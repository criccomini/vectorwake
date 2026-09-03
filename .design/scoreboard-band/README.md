# The scoreboard band, round four

The band at the top of the window is decision 67's: the clock one key tall
at top center, a side either side of it as a 9 point name over a 14 point
number. Chris's notes on it, a week in: the top middle looks wonky, the
time is big and the scores small, there is no one idea behind it, and now
that the players sheet carries the roster the band is carrying less than
it did. He asked for the pilot's own rating on screen the whole match, so
it can be watched going up and down; each zone's own facts, a clock where
the match is timed, sides and scores where there are sides, flags where
there are flags; nothing invasive; and for it to look good.

Four shapes were drawn. Chris picked the scoreline and asked for one thing
changed: nothing on the row varies in size. Drawings of a proposal, not a
plan of record. Nothing here is built.

## The pick: the scoreline, at one size

One line at top center, everything on it 13 points, which is the HUD's own
body size and what POS and the feed are already set in. A side is its
score and its name; the clock stands between them in the reading ink; the
rating is a readout in the top left, the twin of POS in the top right,
at the same size again. What tells a score from a name from the clock is
color and order rather than weight: a side's two words wear its color, the
clock is the reading ink, the rating is ink with its movement colored.

- **The row** is one key tall as before. The band grows outward from the
  clock and stops short of the dial; a name that would run into the
  rating on the left or the dial's strip on the right drops, and the
  figures always draw. A phone drops both names and the rating's caption.
- **The rating** is your own standing in this zone, as the players sheet
  writes it: the standing in ink, the movement since you sat down in
  brackets, green up, red down, dim at zero. That reverses the line in
  `docs/design/interface.md` that kept it off the HUD.
- **Flags** hang under the clock as the beacon the radar draws for one,
  held ones in the holder's color and loose ones dim. Turf shows six,
  Capture the Flag four.
- **A duel** is one kill (decision 146), so there is no score to show
  until it is over: the row is the two pilots either side of the clock.
  Their names keep their case, and a phone keeps them.
- **Free Roam** has no clock and no score, so its middle is the room's
  count.
- **At the whistle** the side that took it keeps its ink and the other
  stands down to a third, and the middle reads `NEXT MATCH IN 0:12` on
  the line itself, since a second line would be a second size.
- **The clock** goes to the warning color under thirty seconds rather
  than growing.
- The band is still the press that opens the players sheet.

The first sheet draws it for every zone and at the whistle, then at 12,
13 and 14 points side by side, then beside the shipped band. The boards
after it are a monitor in Team Battle, Turf, the duel and at the whistle,
and an upright phone in Team Battle and Turf.

## The first pass, for the record

Four directions, each drawn for every zone and at the whistle, then on a
monitor and a phone. The scoreline in this pass had its scores at 22, the
clock at 15 and the names at 10, which is what Chris picked from. Its
duel, like the other three, was drawn as rounds first to two with pips
for the rounds; the duel had been one kill since decision 146, and the
pick corrects it.

- **A, the scoreline**: one line at top center with the score leading,
  the rating a readout in the top left.
- **B, the corners**: you in the top left, them against the dial, a small
  clock alone in the middle; your rating under your score, and in a duel
  the rival's under theirs.
- **C, the bar**: a three point bar filled from each end in the sides'
  colors by score share, scores at its ends, the clock over it; in a flag
  game the stands sit on the bar as the map's long axis, in a duel the
  bar is the match in rounds.
- **D, the tally**: a broadcast stack in the top left, the clock, a line a
  side, then the rating. The corner shape drawn once already in
  `../scoreboard-sheet`, kept because the rating gave it a fourth row.

## What is here

`build.py` is the source, in the manner of `../scoreboard-sheet/build.py`,
whose chrome it carries forward: hues from `client/arena/palette.lua`, the
row's measures from `client/arena/ui.lua`, the beacon the radar draws for
a flag, and the two faces the client carries. The rooms are the ones every
band mock has been judged against: Pylon against Caisson at 17 to 20 with
the viewer, DRiFT, on the losing side.

Rebuild with `python3 build.py`; the twenty seven `.dc.html` files and
`canvas.json` beside them are what the design canvas is seeded from.
