#!/usr/bin/env python3
# The play-page rethink boards, assembled from shared fragments so the chrome
# (top line, rail, row grammar) stays identical across every board. Sizes and
# colors are the drawer's own: 390 wide, ink dfe9f5, dim 6c7a90, friend 4fd6ff,
# enemy ffa552, key boxes on rgba(63,88,120,.75), lbl 9px mono upper. The
# facts on the rows are the catalog's: Duel and Team Battle, Pylon and
# Caisson, eight seats, the melee map rotation.
import pathlib

OUT = str(pathlib.Path(__file__).resolve().parent)

STYLE = """
:root{
  --ink:#dfe9f5; --dim:#6c7a90; --friend:#4fd6ff; --enemy:#ffa552;
  --gold:#ffd166;
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
.name{font-size:18px;color:var(--ink)}
.note{font-family:var(--mono);font-size:10px;color:var(--dim)}
.mono{font-family:var(--mono)}
"""

# The starfield, as CSS dots at three depths, so every board sits on the same
# ground the client draws.
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

# The room behind the drawer: two hulls trading fire around a pair of wall
# modules. Bright strokes on purpose, because every board lays the 0.86 wash
# over this and what survives is what a player actually sees bleed through.
def fight(w, h, ox=0, oy=0):
    def wall(x, y, ww, hh):
        return (f'<rect x="{x}" y="{y}" width="{ww}" height="{hh}" '
                'fill="#080d16" stroke="#22344f" stroke-width="1"/>'
                f'<path d="M{x} {y} H{x + ww}" stroke="#5b82b8" '
                'stroke-width="1.4" opacity=".55"/>')
    a = (f'<g transform="translate({150 + ox},{330 + oy}) rotate(36)">'
         '<path d="M-4,10 L-2,44 L2,44 L4,10 Z" fill="#4fd6ff" opacity=".16"/>'
         '<path d="M0,-13 L15,9 L7,12 L0,8 L-7,12 L-15,9 Z" fill="#0b1220" '
         'stroke="#4fd6ff" stroke-width="1.5" stroke-linejoin="round"/></g>')
    b = (f'<g transform="translate({300 + ox},{560 + oy}) rotate(205)">'
         '<path d="M-4,10 L-2,44 L2,44 L4,10 Z" fill="#ffa552" opacity=".16"/>'
         '<path d="M0,-22 L3,-6 L6,8 L2,12 L-2,12 L-6,8 L-3,-6 Z" '
         'fill="#0b1220" stroke="#ffa552" stroke-width="1.5" '
         'stroke-linejoin="round"/></g>')
    rounds = (f'<g stroke="#62cc35" stroke-width="1.6" opacity=".8">'
              f'<path d="M{170 + ox} {360 + oy} l9 13"/>'
              f'<path d="M{196 + ox} {398 + oy} l9 13"/>'
              f'<path d="M{224 + ox} {438 + oy} l9 13"/></g>')
    return (f'<svg width="{w}" height="{h}" style="position:absolute;inset:0">'
            + wall(288 + ox, 196 + oy, 26, 104)
            + wall(60 + ox, 610 + oy, 128, 26) + a + b + rounds + '</svg>')

X_KEY = ('<div class="key" style="width:26px;height:26px;flex:none">'
         '<svg width="11" height="11" viewBox="0 0 12 12">'
         '<path d="M1.5 1.5 L10.5 10.5 M10.5 1.5 L1.5 10.5" stroke="#9fb6d4" '
         'stroke-width="1.4" stroke-linecap="square"/></svg></div>')

DISCORD_KEY = ('<div class="key" style="width:34px;height:26px;flex:none">'
    '<svg width="15" height="12" viewBox="0 0 16 12" fill="none">'
    '<path d="M4.6 1.6 C5.7 1.2 6.8 1 8 1 C9.2 1 10.3 1.2 11.4 1.6 '
    'C12.9 2.3 14.2 4.5 14.4 7.8 C13.4 9.1 12 9.9 11 10.2 L10.2 8.9 '
    'C9.5 9.1 8.8 9.2 8 9.2 C7.2 9.2 6.5 9.1 5.8 8.9 L5 10.2 '
    'C4 9.9 2.6 9.1 1.6 7.8 C1.8 4.5 3.1 2.3 4.6 1.6 Z" '
    'stroke="#9fb6d4" stroke-width="1.1"/>'
    '<circle cx="5.7" cy="5.9" r="1" fill="#9fb6d4"/>'
    '<circle cx="10.3" cy="5.9" r="1" fill="#9fb6d4"/></svg></div>')

