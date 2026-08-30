#!/usr/bin/env python3
"""Assemble the artboards for the ship menu as five sections.

Chris's ask: the ship menu should be a handful of rows, body, guns,
bombs, specials and flair, each one opening a submenu that holds the
config for that part, with the build credits on display at the top,
above body and below the back bar, and still there in every submenu.

What is there today is one panel with everything on it. The hull is
walked on the top row, five flight bars read under it, the credit tray
sits under those, and then every slot the hull can spend on runs down
the rest of the glass under three band labels: gun, bomb, rack. On an
Apex that is 762 points of panel against the 782 an 810-point window
has to give it, so it fits by twenty and scrolls on anything shorter, a
phone included. What goes off the top first is the tray: a pilot
stepping a slot near the foot is spending a purse they cannot see.

Five sections fix both. The menu is five rows and a reset, none of it
scrolls, and the tray is chrome rather than content: it rides under the
head on the menu and on every submenu, so the purse is on screen
wherever a credit is being spent.

Each of the five reads what it holds, in the voice the games list reads
a format in: `menu_row` puts a detail at TYPE.BODY in `pal.MUTE` hard
against the right of the type column, which is what "4v4 3:00" is
wearing on the zone stop. Body reads the hull, and the hull's five bars
stand under the row that names it, because the stats are the answer to
the question that row asks.

The five are not new groupings. Four of them are the sections
`menu.tune_rows` already builds (flight, gun, bomb and rack) under the
words Chris used, and the fifth is the pair the settings page is
holding for the ship: the wake and which key throws which charge.

Every number is lifted from the client rather than invented:
`client/arena/palette.lua` for hues, `ui.lua` for the type ladder
{12, 14, 17, 21}, LIT {0.18, 0.07}, the 44-point row, PANEL_MAX 560,
the 14-point inset and margin, the 34x18 switch, the 30-point credit
tray and its nine-point diamonds. The rows in each submenu are what
`sim_slot_cap` answers off the shipped baseline, in the order
`tune_rows` builds them: the trigger's own level first, then gun caps
{spray 5, bounce 1, freeze 1} and bomb caps {bounce 1, prox 1,
shrapnel 3, freeze 1}, with prox, shrapnel and push off the gun and
spray off the bomb. The rack is repel to 3 and burst to 2. Shrapnel
reads fragments rather than levels, so one level reads 4. The bars are
`flight` off sim/src/baseline.c, shared against the roster's own range
the way `flight_bars` does it. The scene behind the glass is
../dropdown-stack's.

The level row is called Level. It was Rung, which is the client's word
for the thing and not the core's: `SIM_SLOT_LEVEL` and `SLOT_NOTES`
both say level, and a ladder can go on being a ladder in prose without
the row a pilot presses having to say so.

One pilot flies every board, on one build: an Apex on spray 1, gun
bounce 1, bomb shrapnel 1, repel 2 and burst 1. Three of those five
come with the hull and two were stepped on top of it, and a profile is
spent from the same purse as a step, so that is six credits of seven
with one in hand. The three counts on the menu add up to what the tray
has spent, on purpose: they are the same six.

Rebuild with: python3 build.py
"""

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
BTN = "#0a0f18"         # BTN_BG: the glass's own tint
CAUTION = "#ffd166"     # CHARGE_COL: the credit, and the tray it is spent from

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

/* The glass: frost plus the button tint, outlined in the tile color.
   One ground for a stop, a panel and a card alike. */
.glass{{border:1px solid rgba(63,88,120,.75);background:rgba(10,15,24,.72);
  backdrop-filter:blur(5px)}}
