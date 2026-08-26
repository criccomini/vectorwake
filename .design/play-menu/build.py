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

# Every figure on a row is the landing room's: the room the fill ladder
# would put this press in, which is the same pick the join makes and the
# room whose clock the shipped page already counts down. The zone's own
# totals are a different fact and never wear the seat grammar; a zone
# running two arenas has twelve people and eight seats, and circles drawn
# from both at once would be a lie.
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

# The same direction when a zone is actually holding more than one joinable
# room. The zone head keeps the name and the sentence and stays the press
# that means "wherever the fill ladder puts me"; the rooms unfold under it
# as numbered lines, each with its own clock and its own seats, which is
# the arena's ROOMS grammar moved onto the page. Sorted by the number the
# server gave each room, a full one readable but dim, the one the ladder
# would pick lit. Duel never unfolds: its twenty rooms are one climber
# each, so no second line there is a room anybody could join.
def room_line(n, clk_label, clk, kinds, dim=False, lit=False, under=""):
    bg = ("background:linear-gradient(90deg,rgba(79,214,255,.14),"
          "rgba(79,214,255,0) 85%);" if lit else "")
    ink = "rgba(108,122,144,.75)" if dim else "var(--ink)"
    return (f'<div style="padding:9px 14px 9px 26px;margin:0 -14px;{bg}">'
            '<div class="row">'
            f'<span class="mono" style="font-size:12px;color:{ink};'
            f'letter-spacing:.08em">ROOM {n}</span>'
            '<div style="flex:1"></div>'
            f'<span class="lbl" style="margin-right:7px">{clk_label}</span>'
            f'<span class="mono" style="font-size:14px;color:{ink}">{clk}'
            '</span></div>' + seats(kinds) + under + '</div>')

roomy = ('<div style="margin-top:6px">'
         + live_row("Duel", DUEL_NOTE, clock("live", "2:04"),
                    under=seats("bb")
                    + '<div class="note" style="margin-top:7px">'
                    'your climb is at rung 23</div>')
         + '<div style="padding:13px 14px 4px;margin:0 -14px">'
         '<div class="name">Team Battle</div>'
         f'<div class="note" style="margin-top:2px">{TB_NOTE}</div></div>'
         + room_line(1, "live", "1:28", "pppppppp", dim=True,
                     under='<div class="mono" style="font-size:10px;'
                     'color:var(--friend);margin-top:7px">Vex and Halcyon 9 '
                     'are flying</div>')
         + room_line(2, "next match", "0:42", "ppbbbbb-", lit=True)
         + '</div>')
write("Rooms.dc.html", board(roomy))

# ---- B: the tuner. The row under the cursor is the room behind the wash ----

# The feed and the score are the landing room's, the same room the row's
# press would join: a zone holding several rooms has several scores, and
# the one worth showing is the one this press is about.
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

# A chart of the ground the landing room is on: walls in the radar's tile
# color on the radar's ground, spawn tiles in the side colors. One room's
# ground, since rooms of one zone cycle their rotations apart. Shoal is
# loose rock; drydock is the pair of arms with the slip between them.
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

# ==== Round two: framings that change what the page is, not what a row ====
# ==== says. Sketches, drawn in the drawer's chrome so they compare.     ====

# ---- D: the boarding call. The page is one question, not a catalog ----
#
# The fleet already knows the next whistle and where the fill ladder would
# seat this press, so the page can just ask. Browsing survives underneath
# as two quiet lines, because being told is a default and not a cage.
bigkey = ('<div class="key" style="height:46px;width:100%;font-size:13px;'
          'border-color:rgba(79,214,255,.5);background:rgba(79,214,255,.07);'
          'color:#4fd6ff">deal me in</div>')
dcall = ('<div class="col" style="align-items:center;margin-top:120px">'
         '<span class="lbl">next match</span>'
         '<span class="mono" style="font-size:52px;margin-top:6px">0:42'
         '</span>'
         '<span style="font-size:15px;margin-top:10px">Team Battle '
         '<span class="note" style="font-size:11px">on shoal</span></span>'
         '</div>'
         '<div style="margin-top:26px">' + bigkey + '</div>'
         '<div style="margin-top:130px">'
         + bare_row("or climb", "Duel, one life at a time, at your rung 23")
         + bare_row("or just watch", "stay in the stands, keep the whistle")
         + '</div>')
write("BoardingCall.dc.html", board(dcall))

