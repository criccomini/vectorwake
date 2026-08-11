# Ships

Seven classes covering the archetypes that thirty years of play proved out:
interceptor, bomber, skirmisher, heavy, stealth, brawler, and area denial.
The roles are inherited because they work. The ships are ours.

Support was the eighth, and the Spire carried it. It is gone: see
[decisions.md](../architecture/decisions.md). The role is not disowned, it is
unbuilt, and the archetype list is the shorter for it rather than pretending
one of the seven covers it.

Names follow one family: hard geometric and architectural words, one or two
syllables, no animals and no aircraft. They read cleanly in a kill message and
at radar scale, which is where most ship names actually get used.

## The roster

| Class | Role | Reads as |
|---|---|---|
| **Apex** | Interceptor | A swept dart, wings back far enough to clear its own engines. Fastest and sharpest turn in the game |
| **Wedge** | Bomber | A wide delta with a lit bomb bay down the spine. Fires bombs on a flat, fast trajectory |
| **Chord** | Skirmisher | A shallow bow with a sensor housing at the middle. Sustained fire and detection |
| **Anvil** | Heavy | A blunt slab with two tubes on a flat bow face. Slow, enormous energy, level 3 bombs |
| **Cipher** | Stealth | A knife, and the only hull that draws dim. Cloak, stealth, and the highest burst damage |
| **Facet** | Brawler | A squat pentagon with two barrels out past the nose. Spread guns, lethal inside two tiles |
| **Lattice** | Denial | A trussed cross with dispensers at the arm tips. Mines, bricks, and repels. Owns terrain |

## Standard settings

These are the defaults, the equivalent of the original's standard settings file.
Every value is per-arena configuration; a zone that wants a fast Anvil sets a
fast Anvil. Units follow [simulation-core.md](../architecture/simulation-core.md):
speed and thrust in the Subspace-derived scales, rotation where 400 is one full
turn per second, recharge in energy per second times ten.

| Class | Speed | Thrust | Rotation | Energy | Recharge | Guns | Bombs |
|---|---|---|---|---|---|---|---|
| Apex | 4900 | 30 | 420 | 1350 | 600 | L2 | L1 |
| Wedge | 4400 | 22 | 340 | 1450 | 520 | L1 | L2 |
| Chord | 4300 | 26 | 400 | 1500 | 700 | L1 multi | none |
| Anvil | 3200 | 14 | 240 | 2600 | 380 | L1 | L3 |
| Cipher | 4700 | 24 | 390 | 1100 | 480 | L3 | L1 |
| Facet | 4200 | 27 | 410 | 1600 | 560 | L2 double | L1 |
| Lattice | 3800 | 20 | 330 | 1900 | 500 | L1 | L2 mines |

Numbers are a starting point for M3, not a balance claim. They will be wrong,
and the first playtest will say how.

## Size and shape

The one thing about a ship the original does not supply. Its files carry no
size at all, so for a while a flat 14-pixel square stood in, then a square per
hull, and neither could be right: these hulls are darts and knives, and no
square fits a ship three times longer than it is wide. Sized to the nose it
floats the flanks eleven pixels off every wall; sized to the flanks it buries
the nose. The original never had this problem because its ships were drawn
compact enough to fill a square, and ours are deliberately not.

So a hull's footprint is three numbers, measured off its own drawing: reach
past the nose, behind the tail, and to either side.

| px | Apex | Wedge | Chord | Anvil | Cipher | Facet | Lattice |
|---|---|---|---|---|---|---|---|
| nose | 20 | 13 | 13 | 15 | 22 | 14 | 16 |
| tail | 11 | 12 | 5 | 11 | 12 | 12 | 14 |
| side | 10 | 15 | 17 | 13 | 6 | 11 | 14 |

The collision box follows the heading. Against a wall the simulation uses the
world-axis bounds of the hull as oriented that tick, so a ship touches where
it is drawn touching, whichever way it points, and an Apex flying diagonally
genuinely needs more room than one flying straight: a gap you must straighten
up to thread is correct physics and a skill element, not an artifact. Turning
against a wall levers the ship gently off it; in a slot exactly your own
width, the turn is refused, because you cannot spin a 40-pixel dart in a
40-pixel gap. Weapons and pickups test the oriented rectangle itself rather
than a box around it.

