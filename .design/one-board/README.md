# One board

Twenty two boards for the call that the scoreboard, the ending, the player
list and the side picker are one thing. Chris's ask: unify them, let it be
toggled in game and shown between rounds, keep it off the whole page, and
make it fit a monitor, an upright phone and a sideways one. KISS, and pretty.

Today they are four drawings. The band opens a 340-point roster under it
(decision 67). The whistle takes that roster, zooms it 1.45x and lays it
under an 0.8 wash of the whole window with a head over it (decisions 68 and
94). The side list was a stop in the menu column until decision 143 took it
out to wait for this. Drawings of a proposal, not a plan of record. Nothing
here is built.

## What every direction shares

- **The band stays the instrument it is.** A side is a name over its score,
  as tall as the clock; an upright phone drops the names; between rounds
  the sides go and the clock counts to the next match. A press on it, or
  the board key, opens the room.
- **The room is sections, one per side, and a side's head is the door onto
  that side.** Yours wears the here wedge and the here wash. Any other
  side's head carries JOIN while it has a human seat, and reads FULL,
  unpressable, when it has not. The count is humans of the cap, since bots
  yield their seats. That is the side list of decision 102 with the pilots
  indented under each row of it, and it is the whole of team selection.
  There is no separate stop for it and no second roster to keep in step.
- **Pilots stand under their head** with the K, D, A they carry today, the
  seat's mark beside the name, your own row washed with its lit rule.
  Watchers close the list in nobody's color.
- **The ending is the same panel, one head taller.** At the whistle it
  comes up on its own, at the same size, in the same place, and grows the
  one line it could not know: who took it, and the bar with each side's
  name inside its own share of it. Rating joins the figures, the winner's
  best net wears MVP, and the band keeps the clock with NEXT MATCH IN
  under it. Nothing zooms and nothing washes the window to black: the tint
  is the menu's own 0.42, and every other instrument recedes under it, the
  radar included, as decision 67 already says.

## Where it stands

- **Hang · one column under the band.** Where the board is today, 400
  wide, hanging off the control that opens it. The smallest change from
  what ships. Cost: it stands over the middle of the screen, which on a
  sideways phone is where your ship is, and Free Roam's eight sides run
  past the foot of a monitor and scroll.
- **Wings · a wing under each side of the clock.** Each side hangs off its
  own half of the band, yours left and theirs right, the way the band
  already reads, with the clock's column clear between them. Shallow: four
  a side takes the top 150 points and no more. The reader's side never
  moves, the whistle included; the result is a line across the top and
  each wing's head grows its score. Cost: an upright phone gives each wing
  177 points, so names cut at seven letters and the assists column goes,
  and the right wing stands over the dial. Eight sides tile as a grid on a
  monitor and scroll on a phone.
- **Sheet · the menu's own panel.** The room said in decision 104's
  language: the glass, the head, rows of 44, up through the bottom edge and
  standing on the margin, capped at 560. Nothing new to learn and a thumb
  is already there. Cost: height. Eleven rows at the touch floor is 484
  points before the head, more than a sideways phone has, so there it
  scrolls under the pinned head, and Free Roam scrolls everywhere. The
  score rides the side row because the band is a screen away.

Seven boards each: three windows open mid-match, the same three between
rounds, and Free Roam on a monitor, because eight sides of eight is the test
of putting the side picker in the roster. Free Roam also shows the one thing
none of this settles: a zone with no clock and no score has nothing for the
band to say, which decision 67 named as the case that would make the
chassis a third thing.

## Held constant

The match is the one every ending mock has been judged against: Caisson
takes it 20 to 17, and the viewer is DRiFT, nought and one with six assists
on the losing side. Pylon has two humans of four and Caisson one, so JOIN
is live on the far side; the anatomy sheet draws the FULL state beside it.

## What is here

`build.py` is the source, in the manner of `../podium-rethink/build.py` and
`../menu-language/build.py`, whose design system it borrows: hues from
`client/arena/palette.lua`, the band, key, line and row measures from
`client/arena/ui.lua`, the seat marks, and the two faces the client carries.

Rebuild with `python3 build.py`; the twenty two `.dc.html` files and
`canvas.json` beside it are what a design canvas is seeded from.
