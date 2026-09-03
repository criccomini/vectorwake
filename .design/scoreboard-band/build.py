#!/usr/bin/env python3
"""Assemble the artboards for the scoreboard band, round four.

The shipped band is decision 67's: the clock one key tall at top center, a
side either side of it as a name over a number, the two lines of a side
adding up to the clock's height. Chris's notes on it, a week in: the top
middle looks wonky, the time is big and the scores small, there is no one
idea behind it, and now that the players sheet carries the roster the band
is carrying less than it did. What he wants from the next one:

- the pilot's own rating on screen the whole time, so it can be watched
  going up and down;
- each zone's own facts: a clock where the match is timed, sides and
  scores where there are sides, flags where there are flags;
- not invasive, and good looking.

Four directions, each drawn for every zone and at the whistle on the
first sheet, then each on a monitor and an upright phone. Nothing here is
built.

The rooms are the ones every band mock has been judged against: Pylon
against Caisson at 17 to 20 in Team Battle with the viewer, DRiFT, on the
losing side; Keel against Vantage in Turf and Capture the Flag; DRiFT
against Carrack in the duel; thirty one pilots in Free Roam. The design
system is the client's: hues from client/arena/palette.lua, the row's
measures from ui.lua, the beacon the radar draws for a flag, the two faces
the client carries.

Rebuild with: python3 build.py
"""

import random
from pathlib import Path

HERE = Path(__file__).parent

FORMS = {
    "Desktop": (1440, 810),
    "Portrait": (390, 844),
}

# --- the palette, verbatim from client/arena/palette.lua ---------------------
BG = "#05070c"
INK = "#dfe9f5"
DIM = "#6c7a90"
READ = "#9fb6d4"
MUTE = "#8593a9"
FRIEND = "#4fd6ff"
ENEMY = "#ffa552"
TILE = "#3f5878"
PAID = "#8dffb0"
HURT = "#ff505a"
BOUNTY = "#ffe08a"
CHARGE = "#ffd166"
KEY_EDGE = "#55708f"

# --- the geography, from ui.lua ----------------------------------------------
PAD = 14
KEY_H = 26
KEY_GAP = 6
RADAR = 168
RADAR_COMPACT = 112
MONO_ADV = 0.602      # the mono's advance, as a share of its size


def adv(text, px):
    return len(text) * px * MONO_ADV


def radar_side(compact):
    return RADAR_COMPACT if compact else RADAR


def row_right(w, compact):
    """Where the top row ends: the dial's left edge, a gap short of it."""
    return w - PAD - radar_side(compact) - KEY_GAP


# --- the rooms ---------------------------------------------------------------


class Side:
    def __init__(self, name, col, score, mine, held=0, pilot=False,
                 rating=None):
        self.name, self.col, self.score, self.mine = name, col, score, mine
        self.held = held          # stands or flags this side holds
        self.pilot = pilot        # a side named by its pilot keeps its case
        self.rating = rating      # the rival's standing, in a duel


# The viewer: DRiFT, and what the room has done to their rating since they
# sat down, per zone.
ME = {
    "melee": (1494, -6),
    "turf": (1533, 9),
    "war": (1512, 4),
    "duel": (1471, -12),
    "roam": (1500, 0),
}

ROOMS = {
    "melee": dict(label="Team Battle", clock="2:14", stands=0, sides=[
        Side("Pylon", FRIEND, 17, True),
        Side("Caisson", ENEMY, 20, False)]),
    "turf": dict(label="Turf", clock="1:48", stands=6, sides=[
        Side("Keel", FRIEND, 34, True, held=3),
        Side("Vantage", ENEMY, 27, False, held=2)]),
    "war": dict(label="Capture the Flag", clock="3:12", stands=4, sides=[
        Side("Keel", FRIEND, 2, True, held=2),
        Side("Vantage", ENEMY, 1, False, held=1)]),
    "duel": dict(label="Duel", clock="1:37", stands=0, rounds=[0, 1, None],
                 sides=[
        Side("DRiFT", FRIEND, 1, True, pilot=True, rating=1471),
        Side("Carrack", ENEMY, 1, False, pilot=True, rating=1508)]),
    "roam": dict(label="Free Roam", clock=None, stands=0, flying=31,
                 pact="Anvil Watch", sides=[]),
}

ZONES = ["melee", "turf", "war", "duel", "roam"]

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
.name{{font-family:var(--mono);letter-spacing:.04em}}
.num{{font-family:var(--mono);font-variant-numeric:tabular-nums;line-height:1}}
.mono{{font-family:var(--mono)}}
.lbl{{font-family:var(--mono);font-size:10px;text-transform:uppercase;
  letter-spacing:.14em;color:var(--dim)}}
.row{{display:flex;align-items:center}}
.abs{{position:absolute}}
.glass{{border:1px solid rgba(63,88,120,.75);background:rgba(10,15,24,.72)}}
@keyframes breathe{{0%,100%{{opacity:.28}}50%{{opacity:.6}}}}
.breathe{{animation:breathe 2.4s ease-in-out infinite}}
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
        y = rnd.randint(60, h - 40)
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


def over_dial(w, compact):
    """The strip over the dial: POS at its left edge, the link bars flush
    against its right. Drawn on every board so the band has the end it
    has to stop short of."""
    side = radar_side(compact)
    x = w - PAD - side
    bars = "".join(
        f'<span style="width:4px;height:{3 + 2.6 * k:.1f}px;'
        f'background:{PAID};opacity:{.85 if k < 3 else .22}"></span>'
        for k in range(4))
    return (f'<div class="abs row" style="left:{x}px;top:{PAD}px;'
            f'width:{side}px;height:{KEY_H}px;justify-content:space-between">'
            f'<span class="hud" style="font-size:10px;color:{DIM}">Pos '
            f'<span class="num" style="color:{INK};opacity:.85">755,591</span>'
            f'</span><span class="row" style="gap:2px;align-items:flex-end">'
            f'{bars}</span></div>')


