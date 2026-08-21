#!/usr/bin/env python3
"""Assemble the six .dc.html artboards for the game rethink mockups.

One script so the six screens share one design system rather than drifting.
Every color, metric and shape below is lifted from the real client:
client/arena/palette.lua for hues, client/arena/ui.lua for panel geometry
(PAD 14, COL_W 248, RADAR 168, FONT 13, LINE 18), client/ui/menu.font for
the menu face, sim/include/sim/sim.h for the ceilings.
"""

import random
from pathlib import Path

HERE = Path(__file__).parent

# --- the sky ---------------------------------------------------------------
# Three depths, same cell-hash feel as world.lua, seeded off alpha's map seed
# so every screen shows the same sky.
random.seed(28)


def starfield(w, h, far, mid, near):
    out = []
    for n, col, r in ((far, "#2a3a58", 0.9), (mid, "#4a6089", 1.0),
                      (near, "#93a9c8", 1.3)):
        for _ in range(n):
            x, y = random.randint(0, w), random.randint(0, h)
            out.append(f"radial-gradient(circle {r}px at {x}px {y}px,"
                       f"{col} 0 {r}px,transparent {r}px)")
    return ",".join(out)


STARS = starfield(1280, 720, 46, 30, 12)

# --- the palette, from client/arena/palette.lua ------------------------------
CSS = """
:root{
  --bg:#05070c; --ink:#dfe9f5; --dim:#6c7a90;
  --friend:#4fd6ff; --enemy:#ffa552;
  --rule:#3f5878; --prize:#8dffb0; --charge:#ffd166; --bounty:#ffe08a;
  --level:#ff7ba8; --mod:#9df0ff; --bomb:#ff5ea8; --burst:#c27bff;
  --hurt:#ff505a; --thrust:#ffbe78; --panel-ink:#9fb6d4;
  --nrg:#7fe3a0; --rch:#4fd6ff; --spd:#ffd166; --thr:#ff9a5c; --rot:#c79bff;
  --wall:#080d16; --wall-edge:#22344f; --wall-lit:#5b82b8;
  --r1:#62cc35; --r2:#f7dd0b; --r3:#ff7000; --r4:#f42e3d;
  --mono:"DejaVu Sans Mono","Noto Sans Mono",ui-monospace,monospace;
  --menu:"Chakra Petch","Segoe UI",system-ui,sans-serif;
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font-family:var(--menu)}
a{color:var(--friend)}a:hover{color:#8ee6ff}
.screen{position:relative;width:1280px;height:720px;overflow:hidden;
  background-color:var(--bg);background-image:STARS_HERE}

/* A panel is a translucent ground hung off a lit rule down its left edge,
   with the light spilling 26px across it. ui.lua vrule(). No borders: a box
   is the one shape this game does not contain. */
.panel{position:relative;background:rgba(5,7,12,.62)}
.panel::before{content:"";position:absolute;left:0;top:0;bottom:0;width:1.4px;
  background:rgba(63,88,120,.7)}
.panel::after{content:"";position:absolute;left:1.4px;top:0;bottom:0;width:26px;
  background:linear-gradient(90deg,rgba(63,88,120,.09),transparent);
  pointer-events:none}

/* The map border's tick, used as a rule between things. ui.lua ticks(). */
.ticks{height:3px;border-top:1px solid rgba(63,88,120,.28);
  background-image:repeating-linear-gradient(90deg,
    rgba(63,88,120,.4) 0 1px,transparent 1px 14px)}

/* A selection: bright where it meets its rule and gone across the row. */
.wash{background:linear-gradient(90deg,rgba(79,214,255,.16),rgba(79,214,255,0) 70%)}
.wash-warm{background:linear-gradient(90deg,rgba(255,165,82,.16),rgba(255,165,82,0) 70%)}

/* A count, as marks rather than a number. ui.lua pips(). */
.pips{display:flex;gap:3.1px;align-items:center}
.pip{width:4.4px;height:4.4px;border-radius:50%;flex:none}
.pip.on{background:currentColor}
.pip.off{box-shadow:inset 0 0 0 .9px currentColor;opacity:.3}
.pip.locked{box-shadow:inset 0 0 0 .9px currentColor;opacity:.1}

/* Type. The HUD is capitals, the case an instrument is labeled in; the menu
   takes a sentence's case. ui.lua cased(). */
.hud{font-family:var(--mono);text-transform:uppercase;letter-spacing:.04em}
.t9{font-size:9px}.t10{font-size:10px}.t11{font-size:11px}.t13{font-size:13px}
.dim{color:var(--dim)}
.lbl{font-family:var(--mono);font-size:9px;text-transform:uppercase;
  letter-spacing:.13em;color:var(--dim)}
.num{font-family:var(--mono);font-variant-numeric:tabular-nums}
.row{display:flex;align-items:center}
"""

# Four chamfered corners and nothing between them: what holds a cluster
# together without drawing a box round it. ui.lua bracket(), arm 14, chamfer 5.
BRACKET_SVG = ('<svg width="16" height="16" viewBox="0 0 16 16" fill="none" '
               'style="position:absolute;{pos}">'
               '<path d="M5 .7 H14 M.7 5 V14 M5 .7 L.7 5" stroke="{col}" '
               'stroke-width="1" stroke-linecap="square"/></svg>')


def bracket(col="rgba(63,88,120,.75)"):
    corners = [
        "left:0;top:0", "right:0;top:0;transform:scaleX(-1)",
        "right:0;bottom:0;transform:scale(-1,-1)",
        "left:0;bottom:0;transform:scaleY(-1)",
    ]
    return "".join(BRACKET_SVG.format(pos=p, col=col) for p in corners)


def pips(n, filled, col, locked_from=None, size=4.4, gap=3.1):
    out = []
    for k in range(n):
        if locked_from is not None and k >= locked_from:
            cls = "locked"
        elif k < filled:
            cls = "on"
        else:
            cls = "off"
        out.append(f'<div class="pip {cls}"></div>')
    return (f'<div class="pips" style="color:{col};gap:{gap}px">'
            + "".join(out) + "</div>")


# --- who is in a seat, in two marks. ui.lua helm()/bot_mark() ----------------
# A person wears a round helmet with a curved visor. A machine wears a squared
# one with two lamps and an antenna. Drawn rather than spelled.
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


# --- the roster, drawn to the extents in docs/design/ships.md ----------------
# nose / tail / side, in px, from the table there. Nose points up (-y).
HULLS = {
    "Apex":    ("M0,-20 L6,-3 L10,7 L4,5 L2,11 L-2,11 L-4,5 L-10,7 L-6,-3 Z",
                "interceptor", (20, 11, 10)),
    "Wedge":   ("M0,-13 L15,9 L7,12 L0,8 L-7,12 L-15,9 Z",
                "bomber", (13, 12, 15)),
    "Chord":   ("M0,-13 L8,-7 L17,1 L13,5 L5,2 L-5,2 L-13,5 L-17,1 L-8,-7 Z",
                "skirmisher", (13, 5, 17)),
    "Anvil":   ("M-8,-15 L8,-15 L13,-5 L13,6 L8,11 L-8,11 L-13,6 L-13,-5 Z",
                "heavy", (15, 11, 13)),
    "Cipher":  ("M0,-22 L3,-6 L6,8 L2,12 L-2,12 L-6,8 L-3,-6 Z",
                "stealth", (22, 12, 6)),
    "Facet":   ("M0,-8 L11,-1 L8,12 L-8,12 L-11,-1 Z",
                "brawler", (14, 12, 11)),
    "Lattice": ("M-4,-16 L4,-16 L4,-5 L14,-5 L14,4 L4,4 L4,14 L-4,14 L-4,4 "
                "L-14,4 L-14,-5 L-4,-5 Z", "denial", (16, 14, 14)),
}

# Interior detail draws in a neutral instrument gray, so the team read stays on
# the outline. The canopy is the brightest cell and always forward of center.
EXTRA = {
    "Facet": ('<rect x="-6.5" y="-13" width="2.6" height="6" fill="{ink}" '
              'opacity=".55"/><rect x="3.9" y="-13" width="2.6" height="6" '
              'fill="{ink}" opacity=".55"/>'),
    "Anvil": ('<rect x="-6" y="-16.5" width="4" height="3" fill="{ink}" '
              'opacity=".5"/><rect x="2" y="-16.5" width="4" height="3" '
              'fill="{ink}" opacity=".5"/>'),
    "Wedge": ('<path d="M0,-9 L0,7" stroke="{lit}" stroke-width="1.6" '
              'opacity=".7"/>'),
    "Lattice": ('<circle cx="-13" cy="0" r="2" fill="{ink}" opacity=".55"/>'
                '<circle cx="13" cy="0" r="2" fill="{ink}" opacity=".55"/>'
                '<circle cx="0" cy="13" r="2" fill="{ink}" opacity=".55"/>'),
    "Chord": ('<circle cx="0" cy="-2" r="3.2" stroke="{ink}" stroke-width="1" '
              'fill="none" opacity=".6"/>'),
}

CANOPY = {
    "Apex": (0, -9, 2.4), "Wedge": (0, -4, 2.6), "Chord": (0, -7, 2.4),
    "Anvil": (0, -8, 3.0), "Cipher": (0, -11, 1.8), "Facet": (0, -2, 2.8),
    "Lattice": (0, -9, 2.4),
}


HULL_SEQ = [0]


def hull(name, col, k=1.0, dim=False, canopy=True):
    """One hull, nose up. Lit from its own nose per identity.md."""
    path, _, _ = HULLS[name]
    HULL_SEQ[0] += 1
    gid = f"g{name}{HULL_SEQ[0]}"
    op = ".55" if dim else "1"
    ink, lit = "#9fb6d4", "#dfe9f5"
    extra = EXTRA.get(name, "").format(ink=ink, lit=lit)
    cap = ""
    if canopy:
        cx, cy, cr = CANOPY[name]
        cap = (f'<ellipse cx="{cx}" cy="{cy}" rx="{cr}" ry="{cr * 1.5}" '
               f'fill="{lit}" opacity=".8"/>')
    side = 52 * k
    return (f'<svg width="{side}" height="{side}" viewBox="-26 -26 52 52" '
            f'style="flex:none;overflow:visible">'
            f'<defs><linearGradient id="{gid}" x1="0" y1="0" x2="0" y2="1">'
            f'<stop offset="0" stop-color="#3a4a63"/>'
            f'<stop offset="1" stop-color="#080d16"/></linearGradient></defs>'
            f'<path d="{path}" fill="url(#{gid})" stroke="{col}" '
            f'stroke-width="1.5" opacity="{op}" stroke-linejoin="round"/>'
            f'{extra}{cap}</svg>')


