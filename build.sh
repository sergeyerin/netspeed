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

# Where this build came from, written into the bundle so the app can say so.
#
# A released image is built from a tag with nothing uncommitted, and `git
# describe` prints exactly the tag. Anything else — commits past it, a dirty
# tree — and it prints the difference, which is the honest way for a build to
# admit it is not the one on the download page. Without this a local build and
# a release look identical in the menu, and the question "is this the version I
# think it is" has no answer anywhere.
# Note for releasing: pack the image *after* tagging. Run before the tag
# exists and describe prints the previous one plus the distance, and the
# released build calls itself a local build — truthfully, but uselessly.
SOURCE=$(git describe --tags --dirty --always 2>/dev/null || echo "unknown")
/usr/libexec/PlistBuddy -c "Add :NSBuildSource string $SOURCE" \
  "$APP/Contents/Info.plist" > /dev/null

# The icon is generated once and committed; regenerate with tools/make-icon.swift.
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/"
else
  echo "-- no Resources/AppIcon.icns, building without an icon" >&2
fi

# Both architectures, so one download runs on any Mac that can run macOS 13:
# Apple silicon natively, and Intel natively rather than through Rosetta.
# swiftc builds one at a time, so each slice is compiled and then joined.
ARCHS=(arm64 x86_64)
SLICES=()
for arch in "${ARCHS[@]}"; do
  echo "-- compiling $arch"
  slice="$BUILD_DIR/$APP_NAME-$arch"
  swiftc \
    -O -whole-module-optimization \
    -target "$arch-apple-macos13.0" \
    -framework AppKit \
    -framework CoreWLAN \
    -framework CoreLocation \
    -framework SystemConfiguration \
    -framework ServiceManagement \
    -o "$slice" \
    Sources/*.swift
  SLICES+=("$slice")
done

echo "-- joining into one binary"
lipo -create -output "$MACOS_DIR/$APP_NAME" "${SLICES[@]}"
rm -f "${SLICES[@]}"

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
