# The dropdowns as full-screen panels

Shipped as [decision 103](../../docs/architecture/decisions.md). A stop
used to open a list in place, climbing upward from its own row over the
lockup (decision 99's grammar). Now:

- A tap slides a panel into view from below rather than opening rows
  above the stop.
- The panel is the whole screen save the padding at the edge, **capped
  at 560 points wide**.
- It wears the stops' own glass, the same dim and blur a button has,
  not the near-opaque ground the in-place lists used (`land_list`'s
  0.96 wash).
- Its head still says the name of the section, with the way back on it:
  the triangle-and-name grammar the in-match settings page already
  wears.
- While it stands the other buttons are gone; they slid out below the
  bottom edge as the panel rose. Back plays the slide the other way and
  they return.

The cap is the one thing that changed between these boards and what
shipped, and Chris is the reason: they were drawn full width, which is
right on a phone and wrong on a monitor. A row eleven hundred points
wide sets a game's name at one end and its format at the other, and
glass that wide stops being a panel over a fight and becomes the screen.
The boards carry the cap now; `PANEL_MAX` in `build.py` and in
`client/arena/ui.lua` are the same number.

What the grammar buys is stacking. A row that opens something is not a
special case any more: it slides the next panel in the same way, and
back steps one level out. Nothing stacks in the client yet, so the
Stacked board is the proposal for what comes next rather than a picture
of what runs: LOG IN still raises a card over the landing, and that card
is the obvious first thing to become a panel.

The in-match menu took the same change, because decision 102 had already
made it the landing's grammar carried into a match. That is what fixed
the overlap in the third screenshot this started from, where the settings
page ran over the stops it was standing on.

Six boards, built by `build.py` and seeded with the design skill's
helper:

    python3 build.py
    node seed-canvas.mjs --template payload.template.html \
      --out dropdown-stack.html --title "Dropdown Stack" \
      --artboard Main.dc.html --artboard Closed.dc.html \
      --artboard Account.dc.html --artboard MidSlide.dc.html \
      --artboard Stacked.dc.html --artboard Phone.dc.html \
      --canvas canvas.json

What the boards say:

- **Closed** is the shipped landing, the before.
- **Main** is the zone panel standing: the games list (decision 98)
  with its format strips (decision 82), the row you are in washed at
  0.07 in the friend color, the cursor's row at 0.18 (decision 72).
- **Account** is the account panel: decision 99's rows at the panel's
  width, the guest's offer in the caution color.
- **MidSlide** is one drawn frame of the motion, the column sinking and
  fading while the panel rises over it.
- **Stacked** is a stack going up: the account panel standing, LOG IN
  pressed, its panel rising over the account panel's rows.
- **Phone** is the zone panel on a phone held upright.

That open question is closed: the rows ran the panel's whole width here
and now run 560, centered on the middle the column stands on.

The design system is lifted from `../pilot-dropdown/build.py`, which
lifted it from the real client. The back mark is the game menu's
(`../game-menu`).
