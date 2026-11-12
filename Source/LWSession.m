/*
 * Copyright (c) 2026, Joseph Maloney
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * A user's graphical session.
 *
 * Start: fork, setsid() (the child is the session leader, so its pid is
 * the session id), setusercontext(LOGIN_SETALL) for groups, uid, limits,
 * umask, PATH and the login class environment, chdir to the home, and
 * exec /bin/sh on the session script.
 *
 * Membership: a process belongs to the session if it is in the Unix
 * session (sid) or descends from the leader. loginwindow is a reaper
 * (procctl(2) PROC_REAP_ACQUIRE), so descendants that called setsid()
 * or daemonized are still found through PROC_REAP_GETPIDS, under the
 * leader's subtree. Other processes of the same user (SSH logins, cron
 * jobs) are in neither set and are never touched.
 *
 * Records: LW_RUN_DIR/<uid>.session lists the user, uid, session id and
 * every member pid with its start time, rewritten every few seconds. If
 * loginwindow dies, the next one stops what the record names before it
 * starts a new session. The start time guards against reused pids.
 */

#include <sys/types.h>
#include <sys/procctl.h>
#include <sys/sysctl.h>
#include <sys/user.h>
#include <sys/wait.h>
#include <sys/stat.h>

#include <errno.h>
#include <fcntl.h>
#include <login_cap.h>
#include <pwd.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <unistd.h>

#import "LWSession.h"
#import "LWAuth.h"

extern char **environ;

/* The session that is running, for the reaper. At most one. */
static LWSession *current = nil;
static BOOL isReaper = NO;

/* --- process table helpers ------------------------------------------ */

static struct kinfo_proc *
proc_all(size_t *count)
{
	int mib[3] = { CTL_KERN, KERN_PROC, KERN_PROC_PROC };
	struct kinfo_proc *kp = NULL;
	size_t len = 0;
	int tries;

	*count = 0;
	for (tries = 0; tries < 5; tries++) {
		if (sysctl(mib, 3, NULL, &len, NULL, 0) < 0)
			return (NULL);
		len += len / 4 + 16 * sizeof(*kp);
		free(kp);
		if ((kp = malloc(len)) == NULL)
			return (NULL);
		if (sysctl(mib, 3, kp, &len, NULL, 0) == 0) {
			*count = len / sizeof(*kp);
			return (kp);
		}
		if (errno != ENOMEM)
			break;
	}
	free(kp);
	return (NULL);
}

static int
proc_get(pid_t pid, struct kinfo_proc *out)
{
	int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
	size_t len = sizeof(*out);

	if (sysctl(mib, 4, out, &len, NULL, 0) < 0 || len < sizeof(*out))
		return (-1);
	return (0);
}

static BOOL
proc_live(const struct kinfo_proc *kp)
{
	return (kp->ki_stat != SZOMB);
}

/*
 * The members of a live session: everything in its Unix session plus
 * the leader's reaper subtree. Returns a malloc'd array of pids.
 */
static pid_t *
session_members(pid_t sid, size_t *count)
{
	struct kinfo_proc *all;
	pid_t *out = NULL;
	size_t n = 0, cap = 0, i, nall;
	pid_t self = getpid();

	all = proc_all(&nall);
	cap = nall + 1;
	if ((out = calloc(cap, sizeof(pid_t))) == NULL) {
		free(all);
		*count = 0;
		return (NULL);
	}
	for (i = 0; i < nall; i++) {
		if (all[i].ki_sid == sid && all[i].ki_pid != self &&
		    all[i].ki_pid > 1 && proc_live(&all[i]))
			out[n++] = all[i].ki_pid;
	}
	free(all);

	if (isReaper) {
		struct procctl_reaper_status rs;
		struct procctl_reaper_pids rp;
		struct procctl_reaper_pidinfo *pi;
		u_int j;
		size_t k;

		memset(&rs, 0, sizeof(rs));
		if (procctl(P_PID, self, PROC_REAP_STATUS, &rs) == 0 &&
		    rs.rs_descendants > 0) {
			u_int room = rs.rs_descendants + 16;

			pi = calloc(room, sizeof(*pi));
			memset(&rp, 0, sizeof(rp));
			rp.rp_count = room;
			rp.rp_pids = pi;
			if (pi != NULL &&
			    procctl(P_PID, self, PROC_REAP_GETPIDS, &rp) == 0) {
				for (j = 0; j < room; j++) {
					if ((pi[j].pi_flags &
					    REAPER_PIDINFO_VALID) == 0)
						continue;
					if (pi[j].pi_subtree != sid ||
					    (pi[j].pi_flags &
					    REAPER_PIDINFO_ZOMBIE) != 0)
						continue;
					for (k = 0; k < n; k++)
						if (out[k] == pi[j].pi_pid)
							break;
					if (k == n && n < cap) {
						out[n++] = pi[j].pi_pid;
					} else if (k == n) {
						pid_t *bigger = realloc(out,
						    (cap * 2) * sizeof(pid_t));
						if (bigger == NULL)
							break;
						out = bigger;
						cap *= 2;
						out[n++] = pi[j].pi_pid;
					}
				}
			}
			free(pi);
		}
	}
	*count = n;
	return (out);
}

