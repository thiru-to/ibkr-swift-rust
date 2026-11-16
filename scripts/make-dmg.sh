#!/bin/bash
# Builds a Release copy of the app and packages it as dist/IBKR-Swift-<version>.dmg.
# Signed ad-hoc (no Developer ID), so recipients must approve it once in
# System Settings → Privacy & Security → "Open Anyway".
set -euo pipefail
cd "$(dirname "$0")/.."

if xcode-select -p | grep -q CommandLineTools; then
    for x in /Applications/Xcode.app /Volumes/2TB/Applications/Xcode.app; do
        [ -d "$x" ] && export DEVELOPER_DIR="$x/Contents/Developer" && break
    done
fi

APP_NAME="IBKR Swift"
BUILD=build/release
STAGE=build/dmg

echo "→ Building Release…"
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
    -derivedDataPath "$BUILD" CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
    build | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true

APP="$BUILD/Build/Products/Release/$APP_NAME.app"
[ -d "$APP" ] || { echo "Build failed; see xcodebuild output."; exit 1; }
codesign --verify --deep --strict "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="dist/IBKR-Swift-$VERSION.dmg"

echo "→ Packaging ${DMG}…"
rm -rf "$STAGE" && mkdir -p "$STAGE" dist
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"

echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
