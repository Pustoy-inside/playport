// SPDX-License-Identifier: GPL-3.0-or-later
// PlayportTouchPad: an on-screen game controller for Playport. Pavel Demyanov's
// prototype (PavelDemyanov/playport, contrib/touchpad, v0.4.0-touchpad.3), which
// was a library loaded into the released app, built here into the app itself:
// Playport's entry points are called directly instead of found with dlsym, and
// the 0.4.0-only environment workarounds are gone (runtime_environment).
// The system's GCVirtualController (iOS 15+) draws two thumbsticks, A/B/X/Y,
// the shoulders and the triggers over the app, and appears to it as an ordinary
// GCController with an extendedGamepad. Playport hands that controller to the
// game as XInput (HostIO.attach) as it does a real one. It is on the screen
// while no physical pad is connected: one connects, it hides; it goes, it is back.
// The system draws no Home, Start, Back or D-pad, so this library adds them:
// a D-pad right of the left stick, and a row of buttons at the top centre:
//   Home   Playport's in-game menu (InGameMenu.open(), as Home held does):
//          Resume, Quit game;
//   Back / Start   their XInput bits added to the touch pad's state
//          (host_pad_set, slot 0) while held;
//   opacity   the touch pad's and these buttons': 100 -> 75 -> 50 -> 30 %;
//          held, it turns the touch pad off, all of it (it disconnects, so no
//          invisible touch areas stay) leaving only this button, or back on.
// While the menu is open the touch pad is hidden and the menu's rows take taps.
// Before the runtime starts it also sets a few environment variables
// (runtime_environment) and two settings for Baldur's Gate 3 (bg3_executable,
// bg3_graphics). Log: Documents/playport-touchpad.log.

#import <GameController/GameController.h>
#import <UIKit/UIKit.h>
#include <stdbool.h>

#include "host_io.h"
#include "touchpad.h"

/* wine_host.h (WineHost): the runtime log's cap for this session. */
void wine_host_set_log_limit(size_t bytes);

/* The in-game menu (UI/TouchPadBridge.swift, on the main thread). */
bool playport_touchpad_menu_open(void);
bool playport_touchpad_menu_is_open(void);

enum { XI_DPAD_UP = 0x0001, XI_DPAD_DOWN = 0x0002, XI_DPAD_LEFT = 0x0004, XI_DPAD_RIGHT = 0x0008,
       XI_START = 0x0010, XI_BACK = 0x0020, XI_LB = 0x0100, XI_RB = 0x0200,
       XI_A = 0x1000, XI_B = 0x2000, XI_X = 0x4000, XI_Y = 0x8000 };

static GCVirtualController *touch_pad;
static BOOL touch_pad_connected;
static UIWindow *button_window;
static UIView *button_bar;
static uint16_t held_bits;
static uint16_t dpad_bits;   /* the D-pad's directions while it is held */
static UIView *dpad_view;
static CADisplayLink *held_link;
static CGFloat opacity = 1.0;
static NSString *const opacity_key = @"PlayportTouchPadOpacity";
/* Turned off by the player (the opacity button held): the touch pad is
 * disconnected, all of it; only that button stays. */
static BOOL player_hidden;
static NSString *const hidden_key = @"PlayportTouchPadHidden";
static UIButton *home_button, *back_button, *start_button, *opacity_button;
static BOOL opacity_button_shows_pad;
static GCController *touch_controller;  /* the touch pad's GCController while connected */

