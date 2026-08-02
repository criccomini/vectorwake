# Weapons

Everything that leaves a ship is the same thing.

Not "a bullet and a bomb, plus special cases". One model, two tables, and
every weapon this game will ever have is rows in them. A burst, a spread, a
mine, shrapnel, a repel, a bouncing bomb, a round that freezes your recharge
-- none of those is a feature in the core. They are numbers.

## Why one model

The original has bullets, bombs, bursts, repels, decoys, thors and mines as
seven separate systems, each with its own settings block and its own code.
That is seven places to fix a bug and seven things a zone operator has to
learn, and it means a combination nobody thought of -- a bomb that repels, a
bullet that stalls your bar -- is not a setting but a rewrite.

Looking at what those seven actually *do*, they differ in eight ways:

| | what it means |
|---|---|
| spread | more than one projectile per trigger, fanned |
| bounce | walls reflect it, a fixed number of times |
| proximity | it goes off *near* you rather than *on* you |
| splinter | its ending fires more projectiles |
| level | the same weapon, hitting harder |
| freezing | it stops your bar refilling instead of emptying it |
| through walls | geometry does not apply |
| repel | it shoves rather than hurts |

None of those is a *kind* of weapon. Each is an axis, and the seven systems
are seven points in that space with the space itself left unbuilt. Build the
space and the seven fall out of it, along with everything between them.

## The two tables

A **fire pattern** is what pulling a trigger makes. A **spec** is what one
projectile is. A hull's gun and bomb are each a pattern index, and that is all
a hull knows about weapons.

```
sim_fire_pattern              sim_weapon_spec
  spec      which projectile    speed        how fast, along the heading
  count     how many              life         ticks before it runs out
  spacing   heading units apart   on_wall      end · bounce · pass
  energy    cost of the shot      bounces      walls survived, if bouncing
  delay     cooldown ticks        trigger      px from a hull that counts as arriving
  recoil    kick on the shooter   expire_ends  whether running out counts as arriving
                                  splinter     a pattern fired where it ended
                                  damage       energy at the centre
                                  blast        px of falloff; 0 lands on one hull
                                  push         px/tick shoved outward
                                  stall        ticks of suppressed recharge
```

