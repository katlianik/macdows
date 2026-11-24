#import <IOKit/hidsystem/IOHIDEventSystemClient.h>
#import <IOKit/hidsystem/IOHIDServiceClient.h>
#import <Cocoa/Cocoa.h>
#include <stdatomic.h>
#import <ServiceManagement/ServiceManagement.h>
#import <Carbon/Carbon.h>
#import <IOKit/hidsystem/IOLLEvent.h>
#import <ApplicationServices/ApplicationServices.h>
#import <dlfcn.h>

static CFMachPortRef tap;
static AXUIElementRef pressed;
static NSRunningApplication *target;
static BOOL redEnabled, greenEnabled;
static id clickedWindow, dragWindow;
static BOOL fillPress, singleButtonPress, optionEnabled, lastEnabled, dragEnabled;
static CGPoint dragStart, initialOrigin;
static NSString *const optionClickKey = @"OptionUsesSingleWindowAction";
static NSString *const lastKey = @"QuitOnlyLastWindow";
static NSString *const dragKey = @"DragWindowAnywhere";
static NSString *const backgroundKey = @"KeepBackgroundAppsRunning";
static BOOL backgroundEnabled;

static void resetClick(void) {
    if (pressed) CFRelease(pressed);
    pressed = NULL;
    target = nil;
    clickedWindow = nil;
    dragWindow = nil;
    fillPress = NO;
    singleButtonPress = NO;
}

static AXUIElementRef copyHit(CGPoint point) {
    AXUIElementRef system = AXUIElementCreateSystemWide(), hit = NULL;
    AXUIElementSetMessagingTimeout(system, 0.08);
    AXUIElementCopyElementAtPosition(system, point.x, point.y, &hit);
    CFRelease(system);
    return hit;
}

static id attribute(AXUIElementRef element, CFStringRef key) {
    CFTypeRef value = NULL;
    AXUIElementSetMessagingTimeout(element, 0.04);
    AXUIElementCopyAttributeValue(element, key, &value);
    return CFBridgingRelease(value);
}


static NSString *const redKey = @"RedQuitsApp";
static NSString *const greenKey = @"GreenFillsWindow";

typedef NS_ENUM(NSInteger, GlobeMode) { GlobeOff, GlobeOption, GlobeCommand, GlobeControl };
static NSString *const globeModeKey = @"GlobeModifierMode";
static GlobeMode globeMode, heldMode;
typedef struct { uint64_t usage; CGKeyCode key; CGEventFlags flags; } GlobeMapping;
static const GlobeMapping globeMappings[] = {
    {0, kVK_Function, 0},
    {0x7000000e2ULL, kVK_Option, kCGEventFlagMaskAlternate | NX_DEVICELALTKEYMASK},
    {0x7000000e3ULL, kVK_Command, kCGEventFlagMaskCommand | NX_DEVICELCMDKEYMASK},
    {0x7000000e0ULL, kVK_Control, kCGEventFlagMaskControl | NX_DEVICELCTLKEYMASK}
};

static CFMachPortRef globeTap;
static BOOL globeHeld;
static atomic_bool inputPaused;
static _Atomic(double) lastMainHeartbeat;
static _Atomic(double) healthyMainSince;
static double inputRetryAfter, lastInputRecovery;
static NSUInteger inputRetryCount;

static BOOL inputRecoveryReady(double now) {
    double healthySince = atomic_load(&healthyMainSince);
    return atomic_load(&inputPaused) && healthySince > 0 &&
        now-healthySince >= 2.0 && now >= inputRetryAfter;
}

static dispatch_source_t inputWatchdog;

static void pauseInput(void) {
    if (!atomic_exchange(&inputPaused, true))
        atomic_store(&healthyMainSince, 0);
    @synchronized (NSApplication.class) {
        if (tap) CGEventTapEnable(tap, false);
        if (globeTap) CGEventTapEnable(globeTap, false);
    }
}

static void resumeInput(void) {
    atomic_store(&lastMainHeartbeat, NSProcessInfo.processInfo.systemUptime);
    atomic_store(&inputPaused, false);
    @synchronized (NSApplication.class) {
        if (tap) CGEventTapEnable(tap, true);
        if (globeTap) CGEventTapEnable(globeTap, true);
    }
}

static void startInputWatchdog(void) {
    atomic_store(&lastMainHeartbeat, NSProcessInfo.processInfo.systemUptime);
    NSTimer *heartbeat = [NSTimer timerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *timer) {
        double now = NSProcessInfo.processInfo.systemUptime;
        double previous = atomic_exchange(&lastMainHeartbeat, now);
        if (now-previous > 0.25 || atomic_load(&healthyMainSince) == 0)
            atomic_store(&healthyMainSince, now);
    }];
    [NSRunLoop.mainRunLoop addTimer:heartbeat forMode:NSRunLoopCommonModes];
    inputWatchdog = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
        dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0));
    dispatch_source_set_timer(inputWatchdog, DISPATCH_TIME_NOW, 50*NSEC_PER_MSEC, 10*NSEC_PER_MSEC);
    dispatch_source_set_event_handler(inputWatchdog, ^{
        if (!atomic_load(&inputPaused) &&
            NSProcessInfo.processInfo.systemUptime-atomic_load(&lastMainHeartbeat) > 0.25)
            pauseInput();
    });
    dispatch_resume(inputWatchdog);
}


static NSString *const sourceKey = @"HIDKeyboardModifierMappingSrc", *const destinationKey = @"HIDKeyboardModifierMappingDst";
static IOHIDEventSystemClientRef hidClient;


static NSArray *globeRows(NSArray *rows) {
    return [rows filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id row, NSDictionary *bindings) {
        NSNumber *src = row[sourceKey];
        return [src isEqual:@(0xff00000003ULL)] || [src isEqual:@(0xff0100000003ULL)];
    }]];
}

static NSArray *replaceGlobeRows(NSArray *rows, NSArray *replacement) {
    NSMutableArray *result = [rows mutableCopy];
    [result removeObjectsInArray:globeRows(rows)];
    [result addObjectsFromArray:replacement];
    return result;
}

static void syncKeyboards(GlobeMode mode) {
    if (!hidClient) hidClient = IOHIDEventSystemClientCreateSimpleClient(NULL);
    if (!hidClient) return;
    NSArray *services = CFBridgingRelease(IOHIDEventSystemClientCopyServices(hidClient));
    NSUserDefaults *prefs = NSUserDefaults.standardUserDefaults;
    NSMutableDictionary *journal = [[prefs dictionaryForKey:@"OwnedGlobeMappings"] mutableCopy] ?: [NSMutableDictionary new];
    NSDictionary *old = [journal copy];
    NSArray *desired = mode == GlobeOff ? @[] : @[
        @{sourceKey:@(0xff00000003ULL), destinationKey:@(globeMappings[mode].usage)},
        @{sourceKey:@(0xff0100000003ULL), destinationKey:@(globeMappings[mode].usage)}];
    for (id obj in services) {
        IOHIDServiceClientRef service = (__bridge IOHIDServiceClientRef)obj;
        if (!IOHIDServiceClientConformsTo(service, 1, 6)) continue;
        NSString *key = [(__bridge NSNumber *)IOHIDServiceClientGetRegistryID(service) stringValue];
        if (!key) continue;
        NSArray *rows = CFBridgingRelease(IOHIDServiceClientCopyProperty(service, CFSTR("UserKeyMapping"))) ?: @[];
        if (![rows isKindOfClass:NSArray.class]) continue;
        NSArray *current = globeRows(rows);
        NSDictionary *entry = journal[key];
        NSArray *baseline = entry[@"original"] ?: current;
        if (entry && ![current isEqual:entry[@"installed"]]) {
            baseline = current;
            [journal removeObjectForKey:key];
        }
        NSArray *wanted = mode == GlobeOff ? baseline : desired;
        if (![current isEqual:wanted]) {
            NSArray *merged = replaceGlobeRows(rows, wanted);
            if (!IOHIDServiceClientSetProperty(service, CFSTR("UserKeyMapping"), (__bridge CFArrayRef)merged)) continue;
            NSArray *actual = CFBridgingRelease(IOHIDServiceClientCopyProperty(service, CFSTR("UserKeyMapping"))) ?: @[];
            if (![globeRows(actual) isEqual:wanted]) continue;
            if (mode != GlobeOff) journal[key] = @{@"original":baseline, @"installed":desired};
        }
        if (mode == GlobeOff) [journal removeObjectForKey:key];
    }
    if (![old isEqual:journal]) [prefs setObject:journal forKey:@"OwnedGlobeMappings"];

}

static BOOL spaceConsumed;
static NSString *lastSourceID;

static NSString *sourceID(TISInputSourceRef source) {
    return source ? (__bridge NSString *)TISGetInputSourceProperty(source,kTISPropertyInputSourceID) : nil;
}

static void switchInputSource(void) {
    NSDictionary *filter = @{(__bridge NSString *)kTISPropertyInputSourceCategory:(__bridge NSString *)kTISCategoryKeyboardInputSource,
        (__bridge NSString *)kTISPropertyInputSourceIsSelectCapable:@YES};
    NSArray *sources = CFBridgingRelease(TISCreateInputSourceList((__bridge CFDictionaryRef)filter,false));
    TISInputSourceRef current = TISCopyCurrentKeyboardInputSource();
    NSString *currentID = [sourceID(current) copy];
    if (current) CFRelease(current);
    TISInputSourceRef next = NULL;
    for (id item in sources) {
        TISInputSourceRef candidate = (__bridge TISInputSourceRef)item;
        NSString *identifier = sourceID(candidate);
        if (!identifier || [identifier isEqual:currentID]) continue;
        if (!next || [identifier isEqual:lastSourceID]) next = candidate;
        if ([identifier isEqual:lastSourceID]) break;
    }
    if (next && TISSelectInputSource(next) == noErr) { lastSourceID = currentID; return; }
    NSAlert *alert = [NSAlert new];
    alert.messageText = next ? @"Couldn’t switch input source" : @"Add a second keyboard input source";
    alert.informativeText = next ? @"macOS did not accept the keyboard change." : @"Open System Settings → Keyboard → Text Input → Edit and add the keyboard layout you want to switch to.";
    [alert addButtonWithTitle:@"OK"];
    [alert addButtonWithTitle:@"Keyboard Settings…"];
    [NSApp activateIgnoringOtherApps:YES];
    if ([alert runModal] == NSAlertSecondButtonReturn)
        [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.Keyboard-Settings.extension"]];
}

static NSString *const languageKey = @"OptionSpaceSwitchesLanguage";
static BOOL languageEnabled;
static NSString *const globeShiftKey = @"GlobeShiftSwitchesLanguage";
static BOOL globeShiftEnabled, shiftPending, shiftBlocked;

static CGEventFlags shiftOriginalModifiers;
static const CGEventFlags languageModifiers = kCGEventFlagMaskAlternate |
    kCGEventFlagMaskCommand | kCGEventFlagMaskControl;

static BOOL globeShiftChord(CGEventFlags flags) {
    if (!globeShiftEnabled || !(flags & kCGEventFlagMaskShift)) return NO;
    CGEventFlags modifiers = flags & languageModifiers;
    if ((flags & kCGEventFlagMaskSecondaryFn) && !modifiers) return YES;
    return globeMode != GlobeOff &&
        modifiers == (globeMappings[globeMode].flags & languageModifiers);
}

// Switch on release, and cancel if another key or modifier joins the chord.
static BOOL updateGlobeShift(CGEventType type, CGEventFlags flags) {
    if (!globeShiftEnabled) { shiftPending = NO; shiftBlocked = NO; return NO; }
    if (type == kCGEventKeyDown || type == kCGEventKeyUp) {
        if (shiftPending) { shiftPending = NO; shiftBlocked = YES; }
        return NO;
    }
    if (type != kCGEventFlagsChanged) return NO;
    BOOL chord = globeShiftChord(flags);
    CGEventFlags tracked = languageModifiers | kCGEventFlagMaskSecondaryFn;
    BOOL switchNow = shiftPending && !chord &&
        !((flags & tracked) & ~shiftOriginalModifiers);
    if (!chord) { shiftPending = NO; shiftBlocked = NO; }
    else if (!shiftBlocked) {
        shiftPending = YES;
        shiftOriginalModifiers = flags & tracked;
    }
    return switchNow;
}

static BOOL languageChord(CGEventFlags flags) {
    if (!languageEnabled || (flags & kCGEventFlagMaskShift)) return NO;
    CGEventFlags modifiers = flags & languageModifiers;
    if (!modifiers && (flags & kCGEventFlagMaskSecondaryFn)) return YES;
    if (modifiers == kCGEventFlagMaskAlternate) return YES;
    return globeMode == GlobeControl && modifiers == kCGEventFlagMaskControl;
}

static NSString *const finderKey = @"OpenEmptyFinderOnOptionTab";
static NSString *const otherAppsKey = @"OpenOtherEmptyAppsOnOptionTab";
static NSString *const restoreKey = @"RestoreMinimizedOnActivation";
static BOOL finderEnabled, otherAppsEnabled, restoreEnabled;
static NSString *const localSwitcherKey = @"UseMacdowsAppSwitcher";
static NSString *const localSwitcherCurrentOnlyKey = @"AppSwitcherCurrentDesktopOnly";
static NSString *const localSwitcherHideFinderKey = @"AppSwitcherHideEmptyFinder";
static NSString *const localSwitcherPreviewsKey = @"AppSwitcherShowWindowPreviews";
static NSString *const legacyLocalSwitcherPreviewsKey = @"AppSwitcherShowPreviews";
static NSString *const localSwitcherEveryWindowKey = @"AppSwitcherShowEveryWindow";
static BOOL localSwitcherEnabled, localSwitcherCurrentOnly, localSwitcherHideFinder, localSwitcherPreviews, localSwitcherEveryWindow;
typedef NS_ENUM(NSInteger, LocalSwitcherDisplayMode) {
    LocalSwitcherDisplayIcons,
    LocalSwitcherDisplayAppPreviews,
    LocalSwitcherDisplayEveryWindow
};
static LocalSwitcherDisplayMode localSwitcherDisplayMode(BOOL previews, BOOL everyWindow) {
    return everyWindow ? LocalSwitcherDisplayEveryWindow : previews ? LocalSwitcherDisplayAppPreviews : LocalSwitcherDisplayIcons;
}
static void migrateLocalSwitcherPreviewPreference(NSUserDefaults *prefs) {
    if (![prefs objectForKey:localSwitcherPreviewsKey] && [prefs objectForKey:legacyLocalSwitcherPreviewsKey])
        [prefs setBool:[prefs boolForKey:legacyLocalSwitcherPreviewsKey] forKey:localSwitcherPreviewsKey];
}
static NSMutableArray<NSNumber *> *localSwitcherMRU;
static BOOL windowSwitchEnabled(void) { return finderEnabled || otherAppsEnabled; }
static BOOL scopeIncludesApp(NSString *bundleID) {
    return [bundleID isEqual:@"com.apple.finder"] ? finderEnabled : otherAppsEnabled;
}
static NSUInteger switchGeneration;

typedef uint32_t (*SwitcherMainConnectionFn)(void);
typedef CFArrayRef (*SwitcherCopySpacesForWindowsFn)(uint32_t,int,CFArrayRef);
typedef CFArrayRef (*SwitcherCopyManagedDisplaySpacesFn)(uint32_t);
static SwitcherMainConnectionFn switcherMainConnection;
static SwitcherCopySpacesForWindowsFn switcherCopySpacesForWindows;
static SwitcherCopyManagedDisplaySpacesFn switcherCopyManagedDisplaySpaces;
static BOOL switcherSkyLightLoaded;
static NSArray<NSRunningApplication *> *localSwitcherApps;
static NSMutableSet<NSNumber *> *localSwitcherSuppressedPIDs;
static NSMutableSet<NSNumber *> *localSwitcherSuppressedWindowIDs;
static NSArray<NSNumber *> *localSwitcherItemWindowIDs;
static NSArray<NSString *> *localSwitcherItemTitles;
static NSMutableDictionary<NSNumber *,NSImageView *> *localSwitcherPreviewViews;
static NSMutableDictionary<NSNumber *,NSImage *> *localSwitcherPreviewImageCache;
static NSMutableSet<NSNumber *> *localSwitcherPreviewLoadsInFlight;
static NSInteger localSwitcherSelection, localSwitcherVisibleStart;
static NSUInteger localSwitcherPanelGeneration;
static NSUInteger localSwitcherPreviewGeneration;
static BOOL localSwitcherActive, localSwitcherTabHeld, localSwitcherQHeld, localSwitcherWHeld;
static NSPanel *localSwitcherPanel;
static NSStackView *localSwitcherStack;
static NSView *localSwitcherContentView;
static NSTextField *localSwitcherLeftOverflow, *localSwitcherRightOverflow;
static NSInteger localSwitcherRenderedStart = NSNotFound, localSwitcherRenderedCount;
static BOOL localSwitcherRenderedPreviews;
static CGWindowID localSwitcherWindowID(AXUIElementRef window);
static void focusLocalSwitcherWindow(NSRunningApplication *app, CGWindowID targetWindowID);

static void loadSwitcherSkyLight(void) {
    if (switcherSkyLightLoaded) return;
    switcherSkyLightLoaded = YES;
    void *handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_LAZY | RTLD_LOCAL);
    if (!handle) return;
    switcherMainConnection = (SwitcherMainConnectionFn)dlsym(handle,"SLSMainConnectionID");
    if (!switcherMainConnection) switcherMainConnection = (SwitcherMainConnectionFn)dlsym(handle,"CGSMainConnectionID");
    switcherCopySpacesForWindows = (SwitcherCopySpacesForWindowsFn)dlsym(handle,"SLSCopySpacesForWindows");
    if (!switcherCopySpacesForWindows) switcherCopySpacesForWindows = (SwitcherCopySpacesForWindowsFn)dlsym(handle,"CGSCopySpacesForWindows");
    switcherCopyManagedDisplaySpaces = (SwitcherCopyManagedDisplaySpacesFn)dlsym(handle,"SLSCopyManagedDisplaySpaces");
    if (!switcherCopyManagedDisplaySpaces) switcherCopyManagedDisplaySpaces = (SwitcherCopyManagedDisplaySpacesFn)dlsym(handle,"CGSCopyManagedDisplaySpaces");
}

static NSSet<NSNumber *> *currentSwitcherSpaces(void) {
    loadSwitcherSkyLight();
    if (!switcherMainConnection || !switcherCopyManagedDisplaySpaces) return nil;
    NSArray *displays = CFBridgingRelease(switcherCopyManagedDisplaySpaces(switcherMainConnection()));
    NSMutableSet *result = [NSMutableSet set];
    for (NSDictionary *display in displays) {
        NSNumber *space = [display[@"Current Space"] isKindOfClass:NSDictionary.class] ? display[@"Current Space"][@"ManagedSpaceID"] : nil;
        if (space) [result addObject:space];
    }
    return result.count ? result : nil;
}

static BOOL switcherWindowQualifies(NSDictionary *window) {
    CGRect bounds = CGRectZero;
    CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)window[(id)kCGWindowBounds],&bounds);
    return [window[(id)kCGWindowLayer] integerValue] == 0 &&
        [window[(id)kCGWindowAlpha] doubleValue] > 0 && bounds.size.width >= 100 && bounds.size.height >= 100;
}