That last part is the balance change worth saying out loud. A shot into a
Cipher's flank now has to reach the knife, so thin hulls are genuinely thin
targets from the side, and facing starts to matter: presenting your profile
is presenting six pixels instead of twenty-two. It is the first thing that
has ever actually told the hulls apart, since they fly identically today
whatever the settings table above says.

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

## What each ship is for

**Apex** catches things. Highest top speed, highest thrust, sharpest turn, and
an energy pool thin enough that a single mistake ends it. It exists to punish
players who are out of position, and it dies to anything it cannot outrun.

**Wedge** throws bombs on a flat trajectory at speed. Where a heavy bomber lobs,
the Wedge fires straight, which makes it lethal down a corridor and useless in
the open. It turns badly on purpose.

**Chord** puts a lot of weak bullets in the air and sees more than anyone. It
wins fights by attrition and by information: X-radar and detection let it find
cloaked ships, and its recharge lets it keep firing when others stop. It cannot
finish anything quickly.

**Anvil** is a fortress that moves. It cannot outrun or outturn anything, but
two level 3 bombs kill any ship in the game, and its energy pool means shooting
it is a commitment. Its low recharge is the price: every shot it takes is a
long time coming back.

**Cipher** kills one target and leaves. Cloak and stealth get it into position,
level 3 guns end a fight in a burst, and its energy pool means the second fight
kills it. Playing it well is about patience; playing against it is about
denying position.

**Facet** wins inside two tiles and loses outside them. Double-barrel spread
guns make it the strongest ship in a tunnel and the weakest in the open. It
gives new players something honest to learn: get close, or die.

**Lattice** shapes the map. Mines, bricks that become temporary walls, and
repels that push everything away. It scores less than anything else and decides
more fights than its stats suggest, which is a role type the original proved
players love once they find it.

The repel here is the **add-on** -- the one that welds a shove onto Lattice's
own bombs, and the one thing on the matrix nobody else can hold. The repel you
*carry and spend* is a charge, and every hull gets three of those; see
[weapons.md](weapons.md#charges). Two things called repel, one mechanic, and
only one of them is a roster trait.

## The tech tree

Each hull's row also says how far its weapons climb and which add-ons it may
ever hold. Levels and add-ons are different things -- one is the same weapon
harder, the other changes its character -- and the matrix is in
[weapons.md](weapons.md#the-tech-tree). It is the half of the roster that only
shows up once greens are flying: without it, luck with the prize table would
turn every hull into the same hull by the end of a round.

## Design rules that hold across the roster

No ship is good at everything, and every ship beats something. A player who
loses to a class should be able to name the counter.

Every class is identifiable by silhouette alone at radar scale. Shape carries
class and color carries team, per [identity.md](identity.md).

A hull's detail earns its place by saying something the silhouette cannot. The
canopy says which end is the front. A hardpoint is drawn where the class
actually fires from, so the Facet's double barrels and the Anvil's two bomb
tubes are visible facts rather than table entries. Panel lines say a ship is
built out of parts. Anything that is decoration alone belongs on a hull that
needs one of those three things instead.

Specials are role-defining rather than universal. Cloak belongs to Cipher, and a
zone that hands cloak to everything has made a different game, which is allowed
and is exactly what configuration is for.

Ship performance comes from settings, never from code. If a class needs a
mechanic the settings cannot express, either the settings are missing something
or the class is wrong.

## Open questions

Whether Chord and Facet are distinct enough in practice, or whether sustained
fire and close-range spread collapse into the same playstyle.

Whether gunners earn their place. Riding on another player is unusual and
takes explaining, and it is also one of the most distinctive things the
original did. It is built now, and every hull here carries five, so the
question is no longer whether a hull exists for it: the Spire was withdrawn
for having a role nothing implemented, and what was missing has since been
written. See [gunners.md](gunners.md). What settles this is a playtest.

Whether seven is right for launch. Six ships done well beats eight done
carelessly, and the roster can grow after the game is good.
