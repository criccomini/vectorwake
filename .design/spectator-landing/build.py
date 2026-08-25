#!/usr/bin/env python3
"""Assemble the nine .dc.html artboards for the spectator-first landing mocks.

The proposal: play.vectorwake.net opens straight into a melee room as a
watcher. The HUD is the watcher's own (corner keys, clock and score, radar
and feed, no hull furniture) plus one pulsing PLAY NOW key. The question
these mocks exist to answer is where the game's name goes on that screen,
three window shapes by three placements:

  A  above the PLAY NOW key, so the name and the way in read as one unit
  B  top center, under the clock and score
  C  in the corner the watcher's missing corner stack leaves empty
     (portrait has no empty corner, so C degrades to the bare mark
     in the chrome row)

Drawings of a proposal, not a plan of record. The design system is lifted
from ../rethink/build.py, which lifted it from the real client:
client/arena/palette.lua for hues, client/arena/ui.lua for panel geometry
(PAD 14, RADAR 168, FONT 13), docs/design/ships.md for hull extents, and the
two faces the client carries. The lockup is the canonical mark and word from
docs/banner.svg. Three facts here are the shipped client's rather than the
rethink's: the sides are Pylon and Caisson (catalog/zones/melee/zone.toml),
the watcher's corner row is MENU / PLAYERS / CHANNEL (ui.lua menu_button),
and the PLAY NOW key breathes exactly as the deck's DEPLOY key does
(sin at 2.6 rad/s, edge floored at 0.62, ui.lua line 4854).

One deliberate departure from the shipped watcher HUD: no TAKE SEAT key in
the corner row. PLAY NOW is that key, celebrated; two controls for one act
would be the menu's old sin again.

Rebuild with: python3 build.py
"""

import math
import random
from pathlib import Path

HERE = Path(__file__).parent

# --- the three windows -------------------------------------------------------
FORMS = {
    "Desktop":   (1440, 810, False),
    "Landscape": (844, 390, True),
    "Portrait":  (390, 844, True),
}

VARIANTS = {
    "A": "above PLAY NOW",
    "B": "under the score",
    "C": "in the corner",
}

# --- the sky, as world.lua draws it: three depths and a faint nebula ---------


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
.panel{position:relative;background:rgba(5,7,12,.62)}
.panel::before{content:"";position:absolute;left:0;top:0;bottom:0;width:1.4px;
  background:rgba(63,88,120,.7)}

/* One shape for a thing to press: a rectangle outlined all the way round
   with a wash inside it. ui.lua key_cap(). */
.key{display:inline-flex;align-items:center;justify-content:center;gap:7px;
  border:1px solid rgba(63,88,120,.75);background:rgba(10,15,24,.6);
  font-family:var(--mono);text-transform:uppercase;letter-spacing:.06em;
  color:#9fb6d4}

/* The one press this screen exists for. Fill and edge swell on the tally's
   slow beat: sin at 2.6 rad/s is a 2.42s period, and the trough is floored
   well above dark so it never reads as a key that stopped working.
   ui.lua line 4854. */
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

# --- who is in a seat, in two marks. ui.lua helm()/bot_mark() ----------------


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
            f'<circle cx="5" cy="6" r=".9" fill="{col}"/>'
            f'<circle cx="9" cy="6" r=".9" fill="{col}"/>'
            f'<path d="M1.2 9.4 H12.8" stroke="{col}" stroke-width="1.1"/></svg>')


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


def rivet(col="#ffe08a", k=9):
    return (f'<svg width="{k}" height="{k}" viewBox="0 0 12 12" fill="none" '
            f'style="flex:none">'
            f'<circle cx="6" cy="6" r="4.4" stroke="{col}" stroke-width="1.1"/>'
            f'<circle cx="6" cy="6" r="1.7" fill="{col}"/>'
            f'<path d="M6 1.6 V3" stroke="{col}" stroke-width="1"/>'
            f'<path d="M6 9 V10.4" stroke="{col}" stroke-width="1"/></svg>')