static BOOL switcherWindowsOnCurrentSpace(NSArray<NSNumber *> *windowIDs, NSSet<NSNumber *> *currentSpaces, BOOL anyOnscreen) {
    if (!windowIDs.count) return NO;
    loadSwitcherSkyLight();
    if (!currentSpaces.count || !switcherMainConnection || !switcherCopySpacesForWindows) return anyOnscreen;
    // Mask 7 includes both visible and non-visible managed Spaces. Mask 6
    // omits windows on the current Space on current macOS releases.
    NSArray *spaces = CFBridgingRelease(switcherCopySpacesForWindows(switcherMainConnection(),7,(__bridge CFArrayRef)windowIDs));
    for (NSNumber *space in spaces) if ([currentSpaces containsObject:space]) return YES;
    return NO;
}

static BOOL includeInLocalSwitcher(NSString *bundleID, BOOL hasWindow, BOOL hasWindowOnCurrentSpace) {
    if ([bundleID isEqual:NSBundle.mainBundle.bundleIdentifier]) return NO;
    if ([bundleID isEqual:@"com.apple.finder"] && localSwitcherHideFinder && !hasWindow) return NO;
    return localSwitcherCurrentOnly ? hasWindowOnCurrentSpace : YES;
}

static NSArray<NSNumber *> *realSwitcherWindowIDs(NSRunningApplication *app, NSArray<NSNumber *> *candidateIDs,
    NSMutableDictionary<NSNumber *,NSString *> *titlesByWindowID) {
    AXUIElementRef application = AXUIElementCreateApplication(app.processIdentifier);
    AXUIElementSetMessagingTimeout(application,0.18);
    CFTypeRef value = NULL;
    AXError error = AXUIElementCopyAttributeValue(application,kAXWindowsAttribute,&value);
    CFRelease(application);
    if (error != kAXErrorSuccess || !value) return nil;
    NSArray *windows = CFBridgingRelease(value);
    if (![windows isKindOfClass:NSArray.class]) return nil;
    NSSet<NSNumber *> *candidates = [NSSet setWithArray:candidateIDs];
    NSMutableArray<NSNumber *> *result = [NSMutableArray array];
    NSMutableSet<NSNumber *> *seen = [NSMutableSet set];
    for (id item in windows) {
        AXUIElementRef window = (__bridge AXUIElementRef)item;
        if (![attribute(window,kAXRoleAttribute) isEqual:(__bridge NSString *)kAXWindowRole] ||
            ![attribute(window,kAXSubroleAttribute) isEqual:(__bridge NSString *)kAXStandardWindowSubrole]) continue;
        CGWindowID windowID = localSwitcherWindowID(window);
        NSNumber *number = @(windowID);
        if (!windowID || ![candidates containsObject:number] || [seen containsObject:number]) continue;
        [seen addObject:number];
        [result addObject:number];
        NSString *title = attribute(window,kAXTitleAttribute);
        if ([title isKindOfClass:NSString.class] && title.length) {
            @synchronized(titlesByWindowID) {
                if (!titlesByWindowID[number].length) titlesByWindowID[number] = title;
            }
        }
    }
    return result;
}

static NSArray<NSRunningApplication *> *buildLocalSwitcherApps(void) {
    NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll,kCGNullWindowID)) ?: @[];
    NSMutableDictionary<NSNumber *,NSMutableArray<NSNumber *> *> *idsByPID = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *,NSString *> *titlesByWindowID = [NSMutableDictionary dictionary];
    NSMutableSet<NSNumber *> *onscreenPIDs = [NSMutableSet set];
    NSMutableSet<NSNumber *> *onscreenWindowIDs = [NSMutableSet set];
    NSMutableArray<NSNumber *> *windowPIDOrder = [NSMutableArray array];
    for (NSDictionary *window in windows) {
        if (!switcherWindowQualifies(window)) continue;
        NSNumber *pid = window[(id)kCGWindowOwnerPID], *windowID = window[(id)kCGWindowNumber];
        if (!pid || !windowID) continue;
        if ([localSwitcherSuppressedWindowIDs containsObject:windowID]) continue;
        if (!idsByPID[pid]) idsByPID[pid] = [NSMutableArray array];
        [idsByPID[pid] addObject:windowID];
        NSString *title = [window[(id)kCGWindowName] isKindOfClass:NSString.class] ? window[(id)kCGWindowName] : nil;
        if (title.length) titlesByWindowID[windowID] = title;
        if (![windowPIDOrder containsObject:pid]) [windowPIDOrder addObject:pid];
        if ([window[(id)kCGWindowIsOnscreen] boolValue]) {
            [onscreenPIDs addObject:pid];
            [onscreenWindowIDs addObject:windowID];
        }
    }
    NSSet *currentSpaces = localSwitcherCurrentOnly ? currentSwitcherSpaces() : nil;
    NSArray<NSRunningApplication *> *runningApps = NSWorkspace.sharedWorkspace.runningApplications;
    NSMutableDictionary<NSNumber *,NSArray<NSNumber *> *> *realIDsByPID = [NSMutableDictionary dictionary];
    if (localSwitcherEveryWindow) {
        dispatch_apply(runningApps.count,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^(size_t index) {
            NSRunningApplication *app = runningApps[index];
            if (app.terminated || app.activationPolicy != NSApplicationActivationPolicyRegular) return;
            NSNumber *pid = @(app.processIdentifier);
            NSArray *candidateIDs = idsByPID[pid];
            // A single candidate cannot be a duplicate. Accessibility is only
            // needed for multi-window apps, where Window Server also exposes
            // helper surfaces belonging to the same document window.
            if (candidateIDs.count < 2) return;
            NSArray *realIDs = realSwitcherWindowIDs(app,candidateIDs,titlesByWindowID);
            if (realIDs) @synchronized(realIDsByPID) { realIDsByPID[pid] = realIDs; }
        });
    }
    NSMutableArray<NSRunningApplication *> *eligible = [NSMutableArray array];
    NSMutableDictionary<NSNumber *,NSArray<NSNumber *> *> *eligibleWindowIDsByPID = [NSMutableDictionary dictionary];
    for (NSRunningApplication *app in runningApps) {
        if (app.terminated || app.activationPolicy != NSApplicationActivationPolicyRegular) continue;
        NSNumber *pid = @(app.processIdentifier);
        if ([localSwitcherSuppressedPIDs containsObject:pid]) continue;
        NSArray *windowIDs = idsByPID[pid] ?: @[];
        NSArray *realWindowIDs = realIDsByPID[pid];
        if (realWindowIDs) windowIDs = realWindowIDs;
        BOOL onCurrent = localSwitcherCurrentOnly ? switcherWindowsOnCurrentSpace(windowIDs,currentSpaces,[onscreenPIDs containsObject:pid]) : NO;
        if (!includeInLocalSwitcher(app.bundleIdentifier,windowIDs.count > 0,onCurrent)) continue;
        [eligible addObject:app];
        NSMutableArray<NSNumber *> *eligibleWindowIDs = [NSMutableArray array];
        for (NSNumber *windowID in windowIDs) {
            BOOL windowOnCurrent = !localSwitcherCurrentOnly ||
                switcherWindowsOnCurrentSpace(@[windowID],currentSpaces,[onscreenWindowIDs containsObject:windowID]);
            if (windowOnCurrent) [eligibleWindowIDs addObject:windowID];
        }
        eligibleWindowIDsByPID[pid] = eligibleWindowIDs;
    }
    [eligible sortUsingComparator:^NSComparisonResult(NSRunningApplication *a, NSRunningApplication *b) {
        return [(a.localizedName ?: a.bundleIdentifier ?: @"") localizedCaseInsensitiveCompare:(b.localizedName ?: b.bundleIdentifier ?: @"")];
    }];
    NSMutableArray *ordered = [NSMutableArray array];
    NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
    if ([eligible containsObject:front]) [ordered addObject:front];
    for (NSNumber *pid in localSwitcherMRU ?: @[]) {
        for (NSRunningApplication *app in eligible)
            if (app.processIdentifier == pid.intValue && ![ordered containsObject:app]) { [ordered addObject:app]; break; }
    }
    // Window Server returns windows front-to-back. This gives the first switch
    // after a Macdows relaunch a useful order before activation history exists.
    for (NSNumber *pid in windowPIDOrder) {
        for (NSRunningApplication *app in eligible)
            if (app.processIdentifier == pid.intValue && ![ordered containsObject:app]) { [ordered addObject:app]; break; }
    }
    for (NSRunningApplication *app in eligible) if (![ordered containsObject:app]) [ordered addObject:app];
    NSMutableArray<NSRunningApplication *> *items = [NSMutableArray array];
    NSMutableArray<NSNumber *> *itemWindowIDs = [NSMutableArray array];
    NSMutableArray<NSString *> *itemTitles = [NSMutableArray array];
    for (NSRunningApplication *app in ordered) {
        NSArray<NSNumber *> *windowIDs = eligibleWindowIDsByPID[@(app.processIdentifier)] ?: @[];
        if (localSwitcherEveryWindow && windowIDs.count) {
            for (NSNumber *windowID in windowIDs) {
                [items addObject:app];
                [itemWindowIDs addObject:windowID];
                NSString *appName = app.localizedName ?: app.bundleIdentifier ?: @"Application";
                NSString *windowTitle = titlesByWindowID[windowID];
                [itemTitles addObject:[NSString stringWithFormat:@"%@ · %@",appName,windowTitle.length ? windowTitle : @"Untitled Window"]];
            }
        } else {
            [items addObject:app];
            [itemWindowIDs addObject:windowIDs.firstObject ?: @0];
            [itemTitles addObject:app.localizedName ?: app.bundleIdentifier ?: @"Application"];
        }
    }
    localSwitcherItemWindowIDs = itemWindowIDs;
    localSwitcherItemTitles = itemTitles;
    return items;
}

static NSInteger nextLocalSwitcherIndex(NSUInteger count, NSInteger current, BOOL reverse, BOOL firstStep) {
    if (!count) return NSNotFound;
    if (firstStep) return reverse ? (NSInteger)count-1 : MIN(1,(NSInteger)count-1);
    return (current + (reverse ? -1 : 1) + (NSInteger)count) % (NSInteger)count;
}

typedef CGImageRef (*SwitcherCreateWindowImageFn)(CGRect,CGWindowListOption,CGWindowID,CGWindowImageOption);

static SwitcherCreateWindowImageFn switcherCreateWindowImage(void) {
    static SwitcherCreateWindowImageFn function; static dispatch_once_t once;
    dispatch_once(&once, ^{ function = (SwitcherCreateWindowImageFn)dlsym(RTLD_DEFAULT,"CGWindowListCreateImage"); });
    return function;
}

static void loadLocalSwitcherPreviewImages(NSArray<NSNumber *> *visibleWindowIDs, BOOL refreshCached) {
    SwitcherCreateWindowImageFn createImage = switcherCreateWindowImage();
    if (!localSwitcherPreviews || !createImage || !CGPreflightScreenCaptureAccess()) return;
    NSMutableSet<NSNumber *> *needed = [NSMutableSet set];
    for (NSNumber *windowID in visibleWindowIDs) {
        if (!windowID.unsignedIntValue || (!refreshCached && localSwitcherPreviewImageCache[windowID]) ||
            [localSwitcherPreviewLoadsInFlight containsObject:windowID]) continue;
        [needed addObject:windowID];
        [localSwitcherPreviewLoadsInFlight addObject:windowID];
    }
    if (!needed.count) return;
    NSMutableDictionary<NSNumber *,id> *images = [NSMutableDictionary dictionary];
    dispatch_group_t group = dispatch_group_create();
    for (NSNumber *windowID in needed) {
        dispatch_group_async(group,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
            CGImageRef image = createImage(CGRectNull,kCGWindowListOptionIncludingWindow,windowID.unsignedIntValue,
                kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution);
            if (image && CGImageGetWidth(image) > 1 && CGImageGetHeight(image) > 1) {
                id object = CFBridgingRelease(image);
                @synchronized(images) { images[windowID] = object; }
            } else if (image) CFRelease(image);
        });
    }
    dispatch_group_notify(group,dispatch_get_main_queue(), ^{
            for (NSNumber *windowID in needed) [localSwitcherPreviewLoadsInFlight removeObject:windowID];
            if (!localSwitcherActive || !localSwitcherPreviews) return;
            [images enumerateKeysAndObjectsUsingBlock:^(NSNumber *windowID, id imageObject, BOOL *stop) {
                localSwitcherPreviewImageCache[windowID] = [[NSImage alloc] initWithCGImage:(__bridge CGImageRef)imageObject size:NSZeroSize];
            }];
            [localSwitcherPreviewViews enumerateKeysAndObjectsUsingBlock:^(NSNumber *windowID, NSImageView *view, BOOL *stop) {
                NSImage *image = localSwitcherPreviewImageCache[windowID];
                if (image) view.image = image;
            }];
    });
}

static void updateLocalSwitcherCellSelection(NSView *cell, BOOL selected) {
    cell.layer.backgroundColor = selected ? [NSColor.controlAccentColor colorWithAlphaComponent:(localSwitcherPreviews ? 0.18 : 0.38)].CGColor : NSColor.clearColor.CGColor;
    cell.layer.borderWidth = selected && localSwitcherPreviews ? 3 : 0;
}

static NSView *localSwitcherCell(NSRunningApplication *app, NSNumber *windowID, NSString *title, BOOL selected) {
    CGFloat width = localSwitcherPreviews ? 220 : 84, height = localSwitcherPreviews ? 150 : 94;
    NSView *cell = [[NSView alloc] initWithFrame:NSMakeRect(0,0,width,height)];
    cell.wantsLayer = YES;
    cell.layer.cornerRadius = 11;
    cell.layer.borderColor = NSColor.controlAccentColor.CGColor;
    updateLocalSwitcherCellSelection(cell,selected);
    NSTextField *label = [NSTextField labelWithString:title ?: app.localizedName ?: @""];
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    label.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    label.textColor = NSColor.labelColor;
    if (localSwitcherPreviews) {
        NSImageView *preview = [[NSImageView alloc] initWithFrame:NSMakeRect(6,31,208,113)];
        NSImage *cached = localSwitcherPreviewImageCache[windowID];
        preview.image = cached ?: app.icon ?: [NSImage imageNamed:NSImageNameApplicationIcon];
        preview.imageScaling = NSImageScaleProportionallyUpOrDown;
        preview.wantsLayer = YES;
        preview.layer.cornerRadius = 7;
        preview.layer.masksToBounds = YES;
        preview.layer.backgroundColor = [NSColor.blackColor colorWithAlphaComponent:0.12].CGColor;
        if (windowID.unsignedIntValue) localSwitcherPreviewViews[windowID] = preview;
        NSImageView *icon = [[NSImageView alloc] initWithFrame:NSMakeRect(7,5,20,20)];
        icon.image = app.icon ?: [NSImage imageNamed:NSImageNameApplicationIcon];
        icon.imageScaling = NSImageScaleProportionallyUpOrDown;
        label.frame = NSMakeRect(33,6,179,18);
        label.alignment = NSTextAlignmentLeft;
        [cell addSubview:preview];
        [cell addSubview:icon];
    } else {
        NSImageView *icon = [[NSImageView alloc] initWithFrame:NSMakeRect(12,29,60,60)];
        icon.image = app.icon ?: [NSImage imageNamed:NSImageNameApplicationIcon];
        icon.imageScaling = NSImageScaleProportionallyUpOrDown;
        label.frame = NSMakeRect(2,4,80,18);
        label.alignment = NSTextAlignmentCenter;
        [cell addSubview:icon];
    }
    [cell addSubview:label];
    return cell;
}

static void renderLocalSwitcher(void) {
    if (!localSwitcherApps.count || localSwitcherSelection == NSNotFound) return;
    if (!localSwitcherPanel) {
        localSwitcherPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,120,118)
            styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
        localSwitcherPanel.opaque = NO;
        localSwitcherPanel.backgroundColor = NSColor.clearColor;
        localSwitcherPanel.hasShadow = YES;
        localSwitcherPanel.level = NSStatusWindowLevel;
        localSwitcherPanel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
        if (@available(macOS 26.0, *)) {
            NSGlassEffectView *glass = [[NSGlassEffectView alloc] initWithFrame:localSwitcherPanel.contentView.bounds];
            glass.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            glass.style = NSGlassEffectViewStyleRegular;
            glass.cornerRadius = 18;
            glass.tintColor = [NSColor.windowBackgroundColor colorWithAlphaComponent:0.12];
            if (@available(macOS 27.0, *)) glass.effectIsInteractive = NO;
            NSView *content = [[NSView alloc] initWithFrame:glass.bounds];
            content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            glass.contentView = content;
            localSwitcherPanel.contentView = glass;
            localSwitcherContentView = content;
        } else {
            NSVisualEffectView *background = [[NSVisualEffectView alloc] initWithFrame:localSwitcherPanel.contentView.bounds];
            background.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            background.material = NSVisualEffectMaterialHUDWindow;
            background.state = NSVisualEffectStateActive;
            background.wantsLayer = YES;
            background.layer.cornerRadius = 18;
            background.layer.masksToBounds = YES;
            localSwitcherPanel.contentView = background;
            localSwitcherContentView = background;
        }
        localSwitcherStack = [[NSStackView alloc] initWithFrame:NSMakeRect(12,12,84,94)];
        localSwitcherStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        localSwitcherStack.spacing = 8;
        localSwitcherStack.distribution = NSStackViewDistributionFillEqually;
        [localSwitcherContentView addSubview:localSwitcherStack];
        localSwitcherLeftOverflow = [NSTextField labelWithString:@""];
        localSwitcherRightOverflow = [NSTextField labelWithString:@""];
        for (NSTextField *label in @[localSwitcherLeftOverflow,localSwitcherRightOverflow]) {
            label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
            label.textColor = NSColor.secondaryLabelColor;
            label.alignment = NSTextAlignmentCenter;
            [localSwitcherContentView addSubview:label];
        }
    }
    NSScreen *screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    CGFloat cellWidth = localSwitcherPreviews ? 220 : 84, cellHeight = localSwitcherPreviews ? 150 : 94;
    NSInteger maximumVisible = localSwitcherPreviews ? MAX(1,MIN(6,(NSInteger)((NSWidth(screen.visibleFrame)-112)/(cellWidth+8)))) : MAX(1,MIN(12,(NSInteger)((NSWidth(screen.visibleFrame)-112)/(cellWidth+8))));
    NSInteger count = localSwitcherApps.count, visibleCount = MIN(count,maximumVisible);
    NSInteger maximumStart = MAX(0,count-visibleCount);
    localSwitcherVisibleStart = MIN(MAX(0,localSwitcherVisibleStart),maximumStart);
    if (localSwitcherSelection < localSwitcherVisibleStart)
        localSwitcherVisibleStart = localSwitcherSelection;
    else if (localSwitcherSelection >= localSwitcherVisibleStart+visibleCount)
        localSwitcherVisibleStart = localSwitcherSelection-visibleCount+1;
    NSInteger start = MIN(MAX(0,localSwitcherVisibleStart),maximumStart);
    BOOL structureChanged = localSwitcherRenderedStart != start || localSwitcherRenderedCount != visibleCount ||
        localSwitcherRenderedPreviews != localSwitcherPreviews || (NSInteger)localSwitcherStack.arrangedSubviews.count != visibleCount;
    if (structureChanged) {
        for (NSView *view in localSwitcherStack.arrangedSubviews.copy) {
            [localSwitcherStack removeArrangedSubview:view];
            [view removeFromSuperview];
        }
        localSwitcherPreviewViews = [NSMutableDictionary dictionary];
        for (NSInteger offset=0; offset<visibleCount; offset++) {
            NSInteger index = start+offset;
            [localSwitcherStack addArrangedSubview:localSwitcherCell(localSwitcherApps[index],localSwitcherItemWindowIDs[index],localSwitcherItemTitles[index],index == localSwitcherSelection)];
        }
        localSwitcherRenderedStart = start;
        localSwitcherRenderedCount = visibleCount;
        localSwitcherRenderedPreviews = localSwitcherPreviews;
    } else {
        [localSwitcherStack.arrangedSubviews enumerateObjectsUsingBlock:^(NSView *cell, NSUInteger offset, BOOL *stop) {
            updateLocalSwitcherCellSelection(cell,start+(NSInteger)offset == localSwitcherSelection);
        }];
    }
    NSInteger hiddenLeft = start, hiddenRight = count-(start+visibleCount);
    CGFloat sidePadding = (hiddenLeft || hiddenRight) ? 44 : 12;
    CGFloat width = visibleCount*cellWidth + (visibleCount-1)*8 + sidePadding*2;
    CGFloat height = cellHeight+24;
    [localSwitcherPanel setContentSize:NSMakeSize(width,height)];
    localSwitcherStack.frame = NSMakeRect(sidePadding,12,width-sidePadding*2,cellHeight);
    localSwitcherLeftOverflow.hidden = hiddenLeft == 0;
    localSwitcherRightOverflow.hidden = hiddenRight == 0;
    localSwitcherLeftOverflow.stringValue = hiddenLeft ? [NSString stringWithFormat:@"‹ %ld",(long)hiddenLeft] : @"";
    localSwitcherRightOverflow.stringValue = hiddenRight ? [NSString stringWithFormat:@"%ld ›",(long)hiddenRight] : @"";
    localSwitcherLeftOverflow.frame = NSMakeRect(3,(height-20)/2,38,20);
    localSwitcherRightOverflow.frame = NSMakeRect(width-41,(height-20)/2,38,20);
    NSRect frame = localSwitcherPanel.frame, area = screen.visibleFrame;
    [localSwitcherPanel setFrameOrigin:NSMakePoint(NSMidX(area)-NSWidth(frame)/2,NSMidY(area)-NSHeight(frame)/2)];
    [localSwitcherPanel orderFrontRegardless];
    localSwitcherPreviewGeneration++;
    NSInteger previewStart = MAX(0,start-2);
    NSInteger previewEnd = MIN(count,start+visibleCount+2);
    loadLocalSwitcherPreviewImages([localSwitcherItemWindowIDs subarrayWithRange:NSMakeRange(previewStart,previewEnd-previewStart)],NO);
}

