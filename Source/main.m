/*
 * Copyright (c) 2026, Joseph Maloney
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * loginwindow: the graphical login for the NextBSD WindowServer.
 *
 * Before AppKit loads a backend, main() waits until WindowServer
 * answers, makes the bundled Inter fonts visible to fontconfig, and
 * pins the defaults loginwindow depends on (the nextbsd backend, no
 * theme, no app icon) in the argument domain, so root's own defaults
 * can't change them.
 */

#include <sys/types.h>
#include <sys/wait.h>

#include <errno.h>
#include <fontconfig/fontconfig.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <syslog.h>
#include <unistd.h>

#include <WindowServer/WSClient.h>

#import <AppKit/AppKit.h>

#import "LWAppDelegate.h"
#import "LWSession.h"

/* The GNUstep backend bundle that talks to WindowServer. */
#define LW_BACKEND	@"libgnustep-nextbsd"

/*
 * One connection attempt in a child process, so a server that launchd
 * has registered but that never answers can't hang loginwindow: the
 * child gets three seconds.
 */
static int
probe_window_server(void)
{
	pid_t pid;
	int status;

	pid = fork();
	if (pid < 0)
		return (-1);
	if (pid == 0) {
		ws_connection_t *c;

		alarm(3);
		c = ws_connect("loginwindow", WS_CONNECT_CONTROL);
		if (c == NULL)
			_exit(1);
		if (ws_sync(c) != 0)
			_exit(1);
		ws_disconnect(c);
		_exit(0);
	}
	while (waitpid(pid, &status, 0) < 0)
		if (errno != EINTR)
			return (-1);
	return (WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : -1);
}

/*
 * Waits for WindowServer, backing off from a quarter second to two
 * seconds between attempts. After a minute it gives up; launchd
 * (KeepAlive) starts loginwindow again.
 */
static BOOL
wait_for_window_server(void)
{
	useconds_t delay = 250000;
	int elapsed = 0;		/* ms, roughly */
	BOOL logged = NO;

	while (probe_window_server() != 0) {
		if (!logged) {
			syslog(LOG_NOTICE, "waiting for WindowServer (%s)",
			    getenv("WS_SERVICE_NAME") ? getenv("WS_SERVICE_NAME")
			    : "org.nextbsd.windowserver");
			logged = YES;
		}
		if (elapsed > 60000)
			return (NO);
		usleep(delay);
		elapsed += delay / 1000 + 100;
		if (delay < 2000000)
			delay *= 2;
	}
	return (YES);
}

/* Adds the app's Fonts folder to fontconfig as application fonts. */
static void
add_bundled_fonts(void)
{
	NSString *dir;

	dir = [[NSBundle mainBundle] pathForResource: @"Fonts" ofType: nil];
	if (dir == nil ||
	    !FcConfigAppFontAddDir(NULL,
	    (const FcChar8 *)[dir fileSystemRepresentation]))
		syslog(LOG_WARNING, "couldn't add the bundled fonts in %s",
		    dir ? [dir fileSystemRepresentation] : "Resources/Fonts");
}

/*
 * Puts the defaults loginwindow relies on into the argument domain,
 * which comes before every persistent domain. Only this process is
 * affected; nothing is written to root's defaults.
 */
static void
pin_defaults(void)
{
	NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
	NSMutableDictionary *args;

	args = [[[defs volatileDomainForName: NSArgumentDomain]
	    mutableCopy] autorelease];
	if (args == nil)
		args = [NSMutableDictionary dictionary];
	[args setObject: LW_BACKEND forKey: @"GSBackend"];
	[args setObject: @"GNUstep" forKey: @"GSTheme"];
	[args setObject: @"YES" forKey: @"GSSuppressAppIcon"];
	/* Root has no fonts but the bundled Inter. */
	[args setObject: @"Inter-Regular" forKey: @"NSFont"];
	[args setObject: @"Inter-Bold" forKey: @"NSBoldFont"];
	[args setObject: @"Inter-Regular" forKey: @"NSUserFont"];
	[args setObject: @"Inter-Regular" forKey: @"NSUserFixedPitchFont"];
	[args setObject: @"NSNextStepInterfaceStyle"
		 forKey: @"NSMenuInterfaceStyle"];
	[defs removeVolatileDomainForName: NSArgumentDomain];
	[defs setVolatileDomain: args forName: NSArgumentDomain];
}

int
main(int argc, const char **argv)
{
	NSAutoreleasePool *pool;
	LWAppDelegate *delegate;

	openlog("loginwindow", LOG_PID | LOG_PERROR, LOG_AUTH);
	if (geteuid() != 0) {
		syslog(LOG_ERR, "loginwindow must run as root");
		return (EXIT_FAILURE);
	}
	signal(SIGPIPE, SIG_IGN);

	/* Before anything forks, so session processes stay ours. */
	[LWSession becomeReaper];

	if (!wait_for_window_server()) {
		syslog(LOG_ERR, "WindowServer didn't answer; giving up");
		return (EXIT_FAILURE);
	}

	pool = [NSAutoreleasePool new];
	add_bundled_fonts();
	pin_defaults();

	[NSApplication sharedApplication];
	delegate = [LWAppDelegate new];
	[NSApp setDelegate: delegate];
	[NSApp run];
	[pool release];
	return (EXIT_SUCCESS);
}
