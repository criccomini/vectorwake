#!/usr/bin/env python3
"""Assemble the seven .dc.html artboards for the mobile pad rethink.

Chris's reading of the shipped touch controls, from a phone in a duel:

1. the pads look boxy and pixelated rather than like the game around them,
2. the gun pad's fan is smashed down until it stops reading as multifire,
3. the charges are small all-gold squares,
4. the stick is a bare wireframe circle,
5. nobody discovers that a double tap toggles reverse.

Three directions, each drawn resting and with the stick held in the
reversed stance, beside a board of what ships today:

  A  Instrument  the pads become cockpit gauges: arc rims, radial glow,
                 the volley drawn at full size, a rim tab for the fan,
                 hexagonal charge cells, a rose for the stick with a
                 tappable stance tab at its foot
  B  Cluster    the corner becomes one hand of round keys on a thumb
                 arc, no boxes anywhere, counts as rim segments, the fan
                 as a satellite moon on the gun's rim, the stick a ring
                 with a course needle and the reverse hint etched round it
  C  Glass      no chrome at all: the controls are the glowing marks
                 themselves, the volley is the multifire state, counts
                 are bare pips, the stick a faint reticle with a ghost
                 hint that fades once learned

Drawings of a proposal, not a plan of record. The design system is
lifted from the real client: client/arena/palette.lua for every hue,
client/arena/touch.lua for the shipped geometry the Today board
reproduces, client/arena/marks.lua for how a round, a bomb, a repel and
a burst are drawn, hull outlines to the extents in docs/design/ships.md.

Rebuild with: python3 build.py
"""

import math
import random
from pathlib import Path

HERE = Path(__file__).parent

W, H = 844, 390

# --- the palette, from client/arena/palette.lua ------------------------------

INK = "#dfe9f5"
DIM = "#6c7a90"
FRIEND = "#4fd6ff"
ENEMY = "#ffa552"
THRUST = "#ffbe78"
CHARGE = "#ffd166"
RUNG = ["#62cc35", "#f7dd0b", "#ff7000", "#f42e3d"]

GUN = RUNG[1]       # the shipped duel loadout: a rung 2 gun, a rung 3 bomb
BOMB = RUNG[2]

HOT = {             # pal.hot, blended toward white by hand
    GUN: "#fdf3a1",
    BOMB: "#ffcf9e",
    CHARGE: "#fff0c4",
    FRIEND: "#d9f6ff",
    THRUST: "#ffe9d2",
    ENEMY: "#ffd9b3",
}


def a(col, alpha):
    r, g, b = int(col[1:3], 16), int(col[3:5], 16), int(col[5:7], 16)
    return f"rgba({r},{g},{b},{alpha})"


CSS = """
:root{
  --bg:#05070c; --ink:#dfe9f5; --dim:#6c7a90;
  --mono:"DejaVu Sans Mono","Noto Sans Mono",ui-monospace,monospace;
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font-family:var(--mono)}
a{color:#4fd6ff}a:hover{color:#8ee6ff}
.hud{font-family:var(--mono);text-transform:uppercase;letter-spacing:.04em}
.key{display:inline-flex;align-items:center;justify-content:center;
  border:1px solid rgba(63,88,120,.75);background:rgba(10,15,24,.6);
  font-family:var(--mono);text-transform:uppercase;letter-spacing:.06em;
  color:#9fb6d4}
"""

# --- svg plumbing ------------------------------------------------------------


def defs():
    """Glow is the whole argument against 'pixelated': every neon stroke
    rides a soft pass of itself, the way the vec layers bloom in the game."""
    grads = []
    for name, col in (("gy", GUN), ("go", BOMB), ("gg", CHARGE),
                      ("gc", FRIEND), ("gt", THRUST)):
        grads.append(
            f'<radialGradient id="{name}">'
            f'<stop offset="0%" stop-color="{a(col, .16)}"/>'
            f'<stop offset="70%" stop-color="{a(col, .05)}"/>'
            f'<stop offset="100%" stop-color="{a(col, 0)}"/>'
            f'</radialGradient>')
    return (
        '<defs>'
        '<filter id="g" x="-150%" y="-150%" width="400%" height="400%">'
        '<feGaussianBlur stdDeviation="2" result="b"/>'
        '<feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/>'
        '</feMerge></filter>'
        '<filter id="b" x="-200%" y="-200%" width="500%" height="500%">'
        '<feGaussianBlur stdDeviation="5"/></filter>'
        + "".join(grads) + '</defs>')


def pt(cx, cy, r, ang):
    t = math.radians(ang)
    return cx + r * math.cos(t), cy + r * math.sin(t)


