/*
 * Copyright (c) 2026, Joseph Maloney
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The login screen: a full-screen black window with one 640 px panel.
 * Everything is drawn here, independent of any GNUstep theme, because
 * loginwindow runs as root and must look the same on every machine.
 */

#import <AppKit/AppKit.h>

/* Panel geometry at 1x, from the NextBSD Desktop Theme mockup. */
#define LW_PANEL_WIDTH		640
#define LW_PANEL_HEIGHT		400

typedef enum {
	LWButtonNone = 0,
	LWButtonRestart,
	LWButtonShutDown,
	LWButtonLogIn
} LWButton;

@protocol LWPanelDelegate
- (void) panelLogIn: (id)sender;
- (void) panelRestart: (id)sender;
- (void) panelShutDown: (id)sender;
@end

/* Borderless, full screen, and still able to become key. */
@interface LWWindow : NSWindow
@end

/* The black screen with the version footer. */
@interface LWBackgroundView : NSView
{
	NSString	*footer;
}
- (void) setFooter: (NSString *)text;
@end

@interface LWPanelView : NSView <NSTextFieldDelegate>
{
	id		 delegate;
	NSTextField	*nameField;
	NSSecureTextField *passwordField;
	NSImage		*cube;
	LWButton	 pressed;	/* mouse is down in this button */
	LWButton	 armed;		/* waiting for a confirming click */
	NSTimer		*disarmTimer;
	NSTimer		*shakeTimer;
	int		 shakeStep;
	NSPoint		 home;		/* origin when not shaking */
	NSTextView	*fieldEditor;
}

- (id) initWithFrame: (NSRect)frame delegate: (id)aDelegate;

- (NSTextField *) nameField;
- (NSTextField *) passwordField;

/* Clears both fields and the confirm state; focus goes to Name. */
- (void) reset;

/* Wrong password: shake the panel, clear the password, keep focus. */
- (void) rejectPassword;

/* Cancels a pending Restart / Shut Down confirmation. */
- (void) disarm;

/* The field editor, styled for the dark fields. */
- (NSTextView *) fieldEditor;

/* Moves the panel to its home position in the window. */
- (void) setHome: (NSPoint)origin;

@end
