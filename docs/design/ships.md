# Ships

Seven hulls, and a hull is a whole ship. Its shape, its speed, its thrust, its
turn, its energy and its recharge; the gun it fires and the bomb it throws;
what those weapons carry and what it has in the rack. All of it belongs to the
hull, and a pilot picks one.

What the hull owns is the shape and the flight. What it carries is a pilot's:
seven build credits over the core's flat slot space, at one credit a step, and
each hull's profile below is its default spend. Nothing is bought and nothing
is owned, so there is no shelf, no wallet and no ceiling but the slot's own;
what a pilot changes is which weapons and which rack their seven credits sit
on. See [decision 100](../architecture/decisions.md).

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
| **Apex** | A swept dart, wings back far enough to clear its own engines | The fighter. Fast, paired heavy rounds, a way out. |
| **Wedge** | A wide delta with a lit bomb bay down the spine | The bomber. A fuse, a wide blast, and fragments. |
| **Chord** | A shallow bow with a sensor housing at the middle | Turns inside everything. Light rounds that freeze. |
| **Anvil** | A blunt slab with two tubes on a flat bow face | The heavy. Wins any fight it is allowed to have. |
| **Cipher** | A knife, and the only hull that draws dim | The fastest, thinnest thing in the game, with no rack. |
| **Facet** | A squat pentagon with two barrels out past the nose | Five rounds abreast, bouncing. A room at short range. |
| **Lattice** | A trussed cross with dispensers at the arm tips | Does not kill you, moves you. The deepest rack. |

## Flight

One row a hull, in the settings file's own units.

| Class | Speed | Thrust | Rotation | Energy | Recharge |
|---|---:|---:|---:|---:|---:|
| Apex | 3600 | 205 | 250 | 1500 | 1150 |
| Wedge | 2900 | 155 | 205 | 1900 | 1020 |
| Chord | 2800 | 215 | 310 | 1550 | 1200 |
| Anvil | 2650 | 145 | 195 | 2100 | 1250 |
| Cipher | 3900 | 200 | 235 | 1400 | 1100 |
| Facet | 3050 | 175 | 265 | 1400 | 1100 |
| Lattice | 3100 | 165 | 240 | 1750 | 1050 |

Speed is tenths of a pixel a second, so the Cipher runs at 390 and the Anvil
at 265. Thrust is tenths of the settings unit. Rotation counts 400 to a full
turn a second, so the Chord comes round in a little over a second and a quarter
and the Anvil takes two. Recharge is energy a second times ten. The mapping is
in [simulation-core.md](../architecture/simulation-core.md) and lives in
`sim_units_*` and nowhere else.

Nothing on this row climbs. Every hull's floor is its ceiling and its step is
zero, so a stat slot in the profile below would buy nothing. The slots stay in
the space because a zone is free to write a hull that climbs; the shipped
roster does not.

A table like this one stood here for a long time as an intention nobody had
implemented, then was deleted on the argument that uniform flight is what makes
a thirty point kit a fair trade. That argument was sound while the kit existed.
It does not survive the kit, which is exactly the condition
[decision 50](../architecture/decisions.md) named for reopening it.

## Weapons

Each hull fires its own gun and throws its own bomb, and each of those is a
ladder of three. The row below is rung zero, the weapon a hull arrives with,
and a pilot's credits buy the two rungs above it: one credit a rung, out of
the same seven that pay for everything else. That is the original's own shape,
where a gun and a bomb each have three levels, and it is what the Rung row at
the top of each weapon section in the hangar spends on. `SIM_MAX_RUNGS` is
four, so the fourth stays free for a zone that wants a hull climbing further
than this roster does.

| Class | Gun damage | Energy | Delay | Bomb damage | Blast | Energy | Delay |
|---|---:|---:|---:|---:|---:|---:|---:|
| Apex | 320 | 40 | 25 | 750 | 80 | 300 | 150 |
| Wedge | 208 | 20 | 25 | 750 | 128 | 310 | 120 |
| Chord | 200 | 30 | 25 | 750 | 80 | 300 | 150 |
| Anvil | 465 | 90 | 45 | 750 | 160 | 400 | 200 |
| Cipher | 400 | 58 | 28 | none | | | |
| Facet | 300 | 40 | 25 | 750 | 80 | 300 | 150 |
| Lattice | 200 | 26 | 25 | 750 | 80 | 300 | 150 |

