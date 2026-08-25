#!/usr/bin/env python3
"""Assemble the nine .dc.html artboards for the scoreboard rethink.

The shipped scoreboard is a centered band that grows outward from the clock
with names, ratings and the ladder readout, so it overruns an upright phone;
Ladder and Melee fill it differently so the two zones look unrelated; its type
is fixed at 13/30pt, which is small at desktop distance; and match events
arrive as one 24pt white sentence across the middle of the screen.

These boards ask one question three ways: where does a scoreboard live so
that one chassis serves every zone and every window? The chassis is the same
in all three: score and clock, common to every zone; one slot the zone fills
(Ladder's rung and streak, Melee's intermission clock, a flag game's pennant
tally); and events landing in that slot in the scoring side's color instead
of across the middle of the glass.

  A  the scorebug: one contained box top center, broadcast style
  B  the corner tile: an instrument docked under MENU, the center stays glass
  C  the edge strip: the window's top edge is the scoreboard, filled from
     each end in the sides' colors

Three window shapes each. Desktop shows Melee mid-match; landscape shows
Ladder at the moment a rung clears, which is where the mid-screen banner
lives today; portrait shows Ladder mid-life, the shape that overruns today.

Drawings of a proposal, not a plan of record. The design system is lifted
from ../spectator-landing/build.py, which lifted it from the real client:
client/arena/palette.lua for hues, client/arena/ui.lua for panel geometry,
docs/design/ships.md for hull extents, sides from catalog/zones/*/zone.toml
(Pylon and Caisson; Pilot and Rival). The corner row is the shipped one:
hamburger MENU, PLAYERS with the two seat marks, LINK and the radar in the
far corner.

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

VARIANTS = ["A", "B", "C", "D"]

FRIEND, ENEMY = "#4fd6ff", "#ffa552"

# --- what each window is showing ---------------------------------------------
# sides: (name, score, color, rating or None). zone: the line the zone owns.
# event: (line, color) standing in the slot for a few seconds, or None.
MODES = {
    "Desktop": {
        "sides": [("PYLON", 15, FRIEND, None), ("CAISSON", 19, ENEMY, None)],
        "clock": "0:33",
        "zone": None,
        "event": None,
        "humans": 3, "bots": 5,
    },
    "Landscape": {
        "sides": [("PILOT", 1, FRIEND, 1206), ("RIVAL", 0, ENEMY, 1200)],
        "clock": "0:05",
        "zone": "RUNG 4 · STREAK 3",
        "event": ("RUNG 3 CLEARED · NEXT RUNG 4 · STREAK 3", FRIEND),
        "dead_rival": True,
        "humans": 1, "bots": 1,
    },
    "Portrait": {
        "sides": [("PILOT", 0, FRIEND, 1206), ("RIVAL", 0, ENEMY, 1200)],
        "clock": "2:39",
        "zone": "RUNG 4 · STREAK 3",
        "event": None,
        "humans": 1, "bots": 2,
    },
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
.panel{position:relative;background:rgba(5,7,12,.62)}
.panel::before{content:"";position:absolute;left:0;top:0;bottom:0;width:1.4px;
  background:rgba(63,88,120,.7)}

/* A selection: bright where it meets its rule and gone across the row. */
.wash{background:linear-gradient(90deg,rgba(79,214,255,.14),
  rgba(79,214,255,0) 70%)}

/* One shape for a thing to press. ui.lua key_cap(). */
.key{display:inline-flex;align-items:center;justify-content:center;gap:7px;
  border:1px solid rgba(63,88,120,.75);background:rgba(10,15,24,.6);
  font-family:var(--mono);text-transform:uppercase;letter-spacing:.06em;
  color:#9fb6d4}
"""

# --- seat marks, ui.lua helm()/bot_mark() ------------------------------------


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


def rivet(col="#ffe08a", k=9):
    return (f'<svg width="{k}" height="{k}" viewBox="0 0 12 12" fill="none" '
            f'style="flex:none">'
            f'<circle cx="6" cy="6" r="4.4" stroke="{col}" stroke-width="1.1"/>'
            f'<circle cx="6" cy="6" r="1.7" fill="{col}"/>'
            f'<path d="M6 1.6 V3" stroke="{col}" stroke-width="1"/>'
            f'<path d="M6 9 V10.4" stroke="{col}" stroke-width="1"/></svg>')


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