static void tp_log(NSString *format, ...)
{
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/playport-touchpad.log"];
    NSString *stamped = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], line];
    NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!file)
    {
        [stamped writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    [file seekToEndOfFile];
    [file writeData:[stamped dataUsingEncoding:NSUTF8StringEncoding]];
    [file closeFile];
}

/* ---- Playport's own entry points ---- */

static void resolve_playport(void)
{
    tp_log(@"environment: SDL_JOYSTICK_RAWINPUT=%s WINEDLLOVERRIDES=%s", getenv("SDL_JOYSTICK_RAWINPUT"), getenv("WINEDLLOVERRIDES"));
}

static BOOL menu_is_open(void)
{
    return playport_touchpad_menu_is_open() ? YES : NO;
}

static BOOL menu_open(void)
{
    return playport_touchpad_menu_open() ? YES : NO;
}

/* ---- the pad state with Start / Back added ---- */

static int16_t thumb(float f)
{
    if (f < -1) f = -1;
    if (f > 1) f = 1;
    return (int16_t)(f < 0 ? f * 32768.0f : f * 32767.0f);
}

static void send_pad_state(void)
{
    GCExtendedGamepad *pad = touch_pad.controller.extendedGamepad;
    hio_pad_state st = {0};

    if (!pad) return;
    if (pad.buttonA.isPressed) st.buttons |= XI_A;
    if (pad.buttonB.isPressed) st.buttons |= XI_B;
    if (pad.buttonX.isPressed) st.buttons |= XI_X;
    if (pad.buttonY.isPressed) st.buttons |= XI_Y;
    if (pad.leftShoulder.isPressed) st.buttons |= XI_LB;
    if (pad.rightShoulder.isPressed) st.buttons |= XI_RB;
    st.buttons |= held_bits | dpad_bits;
    st.left_trigger = (uint8_t)(pad.leftTrigger.value * 255.0f + 0.5f);
    st.right_trigger = (uint8_t)(pad.rightTrigger.value * 255.0f + 0.5f);
    st.thumb_lx = thumb(pad.leftThumbstick.xAxis.value);
    st.thumb_ly = thumb(pad.leftThumbstick.yAxis.value);
    st.thumb_rx = thumb(pad.rightThumbstick.xAxis.value);
    st.thumb_ry = thumb(pad.rightThumbstick.yAxis.value);
    host_pad_set(0, &st);
}

@interface TPTarget : NSObject
@end

static void touch_pad_update(NSString *reason);

static TPTarget *target;

/* While anything is held (Start, Back, the D-pad), the state goes every frame:
 * Playport rewrites the slot whenever the touch pad changes. */
static void update_held_link(void)
{
    if ((held_bits | dpad_bits) && !held_link)
    {
        held_link = [CADisplayLink displayLinkWithTarget:target selector:@selector(heldTick)];
        [held_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
    else if (!(held_bits | dpad_bits) && held_link)
    {
        [held_link invalidate];
        held_link = nil;
    }
}

/* ---- the D-pad ----
 *
 * The system's touch pad has no D-pad, and some games need one for weapons or
 * menus. This one sits right of the left button group, level with the left
 * stick, in the colours of Apple's buttons: a dark base like the stick's, a light
 * grey cross, dark arrows. Eight directions, by the touch's angle from the centre
 * in 45-degree steps; nothing near the centre. Its bits join the pad's state as
 * Start and Back do. */
@interface TPDPadView : UIView
@end

@implementation TPDPadView

- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame]))
    {
        self.opaque = NO;
        self.backgroundColor = UIColor.clearColor;
        self.multipleTouchEnabled = NO;
        self.contentMode = UIViewContentModeRedraw;
    }
    return self;
}

