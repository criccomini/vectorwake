#!/usr/bin/env python3
"""Assemble the artboards for the scoreboard sheet: round two of one board.

Round one (../one-board) drew three places for one panel that is the
scoreboard, the roster, the side picker and the ending. Chris picked the
sheet, the menu's own panel, and asked for four things:

- Name it for what it is. TEAMS was the first instinct and then the duel
  argued against it, since a duel has no teams to be on. Both namings are
  drawn; the boards lead with SCOREBOARD, whose answer down the column is
  where you stand, which is what TEAMS was for.
- The column should say which side you are on, or that you are watching.
  So the panel is a stop in the in-match column, and its answer is your
  side and its score.
- The menu language has no section that can be pressed. A side's name is
  one, since pressing it joins the side. Three shapes for it are on the
  sheet; the boards use the ring.
- It has to make sense in every zone: Team Battle, Turf, War, the duel and
  Free Roam are each drawn.

And the band: alternatives to a 26-point instrument at top center, which
are a thinner line in the same place and a stack in the top left corner,
each drawn for every zone.

Round three, on Chris's next notes: the list is flat and the panel is
called PLAYERS. Time goes and a Team column takes its place; the side
line under the head goes, since the column names every side and the band
carries the score; your own side comes first and then everyone else, each
run alphabetical; and a side is joined from a player's own card, which a
press on any row opens and which carries JOIN <side> as its breathing
key. The selectable section is gone with the grouping; the card is a
panel that stacked, which the language already had.

The match is the one every ending mock has been judged against: Caisson
takes it 20 to 17, and the viewer is DRiFT on the losing side. The design
system is the client's: hues from client/arena/palette.lua, the band, key,
stop and row measures from ui.lua, the menu language of decisions 104 to
108, and the two faces the client carries.

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
KEY_EDGE = "#55708f"

# The list's order inside each group. Chris asked for "alphabetically by
# name desc", twice, so it is Z to A; flip this if A to Z was meant.
DESC = True

# --- the geography, from ui.lua ----------------------------------------------
PAD = 14
KEY_H = 26
ROW = 44
PANEL_MAX = 560
RADAR = 168
COLUMN_WASH = 0.42
STOP_W, STOP_H = 320, 54
STOP_GAP = 8

# --- the rooms ---------------------------------------------------------------
# A pilot: name, human, k, d, a, time in the seat, what the match paid.
PYLON = [
    ("Gantry", True, 8, 4, 4, "2:14", -3),
    ("Bellwether", False, 6, 3, 5, "2:14", -2),
    ("Ozone", False, 3, 7, 3, "2:14", -5),
    ("DRiFT", True, 0, 1, 6, "1:52", -6),
]
CAISSON = [
    ("Carrack", True, 6, 5, 3, "2:14", 9),
    ("Isobar", False, 5, 5, 3, "2:14", 4),
    ("Cirrus", False, 5, 6, 7, "2:14", 3),
    ("Jackstay", False, 4, 4, 8, "0:48", 4),
]
ME = "DRiFT"
MVP = "Carrack"
WATCHERS = ["Halyard", "Moss"]


def watching():
    """The watchers as a side: no score, no seats to take, nobody's color,
    and zeros for figures, since a watcher has none."""
    rows = [(n, True, 0, 0, 0, "", 0) for n in WATCHERS]
    return Side("Watching", MUTE, None, 0, 0, rows, False)


class Side:
    def __init__(self, name, col, score, humans, cap, pilots, mine,
                 held=0, of=0):
        self.name, self.col, self.score = name, col, score
        self.humans, self.cap, self.pilots, self.mine = humans, cap, pilots, mine
        self.held, self.of = held, of      # pennants: stands or flags held


# One room per zone. Score is what the zone counts: kills, turf, rounds.
ROOMS = {
    "melee": dict(label="Team Battle", clock="2:14", unit="kills", sides=[
        Side("Pylon", FRIEND, 17, 2, 4, PYLON, True),
        Side("Caisson", ENEMY, 20, 1, 4, CAISSON, False)]),
    "turf": dict(label="Turf", clock="1:48", unit="turf", stands=6, sides=[
        Side("Keel", FRIEND, 34, 2, 4, PYLON, True, held=3, of=6),
        Side("Vantage", ENEMY, 27, 4, 4, CAISSON, False, held=2, of=6)]),
    "war": dict(label="War", clock="3:12", unit="rounds", stands=4, sides=[
        Side("Keel", FRIEND, 2, 2, 4, PYLON, True, held=2, of=4),
        Side("Vantage", ENEMY, 1, 1, 4, CAISSON, False, held=1, of=4)]),
    "duel": dict(label="Duel", clock="1:37", unit="rounds", sides=[
        Side("DRiFT", FRIEND, 1, 1, 1, [("DRiFT", True, 1, 1, 0, "1:37", -4)],
             True),
        Side("Carrack", ENEMY, 1, 1, 1,
             [("Carrack", True, 1, 1, 0, "1:37", 5)], False)]),
}
# round, who took it, how long it ran; the third is in play
DUEL_ROUNDS = [("1", "DRiFT", "0:41"), ("2", "Carrack", "1:05"),
               ("3", None, "0:31")]

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


def roam_room():
    rnd = random.Random(7)
    sides = []
    for i, (name, pilots) in enumerate(ROAM_NAMES):
        mine = i == 0
        col = FRIEND if mine else ROAM_HUES[i - 1]
        rows = []
        for j, p in enumerate(pilots):
            human = (j % 3 != 1)
            rows.append((p, human, rnd.randint(0, 14), rnd.randint(0, 9),
                         rnd.randint(0, 6), f"{rnd.randint(0, 24)}:{rnd.randint(10, 59)}", 0))
        humans = sum(1 for r in rows if r[1])
        sides.append(Side(name, col, None, humans, 8, rows, mine))
    return dict(label="Free Roam", clock=None, unit=None, sides=sides,
                watched=False)


ROOMS["roam"] = roam_room()


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
.key{{display:inline-flex;align-items:center;justify-content:center;
  border:1px solid {KEY_EDGE};background:rgba(10,15,24,.6);
  font-family:var(--mono);text-transform:uppercase;letter-spacing:.08em;
  color:var(--read);white-space:nowrap}}
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


def pennant(col, k=8, a=1):
    """The flag at four pixels: the same pennant wherever an instrument
    shows one."""
    return (f'<svg width="{k}" height="{k + 2}" viewBox="0 0 8 10" '
            f'style="flex:none;opacity:{a}"><path d="M1 0 V10" stroke="{col}" '
            f'stroke-width="1.2"/><path d="M1.5 .8 L7.5 3.2 L1.5 5.6 Z" '
            f'fill="{col}"/></svg>')


def pennants(side, k=8, room=None):
    """A side's stands or flags: filled in its color, and the ones nobody
    holds dim, so the row says how much of the map is up for grabs."""
    if not side.of:
        return ""
    out = [pennant(side.col, k) for _ in range(side.held)]
    if room is not None:
        loose = side.of - sum(s.held for s in room["sides"])
        out += [pennant(DIM, k, .6) for _ in range(loose)]
    return f'<span class="row" style="gap:2px">{"".join(out)}</span>'


# --- the bands ---------------------------------------------------------------


def band_middle(w, room, compact, portrait, state="open"):
    """The shipped band: the clock one key tall, a side either side of it
    as a name over a number (decision 67). Pennants under it where the
    zone has them."""
    top = PAD
    name_px, gap = 9, 3
    under_px = KEY_H - name_px - gap
    side_gap = 14 if compact else 22
    out = []
    if room["clock"] is None:
        return (f'<div class="abs hud" style="left:0;right:0;top:{top}px;'
                f'height:{KEY_H}px;display:flex;flex-direction:column;'
                f'align-items:center;justify-content:center;gap:{gap}px">'
                f'<span style="font-size:{name_px}px;color:{DIM}">Free roam</span>'
                f'<span class="num" style="font-size:{under_px}px;color:{INK};'
                f'line-height:1;opacity:.95">31 flying</span></div>')
    clock = "0:12" if state == "end" else room["clock"]
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
    for i, s in enumerate(room["sides"]):
        edge = w / 2 - half - side_gap if i == 0 else w / 2 + half + side_gap
        align = "flex-end" if i == 0 else "flex-start"
        pos = (f"right:{w - edge:.0f}px" if i == 0 else f"left:{edge:.0f}px")
        label = "" if portrait else (
            f'<span class="hud" style="font-size:{name_px}px;'
            f'line-height:{name_px}px;color:{s.col};opacity:.85">{s.name}</span>')
        out.append(
            f'<div class="abs" style="{pos};top:{top}px;height:{KEY_H}px;'
            f'display:flex;flex-direction:column;align-items:{align};'
            f'justify-content:space-between">{label}'
            f'<span class="num" style="font-size:{under_px}px;'
            f'line-height:{under_px}px;color:{s.col}">{s.score}</span></div>')
    if room.get("stands"):
        flags = "".join(pennants(s, 8) for s in room["sides"])
        loose = room["stands"] - sum(s.held for s in room["sides"])
        flags += "".join(pennant(DIM, 8, .6) for _ in range(loose))
        out.append(f'<div class="abs row" style="left:50%;top:{top + KEY_H + 6}px;'
                   f'transform:translateX(-50%);gap:3px">{flags}</div>')
    return "".join(out)


def band_thin(w, room, compact, portrait):
    """One line, sixteen points: name and score either side of a smaller
    clock, pennants inline after the name. Less of the top of the arena
    spent, at the cost of a smaller clock and one weight for everything."""
    top = PAD
    h = 16
    if room["clock"] is None:
        return (f'<div class="abs hud num" style="left:50%;top:{top}px;'
                f'transform:translateX(-50%);font-size:12px;line-height:{h}px;'
                f'color:{INK};opacity:.9">31 flying</div>')
    parts = []
    for i, s in enumerate(room["sides"]):
        name = "" if portrait else (
            f'<span class="hud" style="font-size:10px;color:{s.col};'
            f'opacity:.85">{s.name}</span>')
        flags = pennants(s, 7)
        bits = [name, flags,
                f'<span class="num" style="font-size:13px;color:{s.col}">'
                f'{s.score}</span>']
        if i == 0:
            bits = bits
        else:
            bits = bits[::-1]
        parts.append(f'<span class="row" style="gap:6px">{"".join(bits)}</span>')
    return (f'<div class="abs row" style="left:50%;top:{top}px;height:{h}px;'
            f'transform:translateX(-50%);gap:{10 if compact else 16}px">'
            f'{parts[0]}<span class="num" style="font-size:16px;color:{INK};'
            f'opacity:.95">{room["clock"]}</span>{parts[1]}</div>')


def band_corner(w, room, compact, portrait):
    """A stack in the top left corner, broadcast style: the clock, then a
    line per side in its color. The middle of the top edge is the fight's
    again. Cost: the score stops being the first thing a stranger sees,
    and the corner is where the room's chips (TAKE SEAT, watching) come
    and go."""
    lines = []
    if room["clock"] is None:
        lines.append(f'<span class="hud num" style="font-size:12px;'
                     f'color:{INK};opacity:.9">31 flying</span>')
    else:
        lines.append(f'<span class="num" style="font-size:18px;'
                     f'line-height:18px;color:{INK};opacity:.95">'
                     f'{room["clock"]}</span>')
        for s in room["sides"]:
            lines.append(
                f'<span class="row" style="gap:6px;height:14px">'
                f'<span class="num" style="font-size:12px;color:{s.col};'
                f'width:22px">{s.score}</span>'
                f'<span class="hud" style="font-size:10px;color:{s.col};'
                f'opacity:.85">{s.name}</span>{pennants(s, 7)}</span>')
    return (f'<div class="abs" style="left:{PAD}px;top:{PAD}px;display:flex;'
            f'flex-direction:column;gap:3px">{"".join(lines)}</div>')


BANDS = {"Middle": band_middle, "Thin": band_thin, "Corner": band_corner}


def menu_key(w, h):
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
    return "".join([ring(80, h - 96, 54), ring(w - 64, h - 130, 26),
                    ring(w - 108, h - 78, 26)])


def chrome(w, h, room, compact, portrait, band="Middle", state="open",
           wash=True, key=True):
    out = [scene(w, h, 11 + w, compact), radar(w, compact)]
    if compact:
        out.append(pads(w, h))
    else:
        out.append(feed(w))
        out.append(corner_stack(h))
    if wash:
        out.append(f'<div class="abs" style="inset:0;'
                   f'background:rgba(5,7,12,{COLUMN_WASH})"></div>')
    if band == "Middle":
        out.append(band_middle(w, room, compact, portrait, state))
    else:
        out.append(BANDS[band](w, room, compact, portrait))
    if key:
        out.append(menu_key(w, h))
    return "".join(out)


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
    return (f'<svg width="{k}" height="{k}" viewBox="0 0 8 8" '
            f'style="flex:none"><polygon points="0,0 8,4 0,8" fill="{col}"/>'
            '</svg>')


def ring(col, k=8, a=.9):
    """The empty place: the ring the pips use for a charge you do not hold.
    On a side's row it is the seat you could take."""
    return (f'<svg width="{k}" height="{k}" viewBox="0 0 8 8" '
            f'style="flex:none;opacity:{a}"><circle cx="4" cy="4" r="3.1" '
            f'fill="none" stroke="{col}" stroke-width="1.2"/></svg>')