"""

# --- small marks, at the pen weight the client draws them --------------------


def caret(col=READ, k=10):
    """Opens: two strokes saying a panel is about to come up over this one."""
    return (f'<svg width="{k}" height="{k}" viewBox="0 0 10 10" fill="none" '
            f'style="flex:none"><path d="M1.5 3 L5 7 L8.5 3" stroke="{col}" '
            f'stroke-width="1.4" stroke-linecap="square"/></svg>')


def back_tri(a=0.9):
    return (f'<svg width="11" height="12" viewBox="0 0 11 12" '
            f'style="flex:none"><polygon points="2,6 9,1.5 9,10.5" '
            f'fill="rgba(79,214,255,{a})"/></svg>')


def step_tri(direction, live=True, k=13):
    pts = "2,6.5 11,1.5 11,11.5" if direction < 0 else "11,6.5 2,1.5 2,11.5"
    a = 0.9 if live else 0.25
    return (f'<svg width="{k}" height="{k}" viewBox="0 0 13 13" '
            f'style="flex:none"><polygon points="{pts}" '
            f'fill="rgba(79,214,255,{a})"/></svg>')


def diamond(on=True, k=9):
    """One credit. Filled is in hand, hollow is spent, which is the tray's
    own rule: `land_panel` lights the first `free` of `credits`."""
    fill = CAUTION if on else "rgba(255,209,102,.18)"
    return (f'<span style="width:{k}px;height:{k}px;flex:none;'
            f'transform:rotate(45deg);background:{fill}"></span>')


# --- the row: one shape, six right ends --------------------------------------
# Decision 104's language, unchanged: 44 tall, inset 14, the name in the menu
# face at 17 sentence case, the reading in the mono at 14, and the right end
# is what the row does. Nothing here needs a seventh end: a section row opens,
# which is the caret every stop on the landing already wears.

WASH_CURSOR = "background:rgba(79,214,255,.18)"
WASH_HERE = "background:rgba(79,214,255,.07)"


def reading(text, col=MUTE):
    """A row's reading, in the voice the games list reads its format in.

    `menu_row` draws a detail at TYPE.BODY in `pal.MUTE`, right against the
    type column's far edge, in the face the numbers in flight are set in. That
    is what "4v4 3:00" is wearing on the zone stop, and it is what these
    sections wear now: quieter than the name it answers, and never mistaken
    for a control."""
    return (f'<span class="mono" style="font-size:14px;color:{col}">'
            f'{text}</span>')


def r_open(detail=""):
    """Opens, with what is inside said beside the caret. The detail sits
    fourteen points inside the caret, which is where `menu_row` puts it."""
    return (f'<span class="row" style="margin-left:auto;gap:6px">'
            f'{detail}{caret()}</span>')


def r_spend(n):
    """A section's reading: the credits standing in it, in the color they
    are spent in, against a tray of the same diamonds directly above."""
    if n == 0:
        return (f'<span class="row" style="gap:6px">{diamond(False, 7)}'
                f'<span class="mono" style="font-size:14px;'
                f'color:rgba(133,147,169,.85)">0</span></span>')
    return (f'<span class="row" style="gap:6px">{diamond(True, 7)}'
            f'<span class="mono" style="font-size:14px;color:{CAUTION}">{n}'
            f'</span></span>')


def r_stepper(value, down=True, up=True, lit=True):
    col = FRIEND if lit else DIM
    return (f'<span class="row" style="margin-left:auto;gap:10px">'
            f'{step_tri(-1, down)}<span class="mono" style="font-size:14px;'
            f'color:{col};min-width:18px;text-align:center">{value}</span>'
            f'{step_tri(1, up)}</span>')


def r_range(word, n, on):
    cells = "".join(
        '<span style="width:13px;height:10px;flex:none;'
        + (f'background:{FRIEND}' if k < on
           else 'border:1px solid rgba(108,122,144,.6)')
        + '"></span>' for k in range(n))
    return (f'<span class="row" style="margin-left:auto;gap:12px">'
            f'<span class="mono" style="font-size:14px;color:{READ}">{word}'
            f'</span><span class="row" style="gap:5px">{cells}</span></span>')


def r_switch(on):
    edge = "rgba(79,214,255,.75)" if on else "rgba(63,88,120,.75)"
    fill = "rgba(79,214,255,.18)" if on else "transparent"
    knob = (f'background:{FRIEND};margin-left:auto' if on
            else f'background:{DIM};opacity:.6')
    return (f'<span style="margin-left:auto;width:34px;height:18px;flex:none;'
            f'border:1px solid {edge};background:{fill};display:flex;'
            f'align-items:center;padding:2px">'
            f'<span style="width:12px;height:12px;flex:none;{knob}"></span>'
            f'</span>')


def row(name, right="", h=44, state=None, dim=False, pad=14):
    wash = {"cursor": WASH_CURSOR, "here": WASH_HERE}.get(state, "")
    col = DIM if dim else INK
    alpha = "opacity:.85;" if not (state or dim) else ""
    return (f'<div class="row" style="height:{h}px;padding:0 {pad}px;'
            f'gap:10px;{wash}"><span style="font-size:17px;color:{col};'
            f'{alpha}">{name}</span>{right}</div>')


def rule(pad=14):
    return (f'<div style="padding:4px {pad}px">'
            '<div style="height:1px;background:rgba(63,88,120,.6)"></div>'
            '</div>')


def head(section, foot_note=None, hot=False, pad=14):
    """The back bar: the way back and the name of what you are in, the whole
    line being the press, lit like the control it is."""
    note = ""
    if foot_note:
        note = (f'<span style="font-size:11px;color:{READ};margin-left:auto;'
                f'font-family:var(--menu)">{foot_note}</span>')
    wash = WASH_CURSOR if hot else ""
    ink = INK if hot else MUTE
    return (f'<div class="row" style="height:44px;padding:0 {pad}px;gap:10px;'
            f'flex:none;border-bottom:1px solid rgba(63,88,120,.6);{wash}">'
            f'{back_tri(1 if hot else 0.9)}'
            f'<span class="lbl" style="color:{ink}">{section}</span>'
            f'{note}</div>')


def tray(free=1, total=7, pad=14):
    """The purse, under the back bar and above everything else.

    It was content: the third strip of the one ship panel, scrolling away
    with the rows above it. Here it is chrome, drawn once by the panel and
    the same on every section, so a pilot stepping a slot is looking at what
    that step costs. Closed by a rule of its own, which the first row then
    stands under."""
    chips = "".join(diamond(k < free) for k in range(total))
    return (f'<div style="flex:none">'
            f'<div class="row" style="height:30px;padding:0 {pad}px">'
            f'<span class="lbl" style="color:rgba(255,209,102,.8)">'
            f'build credits</span>'
            f'<span class="row" style="margin-left:auto;gap:6px">{chips}'
            f'</span></div>'
            '<div style="height:1px;background:rgba(63,88,120,.45)"></div>'
            '</div>')


# What each hull flies at, verbatim from `flight` in sim/src/baseline.c. The
# step is zero on every row and the ceiling is the floor, so the first number
# of each triplet is the whole of it.
STATS = ("speed", "thrust", "turn", "energy", "recharge")
FLIGHT = {
    "Apex":    (3600, 205, 250, 1500, 1150),
    "Wedge":   (2900, 155, 205, 1900, 1020),
    "Chord":   (2800, 215, 310, 1550, 1200),
    "Anvil":   (2650, 145, 195, 2100, 1250),
    "Cipher":  (3900, 200, 235, 1400, 1100),
    "Facet":   (3050, 175, 265, 1400, 1100),
    "Lattice": (3100, 165, 240, 1750, 1050),
}
ROSTER = list(FLIGHT)


def shares(hull):
    """Where a hull stands on each row as a share of the roster's own range,
    which is what `flight_bars` answers and for its reason: the units are the
    core's, five different scales none of which a player reads, and the
    question is "faster than what"."""
    out = []
    for i in range(5):
        col = [FLIGHT[h][i] for h in ROSTER]
        lo, hi = min(col), max(col)
        span = hi - lo
        out.append((FLIGHT[hull][i] - lo) / span if span else 1.0)
    return out


# The Apex silhouette, verbatim from `M.HULLS` in client/arena/world.lua: the
# polygon the client calls the part a menu draws, the interior lines that say
# which way it is facing, and the canopy. Local pixels with the nose along +y.
APEX_POLY = [(0, 21), (1.6, 12), (2.6, 5), (6.5, -1), (11, -9), (8.5, -11.5),
             (3.5, -6.5), (3, -10.5), (0, -11.5), (-3, -10.5), (-3.5, -6.5),
             (-8.5, -11.5), (-11, -9), (-6.5, -1), (-2.6, 5), (-1.6, 12)]
APEX_LINES = [[(0, 19.8), (2.6, 5), (6.5, -1)],
              [(0, 19.8), (-2.6, 5), (-6.5, -1)],
              [(5, 0.2), (9.3, -8.2)], [(-5, 0.2), (-9.3, -8.2)],
              [(2.6, 1.5), (6, -1.6)], [(-2.6, 1.5), (-6, -1.6)]]
APEX_CANOPY = [(0, 15.5), (1.5, 10.5), (0, 7.6), (-1.5, 10.5)]
APEX_PLATES = [[(0, 6.5), (2.2, 2), (1.8, -6), (0, -8), (-1.8, -6), (-2.2, 2)]]
APEX_TUBES = [((4.2, 3), (4.2, -1), 1.4), ((-4.2, 3), (-4.2, -1), 1.4)]
# `reach` is the circle that holds the hull and `mid` is halfway up it, both
# measured off the polygon when world.lua loads. A drawing about the origin
# sits low, because every hull reaches further forward than back.
APEX_REACH = 22.0
APEX_MID = 4.75
PANEL_INK = "#9fb6d4"


def hull_art(cx, cy, r, squash, col=FRIEND):
    """One hull, turning on its own vertical axis, drawn the way the arena
    draws one.

    Not a tracing. The client gives a hull plates washed and outlined in the
    panel ink, hardpoints drawn hot, a canopy that is always the brightest
    closed shape on it, and a silhouette whose every edge carries its own
    brightness. The bloom is the one part it leaves out: that lives on the
    fight's additive layer, and a panel draws on one that composites.

    `squash` is the cosine of the turn: local x scaled by it and the length
    left alone, which is a ship rotating about the axis up the screen.
    Broadside at 1, edge-on at 0. Caught mid-turn here rather than animated;
    the client turns it once every eleven seconds."""
    k = r / APEX_REACH

    def put(pts):
        return [(cx + px * squash * k, cy - (py - APEX_MID) * k)
                for px, py in pts]

    def path(pts, close):
        d = "M" + " L".join(f"{x:.1f},{y:.1f}" for x, y in pts)
        return d + (" Z" if close else "")

    parts = []
    for plate in APEX_PLATES:
        t = put(plate)
        parts.append(f'<path d="{path(t, True)}" fill="{PANEL_INK}" '
                     f'fill-opacity=".035" stroke="{PANEL_INK}" '
                     f'stroke-width="0.85" stroke-opacity=".36"/>')
    for line in APEX_LINES:
        parts.append(f'<path d="{path(put(line), False)}" fill="none" '
                     f'stroke="{PANEL_INK}" stroke-width="0.7" '
                     f'stroke-opacity=".26"/>')
    for a, b, w in APEX_TUBES:
        t = put([a, b])
        parts.append(f'<path d="{path(t, False)}" stroke="{col}" '
                     f'stroke-width="{w * k:.1f}" stroke-opacity=".3"/>')
        parts.append(f'<path d="{path(t, False)}" stroke="{INK}" '
                     f'stroke-width="{w * k * 0.34:.1f}" '
                     f'stroke-opacity=".9"/>')
    # The silhouette, every edge at its own brightness: a light fixed to the
    # hull's own nose, so a ship reads the same whichever way it is pointing.
    hull = put(APEX_POLY)
    lo = min(p[1] for p in APEX_POLY)
    span = max(p[1] for p in APEX_POLY) - lo
    for i, (x, y) in enumerate(hull):
        x2, y2 = hull[(i + 1) % len(hull)]
        t = (APEX_POLY[i][1] - lo) / span
        parts.append(f'<path d="M{x:.1f},{y:.1f} L{x2:.1f},{y2:.1f}" '
                     f'stroke="{col}" stroke-width="1.5" '
                     f'stroke-opacity="{max(0.18, t * t):.2f}" '
                     f'stroke-linecap="round"/>')
    parts.append(f'<path d="{path(put(APEX_CANOPY), True)}" fill="{INK}" '
                 f'fill-opacity=".42" stroke="{INK}" stroke-width="0.9" '
                 f'stroke-opacity=".95"/>')
    return "".join(parts)


def carousel(hull, note, squash=0.62, h=228, pad=14, here=True):
    """The body section: one ship turning, an arrow either side of it level
    with the ship rather than with the row, and the name and the hull's own
    line under it.

    The ship is the press that flies it; the arrows only look. That press sits
    at the priority every other control on a panel does, which is what it did
    not do at first: the glass publishes its own box before any row draws, and
    a control sharing that priority is one the panel swallows."""
    col = FRIEND if here else INK
    nameh, noteh = 30, 22
    mid = (h - nameh - noteh) / 2
    wash = WASH_HERE if here else ""
    art = hull_art(560 / 2, mid, min(mid - 6, 78), squash, col)
    return (f'<div style="position:relative;height:{h}px;{wash}">'
            f'<svg width="560" height="{h}" style="position:absolute;'
            f'inset:0">{art}</svg>'
            f'<div style="position:absolute;left:{pad + 10}px;top:{mid - 9}px">'
            f'{step_tri(-1, k=18)}</div>'
            f'<div style="position:absolute;right:{pad + 10}px;'
            f'top:{mid - 9}px">{step_tri(1, k=18)}</div>'
            f'<div style="position:absolute;left:0;right:0;'
            f'bottom:{noteh}px;height:{nameh}px;display:flex;'
            f'align-items:center;justify-content:center;font-size:21px;'
            f'color:{col}">{hull}</div>'
            f'<div style="position:absolute;left:0;right:0;bottom:0;'
            f'height:{noteh}px;display:flex;align-items:center;'
            f'justify-content:center;font-size:14px;color:{READ}">{note}</div>'
            f'</div>')


def stat_line(name, share, col=FRIEND, pad=14):
    """One flight row: the word, and where this hull stands on it against the
    rest of the roster.

    With a floor under the fill, because the hull at the bottom of a row is
    still a hull that flies: a share of nothing drew nothing, and the Anvil is
    the floor of speed, thrust and turn all three."""
    pct = max(3.5, round(share * 100))
    return (f'<div class="row" style="height:26px;padding:0 {pad}px;gap:0">'
            f'<span class="lbl" style="width:96px;flex:none">{name}</span>'
            f'<span style="flex:1;height:3px;background:'
            f'linear-gradient(90deg,{col} {pct}%,rgba(108,122,144,.22) '
            f'{pct}%)"></span></div>')


# --- the fight behind the glass, from ../dropdown-stack ----------------------

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
    watches a live room, so `match_clock` draws while `M.joined` is false and
    only the press into the board stands down.

    A side with nowhere left to grow drops its name rather than the whole band
    dropping a line, which at 390 points is both of them."""
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


