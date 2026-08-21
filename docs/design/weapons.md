# Weapons

> **Two parts of this changed.** [match-game.md](match-game.md) removed greens
> entirely, keeping the upgrade space below as the coordinate system a chosen
> kit is built in, and made a mine an ordinary charge rather than the bomb
> trigger's other posture. What the pickup, its weights and rust were is in
> `docs/research/` with the rest of the original's tables.

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
| bounce | walls reflect it, for a budget the weapon sets |
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
  energy_up more per rung          still        laid rather than thrown
  delay     cooldown ticks        trigger      px from a hull that counts as arriving
  recoil    kick on the shooter   expire_ends  whether running out counts as arriving
                                  splinter     a pattern fired where it ended
                                  damage       energy at the center
                                  blast        px of falloff; 0 lands on one hull
                                  push         px/tick shoved outward
                                  push_time    ticks the shove outruns a hull
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
everything inside `blast` with damage falling off linearly from the center,
shove ships *and other projectiles* outward, and fire `splinter`. A plain
bullet does the first. A bomb does the first two. A repel does only the third.

A round that ends at a wall ends on the near side of it rather than a step
inside. A blast centered in the tile spends half its reach where nobody is, and
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

**Bouncing bullet.** The same two fields, and the difference between the two
recipes is the whole of why `bounces` sits on the spec instead of in
`mod_step`. A bomb's bounces are counted and a bullet's are not: the original
has `BombBounceCount` per ship, 1 on the Lancaster and 0 on everyone else,
with `BBombDamagePercent` beside it, and no bullet equivalent of either.
On the wire it is not a budget at all but a weapon *type*, 1 for a bullet
against 2 for a bouncing one. So a bullet takes `bounces: 255`, which its
5.5 seconds of life cannot spend, and one point of bounce turns it from a
round that stops at the first wall into one that fills a corridor. A fragment is a
bullet and takes the same number.

`mod_step` could not express that. A step is one number for every weapon that
takes the add-on, and these two weapons take it and spend it differently.

**Mine.** `speed: 0`, `still: 1`, a long `life`, `expire_ends: 1`, a `trigger`,
and a blast. It sits where you left it and goes off when its fuse finds
somebody or its timer runs out, whichever comes first. Nothing in the update
loop knows a mine from a bomb.

**It is a charge.** A count you carry out of your kit and spend, in the slot
beside repel and burst, which is what makes "how many mines do I bring" a
loadout decision priced against everything else in the thirty.

It was the bomb trigger's other posture for a long time, on the original's own
chord: shift and the bomb key, no inventory, mines for as long as you had a
rack, limited by a `mine_max` per hull. That is faithful, and it was the wrong
half of the original to keep once a pilot chose their ship. The limit lived on
the hull rather than in the pilot's hands, so the one weapon in the game that
denies ground could not be traded for anything.

What went with it: the chord, its touch cell, and `mine_max`. Six mines was
then the Lattice's row, which fixed the wrong half of the same problem: the
limit had moved off the rack and onto the roster instead of into the pilot's
hands. Six is the arena's ceiling for everyone now, the kind is something the
shop sells, and the miner is whoever spends a fifth of their kit on mines.

The count is the ordinary charge count, spent at the lay and not refilled
until the next match. Dying does not clear your minefield, so what is already
posted stays posted and stays yours.

Two minutes of `life`, and a zone moves it the way it moves any weapon's:
`[[arena.weapons]] name = "mine"`, `life = 12000`. That clock is the whole
of how long the ground a minefield denies stays denied, so it is a map setting
as much as a weapon one and worth reaching for before the damage. The original calls it MineAliveTime, bounds it at two seconds to ten minutes,
and its vanilla settings run it at exactly this: 12000 hundredths.

Laying one costs 270 energy and 150 more per bomb rung, against the 300 and 50
of throwing one, and locks the triggers for 125 ticks against a bomb's 150.
So a mine is cheaper and quicker than the bomb it is at rung one and dearer by
rung three -- 570 against 400 -- which is what stops the rung being free on the
weapon that does not have to be aimed. All four are the original's:
LandmineFireEnergy, LandmineFireEnergyUpgrade and LandmineFireDelay.

`still` is the only field the weapon needed that the model did not already
have, and it is there because every other round in the game wants the
opposite. A shot takes the firer's velocity on top of its own speed, which is
what makes one fired at a run faster over the ground than one fired standing.
A speed-zero round with that velocity added does not sit anywhere: it leaves
the rack at exactly the speed the ship was doing and holds it until a wall
stops it. This page called that drift for a while. It is not drift, it is
flight, and it made the weapon usable only from a standstill.