# --- charge marks ------------------------------------------------------------
def mark_repel(col, k=13):
    return (f'<svg width="{k}" height="{k}" viewBox="0 0 16 16" fill="none">'
            f'<circle cx="8" cy="8" r="2" fill="{col}"/>'
            f'<circle cx="8" cy="8" r="5" stroke="{col}" stroke-width="1" '
            f'opacity=".7"/><circle cx="8" cy="8" r="7.3" stroke="{col}" '
            f'stroke-width=".9" opacity=".35"/></svg>')


def mark_burst(col, k=13):
    spokes = "".join(
        f'<path d="M8 8 L{8 + 6.4 * __import__("math").cos(a):.1f} '
        f'{8 + 6.4 * __import__("math").sin(a):.1f}" stroke="{col}" '
        f'stroke-width=".9" opacity=".75"/>'
        for a in [i * 3.14159 / 4 for i in range(8)])
    return (f'<svg width="{k}" height="{k}" viewBox="0 0 16 16" fill="none">'
            f'{spokes}<circle cx="8" cy="8" r="2.2" fill="{col}"/></svg>')


def mark_brick(col, k=13):
    return (f'<svg width="{k}" height="{k}" viewBox="0 0 16 16" fill="none">'
            f'<rect x="2" y="5" width="12" height="6" stroke="{col}" '
            f'stroke-width="1.1"/><path d="M8 5 V11" stroke="{col}" '
            f'stroke-width=".9" opacity=".6"/></svg>')


def mark_decoy(col, k=13):
    return (f'<svg width="{k}" height="{k}" viewBox="0 0 16 16" fill="none">'
            f'<path d="M8 2.5 L11 11 L8 9.2 L5 11 Z" stroke="{col}" '
            f'stroke-width="1.1" stroke-linejoin="round"/>'
            f'<path d="M8 2.5 L11 11 L8 9.2 L5 11 Z" stroke="{col}" '
            f'stroke-width="1.1" stroke-linejoin="round" opacity=".3" '
            f'transform="translate(3.4,1.6)"/></svg>')


def mark_diamond(col, k=12):
    return (f'<svg width="{k}" height="{k}" viewBox="0 0 12 12" fill="none">'
            f'<path d="M6 1 L11 6 L6 11 L1 6 Z" fill="{col}"/></svg>')


# A rivet: the currency wears a drawn mark rather than a hue, because every
# hue in this game already means something in the arena. See the handover note.
def rivet(col="#dfe9f5", k=12):
    return (f'<svg width="{k}" height="{k}" viewBox="0 0 12 12" fill="none" '
            f'style="flex:none">'
            f'<circle cx="6" cy="6" r="4.4" stroke="{col}" stroke-width="1.1"/>'
            f'<circle cx="6" cy="6" r="1.7" fill="{col}"/>'
            f'<path d="M6 1.6 V3" stroke="{col}" stroke-width="1"/>'
            f'<path d="M6 9 V10.4" stroke="{col}" stroke-width="1"/></svg>')


def wordmark(k=1.0):
    """The aligned 2x3 wedge mark, 18x22 with a 9px gap. See memory: the site
    mark is aligned colored rows."""
    o, c = "#ff9d22", "#27c5ed"
    w, h = 46 * k, 26 * k
    return (f'<svg width="{w}" height="{h}" viewBox="0 0 46 26" fill="none" '
            f'style="flex:none">'
            f'<path d="M2 3 H20 L15 9 H2 Z" fill="{c}"/>'
            f'<path d="M2 10 H16 L11 16 H2 Z" fill="{o}"/>'
            f'<path d="M2 17 H12 L7 23 H2 Z" fill="{c}" opacity=".75"/>'
            f'<path d="M26 3 H44 L39 9 H26 Z" fill="{o}"/>'
            f'<path d="M26 10 H40 L35 16 H26 Z" fill="{c}"/>'
            f'<path d="M26 17 H36 L31 23 H26 Z" fill="{o}" opacity=".75"/>'
            f'</svg>')


def page(name, body, script=""):
    css = CSS.replace("STARS_HERE", STARS)
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
  <style>{css}{EXTRA_CSS.get(name, '')}</style>
</helmet>
{body}
</x-dc>
{script}
</body>
</html>
"""
    (HERE / f"{name}.dc.html").write_text(doc)
    return doc


EXTRA_CSS = {}


# --- chrome shared by the three menu screens --------------------------------
NAV = ["Play", "Hangar", "Shop", "Standings", "Pilot", "Settings"]


def discord(col="currentColor", w=19):
    return (f'<svg width="{w}" height="{int(w * 16 / 21)}" viewBox="0 0 21 17" '
            f'fill="{col}" style="flex:none">'
            f'<path d="M17.7 2.6A15 15 0 0 0 14 1.4l-.2.4a13.8 13.8 0 0 1 3.3 1.1 '
            f'12.6 12.6 0 0 0-10.6 0A13.9 13.9 0 0 1 9.8 1.8L9.6 1.4A15 15 0 0 0 '
            f'5.9 2.6C3.3 6.5 2.6 10.3 2.9 14a15.1 15.1 0 0 0 4.6 2.3l1-1.6a9.8 '
            f'9.8 0 0 1-1.6-.8l.4-.3a10.8 10.8 0 0 0 9 0l.4.3a9.7 9.7 0 0 1-1.6.8'
            f'l1 1.6a15 15 0 0 0 4.6-2.3c.4-4.3-.7-8.1-3-11.4ZM8.5 11.8c-.9 0-1.6-.8'
            f'-1.6-1.8s.7-1.8 1.6-1.8 1.6.8 1.6 1.8-.7 1.8-1.6 1.8Zm4.6 0c-.9 0-1.6'
            f'-.8-1.6-1.8s.7-1.8 1.6-1.8 1.6.8 1.6 1.8-.7 1.8-1.6 1.8Z"/></svg>')


def topbar(current, rivets="342"):
    items = []
    for n in NAV:
        on = n == current
        col = "var(--friend)" if on else "var(--dim)"
        w = ('<div style="height:1.4px;background:var(--friend);margin-top:5px">'
             '</div>') if on else ""
        items.append(f'<div style="font-size:15px;color:{col}">{n}{w}</div>')
    nav = ('<div style="display:flex;gap:21px;align-items:flex-start">'
           + "".join(items) + "</div>")
    return f"""
  <div class="row" style="height:56px;padding:0 56px;gap:34px;
       background:rgba(5,7,12,.55)">
    {wordmark(.86)}
    {nav}
    <div style="flex:1"></div>
    <div class="row" style="gap:8px">
      {helm('var(--friend)', 13)}
      <div style="font-size:15px">Quarrel</div>
      <div class="lbl" style="color:var(--friend);letter-spacing:.18em">Ace</div>
    </div>
    <div class="row" style="gap:7px">{rivet()}
      <div class="num" style="font-size:15px">{rivets}</div>
      <div class="lbl">rivets</div>
    </div>
  </div>
  <div class="ticks" style="margin:0 56px"></div>"""


def minimap(side, seed, cls_a="#3f5878", spawn=True):
    """A small map in radar terms: wall blips on RADAR_BG, brackets round it."""
    rnd = random.Random(seed)
    blips = []
    for _ in range(26):
        cx, cy = rnd.randint(6, 94), rnd.randint(6, 94)
        w, h = rnd.choice([(6, 3), (3, 7), (5, 5), (9, 3), (3, 10)])
        blips.append(f'<rect x="{cx}" y="{cy}" width="{w}" height="{h}" '
                     f'fill="{cls_a}" opacity=".85"/>')
        # mirrored, because a 4v4 map is symmetric
        blips.append(f'<rect x="{100 - cx - w}" y="{100 - cy - h}" width="{w}" '
                     f'height="{h}" fill="{cls_a}" opacity=".85"/>')
    marks = ""
    if spawn:
        marks = ('<circle cx="14" cy="86" r="3.4" fill="#4fd6ff"/>'
                 '<circle cx="86" cy="14" r="3.4" fill="#ffa552"/>')
    return (f'<div style="position:relative;width:{side}px;height:{side}px">'
            f'<svg width="{side}" height="{side}" viewBox="0 0 100 100" '
            f'style="background:#060a10">{"".join(blips)}{marks}</svg>'
            f'{bracket("rgba(63,88,120,.8)")}</div>')


def seat_row(name, col, humans, you):
    seats = []
    for i, h in enumerate(humans):
        if you is not None and i == you:
            seats.append(f'<div style="position:relative;padding:0 3px">'
                         f'{helm(col, 13)}</div>')
        else:
            seats.append(helm(col, 13) if h else bot("var(--dim)", 13))
    tag = ('<div class="lbl" style="color:var(--friend)">you</div>'
           if you is not None else "")
    return (f'<div class="row" style="height:28px;gap:9px">'
            f'<div class="t10 num" style="color:{col};min-width:74px">{name}</div>'
            f'<div class="row" style="gap:7px">{"".join(seats)}</div>'
            f'<div style="flex:1"></div>{tag}</div>')


def kitdots(spent=30, total=30):
    """The kit budget as a run of marks. Thirty greens, chosen."""
    cells = []
    for k in range(total):
        on = k < spent
        cells.append(f'<div style="width:5px;height:5px;flex:none;'
                     f'background:{"#8dffb0" if on else "transparent"};'
                     f'box-shadow:{"none" if on else "inset 0 0 0 .9px #8dffb0"};'
                     f'opacity:{1 if on else .28};'
                     f'transform:rotate(45deg)"></div>')
    return ('<div style="display:flex;gap:4px;flex-wrap:wrap;max-width:300px">'
            + "".join(cells) + "</div>")


# =============================================================================
# 1. Match list: four modes, all startable now. No rotation, because rationing
#    a queue is a thing you do to a population you have; and no open arena.
# =============================================================================
MODES = [
    ("Melee", "kills", 2, True,
     "Four a side, three minutes. Most kills takes it."),
    ("Capture", "flags", 1, False,
     "Carry theirs home. Holding it makes you worth more, which is how it "
     "gets contested."),
    ("Holdfast", "one room", 1, False,
     "One room on the map pays whoever holds it. Standing in it is the whole "
     "job, which is why the hulls that cannot hold ground struggle here."),
]

FRIENDS = [
    ("MARLOW", "in a match", "2:10 left", "var(--friend)"),
    ("CORVID", "in the hangar", "", "var(--friend)"),
    ("TALLOW", "offline", "", ""),
]


def s_matchlist():
    rows = []
    for name, kind, rooms, sel, _ in MODES:
        live = (f'<div class="row" style="gap:5px">{helm("var(--dim)", 11)}'
                f'<div class="num t11 dim">{rooms * 3 + 2}</div></div>'
                if rooms else '<div class="lbl" style="opacity:.6">'
                              'nobody in one</div>')
        cursor = ('<div style="color:var(--friend);font-size:13px;width:14px">'
                  '&#9654;</div>') if sel else '<div style="width:14px"></div>'
        last = ('<div class="lbl" style="color:var(--friend)">last</div>'
                if sel else "")
        rows.append(f"""
      <div class="row {'wash' if sel else ''}" style="height:52px;padding:0 16px;gap:14px">
        {cursor}
        <div style="font-size:22px;min-width:136px">{name}</div>
        <div class="lbl" style="min-width:56px">{kind}</div>
        {last}<div style="flex:1"></div>{live}
      </div>""")

    friends = []
    for name, where, extra, col in FRIENDS:
        on = bool(col)
        dot = (f'<div style="width:6px;height:6px;flex:none;border-radius:50%;'
               f'background:{"var(--prize)" if on else "var(--dim)"};'
               f'opacity:{1 if on else .4}"></div>')
        act = ('<div class="t10 num" style="color:var(--friend)">JOIN</div>'
               if where == "in a match" else "")
        friends.append(f"""
        <div class="row" style="height:32px;gap:9px;opacity:{1 if on else .45}">
          {dot}{helm("var(--dim)", 12)}
          <div class="t11 num">{name}</div>
          <div style="flex:1"></div>
          <div class="lbl">{where}</div>
          <div class="lbl" style="color:var(--bounty);min-width:44px;
               text-align:right">{extra}</div>
          <div style="min-width:30px;text-align:right">{act}</div>
        </div>""")

    body = f"""
