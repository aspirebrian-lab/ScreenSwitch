# ScreenSwitch

A small macOS menu bar app that fixes the "first click only focuses" behavior of macOS.
When you click a window that belongs to a different app, the click is performed right away, just like on Windows.

## Installation

**Using the installer (recommended)**
1. Download the latest `ScreenSwitch-x.y.z.dmg` from [Releases](../../releases).
2. Open the DMG and drag ScreenSwitch to Applications.
3. Launch the app and grant access under System Settings → Privacy & Security → Accessibility.

> If the DMG is not notarized, macOS shows a warning. In that case, open the app once
> via right-click → Open.

**From source** (requires the Xcode Command Line Tools)
```bash
git clone <this-repo>
cd ScreenSwitch
./build.sh        # builds and installs to /Applications
```

## Building an installer
```bash
VERSION=1.0.0 ./package.sh
```
The result is placed in `dist/`. A DMG without a Gatekeeper warning requires a
Developer ID certificate and notarization; see the notes at the top of [package.sh](package.sh).

## Settings
Click the menu bar icon → **Settings…** to adjust the delay (0–500 ms) before the second click
with a slider. The default is 120 ms.

## Launch at login
System Settings → General → Login Items → **+** → ScreenSwitch.

## How it works
An event tap watches left mouse clicks. If the window under the cursor belongs to an inactive app,
ScreenSwitch lets that click through (macOS focuses the app) and sends the same click again
~0.12 s later. Drags are ignored.