static void stepLocalSwitcher(BOOL reverse) {
    BOOL first = !localSwitcherActive;
    if (first) {
        localSwitcherApps = buildLocalSwitcherApps();
        localSwitcherVisibleStart = 0;
        localSwitcherRenderedStart = NSNotFound;
        if (!localSwitcherPreviewImageCache) localSwitcherPreviewImageCache = [NSMutableDictionary dictionary];
        if (!localSwitcherPreviewLoadsInFlight) localSwitcherPreviewLoadsInFlight = [NSMutableSet set];
        NSSet<NSNumber *> *currentWindowIDs = [NSSet setWithArray:localSwitcherItemWindowIDs ?: @[]];
        for (NSNumber *windowID in localSwitcherPreviewImageCache.allKeys.copy)
            if (![currentWindowIDs containsObject:windowID]) [localSwitcherPreviewImageCache removeObjectForKey:windowID];
    }
    if (!localSwitcherApps.count) return;
    localSwitcherActive = YES;
    localSwitcherSelection = nextLocalSwitcherIndex(localSwitcherApps.count,localSwitcherSelection,reverse,first);
    if (first) {
        NSScreen *screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
        CGFloat cellWidth = localSwitcherPreviews ? 220 : 84;
        NSInteger maximumVisible = localSwitcherPreviews ? MAX(1,MIN(6,(NSInteger)((NSWidth(screen.visibleFrame)-112)/(cellWidth+8)))) : MAX(1,MIN(12,(NSInteger)((NSWidth(screen.visibleFrame)-112)/(cellWidth+8))));
        NSInteger visibleCount = MIN((NSInteger)localSwitcherApps.count,maximumVisible);
        NSInteger start = localSwitcherSelection >= visibleCount ? localSwitcherSelection-visibleCount+1 : 0;
        loadLocalSwitcherPreviewImages([localSwitcherItemWindowIDs subarrayWithRange:NSMakeRange(start,visibleCount)],YES);
        NSInteger previewStart = MAX(0,start-2);
        NSInteger previewEnd = MIN((NSInteger)localSwitcherApps.count,start+visibleCount+2);
        loadLocalSwitcherPreviewImages([localSwitcherItemWindowIDs subarrayWithRange:NSMakeRange(previewStart,previewEnd-previewStart)],NO);
        NSUInteger generation = ++localSwitcherPanelGeneration;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,160*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
            if (localSwitcherActive && generation == localSwitcherPanelGeneration) renderLocalSwitcher();
        });
    } else {
        // A second Tab means the user is deliberately browsing the list.
        renderLocalSwitcher();
    }
}

static void finishLocalSwitcher(BOOL activate) {
    NSRunningApplication *selected = localSwitcherActive && localSwitcherSelection >= 0 &&
        localSwitcherSelection < (NSInteger)localSwitcherApps.count ? localSwitcherApps[localSwitcherSelection] : nil;
    CGWindowID selectedWindowID = selected ? localSwitcherItemWindowIDs[localSwitcherSelection].unsignedIntValue : 0;
    [localSwitcherPanel orderOut:nil];
    localSwitcherPanelGeneration++;
    localSwitcherPreviewGeneration++;
    localSwitcherActive = NO;
    localSwitcherTabHeld = NO;
    localSwitcherQHeld = NO;
    localSwitcherWHeld = NO;
    localSwitcherSelection = NSNotFound;
    localSwitcherVisibleStart = 0;
    localSwitcherRenderedStart = NSNotFound;
    localSwitcherApps = nil;
    localSwitcherItemWindowIDs = nil;
    localSwitcherItemTitles = nil;
    [localSwitcherSuppressedPIDs removeAllObjects];
    [localSwitcherSuppressedWindowIDs removeAllObjects];
    if (activate && selected && !selected.terminated) focusLocalSwitcherWindow(selected,selectedWindowID);
}

static BOOL localSwitcherChord(CGEventFlags flags) {
    CGEventFlags relevant = flags & (kCGEventFlagMaskCommand | kCGEventFlagMaskAlternate |
        kCGEventFlagMaskControl | kCGEventFlagMaskSecondaryFn);
    return localSwitcherEnabled && relevant == kCGEventFlagMaskCommand;
}

static void reloadLocalSwitcher(pid_t preferredPID, CGWindowID preferredWindowID, NSInteger fallbackIndex) {
    if (!localSwitcherActive) return;
    NSArray<NSRunningApplication *> *rebuilt = buildLocalSwitcherApps();
    if (!rebuilt.count) { finishLocalSwitcher(NO); return; }
    localSwitcherApps = rebuilt;
    NSInteger found = NSNotFound;
    for (NSInteger index=0; index<(NSInteger)rebuilt.count; index++) {
        if (preferredWindowID && localSwitcherItemWindowIDs[index].unsignedIntValue == preferredWindowID) { found = index; break; }
        if (!preferredWindowID && rebuilt[index].processIdentifier == preferredPID) { found = index; break; }
    }
    localSwitcherSelection = found == NSNotFound ? MIN(fallbackIndex,(NSInteger)rebuilt.count-1) : found;
    localSwitcherRenderedStart = NSNotFound;
    renderLocalSwitcher();
}

static void reloadLocalSwitcherPreservingSelection(void) {
    if (!localSwitcherActive || localSwitcherSelection < 0 ||
        localSwitcherSelection >= (NSInteger)localSwitcherApps.count) return;
    reloadLocalSwitcher(localSwitcherApps[localSwitcherSelection].processIdentifier,
        localSwitcherItemWindowIDs[localSwitcherSelection].unsignedIntValue,localSwitcherSelection);
}

typedef AXError (*SwitcherAXWindowIDFn)(AXUIElementRef,CGWindowID *);
static SwitcherAXWindowIDFn switcherAXWindowID;
static BOOL switcherAXWindowIDLoaded;

static CGWindowID localSwitcherWindowID(AXUIElementRef window) {
    if (!switcherAXWindowIDLoaded) {
        switcherAXWindowIDLoaded = YES;
        switcherAXWindowID = (SwitcherAXWindowIDFn)dlsym(RTLD_DEFAULT,"_AXUIElementGetWindow");
    }
    CGWindowID windowID = 0;
    if (switcherAXWindowID) switcherAXWindowID(window,&windowID);
    return windowID;
}

static void focusLocalSwitcherWindow(NSRunningApplication *app, CGWindowID targetWindowID) {
    if (!targetWindowID) {
        [app activateWithOptions:NSApplicationActivateIgnoringOtherApps | NSApplicationActivateAllWindows];
        return;
    }
    [app activateWithOptions:NSApplicationActivateIgnoringOtherApps];
    AXUIElementRef application = AXUIElementCreateApplication(app.processIdentifier);
    AXUIElementSetMessagingTimeout(application,0.3);
    id windows = attribute(application,kAXWindowsAttribute);
    for (id item in [windows isKindOfClass:NSArray.class] ? windows : @[]) {
        AXUIElementRef window = (__bridge AXUIElementRef)item;
        if (localSwitcherWindowID(window) != targetWindowID) continue;
        AXUIElementSetAttributeValue(application,kAXFocusedWindowAttribute,window);
        AXUIElementSetAttributeValue(window,kAXMainAttribute,kCFBooleanTrue);
        AXUIElementPerformAction(window,kAXRaiseAction);
        break;
    }
    CFRelease(application);
}

static BOOL localSwitcherWindowOnCurrentSpace(AXUIElementRef window, NSSet<NSNumber *> *spaces) {
    if (!localSwitcherCurrentOnly || !spaces.count) return YES;
    CGWindowID windowID = localSwitcherWindowID(window);
    if (!windowID) return YES;
    return switcherWindowsOnCurrentSpace(@[@(windowID)],spaces,NO);
}

static BOOL closeLocalSwitcherWindow(NSRunningApplication *app, CGWindowID targetWindowID, BOOL *lastEligibleWindow) {
    AXUIElementRef application = AXUIElementCreateApplication(app.processIdentifier);
    AXUIElementSetMessagingTimeout(application,0.15);
    id focused = attribute(application,kAXFocusedWindowAttribute);
    id main = attribute(application,kAXMainWindowAttribute);
    id windows = attribute(application,kAXWindowsAttribute);
    CFRelease(application);
    NSMutableArray *ordered = [NSMutableArray array];
    if (focused) [ordered addObject:focused];
    if (main && ![ordered containsObject:main]) [ordered addObject:main];
    if ([windows isKindOfClass:NSArray.class])
        for (id window in windows) if (![ordered containsObject:window]) [ordered addObject:window];
    NSSet *spaces = currentSwitcherSpaces();
    NSMutableArray *eligibleButtons = [NSMutableArray array];
    NSMutableArray<NSNumber *> *eligibleIDs = [NSMutableArray array];
    NSMutableSet<NSNumber *> *eligibleWindowIDs = [NSMutableSet set];
    for (id item in ordered) {
        AXUIElementRef window = (__bridge AXUIElementRef)item;
        if (![attribute(window,kAXRoleAttribute) isEqual:(__bridge NSString *)kAXWindowRole] ||
            ![attribute(window,kAXSubroleAttribute) isEqual:(__bridge NSString *)kAXStandardWindowSubrole] ||
            [attribute(window,kAXMinimizedAttribute) isEqual:@YES] ||
            !localSwitcherWindowOnCurrentSpace(window,spaces)) continue;
        CGWindowID windowID = localSwitcherWindowID(window);
        if (windowID && [eligibleWindowIDs containsObject:@(windowID)]) continue;
        if (windowID) [eligibleWindowIDs addObject:@(windowID)];
        id button = attribute(window,kAXCloseButtonAttribute);
        if (button && ![attribute((__bridge AXUIElementRef)button,kAXEnabledAttribute) isEqual:@NO]) {
            [eligibleButtons addObject:button];
            [eligibleIDs addObject:@(windowID)];
        }
    }
    if (lastEligibleWindow) *lastEligibleWindow = eligibleButtons.count == 1;
    NSInteger targetIndex = targetWindowID ? [eligibleIDs indexOfObject:@(targetWindowID)] : 0;
    if (targetIndex == NSNotFound || targetIndex >= (NSInteger)eligibleButtons.count) return NO;
    return AXUIElementPerformAction((__bridge AXUIElementRef)eligibleButtons[targetIndex],kAXPressAction) == kAXErrorSuccess;
}

static BOOL closeAllFinderWindows(NSRunningApplication *finder) {
    AXUIElementRef application = AXUIElementCreateApplication(finder.processIdentifier);
    AXUIElementSetMessagingTimeout(application,0.2);
    id windows = attribute(application,kAXWindowsAttribute);
    CFRelease(application);
    if (![windows isKindOfClass:NSArray.class]) return NO;
    NSMutableSet<NSNumber *> *closedWindowIDs = [NSMutableSet set];
    BOOL closed = NO;
    for (id item in windows) {
        AXUIElementRef window = (__bridge AXUIElementRef)item;
        if (![attribute(window,kAXRoleAttribute) isEqual:(__bridge NSString *)kAXWindowRole] ||
            ![attribute(window,kAXSubroleAttribute) isEqual:(__bridge NSString *)kAXStandardWindowSubrole]) continue;
        CGWindowID windowID = localSwitcherWindowID(window);
        if (windowID && [closedWindowIDs containsObject:@(windowID)]) continue;
        if (windowID) [closedWindowIDs addObject:@(windowID)];
        id button = attribute(window,kAXCloseButtonAttribute);
        if (button && ![attribute((__bridge AXUIElementRef)button,kAXEnabledAttribute) isEqual:@NO] &&
            AXUIElementPerformAction((__bridge AXUIElementRef)button,kAXPressAction) == kAXErrorSuccess) closed = YES;
    }
    return closed;
}

static void removeSelectedLocalSwitcherItem(void) {
    if (localSwitcherSelection < 0 || localSwitcherSelection >= (NSInteger)localSwitcherApps.count) return;
    NSMutableArray *remaining = [localSwitcherApps mutableCopy];
    NSMutableArray *remainingWindowIDs = [localSwitcherItemWindowIDs mutableCopy];
    NSMutableArray *remainingTitles = [localSwitcherItemTitles mutableCopy];
    [remaining removeObjectAtIndex:localSwitcherSelection];
    [remainingWindowIDs removeObjectAtIndex:localSwitcherSelection];
    [remainingTitles removeObjectAtIndex:localSwitcherSelection];
    localSwitcherApps = remaining;
    localSwitcherItemWindowIDs = remainingWindowIDs;
    localSwitcherItemTitles = remainingTitles;
    if (!remaining.count) { finishLocalSwitcher(NO); return; }
    localSwitcherSelection = MIN(localSwitcherSelection,(NSInteger)remaining.count-1);
    localSwitcherRenderedStart = NSNotFound;
    renderLocalSwitcher();
}

static void removeLocalSwitcherItemsForPID(pid_t pid) {
    if (!localSwitcherApps.count) return;
    NSMutableArray *remaining = [NSMutableArray array];
    NSMutableArray *remainingWindowIDs = [NSMutableArray array];
    NSMutableArray *remainingTitles = [NSMutableArray array];
    for (NSInteger index=0; index<(NSInteger)localSwitcherApps.count; index++) {
        if (localSwitcherApps[index].processIdentifier == pid) continue;
        [remaining addObject:localSwitcherApps[index]];
        [remainingWindowIDs addObject:localSwitcherItemWindowIDs[index]];
        [remainingTitles addObject:localSwitcherItemTitles[index]];
    }
    localSwitcherApps = remaining;
    localSwitcherItemWindowIDs = remainingWindowIDs;
    localSwitcherItemTitles = remainingTitles;
    if (!remaining.count) { finishLocalSwitcher(NO); return; }
    localSwitcherSelection = MIN(localSwitcherSelection,(NSInteger)remaining.count-1);
    localSwitcherRenderedStart = NSNotFound;
    renderLocalSwitcher();
}

static void performLocalSwitcherAction(CGKeyCode keyCode) {
    if (localSwitcherSelection < 0 || localSwitcherSelection >= (NSInteger)localSwitcherApps.count) return;
    NSRunningApplication *selected = localSwitcherApps[localSwitcherSelection];
    CGWindowID selectedWindowID = localSwitcherItemWindowIDs[localSwitcherSelection].unsignedIntValue;
    NSInteger oldIndex = localSwitcherSelection;
    if (keyCode == kVK_ANSI_Q) {
        if ([selected.bundleIdentifier isEqual:@"com.apple.finder"]) {
            if (!closeAllFinderWindows(selected)) { NSBeep(); return; }
            if (!localSwitcherSuppressedPIDs) localSwitcherSuppressedPIDs = [NSMutableSet set];
            [localSwitcherSuppressedPIDs addObject:@(selected.processIdentifier)];
            removeLocalSwitcherItemsForPID(selected.processIdentifier);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,500*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
                reloadLocalSwitcherPreservingSelection();
            });
            return;
        }
        if (![selected terminate]) { NSBeep(); return; }
        removeLocalSwitcherItemsForPID(selected.processIdentifier);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,300*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
            reloadLocalSwitcher(0,0,oldIndex);
        });
    } else if (keyCode == kVK_ANSI_W) {
        BOOL lastWindow = NO;
        if (!closeLocalSwitcherWindow(selected,selectedWindowID,&lastWindow)) { NSBeep(); return; }
        if (selectedWindowID) {
            if (!localSwitcherSuppressedWindowIDs) localSwitcherSuppressedWindowIDs = [NSMutableSet set];
            [localSwitcherSuppressedWindowIDs addObject:@(selectedWindowID)];
        }
        if (lastWindow && localSwitcherHideFinder && [selected.bundleIdentifier isEqual:@"com.apple.finder"]) {
            if (!localSwitcherSuppressedPIDs) localSwitcherSuppressedPIDs = [NSMutableSet set];
            [localSwitcherSuppressedPIDs addObject:@(selected.processIdentifier)];
            removeLocalSwitcherItemsForPID(selected.processIdentifier);
        } else if (localSwitcherEveryWindow) {
            removeSelectedLocalSwitcherItem();
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
            reloadLocalSwitcherPreservingSelection();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,800*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
            reloadLocalSwitcherPreservingSelection();
        });
    }
}

static BOOL hasNoWindows(id windows) {
    return [windows isKindOfClass:NSArray.class] && [windows count] == 0;
}

static void openEmptyFinder(void) {
    static NSAppleScript *script;
    static BOOL reportedFailure;
    NSDictionary *error = nil;
    if (!script) {
        NSURL *url = [NSBundle.mainBundle URLForResource:@"OpenEmptyFinder" withExtension:@"scpt"];
        if (url) script = [[NSAppleScript alloc] initWithContentsOfURL:url error:&error];
    }
    if (script && [script executeAndReturnError:&error]) { reportedFailure = NO; return; }
    if (reportedFailure) return;
    reportedFailure = YES;
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Couldn’t open a Finder window";
    alert.informativeText = [error[NSAppleScriptErrorNumber] integerValue] == -1743 ?
        @"Allow Macdows to control Finder in System Settings → Privacy & Security → Automation." :
        error[NSAppleScriptErrorMessage] ?: @"Reopen the installed copy of Macdows and try again.";
    [alert runModal];
}