# --- a panel standing over a fight -------------------------------------------

PANEL_MAX = 560


def panel(w, section, inner, margin=14, foot_note=None, free=1,
          bottom=None, back=False):
    """As tall as what it holds, standing on the margin it slid out of.

    `back` is the panel a submenu has come up over: decision 104 says a
    covered panel stands down, so it is drawn at a third of its strength.
    The cursor goes with the panel that took it, and what is left lit on the
    covered menu is the mark on the section that is open."""
    pw = min(w - 2 * margin, PANEL_MAX)
    left = (w - pw) / 2
    pad = margin
    bot = margin if bottom is None else bottom
    fade = "opacity:.34;" if back else ""
    return (f'<div class="glass" style="position:absolute;left:{left:.0f}px;'
            f'width:{pw:.0f}px;bottom:{bot}px;'
            f'max-height:calc(100% - {2 * margin}px);{fade}'
            f'display:flex;flex-direction:column;overflow:hidden">'
            + head(section, foot_note, pad=pad)
            + tray(free=free, pad=pad)
            + '<div style="padding:5px 0;display:flex;flex-direction:column;'
            'min-height:0">' + "".join(inner) + '</div></div>')


def board(w, h, section, inner, seed, foot_note=None, free=1, margin=14):
    return wrap(w, h, [scene(w, h, seed), score_band(),
                       panel(w, section, inner, margin=margin,
                             foot_note=foot_note, free=free)], seed)


