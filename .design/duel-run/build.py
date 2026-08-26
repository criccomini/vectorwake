#!/usr/bin/env python3
"""Assemble the artboards for the duel's run panel.

The shipped panel heads a duel's fight list with "RUNG 6  FLOOR 6" and gives
every row under it a rung number. Chris's reading: the rung and floor words are
weird, track streaks instead, name the rivals, say who won, and cap the list at
about five. He picked A off the first pass, cut the MVP mark (in a first-to-one
duel the winner is always the best gun, so the mark is the bar said again), and
sent the streak reading back: it sat where the roster's column headings sit,
heading columns it had nothing to do with.

So A's list is settled and what is open is where the streak goes. Three
answers, all with the same five rows under them:

  Main      on the list: the panel's own left rule lit over the streak's rows
  Stack     as readings: label over value, the play page's own strip grammar
  Headline  in the sentence: out of the panel and into the line over the bar

Every board draws one evening, at two moments a fight apart. After eleven
fights the run is three deep and climbing, which is where a streak is visible
at all; the twelfth is the moment in Chris's screenshot, where Tessellate takes
the life and the three ends. `Broken` draws the leading answer at the second
moment, `Current` draws the shipped panel there, and the mid-fight board draws
the fight between them. B and C, the two alternatives A was picked over, keep
their own page as they were proposed.

Drawings of a proposal, not a plan of record. The design system is the
client's, lifted from ../podium-rethink/build.py: hues from
client/arena/palette.lua, panel and key geometry from client/arena/ui.lua, the
two faces from client/ui/, and the rival order computed off pilots::CALIBRATED
so the names in the run are the ones a real evening deals.

Rebuild with: python3 build.py
"""

import json
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


def recent_at(fought):
    """The list as it stood after `fought` fights, newest first."""
    return [leg(n) for n in range(fought - 1, -1, -1)]


# Two moments one fight apart, so every board draws the same evening.
#
# After eleven fights the run is three deep and climbing, which is the state
# that shows a streak at all. The twelfth is the one in Chris's screenshot:
# Tessellate takes the life and the three ends. An answer drawn only at the
# second moment hides the thing the answer is for, and one drawn only at the
# first hides how it behaves when the run breaks, so the boards do both.
CLIMBING, BROKEN = 11, 12


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


def panel(inner, pad_top, pad_bottom, s, lit=None):
    """A panel: the wash, the left rule, and the short skirt off it.

    `lit` is (top, height) in the panel's own points, and lights that stretch
    of the left rule in the friendly color. It is how the run panel draws a
    streak: the rule it already has, brightened over the rows the streak is."""
    skirt = (f"linear-gradient(90deg,rgba(63,88,120,.07),"
             f"rgba(63,88,120,0) {26 * s:.0f}px)")
    spine = ""
    if lit:
        top, high = lit
        spine = (f'<div style="position:absolute;left:0;top:{top:.0f}px;'
                 f'height:{high:.0f}px;width:{1.4 * s:.1f}px;'
                 f'background:rgba(79,214,255,.9)"></div>')
    return (f'<div style="position:relative;background:{PANEL_BG};'
            f'padding:{pad_top:.0f}px 0 {pad_bottom:.0f}px">'
            f'<div style="position:absolute;inset:0;background:{skirt};'
            f'pointer-events:none"></div>'
            f'<div style="position:absolute;left:0;top:0;bottom:0;'
            f'width:{1.4 * s:.1f}px;background:rgba(63,88,120,.7)"></div>'
            f'{spine}<div style="position:relative">{inner}</div></div>')


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


