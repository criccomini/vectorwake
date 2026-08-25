#!/usr/bin/env python3
"""Assemble the artboards for the ship and upgrades rethink.

One hangar won: the tabs merge, and every slot the arena has lives on the
ship page. The first page of the canvas is that direction as revised with
Chris, and the second keeps the first pass, the pages as shipped beside the
two directions that lost, as the record of how it was chosen.

The revised hangar, on page one:

  Main      the page. Circles only: solid is equipped, a ring is owned and
            not equipped, a dim grey ring is not yours, with the price at
            the row's end where a next rung is for sale. No info band; the
            head carries the build selector and the points meter.
  Buy       the reading, slid in from the right over the page. Pressing a
            row's word or its dim region opens it: the lesson, the ladder
            at reading size, the price, the wallet, BUY. Back is the
            chevron or a swipe right.
  Owned     the same reading for a slot with nothing left to sell: no
            price, no wallet, no BUY.
  Builds    what pressing the build's name opens: the library, with save,
            rename, delete and save-as-new in the one place they act.
  Points    what pressing the meter opens: what the thirty are, and the
            circle grammar taught where it is asked about.

The design system is the client's, same sources as ../menu-unify/build.py:
client/arena/palette.lua for hues, client/arena/ui.lua for panel grammar,
sim/src/baseline.c and sim.c for the real melee shelf: what is dealt, what
the arena holds, and what is left to sell. The account shown owns one bought
spray rung and holds 130 rivets.

Rebuild with: python3 build.py
"""

import random
from pathlib import Path

HERE = Path(__file__).parent

# --- the sky, as world.lua draws it ------------------------------------------


def starfield(w, h, far, mid, near, seed):
    rnd = random.Random(seed)
    out = [
        f"radial-gradient(620px 420px at {int(w * .72)}px {int(h * .3)}px,"
        "rgba(39,197,237,.05),transparent 70%)",
        f"radial-gradient(520px 380px at {int(w * .2)}px {int(h * .78)}px,"
        "rgba(255,157,34,.04),transparent 70%)",
    ]
    for n, col, r in ((far, "#2a3a58", 0.9), (mid, "#4a6089", 1.0),
                      (near, "#93a9c8", 1.3)):
        for _ in range(n):
            x, y = rnd.randint(0, w), rnd.randint(0, h)
            out.append(f"radial-gradient(circle {r}px at {x}px {y}px,"
                       f"{col} 0 {r}px,transparent {r}px)")
    return ",".join(out)


# --- the palette, from client/arena/palette.lua ------------------------------
INK = "#dfe9f5"
DIM = "#6c7a90"
FRIEND = "#4fd6ff"
RULE = "rgba(63,88,120,.6)"
GOLD = "#ffd166"          # CHARGE_COL: prices, the gun's tint, charge boxes
BOMBC = "#ff5ea8"         # the bomb's tint
STATS = [("energy", "#7fe3a0"), ("recharge", "#4fd6ff"),
         ("speed", "#ffd166"), ("thrust", "#ff9a5c"),
         ("rotation", "#c79bff")]

CSS = """
:root{
  --ink:#dfe9f5; --dim:#6c7a90; --friend:#4fd6ff; --gold:#ffd166;
  --mono:"DejaVu Sans Mono","Noto Sans Mono",ui-monospace,monospace;
  --menu:"Chakra Petch","Segoe UI",system-ui,sans-serif;
}
*{box-sizing:border-box}
body{margin:0;background:#05070c;color:var(--ink);font-family:var(--menu)}
a{color:var(--friend)}a:hover{color:#8ee6ff}
.lbl{font-family:var(--mono);font-size:9px;text-transform:uppercase;
  letter-spacing:.13em;color:var(--dim)}
.num{font-family:var(--mono);font-variant-numeric:tabular-nums}
.hud{font-family:var(--mono);text-transform:uppercase;letter-spacing:.06em}
.row{display:flex;align-items:center}
.col{display:flex;flex-direction:column}
.key{display:inline-flex;align-items:center;justify-content:center;gap:6px;
  border:1px solid rgba(63,88,120,.75);background:rgba(10,15,24,.6);
  font-family:var(--mono);text-transform:uppercase;letter-spacing:.06em;
  color:#9fb6d4}
.wash{background:linear-gradient(90deg,rgba(79,214,255,.14),
  rgba(79,214,255,0) 85%)}
"""

HELMET = """<helmet>
  <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Chakra+Petch:wght@400;500;600&amp;family=Noto+Sans+Mono:wght@400;500;700&amp;display=swap">
  <style>
CSS_HERE
  .screen{position:relative;width:WPXpx;height:HPXpx;overflow:hidden;
    background-color:#05070c;background-image:STARS_HERE}
  </style>
</helmet>"""


def helmet(w, h, stars):
    return (HELMET.replace("CSS_HERE", CSS)
            .replace("WPX", str(w)).replace("HPX", str(h))
            .replace("STARS_HERE", stars))