static void reopenEmptyApp(NSRunningApplication *front, NSUInteger generation, NSUInteger retries) {
    if (generation != switchGeneration || !front.active || front.terminated) return;
    BOOL openEmpty = scopeIncludesApp(front.bundleIdentifier);
    if (!restoreEnabled && !openEmpty) return;
    BOOL finder = [front.bundleIdentifier isEqual:@"com.apple.finder"];
    AXUIElementRef app = AXUIElementCreateApplication(front.processIdentifier);
    AXUIElementSetMessagingTimeout(app,0.2);
    id windows = attribute(app,kAXWindowsAttribute);
    id mainWindow = restoreEnabled ? attribute(app,kAXMainWindowAttribute) : nil;
    CFRelease(app);
    if (restoreEnabled && [windows isKindOfClass:NSArray.class]) {
        id candidate = nil;
        for (id item in windows) {
            AXUIElementRef window = (__bridge AXUIElementRef)item;
            id subrole = attribute(window,kAXSubroleAttribute);
            if ([subrole isEqual:(__bridge NSString *)kAXSystemDialogSubrole] ||
                [subrole isEqual:@"AXDialog"]) return;
            if (finder && [subrole isEqual:@"AXUnknown"] &&
                [attribute(window,kAXTitleAttribute) isEqual:@""]) continue;
            id minimized = attribute(window,kAXMinimizedAttribute);
            if (![minimized isEqual:@YES]) { candidate = nil; break; }
            if (!candidate || [mainWindow isEqual:item]) candidate = item;
        }
        if (candidate && front.active) {
            AXUIElementRef window = (__bridge AXUIElementRef)candidate;
            if (AXUIElementSetAttributeValue(window,kAXMinimizedAttribute,kCFBooleanFalse) == kAXErrorSuccess && front.active)
                AXUIElementPerformAction(window,kAXRaiseAction);
            return;
        }
    }
    if (finder && openEmpty && front.active) { openEmptyFinder(); return; }
    if (!openEmpty && windows) return;
    if (!windows && retries) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,150*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
            reopenEmptyApp(front,generation,retries-1);
        });
        return;
    }
    if (!hasNoWindows(windows) || !front.active) return;
    if (front.bundleURL) {
        NSWorkspaceOpenConfiguration *config = NSWorkspaceOpenConfiguration.configuration;
        config.createsNewApplicationInstance = NO;
        [NSWorkspace.sharedWorkspace openApplicationAtURL:front.bundleURL configuration:config completionHandler:nil];
    }
}

static NSString *const fileCutKey = @"FinderCutAndMove";
static BOOL fileCutEnabled, cutKeyHeld, moveKeyHeld;
static NSInteger cutClipboard = -1;

static NSInteger copyBaseline = -1;
static NSUInteger copyGeneration;
static NSArray<NSURL *> *cutFiles;

static NSArray<NSURL *> *fileURLs(NSPasteboard *board) {
    return [board readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey:@YES}];
}

static void clearCut(void) {
    copyBaseline = -1; cutClipboard = -1; cutFiles = nil; copyGeneration++;
}

static void awaitFinderCopy(NSUInteger generation, NSUInteger attempts) {
    if (generation != copyGeneration || copyBaseline < 0) return;
    NSPasteboard *board = NSPasteboard.generalPasteboard;
    NSInteger change = board.changeCount;
    if (change != copyBaseline) {
        NSArray *urls = fileURLs(board);
        if (urls.count && board.changeCount == change) {
            cutFiles = [urls copy]; cutClipboard = change; copyBaseline = -1; return;
        }
    }
    if (!attempts) { clearCut(); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
        awaitFinderCopy(generation, attempts-1);
    });
}

static const int64_t nativeMoveTag = 0x4d6163646f77734dLL;

static CGEventRef copyNativeMoveEvent(BOOL down) {
    CGEventRef event = CGEventCreateKeyboardEvent(NULL,kVK_ANSI_V,down);
    if (event) {
        CGEventSetFlags(event,kCGEventFlagMaskCommand | kCGEventFlagMaskAlternate);
        CGEventSetIntegerValueField(event,kCGEventSourceUserData,nativeMoveTag);
    }
    return event;
}

// Finder owns destination resolution, collision handling, permissions and undo.
static void pasteCutFiles(NSRunningApplication *finder, NSUInteger generation) {
    if (generation != copyGeneration || !fileCutEnabled) return;
    if (copyBaseline >= 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
            pasteCutFiles(finder,generation);
        });
        return;
    }
    if (!finder.active || finder.terminated ||
        cutClipboard < 0 || cutClipboard != NSPasteboard.generalPasteboard.changeCount) return;
    CGEventRef down = copyNativeMoveEvent(YES);
    CGEventRef up = copyNativeMoveEvent(NO);
    if (!down || !up) {
        if (down) CFRelease(down);
        if (up) CFRelease(up);
        return;
    }
    CGEventPostToPid(finder.processIdentifier,down);
    CGEventPostToPid(finder.processIdentifier,up);
    CFRelease(down);
    CFRelease(up);
    clearCut();
}

// Locate Edit by its standard shortcuts, including on non-English systems.
// Only replace a disabled Cut. Finder enables the native Cut when editing text.
static id copyFileCommand(AXUIElementRef app) {
    id bar = attribute(app,kAXMenuBarAttribute);
    if (!bar) return nil;
    NSMutableArray *headings = [attribute((__bridge AXUIElementRef)bar,kAXChildrenAttribute) mutableCopy];
    if (headings.count > 3) [headings exchangeObjectAtIndex:0 withObjectAtIndex:3];
    for (id heading in headings) {
        id menu = [attribute((__bridge AXUIElementRef)heading,kAXChildrenAttribute) firstObject];
        if (!menu) continue;
        id copy = nil; BOOL disabledCut = NO;
        for (id item in attribute((__bridge AXUIElementRef)menu,kAXChildrenAttribute)) {
            AXUIElementRef entry = (__bridge AXUIElementRef)item;
            NSString *key = [attribute(entry,kAXMenuItemCmdCharAttribute) lowercaseString];
            if (![key isEqual:@"x"] && ![key isEqual:@"c"]) continue;
            NSNumber *mods = attribute(entry,kAXMenuItemCmdModifiersAttribute);
            if (!mods || mods.integerValue != 0) continue;
            NSNumber *enabled = attribute(entry,kAXEnabledAttribute);
            if ([key isEqual:@"x"] && [enabled isEqual:@NO]) disabledCut = YES;
            if ([key isEqual:@"c"] && [enabled isEqual:@YES]) copy = item;
            if (disabledCut && copy) return copy;
        }
    }
    return nil;
}

static BOOL fileFocus(AXUIElementRef app) {
    id focus = attribute(app,kAXFocusedUIElementAttribute);
    if (!focus) return NO;
    AXUIElementRef el = (__bridge AXUIElementRef)focus;
    NSString *role = attribute(el,kAXRoleAttribute);
    if (!role || [@[@"AXTextField",@"AXTextArea",@"AXComboBox",@"AXSearchField"] containsObject:role]) return NO;
    return !attribute(el,kAXSelectedTextRangeAttribute);
}

static BOOL handleFileShortcut(CGEventType type, CGEventRef event) {
    if (type != kCGEventKeyDown && type != kCGEventKeyUp) return NO;
    CGKeyCode key = CGEventGetIntegerValueField(event,kCGKeyboardEventKeycode);
    if (key == kVK_ANSI_X && cutKeyHeld) {
        if (type == kCGEventKeyUp) cutKeyHeld = NO;
        return YES;
    }
    if (key == kVK_ANSI_V && moveKeyHeld) {
        if (type == kCGEventKeyDown) return YES;
        moveKeyHeld = NO;
        return YES;
    }
    CGEventFlags flags = CGEventGetFlags(event);
    CGEventFlags mask = kCGEventFlagMaskCommand|kCGEventFlagMaskAlternate|kCGEventFlagMaskControl|kCGEventFlagMaskShift;
    if (!fileCutEnabled || type != kCGEventKeyDown || (flags & mask) != kCGEventFlagMaskCommand) return NO;
    if (key == kVK_ANSI_C || key == kVK_ANSI_X) clearCut();
    if (key != kVK_ANSI_X && !(key == kVK_ANSI_V && (cutClipboard >= 0 || copyBaseline >= 0))) return NO;
    NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
    if (![front.bundleIdentifier isEqual:@"com.apple.finder"]) return NO;
    NSPasteboard *board = NSPasteboard.generalPasteboard;
    if (key == kVK_ANSI_V && cutClipboard >= 0 && cutClipboard != board.changeCount) { clearCut(); return NO; }
    AXUIElementRef app = AXUIElementCreateApplication(front.processIdentifier);
    AXUIElementSetMessagingTimeout(app,0.08);
    BOOL intercept = NO;
    if (fileFocus(app)) {
        if (key == kVK_ANSI_X) {
            id copy = copyFileCommand(app);
            NSInteger before = board.changeCount;
            if (copy && AXUIElementPerformAction((__bridge AXUIElementRef)copy,kAXPressAction)==kAXErrorSuccess) {
                copyBaseline = before;
                awaitFinderCopy(copyGeneration,60);
                cutKeyHeld = YES; intercept = YES;
            }
        } else {
            NSUInteger generation = copyGeneration;
            moveKeyHeld = YES; intercept = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,80*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
                pasteCutFiles(front,generation);
            });
        }
    }
    CFRelease(app);
    return intercept;
}

static NSString *const cycleKey = @"CycleWindowsByPhysicalKey";
static BOOL cycleEnabled, cycleKeyDown;
static NSString *const snapKey = @"ControlArrowsSnap";
static NSString *const arrangeKey = @"ControlOptionArrowsArrange";
static NSString *const desktopKey = @"ControlShiftOptionArrowsDesktops";
static BOOL snapEnabled, arrangeEnabled, desktopEnabled;
static BOOL arrowConsumed[4];
static BOOL arrowArrange[4];
static BOOL desktopArrowConsumed[2];
static atomic_bool desktopSwitchInFlight;
static NSInteger arrowIndex(CGKeyCode key) {
    switch (key) {
        case kVK_LeftArrow: return 0;
        case kVK_RightArrow: return 1;
        case kVK_UpArrow: return 2;
        case kVK_DownArrow: return 3;
        default: return -1;
    }
}
static BOOL arrangementChord(CGEventFlags flags, NSInteger direction) {
    if (@available(macOS 15.0, *)) {
        CGEventFlags mask = kCGEventFlagMaskCommand | kCGEventFlagMaskControl |
                           kCGEventFlagMaskAlternate | kCGEventFlagMaskShift;
        CGEventFlags chord = flags & mask;
        return (snapEnabled && direction < 2 && chord == kCGEventFlagMaskControl) ||
               (arrangeEnabled && chord == (kCGEventFlagMaskControl | kCGEventFlagMaskAlternate));
    }
    return NO;
}
static BOOL desktopChord(CGEventFlags flags, NSInteger direction) {
    // Arrow events reach this check before the active Globe/Fn modifier is
    // rewritten below. Treat a held Fn configured as Control as Control here.
    if (globeHeld && heldMode == GlobeControl &&
        (flags & kCGEventFlagMaskSecondaryFn)) flags |= kCGEventFlagMaskControl;
    CGEventFlags mask = kCGEventFlagMaskCommand | kCGEventFlagMaskControl |
                       kCGEventFlagMaskAlternate | kCGEventFlagMaskShift;
    CGEventFlags wanted = kCGEventFlagMaskControl | kCGEventFlagMaskAlternate |
                          kCGEventFlagMaskShift;
    return desktopEnabled && direction < 2 && (flags & mask) == wanted;
}
static NSString *desktopScriptName(NSInteger direction) {
    return direction == 0 ? @"SwitchDesktopLeft" : @"SwitchDesktopRight";
}
static BOOL executeDesktopSwitch(NSInteger direction, NSDictionary **reportedError) {
    static NSAppleScript *scripts[2];
    NSDictionary *error=nil;
    if (direction < 0 || direction > 1) return NO;
    if (!scripts[direction]) {
        NSURL *url=[NSBundle.mainBundle URLForResource:desktopScriptName(direction) withExtension:@"scpt"];
        if (url) scripts[direction]=[[NSAppleScript alloc] initWithContentsOfURL:url error:&error];
    }
    atomic_store(&desktopSwitchInFlight,true);
    BOOL success=scripts[direction] && [scripts[direction] executeAndReturnError:&error];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC),dispatch_get_main_queue(), ^{
        atomic_store(&desktopSwitchInFlight,false);
    });
    if (reportedError) *reportedError=error;
    return success;
}
static void launchSystemEvents(void) {
    NSURL *url=[NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:@"com.apple.systemevents"];
    if (!url) return;
    NSWorkspaceOpenConfiguration *configuration=[NSWorkspaceOpenConfiguration configuration];
    configuration.activates=YES;
    [NSWorkspace.sharedWorkspace openApplicationAtURL:url configuration:configuration
        completionHandler:^(NSRunningApplication *application, NSError *error) {}];
}
static void runDesktopSwitchWhenReady(NSInteger direction, NSUInteger releaseAttempt,
                                      NSUInteger launchAttempt) {
    CGEventFlags blocking=kCGEventFlagMaskCommand|kCGEventFlagMaskAlternate|
        kCGEventFlagMaskShift|kCGEventFlagMaskSecondaryFn;
    if (CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState)&blocking) {
        if (releaseAttempt < 250) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_MSEC),
            dispatch_get_main_queue(), ^{ runDesktopSwitchWhenReady(direction,releaseAttempt+1,launchAttempt); });
        return;
    }
    static BOOL reportedFailure;
    if (launchAttempt == 0) {
        launchSystemEvents();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(), ^{
            runDesktopSwitchWhenReady(direction,releaseAttempt,1);
        });
        return;
    }
    NSDictionary *error=nil;
    if (executeDesktopSwitch(direction,&error)) { reportedFailure=NO; return; }
    if ([error[NSAppleScriptErrorNumber] integerValue] == -600 && launchAttempt < 5) {
        launchSystemEvents();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,50*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
            runDesktopSwitchWhenReady(direction,releaseAttempt,launchAttempt+1);
        });
        return;
    }
    if (reportedFailure) return;
    reportedFailure=YES;
    NSAlert *alert=[NSAlert new];
    alert.messageText=@"Couldn’t switch desktops";
    alert.informativeText=[error[NSAppleScriptErrorNumber] integerValue] == -1743 ?
        @"Allow Macdows to control System Events in System Settings → Privacy & Security → Automation." :
        error[NSAppleScriptErrorMessage] ?: @"Reopen the installed copy of Macdows and try again.";
    [alert runModal];
}
static void scheduleDesktopSwitch(NSInteger direction) {
    dispatch_async(dispatch_get_main_queue(), ^{
        launchSystemEvents();
        runDesktopSwitchWhenReady(direction,0,1);
    });
}
static void (*desktopSwitchScheduler)(NSInteger)=scheduleDesktopSwitch;
static void postDesktopSwitch(NSInteger direction) {
    desktopSwitchScheduler(direction);
}
// Call the actual macOS menu command. Fn shortcuts synthesized at the session
// tap are not reliably recognized by the system tiling handler.
static BOOL readGeometry(AXUIElementRef win, CGRect *frame);
static void sizeWindow(id window, NSInteger mode); // 0 toggle, 1 fill, 2 restore
static dispatch_queue_t windowActionQueue(void) {
    static dispatch_queue_t queue; static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("local.macdows.window-actions", DISPATCH_QUEUE_SERIAL); });
    return queue;
}
static void windowDiagnostic(NSString *record) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"macdows-window-action.log"];
    NSString *old = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"";
    NSArray *lines = [old componentsSeparatedByString:@"\n"];
    if (lines.count > 24) old = [[lines subarrayWithRange:NSMakeRange(lines.count-24,24)] componentsJoinedByString:@"\n"];
    [[old stringByAppendingFormat:@"1.35 %@ %@\n",NSDate.date,record] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
static BOOL similar(CGRect a, CGRect b);
static id placementAttribute(id object, CFStringRef key) {
    if (!object) return nil;
    AXUIElementRef element = (__bridge AXUIElementRef)object;
    AXUIElementSetMessagingTimeout(element,0.15);
    CFTypeRef value = NULL;
    AXUIElementCopyAttributeValue(element,key,&value);
    return CFBridgingRelease(value);
}
static BOOL placementKeyMatches(NSInteger key, NSInteger modifiers, NSInteger direction, BOOL pair) {
    NSInteger expected = direction == 0 ? kVK_LeftArrow : direction == 1 ? kVK_RightArrow : direction == 2 ? kVK_ANSI_F : kVK_ANSI_R;
    NSInteger mask = kAXMenuItemModifierShift | kAXMenuItemModifierOption | kAXMenuItemModifierControl | kAXMenuItemModifierNoCommand;
    NSInteger wanted = kAXMenuItemModifierControl | kAXMenuItemModifierNoCommand;
    if (pair && direction < 2) wanted |= kAXMenuItemModifierShift;
    return key == expected && (modifiers & mask) == wanted;
}
static BOOL placementMatches(id item, NSInteger direction, BOOL pair) {
    NSString *title = placementAttribute(item,kAXTitleAttribute);
    NSArray *titles = pair ? @[@"Left & Right",@"Right & Left",@"Fill",@"Return to Previous Size"] : @[@"Left",@"Right",@"Fill",@"Return to Previous Size"];
    if ([title isEqual:titles[direction]]) return YES;
    NSNumber *key = placementAttribute(item,kAXMenuItemCmdVirtualKeyAttribute);
    NSNumber *mods = placementAttribute(item,kAXMenuItemCmdModifiersAttribute);
    return key && mods && placementKeyMatches(key.integerValue,mods.integerValue,direction,pair);
}
static id placementFind(NSArray *items, NSInteger direction, BOOL pair) {
    NSArray *titles=pair ? @[@"Left & Right",@"Right & Left",@"Fill",@"Return to Previous Size"] : @[@"Left",@"Right",@"Fill",@"Return to Previous Size"];
    for (id item in items) if ([placementAttribute(item,kAXTitleAttribute) isEqual:titles[direction]]) return item;
    for (id item in items) if (placementMatches(item,direction,pair)) return item;
    return nil;
}
// All placement input enters one coordinator. There is at most one executing
// request and one pending request; a newer intent cancels obsolete work.
typedef NS_ENUM(NSInteger, WindowIntent) { WindowLeft, WindowRight, WindowFill,
    WindowRestore, WindowToggle, WindowMove };
@interface WindowRequest : NSObject
@property(strong) id window;
@property(strong) NSRunningApplication *app;
@property WindowIntent intent;
@property BOOL pair;
@property CGPoint origin;
@property NSUInteger generation;
@end
@implementation WindowRequest
@end
@interface WindowState : NSObject
@property CGRect baseline, observed;
@property BOOL hasBaseline, hasObserved, confirmed;
@property WindowIntent intent;
@property NSUInteger generation;
@end
@implementation WindowState
@end
static NSMapTable *windowStates;
static WindowRequest *pendingWindowRequest;
static BOOL windowWorkerRunning;
static NSUInteger windowGeneration;
static void executeWindowRequest(WindowRequest *request);
static void (*windowExecutor)(WindowRequest *)=executeWindowRequest;
static BOOL requestCurrent(WindowRequest *request) {
    @synchronized(WindowRequest.class) { return request.generation == windowGeneration; }
}
static void cancelWindowRequests(void) {
    @synchronized(WindowRequest.class) { windowGeneration++; pendingWindowRequest=nil; }
}
static void submitWindowRequest(WindowRequest *request) {
    @synchronized(WindowRequest.class) {
        request.generation=++windowGeneration;
        pendingWindowRequest=request;
        if (windowWorkerRunning) return;
        windowWorkerRunning=YES;
    }
    dispatch_async(windowActionQueue(), ^{
        while (YES) { @autoreleasepool {
            WindowRequest *next;
            @synchronized(WindowRequest.class) {
                next=pendingWindowRequest; pendingWindowRequest=nil;
                if (!next) { windowWorkerRunning=NO; break; }
            }
            windowExecutor(next);
        } }
    });
}
static void requestWindow(id window, NSRunningApplication *app, WindowIntent intent, BOOL pair, CGPoint origin) {
    if (!window || !app || app.terminated) return;
    WindowRequest *request=[WindowRequest new];
    request.window=window; request.app=app; request.intent=intent;
    request.pair=pair; request.origin=origin;
    submitWindowRequest(request);
}
static void performPlacement(NSRunningApplication *front, NSInteger direction, BOOL pair) {
    // Resolve the target once, before looking up a menu. Never let a delayed
    // command migrate to another window of the same application.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!front.active || front.terminated) return;
        AXUIElementRef app=AXUIElementCreateApplication(front.processIdentifier);
        id window=attribute(app,kAXFocusedWindowAttribute);
        CFRelease(app);
        requestWindow(window,front,(WindowIntent)direction,pair,CGPointZero);
    });
}

