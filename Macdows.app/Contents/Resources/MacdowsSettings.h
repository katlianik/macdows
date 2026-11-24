#pragma once

// AppKit settings for the menu-bar app. Changes are routed to the existing app controller.
@interface MacdowsSettingsWindow : NSWindow
@end

@implementation MacdowsSettingsWindow
- (void)cancelOperation:(id)sender {
    [self performClose:sender];
}
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if (flags == NSEventModifierFlagCommand && [event.charactersIgnoringModifiers.lowercaseString isEqualToString:@"w"]) {
        [self performClose:self];
        return YES;
    }
    return [super performKeyEquivalent:event];
}
@end

@interface MacdowsSettingsDocument : NSView
@end

@implementation MacdowsSettingsDocument
- (BOOL)isFlipped { return YES; }
@end

@interface MacdowsSettings : NSWindowController <NSToolbarDelegate>
@property(copy) void (^onChange)(NSString *key, NSInteger value);
@property(readonly) NSDictionary<NSString *, NSControl *> *controls;
@property(readonly) NSDictionary<NSString *, NSTextField *> *notes;
- (void)selectPane:(NSInteger)index;
- (void)showSettings;
@end

@implementation MacdowsSettings {
    NSMutableDictionary<NSString *, NSControl *> *_controls;
    NSMutableDictionary<NSString *, NSTextField *> *_notes;
    NSArray<NSString *> *_titles;
    NSArray<NSString *> *_symbols;
    NSMutableArray<NSScrollView *> *_panes;
    NSView *_host;
}

- (NSDictionary<NSString *, NSControl *> *)controls { return _controls; }
- (NSDictionary<NSString *, NSTextField *> *)notes { return _notes; }

- (instancetype)init {
    NSWindow *window = [[MacdowsSettingsWindow alloc] initWithContentRect:NSMakeRect(0, 0, 610, 510)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    self = [super initWithWindow:window];
    if (!self) return nil;
    window.releasedWhenClosed = NO;
    window.title = @"Macdows Settings";
    window.toolbarStyle = NSWindowToolbarStylePreference;
    window.contentMinSize = NSMakeSize(540, 335);
    _host = window.contentView;
    _controls = [NSMutableDictionary new];
    _notes = [NSMutableDictionary new];
    _panes = [NSMutableArray new];
    _titles = @[@"Switcher", @"Windows", @"Keyboard", @"Apps & Finder", @"General"];
    _symbols = @[@"square.on.square", @"macwindow", @"keyboard", @"folder", @"gearshape"];
    [self buildPanes];
    NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"MacdowsSettingsToolbar"];
    toolbar.delegate = self;
    toolbar.allowsUserCustomization = NO;
    toolbar.displayMode = NSToolbarDisplayModeIconAndLabel;
    window.toolbar = toolbar;
    NSInteger index = [NSUserDefaults.standardUserDefaults integerForKey:@"LastSettingsPane"];
    [self selectPane:(index >= 0 && index < (NSInteger)_panes.count ? index : 0)];
    [window center];
    [window setFrameAutosaveName:@"MacdowsSettings"];
    return self;
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar { return _titles; }
- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar { return _titles; }
- (NSArray<NSToolbarItemIdentifier> *)toolbarSelectableItemIdentifiers:(NSToolbar *)toolbar { return _titles; }

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)identifier
 willBeInsertedIntoToolbar:(BOOL)inserted {
    NSUInteger index = [_titles indexOfObject:identifier];
    if (index == NSNotFound) return nil;
    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:identifier];
    item.label = identifier;
    item.paletteLabel = identifier;
    item.image = [NSImage imageWithSystemSymbolName:_symbols[index] accessibilityDescription:identifier];
    item.tag = (NSInteger)index;
    item.target = self;
    item.action = @selector(changePane:);
    return item;
}

- (void)changePane:(NSToolbarItem *)item {
    [self selectPane:item.tag];
    [NSUserDefaults.standardUserDefaults setInteger:item.tag forKey:@"LastSettingsPane"];
}
- (void)selectPane:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_panes.count) return;
    NSScrollView *pane = _panes[(NSUInteger)index];
    if (pane.superview != _host) {
        for (NSView *view in _host.subviews.copy) [view removeFromSuperview];
        pane.frame = _host.bounds;
        pane.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [_host addSubview:pane];
        [self.window recalculateKeyViewLoop];
    }
    self.window.toolbar.selectedItemIdentifier = _titles[(NSUInteger)index];
    self.window.title = [NSString stringWithFormat:@"%@ Settings", _titles[(NSUInteger)index]];
}
- (void)showSettings {
    if (@available(macOS 14.0, *)) [NSApp activate];
    else [NSApp activateIgnoringOtherApps:YES];
    [self.window makeKeyAndOrderFront:self];
}

