#!/usr/bin/env python3
"""Assemble the artboards for canned phrases during play.

Decision 51 put six phrases on the podium between matches and nothing
publishes them any more: the chips went with the ending's card and the key
that was to replace them never arrived. Chris's ask, a week later, is the
other half of decision 28's reconsider clause: a bounded set of team
signals during a match, drawn beside the ship that said them, with the
house bots both saying them and acting on "follow me", "help!" and
"retreat!".

What is drawn here:

- The picker: a box of rows on the glass, opened by one key, each row a
  digit and a phrase, gone the moment a row is pressed. It stands on the
  left edge over the charge marks so it never covers the middle of the
  glass where you are. Flight keys keep working while it is up.
- The phrase: one line under the nameplate, in ink rather than the side's
  color, for three seconds. Your own hull wears no plate, so your own line
  stands at the same offset alone.
- A caller you cannot see: the feed carries the line in the side's color
  and their radar dot rings for as long as the line lives.
- The phone: a CALL key under the rating corner drops the same rows.
- An alternate picker, a strip of chips along the bottom, for the
  comparison.

The chrome is ../rating-corner/build.py's (hues from palette.lua, measures
from ui.lua) and the rows are ../menu-language/build.py's.

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
GREEN = "#5be08a"
CHARGE = "#ffd166"
BURST = "#c27bff"

# --- the geography, from ui.lua ----------------------------------------------
PAD = 14
KEY_H = 26
KEY_GAP = 6
RADAR = 168
RADAR_COMPACT = 112
MONO_ADV = 0.602
MARK_K = 14
ROW_H = 44          # the one row height, decision 104
ROW_INSET = 14
WASH_CURSOR = "background:rgba(79,214,255,.18);"
WASH_HERE = "background:rgba(79,214,255,.07);"

# --- the ladder, from server/src/rating.rs -----------------------------------
TIERS = [("Newb", None), ("Wing", 1050), ("Lead", 1200), ("Ace", 1350),
         ("Legend", 1700)]
LADDER = [MUTE, GREEN, CHARGE, BURST, INK]


def adv(text, px):
    return len(text) * px * MONO_ADV


def band(at):
    idx = 0
    for i, (_, floor) in enumerate(TIERS):
        if floor is not None and at >= floor:
            idx = i
    return idx


def tier_col(at):
    return LADDER[band(at)]


# --- the phrases -------------------------------------------------------------

# Decision 51's six, in wire order. Between matches, to the room, and they
# keep their indexes so a podium line means what it meant.
PODIUM = ["gg", "nice shot", "close one", "good luck", "thanks", "sorry"]

# During a match, to your side only. Nine so a digit picks each. The wire
# numbers them after the six; "sorry" is the one shared with the podium and
# keeps its index there.
MATCH = ["follow me", "help!", "retreat!", "attack!", "hold here",
         "on it", "can't", "falling back", "sorry"]

# Everything considered, with the verdict and the reason, for the sheet.
BRAINSTORM = [
    ("follow me", "call", "in", "the one Chris named first; a bot escorts"),
    ("help!", "call", "in", "the ask a bot answers by coming; also what a bot says when it needs you"),
    ("retreat!", "call", "in", "moves the whole side; a bot breaks off"),
    ("attack!", "call", "in", "the opposite of retreat; at a flag it means the flag"),
    ("hold here", "call", "in", "the standing order follow me cannot give"),
    ("on it", "answer", "in", "the one answer to every call"),
    ("can't", "answer", "in", "an answer that says why is a refusal that is not rude"),
    ("falling back", "report", "in", "the report a bot owes you before it leaves a fight"),
    ("sorry", "courtesy", "in", "a teamkill with a bomb is the moment for it, and it is already on the wire"),
    ("cover me", "call", "out", "follow me from the other side of the same ask"),
    ("regroup", "call", "out", "retreat! and hold here between them say it"),
    ("spread out", "call", "out", "nothing a bot can do with it that reads as obeying"),
    ("take the flag", "call", "out", "attack! at a flag; a per-zone list is a second list to hold"),
    ("guard the flag", "call", "out", "hold here at a flag"),
    ("go go go", "call", "out", "attack!"),
    ("coming", "answer", "out", "on it"),
    ("with you", "answer", "out", "on it"),
    ("no", "answer", "out", "can't says the same and is not a snub"),
    ("low energy", "report", "out", "help! is the ask; the bar is nobody else's business"),
    ("enemy here", "report", "out", "the radar already says it"),
    ("got the flag", "report", "out", "the pennants in the band already say it"),
    ("nice shot", "courtesy", "podium", "a fight's compliment is the kill line; stays on the podium"),
    ("gg / thanks / good luck / close one", "courtesy", "podium", "decision 51, unchanged"),
]

# What a bot does with what it hears, and what it says back.
BOT_RULES = [
    ("follow me", "Escort: fly to within four tiles of the caller and fight what "
     "fights them, until the caller dies, says anything else, or thirty seconds pass.",
     "on it, or can't while recovering"),
    ("help!", "Take the foe nearest the caller, routing to where the radar puts "
     "them. The radar is how a human would find them too.",
     "on it, or can't while recovering"),
    ("retreat!", "Break off and recover toward the nearest safe zone for ten "
     "seconds, whatever it was doing.", "falling back"),
    ("attack!", "Drop a recovery unless energy is under the reserve, take the nearest "
     "foe or the objective, and hold the engagement fifteen seconds.",
     "on it, or can't"),
    ("hold here", "Station at the caller's position for thirty seconds and fight "
     "what comes into range.", "on it"),
]

BOT_SAYS = [
    ("falling back", "when it begins a retreat with a foe on it, so the human it "
     "was fighting beside is told before the hull turns"),
    ("help!", "when it is recovering with a foe closer than its retreat range and a "
     "teammate on the radar, at most once a life"),
    ("sorry", "on a teamkill"),
    ("gg", "on the podium, and nothing else there"),
]


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
.glass{{border:1px solid rgba(63,88,120,.75);background:rgba(10,15,24,.72);
  backdrop-filter:blur(5px)}}
.key{{display:inline-flex;align-items:center;justify-content:center;gap:7px;
  border:1px solid rgba(63,88,120,.75);background:rgba(10,15,24,.6);
  font-family:var(--mono);text-transform:uppercase;letter-spacing:.06em;
  color:var(--read)}}
table{{border-collapse:collapse}}
td,th{{text-align:left;vertical-align:top;padding:7px 14px 7px 0;
  border-bottom:1px solid rgba(63,88,120,.45);font-size:13px;line-height:19px;
  color:{READ}}}
th{{font-family:var(--mono);font-size:10px;text-transform:uppercase;
  letter-spacing:.14em;color:{DIM};font-weight:normal;padding-top:0}}
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


def bot_mark_svg(x, y, col, k=10):
    """The boxed shell with an antenna the plate draws after a bot's name,
    near enough to judge the line beside it."""
    return (f'<g transform="translate({x:.0f},{y:.0f})" fill="none" '
            f'stroke="{col}" stroke-width="1">'
            f'<rect x="0" y="{-k * .5:.1f}" width="{k * .8:.1f}" height="{k * .6:.1f}"/>'
            f'<path d="M{k * .4:.1f} {-k * .5:.1f} V{-k * .85:.1f}"/>'
            f'<circle cx="{k * .25:.1f}" cy="{-k * .2:.1f}" r=".9" fill="{col}"/>'
            f'<circle cx="{k * .55:.1f}" cy="{-k * .2:.1f}" r=".9" fill="{col}"/></g>')


def plate(x, y, name, col, px=11, bot=False, tier=1228, k=1.0):
    """The nameplate as ui.lua draws it: the name at sx+12, sy+13, in the
    side's color at 0.7, and the seat's mark after it in the band's color."""
    parts = [f'<text x="{x + 12 * k:.0f}" y="{y + 13 * k + px * .35:.0f}" '
             f'font-family="Noto Sans Mono,monospace" font-size="{px}" '
             f'letter-spacing=".04em" fill="{col}" opacity=".7">{name}</text>']
    mx = x + 12 * k + adv(name, px) + 9 * k
    band_col = tier_col(tier)
    if bot:
        parts.append(bot_mark_svg(mx, y + 13 * k, band_col, 10 * k))
    else:
        parts.append(f'<path transform="translate({mx + 5 * k:.0f},{y + 13 * k:.0f})" '
                     f'd="M0 -3.5 L1 2.5 L0 3.5 L-1 2.5 Z M0.6 0 L2.6 3 L1.8 3.5 L0.8 2.5 Z '
                     f'M-0.6 0 L-2.6 3 L-1.8 3.5 L-0.8 2.5 Z" fill="{band_col}" opacity=".55"/>')
    return "".join(parts)


