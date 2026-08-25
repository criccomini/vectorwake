# The match ending, rethought

Twelve boards for the screen a match ends on. The shipped one is a single
measure holding a title, a score bar, both rosters, six SAY chips, the
next-match clock and a share key, and Chris's reading of it is:

- small and busy on a monitor,
- no sense of how *you* did,
- most of it is the scoreboard's own content a second time, and the SAY row
  is about to be a keyboard shortcut anyway.

Four directions, told apart by what leads the page. Drawings of a proposal,
not a plan of record. Nothing here is built.

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

Rebuild with `python3 build.py`; the twelve `.dc.html` files and
`canvas.json` beside it are what a design canvas is seeded from.
