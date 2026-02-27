#!/bin/bash
# Build and install jamauv3.app into /Applications so the AUv3 extension
# is always available system-wide (in DAWs, etc).
# Also kills stale extension processes and re-registers with pluginkit.
set -euo pipefail

DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData"
BUILD_DIR=$(find "$DERIVED_DATA" -maxdepth 1 -name 'jamauv3-*' -print -quit 2>/dev/null)

if [ -z "$BUILD_DIR" ]; then
    echo "ERROR: No jamauv3 DerivedData found. Build from Xcode first."
    exit 1
fi

APP="$BUILD_DIR/Build/Products/Debug/jamauv3.app"
APPEX="$APP/Contents/PlugIns/jamauv3Extension.appex"
INSTALL_DIR="/Applications"
INSTALLED_APP="$INSTALL_DIR/jamauv3.app"

echo "==> Killing old processes..."
pkill -9 -f jamauv3Extension 2>/dev/null || true
pkill -9 -f "jamauv3.app" 2>/dev/null || true
sleep 0.5

echo "==> Cleaning..."
xcodebuild clean -scheme jamauv3 -destination 'platform=macOS' -quiet 2>&1 | grep -E '^(error:|Clean )' || true

echo "==> Building..."
xcodebuild build -scheme jamauv3 -destination 'platform=macOS' -quiet 2>&1 | grep -E '^(error:|Build )' || true

if [ ! -d "$APP" ]; then
    echo "ERROR: Build product not found at $APP"
    exit 1
fi

echo "==> Installing to $INSTALL_DIR..."
rm -rf "$INSTALLED_APP"
cp -R "$APP" "$INSTALLED_APP"

echo "==> Re-registering extension..."
pluginkit -a "$INSTALLED_APP/Contents/PlugIns/jamauv3Extension.appex" 2>/dev/null || true

echo "==> Verifying..."
pluginkit -m 2>&1 | grep -i jamau || echo "WARNING: Extension not found in pluginkit"

echo "Done. jamauv3.app installed to $INSTALL_DIR."
