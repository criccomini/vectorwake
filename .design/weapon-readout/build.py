#!/usr/bin/env python3
# The weapon-readout boards: what the lower-left corner could be, drawn against
# what it is. Every hue is palette.lua's, every mark is marks.lua's geometry
# (BOLT_LEN 1.4, BOMB_R 0.46, MARK_REACH 1.05, the radial share-out), and the
# stack is ui.lua's status(): rows 22z tall, axis at 15z, counts at 32z, block
# anchored to the bottom-left safe corner. z is drawn at 2.0 here, the size a
# large monitor actually reaches (STACK caps at 1.5 over F.scale), so a board
# is an honest screenshot of the big case rather than a flattering blowup.
#
# One loadout on every board so the directions compare: gun at rung 2 wearing
# spray 2 and bounce, bomb at rung 1 wearing prox 2 and shrapnel 2, two of
# three repels, one of two bursts. Rebuild with python3 build.py; the .dc.html
# files and canvas.json beside it seed the design canvas.
import math
import pathlib

OUT = str(pathlib.Path(__file__).resolve().parent)

# ---- palette.lua -----------------------------------------------------------
BG = "#05070c"
INK = "#dfe9f5"
DIM = "#6c7a90"
TILE = "#3f5878"      # RADAR_TILE, the HUD's chrome hue
RADAR_BG = "#060a10"
GOLD = "#ffd166"      # CHARGE_COL
BURST = "#c27bff"
FRIEND = "#4fd6ff"
ENEMY = "#ffa552"
PANEL = "#9fb6d4"     # PANEL_INK
HURT = "#ff505a"
RUNG = ["#62cc35", "#f7dd0b", "#ff7000", "#f42e3d"]
STAR = ["#93a9c8", "#4a6089", "#2a3a58"]


def _rgb(h):
    return int(h[1:3], 16), int(h[3:5], 16), int(h[5:7], 16)


def rgba(h, a=1.0):
    r, g, b = _rgb(h)
    return f"rgba({r},{g},{b},{a:g})"


def hot(h, k=0.45):
    r, g, b = (round(c + (255 - c) * k) for c in _rgb(h))
    return f"#{r:02x}{g:02x}{b:02x}"


# ---- the stack's numbers, from ui.lua's status() at z = 2 ------------------
Z = 2.0
K = 9 * Z             # a trigger mark's k
KC = 7 * Z            # a charge glyph's k
ROW = 22 * Z
PAD = 14 * Z
FRAME_W, FRAME_H = 760, 560
X0 = PAD              # left edge of the block
MID = X0 + 15 * Z     # the axis every mark stands on
VAL = MID + 17 * Z    # where counting starts


def pen(k, ratio):
    return max(1.3, k * ratio)


def fmt(v):
    return f"{v:.2f}".rstrip("0").rstrip(".")


def line(x1, y1, x2, y2, w, col):
    return (f'<path d="M{fmt(x1)} {fmt(y1)} L{fmt(x2)} {fmt(y2)}" '
            f'stroke="{col}" stroke-width="{fmt(w)}" fill="none"/>')


def disc(x, y, r, col):
    return f'<circle cx="{fmt(x)}" cy="{fmt(y)}" r="{fmt(r)}" fill="{col}"/>'


def ring(x, y, r, w, col):
    return (f'<circle cx="{fmt(x)}" cy="{fmt(y)}" r="{fmt(r)}" fill="none" '
            f'stroke="{col}" stroke-width="{fmt(w)}"/>')


# ---- marks.lua, in SVG -----------------------------------------------------
# The bolt: a line with a dot on the end. Spray at rung 2+ is the fan, off the
# one muzzle at +-0.47 rad; bounce rings every dot. The round wears the rung's
# own hue, the add-ons wear it run hot.
def bolt(cx, cy, lvl, spray=0, bounce=0, dim=1.0, recoil=0.0, relit=None):
    k = K
    base = rgba(RUNG[lvl], 0.9 * dim)
    hotc = rgba(hot(RUNG[lvl]), 0.95 * dim)
    at = cx + 0.46 * k - recoil
    o = at - 1.4 * k
    el = []
    dots = []

    def barrel(ang):
        dx = o + math.cos(ang) * 1.4 * k
        dy = cy + math.sin(ang) * 1.4 * k
        el.append(line(o, cy, dx, dy, pen(k, 0.075), base))
        el.append(disc(dx, dy, 0.17 * k, base))
        dots.append((dx, dy))

    barrel(0)
    if spray == 1:
        ox, dy = o + 0.10 * k, cy - 0.16 * k
        dx = ox + 1.3 * k
        el.append(line(ox, dy, dx, dy, pen(k, 0.068), base))
        el.append(disc(dx, dy, 0.136 * k, base))
        dots.append((dx, dy))
    elif spray >= 2:
        barrel(-0.47)
        barrel(0.47)
    if bounce:
        for dx, dy in dots:
            el.append(ring(dx, dy, 0.33 * k, pen(k, 0.065), hotc))
    # A cooling gun for the Live fire board: the barrel relights from the tail
    # as the cooldown runs out, so the line is the gauge.
    if relit is not None:
        el.append(line(o, cy, o + 1.4 * k * relit, cy, pen(k, 0.09),
                       rgba(RUNG[lvl], 0.95)))
    return el


# The bomb: a ringed head on its fuse field, fragments thrown clear of it.
def bomb(cx, cy, lvl, prox=0, shrap=0, gun_lvl=0, dim=1.0):
    k = K
    base = rgba(RUNG[lvl], 0.9 * dim)
    frag = rgba(hot(RUNG[gun_lvl]), 0.95 * dim)
    el = []
    if prox:
        r = k * (1.05 + 0.05 * (min(prox, 3) - 1))
        el.append(disc(cx, cy, r, rgba(RUNG[lvl], 0.9 * 0.24 * dim)))
    el.append(ring(cx, cy, 0.46 * k, pen(k, 0.122), base))
    el.append(disc(cx, cy, 0.34 * k, base))
    if shrap:
        out = 0.46 * k
        step = 1.05 * k - out
        r0, r1 = out + 0.28 * step, out + step
        c = 2 ** shrap
        w = pen(k, min(0.100, 2 * math.pi * r1 * 0.42 / (c * k)))
        for i in range(c):
            a = (i + 0.5) * 2 * math.pi / c
            dx, dy = math.cos(a), math.sin(a)
            el.append(line(cx + dx * r0, cy + dy * r0,
                           cx + dx * r1, cy + dy * r1, w, frag))
    return el