def radar(w, compact):
    side = radar_side(compact)
    x = w - PAD - side
    blips = "".join(
        f'<circle cx="{bx}" cy="{by}" r="2" fill="{col}"/>'
        for bx, by, col in ((side * .3, side * .35, ENEMY),
                            (side * .62, side * .58, ENEMY),
                            (side * .5, side * .5, FRIEND),
                            (side * .41, side * .72, FRIEND)))
    return over_dial(w, compact) + (
        f'<svg class="abs" width="{side}" height="{side}" '
        f'style="left:{x}px;top:{PAD + KEY_H}px">'
        f'<rect x="0" y="0" width="{side}" height="{side}" '
        f'fill="rgba(5,7,12,.55)"/>'
        f'<path d="M{side * .2} {side * .3} V{side * .8} M{side * .55} {side * .2} '
        f'H{side * .85}" stroke="{TILE}" stroke-width="3" opacity=".8"/>'
        f'{blips}</svg>')


def feed(w):
    lines = ["Carrack killed Ozone", "Gantry killed Isobar",
             "Cirrus killed DRiFT"]
    y = PAD + KEY_H + RADAR + 12
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
    return "".join([ring(80, h - 96, 54), ring(w - 64, h - 130, 26),
                    ring(w - 108, h - 78, 26)])


def menu_key(w, h):
    return (f'<div class="abs" style="left:50%;bottom:10px;'
            f'transform:translateX(-50%);display:flex;flex-direction:column;'
            f'align-items:center;gap:4px;opacity:.45">'
            f'<svg width="12" height="12" viewBox="0 0 12 12" fill="none" '
            f'stroke="{READ}" stroke-width="1.6"><path d="M0 2.2H12M0 6H12M0 9.8H12"/>'
            f'</svg><span class="hud" style="font-size:10px;color:{READ}">Menu'
            f'</span></div>')


# --- marks -------------------------------------------------------------------


def beacon(col, k=1.0, a=1.0):
    """The flag as the radar draws it (decision 149): a faint disc, a ring
    and a dot. The same mark on every band, so a flag looks like a flag
    wherever it is shown."""
    s = 10 * k
    return (f'<svg width="{s:.0f}" height="{s:.0f}" viewBox="-5 -5 10 10" '
            f'style="flex:none;opacity:{a}">'
            f'<circle r="4.4" fill="{col}" opacity=".16"/>'
            f'<circle r="3.1" fill="none" stroke="{col}" stroke-width=".9" '
            f'opacity=".9"/><circle r="1.3" fill="{col}"/></svg>')


def beacons(room, k=1.0, gap=4):
    """Every stand or flag in the room, held ones in the holder's color and
    the loose ones dim, so the strip says how much of the ground is up
    for grabs."""
    n = room["stands"]
    if not n:
        return ""
    out = []
    for s in room["sides"]:
        out += [beacon(s.col, k) for _ in range(s.held)]
    loose = n - sum(s.held for s in room["sides"])
    out += [beacon(DIM, k, .7) for _ in range(loose)]
    return f'<span class="row" style="gap:{gap}px">{"".join(out)}</span>'


def pips(side, k=1.0, gap=3, reverse=False):
    """A duel's rounds: first to two, so two pips a side, filled for a
    round taken."""
    out = []
    for i in range(2):
        won = i < side.score
        out.append(
            f'<svg width="{8 * k:.0f}" height="{8 * k:.0f}" viewBox="-4 -4 8 8" '
            f'style="flex:none"><circle r="3.1" fill="{side.col if won else "none"}" '
            f'stroke="{side.col}" stroke-width="1" opacity="{1 if won else .55}"/>'
            '</svg>')
    if reverse:
        out.reverse()
    return f'<span class="row" style="gap:{gap}px">{"".join(out)}</span>'


def signed(n, px, dim=1.0):
    """A rating's movement, signed both ways: green up, red down, and a
    zero in the dim, as the players sheet and the wreck float draw it."""
    col = PAID if n > 0 else HURT if n < 0 else DIM
    return (f'<span class="num" style="font-size:{px}px;color:{col};'
            f'opacity:{dim}">({n:+d})</span>')


def rating(zone, px=13, caption=True, dim=1.0, align="left", cap_px=None):
    """The viewer's standing in this zone, and what the room has done to it
    since they sat down. The standing in ink, since no rating is good or
    bad; only the movement takes a color."""
    at, moved = ME[zone]
    cap = (f'<span class="hud" style="font-size:{cap_px or px - 3}px;'
           f'color:{DIM}">Rating</span>' if caption else "")
    return (f'<span class="row" style="gap:{6 if caption else 4}px;'
            f'justify-content:{"flex-end" if align == "right" else "flex-start"}">'
            f'{cap}<span class="num" style="font-size:{px}px;color:{INK};'
            f'opacity:{.9 * dim}">{at}</span>{signed(moved, px, dim)}</span>')


def stood(room, s, state, down=True):
    """What the whistle does to a side: the one that took it keeps its
    ink, the other stands down to a third. A draw stands neither down.

    The scoreline passes `down=False` and stands neither of them down.
    The two scores say who won, which is what a score is for, and a
    figure read through an alpha is a figure the interface is
    editorializing about. The three shapes on the second page were drawn
    before that and keep it, since they are the record of a first pass."""
    if state != "end" or not down:
        return 1
    best = max(x.score for x in room["sides"])
    return .35 if s.score < best else 1


