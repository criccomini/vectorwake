#!/usr/bin/env python3
"""Assemble the artboards for one board.

Four things on the glass say who is in the room and how it is going, and
they are four drawings: the band and the roster it opens, the ending that
takes the same roster and zooms it under a full-window wash, and the side
list that used to be a stop in the menu column and left it in decision 143
waiting for this. Chris's ask: one thing, toggled in game, up between
rounds, not taking over the page, fitting a monitor, an upright phone and a
sideways one.

Every direction here is the same object. The band stays the instrument it
is. What it opens is the room in sections, one per side, and a side's head
is the way onto that side: the head of the side you fly for wears the
here mark, and any other side's head carries JOIN while it has a seat, and
says FULL when it does not. The pilots stand under their head with their
figures; the watchers at the foot. At the whistle the same panel comes up
on its own, at the same size, in the same place, and grows the one line it
cannot know mid-match, who took it and by how much; the band keeps the
clock, per decision 94. No zoom, no 0.8 wash: the tint the menu uses.

What the directions disagree about is where it stands:

  Hang   one column under the band, where the board is today
  Wings  a wing under each side of the clock, the middle left clear
  Sheet  the menu's own panel, up through the bottom edge

Seven boards each: three windows open mid-match, the same three at the
whistle, and Free Roam on a monitor, since eight sides of eight is the
test of putting the side picker in the roster. Plus one sheet of the
shared anatomy.

The match is the one every ending mock has been judged against: Caisson
takes it 20 to 17, and the viewer is DRiFT, nought and one with six assists
on the losing side. The design system is the client's: hues from
client/arena/palette.lua, the band, key and row measures from ui.lua, the
menu language of decisions 104 to 108, and the two faces the client
carries.

Rebuild with: python3 build.py
"""

import random
from pathlib import Path

HERE = Path(__file__).parent

FORMS = {
    "Desktop": (1440, 810),
    "Landscape": (844, 390),
    "Portrait": (390, 844),
}
DIRECTIONS = ["Hang", "Wings", "Sheet"]

# --- the palette, verbatim from client/arena/palette.lua ---------------------
BG = "#05070c"
INK = "#dfe9f5"
DIM = "#6c7a90"
READ = "#9fb6d4"
MUTE = "#8593a9"
FRIEND = "#4fd6ff"
ENEMY = "#ffa552"
TILE = "#3f5878"        # RADAR_TILE: every rule and resting edge
BTN = "#0a0f18"         # BTN_BG: the glass's own tint
PAID = "#8dffb0"        # what a match paid, and the MVP mark
HURT = "#ff505a"
BOUNTY = "#ffe08a"
KEY_EDGE = "#55708f"

# --- the geography, from ui.lua ----------------------------------------------
PAD = 14
KEY_H = 26              # the clock is one key tall
LINE = 18               # one row of a HUD list
HEAD = 28               # a side's head in the HUD voice
ROW = 44                # the menu's one row height
PANEL_MAX = 560
RADAR = 168
COLUMN_WASH = 0.42

# --- the match ---------------------------------------------------------------
# name, human, k, d, a, what the match did to the rating
PYLON = [
    ("Gantry", True, 8, 4, 4, -3),
    ("Bellwether", False, 6, 3, 5, -2),
    ("Ozone", False, 3, 7, 3, -5),
    ("DRiFT", True, 0, 1, 6, -6),
]
CAISSON = [
    ("Carrack", True, 6, 5, 3, 9),
    ("Isobar", False, 5, 5, 3, 4),
    ("Cirrus", False, 5, 6, 7, 3),
    ("Jackstay", False, 4, 4, 8, 4),
]
ME = "DRiFT"
MVP = "Carrack"
WATCHERS = ["Halyard", "Moss"]

# name, color, score, humans, cap, pilots, mine
SIDES = [
    ("Pylon", FRIEND, 17, 2, 4, PYLON, True),
    ("Caisson", ENEMY, 20, 1, 4, CAISSON, False),
]

# Free Roam: eight sides, generated names, no clock and no score. The
# colors stand in for the golden-angle walk the client derives from the team
# byte; yours is cyan wherever you are.
ROAM_HUES = ["#ffa552", "#f2c94c", "#8dd45a", "#ff7b7b",
             "#d9a3ff", "#7fd1b9", "#f0a8d0"]
ROAM_NAMES = [
    ("Anvil Watch", ["Gantry", "Bellwether", "DRiFT", "Ozone", "Tideline"]),
    ("Bight", ["Carrack", "Isobar", "Cirrus", "Jackstay", "Sable",
               "Coppice", "Downdraft", "Foxglove"]),
    ("Corbel", ["Halyard", "Moss", "Kestrel"]),
    ("Dovetail", ["Marrow", "Pitch", "Quoin", "Rasp", "Sedge", "Tallow"]),
    ("Escarp", ["Umber", "Vellum"]),
    ("Fathom", ["Wicket", "Yaw", "Zephyr", "Alder", "Brindle", "Cairn",
                "Dapple"]),
    ("Gusset", ["Ember", "Flint", "Gorse", "Heath"]),
    ("Hawser", ["Ingot", "Jasper", "Kelp", "Lodestar", "Mizzen"]),
]


def roam_sides():
    rnd = random.Random(7)
    out = []
    for i, (name, pilots) in enumerate(ROAM_NAMES):
        mine = i == 0
        col = FRIEND if mine else ROAM_HUES[i - 1]
        rows = []
        for j, p in enumerate(pilots):
            human = (j % 3 != 1)
            rows.append((p, human, rnd.randint(0, 14), rnd.randint(0, 9),
                         rnd.randint(0, 6), 0))
        humans = sum(1 for r in rows if r[1])
        out.append((name, col, None, humans, 8, rows, mine))
    return out


# --- the page's chrome -------------------------------------------------------