- (NSStackView *)newPane {
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 610, 510)];
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.drawsBackground = NO;
    scroll.contentView.drawsBackground = NO;
    NSView *doc = [[MacdowsSettingsDocument alloc] initWithFrame:scroll.bounds];
    doc.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.documentView = doc;
    NSStackView *page = [NSStackView new];
    page.orientation = NSUserInterfaceLayoutOrientationVertical;
    page.alignment = NSLayoutAttributeLeading;
    page.spacing = 20;
    page.translatesAutoresizingMaskIntoConstraints = NO;
    [doc addSubview:page];
    [NSLayoutConstraint activateConstraints:@[
        [doc.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor],
        [doc.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor],
        [doc.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],
        [page.topAnchor constraintEqualToAnchor:doc.topAnchor constant:22],
        [page.leadingAnchor constraintEqualToAnchor:doc.leadingAnchor constant:26],
        [page.trailingAnchor constraintEqualToAnchor:doc.trailingAnchor constant:-26],
        [page.bottomAnchor constraintEqualToAnchor:doc.bottomAnchor constant:-22]
    ]];
    [_panes addObject:scroll];
    return page;
}

- (NSStackView *)group:(NSString *)title inPane:(NSStackView *)page {
    NSTextField *heading = [NSTextField labelWithString:title];
    heading.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    if (@available(macOS 26.0, *)) heading.accessibilityRole = NSAccessibilityHeadingRole;
    [page addArrangedSubview:heading];
    [page setCustomSpacing:7 afterView:heading];

    NSBox *box = [NSBox new];
    box.boxType = NSBoxCustom;
    box.titlePosition = NSNoTitle;
    box.cornerRadius = 9;
    box.fillColor = NSColor.controlBackgroundColor;
    box.borderColor = NSColor.separatorColor;
    box.borderWidth = 1;
    box.contentViewMargins = NSZeroSize;
    [page addArrangedSubview:box];
    [box.widthAnchor constraintEqualToAnchor:page.widthAnchor].active = YES;

    NSStackView *rows = [NSStackView new];
    rows.translatesAutoresizingMaskIntoConstraints = NO;
    rows.orientation = NSUserInterfaceLayoutOrientationVertical;
    rows.alignment = NSLayoutAttributeLeading;
    rows.spacing = 8;
    [box.contentView addSubview:rows];
    [NSLayoutConstraint activateConstraints:@[
        [rows.leadingAnchor constraintEqualToAnchor:box.contentView.leadingAnchor constant:14],
        [rows.trailingAnchor constraintEqualToAnchor:box.contentView.trailingAnchor constant:-14],
        [rows.topAnchor constraintEqualToAnchor:box.contentView.topAnchor constant:12],
        [rows.bottomAnchor constraintEqualToAnchor:box.contentView.bottomAnchor constant:-12]
    ]];
    return rows;
}

- (void)connect:(NSControl *)control key:(NSString *)key {
    control.identifier = key;
    control.accessibilityIdentifier = key;
    control.target = self;
    control.action = @selector(changed:);
    _controls[key] = control;
}
- (void)changed:(NSControl *)control {
    NSInteger value = control.integerValue;
    if ([control isKindOfClass:NSPopUpButton.class]) value = ((NSPopUpButton *)control).indexOfSelectedItem;
    if (self.onChange) self.onChange(control.identifier, value);
}
- (NSButton *)check:(NSString *)title key:(NSString *)key in:(NSStackView *)rows {
    NSButton *button = [NSButton checkboxWithTitle:title target:nil action:NULL];
    [self connect:button key:key];
    [rows addArrangedSubview:button];
    return button;
}
- (void)shortcut:(NSString *)title keys:(NSString *)keys key:(NSString *)key in:(NSStackView *)rows {
    NSButton *button = [NSButton checkboxWithTitle:title target:nil action:NULL];
    [self connect:button key:key];
    NSTextField *chord = [NSTextField labelWithString:keys];
    chord.textColor = NSColor.secondaryLabelColor;
    button.accessibilityHelp = keys;
    NSStackView *pair = [NSStackView stackViewWithViews:@[button, chord]];
    pair.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    pair.alignment = NSLayoutAttributeCenterY;
    pair.distribution = NSStackViewDistributionEqualSpacing;
    pair.spacing = 12;
    [rows addArrangedSubview:pair];
    [pair.widthAnchor constraintEqualToAnchor:rows.widthAnchor].active = YES;
}
- (void)picker:(NSString *)label key:(NSString *)key choices:(NSArray<NSString *> *)choices in:(NSStackView *)rows {
    NSTextField *name = [NSTextField labelWithString:label];
    NSPopUpButton *picker = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [picker addItemsWithTitles:choices];
    picker.accessibilityLabel = label;
    [self connect:picker key:key];
    NSStackView *pair = [NSStackView stackViewWithViews:@[name, picker]];
    pair.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    pair.alignment = NSLayoutAttributeCenterY;
    pair.distribution = NSStackViewDistributionEqualSpacing;
    pair.spacing = 12;
    [rows addArrangedSubview:pair];
    [pair.widthAnchor constraintEqualToAnchor:rows.widthAnchor].active = YES;
}
- (void)button:(NSString *)title key:(NSString *)key in:(NSStackView *)rows {
    NSButton *button = [NSButton buttonWithTitle:title target:nil action:NULL];
    [self connect:button key:key];
    [rows addArrangedSubview:button];
}
- (void)note:(NSString *)text key:(NSString *)key in:(NSStackView *)rows {
    NSTextField *note = [NSTextField wrappingLabelWithString:text];
    note.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    note.textColor = NSColor.secondaryLabelColor;
    note.maximumNumberOfLines = 0;
    [rows addArrangedSubview:note];
    [note.widthAnchor constraintEqualToAnchor:rows.widthAnchor].active = YES;
    if (key) _notes[key] = note;
}

