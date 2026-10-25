#!/bin/bash
# Installs ScreenSwitch by building it from source. Because the app is built on your
# own Mac, macOS shows no "unverified developer" warning.
#
#   curl -fsSL https://raw.githubusercontent.com/aspirebrian-lab/ScreenSwitch/main/install.sh | bash
set -euo pipefail

TARBALL_URL="${SCREENSWITCH_TARBALL_URL:-https://github.com/aspirebrian-lab/ScreenSwitch/archive/refs/heads/main.tar.gz}"

if [[ "$(uname)" != "Darwin" ]]; then
    echo "ScreenSwitch only runs on macOS." >&2
    exit 1
fi

if ! xcode-select -p >/dev/null 2>&1; then
    echo "The Xcode Command Line Tools are required to build ScreenSwitch."
    echo "Install them with:  xcode-select --install"
    echo "then run this command again."
    exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "Downloading ScreenSwitch…"
curl -fsSL "$TARBALL_URL" | tar -xz -C "$WORK" --strip-components=1

echo "Building…"
"$WORK/build.sh"

open /Applications/ScreenSwitch.app
echo
echo "ScreenSwitch is installed and running (menu bar icon)."
echo "Grant it access under System Settings → Privacy & Security → Accessibility."
