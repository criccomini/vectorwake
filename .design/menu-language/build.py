#!/usr/bin/env python3
"""Assemble the artboards for the menu design language.

Shipped as decision 104 and corrected by decision 105; these boards are
what runs. Decision 103 gave every menu one container -- a stop slides a
frosted panel up through the bottom edge -- and what was inside the
container still spoke three dialects. The zone
and account panels set their rows in the HUD's 12-point mono capitals;
the settings panel sets its rows in the menu face at 17, sentence case;
the ship panel is a third anatomy again, with two heads stacked and its
own row height. Grounds sit at four opacities, the rules at four alphas,
the two scroll thumbs disagree, and the account card stands on no ground
at all.

The language here says each of those once:

- Everything is a panel; a panel is rows; a row is one shape.
- One glass, one edge, one head, one band, one wash pair, one key.
- The menu speaks in the menu face, sentence case, at 17; it reads in
  the mono at 14; it quotes names raw. Capitals belong to the HUD and
  to the small labels, which are the mono at 12.
- A panel is as tall as what it holds, standing on the bottom margin it
  slid out of, and eases to a new height when a stack changes.
- A row's right end is what the row does: opens, reads, steps, fills,
  switches, or walks. Nothing else varies.

Boards: the language sheet, then the four shipped surfaces restated in
it (zone, settings, ship, and the log-in card become a stacked panel),
the settings panel on a phone, and one deliberate alternate: the zone
panel in today's mono voice, so the one open choice is visible instead
of settled by silence.

Every number is lifted from the client rather than invented:
client/arena/palette.lua for hues, ui.lua for TYPE {12, 14, 17, 21},
LIT {0.18, 0.07}, the 44-point touch floor, PANEL_MAX 560, the
14-point margin, the 34x18 switch, the range cells, and the head's
back triangle. Shrapnel's four fragments are sim_splinter_count's, off
the shipped baseline. The scene behind the glass is ../dropdown-stack's.

Rebuild with: python3 build.py
"""

import random
from pathlib import Path

HERE = Path(__file__).parent

# --- the palette, verbatim from client/arena/palette.lua ---------------------
BG = "#05070c"
INK = "#dfe9f5"
DIM = "#6c7a90"
READ = "#9fb6d4"
MUTE = "#8593a9"
FRIEND = "#4fd6ff"
ENEMY = "#ffa552"
TILE = "#3f5878"        # RADAR_TILE: every rule and resting edge
BTN = "#0a0f18"         # BTN_BG: the glass's own tint
CAUTION = "#ffd166"     # CHARGE_COL: the offer and the guest dot
BOUNTY = "#ffe08a"

CSS = f"""
:root{{ --bg:{BG}; --ink:{INK}; --dim:{DIM}; --read:{READ}; --mute:{MUTE};
  --friend:{FRIEND}; --enemy:{ENEMY}; --tile:{TILE}; --caution:{CAUTION};
  --mono:"DejaVu Sans Mono","Noto Sans Mono",ui-monospace,monospace;
  --menu:"Chakra Petch","Segoe UI",system-ui,sans-serif; }}
*{{box-sizing:border-box}}
body{{margin:0;background:var(--bg);color:var(--ink);font-family:var(--menu)}}
a{{color:var(--friend)}}a:hover{{color:#8ee6ff}}
.mono{{font-family:var(--mono)}}
.lbl{{font-family:var(--mono);font-size:12px;text-transform:uppercase;
  letter-spacing:.1em;color:var(--mute)}}
.row{{display:flex;align-items:center}}

/* The glass: frost plus the button tint, outlined in the tile color.
   One ground for a stop, a panel and a card alike. */
.glass{{border:1px solid rgba(63,88,120,.75);background:rgba(10,15,24,.72);
  backdrop-filter:blur(5px)}}

/* The one shape a thing to press wears when it stands alone. */
.key{{display:inline-flex;align-items:center;justify-content:center;gap:7px;
  border:1px solid rgba(63,88,120,.75);background:rgba(10,15,24,.6);
  font-family:var(--mono);text-transform:uppercase;letter-spacing:.06em;
  color:var(--read)}}

@keyframes breath{{
  0%,100%{{background:rgba(79,214,255,.06);border-color:rgba(79,214,255,.62)}}
  50%{{background:rgba(79,214,255,.18);border-color:rgba(79,214,255,1)}}
}}
.play{{display:flex;align-items:center;justify-content:center;
  border:1.6px solid rgba(79,214,255,.62);backdrop-filter:blur(5px);
  animation:breath 2.42s ease-in-out infinite;
  font-family:var(--mono);letter-spacing:.14em;color:var(--ink)}}
"""

