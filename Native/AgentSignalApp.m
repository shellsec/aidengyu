#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <UserNotifications/UserNotifications.h>
#import <math.h>
#import "SignalCore.h"

static NSColor *ASColorForName(NSString *name) {
    if ([name isEqualToString:@"red"]) {
        return [NSColor colorWithRed:0.95 green:0.19 blue:0.18 alpha:1.0];
    }
    if ([name isEqualToString:@"yellow"]) {
        return [NSColor colorWithRed:1.0 green:0.72 blue:0.12 alpha:1.0];
    }
    if ([name isEqualToString:@"green"]) {
        return [NSColor colorWithRed:0.18 green:0.82 blue:0.39 alpha:1.0];
    }
    return NSColor.grayColor;
}

static NSImage *ASAgentLogo(NSString *agent) {
    NSString *resourceName = [agent isEqualToString:ASAgentClaude] ? @"claude" :
        ([agent isEqualToString:ASAgentCursor] ? @"cursor" : @"openai");
    NSURL *resourceURL = [NSBundle.mainBundle URLForResource:resourceName withExtension:@"svg"];
    NSImage *image = resourceURL ? [[NSImage alloc] initWithContentsOfURL:resourceURL] : nil;
    if (!image) {
        NSString *fallback = [agent isEqualToString:ASAgentClaude] ?
            @"chevron.left.forwardslash.chevron.right" :
            ([agent isEqualToString:ASAgentCursor] ? @"cursorarrow" : @"circle.hexagongrid.fill");
        image = [NSImage imageWithSystemSymbolName:fallback accessibilityDescription:ASAgentDisplayName(agent)];
    }
    image.template = YES;
    return image;
}

typedef NS_ENUM(NSInteger, ASLampMode) {
    ASLampModeSingle = 1,
    ASLampModeTriple = 3
};

static NSString * const ASLampModeDefaultsKey = @"lampMode";
static NSString * const ASMaxVisibleSessionsDefaultsKey = @"maxVisibleSessions";

static CGFloat ASEffectIntensity(NSString *effect, NSDate *updatedAt) {
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    if ([effect isEqualToString:@"off"]) return 0;
    if ([effect isEqualToString:@"steady"]) return 1;
    if ([effect isEqualToString:@"breathe"]) {
        return 0.32 + 0.68 * ((sin(now * M_PI * 2.0 / 1.6) + 1.0) / 2.0);
    }
    if ([effect isEqualToString:@"slow_blink"]) return fmod(now, 1.0) < 0.58 ? 1 : 0.12;
    if ([effect isEqualToString:@"fast_blink"]) return fmod(now, 0.4) < 0.2 ? 1 : 0.1;
    if ([effect isEqualToString:@"double_flash"]) {
        NSTimeInterval elapsed = MAX(0, [NSDate.date timeIntervalSinceDate:updatedAt ?: NSDate.date]);
        if (elapsed >= 1.35) return 1;
        NSTimeInterval phase = fmod(elapsed, 0.8);
        return (phase < 0.16 || (phase >= 0.3 && phase < 0.46)) ? 1 : 0.12;
    }
    return 1;
}

@interface ASTrafficLightView : NSView
@property(nonatomic, copy) NSString *state;
@property(nonatomic, strong) NSDate *updatedAt;
@property(nonatomic, strong) NSTimer *animationTimer;
@property(nonatomic, assign) ASLampMode lampMode;
@end

@implementation ASTrafficLightView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _state = ASStateOffline;
        _updatedAt = NSDate.date;
        _lampMode = ASLampModeSingle;
        _animationTimer = [NSTimer timerWithTimeInterval:0.05
            target:self selector:@selector(animationTick:) userInfo:nil repeats:YES];
        [NSRunLoop.mainRunLoop addTimer:_animationTimer forMode:NSRunLoopCommonModes];
        self.wantsLayer = YES;
    }
    return self;
}

- (void)dealloc {
    [_animationTimer invalidate];
}

- (BOOL)isFlipped { return YES; }

- (BOOL)mouseDownCanMoveWindow { return YES; }

