# Game menu mocks

Boards for the call that settings lives in the match and nowhere else.
The landing keeps saying only who, where and what; the drawer dies; the
in-game menu holds leave, side and settings. Nothing pauses: opening the
menu only takes the controls, and the ship stays live below. Two
candidates are drawn in full, the column carried in from the landing and
the corner panel, and in both, side is a list rather than a stepper: in
a zone holding more than two sides, arrows would drag a pilot through
every team between here and the one they want, where a row per side says
them all at once, marks the one you fly for, and puts any other one
press away.

The column row, with the key attached to what it summons:

- **Menu key, at rest** small and faint at the bottom middle, exactly
  where the column will stand: the key box and the three bars, said
  small, furniture rather than a control demanding to be read. PLAYERS
  keeps the corner it has always had; the corner row just loses MENU.
  Esc is the other opener, fixed because it is also how you leave
  everything.
- **Column, sliding in** one drawn frame standing in for the motion:
  the column rising out of the bottom edge where the key sat, LEAVE
  first because LEAVE lives at the top, the wash fading in with it.
- **Column, standing** stops for LEAVE, SETTINGS and SIDE over a
  breathing RESUME, which ends up on the very pixels the key occupied;
  resuming hands the spot back. The fight stays visible through the
  thin wash.
- **Column, settings open** the settings stop opening the way the ship
  stop opens at home, the panel climbing from its row with the drawer's
  whole settings page.
- **Phone, at rest / column standing** the bottom middle is a phone's
  easiest reach, so the key sits where a thumb already rests and the
  column rises into the same hand; the 320 the stops have always been
  fits a 390 glass with margin.

The corner panel, explored:

- **Corner panel** the corner key docks a panel and the match stays
  undimmed beside it: Leave at the head, the side list with its counts,
  the whole of settings below. Drawn against a three-side zone so the
  list earns its place.
- **Corner panel, phone** the same panel at a phone's width, a strip of
  live fight left showing at the right, which is both the promise and
  the stray-thumb tradeoff.

The roads not taken, kept for the record:

- **Center card** the console classic, settings one page deeper.
- **Radial** hold and flick; fastest, and the one direction that costs a
  new grammar.

`build.py` is the source, chrome carried forward from
`../ship-kit/build.py` and `../no-drawer/build.py`: the row states of
decision 72, the ship panel's banded sections, the stops and PLAY NOW of
decision 89, the menu key of `burger_cap` in `client/arena/ui.lua`.

Rebuild with `python3 build.py`; the ten `.dc.html` files and
`canvas.json` beside it are what a design canvas is seeded from.
