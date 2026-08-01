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

Flight is frictionless: momentum never bleeds off, and there is no brake. A
safe zone is the only thing in the game that sheds speed, which makes it the
only place a ship can come to rest. That is why the original had them, and
why an arena without them has nowhere to disengage to.

They cut both ways on purpose. Nothing can hurt a ship inside one, including
a blast that clips the edge, and nothing can be fired out of one either --
otherwise it is a firing position with immunity attached.

## Doors breathe

A door cycles on a period, open for part of it. The variant offsets the phase
by eighths, so a map with several channels opens and shuts in sequence rather
than blinking at once.

Open doors still draw their frame, faintly, so a pilot can see where the wall
will be and time the crossing rather than discovering it.

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

## Bots know about safe zones

Only just enough: a bot that finds itself in one flies out. Without that it
brakes to a halt and becomes an invulnerable ornament, which is what one did
-- sitting in the east zone with a flag game going on around it.

## One copy

The arenas are built in the core, in `sim/src/baseline.c`. They used to be
the same magic numbers written out in the client's C++ and again in the
server's Rust, which is one edit away from a client predicting collisions
against a wall the server does not have.

Loading maps from files is the next step and is not done. When it lands, the
tile classes above are what the format carries -- not a tileset index, which
is a rendering concern that has no business in a simulation.

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

## Spawn points do not travel with the map, yet

A map carries terrain and nothing else. Where ships start is still zone
configuration, so pointing a zone at a new map without moving its spawns puts
everyone outside the walls -- which, tried on a corridor map, is exactly what
happened: ships spawned in open space and drifted off at twenty tiles a
second.

`TURF` tiles exist for flag stands and the feature index already finds them.
Spawns should work the same way, and until they do a map and the zone that
serves it have to agree by hand.
