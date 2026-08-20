# Rethink mockups

Six screens for the game shape in
[docs/design/match-game.md](../../docs/design/match-game.md): a match list, a
hangar where a kit is thirty upgrades you choose, an in-match HUD on a three
minute clock, a podium that pays, a shop, and the weekly ladder.


They are drawings of a proposal, not a plan of record. Nothing here is built.

## What is here

`build.py` is the source. It holds one design system, lifted from the real
client rather than invented, and writes the six `.dc.html` artboards from it:

- hues from `client/arena/palette.lua`
- panel geometry from `client/arena/ui.lua`: PAD 14, COL_W 248, RADAR 168,
  FONT 13, LINE 18, and the rule that a panel is a lit vertical edge with the
  light spilling across it rather than a box
- hull outlines drawn to the nose, tail and side extents in
  `docs/design/ships.md`
- ceilings from `sim/include/sim/sim.h`: `SIM_UP_STEPS` 8, `SIM_MAX_CHARGES` 4
- the two faces the client carries, Chakra Petch for menus and DejaVu Sans Mono
  for anything read in flight

The hangar's pips spend for real, because the thirty point budget is the part
of the proposal worth arguing with, and a picture of a budget cannot be argued
with.

## Rebuilding

```sh
python3 build.py
```

That rewrites the artboards. To rebuild the canvas the artboards are published
in, re-seed it with the `design` skill's helper and publish the result to the
same URL. The seeded file is git-ignored: it is 2.4 MB of editor payload and
nothing in it is authored here.