CSS = f"""
:root{{ --bg:{BG}; --ink:{INK}; --dim:{DIM}; --read:{READ}; --mute:{MUTE};
  --friend:{FRIEND}; --enemy:{ENEMY}; --tile:{TILE}; --paid:{PAID};
  --mono:"Noto Sans Mono","DejaVu Sans Mono",ui-monospace,monospace;
  --menu:"Chakra Petch","Segoe UI",system-ui,sans-serif; }}
*{{box-sizing:border-box}}
body{{margin:0;background:var(--bg);color:var(--ink);font-family:var(--menu)}}
a{{color:var(--friend)}}a:hover{{color:#8ee6ff}}
.hud{{font-family:var(--mono);text-transform:uppercase;letter-spacing:.06em}}
.num{{font-family:var(--mono);font-variant-numeric:tabular-nums}}
.mono{{font-family:var(--mono)}}
.lbl{{font-family:var(--mono);font-size:10px;text-transform:uppercase;
  letter-spacing:.14em;color:var(--dim)}}
.row{{display:flex;align-items:center}}
.abs{{position:absolute}}
/* A button is a stroked box with a wash inside it (key_box). */
.key{{display:inline-flex;align-items:center;justify-content:center;
  border:1px solid {KEY_EDGE};background:rgba(10,15,24,.6);
  font-family:var(--mono);text-transform:uppercase;letter-spacing:.08em;
  color:var(--read);white-space:nowrap}}
/* The menu's glass: frost plus the button tint, outlined in the tile color. */
.glass{{border:1px solid rgba(63,88,120,.75);background:rgba(10,15,24,.72);
  backdrop-filter:blur(5px)}}
"""


def starfield(w, h, seed):
    rnd = random.Random(seed)
    out = [
        f"radial-gradient(620px 420px at {int(w * .72)}px {int(h * .3)}px,"
        "rgba(39,197,237,.05),transparent 70%)",
        f"radial-gradient(520px 380px at {int(w * .2)}px {int(h * .78)}px,"
        "rgba(255,157,34,.04),transparent 70%)",
    ]
    n = int(w * h / 26000)
    for k, col, r in ((n * 3, "#2a3a58", 0.9), (n * 2, "#4a6089", 1.0),
                      (n, "#93a9c8", 1.3)):
        for _ in range(k):
            x, y = rnd.randint(0, w), rnd.randint(0, h)
            out.append(f"radial-gradient(circle {r}px at {x}px {y}px,"
                       f"{col} 0 {r}px,transparent {r}px)")
    return ",".join(out)


def hull(x, y, rot, col, k=1.0):
    """A hull outline at the pen the arena draws them with: a chevron with a
    keel line, which is enough of a ship to read as one at this size."""
    return (f'<g transform="translate({x:.0f},{y:.0f}) rotate({rot}) '
            f'scale({k})" fill="none" stroke="{col}" stroke-width="1.5">'
            '<path d="M0 -14 L10 10 L0 5 L-10 10 Z"/>'
            '<path d="M0 -14 V5" opacity=".55"/></g>')


def plate(x, y, name, col, px=10):
    return (f'<text x="{x:.0f}" y="{y + 26:.0f}" text-anchor="middle" '
            f'font-family="Noto Sans Mono,monospace" font-size="{px}" '
            f'fill="{col}" opacity=".85">{name}</text>')


SHIPS = [
    ("Gantry", FRIEND, (-260, 90), 24),
    ("Carrack", ENEMY, (210, -40), -140),
    ("Isobar", ENEMY, (330, 150), -95),
    ("Ozone", FRIEND, (-120, 220), 70),
    ("Cirrus", ENEMY, (420, 300), 200),
]


def scene(w, h, seed, compact):
    cx, cy = w / 2, h / 2
    rnd = random.Random(seed)
    parts = []
    for _ in range(8 if compact else 18):
        x = rnd.randint(-60, w - 40)
        y = rnd.randint(-40, h - 40)
        bw, bh = rnd.choice([(96, 32), (32, 108), (64, 64), (150, 30),
                             (30, 150)])
        if abs(x + bw / 2 - cx) < 200 and abs(y + bh / 2 - cy) < 150:
            continue
        parts.append(
            f'<rect x="{x}" y="{y}" width="{bw}" height="{bh}" fill="#080d16" '
            f'stroke="#22344f" stroke-width="1"/>'
            f'<path d="M{x} {y} H{x + bw}" stroke="#5b82b8" stroke-width="1.4" '
            f'opacity=".55"/>')
    parts += [
        f'<path d="M{cx + 60} {cy - 32} L{cx + 76} {cy - 44}" stroke="#f7dd0b" '
        'stroke-width="2.6" stroke-linecap="round"/>',
        f'<path d="M{cx - 106} {cy + 6} L{cx - 92} {cy - 8}" stroke="#62cc35" '
        'stroke-width="2.4" stroke-linecap="round"/>',
        f'<circle cx="{cx + 258}" cy="{cy - 20}" r="4.4" fill="#ff7000"/>',
        f'<circle cx="{cx + 258}" cy="{cy - 20}" r="12" stroke="#ff7000" '
        'stroke-width="1" opacity=".4"/>',
    ]
    k = 0.7 if compact else 1.0
    parts.append(hull(cx, cy, -20, FRIEND, 1.15 * k))
    for name, col, (ox, oy), rot in SHIPS:
        x, y = cx + ox * k, cy + oy * k
        if -30 < x < w + 30 and -30 < y < h + 30:
            parts.append(hull(x, y, rot, col, k))
            parts.append(plate(x, y, name, col, 9 if compact else 10))
    return (f'<svg width="{w}" height="{h}" class="abs" '
            f'style="left:0;top:0">{"".join(parts)}</svg>')


