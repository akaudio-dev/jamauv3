#!/bin/bash
# Build and install Jam AUv3.app into /Applications so the AUv3 extension
# is always available system-wide (in DAWs, etc).
# Also kills stale extension processes and re-registers with pluginkit.
set -euo pipefail

DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData"
BUILD_DIR=$(find "$DERIVED_DATA" -maxdepth 1 -name 'jamauv3-*' -print -quit 2>/dev/null)

if [ -z "$BUILD_DIR" ]; then
    echo "ERROR: No jamauv3 DerivedData found. Build from Xcode first."
    exit 1
fi

APP="$BUILD_DIR/Build/Products/Debug/Jam AUv3.app"
APPEX="$APP/Contents/PlugIns/jamauv3Extension.appex"
INSTALL_DIR="/Applications"
INSTALLED_APP="$INSTALL_DIR/Jam AUv3.app"

echo "==> Killing old processes..."
# -x matches the executable name exactly; -f would match any process
# whose argv merely mentions the path (an editor, a DAW hosting the plugin).
pkill -9 -x jamauv3Extension 2>/dev/null || true
pkill -9 -x "Jam AUv3" 2>/dev/null || true
sleep 0.5

echo "==> Cleaning..."
xcodebuild clean -scheme jamauv3 -destination 'platform=macOS' -quiet >/dev/null 2>&1 || true

echo "==> Building..."
BUILD_LOG=$(mktemp)
if ! xcodebuild build -scheme jamauv3 -destination 'platform=macOS' -quiet >"$BUILD_LOG" 2>&1; then
    grep -E 'error:' "$BUILD_LOG" || tail -20 "$BUILD_LOG"
    rm -f "$BUILD_LOG"
    echo "ERROR: build failed"
    exit 1
fi
rm -f "$BUILD_LOG"

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

echo "Done. Jam AUv3.app installed to $INSTALL_DIR."
