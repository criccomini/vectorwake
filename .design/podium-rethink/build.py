#!/usr/bin/env python3
"""Assemble the twelve .dc.html artboards for the match ending rethink.

The shipped ending is one measure holding a title, a score bar, both rosters,
the SAY chips, the next-match clock and a share key. Chris's reading of it:
small and busy on a monitor, no sense of how *you* did, and most of it is the
scoreboard's own content a second time, with the SAY row about to be a
keyboard shortcut anyway.

Four directions, by what leads:

  A  your match leads: the result is a line, your own figures are the page
  B  the result leads, with your row pulled out of the roster at full size
  C  what the match paid leads, since bounty is the economy this game runs on
  D  a title card: the result and the countdown, and nothing the board behind
     the band already carries

Three window shapes each. The match is the one in Chris's screenshot, so the
boards compare against something real: Caisson takes it 20 to 17, and the
viewer is DRiFT, who went nought and one with six assists. A losing side and a
quiet game is the honest case for "how did I do".

Drawings of a proposal, not a plan of record. The design system is the
client's, lifted from ../scoreboard/build.py: hues from
client/arena/palette.lua, panel and key geometry from client/arena/ui.lua, the
seat marks and the rivet from the same, and the two faces the client carries.

Rebuild with: python3 build.py
"""

import random
from pathlib import Path

HERE = Path(__file__).parent

FORMS = {
    "Desktop":   (1440, 810, False),
    "Landscape": (844, 390, True),
    "Portrait":  (390, 844, True),
}
VARIANTS = ["A", "B", "C", "D"]

FRIEND, ENEMY = "#4fd6ff", "#ffa552"
BOUNTY = "#ffe08a"

# The match from the screenshot. name, human?, k, d, a, paid.
PYLON = [
    ("Gantry",     True,  8, 4, 4, 214),
    ("Bellwether", False, 6, 3, 5, 168),
    ("Ozone",      False, 3, 7, 3, 96),
    ("DRiFT",      True,  0, 1, 6, 112),
]
CAISSON = [
    ("Carrack",  True,  6, 5, 3, 191),
    ("Isobar",   False, 5, 5, 3, 155),
    ("Cirrus",   False, 5, 6, 7, 173),
    ("Jackstay", False, 4, 4, 8, 149),
]
ME = PYLON[3]
SCORE_L, SCORE_R = 17, 20


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


CSS = """
:root{
  --bg:#05070c; --ink:#dfe9f5; --dim:#6c7a90;
  --friend:#4fd6ff; --enemy:#ffa552;
  --rule:#3f5878; --prize:#8dffb0; --bounty:#ffe08a;
  --mono:"DejaVu Sans Mono","Noto Sans Mono",ui-monospace,monospace;
  --menu:"Chakra Petch","Segoe UI",system-ui,sans-serif;
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font-family:var(--menu)}
a{color:var(--friend)}a:hover{color:#8ee6ff}
.hud{font-family:var(--mono);text-transform:uppercase;letter-spacing:.04em}
.num{font-family:var(--mono);font-variant-numeric:tabular-nums}
.lbl{font-family:var(--mono);font-size:10px;text-transform:uppercase;
  letter-spacing:.14em;color:var(--dim)}
.dim{color:var(--dim)}
.row{display:flex;align-items:center}
.key{display:flex;align-items:center;justify-content:center;gap:8px;
  border:1px solid rgba(63,88,120,.75);background:rgba(10,15,24,.6);
  font-family:var(--mono);text-transform:uppercase;letter-spacing:.06em;
  color:#9fb6d4}
.wash{background:linear-gradient(90deg,rgba(79,214,255,.16),
  rgba(79,214,255,0) 72%)}
"""


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