# --- the pilot every board flies ---------------------------------------------
#
# An Apex on spray 1, gun bounce 1, bomb shrapnel 1, repel 2 and burst 1. The
# first, fourth and fifth come with the hull and the other two were stepped on
# top of it, which is a distinction the purse does not make: a hull's own
# profile is spent from the same seven `SIM_KIT_CREDITS` hands out. Six of
# them, one still in hand.
#
# The three counts on the menu are those six, split the way the submenus split
# them, which is the whole reason a count is what a section reads.

FREE = 1


def menu_rows(cursor="Guns", open_row=None):
    """`cursor` is where a press would land and `open_row` is the section
    already open, which is the landing's own rule for a stop whose panel is
    up. One of each a screen at most: two washed rows in one frame is two
    answers to the question the cursor asks."""
    def state(name):
        if name == open_row:
            return "here"
        return "cursor" if name == cursor else None
    return [
        row("Body", r_open(reading("Apex")), state=state("Body")),
        row("Guns", r_open(reading("2 rounds \u00b7 bouncing")),
            state=state("Guns")),
        row("Bombs", r_open(reading("4 fragments")), state=state("Bombs")),
        row("Specials", r_open(reading("2 repels \u00b7 1 burst")),
            state=state("Specials")),
        row("Flair", r_open(reading("standard wake")), state=state("Flair")),
        rule(),
        # Live, because this build is not the hull's own any more. It is the
        # whole of the build manager and it stays on the menu rather than in a
        # section: what it puts back is all five of them at once.
        row("Reset", "", state=state("Reset")),
    ]


