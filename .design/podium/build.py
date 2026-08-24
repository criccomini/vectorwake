#!/usr/bin/env python3
"""Assemble the three .dc.html artboards for the podium redesign.

The shipped podium is one card capped at 620pt, sized so a phone can hold it,
and a desktop shows that same small card floating in scrim. These boards
redesign the ending to own whatever window it is given, in the play page's
section grammar. The result, the score band and both rosters stand at the
head without a header over them, since a scoreline needs no label; under them
SAY holds the comms and NEXT MATCH the clock beside its drain, with the share
key below it. Watch replay and the banked readout are dropped.

The design system is the client's, same sources as ../rethink/build.py:
client/arena/palette.lua for hues, client/arena/ui.lua for panel grammar
(hrule, key_box keys, the wash), and the two faces the client
carries. The match shown is a real one, lifted from a screenshot of the
shipped card so the two layouts can be compared line for line.
"""

import random
from pathlib import Path

HERE = Path(__file__).parent

# --- the sky, same cell feel as world.lua, one seed for every board ----------
random.seed(28)


def starfield(w, h, far, mid, near):
    out = []
    for n, col, r in ((far, "#2a3a58", 0.9), (mid, "#4a6089", 1.0),
                      (near, "#93a9c8", 1.3)):
        for _ in range(n):
            x, y = random.randint(0, w), random.randint(0, h)
            out.append(f"radial-gradient(circle {r}px at {x}px {y}px,"
                       f"{col} 0 {r}px,transparent {r}px)")
    return ",".join(out)


# --- the palette, from client/arena/palette.lua ------------------------------
CSS = """
:root{
  --bg:#05070c; --ink:#dfe9f5; --dim:#6c7a90;
  --friend:#4fd6ff; --enemy:#ffa552;
  --rule:#3f5878; --prize:#8dffb0; --charge:#ffd166; --bounty:#ffe08a;
  --mono:"DejaVu Sans Mono","Noto Sans Mono",ui-monospace,monospace;
  --menu:"Chakra Petch","Segoe UI",system-ui,sans-serif;
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font-family:var(--menu)}
a{color:var(--friend)}a:hover{color:#8ee6ff}
.screen{position:relative;width:WPXpx;height:HPXpx;overflow:hidden;
  background-color:var(--bg);background-image:STARS_HERE}

/* A selection: bright where it meets its rule and gone across the row. */
.wash{background:linear-gradient(90deg,rgba(79,214,255,.14),rgba(79,214,255,0) 70%)}

/* Type. The HUD is capitals, the case an instrument is labeled in; names and
   sides keep their supplied case. ui.lua cased(). */
.lbl{font-family:var(--mono);font-size:9px;text-transform:uppercase;
  letter-spacing:.13em;color:var(--dim)}
.num{font-family:var(--mono);font-variant-numeric:tabular-nums}
.hud{font-family:var(--mono);text-transform:uppercase;letter-spacing:.06em}
.dim{color:var(--dim)}
.row{display:flex;align-items:center}
.col{display:flex;flex-direction:column}
"""

HELMET = """<helmet>
  <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Chakra+Petch:wght@400;500;600&amp;family=Noto+Sans+Mono:wght@400;500;700&amp;display=swap">
  <style>
CSS_HERE
  </style>
</helmet>"""


def helmet(w, h, stars):
    css = CSS.replace("WPX", str(w)).replace("HPX", str(h)) \
             .replace("STARS_HERE", stars)
    return HELMET.replace("CSS_HERE", css)


# The rivet, from ui.lua rivet_mark(): a cap, a shank, and two strikes across
# it, the fastener seen from the side.
def rivet(k, col):
    return (f'<svg width="{k}" height="{k}" viewBox="0 0 16 16" fill="none" '
            f'style="flex:none">'
            f'<path d="M2.3 2.6 H13.7 M8 2.6 V14 M4.3 7.7 H11.7 M4.3 10.5 '
            f'H11.7" stroke="{col}" stroke-width="1.5" '
            f'stroke-linecap="square"/></svg>')


