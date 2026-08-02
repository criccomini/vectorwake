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

The public arena is the map's full size: **1024 tiles square**, 16384 pixels on
a side, which is the size the original's maps were.

It was an 84-tile room in the middle of all that space, about ten seconds to
cross at a hull's top speed. That is a duel room wearing an arena's name --
nowhere to go, no distance for a chase to happen over, no reason to choose a
direction.

The field is a lattice of 64-tile cells, each holding one of four structures
picked by a hash of its coordinates: a block, a cross, four pillars, or open
space. 256 landmarks, none wider than twenty tiles, so the lanes between them
are always at least twice the width of what is in them. A lattice rather than
a drawn map because a drawn 1024-tile map is a job for a map editor and a
person, and this has to stay legible from a C file until that exists. A
refuge -- a small safe zone -- sits every fourth cell each way, so nowhere in
the field is more than a couple of hundred tiles from somewhere to stop.

The old room survives at the centre, minus its enclosing box: the four
pillars, the baffles, the two safe zones and the pair of out-of-phase doors.
It is contested ground rather than home.

**Everything else is spread over the map, because otherwise the size is
decoration.** The first version of this kept every spawn, both safe zones and
the whole green field in the middle, on the reasoning that pilots scattered
over 1024 tiles would never find each other. That produces a full-size arena
whose players are all inside one 84-tile box -- which is the small arena
again, with a lot of unused address space around it.

So: each side gets a home band, team 1 across the north and team 0 across the
south, **eight starts apiece 256 tiles apart**, from (180,180) to (948,884).
Flags sit one per quadrant, three hundred tiles apart -- they used to be four
tiles apart in the middle, which made the flag game a scrum in one room. And
the green field covers the whole map.

Crossing takes about thirty seconds at a hull's top speed, which is a journey
rather than a walk. The bots fly it: their targeting has no range limit, only
a preference for what is close and expensive, and the green detour they take
on the way is capped at twenty tiles for exactly this reason -- on a map with
greens everywhere there is always another one nearer than a target half a map
away, so a generous detour radius is a bot that hoovers its way around the
arena and never arrives.

It has no wormhole. One reaches 220 px, fourteen tiles, and the bot ladder
found what that does to a small room: pilots spawned eight tiles from one
stopped fighting and orbited it instead, and the tournament graded a whole
roster equal because nobody landed a shot. A map this size can hold one; where
to put it is a map-editor decision rather than a C-file one.

**Two things had to scale with the map rather than sit in it.** The client
meshes terrain in a 113-tile window around the camera and rebuilds it when the
camera has walked 16 tiles, because a million tile queries per map load is not
a thing a browser does. And the green field went from 20 prizes over 80 tiles
to 200 over 1024, which meant raising `SIM_MAX_PRIZES` to 255 -- the wire's
own ceiling, since a snapshot writes a u8 index and a u8 count. Steady state
is about 150 alive.

That costs bandwidth: a snapshot carries every live green at eleven bytes, so
150 is 1.6 KB a snapshot and about 33 KB/s at the 20 Hz rate, for greens most
of which are nowhere near the player reading them. The way out, when it
matters, is sending a client only what is near it. That is interest
management, it is a feature rather than a number, and it is the same answer
for every other thing a 1024-tile map has too many of.

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
magic, version, and an FNV-1a hash of the tiles. The full-size reference arena
is 28 KB and the duel room 487 bytes, out of a megabyte of tiles. It was 1615
bytes when the arena was one room; the difference is the 256 structures in the
field, and it is sent once when a client joins.

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