def burst(x, y):
    """A hull coming apart, where the rival was when the rung cleared."""
    shards = "".join(
        f'<path d="M{dx} {dy} L{dx * 2.1} {dy * 2.1}" stroke="#ff9d22" '
        f'stroke-width="1.6" stroke-linecap="round" opacity=".8"/>'
        for dx, dy in ((10, -6), (-8, -10), (12, 8), (-11, 5), (2, -13), (-3, 12)))
    return (f'<g transform="translate({x},{y})">'
            f'<circle r="7" fill="#ff7000" opacity=".95"/>'
            f'<circle r="18" stroke="#ff7000" fill="none" stroke-width="2" '
            f'opacity=".5"/>'
            f'<circle r="30" stroke="#ff7000" fill="none" stroke-width="1" '
            f'opacity=".22"/>{shards}</g>')


# --- the fights behind the glass ---------------------------------------------
MELEE_SHIPS = [
    ("KRAIT 4",   "Wedge",   FRIEND, (0, 10),      18,  7),
    ("VIREO 9",   "Chord",   FRIEND, (-170, 40),   62,  2),
    ("SABER 3",   "Facet",   FRIEND, (-320, -150), 118, 4),
    ("PLINTH 41", "Lattice", FRIEND, (520, 290),   -40, 1),
    ("MANTIS 7",  "Cipher",  ENEMY,  (150, -95),   205, 5),
    ("HALCYON 2", "Anvil",   ENEMY,  (365, 55),    160, 9),
    ("SABLE 09",  "Wedge",   ENEMY,  (-460, 240),  285, 1),
    ("ORRERY 3",  "Apex",    ENEMY,  (430, -285),  320, 3),
]

# The climber's own hull is unlabeled, the way your own always is. The rival
# sits where the window has room: clear of the top-center scoreboard in a
# sideways window, up the long axis in an upright one.
DUEL_RIVAL = {"Landscape": (220, -60), "Portrait": (110, 120)}


def duel_ships(form):
    return [("", "Wedge", FRIEND, (0, 30), 12, None),
            ("Vantage 0001", "Apex", ENEMY, DUEL_RIVAL[form], 200, 1)]


def scene(w, h, compact, seed, ships, dead_rival=False):
    cx, cy = w / 2, h / 2
    rnd = random.Random(seed)
    parts = []
    for _ in range(10 if compact else 22):
        x = rnd.randint(-60, w - 40)
        y = rnd.randint(-40, h - 40)
        bw, bh = rnd.choice([(96, 32), (32, 108), (64, 64), (150, 30), (30, 150)])
        if abs(x + bw / 2 - cx) < 210 and abs(y + bh / 2 - cy) < 170:
            continue
        # And off the top center, where the band draws on bare sky.
        if y < 80 and abs(x + bw / 2 - cx) < 230:
            continue
        parts.append(
            f'<rect x="{x}" y="{y}" width="{bw}" height="{bh}" fill="#080d16" '
            f'stroke="#22344f" stroke-width="1"/>'
            f'<path d="M{x} {y} H{x + bw}" stroke="#5b82b8" stroke-width="1.4" '
            f'opacity=".55"/>')
    if not dead_rival:
        parts += [
            f'<path d="M{cx + 60} {cy - 32} L{cx + 76} {cy - 44}" stroke="#f7dd0b" '
            'stroke-width="2.6" stroke-linecap="round"/>',
            f'<path d="M{cx - 106} {cy + 6} L{cx - 92} {cy - 8}" stroke="#62cc35" '
            'stroke-width="2.4" stroke-linecap="round"/>',
        ]
    px = 9 if compact else 10
    k = 0.85 if compact else 1.0
    for i, (name, hullname, col, (ox, oy), rot, bounty) in enumerate(ships):
        x, y = cx + ox * (0.8 if compact else 1), cy + oy * (0.8 if compact else 1)
        if not (-40 < x < w + 40 and -40 < y < h + 40):
            continue
        if dead_rival and col == ENEMY:
            parts.append(burst(x, y))
            continue
        parts.append(ship_at(hullname, x, y, rot, col,
                             k=k * (1.15 if i == 0 else 1)))
        if name:
            parts.append(nameplate(x, y, name, col, bounty, px))
    return (f'<svg width="{w}" height="{h}" '
            f'style="position:absolute;inset:0">{"".join(parts)}</svg>')


