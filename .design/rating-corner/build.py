#!/usr/bin/env python3
"""Assemble the artboards for the row's rating corner.

Decision 163 put your own standing at the near end of the top row as
`RATING 1228 (0)`: a caption in the dim, the figure in ink, and what the
match has done to it in brackets. Chris's call on it, the day after: the
corner is the figure and a badge, nothing else. The badge is the pilot's
wings, the mark the players sheet draws beside a human seat, and it wears
a color a tier: five tiers, five colors.

So the caption goes, and so does the bracket, in every zone. What a death
did to the rating is still said where it happens, on the wreck and at the
end of the feed's line (decisions 152 and 155), and the players sheet
still carries the movement in its column. The corner says where you stand
and what band that is, and it says the band as a color rather than a word,
which is one mark beside one figure and reads the same on a phone.

The badge is `pilot_mark` from client/arena/ui.lua, ported quad for quad:
the Apex hull in three pieces and the six feathers `wing_cut` cuts. The
rest of the chrome is `../scoreboard-band/build.py`'s.

Rebuild with: python3 build.py
"""

import json
import math
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
GREEN = "#5be08a"
CHARGE = "#ffd166"
BURST = "#c27bff"
BOMB = "#ff5ea8"
DOOR = "#35e0a0"
HOLE = "#a06bff"
RUNG3 = "#ff7000"
RUNG4 = "#f42e3d"

# --- the geography, from ui.lua ----------------------------------------------
PAD = 14
KEY_H = 26
KEY_GAP = 6
RADAR = 168
RADAR_COMPACT = 112
MONO_ADV = 0.602      # the mono's advance, as a share of its size
MARK_K = 14           # the badge's width in the corner; the sheet draws 11

# --- the ladder, from server/src/rating.rs -----------------------------------
TIERS = [("Newb", None), ("Wing", 1050), ("Lead", 1200), ("Ace", 1350),
         ("Legend", 1700)]
PLACING_GAMES = 10

# Five colors for five bands. Neither side's color is in it: cyan is yours
# and amber is theirs everywhere on the HUD, and a badge in either would
# read as a side. The bottom band is the mute the sheet already draws the
# mark in, so a new pilot's badge is the badge as it is today, and the top
# is the ink itself, the one color on the HUD that is not a color.
LADDERS = {
    "A": [MUTE, GREEN, CHARGE, BURST, INK],
    "B": [MUTE, DOOR, CHARGE, RUNG3, RUNG4],
}
LADDER = "A"


def adv(text, px):
    return len(text) * px * MONO_ADV


def radar_side(compact):
    return RADAR_COMPACT if compact else RADAR


def row_right(w, compact):
    return w - PAD - radar_side(compact) - KEY_GAP


def band(at):
    idx = 0
    for i, (_, floor) in enumerate(TIERS):
        if floor is not None and at >= floor:
            idx = i
    return idx


def tier_col(at, ladder=None):
    return LADDERS[ladder or LADDER][band(at)]


# --- the badge, ported from pilot_mark and wing_cut in ui.lua ----------------

WING = dict(
    roots=[(0.118, -0.06), (0.166, 0.06), (0.238, 0.18)],
    rake=[(0.500, -0.30), (0.389, 0.09)],
    root_line=[(0.118, -0.06), (0.238, 0.18)],
    deg=30, w0=0.020, w1=0.039,
)


def wing_hit(pt, u, line):
    (ax, ay), (bx, by) = line
    nx, ny = -(by - ay), bx - ax
    return (nx * (ax - pt[0]) + ny * (ay - pt[1])) / (nx * u[0] + ny * u[1])


def wing_cut(k):
    """The six feathers at one mark width, as runs of four corners, in the
    mark's own units. The client's arithmetic, line for line."""
    a = math.radians(WING["deg"])
    u = (math.cos(a), -math.sin(a))
    n = (-u[1], u[0])
    floor = 0.45 / max(1, k)
    w0 = max(WING["w0"], floor)
    w1 = max(WING["w1"], floor)
    out, far = [], 0
    for root in WING["roots"]:
        s = wing_hit(root, u, WING["rake"])
        q = []
        for w, cut, along in ((w0, WING["root_line"], 0),
                              (w1, WING["rake"], s),
                              (-w1, WING["rake"], s),
                              (-w0, WING["root_line"], 0)):
            pt = (root[0] + u[0] * along + n[0] * w,
                  root[1] + u[1] * along + n[1] * w)
            t = wing_hit(pt, u, cut)
            q.append((pt[0] + u[0] * t, pt[1] + u[1] * t))
        out.append(q)
        far = max(far, max(abs(p[0]) for p in q))
    squeeze = 0.5 / far
    both = []
    for q in out:
        both.append([(p[0] * squeeze, p[1]) for p in q])
        both.append([(-p[0] * squeeze, p[1]) for p in q])
    return both