# The share mark: a tray with an arrow leaving it, the glyph every phone puts
# on the control that sends a thing somewhere else. Square caps and one weight,
# like every other mark the client draws.
def share_mark(k, col):
    return (f'<svg width="{k}" height="{k}" viewBox="0 0 16 16" fill="none" '
            f'style="flex:none">'
            f'<path d="M8 2 V10.2 M4.9 5.1 L8 2 L11.1 5.1 '
            f'M4.6 7.4 H2.6 V14 H13.4 V7.4 H11.4" stroke="{col}" '
            f'stroke-width="1.4" stroke-linecap="square"/></svg>')


# A key is the one stroked box the interface contains. ui.lua key_box().
def key(label, h, px, primary=False, style="", mark=None):
    if primary:
        edge, fill, ink = "rgba(79,214,255,.95)", "rgba(79,214,255,.16)", \
                          "rgba(79,214,255,.95)"
    else:
        edge, fill, ink = "rgba(63,88,120,.62)", "rgba(63,88,120,.05)", \
                          "rgba(223,233,245,.92)"
    glyph = mark(round(px * 1.35), ink) + f'<div style="width:{px * 0.8:.0f}px">'\
        '</div>' if mark else ''
    return (f'<div class="row hud" style="height:{h}px;justify-content:center;'
            f'border:1.1px solid {edge};background:{fill};color:{ink};'
            f'font-size:{px}px;{style}">{glyph}{label}</div>')


def chip(label, h, px, style=""):
    return key(label, h, px, primary=False, style=style)


# The wall pieces the ending happens over, dark under the scrim.
WALL_KINDS = [(140, 30), (30, 150), (64, 64), (96, 32), (32, 108)]


def walls(w, h, n):
    out = []
    for _ in range(n):
        bw, bh = random.choice(WALL_KINDS)
        x, y = random.randint(-20, w - 40), random.randint(-20, h - 40)
        out.append(f'<rect x="{x}" y="{y}" width="{bw}" height="{bh}" '
                   f'fill="#080d16" stroke="#22344f" stroke-width="1"/>'
                   f'<path d="M{x} {y} H{x + bw}" stroke="#5b82b8" '
                   f'stroke-width="1.4" opacity=".55"/>')
    return (f'<svg width="{w}" height="{h}" '
            f'style="position:absolute;inset:0;opacity:.28">'
            + "".join(out) + '</svg>'
            '<div style="position:absolute;inset:0;'
            'background:rgba(3,5,10,.78)"></div>')


# --- the match, lifted from a screenshot of the shipped card -----------------
SIDES = [
    ("Pylon", "var(--friend)", "rgba(79,214,255,{a})", [
        ("Kestrel", 9, 10, 2, "mvp"),
        ("Ridgeline", 8, 2, 3, None),
        ("Ozone", 5, 6, 3, None),
        ("DRiFT", 0, 4, 0, "self"),
    ]),
    ("Caisson", "var(--enemy)", "rgba(255,165,82,{a})", [
        ("Sable", 6, 3, 0, None),
        ("Vantage", 5, 4, 2, None),
        ("Tessellate", 5, 7, 4, None),
        ("Cirrus", 4, 7, 5, None),
    ]),
]
SCORE = (22, 20)
PHRASES = ["GG", "NICE SHOT", "CLOSE ONE", "GOOD LUCK", "THANKS", "SORRY"]


def roster(side, row_h, name_px, num_px, cell_w, head_px, style=""):
    name, col, _, pilots = side
    cells = "".join(
        f'<div class="lbl" style="width:{cell_w}px;text-align:right;'
        f'font-size:{max(9, num_px - 4)}px">{c}</div>' for c in "KDA")
    out = [f'<div class="col" style="{style}">',
           f'<div class="row" style="padding:2px 2px 8px">'
           f'<div style="font-size:{head_px}px;font-weight:600;color:{col}">'
           f'{name}</div><div style="flex:1"></div>{cells}</div>',
           '<div style="height:1px;margin:0 2px;'
           'background:rgba(63,88,120,.5)"></div>']
    for pname, k, d, a, tag in pilots:
        wash = ' wash' if tag == "self" else ''
        ink = 'var(--friend)' if tag == "self" else 'var(--ink)'
        mvp = (f'<div class="lbl" style="color:var(--charge);margin-right:'
               f'{cell_w // 3}px">mvp</div>' if tag == "mvp" else '')
        nums = "".join(
            f'<div class="num" style="width:{cell_w}px;text-align:right;'
            f'font-size:{num_px}px;color:rgba(108,122,144,.95)">{v}</div>'
            for v in (k, d, a))
        out.append(
            f'<div class="row{wash}" style="height:{row_h}px;'
            f'padding:0 2px">'
            f'<div style="font-size:{name_px}px;font-weight:500;color:{ink}">'
            f'{pname}</div><div style="flex:1"></div>{mvp}{nums}</div>')
    out.append('</div>')
    return "".join(out)


