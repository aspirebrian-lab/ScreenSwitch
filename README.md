# ScreenSwitch

A small macOS menu bar app that fixes the "first click only focuses" behavior of macOS.
When you click a window that belongs to a different app, the click is performed right away, just like on Windows.

## Installation

Run this in the Terminal (requires the Xcode Command Line Tools, install them with `xcode-select --install`):

```bash
curl -fsSL https://raw.githubusercontent.com/aspirebrian-lab/ScreenSwitch/main/install.sh | bash
```

This downloads the source of the [latest release](https://github.com/aspirebrian-lab/ScreenSwitch/releases/latest),
builds the app on your Mac and installs it to `/Applications`.
Because it is built locally, macOS shows no "unverified developer" warning.

Then grant access under System Settings → Privacy & Security → Accessibility.

**Manually**
```bash
git clone https://github.com/aspirebrian-lab/ScreenSwitch.git
cd ScreenSwitch
./build.sh        # builds and installs to /Applications
```

To update, run the install command again. You may need to re-grant the Accessibility permission.
See [Releases](https://github.com/aspirebrian-lab/ScreenSwitch/releases) for what changed in each version.

## Settings
Click the menu bar icon → **Settings…** to adjust the delay (0–500 ms) before the second click
with a slider. The default is 120 ms.

## Excluded apps
Some apps (System Settings, for example) already act on the very first click themselves. Replaying
the click there would toggle a control twice. Such apps can be excluded: choose
**Don't replay clicks in …** from the menu bar icon while that app is in front, or manage the list
under **Settings…**. System Settings is excluded by default.

## Smooth scrolling
Mouse wheels scroll in steps on macOS. Turn on **Smooth Scrolling** in the menu bar (or in
Settings) to get eased, trackpad-like scrolling. The *Smoothness* slider sets how long the glide lasts.
Trackpad scrolling and scrolling with ⌘/⌃/⌥ held are left untouched.

By default the glide stops as soon as the cursor moves onto another app, so it never scrolls
that app. Turn on **Keep gliding in the original window** in Settings to let the glide finish in
the window you scrolled, even after the cursor leaves it. This sends the glide as a trackpad-style
gesture, so pages can briefly stretch past their edges (rubber-banding), just like with a trackpad.

## Launch at login
System Settings → General → Login Items → **+** → ScreenSwitch.

## How it works
An event tap watches left mouse clicks. If the window under the cursor belongs to an inactive app,
ScreenSwitch lets that click through (macOS focuses the app) and sends the same click again
~0.12 s later (adjustable), but only if the click really changed the focused app. Drags are ignored.

## License
MIT, see [LICENSE](LICENSE).
