#!/bin/bash
# Build a Universal (Apple Silicon + Intel) OpenGallery.app into build/.
#   scripts/bundle.sh            build only
#   scripts/bundle.sh --install  also copy to /Applications and relaunch
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="OpenGallery"
BUNDLE_ID="com.isaacng.gallery-wallpaper"
VERSION="0.1.0"
APP="build/$APP_NAME.app"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/$APP_NAME"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/manifest.json "$APP/Contents/Resources/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>Artwork courtesy National Gallery of Art, Washington (CC0).</string>
</dict>
</plist>
PLIST

# Sign with the local certificate from scripts/make_signing_cert.sh when it
# exists, so privacy permissions survive rebuilds; otherwise ad-hoc, which
# is fine for running on this Mac. Distribution needs a Developer ID
# signature and notarization instead.
SIGN_ID="OpenGallery Local Signing"
if ! security find-identity -v -p codesigning | grep -q "$SIGN_ID"; then
    SIGN_ID="-"
fi
codesign --force --sign "$SIGN_ID" --options runtime "$APP"

echo "Built $APP ($(du -sh "$APP" | cut -f1)) — $(lipo -archs "$APP/Contents/MacOS/$APP_NAME")"

if [ "${1:-}" = "--install" ]; then
    pkill -x "$APP_NAME" 2>/dev/null || true
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" /Applications/
    open "/Applications/$APP_NAME.app"
    echo "Installed and launched /Applications/$APP_NAME.app"
fi
