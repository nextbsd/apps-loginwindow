/*
 * Copyright (c) 2026, Joseph Maloney
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * loginwindow's controller: shows the panel, authenticates, starts the
 * session, waits for it to end, and shows the panel again.
 */

#include <sys/stat.h>

#include <errno.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <unistd.h>

#import "LWAppDelegate.h"
#import "LWAuth.h"
#import "LWSession.h"

#define LW_SYSTEM_VERSION \
	@"/System/Library/CoreServices/SystemVersion.plist"
#define LW_DEFAULT_VERSION	@"NextBSD 27.0.0"
#define LW_SYSTEM_GNUSTEP_CONF	"/System/Library/Preferences/GNUstep.conf"
#define LW_SESSION_CONFIG_DIR	LW_RUN_DIR "/GNUstep"
#define LW_SESSION_BACKEND	@"libgnustep-nextbsd"

static volatile sig_atomic_t quitSignal = 0;

static void
on_signal(int sig)
{
	quitSignal = sig;
}

/* "NextBSD 27.0.0" from SystemVersion.plist, or the fallback. */
static NSString *
system_version(void)
{
	NSDictionary *d;
	NSString *name, *version;

	d = [NSDictionary dictionaryWithContentsOfFile: LW_SYSTEM_VERSION];
	name = [d objectForKey: @"ProductName"];
	version = [d objectForKey: @"ProductUserVisibleVersion"];
	if (version == nil)
		version = [d objectForKey: @"ProductVersion"];
	if (name == nil || version == nil)
		return (LW_DEFAULT_VERSION);
	return ([NSString stringWithFormat: @"%@ %@", name, version]);
}

/*
 * The GNUstep configuration for session processes.
 *
 * libs-base reads its configuration file from $GNUSTEP_CONFIG_FILE when
 * that is set, and merges GlobalDefaults.plist from the same directory
 * into the GSConfigDomain defaults domain. So the session gets a copy of
 * the system GNUstep.conf (all paths unchanged) next to a
 * GlobalDefaults.plist that adds GSBackend = libgnustep-nextbsd. Nothing
 * is written to the user's own defaults. GSConfigDomain comes after
 * NSGlobalDomain, so a GSBackend the user set themselves still wins;
 * the session script handles that case.
 *
 * Returns the path for GNUSTEP_CONFIG_FILE, or nil.
 */
static NSString *
prepare_session_config(void)
{
	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *src, *srcDir, *dir, *conf, *globals, *link;
	NSMutableDictionary *defs;
	NSData *data;
	const char *env = getenv("GNUSTEP_CONFIG_FILE");

	src = [NSString stringWithUTF8String:
	    env != NULL && env[0] == '/' ? env : LW_SYSTEM_GNUSTEP_CONF];
	srcDir = [src stringByDeletingLastPathComponent];
	dir = @LW_SESSION_CONFIG_DIR;
	conf = [dir stringByAppendingPathComponent: @"GNUstep.conf"];
	globals = [dir stringByAppendingPathComponent: @"GlobalDefaults.plist"];
	link = [dir stringByAppendingPathComponent: @"GlobalDefaults"];

	if ((mkdir(LW_RUN_DIR, 0755) < 0 && errno != EEXIST) ||
	    (mkdir(LW_SESSION_CONFIG_DIR, 0755) < 0 && errno != EEXIST)) {
		syslog(LOG_ERR, "mkdir %s: %m", LW_SESSION_CONFIG_DIR);
		return (nil);
	}
	chmod(LW_RUN_DIR, 0755);
	chmod(LW_SESSION_CONFIG_DIR, 0755);

	data = [NSData dataWithContentsOfFile: src];
	if (data == nil)
		data = [NSData data];	/* libs-base then uses built-in paths */
	if (![data writeToFile: conf atomically: YES]) {
		syslog(LOG_ERR, "can't write %s", [conf UTF8String]);
		return (nil);
	}
	chmod([conf fileSystemRepresentation], 0644);

	defs = [NSMutableDictionary dictionaryWithContentsOfFile:
	    [srcDir stringByAppendingPathComponent: @"GlobalDefaults.plist"]];
	if (defs == nil)
		defs = [NSMutableDictionary dictionary];
	[defs setObject: LW_SESSION_BACKEND forKey: @"GSBackend"];
	if (![defs writeToFile: globals atomically: YES]) {
		syslog(LOG_ERR, "can't write %s", [globals UTF8String]);
		return (nil);
	}
	chmod([globals fileSystemRepresentation], 0644);

	/* The system's GlobalDefaults folder, if it has one, still applies. */
	unlink([link fileSystemRepresentation]);
	if ([fm fileExistsAtPath:
	    [srcDir stringByAppendingPathComponent: @"GlobalDefaults"]])
		symlink([[srcDir stringByAppendingPathComponent:
		    @"GlobalDefaults"] fileSystemRepresentation],
		    [link fileSystemRepresentation]);
	return (conf);
}

static void
run_shutdown(const char *how)
{
	pid_t pid;

	syslog(LOG_NOTICE, "%s requested from the login panel",
	    how[1] == 'r' ? "restart" : "shut down");
	pid = fork();
	if (pid == 0) {
		execl("/sbin/shutdown", "shutdown", how, "now", (char *)NULL);
		_exit(127);
	}
	if (pid < 0)
		syslog(LOG_ERR, "fork: %m");
}

@implementation LWAppDelegate

