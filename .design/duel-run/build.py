#!/usr/bin/env python3
"""Assemble the six .dc.html artboards for the duel's run panel.

The shipped panel heads a duel's fight list with "RUNG 6  FLOOR 6" and gives
every row under it a rung number. Chris's reading: the rung and floor words are
weird, track streaks instead, name the rivals, say who won, and cap the list at
about five.

Three directions, by what leads the panel:

  A  the list leads: a plain streak reading over five named fights
  B  the shape leads: the run drawn as one mark per fight over the same rows
  C  the number leads: the streak is a figure, the rows shrink to name and word

The moment on the desktop boards is the one in Chris's screenshot, so the four
compare line for line: twelve fights in, Tessellate 0001 has just taken the
life, the streak is broken, and the shipped panel is showing its whole
twelve-leg window. The phone board draws the other moment, a win, and the live
board draws the panel mid-fight at its 340 point measure.

Drawings of a proposal, not a plan of record. The design system is the
client's, lifted from ../podium-rethink/build.py: hues from
client/arena/palette.lua, panel and key geometry from client/arena/ui.lua, the
two faces from client/ui/, and the rival order computed off
pilots::CALIBRATED so the names in the run are the ones a real evening deals.

Rebuild with: python3 build.py
"""

import random
from pathlib import Path

HERE = Path(__file__).parent

# The ending draws at F.scale times END.ZOOM, so every authored size on a
# desktop board is its ui.lua number times this. The four sizes ui.lua divides
# back out (the score bar, the names inside it, the countdown and its caption)
# are written here at their bare values.
Z = 1.45

BG, INK, DIM = "#05070c", "#dfe9f5", "#6c7a90"
FRIEND, ENEMY = "#4fd6ff", "#ffa552"
RULE, PAID, BOUNTY = "#3f5878", "#8dffb0", "#ffe08a"

MONO = '"DejaVu Sans Mono","Noto Sans Mono",ui-monospace,monospace'
MENU = '"Chakra Petch","Segoe UI",system-ui,sans-serif'

# The rival ladder, weakest first, as pilots::provisional_ladder_order sorts
# CALIBRATED by its ordering prior. Rung six is Tessellate, which is who the
# screenshot lost to.
RIVALS = ["Kestrel", "Cirrus", "Halcyon", "Ozone", "Vantage",
          "Tessellate", "Ridgeline", "Sable"]

# One evening, played by the mode's own rules: a win climbs one, a loss drops
# two without crossing the five-rung checkpoint. It ends on rung six with the
# floor at six and the streak broken, which is the state in the screenshot.
#
# (rung, won, seconds), oldest first.
RUN = [
    (0, True, 34), (1, True, 41), (2, True, 28), (3, False, 52),
    (1, True, 22), (2, True, 37), (3, True, 63), (4, False, 47),
    (2, True, 19), (3, True, 33), (4, True, 51), (5, False, 26),
]
LEGS = len(RUN)
BEST_RUN = 3


def leg(n):
    """One finished fight as the panel reads it: who, what, how long."""
    rung, won, secs = RUN[n]
    return (f"{RIVALS[rung]} 0001", won, f"{secs // 60}:{secs % 60:02d}", rung)


# Newest first, which is the order every one of these panels draws in.
RECENT = [leg(n) for n in range(LEGS - 1, -1, -1)]


def starfield(w, h, seed):
    rnd = random.Random(seed)
    out = [
        f"radial-gradient(620px 420px at {int(w * .72)}px {int(h * .3)}px,"
        "rgba(39,197,237,.05),transparent 70%)",
        f"radial-gradient(520px 380px at {int(w * .2)}px {int(h * .78)}px,"
        "rgba(255,157,34,.04),transparent 70%)",
    ]
    for n, col, r in ((70, "#2a3a58", 0.9), (34, "#4a6089", 1.0),
                      (16, "#93a9c8", 1.3)):
        for _ in range(n):
            x, y = rnd.randint(0, w), rnd.randint(0, h)
            out.append(f"radial-gradient(circle {r}px at {x}px {y}px,"
                       f"{col} 0 {r}px,transparent {r}px)")
    return ",".join(out)


CSS = f"""
:root{{
  --bg:{BG}; --ink:{INK}; --dim:{DIM}; --friend:{FRIEND}; --enemy:{ENEMY};
  --rule:{RULE}; --paid:{PAID}; --bounty:{BOUNTY};
  --mono:{MONO}; --menu:{MENU};
}}
*{{box-sizing:border-box}}
body{{margin:0;background:var(--bg);color:var(--ink);font-family:var(--menu)}}
a{{color:var(--friend)}}a:hover{{color:#8ee6ff}}
.num{{font-family:var(--mono);font-variant-numeric:tabular-nums}}
.lbl{{font-family:var(--mono);text-transform:uppercase;letter-spacing:.14em;
  color:var(--dim)}}
.row{{display:flex;align-items:center}}
.col{{display:flex;flex-direction:column}}
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
  <style>{css}</style>
</helmet>
"""
FOOT = "</x-dc>\n\n</body>\n</html>\n"


