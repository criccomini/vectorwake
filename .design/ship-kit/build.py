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


main_board()
tune_board()
tune_states_board()
flight_option_board()
print("four boards written")
