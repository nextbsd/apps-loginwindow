/*
 * Copyright (c) 2026, Joseph Maloney
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

#import "LWLoginView.h"

@class LWSession;

@interface LWAppDelegate : NSObject <LWPanelDelegate>
{
	LWWindow	*window;
	LWBackgroundView *background;
	LWPanelView	*panel;
	LWSession	*session;
	NSTimer		*tick;
}
@end