def write(name, body):
    (HERE / name).write_text(HEAD.format(css=CSS) + body + FOOT)


# ---- The client's own marks ----

def helm(col, k):
    return (f'<svg width="{k:.0f}" height="{k:.0f}" viewBox="0 0 14 14" '
            f'fill="none" style="flex:none">'
            f'<path d="M2 8.2 A5 5 0 0 1 12 8.2" stroke="{col}" '
            f'stroke-width="1.1"/>'
            f'<path d="M3.6 7.4 A3.4 3.4 0 0 1 10.4 7.4" stroke="{col}" '
            f'stroke-width="1" opacity=".65"/>'
            f'<path d="M1.2 9.4 H12.8" stroke="{col}" '
            f'stroke-width="1.1"/></svg>')


def bot(col, k):
    return (f'<svg width="{k:.0f}" height="{k:.0f}" viewBox="0 0 14 14" '
            f'fill="none" style="flex:none">'
            f'<path d="M7 .8 V3" stroke="{col}" stroke-width="1"/>'
            f'<rect x="2.4" y="3.2" width="9.2" height="5.6" stroke="{col}" '
            f'stroke-width="1.1"/>'
            f'<circle cx="5" cy="6" r=".9" fill="{col}"/>'
            f'<circle cx="9" cy="6" r=".9" fill="{col}"/>'
            f'<path d="M1.2 9.4 H12.8" stroke="{col}" '
            f'stroke-width="1.1"/></svg>')


def rivet(col, k):
    return (f'<svg width="{k:.0f}" height="{k:.0f}" viewBox="0 0 12 12" '
            f'fill="none" style="flex:none">'
            f'<circle cx="6" cy="6" r="4.4" stroke="{col}" stroke-width="1.1"/>'
            f'<circle cx="6" cy="6" r="1.7" fill="{col}"/>'
            f'<path d="M6 1.6 V3" stroke="{col}" stroke-width="1"/>'
            f'<path d="M6 9 V10.4" stroke="{col}" stroke-width="1"/></svg>')


def share_mark(col, k):
    return (f'<svg width="{k:.0f}" height="{k:.0f}" viewBox="0 0 16 16" '
            f'fill="none" style="flex:none"><path d="M8 2 V10 M5 5 L8 2 L11 5" '
            f'stroke="{col}" stroke-width="1.3"/>'
            f'<path d="M4 8 H3 V14 H13 V8 H12" stroke="{col}" '
            f'stroke-width="1.3"/></svg>')


def pip(won, k):
    """One finished fight, drawn. A win is filled, a loss is the ring alone,
    which is the same solid-and-hollow pair the hangar's slot ladders use."""
    col = FRIEND if won else ENEMY
    fill = col if won else "none"
    return (f'<svg width="{k:.0f}" height="{k:.0f}" viewBox="0 0 10 10" '
            f'fill="none" style="flex:none"><circle cx="5" cy="5" r="3.4" '
            f'stroke="{col}" stroke-width="1.2" fill="{fill}" '
            f'opacity="{1 if won else 0.8}"/></svg>')


# ---- Panels, drawn the way ui.lua draws them: a wash, a left rule with a
# short skirt off it, and a ticked rule under the head. ----

PANEL_BG = "rgba(5,7,12,.62)"


def panel(inner, pad_top, pad_bottom, s):
    skirt = (f"linear-gradient(90deg,rgba(63,88,120,.07),"
             f"rgba(63,88,120,0) {26 * s:.0f}px)")
    return (f'<div style="position:relative;background:{PANEL_BG};'
            f'padding:{pad_top:.0f}px 0 {pad_bottom:.0f}px">'
            f'<div style="position:absolute;inset:0;background:{skirt};'
            f'pointer-events:none"></div>'
            f'<div style="position:absolute;left:0;top:0;bottom:0;'
            f'width:{1.4 * s:.1f}px;background:rgba(63,88,120,.7)"></div>'
            f'<div style="position:relative">{inner}</div></div>')


def ticked(s):
    """The head's rule: a hairline with a short uptick every 14 points."""
    pitch = 14 * s
    return (f'<div style="height:{2.5 * s:.1f}px;'
            f'background:repeating-linear-gradient(90deg,'
            f'rgba(63,88,120,.35) 0 {0.8 * s:.1f}px,'
            f'transparent {0.8 * s:.1f}px {pitch:.1f}px),'
            f'linear-gradient(rgba(63,88,120,.25),rgba(63,88,120,.25));'
            f'background-position:0 0,0 100%;'
            f'background-size:100% 100%,100% {0.8 * s:.1f}px;'
            f'background-repeat:no-repeat;margin:0 {12 * s:.0f}px"></div>')