HULL = [
    [(0, -0.325), (0.070, 0.225), (0, 0.325), (-0.070, 0.225)],
    [(0.052, -0.005), (0.220, 0.275), (0.170, 0.325), (0.070, 0.225)],
    [(-0.052, -0.005), (-0.220, 0.275), (-0.170, 0.325), (-0.070, 0.225)],
]


def badge(col, k, alpha=1.0):
    """Pilot's wings: the hull with three feathers off each side, drawn
    `k` points across as the client draws it, in one color."""
    quads = HULL + wing_cut(k)
    paths = "".join(
        '<path d="M' + " L".join(f"{x * k:.2f} {y * k:.2f}" for x, y in q)
        + f' Z" fill="{col}"/>' for q in quads)
    w, h = 1.2 * k, 0.8 * k
    return (f'<svg width="{w:.1f}" height="{h:.1f}" '
            f'viewBox="{-w / 2:.2f} {-h / 2:.2f} {w:.2f} {h:.2f}" '
            f'style="flex:none;opacity:{alpha}">{paths}</svg>')


# --- the rooms ---------------------------------------------------------------


class Side:
    def __init__(self, name, col, score, mine, held=0, pilot=False):
        self.name, self.col, self.score, self.mine = name, col, score, mine
        self.held = held
        self.pilot = pilot


# The viewer: DRiFT, their standing per zone, and what a kill game has done
# to it since they sat down, which the corner no longer draws.
ME = {
    "melee": (1228, -6),
    "turf": (1533, 0),
    "war": (1512, 0),
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
    "duel": dict(label="Duel", clock="1:37", stands=0, sides=[
        Side("DRiFT", FRIEND, 1, True, pilot=True),
        Side("Carrack", ENEMY, 1, False, pilot=True)]),
    "roam": dict(label="Free Roam", clock=None, stands=0, flying=31, sides=[]),
}


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
             "Cirrus killed DRiFT (-6)"]
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


def beacon(col, k=1.0, a=1.0):
    s = 10 * k
    return (f'<svg width="{s:.0f}" height="{s:.0f}" viewBox="-5 -5 10 10" '
            f'style="flex:none;opacity:{a}">'
            f'<circle r="4.4" fill="{col}" opacity=".16"/>'
            f'<circle r="3.1" fill="none" stroke="{col}" stroke-width=".9" '
            f'opacity=".9"/><circle r="1.3" fill="{col}"/></svg>')


def beacons(room, k=1.0, gap=4):
    n = room["stands"]
    if not n:
        return ""
    out = []
    for s in room["sides"]:
        out += [beacon(s.col, k) for _ in range(s.held)]
    loose = n - sum(s.held for s in room["sides"])
    out += [beacon(DIM, k, .7) for _ in range(loose)]
    return f'<span class="row" style="gap:{gap}px">{"".join(out)}</span>'


def label(s, px, dim=1.0):
    cls = "name" if s.pilot else "hud"
    return (f'<span class="{cls}" style="font-size:{px}px;color:{s.col};'
            f'opacity:{.85 * dim};white-space:nowrap">{s.name}</span>')


def clock_text(room, state):
    return "0:12" if state == "end" else room["clock"]


# --- the corner --------------------------------------------------------------