// AXWindows can reorder on every raise. Keep surviving windows in their
// original order and append newly opened windows to the end of the ring.
static id cycleTarget(NSMutableArray *ring, NSArray *available, id focused, BOOL reverse) {
    [ring removeObjectsInArray:[ring filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(id window, NSDictionary *bindings) {
            return ![available containsObject:window];
        }]]];
    for (id window in available)
        if (![ring containsObject:window]) [ring addObject:window];
    NSUInteger index = [ring indexOfObject:focused];
    if (index == NSNotFound || ring.count < 2) return nil;
    NSUInteger step = reverse ? ring.count - 1 : 1;
    return ring[(index + step) % ring.count];
}

// Window cycling must never turn an AX failure into a dead keyboard shortcut.
// Run AX calls away from the main/event-tap thread and preserve the original
// key event for native fallback. The queue also owns the stable window ring.
static dispatch_queue_t cycleQueue(void) {
    static dispatch_queue_t queue; static dispatch_once_t once;
    dispatch_once(&once, ^{ queue=dispatch_queue_create("local.macdows.window-cycle",DISPATCH_QUEUE_SERIAL); });
    return queue;
}
static BOOL cycleCandidate(NSString *role, NSString *subrole, NSNumber *minimized) {
    if (![role isEqual:(__bridge NSString *)kAXWindowRole] || minimized.boolValue) return NO;
    return !subrole || [subrole isEqual:(__bridge NSString *)kAXStandardWindowSubrole] ||
        [subrole isEqual:(__bridge NSString *)kAXUnknownSubrole];
}
static BOOL cycleWindows(NSRunningApplication *front, BOOL reverse) {
    if (!front.active || front.terminated) {
        dispatch_async(windowActionQueue(), ^{ windowDiagnostic(@"cycle skipped: original app inactive"); });
        return YES; // Never act in another app.
    }
    static NSRunningApplication *owner;
    static NSMutableArray *ring;
    if (![owner isEqual:front]) {
        owner=front; ring=[NSMutableArray array];
    }
    id app=CFBridgingRelease(AXUIElementCreateApplication(front.processIdentifier));
    AXUIElementRef appElement=(__bridge AXUIElementRef)app;
    NSArray *windows=attribute(appElement,kAXWindowsAttribute);
    id focused=attribute(appElement,kAXFocusedWindowAttribute) ?: attribute(appElement,kAXMainWindowAttribute);
    if (!focused || ![windows isKindOfClass:NSArray.class]) {
        dispatch_async(windowActionQueue(), ^{ windowDiagnostic([NSString stringWithFormat:@"cycle app=%@ fallback: windows=%@ focused=%d",front.bundleIdentifier,[windows class],focused!=nil]); });
        return NO;
    }
    NSMutableArray *available=[NSMutableArray array];
    double deadline=CFAbsoluteTimeGetCurrent()+0.3;
    for (id item in windows) {
        if (CFAbsoluteTimeGetCurrent()>deadline) {
            dispatch_async(windowActionQueue(), ^{ windowDiagnostic([NSString stringWithFormat:@"cycle app=%@ fallback: enumeration timeout total=%lu eligible=%lu",front.bundleIdentifier,(unsigned long)windows.count,(unsigned long)available.count]); });
            return NO;
        }
        AXUIElementRef win=(__bridge AXUIElementRef)item;
        if (cycleCandidate(attribute(win,kAXRoleAttribute),attribute(win,kAXSubroleAttribute),attribute(win,kAXMinimizedAttribute)))
            [available addObject:item];
    }
    id next=cycleTarget(ring,available,focused,reverse);
    if (!next) {
        dispatch_async(windowActionQueue(), ^{ windowDiagnostic([NSString stringWithFormat:@"cycle app=%@ fallback: no target total=%lu eligible=%lu",front.bundleIdentifier,(unsigned long)windows.count,(unsigned long)available.count]); });
        return NO;
    }
    if (!front.active || front.terminated) return YES;
    AXUIElementRef win=(__bridge AXUIElementRef)next;
    AXUIElementSetMessagingTimeout(win,0.08);
    AXError mainResult=AXUIElementSetAttributeValue(win,kAXMainAttribute,kCFBooleanTrue);
    AXError raiseResult=AXUIElementPerformAction(win,kAXRaiseAction);
    id after=attribute(appElement,kAXFocusedWindowAttribute);
    if ([after isEqual:next]) return YES;
    // Some apps implement raising but require an explicit focused-window change.
    AXError focusResult=AXUIElementSetAttributeValue(appElement,kAXFocusedWindowAttribute,(__bridge CFTypeRef)next);
    after=attribute(appElement,kAXFocusedWindowAttribute);
    if ([after isEqual:next]) return YES;
    // If focus moved elsewhere meanwhile, do not replay into that other window.
    if (after && ![after isEqual:focused]) return YES;
    dispatch_async(windowActionQueue(), ^{
        windowDiagnostic([NSString stringWithFormat:@"cycle app=%@ native-fallback main=%d raise=%d focus=%d",front.bundleIdentifier,mainResult,raiseResult,focusResult]);
    });
    return NO;
}
static void normalizeCycleFallback(CGEventRef event) {
    // The native shortcut is logical Command-Grave. The physical key produces
    // a layout-specific character (for example, ё in Russian), so replaying
    // the original text makes fallback layout-dependent.
    UniChar grave='`';
    CGEventKeyboardSetUnicodeString(event,1,&grave);
}
static void (*cycleEventPoster)(CGEventTapLocation,CGEventRef)=CGEventPost;
static void postCycleEvent(CGEventRef event) {
    cycleEventPoster(kCGSessionEventTap,event);
}
static void replayCycleKey(NSRunningApplication *front, CGEventRef original) {
    if (!original || !front.active || front.terminated) return;
    CGEventRef up=CGEventCreateCopy(original);
    if (!up) return;
    CGEventSetIntegerValueField(original,kCGEventSourceUserData,nativeMoveTag);
    CGEventSetIntegerValueField(original,kCGKeyboardEventAutorepeat,0);
    CGEventSetType(up,kCGEventKeyUp);
    CGEventSetIntegerValueField(up,kCGEventSourceUserData,nativeMoveTag);
    CGEventSetIntegerValueField(up,kCGKeyboardEventAutorepeat,0);
    normalizeCycleFallback(original);
    normalizeCycleFallback(up);
    dispatch_async(windowActionQueue(), ^{ windowDiagnostic([NSString stringWithFormat:@"cycle app=%@ fallback: posting session Command-Grave",front.bundleIdentifier]); });
    postCycleEvent(original);
    postCycleEvent(up);
    CFRelease(up);
}

static CGEventRef globeEvent(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *context) {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        memset(arrowConsumed,0,sizeof(arrowConsumed));
        memset(desktopArrowConsumed,0,sizeof(desktopArrowConsumed));
        cycleKeyDown = NO; cutKeyHeld = NO; moveKeyHeld = NO; clearCut();
        switchGeneration++;
        globeHeld = NO; spaceConsumed = NO; shiftPending = NO; shiftBlocked = NO;
        dispatch_async(dispatch_get_main_queue(), ^{ finishLocalSwitcher(NO); });
        pauseInput();
        return event;
    }
    if (CGEventGetIntegerValueField(event,kCGEventSourceUserData) == nativeMoveTag) return event;
    CGKeyCode keyCode = (CGKeyCode)CGEventGetIntegerValueField(event,kCGKeyboardEventKeycode);
    CGEventFlags eventFlags = CGEventGetFlags(event);
    if (localSwitcherActive && type == kCGEventFlagsChanged && !(eventFlags & kCGEventFlagMaskCommand)) {
        finishLocalSwitcher(YES);
        return NULL;
    }
    if (localSwitcherActive && type == kCGEventKeyDown && keyCode == kVK_Escape) {
        finishLocalSwitcher(NO);
        return NULL;
    }
    if (localSwitcherActive && (keyCode == kVK_ANSI_Q || keyCode == kVK_ANSI_W) &&
        (type == kCGEventKeyDown || type == kCGEventKeyUp)) {
        BOOL *held = keyCode == kVK_ANSI_Q ? &localSwitcherQHeld : &localSwitcherWHeld;
        if (type == kCGEventKeyUp) { *held = NO; return NULL; }
        if (!*held && !CGEventGetIntegerValueField(event,kCGKeyboardEventAutorepeat))
            performLocalSwitcherAction(keyCode);
        *held = YES;
        return NULL;
    }
    if ((type == kCGEventKeyDown || type == kCGEventKeyUp) && keyCode == kVK_Tab &&
        (localSwitcherActive || localSwitcherChord(eventFlags))) {
        if (type == kCGEventKeyUp) { localSwitcherTabHeld = NO; return NULL; }
        if (!localSwitcherTabHeld || CGEventGetIntegerValueField(event,kCGKeyboardEventAutorepeat))
            stepLocalSwitcher((eventFlags & kCGEventFlagMaskShift) != 0);
        localSwitcherTabHeld = YES;
        return NULL;
    }
    if (updateGlobeShift(type, CGEventGetFlags(event)))
        dispatch_async(dispatch_get_main_queue(), ^{ switchInputSource(); });
    if ((type == kCGEventKeyDown || type == kCGEventKeyUp) &&
        CGEventGetIntegerValueField(event,kCGKeyboardEventKeycode) == kVK_ANSI_Grave) {
        if (type == kCGEventKeyUp && cycleKeyDown) { cycleKeyDown = NO; return NULL; }
        CGEventFlags flags = CGEventGetFlags(event);
        CGEventFlags mask = kCGEventFlagMaskCommand | kCGEventFlagMaskAlternate |
                            kCGEventFlagMaskControl | kCGEventFlagMaskSecondaryFn;
        if (type == kCGEventKeyDown && cycleEnabled && (flags & mask) == kCGEventFlagMaskCommand) {
            NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
            BOOL reverse = (flags & kCGEventFlagMaskShift) != 0;
            dispatch_async(windowActionQueue(), ^{ windowDiagnostic([NSString stringWithFormat:@"cycle input app=%@ reverse=%d",front.bundleIdentifier,reverse]); });
            // Do not enqueue auto-repeat bursts behind an unresponsive app.
            if (CGEventGetIntegerValueField(event,kCGKeyboardEventAutorepeat))
                return cycleKeyDown ? NULL : event;
            CGEventRef original=CGEventCreateCopy(event);
            if (!original) return event;
            cancelWindowRequests();
            dispatch_async(cycleQueue(), ^{
                @autoreleasepool {
                    if (!cycleWindows(front,reverse)) replayCycleKey(front,original);
                    CFRelease(original);
                }
            });
            cycleKeyDown = YES;
            return NULL;
        }
    }
    if (type == kCGEventKeyDown || type == kCGEventKeyUp) {
        NSInteger direction = arrowIndex((CGKeyCode)CGEventGetIntegerValueField(event,kCGKeyboardEventKeycode));
        if (direction >= 0) {
            CGEventFlags shortcutFlags=CGEventGetFlags(event)&
                (kCGEventFlagMaskCommand|kCGEventFlagMaskControl|kCGEventFlagMaskAlternate|kCGEventFlagMaskShift);
            if (direction < 2 && atomic_load(&desktopSwitchInFlight) &&
                shortcutFlags == kCGEventFlagMaskControl) {
                if (type == kCGEventKeyUp) atomic_store(&desktopSwitchInFlight,false);
                return event;
            }
            BOOL desktopMatch=direction < 2 && desktopChord(CGEventGetFlags(event),direction);
            if (direction < 2 && type == kCGEventKeyUp && desktopArrowConsumed[direction]) {
                desktopArrowConsumed[direction] = NO;
                return NULL;
            }
            if (direction < 2 && type == kCGEventKeyDown &&
                (desktopArrowConsumed[direction] || desktopMatch)) {
                // One desktop transition per physical press. Do not turn key
                // repeat into several animated Space changes.
                if (desktopArrowConsumed[direction]) return NULL;
                desktopArrowConsumed[direction] = YES;
                postDesktopSwitch(direction);
                return NULL;
            }
            if (type == kCGEventKeyUp && arrowConsumed[direction]) {
                arrowConsumed[direction] = NO;
                return NULL;
            }
            if (type == kCGEventKeyDown && (arrowConsumed[direction] || arrangementChord(CGEventGetFlags(event),direction))) {
                if (!arrowConsumed[direction] && !CGEventGetIntegerValueField(event,kCGKeyboardEventAutorepeat)) {
                    arrowArrange[direction] = (CGEventGetFlags(event) & kCGEventFlagMaskAlternate) != 0;
                    performPlacement(NSWorkspace.sharedWorkspace.frontmostApplication,direction,arrowArrange[direction]);
                }
                arrowConsumed[direction] = YES;
                return NULL;
            }
        }
    }
    if (handleFileShortcut(type,event)) return NULL;

    CGEventFlags flags = CGEventGetFlags(event);
    if ((type == kCGEventKeyDown || type == kCGEventKeyUp) &&
        CGEventGetIntegerValueField(event,kCGKeyboardEventKeycode) == kVK_Space) {
        if (type == kCGEventKeyUp && spaceConsumed) { spaceConsumed = NO; return NULL; }
        if (type == kCGEventKeyDown && (spaceConsumed || languageChord(flags))) {
            if (!spaceConsumed && !CGEventGetIntegerValueField(event,kCGKeyboardEventAutorepeat))
                dispatch_async(dispatch_get_main_queue(), ^{ switchInputSource(); });
            spaceConsumed = YES;
            return NULL;
        }
    }
    BOOL globeTransition = type == kCGEventFlagsChanged
        && CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode) == kVK_Function;
    if (globeTransition) {
        BOOL down = (flags & kCGEventFlagMaskSecondaryFn) != 0;
        if (down ? globeMode == GlobeOff : !globeHeld) return event;
        if (down && !globeHeld) heldMode = globeMode;
        globeHeld = down;
        CGEventSetIntegerValueField(event, kCGKeyboardEventKeycode, globeMappings[heldMode].key);
    } else if (!globeHeld) {
        return event;
    }
    flags &= ~kCGEventFlagMaskSecondaryFn;
    if (globeHeld) {
        flags |= globeMappings[heldMode].flags;
    }
    CGEventSetFlags(event, flags);
    return event;
}

