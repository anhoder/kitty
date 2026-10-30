/*
 * cocoa_window.m
 * Copyright (C) 2017 Kovid Goyal <kovid at kovidgoyal.net>
 *
 * Distributed under terms of the GPL3 license.
 */


#include "state.h"
#include "cleanup.h"
#include "cocoa_window.h"
#include "crypto.h"
#include <Availability.h>
#include <Carbon/Carbon.h>
#include <Cocoa/Cocoa.h>
#import <IOKit/IOKitLib.h>
#include <UserNotifications/UserNotifications.h>
#import <AudioToolbox/AudioServices.h>
#include <Security/Security.h>

#include <AvailabilityMacros.h>
// Needed for _NSGetProgname
#include <crt_externs.h>
#include <objc/runtime.h>

static inline void
cleanup_cfrelease(void *__p) {
    CFTypeRef *tp = (CFTypeRef *)__p;
    CFTypeRef cf = *tp;
    if (cf) { CFRelease(cf); }
}
#define RAII_CoreFoundation(type, name, initializer) __attribute__((cleanup(cleanup_cfrelease))) type name = initializer

#if (MAC_OS_X_VERSION_MAX_ALLOWED < 101300)
#define NSControlStateValueOn NSOnState
#define NSControlStateValueOff NSOffState
#define NSControlStateValueMixed NSMixedState
#endif
#if (MAC_OS_X_VERSION_MAX_ALLOWED < 101200)
#define NSWindowStyleMaskResizable NSResizableWindowMask
#define NSEventModifierFlagOption NSAlternateKeyMask
#define NSEventModifierFlagCommand NSCommandKeyMask
#define NSEventModifierFlagControl NSControlKeyMask
#endif
#if (MAC_OS_X_VERSION_MAX_ALLOWED < 110000)
#define UNNotificationPresentationOptionList (1 << 3)
#define UNNotificationPresentationOptionBanner (1 << 4)
#endif

typedef int CGSConnectionID;
typedef int CGSWindowID;
typedef int CGSWorkspaceID;
typedef enum _CGSSpaceSelector { kCGSSpaceCurrent = 5, kCGSSpaceAll = 7 } CGSSpaceSelector;
extern CGSConnectionID _CGSDefaultConnection(void);
CFArrayRef CGSCopySpacesForWindows(CGSConnectionID Connection, CGSSpaceSelector Type, CFArrayRef Windows);

static NSMenuItem *title_menu = NULL;

static const void *kitty_agents_sidebar_key = &kitty_agents_sidebar_key;
static const void *kitty_agents_sidebar_toggle_key = &kitty_agents_sidebar_toggle_key;

static void draw_agents_sidebar_icon(NSRect rect) {
    CGFloat inset = MAX(1.0, MIN(rect.size.width, rect.size.height) * 0.12);
    NSRect outline_rect = NSInsetRect(rect, inset, inset);
    NSBezierPath *outline = [NSBezierPath bezierPathWithRoundedRect:outline_rect xRadius:2.0 yRadius:2.0];
    outline.lineWidth = 1.35;
    [outline stroke];
    CGFloat divider_x = NSMinX(outline_rect) + outline_rect.size.width * 0.34;
    NSBezierPath *divider = [NSBezierPath bezierPath];
    [divider moveToPoint:NSMakePoint(divider_x, NSMinY(outline_rect))];
    [divider lineToPoint:NSMakePoint(divider_x, NSMaxY(outline_rect))];
    [divider stroke];
    CGFloat line_start = divider_x + 2.5;
    CGFloat line_end = NSMaxX(outline_rect) - 2.5;
    for (NSUInteger i = 0; i < 3; i++) {
        CGFloat y = NSMinY(outline_rect) + 4.0 + i * 3.0;
        NSBezierPath *line = [NSBezierPath bezierPath];
        [line moveToPoint:NSMakePoint(line_start, y)];
        [line lineToPoint:NSMakePoint(line_end, y)];
        [line stroke];
    }
}


@interface KittyAgentsSidebarToggleButton : NSButton
@end

@implementation KittyAgentsSidebarToggleButton
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    (void)event;
    return YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    BOOL expanded = self.state == NSControlStateValueOn;
    NSRect rect = NSInsetRect(self.bounds, 0.5, 0.5);
    NSBezierPath *background = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:7.0 yRadius:7.0];
    NSColor *fill = expanded ? [NSColor selectedContentBackgroundColor] : [NSColor controlBackgroundColor];
    [[fill colorWithAlphaComponent:self.highlighted ? 1.0 : 0.92] setFill];
    [background fill];
    [[NSColor separatorColor] setStroke];
    [background stroke];

    NSColor *foreground = expanded ? [NSColor alternateSelectedControlTextColor] : [NSColor labelColor];
    [foreground setStroke];
    draw_agents_sidebar_icon(NSMakeRect(5.0, (self.bounds.size.height - 18.0) / 2.0, 18.0, 18.0));
    CGFloat center_x = self.bounds.size.width - 10.0;
    CGFloat center_y = NSMidY(self.bounds);
    CGFloat direction = expanded ? -1.0 : 1.0;
    NSBezierPath *chevron = [NSBezierPath bezierPath];
    chevron.lineWidth = 1.5;
    chevron.lineCapStyle = NSLineCapStyleRound;
    chevron.lineJoinStyle = NSLineJoinStyleRound;
    [chevron moveToPoint:NSMakePoint(center_x - direction * 2.0, center_y - 3.5)];
    [chevron lineToPoint:NSMakePoint(center_x + direction * 2.0, center_y)];
    [chevron lineToPoint:NSMakePoint(center_x - direction * 2.0, center_y + 3.5)];
    [chevron stroke];
}
@end

static void agents_sidebar_update_toggle_state(NSButton *button, BOOL visible) {
    if (!button) return;
    NSString *verb = visible ? @"Hide" : @"Show";
    button.toolTip = [NSString stringWithFormat:@"%@ Agents sidebar", verb];
    button.accessibilityValue = visible ? @"Visible" : @"Hidden";
    button.accessibilityHelp = [NSString stringWithFormat:@"%@ the Agents sidebar", verb];
    button.state = visible ? NSControlStateValueOn : NSControlStateValueOff;
    [button setNeedsDisplay:YES];
}

static void agents_sidebar_toggle_button_pressed(id sender) {
    (void)sender;
    set_cocoa_pending_action(AGENTS_SIDEBAR_TOGGLE, NULL);
}

static NSButton *agents_sidebar_toggle_button(NSWindow *window) {
    if (!window) return nil;
    NSButton *button = objc_getAssociatedObject(window, kitty_agents_sidebar_toggle_key);
    if (button) return button;
    if (!(window.styleMask & NSWindowStyleMaskTitled)) return nil;
    NSButton *standard = [window standardWindowButton:NSWindowCloseButton];
    NSView *container = standard.superview;
    if (!container) return nil;
    button = [KittyAgentsSidebarToggleButton buttonWithTitle:@"Agents sidebar" target:window action:@selector(agentsSidebarToggleFromTitlebar:)];
    button.bordered = NO;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.identifier = @"kitty-agents-sidebar-toggle";
    button.accessibilityRole = NSAccessibilityButtonRole;
    button.accessibilityLabel = @"Agents sidebar";
    [container addSubview:button positioned:NSWindowAbove relativeTo:nil];
    [NSLayoutConstraint activateConstraints:@[
        [button.leadingAnchor constraintEqualToAnchor:standard.trailingAnchor constant:10.0],
        [button.centerYAnchor constraintEqualToAnchor:standard.centerYAnchor],
        [button.widthAnchor constraintEqualToConstant:44.0],
        [button.heightAnchor constraintEqualToConstant:28.0],
    ]];
    agents_sidebar_update_toggle_state(button, NO);
    objc_setAssociatedObject(window, kitty_agents_sidebar_toggle_key, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return button;
}

void
cocoa_initialize_agents_sidebar_toggle(void *ptr) {
    NSWindow *window = (NSWindow *)ptr;
    NSButton *button = agents_sidebar_toggle_button(window);
    button.hidden = NO;
    agents_sidebar_update_toggle_state(button, NO);
}

@interface NSWindow (KittyAgentsSidebarToggle)
- (void)agentsSidebarToggleFromTitlebar:(id)sender;
@end

@implementation NSWindow (KittyAgentsSidebarToggle)
- (void)agentsSidebarToggleFromTitlebar:(id)sender {
    (void)sender;
    agents_sidebar_toggle_button_pressed(self);
}
@end
@interface KittyAgentsSidebarView : NSView {
    unsigned os_window_id;
    NSArray<NSString *> *groups;
    NSArray<NSString *> *agents;
    NSArray<NSString *> *labels;
    NSArray<NSString *> *details;
    NSArray<NSNumber *> *states;
    NSArray<NSNumber *> *active_rows;
    CGFloat header_height;
    CGFloat group_height;
    CGFloat row_height;
    NSTimer *spinner_timer;
    CGFloat spinner_phase;
    NSVisualEffectView *background_view;
    unsigned cell_width_pixels;
    BOOL resizing;
    BOOL resizing_width;
    NSTrackingArea *sidebar_tracking_area;
}
- (instancetype)initWithOSWindowID:(unsigned)window_id width:(CGFloat)width cellWidth:(unsigned)cell_width;
- (void)setRows:(const char **)new_groups agents:(const char **)new_agents labels:(const char **)new_labels details:(const char **)new_details states:(const unsigned char *)new_states active:(const bool *)active count:(size_t)count;
- (NSVisualEffectView *)backgroundView;
- (void)stopAnimating;
- (void)advanceSpinner:(NSTimer *)timer;
- (BOOL)isAnimating;
@end

@implementation KittyAgentsSidebarView
- (instancetype)initWithOSWindowID:(unsigned)window_id width:(CGFloat)width cellWidth:(unsigned)cell_width {
    self = [super initWithFrame:NSMakeRect(0, 0, width, 100)];
    if (self) {
        os_window_id = window_id;
        cell_width_pixels = MAX(1u, cell_width);
        resizing = NO;
        resizing_width = NO;
        groups = [[NSArray alloc] init];
        agents = [[NSArray alloc] init];
        labels = [[NSArray alloc] init];
        details = [[NSArray alloc] init];
        states = [[NSArray alloc] init];
        active_rows = [[NSArray alloc] init];
        header_height = 40.0;
        group_height = 24.0;
        row_height = 48.0;
        spinner_timer = nil;
        spinner_phase = 0.0;
        // The translucent sidebar material has to sit behind the rows, but a
        // view's own drawRect paints *beneath* its subviews, so hosting the
        // material as a subview here would hide every row we draw. Keep it in
        // a sibling layer underneath instead.
        NSVisualEffectView *effect = [[NSVisualEffectView alloc] initWithFrame:self.bounds];
        effect.autoresizingMask = NSViewNotSizable;
        effect.material = NSVisualEffectMaterialSidebar;
        effect.blendingMode = NSVisualEffectBlendingModeBehindWindow;
        effect.state = NSVisualEffectStateActive;
        background_view = effect;
        NSTrackingAreaOptions options = NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved | NSTrackingActiveAlways | NSTrackingEnabledDuringMouseDrag | NSTrackingCursorUpdate | NSTrackingInVisibleRect;
        sidebar_tracking_area = [[NSTrackingArea alloc] initWithRect:self.bounds options:options owner:self userInfo:nil];
        [self addTrackingArea:sidebar_tracking_area];
        self.identifier = @"kitty-agents-sidebar";
        self.autoresizingMask = NSViewHeightSizable;
    }
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return NO; }
- (NSVisualEffectView *)backgroundView { return background_view; }

- (NSView *)hitTest:(NSPoint)point {
    NSPoint local = [self convertPoint:point fromView:self.superview];
    if (!NSPointInRect(local, self.bounds)) return nil;
    return self;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    (void)event;
    return YES;
}

- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    [background_view setFrame:self.frame];
    [self.window invalidateCursorRectsForView:self];
    [self setNeedsDisplay:YES];
}

- (void)previewSizeWidth:(CGFloat)width {
    NSRect frame = self.frame;
    frame.size.width = width;
    frame.size.height = self.superview ? self.superview.bounds.size.height : frame.size.height;
    frame.origin.y = 0;
    [self setFrame:frame];
    [background_view setFrame:frame];
    [self resetCursorRects];
    [self setNeedsDisplay:YES];
}

