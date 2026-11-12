/*
 * Copyright (c) 2026, Joseph Maloney
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The login screen, drawn to the NextBSD Desktop Theme mockup at 1x.
 *
 * Panel (640 x 400, square corners, 1 px outline):
 *   header  152 px, black: the NextBSD cube in an 84 px box, "NextBSD"
 *           in Inter Bold 34 and the tagline in Label (#b8b8c0)
 *   body    Plane (#16161b): Name and Password fields (40 px, inset
 *           bevel, black, labels in a 92 px column, 2 px accent ring on
 *           the focused one), Restart and Shut Down (Control #26262d,
 *           raised bevel) on the left and Log In (accent, black bold
 *           text) on the right, all 44 px tall
 * Footer: the system version centred 28 px above the bottom edge.
 */

#import "LWLoginView.h"

#define HEX(v)	[NSColor colorWithCalibratedRed: (((v) >> 16) & 0xff) / 255.0 \
			green: (((v) >> 8) & 0xff) / 255.0 \
			blue: ((v) & 0xff) / 255.0 alpha: 1.0]

/* Theme tokens. */
#define C_ACCENT	0x00d4ff
#define C_PLANE		0x16161b
#define C_CONTROL	0x26262d
#define C_TEXT		0xf5f5f7
#define C_LABEL		0xb8b8c0
#define C_FOOTER	0xa1a1a6
#define C_HIGHLIGHT	0x55555f
#define C_SHADE		0x0a0a0a
#define C_OUTLINE	0x3a3a42
#define C_SEPARATOR	0x2c2c33

/* Layout, in panel content coordinates (top left, y down). */
#define BORDER		1
#define PAD		40
#define HEADER_H	152
#define CUBE_BOX	84
#define CUBE_Y		36
#define TITLE_X		146
#define TITLE_BASE	79
#define TAG_X		145
#define TAG_BASE	107
#define LABEL_COL	92
#define FIELD_X		(PAD + LABEL_COL)
#define FIELD_W		(LW_PANEL_WIDTH - PAD - FIELD_X)
#define FIELD_H		40
#define NAME_Y		188
#define PASS_Y		246
#define LABEL_BASE	26	/* from the field's top */
#define BUTTON_Y	319
#define BUTTON_H	44
#define BUTTON_BASE	28	/* from the button's top */
#define BUTTON_PAD	19
#define BUTTON_MIN	88
#define BUTTON_GAP	10
#define LOGIN_W		100
#define FOOTER_BASE	31	/* from the bottom of the screen */

static NSFont *
lw_font(NSString *name, CGFloat size, BOOL bold)
{
	NSFont *f = [NSFont fontWithName: name size: size];

	if (f == nil)
		f = bold ? [NSFont boldSystemFontOfSize: size] :
		    [NSFont systemFontOfSize: size];
	return (f);
}

static NSDictionary *
attrs(NSFont *font, NSColor *color)
{
	return ([NSDictionary dictionaryWithObjectsAndKeys:
	    font, NSFontAttributeName,
	    color, NSForegroundColorAttributeName, nil]);
}

/* Draws s with its baseline at y, in a flipped view. */
static void
draw_text(NSString *s, NSFont *font, NSColor *color, CGFloat x, CGFloat y)
{
	[s drawAtPoint: NSMakePoint(x, y - [font ascender])
	    withAttributes: attrs(font, color)];
}

/* The same with tracking (letter spacing) in points. */
static void
draw_tracked(NSString *s, NSFont *font, NSColor *color, CGFloat x, CGFloat y,
    CGFloat tracking)
{
	NSMutableDictionary *a = [[attrs(font, color) mutableCopy] autorelease];

	[a setObject: [NSNumber numberWithFloat: tracking]
	      forKey: NSKernAttributeName];
	[s drawAtPoint: NSMakePoint(x, y - [font ascender]) withAttributes: a];
}

static CGFloat
text_width(NSString *s, NSFont *font)
{
	return ([s sizeWithAttributes: attrs(font, HEX(C_TEXT))].width);
}

static void
fill(NSRect r, NSColor *c)
{
	[c set];
	NSRectFill(r);
}

/*
 * The bevel: raised controls get the highlight on the top and left
 * edges and the shade on the bottom and right; inset fields the reverse.
 */