The gun row is one round. What a pull actually throws is that times the hull's
spray, and the extra rounds cost energy and cooldown on top, so the Facet's
five are dearer and slower than the Apex's two rather than free.

The damage numbers started as the original's ladder read as fixed points
rather than as rungs: it begins at 200 and adds 100 a level, so the roster was
laid out on 200, 300, 400 and 500. Balance has moved four of them off those
marks by a few percent, which is what a ladder read as fixed points is for.
The bomb is 750 at every level in the original, which is why every rack here
does the same damage and the blast radius is what separates them.

What a rung is worth follows from those two facts. A gun rung is half the
row's round again, on the damage and on the energy a pull costs alike, so the
three rungs are the row, half again, and double; the rate does not move, since
BulletFireDelay is one number in the original whatever the level and a rung
that fired faster as well as harder would be the gun bought twice. What that
sells is the size of one arriving hit rather than a discount, and it is why a
level is a trade and not a slot every hull dumps into.

A bomb rung adds forty pixels of blast, two and a half tiles, and half the
row's energy again. Added rather than multiplied, because this roster's own
racks already sit up the original's ladder: doubling and tripling would put
the Wedge's bay at twenty-four tiles and the Anvil's at thirty, with the
thrower inside their own blast the whole way. Forty a rung lands a plain rack
on 80, 120 and 160 and the Anvil's on 240, which is the original's L3 for a
bomb that starts where a bomb starts.

The Cipher has no rack at all. It is the only one, the core has always been
able to express it, and nothing until now used it.

## The profile

What each hull carries, over the flat slot space, and what its seven credits
are spent on before a pilot moves any of them. The rightmost column is the
sum, which is what a pilot has to re-spend.

| Class | Gun | Bomb | Charges | Credits |
|---|---|---|---|---:|
| Apex | spray 2 | plain | repel 2, burst 1 | 4 |
| Wedge | plain | prox, shrapnel 2 | repel 1, burst 1 | 5 |
| Chord | spray 3, freeze | prox | repel 2 | 6 |
| Anvil | plain | plain | repel 2, burst 1 | 3 |
| Cipher | plain | no rack | repel 1, burst 2 | 3 |
| Facet | spray 5, bounce | plain | repel 2 | 7 |
| Lattice | plain | bounce, freeze | repel 3, burst 2 | 7 |

Every one of them fits inside seven, which is where the budget came from: the
roster arrived on this number rather than being moved onto it, and
`the shipped roster spends no more than a pilot has` in
`sim/tests/test_sim.c` holds it there. The Anvil and the Cipher ship with four
credits in hand, so a pilot flying either starts by spending rather than by
trading something away.

A credit moves anywhere the hull can reach. An Anvil is three credits of ship
and four credits of whatever its pilot wants, and a Facet is spent to the last
one, so re-spending it means giving something up. That asymmetry is the roster
speaking rather than a rule: a hull that ships light is a hull with room in
it.

Spray is a count of rounds, so "spray 2" is two rounds abreast and everything
else is a depth. Two rounds sit two and a quarter degrees apart, tight enough
to land together out to three hundred pixels; three and up open to the zone's
fifteen. What each add-on does is in [weapons.md](weapons.md).

Two kinds of charge is the ceiling and nothing carries three, because two is
what a keyboard has room for. Which key throws which is the pilot's, and it is
the one thing left on the ship page that a pilot decides; it is a preference
about a keyboard rather than a fact about a ship, so it sits with the wake.
`profiles_carry_two_kinds` holds the roster to the ceiling.

The whole thing is four tables in `sim/src/baseline.c`: flight, gun, bomb, and
the profile. A zone overrides any of them per hull in its own `zone.toml`. The
melee zone deliberately overrides none: a hull that means one thing in one game
and something else in another is a hull nobody can learn.

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

**Apex** is the fighter, and the ship most players should be flying while they
work out what they like. Second fastest, a pair of heavy rounds off one pull,
an ordinary bomb, and two repels to leave a fight it is losing. Nothing about
it is the best in the roster and nothing about it is a weakness.

