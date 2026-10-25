#!/bin/zsh
# Creates dist/ScreenSwitch-<version>.dmg: an installer where the user drags the
# app to Applications.
#
# Distributing without a Gatekeeper warning requires:
#   - a "Developer ID Application" certificate (Apple Developer Program)
#   - notarization. Store your credentials once:
#       xcrun notarytool store-credentials screenswitch-notary
#     then run:  NOTARY_PROFILE=screenswitch-notary ./package.sh
# Without both, the DMG still works, but users must open the app the first time
# via right-click → Open.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=${VERSION:-1.0.0}
DIST=dist
APP="$DIST/ScreenSwitch.app"
DMG="$DIST/ScreenSwitch-$VERSION.dmg"

rm -rf "$DIST"
mkdir -p "$DIST"

# 1. Build the app (without installing)
APP_OUT="$PWD/$APP" ./build.sh
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"

# 2. Sign for distribution
DEV_ID=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')
if [[ -n "$DEV_ID" ]]; then
    echo "Signing with: $DEV_ID"
    codesign --force --options runtime --timestamp --sign "$DEV_ID" "$APP"
else
    echo "⚠️  No Developer ID certificate found: the DMG will not pass Gatekeeper."
    IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
    codesign --force --sign "${IDENTITY:--}" "$APP"
fi

# 3. Create the DMG (app + shortcut to Applications)
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "ScreenSwitch" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

# 4. Notarize (optional)
if [[ -n "$DEV_ID" && -n "${NOTARY_PROFILE:-}" ]]; then
    codesign --force --sign "$DEV_ID" --timestamp "$DMG"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

# Remove the loose .app (Launchpad/Spotlight would show it as a second copy)
rm -rf "$APP"

echo "Done: $DMG"
shasum -a 256 "$DMG"
