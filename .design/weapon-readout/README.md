# Weapon readout

Boards proposing what the lower-left corner could be, against what it is: a
stack of weapon marks and loose gold dots with nothing under them. Five
directions, all keeping what earlier rounds settled about the marks (one
drawing per weapon shared with the touch pads, the rung ramp on the round's
own hue, no labels, no bounty) and changing the ground the rows stand on and
what a count looks like:

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