# --- the shipped chrome, held constant ---------------------------------------


def burger(col, k):
    return (f'<svg width="{k}" height="{k}" viewBox="0 0 14 14" fill="none" '
            f'style="flex:none">'
            f'<path d="M2 3.5 H12 M2 7 H12 M2 10.5 H12" stroke="{col}" '
            f'stroke-width="1.4" stroke-linecap="square"/></svg>')


def corner_row(compact, humans, bots, top=14, extra="", players=True):
    """Hamburger MENU and PLAYERS, as shipped: bars plus the word on a
    desktop, bars alone in a square key on a phone. `extra` is direction D's
    clock key, riding the same row; D also drops PLAYERS, because the
    readout behind the clock is that panel now."""
    kh, px = (22, 9) if compact else (26, 11)
    mk = 10 if compact else 12
    if compact:
        menu = (f'<div class="key" style="width:{kh}px;height:{kh}px">'
                f'{burger("#9fb6d4", 12)}</div>')
    else:
        menu = (f'<div class="key" style="height:{kh}px;padding:0 9px;'
                f'font-size:{px}px">{burger("#9fb6d4", 13)}MENU</div>')
    players_key = ""
    if players:
        players_key = (
            f'<div class="key" style="height:{kh}px;padding:0 9px;'
            f'font-size:{px}px">PLAYERS '
            f'{helm("#9fb6d4", mk)}<span style="margin-left:-4px">{humans}'
            f'</span> {bot("#9fb6d4", mk)}'
            f'<span style="margin-left:-4px">{bots}</span></div>')
    return f"""
  <div class="row" style="position:absolute;left:14px;top:{top}px;gap:8px">
    {menu}
    {players_key}
    {extra}
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
             '<circle cx="66" cy="55" r="2" fill="#ffa552"/>')
    return (f'<div style="position:relative;width:{side}px;height:{side}px">'
            f'<svg width="{side}" height="{side}" viewBox="0 0 100 100" '
            f'style="background:rgba(6,10,16,.55)">{"".join(blips)}{ships}</svg>'
            f'{bracket()}</div>')


def link_bars():
    bars = "".join(
        f'<rect x="{i * 4}" y="{9 - i * 3}" width="2.6" height="{3 + i * 3}" '
        f'fill="#6c7a90" opacity=".8"/>' for i in range(4))
    return f'<svg width="16" height="12" viewBox="0 0 16 12">{bars}</svg>'


def dial_corner(form, top=14):
    """LINK and the radar, in the corner they own. A phone held upright keeps
    LINK alone, the way the shipped client does."""
    if form == "Portrait":
        return (f'<div style="position:absolute;right:14px;top:{top}px">'
                f'{link_bars()}</div>')
    side = 120 if form == "Landscape" else 168
    return f"""
  <div style="position:absolute;right:14px;top:{top}px;display:flex;
       flex-direction:column;align-items:flex-end;gap:10px">
    {link_bars()}
    {minimap(side, 7)}
  </div>"""


# --- direction A: the scorebug -----------------------------------------------


def bug_board(form, mode):
    w, h, compact = FORMS[form]
    portrait = form == "Portrait"
    d = not compact
    clock_px = 38 if d else 24
    score_px = 30 if d else 19
    name_px = 13 if d else 10
    rate_px = 11 if d else 9
    slot_px = 12 if d else 9
    gap = 24 if d else 14

    def chip(name, rating, col, align):
        lines = (f'<div class="hud num" style="font-size:{name_px}px;'
                 f'color:{col}">{name}</div>')
        if rating is not None:
            lines += (f'<div class="num" style="font-size:{rate_px}px;'
                      f'color:{col};opacity:.55">{rating}</div>')
        return (f'<div style="display:flex;flex-direction:column;'
                f'align-items:{align};gap:1px">{lines}</div>')

    (ln, ls, lc, lr), (rn, rs, rc, rr) = mode["sides"]
    main = f"""
    <div class="row" style="justify-content:space-between;gap:{gap}px">
      {chip(ln, lr, lc, 'flex-end')}
      <div class="num" style="font-size:{score_px}px;color:{lc}">{ls}</div>
      <div class="num" style="font-size:{clock_px}px;letter-spacing:.02em">
        {mode["clock"]}</div>
      <div class="num" style="font-size:{score_px}px;color:{rc}">{rs}</div>
      {chip(rn, rr, rc, 'flex-start')}
    </div>"""

    # The zone's slot, on the bug's own foot. An event borrows it for a few
    # seconds in the scoring side's color; a zone with nothing to say has no
    # slot and the chassis alone is the whole bug.
    slot = ""
    line, col = None, "var(--dim)"
    if mode["event"]:
        line, col = mode["event"]
    elif mode["zone"]:
        line = mode["zone"]
    if line:
        slot = (f'<div class="hud" style="border-top:1px solid '
                f'rgba(63,88,120,.5);margin-top:{7 if d else 5}px;'
                f'padding-top:{6 if d else 4}px;font-size:{slot_px}px;'
                f'letter-spacing:.12em;color:{col};text-align:center">'
                f'{line}</div>')

    ground = ("rgba(18,42,54,.78)" if mode["event"] else "rgba(5,7,12,.62)")
    if portrait:
        pos = "left:14px;right:14px;top:46px"
    else:
        pos = (f'left:50%;transform:translateX(-50%);top:{16 if d else 12}px')
    return (f'<div style="position:absolute;{pos};'
            f'border:1px solid rgba(63,88,120,.75);background:{ground};'
            f'padding:{"10px 20px" if d else "7px 14px"}">{main}{slot}</div>')


# --- direction B: the corner tile --------------------------------------------


def tile_board(form, mode):
    w, h, compact = FORMS[form]
    d = not compact
    top = (14 + 26 + 12) if d else (14 + 22 + 10)
    clock_px = 26 if d else 18
    name_px = 12 if d else 10
    score_px = 18 if d else 13
    zone_px = 10 if d else 9
    width = 208 if d else 164

    def side_row(name, score, col, rating):
        rate = ""
        if rating is not None:
            rate = (f'<span class="num" style="font-size:{zone_px}px;'
                    f'color:{col};opacity:.55;margin-left:6px">{rating}</span>')
        return (f'<div class="row" style="gap:8px">'
                f'<div style="width:3px;height:{name_px}px;background:{col}">'
                f'</div>'
                f'<div class="hud num" style="font-size:{name_px}px;'
                f'color:{col}">{name}{rate}</div>'
                f'<div style="flex:1"></div>'
                f'<div class="num" style="font-size:{score_px}px;color:{col}">'
                f'{score}</div></div>')

    rows = [f'<div class="num" style="font-size:{clock_px}px;'
            f'letter-spacing:.02em">{mode["clock"]}</div>']
    for name, score, col, rating in mode["sides"]:
        rows.append(side_row(name, score, col, rating))
    if mode["zone"]:
        rows.append(f'<div class="hud" style="font-size:{zone_px}px;'
                    f'letter-spacing:.12em;color:var(--dim);margin-top:2px">'
                    f'{mode["zone"]}</div>')
    if mode["event"]:
        line, col = mode["event"]
        rows.append(f'<div class="hud" style="font-size:{zone_px}px;'
                    f'letter-spacing:.1em;color:{col};margin-top:2px;'
                    f'max-width:{width}px">{line}</div>')
    return (f'<div class="panel" style="position:absolute;left:14px;'
            f'top:{top}px;width:{width}px;padding:10px 12px;display:flex;'
            f'flex-direction:column;gap:{7 if d else 5}px">'
            f'{"".join(rows)}</div>')


# --- direction C: the edge strip ---------------------------------------------


def strip_board(form, mode):
    w, h, compact = FORMS[form]
    portrait = form == "Portrait"
    d = not compact
    sh = 30 if d else 24
    num_px = 16 if d else 13
    name_px = 11 if d else 9
    clock_px = 18 if d else 14
    tab_px = 11 if d else 9

    (ln, ls, lc, lr), (rn, rs, rc, rr) = mode["sides"]
    total = ls + rs
    share = (ls / total) if total else 0.5
    event = mode["event"]
    la = 0.30 if (event and event[1] == lc) else 0.16
    ra = 0.30 if (event and event[1] == rc) else 0.16
    fills = (
        f'<div style="position:absolute;left:0;top:0;bottom:0;'
        f'width:{share * 100:.1f}%;background:linear-gradient(90deg,'
        f'rgba(79,214,255,{la}),rgba(79,214,255,.03))"></div>'
        f'<div style="position:absolute;right:0;top:0;bottom:0;'
        f'width:{(1 - share) * 100:.1f}%;background:linear-gradient(270deg,'
        f'rgba(255,165,82,{ra}),rgba(255,165,82,.03))"></div>')

    def end_group(name, score, col, rating, right):
        bits = []
        num = (f'<span class="num" style="font-size:{num_px}px;color:{col}">'
               f'{score}</span>')
        label = ""
        if not portrait:
            rate = ("" if rating is None else
                    f'<span class="num" style="font-size:{name_px - 1}px;'
                    f'color:{col};opacity:.55;margin-left:5px">{rating}</span>')
            label = (f'<span class="hud num" style="font-size:{name_px}px;'
                     f'color:{col};opacity:.85">{name}{rate}</span>')
        bits = [num, label] if not right else [label, num]
        side = "right" if right else "left"
        return (f'<div class="row" style="position:absolute;{side}:12px;'
                f'top:0;bottom:0;gap:10px">{"".join(b for b in bits if b)}'
                f'</div>')

    clock = (f'<div class="row" style="position:absolute;left:50%;top:0;'
             f'bottom:0;transform:translateX(-50%)">'
             f'<span class="num" style="font-size:{clock_px}px;'
             f'letter-spacing:.02em">{mode["clock"]}</span></div>')

    strip = (f'<div style="position:absolute;left:0;right:0;top:0;'
             f'height:{sh}px;background:rgba(5,7,12,.7);'
             f'border-bottom:1px solid rgba(63,88,120,.6)">'
             f'{fills}{end_group(ln, ls, lc, lr, False)}'
             f'{end_group(rn, rs, rc, rr, True)}{clock}</div>')

    # The zone line hangs in a tab under the clock; an event takes the tab
    # over in the scoring side's color while the strip flashes the same way.
    tab = ""
    line, col = None, "var(--dim)"
    if event:
        line, col = event
    elif mode["zone"]:
        line = mode["zone"]
    if line:
        tab = (f'<div class="hud" style="position:absolute;left:50%;'
               f'top:{sh}px;transform:translateX(-50%);white-space:nowrap;'
               f'border:1px solid rgba(63,88,120,.6);border-top:none;'
               f'background:rgba(5,7,12,.62);padding:3px 10px;'
               f'font-size:{tab_px}px;letter-spacing:.12em;color:{col}">'
               f'{line}</div>')
    return strip + tab, sh


# --- direction D: the expanding band -----------------------------------------
# The scoreboard is an instrument, not a control, so it does not wear a
# key's box or sit in the key row. Shut, it is a bare readout at top
# center: the score in the side colors around the clock, nothing else, and
# in the duel the clock alone. The expand affordance comes from the
# instrument grammar rather than the key grammar: the faint corner
# brackets the radar already wears, brightened while open. Pressed, the
# readout grows out of the band, so shut and open are one object at two
# depths. PLAYERS is gone, because the readout carries the roster; MENU
# stands alone in its corner doing the one static thing.
#
# The open panel is the shipped players panel's own grammar: a section head
# in dim capitals with its column labels on the same line, rows under it,
# a dashed rule between sections. Sections are the modularity: every zone
# stacks the pilot list; the duel adds its run of fights, a team game adds
# nothing because its scores live on the pilot list's own section heads; a
# pressed row opens the same pilot card everywhere.

# Melee's roster, per pilot: human?, kills, deaths, assists, points, bounty.
MELEE_BOARD = [
    ("PYLON", 15, FRIEND, [
        ("KRAIT 4",   True,  5, 2, 3, 21, 7),
        ("VIREO 9",   True,  4, 3, 1, 12, 2),
        ("SABER 3",   False, 3, 4, 2, 9,  4),
        ("PLINTH 41", False, 3, 2, 0, 8,  1),
    ]),
    ("CAISSON", 19, ENEMY, [
        ("MANTIS 7",  True,  6, 3, 2, 19, 5),
        ("HALCYON 2", False, 5, 4, 1, 15, 9),
        ("ORRERY 3",  False, 4, 2, 3, 13, 3),
        ("SABLE 09",  False, 4, 6, 0, 7,  1),
    ]),
]

# The duel's board, lifted from a screenshot of the shipped players panel so
# the two drawings compare line for line.
DUEL_PILOTS = [
    ("Aperture",     True,  FRIEND, (1, 0, 0, 1, 2)),
    ("Vantage 0001", False, ENEMY,  (0, 0, 0, 0, 1)),
]
DUEL_WATCHER = "DRiFT"
DUEL_RUN = [
    ("RUNG 4", True,  "1-0", "0:26"),
    ("RUNG 3", True,  "1-0", "0:13"),
    ("RUNG 2", True,  "1-0", "0:23"),
    ("RUNG 1", True,  "1-0", "0:45"),
    ("RUNG 2", False, "0-1", "1:29"),
    ("RUNG 1", True,  "1-0", "0:25"),
]
DUEL_CARD = [
    ("team", "Rival", ENEMY), ("seat", "BOT", None), ("tier", "LEAD", None),
    ("rating", "1249", None), ("kills", "0", None), ("deaths", "0", None),
    ("points", "0", None), ("bounty", "0", "var(--bounty)"),
]

# The five columns every pilot list shares, and their widths.
D_COLS = [("k", 22), ("d", 22), ("a", 22), ("pts", 30), ("bty", 30)]

# D's own reading of the duel: the band carries the pilots rather than the
# sides, name over rating, so the sides here are the call signs the roster
# and the card use, and the ratings agree with the card. The event line is
# gone from the instrument; the run's story lives in the readout. Kept
# apart from MODES so the first directions on page two stay as drawn.
D_MODES = {
    "Desktop": MODES["Desktop"],
    "Landscape": {**MODES["Landscape"],
                  "sides": [("Aperture", 1, FRIEND, 1206),
                            ("Vantage 0001", 0, ENEMY, 1249)],
                  "event": None},
    "Portrait": {**MODES["Portrait"],
                 "sides": [("Aperture", 0, FRIEND, 1206),
                           ("Vantage 0001", 0, ENEMY, 1249)]},
}


def score_band(form, mode, melee, open_):
    """The shut scoreboard: a bare readout at top center, no box, no
    ground. Each side is a two-line stack in its color: in Melee the team's
    name over its score, in the duel the pilot's call sign over their
    rating, since the duel's score is not worth a line and the rating is.
    The brackets are the radar's own corner marks, faint at rest and
    brightened while the readout under them is open."""
    compact = FORMS[form][2]
    clock_px = 22 if compact else 34
    score_px = 17 if compact else 26
    name_px = 9 if compact else 11
    rate_px = 8 if compact else 10
    gap = 14 if compact else 22
    pad = "4px 12px" if compact else "6px 16px"
    bcol = "rgba(79,214,255,.55)" if open_ else "rgba(63,88,120,.55)"

    def stack(name, col, under, under_px, under_dim):
        dim = ";opacity:.6" if under_dim else ""
        return (f'<div style="display:flex;flex-direction:column;'
                f'align-items:center;gap:1px">'
                f'<span class="hud num" style="font-size:{name_px}px;'
                f'color:{col};white-space:nowrap">{name}</span>'
                f'<span class="num" style="font-size:{under_px}px;'
                f'color:{col}{dim}">{under}</span></div>')

    (ln, ls, lc, lr), (rn, rs, rc, rr) = mode["sides"]
    if melee:
        left = stack(ln, lc, ls, score_px, False)
        right = stack(rn, rc, rs, score_px, False)
    else:
        left = stack(ln, lc, lr, rate_px, True)
        right = stack(rn, rc, rr, rate_px, True)
    clock = (f'<span class="num" style="font-size:{clock_px}px;'
             f'letter-spacing:.02em">{mode["clock"]}</span>')
    return (f'<div class="row" style="position:absolute;left:50%;'
            f'top:{12 if compact else 14}px;transform:translateX(-50%);'
            f'gap:{gap}px;padding:{pad}">{bracket(bcol)}'
            f'{left}{clock}{right}</div>')


def d_cells(vals, px, col="var(--ink)", bty=True):
    """One pilot's numbers, right-aligned under the shared column heads."""
    out = []
    for (label, w), v in zip(D_COLS, vals):
        c = "var(--bounty)" if (bty and label == "bty") else col
        dim = ";opacity:.55" if label in ("d", "a") else ""
        out.append(f'<span class="num" style="width:{w}px;text-align:right;'
                   f'font-size:{px}px;color:{c}{dim}">{v}</span>')
    return "".join(out)


