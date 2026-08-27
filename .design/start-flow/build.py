#!/usr/bin/env python3
"""Assemble the nine .dc.html artboards for the start flow mocks.

The proposal: the landing's foot grows three stops between the lockup and
PLAY NOW, so a first visit sees every choice the screen can make without
opening the drawer. In the order you would say them: who you are (account),
where you are going (zone), what you arrive as (ship, listing the pilot's
saved builds by the names they gave them, with SPECTATE as the last row,
exactly as the ship page's own last cell has it). Pressing account opens the
account menu; pressing zone drops the games list; pressing ship drops the
builds. PLAY NOW stays the one celebrated key, and a press on a zone in the
list means fly there, not watch it.

Three directions, each drawn closed, open, and on a phone held upright:

  A  Column   the three stops stack over PLAY NOW like a boarding card
  B  Rail     one console band along the foot ending in PLAY NOW
  C  Sentence one line of pressable words between the lockup and the key,
              the closest to what ships today

Drawings of a proposal, not a plan of record. The design system is lifted
from ../spectator-landing/build.py, which lifted it from the real client:
client/arena/palette.lua for hues, client/arena/ui.lua for panel geometry,
docs/design/ships.md for hull extents, the lockup verbatim from
docs/banner.svg, sides from the melee zone's catalog. The PLAY NOW key
breathes exactly as the shipped landing's does. The dropdown rows wear the
menu's own row states from decision 72: the row the cursor is on washes at
0.18, the row you are already in at 0.07.

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
   with a wash inside it. ui.lua key_cap(). */
.key{display:inline-flex;align-items:center;justify-content:center;gap:7px;
  border:1px solid rgba(63,88,120,.75);background:rgba(10,15,24,.6);
  font-family:var(--mono);text-transform:uppercase;letter-spacing:.06em;
  color:#9fb6d4}

/* A stop on the landing: label at one end, the current answer and a caret
   at the other. Same rectangle as .key, roomier inside. */
.field{display:flex;align-items:center;justify-content:space-between;
  border:1px solid rgba(63,88,120,.75);background:rgba(8,12,20,.66);
  font-family:var(--mono);text-transform:uppercase;letter-spacing:.06em;
  padding:0 12px;color:var(--ink)}

/* An open list: the drawer's glass, the menu's row states (decision 72). */
.drop{position:absolute;background:rgba(6,9,15,.97);
  border:1px solid rgba(63,88,120,.85)}
.drow{display:flex;align-items:center;gap:10px;
  font-family:var(--mono);text-transform:uppercase;letter-spacing:.06em;
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

# --- small marks. ui.lua helm(), and a caret every closed stop wears ---------


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


def eye(col="#9fb6d4", k=13):
    """Spectate: watching from nobody's cockpit."""
    return (f'<svg width="{k}" height="{k}" viewBox="0 0 14 14" fill="none" '
            f'style="flex:none">'
            f'<path d="M1.2 7 C3 4 5 2.8 7 2.8 C9 2.8 11 4 12.8 7 '
            f'C11 10 9 11.2 7 11.2 C5 11.2 3 10 1.2 7 Z" stroke="{col}" '
            f'stroke-width="1.1"/>'
            f'<circle cx="7" cy="7" r="1.8" fill="{col}"/></svg>')


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


# --- the three stops and their open lists ------------------------------------
# What the player currently is, on every board: a guest called Vesper 412,
# bound for Team Battle, arriving as their Gunner build.

NAME, ZONE, SHIP = "Vesper 412", "Team Battle", "Gunner"

# The pilot's own saved builds from the hangar, by the names they gave them.
# Which hull each rides is the hangar's business, not this list's.
PROFILES = ["Gunner", "Bomber", "Brawler", "Scout"]

ZONES = [
    ("Team Battle", "4V4 · 3:00"),
    ("Duel", "1V1 · RATED"),
]

# Row states, decision 72: the row the cursor is on washes at 0.18, the row
# you are already in at 0.07.
WASH_CURSOR = "background:rgba(79,214,255,.18);color:var(--ink)"
WASH_HERE = "background:rgba(79,214,255,.07)"


def stop_row(label, value, w, h, px=12, lit=False, style=""):
    """A closed stop: label at the left edge, the answer and a caret at the
    right, in one .key rectangle. `lit` is the stop whose list is open."""
    edge = "border-color:rgba(79,214,255,.85);" if lit else ""
    return (f'<div class="field" style="width:{w}px;height:{h}px;{edge}{style}">'
            f'<span class="lbl">{label}</span>'
            f'<span class="row" style="gap:9px;font-size:{px}px">{value}'
            f'{caret()}</span></div>')


