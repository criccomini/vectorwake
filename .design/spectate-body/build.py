#!/usr/bin/env python3
"""Assemble the artboards for what the body carousel draws on spectate.

The ship stop's body section is a carousel: one ship turning on its own
vertical axis, an arrow either side of it, its name under it and its own
line under that. Seven hulls turn through it and the eighth stop is
spectate, which has no hull, so the drawing is skipped and 168 points of
glass are left empty over the word. Nothing else on the menu has a hole
in it.

Four drawings for that hole, and a board apiece over the same room, plus
the empty one that ships today so the four have something to be compared
against.

The four are not four styles of one idea. Ghost keeps the roster's own
shape and takes the pilot out of it. Lens is a machine whose whole
purpose is to look, and it puts its bright cell where a hull carries a
canopy, which is the one inversion that says watching without a word.
Mast is a fixture rather than a flier: the thing the channel comes out
of. Frame is not a craft at all, and does not turn.

Every drawing here is in the local pixels `world.lua` writes a hull in,
nose along +y, and is drawn by the same four weights the arena gives a
hull: closed plates washed and outlined in the panel ink, panel lines
under them, a silhouette whose every edge carries its own brightness off
a light fixed to the nose, and one bright closed cell. So a pick here is
a table to paste into `M.HULLS`'s neighborhood rather than a picture to
work back from.

The shared rule the four agree on: none of them wears the team color. A
hull on this carousel is drawn in `pal.FRIEND` because the ship you turn
to is the ship you fly, and a watcher flies nothing and holds no side.
The instrument gray is what the interface uses for everything that
describes rather than belongs to you, so these are drawn in it, and the
word Spectate under them stays blue because the stop is still the one
you are standing on.

The panel, the tray, the arrows, the type ladder and the geometry are
lifted from client/arena/ui.lua; the glass, the scene behind it and the
score band are from ../ship-sections/build.py, which lifted them from
../dropdown-stack.

Rebuild with: python3 build.py
"""

import math
import random
from pathlib import Path

HERE = Path(__file__).parent

# --- the palette, verbatim from client/arena/palette.lua ---------------------
BG = "#05070c"
INK = "#dfe9f5"
DIM = "#6c7a90"
READ = "#9fb6d4"
MUTE = "#8593a9"
FRIEND = "#4fd6ff"
ENEMY = "#ffa552"
TILE = "#3f5878"        # RADAR_TILE: every rule and resting edge
CAUTION = "#ffd166"     # CHARGE_COL: the credit, and the tray it is spent from
PANEL_INK = "#9fb6d4"   # the interior of a hull, in a neutral instrument gray

CSS = f"""
:root{{ --bg:{BG}; --ink:{INK}; --dim:{DIM}; --read:{READ}; --mute:{MUTE};
  --friend:{FRIEND}; --enemy:{ENEMY}; --tile:{TILE}; --caution:{CAUTION};
  --mono:"DejaVu Sans Mono","Noto Sans Mono",ui-monospace,monospace;
  --menu:"Chakra Petch","Segoe UI",system-ui,sans-serif; }}
*{{box-sizing:border-box}}
body{{margin:0;background:var(--bg);color:var(--ink);font-family:var(--menu)}}
a{{color:var(--friend)}}a:hover{{color:#8ee6ff}}
.mono{{font-family:var(--mono)}}
.lbl{{font-family:var(--mono);font-size:12px;text-transform:uppercase;
  letter-spacing:.1em;color:var(--mute)}}
.row{{display:flex;align-items:center}}

/* The glass: frost plus the button tint, outlined in the tile color. */
.glass{{border:1px solid rgba(63,88,120,.75);background:rgba(10,15,24,.72);
  backdrop-filter:blur(5px)}}
"""