- (void)resetCursorRects {
    [super resetCursorRects];
    const CGFloat edge = 8.0;
    if (self.bounds.size.width > edge) {
        [self addCursorRect:NSMakeRect(self.bounds.size.width - edge, 0, edge, self.bounds.size.height) cursor:[NSCursor resizeLeftRightCursor]];
    }
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (p.x >= self.bounds.size.width - 8.0) {
        resizing = YES;
        resizing_width = YES;
        return;
    }
    NSString *last_group = nil;
    CGFloat y = header_height;
    for (NSUInteger i = 0; i < labels.count; i++) {
        NSString *group = groups[i];
        if (!last_group || ![last_group isEqualToString:group]) {
            y += group_height;
            last_group = group;
        }
        if (p.y >= y && p.y < y + row_height) {
            char data[64];
            snprintf(data, sizeof(data), "%u:%lu", os_window_id, (unsigned long)i);
            set_cocoa_pending_action(AGENTS_SIDEBAR_CLICK, data);
            return;
        }
        y += row_height;
    }
}

- (void)mouseMoved:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (p.x >= self.bounds.size.width - 8.0) [[NSCursor resizeLeftRightCursor] set];
    else [[NSCursor arrowCursor] set];
}

- (void)mouseEntered:(NSEvent *)event { [self mouseMoved:event]; }
- (void)cursorUpdate:(NSEvent *)event { [self mouseMoved:event]; }
- (void)mouseExited:(NSEvent *)event {
    (void)event;
    if (!resizing) [[NSCursor arrowCursor] set];
}

- (void)mouseDragged:(NSEvent *)event {
    if (!resizing || !self.superview) return;
    CGFloat scale = MAX(1.0, self.window.backingScaleFactor);
    NSPoint p = [self.superview convertPoint:event.locationInWindow fromView:nil];
    CGFloat min_width = 16.0 * cell_width_pixels / scale;
    CGFloat max_width = self.superview.bounds.size.width * 0.75;
    CGFloat width = MIN(max_width, MAX(min_width, p.x));
    unsigned cols = MAX(16u, (unsigned)llround(width * scale / (CGFloat)cell_width_pixels));
    width = cols * cell_width_pixels / scale;
    [self previewSizeWidth:width];
    char data[64];
    snprintf(data, sizeof(data), "%u:%u", os_window_id, cols);
    set_cocoa_pending_action(AGENTS_SIDEBAR_RESIZE, data);
}

- (void)mouseUp:(NSEvent *)event {
    (void)event;
    resizing = NO;
    resizing_width = NO;
    [self resetCursorRects];
}
- (void)setRows:(const char **)new_groups agents:(const char **)new_agents labels:(const char **)new_labels details:(const char **)new_details states:(const unsigned char *)new_states active:(const bool *)active count:(size_t)count {
    NSMutableArray *next_groups = [NSMutableArray arrayWithCapacity:count];
    NSMutableArray *next_agents = [NSMutableArray arrayWithCapacity:count];
    NSMutableArray *next_labels = [NSMutableArray arrayWithCapacity:count];
    NSMutableArray *next_details = [NSMutableArray arrayWithCapacity:count];
    NSMutableArray *next_states = [NSMutableArray arrayWithCapacity:count];
    NSMutableArray *next_active = [NSMutableArray arrayWithCapacity:count];
    for (size_t i = 0; i < count; i++) {
        [next_groups addObject:[NSString stringWithUTF8String:new_groups[i] ? new_groups[i] : ""]];
        [next_agents addObject:[NSString stringWithUTF8String:new_agents[i] ? new_agents[i] : ""]];
        [next_labels addObject:[NSString stringWithUTF8String:new_labels[i] ? new_labels[i] : ""]];
        [next_details addObject:[NSString stringWithUTF8String:new_details[i] ? new_details[i] : ""]];
        [next_states addObject:@(new_states ? new_states[i] : 0)];
        [next_active addObject:@(active && active[i])];
    }
    [groups release];
    [agents release];
    [labels release];
    [details release];
    [states release];
    [active_rows release];
    groups = [next_groups copy];
    agents = [next_agents copy];
    labels = [next_labels copy];
    details = [next_details copy];
    states = [next_states copy];
    active_rows = [next_active copy];
    [self updateAnimationState];
    // Everything is painted in drawRect. There used to be a parallel set of
    // NSTextField subviews drawing the same text on top of it, which hid the
    // state indicator, the spinner and the agent icon underneath them.
    [self setNeedsDisplay:YES];
}

- (NSColor *)stateColor:(NSUInteger)state active:(BOOL)active {
    if (active && state == 1) return [NSColor alternateSelectedControlTextColor];
    switch (state) {
        case 2: return [NSColor systemOrangeColor];
        case 3: return [NSColor systemRedColor];
        case 4: return [NSColor systemGreenColor];
        default: return [NSColor secondaryLabelColor];
    }
}

- (NSColor *)stateTextColor:(NSUInteger)state active:(BOOL)active {
    // Keep idle readable on the selected blue row; active working/blocked/done
    // rows retain their semantic colors instead of collapsing to white.
    return [self stateColor:state active:active];
}

// The spinner only runs while some row is working. A sidebar full of idle
// agents must not keep waking the CPU.
- (BOOL)hasWorkingRow {
    for (NSUInteger i = 0; i < states.count; i++) {
        if ([states[i] unsignedIntegerValue] == 2) return YES;
    }
    return NO;
}

- (BOOL)isAnimating { return spinner_timer != nil; }

- (void)updateAnimationState {
    BOOL want = [self hasWorkingRow] && self.window != nil;
    if (want && !spinner_timer) {
        spinner_timer = [NSTimer timerWithTimeInterval:(1.0 / 30.0) target:self selector:@selector(advanceSpinner:) userInfo:nil repeats:YES];
        // Common run loop modes, so the spinner keeps turning during a live
        // resize or a menu tracking loop instead of freezing mid-arc.
        [[NSRunLoop currentRunLoop] addTimer:spinner_timer forMode:NSRunLoopCommonModes];
    } else if (!want && spinner_timer) {
        [self stopAnimating];
    }
}

- (void)advanceSpinner:(NSTimer *)timer {
    (void)timer;
    spinner_phase += 1.0 / 30.0;
    if (spinner_phase > 1.0e6) spinner_phase = 0.0;
    [self setNeedsDisplay:YES];
}

- (void)stopAnimating {
    [spinner_timer invalidate];
    spinner_timer = nil;
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    // Leaving a window orphans the run loop source; re-evaluate either way.
    [self updateAnimationState];
}

// An indeterminate arc, the platform idiom for "running, length unknown".
- (void)drawSpinnerInRect:(NSRect)rect color:(NSColor *)color {
    const CGFloat line_width = 1.8;
    NSPoint center = NSMakePoint(NSMidX(rect), NSMidY(rect));
    CGFloat radius = (MIN(rect.size.width, rect.size.height) - line_width) / 2.0;
    if (radius <= 0) return;
    CGFloat revolutions_per_second = 0.9;
    CGFloat start = -fmod(spinner_phase * revolutions_per_second, 1.0) * 360.0;
    [[color colorWithAlphaComponent:0.25] setStroke];
    NSBezierPath *track = [NSBezierPath bezierPath];
    track.lineWidth = line_width;
    [track appendBezierPathWithArcWithCenter:center radius:radius startAngle:0 endAngle:360];
    [track stroke];
    [color setStroke];
    NSBezierPath *arc = [NSBezierPath bezierPath];
    arc.lineWidth = line_width;
    arc.lineCapStyle = NSLineCapStyleRound;
    [arc appendBezierPathWithArcWithCenter:center radius:radius startAngle:start endAngle:start - 100.0 clockwise:YES];
    [arc stroke];
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    // No background fill here: the NSVisualEffectView sibling underneath
    // provides the sidebar material, and painting over it would throw away
    // the translucency it exists for.

    NSUInteger visible_count = 0;
    for (NSString *agent in agents) if (agent.length) visible_count++;
    NSDictionary *header_attrs = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:11.0],
        NSForegroundColorAttributeName: [NSColor secondaryLabelColor],
    };
    NSString *header = visible_count ? [NSString stringWithFormat:@"AGENTS  %lu", (unsigned long)visible_count] : @"AGENTS";
    NSRect header_rect = NSMakeRect(12.0, 13.0, MAX(0.0, self.bounds.size.width - 24.0), 18.0);
    [header drawWithRect:header_rect options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine attributes:header_attrs context:nil];
    [[NSColor separatorColor] setFill];
    NSRectFill(NSMakeRect(0, header_height - 1.0, self.bounds.size.width, 1.0));

    NSString *last_group = nil;
    CGFloat y = header_height;
    for (NSUInteger i = 0; i < labels.count; i++) {
        NSString *group = groups[i];
        if (!last_group || ![last_group isEqualToString:group]) {
            NSDictionary *group_attrs = @{
                NSFontAttributeName: [NSFont systemFontOfSize:11.0],
                NSForegroundColorAttributeName: [NSColor secondaryLabelColor],
            };
            [group drawAtPoint:NSMakePoint(12.0, y + 5.0) withAttributes:group_attrs];
            y += group_height;
            last_group = group;
        }
        BOOL active = [active_rows[i] boolValue];
        NSRect row = NSMakeRect(0, y, self.bounds.size.width, row_height);
        if (active) {
            // Inset rounded capsule, matching how macOS sidebars mark the
            // selected row, instead of a full-bleed rectangle.
            NSRect pill = NSInsetRect(row, 6.0, 2.0);
            [[NSColor selectedContentBackgroundColor] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:pill xRadius:6.0 yRadius:6.0] fill];
        }
        NSColor *primary_color = active ? [NSColor alternateSelectedControlTextColor] : [NSColor controlTextColor];
        NSColor *detail_color = active ? [[NSColor alternateSelectedControlTextColor] colorWithAlphaComponent:0.72] : [NSColor secondaryLabelColor];
        BOOL has_agent = i < agents.count && agents[i].length > 0;
        NSUInteger row_state = [states[i] unsignedIntegerValue];
        NSColor *state_color = [self stateColor:row_state active:active];
        // The "No AI agents" placeholder uses an empty agent id. It is not a
        // state-bearing row, so do not render a misleading unknown-state dot.
        const CGFloat indicator_center = 14.0, text_left = 26.0;
        CGFloat row_center = row.origin.y + row_height / 2.0;
        if (has_agent) {
            if (row_state == 2) {
                [self drawSpinnerInRect:NSMakeRect(indicator_center - 5.5, row_center - 5.5, 11.0, 11.0) color:state_color];
            } else {
                [state_color setFill];
                NSRect dot = NSMakeRect(indicator_center - 4.0, row_center - 4.0, 8.0, 8.0);
                [[NSBezierPath bezierPathWithOvalInRect:dot] fill];
            }
        }
        NSDictionary *primary_attrs = @{
            NSFontAttributeName: [NSFont boldSystemFontOfSize:12.0],
            NSForegroundColorAttributeName: primary_color,
        };
        NSDictionary *detail_attrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:10.0],
            NSForegroundColorAttributeName: detail_color,
        };
        // Keep the directory subdued, but make the state itself prominent and
        // semantically colored. Details use "cwd · state" today; if a future
        // row has no separator, it remains a normal one-color detail string.
        NSMutableAttributedString *detail_text = [[[NSMutableAttributedString alloc] initWithString:details[i] attributes:detail_attrs] autorelease];
        NSRange separator = [details[i] rangeOfString:@" · " options:NSBackwardsSearch];
        if (separator.location != NSNotFound) {
            NSUInteger state_start = NSMaxRange(separator);
            NSRange state_range = NSMakeRange(state_start, details[i].length - state_start);
            [detail_text addAttributes:@{
                NSFontAttributeName: [NSFont boldSystemFontOfSize:10.5],
                NSForegroundColorAttributeName: [self stateTextColor:row_state active:active],
            } range:state_range];
        }
        // Use line-fragment drawing rather than baseline placement. The
        // previous drawWithRect call omitted this flag, so AppKit positioned
        // the glyphs against the rect baseline and the two-line block looked
        // too high inside the selected row.
        const CGFloat primary_h = 17.0, detail_h = 14.0, gap = 1.0;
        CGFloat text_top = row_center - (primary_h + gap + detail_h) / 2.0;
        CGFloat text_width = row.size.width - text_left - 10.0;
        NSRect primary_rect = NSMakeRect(text_left, text_top, text_width, primary_h);
        NSRect detail_rect = NSMakeRect(text_left, text_top + primary_h + gap, text_width, detail_h);
        NSStringDrawingOptions text_options = NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading | NSStringDrawingTruncatesLastVisibleLine;
        [labels[i] drawWithRect:primary_rect options:text_options attributes:primary_attrs context:nil];
        [detail_text drawWithRect:detail_rect options:text_options context:nil];
        y += row_height;
    }
}