def drop_rows(rows, w, row_h, px, style):
    """An open list over the glass. rows: (html, state) where state is
    "cursor", "here", "rule" (a separator line) or None."""
    out = []
    for html, state in rows:
        if state == "rule":
            out.append('<div style="height:1px;margin:4px 12px;'
                       'background:rgba(63,88,120,.6)"></div>')
            continue
        wash = WASH_CURSOR if state == "cursor" else (WASH_HERE if state == "here" else "")
        out.append(f'<div class="drow" style="height:{row_h}px;font-size:{px}px;'
                   f'{wash}">{html}</div>')
    return (f'<div class="drop" style="width:{w}px;{style};'
            f'padding:5px 0">{"".join(out)}</div>')


def zone_rows(px=12):
    """The games, exactly the play page's rows minus the format stacks: name
    and the one-line format. A press means fly there."""
    rows = []
    for name, fmt in ZONES:
        cur = name == ZONE
        val = (f'<span style="color:{"var(--friend)" if cur else "inherit"}">'
               f'{name.upper()}</span>'
               f'<span class="dim" style="margin-left:auto;font-size:{px - 2}px">'
               f'{fmt}</span>')
        rows.append((val, "here" if cur else "cursor"))
    return rows


def ship_rows(px=12):
    """The pilot's saved builds and SPECTATE, the ship page's own last cell:
    what you will arrive as. Names alone, no hulls: which hull a build rides
    is the hangar's business."""
    rows = []
    for name in PROFILES:
        cur = name == SHIP
        val = (f'<span style="color:{"var(--friend)" if cur else "inherit"}">'
               f'{name.upper()}</span>')
        rows.append((val, "here" if cur else ("cursor" if name == "Bomber"
                                              else None)))
    rows.append(("", "rule"))
    rows.append((f'{eye()}<span>SPECTATE</span>', None))
    return rows


def account_rows(px=12):
    """A guest's account menu: who you are, then what claiming buys. The
    sign up row wears the offer green the invite band uses (decision 80)."""
    head = f'<span style="color:var(--ink)">{NAME.upper()}</span>' 
    return [
        (head, None),
        ("", "rule"),
        ('<span style="color:var(--prize)">SIGN UP</span>'
         '<span class="dim" style="margin-left:auto;font-size:10px">'
         'KEEP YOUR POINTS</span>', "cursor"),
        ("<span>LOG IN</span>", None),
        ("<span>NEW NAME</span>", None),
    ]


# --- the three directions ----------------------------------------------------


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


def column(form, open_list=None):
    """A: the boarding card. Lockup, then the three stops in the order you
    would say them, then PLAY NOW, all one column at the key's own width."""
    w, h, compact = FORMS[form]
    portrait = form == "Phone"
    body = chrome(w, h, compact, portrait, 5 if portrait else 3)
    kw = (w - 28) if portrait else 320
    kh = 50 if portrait else 54
    rh = 44 if portrait else 36
    gap = 8
    body.append(play_key(kw, kh, 16 if portrait else 19, center(22, kw)))
    stops = [
        ("SHIP", SHIP.upper()),
        ("ZONE", ZONE.upper()),
        ("ACCOUNT", NAME.upper()),
    ]
    bottoms = {}
    y = 22 + kh + 12
    for label, value in stops:
        bottoms[label] = y
        body.append(stop_row(label, value, kw, rh,
                             lit=(open_list == label.lower()),
                             style=center(y, kw)))
        y += rh + gap
    body.append(f'<div style="position:absolute;left:50%;'
                f'transform:translateX(-50%);bottom:{y + 8}px">'
                f'{lockup(150 if portrait else 208)}</div>')
    if open_list == "zone":
        body.append(drop_rows(zone_rows(), kw, 34, 12,
                              center(bottoms["ZONE"] + rh + 6, kw)))
    return wrap(w, h, body)