def head_band(left, right, s):
    """A panel's head: its reading on the left, its count on the right, over
    the ticked rule. Both are 10 point mono, the label register."""
    return (f'<div class="row" style="justify-content:space-between;'
            f'padding:0 {12 * s:.0f}px {6 * s:.0f}px;gap:{12 * s:.0f}px">'
            f'{left}{right}</div>{ticked(s)}')


def lbl(text, s, col=None, px=10):
    return (f'<span class="lbl" style="font-size:{px * s:.1f}px;'
            f'color:{col or "var(--dim)"}">{text}</span>')


def val(text, s, col=None, px=10, weight=400):
    return (f'<span class="num" style="font-size:{px * s:.1f}px;'
            f'font-weight:{weight};color:{col or INK}">{text}</span>')


def reading(label, value, s, col=None, px=10):
    """The label-over-value pair set on one line, which is how every other
    machine reading in this interface is set."""
    return (f'<span class="row" style="gap:{6 * s:.0f}px">'
            f'{lbl(label, s, px=px)}{val(value, s, col, px)}</span>')


# ---- The roster, unchanged by any of this, drawn so the boards compare ----

ME = "DRiFT"
RIVAL_NAME = "Tessellate 0001"


def roster(s, won_the_life, rival=None, ending=True):
    """The pilot list, which none of this changes. Two rows in a duel. The
    ending swaps the bounty column for points under the rivet mark and puts
    the best gun's mark on a row; mid-fight it keeps PTS and BTY and marks
    nobody, which is what ui.lua does either side of the whistle."""
    rival = rival or RIVAL_NAME
    num = (13 - 2) * s
    small = (13 - 3) * s
    line = 18 * s
    pad = 12 * s
    # As wide as the widest thing in the column, floored at 16, which is
    # ui.lua's own rule. Every figure in a duel is one digit, so K, D and A
    # sit on the floor and only the three-letter heads on the mid-fight
    # board are wider than it.
    col_w = 16 * s
    wide = (16 if ending else 19) * s
    mark = 11 * s

    def cell(text, width, col=INK, alpha=0.85):
        return (f'<span class="num" style="width:{width:.0f}px;'
                f'text-align:right;font-size:{num:.1f}px;color:{col};'
                f'opacity:{alpha};flex:none">{text}</span>')

    def head_cell(text, width):
        return (f'<span class="lbl" style="width:{width:.0f}px;'
                f'text-align:right;font-size:{small:.1f}px;flex:none">{text}'
                f'</span>')

    def row(name, human, k, d, a, pts, bty, col, mine, mvp):
        wash = ""
        if mine:
            wash = (f"background:linear-gradient(90deg,rgba(79,214,255,.16),"
                    f"rgba(79,214,255,.104) {130 * s:.0f}px,"
                    f"rgba(79,214,255,.104));"
                    f"box-shadow:inset {1.6 * s:.1f}px 0 0 rgba(79,214,255,.95);")
        tag = ""
        if mvp:
            tag = (f'<span class="lbl" style="font-size:{small:.1f}px;'
                   f'color:{PAID};opacity:.95;flex:none">MVP</span>')
        money = "" if ending else cell(bty, wide, BOUNTY, 0.9)
        return (f'<div class="row" style="height:{line:.0f}px;{wash}'
                f'padding:0 {pad:.0f}px;gap:{7 * s:.0f}px">'
                f'<span style="font-family:var(--menu);font-size:{num:.1f}px;'
                f'color:{col};opacity:{1 if mine else 0.8};'
                f'white-space:nowrap">{name}</span>'
                f'{tag}<div style="flex:1"></div>'
                f'{bot(DIM, mark) if not human else helm(DIM, mark)}'
                f'{cell(k, col_w)}{cell(d, col_w)}{cell(a, col_w)}'
                f'{cell(pts, wide)}{money}</div>')

    pts_head = (f'<span style="width:{wide:.0f}px;display:flex;flex:none;'
                f'justify-content:flex-end">{rivet(DIM, small)}</span>'
                if ending else head_cell("PTS", wide))
    bty_head = "" if ending else head_cell("BTY", wide)
    heads = (f'<div class="row" style="padding:0 {pad:.0f}px;'
             f'gap:{7 * s:.0f}px">'
             f'<span class="lbl" style="font-size:{small:.1f}px;'
             f'color:{FRIEND};opacity:.95;flex:none">PILOTS</span>'
             f'<div style="flex:1"></div>'
             f'<span style="width:{mark:.0f}px;flex:none"></span>'
             f'{head_cell("K", col_w)}{head_cell("D", col_w)}'
             f'{head_cell("A", col_w)}{pts_head}{bty_head}</div>')

    if won_the_life:
        rows = (row(ME, True, 1, 0, 0, 3, 2, FRIEND, True, ending)
                + row(rival, False, 0, 1, 0, 0, 1, ENEMY, False, False))
    else:
        rows = (row(rival, False, 1, 0, 0, 3, 2, ENEMY, False, ending)
                + row(ME, True, 0, 1, 0, 0, 1, FRIEND, True, False))
    inner = (f'<div style="padding:0 0 {6 * s:.0f}px">{heads}</div>{ticked(s)}'
             f'<div style="height:{6 * s:.0f}px"></div>{rows}')
    return panel(inner, 14 * s, 8 * s, s)