The cost is the *shot's*, not each projectile's: a burst of sixteen costs what
pulling the trigger costs, which is what makes count a design knob rather than
a multiplier on price. Multifire is the one exception, and it is priced the way
the original priced it -- see [add-ons](#add-ons) below.

Spread angles are laid out symmetrically about the heading -- an odd count puts
one down the middle, an even count straddles it -- and they come out of the
table. Nothing here is per-shot random, because two machines have to agree.

`splinter` naming a pattern is the whole trick. A pattern makes projectiles;
a projectile can end in a pattern; so shrapnel is a bomb whose ending is a
burst, and no new mechanism was needed to say so.

## A projectile's life, in four phases

It runs out · it moves · something ends it · the ending happens.

That order is the model. Every difference between a bullet, a bomb, a mine and
a fragment is a number read during those four steps rather than a branch
between them.

**Running out is not arriving.** A bomb that crosses the arena untouched and
expires at five seconds has *not* got anywhere, so it does nothing -- that is
what a player means when they say a bomb that times out should not splash.
A mine is the opposite: its whole life is a timer, and `expire_ends` says so.

**Arriving** is being within `trigger` of an enemy hull. Zero is contact, which
is a bullet; anything larger is a proximity fuse that never touches you.

**Ending** does up to four things, all optional: hurt the hull it touched, hurt
everything inside `blast` with damage falling off linearly from the centre,
shove ships *and other projectiles* outward, and fire `splinter`. A plain
bullet does the first. A bomb does the first two. A repel does only the third.

A round that ends at a wall ends on the near side of it rather than a step
inside. A blast centred in the tile spends half its reach where nobody is, and
fragments born in there die on their own first tick.

## What is carried per projectile, and why

Two bytes: `left`, the bounces it has not spent, and `depth`, how many
splinter generations are behind it.

`depth` is a fork-bomb stop. Nothing in a table prevents a fragment's spec from
naming the pattern that made it, and sixteen become two hundred and fifty-six
become four thousand in three ticks. One generation is allowed
(`SIM_MAX_SPLINTER_DEPTH`), and the test for it points the fragments back at
their own pattern deliberately, because that is the shape of the danger.

Both are per projectile rather than per spec because both are *spent* as it
flies, and both are in the snapshot, because a client that predicted a bounce
the server had already used up would show a shot going the wrong way.

## Recipes

Every one of these is table rows. None of them is code.

**Bullet.** speed, life, `on_wall: end`, damage. Count 1.

**Bomb.** Slower, longer-lived, `blast: 48px`. The blast is what makes damage a
measure of how close you were standing, which the screen shake reads back out.

**Multifire.** The same spec, `count: 3`, `spacing: 20°`.

**Burst.** `count: 16`, `spacing: 22.5°` -- a full turn divided by the count,
so it is a rosette. Sixteen for the price of one trigger pull.

**Bouncing bomb.** The bomb spec with `on_wall: bounce`, `bounces: 3`.

**Mine.** `speed: 0`, a long `life`, `expire_ends: 1`, a blast. It sits where
you left it and goes off on its timer -- and because speed is inherited from
the ship, a mine dropped at speed is a mine that drifts.

**Shrapnel.** A bomb whose `splinter` is a burst of short-lived fragments.

**Repel.** `speed: 0`, `life: 1`, `expire_ends: 1`, `on_wall: pass`, a large
`blast` radius, `push`, and *no damage at all*. It shoves ships and incoming
projectiles away from you and hurts nobody, which is exactly what a repel is.

**Stall round.** `damage: 0`, `stall: 200`. Two seconds where your bar simply
stops refilling. In a game where energy is the health and the ammunition, that
is its own kind of damage -- and it is the one case where doing nothing to the
bar still has to count as a hit, which is what made the first attempt land
silently.

**Levels.** Not a field. A level is another spec with a bigger `damage`, and a
prize that swaps which pattern the trigger points at. See the tech tree below.

## Writing one

A zone file names weapons; the core numbers them. The baseline builds a gun
and a bomb for every hull and they get the names an operator would guess, so
tuning one is two lines and does not touch the rest of it:

```toml
[[arena.weapons]]
name = "anvil-bomb"
on_wall = "bounce"
bounces = 3
```

Any *other* name makes a weapon that did not exist, which a hull can carry or
another weapon can splinter into. Order in the file does not matter -- names
are all collected before any of them are resolved:

```toml
[[arena.weapons]]
name = "anvil-bomb"
splinter = "shrapnel"

[[arena.weapons]]
name = "shrapnel"
speed = 1200
life = 40
damage = 50
count = 8
spread = 45          # a full turn over eight, so a rosette

[[arena.ships]]
name = "Spire"
bomb = "repel"       # and bomb = "" takes a rack away
```

One block is a pattern *and* its spec, because every weapon anybody has wanted
is one of each and a name is easier to write than a pair of indices. Sharing
one projectile between two triggers is not expressible, and nothing has wanted
it. Units are the rest of the file's -- px, px/s/10, energy, ticks -- plus
degrees, because nobody thinks in sixty-five thousandths of a turn.

Saving the file is enough. The zone re-reads it, rebuilds its tables from the
baseline, applies the file over that, and sends the result to everyone in the
room. Rebuilding first is what makes a deleted line actually go away, and what
stops a weapon block appending another row every time the file is touched.

## The tech tree

A weapon has a **level** and a set of **add-ons**, and they are different
things.

A level is *the same weapon, harder*: a rung on a ladder of patterns the hull
carries, and climbing it swaps which one the trigger fires. An add-on changes
the weapon's *character* -- it bounces now, it breaks up, it freezes a bar.

The reason to keep them apart is arithmetic. As rungs, three levels against six
on/off add-ons is a hundred and ninety-two patterns for one weapon, and the
table holds sixty-four. So a level is a row and an add-on is a **transform over
that row**, applied at the moment of firing. That is the only new mechanism the
tree needed.

### Everything is a count with a ceiling

| kind | the count means | the ceiling is |
|---|---|---|
| stat | steps from the hull's floor toward its ceiling | eight |
| level | which rung of the trigger's ladder | the ladder's length |
| add-on | how much of that add-on | the hull's row |
| charge | how many you are carrying | the hull's row |

One shape, four meanings. A green is one byte naming a place in that space --
five stats, then a level per trigger, then an add-on per trigger per kind --
which is also the space a zone weights and the client colours from.

### Add-ons are per trigger

You hold "bounce on guns" and "shrapnel on bombs" as separate items, which is
what makes bullets that freeze and bombs that do not a thing you can carry.
Six add-ons, two bits each, two triggers: four bytes on the pilot.

| add-on | what it changes |
|---|---|
| multi | `count`, and `spacing` if the pattern had none |
| bounce | `on_wall`, `bounces` |
| prox | `trigger` |
| shrapnel | `splinter`, to the zone's fragment pattern for that rung |
| freeze | `stall` |
| repel | `push`, and a fuse if the weapon had no reach |

`repel` is the one that shows the model paying off. It is the same `push` field
whether it is bolted onto your bomb or fired on its own as a charge: an add-on
and an item, one mechanic.

**Multifire also changes what the shot costs**, and it is the only add-on that
does. The rest change a weapon's character; this one hands you more bullets,
and more bullets for the same price is the whole of the balance problem.

The original priced it as two separate settings rather than per round:

| | plain | multifire |
|---|---|---|
| `BulletFireEnergy` | 20 | 30 |
| `BulletFireDelay` | 25 ticks | 50 ticks |

Three rounds for half again the energy and twice the wait. Note where the
weight sits: most of the price is the **rate**, not the energy. Energy comes
back on its own, so a cost paid in energy is a cost paid once and recovered;
a cost paid in cooldown is paid every time you pull the trigger and cannot be
out-recharged. A pilot with multifire fires fewer, wider, more expensive
volleys, which is a different weapon rather than a better one.

Ours is those two ratios as a percentage per rung -- `mod_multi_energy = 50`,
`mod_multi_delay = 100` -- because we have rungs and the original did not. A
second rung is a second helping of both, linear like every other add-on here.

### A shot is what it was when it left

A projectile carries the add-ons of the trigger that fired it -- two bytes, on
the weapon and in the snapshot. It cannot read them off its owner, because the
owner may pick up a green, change hull or die while it is in the air. A bomb
thrown while you had shrapnel still breaks up after you are dead, which is the
right rule and also the only one a client can predict.

Fragments carry nothing. A shell that broke into eight would otherwise have
each of those break into eight again.

The same is true of a **level**: a rung swaps which pattern the trigger fires,
so a level-two bullet was spawned from the level-two row and its spec -- with
the harder damage in it -- is what the projectile carries. And of a **charge**:
the count is spent at the trigger, and the sixteen rounds a burst makes are
ordinary projectiles from that moment on.

So dying clears the *inventory*, which is what gates firing. Nothing in flight
reads it: the update loop touches `owner` only to skip you in collision and to
name you in an event. A pilot who is killed a tick after throwing a levelled,
shrapnel-loaded bomb still gets the bomb they threw.

### The matrix

Each hull's row says how far it climbs and what it may hold. This is what keeps
the roster a roster once greens are flying: no run of luck turns a Spire into a
bomber.

| | gun | bomb | gun add-ons | bomb add-ons |
|---|---|---|---|---|
| **Apex** interceptor | 2 | 1 | multi | |
| **Wedge** bomber | 1 | 2 | | prox, shrapnel |
| **Chord** skirmisher | 2 | — | multi ×2, freeze | |
| **Anvil** heavy | 1 | 3 | | shrapnel ×2, prox |
| **Spire** support | 1 | — | freeze ×2 | |
| **Cipher** stealth | 3 | 1 | bounce | |
| **Facet** brawler | 2 | 1 | multi ×2 | prox |
| **Lattice** denial | 1 | 2 | | repel ×2, bounce ×2 |

**Charges are not on this matrix**, and that is the original's rule rather than
an omission -- see below.

A rung is 40% more damage and costs the same to fire. A level is a straight
upgrade, which is what makes it worth crossing the map for; what stops it
running away with a match is that the pilot holding it is carrying a bounty
everyone can see.

### A green is a green

Greens carry no type. Every one of them is takeable by everybody, and what it
turns out to be is rolled where it is picked up, from what that hull could ever
hold. There is no such thing as a green with somebody else's name on it.

The first version typed them at spawn, and the arena filled with greens that
refused to be picked up -- two thirds of them, for an Apex. The treatment was
drawing the ones that were not yours at a quarter alpha, which is a lot of
machinery to make a rule legible instead of removing the rule.

The roll is over what the hull could *ever* hold, not what it can still take.
So a pilot already at the ceiling takes the green, is told what they found, and
nothing moves. That matters: a green eaten in silence is a green that lies, and
one that cannot be picked up reads as a broken pickup. Being told "+ speed" and
watching the number stay where it is says the true thing -- you are full.

It runs off the state's own generator, so the roll is the same roll on the
server and on every client predicting it.

The consequence to accept is that you cannot choose which green to chase. They
are identical on the map and always worth taking, which is the trade: the
gamble is the mechanic, and it is the same gamble for everybody.

### Charges

A charge is a weapon you carry a count of and spend: a repel, a burst. It
needed no new mechanism at all -- it is a pattern, exactly like a gun's, plus
an inventory. The repel is `push` with no damage, which the model has been
able to express since the day it was written; the burst is sixteen rounds at a
full turn's spacing, the rosette that motivated `count` and `spacing` in the
first place.

Four kinds, zone-wide, so slot two means the same weapon for everybody and a
zone can weight "the odds of finding a burst".

**Every hull may carry three of every charge.** That is the original's rule:
`RepelMax`, `BurstMax`, `DecoyMax`, `ThorMax`, `BrickMax`, `PortalMax` and
`RocketMax` are all 3 on all eight of its ships, and every ship starts holding
none of them. Charges are not a roster trait there; they are loot, and the
hull does not gate them.

The ceiling is still a per-class field, so a zone that wants charges to be a
trait can say so and the core will honour it -- but the shipped roster does
not. Two reasons:

- **Hull identity already has three carriers** -- the ladders, the add-ons,
  and the flight model. A fourth buys little and costs the thing below.
- **A mixed inventory is the whole point of the cycle key.** An earlier roster
  gave each hull exactly one kind, which meant nobody could ever hold two,
  which meant the key that cycles them and the pad that draws them could never
  do anything. The control was correct and unreachable.

The consequence to know: charges are the *common* green. Both slots at 70
against five stats at 40 makes a charge better than one green in three for
every hull. That is faithful -- in the original's table `Brick` alone outweighs
every stat put together -- and it is the number to move if the arena starts
feeling like a fireworks display.

**Which one is ready is not simulation state.** The client picks a slot and
sends it in the two spare button bits; the core just spends what it is told.
That keeps a selection byte out of every snapshot, keeps edge detection out of
a function that gets replayed, and means the whole feature costs the wire four
bits of button and four bytes of inventory.

The input is the reason it works that way. Vectorwake is built on five inputs,
because that is what a d-pad has and what a phone can draw, and the game
already spends four arrows plus guns, bombs and menu. A key per charge kind is
what the original did and it does not survive a touchscreen. **One input
cycles which charge is ready and one spends it** -- two inputs for any number
of kinds, with the panel showing `> BST×2` so the marker carries what the
extra keys used to.

The cost is that you can only have one thing ready, so carrying a mixed
inventory is a decision rather than a hotkey. That is slower than muscle
memory on seven keys, and it is the trade.

### The odds, and rust

Each place in the prize space carries a weight, and the roll reads them against
the pool of whoever took the green. So a zone writes the *shape* of its tree,
and the roster decides which parts of that shape a given pilot can see.

**The baseline is the original's `[PrizeWeight]` table**, entry for entry, out
of the settings shipped with the reference server:

| | weight | theirs |
|---|---|---|
| each stat | 40 | `Energy`, `QuickCharge`, `TopSpeed`, `Thruster`, `Rotation` |
| a weapon level | 25 | `Gun`, `Bomb` |
| multi, shrapnel | 30 | `MultiFire`, `Shrapnel` |
| bounce, prox | 25 | `BouncingBullets`, `Proximity` |
| a charge | 70 | `Repel`, `Burst` |

A charge being the heaviest entry by a distance is the part worth noticing: in
the original the green you are pleased to see is a thing the *odds* say, not
the item. For an Apex -- five stats, a gun level, multifire, a burst -- that
works out to a green being a stat three times in five and a charge better than
one time in five.

Two of our add-ons have no entry to copy, because the original has no such
prize: freeze and push exist there as weapon effects, never as something a
green hands you. They get 25, the band its comparable add-ons sit in, and that
is a number we chose rather than inherited. Everything in its table we do not
have -- cloak, stealth, xradar, antiwarp, warp, decoy, thor, brick, rocket,
portal, shields, allweapons, multiprize -- is simply absent from our space.

The weights are relative rather than percentages. Doubling every number changes
nothing, which means a zone can add a weapon without recalculating the file.

**Rust** is a green that takes something back. It is not a place in the space
-- it is a chance, out of a thousand, that the green corrodes instead of
granting, and the baseline is 10: one green in a hundred.

The original ships `PrizeNegativeFactor=300`, one in three hundred, which is
rare enough to be a curiosity rather than a mechanic. Ours is three times more
common because rust is doing a job here that it was not doing there -- it is
the only way *down* a tech tree that otherwise only climbs -- but it is still
the rare case. A pilot notices rust; a pilot does not plan around it.

What it takes is chosen evenly from **what the pilot is actually holding**, and
that is the whole reason it is not simply cruel:

- a pilot who has just spawned holds nothing, cannot be rusted, and the green
  quietly becomes an ordinary one. The punishment never lands on arriving.
- a loaded pilot is the one with something to lose, so rust is a second source
  of the pressure bounty applies -- being ahead costs something.
- nothing can rust below nothing, and nothing can rust into a state the hull
  could not have reached on its own.

Losing an energy step clamps the bar down to the new ceiling rather than
leaving a pilot standing above it.

The client draws and sounds a rust as a loss: the feed says `- speed` in the
rust colour, and there is a separate sound, because the one mechanic in the
game that costs you something should not be silent.

### Writing a tree

Rungs above the first are named for their level, so a zone tunes them the same
way it tunes anything else, and a hull's row is two inline tables:

```toml
[[arena.weapons]]
name = "anvil-bomb-3"     # the Anvil's third rung
blast = 96

[arena.mod_step]          # what one rung of each add-on is worth
freeze = 250              # ticks
prox = 24                 # px of fuse

[[arena.ships]]
name = "Anvil"
bomb_mods = { shrapnel = 3, prox = 1 }
gun_mods = { multi = 1 }
```

## What is deliberately out

**Appearance.** The core carries no colours. The client keys a projectile's
look off its spec id in its own table, and asks `spec_blast(id) > 0` to know
whether a thing that just went off looks like a bomb -- because a weapon that
goes off looks like one by *being* one. The same line we hold for tile classes.

**Randomness.** No per-shot jitter anywhere. A rosette is the same rosette on
every machine, or the state hashes stop matching and the whole determinism
argument goes with them.

**Directional splinter.** Fragments leave at rest, spread about world north. A
cone that follows the parent's travel needs the heading kept on the projectile,
which is another byte in every snapshot. Not until something wants it.

**Homing, charging, chaining.** Each is a genuinely new verb rather than a
number, and none of the seven originals needs one.

## The shipped tuning

Two rows per hull, built from the roster in `sim/src/baseline.c`: a bolt and a
gun pattern, and for the six hulls with a rack, a shell and a bomb pattern.
Nothing in the shipped zone bounces, splinters, stalls or pushes yet. The
mechanics are live and tested; turning one on is a table edit.

And the table is the zone's, not the client's. A zone sends its whole weapon
table to every player as it joins, so a client predicts and draws the weapons
that zone actually has rather than the ones its own build compiled. That is
what makes a new weapon content: a spec is an index, and a client guessing at
its own table would not even agree on what an index means.

Firing costs are a fraction of the hull's own energy, taken from the original's
numbers -- it gave every ship 1700 energy and charged 20 for a bullet and 300
for a bomb. Pricing a shot off its damage instead, which is what this did
first, made a bullet cost 35% of a full bar and a bomb 63%, so the bomb key did
nothing at all unless you had been left alone to recharge, and silently.

One number to revisit at the first playtest: a bolt travels 200 px/s and a hull
tops out at 490. Bullets slower than the ships they chase is a strange place to
start, and it is one row of the table.