static CGEventTapLocation keyboardTapLocation(void) { return kCGHIDEventTap; }
static void refreshGlobeTap(BOOL allowed) {
    if (globeTap && (!allowed || (!snapEnabled && !arrangeEnabled && !desktopEnabled && !cycleEnabled && !fileCutEnabled && !languageEnabled && !globeShiftEnabled && !windowSwitchEnabled() && !localSwitcherEnabled && globeMode == GlobeOff && !globeHeld && !spaceConsumed))) {
        CFMachPortInvalidate(globeTap);
        CFRelease(globeTap);
        globeTap = NULL;
        globeHeld = NO;
    }
    if (!allowed || (!snapEnabled && !arrangeEnabled && !desktopEnabled && !cycleEnabled && !fileCutEnabled && !languageEnabled && !globeShiftEnabled && !windowSwitchEnabled() && !localSwitcherEnabled && globeMode == GlobeOff) || globeTap) return;
    // HID remapping already applies to mouse modifiers. Only keyboard events need this tap.
    CGEventType types[] = {kCGEventFlagsChanged, kCGEventKeyDown, kCGEventKeyUp};
    CGEventMask mask = 0;
    for (size_t i = 0; i < sizeof(types)/sizeof(types[0]); i++) mask |= CGEventMaskBit(types[i]);
    globeTap = CGEventTapCreate(keyboardTapLocation(), kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                                mask, globeEvent, NULL);
    if (!globeTap) return;
    CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(NULL, globeTap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
    CFRelease(source);
}

static BOOL readGeometry(AXUIElementRef win, CGRect *frame) {
    id pos = attribute(win, kAXPositionAttribute), size = attribute(win, kAXSizeAttribute);
    return pos && size && AXValueGetValue((__bridge AXValueRef)pos, kAXValueTypeCGPoint, &frame->origin)
        && AXValueGetValue((__bridge AXValueRef)size, kAXValueTypeCGSize, &frame->size);
}

static CGRect screenRect(NSRect rect, CGFloat desktopTop) {
    return CGRectMake(NSMinX(rect), desktopTop - NSMaxY(rect), NSWidth(rect), NSHeight(rect));
}

static CGRect workArea(CGRect frame) {
    NSArray<NSScreen *> *screens = NSScreen.screens;
    CGFloat top = NSMaxY(screens.firstObject.frame), bestArea = -1;
    CGRect result = CGRectZero;
    for (NSScreen *screen in screens) {
        CGRect overlap = CGRectIntersection(frame, screenRect(screen.frame, top));
        CGFloat area = CGRectIsNull(overlap) ? 0 : overlap.size.width * overlap.size.height;
        if (area > bestArea) {
            result = screenRect(screen.visibleFrame, top);
            bestArea = area;
        }
    }
    return result;
}

static BOOL similar(CGRect a, CGRect b) {
    return fabs(a.origin.x-b.origin.x)<=2 && fabs(a.origin.y-b.origin.y)<=2
        && fabs(a.size.width-b.size.width)<=2 && fabs(a.size.height-b.size.height)<=2;
}

// One geometry transaction, only for restore and pre-15 compatibility.
// Resize before moving: moving a tiled window first can trigger its implicit
// native restore and overwrite a simultaneous size change.
static BOOL writeWindowFrame(WindowRequest *request, CGRect frame) {
    AXUIElementRef win=(__bridge AXUIElementRef)request.window;
    AXValueRef size=AXValueCreate(kAXValueTypeCGSize,&frame.size);
    AXValueRef pos=AXValueCreate(kAXValueTypeCGPoint,&frame.origin);
    AXError resized=kAXErrorFailure, moved=kAXErrorFailure;
    AXUIElementSetMessagingTimeout(win,0.12);
    if (requestCurrent(request)) resized=AXUIElementSetAttributeValue(win,kAXSizeAttribute,size);
    if (requestCurrent(request)) moved=AXUIElementSetAttributeValue(win,kAXPositionAttribute,pos);
    CFRelease(size); CFRelease(pos);
    return resized==kAXErrorSuccess && moved==kAXErrorSuccess;
}

// Native tiling margins and app minimum sizes need not equal visibleFrame.
static BOOL largeWindow(CGRect frame, CGRect area) {
    CGRect overlap = CGRectIntersection(frame,area);
    return !CGRectIsNull(overlap) && overlap.size.width >= area.size.width * .9
        && overlap.size.height >= area.size.height * .9;
}
static CGRect fallbackWindowFrame(CGRect area) {
    return CGRectInset(area,round(area.size.width * .1),round(area.size.height * .1));
}
static CGRect restoredWindowFrame(CGRect before, CGRect area, NSValue *saved) {
    if (!saved) return fallbackWindowFrame(area);
    CGRect target = saved.rectValue;
    if (largeWindow(target,area)) return fallbackWindowFrame(area);
    target.origin=CGPointMake(CGRectGetMidX(area)-target.size.width/2,CGRectGetMidY(area)-target.size.height/2);
    return target;
}

// The state is intent-based. A second Restore cannot become Fill just because
// an application has not yet finished animating the first request.
static WindowIntent resolvedIntent(WindowIntent intent, WindowState *state, CGRect frame, CGRect area) {
    if (intent != WindowToggle) return intent;
    return (state && (state.intent==WindowFill || state.intent==WindowLeft || state.intent==WindowRight))
        || largeWindow(frame,area) ? WindowRestore : WindowFill;
}
static CGRect boundedFrame(CGRect frame, CGRect area) {
    frame.size.width=MIN(frame.size.width,area.size.width);
    frame.size.height=MIN(frame.size.height,area.size.height);
    frame.origin.x=MAX(CGRectGetMinX(area),MIN(frame.origin.x,CGRectGetMaxX(area)-frame.size.width));
    frame.origin.y=MAX(CGRectGetMinY(area),MIN(frame.origin.y,CGRectGetMaxY(area)-frame.size.height));
    return frame;
}
static BOOL focusedRequest(WindowRequest *request) {
    if (!requestCurrent(request) || request.app.terminated || !request.app.active) return NO;
    AXUIElementRef app=AXUIElementCreateApplication(request.app.processIdentifier);
    id focused=attribute(app,kAXFocusedWindowAttribute);
    CFRelease(app);
    return [focused isEqual:request.window] && requestCurrent(request);
}
// App Shortcuts use ordinary app key equivalents, not synthetic Fn events.
// macOS updates and executes the native menu command without showing a menu.
static NSDictionary<NSString *,NSString *> *nativeBindings(void) {
    NSString *menu=@"\033Window\033Move & Resize\033";
    return @{[menu stringByAppendingString:@"Left"]:@"@~^←",
             [menu stringByAppendingString:@"Right"]:@"@~^→",
             [menu stringByAppendingString:@"Left & Right"]:@"@~^$←",
             [menu stringByAppendingString:@"Right & Left"]:@"@~^$→",
             @"\033Window\033Fill":@"@~^↑",
             [menu stringByAppendingString:@"Return to Previous Size"]:@"@~^↓"};
}
static NSDictionary *mergedNativeBindings(NSDictionary *current, NSMutableDictionary *backup, BOOL enabled) {
    NSMutableDictionary *result=[current mutableCopy] ?: [NSMutableDictionary new];
    NSDictionary *owned=nativeBindings();
    for (NSString *key in owned) {
        if (enabled) {
            if (backup[key] && ![result[key] isEqual:owned[key]]) continue;
            if (!backup[key]) backup[key]=result[key] ?: @"";
            result[key]=owned[key];
        } else if (backup[key]) {
            // Do not overwrite a shortcut the user changed after installation.
            if ([result[key] isEqual:owned[key]]) {
                if ([backup[key] length]) result[key]=backup[key];
                else [result removeObjectForKey:key];
            }
            [backup removeObjectForKey:key];
        }
    }
    return result;
}
static void configureNativeBindings(BOOL enabled) {
    if (@available(macOS 15.0,*)) {
        NSUserDefaults *prefs=NSUserDefaults.standardUserDefaults;
        NSMutableDictionary *backup=[[prefs dictionaryForKey:@"NativeShortcutBackup"] mutableCopy] ?: [NSMutableDictionary new];
        NSDictionary *current=CFBridgingRelease(CFPreferencesCopyValue(CFSTR("NSUserKeyEquivalents"),kCFPreferencesAnyApplication,kCFPreferencesCurrentUser,kCFPreferencesAnyHost));
        if (![current isKindOfClass:NSDictionary.class]) current=@{};
        NSDictionary *updated=mergedNativeBindings(current,backup,enabled);
        if (![updated isEqual:current]) {
            // Persist recovery data before replacing any existing shortcuts.
            [prefs setObject:backup forKey:@"NativeShortcutBackup"]; [prefs synchronize];
            CFPreferencesSetValue(CFSTR("NSUserKeyEquivalents"),(__bridge CFDictionaryRef)updated,kCFPreferencesAnyApplication,kCFPreferencesCurrentUser,kCFPreferencesAnyHost);
            CFPreferencesSynchronize(kCFPreferencesAnyApplication,kCFPreferencesCurrentUser,kCFPreferencesAnyHost);
        }
        [prefs setObject:backup forKey:@"NativeShortcutBackup"];
    }
}
static id nativeWindowCommand(WindowRequest *request, NSInteger direction) {
    id app=CFBridgingRelease(AXUIElementCreateApplication(request.app.processIdentifier));
    id bar=placementAttribute(app,kAXMenuBarAttribute);
    NSArray *headings=placementAttribute(bar,kAXChildrenAttribute);
    for (id heading in headings.reverseObjectEnumerator) {
        if (!requestCurrent(request)) return nil;
        id menu=[placementAttribute(heading,kAXChildrenAttribute) firstObject];
        NSArray *items=placementAttribute(menu,kAXChildrenAttribute);
        for (id item in items) {
            if (!requestCurrent(request)) return nil;
            id submenu=[placementAttribute(item,kAXChildrenAttribute) firstObject];
            NSArray *children=placementAttribute(submenu,kAXChildrenAttribute);
            if (!children.count || !placementFind(children,0,YES) || !placementFind(children,1,YES)) continue;
            return direction==2 ? placementFind(items,2,NO) : placementFind(children,direction,request.pair);
        }
    }
    return nil;
}
static CGEventRef copyPlacementEvent(NSInteger direction, BOOL pair, BOOL down) {
    CGKeyCode keys[]={kVK_LeftArrow,kVK_RightArrow,kVK_UpArrow,kVK_DownArrow};
    CGEventRef event=CGEventCreateKeyboardEvent(NULL,keys[direction],down);
    if (event) {
        CGEventFlags flags=kCGEventFlagMaskCommand|kCGEventFlagMaskControl|kCGEventFlagMaskAlternate|kCGEventFlagMaskNumericPad;
        if (pair && direction<2) flags|=kCGEventFlagMaskShift;
        CGEventSetFlags(event,flags);
        CGEventSetIntegerValueField(event,kCGEventSourceUserData,nativeMoveTag);
    }
    return event;
}
static BOOL pressNativeCommand(WindowRequest *request, NSInteger direction) {
    id command=nativeWindowCommand(request,direction);
    NSInteger expected=kAXMenuItemModifierControl|kAXMenuItemModifierOption;
    if (request.pair && direction<2) expected|=kAXMenuItemModifierShift;
    NSNumber *modifiers=placementAttribute(command,kAXMenuItemCmdModifiersAttribute);
    // A running app may still have the old Fn shortcut cached. Never send an
    // unrelated key chord or open its menu as a hidden fallback.
    CGKeyCode keys[]={kVK_LeftArrow,kVK_RightArrow,kVK_UpArrow,kVK_DownArrow};
    NSArray *characters=@[@"←",@"→",@"↑",@"↓"];
    NSString *character=placementAttribute(command,kAXMenuItemCmdCharAttribute);
    NSNumber *key=placementAttribute(command,kAXMenuItemCmdVirtualKeyAttribute);
    BOOL matchedKey=[character isEqual:characters[direction]] || (key && key.integerValue==keys[direction]);
    if (!command || !modifiers || modifiers.integerValue!=expected || !matchedKey) {
        windowDiagnostic([NSString stringWithFormat:@"app=%@ native-shortcut-not-loaded: reopen-app",request.app.bundleIdentifier]);
        return NO;
    }
    if (![placementAttribute(command,kAXEnabledAttribute) boolValue] || !focusedRequest(request)) return NO;
    CGEventRef down=copyPlacementEvent(direction,request.pair,YES), up=copyPlacementEvent(direction,request.pair,NO);
    BOOL ready=down && up;
    if (ready) {
        CGEventPostToPid(request.app.processIdentifier,down);
        CGEventPostToPid(request.app.processIdentifier,up);
    }
    if (down) CFRelease(down); if (up) CFRelease(up);
    return ready;
}
static CGPoint centeredOrigin(CGSize size, CGRect area) {
    return CGPointMake(MAX(CGRectGetMinX(area),CGRectGetMidX(area)-size.width/2),
                       MAX(CGRectGetMinY(area),CGRectGetMidY(area)-size.height/2));
}
static BOOL frameInside(CGRect frame, CGRect area) {
    return CGRectContainsRect(CGRectInset(area,-2,-2),frame);
}
static void observeWindowResult(WindowRequest *request, WindowState *state) {
    // Read-only observation. No sleeps, repeated setters, or delayed corrective
    // moves. A future request/manual drag can never be overwritten by this.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,350*NSEC_PER_MSEC),windowActionQueue(), ^{
        if ([windowStates objectForKey:request.window]!=state || state.generation!=request.generation) return;
        CGRect frame;
        if (readGeometry((__bridge AXUIElementRef)request.window,&frame)) {
            state.observed=frame; state.hasObserved=YES;
            __block CGRect area;
            dispatch_sync(dispatch_get_main_queue(), ^{ area=workArea(frame); });
            state.confirmed=state.intent==WindowFill ? largeWindow(frame,area) :
                state.intent==WindowRestore ? frameInside(frame,area) && !largeWindow(frame,area) :
                frameInside(frame,area) && frame.size.width<=area.size.width*.5+2;
            windowDiagnostic([NSString stringWithFormat:@"app=%@ intent=%ld confirmed=%d observed=%@ area=%@",request.app.bundleIdentifier,(long)state.intent,state.confirmed,NSStringFromRect(frame),NSStringFromRect(area)]);
        }
    });
}
// Observe completion without blocking the worker or resending setters. A
// bounded, cancellable observer is shared by both restore phases; geometry
// must be stable across samples. Failed/unresponsive windows stay unconfirmed.
static void settleWindow(WindowRequest *request, CGRect initial, CGRect previous, NSInteger stable,
                         NSInteger remaining, void (^completion)(CGRect)) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,60*NSEC_PER_MSEC),windowActionQueue(), ^{
        if (!requestCurrent(request)) return;
        CGRect actual;
        if (!readGeometry((__bridge AXUIElementRef)request.window,&actual)) return;
        NSInteger count=similar(actual,previous) ? stable+1 : 0;
        if ((count>=2 && !similar(actual,initial)) || remaining==0) completion(actual);
        else settleWindow(request,initial,actual,count,remaining-1,completion);
    });
}
// Restore has three explicit phases: untile -> resize -> center actual size.
// Only the first two phases can change size; position is calculated afterwards.
static void restoreWindow(WindowRequest *request, WindowState *state, CGRect area, CGRect desired) {
    AXUIElementRef win=(__bridge AXUIElementRef)request.window;
    CGRect initial;
    if (!readGeometry(win,&initial)) return;
    void (^resize)(CGRect)=^(CGRect beforeResize) {
        if (!focusedRequest(request)) return;
        CGSize size=desired.size;
        if (fabs(size.width-beforeResize.size.width)<=2 && fabs(size.height-beforeResize.size.height)<=2) {
            CGPoint origin=centeredOrigin(beforeResize.size,area);
            AXValueRef position=AXValueCreate(kAXValueTypeCGPoint,&origin);
            AXUIElementSetAttributeValue(win,kAXPositionAttribute,position); CFRelease(position);
            observeWindowResult(request,state); return;
        }
        AXValueRef value=AXValueCreate(kAXValueTypeCGSize,&size);
        AXUIElementSetMessagingTimeout(win,0.15);
        AXError error=AXUIElementSetAttributeValue(win,kAXSizeAttribute,value);
        CFRelease(value);
        if (error!=kAXErrorSuccess) {
            windowDiagnostic([NSString stringWithFormat:@"app=%@ restore-size-error=%d",request.app.bundleIdentifier,error]);
            return;
        }
        settleWindow(request,beforeResize,beforeResize,0,9,^(CGRect actual) {
            if (!focusedRequest(request)) return;
            CGPoint origin=centeredOrigin(actual.size,area);
            AXValueRef position=AXValueCreate(kAXValueTypeCGPoint,&origin);
            AXUIElementSetMessagingTimeout(win,0.15);
            AXError moved=AXUIElementSetAttributeValue(win,kAXPositionAttribute,position);
            CFRelease(position);
            if (moved==kAXErrorSuccess) observeWindowResult(request,state);
        });
    };
    BOOL untiled=NO;
    if (@available(macOS 15.0,*)) untiled=pressNativeCommand(request,3);
    if (untiled) settleWindow(request,initial,initial,0,9,resize);
    else resize(initial);
}
static void executeWindowRequest(WindowRequest *request) {
    if (!requestCurrent(request) || request.app.terminated) return;
    AXUIElementRef win=(__bridge AXUIElementRef)request.window;
    if ([attribute(win,CFSTR("AXFullScreen")) boolValue] || [attribute(win,kAXMinimizedAttribute) boolValue]) return;
    if (request.intent==WindowMove) {
        [windowStates removeObjectForKey:request.window];
        CGPoint origin=request.origin;
        AXValueRef pos=AXValueCreate(kAXValueTypeCGPoint,&origin);
        AXUIElementSetMessagingTimeout(win,0.08);
        if (requestCurrent(request)) AXUIElementSetAttributeValue(win,kAXPositionAttribute,pos);
        CFRelease(pos);
        return;
    }
    if (!focusedRequest(request)) return;
    CGRect before;
    if (!readGeometry(win,&before)) return;
    __block CGRect area;
    dispatch_sync(dispatch_get_main_queue(), ^{ area=workArea(before); });
    if (CGRectIsEmpty(area) || !requestCurrent(request)) return;
    WindowState *state=[windowStates objectForKey:request.window];
    if (state.hasObserved && !similar(before,state.observed)) {
        // A manual change starts a new placement session and a new baseline.
        [windowStates removeObjectForKey:request.window]; state=nil;
    }
    WindowIntent intent=resolvedIntent(request.intent,state,before,area);
    if (intent==WindowRestore && state.intent==WindowRestore && state.confirmed) return;
    if (intent==WindowFill && largeWindow(before,area)) return;
    WindowState *next=[WindowState new];
    next.baseline=state.hasBaseline ? state.baseline : before;
    next.hasBaseline=YES; next.intent=intent; next.generation=request.generation;
    BOOL applied=NO;
    if (intent==WindowRestore) {
        CGRect desired=restoredWindowFrame(before,area,[NSValue valueWithRect:next.baseline]);
        [windowStates setObject:next forKey:request.window];
        restoreWindow(request,next,area,boundedFrame(desired,area));
        return;
    } else {
        if (@available(macOS 15.0,*)) {
            applied=pressNativeCommand(request,intent);
        } else if (intent==WindowFill) applied=writeWindowFrame(request,area);
    }
    if (applied) {
        if (windowStates.count>=128 && ![windowStates objectForKey:request.window]) [windowStates removeAllObjects];
        [windowStates setObject:next forKey:request.window];
        observeWindowResult(request,next);
    }
    windowDiagnostic([NSString stringWithFormat:@"app=%@ intent=%ld pair=%d accepted=%d before=%@",request.app.bundleIdentifier,(long)intent,request.pair,applied,NSStringFromRect(before)]);
}
static void sizeWindow(id window, NSInteger mode) {
    pid_t pid=0; AXUIElementGetPid((__bridge AXUIElementRef)window,&pid);
    NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    requestWindow(window,app,mode==0 ? WindowToggle : mode==1 ? WindowFill : WindowRestore,NO,CGPointZero);
}
static void toggleWindow(id window) { sizeWindow(window,0); }

static BOOL onlyWindow(NSArray *windows, id clicked) {
    return clicked && windows.count == 1 && [windows.firstObject isEqual:clicked];
}

static BOOL isLast(pid_t pid, id window) {
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    AXUIElementSetMessagingTimeout(app, 0.08);
    NSArray *windows = attribute(app, kAXWindowsAttribute);
    CFRelease(app);
    return [windows isKindOfClass:NSArray.class] && onlyWindow(windows, window);
}

// Agent applications can temporarily promote themselves to regular applications
// while showing a window. The current activation policy alone loses that intent.
static BOOL declaredBackgroundApp(NSDictionary *info) {
    return [info[@"LSUIElement"] boolValue] || [info[@"LSBackgroundOnly"] boolValue];
}

static BOOL backgroundEvidence(BOOL declaredAgent, BOOL hasStatusItem) {
    return declaredAgent || hasStatusItem;
}

static BOOL keepRunningAfterRed(NSRunningApplication *app) {
    if (!backgroundEnabled) return NO;
    NSDictionary *info = app.bundleURL ? [NSBundle bundleWithURL:app.bundleURL].infoDictionary : nil;
    if (declaredBackgroundApp(info)) return YES;
    // Query only this process's *extras* bar, never the normal application menu.
    // No app-name list, title matching, recursive AX crawl or cross-process guess.
    AXUIElementRef axApp = AXUIElementCreateApplication(app.processIdentifier);
    id extras = attribute(axApp, kAXExtrasMenuBarAttribute);
    CFRelease(axApp);
    if (!extras || CFGetTypeID((__bridge CFTypeRef)extras) != AXUIElementGetTypeID()) return NO;
    NSArray *items = attribute((__bridge AXUIElementRef)extras, kAXChildrenAttribute);
    return backgroundEvidence(NO, [items isKindOfClass:NSArray.class] && items.count > 0);
}

static void yieldAfterBackgroundClose(NSRunningApplication *app, NSUInteger attempts) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
        if (app.terminated || !app.active || !backgroundEnabled) return;
        AXUIElementRef axApp = AXUIElementCreateApplication(app.processIdentifier);
        NSArray *windows = attribute(axApp, kAXWindowsAttribute);
        CFRelease(axApp);
        // A failed read is not an empty window list. Never hide save dialogs,
        // sheets, minimized windows, or another window opened during the close.
        if (![windows isKindOfClass:NSArray.class]) return;
        if (windows.count == 0) [app hide];
        else if (attempts > 1) yieldAfterBackgroundClose(app, attempts-1);
    });
}

static BOOL beginDrag(AXUIElementRef hit, CGPoint point) {
    id obj = [attribute(hit, kAXRoleAttribute) isEqual:@"AXWindow"] ?
        (__bridge id)hit : attribute(hit, kAXWindowAttribute);
    if (!obj) return NO;
    AXUIElementRef win = (__bridge AXUIElementRef)obj;
    AXUIElementSetMessagingTimeout(win, 0.08);
    Boolean movable = false;
    AXUIElementIsAttributeSettable(win, kAXPositionAttribute, &movable);
    if (!movable || [attribute(win, CFSTR("AXFullScreen")) boolValue]) return NO;
    id pos = attribute(win, kAXPositionAttribute);
    if (!pos || !AXValueGetValue((__bridge AXValueRef)pos, kAXValueTypeCGPoint, &initialOrigin)) return NO;
    dragStart = point;
    dragWindow = obj;
    return YES;
}

