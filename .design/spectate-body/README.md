# A drawing for the spectate stop

Chris's ask: come up with a ship design for spectate on the menu, a few
ideas, mocked up.

Seven boards, drawn against the client rather than around it. Not shipped:
this is a set to pick from.

Artifact: [Spectate Ship Art](https://claude.ai/code/artifact/a620110a-adb9-4014-b03c-dca169cc43ee)

## What is there

The ship stop's body section is a carousel. One ship turns on its own
vertical axis once every eleven seconds, an arrow sits either side of it,
and the name and the hull's own line are under it. Seven hulls turn through
it and the eighth stop is spectate, which has no hull: `sect_rows` sets the
row's `cls` only where the roster's value is a number, and `land_row` draws
a ship only where `cls` is set.

So the row keeps its whole height and spends none of it. `land_row_h` gives
the art row 198 points plus a line of note, the name takes 30 off the bottom
and the sentence 19, and the 168 that are left hold nothing but two arrows
floating at their middle. It reads as a panel that failed to load rather
than as a choice. That is the board called Today, and it is the screenshot
that started this.

## The rules the four follow

**In the language the arena draws a hull in.** Closed plates washed and
outlined in the panel ink, panel lines under them, a silhouette whose every
edge carries its own brightness off a light fixed to the nose, and one
bright closed cell. Every drawing here is written in the local pixels
`world.lua` writes a hull in, nose along +y, so a pick is a table to paste
rather than a picture to work back from. `build.py` carries all four.

**156 points across, and no more.** `land_row` caps the radius at
`HULL_ART_R`, so what a pilot sees is the same circle a hull gets. Anything
that needs to be bigger than a ship to read is out.

**It turns, because everything on this carousel turns.** Local x scaled by
the cosine of the angle, which is a rotation about the axis running up the
screen. The Sheet board draws each one broadside and most of the way round,
because the drawing is never still on this page for longer than it takes to
read. Frame is the exception and holds still, which is the argument it is
making.

**None of them wears the team color.** A hull on this carousel is drawn in
`pal.FRIEND` because the ship you turn to is the ship you fly. A watcher
flies nothing and holds no side, so these are drawn in the instrument gray
the interface uses for everything that describes rather than belongs to you,
and the word Spectate under them stays blue because the stop is still the
one you are standing on. One line in `land_row` picks the color.

## The four

**Ghost.** The roster's own language with the pilot taken out of it: a plain
delta none of the seven flies, its canopy outlined and not filled, no
hardpoints, no lamps, and no light on the nose, because the light on a hull
is a hull under way. It is the cheapest to read, since a pilot already knows
what these shapes are, and the hollow cell is exactly where they are used to
finding the brightest one.

What it risks is the wrong sentence. A hull drawn cold and empty is also
what an unavailable hull would look like, and this stop is not a hull you
cannot have, it is a thing you can choose. It also sits closest to the seven
it has to be told apart from.

**Lens.** The channel's own camera. The ring is the silhouette, the aperture
is inside it, and the pupil is the bright cell, which is the canopy's place
on every other drawing this carousel shows. A hood over the top says which
way it looks, so the front is visibly not the back, and the ring turning
edge on is the clearest read of the turn in the set.

The inversion is the whole argument: a hull's brightest cell is where a
pilot sits, and this one's is where a pilot looks. Nothing has to be said in
words. Against it, it is the least like the rest of the roster, which is
either the point or the problem depending on whether spectate should look
like a ship at all.

**Mast.** A relay with a dish, two panels and a truss, which is a thing the
room has rather than a thing anybody flies. No canopy anywhere on it, and
the bright cell is the feed at the dish's focus. It is the one that agrees
with what the server actually does, since a watcher is on one shared
broadcast five seconds behind the room, and a broadcast comes out of
something.

Its cost is that it is the fussiest of the four at 156 points, and a
structure with no nose is the hardest to tell which way it is facing.

**Frame.** Not a craft at all. Four corner brackets and a reticle, in the
interface's own language rather than the world's, and the one drawing here
that holds still while the carousel turns. It is the honest answer: there is
no ship, so what stands in the ship's place is the act of framing the room.

Its cost is that it is furniture. The other seven stops on this carousel are
things in the world, and a viewfinder among them reads as the menu talking
about itself.

## What I would ship

Lens. It is the only one of the four whose meaning is carried by the drawing
rather than by the absence of something, it puts its one bright cell where
the seven hulls put theirs so the carousel keeps its grammar, and a circle
going edge on is the best turn in the set at a size where the Mast's truss
is already crowded. Ghost is the safe second and the one to fall back to if
the Lens reads as a machine from a different game.

The line under the name stays what it is. "Watch the room from nobody's
cockpit" is doing the work no drawing can, and a drawing that needs the
sentence changed to explain it is the wrong drawing.

## Building the one that wins

`hull_art` reads `world.HULLS[cls + 1]`, so the drawing wants to live in a
table of the same shape. It does not want to live in `M.HULLS`: that list is
the roster, `TAIL` walks it and reads `.jets` off every entry, and none of
these four has an engine. An eighth entry there is a crash at load rather
than an eighth ship.

So: a table of its own beside the roster, baked by the same loop that bakes
the hulls, and three lines where the carousel draws. `land_row` picks the
gray instead of `pal.FRIEND` on the spectate row, calls the drawing where it
now skips one, and holds the turn still if Frame wins. Nothing on the wire
moves, nothing in `sim` moves, and no other page draws a hull this way.