def arc(cx, cy, r, a0, a1, w, col, cap="round", glow=True):
    """Angles in css orientation: 0 east, 90 bottom, 270 top."""
    x0, y0 = pt(cx, cy, r, a0)
    x1, y1 = pt(cx, cy, r, a1)
    large = 1 if abs(a1 - a0) > 180 else 0
    sweep = 1 if a1 > a0 else 0
    g = ' filter="url(#g)"' if glow else ""
    return (f'<path d="M{x0:.1f} {y0:.1f} A{r} {r} 0 {large} {sweep} '
            f'{x1:.1f} {y1:.1f}" fill="none" stroke="{col}" '
            f'stroke-width="{w}" stroke-linecap="{cap}"{g}/>')


def ring(cx, cy, r, w, col, glow=True):
    g = ' filter="url(#g)"' if glow else ""
    return (f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{r:.1f}" fill="none" '
            f'stroke="{col}" stroke-width="{w}"{g}/>')


def disc(cx, cy, r, col, blur=False):
    f = ' filter="url(#b)"' if blur else ""
    return (f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{r:.1f}" '
            f'fill="{col}"{f}/>')


def seg(x0, y0, x1, y1, w, col, cap="round", glow=False):
    g = ' filter="url(#g)"' if glow else ""
    return (f'<line x1="{x0:.1f}" y1="{y0:.1f}" x2="{x1:.1f}" y2="{y1:.1f}" '
            f'stroke="{col}" stroke-width="{w}" stroke-linecap="{cap}"{g}/>')


def text(x, y, s, px, col, anchor="middle", spacing=".08em"):
    return (f'<text x="{x:.1f}" y="{y:.1f}" text-anchor="{anchor}" '
            f'font-family="DejaVu Sans Mono,Noto Sans Mono,monospace" '
            f'font-size="{px}" letter-spacing="{spacing}" '
            f'fill="{col}">{s}</text>')


# --- the marks, as client/arena/marks.lua draws them -------------------------


def streak(tx, ty, k, ang, col, hot, alpha=1.0):
    """One round in flight from a tail point, marks.bolt_line: a wide faint
    pass, a bright pass into the head, a hot core, then the lit head."""
    d = k * 1.4
    ca, sa = math.cos(math.radians(ang)), math.sin(math.radians(ang))
    hx, hy = tx + ca * d, ty + sa * d
    m1x, m1y = tx + ca * d * .3, ty + sa * d * .3
    m2x, m2y = tx + ca * d * .62, ty + sa * d * .62
    out = [
        seg(tx, ty, hx, hy, k * .20, a(col, .26 * alpha), glow=True),
        seg(m1x, m1y, hx, hy, k * .11, a(col, .9 * alpha)),
        seg(m2x, m2y, hx, hy, k * .06, a(hot, alpha)),
        disc(hx, hy, k * .26, a(col, .4 * alpha), blur=True),
        disc(hx, hy, k * .12, a(hot, alpha)),
    ]
    return "".join(out), (hx, hy)


def volley(cx, cy, k, spread, col, hot, declined=False, bounce=False):
    """The fan a pull actually throws, three rounds from one tail. Declined,
    the center round stays lit and the outer pair dims, marks.draw_volley."""
    tx, ty = cx - k * .7, cy
    out = []
    for off in (-spread, 0, spread):
        dimmed = declined and off != 0
        c, h = (DIM, DIM) if dimmed else (col, hot)
        s, head = streak(tx, ty, k, off, c, h,
                         alpha=.45 if dimmed else 1.0)
        out.append(s)
        if bounce and not dimmed:
            out.append(ring(head[0], head[1], k * .30, 1.2, a(col, .8),
                            glow=False))
    return "".join(out)


def bomb_mark(cx, cy, k, col, hot, prox=True):
    out = []
    if prox:
        out.append(disc(cx, cy, k * 1.0, a(col, .10)))
    out.append(disc(cx, cy, k * .75, a(col, .35), blur=True))
    out.append(ring(cx, cy, k * .46, k * .12, col))
    out.append(disc(cx, cy, k * .33, hot))
    return "".join(out)


def repel_glyph(cx, cy, k, col=CHARGE, alpha=1.0):
    hot = HOT[CHARGE]
    return "".join([
        disc(cx, cy, k * .5, a(col, .3 * alpha), blur=True),
        disc(cx, cy, k * .14, a(hot, alpha)),
        ring(cx, cy, k * .36, k * .11, a(col, alpha)),
        ring(cx, cy, k * .66, k * .09, a(col, .6 * alpha)),
    ])


def burst_glyph(cx, cy, k, col=CHARGE, alpha=1.0):
    hot = HOT[CHARGE]
    out = [disc(cx, cy, k * .45, a(col, .25 * alpha), blur=True)]
    for i in range(8):
        t = i * 45
        x0, y0 = pt(cx, cy, k * .22, t)
        x1, y1 = pt(cx, cy, k * .62, t)
        out.append(seg(x0, y0, x1, y1, k * .08, a(col, alpha)))
        out.append(disc(x1, y1, k * .10, a(hot, alpha)))
    return "".join(out)