# --- the lockup, verbatim from docs/banner.svg -------------------------------
# The mark's two chevrons and the word's outlines (Chakra Petch, already
# paths), so the mock carries the exact identity rather than a live-text
# approximation of it. Ink runs x 333.5..946.5, y 72..157 in banner space.

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
    """Mark and word together, w px wide, transparent ground."""
    h = round(w * 88 / 616)
    return (f'<svg width="{w}" height="{h}" viewBox="332 71 616 88" '
            f'style="display:block">'
            f'<g transform="translate(334.975 83) scale(.7115)">{MARK_PATHS}</g>'
            f'{WORD_PATH}</svg>')


def mark_only(h):
    """The two chevrons alone, for a row with no room for the word."""
    w = round(h * 84 / 103)
    return (f'<svg width="{w}" height="{h}" viewBox="0 0 84 103" '
            f'style="display:block">{MARK_PATHS}</svg>')


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


# --- the room: eight seats, four a side, camera on the channel's subject -----
# World coordinates are relative to the subject; every window crops the same
# fight. Name, hull, side color, offset, heading, bounty.
FRIEND, ENEMY = "#4fd6ff", "#ffa552"
SHIPS = [
    ("KRAIT 4",   "Wedge",   FRIEND, (0, 10),      18,  7),   # the subject
    ("VIREO 9",   "Chord",   FRIEND, (-170, 40),   62,  2),
    ("SABER 3",   "Facet",   FRIEND, (-320, -150), 118, 4),
    ("PLINTH 41", "Lattice", FRIEND, (520, 290),   -40, 1),
    ("MANTIS 7",  "Cipher",  ENEMY,  (150, -95),   205, 5),
    ("HALCYON 2", "Anvil",   ENEMY,  (365, 55),    160, 9),
    ("SABLE 09",  "Wedge",   ENEMY,  (-460, 240),  285, 1),
    ("ORRERY 3",  "Apex",    ENEMY,  (430, -285),  320, 3),
]


def nameplate(x, y, name, col, bounty, px):
    """Call sign and bounty at the hull's lower right, like every pilot's.
    The one unlabeled hull is your own, and a watcher has none."""
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
    """The fight behind the glass: walls, eight hulls, rounds in the air."""
    cx, cy = w / 2, h / 2
    rnd = random.Random(seed)
    parts = []
    # Wall masses, kept off the knot of ships in the middle.
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
    # Rounds wear the rung's color, one ramp for the whole game.
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


# --- the watcher's chrome ----------------------------------------------------


def corner_row(compact):
    """MENU, PLAYERS, and the green channel mark. ui.lua menu_button(), less
    the TAKE SEAT key: PLAY NOW is that key now."""
    kh, px = (22, 9) if compact else (26, 11)
    mk = 10 if compact else 12
    tri_h = 9 if compact else 11
    return f"""
  <div class="row" style="position:absolute;left:14px;top:14px;gap:8px">
    <div class="key" style="height:{kh}px;padding:0 9px;font-size:{px}px">MENU</div>
    <div class="key" style="height:{kh}px;padding:0 9px;font-size:{px}px">PLAYERS
      {helm('#9fb6d4', mk)}<span style="margin-left:-4px">3</span>
      {bot('#9fb6d4', mk)}<span style="margin-left:-4px">5</span></div>
    <div class="row" style="gap:6px;margin-left:4px">
      <svg width="{tri_h}" height="{tri_h}" viewBox="0 0 10 12">
        <path d="M0 0 L10 6 L0 12 Z" fill="#8dffb0" opacity=".92"/></svg>
      <span class="hud" style="font-size:{px}px;color:#8dffb0;opacity:.92">CHANNEL</span>
    </div>
  </div>"""


def score_band(compact, portrait=False):
    """The clock and the score, dead center at the top: the two facts a three
    minute match is about. Sides from catalog/zones/melee/zone.toml. A phone
    held upright has no top center to spare on the first row, since the
    corner keys own it, so the band drops to a second row and the names come
    off: the numbers keep the side colors, and the roster has the names."""
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


