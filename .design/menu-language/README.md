# The menu language

A proposal: one design language for every menu and submenu, drawn after
Chris said the menus were not quite standardized in look and feel.

Decision 103 gave every menu one container -- a stop slides a frosted
panel up through the bottom edge -- and the interiors still speak three
dialects. The zone and account panels set their rows in the HUD's
12-point mono capitals; the settings panel speaks the menu face at 17,
sentence case; the ship panel is a third anatomy again, two heads
stacked and its own row height. Grounds sit at four opacities, rules at
four alphas, the two scroll thumbs disagree, and the log-in card stands
on no ground at all.

The language says each of those once:

- **Everything is a panel; a panel is rows; a row is one shape.**
- One glass (frost + the button tint at 0.72, tile outline), one head
  (back triangle + section name, the whole line the press), one band
  (label between rules, 24), one wash pair (cursor 0.18, here 0.07),
  one breathing key per screen.
- The menu **speaks** in the menu face at 17, sentence case; it
  **reads** in the mono at 12; it **quotes** a name raw. Capitals
  belong to the HUD and the small labels, never to a row.
- A row is 44 tall (the touch floor; 36 where a pointer is certain),
  inset 14, and its right end is what it does: **opens** (caret),
  **reads** (value), **steps** (arrows), **fills** (cells),
  **switches** (the box), or **walks** (the pager, folded out of the
  ship panel's second head into a row).
- A card is a panel that stacked: the log-in card takes the glass, the
  head, and the breathing key at its foot.

Seven boards, built by `build.py` and seeded with the design skill's
helper:

    python3 build.py
    node seed-canvas.mjs --template payload.template.html \
      --out menu-language.html --title "Menu Language" \
      --artboard Main.dc.html --artboard Zone.dc.html \
      --artboard Settings.dc.html --artboard Ship.dc.html \
      --artboard LogIn.dc.html --artboard Phone.dc.html \
      --artboard AltVoice.dc.html --canvas canvas.json

Main is the language sheet: voice, glass, the row and its six ends and
its states, head and band, key, and the one motion. The four shipped
surfaces are restated in the language beside it, plus the settings
panel on a phone. AltVoice is the one deliberate alternative: the zone
panel keeping today's HUD voice, so the single open choice -- which
register a list speaks -- is judged by looking rather than by argument.

Every number is lifted from the client rather than invented:
`client/arena/palette.lua` for hues, `ui.lua` for the type ladder
{12, 14, 17, 21}, `LIT` {0.18, 0.07}, the 44-point touch floor,
`PANEL_MAX` 560, the 14-point margin, the 34x18 switch, and the range
cells. The fight behind the glass is `../dropdown-stack`'s.