A mine is the bomb you leave behind, so it takes the bomb trigger's add-ons as
well as its rung. Shrapnel breaks it up, and into rounds of your *gun's* rung,
the same way a thrown bomb's fragments are read off your guns at the throw.
Freeze stalls whoever it catches. Push shoves them. A pilot who climbed to
shrapnel and watched their mines go off as bare blasts was being told the two
are different weapons, and they are not.

Two exceptions, in opposite directions. **Multifire is stripped**, because it
multiplies a *pattern* rather than transforming a round: three mines out of
one charge is not a stronger mine, it is a different inventory, and the
inventory is exactly what the kit already decided. And **proximity
takes the larger of the two rather than the sum**, because a mine already
senses. Adding is right for a bomb, which is a contact round with nothing to
add to; on a mine it stacked to two tiles further than a proximity bomb of the
same rung, which inverts the reason the mine's own fuse is the tighter of the
two. It does not have to be dodged in the air first, so it should not out-range
the round that does. With the add-on a mine senses exactly as far as the bomb
it is; without it, its own two tiles.

Its rung is also its color: the color on the floor is the color of the
bombs you throw. That is a real number rather
than paint, because `blast_up` climbs the bomb ladder's own arithmetic and a
rung three mine makes a rung three bomb's hole. A charge fires one pattern, so
a mine cannot be a row per rung the way a bomb is; `blast_up` is to the mine
what `damage_up` is to the fragment, which is the second weapon whose rung
comes from somewhere other than a ladder of its own.

**A repelled mine stops being a mine.** Shoved by an enemy repel it becomes a
bomb of the rung it was laid at and leaves in the push direction. The shape is
wrong for a round in flight in both directions at once -- a minute of life, and
a fuse tuned to something standing still beside it -- so a mine pushed as
itself would cross the map at repel speed and keep going. Clearing a posted
doorway is what a repel is *for*, and what comes out the far side is
recognisably the thing that was posted, still owned by whoever laid it and
still able to kill them. Your own repel leaves your own mines alone, which is
the push loop's hostile-only rule reaching the new round rather than a rule
of its own.

**Shrapnel.** A bomb whose `splinter` is a burst of short-lived fragments, and
the fragments are *bullets*. That is the original's rule and it is where the
add-on stops being a bomb thing: a fragment is a round of your **gun's** rung,
bouncing if your bullets bounce, so a bomber who spent points on their gun
throws a harder burst without touching their bombs. Both are read at the throw and
carried by the bomb, so upgrading mid-flight does not improve the burst on its
way, and a pilot who dies still throws what they had earned.

`damage_up` is what lets one spec be a whole ladder here: it is
BulletDamageUpgrade, added once per rung, because a fragment's rung comes from
another trigger rather than from a row of its own.

**Repel.** `speed: 0`, `life: 1`, `expire_ends: 1`, `on_wall: pass`, a large
`blast` radius, `push`, `push_time`, and *no damage at all*. It shoves ships and
incoming projectiles away from you and hurts nobody, which is exactly what a
repel is.

`push` is a *speed*, not an impulse: everything hostile inside the reach is set
to exactly that, whatever it was doing and however close it was standing. There
is no falloff, and the reach is a square rather than a circle -- the corners
get about 724 px where the sides get 512, which is what the original tests and
so is what we test. `push_time` is why a repel works at all: the speed is
deliberately faster than any hull can fly, so without a window during which the
shoved ship keeps that ceiling instead of its own, its clamp takes the whole
shove back on the very next tick. A repelled round has its clock restarted too,
so a bomb batted back the way it came has its whole life to make the trip.

**Stall round.** `damage: 0`, `stall: 200`. Two seconds where your bar simply
stops refilling. In a game where energy is the health and the ammunition, that
is its own kind of damage -- and it is the one case where doing nothing to the
bar still has to count as a hit, which is what made the first attempt land
silently.

**Levels.** Not a field. A level is another spec with a bigger `damage`, and a
rung in the kit that swaps which pattern the trigger points at. See the tech tree below.

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

The weapons that belong to a settings slot rather than to a hull are named for
the slot: `charge-1` through `charge-4`, and `shrapnel-1` up, one per rung of
the add-on. Naming a charge slot the baseline leaves empty makes the weapon and
fills the slot in one block.

