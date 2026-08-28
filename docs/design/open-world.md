# The open world

> **A proposal, and nothing here is built.** The game running today is the
> three minute match in [match-game.md](match-game.md). This document argues
> for replacing the match as the whole of the game with a persistent world you
> fly around in, and it argues for keeping the match inside that world as a
> place you can go. Decision 95 is the record; this is the reasoning.

## What the match game fixed, and what it left alone

Six gripes drove the match game, and it answered five of them well. A session
has a shape now. You own your kit and a death cannot take it. Bounty pays,
rivets buy, the rating means something. Those are real and none of this
proposes undoing them.

The one it answered by deletion is the first: *you land in the arena and there
is no obvious point.* The match answered it by removing the arena. There is
nowhere to land any more, only a room that starts a match at you, and the point
is the scoreline. That works, and it is also the reason the game is a twitch
shooter and nothing else. Everything a player does in a session is aim.

The question this document takes seriously is whether the arena was the problem
or whether an empty arena was.

## The loop

**Undock light. Fly out. Come back heavier, or lose what you were carrying.**

That is the whole game, and everything below is a consequence of it.

You leave a shipyard with a hull, a kit and nothing in the hold. What you find
out there is money. While you are carrying it, it is at risk: a pilot who kills
you takes it, and so does anything else that kills you. When you dock, it is
banked and nothing in the game can take it again. Then you spend it on the
shelf that is already written, and go out again with a better ship.

The decision the player makes over and over, and the one the match game does
not have anywhere in it, is **when to turn around**. Fly home at twenty and the
trip paid for a rung. Push to two hundred and the trip pays for a hull, if you
live. Nobody sets the difficulty; the throttle does.

## Greens are money, and money has a position

Greens come back, as currency and only as currency. A green is never a weapon
upgrade, never a stat, never anything a ship is. Pick one up and you are richer
and your ship is identical.

That separation is the load-bearing change, and it is what the old greens got
wrong. In the original, and in Alpha here, a green was both money and power,
which made a pilot's strength a function of how long they had been alive and
how lucky they had been. Gripe 3 was that exact complaint. The kit answered it
by choosing your thirty upgrades in the hangar, and the kit stays: what you fly
is what you bought and chose, dealt fresh at every spawn, the same in your
first minute of a life as in your tenth.

So why bring greens back at all, when rivets already work? Because a rivet has
no position. It arrives at a kill, it lands in a wallet, and the only place it
exists is a number on a page. A green sits somewhere. You can see it, fly at
it, get there first, or die on the way. A currency you have to go and get is
the cheapest possible reason for the world to have geography, and geography is
the thing this game deleted when it went to symmetric 144 tile rooms.

That is the Zelda part, and it is worth being precise about which part of Zelda
it is. It is not swords or hearts or a story. It is that the world is the
content: you go somewhere because there is something there, you can usually see
the thing you cannot reach yet, and the map in your head is the progression.

## What killed greens last time, and what has to be different

`maps.md` already records the failure and it should be read before anybody
places a single green.

Alpha scaled the count with the map: twenty prizes over eighty tiles became two
hundred over a thousand, which raised the ceiling to the wire's own 255 and
still produced nothing. Two hundred greens over a million tiles is one per five
thousand. Measured against the live arena it came to a mean of two inside the
whole interest radius and none within sight for the length of a session. A
player said "war zone seems to have no greens," and they were right, in the only
sense that matters.

The fix that shipped was to spawn a green in a ring six to twenty eight tiles
from a live ship, so the money follows the player. For a match that is correct.
For this it is exactly backwards: a currency that comes to you is not a reason
to go anywhere, and it turns the world back into wallpaper.

**Greens here are placed, in fields, at kinds of places a player can learn.**
Not scattered by area and not spawned near anybody. A dozen or thirty of them
together, in a salvage field or around a wreck or where something died, so that
finding one means finding a haul and so that "the field past the shoal pays
well" is a sentence a player can say to another player. Density inside a field
is what makes it worth flying to; emptiness between fields is what makes it a
trip.

## Where money comes from

Three sources, and they should not feel alike.

**Salvage fields** are static, respawning and safe. Low pay for the time. This
is the floor a bad session cannot fall through and the thing a brand new pilot
does in their first two minutes without being shot at. Zelda cuts grass.

**Kills** pay what the victim was carrying, on the ground, as greens. Not
credited invisibly to the killer: dropped where they died, for whoever gets
there. That single rule does more work than anything else in this document. It
makes a loaded hauler the most valuable target in the game, which is precisely
what [bounty.md](bounty.md) has always wanted and has only ever been able to
say with a number over a hull. It makes a kill a scramble rather than a
scoreline. And it gives a third party a reason to arrive late.