def label(s, px, dim=1.0):
    """A side's name: a team's is a label in the instrument's case, a
    pilot's is quoted and keeps its own."""
    cls = "name" if s.pilot else "hud"
    return (f'<span class="{cls}" style="font-size:{px}px;color:{s.col};'
            f'opacity:{.85 * dim};white-space:nowrap">{s.name}</span>')


def clock_text(room, state):
    return "0:12" if state == "end" else room["clock"]


def next_match(x_css, y, px=10):
    return (f'<div class="abs hud" style="{x_css};top:{y}px;font-size:{px}px;'
            f'color:{DIM};white-space:nowrap">Next match in</div>')


# --- the shipped band, for the record ----------------------------------------


def band_shipped(w, room, zone, compact, state="open"):
    """Decision 67's band as it is on main: the clock one key tall at
    top center, a side either side as a 9 point name over a 14 point
    number. No rating anywhere on the HUD."""
    top = PAD
    name_px, gap = 9, 3
    under_px = KEY_H - name_px - gap
    side_gap = 14 if compact else 22
    out = []
    if room["clock"] is None:
        return ""
    clock = clock_text(room, state)
    half = adv(clock, KEY_H) / 2
    out.append(
        f'<div class="abs num" style="left:50%;top:{top}px;'
        f'transform:translateX(-50%);font-size:{KEY_H}px;line-height:{KEY_H}px;'
        f'color:{INK};opacity:.95">{clock}</div>')
    if state == "end":
        out.append(next_match("left:50%;transform:translateX(-50%)",
                              top + KEY_H + 8, 9 if compact else 11))
    for i, s in enumerate(room["sides"]):
        dim = stood(room, s, state)
        edge = w / 2 - half - side_gap if i == 0 else w / 2 + half + side_gap
        align = "flex-end" if i == 0 else "flex-start"
        pos = (f"right:{w - edge:.0f}px" if i == 0 else f"left:{edge:.0f}px")
        name = "" if compact else label(s, name_px, dim)
        out.append(
            f'<div class="abs" style="{pos};top:{top}px;height:{KEY_H}px;'
            f'display:flex;flex-direction:column;align-items:{align};'
            f'justify-content:space-between">{name}'
            f'<span class="num" style="font-size:{under_px}px;'
            f'color:{s.col};opacity:{dim}">{s.score}</span></div>')
    if room["stands"] and state != "end":
        out.append(f'<div class="abs row" style="left:50%;top:{top + KEY_H + 9}px;'
                   f'transform:translateX(-50%)">{beacons(room, 1.0, 6)}</div>')
    return "".join(out)


# --- A. the scoreline --------------------------------------------------------


def band_scoreline(w, room, zone, compact, state="open", px=13):
    """One line at top center, everything on it one size: the HUD's own
    13 point body, which POS and the feed are already set in. A side is
    its score and its name, the clock stands between them in the reading
    ink, and the rating is a readout in the top left, the twin of POS in
    the top right, at the same size again. What tells a score from a
    name from the clock is color and order, not weight: a side's two
    words wear its color, the clock is the reading ink, the rating is
    ink with its movement colored. Flags hang under the clock as beacons,
    and a duel, being one kill, is its two pilots either side of the clock
    with no score at all."""
    top = PAD
    gap = 12 if compact else 16
    line = (f'top:{top}px;height:{KEY_H}px;display:flex;align-items:center;'
            f'position:absolute')
    out = [rating_readout(zone, compact, px)]
    # A room that runs forever has no clock and no score, and nothing moves in
    # to fill the gap: the middle of the row is empty and the top edge of that
    # zone is the fight's.
    if room["clock"] is None:
        return "".join(out)
    clock = clock_text(room, state)
    ended = state == "end"
    # At the whistle the line under the clock says what it is counting to,
    # at the row's own size. That line is the flags' during the match and
    # the flags are not drawn at the whistle, so it is free exactly then;
    # the row keeps its shape and nothing on it moves. Inline it was 18
    # characters wide and ran into the dial's strip on an upright phone.
    middle = (f'<span class="num" style="font-size:{px}px;color:{READ};'
              f'opacity:.95">{clock}</span>')
    mid_w = adv(clock, px)
    # And not on a window held upright, where the dial leaves the line under
    # the clock no room for it. The clock it captions is on the row above,
    # counting, and the sheet the whistle raises says the match is done.
    if ended and not compact:
        out.append(
            f'<div class="abs hud" style="left:50%;top:{top + KEY_H + 4}px;'
            f'transform:translateX(-50%);font-size:{px}px;color:{DIM};'
            f'white-space:nowrap">Next match in</div>')
    out.append(
        f'<div class="row" style="{line};left:50%;transform:translateX(-50%);'
        f'gap:8px">{middle}</div>')
    half = mid_w / 2
    duel = zone == "duel"
    for i, s in enumerate(room["sides"]):
        dim = stood(room, s, state, down=False)
        edge = w / 2 - half - gap if i == 0 else w / 2 + half + gap
        pos = (f"right:{w - edge:.0f}px" if i == 0 else f"left:{edge:.0f}px")
        # A phone has no room for a team's name, and so has any window where
        # the name would run into the rating on the left or the dial's strip
        # on the right: the name drops and the figure always draws, which is
        # the shipped band's rule. A duel's sides are its pilots, and a pip
        # with no name is nobody, so a duel keeps them.
        room_l = edge - (PAD + adv("Rating 1494 (-6)", px) + gap)
        room_r = row_right(w, compact) - edge
        fits = adv(s.name, px) + 8 + adv(str(s.score), px) <= (
            room_l if i == 0 else room_r)
        name = "" if ((compact or not fits) and not duel) else label(s, px, dim)
        # A duel is one kill (decision 146), so there is no score to show
        # until it is over: the row is the two pilots and the clock.
        figure = "" if duel else (
            f'<span class="num" style="font-size:{px}px;'
            f'color:{s.col};opacity:{dim}">{s.score}</span>')
        bits = [figure, name] if i == 0 else [name, figure]
        bits = [x for x in bits if x]
        out.append(f'<div class="row" style="{line};{pos};gap:8px">'
                   f'{"".join(bits)}</div>')
    if room["stands"] and not ended:
        out.append(f'<div class="abs row" style="left:50%;top:{top + KEY_H + 4}px;'
                   f'transform:translateX(-50%)">{beacons(room, .9, 3)}</div>')
    return "".join(out)


