# Macdows

Free macOS menu-bar utility by Astonio Ltd. Globe+Shift language switching, red-button quit, green-button maximize and restore, and cut-and-move in Finder.

- Publisher: Astonio Ltd (https://astonio.com).
- Version: 1.35 (build 76).
- Optional Macdows Command-Tab switcher can show every real window on the current desktop as a separate preview with its title, hide Finder when it has no windows, and show hidden-item counts at the edges. It is disabled by default. Move the pointer onto a card or use Tab to select it. While the Macdows switcher is open, ⌘W or ⌃W closes the selected window. ⌘Q or ⌃Q quits the selected app, or closes Finder’s windows when Finder is selected.
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

- **1.35 build 76, 24 November 2026.** The switcher tracks the card under a moving pointer. Command or Control with W closes the selected window. With Q, Finder closes its windows and other apps quit. The open list updates as Finder windows close.
- **1.35 build 75, 24 November 2026.** The menu bar opens a single Settings window. Related controls stay together, unavailable options stay visible, and one red-button choice covers closing the window or quitting the app.
- **1.35 build 74, 24 November 2026.** Menu section headings are visually distinct from unavailable commands. On macOS 11–14, unavailable tiling shortcuts no longer count as active.
- **1.35 build 73, 24 November 2026.** Switcher mode and desktop scope are chosen together. Dependent settings stay visible in gray within one submenu level. Preview modes check Screen Recording access on startup.
- **1.35 build 70, 24 November 2026.** Added per-window titled previews, edge counts and preview preloading.

[GitHub repository](https://github.com/katlianik/macdows) · [Versioned releases](https://github.com/katlianik/macdows/releases) · [Release feed](https://github.com/katlianik/macdows/releases.atom)

## Where to find a setting

Choose **Settings…** from the Macdows menu in the menu bar.

| Pane | Settings |
| --- | --- |
| Switcher | ⌘Tab mode, desktop scope, icons or previews, empty Finder filtering and Screen Recording for previews. |
| Windows | Cycle app windows, switch desktops, change window button actions, tile and drag windows. |
| Keyboard | Remap Globe/Fn and switch keyboard layouts. |
| Apps & Finder | Restore or reopen windows on activation and move files with ⌘X and ⌘V in Finder. |
| General | Launch at login, menu-bar icon and Accessibility settings. |

For ⌘Tab on the current desktop, choose **Macdows · This desktop** in Switcher. With **Macdows · All desktops**, you can choose whether to hide Finder when it has no windows. **macOS · All apps** uses the system switcher.

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
4. Choose **Settings…** from the Macdows menu. Open Accessibility Settings from **General**, enable the installed copy and reopen Macdows.
5. Allow Automation access to Finder for the empty-Finder feature and to System Events for desktop switching when prompted.

[Install with Homebrew](https://github.com/katlianik/macdows#install-with-homebrew) · [Uninstall Macdows](https://github.com/katlianik/macdows#remove-macdows)

## Common questions

### What is Macdows?

Macdows is a free menu-bar utility for macOS by Astonio Ltd. It brings familiar Windows-style window actions and keyboard habits to a Mac.

### Is Macdows completely free?

Yes. Macdows is free forever, with no subscriptions or hidden fees.

### How do I switch keyboard languages?

Open Settings… from the Macdows menu and choose Keyboard. Enable the Shift shortcut, then press and release Globe+Shift. In the default Globe-to-Option mode, Option+Shift works too. The Space shortcut has its own setting. Add the keyboard layouts you want in macOS Text Input settings.

### What do the red and green buttons do?

In Settings… under Windows, choose whether the red button closes the window, quits after the last window closes (the default), or quits when you close any window. Finder always closes its window. The two quit modes can keep menu-bar and background apps running. The green button fills the desktop and restores the saved size on the next click. On macOS 15 and later it uses native Fill. On earlier versions it resizes the window directly.

### How do cut and paste work in Finder?

Press Command-X on selected files, open the destination in Finder and press Command-V. Macdows invokes Finder’s native move command. The files stay at their source until the move is performed. Finder handles name conflicts and undo.

### Which Macs does Macdows support?

Macdows 1.35 supports Apple silicon and Intel Macs running macOS 11 or later. Launch at Login is available on macOS 13 and later.

### How do I install Macdows?

Quit any running copy, open the DMG and drag Macdows to Applications. Open the installed app and choose Settings… from its menu bar icon. In General, open Accessibility Settings and enable Macdows. If you use the optional previews, allow Screen Recording in Switcher. macOS may also ask for Automation access to Finder for opening a Finder window, or to System Events for desktop switching.


## Window keyboard shortcuts

- Control+Shift+Option+Left/Right: release the keys to switch to the adjacent macOS desktop through the standard Mission Control action. Globe/Fn also works in place of Control when Macdows maps Globe/Fn to Control.
- Control+Left/Right: native macOS Move & Resize, placing the active window on the left or right half at full working height.
- Control+Option+Left/Right: native macOS Arrange, placing the active window on the chosen half and a second eligible window on the other half. macOS selects the second window.
- Control+Option+Up: fill the desktop and remember the previous size. Control+Option+Down: restore the saved size, sharing history with the green button. A large window without a useful smaller restore size becomes 80% of the desktop width and height, via Down or the green button. Repeated presses keep the size stable. Restore affects the active window, not both windows together.
- Both arrow-shortcut options are independent, enabled by default, and require macOS 15 or later. Left/Right requires native tiling support and follows macOS tiling margins and application minimum sizes. Up and the green button use native Fill on macOS 15+. Down restores the size saved before the placement sequence and centers the window using its actual accepted size. Native commands run without opening menus, using system App Shortcuts installed by Macdows. Reopen other apps after installing this update so they load the shortcuts. New actions replace pending actions; no delayed resize retries run in the background. All actions respect window size limits. Disable Control+Left/Right to retain Space switching.
- Command-Grave cycles the current app’s standard, non-minimized windows in a stable circular order. Add Shift to go backwards. Uses the physical key above Tab on standard Mac keyboards, independently of the active layout.
- Optional Command-Tab replacement shows each real window on the current desktop as a separate titled preview. It can hide Finder when Finder has no windows, delays its panel for quick switches, caches and preloads previews, and shows how many items are hidden beyond either edge. Move the pointer onto a card or use Tab to select it. While the Macdows switcher is open, ⌘W or ⌃W closes the selected window. ⌘Q or ⌃Q quits the selected app, or closes Finder’s windows when Finder is selected. The replacement is disabled by default, so macOS handles Command-Tab until it is enabled.