- (void)animationTick:(NSTimer *)timer {
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    NSDictionary *presentation = ASLampPresentation(self.state);
    NSString *activeColor = presentation[@"color"];
    CGFloat intensity = ASEffectIntensity(presentation[@"effect"], self.updatedAt);
    NSArray<NSString *> *colors = self.lampMode == ASLampModeSingle ?
        @[[activeColor isEqualToString:@"off"] ? @"gray" : activeColor] :
        @[@"red", @"yellow", @"green"];

    NSRect housingRect = NSInsetRect(self.bounds, 1.5, 1.5);
    CGFloat housingRadius = self.lampMode == ASLampModeSingle ? 14 : 10;
    NSBezierPath *housing = [NSBezierPath bezierPathWithRoundedRect:housingRect
        xRadius:housingRadius yRadius:housingRadius];
    [[NSColor colorWithWhite:0.045 alpha:0.9] setFill];
    [housing fill];
    [[NSColor colorWithWhite:0.55 alpha:0.42] setStroke];
    housing.lineWidth = 1;
    [housing stroke];

    for (NSUInteger index = 0; index < colors.count; index++) {
        NSString *name = colors[index];
        BOOL active = ![activeColor isEqualToString:@"off"] &&
            (self.lampMode == ASLampModeSingle || [name isEqualToString:activeColor]);
        CGFloat alpha = active ? 0.44 + intensity * 0.56 : 0.16;
        CGFloat lampY = self.lampMode == ASLampModeSingle ? 10 : 8 + index * 34;
        NSRect visorRect = self.lampMode == ASLampModeSingle ?
            NSMakeRect(5, 5, 48, 31) : NSMakeRect(5, lampY - 3, 42, 24);
        NSBezierPath *visor = [NSBezierPath bezierPathWithRoundedRect:visorRect xRadius:12 yRadius:12];
        [[NSColor colorWithWhite:0.015 alpha:0.94] setFill];
        [visor fill];

        NSRect rimRect = self.lampMode == ASLampModeSingle ?
            NSMakeRect(9, 10, 40, 40) : NSMakeRect(9, lampY, 34, 34);
        [[NSColor colorWithWhite:0.01 alpha:0.98] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:rimRect] fill];

        NSRect circleRect = NSInsetRect(rimRect, self.lampMode == ASLampModeSingle ? 3.6 : 3.2,
            self.lampMode == ASLampModeSingle ? 3.6 : 3.2);

        [NSGraphicsContext saveGraphicsState];
        if (active) {
            NSShadow *shadow = [[NSShadow alloc] init];
            shadow.shadowBlurRadius = self.lampMode == ASLampModeSingle ? 14 : 11;
            shadow.shadowOffset = NSZeroSize;
            shadow.shadowColor = [ASColorForName(name) colorWithAlphaComponent:intensity * 0.82];
            [shadow set];
        }
        [[ASColorForName(name) colorWithAlphaComponent:alpha] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:circleRect] fill];
        [NSGraphicsContext restoreGraphicsState];

        [[NSColor.whiteColor colorWithAlphaComponent:active ? 0.34 : 0.1] setStroke];
        NSBezierPath *border = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(circleRect, 0.4, 0.4)];
        border.lineWidth = 0.9;
        [border stroke];

        if (active) {
            [[NSColor.whiteColor colorWithAlphaComponent:0.22 + intensity * 0.28] setFill];
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(
                NSMinX(circleRect) + 6, NSMinY(circleRect) + 5, 8, 4.5
            )] fill];
        }
    }
}

@end

@interface ASDragLabel : NSTextField
@end

@implementation ASDragLabel
- (BOOL)mouseDownCanMoveWindow { return YES; }
@end

static NSTextField *ASLabel(NSString *text, CGFloat size, NSFontWeight weight) {
    ASDragLabel *label = [[ASDragLabel alloc] initWithFrame:NSZeroRect];
    label.stringValue = text ?: @"";
    label.bezeled = NO;
    label.drawsBackground = NO;
    label.editable = NO;
    label.selectable = NO;
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.textColor = NSColor.labelColor;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    label.maximumNumberOfLines = 1;
    return label;
}

@interface ASSessionSignalView : NSView
- (instancetype)initWithSignal:(NSDictionary *)signal
    lampMode:(ASLampMode)lampMode
    showsSeparator:(BOOL)showsSeparator;
@end

@implementation ASSessionSignalView

- (BOOL)isFlipped { return YES; }
- (BOOL)mouseDownCanMoveWindow { return YES; }

