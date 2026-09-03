#!/usr/bin/env python3
"""Assemble the artboards for the row's rating corner.

Decision 163 put your own standing at the near end of the top row as
`RATING 1228 (0)`: a caption in the dim, the figure in ink, and what the
match has done to it in brackets. Chris's notes on it, the day after: it
looks boring, on a phone it is a bare number since the caption drops, and
the bracketed zero says nothing in Turf and Capture the Flag, where
nothing moves until the whistle (decision 157).

Three changes are drawn here, each alone and then together:

- the tier as the caption, in place of the word RATING, so the word beside
  the figure says something and survives on a phone;
- the flag zones either drawing no bracket until the whistle or drawing
  what the score would pay if the match ended now, which the client can
  work out from the roster it already holds;
- a bar under the readout showing where the figure stands inside its
  band, so the corner has a shape and not only a line of type.

The rooms are the ones every band mock has been judged against, with the
viewer's standing in Team Battle set to the 1228 in Chris's screenshot.
The chrome is `../scoreboard-band/build.py`'s: hues from
client/arena/palette.lua, the row's measures from ui.lua, the beacon the
radar draws for a flag.

Rebuild with: python3 build.py
"""

import json
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

# --- the geography, from ui.lua ----------------------------------------------
PAD = 14
KEY_H = 26
KEY_GAP = 6
RADAR = 168
RADAR_COMPACT = 112
MONO_ADV = 0.602      # the mono's advance, as a share of its size

# --- the ladder, from server/src/rating.rs and net.lua -----------------------
TIERS = [("Newb", None), ("Wing", 1050), ("Lead", 1200), ("Ace", 1350),
         ("Legend", 1700)]
PLACING_GAMES = 10
K = 24                # a placed pilot's K, for the projection


def adv(text, px):
    return len(text) * px * MONO_ADV


def radar_side(compact):
    return RADAR_COMPACT if compact else RADAR


def row_right(w, compact):
    """Where the top row ends: the dial's left edge, a gap short of it."""
    return w - PAD - radar_side(compact) - KEY_GAP


def band(at):
    """The tier a figure is in, as its index, floor and ceiling. The top
    band has no ceiling and the bottom no floor."""
    idx = 0
    for i, (_, floor) in enumerate(TIERS):
        if floor is not None and at >= floor:
            idx = i
    floor = TIERS[idx][1] or 900
    ceil = TIERS[idx + 1][1] if idx + 1 < len(TIERS) else None
    return idx, floor, ceil


def tier_word(at):
    return TIERS[band(at)[0]][0]


# --- the rooms ---------------------------------------------------------------


class Side:
    def __init__(self, name, col, score, mine, held=0, pilot=False, mean=None):
        self.name, self.col, self.score, self.mine = name, col, score, mine
        self.held = held          # stands or flags this side holds
        self.pilot = pilot        # a side named by its pilot keeps its case
        self.mean = mean          # the side's mean rating, for the projection


# The viewer: DRiFT, their standing per zone, what a kill game has done to it
# since they sat down, and how many rated games they have there.
ME = {
    "melee": (1228, -6, 41),
    "turf": (1533, 0, 23),
    "war": (1512, 0, 17),
    "duel": (1471, -12, 58),
    "roam": (1500, 0, 12),
}

ROOMS = {
    "melee": dict(label="Team Battle", clock="2:14", stands=0, sides=[
        Side("Pylon", FRIEND, 17, True),
        Side("Caisson", ENEMY, 20, False)]),
    "turf": dict(label="Turf", clock="1:48", stands=6, sides=[
        Side("Keel", FRIEND, 34, True, held=3, mean=1540),
        Side("Vantage", ENEMY, 27, False, held=2, mean=1490)]),
    "war": dict(label="Capture the Flag", clock="3:12", stands=4, sides=[
        Side("Keel", FRIEND, 2, True, held=2, mean=1560),
        Side("Vantage", ENEMY, 2, False, held=1, mean=1500)]),
    "duel": dict(label="Duel", clock="1:37", stands=0, sides=[
        Side("DRiFT", FRIEND, 1, True, pilot=True),
        Side("Carrack", ENEMY, 1, False, pilot=True)]),
    "roam": dict(label="Free Roam", clock=None, stands=0, flying=31, sides=[]),
}