def rating_readout(zone, compact, px=13):
    """The top left corner: your standing, the way POS is the top right,
    and at the same size as everything else on the row. A phone drops
    the caption the way it drops the sides' names."""
    return (f'<div class="abs row" style="left:{PAD}px;top:{PAD}px;'
            f'height:{KEY_H}px">'
            f'{rating(zone, px, caption=not compact, cap_px=px)}</div>')


# --- B. the corners ----------------------------------------------------------


def band_corners(w, room, zone, compact, state="open"):
    """Your side in the top left corner, theirs against the dial, the
    clock alone between them. A corner is a stack the way the bottom
    left is: the side's name, its score at 30 points, and under yours
    your rating; under theirs, in a duel, the rival's. Flags stand under
    the clock, on the ground between the two of you."""
    top = PAD
    score_px = 26 if compact else 30
    name_px = 10
    clock_px = 14 if compact else 15
    out = []
    # A block against the dial wants more air than the band does, since
    # POS stands on the dial's own edge and two readouts six points apart
    # read as one.
    right = row_right(w, compact) - (8 if compact else 18)
    if room["clock"] is None:
        left_block = (
            f'<div class="abs" style="left:{PAD}px;top:{top}px;display:flex;'
            f'flex-direction:column;gap:5px">'
            f'<span class="hud" style="font-size:{name_px}px;color:{FRIEND};'
            f'opacity:.85">{room["pact"]}</span>{rating(zone, 12, False)}</div>')
        mid = (PAD + 90 + right) / 2
        return left_block + (
            f'<div class="abs hud" style="left:{mid:.0f}px;top:{top}px;'
            f'height:{KEY_H}px;transform:translateX(-50%);display:flex;'
            f'align-items:center;font-size:{clock_px}px;color:{INK};opacity:.9;'
            f'white-space:nowrap"><span class="num">{room["flying"]}</span>'
            f'&nbsp;flying</div>')
    duel = zone == "duel"
    widths = []
    for i, s in enumerate(room["sides"]):
        dim = stood(room, s, state)
        mine = i == 0
        align = "flex-start" if mine else "flex-end"
        pos = f"left:{PAD}px" if mine else f"right:{w - right:.0f}px"
        if duel:
            figure = (f'<span style="padding:6px 0 4px">'
                      f'{pips(s, 1.5, 4, reverse=not mine)}</span>')
        else:
            figure = (f'<span class="num" style="font-size:{score_px}px;'
                      f'color:{s.col};opacity:{dim}">{s.score}</span>')
        under = ""
        if mine:
            under = rating(zone, 11, False, dim, "left")
        elif duel and s.rating is not None:
            under = (f'<span class="num" style="font-size:11px;color:{INK};'
                     f'opacity:{.7 * dim}">{s.rating}</span>')
        out.append(
            f'<div class="abs" style="{pos};top:{top}px;display:flex;'
            f'flex-direction:column;align-items:{align};gap:3px">'
            f'{label(s, name_px, dim)}{figure}{under}</div>')
        widths.append(max(adv(s.name, name_px), adv(str(s.score), score_px),
                          70 if (mine or duel) else 0))
    # The clock stands between the two blocks, which on a monitor is
    # near enough the middle of the window and on a phone is not.
    mid = (PAD + widths[0] + right - widths[1]) / 2
    clock = clock_text(room, state)
    out.append(
        f'<div class="abs num" style="left:{mid:.0f}px;top:{top}px;'
        f'height:{KEY_H}px;transform:translateX(-50%);display:flex;'
        f'align-items:center;font-size:{clock_px}px;color:{READ};'
        f'opacity:.95">{clock}</div>')
    if state == "end":
        out.append(next_match(f"left:{mid:.0f}px;transform:translateX(-50%)",
                              top + KEY_H + 4, 9 if compact else 10))
    elif room["stands"]:
        out.append(f'<div class="abs row" style="left:{mid:.0f}px;'
                   f'top:{top + KEY_H + 4}px;transform:translateX(-50%)">'
                   f'{beacons(room, .9, 3)}</div>')
    return "".join(out)


# --- C. the bar --------------------------------------------------------------