def back_tri(a=0.9):
    return (f'<svg width="11" height="12" viewBox="0 0 11 12" '
            f'style="flex:none"><polygon points="2,6 9,1.5 9,10.5" '
            f'fill="rgba(79,214,255,{a})"/></svg>')


def caret(col=INK, a=.75):
    return (f'<svg width="10" height="7" viewBox="0 0 10 7" style="flex:none">'
            f'<path d="M1 1 L5 5.5 L9 1" fill="none" stroke="{col}" '
            f'stroke-opacity="{a}" stroke-width="1.3"/></svg>')


def hrule(alpha=".45"):
    return f'<div style="height:1px;background:rgba(63,88,120,{alpha})"></div>'


# --- the menu language: rows, heads, bands, stops ----------------------------


def cell(v, wpx, col=READ, a=1, px=14):
    return (f'<span class="num" style="width:{wpx}px;text-align:right;'
            f'font-size:{px}px;color:{col};opacity:{a}">{v}</span>')


def m_head(title, col=INK, sub=""):
    extra = (f'<span class="mono" style="font-size:14px;color:{READ};'
             f'margin-left:auto">{sub}</span>') if sub else ""
    return (f'<div class="row" style="height:{ROW}px;gap:10px;padding:0 14px">'
            f'{back_tri()}<span style="font-size:17px;color:{col}">{title}'
            f'</span>{extra}</div>{hrule(".6")}')


