#!/usr/bin/env bash
#
# Publishes the download page to netspeed.biplane.cc.
#
#   NS_SSH=user@host tools/publish.sh
#   NS_DRY_RUN=1 tools/publish.sh        # render the page, copy nothing
#
# The image is not copied here: the page links straight to the GitHub release
# asset, so the bytes exist in one place and the two cannot drift apart. Build
# and publish the release first, then run this to point the page at it.
#
# The local image is still needed — its size and checksum go on the page.
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

# The page names an exact release asset, so refuse to publish one that is not
# there yet: a page linking to a missing download is worse than a stale page.
RELEASE_URL="https://github.com/sergeyerin/netspeed/releases/download/v${VERSION}/NetSpeed-${VERSION}.dmg"
if ! curl -sfI -L -o /dev/null "$RELEASE_URL"; then
    echo "No release asset at $RELEASE_URL" >&2
    echo "Publish it first: gh release create v${VERSION} $DMG ${DMG}.sha256 --title \"NetSpeed ${VERSION}\" --notes ..." >&2
    exit 1
fi

echo "-- publishing the page for ${VERSION} ($SIZE)"
ssh "$NS_SSH" "mkdir -p '$NS_ROOT'"
scp "$WORK/index.html" "$NS_SSH:$NS_ROOT/index.html"

echo "-- published: https://netspeed.biplane.cc/"
ssh "$NS_SSH" "ls -sh '$NS_ROOT'"
