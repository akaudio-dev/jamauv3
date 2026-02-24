#!/bin/bash
# Build, re-register the AUv3 extension, and launch the host app.
# Prevents the "stale bits" problem where macOS loads a cached extension.
set -euo pipefail

DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData"
BUILD_DIR=$(find "$DERIVED_DATA" -maxdepth 1 -name 'jamauv3-*' -print -quit 2>/dev/null)

if [ -z "$BUILD_DIR" ]; then
    echo "ERROR: No jamauv3 DerivedData found. Build from Xcode first."
    exit 1
fi

APP="$BUILD_DIR/Build/Products/Debug/jamauv3.app"
APPEX="$APP/Contents/PlugIns/jamauv3Extension.appex"

echo "==> Killing old processes..."
pkill -9 -f jamauv3Extension 2>/dev/null || true
pkill -9 -f jamauv3.app 2>/dev/null || true
sleep 0.5

# Remove /Applications copy if it exists (conflicts with DerivedData registration)
if [ -d "/Applications/jamauv3.app" ]; then
    echo "==> Removing /Applications/jamauv3.app (avoids pluginkit conflict)..."
    pluginkit -r "/Applications/jamauv3.app/Contents/PlugIns/jamauv3Extension.appex" 2>/dev/null || true
    rm -rf "/Applications/jamauv3.app"
fi

echo "==> Building..."
xcodebuild build -scheme jamauv3 -destination 'platform=macOS' -quiet 2>&1 | grep -E '^(error:|Build )' || true

echo "==> Re-registering extension..."
pluginkit -a "$APPEX" 2>/dev/null || true

echo "==> Launching..."
open "$APP"
echo "Done."