- (void)drawRect:(CGRect)rect
{
    CGRect b = self.bounds;
    CGFloat size = MIN(b.size.width, b.size.height), cx = CGRectGetMidX(b), cy = CGRectGetMidY(b);
    CGFloat arm = size * 0.34, len = size * 0.82, radius = arm * 0.3;
    CGRect vertical = CGRectMake(cx - arm / 2, cy - len / 2, arm, len);
    CGRect horizontal = CGRectMake(cx - len / 2, cy - arm / 2, len, arm);
    UIBezierPath *cross = [UIBezierPath bezierPathWithRoundedRect:vertical cornerRadius:radius];
    [cross appendPath:[UIBezierPath bezierPathWithRoundedRect:horizontal cornerRadius:radius]];
    cross.usesEvenOddFillRule = NO;

    [[UIColor colorWithWhite:0.23 alpha:0.85] setFill];
    [[UIBezierPath bezierPathWithOvalInRect:CGRectInset(b, 1, 1)] fill];
    [[UIColor colorWithWhite:0.6 alpha:0.95] setFill];
    [cross fill];

    /* pressed arms are lighter, along the cross */
    struct { uint16_t bit; CGRect half; } arms[4] = {
        { XI_DPAD_UP,    CGRectMake(cx - arm / 2, cy - len / 2, arm, len / 2 - arm / 2) },
        { XI_DPAD_DOWN,  CGRectMake(cx - arm / 2, cy + arm / 2, arm, len / 2 - arm / 2) },
        { XI_DPAD_LEFT,  CGRectMake(cx - len / 2, cy - arm / 2, len / 2 - arm / 2, arm) },
        { XI_DPAD_RIGHT, CGRectMake(cx + arm / 2, cy - arm / 2, len / 2 - arm / 2, arm) },
    };
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    for (int i = 0; i < 4; i++)
    {
        if (!(dpad_bits & arms[i].bit)) continue;
        CGContextSaveGState(ctx);
        [cross addClip];
        [[UIColor colorWithWhite:0.88 alpha:1] setFill];
        UIRectFill(arms[i].half);
        CGContextRestoreGState(ctx);
    }

    /* arrows towards the edges */
    CGFloat t = arm * 0.22, mid = len / 2 - arm * 0.62;
    [[UIColor colorWithWhite:0.3 alpha:1] setFill];
    for (int i = 0; i < 4; i++)
    {
        CGFloat dx = i == 2 ? -1 : i == 3 ? 1 : 0, dy = i == 0 ? -1 : i == 1 ? 1 : 0;
        CGPoint tip = CGPointMake(cx + dx * (mid + t), cy + dy * (mid + t));
        CGPoint baseCenter = CGPointMake(cx + dx * (mid - t * 0.4), cy + dy * (mid - t * 0.4));
        UIBezierPath *tri = [UIBezierPath bezierPath];
        [tri moveToPoint:tip];
        [tri addLineToPoint:CGPointMake(baseCenter.x + dy * t * 1.1, baseCenter.y + dx * t * 1.1)];
        [tri addLineToPoint:CGPointMake(baseCenter.x - dy * t * 1.1, baseCenter.y - dx * t * 1.1)];
        [tri closePath];
        [tri fill];
    }
}

static void set_dpad(uint16_t bits)
{
    if (bits == dpad_bits) return;
    if (bits) [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
    dpad_bits = bits;
    [dpad_view setNeedsDisplay];
    send_pad_state();
    update_held_link();
}

- (void)track:(UITouch *)touch
{
    static const uint16_t sectors[8] = {
        XI_DPAD_RIGHT, XI_DPAD_RIGHT | XI_DPAD_UP, XI_DPAD_UP, XI_DPAD_UP | XI_DPAD_LEFT,
        XI_DPAD_LEFT, XI_DPAD_LEFT | XI_DPAD_DOWN, XI_DPAD_DOWN, XI_DPAD_DOWN | XI_DPAD_RIGHT,
    };
    CGPoint p = [touch locationInView:self];
    CGFloat dx = p.x - CGRectGetMidX(self.bounds), dy = p.y - CGRectGetMidY(self.bounds);
    double angle;

    if (hypot(dx, dy) < self.bounds.size.width * 0.12) { set_dpad(0); return; }
    angle = atan2(-dy, dx) * 180.0 / M_PI;
    if (angle < 0) angle += 360.0;
    set_dpad(sectors[(int)floor((angle + 22.5) / 45.0) % 8]);
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self track:touches.anyObject]; }
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self track:touches.anyObject]; }
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { set_dpad(0); }
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { set_dpad(0); }

@end

/* ---- the overlay: system pad view, our buttons ---- */

/* The system puts the touch pad's view in the key window of the moment it connects.
 * Turned on while our button window was key (after a tap in it), the view lands
 * there, so every window is searched except the button bar. */
static NSArray<UIView *> *controller_views(void)
{
    NSMutableArray *found = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
    {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows)
        {
            NSMutableArray *stack = [NSMutableArray arrayWithObject:window];
            while (stack.count)
            {
                UIView *view = stack.lastObject;
                [stack removeLastObject];
                if (view == button_bar) continue;
                if ([NSStringFromClass(view.class) containsString:@"GCControllerView"])
                {
                    [found addObject:view];
                    continue;
                }
                [stack addObjectsFromArray:view.subviews];
            }
        }
    }
    return found;
}

