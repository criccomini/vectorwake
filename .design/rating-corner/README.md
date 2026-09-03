# The rating corner

Decision 163 put your own standing at the near end of the row as
`RATING 1228 (0)`: a caption in the dim, the figure in ink, and what the
match has done to it in brackets. Chris's call on it, the day after: the
corner is the figure and a badge, nothing else. The badge is the pilot's
wings, the mark the players sheet draws beside a human seat, and it wears a
color a tier.

So the caption goes, and so does the bracket, in every zone. What a death
did to the rating is still said where it happens, on the wreck and at the
end of the feed's line (decisions 152 and 155), and the players sheet still
carries the movement in its column. The corner says where you stand and, as
a color, what band that is, which is one mark beside one figure and reads
the same on a phone.

That is built, as
[decision 166](../../docs/architecture/decisions.md#166-the-corner-is-a-badge-and-a-figure-and-every-mark-wears-its-band),
which took the color to the marks beside every name as well: the plate
hanging off a hull and the players sheet's rows, where the shape says what is
in the seat and the color now says how good they are. The first ladder below
is the one that shipped.

- **Five colors for five bands**, none of them a side's: cyan is yours and
  amber is theirs everywhere on the HUD. The bottom band is the mute the
  sheet already draws the mark in, so a new pilot's badge is the badge as
  it is today; the top band is the ink itself. A second ladder with a hotter
  top is drawn for the comparison, and its cost is a fourth color near the
  other side's amber.
- **A placing pilot** has no band, so the badge is the mute, dimmed, and the
  figure is the mute the pilot card already gives a placing pilot.
- **Fourteen points** for the badge, a shade over the row's thirteen point
  type; eleven, the sheet's size beside a name, and eighteen are drawn
  beside it.
- **The bracket kept** is drawn once at the end, for the comparison only.

## What is here

`build.py` is the source. The badge is `pilot_mark` from
`client/arena/ui.lua`, ported quad for quad: the Apex hull in three pieces
and the six feathers `wing_cut` cuts, at the width asked for. The rest of
the chrome is `../scoreboard-band/build.py`'s: hues from
`client/arena/palette.lua`, the row's measures from `client/arena/ui.lua`,
the beacon the radar draws for a flag. The rooms are the ones every band
mock has been judged against, with the viewer's standing in Team Battle set
to the 1228 in Chris's screenshot.

`Main.dc.html` is the sheet. The boards beside it are the corner on a
monitor in Team Battle, Turf and for a Legend, on a phone in Team Battle
and Turf, and the corner as it stood before this on a monitor for the
comparison.

The Turf boards here draw a score and a match clock, which is the row that
zone had when these were drawn. Decision 165 landed the same week and took
both away: a flag game is won by holding every flag, so the middle of its
row is the pennants and the countdown alone. What the boards are about, the
near corner, is unaffected.

Rebuild with `python3 build.py`; the seven `.dc.html` files and
`canvas.json` beside them are what the design canvas is seeded from.
