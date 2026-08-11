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

## The edge of the world is not a map's to draw

Every map is closed on four sides by a boundary four tiles thick, painted by
`sim_map_index` when a map is built or arrives, whatever the file said was
there. A map author does not draw one and cannot leave one out.

Four tiles rather than one, and a wall rather than a rule about coordinates,
because a hull at full speed crosses more than a tile in a tick. Collision
resolves one axis at a time against the tiles a ship lands on, so a thin wall
is one it can already be through by the time anything looks, with nothing left
to push it back out of.

It is not in the map file. Every map wants it, so a map that had to carry it is
a map that can be missing it, and every map converted from a `.lvl` was: the
original's client stops a ship at the edge whatever the tiles say, so its maps
never needed to say. The variant marks the ring as a boundary rather than a
wall, which is the one thing the renderer reads it for, and it draws that edge
as a line that is never going to open.

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

**Nothing can shove one out, either.** A repel is `push` with no damage, so
it went straight past the rule that stops damage and threw a sheltering pilot
into the open at speed. That is worse than damage rather than a lesser
version of it: the zone is the only place in the game a ship can stop, so
taking somebody out of one takes away the exact thing they went there for,
and it did it from outside, where they could not answer. "Nothing reaches a
ship in a safe zone" now means the shove as well as the hit.

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
**Flags sit one per quadrant of the middle, forty tiles out.** Not spread with
everything else, and that exception is the whole lesson of this section. They
were three hundred tiles apart for the same reason the starts are, and it made
the flag game unplayable rather than large: the shipped War map starts its
pilots in a 68-tile box at the centre, so the nearest flag sat two hundred tiles
away, past sixty tiles of sight, past the radar, and past anything that would
take a pilot there. Watched on the live server for four minutes: forty-two
kills, four flags, and the banner never moved off "flags 0 - 0, 4 loose". Nobody
had touched one, and nothing about a healthy arena said so.

Forty tiles out puts all four on the radar of a pilot standing between them, and
eighty tiles between neighbours is about twelve seconds of flying -- enough that
a lone pilot collecting the set gives the other side time to flip one behind
them. The previous swing of this pendulum had them four tiles apart, which was
one scrum in one room. This is between the two, not a return to it.

Spread the territory; keep the objective where the people are. Greens learned
the same thing one paragraph down.

Crossing takes about thirty seconds at a hull's top speed, which is a journey
rather than a walk. The bots fly it, but not for the reason first written here:
that reason was "their targeting has no range limit," and bounding perception to
the radar's sixty tiles removed it without anybody noticing the map depended on
it. Starts 256 tiles apart and sight of 60 is every pilot alone, and a pilot who
could see nobody used to sit still. They rally to the middle now, which is what
makes a spread map a fight rather than an empty one.

**Two zones ship their own maps with the starts together.** Chaos and War put
all eight inside a 68-tile box at the centre, and that is deliberate: a public
room with ten pilots in it wants them meeting in the first ten seconds, not
converging over half a minute. The built-in procedural map keeps the bands,
because that is the shape a 1024-tile map is for, and a zone that wants its
pilots together ships a map that puts them there.

It has no wormhole. One reaches 220 px, fourteen tiles, and the bot ladder
found what that does to a small room: pilots spawned eight tiles from one
stopped fighting and orbited it instead, and the tournament graded a whole
roster equal because nobody landed a shot. A map this size can hold one; where
to put it is a map-editor decision rather than a C-file one.

**Two things had to scale with the map rather than sit in it.** The client
meshes terrain in a 113-tile window around the camera and rebuilds it when the
camera has walked 16 tiles, because a million tile queries per map load is not
a thing a browser does. And the greens had to stop being placed by area.

The first answer was to scale the count: 20 prizes over 80 tiles became 200 over
1024, which meant raising `SIM_MAX_PRIZES` to 255, the wire's own ceiling, since
a snapshot writes a u8 index and a u8 count. It did not work, and it could not
have. Two hundred greens over a million tiles is one per five thousand, against
a pilot who sees sixty tiles: measured against the live arena, a mean of two
inside the whole 256-tile interest radius and none at all within sight for the
length of a session. A player put it as "war zone seems to have no greens."
Neither zone had any, in the only sense that matters, and since `spawn_prizes`
is zero on purpose the tech tree was unreachable with them.

**A green appears near a pilot, not somewhere on the map.** In a ring six to
twenty-eight tiles from a live ship: outside the first so it is a trip rather
than a gift, inside the second so it lands on their radar. Twenty greens where
the people are beats two hundred in a million tiles of nobody, and the count
came back down to two dozen. Kept at two hundred the ring carpets the ground a
pilot is standing on, which handed one arena multifire, bounce, proximity and
three energy steps inside a minute.

It also answers the bandwidth problem the count created. A snapshot carries every
live green at eleven bytes, so 150 was 1.6 KB a snapshot and 33 KB/s at 20 Hz,
almost all of it greens nowhere near the player reading them. Interest management
came in and cut what is sent to a 256-tile circle; placing greens where the
pilots are means what is sent is also what is worth sending.

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

`mapdump` writes one of the built-in rooms out as a file:

```sh
make -C sim build/mapdump
./sim/build/mapdump arena catalog/zones/somezone/somezone.vwmap
```

## Where Alpha's map comes from