- (void)dealloc {
    [self stopAnimating];
    [self removeTrackingArea:sidebar_tracking_area];
    [sidebar_tracking_area release];
    [groups release];
    [agents release];
    [labels release];
    [details release];
    [states release];
    [active_rows release];
    [background_view release];
    [super dealloc];
}
@end

void
cocoa_set_agents_sidebar(void *ptr, unsigned os_window_id, bool enabled, unsigned width_pixels, unsigned cell_width, const char **groups, const char **agents, const char **labels, const char **details, const unsigned char *states, const bool *active, size_t count) {
    NSWindow *window = (NSWindow *)ptr;
    if (!window || !window.contentView) return;
    NSButton *toggle_button = agents_sidebar_toggle_button(window);
    toggle_button.hidden = NO;
    agents_sidebar_update_toggle_state(toggle_button, enabled);
    if (!enabled) {
        KittyAgentsSidebarView *sidebar = objc_getAssociatedObject(window, kitty_agents_sidebar_key);
        [sidebar stopAnimating];
        [[sidebar backgroundView] removeFromSuperview];
        [sidebar removeFromSuperview];
        objc_setAssociatedObject(window, kitty_agents_sidebar_key, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    CGFloat scale = MAX(1.0, window.backingScaleFactor);
    CGFloat width = width_pixels / scale;
    KittyAgentsSidebarView *sidebar = objc_getAssociatedObject(window, kitty_agents_sidebar_key);
    if (!sidebar) {
        sidebar = [[KittyAgentsSidebarView alloc] initWithOSWindowID:os_window_id width:width cellWidth:cell_width];
        [window.contentView addSubview:sidebar positioned:NSWindowAbove relativeTo:nil];
        [window.contentView addSubview:[sidebar backgroundView] positioned:NSWindowBelow relativeTo:sidebar];
        objc_setAssociatedObject(window, kitty_agents_sidebar_key, sidebar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [sidebar release];
    }
    NSRect frame = NSMakeRect(0, 0, width, window.contentView.bounds.size.height);
    [sidebar setFrame:frame];
    [[sidebar backgroundView] setFrame:frame];
    [sidebar setRows:groups agents:agents labels:labels details:details states:states active:active count:count];
}

static NSMenuItem *secure_input_title_menu = NULL;


static NSString *
find_app_name(void) {
    size_t i;
    NSDictionary *infoDictionary = [[NSBundle mainBundle] infoDictionary];

    // Keys to search for as potential application names
    NSString *name_keys[] = {
        @"CFBundleDisplayName",
        @"CFBundleName",
        @"CFBundleExecutable",
    };

    for (i = 0; i < sizeof(name_keys) / sizeof(name_keys[0]); i++) {
        id name = infoDictionary[name_keys[i]];
        if (name && [name isKindOfClass:[NSString class]] && ![name isEqualToString:@""]) { return name; }
    }

    char **progname = _NSGetProgname();
    if (progname && *progname) return @(*progname);

    // Really shouldn't get here
    return @"kitty";
}

#define debug_key(...)                \
    if (OPT(debug_keyboard)) {        \
        fprintf(stderr, __VA_ARGS__); \
        fflush(stderr);               \
    }

// SecureKeyboardEntryController {{{
@interface SecureKeyboardEntryController : NSObject

@property(nonatomic, readonly) BOOL isDesired;
@property(nonatomic, readonly, getter=isEnabled) BOOL enabled;

+ (instancetype)sharedInstance;

- (void)toggle;
- (void)update;

@end

@implementation SecureKeyboardEntryController {
    int _count;
    BOOL _desired;
}

+ (instancetype)sharedInstance {
    static id instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _desired = false;

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationDidResignActive:)
                                                     name:NSApplicationDidResignActiveNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationDidBecomeActive:)
                                                     name:NSApplicationDidBecomeActiveNotification
                                                   object:nil];
        if ([NSApp isActive]) { [self update]; }
    }
    return self;
}

#pragma mark - API

- (void)toggle {
    // Set _desired to the opposite of the current state.
    _desired = !_desired;
    debug_key("SecureKeyboardEntry: toggle called. Setting desired to %d ", _desired);

    // Try to set the system's state of secure input to the desired state.
    [self update];
}

- (BOOL)isEnabled {
    return !!IsSecureEventInputEnabled();
}

- (BOOL)isDesired {
    return _desired;
}

#pragma mark - Notifications

- (void)applicationDidResignActive:(NSNotification *)notification {
    (void)notification;
    if (_count > 0) {
        debug_key("SecureKeyboardEntry: Application resigning active.");
        [self update];
    }
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    (void)notification;
    if (self.isDesired) {
        debug_key("SecureKeyboardEntry: Application became active.");
        [self update];
    }
}

#pragma mark - Private

- (BOOL)allowed {
    return [NSApp isActive];
}

- (void)update {
    debug_key("Update secure keyboard entry. desired=%d active=%d\n", (int)self.isDesired, (int)[NSApp isActive]);
    const BOOL secure = self.isDesired && [self allowed];

    if (secure && _count > 0) {
        debug_key("Want to turn on secure input but it's already on\n");
        return;
    }

    if (!secure && _count == 0) {
        debug_key("Want to turn off secure input but it's already off\n");
        return;
    }

    debug_key("Before: IsSecureEventInputEnabled returns %d ", (int)self.isEnabled);
    if (secure) {
        OSErr err = EnableSecureEventInput();
        debug_key("EnableSecureEventInput err=%d ", (int)err);
        if (err) {
            debug_key("EnableSecureEventInput failed with error %d ", (int)err);
        } else {
            _count += 1;
        }
    } else {
        OSErr err = DisableSecureEventInput();
        debug_key("DisableSecureEventInput err=%d ", (int)err);
        if (err) {
            debug_key("DisableSecureEventInput failed with error %d ", (int)err);
        } else {
            _count -= 1;
        }
    }
    debug_key("After: IsSecureEventInputEnabled returns %d\n", (int)self.isEnabled);
}

@end
// }}}

static void
update_secure_input_menu_bar_indicator(BOOL enabled) {
    if (enabled) {
        if (secure_input_title_menu == NULL) {
            NSMenu *bar = [NSApp mainMenu];
            secure_input_title_menu = [bar addItemWithTitle:@"" action:NULL keyEquivalent:@""];
            NSMenu *m = [[NSMenu alloc] initWithTitle:@"[Secure input]"];
            [secure_input_title_menu setSubmenu:m];
            [m release];
        }
    } else {
        if (secure_input_title_menu != NULL) {
            NSMenu *bar = [NSApp mainMenu];
            [bar removeItem:secure_input_title_menu];
            secure_input_title_menu = NULL;
        }
    }
}

@interface UserMenuItem : NSMenuItem
@property(nonatomic) size_t action_index;
@end

@implementation UserMenuItem {
}
@end

@interface WindowMenuDelegate : NSObject <NSMenuDelegate>
@end

@implementation WindowMenuDelegate
- (void)menuNeedsUpdate:(NSMenu *)menu {
    // AppKit injects selectPreviousTab:, selectNextTab:, moveTabToNewWindow:,
    // toggleTabOverview: when allowsAutomaticWindowTabbing=YES (we need it YES
    // for mergeAllWindows:/toggleTabBar: to work). Remove those injected
    // duplicates; kitty has its own versions with shortcuts from kitty.conf.
    static const char *injected[] = {"selectPreviousTab:", "selectNextTab:", "moveTabToNewWindow:", "toggleTabOverview:"};
    NSMutableArray<NSMenuItem *> *to_remove = [NSMutableArray array];
    for (NSMenuItem *item in menu.itemArray) {
        if (!item.action) continue;
        const char *sel_name = sel_getName(item.action);
        for (size_t i = 0; i < arraysz(injected); i++) {
            if (strcmp(sel_name, injected[i]) == 0) {
                [to_remove addObject:item];
                break;
            }
        }
    }
    for (NSMenuItem *item in to_remove) [menu removeItem:item];
}
@end


@interface GlobalMenuTarget : NSObject
+ (GlobalMenuTarget *)shared_instance;
@end

#define PENDING(selector, which)               \
    -(void)selector : (id)sender {             \
        (void)sender;                          \
        set_cocoa_pending_action(which, NULL); \
    }

@implementation GlobalMenuTarget

- (void)user_menu_action:(id)sender {
    UserMenuItem *m = sender;
    if (m.action_index < OPT(global_menu).count && OPT(global_menu.entries)) {
        set_cocoa_pending_action(USER_MENU_ACTION, OPT(global_menu).entries[m.action_index].definition);
    }
}

PENDING(edit_config_file, PREFERENCES_WINDOW)
PENDING(new_os_window, NEW_OS_WINDOW)
PENDING(detach_tab, DETACH_TAB)
PENDING(close_os_window, CLOSE_OS_WINDOW)
PENDING(close_tab, CLOSE_TAB)
PENDING(new_tab, NEW_TAB)
PENDING(next_tab, NEXT_TAB)
PENDING(previous_tab, PREVIOUS_TAB)
PENDING(new_window, NEW_WINDOW)
PENDING(close_window, CLOSE_WINDOW)
PENDING(reset_terminal, RESET_TERMINAL)
PENDING(clear_terminal_and_scrollback, CLEAR_TERMINAL_AND_SCROLLBACK)
PENDING(clear_scrollback, CLEAR_SCROLLBACK)
PENDING(clear_screen, CLEAR_SCREEN)
PENDING(clear_last_command, CLEAR_LAST_COMMAND)
PENDING(reload_config, RELOAD_CONFIG)
PENDING(toggle_macos_secure_keyboard_entry, TOGGLE_MACOS_SECURE_KEYBOARD_ENTRY)
PENDING(macos_cycle_through_os_windows, MACOS_CYCLE_THROUGH_OS_WINDOWS)
PENDING(macos_cycle_through_os_windows_backwards, MACOS_CYCLE_THROUGH_OS_WINDOWS_BACKWARDS)
PENDING(toggle_macos_tab_overview, TOGGLE_MACOS_TAB_OVERVIEW)
PENDING(search_scrollback, SEARCH_SCROLLBACK)
PENDING(toggle_fullscreen, TOGGLE_FULLSCREEN)
PENDING(open_kitty_website, OPEN_KITTY_WEBSITE)
PENDING(hide_macos_app, HIDE)
PENDING(hide_macos_other_apps, HIDE_OTHERS)
PENDING(minimize_macos_window, MINIMIZE)
PENDING(quit, QUIT)
PENDING(paste_from_clipboard, PASTE_FROM_CLIPBOARD)
PENDING(copy_or_noop, COPY_OR_NOOP)

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(toggle_macos_secure_keyboard_entry:)) {
        item.state = [SecureKeyboardEntryController sharedInstance].isDesired ? NSControlStateValueOn : NSControlStateValueOff;
    } else if (item.action == @selector(toggle_fullscreen:)) {
        item.title = ([NSApp currentSystemPresentationOptions] & NSApplicationPresentationFullScreen) ? @"Exit Full Screen" : @"Enter Full Screen";
        if (![NSApp keyWindow]) return NO;
    } else if (item.action == @selector(toggle_macos_tab_overview:)) {
        // The overview only exists with native tabs on and at least two tabs
        // in the key window's tab group.
        NSWindow *window = [NSApp keyWindow];
        if (!OPT(macos_native_tabs) || !window || [window tabbedWindows].count < 2) return NO;
    } else if (item.action == @selector(minimize_macos_window:)) {
        NSWindow *window = [NSApp keyWindow];
        if (!window || window.miniaturized || [NSApp currentSystemPresentationOptions] & NSApplicationPresentationFullScreen) return NO;
    } else if (
        item.action == @selector(close_os_window:) || item.action == @selector(close_tab:) || item.action == @selector(close_window:) ||
        item.action == @selector(reset_terminal:) || item.action == @selector(clear_terminal_and_scrollback:) ||
        item.action == @selector(clear_last_command:) || item.action == @selector(clear_scrollback:) || item.action == @selector(clear_screen:) ||
        item.action == @selector(previous_tab:) || item.action == @selector(next_tab:) || item.action == @selector(detach_tab:)) {
        if (![NSApp keyWindow]) return NO;
    } else if (item.action == @selector(paste_from_clipboard:)) {
        if (![NSApp keyWindow]) return NO;
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        if (![pb stringForType:NSPasteboardTypeString]) return NO;
    } else if (item.action == @selector(copy_or_noop:)) {
        if (![NSApp keyWindow]) return NO;
        OSWindow *osw = current_os_window();
        if (osw && osw->num_tabs > osw->active_tab) {
            Tab *tab = osw->tabs + osw->active_tab;
            if (tab->num_windows > tab->active_window) {
                Screen *screen = tab->windows[tab->active_window].render_data.screen;
                if (screen && screen_has_selection(screen)) return YES;
            }
        }
        return NO;
    }
    return YES;
}