- (instancetype)initWithSignal:(NSDictionary *)signal
    lampMode:(ASLampMode)lampMode
    showsSeparator:(BOOL)showsSeparator {
    CGFloat itemHeight = lampMode == ASLampModeSingle ? 88 : 124;
    self = [super initWithFrame:NSMakeRect(0, 0, 286, itemHeight)];
    if (!self) return nil;
    self.wantsLayer = YES;

    NSString *agent = signal[@"agent"] ?: ASAgentCodex;
    NSString *cwd = signal[@"cwd"];
    NSString *project = cwd.length ? cwd.lastPathComponent : @"未知项目";
    NSString *taskTitle = signal[@"task_title"];
    NSString *state = ASDisplayState(signal, NSDate.date);

    NSRect lightFrame = lampMode == ASLampModeSingle ?
        NSMakeRect(12, 14, 58, 58) : NSMakeRect(12, 6, 50, 112);
    ASTrafficLightView *lights = [[ASTrafficLightView alloc] initWithFrame:lightFrame];
    lights.state = state;
    lights.updatedAt = ASSignalUpdatedAt(signal) ?: NSDate.date;
    lights.lampMode = lampMode;
    [self addSubview:lights];

    NSRect iconFrame = lampMode == ASLampModeSingle ?
        NSMakeRect(82, 12, 30, 30) : NSMakeRect(80, 14, 34, 34);
    NSImageView *agentIcon = [[NSImageView alloc] initWithFrame:iconFrame];
    agentIcon.image = ASAgentLogo(agent);
    agentIcon.imageScaling = NSImageScaleProportionallyUpOrDown;
    agentIcon.contentTintColor = [agent isEqualToString:ASAgentClaude] ?
        [NSColor colorWithRed:0.82 green:0.36 blue:0.24 alpha:1] : NSColor.labelColor;
    agentIcon.toolTip = ASAgentDisplayName(agent);
    agentIcon.accessibilityLabel = ASAgentDisplayName(agent);
    [self addSubview:agentIcon];

    NSTextField *taskLabel = ASLabel(taskTitle.length ? taskTitle : project, 12, NSFontWeightSemibold);
    taskLabel.maximumNumberOfLines = 2;
    taskLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    taskLabel.cell.wraps = YES;
    taskLabel.frame = lampMode == ASLampModeSingle ?
        NSMakeRect(122, 8, 152, 36) : NSMakeRect(126, 11, 148, 39);
    [self addSubview:taskLabel];

    NSTextField *projectLabel = ASLabel(project, 9, NSFontWeightRegular);
    projectLabel.textColor = NSColor.secondaryLabelColor;
    projectLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    projectLabel.frame = lampMode == ASLampModeSingle ?
        NSMakeRect(82, 53, 116, 16) : NSMakeRect(80, 59, 194, 16);
    [self addSubview:projectLabel];

    NSTextField *stateLabel = ASLabel(ASStateTitle(state), 10, NSFontWeightMedium);
    stateLabel.textColor = [state isEqualToString:ASStateReady] ?
        ASColorForName(@"green") : [NSColor.labelColor colorWithAlphaComponent:0.82];
    stateLabel.frame = lampMode == ASLampModeSingle ?
        NSMakeRect(202, 52, 72, 18) : NSMakeRect(80, 88, 132, 18);
    if (lampMode == ASLampModeSingle) stateLabel.alignment = NSTextAlignmentRight;
    [self addSubview:stateLabel];

    if (showsSeparator) {
        NSView *separator = [[NSView alloc] initWithFrame:NSMakeRect(78, itemHeight - 1, 196, 1)];
        separator.wantsLayer = YES;
        separator.layer.backgroundColor = [NSColor.whiteColor colorWithAlphaComponent:0.13].CGColor;
        [self addSubview:separator];
    }

    NSMutableArray *parts = [NSMutableArray arrayWithObjects:ASAgentDisplayName(agent),
        taskTitle.length ? taskTitle : project, ASStateTitle(state), nil];
    NSString *detail = signal[@"detail"];
    if (detail.length) [parts addObject:detail];
    self.toolTip = [parts componentsJoinedByString:@" · "];
    self.accessibilityLabel = [NSString stringWithFormat:@"%@，%@，%@",
        ASAgentDisplayName(agent), taskTitle.length ? taskTitle : project, ASStateTitle(state)];
    return self;
}

@end


@interface ASSessionMonitor : NSObject
@property(nonatomic, copy) NSArray<NSDictionary *> *signals;
@property(nonatomic, copy) void (^updateHandler)(NSArray<NSDictionary *> *signals);
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, copy) NSString *lastFingerprint;
- (void)reload;
- (NSString *)aggregateState;
- (void)clear;
- (void)forceReload;
@end

@implementation ASSessionMonitor

- (instancetype)init {
    self = [super init];
    if (self) {
        _signals = @[];
        [self reload];
        _timer = [NSTimer timerWithTimeInterval:0.25
            target:self selector:@selector(reload) userInfo:nil repeats:YES];
        [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
    }
    return self;
}

- (void)dealloc { [_timer invalidate]; }

- (void)reload {
    NSDate *now = NSDate.date;
    NSMutableArray<NSDictionary *> *visible = [NSMutableArray array];
    for (NSDictionary *signal in ASLoadSignals(ASSignalRootURL())) {
        if (!ASShouldShowSignal(signal, now)) continue;
        [visible addObject:signal];
    }

    NSInteger maxVisible = ASNormalizeMaxVisibleSessions(
        [NSUserDefaults.standardUserDefaults integerForKey:ASMaxVisibleSessionsDefaultsKey]);
    NSArray<NSDictionary *> *limited = ASLimitVisibleSignals(visible, maxVisible);
    NSMutableArray<NSDictionary *> *sorted = [limited mutableCopy];
    [sorted sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        NSInteger leftPriority = ASStatePriority(ASDisplayState(left, now));
        NSInteger rightPriority = ASStatePriority(ASDisplayState(right, now));
        if (leftPriority != rightPriority) return leftPriority > rightPriority ? NSOrderedAscending : NSOrderedDescending;
        NSComparisonResult agentOrder = [left[@"agent"] compare:right[@"agent"]];
        if (agentOrder != NSOrderedSame) return agentOrder;
        return [right[@"updated_at"] compare:left[@"updated_at"]];
    }];

    NSMutableArray<NSString *> *fingerprintParts = [NSMutableArray array];
    for (NSDictionary *signal in sorted) {
        [fingerprintParts addObject:[NSString stringWithFormat:@"%@:%@:%@:%@",
            signal[@"agent"], signal[@"session_id"], signal[@"updated_at"], ASDisplayState(signal, now)]];
    }
    NSString *fingerprint = [fingerprintParts componentsJoinedByString:@"|"];
    if (![fingerprint isEqualToString:self.lastFingerprint]) {
        self.lastFingerprint = fingerprint;
        self.signals = sorted;
        if (self.updateHandler) self.updateHandler(self.signals);
    }
}

- (NSString *)aggregateState {
    NSString *best = ASStateOffline;
    NSInteger bestPriority = -1;
    for (NSDictionary *signal in self.signals) {
        NSString *state = ASDisplayState(signal, NSDate.date);
        NSInteger priority = ASStatePriority(state);
        if (priority > bestPriority) {
            best = state;
            bestPriority = priority;
        }
    }
    return best;
}