def said(x, y, line, px=11, k=1.0, age=0.0, life=3.0, fade=0.8, own=False):
    """The phrase, one line under the plate, in ink. `age` is how long ago it
    was said; the last `fade` of its life is spent leaving. Your own hull
    wears no plate, so your own line stands on the plate's line."""
    a = 0.9
    left = life - age
    if left < fade:
        a *= max(0.0, left / fade)
    dy = 13 * k if own else 13 * k + 14 * k
    return (f'<text x="{x + 12 * k:.0f}" y="{y + dy + px * .35:.0f}" '
            f'font-family="Noto Sans Mono,monospace" font-size="{px}" '
            f'letter-spacing=".04em" fill="{INK}" opacity="{a:.2f}">{line}</text>')


# name, side, bot?, tier, (offset), heading
SHIPS = [
    ("Gantry", FRIEND, False, 1310, (-260, 90), 24),
    ("Carrack", ENEMY, False, 1494, (210, -40), -140),
    ("Isobar", ENEMY, True, 1120, (330, 150), -95),
    ("Ozone", FRIEND, True, 1228, (-120, 220), 70),
    ("Cirrus", ENEMY, False, 1010, (420, 300), 200),
]


def scene(w, h, seed, compact, lines=None, own=None, shift=(0, 0)):
    """The fight. `lines` maps a name to (phrase, age); `own` is what your
    own hull is saying, if anything; `shift` moves the whole fight so a
    window can center on one hull."""
    lines = lines or {}
    cx, cy = w / 2 - shift[0], h / 2 - shift[1]
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
    px = 9 if compact else 11
    parts.append(hull(cx, cy, -20, FRIEND, 1.15 * k))
    if own:
        parts.append(said(cx, cy, own[0], px, k, own[1], own=True))
    for name, col, bot, tier, (ox, oy), rot in SHIPS:
        x, y = cx + ox * k, cy + oy * k
        if -30 < x < w + 30 and -30 < y < h + 30:
            parts.append(hull(x, y, rot, col, k))
            parts.append(plate(x, y, name, col, px, bot, tier, k))
            if name in lines:
                phrase, age = lines[name]
                parts.append(said(x, y, phrase, px, k, age))
    return (f'<svg width="{w}" height="{h}" class="abs" '
            f'style="left:0;top:0">{"".join(parts)}</svg>')


