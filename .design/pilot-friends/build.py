#!/usr/bin/env python3
# Assemble the pilot-friends direction boards from shared fragments, so the
# chrome (top line, rail, row grammar) stays identical across all six.
import os

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
.num{font-family:var(--mono);font-variant-numeric:tabular-nums}
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
.sline{font-family:var(--mono);font-size:9.5px;color:var(--dim);
  margin:-2px 0 6px}
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

# The fight behind the drawer, dim under the wash.
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

X_KEY = """<div class="key" style="width:26px;height:26px;flex:none"><svg width="11" height="11" viewBox="0 0 12 12"><path d="M1.5 1.5 L10.5 10.5 M10.5 1.5 L1.5 10.5" stroke="#9fb6d4" stroke-width="1.4" stroke-linecap="square"/></svg></div>"""

DISCORD_KEY = """<div class="key" style="width:34px;height:26px;flex:none"><svg width="15" height="12" viewBox="0 0 16 12" fill="none"><path d="M4.6 1.6 C5.7 1.2 6.8 1 8 1 C9.2 1 10.3 1.2 11.4 1.6 C12.9 2.3 14.2 4.5 14.4 7.8 C13.4 9.1 12 9.9 11 10.2 L10.2 8.9 C9.5 9.1 8.8 9.2 8 9.2 C7.2 9.2 6.5 9.1 5.8 8.9 L5 10.2 C4 9.9 2.6 9.1 1.6 7.8 C1.8 4.5 3.1 2.3 4.6 1.6 Z" stroke="#9fb6d4" stroke-width="1.1"/><circle cx="5.7" cy="5.9" r="1" fill="#9fb6d4"/><circle cx="10.3" cy="5.9" r="1" fill="#9fb6d4"/></svg></div>"""

def pill(lit=False):
    c = "#4fd6ff" if lit else "#9fb6d4"
    bc = "rgba(79,214,255,.85)" if lit else "rgba(63,88,120,.75)"
    return ('<div class="key" style="height:26px;padding:0 13px;font-size:11px;'
            f'color:{c};border-color:{bc};letter-spacing:.02em;text-transform:none">Delta 154</div>')

def topline(pill_lit=False):
    return ('<div class="row" style="height:48px;gap:10px;'
            'border-bottom:1px solid rgba(63,88,120,.45);margin:0 -14px;padding:0 14px">'
            + X_KEY + '<div style="flex:1"></div>' + DISCORD_KEY + pill(pill_lit) + '</div>')

ICONS = {
 "play": '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="{c}" stroke-width="1.3"><circle cx="8" cy="8" r="3.4"/><ellipse cx="8" cy="8" rx="7" ry="2.6" transform="rotate(-18 8 8)"/></svg>',
 "ship": '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="{c}" stroke-width="1.3"><g transform="translate(8,8.6) scale(.5)"><path d="M0,-13 L15,9 L7,12 L0,8 L-7,12 L-15,9 Z"/></g></svg>',
 "friends": '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="{c}" stroke-width="1.2"><path d="M2 8.6 A3.6 3.6 0 0 1 9.2 8.6 M1.4 10 H9.8" opacity=".55"/><path d="M6.4 11.2 A3.9 3.9 0 0 1 14.2 11.2 M5.7 12.8 H14.9"/></svg>',
 "pilot": '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="{c}" stroke-width="1.3"><path d="M2.6 9.8 A5.5 5.5 0 0 1 13.4 9.8"/><path d="M1.6 11.6 H14.4"/></svg>',
 "settings": '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="{c}" stroke-width="1.3"><path d="M2 4.5 H14 M2 8 H14 M2 11.5 H14"/><circle cx="10.5" cy="4.5" r="1.8" fill="#0a0f18"/><circle cx="5.5" cy="8" r="1.8" fill="#0a0f18"/><circle cx="9.5" cy="11.5" r="1.8" fill="#0a0f18"/></svg>',
}

def rail(stops, lit):
    cells = []
    for name in stops:
        on = name == lit
        c = "#4fd6ff" if on else "#6c7a90"
        tc = "var(--ink)" if on else "var(--dim)"
        bg = ("background:linear-gradient(0deg,rgba(79,214,255,.14),rgba(79,214,255,0) 80%);"
              if on else "")
        cells.append('<div style="flex:1;display:flex;flex-direction:column;'
                     'align-items:center;justify-content:center;gap:4px;height:100%;'
                     f'padding-bottom:14px;{bg}">'
                     + ICONS[name].format(c=c)
                     + f'<span style="font-size:9px;color:{tc}">{name}</span></div>')
    return ('<div style="position:absolute;left:0;right:0;bottom:0;height:78px;'
            'border-top:1px solid rgba(63,88,120,.6);display:flex">'
            + "".join(cells) + '</div>')

