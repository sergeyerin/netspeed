#!/usr/bin/env python3
"""Renders the download page for netspeed.biplane.cc.

Reads the release facts from the environment so the page can never disagree
with the image being published:

    NS_VERSION  NS_SHA  NS_SIZE  NS_DATE

Writes the finished HTML to stdout.
"""

import html
import os
import sys

FIELDS = ("NS_VERSION", "NS_SHA", "NS_SIZE", "NS_DATE")
missing = [f for f in FIELDS if not os.environ.get(f)]
if missing:
    sys.exit(f"missing: {', '.join(missing)}")

version, sha, size, date = (html.escape(os.environ[f]) for f in FIELDS)
dmg = f"NetSpeed-{version}.dmg"

print(f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>NetSpeed — network speed in the macOS menu bar</title>
<style>
  :root {{
    color-scheme: light dark;
    --bg: #f6f6f7;
    --card: #ffffff;
    --ink: #17181a;
    --dim: #6b6f76;
    --line: #e2e3e6;
    --accent: #1d8a3e;
  }}
  @media (prefers-color-scheme: dark) {{
    :root {{
      --bg: #17181a;
      --card: #202226;
      --ink: #f2f3f5;
      --dim: #9aa0a8;
      --line: #32353a;
      --accent: #30d158;
    }}
  }}
  * {{ box-sizing: border-box; }}
  body {{
    margin: 0;
    padding: 3rem 1.25rem 4rem;
    background: var(--bg);
    color: var(--ink);
    font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
  }}
  main {{ max-width: 42rem; margin: 0 auto; }}
  h1 {{ font-size: 2rem; margin: 0 0 .35rem; letter-spacing: -.02em; }}
  .lead {{ color: var(--dim); margin: 0 0 2rem; font-size: 1.05rem; }}
  .card {{
    background: var(--card);
    border: 1px solid var(--line);
    border-radius: 12px;
    padding: 1.5rem;
    margin-bottom: 1.5rem;
  }}
  .get {{ display: flex; align-items: center; gap: 1.25rem; flex-wrap: wrap; }}
  a.button {{
    display: inline-block;
    background: var(--accent);
    color: #fff;
    text-decoration: none;
    font-weight: 600;
    padding: .7rem 1.4rem;
    border-radius: 9px;
  }}
  a.button:hover {{ filter: brightness(1.08); }}
  .meta {{ color: var(--dim); font-size: .9rem; }}
  code, .hash {{
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    font-size: .85rem;
  }}
  .hash {{ color: var(--dim); word-break: break-all; display: block; margin-top: 1rem; }}
  h2 {{ font-size: 1.05rem; margin: 0 0 .75rem; }}
  ol {{ margin: 0; padding-left: 1.2rem; }}
  li {{ margin-bottom: .5rem; }}
  pre {{
    background: var(--bg);
    border: 1px solid var(--line);
    border-radius: 8px;
    padding: .7rem .9rem;
    overflow-x: auto;
    margin: .6rem 0 0;
  }}
  footer {{ color: var(--dim); font-size: .9rem; text-align: center; margin-top: 2.5rem; }}
  footer a {{ color: inherit; }}
</style>
</head>
<body>
<main>
  <h1>NetSpeed</h1>
  <p class="lead">
    Network speed and link quality in the macOS menu bar. Native Swift, no
    dependencies, about 0.5% of one core at idle.
  </p>

  <div class="card">
    <div class="get">
      <a class="button" href="{dmg}">Download {dmg}</a>
      <span class="meta">{size} · version {version} · {date} · macOS 13+, Apple silicon</span>
    </div>
    <span class="hash">SHA-256 {sha}</span>
  </div>

  <div class="card">
    <h2>Installing</h2>
    <ol>
      <li>Open the image and drag <strong>NetSpeed</strong> into Applications.</li>
      <li>
        Launch it. macOS will refuse the first time — the app is signed only
        ad-hoc, not with a paid Apple developer certificate. Open
        <strong>System Settings → Privacy &amp; Security</strong>, find the
        message about NetSpeed and press <strong>Open Anyway</strong>.
      </li>
      <li>
        Or clear the download flag from a terminal and open it normally:
        <pre><code>xattr -dr com.apple.quarantine /Applications/NetSpeed.app</code></pre>
      </li>
    </ol>
    <p class="meta" style="margin-bottom:0">
      There is no Dock icon and no window: everything lives in the menu bar.
      Enable startup in <strong>Settings → Launch at login</strong>.
    </p>
  </div>

  <footer>
    Source, issues and release notes on
    <a href="https://github.com/sergeyerin/netspeed">GitHub</a>.
  </footer>
</main>
</body>
</html>""")