# --- small marks, at the pen weight the client draws them --------------------


def caret(col=READ, k=10):
    return (f'<svg width="{k}" height="{k}" viewBox="0 0 10 10" fill="none" '
            f'style="flex:none"><path d="M1.5 3 L5 7 L8.5 3" stroke="{col}" '
            f'stroke-width="1.4" stroke-linecap="square"/></svg>')


def back_tri(a=0.9):
    return (f'<svg width="11" height="12" viewBox="0 0 11 12" '
            f'style="flex:none"><polygon points="2,6 9,1.5 9,10.5" '
            f'fill="rgba(79,214,255,{a})"/></svg>')


def step_tri(direction, live=True, k=13):
    pts = "2,6.5 11,1.5 11,11.5" if direction < 0 else "11,6.5 2,1.5 2,11.5"
    a = 0.9 if live else 0.25
    return (f'<svg width="{k}" height="{k}" viewBox="0 0 13 13" '
            f'style="flex:none"><polygon points="{pts}" '
            f'fill="rgba(79,214,255,{a})"/></svg>')


def dot(col=CAUTION):
    return (f'<span style="width:5px;height:5px;border-radius:50%;'
            f'background:{col};flex:none"></span>')


def mixer(col=MUTE, k=15):
    return (f'<svg width="{k}" height="{k}" viewBox="0 0 16 16" fill="none" '
            f'stroke="{col}" stroke-width="1.3" style="flex:none">'
            '<path d="M2 4.5 H14 M2 8 H14 M2 11.5 H14"/>'
            f'<circle cx="10.5" cy="4.5" r="1.8" fill="{BTN}"/>'
            f'<circle cx="5.5" cy="8" r="1.8" fill="{BTN}"/>'
            f'<circle cx="9.5" cy="11.5" r="1.8" fill="{BTN}"/></svg>')


# --- the row: one shape, six right ends --------------------------------------
# 44 tall, which is the touch floor, and there is no second height: a dense
# variant was drawn here once and no surface wanted one, so decision 104 kept
# the larger number everywhere. Inset 14 both ends. The name is the menu face
# at 17, sentence case, quoted names raw; the reading is the mono at 14.

# Flat, all the way across. These were drawn with a brighter left edge, which
# is what a selection looks like against a lit rule: the drawer had one and a
# panel does not, so on 560 points of glass it read as a brighter quarter of a
# row with an edge where the falloff ran out. Decision 105 took it out of the
# client and it comes out here.
WASH_CURSOR = "background:rgba(79,214,255,.18)"
WASH_HERE = "background:rgba(79,214,255,.07)"


def reading(text, col=READ):
    # Fourteen, which is the rung beside a name at seventeen. The sheet said
    # twelve and every settings row already read at fourteen; decision 104
    # settled it the other way, and twelve is the band label's alone.
    return (f'<span class="mono" style="font-size:14px;color:{col};'
            f'margin-left:auto">{text}</span>')


def r_caret():
    return f'<span style="margin-left:auto;display:flex">{caret()}</span>'


def r_stepper(value, down=True, up=True, lit=True):
    col = FRIEND if lit else DIM
    return (f'<span class="row" style="margin-left:auto;gap:10px">'
            f'{step_tri(-1, down)}<span class="mono" style="font-size:14px;'
            f'color:{col};min-width:18px;text-align:center">{value}</span>'
            f'{step_tri(1, up)}</span>')


def r_range(word, n, on):
    cells = "".join(
        '<span style="width:13px;height:10px;flex:none;'
        + (f'background:{FRIEND}' if k < on
           else 'border:1px solid rgba(108,122,144,.6)')
        + '"></span>' for k in range(n))
    return (f'<span class="row" style="margin-left:auto;gap:12px">'
            f'<span class="mono" style="font-size:14px;color:{READ}">{word}'
            f'</span><span class="row" style="gap:5px">{cells}</span></span>')


def r_switch(on):
    edge = f"rgba(79,214,255,.75)" if on else "rgba(63,88,120,.75)"
    fill = "rgba(79,214,255,.18)" if on else "transparent"
    knob = (f'background:{FRIEND};margin-left:auto' if on
            else f'background:{DIM};opacity:.6')
    return (f'<span style="margin-left:auto;width:34px;height:18px;flex:none;'
            f'border:1px solid {edge};background:{fill};display:flex;'
            f'align-items:center;padding:2px">'
            f'<span style="width:12px;height:12px;flex:none;{knob}"></span>'
            f'</span>')