def band(w, compact, portrait, state, roam=False):
    """The band: the clock one key tall, a side either side of it as a name
    over a number, the two lines adding up to the clock's height. An upright
    phone runs out of room and drops both names. Between matches the band
    gives up its sides and keeps the numerals with NEXT MATCH IN under them
    (decision 94). Free Roam has no clock and no score, and the band there
    is the open question this sheet does not settle."""
    top = PAD
    name_px, gap = 9, 3
    under_px = KEY_H - name_px - gap
    side_gap = 14 if compact else 22
    out = []
    if roam:
        out.append(
            f'<div class="abs hud" style="left:0;right:0;top:{top}px;'
            f'height:{KEY_H}px;display:flex;flex-direction:column;'
            f'align-items:center;justify-content:center;gap:{gap}px">'
            f'<span style="font-size:{name_px}px;color:{DIM}">Free roam</span>'
            f'<span class="num" style="font-size:{under_px}px;color:{INK};'
            f'line-height:1;opacity:.95">31 flying</span></div>')
        return "".join(out)
    clock = "0:12" if state == "end" else "2:14"
    half = KEY_H * 0.6 * len(clock) / 2
    out.append(
        f'<div class="abs num" style="left:50%;top:{top}px;'
        f'transform:translateX(-50%);font-size:{KEY_H}px;line-height:{KEY_H}px;'
        f'color:{INK};opacity:.95">{clock}</div>')
    if state == "end":
        out.append(
            f'<div class="abs hud" style="left:50%;top:{top + KEY_H + 8}px;'
            f'transform:translateX(-50%);font-size:{9 if compact else 11}px;'
            f'color:{DIM};white-space:nowrap">Next match in</div>')
        return "".join(out)
    for i, (name, col, score, *_rest) in enumerate(SIDES):
        edge = w / 2 - half - side_gap if i == 0 else w / 2 + half + side_gap
        align = "flex-end" if i == 0 else "flex-start"
        pos = (f"right:{w - edge:.0f}px" if i == 0 else f"left:{edge:.0f}px")
        label = "" if portrait else (
            f'<span class="hud" style="font-size:{name_px}px;'
            f'line-height:{name_px}px;color:{col};opacity:.85">{name}</span>')
        out.append(
            f'<div class="abs" style="{pos};top:{top}px;height:{KEY_H}px;'
            f'display:flex;flex-direction:column;align-items:{align};'
            f'justify-content:space-between">{label}'
            f'<span class="num" style="font-size:{under_px}px;'
            f'line-height:{under_px}px;color:{col}">{score}</span></div>')
    return "".join(out)


def menu_key(w, h):
    """The faint way into the menu, bottom middle, no box: three bars and
    the word (decision 102)."""
    return (f'<div class="abs" style="left:50%;bottom:10px;'
            f'transform:translateX(-50%);display:flex;flex-direction:column;'
            f'align-items:center;gap:4px;opacity:.45">'
            f'<svg width="12" height="12" viewBox="0 0 12 12" fill="none" '
            f'stroke="{READ}" stroke-width="1.6"><path d="M0 2.2H12M0 6H12M0 9.8H12"/>'
            f'</svg><span class="hud" style="font-size:10px;color:{READ}">Menu'
            f'</span></div>')


def radar(w, compact):
    side = 112 if compact else RADAR
    x = w - PAD - side
    strip = (f'<div class="abs row" style="left:{x}px;top:{PAD}px;'
             f'width:{side}px;height:{KEY_H}px;justify-content:space-between">'
             f'<span class="hud" style="font-size:10px;color:{DIM}">Pos '
             f'<span class="num" style="color:{READ}">755,591</span></span>'
             f'<span class="row" style="gap:2px;align-items:flex-end">'
             + "".join(f'<span style="width:3px;height:{4 + 2 * k}px;'
                       f'background:{PAID};opacity:{.95 if k < 3 else .3}">'
                       '</span>' for k in range(4))
             + '</span></div>')
    blips = "".join(
        f'<circle cx="{bx}" cy="{by}" r="2" fill="{col}"/>'
        for bx, by, col in ((side * .3, side * .35, ENEMY),
                            (side * .62, side * .58, ENEMY),
                            (side * .5, side * .5, FRIEND),
                            (side * .41, side * .72, FRIEND)))
    return strip + (
        f'<svg class="abs" width="{side}" height="{side}" '
        f'style="left:{x}px;top:{PAD + KEY_H + 6}px">'
        f'<rect x=".5" y=".5" width="{side - 1}" height="{side - 1}" '
        f'fill="rgba(5,7,12,.5)" stroke="{TILE}" stroke-width="1"/>'
        f'<path d="M{side * .2} {side * .3} V{side * .8} M{side * .55} {side * .2} '
        f'H{side * .85}" stroke="{TILE}" stroke-width="3" opacity=".8"/>'
        f'{blips}</svg>')


def feed(w):
    lines = ["Carrack killed Ozone", "Gantry killed Isobar",
             "Cirrus killed DRiFT"]
    y = PAD + KEY_H + 6 + RADAR + 12
    return (f'<div class="abs mono" style="right:{PAD}px;top:{y}px;'
            f'text-align:right;font-size:11px;line-height:17px;color:{DIM}">'
            + "".join(f'<div style="opacity:{1 - .22 * i}">{s}</div>'
                      for i, s in enumerate(lines)) + '</div>')


def corner_stack(h):
    marks = [("#ff5ea8", 3), ("#c27bff", 2), ("#35e0a0", 2)]
    rows = ""
    for col, n in marks:
        pips = "".join(
            f'<span style="width:6px;height:6px;border-radius:50%;'
            f'{"background:" + BOUNTY if k < n else "border:1px solid " + DIM}">'
            '</span>' for k in range(3))
        rows += (f'<div class="row" style="gap:14px;height:22px">'
                 f'<svg width="16" height="16" viewBox="0 0 16 16" fill="none" '
                 f'stroke="{col}" stroke-width="1.4"><circle cx="8" cy="8" '
                 f'r="5"/></svg><span class="row" style="gap:5px">{pips}'
                 f'</span></div>')
    return (f'<div class="abs" style="left:{PAD + 8}px;bottom:{PAD + 8}px">'
            f'{rows}</div>')