def band_bar(w, room, zone, compact, state="open"):
    """A bar at top center, filled from each end in the sides' colors in
    the share of the score each has, the scores at its ends and the
    clock over it. In a flag game the bar is the long axis of the map
    and the stands sit on it as beacons, colored by who holds them. In a
    duel the bar is the match in rounds, a segment a round, the one in
    play breathing. Your rating sits under your end."""
    top = PAD
    bar_w = 150 if compact else 300
    bar_h = 3
    score_px = 18 if compact else 20
    clock_px = 12 if compact else 13
    name_px = 9
    right = row_right(w, compact)
    # Centered on the window, unless that runs its far score into the
    # dial's strip, in which case it is centered between the margins the
    # way every band on a phone is.
    cx = w / 2
    if cx + bar_w / 2 + 9 + adv("20", score_px) + 8 > right:
        cx = (PAD + right) / 2
    out = []
    if room["clock"] is None:
        return (
            f'<div class="abs" style="left:{cx:.0f}px;top:{top}px;'
            f'transform:translateX(-50%);display:flex;flex-direction:column;'
            f'align-items:center;gap:5px">'
            f'<span class="hud" style="font-size:{clock_px + 1}px;color:{INK};'
            f'opacity:.9;white-space:nowrap"><span class="num">'
            f'{room["flying"]}</span>&nbsp;flying</span>'
            f'{rating(zone, 11, False)}</div>')
    clock = clock_text(room, state)
    bar_y = top + clock_px + 5
    x0 = cx - bar_w / 2
    duel = zone == "duel"
    ended = state == "end"
    # The clock over the bar, and at the whistle what it is counting to.
    if ended:
        out.append(
            f'<div class="abs row" style="left:{cx:.0f}px;top:{top}px;'
            f'transform:translateX(-50%);gap:6px;height:{clock_px}px">'
            f'<span class="hud" style="font-size:{name_px}px;color:{DIM};'
            f'white-space:nowrap">Next match in</span>'
            f'<span class="num" style="font-size:{clock_px}px;color:{READ}">'
            f'{clock}</span></div>')
    else:
        out.append(
            f'<div class="abs num" style="left:{cx:.0f}px;top:{top}px;'
            f'transform:translateX(-50%);font-size:{clock_px}px;color:{READ};'
            f'opacity:.95">{clock}</div>')
    # The track, then the fills.
    out.append(f'<div class="abs" style="left:{x0:.0f}px;top:{bar_y}px;'
               f'width:{bar_w}px;height:{bar_h}px;background:{TILE};'
               f'opacity:.45"></div>')
    a, b = room["sides"]
    if duel:
        n = len(room["rounds"])
        seg = (bar_w - 2 * (n - 1)) / n
        for i, taker in enumerate(room["rounds"]):
            sx = x0 + i * (seg + 2)
            if taker is None:
                cls = ' class="abs breathe"' if not ended else ' class="abs"'
                col, op = INK, .28
            else:
                s = room["sides"][taker]
                cls = ' class="abs"'
                col, op = s.col, stood(room, s, state)
            out.append(f'<div{cls} style="left:{sx:.1f}px;top:{bar_y}px;'
                       f'width:{seg:.1f}px;height:{bar_h}px;background:{col};'
                       f'opacity:{op}"></div>')
    else:
        total = a.score + b.score
        if total:
            fa = bar_w * a.score / total
            out.append(f'<div class="abs" style="left:{x0:.0f}px;top:{bar_y}px;'
                       f'width:{fa - 1:.1f}px;height:{bar_h}px;'
                       f'background:{a.col};opacity:{stood(room, a, state)}"></div>')
            out.append(f'<div class="abs" style="left:{x0 + fa + 1:.1f}px;'
                       f'top:{bar_y}px;width:{bar_w - fa - 1:.1f}px;'
                       f'height:{bar_h}px;background:{b.col};'
                       f'opacity:{stood(room, b, state)}"></div>')
    # The stands on the axis.
    if room["stands"] and not ended:
        n = room["stands"]
        holders = ([a.col] * a.held + [DIM] * (n - a.held - b.held)
                   + [b.col] * b.held)
        for i, col in enumerate(holders):
            bx = x0 + bar_w * (i + .5) / n
            out.append(
                f'<div class="abs" style="left:{bx - 6:.1f}px;'
                f'top:{bar_y + bar_h / 2 - 6:.1f}px;width:12px;height:12px;'
                f'border-radius:50%;background:{BG};display:flex;'
                f'align-items:center;justify-content:center">'
                f'{beacon(col, 1.0, .7 if col == DIM else 1)}</div>')
    # The scores at the ends, the names under the ends, the rating under
    # your score.
    for i, s in enumerate(room["sides"]):
        dim = stood(room, s, state)
        mine = i == 0
        if duel:
            figure = pips(s, 1.3, 3, reverse=mine)
        else:
            figure = (f'<span class="num" style="font-size:{score_px}px;'
                      f'color:{s.col};opacity:{dim}">{s.score}</span>')
        pos = (f"right:{w - x0 + 9:.0f}px" if mine
               else f"left:{x0 + bar_w + 9:.0f}px")
        out.append(
            f'<div class="abs row" style="{pos};top:{bar_y + bar_h / 2:.1f}px;'
            f'transform:translateY(-50%)">{figure}</div>')
        npos = f"left:{x0:.0f}px" if mine else f"right:{w - x0 - bar_w:.0f}px"
        if not (compact and not duel and not mine):
            out.append(
                f'<div class="abs row" style="{npos};top:{bar_y + bar_h + 5}px;'
                f'gap:8px">{label(s, name_px, dim)}'
                f'{rating(zone, name_px + 1, False, dim) if mine else ""}</div>')
    return "".join(out)


# --- D. the tally ------------------------------------------------------------