def rivet(col=BOUNTY, k=11):
    return (f'<svg width="{k:.0f}" height="{k:.0f}" viewBox="0 0 12 12" '
            f'fill="none" style="flex:none">'
            f'<circle cx="6" cy="6" r="4.4" stroke="{col}" stroke-width="1.1"/>'
            f'<circle cx="6" cy="6" r="1.7" fill="{col}"/>'
            f'<path d="M6 1.6 V3" stroke="{col}" stroke-width="1"/>'
            f'<path d="M6 9 V10.4" stroke="{col}" stroke-width="1"/></svg>')


def share_mark(col="#9fb6d4", k=12):
    return (f'<svg width="{k}" height="{k}" viewBox="0 0 16 16" fill="none" '
            f'style="flex:none"><path d="M8 2 V10 M5 5 L8 2 L11 5" '
            f'stroke="{col}" stroke-width="1.3"/>'
            f'<path d="M4 8 H3 V14 H13 V8 H12" stroke="{col}" '
            f'stroke-width="1.3"/></svg>')


def hrule(alpha=".55"):
    return f'<div style="height:1px;background:rgba(63,88,120,{alpha})"></div>'


def section(name, px=10):
    return (f'<div><div class="lbl" style="font-size:{px}px;'
            f'margin-bottom:7px">{name}</div>{hrule()}</div>')


def score_bar(h=8, w=None):
    total = SCORE_L + SCORE_R
    share = SCORE_L / total * 100
    width = f"width:{w}px;" if w else "flex:1;"
    return (f'<div style="{width}height:{h}px;display:flex;overflow:hidden">'
            f'<div style="width:{share:.1f}%;background:var(--friend)"></div>'
            f'<div style="flex:1;background:var(--enemy)"></div></div>')


def result_line(px):
    return (f'<div class="row" style="gap:10px;justify-content:center">'
            f'<span class="hud" style="font-size:{px}px;color:var(--enemy);'
            f'letter-spacing:.06em">Caisson</span>'
            f'<span class="hud" style="font-size:{px}px;color:var(--ink);'
            f'letter-spacing:.06em">takes it</span></div>')


def scoreline(big, mid_w=None, bar_h=8):
    return (f'<div class="row" style="gap:20px;justify-content:center">'
            f'<span class="num" style="font-size:{big}px;color:var(--friend);'
            f'line-height:1">{SCORE_L}</span>'
            f'{score_bar(bar_h, mid_w)}'
            f'<span class="num" style="font-size:{big}px;color:var(--enemy);'
            f'line-height:1">{SCORE_R}</span></div>')


def roster_row(p, col, px, mark_px, washed=False, paid=True, mvp=False):
    name, human, k, d, a, pay = p
    mark = helm(col, mark_px) if human else bot(col, mark_px)
    cells = "".join(
        f'<span class="num" style="width:{px * 2.2:.0f}px;text-align:right;'
        f'font-size:{px}px;{"opacity:.55" if lab in ("d", "a") else ""}">{v}'
        f'</span>'
        for lab, v in (("k", k), ("d", d), ("a", a)))
    money = ""
    if paid:
        money = (f'<span class="row" style="gap:4px;width:{px * 4.6:.0f}px;'
                 f'justify-content:flex-end">{rivet(BOUNTY, px)}'
                 f'<span class="num" style="font-size:{px}px;'
                 f'color:var(--bounty)">{pay}</span></span>')
    tag = ""
    if mvp:
        tag = (f'<span class="lbl" style="font-size:{px - 2}px;'
               f'color:var(--prize);margin-left:6px">MVP</span>')
    return (f'<div class="row{" wash" if washed else ""}" '
            f'style="gap:8px;padding:2px 4px">'
            f'<span class="num" style="font-size:{px}px;color:{col}">{name}'
            f'</span>{mark}{tag}<div style="flex:1"></div>{cells}{money}</div>')


# How wide the list of everyone is allowed to be. A name at one edge of a
# thousand points and its three figures at the other is two readings, and the
# eye has to carry the row across the gap between them. Narrower than the
# measure the rest of the ending uses, and centered in it.
ROOM_W = 560