def pads(w, h):
    def ring(x, y, r):
        return (f'<div class="abs" style="left:{x - r}px;top:{y - r}px;'
                f'width:{2 * r}px;height:{2 * r}px;border-radius:50%;'
                f'border:1px solid rgba(85,112,143,.55);'
                f'background:rgba(10,15,24,.35)"></div>')
    out = [ring(80, h - 96, 54), ring(w - 64, h - 130, 26),
           ring(w - 108, h - 78, 26)]
    return "".join(out)


def chrome(w, h, compact, portrait, state, roam=False, key=True):
    """The glass under the board. Decision 67: while the board is up the
    fight behind it is washed and every other instrument recedes with it,
    radar included, so those are drawn under the tint. The band is the
    control that opened the board and stays at full strength over it."""
    out = [scene(w, h, 11 + w, compact), radar(w, compact)]
    if compact:
        out.append(pads(w, h))
    else:
        out.append(feed(w))
        out.append(corner_stack(h))
    out.append(f'<div class="abs" style="inset:0;'
               f'background:rgba(5,7,12,{COLUMN_WASH})"></div>')
    out.append(band(w, compact, portrait, state, roam))
    if key:
        out.append(menu_key(w, h))
    return "".join(out)


def band_bottom():
    return PAD + KEY_H


# --- marks -------------------------------------------------------------------


def helm(col, k=11):
    return (f'<svg width="{k}" height="{k}" viewBox="0 0 14 14" fill="none" '
            f'style="flex:none">'
            f'<path d="M2 8.2 A5 5 0 0 1 12 8.2" stroke="{col}" stroke-width="1.1"/>'
            f'<path d="M3.6 7.4 A3.4 3.4 0 0 1 10.4 7.4" stroke="{col}" '
            f'stroke-width="1" opacity=".65"/>'
            f'<path d="M1.2 9.4 H12.8" stroke="{col}" stroke-width="1.1"/></svg>')


def bot(col, k=11):
    return (f'<svg width="{k}" height="{k}" viewBox="0 0 14 14" fill="none" '
            f'style="flex:none">'
            f'<path d="M7 .8 V3" stroke="{col}" stroke-width="1"/>'
            f'<rect x="2.4" y="3.2" width="9.2" height="5.6" stroke="{col}" '
            f'stroke-width="1.1"/>'
            f'<circle cx="5.2" cy="6" r=".9" fill="{col}"/>'
            f'<circle cx="8.8" cy="6" r=".9" fill="{col}"/>'
            f'<path d="M3.4 11.2 H10.6" stroke="{col}" stroke-width="1.1"/></svg>')


def wedge(col=FRIEND, k=8):
    """The "you are here" mark: a drawn triangle in the row's gutter."""
    return (f'<svg width="{k}" height="{k}" viewBox="0 0 8 8" '
            f'style="flex:none"><polygon points="0,0 8,4 0,8" fill="{col}"/>'
            '</svg>')


def back_tri(a=0.9):
    return (f'<svg width="11" height="12" viewBox="0 0 11 12" '
            f'style="flex:none"><polygon points="2,6 9,1.5 9,10.5" '
            f'fill="rgba(79,214,255,{a})"/></svg>')


def hrule(alpha=".45"):
    return f'<div style="height:1px;background:rgba(63,88,120,{alpha})"></div>'


def ticks(alpha=".35"):
    return (f'<div style="height:4px;background:'
            f'repeating-linear-gradient(90deg,rgba(63,88,120,{alpha}) 0 1px,'
            f'transparent 1px 14px),linear-gradient(rgba(63,88,120,{alpha}),'
            f'rgba(63,88,120,{alpha})) bottom/100% 1px no-repeat"></div>')


# --- the HUD-voice board: Hang and Wings share every row ---------------------


def side_head(side, px=12, count=True, score=False, full=False, w=None):
    """A side's head, which is the way onto that side. Yours wears the here
    wedge and the here wash; another side's carries JOIN while it has a
    seat, and reads FULL, unpressable, when it has not."""
    name, col, sc, humans, cap, _pilots, mine = side
    full = full or humans >= cap
    right = ""
    if mine:
        left = wedge(col)
    else:
        left = '<span style="width:8px;flex:none"></span>'
        if full:
            right = (f'<span class="hud" style="font-size:10px;color:{MUTE}">'
                     'Full</span>')
        else:
            right = (f'<span class="key" style="height:20px;padding:0 9px;'
                     f'font-size:10px">Join</span>')
    figures = ""
    if score and sc is not None:
        figures += (f'<span class="num" style="font-size:{px + 2}px;'
                    f'color:{col};margin-left:8px">{sc}</span>')
    if count:
        figures += (f'<span class="num" style="font-size:10px;color:{DIM};'
                    f'margin-left:auto;margin-right:{10 if right else 0}px">'
                    f'{humans}/{cap}</span>')
    wash = f"background:rgba(79,214,255,.07);" if mine else ""
    return (f'<div class="row" style="height:{HEAD}px;gap:8px;'
            f'padding:0 10px 0 8px;{wash}'
            f'{"width:" + str(w) + "px" if w else ""}">{left}'
            f'<span class="hud" style="font-size:{px}px;color:{col}">{name}'
            f'</span>{figures}{right}</div>')


def cell(v, wpx=22, col=INK, a=.85, px=11):
    return (f'<span class="num" style="width:{wpx}px;text-align:right;'
            f'font-size:{px}px;color:{col};opacity:{a}">{v}</span>')


def col_heads(ending=False, assists=True, px=10):
    cells = cell("K", 22, DIM, .8, px) + cell("D", 22, DIM, .8, px)
    if assists:
        cells += cell("A", 22, DIM, .8, px)
    if ending:
        cells += cell("Rating", 44, DIM, .8, px)
    return (f'<div class="row hud" style="height:16px;gap:7px;'
            f'padding:0 10px 0 8px">'
            f'<span class="lbl" style="font-size:{px}px">Pilots</span>'
            f'<div style="flex:1"></div>{cells}</div>')


