# Ships

Seven hulls, and a hull is how you fly: its shape, its speed, its thrust, its
turn, its energy and its recharge. That is the whole of it.

What leaves the ship is not the hull's. There is one gun in this game and one
bomb, the same two whichever body is carrying them, and what is bolted to them
is the pilot's: seven build credits over the core's flat slot space, at one
credit a step. Every pilot arrives on the same spend and moves it wherever
they like, in any hull. Nothing is bought and nothing is owned, so there is no
shelf, no wallet and no ceiling but the slot's own. See
[decision 100](../architecture/decisions.md).

There is no ship page anywhere but the landing. Its ship stop is the roster and
the editor at once: one hull at a time, paged left and right, with its flight
against the rest of the roster and the rows that spend its credits under it.

The role names are what a hull is for, and they are load bearing again. A dart
and a slab play differently because they fly differently, not only because
they present a different rectangle.

Support was the eighth, and the Spire carried it. It is gone: see
[decisions.md](../architecture/decisions.md). The role is not disowned, it is
unbuilt, and the archetype list is the shorter for it rather than pretending
one of the seven covers it.

Names follow one family: hard geometric and architectural words, one or two
syllables, no animals and no aircraft. They read cleanly in a kill message and
at radar scale, which is where most ship names actually get used.

## The roster

| Class | Reads as | For |
|---|---|---|
| **Apex** | A swept dart, wings back far enough to clear its own engines | The fighter. Second fastest, and nothing about it is a weakness. |
| **Wedge** | A wide delta with a lit bomb bay down the spine | Deep pool, poor turn, and the broadest face coming at you. |
| **Chord** | A shallow bow with a sensor housing at the middle | Turns inside everything and outruns nothing. |
| **Anvil** | A blunt slab with two tubes on a flat bow face | The heavy. Slowest here, and the deepest bar in the game. |
| **Cipher** | A knife, and the only hull that draws dim | The fastest, thinnest thing in the game, on the smallest pool. |
| **Facet** | A squat pentagon with two barrels out past the nose | Quick and handy, with nothing at the top of any row. |
| **Lattice** | A trussed cross with dispensers at the arm tips | Steady and roomy: a bar to spend and the turn to use it. |

## Flight

One row a hull, in the settings file's own units.

| Class | Speed | Thrust | Rotation | Energy | Recharge |
|---|---:|---:|---:|---:|---:|
| Apex | 3332 | 205 | 248 | 1175 | 759 |
| Wedge | 2358 | 155 | 209 | 1525 | 589 |
| Chord | 2219 | 215 | 265 | 1219 | 824 |
| Anvil | 2010 | 145 | 200 | 1700 | 560 |
| Cipher | 3750 | 200 | 235 | 1000 | 1000 |
| Facet | 2567 | 175 | 261 | 1131 | 857 |
| Lattice | 2636 | 165 | 239 | 1394 | 628 |

Speed is tenths of a pixel a second, so the Cipher runs at 375 and the Anvil
at 201. Thrust is tenths of the settings unit. Rotation counts 400 to a full
turn a second, so the Chord comes round in a little over a second and a half
and the Anvil takes two. Recharge is energy a second times ten.

Four of those five columns are bounded, and the bounds are the original's own.
The Alpha Zone settings are eight ships climbing one ladder, so the span
between what a ship arrives with and what a fully greened one reaches is the
whole of what anybody ever flew there: speed 2010 to 3750, rotation 200 to
300, energy 1000 to 1700, recharge 400 to 1150. Ours are seven hulls that do
not climb, so those become the edges of the roster instead, held by
`sim_class_clamp` wherever a row is written, a zone file included. Thrust is
unbounded: the original runs 15 to 19 across every ship and every upgrade,
which is narrower than this roster wants.

The rows above were carried onto those bands by a straight linear rescale, so
each column keeps its order and its spacing and only its scale changed, and
then three of them were corrected for what that cost. The rescale is not a
neutral operation: it narrows the energy spread an eighth and widens the
recharge spread a third, which moves weight onto the refill, and holding speed
inside the original's band slows the whole roster by a sixth, which raises the
price of turning. Both showed up in the measurement. See Balance below for
what they cost and what came off the Anvil, the Chord and the Cipher to pay
for it.

