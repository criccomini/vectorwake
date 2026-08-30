# The menu language

Shipped as [decision 104](../../docs/architecture/decisions.md), and corrected
by [decision 105](../../docs/architecture/decisions.md). One design language
for every menu and submenu, drawn after Chris said the menus were not quite
standardized in look and feel, then built, then used and fixed.

Decision 103 gave every menu one container -- a stop slides a frosted
panel up through the bottom edge -- and the interiors still spoke three
dialects. The zone and account panels set their rows in the HUD's
12-point mono capitals; the settings panel spoke the menu face at 17,
sentence case; the ship panel was a third anatomy again, two heads
stacked and its own row height. Grounds sat at four opacities, rules at
four alphas, rows were inset by two different measures and stood at two
different heights, and the log-in card stood on no ground at all.

The language says each of those once:

- **Everything is a panel; a panel is rows; a row is one shape.**
- One glass (frost + the button tint at 0.72, tile outline), capped at
  560 wide and **as tall as what it holds**, standing on the bottom
  margin it slid out of and easing to a new height when a stack changes
  what is on top.
- One head (back triangle + section name, the whole line the press, and
  it lights like the control it is), one band (label between rules, 24),
  one wash pair (cursor 0.18, here 0.07, **flat, and the width of the
  glass**), one breathing key per screen.
- The menu **speaks** in the menu face at 17, sentence case; it
  **reads** in the mono at 14; it **quotes** a name raw. Capitals
  belong to the HUD and to the small labels, which are the mono at 12,
  never to a row.
- A row is 44 tall (the touch floor, and there is no second height),
  inset 14, and its right end is what it does: **opens** (caret),
  **reads** (value), **steps** (arrows), **fills** (cells),
  **switches** (the box, which enter and space flip), or **walks** (the
  pager, folded out of the ship panel's second head into a row). A row
  lights the same way under either hand.
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
panel on a phone. AltVoice was the one deliberate alternative -- the
zone panel keeping the HUD's voice -- and it is the road not taken:
Chris picked the menu's voice, and every row in the game speaks it now.

These boards carried two captions that were never in the code, and both
are corrected here: a reading is 14 points, not 12 (12 is the band
label's rung and nothing else's), and there is no dense 36-point row,
because no surface wanted one and two heights is the thing the decision
exists to stop.

Decision 105 then corrected six things Chris found by using it, and the
boards carry all of them: the flat wash, the lit head, enter and space
on a switch, the content-height panel, a pointer that lights every row,
and the shrapnel row reading the fragments a rung throws rather than the
rung. The one row on the sheet whose figure is not what it cost is
Shrapnel, and it says so.

[Decision 106](../../docs/architecture/decisions.md) is the same
correction finished. The wash was flat and still stopped fourteen points
short of the glass on both sides, because a row lit its own type column
and only the lists lit the panel. These boards always drew it the right
way, which is how the client came to disagree with them: the wash on
every row here is the row's own background and runs under its padding to
the edge.

Every number is lifted from the client rather than invented:
`client/arena/palette.lua` for hues, `ui.lua` for the type ladder
{12, 14, 17, 21}, `LIT` {0.18, 0.07}, the 44-point touch floor,
`PANEL_MAX` 560, the 14-point margin, the 34x18 switch, and the range
cells. The fight behind the glass is `../dropdown-stack`'s.
