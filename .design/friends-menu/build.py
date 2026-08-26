#!/usr/bin/env python3
# The friends-page rethink boards, assembled from shared fragments so the
# chrome (top line, rail, row grammar) stays identical across every board.
# Sizes and colors are the drawer's own: 390 wide, MENU_PAD 20, ink dfe9f5,
# dim 6c7a90, friend 4fd6ff, enemy ffa552, bounty gold ffd166, key boxes on
# rgba(63,88,120,.75), lbl 9px mono upper. The people are the same eight on
# every board so the directions compare: Halcyon 2 flying Team Battle,
# Vireo 9 and Sable 09 off, Gantry 4 waiting on an answer, Plinth 41 asked
# and unanswered, Krait 4 and Orrery 3 in your room, Mantis 7 ignored.
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
  font-family:var(--mono);font-size:11px;text-transform:uppercase;
  letter-spacing:.06em;color:#9fb6d4}
.gokey{border-color:rgba(79,214,255,.6);color:var(--friend)}
.name{font-size:16px;color:var(--ink)}
.note{font-family:var(--mono);font-size:11px;color:var(--dim)}
.mono{font-family:var(--mono)}
.hrule{height:1px;background:rgba(63,88,120,.45)}
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

# The room behind the drawer, since the drawer is always semi-opaque: two
# hulls trading fire around a pair of wall modules, bright on purpose so
# what survives the 0.86 wash is what a player actually sees bleed through.
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

PILL = ('<div class="key" style="height:26px;padding:0 13px;'
        'letter-spacing:.02em;text-transform:none">Delta 154</div>')

def topline():
    return ('<div class="row" style="height:48px;gap:10px;'
            'border-bottom:1px solid rgba(63,88,120,.45);margin:0 -20px;'
            'padding:0 20px">' + X_KEY + '<div style="flex:1"></div>'
            + PILL + '</div>')

ICONS = {
 "zones": '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="{c}" stroke-width="1.3"><circle cx="8" cy="8" r="3.4"/><ellipse cx="8" cy="8" rx="7" ry="2.6" transform="rotate(-18 8 8)"/></svg>',
 "ship": '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="{c}" stroke-width="1.3"><g transform="translate(8,8.6) scale(.5)"><path d="M0,-13 L15,9 L7,12 L0,8 L-7,12 L-15,9 Z"/></g></svg>',
 "friends": '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="{c}" stroke-width="1.2"><path d="M2 8.6 A3.6 3.6 0 0 1 9.2 8.6 M1.4 10 H9.8" opacity=".55"/><path d="M6.4 11.2 A3.9 3.9 0 0 1 14.2 11.2 M5.7 12.8 H14.9"/></svg>',
 "pilot": '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="{c}" stroke-width="1.3"><path d="M2.6 9.8 A5.5 5.5 0 0 1 13.4 9.8"/><path d="M1.6 11.6 H14.4"/></svg>',
 "settings": '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="{c}" stroke-width="1.3"><path d="M2 4.5 H14 M2 8 H14 M2 11.5 H14"/><circle cx="10.5" cy="4.5" r="1.8" fill="#0a0f18"/><circle cx="5.5" cy="8" r="1.8" fill="#0a0f18"/><circle cx="9.5" cy="11.5" r="1.8" fill="#0a0f18"/></svg>',
}
STOPS = ["zones", "ship", "friends", "settings", "pilot"]

def rail(lit="friends"):
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

def board(body):
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
{fight(390, 844)}
<div style="position:absolute;inset:0;background:rgba(3,5,10,.86)"></div>
<div style="position:absolute;left:0;right:0;top:0;bottom:78px;padding:0 20px;overflow:hidden">
{topline()}
{body}
</div>
{rail()}
</div>
</x-dc>

