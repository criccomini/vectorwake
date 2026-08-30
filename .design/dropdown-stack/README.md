# The dropdowns as full-screen panels

Chris's rethink of what a landing stop opens, mocked before anything is
built. Today a stop opens a list in place, climbing upward from its own
row over the lockup (decision 99's grammar). The proposal:

- A tap slides a panel into view from below rather than opening rows
  above the stop.
- The panel is the whole screen save the padding at the edge.
- It wears the stops' own glass, the same dim and blur a button has,
  not the near-opaque ground the in-place lists used (`land_list`'s
  0.96 wash).
- Its head still says the name of the section, with the way back on it:
  the triangle-and-name grammar the in-match settings page already
  wears.
- While it stands the other buttons are gone; they slid out below the
  bottom edge as the panel rose. Back plays the slide the other way and
  they return.

What that buys is stacking. A row that opens something is not a special
case any more: it slides the next panel in the same way, and back steps
one level out. The stacked board draws LOG IN, which today raises a
card over the landing with no ground behind it, as one more panel. The
ship stop's page falls under the same rule for free.

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

Open question, drawn rather than decided: on a desktop the rows run the
panel's whole width, about 1400 points. Whether a row should keep the
column's measure inside the panel instead is left visible on the Main
board.

The design system is lifted from `../pilot-dropdown/build.py`, which
lifted it from the real client. The back mark is the game menu's
(`../game-menu`).
