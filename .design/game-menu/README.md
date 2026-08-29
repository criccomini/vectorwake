# Game menu mocks

Five boards for the call that settings lives in the match and nowhere
else. The landing keeps saying only who, where and what; the drawer dies;
and the in-game menu becomes the whole question: leave, change sides, and
settings, one system that works for mouse, keyboard, controller and touch.
The constraint under every board is that nothing pauses in a shared arena,
so a menu is something you open while the fight goes on.

- **Pause column** the landing column's grammar carried into the match:
  stops for LEAVE, SETTINGS and SIDE over a breathing RESUME, the fight
  dimmed but half-visible behind. Same muscle memory as home, targets big
  enough for a thumb.
- **Pause column, settings open** the settings stop opening the way the
  ship stop opens at home, the panel climbing from its row with the
  drawer's whole settings page.
- **Corner panel** the direction that most respects the no-pause truth:
  the corner key docks a panel on the left and the match stays live and
  undimmed beside it.
- **Center card** the console classic: four rows in the middle of a
  dimmed screen, settings as a second page in place.
- **Radial** hold the key and four choices ring your own ship; flick
  toward one and let go. Fastest, and the only direction that costs a new
  grammar. Drawn to bound the space.

`build.py` is the source, chrome carried forward from
`../ship-kit/build.py` and `../no-drawer/build.py`: the row states of
decision 72, the ship panel's banded sections, the stops and PLAY NOW of
decision 89, the score head of the duel boards.

Rebuild with `python3 build.py`; the five `.dc.html` files and
`canvas.json` beside it are what a design canvas is seeded from.