def pilot_row(p, col, ending=False, assists=True, name_n=99):
    name, human, k, d, a, moved = p
    me = name == ME
    mark = helm(DIM, 11) if human else bot(DIM, 11)
    cells = cell(k) + cell(d)
    if assists:
        cells += cell(a)
    if ending:
        if moved > 0:
            cells += cell(f"+{moved}", 44, PAID, .95)
        elif moved < 0:
            cells += cell(str(moved), 44, HURT, .85)
        else:
            cells += cell("0", 44, DIM, .8)
    mvp = ""
    if ending and name == MVP:
        mvp = (f'<span class="lbl" style="font-size:9px;color:{PAID}">MVP'
               '</span>')
    wash = ""
    if me:
        wash = (f"background:rgba(79,214,255,.13);"
                f"box-shadow:inset 1.6px 0 0 {FRIEND};")
    shown = name if len(name) <= name_n else name[:name_n]
    return (f'<div class="row" style="height:{LINE}px;gap:7px;'
            f'padding:0 10px 0 8px;{wash}">'
            f'<span class="mono" style="font-size:11px;color:{col};'
            f'opacity:{1 if me else .85};white-space:nowrap">{shown}</span>'
            f'{mvp}{mark}<div style="flex:1"></div>{cells}</div>')


def watch_rows(compact=False, inline=False):
    if inline:
        return (f'<div class="row" style="justify-content:center;gap:8px;'
                f'height:{LINE}px">'
                f'<span class="lbl" style="font-size:9px">Watching</span>'
                f'<span class="mono" style="font-size:11px;color:{DIM}">'
                f'{", ".join(WATCHERS)}</span></div>')
    rows = "".join(
        f'<div class="row" style="height:{LINE}px;gap:7px;padding:0 10px 0 8px">'
        f'<span class="mono" style="font-size:11px;color:{DIM}">{n}</span>'
        f'{helm(DIM, 11)}<div style="flex:1"></div></div>' for n in WATCHERS)
    return (f'<div class="row" style="height:16px;padding:0 10px 0 8px;'
            f'margin-top:6px"><span class="lbl" style="font-size:9px">'
            f'Watching</span></div>{rows}')


def result_line(px=17):
    name, col, *_ = SIDES[1]
    return (f'<div class="row" style="justify-content:center;gap:7px;'
            f'height:{px + 8}px">'
            f'<span style="font-size:{px}px;font-weight:600;color:{col}">'
            f'{name}</span><span style="font-size:{px}px;color:{INK};'
            f'opacity:.9">takes it</span></div>')


def share_bar(h=10, px=13, order=None):
    """The scoreline as a bar with each side's name inside its own share of
    it and the points on the ends. Winner first unless told otherwise."""
    order = order or [SIDES[1], SIDES[0]]
    (ln, lc, ls, *_), (rn, rc, rs, *_) = order
    share = ls / (ls + rs) * 100

    def inside(name, right):
        return (f'<span class="hud" style="font-size:8px;color:{BG};'
                f'letter-spacing:.1em;position:absolute;'
                f'{"right" if right else "left"}:6px;top:50%;'
                f'transform:translateY(-50%);white-space:nowrap">{name}</span>')
    return (f'<div class="row" style="gap:8px;padding:0 8px">'
            f'<span class="num" style="font-size:{px}px;color:{lc}">{ls}</span>'
            f'<div style="flex:1;height:{h}px;display:flex;overflow:hidden">'
            f'<div style="position:relative;width:{share:.1f}%;background:{lc}">'
            f'{inside(ln, False)}</div>'
            f'<div style="position:relative;flex:1;background:{rc}">'
            f'{inside(rn, True)}</div></div>'
            f'<span class="num" style="font-size:{px}px;color:{rc}">{rs}</span>'
            '</div>')


def ground(x, y, w, body, h=None, clip=False):
    """The shipped board's ground: a wash of the field color and a lit rule
    down its left edge, no border (interface.md, Shape)."""
    hh = f"height:{h}px;" if h else ""
    over = "overflow:hidden;" if clip else ""
    thumb = ""
    if clip:
        thumb = (f'<div class="abs" style="right:2px;top:12%;width:3px;'
                 f'height:38%;background:{TILE};opacity:.9"></div>')
    return (f'<div class="abs" style="left:{x}px;top:{y}px;width:{w}px;{hh}'
            f'{over}background:rgba(5,7,12,.62);'
            f'box-shadow:inset 1.5px 0 0 rgba(63,88,120,.7);'
            f'padding:6px 0 8px">{body}{thumb}</div>')


def sections(sides, ending, assists=True, watchers=True, name_n=99,
             score=False):
    """The room in sections: a head per side and its pilots under it. At the
    whistle the winner runs first (decision 68), a rating column joins the
    figures, and the winner's best net wears the mark."""
    order = list(sides)
    if ending and len(sides) == 2:
        order = [sides[1], sides[0]]
    out = [col_heads(ending, assists), ticks()]
    for s in order:
        name, col, *_r, pilots, _mine = s
        out.append(side_head(s, score=score))
        out += [pilot_row(p, col, ending, assists, name_n) for p in pilots]
    if watchers:
        out.append(watch_rows())
    return "".join(out)


# --- Hang: one column under the band -----------------------------------------


def hang(form, state):
    w, h = FORMS[form]
    compact = form != "Desktop"
    portrait = form == "Portrait"
    ending = state == "end"
    roam = state == "roam"
    room = w - 2 * PAD
    bw = min(400, room)
    x = PAD + (room - bw) / 2
    y = band_bottom() + (24 if ending else 10)
    sides = roam_sides() if roam else SIDES
    body = ""
    if ending:
        body += result_line(15 if compact else 17)
        body += share_bar(10 if compact else 12, 13 if compact else 15)
        body += '<div style="height:8px"></div>'
    # A sideways phone has no row for the watchers at the whistle: the
    # result line and the bar take their place.
    body += sections(sides, ending, watchers=not (ending and form == "Landscape"),
                     score=roam)
    clip = roam
    hh = (h - y - PAD) if roam else None
    return chrome(w, h, compact, portrait, state, roam) + ground(
        x, y, bw, body, hh, clip)