def headline(px, gap):
    return (f'<div class="row" style="gap:{gap}px;justify-content:center">'
            f'<div style="font-size:{px}px;font-weight:600;'
            f'color:var(--friend)">Pylon</div>'
            f'<div style="font-size:{px}px;font-weight:400;letter-spacing:'
            f'.04em;color:rgba(223,233,245,.92)">TAKES IT</div></div>')


def score_bar(w, h):
    ls, rs = SCORE
    part = ls / (ls + rs) * 100
    return (f'<div style="position:relative;width:{w}px;height:{h}px;flex:none;'
            f'background:rgba(108,122,144,.16)">'
            f'<div style="position:absolute;left:0;top:0;bottom:0;'
            f'width:{part - 1:.1f}%;background:rgba(79,214,255,.88)"></div>'
            f'<div style="position:absolute;right:0;top:0;bottom:0;'
            f'width:{99 - part:.1f}%;background:rgba(255,165,82,.88)"></div>'
            f'</div>')


def score_band(fig_px, bar_w, bar_h, gap):
    ls, rs = SCORE
    return (f'<div class="row" style="justify-content:center;gap:{gap}px">'
            f'<div class="num" style="font-size:{fig_px}px;line-height:1;'
            f'font-weight:500;color:var(--friend)">{ls}</div>'
            f'{score_bar(bar_w, bar_h)}'
            f'<div class="num" style="font-size:{fig_px}px;line-height:1;'
            f'font-weight:500;color:var(--enemy)">{rs}</div></div>')


# The section grammar all three boards share: the header, a rule under it in
# the menu's hrule weight, and the content, the rule padded equally off both.
def section(label, inner, style="", label_px=10, gap=12):
    return (f'<div class="col" style="{style}">'
            f'<div class="lbl" style="font-size:{label_px}px">{label}</div>'
            f'<div style="height:1px;background:rgba(63,88,120,.5);'
            f'margin:{gap}px 0"></div>'
            + inner + '</div>')


# The next-match clock beside its drain, a bar in the score bar's own
# language running out rather than filling, and under it the key that acts on
# the wait. Sharing had a section head of its own and did not need one: a
# header over a single key names the key twice.
def next_section(label_px, gap, clock_px, share_key, share_mt, style=""):
    return section(
        "Next match",
        f'<div class="row" style="gap:18px">'
        f'<div class="num" style="font-size:{clock_px}px;line-height:1;'
        f'color:rgba(223,233,245,.92)">0:06</div>'
        f'<div style="position:relative;height:4px;flex:1;'
        f'background:rgba(108,122,144,.16)">'
        f'<div style="position:absolute;left:0;top:0;bottom:0;width:24%;'
        f'background:rgba(255,209,102,.55)"></div></div></div>'
        f'<div style="height:{share_mt}px"></div>' + share_key,
        style=style, label_px=label_px, gap=gap)


def board(w, h, stars, body):
    return ("<!doctype html>\n<html>\n<head>\n"
            '  <meta charset="utf-8">\n'
            '  <script src="./support.js"></script>\n'
            "</head>\n<body>\n<x-dc>\n"
            + helmet(w, h, stars) + "\n\n"
            f'<div class="screen">\n{walls(w, h, 14 if w > 900 else 8)}\n'
            + body + "\n</div>\n</x-dc>\n\n</body>\n</html>\n")