def band_tally(w, room, zone, compact, state="open"):
    """A stack in the top left, the way a broadcast scores a match in
    its corner: the clock, then a line a side with its score, its name
    and the flags it holds, then your rating. Rows of marks and counts
    with no panel, which is the model the bottom left corner already
    follows. The top middle is the fight's."""
    top = PAD
    pitch = 15
    clock_px = 15
    score_px = 14
    name_px = 10
    lines = []
    if room["clock"] is None:
        lines.append(
            f'<span class="hud" style="font-size:12px;color:{INK};opacity:.9">'
            f'<span class="num">{room["flying"]}</span>&nbsp;flying</span>')
    else:
        clock = clock_text(room, state)
        if state == "end":
            lines.append(
                f'<span class="row" style="gap:6px">'
                f'<span class="hud" style="font-size:9px;color:{DIM}">'
                f'Next match in</span><span class="num" style="font-size:'
                f'{clock_px}px;color:{INK};opacity:.95">{clock}</span></span>')
        else:
            lines.append(f'<span class="num" style="font-size:{clock_px}px;'
                         f'color:{INK};opacity:.95">{clock}</span>')
        duel = zone == "duel"
        for s in room["sides"]:
            dim = stood(room, s, state)
            if duel:
                figure = f'<span class="row" style="width:26px">{pips(s, 1.0)}</span>'
            else:
                figure = (f'<span class="num" style="font-size:{score_px}px;'
                          f'color:{s.col};width:26px">{s.score}</span>')
            held = ""
            if room["stands"] and state != "end" and s.held:
                held = (f'<span class="row" style="gap:2px;margin-left:2px">'
                        + "".join(beacon(s.col, .8) for _ in range(s.held))
                        + '</span>')
            lines.append(
                f'<span class="row" style="gap:6px;opacity:{dim}">{figure}'
                f'{label(s, name_px)}{held}</span>')
        if room["stands"] and state != "end":
            loose = room["stands"] - sum(s.held for s in room["sides"])
            if loose:
                lines.append(
                    f'<span class="row" style="gap:6px">'
                    f'<span style="width:26px"></span>'
                    f'<span class="row" style="gap:2px">'
                    + "".join(beacon(DIM, .8, .7) for _ in range(loose))
                    + f'</span><span class="hud" style="font-size:9px;'
                    f'color:{DIM}">loose</span></span>')
    lines.append(f'<span style="margin-top:3px">{rating(zone, 11)}</span>')
    rows = "".join(f'<span class="row" style="height:{pitch}px">{l}</span>'
                   for l in lines)
    return (f'<div class="abs" style="left:{PAD}px;top:{top}px;display:flex;'
            f'flex-direction:column;gap:1px">{rows}</div>')


BANDS = {
    "Shipped": band_shipped,
    "Scoreline": band_scoreline,
    "Corners": band_corners,
    "Bar": band_bar,
    "Tally": band_tally,
}


# --- the boards --------------------------------------------------------------


def screen(form, band, zone, state="open", seed=1):
    w, h = FORMS[form]
    compact = form == "Portrait"
    room = ROOMS[zone]
    out = [scene(w, h, 11 + w, compact), radar(w, compact)]
    if compact:
        out.append(pads(w, h))
    else:
        out.append(feed(w))
        out.append(corner_stack(h))
    out.append(BANDS[band](w, room, zone, compact, state))
    out.append(menu_key(w, h))
    return (f'<div style="position:relative;width:{w}px;height:{h}px;'
            f'overflow:hidden;background-color:{BG};'
            f'background-image:{starfield(w, h, seed + w)}">{"".join(out)}</div>')


STRIP_W, STRIP_H = 720, 84


def strip(band, zone, state="open", w=STRIP_W, h=STRIP_H, compact=False,
          px=None):
    """The top of a window and nothing else: the row, the strip over the
    dial and the top edge of the dial, so a band is judged against the
    end it stops at."""
    room = ROOMS[zone]
    fn = BANDS[band]
    drawn = (fn(w, room, zone, compact, state, px) if px
             else fn(w, room, zone, compact, state))
    inner = radar(w, compact) + drawn
    return (f'<div style="position:relative;width:{w}px;height:{h}px;'
            f'overflow:hidden;background-color:{BG};flex:none;'
            f'background-image:{starfield(w, h, 3 + hash(band + zone) % 97)}">'
            f'{inner}</div>')


# --- the sheets --------------------------------------------------------------


def cap(text, w=None, px=13):
    return (f'<div style="font-size:{px}px;line-height:{px + 6}px;color:{READ};'
            f'{"width:" + str(w) + "px;" if w else ""}text-wrap:pretty">'
            f'{text}</div>')


def title(text):
    return (f'<div class="lbl" style="font-size:11px;letter-spacing:.16em;'
            f'margin-bottom:10px">{text}</div>')


def h1(text):
    return (f'<div style="font-size:26px;line-height:32px;color:{INK}">'
            f'{text}</div>')


def h2(text):
    return (f'<div style="font-size:21px;line-height:26px;color:{INK}">'
            f'{text}</div>')


STATES = [("melee", "open", "Team Battle: kills"),
          ("turf", "open", "Turf: points and six stands"),
          ("war", "open", "Capture the Flag: rounds and four flags"),
          ("duel", "open", "Duel: one kill, two pilots, no score"),
          ("roam", "open", "Free Roam: no clock, no score, no middle"),
          ("melee", "end", "At the whistle: Caisson took it")]