/* --- records --------------------------------------------------------- */

static int
ensure_run_dir(void)
{
	struct stat st;

	if (mkdir(LW_RUN_DIR, 0755) < 0 && errno != EEXIST)
		return (-1);
	if (stat(LW_RUN_DIR, &st) < 0 || !S_ISDIR(st.st_mode) ||
	    st.st_uid != 0)
		return (-1);
	(void)chmod(LW_RUN_DIR, 0755);
	return (0);
}

/*
 * Stops the processes a record names: those in its Unix session that
 * still belong to its user, and its listed pids whose start time and
 * user still match.
 */
static int
stop_recorded(const char *path)
{
	FILE *f;
	char line[256], user[64] = "?";
	long uid = -1, sid = -1;
	struct { pid_t pid; long start; } listed[4096];
	size_t nlisted = 0, i, nall, k;
	int round, stopped = 0;

	if ((f = fopen(path, "r")) == NULL)
		return (0);
	while (fgets(line, sizeof(line), f) != NULL) {
		long a, b;

		if (sscanf(line, "user %63s", user) == 1)
			continue;
		if (sscanf(line, "uid %ld", &a) == 1) {
			uid = a;
			continue;
		}
		if (sscanf(line, "sid %ld", &a) == 1) {
			sid = a;
			continue;
		}
		if (sscanf(line, "pid %ld %ld", &a, &b) == 2 &&
		    nlisted < sizeof(listed) / sizeof(listed[0])) {
			listed[nlisted].pid = (pid_t)a;
			listed[nlisted].start = b;
			nlisted++;
		}
	}
	fclose(f);
	if (uid < 0 || sid <= 1)
		return (0);

	for (round = 0; round < 2; round++) {
		int sig = round == 0 ? SIGTERM : SIGKILL;
		int waited, left = 0;

		for (waited = 0; waited <= 30; waited++) {
			struct kinfo_proc *all = proc_all(&nall);

			left = 0;
			for (i = 0; i < nall; i++) {
				struct kinfo_proc *p = &all[i];
				BOOL member = NO;

				if (!proc_live(p) || p->ki_pid <= 1 ||
				    p->ki_pid == getpid() ||
				    p->ki_uid != (uid_t)uid)
					continue;
				if (p->ki_sid == sid)
					member = YES;
				for (k = 0; !member && k < nlisted; k++)
					if (listed[k].pid == p->ki_pid &&
					    listed[k].start ==
					    (long)p->ki_start.tv_sec)
						member = YES;
				if (!member)
					continue;
				left++;
				if (waited == 0) {
					kill(p->ki_pid, sig);
					if (round == 0)
						stopped++;
				}
			}
			free(all);
			if (left == 0)
				break;
			[LWSession reapChildren];
			usleep(100000);
		}
		if (left == 0)
			break;
	}
	if (stopped > 0)
		syslog(LOG_NOTICE, "stopped %d process(es) left from an "
		    "earlier session of %s (uid %ld, session %ld)", stopped,
		    user, uid, sid);
	return (stopped);
}

@implementation LWSession

+ (void) becomeReaper
{
	if (procctl(P_PID, getpid(), PROC_REAP_ACQUIRE, NULL) == 0)
		isReaper = YES;
	else if (errno == EBUSY)	/* already one */
		isReaper = YES;
	else
		syslog(LOG_WARNING, "procctl(PROC_REAP_ACQUIRE): %m; "
		    "daemonized session processes may escape cleanup");
}