def d_sec_head(label, px, col="var(--dim)", cols=None, score=None,
               score_col=None):
    """A section head the shipped panel's way: the label in capitals, its
    column labels on the same line, right-aligned over their columns."""
    left = (f'<span class="hud" style="font-size:{px}px;letter-spacing:.1em;'
            f'color:{col}">{label}</span>')
    if score is not None:
        left += (f'<span class="num" style="font-size:{px + 2}px;'
                 f'color:{score_col};margin-left:8px">{score}</span>')
    heads = ""
    if cols:
        heads = "".join(f'<span class="lbl" style="width:{w}px;'
                        f'text-align:right">{c}</span>' for c, w in cols)
    return (f'<div class="row" style="gap:6px">{left}'
            f'<div style="flex:1"></div>{heads}</div>')


def d_rule():
    return ('<div style="border-top:1px dashed rgba(63,88,120,.55);'
            'margin:2px 0"></div>')


def d_pilot_row(name, human, col, vals, px, mark_px, washed=False):
    mark = helm(col, mark_px) if human else bot(col, mark_px)
    return (f'<div class="row{" wash" if washed else ""}" style="gap:7px;'
            f'padding:1px 2px">'
            f'<span class="num" style="font-size:{px}px;color:{col}">{name}'
            f'</span>{mark}<div style="flex:1"></div>{d_cells(vals, px)}'
            f'</div>')