def radar_side(compact):
    return RADAR_COMPACT if compact else RADAR


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


def radar(w, compact, ring=None):
    """The radar; `ring` names a friendly dot that is calling from off the
    glass, drawn with the ring the call puts on it."""
    side = radar_side(compact)
    x = w - PAD - side
    dots = [(side * .3, side * .35, ENEMY, None),
            (side * .62, side * .58, ENEMY, None),
            (side * .5, side * .5, FRIEND, None),
            (side * .41, side * .72, FRIEND, None),
            (side * .18, side * .82, FRIEND, "Gantry")]
    blips = ""
    for bx, by, col, who in dots:
        blips += f'<circle cx="{bx:.0f}" cy="{by:.0f}" r="2" fill="{col}"/>'
        if who and who == ring:
            blips += (f'<circle cx="{bx:.0f}" cy="{by:.0f}" r="6" fill="none" '
                      f'stroke="{col}" stroke-width="1" opacity=".8"/>'
                      f'<circle cx="{bx:.0f}" cy="{by:.0f}" r="10" fill="none" '
                      f'stroke="{col}" stroke-width="1" opacity=".35"/>')
    return over_dial(w, compact) + (
        f'<svg class="abs" width="{side}" height="{side}" '
        f'style="left:{x}px;top:{PAD + KEY_H}px">'
        f'<rect x="0" y="0" width="{side}" height="{side}" '
        f'fill="rgba(5,7,12,.55)"/>'
        f'<path d="M{side * .2} {side * .3} V{side * .8} M{side * .55} {side * .2} '
        f'H{side * .85}" stroke="{TILE}" stroke-width="3" opacity=".8"/>'
        f'{blips}</svg>')


def feed(w, lines=None):
    lines = lines or [("Carrack killed Ozone", DIM), ("Gantry killed Isobar", DIM),
                      ("Cirrus killed DRiFT (-6)", DIM)]
    y = PAD + KEY_H + RADAR + 12
    return (f'<div class="abs mono" style="right:{PAD}px;top:{y}px;'
            f'text-align:right;font-size:11px;line-height:17px">'
            + "".join(f'<div style="opacity:{1 - .18 * i};color:{c}">{s}</div>'
                      for i, (s, c) in enumerate(lines)) + '</div>')


def corner_stack(h):
    marks = [("#ff5ea8", 3), ("#c27bff", 2), ("#35e0a0", 2)]
    rows = ""
    for col, n in marks:
        pips = "".join(
            f'<span style="width:6px;height:6px;border-radius:50%;'
            f'{"background:#ffe08a" if k < n else "border:1px solid " + DIM}">'
            '</span>' for k in range(3))
        rows += (f'<div class="row" style="gap:14px;height:22px">'
                 f'<svg width="16" height="16" viewBox="0 0 16 16" fill="none" '
                 f'stroke="{col}" stroke-width="1.4"><circle cx="8" cy="8" '
                 f'r="5"/></svg><span class="row" style="gap:5px">{pips}'
                 f'</span></div>')
    return (f'<div class="abs" style="left:{PAD + 8}px;bottom:{PAD + 8}px">'
            f'{rows}</div>')