def project(room, scores=None):
    """Team Elo for the viewer's side, from the two sides' means and the
    score as it stands: what the whistle would pay if it went now. The
    same arithmetic rating.md gives for the flag games, at one K."""
    a, b = room["sides"]
    sa, sb = scores if scores else (a.score, b.score)
    e = 1 / (1 + 10 ** ((b.mean - a.mean) / 400))
    s = 1 if sa > sb else .5 if sa == sb else 0
    return round(K * (s - e))


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
    """The strip over the dial: POS at its left edge, the link bars flush
    against its right."""
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
    """One way of drawing the top left, as a set of choices:

    caption   "rating": the word RATING, dropped on a phone, as shipped.
              "tier": the band the figure is in, kept on a phone.
    flag      what a flag zone's bracket reads before the whistle:
              "zero": (0) all match, as shipped.
              "none": no bracket until the whistle.
              "project": what the score would pay if the match ended now.
    bar       "none", "track" (one bar filled to where the figure stands
              in its band) or "steps" (a segment a band, the current one
              filled to the figure).
    placing   the viewer is inside their first ten rated games.
    scores    the flag room's score, if not the room's own.
    """

    def __init__(self, caption="tier", flag="project", bar="none",
                 placing=False, scores=None):
        self.caption, self.flag, self.bar = caption, flag, bar
        self.placing, self.scores = placing, scores

    def parts(self, zone, compact, state):
        """The caption, the figure and the movement as (text, color,
        alpha) triples, the movement None where nothing is drawn."""
        at, moved, games = ME[zone]
        room = ROOMS[zone]
        flagzone = room["stands"] > 0
        if flagzone and state == "end":
            by, alpha = project(room, self.scores), 1
        elif flagzone and self.flag == "none":
            by, alpha = None, 1
        elif flagzone and self.flag == "project":
            by, alpha = project(room, self.scores), .7
        elif flagzone:
            by, alpha = 0, 1
        else:
            by, alpha = moved, 1
        # A duel keeps its two call signs on a phone, and the row has no
        # room for a word in the corner beside them, so there the caption
        # drops as it does today and the figures stand alone.
        if self.caption == "rating" or (compact and zone == "duel"):
            cap = None if compact else ("Rating", DIM, .8)
        elif self.placing:
            cap = ("Placing", DIM, .8)
        else:
            cap = (tier_word(at), DIM, .8)
        fig = (str(at), MUTE if self.placing else INK, .9)
        if by is None:
            mv = None
        else:
            col = PAID if by > 0 else HURT if by < 0 else MUTE
            mv = (f"({by:+d})" if by else "(0)", col,
                  alpha * (.8 if by == 0 else .95))
        return cap, fig, mv

    def width(self, zone, compact, state, px):
        cap, fig, mv = self.parts(zone, compact, state)
        words = [t for t in (cap, fig, mv) if t]
        return sum(adv(t[0], px) for t in words) + 5 * (len(words) - 1)

    def html(self, zone, compact, state, px=13):
        cap, fig, mv = self.parts(zone, compact, state)
        spans = []
        if cap:
            spans.append(f'<span class="hud" style="font-size:{px}px;'
                         f'color:{cap[1]};opacity:{cap[2]}">{cap[0]}</span>')
        for t in (fig, mv):
            if t:
                spans.append(f'<span class="num" style="font-size:{px}px;'
                             f'color:{t[1]};opacity:{t[2]}">{t[0]}</span>')
        width = self.width(zone, compact, state, px)
        out = [f'<div class="abs row" style="left:{PAD}px;top:{PAD}px;'
               f'height:{KEY_H}px;gap:5px">{"".join(spans)}</div>']
        if self.bar != "none":
            out.append(self.bar_html(zone, width))
        return "".join(out)

    def bar_html(self, zone, width):
        """Under the readout, as wide as it: where the figure stands in its
        band. A placing pilot's bar counts their games toward ten instead,
        in the dim, since they have no band yet."""
        at, _, games = ME[zone]
        y = PAD + KEY_H + 1
        h = 2
        if self.placing:
            frac, col, idx = games / PLACING_GAMES, DIM, None
        else:
            idx, floor, ceil = band(at)
            frac = 1 if ceil is None else (at - floor) / (ceil - floor)
            col = READ
        if self.bar == "track" or idx is None:
            return (f'<div class="abs" style="left:{PAD}px;top:{y}px;'
                    f'width:{width:.0f}px;height:{h}px;background:{TILE};'
                    f'opacity:.45"></div>'
                    f'<div class="abs" style="left:{PAD}px;top:{y}px;'
                    f'width:{width * frac:.0f}px;height:{h}px;'
                    f'background:{col};opacity:.85"></div>')
        n = len(TIERS)
        gap = 2
        seg = (width - gap * (n - 1)) / n
        out = []
        for i in range(n):
            x = PAD + i * (seg + gap)
            out.append(f'<div class="abs" style="left:{x:.1f}px;top:{y}px;'
                       f'width:{seg:.1f}px;height:{h}px;background:{TILE};'
                       f'opacity:.45"></div>')
            fill = 1 if i < idx else frac if i == idx else 0
            if fill:
                out.append(f'<div class="abs" style="left:{x:.1f}px;top:{y}px;'
                           f'width:{seg * fill:.1f}px;height:{h}px;'
                           f'background:{col};opacity:{.85 if i == idx else .4}">'
                           '</div>')
        return "".join(out)