#undef PENDING

+ (GlobalMenuTarget *)shared_instance {
    static GlobalMenuTarget *sharedGlobalMenuTarget = nil;
    @synchronized(self) {
        if (!sharedGlobalMenuTarget) {
            sharedGlobalMenuTarget = [[GlobalMenuTarget alloc] init];
            SecureKeyboardEntryController *k = [SecureKeyboardEntryController sharedInstance];
            if (!k.isDesired && [[NSUserDefaults standardUserDefaults] boolForKey:@"SecureKeyboardEntry"]) [k toggle];
            update_secure_input_menu_bar_indicator(k.isDesired);
        }
        return sharedGlobalMenuTarget;
    }
}

@end

typedef struct {
    char key[32];
    NSEventModifierFlags mods;
} GlobalShortcut;
typedef struct {
    GlobalShortcut new_os_window, close_os_window, close_tab, edit_config_file, reload_config;
    GlobalShortcut previous_tab, next_tab, new_tab, new_window, close_window, reset_terminal;
    GlobalShortcut clear_terminal_and_scrollback, clear_screen, clear_scrollback, clear_last_command;
    GlobalShortcut toggle_macos_secure_keyboard_entry, toggle_fullscreen, open_kitty_website;
    GlobalShortcut hide_macos_app, hide_macos_other_apps, minimize_macos_window, quit, search_scrollback;
    GlobalShortcut macos_cycle_through_os_windows, macos_cycle_through_os_windows_backwards;
    GlobalShortcut paste_from_clipboard, copy_or_noop, toggle_macos_tab_overview;
} GlobalShortcuts;
static GlobalShortcuts global_shortcuts;

static PyObject *
cocoa_set_global_shortcut(PyObject *self UNUSED, PyObject *args) {
    int mods;
    unsigned int key;
    const char *name;
    if (!PyArg_ParseTuple(args, "siI", &name, &mods, &key)) return NULL;
    GlobalShortcut *gs = NULL;
#define Q(x) \
    if (strcmp(name, #x) == 0) gs = &global_shortcuts.x
    Q(new_os_window);
    else Q(close_os_window); else Q(close_tab);
    else Q(edit_config_file); else Q(new_tab);
    else Q(next_tab); else Q(previous_tab);
    else Q(new_window); else Q(close_window);
    else Q(reset_terminal); else Q(clear_terminal_and_scrollback);
    else Q(clear_scrollback); else Q(clear_screen);
    else Q(clear_last_command); else Q(reload_config);
    else Q(toggle_macos_secure_keyboard_entry); else Q(toggle_fullscreen);
    else Q(open_kitty_website); else Q(hide_macos_app);
    else Q(hide_macos_other_apps); else Q(minimize_macos_window);
    else Q(quit); else Q(search_scrollback);
    else Q(macos_cycle_through_os_windows); else Q(macos_cycle_through_os_windows_backwards);
    else Q(paste_from_clipboard); else Q(copy_or_noop);
    else Q(toggle_macos_tab_overview);
#undef Q
    if (gs == NULL) {
        PyErr_SetString(PyExc_KeyError, "Unknown shortcut name");
        return NULL;
    }
    int cocoa_mods;
    get_cocoa_key_equivalent(key, mods, gs->key, 32, &cocoa_mods);
    gs->mods = cocoa_mods;
    if (gs->key[0]) Py_RETURN_TRUE;
    Py_RETURN_FALSE;
}

// Implementation of applicationDockMenu: for the app delegate
static NSMenu *dockMenu = nil;
static NSMenu *
get_dock_menu(id self UNUSED, SEL _cmd UNUSED, NSApplication *sender UNUSED) {
    if (!dockMenu) {
        GlobalMenuTarget *global_menu_target = [GlobalMenuTarget shared_instance];
        dockMenu = [[NSMenu alloc] init];
        [[dockMenu addItemWithTitle:@"New OS Window" action:@selector(new_os_window:) keyEquivalent:@""] setTarget:global_menu_target];
    }
    return dockMenu;
}

static PyObject *notification_activated_callback = NULL;

static PyObject *
set_notification_activated_callback(PyObject *self UNUSED, PyObject *callback) {
    Py_CLEAR(notification_activated_callback);
    if (callback != Py_None) notification_activated_callback = Py_NewRef(callback);
    Py_RETURN_NONE;
}

static void
do_notification_callback(const char *identifier, const char *event, const char *action_identifer) {
    if (notification_activated_callback) {
        PyObject *ret =
            PyObject_CallFunction(notification_activated_callback, "sss", event, identifier ? identifier : "", action_identifer ? action_identifer : "");
        if (ret) Py_DECREF(ret);
        else PyErr_Print();
    }
}


@interface NotificationDelegate : NSObject <UNUserNotificationCenterDelegate>
@end

@implementation NotificationDelegate
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    (void)(center);
    (void)notification;
    UNNotificationPresentationOptions options = UNNotificationPresentationOptionSound;
    if (@available(macOS 11.0, *)) options |= UNNotificationPresentationOptionList | UNNotificationPresentationOptionBanner;
    else options |= (1 << 2); // UNNotificationPresentationOptionAlert avoid deprecated warning
    completionHandler(options);
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
    didReceiveNotificationResponse:(UNNotificationResponse *)response
             withCompletionHandler:(void (^)(void))completionHandler {
    (void)(center);
    char *identifier = strdup(response.notification.request.identifier.UTF8String);
    char *action_identifier = strdup(response.actionIdentifier.UTF8String);
    const char *event = "button";
    if ([response.actionIdentifier isEqualToString:UNNotificationDefaultActionIdentifier]) {
        event = "activated";
    } else if ([response.actionIdentifier isEqualToString:UNNotificationDismissActionIdentifier]) {
        // Crapple never actually sends this event on macOS
        event = "closed";
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      do_notification_callback(identifier, event, action_identifier);
      free(identifier);
      free(action_identifier);
    });
    completionHandler();
}
@end

static UNUserNotificationCenter *
get_notification_center_safely(void) {
    NSBundle *b = [NSBundle mainBundle];
    // when bundleIdentifier is nil currentNotificationCenter crashes instead
    // of returning nil. Apple...purveyor of shiny TOYS
    if (!b || !b.bundleIdentifier) return nil;
    UNUserNotificationCenter *center = nil;
    @try {
        center = [UNUserNotificationCenter currentNotificationCenter];
    } @catch (NSException *e) {
        log_error("Failed to get current UNUserNotificationCenter object with error: %s (%s)", [[e name] UTF8String], [[e reason] UTF8String]);
    }
    return center;
}

static bool
ident_in_list_of_notifications(NSString *ident, NSArray<UNNotification *> *list) {
    for (UNNotification *n in list) {
        if ([[[n request] identifier] isEqualToString:ident]) return true;
    }
    return false;
}

void
cocoa_report_live_notifications(const char *ident) {
    do_notification_callback(ident, "live", ident ? ident : "");
}

static bool
remove_delivered_notification(const char *identifier) {
    UNUserNotificationCenter *center = get_notification_center_safely();
    if (!center) return false;
    char *ident = strdup(identifier);
    [center getDeliveredNotificationsWithCompletionHandler:^(NSArray<UNNotification *> *notifications) {
      if (ident_in_list_of_notifications(@(ident), notifications)) { [center removeDeliveredNotificationsWithIdentifiers:@[ @(ident) ]]; }
      free(ident);
    }];
    return true;
}

static bool
live_delivered_notifications(void) {
    UNUserNotificationCenter *center = get_notification_center_safely();
    if (!center) return false;
    [center getDeliveredNotificationsWithCompletionHandler:^(NSArray<UNNotification *> *notifications) {
      @autoreleasepool {
          NSMutableString *buffer = [NSMutableString stringWithCapacity:1024]; // autoreleased
          for (UNNotification *n in notifications) [buffer appendFormat:@"%@,", [[n request] identifier]];
          const char *val = [buffer UTF8String];
          set_cocoa_pending_action(COCOA_NOTIFICATION_UNTRACKED, val ? val : "");
      }
    }];
    return true;
}

static void
schedule_notification(
    const char *appname,
    const char *identifier,
    const char *title,
    const char *body,
    const char *image_path,
    int urgency,
    const char *category_id,
    bool muted) {
    @autoreleasepool {
        UNUserNotificationCenter *center = get_notification_center_safely();
        if (!center) return;
        // Configure the notification's payload.
        UNMutableNotificationContent *content = [[[UNMutableNotificationContent alloc] init] autorelease];
        if (title) content.title = @(title);
        if (body) content.body = @(body);
        if (appname) content.threadIdentifier = @(appname);
        if (category_id) content.categoryIdentifier = @(category_id);
        if (!muted) content.sound = [UNNotificationSound defaultSound];
#if __MAC_OS_X_VERSION_MIN_REQUIRED >= 120000
        switch (urgency) {
            case 0: content.interruptionLevel = UNNotificationInterruptionLevelPassive;
            case 2: content.interruptionLevel = UNNotificationInterruptionLevelCritical;
            default: content.interruptionLevel = UNNotificationInterruptionLevelActive;
        }
#else
        if ([content respondsToSelector:@selector(interruptionLevel)]) {
            NSUInteger level = 1;
            if (urgency == 0) level = 0;
            else if (urgency == 2) level = 3;
            [content setValue:@(level) forKey:@"interruptionLevel"];
        }
#endif
        if (image_path) {
            @try {
                NSError *error;
                NSURL *image_url = [NSURL fileURLWithFileSystemRepresentation:image_path isDirectory:NO relativeToURL:nil]; // autoreleased
                UNNotificationAttachment *attachment = [UNNotificationAttachment attachmentWithIdentifier:@"image"
                                                                                                      URL:image_url
                                                                                                  options:nil
                                                                                                    error:&error]; // autoreleased
                if (attachment) {
                    content.attachments = @[ attachment ];
                } else NSLog(@"Error attaching image %@ to notification: %@", @(image_path), error.localizedDescription);
            } @catch (NSException *exc) { NSLog(@"Creating image attachment %@ for notification failed with error: %@", @(image_path), exc.reason); }
        }

        // Deliver the notification
        static unsigned long counter = 1;
        UNNotificationRequest *request =
            [UNNotificationRequest requestWithIdentifier:(identifier ? @(identifier) : [NSString stringWithFormat:@"Id_%lu", counter++])
                                                 content:content
                                                 trigger:nil];
        char *duped_ident = strdup(identifier ? identifier : "");
        [center addNotificationRequest:request
                 withCompletionHandler:^(NSError *_Nullable error) {
                   if (error != nil) log_error("Failed to show notification: %s", [[error localizedDescription] UTF8String]);
                   bool ok = error == nil;
                   dispatch_async(dispatch_get_main_queue(), ^{
                     do_notification_callback(duped_ident, ok ? "created" : "creation_failed", "");
                     free(duped_ident);
                   });
                 }];
    }
}


typedef struct {
    char *identifier, *title, *body, *appname, *image_path, *category_id;
    int urgency;
    bool muted;
} QueuedNotification;

typedef struct {
    QueuedNotification *notifications;
    size_t count, capacity;
} NotificationQueue;
static NotificationQueue notification_queue = {0};

static void
queue_notification(
    const char *appname,
    const char *identifier,
    const char *title,
    const char *body,
    const char *image_path,
    int urgency,
    const char *category_id,
    bool muted) {
    ensure_space_for((&notification_queue), notifications, QueuedNotification, notification_queue.count + 16, capacity, 16, true);
    QueuedNotification *n = notification_queue.notifications + notification_queue.count++;
#define d(x) n->x = (x && x[0]) ? strdup(x) : NULL;
    d(appname);
    d(identifier);
    d(title);
    d(body);
    d(image_path);
    d(category_id);
#undef d
    n->urgency = urgency;
    n->muted = muted;
}

static void
drain_pending_notifications(BOOL granted) {
    if (granted) {
        for (size_t i = 0; i < notification_queue.count; i++) {
            QueuedNotification *n = notification_queue.notifications + i;
            schedule_notification(n->appname, n->identifier, n->title, n->body, n->image_path, n->urgency, n->category_id, n->muted);
        }
    }
    while (notification_queue.count) {
        QueuedNotification *n = notification_queue.notifications + --notification_queue.count;
        if (!granted) do_notification_callback(n->identifier, "creation_failed", "");
        free(n->identifier);
        free(n->title);
        free(n->body);
        free(n->appname);
        free(n->image_path);
        free(n->category_id);
        memset(n, 0, sizeof(QueuedNotification));
    }
}

static PyObject *
cocoa_remove_delivered_notification(PyObject *self UNUSED, PyObject *x) {
    if (!PyUnicode_Check(x)) {
        PyErr_SetString(PyExc_TypeError, "identifier must be a string");
        return NULL;
    }
    if (remove_delivered_notification(PyUnicode_AsUTF8(x))) { Py_RETURN_TRUE; }
    Py_RETURN_FALSE;
}

static PyObject *
cocoa_live_delivered_notifications(PyObject *self UNUSED, PyObject *x UNUSED) {
    if (live_delivered_notifications()) { Py_RETURN_TRUE; }
    Py_RETURN_FALSE;
}

static UNNotificationCategory *
category_from_python(PyObject *p) {
    RAII_PyObject(button_ids, PyObject_GetAttrString(p, "button_ids"));
    RAII_PyObject(buttons, PyObject_GetAttrString(p, "buttons"));
    RAII_PyObject(id, PyObject_GetAttrString(p, "id"));
    NSMutableArray<UNNotificationAction *> *actions = [NSMutableArray arrayWithCapacity:PyTuple_GET_SIZE(buttons)];
    for (int i = 0; i < PyTuple_GET_SIZE(buttons); i++)
        [actions addObject:[UNNotificationAction actionWithIdentifier:@(PyUnicode_AsUTF8(PyTuple_GET_ITEM(button_ids, i)))
                                                                title:@(PyUnicode_AsUTF8(PyTuple_GET_ITEM(buttons, i)))
                                                              options:UNNotificationActionOptionNone]];

    return [UNNotificationCategory categoryWithIdentifier:@(PyUnicode_AsUTF8(id)) actions:actions intentIdentifiers:@[] options:0];
}

static bool
set_notification_categories(UNUserNotificationCenter *center, PyObject *categories) {
    NSMutableArray<UNNotificationCategory *> *ans = [NSMutableArray arrayWithCapacity:PyTuple_GET_SIZE(categories)];
    for (int i = 0; i < PyTuple_GET_SIZE(categories); i++) {
        UNNotificationCategory *c = category_from_python(PyTuple_GET_ITEM(categories, i));
        if (!c) return false;
        [ans addObject:c];
    }
    [center setNotificationCategories:[NSSet setWithArray:ans]];
    return true;
}

static PyObject *
cocoa_send_notification(PyObject *self UNUSED, PyObject *args, PyObject *kw) {
    const char *identifier = "", *title = "", *body = "", *appname = "", *image_path = "";
    int urgency = 1;
    PyObject *category, *categories;
    int muted = 0;
    static const char *kwlist[] = {"appname", "identifier", "title", "body", "category", "categories", "image_path", "urgency", "muted", NULL};
    if (!PyArg_ParseTupleAndKeywords(
            args,
            kw,
            "ssssOO!|sip",
            (char **)kwlist,
            &appname,
            &identifier,
            &title,
            &body,
            &category,
            &PyTuple_Type,
            &categories,
            &image_path,
            &urgency,
            &muted))
        return NULL;

    UNUserNotificationCenter *center = get_notification_center_safely();
    if (!center) Py_RETURN_NONE;
    if (!center.delegate) center.delegate = [[NotificationDelegate alloc] init];
    if (PyObject_IsTrue(categories))
        if (!set_notification_categories(center, categories)) return NULL;
    RAII_PyObject(category_id, PyObject_GetAttrString(category, "id"));
    queue_notification(appname, identifier, title, body, image_path, urgency, PyUnicode_AsUTF8(category_id), muted);

    // The badge permission needs to be requested as well, even though it is not used,
    // otherwise macOS refuses to show the preference checkbox for enable/disable notification sound.
    [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound | UNAuthorizationOptionBadge)
                          completionHandler:^(BOOL granted, NSError *_Nullable error) {
                            if (!granted && error != nil) {
                                log_error("Failed to request permission for showing notification: %s", [[error localizedDescription] UTF8String]);
                            }
                            dispatch_async(dispatch_get_main_queue(), ^{ drain_pending_notifications(granted); });
                          }];
    Py_RETURN_NONE;
}

