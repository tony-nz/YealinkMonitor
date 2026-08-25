#!/usr/bin/env bash
#
# Builds YealinkMonitor.app.
#
# Xcode is not required: the macOS SDK shipped with the Command Line Tools has
# everything the app uses, so this compiles with SwiftPM and assembles the
# bundle by hand.
#
#   ./Scripts/make-app.sh              # release build
#   ./Scripts/make-app.sh debug        # faster build, for iterating
#   ./Scripts/make-app.sh release run  # build then launch

set -euo pipefail

CONFIG="${1:-release}"
ACTION="${2:-}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/YealinkMonitor.app"
BUNDLE_ID="nz.co.myers.YealinkMonitor"
VERSION="0.1.0"

cd "$ROOT"

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG"
BINARY="$(swift build -c "$CONFIG" --show-bin-path)/YealinkMonitor"
[[ -x "$BINARY" ]] || { echo "error: binary not found at $BINARY" >&2; exit 1; }

echo "==> Rendering icon"
swift "$ROOT/Scripts/make-icon.swift" >/dev/null
iconutil -c icns "$ROOT/build/AppIcon.iconset" -o "$ROOT/build/AppIcon.icns"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/YealinkMonitor"
cp "$ROOT/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>YealinkMonitor</string>
    <key>CFBundleDisplayName</key><string>YealinkMonitor</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>YealinkMonitor</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <!-- Menu bar only: no Dock icon, no app switcher entry. -->
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Signing (ad-hoc)"
# Ad-hoc is enough to run locally and to use the keychain and notifications.
# Shipping to another Mac needs a Developer ID identity and notarization.
codesign --force --sign - --identifier "$BUNDLE_ID" --timestamp=none "$APP" >/dev/null 2>&1 \
    || echo "warning: ad-hoc signing failed; the app may still run" >&2

echo "==> Built $APP"

if [[ "$ACTION" == "run" ]]; then
    echo "==> Launching"
    pkill -f "YealinkMonitor.app/Contents/MacOS/YealinkMonitor" 2>/dev/null || true
    open "$APP"
fi
