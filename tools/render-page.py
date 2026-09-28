#!/usr/bin/env python3
"""Fills tools/page.html with the facts of the release being published.

The markup lives in page.html so it can be edited — or handed to a designer —
as an ordinary HTML file. This script substitutes values and nothing else; it
holds no layout of its own.

Reads from the environment, so the page cannot disagree with the image it
points at:

    NS_VERSION  NS_SHA  NS_SIZE  NS_DATE

Writes the finished HTML to stdout.
"""

import html
import os
import pathlib
import sys

REPO = "https://github.com/sergeyerin/netspeed"
TEMPLATE = pathlib.Path(__file__).with_name("page.html")

FIELDS = ("NS_VERSION", "NS_SHA", "NS_SIZE", "NS_DATE")
missing = [f for f in FIELDS if not os.environ.get(f)]
if missing:
    sys.exit(f"missing: {', '.join(missing)}")

version, sha, size, date = (html.escape(os.environ[f]) for f in FIELDS)
dmg = f"NetSpeed-{version}.dmg"

values = {
    "VERSION": version,
    "DMG": dmg,
    "DOWNLOAD_URL": f"{REPO}/releases/download/v{version}/{dmg}",
    "SIZE": size,
    "DATE": date,
    "SHA": sha,
    "REPO": REPO,
}

page = TEMPLATE.read_text(encoding="utf-8")

# The brief at the top of the template addresses whoever edits the file, not
# whoever reads the page.
if "<!--" in page:
    start = page.index("<!--")
    page = page[:start] + page[page.index("-->", start) + 3:].lstrip("\n")

# A placeholder the template lost would publish a page with no download link or
# no checksum, and nothing downstream would notice — so require every one of
# them to have been present.
for name, value in values.items():
    token = "{{" + name + "}}"
    if token not in page:
        sys.exit(f"page.html no longer uses {token}")
    page = page.replace(token, value)

if "{{" in page:
    sys.exit(f"unknown placeholder left in page.html: {page[page.index('{{'):][:40]}")

print(page, end="")