<div class="screen">
  {topbar("Play")}
  <div class="row" style="align-items:flex-start;gap:36px;padding:30px 56px 0">
    <div style="flex:1">
      <div class="panel" style="padding:14px 0 8px">
        {''.join(rows)}
      </div>
      <div style="padding:18px 30px 0;font-size:15px;color:var(--dim);
           max-width:600px;line-height:1.5;text-wrap:pretty">
        {MODES[0][4]}
      </div>
      <div class="row" style="gap:9px;padding:22px 30px 0">
        {mark_diamond("var(--dim)", 10)}
        <div style="font-size:13px;color:var(--dim);text-wrap:pretty;
             max-width:520px;line-height:1.5">
          Every mode starts on demand. If nobody is in one, you open it and
          the bots take the other seats.
        </div>
      </div>

      <div class="panel" style="margin-top:30px;padding:14px 18px 12px">
        <div class="row">
          <div class="lbl">Friends</div>
          <div style="flex:1"></div>
          <div class="lbl" style="opacity:.65">2 of 3 on</div>
        </div>
        <div class="ticks" style="margin:9px 0 4px"></div>
        {''.join(friends)}
        <div class="ticks" style="margin:6px 0 0"></div>
        <div class="row" style="height:38px;gap:10px">
          {discord("var(--dim)")}
          <div style="font-size:14px;color:var(--dim)">Talk on Discord</div>
          <div style="flex:1"></div>
          <div class="lbl" style="opacity:.6">the game carries no chat</div>
        </div>
      </div>
    </div>

    <div class="panel" style="width:404px;padding:18px 22px 22px">
      <div class="row">
        <div class="lbl">deploying to</div>
        <div style="flex:1"></div>
        <div class="lbl" style="opacity:.7">the busiest room</div>
      </div>
      <div class="row" style="gap:16px;margin-top:10px">
        {minimap(104, 7)}
        <div>
          <div style="font-size:20px">Drydock</div>
          <div class="lbl" style="margin-top:4px">112 sq &#183; two pockets</div>
          <div class="row" style="gap:8px;margin-top:11px">
            <div class="t10 num" style="color:var(--bounty)">IN PROGRESS</div>
            <div class="t10 num dim">1:20 LEFT</div>
          </div>
          <div class="lbl" style="margin-top:6px;opacity:.75">
            you spawn straight in</div>
        </div>
      </div>
      <div class="ticks" style="margin:16px 0 12px"></div>
      <div class="lbl">who is in it</div>
      {seat_row("BASTION", "var(--friend)", [1, 1, 0, 0], None)}
      {seat_row("CAISSON", "var(--enemy)", [1, 0, 0, 0], 2)}
      <div class="row" style="gap:8px;margin-top:9px">
        {mark_diamond("var(--dim)", 10)}
        <div class="t11 num dim">A BOT STANDS DOWN FOR YOU</div>
      </div>
      <div class="ticks" style="margin:20px 0 16px"></div>
      <div class="lbl">flying</div>
      <div class="row" style="gap:14px;margin-top:8px">
        {hull("Apex", "var(--friend)", .78)}
        <div>
          <div style="font-size:19px">Apex</div>
          <div class="lbl" style="margin-top:3px">interceptor</div>
        </div>
        <div style="flex:1"></div>
        <div style="text-align:right">
          <div class="row" style="gap:6px;justify-content:flex-end">
            {mark_diamond("var(--prize)", 11)}
            <div class="num" style="font-size:17px;color:var(--prize)">30</div>
          </div>
          <div class="lbl" style="margin-top:2px">kit</div>
        </div>
      </div>
      <div style="margin-top:12px">{kitdots(30, 30)}</div>
      <div class="row" style="gap:8px;margin-top:10px">
        {mark_diamond("var(--dim)", 10)}
        <div class="t11 num dim">DEALT TO YOUR HULL AT EVERY SPAWN</div>
      </div>
      <div class="ticks" style="margin:20px 0 14px"></div>
      <div class="row" style="gap:12px">
        <div class="row" style="position:relative;padding:9px 18px;gap:10px">
          {bracket("rgba(79,214,255,.85)")}
          <div class="t11 num" style="color:var(--friend)">ENTER</div>
          <div style="font-size:15px">Play</div>
        </div>
        <div class="row" style="gap:9px;padding:9px 4px">
          <div class="t11 num dim">H</div>
          <div style="font-size:15px;color:var(--dim)">Hangar</div>
        </div>
      </div>
    </div>
  </div>
</div>"""
    page("MatchList", body)


# =============================================================================
# 2. Main: the hangar. The kit is thirty greens, chosen instead of dealt.
#    The pips here actually spend, because the budget is the thing under review.
# =============================================================================
EXTRA_CSS["Main"] = """
.chip{position:relative;display:flex;flex-direction:column;align-items:center;
  justify-content:center;gap:2px;height:34px;width:54px;cursor:pointer;
  font-family:var(--mono);font-size:9px;letter-spacing:.1em;
  text-transform:uppercase}
.kpip{width:7px;height:7px;flex:none;transform:rotate(45deg);cursor:pointer}
.krow{display:flex;align-items:center;gap:12px;height:28px}
.hullrow{display:flex;align-items:center;gap:11px;height:44px;padding:0 12px;
  cursor:default}
"""


def hull_list():
    out = []
    for name, (_, role, _) in HULLS.items():
        sel = name == "Apex"
        col = "var(--friend)" if sel else "var(--dim)"
        out.append(f"""
      <div class="hullrow {'wash' if sel else ''}">
        <div style="width:26px;display:flex;justify-content:center">
          {hull(name, col, .5, dim=not sel, canopy=False)}</div>
        <div>
          <div style="font-size:16px;color:{'var(--ink)' if sel else 'var(--dim)'}">
            {name}</div>
        </div>
        <div style="flex:1"></div>
        <div class="lbl" style="font-size:8px">{role}</div>
      </div>""")
    return "".join(out)


MAIN_SCRIPT = """<script data-dc-script data-props='{"budget":{"editor":"int","default":30,"min":10,"max":60,"unit":" pts","section":"Kit"},"$preview":{"width":1280,"height":720}}'>
class Component extends DCLogic {
  constructor(props) {
    super(props);
    // Thirty is what alpha already deals a fresh spawn (spawn_prizes = 30).
    // The kit does not add anything: it chooses what those thirty are.
    this.state = {
      up: [2, 4, 8, 5, 1],          // NRG RCH SPD THR ROT; base 6, bought to 8
      gun: 2, bomb: 1,              // rungs; Apex tops out at gun 2, bomb 1
      gmods: [1, 1, 1, 0, 0, 0],    // multi bounce prox shrapnel freeze repel
      bmods: [0, 0, 1, 0, 0, 0],
      chg: [3, 2]                   // repel, burst
    };
  }

  total() { return this.props.budget ?? 30; }

  spent() {
    const s = this.state;
    const sum = (a) => a.reduce((x, y) => x + y, 0);
    return sum(s.up) + (s.gun - 1) + (s.bomb - 1)
         + sum(s.gmods) + sum(s.bmods) + sum(s.chg);
  }