def m_band(label):
    return (f'<div class="row" style="height:24px;padding:0 14px;gap:10px">'
            f'<div style="flex:1">{hrule()}</div>'
            f'<span class="lbl" style="font-size:12px;letter-spacing:.1em;'
            f'color:{MUTE}">{label}</span><div style="flex:1">{hrule()}</div>'
            f'</div>')


COLS = {
    "melee": [("Team", 84), ("K", 24), ("D", 24), ("A", 24)],
    "turf": [("Team", 84), ("K", 24), ("D", 24), ("A", 24)],
    "war": [("Team", 84), ("K", 24), ("D", 24), ("A", 24)],
    "duel": [("Team", 84), ("K", 24), ("D", 24)],
    "roam": [("Team", 96), ("K", 24), ("D", 24)],
}


def m_col_heads(zone, ending=False, portrait=False):
    cols = list(COLS[zone])
    if portrait and len(cols) > 3:
        cols = [c for c in cols if c[0] != "A"]
    if ending:
        cols.append(("Rating", 44))
    cells = "".join(cell(c, w, MUTE, 1, 12) for c, w in cols)
    return (f'<div class="row" style="height:24px;padding:0 14px">'
            f'<span class="row hud" style="margin-left:auto;gap:10px">{cells}'
            '</span></div>')