# --- Wings: a wing under each side of the clock ------------------------------


def wing_body(side, ending, assists, name_n, big=False):
    name, col, sc, *_r, pilots, _mine = side
    out = [side_head(side, px=13 if big else 12, score=ending)]
    out.append(col_heads(ending, assists, px=9))
    out += [pilot_row(p, col, ending, assists, name_n) for p in pilots]
    return "".join(out)


def wings(form, state):
    w, h = FORMS[form]
    compact = form != "Desktop"
    portrait = form == "Portrait"
    ending = state == "end"
    roam = state == "roam"
    out = [chrome(w, h, compact, portrait, state, roam)]
    if roam:
        # Eight sides tile as eight wings, four across, under the band. The
        # middle is not kept clear here: eight wings are a grid, and the grid
        # is what a monitor has the width for. A phone stacks and scrolls.
        sides = roam_sides()
        ww, gap = 300, 12
        total = 4 * ww + 3 * gap
        x0 = (w - total) / 2
        y0 = band_bottom() + 10
        col_h = [0, 0, 0, 0]
        for i, s in enumerate(sides):
            c = i % 4
            body = wing_body(s, False, True, 14)
            hh = HEAD + 16 + LINE * len(s[5]) + 14
            out.append(ground(x0 + c * (ww + gap), y0 + col_h[c], ww, body))
            col_h[c] += hh + gap
        return "".join(out)
    # The clock's own column stays clear between the two wings, and a wing
    # hangs off the side it is about: yours left, theirs right, which is the
    # band's own order and never changes, the whistle included.
    if portrait:
        gap = 8
        ww = (w - 2 * PAD - gap) / 2
        name_n, assists = 7, False
    else:
        clock_w = KEY_H * 0.6 * 4
        gap = clock_w + 2 * (14 if compact else 22) + 8
        ww = 240 if compact else 300
        name_n, assists = 99, True
    y = band_bottom() + 10
    if ending:
        out.append(f'<div class="abs" style="left:0;right:0;top:{y + 12}px">'
                   f'{result_line(15 if compact else 17)}</div>')
        y += 42 if compact else 46
    for i, s in enumerate(SIDES):
        x = w / 2 - gap / 2 - ww if i == 0 else w / 2 + gap / 2
        out.append(ground(x, y, ww, wing_body(s, ending, assists, name_n,
                                             big=ending)))
    # Who is watching, one line between the wings: they are on nobody's
    # side, so they hang under neither.
    wy = y + HEAD + 16 + 4 * LINE + 14 + 6
    if not portrait:
        out.append(f'<div class="abs" style="left:0;right:0;top:{wy}px">'
                   f'{watch_rows(inline=True)}</div>')
    else:
        out.append(f'<div class="abs" style="left:{PAD}px;right:{PAD}px;'
                   f'top:{wy}px">{watch_rows(inline=True)}</div>')
    return "".join(out)


# --- Sheet: the menu's own panel ---------------------------------------------


def m_head(title, col=INK, sub=""):
    """The menu's head: back triangle and the section's name, the whole line
    the press."""
    extra = (f'<span class="mono" style="font-size:14px;color:{READ};'
             f'margin-left:auto">{sub}</span>') if sub else ""
    return (f'<div class="row" style="height:{ROW}px;gap:10px;padding:0 14px">'
            f'{back_tri()}<span style="font-size:17px;color:{col}">{title}'
            f'</span>{extra}</div>{hrule(".6")}')


def m_band(label):
    return (f'<div class="row" style="height:24px;padding:0 14px">'
            f'{hrule()}<span class="lbl" style="font-size:12px;'
            f'letter-spacing:.1em;color:{MUTE};padding:0 10px">{label}</span>'
            f'</div>')


def m_side_row(side, score=True):
    """A side as a menu row: the name it speaks, the count it reads, the
    here wash on yours. Pressing another side's row is joining it, which is
    the shape decision 102 gave the side list. Its right end reads."""
    name, col, sc, humans, cap, _p, mine = side
    wash = "background:rgba(79,214,255,.07);" if mine else ""
    figures = (f'<span class="num" style="font-size:14px;color:{col}">{sc}'
               '</span>' if score and sc is not None else "")
    reading = (f'<span class="mono" style="font-size:14px;color:{READ}">'
               f'{humans} of {cap}</span>')
    if not mine and humans >= cap:
        reading = (f'<span class="mono" style="font-size:14px;color:{MUTE}">'
                   'Full</span>')
    left = wedge(col) if mine else '<span style="width:8px;flex:none"></span>'
    return (f'<div class="row" style="height:{ROW}px;gap:10px;padding:0 14px;'
            f'{wash}">{left}<span style="font-size:17px;color:{col}">{name}'
            f'</span>{figures}<span class="row" style="margin-left:auto;gap:14px">'
            f'{reading}</span></div>')


def m_pilot_row(p, col, ending):
    name, human, k, d, a, moved = p
    me = name == ME
    wash = "background:rgba(79,214,255,.13);" if me else ""
    mark = helm(MUTE, 12) if human else bot(MUTE, 12)
    cells = (cell(k, 24, READ, 1, 14) + cell(d, 24, READ, 1, 14)
             + cell(a, 24, READ, 1, 14))
    if ending:
        if moved > 0:
            cells += cell(f"+{moved}", 40, PAID, .95, 14)
        elif moved < 0:
            cells += cell(str(moved), 40, HURT, .85, 14)
        else:
            cells += cell("0", 40, MUTE, 1, 14)
    mvp = ""
    if ending and name == MVP:
        mvp = f'<span class="lbl" style="font-size:10px;color:{PAID}">MVP</span>'
    return (f'<div class="row" style="height:{ROW}px;gap:10px;padding:0 14px 0 32px;'
            f'{wash}"><span style="font-size:17px;color:{col};'
            f'opacity:{1 if me else .85}">{name}</span>{mvp}{mark}'
            f'<span class="row" style="margin-left:auto;gap:10px">{cells}</span>'
            '</div>')