# --- desktop: the ending owns the window -------------------------------------
# One 1040pt measure: the band and both rosters abreast under the result,
# then SAY and NEXT MATCH, each header over its own rule.
def desktop():
    score = (
        score_band(112, 560, 12, 30)
        + '<div class="row" style="gap:40px;margin-top:26px;'
        'align-items:flex-start">'
        + roster(SIDES[0], 44, 17, 15, 34, 16, "flex:1")
        + roster(SIDES[1], 44, 17, 15, 34, 16, "flex:1")
        + '</div>')

    say = section(
        "Say",
        '<div class="row" style="gap:14px">'
        + "".join(chip(p, 46, 11, "flex:1") for p in PHRASES) + '</div>',
        style="margin-top:20px")

    body = ('<div class="col" style="position:absolute;inset:0;'
            'justify-content:center;padding:32px 0">'
            '<div class="col" style="width:1040px;align-self:center">'
            + headline(42, 16)
            + '<div style="height:20px"></div>'
            + score + say
            + next_section(10, 12, 20, key("Share match", 48, 12, primary=True, mark=share_mark),
                           14, "margin-top:20px")
            + '</div></div>')
    return board(1440, 810, STARS_DESKTOP, body)


# --- phone, upright: the desktop's sections, stacked -------------------------
# The sides stack full width instead of halving the measure, so a name and its
# figures stop fighting for the same 180 points.
def mobile():
    score = (
        score_band(52, 170, 8, 18)
        + '<div style="height:16px"></div>'
        + roster(SIDES[0], 34, 15, 13.5, 28, 14)
        + '<div style="height:12px"></div>'
        + roster(SIDES[1], 34, 15, 13.5, 28, 14))

    say = section(
        "Say",
        '<div style="display:grid;grid-template-columns:'
        'repeat(3, minmax(0, 1fr));gap:10px">'
        + "".join(chip(p, 46, 9.5) for p in PHRASES) + '</div>',
        style="margin-top:16px", label_px=9, gap=10)

    body = ('<div class="col" style="position:absolute;inset:0;'
            'padding:40px 16px 20px;justify-content:center">'
            + headline(24, 10)
            + '<div style="height:14px"></div>'
            + score + say
            + next_section(9, 10, 16,
                           key("Share match", 48, 10.5, primary=True, mark=share_mark),
                           12, "margin-top:16px")
            + '</div>')
    return board(390, 844, STARS_MOBILE, body)


# --- phone, on its side: the same sections, on one measure -------------------
# The score keeps its two columns, since a roster is a column wherever it is
# drawn, but SAY and NEXT MATCH span the measure like they do on every other
# board. Everything is a size or two down: sideways the height is the scarce
# edge, and this is the board that has to earn its room back.
def landscape():
    score = (
        score_band(32, 420, 8, 22)
        + '<div class="row" style="gap:32px;margin-top:10px;'
        'align-items:flex-start">'
        + roster(SIDES[0], 24, 13, 12, 24, 13, "flex:1")
        + roster(SIDES[1], 24, 13, 12, 24, 13, "flex:1")
        + '</div>')

    say = section(
        "Say",
        '<div class="row" style="gap:8px">'
        + "".join(chip(p, 40, 9, "flex:1") for p in PHRASES) + '</div>',
        style="margin-top:10px", label_px=9, gap=6)

    body = ('<div class="col" style="position:absolute;inset:0;'
            'padding:10px 18px;justify-content:center">'
            + headline(18, 8)
            + '<div style="height:4px"></div>'
            + score + say
            + next_section(9, 6, 16,
                           key("Share match", 40, 9.5, primary=True,
                               mark=share_mark),
                           8, "margin-top:10px")
            + '</div>')
    return board(844, 390, STARS_LANDSCAPE, body)


STARS_DESKTOP = starfield(1440, 810, 52, 34, 14)
STARS_MOBILE = starfield(390, 844, 26, 16, 7)
STARS_LANDSCAPE = starfield(844, 390, 26, 17, 7)

(HERE / "Main.dc.html").write_text(desktop())
(HERE / "Mobile.dc.html").write_text(mobile())
(HERE / "Landscape.dc.html").write_text(landscape())
print("wrote Main.dc.html Mobile.dc.html Landscape.dc.html")