The last two columns run against each other, and that is the roster's own
trade. A deep bar refills slowly and a shallow one refills fast: the Anvil
takes thirty seconds to fill and the Cipher ten, so the heavy wins the
long fight and is slow to be ready for the next, and the knife loses any fight
it stays in and is whole again almost at once. It is also the one thing here
that makes speed worth having, since a fast refill only pays to a hull that
can break contact. The two ran the same way round until `calibrate bodies`
measured what that did; see Balance below. The mapping is
in [simulation-core.md](../architecture/simulation-core.md) and lives in
`sim_units_*` and nowhere else.

Nothing on this row climbs. Every hull's floor is its ceiling and its step is
zero, so a stat slot in the build below would buy nothing. The slots stay in
the space because a zone is free to write a hull that climbs; the shipped
roster does not.

A table like this one stood here for a long time as an intention nobody had
implemented, then was deleted on the argument that uniform flight is what makes
a thirty point kit a fair trade. That argument was sound while the kit existed.
It does not survive the kit, which is exactly the condition
[decision 50](../architecture/decisions.md) named for reopening it.

## Weapons

One gun and one bomb, and every hull fires both. A hull is a flight row and a
footprint; nothing about what leaves it is written on it, so a Cipher throws
the bomb an Anvil throws and what separates them is how fast it arrives.

That is the original's arrangement too. All eight of its ships carry identical
weapon numbers, and what its per-ship section actually says is how a ship
flies: a Warbird's bullet is a Javelin's bullet. So the numbers below are its
numbers, and so is every step of the ladder.

Each weapon is a ladder of three. Rung one is what a pilot arrives on and the
two above it cost a credit each, out of the same seven that pay for everything
else. `SIM_MAX_RUNGS` is four, so the fourth stays free for a zone that wants a
weapon climbing further than this one does.

| Rung | Gun damage | Gun energy | Gun delay | Bomb damage | Blast | Bomb energy | Bomb delay |
|---|---:|---:|---:|---:|---:|---:|---:|
| 1 | 200 | 20 | 25 | 750 | 80 | 300 | 150 |
| 2 | 300 | 40 | 25 | 750 | 160 | 350 | 150 |
| 3 | 400 | 60 | 25 | 750 | 240 | 400 | 150 |

Read across: `BulletDamageLevel` is 200 and a level adds 100. `BulletFireEnergy`
is 20 times the level, so a harder bullet asks for more of the same bar it is
trying to take from its target. `BulletFireDelay` is 25 whatever the level, so
a rung is a heavier round and never a second gun. `BombDamageLevel` is 750 at
every level, which is why what a bomb rung sells is reach:
`BombExplodePixels` is 80, doubled at level two and tripled at level three.
`BombFireEnergy` is 300 and a level adds 50. `BombFireDelay` is 150 throughout.

The gun row is one round. What a pull actually throws is that times the
pilot's spray, and the extra rounds cost energy and cooldown on top, at the
original's own rate: a spray of three costs half again the energy and twice the
wait, which is `MultiFireEnergy` 30 against 20 and `MultiFireDelay` 50 against
25, read per round so the ladder above three keeps climbing at the same rate.

The tripled blast at the top is wide enough that the thrower is inside it. A
blast damages the pilot who threw it at full strength and everybody else at
half, which is the rule that makes a bomb a thrown weapon rather than a bigger
bullet, so a level-three bomb is a decision about where you are standing.

The row counts from one where the slot counts from zero, and the two are
saying different things. A slot counts credits spent, so nothing spent is a
nought, which is right for every other row on the page: no shrapnel, no
bounce, no repel. A rung is a place on a ladder the pilot is already standing
on, and a gun nobody has paid for still fires. The row read 0 for a while and
said the ship was unarmed.

## The build

Seven credits over the flat slot space, one credit a step, and the same
ceilings for everybody. What a pilot arrives on:

| Slot | Count | What it is |
|---|---:|---|
| Gun level | 2 | the second rung |
| Bomb level | 2 | and the bomb's |
| Gun bounce | 1 | rounds that come off a wall |
| Bomb proximity | 1 | a fuse, so a near miss counts |
| Bomb shrapnel | 1 | two fragments off the blast |
| Repel | 1 | one, to get out with |
| Burst | 1 | and one to answer a corner |