def main_board():
    return board(1440, 810, "ship", menu_rows(), seed=7, free=FREE)


def body_board():
    """One ship, turning, with its flight read out underneath.

    It was a walker, then a list of seven with five bars apiece, and it is a
    carousel: what a hull looks like is most of what a pilot is choosing
    between, and neither of the first two had room to draw one. The five bars
    are still there, one to a line, under the ship they belong to.

    The tray is still drawn, because the purse is a fact about the ship rather
    than about the page, and nothing here costs a credit on the shipped
    roster: every hull's flight step is zero."""
    rows = [carousel("Apex", "Second fastest, and nothing about it "
                     "is a weakness")]
    for name, share in zip(STATS, shares("Apex")):
        rows.append(stat_line(name, share))
    return board(1440, 810, "body", rows, seed=3,
                 foot_note="enter flies it", free=FREE)


def guns_board():
    return board(1440, 810, "guns", [
        # Counted from one, because the bottom of a ladder is a rung: the
        # slot counts credits and the row draws value plus base, so an
        # untouched gun reads 1 and its down arrow is dead.
        row("Level", r_stepper(1, down=False), state="cursor"),
        row("Spray", r_stepper(1)),
        row("Bounce", r_switch(True)),
        row("Freeze", r_switch(False)),
    ], seed=11, free=FREE)