def pips(cx, cy, n, cap, col, r=2.3, pitch=7):
    out = []
    x0 = cx - (cap - 1) * pitch / 2
    for i in range(cap):
        x = x0 + i * pitch
        if i < n:
            out.append(disc(x, cy, r, col))
        else:
            out.append(ring(x, cy, r, 1.2, a(col, .35), glow=False))
    return "".join(out)


# --- the room behind the controls --------------------------------------------

HULLS = {
    "Apex":  "M0,-20 L6,-3 L10,7 L4,5 L2,11 L-2,11 L-4,5 L-10,7 L-6,-3 Z",
    "Anvil": "M-8,-15 L8,-15 L13,-5 L13,6 L8,11 L-8,11 L-13,6 L-13,-5 Z",
}


def ship(name, x, y, rot, col, k=1.0, nose_plume=False):
    """nose_plume is the reversed stance made visible on the hull itself:
    the retros burn out of the bow, arena/world.lua."""
    plume = ""
    if nose_plume:
        plume = (f'<path d="M-3,-20 L-1.5,-40 L1.5,-40 L3,-20 Z" '
                 f'fill="{THRUST}" opacity=".6"/>'
                 f'<path d="M-6,-16 L-9,-30 L-4,-28 Z" fill="{THRUST}" '
                 f'opacity=".35"/>'
                 f'<path d="M6,-16 L9,-30 L4,-28 Z" fill="{THRUST}" '
                 f'opacity=".35"/>')
    else:
        plume = (f'<path d="M-3,11 L-1.5,34 L1.5,34 L3,11 Z" '
                 f'fill="{col}" opacity=".18"/>')
    return (f'<g transform="translate({x},{y}) rotate({rot}) scale({k})">'
            f'{plume}<path d="{HULLS[name]}" fill="#0b1220" stroke="{col}" '
            f'stroke-width="1.5" stroke-linejoin="round" filter="url(#g)"/>'
            f'</g>')


def starfield(seed):
    rnd = random.Random(seed)
    out = [
        f"radial-gradient(560px 360px at {int(W * .68)}px {int(H * .25)}px,"
        "rgba(39,197,237,.05),transparent 70%)",
        f"radial-gradient(460px 320px at {int(W * .18)}px {int(H * .8)}px,"
        "rgba(255,157,34,.04),transparent 70%)",
    ]
    for n, col, r in ((36, "#2a3a58", 0.9), (22, "#4a6089", 1.0),
                      (9, "#93a9c8", 1.3)):
        for _ in range(n):
            x, y = rnd.randint(0, W), rnd.randint(0, H)
            out.append(f"radial-gradient(circle {r}px at {x}px {y}px,"
                       f"{col} 0 {r}px,transparent {r}px)")
    return ",".join(out)


def walls(seed):
    """The station cluster the screenshot fights beside, up the right edge
    and out of the corner the pads own."""
    rnd = random.Random(seed)
    out = []
    for _ in range(9):
        x = rnd.randint(560, 800)
        y = rnd.randint(-20, 150)
        bw, bh = rnd.choice([(64, 22), (22, 74), (44, 44), (96, 20)])
        out.append(
            f'<rect x="{x}" y="{y}" width="{bw}" height="{bh}" '
            f'fill="#080d16" stroke="#22344f" stroke-width="1"/>'
            f'<path d="M{x} {y} H{x + bw}" stroke="#5b82b8" '
            f'stroke-width="1.4" opacity=".5"/>')
    for _ in range(4):
        x = rnd.randint(180, 430)
        y = rnd.randint(-10, 60)
        bw, bh = rnd.choice([(52, 18), (18, 52)])
        out.append(
            f'<rect x="{x}" y="{y}" width="{bw}" height="{bh}" '
            f'fill="#080d16" stroke="#22344f" stroke-width="1"/>')
    return "".join(out)


def scene(reversing=False):
    """One duel, held constant on every board: you in the middle, the rival
    upper right among the walls, two of their rounds inbound."""
    me_x, me_y = 380, 196
    parts = [walls(11)]
    # their rounds, in the rival gun's rung color
    parts.append(streak(560, 150, 12, 160, RUNG[1], HOT[GUN])[0])
    parts.append(streak(600, 175, 12, 168, RUNG[1], HOT[GUN])[0])
    # the rival
    parts.append(ship("Anvil", 640, 118, 205, ENEMY))
    parts.append(text(658, 106, "MANTIS 7", 9, a(ENEMY, .9),
                      anchor="start"))
    # you: reversing, the nose stays on the rival while the retros carry
    # you away, which is the stance's whole argument
    rot = 62 if reversing else 40
    parts.append(ship("Apex", me_x, me_y, rot, FRIEND,
                      nose_plume=reversing))
    parts.append(seg(me_x - 14, me_y - 26, me_x + 14, me_y - 26, 2.4,
                     a(FRIEND, .85)))
    return "".join(parts)


