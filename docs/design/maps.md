# Maps

The original's map was a 1024x1024 grid of 16-pixel tiles, and a tile's
number was its behaviour: 1 through 160 were walls, 162 through 169 were
doors, 171 was a safe zone, 176 through 190 were scenery you flew under. Every
rule in the engine was a range check against a constant, and a map editor had
to know all of them.

The grid is the same. The numbering is not.

## A tile is its behaviour

| Class | What it does |
|---|---|
| `EMPTY` | nothing |
| `SOLID` | a wall |
| `SAFE` | no damage in, no fire out, and the only place a ship can stop |
| `DOOR` | a wall on a clock |
| `GOAL` | reports entry; what it is worth is a mode's business |
| `WORMHOLE` | pulls |
| `OVER` | scenery drawn over the ships, never solid |
| `UNDER` | scenery drawn under them |
| `TURF` | a flag stand a mode can find |

Nine classes rather than 190 numbers, and how a tile is *drawn* is not in that
list at all -- that is the client's business, and the reason the original
needed 160 wall values where this needs one.

The byte is class in the low nibble and a variant in the high one. Doors use
the variant as a channel, so a map can open one set while another shuts;
goals use it as the team that scores there.

## Safe zones are load-bearing

Flight is frictionless: momentum never bleeds off, and there is no brake
anywhere in the game. A safe zone is where you get one, which makes it the
only place a ship can come to rest. That is why the original had them, and
why an arena without them has nowhere to disengage to.

Flight inside one is identical to flight anywhere else -- not merely
unbraked, identical, and there is a test that measures it against open space
rather than against a threshold. The first attempt bled 18% of speed a tick,
which reads as "slower but still moving", and any threshold loose enough to
be safe would have passed it.

The trigger is the brake. Pressing fire in a safe zone does not shoot; it
stops the ship dead. That puts coming to rest under the pilot's thumb rather
than under the floor, and it costs nothing to learn, because pressing fire is
what a pilot does anyway.

They cut both ways on purpose. Nothing can hurt a ship inside one, including
a blast that clips the edge, and nothing can be fired out of one either --
otherwise it is a firing position with immunity attached. Anything the ship
already had in the air comes down with it, so firing and running for cover
cannot score from the one place nothing can answer.

## Doors breathe

A door cycles on a period, open for part of it. The variant offsets the phase
by eighths, so a map with several channels opens and shuts in sequence rather
than blinking at once.

Open doors still draw their frame, faintly, so a pilot can see where the wall
will be and time the crossing rather than discovering it.

A door that shuts on a ship warps it back to where it started. Leaving it
there is not an option the collision can resolve -- both axes are blocked, so
the ship sits inside the wall until something kills it. Warping keeps a door
lethal to position without being lethal to the pilot.

## What the reference arenas use, and what they do not

The public arena has two safe zones on its long axis and a pair of doors out
of phase. It has no wormhole: one reaches 220 px, fourteen tiles of an arena
that is eighty-four across, so any placement near the middle bends every
crossing in the room. The bot ladder found that before a player would have --
pilots spawned eight tiles from one stopped fighting and orbited it instead,
and the tournament graded a whole roster equal because nobody landed a shot.

The duel arena has neither. A duel is decided by two pilots, and a room that
size with somewhere invulnerable in it is not a duel. The ladder found that
one too: a bot that wandered into a safe zone stopped dead, could not be shot
and could not shoot, and the match ended with nothing having happened.

Both are lessons about *placement*, not about the features. A map large
enough to hold a wormhole should have one.

The safe zones taught a third. Placed near the boundary wall they made a
cul-de-sac, and a traced flight showed what that feels like: full clamp speed
across every safe tile, then a bounce-thrust trap in the slot beyond --
held thrust against an inelastic wall converges to a tenth of a pixel per
tick, which a pilot reports as "the safe zone is sticky". The zone was never
sticky; the pocket behind it was. They sit in the open channels now, where
every way out continues somewhere, and the rule generalises: never put a
safe zone where the natural way through it ends in a wall.

## Bots know about safe zones

Only just enough: a bot that finds itself in one flies out. Without that it
brakes to a halt and becomes an invulnerable ornament, which is what one did
-- sitting in the east zone with a flag game going on around it.

## One copy

The arenas are built in the core, in `sim/src/baseline.c`. They used to be
the same magic numbers written out in the client's C++ and again in the
server's Rust, which is one edit away from a client predicting collisions
against a wall the server does not have.

A map file carries the tile classes above -- not a tileset index, which is a
rendering concern that has no business in a simulation.

## Map files

A map travels as a run-length encoded tile array behind a twelve byte header:
magic, version, and an FNV-1a hash of the tiles. The reference arena is 1615
bytes and the duel room 487, out of a megabyte of tiles.

The encoding lives in the core, next to snapshot packing and for the same
reason: the client has to decode it identically or it predicts collisions
against a different room.

The hash is the point of the header. A client that decodes a map and gets a
different number has a different map, and would rather be told than spend a
match wondering why it keeps hitting nothing. The original checksummed its
maps too; this just refuses to play rather than reporting a mismatch and
carrying on.

```sh
make -C sim build/mapdump
./sim/build/mapdump arena zone/maps/arena.vwmap
```

A zone names one in `zone.toml`:

```toml
map = "maps/arena.vwmap"
```

Empty runs the built-in arena, so a zone with no map is still a zone. A map
that will not load is reported and then ignored, because a zone that refuses
to start over a bad file is worse for the people trying to play in it than
one that runs the reference room and says so.

Clients are sent the map before the welcome, since prediction runs collision
locally and needs the room before it needs anyone in it.

## Spawn points travel with the map

A `SPAWN` tile marks where a ship starts, and its variant is the team. They
go through the feature index like turf and goals, so finding one costs the
number of features rather than the million tiles behind them.

`sim_map_spawn(map, team, nth)` walks a team's starts in order and wraps, so
a roster spreads across them instead of stacking on one, and a roster longer
than the map's starts still fits. A team with no start of its own falls back
to anybody's, because a ship inside the walls on the wrong side beats a ship
outside them. A map that names no starts at all reports none, and the zone's
configured tiles stay in charge -- which is how every map worked before this,
so nothing that already ran had to change.

This is the part that makes a map portable. Before it, pointing a zone at a
new map left the roster's tiles pointing into the old map's geometry: on a
corridor map every ship began in open space outside the walls and drifted off
at twenty tiles a second. Now a stock `zone.toml` and a foreign map put all
eight ships inside the room, split by team.

The same placement care applies. A start next to a wormhole is a start that
pulls the whole roster into it before anyone has flown anywhere -- which the
first corridor map did, because its spawns sat two tiles from one.