- (void)clear {
    ASClearSignals(ASSignalRootURL(), nil);
    self.lastFingerprint = nil;
    [self reload];
}

- (void)forceReload {
    self.lastFingerprint = nil;
    [self reload];
}

@end


@interface ASDraggableEffectView : NSVisualEffectView
@property(nonatomic, strong) CAShapeLayer *cornerMaskLayer;
@property(nonatomic, strong) CAShapeLayer *roundedBorderLayer;
@end

@implementation ASDraggableEffectView
- (BOOL)mouseDownCanMoveWindow { return YES; }

- (void)layout {
    [super layout];
    if (!self.layer) return;

    if (!self.cornerMaskLayer) {
        self.cornerMaskLayer = [CAShapeLayer layer];
        self.layer.mask = self.cornerMaskLayer;
    }
    if (!self.roundedBorderLayer) {
        self.roundedBorderLayer = [CAShapeLayer layer];
        self.roundedBorderLayer.fillColor = NSColor.clearColor.CGColor;
        self.roundedBorderLayer.strokeColor = [NSColor.whiteColor colorWithAlphaComponent:0.18].CGColor;
        self.roundedBorderLayer.lineWidth = 1;
        self.roundedBorderLayer.zPosition = 1000;
        [self.layer addSublayer:self.roundedBorderLayer];
    }

    CGPathRef maskPath = CGPathCreateWithRoundedRect(self.bounds, 8, 8, NULL);
    self.cornerMaskLayer.frame = self.bounds;
    self.cornerMaskLayer.path = maskPath;
    CGPathRelease(maskPath);

    CGRect borderRect = CGRectInset(self.bounds, 0.5, 0.5);
    CGPathRef borderPath = CGPathCreateWithRoundedRect(borderRect, 7.5, 7.5, NULL);
    self.roundedBorderLayer.frame = self.bounds;
    self.roundedBorderLayer.path = borderPath;
    CGPathRelease(borderPath);
}
@end

@interface ASFlippedView : NSView
@end

@implementation ASFlippedView
- (BOOL)isFlipped { return YES; }
- (BOOL)mouseDownCanMoveWindow { return YES; }
@end

static NSString * const ASPanelHasSavedPositionKey = @"panelHasSavedPosition";
static NSString * const ASPanelOriginXKey = @"panelOriginX";
static NSString * const ASPanelOriginYKey = @"panelOriginY";

@interface ASTopPanelController : NSObject <NSWindowDelegate>
@property(nonatomic, strong) NSPanel *panel;
@property(nonatomic, strong) ASDraggableEffectView *rootView;
@property(nonatomic, strong) NSScrollView *scrollView;
@property(nonatomic, strong) ASFlippedView *documentView;
@property(nonatomic, copy) NSArray<NSDictionary *> *signals;
@property(nonatomic, assign) ASLampMode lampMode;
@property(nonatomic, assign) BOOL userHidden;
@property(nonatomic, assign) BOOL userPositioned;
@property(nonatomic, assign) BOOL didInitialLayout;
@property(nonatomic, assign) BOOL suppressMoveHandling;
@property(nonatomic, readonly, getter=isVisible) BOOL visible;
- (instancetype)initWithSignals:(NSArray<NSDictionary *> *)signals;
- (void)updateSignals:(NSArray<NSDictionary *> *)signals;
- (NSScreen *)currentScreen;
- (NSRect)constrainedFrame:(NSRect)frame forScreen:(NSScreen *)screen;
- (void)toggle;
- (void)resetPosition;
- (void)changeLampMode:(ASLampMode)lampMode;
@end

@implementation ASTopPanelController

- (instancetype)initWithSignals:(NSArray<NSDictionary *> *)signals {
    self = [super init];
    if (!self) return nil;

    _panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 294, 136)
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO];
    _panel.level = NSStatusWindowLevel;
    _panel.opaque = NO;
    _panel.backgroundColor = NSColor.clearColor;
    _panel.alphaValue = 0.96;
    _panel.hasShadow = NO;
    _panel.hidesOnDeactivate = NO;
    _panel.becomesKeyOnlyIfNeeded = YES;
    _panel.movableByWindowBackground = YES;
    _panel.delegate = self;
    _panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
        NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorStationary;

    _rootView = [[ASDraggableEffectView alloc] initWithFrame:_panel.contentView.bounds];
    _rootView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _rootView.material = NSVisualEffectMaterialHUDWindow;
    _rootView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    _rootView.state = NSVisualEffectStateActive;
    _rootView.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];
    _rootView.wantsLayer = YES;
    _rootView.layer.cornerRadius = 8;
    _rootView.layer.cornerCurve = kCACornerCurveContinuous;
    _rootView.layer.masksToBounds = YES;
    _rootView.layer.backgroundColor = NSColor.clearColor.CGColor;
    _rootView.layer.borderWidth = 0;
    _rootView.accessibilityLabel = @"Codex、Claude Code 和 Cursor 状态指示灯";
    _panel.contentView = _rootView;

    ASFlippedView *tintView = [[ASFlippedView alloc] initWithFrame:_rootView.bounds];
    tintView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    tintView.wantsLayer = YES;
    tintView.layer.backgroundColor = [NSColor colorWithWhite:0.02 alpha:0.22].CGColor;
    [_rootView addSubview:tintView];

    _scrollView = [[NSScrollView alloc] initWithFrame:NSInsetRect(_rootView.bounds, 6, 6)];
    _scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _scrollView.borderType = NSNoBorder;
    _scrollView.drawsBackground = NO;
    _scrollView.hasHorizontalScroller = NO;
    _scrollView.hasVerticalScroller = YES;
    _scrollView.autohidesScrollers = YES;
    _scrollView.scrollerStyle = NSScrollerStyleOverlay;
    _documentView = [[ASFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 282, 124)];
    _scrollView.documentView = _documentView;
    [_rootView addSubview:_scrollView];

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    _userPositioned = [defaults boolForKey:ASPanelHasSavedPositionKey];
    _lampMode = [defaults integerForKey:ASLampModeDefaultsKey] == ASLampModeTriple ?
        ASLampModeTriple : ASLampModeSingle;

    [self updateSignals:signals];
    [_panel orderFrontRegardless];
    return self;
}