def board(body, stops, lit, pill_lit=False, overlay=""):
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
{topline(pill_lit)}
{body}
</div>
{rail(stops, lit)}
{overlay}
</div>
</x-dc>

</body>
</html>
"""

def sect(label, note=None, line=None):
    n = f'<span class="lbl">{note}</span>' if note else ""
    h = (f'<div class="sect"><span class="lbl">{label}</span>'
         f'<div class="rule"></div>{n}</div>')
    if line: h += f'<div class="sline">{line}</div>'
    return h

def keychip(label, lit=False):
    k = "key keylit" if lit else "key"
    return f'<div class="{k}" style="height:20px;padding:0 9px;font-size:8.5px">{label}</div>'

def frow(name, detail=None, keys="", dim=False, wash=False):
    op = ".55" if dim else "1"
    d = (f'<span class="note" style="margin-left:10px">{detail}</span>'
         if detail else "")
    w = ('background:linear-gradient(90deg,rgba(79,214,255,.14),'
         'rgba(79,214,255,0) 85%);') if wash else ""
    return ('<div class="row" style="height:32px;margin:0 -14px;padding:0 14px;'
            f'gap:8px;{w}opacity:{op}">'
            f'<span class="name">{name}</span>{d}'
            f'<div style="flex:1"></div>{keys}</div>')

def addfield():
    return ('<div class="row" style="gap:8px;margin:10px 0 2px">'
            '<div class="row" style="flex:1;height:30px;padding:0 10px;'
            'border:1px solid rgba(63,88,120,.75);background:rgba(10,15,24,.6)">'
            '<span class="note">type a call sign</span>'
            '<span style="width:1px;height:14px;background:#4fd6ff;'
            'margin-left:3px"></span></div>'
            + keychip("add") + '</div>')

# The friends body, shared by A (below the account), BFriends and Main.
def friends_body(trim=False):
    h = addfield()
    h += sect("waiting on you", "1",
              "they added you; accept and you are friends, ignore and they go to everybody")
    h += frow("Vantage 22", "added you 2h ago",
              keychip("accept", True) + keychip("ignore"))
    h += sect("friends", "3, 1 flying")
    h += frow("Sable", "team battle", keychip("join", True) + keychip("unfriend"))
    h += frow("Kestrel 0001", "not on", keychip("unfriend"))
    h += frow("Ridgeline 7", "not on", keychip("unfriend"))
    h += sect("sent", "1")
    h += frow("Aperture", "3d ago", keychip("cancel"))
    h += sect("in this game", "2")
    h += frow("Tessellate 0001", "", keychip("add", True))
    if not trim:
        h += frow("Halcyon 2", "", keychip("add", True))
    h += sect("everybody who added you", "4",
              None if trim else "the ones you ignored, and the ones it came to something")
    h += frow("Mantis 7", "ignored 2w ago", keychip("accept", True))
    if not trim:
        h += frow("Sable", "friend", dim=True)
    return h

# ---- Current: the pilot page as shipped ----
cur = ""
cur += frow("Call sign", None,
            '<span class="note" style="text-transform:none">Delta 154</span>',
            wash=True)
cur += ('<div style="height:6px"></div>'
        '<div class="col" style="gap:2px;margin:8px 0">'
        '<span style="font-size:16px">Keep this pilot</span>'
        '<span class="note">a password brings this pilot back anywhere</span></div>'
        '<div class="col" style="gap:2px;margin:12px 0">'
        '<span style="font-size:16px">Log in</span>'
        '<span class="note">call sign and password</span></div>')
cur += ('<div style="border-left:1px solid rgba(79,214,255,.35);padding:12px 0 12px 16px;'
        'margin-top:16px">'
        '<span class="lbl">call sign</span>'
        '<div style="font-size:22px;margin:6px 0 2px">Delta 154</div>'
        '<span class="lbl">a guest on this device</span>'
        '<p class="note" style="line-height:1.6;margin:12px 0;text-transform:none">'
        'Dealt to you on arrival, and yours until you reroll it. A name of your '
        'own is something to buy once you have flown enough to want one.</p>'
        '<div style="height:170px"></div>'
        '<div style="height:1px;background:rgba(108,122,144,.35);margin:0 40px 10px 0"></div>'
        '<p class="note" style="line-height:1.5;margin:0;text-transform:none">'
        'a password brings this pilot back on any machine; without one it lives '
        'on this one</p></div>')
open(os.path.join(OUT, "Current.dc.html"), "w").write(
    board(cur, ["play","ship","friends","settings","pilot"], "pilot"))

# ---- Direction A: one page, sectioned ----
a = sect("pilot")
a += frow("Call sign", "Delta 154, a guest",
          keychip("keep", True) + keychip("log in"))
a += friends_body(trim=True)
open(os.path.join(OUT, "DirectionA.dc.html"), "w").write(
    board(a, ["play","ship","pilot","settings"], "pilot"))

# ---- Direction B: the drill-down ----
b = frow("Call sign", None,
         '<span class="note" style="text-transform:none">Delta 154</span>',
         wash=True)
b += ('<div class="col" style="gap:2px;margin:10px 0">'
      '<span style="font-size:16px">Keep this pilot</span>'
      '<span class="note">a password brings this pilot back anywhere</span></div>'
      '<div class="col" style="gap:2px;margin:12px 0">'
      '<span style="font-size:16px">Log in</span>'
      '<span class="note">call sign and password</span></div>')
b += ('<div class="row" style="height:38px;margin:4px -14px 0;padding:0 14px;gap:8px">'
      '<span style="font-size:16px">Friends</span>'
      '<span class="note" style="margin-left:6px">1 in a game</span>'
      '<div style="flex:1"></div>'
      '<svg width="9" height="12" viewBox="0 0 10 14">'
      '<path d="M2 1.5 L7.5 7 L2 12.5 Z" fill="rgba(79,214,255,.55)"/></svg></div>')
open(os.path.join(OUT, "DirectionB.dc.html"), "w").write(
    board(b, ["play","ship","pilot","settings"], "pilot"))

# ---- B, one level in: the friends reading ----
bf = ('<div class="row" style="height:36px;gap:10px;margin:2px -14px 0;padding:0 14px;'
      'border-bottom:1px solid rgba(63,88,120,.45)">'
      '<svg width="9" height="12" viewBox="0 0 10 14">'
      '<path d="M8 1.5 L2.5 7 L8 12.5 Z" fill="rgba(79,214,255,.55)"/></svg>'
      '<span style="font-size:14px">friends</span>'
      '<div style="flex:1"></div><span class="lbl">swipe right to go back</span></div>')
bf += friends_body()
open(os.path.join(OUT, "BFriends.dc.html"), "w").write(
    board(bf, ["play","ship","pilot","settings"], "pilot"))

# ---- Main, direction C: the account is a band ----
c = ('<div class="row" style="height:64px;gap:12px;margin:0 -14px;padding:0 14px;'
     'border-bottom:1px solid rgba(63,88,120,.45)">'
     '<div class="col" style="gap:3px">'
     '<div class="row" style="gap:8px">'
     '<span style="font-size:20px">Delta 154</span>'
     '<svg width="13" height="13" viewBox="0 0 16 16" fill="none" '
     'stroke="#6c7a90" stroke-width="1.3">'
     '<path d="M13 8 A5 5 0 1 1 10.5 3.7 M10.5 1.4 V4 H13.1"/></svg></div>'
     '<span class="lbl">a guest on this device</span></div>'
     '<div style="flex:1"></div>'
     + keychip("keep", True) + keychip("log in") + '</div>')
c += friends_body()
open(os.path.join(OUT, "Main.dc.html"), "w").write(
    board(c, ["play","ship","pilot","settings"], "pilot"))

# ---- C with the password card up ----
card = ('<div style="position:absolute;inset:0;background:rgba(3,5,10,.55)"></div>'
        '<div style="position:absolute;left:30px;right:30px;top:270px;'
        'background:#080d16;border:1px solid rgba(63,88,120,.75);padding:18px 18px 16px">'
        '<div style="font-size:16px;margin-bottom:4px">Keep this pilot</div>'
        '<div class="note" style="text-transform:none;line-height:1.5">'
        'a password brings Delta 154 back on any machine; without one it lives '
        'on this one until a quiet week reclaims it</div>'
        '<div class="row" style="height:32px;margin-top:14px;padding:0 10px;'
        'border:1px solid rgba(63,88,120,.75);background:rgba(10,15,24,.6);gap:5px">'
        + "".join('<span style="width:6px;height:6px;border-radius:50%;'
                  'background:#dfe9f5"></span>' for _ in range(6))
        + '<span style="width:1px;height:14px;background:#4fd6ff"></span></div>'
        '<div class="row" style="gap:8px;margin-top:14px;justify-content:flex-end">'
        + keychip("cancel") + keychip("set password", True) + '</div></div>')
open(os.path.join(OUT, "CCard.dc.html"), "w").write(
    board(c, ["play","ship","pilot","settings"], "pilot", overlay=card))

print("boards written")