**Hostiles** are the ships that live out there and are not players. They are
where most of the money is, they are the reason to go into worse
neighborhoods, and they are the entire PvE surface of the game.

## The bots already are the world

This is the strongest technical argument for the pivot and it is not obvious
until you look at what is in the repository.

`ai.rs` is 3,908 lines. `bots.rs` is 3,616. `nav.rs` is 818 and already builds
a 512 by 512 route grid over a full 1024 tile map, held once per map and shared
by every pilot flying it, with a real cost model that puts a route down the
middle of a corridor instead of scraping the wall. Eight behavior profiles
exist, calibrated, with a measured skill dial. A population director already
decides which bots fly, where, and when.

All of that was built to fill empty chairs, and all of it stands down
apologetically the moment a human arrives, because in a match game a bot is an
admission that not enough people are online. In a world a bot is content. The
same navigation, the same profiles and the same director become patrols,
haulers worth robbing, whatever sits on a good salvage field and objects to
being robbed. Nothing about the AI has to be smarter than it is now. It has to
be *employed differently*, and that inverts the most awkward rule in the
current design at no cost.

It also fixes the thing that would otherwise kill an open world at this
population. On 2026-08-17 the fleet had 241 human accounts, 67% of which had
never scored a rated exchange, with a median career of three games among those
that had. Spread twenty of those across 82 seconds of flight and nobody ever
meets anybody. A world has to be populated by something that is always in it,
and this repository already has that something.

## How big, measured

One map. 1024 tiles, which is the core's own `SIM_MAP_TILES` and the size the
original's worlds were. Not a galaxy of stitched sectors, and not "massive."

Every hull at the baseline flies 12.5 tiles a second flat out. That makes the
world **82 seconds edge to edge and about 116 across the diagonal**, against
11.5 seconds to cross one of today's match maps. Two minutes from one corner to
the far one is a real world. It is not a small one.

Size is the cheap part. `sim/tools/worldbench.c` measures it: a world furnished
with rock, N ships all thrusting and firing every single tick, stepped at
100 Hz, with a filtered snapshot packed for every seat at 20 Hz. That is a
ceiling rather than a session, since nobody holds every gun down for twenty
seconds. `make -C sim build/worldbench && sim/build/worldbench` reproduces it,
and these are one run of it on one machine.

| world | ships | ms per tick, budget 10 | per seat |
|---|---|---|---|
| 1024 tiles | 80 | 0.13 | 13.6 KB/s |
| 1024 tiles | 128 | 0.33 | 27.1 KB/s |
| 1024 tiles | 255 | 1.02 | 33.6 KB/s |
| 512 tiles | 255 | 1.29 | 119.0 KB/s |

Two things fall out of that table and both matter.

The core's 255 ship ceiling fits in a tenth of a tick, everybody firing, with
every seat's snapshot packed. Whatever stops this game having a hundred people
in one world, it is not the simulation.

And **the constraint is crowding, not size**. The same 255 ships in a world a
quarter the area cost the same CPU and three and a half times the bandwidth,
because the 84 tile fairness radius means a seat pays for its neighbors rather
than for the population. A big world is not a cost to be justified. It is the
thing that makes a large population affordable.

## Danger is a distance

The world cannot be uniformly dangerous, because then a new pilot has nowhere
to stand, and it cannot be uniformly safe, because then nothing is worth
anything.

**Near a shipyard, nothing can shoot you.** `SIM_TILE_SAFE` exists in the core
already and is described there as no damage, no firing, and the one place you
stop. A shipyard is a field of it.

**Away from a shipyard, the salvage improves and the company gets worse.** That
is the entire difficulty curve and it is spatial. No tiers, no level gate, no
matchmaking bracket, no zone list. The deep parts of the map are worth more and
will kill you, and a player finds their own edge by flying toward it until it
bites. One world holds a first session and a veteran without splitting the
population, which at this population is not a nicety.

The corollary is a map rule: a shipyard is never so close to a good field that
the run home is trivial. What a haul costs is the flight back.

## Shipyards

The shelf is already written. `/v1/upgrades` serves it, the hangar page draws
it, ladders fill in as you buy, and bots read the same reply. A shipyard is
that page, with a door in the world in front of it.

Docking is the only save. Everything you carry becomes rivets in the wallet
that already exists, and everything the wallet buys is what it buys today:
rungs, add-ons, charge kinds, deeper racks, livery, eventually a name. Hulls
join that list, since in a world the ship you fly should be a thing you own
rather than a thing you pick.