# --- the carousel's own geometry, from client/arena/ui.lua -------------------
#
# `pages.land_row_h` gives the art row 198 points plus a line of note at
# `pages.NOTE_LINE`, so the shipped sentence makes it 217. `land_row` takes
# the name's 30 and the note's 19 off the bottom, centers the drawing in what
# is left, and caps its radius at HULL_ART_R. The arrows sit 24 points in from
# either edge, level with the middle of the drawing rather than of the row.
ART_ROW = 198
NAME_H = 30
NOTE_LINE = 19
ART_R = 78
PANEL_MAX = 560
MARGIN = 14
INSET = 14
ARROW_IN = 24
NOTE = "Watch the room from nobody's cockpit"


# --- small marks, at the pen weight the client draws them --------------------


def back_tri(a=0.9):
    return (f'<svg width="11" height="12" viewBox="0 0 11 12" '
            f'style="flex:none"><polygon points="2,6 9,1.5 9,10.5" '
            f'fill="rgba(79,214,255,{a})"/></svg>')


def step_tri(direction, k=18):
    pts = "2,6.5 11,1.5 11,11.5" if direction < 0 else "11,6.5 2,1.5 2,11.5"
    return (f'<svg width="{k}" height="{k}" viewBox="0 0 13 13" '
            f'style="flex:none"><polygon points="{pts}" '
            f'fill="rgba(79,214,255,0.9)"/></svg>')


def diamond(on=True, k=9):
    fill = CAUTION if on else "rgba(255,209,102,.18)"
    return (f'<span style="width:{k}px;height:{k}px;flex:none;'
            f'transform:rotate(45deg);background:{fill}"></span>')


def head(section, pad=INSET):
    """The back bar: the way back and the name of what you are in."""
    return (f'<div class="row" style="height:44px;padding:0 {pad}px;gap:10px;'
            f'flex:none;border-bottom:1px solid rgba(63,88,120,.6)">'
            f'{back_tri()}'
            f'<span class="lbl" style="color:{MUTE}">{section}</span></div>')


def tray(free=0, total=7, pad=INSET):
    """The purse, drawn by the panel on every section. Empty on every board
    here: the default build spends all seven credits, and a watcher is not
    spending any of them either way."""
    chips = "".join(diamond(k < free) for k in range(total))
    return (f'<div style="flex:none">'
            f'<div class="row" style="height:30px;padding:0 {pad}px">'
            f'<span class="lbl" style="color:rgba(255,209,102,.8)">'
            f'build credits</span>'
            f'<span class="row" style="margin-left:auto;gap:6px">{chips}'
            f'</span></div>'
            '<div style="height:1px;background:rgba(63,88,120,.45)"></div>'
            '</div>')


# --- the four drawings -------------------------------------------------------
#
# Local pixels, nose along +y, in the shape `M.HULLS` writes a hull in:
#
#   poly    the silhouette, every edge lit off the nose
#   plates  closed interior loops, washed and outlined in the panel ink
#   lines   open polylines at the panel line's weight
#   hollow  a closed shape outlined and not filled: a cell with nobody in it
#   discs   (x, y, r): the one bright cell, drawn the way a lamp is
#   flat    no nose light, every edge of the silhouette at one brightness
#   turns   False holds the drawing still while the carousel turns


def ring(n, r, cy=0.0, phase=0.5):
    """A closed regular n-gon, phase in half steps so a flat edge or a
    vertex can be put at the top."""
    out = []
    for i in range(n):
        a = (i + phase) * 2 * math.pi / n
        out.append((r * math.cos(a), cy + r * math.sin(a)))
    return out


LENS_C = 2.5
LENS_R = 14.6


def _iris():
    """Six blades and the spokes behind them: an aperture rather than a
    dish, so what the ring is for is legible at 156 points across."""
    blades = ring(6, 6.2, LENS_C, phase=0.5)
    out = [blades + [blades[0]]]
    for i in range(6):
        a = (i + 1.0) * 2 * math.pi / 6
        out.append([(6.2 * math.cos(a), LENS_C + 6.2 * math.sin(a)),
                    (10.4 * math.cos(a), LENS_C + 10.4 * math.sin(a))])
    return out


