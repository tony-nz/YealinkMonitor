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

# Release builds are universal so the bundle runs natively on both Apple
# Silicon and Intel. SwiftPM's own --arch flag needs Xcode's xcbuild, which the
# Command Line Tools do not ship, so each slice is built separately and lipo'd
# together. Debug builds stay native-only, because the second slice roughly
# doubles the build time and is no help while iterating.
ARM_TRIPLE="arm64-apple-macosx14.0"
# A separate scratch path: sharing one .build across triples corrupts SwiftPM's
# build database ("command ... not registered") and breaks the next native build.
ARM_SCRATCH=".build/arm64"
STAGED_BINARY=""

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG"
NATIVE_BINARY="$(swift build -c "$CONFIG" --show-bin-path)/YealinkMonitor"
[[ -x "$NATIVE_BINARY" ]] || { echo "error: binary not found at $NATIVE_BINARY" >&2; exit 1; }
BINARY="$NATIVE_BINARY"

if [[ "$CONFIG" == "release" && "${SKIP_UNIVERSAL:-0}" != "1" ]]; then
    echo "==> Building arm64 slice"
    if swift build -c "$CONFIG" --triple "$ARM_TRIPLE" --scratch-path "$ARM_SCRATCH"; then
        ARM_BINARY="$(swift build -c "$CONFIG" --triple "$ARM_TRIPLE" --scratch-path "$ARM_SCRATCH" --show-bin-path)/YealinkMonitor"
        if [[ -x "$ARM_BINARY" && "$ARM_BINARY" != "$NATIVE_BINARY" ]]; then
            STAGED_BINARY="$ROOT/build/YealinkMonitor.universal"
            mkdir -p "$ROOT/build"
            lipo -create "$NATIVE_BINARY" "$ARM_BINARY" -output "$STAGED_BINARY"
            BINARY="$STAGED_BINARY"
            echo "==> Universal: $(lipo -archs "$BINARY")"
        fi
    else
        # Not fatal: a native-only bundle still runs here, just not natively on
        # Apple Silicon. Say so rather than shipping a surprise.
        echo "warning: arm64 slice failed; bundle will be $(uname -m) only" >&2
    fi
fi

echo "==> Rendering icon"
swift "$ROOT/Scripts/make-icon.swift" >/dev/null
iconutil -c icns "$ROOT/build/AppIcon.iconset" -o "$ROOT/build/AppIcon.icns"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/YealinkMonitor"
[[ -n "$STAGED_BINARY" ]] && rm -f "$STAGED_BINARY"
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
