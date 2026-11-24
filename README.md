# Macdows

Macdows is a free macOS menu-bar utility from Astonio Ltd. Cycle through windows using the physical key above Tab in any keyboard layout, or use ⌘Tab to switch between windows on the current desktop. Each feature has its own setting.

[Download for Mac](https://astonio.com/lab/macdows/Macdows.dmg) · [Website](https://astonio.com/lab/macdows/index.html) · [Release notes](https://github.com/katlianik/macdows/releases) · [Release feed](https://github.com/katlianik/macdows/releases.atom) · [Report a problem](https://github.com/katlianik/macdows/issues)

## Get started

1. On an Intel or Apple silicon Mac running macOS 11 or later, open the DMG and drag Macdows into Applications. Quit any running copy before updating.
2. Open Macdows and grant Accessibility access for keyboard and window controls.
3. Open **⌘Tab Switcher** from the menu bar. Choose **Macdows · This Desktop** to limit the list to windows on your current desktop. Choose icons or previews underneath. Screen Recording access is needed for previews. The default **macOS · All Apps** uses the system switcher.

Other features include Globe/Fn language shortcuts, optional red-click quit and green-click fill/restore, and cut-and-move in Finder. Window tiling shortcuts require macOS 15 or later. [All features and shortcuts](https://astonio.com/lab/macdows/index.html#features)

For a bug report, include your macOS version, Macdows build, relevant menu choices, and the shortest steps that reproduce the issue.

## Install with Homebrew

If you use Homebrew, add the project’s tap and install the cask:

```sh
brew tap katlianik/macdows https://github.com/katlianik/macdows
brew install --cask katlianik/macdows/macdows
```

For later releases, run `brew update` and `brew upgrade --cask katlianik/macdows/macdows`.

## Requirements

- macOS with Xcode 27 or later
- Apple clang
- macOS 11 deployment target or later

## Build and test

Compile the AppleScript resources first:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
mkdir -p Macdows.app/Contents/MacOS
osacompile -o Macdows.app/Contents/Resources/OpenEmptyFinder.scpt Macdows.app/Contents/Resources/OpenEmptyFinder.applescript
osacompile -o Macdows.app/Contents/Resources/SwitchDesktopLeft.scpt Macdows.app/Contents/Resources/SwitchDesktopLeft.applescript
osacompile -o Macdows.app/Contents/Resources/SwitchDesktopRight.scpt Macdows.app/Contents/Resources/SwitchDesktopRight.applescript
```

Compile a universal executable:

```sh
xcrun clang -fobjc-arc -fblocks -mmacosx-version-min=11.0 -arch arm64 -arch x86_64 \
  Macdows.app/Contents/Resources/Macdows.m -o Macdows.app/Contents/MacOS/Macdows \
  -framework Cocoa -framework ServiceManagement -framework IOKit \
  -framework Carbon -framework ApplicationServices
```

Run the regression tests:

```sh
xcrun clang -fobjc-arc -fblocks -mmacosx-version-min=11.0 test.m -o test \
  -framework Cocoa -framework ServiceManagement -framework IOKit \
  -framework Carbon -framework ApplicationServices
./test
```

Signing and notarization are intentionally not part of the source archive.
