#define main macdows_main
#import "Macdows.app/Contents/Resources/Macdows.m"
#undef main
static dispatch_semaphore_t started, releaseWorker, finished;
static NSInteger executions;
static NSUInteger lastExecuted;
static NSInteger cyclePosts;
static CGEventTapLocation lastCycleLocation;
static NSInteger desktopSchedules;
static NSInteger scheduledDesktopDirection=-1;
static void fakeCyclePost(CGEventTapLocation location, CGEventRef event) {
 cyclePosts++; lastCycleLocation=location;
}
static void fakeDesktopSchedule(NSInteger direction) {
 desktopSchedules++; scheduledDesktopDirection=direction;
}
static void fakeExecute(WindowRequest *request) {
 executions++; lastExecuted=request.generation;
 if (executions==1) { dispatch_semaphore_signal(started); dispatch_semaphore_wait(releaseWorker,DISPATCH_TIME_FOREVER); }
 else dispatch_semaphore_signal(finished);
}
static void testSettingChoices(void) {
    NSString *suite = [@"local.macdows.tests.settings." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:suite];
    [prefs setBool:YES forKey:localSwitcherCurrentOnlyKey];
    [prefs setBool:YES forKey:localSwitcherEveryWindowKey];
    [prefs setBool:YES forKey:localSwitcherPreviewsKey];
    [prefs setBool:NO forKey:localSwitcherHideFinderKey];

    // Switching to macOS must preserve the user's previous Macdows configuration.
    storeSettingChoice(prefs, @"scope", SwitcherSystem);
    storeSettingChoice(prefs, @"display", LocalSwitcherDisplayIcons);
    storeSettingChoice(prefs, localSwitcherHideFinderKey, YES);
    assert(![prefs boolForKey:localSwitcherKey] && [prefs boolForKey:localSwitcherCurrentOnlyKey]);
    assert([prefs boolForKey:localSwitcherPreviewsKey] && [prefs boolForKey:localSwitcherEveryWindowKey]);
    assert(![prefs boolForKey:localSwitcherHideFinderKey]);

    storeSettingChoice(prefs, @"scope", SwitcherThisDesktop);
    storeSettingChoice(prefs, localSwitcherHideFinderKey, YES);
    assert([prefs boolForKey:localSwitcherKey] && [prefs boolForKey:localSwitcherCurrentOnlyKey]);
    assert(![prefs boolForKey:localSwitcherHideFinderKey]);
    storeSettingChoice(prefs, @"scope", SwitcherAllDesktops);
    assert([prefs boolForKey:localSwitcherKey] && ![prefs boolForKey:localSwitcherCurrentOnlyKey]);
    storeSettingChoice(prefs, localSwitcherHideFinderKey, YES);
    assert([prefs boolForKey:localSwitcherHideFinderKey]);

    storeSettingChoice(prefs, @"display", LocalSwitcherDisplayIcons);
    assert(![prefs boolForKey:localSwitcherPreviewsKey] && ![prefs boolForKey:localSwitcherEveryWindowKey]);
    storeSettingChoice(prefs, @"display", LocalSwitcherDisplayAppPreviews);
    assert([prefs boolForKey:localSwitcherPreviewsKey] && ![prefs boolForKey:localSwitcherEveryWindowKey]);
    storeSettingChoice(prefs, @"display", LocalSwitcherDisplayEveryWindow);
    assert([prefs boolForKey:localSwitcherPreviewsKey] && [prefs boolForKey:localSwitcherEveryWindowKey]);

    storeSettingChoice(prefs, @"redMode", 1);
    assert([prefs boolForKey:redKey] && [prefs boolForKey:lastKey]);
    storeSettingChoice(prefs, backgroundKey, YES);
    storeSettingChoice(prefs, @"redMode", 0);
    storeSettingChoice(prefs, backgroundKey, NO);
    assert(![prefs boolForKey:redKey] && [prefs boolForKey:lastKey] && [prefs boolForKey:backgroundKey]);
    storeSettingChoice(prefs, @"redMode", 2);
    assert([prefs boolForKey:redKey] && ![prefs boolForKey:lastKey]);
    storeSettingChoice(prefs, backgroundKey, NO);
    assert(![prefs boolForKey:backgroundKey]);

    storeSettingChoice(prefs, globeShiftKey, NO);
    storeSettingChoice(prefs, languageKey, YES);
    for (GlobeMode mode = GlobeOff; mode <= GlobeControl; mode++) {
        storeSettingChoice(prefs, @"globe", mode);
        assert([prefs integerForKey:globeModeKey] == mode);
        assert(![prefs boolForKey:globeShiftKey] && [prefs boolForKey:languageKey]);
    }
    storeSettingChoice(prefs, globeShiftKey, YES);
    storeSettingChoice(prefs, languageKey, NO);
    assert([prefs boolForKey:globeShiftKey] && ![prefs boolForKey:languageKey]);

    [prefs removePersistentDomainForName:suite];
    puts("PASS: settings choices preserve child preferences and reject inactive changes");
}

