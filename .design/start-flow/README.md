# Start flow mocks

Nine boards for the proposal that the landing's foot grows three stops
between the lockup and PLAY NOW: account, zone, ship. Pressing account opens
the account menu, pressing zone drops the games list, pressing ship drops
the hulls with SPECTATE as the last row, and PLAY NOW stays the one
celebrated key. The question the boards ask is how the stops are rendered,
three directions by three states:

- **A · Column** the stops stack over PLAY NOW like a boarding card
- **B · Rail** one console band along the foot ending in PLAY NOW
- **C · Sentence** one line of pressable words between the lockup and the
  key, the closest to what ships today

Each direction is drawn closed, with one list open, and on a phone held
upright. Drawings of a proposal, not a plan of record. Nothing here is
built.

`build.py` is the source, in the manner of `../spectator-landing/build.py`,
whose design system it borrows: hues from `client/arena/palette.lua`, panel
geometry from `client/arena/ui.lua`, hull outlines to the extents in
`docs/design/ships.md`, the lockup verbatim from `docs/banner.svg`. The
open lists wear the menu's row states from decision 72.

Rebuild with `python3 build.py`; the nine `.dc.html` files and `canvas.json`
beside it are what a design canvas is seeded from.
