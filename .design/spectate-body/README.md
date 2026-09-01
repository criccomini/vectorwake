# A drawing for the spectate stop

Chris's ask: come up with a ship design for spectate on the menu, a few
ideas, mocked up.

Ten boards, drawn against the client rather than around it. Wings shipped,
with the banded cut of its feathers, as [decision
135](../../docs/architecture/decisions.md); the other five are the record of
what it was picked against.

The boards draw the carousel as it stood when they were made, 198 points of
row with a sentence under the name. Decision 128 has since cut it to an
ordinary row, so the drawing ships at a third of the size these show it at.
What they were picked on holds at either size: which drawing, and how the
feathers are cut.

Chris then asked whether the human icon, the ship with feathers, could be the
spectate drawing as well. Two more boards for that, and it changed which one
I would ship. Then the feathers themselves, which do not survive being blown
up eight times: a board of eight cuts, and what the pick costs the four
places the mark is already drawn.

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

## The six

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
interface's own language rather than the world's, and one of the drawings
here that holds still while the carousel turns. It is the honest answer:
there is no ship, so what stands in the ship's place is the act of framing
the room.

Its cost is that it is furniture. The other seven stops on this carousel are
things in the world, and a viewfinder among them reads as the menu talking
about itself.

**Wings.** The badge a seat already wears when a person is in it, at the size
the carousel draws a ship: `pilot_mark`'s own three quads, in one flat color,
holding still, with the feathers recut. See below.

It is the boldest drawing on the sheet and the only one a player has already
learned to read, which is the whole argument for it. Against it: this is the
one drawing here that is solid where the identity document asks for thin
bright outlines over a darker fill. It is an emblem in a place where
everything else is an object.

**Wings, built.** The same badge at the weights the rest of the page is drawn
in. The hull is outlined and washed rather than filled, lit off its nose the
way a silhouette is, with a canopy where every hull carries one, and the
feathers are the same shapes outlined rather than filled. It still reads as
the badge at a glance and stops shouting over the line art around it.

Both hold still. A badge turning about its own vertical axis is a decal
spinning, and there is nothing behind one to come into view.

## What shipped

Wings, in the flat cut rather than the outlined one, with the feathers
banded. The badge is the only mark in this game whose subject is the pilot
rather than the ship, and this is the only stop on the carousel whose subject
is the pilot rather than the ship. Everything else here had to invent a
meaning; this one is already carrying it, and `ui.lua` says so in its own
comment: a badge is what a seat is issued rather than what sits in it.
`spectating.md` opens on the same sentence from the other side, that a
watcher is a connection with a seat in the roster and no ship in the
simulation. The seat is the thing both of them are about.

The objection to the plain one was that fourteen points of solid stroke sits
badly on a page of hairlines, which is what Wings, built was drawn to answer.
The recut feathers answer it instead: a tapered band with two clean edges is
not the same object as a round-capped bar, and the badge holds its weight
against the line art without being hollowed out.

Lens is what I would ship if the answer is that spectate should be a thing
rather than an emblem. It is the better drawing on its own: its meaning is in
the picture rather than in what a player already knows, it puts its bright
cell where the hulls put theirs, and it is the only one of the six with a
turn worth watching. The badge wins on being already true rather than on
being better drawn.

One thing to know before picking the badge. The scoreboard already draws it
beside watchers: a row that is not `r.ai` gets the wings, and a row that is
`r.watch` gets the word "watching" in the columns the numbers would use. So
the mark is currently answering "a person is in this seat" on a surface where
watchers are listed, and the menu would have it answer "the stop about the
person" a screen away. The two readings agree on pilot and differ on what is
being said about them. It has not been a problem for the bot mark, which
means silicon in three places and never anything else, and this is the first
time the wings would mean two things.

The line under the name stays what it is on any of the six. "Watch the room
from nobody's cockpit" is doing the work no drawing can, and a drawing that
needs the sentence changed to explain it is the wrong drawing.