class Corner:
    """The top left: the badge in the tier's color, then the figure in ink.

    at        a standing other than the room's, to draw one tier or another.
    k         the badge's width in points.
    placing   inside the first ten rated games: no band, so the badge is
              the mute the sheet draws it in today, dimmed, and the figure
              is the mute the pilot card gives a placing pilot.
    bracket   keep decision 163's movement after the figure, for the
              comparison only.
    ladder    which five colors.
    shipped   decision 163's corner as it is on main, for the record.
    """

    def __init__(self, at=None, k=MARK_K, placing=False, bracket=False,
                 ladder=None, shipped=False):
        self.at, self.k, self.placing = at, k, placing
        self.bracket, self.ladder, self.shipped = bracket, ladder, shipped

    def standing(self, zone):
        at, moved = ME[zone]
        return (self.at if self.at is not None else at), moved

    def width(self, zone, compact, px):
        at, moved = self.standing(zone)
        if self.shipped:
            w = adv(str(at), px) + 5 + adv(f"({moved:+d})", px)
            return w if compact else w + adv("Rating", px) + 5
        w = 1.2 * self.k + 6 + adv(str(at), px)
        if self.bracket:
            w += 5 + adv(f"({moved:+d})", px)
        return w

    def html(self, zone, compact, px=13):
        at, moved = self.standing(zone)
        spans = []
        if self.shipped:
            if not compact:
                spans.append(f'<span class="hud" style="font-size:{px}px;'
                             f'color:{DIM};opacity:.8">Rating</span>')
            spans.append(f'<span class="num" style="font-size:{px}px;'
                         f'color:{INK};opacity:.9">{at}</span>')
            spans.append(self.moved(moved, px))
            gap = 5
        else:
            if self.placing:
                spans.append(badge(MUTE, self.k, .55))
                spans.append(f'<span class="num" style="font-size:{px}px;'
                             f'color:{MUTE};opacity:.9">{at}</span>')
            else:
                spans.append(badge(tier_col(at, self.ladder), self.k, .95))
                spans.append(f'<span class="num" style="font-size:{px}px;'
                             f'color:{INK};opacity:.9">{at}</span>')
            if self.bracket:
                spans.append(self.moved(moved, px))
            gap = 6
        return (f'<div class="abs row" style="left:{PAD}px;top:{PAD}px;'
                f'height:{KEY_H}px;gap:{gap}px">{"".join(spans)}</div>')

    @staticmethod
    def moved(by, px):
        col = PAID if by > 0 else HURT if by < 0 else MUTE
        text = f"({by:+d})" if by else "(0)"
        return (f'<span class="num" style="font-size:{px}px;color:{col};'
                f'opacity:{.8 if by == 0 else .95}">{text}</span>')


SHIPPED = Corner(shipped=True)
PICK = Corner()


# --- the row -----------------------------------------------------------------


def band_row(w, room, zone, compact, state, corner, px=13):
    """Decision 163's row: one line at top center, everything on it 13
    points. A side is its score and its name, the clock stands between
    them, and the corner is whatever `corner` draws."""
    top = PAD
    gap = 12 if compact else 16
    line = (f'top:{top}px;height:{KEY_H}px;display:flex;align-items:center;'
            f'position:absolute')
    out = [corner.html(zone, compact, px)]
    if room["clock"] is None:
        return "".join(out)
    clock = clock_text(room, state)
    ended = state == "end"
    middle = (f'<span class="num" style="font-size:{px}px;color:{READ};'
              f'opacity:.95">{clock}</span>')
    mid_w = adv(clock, px)
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
    corner_w = corner.width(zone, compact, px)
    for i, s in enumerate(room["sides"]):
        edge = w / 2 - half - gap if i == 0 else w / 2 + half + gap
        pos = (f"right:{w - edge:.0f}px" if i == 0 else f"left:{edge:.0f}px")
        room_l = edge - (PAD + corner_w + gap)
        room_r = row_right(w, compact) - edge
        fits = adv(s.name, px) + 8 + adv(str(s.score), px) <= (
            room_l if i == 0 else room_r)
        name = "" if ((compact or not fits) and not duel) else label(s, px)
        figure = "" if duel else (
            f'<span class="num" style="font-size:{px}px;'
            f'color:{s.col}">{s.score}</span>')
        bits = [figure, name] if i == 0 else [name, figure]
        bits = [x for x in bits if x]
        out.append(f'<div class="row" style="{line};{pos};gap:8px">'
                   f'{"".join(bits)}</div>')
    if room["stands"] and not ended:
        out.append(f'<div class="abs row" style="left:50%;top:{top + KEY_H + 4}px;'
                   f'transform:translateX(-50%)">{beacons(room, .9, 3)}</div>')
    return "".join(out)


# --- the boards --------------------------------------------------------------


def screen(form, zone, corner, state="open", seed=1):
    w, h = FORMS[form]
    compact = form == "Portrait"
    room = ROOMS[zone]
    out = [scene(w, h, 11 + w, compact), radar(w, compact)]
    if compact:
        out.append(pads(w, h))
    else:
        out.append(feed(w))
        out.append(corner_stack(h))
    out.append(band_row(w, room, zone, compact, state, corner))
    out.append(menu_key(w, h))
    return (f'<div style="position:relative;width:{w}px;height:{h}px;'
            f'overflow:hidden;background-color:{BG};'
            f'background-image:{starfield(w, h, seed + w)}">{"".join(out)}</div>')