STACK_H = 3 * 22


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


# --- the badge, ported from pilot_mark in ui.lua (the corner) -----------------

def badge(col, k, alpha=1.0):
    quads = [
        [(0, -0.325), (0.070, 0.225), (0, 0.325), (-0.070, 0.225)],
        [(0.052, -0.005), (0.220, 0.275), (0.170, 0.325), (0.070, 0.225)],
        [(-0.052, -0.005), (-0.220, 0.275), (-0.170, 0.325), (-0.070, 0.225)],
        [(0.118, -0.06), (0.30, 0.10), (0.27, 0.15), (0.12, 0.0)],
        [(0.166, 0.06), (0.36, 0.20), (0.33, 0.25), (0.17, 0.12)],
        [(0.238, 0.18), (0.42, 0.30), (0.39, 0.34), (0.24, 0.24)],
    ]
    quads += [[(-x, y) for x, y in q] for q in quads[3:]]
    paths = "".join(
        '<path d="M' + " L".join(f"{x * k:.2f} {y * k:.2f}" for x, y in q)
        + f' Z" fill="{col}"/>' for q in quads)
    w, h = 1.2 * k, 0.8 * k
    return (f'<svg width="{w:.1f}" height="{h:.1f}" '
            f'viewBox="{-w / 2:.2f} {-h / 2:.2f} {w:.2f} {h:.2f}" '
            f'style="flex:none;opacity:{alpha}">{paths}</svg>')


def corner(px=13):
    at = 1228
    return (f'<div class="abs row" style="left:{PAD}px;top:{PAD}px;'
            f'height:{KEY_H}px;gap:6px">{badge(tier_col(at), MARK_K, .95)}'
            f'<span class="num" style="font-size:{px}px;color:{INK};opacity:.9">'
            f'{at}</span></div>')


def band_row(w, compact, px=13):
    """Decision 163's row, Team Battle: score, name, clock, name, score."""
    line = (f'top:{PAD}px;height:{KEY_H}px;display:flex;align-items:center;'
            f'position:absolute')
    out = [corner(px),
           f'<div class="row" style="{line};left:50%;transform:translateX(-50%)">'
           f'<span class="num" style="font-size:{px}px;color:{READ};opacity:.95">'
           f'2:14</span></div>']
    half = adv("2:14", px) / 2
    gap = 12 if compact else 16
    for i, (name, col, score) in enumerate((("Pylon", FRIEND, 17),
                                            ("Caisson", ENEMY, 20))):
        edge = w / 2 - half - gap if i == 0 else w / 2 + half + gap
        pos = f"right:{w - edge:.0f}px" if i == 0 else f"left:{edge:.0f}px"
        label = "" if compact else (
            f'<span class="hud" style="font-size:{px}px;color:{col};opacity:.85">'
            f'{name}</span>')
        figure = f'<span class="num" style="font-size:{px}px;color:{col}">{score}</span>'
        bits = [figure, label] if i == 0 else [label, figure]
        out.append(f'<div class="row" style="{line};{pos};gap:8px">'
                   f'{"".join(b for b in bits if b)}</div>')
    return "".join(out)


# --- the picker --------------------------------------------------------------
#
# Decision 67's board, the one the band opened before the players sheet took
# the roster into the menu: a column hanging centered under the band, a wash
# of the field color with a lit rule down its left edge and no border, a
# head in dim capitals with a tick rule under it, and rows one HUD line
# tall in the mono. Chris asked for the picker in that grammar, under the
# scoreboard, and this is it.

LINE = 18           # one row of a HUD list, as the board drew it
BOARD_W = 236


def hrule(alpha=".45"):
    return f'<div style="height:1px;background:rgba(63,88,120,{alpha})"></div>'


def ticks(alpha=".35"):
    return (f'<div style="height:4px;background:'
            f'repeating-linear-gradient(90deg,rgba(63,88,120,{alpha}) 0 1px,'
            f'transparent 1px 14px),linear-gradient(rgba(63,88,120,{alpha}),'
            f'rgba(63,88,120,{alpha})) bottom/100% 1px no-repeat"></div>')


