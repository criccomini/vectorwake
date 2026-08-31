# Weapons

> **Two parts of this changed.** [match-game.md](match-game.md) removed greens
> entirely, keeping the upgrade space below as the coordinate system a build is
> written in. What the pickup, its weights and rust were is in `docs/research/`
> with the rest of the original's tables. Mines are gone as well; decision 62
> says why, and the original's own tables for them stay in `docs/research/`.
>
> Nothing in that space is rolled for now. A pilot spends seven credits over
> it, in whichever hull they are sitting in, and the hull has no say in any of
> it; see [ships.md](ships.md).

Everything that leaves a ship is the same thing.

Not "a bullet and a bomb, plus special cases". One model, two tables, and
every weapon this game will ever have is rows in them. A burst, a spread,
shrapnel, a repel, a bouncing bomb, a round that freezes your recharge. None
of those is a feature in the core. They are numbers.

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
  delay     cooldown ticks        trigger      px from a hull that counts as arriving
  recoil    kick on the shooter   expire_ends  whether running out counts as arriving
                                  splinter     a pattern fired where it ended
                                  damage       energy at the center
                                  blast        px of falloff; 0 lands on one hull
                                  push         px/tick shoved outward
                                  push_time    ticks the shove outruns a hull
                                  stall        ticks of suppressed recharge
```

A `delay` is a cooldown on whatever fired the pattern: a trigger's clock when
a trigger fired it, and the charge kind's own when a charge did.

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

That order is the model. Every difference between a bullet, a bomb and a
fragment is a number read during those four steps rather than a branch between
them.

**Running out is not arriving.** A bomb that crosses the arena untouched and
expires at five seconds has *not* got anywhere, so it does nothing -- that is
what a player means when they say a bomb that times out should not splash.
A round whose whole life is a timer asks for the opposite, and `expire_ends`
is how it says so.

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
so it is a rosette. Sixteen for the price of one trigger pull, and a `delay`
that shuts the key behind it: see [charges](#charges).

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
slot in the build that swaps which pattern the trigger points at. See the tech
tree below.

## Writing one

A zone file names weapons; the core numbers them. The baseline builds one gun
and one bomb for the whole room and they get the names an operator would
guess, so tuning one is two lines and does not touch the rest of it:

```toml
[[arena.weapons]]
name = "bomb"
on_wall = "bounce"
bounces = 3
```

That reaches every pilot in the room, because there is one bomb: a hull is a
flight row and the weapons are the arena's.

The weapons that belong to a settings slot rather than to a trigger are named
for what they are where the baseline fills them, `repel` and `burst`, and for
the slot where it does not: `charge-3` and `charge-4`, and `shrapnel-1` up, one
per rung of the add-on. Naming a charge slot the baseline leaves empty makes
the weapon and fills the slot in one block.

Any *other* name makes a weapon that did not exist, which another weapon can
splinter into or an empty charge slot can hold. Order in the file does not
matter, since names are all collected before any of them are resolved:

```toml
[[arena.weapons]]
name = "bomb"
splinter = "shrapnel"

[[arena.weapons]]
name = "shrapnel"
speed = 1200
life = 40
damage = 50
count = 8
spread = 45          # a full turn over eight, so a rosette
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

A level is *the same weapon, harder*: a rung on a ladder of patterns the arena
holds, and climbing it swaps which one the trigger fires. An add-on changes
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

One shape, four meanings. A slot is one byte naming a place in that space:
five stats, then a level per trigger, then an add-on per trigger per kind, then
a charge apiece. A hull carries a row of twenty-three of them and that row is
the ship. The flat, one-byte-per-slot shape is left from when a pilot spent
thirty points across it; nobody spends anything now, and the shape survived
because it is a good way to write down what a ship has.

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

Ours is those two ratios per *round* (`mod_multi_energy = 25`,
`mod_multi_delay = 50`), because we have a ladder and the original did not.
Their numbers bought two extra rounds, so half of each is what one round costs,
and a spray of three therefore lands exactly where SVS put it. Every rung above
that climbs at the same rate, linear like every other add-on here.

