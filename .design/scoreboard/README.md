# Scoreboard rethink

Nine boards for the question of where the scoreboard lives. The shipped one is
a centered band that grows outward from the clock with side names, ratings and
the ladder readout, and it has four problems, all visible from a phone or a
desk:

- It overruns an upright phone, because nothing bounds its growth.
- Ladder and Melee fill it differently, so the two zones look like two games.
- Its type is fixed at 13/30pt, which is small at desktop distance.
- Match events arrive as one 24pt white sentence across the middle of the
  screen ("RUNG 3 CLEARED. NEXT RUNG 4, STREAK 3"), the largest and least
  designed thing on the glass.

Drawings of a proposal, not a plan of record. Nothing here is built.

## The chassis

All three directions share one idea: a chassis common to every zone, with one
slot the zone owns.

- **Common**: the score and the clock, in the viewer's own colors, yours
  first. Same drawing in every zone.
- **The zone's slot**: one line the mode fills. Ladder writes its rung and
  streak there; Melee writes nothing during play and the intermission clock
  between matches; a flag game would write its pennant tally. A zone with
  nothing to say has no slot, and the chassis alone is the whole scoreboard.
- **Events land in the slot**, in the scoring side's color, for a few
  seconds, instead of as a giant line over the fight. DESTROYED and SUDDEN
  DEATH are the same kind of tenant.
- **Type rides the window**: the desktop boards draw the scoreboard about a
  third larger than the shipped sizes, portrait draws it tighter, and the
  cap is the direction's own geometry rather than a formula that can
  overrun.

## The three directions

- **A · the scorebug**: one contained box top center, broadcast style. Side
  chips, scores, clock, slot on its foot. Bounded, so portrait cannot
  overrun. Cost: furniture over the fight's top edge.
- **B · the corner tile**: an instrument docked under MENU, where chrome
  already lives. Clock at the head, a row per side, the slot at the foot,
  events appending as a colored row. The center of the glass stays empty.
  Cost: the score stops being the first thing a stranger sees.
- **C · the edge strip**: the window's top edge is the scoreboard, a slim
  bar filled from each end in the sides' colors in proportion, numbers at
  the ends, clock dead center, slot hanging in a tab beneath it. Adapts to
  any width by construction. Cost: the fill jumps rather than creeps in a
  legs game, and the strip's height caps the type.

Three window shapes each. Desktop shows Melee mid-match; landscape shows
Ladder at the moment a rung clears, which is where the mid-screen banner
lives today; portrait shows Ladder mid-life, the exact shape that overruns
today.

## What is here

`build.py` is the source, in the manner of `../spectator-landing/build.py`,
whose design system it borrows: hues from `client/arena/palette.lua`, panel
geometry from `client/arena/ui.lua`, hull outlines to the extents in
`docs/design/ships.md`, sides from `catalog/zones/*/zone.toml` (Pylon and
Caisson; Pilot and Rival). The chrome is the shipped client's: hamburger
MENU, PLAYERS with the two seat marks, LINK and the radar in the far corner.

Rebuild with `python3 build.py`; the nine `.dc.html` files and `canvas.json`
beside it are what a design canvas is seeded from.