static void log_controller_views(NSString *when)
{
    NSMutableArray *where = [NSMutableArray array];
    for (UIView *view in controller_views())
        [where addObject:[NSString stringWithFormat:@"%@ in %@%@", NSStringFromClass(view.class),
                          NSStringFromClass(view.window.class), view.window == button_window ? @" (buttons)" : @""]];
    tp_log(@"%@: pad views [%@]", when, [where componentsJoinedByString:@", "]);
}

static BOOL physical_pad_present(void);

static void set_opacity_button_icon(BOOL pad)
{
    UIImageSymbolConfiguration *config;

    if (pad == opacity_button_shows_pad) return;
    opacity_button_shows_pad = pad;
    config = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightSemibold];
    [opacity_button setImage:[UIImage systemImageNamed:pad ? @"gamecontroller.fill" : @"circle.lefthalf.filled"
                                     withConfiguration:config] forState:UIControlStateNormal];
}

static void apply_overlay_state(void)
{
    BOOL menu = menu_is_open();
    BOOL shown = !menu && !physical_pad_present() && (touch_pad_connected || player_hidden);

    for (UIView *view in controller_views())
    {
        view.alpha = opacity;
        view.hidden = menu;
    }
    /* hidden views take no touches: off means off, not invisible */
    home_button.hidden = back_button.hidden = start_button.hidden = player_hidden;
    set_opacity_button_icon(player_hidden);
    button_bar.alpha = player_hidden ? MAX(opacity, 0.6) : opacity;
    /* the D-pad belongs to the touch pad: shown only while it is connected */
    dpad_view.hidden = player_hidden || !touch_pad_connected;
    dpad_view.alpha = opacity;
    if ((dpad_view.hidden || menu) && dpad_bits) set_dpad(0);
    button_window.hidden = !shown;
}

@interface TPPassthroughWindow : UIWindow
@end

@implementation TPPassthroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
    UIView *view = [super hitTest:point withEvent:event];
    return (view == self || view == self.rootViewController.view || view == button_bar) ? nil : view;
}
@end

@interface TPRootController : UIViewController
@end

@implementation TPRootController
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
@end

@implementation TPTarget

- (void)homeTapped
{
    BOOL opened = menu_open();
    tp_log(@"Home: Playport menu %@", opened ? @"opened" : @"not opened (no game running)");
    apply_overlay_state();
}

- (void)startDown { [self hold:XI_START]; }
- (void)backDown { [self hold:XI_BACK]; }
- (void)startUp { [self letGo:XI_START]; }
- (void)backUp { [self letGo:XI_BACK]; }

- (void)hold:(uint16_t)bit
{
    if (menu_is_open()) return;
    held_bits |= bit;
    send_pad_state();
    update_held_link();
}

- (void)letGo:(uint16_t)bit
{
    held_bits &= ~bit;
    send_pad_state();
    update_held_link();
}

- (void)heldTick { send_pad_state(); }

- (void)opacityTapped
{
    if (player_hidden) return;
    opacity = opacity > 0.9 ? 0.75 : opacity > 0.6 ? 0.5 : opacity > 0.4 ? 0.3 : 1.0;
    [NSUserDefaults.standardUserDefaults setDouble:opacity forKey:opacity_key];
    apply_overlay_state();
    log_controller_views([NSString stringWithFormat:@"opacity %.0f%%", opacity * 100]);
}

/* Held: the touch pad off, all of it (it disconnects, its overlay and touches go), or back on. */
- (void)opacityLongPress:(UILongPressGestureRecognizer *)gesture
{
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    player_hidden = !player_hidden;
    [NSUserDefaults.standardUserDefaults setBool:player_hidden forKey:hidden_key];
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
    if (player_hidden && (held_bits | dpad_bits))
    {
        held_bits = dpad_bits = 0;
        [dpad_view setNeedsDisplay];
        send_pad_state();
        update_held_link();
    }
    touch_pad_update(player_hidden ? @"turned off by the player" : @"turned on by the player");
    apply_overlay_state();
}

- (void)tick { apply_overlay_state(); }

@end

