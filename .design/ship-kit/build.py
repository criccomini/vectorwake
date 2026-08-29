#!/usr/bin/env python3
# The ship tuning boards: the thirty point kit back, with nothing to buy.
#
# The proposal in one line: every hull's shipped profile is its default spend
# of thirty points, the roster stays the picker it is today, and one TUNE key
# on the ship you fly opens a stepper page where each slot is a plain sentence
# stepped by the triangles the wake row already taught. One remembered build a
# hull, saved as you step, a RESET row instead of a build manager. Points move
# between weapon and rack slots only; flight stays the hull's own, which is
# the open fork the fourth board sketches the other side of.
#
# Chrome and hues are the drawer's own: 390 wide, ink dfe9f5, dim 6c7a90,
# friend 4fd6ff, the row states of decision 72, the foot rail of decision 80
# with friends gone, link bars in the head beside the call sign. Slot prices
# here are stand-ins that make Apex's default sum to thirty; the real prices
# are the balance work's to set.
import pathlib

OUT = str(pathlib.Path(__file__).resolve().parent)

STYLE = """
:root{
  --ink:#dfe9f5; --dim:#6c7a90; --friend:#4fd6ff; --enemy:#ffa552;
  --read:#9fb6d4; --mute:#8593a9;
  --mono:"DejaVu Sans Mono","Noto Sans Mono",ui-monospace,monospace;
  --menu:"Chakra Petch","Segoe UI",system-ui,sans-serif;
}
*{box-sizing:border-box}
body{margin:0;background:#05070c;color:var(--ink);font-family:var(--menu)}
a{color:var(--friend)}a:hover{color:#8ee6ff}
.lbl{font-family:var(--mono);font-size:9px;text-transform:uppercase;
  letter-spacing:.13em;color:var(--dim)}
.row{display:flex;align-items:center}
.col{display:flex;flex-direction:column}
.key{display:inline-flex;align-items:center;justify-content:center;gap:6px;
  border:1px solid rgba(63,88,120,.75);background:rgba(10,15,24,.6);
  font-family:var(--mono);text-transform:uppercase;letter-spacing:.06em;
  color:#9fb6d4}
.mono{font-family:var(--mono)}
.note{font-family:var(--mono);font-size:10px;color:var(--dim)}
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


# ---- The lit field, decision 72: wash at the drawer span, a skirt against
# the left rule gone by 130. ----
def field(a):
    lo = a * 0.8
    hi = a * 0.8 + a * 0.6
    return (f"background:linear-gradient(90deg,rgba(79,214,255,{hi:.3f}),"
            f"rgba(79,214,255,{lo:.3f}) 130px,rgba(79,214,255,{lo:.3f}));")


CURSOR = field(0.18)
HERE = field(0.07)


def state_bg(state):
    if state == "cursor":
        return CURSOR
    if state == "here":
        return HERE
    return ""


def bleed(content, state=None, pad="0 36px", extra=""):
    return (f'<div style="margin:0 -14px;padding:{pad};'
            + state_bg(state) + extra + '">' + content + '</div>')


# ---- Shared drawer chrome ----
def stars(w, h):
    pts = [
        (0.63, 0.15, 1.3, "#93a9c8"), (0.11, 0.74, 1.3, "#93a9c8"),
        (0.77, 0.04, 1.0, "#4a6089"), (0.22, 0.31, 1.0, "#4a6089"),
        (0.86, 0.84, 1.0, "#4a6089"), (0.50, 0.40, 0.9, "#2a3a58"),
        (0.30, 0.20, 0.9, "#2a3a58"), (0.91, 0.34, 0.9, "#2a3a58"),
        (0.07, 0.53, 0.9, "#2a3a58"), (0.50, 0.89, 0.9, "#2a3a58"),
    ]
    grads = ",\n   ".join(
        f"radial-gradient(circle {r}px at {int(x * w)}px {int(y * h)}px,"
        f"{c} 0 {r}px,transparent {r}px)" for x, y, r, c in pts)
    return ("background-color:#05070c;background-image:\n   " + grads)


def fight(w, h):
    def wall(x, y, ww, hh):
        return (f'<rect x="{x}" y="{y}" width="{ww}" height="{hh}" '
                'fill="#080d16" stroke="#22344f" stroke-width="1"/>'
                f'<path d="M{x} {y} H{x + ww}" stroke="#5b82b8" '
                'stroke-width="1.4" opacity=".55"/>')
    a = ('<g transform="translate(150,330) rotate(36)">'
         '<path d="M-4,10 L-2,44 L2,44 L4,10 Z" fill="#4fd6ff" opacity=".16"/>'
         '<path d="M0,-13 L15,9 L7,12 L0,8 L-7,12 L-15,9 Z" fill="#0b1220" '
         'stroke="#4fd6ff" stroke-width="1.5" stroke-linejoin="round"/></g>')
    b = ('<g transform="translate(300,560) rotate(205)">'
         '<path d="M-4,10 L-2,44 L2,44 L4,10 Z" fill="#ffa552" opacity=".16"/>'
         '<path d="M0,-22 L3,-6 L6,8 L2,12 L-2,12 L-6,8 L-3,-6 Z" '
         'fill="#0b1220" stroke="#ffa552" stroke-width="1.5" '
         'stroke-linejoin="round"/></g>')
    rounds = ('<g stroke="#62cc35" stroke-width="1.6" opacity=".8">'
              '<path d="M170 360 l9 13"/><path d="M196 398 l9 13"/>'
              '<path d="M224 438 l9 13"/></g>')
    return (f'<svg width="{w}" height="{h}" style="position:absolute;inset:0">'
            + wall(288, 196, 26, 104) + wall(60, 610, 128, 26)
            + a + b + rounds + '</svg>')


X_KEY = ('<div class="key" style="width:26px;height:26px;flex:none">'
         '<svg width="11" height="11" viewBox="0 0 12 12">'
         '<path d="M1.5 1.5 L10.5 10.5 M10.5 1.5 L1.5 10.5" stroke="#9fb6d4" '
         'stroke-width="1.4" stroke-linecap="square"/></svg></div>')

LINK_BARS = ('<svg width="16" height="12" viewBox="0 0 16 12" style="flex:none">'
             + "".join(f'<rect x="{i * 4}" y="{9 - i * 3}" width="2.6" '
                       f'height="{3 + i * 3}" fill="#6c7a90" opacity=".8"/>'
                       for i in range(4))
             + '</svg>')

PILL = ('<div class="key" style="height:26px;padding:0 13px;font-size:11px;'
        'color:#9fb6d4;letter-spacing:.02em;text-transform:none">Delta 154'
        '</div>')


def topline():
    return ('<div class="row" style="height:48px;gap:10px;'
            'border-bottom:1px solid rgba(63,88,120,.45);margin:0 -14px;'
            'padding:0 14px">' + X_KEY + '<div style="flex:1"></div>'
            + LINK_BARS + PILL + '</div>')


ICONS = {
 "play": '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="{c}" stroke-width="1.3"><circle cx="8" cy="8" r="3.4"/><ellipse cx="8" cy="8" rx="7" ry="2.6" transform="rotate(-18 8 8)"/></svg>',
 "ship": '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="{c}" stroke-width="1.3"><g transform="translate(8,8.6) scale(.5)"><path d="M0,-13 L15,9 L7,12 L0,8 L-7,12 L-15,9 Z"/></g></svg>',
 "pilot": '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="{c}" stroke-width="1.3"><path d="M2.6 9.8 A5.5 5.5 0 0 1 13.4 9.8"/><path d="M1.6 11.6 H14.4"/></svg>',
 "settings": '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="{c}" stroke-width="1.3"><path d="M2 4.5 H14 M2 8 H14 M2 11.5 H14"/><circle cx="10.5" cy="4.5" r="1.8" fill="#0a0f18"/><circle cx="5.5" cy="8" r="1.8" fill="#0a0f18"/><circle cx="9.5" cy="11.5" r="1.8" fill="#0a0f18"/></svg>',
}
STOPS = ["play", "ship", "pilot", "settings"]


def rail(lit="ship"):
    cells = []
    for name in STOPS:
        on = name == lit
        c = "#4fd6ff" if on else "#6c7a90"
        tc = "var(--ink)" if on else "var(--dim)"
        bg = ("background:linear-gradient(0deg,rgba(79,214,255,.14),"
              "rgba(79,214,255,0) 80%);" if on else "")
        cells.append('<div style="flex:1;display:flex;flex-direction:column;'
                     'align-items:center;justify-content:center;gap:4px;'
                     f'height:100%;padding-bottom:14px;{bg}">'
                     + ICONS[name].format(c=c)
                     + f'<span style="font-size:9px;color:{tc}">{name}</span>'
                     '</div>')
    return ('<div style="position:absolute;left:0;right:0;bottom:0;height:78px;'
            'border-top:1px solid rgba(63,88,120,.6);display:flex">'
            + "".join(cells) + '</div>')


def board(body, head=None):
    head = topline() if head is None else head
    return ('<div style="position:relative;width:390px;height:844px;'
            f'overflow:hidden;{stars(390, 844)}">'
            + fight(390, 844)
            + '<div style="position:absolute;inset:0;'
            'background:rgba(3,5,10,.86)"></div>'
            + '<div style="position:absolute;left:0;right:0;top:0;'
            'bottom:78px;padding:0 14px;overflow:hidden">'
            + head + body + '</div>'
            + rail() + '</div>')


def sect(label, mt=16):
    return (f'<div style="margin-top:{mt}px;padding:0 36px 0;margin-left:'
            '-14px;margin-right:-14px">'
            '<div style="border-top:1px solid rgba(63,88,120,.45)"></div>'
            f'<div class="lbl" style="margin-top:8px">{label}</div></div>')


# ---- Hull outlines, to the extents in docs/design/ships.md ----
HULLS = {
    "Apex":    "M0,-20 L6,-3 L10,7 L4,5 L2,11 L-2,11 L-4,5 L-10,7 L-6,-3 Z",
    "Wedge":   "M0,-13 L15,9 L7,12 L0,8 L-7,12 L-15,9 Z",
    "Chord":   "M0,-13 L8,-7 L17,1 L13,5 L5,2 L-5,2 L-13,5 L-17,1 L-8,-7 Z",
    "Anvil":   "M-8,-15 L8,-15 L13,-5 L13,6 L8,11 L-8,11 L-13,6 L-13,-5 Z",
    "Cipher":  "M0,-22 L3,-6 L6,8 L2,12 L-2,12 L-6,8 L-3,-6 Z",
    "Facet":   "M0,-8 L11,-1 L8,12 L-8,12 L-11,-1 Z",
}


def thumb(name, col):
    return (f'<svg width="34" height="40" viewBox="-18 -24 36 40" '
            f'style="flex:none"><path d="{HULLS[name]}" fill="#0b1220" '
            f'stroke="{col}" stroke-width="1.5" stroke-linejoin="round"/>'
            '</svg>')


# ---- The stepper triangles, the wake row's own ----
def tri(direction, on=True):
    a = ".9" if on else ".25"
    pts = ("2,6 9,1.5 9,10.5" if direction < 0 else "9,6 2,1.5 2,10.5")
    return (f'<svg width="11" height="12" viewBox="0 0 11 12" '
            f'style="flex:none"><polygon points="{pts}" '
            f'fill="rgba(79,214,255,{a})"/></svg>')


# ============================ Main: the roster ============================
#
# The ship page as it stands, with the two things the kit adds: the ship you
# fly grows a TUNE key, and a hull whose build has been stepped off its
# default says so in a word. Picking a ship is still one press and needs
# nothing else; the son's whole path is this board.
FLIGHT_ROWS = ["speed", "thrust", "turn", "energy", "recharge"]

ROSTER = [
    # name, shape, bars (share of the roster's range), the build's words
    ("Apex", "a swept dart", (.76, .86, .48, .14, .57),
     "spray 2, repel 2, burst 1", "here", False),
    ("Wedge", "a wide delta", (.20, .14, .09, .71, .00),
     "bomb fuse, shrapnel 3, repel 1", "cursor", True),
    ("Chord", "a shallow bow", (.12, 1.0, 1.0, .21, .78),
     "spray 3, gun freeze, bomb fuse, repel 2", None, False),
    ("Anvil", "a blunt slab", (.00, .00, .00, 1.0, 1.0),
     "repel 2, burst 1", None, False),
    ("Cipher", "a knife", (1.0, .79, .35, .00, .35),
     "repel 1, burst 2, no bomb rack", None, False),
    ("Facet", "a squat pentagon", (.32, .43, .61, .00, .35),
     "spray 5, gun bounce, repel 2", None, False),
]


def bars_strip(shares, col):
    cells = []
    for share, word in zip(shares, FLIGHT_ROWS):
        cells.append(
            '<div class="col" style="flex:1;gap:3px">'
            '<div style="position:relative;height:3px;'
            'background:rgba(108,122,144,.22)">'
            f'<div style="position:absolute;left:0;top:0;bottom:0;'
            f'width:{share * 100:.0f}%;background:{col};opacity:.85"></div>'
            '</div>'
            f'<span class="lbl" style="font-size:8px;letter-spacing:.1em">'
            f'{word}</span></div>')
    return ('<div class="row" style="gap:6px;align-items:flex-start">'
            + "".join(cells) + '</div>')


def ship_row(name, shape, shares, carries, state, tuned):
    mine = state == "here"
    col = "#4fd6ff" if mine else "rgba(223,233,245,.9)"
    tune = ('<span class="key" style="height:26px;padding:0 12px;'
            'font-size:10px">tune</span>' if mine else "")
    mark = ('<span class="lbl" style="color:#4fd6ff;opacity:.75;'
            'margin-left:10px">tuned</span>' if tuned else "")
    return bleed(
        '<div class="row" style="padding:10px 0 9px;gap:12px;'
        'align-items:flex-start">'
        + '<div style="margin-top:2px">' + thumb(name, col) + '</div>'
        + '<div class="col" style="flex:1;min-width:0;gap:6px">'
        + '<div class="row" style="gap:10px">'
        + f'<span style="font-size:17px;color:{col}">{name}</span>'
        + f'<span class="lbl" style="letter-spacing:.08em">{shape}</span>'
        + mark + '<div style="flex:1"></div>' + tune + '</div>'
        + bars_strip(shares, col)
        + f'<span class="mono" style="font-size:11.5px;color:#9fb6d4">'
        f'{carries}</span>'
        + '</div></div>', state=state)


def main_board():
    rows = "".join(ship_row(*r) for r in ROSTER)
    body = (sect("ships", mt=12)
            + '<div style="margin-top:6px">' + rows + '</div>')
    write("Main.dc.html", board(body))


# ============================ Tune: the editor ============================
#
# One hull, one page. The head carries the hull and the budget; every row
# under it is a slot said as a sentence and stepped by the triangles. The
# cursor's row wears its note, the way every page's rows do now. RESET is
# the entire build manager.
def tune_head(name, free, changed=False):
    spent = 30 - free
    seg = (f'<div style="position:relative;width:86px;height:5px;'
           'background:rgba(108,122,144,.25)">'
           f'<div style="position:absolute;left:0;top:0;bottom:0;'
           f'width:{spent / 30 * 100:.0f}%;background:#4fd6ff;opacity:.9">'
           '</div></div>')
    return ('<div class="row" style="height:48px;gap:10px;border-bottom:'
            '1px solid rgba(63,88,120,.45);margin:0 -14px;padding:0 14px">'
            + X_KEY
            + '<div style="margin:0 -4px">' + thumb(name, "#4fd6ff") + '</div>'
            + f'<span style="font-size:17px">{name}</span>'
            '<div style="flex:1"></div>'
            + '<div class="col" style="align-items:flex-end;gap:4px">'
            + f'<span class="lbl" style="color:'
            + ("#8dffb0" if free else "#6c7a90")
            + f'">{free} free of 30</span>' + seg + '</div></div>')


def step_row(label, value, cost=None, state=None, note=None, down=True,
             up=True, zero=False):
    hot = state == "cursor"
    vcol = ("rgba(108,122,144,.85)" if zero
            else "#4fd6ff")
    right = ""
    if cost == "max":
        right = '<span class="lbl">at its cap</span>'
    elif cost:
        right = (f'<span class="mono" style="font-size:11px;'
                 f'color:rgba(133,147,169,.9)">{cost}</span>')
    note_line = ""
    if note:
        note_line = ('<div style="padding:0 0 10px;margin-top:-2px">'
                     f'<span style="font-size:13px;color:#9fb6d4;'
                     f'line-height:1.45">{note}</span></div>')
    return bleed(
        '<div class="row" style="height:40px;gap:0">'
        f'<span style="font-size:14px;width:118px;flex:none;'
        f'color:rgba(223,233,245,{1 if hot else .85})">{label}</span>'
        + tri(-1, on=down) +
        f'<span class="mono" style="font-size:12.5px;color:{vcol};'
        'min-width:104px;text-align:center;padding:0 6px">'
        f'{value}</span>'
        + tri(1, on=up)
        + '<div style="flex:1"></div>' + right + '</div>' + note_line,
        state=state)


def reset_row(changed):
    col = "#dfe9f5" if changed else "rgba(223,233,245,.45)"
    word = ("back to the Apex&#39;s own build" if changed
            else "this is the Apex&#39;s own build")
    return bleed(
        '<div class="row" style="height:44px;gap:12px">'
        f'<span style="font-size:14px;color:{col}">reset</span>'
        f'<span class="note">{word}</span></div>')


def tune_board():
    body = (
        sect("gun", mt=12)
        + '<div style="margin-top:4px">'
        + step_row("spray", "2 rounds", cost="4 a round", state="cursor",
                   note="Every pull throws two rounds abreast. The extra "
                        "rounds cost energy on top.")
        + step_row("bounce", "off", cost="3", down=False, zero=True)
        + step_row("freeze", "off", cost="3", down=False, zero=True)
        + '</div>'
        + sect("bomb")
        + '<div style="margin-top:4px">'
        + step_row("fuse", "on contact", cost="2", down=False, zero=True)
        + step_row("shrapnel", "none", cost="3 a rung", down=False, zero=True)
        + step_row("bounce", "off", cost="2", down=False, zero=True)
        + '</div>'
        + sect("rack")
        + '<div style="margin-top:4px">'
        + step_row("repel", "carries 2", cost="9 each")
        + step_row("burst", "carries 1", cost="8 each")
        + '</div>'
        + sect("")
        + reset_row(False))
    write("Tune.dc.html", board(body, head=tune_head("Apex", 0)))


# ==================== TuneStates: the page mid-edit ====================
#
# The same page after trading a repel away: six points free and part spent,
# one slot at its cap saying so, the freed points lighting the head, RESET
# awake. The row that cannot step down dims its own left triangle rather
# than growing a rule.
def tune_states_board():
    body = (
        sect("gun", mt=12)
        + '<div style="margin-top:4px">'
        + step_row("spray", "2 rounds", cost="4 a round")
        + step_row("bounce", "bounces once", cost="max", up=False)
        + step_row("freeze", "off", cost="3", down=False, zero=True)
        + '</div>'
        + sect("bomb")
        + '<div style="margin-top:4px">'
        + step_row("fuse", "on contact", cost="2", down=False, zero=True)
        + step_row("shrapnel", "none", cost="3 a rung", state="cursor",
                   down=False, zero=True,
                   note="Each rung is two fragments out of every blast, "
                        "carrying the gun&#39;s own damage.")
        + step_row("bounce", "off", cost="2", down=False, zero=True)
        + '</div>'
        + sect("rack")
        + '<div style="margin-top:4px">'
        + step_row("repel", "carries 1", cost="9 each")
        + step_row("burst", "carries 1", cost="8 each")
        + '</div>'
        + sect("")
        + reset_row(True))
    write("TuneStates.dc.html", board(body, head=tune_head("Apex", 6,
                                                           changed=True)))


# ==================== FlightOption: the other fork ====================
#
# The sketch of the road not recommended: flight spendable too. Same page
# with a fourth section whose five rows step the flight row itself. What it
# buys is full freedom; what it costs is the roster, since two hulls tuned
# to the same numbers are the same ship wearing two drawings.
def flight_option_board():
    body = (
        sect("flight", mt=12)
        + '<div style="margin-top:4px">'
        + step_row("speed", "rung 6 of 8", cost="2 a rung")
        + step_row("thrust", "rung 7 of 8", cost="2 a rung")
        + step_row("turn", "rung 4 of 8", cost="2 a rung", state="cursor",
                   note="Two hulls stepped to the same rungs fly as the "
                        "same ship. This section is the fork not taken.")
        + step_row("energy", "rung 2 of 8", cost="2 a rung")
        + step_row("recharge", "rung 5 of 8", cost="2 a rung")
        + '</div>'
        + sect("gun")
        + '<div style="margin-top:4px">'
        + step_row("spray", "2 rounds", cost="4 a round")
        + step_row("bounce", "off", cost="3", down=False, zero=True)
        + '</div>'
        + sect("rack")
        + '<div style="margin-top:4px">'
        + step_row("repel", "carries 1", cost="9 each")
        + step_row("burst", "carries 1", cost="8 each")
        + '</div>'
        + sect("")
        + reset_row(True))
    write("FlightOption.dc.html", board(body, head=tune_head("Apex", 1)))


# ======================= The build credits vocabulary =======================
#
# Chris's read of the first pass: busy, the right-hand numbers opaque, the
# blue bar opaque. So the currency gets a name and a face. A build credit is
# a gold diamond; the tray under the head holds all thirty, solid where they
# are free and a faint socket where they are spent; a price anywhere on a
# page is drawn as the chips it costs, never as a numeral. Nothing to read,
# only to count.
def chip(solid=True, k=7):
    if solid:
        return (f'<span style="width:{k}px;height:{k}px;flex:none;'
                'background:#ffd166;transform:rotate(45deg)"></span>')
    return (f'<span style="width:{k}px;height:{k}px;flex:none;'
            'border:1px solid rgba(255,209,102,.3);'
            'transform:rotate(45deg)"></span>')


def chips(n, solid=True, k=7, gap=3):
    return (f'<span class="row" style="gap:{gap}px;flex:none">'
            + "".join(chip(solid, k) for _ in range(n)) + '</span>')


def credits_tray(free):
    cells = "".join(chip(True, 6) for _ in range(free)) + "".join(
        chip(False, 6) for _ in range(30 - free))
    return ('<div class="row" style="height:34px;gap:10px;'
            'border-bottom:1px solid rgba(63,88,120,.45);'
            'margin:0 -14px;padding:0 14px">'
            '<span class="lbl" style="color:#ffd166;opacity:.8;flex:none">'
            'build credits</span>'
            '<div class="row" style="gap:2px;flex-wrap:nowrap">'
            + cells + '</div></div>')


def hull_head(name):
    return ('<div class="row" style="height:48px;gap:10px;border-bottom:'
            '1px solid rgba(63,88,120,.45);margin:0 -14px;padding:0 14px">'
            + X_KEY
            + '<div style="margin:0 -4px">' + thumb(name, "#4fd6ff") + '</div>'
            + f'<span style="font-size:17px">{name}</span>'
            '<div style="flex:1"></div></div>')


# ====================== Option A: chips on the rows ======================
#
# The list survives but every number on it dies. A row at rest is three
# things: the slot, what it is set to, and its price drawn as the chips one
# step costs. Only the row the cursor is on grows its triangles, at the
# row's full height so a thumb hits them as easily as a d-pad does; every
# other row is quiet. Stepping up visibly drains the tray.
def chips_row(label, value, price, state=None, zero=False, full=False):
    hot = state == "cursor"
    vcol = "rgba(108,122,144,.85)" if zero else "#4fd6ff"
    right = ('<span class="lbl">full</span>' if full
             else chips(price, solid=True, k=6, gap=2.5))
    h = 52 if hot else 42
    left_t = (tri(-1, on=not zero) if hot else "")
    right_t = (tri(1, on=not full) if hot else "")
    return bleed(
        f'<div class="row" style="height:{h}px;gap:10px">'
        f'<span style="font-size:14px;width:96px;flex:none;'
        f'color:rgba(223,233,245,{1 if hot else .85})">{label}</span>'
        + left_t
        + f'<span class="mono" style="font-size:12.5px;color:{vcol};'
        f'min-width:92px;text-align:center">{value}</span>'
        + right_t
        + '<div style="flex:1"></div>' + right + '</div>', state=state)


def option_chips_board():
    body = (
        credits_tray(8)
        + sect("gun", mt=10)
        + '<div style="margin-top:2px">'
        + chips_row("spray", "2 rounds", 5, state="cursor")
        + chips_row("bounce", "off", 3, zero=True)
        + chips_row("freeze", "off", 3, zero=True)
        + '</div>'
        + sect("bomb", mt=8)
        + '<div style="margin-top:2px">'
        + chips_row("fuse", "contact", 2, zero=True)
        + chips_row("shrapnel", "none", 3, zero=True)
        + '</div>'
        + sect("rack", mt=8)
        + '<div style="margin-top:2px">'
        + chips_row("repel", "1", 8)
        + chips_row("burst", "1", 9)
        + '</div>'
        + sect("", mt=8)
        + bleed('<div class="row" style="height:44px">'
                '<span style="font-size:14px;color:#dfe9f5">reset</span>'
                '</div>'))
    write("Chips.dc.html", board(body, head=hull_head("Apex")))


# ====================== Option B: one slot at a time ======================
#
# The opposite cure for busy: the page holds one slot, drawn as what it
# does. Left and right walk the slots, the picture changes, and the two keys
# at the foot are the whole interface, the raise key wearing the chips it
# will take. A controller and a thumb get the same four targets; a keyboard
# gets four arrows.
def option_focus_board():
    dots = "".join(
        '<span style="width:7px;height:7px;border-radius:50%;flex:none;'
        + ('background:#4fd6ff' if i == 0
           else 'border:1.2px solid rgba(108,122,144,.5)')
        + '"></span>' for i in range(7))
    strip = ('<div class="row" style="justify-content:center;gap:8px;'
             'margin-top:16px">' + dots + '</div>')
    picture = ('<svg width="300" height="230" viewBox="0 0 300 230" '
               'style="display:block;margin:8px auto 0">'
               '<g stroke="#4fd6ff" stroke-width="2" opacity=".9">'
               '<path d="M138 130 L138 34"/><path d="M162 130 L162 34"/>'
               '</g>'
               '<g fill="#4fd6ff">'
               '<path d="M138 26 l-4 10 h8 Z"/><path d="M162 26 l-4 10 h8 Z"/>'
               '</g>'
               '<g transform="translate(150,178) scale(3.2)">'
               '<path d="M0,-20 L6,-3 L10,7 L4,5 L2,11 L-2,11 L-4,5 L-10,7 '
               'L-6,-3 Z" fill="#0b1220" stroke="#4fd6ff" stroke-width="1.1" '
               'stroke-linejoin="round"/></g></svg>')
    name = ('<div class="row" style="justify-content:center;gap:14px;'
            'margin-top:18px">'
            + tri(-1) +
            '<span class="lbl" style="font-size:11px;color:#9fb6d4">spray'
            '</span>' + tri(1) + '</div>')
    value = ('<div style="text-align:center;margin-top:10px">'
             '<span class="mono" style="font-size:21px;color:#4fd6ff">'
             '2 rounds</span></div>')
    keys = ('<div class="row" style="gap:10px;margin-top:26px">'
            '<div class="key" style="flex:1;height:56px;font-size:20px">'
            '&#8722;</div>'
            '<div class="key" style="flex:1;height:56px;gap:9px;'
            'border-color:rgba(255,209,102,.55)">'
            '<span style="font-size:20px">+</span>'
            + chips(5, k=7) + '</div></div>')
    body = credits_tray(8) + name + picture + value + keys + strip
    write("Focus.dc.html", board(body, head=hull_head("Apex")))


# ==================== Option C: the ship is the page ====================
#
# No list at all. The build is drawn once, as the ship firing it: the fan
# ahead of the nose, the bomb under the tail, the rack beside the hull, and
# each cluster is the control for itself. The cursor is the radar's corner
# brackets; left and right step whatever is inside them, a tap moves them.
# The only words are the count each cluster wears.
def option_diagram_board():
    def brackets(x, y, w, h):
        c, s = "rgba(255,209,102,.85)", 12
        return (f'<g stroke="{c}" stroke-width="1.4" fill="none">'
                f'<path d="M{x} {y + s} V{y} H{x + s}"/>'
                f'<path d="M{x + w - s} {y} H{x + w} V{y + s}"/>'
                f'<path d="M{x + w} {y + h - s} V{y + h} H{x + w - s}"/>'
                f'<path d="M{x + s} {y + h} H{x} V{y + h - s}"/></g>')

    def word(x, y, text, col="#9fb6d4", anchor="middle"):
        return (f'<text x="{x}" y="{y}" text-anchor="{anchor}" '
                f'font-family="DejaVu Sans Mono,monospace" font-size="11" '
                f'fill="{col}">{text}</text>')

    def diamonds(x, y, n):
        out = []
        for i in range(n):
            cx = x + i * 11
            out.append(f'<rect x="{cx}" y="{y}" width="6" height="6" '
                       f'transform="rotate(45 {cx + 3} {y + 3})" '
                       'fill="#ffd166"/>')
        return "".join(out)

    svg = (
        '<svg width="362" height="560" viewBox="0 0 362 560" '
        'style="display:block;margin-top:6px">'
        # The fan: two rounds abreast, the selected cluster.
        '<g stroke="#4fd6ff" stroke-width="2" opacity=".9">'
        '<path d="M169 150 L169 70"/><path d="M193 150 L193 70"/></g>'
        '<g fill="#4fd6ff">'
        '<path d="M169 62 l-4 10 h8 Z"/><path d="M193 62 l-4 10 h8 Z"/></g>'
        + brackets(140, 48, 82, 118)
        + word(181, 40, "spray &#183; 2", "#ffd166")
        + diamonds(154, 178, 5)
        # The hull.
        + '<g transform="translate(181,290) scale(3.2)">'
        '<path d="M0,-20 L6,-3 L10,7 L4,5 L2,11 L-2,11 L-4,5 L-10,7 L-6,-3 Z" '
        'fill="#0b1220" stroke="#4fd6ff" stroke-width="1.1" '
        'stroke-linejoin="round"/></g>'
        # The bomb, under the tail: a plain round and its blast ring.
        + '<circle cx="181" cy="430" r="7" fill="#ffa552" opacity=".9"/>'
        '<circle cx="181" cy="430" r="24" stroke="#ffa552" fill="none" '
        'stroke-width="1" opacity=".4"/>'
        + word(181, 478, "bomb &#183; plain")
        # The rack, beside the hull: repel arcs and a burst star.
        + '<g stroke="#8dffb0" fill="none" stroke-width="1.4" opacity=".85">'
        '<circle cx="66" cy="270" r="13"/><circle cx="66" cy="270" r="20"/>'
        '<circle cx="106" cy="270" r="13"/><circle cx="106" cy="270" r="20"/>'
        '</g>'
        + word(86, 312, "repel &#183; 2")
        + '<g stroke="#ffe08a" stroke-width="1.4" opacity=".9">'
        '<path d="M286 258 v24 M274 270 h24 M278 262 l16 16 M294 262 '
        'l-16 16"/></g>'
        + word(286, 312, "burst &#183; 1")
        + '</svg>')
    stepper = ('<div class="row" style="justify-content:center;gap:22px;'
               'margin-top:0">'
               + tri(-1) + '<span class="lbl" style="font-size:10px;'
               'color:#ffd166">spray</span>' + tri(1) + '</div>')
    body = credits_tray(8) + svg + stepper
    write("Diagram.dc.html", board(body, head=hull_head("Apex")))


# ===================== The A experiments: real controls =====================
#
# Chris's next ask: A again, but the laddered slots as drop down selectors,
# the on/off add-ons as toggles, and the credit cost tried in different
# homes. Three homes are drawn: in the choice (a row is clean until its list
# is open or the cursor stands on it), on the row (every price always
# visible), and in the tray (the rows are bare and the tray itself shows
# what the focused step would take).
def toggle(on):
    if on:
        return ('<span style="width:40px;height:20px;flex:none;'
                'border:1px solid rgba(79,214,255,.75);'
                'background:rgba(79,214,255,.18);position:relative">'
                '<span style="position:absolute;right:2px;top:2px;'
                'width:14px;height:14px;background:#4fd6ff"></span></span>')
    return ('<span style="width:40px;height:20px;flex:none;'
            'border:1px solid rgba(63,88,120,.75);position:relative">'
            '<span style="position:absolute;left:2px;top:2px;'
            'width:14px;height:14px;background:rgba(108,122,144,.6)">'
            '</span></span>')


def caret(col="#9fb6d4"):
    return ('<svg width="9" height="9" viewBox="0 0 10 10" fill="none" '
            f'style="flex:none"><path d="M1.5 3 L5 7 L8.5 3" stroke="{col}" '
            'stroke-width="1.4" stroke-linecap="square"/></svg>')


def select_field(value, inner="", w=None, zero=False):
    vcol = "rgba(108,122,144,.9)" if zero else "#4fd6ff"
    ww = f"width:{w}px;" if w else ""
    return (f'<span class="key" style="height:34px;padding:0 10px;gap:8px;'
            f'{ww}justify-content:space-between;text-transform:none">'
            f'<span class="mono" style="font-size:12px;color:{vcol}">'
            f'{value}</span>' + inner + caret() + '</span>')


def ctl_row(label, control, mid="", state=None, h=46):
    hot = state == "cursor"
    return bleed(
        f'<div class="row" style="height:{h}px;gap:10px">'
        f'<span style="font-size:14px;color:rgba(223,233,245,'
        f'{1 if hot else .85})">{label}</span>'
        '<div style="flex:1"></div>' + mid + control + '</div>', state=state)


def exp_rows(cost, cursor_on, fuse_on=False):
    """The one list all four experiment boards share. cost(price, on_row,
    focused) says what a row shows beside its control; the homes differ
    only in that function."""
    def c(price, focused=False, paid=False):
        return cost(price, focused, paid)
    return (
        sect("gun", mt=10)
        + '<div style="margin-top:2px">'
        + ctl_row("spray", select_field("2 rounds", w=132),
                  mid=c(5, cursor_on == "spray"),
                  state="cursor" if cursor_on == "spray" else None)
        + ctl_row("bounce", toggle(False),
                  mid=c(3, cursor_on == "bounce"),
                  state="cursor" if cursor_on == "bounce" else None)
        + ctl_row("freeze", toggle(False),
                  mid=c(3, cursor_on == "freeze"),
                  state="cursor" if cursor_on == "freeze" else None)
        + '</div>'
        + sect("bomb", mt=8)
        + '<div style="margin-top:2px">'
        + ctl_row("fuse", toggle(fuse_on), mid=c(2, False, paid=fuse_on))
        + ctl_row("shrapnel", select_field("none", w=132, zero=True),
                  mid=c(3, False))
        + ctl_row("bounce", toggle(False), mid=c(2, False))
        + '</div>'
        + sect("rack", mt=8)
        + '<div style="margin-top:2px">'
        + ctl_row("repel", select_field("1", w=132), mid=c(8, False))
        + ctl_row("burst", select_field("1", w=132), mid=c(9, False))
        + '</div>'
        + sect("", mt=8)
        + bleed('<div class="row" style="height:44px">'
                '<span style="font-size:14px;color:#dfe9f5">reset</span>'
                '</div>'))


# -- A2: the cost lives in the choice. A row at rest shows nothing; the row
# the cursor stands on shows what one step costs, and the open list prices
# every rung (its own board, below).
def exp_selects_board():
    def cost(price, focused, paid=False):
        if not focused:
            return ""
        return ('<span class="row" style="gap:8px;margin-right:4px">'
                + chips(price, k=6, gap=2.5) + '</span>')
    body = credits_tray(8) + exp_rows(cost, cursor_on="bounce")
    write("ASelects.dc.html", board(body, head=hull_head("Apex")))


# -- A2 with the spray list open: every rung wears its own chips, the rung
# you hold washes at 0.07, the one under the cursor at 0.18. The price
# comparison IS the list.
def exp_selects_open_board():
    def opt(value, n_chips, state=None, free=False):
        wash = (CURSOR if state == "cursor"
                else HERE if state == "here" else "")
        right = ('<span class="lbl">free</span>' if free
                 else chips(n_chips, k=6, gap=2.5))
        return (f'<div class="row" style="height:38px;padding:0 12px;{wash}">'
                f'<span class="mono" style="font-size:12px;color:#dfe9f5">'
                f'{value}</span><div style="flex:1"></div>' + right + '</div>')
    drop = ('<div style="position:absolute;left:150px;right:36px;top:114px;'
            'background:rgba(6,9,15,.97);border:1px solid '
            'rgba(63,88,120,.85);padding:4px 0;z-index:3">'
            + opt("1 round", 0, free=True)
            + opt("2 rounds", 5, state="here")
            + opt("3 rounds", 10, state="cursor")
            + '</div>')
    def cost(price, focused, paid=False):
        return ""
    body = ('<div style="position:relative">'
            + credits_tray(8)
            + exp_rows(cost, cursor_on="spray")
            + drop + '</div>')
    write("ASelectsOpen.dc.html", board(body, head=hull_head("Apex")))


# -- A3: the cost lives on the row, always. The most honest and the
# busiest; a paid toggle keeps its chips beside it, dimmed, so on and off
# rows read differently at a glance.
def exp_inline_board():
    def cost(price, focused, paid=False):
        op = "opacity:.35;" if paid else ""
        return (f'<span class="row" style="gap:8px;margin-right:4px;{op}">'
                + chips(price, k=6, gap=2.5) + '</span>')
    body = credits_tray(6) + exp_rows(cost, cursor_on="freeze", fuse_on=True)
    write("ACostInline.dc.html", board(body, head=hull_head("Apex")))


# -- A4: the cost lives in the tray. The rows are the cleanest of the
# three; standing on a control lights the chips it would take at the end
# of the tray's free run, about to go.
def preview_tray(free, preview):
    solid = "".join(chip(True, 6) for _ in range(free - preview))
    prev = "".join(
        '<span style="width:6px;height:6px;flex:none;'
        'border:1.4px solid #ffd166;background:rgba(255,209,102,.25);'
        'transform:rotate(45deg)"></span>' for _ in range(preview))
    sockets = "".join(chip(False, 6) for _ in range(30 - free))
    return ('<div class="row" style="height:34px;gap:10px;'
            'border-bottom:1px solid rgba(63,88,120,.45);'
            'margin:0 -14px;padding:0 14px">'
            '<span class="lbl" style="color:#ffd166;opacity:.8;flex:none">'
            'build credits</span>'
            '<div class="row" style="gap:2px;flex-wrap:nowrap">'
            + solid + prev + sockets + '</div></div>')


def exp_tray_board():
    def cost(price, focused, paid=False):
        return ""
    body = preview_tray(8, 3) + exp_rows(cost, cursor_on="freeze")
    write("ACostTray.dc.html", board(body, head=hull_head("Apex")))


# ========================= Flat: one credit each =========================
#
# Chris's cut through the cost-home question: shrink the tray and price
# every step at one build credit. There is no price to draw anywhere, so
# the rows carry nothing but their controls: plus and minus keys on the
# laddered slots, toggles on the on/off add-ons. Seven chips, drawn big.
# Balance moves from prices to caps and effect tuning, and seven picks
# over a dozen steps is a build space calibrate can sweep whole.
def flat_tray(free, total=7):
    cells = []
    for i in range(total):
        if i < free:
            cells.append('<span style="width:11px;height:11px;flex:none;'
                         'background:#ffd166;transform:rotate(45deg)">'
                         '</span>')
        else:
            cells.append('<span style="width:11px;height:11px;flex:none;'
                         'border:1.2px solid rgba(255,209,102,.3);'
                         'transform:rotate(45deg)"></span>')
    return ('<div class="row" style="height:40px;gap:14px;'
            'border-bottom:1px solid rgba(63,88,120,.45);'
            'margin:0 -14px;padding:0 14px">'
            '<span class="lbl" style="color:#ffd166;opacity:.8;flex:none">'
            'build credits</span>'
            '<div class="row" style="gap:7px">' + "".join(cells)
            + '</div></div>')


def flat_note(note):
    """The active row says what its slot does, in one sentence under the
    controls, the way the menu's rows carry their wrapping notes."""
    if not note:
        return ""
    return ('<div style="padding:0 0 12px;margin-top:-4px">'
            f'<span style="font-size:13px;color:#9fb6d4;line-height:1.45">'
            f'{note}</span></div>')


