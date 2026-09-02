# Maps

> **A map says how large it is and why it exists.** Match maps now span square,
> wide, and tall envelopes. The open arena remains a thousand tiles. A map
> carries its own width and height, so sections below that discuss a thousand
> tiles apply to that arena rather than every map.

The original's map was a 1024x1024 grid of 16-pixel tiles, and a tile's
number was its behavior: 1 through 160 were walls, 162 through 169 were
doors, 171 was a safe zone, 176 through 190 were scenery you flew under. Every
rule in the engine was a range check against a constant, and a map editor had
to know all of them.

The tile is the same size. The numbering is not, and neither is the grid: a
map here says how big it is.

## A tile is its behavior

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
| `SLOPE` | half a wall, cut corner to corner |

Ten classes rather than 190 numbers, and how a tile is *drawn* is not in that
list at all -- that is the client's business, and the reason the original
needed 160 wall values where this needs one.

The byte is class in the low nibble and a variant in the high one. Doors use
the variant as a channel, so a map can open one set while another shuts;
goals use it as the team that scores there; a slope uses it as the corner it
fills. A solid uses it for what kind of solid it is, which the core never
reads: every one of them stops a ship the same way, so the whole vocabulary of
wall, map edge, rock and station costs the simulation nothing and buys the
renderer a room that does not look poured from one mold. Those live in
`sim.h` as `SIM_SOLID_*` with the classes, because the client and the map
editor both copy them and a numbering two files disagree about is a station
that saves as a rock.

## A map is the size it says it is

The size is in the file, up to 1024 each way, and the two need not match. A
match room is 160 tiles and the open arena is a thousand, and the world ends
at the edge a map declares: `sim_tile_at` answers solid past it, so nothing
outside is anywhere.

Before this every map was the full square and a small one was drawn as a hole
in the middle of a solid megabyte. It worked and it cost: every pass over the
map paid for the thousand-tile square whatever the map held, the file carried
it, and the overview drew a match map as a speck in a black field with no way
to ask how big the room actually was. An empty 96 by 144 room is 833 bytes
where the same drawing inside a full square was six thousand.

The tile array does not change size. It is always the full square, so indexing
is a constant, nothing allocates, and a map that grows or shrinks moves
nothing; the declared size only says how much of it is the map. Sizes below
nine tiles are refused, since the boundary is four tiles thick each side and a
map smaller than its own walls has no inside.

## A wall can be diagonal

A diagonal built from square tiles is a staircase, and a staircase is not a
shape a ship can fly along: every step is a fresh axis-aligned bounce, so a
hull skimming one rattles down it instead of sliding, and a round fired along
it skips. A `SLOPE` is that wall with the steps cut off. Its variant names the
corner that stays solid, so the face is the diagonal opposite it, and two of
them meeting at a corner make one continuous face however long the run.

**The angle is 45 degrees because that is the one that is exact.** Reflecting a
velocity off a 45 degree plane is a swap and a negate: a face through NW and SE
turns `(vx, vy)` into `(vy, vx)`, and one through NE and SW into `(-vy, -vx)`.
There is no table to read and no root to take, so there is nothing to round. A
round bouncing off one keeps every bit of its speed and leaves square to how it
arrived. An arbitrary angle costs a trigonometric table and a rounding rule,
and both are places two architectures can disagree, which in this core is the
one bug worth never having.

A hull's box is resolved out along the face's own normal, half the depth on
each axis, so a ship leaning into a diagonal is set down on it rather than
shoved sideways to a tile edge. The velocity is split into the part along the
face and the part into it; the first keeps `friction` and the second reverses
with `bounce`, which is what a wall does per axis, said in the face's own
frame.

**Slopes go in runs.** A hull is three tiles across, so it rests on several
tiles at once, and a lone slope cut into an otherwise flat top gives it two
surfaces that disagree about where it should be: the flat clamps it down and
the diagonal pushes it out, every tick. Drawn as a continuous face with the
wall's body behind it, a box resting on the plane never reaches the square
tiles under it: the corner that would touch one is the same corner the face
is holding up. That is what stops the staircase coming back as the square
backing behind a smooth front.

