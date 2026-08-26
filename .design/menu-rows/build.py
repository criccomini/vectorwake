#!/usr/bin/env python3
# The row-grammar boards: one way to draw a hovered or standing row, proposed
# against the seven ways ui.lua draws one today. Chrome and hues are the
# drawer's own: 390 wide, ink dfe9f5, dim 6c7a90, friend 4fd6ff, gold ffd166,
# lbl 9px mono upper. The proposal in one line: the lit field is wash() at the
# full drawer span with two weights, 0.18 under the cursor and 0.07 where you
# already are, and every row's text lives in one column 36 from either edge.
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


def write(name, body, style=STYLE):
    pathlib.Path(OUT, name).write_text(
        HEAD.format(style=style) + body + FOOT)


# ---- The proposed field, as CSS. wash() is a flat fill at 0.8a with a skirt
# adding 0.6a against the left rule, falling off over 130 points. ----
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


# A row of the column: full-bleed field, text in the 36 column. The container
# pads 14, so the bleed is -14 and the text pad is 36.
def bleed(content, state=None, pad="0 36px", extra=""):
    return (f'<div style="margin:0 -14px;padding:{pad};'
            + state_bg(state) + extra + '">' + content + '</div>')


# ---- Shared drawer chrome, borrowed from ../play-menu/build.py ----
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


# The foot rail. The lit stop keeps its tab gradient; a stop under the
# pointer takes the cursor weight on its own slot, which is the same rule the
# rows follow: the field is the hit box.
def rail(lit="play", hover=None):
    cells = []
    for name in STOPS:
        on = name == lit
        c = "#4fd6ff" if on else "#6c7a90"
        tc = "var(--ink)" if on else "var(--dim)"
        bg = ("background:linear-gradient(0deg,rgba(79,214,255,.14),"
              "rgba(79,214,255,0) 80%);" if on else "")
        if name == hover and not on:
            bg = "background:rgba(79,214,255,.144);"
            c, tc = "#4fd6ff", "var(--ink)"
        cells.append('<div style="flex:1;display:flex;flex-direction:column;'
                     'align-items:center;justify-content:center;gap:4px;'
                     f'height:100%;padding-bottom:14px;{bg}">'
                     + ICONS[name].format(c=c)
                     + f'<span style="font-size:9px;color:{tc}">{name}</span>'
                     '</div>')
    return ('<div style="position:absolute;left:0;right:0;bottom:0;height:78px;'
            'border-top:1px solid rgba(63,88,120,.6);display:flex">'
            + "".join(cells) + '</div>')


def board(body, lit="play", hover=None, head=None):
    head = topline() if head is None else head
    return (f'<div style="position:relative;width:390px;height:844px;'
            f'overflow:hidden;{stars(390, 844)}">'
            + fight(390, 844)
            + '<div style="position:absolute;inset:0;'
            'background:rgba(3,5,10,.86)"></div>'
            + '<div style="position:absolute;left:0;right:0;top:0;'
            'bottom:78px;padding:0 14px;overflow:hidden">'
            + head + body + '</div>'
            + rail(lit, hover) + '</div>')


# ---- Small vocabulary the pages share ----
def sect(label, mt=18):
    return (f'<div style="margin-top:{mt}px;padding:0 36px 0;margin-left:'
            '-14px;margin-right:-14px">'
            '<div style="border-top:1px solid rgba(63,88,120,.45)"></div>'
            f'<div class="lbl" style="margin-top:8px">{label}</div></div>')


def circles(held, owned, top=6, gold=False):
    c = "#ffd166" if gold else "#4fd6ff"
    out = []
    for k in range(top):
        if k < held:
            out.append(f'<span style="width:9px;height:9px;'
                       f'border-radius:50%;background:{c};flex:none"></span>')
        elif k < owned:
            out.append('<span style="width:9px;height:9px;border-radius:50%;'
                       f'border:1.4px solid {c};flex:none"></span>')
        else:
            out.append('<span style="width:9px;height:9px;border-radius:50%;'
                       'border:1.4px solid rgba(108,122,144,.4);flex:none">'
                       '</span>')
    return ('<div class="row" style="gap:4px">' + "".join(out) + '</div>')


def rivet(n, dim=False):
    c = "rgba(108,122,144,.55)" if dim else "#ffd166"
    return ('<span class="row" style="gap:4px;flex:none">'
            f'<svg width="9" height="9" viewBox="0 0 10 10"><circle cx="5" '
            f'cy="5" r="4" fill="none" stroke="{c}" stroke-width="1.2"/>'
            f'<circle cx="5" cy="5" r="1.4" fill="{c}"/></svg>'
            f'<span class="mono" style="font-size:11.5px;color:{c}">{n}'
            '</span></span>')


