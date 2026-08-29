# Game menu mocks

Boards for the call that settings lives in the match and nowhere else.
The landing keeps saying only who, where and what; the drawer dies; the
in-game menu holds leave, side and settings. The chosen direction is the
landing column's grammar carried into the match, and nothing pauses:
opening the column only takes the controls, the ship stays live below,
and the wash is thin enough to watch trouble coming.

The chosen row:

- **Menu button, at rest** the key that summons the column, drawn as the
  client already draws it in `burger_cap`: the key box every pressable
  thing wears, three bars for the mark, the word MENU beside them on a
  desktop because that corner is read. PLAYERS keeps it company. Esc is
  the other opener, fixed because it is also how you leave everything.
- **Pause column** the column standing: stops for LEAVE, SETTINGS and
  SIDE over a breathing RESUME, the fight visible through the thin wash.
- **Pause column, settings open** the settings stop opening the way the
  ship stop opens at home, the panel climbing from its row with the
  drawer's whole settings page.
- **Phone, at rest / column open** the word drops and the mark stands
  alone in a square of the same box; the column's 320 fits a 390 glass
  with margin and RESUME lands where a thumb already lives.

The roads not taken, kept for the record:

- **Corner panel** the corner key docks a panel and the match stays
  undimmed beside it.
- **Center card** the console classic, settings one page deeper.
- **Radial** hold and flick; fastest, and the one direction that costs a
  new grammar.

`build.py` is the source, chrome carried forward from
`../ship-kit/build.py` and `../no-drawer/build.py`: the row states of
decision 72, the ship panel's banded sections, the stops and PLAY NOW of
decision 89, the menu key of `burger_cap` in `client/arena/ui.lua`.

Rebuild with `python3 build.py`; the eight `.dc.html` files and
`canvas.json` beside it are what a design canvas is seeded from.