def m_pilot(p, zone, side, ending=False, portrait=False, lit=False):
    """A pilot's row: the name in the side's color, the seat's mark, then
    the side's name in the Team column and the figures. Your own row keeps
    its wash; a row under a hand lights edge to edge. A press opens the
    pilot's card."""
    name, human, k, d, a, _t, moved = p
    col = side.col
    watcher = side.name == "Watching"
    me = name == ME
    wash = ""
    if lit:
        wash = "background:rgba(79,214,255,.18);"
    elif me:
        wash = "background:rgba(79,214,255,.13);"
    mark = helm(MUTE, 12) if human else bot(MUTE, 12)
    cols = list(COLS[zone])
    if portrait and len(cols) > 3:
        cols = [c for c in cols if c[0] != "A"]
    cells = ""
    for c, w in cols:
        if c == "Team":
            cells += (f'<span class="mono" style="width:{w}px;text-align:right;'
                      f'font-size:13px;color:{col};opacity:.9;'
                      f'white-space:nowrap;overflow:hidden">{side.name}</span>')
        else:
            cells += cell({"K": k, "D": d, "A": a}[c], w,
                          MUTE if watcher else READ)
    if ending and watcher:
        cells += cell("", 44, MUTE)
    elif ending:
        if moved > 0:
            cells += cell(f"+{moved}", 44, PAID, .95)
        elif moved < 0:
            cells += cell(str(moved), 44, HURT, .85)
        else:
            cells += cell("0", 44, MUTE)
    mvp = ""
    if ending and name == MVP:
        mvp = f'<span class="lbl" style="font-size:10px;color:{PAID}">MVP</span>'
    return (f'<div class="row" style="height:{ROW}px;gap:10px;'
            f'padding:0 14px;{wash}">'
            f'<span style="font-size:17px;color:{READ if watcher else col};'
            f'opacity:{1 if me else .85}">{name}</span>{mvp}{mark}'
            f'<span class="row" style="margin-left:auto;gap:10px">{cells}</span>'
            '</div>')


def score_row(room):
    """The sides and their scores inside the sheet, one line under the head:
    the band said again, because on a phone the band is a screen away. Each
    side in its color with its stands or flags, the loose ones dim."""
    if room["clock"] is None or room["unit"] is None:
        return ""
    l, r = room["sides"]

    def side(s, right):
        bits = [f'<span style="font-size:14px;color:{s.col}">{s.name}</span>',
                f'<span class="num" style="font-size:14px;color:{s.col}">'
                f'{s.score}</span>', pennants(s, 8, room)]
        if right:
            bits = bits[::-1]
        return f'<span class="row" style="gap:8px">{"".join(bits)}</span>'
    return (f'<div class="row" style="height:32px;padding:0 14px;'
            f'justify-content:space-between">{side(l, False)}{side(r, True)}'
            f'</div>')