def row(name, right="", h=44, state=None, tint=None, offer=False, dim=False,
        note=None, pad=14, name_px=17):
    wash = {"cursor": WASH_CURSOR, "here": WASH_HERE}.get(state, "")
    col = tint or (CAUTION if offer else (DIM if dim else INK))
    alpha = "opacity:.85;" if not (state or tint or offer or dim) else ""
    if note:
        h = max(h, 44) + 19
        body = (f'<span style="display:flex;flex-direction:column;gap:2px">'
                f'<span style="font-size:21px;color:{col};{alpha[:-1] or ""}'
                f'">{name}</span>'
                f'<span class="mono" style="font-size:14px;color:{READ}">'
                f'{note}</span></span>')
    else:
        body = f'<span style="font-size:{name_px}px;color:{col};{alpha}">{name}</span>'
    return (f'<div class="row" style="height:{h}px;padding:0 {pad}px;'
            f'gap:10px;{wash}">{body}{right}</div>')


def band(word):
    return ('<div style="flex:none">'
            '<div style="height:1px;background:rgba(63,88,120,.45)"></div>'
            f'<div class="row" style="height:24px;padding:0 14px">'
            f'<span class="lbl">{word}</span></div>'
            '<div style="height:1px;background:rgba(63,88,120,.45)"></div>'
            '</div>')


def head(section, foot_note=None, h=44, hot=False):
    """The head is the way back and it takes a press, so it lights like the
    control it is. It did not, and a hand walking the panel with the arrows
    could stand on it with nothing on screen saying so."""
    note = ""
    if foot_note:
        note = (f'<span style="font-size:11px;color:{READ};margin-left:auto;'
                f'font-family:var(--menu)">{foot_note}</span>')
    wash = WASH_CURSOR if hot else ""
    ink = INK if hot else MUTE
    return (f'<div class="row" style="height:{h}px;padding:0 14px;gap:10px;'
            f'flex:none;border-bottom:1px solid rgba(63,88,120,.6);{wash}">'
            f'{back_tri(1 if hot else 0.9)}'
            f'<span class="lbl" style="color:{ink}">{section}</span>'
            f'{note}</div>')


def pager_row(name, h=44):
    """The walker: the one row whose left and right arrows page a set,
    folded out of the ship panel's second head into an ordinary row."""
    return (f'<div class="row" style="height:{h}px;padding:0 14px">'
            f'{step_tri(-1)}<span style="font-size:17px;color:{FRIEND};'
            f'flex:1;text-align:center">{name}</span>{step_tri(1)}</div>')


def field_line(label, value, dimmed=False):
    col = DIM if dimmed else INK
    return (f'<div style="padding:10px 14px 0">'
            f'<div class="lbl" style="font-size:9px">{label}</div>'
            f'<div class="mono" style="font-size:14px;color:{col};height:30px;'
            f'display:flex;align-items:center;'
            f'border-bottom:1px solid rgba(63,88,120,.75)">{value}</div>'
            f'</div>')


# --- the fight behind the glass, from ../dropdown-stack ----------------------

HULLS = {
    "Wedge":   "M0,-13 L15,9 L7,12 L0,8 L-7,12 L-15,9 Z",
    "Chord":   "M0,-13 L8,-7 L17,1 L13,5 L5,2 L-5,2 L-13,5 L-17,1 L-8,-7 Z",
    "Cipher":  "M0,-22 L3,-6 L6,8 L2,12 L-2,12 L-6,8 L-3,-6 Z",
    "Anvil":   "M-8,-15 L8,-15 L13,-5 L13,6 L8,11 L-8,11 L-13,6 L-13,-5 Z",
    "Facet":   "M0,-8 L11,-1 L8,12 L-8,12 L-11,-1 Z",
}

SHIPS = [
    ("KRAIT 4",   "Wedge",  FRIEND, (0, 10),      18),
    ("VIREO 9",   "Chord",  FRIEND, (-190, 60),   62),
    ("SABER 3",   "Facet",  FRIEND, (-350, -160), 118),
    ("MANTIS 7",  "Cipher", ENEMY,  (170, -95),   205),
    ("HALCYON 2", "Anvil",  ENEMY,  (385, 65),    160),
]


