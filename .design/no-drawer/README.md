# No-drawer mocks

Four boards for the proposal that the slide-out drawer goes away and its
settings move onto the main landing page. The constraint that shapes all
four: the landing exists only in the stands. A pilot in a seat has no
landing under them and still needs volume, a side switch, and a way to
hand the seat back, so any answer that only rearranges the landing leaves
the drawer alive for flight, and then there are two systems instead of
one. The corner MENU key is the real question.

- **Corner key, home** the direction recommended: the corner key stops
  saying MENU and becomes a settings key, icon only, that opens the
  settings panel in place over the stars. The panel is the drawer's
  settings page in the landing column's clothes: full-width section bands,
  the wake and charge-key steppers, Controls and About as rows.
- **Corner key, flying** the same key and the same panel mid-match, with
  Leave and Side riding at the head because they only mean anything in a
  seat. This board is what the proposal stands on; if it works, nothing
  needs the drawer.
- **Settings stop** a fourth SETTINGS stop in the landing column, opening
  upward from its row. Honest about where settings live, but it bends the
  who-where-what sentence the column speaks, and it answers only the
  stands.
- **Account fold** settings folded under the account list, drawn to be
  ruled out: it buries sound and controls behind an identity chooser and
  still says nothing about flight.

`build.py` is the source, chrome carried forward from
`../ship-kit/build.py`: the landing column as shipped after decision 100,
the settings rows as the drawer holds them today, the score head of the
duel boards for the flying scene.

Rebuild with `python3 build.py`; the four `.dc.html` files and
`canvas.json` beside it are what a design canvas is seeded from.
