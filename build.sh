#!/bin/bash
# Build rtr.app — a macOS default-browser picker.
#
# Usage:
#   ./build.sh              # build into ./build/rtr.app
#   ./build.sh install      # build and copy to ~/Applications/rtr.app
#   ./build.sh run          # build + install + launch

set -euo pipefail
cd "$(dirname "$0")"

CONFIG=${CONFIG:-release}
APP_NAME="rtr"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "▸ Building Swift package ($CONFIG)…"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"
if [ ! -f "$BIN_PATH" ]; then
    echo "✗ Binary not found at $BIN_PATH"
    exit 1
fi

echo "▸ Assembling ${APP_DIR}…"
rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"

cp "$BIN_PATH" "$MACOS/$APP_NAME"
chmod +x "$MACOS/$APP_NAME"
cp Resources/Info.plist "$CONTENTS/Info.plist"

# Generate AppIcon.icns from source image (if present) and copy into the bundle.
ICON_SOURCE=""
for ext in png jpg jpeg; do
    if [ -f "Resources/AppIconSource.$ext" ]; then
        ICON_SOURCE="Resources/AppIconSource.$ext"
        break
    fi
done
if [ -n "$ICON_SOURCE" ]; then
    echo "▸ Generating AppIcon.icns from ${ICON_SOURCE}…"
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 64 128 256 512 1024; do
        sips -s format png -Z "$size" "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null 2>&1
    done
    # iconset needs both 1x and @2x variants per base size
    cp "$ICONSET/icon_32x32.png"    "$ICONSET/icon_16x16@2x.png"
    cp "$ICONSET/icon_64x64.png"    "$ICONSET/icon_32x32@2x.png"
    cp "$ICONSET/icon_256x256.png"  "$ICONSET/icon_128x128@2x.png"
    cp "$ICONSET/icon_512x512.png"  "$ICONSET/icon_256x256@2x.png"
    cp "$ICONSET/icon_1024x1024.png" "$ICONSET/icon_512x512@2x.png"
    rm -f "$ICONSET/icon_64x64.png" "$ICONSET/icon_1024x1024.png"
    iconutil -c icns "$ICONSET" -o "$RESOURCES/AppIcon.icns"
    rm -rf "$(dirname "$ICONSET")"
fi

# Ad-hoc sign so macOS will run it. A real signed/notarized build would replace this.
echo "▸ Ad-hoc codesigning…"
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || {
    echo "  (codesign failed — app may still run but Gatekeeper may complain)"
}

echo "✓ Built $APP_DIR"

case "${1:-}" in
    install|run)
        DEST="$HOME/Applications"
        mkdir -p "$DEST"
        # Kill any running instance so we can replace it
        pkill -x "$APP_NAME" 2>/dev/null || true
        sleep 0.2
        rm -rf "$DEST/$APP_NAME.app"
        cp -R "$APP_DIR" "$DEST/$APP_NAME.app"
        echo "✓ Installed to $DEST/$APP_NAME.app"

        # Force LaunchServices to re-scan this bundle so its URL handlers are registered.
        LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
        if [ -x "$LSREG" ]; then
            "$LSREG" -f "$DEST/$APP_NAME.app" >/dev/null 2>&1 || true
            echo "✓ Registered with LaunchServices"
        fi

        if [ "$1" = "run" ]; then
            open "$DEST/$APP_NAME.app"
            echo "✓ Launched"
            echo ""
            echo "Next step: System Settings → Desktop & Dock → Default web browser → rtr"
            echo "Then click any link — the picker should appear."
        fi
        ;;
esac