DIRECTIONS = [
    ("Scoreline", "A · The scoreline",
     "One line at top center, the score leading it. A side is its score at 22 "
     "points with its name at 10 beside it, and the clock stands between them "
     "at 15 in the reading ink, so the two numbers that change every few "
     "seconds are the big ones and the one that only counts down is not. "
     "Flags hang under the clock as beacons, the mark the radar already draws "
     "for one; a duel's rounds are pips in place of numbers. The rating is a "
     "readout in the top left, the twin of POS in the top right: caption, "
     "standing, movement. The least change of the four: the same place, the "
     "same growth outward from the clock, the sizes put the right way up.",
     "Costs: the top left is no longer empty, and a phone still drops the "
     "names."),
    ("Corners", "B · The corners",
     "You in the top left, them against the dial, the clock alone in the "
     "middle. Each corner is a stack the way the bottom left already is: the "
     "side's name, its score at 30, and a line under it. Under yours, your "
     "rating. Under theirs, in a duel, the rival's, which is the one match "
     "where their standing is the point. Flags stand under the clock, on the "
     "ground between the two of you, and the middle of the top edge holds a "
     "small clock and nothing else.",
     "Costs: the two scores are far apart, so a glance reads one; on a phone "
     "the clock is centered between the blocks rather than on the window."),
    ("Bar", "C · The bar",
     "The score as a shape. A three point bar at top center fills from each "
     "end in the sides' colors in the share each has of the score, the "
     "figures at its ends and the clock over it. In a flag game the bar is "
     "the long axis of the map, which is where the stands are, and they sit on "
     "it as beacons colored by who holds them. In a duel the bar is the match "
     "in rounds, a segment a round, the one in play breathing. Your rating "
     "sits under your end, beside your side's name.",
     "Costs: the tallest of the four, three lines against one; and the fill "
     "moves in steps in a kill game, where a point is one twentieth of it."),
    ("Tally", "D · The tally",
     "A stack in the top left corner, the way a broadcast keeps score: the "
     "clock, then a line a side with its score, its name and the flags it "
     "holds, then your rating under a caption. Rows of marks and counts with "
     "no panel and no rules, which is what the corner stack at the bottom "
     "left is made of, so the two corners are one instrument read twice. The "
     "top middle is the fight's, all of it.",
     "Costs: the score is not the first thing a stranger sees, and this is the "
     "corner shape drawn once already, kept here because the rating gives it "
     "a fourth row it did not have."),
]


def scoreline_sheet():
    body = [
        title("The scoreboard band · round four · the pick"),
        h1("The scoreline, at one size"),
        cap("Chris picked A and asked for one thing changed: nothing on the "
            "row varies in size. The first draft set the scores at 22, the "
            "clock at 15 and the names at 10; here every figure and every "
            "word on the row is 13 points, which is the HUD's own body size "
            "and what POS and the feed are already set in. What tells a score "
            "from a name from the clock is color and order rather than weight: "
            "a side's two words wear its color, the clock is the reading ink, "
            "the rating is ink with its movement colored. The row is one key "
            "tall as before and the band still grows outward from the clock "
            "and stops short of the dial; a phone drops the names and the "
            "rating's caption, and the figures always draw. Flags hang under "
            "the clock as the radar's beacon; a duel is one kill, so its row is "
            "the two pilots either side of the clock and no score; a room "
            "that runs forever has no middle at all; and at the whistle both "
            "sides stay at their own strength, with the line under the clock, "
            "the flags' line during the match, saying what it is counting to "
            "at the same size. That caption is a monitor's: on a phone the "
            "dial leaves the line under the clock no room for it.",
            900),
        f'<div style="height:22px"></div>',
        title("Every zone, and the whistle"),
    ]
    cells = "".join(
        f'<div style="display:flex;flex-direction:column;gap:6px">'
        f'{strip("Scoreline", zone, state)}'
        f'<span class="lbl" style="letter-spacing:.1em">{note}</span></div>'
        for zone, state, note in STATES)
    body.append(
        f'<div style="display:grid;grid-template-columns:repeat(2, minmax(0, 1fr));'
        f'gap:14px 16px;width:{2 * STRIP_W + 16}px">{cells}</div>')
    body += [
        f'<div style="height:34px"></div>',
        title("The one size, tried at three"),
        cap("13 is the body. 12 is the caption size the row's neighbors use "
            "for POS, and 14 is one up. Turf, because it has the most on the "
            "row.", 900),
        f'<div style="height:12px"></div>',
    ]
    cells = "".join(
        f'<div style="display:flex;flex-direction:column;gap:6px">'
        f'{strip("Scoreline", "turf", px=px)}'
        f'<span class="lbl" style="letter-spacing:.1em">{px} points'
        f'{" · the boards" if px == 13 else ""}</span></div>'
        for px in (12, 13, 14))
    body.append(
        f'<div style="display:grid;grid-template-columns:repeat(2, minmax(0, 1fr));'
        f'gap:14px 16px;width:{2 * STRIP_W + 16}px">{cells}</div>')
    body += [
        f'<div style="height:34px"></div>',
        title("As shipped, for the record"),
        f'<div style="display:flex;gap:16px;align-items:flex-start">'
        f'{strip("Shipped", "melee")}{strip("Shipped", "turf")}</div>',
        cap("Decision 67's band on main today: the clock at 26, each score at "
            "14, the names at 9, and no rating anywhere on the HUD.", 900),
    ]
    return (f'<div style="padding:40px 48px 56px;width:{2 * STRIP_W + 16 + 96}px;'
            f'background:{BG};display:flex;flex-direction:column;gap:2px">'
            f'{"".join(body)}</div>')


