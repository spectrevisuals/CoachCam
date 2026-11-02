#!/bin/bash
# Finish the v1.9.4 build-74 TEST DMG (launch-deadlock fix for macOS 15 + prior 27.2/WhatsApp fixes).
# The app is already archived + exported + Developer-ID signed at build/export/CoachCam.app.
# This script only does the steps the Claude sandbox can't (needs Full Disk Access):
#   package DMG -> notarize -> staple -> validate.
# Run from the repo root:  bash make_test_dmg.sh
set -e
cd "$(dirname "$0")"

APP="build/export/CoachCam.app"
DMG="$HOME/Downloads/CoachCam-v1.9.4-test11.dmg"

[ -d "$APP" ] || { echo "✗ $APP missing — re-run the export first"; exit 1; }

echo "→ Packaging DMG…"
rm -rf build/dmg-root && mkdir -p build/dmg-root
ditto "$APP" build/dmg-root/CoachCam.app
ln -s /Applications build/dmg-root/Applications
rm -f "$DMG"
hdiutil create -volname "CoachCam" -srcfolder build/dmg-root -ov -format UDZO "$DMG"
rm -rf build/dmg-root

echo "→ Notarizing (this waits for Apple)…"
xcrun notarytool submit "$DMG" --keychain-profile notary --wait

echo "→ Stapling…"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo ""
echo "✓ Done: $DMG"
echo "  Build: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist") / $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