def repel_glyph(cx, cy, a=0.85):
    return [ring(cx, cy, 0.34 * KC, pen(KC, 0.11), rgba(GOLD, a)),
            ring(cx, cy, 0.64 * KC, pen(KC, 0.095), rgba(GOLD, a))]


def burst_glyph(cx, cy, a=0.85):
    el = []
    for i in range(8):
        t = i * math.pi / 4
        el.append(disc(cx + math.cos(t) * 0.52 * KC,
                       cy + math.sin(t) * 0.52 * KC, 0.135 * KC,
                       rgba(BURST, a)))
    return el


# Today's count: loose dots, ui.lua's pips().
def pips(x, cy, n, filled):
    el = []
    for i in range(n):
        px = x + i * 9 * Z
        if i < filled:
            el.append(disc(px, cy, 2.7 * Z, rgba(GOLD, 1)))
        else:
            el.append(ring(px, cy, 2.7 * Z, 1.6, rgba(GOLD, 0.3)))
    return el


# The proposed count: magazine cells, chamfered the way the HUD chamfers a
# corner. A spent cell keeps its outline, so the row's width never changes.
def cells(x, cy, n, filled, halo=None):
    el = []
    w, h, gap, ch = 10, 15, 5, 2.5
    for i in range(n):
        px = x + i * (w + gap)
        y0, y1 = cy - h / 2, cy + h / 2
        d = (f"M{fmt(px + ch)} {fmt(y0)} L{fmt(px + w)} {fmt(y0)} "
             f"L{fmt(px + w)} {fmt(y1 - ch)} L{fmt(px + w - ch)} {fmt(y1)} "
             f"L{fmt(px)} {fmt(y1)} L{fmt(px)} {fmt(y0 + ch)} Z")
        if i < filled:
            hl = (f' filter="url(#cellglow)"' if halo == i else "")
            el.append(f'<path d="{d}" fill="{rgba(GOLD, 0.92)}"{hl}/>')
        else:
            el.append(f'<path d="{d}" fill="none" '
                      f'stroke="{rgba(GOLD, 0.32)}" stroke-width="1.4"/>')
    return el


# ---- the corner's surroundings, identical on every board -------------------
STARS = ",\n   ".join([
    "radial-gradient(circle 1.3px at 512px 96px,#93a9c8 0 1.3px,transparent 1.3px)",
    "radial-gradient(circle 1.3px at 138px 208px,#93a9c8 0 1.3px,transparent 1.3px)",
    "radial-gradient(circle 1px at 660px 300px,#4a6089 0 1px,transparent 1px)",
    "radial-gradient(circle 1px at 300px 90px,#4a6089 0 1px,transparent 1px)",
    "radial-gradient(circle 1px at 240px 420px,#4a6089 0 1px,transparent 1px)",
    "radial-gradient(circle 1px at 430px 500px,#4a6089 0 1px,transparent 1px)",
    "radial-gradient(circle .9px at 90px 60px,#2a3a58 0 .9px,transparent .9px)",
    "radial-gradient(circle .9px at 400px 330px,#2a3a58 0 .9px,transparent .9px)",
    "radial-gradient(circle .9px at 580px 180px,#2a3a58 0 .9px,transparent .9px)",
    "radial-gradient(circle .9px at 190px 320px,#2a3a58 0 .9px,transparent .9px)",
    "radial-gradient(circle .9px at 700px 520px,#2a3a58 0 .9px,transparent .9px)",
])


def context():
    el = []
    # Your hull, mid-fight, and the plume behind it.
    el.append(f'<g transform="translate(470,210) rotate(-35) scale(1.8)">'
              f'<path d="M-4,10 L-2,34 L2,34 L4,10 Z" fill="{FRIEND}" '
              f'opacity=".16"/>'
              f'<path d="M0,-13 L15,9 L7,12 L0,8 L-7,12 L-15,9 Z" '
              f'fill="#0b1220" stroke="{FRIEND}" stroke-width="1.5" '
              f'stroke-linejoin="round"/></g>')
    # Somebody shooting at you from the top right.
    el.append(f'<g transform="translate(668,96) rotate(140) scale(1.4)">'
              f'<path d="M0,-22 L3,-6 L6,8 L2,12 L-2,12 L-6,8 L-3,-6 Z" '
              f'fill="#0b1220" stroke="{ENEMY}" stroke-width="1.5" '
              f'stroke-linejoin="round"/></g>')
    for x, y in ((618, 152), (586, 188), (554, 224)):
        el.append(line(x + 10, y - 10, x, y, 1.6, rgba(RUNG[1], 0.35)))
        el.append(disc(x, y, 2.4, rgba(RUNG[1], 0.85)))
    # The radar in the opposite corner, for what the HUD's chrome sounds like:
    # chamferless corner brackets, tile hue, two dots.
    rx, ry_, side = 626, 426, 120
    el.append(f'<rect x="{rx}" y="{ry_}" width="{side}" height="{side}" '
              f'fill="{rgba(RADAR_BG, 0.85)}"/>')
    arm = 18
    for cx, cy, sx, sy in ((rx, ry_, 1, 1), (rx + side, ry_, -1, 1),
                           (rx, ry_ + side, 1, -1),
                           (rx + side, ry_ + side, -1, -1)):
        el.append(f'<path d="M{cx + sx * arm} {cy} L{cx} {cy} '
                  f'L{cx} {cy + sy * arm}" fill="none" '
                  f'stroke="{rgba(TILE, 0.8)}" stroke-width="1.4"/>')
    for tx, ty, tw, th in ((650, 470, 26, 6), (650, 476, 6, 22),
                           (700, 502, 30, 6), (688, 444, 6, 18)):
        el.append(f'<rect x="{tx}" y="{ty}" width="{tw}" height="{th}" '
                  f'fill="{rgba(TILE, 0.5)}"/>')
    el.append(disc(686, 486, 2.6, FRIEND))
    el.append(disc(712, 456, 2.2, ENEMY))
    return "".join(el)


