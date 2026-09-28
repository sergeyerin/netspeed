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

# One connection for the whole publish. Without it every ssh and every scp
# authenticates on its own, and a passphrase-protected key gets asked for once
# per file — a dozen prompts to put up one page.
SSH_CTL="$WORK/ctl"
SSH_OPTS=(-o ControlMaster=auto -o "ControlPath=$SSH_CTL" -o ControlPersist=60)
cleanup() {
    [[ -S "$SSH_CTL" ]] && ssh -o "ControlPath=$SSH_CTL" -O exit "$NS_SSH" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

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

# Anything the page refers to by a relative path — screenshots, an icon, the
# fonts. Kept beside the markup so a redesign can add files without touching
# this, and copied in one go rather than one scp per file.
shopt -s nullglob
assets=()
for asset in tools/page-assets/*; do
    [[ "$(basename "$asset")" == "README.md" ]] && continue
    assets+=("$asset")
done

echo "-- publishing the page for ${VERSION} ($SIZE) and ${#assets[@]} files beside it"
ssh "${SSH_OPTS[@]}" "$NS_SSH" "mkdir -p '$NS_ROOT'"
scp "${SSH_OPTS[@]}" "$WORK/index.html" "$NS_SSH:$NS_ROOT/index.html"
[[ ${#assets[@]} -gt 0 ]] && scp "${SSH_OPTS[@]}" "${assets[@]}" "$NS_SSH:$NS_ROOT/"

echo "-- published: https://netspeed.biplane.cc/"
ssh "${SSH_OPTS[@]}" "$NS_SSH" "ls -sh '$NS_ROOT'"
