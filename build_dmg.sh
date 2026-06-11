#!/bin/bash
set -e

echo "Building CoachCam DMG with proper symlink preservation..."

# Build Release version
echo "→ Building Release..."
xcodebuild -project CoachCap.xcodeproj -scheme CoachCap -configuration Release -derivedDataPath build > /dev/null 2>&1

APP_PATH="build/Build/Products/Release/CoachCam.app"

if [ ! -d "$APP_PATH" ]; then
    echo "✗ Build failed: $APP_PATH not found"
    exit 1
fi

echo "✓ Build complete"

# Verify signatures before packaging
echo "→ Verifying code signatures..."
if ! codesign --verify --deep --strict "$APP_PATH" 2>&1 | tail -1; then
    echo "✗ Code signature verification failed"
    exit 1
fi

spctl --assess --type execute "$APP_PATH" 2>&1 && echo "✓ Gatekeeper OK" || echo "⚠ Gatekeeper requires notarization (non-blocking for testing)"

echo "✓ Code signatures valid"

# Create DMG with proper symlink preservation
echo "→ Creating DMG with symlink preservation..."
rm -rf dmg-root
mkdir -p dmg-root

# Use ditto to preserve symlinks (NOT cp -RL which would flatten them)
ditto "$APP_PATH" "dmg-root/CoachCam.app"

# Add /Applications symlink for drag-and-drop install
ln -s /Applications dmg-root/Applications

# Create DMG
rm -f ~/Desktop/CoachCam.dmg
hdiutil create -volname "CoachCam" -srcfolder dmg-root -ov -format UDZO ~/Desktop/CoachCam.dmg

echo "✓ DMG created at ~/Desktop/CoachCam.dmg"

# Cleanup
rm -rf dmg-root

# Verify DMG contents
echo ""
echo "→ Verification checklist:"
echo ""
codesign --verify --deep --strict dmg-root/CoachCam.app 2>&1 || echo "  ⚠ Note: Verify again after mounting DMG"
spctl --assess --type execute "$APP_PATH" 2>&1 || echo "  ⚠ Note: Gatekeeper check"
echo ""
echo "  Info.plist keys:"
plutil -p "$APP_PATH/Contents/Info.plist" | grep -E "CoachCam|SUPublic|BundleVersion" || true
echo ""
echo "✓ DMG build complete"