def charge_key(n, hot=False):
    ec = "rgba(255,209,102," + (".9" if hot else ".5") + ")"
    bg = "rgba(255,209,102," + (".16" if hot else ".07") + ")"
    tc = "rgba(255,209,102," + ("1" if hot else ".8") + ")"
    return (f'<span class="key" style="height:18px;padding:0 9px;'
            f'font-size:9px;letter-spacing:.13em;border-color:{ec};'
            f'background:{bg};color:{tc}">charge {n}</span>')


def spec_strip(cells, ink=1.0):
    out = []
    for i, (l, v) in enumerate(cells):
        if i > 0:
            out.append('<div style="width:1px;align-self:stretch;'
                       'background:rgba(63,88,120,.45)"></div>')
        out.append('<div class="col" style="align-items:flex-start">'
                   f'<span class="lbl">{l}</span>'
                   '<span class="mono" style="font-size:13px;'
                   f'color:rgba(223,233,245,{ink});margin-top:3px;'
                   f'white-space:nowrap">{v}</span></div>')
    return ('<div class="row" style="gap:14px;margin-top:10px;'
            'align-items:stretch">' + "".join(out) + '</div>')


# ============================ Main: the rule ============================
#
# The anatomy board: three rows of a drawer slice, at rest, under the cursor,
# and the one you are standing in, with the measures called out beside them.
def anatomy():
    def r(label, state, ink, extra_right=""):
        color = ("#4fd6ff" if state == "here"
                 else f"rgba(223,233,245,{ink})")
        return bleed(
            '<div class="row" style="height:52px">'
            f'<span style="font-size:17px;color:{color}">{label}</span>'
            '<div style="flex:1"></div>' + extra_right + '</div>',
            state=state)
    slice_ = ('<div style="position:relative;width:390px;'
              'background:rgba(3,5,10,.92);border:1px solid '
              'rgba(63,88,120,.6);padding:10px 14px">'
              + r("A row at rest", None, 0.85,
                  '<span class="mono" style="font-size:11.5px;'
                  'color:rgba(223,233,245,.8)">value</span>')
              + r("The row under the cursor", "cursor", 1.0,
                  '<span class="mono" style="font-size:11.5px;'
                  'color:#dfe9f5">value</span>')
              + r("The row you are standing in", "here", 1.0,
                  '<span class="mono" style="font-size:11.5px;'
                  'color:rgba(223,233,245,.95)">value</span>')
              + '</div>')
    # Measure marks over the slice, drawn as an SVG the width of the board.
    # The slice sits at (96,96); rows are 52 tall behind 11 points of box
    # edge, so their centers land at 133, 185 and 237, the field spans
    # x 97 to 485, and the text column runs 133 to 449.
    marks = """
<svg width="880" height="470" viewBox="0 0 880 470"
     style="position:absolute;inset:0;pointer-events:none"
     font-family="DejaVu Sans Mono,monospace" font-size="10">
  <g stroke="#6c7a90" stroke-width="1" fill="none" opacity=".9">
    <path d="M97 92 V78 M133 92 V78 M97 84 H133"/>
    <path d="M449 92 V78 M485 92 V78 M449 84 H485"/>
    <path d="M97 280 V296 M485 280 V296 M97 288 H485"/>
    <path d="M227 268 V278"/>
  </g>
  <g fill="#9fb6d4">
    <text x="115" y="74" text-anchor="middle">36</text>
    <text x="467" y="74" text-anchor="middle">36</text>
    <text x="291" y="312" text-anchor="middle">the field and the hit box: the drawer span, edge to edge</text>
    <text x="227" y="332" text-anchor="middle">skirt: +0.6a against the left rule, gone by 130</text>
  </g>
  <g fill="#6c7a90">
    <text x="530" y="128">rest: no field, ink 0.85</text>
    <text x="530" y="144">unpressable rows dim to 0.55, never lit</text>
    <text x="530" y="180">cursor: wash(FRIEND, 0.18), ink to 1.0</text>
    <text x="530" y="196">hover and the arrow cursor are the same fact</text>
    <text x="530" y="232">here: wash(FRIEND, 0.07), label in FRIEND</text>
    <text x="530" y="248">the game you fly, your hull, the loaded build;</text>
    <text x="530" y="264">replaces the wedge, and the cursor outranks it</text>
  </g>
  <g stroke="#3f5878" stroke-width="1" opacity=".8">
    <path d="M524 124 L490 124"/>
    <path d="M524 176 L490 176"/>
    <path d="M524 228 L490 228"/>
  </g>
</svg>"""
    body = ('<div style="position:relative;width:880px;height:470px;'
            'background:#05070c;overflow:hidden">'
            '<div style="position:absolute;left:96px;top:96px">'
            + slice_ + '</div>' + marks
            + '<div class="lbl" style="position:absolute;left:96px;top:36px;'
            'font-size:10px;color:#9fb6d4">one row grammar: the field</div>'
            '<div class="note" style="position:absolute;left:96px;top:54px">'
            'wash() at the drawer span, two weights, one text column'
            '</div></div>')
    write("Main.dc.html", body)


