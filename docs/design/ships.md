# Ships

Seven hulls, and a hull is a whole ship. Its shape, its speed, its thrust, its
turn, its energy and its recharge; the gun it fires and the bomb it throws;
what those weapons carry and what it has in the rack. All of it belongs to the
hull, and a pilot picks one.

Nobody spends anything. There is no kit, no budget, no shelf and no wallet: the
menu's ship page is the roster with the seven read down a column, and pressing
one flies it. What used to stand there is in
[decisions.md](../architecture/decisions.md); the short version is that a
thirty point kit made every hull the same ship underneath, and the thing worth
choosing between was the ship.

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
| Apex | 3600 | 190 | 250 | 1500 | 1150 |
| Wedge | 2900 | 155 | 205 | 1900 | 1000 |
| Chord | 2800 | 215 | 310 | 1550 | 1200 |
| Anvil | 2650 | 145 | 195 | 2100 | 1300 |
| Cipher | 3900 | 200 | 235 | 1300 | 950 |
| Facet | 3050 | 175 | 265 | 1400 | 1100 |
| Lattice | 3100 | 165 | 240 | 1750 | 1250 |

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

Each hull fires its own gun and throws its own bomb. Both are one rung of a
ladder the core still has, so a zone may write a hull whose weapon climbs; the
shipped roster names rung zero for every one of them.

| Class | Gun damage | Energy | Delay | Bomb damage | Blast | Energy | Delay |
|---|---:|---:|---:|---:|---:|---:|---:|
| Apex | 300 | 40 | 25 | 750 | 80 | 300 | 150 |
| Wedge | 200 | 20 | 25 | 750 | 128 | 350 | 120 |
| Chord | 200 | 30 | 25 | 750 | 80 | 300 | 150 |
| Anvil | 500 | 90 | 45 | 750 | 160 | 400 | 200 |
| Cipher | 400 | 60 | 28 | none | | | |
| Facet | 300 | 40 | 25 | 750 | 80 | 300 | 150 |
| Lattice | 200 | 20 | 25 | 750 | 80 | 300 | 150 |

The gun row is one round. What a pull actually throws is that times the hull's
spray, and the extra rounds cost energy and cooldown on top, so the Facet's
five are dearer and slower than the Apex's two rather than free.

The damage numbers are the original's ladder read as fixed points rather than
as rungs: it starts at 200 and adds 100 a level, so 200, 300, 400 and 500 are
four hulls sitting at four places on one ladder. The bomb is 750 at every
level in the original, which is why every rack here does the same damage and
the blast radius is what separates them.

The Cipher has no rack at all. It is the only one, the core has always been
able to express it, and nothing until now used it.

## The profile

What each hull carries, over the same flat slot space the kit used to spend
points on. Nobody buys any of it.

| Class | Gun | Bomb | Charges |
|---|---|---|---|
| Apex | spray 2 | plain | repel 2, burst 1 |
| Wedge | plain | prox, shrapnel 2 | repel 1, burst 1 |
| Chord | spray 3, freeze | prox | repel 2 |
| Anvil | plain | plain | repel 3, burst 1 |
| Cipher | plain | no rack | repel 1, burst 2 |
| Facet | spray 5, bounce | plain | repel 2 |
| Lattice | bounce | bounce 2, freeze | repel 3, burst 3 |

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
work out what they like. Third fastest, a pair of heavy rounds off one pull,
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

**Anvil** wins any fight it is allowed to have. One 500-damage round every 45
ticks, the widest bomb in the game at ten tiles, the deepest energy pool and
the best recharge. It is also the slowest thing here with the worst turn, so
the whole question is whether it gets to have the fight. Three repels are how
it survives the wait.

**Cipher** is the fastest and thinnest ship in the game and the only one with
no bomb rack. Nose-on it is 16 pixels of target; broadside it is the largest
in the roster. Its gun is the whole of what it has, and its energy is the
smallest, so it cannot afford a fight it did not choose. Two bursts are its
answer to being cornered.

**Facet** fires five rounds off two barrels, fanned fifteen degrees apart,
and they bounce. It is a shotgun. Point blank most of the fan lands on one
hull, and 1500 damage kills four of the seven outright; at any real distance
the rounds are a hull's width apart and one arrives. The bounce is what makes
it a room-clearer rather than a duelist: five bouncing rounds fill a corridor,
and it is the hull that wins one it cannot see down.

**Lattice** does not kill you, it moves you. The weakest gun in the roster,
bouncing rounds, a bomb that bounces twice and freezes, and the deepest rack
of both charges: three repels and three bursts. It is the hull that decides
where a fight happens, and it needs somebody else there to finish it.

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
roster against itself and reports the matrix. It is the primary balance
question now: with no kit in the way, a hull that beats the field is a hull
that beats the field, and there is nothing a pilot could have spent to answer
it.

## Open questions

Whether seven distinct ships is more roster than we can keep balanced. It is a
harder problem than seven silhouettes on one flight row, and the bet is that a
game where the ships are actually different is worth the work. The tournament
harness exists so the answer is measured rather than argued.

Whether the Lattice is a ship or a job. Three repels and three bursts on a hull
that cannot kill anybody is a support role wearing a fighter's chassis, which
is the thing the Spire was cut for being. If it turns out nobody wants to fly
it, the answer is to give it a way to finish what it starts, not to hand its
charges to somebody else.

Whether seven is right for launch. Six ships done well beats eight done
carelessly, and the roster can grow after the game is good.
