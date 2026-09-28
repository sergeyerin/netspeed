#!/bin/bash
# Packages the built app into a disk image for downloading.
#
#   tools/make-dmg.sh          # builds the app first, writes dist/NetSpeed-<version>.dmg
#
# The image holds the app next to a link to /Applications, so installing is a
# drag from one side of the window to the other.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="NetSpeed"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
DMG="dist/${APP_NAME}-${VERSION}.dmg"

./build.sh

rm -rf dist/stage "$DMG"
mkdir -p dist/stage
cp -R "build/${APP_NAME}.app" dist/stage/
ln -s /Applications dist/stage/Applications

echo "-- packing $DMG"
# UDZO keeps the image compressed and read-only; HFS+ because a signed app
# bundle's symlinks and permissions survive it unchanged.
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder dist/stage \
    -fs HFS+ \
    -format UDZO \
    -ov \
    -quiet \
    "$DMG"

rm -rf dist/stage
shasum -a 256 "$DMG" | tee "${DMG}.sha256"
echo "-- done: $DMG ($(du -h "$DMG" | cut -f1))"
