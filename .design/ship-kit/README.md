# Ship tuning mocks

Four boards for the proposal that the thirty point kit returns without its
economy: no shop, no ownership, no wallet, everything reachable by every
pilot from the first session.

- **Roster** the ship page as shipped, plus the two things the kit adds: a
  TUNE key on the ship you fly, and a one-word "tuned" mark on a hull whose
  build has been stepped off its default.
- **Tune, the default** the editor at rest on the Apex: each slot is a plain
  sentence stepped by the triangles the wake row already taught, grouped
  gun, bomb, rack, with the budget in the head and RESET as the entire
  build manager.
- **Tune, mid-edit** the same page after trading a repel away: points free
  in the head, a slot at its cap saying so, RESET awake.
- **Flight spendable** the fork not recommended, drawn so the choice is
  looked at rather than argued: a flight section whose five rows step the
  hull's own numbers.

Every hull's shipped profile is its default spend of the thirty, so the
board a new player meets is the roster and nothing else; the editor is
optional depth. One remembered build a hull, saved as you step. Slot
prices on the boards are stand-ins that make the Apex's default sum to
thirty; the real prices are the balance work's to set.

`build.py` is the source, in the manner of `../menu-rows/build.py`, whose
drawer chrome it borrows, brought forward to the current client: the foot
rail of decision 80 with friends gone, link bars in the head beside the
call sign, the row states of decision 72, hull outlines to the extents in
`docs/design/ships.md` and flight bars to its table.

Rebuild with `python3 build.py`; the four `.dc.html` files and
`canvas.json` beside it are what a design canvas is seeded from.