# ---- The run panel: the thing this canvas is about ----

def run_row(name, won, clock, s, lead_word=False, bare=False, show_pip=False):
    num = (13 - 2) * s
    line = 18 * s
    pad = 12 * s
    word, col = ("won", FRIEND) if won else ("lost", ENEMY)

    def word_cell(width):
        return (f'<span class="num" style="width:{width:.0f}px;flex:none;'
                f'font-size:{num:.1f}px;color:{col};opacity:.9;'
                f'text-align:{"left" if lead_word else "right"}">{word}</span>')

    name_el = (f'<span style="font-family:var(--menu);font-size:{num:.1f}px;'
               f'color:{INK};opacity:.85;white-space:nowrap">{name}</span>')
    clock_el = (f'<span class="num" style="font-size:{num:.1f}px;color:{INK};'
                f'opacity:.8;width:{34 * s:.0f}px;text-align:right;'
                f'flex:none">{clock}</span>')
    mark = pip(won, 10 * s) if show_pip else ""

    if lead_word:
        body = (f'{word_cell(38 * s)}{name_el}<div style="flex:1"></div>'
                f'{clock_el}')
    elif bare:
        body = (f'{mark}{name_el}<div style="flex:1"></div>{word_cell(38 * s)}')
    else:
        body = (f'{name_el}<div style="flex:1"></div>{word_cell(38 * s)}'
                f'{clock_el}')
    return (f'<div class="row" style="height:{line:.0f}px;'
            f'padding:0 {pad:.0f}px;gap:{7 * s:.0f}px">{body}</div>')


def run_shipped(s, shown):
    """As shipped: the rung and the floor at the head, a rung number on every
    row, the scoreline in the middle, and as many legs as the window holds."""
    num = (13 - 2) * s
    small = (13 - 3) * s
    line = 18 * s
    pad = 12 * s
    heads = (f'<div class="row" style="justify-content:space-between;'
             f'padding:0 {pad:.0f}px {6 * s:.0f}px">'
             f'<span class="num" style="font-size:{small:.1f}px;color:{INK};'
             f'opacity:.85;letter-spacing:.06em">RUNG 6&nbsp;&nbsp;FLOOR 6'
             f'</span>'
             f'<span class="num" style="font-size:{small:.1f}px;color:{DIM};'
             f'opacity:.7">run: {LEGS} fights</span></div>')
    rows = ""
    for name, won, clock, rung in RECENT[:shown]:
        word, col = ("won", FRIEND) if won else ("lost", ENEMY)
        rows += (f'<div class="row" style="height:{line:.0f}px;'
                 f'padding:0 {pad:.0f}px;gap:{7 * s:.0f}px">'
                 f'<span class="num" style="font-size:{num:.1f}px;color:{INK};'
                 f'opacity:.85">rung {rung + 1}</span>'
                 f'<div style="flex:1"></div>'
                 f'<span class="num" style="width:{38 * s:.0f}px;'
                 f'text-align:right;font-size:{num:.1f}px;color:{col};'
                 f'opacity:.9">{word}</span>'
                 f'<span class="num" style="width:{34 * s:.0f}px;'
                 f'text-align:right;font-size:{num:.1f}px;color:{INK};'
                 f'opacity:.8">{"0-1" if not won else "1-0"}</span>'
                 f'<span class="num" style="width:{34 * s:.0f}px;'
                 f'text-align:right;font-size:{num:.1f}px;color:{INK};'
                 f'opacity:.8">{clock}</span></div>')
    inner = (f'<div style="padding:0 0 {6 * s:.0f}px">{heads}</div>{ticked(s)}'
             f'<div style="height:{6 * s:.0f}px"></div>{rows}')
    return panel(inner, 14 * s, 6 * s, s)


SHOWN = 5


def run_a(s, streak, shown=SHOWN, best=BEST_RUN, legs=LEGS):
    """A: a plain streak reading over five named fights."""
    left = (f'<span class="row" style="gap:{14 * s:.0f}px">'
            f'{reading("streak", streak, s, FRIEND if streak else DIM)}'
            f'{reading("best", best, s)}</span>')
    right = (f'<span class="num" style="font-size:{10 * s:.1f}px;color:{DIM};'
             f'opacity:.7">{legs} fights</span>')
    rows = "".join(run_row(n, w, c, s) for n, w, c, _ in RECENT[:shown])
    inner = (f'<div style="padding:0 0 {6 * s:.0f}px">'
             f'<div class="row" style="justify-content:space-between;'
             f'padding:0 {12 * s:.0f}px;gap:{12 * s:.0f}px">{left}{right}</div>'
             f'</div>{ticked(s)}<div style="height:{6 * s:.0f}px"></div>{rows}')
    return panel(inner, 14 * s, 6 * s, s)