</body>
</html>
"""

def write(name, html):
    pathlib.Path(OUT, name).write_text(html)

# One section head as the page draws it: the rule, the mono label, the count
# in team blue beside it, and the sentence under it where the section has one.
def sect(label, count=None, line=None, top=16):
    extra = (f'<span class="mono" style="font-size:9px;color:var(--friend);'
             f'margin-left:10px;letter-spacing:.13em">{count}</span>'
             if count is not None else "")
    said = (f'<div class="note" style="font-size:11.5px;line-height:15px;'
            f'margin-top:4px">{line}</div>' if line else "")
    return (f'<div style="margin-top:{top}px">'
            '<div class="hrule" style="margin-bottom:8px"></div>'
            f'<span class="lbl">{label}</span>' + extra + said + '</div>')

def key(label, go=False, w=None, h=26):
    cls = "key gokey" if go else "key"
    ww = f"width:{w}px;" if w else "padding:0 12px;"
    return f'<div class="{cls}" style="height:{h}px;{ww}flex:none">{label}</div>'

# The flying dot, the one mark on the shipped page that says "now".
DOT = ('<span style="width:6px;height:6px;background:var(--friend);'
       'flex:none"></span>')

# ---- As shipped: the field, then five sections of one row grammar ----------

def cur_row(name, detail, keys, lit=False, dim=False, detail_col="var(--dim)",
            dot=False):
    bg = ("background:linear-gradient(90deg,rgba(79,214,255,.14),"
          "rgba(79,214,255,0) 85%);" if lit else "")
    ink = "rgba(223,233,245,.6)" if dim else "var(--ink)"
    d = ((DOT + '<span style="width:7px"></span>') if dot else "")
    return (f'<div class="row" style="min-height:52px;margin:0 -20px;'
            f'padding:6px 20px;{bg}">'
            '<div class="col" style="flex:1;min-width:0;gap:3px">'
            f'<span class="name" style="font-size:15px;color:{ink}">{name}'
            '</span>'
            f'<span class="row mono" style="font-size:11.5px;'
            f'color:{detail_col}">{d}{detail}</span></div>'
            '<div class="row" style="gap:8px">' + keys + '</div></div>')

FIELD = ('<div class="row" style="gap:10px;margin-top:6px">'
         '<div class="row" style="flex:1;height:30px;'
         'border:1px solid rgba(63,88,120,.7);border-radius:15px;'
         'padding:0 12px">'
         '<span class="mono" style="font-size:11px;color:rgba(108,122,144,.8);'
         'letter-spacing:.08em">A CALL SIGN</span></div>'
         + key("add", go=True) + '</div>')

cur = ('<div class="lbl" style="margin-top:14px">add a pilot</div>'
       + FIELD
       + sect("waiting on you", 1,
              "They added you; accept and you are friends, ignore and they"
              " go to everybody", top=20)
       + cur_row("Gantry 4", "added you 2h ago",
                 key("accept", go=True) + key("ignore"))
       + sect("friends", "3, 1 flying")
       + cur_row("Halcyon 2", "team battle",
                 key("join", go=True) + key("unfriend"), lit=True,
                 detail_col="var(--friend)", dot=True)
       + cur_row("Vireo 9", "not on", key("unfriend"))
       + cur_row("Sable 09", "not on", key("unfriend"))
       + sect("sent", 1)
       + cur_row("Plinth 41", "3d ago", key("cancel"))
       + sect("in this game", 2)
       + cur_row("Krait 4", "", key("add", go=True))
       + cur_row("Orrery 3", "", key("add", go=True))
       + sect("everybody who added you", 3,
              "The ones you ignored, and the ones it came to something"))
write("Current.dc.html", board(cur))

# ---- A: deck watch. The page reorders around now ---------------------------
#
# A friend in a game is the fact this page exists for, so they get the play
# page's live-row grammar: name large, the game and its clock as
# label-over-value stacks, the whole row lit and the whole row the join.
# Everything that is not now quiets down around them: off friends are a
# plain roll, an add waiting on you is a hail band answered in place, the
# field folds behind the ADD key, and the ledger is one drill-in row at the
# foot. The clock is honest: the directory already lists the friend's
# instance, and its room's clock is the one the play page counts down.

def stack(label, value, col="var(--ink)"):
    return ('<div class="col" style="align-items:flex-start;min-width:0">'
            f'<span class="lbl">{label}</span>'
            f'<span class="mono" style="font-size:13px;color:{col};'
            'margin-top:3px;white-space:nowrap">{v}</span></div>'
            ).replace("{v}", value)

def stacks(cells):
    out = []
    for i, (l, v) in enumerate(cells):
        if i > 0:
            out.append('<div style="width:1px;align-self:stretch;'
                       'background:rgba(63,88,120,.45)"></div>')
        out.append(stack(l, v))
    return ('<div class="row" style="gap:14px;margin-top:10px;'
            'align-items:stretch">' + "".join(out) + '</div>')

def live_friend(name, cells):
    return ('<div style="margin:0 -20px;padding:13px 20px 14px;'
            'background:linear-gradient(90deg,rgba(79,214,255,.14),'
            'rgba(79,214,255,0) 85%)">'
            '<div class="row">'
            f'<span class="name" style="font-size:17px">{name}</span>'
            '<div style="flex:1"></div>' + key("join", go=True, h=30)
            + '</div>' + stacks(cells) + '</div>')

def quiet_row(name, right="", h=36, dim=True):
    ink = "rgba(223,233,245,.75)" if dim else "var(--ink)"
    return (f'<div class="row" style="height:{h}px;margin:0 -20px;'
            'padding:0 20px">'
            f'<span class="name" style="font-size:15px;color:{ink}">{name}'
            '</span><div style="flex:1"></div>' + right + '</div>')

HAIL = ('<div style="border-left:1px solid rgba(255,209,102,.55);'
        'padding:8px 0 9px 14px;margin-top:10px">'
        '<div class="row">'
        '<div class="col" style="flex:1;gap:3px">'
        '<span class="name" style="font-size:15px">Gantry 4</span>'
        '<span class="mono" style="font-size:10.5px;color:var(--gold)">'
        'added you 2h ago</span></div>'
        + key("accept", go=True) + '<span style="width:8px"></span>'
        + key("ignore") + '</div></div>')

CHEV = ('<svg width="7" height="10" viewBox="0 0 10 14">'
        '<path d="M2 1.5 L7.5 7 L2 12.5 Z" fill="rgba(79,214,255,.45)"/>'
        '</svg>')

deck = ('<div class="row" style="margin-top:14px">'
        '<span class="lbl">friends</span>'
        '<span class="mono" style="font-size:9px;color:var(--friend);'
        'margin-left:10px;letter-spacing:.13em">3</span>'
        '<div style="flex:1"></div>' + key("add a pilot") + '</div>'
        + sect("waiting on you", 1, top=18)
        + HAIL
        + sect("on now", 1, top=22)
        + '<div style="margin-top:8px"></div>'
        + live_friend("Halcyon 2", [("game", "team battle"),
                                    ("time", "1:12"),
                                    ("ground", "shoal")])
        + sect("off", 2, top=18)
        + quiet_row("Vireo 9") + quiet_row("Sable 09")
        + sect("sent", 1, top=14)
        + quiet_row("Plinth 41",
                    '<span class="mono" style="font-size:10.5px;'
                    'color:var(--dim)">3d ago</span>')
        + sect("in this game", 2, top=14)
        + quiet_row("Krait 4", key("add", go=True), dim=False)
        + quiet_row("Orrery 3", key("add", go=True), dim=False)
        + '<div style="margin-top:18px"><div class="hrule"></div>'
        '<div class="row" style="height:40px">'
        '<span class="mono" style="font-size:11px;color:var(--dim)">'
        'everybody who added you</span>'
        '<span class="mono" style="font-size:9px;color:var(--friend);'
        'margin-left:10px">3</span>'
        '<div style="flex:1"></div>' + CHEV + '</div></div>')
write("Main.dc.html", board(deck))

# ---- B: the manifest. One roster, a mark carries the state -----------------
#
# Every person is one line whatever their state, so the page is a single
# aligned reading: the mark says what they are, the WHERE column says where,
# and at most one key rides the line. The states stop being five sections
# and become a sort: flying, asking, in your room, off, sent. Scales to the
# hundred-edge cap without a second screen.

def mark(kind):
    if kind == "on":
        return ('<span style="width:8px;height:8px;background:var(--friend);'
                'flex:none"></span>')
    if kind == "ask":
        return ('<span style="width:8px;height:8px;border:1.4px solid '
                'var(--gold);flex:none"></span>')
    if kind == "here":
        return ('<svg width="9" height="9" viewBox="0 0 10 10" flex="none">'
                '<path d="M5 0 V10 M0 5 H10" stroke="#9fb6d4" '
                'stroke-width="1.6"/></svg>')
    if kind == "sent":
        return ('<svg width="9" height="9" viewBox="0 0 10 10">'
                '<path d="M1 9 L9 1 M4 1 H9 V6" stroke="#6c7a90" '
                'stroke-width="1.4" fill="none"/></svg>')
    return ('<span style="width:8px;height:8px;border:1.4px solid '
            'rgba(108,122,144,.6);flex:none"></span>')

def man_row(kind, name, where, where_col, k="", lit=False, dim=False):
    bg = ("background:linear-gradient(90deg,rgba(79,214,255,.14),"
          "rgba(79,214,255,0) 85%);" if lit else "")
    ink = "rgba(223,233,245,.65)" if dim else "var(--ink)"
    kk = k if k else CHEV
    return (f'<div class="row" style="height:40px;margin:0 -20px;'
            f'padding:0 20px;gap:11px;{bg}">' + mark(kind)
            + f'<span class="name" style="font-size:15px;color:{ink};'
            'flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;'
            f'white-space:nowrap">{name}</span>'
            f'<span class="mono" style="font-size:10px;color:{where_col};'
            f'letter-spacing:.08em">{where}</span>' + kk + '</div>')

MAN_HEAD = ('<div class="row" style="margin:16px -20px 0;padding:0 20px 7px;'
            'border-bottom:1px solid rgba(63,88,120,.45)">'
            '<span class="lbl">pilot</span><div style="flex:1"></div>'
            '<span class="lbl">where</span></div>')

LEGEND = ('<div class="row" style="gap:16px;margin-top:12px">'
          '<span class="row" style="gap:6px">' + mark("on")
          + '<span class="lbl">flying</span></span>'
          '<span class="row" style="gap:6px">' + mark("ask")
          + '<span class="lbl">asking</span></span>'
          '<span class="row" style="gap:6px">' + mark("here")
          + '<span class="lbl">your room</span></span>'
          '<span class="row" style="gap:6px">' + mark("off")
          + '<span class="lbl">off</span></span></div>')

man = ('<div class="row" style="margin-top:14px">'
       '<span class="lbl">friends</span>'
       '<span class="mono" style="font-size:9px;color:var(--friend);'
       'margin-left:10px;letter-spacing:.13em">3</span>'
       '<div style="flex:1"></div>' + key("add a pilot") + '</div>'
       + MAN_HEAD
       + man_row("on", "Halcyon 2", "TEAM BATTLE 1:12", "var(--friend)",
                 key("join", go=True), lit=True)
       + man_row("ask", "Gantry 4", "ADDED YOU 2H", "var(--gold)",
                 key("accept", go=True))
       + man_row("here", "Krait 4", "YOUR ROOM", "#9fb6d4",
                 key("add", go=True))
       + man_row("here", "Orrery 3", "YOUR ROOM", "#9fb6d4",
                 key("add", go=True))
       + man_row("off", "Vireo 9", "", "var(--dim)", dim=True)
       + man_row("off", "Sable 09", "", "var(--dim)", dim=True)
       + man_row("sent", "Plinth 41", "SENT 3D", "var(--dim)", dim=True)
       + LEGEND
       + '<div style="margin-top:20px"><div class="hrule"></div>'
       '<div class="row" style="height:40px">'
       '<span class="mono" style="font-size:11px;color:var(--dim)">'
       'everybody who added you</span>'
       '<span class="mono" style="font-size:9px;color:var(--friend);'
       'margin-left:10px">3</span>'
       '<div style="flex:1"></div>' + CHEV + '</div></div>')
write("Manifest.dc.html", board(man))

# ---- C: the crew wall. Friends drawn as crew, not listed as rows -----------
#
# A plaque each: helmet mark, call sign, and what they are doing, lit when
# they are flying with the join on the plaque. The one direction that looks
# like the game rather than a table; a press anywhere on a plaque raises
# the same card the rows raise today.

HELMET = ('<svg width="26" height="26" viewBox="0 0 16 16" fill="none" '
          'stroke="{c}" stroke-width="1.1">'
          '<path d="M2.6 9.8 A5.5 5.5 0 0 1 13.4 9.8"/>'
          '<path d="M1.6 11.6 H14.4"/></svg>')

def plaque(name, state, kind):
    if kind == "on":
        edge, hc = "rgba(79,214,255,.65)", "#4fd6ff"
        st = ('<span class="mono" style="font-size:9px;'
              f'color:var(--friend);letter-spacing:.08em">{state}</span>')
        foot = ('<div class="key gokey" style="height:22px;width:100%;'
                'font-size:10px;margin-top:8px">join</div>')
        bg = "background:rgba(79,214,255,.06);"
    elif kind == "ask":
        edge, hc = "rgba(255,209,102,.55)", "#ffd166"
        st = ('<span class="mono" style="font-size:9px;color:var(--gold);'
              f'letter-spacing:.08em">{state}</span>')
        foot = ('<div class="key gokey" style="height:22px;width:100%;'
                'font-size:10px;margin-top:8px">accept</div>')
        bg = ""
    elif kind == "here":
        edge, hc = "rgba(63,88,120,.75)", "#9fb6d4"
        st = ('<span class="mono" style="font-size:9px;color:#9fb6d4;'
              f'letter-spacing:.08em">{state}</span>')
        foot = ('<div class="key" style="height:22px;width:100%;'
                'font-size:10px;margin-top:8px">add</div>')
        bg = ""
    else:
        edge, hc = "rgba(63,88,120,.55)", "#6c7a90"
        st = ('<span class="mono" style="font-size:9px;color:var(--dim);'
              f'letter-spacing:.08em">{state}</span>')
        foot = '<div style="height:30px"></div>'
        bg = ""
    return (f'<div class="col" style="border:1px solid {edge};{bg}'
            'padding:14px 10px 10px;align-items:center;gap:6px">'
            + HELMET.format(c=hc)
            + f'<span class="mono" style="font-size:11px;color:var(--ink)">'
            f'{name}</span>' + st + foot + '</div>')

ADD_PLAQUE = ('<div class="col" style="border:1px dashed rgba(63,88,120,.6);'
              'padding:14px 10px 10px;align-items:center;'
              'justify-content:center;gap:8px;min-height:118px">'
              '<svg width="16" height="16" viewBox="0 0 16 16">'
              '<path d="M8 2 V14 M2 8 H14" stroke="#6c7a90" '
              'stroke-width="1.4"/></svg>'
              '<span class="lbl">add a pilot</span></div>')

wall = ('<div class="row" style="margin-top:14px">'
        '<span class="lbl">your crew</span>'
        '<span class="mono" style="font-size:9px;color:var(--friend);'
        'margin-left:10px;letter-spacing:.13em">3, 1 flying</span></div>'
        '<div style="display:grid;grid-template-columns:'
        'repeat(3,minmax(0,1fr));gap:12px;margin-top:12px">'
        + plaque("Halcyon 2", "team battle", "on")
        + plaque("Gantry 4", "added you 2h", "ask")
        + plaque("Vireo 9", "off", "off")
        + plaque("Sable 09", "off", "off")
        + plaque("Plinth 41", "sent 3d", "off")
        + ADD_PLAQUE
        + '</div>'
        + sect("in this game", 2, top=22)
        + '<div style="display:grid;grid-template-columns:'
        'repeat(3,minmax(0,1fr));gap:12px;margin-top:10px">'
        + plaque("Krait 4", "flying with you", "here")
        + plaque("Orrery 3", "flying with you", "here")
        + '</div>'
        + '<div style="margin-top:20px"><div class="hrule"></div>'
        '<div class="row" style="height:40px">'
        '<span class="mono" style="font-size:11px;color:var(--dim)">'
        'everybody who added you</span>'
        '<span class="mono" style="font-size:9px;color:var(--friend);'
        'margin-left:10px">3</span>'
        '<div style="flex:1"></div>' + CHEV + '</div></div>')
write("CrewWall.dc.html", board(wall))

# ---- D: by game. The page answers where instead of who ---------------------
#
# Each zone holding a friend is a band in the play page's grammar: the
# game's name, its room's clock, the friends inside it, and the join on the
# band. The people without a place fall into quiet rolls underneath. The
# strongest read when somebody is on and the emptiest when nobody is.

CHANNEL = ('<div style="margin:0 -20px;padding:13px 20px 14px;'
           'background:linear-gradient(90deg,rgba(79,214,255,.14),'
           'rgba(79,214,255,0) 85%)">'
           '<div class="row">'
           '<span class="name" style="font-size:17px">Team Battle</span>'
           '<div style="flex:1"></div>'
           '<div class="col" style="align-items:flex-end">'
           '<span class="lbl">time</span>'
           '<span class="mono" style="font-size:15px;margin-top:2px">1:12'
           '</span></div></div>'
           '<div class="row" style="gap:8px;margin-top:9px">' + DOT
           + '<span class="mono" style="font-size:11px;'
           'color:var(--friend)">Halcyon 2 is flying here</span></div>'
           '<div class="key gokey" style="height:30px;width:100%;'
           'margin-top:11px">join them</div></div>')

chan = ('<div class="row" style="margin-top:14px">'
        '<span class="lbl">friends</span>'
        '<span class="mono" style="font-size:9px;color:var(--friend);'
        'margin-left:10px;letter-spacing:.13em">3, 1 flying</span>'
        '<div style="flex:1"></div>' + key("add a pilot") + '</div>'
        + '<div style="margin-top:14px"></div>'
        + CHANNEL
        + sect("waiting on you", 1, top=20)
        + HAIL
        + sect("off watch", 2, top=22)
        + quiet_row("Vireo 9") + quiet_row("Sable 09")
        + sect("sent", 1, top=14)
        + quiet_row("Plinth 41",
                    '<span class="mono" style="font-size:10.5px;'
                    'color:var(--dim)">3d ago</span>')
        + sect("in this game", 2, top=14)
        + quiet_row("Krait 4", key("add", go=True), dim=False)
        + quiet_row("Orrery 3", key("add", go=True), dim=False)
        + '<div style="margin-top:18px"><div class="hrule"></div>'
        '<div class="row" style="height:40px">'
        '<span class="mono" style="font-size:11px;color:var(--dim)">'
        'everybody who added you</span>'
        '<span class="mono" style="font-size:9px;color:var(--friend);'
        'margin-left:10px">3</span>'
        '<div style="flex:1"></div>' + CHEV + '</div></div>')
write("Channels.dc.html", board(chan))

# ---- The first friend: direction A with nothing on it ----------------------
#
# Two thirds of accounts never score and the median career is three games,
# so the page most pilots meet is this one. The ADD key is pressed and the
# field is open with the completions the meta-layer answers from the first
# letter; the room you are flying with is the second way in, and the one
# sentence of help is under the list rather than across the middle.

OPEN_FIELD = ('<div style="margin-top:12px">'
              '<div class="row" style="height:32px;'
              'border:1px solid rgba(79,214,255,.55);border-radius:16px;'
              'padding:0 13px;background:rgba(79,214,255,.05)">'
              '<span class="mono" style="font-size:12px;color:var(--ink)">'
              'hal</span>'
              '<span style="width:1.5px;height:14px;'
              'background:var(--friend);margin-left:2px"></span></div>'
              '<div style="border:1px solid rgba(63,88,120,.7);'
              'background:rgba(7,11,18,.96);margin-top:5px">'
              '<div class="row" style="height:30px;padding:0 13px;'
              'background:rgba(79,214,255,.16)">'
              '<span class="name" style="font-size:13px">Halcyon 2</span>'
              '</div>'
              '<div class="row" style="height:30px;padding:0 13px">'
              '<span class="name" style="font-size:13px;'
              'color:rgba(223,233,245,.85)">Halyard 12</span></div></div>'
              '</div>')

first = ('<div class="row" style="margin-top:14px">'
         '<span class="lbl">friends</span>'
         '<span class="mono" style="font-size:9px;color:var(--friend);'
         'margin-left:10px;letter-spacing:.13em">0</span>'
         '<div style="flex:1"></div>'
         '<div class="key gokey" style="height:26px;padding:0 12px;'
         'background:rgba(79,214,255,.1)">add a pilot</div></div>'
         + OPEN_FIELD
         + sect("in this game", 2,
                "The pilots in your room; you fly with somebody, it was"
                " good, add them", top=26)
         + quiet_row("Krait 4", key("add", go=True), dim=False)
         + quiet_row("Orrery 3", key("add", go=True), dim=False)
         + '<div class="col" style="align-items:center;margin-top:110px;'
         'gap:8px">'
         '<span style="font-size:14px">nobody yet</span>'
         '<span class="note" style="font-size:10.5px;text-align:center">'
         'friends show up here, the ones in a game first</span></div>')
write("FirstFriend.dc.html", board(first))

print("boards written")