  // Nothing may be slotted that the budget cannot pay for. A refund is always
  // allowed, which is what keeps a player from getting stuck.
  try_set(path, idx, next) {
    const s = this.state;
    const cur = idx === null ? s[path] : s[path][idx];
    const delta = next - cur;
    if (delta > 0 && this.spent() + delta > this.total()) return;
    if (idx === null) { this.setState({ [path]: next }); }
    else { const a = s[path].slice(); a[idx] = next; this.setState({ [path]: a }); }
  }

  // Clicking the last filled mark refunds it; clicking any other sets to there.
  cellsFor(path, idx, count, ceiling, roster, col) {
    const out = [];
    for (let k = 0; k < ceiling; k++) {
      const on = k < count, live = k < roster;
      const next = (count === k + 1) ? k : k + 1;
      out.push({
        style: 'background:' + (on ? col : 'transparent')
             + ';box-shadow:' + (on ? 'none' : 'inset 0 0 0 1px ' + col)
             + ';opacity:' + (on ? 1 : live ? 0.32 : 0.16)
             + ';cursor:' + (live ? 'pointer' : 'default'),
        pick: live ? () => this.try_set(path, idx, next) : null
      });
    }
    return out;
  }

  chipStyle(state, col) {
    if (state === 'off') return 'color:#6c7a90;opacity:.22;cursor:default;'
      + 'box-shadow:inset 0 0 0 1px #6c7a90';
    if (state === 'locked') return 'color:#6c7a90;opacity:.5;cursor:default;'
      + 'box-shadow:inset 0 0 0 1px rgba(108,122,144,.5)';
    if (state === 'on') return 'color:' + col + ';box-shadow:inset 0 0 0 1px '
      + col + ';background:linear-gradient(180deg,rgba(157,240,255,.13),transparent)';
    return 'color:' + col + ';opacity:.62;box-shadow:inset 0 0 0 1px '
      + 'rgba(157,240,255,.32)';
  }

  modRow(path, owned, roster) {
    const NAMES = ['MUL', 'BNC', 'PRX', 'SHR', 'FRZ', 'RPL'];
    const held = this.state[path];
    return NAMES.map((short, i) => {
      const on = held[i] > 0;
      const st = !roster[i] ? 'off' : !owned[i] ? 'locked' : on ? 'on' : 'idle';
      return {
        short,
        note: st === 'off' ? 'hull' : st === 'locked' ? '· 40' : on ? '1 pt' : '',
        style: this.chipStyle(st, '#9df0ff'),
        pick: (roster[i] && owned[i])
          ? () => this.try_set(path, i, on ? 0 : 1) : null
      };
    });
  }

  rungRow(path, max, roster) {
    const lvl = this.state[path];
    return [1, 2, 3].map((n) => {
      const st = n > roster ? 'off' : n > max ? 'locked'
               : n === lvl ? 'on' : 'idle';
      const RUNG = ['#62cc35', '#f7dd0b', '#ff7000'];
      return {
        short: 'L' + n,
        note: st === 'off' ? 'hull' : st === 'locked' ? '· 90'
            : n === 1 ? 'base' : (n - 1) + ' pt',
        style: this.chipStyle(st, RUNG[n - 1]),
        pick: (n <= max) ? () => this.try_set(path, null, n) : null
      };
    });
  }

  renderVals() {
    const s = this.state, total = this.total(), spent = this.spent();
    const left = total - spent;
    const STATS = [
      ['NRG', 'energy',   '#7fe3a0'], ['RCH', 'recharge', '#4fd6ff'],
      ['SPD', 'speed',    '#ffd166'], ['THR', 'thrust',   '#ff9a5c'],
      ['ROT', 'rotation', '#c79bff']
    ];
    return {
      total, spent, left,
      leftStyle: 'color:' + (left === 0 ? '#8dffb0' : left < 0 ? '#ff505a'
                 : '#ffe08a'),
      barStyle: 'width:' + Math.max(0, Math.min(100, spent / total * 100))
              + '%;background:' + (left === 0 ? '#8dffb0' : '#4fd6ff'),
      // Every stat runs to six for everybody. The last two steps are the
      // shop's, and only deep speed is bought here, which is what lets SPD
      // sit at eight. See Shop.dc.html.
      stats: STATS.map(([short, name, col], i) => {
        const all = this.cellsFor('up', i, s.up[i], 8, [6, 6, 8, 6, 6][i], col);
        return { short, name, count: s.up[i],
                 cells: all.slice(0, 6), deep: all.slice(6) };
      }),
      // Apex: gun ladder tops at L2, bombs at L1. ships.md.
      gunRungs: this.rungRow('gun', 2, 2),
      bombRungs: this.rungRow('bomb', 1, 1),
      // owned = bought in the shop; roster = the hull may ever hold it.
      // The add-on repel belongs to Lattice alone, so it is off-roster here.
      gunMods: this.modRow('gmods', [1, 1, 1, 0, 0, 0], [1, 1, 1, 1, 1, 0]),
      bombMods: this.modRow('bmods', [1, 1, 1, 0, 0, 0], [0, 1, 1, 1, 0, 0]),
      repel: this.cellsFor('chg', 0, s.chg[0], 6, 6, '#ffd166'),
      burst: this.cellsFor('chg', 1, s.chg[1], 6, 6, '#ffd166'),
      repelN: s.chg[0], burstN: s.chg[1]
    };
  }
}
</script>"""


def s_main():
    def chiprow(binding, count):
        return f"""
        <div class="row" style="gap:8px">
          <sc-for list="{{{{{binding}}}}}" as="c" hint-placeholder-count="{count}">
            <div class="chip" style="{{{{c.style}}}}" onClick="{{{{c.pick}}}}">
              <div>{{{{c.short}}}}</div>
              <div style="font-size:8px;opacity:.6">{{{{c.note}}}}</div>
            </div>
          </sc-for>
        </div>"""

    body = f"""
<div class="screen">
  {topbar("Hangar")}
  <div class="row" style="align-items:flex-start;gap:22px;padding:22px 56px 0">

    <div class="panel" style="width:196px;padding:10px 0">
      <div class="lbl" style="padding:0 12px 8px">Hull</div>
      {hull_list()}
    </div>

    <div class="panel" style="width:268px;padding:18px 20px">
      <div style="display:flex;justify-content:center;padding:14px 0 6px">
        {hull("Apex", "var(--friend)", 2.1)}
      </div>
      <div style="text-align:center;font-size:26px;margin-top:6px">Apex</div>
      <div class="lbl" style="text-align:center;margin-top:4px">interceptor</div>
      <div style="text-align:center;font-size:13px;color:var(--dim);
           margin-top:12px;line-height:1.5;text-wrap:pretty">
        Catches things. Thin enough that one mistake ends it.
      </div>
      <div class="ticks" style="margin:18px 0 14px"></div>
      <div class="lbl" style="margin-bottom:9px">Hull limits</div>
      <div class="row" style="justify-content:space-between;height:22px">
        <div class="t10 num dim">GUN LADDER</div>
        <div class="t10 num" style="color:var(--r2)">L2</div></div>
      <div class="row" style="justify-content:space-between;height:22px">
        <div class="t10 num dim">BOMB LADDER</div>
        <div class="t10 num" style="color:var(--r1)">L1</div></div>
      <div class="row" style="justify-content:space-between;height:22px">
        <div class="t10 num dim">CHARGE SLOTS</div>
        <div class="t10 num">2</div></div>
      <div class="row" style="justify-content:space-between;height:22px">
        <div class="t10 num dim">HITBOX</div>
        <div class="t10 num">20 / 11 / 10</div></div>
    </div>

    <div class="panel" style="flex:1;padding:16px 24px 20px">
      <div class="row" style="gap:14px">
        <div class="lbl" style="letter-spacing:.2em">Kit</div>
        <div style="flex:1;height:5px;background:rgba(63,88,120,.28);
             position:relative;overflow:hidden">
          <div style="height:100%;{{{{barStyle}}}}"></div>
        </div>
        <div class="num" style="font-size:19px">{{{{spent}}}}</div>
        <div class="num dim" style="font-size:13px">/ {{{{total}}}}</div>
        <div class="num" style="font-size:15px;{{{{leftStyle}}}}">
          {{{{left}}}} left</div>
      </div>
      <div class="row" style="gap:7px;margin-top:7px">
        {mark_diamond("var(--prize)", 10)}
        <div class="t9 num dim">EVERY SLOT COSTS ONE &#183;
          THIRTY IS WHAT A SPAWN IS ALREADY DEALT</div>
      </div>

      <div class="ticks" style="margin:14px 0 10px"></div>
      <div class="row" style="gap:10px;margin-bottom:4px">
        <div class="lbl">Stats</div>
        <div class="lbl" style="opacity:.55">six a stat is the whole budget
          &#183; the last two are bought</div>
      </div>
      <sc-for list="{{{{stats}}}}" as="s" hint-placeholder-count="5">
        <div class="krow">
          <div class="t10 num dim" style="width:32px">{{{{s.short}}}}</div>
          <div style="display:flex;gap:5px">
            <sc-for list="{{{{s.cells}}}}" as="c" hint-placeholder-count="6">
              <div class="kpip" style="{{{{c.style}}}}" onClick="{{{{c.pick}}}}"></div>
            </sc-for>
          </div>
          <div style="width:1px;height:11px;background:rgba(63,88,120,.55)"></div>
          <div style="display:flex;gap:5px">
            <sc-for list="{{{{s.deep}}}}" as="d" hint-placeholder-count="2">
              <div class="kpip" style="{{{{d.style}}}}" onClick="{{{{d.pick}}}}"></div>
            </sc-for>
          </div>
          <div class="num t11" style="width:14px;opacity:.75">{{{{s.count}}}}</div>
          <div class="dim" style="font-size:12px">{{{{s.name}}}}</div>
        </div>
      </sc-for>

      <div class="ticks" style="margin:12px 0 10px"></div>
      <div class="row" style="align-items:flex-start;gap:26px">
        <div>
          <div class="lbl" style="margin-bottom:7px">Gun</div>
          {chiprow("gunRungs", 3)}
          <div style="height:8px"></div>
          {chiprow("gunMods", 6)}
        </div>
      </div>
      <div style="height:12px"></div>
      <div>
        <div class="lbl" style="margin-bottom:7px">Bomb</div>
        {chiprow("bombRungs", 3)}
        <div style="height:8px"></div>
        {chiprow("bombMods", 6)}
      </div>

      <div class="ticks" style="margin:14px 0 10px"></div>
      <div class="row" style="gap:10px">
        <div class="lbl">Charges</div>
        <div class="lbl" style="opacity:.55">two slots &#183; spent charges do
          not come back when you die</div>
      </div>
      <div class="row" style="gap:34px;margin-top:8px">
        <div class="row" style="gap:10px">
          {mark_repel("var(--charge)")}
          <div style="font-size:14px;width:52px">Repel</div>
          <div style="display:flex;gap:5px">
            <sc-for list="{{{{repel}}}}" as="c" hint-placeholder-count="6">
              <div class="kpip" style="{{{{c.style}}}}" onClick="{{{{c.pick}}}}"></div>
            </sc-for>
          </div>
          <div class="num t11" style="opacity:.75">{{{{repelN}}}}</div>
        </div>
        <div class="row" style="gap:10px">
          {mark_burst("var(--charge)")}
          <div style="font-size:14px;width:52px">Burst</div>
          <div style="display:flex;gap:5px">
            <sc-for list="{{{{burst}}}}" as="c" hint-placeholder-count="6">
              <div class="kpip" style="{{{{c.style}}}}" onClick="{{{{c.pick}}}}"></div>
            </sc-for>
          </div>
          <div class="num t11" style="opacity:.75">{{{{burstN}}}}</div>
        </div>
      </div>
      <div class="row" style="gap:13px;margin-top:11px">
        <div class="lbl" style="width:52px">kinds</div>
        <div class="row" style="gap:9px">
          {mark_repel("var(--charge)", 15)}{mark_burst("var(--charge)", 15)}
          <svg width="15" height="15" viewBox="0 0 16 16" fill="none">
            <circle cx="8" cy="8" r="3" fill="#ffd166"/>
            <circle cx="8" cy="8" r="6.4" stroke="#ffd166" stroke-width="1"
              stroke-dasharray="1.6 2.4" opacity=".8"/></svg>
        </div>
        <div class="lbl" style="opacity:.7">held</div>
        <div style="width:14px"></div>
        <div class="row" style="gap:9px;opacity:.3">
          {mark_brick("var(--dim)", 15)}{mark_decoy("var(--dim)", 15)}
        </div>
        <div class="lbl" style="opacity:.45">in the shop</div>
      </div>
    </div>
  </div>
