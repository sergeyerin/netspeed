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

# The fonts and the icon live with the download page, which moved to a private
# repository when the server's address was taken out of this one. This script
# kept copying from tools/page-assets/ and has been broken ever since — long
# enough for the banner to spend fourteen releases advertising a signal-bar
# scale the app no longer has.
NS_SITE="${NS_SITE:-../netspeed-site}"
if [[ ! -d "$NS_SITE/page-assets" ]]; then
    echo "No page assets at $NS_SITE/page-assets — set NS_SITE to the site checkout." >&2
    exit 1
fi

# The strip, though, comes from here: it is generated into preview/ alongside
# the README's other pictures, so the banner shows the same indicator they do.
if [[ ! -f preview/tray-light.png ]]; then
    echo "No preview/tray-light.png — generate the screenshots first." >&2
    exit 1
fi

# The page refers to its assets by plain names, so stage them together.
cp tools/banner.html "$WORK/banner.html"
cp "$NS_SITE"/page-assets/*.woff2 "$NS_SITE/page-assets/icon-256.png" "$WORK/"
cp preview/tray-light.png "$WORK/"

mkdir -p preview
"$CHROME" --headless --disable-gpu --no-sandbox --hide-scrollbars \
    --window-size=1280,640 \
    --screenshot="$PWD/preview/banner.png" \
    "file://$WORK/banner.html" 2>/dev/null

echo "-- preview/banner.png ($(du -h preview/banner.png | cut -f1))"