def chrome():
    return (
        '<div class="key" style="position:absolute;left:14px;top:14px;'
        'height:22px;padding:0 9px;font-size:9px">MENU</div>'
        '<div class="hud" style="position:absolute;top:12px;left:50%;'
        'transform:translateX(-50%);font-size:10px;display:flex;gap:10px;'
        'align-items:baseline">'
        f'<span style="color:{FRIEND}">VESPER 412&nbsp;2</span>'
        '<span style="font-size:14px">1:47</span>'
        f'<span style="color:{ENEMY}">3&nbsp;MANTIS 7</span></div>')


def radar():
    rnd = random.Random(7)
    blips = []
    for _ in range(18):
        bx, by = rnd.randint(6, 90), rnd.randint(6, 90)
        bw, bh = rnd.choice([(6, 3), (3, 7), (5, 5)])
        blips.append(f'<rect x="{bx}" y="{by}" width="{bw}" height="{bh}" '
                     f'fill="#3f5878" opacity=".85"/>')
    blips.append(f'<circle cx="46" cy="52" r="2" fill="{FRIEND}"/>')
    blips.append(f'<circle cx="60" cy="40" r="2" fill="{ENEMY}"/>')
    corners = "".join(
        f'<path d="{d}" stroke="rgba(63,88,120,.8)" stroke-width="1" '
        'fill="none"/>' for d in (
            "M1 12 V1 H12", "M88 1 H99 V12", "M99 88 V99 H88",
            "M12 99 H1 V88"))
    return (f'<svg width="100" height="100" viewBox="0 0 100 100" '
            f'style="position:absolute;right:14px;top:14px;'
            f'background:rgba(6,10,16,.55)">{"".join(blips)}{corners}</svg>')


# --- direction Today: the shipped controls, faults and all -------------------


def controls_today():
    out = []
    # gun pad, touch.lua M.layout: r 43 at (784,330)
    gx, gy, gr = 784, 330, 43
    out.append(ring(gx, gy, gr, 2.6, a(GUN, .5), glow=False))
    out.append(disc(gx, gy, gr, a(GUN, .045)))
    # the whole loadout squeezed to the pad's worst case: the fan at its
    # true narrow angles, bounce rings crowding the heads, all of it small
    out.append(volley(gx, gy, 17, 7, GUN, HOT[GUN], bounce=True))
    # the multifire arrow, all nine pixels of it
    ay = gy - gr - 8
    out.append(seg(gx, ay + 6, gx, ay - 3, 1.8, a(GUN, .72), glow=False))
    out.append(seg(gx, ay - 3, gx - 4, ay + 1, 1.8, a(GUN, .72), glow=False))
    out.append(seg(gx, ay - 3, gx + 4, ay + 1, 1.8, a(GUN, .72), glow=False))
    # bomb pad
    bx, by, br = 691, 330, 35
    out.append(ring(bx, by, br, 2.6, a(BOMB, .5), glow=False))
    out.append(disc(bx, by, br, a(BOMB, .045)))
    out.append(bomb_mark(bx, by, 20, BOMB, HOT[BOMB]))
    # the charge squares
    for cx, glyph, n in ((784, repel_glyph, 2), (737.5, burst_glyph, 3)):
        cy, cw = 247, 35
        out.append(f'<rect x="{cx - cw/2}" y="{cy - cw/2}" width="{cw}" '
                   f'height="{cw}" fill="{a(CHARGE, .05)}" '
                   f'stroke="{a(CHARGE, .55)}" stroke-width="2.2"/>')
        out.append(glyph(cx, cy - 2.8, 14.7))
        x0 = cx - 6.65
        for i in range(3):
            x = x0 + i * 6.65
            if i < n:
                out.append(disc(x, cy + 11.6, 2.4, CHARGE))
            else:
                out.append(ring(x, cy + 11.6, 2.4, 1.4, a(CHARGE, .3),
                                glow=False))
    # the stick's resting mark: a ring and an eye, nothing else
    sx, sy, sr = 69, 313, 49.4
    out.append(ring(sx, sy, sr, 1.8, a(DIM, .28), glow=False))
    out.append(ring(sx, sy, sr * .3, 1.8, a(DIM, .35), glow=False))
    return "".join(out)


# --- direction A: Instrument -------------------------------------------------


def gauge_trigger(cx, cy, r, col, hot, grad, mark, tab=None):
    """A trigger as a cockpit gauge: radial glow ground, a hairline ring,
    a bright arc rim broken at the top, the mark at full size inside."""
    out = [
        disc(cx, cy, r - 2, f"url(#{grad})"),
        ring(cx, cy, r, 1.2, a(col, .3), glow=False),
        arc(cx, cy, r, 300, 600, 2.8, a(col, .85)),
    ]
    # rung ticks along the inside foot of the rim, where the add-on ladder
    # lives now, so the mark never has to carry it
    for t in (76, 90, 104):
        x0, y0 = pt(cx, cy, r - 4, t)
        x1, y1 = pt(cx, cy, r - 9, t)
        out.append(seg(x0, y0, x1, y1, 1.6, a(col, .5), glow=False))
    out.append(mark)
    if tab:
        out.append(tab)
    return "".join(out)