def bombs_board():
    return board(1440, 810, "bombs", [
        row("Level", r_stepper(1, down=False)),
        row("Bounce", r_switch(False)),
        row("Proximity detonation", r_switch(False)),
        # The one row whose figure is not what it cost: shrapnel's magnitude
        # is another weapon, so the row reads the fragments a rung throws.
        # One rung is four. See decision 105.
        row("Shrapnel", r_stepper(4), state="cursor"),
        row("Freeze", r_switch(False)),
    ], seed=5, free=FREE)


def specials_board():
    """The rack, under the word Chris used for it. Repel to three and burst
    to two, which is what the baseline caps them at."""
    return board(1440, 810, "specials", [
        row("Repel", r_stepper(2), state="cursor"),
        row("Burst", r_stepper(1)),
    ], seed=17, free=FREE)


def flair_board():
    """What a ship looks like and which key throws which charge: the two
    things a pilot decides that are not about how a ship fights.

    They are on the settings page, which is where they went when the ship
    page was one list of things to spend credits on. A section that costs
    nothing is not out of place beside four that do, so they come back and
    settings loses them: one control, one home."""
    return board(1440, 810, "flair", [
        row("Wake", r_range("Standard", 3, 1), state="cursor"),
        row("Charge keys", r_range("Repel first", 2, 1)),
    ], seed=23, free=FREE)