# ---- E: the channel wall. The previews are the controls ----
#
# No rows at all: the page is one live window per game, the fight drawn
# small with its name and clock on a corner band, and pressing a window
# means be in that room. With two games the whole fleet fits on a phone.
def tile(label, corner, w=362, h=300, oy=0, foot=""):
    return ('<div style="position:relative;width:' + str(w) + 'px;height:'
            + str(h) + 'px;overflow:hidden;border:1px solid '
            'rgba(34,52,79,.9);' + stars(w, h) + '">'
            + fight(w, h, ox=-20, oy=oy)
            + '<div class="row" style="position:absolute;left:0;right:0;'
            'top:0;height:26px;padding:0 10px;gap:8px;'
            'background:rgba(3,5,10,.72)">'
            f'<span style="font-size:13px">{label}</span>'
            '<div style="flex:1"></div>' + corner + '</div>'
            + foot + '</div>')

tb_corner = ('<span class="mono" style="font-size:10px;color:var(--friend)">'
             'Pylon 12</span>'
             '<span class="mono" style="font-size:12px">1:28</span>'
             '<span class="mono" style="font-size:10px;color:var(--enemy)">'
             'Caisson 9</span>')
duel_corner = ('<span class="mono" style="font-size:10px;color:var(--dim)">'
               'rung 23</span>'
               '<span class="mono" style="font-size:12px">2:04</span>')
wall_page = ('<div class="col" style="gap:14px;margin-top:14px">'
             + tile("Team Battle", tb_corner, oy=-160)
             + tile("Duel", duel_corner, oy=-300)
             + '</div>'
             '<div class="note" style="text-align:center;margin-top:12px">'
             'press a window to be in it</div>')
write("ChannelWall.dc.html", board(wall_page, back=""))

# ---- G: the star chart. A game is a place on one map ----
#
# The games drawn as beacons on a chart in the radar's grammar, your own
# mark at the foot, and a plotted route to the beacon under the cursor,
# whose card opens beside it. Choosing a game reads as going somewhere,
# which is the register the whole game is named in.
def beacon(x, y, r, label, lit):
    c = "#4fd6ff" if lit else "#9fb6d4"
    rings = (f'<circle cx="{x}" cy="{y}" r="{r + 8}" stroke="{c}" '
             'fill="none" stroke-width="1" opacity=".35"/>' if lit else "")
    return (f'<circle cx="{x}" cy="{y}" r="{r}" stroke="{c}" fill="none" '
            'stroke-width="1.4"/>'
            f'<circle cx="{x}" cy="{y}" r="2.2" fill="{c}"/>' + rings
            + f'<text x="{x}" y="{y + r + 18}" text-anchor="middle" '
            f'fill="{c}" font-size="11" font-family="DejaVu Sans Mono,'
            f'monospace">{label}</text>')

chart_page = ('<svg width="362" height="560" viewBox="0 0 362 560" '
              'style="display:block;margin-top:14px;background:#060a10;'
              'border:1px solid rgba(34,52,79,.9)">'
              + beacon(96, 150, 9, "DUEL", False)
              + beacon(252, 300, 12, "TEAM BATTLE", True)
              + '<path d="M181 512 L252 300" stroke="#4fd6ff" '
              'stroke-width="1" stroke-dasharray="3 5" opacity=".6"/>'
              '<g transform="translate(181,512) rotate(-18)">'
              '<path d="M0,-8 L9,5 L4,7 L0,5 L-4,7 L-9,5 Z" fill="#0b1220" '
              'stroke="#4fd6ff" stroke-width="1.3"/></g>'
              '<text x="181" y="536" text-anchor="middle" fill="#6c7a90" '
              'font-size="9" font-family="DejaVu Sans Mono,monospace" '
              'letter-spacing="2">YOU</text>'
              '<g transform="translate(196,236)">'
              '<rect width="152" height="52" fill="rgba(3,5,10,.85)" '
              'stroke="rgba(63,88,120,.75)"/>'
              '<text x="10" y="20" fill="#dfe9f5" font-size="12" '
              'font-family="Chakra Petch,sans-serif">Team Battle</text>'
              '<text x="10" y="38" fill="#6c7a90" font-size="9" '
              'font-family="DejaVu Sans Mono,monospace">on shoal · '
              'next match 0:42</text></g>'
              '</svg>'
              '<div class="note" style="text-align:center;margin-top:12px">'
              'press a beacon to go</div>')
write("StarChart.dc.html", board(chart_page))