- (BOOL)isVisible { return self.panel.visible; }

- (void)updateSignals:(NSArray<NSDictionary *> *)signals {
    self.signals = signals ?: @[];
    for (NSView *view in [self.documentView.subviews copy]) [view removeFromSuperview];

    NSScreen *screen = [self currentScreen];
    CGFloat width = 294;
    CGFloat itemHeight = self.lampMode == ASLampModeSingle ? 88 : 124;
    CGFloat documentHeight = MAX(itemHeight, signals.count * itemHeight);
    CGFloat height = MIN(screen.visibleFrame.size.height - 24, documentHeight + 12);
    NSRect oldFrame = self.panel.frame;

    self.suppressMoveHandling = YES;
    [self.panel setContentSize:NSMakeSize(width, height)];
    self.rootView.frame = NSMakeRect(0, 0, width, height);
    self.scrollView.frame = NSInsetRect(self.rootView.bounds, 6, 6);
    CGFloat documentWidth = self.scrollView.contentSize.width;
    self.documentView.frame = NSMakeRect(0, 0, documentWidth, documentHeight);
    self.scrollView.hasVerticalScroller = documentHeight > self.scrollView.contentSize.height;

    if (!signals.count) {
        NSRect lightFrame = self.lampMode == ASLampModeSingle ?
            NSMakeRect(12, 14, 58, 58) : NSMakeRect(12, 6, 50, 112);
        ASTrafficLightView *lights = [[ASTrafficLightView alloc] initWithFrame:lightFrame];
        lights.state = ASStateOffline;
        lights.lampMode = self.lampMode;
        [self.documentView addSubview:lights];
        NSTextField *label = ASLabel(@"无活动会话", 12, NSFontWeightSemibold);
        label.textColor = NSColor.secondaryLabelColor;
        label.frame = self.lampMode == ASLampModeSingle ?
            NSMakeRect(84, 34, 170, 20) : NSMakeRect(82, 50, 170, 20);
        [self.documentView addSubview:label];
    } else {
        [signals enumerateObjectsUsingBlock:^(NSDictionary *signal, NSUInteger index, BOOL *stop) {
            ASSessionSignalView *view = [[ASSessionSignalView alloc]
                initWithSignal:signal
                lampMode:self.lampMode
                showsSeparator:index + 1 < signals.count];
            view.frame = NSMakeRect(0, index * itemHeight, documentWidth, itemHeight);
            [self.documentView addSubview:view];
        }];
    }

    NSRect targetFrame;
    if (!self.didInitialLayout && self.userPositioned) {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        targetFrame = NSMakeRect(
            [defaults doubleForKey:ASPanelOriginXKey],
            [defaults doubleForKey:ASPanelOriginYKey],
            width,
            height
        );
    } else if (self.didInitialLayout && self.userPositioned) {
        targetFrame = NSMakeRect(oldFrame.origin.x, NSMaxY(oldFrame) - height, width, height);
    } else {
        NSRect visibleFrame = screen.visibleFrame;
        targetFrame = NSMakeRect(
            NSMidX(visibleFrame) - width / 2,
            NSMaxY(visibleFrame) - height - 7,
            width,
            height
        );
    }
    targetFrame = [self constrainedFrame:targetFrame forScreen:screen];
    [self.panel setFrame:targetFrame display:YES animate:NO];
    self.suppressMoveHandling = NO;
    self.didInitialLayout = YES;
    if (!self.userHidden) [self.panel orderFrontRegardless];
}

- (NSScreen *)currentScreen {
    NSPoint mouse = NSEvent.mouseLocation;
    for (NSScreen *screen in NSScreen.screens) {
        if (NSPointInRect(mouse, screen.frame)) return screen;
    }
    return self.panel.screen ?: NSScreen.mainScreen ?: NSScreen.screens.firstObject;
}

- (NSRect)constrainedFrame:(NSRect)frame forScreen:(NSScreen *)screen {
    NSRect visible = screen.visibleFrame;
    CGFloat minimumVisible = 72;
    CGFloat minimumX = NSMinX(visible) - frame.size.width + minimumVisible;
    CGFloat maximumX = NSMaxX(visible) - minimumVisible;
    CGFloat minimumY = NSMinY(visible) - frame.size.height + minimumVisible;
    CGFloat maximumY = NSMaxY(visible) - minimumVisible;
    frame.origin.x = MIN(MAX(frame.origin.x, minimumX), maximumX);
    frame.origin.y = MIN(MAX(frame.origin.y, minimumY), maximumY);
    return frame;
}