@interface ServiceProvider : NSObject
@end

@implementation ServiceProvider

- (BOOL)openTab:(NSPasteboard *)pasteboard userData:(NSString *)UNUSED userData error:(NSError **)UNUSED error {
    return [self openDirsFromPasteboard:pasteboard type:NEW_TAB_WITH_WD];
}

- (BOOL)openOSWindow:(NSPasteboard *)pasteboard userData:(NSString *)UNUSED userData error:(NSError **)UNUSED error {
    return [self openDirsFromPasteboard:pasteboard type:NEW_OS_WINDOW_WITH_WD];
}

- (BOOL)openDirsFromPasteboard:(NSPasteboard *)pasteboard type:(int)type {
    NSDictionary *options = @{NSPasteboardURLReadingFileURLsOnlyKey : @YES};
    NSArray *filePathArray = [pasteboard readObjectsForClasses:[NSArray arrayWithObject:[NSURL class]] options:options];
    NSMutableArray<NSString *> *dirPathArray = [NSMutableArray arrayWithCapacity:[filePathArray count]];
    for (NSURL *url in filePathArray) {
        NSString *path = [url path];
        BOOL isDirectory = NO;
        if ([[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory]) {
            if (!isDirectory) path = [path stringByDeletingLastPathComponent];
            if (![dirPathArray containsObject:path]) [dirPathArray addObject:path];
        }
    }
    if ([dirPathArray count] > 0) {
        // Colons are not valid in paths under macOS.
        set_cocoa_pending_action(type, [[dirPathArray componentsJoinedByString:@":"] UTF8String]);
    }
    return YES;
}

- (BOOL)openFileURLs:(NSPasteboard *)pasteboard userData:(NSString *)UNUSED userData error:(NSError **)UNUSED error {
    NSDictionary *options = @{NSPasteboardURLReadingFileURLsOnlyKey : @YES};
    NSArray *urlArray = [pasteboard readObjectsForClasses:[NSArray arrayWithObject:[NSURL class]] options:options];
    for (NSURL *url in urlArray) {
        NSString *path = [url path];
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            set_cocoa_pending_action(LAUNCH_URLS, [[[NSURL fileURLWithPath:path] absoluteString] UTF8String]);
        }
    }
    return YES;
}

- (void)quickAccessTerminal:(NSPasteboard *)pboard userData:(NSString *)userData error:(NSString **)error {
    // we ignore event during application launch as it will cause the window to be shown and hidden
    static bool is_first_event = true;
    if (!is_first_event || monotonic() >= s_double_to_monotonic_t(2.0)) { call_boss(quick_access_terminal_invoked, NULL); }
    is_first_event = false;
}
@end

// global menu {{{

static void
add_user_global_menu_entry(struct MenuItem *e, NSMenu *bar, size_t action_index) {
    NSMenu *parent = bar;
    UserMenuItem *final_item = nil;
    GlobalMenuTarget *global_menu_target = [GlobalMenuTarget shared_instance];
    for (size_t i = 0; i < e->location_count; i++) {
        NSMenuItem *item = [parent itemWithTitle:@(e->location[i])];
        if (!item) {
            final_item = [[UserMenuItem alloc] initWithTitle:@(e->location[i]) action:@selector(user_menu_action:) keyEquivalent:@""];
            final_item.target = global_menu_target;
            [parent addItem:final_item];
            item = final_item;
            [final_item release];
        }
        if (i + 1 < e->location_count) {
            if (![item hasSubmenu]) {
                NSMenu *sub_menu = [[NSMenu alloc] initWithTitle:item.title];
                [item setSubmenu:sub_menu];
                [sub_menu release];
            }
            parent = [item submenu];
            if (!parent) return;
        }
    }
    if (final_item != nil) { final_item.action_index = action_index; }
}

static void
cocoa_create_global_menu(void) {
    NSString *app_name = find_app_name();
    NSMenu *bar = [[NSMenu alloc] init];
    GlobalMenuTarget *global_menu_target = [GlobalMenuTarget shared_instance];
    [NSApp setMainMenu:bar];

#define MENU_ITEM(menu, title, name)                                                                                         \
    {                                                                                                                        \
        NSMenuItem *__mi = [menu addItemWithTitle:title action:@selector(name:) keyEquivalent:@(global_shortcuts.name.key)]; \
        [__mi setKeyEquivalentModifierMask:global_shortcuts.name.mods];                                                      \
        [__mi setTarget:global_menu_target];                                                                                 \
    }

    NSMenuItem *appMenuItem = [bar addItemWithTitle:@"" action:NULL keyEquivalent:@""];
    NSMenu *appMenu = [[NSMenu alloc] init];
    [appMenuItem setSubmenu:appMenu];

    [appMenu addItemWithTitle:[NSString stringWithFormat:@"About %@", app_name] action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    MENU_ITEM(appMenu, @"Preferences…", edit_config_file);
    MENU_ITEM(appMenu, @"Reload Preferences", reload_config);
    [appMenu addItem:[NSMenuItem separatorItem]];

    NSMenu *servicesMenu = [[NSMenu alloc] init];
    [NSApp setServicesMenu:servicesMenu];
    [[appMenu addItemWithTitle:@"Services" action:NULL keyEquivalent:@""] setSubmenu:servicesMenu];
    [servicesMenu release];
    [appMenu addItem:[NSMenuItem separatorItem]];

    MENU_ITEM(appMenu, ([NSString stringWithFormat:@"Hide %@", app_name]), hide_macos_app);
    MENU_ITEM(appMenu, @"Hide Others", hide_macos_other_apps);
    [appMenu addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];

    MENU_ITEM(appMenu, @"Secure Keyboard Entry", toggle_macos_secure_keyboard_entry);
    [appMenu addItem:[NSMenuItem separatorItem]];

    MENU_ITEM(appMenu, ([NSString stringWithFormat:@"Quit %@", app_name]), quit);
    [appMenu release];

    NSMenuItem *shellMenuItem = [bar addItemWithTitle:@"Shell" action:NULL keyEquivalent:@""];
    NSMenu *shellMenu = [[NSMenu alloc] initWithTitle:@"Shell"];
    [shellMenuItem setSubmenu:shellMenu];
    MENU_ITEM(shellMenu, @"New OS Window", new_os_window);
    MENU_ITEM(shellMenu, @"New Tab", new_tab);
    MENU_ITEM(shellMenu, @"New Window", new_window);
    [shellMenu addItem:[NSMenuItem separatorItem]];
    MENU_ITEM(shellMenu, @"Close OS Window", close_os_window);
    MENU_ITEM(shellMenu, @"Close Tab", close_tab);
    MENU_ITEM(shellMenu, @"Close Window", close_window);
    [shellMenu addItem:[NSMenuItem separatorItem]];
    MENU_ITEM(shellMenu, @"Reset", reset_terminal);
    [shellMenu release];
    NSMenuItem *editMenuItem = [bar addItemWithTitle:@"Edit" action:NULL keyEquivalent:@""];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenuItem setSubmenu:editMenu];
    MENU_ITEM(editMenu, @"Clear to Start", clear_terminal_and_scrollback);
    MENU_ITEM(editMenu, @"Clear Scrollback", clear_scrollback);
    MENU_ITEM(editMenu, @"Clear Screen", clear_screen);
    MENU_ITEM(editMenu, @"Clear Last Command", clear_last_command);
    MENU_ITEM(editMenu, @"Find", search_scrollback);
    [editMenu addItem:[NSMenuItem separatorItem]];
    MENU_ITEM(editMenu, @"Copy", copy_or_noop);
    MENU_ITEM(editMenu, @"Paste", paste_from_clipboard);
    [editMenu release];

    NSMenuItem *windowMenuItem = [bar addItemWithTitle:@"Window" action:NULL keyEquivalent:@""];
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    [windowMenuItem setSubmenu:windowMenu];

    MENU_ITEM(windowMenu, @"Minimize", minimize_macos_window);
    [windowMenu addItemWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""];
    [windowMenu addItem:[NSMenuItem separatorItem]];
    MENU_ITEM(windowMenu, @"Cycle Through OS Windows", macos_cycle_through_os_windows);
    MENU_ITEM(windowMenu, @"Cycle Through OS Windows backwards", macos_cycle_through_os_windows_backwards);
    [windowMenu addItem:[NSMenuItem separatorItem]];
    [windowMenu addItemWithTitle:@"Bring All to Front" action:@selector(arrangeInFront:) keyEquivalent:@""];

    [windowMenu addItem:[NSMenuItem separatorItem]];
    MENU_ITEM(windowMenu, @"Show Previous Tab", previous_tab);
    MENU_ITEM(windowMenu, @"Show Next Tab", next_tab);
    MENU_ITEM(windowMenu, @"Show All Tabs", toggle_macos_tab_overview);
    [[windowMenu addItemWithTitle:@"Move Tab to New Window" action:@selector(detach_tab:) keyEquivalent:@""] setTarget:global_menu_target];
    // These two have no kitty equivalent, so use AppKit's implementations. They
    // need allowsAutomaticWindowTabbing to stay on, which also makes AppKit
    // inject its own copies of the four items above; WindowMenuDelegate strips
    // those duplicates when the menu opens.
    [windowMenu addItemWithTitle:@"Merge All Windows" action:@selector(mergeAllWindows:) keyEquivalent:@""];
    [windowMenu addItemWithTitle:@"Show Tab Bar" action:@selector(toggleTabBar:) keyEquivalent:@""];

    [windowMenu addItem:[NSMenuItem separatorItem]];
    MENU_ITEM(windowMenu, @"Enter Full Screen", toggle_fullscreen);
    static WindowMenuDelegate *window_menu_delegate = nil;
    if (!window_menu_delegate) window_menu_delegate = [[WindowMenuDelegate alloc] init];
    windowMenu.delegate = window_menu_delegate;
    [NSApp setWindowsMenu:windowMenu];
    [windowMenu release];

    NSMenuItem *helpMenuItem = [bar addItemWithTitle:@"Help" action:NULL keyEquivalent:@""];
    NSMenu *helpMenu = [[NSMenu alloc] initWithTitle:@"Help"];
    [helpMenuItem setSubmenu:helpMenu];

    MENU_ITEM(helpMenu, @"Visit kitty Website", open_kitty_website);
    [NSApp setHelpMenu:helpMenu];
    [helpMenu release];

    if (OPT(global_menu.entries)) {
        for (size_t i = 0; i < OPT(global_menu.count); i++) {
            struct MenuItem *e = OPT(global_menu.entries) + i;
            if (e->definition && e->location && e->location_count > 1) { add_user_global_menu_entry(e, bar, i); }
        }
    }
    [bar release];


    class_addMethod(object_getClass([NSApp delegate]), @selector(applicationDockMenu:), (IMP)get_dock_menu, "@@:@");


    [NSApp setServicesProvider:[[[ServiceProvider alloc] init] autorelease]];

#undef MENU_ITEM
}