`sim/tools/mapgen.c` draws it, from a seed:

```sh
make -C sim build/mapgen
./sim/build/mapgen catalog/zones/alpha/alpha.vwmap 23
```

Seed 23 is the shipped map, and the seed is the whole of its provenance: the
same number gives the same map on any machine, so a file in the repository can
be explained by a command rather than by whoever happened to draw it.

It exists because the map that shipped before it was a converted `.lvl` from
an existing zone, which is somebody else's drawing however it reaches us.
[research/map-measurements.md](../research/map-measurements.md) counts what
such a map is made of: three per cent wall, four fifths of that a single tile
thick, several hundred small structures standing in an open field in groups,
with long empty lanes between the groups. Those are facts about a map rather
than the map, and mapgen is what happens when you build to them.

It draws from a vocabulary of rooms with gaps cut through them, corner
brackets, lattices of single tiles, stepped diagonals, capped bars, line
stacks and loose debris, in clusters of two to six at a time.

Where those clusters go is decided at two scales, and it takes both. The map
is divided into thirty **districts**, each with its own density, and every
district gets built: none is left empty. Inside a district, one to three
**sites** say where the building actually happens, and a site is small, forty
to sixty tiles. So the wall is spread across the whole map at the scale of a
quarter of it, and bunched at the scale of a screen. The lanes come from where
the sites are not.

That is measured rather than chosen. Sorted into 128-tile squares, the map
this replaced has no empty square at all: its emptiest is 1.6 per cent wall
and its fullest 7.3. Sorted into 32-tile squares, a fifth of them are empty.
It varies enormously up close and hardly at all across the map, and only two
levels of placement give you both.

Five large halls are placed first as landmarks, since rejection sampling gives
the last caller whatever room is left and a map wants its big pieces sited
before its small ones. Safe zones and the wormhole come next for the same
reason: nine berths on nine anchors became four when the field went in first.

Two things are arranged rather than left to the dice, because measuring the
random version showed it was wrong.

**Safe zones sit on nine anchors** spread over the map. Placed at random they
clustered: a median of 94 tiles between neighbours where the measured map has
291, and five of the map's sixteen quarters holding all nine. Spread is the
whole reason for having nine rather than two, so it is arranged.

**Door lines run out of a wall and stop in open ground.** Every one of the
measured map's 28 door runs is attached to something, none stands alone, and
half of them are longer than nine tiles. Attaching one end and leaving the
other free is also what makes a barrier safe: one bridging two structures
divides the field when its channel shuts.

Then it fixes what it drew. Structures placed independently enclose ground
between them whether or not any one of them is closed, which makes dozens of
sealed pockets per map. Each is joined to the field by digging the shortest
line of wall between them, breadth-first from the pocket outward. Around forty
tiles a map, nearly all of them single. A pocket is not wasted ground so much
as a trap: a ship shoved into one cannot leave, a prize landing in one is
gone, and a bot routing toward one grinds on the wall in front of it.

Then it checks, and refuses to write a map that fails:

- sixteen spawns placed, eight a side, north and south
- nine safe zones placed
- **every** open tile on one region, with doors counted as shut
- no spawn, safe tile or wormhole off it
- solid between 2% and 4.5% of the interior

The connectivity check counts a door as a wall throughout. A pocket reachable
only through a door is still a pocket, since its channel shuts for part of
every cycle and a ship inside would be held until it opened.

`mapgen --selftest` runs twelve other seeds through the same checks and is
part of `make -C sim check`, so a change that makes the generator produce
unplayable maps fails the build rather than the match.

Those checks say a map can be flown, not that it is worth flying. For that
there is `vectorwake-server drill alpha 180 51`, which flies the live bot
count on the real map and reports what they did with the time. It is what
picked the seed, and it caught the door mistake before the measurement did:
twenty free-standing fences across open lanes cost a third of the kills,
because a fence in a lane is something to fly around on the way to a fight.
Counting the measured map's doors properly said the same thing from the other
direction, since none of them stands in open ground at all.

Where it ended up, against the map it replaced:

| | replaced | drawn |
|---|---|---|
| kills per bot-minute | 0.80 | 0.88 |
| shots hitting | 17.6% | 23.6% |
| bounces per bot-minute | 6.5 | 7.0 |
| time crawling on a wall | 6.7% | 8.8% |
| ground covered, 8-tile cells | 3288 | 2981 |

And how it is spread, which is the check that caught the first version being
polarised into empty quarters and crowded ones:

| | replaced | drawn |
|---|---|---|
| wall, 128-square spread | 0.42 | 0.46 |
| 128-squares with no wall | 0.0% | 0.0% |
| wall, 32-square spread | 1.00 | 1.02 |
| open ground 20+ tiles from a wall | 15.3% | 18.1% |
| open ground 40+ tiles from a wall | 1.7% | 3.7% |

Map to map the same settings give anything from 0.71 to 1.15 kills, so the
seed is chosen from a handful rather than tuned toward a number, and a
difference inside that spread is not evidence of anything.

What it does not attempt is symmetry. The measured map has none to speak of,
and neither does this one: the sides are statistically alike and
geometrically different, which is the arrangement that stops a player learning
one half and knowing the other.

A zone names one in its own `zone.toml`, relative to the zone's directory:

```toml
map = "chaos.vwmap"
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
