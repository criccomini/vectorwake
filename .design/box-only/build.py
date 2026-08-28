#!/usr/bin/env python3
"""Assemble the artboards for the box-only mocks: the drawer goes, and the
landing's boxes carry everything it held.

Chris's brief: keep only the box style the landing's stops wear, remove the
hamburger menu entirely, work at desktop, landscape and portrait, and rethink
the ship experience from the ground up. The drawer holds five stops today
(play, ship, friends, pilot, settings); the landing's boxes already answer
three of them, so the mocks ask where friends and settings live, what a press
does when no drawer stands behind it, and what the ship box becomes when it
has to carry the whole hangar.

Three directions, named by what a press on a box does:

  A  Unfold  the shipped column with friends and settings aboard; a pressed
             box opens between its neighbors and everything else stays put
  B  Board   no open state at all: every box stands with its rows inside,
             the fight showing between them
  C  Deck    a press replaces the column with the next set of boxes, a back
             box at the head; the ship rethink lives here

Every direction keeps PLAY NOW as the one celebrated key. A fourth board
answers the match: with no drawer, MENU raises the same column over the
fight.

Drawings of a proposal, not a plan of record. The design system is lifted
from ../start-flow/build.py, which lifted it from the real client:
client/arena/palette.lua for hues, client/arena/ui.lua for panel geometry,
docs/design/ships.md for hull extents, the lockup verbatim from
docs/banner.svg, slots and their names from client/arena/menu.lua and
palette.lua. Values inside boxes are spelled as typed, the way the shipped landing
spells a call sign.

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
CSS = """
:root{
  --bg:#05070c; --ink:#dfe9f5; --dim:#6c7a90;
  --friend:#4fd6ff; --enemy:#ffa552;
  --rule:#3f5878; --prize:#8dffb0; --bounty:#ffe08a;
  --wall:#080d16; --wall-edge:#22344f; --wall-lit:#5b82b8;
  --mono:"DejaVu Sans Mono","Noto Sans Mono",ui-monospace,monospace;
  --menu:"Chakra Petch","Segoe UI",system-ui,sans-serif;
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font-family:var(--menu)}
a{color:var(--friend)}a:hover{color:#8ee6ff}
.hud{font-family:var(--mono);text-transform:uppercase;letter-spacing:.04em}
.num{font-family:var(--mono);font-variant-numeric:tabular-nums}
.lbl{font-family:var(--mono);font-size:9px;text-transform:uppercase;
  letter-spacing:.13em;color:var(--dim)}
.dim{color:var(--dim)}
.row{display:flex;align-items:center}

/* One shape for a thing to press: a rectangle outlined all the way round
   with a wash inside it, washed dark enough to read over the fight. ui.lua key_cap(). */
.key{display:inline-flex;align-items:center;justify-content:center;gap:7px;
  border:1px solid rgba(63,88,120,.75);background:rgba(10,15,24,.72);
  font-family:var(--mono);text-transform:uppercase;letter-spacing:.06em;
  color:#9fb6d4}

/* A box: label at one end, the current answer and a caret at the other.
   Same rectangle as .key, roomier inside. Values spell as typed. */
.field{display:flex;align-items:center;justify-content:space-between;
  border:1px solid rgba(63,88,120,.75);background:rgba(8,12,20,.78);
  font-family:var(--mono);letter-spacing:.06em;
  padding:0 12px;color:var(--ink)}

/* A standing panel: the same box grown tall, its label a head inside. */
.panel{border:1px solid rgba(63,88,120,.75);background:rgba(8,12,20,.9);
  padding:0 0 5px 0}
.phead{font-family:var(--mono);font-size:9px;text-transform:uppercase;
  letter-spacing:.13em;color:var(--dim);padding:9px 12px 5px 12px}

/* Rows inside an open box or a panel: the menu's row states (decision 72). */
.drow{display:flex;align-items:center;gap:10px;
  font-family:var(--mono);letter-spacing:.06em;
  font-size:12px;padding:0 12px;color:#9fb6d4}

/* The one press this screen exists for. ui.lua landing(). */
@keyframes breath{
  0%,100%{background:rgba(79,214,255,.06);
    border-color:rgba(79,214,255,.62)}
  50%{background:rgba(79,214,255,.18);
    border-color:rgba(79,214,255,1)}
}
.play{display:flex;align-items:center;justify-content:center;
  border:1.6px solid rgba(79,214,255,.62);
  animation:breath 2.42s ease-in-out infinite;
  font-family:var(--mono);letter-spacing:.14em;color:var(--ink)}
"""

# --- small marks --------------------------------------------------------------


def caret(col="#9fb6d4", k=9):
    return (f'<svg width="{k}" height="{k}" viewBox="0 0 10 10" fill="none" '
            f'style="flex:none"><path d="M1.5 3 L5 7 L8.5 3" stroke="{col}" '
            f'stroke-width="1.4" stroke-linecap="square"/></svg>')


def back_caret(col="#9fb6d4", k=10):
    return (f'<svg width="{k}" height="{k}" viewBox="0 0 10 10" fill="none" '
            f'style="flex:none"><path d="M7 1.5 L3 5 L7 8.5" stroke="{col}" '
            f'stroke-width="1.4" stroke-linecap="square"/></svg>')


def eye(col="#9fb6d4", k=13):
    return (f'<svg width="{k}" height="{k}" viewBox="0 0 14 14" fill="none" '
            f'style="flex:none">'
            f'<path d="M1.2 7 C3 4 5 2.8 7 2.8 C9 2.8 11 4 12.8 7 '
            f'C11 10 9 11.2 7 11.2 C5 11.2 3 10 1.2 7 Z" stroke="{col}" '
            f'stroke-width="1.1"/>'
            f'<circle cx="7" cy="7" r="1.8" fill="{col}"/></svg>')


def gauge(col="#9fb6d4", k=13):
    """Settings wears a gauge (decision 83)."""
    return (f'<svg width="{k}" height="{k}" viewBox="0 0 14 14" fill="none" '
            f'style="flex:none">'
            f'<path d="M2 10.5 A5.4 5.4 0 0 1 12 10.5" stroke="{col}" '
            f'stroke-width="1.2"/>'
            f'<path d="M7 10.2 L9.6 5.6" stroke="{col}" stroke-width="1.3" '
            f'stroke-linecap="square"/>'
            f'<circle cx="7" cy="10.2" r="1.1" fill="{col}"/></svg>')


def pair(col="#9fb6d4", k=13):
    """Friends: two hulls flying together, reduced to two rings."""
    return (f'<svg width="{k}" height="{k}" viewBox="0 0 14 14" fill="none" '
            f'style="flex:none">'
            f'<circle cx="5" cy="7" r="3.4" stroke="{col}" stroke-width="1.2"/>'
            f'<circle cx="10" cy="7" r="3.4" stroke="{col}" '
            f'stroke-width="1.2" opacity=".55"/></svg>')


def rivet(k=8):
    """A price is always the rivet mark in gold."""
    return (f'<svg width="{k}" height="{k}" viewBox="0 0 10 10" '
            f'style="flex:none">'
            f'<circle cx="5" cy="5" r="4" stroke="#ffe08a" fill="none" '
            f'stroke-width="1.1"/>'
            f'<circle cx="5" cy="5" r="1.4" fill="#ffe08a"/></svg>')


def dot(col="#8dffb0", k=7):
    return (f'<svg width="{k}" height="{k}" viewBox="0 0 8 8" '
            f'style="flex:none"><circle cx="4" cy="4" r="3" fill="{col}"/>'
            f'</svg>')


def steps(n, of, tint="#9fb6d4", k=6):
    """A slot's ladder as filled and empty treads, the ship page's steps."""
    cells = []
    for i in range(of):
        fill = tint if i < n else "none"
        op = ".95" if i < n else "1"
        cells.append(f'<rect x="{i * (k + 3)}" y="0" width="{k}" '
                     f'height="{k + 4}" fill="{fill}" stroke="{tint}" '
                     f'stroke-width="1" opacity="{op if i < n else ".45"}"/>')
    w = of * (k + 3) - 3
    return (f'<svg width="{w}" height="{k + 4}" viewBox="0 0 {w} {k + 4}" '
            f'style="flex:none">{"".join(cells)}</svg>')


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
    'L67.8 -8H85.7L90.1 -12.3V-15.7H99.3V-9.5L89.9 0H63.6ZM110.9 -9.5V-40.3L120.4 -49.8H145.5L155.1 -40.2V-33.1H145.8'
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
            f'style="display:block">'
            f'<g transform="translate(334.975 83) scale(.7115)">{MARK_PATHS}</g>'
            f'{WORD_PATH}</svg>')


def mark_only(h):
    w = round(h * 84 / 103)
    return (f'<svg width="{w}" height="{h}" viewBox="0 0 84 103" '
            f'style="display:block;flex:none">{MARK_PATHS}</svg>')


# --- hull outlines, to the extents in docs/design/ships.md -------------------
HULLS = {
    "Apex":    "M0,-20 L6,-3 L10,7 L4,5 L2,11 L-2,11 L-4,5 L-10,7 L-6,-3 Z",
    "Wedge":   "M0,-13 L15,9 L7,12 L0,8 L-7,12 L-15,9 Z",
    "Chord":   "M0,-13 L8,-7 L17,1 L13,5 L5,2 L-5,2 L-13,5 L-17,1 L-8,-7 Z",
    "Anvil":   "M-8,-15 L8,-15 L13,-5 L13,6 L8,11 L-8,11 L-13,6 L-13,-5 Z",
    "Cipher":  "M0,-22 L3,-6 L6,8 L2,12 L-2,12 L-6,8 L-3,-6 Z",
    "Facet":   "M0,-8 L11,-1 L8,12 L-8,12 L-11,-1 Z",
    "Lattice": ("M-4,-16 L4,-16 L4,-5 L14,-5 L14,4 L4,4 L4,14 L-4,14 L-4,4 "
                "L-14,4 L-14,-5 L-4,-5 Z"),
}


def ship_at(name, x, y, rot, col, k=1.0, trail=True):
    t = ""
    if trail:
        t = f'<path d="M-4,10 L-2,52 L2,52 L4,10 Z" fill="{col}" opacity=".16"/>'
    return (f'<g transform="translate({x},{y}) rotate({rot}) scale({k})">'
            f'{t}<path d="{HULLS[name]}" fill="#0b1220" stroke="{col}" '
            f'stroke-width="1.5" stroke-linejoin="round"/></g>')


# --- the room behind the glass, from ../spectator-landing --------------------
FRIEND, ENEMY = "#4fd6ff", "#ffa552"
SHIPS = [
    ("KRAIT 4",   "Wedge",   FRIEND, (0, 10),      18,  7),
    ("VIREO 9",   "Chord",   FRIEND, (-170, 40),   62,  2),
    ("SABER 3",   "Facet",   FRIEND, (-320, -150), 118, 4),
    ("PLINTH 41", "Lattice", FRIEND, (520, 290),   -40, 1),
    ("MANTIS 7",  "Cipher",  ENEMY,  (150, -95),   205, 5),
    ("HALCYON 2", "Anvil",   ENEMY,  (365, 55),    160, 9),
    ("SABLE 09",  "Wedge",   ENEMY,  (-460, 240),  285, 1),
    ("ORRERY 3",  "Apex",    ENEMY,  (430, -285),  320, 3),
]


def nameplate(x, y, name, col, bounty, px):
    by = y + 22 + px + 4
    return (f'<g font-family="DejaVu Sans Mono,Noto Sans Mono,monospace" '
            f'font-size="{px}">'
            f'<text x="{x + 16}" y="{y + 22}" fill="{col}" opacity=".92">{name}</text>'
            f'<circle cx="{x + 20}" cy="{by - 3}" r="3.2" stroke="#ffe08a" '
            f'fill="none" stroke-width="1" opacity=".85"/>'
            f'<circle cx="{x + 20}" cy="{by - 3}" r="1.2" fill="#ffe08a" '
            f'opacity=".85"/>'
            f'<text x="{x + 26}" y="{by}" fill="#ffe08a" '
            f'opacity=".85">{bounty}</text></g>')


def scene(w, h, compact, seed):
    cx, cy = w / 2, h / 2
    rnd = random.Random(seed)
    parts = []
    for _ in range(10 if compact else 22):
        x = rnd.randint(-60, w - 40)
        y = rnd.randint(-40, h - 40)
        bw, bh = rnd.choice([(96, 32), (32, 108), (64, 64), (150, 30), (30, 150)])
        if abs(x + bw / 2 - cx) < 210 and abs(y + bh / 2 - cy) < 170:
            continue
        parts.append(
            f'<rect x="{x}" y="{y}" width="{bw}" height="{bh}" fill="#080d16" '
            f'stroke="#22344f" stroke-width="1"/>'
            f'<path d="M{x} {y} H{x + bw}" stroke="#5b82b8" stroke-width="1.4" '
            f'opacity=".55"/>')
    parts += [
        f'<path d="M{cx + 60} {cy - 32} L{cx + 76} {cy - 44}" stroke="#f7dd0b" '
        'stroke-width="2.6" stroke-linecap="round"/>',
        f'<path d="M{cx + 88} {cy - 52} L{cx + 102} {cy - 62}" stroke="#f7dd0b" '
        'stroke-width="2.6" stroke-linecap="round" opacity=".6"/>',
        f'<path d="M{cx - 106} {cy + 6} L{cx - 92} {cy - 8}" stroke="#62cc35" '
        'stroke-width="2.4" stroke-linecap="round"/>',
        f'<circle cx="{cx + 258}" cy="{cy - 20}" r="4.4" fill="#ff7000"/>',
        f'<circle cx="{cx + 258}" cy="{cy - 20}" r="12" stroke="#ff7000" '
        'stroke-width="1" opacity=".4"/>',
    ]
    px = 9 if compact else 10
    k = 0.85 if compact else 1.0
    for name, hullname, col, (ox, oy), rot, bounty in SHIPS:
        x, y = cx + ox * (0.8 if compact else 1), cy + oy * (0.8 if compact else 1)
        if not (-40 < x < w + 40 and -40 < y < h + 40):
            continue
        parts.append(ship_at(hullname, x, y, rot, col,
                             k=k * (1.15 if name == "KRAIT 4" else 1)))
        parts.append(nameplate(x, y, name, col, bounty, px))
    return (f'<svg width="{w}" height="{h}" '
            f'style="position:absolute;inset:0">{"".join(parts)}</svg>')


def score_band(compact, portrait=False):
    big, mid, name = (22, 17, 9) if compact else (34, 30, 11)
    gap = 12 if compact else 22
    top = 46 if portrait else (10 if compact else 14)
    left = (f'<div class="hud num" style="font-size:{name}px;'
            f'color:var(--friend)">PYLON</div>') if not portrait else ""
    right = (f'<div class="hud num" style="font-size:{name}px;'
             f'color:var(--enemy)">CAISSON</div>') if not portrait else ""
    return f"""
  <div style="position:absolute;top:{top}px;left:50%;
       transform:translateX(-50%);display:flex;align-items:center;gap:{gap}px">
    <div class="row" style="gap:{gap // 2}px">
      {left}
      <div class="num" style="font-size:{mid}px;color:var(--friend)">3</div>
    </div>
    <div class="num" style="font-size:{big}px;letter-spacing:.02em">1:47</div>
    <div class="row" style="gap:{gap // 2}px">
      <div class="num" style="font-size:{mid}px;color:var(--enemy)">5</div>
      {right}
    </div>
  </div>"""


def bracket(col="rgba(63,88,120,.8)"):
    tpl = ('<svg width="16" height="16" viewBox="0 0 16 16" fill="none" '
           'style="position:absolute;{pos}">'
           '<path d="M5 .7 H14 M.7 5 V14 M5 .7 L.7 5" stroke="{col}" '
           'stroke-width="1" stroke-linecap="square"/></svg>')
    corners = [
        "left:0;top:0", "right:0;top:0;transform:scaleX(-1)",
        "right:0;bottom:0;transform:scale(-1,-1)",
        "left:0;bottom:0;transform:scaleY(-1)",
    ]
    return "".join(tpl.format(pos=p, col=col) for p in corners)


def minimap(side, seed):
    rnd = random.Random(seed)
    blips = []
    for _ in range(26):
        bx, by = rnd.randint(6, 94), rnd.randint(6, 94)
        bw, bh = rnd.choice([(6, 3), (3, 7), (5, 5), (9, 3), (3, 10)])
        blips.append(f'<rect x="{bx}" y="{by}" width="{bw}" height="{bh}" '
                     f'fill="#3f5878" opacity=".85"/>')
        blips.append(f'<rect x="{100 - bx - bw}" y="{100 - by - bh}" width="{bw}" '
                     f'height="{bh}" fill="#3f5878" opacity=".85"/>')
    ships = ('<circle cx="47" cy="52" r="2" fill="#4fd6ff"/>'
             '<circle cx="41" cy="61" r="2" fill="#4fd6ff"/>'
             '<circle cx="38" cy="43" r="2" fill="#4fd6ff"/>'
             '<circle cx="72" cy="70" r="2" fill="#ffa552"/>'
             '<circle cx="55" cy="44" r="2" fill="#ffa552"/>'
             '<circle cx="28" cy="66" r="2" fill="#ffa552"/>')
    return (f'<div style="position:relative;width:{side}px;height:{side}px">'
            f'<svg width="{side}" height="{side}" viewBox="0 0 100 100" '
            f'style="background:rgba(6,10,16,.55)">{"".join(blips)}{ships}</svg>'
            f'{bracket()}</div>')


def radar(compact, portrait=False):
    side = 90 if portrait else (120 if compact else 168)
    top = 40 if portrait else 14
    return (f'<div style="position:absolute;right:14px;top:{top}px">'
            f'{minimap(side, 7)}</div>')


def play_key(w, h, px, extra_style="", word="PLAY NOW"):
    return (f'<div class="play" style="width:{w}px;height:{h}px;'
            f'font-size:{px}px;{extra_style}">{word}</div>')


# --- what the player currently is, on every board ----------------------------
# The account, zone and ship from Chris's screenshot, spelled as typed.

NAME, ZONE, SHIP = "DRiFT", "Duel", "Gunner"

ZONES = [
    ("Team Battle", "4V4 · 3:00"),
    ("Duel", "1V1 · RATED"),
]

# The pilot's saved builds and the hull each rides. The landing's list shows
# names alone; the ship screens own the hulls.
BUILDS = [
    ("Gunner", "Apex"),
    ("Bomber", "Anvil"),
    ("Brawler", "Wedge"),
    ("Scout", "Cipher"),
]

FRIENDS_ROWS = [
    ("Vireo 9", "Team Battle", True),
    ("Saber 3", "Duel", True),
    ("Plinth 41", "", False),
]

# Row states, decision 72: the row the cursor is on washes at 0.18, the row
# you are already in at 0.07.
WASH_CURSOR = "background:rgba(79,214,255,.18);color:var(--ink)"
WASH_HERE = "background:rgba(79,214,255,.07)"

UP_TINTS = {"NRG": "#7fe3a0", "RCH": "#4fd6ff", "SPD": "#ffd166",
            "THR": "#ff9a5c", "ROT": "#c79bff"}


# --- box building blocks ------------------------------------------------------


def box(label, value, w, h, px=13, lit=False, dim=False, icon="", style=""):
    """A closed box: label at the left edge, the answer and a caret at the
    right. `lit` is the box whose contents are open."""
    edge = "border-color:rgba(79,214,255,.85);" if lit else ""
    vcol = "color:var(--dim);" if dim else ""
    return (f'<div class="field" style="width:{w}px;height:{h}px;{edge}{style}">'
            f'<span class="row" style="gap:8px">{icon}'
            f'<span class="lbl">{label}</span></span>'
            f'<span class="row" style="gap:9px;font-size:{px}px;{vcol}">{value}'
            f'{caret()}</span></div>')


def rows_html(rows, row_h, px=12):
    """Rows: (html, state) with state cursor, here, rule or None."""
    out = []
    for html, state in rows:
        if state == "rule":
            out.append('<div style="height:1px;margin:4px 12px;'
                       'background:rgba(63,88,120,.6)"></div>')
            continue
        wash = WASH_CURSOR if state == "cursor" else (
            WASH_HERE if state == "here" else "")
        out.append(f'<div class="drow" style="height:{row_h}px;'
                   f'font-size:{px}px;{wash}">{html}</div>')
    return "".join(out)


def unfold(rows, w, row_h, px=12, style=""):
    """An open box's contents, hung under it inside the column: the same
    glass, the lit box's own edge carried down."""
    return (f'<div class="panel" style="width:{w}px;{style};'
            f'border-color:rgba(79,214,255,.55);border-top:none;'
            f'padding:5px 0">{rows_html(rows, row_h, px)}</div>')


def panel(label, rows, w, row_h=34, px=12, style=""):
    """A standing panel: label as its head, rows always visible."""
    return (f'<div class="panel" style="width:{w}px;{style}">'
            f'<div class="phead">{label}</div>'
            f'{rows_html(rows, row_h, px)}</div>')


def zone_rows(px=12):
    rows = []
    for name, fmt in ZONES:
        cur = name == ZONE
        val = (f'<span style="color:{"var(--friend)" if cur else "inherit"}">'
               f'{name}</span>'
               f'<span class="dim" style="margin-left:auto;font-size:{px - 2}px">'
               f'{fmt}</span>')
        rows.append((val, "here" if cur else "cursor"))
    return rows


def build_rows(hulls=False, cursor="Bomber"):
    rows = []
    for name, hull in BUILDS:
        cur = name == SHIP
        right = (f'<span class="dim" style="margin-left:auto;font-size:10px">'
                 f'{hull.upper()}</span>') if hulls else ""
        val = (f'<span style="color:{"var(--friend)" if cur else "inherit"}">'
               f'{name}</span>{right}')
        rows.append((val, "here" if cur else
                     ("cursor" if name == cursor else None)))
    return rows


def friends_rows():
    rows = [('<span class="dim" style="font-size:11px">ADD A PILOT '
             '&#9615;</span>', None)]
    rows.append((f'{dot("#ffe08a")}<span>Krait 4</span>'
                 f'<span style="margin-left:auto;color:var(--prize);'
                 f'font-size:10px">ACCEPT</span>'
                 f'<span class="dim" style="font-size:10px">IGNORE</span>',
                 None))
    rows.append(("", "rule"))
    for name, zone, on in FRIENDS_ROWS:
        d = dot("#8dffb0") if on else dot("#3f5878")
        z = (f'<span class="dim" style="margin-left:auto;font-size:10px">'
             f'{zone}</span>') if zone else ""
        rows.append((f'{d}<span>{name}</span>{z}', None))
    rows.append(("", "rule"))
    rows.append(('<span style="color:var(--prize)">INVITE A FRIEND</span>',
                 None))
    return rows


def settings_rows():
    return [
        ('<span>Sound</span><span class="dim" style="margin-left:auto;'
         'font-size:11px">ON</span>', None),
        ('<span>Fullscreen</span>', None),
        ('<span>Controls</span>', "cursor"),
        ('<span>About</span>', None),
    ]


def account_rows():
    return [
        (f'<span>{NAME}</span>', None),
        ("", "rule"),
        ('<span style="color:var(--prize)">SIGN UP</span>'
         '<span class="dim" style="margin-left:auto;font-size:10px">'
         'KEEP YOUR POINTS</span>', "cursor"),
        ("<span>LOG IN</span>", None),
        ("<span>NEW NAME</span>", None),
    ]


def price(n):
    return (f'<span class="row" style="gap:5px;color:var(--bounty)">'
            f'{rivet()}<span class="num" style="font-size:11px">{n}</span>'
            f'</span>')


def slot_box(short, name, right, w, h, tint="#9fb6d4", dim=False):
    """One slot of the kit as a box: the mark and name at the left, and at
    the right edge either the level you fly or the price to raise it."""
    ncol = "var(--dim)" if dim else "var(--ink)"
    return (f'<div class="field" style="width:{w}px;height:{h}px">'
            f'<span class="row" style="gap:9px">'
            f'<span class="num" style="font-size:9px;color:{tint};'
            f'letter-spacing:.1em">{short}</span>'
            f'<span style="font-size:12px;color:{ncol}">{name}</span></span>'
            f'<span class="row" style="gap:8px">{right}</span></div>')


def kit_boxes(w, h):
    """The Gunner build's slots. Owned rungs are treads; the next rung for
    sale is a gold price on the same edge."""
    lvl = lambda n, of, t: (f'{steps(n, of, t)}<span class="num" '
                            f'style="font-size:11px;color:{t}">{n}</span>')
    chip = lambda on: (f'<span class="num" style="font-size:10px;'
                       f'color:{"var(--friend)" if on else "var(--dim)"}">'
                       f'{"ON" if on else "OFF"}</span>')
    return [
        slot_box("NRG", "Energy", lvl(4, 5, UP_TINTS["NRG"]), w, h,
                 UP_TINTS["NRG"]),
        slot_box("RCH", "Recharge", lvl(3, 5, UP_TINTS["RCH"]), w, h,
                 UP_TINTS["RCH"]),
        slot_box("SPD", "Speed", lvl(2, 5, UP_TINTS["SPD"]), w, h,
                 UP_TINTS["SPD"]),
        slot_box("THR", "Thrust", lvl(3, 5, UP_TINTS["THR"]), w, h,
                 UP_TINTS["THR"]),
        slot_box("ROT", "Rotation", lvl(2, 5, UP_TINTS["ROT"]), w, h,
                 UP_TINTS["ROT"]),
        slot_box("GUN", "Gun level", lvl(2, 3, "#ffd166"), w, h, "#ffd166"),
        slot_box("BMB", "Bomb level",
                 f'{steps(1, 3, "#ff9a5c")}{price(62)}', w, h, "#ff9a5c"),
        slot_box("GUN", "Spray",
                 f'{steps(2, 3, "#ffd166")}{price(45)}', w, h, "#ffd166"),
        slot_box("BMB", "Bounce", chip(True), w, h, "#ff9a5c"),
        slot_box("BMB", "Shrapnel", price(240), w, h, "#ff9a5c", dim=True),
        slot_box("CHG", "Repel",
                 f'<span class="num" style="font-size:11px">&times;2</span>'
                 f'{price(320)}', w, h, "#ffd166"),
        slot_box("CHG", "Burst",
                 f'<span class="num" style="font-size:11px">&times;1</span>'
                 f'{price(180)}', w, h, "#ffd166"),
    ]


# --- assembly helpers ---------------------------------------------------------


def wrap(w, h, body, seed=28):
    stars = starfield(w, h, *((30, 20, 8) if w < 900 else (46, 30, 12)),
                      seed=seed)
    return (f'<div style="position:absolute;left:0;top:0;width:{w}px;'
            f'height:{h}px;overflow:hidden;background-color:var(--bg);'
            f'background-image:{stars}">{"".join(body)}</div>')


def center(bottom, w):
    return (f'position:absolute;left:50%;transform:translateX(-50%);'
            f'bottom:{bottom}px;width:{w}px')


def chrome(w, h, compact, portrait, seed):
    return [scene(w, h, compact, seed), score_band(compact, portrait),
            radar(compact, portrait)]


def half_row(w, h, style, lit=None):
    """Friends and settings as one split row of two half boxes: the sentence
    stops full width above, the utilities half width below."""
    hw = (w - 8) / 2
    f_edge = "border-color:rgba(79,214,255,.85);" if lit == "friends" else ""
    s_edge = "border-color:rgba(79,214,255,.85);" if lit == "settings" else ""
    return (f'<div class="row" style="{style};gap:8px">'
            f'<div class="field" style="width:{hw}px;height:{h}px;{f_edge}">'
            f'<span class="row" style="gap:8px">{pair()}'
            f'<span class="lbl">FRIENDS</span></span>'
            f'<span class="row" style="gap:9px;font-size:12px">2 ON{caret()}'
            f'</span></div>'
            f'<div class="field" style="width:{hw}px;height:{h}px;{s_edge}">'
            f'<span class="row" style="gap:8px">{gauge()}'
            f'<span class="lbl">SETTINGS</span></span>{caret()}</div></div>')


# --- direction A: unfold ------------------------------------------------------


def a_desktop():
    """The home column, closed: the shipped landing with friends and
    settings aboard as one half row."""
    w, h = FORMS["Desktop"]
    body = chrome(w, h, False, False, 3)
    kw, kh, rh, gap = 320, 54, 40, 8
    body.append(play_key(kw, kh, 19, center(22, kw)))
    y = 22 + kh + 12
    body.append(half_row(kw, rh, center(y, kw)))
    y += rh + gap
    for label, value in (("SHIP", SHIP), ("ZONE", ZONE), ("ACCOUNT", NAME)):
        body.append(box(label, value, kw, rh, style=center(y, kw)))
        y += rh + gap
    body.append(f'<div style="position:absolute;left:50%;'
                f'transform:translateX(-50%);bottom:{y + 8}px">'
                f'{lockup(208)}</div>')
    return wrap(w, h, body)


def a_landscape():
    """The rail the landing already lies down into (decision 91), with
    friends and settings as two square cells before the key."""
    w, h = FORMS["Landscape"]
    body = chrome(w, h, True, False, 5)

    def cell(label, value, cw):
        return (f'<div class="field" style="height:44px;width:{cw}px;'
                f'padding:0 10px;flex:none;flex-direction:column;'
                f'align-items:flex-start;justify-content:center;gap:2px">'
                f'<span class="lbl" style="font-size:8px">{label}</span>'
                f'<span class="row" style="gap:7px;font-size:12px;'
                f'white-space:nowrap">{value}{caret()}</span></div>')

    def sq(icon):
        return (f'<div class="key" style="width:44px;height:44px;flex:none">'
                f'{icon}</div>')

    band = (
        f'<div class="row" style="position:absolute;left:50%;'
        f'transform:translateX(-50%);bottom:16px;gap:8px;align-items:center">'
        f'{mark_only(26)}<div style="width:4px"></div>'
        f'{cell("ACCOUNT", NAME, 116)}'
        f'{cell("ZONE", ZONE, 100)}'
        f'{cell("SHIP", SHIP, 108)}'
        f'{sq(pair())}{sq(gauge())}'
        f'<div style="width:4px"></div>'
        f'{play_key(190, 48, 15)}</div>')
    body.append(band)
    return wrap(w, h, body)


def a_portrait():
    """The column at the phone's full width, the ship box unfolded in place:
    the builds, then the way down into the hangar."""
    w, h = FORMS["Portrait"]
    body = chrome(w, h, True, True, 5)
    kw, kh, rh, gap = w - 28, 50, 44, 8
    body.append(play_key(kw, kh, 16, center(22, kw)))
    y = 22 + kh + 12
    body.append(half_row(kw, rh, center(y, kw)))
    y += rh + gap
    rows = build_rows()
    rows.append(("", "rule"))
    rows.append((f'{caret()}<span>EDIT BUILDS</span>'
                 '<span class="dim" style="margin-left:auto;font-size:10px">'
                 'THE HANGAR</span>', None))
    rows.append((f'{eye()}<span>SPECTATE</span>', None))
    uh = 5 + 6 * 36 + 9 + 5 + 1
    body.append(unfold(rows, kw, 36, 12,
                       style=f'position:absolute;left:50%;'
                             f'transform:translateX(-50%);bottom:{y}px'))
    y += uh
    body.append(box("SHIP", SHIP, kw, rh, lit=True, style=center(y, kw)))
    y += rh
    for label, value in (("ZONE", ZONE), ("ACCOUNT", NAME)):
        y += gap
        body.append(box(label, value, kw, rh, style=center(y, kw)))
        y += rh
    body.append(f'<div style="position:absolute;left:50%;'
                f'transform:translateX(-50%);bottom:{y + 14}px">'
                f'{lockup(150)}</div>')
    return wrap(w, h, body)


# --- direction B: board -------------------------------------------------------


def b_desktop():
    """Everything standing at once: panels at the wings, the sentence and
    the key in the middle, the fight showing between them."""
    w, h = FORMS["Desktop"]
    body = chrome(w, h, False, False, 3)
    pw = 330
    body.append(panel("ZONE", zone_rows(), pw,
                      style=f'position:absolute;left:96px;bottom:22px'))
    body.append(panel("SETTINGS", settings_rows(), pw, row_h=30,
                      style=f'position:absolute;left:96px;bottom:150px'))
    rows = build_rows(hulls=True)
    rows.append(("", "rule"))
    rows.append((f'{caret()}<span>EDIT BUILDS</span>', None))
    body.append(panel("SHIP", rows, pw,
                      style=f'position:absolute;right:96px;bottom:262px'))
    body.append(panel("FRIENDS", friends_rows(), pw, row_h=28,
                      style=f'position:absolute;right:96px;bottom:22px'))
    kw = 320
    body.append(play_key(kw, 54, 19, center(22, kw)))
    body.append(box("ACCOUNT", NAME, kw, 40, style=center(88, kw)))
    body.append(f'<div style="position:absolute;left:50%;'
                f'transform:translateX(-50%);bottom:142px">{lockup(208)}</div>')
    return wrap(w, h, body)


def b_landscape():
    """The board pressed into a window with no height: shallow panels
    abreast, and not much fight left between them."""
    w, h = FORMS["Landscape"]
    body = chrome(w, h, True, False, 5)
    pw = 240
    body.append(panel("ZONE", zone_rows(11), pw, row_h=30, px=11,
                      style=f'position:absolute;left:16px;bottom:16px'))
    rows = build_rows(hulls=True)[:4]
    body.append(panel("SHIP", rows, pw, row_h=27, px=11,
                      style=f'position:absolute;right:16px;bottom:16px'))
    kw = 300
    body.append(play_key(kw, 44, 14, center(16, kw)))
    body.append(half_row(kw, 34, center(68, kw)))
    body.append(box("ACCOUNT", NAME, kw, 34, px=12, style=center(110, kw)))
    body.append(f'<div style="position:absolute;left:50%;'
                f'transform:translateX(-50%);bottom:154px">{lockup(140)}</div>')
    return wrap(w, h, body)


def b_portrait():
    """The board as one column: every panel stacked, the key pinned, and the
    fight reduced to slivers between the glass."""
    w, h = FORMS["Portrait"]
    body = chrome(w, h, True, True, 5)
    kw = w - 28
    body.append(play_key(kw, 50, 16, center(16, kw)))
    y = 16 + 50 + 10
    body.append(box("SETTINGS", "", kw, 40, icon=gauge(),
                    style=center(y, kw)))
    y += 40 + 8
    fr = friends_rows()[:5]
    fh = 28 + 4 * 30 + 9 + 5 + 2
    body.append(panel("FRIENDS", fr, kw, row_h=30,
                      style=f'position:absolute;left:50%;'
                            f'transform:translateX(-50%);bottom:{y}px'))
    y += fh + 8
    rows = build_rows(hulls=True)
    sh = 28 + 4 * 32 + 5
    body.append(panel("SHIP", rows, kw, row_h=32,
                      style=f'position:absolute;left:50%;'
                            f'transform:translateX(-50%);bottom:{y}px'))
    y += sh + 8
    zh = 28 + 2 * 34 + 5
    body.append(panel("ZONE", zone_rows(), kw, row_h=34,
                      style=f'position:absolute;left:50%;'
                            f'transform:translateX(-50%);bottom:{y}px'))
    y += zh + 8
    body.append(box("ACCOUNT", NAME, kw, 44, style=center(y, kw)))
    y += 44
    body.append(f'<div style="position:absolute;left:50%;'
                f'transform:translateX(-50%);bottom:{y + 12}px">'
                f'{lockup(150)}</div>')
    return wrap(w, h, body)


# --- direction C: deck --------------------------------------------------------


def head_box(label, w, h, style):
    """The way back: the first box of every screen below the top one."""
    return (f'<div class="field" style="width:{w}px;height:{h}px;{style}">'
            f'<span class="row" style="gap:10px">{back_caret()}'
            f'<span style="font-size:13px">{label}</span></span>'
            f'<span class="lbl">BACK</span></div>')


def c_ship():
    """SHIP pressed: the column is now the ship screen. Builds as boxes,
    each naming the hull it rides, the key still at the foot."""
    w, h = FORMS["Desktop"]
    body = chrome(w, h, False, False, 3)
    kw, rh, gap = 320, 40, 8
    body.append(play_key(kw, 54, 19, center(22, kw)))
    y = 22 + 54 + 12
    entries = [
        ('<span class="row" style="gap:10px">' + eye() +
         '<span style="font-size:13px">Spectate</span></span>', ""),
        ('<span style="font-size:13px;color:var(--dim)">New build</span>'
         '<span class="num dim" style="font-size:13px">+</span>', ""),
    ]
    for name, hull in reversed(BUILDS):
        cur = name == SHIP
        edge = "border-color:rgba(79,214,255,.85);" if cur else ""
        col = "var(--friend)" if cur else "var(--ink)"
        entries.append((
            f'<span style="font-size:13px;color:{col}">{name}</span>'
            f'<span class="row" style="gap:9px">'
            f'<span class="dim" style="font-size:10px">{hull.upper()}</span>'
            f'{caret()}</span>', edge))
    for html, edge in entries:
        body.append(f'<div class="field" style="width:{kw}px;height:{rh}px;'
                    f'{edge}{center(y, kw)}">{html}</div>')
        y += rh + gap
    body.append(head_box("Ship", kw, rh, center(y, kw)))
    y += rh
    body.append(f'<div style="position:absolute;left:50%;'
                f'transform:translateX(-50%);bottom:{y + 16}px">'
                f'{lockup(208)}</div>')
    return wrap(w, h, body)


def c_build():
    """A build opened: the whole kit as boxes, two abreast where there is
    room. Every slot's right edge is the level you fly or the price to
    raise it, which is the hangar's brief in one rule."""
    w, h = FORMS["Desktop"]
    body = chrome(w, h, False, False, 3)
    bw, rh, gap = 316, 40, 8
    gw = bw * 2 + gap
    body.append(play_key(320, 54, 19, center(22, 320)))
    boxes = kit_boxes(bw, rh)
    rows = [boxes[i:i + 2] for i in range(0, len(boxes), 2)]
    y = 22 + 54 + 12
    for pair_ in reversed(rows):
        body.append(f'<div class="row" style="{center(y, gw)};gap:{gap}px">'
                    f'{"".join(pair_)}</div>')
        y += rh + gap
    meter = (f'<div class="row" style="{center(y, gw)};height:20px;'
             f'justify-content:space-between">'
             f'<span class="lbl">GUNNER SPENDS 21 OF 30 POINTS</span>'
             f'<span class="row" style="gap:6px">{rivet()}'
             f'<span class="num" style="font-size:11px;color:var(--bounty)">'
             f'1 240</span></span></div>')
    body.append(meter)
    y += 20 + gap
    hull = (f'<div class="field" style="width:{gw}px;height:{rh}px;'
            f'{center(y, gw)}"><span class="lbl">HULL</span>'
            f'<span class="row" style="gap:9px;font-size:13px">'
            f'<svg width="22" height="22" viewBox="-14 -16 28 28" '
            f'style="flex:none"><path d="{HULLS["Apex"]}" fill="#0b1220" '
            f'stroke="#4fd6ff" stroke-width="1.5" transform="scale(.62)"/>'
            f'</svg>Apex{caret()}</span></div>')
    body.append(hull)
    y += rh + gap
    body.append(head_box("Gunner", gw, rh, center(y, gw)))
    return wrap(w, h, body)


def c_portrait():
    """The build screen on a phone: the same boxes in one column that
    scrolls, nothing redesigned for the small window."""
    w, h = FORMS["Portrait"]
    body = chrome(w, h, True, True, 5)
    kw, rh, gap = w - 28, 38, 6
    body.append(play_key(kw, 50, 16, center(16, kw)))
    boxes = kit_boxes(kw, rh)
    y = 16 + 50 + 10
    for b in reversed(boxes):
        body.append(f'<div style="{center(y, kw)}">{b}</div>')
        y += rh + gap
    meter = (f'<div class="row" style="{center(y, kw)};height:18px;'
             f'justify-content:space-between">'
             f'<span class="lbl">21 OF 30 POINTS</span>'
             f'<span class="row" style="gap:6px">{rivet()}'
             f'<span class="num" style="font-size:11px;color:var(--bounty)">'
             f'1 240</span></span></div>')
    body.append(meter)
    y += 18 + gap
    hull = (f'<div class="field" style="width:{kw}px;height:{rh}px;'
            f'{center(y, kw)}"><span class="lbl">HULL</span>'
            f'<span class="row" style="gap:9px;font-size:12px">Apex'
            f'{caret()}</span></div>')
    body.append(hull)
    y += rh + gap
    body.append(head_box("Gunner", kw, rh, center(y, kw)))
    return wrap(w, h, body)


# --- the match: what MENU raises with no drawer behind it --------------------


def match_menu():
    """Mid-match, the same column over the fight: the zone you are in, the
    ship dimmed while a match holds it, friends, settings, and the key
    reads RESUME."""
    w, h = FORMS["Landscape"]
    body = chrome(w, h, True, False, 9)
    body.append('<div style="position:absolute;inset:0;'
                'background:rgba(5,7,12,.45)"></div>')
    body.append('<div class="key" style="position:absolute;left:14px;'
                'top:14px;height:22px;padding:0 9px;font-size:9px;'
                'border-color:rgba(79,214,255,.85);color:var(--ink)">'
                'MENU</div>')
    kw, rh, gap = 300, 34, 6
    total = 3 * rh + 2 * gap + 10 + 44
    y = (h - total) / 2
    body.append(play_key(kw, 44, 14, center(y, kw), word="RESUME"))
    y += 44 + 10
    body.append(half_row(kw, rh, center(y, kw)))
    y += rh + gap
    body.append(box("SHIP", SHIP, kw, rh, px=12, dim=True,
                    style=center(y, kw)))
    y += rh + gap
    body.append(box("ZONE", "Team Battle", kw, rh, px=12,
                    style=center(y, kw)))
    return wrap(w, h, body)


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


def main():
    page("Main", a_desktop())
    page("UnfoldLandscape", a_landscape())
    page("UnfoldPortrait", a_portrait())
    page("BoardDesktop", b_desktop())
    page("BoardLandscape", b_landscape())
    page("BoardPortrait", b_portrait())
    page("DeckShip", c_ship())
    page("DeckBuild", c_build())
    page("DeckPortrait", c_portrait())
    page("MatchMenu", match_menu())
    print("ten artboards written")


if __name__ == "__main__":
    main()
