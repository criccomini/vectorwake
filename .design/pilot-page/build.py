#!/usr/bin/env python3
# The pilot-page rethink boards, assembled from shared fragments so the
# chrome (top line, rail, row grammar) stays identical across every board.
# Sizes and colors are the drawer's own: 390 wide, ink dfe9f5, dim 6c7a90,
# friend 4fd6ff, key boxes on rgba(63,88,120,.75), lbl 9px mono upper.
import pathlib

OUT = str(pathlib.Path(__file__).resolve().parent)

STYLE = """
:root{
  --ink:#dfe9f5; --dim:#6c7a90; --friend:#4fd6ff; --gold:#ffd166;
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
.keylit{border-color:rgba(79,214,255,.5);background:rgba(79,214,255,.07);
  color:#4fd6ff}
.sect{display:flex;align-items:center;gap:10px;margin:14px 0 6px}
.sect .rule{flex:1;height:1px;background:rgba(63,88,120,.45)}
.name{font-size:15px;color:var(--ink)}
.note{font-family:var(--mono);font-size:10px;color:var(--dim)}
.screen{position:relative;width:390px;height:844px;overflow:hidden;
  background-color:#05070c;
  background-image:
   radial-gradient(circle 1.3px at 244px 128px,#93a9c8 0 1.3px,transparent 1.3px),
   radial-gradient(circle 1.3px at 44px 626px,#93a9c8 0 1.3px,transparent 1.3px),
   radial-gradient(circle 1.0px at 300px 33px,#4a6089 0 1.0px,transparent 1.0px),
   radial-gradient(circle 1.0px at 85px 263px,#4a6089 0 1.0px,transparent 1.0px),
   radial-gradient(circle 1.0px at 335px 707px,#4a6089 0 1.0px,transparent 1.0px),
   radial-gradient(circle 0.9px at 195px 340px,#2a3a58 0 0.9px,transparent 0.9px),
   radial-gradient(circle 0.9px at 118px 170px,#2a3a58 0 0.9px,transparent 0.9px),
   radial-gradient(circle 0.9px at 353px 290px,#2a3a58 0 0.9px,transparent 0.9px),
   radial-gradient(circle 0.9px at 27px 449px,#2a3a58 0 0.9px,transparent 0.9px),
   radial-gradient(circle 0.9px at 196px 749px,#2a3a58 0 0.9px,transparent 0.9px)}
"""

ARENA = """<svg width="390" height="844" style="position:absolute;inset:0">
<rect x="288" y="196" width="26" height="104" fill="#080d16" stroke="#22344f" stroke-width="1"/>
<path d="M288 196 H314" stroke="#5b82b8" stroke-width="1.4" opacity=".55"/>
<rect x="60" y="560" width="128" height="26" fill="#080d16" stroke="#22344f" stroke-width="1"/>
<path d="M60 560 H188" stroke="#5b82b8" stroke-width="1.4" opacity=".55"/>
<g transform="translate(150,330) rotate(36)">
<path d="M-4,10 L-2,44 L2,44 L4,10 Z" fill="#4fd6ff" opacity=".16"/>
<path d="M0,-13 L15,9 L7,12 L0,8 L-7,12 L-15,9 Z" fill="#0b1220" stroke="#4fd6ff" stroke-width="1.5" stroke-linejoin="round"/></g>
<g transform="translate(300,660) rotate(205)">
<path d="M-4,10 L-2,44 L2,44 L4,10 Z" fill="#ffa552" opacity=".16"/>
<path d="M0,-22 L3,-6 L6,8 L2,12 L-2,12 L-6,8 L-3,-6 Z" fill="#0b1220" stroke="#ffa552" stroke-width="1.5" stroke-linejoin="round"/></g>
</svg>"""

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
        'color:#9fb6d4;letter-spacing:.02em;text-transform:none">Delta 154</div>')

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

def rail(lit="pilot"):
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

def board(body, overlay=""):
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
<div class="screen">
{ARENA}
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

def sect(label, note=None):
    n = f'<span class="lbl">{note}</span>' if note else ""
    return (f'<div class="sect"><span class="lbl">{label}</span>'
            f'<div class="rule"></div>{n}</div>')

def keychip(label, lit=False, h=22):
    k = "key keylit" if lit else "key"
    return (f'<div class="{k}" style="height:{h}px;padding:0 10px;'
            'font-size:8.5px">' + label + '</div>')

def vrow(title, note=None, keys=""):
    n = (f'<span class="note" style="margin-top:2px">{note}</span>'
         if note else "")
    return ('<div class="row" style="margin:0 -14px;padding:7px 14px;gap:8px">'
            f'<div class="col"><span style="font-size:16px">{title}</span>{n}'
            '</div><div style="flex:1"></div>' + keys + '</div>')

def fact(label, value, mark=""):
    return ('<div class="row" style="height:30px;margin:0 -14px;'
            'padding:0 14px;gap:8px">'
            f'<span style="font-size:13.5px;opacity:.85">{label}</span>'
            '<div style="flex:1"></div>' + mark +
            f'<span class="num note" style="font-size:11px;color:#9fb6d4">'
            f'{value}</span></div>')

RIVET = ('<svg width="11" height="11" viewBox="0 0 16 16" fill="none">'
         '<circle cx="8" cy="6.5" r="4" stroke="#ffd166" stroke-width="1.4"/>'
         '<path d="M3.5 13 H12.5" stroke="#ffd166" stroke-width="1.4"/></svg>')

NEWNAME = keychip("new name")