# ---- H: the wire. The page is what just happened, each line a door ----
#
# Choosing by story rather than by name: streaks in the streak's gold,
# kills in the payout green, whistles and seats in ink and cyan, every
# line pressable toward the room it happened in. The games are still one
# press away; they are just no longer the subject.
def wire_line(t, text, col="var(--ink)"):
    return ('<div class="row" style="height:34px;margin:0 -14px;'
            'padding:0 14px;gap:10px">'
            f'<span class="mono" style="font-size:9px;color:var(--dim);'
            f'width:30px">{t}</span>'
            f'<span class="mono" style="font-size:11px;color:{col};'
            'flex:1;white-space:nowrap;overflow:hidden;'
            f'text-overflow:ellipsis">{text}</span>'
            '<svg width="7" height="10" viewBox="0 0 10 14">'
            '<path d="M2 1.5 L7.5 7 L2 12.5 Z" '
            'fill="rgba(79,214,255,.45)"/></svg></div>')

wire = ('<div class="lbl" style="margin:16px 0 8px">across the fleet, now'
        '</div>'
        + wire_line("0:04", "Vex is on a streak in Team Battle", "#ffc23d")
        + wire_line("0:11", "a seat opened on Caisson", "var(--friend)")
        + wire_line("0:26", "Halcyon 9 took Marrow 6", "#8dffb0")
        + wire_line("0:42", "next match calls on shoal")
        + wire_line("1:03", "Sable holds rung 31 in Duel", "#ffc23d")
        + wire_line("1:19", "match on relay went to Pylon, 21 to 18")
        + wire_line("1:40", "Chord 12 took a double", "#8dffb0")
        + '<div style="margin-top:22px">'
        + bare_row("Duel", DUEL_NOTE)
        + bare_row("Team Battle", TB_NOTE)
        + '</div>')
write("Ticker.dc.html", board(wire))

# ---- F: no page at all. The stands are the browser ----
#
# The play stop stops opening a drawer: you are always in some room's
# stands, the chevrons flick between live rooms, and PLAY seats you in
# the one you are watching. The endpoint of the spectator-first landing;
# the drawer keeps everything else.
def surf_board():
    chev = ('<svg width="16" height="26" viewBox="0 0 16 26">'
            '<path d="{d}" stroke="#9fb6d4" stroke-width="2" fill="none" '
            'stroke-linecap="square"/></svg>')
    left = ('<div class="key" style="position:absolute;left:10px;top:50%;'
            'margin-top:-26px;width:34px;height:52px">'
            + chev.format(d="M12 3 L4 13 L12 23") + '</div>')
    right = ('<div class="key" style="position:absolute;right:10px;top:50%;'
             'margin-top:-26px;width:34px;height:52px">'
             + chev.format(d="M4 3 L12 13 L4 23") + '</div>')
    band = ('<div class="row" style="position:absolute;left:0;right:0;'
            'top:12px;justify-content:center;gap:14px">'
            '<div class="col" style="align-items:flex-end">'
            '<span class="mono" style="font-size:10px;color:var(--friend)">'
            'Pylon</span>'
            '<span class="mono" style="font-size:13px;color:var(--friend)">'
            '12</span></div>'
            '<span class="mono" style="font-size:24px">1:28</span>'
            '<div class="col">'
            '<span class="mono" style="font-size:10px;color:var(--enemy)">'
            'Caisson</span>'
            '<span class="mono" style="font-size:13px;color:var(--enemy)">'
            '9</span></div></div>')
    foot = ('<div class="col" style="position:absolute;left:0;right:0;'
            'bottom:26px;align-items:center;gap:10px">'
            '<div class="row" style="gap:8px">'
            '<span style="width:5px;height:5px;border-radius:50%;'
            'background:#dfe9f5"></span>'
            '<span style="width:5px;height:5px;border-radius:50%;'
            'border:1px solid #6c7a90"></span></div>'
            '<span style="font-size:14px">Team Battle '
            '<span class="note" style="font-size:10px">on shoal</span>'
            '</span>'
            '<div class="key" style="height:44px;width:250px;font-size:13px;'
            'border-color:rgba(79,214,255,.5);'
            'background:rgba(79,214,255,.07);color:#4fd6ff">play</div>'
            '</div>')
    burger = ('<div class="key" style="position:absolute;left:14px;top:11px;'
              'width:26px;height:26px">'
              '<svg width="12" height="10" viewBox="0 0 12 10">'
              '<path d="M0 1 H12 M0 5 H12 M0 9 H12" stroke="#9fb6d4" '
              'stroke-width="1.4"/></svg></div>')
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
{fight(390, 844, oy=-60)}
{burger}
{band}
{left}
{right}
{foot}
</div>
</x-dc>