PILL = ('<div class="key" style="height:26px;padding:0 13px;font-size:11px;'
        'color:#9fb6d4;letter-spacing:.02em;text-transform:none">Delta 154'
        '</div>')

def topline():
    return ('<div class="row" style="height:48px;gap:10px;'
            'border-bottom:1px solid rgba(63,88,120,.45);margin:0 -14px;'
            'padding:0 14px">' + X_KEY + '<div style="flex:1"></div>'
            + DISCORD_KEY + PILL + '</div>')

ICONS = {
 "play": '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="{c}" stroke-width="1.3"><circle cx="8" cy="8" r="3.4"/><ellipse cx="8" cy="8" rx="7" ry="2.6" transform="rotate(-18 8 8)"/></svg>',
 "ship": '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="{c}" stroke-width="1.3"><g transform="translate(8,8.6) scale(.5)"><path d="M0,-13 L15,9 L7,12 L0,8 L-7,12 L-15,9 Z"/></g></svg>',
 "friends": '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="{c}" stroke-width="1.2"><path d="M2 8.6 A3.6 3.6 0 0 1 9.2 8.6 M1.4 10 H9.8" opacity=".55"/><path d="M6.4 11.2 A3.9 3.9 0 0 1 14.2 11.2 M5.7 12.8 H14.9"/></svg>',
 "pilot": '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="{c}" stroke-width="1.3"><path d="M2.6 9.8 A5.5 5.5 0 0 1 13.4 9.8"/><path d="M1.6 11.6 H14.4"/></svg>',
 "settings": '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="{c}" stroke-width="1.3"><path d="M2 4.5 H14 M2 8 H14 M2 11.5 H14"/><circle cx="10.5" cy="4.5" r="1.8" fill="#0a0f18"/><circle cx="5.5" cy="8" r="1.8" fill="#0a0f18"/><circle cx="9.5" cy="11.5" r="1.8" fill="#0a0f18"/></svg>',
}
STOPS = ["play", "ship", "friends", "settings", "pilot"]

def rail(lit="play"):
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

def board(body, overlay="", back=None):
    back = back if back is not None else fight(390, 844)
    return f"""<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
  <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Chakra+Petch:wght@400;500;600&amp;family=Noto+Sans+Mono:wght@400;500;700&amp;display=swap">
  <style>{STYLE}</style>
</helmet>
<div style="position:relative;width:390px;height:844px;overflow:hidden;{stars(390, 844)}">
{back}
<div style="position:absolute;inset:0;background:rgba(3,5,10,.86)"></div>
<div style="position:absolute;left:0;right:0;top:0;bottom:78px;padding:0 14px;overflow:hidden">
{topline()}
{body}
</div>
{rail()}
{overlay}
</div>
</x-dc>

</body>
</html>
"""

def write(name, html):
    pathlib.Path(OUT, name).write_text(html)

# A game row as the page ships it: the name over the sentence, the lit
# gradient on the row the cursor rests on, nothing else.
def bare_row(name, note, lit=False, extra=""):
    bg = ("background:linear-gradient(90deg,rgba(79,214,255,.14),"
          "rgba(79,214,255,0) 85%);" if lit else "")
    return (f'<div style="padding:12px 14px;margin:0 -14px;{bg}">'
            f'<div class="name">{name}</div>'
            f'<div class="note" style="margin-top:2px">{note}</div>'
            + extra + '</div>')

DUEL_NOTE = "one life at a time, climb the house pilot ladder"
TB_NOTE = "four a side, three minutes"

# ---- As shipped: two names, two sentences, an empty column ----
cur = ('<div style="margin-top:6px">'
       + bare_row("Duel", DUEL_NOTE, lit=True)
       + bare_row("Team Battle", TB_NOTE) + '</div>')
write("Current.dc.html", board(cur))

# ---- A: departures. The wire the list already asks every three seconds ----

# One seat, in the hangar's circle grammar: solid is a person, a ring is a
# bot holding the seat for one, a dim ring is nobody.
def seat(kind):
    if kind == "p":
        return ('<span style="width:9px;height:9px;border-radius:50%;'
                'background:#dfe9f5"></span>')
    if kind == "b":
        return ('<span style="width:9px;height:9px;border-radius:50%;'
                'border:1.4px solid #6c7a90"></span>')
    return ('<span style="width:9px;height:9px;border-radius:50%;'
            'border:1.4px solid rgba(108,122,144,.35)"></span>')