static void
bevel(NSRect r, BOOL raised)
{
	NSColor *tl = raised ? HEX(C_HIGHLIGHT) : HEX(C_SHADE);
	NSColor *br = raised ? HEX(C_SHADE) : HEX(C_HIGHLIGHT);

	fill(NSMakeRect(NSMinX(r), NSMinY(r), NSWidth(r), 1), tl);
	fill(NSMakeRect(NSMinX(r), NSMinY(r), 1, NSHeight(r)), tl);
	fill(NSMakeRect(NSMinX(r), NSMaxY(r) - 1, NSWidth(r), 1), br);
	fill(NSMakeRect(NSMaxX(r) - 1, NSMinY(r), 1, NSHeight(r)), br);
}

/* A 2 px ring just outside r. */
static void
ring(NSRect r, NSColor *c)
{
	NSRect o = NSInsetRect(r, -2, -2);

	fill(NSMakeRect(NSMinX(o), NSMinY(o), NSWidth(o), 2), c);
	fill(NSMakeRect(NSMinX(o), NSMaxY(o) - 2, NSWidth(o), 2), c);
	fill(NSMakeRect(NSMinX(o), NSMinY(o), 2, NSHeight(o)), c);
	fill(NSMakeRect(NSMaxX(o) - 2, NSMinY(o), 2, NSHeight(o)), c);
}

@implementation LWWindow

- (BOOL) canBecomeKeyWindow
{
	return (YES);
}

- (BOOL) canBecomeMainWindow
{
	return (YES);
}

- (BOOL) makeFirstResponder: (NSResponder *)r
{
	BOOL ok = [super makeFirstResponder: r];

	/*
	 * A scrollable text field puts the field editor in a clip view
	 * that paints the theme's light control colour; keep it clear.
	 */
	if ([r isKindOfClass: [NSTextView class]] &&
	    [[(NSView *)r superview] isKindOfClass: [NSClipView class]]) {
		NSClipView *clip = (NSClipView *)[(NSView *)r superview];

		[clip setDrawsBackground: NO];
		[clip setBackgroundColor: [NSColor blackColor]];
	}
	/* The focus ring is drawn by the panel. */
	[[self contentView] setNeedsDisplay: YES];
	return (ok);
}

@end

@implementation LWBackgroundView

- (BOOL) isFlipped
{
	return (YES);
}

- (BOOL) isOpaque
{
	return (YES);
}

- (void) dealloc
{
	[footer release];
	[super dealloc];
}

- (void) setFooter: (NSString *)text
{
	ASSIGN(footer, text);
	[self setNeedsDisplay: YES];
}

- (void) drawRect: (NSRect)r
{
	NSFont *font = lw_font(@"Inter-Regular", 13, NO);
	NSRect b = [self bounds];

	fill(r, [NSColor blackColor]);
	if (footer != nil) {
		CGFloat w = text_width(footer, font);

		draw_text(footer, font, HEX(C_FOOTER),
		    floor(NSMidX(b) - w / 2), NSMaxY(b) - FOOTER_BASE);
	}
}

@end

@implementation LWPanelView

- (NSTextField *) makeField: (Class)cls y: (CGFloat)y
{
	NSFont *font = lw_font(@"Inter-Regular", 14, NO);
	CGFloat h = ceil([font ascender] - [font descender]) + 4;
	NSTextField *f;

	f = [[cls alloc] initWithFrame: NSMakeRect(BORDER + FIELD_X + 10,
	    BORDER + y + floor((FIELD_H - h) / 2), FIELD_W - 20, h)];
	[f setBezeled: NO];
	[f setBordered: NO];
	[f setDrawsBackground: NO];
	[f setBackgroundColor: [NSColor blackColor]];
	[f setEditable: YES];
	[f setSelectable: YES];
	[f setFont: font];
	[f setTextColor: HEX(C_TEXT)];
	[f setFocusRingType: NSFocusRingTypeNone];
	[[f cell] setScrollable: YES];
	[[f cell] setSendsActionOnEndEditing: NO];
	[f setTarget: self];
	[f setAction: @selector(fieldAction:)];
	[f setDelegate: self];
	[self addSubview: f];
	return ([f autorelease]);
}