SHIPPED = Corner(caption="rating", flag="zero")
TIER = Corner(caption="tier", flag="zero")
PROPOSED = Corner(caption="tier", flag="project", bar="track")


# --- the row -----------------------------------------------------------------


def band_row(w, room, zone, compact, state, corner, px=13):
    """Decision 163's row: one line at top center, everything on it 13
    points. A side is its score and its name, the clock stands between
    them, and the corner is whatever `corner` draws."""
    top = PAD
    gap = 12 if compact else 16
    line = (f'top:{top}px;height:{KEY_H}px;display:flex;align-items:center;'
            f'position:absolute')
    room = dict(room)
    if corner.scores and room["stands"]:
        a, b = room["sides"]
        room["sides"] = [Side(a.name, a.col, corner.scores[0], a.mine, a.held,
                              a.pilot, a.mean),
                         Side(b.name, b.col, corner.scores[1], b.mine, b.held,
                              b.pilot, b.mean)]
    out = [corner.html(zone, compact, state, px)]
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
    corner_w = corner.width(zone, compact, state, px)
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
    """The top of a window and nothing else: the row, the strip over the
    dial and the top edge of the dial."""
    w = PHONE_W if compact else STRIP_W
    room = ROOMS[zone]
    inner = radar(w, compact) + band_row(w, room, zone, compact, state, corner)
    seed = seed if seed is not None else 3 + hash(zone + corner.caption) % 97
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


def grid(cells, cols=2):
    return (f'<div style="display:grid;grid-template-columns:repeat({cols}, '
            f'minmax(0, 1fr));gap:14px 16px;width:{2 * STRIP_W + 16}px">'
            f'{"".join(cells)}</div>')


def flow(cells):
    return (f'<div style="display:flex;flex-wrap:wrap;gap:14px 16px;'
            f'width:{2 * STRIP_W + 16}px;align-items:flex-start">'
            f'{"".join(cells)}</div>')