def run_b(s, streak, shown=SHOWN, best=BEST_RUN, legs=LEGS):
    """B: the whole run drawn as one mark per fight, oldest at the left."""
    marks = "".join(pip(won, 10 * s) for _, won, _ in RUN)
    left = (f'<span class="row" style="gap:{9 * s:.0f}px">'
            f'{lbl("run", s)}'
            f'<span class="row" style="gap:{4 * s:.0f}px">{marks}</span>'
            f'</span>')
    right = (f'<span class="row" style="gap:{12 * s:.0f}px">'
             f'{reading("streak", streak, s, FRIEND if streak else DIM)}'
             f'{reading("best", best, s)}</span>')
    rows = "".join(run_row(n, w, c, s) for n, w, c, _ in RECENT[:shown])
    inner = (f'<div style="padding:0 0 {6 * s:.0f}px">'
             f'<div class="row" style="justify-content:space-between;'
             f'padding:0 {12 * s:.0f}px;gap:{12 * s:.0f}px">{left}{right}</div>'
             f'</div>{ticked(s)}<div style="height:{6 * s:.0f}px"></div>{rows}')
    return panel(inner, 14 * s, 6 * s, s)


def run_c(s, streak, shown=SHOWN, best=BEST_RUN, legs=LEGS):
    """C: no head at all. The streak is a figure in a column of its own,
    standing beside the rows rather than over them, and the rows drop to a
    mark, a name and the word. Five rows and the figure occupy the same band,
    so this is the shortest of the three by a whole head."""
    big = 44 * s
    fig = (f'<div class="col" style="width:{116 * s:.0f}px;flex:none;'
           f'align-items:center;justify-content:center;'
           f'gap:{2 * s:.0f}px">'
           f'<span class="num" style="font-size:{big:.0f}px;line-height:1;'
           f'color:{FRIEND if streak else DIM}">{streak}</span>'
           f'{lbl("in a row", s, px=9)}'
           f'<span class="num" style="font-size:{9 * s:.1f}px;color:{DIM};'
           f'opacity:.7;white-space:nowrap">best {best} of {legs}</span>'
           f'</div>')
    rows = "".join(run_row(n, w, c, s, bare=True, show_pip=True)
                   for n, w, c, _ in RECENT[:shown])
    inner = (f'<div class="row" style="align-items:stretch">{fig}'
             f'<div style="width:{0.8 * s:.1f}px;margin:{4 * s:.0f}px 0;'
             f'background:rgba(63,88,120,.35)"></div>'
             f'<div class="col" style="flex:1;justify-content:center">'
             f'{rows}</div></div>')
    return panel(inner, 8 * s, 8 * s, s)


# ---- The ending's head and foot, which the run panel sits between ----

def result_line(s, said, said_col, verb):
    px = 20 * s
    if verb:
        return (f'<div class="row" style="gap:{px * 0.42:.0f}px;'
                f'justify-content:center">'
                f'<span style="font-size:{px:.0f}px;color:{said_col}">{said}'
                f'</span><span style="font-size:{px:.0f}px;color:{INK};'
                f'opacity:.9">{verb}</span></div>')
    return (f'<div style="text-align:center;font-size:{px:.0f}px;'
            f'color:{said_col}">{said}</div>')


def band(s, left_name, left_score, right_name, right_score, left_col,
         right_col, compact=False):
    """The score as one bar, each side's name inside its own share of it. The
    bar and the names it holds keep the interface's own size; the figures on
    the ends wear the ending's zoom."""
    px = (20 if compact else 26) * s
    bar_h = 18 if compact else 26
    name_px = 10 if compact else 12
    total = max(1, left_score + right_score)
    share = left_score / total * 100
    pad = 9

    def inside(name, col, at_end):
        return (f'<span style="font-family:var(--menu);'
                f'font-size:{name_px}px;color:rgba(5,7,12,.95);'
                f'padding:0 {pad}px;white-space:nowrap">{name}</span>')

    lfill = (f'<div class="row" style="width:{share:.1f}%;'
             f'background:{left_col};opacity:.9;justify-content:flex-start">'
             f'{inside(left_name, left_col, False) if share > 22 else ""}</div>')
    rfill = (f'<div class="row" style="flex:1;background:{right_col};'
             f'opacity:.9;justify-content:flex-end">'
             f'{inside(right_name, right_col, True) if share < 78 else ""}'
             f'</div>')
    return (f'<div class="row" style="gap:{14 * s:.0f}px">'
            f'<span class="num" style="font-size:{px:.0f}px;line-height:1;'
            f'color:{left_col}">{left_score}</span>'
            f'<div class="row" style="flex:1;height:{bar_h}px;'
            f'background:rgba(108,122,144,.16)">{lfill}{rfill}</div>'
            f'<span class="num" style="font-size:{px:.0f}px;line-height:1;'
            f'color:{right_col}">{right_score}</span></div>')