def minimap(side, seed):
    rnd = random.Random(seed)
    blips = []
    for _ in range(26):
        bx, by = rnd.randint(6, 94), rnd.randint(6, 94)
        w, h = rnd.choice([(6, 3), (3, 7), (5, 5), (9, 3), (3, 10)])
        blips.append(f'<rect x="{bx}" y="{by}" width="{w}" height="{h}" '
                     f'fill="#3f5878" opacity=".85"/>')
        blips.append(f'<rect x="{100 - bx - w}" y="{100 - by - h}" width="{w}" '
                     f'height="{h}" fill="#3f5878" opacity=".85"/>')
    ships = ('<circle cx="47" cy="52" r="2" fill="#4fd6ff"/>'
             '<circle cx="41" cy="61" r="2" fill="#4fd6ff"/>'
             '<circle cx="38" cy="43" r="2" fill="#4fd6ff"/>'
             '<circle cx="72" cy="70" r="2" fill="#4fd6ff"/>'
             '<circle cx="55" cy="44" r="2" fill="#ffa552"/>'
             '<circle cx="66" cy="55" r="2" fill="#ffa552"/>'
             '<circle cx="28" cy="66" r="2" fill="#ffa552"/>'
             '<circle cx="79" cy="30" r="2" fill="#ffa552"/>')
    return (f'<div style="position:relative;width:{side}px;height:{side}px">'
            f'<svg width="{side}" height="{side}" viewBox="0 0 100 100" '
            f'style="background:rgba(6,10,16,.55)">{"".join(blips)}{ships}</svg>'
            f'{bracket()}</div>')


FEED = [
    ("MANTIS 7", ENEMY, "SABER 3", FRIEND, 1.0),
    ("KRAIT 4", FRIEND, "SABLE 09", ENEMY, 0.85),
    ("HALCYON 2", ENEMY, "VIREO 9", FRIEND, 0.45),
]


def feed_lines():
    """Kill sentences, newest first: names as their owners wrote them, the
    interface talking in lower case between them. ui.lua feed()."""
    rows = []
    for a, ca, b, cb, alpha in FEED:
        rows.append(
            f'<div class="row" style="height:18px;justify-content:flex-end;'
            f'gap:0;opacity:{alpha}">'
            f'<span class="num" style="font-size:10px;color:{ca}">{a}</span>'
            f'<span class="num dim" style="font-size:10px">&nbsp;killed&nbsp;</span>'
            f'<span class="num" style="font-size:10px;color:{cb}">{b}</span></div>')
    return "".join(rows)


def link_bars():
    bars = "".join(
        f'<rect x="{i * 4}" y="{9 - i * 3}" width="2.6" height="{3 + i * 3}" '
        f'fill="#6c7a90" opacity=".8"/>' for i in range(4))
    return f'<svg width="16" height="12" viewBox="0 0 16 12">{bars}</svg>'


def radar_feed(compact, portrait=False):
    side = 90 if portrait else (120 if compact else 168)
    top = 40 if portrait else 14
    return f"""
  <div style="position:absolute;right:14px;top:{top}px;display:flex;
       flex-direction:column;align-items:flex-end;gap:10px">
    {'' if portrait else link_bars()}
    {minimap(side, 7)}
    {'' if compact else f'<div style="margin-top:2px">{feed_lines()}</div>'}
  </div>"""


def toast():
    """The phone's reading of the feed: one line over the middle, where the
    corner column would sit under a thumb."""
    a, ca, b, cb, _ = FEED[0]
    return (f'<div class="row" style="position:absolute;top:29%;left:50%;'
            f'transform:translateX(-50%);gap:0">'
            f'<span class="num" style="font-size:10px;color:{ca}">{a}</span>'
            f'<span class="num dim" style="font-size:10px">&nbsp;killed&nbsp;</span>'
            f'<span class="num" style="font-size:10px;color:{cb}">{b}</span></div>')


def play_key(w, h, px, extra_style=""):
    return (f'<div class="play" style="width:{w}px;height:{h}px;'
            f'font-size:{px}px;{extra_style}">PLAY NOW</div>')


TABS = ["Play", "Ship", "Upgrades", "Friends", "Standings", "Settings"]