def directions_sheet():
    body = [
        title("The scoreboard band · round four · the first pass"),
        h1("Four shapes for the top of the window"),
        cap("The first pass, kept for the record. Chris picked A, the "
            "scoreline, and asked for it at one size; that is the first page. "
            "The scoreline drawn here is the draft he picked from, with its "
            "scores at 22, clock at 15 and names at 10.", 900),
        f'<div style="height:14px"></div>',
        cap("The shipped band is decision 67's: the clock one key tall at top "
            "center, a side either side of it as a 9 point name over a 14 point "
            "number. What is wrong with it, a week in: the middle looks wonky, "
            "the time is big and the scores are small, and there is no one idea "
            "holding it together. Now that the players sheet carries the "
            "roster, the band is carrying less than it did. Each direction "
            "below is drawn for every zone and at the whistle, at 720 points "
            "wide with the dial's strip at the right end so the band is judged "
            "against the end it has to stop at. Every one of them puts the "
            "pilot's own rating on screen for the whole match, as the standing "
            "in ink and the movement since they sat down in brackets, green up "
            "and red down, which is the form the players sheet already uses.",
            900),
        f'<div style="height:22px"></div>',
        title("As shipped, for the record"),
        f'<div style="display:flex;gap:16px;align-items:flex-start">'
        f'{strip("Shipped", "melee")}{strip("Shipped", "turf")}</div>',
        cap("Team Battle and Turf on main today. The clock is 26 points and "
            "each score 14; no rating anywhere on the HUD.", 900),
    ]
    for key, head, text, cost in DIRECTIONS:
        cells = "".join(
            f'<div style="display:flex;flex-direction:column;gap:6px">'
            f'{strip(key, zone, state)}'
            f'<span class="lbl" style="letter-spacing:.1em">{note}</span></div>'
            for zone, state, note in STATES)
        body += [
            f'<div style="height:34px"></div>',
            h2(head),
            f'<div style="height:6px"></div>',
            cap(text, 900),
            f'<div style="height:4px"></div>',
            cap(cost, 900, 12),
            f'<div style="height:12px"></div>',
            f'<div style="display:grid;grid-template-columns:repeat(2, minmax(0, 1fr));'
            f'gap:14px 16px;width:{2 * STRIP_W + 16}px">{cells}</div>',
        ]
    body += [
        f'<div style="height:34px"></div>',
        h2("What every one of them shares"),
        f'<div style="height:6px"></div>',
        cap("The clock is smaller than the score in all four, and it goes to "
            "the warning color under thirty seconds rather than growing. The "
            "rating is your own standing in this zone and reads the same "
            "wherever it stands: figures in ink, movement in brackets, green up "
            "and red down and dim at zero. A side's name is a label in the "
            "instrument's case; a pilot's, in the duel, keeps its own. A flag is "
            "the beacon the radar draws for one, held ones in the holder's color "
            "and loose ones dim. A duel's rounds are two pips a side, filled "
            "when taken. At the whistle the side that took it keeps its ink and "
            "the other stands down to a third, over the clock counting to the "
            "next match. Free Roam has no clock and no score, so its band is the "
            "room's count and your rating. The band is still the press that "
            "opens the players sheet, in every shape.", 900),
    ]
    return (f'<div style="padding:40px 48px 56px;width:{2 * STRIP_W + 16 + 96}px;'
            f'background:{BG};display:flex;flex-direction:column;gap:2px">'
            f'{"".join(body)}</div>')


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
    boards = {"Main": scoreline_sheet(),
              "Directions": directions_sheet(),
              "Shipped": screen("Desktop", "Shipped", "melee")}
    for key, *_ in DIRECTIONS:
        boards[f"{key}Desktop"] = screen("Desktop", key, "melee")
        boards[f"{key}Turf"] = screen("Desktop", key, "turf")
        boards[f"{key}Duel"] = screen("Desktop", key, "duel")
        boards[f"{key}End"] = screen("Desktop", key, "melee", "end")
        boards[f"{key}Portrait"] = screen("Portrait", key, "melee")
        boards[f"{key}PortraitTurf"] = screen("Portrait", key, "turf")
    boards["ScorelinePortraitEnd"] = screen("Portrait", "Scoreline", "melee",
                                            "end")
    for name, body in boards.items():
        page(name, body)
    canvas(boards)
    print(f"{len(boards)} artboards written")


def canvas(boards):
    """Where each board sits on the canvas: the pick first, the scoreline
    at one size across every zone with its monitors down the left and
    its phones to the right; then the first pass's four directions for
    the record, a page each after the sheet that compares them."""
    pages = [{"id": "page-1", "name": "The scoreline"},
             {"id": "page-2", "name": "The four, first pass"}]
    arts = [
        dict(file="Main.dc.html", title="The scoreline at one size, every zone",
             x=0, y=0, w=2 * STRIP_W + 16 + 96, h=1180, page="page-1"),
        dict(file="Directions.dc.html", title="Four shapes, every zone",
             x=0, y=0, w=2 * STRIP_W + 16 + 96, h=2960, page="page-2"),
        dict(file="Shipped.dc.html", title="As shipped: Team Battle, monitor",
             x=1640, y=0, w=1440, h=810, page="page-2"),
    ]
    col = [("Desktop", "Team Battle, monitor"), ("Turf", "Turf, monitor"),
           ("Duel", "Duel, monitor"), ("End", "At the whistle, monitor")]

    def boards_of(key, pid, x0, y0):
        for i, (suffix, t) in enumerate(col):
            arts.append(dict(file=f"{key}{suffix}.dc.html", title=t, x=x0,
                             y=y0 + i * 930, w=1440, h=810, page=pid))
        arts.append(dict(file=f"{key}Portrait.dc.html",
                         title="Team Battle, phone", x=x0 + 1540, y=y0,
                         w=390, h=844, page=pid))
        arts.append(dict(file=f"{key}PortraitTurf.dc.html",
                         title="Turf, phone", x=x0 + 2030, y=y0, w=390,
                         h=844, page=pid))

    boards_of("Scoreline", "page-1", 0, 1320)
    arts.append(dict(file="ScorelinePortraitEnd.dc.html",
                     title="At the whistle, phone", x=2520, y=1320, w=390,
                     h=844, page="page-1"))
    for n, (key, head, *_) in enumerate(DIRECTIONS[1:], start=3):
        pid = f"page-{n}"
        pages.append({"id": pid, "name": head.replace(" · ", ": ")})
        boards_of(key, pid, 0, 0)
    listed = {a["file"] for a in arts}
    assert listed == {f"{n}.dc.html" for n in boards}, listed ^ {
        f"{n}.dc.html" for n in boards}
    import json
    (HERE / "canvas.json").write_text(json.dumps(
        {"pages": pages, "artboards": arts,
         "launch": {"view": "canvas", "page": "page-1"}}, indent=2) + "\n")


if __name__ == "__main__":
    main()
