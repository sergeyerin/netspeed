#!/usr/bin/env bash
#
# Renders preview/banner.png from tools/banner.html.
#
#   tools/make-banner.sh
#
# 1280×640 — GitHub's social preview size, and wide enough to head the README.
# Chrome does the rendering because the banner uses the same self-hosted Barlow
# as the page; drawing it in AppKit would mean a second set of fonts and a
# second idea of what the product looks like.
set -euo pipefail
cd "$(dirname "$0")/.."

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [[ ! -x "$CHROME" ]]; then
    echo "Google Chrome not found at $CHROME — it does the rendering." >&2
    exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# The page refers to its assets by plain names, so stage them together.
cp tools/banner.html "$WORK/banner.html"
cp tools/page-assets/*.woff2 tools/page-assets/icon-256.png tools/page-assets/tray-light.png "$WORK/"

mkdir -p preview
"$CHROME" --headless --disable-gpu --no-sandbox --hide-scrollbars \
    --window-size=1280,640 \
    --screenshot="$PWD/preview/banner.png" \
    "file://$WORK/banner.html" 2>/dev/null

echo "-- preview/banner.png ($(du -h preview/banner.png | cut -f1))"