+ (int) cleanUpLeftovers
{
	NSArray *names;
	NSString *name;
	NSEnumerator *e;
	int stopped = 0;

	names = [[NSFileManager defaultManager]
	    directoryContentsAtPath: @LW_RUN_DIR];
	e = [names objectEnumerator];
	while ((name = [e nextObject]) != nil) {
		NSString *path;

		if (![[name pathExtension] isEqualToString: @"session"])
			continue;
		path = [@LW_RUN_DIR stringByAppendingPathComponent: name];
		if (current != nil && [path isEqual: current->recordPath])
			continue;
		stopped += stop_recorded([path fileSystemRepresentation]);
		unlink([path fileSystemRepresentation]);
	}
	return (stopped);
}

+ (void) reapChildren
{
	pid_t pid;
	int status;

	while ((pid = waitpid(-1, &status, WNOHANG)) > 0) {
		if (current != nil && pid == current->leader) {
			current->leaderExited = YES;
			current->leaderStatus = status;
		}
	}
}

+ (LWSession *) startSessionForUser: (NSString *)name
				pam: (pam_handle_t *)handle
			     script: (NSString *)script
			environment: (NSDictionary *)extra
{
	LWSession *s;
	struct passwd *pw;
	char **pamenv, **envp, **ep;
	size_t nenv, n;
	const char *keep[] = { "WS_SERVICE_NAME", "LANG", "LC_ALL", "TZ",
	    NULL };
	NSEnumerator *ke;
	NSString *key;
	const char *shell, *home;
	char scriptPath[PATH_MAX];
	pid_t pid;
	int i;

	if ((pw = getpwnam([name UTF8String])) == NULL) {
		syslog(LOG_ERR, "no passwd entry for %s", [name UTF8String]);
		LWAuthClose(handle);
		return (nil);
	}
	home = pw->pw_dir != NULL && pw->pw_dir[0] != '\0' ? pw->pw_dir : "/";
	shell = pw->pw_shell != NULL && pw->pw_shell[0] != '\0' ?
	    pw->pw_shell : "/bin/sh";
	strlcpy(scriptPath, [script fileSystemRepresentation],
	    sizeof(scriptPath));

	/*
	 * Build the environment before fork(): the child only calls what
	 * login(1) calls. setusercontext() adds PATH, umask-independent
	 * class variables (setenv=, lang=) and the user's ~/.login_conf.
	 */
	pamenv = pam_getenvlist(handle);
	nenv = 0;
	for (ep = pamenv; ep != NULL && *ep != NULL; ep++)
		nenv++;
	envp = calloc(nenv + [extra count] + 16, sizeof(char *));
	n = 0;
	asprintf(&envp[n++], "HOME=%s", home);
	asprintf(&envp[n++], "USER=%s", pw->pw_name);
	asprintf(&envp[n++], "LOGNAME=%s", pw->pw_name);
	asprintf(&envp[n++], "SHELL=%s", shell);
	asprintf(&envp[n++], "PATH=%s", "/usr/bin:/bin");
	for (i = 0; keep[i] != NULL; i++) {
		const char *v = getenv(keep[i]);

		if (v != NULL)
			asprintf(&envp[n++], "%s=%s", keep[i], v);
	}
	ke = [extra keyEnumerator];
	while ((key = [ke nextObject]) != nil)
		asprintf(&envp[n++], "%s=%s", [key UTF8String],
		    [[extra objectForKey: key] UTF8String]);
	for (ep = pamenv; ep != NULL && *ep != NULL; ep++)
		envp[n++] = *ep;
	envp[n] = NULL;
	free(pamenv);

	s = [LWSession new];
	s->user = [name copy];
	s->uid = pw->pw_uid;
	s->pamh = handle;

	pid = fork();
	if (pid < 0) {
		syslog(LOG_ERR, "fork: %m");
		LWAuthClose(handle);
		s->pamh = NULL;
		[s release];
		return (nil);
	}
	if (pid == 0) {
		sigset_t none;
		login_cap_t *lc;
		int fd, sig;

		sigemptyset(&none);
		sigprocmask(SIG_SETMASK, &none, NULL);
		for (sig = 1; sig < NSIG; sig++)
			if (sig != SIGKILL && sig != SIGSTOP)
				signal(sig, SIG_DFL);
		if (setsid() < 0)
			_exit(126);
		if ((fd = open("/dev/null", O_RDWR)) >= 0) {
			dup2(fd, STDIN_FILENO);
			if (fd > STDERR_FILENO)
				close(fd);
		}
		closefrom(STDERR_FILENO + 1);
		environ = envp;
		lc = login_getpwclass(pw);
		if (setusercontext(lc, pw, pw->pw_uid, LOGIN_SETALL) != 0) {
			syslog(LOG_ERR, "setusercontext for %s: %m",
			    pw->pw_name);
			_exit(126);
		}
		login_close(lc);
		if (chdir(home) != 0)
			(void)chdir("/");
		execl("/bin/sh", "sh", scriptPath, (char *)NULL);
		syslog(LOG_ERR, "exec /bin/sh %s: %m", scriptPath);
		_exit(127);
	}

	for (ep = envp; *ep != NULL; ep++)
		free(*ep);
	free(envp);

	s->leader = pid;
	{
		struct kinfo_proc kp;

		s->leaderStart = proc_get(pid, &kp) == 0 ?
		    kp.ki_start.tv_sec : 0;
	}
	if (ensure_run_dir() == 0)
		s->recordPath = [[NSString alloc] initWithFormat:
		    @"%s/%u.session", LW_RUN_DIR, (unsigned)s->uid];
	current = s;
	[s updateRecord];
	syslog(LOG_NOTICE, "session started for %s (uid %u, session %d)",
	    pw->pw_name, (unsigned)s->uid, (int)pid);
	return ([s autorelease]);
}