def rail(form, open_list=None):
    """B: one console band along the foot. The mark, the three stops as
    chips, PLAY NOW at the end of the line; the fight stays clear above."""
    w, h, compact = FORMS[form]
    portrait = form == "Phone"
    body = chrome(w, h, compact, portrait, 5 if portrait else 3)
    if portrait:
        # The band cannot hold five things and a key on a phone: the chips
        # drop their labels and take a slim row of their own over the
        # full-width key, the mark standing in for the word.
        kw = w - 28
        body.append(play_key(kw, 50, 16, center(22, kw)))
        chips = (
            f'<div class="row" style="{center(84, kw)};height:40px;gap:6px;'
            f'justify-content:center">'
            f'{mark_only(20)}'
            f'<div class="field" style="height:40px;padding:0 10px;gap:8px;'
            f'font-size:11px">{NAME.upper()}{caret()}</div>'
            f'<div class="field" style="height:40px;padding:0 10px;gap:8px;'
            f'font-size:11px">{ZONE.upper()}{caret()}</div>'
            f'<div class="field" style="height:40px;padding:0 10px;gap:8px;'
            f'font-size:11px;'
            f'{"border-color:rgba(79,214,255,.85)" if open_list == "ship" else ""}">'
            f'{SHIP.upper()}{caret()}</div></div>')
        body.append(chips)
        if open_list == "ship":
            body.append(drop_rows(ship_rows(), 210, 34, 12,
                                  "right:14px;bottom:132px"))
        return wrap(w, h, body)

    def chip(label, value, lit=False):
        edge = "border-color:rgba(79,214,255,.85);" if lit else ""
        return (f'<div class="field" style="height:44px;padding:0 12px;{edge}'
                f'flex:none;flex-direction:column;align-items:flex-start;'
                f'justify-content:center;gap:2px">'
                f'<span class="lbl" style="font-size:8px">{label}</span>'
                f'<span class="row" style="gap:8px;font-size:12px;'
                f'white-space:nowrap">{value}{caret()}</span></div>')

    ship_val = SHIP.upper()
    band = (
        f'<div class="row" style="position:absolute;left:50%;'
        f'transform:translateX(-50%);bottom:22px;gap:10px;align-items:center">'
        f'{lockup(150)}'
        f'<div style="width:8px"></div>'
        f'{chip("ACCOUNT", NAME.upper())}'
        f'{chip("ZONE", ZONE.upper())}'
        f'{chip("SHIP", ship_val, lit=(open_list == "ship"))}'
        f'<div style="width:8px"></div>'
        f'{play_key(240, 54, 17)}</div>')
    body.append(band)
    if open_list == "ship":
        # Over its own chip: the band runs 150+8+10*4+~146+~130+~120+8+240
        # wide, so the ship chip's left edge sits near the band's middle.
        body.append(drop_rows(ship_rows(), 210, 34, 12,
                              "left:calc(50% + 40px);bottom:84px"))
    return wrap(w, h, body)


def line(form, open_list=None):
    """C: the sentence. The shipped landing exactly as it is, with one line
    of pressable words between the lockup and the key: who, where, what."""
    w, h, compact = FORMS[form]
    portrait = form == "Phone"
    body = chrome(w, h, compact, portrait, 5 if portrait else 3)
    kw = (w - 28) if portrait else 320
    kh = 50 if portrait else 54
    body.append(play_key(kw, kh, 16 if portrait else 19, center(22, kw)))

    def seg(text, lit=False):
        col = "var(--ink)" if lit else "#9fb6d4"
        edge = "rgba(79,214,255,.85)" if lit else "rgba(159,182,212,.45)"
        return (f'<span class="row" style="gap:6px;font-family:var(--mono);'
                f'font-size:12px;letter-spacing:.06em;color:{col};'
                f'white-space:nowrap;'
                f'padding-bottom:3px;border-bottom:1px dotted {edge}">'
                f'{text}{caret()}</span>')

    dot = '<span class="dim" style="margin:0 10px">·</span>'
    sent_y = 22 + kh + 16
    sentence = (f'<div class="row" style="position:absolute;left:50%;'
                f'transform:translateX(-50%);bottom:{sent_y}px;'
                f'justify-content:center">'
                f'{seg(NAME.upper(), lit=(open_list == "account"))}{dot}'
                f'{seg(ZONE.upper(), lit=(open_list == "zone"))}{dot}'
                f'{seg(SHIP.upper(), lit=(open_list == "ship"))}</div>')
    body.append(sentence)
    body.append(f'<div style="position:absolute;left:50%;'
                f'transform:translateX(-50%);bottom:{sent_y + 24 + 14}px">'
                f'{lockup(150 if portrait else 208)}</div>')
    if open_list == "account":
        # Over the first segment: the sentence centers on the key, so the
        # name's stretch sits left of middle.
        off = "left:calc(50% - 180px)" if not portrait else "left:14px"
        body.append(drop_rows(account_rows(), 230, 34, 12,
                              f'{off};bottom:{sent_y + 24}px'))
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
    page("Main", column("Desktop"))
    page("ColumnOpen", column("Desktop", open_list="zone"))
    page("ColumnPhone", column("Phone"))
    page("Rail", rail("Desktop"))
    page("RailOpen", rail("Desktop", open_list="ship"))
    page("RailPhone", rail("Phone"))
    page("Line", line("Desktop"))
    page("LineOpen", line("Desktop", open_list="account"))
    page("LinePhone", line("Phone"))
    print("nine artboards written")


if __name__ == "__main__":
    main()
