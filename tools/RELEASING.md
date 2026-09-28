# Releasing

How a build reaches people. The app itself is described in the README; this is
the machinery around it, kept separate because it is specific to one server and
one account.

## Cutting a release

In this order — the page points at an exact release asset, so the release has to
exist before the page can name it:

```bash
# 1. bump CFBundleShortVersionString in Info.plist, then
tools/make-dmg.sh

# 2. publish the image — this is the only place it is hosted
gh release create v1.12 dist/NetSpeed-1.12.dmg dist/NetSpeed-1.12.dmg.sha256 \
    --title "NetSpeed 1.12" --notes "..."

# 3. point the page at it (refuses to run if the asset is not there)
NS_SSH=user@host tools/publish.sh            # NS_DRY_RUN=1 renders locally only
```

The image is hosted once, on GitHub Releases: free, on a CDN, with download
counts, and with no second copy free to claim a different version. That
duplication existed briefly and the two disagreed within the hour.

The site keeps the short address and the install instructions;
`netspeed.biplane.cc/download` redirects to the newest release.

Download counts are not shown anywhere in GitHub's web interface, only through
the API:

```bash
gh api repos/sergeyerin/netspeed/releases \
  --jq '.[] | "\(.tag_name): \([.assets[] | select(.name|endswith(".dmg")) | .download_count] | add)"'
```

## The download page

A single static file, generated from `tools/page.html` by
`tools/render-page.py`. The markup is ordinary HTML: open it in a browser to
work on it, or hand it to someone else to redesign. The brief at the top of it
spells out the constraints — nothing loaded from a third party, light and dark,
and the Gatekeeper instructions must survive, because without them the download
is useless to most people who get it.

The version, size, date, checksum and download link are substituted at publish
time from the image being released, so the page cannot advertise a version that
differs from the file. If a redesign drops one of those placeholders, publishing
stops with an error rather than putting up a page with no download link:

```bash
NS_DRY_RUN=1 tools/publish.sh    # renders dist/index.html with real values
```

Files the page refers to — screenshots, the icons, the self-hosted Barlow —
live in `tools/page-assets/` and are uploaded beside it.

To hand the page to a designer, `tools/design-kit.sh` assembles what they need —
the brief, the template, a preview carrying the current release's values,
screenshots and the icon — into `dist/netspeed-design-kit/` and a zip beside it.
Nothing in the kit is maintained by hand: the preview and the icons are
generated, so it cannot show a version or a mark that does not exist.

## Setting up the server

One-time, and the DNS record for the subdomain must already point at the host:

```bash
# from the Mac
scp tools/nginx-netspeed.conf user@host:/tmp/

# on the server — SERVER_IP is this host's own address, see the config's header
SERVER_IP=198.51.100.10
sudo mkdir -p /var/www/netspeed && sudo chown "$USER" /var/www/netspeed
# tee rather than a redirect: the redirect would run as you, not as root
sed "s/SERVER_IP/$SERVER_IP/g" /tmp/nginx-netspeed.conf \
    | sudo tee /etc/nginx/sites-available/netspeed > /dev/null
sudo ln -s /etc/nginx/sites-available/netspeed /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx

sudo certbot --nginx -d netspeed.biplane.cc
# certbot writes a bare `listen 443 ssl;`, which cannot bind on this host —
# see the comment at the top of nginx-netspeed.conf for why, and check from
# outside afterwards that the certificate served is this site's own:
sudo sed -i "s/^    listen 443 ssl;/    listen $SERVER_IP:443 ssl;/" \
    /etc/nginx/sites-available/netspeed
sudo nginx -t && sudo systemctl reload nginx
```

That `sed` is not housekeeping. Without it the bind fails, nginx keeps serving
the previous configuration, `nginx -t` passes, `systemctl reload` reports
success — and the outside world is handed another site's certificate. The only
trace is `bind() to 0.0.0.0:443 failed` in the error log.
