#!/usr/bin/env python3
# Who is in the seat, drawn six ways. The current pair (a front-view helmet
# with a wrapped visor, a boxed shell with lamps and an antenna) is ported
# from ui.lua's own math so the comparison is honest, and five alternatives
# each move on a different axis: profiles, badges, scope blips, busts, and
# signal traces. Every direction is shown at the three sizes the game
# actually draws these at: k=11 beside a count or a name, k=21 in the rail,
# and large only so the shapes can be judged.
#
# Chrome and hues are the client's: ink dfe9f5, dim 6c7a90, friend 4fd6ff,
# enemy ffa552, bg 05070c. Pen = max(0.9, k*0.11), same as marks.pen.
import math
import pathlib

OUT = str(pathlib.Path(__file__).resolve().parent)

INK, DIM, FRIEND, ENEMY, GOLD = ("#dfe9f5", "#6c7a90", "#4fd6ff",
                                 "#ffa552", "#ffd166")
BG = "#05070c"

STYLE = """
:root{--ink:#dfe9f5;--dim:#6c7a90;--friend:#4fd6ff;--enemy:#ffa552;
  --mono:"DejaVu Sans Mono","Noto Sans Mono",ui-monospace,monospace;
  --menu:"Chakra Petch","Segoe UI",system-ui,sans-serif}
*{box-sizing:border-box}
body{margin:0;background:#05070c;color:var(--ink);font-family:var(--menu)}
a{color:var(--friend)}a:hover{color:#8ee6ff}
.lbl{font-family:var(--mono);font-size:9px;text-transform:uppercase;
  letter-spacing:.13em;color:var(--dim)}
.note{font-family:var(--mono);font-size:10px;color:var(--dim);
  line-height:1.55}
.row{display:flex;align-items:center}
.col{display:flex;flex-direction:column}
.mono{font-family:var(--mono)}
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


def write(name, body):
    pathlib.Path(OUT, name).write_text(HEAD.format(style=STYLE) + body + FOOT)


def pen(k, ratio=0.11):
    return max(0.9, k * ratio)


def fmt(v):
    return f"{v:.2f}"


def poly(pts, col, line, closed=True, fill="none", cap="butt"):
    d = " ".join(f"{fmt(x)},{fmt(y)}" for x, y in pts)
    tag = "polygon" if closed else "polyline"
    return (f'<{tag} points="{d}" fill="{fill}" stroke="{col}" '
            f'stroke-width="{fmt(line)}" stroke-linecap="{cap}" '
            f'stroke-linejoin="round"/>')


def filled(pts, col):
    d = " ".join(f"{fmt(x)},{fmt(y)}" for x, y in pts)
    return f'<polygon points="{d}" fill="{col}" stroke="none"/>'


def seg(x1, y1, x2, y2, w, col, cap="square"):
    return (f'<line x1="{fmt(x1)}" y1="{fmt(y1)}" x2="{fmt(x2)}" '
            f'y2="{fmt(y2)}" stroke="{col}" stroke-width="{fmt(w)}" '
            f'stroke-linecap="{cap}"/>')


def disc(cx, cy, r, col):
    return (f'<circle cx="{fmt(cx)}" cy="{fmt(cy)}" r="{fmt(r)}" '
            f'fill="{col}"/>')


def ring(cx, cy, r, w, col):
    return (f'<circle cx="{fmt(cx)}" cy="{fmt(cy)}" r="{fmt(r)}" '
            f'fill="none" stroke="{col}" stroke-width="{fmt(w)}"/>')


def arc(cx, cy, r, a0, a1, w, col, n=24):
    pts = []
    for i in range(n + 1):
        a = a0 + (a1 - a0) * i / n
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return poly(pts, col, w, closed=False, cap="round")


# ---- As shipped, straight from ui.lua's geometry ----
HELM_NECK = 0.68
HELM_TALL = 0.5 * (1 + HELM_NECK)
FACE_WIDE, FACE_CROWN = 0.38, 0.38
FACE_ROUND, FACE_BLUNT, FACE_IN = 2.1, 2.3, 0.22


def cur_pilot(cx, cy, k, col, line=None):
    line = line or pen(k)
    w = k
    h = w * HELM_TALL
    y0 = cy - h / 2
    up, down = h * FACE_CROWN, h * (1 - FACE_CROWN)
    waist = y0 + up
    half = k * FACE_WIDE

    def hw(y):
        t = (y - waist) / (up if y < waist else down)
        t = max(-1.0, min(1.0, t))
        if t < 0:
            return half * (1 - (-t) ** FACE_ROUND) ** (1 / FACE_ROUND)
        return half * ((1 - t ** FACE_BLUNT) ** (1 / FACE_BLUNT)
                       * (1 - FACE_IN * t))

    steps = 24
    pts = []
    for i in range(steps + 1):
        y = y0 + h * i / steps
        pts.append((cx - hw(y), y))
    for i in range(steps, -1, -1):
        y = y0 + h * i / steps
        pts.append((cx + hw(y), y))
    out = [poly(pts, col, line)]
    top = waist - min(line * 1.5, h * 0.11)
    reach = hw(top) - line * 1.1
    sag = min(line * 2.6, h * 0.19)
    bend, floor = h * 0.080, cy + h / 2
    tops, bots = [], []
    for i in range(11):
        t = -1 + 2 * i / 10
        x = cx + reach * t
        tops.append((x, top + bend * (1 - t * t)))
        bots.append((x, min(waist + sag * (1 - t * t), floor - line)))
    out.append(filled(tops + bots[::-1], col))
    return "".join(out)


def cur_bot(cx, cy, k, col, line=None):
    line = line or pen(k)
    w = k
    h = w * HELM_TALL
    x0, y0 = cx - w / 2, cy - h / 2
    r = w * 0.5
    mid = y0 + r
    neck = mid + r * HELM_NECK
    out = [seg(x0, y0, x0 + w, y0, line, col),
           seg(x0, y0 + line / 2, x0, neck - line / 2, line, col, "butt"),
           seg(x0 + w, y0 + line / 2, x0 + w, neck - line / 2, line, col,
               "butt"),
           seg(cx - r * 1.26, neck, cx + r * 1.26, neck, line, col)]
    eye = mid - r * 0.16
    out.append(disc(x0 + w * 0.31, eye, w * 0.115, col))
    out.append(disc(x0 + w * 0.69, eye, w * 0.115, col))
    out.append(seg(cx, y0, cx, y0 - r * 0.36, pen(k, 0.09), col))
    out.append(disc(cx, y0 - r * 0.48, w * 0.11, col))
    return "".join(out)


# ---- A. Profiles: the same two heads, side on, facing the way ships fly ----
def prof_pilot(cx, cy, k, col, line=None):
    line = line or pen(k)

    def p(x, y):
        return (cx + x * k, cy + y * k)

    shell = (f'<path d="M {fmt(cx - 0.36 * k)} {fmt(cy + 0.32 * k)} '
             f'C {fmt(cx - 0.50 * k)} {fmt(cy + 0.10 * k)} '
             f'{fmt(cx - 0.44 * k)} {fmt(cy - 0.32 * k)} '
             f'{fmt(cx - 0.10 * k)} {fmt(cy - 0.42 * k)} '
             f'C {fmt(cx + 0.16 * k)} {fmt(cy - 0.50 * k)} '
             f'{fmt(cx + 0.38 * k)} {fmt(cy - 0.38 * k)} '
             f'{fmt(cx + 0.42 * k)} {fmt(cy - 0.20 * k)} '
             f'L {fmt(cx + 0.48 * k)} {fmt(cy + 0.14 * k)} '
             f'L {fmt(cx + 0.10 * k)} {fmt(cy + 0.32 * k)} Z" '
             f'fill="none" stroke="{col}" stroke-width="{fmt(line)}" '
             f'stroke-linejoin="round"/>')
    visor = filled([p(0.12, -0.28), p(0.34, -0.22), p(0.41, 0.12),
                    p(0.09, 0.26)], col)
    return shell + visor


def prof_bot(cx, cy, k, col, line=None):
    line = line or pen(k)

    def p(x, y):
        return (cx + x * k, cy + y * k)

    head = poly([p(-0.42, 0.30), p(-0.42, -0.34), p(0.24, -0.34),
                 p(0.46, -0.06), p(0.46, 0.30)], col, line)
    lens = filled([p(0.08, -0.12), p(0.40, -0.12), p(0.40, 0.02),
                   p(0.08, 0.02)], col)
    ant = (seg(*p(-0.26, -0.34), *p(-0.26, -0.52), pen(k, 0.09), col)
           + disc(*p(-0.26, -0.60), 0.07 * k, col))
    return head + lens + ant


# ---- B. Badges: what they wear, not what their head looks like ----
def wing_pilot(cx, cy, k, col, line=None):
    line = line or pen(k)

    def p(x, y):
        return (cx + x * k, cy + y * k)

    out = [filled([p(0, -0.13), p(0.10, 0.01), p(0, 0.15), p(-0.10, 0.01)],
                  col)]
    for s in (1, -1):
        out.append(seg(*p(s * 0.11, -0.06), *p(s * 0.54, -0.30),
                       line * 0.85, col, "round"))
        out.append(seg(*p(s * 0.11, 0.06), *p(s * 0.50, -0.10),
                       line * 0.85, col, "round"))
        out.append(seg(*p(s * 0.11, 0.18), *p(s * 0.42, 0.09),
                       line * 0.85, col, "round"))
    return "".join(out)


def chip_bot(cx, cy, k, col, line=None):
    line = line or pen(k)

    def p(x, y):
        return (cx + x * k, cy + y * k)

    s = 0.27
    out = [poly([p(-s, -s), p(s, -s), p(s, s), p(-s, s)], col, line)]
    out.append(filled([p(-0.09, -0.09), p(0.09, -0.09), p(0.09, 0.09),
                       p(-0.09, 0.09)], col))
    for off in (-0.135, 0.135):
        out.append(seg(*p(-s, off), *p(-s - 0.14, off), line, col, "butt"))
        out.append(seg(*p(s, off), *p(s + 0.14, off), line, col, "butt"))
        out.append(seg(*p(off, -s), *p(off, -s - 0.14), line, col, "butt"))
        out.append(seg(*p(off, s), *p(off, s + 0.14), line, col, "butt"))
    return "".join(out)


# ---- C. Blips: contacts on a scope, the radar's own vocabulary ----
def blip_pilot(cx, cy, k, col, line=None):
    line = line or pen(k)
    return (disc(cx, cy + 0.10 * k, 0.16 * k, col)
            + arc(cx, cy + 0.10 * k, 0.34 * k, math.radians(200),
                  math.radians(340), line, col))


def blip_bot(cx, cy, k, col, line=None):
    line = line or pen(k)

    def p(x, y):
        return (cx + x * k, cy + y * k)

    s = 0.16
    return (poly([p(-s, 0.10 - s), p(s, 0.10 - s), p(s, 0.10 + s),
                  p(-s, 0.10 + s)], col, line)
            + disc(cx, cy + 0.10 * k, 0.055 * k, col)
            + arc(cx, cy + 0.10 * k, 0.34 * k, math.radians(200),
                  math.radians(340), line, col))


# ---- D. Busts: head and shoulders, the head answering the question ----
def shoulders(cx, cy, k, col, line):
    return (f'<path d="M {fmt(cx - 0.38 * k)} {fmt(cy + 0.42 * k)} '
            f'C {fmt(cx - 0.36 * k)} {fmt(cy + 0.14 * k)} '
            f'{fmt(cx - 0.20 * k)} {fmt(cy + 0.04 * k)} '
            f'{fmt(cx)} {fmt(cy + 0.04 * k)} '
            f'C {fmt(cx + 0.20 * k)} {fmt(cy + 0.04 * k)} '
            f'{fmt(cx + 0.36 * k)} {fmt(cy + 0.14 * k)} '
            f'{fmt(cx + 0.38 * k)} {fmt(cy + 0.42 * k)}" '
            f'fill="none" stroke="{col}" stroke-width="{fmt(line)}"/>')


def bust_pilot(cx, cy, k, col, line=None):
    line = line or pen(k)
    return (ring(cx, cy - 0.18 * k, 0.17 * k, line, col)
            + shoulders(cx, cy, k, col, line))


def bust_bot(cx, cy, k, col, line=None):
    line = line or pen(k)

    def p(x, y):
        return (cx + x * k, cy + y * k)

    head = poly([p(-0.16, -0.34), p(0.16, -0.34), p(0.16, -0.02),
                 p(-0.16, -0.02)], col, line)
    lens = seg(*p(-0.08, -0.16), *p(0.08, -0.16), line * 1.4, col, "butt")
    ant = (seg(*p(0, -0.34), *p(0, -0.48), pen(k, 0.09), col)
           + disc(*p(0, -0.55), 0.055 * k, col))
    return head + lens + ant + shoulders(cx, cy, k, col, line)


# ---- E. Signals: what is on the stick, drawn as a trace ----
def sig_pilot(cx, cy, k, col, line=None):
    line = line or pen(k)
    pts = []
    for i in range(33):
        t = i / 32
        x = cx + (t - 0.5) * 0.9 * k
        pts.append((x, cy - 0.20 * k * math.sin(t * math.pi * 3)))
    return poly(pts, col, line, closed=False, cap="round")


def sig_bot(cx, cy, k, col, line=None):
    line = line or pen(k)

    def p(x, y):
        return (cx + x * k, cy + y * k)

    pts = [p(-0.45, 0.20), p(-0.45, -0.20), p(-0.15, -0.20), p(-0.15, 0.20),
           p(0.15, 0.20), p(0.15, -0.20), p(0.45, -0.20), p(0.45, 0.20)]
    return poly(pts, col, line, closed=False, cap="butt")


DIRS = [
    ("Current", "As shipped", cur_pilot, cur_bot,
     "A front-view helmet with the visor wrapped into the shell; a boxed "
     "shell with two lamps and an antenna. Curved is grown, boxed is built."),
    ("Profiles", "A. Profiles", prof_pilot, prof_bot,
     "The same two heads turned side on, facing the way ships fly. A "
     "helmet in profile is the aviation silhouette; the machine keeps the "
     "box, one lens forward, antenna aft."),
    ("Badges", "B. Badges", wing_pilot, chip_bot,
     "Not heads at all: what each one is. A pilot wears wings; a machine "
     "is silicon. The wings also make the Pilot rail stop literal."),
    ("Blips", "C. Scope blips", blip_pilot, blip_bot,
     "The radar's own vocabulary: two contacts under the same sweep. "
     "Round and solid is alive; square with a lens dot is built."),
    ("Busts", "D. Busts", bust_pilot, bust_bot,
     "Head and shoulders instead of a bottled helmet. The shared "
     "shoulders make the pair one question; the head answers it."),
    ("Signals", "E. Signals", sig_pilot, sig_bot,
     "What is on the stick, drawn as a trace. A hand flies in curves, a "
     "clock flies in steps. The most abstract, and the most vector."),
]


def mark_svg(fn, k, col, pad=None, line=None):
    pad = pad if pad is not None else max(3, k * 0.32)
    side = k + 2 * pad
    inner = fn(side / 2, side / 2, k, col, line)
    return (f'<svg width="{fmt(side)}" height="{fmt(side)}" '
            f'style="flex:none;overflow:visible">{inner}</svg>')


# ---- Context strips, drawn the way the client draws them ----
def games_row(pfn, bfn, w=390):
    counts = ('<div class="row" style="gap:6px;flex:none">'
              + mark_svg(bfn, 11, "rgba(108,122,144,.9)", pad=3)
              + '<span class="mono" style="font-size:12px;'
              'color:rgba(223,233,245,.75)">5</span>'
              '<span style="width:8px"></span>'
              + mark_svg(pfn, 11, "rgba(108,122,144,.9)", pad=3)
              + '<span class="mono" style="font-size:12px;'
              'color:rgba(223,233,245,.75)">3</span></div>')
    return (f'<div style="width:{w}px;border:1px solid rgba(63,88,120,.5);'
            'background:rgba(7,11,18,.6);padding:12px 16px">'
            '<div class="row">'
            '<div class="col" style="flex:1;min-width:0">'
            '<span style="font-size:17px">Team Battle</span>'
            '<span class="note" style="margin-top:2px">The longer your '
            'run, the bigger the bounty</span></div>' + counts
            + '</div></div>')


def roster_rows(pfn, bfn, w=250):
    def r(fn, name, col, score):
        return ('<div class="row" style="height:24px;gap:7px">'
                + mark_svg(fn, 11, col, pad=3)
                + f'<span class="mono" style="font-size:12px;color:{col}">'
                f'{name}</span><div style="flex:1"></div>'
                f'<span class="mono" style="font-size:12px;color:{col};'
                f'opacity:.8">{score}</span></div>')
    return (f'<div style="width:{w}px;border:1px solid rgba(63,88,120,.5);'
            'background:rgba(7,11,18,.6);padding:8px 14px">'
            + r(pfn, "Delta 154", FRIEND, 6)
            + r(bfn, "Vex", FRIEND, 4)
            + r(pfn, "Halcyon 9", ENEMY, 5)
            + r(bfn, "Ozone", ENEMY, 2)
            + '</div>')


def rail_cells(pfn):
    def cell(inner, label, lit=False):
        c = FRIEND if lit else "rgba(108,122,144,.9)"
        tc = "var(--ink)" if lit else "var(--dim)"
        bg = ("background:linear-gradient(0deg,rgba(79,214,255,.14),"
              "rgba(79,214,255,0) 80%);" if lit else "")
        return ('<div class="col" style="align-items:center;'
                f'justify-content:center;gap:5px;width:64px;height:64px;'
                f'{bg}">' + inner.format(c=c)
                + f'<span style="font-size:9px;color:{tc}">{label}</span>'
                '</div>')
    zones = ('<svg width="22" height="22" viewBox="0 0 22 22" fill="none" '
             'stroke="{c}" stroke-width="1.2"><circle cx="11" cy="11" '
             'r="4.6"/><ellipse cx="11" cy="11" rx="9.6" ry="3.6" '
             'transform="rotate(-19 11 11)"/></svg>')
    ship = ('<svg width="22" height="22" viewBox="0 0 22 22" fill="none" '
            'stroke="{c}" stroke-width="1.2"><g transform="translate(11,12) '
            'scale(.68)"><path d="M0,-13 L15,9 L7,12 L0,8 L-7,12 L-15,9 Z"/>'
            '</g></svg>')
    pilot = mark_svg(pfn, 21, FRIEND, pad=0.5, line=1.2)
    return ('<div class="row" style="border:1px solid rgba(63,88,120,.5);'
            'background:rgba(7,11,18,.6)">'
            + cell(zones, "play") + cell(ship, "ship")
            + cell(pilot.replace("SENTINEL", ""), "pilot", lit=True)
            + '</div>')


def size_run(pfn, bfn):
    cells = []
    for k in (36, 21, 16, 11):
        cells.append(
            '<div class="col" style="align-items:center;gap:6px">'
            '<div class="row" style="gap:10px;align-items:flex-end">'
            + mark_svg(pfn, k, INK) + mark_svg(bfn, k, INK) + '</div>'
            + f'<span class="lbl">{k}</span></div>')
    return ('<div class="row" style="gap:20px;align-items:flex-end">'
            + "".join(cells) + '</div>')


# ---- Round 2: the Badges direction, opened up ----
#
# Chris picked Badges. Two variant sheets, then the strongest pairings put
# back into the game's contexts. The wings vary in how they are cut; the
# machine varies in what it wears, including its own set of wings printed
# as circuit traces, which keeps the pair one grammar the way the shared
# collar did for the helmets.
def wing_feathers(cx, cy, k, col, line=None):
    return wing_pilot(cx, cy, k, col, line)


def wing_solid(cx, cy, k, col, line=None):
    line = line or pen(k)

    def p(x, y):
        return (cx + x * k, cy + y * k)

    out = [filled([p(0, -0.16), p(0.11, 0), p(0, 0.18), p(-0.11, 0)], col)]
    for s in (1, -1):
        out.append(filled([p(s * 0.10, -0.05), p(s * 0.53, -0.27),
                           p(s * 0.41, -0.11), p(s * 0.45, -0.05),
                           p(s * 0.31, 0.01), p(s * 0.35, 0.07),
                           p(s * 0.13, 0.12)], col))
    return "".join(out)


def wing_chevron(cx, cy, k, col, line=None):
    line = line or pen(k)

    def p(x, y):
        return (cx + x * k, cy + y * k)

    out = [filled([p(0, -0.12), p(0.09, 0.01), p(0, 0.14), p(-0.09, 0.01)],
                  col)]
    for s in (1, -1):
        out.append(seg(*p(s * 0.10, 0.02), *p(s * 0.50, -0.20),
                       line * 1.6, col, "round"))
        out.append(seg(*p(s * 0.09, 0.13), *p(s * 0.36, -0.01),
                       line * 1.6, col, "round"))
    return "".join(out)


def wing_hull(cx, cy, k, col, line=None):
    line = line or pen(k)

    def p(x, y):
        return (cx + x * k, cy + y * k)

    # The client's own hull thumb at the center of the spread: the wings
    # are the badge, the ship is whose badge it is.
    hull = [(0, -13), (15, 9), (7, 12), (0, 8), (-7, 12), (-15, 9)]
    sc = 0.46 / 30
    out = [poly([(cx + x * sc * k, cy + (y + 0.5) * sc * k)
                 for x, y in hull], col, line)]
    for s in (1, -1):
        out.append(seg(*p(s * 0.30, 0.02), *p(s * 0.56, -0.20),
                       line * 0.9, col, "round"))
        out.append(seg(*p(s * 0.30, 0.12), *p(s * 0.50, -0.02),
                       line * 0.9, col, "round"))
    return "".join(out)


def mach_chip(cx, cy, k, col, line=None):
    return chip_bot(cx, cy, k, col, line)


def mach_gear(cx, cy, k, col, line=None):
    line = line or pen(k)
    out = [ring(cx, cy, 0.19 * k, line, col), disc(cx, cy, 0.055 * k, col)]
    for i in range(8):
        a = i * math.pi / 4 + math.pi / 8
        out.append(seg(cx + 0.19 * k * math.cos(a),
                       cy + 0.19 * k * math.sin(a),
                       cx + 0.30 * k * math.cos(a),
                       cy + 0.30 * k * math.sin(a),
                       line * 1.5, col, "butt"))
    return "".join(out)


def mach_circuit(cx, cy, k, col, line=None):
    line = line or pen(k)

    def p(x, y):
        return (cx + x * k, cy + y * k)

    out = [filled([p(-0.08, -0.08), p(0.08, -0.08), p(0.08, 0.10),
                   p(-0.08, 0.10)], col)]
    for s in (1, -1):
        for a, b, c in (((0.10, -0.06), (0.24, -0.06), (0.52, -0.30)),
                        ((0.10, 0.04), (0.30, 0.04), (0.49, -0.10)),
                        ((0.10, 0.14), (0.26, 0.14), (0.41, 0.07))):
            pts = [p(s * a[0], a[1]), p(s * b[0], b[1]), p(s * c[0], c[1])]
            out.append(poly(pts, col, line * 0.8, closed=False,
                            cap="round"))
            out.append(disc(*p(s * c[0], c[1]), 0.055 * k, col))
    return "".join(out)


def mach_radio(cx, cy, k, col, line=None):
    line = line or pen(k)

    def p(x, y):
        return (cx + x * k, cy + y * k)

    out = [seg(*p(0, 0.36), *p(0, 0.02), line, col, "butt"),
           disc(*p(0, -0.04), 0.06 * k, col)]
    for r in (0.17, 0.30):
        out.append(arc(cx, cy - 0.04 * k, r * k, math.radians(-45),
                       math.radians(45), line, col))
        out.append(arc(cx, cy - 0.04 * k, r * k, math.radians(135),
                       math.radians(225), line, col))
    return "".join(out)


def mach_hex(cx, cy, k, col, line=None):
    line = line or pen(k)
    pts = []
    for i in range(6):
        a = math.pi / 6 + i * math.pi / 3
        pts.append((cx + 0.27 * k * math.cos(a),
                    cy + 0.27 * k * math.sin(a)))
    return poly(pts, col, line) + disc(cx, cy, 0.06 * k, col)


WINGS = [
    ("Feathers", wing_feathers,
     "Round 1's cut: three strokes fanning off a diamond. Lightest on "
     "the screen; the feathers mush into one wing by 11."),
    ("Solid", wing_solid,
     "The wings as filled silhouettes with a notched trailing edge. "
     "Reads as a worn badge, and the mass survives 11 best."),
    ("Chevrons", wing_chevron,
     "Two heavy strokes a side. The most minimal cut, and the one that "
     "stays crisp smallest; large it is the plainest."),
    ("Hull", wing_hull,
     "The client's own hull thumb inside the spread: whose wings these "
     "are. Costs the most detail, so the ship dies first at 11."),
]

MACHINES = [
    ("Chip", mach_chip,
     "Round 1's machine: silicon with legs. Instantly a machine, "
     "reads at every size; also every second tech logo."),
    ("Circuit wings", mach_circuit,
     "The same wings the pilot wears, printed: traces that bend at "
     "45 and end in pads. Both marks are wings, and the texture "
     "answers the question, the way the shared collar used to."),
    ("Gear", mach_gear,
     "The oldest machine mark there is. Bold and unmistakable large; "
     "at 11 the teeth blur into a fuzzy ring."),
    ("Radio", mach_radio,
     "A mast broadcasting: the seat is remote-controlled. The most "
     "honest about what a bot is; the arcs thin out by 11."),
    ("Hex", mach_hex,
     "A nut with a bore: built, torqued down. The simplest shape "
     "here and rock solid at 11; the least specific to a machine."),
]


def variant_sheet(name, title, intro, variants, h=640):
    rows = []
    for label, fn, note in variants:
        cells = []
        for kk in (36, 21, 11):
            cells.append(
                '<div class="col" style="align-items:center;gap:5px;'
                'width:56px">' + mark_svg(fn, kk, INK)
                + f'<span class="lbl">{kk}</span></div>')
        rows.append(
            '<div class="row" style="gap:18px;padding:12px 0;'
            'border-top:1px solid rgba(63,88,120,.35);'
            'align-items:center">'
            '<div class="col" style="width:190px;flex:none">'
            f'<span style="font-size:14px">{label}</span>'
            f'<div class="note" style="margin-top:4px">{note}</div></div>'
            '<div class="row" style="gap:14px;flex:1;'
            'justify-content:center;align-items:flex-end">'
            + "".join(cells) + '</div></div>')
    body = (f'<div style="width:470px;height:{h}px;background:#05070c;'
            'padding:24px 28px;overflow:hidden">'
            f'<div class="lbl" style="font-size:10px;color:#9fb6d4">'
            f'{title}</div>'
            f'<div class="note" style="margin-top:6px">{intro}</div>'
            '<div style="margin-top:14px">' + "".join(rows)
            + '</div></div>')
    write(name + ".dc.html", body)


PAIRS = [
    ("PairSolidCircuit", "Solid wings + circuit wings", wing_solid,
     mach_circuit,
     "The matched pair: everyone at the table wears wings, and what "
     "they are cut from answers the question. Grown feathers against "
     "printed traces, one badge grammar, no head in sight."),
    ("PairSolidChip", "Solid wings + chip", wing_solid, mach_chip,
     "The blunt pair: the strongest wing cut beside the most "
     "unmistakable machine. No shared grammar between them, which is "
     "also why nobody ever misreads it."),
    ("PairChevronGear", "Chevrons + gear", wing_chevron, mach_gear,
     "The minimal pair: two strokes against a toothed ring. The "
     "quietest of the three in a row of numbers, and the gear is the "
     "only piece here that suffers at 11."),
]


# ---- Boards ----
def direction_board(key, title, pfn, bfn, note):
    body = ('<div style="width:470px;height:560px;background:#05070c;'
            'padding:24px 28px;overflow:hidden">'
            f'<div class="lbl" style="font-size:10px;color:#9fb6d4">{title}'
            '</div>'
            f'<div class="note" style="margin-top:6px">{note}</div>'
            '<div style="margin-top:20px">' + size_run(pfn, bfn) + '</div>'
            '<div class="lbl" style="margin-top:24px">games list</div>'
            '<div style="margin-top:6px">' + games_row(pfn, bfn) + '</div>'
            '<div class="lbl" style="margin-top:16px">scoreboard</div>'
            '<div class="row" style="margin-top:6px;gap:16px;'
            'align-items:flex-start">' + roster_rows(pfn, bfn)
            + '<div class="col" style="gap:6px">'
            '<span class="lbl">rail</span>' + rail_cells(pfn)
            + '</div></div></div>')
    write(key + ".dc.html", body)


def main_board():
    rows = []
    for key, title, pfn, bfn, note in DIRS:
        cur = key == "current"
        rows.append(
            '<div class="row" style="gap:24px;padding:14px 0;'
            'border-top:1px solid rgba(63,88,120,.35)">'
            '<div class="col" style="width:170px;flex:none">'
            f'<span style="font-size:14px;color:'
            f'{"rgba(223,233,245,.6)" if cur else "var(--ink)"}">{title}'
            '</span></div>'
            '<div class="row" style="gap:12px;width:150px;flex:none;'
            'justify-content:center">'
            + mark_svg(pfn, 34, INK) + mark_svg(bfn, 34, INK) + '</div>'
            '<div class="row" style="gap:8px;width:90px;flex:none;'
            'justify-content:center">'
            + mark_svg(pfn, 11, "rgba(108,122,144,.9)", pad=3)
            + '<span class="mono" style="font-size:12px;'
            'color:rgba(223,233,245,.75)">3</span>'
            + mark_svg(bfn, 11, "rgba(108,122,144,.9)", pad=3)
            + '<span class="mono" style="font-size:12px;'
            'color:rgba(223,233,245,.75)">5</span></div>'
            f'<div class="note" style="flex:1">{note}</div></div>')
    body = ('<div style="width:880px;height:700px;background:#05070c;'
            'padding:28px 32px;overflow:hidden">'
            '<div class="lbl" style="font-size:10px;color:#9fb6d4">'
            'who is in the seat: six ways to draw it</div>'
            '<div class="note" style="margin-top:6px;max-width:640px">'
            'Two marks answer one question everywhere the game counts or '
            'names a seat. The constraint that decides everything: one '
            'color, one thin pen, and the pair has to survive at 11 points '
            'beside a count, solo beside an AI name, and at 21 in the rail '
            'where the human mark also stands for the Pilot page.</div>'
            '<div style="margin-top:18px">' + "".join(rows) + '</div>'
            '</div>')
    write("Main.dc.html", body)


def canvas():
    import json
    arts = [{"file": "Main.dc.html", "title": "Six ways", "page": "page-1",
             "x": 0, "y": 0, "w": 880, "h": 700}]
    names = ["Current", "Profiles", "Badges", "Blips", "Busts", "Signals"]
    for i, n in enumerate(names):
        arts.append({"file": n + ".dc.html", "title": n, "page": "page-1",
                     "x": (i % 3) * 570, "y": 830 + (i // 3) * 690,
                     "w": 470, "h": 560})
    arts.append({"file": "Wings.dc.html", "title": "The wings",
                 "page": "page-2", "x": 0, "y": 0, "w": 470, "h": 640})
    arts.append({"file": "Machines.dc.html", "title": "The machine",
                 "page": "page-2", "x": 570, "y": 0, "w": 470, "h": 760})
    for i, (key, title, _, _, _) in enumerate(PAIRS):
        arts.append({"file": key + ".dc.html", "title": title,
                     "page": "page-2", "x": i * 570, "y": 900,
                     "w": 470, "h": 560})
    notes = [
        {"id": "note-brief", "page": "page-1", "x": 940, "y": 40, "w": 380,
         "text":
         "The ask: alternatives to the current human and bot marks, whose "
         "style Chris doesn't like. Five directions, each moving on a "
         "different axis: turn the heads (Profiles), drop the heads for "
         "what they wear (Badges), go fully abstract in the radar's own "
         "language (Blips), draw the person rather than the hat (Busts), "
         "or draw the flying itself (Signals).\n\nEvery board shows the "
         "pair at the three sizes the client actually draws: 11 beside "
         "counts and names, 21 in the rail, large only for judging."},
        {"id": "note-lean", "page": "page-1", "x": 940, "y": 420, "w": 380,
         "text":
         "A read on each, honestly: Badges is the most distinctive and "
         "the wings make the Pilot stop literal, but a chip is every "
         "second tech logo. Profiles keeps today's grown-vs-built logic "
         "with far more character at large sizes; it is the least legible "
         "at 11. Blips is the most native to a space game and the most "
         "abstract; it needs the pair side by side once to learn. Busts "
         "is the safest read at 11 and the least interesting large. "
         "Signals is the boldest idea and the biggest gamble."},
        {"id": "note-round2", "page": "page-2", "x": 1140, "y": 40,
         "w": 380, "text":
         "Round 2: Badges opened up. Left sheet cuts the wings four "
         "ways, right sheet tries five things for the machine to wear. "
         "Below, the three pairings worth arguing about, each back in "
         "the games list, scoreboard and rail.\n\nThe lean: solid wings "
         "with circuit wings. Matched badges keep the pair one grammar "
         "the way the old shared collar did, and both carry mass, so "
         "neither side goes thin at 11. Chip is the safe fallback if "
         "the two wing shapes sit too close at list size; the "
         "scoreboard board is the place to judge that."},
    ]
    pages = [{"id": "page-1", "name": "Directions"},
             {"id": "page-2", "name": "Badges round 2"}]
    doc = {"artboards": arts, "annotations": notes, "pages": pages,
           "launch": {"view": "canvas", "page": "page-2"}}
    pathlib.Path(OUT, "canvas.json").write_text(
        json.dumps(doc, indent=2) + "\n")


for key, title, pfn, bfn, note in DIRS:
    direction_board(key, title, pfn, bfn, note)
variant_sheet("Wings", "the wings, four cuts",
              "What the pilot wears, varied in how it is cut. The "
              "diamond stays; the wings change weight and count.", WINGS)
variant_sheet("Machines", "the machine, five badges",
              "What sits beside the wings. Two keep round 1's silicon, "
              "one prints the pilot's own wings in traces, two reach "
              "for older machine marks.", MACHINES, h=760)
for key, title, pfn, bfn, note in PAIRS:
    direction_board(key, title, pfn, bfn, note)
main_board()
canvas()
print("boards written")
