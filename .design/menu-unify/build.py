#!/usr/bin/env python3
"""Assemble the nine .dc.html artboards for the menu unification mocks.

The premise: the menu is designed once, at the phone's own measure of 390
points, with the name and the call sign at its head, the page in the middle,
and the six stops at its foot. The question the boards ask is where that
column stands, three window shapes by three answers:

  Dock     on the left edge, full height. Upright it takes the whole window,
           which is the shipped narrow layout; everywhere else the fight
           keeps the rest of the glass.
  Card     floating in the middle, clamped to 390 by 560, the glass dimmed a
           step around it. The most modal of the three.
  Console  the six stops and PLAY NOW live on a bar that never leaves the
           glass, and a tab raises a sheet rather than a screen.

Drawings of a proposal, not a plan of record. The design system is lifted
from ../spectator-landing/build.py, which lifted it from the real client:
client/arena/palette.lua for hues, client/arena/ui.lua for panel geometry,
docs/design/ships.md for hull extents, docs/banner.svg for the lockup, and
catalog/zones/*/zone.toml for the zones and their sentences. Every board
shows the play page open over a live melee, because the stands are the front
end now (decision 61) and changing a ship or a zone should not mean leaving
them.

Rebuild with: python3 build.py
"""

import random
from pathlib import Path

HERE = Path(__file__).parent

# --- the three windows -------------------------------------------------------
FORMS = {
    "Desktop":   (1440, 810, False),
    "Landscape": (844, 390, True),
    "Portrait":  (390, 844, True),
}

RULE = "rgba(63,88,120,.6)"

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