def m_col_heads(ending):
    cells = cell("K", 24, MUTE, 1, 12) + cell("D", 24, MUTE, 1, 12) + cell("A", 24, MUTE, 1, 12)
    if ending:
        cells += cell("Rating", 40, MUTE, 1, 12)
    return (f'<div class="row" style="height:24px;padding:0 14px">'
            f'<span class="lbl" style="font-size:12px;letter-spacing:.1em;'
            f'color:{MUTE}">Pilots</span>'
            f'<span class="row hud" style="margin-left:auto;gap:10px">{cells}'
            '</span></div>')


def sheet(form, state):
    w, h = FORMS[form]
    compact = form != "Desktop"
    portrait = form == "Portrait"
    ending = state == "end"
    roam = state == "roam"
    sides = roam_sides() if roam else SIDES
    order = list(sides)
    if ending:
        order = [sides[1], sides[0]]
    span = w - 2 * PAD
    pw = min(PANEL_MAX, span)
    px = PAD + (span - pw) / 2
    body = []
    if roam:
        body.append(m_head("Free roam", sub="31 flying"))
    elif ending:
        name, col, *_ = SIDES[1]
        body.append(m_head(f"{name} takes it", col))
        body.append(f'<div style="padding:10px 6px 6px">'
                    f'{share_bar(12, 15)}</div>')
    else:
        body.append(m_head("Scoreboard", sub="2:14"))
    body.append(m_col_heads(ending))
    for s in order:
        body.append(m_side_row(s, score=not roam))
        body += [m_pilot_row(p, s[1], ending) for p in s[5]]
    if not roam:
        body.append(m_band("Watching"))
        for n in WATCHERS:
            body.append(
                f'<div class="row" style="height:{ROW}px;gap:10px;'
                f'padding:0 14px 0 32px"><span style="font-size:17px;'
                f'color:{READ};opacity:.85">{n}</span>{helm(MUTE, 12)}'
                f'<span class="mono" style="margin-left:auto;font-size:14px;'
                f'color:{MUTE}">watching</span></div>')
    # As tall as what it holds, standing on the bottom margin, and capped by
    # the room under the band: what will not fit scrolls under a pinned head.
    n_rows = sum(1 + len(s[5]) for s in sides) + (0 if roam else 2)
    want = ROW + 24 + n_rows * ROW + (0 if roam else 24) + (60 if ending else 0)
    room = h - PAD - (band_bottom() + 14)
    ph = min(want, room)
    clip = want > room
    thumb = ""
    if clip:
        frac = room / want
        thumb = (f'<div class="abs" style="right:3px;top:{ROW + 8}px;width:3px;'
                 f'height:{(ph - ROW - 16) * frac:.0f}px;background:{TILE}">'
                 '</div>')
    panel = (f'<div class="abs glass" style="left:{px}px;bottom:{PAD}px;'
             f'width:{pw}px;height:{ph}px;overflow:hidden">'
             f'{"".join(body)}{thumb}</div>')
    return chrome(w, h, compact, portrait, state, roam, key=False) + panel


# --- Main: the shared anatomy ------------------------------------------------