ART = {
    # Ghost: the roster's own language with the pilot taken out of it. A
    # plain delta none of the seven flies, its canopy outlined and not
    # filled, no hardpoints, no lamps, and no light on the nose, because
    # the light on a hull is a hull under way.
    "Ghost": dict(
        poly=[(0, 19), (2.4, 7), (6.6, -1.5), (11, -9.5), (5.5, -9),
              (3.4, -12), (0, -11), (-3.4, -12), (-5.5, -9), (-11, -9.5),
              (-6.6, -1.5), (-2.4, 7)],
        plates=[[(0, 6), (2.0, 1.5), (1.7, -6), (0, -7.6), (-1.7, -6),
                 (-2.0, 1.5)]],
        lines=[[(0, 17.6), (2.4, 7), (6.6, -1.5)],
               [(0, 17.6), (-2.4, 7), (-6.6, -1.5)],
               [(4.4, 0.4), (8.6, -8.0)], [(-4.4, 0.4), (-8.6, -8.0)],
               [(-2.0, -8.6), (2.0, -8.6)]],
        hollow=[[(0, 13.6), (1.5, 9.8), (0, 7.2), (-1.5, 9.8)]],
        discs=[],
        flat=True,
        turns=True,
        line="A hull with the seat empty",
    ),
    # Lens: the channel's own camera. The ring is the silhouette and the
    # pupil is the bright cell, which is the canopy's place on every other
    # drawing this carousel shows. A hood over the top says which way it
    # looks, so the front is visibly not the back at radar scale, and the
    # ring turning edge on is the clearest read of the turn in the set.
    "Lens": dict(
        poly=ring(12, LENS_R, LENS_C),
        plates=[ring(12, 10.4, LENS_C),
                [(3.0, -13.0), (2.2, -18.4), (-2.2, -18.4), (-3.0, -13.0)]],
        lines=_iris() + [
            [(10.3, 12.8), (6.2, 19.4)], [(-10.3, 12.8), (-6.2, 19.4)],
            [(-6.2, 19.4), (6.2, 19.4)],
            [(10.3, -7.8), (2.8, -14.2)], [(-10.3, -7.8), (-2.8, -14.2)],
        ],
        hollow=[],
        discs=[(0, LENS_C, 3.3)],
        flat=False,
        turns=True,
        line="The room's camera, and nothing else",
    ),
    # Mast: a relay with panels and a dish, which is a thing the room has
    # rather than a thing anybody flies. No canopy anywhere on it, and the
    # bright cell is the feed at the dish's focus.
    "Mast": dict(
        poly=[(0, 17), (2.6, 9), (2.2, -2), (3.6, -9), (2.4, -15),
              (-2.4, -15), (-3.6, -9), (-2.2, -2), (-2.6, 9)],
        plates=[[(-12.5, 2.2), (-17, 2.2), (-17, -4.5), (-12.5, -4.5)],
                [(12.5, 2.2), (17, 2.2), (17, -4.5), (12.5, -4.5)]],
        lines=[[(-11, 7.2), (-7.4, 11.6), (0, 13.8), (7.4, 11.6), (11, 7.2)],
               [(-11, 7.2), (0, 17.8)], [(11, 7.2), (0, 17.8)],
               [(-12.5, 0.5), (12.5, 0.5)], [(-9.5, -7.5), (9.5, -7.5)],
               [(-12.5, 0.5), (-9.5, -7.5)], [(12.5, 0.5), (9.5, -7.5)],
               [(-12.5, 0.5), (-10.2, -7.5), (-8.0, 0.5), (-5.8, -7.5),
                (-3.6, 0.5)],
               [(12.5, 0.5), (10.2, -7.5), (8.0, 0.5), (5.8, -7.5),
                (3.6, 0.5)]],
        hollow=[],
        discs=[(0, 17.8, 1.7)],
        flat=False,
        turns=True,
        line="A fixture the channel comes out of",
    ),
    # Frame: no craft at all. Four corner brackets and a reticle, which is
    # the interface's own language rather than the world's, and the one
    # drawing here that holds still while the carousel turns.
    "Frame": dict(
        poly=[],
        plates=[],
        lines=[[(13, 7.5), (13, 13), (7.5, 13)],
               [(-13, 7.5), (-13, 13), (-7.5, 13)],
               [(13, -7.5), (13, -13), (7.5, -13)],
               [(-13, -7.5), (-13, -13), (-7.5, -13)],
               [(6.2, 0), (8.8, 0)], [(-6.2, 0), (-8.8, 0)],
               [(0, 6.2), (0, 8.8)], [(0, -6.2), (0, -8.8)]],
        hollow=[ring(12, 3.8)],
        discs=[(0, 0, 1.1)],
        flat=True,
        turns=False,
        line="Not a ship, and says so",
    ),
}