void
cocoa_application_lifecycle_event(bool application_launch_finished) {
    if (!application_launch_finished) cocoa_create_global_menu(); // applicationWillFinishLaunching
}

void
cocoa_update_menu_bar_title(PyObject *pytitle) {
    if (!pytitle) return;
    NSString *title = nil;
    if (OPT(macos_menubar_title_max_length) > 0 && PyUnicode_GetLength(pytitle) > OPT(macos_menubar_title_max_length)) {
        static char fmt[64];
        snprintf(fmt, sizeof(fmt), "%%%ld.%ldU%%s", OPT(macos_menubar_title_max_length), OPT(macos_menubar_title_max_length));
        RAII_PyObject(st, PyUnicode_FromFormat(fmt, pytitle, "…"));
        if (st) title = @(PyUnicode_AsUTF8(st));
        else PyErr_Print();
    } else {
        title = @(PyUnicode_AsUTF8(pytitle));
    }
    if (!title) return;
    NSString *menuTitle = [NSString stringWithFormat:@" :: %@", title];
    if (title_menu != NULL) {
        [[title_menu submenu] setTitle:menuTitle];
    } else {
        NSMenu *bar = [NSApp mainMenu];
        title_menu = [bar addItemWithTitle:@"" action:NULL keyEquivalent:@""];
        NSMenu *m = [[NSMenu alloc] initWithTitle:menuTitle];
        [title_menu setSubmenu:m];
        [m release];
    }
}

void
cocoa_clear_global_shortcuts(void) {
    memset(&global_shortcuts, 0, sizeof(global_shortcuts));
}

void
cocoa_recreate_global_menu(void) {
    if (title_menu != NULL) {
        NSMenu *bar = [NSApp mainMenu];
        [bar removeItem:title_menu];
    }
    title_menu = NULL;
    if (secure_input_title_menu != NULL) {
        NSMenu *bar = [NSApp mainMenu];
        [bar removeItem:secure_input_title_menu];
    }
    secure_input_title_menu = NULL;
    cocoa_create_global_menu();
    SecureKeyboardEntryController *k = [SecureKeyboardEntryController sharedInstance];
    update_secure_input_menu_bar_indicator(k.isDesired);
}


// }}}

#define NSLeftAlternateKeyMask (0x000020 | NSEventModifierFlagOption)
#define NSRightAlternateKeyMask (0x000040 | NSEventModifierFlagOption)

bool
cocoa_alt_option_key_pressed(NSUInteger flags) {
    NSUInteger q = (OPT(macos_option_as_alt) == 1) ? NSRightAlternateKeyMask : NSLeftAlternateKeyMask;
    return (q & flags) == q;
}

void
cocoa_toggle_secure_keyboard_entry(void) {
    SecureKeyboardEntryController *k = [SecureKeyboardEntryController sharedInstance];
    [k toggle];
    [[NSUserDefaults standardUserDefaults] setBool:k.isDesired forKey:@"SecureKeyboardEntry"];
    update_secure_input_menu_bar_indicator(k.isDesired);
}

void
cocoa_hide(void) {
    [[NSApplication sharedApplication] performSelectorOnMainThread:@selector(hide:) withObject:nil waitUntilDone:NO];
}

void
cocoa_hide_others(void) {
    [[NSApplication sharedApplication] performSelectorOnMainThread:@selector(hideOtherApplications:) withObject:nil waitUntilDone:NO];
}

void
cocoa_minimize(void *w) {
    NSWindow *window = (NSWindow *)w;
    if (window && !window.miniaturized) [window performSelectorOnMainThread:@selector(performMiniaturize:) withObject:nil waitUntilDone:NO];
}

void
cocoa_focus_window(void *w) {
    NSWindow *window = (NSWindow *)w;
    [window makeKeyWindow];
}

long
cocoa_window_number(void *w) {
    NSWindow *window = (NSWindow *)w;
    return [window windowNumber];
}

size_t
cocoa_get_workspace_ids(void *w, size_t *workspace_ids, size_t array_sz) {
    NSWindow *window = (NSWindow *)w;
    if (!window) return 0;
    NSArray *window_array = @[ @([window windowNumber]) ];
    CFArrayRef spaces = CGSCopySpacesForWindows(_CGSDefaultConnection(), kCGSSpaceAll, (__bridge CFArrayRef)window_array);
    CFIndex ans = CFArrayGetCount(spaces);
    if (ans > 0) {
        for (CFIndex i = 0; i < MIN(ans, (CFIndex)array_sz); i++) {
            NSNumber *s = (NSNumber *)CFArrayGetValueAtIndex(spaces, i);
            workspace_ids[i] = [s intValue];
        }
    } else ans = 0;
    CFRelease(spaces);
    return ans;
}

static PyObject *
cocoa_get_lang(PyObject UNUSED *self, PyObject *args UNUSED) {
    @autoreleasepool {
        NSString *lang_code = [[NSLocale currentLocale] languageCode];
        NSString *country_code = [[NSLocale currentLocale] objectForKey:NSLocaleCountryCode];
        NSString *identifier = [[NSLocale currentLocale] localeIdentifier];
        return Py_BuildValue(
            "sss", lang_code ? [lang_code UTF8String] : "", country_code ? [country_code UTF8String] : "", identifier ? [identifier UTF8String] : "");
    } // autoreleasepool
}

monotonic_t
cocoa_cursor_blink_interval(void) {
    @autoreleasepool {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        double on_period_ms = [defaults doubleForKey:@"NSTextInsertionPointBlinkPeriodOn"];
        double off_period_ms = [defaults doubleForKey:@"NSTextInsertionPointBlinkPeriodOff"];
        double period_ms = [defaults doubleForKey:@"NSTextInsertionPointBlinkPeriod"];
        double max_value = 60 * 1000.0, ans = -1.0;
        if (on_period_ms != 0. || off_period_ms != 0.) {
            ans = on_period_ms + off_period_ms;
        } else if (period_ms != 0.) {
            ans = period_ms;
        }
        return ans > max_value ? 0ll : ms_double_to_monotonic_t(ans);

    } // autoreleasepool
}

void
cocoa_set_activation_policy(bool hide_from_tasks) {
    [NSApp setActivationPolicy:(hide_from_tasks ? NSApplicationActivationPolicyAccessory : NSApplicationActivationPolicyRegular)];
}

static PyObject *
cocoa_set_url_handler(PyObject UNUSED *self, PyObject *args) {
    @autoreleasepool {
        const char *url_scheme = NULL, *bundle_id = NULL;
        if (!PyArg_ParseTuple(args, "s|z", &url_scheme, &bundle_id)) return NULL;
        if (!url_scheme || url_scheme[0] == '\0') {
            PyErr_SetString(PyExc_TypeError, "Empty url scheme");
            return NULL;
        }

        NSString *scheme = [NSString stringWithUTF8String:url_scheme];
        NSString *identifier = @"";
        if (!bundle_id) {
            identifier = [[NSBundle mainBundle] bundleIdentifier];
            if (!identifier || identifier.length == 0) identifier = @"net.kovidgoyal.kitty";
        } else if (bundle_id[0] != '\0') {
            identifier = [NSString stringWithUTF8String:bundle_id];
        }
        // This API has been marked as deprecated. It will need to be replaced when a new approach is available.
        OSStatus err = LSSetDefaultHandlerForURLScheme((CFStringRef)scheme, (CFStringRef)identifier);
        if (err == noErr) Py_RETURN_NONE;
        PyErr_Format(PyExc_OSError, "Failed to set default handler with error code: %d", err);
        return NULL;
    } // autoreleasepool
}

static PyObject *
cocoa_set_app_icon(PyObject UNUSED *self, PyObject *args) {
    @autoreleasepool {
        const char *icon_path = NULL, *app_path = NULL;
        if (!PyArg_ParseTuple(args, "s|z", &icon_path, &app_path)) return NULL;
        if (!icon_path || icon_path[0] == '\0') {
            PyErr_SetString(PyExc_TypeError, "Empty icon file path");
            return NULL;
        }
        NSString *custom_icon_path = [NSString stringWithUTF8String:icon_path];
        if (![[NSFileManager defaultManager] fileExistsAtPath:custom_icon_path]) {
            PyErr_Format(PyExc_FileNotFoundError, "Icon file not found: %s", [custom_icon_path UTF8String]);
            return NULL;
        }

        NSString *bundle_path = @"";
        if (!app_path) {
            bundle_path = [[NSBundle mainBundle] bundlePath];
            if (!bundle_path || bundle_path.length == 0) bundle_path = @"/Applications/kitty.app";
            // When compiled from source and run from the launcher folder the bundle path should be `kitty.app` in it
            if (![bundle_path hasSuffix:@".app"]) {
                NSString *launcher_app_path = [bundle_path stringByAppendingPathComponent:@"kitty.app"];
                bundle_path = @"";
                BOOL is_dir;
                if ([[NSFileManager defaultManager] fileExistsAtPath:launcher_app_path isDirectory:&is_dir] && is_dir &&
                    [[NSWorkspace sharedWorkspace] isFilePackageAtPath:launcher_app_path]) {
                    bundle_path = launcher_app_path;
                }
            }
        } else if (app_path[0] != '\0') {
            bundle_path = [NSString stringWithUTF8String:app_path];
        }
        if (!bundle_path || bundle_path.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:bundle_path]) {
            PyErr_Format(PyExc_FileNotFoundError, "Application bundle not found: %s", [bundle_path UTF8String]);
            return NULL;
        }

        NSImage *icon_image = [[NSImage alloc] initWithContentsOfFile:custom_icon_path];
        BOOL result = [[NSWorkspace sharedWorkspace] setIcon:icon_image forFile:bundle_path options:NSExcludeQuickDrawElementsIconCreationOption];
        [icon_image release];
        if (result) Py_RETURN_NONE;
        PyErr_Format(PyExc_OSError, "Failed to set custom icon %s for %s", [custom_icon_path UTF8String], [bundle_path UTF8String]);
        return NULL;

    } // autoreleasepool
}