The base gun energy is multiplied by its gun level, as SVS does. Before any
spray, a level-one shot costs 20, level two costs 40, and level three costs 60.
The harder bullet therefore asks for more of the same bar it is trying to take
from its target. That is `BulletFireEnergy` times the level, and the damage
climbs beside it: `BulletDamageLevel` 200 with 100 a level, so 200, 300, 400.

The damage number is a ceiling. SVS left exact damage off for bullets, burst
rounds, and shrapnel. Vectorwake keeps that curve's mean without its variance:
every hit deals a fixed two thirds of the listed value. Bomb damage stays exact
before blast-distance falloff.

**A second barrel is one rung of spray.** `DoubleBarrel` was a per-ship setting
and the Terrier alone carried it: two rounds abreast for one pull where every
other ship sent one. It became an add-on of its own here, and then stopped
being one: it and multifire were two ladders that both meant more bullets, and
nobody could say what the difference bought. Spray is the ladder, its rung is a
round, and one rung is the pair the Terrier had.

What survives of the difference is the spacing. One rung leaves at
`mod_pair_spread`, which is tighter than the fan, so two abreast still read as
two abreast; three or more open out to `mod_spread`. The original charged
nothing at all for `DoubleBarrel`, which was defensible while one hull had it
and could not choose otherwise; as a rung a pilot buys, it pays like every
other round.

The arithmetic is the part worth keeping. Spray *adds* rounds rather than
multiplying them, so the ladder reads as a count: three rungs is four rounds,
not eight. That was the Terrier's real behavior, and here it falls out of the
model instead of being written down for one hull.

The rate never moves. `BulletFireDelay` is 25 whatever the level and whatever
the hull, so a rung buys the size of one arriving hit and never a second gun.

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

What the space can hold, which is what the core's own maxima allow rather than
a row any zone writes: a weapon climbs to `SIM_MAX_RUNGS`, an add-on to
`SIM_MOD_MAX`, and spray to `SIM_MOD_MULTI_MAX`. A build is clamped to those
where it is dealt, so a client asking past them gets the ceiling rather than a
refusal.

**Availability follows the original, and so do the ceilings now.** `MultiFire`,
`BouncingBullets`, `Proximity` and `Shrapnel` appear nowhere in the original's
per-ship config: they are `[PrizeWeight]` entries any ship can be handed, and
its per-ship section is a flight row. Ours is one row of ceilings for the whole
arena and seven credits to spend inside it, which is the same claim: what you
carry is what you found, or here what you bought, and never what you are
sitting in.