## The feathers

`pilot_mark` is cut for eleven points. There a feather is a stroke one point
across and a round cap is a rounding error. At the 156 the carousel gives it
the same three strokes are fourteen points across with a half circle on each
end, which is three sausages rather than three feathers. What is wrong with
them is the pen, not the arrangement.

Three things, and the first is nearly free. They are not parallel: 32.1, 28.3
and 30.8 degrees, close enough to look like a mistake and far enough to lose
the even gap the roots were cut for. Set all three to 30 and run each one out
to the line the current tips already sit on, and the bottom feather lands
within a thousandth of where it is now and the middle one within two
hundredths. The shape barely moves. It stops wobbling.

Then the ends. Both are cut on a line rather than squared off per feather:
the tips on the line the current three tips already lie on, the roots on the
line through the top and bottom roots, which is the hull's own leading edge
and the thing the comment in `ui.lua` says the roots were placed against. So
the wing is one swept band split in three, with a clean edge either side of
it and the same gap behind every feather.

Then the taper. Half widths run 0.013 of the mark at the root to 0.045 at the
tip, so a feather has a direction in it and the eye finds the gaps. Drawn as
closed shapes rather than strokes, which is how the hull in the middle of the
badge is already drawn, so the corners are sharp for free and no new drawing
primitive is involved: `F.layer:quad` is in `pilot_mark` twice already.

Banded is the cut, and it is what ships. Eight are on the Feathers board,
including the two that were tried and lost. Quill comes to a point, which reads as a knife rather than a feather.
Swept grows everything under a straight top edge, which is what a real
feather does and what makes three of them merge into one wing at this size.

Two constraints hold whatever is picked.

**The spread stays exactly the mark's width.** Every caller lays the badge
out against `k` and one of them sets it beside a call sign, so a tip corner
at 0.51 is a wing that touches a name. The set is squeezed in x until the
widest corner is 0.5, which moves a root two thousandths and keeps the three
parallel, since scaling one axis does.

**It has to survive eleven points.** `pilot_mark` is one function and this is
the carousel's fourth caller: the scoreboard draws it at eleven, a nameplate
at ten, the room's population count at eleven. A taper cut so fine that it is
a hairline there would disappear from three quarters of its callers. So the
widths carry the same floor `pen` puts under a stroke, nine tenths of a
point, and the bottom strip of the Feathers board is that check: rasterized
at one to one and magnified, the recut mark at 10 and 11 points is
indistinguishable from the one shipping now, and from 22 up it reads. The
small callers lose nothing and gain nothing, which is the right answer for a
change made for a drawing eight times their size.

## Building the one that wins

The two badges are the cheap ones. `pilot_mark` is a local in `ui.lua`
declared three thousand lines above `land_row`, and it already takes a
center, a color and the width to draw at, which is everything the carousel
has to hand. The plain one is a call. The built one is that function given a
second way to draw itself, or a sibling beside it.

The recut feathers are six `seg` calls becoming six `quad` calls in that
function, plus the two lines and the two widths they are cut against. That
part is not the carousel's: it changes the mark everywhere it is drawn, which
is the scoreboard, the nameplates and the population count, and the strip on
the Feathers board is there to show that none of them moves.

The other four want a table shaped like a hull's, because `hull_art` reads
`world.HULLS[cls + 1]`. That table does not want to live in `M.HULLS`: the
list is the roster, `TAIL` walks it and reads `.jets` off every entry, and
none of the four has an engine. An eighth entry there is a crash at load
rather than an eighth ship. So it goes beside the roster, baked by the same
loop that bakes the hulls.

Either way `land_row` needs the same three things: the gray instead of
`pal.FRIEND` on the spectate row, a drawing where it now skips one, and the
turn held still for the drawings that do not take one. Nothing on the wire
moves, nothing in `sim` moves, and no other page draws a hull this way.