def tab_bar():
    """The bar a thumb reaches, exactly where the menu already puts it under
    620 points. Play is lit: it is where you are."""
    cells = []
    for t in TABS:
        lit = t == "Play"
        col = "var(--ink)" if lit else "var(--dim)"
        wash = ("background:linear-gradient(0deg,rgba(79,214,255,.14),"
                "rgba(79,214,255,0) 80%);" if lit else "")
        cells.append(f'<div style="flex:1;display:flex;align-items:center;'
                     f'justify-content:center;height:100%;font-size:11px;'
                     f'color:{col};{wash}">{t}</div>')
    return (f'<div style="position:absolute;left:0;right:0;bottom:0;height:84px;'
            f'background:rgba(5,7,12,.55);border-top:1px solid rgba(63,88,120,.5);'
            f'display:flex">{"".join(cells)}</div>')


# --- one window, one placement ----------------------------------------------


def screen(form, variant):
    w, h, compact = FORMS[form]
    portrait = form == "Portrait"
    body = [scene(w, h, compact, seed={"Desktop": 3, "Landscape": 3,
                                       "Portrait": 5}[form]),
            corner_row(compact), score_band(compact, portrait),
            radar_feed(compact, portrait)]
    if compact:
        body.append(toast())

    bottom_gap = 98 if portrait else 22  # above the tab bar, or the edge
    if portrait:
        body.append(tab_bar())

    # The key: full width above the tab bar on a phone held upright, its own
    # box at the bottom middle everywhere else.
    if portrait:
        key = play_key(w - 28, 50, 16,
                       f"position:absolute;left:14px;bottom:{bottom_gap}px")
    elif compact:
        key = play_key(240, 44, 14,
                       f"position:absolute;left:50%;transform:translateX(-50%);"
                       f"bottom:{bottom_gap}px")
    else:
        key = play_key(320, 54, 19,
                       f"position:absolute;left:50%;transform:translateX(-50%);"
                       f"bottom:{bottom_gap}px")
    body.append(key)

    key_h = 50 if portrait else (44 if compact else 54)
    lock_w = 150 if compact else 208
    if variant == "A":
        # The name over the way in: one lockup, one key, one unit.
        if portrait:
            pos = (f"position:absolute;left:50%;transform:translateX(-50%);"
                   f"bottom:{bottom_gap + key_h + 14}px")
        else:
            pos = (f"position:absolute;left:50%;transform:translateX(-50%);"
                   f"bottom:{bottom_gap + key_h + (12 if compact else 16)}px")
        body.append(f'<div style="{pos}">{lockup(lock_w)}</div>')
    elif variant == "B":
        # Under the clock: the strip the pennants and the round's banner own
        # in flag games, free in melee.
        top = {"Desktop": 72, "Landscape": 50, "Portrait": 84}[form]
        body.append(f'<div style="position:absolute;left:50%;top:{top}px;'
                    f'transform:translateX(-50%)">'
                    f'{lockup(120 if compact else 168)}</div>')
    else:
        # The corner the missing corner stack leaves empty. Portrait has no
        # empty corner, so the mark rides the chrome alone, favicon-sized,
        # under MENU where the score band's second row leaves room.
        if portrait:
            body.append(f'<div style="position:absolute;left:14px;top:46px">'
                        f'{mark_only(18)}</div>')
        else:
            body.append(f'<div style="position:absolute;left:20px;'
                        f'bottom:{18 if compact else 22}px">'
                        f'{lockup(120 if compact else 168)}</div>')

    stars = starfield(w, h, *(dict(Desktop=(46, 30, 12), Landscape=(30, 20, 8),
                                   Portrait=(30, 20, 8))[form]),
                      seed=28)
    # Absolutely positioned so nothing in flow can push the frame's bottom
    # edge past the artboard's: clipping is the one failure a fixed frame has.
    return (f'<div style="position:absolute;left:0;top:0;width:{w}px;'
            f'height:{h}px;overflow:hidden;background-color:var(--bg);'
            f'background-image:{stars}">{"".join(body)}</div>')


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
    for form in FORMS:
        for v in VARIANTS:
            name = "Main" if (form, v) == ("Desktop", "A") else f"{form}{v}"
            page(name, screen(form, v))
    print("nine artboards written")


if __name__ == "__main__":
    main()