def d_watch_row(name, px, mark_px):
    return (f'<div class="row" style="gap:7px;padding:1px 2px">'
            f'<span class="num" style="font-size:{px}px;color:var(--ink)">'
            f'{name}</span>{helm("#9fb6d4", mark_px)}<div style="flex:1">'
            f'</div><span class="hud dim" style="font-size:{px - 1}px;'
            f'opacity:.7">WATCHING</span></div>')


def melee_readout(compact):
    """Melee's readout: one pilot list, the sides told apart by the color
    their names already wear. The band above carries the team names and
    scores, so a head repeating them here would say everything twice."""
    px = 10 if compact else 11
    mark = 10 if compact else 11
    parts = [d_sec_head("PILOTS", px - 1, cols=D_COLS)]
    for team, score, col, pilots in MELEE_BOARD:
        for name, human, k, d, a, pts, bty in pilots:
            parts.append(d_pilot_row(name, human, col, (k, d, a, pts, bty),
                                     px, mark))
    parts.append(d_rule())
    parts.append(d_watch_row(DUEL_WATCHER, px, mark))
    return (f'<div class="panel" style="position:absolute;left:50%;top:78px;'
            f'transform:translateX(-50%);width:340px;padding:10px 12px;'
            f'display:flex;flex-direction:column;gap:5px">'
            f'{"".join(parts)}</div>')