def fan_tab(cx, cy, r, col, hot, on=True):
    """The multifire key: a tab on the gun's rim wearing the fan at a size
    that reads. A tap toggles it; the upward pull still works."""
    alpha = .9 if on else .35
    out = [arc(cx, cy, r + 9, 256, 284, 8, a(col, .18 * (3 if on else 1)))]
    tx, ty = cx, cy - r - 24
    for off in (-26, 0, 26):
        x1, y1 = pt(tx, ty + 9, 13, -90 + off)
        out.append(seg(tx, ty + 9, x1, y1, 2.2, a(col, alpha), glow=True))
        out.append(disc(x1, y1, 1.8, a(hot, alpha)))
    return "".join(out)


def stance_tab(cx, cy, r, reversed_=False):
    """The reverse made visible: a tab at the stick's foot carrying the
    keyboard's own down arrow, plus the gesture written beside it. A tap
    on the tab flips the stance too, so the gesture is a shortcut rather
    than a secret."""
    col = THRUST if reversed_ else DIM
    alpha = .9 if reversed_ else .5
    out = [arc(cx, cy, r + 10, 74, 106, 9, a(col, .5 if reversed_ else .16))]
    gy = cy + r + 24
    d = 1 if reversed_ else -1
    out.append(seg(cx, gy - 5 * d, cx, gy + 5 * d, 1.8, a(col, alpha),
                   glow=False))
    out.append(seg(cx, gy + 5 * d, cx - 4, gy + 1 * d, 1.8, a(col, alpha),
                   glow=False))
    out.append(seg(cx, gy + 5 * d, cx + 4, gy + 1 * d, 1.8, a(col, alpha),
                   glow=False))
    out.append(text(cx + 14, gy + 4, "REV ×2", 7,
                    a(col, .8 if reversed_ else .45), anchor="start"))
    return "".join(out)


def hexagon(cx, cy, R):
    ps = [pt(cx, cy, R, t) for t in (0, 60, 120, 180, 240, 300)]
    return "M" + " L".join(f"{x:.1f} {y:.1f}" for x, y in ps) + " Z"


def gauge_charge(cx, cy, glyph, n):
    R = 23
    out = [
        f'<path d="{hexagon(cx, cy, R)}" fill="{a(CHARGE, .06)}" '
        f'stroke="{a(CHARGE, .8)}" stroke-width="1.8" '
        f'stroke-linejoin="round" filter="url(#g)"/>',
        glyph(cx, cy - 3, 13),
    ]
    x0 = cx - 8
    for i in range(3):
        x = x0 + i * 8
        col = a(CHARGE, 1) if i < n else a(CHARGE, .25)
        out.append(seg(x - 2.5, cy + 13, x + 2.5, cy + 13, 2.2, col,
                       glow=False))
    return "".join(out)


def gauge_stick(cx, cy, R, engaged=None, reversed_=False):
    """The rose: a ring with rim ticks, a nose chevron riding it, an inner
    ring, and the stance tab at its foot. Engaged, the live stick draws
    where the thumb is, exactly as touch.lua does."""
    col = THRUST if reversed_ else DIM
    live = THRUST if reversed_ else FRIEND
    out = [ring(cx, cy, R, 1.6, a(col, .5))]
    for i in range(8):
        t = i * 45
        long = i % 2 == 0
        x0, y0 = pt(cx, cy, R, t)
        x1, y1 = pt(cx, cy, R - (8 if long else 5), t)
        out.append(seg(x0, y0, x1, y1, 2 if long else 1.4,
                       a(col, .7 if long else .4), glow=False))
    # the nose chevron on the rim: where the bow is, which reversed is the
    # far side of the thumb
    nose = 90 if reversed_ else 270
    nx, ny = pt(cx, cy, R + 5, nose)
    lx, ly = pt(cx, cy, R - 3, nose - 8)
    rx, ry = pt(cx, cy, R - 3, nose + 8)
    out.append(f'<path d="M{nx:.1f} {ny:.1f} L{lx:.1f} {ly:.1f} '
               f'L{rx:.1f} {ry:.1f} Z" fill="{a(live, .85)}" '
               f'filter="url(#g)"/>')
    out.append(ring(cx, cy, R * .3, 1.4, a(col, .3), glow=False))
    if engaged:
        ex, ey = engaged
        out.append(ring(ex, ey, 17, 1.8, a(live, .9)))
        out.append(seg(cx, cy, ex, ey, 2, a(live, .9), glow=True))
        # the course, out the far side of the press, headed
        dx, dy = cx - ex, cy - ey
        m = math.hypot(dx, dy) or 1
        ux, uy = dx / m, dy / m
        tx, ty = cx + ux * R * .72, cy + uy * R * .72
        out.append(seg(cx, cy, tx, ty, 2, a(live, .4)))
        px, py = -uy, ux
        for s in (1, -1):
            out.append(seg(tx, ty, tx - ux * 10 + px * 6 * s,
                           ty - uy * 10 + py * 6 * s, 2, a(live, .55)))
    out.append(stance_tab(cx, cy, R, reversed_))
    return "".join(out)