- (void)windowDidMove:(NSNotification *)notification {
    if (self.suppressMoveHandling) return;
    NSScreen *screen = [self currentScreen];
    NSRect current = self.panel.frame;
    NSRect constrained = [self constrainedFrame:current forScreen:screen];
    if (!NSEqualRects(current, constrained)) {
        self.suppressMoveHandling = YES;
        [self.panel setFrame:constrained display:YES animate:NO];
        self.suppressMoveHandling = NO;
    }
    self.userPositioned = YES;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:YES forKey:ASPanelHasSavedPositionKey];
    [defaults setDouble:constrained.origin.x forKey:ASPanelOriginXKey];
    [defaults setDouble:constrained.origin.y forKey:ASPanelOriginYKey];
}

- (void)toggle {
    if (self.panel.visible) {
        self.userHidden = YES;
        [self.panel orderOut:nil];
    } else {
        self.userHidden = NO;
        [self.panel orderFrontRegardless];
    }
}

- (void)resetPosition {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults removeObjectForKey:ASPanelHasSavedPositionKey];
    [defaults removeObjectForKey:ASPanelOriginXKey];
    [defaults removeObjectForKey:ASPanelOriginYKey];
    self.userPositioned = NO;

    NSScreen *screen = [self currentScreen];
    NSRect visible = screen.visibleFrame;
    NSRect frame = self.panel.frame;
    frame.origin.x = NSMidX(visible) - frame.size.width / 2;
    frame.origin.y = NSMaxY(visible) - frame.size.height - 7;
    self.suppressMoveHandling = YES;
    [self.panel setFrame:[self constrainedFrame:frame forScreen:screen] display:YES animate:YES];
    self.suppressMoveHandling = NO;
    self.userHidden = NO;
    [self.panel orderFrontRegardless];
}

- (void)changeLampMode:(ASLampMode)lampMode {
    if (lampMode != ASLampModeSingle && lampMode != ASLampModeTriple) return;
    if (self.lampMode == lampMode) return;
    self.lampMode = lampMode;
    [NSUserDefaults.standardUserDefaults setInteger:lampMode forKey:ASLampModeDefaultsKey];
    [self updateSignals:self.signals];
}

@end


@interface ASAppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property(nonatomic, strong) ASSessionMonitor *monitor;
@property(nonatomic, strong) ASTopPanelController *panelController;
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSMenu *menu;
@property(nonatomic, strong) NSTimer *statusAnimationTimer;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *notifiedStates;
@end

@implementation ASAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.notifiedStates = [NSMutableDictionary dictionary];
    UNUserNotificationCenter *center = UNUserNotificationCenter.currentNotificationCenter;
    [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
        completionHandler:^(BOOL granted, NSError * _Nullable error) {}];

    self.monitor = [[ASSessionMonitor alloc] init];
    self.panelController = [[ASTopPanelController alloc] initWithSignals:self.monitor.signals];

    __weak typeof(self) weakSelf = self;
    self.monitor.updateHandler = ^(NSArray<NSDictionary *> *signals) {
        [weakSelf.panelController updateSignals:signals];
        [weakSelf updateStatusIcon];
        [weakSelf notifyAttentionForSignals:signals];
    };

    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:27];
    self.statusItem.button.imagePosition = NSImageOnly;
    self.statusItem.button.toolTip = @"Codex / Claude Code / Cursor 状态";
    self.menu = [[NSMenu alloc] init];
    self.menu.delegate = self;
    self.statusItem.menu = self.menu;
    [self rebuildMenu];
    [self updateStatusIcon];
    [self notifyAttentionForSignals:self.monitor.signals];

    self.statusAnimationTimer = [NSTimer timerWithTimeInterval:0.2
        target:self selector:@selector(updateStatusIcon) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:self.statusAnimationTimer forMode:NSRunLoopCommonModes];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return NO; }

- (void)menuWillOpen:(NSMenu *)menu { [self rebuildMenu]; }