def _points(spec):
    out = list(spec["poly"])
    for group in ("plates", "lines", "hollow"):
        for shape in spec[group]:
            out.extend(shape)
    out.extend((d[0], d[1]) for d in spec["discs"])
    return out


def measure(spec):
    """`reach` and `mid` the way world.lua measures them at load: the circle
    that holds the drawing, and halfway up it. Off the silhouette where there
    is one, and off everything drawn where there is not."""
    pts = spec["poly"] or _points(spec)
    lo = min(p[1] for p in pts)
    hi = max(p[1] for p in pts)
    reach = max(math.hypot(x, y) for x, y in _points(spec))
    return reach, (lo + hi) / 2


def draw(spec, cx, cy, r, squash, col=READ):
    """One drawing, turned, in the four weights the arena gives a hull.

    `squash` is the cosine of the turn: local x scaled by it and the length
    left alone, which is a rotation about the axis running up the screen.
    Broadside at 1 and edge on at 0, caught mid turn here rather than
    animated. The client turns a hull once every eleven seconds."""
    reach, mid = measure(spec)
    k = r / reach
    if not spec["turns"]:
        squash = 1.0

    def put(pts):
        return [(cx + px * squash * k, cy - (py - mid) * k) for px, py in pts]

    def path(pts, close):
        d = "M" + " L".join(f"{x:.1f},{y:.1f}" for x, y in pts)
        return d + (" Z" if close else "")

    parts = []
    for plate in spec["plates"]:
        parts.append(f'<path d="{path(put(plate), True)}" fill="{PANEL_INK}" '
                     f'fill-opacity=".035" stroke="{PANEL_INK}" '
                     f'stroke-width="0.85" stroke-opacity=".36"/>')
    for line in spec["lines"]:
        parts.append(f'<path d="{path(put(line), False)}" fill="none" '
                     f'stroke="{PANEL_INK}" stroke-width="0.7" '
                     f'stroke-opacity=".26" stroke-linecap="round"/>')
    # The silhouette, edge by edge. A light fixed to the drawing's own nose,
    # unless it is flat: nothing is under way here, and the Ghost is the one
    # that wants saying so.
    poly = spec["poly"]
    if poly:
        hull = put(poly)
        lo = min(p[1] for p in poly)
        span = max(p[1] for p in poly) - lo
        for i, (x, y) in enumerate(hull):
            x2, y2 = hull[(i + 1) % len(hull)]
            t = (poly[i][1] - lo) / span
            a = 0.45 if spec["flat"] else max(0.18, t * t)
            parts.append(f'<path d="M{x:.1f},{y:.1f} L{x2:.1f},{y2:.1f}" '
                         f'stroke="{col}" stroke-width="1.5" '
                         f'stroke-opacity="{a:.2f}" stroke-linecap="round"/>')
    for shape in spec["hollow"]:
        parts.append(f'<path d="{path(put(shape), True)}" fill="none" '
                     f'stroke="{INK}" stroke-width="0.9" '
                     f'stroke-opacity=".46"/>')
    for dx, dy, dr in spec["discs"]:
        x, y = put([(dx, dy)])[0]
        parts.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{dr * 2.4 * k:.1f}"'
                     f' fill="{col}" fill-opacity=".10"/>')
        parts.append(f'<ellipse cx="{x:.1f}" cy="{y:.1f}" '
                     f'rx="{max(1.0, dr * k * squash):.1f}" '
                     f'ry="{dr * k:.1f}" fill="{INK}" fill-opacity=".42" '
                     f'stroke="{INK}" stroke-width="0.9" '
                     f'stroke-opacity=".95"/>')
    return "".join(parts)


