# No-drawer mocks

Four boards for the proposal that the slide-out drawer goes away and its
settings move into the landing column itself. The ship stop already taught
the column the grammar this needs, a stop that opens a panel at the
column's own width, so settings becomes a stop and the corner MENU key
disappears from the home screen.

- **Settings stop, closed** the column at rest with the settings stop at
  its head, above the account: same field, a step shorter and dimmer than
  the three below it, the mixer icon where a value would be. Quiet on
  purpose, because it is not part of the who-where-what sentence that ends
  in PLAY NOW.
- **Settings stop, open** the panel climbing from the stop the way the
  ship pager climbs from the ship stop: the drawer's settings page whole,
  banded the way the ship panel bands its sections, with Controls and
  About as rows that open in place.
- **Footer line** the alternative that costs no stop: a quiet mono line
  under PLAY NOW opening the same panel. Cheapest presence, hardest to
  find.
- **Cockpit remainder** the one place the landing cannot reach. A seated
  pilot has no landing under them and still needs the way out of the seat,
  which side it is on, and the volume; the corner key keeps the mixer icon
  mid-match and opens only those three rows. Everything else waits at
  home.

`build.py` is the source, chrome carried forward from
`../ship-kit/build.py`: the landing column as shipped after decision 100,
the settings rows as the drawer holds them today, the score head of the
duel boards for the flying scene.

Rebuild with `python3 build.py`; the four `.dc.html` files and
`canvas.json` beside it are what a design canvas is seeded from.
