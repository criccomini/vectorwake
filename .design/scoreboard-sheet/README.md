# The scoreboard sheet

Round two of [one board](../one-board/README.md). Chris picked the sheet, the
menu's own panel, and asked for four things: name it for what it is, have the
column say which side you are on, give the menu language a section that can
be pressed, and make it hold in every zone. And, apart from the sheet, a look
at other shapes and places for the band it hangs off. Twenty two boards.
Drawings of a proposal, not a plan of record. Nothing here is built.

## What the sheet is

- **A stop in the column.** `SCOREBOARD` sits between `ZONE` and `SHIP`, and
  its answer is where you stand: your side and its score, `Pylon 17`, or
  `Watching`. The band's press and the board key open the same panel. That is
  a fifth stop, which decision 143 named as the number to watch on a short
  window's rail; the phone board carries the cost.
- **A section per side, and the section is the press that joins it.** The
  menu language had bands (a label between rules, not pressable) and rows
  (pressable, one shape). This is a third thing: a row that heads a group and
  is itself a control. A rule over it, the name spoken at 17 in the side's
  color, the score read beside it, its stands or flags after that, seats at
  the right end. The gutter says what a press does: the wedge on the side you
  fly for, a ring on a side with a seat, nothing on a full side, whose reading
  says `Full`. The ring is the pips' own mark for an empty place. Two other
  shapes are on the language sheet, an act word at the right end and the
  HUD's stroked key, and the ring leads because it adds no new mark and no
  second button shape.
- **Pilots under their side**, indented, with what the zone counts and how
  long they have been in: `K D A Time` in the team zones, `K D Time` in the
  duel and Free Roam. Your own row keeps its wash. Watchers close the list
  under a band.
- **At the whistle** it rises on its own with the result as its head, the
  share bar under it, the winner first, a rating column, and the MVP mark.
  The band keeps the clock.

## By zone

- **Team Battle** counts kills. Drawn on a monitor, both phones, between
  rounds, and once named `Teams` beside the `Scoreboard` board to compare.
- **Turf** counts turf, and each side's row carries the stands it holds as
  pennants in its color, with the stands nobody holds dim after them.
- **War** counts rounds and shows the four flags the same way.
- **The duel** counts rounds. A side is one pilot, so the section is the
  pilot, with its own figures at the right end and nothing to join. A
  `Rounds` band under the two lists who took each round and how long it ran,
  with the round in play reading its clock.
- **Free Roam** has no clock and no score. Eight sides of eight, rings on the
  ones with a seat, and the list scrolls under the pinned head.

## The name

`Scoreboard` leads. Its answer down the column is where you stand in every
zone, which is what `Teams` was for, and it survives the two zones `Teams`
does not: a duel, where the answer would be your own call sign, and Free
Roam, where a side is a pact of one with no score. Both are drawn.

## The band

Three shapes, each drawn for every zone on one sheet and then in a Turf room
on a monitor and a War room on a phone:

- **Middle**, the shipped band: the clock one key tall at top center, a side
  either side of it as a name over a number, pennants under. Keeps the first
  glance.
- **Thin**: one line at 16 points in the same place, the clock smaller, names
  and scores at one weight, pennants inline. Spends less of the top edge and
  makes the clock small.
- **Corner**: a stack in the top left, the clock then a line per side with
  its pennants. Clears the top edge for the fight and sits where the room's
  chips come and go. Drawn once with the sheet up, since the sheet no longer
  hangs under the thing that opens it.

Free Roam is the same open question in all three: with no clock and no
score, the band is the room's count and nothing else.

## What is here

`build.py` is the source, in the manner of `../one-board/build.py`, whose
chrome it carries forward: hues from `client/arena/palette.lua`, the band,
key, stop and row measures from `client/arena/ui.lua`, the seat marks and the
pennant, and the two faces the client carries.

Rebuild with `python3 build.py`; the twenty two `.dc.html` files and
`canvas.json` beside it are what a design canvas is seeded from.
