# The rating corner

Decision 163 put your own standing at the near end of the row as
`RATING 1228 (0)`: a caption in the dim, the figure in ink, and what the
match has done to it in brackets. Chris's notes on it the day after: it
looks boring, on a phone it is a bare number since the caption is the first
thing dropped, and the bracketed zero says nothing in Turf and Capture the
Flag, where a death moves nothing and the whistle moves everybody
(decision 157).

Three changes are drawn, each on its own and then together. Nothing here is
built.

- **The tier is the caption.** The band the figure is in, Newb to Legend,
  goes where `RATING` was, in the caption's dim, and stays on a phone. A
  pilot inside their first ten rated games reads `PLACING` with the figure
  in the mute, which is what the pilot card already does. A duel keeps its
  two call signs on a phone and has no room for a word beside them, so
  there the caption drops as it does today.
- **A flag zone's bracket says what the score is worth.** The plain answer
  draws no bracket until the whistle. The better one draws what the whistle
  would pay if it went now, worked out on the client from the roster's
  ratings, sides and game counts, a step dimmer than a fact; at the whistle
  the server's figure lands in the same place at full strength. A level
  score costs the stronger side, which is the thing a projection says and
  a score alone does not.
- **A bar under it.** Two points tall, as wide as the readout, filled to
  where the figure stands in its band, on the line the flags use under the
  clock. The track is the pick; five steps, one a band, are drawn beside it
  for the comparison. A placing pilot's bar counts their games toward ten.

## What is here

`build.py` is the source, carrying forward the chrome of
`../scoreboard-band/build.py`: hues from `client/arena/palette.lua`, the
row's measures from `client/arena/ui.lua`, the beacon the radar draws for a
flag. The rooms are the ones every band mock has been judged against, with
the viewer's standing in Team Battle set to the 1228 in Chris's screenshot.
The projection is `rating.md`'s team Elo at one K of 24, from side means
the rooms declare.

`Main.dc.html` is the sheet. The boards beside it are the whole proposal on
a monitor in Team Battle, Turf and Turf at the whistle, on a phone in Team
Battle and Turf, and the shipped corner on a monitor for the comparison.

Rebuild with `python3 build.py`; the seven `.dc.html` files and
`canvas.json` beside them are what the design canvas is seeded from.
