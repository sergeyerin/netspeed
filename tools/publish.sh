#!/usr/bin/env bash
#
# Publishes the disk image and the download page to netspeed.biplane.cc.
#
#   NS_SSH=user@host tools/publish.sh
#   NS_DRY_RUN=1 tools/publish.sh        # render the page, copy nothing
#
# The server needs nothing beyond a directory of static files: the page links
# straight to the image. Nginx config lives next door in nginx-netspeed.conf.
set -euo pipefail
cd "$(dirname "$0")/.."

NS_SSH="${NS_SSH:-}"
NS_ROOT="${NS_ROOT:-/var/www/netspeed}"
NS_DRY_RUN="${NS_DRY_RUN:-}"

if [[ -z "$NS_SSH" && -z "$NS_DRY_RUN" ]]; then
    echo "Set NS_SSH=user@host (or NS_DRY_RUN=1)." >&2
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
DMG="dist/NetSpeed-${VERSION}.dmg"

if [[ ! -f "$DMG" ]]; then
    echo "No $DMG — build it first: tools/make-dmg.sh" >&2
    exit 1
fi

SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
SIZE=$(du -h "$DMG" | cut -f1 | tr -d ' ')
DATE=$(date -u +%Y-%m-%d)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# The page is generated rather than kept as a file: the version, size and
# checksum have to match the image being published, and a page edited by hand
# drifts from it silently.
NS_VERSION="$VERSION" NS_SHA="$SHA" NS_SIZE="$SIZE" NS_DATE="$DATE" \
    python3 tools/render-page.py > "$WORK/index.html"

if [[ -n "$NS_DRY_RUN" ]]; then
    echo "NS_DRY_RUN=1 — page rendered to $WORK/index.html, nothing copied."
    cp "$WORK/index.html" dist/index.html
    echo "Kept a copy at dist/index.html"
    exit 0
fi

echo "-- uploading $DMG ($SIZE)"
ssh "$NS_SSH" "mkdir -p '$NS_ROOT'"
# Image first: if the page fails to copy, the old page still points at a file
# that exists. The other way round it would link to something that does not.
scp "$DMG" "$NS_SSH:$NS_ROOT/"
printf '%s  %s\n' "$SHA" "NetSpeed-${VERSION}.dmg" > "$WORK/NetSpeed-${VERSION}.dmg.sha256"
scp "$WORK/NetSpeed-${VERSION}.dmg.sha256" "$NS_SSH:$NS_ROOT/"
scp "$WORK/index.html" "$NS_SSH:$NS_ROOT/index.html"

# Keep the three most recent images: enough to roll back, and the disk does not
# fill up on its own.
ssh "$NS_SSH" "cd '$NS_ROOT' && ls -t *.dmg 2>/dev/null | tail -n +4 | xargs -r rm -v --"

echo "-- published: https://netspeed.biplane.cc/"
ssh "$NS_SSH" "ls -sh '$NS_ROOT'"