def ladder_readout(compact):
    """The duel's readout: the same pilot list section, then the run's
    fights, then the card a pressed row opens. Two of the three are shared
    with every other zone; only the run is the duel's own."""
    px = 10 if compact else 11
    mark = 10 if compact else 11
    parts = [d_sec_head("PILOTS", px - 1, cols=D_COLS)]
    for name, human, col, vals in DUEL_PILOTS:
        parts.append(d_pilot_row(name, human, col, vals, px, mark,
                                 washed=(name == "Vantage 0001")))
    parts.append(d_watch_row(DUEL_WATCHER, px, mark))
    parts.append(d_rule())
    parts.append(d_sec_head(f"RUN: {len(DUEL_RUN)} FIGHTS", px - 1,
                            cols=[("score", 40), ("time", 40)]))
    for rung, won, score, time in DUEL_RUN:
        verdict = ("WON", FRIEND) if won else ("LOST", ENEMY)
        parts.append(
            f'<div class="row" style="gap:7px;padding:1px 2px">'
            f'<span class="num" style="font-size:{px}px;opacity:.85">{rung}'
            f'</span><div style="flex:1"></div>'
            f'<span class="hud" style="font-size:{px - 1}px;'
            f'color:{verdict[1]}">{verdict[0]}</span>'
            f'<span class="num" style="width:40px;text-align:right;'
            f'font-size:{px}px">{score}</span>'
            f'<span class="num dim" style="width:40px;text-align:right;'
            f'font-size:{px}px">{time}</span></div>')
    panel = (f'<div class="panel" style="position:absolute;left:14px;'
             f'right:14px;top:58px;padding:10px 12px;display:flex;'
             f'flex-direction:column;gap:5px">{"".join(parts)}</div>')

    # The card the washed row is holding open, a block of its own under the
    # panel: who this seat is, in full.
    cross = ('<svg width="9" height="9" viewBox="0 0 10 10">'
             '<path d="M1 1 L9 9 M9 1 L1 9" stroke="#6c7a90" '
             'stroke-width="1.3" stroke-linecap="square"/></svg>')
    rows = [f'<div class="row" style="gap:7px">'
            f'<span class="num" style="font-size:{px}px;color:{ENEMY}">'
            f'Vantage 0001</span>{bot(ENEMY, mark)}'
            f'<div style="flex:1"></div>{cross}</div>']
    for label, value, col in DUEL_CARD:
        vcol = col or "var(--ink)"
        rows.append(f'<div class="row"><span class="lbl">{label}</span>'
                    f'<div style="flex:1"></div>'
                    f'<span class="num" style="font-size:{px}px;'
                    f'color:{vcol}">{value}</span></div>')
    card = (f'<div class="panel" style="position:absolute;left:14px;'
            f'right:14px;top:284px;padding:10px 12px;display:flex;'
            f'flex-direction:column;gap:5px">{"".join(rows)}</div>')
    return panel + card