static UIButton *make_button(NSString *symbol, SEL down, SEL up)
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightSemibold];
    [button setImage:[UIImage systemImageNamed:symbol withConfiguration:config] forState:UIControlStateNormal];
    button.tintColor = UIColor.whiteColor;
    button.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.55];
    button.layer.cornerRadius = 20;
    button.layer.borderWidth = 1;
    button.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.35].CGColor;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.widthAnchor constraintEqualToConstant:40].active = YES;
    [button.heightAnchor constraintEqualToConstant:40].active = YES;
    if (up)
    {
        [button addTarget:target action:down forControlEvents:UIControlEventTouchDown];
        [button addTarget:target action:up forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    }
    else [button addTarget:target action:down forControlEvents:UIControlEventTouchUpInside];
    return button;
}

static void buttons_start(void)
{
    UIWindowScene *scene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
        if ([s isKindOfClass:UIWindowScene.class]) { scene = (UIWindowScene *)s; break; }
    if (!scene) { tp_log(@"no window scene for the buttons"); return; }

    target = [[TPTarget alloc] init];
    button_window = [[TPPassthroughWindow alloc] initWithWindowScene:scene];
    button_window.windowLevel = UIWindowLevelAlert + 1;
    button_window.backgroundColor = UIColor.clearColor;
    TPRootController *root = [[TPRootController alloc] init];
    root.view.backgroundColor = UIColor.clearColor;
    button_window.rootViewController = root;

    home_button = make_button(@"house.fill", @selector(homeTapped), NULL);
    back_button = make_button(@"rectangle.on.rectangle", @selector(backDown), @selector(backUp));
    start_button = make_button(@"line.3.horizontal", @selector(startDown), @selector(startUp));
    opacity_button = make_button(@"circle.lefthalf.filled", @selector(opacityTapped), NULL);
    UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc] initWithTarget:target
                                                                                        action:@selector(opacityLongPress:)];
    hold.minimumPressDuration = 0.6;
    [opacity_button addGestureRecognizer:hold];  /* cancels the tap once recognised */
    UIStackView *bar = [[UIStackView alloc] initWithArrangedSubviews:@[home_button, back_button, start_button, opacity_button]];
    bar.axis = UILayoutConstraintAxisHorizontal;
    bar.spacing = 14;
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    button_bar = bar;
    [root.view addSubview:bar];
    [bar.centerXAnchor constraintEqualToAnchor:root.view.centerXAnchor].active = YES;
    [bar.topAnchor constraintEqualToAnchor:root.view.safeAreaLayoutGuide.topAnchor constant:8].active = YES;

    /* The D-pad right of the system pad's left group, centred on its stick's height.
     * The group ends about 189 pt from the safe area's left edge, and the stick's
     * centre is 98 pt above its bottom edge (iPhone 17 Pro Max, iOS 27). */
    dpad_view = [[TPDPadView alloc] initWithFrame:CGRectMake(0, 0, 104, 104)];
    dpad_view.translatesAutoresizingMaskIntoConstraints = NO;
    [root.view addSubview:dpad_view];
    [dpad_view.widthAnchor constraintEqualToConstant:104].active = YES;
    [dpad_view.heightAnchor constraintEqualToConstant:104].active = YES;
    [dpad_view.centerXAnchor constraintEqualToAnchor:root.view.safeAreaLayoutGuide.leftAnchor constant:251].active = YES;
    [dpad_view.centerYAnchor constraintEqualToAnchor:root.view.safeAreaLayoutGuide.bottomAnchor constant:-98].active = YES;

    button_window.hidden = NO;
    [NSTimer scheduledTimerWithTimeInterval:0.5 target:target selector:@selector(tick) userInfo:nil repeats:YES];
    tp_log(@"buttons shown: Home, Back, Start, opacity %.0f%%%@", opacity * 100, player_hidden ? @"; touch pad off" : @"");
}

/* ---- the system pad ---- */

static void log_controllers(NSString *when)
{
    NSMutableArray *names = [NSMutableArray array];
    for (GCController *c in GCController.controllers)
        [names addObject:[NSString stringWithFormat:@"%@%@%@", c.vendorName, c.extendedGamepad ? @" (extended)" : @"",
                          (touch_pad && c == touch_pad.controller) ? @" [touch]" : @""]];
    tp_log(@"%@: GCController.controllers = [%@]", when, [names componentsJoinedByString:@", "]);
}