def room_list(head, rows, px, compact, wide_form):
    """Everyone in the room, one line each. On a sideways phone this is the
    right hand half of the page rather than a band under it."""
    body = f'''
    <div style="display:flex;flex-direction:column;gap:2px;
         width:{"100%" if compact else str(ROOM_W) + "px"};
         margin:0 auto">
      {col_heads(px)}
      {"".join(rows)}
    </div>'''
    return f'''
    <div style="display:flex;flex-direction:column;gap:8px">
      {section(head, 10 if not compact else 9)}{body}
    </div>'''


def col_heads(px, paid=True):
    cells = "".join(
        f'<span class="lbl" style="width:{px * 2.2:.0f}px;text-align:right;'
        f'font-size:{px - 2}px">{lab}</span>' for lab in ("k", "d", "a"))
    money = (f'<span class="lbl" style="width:{px * 4.6:.0f}px;'
             f'text-align:right;font-size:{px - 2}px">paid</span>'
             if paid else "")
    return (f'<div class="row" style="gap:8px;padding:0 4px">'
            f'<div style="flex:1"></div>{cells}{money}</div>')


def next_match(px, key_h, label=True, inline=False):
    """The clock the room is counting down on, and the one thing you can do
    with the match that just happened. A phone held sideways has no row to
    spare, so there the key rides the clock's own line instead of standing
    under it."""
    head = section("Next match", px) if label else ""
    key = (f'<div class="key" style="height:{key_h}px;'
           f'{"padding:0 14px" if inline else "margin-top:10px"};'
           f'font-size:{px + 1}px">{share_mark()}Share match</div>')
    return f"""
    <div>{head}
      <div class="row" style="gap:16px;margin-top:8px">
        <span class="num" style="font-size:{px * 2.4:.0f}px">0:15</span>
        <div style="flex:1;height:4px;background:rgba(63,88,120,.35)">
          <div style="width:38%;height:100%;background:var(--bounty);
               opacity:.85"></div></div>
        {key if inline else ""}
      </div>{"" if inline else key}
    </div>"""


def say_hint(px):
    """The chips are a keyboard shortcut in the making, so the ending says
    where they live rather than spending six keys on them."""
    return (f'<div class="row" style="gap:8px;justify-content:center">'
            f'<span class="lbl" style="font-size:{px}px">say</span>'
            f'<span class="key" style="padding:1px 8px;font-size:{px}px;'
            f'color:var(--ink)">T</span>'
            f'<span class="lbl" style="font-size:{px}px">gg &middot; nice shot '
            f'&middot; close one</span></div>')


def my_figures(size, gap_px, with_paid=True):
    def fig(n, label, col=None, mark=False):
        head = (f'<div class="row" style="gap:6px;justify-content:center">'
                f'{rivet(BOUNTY, size * 0.42) if mark else ""}'
                f'<span class="num" style="font-size:{size}px;line-height:1;'
                f'color:{col or "var(--ink)"}">{n}</span></div>')
        return (f'<div style="display:flex;flex-direction:column;gap:6px;'
                f'align-items:center">{head}'
                f'<span class="lbl" style="font-size:{max(9, size * 0.2):.0f}px">'
                f'{label}</span></div>')

    _, _, k, d, a, pay = ME
    cells = [fig(k, "kills"), fig(d, "deaths"), fig(a, "assists")]
    if with_paid:
        cells.append(fig(pay, "rivets", "var(--bounty)", mark=True))
    return (f'<div class="row" style="gap:{gap_px}px;justify-content:center">'
            + "".join(cells) + "</div>")


def my_name_line(px):
    tail = (f'<span class="lbl" style="font-size:{max(9, px * 0.5):.0f}px">'
            f'4th of 8 &middot; best run 2</span>')
    return (f'<div class="row" style="gap:12px;justify-content:center">'
            f'<span class="num" style="font-size:{px}px;color:var(--friend)">'
            f'{ME[0]}</span>{helm(FRIEND, px * 0.7)}{tail}</div>')