def scene(w, h, seed):
    cx, cy = w / 2, h / 2
    rnd = random.Random(seed)
    parts = []
    for _ in range(16):
        x = rnd.randint(-60, w - 40)
        y = rnd.randint(-40, h - 40)
        bw, bh = rnd.choice([(96, 32), (32, 108), (64, 64), (150, 30)])
        if abs(x + bw / 2 - cx) < 260 and abs(y + bh / 2 - cy) < 200:
            continue
        parts.append(
            f'<rect x="{x}" y="{y}" width="{bw}" height="{bh}" fill="#080d16" '
            f'stroke="#22344f" stroke-width="1"/>'
            f'<path d="M{x} {y} H{x + bw}" stroke="#5b82b8" stroke-width="1.4" '
            f'opacity=".55"/>')
    parts.append(f'<path d="M{cx + 60} {cy - 32} L{cx + 76} {cy - 44}" '
                 'stroke="#f7dd0b" stroke-width="2.6" stroke-linecap="round"/>')
    for name, hull, col, (ox, oy), rot in SHIPS:
        x, y = cx + ox, cy + oy
        if not (-40 < x < w + 40 and -40 < y < h + 40):
            continue
        parts.append(
            f'<g transform="translate({x},{y}) rotate({rot})">'
            f'<path d="M-4,10 L-2,52 L2,52 L4,10 Z" fill="{col}" opacity=".16"/>'
            f'<path d="{HULLS[hull]}" fill="#0b1220" stroke="{col}" '
            f'stroke-width="1.5" stroke-linejoin="round"/></g>'
            f'<text x="{x + 16}" y="{y + 22}" fill="{col}" opacity=".9" '
            f'font-family="DejaVu Sans Mono,monospace" font-size="10">{name}'
            '</text>')
    return (f'<svg width="{w}" height="{h}" '
            f'style="position:absolute;inset:0">{"".join(parts)}</svg>')


