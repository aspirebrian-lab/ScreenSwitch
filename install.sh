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

# Install the latest release, asked from the GitHub API.
# Falls back to the main branch if there is no release (or the API can't be reached).
if [[ -n "${SCREENSWITCH_TARBALL_URL:-}" ]]; then
    TARBALL_URL="$SCREENSWITCH_TARBALL_URL"
    VERSION="custom"
else
    VERSION=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
        | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1 || true)
    if [[ -n "$VERSION" ]]; then
        TARBALL_URL="https://github.com/$REPO/archive/refs/tags/$VERSION.tar.gz"
        export SCREENSWITCH_VERSION="$VERSION"  # the downloaded source has no git history
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
