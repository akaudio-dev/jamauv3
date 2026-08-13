#!/bin/bash
# Build a signed, notarized release of Jam AUv3 for direct distribution.
#
# One-time setup:
#   1. Create a "Developer ID Application" certificate at
#      https://developer.apple.com/account/resources/certificates (download and
#      double-click to install, or add via Xcode → Settings → Accounts).
#   2. Store notarization credentials (uses an app-specific password from
#      https://account.apple.com):
#        xcrun notarytool store-credentials notary \
#          --apple-id <apple-id-email> --team-id 66U677JDPM
#
# Usage: ./make-release.sh [version]   (version defaults to MARKETING_VERSION)
set -euo pipefail

cd "$(dirname "$0")"

TEAM_ID="66U677JDPM"
NOTARY_PROFILE="notary"
SCHEME="jamauv3"
APP_NAME="Jam AUv3"

OUT_DIR="dist"
ARCHIVE="$OUT_DIR/jamauv3.xcarchive"
EXPORT_DIR="$OUT_DIR/export"

VERSION="${1:-$(sed -n 's/.*MARKETING_VERSION = \([^;]*\);.*/\1/p' jamauv3.xcodeproj/project.pbxproj | head -1)}"
DMG="$OUT_DIR/JamAUv3-$VERSION.dmg"

rm -rf "$ARCHIVE" "$EXPORT_DIR" "$DMG"
mkdir -p "$OUT_DIR"

echo "==> Archiving $VERSION..."
xcodebuild archive \
    -scheme "$SCHEME" \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates \
    -quiet

echo "==> Exporting with Developer ID signing..."
EXPORT_PLIST=$(mktemp -t exportOptions).plist
cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>$TEAM_ID</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_PLIST" \
    -allowProvisioningUpdates
rm -f "$EXPORT_PLIST"

APP="$EXPORT_DIR/$APP_NAME.app"
[ -d "$APP" ] || { echo "ERROR: export product not found at $APP"; exit 1; }

echo "==> Verifying code signature..."
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Building DMG..."
STAGING=$(mktemp -d)
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"

echo "==> Notarizing (this can take a few minutes)..."
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling..."
xcrun stapler staple "$DMG"

echo "==> Gatekeeper check..."
spctl --assess --type open --context context:primary-signature -v "$DMG" || true

echo "Done: $DMG"