**Wedge** is the bomber. It is slow and it turns badly, and what it has is the
widest rack anybody would want to be in front of: a fuse so a near miss counts,
an eight-tile blast, and two rungs of shrapnel, which is six fragments out of
every detonation carrying its own gun's damage. Its gun is chip while the rack
reloads. It is also the broadest face in the roster coming at you, which is the
argument against charging with it.

**Chord** turns inside everything and outruns nothing. Slowest hull, best
rotation by a wide margin, three light rounds that freeze what they hit, and a
fuse on the bomb so it need not be exact. Freezing a recharge is what makes it
dangerous: the Chord does not kill people, it stops them recharging while
somebody else does.

**Anvil** wins any fight it is allowed to have. One 465-damage round every 45
ticks, which is half again the hardest thing anybody else throws, the widest
bomb in the game at ten tiles, and the deepest energy pool. It is also the
slowest thing here with the worst turn, so the whole question is whether it
gets to have the fight.

**Cipher** is the fastest and thinnest ship in the game and the only one with
no bomb rack. Nose-on it is 16 pixels of target; broadside it is the largest
in the roster. Its gun is the whole of what it has and its pool is the
smallest, so it cannot afford a fight it did not choose. Two bursts are its
answer to being cornered.

Its pool and its gun's price are the tightest coupling in the roster and the
one the tournament found first: at 1300 energy and 60 a pull it drew dry in
twenty-one rounds and recharged slower than its own trigger, which on a map
with nowhere to run left it beating nothing at all.

**Facet** fires five rounds off two barrels, fanned fifteen degrees apart,
and they bounce. It is a shotgun. Point blank most of the fan lands on one
hull, and 1500 damage kills four of the seven outright; at any real distance
the rounds are a hull's width apart and one arrives. The bounce is what makes
it a room-clearer rather than a duelist: five bouncing rounds fill a corridor,
and it is the hull that wins one it cannot see down.

**Lattice** does not kill you, it moves you. The weakest gun in the roster, a
bomb that bounces once and freezes, and the deepest rack in the game: three
repels and two bursts. It is the hull that decides where a fight happens, and
it needs somebody else there to finish it.

It arrived with bouncing rounds on top of all that and won every single bout
of its first tournament. A bouncing gun on the hull that fires the most rounds
in the roster is a room where every miss keeps hunting, which is not area
denial, it is the best gun in the game wearing the worst gun's numbers.

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

A hardpoint is a claim about what the ship carries, and it has to be true. The
Facet is drawn with two barrels out past the nose and fires five rounds. The
Wedge has a lit bay down the spine and throws the second-widest bomb in the
game. The Cipher has no bay drawn on it and has no rack.

Exclusivity is allowed, and it is most of what a roster is. The Cipher's empty
rack, the Anvil's cannon, the Lattice's six charges: no other hull has these
and no pilot can buy them, because there is nothing to buy them with. What is
not allowed is a hull that is another hull with a number moved.

Ship performance comes from settings, never from code. If a class needs a
mechanic the settings cannot express, either the settings are missing something
or the class is wrong.

## Balance

`cargo run --manifest-path server/Cargo.toml -- calibrate hulls` flies the
roster against itself on its own profiles and reports the matrix. That is one
of the two balance questions, and with a pilot's credits back it is no longer
the only one: a roster balanced hull against hull can still have one slot
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
slot at the length of the hull's own ladder, so three rungs answers two and a
hull with no rack answers zero without the Cipher being named anywhere. That
is also how the row went missing for a while. Every line that drew it was
right, and the roster underneath named one rung a weapon, so the ceiling came
back zero on every hull and the panel correctly drew nothing.

The rack: three repels, two bursts, which keeps the Lattice the deepest rack
in the game. Flight keeps its full ladder, since its step is zero across the
shipped roster and a stat slot buys nothing anyway.

Two of those zeroes were measured rather than assumed. Seven of one charge
beat every hull's own row on every hull, because a rack answered to the budget
and nothing else; and an add-on that belongs on a bomb wins outright on a gun,
since rounds with a proximity fuse do not have to hit and rounds that bounce
fill a room the way the Lattice's did before its gun stopped bouncing. A step
cannot be made dearer, so the answer to both is a shallower slot.

Where a ceiling is zero the slot is not a slot: no row is drawn for it and a
profile naming it is fitted down. A zone that wants one raises it, and the
ceiling travels with the settings, so a client never draws a key the arena
would refuse.