def controls_gauge(reversed_=False):
    out = []
    gx, gy, gr = 772, 318, 50
    mark = volley(gx, gy + 2, 24, 16, GUN, HOT[GUN])
    out.append(gauge_trigger(gx, gy, gr, GUN, HOT[GUN], "gy", mark,
                             tab=fan_tab(gx, gy, gr, GUN, HOT[GUN])))
    bx, by, br = 664, 328, 40
    out.append(gauge_trigger(bx, by, br, BOMB, HOT[BOMB], "go",
                             bomb_mark(bx, by, 27, BOMB, HOT[BOMB])))
    out.append(gauge_charge(700, 240, repel_glyph, 2))
    out.append(gauge_charge(646, 252, burst_glyph, 3))
    if reversed_:
        out.append(gauge_stick(96, 290, 52, engaged=(128, 268),
                               reversed_=True))
    else:
        out.append(gauge_stick(76, 296, 52))
    return "".join(out)


# --- direction B: Cluster ----------------------------------------------------


def cluster_key(cx, cy, r, col, grad, mark, segs=None, fan=None):
    """One round key of the hand: glow ground, one bright ring, the mark.

    On a charge key the count ring is the boundary: no inner ring at all,
    just the rim split one segment per charge, lit while it is in hand and
    dimmed once spent, so the key keeps its edge down to the last one.

    On a gun carrying a fan the same rim language answers for multifire:
    the ring opens at the top and the separated segment is the fan's own
    light, bright while it fires and down to a glimmer when declined. The
    volley inside draws the same answer, and a chevron under the segment
    points the upward pull that toggles it."""
    out = [disc(cx, cy, r - 1, f"url(#{grad})")]
    if segs:
        n, cap = segs
        span = 360 / cap - 12
        for i in range(cap):
            t0 = -90 + i * (360 / cap) + 6
            alpha = .9 if i < n else .22
            out.append(arc(cx, cy, r, t0, t0 + span, 2.6, a(col, alpha)))
    elif fan is not None:
        out.append(arc(cx, cy, r, 297, 603, 2.2, a(col, .85)))
        out.append(arc(cx, cy, r, 251, 289, 2.6,
                       a(col, .95 if fan else .3)))
        hy = cy - r + 12
        ch = a(col, .6 if fan else .3)
        out.append(seg(cx - 5, hy + 4, cx, hy - 2, 1.6, ch, glow=False))
        out.append(seg(cx, hy - 2, cx + 5, hy + 4, 1.6, ch, glow=False))
    else:
        out.append(ring(cx, cy, r, 2.2, a(col, .85)))
    out.append(mark)
    return "".join(out)


def cluster_rail(gx, gy):
    """The faint thread the hand hangs on: the satellites all sit one
    orbit out from the gun, so the thread is that orbit drawn dashed."""
    x0, y0 = pt(gx, gy, 83, 152)
    x1, y1 = pt(gx, gy, 83, 274)
    return (f'<path d="M{x0:.1f} {y0:.1f} A83 83 0 0 1 {x1:.1f} {y1:.1f}" '
            f'fill="none" stroke="{a(DIM, .3)}" stroke-width="1.2" '
            f'stroke-dasharray="1 6" stroke-linecap="round"/>')


_lbl_n = [0]


def key_label(cx, cy, r, word, top=False):
    """A key's name, etched along its rim the way the stick wears the
    double tap hint: small mono, letterspaced, in the dim ink that never
    fights the key's own color. Under a trigger, over a satellite."""
    _lbl_n[0] += 1
    lid = f"lbl{_lbl_n[0]}"
    a0, a1 = (210, 330) if top else (150, 30)
    x0, y0 = pt(cx, cy, r, a0)
    x1, y1 = pt(cx, cy, r, a1)
    sweep = 1 if a1 > a0 else 0
    return (
        f'<defs><path id="{lid}" d="M{x0:.1f} {y0:.1f} A{r} {r} 0 0 '
        f'{sweep} {x1:.1f} {y1:.1f}"/></defs>'
        f'<text font-family="DejaVu Sans Mono,Noto Sans Mono,monospace" '
        f'font-size="7.5" letter-spacing=".14em" fill="{a(DIM, .55)}">'
        f'<textPath href="#{lid}" startOffset="50%" text-anchor="middle">'
        f'{word}</textPath></text>')