def flat_row(label, value, minus=True, plus=True, state=None, zero=False,
             note=None):
    """A counted slot steps the wake row's way: the value between the two
    friend triangles, the one that cannot fire dimmed."""
    hot = state == "cursor"
    vcol = "rgba(108,122,144,.9)" if zero else "#4fd6ff"
    return bleed(
        '<div class="row" style="height:46px;gap:0">'
        f'<span style="font-size:14px;color:rgba(223,233,245,'
        f'{1 if hot else .85})">{label}</span>'
        '<div style="flex:1"></div>'
        + tri(-1, on=minus)
        + f'<span class="mono" style="font-size:12.5px;color:{vcol};'
        f'min-width:96px;text-align:center;padding:0 6px">{value}</span>'
        + tri(1, on=plus) + '</div>'
        + flat_note(note if hot else None), state=state)


def flat_toggle_row(label, on, can_raise=True, state=None, note=None):
    hot = state == "cursor"
    t = toggle(on)
    if not on and not can_raise:
        t = f'<span style="opacity:.35">{t}</span>'
    return bleed(
        '<div class="row" style="height:46px;gap:14px">'
        f'<span style="font-size:14px;color:rgba(223,233,245,'
        f'{1 if hot else .85})">{label}</span>'
        '<div style="flex:1"></div>' + t + '</div>'
        + flat_note(note if hot else None), state=state)