</div>"""
    page("Main", body, MAIN_SCRIPT)


# =============================================================================
# 3. Shop: rivets buy what you may SLOT, never how much you may slot.
# =============================================================================
SHOP = [
    ("Stats", [
        ("Deep speed", "The seventh and eighth step of SPD", 120, "owned", ""),
        ("Deep thrust", "The seventh and eighth step of THR", 120, "buy", ""),
        ("Deep rotation", "The seventh and eighth step of ROT", 120, "buy", ""),
        ("Deep energy", "The seventh and eighth step of NRG", 120, "buy", ""),
        ("Deep recharge", "The seventh and eighth step of RCH", 120, "buy", ""),
    ]),
    ("Triggers", [
        ("Gun rung 3", "The third rung, on hulls that reach it", 90, "buy",
         "Apex tops at 2"),
        ("Shrapnel", "Bombs break into gun-rung fragments", 40, "buy", ""),
        ("Freeze", "Stalls the recharge of whoever it reaches", 40, "buy", ""),
        ("Proximity", "A fuse, so it need not touch", 40, "owned", ""),
    ]),
    ("Charges", [
        ("Brick", "Drop a wall that lasts a while", 60, "buy", ""),
        ("Decoy", "A copy of you, flying the way you were", 60, "buy", ""),
    ]),
    ("Livery", [
        ("Ember wake", "Your trail, burnt orange", 200, "buy", ""),
        ("Hairline wake", "Your trail, thin and white", 200, "owned", ""),
    ]),
]


def s_shop():
    rail = []
    for i, (cat, _) in enumerate(SHOP):
        sel = i == 0
        rail.append(f"""
      <div class="row {'wash' if sel else ''}" style="height:38px;padding:0 14px">
        <div style="font-size:15px;color:{'var(--ink)' if sel else 'var(--dim)'}">
          {cat}</div></div>""")

    cards = []
    for cat, items in SHOP:
        cards.append(f'<div class="lbl" style="grid-column:1/-1;margin-top:6px">'
                     f'{cat}</div>')
        for name, line, price, state, note in items:
            owned = state == "owned"
            notediv = (f'<div class="lbl" style="opacity:.7;margin-top:3px">'
                       f'{note}</div>') if note else ""
            pricebox = (f'<div class="row" style="gap:6px">'
                        f'<div class="t10 num" style="color:var(--prize)">HELD</div>'
                        f'</div>') if owned else (
                        f'<div class="row" style="gap:6px">{rivet("#dfe9f5", 11)}'
                        f'<div class="num" style="font-size:15px">{price}</div></div>')
            cards.append(f"""
        <div class="panel" style="padding:11px 14px;position:relative;
             opacity:{'.62' if owned else '1'}">
          <div class="row" style="gap:10px">
            <div style="font-size:16px">{name}</div>
            <div style="flex:1"></div>{pricebox}
          </div>
          <div style="font-size:12px;color:var(--dim);margin-top:5px;
               line-height:1.35;min-height:26px;text-wrap:pretty">{line}</div>
          {notediv}
        </div>""")

    body = f"""
<div class="screen">
  {topbar("Shop")}
  <div class="row" style="align-items:flex-start;gap:26px;padding:24px 56px 0">
    <div style="width:180px">
      <div class="panel" style="padding:10px 0">
        <div class="lbl" style="padding:0 14px 8px">Bench</div>
        {''.join(rail)}
      </div>
      <div class="panel" style="margin-top:18px;padding:15px">
        <div class="lbl">Balance</div>
        <div class="row" style="gap:9px;margin-top:9px">
          {rivet("#dfe9f5", 17)}
          <div class="num" style="font-size:25px">342</div>
        </div>
        <div class="lbl" style="margin-top:9px;opacity:.7">+19 last match</div>
      </div>
    </div>

    <div style="flex:1">
      <div style="display:grid;grid-template-columns:repeat(4,minmax(0,1fr));
           gap:11px;align-items:start">
        {''.join(cards)}
      </div>
      <div class="row" style="gap:9px;margin-top:13px">
        {mark_diamond("var(--dim)", 10)}
        <div style="font-size:13px;color:var(--dim);text-wrap:pretty">
          Nothing here makes a ship stronger. Everything trades against the same
          thirty, and five stats at eight would need forty, so no amount of
          buying ever makes the kit stop being a set of tradeoffs.
        </div>
      </div>
    </div>
  </div>
</div>"""
    page("Shop", body)


# =============================================================================
# 4. In match: a 4v4 on a three minute clock. The HUD is the one that ships
#    today plus a clock and a side score; the corner stack is unchanged.
# =============================================================================
def arena_svg(w=1280, h=720):
    rnd = random.Random(11)
    parts = []
    # Walls: near black at the core, lit at the rim, which is what gives a face
    # thickness. palette.lua WALL / WALL_EDGE / WALL_LIT.
    for _ in range(30):
        x, y = rnd.randint(40, w - 120), rnd.randint(60, h - 120)
        bw, bh = rnd.choice([(96, 32), (32, 108), (64, 64), (140, 30), (30, 150)])
        parts.append(
            f'<rect x="{x}" y="{y}" width="{bw}" height="{bh}" fill="#080d16" '
            f'stroke="#22344f" stroke-width="1"/>'
            f'<path d="M{x} {y} H{x + bw}" stroke="#5b82b8" stroke-width="1.4" '
            f'opacity=".55"/>')
    return "".join(parts)


def ship_at(name, x, y, rot, col, trail=True, k=1.0, hurt=False):
    path, _, _ = HULLS[name]
    t = ""
    if trail:
        # 0.6s of path, leaving from the hull's jets. render/trail.
        t = (f'<path d="M-4,10 L-2,52 L2,52 L4,10 Z" fill="{col}" '
             f'opacity=".16"/>')
    edge = "#ff505a" if hurt else col
    return (f'<g transform="translate({x},{y}) rotate({rot}) scale({k})">'
            f'{t}<path d="{path}" fill="#0b1220" stroke="{edge}" '
            f'stroke-width="1.5" stroke-linejoin="round"/></g>')


def match_screen(menu=""):
    ships = "".join([
        ship_at("Apex", 640, 372, 18, "#4fd6ff", k=1.25),
        ship_at("Facet", 470, 250, 118, "#4fd6ff"),
        ship_at("Lattice", 812, 512, -40, "#4fd6ff"),
        ship_at("Chord", 356, 545, 62, "#4fd6ff", hurt=True),
        ship_at("Cipher", 792, 232, 196, "#ffa552"),
        ship_at("Wedge", 545, 470, 244, "#ffa552"),
        ship_at("Anvil", 930, 388, 160, "#ffa552"),
        ship_at("Apex", 402, 336, 288, "#ffa552"),
    ])
    # Rounds wear the color of the rung they were fired at, one ramp for the
    # whole game. palette.lua RUNG.
    bolts = "".join([
        '<path d="M700 300 L716 288" stroke="#f7dd0b" stroke-width="2.6" '
        'stroke-linecap="round"/>',
        '<path d="M726 281 L740 271" stroke="#f7dd0b" stroke-width="2.6" '
        'stroke-linecap="round" opacity=".6"/>',
        '<path d="M600 420 L586 434" stroke="#62cc35" stroke-width="2.4" '
        'stroke-linecap="round"/>',
        '<circle cx="868" cy="452" r="4.4" fill="#ff7000"/>',
        '<circle cx="868" cy="452" r="11" stroke="#ff7000" stroke-width="1" '
        'opacity=".4"/>',
        '<circle cx="470" cy="600" r="3.6" fill="#f42e3d"/>',
    ])
    feed = [
        # Vesper was four kills into a run, so was worth five.
        ("QUARREL", "VESPER 412", "+5", "var(--friend)"),
        ("SABLE 09", "KESTREL", "+3", "var(--enemy)"),
        # A pilot who has just spawned is worth exactly one, which is what
        # makes camping one pay almost nothing.
        ("QUARREL", "ORRERY 3", "+1", "var(--friend)"),
    ]
    feed_html = "".join(
        f'<div class="row" style="gap:7px;height:19px">'
        f'<div class="t10 num" style="color:{c}">{a}</div>'
        f'<div class="t10 num dim" style="opacity:.6">&#215;</div>'
        f'<div class="t10 num dim">{b}</div><div style="flex:1"></div>'
        f'<div class="t10 num" style="color:var(--bounty)">{p}</div></div>'
        for a, b, p, c in feed)

    def side_rows(names, col, ks):
        out = []
        for (n, isbot), (k, d) in zip(names, ks):
            mark = bot(col, 11) if isbot else helm(col, 11)
            out.append(
                f'<div class="row" style="gap:8px;height:22px">{mark}'
                f'<div class="t11 num" style="color:{col}">{n}</div>'
                f'<div style="flex:1"></div>'
                f'<div class="t10 num dim">{k}</div>'
                f'<div class="t10 num dim" style="opacity:.5">{d}</div></div>')
        return "".join(out)

    body = f"""