def cluster_stick(cx, cy, R, engaged=None, reversed_=False):
    """A ring with a course needle, and the gesture etched round the foot
    of the rim where a resting thumb reads it."""
    col = THRUST if reversed_ else DIM
    live = THRUST if reversed_ else FRIEND
    out = [ring(cx, cy, R, 2, a(col, .55)),
           disc(cx, cy, 2.6, a(col, .6))]
    # the needle names the course; reversed it swings to the far side of
    # the thumb, nose held on the fight
    if engaged:
        ex, ey = engaged
        out.append(ring(ex, ey, 16, 1.8, a(live, .9)))
        out.append(seg(cx, cy, ex, ey, 2, a(live, .9), glow=True))
        dx, dy = cx - ex, cy - ey
        m = math.hypot(dx, dy) or 1
        nx, ny = cx + dx / m * (R - 8), cy + dy / m * (R - 8)
        out.append(seg(cx, cy, nx, ny, 2.4, a(live, .5), glow=True))
        out.append(disc(nx, ny, 3, a(live, .8)))
    else:
        nx, ny = pt(cx, cy, R - 8, 270)
        out.append(seg(cx, cy, nx, ny, 2.6, a(FRIEND, .8), glow=True))
        out.append(disc(nx, ny, 3.2, a(FRIEND, .9)))
    # the hint, etched along the outside of the foot arc
    x0, y0 = pt(cx, cy, R + 12, 152)
    x1, y1 = pt(cx, cy, R + 12, 28)
    etched = a(THRUST, .8) if reversed_ else a(DIM, .5)
    label = "REVERSED · ×2 BACK" if reversed_ else "TAP ×2 · REVERSE"
    out.append(
        f'<defs><path id="hint" d="M{x0:.1f} {y0:.1f} A{R + 12} {R + 12} '
        f'0 0 0 {x1:.1f} {y1:.1f}"/></defs>'
        f'<text font-family="DejaVu Sans Mono,Noto Sans Mono,monospace" '
        f'font-size="7.5" letter-spacing=".14em" fill="{etched}">'
        f'<textPath href="#hint" startOffset="50%" text-anchor="middle">'
        f'{label}</textPath></text>')
    return "".join(out)


def controls_cluster(reversed_=False):
    gx, gy, gr = 772, 314, 42
    out = [cluster_rail(gx, gy)]
    out.append(cluster_key(gx, gy, gr, GUN, "gy",
                           volley(gx, gy + 4, 21, 13, GUN, HOT[GUN]),
                           fan=True))
    out.append(key_label(gx, gy, gr + 11, "GUNS"))
    # The bomb rides the same orbit as the charges, at their size: one big
    # key for the trigger a thumb lives on, satellites for everything it
    # visits. It keeps its ring whole; only the charges count in segments.
    bx, by, br = 692, 336, 22
    out.append(cluster_key(bx, by, br, BOMB, "go",
                           bomb_mark(bx, by, 15, BOMB, HOT[BOMB])))
    out.append(key_label(bx, by, br + 8, "BOMB", top=True))
    out.append(cluster_key(706, 262, 22, CHARGE, "gg",
                           repel_glyph(706, 262, 12), segs=(2, 3)))
    out.append(key_label(706, 262, 30, "REPEL", top=True))
    out.append(cluster_key(760, 232, 22, CHARGE, "gg",
                           burst_glyph(760, 232, 12), segs=(3, 3)))
    out.append(key_label(760, 232, 30, "BURST", top=True))
    if reversed_:
        out.append(cluster_stick(96, 300, 54, engaged=(130, 276),
                                 reversed_=True))
    else:
        out.append(cluster_stick(76, 306, 54))
    return "".join(out)


def controls_cluster_states():
    """The cluster's states at reading size, off to the side of the fight:
    the gun with the fan firing and declined, and a charge key counting
    down. At zero the key goes away entirely, as it does today."""
    out = []
    for x, declined, label in ((170, False, "MULTIFIRE ON"),
                               (390, True, "MULTIFIRE DECLINED")):
        gy, gr = 168, 63
        out.append(cluster_key(x, gy, gr, GUN, "gy",
                               volley(x, gy + 6, 30, 13, GUN, HOT[GUN],
                                      declined=declined),
                               fan=not declined))
        out.append(text(x, 262, label, 9, a(DIM, .8)))
    out.append(text(280, 284, "THE SEGMENT AND THE VOLLEY ARE THE STATE · "
                    "PULL UP TO TOGGLE", 8, a(DIM, .55)))
    for x, n, label in ((590, 3, "3 IN HAND"), (690, 2, "2 IN HAND"),
                        (790, 1, "1 IN HAND")):
        cy, cr = 168, 33
        out.append(cluster_key(x, cy, cr, CHARGE, "gg",
                               burst_glyph(x, cy, 18), segs=(n, 3)))
        out.append(text(x, 232, label, 9, a(DIM, .8)))
    out.append(text(690, 262, "THE COUNT RING IS THE BOUNDARY", 8,
                    a(DIM, .55)))
    return "".join(out)


