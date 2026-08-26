# The match ending, rethought

Twenty one boards for the screen a match ends on. The shipped one is a single
measure holding a title, a score bar, both rosters, six SAY chips, the
next-match clock and a share key, and Chris's reading of it is:

- small and busy on a monitor,
- no sense of how *you* did,
- most of it is the scoreboard's own content a second time, and the SAY row
  is about to be a keyboard shortcut anyway.

Chris's reading of the first four, which is what the leading page came from:
none of them, but keep the plain pilot list with your own row washed, keep the
bar with each side's points on it, drop the block of big figures, drop the
clock's drain bar, shrink the share key and call it INVITE FRIEND, and lay the
three window shapes out the same way. And then the question that reframed it:
maybe there is no ending page at all, and the board the band opens just comes
up when the match does.

This landed. `podium()` in `client/arena/ui.lua` draws what the leading page
draws, `client/tests/podium_test.lua` holds the geometry to it, and decision
68 records what it replaced. The boards stay as the drawing the layout was
settled against.

## The board is the ending (page one)

No podium. At the whistle the board comes up by itself and grows a head and a
foot: the line saying who took it, the bar under it carrying each side's name
inside its own share of it with the points on the ends, the pilot list with
your own row washed, and a foot with the countdown and one key. One layout at
every size; the measure, the type and where the block sits are all that
change, and on an upright phone it hugs the foot of the screen so the one key
on it is under a thumb.

The side that took it comes first everywhere on this page, whether or not it
is yours, so the line, the bar and the rows all read the same way down the
page. That is the one rule the ending does not share with the band, which
puts your own side on the left mid-match so the reading stays positional.

The three boards differ in one thing, how the list is ordered:

- **One list, winner first.** The board's own list, re-ordered once at the
  whistle so the winning side runs before the losing one.
- **A block per side.** The same rows grouped, each side's points on its own
  head. Clearest team reading, busiest page.
- **Best gun first.** One list across both sides ordered by kills, so the room
  is ranked and your washed row is where you placed.

## The first four directions (page two)

Told apart by what leads the page.

- **A · your match leads.** The result is a line; your four figures are the
  page. Everyone else is one list under them. Answers the question without
  being asked; costs the scoreline its size.
- **B · the result leads, your row pulled out.** The scoreline stays big and
  your row is lifted out of the roster into a band of its own. The smallest
  change from what ships, and still the busiest of the four.
- **C · what it paid leads.** The rivets the match earned are the hero
  number, since that is the one figure the scoreboard does not carry. Risks
  ending a bad match on a cheerful number.
- **D · a title card.** The result, one line about you, the countdown. The
  roster is not repeated, because the board behind the band holds it a press
  away and the card says so.

## Held constant

The match is the one from the screenshot, so the boards compare against
something real: Caisson takes it 20 to 17, and the viewer is DRiFT, nought
and one with six assists on the losing side. A quiet game on a losing side is
the honest test of "how did I do".

On every board the SAY chips are replaced by a line naming the key that will
send them, each roster row carries what that pilot earned, and the foot keeps
the countdown and one share key. A phone held sideways sets the page in two
columns and puts the share key on the countdown's line, because 390 points of
height has no row to spare.

## What is here

`build.py` is the source, in the manner of `../scoreboard/build.py`, whose
design system it borrows: hues from `client/arena/palette.lua`, panel and key
geometry from `client/arena/ui.lua`, the seat marks and the rivet from the
same, and the two faces the client carries.

Rebuild with `python3 build.py`; the twenty one `.dc.html` files and
`canvas.json` beside it are what a design canvas is seeded from.