def pilot_card(p, side, room, zone="melee", w=None, note=None):
    """The pilot's card: a panel that stacked. Its head is the pilot, its
    rows read who they are and what they have done this match, and its
    breathing key at the foot is the one act the card offers, joining
    their side. No key on your own side's pilot or on yourself; a full
    side's key stands down and says why."""
    name, human, k, d, a, _t, _m = p
    me = name == ME
    rows = []

    def read(label, value, col=READ, raw=False):
        return (f'<div class="row" style="height:{ROW}px;padding:0 14px">'
                f'<span style="font-size:17px;color:{INK}">{label}</span>'
                f'<span class="{"" if raw else "mono"}" style="margin-left:auto;'
                f'font-size:14px;color:{col}">{value}</span></div>')
    rows.append(read("Team", side.name, side.col))
    rows.append(read("Ship", "Anvil" if not me else "Apex"))
    rows.append(read("Rating", "1480 · Ace" if human else "Bot"))
    figures = f"{k} K · {d} D · {a} A" if zone != "duel" else f"{k} K · {d} D"
    rows.append(read("This match", figures))
    foot = ""
    if side.name == "Watching":
        pass
    elif not me and not side.mine:
        if side.humans < side.cap:
            foot = (f'<div style="padding:10px 14px 14px">'
                    f'{commit_key("JOIN " + side.name.upper(), None, 44)}</div>')
        else:
            foot = (f'<div class="row" style="height:{ROW}px;padding:0 14px;'
                    f'justify-content:center"><span class="mono" '
                    f'style="font-size:14px;color:{MUTE}">{side.name} is full'
                    f'</span></div>')
    if note:
        foot = (f'<div class="row" style="height:{ROW}px;padding:0 14px;'
                f'justify-content:center"><span class="mono" '
                f'style="font-size:14px;color:{MUTE}">{note}</span></div>')
    head = (f'<div class="row" style="height:{ROW}px;gap:10px;padding:0 14px">'
            f'{back_tri()}<span style="font-size:17px;color:{side.col}">{name}'
            f'</span>{helm(MUTE, 12) if human else bot(MUTE, 12)}</div>'
            f'{hrule(".6")}')
    return (f'<div class="glass" style="{"width:" + str(w) + "px" if w else ""}">'
            f'{head}{"".join(rows)}{foot}</div>')


def m_round(n, who, t, room):
    """One round of a duel: its number, who took it in their color, and how
    long it ran. The round in play has no taker yet and reads its clock."""
    if who:
        col = next(s.col for s in room["sides"] if s.name == who)
        took = f'<span style="font-size:17px;color:{col}">{who}</span>'
    else:
        took = f'<span style="font-size:17px;color:{MUTE}">In play</span>'
    return (f'<div class="row" style="height:{ROW}px;gap:14px;'
            f'padding:0 14px 0 32px">'
            f'<span class="mono" style="font-size:14px;color:{MUTE};'
            f'width:16px">{n}</span>{took}'
            f'<span class="num" style="margin-left:auto;font-size:14px;'
            f'color:{MUTE}">{t}</span></div>')


def share_bar(room, h=12, px=15):
    l, r = sorted(room["sides"], key=lambda s: -s.score)
    share = l.score / (l.score + r.score) * 100

    def inside(name, right):
        return (f'<span class="hud" style="font-size:8px;color:{BG};'
                f'letter-spacing:.1em;position:absolute;'
                f'{"right" if right else "left"}:6px;top:50%;'
                f'transform:translateY(-50%);white-space:nowrap">{name}</span>')
    return (f'<div class="row" style="gap:8px;padding:0 8px">'
            f'<span class="num" style="font-size:{px}px;color:{l.col}">{l.score}</span>'
            f'<div style="flex:1;height:{h}px;display:flex;overflow:hidden">'
            f'<div style="position:relative;width:{share:.1f}%;background:{l.col}">'
            f'{inside(l.name, False)}</div>'
            f'<div style="position:relative;flex:1;background:{r.col}">'
            f'{inside(r.name, True)}</div></div>'
            f'<span class="num" style="font-size:{px}px;color:{r.col}">{r.score}</span>'
            '</div>')


def stop(label, value, w=STOP_W, h=STOP_H, lit=False, hot=False, raw=True):
    """A stop of the column: the question at the label's weight, the answer
    at full strength, a caret, in the stroked box every key wears."""
    edge = f"rgba(79,214,255,.8)" if (lit or hot) else "rgba(63,88,120,.75)"
    wash = "rgba(79,214,255,.18)" if hot else "rgba(10,15,24,.6)"
    val = ""
    if value:
        val = (f'<span class="{"" if raw else "hud"}" style="font-size:12px;'
               f'color:{INK};opacity:.95;font-family:var(--mono)">{value}</span>')
    return (f'<div class="row" style="width:{w}px;height:{h}px;'
            f'border:1px solid {edge};background:{wash};padding:0 14px;'
            f'gap:10px;backdrop-filter:blur(4px)">'
            f'<span class="lbl" style="font-size:12px;letter-spacing:.1em">'
            f'{label}</span><span style="margin-left:auto"></span>{val}'
            f'{caret()}</div>')


