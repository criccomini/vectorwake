#!/usr/bin/env python3
# The end of the drawer: settings joins the landing column itself, and the
# slide-out menu is deleted whole.
#
# The arc that makes this thinkable is decisions 98 through 100. The games
# went to the zone stop, the account to the account stop, the ship to the
# ship stop, and what the drawer holds now is settings alone at home, plus
# side and leave in a room. The ship stop also taught the column a grammar
# on the way: a stop can open a panel at the column's own width. Settings
# rides the same grammar.
#
#   Main        the column at rest with a settings stop at its head, a step
#               quieter than the three below it, wearing the mixer icon; the
#               corner MENU key is gone at home
#   StopOpen    the stop open: the panel climbs from it the way the ship
#               pager does, holding everything the drawer held
#   FootLinks   the quieter alternative: no stop, a footer line under PLAY
#               NOW instead
#   CockpitRows what a seat still needs once the drawer dies: a corner key
#               with leave, side and sound, nothing more, because the rest
#               lives at home
#
# Chrome and hues are the client's own, in the manner of ../ship-kit/build.py:
# the row states of decision 72, the ship panel's banded sections, the stops
# and PLAY NOW of decision 89, the lockup verbatim from docs/banner.svg.
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


def attic_stop(lit=False, w=320):
    """The settings stop: same field, a step shorter and dimmer, the mixer
    icon where a value would be. Quiet on purpose: it is not part of the
    who-where-what sentence the three stops below it speak."""
    edge = ("border-color:rgba(79,214,255,.85);" if lit
            else "border-color:rgba(63,88,120,.45);")
    return (f'<div class="field" style="width:{w}px;height:31px;{edge}'
            'background:rgba(8,12,20,.45)">'
            '<span class="lbl">settings</span>'
            '<span class="row" style="gap:9px">' + mixer("#8593a9", 13)
            + caret("#6c7a90") + '</span></div>')


def column(stops, lit=None, kw=320, attic=None, bottom=22):
    """The stops over PLAY NOW, bottom-up, with the lockup at the head.
    attic: None | "closed" | "open" adds the settings stop above the three."""
    out = ['<div style="position:absolute;left:50%;transform:translateX(-50%);'
           f'bottom:{bottom}px;display:flex;flex-direction:column-reverse;'
           'gap:8px;align-items:center">'
           f'<div class="play" style="width:{kw}px;height:54px;'
           'font-size:19px;margin-top:12px;order:-1">PLAY NOW</div>']
    for label, value in stops:
        out.append(land_stop(label, value, lit == label, w=kw))
    if attic:
        out.append('<div style="margin-top:6px">'
                   + attic_stop(lit=(attic == "open"), w=kw) + '</div>')
    out.append('<div style="margin-bottom:14px">' + lockup(208) + '</div>')
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


def corner_key(lit=False):
    edge = "border-color:rgba(79,214,255,.85);" if lit else ""
    return (f'<div class="key" style="position:absolute;left:14px;top:14px;'
            f'height:26px;padding:0 9px;{edge}">' + mixer() + '</div>')


def board(w, h, parts):
    return (f'<div style="position:relative;width:{w}px;height:{h}px;'
            f'overflow:hidden;{stars(w, h)}">' + scene(w, h)
            + "".join(parts) + '</div>')


STOPS3 = [("SHIP", "APEX"), ("ZONE", "TEAM BATTLE"), ("ACCOUNT", "DELTA 154")]


# ================== Main: the column at rest, stop closed ==================
#
# The settings stop rides at the head of the column, above the account,
# shorter and dimmer than the three below it: present, findable, and
# visibly not part of the sentence that ends in PLAY NOW. The corner MENU
# key is gone from this screen; the column is the whole interface.
def main_board():
    parts = [
        column(STOPS3, attic="closed"),
    ]
    write("Main.dc.html", board(1440, 810, parts))


# ==================== StopOpen: the stop, opened ====================
#
# The same grammar the ship stop just taught: a stop opens a panel at the
# column's own width, climbing from its row. Everything the drawer's
# settings page holds is here, banded the way the ship panel bands its
# sections, with controls and about as rows that open in place.
def stop_open_board():
    parts = [
        column(STOPS3, attic="open"),
        '<div style="position:absolute;left:50%;'
        'transform:translateX(-50%);bottom:267px;width:320px;'
        'background:#070b12;border:1px solid rgba(63,88,120,.85);'
        'padding:0 14px 10px;z-index:5">' + settings_rows() + '</div>',
    ]
    write("StopOpen.dc.html", board(1440, 810, parts))


# ================= FootLinks: the footer line instead =================
#
# The alternative that costs no stop: a quiet mono line under PLAY NOW,
# opening the same panel. Cheapest possible presence, but it puts the way
# to turn the music down in the smallest type on the screen, and a first
# session will not find it.
def foot_links_board():
    foot = ('<div class="row" style="position:absolute;left:50%;'
            'transform:translateX(-50%);bottom:16px;gap:8px;'
            'justify-content:center">'
            + mixer("#6c7a90", 12)
            + '<span class="lbl" style="font-size:9.5px">settings</span>'
            '<span class="lbl" style="opacity:.5">&middot;</span>'
            '<span class="lbl" style="font-size:9.5px">controls</span>'
            '<span class="lbl" style="opacity:.5">&middot;</span>'
            '<span class="lbl" style="font-size:9.5px">about</span></div>')
    parts = [
        column(STOPS3, bottom=48),
        foot,
    ]
    write("FootLinks.dc.html", board(1440, 810, parts))


# ================ CockpitRows: what a seat still needs ================
#
# The landing exists only in the stands, so the drawer's death leaves a
# seated pilot needing exactly three things: the way out of the seat, which
# side it is on, and the volume. The corner key keeps the mixer icon and
# opens only that. Everything else waits at home, which is where a pilot
# retunes anyway.
def cockpit_board():
    hud = [
        # The score band and a radar, said small: this is a fight, not a
        # front page.
        '<div style="position:absolute;top:14px;left:50%;'
        'transform:translateX(-50%);display:flex;align-items:center;'
        'gap:22px">'
        '<span class="mono" style="font-size:11px;color:#4fd6ff">PYLON</span>'
        '<span class="mono" style="font-size:30px;color:#4fd6ff">3</span>'
        '<span class="mono" style="font-size:34px">1:47</span>'
        '<span class="mono" style="font-size:30px;color:#ffa552">5</span>'
        '<span class="mono" style="font-size:11px;color:#ffa552">CAISSON</span>'
        '</div>',
        '<div style="position:absolute;right:14px;top:14px;width:168px;'
        'height:168px;background:rgba(6,10,16,.55);border:1px solid '
        'rgba(63,88,120,.5)"></div>',
    ]
    rows = (
        srow("Leave", '<span class="key" style="height:24px;padding:0 11px;'
             'font-size:10px">hand the seat back</span>', state="cursor")
        + srow("Side", stepper("Pylon"))
        + srow("Sound", pips(4, 3))
    )
    parts = hud + [
        corner_key(lit=True),
        '<div style="position:absolute;left:14px;top:48px;width:300px;'
        'background:#070b12;border:1px solid rgba(63,88,120,.85);'
        'padding:0 14px 10px;z-index:5">' + rows + '</div>',
    ]
    write("CockpitRows.dc.html", board(1440, 810, parts))


main_board()
stop_open_board()
foot_links_board()
cockpit_board()
print("four boards written")