# ========================= Current: the seven =========================
#
# Every treatment the client draws today, one specimen each, drawn to its own
# geometry inside a mini drawer whose edges are marked, so the insets and the
# overhangs are visible instead of described.
def current():
    W = 300   # mini drawer width
    L = 45    # its left edge inside the board

    def strip(title, cite, inner, h=34):
        edges = (f'<div style="position:absolute;left:0;top:0;bottom:0;'
                 'width:1px;background:rgba(108,122,144,.5)"></div>'
                 f'<div style="position:absolute;right:0;top:0;bottom:0;'
                 'width:1px;background:rgba(108,122,144,.5)"></div>')
        return ('<div style="margin:20px 0 0 0;padding:0 45px">'
                f'<div class="row" style="gap:8px;margin-bottom:5px">'
                f'<span class="lbl" style="color:#9fb6d4">{title}</span>'
                f'<span class="lbl" style="letter-spacing:.06em">{cite}'
                '</span></div>'
                f'<div style="position:relative;width:{W}px;height:{h}px">'
                + edges + inner + '</div></div>')

    def txt(label, x, ink=0.9, size=13, color=None):
        c = color or f"rgba(223,233,245,{ink})"
        return (f'<span style="position:absolute;left:{x}px;top:50%;'
                f'transform:translateY(-50%);font-size:{size}px;'
                f'color:{c}">{label}</span>')

    def wash_css(a, l, r, top=0):
        lo, hi = a * 0.8, a * 1.4
        return (f'<div style="position:absolute;left:{l}px;right:{r}px;'
                f'top:{top}px;bottom:0;background:linear-gradient(90deg,'
                f'rgba(79,214,255,{hi:.3f}),rgba(79,214,255,{lo:.3f}) 110px,'
                f'rgba(79,214,255,{lo:.3f}))"></div>')

    def flat(a, l, r, top=0, bottom=0):
        return (f'<div style="position:absolute;left:{l}px;right:{r}px;'
                f'top:{top}px;bottom:{bottom}px;'
                f'background:rgba(79,214,255,{a})"></div>')

    s1 = strip("stage rows &middot; play, settings", "ui.lua:6160",
               wash_css(0.18, 0, 0) + txt("Team Battle", 36))
    s2 = strip("kit rows &middot; ship page", "ui.lua:4876",
               wash_css(0.2, 0, 14, top=2) + txt("Repel", 14, size=12))
    s3 = strip("kit rows, page unfocused", "ui.lua:4878",
               wash_css(0.1, 0, 14, top=2) + txt("Repel", 14, 0.8, size=12))
    s4 = strip("friends rows", "ui.lua:5478",
               flat(0.16, 20, 20) + txt("Halcyon 9", 36))
    s5 = strip("builds rows", "ui.lua:5196",
               wash_css(0.2, 0, -14) + txt("brawler", 36, size=12))
    s6 = strip("ship grid cell", "ui.lua:6632",
               flat(0.14, 4, 4, top=2, bottom=2)
               + txt("Vanguard", 0, 1, 12,
                     color="#dfe9f5").replace('left:0px',
                                              'left:50%;margin-left:-28px'))
    s7 = strip("rail stop", "ui.lua:7419",
               flat(0.16, 3, 3) + txt("ship", 0, 1, 11,
                                      color="#dfe9f5").replace(
                                          'left:0px',
                                          'left:50%;margin-left:-12px'))
    s8 = strip("call sign results", "ui.lua:5398",
               flat(0.16, 0, 0) + txt("Vex", 11, 1, 13))
    head = ('<div style="padding:26px 45px 0">'
            '<div class="lbl" style="font-size:10px;color:#9fb6d4">'
            'as shipped: eight fields for one idea</div>'
            '<div class="note" style="margin-top:6px;line-height:1.5">'
            'Every specimen is the row a cursor is resting on, drawn to its '
            'own geometry. The thin rules are the drawer&#39;s edges. '
            'Alphas run 0.1 to 0.2, text starts at 0, 11, 14 or 36, and one '
            'field overhangs the panel it sits in.</div></div>')
    body = ('<div style="width:390px;height:844px;background:#05070c;'
            'overflow:hidden">' + head
            + s1 + s2 + s3 + s4 + s5 + s6 + s7 + s8 + '</div>')
    write("Current.dc.html", body)


