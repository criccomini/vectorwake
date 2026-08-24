#!/usr/bin/env python3
"""Assemble the three .dc.html artboards for the podium redesign.

The shipped podium is one card capped at 620pt, sized so a phone can hold it,
and a desktop shows that same small card floating in scrim. These boards
redesign the ending to own whatever window it is given. Same content as the
shipped screen, nothing invented: the result, the score, both rosters, comms,
share and replay, what the match banked, and the next-match clock.

The design system is the client's, same sources as ../rethink/build.py:
client/arena/palette.lua for hues, client/arena/ui.lua for panel grammar
(vrule panels, key_box keys, the chamfered bracket, hrule), and the two faces
the client carries. The match shown is a real one, lifted from a screenshot of
the shipped card so the two layouts can be compared line for line.
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

/* A panel is a translucent ground hung off a lit rule down its left edge,
   with the light spilling 26px across it. ui.lua vrule(). */
.panel{position:relative;background:rgba(5,7,12,.62)}
.panel::before{content:"";position:absolute;left:0;top:0;bottom:0;width:1.4px;
  background:rgba(63,88,120,.7)}
.panel::after{content:"";position:absolute;left:1.4px;top:0;bottom:0;width:26px;
  background:linear-gradient(90deg,rgba(63,88,120,.09),transparent);
  pointer-events:none}

/* The map border's tick, used as a rule between things. ui.lua ticks(). */
.ticks{height:3px;border-top:1px solid rgba(63,88,120,.28);
  background-image:repeating-linear-gradient(90deg,
    rgba(63,88,120,.4) 0 1px,transparent 1px 14px)}

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


# Four chamfered corners and nothing between them: what holds a cluster
# together without drawing a box round it. ui.lua bracket(), arm 14, chamfer 5.
BRACKET_SVG = ('<svg width="16" height="16" viewBox="0 0 16 16" fill="none" '
               'style="position:absolute;{pos}">'
               '<path d="M5 .7 H14 M.7 5 V14 M5 .7 L.7 5" stroke="{col}" '
               'stroke-width="1" stroke-linecap="square"/></svg>')


def bracket(col="rgba(63,88,120,.65)"):
    corners = [
        "left:0;top:0", "right:0;top:0;transform:scaleX(-1)",
        "right:0;bottom:0;transform:scale(-1,-1)",
        "left:0;bottom:0;transform:scaleY(-1)",
    ]
    return "".join(BRACKET_SVG.format(pos=p, col=col) for p in corners)


# The rivet, from ui.lua rivet_mark(): a cap, a shank, and two strikes across
# it, the fastener seen from the side.
def rivet(k, col):
    return (f'<svg width="{k}" height="{k}" viewBox="0 0 16 16" fill="none" '
            f'style="flex:none">'
            f'<path d="M2.3 2.6 H13.7 M8 2.6 V14 M4.3 7.7 H11.7 M4.3 10.5 '
            f'H11.7" stroke="{col}" stroke-width="1.5" '
            f'stroke-linecap="square"/></svg>')


# A key is the one stroked box the interface contains. ui.lua key_box().
def key(label, h, px, primary=False, style=""):
    if primary:
        edge, fill, ink = "rgba(79,214,255,.95)", "rgba(79,214,255,.16)", \
                          "rgba(79,214,255,.95)"
    else:
        edge, fill, ink = "rgba(63,88,120,.62)", "rgba(63,88,120,.05)", \
                          "rgba(223,233,245,.92)"
    return (f'<div class="row hud" style="height:{h}px;justify-content:center;'
            f'border:1.1px solid {edge};background:{fill};color:{ink};'
            f'font-size:{px}px;{style}">{label}</div>')


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


def roster(side, row_h, name_px, num_px, cell_w, pad, head_px, style=""):
    name, col, _, pilots = side
    cells = "".join(
        f'<div class="lbl" style="width:{cell_w}px;text-align:right;'
        f'font-size:{max(9, num_px - 4)}px">{c}</div>' for c in "KDA")
    out = [f'<div class="panel col" style="padding:{pad}px 0;{style}">',
           f'<div class="row" style="padding:2px {pad + 2}px 8px">'
           f'<div style="font-size:{head_px}px;font-weight:600;color:{col}">'
           f'{name}</div><div style="flex:1"></div>{cells}</div>',
           f'<div style="height:1px;margin:0 {pad + 2}px;'
           f'background:rgba(63,88,120,.5)"></div>']
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
            f'padding:0 {pad + 2}px">'
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


def banked(label_px, fig_px):
    return (f'<div class="col" style="gap:8px">'
            f'<div class="lbl" style="font-size:{label_px}px">Banked</div>'
            f'<div class="row" style="gap:9px">'
            f'{rivet(int(fig_px * 0.62), "#8dffb0")}'
            f'<div class="num" style="font-size:{fig_px}px;line-height:1;'
            f'color:var(--prize)">0</div></div></div>')


def next_match(label_px, fig_px, drain_h):
    # The clock over a drain: the same bar the score speaks in, running out
    # rather than filling, so the wait reads at a glance.
    return (f'<div class="col" style="gap:8px">'
            f'<div class="lbl" style="font-size:{label_px}px">Next match</div>'
            f'<div class="num" style="font-size:{fig_px}px;line-height:1;'
            f'color:rgba(223,233,245,.92)">0:06</div>'
            f'<div style="position:relative;height:{drain_h}px;'
            f'background:rgba(108,122,144,.16)">'
            f'<div style="position:absolute;left:0;top:0;bottom:0;width:24%;'
            f'background:rgba(255,209,102,.55)"></div></div></div>')


def board(w, h, stars, body):
    return ("<!doctype html>\n<html>\n<head>\n"
            '  <meta charset="utf-8">\n'
            '  <script src="./support.js"></script>\n'
            "</head>\n<body>\n<x-dc>\n"
            + helmet(w, h, stars) + "\n\n"
            f'<div class="screen">\n{walls(w, h, 14 if w > 900 else 8)}\n'
            + body + "\n</div>\n</x-dc>\n\n</body>\n</html>\n")


# --- desktop: the ending owns the window -------------------------------------
# One 1200pt measure. The result and the score band on top, the two rosters
# with a spine between them carrying the payout, the countdown and the
# actions, and comms in one row along the foot.
def desktop():
    spine = (
        '<div class="col" style="width:280px;flex:none;position:relative;'
        'padding:26px 24px;justify-content:space-between">'
        + bracket()
        + banked(10, 34)
        + '<div class="ticks" style="margin:16px 0"></div>'
        + next_match(10, 34, 6)
        + '<div class="ticks" style="margin:16px 0"></div>'
        + '<div class="col" style="gap:12px">'
        + key("Share match", 48, 12, primary=True)
        + key("Watch replay", 48, 12)
        + '</div></div>')

    rosters = (
        '<div class="row" style="gap:40px;align-items:stretch;'
        'justify-content:center;margin-top:36px">'
        + roster(SIDES[0], 44, 17, 15, 34, 16, 16, "width:420px;flex:none")
        + spine
        + roster(SIDES[1], 44, 17, 15, 34, 16, 16, "width:420px;flex:none")
        + '</div>')

    comms = ('<div class="row" style="gap:14px;justify-content:center;'
             'margin-top:36px">'
             + "".join(chip(p, 46, 11, "width:150px;flex:none")
                       for p in PHRASES)
             + '</div>')

    body = ('<div class="col" style="position:absolute;inset:0;'
            'justify-content:center;padding:40px 0">'
            + headline(42, 16)
            + '<div style="height:22px"></div>'
            + score_band(112, 560, 12, 30)
            + rosters + comms + '</div>')
    return board(1440, 810, STARS_DESKTOP, body)


# --- phone, upright: the same order the shipped card keeps, given room -------
# The sides stack full width instead of halving the measure, so a name and its
# figures stop fighting for the same 180 points.
def mobile():
    chips = ('<div style="display:grid;grid-template-columns:'
             'repeat(3, minmax(0, 1fr));gap:10px;margin-top:16px">'
             + "".join(chip(p, 46, 9.5) for p in PHRASES) + '</div>')

    actions = ('<div class="row" style="gap:10px;margin-top:12px">'
               + key("Share match", 48, 10.5, primary=True, style="flex:1")
               + key("Watch replay", 48, 10.5, style="flex:1") + '</div>')

    foot = ('<div class="row" style="margin-top:16px">'
            '<div class="row" style="gap:8px">'
            '<div class="lbl">Banked</div>' + rivet(13, "#8dffb0")
            + '<div class="num" style="font-size:15px;color:var(--prize)">0'
              '</div></div>'
            '<div style="flex:1"></div>'
            '<div class="row" style="gap:10px">'
            '<div class="lbl">Next match</div>'
            '<div class="num" style="font-size:16px;'
            'color:rgba(223,233,245,.92)">0:06</div></div></div>'
            '<div style="position:relative;height:4px;margin-top:8px;'
            'background:rgba(108,122,144,.16)">'
            '<div style="position:absolute;left:0;top:0;bottom:0;width:24%;'
            'background:rgba(255,209,102,.55)"></div></div>')

    body = ('<div class="col" style="position:absolute;inset:0;'
            'padding:44px 16px 20px;justify-content:center">'
            + headline(24, 10)
            + '<div style="height:10px"></div>'
            + score_band(52, 170, 8, 18)
            + '<div style="height:18px"></div>'
            + roster(SIDES[0], 36, 15, 13.5, 28, 12, 14)
            + '<div style="height:12px"></div>'
            + roster(SIDES[1], 36, 15, 13.5, 28, 12, 14)
            + chips + actions + foot + '</div>')
    return board(390, 844, STARS_MOBILE, body)


# --- phone, on its side: the spine becomes a right rail ----------------------
# Both rosters stay up, comms keep one row under the thumbs, and the payout,
# the countdown and the actions stand at the right edge.
def landscape():
    rail = ('<div class="col" style="width:224px;flex:none;position:relative;'
            'padding:14px 16px;justify-content:space-between">'
            + bracket()
            + '<div class="row" style="align-items:flex-start;gap:20px">'
            + banked(9, 20)
            + '<div class="col" style="flex:1">' + next_match(9, 20, 4)
            + '</div></div>'
            + '<div class="ticks" style="margin:12px 0"></div>'
            + '<div class="col" style="gap:8px">'
            + key("Share match", 44, 10, primary=True)
            + key("Watch replay", 44, 10)
            + '</div></div>')

    mid = ('<div class="row" style="gap:12px;align-items:stretch;'
           'margin-top:12px">'
           + roster(SIDES[0], 28, 13, 12, 24, 8, 13, "flex:1")
           + roster(SIDES[1], 28, 13, 12, 24, 8, 13, "flex:1")
           + rail + '</div>')

    head = ('<div class="row" style="justify-content:center;gap:20px">'
            '<div class="num" style="font-size:40px;line-height:1;'
            'font-weight:500;color:var(--friend)">22</div>'
            '<div class="col" style="gap:8px;align-items:center">'
            + headline(18, 8) + score_bar(300, 8) + '</div>'
            '<div class="num" style="font-size:40px;line-height:1;'
            'font-weight:500;color:var(--enemy)">20</div></div>')

    comms = ('<div class="row" style="gap:8px;margin-top:12px">'
             + "".join(chip(p, 44, 9, "flex:1") for p in PHRASES) + '</div>')

    body = ('<div class="col" style="position:absolute;inset:0;'
            'padding:14px 18px;justify-content:center">'
            + head + mid + comms + '</div>')
    return board(844, 390, STARS_LANDSCAPE, body)


STARS_DESKTOP = starfield(1440, 810, 52, 34, 14)
STARS_MOBILE = starfield(390, 844, 26, 16, 7)
STARS_LANDSCAPE = starfield(844, 390, 26, 17, 7)

(HERE / "Main.dc.html").write_text(desktop())
(HERE / "Mobile.dc.html").write_text(mobile())
(HERE / "Landscape.dc.html").write_text(landscape())
print("wrote Main.dc.html Mobile.dc.html Landscape.dc.html")
