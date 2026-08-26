# Weapon readout

Boards proposing what the lower-left corner could be, against what it is.
Two rounds so far, two pages of the canvas.

## Round two: the marks (current)

Chris passed on the ground round: the icons themselves are the primitive
part, and the counts should use the ship page's circle grammar. So every
board on the marks page counts charges with `pages.dot`'s three fills
(solid a charge held, ringed the slot a spent one leaves) and proposes a
vocabulary for the four drawings, each shown as an inspection strip plus
the corner in situ at stack scale:

- **F, tracer** (`Tracer`): the icon is the round the arena fires, frozen:
  `world.weapons`' layered streak, hot head and halo.
- **G, ordnance** (`Ordnance`): rounds built the way hulls are, outline
  over darker fill, lit leading edge: a finned dart, a cased shell with
  lugs, a shockwave, a ring of darts.
- **H, ordnance lit** (`Lit`): G's bodies under F's light, a wake and a
  halo on each.
- `MarksCurrent` is the shipped vocabulary at the same sizes, for contrast.

## Round one: the ground (kept as record)

Five directions, all keeping the shipped marks (one drawing per weapon
shared with the touch pads, the rung ramp on the round's own hue, no
labels, no bounty) and changing the ground the rows stand on and what a
count looks like:

- **A, the rail** (`Main`, plus `RailBare` for a fresh spawn): one spine out
  of a chamfered foot, a nub per row, counts as chamfered magazine cells.
- **B, bays** (`Bays`): a chamfered lip per row, the radar's own bracket
  chrome, one hairline deck under the block.
- **C, the hull plan** (`HullPlan`): your hull faint in panel ink, each mark
  on a leader off the hardpoint that fires it.
- **D, the fire arc** (`FireArc`): a quarter instrument out of the corner,
  stations on the arc, the dial corner answered from opposite.
- **E, live fire** (`LiveFire`): the shipped geometry given state: recoil,
  a barrel that relights over the cooldown, breathing when ready, a pulsing
  last charge. Composes with any of the others.

`build.py` is the source, in the manner of `../play-menu/build.py`: hues from
`client/arena/palette.lua`, mark geometry from `client/arena/marks.lua`
(BOLT_LEN, BOMB_R, MARK_REACH, the radial share-out), stack layout from
`status()` in `client/arena/ui.lua`, drawn at z = 2. Rebuild with
`python3 build.py`; the `.dc.html` files and `canvas.json` are what the
design canvas is seeded from. The seeded canvas itself is git-ignored, same
argument that keeps `client/dist/` out of the history.

Every board carries the same loadout so the directions compare: gun at rung 2
wearing spray 2 and bounce, bomb at rung 1 wearing prox 2 and shrapnel 2, two
of three repels, one of two bursts.