- (void) applicationDidFinishLaunching: (NSNotification *)n
{
	NSRect screen = [[NSScreen mainScreen] frame];
	NSRect pf;

	window = [[LWWindow alloc] initWithContentRect: screen
					     styleMask: NSBorderlessWindowMask
					       backing: NSBackingStoreBuffered
						 defer: NO];
	[window setLevel: NSScreenSaverWindowLevel];
	[window setBackgroundColor: [NSColor blackColor]];
	[window setReleasedWhenClosed: NO];
	[window setHidesOnDeactivate: NO];
	[window setDelegate: self];

	background = [[LWBackgroundView alloc] initWithFrame:
	    NSMakeRect(0, 0, NSWidth(screen), NSHeight(screen))];
	[background setFooter: system_version()];
	[window setContentView: background];

	pf = NSMakeRect(0, 0, LW_PANEL_WIDTH + 2, LW_PANEL_HEIGHT + 2);
	pf.origin.x = floor((NSWidth(screen) - NSWidth(pf)) / 2);
	pf.origin.y = floor((NSHeight(screen) - NSHeight(pf)) / 2);
	panel = [[LWPanelView alloc] initWithFrame: pf delegate: self];
	[background addSubview: panel];

	signal(SIGTERM, on_signal);
	signal(SIGINT, on_signal);
	signal(SIGHUP, on_signal);
	tick = [NSTimer scheduledTimerWithTimeInterval: 0.25
	    target: self selector: @selector(tick:) userInfo: nil
	    repeats: YES];

	[self showPanel];
}

- (void) showPanel
{
	[panel reset];
	[window makeKeyAndOrderFront: nil];
	[NSApp activateIgnoringOtherApps: YES];
	[window makeFirstResponder: [panel nameField]];
	[window display];
}

- (id) windowWillReturnFieldEditor: (NSWindow *)sender toObject: (id)client
{
	if (client == [panel nameField] || client == [panel passwordField])
		return ([panel fieldEditor]);
	return (nil);
}

- (NSApplicationTerminateReply) applicationShouldTerminate: (NSApplication *)a
{
	/* Only a signal (launchd stopping the job) ends loginwindow. */
	return (quitSignal != 0 ? NSTerminateNow : NSTerminateCancel);
}

- (void) tick: (NSTimer *)t
{
	if (quitSignal != 0) {
		syslog(LOG_NOTICE, "signal %d: ending the session and exiting",
		    (int)quitSignal);
		if (session != nil) {
			[session end];
			[session release];
			session = nil;
		}
		exit(EXIT_SUCCESS);
	}
	if (session == nil) {
		[LWSession reapChildren];
		return;
	}
	if ([session leaderHasExited]) {
		[session end];
		[session release];
		session = nil;
		[self showPanel];
	} else {
		[session updateRecord];
	}
}

- (void) startSession: (NSArray *)args
{
	NSString *user = [args objectAtIndex: 0];
	pam_handle_t *pamh = [[args objectAtIndex: 1] pointerValue];
	NSString *script, *conf;
	NSMutableDictionary *env = [NSMutableDictionary dictionary];
	int stopped;

	stopped = [LWSession cleanUpLeftovers];
	if (stopped > 0)
		syslog(LOG_NOTICE, "cleaned up %d leftover process(es)",
		    stopped);
	conf = prepare_session_config();
	if (conf != nil)
		[env setObject: conf forKey: @"GNUSTEP_CONFIG_FILE"];
	[env setObject: LW_SESSION_BACKEND forKey: @"LW_SESSION_BACKEND"];
	script = [[NSBundle mainBundle] pathForResource: @"session"
						 ofType: nil];
	[env setObject: [script stringByDeletingLastPathComponent]
		forKey: @"LW_RESOURCES"];
	session = [[LWSession startSessionForUser: user
					      pam: pamh
					   script: script
				      environment: env] retain];
	if (session == nil) {
		[self showPanel];
		[panel rejectPassword];
	}
}

- (void) panelLogIn: (id)sender
{
	NSString *name;
	char *password, *canonical = NULL;
	pam_handle_t *pamh;

	if (session != nil)
		return;
	name = [[[panel nameField] stringValue] stringByTrimmingCharactersInSet:
	    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if ([name length] == 0) {
		[panel rejectPassword];
		return;
	}
	password = strdup([[[panel passwordField] stringValue] UTF8String]);
	[[panel passwordField] setStringValue: @""];
	pamh = password != NULL ? LWAuthOpen([name UTF8String], password,
	    &canonical) : NULL;
	if (password != NULL) {
		explicit_bzero(password, strlen(password));
		free(password);
	}
	if (pamh == NULL) {
		[panel rejectPassword];
		return;
	}
	syslog(LOG_NOTICE, "%s logged in", canonical);

	/*
	 * Straight to the desktop: take the panel off the screen now and
	 * start the session on the next pass of the run loop, after the
	 * backend has sent the order-out to WindowServer.
	 */
	[window orderOut: nil];
	[self performSelector: @selector(startSession:)
		   withObject: [NSArray arrayWithObjects:
		       [NSString stringWithUTF8String: canonical],
		       [NSValue valueWithPointer: pamh], nil]
		   afterDelay: 0];
	free(canonical);
}

- (void) panelRestart: (id)sender
{
	run_shutdown("-r");
}

- (void) panelShutDown: (id)sender
{
	run_shutdown("-p");
}

@end