# --- one window, one direction -----------------------------------------------


def screen(form, variant):
    w, h, compact = FORMS[form]
    mode = D_MODES[form] if variant == "D" else MODES[form]
    melee = form == "Desktop"
    ships = MELEE_SHIPS if melee else duel_ships(form)
    dead = mode.get("dead_rival", False)
    seed = {"Desktop": 3, "Landscape": 3, "Portrait": 5}[form]
    body = [scene(w, h, compact, seed, ships, dead_rival=dead)]

    chrome_top = 14
    extra = ""
    if variant == "A":
        body.append(bug_board(form, mode))
    elif variant == "B":
        body.append(tile_board(form, mode))
    elif variant == "C":
        strip, sh = strip_board(form, mode)
        body.append(strip)
        chrome_top = sh + 10
        # An upright phone has no width to put the corner row beside the
        # hanging tab, so the row drops below it.
        if form == "Portrait" and (mode["zone"] or mode["event"]):
            chrome_top = sh + 34
    else:
        # The band is drawn open where the board is about the readout, and
        # shut where it is about the quiet state.
        open_panel = form != "Landscape"
        body.append(score_band(form, mode, melee, open_panel))
        if open_panel:
            body.append(melee_readout(compact) if melee
                        else ladder_readout(compact))

    body.append(corner_row(compact, mode["humans"], mode["bots"],
                           top=chrome_top, extra=extra,
                           players=variant != "D"))
    body.append(dial_corner(form, top=chrome_top))

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
    for form in FORMS:
        for v in VARIANTS:
            # Main is the leading candidate: D, since Chris picked it.
            name = "Main" if (form, v) == ("Desktop", "D") else f"{form}{v}"
            page(name, screen(form, v))
    print(f"{len(FORMS) * len(VARIANTS)} artboards written")


if __name__ == "__main__":
    main()
