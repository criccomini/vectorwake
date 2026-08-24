# Ships

Seven hulls, and a hull is a shape. They fly alike, they climb alike and they
hold alike; what one has that another does not is the rectangle it presents to
a bullet. Everything else a pilot flies with is bought, chosen, and the same
thirty points for everybody.

That is a change from what this document used to say, and the reasoning is
under [standard settings](#standard-settings) and [the tech
tree](#the-tech-tree). The short version: a trait that lives on one hull is a
trait the shop can never sell and a pilot can never choose, and the roster was
carrying four of them.

The role names survive as names for silhouettes. They are useful because a
dart and a slab do play differently, and misleading if read as a stat block,
which is what they used to be.

Support was the eighth, and the Spire carried it. It is gone: see
[decisions.md](../architecture/decisions.md). The role is not disowned, it is
unbuilt, and the archetype list is the shorter for it rather than pretending
one of the seven covers it.

Names follow one family: hard geometric and architectural words, one or two
syllables, no animals and no aircraft. They read cleanly in a kill message and
at radar scale, which is where most ship names actually get used.

## The roster

Reach past the nose, behind the tail, and to either side of the pivot, in
pixels. The drawing is fitted around these collision extents. These are the
differences.

| Class | Reads as | Nose | Tail | Beam |
|---|---|---|---|---|
| **Apex** | A swept dart, wings back far enough to clear its own engines | 20 | 11.25 | 20 |
| **Wedge** | A wide delta with a lit bomb bay down the spine | 11 | 9 | 31.25 |
| **Chord** | A shallow bow with a sensor housing at the middle | 9 | 7 | 39.0625 |
| **Anvil** | A blunt slab with two tubes on a flat bow face | 13 | 12 | 25 |
| **Cipher** | A knife, and the only hull that draws dim | 21 | 18.0625 | 16 |
| **Facet** | A squat pentagon with two barrels out past the nose | 13 | 12 | 25 |
| **Lattice** | A trussed cross with dispensers at the arm tips | 13 | 12 | 25 |

## Standard settings

There is one row, and every hull is on it.

| Speed | Thrust | Rotation | Energy | Recharge |
|---|---|---|---|---|
| 3250 | 17 | 230 | 1700 | 1150 |

Those are ceilings; each stat also has a floor a fresh ship starts at and a
step one kit slot adds, and all three are in `sim/src/baseline.c`. Units follow
[simulation-core.md](../architecture/simulation-core.md): speed and thrust in
the Subspace-derived scales, rotation where 400 is one full turn per second,
recharge in energy per second times ten.

A table of seven rows stood here, giving the Apex a 420 rotation against the
Anvil's 240 and the Anvil a 2600 energy pool against the Cipher's 1100. It was
never what the simulation did. `baseline.c` has carried one shared `flight`
struct since it was written, for a reason it states plainly: all eight of the
original's ships fly identically, and what tells them apart there is ten
capability flags. The table was an intention nobody had implemented.

It is not going to be implemented, either, and that is the decision worth
writing down. A kit is thirty points and
[match-game.md](match-game.md) rests on every pilot dealing the same thirty. If
an Anvil started on 2600 energy and an Apex on 1350, thirty points would buy
wildly different ships depending on what you were sitting in, and the drill
harness would have seven baselines to measure a change against instead of one.
Uniform flight is what makes a kit a fair trade.

So a hull is a shape. See [the footprint](#size-and-shape) below, which is
where the roster actually lives.

## Size and shape

The one thing about a ship the original does not supply. Its files carry no
size at all, so for a while a flat 14-pixel square stood in, then a square per
hull, and neither could be right: these hulls are darts and knives, and no
square fits a ship three times longer than it is wide. Sized to the nose it
floats the flanks eleven pixels off every wall; sized to the flanks it buries
the nose. The original never had this problem because its ships were drawn
compact enough to fill a square, and ours are deliberately not.

So a hull's footprint is three numbers: reach past the nose, behind the tail,
and to either side. Together they must occupy exactly 625 square pixels. Shape
spends that fixed target budget instead of granting one hull less target than
another.

| px | Apex | Wedge | Chord | Anvil | Cipher | Facet | Lattice |
|---|---|---|---|---|---|---|---|
| nose | 20 | 11 | 9 | 13 | 21 | 13 | 13 |
| tail | 11.25 | 9 | 7 | 12 | 18.0625 | 12 | 12 |
| side | 10 | 15.625 | 19.53125 | 12.5 | 8 | 12.5 | 12.5 |

The collision box follows the heading. Against a wall the simulation uses the
world-axis bounds of the hull as oriented that tick, so a ship touches where
it is drawn touching, whichever way it points, and an Apex flying diagonally
genuinely needs more room than one flying straight: a gap you must straighten
up to thread is correct physics and a skill element, not an artifact. Turning
against a wall levers the ship gently off it; in a slot exactly your own
width, the turn is refused, because you cannot spin a 40-pixel dart in a
40-pixel gap. Weapons and pickups test the oriented rectangle itself rather
than a box around it.

That last part is the balance consequence worth saying out loud. Every hull
occupies 625 square pixels, but it presents those pixels differently. Cipher
is 16 pixels across nose-on and just over 39 broadside. Chord is the inverse.
The square hulls present about 25 pixels from either direction. Facing still
matters without changing how much target any hull receives.

The ceiling is a diagonal: no hull's nose-corner reach, the square root of
nose squared plus side squared, may pass 23 pixels. That is the number all
three shipped maps were flood-filled and spawn-checked against, so holding it
means every room stays reachable, every spawn stays safe, and a full rotation
fits a three-tile corridor, for every hull, on any map drawn to the same
promise. It is why each box sits about a pixel inside its drawing rather than
flush: a pixel of art crossing a wall at the moment of contact is invisible,
and it buys the diagonal back.

`client/tests/hull_fit_test.lua` reads the extents out of `sim/src/baseline.c`
and measures every face of the client's hulls against them, so the two cannot
drift apart again, and the sim's own tests hold the diagonal ceiling.

The client draws a hull as a solid: a deck lofted over that plan and a nearly
flat keel under it, turning about its own nose-to-tail axis when the pilot
banks. None of that touches any number above. The loft moves no part of the
drawing sideways, so the plan in this section is the plan on the screen, and
`client/tests/hull3d_test.lua` measures every vertex of every solid against the
same boxes. See [decision 58](../architecture/decisions.md).

## What each ship is for

Every hull flies alike, climbs alike and holds alike. What differs is the
rectangle it puts between a bullet and the pilot, and because weapons test the
oriented rectangle, that rectangle is a real number in a real fight. All seven
rectangles have the same area. Their aspect ratios decide which heading makes
each one easier to hit.

So the roles below are read off the shapes rather than off a settings table.
They are how the hull plays, not what it is issued.

**Apex** is a dart with a 31.25 by 20 footprint. Nose-on it is smaller than it
is broadside, but the difference is moderate enough that a turn does not
transform it completely.

**Wedge** mirrors the Apex at 20 by 31.25. Coming nose-first presents the broad
face. Turning across the fight presents the short edge.

**Chord** is the widest hull at just over 39 pixels, but only 16 pixels long.
It makes the strongest trade in the roster between a broad nose-on target and
a thin broadside target.

**Anvil** is the even one. Its 25 by 25 footprint has no especially good angle
and no especially bad one.

**Cipher** is the knife and the Chord's inverse: just over 39 pixels long and
16 wide. It is the smallest nose-on target and the largest broadside target.

**Facet** uses the same square footprint as Anvil. The pentagonal silhouette
makes it read differently without giving it less target area.

**Lattice** is also square. Its open truss changes the silhouette, while its
collision footprint remains the same 625 square pixels as every other hull.

## The tech tree

It is not the roster's. Every hull may hold everything the arena has, to the
same depth, and what a pilot flies is what they chose to spend thirty points on
plus what their account has bought. The matrix is in
[weapons.md](weapons.md#the-tech-tree) and the ceilings are one row in
`sim_settings::kit_ceiling`.

This is a change, and it is the reason the sections above no longer talk about
bomb racks and barrel counts. A row per hull said which add-ons that hull could
hold and how deep: shrapnel to three on the bombers, multifire to two on the
spread hulls, six mines on the denial hull, a second barrel on the brawler
alone, a third bomb rung on the heavy alone. Four of those were the whole of
what made those hulls what they were, and all four had the same defect. A shop
cannot sell a trait that exists on one hull, so none of them could ever be
bought; and a pilot who bought a rung anyway would find the hull they wanted to
fly it on refused it.

They are slots now, on the same shelf as everything else. What was the
brawler's barrel is one rung of gun spray, which anybody may buy five of: it
was an add-on of its own for a while, and then it and multifire turned out to
be two ladders that both meant more bullets.
What was the heavy's third bomb rung is a rung on a ladder every hull climbs.
Six mines is what the arena allows anyone willing to spend a fifth of their kit
on mines, and a kit carries two kinds of charge at once, so fitting them means
taking a repel or a burst off. See
[match-game.md](match-game.md#two-charges-and-which-two-is-the-choice).

## Design rules that hold across the roster

No ship is good at everything, and every ship beats something. That used to be
a claim about stat blocks and is now a claim about geometry: a hull with a thin
side has a fat front, and a hull with no bad angle has no good one either. A
player who loses to a shape should be able to say which way to have been
pointing.

Every class is identifiable by silhouette alone at radar scale. Shape carries
class and color carries team, per [identity.md](identity.md). This matters more
than it did: the silhouette is no longer a label for a stat block, it is the
stat block.

A hull's detail earns its place by saying something the silhouette cannot. The
canopy says which end is the front. A hardpoint is drawn where a weapon
actually leaves the ship. Panel lines say a ship is built out of parts.
Anything that is decoration alone belongs on a hull that needs one of those
three things instead.

A hardpoint is not a claim about what the ship carries. The brawler is drawn
with two barrels out past the nose because that is the shape it has always
had; whether it fires two rounds is a question about the pilot's kit, and any
hull that buys a rung of spray fires two.

Nothing is exclusive to a hull. Not an add-on, not a rung, not a charge kind.
A trait one hull has is a trait the shop cannot sell and a pilot cannot choose,
which was true of four of them until it was fixed. If a role seems to need
exclusivity, the role is asking to be a purchase.

Ship performance comes from settings, never from code. If a class needs a
mechanic the settings cannot express, either the settings are missing something
or the class is wrong.

## Open questions

Whether a shape is enough. Seven silhouettes with identical engines is a
thinner roster than seven stat blocks, and the bet is that a hitbox you can
see and turn is a more legible difference than a rotation number you cannot.
If it turns out not to be, the answer is more shape rather than a stat table
coming back: extents that vary more, or something a shape can express that a
number cannot.

Whether gunners earn their place is answered, and the answer is no. It was
built, every hull carried five, and a playtest settled it the way this
document said a playtest would: [match-game.md](match-game.md) makes every
game a 4v4, and two pilots on one hull is a quarter of a side parked. The
code, the `ATTACH` message and `gunners.md` are all gone.

Whether seven is right for launch. Six ships done well beats eight done
carelessly, and the roster can grow after the game is good.
