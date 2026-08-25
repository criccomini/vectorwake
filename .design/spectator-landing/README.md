# Spectator-first landing mocks

Nine boards for the proposal that play.vectorwake.net opens straight into a
melee room as a watcher: the watcher's own HUD, one pulsing PLAY NOW key, and
the game's name somewhere on the glass. Where, exactly, is the question the
boards ask, three window shapes by three placements:

- **A** above the PLAY NOW key
- **B** top center, under the clock and score
- **C** in the corner the watcher's missing corner stack leaves empty

Drawings of a proposal, not a plan of record. Nothing here is built.

`build.py` is the source, in the manner of `../rethink/build.py`, whose design
system it borrows: hues from `client/arena/palette.lua`, panel geometry from
`client/arena/ui.lua`, hull outlines to the extents in `docs/design/ships.md`,
the lockup verbatim from `docs/banner.svg`, sides from
`catalog/zones/melee/zone.toml`. The PLAY NOW key breathes exactly as the
deck's DEPLOY key does. One deliberate departure from the shipped watcher
chrome: no TAKE SEAT key in the corner row, because PLAY NOW is that key.

Rebuild with `python3 build.py`; the nine `.dc.html` files and `canvas.json`
beside it are what a design canvas is seeded from.