def board_row(digit, phrase, cursor=False):
    wash = "background:rgba(79,214,255,.18);" if cursor else ""
    return (f'<div class="row" style="height:{LINE}px;gap:10px;'
            f'padding:0 10px 0 8px;{wash}">'
            f'<span class="num" style="font-size:10px;color:{DIM};width:8px;'
            f'text-align:right">{digit}</span>'
            f'<span class="name" style="font-size:11px;color:{INK};opacity:.9">'
            f'{phrase}</span></div>')


def board_head(word, key):
    right = (f'<span class="hud" style="font-size:10px;color:{DIM}">{key}</span>'
             if key else "")
    return (f'<div class="row hud" style="height:16px;gap:7px;'
            f'padding:0 10px 0 8px"><span class="lbl">{word}</span>'
            f'<div style="flex:1"></div>{right}</div>')


def picker(phrases, cursor=0, width=BOARD_W, key="C"):
    """The board: a head naming it and the key that opened it, the tick
    rule, then a row a phrase. No wash on the fight behind it, since it is
    up for a second and the fight is what you are reading."""
    rows = "".join(board_row(i + 1, p, i == cursor)
                   for i, p in enumerate(phrases))
    return (f'<div style="width:{width}px;background:rgba(5,7,12,.62);'
            f'box-shadow:inset 1.5px 0 0 rgba(63,88,120,.7);padding:6px 0 8px">'
            f'{board_head("Call", key)}{ticks()}{rows}</div>')


def picker_under_band(w, phrases, cursor=0, width=BOARD_W):
    """Hanging centered under the row, where the board hung."""
    x = (w - width) / 2
    return (f'<div class="abs" style="left:{x:.0f}px;top:{PAD + KEY_H + 10}px">'
            f'{picker(phrases, cursor, width)}</div>')


# The earlier pick, kept for the record: the menu language's rows on the
# glass, standing on the left edge over the charge marks.


def column_row(digit, phrase, cursor=False):
    wash = WASH_CURSOR if cursor else ""
    return (f'<div class="row" style="height:{ROW_H}px;padding:0 {ROW_INSET}px;'
            f'gap:12px;{wash}">'
            f'<span class="num" style="font-size:14px;color:{READ};width:12px">'
            f'{digit}</span>'
            f'<span style="font-size:17px;color:{INK};opacity:.85">{phrase}</span>'
            f'</div>')


def column_picker(phrases, cursor=0, width=232, key="C"):
    rows = "".join(column_row(i + 1, p, i == cursor)
                   for i, p in enumerate(phrases))
    return (f'<div class="glass" style="width:{width}px;display:flex;'
            f'flex-direction:column">'
            f'<div class="row" style="height:24px;padding:0 {ROW_INSET}px;'
            f'justify-content:space-between;border-bottom:1px solid '
            f'rgba(63,88,120,.45)"><span class="lbl">Call</span>'
            f'<span class="lbl">{key}</span></div>'
            f'<div style="padding:5px 0">{rows}</div></div>')


def picker_desktop(h, phrases, cursor=0):
    return (f'<div class="abs" style="left:{PAD}px;bottom:{PAD + 8 + STACK_H + 12}px">'
            f'{column_picker(phrases, cursor)}</div>')


def strip_desktop(w, h, phrases, cursor=0):
    """The other earlier pick: chips along the bottom, the digit inside each."""
    chips = "".join(
        f'<span class="key" style="height:30px;padding:0 12px;gap:9px;'
        f'{WASH_CURSOR if i == cursor else ""}'
        f'text-transform:none;letter-spacing:.02em">'
        f'<span class="num" style="font-size:12px;color:{READ}">{i + 1}</span>'
        f'<span style="font-family:var(--menu);font-size:15px;color:{INK}">'
        f'{p}</span></span>' for i, p in enumerate(phrases))
    return (f'<div class="abs row" style="left:50%;bottom:{PAD + 30}px;'
            f'transform:translateX(-50%);gap:6px;white-space:nowrap">{chips}</div>')


def call_key(x, y, lit=False):
    wash = WASH_CURSOR + ";" if lit else ""
    return (f'<div class="abs key" style="left:{x}px;top:{y}px;height:{KEY_H}px;'
            f'padding:0 10px;font-size:10px;{wash}">Call</div>')


def picker_phone(w, phrases, cursor=None):
    """The key stays under the corner; the board hangs under the row as it
    does on a monitor, and a thumb picks a row."""
    top = PAD + KEY_H + 6
    return (call_key(PAD, top, True)
            + f'<div class="abs" style="left:{(w - BOARD_W) / 2:.0f}px;'
            f'top:{top + KEY_H + 6}px">'
            f'{picker(phrases, cursor if cursor is not None else -1, BOARD_W, "")}</div>')


# --- the boards --------------------------------------------------------------


