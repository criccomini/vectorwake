#!/bin/sh
# Rasterise the share card. Run from anywhere; writes share-card.png beside the
# svg it came from.
#
#     deploy/site/make-cards.sh [path/to/chrome]
#
# Chromium rather than a converter because the card has a photograph in it now,
# and the browser is the one renderer already on every machine that builds this
# repo. Playwright puts one at /opt/pw-browsers.
#
# Two things about the invocation are load-bearing and were both found the hard
# way, so they are spelled out rather than left as flags nobody dares touch.
#
# The svg is inlined into a page rather than pointed at with <img>. An svg
# loaded as an image is an isolated document and may not fetch anything
# external, so the gameplay frame silently does not draw and the card comes out
# as flat colour with the text still on it. It looks deliberate. Inlined, the
# relative path resolves against this directory, which is also where the file
# is served from.
#
# And it is `headless_shell`, not `chrome --headless`. The full browser counts
# its own window frame inside --window-size, so a 630-tall window renders a
# 547-tall viewport and the card loses its bottom eighty-three pixels: the
# button clips and the url is cut through the middle. The shell has no frame.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
chrome=${1:-}
if [ -z "$chrome" ]; then
    for c in /opt/pw-browsers/chromium_headless_shell-*/chrome-linux/headless_shell \
             /usr/bin/chromium-headless-shell; do
        [ -x "$c" ] && chrome=$c && break
    done
fi
if [ -z "$chrome" ] || [ ! -x "$chrome" ]; then
    echo "no headless shell found; pass one: $0 /path/to/headless_shell" >&2
    exit 1
fi

page=$(mktemp "${TMPDIR:-/tmp}/share-card-XXXXXX.html")
trap 'rm -f "$page"' EXIT
{
    printf '%s' '<!doctype html><meta charset=utf-8><style>*{margin:0;padding:0}'
    printf '%s' 'html,body{background:#05070c;overflow:hidden}'
    printf '%s\n' 'svg{display:block;position:absolute;top:0;left:0}</style>'
    cat "$here/share-card.svg"
} > "$page"

# The page has to sit in this directory for `media/gameplay-poster.jpg` to
# resolve, so it is copied in rather than rendered from the temp dir.
cp "$page" "$here/.card-render.html"
trap 'rm -f "$page" "$here/.card-render.html"' EXIT

"$chrome" --no-sandbox --disable-gpu --hide-scrollbars \
    --force-device-scale-factor=1 --window-size=1200,630 \
    --screenshot="$here/share-card.png" \
    "file://$here/.card-render.html" >/dev/null 2>&1

echo "wrote $here/share-card.png"