The generator draws its diagonals this way, as a pair of tiles side by side,
each filling the corner nearest the other. Their solid halves meet along the
whole of the edge they share and their open halves fall outside, which leaves
**one stripe** with a face down each side. Two tiles across, not a solid tile
in it, and the two faces are parallel: both are the run's own line, a tile
apart. A stripe, not a vee and not a zigzag.

Two and not one, because a single run is a **one-way wall**. Tiles of one
variant meet corner to corner, so the face they make is continuous and the
material behind it is not: coming at the side the solid halves face a hull is
stopped, and coming at the other it goes straight through, because the open
halves line up into a corridor. Sixteen hulls out of sixteen, at every speed
measured. It looks like a wall on the drawing from both sides, which is why
that is a test rather than a sentence.

What makes the pair work is that the two runs **share a whole edge**. Each tile
is solid the entire length of the side it hands its neighbour, across the run
and along it both. Every other diagonal a square grid can draw meets corner to
corner and pinches to a point there, and that pinch is the interesting part:

**A pinch is no hole to a hull and it is a hole to a bullet.** A hull is three
tiles across and cannot fit through a point. A round can. Fired square at a
stepped diagonal, a round travels along the other diagonal, which takes it
exactly through the corners where the tiles touch, and it passes through a wall
that stops every ship in the game. One heading in thirty-two, and the heading
is the shot anybody would take. That was true of the generator's diagonals for
as long as they were stepped, and of a sloped run with a solid spine down the
middle, which has the same stepped line inside it. The pair leaks on none of
the thirty-two.

The pair is also *thinner* than the staircase it replaces: seed 3 of the open
arena goes from 3.06% solid to 2.91%. A thick diagonal reading as a smear at
radar scale was the reason these stayed single stepped tiles for so long, and
it turns out not to be a cost that had to be paid.

The match maps draw from that vocabulary now too. They used to build their
cover from two shapes, a filled rectangle and a hollow room, so every piece of
it was a box; there was never an argument for the smaller maps having a smaller
vocabulary, it just never got written. A shape is drawn once into its box and
then read back and laid down half a turn away, rather than drawn twice, because
the shapes make their own random choices as they go and drawing one twice draws
two different shapes.

Two things had to move with them. A slope names the corner it fills, so half a
turn flips that corner to the opposite one, and a mirrored diagonal without
that comes out inside out. And the wall fraction a match arena is held to
counted whole solid tiles only, so a diagonal drawn as slopes vanished from the
measure: converting one read as the map losing wall it had not lost. A slope is
half a tile of wall and counts as half now, in both generators.

## The edge of the world is not a map's to draw

Every map is closed on four sides by a boundary four tiles thick, painted by
`sim_map_index` around the map's own rect when it is built or arrives,
whatever the file said was there. A map author does not draw one and cannot
leave one out.

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
cross at a hull's top speed. That is a two-ship room wearing an arena's name:
nowhere to go, no distance for a chase to happen over, no reason to choose a
direction.

The field is a lattice of 64-tile cells, each holding one of four structures
picked by a hash of its coordinates: a block, a cross, four pillars, or open
space. 256 landmarks, none wider than twenty tiles, so the lanes between them
are always at least twice the width of what is in them. A lattice rather than
a drawn map because a drawn 1024-tile map is a job for a person, and this had
to stay legible from a C file. A
refuge -- a small safe zone -- sits every fourth cell each way, so nowhere in
the field is more than a couple of hundred tiles from somewhere to stop.

The old room survives at the center, minus its enclosing box: the four
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
the flag game unplayable rather than large: the shipped Capture the Flag map
starts its pilots in a 68-tile box at the center, so the nearest flag sat two
hundred tiles away, past sixty tiles of sight, past the radar, and past
anything that would take a pilot there. Watched on the live server for four
minutes: forty-two kills, four flags, and the banner never moved off "flags 0 -
0, 4 loose". Nobody had touched one, and nothing about a healthy arena said so.

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
all eight inside a 68-tile box at the center, and that is deliberate: a public
room with ten pilots in it wants them meeting in the first ten seconds, not
converging over half a minute. The built-in procedural map keeps the bands,
because that is the shape a 1024-tile map is for, and a zone that wants its
pilots together ships a map that puts them there.