def commit_key(word, w=STOP_W, h=STOP_H):
    return (f'<div class="row" style="{"width:" + str(w) + "px;" if w else ""}'
            f'height:{h}px;'
            f'justify-content:center;border:1px solid rgba(79,214,255,.85);'
            f'background:rgba(79,214,255,.16);font-size:14px;'
            f'font-family:var(--mono);letter-spacing:.12em;color:{FRIEND}">'
            f'{word}</div>')


# --- the boards --------------------------------------------------------------


def order(room, as_watcher=False):
    """Your own side first, then everyone else, then the watchers at the
    foot, each run by name (Z to A while DESC holds). A watcher has no side,
    so for them the first two groups are one."""
    groups = [(p, s) for s in room["sides"] for p in s.pilots]
    if room.get("watched", True):
        w = watching()
        groups += [(p, w) for p in w.pilots]

    def key(ps):
        p, side = ps
        rank = 2 if side.name == "Watching" else (
            1 if (as_watcher or not side.mine) else 0)
        return (rank, p[0].lower())
    out = sorted(groups, key=key)
    if DESC:
        # Reverse the names inside each rank and keep the ranks in place.
        by_rank = {}
        for ps in out:
            by_rank.setdefault(key(ps)[0], []).append(ps)
        out = []
        for r in sorted(by_rank):
            out += list(reversed(by_rank[r]))
    return out


def sheet_body(zone, state="open", portrait=False, naming="Players",
               lit=None, watching=False):
    room = ROOMS[zone]
    ending = state == "end"
    body = []
    if ending:
        winner = max(room["sides"], key=lambda s: s.score)
        body.append(m_head(f"{winner.name} takes it", winner.col))
        body.append(f'<div style="padding:10px 6px 6px">{share_bar(room)}</div>')
    elif zone == "roam":
        body.append(m_head(naming, sub="31 flying"))
    else:
        body.append(m_head(naming, sub=room["clock"]))
    body.append(m_col_heads(zone, ending, portrait))
    for p, s in order(room, watching):
        body.append(m_pilot(p, zone, s, ending, portrait, lit=(p[0] == lit)))
    if zone == "duel":
        body.append(m_band("Rounds"))
        for n, who, t in DUEL_ROUNDS:
            if ending and who is None:
                continue
            body.append(m_round(n, who, t, room))
    return "".join(body)


def sheet_height(zone, state, ending_extra=60):
    room = ROOMS[zone]
    n = sum(len(s.pilots) for s in room["sides"])
    if room.get("watched", True):
        n += len(WATCHERS)
    want = ROW + 1 + 24 + n * ROW
    if zone == "duel":
        want += 24 + (2 if state == "end" else 3) * ROW
    if state == "end":
        want += ending_extra
    return want


def sheet(zone, form, state="open", naming="Players", band="Middle",
          card=None, lit=None):
    """The sheet on the glass; with `card` the name of a pilot whose card
    has replaced it, the way a stacked panel replaces the one under it."""
    w, h = FORMS[form]
    compact = form != "Desktop"
    portrait = form == "Portrait"
    room = ROOMS[zone]
    span = w - 2 * PAD
    pw = min(PANEL_MAX, span)
    px = PAD + (span - pw) / 2
    if card:
        p, side = next((p, s) for s in room["sides"] for p in s.pilots
                       if p[0] == card)
        panel = (f'<div class="abs" style="left:{px}px;bottom:{PAD}px;'
                 f'width:{pw}px">{pilot_card(p, side, room, zone)}</div>')
        return chrome(w, h, room, compact, portrait, band, state,
                      key=False) + panel
    want = sheet_height(zone, state)
    top_clear = PAD + KEY_H + (22 if room.get("stands") else 14)
    if state == "end":
        top_clear += 12
    roomh = h - PAD - top_clear
    ph = min(want, roomh)
    clip = want > roomh
    thumb = ""
    if clip:
        frac = roomh / want
        thumb = (f'<div class="abs" style="right:3px;top:{ROW + 8}px;width:3px;'
                 f'height:{(ph - ROW - 16) * frac:.0f}px;background:{TILE}">'
                 '</div>')
    panel = (f'<div class="abs glass" style="left:{px}px;bottom:{PAD}px;'
             f'width:{pw}px;height:{ph}px;overflow:hidden">'
             f'{sheet_body(zone, state, portrait, naming, lit)}{thumb}</div>')
    return chrome(w, h, room, compact, portrait, band, state, key=False) + panel