static NSImage *custom_dock_icon = nil;

static PyObject *
cocoa_set_dock_icon(PyObject UNUSED *self, PyObject *args) {
    @autoreleasepool {
        const char *icon_path = NULL;
        if (!PyArg_ParseTuple(args, "s", &icon_path)) return NULL;
        if (!icon_path || icon_path[0] == '\0') {
            PyErr_SetString(PyExc_TypeError, "Empty icon file path");
            return NULL;
        }
        NSString *custom_icon_path = [NSString stringWithUTF8String:icon_path];
        if ([[NSFileManager defaultManager] fileExistsAtPath:custom_icon_path]) {
            NSImage *icon_image = [[[NSImage alloc] initWithContentsOfFile:custom_icon_path] autorelease];
            [NSApplication sharedApplication].applicationIconImage = icon_image;
            if (custom_dock_icon) [custom_dock_icon release];
            custom_dock_icon = [icon_image retain];
            Py_RETURN_NONE;
        }
        return NULL;

    } // autoreleasepool
}

static NSSound *beep_sound = nil;

static void
cleanup(void) {
    @autoreleasepool {
        if (dockMenu) [dockMenu release];
        dockMenu = nil;
        if (beep_sound) [beep_sound release];
        beep_sound = nil;

        drain_pending_notifications(NO);
        free(notification_queue.notifications);
        notification_queue.notifications = NULL;
        notification_queue.capacity = 0;

    } // autoreleasepool
}

void
cocoa_system_beep(const char *path) {
    if (!path) {
        NSBeep();
        return;
    }
    static const char *beep_path = NULL;
    if (beep_path != path) {
        if (beep_sound) [beep_sound release];
        beep_sound = [[NSSound alloc] initWithContentsOfFile:@(path) byReference:YES];
    }
    if (beep_sound) [beep_sound play];
    else NSBeep();
}

static void
uncaughtExceptionHandler(NSException *exception) {
    log_error("Unhandled exception in Cocoa: %s", [[exception description] UTF8String]);
    log_error("Stack trace:\n%s", [[exception.callStackSymbols description] UTF8String]);
}

void
cocoa_set_uncaught_exception_handler(void) {
    NSSetUncaughtExceptionHandler(&uncaughtExceptionHandler);
}

static PyObject *
convert_imagerep_to_png(NSBitmapImageRep *rep, const char *output_path) {
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{NSImageCompressionFactor : @1.0}]; // autoreleased

    if (output_path) {
        if (![png writeToFile:@(output_path) atomically:YES]) {
            PyErr_Format(PyExc_OSError, "Failed to write PNG data to %s", output_path);
            return NULL;
        }
        return PyBytes_FromStringAndSize(NULL, 0);
    }
    return PyBytes_FromStringAndSize(png.bytes, png.length);
}

static PyObject *
convert_image_to_png(NSImage *icon, unsigned image_size, const char *output_path) {
    NSRect r = NSMakeRect(0, 0, image_size, image_size);
    RAII_CoreFoundation(CGColorSpaceRef, colorSpace, CGColorSpaceCreateWithName(kCGColorSpaceGenericRGB));
    RAII_CoreFoundation(
        CGContextRef,
        cgContext,
        CGBitmapContextCreate(NULL, image_size, image_size, 8, 4 * image_size, colorSpace, kCGBitmapByteOrderDefault | kCGImageAlphaPremultipliedLast));
    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithCGContext:cgContext flipped:NO]; // autoreleased
    CGImageRef cg = [icon CGImageForProposedRect:&r context:context hints:nil];
    NSBitmapImageRep *rep = [[[NSBitmapImageRep alloc] initWithCGImage:cg] autorelease];
    return convert_imagerep_to_png(rep, output_path);
}

static PyObject *
render_emoji(NSString *text, unsigned image_size, const char *output_path) {
    NSFont *font = [NSFont fontWithName:@"AppleColorEmoji" size:12];
    CTFontRef ctfont = (__bridge CTFontRef)(font);
    CGFloat line_height = MAX(1, floor(CTFontGetAscent(ctfont) + CTFontGetDescent(ctfont) + MAX(0, CTFontGetLeading(ctfont)) + 0.5));
    CGFloat pts_per_px = CTFontGetSize(ctfont) / line_height;
    CGFloat desired_size = image_size * pts_per_px;
    NSFont *final_font = [NSFont fontWithName:@"AppleColorEmoji" size:desired_size];
    NSAttributedString *attr_string = [[[NSAttributedString alloc] initWithString:text attributes:@{NSFontAttributeName : final_font}] autorelease];
    NSBitmapImageRep *bmp = [[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nil
                                                                     pixelsWide:image_size
                                                                     pixelsHigh:image_size
                                                                  bitsPerSample:8
                                                                samplesPerPixel:4
                                                                       hasAlpha:YES
                                                                       isPlanar:NO
                                                                 colorSpaceName:NSDeviceRGBColorSpace
                                                                    bytesPerRow:0
                                                                   bitsPerPixel:0] autorelease];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:bmp];
    [NSGraphicsContext setCurrentContext:context];
    [attr_string drawInRect:NSMakeRect(0, 0, image_size, image_size)];
    [NSGraphicsContext restoreGraphicsState];
    return convert_imagerep_to_png(bmp, output_path);
}


static PyObject *
bundle_image_as_png(PyObject *self UNUSED, PyObject *args, PyObject *kw) {
    @autoreleasepool {
        const char *b, *output_path = NULL;
        int image_type = 1;
        unsigned image_size = 256;
        static const char *kwlist[] = {"path_or_identifier", "output_path", "image_size", "image_type", NULL};
        if (!PyArg_ParseTupleAndKeywords(args, kw, "s|sIi", (char **)kwlist, &b, &output_path, &image_size, &image_type)) return NULL;
        NSImage *icon = nil;
        switch (image_type) {
            case 0:
            case 1: {
                NSWorkspace *workspace = [NSWorkspace sharedWorkspace]; // autoreleased
                if (image_type == 1) {
                    NSURL *url = [workspace URLForApplicationWithBundleIdentifier:@(b)]; // autoreleased
                    if (!url) {
                        PyErr_Format(PyExc_KeyError, "Failed to find bundle path for identifier: %s", b);
                        return NULL;
                    }
                    icon = [workspace iconForFile:@(url.fileSystemRepresentation)];
                } else icon = [workspace iconForFile:@(b)];
            } break;
            case 2: return render_emoji(@(b), image_size, output_path);
            default:
                if (@available(macOS 11.0, *)) {
                    icon = [NSImage imageWithSystemSymbolName:@(b) accessibilityDescription:@""]; // autoreleased
                } else {
                    PyErr_SetString(PyExc_ValueError, "Your version of macOS is too old to use symbol images, need >= 11.0");
                    return NULL;
                }
                break;
        }
        if (!icon) {
            PyErr_Format(PyExc_ValueError, "Failed to load icon for bundle: %s", b);
            return NULL;
        }
        return convert_image_to_png(icon, image_size, output_path);
    }
}

static PyObject *
play_system_sound_by_id_async(PyObject *self UNUSED, PyObject *which) {
    if (!PyLong_Check(which)) {
        PyErr_SetString(PyExc_TypeError, "system sound id must be an integer");
        return NULL;
    }
    AudioServicesPlaySystemSound(PyLong_AsUnsignedLong(which));
    Py_RETURN_NONE;
}

// Dock Progress bar {{{
@interface RoundedRectangleView : NSView {
    unsigned intermediate_step;
    CGFloat fill_fraction;
    BOOL is_indeterminate;
}
- (void)animate;
- (BOOL)isIndeterminate;
- (void)setIndeterminate:(BOOL)val;
- (void)setFraction:(CGFloat)fraction;
@end

@implementation RoundedRectangleView

- (void)animate {
    intermediate_step++;
}
- (BOOL)isIndeterminate {
    return is_indeterminate;
}
- (void)setIndeterminate:(BOOL)val {
    if (val != is_indeterminate) {
        is_indeterminate = val;
        intermediate_step = 0;
    }
}
- (void)setFraction:(CGFloat)fraction {
    fill_fraction = fraction;
}


- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    NSRect bar = NSInsetRect(self.bounds, 4, 4);
    CGFloat cornerRadius = self.bounds.size.height / 4.0;

#define fill(bar) [[NSBezierPath bezierPathWithRoundedRect:bar xRadius:cornerRadius yRadius:cornerRadius] fill]
    // Create the border
    [[[NSColor whiteColor] colorWithAlphaComponent:0.8] setFill];
    fill(bar);
    // Create the background
    [[[NSColor blackColor] colorWithAlphaComponent:0.8] setFill];
    fill(NSInsetRect(bar, 0.5, 0.5));
    // Create the progress
    NSRect bar_progress = NSInsetRect(bar, 1, 1);
    if (intermediate_step) {
        unsigned num_of_steps = 80;
        intermediate_step = intermediate_step % num_of_steps;
        bar_progress.size.width = self.bounds.size.width / 8;
        float frac = intermediate_step / (float)num_of_steps;
        bar_progress.origin.x += (self.bounds.size.width - bar_progress.size.width) * frac;
    } else bar_progress.size.width *= fill_fraction;
    [[NSColor whiteColor] setFill];
    fill(bar_progress);
#undef fill
}

@end
static NSView *dock_content_view = nil;
static NSImageView *dock_image_view = nil;
static RoundedRectangleView *dock_pbar = nil;

static void animate_dock_progress_bar(id_type timer_id UNUSED, void *data UNUSED);

static void
tick_dock_pbar(void) {
    add_main_loop_timer(ms_to_monotonic_t(20), false, animate_dock_progress_bar, NULL, NULL);
}

static void
animate_dock_progress_bar(id_type timer_id UNUSED, void *data UNUSED) {
    if (dock_pbar != nil && [dock_pbar isIndeterminate]) {
        [dock_pbar animate];
        NSDockTile *dockTile = [NSApp dockTile];
        [dockTile display];
        tick_dock_pbar();
    }
}

static PyObject *
cocoa_show_progress_bar_on_dock_icon(PyObject *self UNUSED, PyObject *args) {
    float percent = -100;
    if (!PyArg_ParseTuple(args, "|f", &percent)) return NULL;
    NSDockTile *dockTile = [NSApp dockTile];
    const bool remove_pbar = percent < 0;
    if (!dock_content_view) {
        if (remove_pbar) Py_RETURN_NONE; // nothing to remove, leave the dock tile alone
        dock_content_view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, dockTile.size.width, dockTile.size.height)];
        dock_content_view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        dock_image_view = [NSImageView.alloc initWithFrame:dock_content_view.frame];
        dock_image_view.imageScaling = NSImageScaleProportionallyDown;
        dock_image_view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [dock_content_view addSubview:dock_image_view];
        dock_pbar = [[RoundedRectangleView alloc] initWithFrame:NSMakeRect(0, 0, dockTile.size.width, dockTile.size.height / 4)];
        dock_pbar.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
        [dock_content_view addSubview:dock_pbar];
    }
    NSImage *icon_image = custom_dock_icon ? custom_dock_icon : NSApp.applicationIconImage;
    if (dock_image_view.image != icon_image) dock_image_view.image = icon_image;
    [dock_content_view setFrameSize:dockTile.size];
    [dock_image_view setFrameSize:dockTile.size];
    if (percent >= 0 && percent <= 100) {
        [dock_pbar setFraction:percent / 100.];
        [dock_pbar setIndeterminate:NO];
    } else if (percent > 100) {
        if (![dock_pbar isIndeterminate]) {
            [dock_pbar setIndeterminate:YES];
            tick_dock_pbar();
        }
    } else [dock_pbar setIndeterminate:NO]; // stops the animation timer, if running
    [dock_pbar setFrameSize:NSMakeSize(dockTile.size.width - 20, 20)];
    [dock_pbar setFrameOrigin:NSMakePoint(10, -2)];
    dock_pbar.hidden = remove_pbar;
    // Re-apply the custom icon in case macOS has reverted it, so that the
    // icon used outside the Dock (cmd+tab, notifications, etc.) is correct
    if (custom_dock_icon != nil && NSApp.applicationIconImage != custom_dock_icon) NSApp.applicationIconImage = custom_dock_icon;
    // On some macOS versions setting the content view to nil causes the Dock
    // to redraw the tile with the bundle icon before the custom icon is
    // restored, causing a flicker. So when there is a custom icon, keep the
    // content view, which draws the custom icon itself, just without the
    // progress bar.
    [dockTile setContentView:(remove_pbar && custom_dock_icon == nil) ? nil : dock_content_view];
    [dockTile display];
    Py_RETURN_NONE;
}
// }}}

