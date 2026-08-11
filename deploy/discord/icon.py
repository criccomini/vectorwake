#!/usr/bin/env python3
# The server's icon, cut from the mark the client already ships.
#
#     python3 deploy/discord/icon.py            # rewrites deploy/discord/icon.png
#
# client/web/icon.svg is the mark, and logo_test holds it to what ui.lua draws,
# so cutting the icon from that file rather than redrawing it is what keeps a
# fourth drawing of the mark from existing. Two things change on the way to a
# Discord tile, and both are the reasons the home screen's cut differs from the
# tab's:
#
# Full bleed. The tile is chamfered in the file because the page shows it
# square. Discord masks a server icon to a circle, so a chamfer arrives as a
# bite out of the rim rather than as a corner, which is the same mistake iOS
# would make of it.
#
# Stood on its middle vertical. Three wedges are one and three quarters as
# wide as they are tall, so a square tile holds the mark at barely half its
# height, and centring the box it fills leaves the standing strokes visibly
# right of center. Putting the middle vertical on the tile's center line puts
# the other two evenly either side of it and runs the first wake's faded end
# off the left edge, where it carries no ink to lose. The favicon is placed the
# same way for the same reason; this keeps the mark's own hairline cut, because
# Discord never asks for it at sixteen pixels.
#
# Rasterised by the Chromium that is already on the machine for the client's
# screenshots, since Discord takes png and not svg.

import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
SVG = ROOT / "client" / "web" / "icon.svg"
OUT = pathlib.Path(__file__).resolve().parent / "icon.png"
SIZE = 512
TILE = 'M92,0H512V420L420,512H0V92Z'
FULL = 'M0,0H512V512H0Z'

CHROME = next((p for p in ["/opt/pw-browsers/chromium",
                           shutil.which("chromium"),
                           shutil.which("chromium-browser"),
                           shutil.which("google-chrome")] if p), None)


def cut(svg):
    """The mark, full bleed and stood on its middle vertical."""
    svg = svg[svg.index("<svg"):]
    # A vertical is the one path whose two ends share an x. The middle of the
    # three is what the tile's center line is for.
    verts = sorted(float(m) for m in
                   re.findall(r'<path d="M([\d.]+),[\d.]+ L\1,[\d.]+"', svg))
    if len(verts) != 3:
        sys.exit(f"{SVG}: found {len(verts)} verticals, expected 3")
    if TILE not in svg:
        sys.exit(f"{SVG}: the tile path moved, so this cut needs rewriting")
    svg = svg.replace(TILE, FULL)
    tile = f'<path d="{FULL}" fill="#05070c"/>'
    head, marks = svg.split(tile)
    # A group transform, so the gradients move with the strokes they paint:
    # they are in user space, which the transform is part of.
    dx = SIZE / 2 - verts[1]
    marks = marks.replace("</svg>", "")
    return f'{head}{tile}<g transform="translate({dx:.1f},0)">{marks}</g></svg>'


def main():
    if CHROME is None:
        sys.exit("no chromium on this machine, and the cut has to be "
                 "rasterised somewhere")
    svg = cut(SVG.read_text())
    with tempfile.TemporaryDirectory() as tmp:
        page = pathlib.Path(tmp) / "shot.html"
        page.write_text("<!doctype html><meta charset=utf-8>"
                        "<style>html,body{margin:0;padding:0;background:#05070c}"
                        f"svg{{display:block;width:{SIZE}px;height:{SIZE}px}}"
                        "</style>" + svg)
        shot = pathlib.Path(tmp) / "icon.png"
        subprocess.run(
            [CHROME, "--headless", "--disable-gpu", "--no-sandbox",
             "--hide-scrollbars", "--force-device-scale-factor=1",
             f"--window-size={SIZE},{SIZE}", f"--screenshot={shot}",
             page.as_uri()],
            check=True, capture_output=True)
        OUT.write_bytes(shot.read_bytes())
    print(f"{OUT.relative_to(ROOT)}: {SIZE}x{SIZE}, {OUT.stat().st_size} bytes")


if __name__ == "__main__":
    main()
