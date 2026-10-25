#!/bin/bash
# Installs ScreenSwitch by building it from source. Because the app is built on your
# own Mac, macOS shows no "unverified developer" warning.
#
#   curl -fsSL https://raw.githubusercontent.com/aspirebrian-lab/ScreenSwitch/main/install.sh | bash
set -euo pipefail

REPO="aspirebrian-lab/ScreenSwitch"

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

# Install the latest release (github.com/<repo>/releases/latest redirects to its tag).
# Falls back to the main branch if there is no release yet.
if [[ -n "${SCREENSWITCH_TARBALL_URL:-}" ]]; then
    TARBALL_URL="$SCREENSWITCH_TARBALL_URL"
    VERSION="custom"
else
    LATEST=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest" || true)
    VERSION="${LATEST##*/tag/}"
    if [[ "$LATEST" == */tag/* && -n "$VERSION" ]]; then
        TARBALL_URL="https://github.com/$REPO/archive/refs/tags/$VERSION.tar.gz"
    else
        VERSION="main"
        TARBALL_URL="https://github.com/$REPO/archive/refs/heads/main.tar.gz"
    fi
fi

echo "Downloading ScreenSwitch ($VERSION)…"
curl -fsSL "$TARBALL_URL" | tar -xz -C "$WORK" --strip-components=1

echo "Building…"
"$WORK/build.sh"

open /Applications/ScreenSwitch.app
echo
echo "ScreenSwitch is installed and running (menu bar icon)."
echo "Grant it access under System Settings → Privacy & Security → Accessibility."