def foot(s, compact=False):
    px = (10 if compact else 12) * s
    cap = 10 if compact else 12
    clock = 17 if compact else 21
    key_h = 26 * s
    key = (f'<div class="row" style="height:{key_h:.0f}px;flex:none;'
           f'gap:{px * 0.6:.0f}px;padding:0 {13 * s:.0f}px;'
           f'justify-content:center;border:1px solid rgba(79,214,255,.8);'
           f'background:rgba(79,214,255,.14)">'
           f'{share_mark(FRIEND, px * 0.72 * 2)}'
           f'<span class="lbl" style="font-size:{px:.1f}px;color:{FRIEND};'
           f'letter-spacing:.06em;white-space:nowrap">INVITE FRIEND</span>'
           f'</div>')
    return (f'<div class="row" style="height:{key_h:.0f}px;'
            f'gap:{12 * s:.0f}px">'
            f'<span class="lbl" style="font-size:{cap}px;opacity:.9;'
            f'white-space:nowrap;flex:none">NEXT MATCH</span>'
            f'<span class="num" style="font-size:{clock}px;color:{INK};'
            f'opacity:.92;flex:none">0:06</span>'
            f'<div style="flex:1"></div>{key}</div>')


# ---- The boards ----

DESK_W, DESK_H = 1440, 900
BLOCK = 720 * Z          # 1044, the measure the ending lays out in


def desktop(name, run_panel, said, said_col, verb, seed, bar=None):
    s = Z
    gap = 14 * s
    # The shipped bar carries the zone's side names; the directions put the two
    # call signs there instead, which is the change note-elsewhere is about.
    left, right = bar or (RIVAL_NAME, ME)
    block = (f'<div class="col" style="width:{BLOCK:.0f}px;gap:{gap:.0f}px">'
             f'{result_line(s, said, said_col, verb)}'
             f'{band(s, left, 1, right, 0, ENEMY, FRIEND)}'
             f'{roster(s, False)}'
             f'{run_panel}'
             f'{foot(s)}</div>')
    body = (f'<div style="width:{DESK_W}px;height:{DESK_H}px;position:relative;'
            f'overflow:hidden;background-color:{BG};background-image:'
            f'{starfield(DESK_W, DESK_H, seed)}">'
            f'<div style="position:absolute;inset:0;'
            f'background:rgba(3,5,10,.8)"></div>'
            f'<div style="position:absolute;inset:0;display:flex;'
            f'align-items:center;justify-content:center">{block}</div></div>')
    write(name, body)


def build_desktops():
    desktop("Current.dc.html", run_shipped(Z, LEGS),
            "back to rung 6", ENEMY, None, 7, bar=("Rival", "Pilot"))
    desktop("Main.dc.html", run_a(Z, 0), RIVAL_NAME, ENEMY, "takes it", 7)
    desktop("B.dc.html", run_b(Z, 0), RIVAL_NAME, ENEMY, "takes it", 7)
    desktop("C.dc.html", run_c(Z, 0), RIVAL_NAME, ENEMY, "takes it", 7)


def build_portrait():
    """A at the ending on an upright phone, on the other moment: a win, four
    in a row, and the block hugging the foot so the one key is under a thumb."""
    w, h = 390, 844
    s = Z
    gap = 10 * s
    inner = 390 - 2 * 14 * s
    won = [("Vantage 0001", True, "0:51", 4), ("Ozone 0001", True, "0:33", 3),
           ("Halcyon 0001", True, "0:19", 2), ("Vantage 0001", False, "0:47", 4),
           ("Ozone 0001", True, "1:03", 3)]
    global RECENT
    keep = RECENT
    RECENT = won
    panel_html = run_a(s, 4, best=4)
    RECENT = keep
    block = (f'<div class="col" style="width:{inner:.0f}px;gap:{gap:.0f}px">'
             f'{result_line(s, "Vantage 0001", FRIEND, "beaten")}'
             f'{band(s, ME, 1, "Vantage 0001", 0, FRIEND, ENEMY, compact=True)}'
             f'{roster(s, True, rival="Vantage 0001")}'
             f'{panel_html}{foot(s, compact=True)}</div>')
    body = (f'<div style="width:{w}px;height:{h}px;position:relative;'
            f'overflow:hidden;background-color:{BG};background-image:'
            f'{starfield(w, h, 11)}">'
            f'<div style="position:absolute;inset:0;'
            f'background:rgba(3,5,10,.8)"></div>'
            f'<div style="position:absolute;left:{14 * s:.0f}px;'
            f'right:{14 * s:.0f}px;bottom:{26 * s:.0f}px;display:flex;'
            f'justify-content:center">{block}</div></div>')
    write("Portrait.dc.html", body)