def screen(form, seed=1, lines=None, own=None, feed_lines=None, ring=None,
           pick=None, column=None, strip=None, phone_pick=False, show_key=True):
    w, h = FORMS[form]
    compact = form == "Portrait"
    out = [scene(w, h, 11 + w, compact, lines, own), radar(w, compact, ring)]
    if compact:
        out.append(pads(w, h))
        if show_key and not phone_pick:
            out.append(call_key(PAD, PAD + KEY_H + 6))
        if phone_pick:
            out.append(picker_phone(w, MATCH))
    else:
        out.append(feed(w, feed_lines))
        out.append(corner_stack(h))
        if pick is not None:
            out.append(picker_under_band(w, MATCH, pick))
        if column is not None:
            out.append(picker_desktop(h, MATCH, column))
        if strip is not None:
            out.append(strip_desktop(w, h, MATCH, strip))
    out.append(band_row(w, compact))
    out.append(menu_key(w, h))
    return (f'<div style="position:relative;width:{w}px;height:{h}px;'
            f'overflow:hidden;background-color:{BG};'
            f'background-image:{starfield(w, h, seed + w)}">{"".join(out)}</div>')


STRIP_W, STRIP_H = 720, 170
SHEET_H = 3480


def strip(seed, lines=None, own=None, w=STRIP_W, h=STRIP_H, compact=False,
          shift=(0, 0)):
    """A window on the fight, the phrase under a plate, for the sheet."""
    inner = scene(w, h, seed, compact, lines, own, shift)
    return (f'<div style="position:relative;width:{w}px;height:{h}px;'
            f'overflow:hidden;background-color:{BG};flex:none;'
            f'background-image:{starfield(w, h, seed)}">{inner}</div>')


# --- the sheet ---------------------------------------------------------------


def cap(text, w=None, px=13):
    return (f'<div style="font-size:{px}px;line-height:{px + 6}px;color:{READ};'
            f'{"width:" + str(w) + "px;" if w else ""}text-wrap:pretty">'
            f'{text}</div>')


def title(text):
    return (f'<div class="lbl" style="font-size:11px;letter-spacing:.16em;'
            f'margin-bottom:10px">{text}</div>')


def h1(text):
    return f'<div style="font-size:26px;line-height:32px;color:{INK}">{text}</div>'


def h2(text):
    return f'<div style="font-size:21px;line-height:26px;color:{INK}">{text}</div>'


def gap(h):
    return f'<div style="height:{h}px"></div>'


def cell(html, note):
    return (f'<div style="display:flex;flex-direction:column;gap:6px">'
            f'{html}<span class="lbl" style="letter-spacing:.1em">{note}'
            f'</span></div>')


def flow(cells, w=None):
    return (f'<div style="display:flex;flex-wrap:wrap;gap:14px 16px;'
            f'width:{w or 2 * STRIP_W + 16}px;align-items:flex-start">'
            f'{"".join(cells)}</div>')


def table(head, rows, widths):
    ths = "".join(f'<th style="width:{w}px">{h}</th>' for h, w in zip(head, widths))
    trs = ""
    for r in rows:
        tds = ""
        for i, c in enumerate(r):
            style = ""
            if i == 0:
                style = f'font-family:var(--menu);font-size:15px;color:{INK}'
            elif head[i].lower() == "verdict":
                col = {"in": PAID, "out": DIM, "podium": CHARGE}.get(c, READ)
                style = f'font-family:var(--mono);font-size:11px;text-transform:uppercase;letter-spacing:.1em;color:{col}'
            tds += f'<td style="{style}">{c}</td>'
        trs += f'<tr>{tds}</tr>'
    return f'<table><thead><tr>{ths}</tr></thead><tbody>{trs}</tbody></table>'


# Where the ship under the phrase sits in a strip: the scene puts your own
# hull at the middle and Gantry 260 left, 90 down, so a strip cut to show
# Gantry near its middle is offset accordingly.
def strip_on(name, seed, phrase, age=0.0):
    off = next(sh[4] for sh in SHIPS if sh[0] == name)
    return strip(seed, {name: (phrase, age)}, shift=(off[0] - 60, off[1] - 10))