/* A connected pad that is not the touch pad itself. */
static BOOL physical_pad_present(void)
{
    for (GCController *controller in GCController.controllers)
    {
        if (controller == touch_controller || (touch_pad && controller == touch_pad.controller)) continue;
        if (controller.extendedGamepad) return YES;
    }
    return NO;
}

static void touch_pad_update(NSString *reason)
{
    BOOL physical = physical_pad_present();

    if ((physical || player_hidden) && touch_pad_connected)
    {
        [touch_pad disconnect];
        touch_pad_connected = NO;
        tp_log(@"%@: %@, touch pad disconnected", reason, physical ? @"a physical pad is connected" : @"off");
        apply_overlay_state();
    }
    else if (!physical && !player_hidden && !touch_pad_connected)
    {
        touch_pad_connected = YES;
        [touch_pad connectWithReplyHandler:^(NSError *error) {
            if (error)
            {
                touch_pad_connected = NO;
                tp_log(@"%@: connect failed: %@", reason, error);
            }
            else
            {
                touch_controller = touch_pad.controller;
                tp_log(@"%@: touch pad shown (%@)", reason, touch_pad.controller.vendorName);
                apply_overlay_state();
                /* the pad's view appears a little after it connects */
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    log_controller_views(reason);
                });
            }
        }];
    }
}

/* The system draws only some elements: an element set it refuses throws from
 * the initializer, so each set is tried in turn, the fullest first. */
static GCVirtualController *touch_pad_create(void)
{
    NSArray *base = @[
        GCInputLeftThumbstick, GCInputRightThumbstick,
        GCInputButtonA, GCInputButtonB, GCInputButtonX, GCInputButtonY,
        GCInputLeftShoulder, GCInputRightShoulder,
    ];
    NSArray *sets = @[ [base arrayByAddingObjectsFromArray:@[GCInputLeftTrigger, GCInputRightTrigger]], base ];

    for (NSArray *elements in sets)
    {
        GCVirtualControllerConfiguration *config = [[GCVirtualControllerConfiguration alloc] init];
        config.elements = [NSSet setWithArray:elements];
        @try
        {
            GCVirtualController *pad = [GCVirtualController virtualControllerWithConfiguration:config];
            tp_log(@"touch pad created with %lu elements", (unsigned long)elements.count);
            return pad;
        }
        @catch (NSException *e)
        {
            tp_log(@"%lu elements refused: %@: %@", (unsigned long)elements.count, e.name, e.reason);
        }
    }
    return nil;
}

static void touch_pad_start(void)
{
    if (touch_pad) return;
    resolve_playport();
    NSNumber *saved = [NSUserDefaults.standardUserDefaults objectForKey:opacity_key];
    if (saved) opacity = saved.doubleValue;
    player_hidden = [NSUserDefaults.standardUserDefaults boolForKey:hidden_key];
    if (!(touch_pad = touch_pad_create())) return;
    buttons_start();

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserverForName:GCControllerDidConnectNotification object:nil queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *note) {
        GCController *controller = note.object;
        if (controller == touch_controller || controller == touch_pad.controller) return;
        log_controllers([NSString stringWithFormat:@"did connect \"%@\"", controller.vendorName]);
        touch_pad_update([NSString stringWithFormat:@"connected \"%@\"", controller.vendorName]);
    }];
    [nc addObserverForName:GCControllerDidDisconnectNotification object:nil queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *note) {
        GCController *controller = note.object;
        if (controller == touch_controller || controller == touch_pad.controller) return;
        touch_pad_update([NSString stringWithFormat:@"disconnected \"%@\"", controller.vendorName]);
    }];
    touch_pad_update(@"start");
}

/* Before the runtime starts (the constructor runs before main). The prototype
 * also set MADEIRA_KEEP_SMC=1 (FEX 0.4.0's Mono fault, which main fixes with fex
 * 0033/0038) and a WINEDLLOVERRIDES to stop HostIO disabling windows.gaming.input
 * (PR #53 leaves it enabled itself); neither is needed on main.
 * - SDL_JOYSTICK_RAWINPUT=0: SDL 2.0.14 and later (Half-Life 2, Baldur's Gate 3)
 *   gives XInput pads to its RawInput driver once the pad is in the raw input list,
 *   and turns its XInput driver off, but the pad sends no WM_INPUT: without this
 *   the game sees no pad. */