Seven, which is all of them, so a pilot who wants something else trades for it
rather than finding a spare. It is one row and every hull deals it, which is
what "the loadout is separate from the body" means where a pilot has not said
anything yet. `sim/src/baseline.c` writes it, the settings carry it, and
`client/arena/menu.lua` reads it back off the core rather than keeping a copy.

The ceilings are the arena's, in `fill_slot_caps`, and they are the whole of
the balance lever: every step costs the same, so a slot that turns out too
strong cannot be made dearer and has to be made shallower. Spray climbs to
five rounds abreast, shrapnel to three rungs, both racks to three. A fuse and
shrapnel are the bomb's; spray is the gun's. A proximity fuse on a gun does not
need to hit and a bouncing round fills a room, which is what `calibrate builds`
found and why neither is offered.

Spray is a count of rounds, so "spray 2" is two rounds abreast and everything
else is a depth. Two rounds sit two and a quarter degrees apart, tight enough
to land together out to three hundred pixels; three and up open to the zone's
fan. What each add-on does is in [weapons.md](weapons.md).

Two kinds of charge is the ceiling and nothing carries three, because two is
what a keyboard has room for. Which key throws which is the pilot's, and it is
a preference about a keyboard rather than a fact about a ship, so it sits with
the wake.

The whole thing is three tables in `sim/src/baseline.c`: flight, the footprint,
and the two ladders. A zone overrides flight per hull in its own `zone.toml`
and tunes a weapon by name for the whole room. The melee zone deliberately
overrides neither: a game that means one thing in one room and something else
in another is a game nobody can learn.

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
nose squared plus side squared, may pass 23 pixels. That is the number all six
shipped maps were flood-filled and spawn-checked against, so holding it means
every room stays reachable, every spawn stays safe, and a full rotation fits a
three-tile corridor, for every hull, on any map drawn to the same promise. It
is why each box sits about a pixel inside its drawing rather than flush: a
pixel of art crossing a wall at the moment of contact is invisible, and it
buys the diagonal back.

`client/tests/hull_fit_test.lua` reads the extents out of `sim/src/baseline.c`
and measures every face of the client's hulls against them, so the two cannot
drift apart again, and the sim's own tests hold the diagonal ceiling.

## What each ship is for

A hull is a flight row, so these are claims about flight. What any of them
throws is whatever its pilot bought, and the same seven credits are available
in all of them.

**Apex** is the fighter, and the ship most players should be flying while they
work out what they like. Second fastest, a middling bar, and a turn that keeps
up with everything except the Chord. Nothing about it is the best in the roster
and nothing about it is a weakness.

**Wedge** is slow, turns badly, and carries the second deepest bar in the game.
What it is for is arriving somewhere and staying there. It is also the broadest
face in the roster coming at you, which is the argument against charging with
it and the reason its pool has to be what it is.

**Chord** turns inside everything and outruns nothing. Slowest hull in the
game, best rotation by a wide margin, and the fastest recharge. It wins the
fight it can keep in a circle and loses any fight that can leave.

**Anvil** wins any fight it is allowed to have: the deepest bar in the roster
by a fifth, and the slowest refill in it by as much, so what it does not win
it spends a long time recovering from. It is also the slowest thing here with
the worst turn, so the whole question is whether it gets to have the fight.

It had that bar and the fastest refill both, for a while, which made it the
one ship in the game nothing paid for. It took 60% of its seats in a team
match and 80% of a duel at mid skill.

**Cipher** is the fastest and thinnest ship in the game. Nose-on it is 16
pixels of target; broadside it is the largest in the roster. Its pool is the
smallest and its refill the quickest, nine seconds against the Anvil's
twenty-four, so it cannot afford a fight it did not choose and is whole again
almost as soon as it leaves one. The thing it is best at is choosing, and the
refill is what pays it for choosing well.

It flew on 1300 energy once before, with a gun of its own that cost 60 a pull:
it drew dry in twenty-one rounds and recharged slower than its own trigger,
which on a map with nowhere to run left it beating nothing at all. The gun is
everybody's now and an opening shot costs 20, so the same bar is a different
ship.

**Facet** is quick, handy, and at the top of no row at all. It is the hull with
no excuse: whatever it loses to, it did not lose to the ship.

**Lattice** has a bar to spend and the turn to use it, on a frame that is
neither fast nor slow. It is the hull that can afford to be somewhere
uncomfortable for a while.

## Design rules that hold across the roster

