/*
 * Copyright (c) 2026, Joseph Maloney
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * A user's graphical session: started as the user in its own Unix
 * session, watched until its leader exits, then stopped as a whole.
 */

#import <Foundation/Foundation.h>
#include <sys/types.h>
#include <security/pam_appl.h>

/* Where loginwindow keeps its state: session records, session config. */
#define LW_RUN_DIR	"/var/run/loginwindow"

@interface LWSession : NSObject
{
	NSString	*user;
	uid_t		 uid;
	pid_t		 leader;	/* session leader, also the session id */
	long long	 leaderStart;	/* microseconds since boot */
	BOOL		 haveLeaderStart;
	BOOL		 leaderExited;
	int		 leaderStatus;
	pam_handle_t	*pamh;
	NSString	*recordPath;
	NSTimeInterval	 lastRecord;	/* CLOCK_MONOTONIC seconds */
}

/*
 * Makes loginwindow the reaper of its descendants (procctl(2)), so
 * session processes that daemonize or call setsid() stay attached to
 * it and can be found and stopped. Call once at startup.
 */
+ (void) becomeReaper;

/*
 * Stops whatever is left of sessions an earlier loginwindow started (it
 * crashed or was killed), from the records in LW_RUN_DIR, and removes
 * those records. Returns how many processes it had to stop.
 */
+ (int) cleanUpLeftovers;

/*
 * Reaps exited children. Call it often (loginwindow is a reaper, so
 * orphans of the session become its children).
 */
+ (void) reapChildren;

/*
 * Starts the session for user (already authenticated; pamh has an
 * open PAM session and is closed when the session ends). script is the
 * session script, run with /bin/sh as the user; extra adds environment
 * variables. Returns nil and logs
 * why on failure (the PAM session is then closed too).
 */
+ (LWSession *) startSessionForUser: (NSString *)name
				pam: (pam_handle_t *)handle
			     script: (NSString *)script
			environment: (NSDictionary *)extra;

- (NSString *) user;
- (pid_t) leader;

/* Reaps children; YES once the session leader has exited. */
- (BOOL) leaderHasExited;

/* Refreshes the session record (cheap; rate-limited internally). */
- (void) updateRecord;

/*
 * Stops every process of the session (SIGTERM, a grace period, then
 * SIGKILL), closes the PAM session and removes the record.
 */
- (void) end;

@end
