#!/bin/bash
# v1.9.3 RELEASE DMG — package + notarize + staple the already-exported, signed app.
# (Claude's sandbox can't run hdiutil/notarytool — run this yourself, then hand back.)
#   bash make_release_dmg.sh
set -e
cd "$(dirname "$0")"

APP="build/export/CoachCam.app"
DMG="CoachCam-v1.9.3.dmg"

[ -d "$APP" ] || { echo "✗ $APP missing — re-run the export first"; exit 1; }
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
[ "$BUILD" = "63" ] || { echo "✗ exported app is build $BUILD, expected 63"; exit 1; }

echo "→ Packaging $DMG…"
rm -rf build/dmg-root && mkdir -p build/dmg-root
ditto "$APP" build/dmg-root/CoachCam.app
ln -s /Applications build/dmg-root/Applications
rm -f "$DMG"
hdiutil create -volname "CoachCam" -srcfolder build/dmg-root -ov -format UDZO "$DMG"
rm -rf build/dmg-root

echo "→ Notarizing (waits for Apple)…"
xcrun notarytool submit "$DMG" --keychain-profile notary --wait

echo "→ Stapling…"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo ""
echo "✓ $DMG ready (v1.9.3 build 63, notarized + stapled)"
echo "  Now tell Claude it's done — it will sign for Sparkle, update the appcast,"
echo "  publish the GitHub release, and push."