// Dock badge {{{

static bool dock_badge_is_set = false;

void
cocoa_set_dock_badge(const char *label) {
    @autoreleasepool {
        NSDockTile *dockTile = [NSApp dockTile];
        [dockTile setBadgeLabel:label ? @(label) : nil];
        [dockTile display];
        dock_badge_is_set = (label != NULL);
    }
}

void
cocoa_clear_dock_badge_if_set(void) {
    if (dock_badge_is_set) cocoa_set_dock_badge(NULL);
}

// }}}

static PyObject *
cocoa_is_secure_input_enabled(PyObject *self UNUSED, PyObject *args UNUSED) {
    SecureKeyboardEntryController *k = [SecureKeyboardEntryController sharedInstance];
    return Py_NewRef(k.isDesired ? Py_True : Py_False);
}

static PyObject *
cocoa_get_machine_id(PyObject *self UNUSED, PyObject *args UNUSED) {
    static char ans[1024] = {0};
    static bool done = false;
    if (!done) {
        done = true;
        CFMutableDictionaryRef matching = IOServiceMatching("IOPlatformExpertDevice");
        // Get the matching service
        io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, matching);
        if (service) {
            CFTypeRef uuid = IORegistryEntryCreateCFProperty(service, CFSTR("IOPlatformUUID"), kCFAllocatorDefault, 0);
            if (uuid) {
                // Transfer ownership to NSString using ARC __bridge_transfer
                NSString *s = (NSString *)uuid;
                [s getCString:ans maxLength:sizeof(ans) encoding:NSUTF8StringEncoding];
            }
            // Release the I/O object
            IOObjectRelease(service);
        }
    }
    return PyUnicode_FromString(ans);
}

// Keychain {{{
// These never show any UI, such as a prompt to unlock the keychain or to allow kitty to access an item, failing instead.

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
// The legacy file based keychain, which is the one used by default, shows its prompts unless interaction is disallowed with this
// deprecated, process wide, API, which has no replacement.
typedef struct {
    Boolean previous;
    bool is_set;
} KeychainInteraction;

static KeychainInteraction
disallow_keychain_interaction(void) {
    KeychainInteraction ans = {0};
    if (SecKeychainGetUserInteractionAllowed(&ans.previous) == errSecSuccess) ans.is_set = SecKeychainSetUserInteractionAllowed(false) == errSecSuccess;
    return ans;
}

static void
restore_keychain_interaction(KeychainInteraction x) {
    if (x.is_set) SecKeychainSetUserInteractionAllowed(x.previous);
}

static void
set_keychain_query_ui_fail(CFMutableDictionaryRef q) {
    CFDictionarySetValue(q, kSecUseAuthenticationUI, kSecUseAuthenticationUIFail);
}
#pragma clang diagnostic pop

static CFMutableDictionaryRef
keychain_query(const char *service, const char *account) {
    // account can be NULL to match all items of service
    CFMutableDictionaryRef q = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFStringRef s = CFStringCreateWithCString(NULL, service, kCFStringEncodingUTF8);
    CFStringRef a = account ? CFStringCreateWithCString(NULL, account, kCFStringEncodingUTF8) : NULL;
    if (!q || !s || (account && !a)) {
        if (q) CFRelease(q);
        if (s) CFRelease(s);
        if (a) CFRelease(a);
        PyErr_NoMemory();
        return NULL;
    }
    CFDictionarySetValue(q, kSecClass, kSecClassGenericPassword);
    CFDictionarySetValue(q, kSecAttrService, s);
    CFRelease(s);
    if (a) {
        CFDictionarySetValue(q, kSecAttrAccount, a);
        CFRelease(a);
    }
    return q;
}

static PyObject *
set_keychain_error(OSStatus status, const char *action) {
    char msg[512] = {0};
    CFStringRef m = SecCopyErrorMessageString(status, NULL);
    if (m) {
        CFStringGetCString(m, msg, sizeof(msg), kCFStringEncodingUTF8);
        CFRelease(m);
    }
    PyErr_Format(PyExc_OSError, "Failed to %s the keychain: %s (error code: %d)", action, msg, (int)status);
    return NULL;
}

static PyObject *
cocoa_keychain_store_secret(PyObject *self UNUSED, PyObject *args) {
    const char *service, *account, *label;
    PyObject *secret;
    if (!PyArg_ParseTuple(args, "sssO", &service, &account, &label, &secret)) return NULL;
    const void *data;
    size_t len;
    if (!secret_data(secret, &data, &len)) return NULL;
    CFMutableDictionaryRef q = keychain_query(service, account);
    if (!q) return NULL;
    // Do not copy the secret into memory that is not cleared when freed
    CFDataRef d = CFDataCreateWithBytesNoCopy(NULL, data, (CFIndex)len, kCFAllocatorNull);
    CFStringRef l = CFStringCreateWithCString(NULL, label, kCFStringEncodingUTF8);
    if (!d || !l) {
        CFRelease(q);
        if (d) CFRelease(d);
        if (l) CFRelease(l);
        return PyErr_NoMemory();
    }
    CFDictionarySetValue(q, kSecValueData, d);
    CFDictionarySetValue(q, kSecAttrLabel, l);
    CFRelease(d);
    CFRelease(l);
    KeychainInteraction ki = disallow_keychain_interaction();
    OSStatus status = SecItemAdd(q, NULL);
    restore_keychain_interaction(ki);
    CFRelease(q);
    if (status != errSecSuccess) return set_keychain_error(status, "store an item in");
    Py_RETURN_NONE;
}

static PyObject *
cocoa_keychain_read_secret(PyObject *self UNUSED, PyObject *args) {
    const char *service, *account;
    if (!PyArg_ParseTuple(args, "ss", &service, &account)) return NULL;
    CFMutableDictionaryRef q = keychain_query(service, account);
    if (!q) return NULL;
    CFDictionarySetValue(q, kSecReturnData, kCFBooleanTrue);
    CFDictionarySetValue(q, kSecMatchLimit, kSecMatchLimitOne);
    set_keychain_query_ui_fail(q);
    CFTypeRef result = NULL;
    KeychainInteraction ki = disallow_keychain_interaction();
    OSStatus status = SecItemCopyMatching(q, &result);
    restore_keychain_interaction(ki);
    CFRelease(q);
    if (status == errSecItemNotFound) Py_RETURN_NONE;
    if (status != errSecSuccess) return set_keychain_error(status, "read an item from");
    if (!result || CFGetTypeID(result) != CFDataGetTypeID()) {
        if (result) CFRelease(result);
        PyErr_SetString(PyExc_OSError, "The item read from the keychain has no data");
        return NULL;
    }
    PyObject *ans = secret_from_data(CFDataGetBytePtr((CFDataRef)result), (size_t)CFDataGetLength((CFDataRef)result));
    CFRelease(result);
    return ans;
}

static PyObject *
cocoa_keychain_delete(PyObject *self UNUSED, PyObject *args) {
    const char *service, *account;
    if (!PyArg_ParseTuple(args, "ss", &service, &account)) return NULL;
    CFMutableDictionaryRef q = keychain_query(service, account);
    if (!q) return NULL;
    set_keychain_query_ui_fail(q);
    KeychainInteraction ki = disallow_keychain_interaction();
    OSStatus status = SecItemDelete(q);
    restore_keychain_interaction(ki);
    CFRelease(q);
    if (status == errSecItemNotFound) Py_RETURN_FALSE;
    if (status != errSecSuccess) return set_keychain_error(status, "delete an item from");
    Py_RETURN_TRUE;
}
static PyObject *
cocoa_keychain_list_accounts(PyObject *self UNUSED, PyObject *args) {
    const char *service;
    if (!PyArg_ParseTuple(args, "s", &service)) return NULL;
    CFMutableDictionaryRef q = keychain_query(service, NULL);
    if (!q) return NULL;
    // Only the attributes are read, which does not need access to the secret data of the items
    CFDictionarySetValue(q, kSecReturnAttributes, kCFBooleanTrue);
    CFDictionarySetValue(q, kSecMatchLimit, kSecMatchLimitAll);
    set_keychain_query_ui_fail(q);
    CFTypeRef result = NULL;
    KeychainInteraction ki = disallow_keychain_interaction();
    OSStatus status = SecItemCopyMatching(q, &result);
    restore_keychain_interaction(ki);
    CFRelease(q);
    if (status == errSecItemNotFound) return PyList_New(0);
    if (status != errSecSuccess) return set_keychain_error(status, "list the items in");
    if (!result || CFGetTypeID(result) != CFArrayGetTypeID()) {
        if (result) CFRelease(result);
        PyErr_SetString(PyExc_OSError, "Listing the items in the keychain did not return a list");
        return NULL;
    }
    PyObject *ans = PyList_New(0);
    CFArrayRef items = (CFArrayRef)result;
    for (CFIndex i = 0; ans && i < CFArrayGetCount(items); i++) {
        CFTypeRef item = CFArrayGetValueAtIndex(items, i);
        if (!item || CFGetTypeID(item) != CFDictionaryGetTypeID()) continue;
        CFTypeRef account = CFDictionaryGetValue((CFDictionaryRef)item, kSecAttrAccount);
        if (!account || CFGetTypeID(account) != CFStringGetTypeID()) continue;
        char buf[1024];
        if (!CFStringGetCString((CFStringRef)account, buf, sizeof(buf), kCFStringEncodingUTF8)) continue;
        RAII_PyObject(a, PyUnicode_FromString(buf));
        if (!a || PyList_Append(ans, a) != 0) Py_CLEAR(ans);
    }
    CFRelease(result);
    return ans;
}
// }}}

static PyMethodDef module_methods[] = {
    {"cocoa_keychain_list_accounts", (PyCFunction)cocoa_keychain_list_accounts, METH_VARARGS, ""},
    {"cocoa_keychain_store_secret", (PyCFunction)cocoa_keychain_store_secret, METH_VARARGS, ""},
    {"cocoa_keychain_read_secret", (PyCFunction)cocoa_keychain_read_secret, METH_VARARGS, ""},
    {"cocoa_keychain_delete", (PyCFunction)cocoa_keychain_delete, METH_VARARGS, ""},
    {"cocoa_play_system_sound_by_id_async", play_system_sound_by_id_async, METH_O, ""},
    {"cocoa_get_lang", (PyCFunction)cocoa_get_lang, METH_NOARGS, ""},
    {"cocoa_get_machine_id", (PyCFunction)cocoa_get_machine_id, METH_NOARGS, ""},
    {"cocoa_is_secure_input_enabled", (PyCFunction)cocoa_is_secure_input_enabled, METH_NOARGS, ""},
    {"cocoa_set_global_shortcut", (PyCFunction)cocoa_set_global_shortcut, METH_VARARGS, ""},
    {"cocoa_send_notification", (PyCFunction)(void (*)(void))cocoa_send_notification, METH_VARARGS | METH_KEYWORDS, ""},
    {"cocoa_remove_delivered_notification", (PyCFunction)cocoa_remove_delivered_notification, METH_O, ""},
    {"cocoa_live_delivered_notifications", (PyCFunction)cocoa_live_delivered_notifications, METH_NOARGS, ""},
    {"cocoa_set_notification_activated_callback", (PyCFunction)set_notification_activated_callback, METH_O, ""},
    {"cocoa_set_url_handler", (PyCFunction)cocoa_set_url_handler, METH_VARARGS, ""},
    {"cocoa_set_app_icon", (PyCFunction)cocoa_set_app_icon, METH_VARARGS, ""},
    {"cocoa_set_dock_icon", (PyCFunction)cocoa_set_dock_icon, METH_VARARGS, ""},
    {"cocoa_show_progress_bar_on_dock_icon", (PyCFunction)cocoa_show_progress_bar_on_dock_icon, METH_VARARGS, ""},
    {"cocoa_bundle_image_as_png", (PyCFunction)(void (*)(void))bundle_image_as_png, METH_VARARGS | METH_KEYWORDS, ""},
    {NULL, NULL, 0, NULL} /* Sentinel */
};

bool
init_cocoa(PyObject *module) {
    cocoa_clear_global_shortcuts();
    if (PyModule_AddFunctions(module, module_methods) != 0) return false;
    register_at_exit_cleanup_func(COCOA_CLEANUP_FUNC, cleanup);
    [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note UNUSED) { cocoa_set_dock_badge(NULL); }];
    return true;
}