def board_a(form):
    w, h, compact = FORMS[form]
    portrait = form == "Portrait"
    fig = 88 if not compact else (52 if portrait else 34)
    name_px = 26 if not compact else 16
    row_px = 12 if not compact else 10
    gap = 56 if not compact else (22 if portrait else 30)

    head = f"""
    <div style="display:flex;flex-direction:column;gap:10px;
         align-items:center">
      {result_line(19 if not compact else 14)}
      <div class="row" style="gap:14px">
        <span class="num" style="font-size:{22 if not compact else 15}px;
              color:var(--friend)">{SCORE_L}</span>
        {score_bar(5, 220 if not compact else 130)}
        <span class="num" style="font-size:{22 if not compact else 15}px;
              color:var(--enemy)">{SCORE_R}</span>
      </div>
    </div>"""

    mine = f"""
    <div style="display:flex;flex-direction:column;
         gap:{18 if not compact else 10}px;align-items:center">
      {my_name_line(name_px)}
      {my_figures(fig, gap)}
    </div>"""

    rows = [roster_row(p, FRIEND, row_px, row_px, washed=(p is ME),
                       mvp=(p is PYLON[0])) for p in PYLON]
    rows += [roster_row(p, ENEMY, row_px, row_px) for p in CAISSON]
    room = room_list("Everyone here", rows, row_px, compact,
                     form == "Landscape")
    return [head, mine, room, "SAY", "NEXT"]


def board_b(form):
    w, h, compact = FORMS[form]
    big = 84 if not compact else 46
    row_px = 12 if not compact else 10

    head = f"""
    <div style="display:flex;flex-direction:column;
         gap:{14 if not compact else 8}px">
      {result_line(26 if not compact else 16)}
      {scoreline(big, None, 10 if not compact else 7)}
    </div>"""

    _, _, k, d, a, pay = ME
    cells = "".join(
        f'<div style="display:flex;flex-direction:column;align-items:center;'
        f'gap:4px"><span class="num" style="font-size:'
        f'{30 if not compact else 19}px;line-height:1;color:{col}">{v}</span>'
        f'<span class="lbl" style="font-size:9px">{lab}</span></div>'
        for lab, v, col in (("kills", k, "var(--ink)"),
                            ("deaths", d, "var(--ink)"),
                            ("assists", a, "var(--ink)"),
                            ("rivets", pay, "var(--bounty)")))
    mine = f"""
    <div>
      {section("Your match", 10 if not compact else 9)}
      <div class="row wash" style="gap:18px;padding:10px 12px;margin-top:8px;
           border-left:2px solid var(--friend)">
        <span class="num" style="font-size:{22 if not compact else 14}px;
              color:var(--friend)">{ME[0]}</span>
        {helm(FRIEND, 14 if not compact else 11)}
        <div style="flex:1"></div>
        <div class="row" style="gap:{34 if not compact else 18}px">{cells}</div>
      </div>
    </div>"""

    lists = []
    for team, col, pilots in (("Pylon", FRIEND, PYLON),
                              ("Caisson", ENEMY, CAISSON)):
        rows = "".join(roster_row(p, col, row_px, row_px, paid=False,
                                  mvp=(p is PYLON[0]))
                       for p in pilots if p is not ME)
        lists.append(f"""
        <div style="flex:1;display:flex;flex-direction:column;gap:2px">
          <div class="row" style="gap:8px;padding:0 4px">
            <span class="hud" style="font-size:{row_px}px;color:{col}">{team}
            </span>{col_heads(row_px, paid=False)}
          </div>
          {rows}
        </div>""")
    room = (f'<div class="row" style="gap:26px;align-items:flex-start">'
            + "".join(lists) + "</div>")
    return [head, mine, room, "SAY", "NEXT"]


