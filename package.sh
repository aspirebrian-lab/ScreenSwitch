#!/bin/zsh
# Maakt dist/ScreenSwitch-<versie>.dmg: een installer waarin de gebruiker de app
# naar Programma's sleept.
#
# Voor publieke distributie (zonder Gatekeeper-waarschuwing) is nodig:
#   - een "Developer ID Application"-certificaat (Apple Developer Program)
#   - notarisatie. Eenmalig opslaan van je inloggegevens:
#       xcrun notarytool store-credentials screenswitch-notary
#     en daarna draaien met:  NOTARY_PROFILE=screenswitch-notary ./package.sh
# Zonder die twee werkt de DMG wel, maar moeten gebruikers de app de eerste keer
# openen via rechtsklik → Open.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=${VERSION:-1.0.0}
DIST=dist
APP="$DIST/ScreenSwitch.app"
DMG="$DIST/ScreenSwitch-$VERSION.dmg"

rm -rf "$DIST"
mkdir -p "$DIST"

# 1. App bouwen (zonder te installeren)
APP_OUT="$PWD/$APP" ./build.sh
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"

# 2. Ondertekenen voor distributie
DEV_ID=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')
if [[ -n "$DEV_ID" ]]; then
    echo "Ondertekenen met: $DEV_ID"
    codesign --force --options runtime --timestamp --sign "$DEV_ID" "$APP"
else
    echo "⚠️  Geen Developer ID-certificaat gevonden: de DMG is niet geschikt voor Gatekeeper."
    IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
    codesign --force --sign "${IDENTITY:--}" "$APP"
fi

# 3. DMG maken (app + snelkoppeling naar Programma's)
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "ScreenSwitch" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

# 4. Notariseren (optioneel)
if [[ -n "$DEV_ID" && -n "${NOTARY_PROFILE:-}" ]]; then
    codesign --force --sign "$DEV_ID" --timestamp "$DMG"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

# De losse .app niet laten staan (Launchpad/Spotlight zou hem als tweede kopie tonen)
rm -rf "$APP"

echo "Klaar: $DMG"
shasum -a 256 "$DMG"