`mine` is the exception that is named rather than numbered, because it is not
a slot whose contents a zone picks: there is one mine, it is what the bomb
trigger lays, and calling it `charge-3` would say the opposite.

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
name = "Chord"
bomb = ["repel"]     # the ladder, first rung first; [] takes a rack away
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
| add-on | how much of that add-on | the arena's row |
| charge | how many you are carrying | the arena's row |

One shape, four meanings. A kit slot is one byte naming a place in that space:
five stats, then a level per trigger, then an add-on per trigger per kind, then
a charge apiece. Every slot in it costs the same one point, which is what makes
a budget of thirty a sentence a player can reason about.

### Add-ons are per trigger

You hold "bounce on guns" and "shrapnel on bombs" as separate items, which is
what makes bullets that freeze and bombs that do not a thing you can carry.
Six add-ons, two bits each, two triggers: four bytes on the pilot.

| add-on | what it changes |
|---|---|
| multi | `count`, and `spacing` if the pattern had none |
| bounce | `on_wall`, `bounces` |
| prox | `trigger` |
| shrapnel | `splinter`, to the zone's fragment pattern for that rung; the fragments come off the *gun* |
| freeze | `stall` |
| repel | `push` and `push_time`, and a fuse if the weapon had no reach |

`repel` is the one that shows the model paying off. It is the same `push` field
whether it is bolted onto your bomb or fired on its own as a charge: an add-on
and an item, one mechanic.

**Multifire also changes what the shot costs**, and it is the only add-on that
does. The rest change a weapon's character; this one hands you more bullets,
and more bullets for the same price is the whole of the balance problem.

The rounds in one gun pull are linked. The first one that touches a hull spends
the rest of the volley, so a tight three-round fan cannot deal three hits to one
pilot. A wall only removes the round that reached it. The other sides of the fan
keep flying, which preserves multifire's ability to cover a corner.

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

Ours is those two ratios as a percentage per rung (`mod_multi_energy = 50`,
`mod_multi_delay = 100`), because we have rungs and the original did not. A
second rung is a second helping of both, linear like every other add-on here.

The base gun energy is also multiplied by its gun level, as SVS does. Before
multifire or hull barrels, a level-one shot costs 20, level two costs 40, and
level three costs 60. The harder bullet therefore asks for more of the same bar
it is trying to take from its target.

The damage number is a ceiling. SVS left exact damage off for bullets, burst
rounds, and shrapnel, and Vectorwake follows it. Each hit uses the same
square-root random curve and averages near two thirds of the listed value. Bomb
damage stays exact before blast-distance falloff.

**Barrels are the hull's own.** `DoubleBarrel` was a per-ship setting and the
Terrier alone carried it: two rounds abreast for one pull where every other
ship sent one. The Facet has it here. It is not an add-on, so it is never picked
up and never dropped.

The SVS Terrier pays the same price as the Warbird for that pull:
`BulletFireEnergy=20` and `BulletFireDelay=25`. `DoubleBarrel` changes the two
rounds that leave, not the trigger cost or its clock. Facet follows the same
rule. Its gun level still multiplies the base cost, and multifire still adds its
own energy and delay surcharge once per rung.

The arithmetic is the part worth keeping. Multifire *adds* barrels rather than
multiplying them, so two abreast plus a rung of multifire is four rather than
the six a pilot expects out of three times two. That was the Terrier's real
behavior, and here it falls out of the model instead of being written down
for one hull.

The Terrier and Facet both use the baseline's 25-tick gun delay.

### A shot is what it was when it left

A projectile carries the add-ons of the trigger that fired it -- two bytes, on
the weapon and in the snapshot. It cannot read them off its owner, because the
owner may change hull or die while it is in the air. A bomb
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
name you in an event. A pilot who is killed a tick after throwing a leveled,
shrapnel-loaded bomb still gets the bomb they threw.

### The matrix

One row, for the arena, in `sim_settings::kit_ceiling`. It says how far each
weapon climbs and how deep each add-on goes, and it says the same thing to
every hull in the room.

**Availability follows the original; ceilings are ours.** `MultiFire`,
`BouncingBullets`, `Proximity` and `Shrapnel` appear nowhere in the original's
per-ship config: they are `[PrizeWeight]` entries any ship can be handed. Its
per-ship differentiation is a short list of flags and counts, and the ones that
bear on this are `MaxBombs` (3 on the Leviathan, 2 elsewhere), `ShrapnelMax` (8
everywhere, 31 on the Shark), `BombBounceCount` (1 on the Lancaster alone) and
`DoubleBarrel` (the Terrier alone).