- (id) initWithFrame: (NSRect)frame delegate: (id)aDelegate
{
	NSString *path;

	frame.size = NSMakeSize(LW_PANEL_WIDTH + 2 * BORDER,
	    LW_PANEL_HEIGHT + 2 * BORDER);
	if ((self = [super initWithFrame: frame]) == nil)
		return (nil);
	delegate = aDelegate;
	home = frame.origin;
	nameField = [[self makeField: [NSTextField class] y: NAME_Y] retain];
	passwordField = [(NSSecureTextField *)[self makeField:
	    [NSSecureTextField class] y: PASS_Y] retain];
	[nameField setNextKeyView: passwordField];
	[passwordField setNextKeyView: nameField];

	path = [[NSBundle mainBundle] pathForResource: @"Cube" ofType: @"png"];
	if (path != nil)
		cube = [[NSImage alloc] initWithContentsOfFile: path];
	return (self);
}

- (void) dealloc
{
	[disarmTimer invalidate];
	[shakeTimer invalidate];
	[nameField release];
	[passwordField release];
	[cube release];
	[fieldEditor release];
	[super dealloc];
}

- (BOOL) isFlipped
{
	return (YES);
}

- (BOOL) isOpaque
{
	return (YES);
}

- (NSTextField *) nameField
{
	return (nameField);
}

- (NSTextField *) passwordField
{
	return (passwordField);
}

- (NSTextView *) fieldEditor
{
	if (fieldEditor == nil) {
		NSColor *sel = [NSColor colorWithCalibratedRed: 0
		    green: 0x6a / 255.0 blue: 0x80 / 255.0 alpha: 1.0];

		fieldEditor = [[NSTextView alloc] initWithFrame: NSZeroRect];
		[fieldEditor setFieldEditor: YES];
		[fieldEditor setDrawsBackground: NO];
		[fieldEditor setBackgroundColor: [NSColor blackColor]];
		[fieldEditor setTextColor: HEX(C_TEXT)];
		[fieldEditor setInsertionPointColor: HEX(C_TEXT)];
		[fieldEditor setSelectedTextAttributes:
		    [NSDictionary dictionaryWithObjectsAndKeys:
		    sel, NSBackgroundColorAttributeName,
		    HEX(C_TEXT), NSForegroundColorAttributeName, nil]];
	}
	return (fieldEditor);
}

- (void) setHome: (NSPoint)origin
{
	home = origin;
	[self setFrameOrigin: origin];
}

/* Which field has the keyboard (the field editor stands in for it). */
- (NSTextField *) focusedField
{
	NSResponder *r = [[self window] firstResponder];

	if (r == nameField || r == passwordField)
		return ((NSTextField *)r);
	if ([r isKindOfClass: [NSTextView class]]) {
		id d = [(NSTextView *)r delegate];

		if (d == nameField || d == passwordField)
			return (d);
	}
	return (nil);
}

/* --- buttons ------------------------------------------------------- */

- (NSString *) titleOf: (LWButton)b
{
	switch (b) {
	case LWButtonRestart:
		return (armed == b ? @"Confirm Restart" : @"Restart");
	case LWButtonShutDown:
		return (armed == b ? @"Confirm Shut Down" : @"Shut Down");
	case LWButtonLogIn:
		return (@"Log In");
	default:
		return (@"");
	}
}

- (NSFont *) fontOf: (LWButton)b
{
	return (b == LWButtonLogIn ? lw_font(@"Inter-Bold", 14, YES) :
	    lw_font(@"Inter-SemiBold", 14, YES));
}

/* In panel content coordinates. */
- (NSRect) rectOf: (LWButton)b
{
	CGFloat x = PAD, w;

	if (b == LWButtonLogIn)
		return (NSMakeRect(LW_PANEL_WIDTH - PAD - LOGIN_W, BUTTON_Y,
		    LOGIN_W, BUTTON_H));
	w = MAX(BUTTON_MIN, ceil(text_width([self titleOf: LWButtonRestart],
	    [self fontOf: LWButtonRestart]) + 2 * BUTTON_PAD));
	if (b == LWButtonRestart)
		return (NSMakeRect(x, BUTTON_Y, w, BUTTON_H));
	x += w + BUTTON_GAP;
	w = MAX(BUTTON_MIN, ceil(text_width([self titleOf: LWButtonShutDown],
	    [self fontOf: LWButtonShutDown]) + 2 * BUTTON_PAD));
	return (NSMakeRect(x, BUTTON_Y, w, BUTTON_H));
}

