#!/bin/bash
# Builds ScanNPrint for Apple silicon and Intel, signs it with a Developer ID certificate and packages
# ScanNPrint-<version>.dmg in mac/dist. Notarizes it too when NOTARY_PROFILE names a profile saved with
#   xcrun notarytool store-credentials <name> --apple-id <apple id> --team-id <team>
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
TEAM="${TEAM_ID:-NRZQU2K9AD}"
BUILD=build/release
DIST=dist

rm -rf "$BUILD"
xcodebuild -project ScanNPrint.xcodeproj -scheme ScanNPrint -configuration Release \
  -derivedDataPath "$BUILD" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" \
  ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS="--timestamp" \
  clean build | grep -E "error:|BUILD"

APP="$BUILD/Build/Products/Release/ScanNPrint.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
lipo -archs "$APP/Contents/MacOS/ScanNPrint"
codesign --verify --strict --deep "$APP"

# Disk image with the app and a shortcut to Applications to drag it onto.
STAGE="$BUILD/dmg"
mkdir -p "$STAGE" "$DIST"
ditto "$APP" "$STAGE/ScanNPrint.app"
ln -s /Applications "$STAGE/Applications"
DMG="$DIST/ScanNPrint-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "ScanNPrint $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
codesign --sign "$IDENTITY" --timestamp "$DMG"

if [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
else
  echo "Not notarized: set NOTARY_PROFILE to notarize, or other Macs will show a security warning."
fi
echo "$DMG"