def main_sheet():
    body = [
        title("Canned phrases · calls during a match"),
        h1("Nine things to say, and a bot that listens"),
        cap("Decision 51 put six phrases on the podium and nothing publishes "
            "them now: the chips went with the ending's card and the key that "
            "was to replace them never came. This is that key, and the other "
            "half of decision 28's reconsider clause with it: a bounded set of "
            "signals to your own side during a match, drawn for three seconds "
            "under the plate of whoever said them. The house bots say them "
            "when their state changes in a way a wingman would call out, and "
            "act on the three Chris named. The wire is decision 51's unchanged: "
            "one byte, an index into a list the client holds, side-only while "
            "a match runs, one every two seconds a seat. Nothing here is built.",
            900),
        gap(26),
        h2("The picker"),
        gap(6),
        cap("It is decision 67's board, the one the band opened before the "
            "players sheet took the roster into the menu: a column hanging "
            "centered under the row, a wash of the field color with a lit "
            "rule down its left edge and no border, a head in dim capitals "
            "with a tick rule under it, and rows one HUD line tall in the "
            "mono. Chris asked for the picker in that grammar, under the "
            "scoreboard. One key opens it and the same key, a pick, escape or "
            "four idle seconds close it. It appears in a frame rather than "
            "sliding, the flight keys keep working under it, and the fight is "
            "not washed behind it, since it is up for a second and the fight "
            "is what you are reading. A digit picks its row, and so do the "
            "arrows and enter, and so does a pointer. Between matches the "
            "same board lists decision 51's six instead, since that is what "
            "the moment allows.", 900),
        gap(12),
        flow([cell(picker(MATCH, 1), "During a match, nine, to your side"),
              cell(picker(PODIUM, 0), "Between matches, the six, to the room")],
             w=900),
        gap(18),
        cap("Two earlier shapes are on the second page for the record: the "
            "menu language's rows on the glass standing on the left edge, and "
            "a strip of chips along the bottom. Both put a second voice on the "
            "HUD; the board is the HUD's own.", 900),
        gap(26),
        h2("The phrase"),
        gap(6),
        cap("One line under the nameplate, in ink rather than the side's "
            "color: the plate says who, the line says what they said, and a "
            "line in the side's color read as a longer name. Eleven points, "
            "the plate's own size, lower case as the podium wrote them. Three "
            "seconds, the last eight tenths spent leaving. Your own hull wears "
            "no plate, so your own line stands where the plate would, which is "
            "how you know it went. The other side never receives a match "
            "phrase, so there is nothing of yours to draw under their hulls.",
            900),
        gap(12),
        flow([
            cell(strip_on("Gantry", 3, "help!"), "A teammate's call, just said"),
            cell(strip_on("Ozone", 4, "on it"), "A bot's answer; the plate's mark says which seat"),
            cell(strip(5, own=("retreat!", 0.0)), "Your own line, on the plate's line"),
            cell(strip_on("Gantry", 6, "help!", 2.6), "The same call, leaving"),
        ]),
        gap(26),
        h2("A caller you cannot see"),
        gap(6),
        cap("The whole point of help! is that the hull calling is not on "
            "your glass. The feed carries the line in the side's color, one "
            "fact as decision 155 asks, and the caller's dot on the radar "
            "wears a ring for as long as the line lives. The ring is the ping "
            "decision 51's reconsider clause asked for, arriving as a side "
            "effect of a word rather than as a feature of its own.", 900),
        gap(12),
        flow([cell(
            f'<div style="position:relative;width:{STRIP_W}px;height:230px;'
            f'overflow:hidden;background-color:{BG};'
            f'background-image:{starfield(STRIP_W, 230, 21)}">'
            + radar(STRIP_W, True, "Gantry")
            + f'<div class="abs mono" style="right:{PAD}px;top:{PAD + KEY_H + RADAR_COMPACT + 12}px;'
            f'text-align:right;font-size:11px;line-height:17px">'
            f'<div style="color:{FRIEND}">Gantry: help!</div>'
            f'<div style="color:{DIM};opacity:.82">Carrack killed Ozone</div></div>'
            '</div>', "The corner, with Gantry off the glass and calling")]),
        gap(26),
        h2("Everything considered"),
        gap(6),
        cap("Nine made it, and each one either does something a bot can be "
            "seen to obey or answers one that does. The rest are the same ask "
            "in other words, a report the HUD already makes, or a courtesy the "
            "podium already carries.", 900),
        gap(12),
        table(["Phrase", "Kind", "Verdict", "Why"], BRAINSTORM, [230, 80, 80, 500]),
        gap(26),
        h2("What a bot does with one"),
        gap(6),
        cap("A bot hears a phrase the way everyone else does, off the wire, "
            "and a phrase becomes an input to the goal its brain already "
            "picks between. That keeps the runtime's one rule: a bot produces "
            "inputs and nothing else. Every bot on the side acts; only the one "
            "nearest the caller answers aloud, so five bots do not say on it "
            "at once. A bot's obedience is not a skill knob, and it has no "
            "lines of its own to speak beyond the list every pilot holds.",
            900),
        gap(12),
        table(["Heard", "Does", "Says"], BOT_RULES, [120, 560, 210]),
        gap(22),
        cap("And unprompted, at most one line a bot every twenty seconds:", 900),
        gap(8),
        table(["Says", "When"], BOT_SAYS, [140, 750]),
        gap(26),
        h2("What it costs"),
        gap(6),
        cap("Decision 51's reconsider clause named a phrase during a match as "
            "chat with a smaller vocabulary, and the AI design says no chat "
            "from bots. Both records change if this ships. The argument for it "
            "is that a phrase to your own side during play is the team signal "
            "decision 28 left open, and a bot saying what its brain is doing "
            "is a state readout in words rather than dialogue: it never says "
            "anything a human on the list could not, and never to the other "
            "side. The moderation surface stays at zero for decision 51's "
            "reason, the shape of the wire.", 900),
        gap(30),
    ]
    return "".join(body)