# ============================ Play page ============================
def play():
    duel = bleed(
        '<div style="padding:13px 0 12px">'
        '<div class="name">Duel</div>'
        '<div class="note" style="margin-top:2px">Every rung is a harder '
        'rival; a loss drops you two</div>'
        + spec_strip([("teams", "1 v 1"), ("time", "one life"),
                      ("scoring", "rungs")]) + '</div>',
        state="cursor")
    tb = bleed(
        '<div style="padding:13px 0 12px">'
        '<div class="row" style="align-items:flex-start">'
        '<div class="col" style="flex:1;min-width:0">'
        '<div class="name" style="color:#4fd6ff">Team Battle</div>'
        '<div class="note" style="margin-top:2px">The longer your run, the '
        'bigger the bounty on you</div></div>'
        '<span class="key" style="height:26px;padding:0 12px;font-size:10px">'
        'leave</span></div>'
        + spec_strip([("teams", "4 v 4"), ("time", "3:00"),
                      ("scoring", "kills")], ink=0.95) + '</div>',
        state="here")
    body = '<div style="margin-top:6px">' + duel + tb + '</div>'
    write("Play.dc.html", board(body))


# ============================ Ship page ============================
def ship():
    def kit_row(label, held, owned, state=None, top=6, gold=False,
                after="", price=None, level=None):
        hot = state == "cursor"
        ink = 0.95 if hot else 0.8
        lvl = ('<span class="mono" style="font-size:11px;'
               f'color:rgba(223,233,245,{0.95 if hot else 0.7});'
               f'margin-left:10px">{level}</span>' if level else '')
        pr = ('<div style="flex:1"></div>' + rivet(price)
              if price else '<div style="flex:1"></div>')
        return bleed(
            '<div class="row" style="height:26px">'
            f'<span style="font-size:12.5px;width:112px;flex:none;'
            f'color:rgba(223,233,245,{ink})">{label}</span>'
            + circles(held, owned, top, gold) + lvl
            + ('<span style="width:16px;flex:none"></span>' + after
               if after else '')
            + pr + '</div>', state=state)

    band = ('<div class="row" style="height:48px;gap:10px;border-bottom:'
            '1px solid rgba(63,88,120,.45);margin:0 -14px;padding:0 14px">'
            + X_KEY
            + '<span class="key" style="height:26px;padding:0 12px;'
            'font-size:11px;text-transform:none;letter-spacing:.02em">'
            'brawler</span>'
            '<div style="flex:1"></div>'
            '<span class="lbl">points</span>'
            + circles(3, 5, 5)
            + '</div>')
    body = (sect("guns", mt=14)
            + '<div style="margin-top:8px">'
            + kit_row("Gun", 2, 4, level="L3")
            + kit_row("Spray", 1, 3, level="2")
            + '</div>'
            + sect("charges")
            + '<div style="margin-top:8px">'
            + kit_row("Repel", 2, 3, state="cursor", top=3, gold=True,
                      after=charge_key(1, hot=True), price=200)
            + kit_row("Burst", 2, 3, top=3, gold=True,
                      after=charge_key(2), price=350)
            + '</div>'
            + sect("flight")
            + '<div style="margin-top:8px">'
            + kit_row("Thrust", 3, 4)
            + kit_row("Top speed", 2, 4)
            + '</div>')
    write("Ship.dc.html", board(body, lit="ship", head=band))