STRIP_W, STRIP_H = 720, 84
PHONE_W = 390


def strip(zone, corner, state="open", compact=False, seed=None):
    w = PHONE_W if compact else STRIP_W
    room = ROOMS[zone]
    inner = radar(w, compact) + band_row(w, room, zone, compact, state, corner)
    seed = seed if seed is not None else 3 + hash(zone + str(corner.at)) % 97
    return (f'<div style="position:relative;width:{w}px;height:{STRIP_H}px;'
            f'overflow:hidden;background-color:{BG};flex:none;'
            f'background-image:{starfield(w, STRIP_H, seed)}">{inner}</div>')


# --- the sheet ---------------------------------------------------------------


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


def gap(h):
    return f'<div style="height:{h}px"></div>'


def cell(html, note):
    return (f'<div style="display:flex;flex-direction:column;gap:6px">'
            f'{html}<span class="lbl" style="letter-spacing:.1em">{note}'
            f'</span></div>')


def flow(cells):
    return (f'<div style="display:flex;flex-wrap:wrap;gap:14px 16px;'
            f'width:{2 * STRIP_W + 16}px;align-items:flex-start">'
            f'{"".join(cells)}</div>')


def swatches(ladder, k=40):
    """The five badges at forty points with the band's name and the hex
    under each, so the colors are judged as a set."""
    cells = []
    for (name, floor), col in zip(TIERS, LADDERS[ladder]):
        rng = (f"{floor} and up" if name == "Legend"
               else f"under {TIERS[1][1]}" if floor is None
               else f"{floor} to {TIERS[band(floor) + 1][1] - 1}")
        cells.append(
            f'<div style="display:flex;flex-direction:column;align-items:center;'
            f'gap:8px;width:120px">{badge(col, k)}'
            f'<span class="hud" style="font-size:11px;color:{INK};opacity:.9">'
            f'{name}</span>'
            f'<span class="lbl" style="letter-spacing:.08em;text-transform:none">'
            f'{rng}</span>'
            f'<span class="lbl" style="letter-spacing:.08em;text-transform:none">'
            f'{col}</span></div>')
    return (f'<div style="display:flex;gap:24px;padding:18px 0 4px">'
            f'{"".join(cells)}</div>')


TIER_AT = [1010, 1120, 1228, 1494, 1745]