# ---- the loadout every board draws -----------------------------------------
GUN = dict(lvl=2, spray=2, bounce=1)
BOMB = dict(lvl=1, prox=2, shrap=2, gun_lvl=2)
REPEL = (3, 2)   # max, held
BURSTN = (2, 1)

N_ROWS = 4


def row_centers(ybot=FRAME_H - PAD):
    top = ybot - N_ROWS * ROW
    return [top + (i + 0.5) * ROW for i in range(N_ROWS)], top


# ---- boards ----------------------------------------------------------------
STYLE = """
*{box-sizing:border-box}
body{margin:0;background:#05070c;color:#dfe9f5;
  font-family:"Chakra Petch","Segoe UI",system-ui,sans-serif}
a{color:#4fd6ff}a:hover{color:#8ee6ff}
.lbl{font-family:"DejaVu Sans Mono","Noto Sans Mono",ui-monospace,monospace;
  font-size:9px;text-transform:uppercase;letter-spacing:.13em;color:#6c7a90}
"""

HEAD = """<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
  <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Chakra+Petch:wght@400;500;600&amp;family=Noto+Sans+Mono:wght@400;500;700&amp;display=swap">
  <style>{style}</style>
</helmet>
"""
FOOT = "</x-dc>\n\n</body>\n</html>\n"

DEFS = f"""<defs>
<linearGradient id="railfade" x1="0" y1="1" x2="0" y2="0">
  <stop offset="0" stop-color="{rgba(TILE, 0.75)}"/>
  <stop offset="1" stop-color="{rgba(TILE, 0)}"/>
</linearGradient>
<filter id="cellglow" x="-80%" y="-80%" width="260%" height="260%">
  <feGaussianBlur stdDeviation="2.2" result="b"/>
  <feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge>
</filter>
<filter id="soft" x="-120%" y="-120%" width="340%" height="340%">
  <feGaussianBlur stdDeviation="1.6"/>
</filter>
<filter id="softer" x="-160%" y="-160%" width="420%" height="420%">
  <feGaussianBlur stdDeviation="3.4"/>
</filter>
</defs>"""


def board(name, corner_svg, extra_html=""):
    body = (f'<div style="position:relative;width:{FRAME_W}px;'
            f'height:{FRAME_H}px;overflow:hidden;background-color:{BG};'
            f'background-image:\n   {STARS}">\n'
            f'<svg width="{FRAME_W}" height="{FRAME_H}" '
            f'style="position:absolute;inset:0">{DEFS}{context()}'
            f'{corner_svg}</svg>\n{extra_html}</div>\n')
    pathlib.Path(OUT, name).write_text(HEAD.format(style=STYLE) + body + FOOT)


# --- As shipped: marks and loose dots, nothing under them -------------------
def b_current():
    cys, _ = row_centers()
    el = []
    el += bolt(MID, cys[0], **GUN)
    el += bomb(MID, cys[1], **BOMB)
    el += repel_glyph(MID, cys[2])
    el += pips(VAL + 3 * Z, cys[2], REPEL[0], REPEL[1])
    el += burst_glyph(MID, cys[3])
    el += pips(VAL + 3 * Z, cys[3], BURSTN[0], BURSTN[1])
    board("Current.dc.html", "".join(el))


# --- A: the rail. One spine out of the corner, everything leaves from it ----
def b_rail(name="Main.dc.html"):
    cys, top = row_centers()
    sx = 30
    el = []
    # The spine: up out of a chamfered foot, fading past the top row.
    foot_y = FRAME_H - PAD + 8
    el.append(f'<path d="M{sx + 56} {fmt(foot_y)} L{sx + 6} {fmt(foot_y)} '
              f'L{sx} {fmt(foot_y - 6)} L{sx} {fmt(top - 4)}" fill="none" '
              f'stroke="{rgba(TILE, 0.75)}" stroke-width="1.6"/>')
    el.append(f'<rect x="{sx - 0.8}" y="{fmt(top - 40)}" width="1.6" '
              f'height="36" fill="url(#railfade)"/>')
    # A nub per row: the mark visibly leaves the rail.
    reach = {0: MID + 0.46 * K - 1.4 * K, 1: MID - 1.10 * K,
             2: MID - 0.64 * KC, 3: MID - 0.52 * KC - 0.135 * KC}
    for i, cy in enumerate(cys):
        el.append(line(sx, cy, reach[i] - 2, cy, 1.6, rgba(TILE, 0.9)))
    # And a tick at each row seam.
    for i in range(N_ROWS + 1):
        y = top + i * ROW
        el.append(line(sx, y, sx + 5, y, 1.2, rgba(TILE, 0.35)))
    el += bolt(MID, cys[0], **GUN)
    el += bomb(MID, cys[1], **BOMB)
    el += repel_glyph(MID, cys[2])
    el += cells(VAL + 3 * Z, cys[2], REPEL[0], REPEL[1])
    el += burst_glyph(MID, cys[3])
    el += cells(VAL + 3 * Z, cys[3], BURSTN[0], BURSTN[1])
    board(name, "".join(el))