def roster(s, won_the_life, rival=None, ending=True, mvp=False):
    """The pilot list. Two rows in a duel, and the ending swaps the bounty
    column for points under the rivet mark, which is what ui.lua does either
    side of the whistle.

    `mvp` is off on every board but the shipped one. In a first-to-one duel
    the winner is the only pilot with a kill, so the best gun in the room is
    whoever just won, and a prize saying so is the bar above it said twice."""
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
        rows = (row(ME, True, 1, 0, 0, 3, 2, FRIEND, True, mvp)
                + row(rival, False, 0, 1, 0, 0, 1, ENEMY, False, False))
    else:
        rows = (row(rival, False, 1, 0, 0, 3, 2, ENEMY, False, mvp)
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


# ---- Where the streak goes, now that A's list is settled. Three answers, and
# none of them a column heading over columns it does not head. ----

def foot_count(s, legs):
    """How much longer the evening is than the five rows. A footnote under the
    list rather than a figure at its head: it is about the list, and the head
    is where this interface puts the words that name columns."""
    return (f'<div class="row" style="justify-content:flex-end;'
            f'padding:{4 * s:.0f}px {12 * s:.0f}px 0">'
            f'<span class="num" style="font-size:{9 * s:.1f}px;color:{DIM};'
            f'opacity:.7">{legs} fights this run</span></div>')


def streak_words(s, streak, broken, px=None):
    """The run's state as a phrase: a figure in mono, the rest in the label
    register. Two states, so a broken streak still says the size of what
    broke rather than going quiet the way the shipped head does at zero."""
    px = px or 11 * s
    if streak > 0:
        return (f'<span class="row" style="gap:{6 * s:.0f}px">'
                f'<span class="num" style="font-size:{px:.1f}px;color:{FRIEND}">'
                f'{streak}</span>{lbl("in a row", s, px=px / s * 0.9)}</span>')
    return (f'<span class="row" style="gap:{6 * s:.0f}px">'
            f'{lbl("broken after", s, px=px / s * 0.9)}'
            f'<span class="num" style="font-size:{px:.1f}px;color:{ENEMY}">'
            f'{broken}</span></span>')


def run_spine(s, streak, broken, shown=SHOWN, legs=LEGS):
    """The streak on the list. A phrase at the top saying where the run
    stands, and the panel's own left rule lit over the rows that are the
    streak, so the number is drawn against what it counts."""
    line = 18 * s
    pad_top = 14 * s
    cap = (f'<div class="row" style="height:{line:.0f}px;'
           f'padding:0 {12 * s:.0f}px">{streak_words(s, streak, broken)}</div>')
    rows = "".join(run_row(n, w, c, s) for n, w, c, _ in RECENT[:shown])
    inner = f'{cap}{rows}{foot_count(s, legs)}'
    lit = None
    if streak > 0:
        lit = (pad_top, (1 + min(streak, shown)) * line)
    return panel(inner, pad_top, 8 * s, s, lit)


def run_stack(s, streak, best, shown=SHOWN, legs=LEGS):
    """The streak as readings. Label over value with a rule between the
    stacks, which is how the play page sets a zone's format and how the band
    sets TIME and PLAYERS. A different shape from a column heading, so it
    cannot be read as one."""
    def stack(label, value, col=None, first=False):
        rule = ("" if first else
                f'<div style="width:{1.0 * s:.1f}px;height:{22 * s:.0f}px;'
                f'background:rgba(63,88,120,.45)"></div>')
        return (f'{rule}<div class="col" style="gap:{3 * s:.0f}px">'
                f'{lbl(label, s)}'
                f'<span class="num" style="font-size:{13 * s:.1f}px;'
                f'color:{col or INK};opacity:.9">{value}</span></div>')

    strip = (f'<div class="row" style="gap:{15 * s:.0f}px;'
             f'padding:0 {12 * s:.0f}px">'
             f'{stack("streak", streak, FRIEND if streak else DIM, True)}'
             f'{stack("best", best)}{stack("fights", legs)}</div>')
    rows = "".join(run_row(n, w, c, s) for n, w, c, _ in RECENT[:shown])
    inner = (f'{strip}<div style="height:{12 * s:.0f}px"></div>{rows}')
    return panel(inner, 14 * s, 8 * s, s)


def run_bare(s, shown=SHOWN, legs=LEGS):
    """The panel with the streak taken out of it: five fights and a count.
    For the board that puts the streak in the sentence over the bar."""
    rows = "".join(run_row(n, w, c, s) for n, w, c, _ in RECENT[:shown])
    return panel(f'{rows}{foot_count(s, legs)}', 10 * s, 8 * s, s)


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

def result_line(s, said, said_col, verb, under=None):
    """The sentence over the bar. `under` is the second line the Headline
    board hangs off it, which is where that board puts the streak."""
    px = 20 * s
    if verb:
        line = (f'<div class="row" style="gap:{px * 0.42:.0f}px;'
                f'justify-content:center">'
                f'<span style="font-size:{px:.0f}px;color:{said_col}">{said}'
                f'</span><span style="font-size:{px:.0f}px;color:{INK};'
                f'opacity:.9">{verb}</span></div>')
    else:
        line = (f'<div style="text-align:center;font-size:{px:.0f}px;'
                f'color:{said_col}">{said}</div>')
    if not under:
        return line
    words, col = under
    return (f'<div class="col" style="gap:{5 * s:.0f}px">{line}'
            f'<div style="text-align:center;font-family:var(--mono);'
            f'font-size:{11 * s:.1f}px;text-transform:uppercase;'
            f'letter-spacing:.14em;color:{col};opacity:.9">{words}</div>'
            f'</div>')


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


def desktop(name, run_panel, said, said_col, verb, seed, bar=None, mvp=False,
            under=None, flip=False):
    """One ending. `flip` is a board where the viewer took the life, so the
    winning side on the bar is theirs and the roster leads with their row."""
    s = Z
    gap = 14 * s
    # The shipped bar carries the zone's side names; the directions put the two
    # call signs there instead, which is the change note-elsewhere is about.
    left, right = bar or (RIVAL_NAME, ME)
    lcol, rcol = (FRIEND, ENEMY) if flip else (ENEMY, FRIEND)
    block = (f'<div class="col" style="width:{BLOCK:.0f}px;gap:{gap:.0f}px">'
             f'{result_line(s, said, said_col, verb, under)}'
             f'{band(s, left, 1, right, 0, lcol, rcol)}'
             f'{roster(s, flip, rival=(right if flip else left), mvp=mvp)}'
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
    global RECENT
    keep = RECENT

    # The shipped panel, at the moment in the screenshot.
    RECENT = recent_at(BROKEN)
    desktop("Current.dc.html", run_shipped(Z, BROKEN),
            "back to rung 6", ENEMY, None, 7, bar=("Rival", "Pilot"), mvp=True)
    # And the two alternatives it was first proposed against, kept on their
    # own page as they were drawn.
    desktop("B.dc.html", run_b(Z, 0), RIVAL_NAME, ENEMY, "takes it", 7,
            mvp=True)
    desktop("C.dc.html", run_c(Z, 0), RIVAL_NAME, ENEMY, "takes it", 7,
            mvp=True)
    # A at the same moment, to show what the answer does once a run breaks.
    desktop("Broken.dc.html", run_spine(Z, 0, 3, legs=BROKEN),
            RIVAL_NAME, ENEMY, "takes it", 7)

    # A one fight earlier, three deep and climbing: the three answers to where
    # the streak goes, each drawn where its own reading is visible.
    RECENT = recent_at(CLIMBING)
    won = ("Vantage 0001", FRIEND, "beaten")
    bar = (ME, "Vantage 0001")
    desktop("Main.dc.html", run_spine(Z, 3, 3, legs=CLIMBING),
            *won, 7, bar=bar, flip=True)
    desktop("Stack.dc.html", run_stack(Z, 3, 3, legs=CLIMBING),
            *won, 7, bar=bar, flip=True)
    desktop("Headline.dc.html", run_bare(Z, legs=CLIMBING),
            *won, 7, bar=bar, flip=True, under=("3 in a row", FRIEND))
    RECENT = keep


def build_portrait():
    """A at the ending on an upright phone, on the other moment: a win, four
    in a row, and the block hugging the foot so the one key is under a thumb."""
    w, h = 390, 844
    s = Z
    gap = 10 * s
    inner = 390 - 2 * 14 * s
    global RECENT
    keep = RECENT
    RECENT = recent_at(CLIMBING)
    panel_html = run_spine(s, 3, 3, legs=CLIMBING)
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
    # The fight the two boards above show the end of: beating Vantage put this
    # run on rung six, and rung six is Tessellate.
    rival = RIVAL_NAME
    global RECENT
    keep = RECENT
    RECENT = recent_at(CLIMBING)
    panel_html = run_spine(s, 3, 3, legs=CLIMBING)
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


CANVAS = {
    "pages": [
        {"id": "page-1", "name": "A, and where the streak goes"},
        {"id": "page-2", "name": "First directions"},
    ],
    "artboards": [
        {"file": "Current.dc.html", "title": "As shipped", "x": 0, "y": 0, "w": 1440, "h": 900, "page": "page-1"},
        {"file": "Main.dc.html", "title": "On the list", "x": 1560, "y": 0, "w": 1440, "h": 900, "page": "page-1"},
        {"file": "Stack.dc.html", "title": "As readings", "x": 3120, "y": 0, "w": 1440, "h": 900, "page": "page-1"},
        {"file": "Headline.dc.html", "title": "In the sentence", "x": 4680, "y": 0, "w": 1440, "h": 900, "page": "page-1"},
        {"file": "Broken.dc.html", "title": "On the list \u00b7 the run breaks", "x": 1560, "y": 1180, "w": 1440, "h": 900, "page": "page-1"},
        {"file": "Live.dc.html", "title": "Mid-fight, 340 wide", "x": 3120, "y": 1180, "w": 420, "h": 300, "page": "page-1"},
        {"file": "Portrait.dc.html", "title": "Phone", "x": 3660, "y": 1180, "w": 390, "h": 844, "page": "page-1"},
        {"file": "B.dc.html", "title": "B \u00b7 the shape leads", "x": 0, "y": 0, "w": 1440, "h": 900, "page": "page-2"},
        {"file": "C.dc.html", "title": "C \u00b7 the number leads", "x": 1560, "y": 0, "w": 1440, "h": 900, "page": "page-2"},
    ],
    "annotations": [
        {"id": 'note-shipped', "x": 0, "y": -300, "w": 620, "page": 'page-1',
         "text": "As shipped, at the moment in Chris's screenshot. Twelve fights in, Tessellate 0001 has just taken the life.\n\nThe head is RUNG 6  FLOOR 6 and every row under it is a rung number. Neither word is ever defined on screen: a floor is the checkpoint the mode will not let a loss push you below, and a rung is a roster slot. The rung is said a third time in the line over the bar. The rival is nowhere in the run, even though the run is a list of fights against people. The middle column is 1-0 or 0-1 on every row, because a duel is first to one, so all it ever says is that somebody died.\n\nThe MVP mark goes with them. In a first-to-one duel the winner is the only pilot with a kill, so the best gun in the room is always whoever just won and the mark is the bar above it said again. The rule that keeps it honest elsewhere: no mark unless three or more pilots scored."},
        {"id": 'note-a', "x": 1560, "y": -440, "w": 1040, "page": 'page-1',
         "text": "A, settled\n\nThe rung, the floor, the scoreline and the MVP mark are gone. Each row names the rival and says won or lost in that word's own color, and the list is the last five with a count of how much longer the evening was.\n\nWhat is still open is the streak. On the first pass it sat where PILOTS and K D A sit in the panel above: same place, same size, same ticked rule, heading columns it had nothing to do with. Three answers below, all with A's list under them. In two of the three the fights count moves to a footnote under the list, since it is about the list rather than a column of it."},
        {"id": 'note-spine', "x": 1560, "y": -200, "w": 620, "page": 'page-1',
         "text": "On the list\n\nThe panel already has a left rule. The streak lights the stretch of it that is the streak, and one phrase at the top says how long: 4 IN A ROW while it is running, BROKEN AFTER 3 once it is not. The number is drawn against the rows it counts, so it cannot be read as a heading for them.\n\nBoth states always draw, which is what the shipped head does not do. It hides the streak at zero, so the one number this is about goes missing exactly on the screen you read after losing.\n\nCost: a lit rule with a wash off it is how this interface marks a selected row. This is a lit rule without the wash, on the panel's edge rather than inside it, spanning several rows. Close enough to want checking on a real screen."},
        {"id": 'note-stack', "x": 3120, "y": -180, "w": 620, "page": 'page-1',
         "text": "As readings\n\nLabel over value with a thin rule between the stacks: the grammar the play page sets a zone's format in, and the band sets TIME and PLAYERS in. Instruments rather than headings, and the shape says so before the words do.\n\nIt is the only one of the three with room for BEST without it feeling bolted on, and the fights count belongs in the row rather than at the foot.\n\nCost: it is still a band above the list, so of the three it changes the least about what was wrong. And three readings is two more than the question asked for. BEST is my addition, not Chris's."},
        {"id": 'note-headline', "x": 4680, "y": -180, "w": 620, "page": 'page-1',
         "text": 'In the sentence\n\nThe streak leaves the panel. It joins the line over the bar, which is already the sentence about what just happened, and what just happened to a run is a streak event. The panel becomes what it says it is: five fights and a count.\n\nCleanest panel of the three, and the streak is read at the size the result is read at.\n\nCost: there is no sentence mid-fight. The band would have to carry the streak while you are flying, which is a second place to put it and a second thing to design. See the mid-fight board.'},
        {"id": 'note-live', "x": 4120, "y": 1180, "w": 620, "page": 'page-1',
         "text": 'Mid-fight, where the panel is asked for rather than raised at the whistle: no zoom, no head, no foot, and the board at its 340 point measure under the band.\n\nThis is where the sentence answer costs something. There is no result line here, so the streak would have to ride the band beside the clock or not show at all while you are flying. The other two draw the same either side of the whistle.'},
        {"id": 'note-wire', "x": 4820, "y": 1180, "w": 620, "page": 'page-1',
         "text": "What this costs to build\n\nThe leg the room files carries a rung, a result, a scoreline and a duration, and no name (modes::LadderLeg). The rival's call sign has to be captured when the leg is filed, since by the time the panel draws it the rival may have left the room. That is one field on the leg, the name reaching the mode through ModeCtx, and eleven bytes a leg on S2C_MATCH becoming eleven plus the name. Sending five legs rather than twelve nearly pays for it.\n\nThe scoreline drops off the wire with the column. The streak is already there; a best streak would be a max over it.\n\nThe word is not only in this panel. END.result says rung 6 cleared and back to rung 6 over the bar; the play page's format strip says scoring: rungs; the zone's hook line is every rung is a harder rival, a loss drops you two; and two Ladder::banner lines name a rung and a checkpoint."},
        {"id": 'note-open', "x": 5520, "y": 1180, "w": 620, "page": 'page-1',
         "text": 'The one question these boards do not answer\n\nThe floor is real whether or not it is named. A loss drops two rungs and cannot push you below the last checkpoint, so after twelve fights this run cannot fall below Tessellate however badly it goes. Take the word off the screen and the kindness is still there, unread.\n\nEither keep the mechanic and stop narrating it, which changes nothing on the server, or make the streak the mechanic: a win puts you against a harder rival, a loss puts you back at the start, and there is no floor to explain because there is not one. That is what "just track streaks" says most plainly, and it is a harsher game. The twelfth fight on these boards would have sent this run back to Kestrel.\n\nThe panel draws the same either way.'},
        {"id": 'note-first', "x": -460, "y": 0, "w": 400, "page": 'page-2',
         "text": 'The first two alternatives, kept for the record. Chris picked A over both. They still carry the MVP mark and the streak in the heading slot, since they are drawn as they were proposed.\n\nB put the whole run in the head as one mark per fight, filled for a win and hollow for a loss. C dropped the head entirely and stood the streak as a figure in a column beside the rows.'},
    ],
    "launch": {"view": "canvas", "page": "page-1"},
}



def main():
    build_desktops()
    build_portrait()
    build_live()
    (HERE / "canvas.json").write_text(
        json.dumps(CANVAS, indent=2, ensure_ascii=False) + "\n")
    print("wrote", len(list(HERE.glob("*.dc.html"))), "artboards")


if __name__ == "__main__":
    main()