`calibrate builds` asks the second. It flies every runaway shape, every credit
in one slot and the hull's own row with one credit moved, against the hull it
was spent on, in a mirror so the only difference in the room is how the
credits went. A build that beats its own hull's row well past even is one the
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

What the sweep says a slot is worth, as the mean over the seven hulls of
dumping every credit into it alone. The rows that ship are the yardstick a new
one is read against:

| slot | mean | dearest hull |
|---|---:|---:|
| gun bounce | 57.9 | 92.5 |
| burst | 54.1 | 87.5 |
| gun freeze | 53.9 | 87.5 |
| gun rung | 46.2 | 95.0 |
| gun spray | 32.5 | 85.0 |
| bomb rung | 30.4 | 47.5 |
| bomb bounce | 26.2 | 65.0 |
| bomb shrapnel | 25.7 | 52.5 |
| bomb freeze | 23.4 | 45.0 |
| bomb proximity | 20.9 | 41.2 |

So a gun rung is the fourth-strongest gun slot, under three that already
ship, and a bomb rung is the strongest of the bomb slots without leaving
their band. Its one tall reading, the Wedge at 95, is not separable from the
Apex's 92.5 on gun bounce: at forty bouts those are 95.0 plus or minus 6.8
and 92.5 plus or minus 8.2. The Wedge's own row also loses to gun bounce at
86 and gun freeze at 88, so what that column is measuring there is a hull
whose seven credits are badly spent rather than a slot that is too strong.

Run the hull tournament on both rooms. The pit is one box a pilot can see
across, which flatters everything that wants to be close and charges nothing
for being slow; the arena has cover and somewhere to run to. A hull whose
weakness is written down as "slow" or "must choose its fights" only pays for
it on the second, and a number from one room alone is a fact about that room.

`calibrate builds` is the exception, and it is a pit question only. It is a
mirror, so the arena's cover gives two identical hulls at one skill somewhere
to not die: 4223 of 4240 bouts drew there, every rate collapsed onto the half
point a draw scores, and the run still printed that nothing ran away with it.
Read the draw count before believing a flat table.

Where the shipped roster stands, mean of the two rooms at 24 bouts a pair:

| hull | win% | pit | arena |
|---|---:|---:|---:|
| Anvil | 54.6 | 51.0 | 58.3 |
| Lattice | 51.4 | 46.9 | 55.9 |
| Cipher | 51.2 | 52.8 | 49.7 |
| Wedge | 50.9 | 51.7 | 50.0 |
| Chord | 49.7 | 51.7 | 47.6 |
| Facet | 46.9 | 52.8 | 41.0 |
| Apex | 45.4 | 43.1 | 47.6 |

A row is 144 bouts and worth about eight points either way, so the order
inside that band is not meaningful and the band is. It opened at 28 to 90.

The largest single correction was not a hull. Melee charged a whole base
cooldown for every round past the first, which was written when spray was a
rung on a shelf and a cheaper price made it an upgrade nobody could decline.
Nobody buys spray now, so the same number was a tax on the three ships that
have barrels, and it put all three in the bottom three on both rooms.

## Open questions

Whether seven distinct ships is more roster than we can keep balanced. It is a
harder problem than seven silhouettes on one flight row, and the bet is that a
game where the ships are actually different is worth the work. The tournament
harness exists so the answer is measured rather than argued.

Whether the Facet's five rounds are worth what they cost it. The sweep says
its own row loses to re-spending its own credits more often than any other
hull's, and every build that beats it drops the spray to three and puts the
two credits somewhere else. The hull tournament had already put it second from
bottom. So the measurement is not that a slot is broken, it is that this
particular seven credits are badly spent, and the question is a design one:
five rounds abreast is what a Facet is, and a Facet that fires three is a
Chord that does not turn. Worth answering before the roster is called
balanced, and not worth answering by quietly editing the profile.

Whether the Lattice is a ship or a job. Three repels and three bursts on a hull
that cannot kill anybody is a support role wearing a fighter's chassis, which
is the thing the Spire was cut for being. If it turns out nobody wants to fly
it, the answer is to give it a way to finish what it starts, not to hand its
charges to somebody else.

Whether seven is right for launch. Six ships done well beats eight done
carelessly, and the roster can grow after the game is good.