def board_c(form):
    w, h, compact = FORMS[form]
    big = 96 if not compact else (58 if form == "Portrait" else 46)
    row_px = 12 if not compact else 10
    lbl = 11 if not compact else 9

    head = f"""
    <div class="row" style="gap:14px;justify-content:center">
      {result_line(17 if not compact else 13)}
      <span class="lbl" style="font-size:{lbl}px">{SCORE_L} to {SCORE_R}</span>
    </div>"""

    _, _, k, d, a, pay = ME
    paid = f"""
    <div style="display:flex;flex-direction:column;align-items:center;
         gap:{12 if not compact else 7}px">
      <div class="row" style="gap:14px">
        {rivet(BOUNTY, big * 0.5)}
        <span class="num" style="font-size:{big}px;line-height:1;
              color:var(--bounty)">+{pay}</span>
      </div>
      <span class="lbl" style="font-size:{lbl}px">rivets this match</span>
      <div class="row" style="gap:{20 if not compact else 12}px;margin-top:4px">
        <span class="lbl" style="font-size:{lbl}px">{k} kills</span>
        <span class="lbl" style="font-size:{lbl}px">{a} assists</span>
        <span class="lbl" style="font-size:{lbl}px">{d} deaths</span>
        <span class="lbl" style="font-size:{lbl}px;color:var(--bounty)">
          wallet 1,284</span>
      </div>
    </div>"""

    rows = [roster_row(p, FRIEND, row_px, row_px, washed=(p is ME),
                       mvp=(p is PYLON[0])) for p in PYLON]
    rows += [roster_row(p, ENEMY, row_px, row_px) for p in CAISSON]
    room = room_list("What everyone earned", rows, row_px, compact,
                     form == "Landscape")
    return [head, paid, room, "SAY", "NEXT"]


def board_d(form):
    w, h, compact = FORMS[form]
    big = 150 if not compact else (84 if form == "Portrait" else 66)
    title = 40 if not compact else 22

    head = f"""
    <div style="display:flex;flex-direction:column;
         gap:{20 if not compact else 12}px">
      {result_line(title)}
      {scoreline(big, None, 12 if not compact else 8)}
    </div>"""

    _, _, k, d, a, pay = ME
    px = 15 if not compact else 11
    mine = f"""
    <div class="row" style="gap:14px;justify-content:center;
         padding:{10 if not compact else 6}px 0;flex-wrap:wrap">
      <span class="num" style="font-size:{px}px;color:var(--friend)">{ME[0]}
      </span>{helm(FRIEND, px)}
      <span class="num dim" style="font-size:{px}px">{k}-{d}-{a}</span>
      <span class="row" style="gap:5px">{rivet(BOUNTY, px)}
        <span class="num" style="font-size:{px}px;color:var(--bounty)">+{pay}
        </span></span>
      <span class="lbl" style="font-size:{max(9, px - 3)}px">press the clock
        for the board</span>
    </div>"""
    return [head, mine, None, "SAY", "NEXT"]


BUILDERS = {"A": board_a, "B": board_b, "C": board_c, "D": board_d}