# --- the carousel ------------------------------------------------------------


def carousel(name, spec=None, squash=0.62, w=PANEL_MAX, note=NOTE):
    """The body section turned to a stop that is not a hull: the drawing,
    an arrow either side of it, the name, and the line under the name.

    Sitting out carries no flight bars, because there is no ship to say
    anything about, so this row is the whole of the section and the panel is
    as short as the menu ever gets."""
    h = ART_ROW + NOTE_LINE
    band = h - NAME_H - NOTE_LINE
    mid = band / 2
    art = ""
    if spec:
        art = draw(spec, w / 2, mid, min(mid - 6, ART_R), squash)
    return (f'<div style="position:relative;height:{h}px">'
            f'<svg width="{w}" height="{h}" style="position:absolute;'
            f'inset:0">{art}</svg>'
            f'<div style="position:absolute;left:{ARROW_IN - 9}px;'
            f'top:{mid - 9:.0f}px">{step_tri(-1)}</div>'
            f'<div style="position:absolute;right:{ARROW_IN - 9}px;'
            f'top:{mid - 9:.0f}px">{step_tri(1)}</div>'
            f'<div style="position:absolute;left:0;right:0;'
            f'bottom:{NOTE_LINE}px;height:{NAME_H}px;display:flex;'
            f'align-items:center;justify-content:center;font-size:21px;'
            f'color:{FRIEND}">{name}</div>'
            f'<div style="position:absolute;left:0;right:0;bottom:0;'
            f'height:{NOTE_LINE}px;display:flex;align-items:center;'
            f'justify-content:center;font-size:14px;color:{READ}">{note}'
            f'</div></div>')


# --- the fight behind the glass, from ../ship-sections -----------------------

SHAPES = {
    "Wedge":   "M0,-13 L15,9 L7,12 L0,8 L-7,12 L-15,9 Z",
    "Chord":   "M0,-13 L8,-7 L17,1 L13,5 L5,2 L-5,2 L-13,5 L-17,1 L-8,-7 Z",
    "Cipher":  "M0,-22 L3,-6 L6,8 L2,12 L-2,12 L-6,8 L-3,-6 Z",
    "Anvil":   "M-8,-15 L8,-15 L13,-5 L13,6 L8,11 L-8,11 L-13,6 L-13,-5 Z",
    "Facet":   "M0,-8 L11,-1 L8,12 L-8,12 L-11,-1 Z",
}

SHIPS = [
    ("KRAIT 4",   "Wedge",  FRIEND, (0, 10),      18),
    ("VIREO 9",   "Chord",  FRIEND, (-190, 60),   62),
    ("SABER 3",   "Facet",  FRIEND, (-350, -160), 118),
    ("MANTIS 7",  "Cipher", ENEMY,  (170, -95),   205),
    ("HALCYON 2", "Anvil",  ENEMY,  (385, 65),    160),
]