- (void)buildPanes {
    NSStackView *page = [self newPane];
    NSStackView *rows = [self group:@"App switcher" inPane:page];
    [self picker:@"⌘Tab mode" key:@"scope"
         choices:@[@"macOS · All apps", @"Macdows · This desktop", @"Macdows · All desktops"] in:rows];
    [self note:@"Choose a Macdows mode to customize the switcher." key:@"switcher" in:rows];
    rows = [self group:@"Macdows switcher" inPane:page];
    [self picker:@"Display" key:@"display"
         choices:@[@"App icons", @"One preview per app", @"One preview per window"] in:rows];
    [self button:@"Screen Recording Settings…" key:@"previewAccess" in:rows];
    [self note:@"Window previews use Screen Recording access." key:@"preview" in:rows];
    [self check:@"Hide Finder when it has no windows" key:localSwitcherHideFinderKey in:rows];
    [self note:@"This desktop already excludes apps without a window here." key:@"finder" in:rows];

    page = [self newPane];
    rows = [self group:@"Window buttons" inPane:page];
    [self picker:@"Red button" key:@"redMode"
         choices:@[@"Close the window", @"Quit after the last window closes", @"Quit when closing any window"] in:rows];
    [self check:@"Keep menu-bar and background apps running" key:backgroundKey in:rows];
    [self note:@"Applies when the red button quits an app." key:@"red" in:rows];
    [self check:@"Fill or restore with the green button" key:greenKey in:rows];
    NSButton *normal = [self check:@"Option-click for the standard single-window action" key:optionClickKey in:rows];
    normal.toolTip = @"Applies to Macdows red and green buttons and to the yellow minimize button.";
    rows = [self group:@"Move & resize" inPane:page];
    [self shortcut:@"Move a window by dragging anywhere" keys:@"⌃⌥Drag" key:dragKey in:rows];
    [self shortcut:@"Tile left or right" keys:@"⌃← / ⌃→" key:snapKey in:rows];
    [self shortcut:@"Arrange, fill or restore" keys:@"⌃⌥Arrows" key:arrangeKey in:rows];
    [self note:@"Tiling and arranging require macOS 15. Control–Option–Left or Right arranges two windows, Up fills, and Down restores." key:nil in:rows];

    rows = [self group:@"Switch windows & desktops" inPane:page];
    [self shortcut:@"Cycle windows in the current app" keys:@"⌘`" key:cycleKey in:rows];
    [self note:@"Uses the physical key above Tab in any keyboard layout. Add Shift to go backward." key:nil in:rows];
    [self shortcut:@"Switch desktops" keys:@"⌃⇧⌥← / ⌃⇧⌥→" key:desktopKey in:rows];
    [self note:@"Switches when you release the keys. Uses Automation access to System Events." key:nil in:rows];
    page = [self newPane];
    rows = [self group:@"Globe key" inPane:page];
    [self picker:@"Use Globe / Fn as" key:@"globe"
         choices:@[@"Standard Globe / Fn", @"Option ⌥", @"Command ⌘", @"Control ⌃"] in:rows];
    rows = [self group:@"Switch keyboard layouts" inPane:page];
    [self check:@"Globe + Shift" key:globeShiftKey in:rows];
    [self check:@"Option + Space" key:languageKey in:rows];

    page = [self newPane];
    rows = [self group:@"When activating an app" inPane:page];
    [self check:@"Restore one window if all windows are minimized" key:restoreKey in:rows];
    [self check:@"Open a Finder window if none are open" key:finderKey in:rows];
    [self check:@"Open a window in other apps if none are open" key:otherAppsKey in:rows];
    [self note:@"Opening Finder windows uses Automation access to Finder." key:nil in:rows];
    rows = [self group:@"Finder files" inPane:page];
    [self shortcut:@"Cut and move files" keys:@"⌘X, ⌘V" key:fileCutKey in:rows];

    page = [self newPane];
    rows = [self group:@"Startup & menu bar" inPane:page];
    [self check:@"Launch at login" key:@"login" in:rows];
    [self note:@"Available on macOS 13 or later." key:@"login" in:rows];
    [self button:@"Login Items Settings…" key:@"loginSettings" in:rows];
    [self check:@"Show the menu bar icon" key:@"menuIcon" in:rows];
    [self note:@"Opening Macdows again restores the icon." key:nil in:rows];
    rows = [self group:@"Accessibility" inPane:page];
    [self note:@"Macdows uses Accessibility access to manage windows and keyboard shortcuts." key:@"accessibility" in:rows];
    [self button:@"Accessibility Settings…" key:@"accessibility" in:rows];
    rows = [self group:@"Help" inPane:page];
    [self button:@"Macdows website" key:@"website" in:rows];
}
@end