static void runtime_environment(void)
{
    setenv("SDL_JOYSTICK_RAWINPUT", "0", 0);
}

/* ---- Baldur's Gate 3 without the Larian launcher ---- */

static NSString *const bg3_title = @"app-1086940";

/* Steam's launch entry is Launcher\LariLauncher.exe, which needs .NET 6: Playport
 * has none, and it exits at once. The game does not need it. The chosen executable
 * (chosenExecutable, the game page's Executable, which Playport hides for Steam
 * games) is kept by every rescan of the catalogue. The catalogue is read after
 * this library loads, so the choice holds from this start of Playport; a game
 * downloaded during this run gets it at the next start. */
static void bg3_executable(void)
{
    NSString *support = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Playport"];
    NSString *path = [support stringByAppendingPathComponent:@"catalog.json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return;
    NSMutableDictionary *catalog = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
    if (![catalog isKindOfClass:NSDictionary.class] || ![catalog[@"titles"] isKindOfClass:NSArray.class]) return;
    for (NSMutableDictionary *title in catalog[@"titles"])
    {
        if (![title isKindOfClass:NSDictionary.class] || ![title[@"id"] isEqual:bg3_title]) continue;
        if (title[@"chosenExecutable"]) return;  /* the player's choice, or already ours */
        NSString *exe = title[@"executable"], *dir = title[@"installDir"];
        if (![exe isKindOfClass:NSString.class] || ![dir isKindOfClass:NSString.class]) return;
        if (![exe.lowercaseString hasPrefix:@"launcher\\"]) return;
        NSString *game = [NSString stringWithFormat:@"Documents/prefix/drive_c/Games/%@/bin/bg3_dx11.exe", dir];
        if (![NSFileManager.defaultManager fileExistsAtPath:[NSHomeDirectory() stringByAppendingPathComponent:game]]) return;
        title[@"chosenExecutable"] = @"bin\\bg3_dx11.exe";
        title[@"executable"] = @"bin\\bg3_dx11.exe";
        NSData *out = [NSJSONSerialization dataWithJSONObject:catalog
                                                      options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys | NSJSONWritingWithoutEscapingSlashes
                                                        error:nil];
        BOOL saved = out && [out writeToFile:path atomically:YES];
        tp_log(@"Baldur's Gate 3: %@ -> bin\\bg3_dx11.exe %@", exe, saved ? @"set" : @"NOT saved");
        return;
    }
}

/* By default Playport picks Vulkan: the game's SDL2.dll references d3d12.dll,
 * which counts as Direct3D 12. On Vulkan the game lags and crashes; on DXMT it
 * plays. DXMT is set until the player picks a Direct3D themselves. */
static void bg3_graphics(void)
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSData *stored = [defaults dataForKey:@"launchSettings.games"];
    NSDictionary *all = stored ? [NSJSONSerialization JSONObjectWithData:stored options:0 error:nil] : @{};
    if (![all isKindOfClass:NSDictionary.class]) return;
    NSMutableDictionary *games = [all mutableCopy];
    NSMutableDictionary *settings = [games[bg3_title] isKindOfClass:NSDictionary.class] ? [games[bg3_title] mutableCopy]
                                                                                         : [NSMutableDictionary dictionary];
    if (settings[@"graphics"]) return;
    settings[@"graphics"] = @"dxmt";
    games[bg3_title] = settings;
    NSData *out = [NSJSONSerialization dataWithJSONObject:games options:0 error:nil];
    if (!out) return;
    [defaults setObject:out forKey:@"launchSettings.games"];
    tp_log(@"Baldur's Gate 3: Direct3D set to DXMT");
}

/* Diagnostics on request: Documents/playport-diag.env, KEY=VALUE lines. Each is
 * set before the runtime starts and wins over Playport's value (it sets WINEDEBUG
 * without overwriting), except PLAYPORT_LOG_LIMIT_MB, the log's cap for a session
 * instead of a release's 4 MB (AppLog.limit). Without the file, nothing. */
static long diag_log_limit_mb;