<div class="screen">
  <svg width="1280" height="720" style="position:absolute;inset:0">
    {arena_svg()}{bolts}{ships}
  </svg>

  <!-- the clock and the two sides, dead center top: the two facts a three
       minute match is about -->
  <div style="position:absolute;top:14px;left:50%;transform:translateX(-50%);
       display:flex;align-items:center;gap:22px">
    <div class="row" style="gap:11px">
      <div class="t11 num" style="color:var(--friend)">BASTION</div>
      <div class="num" style="font-size:30px;color:var(--friend)">10</div>
    </div>
    <div style="text-align:center;padding:0 4px">
      <div class="num" style="font-size:34px;letter-spacing:.02em">1:47</div>
      <div class="lbl" style="text-align:center;margin-top:-2px">melee</div>
    </div>
    <div class="row" style="gap:11px">
      <div class="num" style="font-size:30px;color:var(--enemy)">7</div>
      <div class="t11 num" style="color:var(--enemy)">CAISSON</div>
    </div>
  </div>

  <!-- both sides, four a side: at this size a roster is a scoreboard -->
  <div class="panel" style="position:absolute;left:14px;top:56px;width:248px;
       padding:11px 12px">
    <div class="row" style="height:16px">
      <div class="lbl" style="color:var(--friend)">Bastion</div>
      <div style="flex:1"></div><div class="lbl">K</div>
      <div class="lbl" style="margin-left:9px;opacity:.5">D</div>
    </div>
    {side_rows([("QUARREL", False), ("KESTREL", True), ("PLINTH 41", True),
                ("MARLOW", False)], "var(--friend)",
               [(4, 1), (3, 2), (2, 2), (1, 2)])}
    <div class="ticks" style="margin:9px 0"></div>
    <div class="lbl" style="color:var(--enemy);height:16px">Caisson</div>
    {side_rows([("VESPER 412", True), ("SABLE 09", True), ("TALLOW", False),
                ("ORRERY 3", True)], "var(--enemy)",
               [(3, 3), (2, 2), (2, 3), (0, 2)])}
  </div>

  <!-- radar, then the feed under it: ui.lua puts them in that order -->
  <div style="position:absolute;right:14px;top:56px;width:196px">
    <div style="display:flex;justify-content:flex-end">{minimap(168, 7)}</div>
    <div class="panel" style="margin-top:12px;padding:9px 11px">
      {''.join(feed_html)}
    </div>
  </div>

  <!-- the corner stack, exactly as status() draws it: what a key would spend
       if you pressed it, and what you are worth -->
  <div style="position:absolute;left:20px;bottom:16px;display:flex;
       flex-direction:column;gap:5px">
    <div class="row" style="gap:14px;height:22px">
      <svg width="26" height="16" viewBox="0 0 26 16" fill="none">
        <path d="M4 8 H15" stroke="#f7dd0b" stroke-width="2.6"
          stroke-linecap="round"/>
        <path d="M4 3.4 H12" stroke="#f7dd0b" stroke-width="2" opacity=".7"
          stroke-linecap="round"/>
        <path d="M4 12.6 H12" stroke="#f7dd0b" stroke-width="2" opacity=".7"
          stroke-linecap="round"/>
      </svg>
    </div>
    <div class="row" style="gap:14px;height:22px">
      <svg width="26" height="16" viewBox="0 0 26 16" fill="none">
        <circle cx="9" cy="8" r="4.4" fill="#62cc35"/>
        <circle cx="9" cy="8" r="7.6" stroke="#62cc35" stroke-width="1"
          opacity=".45" stroke-dasharray="2 2"/>
      </svg>
    </div>
    <div class="row" style="gap:12px;height:22px">
      {mark_repel("var(--charge)", 15)}{pips(3, 2, "var(--charge)", gap=4.6)}
    </div>
    <div class="row" style="gap:12px;height:22px">
      {mark_burst("var(--charge)", 15)}{pips(2, 1, "var(--charge)", gap=4.6)}
    </div>
    <div class="row" style="gap:12px;height:22px">
      {mark_diamond("var(--prize)", 13)}
      <div class="num t13" style="color:var(--prize)">4</div>
    </div>
  </div>

  <!-- charges are spent for the match rather than for the life -->
  <div style="position:absolute;right:16px;bottom:16px;text-align:right">
    <div class="lbl" style="opacity:.55">2 repels and 1 burst left this match</div>
  </div>
  {menu}
</div>"""
    return body


def s_match():
    page("Match", match_screen())


# =============================================================================
# 4b. Settings, over a live match. Same surface as the front end, full screen
#     with the tab row on top, over a scrim rather than over a blank: the
#     world has not stopped and the screen should not pretend it has.
# =============================================================================
# Two axes, and exactly the five inputs menu.md commits to. Focus starts on
# the tab row; left and right move along it; down enters the page; up from the
# first row comes back; left and right on a focused row move its value;
# escape closes. A d-pad, a thumb and a keyboard all do this without a second
# layout.
MATCH_TABS = ["Settings", "Leave"]

AUDIO = [("Sound", ["off", "quiet", "half", "full"], 2, True),
         ("Music", ["off", "quiet", "half", "full"], 0, False)]
VIDEO = [("Frames", ["60", "120", "screen"], 0, False),
         ("Fullscreen", ["off", "on"], 1, False)]

# The real ids and defaults out of client/arena/controls.lua, less the two the
# design retires: the mine posture becomes a third charge, and attach goes
# with the turrets.
BINDS = [
    ("turn left", "&#8592;"), ("turn right", "&#8594;"),
    ("thrust", "&#8593;"), ("reverse", "&#8595;"),
    ("guns", "SPACE"), ("bombs", "TAB"),
    ("repel", "Q"), ("burst", "W"), ("mine", "E"),
    ("map", "M"), ("players", "P"), ("menu", "ESC"),
]


def opt_chips(items, sel, focused):
    out = []
    for i, it in enumerate(items):
        on = i == sel
        col = "var(--friend)" if on else "var(--dim)"
        ring = ("box-shadow:inset 0 0 0 1px rgba(79,214,255,.75)" if on
                else "box-shadow:inset 0 0 0 1px rgba(108,122,144,.28)")
        out.append(f'<div style="padding:5px 13px;font-family:var(--mono);'
                   f'font-size:10px;letter-spacing:.1em;text-transform:uppercase;'
                   f'color:{col};{ring};opacity:{1 if on or focused else .72}">'
                   f'{it}</div>')
    return '<div style="display:flex;gap:7px">' + "".join(out) + "</div>"


def setting_rows(rows, label_w=126):
    out = []
    for name, items, sel, focused in rows:
        cursor = ('<div style="color:var(--friend);font-size:13px;width:14px">'
                  '&#9654;</div>') if focused else '<div style="width:14px"></div>'
        out.append(f"""
        <div class="row {'wash' if focused else ''}" style="height:44px;
             padding:0 18px;gap:13px">
          {cursor}
          <div style="font-size:17px;min-width:{label_w}px;
               color:{'var(--ink)' if focused else 'var(--dim)'}">{name}</div>
          {opt_chips(items, sel, focused)}
        </div>""")
    return "".join(out)


def section(title):
    return (f'<div class="lbl" style="padding:0 18px;margin:14px 0 6px;'
            f'letter-spacing:.2em">{title}</div>')


def settings_page(in_match):
    binds = "".join(
        f'<div class="row" style="height:26px;padding:0 18px;gap:12px">'
        f'<div style="font-size:14px;color:var(--dim);min-width:112px">{n}</div>'
        f'<div class="t11 num" style="color:var(--ink)">{k}</div>'
        f'<div style="flex:1"></div>'
        f'<div class="lbl" style="opacity:.45">'
        f'{"fixed" if n == "menu" else "rebind"}</div></div>'
        for n, k in BINDS)

    footer = ("""
      <div class="row" style="gap:9px;margin-top:24px">
        %s
        <div style="font-size:13px;color:var(--dim);text-wrap:pretty;
             max-width:660px;line-height:1.5">
          The match is still running behind this and nothing here pauses it.
          Leaving hands your seat to a bot: you keep the rivets you have taken
          and give up the win.
        </div>
      </div>""" % mark_diamond("var(--dim)", 10)) if in_match else ""

    return f"""
    <div style="padding:30px 56px 0">
      <div class="row" style="gap:14px;margin-bottom:14px">
        <div style="font-size:23px">Settings</div>
        <div class="lbl" style="opacity:.6">saved as you set them</div>
      </div>
      <div class="row" style="align-items:flex-start;gap:26px">

        <div class="panel" style="flex:1;padding:6px 0 14px">
          {section("Audio")}{setting_rows(AUDIO)}
          {section("Video")}{setting_rows(VIDEO)}
          {section("About")}
          <div class="row" style="height:26px;padding:0 18px;gap:12px">
            <div style="font-size:14px;color:var(--dim);min-width:112px">build</div>
            <div class="t11 num">c429fcd</div>
          </div>
          <div class="row" style="height:26px;padding:0 18px;gap:12px">
            <div style="font-size:14px;color:var(--dim);min-width:112px">source</div>
            <div class="t11 num" style="color:var(--friend)">GITHUB</div>
          </div>
          <div class="row" style="height:26px;padding:0 18px;gap:12px">
            <div style="font-size:14px;color:var(--dim);min-width:112px">licence</div>
            <div class="t11 num" style="opacity:.75">POLYFORM</div>
          </div>
        </div>

        <div class="panel" style="width:452px;padding:6px 0 14px">
          {section("Controls")}
          {setting_rows([("Steering", ["stick", "d-pad"], 0, False)], 92)}
          <div class="ticks" style="margin:8px 18px 8px"></div>
          {binds}
        </div>
      </div>
      {footer}
      <div class="row" style="gap:24px;margin-top:{"22" if in_match else "30"}px">
        <div class="row" style="gap:9px">
          <div class="t11 num dim">&#8592; &#8594;</div>
          <div style="font-size:14px;color:var(--dim)">Tab, or set a value</div>
        </div>
        <div class="row" style="gap:9px">
          <div class="t11 num dim">&#8593; &#8595;</div>
          <div style="font-size:14px;color:var(--dim)">Row</div>
        </div>
        <div class="row" style="gap:9px">
          <div class="t11 num dim">ESC</div>
          <div style="font-size:14px;color:var(--dim)">
            {"Back to it" if in_match else "Back"}</div>
        </div>
      </div>
    </div>"""


def topbar_match():
    tabs = []
    for t in MATCH_TABS:
        on = t == "Settings"
        col = "var(--friend)" if on else "var(--dim)"
        rule = ('<div style="height:1.4px;background:var(--friend);'
                'margin-top:5px"></div>') if on else ""
        tabs.append(f'<div style="font-size:15px;color:{col}">{t}{rule}</div>')
    return f"""
  <div class="row" style="height:56px;padding:0 56px;gap:34px;
       background:rgba(5,7,12,.72)">
    {wordmark(.86)}
    <div style="display:flex;gap:21px;align-items:flex-start">{''.join(tabs)}</div>
    <div style="flex:1"></div>
    <div class="row" style="gap:13px">
      <div class="t11 num" style="color:var(--friend)">BASTION</div>
      <div class="num" style="font-size:19px;color:var(--friend)">2</div>
      <div class="num" style="font-size:19px">1:47</div>
      <div class="num" style="font-size:19px;color:var(--enemy)">1</div>
      <div class="t11 num" style="color:var(--enemy)">CAISSON</div>
    </div>
  </div>
  <div class="ticks" style="margin:0 56px"></div>"""


def s_menu():
    menu = f"""
  <!-- a scrim, not a curtain: the ships and the walls read straight through -->
  <div style="position:absolute;inset:0;background:rgba(5,7,12,.82)"></div>
  <div style="position:absolute;inset:0">
    {topbar_match()}
    {settings_page(True)}
  </div>"""
    page("InMatchMenu", match_screen(menu))


# =============================================================================
# 4c. Pilot: who you are, which is the one tab that is about you rather than
#     about a match. It is also where a bought name would land.
# =============================================================================
def s_pilot():
    body = f"""
