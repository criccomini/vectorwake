#!/usr/bin/env python3
"""Assemble the artboards for the full-screen dropdown mocks.

Shipped as decision 103. A stop used to open a list in place, climbing
upward from its own row over the lockup. A tap slides a panel into view
from below now: the panel is the screen save the padding at the edge,
held to a maximum width, it wears the same frost the stops themselves
wear (the fight dims and blurs behind the glass), its head says the name
of the section with the way back on it, and the other buttons slide out
of view while it stands. Back slides them in again.

One thing changed between these boards and what shipped, and it is on
every board here now: the width is capped at 560. These were drawn full
width, which is right on a phone and wrong on a monitor, and Chris said
so. See `PANEL_MAX` below and in client/arena/ui.lua.

What the grammar buys is stacking: a row that opens something is not a
special case any more. It slides the next panel in the same way, and back
steps one level out. Nothing stacks in the client yet -- LOG IN still
raises a card over the landing -- so the Stacked board is the proposal
for what comes next rather than a picture of what runs.

Six boards: the landing closed, the zone panel open, the account panel
open, one drawn frame of the slide, one drawn frame of a stack going up,
and the zone panel on a phone.

The design system is lifted from ../pilot-dropdown/build.py, which
lifted it from the real client: client/arena/palette.lua for hues,
client/arena/ui.lua for the stops and their frost, docs/design/ships.md
for hull extents, the lockup verbatim from docs/banner.svg. The panel
head's back mark is the game menu's (../game-menu), the same grammar the
in-match settings page already wears. Zone rows carry the format strip
the games list carries (decision 82): teams and time in the catalog's
own words.

Rebuild with: python3 build.py
"""

import random
from pathlib import Path

HERE = Path(__file__).parent