- (LWButton) buttonAt: (NSPoint)p
{
	LWButton b;

	p.x -= BORDER;
	p.y -= BORDER;
	for (b = LWButtonRestart; b <= LWButtonLogIn; b++)
		if (NSPointInRect(p, [self rectOf: b]))
			return (b);
	return (LWButtonNone);
}

- (void) drawButton: (LWButton)b
{
	NSRect r = NSOffsetRect([self rectOf: b], BORDER, BORDER);
	NSString *title = [self titleOf: b];
	NSFont *font = [self fontOf: b];
	CGFloat w = text_width(title, font);
	BOOL down = pressed == b;

	if (b == LWButtonLogIn) {
		fill(r, down ? HEX(0x00a8cc) : HEX(C_ACCENT));
		draw_text(title, font, [NSColor blackColor],
		    floor(NSMidX(r) - w / 2), NSMinY(r) + BUTTON_BASE);
		return;
	}
	fill(r, down ? HEX(0x1c1c22) : HEX(C_CONTROL));
	bevel(r, !down);
	if (armed == b)
		ring(r, HEX(C_ACCENT));
	draw_text(title, font, HEX(C_TEXT), floor(NSMidX(r) - w / 2),
	    NSMinY(r) + BUTTON_BASE);
}

/* --- drawing ------------------------------------------------------- */

- (void) drawField: (NSTextField *)f label: (NSString *)label y: (CGFloat)y
{
	NSRect r = NSMakeRect(BORDER + FIELD_X, BORDER + y, FIELD_W, FIELD_H);
	NSFont *font = lw_font(@"Inter-Regular", 14, NO);

	draw_text(label, font, HEX(C_LABEL), BORDER + PAD,
	    BORDER + y + LABEL_BASE);
	fill(r, [NSColor blackColor]);
	if ([self focusedField] == f)
		ring(r, HEX(C_ACCENT));
	else
		bevel(r, NO);
}

- (void) drawRect: (NSRect)dirty
{
	NSRect b = [self bounds];
	NSRect header = NSMakeRect(BORDER, BORDER, LW_PANEL_WIDTH, HEADER_H);
	NSRect body = NSMakeRect(BORDER, BORDER + HEADER_H + 1,
	    LW_PANEL_WIDTH, LW_PANEL_HEIGHT - HEADER_H - 1);
	NSFont *title = lw_font(@"Inter-Bold", 34, YES);
	NSFont *tag = lw_font(@"Inter-Regular", 15, NO);

	/* Outline, header, separator, body. */
	fill(b, HEX(C_OUTLINE));
	fill(header, [NSColor blackColor]);
	fill(NSMakeRect(BORDER, BORDER + HEADER_H, LW_PANEL_WIDTH, 1),
	    HEX(C_SEPARATOR));
	fill(body, HEX(C_PLANE));

	if (cube != nil) {
		NSSize s = [cube size];
		NSRect box = NSMakeRect(BORDER + PAD, BORDER + CUBE_Y,
		    CUBE_BOX, CUBE_BOX);
		NSRect to = NSMakeRect(floor(NSMidX(box) - s.width / 2),
		    floor(NSMidY(box) - s.height / 2), s.width, s.height);

		[cube drawInRect: to
			fromRect: NSZeroRect
		       operation: NSCompositeSourceOver
			fraction: 1.0
		  respectFlipped: YES
			   hints: nil];
	}
	/* Display type is set tight: -0.02 em. */
	draw_tracked(@"NextBSD", title, HEX(C_TEXT), BORDER + TITLE_X,
	    BORDER + TITLE_BASE, -0.02 * [title pointSize]);
	draw_text(@"The BSD of the 21st century.", tag, HEX(C_LABEL),
	    BORDER + TAG_X, BORDER + TAG_BASE);

	[self drawField: nameField label: @"Name" y: NAME_Y];
	[self drawField: passwordField label: @"Password" y: PASS_Y];

	[self drawButton: LWButtonRestart];
	[self drawButton: LWButtonShutDown];
	[self drawButton: LWButtonLogIn];
}

/* --- mouse --------------------------------------------------------- */

- (BOOL) acceptsFirstMouse: (NSEvent *)e
{
	return (YES);
}