def flat_reset():
    return (sect("", mt=8)
            + bleed('<div class="row" style="height:44px">'
                    '<span style="font-size:14px;color:#dfe9f5">Reset</span>'
                    '</div>'))


# The Apex default: spray 2, repel 2, burst 1 is four picks of seven, so a
# fresh player holds three free credits and their first edit is spending
# one rather than trading.
def flat_board():
    body = (
        flat_tray(3)
        + sect("gun", mt=10)
        + '<div style="margin-top:2px">'
        + flat_row("Spray", "2", state="cursor",
                   note="How many rounds one pull of the trigger throws.")
        + flat_toggle_row("Bounce", False)
        + flat_toggle_row("Freeze", False)
        + '</div>'
        + sect("bomb", mt=8)
        + '<div style="margin-top:2px">'
        + flat_toggle_row("Proximity detonation", False)
        + flat_row("Shrapnel", "0", minus=False, zero=True)
        + flat_toggle_row("Bounce", False)
        + '</div>'
        + sect("rack", mt=8)
        + '<div style="margin-top:2px">'
        + flat_row("Repel", "2")
        + flat_row("Burst", "1")
        + '</div>'
        + flat_reset())
    write("Flat.dc.html", board(body, head=hull_head("Apex")))


# The same page with all seven spent: every way to spend an eighth stands
# down by itself, plus keys and off toggles alike, which is the whole of
# what "out of credits" needs to say.
def flat_spent_board():
    body = (
        flat_tray(0)
        + sect("gun", mt=10)
        + '<div style="margin-top:2px">'
        + flat_row("Spray", "3", plus=False)
        + flat_toggle_row("Bounce", False, can_raise=False)
        + flat_toggle_row("Freeze", True)
        + '</div>'
        + sect("bomb", mt=8)
        + '<div style="margin-top:2px">'
        + flat_toggle_row("Proximity detonation", True)
        + flat_row("Shrapnel", "0", minus=False, plus=False, zero=True,
                   state="cursor",
                   note="Fragments thrown by the blast, each carrying the "
                        "gun&#39;s damage.")
        + flat_toggle_row("Bounce", False, can_raise=False)
        + '</div>'
        + sect("rack", mt=8)
        + '<div style="margin-top:2px">'
        + flat_row("Repel", "2")
        + flat_row("Burst", "1", plus=False)
        + '</div>'
        + flat_reset())
    write("FlatSpent.dc.html", board(body, head=hull_head("Apex")))


main_board()
tune_board()
tune_states_board()
flight_option_board()
option_chips_board()
option_focus_board()
option_diagram_board()
exp_selects_board()
exp_selects_open_board()
exp_inline_board()
exp_tray_board()
flat_board()
flat_spent_board()
print("thirteen boards written")