It has no wormhole. One reaches 220 px, fourteen tiles, and the bot ladder
found what that does to a small room: pilots spawned eight tiles from one
stopped fighting and orbited it instead, and the tournament graded a whole
roster equal because nobody landed a shot. A map this size can hold one; where
to put it is a decision for whoever draws it rather than for a C file.

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

Two names above are the old ones. Greens went with the match game and came back
for Free Roam ([decision 132](../architecture/decisions.md#132-a-green-raises-what-you-fly-not-what-you-own)),
and the rebuild kept every measurement in this passage and none of the
spelling: the ceiling is `SIM_MAX_GREENS`, the count a zone asks for is
`green_target`, and the ring is `green_near` and `green_far`. What is not here
is a `spawn_prizes`. A green fills a slot in the kit space rather than dealing
a prize, so a pilot starts a life on the build they chose and grows from there,
and the thirty a fresh spawn used to be dealt has nowhere to go.

The calibration pit has neither. It measures two pilots against each other,
and a room that size with somewhere invulnerable in it settles nothing. The bot
ladder found that one the hard way: a pilot that wandered into a safe zone
stopped dead, could not be shot and could not shoot, and the match ended with
nothing having happened.

Both are lessons about *placement*, not about the features. A map large
enough to hold a wormhole should have one.

The safe zones taught a third. Placed near the boundary wall they made a
cul-de-sac, and a traced flight showed what that feels like: full clamp speed
across every safe tile, then a bounce-thrust trap in the slot beyond. Held
thrust against a wall converged to a tenth of a pixel a tick, which a pilot
reports as "the safe zone is sticky". The zone was never sticky; the pocket
behind it was. That was measured when a wall gave back ten sixteenths and it
gives back all of it now, so the trap is milder; the placement rule is not
about the number. They sit in the open channels now, where
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

A map travels as a run-length encoded tile array behind a fourteen byte header:
magic, version, the map's width and height, and an FNV-1a hash. The full-size
reference arena is 28 KB and a match room under four, and it is sent once when
a client joins.

Runs are read in the map's own row order, and the array's stride is not in the
file. A small map that carried it would spend every row saying "and then eight
hundred and eighty tiles of nothing", and would be a different file at a
different stride.

The encoding lives in the core, next to snapshot packing and for the same
reason: the client has to decode it identically or it predicts collisions
against a different room.

The hash is the point of the header. A client that decodes a map and gets a
different number has a different map, and would rather be told than spend a
match wondering why it keeps hitting nothing. The original checksummed its
maps too; this just refuses to play rather than reporting a mismatch and
carrying on. The size is hashed along with the tiles, so the same drawing at
two sizes is two maps and cannot be mistaken for one.

The size is also what the reader checks first, and the length bound has to
cover the whole header: it was still version 1's ten bytes for a while, and a
file truncated between the two got past the check and had its size read off the
end of the buffer.

`mapdump` writes one of the built-in rooms out as a file:

```sh
make -C sim build/mapdump
./sim/build/mapdump arena catalog/zones/somezone/somezone.vwmap
```

## The match maps

Five ship. One theme apiece, because a theme is a whole geometry
rather than a texture: these are five rooms a pilot can tell apart from the
radar corner.

| Map | Theme | Envelope | What it is |
|---|---|---|---|
| maelstrom | spiral nebula | 160 square | two asteroid arms winding out of a wormhole core |
| gantry | station yard | 192 by 144 | stations on a grid, gantry stubs, doored bays |
| warren | maze | 160 square | brick-bond corridors, every third shortcut on a door |
| redoubt | twin fortresses | 192 by 144 | a walled keep around each home, open ground between |
| ringworks | rings | 160 square | concentric rings, gaps rotated, warps off the corridor |

Between them they place every element a melee map is allowed. Maelstrom and
ringworks carry the wormholes; gantry, warren, redoubt and ringworks the
doors. Safe, goal and turf tiles stay out by gate, for the reasons under
"what the reference arenas use".

They replaced a rotation of six drawn by the scatter generator, which measured
correctly and read as one room with six coats of paint. The old maps and their
recipes are still in the tree and still verify; nothing plays them.

They come from `mapforge`, the server binary's offline map tool. Each `.vwmap`
has three files beside it: a `.recipe.toml` source, a `.metrics.json` review
report, and an `.svg` preview with its accepted routes drawn over it. The
recipe pins the output hash, so provenance is the full design brief rather than
a seed that only makes sense inside one generator version.

```sh
cargo run --manifest-path server/Cargo.toml -- \
  mapforge verify catalog/zones/melee/drydock.recipe.toml \
  catalog/zones/melee/drydock.vwmap
```

### The generation pipeline

A map starts as a brief: mode, theme, arena envelope, symmetry, route count,
minimum opening, and contact-time window. The seed chooses small details
inside that brief. It does not choose what sort of map is being made.

The brief becomes a `LayoutGraph`. Homes, junctions, and edges are named
before a tile is placed, and the junctions hug the home ends so each reserved
lane crosses the field as one straight, clean channel. Geometry reserves
every graph edge at the brief's opening width. There is no connectivity
repair. A layout that fails is rejected instead of having a random tunnel cut
through it after the fact.

**A theme owns its geometry.** The first version of this pipeline paired a
topology with a theme that scattered materials over it, up to a hundred and
ten placements at random coordinates, and every map came out as the same
rubble in a different texture. Now the theme is the topology: every shape
sits on a module grid, placement runs along lattices, bands, and rings, and
the seed varies texture inside the pattern rather than the pattern itself.
Each theme also declares which elements it uses and what cover fraction it is
held to, which is how doors and wormholes reach generated maps and how a maze
is allowed five times the wall of a nebula.

Five themes ship, one per map in the rotation: spiral-nebula, station-yard,
maze, twin-fortresses, and rings. Thirteen were drawn and reviewed as
pictures; the five that survived are the ones worth a slot, and the rest are
in the history rather than in the enum, because a theme nothing plays is a
pattern to maintain for nobody.

A wormhole is a hazard and an ejector seat, not a gate. The core sends a ship
that touches one back to its own team's start, so a warp is a way out of a
fight rather than a way across the map, and making one lead anywhere else is
a simulation decision no map brief can take. That fact drew the nebula: its
core wears a rock collar with four diagonal mouths, and the middle lane bows
around it, because a wormhole sitting on the shortest home-to-home route is a
trap the route gate cannot see. A path search reads a warp as open ground.

It is also the one element a brief can refuse. `allow_wormholes = false` on a
theme that draws one lays the clearing and no mouth, leaving the rest of the
pattern on the tiles it was on, which is how the duel's ninety-six tile maps
are the nebula and the rings without a well in either. Doors work the other
way: a brief that refuses them on a theme that draws them is rejected rather
than redrawn.

The spiral is integer arithmetic against a baked table of headings rather
than a call to `sin`. A recipe pins the hash of the map it draws, and a libm
that rounds one heading differently would move a rock a tile and fail
verification on a machine that was not the one that pinned it. Same reason
the simulation core has no floats in it.

The scatter generator is frozen beside the new one, in
`server/src/mapforge/legacy.rs`, and still reproduces the six maps that
preceded this rotation. It is the same arrangement `sim/tools/mapgen.c` has
with the maps that preceded those: kept to reproduce, never the source of new
maps.

The client gives those materials one visual grammar without flattening them
into one tileset. A bulkhead is deliberately plain: a dark solid body, a
continuous bright collision edge, and enough rim shading to show its depth. It
carries no hatches, pipes, braces, warning marks, panels, or interior seams.
Thin partitions and deep walls use the same treatment, so walls stay quiet
while the objects around them carry the arena's mechanical detail.

A rock is warmer, faceted, and carries a sparse mineral seam. It does
not turn: an asteroid that tumbles cannot be built into the terrain mesh, and a
map laying a few hundred of them then costs more of a frame's vertex budget
than the fight it is a backdrop for. A station fills the whole six-tile square
the simulation collides with, then cuts docking throats, armor quarters,
trusses, and a cold reactor into that mass. The detail is subordinate to the
outside edge at combat zoom. A player reads collision first and fiction on the
second look.

The thick perimeter mass uses the same plain treatment. Its broad dark body
distinguishes the arena boundary from an interior partition.

Large objects are stamped as objects, so a station's six-tile body cannot be
mistaken for accidental wall thickness.

### Gates and review scores

Every candidate first passes `sim_map_check`, the same hull-sized validator the
server and editor use. Mapforge then requires exactly four starts per side,
exact half-turn competitive symmetry, the brief's two or three separated
routes at least seven tiles wide, two spawn exits, the requested home-flight
time, no elements the brief does not call for, and the theme's own cover
band, with a slope counting as half a tile of wall. Generic wall in playable
space must remain a centerline. Perimeter masses and complete rocks or
stations are intentional solids and are measured separately.

Passing is not the same as being good. The report also scores route balance,
line-of-sight distribution, dead ends, cover balance by quadrant, landmark
count, material mix, theme fidelity, and spawn exits. A batch can add two short
bot drills, recording travel, fighting, crawling, bounces, weapon use, and map
coverage across seeds.

Those scores compare seeds inside a theme, not themes against each other. A
maze scores lower than a station yard on dead ends alone, and a maze without
pockets is a set of rows. What decides whether a map is worth a slot is
`vectorwake-server melee 20 <map>`, which flies the roster on it: the first
draw of warren answered skill with a +0.69 correlation against the rotation's
+0.87 and threw a third fewer rounds, because its cross walls ran the whole
way between rows and every pocket closed to three sides. Shortening them put
it back at +0.89. That is the measurement a picture cannot make.

The review command produces ten candidates, two seeds of each theme:

```sh
cargo run --manifest-path server/Cargo.toml -- \
  mapforge batch /tmp/vectorwake-maps 20260826
```

`index.html` is the contact sheet. Each card links through the files beside
it, so a person selects a candidate with its picture and evidence together.
`--no-simulate` skips the bot pass when the job is only a quick geometry
iteration.

The old `sim/tools/mapgen --match` path remains frozen for reproducing the two
maps that preceded this rotation. It is not the source of new match maps. The
same C tool still owns the separate thousand-tile open-arena family described
below.

## Where the open arena's map came from

The zone it was drawn for is gone, and the generator that drew it is not. It
is the family every big map in this repository comes from, and what follows is
how it works, kept because the next open arena will want it.

`sim/tools/mapgen.c` draws one from a seed:

```sh
make -C sim build/mapgen
./sim/build/mapgen out.vwmap 28
```

Seed 28 drew the map the open arena shipped with, and a seed is the whole of a
generated map's provenance: the same number gives the same map on any machine,
so a file in the repository can be explained by a command rather than by
whoever happened to draw it.

Which seed ships is a drill result rather than a preference, and that one was
picked the same way seed 23 was before it. Twelve candidates were flown by
the full roster and the one whose kill rate, accuracy, time to first contact
and fighting share landed on top of the map it replaced was kept. That
matters because the spread between maps is wide: across seven maps of this
family the kill rate runs from 0.60 to 0.98 a bot-minute and the time to
first contact from 41 to 58 seconds, so a new map is only the same game as
the old one if somebody checks.

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

**Every shape in it is symmetric and centered**, and every member of a cluster
is drawn off one roll of the dice, so a group is one shape repeated rather
than four cousins of it. Both of those replaced random offsets, which drew a
map that measured correctly and read as rubble. A room is cut on opposite
walls at the same place, so it is something to fly straight through rather
than a chicane. A stack of lines is centered and the same above the middle as
below. A diagonal is one tile per step, never two, and crossed diagonals meet
on exactly one tile. The crotches of an X and of a V are left open: they are
narrower than a hull, and the sweep that walls in unreachable ground used to
plug them with square wall, which ran every X's arms into flat ledges. It
skips the inside of an angle now, because a corner closing to a point does
not read as a way in the way a square notch does. A hall's four ways in are
the same width and each sits in the middle of the wall it goes through.

The arithmetic under that is parity. A run centers exactly in a span only
when the two are both odd or both even, so a gap's width is moved to its
wall's parity before it is placed rather than rounded into position after.
One tile is the whole difference between a gap that faces the one opposite
and a gap that does not, and there is no way to see which you have except by
flying at it and stopping.

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

**Then it walks out to whatever ground the dice missed.** Districts say where
building is likely, not where it happens, so a seed can leave a hundred tiles
of open field with nothing on it at all. Measured across seeds, the share of
open ground more than forty tiles from any wall ran from under 3 per cent to
over 8, which is the difference between a map with lanes in it and a map with
a car park in the middle. So a last pass picks a tile at random from whatever
is beyond that distance, drops a group beside it, and repeats until the share
is down to 3 per cent. It is not a density knob: the wall it adds only goes
where there was none for forty tiles in any direction, and it stops as soon
as the map is inside the figure. Across the twelve selftest seeds it holds
that share between 2.3 and 3.9 per cent, against 2.9 to 8.3 without it.

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

Then it fixes what it drew, and it does that against a hull rather than
against a point. **A ship is three tiles across.** The widest one in the
roster measures just over 39 pixels at the beam and the longest reaches under
23 pixels from its center at the worst diagonal, against a 16-pixel tile: two
tiles is 32 pixels and holds neither of them, three is 48 and holds both at any
heading.
So a hull stands on a tile only when the eight around it are open too, and
the connectivity of a map is the connectivity of that set.

Structures placed independently strand ground between them whether or not any
one of them is closed, which is dozens of pieces per map. Each is joined to
the field along the shortest line between them, breadth-first from the piece
outward, and the lane carved back along that line is three tiles wide because
the thing being let out is a ship. What is left over afterwards is slivers:
the tile between two structures that stopped one apart, or the inside of
something drawn too small to enter. Those are walled in rather than dug out,
since a sliver widened into a lane is a hole knocked in a structure that was
fine as it stood.

Stranded ground is not wasted so much as a trap: a ship shoved into it cannot
leave, a prize landing there is gone, and a bot routing toward it grinds on
the wall in front of it.

Then it checks, and refuses to write a map that fails:

- sixteen spawns placed, eight a side, north and south
- nine safe zones placed
- **one** region a hull can fly, with the doors open
- no spawn, safe tile or wormhole out of reach of it
- no open tile a hull cannot reach with the doors open
- solid between 2% and 4.5% of the interior

The generator draws its halls as though a door were a wall: one axis of a hall
is hung with doors and the other is left open,
rather than all four being doors and the connectivity pass tearing a hole in
a wall to undo it.

All of that used to be measured one tile at a time, and one tile is not a
ship. Read that way a single-tile notch counts as a way in, so structures
nothing could enter passed the check, and the pass that joined the pockets up
dug single-tile channels that satisfied it and let nobody through. The map
this replaced shipped that way: 59 separate regions a hull could fly and
16,431 tiles of open ground it could not reach, doors counted shut, on a map
the generator had checked and reported as one region.

`mapgen --selftest` runs twelve other seeds through the same checks and is
part of `make -C sim check`, so a change that makes the generator produce
unplayable maps fails the build rather than the match.

Those checks say a map can be flown, not that it is worth flying. For that
there is `vectorwake-server drill <zone> 180 51`, which flies the live bot
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

Which maps a zone plays has a section of its own below.

Clients are sent the map before the welcome, since prediction runs collision
locally and needs the room before it needs anyone in it.

## Where a map comes from

Four places, and they all end at the same check.

`mapforge` builds match candidates from recipes. `sim/tools/mapgen` draws the
large open-arena family from a seed.
`sim/tools/lvl2vw` converts one from the original's format, which is how a room
somebody else play-tested for years can be flown against our collision.
And the admin panel has an editor: a canvas one square per tile, every class
above as a palette, and half-turn symmetry that turns a slope to its opposite
corner and hands a start to the other side.

Every class, and every variant of one worth placing. A solid tile is not one
thing: its variant is the difference between a wall somebody built, the map's
own edge, two sizes of rock and a station, and the renderer draws each of them
differently. Two of those are larger than a tile, and only the top-left of a
big rock or a station carries the picture while the rest is body, so the editor
places one as a block snapped to the object's own grid. That snapping is not
tidiness. A station dropped one tile off another buries a corner under
somebody's body tile, and a buried corner draws as nothing while staying every
bit as solid, which is an invisible wall.

Drawing is the usual set: pencil, line, rectangle, outline, fill, and a
marquee that moves what is inside it and answers the clipboard keys. Held
shift locks a line to the nearest eighth of a turn and a rectangle to a square,
which is how a run of slopes gets drawn exactly diagonal rather than nearly so.
A drag shows what it would leave before it leaves it, computed by running the
tool itself against a bucket rather than the map, so the preview cannot drift
from the thing it is previewing. Space or the middle button moves around a map
too wide for the frame.

The editor can also open a local `.vwmap` candidate without publishing it and
load the candidate's metrics JSON. Route overlays draw the three separated
paths over the tiles, while the cover overlay shows the quadrant distribution.
The score panel keeps flight time, balance, wall share, dead ends, theme
fidelity, and hash beside the drawing while a person makes the final call.

Whichever drew it, `sim_map_check` decides whether it can be played. It asks
about a hull rather than a point: whether a three-tile ship can fly all of the
map, and whether each start is somewhere a ship can leave.

Ground no hull can reach is reported and not refused. It sounds like the worst
thing on the list and mostly is not: a hull is three tiles across, so any two
rocks with a single tile between them leave a tile no hull's center can come
within one of, and a drawn asteroid field is hundreds of them. The first map
anybody scattered rocks over came back with thirty-eight and nothing wrong with
it. The three things the refusal was guarding are all somewhere else now. A
ship cannot be shoved into a gap it does not fit in; a prize cannot land there,
because prizes came out of the core; and a bot cannot route there, because nav
counts a tile blocked unless a hull fits on it. What is left is worth knowing
and is not a verdict: a two-tile passage that looks like a route and is not,
against a crevice between two rocks. The editor draws those tiles in orange so
an author can tell which they are drawing, since the difference is obvious at a
glance and invisible in a number.

A place a hull could fly and cannot reach is still refused, by the region
count: that is the same fact said about ground a ship can actually be on.

All of that with the doors open, because a door is a wall on a clock and the
clock keeps running: at the baseline it is shut two seconds in every six, and a
pocket behind one is somewhere you wait to get into rather than somewhere you
cannot go. The worst case is already the engine's, since a ship caught by a
closing door is warped home.

It used to ask with every door shut, on the argument that a route through one
can be held against you for a third of the cycle. That is an argument for a
door-gated pocket being awkward, not for it being unplayable, and the cost was
the whole class: a door could never be the only way into anywhere, so it could
never gate a pocket, so it was a second entrance to somewhere already open with
eight channels of timing on it. The first map drawn with doors in it came back
"a start is walled in", and the map was right.

The shut count survives as `regions_shut`, and the editor says so when it
exceeds the open one: that map's shape depends on its doors opening, which a
zone setting `door_period` to zero would not do. Which zone it lands in is not
the map's business, so it is a note rather than a refusal. The generator refuses to
write a map that fails it and the meta-layer refuses to store one, so a map
drawn by hand is held to exactly what a generated one is.

The editor does not carry its own copy of that. It packs the tiles, posts them,
and shows what the core said, which is also what stops a browser and a
simulation quietly disagreeing about a room. What it does have to get exactly
right is the file, since the far end unpacks it with the same function an arena
does and refuses anything whose bytes do not match the hash in its own header.

## Which maps a zone plays

A zone names its own in `zone.toml`, relative to the zone's directory:

```toml
maps = ["maelstrom.vwmap", "gantry.vwmap", "warren.vwmap"]
```

More than one is a rotation, and the room takes the next one at every whistle.
Empty runs the built-in arena, so a zone with no map is still a zone. A map
that will not load is reported and then ignored, because a zone that refuses
to start over a bad file is worse for the people trying to play in it than one
that runs the reference room and says so.

An operator can point a zone somewhere else from the panel, and that overrides
the file for that zone until it is taken off again. The file stays the reviewed
baseline: it is what a fresh deployment boots with and what the tests run
against.

A rotation changed under a running room does not interrupt it. The match in
progress finishes on the ground it started on, because swapping the map under
a live fight is a desync everybody sees, and the next whistle is seconds away.
See [../architecture/admin.md](../architecture/admin.md) for how a publish
reaches a fleet.

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
