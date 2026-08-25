# Scoreboard rethink

The shipped scoreboard is a centered band that grows outward from the clock
with side names, ratings and the ladder readout, and it has four problems,
all visible from a phone or a desk:

- It overruns an upright phone, because nothing bounds its growth.
- Ladder and Melee fill it differently, so the two zones look like two games.
- Its type is fixed at 13/30pt, which is small at desktop distance.
- Match events arrive as one 24pt white sentence across the middle of the
  screen ("RUNG 3 CLEARED. NEXT RUNG 4, STREAK 3"), the largest and least
  designed thing on the glass.

Four directions were mocked; Chris picked **D** and then pushed it further:
a clock-key first draft put the scoreboard in the corner row wearing a
key's box, and that conflated an instrument with a control. The board now
leads the canvas as **the expanding band**, and the other three directions
stay on a second page for the record. Drawings of a proposal, not a plan
of record. Nothing here is built.

## D · the expanding band

The scoreboard is an instrument, so it wears no key box and sits nowhere
near MENU. Shut, it is a bare readout at top center, each side a two-line
stack in its color: in Melee the team's name over its score, in the duel
the pilot's call sign over their rating, with no score and no rung line,
since neither says anything the duel's readout doesn't say better. The
expand affordance comes from the instrument grammar rather than the key
grammar: the faint corner brackets the radar already wears, brightened
while open. Pressed, the readout grows out of the band, so shut and open
are one object at two depths. PLAYERS is gone, because the readout carries
the roster; MENU stands alone in its corner doing the one static thing.

The open readout is the shipped players panel's own grammar: a section head
in dim capitals with its column labels on the same line, rows under it, a
dashed rule between sections. Sections are the modularity:

- **The pilot list** is shared by every zone: one list, the sides told
  apart by the color the names already wear, the seat's mark,
  k / d / a / pts / bty, watchers at the foot. No team heads, because the
  band above carries the team names and scores.
- **The zone's own sections** stack under it. The duel adds its run of
  fights (rung, verdict, score, time). A team game adds nothing new.
- **The pilot card** a pressed row opens is the same card everywhere: team,
  seat, tier, rating, and the match's numbers.

Desktop shows Melee open; portrait shows the duel open with a pressed row's
card, mirroring a screenshot of the shipped players panel line for line;
landscape shows the key shut at the moment a rung clears, with the event
docked under it.

## The first directions (page two)

- **A · the scorebug**: one contained box top center, broadcast style, the
  zone's slot on its foot. Bounded, so portrait cannot overrun. Cost:
  furniture over the fight's top edge.
- **B · the corner tile**: an instrument docked under MENU. Clock at the
  head, a row per side, the zone line at the foot. Cost: the score stops
  being the first thing a stranger sees.
- **C · the edge strip**: the window's top edge is the scoreboard, filled
  from each end in the sides' colors in proportion. Cost: the fill jumps
  rather than creeps in a legs game, and the strip's height caps the type.

All four share the chassis idea: score and clock common to every zone, a
zone-owned place for what the zone knows, events in the scoring side's
color instead of the mid-screen banner.

## What is here

`build.py` is the source, in the manner of `../spectator-landing/build.py`,
whose design system it borrows: hues from `client/arena/palette.lua`, panel
geometry from `client/arena/ui.lua`, hull outlines to the extents in
`docs/design/ships.md`, sides from `catalog/zones/*/zone.toml` (Pylon and
Caisson; Pilot and Rival). The duel readout's data is lifted from a
screenshot of the shipped players panel so the two drawings compare line
for line.

Rebuild with `python3 build.py`; the twelve `.dc.html` files and
`canvas.json` beside it are what a design canvas is seeded from.