No ship is good at everything, and every ship beats something. The Cipher
outruns the Anvil and dies to anything that corners it. The Chord turns inside
the Apex and cannot leave. A player who loses should be able to say what they
lost to.

Every class is identifiable by silhouette alone at radar scale. Shape carries
class and color carries team, per [identity.md](identity.md). A silhouette is
a stat block again now, which raises the stakes on the drawing rather than
lowering them.

A hull's detail earns its place by saying something the silhouette cannot. The
canopy says which end is the front. A hardpoint is drawn where a weapon
actually leaves the ship. Panel lines say a ship is built out of parts.
Anything that is decoration alone belongs on a hull that needs one of those
three things instead.

A hardpoint is a claim about the game rather than about one ship. Every hull
fires the same gun and throws the same bomb, so every hull is drawn with
somewhere for both to leave from: the Facet's two barrels are where its rounds
appear, the Wedge's lit bay is where its bombs do. What a drawing may not do is
promise a weapon this game does not have.

Exclusivity is allowed, and it lives in the flight row: the Cipher's speed, the
Anvil's bar, the Chord's turn. No pilot can buy any of them, because a body is
picked rather than bought. What is not allowed is a hull that is another hull
with a number moved.

Ship performance comes from settings, never from code. If a class needs a
mechanic the settings cannot express, either the settings are missing something
or the class is wrong.

## Balance

`cargo run --manifest-path server/Cargo.toml -- calibrate hulls` flies the
roster against itself on the arrival build and reports the matrix, which with
the weapons off the hulls is a measurement of flight alone. That is one of the
two balance questions: a roster balanced hull against hull can still have one
slot
everybody dumps into.

### The ceilings

What a pilot may take of each slot, which is the roster's design space written
down and the only balance lever a flat price list leaves.

| Slot | Gun | Bomb |
|---|---:|---:|
| rung | 2 | 2 |
| spray | 5 | 0 |
| bounce | 1 | 1 |
| proximity | 0 | 1 |
| shrapnel | 0 | 3 |
| freeze | 1 | 1 |
| push | 0 | 0 |

The rung ceiling is not a number anybody set: `sim_slot_cap` floors the level
slot at the length of the ladder itself, so three rungs answers two and a
trigger a zone leaves empty answers zero without any hull being named. That is
also how the row went missing for a while. Every line that drew it was right,
and the roster underneath named one rung a weapon, so the ceiling came back
zero and the panel correctly drew nothing.

The rack: three of each, which is `RepelMax` and `BurstMax` on all eight of the
original's ships. Flight keeps its full ladder, since its step is zero across
the shipped roster and a stat slot buys nothing anyway.

Two of those zeroes were measured rather than assumed. Seven of one charge beat
everything else on every hull, because a rack answered to the budget and
nothing else; and an add-on that belongs on a bomb wins outright on a gun,
since rounds with a proximity fuse do not have to hit and rounds that bounce
fill a room. A step cannot be made dearer, so the answer to both is a shallower
slot.

Where a ceiling is zero the slot is not a slot: no row is drawn for it and a
build naming it is fitted down. A zone that wants one raises it, and the
ceiling travels with the settings, so a client never draws a key the arena
would refuse.

`calibrate builds` asks the second. It flies every runaway shape, every credit
in one slot and the arrival build with one credit moved, in a mirror so the
only difference in the room is how the credits went. A build that beats its own hull's row well past even is one the
roster would converge on, and since a step cannot be made expensive the answer
is a lower ceiling or a weaker step. `sim_slot_cap` is where a ceiling lives.

Where the ceilings above left it, at forty bouts a build on the pit, with the
weapon rungs in. The median column is the one to read: it is what an ordinary
re-spend does against the hull's own row, so a hull near even is a hull whose
credits are already well spent.

| hull | ships | builds past 65% | median |
|---|---:|---:|---:|
| Anvil | 3/7 | 6 of 32 | 49% |
| Cipher | 3/7 | 2 of 29 | 38% |
| Apex | 4/7 | 8 of 32 | 52% |
| Wedge | 5/7 | 8 of 31 | 48% |
| Chord | 6/7 | 3 of 30 | 21% |
| Facet | 7/7 | 13 of 30 | 52% |
| Lattice | 7/7 | 4 of 28 | 44% |