The per-ship counts it does keep are `MaxBombs` (3 on the Leviathan, 2
elsewhere), `ShrapnelMax` (8 everywhere, 31 on the Shark), `BombBounceCount` (1
on the Lancaster alone) and `DoubleBarrel` (the Terrier alone). Those four were
a row per hull here too, twice: once as the roster's own traits and once as an
arena ceiling with everything below it for sale. Neither survives. A hull is
how it flies, the ceilings are the room's, and the shrapnel belongs to whoever
spent a credit on it. What a pilot arrives on is in
[ships.md](ships.md#the-build).

The barrel is on the matrix now, inside spray. `DoubleBarrel` was the one
weapon setting with no home in this space, being neither a ladder nor an
add-on, and it stayed a flag on one hull for exactly as long as that was true.
It became `SIM_MOD_BARREL` for a while, and then stopped: it and multifire were
two ladders that both meant more bullets. `SIM_MOD_MULTI` is the ladder, its
rung is a round, and one rung is the pair. The pair's tight spacing is all that
survives of the second add-on, and where a pilot stands on the ladder decides
whether the group reads as a pair or as a fan.

| | rungs above the first | add-ons |
|---|---|---|
| **gun** | 2 | multi ×5, bounce, freeze |
| **bomb** | 2 | prox, shrapnel ×3, bounce ×2, freeze |

That is the space, and it is what the core can express rather than what any
build holds. The arena's own ceilings sit inside it: spray to five, shrapnel to
three, one wall of bounce on either trigger, and no fuse on a gun.

**Freeze and push are the exception**, and the only part of this table that is
ours: the original has no such upgrade, so there is nothing to copy. Freeze
hangs off both triggers, because stalling a recharge is a thing a hit does and
the core reads it off whichever trigger's add-ons carried it. Push is unused
until the shove has had a look of its own, so its ceiling is zero.

The names a player reads are not these. `multi` is **spray** on the ship page;
the words in this table are the core's, and the core's are what a zone file
writes.

**A trigger's add-ons stay a trigger's.** Bullets do not carry a fuse and do
not break up, because a bullet with a proximity fuse is a bomb and that weapon
already exists. Bombs do not fan and do not come in pairs, because a rack that
throws three at a pull is a different game. Those four are zeroes in the
arena's row, and a zero is a slot that does not exist: no hull can carry it and
no zone can write it.

The other way a weapon goes missing is having **no rack**. An add-on is a
transform on a trigger, and a trigger that does not exist cannot be
transformed. The Cipher is the roster's one hull with no rack, so this is a
fact about a shipped ship rather than a rule held in reserve.

**Charges are not on this matrix**, and that is the original's rule rather than
an omission -- see below.

A rung is 40% more damage and costs the same to fire. The shipped ladder is
the original's instead: 200 damage and 20 energy at the first rung, 100 and a
whole `BulletFireEnergy` more at each one above it.

### A build is a row of these

Nothing rolls. A pilot spends seven credits over the space above and the ship
is dealt that row whole at every spawn: rungs, add-ons and charge counts. That
row is why the space survived the pickup being deleted: it is still how the
core writes down what a ship has. [ships.md](ships.md) has what a pilot arrives
on and [match-game.md](match-game.md) has why nobody hunts for it.

Two properties the pickup used to provide are structural rather than tuned. A
ship cannot hold what the arena has no ladder for, because the row is clamped
where it is dealt rather than rolled at a pad. And what a death costs is the
walk back, because the frame comes back whole.

**Charge counts are the exception, and the only one.** They come back at the
start of a match and never at a spawn, so a repel spent in the opening joust
is a repel gone for three minutes. Refilling them on death would mean a pilot
out of repels could suicide into the nearest enemy to reload, and dying costs
nothing but the walk.

### Charges

A charge is a weapon you carry a count of and spend: a repel, a burst. It
needed no new mechanism at all -- it is a pattern, exactly like a gun's, plus
an inventory. The repel is `push` with no damage, which the model has been
able to express since the day it was written; the burst is sixteen rounds at a
full turn's spacing, the rosette that motivated `count` and `spacing` in the
first place.

Four slots, zone-wide, so slot two means the same weapon for everybody. Two of
them ship filled; a zone is free to write the others.

**Everybody may carry three of every charge.** That is the original's rule:
`RepelMax`, `BurstMax`, `DecoyMax`, `ThorMax`, `BrickMax`, `PortalMax` and
`RocketMax` are all 3 on all eight of its ships, and every ship starts holding
none of them. Charges are not a roster trait there; they are loot, and the
hull does not gate them.

How many of which kinds is the pilot's, and two kinds is the ceiling:

- **Two, because a keyboard has two keys for them.** The rack holds four kinds
  in the core, so a zone may fill a third slot; the shipped arena does not, and
  it refuses a build that carries three. See
  [ships.md](ships.md#the-build).
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

Charges do not share the gun and bomb firing clock. A pilot may spend one
during a weapon delay or on the same tick as a shot. That half is deliberate:
a repel answers a round that is already arriving, and a repel you cannot throw
because your guns are hot is not an answer to anything.

**Each kind keeps a clock of its own, though, and the burst's is a second and
a half.** It used to keep none, and inventory turned out not to be a limit at
the scale a hand works at: three presses is a tenth of a second, the burst
costs no energy, and three rosettes from one standing position is seventy-two
rounds, of which three end anybody. What that asked of a pilot was one
approach, and the second and third bursts asked nothing the first had not
already asked.

The clock does not change what a burst does, and it is deliberately short. A
second and a half is the bomb's own delay, the longest wait any weapon here
asks for, and it prices the cadence rather than the fight: emptying the rack
takes three seconds where three presses took a tenth of one, so the bursts are
flown between and aimed separately, and all three are still available inside
the exchange the first one was thrown into. Pushing the next burst into the next
fight would take several times this, and that is a different rule about what a
rack is for rather than a longer version of this one.

The repel has no delay, which is the reason the clock is per kind rather than
one over the rack. It does no damage, chaining it only wastes it, and shutting
it because a burst had just gone would take the answer away exactly when a
pilot wants it.

The wait is the pattern's own `delay`, so it is the arena's to set like any
other weapon number, and the ticks left ride in the owner-only tail of a
snapshot: the clock is set at a press that may be older than the tick a
snapshot starts from, so a client that could not read it would predict a key
the zone has shut. The corner rail and the touch pads wash a kind's row down
when its key shuts and bring it back as the clock runs out, so a key that does
nothing looks like one.

### A loaded opening is a choice, and it flattens skill

Every ship spawns carrying its pilot's whole build, which is a loud opening on
purpose.
That is the strongest single lever in the tuning. Running the bot calibration
ladder over a 48-round round-robin, same hull, three pilots at skill 0.15, 0.50
and 0.95, the kills came out:

| | low | mid | high |
|---|---|---|---|
| nothing dealt | 93 | 102 | **187** |
| thirty dealt | 313 | 290 | 299 |

A two-to-one skill gap becomes flat, and the total number of kills triples.
With everyone carrying spray from the first second, time to kill collapses and
the fight is over before flying it decides anything.

That was measured when a ship was dealt thirty random greens, and it did not
move when the thirty became a chosen kit, and it does not move now that seven
credits are the pilot's: the flattening comes from how loaded a ship is at the
whistle, not from where the load came from. It is a choice for a game that
wants its openings loud. The offline calibration in `server/src/calibrate.rs`
strips the build for exactly this reason, because a ladder has to be able to
rank pilots.

### Writing a tree

Rungs above the first are named for their level, so a zone tunes them the same
way it tunes anything else, and the ceilings are one section:

```toml
[[arena.weapons]]
name = "bomb-3"           # the third bomb rung, which anybody may climb to
blast = 96

[arena.mod_step]          # what one rung of each add-on is worth
freeze = 250              # ticks
prox = 24                 # px of fuse

[[arena.ships]]           # and what one hull carries
name = "Anvil"
gun_mods = { }            # a plain heavy round
bomb_mods = { }           # and a plain wide bomb
charges = [3, 1]          # three repels, one burst
```

A hull left out of the ships list keeps the baseline's row for it, so a zone
overrides one ship without restating the other six. An add-on left out of a
`gun_mods` or `bomb_mods` table that names any is zero on that hull, which is
how "this ship's bombs do not fan" gets said.

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

Two ladders for the whole room, built in `sim/src/baseline.c`: three bolts and
three gun patterns, three shells and three bomb patterns, and every hull is
handed the same six indices.

No *base* weapon bounces, splinters, stalls or pushes. Every one of those
arrives as an add-on out of the pilot's build and composes onto whichever rung
the trigger is on, so two pilots in the same hull can fire a plain bolt and a
bouncing one.

Both start at a `bounces` of 0, so a rung of the add-on buys exactly one wall
on either. The bolt carried 255 for a while, which is more than its life can
spend and made that one credit a corridor where every miss kept hunting.

And the table is the zone's, not the client's. A zone sends its whole weapon
table to every player as it joins, so a client predicts and draws the weapons
that zone actually has rather than the ones its own build compiled. That is
what makes a new weapon content: a spec is an index, and a client guessing at
its own table would not even agree on what an index means.

Firing costs are the original's outright: 20 for a bullet and 300 for a bomb,
against the 1700 energy it gave every ship. Pricing a shot off its damage
instead, which is what this did first, made a bullet cost 35% of a full bar and
a bomb 63%, so the bomb key did nothing at all unless you had been left alone
to recharge, and silently.

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