# --- B: bays. A chamfered lip per row, the bracket chrome the HUD speaks ---
def b_bays():
    cys, top = row_centers()
    lx = 22
    el = []
    for cy in cys:
        y0, y1 = cy - 16, cy + 16
        el.append(f'<path d="M{lx + 12} {fmt(y0)} L{lx + 5} {fmt(y0)} '
                  f'L{lx} {fmt(y0 + 5)} L{lx} {fmt(y1 - 5)} '
                  f'L{lx + 5} {fmt(y1)} L{lx + 12} {fmt(y1)}" fill="none" '
                  f'stroke="{rgba(TILE, 0.8)}" stroke-width="1.4"/>')
    el.append(line(lx, FRAME_H - PAD + 8, lx + 150, FRAME_H - PAD + 8,
                   1.2, rgba(TILE, 0.35)))
    el += bolt(MID + 6, cys[0], **GUN)
    el += bomb(MID + 6, cys[1], **BOMB)
    el += repel_glyph(MID + 6, cys[2])
    el += cells(VAL + 6 + 3 * Z, cys[2], REPEL[0], REPEL[1])
    el += burst_glyph(MID + 6, cys[3])
    el += cells(VAL + 6 + 3 * Z, cys[3], BURSTN[0], BURSTN[1])
    board("Bays.dc.html", "".join(el))


# --- C: the hull plan. The readout is the machine that does it --------------
def b_hullplan():
    el = []
    hx, hy = 120, 398
    el.append(f'<g transform="translate({hx},{hy}) scale(6)">'
              f'<path d="M0,-13 L15,9 L7,12 L0,8 L-7,12 L-15,9 Z" '
              f'fill="{rgba("#0b1220", 0.5)}" stroke="{rgba(PANEL, 0.38)}" '
              f'stroke-width="0.22" stroke-linejoin="round"/>'
              f'<path d="M0,-9 L0,7" stroke="{rgba(PANEL, 0.16)}" '
              f'stroke-width="0.18"/>'
              f'<path d="M-9,7.5 L-4,4 M9,7.5 L4,4" '
              f'stroke="{rgba(PANEL, 0.16)}" stroke-width="0.18"/></g>')

    def hardpoint(x, y, tx, ty):
        return [disc(x, y, 2.6, rgba(PANEL, 0.7)),
                line(x, y, tx, ty, 1.1, rgba(PANEL, 0.3))]

    # Gun on the nose, bomb in the keel, charges racked off the wing.
    el += hardpoint(hx, hy - 78, 208, 306)
    el += bolt(232, 306, **GUN)
    el += hardpoint(hx + 12, hy + 44, 208, 372)
    el += bomb(230, 372, **BOMB)
    el += hardpoint(hx + 90, hy + 56, 236, 448)
    el += repel_glyph(250, 448)
    el += cells(268, 448, REPEL[0], REPEL[1])
    el.append(line(236, 448, 236, 486, 1.1, rgba(PANEL, 0.3)))
    el += burst_glyph(250, 486)
    el += cells(268, 486, BURSTN[0], BURSTN[1])
    board("HullPlan.dc.html", "".join(el))


# --- D: the fire arc. A quarter instrument out of the corner itself ---------
def b_firearc():
    cx, cy = 6, 554
    r_in, r_out, r_st = 140, 230, 185
    el = []

    def pt(r, deg):
        a = math.radians(deg)
        return cx + r * math.cos(a), cy - r * math.sin(a)

    def arc(r, d0, d1, w, col):
        x0, y0 = pt(r, d0)
        x1, y1 = pt(r, d1)
        return (f'<path d="M{fmt(x0)} {fmt(y0)} A{r} {r} 0 0 0 '
                f'{fmt(x1)} {fmt(y1)}" fill="none" stroke="{col}" '
                f'stroke-width="{fmt(w)}"/>')

    el.append(arc(r_out, 82, 6, 1.6, rgba(TILE, 0.55)))
    el.append(arc(r_in, 82, 6, 1.6, rgba(TILE, 0.35)))
    for deg in range(10, 81, 10):
        x0, y0 = pt(r_out - 6, deg)
        x1, y1 = pt(r_out, deg)
        el.append(line(x0, y0, x1, y1, 1.2, rgba(TILE, 0.5)))
    stations = ((62, "gun"), (38, "bomb"), (20, "repel"), (8, "burst"))
    for deg, kind in stations:
        x0, y0 = pt(r_st - 26, deg)
        x1, y1 = pt(r_st + 26, deg)
        el.append(line(x0, y0, x1, y1, 1.1, rgba(TILE, 0.28)))
        sx, sy = pt(r_st, deg)
        if kind == "gun":
            el += bolt(sx, sy, **GUN)
        elif kind == "bomb":
            el += bomb(sx, sy, **BOMB)
        elif kind == "repel":
            el += repel_glyph(sx, sy)
            el += cells(sx + 18, sy, REPEL[0], REPEL[1])
        else:
            el += burst_glyph(sx, sy)
            el += cells(sx + 18, sy, BURSTN[0], BURSTN[1])
    board("FireArc.dc.html", "".join(el))