- (void)rebuildMenu {
    [self.menu removeAllItems];
    NSString *writeError = ASLoadHookWriteError(ASSignalRootURL());
    if (writeError.length) {
        NSMenuItem *errorItem = [[NSMenuItem alloc] initWithTitle:writeError action:nil keyEquivalent:@""];
        errorItem.enabled = NO;
        [self.menu addItem:errorItem];
        [self.menu addItem:NSMenuItem.separatorItem];
    }
    if (!self.monitor.signals.count) {
        NSMenuItem *empty = [[NSMenuItem alloc] initWithTitle:@"无活动会话" action:nil keyEquivalent:@""];
        empty.enabled = NO;
        [self.menu addItem:empty];
    } else {
        for (NSDictionary *signal in self.monitor.signals) {
            NSString *cwd = signal[@"cwd"];
            NSString *project = cwd.length ? cwd.lastPathComponent : @"未知项目";
            NSString *taskTitle = signal[@"task_title"];
            NSString *title = [NSString stringWithFormat:@"%@ · %@",
                taskTitle.length ? taskTitle : project, ASStateTitle(ASDisplayState(signal, NSDate.date))];
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                action:@selector(openSession:) keyEquivalent:@""];
            item.target = self;
            item.representedObject = signal;
            item.image = ASAgentLogo(signal[@"agent"]);
            BOOL isDirectory = NO;
            BOOL cwdValid = cwd.length > 0 &&
                [NSFileManager.defaultManager fileExistsAtPath:cwd isDirectory:&isDirectory] &&
                isDirectory;
            item.enabled = cwdValid;
            if (!cwdValid) item.action = nil;
            [self.menu addItem:item];
        }
    }

    [self.menu addItem:NSMenuItem.separatorItem];
    [self.menu addItem:[self menuItem:@"安装/修复状态连接" symbol:@"link.badge.plus" action:@selector(installHooks:) key:@""]];
    [self.menu addItem:[self menuItem:@"卸载状态连接" symbol:@"link.badge.minus" action:@selector(uninstallHooks:) key:@""]];
    NSMenuItem *panelItem = [self menuItem:@"显示顶部指示灯" symbol:@"rectangle.topthird.inset.filled"
        action:@selector(togglePanel:) key:@""];
    panelItem.state = self.panelController.visible ? NSControlStateValueOn : NSControlStateValueOff;
    [self.menu addItem:panelItem];

    NSMenuItem *lampStyleItem = [[NSMenuItem alloc] initWithTitle:@"指示灯样式" action:nil keyEquivalent:@""];
    lampStyleItem.image = [NSImage imageWithSystemSymbolName:@"light.beacon.max"
        accessibilityDescription:@"指示灯样式"];
    NSMenu *lampStyleMenu = [[NSMenu alloc] initWithTitle:@"指示灯样式"];
    NSMenuItem *singleLampItem = [self menuItem:@"单灯" symbol:@"circle.fill"
        action:@selector(changeLampMode:) key:@""];
    singleLampItem.tag = ASLampModeSingle;
    singleLampItem.state = self.panelController.lampMode == ASLampModeSingle ?
        NSControlStateValueOn : NSControlStateValueOff;
    [lampStyleMenu addItem:singleLampItem];
    NSMenuItem *tripleLampItem = [self menuItem:@"三灯" symbol:@"ellipsis"
        action:@selector(changeLampMode:) key:@""];
    tripleLampItem.tag = ASLampModeTriple;
    tripleLampItem.state = self.panelController.lampMode == ASLampModeTriple ?
        NSControlStateValueOn : NSControlStateValueOff;
    [lampStyleMenu addItem:tripleLampItem];
    lampStyleItem.submenu = lampStyleMenu;
    [self.menu addItem:lampStyleItem];

    NSInteger currentMaxVisible = ASNormalizeMaxVisibleSessions(
        [NSUserDefaults.standardUserDefaults integerForKey:ASMaxVisibleSessionsDefaultsKey]);
    NSMenuItem *visibleCountItem = [[NSMenuItem alloc] initWithTitle:@"显示条数" action:nil keyEquivalent:@""];
    visibleCountItem.image = [NSImage imageWithSystemSymbolName:@"list.number"
        accessibilityDescription:@"显示条数"];
    NSMenu *visibleCountMenu = [[NSMenu alloc] initWithTitle:@"显示条数"];
    NSArray<NSNumber *> *visiblePresets = @[@5, @10, @20];
    for (NSNumber *preset in visiblePresets) {
        NSInteger limit = preset.integerValue;
        NSMenuItem *item = [self menuItem:[NSString stringWithFormat:@"%ld 条", (long)limit]
            symbol:@"number" action:@selector(changeMaxVisibleSessions:) key:@""];
        item.tag = limit;
        item.state = currentMaxVisible == limit ? NSControlStateValueOn : NSControlStateValueOff;
        [visibleCountMenu addItem:item];
    }
    visibleCountItem.submenu = visibleCountMenu;
    [self.menu addItem:visibleCountItem];

    [self.menu addItem:[self menuItem:@"重置窗口位置" symbol:@"arrow.up.and.down.and.arrow.left.and.right"
        action:@selector(resetPanelPosition:) key:@""]];
    [self.menu addItem:[self menuItem:@"清除历史灯组" symbol:@"trash" action:@selector(clearSignals:) key:@""]];
    [self.menu addItem:NSMenuItem.separatorItem];
    [self.menu addItem:[self menuItem:@"退出" symbol:@"power" action:@selector(quit:) key:@"q"]];
}

- (NSMenuItem *)menuItem:(NSString *)title symbol:(NSString *)symbol action:(SEL)action key:(NSString *)key {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key];
    item.target = self;
    item.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:title];
    return item;
}

- (void)openSession:(NSMenuItem *)sender {
    NSDictionary *signal = [sender.representedObject isKindOfClass:[NSDictionary class]] ?
        sender.representedObject : nil;
    NSString *cwd = signal[@"cwd"];
    BOOL isDirectory = NO;
    if (!cwd.length ||
        ![NSFileManager.defaultManager fileExistsAtPath:cwd isDirectory:&isDirectory] ||
        !isDirectory) {
        return;
    }
    [[NSWorkspace sharedWorkspace] openFile:cwd];
}