def screen(variant, form):
    w, h, compact = FORMS[form]
    parts = BUILDERS[variant](form)
    measure = min(w - 36, 1040) if not compact else w - 28
    px = 11 if not compact else 9
    key_h = 30 if not compact else 24

    blocks = []
    for p in parts:
        if p is None:
            continue
        if p == "SAY":
            blocks.append(say_hint(px))
        elif p == "NEXT":
            blocks.append(next_match(
                px, key_h,
                label=(variant != "D" and form != "Landscape"),
                inline=(form == "Landscape")))
        else:
            blocks.append(p)

    gap = 26 if not compact else (14 if form == "Portrait" else 8)
    if form == "Landscape" and len(blocks) > 4:
        # A phone held sideways is 390 points tall and the ending is a stack,
        # so the stack runs off the bottom of it. The two halves of the page
        # go abreast instead: what the match was and what you did on the left,
        # everyone else on the right, and the countdown across the foot. It is
        # the same reading in the shape the window actually has.
        head, mine, room = blocks[0], blocks[1], blocks[2]
        rest = "".join(blocks[3:])
        # Anchored near the top rather than centered: a page that fills most
        # of a 390-point window has no slack for centering to round away, and
        # what rounds off the bottom is the countdown.
        body = (f'<div style="position:absolute;left:50%;top:22px;'
                f'transform:translateX(-50%);width:{measure}px;'
                f'display:flex;flex-direction:column;gap:{gap}px">'
                f'<div class="row" style="gap:24px;align-items:flex-start">'
                f'<div style="flex:1;display:flex;flex-direction:column;'
                f'gap:{gap}px">{head}{mine}</div>'
                f'<div style="flex:1">{room}</div></div>{rest}</div>')
    else:
        body = (f'<div style="position:absolute;left:50%;top:50%;'
                f'transform:translate(-50%,-50%);width:{measure}px;'
                f'display:flex;flex-direction:column;gap:{gap}px">'
                + "".join(blocks) + "</div>")

    stars = starfield(w, h, *(dict(Desktop=(46, 30, 12), Landscape=(30, 20, 8),
                                   Portrait=(30, 20, 8))[form]), seed=28)
    return (f'<div style="position:absolute;left:0;top:0;width:{w}px;'
            f'height:{h}px;overflow:hidden;background-color:var(--bg);'
            f'background-image:{stars}">'
            f'<div style="position:absolute;inset:0;'
            f'background:rgba(5,7,12,.55)"></div>{body}</div>')


# --- the ending is the board -------------------------------------------------
#
# The second reading of all this, and Chris's: the match ending does not need
# a page of its own. The board behind the band is already the room's numbers,
# so at the whistle it opens by itself and grows a head and a foot. One
# layout, at every window size: the bar with each side's points on it, the
# line saying who took it, the pilot list with your own row washed, and a foot
# carrying the countdown and one small key.
#
# What went, on Chris's reading of the first four: the clock's drain bar, the
# block of large figures at the top, the six SAY chips, and the share key that
# ran the width of the page.

E_ROWS = {
    "Merged": "the room in one list, your side first",
    "Split": "a block per side, each with its own points",
    "Ranked": "one list, best gun at the top",
}


def bar_head(px, bar_h, name_px):
    """The scoreline as a bar with each side's points on the ends of it. The
    proportion is the fight, the numbers are the score, and the two colors are
    the ones every other instrument uses for these sides."""
    total = SCORE_L + SCORE_R
    share = SCORE_L / total * 100
    return f"""
    <div class="row" style="gap:{px}px">
      <span class="hud" style="font-size:{name_px}px;color:var(--friend)">
        Pylon</span>
      <span class="num" style="font-size:{px * 1.9:.0f}px;color:var(--friend);
            line-height:1">{SCORE_L}</span>
      <div style="flex:1;height:{bar_h}px;display:flex;overflow:hidden">
        <div style="width:{share:.1f}%;background:var(--friend)"></div>
        <div style="flex:1;background:var(--enemy)"></div>
      </div>
      <span class="num" style="font-size:{px * 1.9:.0f}px;color:var(--enemy);
            line-height:1">{SCORE_R}</span>
      <span class="hud" style="font-size:{name_px}px;color:var(--enemy)">
        Caisson</span>
    </div>"""


def took_it(px):
    return (f'<div class="row" style="gap:8px;justify-content:center">'
            f'<span class="hud" style="font-size:{px}px;color:var(--enemy)">'
            f'Caisson</span>'
            f'<span class="hud" style="font-size:{px}px">takes it</span></div>')