static void testStatusMenu(void) {
    [NSApplication sharedApplication];
    Macdows *controller = [Macdows new];
    NSMenu *root = [controller buildStatusMenu];
    NSMutableArray<NSMenuItem *> *rows = [NSMutableArray array];
    for (NSMenuItem *item in root.itemArray) {
        assert(!item.hasSubmenu && !item.hidden);
        if (!item.separatorItem) [rows addObject:item];
    }
    assert(rows.count == 3);
    assert(!rows[0].action && !rows[0].enabled);
    assert(rows[1].action == @selector(showSettings:) && rows[1].target == controller);
    assert([rows[1].keyEquivalent isEqual:@","]);
    assert(rows[2].action == @selector(terminate:) && [rows[2].keyEquivalent isEqual:@"q"]);
    [controller prepareSettingsWindow];
    assert(controller.preferencesWindow != nil);
    [controller syncSettings];

    NSDictionary<NSString *, NSControl *> *controls = controller.preferencesWindow.controls;
    NSArray<NSArray<NSString *> *> *panes = @[
        @[@"scope", @"display", localSwitcherHideFinderKey, @"previewAccess"],
        @[@"redMode", backgroundKey, greenKey, optionClickKey, cycleKey, desktopKey, dragKey, snapKey, arrangeKey],
        @[@"globe", globeShiftKey, languageKey],
        @[restoreKey, finderKey, otherAppsKey, fileCutKey],
        @[@"login", @"loginSettings", @"accessibility", @"menuIcon", @"website"]
    ];
    NSMutableSet<NSString *> *allKeys = [NSMutableSet set];
    for (NSUInteger index = 0; index < panes.count; ++index) {
        [controller.preferencesWindow selectPane:index];
        NSArray<NSString *> *expected = panes[index];
        NSMutableSet *reachable = [NSMutableSet set];
        for (NSString *key in controls) {
            NSControl *control = controls[key];
            assert([control.identifier isEqual:key]);
            if (control.window == controller.preferencesWindow.window && !control.hiddenOrHasHiddenAncestor) {
                assert(control.action && control.target);
                [reachable addObject:key];
            }
        }
        assert([reachable isEqualToSet:[NSSet setWithArray:expected]]);
        [allKeys addObjectsFromArray:expected];
    }
    assert(allKeys.count == controls.count);
    assert(!controller.preferencesWindow.window.visible);
    NSPopUpButton *scope = (NSPopUpButton *)controls[@"scope"];
    NSPopUpButton *display = (NSPopUpButton *)controls[@"display"];
    NSButton *finder = (NSButton *)controls[localSwitcherHideFinderKey];
    NSButton *background = (NSButton *)controls[backgroundKey];
    NSControl *permission = controls[@"previewAccess"];
    globeMode = GlobeOff;
    localSwitcherCurrentOnly = YES;
    localSwitcherHideFinder = NO;
    localSwitcherPreviews = YES;
    localSwitcherEveryWindow = NO;
    redEnabled = localSwitcherEnabled = NO;
    controller.previewAccessWasAllowed = NO;
    [controller syncSettings];
    assert(scope.indexOfSelectedItem == SwitcherSystem);
    assert(!display.enabled && !finder.enabled && !permission.enabled && !background.enabled);
    assert(controls[greenKey].enabled && controls[optionClickKey].enabled);
    assert(controls[finderKey].enabled && controls[otherAppsKey].enabled && controls[restoreKey].enabled);

    redEnabled = localSwitcherEnabled = YES;
    [controller syncSettings];
    assert(scope.indexOfSelectedItem == SwitcherThisDesktop && display.enabled);
    assert(display.indexOfSelectedItem == LocalSwitcherDisplayAppPreviews);
    assert(!finder.enabled && finder.state == NSControlStateValueOn);
    assert(permission.enabled && background.enabled);

    localSwitcherCurrentOnly = NO;
    controller.previewAccessWasAllowed = YES;
    [controller syncSettings];
    assert(scope.indexOfSelectedItem == SwitcherAllDesktops);
    assert(finder.enabled && finder.state == NSControlStateValueOff && !permission.enabled);
    localSwitcherPreviews = NO;
    controller.previewAccessWasAllowed = NO;
    [controller syncSettings];
    assert(display.indexOfSelectedItem == LocalSwitcherDisplayIcons && !permission.enabled);
    for (GlobeMode mode = GlobeOff; mode <= GlobeControl; mode++) {
        globeMode = mode;
        [controller syncSettings];
        assert(controls[globeShiftKey].enabled && controls[languageKey].enabled);
    }
    globeMode = GlobeOff;
    puts("PASS: flat status menu and consistent settings availability");
}
static void testTilingAvailability(void) {
 NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:@"local.macdows.tests.tiling"];
 [prefs setVolatileDomain:@{snapKey:@YES, arrangeKey:@YES} forName:NSArgumentDomain];
 loadTilingShortcuts(prefs,NO);
 assert(!snapEnabled && !arrangeEnabled);
 assert([prefs boolForKey:snapKey] && [prefs boolForKey:arrangeKey]);
 loadTilingShortcuts(prefs,YES);
 assert(snapEnabled && arrangeEnabled);
 [prefs setVolatileDomain:@{snapKey:@NO, arrangeKey:@YES} forName:NSArgumentDomain];
 loadTilingShortcuts(prefs,YES);
 assert(!snapEnabled && arrangeEnabled);
 [prefs removeVolatileDomainForName:NSArgumentDomain];
 puts("PASS: unsupported tiling shortcuts stay inactive and preserve their saved choices");
}
int main(void) { @autoreleasepool {
 testSettingChoices();
 testStatusMenu();
 testTilingAvailability();
 localSwitcherEnabled=YES;
 assert(localSwitcherDisplayMode(NO,NO)==LocalSwitcherDisplayIcons);
 assert(localSwitcherDisplayMode(YES,NO)==LocalSwitcherDisplayAppPreviews);
 assert(localSwitcherDisplayMode(YES,YES)==LocalSwitcherDisplayEveryWindow);
 assert(localSwitcherDisplayMode(NO,YES)==LocalSwitcherDisplayEveryWindow);
 NSUserDefaults *migrationPrefs=[[NSUserDefaults alloc] initWithSuiteName:@"local.macdows.tests.preview-migration"];
 [migrationPrefs removePersistentDomainForName:@"local.macdows.tests.preview-migration"];
 [migrationPrefs setBool:YES forKey:legacyLocalSwitcherPreviewsKey];
 migrateLocalSwitcherPreviewPreference(migrationPrefs);
 assert([migrationPrefs boolForKey:localSwitcherPreviewsKey]);
 [migrationPrefs setBool:NO forKey:localSwitcherPreviewsKey];
 migrateLocalSwitcherPreviewPreference(migrationPrefs);
 assert(![migrationPrefs boolForKey:localSwitcherPreviewsKey]);
 [migrationPrefs removePersistentDomainForName:@"local.macdows.tests.preview-migration"];
 assert(localSwitcherChord(kCGEventFlagMaskCommand));
 assert(localSwitcherChord(kCGEventFlagMaskCommand|kCGEventFlagMaskShift));
 assert(!localSwitcherChord(kCGEventFlagMaskCommand|kCGEventFlagMaskAlternate));
 assert(nextLocalSwitcherIndex(4,NSNotFound,NO,YES)==1);
 assert(nextLocalSwitcherIndex(4,NSNotFound,YES,YES)==3);
 assert(nextLocalSwitcherIndex(4,3,NO,NO)==0);
 assert(nextLocalSwitcherIndex(4,0,YES,NO)==3);
 localSwitcherCurrentOnly=YES; localSwitcherHideFinder=YES;
 assert(includeInLocalSwitcher(@"com.example.App",YES,YES));
 assert(!includeInLocalSwitcher(@"com.example.App",YES,NO));
 assert(!includeInLocalSwitcher(@"com.apple.finder",NO,NO));
 localSwitcherCurrentOnly=NO;
 assert(includeInLocalSwitcher(@"com.example.App",NO,NO));
 assert(placementKeyMatches(kVK_LeftArrow,12,0,NO));
 assert(keyboardTapLocation()==kCGHIDEventTap);
 assert(!placementKeyMatches(kVK_LeftArrow,12,0,YES));
 assert(placementKeyMatches(kVK_LeftArrow,13,0,YES));
 assert(placementKeyMatches(kVK_RightArrow,13,1,YES));
 assert(placementKeyMatches(kVK_ANSI_F,12,2,YES));
 assert(placementKeyMatches(kVK_ANSI_R,12,3,YES));
 assert(!placementKeyMatches(kVK_ANSI_F,0,2,NO));
 snapEnabled=YES;arrangeEnabled=NO;
 assert(arrangementChord(kCGEventFlagMaskControl,0));
 assert(!arrangementChord(kCGEventFlagMaskControl|kCGEventFlagMaskAlternate,0));
 snapEnabled=NO;arrangeEnabled=YES;
 assert(!arrangementChord(kCGEventFlagMaskControl,0));
 assert(arrangementChord(kCGEventFlagMaskControl|kCGEventFlagMaskAlternate,3));
 assert(!arrangementChord(kCGEventFlagMaskCommand|kCGEventFlagMaskAlternate,3));
 desktopEnabled=YES;
 CGEventFlags desktopFlags=kCGEventFlagMaskControl|kCGEventFlagMaskAlternate|kCGEventFlagMaskShift;
 assert(desktopChord(desktopFlags,0));
 assert(desktopChord(desktopFlags,1));
 assert(desktopChord(desktopFlags|kCGEventFlagMaskSecondaryFn,1));
 globeHeld=YES; heldMode=GlobeControl;
 assert(desktopChord(kCGEventFlagMaskSecondaryFn|kCGEventFlagMaskAlternate|kCGEventFlagMaskShift,1));
 heldMode=GlobeCommand;
 assert(!desktopChord(kCGEventFlagMaskSecondaryFn|kCGEventFlagMaskAlternate|kCGEventFlagMaskShift,1));
 globeHeld=NO;
 assert(!desktopChord(desktopFlags,2));
 assert(!desktopChord(desktopFlags|kCGEventFlagMaskCommand,0));
 assert(!desktopChord(kCGEventFlagMaskControl|kCGEventFlagMaskAlternate,0));
 assert([desktopScriptName(0) isEqual:@"SwitchDesktopLeft"]);
 assert([desktopScriptName(1) isEqual:@"SwitchDesktopRight"]);
 desktopSwitchScheduler=fakeDesktopSchedule;
 CGEventRef desktopDown=CGEventCreateKeyboardEvent(NULL,kVK_RightArrow,true);
 CGEventSetFlags(desktopDown,desktopFlags);
 assert(globeEvent(NULL,kCGEventKeyDown,desktopDown,NULL)==NULL);
 assert(desktopArrowConsumed[1]);
 assert(desktopSchedules==1 && scheduledDesktopDirection==1);
 CGEventRef desktopRepeat=CGEventCreateKeyboardEvent(NULL,kVK_RightArrow,true);
 CGEventSetFlags(desktopRepeat,desktopFlags);
 CGEventSetIntegerValueField(desktopRepeat,kCGKeyboardEventAutorepeat,1);
 assert(globeEvent(NULL,kCGEventKeyDown,desktopRepeat,NULL)==NULL);
 assert(desktopSchedules==1);
 CGEventRef desktopUp=CGEventCreateKeyboardEvent(NULL,kVK_RightArrow,false);
 assert(globeEvent(NULL,kCGEventKeyUp,desktopUp,NULL)==NULL);
 assert(!desktopArrowConsumed[1]);
 CFRelease(desktopDown); CFRelease(desktopRepeat); CFRelease(desktopUp);
 desktopSwitchScheduler=scheduleDesktopSwitch;
 assert(cycleCandidate(@"AXWindow",@"AXStandardWindow",@NO));
 assert(cycleCandidate(@"AXWindow",nil,@NO));
 assert(cycleCandidate(@"AXWindow",@"AXUnknown",@NO));
 assert(!cycleCandidate(@"AXWindow",@"AXDialog",@NO));
 assert(!cycleCandidate(@"AXWindow",@"AXStandardWindow",@YES));
 assert(!cycleCandidate(nil,@"AXStandardWindow",@NO));
 NSMutableArray *ring=[NSMutableArray array];
 cycleTarget(ring,@[@"A",@"B",@"C"],@"A",NO);
 assert([cycleTarget(ring,@[@"C",@"B",@"A"],@"C",NO) isEqual:@"A"]);
 assert([cycleTarget(ring,@[@"B",@"A",@"C"],@"A",YES) isEqual:@"C"]);
 assert([cycleTarget(ring,@[@"C",@"A"],@"A",NO) isEqual:@"C"]);
 assert(cycleTarget(ring,@[@"A"],@"A",NO)==nil);
 assert(cycleTarget(ring,@[@"A",@"B"],@"Missing",NO)==nil);
 assert(cycleTarget(ring,@[],@"A",NO)==nil);
 CGEventRef fallbackEvent=CGEventCreateKeyboardEvent(NULL,kVK_ANSI_Grave,true);
 UniChar russianYo=0x0451;
 CGEventKeyboardSetUnicodeString(fallbackEvent,1,&russianYo);
 normalizeCycleFallback(fallbackEvent);
 UniChar fallbackText[2]={0}; UniCharCount fallbackLength=0;
 CGEventKeyboardGetUnicodeString(fallbackEvent,2,&fallbackLength,fallbackText);
 assert(fallbackLength==1 && fallbackText[0]=='`');
 cycleEventPoster=fakeCyclePost; postCycleEvent(fallbackEvent);
 assert(cyclePosts==1 && lastCycleLocation==kCGSessionEventTap);
 cycleEventPoster=CGEventPost;
 CFRelease(fallbackEvent);

 CGRect area=CGRectMake(0,25,1600,875);
 CGRect near=CGRectInset(area,8,8), small=CGRectMake(200,130,1000,600);
 assert(largeWindow(near,area));
 assert(!largeWindow(CGRectMake(0,25,800,875),area));
 assert(!largeWindow(small,area));
 CGRect fallback=fallbackWindowFrame(area);
 assert(similar(restoredWindowFrame(near,area,nil),fallback));
 assert(similar(restoredWindowFrame(near,area,[NSValue valueWithRect:near]),fallback));
 CGRect restored=restoredWindowFrame(near,area,[NSValue valueWithRect:small]);
 assert(CGSizeEqualToSize(restored.size,small.size));
 assert(CGPointEqualToPoint(restored.origin,centeredOrigin(small.size,area)));
 assert(frameInside(restored,area));
 assert(CGPointEqualToPoint(centeredOrigin(CGSizeMake(2000,1200),area),area.origin));
 CGRect edge=boundedFrame(CGRectMake(-500,999,800,400),area); assert(frameInside(edge,area));
 assert(!largeWindow(fallback,area));
 assert(fallback.size.width==1280 && fallback.size.height==699);
 assert(similar(restoredWindowFrame(fallback,area,[NSValue valueWithRect:area]),fallback));
 WindowState *state=[WindowState new]; state.intent=WindowFill;
 assert(resolvedIntent(WindowToggle,state,small,area)==WindowRestore); // animation still at old size
 state.intent=WindowRestore;
 assert(resolvedIntent(WindowRestore,state,area,area)==WindowRestore); // never toggles
 assert(resolvedIntent(WindowFill,state,small,area)==WindowFill);
 state.intent=WindowLeft;
 assert(resolvedIntent(WindowToggle,state,small,area)==WindowRestore);
 assert(resolvedIntent(WindowToggle,nil,small,area)==WindowFill);
 assert(resolvedIntent(WindowToggle,nil,near,area)==WindowRestore);
 CGRect constrained=boundedFrame(CGRectMake(-200,-100,2000,1200),area);
 assert(similar(constrained,area));
 // A blocked application plus 1,000 newer intents must execute only the first
 // in-flight request and the last pending one, with cancellation observable.
 started=dispatch_semaphore_create(0); releaseWorker=dispatch_semaphore_create(0);
 finished=dispatch_semaphore_create(0); windowExecutor=fakeExecute;
 WindowRequest *first=[WindowRequest new]; first.intent=WindowFill;
 submitWindowRequest(first);
 assert(dispatch_semaphore_wait(started,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0);
 WindowRequest *last=nil;
 for (int i=0;i<1000;i++) { last=[WindowRequest new]; last.intent=WindowRestore; submitWindowRequest(last); }
 assert(!requestCurrent(first)); assert(requestCurrent(last));
 dispatch_semaphore_signal(releaseWorker);
 assert(dispatch_semaphore_wait(finished,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0);
 dispatch_sync(windowActionQueue(),^{});
 assert(executions==2 && lastExecuted==last.generation);
 cancelWindowRequests(); assert(!requestCurrent(last));
 NSMutableDictionary *backup=[NSMutableDictionary new];
 NSString *binding=nativeBindings().allKeys.firstObject;
 NSDictionary *existing=@{binding:@"@x",@"Unrelated":@"@z"};
 NSDictionary *installed=mergedNativeBindings(existing,backup,YES);
 assert([installed[@"Unrelated"] isEqual:@"@z"]);
 assert([backup[binding] isEqual:@"@x"]);
 installed=mergedNativeBindings(installed,backup,YES);
 assert([backup[binding] isEqual:@"@x"]);
 NSDictionary *removed=mergedNativeBindings(installed,backup,NO);
 assert([removed isEqual:existing] && backup.count==0);
 installed=mergedNativeBindings(existing,backup,YES);
 NSMutableDictionary *userEdit=[installed mutableCopy]; userEdit[binding]=@"@y";
 removed=mergedNativeBindings(userEdit,backup,NO);
 assert([removed[binding] isEqual:@"@y"]);
 CGEventRef event=copyPlacementEvent(0,YES,YES);
 assert(CGEventGetIntegerValueField(event,kCGKeyboardEventKeycode)==kVK_LeftArrow);
 assert(CGEventGetIntegerValueField(event,kCGEventSourceUserData)==nativeMoveTag);
 assert(CGEventGetFlags(event)&kCGEventFlagMaskShift);
 assert(!(CGEventGetFlags(event)&kCGEventFlagMaskSecondaryFn));
 CFRelease(event);
 puts("PASS: desktop switching chord, layout-independent cycle fallback, intent transitions, original-size restore, 80% fallback, bounds, circular switching, 1,000-request coalescing and cancellation");
} }