# --- E: live fire. Same geometry as shipped; the corner answers "now?" ------
def b_livefire():
    cys, _ = row_centers()
    el = []
    # The gun, cooling: fired a beat ago, the barrel relights from the tail
    # as the cooldown runs out.
    el += bolt(MID, cys[0], lvl=GUN["lvl"], spray=GUN["spray"],
               bounce=GUN["bounce"], dim=0.30, relit=0.62)
    # The bomb, ready, breathing: a faint halo on the ON AIR clock.
    el.append(ring(MID, cys[1], 1.28 * K, 2.6, rgba(RUNG[BOMB["lvl"]], 0.10)))
    el += bomb(MID, cys[1], **BOMB)
    # The last repel, pulsing.
    el += repel_glyph(MID, cys[2])
    el += cells(VAL + 3 * Z, cys[2], 3, 1, halo=0)
    el += burst_glyph(MID, cys[3])
    el += cells(VAL + 3 * Z, cys[3], BURSTN[0], BURSTN[1])
    # The phase strip: one row's life, drawn out flat.
    strip = ['<div style="position:absolute;left:140px;top:24px;'
             'display:flex;gap:26px">']
    for cap, mode in (("ready, breathing", "ready"),
                      ("fired: recoil, flash", "fire"),
                      ("cooling: line refills", "cool")):
        cell = ['<div style="display:flex;flex-direction:column;gap:7px">',
                f'<svg width="150" height="52" style="outline:1px solid '
                f'{rgba(TILE, 0.3)}">']
        if mode == "ready":
            cell.append(ring(67 + 0.46 * K * 0.2, 26, 1.5 * K, 2,
                             rgba(RUNG[2], 0.08)))
            cell += bolt(67, 26, 2, spray=2, bounce=1)
        elif mode == "fire":
            cell += bolt(67, 26, 2, spray=2, bounce=1, recoil=3)
            fx = 67 + 0.46 * K - 3
            for ang in (0, 90, 45, 135):
                a = math.radians(ang)
                cell.append(line(fx - math.cos(a) * 8, 26 - math.sin(a) * 8,
                                 fx + math.cos(a) * 8, 26 + math.sin(a) * 8,
                                 1.3, rgba(hot(RUNG[2], 0.7), 0.9)))
        else:
            cell += bolt(67, 26, 2, spray=2, bounce=1, dim=0.30, relit=0.62)
        cell.append('</svg>')
        cell.append(f'<span class="lbl">{cap}</span></div>')
        strip += cell
    strip.append('</div>')
    board("LiveFire.dc.html", "".join(el), "".join(strip))


# --- The rail on a fresh spawn: two plain rows, most of the corner's life ---
def b_rail_bare():
    w, h = 400, 300
    rows = 2
    ybot = h - PAD
    top = ybot - rows * ROW
    cys = [top + (i + 0.5) * ROW for i in range(rows)]
    sx = 30
    el = []
    foot_y = h - PAD + 8
    el.append(f'<path d="M{sx + 56} {fmt(foot_y)} L{sx + 6} {fmt(foot_y)} '
              f'L{sx} {fmt(foot_y - 6)} L{sx} {fmt(top - 4)}" fill="none" '
              f'stroke="{rgba(TILE, 0.75)}" stroke-width="1.6"/>')
    el.append(f'<rect x="{sx - 0.8}" y="{fmt(top - 40)}" width="1.6" '
              f'height="36" fill="url(#railfade)"/>')
    el.append(line(sx, cys[0], MID + 0.46 * K - 1.4 * K - 2, cys[0],
                   1.6, rgba(TILE, 0.9)))
    el.append(line(sx, cys[1], MID - 0.46 * K - 2, cys[1],
                   1.6, rgba(TILE, 0.9)))
    for i in range(rows + 1):
        y = top + i * ROW
        el.append(line(sx, y, sx + 5, y, 1.2, rgba(TILE, 0.35)))
    el += bolt(MID, cys[0], 0)
    el += bomb(MID, cys[1], 0)
    body = (f'<div style="position:relative;width:{w}px;height:{h}px;'
            f'overflow:hidden;background-color:{BG};background-image:\n   '
            'radial-gradient(circle 1.3px at 300px 60px,#93a9c8 0 1.3px,'
            'transparent 1.3px),\n   '
            'radial-gradient(circle 1px at 120px 150px,#4a6089 0 1px,'
            'transparent 1px),\n   '
            'radial-gradient(circle .9px at 330px 220px,#2a3a58 0 .9px,'
            'transparent .9px)">\n'
            f'<svg width="{w}" height="{h}" '
            f'style="position:absolute;inset:0">{DEFS}{"".join(el)}'
            f'</svg>\n</div>\n')
    pathlib.Path(OUT, "RailBare.dc.html").write_text(
        HEAD.format(style=STYLE) + body + FOOT)


# ===========================================================================
# Round two: the marks themselves. Chris: the icons should look cooler, and
# the counts should be the ship page's circle grammar. So every board below
# counts charges with pages.dot's three fills (solid held, ringed spent) and
# proposes a vocabulary for the four drawings: gun, bomb, repel, burst.
# ===========================================================================

_uid = [0]


def uid(stem):
    _uid[0] += 1
    return f"{stem}{_uid[0]}"


# The ship page's circle, pages.dot at this scale: solid is a charge you
# hold, a ring is the slot a spent one leaves. 14 sides in game; a circle
# here.
def hdot(cx, cy, r, kind, col):
    if kind == "on":
        return disc(cx, cy, r, rgba(col, 0.95))
    return ring(cx, cy, r - 0.5, 1.1 * (r / 9), rgba(col, 0.45))


def hdots(x, cy, n, filled, r, step, col=GOLD):
    return [hdot(x + i * step, cy, r, "on" if i < filled else "ring", col)
            for i in range(n)]


# A streak that fades in along its length, the way seg_fade draws one:
# a gradient-stroked line, optionally blurred. Local coordinates; callers
# rotate the group it lands in.
def fade_line(x1, y1, x2, y2, w, a0, a1, col, blur=None):
    gid = uid("fade")
    f = f' filter="url(#{blur})"' if blur else ""
    return (f'<defs><linearGradient id="{gid}" '
            f'gradientUnits="userSpaceOnUse" x1="{fmt(x1)}" y1="{fmt(y1)}" '
            f'x2="{fmt(x2)}" y2="{fmt(y2)}">'
            f'<stop offset="0" stop-color="{rgba(col, a0)}"/>'
            f'<stop offset="1" stop-color="{rgba(col, a1)}"/>'
            f'</linearGradient></defs>'
            f'<path d="M{fmt(x1)} {fmt(y1)} L{fmt(x2)} {fmt(y2)}" '
            f'stroke="url(#{gid})" stroke-width="{fmt(w)}" '
            f'stroke-linecap="round" fill="none"{f}/>')