- (void)notifyAttentionForSignals:(NSArray<NSDictionary *> *)signals {
    NSDate *now = NSDate.date;
    for (NSDictionary *signal in signals) {
        NSString *sessionID = signal[@"session_id"] ?: @"";
        if (!sessionID.length) continue;
        NSString *state = ASDisplayState(signal, now);
        NSString *previous = self.notifiedStates[sessionID];
        self.notifiedStates[sessionID] = state;
        if (!previous.length || [previous isEqualToString:state] || !ASNeedsUserAttention(state)) {
            continue;
        }
        NSString *cwd = signal[@"cwd"];
        NSString *project = cwd.length ? cwd.lastPathComponent : @"未知项目";
        NSString *task = signal[@"task_title"];
        NSString *body = project;
        if (task.length && ![task isEqualToString:project]) {
            body = [NSString stringWithFormat:@"%@\n%@", project, task];
        }
        UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
        content.title = ASStateTitle(state);
        content.body = body;
        NSString *identifier = [NSString stringWithFormat:@"%@-%@-%@",
            signal[@"agent"] ?: @"", sessionID, state];
        UNNotificationRequest *request = [UNNotificationRequest
            requestWithIdentifier:identifier content:content trigger:nil];
        [UNUserNotificationCenter.currentNotificationCenter
            addNotificationRequest:request withCompletionHandler:nil];
    }
}

- (NSString *)hookExecutablePath {
    NSString *bundled = [NSBundle.mainBundle.bundleURL
        URLByAppendingPathComponent:@"Contents/Helpers/AgentSignalHook"].path;
    if ([NSFileManager.defaultManager isExecutableFileAtPath:bundled]) return bundled;
    NSURL *executable = [NSURL fileURLWithPath:NSProcessInfo.processInfo.arguments.firstObject];
    return [[executable URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"AgentSignalHook"].path;
}

- (void)installHooks:(id)sender {
    NSString *hookPath = self.hookExecutablePath;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        BOOL success = ASInstallHooks(hookPath, NSFileManager.defaultManager.homeDirectoryForCurrentUser, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showAlert:success ? @"状态连接已安装" : @"无法安装状态连接"
                message:success ? @"请新开 Codex、Claude Code 和 Cursor 会话。Codex 首次加载时还需要在 /hooks 中确认信任。" : error.localizedDescription];
        });
    });
}

- (void)uninstallHooks:(id)sender {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        BOOL success = ASUninstallHooks(NSFileManager.defaultManager.homeDirectoryForCurrentUser, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showAlert:success ? @"状态连接已卸载" : @"无法卸载状态连接"
                message:success ? @"现有会话不受影响，新会话将不再上报状态。" : error.localizedDescription];
        });
    });
}

- (void)togglePanel:(id)sender { [self.panelController toggle]; }
- (void)changeLampMode:(NSMenuItem *)sender {
    [self.panelController changeLampMode:(ASLampMode)sender.tag];
    [self rebuildMenu];
}
- (void)changeMaxVisibleSessions:(NSMenuItem *)sender {
    NSInteger limit = ASNormalizeMaxVisibleSessions(sender.tag);
    [NSUserDefaults.standardUserDefaults setInteger:limit forKey:ASMaxVisibleSessionsDefaultsKey];
    [self.monitor forceReload];
    [self rebuildMenu];
}
- (void)resetPanelPosition:(id)sender { [self.panelController resetPosition]; }
- (void)clearSignals:(id)sender { [self.monitor clear]; }
- (void)quit:(id)sender { [NSApp terminate:nil]; }

- (void)showAlert:(NSString *)title message:(NSString *)message {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = title;
    alert.informativeText = message ?: @"";
    [alert addButtonWithTitle:@"好"];
    [alert runModal];
}

- (void)updateStatusIcon {
    NSString *state = self.monitor.aggregateState;
    NSDictionary *presentation = ASLampPresentation(state);
    CGFloat intensity = ASEffectIntensity(presentation[@"effect"], NSDate.date);
    BOOL singleLamp = self.panelController.lampMode == ASLampModeSingle;
    NSImage *image = [[NSImage alloc] initWithSize:singleLamp ? NSMakeSize(14, 14) : NSMakeSize(24, 14)];
    [image lockFocus];
    if (singleLamp) {
        NSString *name = [presentation[@"color"] isEqualToString:@"off"] ? @"gray" : presentation[@"color"];
        CGFloat alpha = [presentation[@"color"] isEqualToString:@"off"] ? 0.25 : 0.42 + intensity * 0.58;
        [[ASColorForName(name) colorWithAlphaComponent:alpha] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(2, 2, 10, 10)] fill];
    } else {
        NSArray<NSString *> *colors = @[@"red", @"yellow", @"green"];
        for (NSUInteger index = 0; index < colors.count; index++) {
            NSString *name = colors[index];
            BOOL active = [name isEqualToString:presentation[@"color"]];
            CGFloat alpha = active ? 0.42 + intensity * 0.58 : 0.2;
            [[ASColorForName(name) colorWithAlphaComponent:alpha] setFill];
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(index * 8 + 1, 4, 6, 6)] fill];
        }
    }
    [image unlockFocus];
    image.template = NO;
    self.statusItem.button.image = image;
    self.statusItem.button.accessibilityLabel = [NSString stringWithFormat:@"Agent 状态：%@", ASStateTitle(state)];
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *application = NSApplication.sharedApplication;
        ASAppDelegate *delegate = [[ASAppDelegate alloc] init];
        application.delegate = delegate;
        [application setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [application run];
    }
    return EXIT_SUCCESS;
}