def starfield(w, h, n, seed):
    rnd = random.Random(seed)
    out = []
    for col, r, k in (("#2a3a58", 0.9, n), ("#4a6089", 1.0, n * 2 // 3),
                      ("#93a9c8", 1.3, n // 4)):
        for _ in range(k):
            x, y = rnd.randint(0, w), rnd.randint(0, h)
            out.append(f"radial-gradient(circle {r}px at {x}px {y}px,"
                       f"{col} 0 {r}px,transparent {r}px)")
    return ",".join(out)


def score_band():
    return ('<div style="position:absolute;top:14px;left:50%;'
            'transform:translateX(-50%);display:flex;align-items:center;'
            'gap:22px">'
            f'<span class="mono" style="font-size:11px;color:{FRIEND}">PYLON'
            '</span>'
            f'<span class="mono" style="font-size:30px;color:{FRIEND}">3</span>'
            '<span class="mono" style="font-size:34px">1:47</span>'
            f'<span class="mono" style="font-size:30px;color:{ENEMY}">5</span>'
            f'<span class="mono" style="font-size:11px;color:{ENEMY}">CAISSON'
            '</span></div>')


def wrap(w, h, body, seed=9):
    return (f'<div style="position:absolute;left:0;top:0;width:{w}px;'
            f'height:{h}px;overflow:hidden;background-color:{BG};'
            f'background-image:{starfield(w, h, 40, seed)}">'
            + "".join(body) + '</div>')


# --- an exemplar: one panel standing over a fight ----------------------------

PANEL_MAX = 560


def panel(w, h, section, inner, margin=14, foot_note=None, hot=False):
    """As tall as what it holds, and no taller.

    These boards drew the whole window less its margin, which decision 103
    asked for and is right for a hull's build and absurd for three account
    acts: a head, three rows and six hundred points of empty glass over a
    fight somebody is watching. Anchored at the foot instead -- the edge it
    slides out of -- so it grows upward from there, and where its content
    outruns the room it takes the room and scrolls."""
    pw = min(w - 2 * margin, PANEL_MAX)
    left = (w - pw) / 2
    return (f'<div class="glass" style="position:absolute;left:{left:.0f}px;'
            f'width:{pw:.0f}px;bottom:{margin}px;'
            f'max-height:calc(100% - {2 * margin}px);'
            f'display:flex;flex-direction:column;overflow:hidden">'
            + head(section, foot_note, hot=hot)
            + '<div style="padding:5px 0;display:flex;flex-direction:column;'
            'min-height:0">' + "".join(inner) + '</div></div>')


def exemplar(w, h, section, inner, seed, foot_note=None, foot=None, hot=False):
    body = [scene(w, h, seed), score_band(),
            panel(w, h, section, inner, foot_note=foot_note, hot=hot)]
    if foot:
        body.append(foot)
    return wrap(w, h, body, seed)


# --- the boards --------------------------------------------------------------


def zone_board():
    inner = [
        row("Team Battle", reading("4v4 · 3 min"), state="here"),
        row("Duel", reading("1v1 · 3 min"), state="cursor"),
        row("Gauntlet", reading("coming back"), dim=True),
    ]
    return exemplar(1440, 810, "zone", inner, seed=3)


def settings_board():
    inner = [
        band("audio"),
        row("Sound", r_range("Half", 3, 2), state="cursor"),
        row("Music", r_range("Half", 3, 2)),
        band("video"),
        row("Frames", r_range("Display", 3, 1)),
        row("Fullscreen", reading("fill the screen")),
        band("the machine"),
        row("Controls", '<span class="row" style="margin-left:auto;gap:8px">'
            + f'<span class="mono" style="font-size:14px;color:{READ}">'
            'keys and pads</span>' + caret() + '</span>'),
        row("About", '<span class="row" style="margin-left:auto;gap:8px">'
            + f'<span class="mono" style="font-size:14px;color:{READ}">'
            'this build</span>' + caret() + '</span>'),
        band("ship"),
        row("Wake", r_range("Standard", 3, 1)),
        row("Charge keys", r_range("Repel first", 2, 1)),
    ]
    return exemplar(1440, 810, "settings", inner, seed=5)


def ship_board():
    bars = "".join(
        f'<span style="flex:1;display:flex;flex-direction:column;gap:5px">'
        f'<span style="height:3px;background:'
        f'linear-gradient(90deg,{FRIEND} {p}%,rgba(108,122,144,.22) {p}%)">'
        f'</span><span class="lbl" style="font-size:8.5px">{n}</span></span>'
        for n, p in (("speed", 62), ("thrust", 48), ("turn", 75),
                     ("energy", 55), ("recharge", 40)))
    credits = "".join(
        f'<span style="width:9px;height:9px;flex:none;transform:rotate(45deg);'
        + (f'background:{CAUTION}' if k < 3
           else f'background:rgba(255,209,102,.18)') + '"></span>'
        for k in range(7))
    inner = [
        pager_row("Apex"),
        (f'<div class="row" style="height:34px;padding:0 14px;gap:6px">'
         f'{bars}</div>'),
        (f'<div class="row" style="height:30px;padding:0 14px">'
         f'<span class="lbl" style="color:rgba(255,209,102,.8)">'
         f'build credits</span>'
         f'<span class="row" style="margin-left:auto;gap:6px">{credits}'
         f'</span></div>'),
        band("gun"),
        row("Rung", r_stepper(1), state="cursor"),
        row("Spray", r_stepper(1)),
        row("Bounce", r_switch(False)),
        band("bomb"),
        # The one row whose figure is not what it cost. Shrapnel's magnitude
        # is another weapon: a rung throws four fragments and the rungs above
        # climb by two, so a pilot spending a credit is choosing between four
        # in the air and six. It read the rung until decision 105.
        row("Shrapnel", r_stepper(4)),
        row("Proximity detonation", r_switch(True)),
        band("rack"),
        row("Repel", r_stepper(2)),
        row("Burst", r_stepper(1, lit=True)),
        row("Reset", "", dim=True),
    ]
    return exemplar(1440, 810, "ship", inner, seed=7,
                    foot_note="enter flies it")


def login_board():
    inner = [
        # Where the fleet's reply lands. It used to replace the head, which on
        # a card is the whole point and on a panel costs a pilot the section
        # name and the label on the way back, exactly when a press has just
        # failed. Decision 105 put it here, in the caution color, superseding
        # whatever note the panel carried.
        (f'<div style="padding:12px 14px 2px;font-size:14px;color:{CAUTION}">'
         'That password is too short.</div>'),
        field_line("call sign", "Vesper 412"),
        field_line("password", "&middot;" * 6, dimmed=True),
        ('<div style="padding:14px 14px 10px">'
         '<div class="play" style="height:50px;font-size:15px">LOG IN</div>'
         '</div>'),
    ]
    return exemplar(1440, 810, "log in", inner, seed=11)


def phone_board():
    inner = [
        band("audio"),
        row("Sound", r_range("Half", 3, 2), state="cursor"),
        row("Music", r_range("Half", 3, 2)),
        band("video"),
        row("Frames", r_range("Display", 3, 1)),
        row("Fullscreen", reading("fill the screen")),
        band("the machine"),
        row("Controls", r_caret()),
        row("About", r_caret()),
        band("ship"),
        row("Wake", r_range("Standard", 3, 1)),
        row("Charge keys", r_range("Repel first", 2, 1)),
    ]
    body = [scene(390, 844, 13), panel(390, 844, "settings", inner, margin=12)]
    return wrap(390, 844, body, 13)


def alt_voice_board():
    """The road not taken: the zone panel keeping today's HUD voice, so
    the choice between the two registers is a thing to look at rather
    than a sentence to trust."""
    def hud_row(name, note, state=None, dim=False):
        wash = {"cursor": WASH_CURSOR, "here": WASH_HERE}.get(state, "")
        col = DIM if dim else (FRIEND if state == "here" else READ)
        return (f'<div class="row" style="height:44px;padding:0 14px;{wash}">'
                f'<span class="mono" style="font-size:12px;'
                f'letter-spacing:.06em;color:{col}">{name}</span>'
                f'{reading(note)}</div>')
    inner = [
        hud_row("Team Battle", "4v4 · 3 min", state="here"),
        hud_row("Duel", "1v1 · 3 min", state="cursor"),
        hud_row("Gauntlet", "coming back", dim=True),
    ]
    return exemplar(1440, 810, "zone", inner, seed=3)


# --- the language sheet ------------------------------------------------------


def spec_h(title, note=""):
    n = (f'<div style="font-size:13px;color:{READ};max-width:640px;'
         f'line-height:1.45">{note}</div>') if note else ""
    return (f'<div style="display:flex;flex-direction:column;gap:6px;'
            f'margin:34px 0 14px">'
            f'<div class="lbl" style="color:{FRIEND};font-size:11px">{title}'
            f'</div>{n}</div>')


def chip(label):
    return (f'<span class="lbl" style="font-size:9px;letter-spacing:.08em;'
            f'color:{DIM}">{label}</span>')


def demo(width, inner_html, label):
    return (f'<div style="display:flex;flex-direction:column;gap:7px">'
            f'<div class="glass" style="width:{width}px;display:flex;'
            f'flex-direction:column">{inner_html}</div>{chip(label)}</div>')


def swatch(col, name, sub):
    return (f'<div style="display:flex;flex-direction:column;gap:6px;'
            f'width:118px"><div style="height:34px;background:{col};'
            f'border:1px solid rgba(63,88,120,.5)"></div>'
            f'<div class="mono" style="font-size:11px;color:{INK}">{name}'
            f'</div><div class="mono" style="font-size:10px;color:{DIM}">'
            f'{sub}</div></div>')


def stack_diagram():
    """Three little screens: the column, a panel, a stacked panel. The
    movement decision 103 shipped, said as the language's one motion."""
    def mini(parts):
        return (f'<div style="width:150px;height:96px;position:relative;'
                f'background:{BG};border:1px solid rgba(63,88,120,.5);'
                f'overflow:hidden">{parts}</div>')
    stops = "".join(
        f'<div style="position:absolute;left:38px;width:74px;height:9px;'
        f'bottom:{b}px;border:1px solid rgba(63,88,120,.9)"></div>'
        for b in (34, 22))
    key = ('<div style="position:absolute;left:38px;width:74px;height:12px;'
           'bottom:6px;border:1px solid rgba(79,214,255,.7)"></div>')
    # A panel is as tall as what it holds and stands on the edge it slid out
    # of, so these two are different heights on purpose: a stack that opens
    # something shorter slides the glass down to fit it.
    pan = ('<div style="position:absolute;left:10px;right:10px;top:30px;'
           'bottom:8px;border:1px solid rgba(63,88,120,.9);'
           'background:rgba(10,15,24,.72)">'
           '<div style="height:12px;border-bottom:1px solid '
           'rgba(63,88,120,.6)"></div></div>')
    pan2 = ('<div style="position:absolute;left:10px;right:10px;top:52px;'
            'bottom:8px;border:1px solid rgba(79,214,255,.5);'
            'background:rgba(10,15,24,.85)">'
            '<div style="height:12px;border-bottom:1px solid '
            'rgba(63,88,120,.6)"></div></div>')
    arrow = (f'<svg width="26" height="12" viewBox="0 0 26 12" '
             f'style="flex:none"><path d="M0 6 H18 M18 6 L12 1.5 M18 6 L12 '
             f'10.5" stroke="{DIM}" stroke-width="1.4" fill="none"/></svg>')
    return (f'<div class="row" style="gap:12px">'
            f'<div style="display:flex;flex-direction:column;gap:7px">'
            f'{mini(stops + key)}{chip("the column")}</div>{arrow}'
            f'<div style="display:flex;flex-direction:column;gap:7px">'
            f'{mini(pan)}{chip("a stop opens: as tall as it needs, 560 cap")}</div>'
            f'{arrow}'
            f'<div style="display:flex;flex-direction:column;gap:7px">'
            f'{mini(pan + pan2)}{chip("a row opens: it stacks, sliding to the new height")}</div></div>')


def main_board():
    W = 1180
    parts = [f'''
<div style="padding:44px 48px 56px">
  <div class="lbl" style="font-size:11px;color:{DIM}">vectorwake</div>
  <div style="font-size:34px;margin-top:6px">The menu language</div>
  <div style="font-size:15px;color:{READ};max-width:660px;margin-top:10px;
       line-height:1.5">Everything is a panel. A panel is rows. A row is one
    shape. Decision 103 gave every menu one container; this gives the
    container one interior, so walking from the games list into settings
    into a ship no longer changes dialect.</div>
''']

    # -- 1 the voice --
    parts.append(spec_h("1 · The voice",
        "The menu <b>speaks</b> in the menu face, sentence case, 17. It "
        "<b>reads</b> in the mono at 14. It <b>quotes</b> a name in the case "
        "its owner gave it. Capitals belong to the HUD and to the small "
        "labels, never to a row. The type ladder is the shipped one: "
        "12 · 14 · 17 · 21, and nothing between rungs."))
    parts.append(f'''
  <div class="row" style="gap:44px;align-items:flex-start">
    <div style="display:flex;flex-direction:column;gap:9px">
      <span style="font-size:17px">Charge keys</span>{chip("speaks · menu 17")}
    </div>
    <div style="display:flex;flex-direction:column;gap:9px">
      <span style="font-size:17px">Team Battle</span>{chip("quotes · raw case")}
    </div>
    <div style="display:flex;flex-direction:column;gap:9px">
      <span class="mono" style="font-size:14px;color:{READ}">4v4 · 3 min</span>
      {chip("reads · mono 14")}
    </div>
    <div style="display:flex;flex-direction:column;gap:9px">
      <span class="lbl">the machine</span>{chip("labels · mono 12 caps")}
    </div>
    <div style="display:flex;flex-direction:column;gap:9px">
      <span style="font-size:21px">Sign up</span>{chip("heads a note · 21")}
    </div>
  </div>''')

    # -- 2 the glass --
    parts.append(spec_h("2 · The glass",
        "One ground for every surface: the fight blurred, the button tint "
        "at 0.72 over it, one tile-colored outline. Capped at 560 wide, "
        "centered, and as tall as what it holds -- standing on the bottom "
        "margin it slid out of, taking the room and scrolling only where its "
        "content outruns it. Cards are not exempt: a card is a panel that "
        "stacked. Two washes say where a hand is, flat across the row: the "
        "cursor at 0.18 and where you already are at 0.07, friend color both."))
    parts.append(f'''
  <div class="row" style="gap:22px;align-items:flex-start;flex-wrap:wrap">
    {swatch("rgba(10,15,24,.72)", "the glass", "frost + 0a0f18 at .72")}
    {swatch("rgba(63,88,120,.75)", "the edge", "3f5878 at .75")}
    {swatch("rgba(79,214,255,.18)", "cursor", "4fd6ff at .18")}
    {swatch("rgba(79,214,255,.07)", "here", "4fd6ff at .07")}
    {swatch(CAUTION, "the offer", "ffd166 · and the dot")}
    {swatch("rgba(108,122,144,.5)", "dimmed", "a row that cannot act")}
  </div>''')

    # -- 3 the row --
    parts.append(spec_h("3 · The row",
        "44 points tall, which is the touch floor, and there is no second "
        "height: a dense variant was drawn here and no surface wanted one. "
        "14 in from either edge. The name at the left; what stands "
        "at the right end is what the row <b>does</b>, and it is the only "
        "thing that varies. Six ends, and every menu is spelled with them."))
    rows_w = 470
    parts.append(f'''
  <div style="display:grid;grid-template-columns:repeat(2, minmax(0, 1fr));
       gap:20px 40px;max-width:{rows_w * 2 + 40}px">
    {demo(rows_w, row("Duel", r_caret()), "opens · the caret promises a panel")}
    {demo(rows_w, row("Fullscreen", reading("fill the screen")),
          "reads · a value with no control")}
    {demo(rows_w, row("Repel", r_stepper(2)), "steps · arrows spend and refund")}
    {demo(rows_w, row("Sound", r_range("Half", 3, 2)),
          "fills · one cell per step, the word beside it")}
    {demo(rows_w, row("Bounce", r_switch(True)),
          "switches · lit right for on; enter and space flip it")}
    {demo(rows_w, pager_row("Apex"), "walks · arrows at the edges page a set")}
  </div>''')

    parts.append(spec_h("states",
        "The same row under each thing that can be true of it. A row wearing "
        "a side is written in that side's color; the one row that is an "
        "offer wears the caution color, the same hue as the dot it answers."))
    parts.append(f'''
  <div style="display:grid;grid-template-columns:repeat(2, minmax(0, 1fr));
       gap:20px 40px;max-width:{rows_w * 2 + 40}px">
    {demo(rows_w, row("Duel", r_caret(), state="cursor"),
          "the cursor · 0.18 flat, from either hand")}
    {demo(rows_w, row("Team Battle", reading("4v4 · 3 min"), state="here"),
          "here · 0.07, where you already are")}
    {demo(rows_w, row("Sign up", reading("keep your points", READ),
                      offer=True), "the offer · caution color")}
    {demo(rows_w, row("Gauntlet", reading("coming back"), dim=True),
          "dimmed · publishes no press")}
    {demo(rows_w, row("Pylon", reading("8 · yours"), tint=FRIEND),
          "a side · written in its own color")}
    {demo(rows_w, row("Apex", "", note="Turns on a wingtip, thin armor"),
          "carries a note · name to 21, note under")}
    {demo(rows_w, row("Shrapnel", r_stepper(4)),
          "reads what it throws · not what it cost")}
  </div>''')

    # -- 4 the head and the band --
    parts.append(spec_h("4 · The head and the band",
        "Every panel heads itself once: the way back and the section's name, "
        "and nothing else lives on that line but a short standing sentence "
        "at the right. Groups inside a panel get the band: a label between "
        "two rules, 24 tall. The ship page's second head is gone; what it "
        "held is the walker row."))
    parts.append(f'''
  <div style="display:grid;grid-template-columns:repeat(2, minmax(0, 1fr));
       gap:20px 40px;max-width:{rows_w * 2 + 40}px">
    {demo(rows_w, head("settings"), "the head · the whole line is the press")}
    {demo(rows_w, head("settings", hot=True),
          "and it lights, like the control it is")}
    {demo(rows_w, head("ship", foot_note="enter flies it"),
          "with its one sentence")}
  </div>
  <div style="height:20px"></div>
  {demo(rows_w, band("audio") + row("Sound", r_range("Half", 3, 2)),
        "the band · 24, label between rules")}''')

    # -- 5 the key --
    parts.append(spec_h("5 · The key",
        "One breathing key per screen, and it is the commit: PLAY NOW, "
        "RESUME, LOG IN. It sits at the foot of whatever it commits. "
        "Everything else pressable is either a row or a chip, and a chip is "
        "the mono in a plain outline."))
    parts.append(f'''
  <div class="row" style="gap:40px;align-items:center">
    <div style="display:flex;flex-direction:column;gap:7px">
      <div class="play" style="width:320px;height:50px;font-size:16px">
        PLAY NOW</div>{chip("the commit · one per screen, breathing")}
    </div>
    <div style="display:flex;flex-direction:column;gap:7px">
      <div class="key" style="height:26px;padding:0 10px;font-size:11px">
        PLAYERS</div>{chip("a chip · quoted, secondary")}
    </div>
  </div>''')

    # -- 6 the motion --
    parts.append(spec_h("6 · The motion",
        "One movement: press a stop and the column goes out through the "
        "bottom edge while the panel comes up through it; press a row that "
        "opens and the next panel rides the same slide over this one; back "
        "steps one level out. A panel arrives at the height it wants and "
        "eases to a new one when what it holds changes, so a stack slides to "
        "fit rather than swapping two rectangles. Nothing pauses behind it."))
    parts.append(stack_diagram())

    parts.append('</div>')
    return (f'<div style="position:relative;width:{W}px;background-color:{BG};'
            f'background-image:{starfield(W, 1980, 26, 21)}">'
            + "".join(parts) + '</div>')


# --- assembly ----------------------------------------------------------------


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
    page("Main", main_board())
    page("Zone", zone_board())
    page("Settings", settings_board())
    page("Ship", ship_board())
    page("LogIn", login_board())
    page("Phone", phone_board())
    page("AltVoice", alt_voice_board())
    print("seven artboards written")


if __name__ == "__main__":
    main()