def main_sheet():
    body = [
        title("The rating corner · the row's near end"),
        h1("A standing with a word beside it"),
        cap("Decision 163 put your own rating at the near end of the row as "
            "RATING 1228 (0): a caption in the dim, the figure in ink, the "
            "movement in brackets. Chris's notes on it the next day: it looks "
            "boring, on a phone it is a bare number because the caption is "
            "the first thing dropped, and the bracketed zero says nothing in "
            "Turf and Capture the Flag, where a death moves nothing and the "
            "whistle moves everybody. Three changes are drawn below, each on "
            "its own and then together on the boards to the right. Nothing "
            "here is built.", 900),
        gap(22),
        title("As shipped"),
    ]
    body.append(flow([
        cell(strip("melee", SHIPPED), "Team Battle, monitor"),
        cell(strip("melee", SHIPPED, compact=True), "Team Battle, phone"),
        cell(strip("turf", SHIPPED), "Turf, monitor: the (0) that reads all match"),
        cell(strip("turf", SHIPPED, compact=True), "Turf, phone"),
    ]))

    # 1. the tier as the caption
    body += [
        gap(34),
        h2("1 · The tier is the caption"),
        gap(6),
        cap("The ladder already has five named bands, Newb to Legend, and "
            "the pilot card already prints the figure with its band beside "
            "it. The band goes where RATING was, in the caption's own dim, "
            "and stays on a phone: RATING under a figure in that corner said "
            "nothing the corner had not said already, and a phone was right "
            "to drop it, but LEAD says what the figure means and what it is "
            "next to. A pilot inside their first ten rated games has no band "
            "and reads PLACING, with the figure in the mute the card gives "
            "it. A duel keeps its two call signs on a phone and there is no "
            "room for a word beside them, so there the caption drops as it "
            "does today. Nothing else on the row moves: the figures, the "
            "brackets and the colors are decision 163's.", 900),
        gap(12),
    ]
    body.append(flow([
        cell(strip("melee", TIER), "Team Battle: Lead, down six"),
        cell(strip("melee", TIER, compact=True), "Team Battle, phone: the band stays"),
        cell(strip("duel", TIER), "Duel: Ace, down twelve"),
        cell(strip("duel", TIER, compact=True), "Duel, phone: the names stay, the caption goes"),
        cell(strip("roam", TIER), "Free Roam: no clock, no score, the corner alone"),
        cell(strip("roam", Corner(caption="tier", flag="zero", placing=True),
                   compact=True), "Free Roam, phone: a pilot still placing"),
        cell(strip("melee", TIER, state="end"), "At the whistle"),
        cell(strip("melee", Corner(caption="tier", flag="zero", placing=True)),
             "Placing: the figure in the mute, the movement still colored"),
    ]))

    # 2. the flag zones
    body += [
        gap(34),
        h2("2 · A flag zone's bracket says what the score is worth"),
        gap(6),
        cap("Turf and Capture the Flag rate the whistle (decision 157), so "
            "the bracket cannot move while it is on screen: it reads (0) for "
            "three minutes and then jumps. Two answers. The plain one draws "
            "no bracket in a flag zone until the whistle latches the "
            "exchange. The better one draws what the whistle would pay if it "
            "went now. Team Elo needs the two sides' mean ratings and your K, "
            "and the roster already carries every seat's rating, side and "
            "game count, so the client can work it out; it is drawn a step "
            "dimmer than a fact while the match runs, and at the whistle the "
            "server's own figure lands in the same place at full strength. "
            "Keel's mean is fifty over Vantage's in Turf, so a level score "
            "costs Keel two, which is the thing a projection says and a "
            "score alone does not.", 900),
        gap(12),
    ]
    none = Corner(caption="tier", flag="none")
    proj = Corner(caption="tier", flag="project")
    body.append(flow([
        cell(strip("turf", TIER), "With the bracket as shipped: (0), all match"),
        cell(strip("turf", none), "No bracket until the whistle"),
        cell(strip("turf", proj), "Projected, ahead 34 to 27: plus ten"),
        cell(strip("turf", Corner(caption="tier", flag="project",
                                  scores=(27, 27))),
             "Projected, level: minus two, since Keel is the stronger side"),
        cell(strip("turf", Corner(caption="tier", flag="project",
                                  scores=(27, 34))),
             "Projected, behind: minus fourteen"),
        cell(strip("turf", proj, state="end"), "The whistle: the fact, at full strength"),
        cell(strip("war", proj), "Capture the Flag, level at two rounds each"),
        cell(strip("turf", proj, compact=True), "Turf, phone"),
    ]))

    # 3. the bar
    body += [
        gap(34),
        h2("3 · A bar under it, for where you stand in the band"),
        gap(6),
        cap("The far end of the row has an instrument under its readouts and "
            "the near end has a line of type. The band word says which rung; "
            "a two point bar under the readout, as wide as it, says how far "
            "along the rung, which is the question a rating answers for a "
            "player: Lead runs from 1200 to 1350, and 1228 is a fifth of the "
            "way to Ace. It sits on the line the flags use under the clock, "
            "so the row keeps its one line and the corner gains a shape. Two "
            "forms. The track is one bar filled to the figure. The steps are "
            "five segments, one a band, the ones below filled and the current "
            "one filled to the figure, so the whole ladder is in the corner. "
            "The track is the pick: the word already says which band, and "
            "five segments say it a second time. A placing pilot's bar counts "
            "their games toward ten, in the dim, since they have no band "
            "yet.", 900),
        gap(12),
    ]
    track = Corner(caption="tier", flag="project", bar="track")
    steps = Corner(caption="tier", flag="project", bar="steps")
    body.append(flow([
        cell(strip("melee", track), "Track: Lead, a fifth of the way to Ace"),
        cell(strip("melee", steps), "Steps: the third of five, a fifth filled"),
        cell(strip("turf", track), "Track, in Turf with the projection"),
        cell(strip("turf", steps), "Steps, in Turf"),
        cell(strip("melee", track, compact=True), "Track, phone"),
        cell(strip("melee", steps, compact=True), "Steps, phone"),
        cell(strip("melee", Corner(caption="tier", flag="project", bar="track",
                                   placing=True)),
             "Placing: four games of ten, in the dim"),
        cell(strip("duel", track), "Duel: Ace, a third of the way to Legend"),
    ]))

    body += [
        gap(34),
        h2("Together"),
        gap(6),
        cap("The band as the caption, the projection in a flag zone, the "
            "track under it. The boards to the right are this on a monitor "
            "and a phone, in Team Battle and in Turf.", 900),
        gap(12),
    ]
    body.append(flow([
        cell(strip("melee", PROPOSED), "Team Battle"),
        cell(strip("turf", PROPOSED), "Turf"),
        cell(strip("melee", PROPOSED, compact=True), "Team Battle, phone"),
        cell(strip("turf", PROPOSED, compact=True), "Turf, phone"),
    ]))
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
    ("Desktop", "Desktop", "melee", PROPOSED, "open", "Team Battle, monitor"),
    ("Turf", "Desktop", "turf", PROPOSED, "open", "Turf, monitor"),
    ("End", "Desktop", "turf", PROPOSED, "end", "Turf at the whistle, monitor"),
    ("Portrait", "Portrait", "melee", PROPOSED, "open", "Team Battle, phone"),
    ("PortraitTurf", "Portrait", "turf", PROPOSED, "open", "Turf, phone"),
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
    """The sheet at the left, the monitors down a column beside it and
    the phones beside those."""
    arts = [dict(file="Main.dc.html", title="The rating corner, the sheet",
                 x=0, y=0, w=2 * STRIP_W + 16 + 96, h=2860)]
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