def board_foot(px, key_h):
    """The countdown as a reading rather than a draining bar, and one key
    beside it. INVITE FRIEND rather than SHARE MATCH: the same act, named for
    what a player wants out of it, and sized like a key rather than a banner."""
    return f"""
    <div class="row" style="gap:14px">
      <span class="lbl" style="font-size:{px}px">Next match</span>
      <span class="num" style="font-size:{px * 1.7:.0f}px">0:15</span>
      <div style="flex:1"></div>
      <div class="key" style="height:{key_h}px;padding:0 14px;
           font-size:{px}px">{share_mark()}Invite friend</div>
    </div>"""


def board_rows(order, px):
    """The pilot list, in whichever order this board is arguing for. Your own
    row is washed and keeps its side's color, exactly as it does in the board
    the band opens mid-match."""
    if order == "Split":
        out = []
        for team, col, pilots, score in (("Pylon", FRIEND, PYLON, SCORE_L),
                                         ("Caisson", ENEMY, CAISSON, SCORE_R)):
            out.append(f'''<div class="row" style="gap:8px;padding:6px 4px 2px">
              <span class="hud" style="font-size:{px}px;color:{col}">{team}
              </span>
              <span class="num" style="font-size:{px}px;color:{col}">{score}
              </span><div style="flex:1"></div></div>''')
            out += [roster_row(p, col, px, px, washed=(p is ME),
                               mvp=(p is PYLON[0])) for p in pilots]
        return out
    if order == "Ranked":
        everyone = [(p, FRIEND) for p in PYLON] + [(p, ENEMY) for p in CAISSON]
        everyone.sort(key=lambda pc: (-pc[0][2], pc[0][3]))
        return [roster_row(p, col, px, px, washed=(p is ME),
                           mvp=(p is PYLON[0])) for p, col in everyone]
    rows = [roster_row(p, FRIEND, px, px, washed=(p is ME),
                       mvp=(p is PYLON[0])) for p in PYLON]
    rows += [roster_row(p, ENEMY, px, px) for p in CAISSON]
    return rows


def board_ending(order, form):
    """One layout, at every size. Only the type and the measure change."""
    w, h, compact = FORMS[form]
    px = 14 if not compact else 11
    name_px = 13 if not compact else 10
    bar_h = 10 if not compact else 7
    key_h = 30 if not compact else 24
    lbl_px = 11 if not compact else 9

    rows = board_rows(order, px)
    return f"""
    <div style="display:flex;flex-direction:column;
         gap:{16 if not compact else 10}px">
      {bar_head(px, bar_h, name_px)}
      {took_it(lbl_px + 3)}
      <div style="display:flex;flex-direction:column;gap:2px">
        {hrule()}
        {col_heads(px)}
        {"".join(rows)}
        {hrule()}
      </div>
      {board_foot(lbl_px, key_h)}
    </div>"""


def screen_board(order, form):
    w, h, compact = FORMS[form]
    # One measure everywhere, capped so a monitor does not stretch eight rows
    # across a thousand points and a phone still spends its whole width.
    measure = min(w - 28, 720 if not compact else w - 28)
    stars = starfield(w, h, *(dict(Desktop=(46, 30, 12), Landscape=(30, 20, 8),
                                   Portrait=(30, 20, 8))[form]), seed=28)
    return (f'''<div style="position:absolute;left:0;top:0;width:{w}px;
            height:{h}px;overflow:hidden;background-color:var(--bg);
            background-image:{stars}">
            <div style="position:absolute;inset:0;background:rgba(5,7,12,.55)">
            </div>
            <div style="position:absolute;left:50%;top:50%;
                 transform:translate(-50%,-50%);width:{measure}px">
              {board_ending(order, form)}
            </div></div>''')


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
    n = 0
    for order in E_ROWS:
        for form in FORMS:
            name = ("Main" if (order, form) == ("Merged", "Desktop")
                    else f"{form}{order}")
            page(name, screen_board(order, form))
            n += 1
    for v in VARIANTS:
        for form in FORMS:
            page(f"{form}{v}", screen(v, form))
            n += 1
    print(f"{n} artboards written")


if __name__ == "__main__":
    main()