Not every shipyard sells everything. This is the cheapest possible content
lever and the most Zelda thing available: the yard that sells the good rack is
somewhere awkward, and getting there is the quest. It costs one column in the
catalog.

## Quitting, and what a death costs

A death costs what you are carrying and nothing else. Your kit, your wallet,
your hulls and everything you have ever docked are untouched, exactly as
match-game.md promises, because those were bought and buying is permanent.
What you had not yet banked drops where you died.

Logging out is the interesting case, and the rule is already written down.
[Decision 38](../architecture/decisions.md#38-a-quit-under-fire-is-a-death)
says a quit under fire is a death.
So: log out clean, and you are still there when you come back, hold and all.
Log out because somebody is shooting at you, and you die and drop it like
anybody else. No timer to tune, no towing rule, no penalty invented for this
document.

## Melee, Team Battle and Duel become places

The version of this pivot that throws away a month of work is the wrong one,
and it is avoidable.

A shipyard is a door in the world that opens a page. An arena station is the
same door pointed at a room. Fly to it, dock, and you are in a Melee: three
minutes, four a side, the podium, the intermission, the whistle, all of it
exactly as built and tuned. Come out, and you are back in the world where you
left, with what the match paid.

That is the shape the original actually had, and it costs almost nothing here
because the room, the fill ladder, the modes and the seating already work. It
also gives the world three finished things to have in it on the first day it
exists, which is the difference between a world with content and a world with
a plan for content.

Duel is the same move: the pairing at the door is already a door.

## What this costs

Honest accounting, because this is a large change and most of the last month is
in the layer it moves.

**Untouched.** The simulation core, entirely; nothing here needs a new tile, a
new weapon or a new rule, only content. Interest management, measured above.
Accounts, wallets, upgrades, ratings, presence, friends. The bot runtime and
navigation. The sky and its weather, terrain themes, rocks, stations. The
client's whole front end: the menu column, the type system, the landing, the
HUD, the pads, the frost.

**Repointed.** `mapforge` keeps making places and stops making whole maps: a
world is authored, its salvage fields and camps are generated. The hangar page
becomes what a shipyard shows. The bot director gets a new job description.
Bounty stops being the only thing a number over a hull can mean, since what a
pilot is carrying is now the honest answer to what they are worth.

**Gone, or changed enough to count as gone.** The match as the whole of the
game: the three minute clock, the intermission, the fill ladder and the room
sort by humans stop being how anybody arrives anywhere, and survive only inside
an arena station. The six point symmetric maps, and the symmetry rule that
generated them, do not describe a world. `sim_restart` loses most of its job.

**The two real questions.** Sides are the first: `SIM_SIDES` is 2, and a world
where every pilot is their own side, or where sides are factions you join, is a
core change rather than a config one. The second is the balance fixture. The
drill harness measures matched 30 point kits in mirrored four a side matches,
and the ten preregistered comparisons are worth what they are worth about that
fixture. They say nothing about whether a fat hauler and a fast interceptor are
a fair fight in open ground, and that experiment does not exist yet.

## Where I would argue with the brief

One word: massive.

The measurement above says size is free, and the same measurement is why size
is a trap. This project has already run the experiment once and written down
the answer, and the answer was a player saying the war zone had no greens. A
large empty map is not a big world, it is a loading screen you fly through.

So the number to design against is not tiles. It is **seconds to the next thing
worth stopping for**. At 12.5 tiles a second, wanting something within fifteen
seconds of anywhere means points of interest roughly every 190 tiles, which
over a 1024 tile world is a five by five lattice: about twenty five places,
plus the shipyards. That is a content budget one person can actually fill, and
it is the number that decides whether this works. Everything else in this
document is cheaper than it looks. That one is not.

## What to build first, in order

1. **A world that persists.** One 1024 tile map, a pilot's position and hold in
   the meta layer, and undock and dock against a safe field. No money yet. The
   thing being tested is whether flying around a large map with other people in
   it is enjoyable for ten minutes with nothing to do. If it is not, stop here.
2. **Greens as money, in placed fields, dropped on death.** The loop, minimum
   viable: find, carry, decide, bank or lose.
3. **The shipyard door onto the existing shelf.** The economy closes.
4. **Hostiles.** The bot director's new job. This is where the game becomes a
   game rather than a hauling simulator.
5. **An arena station onto Melee.** The month of work comes back as a place.

Steps one and two are a fortnight and answer the question the rest depends on.
Nothing above them needs to be decided before they are done.