def main_sheet():
    body = [
        title("The rating corner · the row's near end"),
        h1("A badge and a figure"),
        cap("Chris's call: the corner is the rating and a badge, nothing "
            "else. The badge is the pilot's wings, the mark the players sheet "
            "draws beside a human seat, and it wears a color a tier. So the "
            "caption goes and so does the bracket, in every zone; what a "
            "death did to the rating is still said on the wreck and at the "
            "end of the feed's line (decisions 152 and 155), and the sheet "
            "still carries the movement in its column. The corner says where "
            "you stand and, as a color, what band that is. Nothing here is "
            "built.", 900),
        gap(22),
        title("As shipped"),
        flow([cell(strip("melee", SHIPPED), "Team Battle, monitor"),
              cell(strip("melee", SHIPPED, compact=True), "Team Battle, phone")]),
        gap(34),
        h2("The five tiers"),
        gap(6),
        cap("The bands are rating.rs's: Newb under 1050, Wing to 1200, Lead "
            "to 1350, Ace to 1700, Legend above. Neither side's color is in "
            "the ladder, since cyan is yours and amber is theirs everywhere "
            "on the HUD and a badge in either would read as a side. The "
            "bottom band is the mute the sheet already draws the mark in, so "
            "a new pilot's badge is the badge as it is today, and the top "
            "band is the ink itself. The badge is drawn at fourteen points "
            "here, the row's type being thirteen; the sheet draws it at "
            "eleven beside a name, and the three sizes are compared "
            "further down.", 900),
        swatches("A"),
        gap(12),
    ]
    body.append(flow([
        cell(strip("melee", Corner(at=at)), f"{name}: {at}")
        for (name, _), at in zip(TIERS, TIER_AT)
    ] + [cell(strip("melee", Corner(placing=True)),
              "Placing: no band yet, badge and figure in the mute")]))
    body += [
        gap(28),
        title("A second ladder, for the comparison"),
        cap("The same bottom and a hotter top: teal, gold, then the two "
            "upper rungs of the weapon ladder. Its cost is that the fourth "
            "color sits close to the other side's amber.", 900),
        swatches("B"),
        gap(12),
        flow([cell(strip("melee", Corner(at=at, ladder="B")), f"{name}: {at}")
              for (name, _), at in zip(TIERS, TIER_AT)]),
        gap(34),
        h2("Every zone"),
        gap(6),
        cap("One mark and one figure, so a phone draws the same corner as a "
            "monitor. A flag zone's corner is the same corner, since there is "
            "no bracket to stand still in it. A watcher is shown none, as "
            "today.", 900),
        gap(12),
    ]
    body.append(flow([
        cell(strip("melee", PICK), "Team Battle: Lead"),
        cell(strip("melee", PICK, compact=True), "Team Battle, phone"),
        cell(strip("turf", PICK), "Turf: Ace"),
        cell(strip("turf", PICK, compact=True), "Turf, phone"),
        cell(strip("duel", PICK), "Duel: Ace"),
        cell(strip("duel", PICK, compact=True), "Duel, phone"),
        cell(strip("roam", PICK), "Free Roam: no clock, no score, the corner alone"),
        cell(strip("melee", PICK, state="end"), "At the whistle"),
    ]))
    body += [
        gap(34),
        h2("The badge's size"),
        gap(6),
        cap("Eleven is what the players sheet draws the mark at beside a "
            "name, and at that size the feathers are three strokes a point "
            "across, which carries the shape and not much of the color. "
            "Fourteen is the pick: a shade over the type, so the mark is "
            "seen first and the figure read second. Eighteen stands taller "
            "than the row.", 900),
        gap(12),
        flow([cell(strip("melee", Corner(k=k)), f"{k} points{' · the pick' if k == 14 else ''}")
              for k in (11, 14, 18)]),
        gap(34),
        h2("If the movement stays"),
        gap(6),
        cap("For the comparison only: decision 163's bracket after the "
            "figure, green up, red down. Chris asked for the figure and the "
            "badge alone, and the strip above the feed on the boards shows "
            "where the movement is still said.", 900),
        gap(12),
        flow([cell(strip("melee", Corner(bracket=True)), "Team Battle, monitor"),
              cell(strip("melee", Corner(bracket=True), compact=True),
                   "Team Battle, phone")]),
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


BOARDS = [
    ("Desktop", "Desktop", "melee", PICK, "open", "Team Battle, monitor: Lead"),
    ("Turf", "Desktop", "turf", PICK, "open", "Turf, monitor: Ace"),
    ("Legend", "Desktop", "melee", Corner(at=1745), "open", "A Legend, monitor"),
    ("Portrait", "Portrait", "melee", PICK, "open", "Team Battle, phone"),
    ("PortraitTurf", "Portrait", "turf", PICK, "open", "Turf, phone"),
    ("Shipped", "Desktop", "melee", SHIPPED, "open", "As shipped, monitor"),
]


def main():
    boards = {"Main": main_sheet()}
    for name, form, zone, corner, state, _ in BOARDS:
        boards[name] = screen(form, zone, corner, state)
    for name, body in boards.items():
        page(name, body)
    canvas(boards)
    print(f"{len(boards)} artboards written")


def canvas(boards):
    arts = [dict(file="Main.dc.html", title="The rating corner, the sheet",
                 x=0, y=0, w=2 * STRIP_W + 16 + 96, h=2820)]
    x0 = 2 * STRIP_W + 16 + 96 + 100
    my, py = 0, 0
    for name, form, zone, corner, state, t in BOARDS:
        w, h = FORMS[form]
        if form == "Desktop":
            arts.append(dict(file=f"{name}.dc.html", title=t, x=x0, y=my,
                             w=w, h=h))
            my += h + 120
        else:
            arts.append(dict(file=f"{name}.dc.html", title=t,
                             x=x0 + 1440 + 100 + py, y=0, w=w, h=h))
            py += w + 80
    assert {a["file"] for a in arts} == {f"{n}.dc.html" for n in boards}
    (HERE / "canvas.json").write_text(json.dumps(
        {"artboards": arts, "launch": {"view": "canvas"}}, indent=2) + "\n")


if __name__ == "__main__":
    main()