The hulls that ship with credits in hand are meant to sit high here: an Anvil
holds four and spending them is supposed to be worth something. The Chord is
the other end, and it is the roster working: a hull spent to six credits on
the things it wants has little left to gain by moving them.

Two rungs a weapon added 26 shapes to that space and did not make it more
runaway-prone: 44 of 212 past 65% against 40 of 186 before them, which is the
same fifth of the space either way.

What a slot is worth is a harder question than the sweep can answer, and the
table below is as far as it goes. Every row is one candidate: every credit
dumped into that slot and the rest of the budget wasted. So a slot capped at
one is measured on a build spending one credit of seven, and a hull that has
thrown its budget away is most of what the number describes.

Which is why the flight stats belong in it. Their step is zero, so seven
credits there buy nothing at all and the row is a stripped hull: 23.2 on the
pit, 38.0 on Gantry. That is the floor, and the only scale on which two rooms
with different draw rates can be compared, so the columns below are points
above it.

| slot | pit | Gantry |
|---|---:|---:|
| gun bounce | +34.7 | +7.0 |
| burst | +30.9 | +6.8 |
| gun freeze | +30.8 | +12.1 |
| gun rung | +23.1 | +8.0 |
| gun spray | +9.3 | +8.8 |
| bomb rung | +7.2 | +2.2 |
| bomb bounce | +3.1 | +2.7 |
| bomb shrapnel | +2.5 | +1.8 |
| bomb freeze | +0.2 | +1.3 |
| repel | -0.7 | -0.7 |
| bomb proximity | -2.3 | +2.3 |

Read the two columns against each other rather than either alone, because
they disagree about almost everything. Gun bounce is the strongest slot in
the game on the pit and fourth on a real map; the burst falls the same way.
On Gantry the five gun slots land inside six points of one another, which is
a roster with no dominant slot rather than a ranking. The pit is one box a
pilot can see across, so it pays for closing and charges nothing for being
slow, and every close-quarters good is worth more there than it will ever be
worth in a game. A ranking off the pit is a fact about the pit.

The rungs come out of that unremarkable, which is what they were checked
for. A gun rung is third of the four gun slots in both rooms, inside the
band each time. A bomb rung leads the bomb slots by four points on the pit
and is third of five on Gantry, where the whole group sits within a point
and a half of itself. The one tall reading, the Wedge at 95 on a doubled
gun, was the pit talking: the same build is 66.2 on Gantry.

None of this is a significance test, and forty bouts a build is not close to
being one. `experiment.rs` is where this repository does inference properly,
at alpha 0.05 and power 0.90 with the effect named in advance; a build sweep
is the exploratory tier under it. At forty bouts the Wilson interval on an
even build is plus or minus 14.8, so the 65% line the sweep flags at falls
inside the noise, and screening 212 builds against it turns up about nine by
luck alone. Gantry found nine. Resolving a ten point gap between two
slots at power 0.90 would take 524 bouts a build, so the ordering inside
either column above is not evidence of anything.

What the sweep does answer is the question it was built for: whether some
shape runs away with it. Two rungs a weapon added 26 shapes and did not.

Run the hull tournament on both rooms. The pit is one box a pilot can see
across, which flatters everything that wants to be close and charges nothing
for being slow; the arena has cover and somewhere to run to. A hull whose
weakness is written down as "slow" or "must choose its fights" only pays for
it on the second, and a number from one room alone is a fact about that room.

`calibrate builds` needs a third room and the arena is not it. A build sweep
is a mirror, so two identical hulls at one skill use the arena's cover to not
die: 4223 of 4240 bouts drew there, every rate collapsed onto the half point
a draw scores, and the run still printed that nothing ran away with it. Read
its draw count before believing a flat table. A map off `mapforge generate`
is the room to use instead, since it is one the game is actually played on,
though Gantry still draws 71% of a mirror and a draw carries no information.
Everything a build sweep says is worth less than its draw count suggests.
Read the draw count before believing a flat table.

Where the roster stands, off `calibrate bodies`. Two runs of 99,600 seats
each, one against the flight table that came out of decision 121 and one
against the table that replaced it, at 1,200 swapped pairs a stratum in the
team arm and 3,500 in the duel.

