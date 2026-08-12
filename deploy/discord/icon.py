#!/usr/bin/env python3
# The server's icon, cut from the mark the client already ships.
#
#     python3 deploy/discord/icon.py            # rewrites deploy/discord/icon.png
#
# client/web/icon.svg is the mark, and logo_test holds it to what ui.lua draws,
# so cutting the icon from that file rather than redrawing it keeps another
# drawing of the mark from existing. One thing changes on the way to Discord:
#
# Full bleed. The tile is chamfered in the file because the page shows it
# square. Discord masks a server icon to a circle, so a chamfer arrives as a
# bite out of the rim rather than as a corner, which is the same mistake iOS
# would make of it.
#
# Discord takes PNG rather than SVG. librsvg makes the raster when it is
# available, with the screenshot browser as a fallback.

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
                           "/Applications/Google Chrome.app/Contents/MacOS/"
                           "Google Chrome",
                           shutil.which("chromium"),
                           shutil.which("chromium-browser"),
                           shutil.which("google-chrome")]
               if p and pathlib.Path(p).exists()), None)
RSVG = shutil.which("rsvg-convert")


def cut(svg):
    """Make the source tile full bleed for Discord's circular mask."""
    svg = svg[svg.index("<svg"):]
    # A vertical is the path whose ends share an x. There are two rows, so the
    # three x positions each occur twice.
    verts = sorted(set(float(m) for m in
                       re.findall(r'<path d="M([\d.]+),[\d.]+ L\1,[\d.]+"',
                                  svg)))
    if len(verts) != 3:
        sys.exit(f"{SVG}: found {len(verts)} vertical positions, expected 3")
    if TILE not in svg:
        sys.exit(f"{SVG}: the tile path moved, so this cut needs rewriting")
    svg = svg.replace(TILE, FULL)
    return svg


def main():
    if RSVG is None and CHROME is None:
        sys.exit("no SVG rasterizer found")
    svg = cut(SVG.read_text())
    with tempfile.TemporaryDirectory() as tmp:
        shot = pathlib.Path(tmp) / "icon.png"
        if RSVG:
            source = pathlib.Path(tmp) / "icon.svg"
            source.write_text(svg)
            subprocess.run([RSVG, "-w", str(SIZE), "-h", str(SIZE),
                            "-o", shot, source], check=True)
        else:
            page = pathlib.Path(tmp) / "shot.html"
            page.write_text(
                "<!doctype html><meta charset=utf-8>"
                "<style>html,body{margin:0;padding:0;background:#05070c}"
                f"svg{{display:block;width:{SIZE}px;height:{SIZE}px}}"
                "</style>" + svg)
            subprocess.run(
                [CHROME, "--headless", "--disable-gpu", "--no-sandbox",
                 "--hide-scrollbars", "--force-device-scale-factor=1",
                 f"--window-size={SIZE},{SIZE}", f"--screenshot={shot}",
                 page.as_uri()], check=True, capture_output=True)
        OUT.write_bytes(shot.read_bytes())
    print(f"{OUT.relative_to(ROOT)}: {SIZE}x{SIZE}, {OUT.stat().st_size} bytes")


if __name__ == "__main__":
    main()