def seats(kinds):
    return ('<div class="row" style="gap:7px;margin-top:9px">'
            + "".join(seat(k) for k in kinds) + '</div>')

def clock(label, value):
    return ('<div class="col" style="align-items:flex-end;flex:none">'
            f'<span class="lbl">{label}</span>'
            '<span class="mono" style="font-size:17px;color:var(--ink);'
            f'margin-top:2px">{value}</span></div>')

def live_row(name, note, right, under="", lit=False):
    bg = ("background:linear-gradient(90deg,rgba(79,214,255,.14),"
          "rgba(79,214,255,0) 85%);" if lit else "")
    return (f'<div style="padding:13px 14px 12px;margin:0 -14px;{bg}">'
            '<div class="row" style="align-items:flex-start">'
            f'<div class="col" style="flex:1;min-width:0">'
            f'<div class="name">{name}</div>'
            f'<div class="note" style="margin-top:2px">{note}</div></div>'
            + right + '</div>' + under + '</div>')

dep = ('<div style="margin-top:6px">'
       + live_row("Duel", DUEL_NOTE, clock("live", "2:04"),
                  under=seats("bb")
                  + '<div class="note" style="margin-top:7px">'
                  'your climb is at rung 23</div>')
       + live_row("Team Battle", TB_NOTE, clock("next match", "0:42"),
                  under=seats("pppbbbb-")
                  + '<div class="mono" style="font-size:10px;'
                  'color:var(--friend);margin-top:7px">Vex and Halcyon 9 '
                  'are flying</div>', lit=True)
       + '</div>')
write("Main.dc.html", board(dep))

# ---- B: the tuner. The row under the cursor is the room behind the wash ----

def scoreline():
    return ('<div class="row" style="margin-top:8px;gap:8px">'
            '<span class="mono" style="font-size:11px;color:var(--friend)">'
            'Pylon 12</span>'
            '<div style="flex:1;height:1px;background:rgba(63,88,120,.45)">'
            '</div>'
            '<span class="mono" style="font-size:13px;color:var(--ink)">'
            '1:28</span>'
            '<div style="flex:1;height:1px;background:rgba(63,88,120,.45)">'
            '</div>'
            '<span class="mono" style="font-size:11px;color:var(--enemy)">'
            'Caisson 9</span></div>')

tun = ('<div style="margin-top:6px">'
       + bare_row("Duel", DUEL_NOTE)
       + bare_row("Team Battle", TB_NOTE, lit=True, extra=scoreline())
       + '</div>')
write("Tuner.dc.html", board(tun, back=fight(390, 844, oy=-40)))

# The same direction with room to see it: the drawer at its 390 beside the
# fight it is tuned to, the way a desktop or a phone on its side holds it.
def wide_board():
    band = ('<div class="row" style="position:absolute;left:390px;right:0;'
            'top:10px;justify-content:center;gap:14px">'
            '<div class="col" style="align-items:flex-end">'
            '<span class="mono" style="font-size:10px;color:var(--friend)">'
            'Pylon</span>'
            '<span class="mono" style="font-size:13px;color:var(--friend)">'
            '12</span></div>'
            '<span class="mono" style="font-size:24px;color:var(--ink)">'
            '1:28</span>'
            '<div class="col">'
            '<span class="mono" style="font-size:10px;color:var(--enemy)">'
            'Caisson</span>'
            '<span class="mono" style="font-size:13px;color:var(--enemy)">'
            '9</span></div></div>')
    drawer = ('<div style="position:absolute;left:0;top:0;bottom:0;'
              'width:390px;background:rgba(3,5,10,.86);'
              'border-right:1px solid rgba(63,88,120,.6)">'
              '<div style="position:absolute;left:0;right:0;top:0;bottom:64px;'
              'padding:0 14px;overflow:hidden">'
              + topline()
              + '<div style="margin-top:6px">'
              + bare_row("Duel", DUEL_NOTE)
              + bare_row("Team Battle", TB_NOTE, lit=True, extra=scoreline())
              + '</div></div>'
              + '<div style="position:absolute;left:0;right:0;bottom:0;'
              'height:64px;border-top:1px solid rgba(63,88,120,.6);'
              'display:flex">'
              + "".join('<div style="flex:1;display:flex;flex-direction:column;'
                        'align-items:center;justify-content:center;gap:3px;'
                        + ("background:linear-gradient(0deg,"
                           "rgba(79,214,255,.14),rgba(79,214,255,0) 80%);"
                           if n == "play" else "") + '">'
                        + ICONS[n].format(
                            c="#4fd6ff" if n == "play" else "#6c7a90")
                        + f'<span style="font-size:9px;color:'
                        + ("var(--ink)" if n == "play" else "var(--dim)")
                        + f'">{n}</span></div>' for n in STOPS)
              + '</div></div>')
    return f"""<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
  <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Chakra+Petch:wght@400;500;600&amp;family=Noto+Sans+Mono:wght@400;500;700&amp;display=swap">
  <style>{STYLE}</style>
</helmet>
<div style="position:relative;width:844px;height:390px;overflow:hidden;{stars(844, 390)}">
{fight(844, 390, ox=310, oy=-240)}
{band}
{drawer}
</div>
</x-dc>

</body>
</html>
"""