<div class="screen">
  {topbar("Pilot")}
  <div class="row" style="align-items:flex-start;gap:26px;padding:30px 56px 0">

    <div class="panel" style="width:432px;padding:20px 22px 22px;position:relative">
      {bracket("rgba(79,214,255,.6)")}
      <div class="lbl">call sign</div>
      <div class="row" style="gap:13px;margin-top:11px">
        {helm("var(--friend)", 22)}
        <div style="font-size:30px">Quarrel</div>
        <div style="flex:1"></div>
        <div class="lbl" style="color:var(--friend);letter-spacing:.2em">ace</div>
      </div>
      <div style="font-size:13px;color:var(--dim);margin-top:12px;
           line-height:1.5;text-wrap:pretty">
        Dealt to you on arrival. Reroll for another from the pool, or buy a
        name of your own once you have flown enough to want one.
      </div>
      <div class="row" style="gap:12px;margin-top:16px">
        <div class="row" style="position:relative;padding:8px 16px;gap:9px">
          {bracket("rgba(108,122,144,.6)")}
          <div class="t11 num dim">R</div>
          <div style="font-size:14px;color:var(--dim)">Reroll</div>
        </div>
        <div class="row" style="position:relative;padding:8px 16px;gap:9px">
          {bracket("rgba(255,224,138,.6)")}
          {rivet("#ffe08a", 12)}
          <div class="num" style="font-size:14px;color:var(--bounty)">600</div>
          <div style="font-size:14px">Name your own</div>
        </div>
      </div>
      <div class="ticks" style="margin:20px 0 14px"></div>
      <div class="lbl">account</div>
      <div class="row" style="height:30px;margin-top:6px">
        <div style="font-size:14px;color:var(--dim)">Claimed</div>
        <div style="flex:1"></div>
        <div class="t11 num" style="color:var(--prize)">YES</div>
      </div>
      <div class="row" style="height:30px">
        <div style="font-size:14px;color:var(--dim)">Flying since</div>
        <div style="flex:1"></div>
        <div class="t11 num">MAR 2026</div>
      </div>
    </div>

    <div style="flex:1">
      <div class="panel" style="padding:18px 22px">
        <div class="lbl">career</div>
        <div class="row" style="gap:34px;margin-top:14px">
          <div>
            <div class="num" style="font-size:29px;color:var(--friend)">ACE</div>
            <div class="lbl" style="margin-top:3px">rating band</div>
          </div>
          <div>
            <div class="num" style="font-size:29px">412</div>
            <div class="lbl" style="margin-top:3px">matches</div>
          </div>
          <div>
            <div class="num" style="font-size:29px">1.24</div>
            <div class="lbl" style="margin-top:3px">kills a death</div>
          </div>
          <div>
            <div class="num" style="font-size:29px;color:var(--bounty)">11</div>
            <div class="lbl" style="margin-top:3px">longest run</div>
          </div>
        </div>
      </div>

      <div class="panel" style="margin-top:18px;padding:18px 22px">
        <div class="lbl">hulls flown</div>
        <div class="row" style="gap:8px;margin-top:14px;flex-wrap:wrap">
          {''.join(
            f'<div style="display:flex;flex-direction:column;align-items:center;'
            f'gap:6px;width:74px">'
            f'{hull(n, "var(--friend)" if n == "Apex" else "var(--dim)", .62, dim=n != "Apex", canopy=False)}'
            f'<div class="lbl" style="opacity:{1 if n == "Apex" else .6}">{n}</div>'
            f'<div class="t10 num" style="opacity:.6">{p}</div></div>'
            for n, p in [("Apex", "48%"), ("Cipher", "19%"), ("Facet", "12%"),
                         ("Wedge", "9%"), ("Chord", "6%"), ("Lattice", "4%"),
                         ("Anvil", "2%")])}
        </div>
      </div>

      <div class="panel" style="margin-top:18px;padding:18px 22px">
        <div class="lbl">wearing</div>
        <div class="row" style="gap:14px;margin-top:12px">
          {wake("hairline", 64)}
          <div style="font-size:15px">Hairline wake</div>
          <div style="flex:1"></div>
          <div class="lbl" style="opacity:.65">won in week 31</div>
        </div>
      </div>
    </div>
  </div>
</div>"""
    page("Pilot", body)


# =============================================================================
# 5. The podium: an ending, and a payday. Round points bank one for one.
# =============================================================================
def s_podium():
    # Kills, and the two sides sum to the 14 and 11 on the banner.
    won = [("QUARREL", False, 5, True), ("KESTREL", True, 4, False),
           ("PLINTH 41", True, 3, False), ("MARLOW", False, 2, False)]
    lost = [("VESPER 412", True, 4, False), ("SABLE 09", True, 3, False),
            ("TALLOW", False, 3, False), ("ORRERY 3", True, 1, False)]

    def col_rows(rows, col, mvp_label):
        out = []
        for n, isbot, pts, mvp in rows:
            mark = bot(col, 12) if isbot else helm(col, 12)
            tag = (f'<div class="lbl" style="color:var(--bounty)">{mvp_label}</div>'
                   if mvp else "")
            out.append(f"""
        <div class="row {'wash' if mvp else ''}" style="gap:9px;height:30px;
             padding:0 8px">
          {mark}<div class="t11 num" style="color:{col}">{n}</div>
          {tag}<div style="flex:1"></div>
          <div class="num" style="font-size:15px">{pts}</div>
        </div>""")
        return "".join(out)

    body = f"""