def arc_path(cx, cy, r, d0, d1, w, col, extra=""):
    a0, a1 = math.radians(d0), math.radians(d1)
    x0, y0 = cx + r * math.cos(a0), cy - r * math.sin(a0)
    x1, y1 = cx + r * math.cos(a1), cy - r * math.sin(a1)
    large = 1 if abs(d1 - d0) > 180 else 0
    sweep = 0 if d1 > d0 else 1
    return (f'<path d="M{fmt(x0)} {fmt(y0)} A{fmt(r)} {fmt(r)} 0 {large} '
            f'{sweep} {fmt(x1)} {fmt(y1)}" fill="none" stroke="{col}" '
            f'stroke-width="{fmt(w)}"{extra}/>')


# --- F, tracer: the mark is the round the arena fires, frozen ---------------
# The layering is world.weapons() verbatim: a broad faint streak, a tighter
# bright one over the last stretch, a hot core at the head, a halo. A bomb is
# its hot core in a ring with the halo and a stub of trail.
def tr_streak(k, hue):
    L = 1.6 * k
    return (fade_line(-L, 0, 0, 0, 0.25 * k, 0.0, 0.30, hue, "soft")
            + fade_line(-1.05 * k, 0, 0, 0, 0.15 * k, 0.2, 0.9, hue)
            + fade_line(-0.5 * k, 0, 0, 0, 0.10 * k, 0.4, 1.0, hot(hue, 0.9))
            + f'<circle cx="0" cy="0" r="{fmt(0.26 * k)}" '
            f'fill="{rgba(hue, 0.45)}" filter="url(#softer)"/>'
            + f'<circle cx="0" cy="0" r="{fmt(0.13 * k)}" '
            f'fill="{rgba(hot(hue, 0.9), 1)}"/>')


def tr_gun(cx, cy, k, loaded):
    hue = RUNG[GUN["lvl"]] if loaded else RUNG[0]
    hx = cx + 0.5 * k
    el = []
    angs = (0, -20, 20) if loaded else (0,)
    for a in angs:
        el.append(f'<g transform="translate({fmt(hx)},{fmt(cy)}) '
                  f'rotate({a},{fmt(-1.6 * k)},0)">{tr_streak(k, hue)}</g>')
    if loaded and GUN["bounce"]:
        for a in angs:
            r = math.radians(a)
            px = hx - 1.6 * k + math.cos(r) * 1.6 * k
            py = cy + math.sin(r) * 1.6 * k
            el.append(ring(px, py, 0.30 * k, pen(k, 0.045),
                           rgba(hot(hue), 0.8)))
    return el


def tr_bomb(cx, cy, k, loaded):
    hue = RUNG[BOMB["lvl"]] if loaded else RUNG[0]
    el = []
    if loaded and BOMB["prox"]:
        r = k * (1.05 + 0.05 * (BOMB["prox"] - 1))
        el.append(disc(cx, cy, r, rgba(hue, 0.16)))
    el.append(fade_line(cx - 1.35 * k, cy, cx - 0.40 * k, cy, 0.26 * k,
                        0.0, 0.45, hue, "soft"))
    el.append(f'<circle cx="{fmt(cx)}" cy="{fmt(cy)}" r="{fmt(0.62 * k)}" '
              f'fill="{rgba(hue, 0.32)}" filter="url(#softer)"/>')
    el.append(ring(cx, cy, 0.36 * k, pen(k, 0.11), rgba(hue, 0.95)))
    el.append(disc(cx, cy, 0.27 * k, rgba(hot(hue, 0.8), 0.9)))
    if loaded and BOMB["shrap"]:
        frag = rgba(hot(RUNG[BOMB["gun_lvl"]]), 0.95)
        c = 2 ** BOMB["shrap"]
        for i in range(c):
            a = (i + 0.5) * 2 * math.pi / c
            dx, dy = math.cos(a), math.sin(a)
            el.append(line(cx + dx * 0.66 * k, cy + dy * 0.66 * k,
                           cx + dx * 0.95 * k, cy + dy * 0.95 * k,
                           pen(k, 0.07), frag))
    return el


def tr_repel(cx, cy, kc):
    el = [f'<circle cx="{fmt(cx)}" cy="{fmt(cy)}" r="{fmt(0.5 * kc)}" '
          f'fill="{rgba(GOLD, 0.4)}" filter="url(#softer)"/>',
          disc(cx, cy, 0.14 * kc, rgba(hot(GOLD, 0.6), 0.95)),
          ring(cx, cy, 0.36 * kc, pen(kc, 0.11), rgba(GOLD, 0.9)),
          ring(cx, cy, 0.66 * kc, pen(kc, 0.09), rgba(GOLD, 0.6))]
    return el


def tr_burst(cx, cy, kc):
    el = [f'<circle cx="{fmt(cx)}" cy="{fmt(cy)}" r="{fmt(0.45 * kc)}" '
          f'fill="{rgba(BURST, 0.35)}" filter="url(#softer)"/>']
    for i in range(8):
        t = i * math.pi / 4
        dx, dy = math.cos(t), math.sin(t)
        el.append(fade_line(cx + dx * 0.22 * kc, cy + dy * 0.22 * kc,
                            cx + dx * 0.62 * kc, cy + dy * 0.62 * kc,
                            pen(kc, 0.09), 0.25, 0.95, BURST))
        el.append(disc(cx + dx * 0.62 * kc, cy + dy * 0.62 * kc,
                       0.10 * kc, rgba(hot(BURST, 0.5), 0.95)))
    return el