def main_sheet():
    W, H = 1440, 1150

    def cap(text, w=None):
        return (f'<div style="font-size:13px;line-height:19px;color:{READ};'
                f'{"width:" + str(w) + "px;" if w else ""}'
                f'text-wrap:pretty">{text}</div>')

    def title(text):
        return (f'<div class="lbl" style="font-size:11px;letter-spacing:.16em;'
                f'margin-bottom:10px">{text}</div>')

    full_side = ("Caisson", ENEMY, 20, 4, 4, CAISSON, False)
    demo = (f'<div style="width:400px;background:rgba(5,7,12,.62);'
            f'box-shadow:inset 1.5px 0 0 rgba(63,88,120,.7);padding:6px 0 8px">'
            f'{col_heads()}{ticks()}{side_head(SIDES[0])}'
            f'{pilot_row(PYLON[0], FRIEND)}{pilot_row(PYLON[3], FRIEND)}'
            f'{side_head(SIDES[1])}{pilot_row(CAISSON[0], ENEMY)}'
            f'{pilot_row(CAISSON[1], ENEMY)}'
            f'{side_head(full_side)}{watch_rows()}</div>')
    ending = (f'<div style="width:400px;background:rgba(5,7,12,.62);'
              f'box-shadow:inset 1.5px 0 0 rgba(63,88,120,.7);padding:6px 0 8px">'
              f'{result_line()}{share_bar(12, 15)}'
              f'<div style="height:8px"></div>{col_heads(True)}{ticks()}'
              f'{side_head(SIDES[1])}{pilot_row(CAISSON[0], ENEMY, True)}'
              f'{side_head(SIDES[0])}{pilot_row(PYLON[3], FRIEND, True)}</div>')
    menu = (f'<div class="glass" style="width:400px">'
            f'{m_head("Scoreboard", sub="2:14")}{m_col_heads(False)}'
            f'{m_side_row(SIDES[0])}{m_pilot_row(PYLON[3], FRIEND, False)}'
            f'{m_side_row(SIDES[1])}{m_pilot_row(CAISSON[0], ENEMY, False)}'
            f'{m_side_row(full_side)}</div>')

    bands = ""
    for form, (w, h) in FORMS.items():
        bw = 420 if form != "Portrait" else 362
        bands += (f'<div style="position:relative;width:{bw}px;height:60px;'
                  f'background:rgba(5,7,12,.5);overflow:hidden">'
                  f'{band(bw, form != "Desktop", form == "Portrait", "open")}'
                  f'<div class="lbl" style="position:absolute;left:8px;'
                  f'bottom:6px;font-size:9px">{form}</div></div>')
    end_band = (f'<div style="position:relative;width:420px;height:60px;'
                f'background:rgba(5,7,12,.5);overflow:hidden">'
                f'{band(420, False, False, "end")}'
                f'<div class="lbl" style="position:absolute;left:8px;'
                f'bottom:6px;font-size:9px">Between rounds</div></div>')

    thumbs = ""
    for name, draw, note in (
        ("Hang", lambda: '<div style="position:absolute;left:35%;top:22%;'
                         'width:30%;height:60%;background:rgba(63,88,120,.5)">'
                         '</div>',
         "one column under the band"),
        ("Wings", lambda: '<div style="position:absolute;left:12%;top:22%;'
                          'width:33%;height:34%;background:rgba(63,88,120,.5)">'
                          '</div><div style="position:absolute;right:12%;'
                          'top:22%;width:33%;height:34%;'
                          'background:rgba(63,88,120,.5)"></div>',
         "a wing under each side of the clock"),
        ("Sheet", lambda: '<div style="position:absolute;left:30%;bottom:6%;'
                          'width:40%;height:70%;border:1px solid '
                          'rgba(63,88,120,.9);background:rgba(10,15,24,.8)">'
                          '</div>',
         "the menu's panel, up through the foot"),
    ):
        thumbs += (f'<div style="display:flex;flex-direction:column;gap:8px">'
                   f'<div style="position:relative;width:200px;height:112px;'
                   f'background:rgba(5,7,12,.6);border:1px solid rgba(63,88,120,.4)">'
                   f'<div style="position:absolute;left:44%;top:6%;width:12%;'
                   f'height:9%;background:rgba(223,233,245,.7)"></div>{draw()}'
                   f'</div><div class="hud" style="font-size:12px;color:{INK}">'
                   f'{name}</div>{cap(note, 200)}</div>')

    body = f'''
<div style="position:relative;width:{W}px;height:{H}px;overflow:hidden;
     background-color:{BG};background-image:{starfield(W, H, 3)};padding:40px 48px">
  <div style="display:flex;flex-direction:column;gap:6px;margin-bottom:28px">
    <div style="font-size:26px;color:{INK}">One board</div>
    {cap("The score, the room, and the door onto a side, as one thing. The band stays the instrument; what it opens is the room in sections, a side's head is the way onto that side, and at the whistle the same panel comes up by itself at the same size in the same place, plus the one line it could not know.", 760)}
  </div>
  <div style="display:grid;grid-template-columns:repeat(3, minmax(0, 1fr));gap:40px">
    <div>
      {title("The band, shut")}
      <div style="display:flex;flex-direction:column;gap:10px">{bands}{end_band}</div>
      <div style="margin-top:12px">{cap("Unchanged from decisions 67 and 94: a side is a name over its score, as tall as the clock; an upright phone drops the names; between rounds the sides go and the clock counts to the next match. A press on the band, or the board key, opens the room.")}</div>
    </div>
    <div>
      {title("The room, in the HUD's voice (Hang, Wings)")}
      {demo}
      <div style="margin-top:12px">{cap("A side's head is the side picker. Yours wears the wedge and the here wash. Another side's head carries JOIN while it has a human seat, and reads FULL, unpressable, when it has not. The count is humans of the cap, since bots yield their seats. Pilots stand under their head with the same K, D, A they carry today; your row keeps its wash and lit rule. Watchers close the list, in nobody's color.")}</div>
      <div style="margin-top:22px">{title("At the whistle")}{ending}</div>
      <div style="margin-top:12px">{cap("The same panel, one head taller: who took it, and the bar with each side inside its own share. Rating joins the figures, the winner's best net wears MVP, and the winner leads (decision 68) where the sides stack. Nothing zooms and nothing washes the window to black: the tint is the menu's own 0.42.")}</div>
    </div>
    <div>
      {title("The room, in the menu's voice (Sheet)")}
      {menu}
      <div style="margin-top:12px">{cap("The same sections said in decision 104's language: one glass, one head, rows of 44, the name spoken at 17 and the figures read at 14. A side row is the side list decision 102 drew, with its pilots indented under it. It costs height: eleven rows at the touch floor is more than a sideways phone has, so there it scrolls under the pinned head.")}</div>
    </div>
  </div>
  <div style="margin-top:36px">{title("Where it stands: the three directions")}
    <div style="display:flex;gap:40px">{thumbs}</div></div>
</div>'''
    return body


# --- assembly ----------------------------------------------------------------


def page(name, body):
    doc = f"""<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
  <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Chakra+Petch:wght@400;500;600&amp;family=Noto+Sans+Mono:wght@400;500;700&amp;display=swap">
  <style>{CSS}</style>
</helmet>
{body}
</x-dc>
</body>
</html>
"""
    (HERE / f"{name}.dc.html").write_text(doc)


def screen(direction, form, state):
    w, h = FORMS[form]
    draw = {"Hang": hang, "Wings": wings, "Sheet": sheet}[direction]
    inner = draw(form, state)
    return (f'<div style="position:relative;width:{w}px;height:{h}px;'
            f'overflow:hidden;background-color:{BG};'
            f'background-image:{starfield(w, h, len(direction) + w)}">'
            f'{inner}</div>')


def main():
    page("Main", main_sheet())
    n = 1
    for d in DIRECTIONS:
        for form in FORMS:
            for state in ("open", "end"):
                if state == "end":
                    name = f"{d}{form}End"
                else:
                    name = f"{d}{form}"
                page(name, screen(d, form, state))
                n += 1
        page(f"{d}Roam", screen(d, "Desktop", "roam"))
        n += 1
    print(f"{n} artboards written")


if __name__ == "__main__":
    main()