def column(form, value, naming="Players", watching=False):
    """The in-match column with the scoreboard as a stop whose answer is
    where you stand: your side and its score, or Watching."""
    w, h = FORMS[form]
    compact = form != "Desktop"
    portrait = form == "Portrait"
    room = ROOMS["melee"]
    narrow = w < 620
    sw = (w - 2 * PAD) if narrow else (240 if compact else STOP_W)
    sh = 50 if narrow else (44 if compact else STOP_H)
    stops = [("Account", "DRiFT"), ("Zone", "Team Battle"),
             (naming, value), ("Ship", "Apex"), ("Settings", "")]
    col = "".join(stop(l, v, sw, sh) for l, v in stops)
    key = commit_key("PLAY" if watching else "SPECTATE", sw, sh)
    block = (f'<div class="abs" style="left:50%;bottom:{PAD}px;'
             f'transform:translateX(-50%);display:flex;flex-direction:column;'
             f'gap:{STOP_GAP}px">{col}{key}</div>')
    return chrome(w, h, room, compact, portrait, key=False) + block


def band_board(design, form, zone="melee"):
    w, h = FORMS[form]
    compact = form != "Desktop"
    portrait = form == "Portrait"
    return chrome(w, h, ROOMS[zone], compact, portrait, design, wash=False)


# --- the sheets --------------------------------------------------------------


def cap(text, w=None):
    return (f'<div style="font-size:13px;line-height:19px;color:{READ};'
            f'{"width:" + str(w) + "px;" if w else ""}text-wrap:pretty">'
            f'{text}</div>')


def title(text):
    return (f'<div class="lbl" style="font-size:11px;letter-spacing:.16em;'
            f'margin-bottom:10px">{text}</div>')


def glass(body, w=400):
    return f'<div class="glass" style="width:{w}px">{body}</div>'


def main_sheet():
    W, H = 1440, 1020
    room = ROOMS["melee"]
    pylon, caisson = room["sides"]
    full = Side("Caisson", ENEMY, 20, 4, 4, CAISSON, False)

    rows = glass(
        m_head("Players", sub="2:14")
        + m_col_heads("melee")
        + m_pilot(PYLON[0], "melee", pylon)
        + m_pilot(PYLON[3], "melee", pylon)
        + m_pilot(CAISSON[0], "melee", caisson, lit=True)
        + m_pilot(watching().pilots[1], "melee", watching()), 400)

    cards = (f'<div style="display:flex;flex-direction:column;gap:14px">'
             f'{pilot_card(CAISSON[0], caisson, room, w=400)}'
             f'{pilot_card(CAISSON[0], full, room, w=400)}'
             f'{pilot_card(PYLON[0], pylon, room, w=400)}</div>')

    stops = (f'<div style="display:flex;flex-direction:column;gap:8px">'
             f'{stop("Players", "Pylon")}{stop("Players", "Watching")}'
             f'{stop("Players", "DRiFT")}{stop("Players", "Anvil Watch")}'
             f'</div>')

    body = f'''
<div style="position:relative;width:{W}px;height:{H}px;overflow:hidden;
     background-color:{BG};background-image:{starfield(W, H, 3)};padding:40px 48px">
  <div style="display:flex;flex-direction:column;gap:6px;margin-bottom:28px">
    <div style="font-size:26px;color:{INK}">The players sheet</div>
    {cap("The menu's panel, holding the room as one list: your own side first, then everyone else, then the watchers, each run by name, with the side in the Team column and in the color of the name. A press on a player opens their card, and the card's one key joins their side. It is a stop in the column, its answer is where you stand, and at the whistle it rises on its own with the result as its head.", 860)}
  </div>
  <div style="display:grid;grid-template-columns:repeat(3, minmax(0, 1fr));gap:40px">
    <div>
      {title("The list")}
      {rows}
      <div style="margin-top:8px">{cap("The head names the panel and reads the clock. The columns are the side, kills, deaths and assists; the band above already carries the score, so the sheet does not say it again. Your own side comes first, then everyone else, then the watchers, each run by name, Z to A: the color and the Team column say the side, the order says who is with you. A watcher is a row like any other, with Watching for a side and zeros for figures, in nobody's color. Your own row keeps its wash; a row under a hand lights edge to edge, as every row does, and a press opens the player's card. Nothing in the language is new here.")}</div>
    </div>
    <div>
      {title("The pilot card, in its states")}
      {cards}
      <div style="margin-top:8px">{cap("A panel that stacked, with the player as its head. Its rows read their side, their ship, their rating and this match. The breathing key at the foot is the one act: JOIN, named for the side, gated as a hull change is. On a full side the key stands down and says so. On your own side's player, on yourself, and on a watcher, there is no key.")}</div>
    </div>
    <div>
      {title("The stop")}
      {stops}
      <div style="margin-top:8px">{cap("PLAYERS, between ZONE and SHIP, answering where you stand: your side, or Watching. In a duel a side is named by its pilot, so the answer there is your own call sign; in Free Roam it is the pact you are in.", 320)}</div>
    </div>
  </div>
</div>'''
    return body