# --- G, ordnance: rounds built the way hulls are ----------------------------
# Thin outline over a darker fill, lit at the leading edge. The gun round is
# a finned dart, the bomb a cased shell with lugs.
def ord_dart(k, hue, scale=1.0):
    s = scale
    body = (f"M{fmt(0.62 * k * s)} 0 "
            f"L{fmt(0.02 * k * s)} {fmt(-0.17 * k * s)} "
            f"L{fmt(-0.45 * k * s)} {fmt(-0.11 * k * s)} "
            f"L{fmt(-0.32 * k * s)} 0 "
            f"L{fmt(-0.45 * k * s)} {fmt(0.11 * k * s)} "
            f"L{fmt(0.02 * k * s)} {fmt(0.17 * k * s)} Z")
    el = [f'<path d="{body}" fill="#0b1220" stroke="{rgba(hue, 0.9)}" '
          f'stroke-width="{fmt(pen(k, 0.055) * s)}" '
          f'stroke-linejoin="round"/>']
    for sgn in (-1, 1):
        el.append(line(-0.30 * k * s, sgn * 0.09 * k * s,
                       -0.70 * k * s, sgn * 0.27 * k * s,
                       pen(k, 0.05) * s, rgba(hue, 0.85)))
    el.append(line(0.04 * k * s, 0, 0.48 * k * s, 0, pen(k, 0.06) * s,
                   rgba(hot(hue, 0.75), 0.95)))
    return el


def ord_gun(cx, cy, k, loaded):
    hue = RUNG[GUN["lvl"]] if loaded else RUNG[0]
    el = []
    if loaded:
        for a in (-29, 29):
            el.append(f'<g transform="translate({fmt(cx)},{fmt(cy)}) '
                      f'rotate({a},{fmt(-0.55 * k)},0)">'
                      f'<g transform="scale(0.68) '
                      f'translate({fmt(-0.55 * k * 0.47)},0)">'
                      + "".join(ord_dart(k, hue)) + '</g></g>')
    el.append(f'<g transform="translate({fmt(cx)},{fmt(cy)})">'
              + "".join(ord_dart(k, hue)) + '</g>')
    if loaded and GUN["bounce"]:
        for a in (0, -29, 29):
            # Where each dart's nose landed: the side darts' noses sit at
            # 0.68 scale about the shared pivot behind the pack.
            if a == 0:
                nx, ny = cx + 0.62 * k, cy
            else:
                r = math.radians(a)
                lx = 0.68 * (0.62 - 0.55 * 0.47) * k
                v = lx + 0.55 * k
                nx = cx - 0.55 * k + math.cos(r) * v
                ny = cy + math.sin(r) * v
            el.append(ring(nx, ny, 0.18 * k, pen(k, 0.045),
                           rgba(hot(hue), 0.85)))
    return el


def ord_bomb(cx, cy, k, loaded):
    hue = RUNG[BOMB["lvl"]] if loaded else RUNG[0]
    el = []
    if loaded and BOMB["prox"]:
        r = k * (1.05 + 0.05 * (BOMB["prox"] - 1))
        el.append(disc(cx, cy, r, rgba(hue, 0.20)))
    el.append(f'<circle cx="{fmt(cx)}" cy="{fmt(cy)}" r="{fmt(0.48 * k)}" '
              f'fill="#0b1220" stroke="{rgba(hue, 0.9)}" '
              f'stroke-width="{fmt(pen(k, 0.075))}"/>')
    for i in range(4):
        a = math.pi / 4 + i * math.pi / 2
        dx, dy = math.cos(a), math.sin(a)
        el.append(line(cx + dx * 0.48 * k, cy + dy * 0.48 * k,
                       cx + dx * 0.64 * k, cy + dy * 0.64 * k,
                       pen(k, 0.075), rgba(hue, 0.9)))
    el.append(arc_path(cx, cy, 0.48 * k, 105, 195, pen(k, 0.09),
                       rgba(hot(hue, 0.75), 0.95)))
    el.append(disc(cx, cy, 0.20 * k, rgba(hot(hue, 0.75), 0.95)))
    if loaded and BOMB["shrap"]:
        frag = rgba(hot(RUNG[BOMB["gun_lvl"]]), 0.95)
        c = 2 ** BOMB["shrap"]
        for i in range(c):
            a = 2 * math.pi / 8 + (i + 0.5) * 2 * math.pi / c
            dx, dy = math.cos(a), math.sin(a)
            el.append(line(cx + dx * 0.78 * k, cy + dy * 0.78 * k,
                           cx + dx * 1.02 * k, cy + dy * 1.02 * k,
                           pen(k, 0.06), frag))
    return el


def ord_repel(cx, cy, kc):
    el = [disc(cx, cy, 0.13 * kc, rgba(GOLD, 0.95))]
    for sgn in (0, 180):
        for i, r in enumerate((0.40 * kc, 0.68 * kc)):
            el.append(arc_path(cx, cy, r, sgn - 52, sgn + 52,
                               pen(kc, 0.10 - 0.02 * i),
                               rgba(GOLD, 0.9 - 0.3 * i)))
    return el


def ord_burst(cx, cy, kc):
    el = [disc(cx, cy, 0.10 * kc, rgba(BURST, 0.9))]
    for i in range(8):
        deg = i * 45
        el.append(f'<g transform="translate({fmt(cx)},{fmt(cy)}) '
                  f'rotate({-deg}) translate({fmt(0.52 * kc)},0)">'
                  + "".join(ord_dart(kc, BURST, 0.42)) + '</g>')
    return el


# --- H, ordnance lit: the dart on its wake ----------------------------------
# G's bodies under F's light: the built round riding a short fading wake,
# a halo on the hot parts. What the arena does to everything else it cares
# about, a body with light coming off it.
def lit_gun(cx, cy, k, loaded):
    hue = RUNG[GUN["lvl"]] if loaded else RUNG[0]
    el = []
    angs = ((0, 1.0), (-24, 0.8), (24, 0.8)) if loaded else ((0, 1.0),)
    for a, s in angs:
        el.append(f'<g transform="translate({fmt(cx)},{fmt(cy)}) '
                  f'rotate({a},{fmt(-0.45 * k)},0)">'
                  + fade_line(-1.15 * k * s, 0, -0.42 * k * s, 0,
                              0.16 * k * s, 0.0, 0.55, hue, "soft")
                  + '</g>')
    el += ord_gun(cx, cy, k, loaded)
    el.append(f'<circle cx="{fmt(cx + 0.62 * k)}" cy="{fmt(cy)}" '
              f'r="{fmt(0.30 * k)}" fill="{rgba(hot(hue, 0.5), 0.5)}" '
              f'filter="url(#softer)"/>')
    return el