write("TunerWide.dc.html", wide_board())

# ---- C: the chart room. A game is a place, drawn in the radar's grammar ----

# A chart of the ground the room is on: walls in the radar's tile color on
# the radar's ground, spawn tiles in the side colors. Shoal is loose rock;
# drydock is the pair of arms with the slip between them.
def chart(kind, spawns):
    w, h = 362, 128
    if kind == "shoal":
        rocks = (
            '<g fill="rgba(63,88,120,.18)" stroke="#3f5878" '
            'stroke-width="1.2">'
            '<path d="M60 34 l22 -8 18 12 -6 20 -24 6 -14 -16 Z"/>'
            '<path d="M150 78 l16 -10 20 4 6 16 -14 14 -22 -4 Z"/>'
            '<path d="M236 30 l18 -6 14 10 -4 16 -20 6 -12 -12 Z"/>'
            '<path d="M282 84 l14 -8 16 6 2 14 -16 10 -16 -6 Z"/>'
            '<path d="M112 22 l10 -4 8 6 -2 10 -12 2 -6 -8 Z"/>'
            '<path d="M204 96 l10 -6 10 4 2 10 -10 6 -12 -4 Z"/></g>')
        body = rocks
    else:
        body = (
            '<g fill="rgba(63,88,120,.18)" stroke="#3f5878" '
            'stroke-width="1.2">'
            '<path d="M48 30 H272 l22 12 v10 H48 Z"/>'
            '<path d="M48 76 H272 l22 12 v10 H48 Z"/>'
            '<rect x="140" y="58" width="34" height="12"/></g>'
            '<path d="M294 52 v24" stroke="#35e0a0" stroke-width="2"/>')
    dots = "".join(
        f'<circle cx="{x}" cy="{y}" r="2.6" fill="{c}"/>'
        for x, y, c in spawns)
    return (f'<svg width="{w}" height="{h}" style="display:block;'
            'background:#060a10;border:1px solid rgba(34,52,79,.9)" '
            f'viewBox="0 0 {w} {h}">{body}{dots}</svg>')

TB_SPAWNS = [(28, 40, "#4fd6ff"), (28, 62, "#4fd6ff"), (28, 84, "#4fd6ff"),
             (28, 106, "#4fd6ff"), (334, 22, "#ffa552"), (334, 44, "#ffa552"),
             (334, 66, "#ffa552"), (334, 88, "#ffa552")]
DUEL_SPAWNS = [(28, 62, "#4fd6ff"), (334, 66, "#ffa552")]

def card(name, note, chart_svg, ground, lit=False):
    bg = ("background:linear-gradient(90deg,rgba(79,214,255,.14),"
          "rgba(79,214,255,0) 85%);" if lit else "")
    return (f'<div style="padding:13px 14px 14px;margin:0 -14px;{bg}">'
            f'<div class="name">{name}</div>'
            f'<div class="note" style="margin-top:2px">{note}</div>'
            f'<div style="margin-top:10px">{chart_svg}</div>'
            '<div class="row" style="margin-top:7px">'
            + ground + '</div></div>')

tb_ground = ('<span class="lbl" style="color:#9fb6d4">shoal</span>'
             '<div style="flex:1"></div>'
             '<span class="lbl">next ground breakwater · 0:42</span>')
duel_ground = ('<span class="lbl" style="color:#9fb6d4">drydock</span>'
               '<div style="flex:1"></div>'
               '<span class="lbl">the calibration ground</span>')

cr = ('<div style="margin-top:6px">'
      + card("Duel", DUEL_NOTE, chart("drydock", DUEL_SPAWNS), duel_ground)
      + card("Team Battle", TB_NOTE, chart("shoal", TB_SPAWNS), tb_ground,
             lit=True)
      + '</div>')
write("ChartRoom.dc.html", board(cr))

print("boards written")