The first run found the roster eight to thirteen points wide at the Anvil and
five to nine under at the Cipher, at every skill and in both formats. Fitting
win rate against energy and recharge over those seats explained 94% of the
spread and priced the two columns: a hundred energy is worth 1.7 win points in
a team match and a hundred recharge 2.7.

What that fit found was not a spread that was too wide. It was two columns
running the same way round. The Anvil held the deepest bar in the game and
nearly the fastest refill at once, so nothing paid for the bar, and what was
supposed to pay for it, being slow, pays nothing at all: speed correlates
**negatively** with winning here, at -0.75 in the team arm. Solving each body
onto the fit's line left the energy spread exactly where the roster put it and
moved three rows, none of them the four already inside the margin.

Team arm, win rate before and after, by skill:

| body | low | mid | high |
|---|---|---|---|
| Apex | 48.2 → 48.0 | 50.8 → 49.0 | 49.4 → 49.9 |
| Wedge | 51.4 → 51.5 | 51.6 → 52.6 | 50.5 → 51.1 |
| Chord | 48.0 → 47.7 | 49.6 → 49.8 | 54.8 → **55.1** |
| Anvil | **59.7** → 48.0 | **62.9** → 49.8 | **58.2** → 49.8 |
| Cipher | **45.5** → 52.7 | **40.9** → 50.4 | **40.7** → **45.2** |
| Facet | **46.7** → 51.9 | **44.9** → 48.9 | **45.7** → 49.8 |
| Lattice | 50.7 → 50.1 | 49.5 → 49.6 | 50.5 → 49.1 |

Bold is outside the five-point margin, tested as equivalence with the family
Holm-adjusted across the seven. Nineteen of the twenty-one cells certify,
against eleven before. At mid skill the whole roster sits between 48.9 and
52.6 and its k/d spread has closed from 0.80 to 1.54 down to 0.93 to 1.09.

**Two cells still miss, and both only at high skill.** The Chord is five points
over and the Cipher five under. Neither should be chased with these two
columns, and the shape of the miss is why: the Cipher reads 52.7, 50.4, 45.2
across the strata and the Chord 47.7, 49.8, 55.1, so both are sloped against
skill while energy and recharge are flat across it. Buying five points at high
would spend two certified cells to gain one. What is left is about what a good
pilot does with the best turn in the game and with the fastest hull, which
lives in the columns this correction deliberately did not touch.

The duel arm went from six certified cells to eleven, and is the honest limit
on all of this. The Anvil's 80.6% at mid skill came down to 50.3, and the
Facet certified at every skill, but the Cipher overshot to 62.6% at mid and
the Chord sits at 36.7% there, before and after, untouched. That was expected
and accepted rather than discovered: the pit's fitted coefficients are nearly
twice the team arm's, because a room where a pilot can never break contact
turns a fast refill into flat extra life, where a room they can leave makes it
conditional on leaving. The correction was solved on the team arm on purpose,
melee being the mode that ships. A table that balances both rooms is probably
not reachable from two columns.

## Open questions

Whether seven distinct ships is more roster than we can keep balanced. The
measurement above says not yet: three of the seven certify and two are a long
way out. It is a harder problem than seven silhouettes on one flight row, and
the bet is that a game where the ships are actually different is worth the
work. The harness exists so the answer is measured rather than argued, and it
now has an answer to argue with.

Whether five rounds abreast is worth what it costs. The sweep found the spray
ladder's top the most re-spent thing on the shelf: every build that beat a
five-round one dropped it to three and put the two credits somewhere else.
That was measured while spray was a hull's trait and the Facet was the hull
wearing it; as a slot every pilot can reach it is one more question for
`calibrate builds` rather than an argument about a ship.

Whether a hull with no weapon of its own is still seven ships. Flight is a
real difference and the tournament measures it, but a roster whose members
differ by a fifth of a bar and a tenth of a turn is a thinner roster than one
where the Anvil had its own cannon. If it turns out nobody can tell the seven
apart in a fight, the answer is a wider flight spread rather than putting the
weapons back on the hulls.

Whether the Lattice is a ship or a job. A deep bar and a good turn on a hull
that is fast at nothing is a support role wearing a fighter's chassis, which
is the thing the Spire was cut for being. If it turns out nobody wants to fly
it, the answer is to give it a way to finish what it starts, not to hand its
charges to somebody else.

Whether seven is right for launch. Six ships done well beats eight done
carelessly, and the roster can grow after the game is good.
