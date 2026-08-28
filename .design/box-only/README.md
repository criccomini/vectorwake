# Box-only mocks: the menu becomes the boxes

Ten boards for Chris's brief: keep only the box style the landing's stops
wear, remove the hamburger menu entirely, hold up at desktop, landscape and
portrait, and rethink the ship experience from the ground up.

The drawer holds five stops today (play, ship, friends, pilot, settings) and
the landing's boxes already answer three of them, so the open questions are
where friends and settings live, what a press does when no drawer stands
behind it, and what the ship box becomes when it has to carry the whole
hangar. Three directions, named by what a press on a box does:

- **A · Unfold** the shipped column with friends and settings aboard as one
  half-width row; a pressed box opens between its neighbors and everything
  else stays put. In landscape the column lies down into the rail of
  decision 91 with the two utilities as square cells.
- **B · Board** no open state at all: every box stands with its rows already
  inside, the fight showing between the glass. Everything is one press away,
  at the price of the most covered screen of the three.
- **C · Deck** a press swaps the column for the next set of boxes, a back
  box at the head, never more than one column on screen. The ship rethink is
  drawn here: a build opens into the whole kit, one box per slot, and each
  box's right edge is either the level you fly or the gold price to raise
  it.

Every direction keeps PLAY NOW as the one celebrated key. A tenth board
answers the match: with no drawer, MENU raises the same column over the
fight and the key reads RESUME.

Drawings of a proposal, not a plan of record. Nothing here is built.

`build.py` is the source, in the manner of `../start-flow/build.py`, whose
design system it borrows: hues from `client/arena/palette.lua`, panel
geometry from `client/arena/ui.lua`, hull outlines to the extents in
`docs/design/ships.md`, the lockup verbatim from `docs/banner.svg`, the kit's
slots and their names from `client/arena/menu.lua` and `palette.lua`, and
the account, zone and ship values from the shipped landing. The open rows
wear the menu's row states from decision 72.

Rebuild with `python3 build.py`; the ten `.dc.html` files and `canvas.json`
beside it are what a design canvas is seeded from.
