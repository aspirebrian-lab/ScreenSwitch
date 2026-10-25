#!/bin/zsh
# Builds ScreenSwitch.app in a temp folder and installs it to /Applications
# (so only one copy exists for Launchpad/Spotlight to find).
set -euo pipefail
cd "$(dirname "$0")"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/ScreenSwitch.app"
mkdir -p "$APP/Contents/MacOS"

swiftc -O main.swift -o "$APP/Contents/MacOS/ScreenSwitch"

# Icon: draw a 1024px PNG and turn it into an .icns
ICONSET="$WORK/Icon.iconset"
mkdir -p "$ICONSET"
swiftc -O make-icon.swift -o "$WORK/make-icon"
"$WORK/make-icon" "$ICONSET/base.png"
for s in 16 32 128 256 512; do
    sips -z $s $s "$ICONSET/base.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$ICONSET/base.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
rm "$ICONSET/base.png"
mkdir -p "$APP/Contents/Resources"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Icon.icns"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>ScreenSwitch</string>
    <key>CFBundleIdentifier</key><string>com.personal.screenswitch</string>
    <key>CFBundleExecutable</key><string>ScreenSwitch</string>
    <key>CFBundleIconFile</key><string>Icon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

# Sign with a stable identity so the Accessibility permission survives rebuilds
# (an ad-hoc signature changes on every build).
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$APP"

pkill -x ScreenSwitch || true
rm -rf /Applications/ScreenSwitch.app
cp -R "$APP" /Applications/
echo "Installed: /Applications/ScreenSwitch.app"