- (void) dealloc
{
	if (current == self)
		current = nil;
	[user release];
	[recordPath release];
	[super dealloc];
}

- (NSString *) user
{
	return (user);
}

- (pid_t) leader
{
	return (leader);
}

- (BOOL) leaderHasExited
{
	struct kinfo_proc kp;

	[LWSession reapChildren];
	/*
	 * libs-base's NSTask reaps with waitpid(-1) from its SIGCHLD
	 * handler, so the leader may be gone without us seeing its status:
	 * look it up as well (a pid with another start time is not ours).
	 */
	if (!leaderExited && (proc_get(leader, &kp) != 0 ||
	    kp.ki_start.tv_sec != leaderStart || kp.ki_stat == SZOMB))
		leaderExited = YES;
	return (leaderExited);
}

- (void) updateRecord
{
	NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
	char tmp[PATH_MAX];
	const char *path;
	pid_t *pids;
	size_t n, i;
	FILE *f;
	int fd;

	if (recordPath == nil || now - lastRecord < 2.0)
		return;
	lastRecord = now;
	path = [recordPath fileSystemRepresentation];
	snprintf(tmp, sizeof(tmp), "%s.tmp", path);
	if ((fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0600)) < 0)
		return;
	if ((f = fdopen(fd, "w")) == NULL) {
		close(fd);
		return;
	}
	fprintf(f, "# loginwindow session record\n");
	fprintf(f, "user %s\nuid %u\nsid %d\n", [user UTF8String],
	    (unsigned)uid, (int)leader);
	pids = session_members(leader, &n);
	for (i = 0; i < n; i++) {
		struct kinfo_proc kp;

		if (proc_get(pids[i], &kp) == 0)
			fprintf(f, "pid %d %ld\n", (int)pids[i],
			    (long)kp.ki_start.tv_sec);
	}
	free(pids);
	if (fclose(f) == 0)
		rename(tmp, path);
	else
		unlink(tmp);
}

- (void) end
{
	int round;

	for (round = 0; round < 2; round++) {
		int sig = round == 0 ? SIGTERM : SIGKILL;
		int waited;
		size_t n = 0, i;
		pid_t *pids;

		if (isReaper) {
			struct procctl_reaper_kill rk;

			memset(&rk, 0, sizeof(rk));
			rk.rk_sig = sig;
			rk.rk_flags = REAPER_KILL_SUBTREE;
			rk.rk_subtree = leader;
			(void)procctl(P_PID, getpid(), PROC_REAP_KILL, &rk);
		}
		pids = session_members(leader, &n);
		for (i = 0; i < n; i++)
			kill(pids[i], sig);
		free(pids);

		/* 3 s grace after SIGTERM; after SIGKILL just reap. */
		for (waited = 0; waited < (round == 0 ? 30 : 20); waited++) {
			[LWSession reapChildren];
			pids = session_members(leader, &n);
			free(pids);
			if (n == 0)
				break;
			usleep(100000);
		}
		if (n == 0)
			break;
		syslog(LOG_NOTICE, "%zu session process(es) of %s ignored "
		    "SIGTERM; sending SIGKILL", n, [user UTF8String]);
	}
	[LWSession reapChildren];
	LWAuthClose(pamh);
	pamh = NULL;
	if (recordPath != nil)
		unlink([recordPath fileSystemRepresentation]);
	syslog(LOG_NOTICE, "session of %s ended", [user UTF8String]);
	if (current == self)
		current = nil;
}

@end
