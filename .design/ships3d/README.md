# Ships in three dimensions

A mock, not a plan. It asks one question: what would the seven hulls look like
with a third dimension under them, and would the game still look like itself.

The answer this settles on is that the third dimension goes into the geometry
and nothing else. These are solids, occluding each other and the walls, seen
through a perspective camera; they are shaded the way `client/arena/world.lua`
shades a hull, which is to say not at all. There is no light in any of these
pictures. A face carries the fill it was given when it was built, the hull's
own nose lights its edges, and the outline is drawn as light over the top. A
lit, specular, shadow-casting version of the same meshes was the first thing
built here and it looked like a different game.

![the roster](renders/roster.png)

## What is drawn from what

Nothing here invents a ship. `hull_export.py` reads the seven hulls out of
`client/arena/world.lua`, applies the same `fit` the client applies at load,
and writes `hulls_data.h`. So a hull in these pictures has the outline, the
plates, the panel lines, the canopy, the hardpoints, the lamps and the engine
mouths the game already draws, sitting inside the footprint
`sim/src/baseline.c` gives its class.

The one invented number is height, and it is derived rather than drawn: the
crown is read off a distance field over the outline, so a hull stands tall
where it is wide and stays low where it is a wingtip or a nose. A roof is also
never allowed to be taller than the room it stands on, which is what keeps the
Apex's neck and the Lattice's arms from coming out as fins.

The fill is the client's own, taken from `world.lua` rather than picked:

```
body = team * 0.055 + (0.018, 0.026, 0.042)
wash = team * 0.20 * light
```

with `light` the nose-fixed edge light the flat client uses, generalized to a
face normal. Doing that sum in linear light rather than in display space adds
several times as much wash and turns every hull into a hologram, which is worth
saying because it is what happened first.

## The footprint still holds

Every hull spends exactly 625 square pixels of target area, and the drawing has
to sit on the box the core collides it in. That contract is
`sim/src/baseline.c`'s, and `client/tests/hull_fit_test.lua` holds the flat
client to it. A third dimension is not a licence to escape it, so `make check`
takes the same measurement on the meshes:

```
$ make check
hull     nose  box / drawn      tail  box / drawn      flank box / drawn      area px^2    diag
Apex           20 / 20.69          11.25 / 12.25             10 / 11.00         625.000   22.36  ok
Wedge          11 / 12.00              9 / 10.00          15.62 / 16.62         625.000   19.11  ok
Chord           9 / 10.00              7 / 8.00           19.53 / 20.53         625.000   21.51  ok
Anvil          13 / 13.01             12 / 13.16           12.5 / 13.50         625.000   18.03  ok
Cipher         21 / 22.00          18.06 / 19.22              8 / 9.00          625.000   22.47  ok
Facet          13 / 14.00             12 / 13.16           12.5 / 13.50         625.000   18.03  ok
Lattice        13 / 14.00             12 / 12.74           12.5 / 13.26         625.000   18.03  ok
every hull spends the same 625 px^2 and stays on its box
```

It measures every vertex of every part, hardpoints and lamps and engine bells
included, not just the outline: the furthest thing on a ship is not always on
its silhouette. Nothing in `hull3d.c` moves a vertex in x or y, and this is
what says so out loud rather than asking to be believed.

## The battles are real ones

`vectorwake-server battlecap <zone> <seconds> <bots> <out.vwcap> [map] [seed]`
flies the arena's own brains on one of the zone's own maps, two teams, and
writes down every tick: positions, headings, what was in the air, and every
event the core raised. Nothing in a frame below was posed. The blast fronts are
at the radius the bomb that made them actually had, at the age the tick says,
and the engine trails are where the ship was on the ticks before.

`./mock3d pick <cap>` reads a recording back and says which moments are worth
drawing; `./mock3d kills <cap>` lists every kill with the frame a few ticks
after it, because by the time a blast is big enough to notice it is mostly
over.

A kill on convoy, nine ticks after the bomb:

![a kill](renders/battle-kill.png)

A Lattice and a Wedge on switchyard, from low enough to see they are solids:

![a duel](renders/battle-duel.png)

Four hulls and a fading blast on shoal:

![a melee](renders/battle-melee.png)

Nearly overhead, which is where the game is actually played from:

![as played](renders/battle-topdown.png)

## Running it

```sh
make                 # the renderer
make check           # meshes against the collision boxes
make hulls           # re-read the hull art after editing world.lua
make meshes          # write meshes/*.obj

./mock3d sheet renders/roster.png 1680 880 1.02 0
./mock3d hull 4 cipher.png 900 900 0.95 0
./mock3d battle battle.vwcap 842 kill.png 1400 800 1.05 0
```

The renderer is C99 with zlib for the PNG and nothing else: triangles, a
z-buffer, additive glow lines and a bloom. `r3.c` carries a directional light
and a shadow map that the flat path never calls, left in because the question
of whether these should be lit is the one thing here somebody might reasonably
answer the other way.

## What this does not answer

Whether the client should draw any of this. It draws five mesh layers of flat
vector art, the menu is vector because a Switch cannot composite a DOM over a
live frame, and none of that changes because a mock exists. Height is also a
gameplay claim nobody has made: the simulation collides an oriented rectangle
in a plane, and every hull here is exactly that rectangle seen from above.

`meshes/*.obj` are the seven hulls as plain geometry, if something else wants
to look at them.