- (void) mouseDown: (NSEvent *)e
{
	NSPoint p = [self convertPoint: [e locationInWindow] fromView: nil];

	pressed = [self buttonAt: p];
	if (pressed != LWButtonNone)
		[self setNeedsDisplay: YES];
}

- (void) mouseUp: (NSEvent *)e
{
	NSPoint p = [self convertPoint: [e locationInWindow] fromView: nil];
	LWButton b = pressed;

	pressed = LWButtonNone;
	[self setNeedsDisplay: YES];
	if (b == LWButtonNone || [self buttonAt: p] != b)
		return;
	switch (b) {
	case LWButtonLogIn:
		[self disarm];
		[delegate panelLogIn: self];
		break;
	case LWButtonRestart:
	case LWButtonShutDown:
		if (armed == b) {
			[self disarm];
			if (b == LWButtonRestart)
				[delegate panelRestart: self];
			else
				[delegate panelShutDown: self];
		} else {
			armed = b;
			[disarmTimer invalidate];
			disarmTimer = [NSTimer scheduledTimerWithTimeInterval: 5
			    target: self selector: @selector(disarm)
			    userInfo: nil repeats: NO];
			[self setNeedsDisplay: YES];
		}
		break;
	default:
		break;
	}
}

- (void) disarm
{
	[disarmTimer invalidate];
	disarmTimer = nil;
	if (armed != LWButtonNone) {
		armed = LWButtonNone;
		[self setNeedsDisplay: YES];
	}
}

/* --- keyboard (as the fields' delegate) ---------------------------- */

/*
 * GNUstep's field editor ends editing on Return itself and sends the
 * field's action, so Return logs in from here. Tab only moves on.
 */
- (void) fieldAction: (id)sender
{
	NSEvent *e = [NSApp currentEvent];

	if ([e type] == NSKeyDown || [e type] == NSKeyUp) {
		NSString *c = [e charactersIgnoringModifiers];

		if ([c length] > 0 && ([c characterAtIndex: 0] == '\r' ||
		    [c characterAtIndex: 0] == 3)) {
			[self disarm];
			[delegate panelLogIn: self];
		}
	}
}

- (BOOL) control: (NSControl *)c textView: (NSTextView *)tv
    doCommandBySelector: (SEL)sel
{
	if (sel == @selector(insertNewline:)) {
		[self disarm];
		[delegate panelLogIn: self];
		return (YES);
	}
	if (sel == @selector(cancelOperation:) || sel == @selector(complete:)) {
		[self disarm];
		return (YES);
	}
	return (NO);
}

- (void) controlTextDidChange: (NSNotification *)n
{
	[self disarm];
}

- (void) controlTextDidBeginEditing: (NSNotification *)n
{
	[self setNeedsDisplay: YES];
}

- (void) controlTextDidEndEditing: (NSNotification *)n
{
	[self setNeedsDisplay: YES];
}

/* --- state --------------------------------------------------------- */

- (void) reset
{
	[shakeTimer invalidate];
	shakeTimer = nil;
	[self setFrameOrigin: home];
	[self disarm];
	[nameField setStringValue: @""];
	[passwordField setStringValue: @""];
	[[self window] makeFirstResponder: nameField];
	[[self superview] setNeedsDisplay: YES];
}

- (void) shake: (NSTimer *)t
{
	static const int offsets[] = { -14, 14, -11, 11, -7, 7, -3, 3, 0 };

	if (shakeStep >= (int)(sizeof(offsets) / sizeof(offsets[0]))) {
		[shakeTimer invalidate];
		shakeTimer = nil;
		[self setFrameOrigin: home];
	} else {
		[self setFrameOrigin: NSMakePoint(home.x + offsets[shakeStep++],
		    home.y)];
	}
	[[self superview] setNeedsDisplay: YES];
}

- (void) rejectPassword
{
	[passwordField setStringValue: @""];
	if ([[nameField stringValue] length] > 0)
		[[self window] makeFirstResponder: passwordField];
	else
		[[self window] makeFirstResponder: nameField];
	[shakeTimer invalidate];
	shakeStep = 0;
	shakeTimer = [NSTimer scheduledTimerWithTimeInterval: 0.035
	    target: self selector: @selector(shake:) userInfo: nil
	    repeats: YES];
}

@end