</body>
</html>
"""

write("Surf.dc.html", surf_board())

# ==== Round three: the structured format. Chris's brief after rounds one ====
# ==== and two: the stands beside the drawer already show a game in       ====
# ==== flight, so the row's job is saying what the format is. Time, team  ====
# ==== count, scoring, in a structure rather than a sentence. Four        ====
# ==== versions of that structure, same facts on all four.                ====
#
# The facts are the catalog's. Team Battle: two sides of four with AI
# holding empty seats, three-minute matches with fifteen seconds between,
# kills score the victim's bounty (one, plus one per kill on their run),
# six grounds in rotation. Duel: one against a measured house pilot, one
# life a round, a win climbs a rung and a loss drops two with a checkpoint
# every five, always on drydock.

# ---- I: spec stacks. The landing band's label-over-value grammar ----
#
# Each fact is a small stack, label over value, vrules between, the way
# the landing's room band wore TIME and PLAYERS. The sentence stays under
# the name; the stacks answer the questions the sentence glosses over.
def spec(label, value):
    return ('<div class="col" style="align-items:flex-start;min-width:0">'
            f'<span class="lbl">{label}</span>'
            '<span class="mono" style="font-size:13px;color:var(--ink);'
            f'margin-top:3px;white-space:nowrap">{value}</span></div>')

def spec_strip(cells):
    out = []
    for i, (l, v) in enumerate(cells):
        if i > 0:
            out.append('<div style="width:1px;align-self:stretch;'
                       'background:rgba(63,88,120,.45)"></div>')
        out.append(spec(l, v))
    return ('<div class="row" style="gap:14px;margin-top:11px;'
            'align-items:stretch">' + "".join(out) + '</div>')

DUEL_SPECS = [("sides", "1 v 1"), ("time", "one life"),
              ("scoring", "rungs"), ("ground", "drydock")]
TB_SPECS = [("sides", "4 v 4"), ("time", "3:00"),
            ("scoring", "kills"), ("grounds", "6 rotate")]

specs_page = ('<div style="margin-top:6px">'
              + bare_row("Duel", DUEL_NOTE, extra=spec_strip(DUEL_SPECS))
              + bare_row("Team Battle", TB_NOTE, lit=True,
                         extra=spec_strip(TB_SPECS))
              + '</div>')
write("SpecRows.dc.html", board(specs_page))

# ---- J: the table. One header, aligned columns, games as rows ----
#
# The structure the facts want once there are more games than two: one
# labeled header and every game measured in the same columns, so reading
# the list is comparing. The sentence rides under the name inside the
# first column.
def tcell(v, w, right=True, col="var(--ink)"):
    a = "right" if right else "left"
    return (f'<span class="mono" style="font-size:11.5px;color:{col};'
            f'width:{w}px;flex:none;text-align:{a};white-space:nowrap">'
            f'{v}</span>')

def trow(name, note, sides, time, scoring, lit=False):
    bg = ("background:linear-gradient(90deg,rgba(79,214,255,.14),"
          "rgba(79,214,255,0) 85%);" if lit else "")
    return (f'<div class="row" style="margin:0 -14px;padding:11px 14px;{bg};'
            'align-items:flex-start;gap:14px">'
            '<div class="col" style="flex:1;min-width:0">'
            f'<span style="font-size:16px">{name}</span>'
            f'<span class="note" style="margin-top:2px">{note}</span></div>'
            + tcell(sides, 34) + tcell(time, 60) + tcell(scoring, 46)
            + '</div>')

thead = ('<div class="row" style="margin:14px -14px 0;padding:0 14px 6px;'
         'border-bottom:1px solid rgba(63,88,120,.45);gap:14px">'
         '<span class="lbl" style="flex:1">game</span>'
         + tcell("sides", 34, col="var(--dim)")
         + tcell("time", 60, col="var(--dim)")
         + tcell("scoring", 46, col="var(--dim)") + '</div>')
table_page = (thead
              + trow("Duel", "the house ladder", "1v1", "one life", "rungs")
              + trow("Team Battle", "melee", "4v4", "3:00", "kills",
                     lit=True))
write("FormatTable.dc.html", board(table_page))

# ---- K: format marks. The structure drawn, then captioned ----
#
# The sides as seat circles actually facing each other, time as a dial,
# scoring as the crosshair or the ladder, each mark over a one-word
# caption. Reads before it is read; costs a vocabulary nobody has been
# taught yet, so every mark keeps its word underneath.
def mark_cell(svg, caption):
    return ('<div class="col" style="align-items:center;gap:5px">'
            f'<svg width="44" height="20" viewBox="0 0 44 20">{svg}</svg>'
            f'<span class="lbl">{caption}</span></div>')

# A side is a cluster of seats; two clusters facing across a gap say
# "versus" without a letter doing it.
def cluster(n, cx, solid):
    spots = [(cx, 10)] if n == 1 else [(cx - 4, 6), (cx + 4, 6),
                                       (cx - 4, 14), (cx + 4, 14)]
    out = []
    for x, y in spots:
        if solid:
            out.append(f'<circle cx="{x}" cy="{y}" r="2.6" fill="#dfe9f5"/>')
        else:
            out.append(f'<circle cx="{x}" cy="{y}" r="2.6" fill="none" '
                       'stroke="#6c7a90" stroke-width="1.3"/>')
    return "".join(out)

SIDES_44 = cluster(4, 12, True) + cluster(4, 32, False)
SIDES_11 = cluster(1, 14, True) + cluster(1, 30, False)
DIAL = ('<circle cx="22" cy="10" r="8" fill="none" stroke="#dfe9f5" '
        'stroke-width="1.3"/>'
        '<path d="M22 10 L22 4.5 M22 10 L26 12" stroke="#dfe9f5" '
        'stroke-width="1.3"/>')
ONE_LIFE = ('<circle cx="22" cy="10" r="8" fill="none" stroke="#dfe9f5" '
            'stroke-width="1.3"/>'
            '<circle cx="22" cy="10" r="2.4" fill="#dfe9f5"/>')
CROSS = ('<circle cx="22" cy="10" r="6.5" fill="none" stroke="#dfe9f5" '
         'stroke-width="1.3"/>'
         '<path d="M22 0.5 V5 M22 15 V19.5 M12.5 10 H17 M27 10 H31.5" '
         'stroke="#dfe9f5" stroke-width="1.3"/>')
RUNGS = ('<path d="M14 16 H30 M16 10 H32 M18 4 H34" stroke="#dfe9f5" '
         'stroke-width="1.4"/>')

def marks_strip(cells):
    return ('<div class="row" style="gap:22px;margin-top:12px">'
            + "".join(mark_cell(s, c) for s, c in cells) + '</div>')

marks_page = ('<div style="margin-top:6px">'
              + bare_row("Duel", DUEL_NOTE,
                         extra=marks_strip([(SIDES_11, "1 v 1"),
                                            (ONE_LIFE, "one life"),
                                            (RUNGS, "rungs")]))
              + bare_row("Team Battle", TB_NOTE, lit=True,
                         extra=marks_strip([(SIDES_44, "4 v 4"),
                                            (DIAL, "3:00"),
                                            (CROSS, "kills")]))
              + '</div>')
write("FormatMarks.dc.html", board(marks_page))

# ---- L: the rule card. Compact lines, the lit row unfolds its rules ----
#
# Every row carries the one-line spec; the row under the cursor opens the
# whole format as labeled lines behind a left rule, the reading grammar
# the hangar uses. The deepest answer for the least standing ink, at the
# cost of hiding the comparison a table gives away free.
def compact_row(name, line, lit=False, extra=""):
    bg = ("background:linear-gradient(90deg,rgba(79,214,255,.14),"
          "rgba(79,214,255,0) 85%);" if lit else "")
    return (f'<div style="padding:12px 14px;margin:0 -14px;{bg}">'
            f'<div class="name">{name}</div>'
            '<div class="mono" style="font-size:11px;color:#9fb6d4;'
            f'margin-top:3px">{line}</div>' + extra + '</div>')

def rule(label, text):
    return ('<div style="margin-top:9px">'
            f'<span class="lbl">{label}</span>'
            '<div class="note" style="text-transform:none;font-size:10.5px;'
            f'line-height:1.5;margin-top:2px;color:#9fb6d4">{text}</div>'
            '</div>')

tb_rules = ('<div style="border-left:1px solid rgba(79,214,255,.35);'
            'padding:2px 0 4px 14px;margin-top:11px">'
            + rule("sides", "two of four; AI holds every empty seat and "
                   "stands down when somebody arrives")
            + rule("time", "three-minute matches, fifteen seconds between")
            + rule("scoring", "a kill scores its victim's bounty: one, "
                   "plus one for each kill on their run")
            + rule("grounds", "six in rotation, a new one every match")
            + '</div>')
card_page = ('<div style="margin-top:6px">'
             + compact_row("Duel", "1 v 1 · one life · rungs")
             + compact_row("Team Battle", "4 v 4 · 3:00 · kills", lit=True,
                           extra=tb_rules)
             + '</div>')
write("RuleCard.dc.html", board(card_page))

print("boards written")