Those four were a row per hull here too, and they are not any more. A trait one
hull holds is a trait the shop can never sell, so the deepest of each is the
arena's ceiling and everything below it is a purchase. A bomber is not the hull
that holds the most shrapnel; a bomber is a pilot who bought three rungs of it.
See [ships.md](ships.md#the-tech-tree).

Barrels are on the matrix now. `DoubleBarrel` was the one weapon setting with
no home in this space, being neither a ladder nor an add-on, and it stayed a
flag on one hull for exactly as long as that was true. It is `SIM_MOD_BARREL`:
an add-on that adds to the round count rather than multiplying it, keeps its
own tight spacing, and charges energy without charging cooldown. That last part
is the whole difference from multifire, which charges both: a fan throws more
and slows you down, a pair throws fewer at the rate you already had.

| | rungs above the first | add-ons |
|---|---|---|
| **gun** | 2 | multi ×2, bounce, freeze, barrel ×2 |
| **bomb** | 2 | prox, shrapnel ×3, bounce ×2, freeze |

Those are the deepest each of the seven hull rows used to reach, so nothing was
granted and nothing taken away when the rows collapsed into one. A Wedge could
always hold three rungs of shrapnel; now anyone who buys them can.

**Freeze and push are the exception**, and the only part of this table that is
ours: the original has no such upgrade, so there is nothing to copy. Freeze
hangs off both triggers, because stalling a recharge is a thing a hit does and
the core reads it off whichever trigger's add-ons carried it. Push is off the
shelf until the shove has had a look of its own, so the bomb row does not
mention it and no arena grants it.

The names a player reads are not these. `multi` is **Spray** and `barrel` is
**Double barrel** on the ship page and in upgrades; the words in this table are
the core's, and the core's are what a zone file writes.

**A trigger's add-ons stay a trigger's.** Bullets do not carry a fuse and do
not break up, because a bullet with a proximity fuse is a bomb and that weapon
already exists. Bombs do not fan and do not come in pairs, because a rack that
throws three at a pull is a different game. Those four are zeroes in the
arena's row, and a zero is a slot that does not exist: it is not on the shelf
and it is not in the hangar.

The other way a weapon goes missing is having **no rack**. An add-on is a
transform on a trigger, and a trigger that does not exist cannot be
transformed. Every hull on the shipped roster carries one, so this is a rule
for a zone that takes a rack away rather than a fact about any of them.

**Charges are not on this matrix**, and that is the original's rule rather than
an omission -- see below.

A rung is 40% more damage and costs the same to fire. A level is a straight
upgrade, which is what makes it worth crossing the map for; what stops it
running away with a match is that the pilot holding it is carrying a bounty
everyone can see.

### A kit is thirty of these

Nothing rolls. A pilot spends thirty points in the hangar, one per step, and
the ship is dealt that kit at every spawn: stats, rungs, add-ons and charge
counts, inside the arena's own row. The space above is the coordinate system
that kit is written in, which is why it survived the pickup being deleted
whole. [match-game.md](match-game.md) has the budget and what rivets buy.

Two properties the pickup used to provide are now structural rather than
tuned. A pilot cannot hold what the arena has no ladder for, because the
ceiling is checked where the kit is dealt rather than where a green is rolled.
And what a death costs is the walk back, because the frame is re-dealt from
something the pilot owns.

**Charge counts are the exception, and the only one.** They come back at the
start of a match and never at a spawn, so a repel spent in the opening joust
is a repel gone for three minutes. Refilling them on death would mean a pilot
out of repels could suicide into the nearest enemy to reload, and at a bounty
of one that costs nothing.

### Charges

A charge is a weapon you carry a count of and spend: a repel, a burst. It
needed no new mechanism at all -- it is a pattern, exactly like a gun's, plus
an inventory. The repel is `push` with no damage, which the model has been
able to express since the day it was written; the burst is sixteen rounds at a
full turn's spacing, the rosette that motivated `count` and `spacing` in the
first place.

Four kinds, zone-wide, so slot two means the same weapon for everybody and a
zone can weight "the odds of finding a burst".

**Everybody may carry three of every charge**, and six mines. That is the
original's rule, give or take the mine:
`RepelMax`, `BurstMax`, `DecoyMax`, `ThorMax`, `BrickMax`, `PortalMax` and
`RocketMax` are all 3 on all eight of its ships, and every ship starts holding
none of them. Charges are not a roster trait there; they are loot, and the
hull does not gate them.

The ceiling is the arena's, and it is six for mines rather than three: that
was the Lattice's row, and it is everybody's now. Charges are not a hull trait
here for the same reason nothing else is, plus one of their own:

- **A hull carries no traits at all.** Ladders, add-ons and flight are the
  arena's; the hull is a footprint. A trait one hull holds is a trait the shop
  cannot sell, which is what made the roster's version of this a dead end. See
  [ships.md](ships.md#the-tech-tree).
- **A mixed inventory is the whole point of the cycle key.** An earlier roster
  gave each hull exactly one kind, which meant nobody could ever hold two,
  which meant the key that cycles them and the pad that draws them could never
  do anything. The control was correct and unreachable.

The consequence to know: a charge is a point like any other, so a pilot who
wants six of them buys six by giving up six steps of something else. What used
to be an odds question is a budget question, and the number to move if the
arena starts feeling like a fireworks display is the arena's row rather than a
weight.

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

Repel and burst do not share the gun and bomb firing clock. A pilot may spend
one during a weapon delay, on the same tick as a shot, or immediately after
another charge. Their inventory and energy cost are the limits. Mines are not
charges: they wait for the bomb clock and lock both weapon triggers when laid.

### Thirty is a loud opening, and that is a choice

Every ship spawns carrying thirty steps. That number is the strongest single
lever in the tuning, and it does more than make openings livelier. Running the
bot calibration ladder over a 48-round round-robin, same hull, three pilots at
skill 0.15, 0.50 and 0.95, the kills come out:

| | low | mid | high |
|---|---|---|---|
| nothing dealt | 93 | 102 | **187** |
| thirty dealt | 313 | 290 | 299 |

A two-to-one skill gap becomes flat, and the total number of kills triples.
With everyone carrying multifire from the first second, time to kill collapses
and the fight is over before flying it decides anything.

That was measured when the thirty were rolled, and choosing them rather than
rolling them does not move it: the flattening comes from how loaded a ship is
at the whistle, not from where the load came from. It is a choice for a game
that wants its openings loud. The offline calibration in
`server/src/calibrate.rs` deals nothing for exactly this reason, because a
ladder has to be able to rank pilots.

### Writing a tree

Rungs above the first are named for their level, so a zone tunes them the same
way it tunes anything else, and the ceilings are one section:

```toml
[[arena.weapons]]
name = "anvil-bomb-3"     # the third bomb rung, which every hull climbs to
blast = 96

[arena.mod_step]          # what one rung of each add-on is worth
freeze = 250              # ticks
prox = 24                 # px of fuse

[arena.kit]               # and how many rungs of each a kit may hold
gun_mods = { multi = 2, bounce = 1, freeze = 1, barrel = 2 }
bomb_mods = { prox = 1, shrapnel = 3, bounce = 2, freeze = 1 }
charges = [3, 3, 6]       # repels, bursts, mines
```

An add-on left out of a map that names any is a slot this arena does not have,
which is how "bombs do not fan here" gets said. Leaving the section out
entirely keeps the baseline's, which is the union of what the seven hull rows
used to allow.

## What is deliberately out

**Appearance.** The core carries no colors. The client keys a projectile's
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

No *base* weapon bounces, splinters, stalls or pushes -- every one of those
arrives as an add-on out of the kit and composes onto whichever rung the
trigger is on. So a pilot who spent nothing there fires a plain bolt, and a
pilot who spent one point fires a bouncing one.

The bolt and the shell do carry a `bounces` of 255 while their `on_wall` is
still `end`, which is not an exception to that: a budget is spent only once
something is bouncing, so the number is inert until the add-on flips the field
beside it. It is there to say how far the add-on goes when it does arrive, and
255 is this table's way of writing "until the round runs out".

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

## Measuring it

Every number above is a choice, and most of them came from the original's
settings rather than from anything this game has observed. `vectorwake-server
calibrate stages` puts a price on them: one hull, the same pilot on both sides,
and one stage of the tree as the only difference between two ships. It reports a
win rate per stage, so changing a rung or an add-on's cost is a change with a
number either side of it. The server's README explains how to read the report,
including the control row it measures its own noise floor from.

It answers what a rung is worth against a bare hull and against another rung. It
does not answer what a weapon feels like, and the numbers it produces are only
as good as the bots' willingness to use the thing being priced, which is why the
report counts trigger pulls per stage: a rung nobody fired and a rung that lost
are different findings that look identical in a win column.
