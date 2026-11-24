# Macdows

Free macOS menu-bar utility by Astonio Ltd. Globe+Shift language switching, red-button quit, green-button maximize and restore, and cut-and-move in Finder.

- Publisher: Astonio Ltd (https://astonio.com).
- Version: 1.35 (build 73).
- Optional Macdows Command-Tab switcher can show every real window on the current desktop as a separate preview with its title, hide Finder when it has no windows, and show hidden-item counts at the edges. It is disabled by default. While the panel is open, Command-W closes the selected window and Command-Q quits the selected app; for Finder, Command-Q closes all Finder windows.
- Control-Shift-Option-Left/Right switches to the adjacent macOS desktop after the keys are released. Globe/Fn can be used instead of Control when Macdows maps Globe/Fn to Control.
- Command-Grave cycles through the current app’s standard windows in either direction, including across the last/first boundary. Add Shift to go backwards. The shortcut uses the physical key across keyboard layouts.
- Price: free forever; no subscriptions or hidden fees.
- Requirements: macOS 11 or later, Apple silicon or Intel.
- Distribution: Developer ID signed by Astonio Ltd and notarized by Apple.
- Last updated: 2026-11-24.

[Official product page](https://astonio.com/lab/macdows/index.html)
[Download Macdows.dmg](https://astonio.com/lab/macdows/Macdows.dmg)
[Download source code](https://astonio.com/lab/macdows/Macdows-1.35-source.zip)

## Release notes

- **1.35 build 73, 24 November 2026.** Switcher mode and desktop scope are chosen together. Dependent settings stay visible in gray within one submenu level. Preview modes check Screen Recording access on startup.
- **1.35 build 70, 24 November 2026.** Added per-window titled previews, edge counts and preview preloading.

[GitHub repository](https://github.com/katlianik/macdows) · [Versioned releases](https://github.com/katlianik/macdows/releases) · [Release feed](https://github.com/katlianik/macdows/releases.atom)

## Features

- Red-button quit with an optional last-window-only rule; Finder uses its normal close action. Background agents and apps exposing their menu-bar icon keep running by default.
- Green-button fill and restore of the usable desktop.
- Option-click for the standard window-button action.
- Globe/Fn remapping to Option, Command or Control; normal Globe mode is also available.
- Globe+Shift language switching, independent of the Space shortcut.
- Globe-Space / Option-Space language switching, with behavior depending on Globe mode.
- Command-X followed by Command-V to invoke native Finder file moving.
- Restore one minimized window when returning to an app whose windows are all minimized.
- Open a window when switching to an empty Finder; optionally request a window in other apps that support reopening.
- Optional Control-Option-drag to move a window from inside it.
- Launch at Login on macOS 13 or later.
- Hide the menu-bar icon and restore it by opening Macdows again; the icon also returns on every launch.

## Language shortcuts

Shift and Space alternatives are independent settings. Globe-Shift starts enabled and switches on release. Adding another key cancels that switch. With Globe remapped, the corresponding physical modifier+Shift also switches.

| Globe mode | Shift alternative | Space alternative |
| --- | --- | --- |
| Option (default) | Option+Shift or Globe+Shift | Option+Space or Globe+Space |
| Control | Control+Shift or Globe+Shift | Control+Space, Globe+Space or Option+Space |
| Command | Command+Shift or Globe+Shift | Option+Space |
| Normal Globe | Globe+Shift | Globe+Space or Option+Space |

In Command mode, Globe-Space follows macOS Command-Space. Input source switching requires keyboard layouts configured in macOS.

## Installation

1. Quit an older Macdows or RedQuit copy.
2. Open Macdows.dmg and drag Macdows.app to Applications.
3. Open Macdows from Applications.
4. Enable Accessibility / Device Control permission for the installed copy, then reopen it.
5. Allow Automation access to Finder for the empty-Finder feature and to System Events for desktop switching when prompted.

## Common questions

### What is Macdows?

Macdows is a free menu-bar utility for macOS by Astonio Ltd. It brings familiar Windows-style window actions and keyboard habits to a Mac.

### Is Macdows completely free?

Yes. Macdows is free forever, with no subscriptions or hidden fees.

### How do I switch keyboard languages?

Enable Globe-Shift in Globe Key & Language, then press and release Globe+Shift. Globe-Space is a separate alternative. Choose your keyboard layouts in macOS Text Input settings. In the default Globe-to-Option mode, Option+Shift also switches layouts.

### What do the red and green buttons do?

The red button quits the app, with quit-only-on-last-window enabled by default. Finder keeps its standard close behavior. Declared background apps and apps exposing their own menu-bar icon close normally and keep running; this protection is enabled by default and can be switched off. The green button uses native Fill on macOS 15+ and restores the size saved before the placement sequence and centers the window when clicked again. Earlier macOS versions use direct resizing. Manually changing the window starts a new placement sequence. An initially large window without a useful smaller restore size is centered at 80% of the desktop width and height.

### How do cut and paste work in Finder?

Press Command-X on selected files, open the destination in Finder and press Command-V. Macdows invokes Finder’s native move command. The files stay at their source until the move is performed. Finder handles name conflicts and undo.

### Which Macs does Macdows support?

Macdows 1.35 supports Apple silicon and Intel Macs running macOS 11 or later. Launch at Login is available on macOS 13 and later.

### How do I install Macdows?

Download Macdows.dmg, quit an older copy, drag Macdows.app into Applications and open it there. Enable its Accessibility or Device Control permission in macOS. Allow Automation access to Finder for the empty-Finder feature and to System Events for desktop switching when prompted.


## Window keyboard shortcuts

- Control+Shift+Option+Left/Right: release the keys to switch to the adjacent macOS desktop through the standard Mission Control action. Globe/Fn also works in place of Control when Macdows maps Globe/Fn to Control.
- Control+Left/Right: native macOS Move & Resize, placing the active window on the left or right half at full working height.
- Control+Option+Left/Right: native macOS Arrange, placing the active window on the chosen half and a second eligible window on the other half. macOS selects the second window.
- Control+Option+Up: fill the desktop and remember the previous size. Control+Option+Down: restore the saved size, sharing history with the green button. A large window without a useful smaller restore size becomes 80% of the desktop width and height, via Down or the green button. Repeated presses keep the size stable. Restore affects the active window, not both windows together.
- Both arrow-shortcut options are independent, enabled by default, and require macOS 15 or later. Left/Right requires native tiling support and follows macOS tiling margins and application minimum sizes. Up and the green button use native Fill on macOS 15+. Down restores the size saved before the placement sequence and centers the window using its actual accepted size. Native commands run without opening menus, using system App Shortcuts installed by Macdows. Reopen other apps after installing this update so they load the shortcuts. New actions replace pending actions; no delayed resize retries run in the background. All actions respect window size limits. Disable Control+Left/Right to retain Space switching.
- Command-Grave cycles the current app’s standard, non-minimized windows in a stable circular order. Add Shift to go backwards. Uses the physical key above Tab on standard Mac keyboards, independently of the active layout.
- Optional Command-Tab replacement shows each real window on the current desktop as a separate titled preview. It can hide Finder when Finder has no windows, delays its panel for quick switches, caches and preloads previews, and shows how many items are hidden beyond either edge. Command-W closes the selected window; Command-Q quits the selected app, or closes every Finder window when Finder is selected. The replacement is disabled by default, so macOS handles Command-Tab until it is enabled.