def board_plain(content, seed=33):
    """A detail sheet: the same sky, none of the fight."""
    stars = starfield(seed)
    return (
        f'<div style="position:absolute;left:0;top:0;width:{W}px;'
        f'height:{H}px;overflow:hidden;background-color:var(--bg);'
        f'background-image:{stars}">'
        f'<svg width="{W}" height="{H}" viewBox="0 0 {W} {H}" '
        f'style="position:absolute;inset:0">{defs()}{content}</svg></div>')


# --- direction C: Glass ------------------------------------------------------


def glass_footprint(cx, cy, r, col):
    return disc(cx, cy, r, a(col, .04))


def controls_glass(reversed_=False):
    out = []
    # the gun is its volley and nothing else: multifire on is three rounds,
    # declined is one lit and two dim, so the state is the mark
    gx, gy = 770, 318
    out.append(glass_footprint(gx, gy, 52, GUN))
    out.append(volley(gx, gy, 27, 14, GUN, HOT[GUN]))
    bx, by = 668, 330
    out.append(glass_footprint(bx, by, 42, BOMB))
    out.append(bomb_mark(bx, by, 28, BOMB, HOT[BOMB]))
    # charges as bare glyphs over dot counts
    out.append(glass_footprint(704, 244, 26, CHARGE))
    out.append(repel_glyph(704, 242, 15))
    out.append(pips(704, 262, 2, 3, CHARGE))
    out.append(glass_footprint(650, 254, 26, CHARGE))
    out.append(burst_glyph(650, 252, 15))
    out.append(pips(650, 272, 3, 3, CHARGE))
    # the stick is a reticle: four arcs suggesting the circle, a center
    # point, and a ghost hint that fades once the gesture has been used
    if reversed_:
        cx, cy = 104, 296
        live = THRUST
        out.append(disc(130, 274, 24, a(THRUST, .25), blur=True))
        out.append(ring(130, 274, 18, 1.8, a(live, .9)))
        out.append(seg(cx, cy, 130, 274, 2, a(live, .9), glow=True))
        dx, dy = cx - 130, cy - 274
        m = math.hypot(dx, dy)
        tx, ty = cx + dx / m * 34, cy + dy / m * 34
        out.append(seg(cx, cy, tx, ty, 2, a(live, .45)))
        for s in (1, -1):
            px, py = -dy / m, dx / m
            out.append(seg(tx, ty, tx - dx / m * 9 + px * 5 * s,
                           ty - dy / m * 9 + py * 5 * s, 2, a(live, .6)))
        for t0 in (262, 352, 82, 172):
            out.append(arc(cx, cy, 48, t0, t0 + 16, 1.6, a(live, .6)))
        out.append(text(cx, cy + 72, "REVERSED", 7.5, a(THRUST, .7)))
    else:
        cx, cy = 76, 306
        out.append(disc(cx, cy, 2.5, a(DIM, .6)))
        for t0 in (262, 352, 82, 172):
            out.append(arc(cx, cy, 50, t0, t0 + 16, 1.6, a(DIM, .45)))
        out.append(text(cx, cy + 68, "×2 REVERSE", 7.5, a(DIM, .32)))
    return "".join(out)


# --- assembly ----------------------------------------------------------------


def board(controls, reversing=False, seed=28):
    stars = starfield(seed)
    return (
        f'<div style="position:absolute;left:0;top:0;width:{W}px;'
        f'height:{H}px;overflow:hidden;background-color:var(--bg);'
        f'background-image:{stars}">'
        f'<svg width="{W}" height="{H}" viewBox="0 0 {W} {H}" '
        f'style="position:absolute;inset:0">{defs()}'
        f'{scene(reversing=reversing)}{controls}</svg>'
        f'{chrome()}{radar()}</div>')


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
  <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Noto+Sans+Mono:wght@400;500;700&amp;display=swap">
  <style>{CSS}</style>
</helmet>
{body}
</x-dc>
</body>
</html>
"""
    (HERE / f"{name}.dc.html").write_text(doc)


def main():
    page("Today", board(controls_today()))
    page("Main", board(controls_gauge()))
    page("InstrumentRev", board(controls_gauge(reversed_=True),
                                reversing=True))
    page("Cluster", board(controls_cluster()))
    page("ClusterRev", board(controls_cluster(reversed_=True),
                             reversing=True))
    page("ClusterStates", board_plain(controls_cluster_states()))
    page("Glass", board(controls_glass()))
    page("GlassRev", board(controls_glass(reversed_=True),
                           reversing=True))
    print("eight artboards written")


if __name__ == "__main__":
    main()