def stack_board():
    """The motion, and what "stays visible in the submenus" turns into.

    A section slides up through the bottom edge and the menu stands down
    behind it, which is decision 103's grammar unchanged. What is new is that
    the tray comes up with it: it is the first thing under the back bar on
    whichever panel is on top, so a section arrives with the purse already on
    it and there is no scroll position left that can take it away.

    It does not hold still, and this is the board that says so. A panel is as
    tall as what it holds and stands on the bottom margin it slid out of, so a
    section of four rows sits lower than a menu of six and its tray rides down
    with its own head. What is fixed is the tray's place in a panel, not its
    place on the screen."""
    w, h = 1440, 810
    return wrap(w, h, [
        scene(w, h, 13), score_band(),
        panel(w, "ship", menu_rows(cursor=None, open_row="Guns"),
              free=FREE, back=True),
        panel(w, "guns", [
            row("Level", r_stepper(1, down=False), state="cursor"),
            row("Spray", r_stepper(1)),
            row("Bounce", r_switch(True)),
            row("Freeze", r_switch(False)),
        ], free=FREE, bottom=-152),
    ], 13)


def phone_board():
    """362 points of glass on a 390 phone, which is the window less the
    14-point margin `panel_geom` keeps at every window size, and the whole
    menu still fits above the fold: five rows, a rule and the reset, over a
    tray that is always the top of the panel. This is the shape the scroll
    was costing.

    Nothing is lit. A cursor is where a press would land, and on glass there
    is nowhere a press is waiting to land."""
    w, h = 390, 844
    return wrap(w, h, [
        scene(w, h, 29), score_band(names=False),
        panel(w, "ship", menu_rows(cursor=None), free=FREE),
    ], 29)


def alt_reading_board():
    """The road not taken, kept as the record of the choice.

    A section could read what it holds in credits rather than what it holds
    in the fight. The count is the same currency the tray above is
    denominated in, so the two read as one instrument and a pilot hunting a
    credit to free knows which row to open without opening any of them. What
    it cannot do is say anything about the ship: three sections reading 2, 1
    and 3 describe a purse, and the pilot is here about a gun.

    Chris took the contents. This is what the other one looked like."""
    return board(1440, 810, "ship", [
        row("Body", r_open(reading("Apex"))),
        row("Guns", r_open(r_spend(2)), state="cursor"),
        row("Bombs", r_open(r_spend(1))),
        row("Specials", r_open(r_spend(3))),
        row("Flair", r_open(r_spend(0))),
        rule(),
        row("Reset", ""),
    ], seed=7, free=FREE)


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
    page("Main", main_board())
    page("Stack", stack_board())
    page("Body", body_board())
    page("Guns", guns_board())
    page("Bombs", bombs_board())
    page("Specials", specials_board())
    page("Flair", flair_board())
    page("Phone", phone_board())
    page("AltReading", alt_reading_board())
    print("nine artboards written")


if __name__ == "__main__":
    main()