# ============================ Settings page ============================
def settings():
    def srow(label, state=None, value=None, pips=None, plabel=None):
        hot = state == "cursor"
        ink = 1.0 if hot else 0.85
        right = ""
        if pips is not None:
            n, on = pips
            cells = "".join(
                '<span style="width:13px;height:10px;flex:none;'
                + ('background:#4fd6ff'
                   if k < on else 'border:1px solid rgba(108,122,144,.6)')
                + '"></span>' for k in range(n))
            word = (f'<span class="lbl" style="margin-right:10px">{plabel}'
                    '</span>' if plabel else '')
            right = (word + '<div class="row" style="gap:5px">'
                     + cells + '</div>')
        elif value:
            right = ('<span class="mono" style="font-size:11.5px;'
                     f'color:rgba(108,122,144,{1 if hot else 0.85})">'
                     f'{value}</span>')
        return bleed(
            '<div class="row" style="height:40px">'
            f'<span style="font-size:17px;color:rgba(223,233,245,{ink})">'
            f'{label}</span><div style="flex:1"></div>' + right + '</div>',
            state=state)

    body = (sect("video", mt=14)
            + '<div style="margin-top:6px">'
            + srow("Frames", pips=(3, 1), plabel="display")
            + srow("Fullscreen", state="cursor", value="Fill the screen")
            + srow("Add to home screen", value="One tap")
            + '</div>'
            + sect("sound")
            + '<div style="margin-top:6px">'
            + srow("Volume", pips=(4, 3))
            + '</div>')
    write("Settings.dc.html", board(body, lit="settings"))


# ==================== Elsewhere: the rule travels ====================
#
# The friends list and the builds list move onto the same field, and the two
# shapes that are not rows, the ship grid and the foot rail, take the same
# two weights on their own hit shapes.
def elsewhere():
    def frow(name, detail=None, flying=False, state=None, act=None):
        hot = state == "cursor"
        ink = 1.0 if hot else 0.9
        dot = ('<span style="width:6px;height:6px;background:#4fd6ff;'
               'flex:none;margin-right:7px"></span>' if flying else '')
        det = (f'<span class="mono" style="font-size:11.5px;color:'
               + ('#4fd6ff' if flying else 'rgba(108,122,144,.95)')
               + f'">{detail}</span>' if detail else '')
        right = (f'<span class="key" style="height:26px;padding:0 12px;'
                 f'font-size:10px">{act}</span>' if act else '')
        return bleed(
            '<div class="row" style="height:40px;gap:0">'
            f'<span style="font-size:16px;color:rgba(223,233,245,{ink});'
            f'width:150px;flex:none">{name}</span>'
            + dot + det + '<div style="flex:1"></div>' + right + '</div>',
            state=state)

    def brow(name, state=None, starter=False):
        hot = state == "cursor"
        color = "#4fd6ff" if state == "here" else \
            f"rgba(223,233,245,{1 if hot else 0.85})"
        right = ('<span class="lbl">starter</span>' if starter else '')
        return bleed(
            '<div class="row" style="height:30px">'
            f'<span style="font-size:13px;color:{color}">{name}</span>'
            '<div style="flex:1"></div>' + right + '</div>', state=state)

    hull = ('<svg width="46" height="46" viewBox="0 0 32 32" fill="none" '
            'stroke="{c}" stroke-width="1.4"><g transform="translate(16,17) '
            'scale(1.05)"><path d="M0,-13 L15,9 L7,12 L0,8 L-7,12 L-15,9 Z"/>'
            '</g></svg>')

    def cell(name, role, state=None):
        bg = ("background:rgba(79,214,255,.144);" if state == "cursor"
              else "background:rgba(79,214,255,.056);" if state == "here"
              else "")
        c = "#4fd6ff" if state == "here" else \
            ("#dfe9f5" if state == "cursor" else "rgba(223,233,245,.7)")
        return ('<div class="col" style="align-items:center;'
                f'justify-content:center;gap:4px;height:104px;{bg}">'
                + hull.format(c=c)
                + f'<span style="font-size:14px;color:{c}">{name}</span>'
                + f'<span class="lbl" style="letter-spacing:.1em">{role}'
                '</span></div>')

    body = (sect("friends, on the field", mt=14)
            + '<div style="margin-top:6px">'
            + frow("Halcyon 9", "In Team Battle", flying=True,
                   state="cursor", act="join")
            + frow("Sable", "Seen yesterday")
            + '</div>'
            + sect("builds, on the field")
            + '<div style="margin-top:6px">'
            + brow("brawler", state="here")
            + brow("runner", state="cursor")
            + brow("first wings", starter=True)
            + '</div>'
            + sect("cells and stops: same weights, their own hit shapes")
            + '<div style="display:grid;grid-template-columns:repeat(2,'
            'minmax(0,1fr));margin:10px -14px 0">'
            + cell("Vanguard", "brawler", state="here")
            + cell("Warden", "anchor", state="cursor")
            + '</div>')
    write("Elsewhere.dc.html", board(body, lit="friends", hover="ship"))


anatomy()
current()
play()
ship()
settings()
elsewhere()
print("boards written")