<div class="screen">
  <svg width="1280" height="720" style="position:absolute;inset:0;opacity:.28">
    {arena_svg()}
  </svg>
  <div style="position:absolute;inset:0;background:rgba(5,7,12,.72)"></div>

  <div style="position:absolute;inset:0;display:flex;flex-direction:column;
       align-items:center;padding-top:38px">

    <div class="lbl" style="letter-spacing:.3em">Drydock &#183; melee</div>
    <div class="row" style="gap:26px;margin-top:12px">
      <div class="num" style="font-size:44px;color:var(--friend)">14</div>
      <div style="font-size:27px;letter-spacing:.04em">Bastion takes it</div>
      <div class="num" style="font-size:44px;color:var(--enemy)">11</div>
    </div>

    <div class="row" style="align-items:flex-start;gap:20px;margin-top:26px">

      <div class="panel" style="width:326px;padding:13px 10px">
        <div class="row" style="padding:0 8px 8px">
          <div class="lbl" style="color:var(--friend)">Bastion</div>
          <div style="flex:1"></div><div class="lbl">kills</div>
        </div>
        {col_rows(won, "var(--friend)", "mvp")}
      </div>

      <div class="panel" style="width:326px;padding:13px 10px;opacity:.78">
        <div class="row" style="padding:0 8px 8px">
          <div class="lbl" style="color:var(--enemy)">Caisson</div>
          <div style="flex:1"></div><div class="lbl">kills</div>
        </div>
        {col_rows(lost, "var(--enemy)", "")}
      </div>

      <!-- the payday. Points are already the number that cannot be taken by
           death, so rivets are round points made spendable. -->
      <div class="panel" style="width:302px;padding:16px 18px;position:relative">
        {bracket("rgba(255,224,138,.55)")}
        <div class="lbl">Banked</div>
        <div class="row" style="gap:10px;margin-top:9px">
          {rivet("#ffe08a", 22)}
          <div class="num" style="font-size:36px;color:var(--bounty)">+19</div>
        </div>
        <div class="ticks" style="margin:14px 0 10px"></div>
        <div class="row" style="height:23px">
          <div class="t10 num dim">BOUNTY TAKEN &#183; 5 KILLS</div>
          <div style="flex:1"></div>
          <div class="t11 num">11</div></div>
        <div class="row" style="height:23px">
          <div class="t10 num dim">WON THE MATCH</div><div style="flex:1"></div>
          <div class="t11 num">+5</div></div>
        <div class="row" style="height:23px">
          <div class="t10 num dim">FIRST WIN TODAY</div><div style="flex:1"></div>
          <div class="t11 num">+3</div></div>
        <div class="ticks" style="margin:10px 0"></div>
        <div class="row" style="height:24px">
          <div class="t10 num dim">BALANCE</div><div style="flex:1"></div>
          <div class="row" style="gap:6px">{rivet("#dfe9f5", 12)}
            <div class="num t13">342</div></div></div>
        <div class="ticks" style="margin:12px 0 10px"></div>
        <div class="row" style="height:22px">
          <div class="t10 num dim">BEST RUN</div><div style="flex:1"></div>
          <div class="t11 num" style="color:var(--bounty)">5</div></div>
        <div class="row" style="height:22px">
          <div class="t10 num dim">WEEK 34</div><div style="flex:1"></div>
          <div class="row" style="gap:7px">
            <div class="t11 num dim" style="opacity:.55">12TH</div>
            <div class="t11 num" style="color:var(--dim)">&#9654;</div>
            <div class="t11 num" style="color:var(--friend)">9TH</div></div></div>
      </div>
    </div>

    <div class="row" style="gap:16px;margin-top:30px">
      <div class="row" style="position:relative;padding:10px 20px;gap:11px">
        {bracket("rgba(79,214,255,.85)")}
        <div class="t11 num" style="color:var(--friend)">ENTER</div>
        <div style="font-size:15px">Next match</div>
        <div class="num t11" style="color:var(--bounty)">0:23</div>
      </div>
      <div class="row" style="gap:10px;padding:10px 4px">
        <div class="t11 num dim">H</div>
        <div style="font-size:15px;color:var(--dim)">Change kit</div>
      </div>
      <div class="row" style="gap:10px;padding:10px 4px">
        <div class="t11 num dim">ESC</div>
        <div style="font-size:15px;color:var(--dim)">Leave</div>
      </div>
    </div>
  </div>
</div>"""
    page("Podium", body)


# =============================================================================
# 6. The week: the short ladder beside the career one, and what you wear.
# =============================================================================
WEEK = [
    (1, "TALLOW", False, 14, 9, 118, 11, "ember"),
    (2, "VESPER 412", True, 13, 11, 106, 9, "hairline"),
    (3, "SABLE 09", True, 12, 8, 97, 8, "plain"),
    (4, "MARLOW", False, 10, 7, 91, 7, "plain"),
    (5, "ORRERY 3", True, 9, 9, 84, 6, "plain"),
    (6, "PLINTH 41", True, 9, 6, 81, 7, "plain"),
    (7, "CORVID", False, 8, 5, 74, 5, "plain"),
    (8, "KESTREL", True, 8, 5, 71, 6, "plain"),
    (9, "QUARREL", False, 7, 6, 68, 5, "hairline"),
    (10, "LINTEL 22", True, 6, 4, 61, 4, "plain"),
]


def wake(kind, w=54):
    if kind == "ember":
        col, op = "#ff9a5c", ".9"
    elif kind == "hairline":
        col, op = "#dfe9f5", ".8"
    else:
        col, op = "#4fd6ff", ".45"
    return (f'<svg width="{w}" height="12" viewBox="0 0 54 12" fill="none">'
            f'<path d="M2,6 L44,3.4 L44,8.6 Z" fill="{col}" opacity="{op}"/>'
            f'<circle cx="47" cy="6" r="2.6" fill="{col}"/></svg>')


def s_standings():
    rows = []
    for rank, name, isbot, wins, pods, pts, streak, liv in WEEK:
        me = name == "QUARREL"
        col = "var(--friend)" if me else "var(--ink)"
        mark = bot("var(--dim)", 12) if isbot else helm("var(--dim)", 12)
        top = ('<div class="lbl" style="color:var(--bounty);width:30px">livery</div>'
               if rank <= 3 else '<div style="width:30px"></div>')
        rows.append(f"""
      <div class="row {'wash' if me else ''}" style="height:34px;padding:0 16px;
           gap:13px">
        <div class="num t11 dim" style="width:22px;text-align:right;
             {'color:var(--friend)' if me else ''}">{rank}</div>
        {mark}
        <div class="t11 num" style="color:{col};width:104px">{name}</div>
        <div style="width:58px">{wake(liv)}</div>
        {top}
        <div style="flex:1"></div>
        <div class="num t11" style="width:34px;text-align:right">{wins}</div>
        <div class="num t11 dim" style="width:44px;text-align:right">{pods}</div>
        <div class="num t11" style="width:52px;text-align:right">{pts}</div>
        <div class="num t11" style="width:38px;text-align:right;
             color:var(--bounty)">{streak}</div>
      </div>""")

    body = f"""
<div class="screen">
  {topbar("Standings")}
  <div class="row" style="align-items:flex-start;gap:26px;padding:24px 56px 0">

    <div style="flex:1">
      <div class="row" style="gap:14px;margin-bottom:12px">
        <div style="font-size:22px">Week 34</div>
        <div class="lbl">melee &#183; every map</div>
        <div style="flex:1"></div>
        <div class="lbl">resets in</div>
        <div class="num" style="font-size:15px;color:var(--bounty)">2d 14h</div>
      </div>
      <div class="panel" style="padding:12px 0 10px">
        <div class="row" style="height:20px;padding:0 16px;gap:13px">
          <div class="lbl" style="width:22px;text-align:right">#</div>
          <div style="width:12px"></div>
          <div class="lbl" style="width:104px">pilot</div>
          <div style="width:58px"></div><div style="width:30px"></div>
          <div style="flex:1"></div>
          <div class="lbl" style="width:34px;text-align:right">won</div>
          <div class="lbl" style="width:44px;text-align:right">podium</div>
          <div class="lbl" style="width:52px;text-align:right">kills</div>
          <div class="lbl" style="width:38px;text-align:right">run</div>
        </div>
        <div class="ticks" style="margin:6px 16px 4px"></div>
        {''.join(rows)}
      </div>
      <div class="row" style="gap:9px;margin-top:14px">
        {mark_diamond("var(--dim)", 10)}
        <div style="font-size:13px;color:var(--dim);text-wrap:pretty">
          Rating says how good you are and moves slowly. The week says what you
          did with it lately, and starts again on Monday.
        </div>
      </div>
    </div>

    <div style="width:340px">
      <div class="panel" style="padding:18px 20px 20px;position:relative">
        {bracket("rgba(79,214,255,.6)")}
        <div class="row" style="gap:11px">
          {helm("var(--friend)", 20)}
          <div>
            <div style="font-size:24px">Quarrel</div>
            <div class="lbl" style="margin-top:2px;color:var(--friend);
                 letter-spacing:.2em">ace</div>
          </div>
          <div style="flex:1"></div>
          <div style="text-align:right">
            <div class="num" style="font-size:27px;color:var(--friend)">9th</div>
            <div class="lbl">this week</div>
          </div>
        </div>
        <div class="ticks" style="margin:16px 0 12px"></div>
        <div class="row" style="height:25px">
          <div class="t10 num dim">MATCHES WON</div><div style="flex:1"></div>
          <div class="t11 num">7 of 19</div></div>
        <div class="row" style="height:25px">
          <div class="t10 num dim">PODIUMS</div><div style="flex:1"></div>
          <div class="t11 num">6</div></div>
        <div class="row" style="height:25px">
          <div class="t10 num dim">BEST RUN</div><div style="flex:1"></div>
          <div class="t11 num" style="color:var(--bounty)">5</div></div>
        <div class="row" style="height:25px">
          <div class="t10 num dim">BANKED</div><div style="flex:1"></div>
          <div class="row" style="gap:6px">{rivet("#dfe9f5", 12)}
            <div class="t11 num">342</div></div></div>
        <div class="ticks" style="margin:12px 0"></div>
        <div class="lbl" style="margin-bottom:9px">Wearing</div>
        <div class="row" style="gap:13px">
          {wake("hairline", 62)}
          <div style="font-size:14px">Hairline wake</div>
        </div>
        <div class="lbl" style="margin-top:9px;opacity:.7">
          top three of a closing week are paid in livery
        </div>
      </div>

      <div class="panel" style="margin-top:16px;padding:15px 20px">
        <div class="lbl">Career</div>
        <div class="row" style="gap:12px;margin-top:10px">
          <div class="lbl" style="width:74px">rating</div>
          <div class="row" style="gap:7px">
            <div class="t11 num" style="color:var(--friend)">ACE</div>
            <div class="t10 num dim" style="opacity:.6">1,246</div>
          </div>
        </div>
        <div class="row" style="gap:12px;margin-top:8px">
          <div class="lbl" style="width:74px">games</div>
          <div class="t11 num">412</div>
        </div>
      </div>
    </div>
  </div>
</div>"""
    page("Standings", body)


if __name__ == "__main__":
    s_matchlist(); s_main(); s_shop(); s_match(); s_menu(); s_pilot()
    s_podium(); s_standings()
    print("wrote 8 artboards")