def band_sheet():
    W, H = 1440, 1080
    zones = ["melee", "turf", "war", "duel", "roam"]
    cols = ""
    for design, note in (
        ("Middle", "The shipped band: the clock one key tall, a side either side of it as a name over a number, pennants under. 26 points of the top edge, centered on the fight."),
        ("Thin", "One line at 16 points, the clock smaller, names and scores at one weight, pennants inline. Costs the clock its size and the sides their two-line stack."),
        ("Corner", "A stack in the top left: the clock, then a line per side with its pennants. The top edge is the fight's again. Costs the first glance: a stranger's eye starts at the middle."),
    ):
        strips = ""
        for z in zones:
            strips += (f'<div style="position:relative;width:420px;height:64px;'
                       f'background:rgba(5,7,12,.5);overflow:hidden">'
                       f'{BANDS[design](420, ROOMS[z], False, False)}'
                       f'<div class="lbl" style="position:absolute;right:8px;'
                       f'bottom:6px;font-size:9px">{ROOMS[z]["label"]}</div></div>')
        strips += (f'<div style="position:relative;width:362px;height:64px;'
                   f'background:rgba(5,7,12,.5);overflow:hidden">'
                   f'{BANDS[design](362, ROOMS["turf"], True, True)}'
                   f'<div class="lbl" style="position:absolute;right:8px;'
                   f'bottom:6px;font-size:9px">Turf, upright phone</div></div>')
        cols += (f'<div style="display:flex;flex-direction:column;gap:10px">'
                 f'{title(design)}{strips}<div style="margin-top:4px">'
                 f'{cap(note, 420)}</div></div>')
    return f'''
<div style="position:relative;width:{W}px;height:{H}px;overflow:hidden;
     background-color:{BG};background-image:{starfield(W, H, 5)};padding:40px 48px">
  <div style="display:flex;flex-direction:column;gap:6px;margin-bottom:28px">
    <div style="font-size:26px;color:{INK}">The band, by zone</div>
    {cap("Three shapes for the instrument the sheet hangs off, each drawn for every zone. Team Battle counts kills, Turf counts turf and shows the six stands, War counts rounds and shows the four flags, the duel counts rounds under each pilot's call sign, and Free Roam has no clock and no score, so its band is the room's count and nothing else.", 860)}
  </div>
  <div style="display:flex;gap:40px">{cols}</div>
</div>'''


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


def screen(form, inner, seed=1):
    w, h = FORMS[form]
    return (f'<div style="position:relative;width:{w}px;height:{h}px;'
            f'overflow:hidden;background-color:{BG};'
            f'background-image:{starfield(w, h, seed + w)}">{inner}</div>')


def main():
    boards = {
        "Main": main_sheet(),
        "ColumnDesktop": screen("Desktop", column("Desktop", "Pylon")),
        "ColumnPortrait": screen("Portrait",
                                 column("Portrait", "Watching", watching=True)),
        "TeamBattle": screen("Desktop", sheet("melee", "Desktop",
                                              lit="Carrack")),
        "PilotCard": screen("Desktop", sheet("melee", "Desktop",
                                             card="Carrack")),
        "PilotCardPortrait": screen("Portrait", sheet("melee", "Portrait",
                                                      card="Carrack")),
        "TeamBattlePortrait": screen("Portrait", sheet("melee", "Portrait")),
        "TeamBattleLandscape": screen("Landscape", sheet("melee", "Landscape")),
        "TeamBattleEnd": screen("Desktop", sheet("melee", "Desktop", "end")),
        "TeamBattleEndPortrait": screen("Portrait",
                                        sheet("melee", "Portrait", "end")),
        "Turf": screen("Desktop", sheet("turf", "Desktop")),
        "War": screen("Desktop", sheet("war", "Desktop")),
        "Duel": screen("Desktop", sheet("duel", "Desktop")),
        "DuelEnd": screen("Desktop", sheet("duel", "Desktop", "end")),
        "DuelPortrait": screen("Portrait", sheet("duel", "Portrait")),
        "FreeRoam": screen("Desktop", sheet("roam", "Desktop")),
        "Bands": band_sheet(),
        "BandMiddle": screen("Desktop", band_board("Middle", "Desktop", "turf")),
        "BandThin": screen("Desktop", band_board("Thin", "Desktop", "turf")),
        "BandCorner": screen("Desktop", band_board("Corner", "Desktop", "turf")),
        "BandThinPortrait": screen("Portrait",
                                   band_board("Thin", "Portrait", "war")),
        "BandCornerPortrait": screen("Portrait",
                                     band_board("Corner", "Portrait", "war")),
        "BandCornerSheet": screen("Desktop",
                                  sheet("war", "Desktop", band="Corner")),
    }
    for name, body in boards.items():
        page(name, body)
    print(f"{len(boards)} artboards written")


if __name__ == "__main__":
    main()
