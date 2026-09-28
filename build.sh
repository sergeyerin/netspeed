#!/bin/bash
# Builds NetSpeed.app: one binary plus a bundle, no dependencies.
#   ./build.sh            build into ./build/NetSpeed.app
#   ./build.sh install    build, install into ~/Applications and restart
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="NetSpeed"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP/Contents/MacOS"

rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"

echo "-- compiling"
swiftc \
  -O -whole-module-optimization \
  -target "$(uname -m)-apple-macos13.0" \
  -framework AppKit \
  -framework CoreWLAN \
  -framework SystemConfiguration \
  -framework ServiceManagement \
  -o "$MACOS_DIR/$APP_NAME" \
  Sources/*.swift

echo "-- signing (ad-hoc: gives the app a stable identity for login items)"
codesign --force --sign - --identifier local.netspeed.NetSpeed "$APP" >/dev/null

SIZE=$(du -sh "$APP" | cut -f1)
echo "-- done: $APP ($SIZE)"

if [[ "${1:-}" == "install" ]]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
  pkill -x "$APP_NAME" 2>/dev/null || true
  rm -rf "$DEST/$APP_NAME.app"
  cp -R "$APP" "$DEST/"
  open "$DEST/$APP_NAME.app"
  echo "-- installed into $DEST and launched"
fi