def build_live():
    """The same panel mid-fight, where it is asked for rather than raised at
    the whistle: no zoom, no head, no foot, and the board at its 340 point
    measure under the band."""
    w, h = 420, 300
    s = 1.0
    board = 340
    rival = "Ridgeline 0001"
    mid = [("Tessellate 0001", True, "0:33", 5), ("Vantage 0001", True, "0:19", 4),
           ("Ozone 0001", True, "0:47", 3), ("Vantage 0001", False, "1:03", 4),
           ("Ozone 0001", True, "0:26", 3)]
    global RECENT
    keep = RECENT
    RECENT = mid
    panel_html = run_a(s, 3)
    RECENT = keep

    clock = (f'<div class="row" style="height:26px;gap:12px;'
             f'justify-content:center">'
             f'<div class="col" style="align-items:flex-end;gap:0">'
             f'<span style="font-family:var(--menu);font-size:9px;'
             f'color:{FRIEND};white-space:nowrap">{ME}</span>'
             f'<span class="num" style="font-size:14px;line-height:1.05;'
             f'color:{FRIEND}">1</span></div>'
             f'<span class="num" style="font-size:26px;line-height:1;'
             f'color:{INK}">1:14</span>'
             f'<div class="col" style="align-items:flex-start;gap:0">'
             f'<span style="font-family:var(--menu);font-size:9px;'
             f'color:{ENEMY};white-space:nowrap">{rival}</span>'
             f'<span class="num" style="font-size:14px;line-height:1.05;'
             f'color:{ENEMY}">0</span></div></div>')

    body = (f'<div style="width:{w}px;height:{h}px;position:relative;'
            f'overflow:hidden;background-color:{BG};background-image:'
            f'{starfield(w, h, 3)}">'
            f'<div style="position:absolute;inset:0;'
            f'background:rgba(3,5,10,.45)"></div>'
            f'<div style="position:absolute;left:{(w - board) / 2:.0f}px;'
            f'top:14px;width:{board}px;display:flex;flex-direction:column;'
            f'gap:10px">{clock}'
            f'{roster(s, True, rival=rival, ending=False)}'
            f'{panel_html}</div></div>')
    write("Live.dc.html", body)


