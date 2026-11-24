#!/bin/bash
# Finish the v1.9.5 build-84 TEST DMG (adds: Sentry crash + error reporting; webcam-only + float cam black-video fix).
# The app is already archived + exported + Developer-ID signed at build/export/CoachCam.app.
# This script only does the steps the Claude sandbox can't (needs Full Disk Access):
#   package DMG -> notarize -> staple -> validate -> save + upload the debug symbols.
# Run it in Terminal (works from any folder):
#   bash /Users/jake/Documents/ClaudeCode/CoachCap/make_test_dmg.sh
#
# It stops before packaging if the exported app is not build 84, or if it has no Sentry DSN
# (such a build could never report a crash). To package a build without a DSN on purpose:
#   ALLOW_NO_DSN=1 bash /Users/jake/Documents/ClaudeCode/CoachCap/make_test_dmg.sh
set -e
cd "$(dirname "$0")"

APP="build/export/CoachCam.app"
DSYMS="build/CoachCam.xcarchive/dSYMs"
BUILD="84"
DMG="$HOME/Downloads/CoachCam-v1.9.5-test15.dmg"

[ -d "$APP" ] || { echo "✗ $PWD/$APP is missing — ask Claude to archive + export the app first"; exit 1; }
[ -f Scripts/release_common.sh ] || { echo "✗ $PWD/Scripts/release_common.sh is missing — cannot check the build"; exit 1; }
. Scripts/release_common.sh

require_build "$APP" "$BUILD"
require_sentry_dsn "$APP"

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

# The DMG is finished at this point; nothing below can stop the script.
save_and_upload_dsyms "$APP" "$DSYMS" || true

echo ""
echo "✓ Done: $DMG"
echo "  Build: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist") / $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