def scene(w, h, seed):
    cx, cy = w / 2, h / 2
    rnd = random.Random(seed)
    parts = []
    for _ in range(16):
        x = rnd.randint(-60, w - 40)
        y = rnd.randint(-40, h - 40)
        bw, bh = rnd.choice([(96, 32), (32, 108), (64, 64), (150, 30)])
        if abs(x + bw / 2 - cx) < 260 and abs(y + bh / 2 - cy) < 200:
            continue
        parts.append(
            f'<rect x="{x}" y="{y}" width="{bw}" height="{bh}" fill="#080d16" '
            f'stroke="#22344f" stroke-width="1"/>'
            f'<path d="M{x} {y} H{x + bw}" stroke="#5b82b8" stroke-width="1.4" '
            f'opacity=".55"/>')
    parts.append(f'<path d="M{cx + 60} {cy - 32} L{cx + 76} {cy - 44}" '
                 'stroke="#f7dd0b" stroke-width="2.6" stroke-linecap="round"/>')
    for name, hull, col, (ox, oy), rot in SHIPS:
        x, y = cx + ox, cy + oy
        if not (-40 < x < w + 40 and -40 < y < h + 40):
            continue
        parts.append(
            f'<g transform="translate({x},{y}) rotate({rot})">'
            f'<path d="M-4,10 L-2,52 L2,52 L4,10 Z" fill="{col}" opacity=".16"/>'
            f'<path d="{SHAPES[hull]}" fill="#0b1220" stroke="{col}" '
            f'stroke-width="1.5" stroke-linejoin="round"/></g>'
            f'<text x="{x + 16}" y="{y + 22}" fill="{col}" opacity=".9" '
            f'font-family="DejaVu Sans Mono,monospace" font-size="10">{name}'
            '</text>')
    return (f'<svg width="{w}" height="{h}" '
            f'style="position:absolute;inset:0">{"".join(parts)}</svg>')