/* Merges src into dst: dictionaries recursively, NSNull removes the key. */
static void merge_settings(NSMutableDictionary *dst, NSDictionary *src)
{
    for (NSString *key in src)
    {
        id value = src[key];
        if (value == NSNull.null) [dst removeObjectForKey:key];
        else if ([value isKindOfClass:NSDictionary.class] && [dst[key] isKindOfClass:NSDictionary.class])
        {
            NSMutableDictionary *inner = [dst[key] mutableCopy];
            merge_settings(inner, value);
            dst[key] = inner;
        }
        else dst[key] = value;
    }
}

/* PLAYPORT_GAME_SETTINGS=<game id> <JSON>: merged over the game's Playport settings
 * (UserDefaults launchSettings.games, LaunchSettingsStore), the ones a release
 * build does not show included (ordering.tso, maxInst, diskCache...; a release
 * build resets those at launch). */
static void diag_game_settings(NSString *value)
{
    NSRange space = [value rangeOfString:@" "];
    if (space.location == NSNotFound) return;
    NSString *game = [value substringToIndex:space.location];
    NSData *json = [[value substringFromIndex:space.location + 1] dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *patch = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
    if (![patch isKindOfClass:NSDictionary.class]) { tp_log(@"diag: settings for %@ are not a JSON object", game); return; }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSData *stored = [defaults dataForKey:@"launchSettings.games"];
    NSDictionary *all = stored ? [NSJSONSerialization JSONObjectWithData:stored options:0 error:nil] : @{};
    NSMutableDictionary *games = [all isKindOfClass:NSDictionary.class] ? [all mutableCopy] : [NSMutableDictionary dictionary];
    NSMutableDictionary *settings = [games[game] isKindOfClass:NSDictionary.class] ? [games[game] mutableCopy]
                                                                                    : [NSMutableDictionary dictionary];
    merge_settings(settings, patch);
    games[game] = settings;
    [defaults setObject:[NSJSONSerialization dataWithJSONObject:games options:0 error:nil] forKey:@"launchSettings.games"];
    NSData *now = [NSJSONSerialization dataWithJSONObject:settings options:NSJSONWritingSortedKeys error:nil];
    tp_log(@"diag: settings of %@ now %@", game, [[NSString alloc] initWithData:now encoding:NSUTF8StringEncoding]);
}

static void diag_environment(void)
{
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/playport-diag.env"];
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    for (NSString *raw in [text componentsSeparatedByString:@"\n"])
    {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSRange eq = [line rangeOfString:@"="];
        if (!line.length || [line hasPrefix:@"#"] || eq.location == NSNotFound || !eq.location) continue;
        NSString *key = [line substringToIndex:eq.location];
        NSString *value = [line substringFromIndex:eq.location + 1];
        if ([key isEqualToString:@"PLAYPORT_LOG_LIMIT_MB"]) diag_log_limit_mb = value.integerValue;
        else if ([key isEqualToString:@"PLAYPORT_GAME_SETTINGS"]) diag_game_settings(value);
        else setenv(key.UTF8String, value.UTF8String, 1);
    }
}

/* After AppLog.start (the app's init sets 4 MB): the log's watchdog reads the
 * cap every second, so a new one holds after the start too. */
static void diag_log_limit(void)
{
    if (diag_log_limit_mb <= 0) return;
    long bytes = diag_log_limit_mb << 20;
    wine_host_set_log_limit((size_t)bytes);
    host_log_set_limit(bytes);
    tp_log(@"diag: log limit %ld MB, WINEDEBUG=%s", diag_log_limit_mb, getenv("WINEDEBUG"));
}

__attribute__((constructor))
static void touch_pad_init(void)
{
    runtime_environment();
    bg3_executable();
    bg3_graphics();
    diag_environment();
    /* The overlay needs the app's window: start once the app is active the first time. */
    __block id observer = [NSNotificationCenter.defaultCenter
        addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *note) {
        [NSNotificationCenter.defaultCenter removeObserver:observer];
        diag_log_limit();
        /* Controllers already paired are reported shortly after launch. */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            touch_pad_start();
        });
    }];
}

/* Referenced from the app (PlayportApp.init) so the linker keeps this object,
 * and with it the constructor above. */
void playport_touchpad_linked(void)
{
}