def field(placeholder, discs=False):
    inner = ("".join('<span style="width:6px;height:6px;border-radius:50%;'
                     'background:#dfe9f5"></span>' for _ in range(6))
             if discs else
             f'<span class="note">{placeholder}</span>')
    return ('<div class="row" style="height:32px;padding:0 10px;gap:5px;'
            'border:1px solid rgba(63,88,120,.75);'
            'background:rgba(10,15,24,.6)">' + inner +
            '<span style="width:1px;height:14px;background:#4fd6ff;'
            'margin-left:3px"></span></div>')

def write(name, html):
    pathlib.Path(OUT, name).write_text(html)

# ---- Current: the page as shipped, for scale ----
cur = ('<div class="row" style="height:32px;margin:0 -14px;padding:0 14px;'
       'gap:8px;background:linear-gradient(90deg,rgba(79,214,255,.14),'
       'rgba(79,214,255,0) 85%)">'
       '<span class="name">Call sign</span><div style="flex:1"></div>'
       '<span class="note" style="text-transform:none">Delta 154</span></div>')
cur += vrow("Keep this pilot", "a password brings this pilot back anywhere")
cur += vrow("Log in", "call sign and password")
cur += ('<div style="border-left:1px solid rgba(79,214,255,.35);'
        'padding:12px 0 12px 16px;margin-top:16px">'
        '<span class="lbl">call sign</span>'
        '<div style="font-size:22px;margin:6px 0 2px">Delta 154</div>'
        '<span class="lbl">a guest on this device</span>'
        '<p class="note" style="line-height:1.6;margin:12px 0;'
        'text-transform:none">Dealt to you on arrival, and yours until you '
        'reroll it. A name of your own is something to buy once you have '
        'flown enough to want one.</p>'
        '<div style="height:170px"></div>'
        '<div style="height:1px;background:rgba(108,122,144,.35);'
        'margin:0 40px 10px 0"></div>'
        '<p class="note" style="line-height:1.5;margin:0;text-transform:none">'
        'a password brings this pilot back on any machine; without one it '
        'lives on this one</p></div>')
write("Current.dc.html", board(cur))

# ---- A: plain words, and the box deleted ----
a = ('<div class="row" style="height:34px;margin:0 -14px;padding:0 14px;'
     'gap:8px"><span class="name">Call sign</span>'
     '<span class="note" style="text-transform:none;margin-left:10px">'
     'Delta 154</span><div style="flex:1"></div>' + NEWNAME + '</div>')
a += vrow("Set a password", "makes Delta 154 yours on any machine")
a += vrow("Log in", "already have a pilot")
write("DirectionA.dc.html", board(a))

# ---- B, leading: the pilot card, and the career under it ----
def b_head(status, warn, keys):
    h = ('<div style="margin:14px -14px 0;padding:0 14px 14px;'
         'border-bottom:1px solid rgba(63,88,120,.45)">'
         '<div class="row" style="gap:10px">'
         '<span style="font-size:24px">Delta 154</span>'
         '<div style="flex:1"></div>' + NEWNAME + '</div>'
         f'<div class="lbl" style="margin-top:4px">{status}</div>')
    if warn:
        h += ('<div class="note" style="text-transform:none;line-height:1.5;'
              f'margin-top:8px">{warn}</div>')
    h += ('<div class="row" style="gap:8px;margin-top:12px">' + keys
          + '</div></div>')
    return h

def career():
    h = sect("career", "the season so far")
    h += fact("Duel rating", "1487, ace")
    h += fact("Record", "231 kills, 188 deaths")
    h += fact("Games", "419")
    h += fact("Rivets", "1,264", RIVET)
    return h

bg = b_head("a guest on this device",
            "a password makes this name yours on any machine; without one "
            "it lives here",
            keychip("set password", True, 30) + keychip("log in", False, 30))
bg += career()
write("Main.dc.html", board(bg))

bc = b_head("signed in", None,
            keychip("change password", False, 30) + keychip("log out", False, 30))
bc += career()
write("BClaimed.dc.html", board(bc))

# ---- C: the form is the page ----
c = ('<div style="margin-top:14px">'
     '<span class="lbl">flying as</span>'
     '<div class="row" style="gap:10px;margin-top:4px">'
     '<span style="font-size:24px">Delta 154</span>'
     '<div style="flex:1"></div>' + NEWNAME + '</div>'
     '<div class="lbl" style="margin-top:4px">a guest on this device</div>'
     '</div>')
c += sect("keep this name anywhere")
c += field("choose a password")
c += ('<div class="key keylit" style="height:34px;margin-top:10px;'
      'width:100%;font-size:10px">set password</div>')
c += sect("or")
c += vrow("Log in to another pilot", None,
          '<svg width="9" height="12" viewBox="0 0 10 14">'
          '<path d="M2 1.5 L7.5 7 L2 12.5 Z" '
          'fill="rgba(79,214,255,.55)"/></svg>')
write("DirectionC.dc.html", board(c))

cc = ('<div style="margin-top:14px">'
      '<span class="lbl">flying as</span>'
      '<div class="row" style="gap:10px;margin-top:4px">'
      '<span style="font-size:24px">Delta 154</span>'
      '<div style="flex:1"></div>' + NEWNAME + '</div>'
      '<div class="lbl" style="margin-top:4px">signed in</div></div>'
      '<div style="height:10px"></div>')
cc += vrow("Change password")
cc += vrow("Log out", "this device becomes a fresh guest")
write("CClaimed.dc.html", board(cc))

print("boards written")