FORMS = {
    "Desktop": (1440, 810, False),
    "Phone": (390, 844, True),
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
  --rule:#3f5878; --bounty:#ffe08a;
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
   with a wash inside it. ui.lua key_cap(). */
.key{display:inline-flex;align-items:center;justify-content:center;gap:7px;
  border:1px solid rgba(63,88,120,.75);background:rgba(10,15,24,.6);
  font-family:var(--mono);text-transform:uppercase;letter-spacing:.06em;
  color:#9fb6d4}

/* A stop on the landing: label at one end, the current answer and a caret
   at the other. Frosted the way the shipped stops are: the fight blurs
   behind the glass. */
.field{display:flex;align-items:center;justify-content:space-between;
  border:1px solid rgba(63,88,120,.75);background:rgba(8,12,20,.66);
  backdrop-filter:blur(5px);
  font-family:var(--mono);text-transform:uppercase;letter-spacing:.06em;
  padding:0 12px;color:var(--ink)}

/* The open panel: a stop grown to the screen. Same glass as .field on
   purpose, that is the ask: the dropdown wears the buttons' own frost
   rather than the near-opaque ground the in-place lists used. */
.panel{position:absolute;border:1px solid rgba(63,88,120,.75);
  background:rgba(8,12,20,.66);backdrop-filter:blur(5px);
  display:flex;flex-direction:column;overflow:hidden}
.phead{display:flex;align-items:center;gap:10px;flex:none;
  padding:0 14px;border-bottom:1px solid rgba(63,88,120,.6)}
.prow{display:flex;align-items:center;gap:10px;flex:none;
  font-family:var(--mono);letter-spacing:.06em;
  padding:0 14px;color:#9fb6d4}

/* The one press this screen exists for. ui.lua landing(). */
@keyframes breath{
  0%,100%{background:rgba(79,214,255,.06);
    border-color:rgba(79,214,255,.62)}
  50%{background:rgba(79,214,255,.18);
    border-color:rgba(79,214,255,1)}
}
.play{display:flex;align-items:center;justify-content:center;
  border:1.6px solid rgba(79,214,255,.62);backdrop-filter:blur(5px);
  animation:breath 2.42s ease-in-out infinite;
  font-family:var(--mono);letter-spacing:.14em;color:var(--ink)}
"""

# --- small marks. ui.lua helm(), the caret, and the way-back triangle --------


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


def caret(col="#9fb6d4", k=9):
    return (f'<svg width="{k}" height="{k}" viewBox="0 0 10 10" fill="none" '
            f'style="flex:none"><path d="M1.5 3 L5 7 L8.5 3" stroke="{col}" '
            f'stroke-width="1.4" stroke-linecap="square"/></svg>')


# The way back, the game menu's own mark: the in-match settings page heads
# itself with this triangle and its section name, and the panel repeats
# that grammar exactly.
def back_tri(a=1.0):
    return (f'<svg width="11" height="12" viewBox="0 0 11 12" '
            f'style="flex:none"><polygon points="2,6 9,1.5 9,10.5" '
            f'fill="rgba(79,214,255,{a})"/></svg>')


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
    h = round(w * 88 / 616)
    return (f'<svg width="{w}" height="{h}" viewBox="332 71 616 88" '
            f'style="display:block">'
            f'<g transform="translate(334.975 83) scale(.7115)">{MARK_PATHS}</g>'
            f'{WORD_PATH}</svg>')


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
        # And off the foot, where the stops sit: a wall's outline behind one
        # pressable word reads as a box that word never had.
        if abs(x + bw / 2 - cx) < 340 and y + bh > h - 250:
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


# --- the watcher's chrome, from ../spectator-landing -------------------------


def corner_row(compact):
    kh, px = (22, 9) if compact else (26, 11)
    mk = 10 if compact else 12
    return f"""
  <div class="row" style="position:absolute;left:14px;top:14px;gap:8px">
    <div class="key" style="height:{kh}px;padding:0 9px;font-size:{px}px">PLAYERS
      {helm('#9fb6d4', mk)}<span style="margin-left:-4px">3</span>
      {bot('#9fb6d4', mk)}<span style="margin-left:-4px">5</span></div>
  </div>"""


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
    a, ca, b, cb, _ = FEED[0]
    return (f'<div class="row" style="position:absolute;top:29%;left:50%;'
            f'transform:translateX(-50%);gap:0">'
            f'<span class="num" style="font-size:10px;color:{ca}">{a}</span>'
            f'<span class="num dim" style="font-size:10px">&nbsp;killed&nbsp;</span>'
            f'<span class="num" style="font-size:10px;color:{cb}">{b}</span></div>')


def play_key(w, h, px, extra_style=""):
    return (f'<div class="play" style="width:{w}px;height:{h}px;'
            f'font-size:{px}px;{extra_style}">PLAY NOW</div>')


# --- the stops ---------------------------------------------------------------
# Who the player is on every board: Vesper 412, bound for Team Battle,
# arriving as a Wedge. A call sign, a game and a hull all stand in the
# case they were given, the way the shipped stops draw them raw.

NAME, ZONE, SHIP = "Vesper 412", "Team Battle", "Wedge"

# Row states, decision 72: the row the cursor is on washes at 0.18, the
# row you are already in at 0.07.
WASH_CURSOR = "background:rgba(79,214,255,.18);color:var(--ink)"
WASH_HERE = "background:rgba(79,214,255,.07)"


def stop_row(label, value, w, h, px=12, style="", warn=False, alpha=None):
    """A closed stop: label at the left edge, the answer and a caret at
    the right, in one .field rectangle. `warn` is the dot a guest with
    something to lose gets; `alpha` fades a stop mid-slide."""
    fade = f"opacity:{alpha};" if alpha is not None else ""
    dot = ('<span style="width:5px;height:5px;border-radius:50%;'
           'background:var(--bounty);flex:none;margin-right:7px"></span>'
           ) if warn else ""
    return (f'<div class="field" style="width:{w}px;height:{h}px;{fade}{style}">'
            f'<span class="row">{dot}<span class="lbl">{label}</span></span>'
            f'<span class="row" style="gap:9px;font-size:{px}px;'
            f'text-transform:none">{value}{caret()}</span></div>')


# --- the panel ---------------------------------------------------------------


def panel_head(label, h=46, px=10):
    """The panel's first row: the way back and the section's name, the
    grammar the in-match settings page already wears. The whole row is
    the press that steps one level out."""
    return (f'<div class="phead" style="height:{h}px">{back_tri()}'
            f'<span class="lbl" style="font-size:{px}px;'
            f'color:#9fb6d4">{label}</span></div>')


def panel_row(html, h, px=13, state=None):
    wash = {"cursor": WASH_CURSOR, "here": WASH_HERE}.get(state, "")
    return (f'<div class="prow" style="height:{h}px;font-size:{px}px;'
            f'{wash}">{html}</div>')


def panel_rule():
    return ('<div style="height:1px;margin:5px 14px;flex:none;'
            'background:rgba(63,88,120,.6)"></div>')


# The measure the panel is held to, which is the one thing Chris changed
# between these boards and what shipped. Full width is right on a phone
# and wrong on a monitor: a row eleven hundred points wide sets a name at
# one end and its figure at the other, two things too far apart to read
# as one row. Capped, the panel stands in the middle with the room
# showing either side, which is what the frost was for. 560 in the client
# (`PANEL_MAX` in ui.lua), and the same here.
PANEL_MAX = 560


def full_panel(w, h, edge, label, rows, rise=None, head_h=46):
    """The screen's worth of glass, less the padding at the edge and held
    to a maximum width. `rise` draws it mid-slide instead: risen that many
    pixels off the bottom edge, on its way up."""
    pw = min(w - 2 * edge, PANEL_MAX)
    left = (w - pw) / 2
    top = edge if rise is None else h - rise
    pos = (f"left:{left:.0f}px;width:{pw:.0f}px;top:{top:.0f}px;"
           f"bottom:{edge}px")
    return (f'<div class="panel" style="{pos}">'
            + panel_head(label, head_h)
            + '<div style="padding:6px 0;display:flex;'
            'flex-direction:column">' + "".join(rows) + '</div></div>')


# --- the rows each section holds ---------------------------------------------


def zone_rows(rh, px=13):
    """The games list, decision 98's one list: every game named rather
    than described, the format strip riding at the right edge in the
    catalog's own words (decision 82). Team Battle is the row you are
    already in; the cursor rests on Duel."""
    def strip(text):
        return (f'<span class="num dim" style="margin-left:auto;'
                f'font-size:{px - 2}px">{text}</span>')
    return [
        panel_row('<span style="color:var(--friend)">Team Battle</span>'
                  + strip("4v4 · 3 min"), rh, px, state="here"),
        panel_row('<span style="color:var(--ink)">Duel</span>'
                  + strip("1v1 · 3 min"), rh, px, state="cursor"),
    ]


def account_rows(rh, px=13):
    """The account acts, decision 99: acts on the account you are above
    a rule, ways of being somebody else below it. The guest's offer
    wears the caution color the stop's dot is written in. LOG IN is the
    row the stacked board opens."""
    note = (f'<span class="num dim" style="margin-left:auto;'
            f'font-size:{px - 2}px">')
    return [
        panel_row(f'<span style="color:var(--bounty)">SIGN UP</span>'
                  f'{note}KEEP YOUR POINTS</span>', rh, px, state="cursor"),
        panel_row('<span>NEW NAME</span>', rh, px),
        panel_rule(),
        panel_row('<span>LOG IN</span>', rh, px),
    ]


def login_rows(rh, px=13):
    """What the stacked panel holds: the log-in card's two fields as
    panel rows, and the act at the foot. Today these live on a card over
    the landing with no ground behind it; stacking makes them one more
    panel."""
    def field(label, value, dimmed=False):
        col = "var(--dim)" if dimmed else "var(--ink)"
        return (f'<div style="padding:10px 14px 0">'
                f'<div class="lbl">{label}</div>'
                f'<div class="num" style="font-size:{px}px;color:{col};'
                f'height:30px;display:flex;align-items:center;'
                f'border-bottom:1px solid rgba(63,88,120,.75)">{value}</div>'
                f'</div>')
    return [
        field("CALL SIGN", "Vesper 412"),
        field("PASSWORD", "&middot;&middot;&middot;&middot;&middot;&middot;",
              dimmed=True),
        (f'<div style="padding:18px 14px 0">'
         f'<div class="key" style="height:{rh}px;padding:0 26px;'
         f'font-size:{px - 1}px">LOG IN</div></div>'),
    ]


# --- the boards --------------------------------------------------------------


def chrome(w, h, compact, portrait, seed):
    body = [scene(w, h, compact, seed), corner_row(compact),
            score_band(compact, portrait), radar_feed(compact, portrait)]
    if compact:
        body.append(toast())
    return body


def wrap(w, h, body, seed=28):
    stars = starfield(w, h, *((30, 20, 8) if w < 900 else (46, 30, 12)),
                      seed=seed)
    return (f'<div style="position:absolute;left:0;top:0;width:{w}px;'
            f'height:{h}px;overflow:hidden;background-color:var(--bg);'
            f'background-image:{stars}">{"".join(body)}</div>')


def center(bottom, w):
    return (f'position:absolute;left:50%;transform:translateX(-50%);'
            f'bottom:{bottom}px;width:{w}px')


def column(form, slide=0):
    """The landing's column as shipped: PLAY NOW at the foot, the three
    stops over it, the lockup over those. `slide` sinks the whole set
    that many pixels below its rest position, fading as it goes: one
    drawn frame of the buttons on their way out."""
    w, h, compact = FORMS[form]
    portrait = form == "Phone"
    kw = (w - 28) if portrait else 320
    kh = 50 if portrait else 54
    rh = 44 if portrait else 36
    gap = 8
    alpha = None if slide == 0 else max(0.0, 1 - slide / 260)
    fade = f"opacity:{alpha};" if alpha is not None else ""
    body = [play_key(kw, kh, 16 if portrait else 19,
                     center(22 - slide, kw) + f";{fade}")]
    y = 22 + kh + 12 - slide
    for label, value, warn in [("SHIP", SHIP, False), ("ZONE", ZONE, False),
                               ("ACCOUNT", NAME, True)]:
        body.append(stop_row(label, value, kw, rh, style=center(y, kw),
                             warn=warn, alpha=alpha))
        y += rh + gap
    body.append(f'<div style="position:absolute;left:50%;'
                f'transform:translateX(-50%);bottom:{y + 8}px;{fade}">'
                f'{lockup(150 if portrait else 208)}</div>')
    return body


def closed_board(form):
    w, h, compact = FORMS[form]
    portrait = form == "Phone"
    body = chrome(w, h, compact, portrait, 5 if portrait else 3)
    body += column(form)
    return wrap(w, h, body)


def open_board(form, section):
    """A stop's panel standing: the whole screen less the edge padding,
    the buttons gone below the bottom edge, the section's name and the
    way back at the head. The fight reads on through the glass, blurred
    the way it blurs behind a stop."""
    w, h, compact = FORMS[form]
    portrait = form == "Phone"
    edge = 12 if portrait else 14
    rh = 48 if portrait else 44
    body = chrome(w, h, compact, portrait, 5 if portrait else 3)
    rows = zone_rows(rh) if section == "ZONE" else account_rows(rh)
    body.append(full_panel(w, h, edge, section, rows))
    return wrap(w, h, body)


def midslide_board(form):
    """One drawn frame of the motion. The tap was on ZONE: the column is
    sinking below the bottom edge, fading as it goes, and the panel is
    rising over it from the same edge, its head already reading where
    you are. Back plays the same frame the other way round."""
    w, h, compact = FORMS[form]
    portrait = form == "Phone"
    edge = 12 if portrait else 14
    rh = 48 if portrait else 44
    body = chrome(w, h, compact, portrait, 5 if portrait else 3)
    body += column(form, slide=130)
    body.append(full_panel(w, h, edge, "ZONE", zone_rows(rh), rise=210))
    return wrap(w, h, body)


def stacked_board(form):
    """What the grammar buys: a row that opens something slides the next
    panel in the same way. The account panel stands; LOG IN was pressed;
    its panel is rising over the account panel from the bottom edge.
    Back steps one level out: log in, then account, then the buttons."""
    w, h, compact = FORMS[form]
    portrait = form == "Phone"
    edge = 12 if portrait else 14
    rh = 48 if portrait else 44
    body = chrome(w, h, compact, portrait, 5 if portrait else 3)
    body.append(full_panel(w, h, edge, "ACCOUNT", account_rows(rh)))
    body.append(full_panel(w, h, edge, "LOG IN",
                           login_rows(34 if portrait else 30), rise=280))
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
    page("Closed", closed_board("Desktop"))
    page("Main", open_board("Desktop", "ZONE"))
    page("Account", open_board("Desktop", "ACCOUNT"))
    page("MidSlide", midslide_board("Desktop"))
    page("Stacked", stacked_board("Desktop"))
    page("Phone", open_board("Phone", "ZONE"))
    print("six artboards written")


if __name__ == "__main__":
    main()
