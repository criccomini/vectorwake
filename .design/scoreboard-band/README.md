# The scoreboard band, round four

Chris's notes on the shipped band, a week after decision 67 put it there:
the top middle looks wonky, the time is big and the scores small, and there
is no one idea holding it together. Now that the players sheet carries the
roster, the band is carrying less than it did. What he wants from the next
one: the pilot's own rating on screen the whole match, so it can be watched
going up and down; each zone's own facts, a clock where the match is timed,
sides and scores where there are sides, flags where there are flags; not
invasive; and good looking. Four directions, drawn for every zone and at the
whistle on one sheet, then each on a monitor and an upright phone. Drawings
of a proposal, not a plan of record. Nothing here is built.

## What every direction shares

- **The clock is smaller than the score.** The two numbers that change every
  few seconds are the big ones; the one that only counts down is not. It
  takes the warning color under thirty seconds rather than growing.
- **The rating is on screen for the whole match**, as the standing in ink
  and the movement since the pilot sat down in brackets, green up, red down,
  dim at zero: `1494 (-6)`, the form the players sheet already uses. That
  contradicts the line in `docs/design/interface.md` that keeps the rating
  off the HUD because a pilot cannot act on it; the ask is to watch it, and
  watching is the point.
- **A flag is the beacon** the radar draws for one (decision 149), held ones
  in the holder's color and loose ones dim.
- **A duel's rounds are two pips a side**, filled when taken, since first to
  two is the rule and a numeral for a count that tops out at two is a
  numeral wasted. A side named by its pilot keeps its own case; a team's
  name is a label in the instrument's case.
- **At the whistle** the side that took it keeps its ink and the other
  stands down to a third, over the clock counting to the next match. Free
  Roam has no clock and no score, so its band is the room's count and the
  rating. The band stays the press that opens the players sheet.

## The four

- **A · The scoreline.** One line at top center, the score leading it: a
  side is its score at 22 points with its name at 10 beside it, the clock
  between them at 15 in the reading ink. Flags hang under the clock; the
  rating is a readout in the top left, the twin of POS at the top right. The
  least change of the four. Costs: the top left is no longer empty, and a
  phone still drops the names.
- **B · The corners.** You in the top left, them against the dial, the clock
  alone between. Each corner is a stack the way the bottom left already is:
  name, score at 30, and a line under it, your rating under yours and in a
  duel the rival's under theirs. Costs: the two scores are far apart, and on
  a phone the clock is centered between the blocks rather than on the
  window.
- **C · The bar.** The score as a shape: a three point bar filling from each
  end in the sides' colors in the share each has, figures at its ends, clock
  over it. In a flag game the bar is the long axis of the map and the stands
  sit on it as beacons; in a duel it is the match in rounds, a segment a
  round, the one in play breathing. Your rating sits under your end. Costs:
  three lines tall, and the fill moves in steps in a kill game.
- **D · The tally.** A stack in the top left the way a broadcast keeps
  score: clock, a line a side with score, name and held flags, then the
  rating under a caption. Rows of marks and counts with no panel, which is
  what the corner stack at the bottom left is made of. Costs: the score is
  not the first thing a stranger sees, and this is the corner shape drawn
  once already in `../scoreboard-sheet`, kept here because the rating gives
  it a row it did not have.

## What is here

`build.py` is the source, in the manner of `../scoreboard-sheet/build.py`,
whose chrome it carries forward: hues from `client/arena/palette.lua`, the
row's measures from `client/arena/ui.lua`, the beacon, the dial's strip, and
the two faces the client carries. Rebuild with `python3 build.py`; the
twenty six `.dc.html` files and `canvas.json` beside it are what a design
canvas is seeded from.