def page(name, body, w, h):
    return (f'<!doctype html>\n<html>\n<head>\n  <meta charset="utf-8">\n'
            f'  <script src="./support.js"></script>\n</head>\n<body>\n<x-dc>\n'
            f'<helmet>\n  <style>{CSS}</style>\n</helmet>\n'
            f'<div style="position:relative;width:{w}px;min-height:{h}px;'
            f'background:{BG};overflow:hidden">{body}</div>\n'
            f'</x-dc>\n</body>\n</html>\n')


def main():
    boards = []

    def emit(name, title_, body, w, h, x, y):
        (HERE / f"{name}.dc.html").write_text(page(name, body, w, h))
        boards.append(dict(file=f"{name}.dc.html", title=title_, x=x, y=y, w=w, h=h))

    sheet_w = 1552
    emit("Main", "Canned phrases, the sheet",
         f'<div style="padding:34px 40px 40px">{main_sheet()}</div>',
         sheet_w, SHEET_H, 0, 0)

    dx = sheet_w + 100
    emit("Desktop", "Team Battle, monitor: the picker under the row, Gantry calling",
         screen("Desktop", 1, lines={"Gantry": ("help!", 0.4)},
                feed_lines=[("Gantry: help!", FRIEND), ("Carrack killed Ozone", DIM),
                            ("Gantry killed Isobar", DIM)],
                pick=1),
         1440, 810, dx, 0)
    emit("Answered", "A second later: your answer and the bot's",
         screen("Desktop", 2, lines={"Gantry": ("help!", 1.4), "Ozone": ("on it", 0.2)},
                own=("on it", 0.0),
                feed_lines=[("Gantry: help!", FRIEND), ("Carrack killed Ozone", DIM),
                            ("Gantry killed Isobar", DIM)]),
         1440, 810, dx, 930)
    emit("Retreat", "Retreat! called: the side's bots fall back",
         screen("Desktop", 3, lines={"Ozone": ("falling back", 0.3)},
                own=("retreat!", 0.6),
                feed_lines=[("Ozone: falling back", FRIEND), ("Carrack killed Isobar", DIM)]),
         1440, 810, dx, 1860)

    px = dx + 1440 + 100
    emit("Portrait", "Phone: the CALL key and the board under the row",
         screen("Portrait", 5, lines={"Gantry": ("help!", 0.4)}, phone_pick=True),
         390, 844, px, 0)
    emit("PortraitSaid", "Phone: a phrase under a plate",
         screen("Portrait", 6, lines={"Ozone": ("on it", 0.2)}, own=("help!", 0.8)),
         390, 844, px + 470, 0)

    # The earlier shapes, on a page of their own.
    emit("Column", "Earlier: the menu language's rows on the left edge",
         screen("Desktop", 4, lines={"Gantry": ("help!", 0.4)},
                feed_lines=[("Gantry: help!", FRIEND), ("Carrack killed Ozone", DIM)],
                column=1),
         1440, 810, 0, 0)
    boards[-1]["page"] = "page-2"
    emit("Strip", "Earlier: chips along the bottom",
         screen("Desktop", 4, lines={"Gantry": ("help!", 0.4)},
                feed_lines=[("Gantry: help!", FRIEND), ("Carrack killed Ozone", DIM)],
                strip=1),
         1440, 810, 1540, 0)
    boards[-1]["page"] = "page-2"

    (HERE / "canvas.json").write_text(json.dumps(
        {"pages": [{"id": "page-1", "name": "Under the band"},
                   {"id": "page-2", "name": "Earlier directions"}],
         "artboards": boards,
         "launch": {"view": "canvas", "page": "page-1"}}, indent=2) + "\n")
    print(f"wrote {len(boards)} boards")


if __name__ == "__main__":
    main()