/* The one press a screen exists for. Fill and edge swell on the tally's
   slow beat: sin at 2.6 rad/s is a 2.42s period, and the trough is floored
   well above dark so it never reads as a key that stopped working. */
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
    """Mark and word together, w px wide, transparent ground."""
    h = round(w * 88 / 616)
    return (f'<svg width="{w}" height="{h}" viewBox="332 71 616 88" '
            f'style="display:block;flex:none">'
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


# --- the room: eight seats, four a side, camera on the channel's subject -----
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


def scene(w, h, compact, seed, shift=0):
    """The fight behind the glass. `shift` slides the camera's subject right,
    for a board whose left side a panel is standing on."""
    cx, cy = w / 2 + shift, h / 2
    rnd = random.Random(seed)
    parts = []
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


def corner_row(compact, menu=True):
    """The top left corner. With `menu` false the MENU key is gone, for the
    console boards, where the bar is that key."""
    kh, px = (22, 9) if compact else (26, 11)
    mk = 10 if compact else 12
    tri_h = 9 if compact else 11
    menu_key = (f'<div class="key" style="height:{kh}px;padding:0 9px;'
                f'font-size:{px}px">MENU</div>') if menu else ""
    return f"""
  <div class="row" style="position:absolute;left:14px;top:14px;gap:8px">
    {menu_key}
    <div class="key" style="height:{kh}px;padding:0 9px;font-size:{px}px">PLAYERS
      {helm('#9fb6d4', mk)}<span style="margin-left:-4px">3</span>
      {bot('#9fb6d4', mk)}<span style="margin-left:-4px">5</span></div>
    <div class="row" style="gap:6px;margin-left:4px">
      <svg width="{tri_h}" height="{tri_h}" viewBox="0 0 10 12">
        <path d="M0 0 L10 6 L0 12 Z" fill="#8dffb0" opacity=".92"/></svg>
      <span class="hud" style="font-size:{px}px;color:#8dffb0;opacity:.92">CHANNEL</span>
    </div>
  </div>"""


def score_band(compact, portrait=False, cx=None):
    """The clock and the score. `cx` recenters the band, for a board whose
    glass no longer starts at the window's left edge."""
    big, mid, name = (22, 17, 9) if compact else (34, 30, 11)
    gap = 12 if compact else 22
    top = 46 if portrait else (10 if compact else 14)
    pos = (f"left:{cx}px" if cx is not None else "left:50%")
    left = (f'<div class="hud num" style="font-size:{name}px;'
            f'color:var(--friend)">PYLON</div>') if not portrait else ""
    right = (f'<div class="hud num" style="font-size:{name}px;'
             f'color:var(--enemy)">CAISSON</div>') if not portrait else ""
    return f"""
  <div style="position:absolute;top:{top}px;{pos};
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


# --- the column: the one menu, drawn at the phone's measure ------------------


def pilot_chip():
    """The call sign in the head, which is the way to the pilot page."""
    return (f'<div class="key" style="height:24px;padding:0 9px;font-size:10px;'
            f'gap:6px">{helm("#9fb6d4", 11)}KRAIT 4</div>')


def section(label):
    return (f'<div class="row" style="gap:10px;margin:14px 0 8px">'
            f'<span class="lbl">{label}</span>'
            f'<div style="flex:1;height:1px;background:rgba(63,88,120,.45)">'
            f'</div></div>')


def meter(bright, dimmed):
    """The population meter off the play page: people lit, AI half lit."""
    cells = []
    for i in range(8):
        if i < bright:
            cells.append(f'<rect x="{i * 7}" y="0" width="5" height="9" '
                         f'fill="#4fd6ff"/>')
        elif i < bright + dimmed:
            cells.append(f'<rect x="{i * 7}" y="0" width="5" height="9" '
                         f'fill="#4fd6ff" opacity=".32"/>')
        else:
            cells.append(f'<rect x="{i * 7 + .5}" y=".5" width="4" height="8" '
                         f'fill="none" stroke="{RULE}" stroke-width="1"/>')
    return f'<svg width="54" height="9" viewBox="0 0 54 9">{"".join(cells)}</svg>'


def zone_row(name, note, count, humans, bots, lit):
    wash = ("background:linear-gradient(90deg,rgba(79,214,255,.13),"
            "rgba(79,214,255,.02));" if lit else "")
    ncol = "var(--ink)" if lit else "#b9c6d8"
    return f"""
  <div style="display:flex;align-items:center;gap:10px;padding:10px;
       min-height:58px;{wash}">
    <div style="flex:1;min-width:0">
      <div style="font-size:15px;color:{ncol}">{name}</div>
      <div style="font-size:10.5px;color:var(--dim);margin-top:2px">{note}</div>
    </div>
    <div style="display:flex;flex-direction:column;align-items:flex-end;gap:5px">
      <span class="num" style="font-size:11px;color:#9fb6d4">{count}</span>
      {meter(humans, bots)}
    </div>
  </div>"""


def watch_card():
    """The room behind the glass, which is what deploy_aside already says."""
    return f"""
  <div class="panel" style="padding:10px 12px">
    <div class="row" style="justify-content:space-between">
      <span class="hud" style="font-size:10px;color:var(--dim)">melee · room 2</span>
      <span class="num" style="font-size:16px">1:47</span>
    </div>
    <div class="row" style="gap:8px;margin-top:6px">
      <span class="hud num" style="font-size:11px;color:var(--friend)">PYLON 3</span>
      <span class="num" style="font-size:11px;color:var(--dim)">:</span>
      <span class="hud num" style="font-size:11px;color:var(--enemy)">5 CAISSON</span>
    </div>
  </div>"""


def column_body(watching):
    """The play page: the zones, and the room behind the glass where there is
    height for it. A window too short for the card scrolls instead."""
    rows = [section("zones"),
            zone_row("melee", "four a side, three minutes",
                     "3 + 5 AI", 3, 5, True),
            zone_row("ladder", "one life at a time, climb the house ladder",
                     "1 + 1 AI", 1, 1, False)]
    if watching:
        rows.append(section("watching"))
        rows.append(watch_card())
    return "".join(rows)


ICONS = {
    "play": '<path d="M4.5 2.5 L13 8 L4.5 13.5 Z"/>',
    "ship": ('<g transform="translate(8,8.6) scale(.5)">'
             '<path d="M0,-13 L15,9 L7,12 L0,8 L-7,12 L-15,9 Z"/></g>'),
    "upgrades": ('<circle cx="8" cy="8" r="4.4"/>'
                 '<path d="M8 1.6 V3.6 M8 12.4 V14.4"/>'),
    "friends": ('<path d="M2.6 9.8 A5.5 5.5 0 0 1 13.4 9.8"/>'
                '<path d="M1.6 11.6 H14.4"/>'),
    "standings": '<path d="M3 13.5 V8.5 M8 13.5 V2.5 M13 13.5 V6"/>',
    "settings": ('<path d="M2 4.5 H14 M2 8 H14 M2 11.5 H14"/>'
                 '<circle cx="10.5" cy="4.5" r="1.8" fill="#0a0f18"/>'
                 '<circle cx="5.5" cy="8" r="1.8" fill="#0a0f18"/>'
                 '<circle cx="9.5" cy="11.5" r="1.8" fill="#0a0f18"/>'),
}


def icon(kind, col):
    dot = (f'<circle cx="8" cy="8" r="1.3" fill="{col}" stroke="none"/>'
           if kind == "upgrades" else "")
    return (f'<svg width="16" height="16" viewBox="0 0 16 16" fill="none" '
            f'stroke="{col}" stroke-width="1.3" style="flex:none">'
            f'{ICONS[kind]}{dot}</svg>')


TABS = ["play", "ship", "upgrades", "friends", "standings", "settings"]


def tab_cells():
    """The six stops. Play is lit: it is where you are."""
    cells = []
    for t in TABS:
        lit = t == "play"
        col = "var(--ink)" if lit else "var(--dim)"
        ic = "#4fd6ff" if lit else "#6c7a90"
        wash = ("background:linear-gradient(0deg,rgba(79,214,255,.14),"
                "rgba(79,214,255,0) 80%);" if lit else "")
        cells.append(
            f'<div style="flex:1;display:flex;flex-direction:column;'
            f'align-items:center;justify-content:center;gap:4px;height:100%;'
            f'{wash}">{icon(t, ic)}'
            f'<span style="font-size:9px;color:{col}">{t}</span></div>')
    return "".join(cells)


def column(cw, ch):
    """The whole column at cw by ch: head, page, DEPLOY, the six stops."""
    parts = [f'<div class="row" style="height:56px;padding:0 14px;'
             f'justify-content:space-between;border-bottom:1px solid '
             f'rgba(63,88,120,.45)">{lockup(112)}{pilot_chip()}</div>']
    parts.append(f'<div style="position:absolute;left:0;right:0;bottom:0;'
                 f'height:64px;border-top:1px solid {RULE};display:flex">'
                 f'{tab_cells()}</div>')
    parts.append('<div class="play" style="position:absolute;left:14px;'
                 'right:14px;bottom:78px;height:44px;font-size:14px">'
                 'DEPLOY</div>')
    inner_h = ch - 56 - 64 - 58 - 10
    parts.insert(1, f'<div style="position:absolute;left:0;right:0;top:56px;'
                    f'height:{inner_h}px;padding:0 14px;overflow:hidden">'
                    f'{column_body(inner_h >= 300)}</div>')
    return "".join(parts)


def sheet_inner(sh):
    """The console's sheet: the page alone, since the bar is the tab row."""
    inner_h = sh - 44 - 10
    return (f'<div class="row" style="height:44px;padding:0 14px;'
            f'justify-content:space-between;border-bottom:1px solid '
            f'rgba(63,88,120,.45)">'
            f'<span class="hud" style="font-size:11px">play</span>'
            f'{pilot_chip()}</div>'
            f'<div style="position:absolute;left:0;right:0;top:44px;'
            f'height:{inner_h}px;padding:0 14px;overflow:hidden">'
            f'{column_body(inner_h >= 300)}</div>')


# --- one window, one direction -----------------------------------------------

SEEDS = {"Desktop": 3, "Landscape": 3, "Portrait": 5}


def dock_board(form):
    w, h, compact = FORMS[form]
    portrait = form == "Portrait"
    dw = min(390, w)
    body = [scene(w, h, compact, SEEDS[form], shift=0 if portrait else dw // 3)]
    if not portrait:
        body.append(score_band(compact, cx=int(dw + (w - dw) / 2)))
        body.append(radar_feed(compact))
    border = "" if portrait else f"border-right:1px solid {RULE};"
    body.append(f'<div style="position:absolute;left:0;top:0;width:{dw}px;'
                f'height:{h}px;background:rgba(3,5,10,.88);{border}">'
                f'{column(dw, h)}</div>')
    return body


def card_board(form):
    w, h, compact = FORMS[form]
    portrait = form == "Portrait"
    cw, ch = min(390, w - 24), min(560, h - 24)
    return [scene(w, h, compact, SEEDS[form]),
            corner_row(compact),
            score_band(compact, portrait),
            radar_feed(compact, portrait),
            '<div style="position:absolute;inset:0;'
            'background:rgba(3,5,10,.45)"></div>',
            f'<div style="position:absolute;left:50%;top:50%;'
            f'transform:translate(-50%,-50%);width:{cw}px;height:{ch}px;'
            f'background:rgba(3,5,10,.9);border:1px solid {RULE}">'
            f'{bracket()}{column(cw, ch)}</div>']


def console_board(form):
    w, h, compact = FORMS[form]
    portrait = form == "Portrait"
    bw = min(620, w)
    bx = (w - bw) // 2
    body = [scene(w, h, compact, SEEDS[form]),
            corner_row(compact, menu=False),
            score_band(compact, portrait),
            radar_feed(compact, portrait)]
    if portrait:
        sheet_h, sheet_b = 480, 64 + 14 + 44 + 14
        body.append(f'<div style="position:absolute;left:0;bottom:{sheet_b}px;'
                    f'width:{w}px;height:{sheet_h}px;'
                    f'background:rgba(3,5,10,.9);border-top:1px solid {RULE};'
                    f'border-bottom:1px solid {RULE}">{sheet_inner(sheet_h)}'
                    f'</div>')
        body.append('<div class="play" style="position:absolute;left:14px;'
                    'right:14px;bottom:78px;height:44px;font-size:14px">'
                    'PLAY NOW</div>')
        body.append(f'<div style="position:absolute;left:0;right:0;bottom:0;'
                    f'height:64px;background:rgba(5,7,12,.85);'
                    f'border-top:1px solid {RULE};display:flex">{tab_cells()}'
                    f'</div>')
    else:
        sheet_h = 240 if compact else 560
        body.append(f'<div style="position:absolute;left:{bx}px;bottom:64px;'
                    f'width:{bw}px;height:{sheet_h}px;'
                    f'background:rgba(3,5,10,.9);border:1px solid {RULE};'
                    f'border-bottom:none">{sheet_inner(sheet_h)}</div>')
        body.append(f'<div style="position:absolute;left:{bx}px;bottom:0;'
                    f'width:{bw}px;height:64px;background:rgba(5,7,12,.85);'
                    f'border:1px solid {RULE};border-bottom:none;display:flex">'
                    f'{tab_cells()}'
                    f'<div class="play" style="width:150px;height:100%;'
                    f'font-size:12px;flex:none">PLAY NOW</div></div>')
    return body


DIRECTIONS = {"Dock": dock_board, "Card": card_board, "Console": console_board}


def screen(form, direction):
    w, h, _ = FORMS[form]
    body = DIRECTIONS[direction](form)
    stars = starfield(w, h, *(dict(Desktop=(46, 30, 12), Landscape=(30, 20, 8),
                                   Portrait=(30, 20, 8))[form]),
                      seed=28)
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
    for direction in DIRECTIONS:
        for form in FORMS:
            name = ("Main" if (direction, form) == ("Dock", "Desktop")
                    else f"{form}{direction}")
            page(name, screen(form, direction))
    print("nine artboards written")


if __name__ == "__main__":
    main()
