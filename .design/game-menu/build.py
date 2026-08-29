#!/usr/bin/env python3
# The game menu: the drawer dies, the landing keeps saying only who, where
# and what, and settings lives in the match, which is the only place it is
# available at all. What a seated pilot needs from a menu is exactly three
# things: the way out of the seat, which side it is on, and settings. These
# boards brainstorm the menu that holds them, for mouse, keyboard,
# controller and touch alike.
#
# The column's row, as it stands after the iterations: the menu key is
# small and faint at the bottom middle, exactly where the column will
# stand, and the tap slides the column up out of that edge.
#
#   MenuKey      the match at rest, the faint key at the bottom middle
#   MidSlide     the column on its way up, one frame for the motion
#   Main         the column standing: SIDE, SETTINGS, LEAVE over a
#                breathing RESUME, the fight thin-washed behind
#   SettingsOpen the settings stop open, the panel climbing from it the
#                way the ship pager climbs at home
#   Phone(...)   the same three states on a 390 glass
#
# And the explorations kept beside it:
#
#   CornerPanel  a corner key docks a panel on the left and the fight
#   CornerPhone  stays live and undimmed beside it; side as a list
#   CenterCard   the classic: a compact pause card, four rows
#   Radial       hold the key and four choices ring the ship
#
# Chrome and hues are the client's own, in the manner of ../ship-kit/build.py
# and ../no-drawer/build.py: the row states of decision 72, the ship panel's
# banded sections, the stops and PLAY NOW of decision 89.
import math
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
.key{display:inline-flex;align-items:center;justify-content:center;gap:6px;
  border:1px solid rgba(63,88,120,.75);background:rgba(10,15,24,.6);
  font-family:var(--mono);text-transform:uppercase;letter-spacing:.06em;
  color:#9fb6d4}
.mono{font-family:var(--mono)}
.note{font-family:var(--mono);font-size:10px;color:var(--dim)}
.field{display:flex;align-items:center;justify-content:space-between;
  border:1px solid rgba(63,88,120,.75);background:rgba(8,12,20,.66);
  font-family:var(--mono);text-transform:uppercase;letter-spacing:.06em;
  padding:0 12px;color:var(--ink)}
@keyframes breath{
  0%,100%{background:rgba(79,214,255,.06);border-color:rgba(79,214,255,.62)}
  50%{background:rgba(79,214,255,.18);border-color:rgba(79,214,255,1)}
}
.play{display:flex;align-items:center;justify-content:center;
  border:1.6px solid rgba(79,214,255,.62);
  animation:breath 2.42s ease-in-out infinite;
  font-family:var(--mono);letter-spacing:.14em;color:var(--ink)}
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


# ---- the lit field, decision 72 ----
def field(a):
    lo = a * 0.8
    hi = a * 0.8 + a * 0.6
    return (f"background:linear-gradient(90deg,rgba(79,214,255,{hi:.3f}),"
            f"rgba(79,214,255,{lo:.3f}) 130px,rgba(79,214,255,{lo:.3f}));")


CURSOR = field(0.18)

RULE = '<div style="border-top:1px solid rgba(63,88,120,.45)"></div>'


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


# ---- hull outlines, to the extents in docs/design/ships.md ----
HULLS = {
    "Apex":    "M0,-20 L6,-3 L10,7 L4,5 L2,11 L-2,11 L-4,5 L-10,7 L-6,-3 Z",
    "Wedge":   "M0,-13 L15,9 L7,12 L0,8 L-7,12 L-15,9 Z",
    "Cipher":  "M0,-22 L3,-6 L6,8 L2,12 L-2,12 L-6,8 L-3,-6 Z",
    "Facet":   "M0,-8 L11,-1 L8,12 L-8,12 L-11,-1 Z",
}


def scene(w, h):
    hulls = [("Wedge", 0.24, 0.32, 24, "#4fd6ff"),
             ("Cipher", 0.78, 0.62, 205, "#ffa552"),
             ("Facet", 0.71, 0.20, 320, "#ffa552"),
             ("Apex", 0.30, 0.74, 100, "#4fd6ff")]
    parts = []
    for name, fx, fy, rot, col in hulls:
        parts.append(
            f'<g transform="translate({int(fx * w)},{int(fy * h)}) '
            f'rotate({rot})">'
            f'<path d="M-4,10 L-2,44 L2,44 L4,10 Z" fill="{col}" '
            'opacity=".16"/>'
            f'<path d="{HULLS[name]}" fill="#0b1220" stroke="{col}" '
            'stroke-width="1.5" stroke-linejoin="round"/></g>')
    parts.append(f'<rect x="{int(0.45 * w)}" y="{int(0.16 * h)}" width="30" '
                 'height="110" fill="#080d16" stroke="#22344f"/>'
                 f'<path d="M{int(0.45 * w)} {int(0.16 * h)} '
                 f'H{int(0.45 * w) + 30}" stroke="#5b82b8" '
                 'stroke-width="1.4" opacity=".55"/>')
    return (f'<svg width="{w}" height="{h}" '
            f'style="position:absolute;inset:0">{"".join(parts)}</svg>')


# ---- the lockup, verbatim from docs/banner.svg ----
MARK_PATHS = (
    '<path fill="#ff9d22" d="M42 0L84 67L66 78L42 53L18 78L0 67Z"/>'
    '<path fill="#27c5ed" d="M0 67L18 78L42 53L66 78L84 67L60 103L42 74L24 103Z"/>'
    '<path fill="none" stroke="#000" stroke-width="3" stroke-linecap="square" '
    'stroke-linejoin="miter" d="M0 67L18 78L42 53L66 78L84 67"/>'
)

WORD_PATH = (
    '<path transform="translate(424.175,144.9)" d="M1 -49.8H10.6L24.4 -10H24.8L38.5 '
    '-49.8H48.1L29.6 0H19.6ZM54.1 -9.5V-40.2L63.7 -49.8H89.8L99.4 -40.2V-22H63.4V-12.4'
    'L67.8 -8H85.7L90.1 -12.3V-15.7H99.3V-9.5L89.9 0H63.6ZM90.1 -29.3V-37.4L85.6 -41.8'
    'H67.9L63.4 -37.4V-29.3ZM110.9 -9.5V-40.3L120.4 -49.8H145.5L155.1 -40.2V-33.1H145.8'
    'V-37.2L141.3 -41.7H124.7L120.2 -37.2V-12.6L124.7 -8.1H141.3L145.8 -12.6V-16.7H155.1'
    'V-9.6L145.5 0H120.4ZM170.6 -9.5V-41.8H161.6V-49.8H170.8V-66H179.9V-49.8H195.4V-41.7'
    'H179.9V-12.5L184.4 -8.1H195.4V0H180.2ZM203.4 -9.6V-40.2L213 -49.8H239.6L249.1 -40.2'
    'V-9.6L239.6 0H213ZM235.3 -8.1 239.8 -12.5V-37.3L235.3 -41.7H217.2L212.7 -37.3V-12.5'
    'L217.2 -8.1ZM262.1 -49.8H271V-41.1L279.6 -49.8H292.9V-41.7H281.7L271.4 -31.3V0H262.1'
    'ZM297.4 -49.8H306.9L314.5 -11.7H314.8L325.8 -49.8H334.6L344.7 -11.7H345L353.3 -49.8'
    'H362.8L350.1 0H340.7L330.3 -38.6H330L318.7 0H309.2ZM369.3 -8.5V-20.8L377.8 -29.3H404'
    'V-37.7L399.6 -42H383.3L379 -37.7V-34H369.7V-40.1L379.4 -49.8H403.5L413.2 -40.1V0'
    'H404.5V-8.2L395.9 0H377.8ZM394.6 -7.7 404 -16.7V-21.9H382.1L378.6 -18.4V-11.1L382.1 '
    '-7.7ZM426.7 -71.4H436V-30H446.7L460.7 -49.8H471L454.3 -25.8L472 0H461.7L446.6 -21.8'
    'H436V0H426.7ZM477 -9.5V-40.2L486.6 -49.8H512.7L522.3 -40.2V-22H486.3V-12.4L490.7 '
    '-8H508.6L513 -12.3V-15.7H522.2V-9.5L512.8 0H486.5ZM513 -29.3V-37.4L508.5 -41.8'
    'H490.8L486.3 -37.4V-29.3Z" fill="#dfe9f5"/>'
)


def lockup(w):
    h = round(w * 88 / 616)
    return (f'<svg width="{w}" height="{h}" viewBox="332 71 616 88" '
            f'style="display:block">'
            f'<g transform="translate(334.975 83) scale(.7115)">{MARK_PATHS}</g>'
            f'{WORD_PATH}</svg>')


def caret(col="#9fb6d4"):
    return ('<svg width="9" height="9" viewBox="0 0 10 10" fill="none" '
            f'style="flex:none"><path d="M1.5 3 L5 7 L8.5 3" stroke="{col}" '
            'stroke-width="1.4" stroke-linecap="square"/></svg>')


def go_mark(col="#9fb6d4"):
    """A row that opens something deeper: the caret lying on its side."""
    return ('<svg width="9" height="9" viewBox="0 0 10 10" fill="none" '
            f'style="flex:none"><path d="M3 1.5 L7 5 L3 8.5" stroke="{col}" '
            'stroke-width="1.4" stroke-linecap="square"/></svg>')


def tri(direction, on=True):
    a = ".9" if on else ".25"
    pts = ("2,6 9,1.5 9,10.5" if direction < 0 else "9,6 2,1.5 2,10.5")
    return (f'<svg width="11" height="12" viewBox="0 0 11 12" '
            f'style="flex:none"><polygon points="{pts}" '
            f'fill="rgba(79,214,255,{a})"/></svg>')


# The rail's own settings icon: the mixer, three lines with a knob apiece.
def mixer(col="#9fb6d4", k=15):
    return (f'<svg width="{k}" height="{k}" viewBox="0 0 16 16" fill="none" '
            f'stroke="{col}" stroke-width="1.3" style="flex:none">'
            '<path d="M2 4.5 H14 M2 8 H14 M2 11.5 H14"/>'
            '<circle cx="10.5" cy="4.5" r="1.8" fill="#0a0f18"/>'
            '<circle cx="5.5" cy="8" r="1.8" fill="#0a0f18"/>'
            '<circle cx="9.5" cy="11.5" r="1.8" fill="#0a0f18"/></svg>')


# ---- the landing's stops, decision 89's column ----
def land_stop(label, value, lit=False, w=320, h=36):
    edge = "border-color:rgba(79,214,255,.85);" if lit else ""
    return (f'<div class="field" style="width:{w}px;height:{h}px;{edge}">'
            f'<span class="lbl">{label}</span>'
            f'<span class="row" style="gap:9px;font-size:12px">{value}'
            + caret() + '</span></div>')


def column(stops, lit=None, kw=320, bottom=22, go="RESUME"):
    """The stops over the breathing key, bottom-up: the landing column's
    grammar, carried into the match. No lockup here; the fight is the
    backdrop."""
    out = ['<div style="position:absolute;left:50%;transform:translateX(-50%);'
           f'bottom:{bottom}px;display:flex;flex-direction:column-reverse;'
           'gap:8px;align-items:center">'
           f'<div class="play" style="width:{kw}px;height:54px;'
           f'font-size:19px;margin-top:12px;order:-1">{go}</div>']
    for label, value in stops:
        out.append(land_stop(label, value, lit == label, w=kw))
    out.append('</div>')
    return "".join(out)


# ---- the settings rows themselves ----
def pips(n, on):
    cells = "".join(
        '<span style="width:13px;height:10px;flex:none;'
        + ('background:#4fd6ff'
           if k < on else 'border:1px solid rgba(108,122,144,.6)')
        + '"></span>' for k in range(n))
    return '<div class="row" style="gap:5px">' + cells + '</div>'


def band(label):
    return ('<div style="margin:8px -14px 0">' + RULE
            + f'<div class="lbl" style="padding:6px 20px">{label}</div>'
            + RULE + '</div>')


def srow(label, right, state=None, h=36):
    hot = state == "cursor"
    wash = CURSOR if hot else ""
    return (f'<div style="margin:0 -14px;padding:0 20px;{wash}">'
            f'<div class="row" style="height:{h}px;gap:12px">'
            f'<span style="font-size:14px;color:rgba(223,233,245,'
            f'{1 if hot else 0.85})">{label}</span>'
            '<div style="flex:1"></div>' + right + '</div></div>')


def val(text, col="#8593a9"):
    return f'<span class="mono" style="font-size:11.5px;color:{col}">{text}</span>'


def stepper(text):
    return ('<span class="row" style="gap:8px">' + tri(-1)
            + f'<span class="mono" style="font-size:11.5px;color:#4fd6ff">'
            f'{text}</span>' + tri(1) + '</span>')


def settings_rows(cursor="sound"):
    """The whole of what the drawer holds at home, as one panel: the
    settings page's rows, the two ship preferences, and the two pages
    (controls, about) as rows that open in place with a way back."""
    return (
        band("audio")
        + srow("Sound", pips(4, 3), state="cursor" if cursor == "sound" else None)
        + srow("Music", pips(3, 1))
        + band("video")
        + srow("Frames", val("as the display asks"))
        + srow("Fullscreen", val("fill the screen"))
        + srow("Add to home screen", val("one tap"))
        + band("ship")
        + srow("Wake", stepper("standard"))
        + srow("Charge keys", stepper("repel first"))
        + band("")
        + srow("Controls", '<span class="row" style="gap:8px">'
               + val("24 keys") + go_mark() + '</span>')
        + srow("About", '<span class="row" style="gap:8px">'
               + val("build 029d1c3") + go_mark() + '</span>')
        + srow("Reset to defaults", "")
    )


# The menu button, verbatim from `burger_cap` in client/arena/ui.lua: a key
# box holding three bars, the word MENU beside them on a desktop, the mark
# alone on a phone. Dim at rest, friend blue while the panel it opens is
# standing.
def burger(col, k=13):
    bars = "".join(
        f'<span style="width:{k}px;height:1.8px;background:{col};'
        'flex:none"></span>' for _ in range(3))
    return ('<span style="display:inline-flex;flex-direction:column;'
            'gap:2.6px;flex:none">' + bars + '</span>')


def corner_key(lit=False, word=True, x=14, y=14):
    if lit:
        edge = ("border-color:rgba(79,214,255,.95);"
                "background:rgba(79,214,255,.16);")
        ink = "#4fd6ff"
    else:
        edge = ("border-color:rgba(108,122,144,.55);"
                "background:rgba(108,122,144,.07);")
        ink = "rgba(159,182,212,.85)"
    label = (f'<span style="font-size:11px;color:{ink}">MENU</span>'
             if word else "")
    pad = "0 9px" if word else "0 6px"
    return (f'<div class="key" style="position:absolute;left:{x}px;'
            f'top:{y}px;height:26px;padding:{pad};{edge}">'
            + burger(ink) + label + '</div>')


def players_key(x=14, y=14):
    """MENU's neighbor in the corner row, here so the button is seen in
    its own company rather than alone."""
    return (f'<div class="key" style="position:absolute;left:{x}px;'
            f'top:{y}px;height:26px;padding:0 9px;font-size:11px;'
            'border-color:rgba(108,122,144,.55);'
            'background:rgba(108,122,144,.07);'
            'color:rgba(159,182,212,.85)">PLAYERS</div>')


def board(w, h, parts):
    return (f'<div style="position:relative;width:{w}px;height:{h}px;'
            f'overflow:hidden;{stars(w, h)}">' + scene(w, h)
            + "".join(parts) + '</div>')


STOP_ROWS = [("SIDE", "PYLON"),
             ("SETTINGS", mixer("#8593a9", 13)),
             ("LEAVE", "TO THE STANDS")]

# Thin on purpose: nothing pauses in a shared arena, the column only takes
# the controls, so the fight underneath stays watchable while it stands.
DIM = ('<div style="position:absolute;inset:0;'
       'background:rgba(5,7,12,.42)"></div>')


def hud(three=False):
    """The score band and a radar, said small: this is a fight, not a
    front page. `three` adds a third side, for the boards whose point is
    a zone holding more than two."""
    tail = ('<span class="mono" style="font-size:30px;color:#ffa552">4'
            '</span>'
            '<span class="mono" style="font-size:11px;color:#ffa552">'
            'MERIDIAN</span>') if three else ''
    return [
        '<div style="position:absolute;top:14px;left:50%;'
        'transform:translateX(-50%);display:flex;align-items:center;'
        'gap:22px">'
        '<span class="mono" style="font-size:11px;color:#4fd6ff">PYLON</span>'
        '<span class="mono" style="font-size:30px;color:#4fd6ff">3</span>'
        '<span class="mono" style="font-size:34px">1:47</span>'
        '<span class="mono" style="font-size:30px;color:#ffa552">5</span>'
        '<span class="mono" style="font-size:11px;color:#ffa552">CAISSON</span>'
        + tail + '</div>',
        '<div style="position:absolute;right:14px;top:14px;width:168px;'
        'height:168px;background:rgba(6,10,16,.55);border:1px solid '
        'rgba(63,88,120,.5)"></div>',
    ]


# The column's own button: small and faint at the bottom middle, standing
# exactly where the column will stand, so the tap and what it summons
# share a spot. Pressing it slides the column up out of that edge, and
# RESUME ends up breathing on the very pixels the key occupied; pressing
# RESUME hands the spot back to the key. Faint on purpose: it lives
# inside the fight, so at rest it is furniture, not a control demanding
# to be read.
def bottom_key(bottom=14):
    ink = "rgba(159,182,212,.5)"
    return (f'<div class="key" style="position:absolute;left:50%;'
            f'transform:translateX(-50%);bottom:{bottom}px;height:22px;'
            'padding:0 8px;border-color:rgba(108,122,144,.35);'
            'background:rgba(108,122,144,.05)">' + burger(ink, 11)
            + '</div>')


# ============== Main: the pause takeover, column grammar ==============
#
# The landing column, carried into the match, standing where its key
# stood. Dim the fight, keep it visible, and say the three things a seat
# can want the way the landing says who, where and what: stops at the
# column's width, the breathing key at the bottom, leave farthest from
# the thumb that resumes.
def pause_board():
    parts = hud() + [
        DIM,
        column(STOP_ROWS),
    ]
    write("Main.dc.html", board(1440, 810, parts))


# ============ MidSlide: the column on its way up ============
#
# The moment between the tap and the menu: the column rising out of the
# bottom edge where the key sat, LEAVE first because LEAVE lives at the
# top. One drawn frame standing in for the motion; the wash fades in
# with it.
def mid_slide_board():
    parts = hud() + [
        '<div style="position:absolute;inset:0;'
        'background:rgba(5,7,12,.24)"></div>',
        column(STOP_ROWS, bottom=-118),
    ]
    write("MidSlide.dc.html", board(1440, 810, parts))


# =========== SettingsOpen: the same pause, the stop opened ===========
#
# The settings stop opens the way the ship stop opens at home: a panel at
# the column's width climbing from its row. This is the only place
# settings exists, so the panel is the drawer's whole settings page,
# bands and all.
def settings_open_board():
    parts = hud() + [
        DIM,
        column(STOP_ROWS, lit="SETTINGS"),
        '<div style="position:absolute;left:50%;'
        'transform:translateX(-50%);bottom:184px;width:320px;'
        'background:#070b12;border:1px solid rgba(63,88,120,.85);'
        'padding:0 14px 10px;z-index:5">' + settings_rows() + '</div>',
    ]
    write("SettingsOpen.dc.html", board(1440, 810, parts))


# ============= CornerPanel: the docked panel, fight live =============
#
# The corner key docks a panel on the left and the match keeps running
# undimmed beside it. Nothing is hidden while the menu stands.
#
# Side is a list rather than a stepper, because a stepper walks: in a
# zone holding more than two sides, arrows would drag a pilot through
# every team between here and the one they want. A row per side says
# them all at once, marks the one you fly for, and any other is one
# press. The counts are what you weigh when you switch, so they ride
# along; the board holds three sides so the reason is visible.
def side_rows(cursor=None):
    sides = [("Pylon", "#4fd6ff", "8 &middot; yours"),
             ("Caisson", "#ffa552", "7"),
             ("Meridian", "#ffa552", "6")]
    out = band("side")
    for name, col, right in sides:
        out += srow(f'<span style="color:{col}">{name}</span>', val(right),
                    state="cursor" if cursor == name else None)
    return out


def corner_panel_rows(cursor="Meridian"):
    return (
        srow("Leave", '<span class="key" style="height:24px;padding:0 11px;'
             'font-size:10px">to the stands</span>')
        + side_rows(cursor=cursor)
        + settings_rows(cursor=None)
    )


def corner_panel_board():
    parts = hud(three=True) + [
        corner_key(lit=True),
        '<div style="position:absolute;left:14px;top:48px;width:300px;'
        'background:#070b12;border:1px solid rgba(63,88,120,.85);'
        'padding:0 14px 10px;z-index:5">' + corner_panel_rows() + '</div>',
    ]
    write("CornerPanel.dc.html", board(1440, 810, parts))


# ============== CornerPhone: the same panel under a thumb ==============
#
# The panel at a phone's width: 300 on a 390 glass leaves a strip of the
# fight showing, which is the direction's promise kept even here. The
# stray-thumb worry lives on this board too: everything to the right of
# the panel is live game.
def corner_phone_board():
    parts = hud_phone() + [
        corner_key(lit=True, word=False, x=12, y=12),
        '<div style="position:absolute;left:12px;top:46px;width:300px;'
        'background:#070b12;border:1px solid rgba(63,88,120,.85);'
        'padding:0 14px 10px;z-index:5">' + corner_panel_rows() + '</div>',
    ]
    write("CornerPhone.dc.html", board(390, 844, parts))


# ================= CenterCard: the classic pause card =================
#
# Four rows in the middle of a dimmed screen, the shape every console
# game has taught. Settings is a row that opens a second page in place;
# the caret on its side says so.
def center_card_board():
    card = (
        srow("Resume", "", state="cursor", h=40)
        + srow("Side", stepper("Pylon"), h=40)
        + srow("Settings", '<span class="row" style="gap:8px">'
               + mixer("#8593a9", 13) + go_mark() + '</span>', h=40)
        + srow("Leave", val("to the stands"), h=40)
    )
    parts = hud() + [
        DIM,
        corner_key(lit=True),
        '<div style="position:absolute;left:50%;top:46%;'
        'transform:translate(-50%,-50%);width:340px;'
        'background:#070b12;border:1px solid rgba(63,88,120,.85);'
        'padding:6px 14px;z-index:5">' + card + '</div>',
    ]
    write("CenterCard.dc.html", board(1440, 810, parts))


# =================== Radial: hold, and flick toward ===================
#
# Hold the key and four choices ring your own ship; flick toward one and
# let go. Fastest on a stick or a thumb, invisible until held, and the
# only direction here that costs a new grammar to learn. Settings still
# opens the same panel afterward.
def radial_board():
    cx, cy = 720, 420
    r = 120

    def arc(mid, lit=False):
        a0, a1 = math.radians(mid - 32), math.radians(mid + 32)
        x0, y0 = cx + r * math.cos(a0), cy + r * math.sin(a0)
        x1, y1 = cx + r * math.cos(a1), cy + r * math.sin(a1)
        col = "#4fd6ff" if lit else "rgba(63,88,120,.9)"
        wd = 2.4 if lit else 1.4
        return (f'<path d="M{x0:.1f} {y0:.1f} A{r} {r} 0 0 1 '
                f'{x1:.1f} {y1:.1f}" stroke="{col}" stroke-width="{wd}" '
                'fill="none"/>')

    ring = ('<svg width="1440" height="810" '
            'style="position:absolute;inset:0;z-index:5">'
            + arc(270) + arc(0) + arc(90, lit=True) + arc(180)
            + f'<g transform="translate({cx},{cy})">'
            f'<path d="{HULLS["Apex"]}" fill="#0b1220" stroke="#4fd6ff" '
            'stroke-width="1.5" stroke-linejoin="round" '
            'transform="scale(1.7)"/></g></svg>')

    def chip(x, y, inner, lit=False):
        edge = "border-color:rgba(79,214,255,.85);" if lit else ""
        return (f'<div class="key" style="position:absolute;left:{x}px;'
                f'top:{y}px;transform:translate(-50%,-50%);height:26px;'
                f'padding:0 11px;font-size:10px;z-index:6;{edge}">'
                + inner + '</div>')

    labels = (
        chip(cx, cy - r - 42, "leave")
        + chip(cx + r + 92, cy, "side &#9656; caisson")
        + chip(cx, cy + r + 42, "settings", lit=True)
        + chip(cx - r - 88, cy, "resume")
    )
    parts = hud() + [
        '<div style="position:absolute;inset:0;'
        'background:rgba(5,7,12,.38)"></div>',
        corner_key(lit=True),
        ring,
        labels,
    ]
    write("Radial.dc.html", board(1440, 810, parts))


# ================ MenuKey: the button at rest, desktop ================
#
# The match at rest with the column's key faint at the bottom middle,
# where the column will stand. The mark keeps the key box and the three
# bars, said small; PLAYERS keeps the corner it has always had, so the
# corner row loses MENU and nothing else. Esc still opens the column
# from a keyboard, so the key is the touch opener and the reminder.
def menu_key_board():
    parts = hud() + [
        players_key(),
        bottom_key(),
    ]
    write("MenuKey.dc.html", board(1440, 810, parts))


def hud_phone():
    """The score band said smaller still, for a 390 corner the clock band
    has to share with two keys."""
    return [
        '<div style="position:absolute;top:52px;left:50%;'
        'transform:translateX(-50%);display:flex;align-items:center;'
        'gap:12px">'
        '<span class="mono" style="font-size:9px;color:#4fd6ff">PYL</span>'
        '<span class="mono" style="font-size:20px;color:#4fd6ff">3</span>'
        '<span class="mono" style="font-size:23px">1:47</span>'
        '<span class="mono" style="font-size:20px;color:#ffa552">5</span>'
        '<span class="mono" style="font-size:9px;color:#ffa552">CAI</span>'
        '</div>',
        '<div style="position:absolute;right:12px;top:12px;width:96px;'
        'height:96px;background:rgba(6,10,16,.55);border:1px solid '
        'rgba(63,88,120,.5)"></div>',
    ]


# ================== Phone: the faint key, at rest ==================
#
# The same faint mark at the bottom middle of a 390 glass, which on a
# phone is also the easiest reach there is: the key sits where a thumb
# already rests, and the column it summons rises into the same hand.
def phone_board():
    parts = hud_phone() + [
        bottom_key(),
    ]
    write("Phone.dc.html", board(390, 844, parts))


# ================ PhoneOpen: the column under a thumb ================
#
# The tap, taken. The column stands where the key sat, the 320 the stops
# have always been fits the glass with margin, RESUME breathes on the
# key's own pixels, and the fight stays visible through the thin wash.
def phone_open_board():
    parts = hud_phone() + [
        DIM,
        column(STOP_ROWS),
    ]
    write("PhoneOpen.dc.html", board(390, 844, parts))


pause_board()
mid_slide_board()
settings_open_board()
corner_panel_board()
center_card_board()
radial_board()
menu_key_board()
phone_board()
phone_open_board()
corner_phone_board()
print("ten boards written")
