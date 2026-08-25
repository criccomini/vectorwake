#!/usr/bin/env python3
"""Assemble the artboards for the ship and upgrades rethink.

The brief: the ship page is busy and hard to learn, and the upgrades tab
feels like it belongs inside it. A pilot who cannot turn something on should
see what it costs where the refusal happens, not on another stop.

Five boards. One shows the two pages as shipped, at the drawer's own 390
point measure, so the directions can be compared against the thing that
exists. Three directions follow:

  One hangar    the tabs merge. Every slot the arena has is on the ship
                page; a rung you do not own is drawn dim with its price on
                the row, and pressing into it opens a buy card. The wallet
                lives on the card alone.
  Fit and buy   one geography, two lenses. The same page under a FIT | BUY
                toggle: FIT spends the thirty points and shows no prices,
                BUY relights the same rows in shop terms.
  Two stops,    the smallest change. Both tabs stay; the ship page draws
  linked        the rungs it is not showing today with a shelf mark, and
                pressing one lands on that slot's card in upgrades.

Every direction bakes in one shared cleanup, argued in README.md: one row
grammar (the chips become ladders), the build library folded into a selector
row, and a teach line pinned over the stops for whatever row the cursor is
on.

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


def pip_svg(cells, k=11):
    """A run of ladder steps. Each cell is (kind, color): `on` a filled
    disc, `own` a hollow disc (owned, not slotted), `lock` a dim square
    (the arena has it, the account does not), `next` the gold diamond the
    next purchase would light."""
    step = 13
    w = step * len(cells) + 2
    out = []
    for i, (kind, col) in enumerate(cells):
        cx = i * step + 6
        if kind == "on":
            out.append(f'<circle cx="{cx}" cy="{k // 2 + 1}" r="4.4" '
                       f'fill="{col}"/>')
        elif kind == "own":
            out.append(f'<circle cx="{cx}" cy="{k // 2 + 1}" r="3.9" '
                       f'fill="none" stroke="{col}" stroke-width="1.1" '
                       f'opacity=".8"/>')
        elif kind == "lock":
            out.append(f'<rect x="{cx - 3}" y="{k // 2 - 2}" width="6" '
                       f'height="6" fill="none" stroke="{DIM}" '
                       f'stroke-width="1" opacity=".55"/>')
        elif kind == "next":
            out.append(f'<path d="M{cx} {k // 2 - 4.5} L{cx + 4.5} '
                       f'{k // 2 + 1} L{cx} {k // 2 + 6.5} L{cx - 4.5} '
                       f'{k // 2 + 1} Z" fill="none" stroke="{GOLD}" '
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


def hangar_body(hot="shrapnel", priced=True):
    return (band_row(build_selector(), kit_figure())
            + hangar_group("flight", FLIGHT, priced=priced)
            + hangar_group("gun", GUN, hot_name=hot, priced=priced)
            + hangar_group("bomb", BOMB, hot_name=hot, priced=priced)
            + charges_with_boxes(priced=priced)
            + flair_rows())


def hangar_board():
    teach = teach_band(
        "bomb &#183; shrapnel",
        TEACH_SHRAPNEL,
        price_line=(f'{rivet(11, GOLD)}<span class="num" style="font-size:'
                    f'11px;color:{GOLD}">20</span>'
                    f'<span class="lbl">buys the next rung &#183; press it'
                    f'</span>'))
    page = hangar_body()
    body = drawer(page, ["play", "ship", "friends", "standings", "settings"],
                  "ship", teach=teach)
    board("Main.dc.html", 390, 880, body, seed=41)


# --- board: the buy card -----------------------------------------------------


def buy_card():
    cells = pip_svg([("on", BOMBC), ("next", ""), ("lock", "")], k=13)
    return f"""
  <div style="position:absolute;inset:0;background:rgba(3,5,10,.72)"></div>
  <div style="position:absolute;left:22px;right:22px;top:190px;
       border:1px solid rgba(63,88,120,.9);background:rgba(5,8,14,.97);
       padding:18px 18px 16px">
    <div class="lbl">bomb add-on</div>
    <div style="font-size:22px;margin:8px 0 12px">shrapnel</div>
    <div style="font-size:12px;line-height:17px;color:rgba(223,233,245,.85)">
      {TEACH_SHRAPNEL}</div>
    <div class="row" style="gap:10px;margin:16px 0 4px">{dealt_bar()}{cells}
    </div>
    <div class="lbl" style="margin:6px 0 14px">1 dealt to everybody,
      2 to climb</div>
    <div class="row" style="gap:8px">
      {rivet(13, GOLD)}
      <span class="num" style="font-size:15px;color:{GOLD}">20</span>
      <span class="lbl">buys the next rung</span>
      <div style="flex:1"></div>
      <span class="lbl">wallet</span>
      {rivet(11, GOLD)}
      <span class="num" style="font-size:12px;color:{GOLD}">{WALLET}</span>
    </div>
    <div class="row" style="gap:10px;margin-top:16px">
      <div class="key" style="flex:1;height:40px;font-size:13px;
           color:{INK};border-color:rgba(255,209,102,.9);
           background:rgba(255,209,102,.10)">BUY</div>
      <div class="key" style="width:90px;height:40px;font-size:11px">BACK</div>
    </div>
  </div>"""


def buy_board():
    page = hangar_body()
    body = drawer(page, ["play", "ship", "friends", "standings", "settings"],
                  "ship", overlay=buy_card())
    board("BuyCard.dc.html", 390, 880, body, seed=42)


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


current_board()
hangar_board()
buy_board()
lenses_board()
linked_board()