def starfield(w, h, n, seed):
    rnd = random.Random(seed)
    out = []
    for col, r, k in (("#2a3a58", 0.9, n), ("#4a6089", 1.0, n * 2 // 3),
                      ("#93a9c8", 1.3, n // 4)):
        for _ in range(k):
            x, y = rnd.randint(0, w), rnd.randint(0, h)
            out.append(f"radial-gradient(circle {r}px at {x}px {y}px,"
                       f"{col} 0 {r}px,transparent {r}px)")
    return ",".join(out)


def score_band(names=True):
    """The top row over the arena, which the stands get too: the landing
    watches a live room, so the clock draws while the pilot is not in it."""
    if not names:
        return ('<div style="position:absolute;top:14px;left:50%;'
                'transform:translateX(-50%);display:flex;align-items:center;'
                'gap:18px">'
                f'<span class="mono" style="font-size:26px;color:{FRIEND}">3'
                '</span>'
                '<span class="mono" style="font-size:30px">1:47</span>'
                f'<span class="mono" style="font-size:26px;color:{ENEMY}">5'
                '</span></div>')
    return ('<div style="position:absolute;top:14px;left:50%;'
            'transform:translateX(-50%);display:flex;align-items:center;'
            'gap:22px">'
            f'<span class="mono" style="font-size:11px;color:{FRIEND}">PYLON'
            '</span>'
            f'<span class="mono" style="font-size:30px;color:{FRIEND}">3</span>'
            '<span class="mono" style="font-size:34px">1:47</span>'
            f'<span class="mono" style="font-size:30px;color:{ENEMY}">5</span>'
            f'<span class="mono" style="font-size:11px;color:{ENEMY}">CAISSON'
            '</span></div>')


def wrap(w, h, body, seed=9):
    return (f'<div style="position:absolute;left:0;top:0;width:{w}px;'
            f'height:{h}px;overflow:hidden;background-color:{BG};'
            f'background-image:{starfield(w, h, 40, seed)}">'
            + "".join(body) + '</div>')


def panel(w, inner, margin=MARGIN):
    """As tall as what it holds, standing on the margin it slid out of."""
    pw = min(w - 2 * margin, PANEL_MAX)
    left = (w - pw) / 2
    return (f'<div class="glass" style="position:absolute;left:{left:.0f}px;'
            f'width:{pw:.0f}px;bottom:{margin}px;'
            f'max-height:calc(100% - {2 * margin}px);'
            f'display:flex;flex-direction:column;overflow:hidden">'
            + head("body") + tray()
            + '<div style="padding:5px 0;display:flex;flex-direction:column;'
            'min-height:0">' + "".join(inner) + '</div></div>')


def board(w, h, inner, seed, names=True):
    return wrap(w, h, [scene(w, h, seed), score_band(names), panel(w, inner)],
                seed)


# --- the boards --------------------------------------------------------------


def today_board():
    """What ships: the drawing is skipped where there is no hull, and the
    carousel keeps its full height anyway, so the word sits at the bottom of
    168 empty points with two arrows floating in the middle of them. It reads
    as a panel that failed to load rather than as a choice."""
    return board(1440, 810, [carousel("Spectate")], seed=3)


def concept_board(name, squash=0.62, seed=3):
    return board(1440, 810, [carousel("Spectate", ART[name], squash)],
                 seed=seed)


def sheet_board():
    """The four at the size the carousel draws them, each one broadside and
    then most of the way round, which is the whole of what a pilot sees: the
    drawing is never still on this page for longer than it takes to read.

    Frame is the same twice on purpose. It does not turn."""
    w, h = 1440, 600
    cols = list(ART.items())
    step = w / len(cols)
    parts = []
    for i, (name, spec) in enumerate(cols):
        cx = step * (i + 0.5)
        for j, sq in enumerate((1.0, 0.34)):
            cy = 152 + j * 208
            parts.append(f'<g>{draw(spec, cx, cy, ART_R, sq)}</g>')
    art = f'<svg width="{w}" height="{h}" style="position:absolute;inset:0">'
    art += "".join(parts) + "</svg>"
    labels = []
    for i, (name, spec) in enumerate(cols):
        left = step * i
        if not spec["turns"]:
            labels.append(
                f'<div class="lbl" style="position:absolute;'
                f'left:{left:.0f}px;top:436px;width:{step:.0f}px;'
                f'text-align:center;color:{DIM}">holds still</div>')
        labels.append(
            f'<div style="position:absolute;left:{left:.0f}px;top:472px;'
            f'width:{step:.0f}px;text-align:center">'
            f'<div style="font-size:21px;color:{FRIEND}">{name}</div>'
            f'<div style="font-size:14px;color:{READ};padding:6px 40px 0">'
            f'{spec["line"]}</div></div>')
    heads = (f'<div style="position:absolute;left:0;right:0;top:34px;'
             f'text-align:center" class="lbl">four spectate drawings, '
             f'at the 156 points the carousel gives them</div>'
             f'<div class="lbl" style="position:absolute;left:26px;top:126px;'
             f'writing-mode:vertical-rl">broadside</div>'
             f'<div class="lbl" style="position:absolute;left:26px;top:336px;'
             f'writing-mode:vertical-rl">turning</div>')
    return wrap(w, h, [art, heads] + labels, 11)


def phone_board():
    """362 points of glass on a 390 phone, which is the window less the
    14-point margin the panel keeps at every size. The drawing is capped by
    the row rather than by the glass, so it is the same 156 points across
    here as on a desktop window and the panel is the same height."""
    w, h = 390, 844
    return wrap(w, h, [scene(w, h, 29), score_band(names=False),
                       panel(w, [carousel("Spectate", ART["Lens"], 0.72,
                                          w=w - 2 * MARGIN)])], 29)


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
    page("Main", concept_board("Lens", 0.82))
    page("Today", today_board())
    page("Ghost", concept_board("Ghost", 0.90, seed=5))
    page("Mast", concept_board("Mast", 0.88, seed=7))
    page("Frame", concept_board("Frame", 1.0, seed=13))
    page("Sheet", sheet_board())
    page("Phone", phone_board())
    print("seven artboards written")


if __name__ == "__main__":
    main()