static CGPoint dragOrigin(CGPoint origin, CGPoint start, CGPoint now) {
    return CGPointMake(origin.x + now.x - start.x, origin.y + now.y - start.y);
}

static BOOL dragChord(CGEventFlags flags) {
    CGEventFlags modifiers = kCGEventFlagMaskControl | kCGEventFlagMaskAlternate;
    return (flags & (modifiers | kCGEventFlagMaskShift | kCGEventFlagMaskCommand)) == modifiers;
}

static BOOL isGreenButton(NSString *role) {
    return [role isEqual:(__bridge NSString *)kAXFullScreenButtonSubrole]
        || [role isEqual:(__bridge NSString *)kAXZoomButtonSubrole];
}

static id containingWindow(AXUIElementRef hit) {
    id window = attribute(hit, kAXWindowAttribute);
    if (window) return window;
    id node = (__bridge id)hit;
    for (NSUInteger depth = 0; node && depth < 5; depth++) {
        AXUIElementRef element = (__bridge AXUIElementRef)node;
        if ([attribute(element, kAXRoleAttribute) isEqual:@"AXWindow"]) return node;
        node = attribute(element, kAXParentAttribute);
    }
    return nil;
}

// Some title bars return a container from hit testing. Use the window's
// published button and its real screen bounds, never a guessed pixel offset.
static id greenControl(AXUIElementRef hit, NSString *subrole, id window, CGPoint point) {
    if (isGreenButton(subrole)) return (__bridge id)hit;
    if (!window) return nil;
    AXUIElementRef win = (__bridge AXUIElementRef)window;
    const CFStringRef keys[] = {kAXFullScreenButtonAttribute, kAXZoomButtonAttribute};
    for (NSUInteger i = 0; i < 2; i++) {
        id button = attribute(win, keys[i]);
        if (!button) continue;
        CGRect frame;
        if ([button isEqual:(__bridge id)hit] ||
            (readGeometry((__bridge AXUIElementRef)button, &frame) && CGRectContainsPoint(frame, point)))
            return button;
    }
    return nil;
}

// Resolve the pointed window before mouse-down, while the app is free to answer AX queries.
@interface GreenTarget : NSObject
@property(strong) id window, button;
@property CGRect bounds;
@property pid_t pid;
@property double time;
@end
@implementation GreenTarget
@end
static GreenTarget *hoverTarget;
static BOOL cachedPress;
static CGRect pressedBounds;
static double hoverSince;
static BOOL dwelledAtPress;
// Probe inside the panel, since hit-testing the green button returns its window.
static id tilingPanelAt(CGPoint point, pid_t appPID) {
    AXUIElementRef hit = copyHit(point);
    if (!hit) return nil;
    id node = CFBridgingRelease(hit);
    pid_t owner = 0;
    AXUIElementGetPid((__bridge AXUIElementRef)node,&owner);
    NSString *bundle = [NSRunningApplication runningApplicationWithProcessIdentifier:owner].bundleIdentifier;
    BOOL manager = [bundle isEqual:@"com.apple.WindowManager"] || [bundle isEqual:@"com.apple.dock"];
    if (!manager && owner != appPID) return nil;
    for (NSUInteger depth=0; node && depth<10; depth++) {
        AXUIElementRef element = (__bridge AXUIElementRef)node;
        NSString *role = attribute(element,kAXRoleAttribute);
        if ([role isEqual:@"AXPopover"] || [role isEqual:@"AXMenu"] || (manager && [role isEqual:@"AXWindow"])) return node;
        if ([role isEqual:@"AXWindow"] || [role isEqual:@"AXApplication"]) break;
        node = attribute(element,kAXParentAttribute);
    }
    return nil;
}

static void postEscape(pid_t recipient) {
    CGEventRef down = CGEventCreateKeyboardEvent(NULL,kVK_Escape,true);
    CGEventRef up = CGEventCreateKeyboardEvent(NULL,kVK_Escape,false);
    if (down && up) {
        CGEventSetFlags(down,0); CGEventSetFlags(up,0);
        if (recipient > 0) {
            CGEventPostToPid(recipient,down); CGEventPostToPid(recipient,up);
        } else {
            CGEventPost(kCGHIDEventTap,down); CGEventPost(kCGHIDEventTap,up);
        }
    }
    if (down) CFRelease(down);
    if (up) CFRelease(up);
}

static void dismissTilingPanel(CGPoint click, NSRunningApplication *app, BOOL dwelled) {
    CGPoint below = CGPointMake(click.x,click.y+35);
    id panel = tilingPanelAt(below,app.processIdentifier);
    if (!panel && dwelled) panel = tilingPanelAt(CGPointMake(click.x,click.y-35),app.processIdentifier);
    if (!panel && (!dwelled || !app.active)) return;
    if (panel) {
        AXUIElementRef element = (__bridge AXUIElementRef)panel;
        if (AXUIElementPerformAction(element,kAXCancelAction)==kAXErrorSuccess) {
            return;
        }
        pid_t owner = 0;
        AXUIElementGetPid(element,&owner);
        postEscape(owner);
    } else {
        postEscape(0);
    }
}

static void sampleGreen(void) {
    static BOOL busy, sampled;
    static CGPoint lastPoint;
    static pid_t lastApp;
    if (busy || !greenEnabled || !tap) return;
    CGEventRef cursor=CGEventCreate(NULL);
    CGPoint point=cursor ? CGEventGetLocation(cursor) : CGPointZero;
    if (cursor) CFRelease(cursor);
    pid_t app=NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    if (sampled && CGPointEqualToPoint(point,lastPoint) && app==lastApp) return;
    sampled=YES; lastPoint=point; lastApp=app;
    busy = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            GreenTarget *found = nil;
            CGEventRef sample = CGEventCreate(NULL);
            CGPoint point = sample ? CGEventGetLocation(sample) : CGPointZero;
            AXUIElementRef hit = sample ? copyHit(point) : NULL;
            if (sample) CFRelease(sample);
            if (hit) {
                AXUIElementSetMessagingTimeout(hit, 0.08);
                id window = containingWindow(hit);
                if (!window) {
                    pid_t owner = 0;
                    if (AXUIElementGetPid(hit,&owner) == kAXErrorSuccess && owner > 0) {
                        AXUIElementRef app = AXUIElementCreateApplication(owner);
                        AXUIElementSetMessagingTimeout(app, 0.08);
                        window = attribute(app,kAXFocusedWindowAttribute);
                        CFRelease(app);
                    }
                }
                id button = greenControl(hit, attribute(hit,kAXSubroleAttribute), window, point);
                CGRect bounds;
                if (button && window && readGeometry((__bridge AXUIElementRef)button,&bounds)
                    && CGRectContainsPoint(bounds,point) && ![attribute((__bridge AXUIElementRef)window, CFSTR("AXFullScreen")) boolValue]
                    && ![attribute((__bridge AXUIElementRef)button,kAXEnabledAttribute) isEqual:@NO]) {
                    pid_t pid = 0; AXUIElementGetPid(hit,&pid);
                    found = [GreenTarget new]; found.button = button; found.window = window;
                    found.bounds = bounds; found.pid = pid; found.time = NSProcessInfo.processInfo.systemUptime;
                }
                CFRelease(hit);
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!found || ![hoverTarget.button isEqual:found.button]) hoverSince = found ? found.time : 0;
                hoverTarget = found; busy = NO;
            });
        }
    });
}

static CGEventRef mouseEvent(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *context) {
    @autoreleasepool {
        if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
            resetClick();
            pauseInput();
            return event;
        }
        if (dragWindow && type != kCGEventLeftMouseDown) {
            CGPoint origin = dragOrigin(initialOrigin, dragStart, CGEventGetLocation(event));
            pid_t pid=0; AXUIElementGetPid((__bridge AXUIElementRef)dragWindow,&pid);
            requestWindow(dragWindow,[NSRunningApplication runningApplicationWithProcessIdentifier:pid],WindowMove,NO,origin);
            if (type == kCGEventLeftMouseUp) resetClick();
            return NULL;
        }
        if (!pressed && !redEnabled && !greenEnabled && !optionEnabled && !dragEnabled) return event;
        if (type == kCGEventLeftMouseDown) {
            cancelWindowRequests();
            resetClick();
            cachedPress = NO;
            dwelledAtPress = CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateCombinedSessionState,kCGEventMouseMoved) >= 0.65;
            CGPoint point = CGEventGetLocation(event);
            CGEventFlags mods = CGEventGetFlags(event);
            pid_t dest = (pid_t)CGEventGetIntegerValueField(event,kCGEventTargetUnixProcessID);
            GreenTarget *hover = hoverTarget;
            if (greenEnabled && hover && !((optionEnabled && (mods & kCGEventFlagMaskAlternate)) || (dragEnabled && dragChord(mods)))
                && NSProcessInfo.processInfo.systemUptime-hover.time < 0.4 && CGRectContainsPoint(hover.bounds,point)
                && (dest > 0 ? dest == hover.pid : NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier == hover.pid)) {
                pressed = (AXUIElementRef)CFRetain((__bridge CFTypeRef)hover.button);
                clickedWindow = hover.window; fillPress = YES; cachedPress = YES; pressedBounds = hover.bounds;
                target = [NSRunningApplication runningApplicationWithProcessIdentifier:hover.pid];
                return NULL;
            }
            AXUIElementRef hit = copyHit(CGEventGetLocation(event));
            if (!hit) return event;
            AXUIElementSetMessagingTimeout(hit, 0.08);
            CGEventFlags flags = CGEventGetFlags(event);
            if (dragEnabled && dragChord(flags) && beginDrag(hit, CGEventGetLocation(event))) {
                CFRelease(hit);
                return NULL;
            }
            NSString *role = attribute(hit, kAXSubroleAttribute);
            BOOL red = redEnabled && [role isEqual:(__bridge NSString *)kAXCloseButtonSubrole];
            BOOL minimize = [role isEqual:(__bridge NSString *)kAXMinimizeButtonSubrole];
            id window = nil, greenButton = nil;
            if (greenEnabled && !minimize && ![role isEqual:(__bridge NSString *)kAXCloseButtonSubrole]) {
                window = containingWindow(hit);
                greenButton = greenControl(hit, role, window, CGEventGetLocation(event));
                if (greenButton && !window) window = containingWindow((__bridge AXUIElementRef)greenButton);
            }
            AXUIElementRef control = greenButton ? (__bridge AXUIElementRef)greenButton : hit;
            BOOL green = greenButton && window && ![attribute((__bridge AXUIElementRef)window, CFSTR("AXFullScreen")) boolValue];
            BOOL optionClick = optionEnabled && (flags & kCGEventFlagMaskAlternate)
                && !(flags & (kCGEventFlagMaskControl | kCGEventFlagMaskCommand | kCGEventFlagMaskShift));
            BOOL optionYellow = optionClick && [role isEqual:(__bridge NSString *)kAXMinimizeButtonSubrole];
            if ((red || green || optionYellow) && ![attribute(control, kAXEnabledAttribute) isEqual:@NO]) {
                pid_t pid = 0;
                AXUIElementGetPid(hit, &pid);
                NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
                if (app && (green || app.activationPolicy == NSApplicationActivationPolicyRegular)) {
                    singleButtonPress = optionClick;
                    fillPress = green && !optionClick;
                    clickedWindow = green ? window : attribute(hit, kAXWindowAttribute);
                    BOOL quit = red && ![app.bundleIdentifier isEqual:@"com.apple.finder"]
                        && (!lastEnabled || isLast(pid, clickedWindow));
                    if (singleButtonPress || (fillPress && clickedWindow) || quit) {
                        pressed = (AXUIElementRef)CFRetain(control);
                        CFRelease(hit);
                        target = app;
                        return NULL;
                    }
                }
            }
            CFRelease(hit);
        } else if (pressed) {
            if (type == kCGEventLeftMouseUp) {
                AXUIElementRef released = cachedPress ? NULL : copyHit(CGEventGetLocation(event));
                BOOL matched = cachedPress ? CGRectContainsPoint(pressedBounds, CGEventGetLocation(event)) : released && CFEqual(pressed, released);
                if (!matched && released && clickedWindow && (fillPress || singleButtonPress)) {
                    id releaseWindow = containingWindow(released);
                    if ([clickedWindow isEqual:releaseWindow]) {
                        id releaseControl = greenControl(released, attribute(released, kAXSubroleAttribute), releaseWindow, CGEventGetLocation(event));
                        matched = [releaseControl isEqual:(__bridge id)pressed];
                    }
                }
                if (released) CFRelease(released);
                NSRunningApplication *app = target;
                id window = clickedWindow;
                id button = (__bridge id)pressed;
                BOOL plain = singleButtonPress;
                BOOL fill = fillPress;
                CGPoint click = CGEventGetLocation(event);
                BOOL longHover = fill && (dwelledAtPress || (hoverSince && [hoverTarget.button isEqual:button]
                    && NSProcessInfo.processInfo.systemUptime-hoverSince >= 0.32));
                resetClick();
                if (matched) dispatch_async(dispatch_get_main_queue(), ^{
                    if (app.terminated) return;
                    if (plain || (!fill && lastEnabled && !isLast(app.processIdentifier, window))) {
                        if (AXUIElementPerformAction((__bridge AXUIElementRef)button, kAXPressAction) != kAXErrorSuccess) NSBeep();
                    } else if (fill) {
                        dismissTilingPanel(click,app,longHover);
                        toggleWindow(window);
                    }
                    else if (keepRunningAfterRed(app)) {
                        if (AXUIElementPerformAction((__bridge AXUIElementRef)button, kAXPressAction) == kAXErrorSuccess)
                            yieldAfterBackgroundClose(app, 4);
                        else NSBeep();
                    }
                    else if (![app terminate]) NSBeep();
                });
            }
            return NULL;
        }
        return event;
    }
}

static NSString *const hideIconKey = @"HideMenuBarIcon";

typedef NS_ENUM(NSInteger, SwitcherScope) {
    SwitcherSystem, SwitcherThisDesktop, SwitcherAllDesktops
};

static NSMenu *settingsSection(NSMenu *root, NSString *title) {
    NSMenuItem *row = [root addItemWithTitle:title action:nil keyEquivalent:@""];
    NSMenu *section = [[NSMenu alloc] initWithTitle:title];
    section.autoenablesItems = NO;
    row.submenu = section;
    return section;
}

static NSMenuItem *menuCaption(NSMenu *menu, NSString *title) {
    NSMenuItem *caption = [menu addItemWithTitle:title action:nil keyEquivalent:@""];
    caption.enabled = NO;
    return caption;
}

@interface Macdows : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property(strong) NSStatusItem *item;
@property(strong) NSMenuItem *status, *loginItem, *loginSettings;
@property(strong) NSMenuItem *redLast, *redBackground, *switcherFinder, *previewAccess;
@property(strong) NSArray<NSMenuItem *> *scopeChoices, *displayChoices, *globeChoices;
@property(strong) NSMenuItem *shiftShortcut, *spaceShortcut;
@property(copy) NSString *loginError, *statusText;
@property(assign) BOOL previewAccessRequested, previewAccessWasAllowed, menuTracking;
@end

