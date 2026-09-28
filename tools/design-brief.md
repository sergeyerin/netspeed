# NetSpeed — download page

Everything here is for redesigning one page: <https://netspeed.biplane.cc/>.

## What NetSpeed is

A small macOS app that lives in the menu bar and shows what your network
connection is actually doing — how fast it is right now, how long it takes to
answer, and, when you are tethered to a phone, what the phone reports about its
cellular link. It is free, has no accounts and no server behind it.

People who land on this page usually arrive from a link, on a Mac, wanting the
app. They are technical enough to have gone looking for a network meter. Many of
them are on a bad connection at that very moment — that is what sent them
looking — so the page should be light and get to the point.

## What the page has to do

Two things, in this order:

1. **Hand over the file.** One obvious download, with enough context to trust it
   (version, size, date, checksum, where it is hosted).
2. **Get them past Gatekeeper.** The app is signed ad-hoc rather than with a paid
   Apple certificate, so macOS refuses the first launch on every machine that
   downloads it. Someone who does not find the way around this will conclude the
   app is broken. This is not a footnote — for most visitors it is the
   difference between a working app and a wasted download.

Everything else on the page exists to serve those two.

## What is in the kit

    README.md          this brief
    page.html          the page to edit, with placeholders — hand this back
    preview.html       the same page as it looks today, with real values
    screenshots/       the app in light and dark: the menu and the indicator
    icon/              the app icon at 1024, 256 and 32 px
    assets/            put your images and fonts here (see the note inside)

Open `preview.html` to see where things stand. Edit `page.html`.

## Rules the page has to keep

**Nothing loaded from a third party.** No CDN, no Google Fonts, no analytics, no
hotlinked images. The page must depend on no host but its own. Files of your own
are welcome — drop them in `assets/` and reference them by a plain relative path,
`<img src="shot.png">`. Do use the screenshots if they help; they are in
`screenshots/`.

**Light and dark.** Both are expected to work. Today that is five custom
properties redefined under `prefers-color-scheme`.

**Small.** The page is about bad connections; it should not be one itself. It is
4 KB today. Images are fine, but weigh them.

**The placeholders must survive.** These are substituted at publish time from the
disk image actually being released, so the page can never advertise a version or
a checksum that differs from the file people get:

    {{VERSION}}       version number, e.g. 1.1
    {{DMG}}           file name, e.g. NetSpeed-1.1.dmg
    {{DOWNLOAD_URL}}  full URL of the file on GitHub Releases
    {{SIZE}}          e.g. 324K
    {{DATE}}          e.g. 2026-09-28
    {{SHA}}           64 hex characters, the SHA-256 of the file
    {{REPO}}          https://github.com/sergeyerin/netspeed

Keep each of them somewhere in the markup. If one goes missing, publishing stops
with an error instead of putting up a page with no download link — but that
means a page missing a placeholder cannot ship at all.

## The look it has now

Nothing here is precious; it is a first pass, not a design.

- System font throughout (`-apple-system`), which matches the app.
- Green accent: `#1d8a3e` on light, `#30d158` on dark. Same green as the icon and
  as a healthy connection in the app itself. Worth keeping the tie, but the shade
  is not sacred.
- Two cards on a plain background: the download, then the installation steps.

The app's own visual language is a four-bar signal scale coloured green through
amber to red by how the connection behaves — see `screenshots/`. Anything that
plays off that will feel like the same product.

## Handing it back

`page.html` plus whatever you put in `assets/`. That is the whole deliverable —
no build step, no framework, no package to install. It goes live as a single
static file.