def board(name, w, h, body, seed):
    stars = starfield(w, h, max(10, w * h // 26000),
                      max(7, w * h // 40000), max(4, w * h // 90000), seed)
    (HERE / name).write_text(
        "<!doctype html>\n<html>\n<head>\n"
        '  <meta charset="utf-8">\n'
        '  <script src="./support.js"></script>\n'
        "</head>\n<body>\n<x-dc>\n"
        + helmet(w, h, stars) + "\n\n"
        f'<div class="screen">\n{body}\n</div>\n</x-dc>\n\n</body>\n</html>\n')
    print("wrote", name)


# --- the lockup, verbatim from docs/banner.svg -------------------------------
MARK_PATHS = (
    '<path fill="#ff9d22" d="M42 0L84 67L66 78L42 53L18 78L0 67Z"/>'
    '<path fill="#27c5ed" d="M0 67L18 78L42 53L66 78L84 67L60 103L42 74L24 103Z"/>'
    '<path fill="none" stroke="#000" stroke-width="3" stroke-linecap="square" '
    'stroke-linejoin="miter" d="M0 67L18 78L42 53L66 78L84 67"/>'
)

WORD_PATH = (
    '<path transform="translate(424.175,144.9)" d="M1 -49.8H10.6L24.4 -10H24.8L38.5 '
    '-49.8H48.1L29.6 0H19.6ZM54.1 -9.5V-40.2L63.7 -49.8H89.8L99.4 -40.2V-22H63.4V-12.4'
    'L67.8 -8H85.7L90.1 -12.3V-15.7H99.3V-9.5L89.9 0H63.6ZM90.1 -29.3V-37.4L85.6 -41.8'
    'H67.9L63.4 -37.4V-29.3ZM110.9 -9.5V-40.3L120.4 -49.8H145.5L155.1 -40.2V-33.1H145.8'
    'V-37.2L141.3 -41.7H124.7L120.2 -37.2V-12.6L124.7 -8.1H141.3L145.8 -12.6V-16.7H155.1'
    'V-9.6L145.5 0H120.4ZM170.6 -9.5V-41.8H161.6V-49.8H170.8V-66H179.9V-49.8H195.4V-41.7'
    'H179.9V-12.5L184.4 -8.1H195.4V0H180.2ZM203.4 -9.6V-40.2L213 -49.8H239.6L249.1 -40.2'
    'V-9.6L239.6 0H213ZM235.3 -8.1 239.8 -12.5V-37.3L235.3 -41.7H217.2L212.7 -37.3V-12.5'
    'L217.2 -8.1ZM262.1 -49.8H271V-41.1L279.6 -49.8H292.9V-41.7H281.7L271.4 -31.3V0H262.1'
    'ZM297.4 -49.8H306.9L314.5 -11.7H314.8L325.8 -49.8H334.6L344.7 -11.7H345L353.3 -49.8'
    'H362.8L350.1 0H340.7L330.3 -38.6H330L318.7 0H309.2ZM369.3 -8.5V-20.8L377.8 -29.3H404'
    'V-37.7L399.6 -42H383.3L379 -37.7V-34H369.7V-40.1L379.4 -49.8H403.5L413.2 -40.1V0'
    'H404.5V-8.2L395.9 0H377.8ZM394.6 -7.7 404 -16.7V-21.9H382.1L378.6 -18.4V-11.1L382.1 '
    '-7.7ZM426.7 -71.4H436V-30H446.7L460.7 -49.8H471L454.3 -25.8L472 0H461.7L446.6 -21.8'
    'H436V0H426.7ZM477 -9.5V-40.2L486.6 -49.8H512.7L522.3 -40.2V-22H486.3V-12.4L490.7 '
    '-8H508.6L513 -12.3V-15.7H522.2V-9.5L512.8 0H486.5ZM513 -29.3V-37.4L508.5 -41.8'
    'H490.8L486.3 -37.4V-29.3Z" fill="#dfe9f5"/>'
)


def lockup(w):
    h = round(w * 88 / 616)
    return (f'<svg width="{w}" height="{h}" viewBox="332 71 616 88" '
            f'style="display:block;flex:none">'
            f'<g transform="translate(334.975 83) scale(.7115)">{MARK_PATHS}</g>'
            f'{WORD_PATH}</svg>')


# --- small marks -------------------------------------------------------------


def rivet(k, col):
    """The fastener seen from the side: what a price is counted in."""
    return (f'<svg width="{k}" height="{k}" viewBox="0 0 16 16" fill="none" '
            f'style="flex:none">'
            f'<path d="M2.3 2.6 H13.7 M8 2.6 V14 M4.3 7.7 H11.7 M4.3 10.5 '
            f'H11.7" stroke="{col}" stroke-width="1.5" '
            f'stroke-linecap="square"/></svg>')


def helm(col, k=11):
    return (f'<svg width="{k}" height="{k}" viewBox="0 0 14 14" fill="none" '
            f'style="flex:none">'
            f'<path d="M2 8.2 A5 5 0 0 1 12 8.2" stroke="{col}" stroke-width="1.1"/>'
            f'<path d="M3.6 7.4 A3.4 3.4 0 0 1 10.4 7.4" stroke="{col}" '
            f'stroke-width="1" opacity=".65"/>'
            f'<path d="M1.2 9.4 H12.8" stroke="{col}" stroke-width="1.1"/></svg>')


def tri(direction, col, k=9):
    p = ("M8 1.5 L2.5 7 L8 12.5 Z" if direction < 0
         else "M2 1.5 L7.5 7 L2 12.5 Z")
    return (f'<svg width="{k}" height="{k}" viewBox="0 0 10 14" '
            f'style="flex:none"><path d="{p}" fill="{col}"/></svg>')


# --- the fight beside the drawer, for the landscape boards -------------------
#
# Hull outlines to the extents in docs/design/ships.md, same paths as
# ../menu-unify/build.py, and the radar the sideways phone keeps while the
# drawer covers the clock band.

HULLS = {
    "Wedge":   "M0,-13 L15,9 L7,12 L0,8 L-7,12 L-15,9 Z",
    "Cipher":  "M0,-22 L3,-6 L6,8 L2,12 L-2,12 L-6,8 L-3,-6 Z",
    "Anvil":   "M-8,-15 L8,-15 L13,-5 L13,6 L8,11 L-8,11 L-13,6 L-13,-5 Z",
    "Apex":    "M0,-20 L6,-3 L10,7 L4,5 L2,11 L-2,11 L-4,5 L-10,7 L-6,-3 Z",
}

ENEMY = "#ffa552"


def ship_at(name, x, y, rot, col):
    return (f'<g transform="translate({x},{y}) rotate({rot})">'
            f'<path d="M-4,10 L-2,52 L2,52 L4,10 Z" fill="{col}" '
            f'opacity=".16"/>'
            f'<path d="{HULLS[name]}" fill="#0b1220" stroke="{col}" '
            f'stroke-width="1.5" stroke-linejoin="round"/></g>')


def nameplate(x, y, name, col, px=9):
    return (f'<text x="{x + 14}" y="{y + 24}" font-family="Noto Sans Mono,'
            f'monospace" font-size="{px}" fill="{col}" opacity=".9">'
            f'{name}</text>')


def scene_svg(w, h, seed):
    rnd = random.Random(seed)
    parts = []
    for _ in range(7):
        bw, bh = rnd.choice([(96, 32), (32, 108), (64, 64), (140, 30)])
        x, y = rnd.randint(-20, w - 60), rnd.randint(-20, h - 40)
        parts.append(
            f'<rect x="{x}" y="{y}" width="{bw}" height="{bh}" '
            f'fill="#080d16" stroke="#22344f" stroke-width="1"/>'
            f'<path d="M{x} {y} H{x + bw}" stroke="#5b82b8" '
            f'stroke-width="1.4" opacity=".55"/>')
    for name, hull, col, (ox, oy), rot in (
            ("KRAIT 4", "Wedge", FRIEND, (0.62, 0.62), 24),
            ("MANTIS 7", "Cipher", ENEMY, (0.7, 0.3), 205),
            ("HALCYON 2", "Anvil", ENEMY, (0.87, 0.55), 160)):
        x, y = w * ox, h * oy
        parts.append(ship_at(hull, x, y, rot, col))
        parts.append(nameplate(x, y, name, col))
    return (f'<svg width="{w}" height="{h}" '
            f'style="position:absolute;inset:0">{"".join(parts)}</svg>')


def minimap(side, seed):
    rnd = random.Random(seed)
    blips = []
    for _ in range(20):
        bx, by = rnd.randint(6, 94), rnd.randint(6, 94)
        bw, bh = rnd.choice([(6, 3), (3, 7), (5, 5), (9, 3)])
        blips.append(f'<rect x="{bx}" y="{by}" width="{bw}" height="{bh}" '
                     f'fill="#3f5878" opacity=".85"/>')
    ships = ('<circle cx="47" cy="52" r="2" fill="#4fd6ff"/>'
             '<circle cx="66" cy="38" r="2" fill="#ffa552"/>'
             '<circle cx="30" cy="30" r="2" fill="#ffa552"/>')
    return (f'<svg width="{side}" height="{side}" viewBox="0 0 100 100" '
            f'style="background:rgba(6,10,16,.55);outline:1px solid '
            f'rgba(63,88,120,.5)">{"".join(blips)}{ships}</svg>')


# --- the drawer chrome -------------------------------------------------------

ICONS = {
    "play": '<path d="M4.5 2.5 L13 8 L4.5 13.5 Z"/>',
    "ship": ('<g transform="translate(8,8.6) scale(.5)">'
             '<path d="M0,-13 L15,9 L7,12 L0,8 L-7,12 L-15,9 Z"/></g>'),
    "upgrades": ('<circle cx="8" cy="8" r="4.4"/>'
                 '<path d="M8 1.6 V3.6 M8 12.4 V14.4"/>'),
    "friends": ('<path d="M2.6 9.8 A5.5 5.5 0 0 1 13.4 9.8"/>'
                '<path d="M1.6 11.6 H14.4"/>'),
    "standings": '<path d="M3 13.5 V8.5 M8 13.5 V2.5 M13 13.5 V6"/>',
    "settings": ('<path d="M2 4.5 H14 M2 8 H14 M2 11.5 H14"/>'
                 '<circle cx="10.5" cy="4.5" r="1.8" fill="#0a0f18"/>'
                 '<circle cx="5.5" cy="8" r="1.8" fill="#0a0f18"/>'
                 '<circle cx="9.5" cy="11.5" r="1.8" fill="#0a0f18"/>'),
}


def icon(kind, col):
    dot = (f'<circle cx="8" cy="8" r="1.3" fill="{col}" stroke="none"/>'
           if kind == "upgrades" else "")
    return (f'<svg width="16" height="16" viewBox="0 0 16 16" fill="none" '
            f'stroke="{col}" stroke-width="1.3" style="flex:none">'
            f'{ICONS[kind]}{dot}</svg>')


def stops_bar(tabs, lit):
    cells = []
    for t in tabs:
        on = t == lit
        col = "var(--ink)" if on else "var(--dim)"
        ic = FRIEND if on else DIM
        wash = ("background:linear-gradient(0deg,rgba(79,214,255,.14),"
                "rgba(79,214,255,0) 80%);" if on else "")
        cells.append(
            f'<div style="flex:1;display:flex;flex-direction:column;'
            f'align-items:center;justify-content:center;gap:4px;height:100%;'
            f'{wash}">{icon(t, ic)}'
            f'<span style="font-size:9px;color:{col}">{t}</span></div>')
    return (f'<div style="position:absolute;left:0;right:0;bottom:0;'
            f'height:64px;border-top:1px solid {RULE};display:flex">'
            + "".join(cells) + '</div>')


def drawer_head():
    """The x where the burger sat, the wordmark beside it, the call sign at
    the far end."""
    x_key = ('<div class="key" style="width:26px;height:26px;flex:none">'
             '<svg width="11" height="11" viewBox="0 0 12 12">'
             '<path d="M1.5 1.5 L10.5 10.5 M10.5 1.5 L1.5 10.5" '
             'stroke="#9fb6d4" stroke-width="1.4" '
             'stroke-linecap="square"/></svg></div>')
    chip = (f'<div class="key" style="height:24px;padding:0 9px;'
            f'font-size:10px;gap:6px">{helm("#9fb6d4", 11)}KRAIT 4</div>')
    return (f'<div class="row" style="height:52px;padding:0 14px;gap:12px;'
            f'justify-content:space-between;border-bottom:1px solid '
            f'rgba(63,88,120,.45)">{x_key}{lockup(104)}'
            f'<div style="flex:1"></div>{chip}</div>')


def drawer(page, tabs, lit, teach=None, overlay=""):
    """One 390 by 880 column: head, page, an optional teach band, the stops.
    `overlay` is drawn over everything, for the buy card."""
    teach_h = 78 if teach else 0
    band = ""
    if teach:
        band = (f'<div style="position:absolute;left:0;right:0;bottom:64px;'
                f'height:{teach_h}px;padding:9px 14px 0;'
                f'border-top:1px solid rgba(63,88,120,.45)">{teach}</div>')
    return (f'<div style="position:absolute;inset:0;'
            f'background:rgba(3,5,10,.86)"></div>'
            + drawer_head()
            + f'<div style="position:absolute;left:0;right:0;top:52px;'
              f'bottom:{64 + teach_h}px;padding:0 14px;overflow:hidden">'
              f'{page}</div>'
            + band + stops_bar(tabs, lit)
            + f'<div style="position:absolute;right:0;top:0;bottom:0;'
              f'width:1px;background:{RULE}"></div>'
            + overlay)


# --- page furniture ----------------------------------------------------------


def rule(label, mt=12, mb=8):
    return (f'<div class="row" style="gap:10px;margin:{mt}px 0 {mb}px">'
            f'<span class="lbl">{label}</span>'
            f'<div style="flex:1;height:1px;'
            f'background:rgba(63,88,120,.45)"></div></div>')


def pip_svg(cells, k=11, r=4.4, step=13):
    """A run of ladder steps. Each cell is (kind, color). The revised
    grammar is circles all the way down: `on` a solid disc (equipped),
    `ring` a hollow disc in the slot's color (owned, not equipped), `dim` a
    grey hollow disc (the arena has it, the account does not). The first
    pass's `own`, `lock` and `next` kinds survive for the boards on the
    record page, which drew the shelf the way the shipped client does."""
    w = step * len(cells) + 2
    cy = k // 2 + 1
    out = []
    for i, (kind, col) in enumerate(cells):
        cx = i * step + 6
        if kind == "on":
            out.append(f'<circle cx="{cx}" cy="{cy}" r="{r}" '
                       f'fill="{col}"/>')
        elif kind in ("own", "ring"):
            out.append(f'<circle cx="{cx}" cy="{cy}" r="{r - 0.5}" '
                       f'fill="none" stroke="{col}" stroke-width="1.1" '
                       f'opacity=".8"/>')
        elif kind == "dim":
            out.append(f'<circle cx="{cx}" cy="{cy}" r="{r - 0.5}" '
                       f'fill="none" stroke="{DIM}" stroke-width="1" '
                       f'opacity=".5"/>')
        elif kind == "lock":
            out.append(f'<rect x="{cx - 3}" y="{cy - 3}" width="6" '
                       f'height="6" fill="none" stroke="{DIM}" '
                       f'stroke-width="1" opacity=".55"/>')
        elif kind == "next":
            out.append(f'<path d="M{cx} {cy - 5.5} L{cx + 4.5} '
                       f'{cy} L{cx} {cy + 5.5} L{cx - 4.5} '
                       f'{cy} Z" fill="none" stroke="{GOLD}" '
                       f'stroke-width="1.2" opacity=".95"/>')
    return (f'<svg width="{w}" height="{k + 3}" viewBox="0 0 {w} {k + 3}" '
            f'style="flex:none">{"".join(out)}</svg>')


def dealt_bar():
    """What everybody is dealt, as one bar, the way the shelf draws it."""
    return ('<div style="width:18px;height:3px;background:rgba(108,122,144,'
            '.45);margin-right:9px;flex:none"></div>')


def price_tag(n, can=True, figure=True):
    col = GOLD if can else DIM
    fig = (f'<span class="num" style="font-size:11px;color:{col};'
           f'opacity:.95">{n}</span>' if figure else '')
    return (f'<div class="row" style="gap:3px;margin-left:auto;flex:none">'
            f'{rivet(11, col)}{fig}</div>')


def ladder_row(name, cells, readout=None, tail="", hot=False, name_w=112,
               h=26, name_col=None):
    wash = ' wash' if hot else ''
    ncol = name_col or (INK if not hot else INK)
    ro = (f'<span class="num" style="font-size:10.5px;margin-left:9px;'
          f'color:rgba(223,233,245,.75)">{readout}</span>' if readout else '')
    return (f'<div class="row{wash}" style="height:{h}px;margin:0 -14px;'
            f'padding:0 14px">'
            f'<span style="font-size:12.5px;color:{ncol};opacity:'
            f'{1 if hot else .85};width:{name_w}px;flex:none">{name}</span>'
            + cells + ro + tail + '</div>')


def charge_box(word, hot=False):
    return (f'<div class="key" style="height:18px;padding:0 8px;'
            f'font-size:8.5px;margin-left:12px;color:{GOLD};'
            f'border-color:rgba(255,209,102,{".9" if hot else ".5"});'
            f'background:rgba(255,209,102,{".16" if hot else ".07"})">'
            f'{word}</div>')


def flair_rows(hot=None):
    def one(label, value, n, of, is_hot):
        wash = ' wash' if is_hot else ''
        return (f'<div class="row{wash}" style="height:26px;margin:0 -14px;'
                f'padding:0 14px">'
                f'<span style="font-size:12.5px;opacity:.85;width:112px;'
                f'flex:none">{label}</span>'
                f'{tri(-1, "rgba(79,214,255,.55)")}'
                f'<span style="font-size:12.5px;color:{FRIEND};'
                f'margin:0 10px">{value}</span>'
                f'{tri(1, "rgba(79,214,255,.55)")}'
                f'<span class="lbl" style="margin-left:auto">{n} of {of}'
                f'</span></div>')
    return (rule("flair") + one("hull", "Wedge", 2, 8, hot == "hull")
            + one("wake", "ion", 1, 4, hot == "wake"))


# --- the account the boards show ---------------------------------------------
#
# The real melee shelf, from sim_base_entitlements and fill_kit_ceiling:
# stats are dealt whole, the gun's ladder is dealt whole, and what is left
# to sell is a bomb rung, three spray rungs, two shrapnel rungs, and a third
# repel and burst. This account has bought spray to 3 and holds 130 rivets.
#
# (name, tint, arena, base, owned, slotted, readout maker)
WALLET = 130

FLIGHT = [(n, c, 8, 8, 8, s, None)
          for (n, c), s in zip(STATS, (5, 4, 5, 2, 2))]

GUN = [
    ("gun level", GOLD, 2, 2, 2, 2, "lvl"),
    ("spray", GOLD, 5, 2, 3, 2, "cnt"),
    ("bounce", GOLD, 1, 1, 1, 1, None),
    ("freeze", GOLD, 1, 1, 1, 0, None),
]
BOMB = [
    ("bomb level", BOMBC, 2, 1, 1, 1, "lvl"),
    ("bounce", BOMBC, 2, 2, 2, 0, None),
    ("proximity", BOMBC, 1, 1, 1, 1, None),
    ("shrapnel", BOMBC, 3, 1, 1, 1, None),
    ("freeze", BOMBC, 1, 1, 1, 0, None),
]
CHARGES = [
    ("repel", GOLD, 3, 2, 2, 2, None),
    ("burst", GOLD, 3, 2, 2, 2, None),
]


def next_price(base, owned, arena):
    """meta/upgrades.rs: 20 + 20 per rung already bought past the base."""
    if owned >= arena:
        return None
    return 20 + 20 * (owned - base)


def readout_of(kind, slotted):
    if kind == "lvl":
        return "L" + str(slotted + 1)
    if kind == "cnt":
        return str(slotted + 1)
    return None


# --- the merged ladder, three kinds of step ----------------------------------


def hangar_cells(tint, arena, owned, slotted, priced):
    cells = []
    for k in range(1, owned + 1):
        cells.append(("on" if k <= slotted else "own", tint))
    for k in range(owned + 1, arena + 1):
        cells.append(("next" if (priced and k == owned + 1) else "lock", ""))
    return pip_svg(cells)


def hangar_group(label, slots, hot_name=None, priced=True, level_price=30):
    out = [rule(label)]
    for name, tint, arena, base, owned, slotted, kind in slots:
        price = next_price(base, owned, arena)
        if price is not None and kind == "lvl":
            price = level_price
        tail = (price_tag(price) if (priced and price is not None) else "")
        out.append(ladder_row(
            name, hangar_cells(tint, arena, owned, slotted,
                               priced and price is not None),
            readout=readout_of(kind, slotted), tail=tail,
            hot=(name == hot_name)))
    return "".join(out)


def band_row(left, right):
    return (f'<div class="row" style="height:40px;border-bottom:1px solid '
            f'rgba(63,88,120,.45);margin:0 -14px;padding:0 14px;gap:10px">'
            f'{left}<div style="flex:1"></div>{right}</div>')


def build_selector():
    return (f'<div class="row" style="gap:9px">'
            f'{tri(-1, "rgba(79,214,255,.55)")}'
            f'<span style="font-size:15px">striker</span>'
            f'<span class="lbl">edited</span>'
            f'{tri(1, "rgba(79,214,255,.55)")}</div>')


def kit_figure(spent=30, total=30):
    return (f'<div class="row" style="gap:6px"><span class="lbl">kit</span>'
            f'<span class="num" style="font-size:15px">{spent}</span>'
            f'<span class="num" style="font-size:11px;color:var(--dim)">'
            f'/ {total}</span></div>')


def wallet_figure():
    return (f'<div class="row" style="gap:5px">{rivet(12, GOLD)}'
            f'<span class="num" style="font-size:14px;color:{GOLD}">'
            f'{WALLET}</span></div>')


# --- board: one hangar -------------------------------------------------------


def teach_band(head, line, price_line=None):
    price = (f'<div class="row" style="gap:6px;margin-top:5px">{price_line}'
             f'</div>' if price_line else '')
    return (f'<div class="lbl" style="margin-bottom:5px">{head}</div>'
            f'<div style="font-size:11px;line-height:15px;'
            f'color:rgba(223,233,245,.8)">{line}</div>' + price)


TEACH_SHRAPNEL = ("the round&#39;s ending is itself an attack: it splits "
                  "into fragments of your own gun. higher rungs throw more.")


def charges_with_boxes(hot_name=None, priced=True):
    out = [rule("charges")]
    for i, (name, tint, arena, base, owned, slotted, kind) in enumerate(CHARGES):
        price = next_price(base, owned, arena)
        tail = ""
        if slotted > 0:
            key = "shift" if i == 0 else "x"
            tail += charge_box(f"charge {i + 1} &#183; {key}")
        if priced and price is not None:
            tail += price_tag(price)
        out.append(ladder_row(
            name, hangar_cells(tint, arena, owned, slotted,
                               priced and price is not None),
            tail=tail, hot=(name == hot_name)))
    return "".join(out)


# --- the revised hangar: circles only, and a reading that slides in ----------

TEACH_BOUNCE = ("walls stop eating your rounds and reflect them instead. "
                "each rung is another bounce before the round ends.")

# The same account with a point taken off speed, so the meter has something
# to say and the stats show a ring beside their solids.
FLIGHT2 = [(n, c, 8, 8, 8, s, None)
           for (n, c), s in zip(STATS, (5, 4, 4, 2, 2))]
SPENT2, LEFT2 = 28, 2

TABS2 = ["play", "ship", "friends", "standings", "settings"]


def circle_cells(tint, arena, owned, slotted, k=11, r=4.4, step=13):
    cells = ([("on", tint)] * slotted
             + [("ring", tint)] * (owned - slotted)
             + [("dim", "")] * (arena - owned))
    return pip_svg(cells, k=k, r=r, step=step)


def circle_group(label, slots, hot_name=None, level_price=30):
    out = [rule(label)]
    for name, tint, arena, base, owned, slotted, kind in slots:
        price = next_price(base, owned, arena)
        if price is not None and kind == "lvl":
            price = level_price
        tail = price_tag(price) if price is not None else ""
        out.append(ladder_row(
            name, circle_cells(tint, arena, owned, slotted),
            readout=readout_of(kind, slotted), tail=tail,
            hot=(name == hot_name)))
    return "".join(out)


def circle_charges():
    out = [rule("charges")]
    for i, (name, tint, arena, base, owned, slotted, kind) in \
            enumerate(CHARGES):
        price = next_price(base, owned, arena)
        tail = ""
        if slotted > 0:
            key = "shift" if i == 0 else "x"
            tail += charge_box(f"charge {i + 1} &#183; {key}")
        if price is not None:
            tail += price_tag(price)
        out.append(ladder_row(
            name, circle_cells(tint, arena, owned, slotted), tail=tail))
    return "".join(out)


def points_meter():
    fill = SPENT2 / 30 * 100
    bar = (f'<div style="position:relative;width:52px;height:4px;'
           f'background:rgba(108,122,144,.25)">'
           f'<div style="position:absolute;left:0;top:0;bottom:0;'
           f'width:{fill:.0f}%;background:rgba(79,214,255,.85)"></div></div>')
    return (f'<div class="col" style="align-items:flex-end;gap:4px">'
            f'<span class="lbl">points</span>'
            f'<div class="row" style="gap:8px">{bar}'
            f'<span class="num" style="font-size:11px;'
            f'color:rgba(223,233,245,.9)">{LEFT2} left</span></div></div>')


def x_key():
    return ('<div class="key" style="width:26px;height:26px;flex:none">'
            '<svg width="11" height="11" viewBox="0 0 12 12">'
            '<path d="M1.5 1.5 L10.5 10.5 M10.5 1.5 L1.5 10.5" '
            'stroke="#9fb6d4" stroke-width="1.4" '
            'stroke-linecap="square"/></svg></div>')


# The ship screen keeps no head: the row that was the logo and the account
# is the profile and the points, with the drawer's own x at its left. The
# name is a button, the one stroked box the interface presses, and the
# press on it opens the builds list.
def band2():
    name_key = (f'<div class="key" style="height:26px;padding:0 13px;'
                f'font-size:11px;color:{INK}">STRIKER</div>')
    return (f'<div class="row" style="height:48px;gap:10px;'
            f'border-bottom:1px solid rgba(63,88,120,.45);margin:0 -14px;'
            f'padding:0 14px">{x_key()}{name_key}'
            f'<span class="lbl">edited</span>'
            f'<div style="flex:1"></div>{points_meter()}</div>')


# The drawer without its head, and with the save key the edited kit earns:
# full width over the stops, gone the moment the kit matches its name again.
#
# `portrait` is the phone held upright, where the drawer is the window: the
# right-edge rule goes, because a rule against nothing marks nothing, and
# the foot deepens so the stop labels clear the home indicator. Nothing else
# changes; the menu is one drawing at 390 wherever it stands.
def drawer2(page, save=False, lit="ship", portrait=False, short=False):
    foot = 78 if portrait else 64
    save_h = 32 if short else 40
    bottom = foot + ((save_h + 14) if save else 0)
    savekey = ""
    if save:
        savekey = (f'<div class="key" style="position:absolute;left:14px;'
                   f'right:14px;bottom:{foot + 8}px;height:{save_h}px;'
                   f'font-size:12px;'
                   f'color:{INK};border-color:rgba(79,214,255,.85);'
                   f'background:rgba(79,214,255,.10)">SAVE</div>')
    stops = stops_bar(TABS2, lit)
    if portrait:
        stops = stops.replace('height:64px', 'height:78px').replace(
            'justify-content:center;gap:4px;height:100%',
            'justify-content:center;gap:4px;height:100%;'
            'padding-bottom:14px')
    edge = ("" if portrait else
            f'<div style="position:absolute;right:0;top:0;bottom:0;'
            f'width:1px;background:{RULE}"></div>')
    return (f'<div style="position:absolute;inset:0;'
            f'background:rgba(3,5,10,.86)"></div>'
            f'<div style="position:absolute;left:0;right:0;top:0;'
            f'bottom:{bottom}px;padding:0 14px;overflow:hidden">{page}</div>'
            + savekey + stops + edge)


def hangar2_page(hot=None):
    return (band2()
            + circle_group("flight", FLIGHT2)
            + circle_group("gun", GUN, hot_name=hot)
            + circle_group("bomb", BOMB, hot_name=hot)
            + circle_charges()
            + flair_rows())


def hangar2_board():
    body = drawer2(hangar2_page(hot="shrapnel"), save=True)
    board("Main.dc.html", 390, 880, body, seed=41)


# --- the same screens at the phone's own window ------------------------------
#
# 390 by 844, the drawer as the whole screen. What these two boards prove is
# the fit: the merged page, save key and all, holds an upright phone with no
# scroll on melee's slot set.


def portrait_boards():
    body = drawer2(hangar2_page(hot="shrapnel"), save=True, portrait=True)
    board("PortraitShip.dc.html", 390, 844, body, seed=49)
    page = detail_page(
        "bomb add-on", "shrapnel",
        circle_cells(BOMBC, 3, 1, 1, k=13, r=5.5, step=17),
        "1 dealt to everybody &#183; 2 to climb",
        TEACH_SHRAPNEL, price=20,
        foot=('<div class="lbl" style="margin-top:18px;line-height:15px">'
              'a swipe right, or the chevron, puts the ship page back</div>'))
    board("PortraitBuy.dc.html", 390, 844, drawer2(page, portrait=True),
          seed=50)


# --- the phone on its side: the drawer docked, the fight beside it -----------
#
# 844 by 390. The drawer keeps its 390 and the fight keeps the rest, so
# height is the scarce edge: the ship page scrolls where portrait held it
# whole, the save key drops a size, and the reading tightens its margins.
# The radar stays in the fight's corner; the clock band the drawer covers
# is down while it is over it.


def compact_detail(kind, name, cells, caption, teach, price):
    price_row = (f'<div class="row" style="gap:8px;margin-top:12px">'
                 f'{rivet(12, GOLD)}'
                 f'<span class="num" style="font-size:13px;color:{GOLD}">'
                 f'{price}</span>'
                 f'<span class="lbl">buys the next rung</span>'
                 f'<div style="flex:1"></div>'
                 f'<span class="lbl">wallet</span>{rivet(10, GOLD)}'
                 f'<span class="num" style="font-size:11px;color:{GOLD}">'
                 f'{WALLET}</span></div>')
    buy = (f'<div class="key" style="width:100%;height:34px;'
           f'font-size:12px;color:{INK};'
           f'border-color:rgba(255,209,102,.9);'
           f'background:rgba(255,209,102,.10);margin-top:12px">BUY</div>')
    return (back_row()
            + f'<div class="lbl" style="margin:10px 0 4px">{kind}</div>'
            + f'<div style="font-size:19px;margin-bottom:8px">{name}</div>'
            + f'<div style="font-size:11.5px;line-height:16px;'
              f'color:rgba(223,233,245,.85)">{teach}</div>'
            + f'<div class="row" style="margin:12px 0 4px">{cells}</div>'
            + f'<div class="lbl">{caption}</div>'
            + price_row + buy)


def landscape_body(page, save=False):
    thumb = ('<div style="position:absolute;left:385px;top:64px;width:3px;'
             'height:70px;background:rgba(63,88,120,.9)"></div>'
             '<div style="position:absolute;left:385px;top:52px;width:3px;'
             'height:260px;background:rgba(63,88,120,.25)"></div>')
    return (scene_svg(844, 390, 51)
            + f'<div style="position:absolute;left:0;top:0;width:390px;'
              f'height:390px">{drawer2(page, save=save, short=True)}</div>'
            + (thumb if save else "")
            + f'<div style="position:absolute;right:14px;top:14px">'
              f'{minimap(96, 52)}</div>')


def landscape_boards():
    board("LandscapeShip.dc.html", 844, 390,
          landscape_body(hangar2_page(), save=True), seed=53)
    page = compact_detail(
        "bomb add-on", "shrapnel",
        circle_cells(BOMBC, 3, 1, 1, k=13, r=5.5, step=17),
        "1 dealt to everybody &#183; 2 to climb",
        TEACH_SHRAPNEL, 20)
    board("LandscapeBuy.dc.html", 844, 390, landscape_body(page), seed=54)


# --- the reading, slid in from the right -------------------------------------


def back_row(place="ship"):
    return (f'<div class="row" style="height:48px;gap:8px;'
            f'border-bottom:1px solid rgba(63,88,120,.45);'
            f'margin:0 -14px;padding:0 14px">'
            + tri(-1, "rgba(108,122,144,.9)")
            + f'<span class="lbl">{place}</span></div>')


def detail_page(kind, name, cells, caption, teach, price=None, foot=None):
    price_row, buy = "", ""
    if price is not None:
        price_row = (f'<div class="row" style="gap:8px;margin-top:22px">'
                     f'{rivet(13, GOLD)}'
                     f'<span class="num" style="font-size:15px;color:{GOLD}">'
                     f'{price}</span>'
                     f'<span class="lbl">buys the next rung</span>'
                     f'<div style="flex:1"></div>'
                     f'<span class="lbl">wallet</span>{rivet(11, GOLD)}'
                     f'<span class="num" style="font-size:12px;color:{GOLD}">'
                     f'{WALLET}</span></div>')
        buy = (f'<div class="key" style="width:100%;height:44px;'
               f'font-size:13px;color:{INK};'
               f'border-color:rgba(255,209,102,.9);'
               f'background:rgba(255,209,102,.10);margin-top:18px">BUY</div>')
    return (back_row()
            + f'<div class="lbl" style="margin:18px 0 6px">{kind}</div>'
            + f'<div style="font-size:24px;margin-bottom:14px">{name}</div>'
            + f'<div style="font-size:12.5px;line-height:18px;'
              f'color:rgba(223,233,245,.85)">{teach}</div>'
            + f'<div class="row" style="margin:20px 0 6px">{cells}</div>'
            + f'<div class="lbl" style="margin-bottom:4px">{caption}</div>'
            + price_row + buy + (foot or ""))


def buy2_board():
    page = detail_page(
        "bomb add-on", "shrapnel",
        circle_cells(BOMBC, 3, 1, 1, k=13, r=5.5, step=17),
        "1 dealt to everybody &#183; 2 to climb",
        TEACH_SHRAPNEL, price=20,
        foot=('<div class="lbl" style="margin-top:18px;line-height:15px">'
              'a swipe right, or the chevron, puts the ship page back</div>'))
    board("Buy.dc.html", 390, 880, drawer2(page), seed=42)


def owned_board():
    page = detail_page(
        "gun add-on", "bounce",
        circle_cells(GOLD, 1, 1, 1, k=13, r=5.5, step=17),
        "dealt to everybody &#183; equipped",
        TEACH_BOUNCE,
        foot=('<div class="lbl" style="margin-top:22px;line-height:15px">'
              'nothing to buy here: the arena deals every rung of this'
              '</div>'))
    board("Owned.dc.html", 390, 880, drawer2(page), seed=46)


# --- the builds list, behind the name ----------------------------------------


def builds_board():
    rows = []
    for name, starter, current in (("gunner", True, False),
                                   ("bomber", True, False),
                                   ("control", True, False),
                                   ("striker", False, True)):
        mark = ('<span class="lbl" style="margin-left:auto">starter</span>'
                if starter else '')
        wash = ' wash' if current else ''
        col = FRIEND if current else INK
        rows.append(
            f'<div class="row{wash}" style="height:30px;margin:0 -14px;'
            f'padding:0 14px"><span style="font-size:13px;color:{col}">'
            f'{name}</span>{mark}</div>')
    keys = ('<div class="row" style="gap:10px;margin-top:16px">'
            '<div class="key" style="flex:1;height:32px;font-size:10px;'
            'color:#dfe9f5;border-color:rgba(79,214,255,.7);'
            'background:rgba(79,214,255,.08)">NEW</div>'
            '<div class="key" style="flex:1;height:32px;font-size:10px">'
            'DELETE</div></div>')
    page = (back_row()
            + '<div class="lbl" style="margin:18px 0 8px">builds</div>'
            + ''.join(rows) + keys)
    board("Builds.dc.html", 390, 880, drawer2(page), seed=45)


# --- the new screen, behind NEW ----------------------------------------------


def new_board():
    field = (f'<div class="row" style="height:38px;border:1px solid '
             f'rgba(63,88,120,.75);background:rgba(10,15,24,.6);'
             f'padding:0 12px;margin:20px 0 6px">'
             f'<span style="font-family:var(--mono);font-size:13.5px">'
             f'striker 2</span>'
             f'<div style="width:1.5px;height:17px;background:{FRIEND};'
             f'margin-left:3px"></div></div>')
    create = (f'<div class="key" style="width:100%;height:40px;'
              f'font-size:12px;color:{INK};'
              f'border-color:rgba(79,214,255,.85);'
              f'background:rgba(79,214,255,.10);margin-top:20px">CREATE'
              f'</div>')
    page = (back_row("builds")
            + '<div class="lbl" style="margin:18px 0 6px">builds</div>'
            + '<div style="font-size:24px;margin-bottom:14px">new build'
              '</div>'
            + '<div style="font-size:12.5px;line-height:18px;'
              'color:rgba(223,233,245,.85)">keeps the thirty points in '
              'hand under a name of yours.</div>'
            + field
            + '<div class="lbl">a name for this build</div>'
            + create
            + '<div class="lbl" style="margin-top:18px;line-height:15px">'
              'create slides back to the list with the new build lit'
              '</div>')
    board("NewBuild.dc.html", 390, 880, drawer2(page), seed=48)


# --- the points panel, behind the meter --------------------------------------


def points_board():
    def legend(kind, col, words):
        return (f'<div class="row" style="gap:10px;height:26px">'
                + pip_svg([(kind, col)], k=13, r=5.5, step=17)
                + f'<span style="font-size:12px;'
                  f'color:rgba(223,233,245,.85)">{words}</span></div>')
    fill = SPENT2 / 30 * 100
    meter = (f'<div class="row" style="gap:12px;margin:22px 0 6px">'
             f'<div style="position:relative;flex:1;height:6px;'
             f'background:rgba(108,122,144,.25)">'
             f'<div style="position:absolute;left:0;top:0;bottom:0;'
             f'width:{fill:.0f}%;background:rgba(79,214,255,.85)"></div>'
             f'</div>'
             f'<span class="num" style="font-size:12px">{SPENT2} spent '
             f'&#183; {LEFT2} left</span></div>')
    page = (back_row()
            + '<div class="lbl" style="margin:18px 0 6px">points</div>'
            + '<div style="font-size:24px;margin-bottom:14px">thirty points'
              '</div>'
            + '<div style="font-size:12.5px;line-height:18px;'
              'color:rgba(223,233,245,.85)">every ship is a spend of the '
              'same thirty points, whoever flies it and whatever the '
              'account owns. press a circle to spend a point there; press '
              'it again to take the point back and put it somewhere else.'
              '</div>'
            + meter
            + '<div class="lbl" style="margin:20px 0 8px">what a circle '
              'says</div>'
            + legend("on", FRIEND, "equipped: one of your thirty")
            + legend("ring", FRIEND, "owned, waiting for a point")
            + legend("dim", "", "not yours yet: its price sits on the row")
            )
    board("Points.dc.html", 390, 880, drawer2(page), seed=47)


# --- board: fit and buy ------------------------------------------------------


def mode_toggle(lit):
    def cell(word, on):
        return (f'<div style="padding:3px 14px;font-size:10px;'
                f'font-family:var(--mono);letter-spacing:.08em;'
                f'color:{INK if on else DIM};'
                f'background:{"rgba(79,214,255,.16)" if on else "transparent"}'
                f'">{word}</div>')
    return (f'<div class="row" style="border:1px solid rgba(63,88,120,.75)">'
            + cell("FIT", lit == "fit") + cell("BUY", lit == "buy")
            + '</div>')


def shop_cells(tint, arena, base, owned):
    """The shelf's reading of a ladder: the dealt run as a bar, then a pip
    per rung past it, the next buyable one in gold."""
    cells = []
    for k in range(base + 1, arena + 1):
        if k <= owned:
            cells.append(("on", tint))
        elif k == owned + 1:
            cells.append(("next", ""))
        else:
            cells.append(("lock", ""))
    return dealt_bar() + (pip_svg(cells) if cells else
                          '<span class="lbl">dealt whole</span>')


def buy_group(label, slots, level_price=30, hot_name=None):
    out = [rule(label)]
    for name, tint, arena, base, owned, slotted, kind in slots:
        price = next_price(base, owned, arena)
        if price is not None and kind == "lvl":
            price = level_price
        tail = (price_tag(price, can=price <= WALLET)
                if price is not None else
                '<span class="lbl" style="margin-left:auto">yours</span>')
        out.append(ladder_row(name, shop_cells(tint, arena, base, owned),
                              tail=tail, hot=(name == hot_name)))
    return "".join(out)


def lenses_board():
    fit_page = (band_row(
        f'<div class="row" style="gap:12px">{mode_toggle("fit")}'
        f'{build_selector()}</div>', kit_figure())
        + hangar_group("flight", FLIGHT, priced=False)
        + hangar_group("gun", GUN, hot_name="shrapnel", priced=False)
        + hangar_group("bomb", BOMB, hot_name="shrapnel", priced=False)
        + charges_with_boxes(priced=False)
        + flair_rows())
    fit_teach = teach_band(
        "bomb &#183; shrapnel", TEACH_SHRAPNEL,
        price_line=('<span class="lbl">the dim rungs are on the shelf: '
                    'see buy</span>'))
    fit = drawer(fit_page, ["play", "ship", "friends", "standings",
                            "settings"], "ship", teach=fit_teach)

    buy_page = (band_row(
        f'<div class="row" style="gap:12px">{mode_toggle("buy")}'
        f'<span class="lbl">what rivets buy here</span></div>',
        wallet_figure())
        + rule("flight", mt=14)
        + ladder_row("all five stats", '<span class="lbl">dealt to '
                     'everybody, whole</span>', h=24)
        + buy_group("gun", GUN, hot_name="shrapnel")
        + buy_group("bomb", BOMB, hot_name="shrapnel")
        + buy_group("charges", CHARGES))
    buy_teach = teach_band(
        "bomb &#183; shrapnel", TEACH_SHRAPNEL,
        price_line=(f'{rivet(11, GOLD)}<span class="num" style="font-size:'
                    f'11px;color:{GOLD}">20</span>'
                    f'<span class="lbl">buys the next rung &#183; '
                    f'press the row</span>'))
    buy = drawer(buy_page, ["play", "ship", "friends", "standings",
                            "settings"], "ship", teach=buy_teach)

    body = (f'<div style="position:absolute;left:0;top:0;width:390px;'
            f'height:880px">{fit}</div>'
            f'<div style="position:absolute;left:440px;top:0;width:390px;'
            f'height:880px">{buy}</div>')
    board("Lenses.dc.html", 830, 880, body, seed=43)


# --- board: two stops, linked ------------------------------------------------


def linked_board():
    # The ship page keeps the split: no figures, only the shelf's mark on a
    # row with more to climb, and the teach band says where the press lands.
    ship_page = (band_row(build_selector(), kit_figure())
                 + hangar_group("flight", FLIGHT, priced=False)
                 + "".join([rule("gun")] + [
                     ladder_row(name,
                                hangar_cells(tint, arena, owned, slotted,
                                             owned < arena),
                                readout=readout_of(kind, slotted),
                                tail=(price_tag("", figure=False)
                                      if owned < arena else ""),
                                hot=(name == "shrapnel"))
                     for name, tint, arena, base, owned, slotted, kind
                     in GUN])
                 + "".join([rule("bomb")] + [
                     ladder_row(name,
                                hangar_cells(tint, arena, owned, slotted,
                                             owned < arena),
                                readout=readout_of(kind, slotted),
                                tail=(price_tag("", figure=False)
                                      if owned < arena else ""),
                                hot=(name == "shrapnel"))
                     for name, tint, arena, base, owned, slotted, kind
                     in BOMB])
                 + charges_with_boxes(priced=False)
                 + flair_rows())
    ship_teach = teach_band(
        "bomb &#183; shrapnel", TEACH_SHRAPNEL,
        price_line=(f'{rivet(11, GOLD)}'
                    f'<span class="lbl">two rungs are on the shelf &#183; '
                    f'press for the price</span>'))
    ship = drawer(ship_page, ["play", "ship", "upgrades", "friends",
                              "standings", "settings"], "ship",
                  teach=ship_teach)

    # And where the press lands: the shelf, opened on that slot's card.
    cells = pip_svg([("on", BOMBC), ("next", ""), ("lock", "")], k=13)
    shelf_page = f"""
  {band_row('<div class="row" style="gap:8px">'
            + tri(-1, "rgba(108,122,144,.9)")
            + '<span class="lbl">upgrades</span></div>', wallet_figure())}
  <div class="lbl" style="margin:16px 0 6px">bomb add-on</div>
  <div style="font-size:24px;margin-bottom:14px">shrapnel</div>
  <div style="font-size:12.5px;line-height:18px;
       color:rgba(223,233,245,.85)">{TEACH_SHRAPNEL}</div>
  <div class="row" style="gap:10px;margin:20px 0 6px">{dealt_bar()}{cells}
  </div>
  <div class="lbl" style="margin-bottom:18px">1 dealt to everybody,
    2 to climb</div>
  <div class="row" style="gap:8px">
    {rivet(13, GOLD)}
    <span class="num" style="font-size:15px;color:{GOLD}">20</span>
    <span class="lbl">buys the next rung</span>
  </div>
  <div class="key" style="width:100%;height:44px;font-size:13px;
       color:{INK};border-color:rgba(255,209,102,.9);
       background:rgba(255,209,102,.10);margin-top:20px">BUY</div>
  <div class="lbl" style="margin-top:18px;line-height:15px">
    bought rungs land on the ship page at once: the way back is the
    chevron, or the ship stop</div>"""
    shelf = drawer(shelf_page, ["play", "ship", "upgrades", "friends",
                                "standings", "settings"], "upgrades")

    body = (f'<div style="position:absolute;left:0;top:0;width:390px;'
            f'height:880px">{ship}</div>'
            f'<div style="position:absolute;left:440px;top:0;width:390px;'
            f'height:880px">{shelf}</div>')
    board("Linked.dc.html", 830, 880, body, seed=44)


# --- board: as shipped -------------------------------------------------------


def chip(word, held, count=None, slotted=0, hot=False):
    pips = ""
    if count and count > 1:
        pips = pip_svg([("on" if k <= slotted else "own",
                         FRIEND if k <= slotted else DIM)
                        for k in range(1, count + 1)], k=8)
        pips = (f'<div class="row" style="justify-content:center">{pips}'
                f'</div>')
    edge = (f'1.2px solid rgba(79,214,255,{"1" if hot else ".55"})'
            if (hot or held) else '1px solid rgba(63,88,120,.6)')
    bg = ('rgba(79,214,255,.2)' if held
          else ('rgba(79,214,255,.1)' if hot else 'transparent'))
    return (f'<div class="col" style="min-width:62px;height:36px;'
            f'justify-content:center;gap:2px;padding:0 12px;'
            f'border:{edge};background:{bg}">'
            f'<div class="lbl" style="text-align:center;color:'
            f'{FRIEND if held else INK};opacity:{1 if held else .8}">'
            f'{word}</div>{pips}</div>')


def shipped_ship_page():
    key = ('<div class="key" style="height:20px;padding:0 10px;'
           'font-size:9px">{}</div>')
    head = (
        '<div class="col" style="border-bottom:1px solid '
        'rgba(63,88,120,.45);margin:0 -14px;padding:8px 14px 8px">'
        '<div class="row" style="gap:10px">'
        '<span style="font-size:15px">striker</span>'
        '<span class="lbl">edited</span>'
        + key.format("RENAME") + key.format("DELETE")
        + '</div>'
        '<div class="row" style="margin-top:6px">'
        '<div style="flex:1"></div>'
        '<span class="lbl" style="margin-right:8px">kit</span>'
        '<span class="num" style="font-size:15px">30</span>'
        '<span class="num" style="font-size:11px;color:var(--dim)">'
        '&nbsp;/ 30</span></div></div>')
    profiles = "".join(
        f'<div class="row{" wash" if p == "striker" else ""}" '
        f'style="height:24px;margin:0 -14px;padding:0 14px">'
        f'<span style="font-size:12.5px;'
        f'color:{FRIEND if p == "striker" else INK};'
        f'opacity:{1 if p == "striker" else .82}">{p}</span></div>'
        for p in ("gunner", "bomber", "control", "striker"))
    new_key = ('<div class="key" style="height:22px;width:230px;'
               'font-size:9px;margin:8px 0 2px">NEW</div>')

    def stat_ladders():
        out = [rule("stats")]
        for (name, colr, arena, base, owned, slotted, _k) in FLIGHT:
            out.append(ladder_row(
                name, pip_svg([("on" if k <= slotted else "own", colr)
                               for k in range(1, owned + 1)]),
                readout=None))
        return "".join(out)

    levels = (rule("weapon level")
              + ladder_row("gun level",
                           pip_svg([("on", GOLD), ("on", GOLD)]),
                           readout="L3")
              + ladder_row("bomb level", pip_svg([("on", BOMBC)]),
                           readout="L2"))
    gun_chips = (rule("gun")
                 + ladder_row("spray",
                              pip_svg([("on", GOLD), ("on", GOLD),
                                       ("own", GOLD)]), readout="3")
                 + '<div class="row" style="gap:8px;margin:4px 0 6px">'
                 + chip("BOUNCE", True) + chip("FREEZE", False) + '</div>')
    bomb_chips = (rule("bomb")
                  + '<div class="row" style="gap:8px;margin:4px 0 6px;'
                  'flex-wrap:wrap">'
                  + chip("BOUNCE", False, 2, 0) + chip("PROX", True)
                  + chip("SHRAPNEL", True, hot=True) + chip("FREEZE", False)
                  + '</div>')
    charges = (rule("charges")
               + ladder_row("repel", pip_svg([("on", GOLD), ("on", GOLD)]),
                            tail=charge_box("charge 1 &#183; shift"))
               + ladder_row("burst", pip_svg([("on", GOLD), ("on", GOLD)]),
                            tail=charge_box("charge 2 &#183; x")))
    scrollbar = ('<div style="position:absolute;right:2px;top:270px;'
                 'width:3px;height:170px;background:rgba(63,88,120,.8)">'
                 '</div>')
    return (head + profiles + new_key + stat_ladders() + levels + gun_chips
            + bomb_chips + charges + flair_rows() + scrollbar)


def shipped_shelf_page():
    def row(name, tint, arena, base, owned, price=None, mark="&#9678;"):
        cells = shop_cells(tint, arena, base, owned)
        tail = (price_tag(price, can=price <= WALLET)
                if price is not None else
                '<span class="lbl" style="margin-left:auto">yours</span>')
        return ladder_row(name, cells, tail=tail, name_w=104, h=30)

    head = (f'<div class="row" style="margin:10px 0 2px">'
            f'<span class="lbl">rivets</span><div style="flex:1"></div>'
            f'<span class="num" style="font-size:14px;color:{GOLD}">'
            f'{WALLET}</span></div>')
    stats = rule("stats") + "".join(
        row(n, c, 8, 8, 8) for n, c, *_ in FLIGHT)
    levels = (rule("weapon level")
              + row("gun rung", GOLD, 2, 2, 2)
              + row("bomb rung", BOMBC, 2, 1, 1, 30))
    gun = (rule("gun add-ons")
           + row("spray", GOLD, 5, 2, 3, 40)
           + row("bouncing", GOLD, 1, 1, 1))
    bomb = (rule("bomb add-ons")
            + row("bomb bouncing", BOMBC, 2, 2, 2)
            + row("proximity", BOMBC, 1, 1, 1)
            + row("shrapnel", BOMBC, 3, 1, 1, 20)
            + row("bomb freeze", BOMBC, 1, 1, 1))
    charges = (rule("charges")
               + row("repel", GOLD, 3, 2, 2, 20)
               + row("burst", GOLD, 3, 2, 2, 20))
    scrollbar = ('<div style="position:absolute;right:2px;top:120px;'
                 'width:3px;height:300px;background:rgba(63,88,120,.8)">'
                 '</div>')
    return head + stats + levels + gun + bomb + charges + scrollbar


def current_board():
    tabs = ["play", "ship", "upgrades", "friends", "standings", "settings"]
    ship = drawer(shipped_ship_page(), tabs, "ship")
    shelf = drawer(shipped_shelf_page(), tabs, "upgrades")
    body = (f'<div style="position:absolute;left:0;top:0;width:390px;'
            f'height:880px">{ship}</div>'
            f'<div style="position:absolute;left:440px;top:0;width:390px;'
            f'height:880px">{shelf}</div>')
    board("Current.dc.html", 830, 880, body, seed=40)


hangar2_board()
portrait_boards()
landscape_boards()
buy2_board()
owned_board()
builds_board()
new_board()
points_board()
current_board()
lenses_board()
linked_board()