@implementation Macdows
- (void)applicationWillTerminate:(NSNotification *)note {
    pauseInput();
    if (inputWatchdog) dispatch_source_cancel(inputWatchdog);
    syncKeyboards(GlobeOff);
}
- (void)appActivated:(NSNotification *)note {
    NSUInteger generation = ++switchGeneration;
    NSRunningApplication *front = note.userInfo[NSWorkspaceApplicationKey];
    if (front.activationPolicy == NSApplicationActivationPolicyRegular) {
        if (!localSwitcherMRU) localSwitcherMRU = [NSMutableArray array];
        NSNumber *pid = @(front.processIdentifier);
        [localSwitcherMRU removeObject:pid];
        [localSwitcherMRU insertObject:pid atIndex:0];
        if (localSwitcherMRU.count > 40) [localSwitcherMRU removeLastObject];
    }
    if (front.activationPolicy != NSApplicationActivationPolicyRegular || (!restoreEnabled && !scopeIncludesApp(front.bundleIdentifier))) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
        reopenEmptyApp(front,generation,3);
    });
}
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    self.item = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
    NSImage *menuImage = [NSImage imageWithSize:NSMakeSize(18,18) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        [NSColor.labelColor setStroke];
        NSBezierPath *frame = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(1.5,2.5,15,13) xRadius:2 yRadius:2];
        frame.lineWidth = 1.5;
        [frame stroke];
        NSBezierPath *line = [NSBezierPath bezierPath];
        [line moveToPoint:NSMakePoint(2,11)];
        [line lineToPoint:NSMakePoint(16,11)];
        line.lineWidth = 1.5;
        [line stroke];
        [NSColor.labelColor setFill];
        for (NSInteger i=0; i<3; i++)
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(4+i*4,12.5,1.5,1.5)] fill];
        return YES;
    }];
    menuImage.template = YES;
    self.item.button.image = menuImage;
    self.item.button.toolTip = @"Macdows";
    windowStates = [NSMapTable strongToStrongObjectsMapTable];
    NSUserDefaults *prefs = NSUserDefaults.standardUserDefaults;
    // Migrate the old default and enabled mapping to Option. Respect an explicit opt-out.
    if (![prefs objectForKey:globeModeKey]) {
        NSNumber *old = [prefs objectForKey:@"GlobeActsAsCommand"];
        [prefs setInteger:(old && !old.boolValue ? GlobeOff : GlobeOption) forKey:globeModeKey];
    }
    if (![prefs objectForKey:greenKey] && [prefs objectForKey:@"YellowFillsWindow"])
        [prefs setBool:[prefs boolForKey:@"YellowFillsWindow"] forKey:greenKey];
    // Build 65 renamed this preference. Preserve the explicit choice from
    // earlier public builds instead of silently replacing it with a default.
    migrateLocalSwitcherPreviewPreference(prefs);
    [prefs registerDefaults:@{ snapKey:@YES, arrangeKey:@YES, desktopKey:@YES, cycleKey:@YES, backgroundKey:@YES, redKey:@YES, greenKey:@YES, optionClickKey:@YES, lastKey:@YES, dragKey:@NO, globeShiftKey:@YES, languageKey:@YES, restoreKey:@YES, finderKey:@YES, otherAppsKey:@NO, fileCutKey:@YES, localSwitcherKey:@NO, localSwitcherCurrentOnlyKey:@YES, localSwitcherHideFinderKey:@YES, localSwitcherPreviewsKey:@YES, localSwitcherEveryWindowKey:@YES }];
    [self loadPreferences];
    if (@available(macOS 13.0, *)) {
        NSString *setupKey = @"DidConfigureLaunchAtLogin";
        if (![prefs boolForKey:setupKey]) {
            SMAppService *service = SMAppService.mainAppService;
            if (service.status == SMAppServiceStatusNotRegistered) {
                NSError *error = nil;
                if (![service registerAndReturnError:&error]) self.loginError = error.localizedDescription;
            }
            if (service.status == SMAppServiceStatusEnabled || service.status == SMAppServiceStatusRequiresApproval)
                [prefs setBool:YES forKey:setupKey];
        }
    }
    self.item.menu = [self buildStatusMenu];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(appActivated:) name:NSWorkspaceDidActivateApplicationNotification object:nil];
    // Keep settings reachable even when a previous session hid the icon.
    [prefs setBool:NO forKey:hideIconKey];
    self.item.visible = YES;
    [NSTimer scheduledTimerWithTimeInterval:0.13 repeats:YES block:^(NSTimer *timer){ sampleGreen(); }];
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge NSString *)kAXTrustedCheckOptionPrompt:@YES});
    self.previewAccessWasAllowed = CGPreflightScreenCaptureAccess();
    [self refresh];
    [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *timer){ [self refresh]; }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,500*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
        [self ensurePreviewAccessIfNeeded:YES];
    });
    startInputWatchdog();
}
- (NSArray<NSMenuItem *> *)choicesIn:(NSMenu *)menu titles:(NSArray<NSString *> *)titles action:(SEL)action {
    NSMutableArray *rows = [NSMutableArray array];
    for (NSString *title in titles) {
        NSMenuItem *row = [menu addItemWithTitle:title action:action keyEquivalent:@""];
        row.target = self;
        row.tag = rows.count;
        [rows addObject:row];
    }
    return rows;
}
- (NSMenu *)buildStatusMenu {
    NSMenu *root = [NSMenu new];
    root.autoenablesItems = NO;
    root.delegate = self;
    self.status = menuCaption(root,@"Macdows");
    [root addItem:NSMenuItem.separatorItem];
    NSMenuItem *(^toggle)(NSMenu *, NSString *, NSString *) = ^NSMenuItem *(NSMenu *section, NSString *key, NSString *label) {
        NSMenuItem *row = [section addItemWithTitle:label action:@selector(toggle:) keyEquivalent:@""];
        row.representedObject = key;
        row.target = self;
        row.state = [NSUserDefaults.standardUserDefaults boolForKey:key] ? NSControlStateValueOn : NSControlStateValueOff;
        return row;
    };

    NSMenu *switcher = settingsSection(root,@"⌘Tab Switcher");
    menuCaption(switcher,@"Switch with ⌘Tab");
    self.scopeChoices = [self choicesIn:switcher titles:@[@"macOS · All Apps", @"Macdows · This Desktop", @"Macdows · All Desktops"] action:@selector(selectScope:)];
    [switcher addItem:NSMenuItem.separatorItem];
    menuCaption(switcher,@"Macdows appearance");
    self.displayChoices = [self choicesIn:switcher titles:@[@"App Icons", @"One Preview per App", @"One Preview per Window"] action:@selector(selectSwitcherDisplay:)];
    self.previewAccess = [switcher addItemWithTitle:@"Allow Screen Recording for Previews…" action:@selector(openPreviewAccess:) keyEquivalent:@""];
    self.previewAccess.target = self;
    self.previewAccess.indentationLevel = 1;
    [switcher addItem:NSMenuItem.separatorItem];
    menuCaption(switcher,@"Macdows filters");
    self.switcherFinder = toggle(switcher,localSwitcherHideFinderKey,@"Hide Finder Without Windows");

    NSMenu *windows = settingsSection(root,@"Windows & Desktops");
    menuCaption(windows,@"Switch");
    toggle(windows,cycleKey,@"Cycle App Windows  ·  ⌘`").toolTip = @"Uses the physical key above Tab in any keyboard layout. Add Shift to cycle backwards.";
    toggle(windows,desktopKey,@"Switch Desktops  ·  ⌃⇧⌥←/→").toolTip = @"Release the shortcut to switch. Requires Automation access to System Events.";
    [windows addItem:NSMenuItem.separatorItem];
    menuCaption(windows,@"Move & resize");
    NSMenuItem *snap = toggle(windows,snapKey,@"Tile Left or Right  ·  ⌃←/→");
    snap.toolTip = @"Uses the standard desktop-switching keys for tiling. Requires macOS 15 or later.";
    NSMenuItem *arrange = toggle(windows,arrangeKey,@"Arrange, Fill or Restore  ·  ⌃⌥Arrows");
    arrange.toolTip = @"Left/right arranges two windows. Up fills the window. Down restores it. Requires macOS 15 or later.";
    if (@available(macOS 15.0, *)) {} else {
        snap.enabled = arrange.enabled = NO;
        snap.state = arrange.state = NSControlStateValueOff;
    }
    toggle(windows,dragKey,@"Move by Dragging Anywhere  ·  ⌃⌥Drag");

    NSMenu *buttons = settingsSection(root,@"Window Buttons");
    toggle(buttons,redKey,@"Red Button Quits the App");
    self.redLast = toggle(buttons,lastKey,@"Only When Closing the Last Window");
    self.redBackground = toggle(buttons,backgroundKey,@"Keep Menu-Bar and Background Apps Running");
    self.redLast.indentationLevel = self.redBackground.indentationLevel = 1;
    [buttons addItem:NSMenuItem.separatorItem];
    toggle(buttons,greenKey,@"Green Button Fills or Restores the Window");
    toggle(buttons,optionClickKey,@"Option-Click Acts on One Window");

    NSMenu *activation = settingsSection(root,@"When Activating an App");
    toggle(activation,restoreKey,@"Restore One Window if All Are Minimized");
    [activation addItem:NSMenuItem.separatorItem];
    menuCaption(activation,@"Open a window if none exist");
    toggle(activation,finderKey,@"In Finder");
    toggle(activation,otherAppsKey,@"In Other Apps");

    NSMenu *language = settingsSection(root,@"Globe Key & Language");
    menuCaption(language,@"Use Globe / Fn as");
    self.globeChoices = [self choicesIn:language titles:@[@"Standard Globe / Fn", @"Option ⌥", @"Command ⌘", @"Control ⌃"] action:@selector(selectGlobe:)];
    [language addItem:NSMenuItem.separatorItem];
    menuCaption(language,@"Switch Keyboard Language");
    self.shiftShortcut = toggle(language,globeShiftKey,@"Globe + Shift");
    self.spaceShortcut = toggle(language,languageKey,@"Option + Space");
    [root addItem:NSMenuItem.separatorItem];
    toggle(root,fileCutKey,@"Move Files in Finder  ·  ⌘X / ⌘V");

    NSMenu *general = settingsSection(root,@"General");
    if (@available(macOS 13.0, *)) {
        self.loginItem = [general addItemWithTitle:@"Launch at Login" action:@selector(toggleLogin:) keyEquivalent:@""];
        self.loginItem.target = self;
        self.loginSettings = [general addItemWithTitle:@"Login Items Settings…" action:@selector(openLoginSettings:) keyEquivalent:@""];
        self.loginSettings.target = self;
    } else {
        menuCaption(general,@"Launch at Login (macOS 13+)");
        menuCaption(general,@"Login Items Settings…");
    }
    NSMenuItem *hide = [general addItemWithTitle:@"Hide Menu Bar Icon" action:@selector(hideMenuIcon:) keyEquivalent:@""];
    hide.target = self;
    hide.toolTip = @"Open Macdows again to show its icon.";
    [general addItemWithTitle:@"Accessibility Settings…" action:@selector(settings:) keyEquivalent:@""].target = self;
    [general addItemWithTitle:@"Astonio Website…" action:@selector(openAstonio:) keyEquivalent:@""].target = self;
    [root addItemWithTitle:@"Quit Macdows" action:@selector(terminate:) keyEquivalent:@"q"].target = NSApp;
    [self syncMenuChoices];
    return root;
}
- (void)syncMenuChoices {
    SwitcherScope scope = SwitcherSystem;
    if (localSwitcherEnabled) scope = localSwitcherCurrentOnly ? SwitcherThisDesktop : SwitcherAllDesktops;
    for (NSMenuItem *row in self.scopeChoices) row.state = row.tag == scope;
    LocalSwitcherDisplayMode display = localSwitcherDisplayMode(localSwitcherPreviews,localSwitcherEveryWindow);
    for (NSMenuItem *row in self.displayChoices) {
        row.state = localSwitcherEnabled && row.tag == display;
        row.enabled = localSwitcherEnabled;
    }
    self.switcherFinder.enabled = scope == SwitcherAllDesktops;
    self.switcherFinder.state = localSwitcherEnabled && (localSwitcherCurrentOnly || localSwitcherHideFinder);
    self.switcherFinder.toolTip = scope == SwitcherThisDesktop ? @"This desktop already excludes every app that has no windows here." : @"Available in Macdows · All Desktops.";
    BOOL needsCapture = localSwitcherEnabled && localSwitcherPreviews;
    self.previewAccess.enabled = needsCapture && !self.previewAccessWasAllowed;
    self.previewAccess.title = !needsCapture ? @"Screen Recording (for previews)" : self.previewAccessWasAllowed ? @"Screen Recording Granted" : @"Allow Screen Recording…";
    self.redLast.enabled = self.redBackground.enabled = redEnabled;
    self.redLast.state = redEnabled && lastEnabled;
    self.redBackground.state = redEnabled && backgroundEnabled;
    for (NSMenuItem *row in self.globeChoices) row.state = row.tag == globeMode;
    NSString *modifier = @[@"Globe",@"Option",@"Command",@"Control"][globeMode];
    self.shiftShortcut.title = globeMode == GlobeOff ? @"Globe + Shift" :
        [NSString stringWithFormat:@"Globe or %@ + Shift",modifier];
    self.spaceShortcut.title = globeMode == GlobeControl ? @"Globe / Option / Control + Space" :
        globeMode == GlobeCommand ? @"Option + Space" : @"Globe / Option + Space";
}
- (void)selectScope:(NSMenuItem *)choice {
    NSUserDefaults *prefs = NSUserDefaults.standardUserDefaults;
    BOOL custom = choice.tag != SwitcherSystem;
    if (custom) [prefs setBool:choice.tag == SwitcherThisDesktop forKey:localSwitcherCurrentOnlyKey];
    [prefs setBool:custom forKey:localSwitcherKey];
    [self loadPreferences];
    [self refresh];
    if (custom) [self ensurePreviewAccessIfNeeded:YES];
}
- (void)ensurePreviewAccessIfNeeded:(BOOL)request {
    BOOL needsPreviewAccess = localSwitcherEnabled && localSwitcherPreviews;
    BOOL allowed = CGPreflightScreenCaptureAccess();
    if (needsPreviewAccess && request && !allowed && !self.previewAccessRequested) {
        self.previewAccessRequested = YES;
        allowed = CGRequestScreenCaptureAccess();
    }
    if (allowed != self.previewAccessWasAllowed) [self refresh];
}
- (void)openPreviewAccess:(id)sender {
    if (!CGPreflightScreenCaptureAccess()) {
        self.previewAccessRequested = YES;
        if (!CGRequestScreenCaptureAccess())
            [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]];
    }
    [self refresh];
}
- (void)selectSwitcherDisplay:(NSMenuItem *)choice {
    LocalSwitcherDisplayMode mode = (LocalSwitcherDisplayMode)choice.tag;
    NSUserDefaults *prefs = NSUserDefaults.standardUserDefaults;
    [prefs setBool:mode != LocalSwitcherDisplayIcons forKey:localSwitcherPreviewsKey];
    [prefs setBool:mode == LocalSwitcherDisplayEveryWindow forKey:localSwitcherEveryWindowKey];
    [self loadPreferences];
    [self ensurePreviewAccessIfNeeded:YES];
}
- (void)updateLoginMenu API_AVAILABLE(macos(13.0)) {
    SMAppServiceStatus status = SMAppService.mainAppService.status;
    BOOL enabled = status == SMAppServiceStatusEnabled;
    BOOL pending = status == SMAppServiceStatusRequiresApproval;
    self.loginItem.state = enabled ? NSControlStateValueOn : pending ? NSControlStateValueMixed : NSControlStateValueOff;
    self.loginItem.title = pending ? @"Launch at Login · Approval Needed" : self.loginError && !enabled ? @"Launch at Login · Retry" : @"Launch at Login";
    self.loginItem.toolTip = self.loginError;
    self.loginSettings.enabled = YES;
}
// Freeze one snapshot while AppKit tracks the root and its single-level submenus.
- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (self.menuTracking) return;
    self.status.title = self.statusText ?: @"Macdows";
    [self syncMenuChoices];
    if (@available(macOS 13.0, *)) [self updateLoginMenu];
}
- (void)menuWillOpen:(NSMenu *)menu { self.menuTracking = YES; }
- (void)menuDidClose:(NSMenu *)menu {
    self.menuTracking = NO;
    // Selection actions can be delivered just after tracking ends.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.menuTracking) [self syncMenuChoices];
    });
}
- (void)openLoginSettings:(id)sender API_AVAILABLE(macos(13.0)) {
    [SMAppService openSystemSettingsLoginItems];
}
- (void)toggleLogin:(id)sender API_AVAILABLE(macos(13.0)) {
    SMAppService *service = SMAppService.mainAppService;
    NSError *error = nil;
    BOOL registered = service.status == SMAppServiceStatusEnabled || service.status == SMAppServiceStatusRequiresApproval;
    BOOL success = registered ? [service unregisterAndReturnError:&error] : [service registerAndReturnError:&error];
    self.loginError = success ? nil : error.localizedDescription;
    if (success || service.status == SMAppServiceStatusRequiresApproval)
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"DidConfigureLaunchAtLogin"];
    [self updateLoginMenu];
    if (!success && error && service.status != SMAppServiceStatusRequiresApproval) {
        [[NSAlert alertWithError:error] runModal];
    }
}
- (void)refresh {
    BOOL allowed = AXIsProcessTrusted();
    BOOL previewAllowed = CGPreflightScreenCaptureAccess();
    if (previewAllowed != self.previewAccessWasAllowed) {
        self.previewAccessWasAllowed = previewAllowed;
        [localSwitcherPreviewImageCache removeAllObjects];
        [localSwitcherPreviewLoadsInFlight removeAllObjects];
        if (localSwitcherActive) {
            localSwitcherRenderedStart = NSNotFound;
            renderLocalSwitcher();
        }
    }
    double now = NSProcessInfo.processInfo.systemUptime;
    if (!atomic_load(&inputPaused) && now-lastInputRecovery > 60)
        inputRetryCount = 0;
    if (allowed && inputRecoveryReady(now)) {
        static const double retryDelays[] = {2, 5, 15, 60};
        inputRetryAfter = now+retryDelays[MIN(inputRetryCount, 3)];
        inputRetryCount++;
        lastInputRecovery = now;
        resetClick();
        cutKeyHeld = NO; moveKeyHeld = NO;
        clearCut();
        globeHeld = NO; spaceConsumed = NO;
        shiftPending = NO; shiftBlocked = NO;
        resumeInput();
    }
    BOOL paused = atomic_load(&inputPaused);
    @synchronized (NSApplication.class) {
        if (allowed && !paused && !tap) {
            CGEventMask mask = CGEventMaskBit(kCGEventLeftMouseDown) | CGEventMaskBit(kCGEventLeftMouseDragged) | CGEventMaskBit(kCGEventLeftMouseUp);
            tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, mask, mouseEvent, NULL);
            if (tap) {
                CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(NULL, tap, 0);
                CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
                CFRelease(source);
            }
        }
        if ((!allowed || paused) && tap) {
            CFMachPortInvalidate(tap);
            CFRelease(tap);
            tap = NULL;
            resetClick();
        }
        refreshGlobeTap(allowed && !paused);
    }
    syncKeyboards(globeMode);
    BOOL previewMissing = localSwitcherEnabled && localSwitcherPreviews && !previewAllowed;
    self.statusText = paused ? @"Input paused after a slow response · recovering automatically" : !allowed ? @"Macdows 1.35 needs Accessibility access" : !tap ? @"Mouse access unavailable · reopen Macdows" : (snapEnabled || arrangeEnabled || desktopEnabled || cycleEnabled || fileCutEnabled || languageEnabled || globeShiftEnabled || windowSwitchEnabled() || localSwitcherEnabled || globeMode != GlobeOff) && !globeTap ? @"Keyboard access unavailable · reopen Macdows" : previewMissing ? @"Window previews need Screen Recording access" : (!snapEnabled && !arrangeEnabled && !desktopEnabled && !cycleEnabled && !redEnabled && !greenEnabled && globeMode == GlobeOff && !optionEnabled && !dragEnabled && !restoreEnabled && !windowSwitchEnabled() && !localSwitcherEnabled && !fileCutEnabled && !languageEnabled && !globeShiftEnabled) ? @"All switches off" : @"Macdows 1.35 is active";
}
- (void)toggle:(NSMenuItem *)item {
    BOOL enabled = item.state != NSControlStateValueOn;
    item.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:item.representedObject];
    [self loadPreferences];
    inputRetryCount = 0; inputRetryAfter = 0;
    resumeInput();
    [self refresh];
}
- (void)selectGlobe:(NSMenuItem *)choice {
    shiftPending = NO; shiftBlocked = NO;
    globeMode = (GlobeMode)choice.tag;
    [NSUserDefaults.standardUserDefaults setInteger:globeMode forKey:globeModeKey];
    inputRetryCount = 0; inputRetryAfter = 0;
    resumeInput();
    [self refresh];
}
- (void)loadPreferences {
    NSUserDefaults *prefs = NSUserDefaults.standardUserDefaults;
    globeShiftEnabled = [prefs boolForKey:globeShiftKey];
    shiftPending = NO; shiftBlocked = NO;
    snapEnabled = [prefs boolForKey:snapKey];
    arrangeEnabled = [prefs boolForKey:arrangeKey];
    desktopEnabled = [prefs boolForKey:desktopKey];
    cycleEnabled = [prefs boolForKey:cycleKey];
    languageEnabled = [prefs boolForKey:languageKey];
    redEnabled = [prefs boolForKey:redKey];
    backgroundEnabled = [prefs boolForKey:backgroundKey];
    greenEnabled = [prefs boolForKey:greenKey];
    globeMode = (GlobeMode)[prefs integerForKey:globeModeKey];
    if (globeMode < GlobeOff || globeMode > GlobeControl) globeMode = GlobeOption;
    lastEnabled = [prefs boolForKey:lastKey];
    optionEnabled = [prefs boolForKey:optionClickKey];
    dragEnabled = [prefs boolForKey:dragKey];
    finderEnabled = [prefs boolForKey:finderKey];
    fileCutEnabled = [prefs boolForKey:fileCutKey];
    if (!fileCutEnabled) clearCut();
    restoreEnabled = [prefs boolForKey:restoreKey];
    otherAppsEnabled = [prefs boolForKey:otherAppsKey];
    localSwitcherEnabled = [prefs boolForKey:localSwitcherKey];
    localSwitcherCurrentOnly = [prefs boolForKey:localSwitcherCurrentOnlyKey];
    localSwitcherHideFinder = [prefs boolForKey:localSwitcherHideFinderKey];
    localSwitcherPreviews = [prefs boolForKey:localSwitcherPreviewsKey];
    localSwitcherEveryWindow = [prefs boolForKey:localSwitcherEveryWindowKey];
    if (localSwitcherEveryWindow && !localSwitcherPreviews) {
        localSwitcherPreviews = YES;
        [prefs setBool:YES forKey:localSwitcherPreviewsKey];
    }
    if (!localSwitcherEnabled && localSwitcherActive) finishLocalSwitcher(NO);
    if (!windowSwitchEnabled()) switchGeneration++;
    configureNativeBindings(snapEnabled || arrangeEnabled || greenEnabled);
}
- (void)hideMenuIcon:(id)sender {
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:hideIconKey];
    self.item.visible = NO;
}
- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)hasWindows {
    if (self.item && !self.item.visible) {
        [NSUserDefaults.standardUserDefaults setBool:NO forKey:hideIconKey];
        self.item.visible = YES;
    }
    return YES;
}
- (void)openAstonio:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://astonio.com"]];
}
- (void)settings:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
}
@end

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        Macdows * __attribute__((objc_precise_lifetime)) delegate = [Macdows new];
        NSApp.delegate = delegate;
        [NSApp run];
    }
    return 0;
}