CANVAS = """{
  "artboards": [
    { "file": "Current.dc.html", "title": "As shipped", "x": 0, "y": 0, "w": 1440, "h": 900 },
    { "file": "Main.dc.html", "title": "A \\u00b7 the list leads", "x": 1560, "y": 0, "w": 1440, "h": 900 },
    { "file": "B.dc.html", "title": "B \\u00b7 the shape leads", "x": 3120, "y": 0, "w": 1440, "h": 900 },
    { "file": "C.dc.html", "title": "C \\u00b7 the number leads", "x": 4680, "y": 0, "w": 1440, "h": 900 },
    { "file": "Live.dc.html", "title": "A \\u00b7 mid-fight, 340 wide", "x": 1560, "y": 1180, "w": 420, "h": 300 },
    { "file": "Portrait.dc.html", "title": "A \\u00b7 phone, a win", "x": 2100, "y": 1180, "w": 390, "h": 844 }
  ],
  "annotations": [
    { "id": "note-shipped", "x": 0, "y": -300, "w": 620, "text": "As shipped, at the moment in Chris's screenshot. Twelve fights in, Tessellate 0001 has just taken the life.\\n\\nThe panel's head is RUNG 6  FLOOR 6, and every row under it is a rung number. Neither word is ever defined on screen: a floor is the checkpoint the mode will not let a loss push you below, which the panel names but never explains, and a rung is a roster slot. The streak is in that head too and is not showing, because the rule is that a streak of none is not said, so the one number this redesign is about is absent exactly when the panel is most read.\\n\\nThree more things it does: the rung is said a third time in the line over the bar (\\"back to rung 6\\"), the rival is nowhere in the run even though the run is a list of fights against people, and the middle column is 1-0 or 0-1 on every row because a duel is first to one, so it only ever says that somebody died." },
    { "id": "note-a", "x": 1560, "y": -300, "w": 620, "text": "A \\u00b7 the list leads\\n\\nThe smallest change that does what was asked. The head carries the streak and the run's best beside it; the rung, the floor and the scoreline column are gone; each row names the rival, says won or lost in that word's own color, and keeps how long the fight took. Five rows, with the count on the right saying how much longer the evening is than the five.\\n\\nThe name is set in the menu face because it is a name being read, the way a call sign in the roster is; the word and the clock beside it are mono because they are data. That is the rule in docs/design/interface.md and the shipped panel already breaks it by setting the rival's slot number where the rival's name should be.\\n\\nBEST is a number the run does not keep yet. The wire carries a best rung; a best streak is a max over the streak and one more u32.\\n\\nCost: nothing on the panel says the rivals get harder as you climb. Today the rung number says it. See the note under these boards." },
    { "id": "note-b", "x": 3120, "y": -300, "w": 620, "text": "B \\u00b7 the shape leads\\n\\nThe same rows, but the head is the whole run drawn rather than counted: one mark per fight, oldest at the left, filled for a win and hollow for a loss. Twelve marks fit the head at either measure, and the shape of an evening (three, a stumble, three, a stumble, three) is one glance instead of five rows of reading.\\n\\nThe streak reading stays on the right, because a picture of a run does not give you the number, and the number is what a player says out loud.\\n\\nCost: the marks and the rows say overlapping things, and the head grows a second thing to learn. It is also the only one of the three that needs the whole twelve-leg window rather than five." },
    { "id": "note-c", "x": 4680, "y": -300, "w": 620, "text": "C \\u00b7 the number leads\\n\\nNo head. The streak is a figure standing in a column of its own beside the rows, with the run's best under it, and the rows drop to a mark, a name and the word.\\n\\nIt is the shortest of the three: the figure occupies the same band the five rows do rather than a head over them, so the panel loses a whole head, its rule and the gap either side. That is about 45 points at the ending's scale, which on a phone is a sixth row.\\n\\nCost: how long a fight took is gone, and that is the one thing in the run a player cannot get anywhere else. And on the screen you are reading because you just lost, it puts a 0 in 60 point type, which is either the honest reading or a kick." },
    { "id": "note-elsewhere", "x": 1560, "y": 2120, "w": 900, "text": "What the words become elsewhere\\n\\nThe rung is not only in this panel, and a rename that leaves the rest saying rung is worse than saying it everywhere.\\n\\n\\u00b7 The line over the bar reads \\"rung 6 cleared\\", \\"back to rung 6\\" or \\"rung 6 drawn\\" today. On these boards it is the melee's own grammar: the rival's name and a verb. \\"Tessellate 0001 takes it\\" on a loss, \\"Vantage 0001 beaten\\" on a win, \\"drawn\\" on a draw, \\"every rival beaten\\" for a cleared roster. END.result in client/arena/ui.lua.\\n\\n\\u00b7 The bar itself says PILOT and RIVAL, which are the zone's side names. A duel is two people, so these boards put the two call signs in the bar instead. That is a separate change and can be left alone.\\n\\n\\u00b7 The play page's format strip says scoring: rungs, and the zone's hook line is \\"every rung is a harder rival; a loss drops you two\\". Both would become streak language: scoring: streak, and a sentence that promises a harder rival for every win.\\n\\n\\u00b7 Two server banners still name a rung and a checkpoint (\\"Rival disconnected. Replaying rung 6\\", \\"Ladder cleared. New run starts at checkpoint 6\\"). modes.rs, Ladder::banner." },
    { "id": "note-wire", "x": 2560, "y": 1180, "w": 620, "text": "What this costs on the wire\\n\\nThe leg the room files carries a rung, a result, a scoreline and a duration, and no name: modes::LadderLeg. So the rival's call sign has to be captured when the leg is filed, since by the time the panel draws it the rival may have left the room.\\n\\nThat is one field on the leg (the room caps a call sign at 24 bytes), the rival's name reaching the mode through ModeCtx, and eleven bytes a leg becoming eleven plus the name on S2C_MATCH. Sending five legs rather than twelve nearly pays for it.\\n\\nThe scoreline drops off the wire with the column: first_to is 1 in this zone and catalog validation refuses any other value, so kills and deaths on a leg are always 1-0, 0-1 or 1-1." },
    { "id": "note-open", "x": 3260, "y": 1180, "w": 620, "text": "The one question these boards do not answer\\n\\nThe floor is real whether or not it is named. A loss drops two rungs and cannot push you below the last checkpoint, so after twelve fights this run cannot fall below Tessellate however badly it goes. Take the word off the screen and the kindness is still there, unread.\\n\\nTwo honest ways out:\\n\\n\\u00b7 Keep the mechanic, drop the word. The rivals still climb and the floor still catches you; the screen just stops narrating the bookkeeping. Nothing on the server changes.\\n\\n\\u00b7 Make the streak the mechanic. A win puts you against a harder rival, a loss puts you back at the start, and there is no floor to explain because there is not one. That is what \\"just track streaks\\" says most plainly, and it is a harsher game: the twelfth fight on these boards would have sent this run back to Kestrel.\\n\\nThe panel draws the same either way, which is why it is a question and not a direction." }
  ],
  "launch": { "view": "canvas" }
}
"""


def main():
    build_desktops()
    build_portrait()
    build_live()
    (HERE / "canvas.json").write_text(CANVAS)
    print("wrote", len(list(HERE.glob("*.dc.html"))), "artboards")


if __name__ == "__main__":
    main()