def lit_bomb(cx, cy, k, loaded):
    hue = RUNG[BOMB["lvl"]] if loaded else RUNG[0]
    el = [f'<circle cx="{fmt(cx)}" cy="{fmt(cy)}" r="{fmt(0.60 * k)}" '
          f'fill="{rgba(hue, 0.40)}" filter="url(#softer)"/>']
    el.append(fade_line(cx - 1.30 * k, cy, cx - 0.55 * k, cy, 0.20 * k,
                        0.0, 0.5, hue, "soft"))
    el += ord_bomb(cx, cy, k, loaded)
    return el


def lit_repel(cx, cy, kc):
    return [f'<circle cx="{fmt(cx)}" cy="{fmt(cy)}" r="{fmt(0.45 * kc)}" '
            f'fill="{rgba(GOLD, 0.35)}" filter="url(#softer)"/>'] \
        + ord_repel(cx, cy, kc)


def lit_burst(cx, cy, kc):
    return [f'<circle cx="{fmt(cx)}" cy="{fmt(cy)}" r="{fmt(0.45 * kc)}" '
            f'fill="{rgba(BURST, 0.32)}" filter="url(#softer)"/>'] \
        + ord_burst(cx, cy, kc)


VOCABS = {
    "tracer": dict(gun=tr_gun, bomb=tr_bomb, repel=tr_repel, burst=tr_burst),
    "ordnance": dict(gun=ord_gun, bomb=ord_bomb, repel=ord_repel,
                     burst=ord_burst),
    "lit": dict(gun=lit_gun, bomb=lit_bomb, repel=lit_repel, burst=lit_burst),
}


# --- the specimen sheet + the corner in situ, shared by every marks board ---
def marks_board(name, vocab):
    v = VOCABS[vocab]
    caps = ("gun", "gun, loaded", "bomb", "bomb, loaded", "repel", "burst")
    strip = ['<div style="position:absolute;left:24px;top:26px;'
             'display:flex;gap:8px">']
    k, kc = 30, 24
    for i, cap in enumerate(caps):
        cell = ['<div style="display:flex;flex-direction:column;gap:8px;'
                'align-items:center">',
                f'<svg width="112" height="104" '
                f'style="background:{BG}">{DEFS}']
        cx, cy = 56, 52
        if i == 0:
            cell += v["gun"](cx, cy, k, False)
        elif i == 1:
            cell += v["gun"](cx, cy, k, True)
        elif i == 2:
            cell += v["bomb"](cx, cy, k, False)
        elif i == 3:
            cell += v["bomb"](cx, cy, k, True)
        elif i == 4:
            cell += v["repel"](cx, cy, kc)
        else:
            cell += v["burst"](cx, cy, kc)
        cell.append(f'</svg><span class="lbl">{cap}</span></div>')
        strip += cell
    strip.append('</div>')
    # The corner, in situ: the shipped layout, the new marks, and the ship
    # page's circles counting the charges.
    cys, _ = row_centers()
    el = []
    el += v["gun"](MID, cys[0], K * 0.9, True)
    el += v["bomb"](MID, cys[1], K * 0.9, True)
    el += v["repel"](MID, cys[2], KC)
    el += hdots(VAL + 8, cys[2], REPEL[0], REPEL[1], 4.5 * Z * 0.9, 13 * Z)
    el += v["burst"](MID, cys[3], KC)
    el += hdots(VAL + 8, cys[3], BURSTN[0], BURSTN[1], 4.5 * Z * 0.9, 13 * Z)
    board(name, "".join(el), "".join(strip))


def b_marks_current():
    caps = ("gun", "gun, loaded", "bomb", "bomb, loaded", "repel", "burst")
    strip = ['<div style="position:absolute;left:24px;top:26px;'
             'display:flex;gap:8px">']
    k, kc = 30, 24
    for i, cap in enumerate(caps):
        cell = ['<div style="display:flex;flex-direction:column;gap:8px;'
                'align-items:center">',
                f'<svg width="112" height="104" '
                f'style="background:{BG}">{DEFS}']
        cx, cy = 56, 52
        if i == 0:
            cell += bolt(cx, cy, 0)
        elif i == 1:
            cell += [e for e in bolt(cx, cy, GUN["lvl"], GUN["spray"],
                                     GUN["bounce"])]
        elif i == 2:
            cell += bomb(cx, cy, 0)
        elif i == 3:
            cell += bomb(cx, cy, BOMB["lvl"], BOMB["prox"], BOMB["shrap"],
                         BOMB["gun_lvl"])
        elif i == 4:
            cell += repel_glyph(cx, cy)
        else:
            cell += burst_glyph(cx, cy)
        cell.append(f'</svg><span class="lbl">{cap}</span></div>')
        strip += cell
    strip.append('</div>')
    cys, _ = row_centers()
    el = []
    el += bolt(MID, cys[0], **GUN)
    el += bomb(MID, cys[1], **BOMB)
    el += repel_glyph(MID, cys[2])
    el += pips(VAL + 3 * Z, cys[2], REPEL[0], REPEL[1])
    el += burst_glyph(MID, cys[3])
    el += pips(VAL + 3 * Z, cys[3], BURSTN[0], BURSTN[1])
    board("MarksCurrent.dc.html", "".join(el), "".join(strip))


# The specimen cells draw marks at k 30 against 22-point rows in the game, so
# the boards say so: cells are inspection size, the corner strip is truth.

for f in (b_current, b_rail, b_bays, b_hullplan, b_firearc, b_livefire,
          b_rail_bare, b_marks_current):
    f()
for vv, fn in (("tracer", "Tracer.dc.html"), ("ordnance", "Ordnance.dc.html"),
               ("lit", "Lit.dc.html")):
    marks_board(fn, vv)
print("boards built")
