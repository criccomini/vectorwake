# Zones

Five games, in one catalog, on one engine.

| Zone | What it is | Room | Scored in |
|---|---|---|---|
| Team Battle | Three minute 4v4 melee | 8 seats, 5 maps | kills |
| Turf | Six stands that pay whoever holds them | 8 seats, 3 maps | turf |
| War | Four flags, a round to whoever holds the set | 8 seats, 3 maps | flags |
| Duel | One against one on small ground | 2 seats, 3 maps | rounds |
| Free Roam | A thousand tiles, no clock, greens | 64 seats, 1 map | nothing |

Team Battle is [match-game.md](match-game.md)'s and came first. The other four
were built together, and this document is what they are and why each one is
shaped the way it is. The engineering decisions behind them are records
[129 to 132](../architecture/decisions.md).

## Where a zone's rules live

Subspace ran hundreds of distinct games for thirty years without zone owners
modifying the engine, and it is worth being precise about how, because the
folklore version ("it was all SERVER.CFG and bots") hides the actual split.
Three layers carried it:

1. **SERVER.CFG** held the numbers: physics, weapons, prizes, flag timers.
2. **The engine** held mechanisms with no opinions: flags could be carried,
   prizes could be picked up, and nothing in the physics knew what winning
   meant.
3. **The bots** held the meaning. A league zone's rules were thousands of
   lines of zone-specific bot code, and "no engine modifications" really
   meant that the per-zone game logic lived outside the engine, not that it
   did not exist.

vectorwake has the same split, with the third layer moved somewhere it can be
tested:

1. The **catalog** is our SERVER.CFG. A zone declares its mode, maps, sides
   and caps, and overrides any `sim_settings` field. See
   [architecture/catalog.md](../architecture/catalog.md).
2. The **simulation core** is the mechanism layer. It moves flags, puts greens
   on the ground, reports who holds what, and refuses to know what any of it
   means.
3. **Modes** in `server/src/modes.rs` are where the meaning went: small
   compiled Rust behind the `Mode` trait, watching the state a tick produced,
   writing the banner, keeping the score, and saying when a match opens and
   closes.

Every zone below decomposes along that split, and building four of them added
two modes, five settings and one entity to the core. The duel took a third
mode afterwards, per
[decision 142](../architecture/decisions.md#142-a-duel-is-rounds-and-two-of-them-take-it),
which is still meaning in the mode layer rather than anything the core had to
learn. Nothing needed a new
layer, and [decision 6](../architecture/decisions.md#6-zone-modules-are-sandboxed)'s
sandboxed module runtime stays superseded.

## What the four cost the engine

Worth stating plainly, because it is the argument against generalizing early.
Four games, and the whole of what the core had to grow:

- `flag_carry`, one byte, deciding whether taking a flag picks it up. That is
  the entire difference between War and Turf.
- `flag_carry_ticks`, so a carried flag comes down on its own.
- `sim_green`, six fields, and the five settings that place them.
- One event, `SIM_EV_GREEN`.

Everything else was configuration, two modes, and maps.

## Turf

Six stands down the long axis of the map. Flying over one claims it; it then
settles for two seconds before it can change hands again. Every five seconds
each side is paid a point for each stand it is holding, and the match belongs
to whoever has the most when the clock runs out.

The payout is the design. Holding two stands of six is not a losing position,
it is two points every five seconds, so a side that gives up the middle and
keeps its own half is playing a real strategy rather than waiting to be beaten.
It is also what stops the game collapsing into one scrum: a scrum wins one
stand while the four it left pay somebody else.

The settling window looks like a detail and is not. Without it, two pilots of
opposite sides sitting on one stand take it from each other a hundred times a
second: the pennant strobes, and which side the clock happens to pay is decided
by the tick the payout lands on rather than by the fight.

Six stands and four a side is deliberate. Two more stands than either team has
pilots means nobody can cover the map, which is the pressure the whole game
runs on.

## War

The classic flag game, named for the original's War Zone. A flag can only be
taken from a side that is not yours, it rides whoever took it, and it drops
where they die. Hold all four for ten seconds and the round is yours; the flags
go neutral and back on their stands, and the next round starts.

Two things are ours. A carried flag comes down on its own after thirty seconds,
because without that the other side's only answer to a runner is to kill them,
and a hull built not to be killed turns a four flag round into a three flag
round nobody can finish. Home to home on these maps is about twelve seconds, so
thirty is two crossings: long enough to bring a flag to where your side holds
the others, short enough that staying alive is not the whole strategy.

And there is a match around the rounds: four minutes, scored in rounds taken.
A room that ran rounds forever had no score, no clock beside the deploy key, no
ending board and no reason to change ground, which made it the one game in the
catalog a player could not read from outside the room.

## Duel

One pilot against one, one kill a match, on ground ninety-six tiles across.

The rooms hold two seats and that is what does the matchmaking. A client
prefers the fullest room below its cap, which for a room of two means the one
with somebody waiting in it; a pilot who finds nobody opens a room and becomes
the person the next arrival is put beside. This is the pairing rule
[decision 92](../architecture/decisions.md#92-duel-is-two-pilots-and-the-door-decides-which-two)
built a matchmaker for, falling out of the fill ladder for free.

The maps are why this is a zone rather than a line in the melee file. Two
pilots searching a hundred and sixty tiles for each other is a draw, which is
what a 1v1 on melee ground measured as. These are four to six seconds home to
home rather than twelve to fifteen, so the fight starts at the whistle and
restarts after every death.

None of the three holds a wormhole. A warp sends whoever touches it back to
their own start, which on ground this small is a way out of the only fight in
the room, and its thirty-eight tile field covers most of a ninety-six tile map
besides. See
[decision 138](../architecture/decisions.md#138-a-duel-is-too-small-to-hold-a-wormhole).

It is played in rounds and one of them takes it. A death ends the round, and
two seconds later both pilots are back on their own starts with a full bar and
a full rack. The three minute clock is the backstop: the leader takes it and
level is a draw. That two second window is the trade rule, and it is also the
respawn delay, so a bomb thrown by a pilot who is already dead still lands and
the round goes to both of them.

A trade is why the round survives even where one of them is the whole match.
The match wants a leader rather than a number, so two deaths inside the window
give both sides a round, neither leads, and it plays on to two-one. That is what
a first-blood duel could never do and the reason
[decision 142](../architecture/decisions.md#142-a-duel-is-rounds-and-two-of-them-take-it)
set the count at two; the window turned out to be the part doing the work, so
[decision 145](../architecture/decisions.md#145-a-duel-is-one-kill-and-the-room-deals-you-a-rival)
moved the count back to one. The score is rounds taken, read off the other
side's deaths, so flying into a wall hands the round across the arena instead
of taking a point off your own.

A short match is also the unit a rival is dealt on. Fly three of them against
the same person and the room asks the population for somebody else, near their
strength and not one of the last few it has had, so an evening in here is
several opponents rather than whichever pilot the fill happened to seat first.

The match is between the two seats, so a seat changing hands is a new match:
whole clock, nothing on the board, both pilots home. An arrival lands across
from whoever is already there. That is
[decision 141](../architecture/decisions.md#141-in-a-duel-the-door-is-the-whistle).
Without it a person at the door was put into the match the room's bots were
having, and shown its score at the whistle.

Pairing two people by rating is not here. That needs a band and a queue and is
a decision to take on its own. Choosing which bot you are put across from needs
neither, because every candidate already exists, and that is
[decision 145](../architecture/decisions.md#145-a-duel-is-one-kill-and-the-room-deals-you-a-rival).

## Free Roam

One map a thousand tiles square, sixty-four pilots, eight sides of eight, no
clock and no score. You arrive, you fly, and the room is still going when you
leave it.

What replaces the match as a reason to keep flying is the greens. A pilot
starts on the build they chose, the same as anywhere else, and grows over a
life: a prize is a step of energy or a rung of gun on top of what they own, and
it lasts until they die. That last part is free rather than designed, and it is
the nicest thing about how greens are built. A green fills a slot in the kit
space; a respawn deals the pilot's own build again and a green never touched
it, so death returns you to what you own with no rule written anywhere.

Two dozen are out at once, in a ring six to twenty-eight tiles from a live
ship. That ring is the whole design, and [maps.md](maps.md) records why:
scattered by area, two hundred greens over a million tiles is one per five
thousand against a pilot who sees sixty, and the zone that ran that way read to
its players as having none at all. Outside six tiles so a green is a trip
rather than a gift, inside twenty-eight so it lands on the radar of the pilot
it appeared for.

The weights are stats-heavy, which is what Alpha Zone's own settings file is: a
green is mostly one more step of something you already have rather than a new
capability. That is what makes growth feel like a slope instead of a series of
unlocks, and it is what stops a pilot who has been alive four minutes flying
something a new arrival cannot fight.

## What we did not build

**A module runtime.** Four games needed two modes and five settings between
them, and rounds took a third mode later. That is no argument for an ABI, an
authoring system and a sandbox.

**A mode-aware client.** The client reads the catalog's format strip, draws
pennants and greens off the wire, and gets the match clock from `match_state`.
Turf and War needed no client change at all beyond the strip; greens needed one
accessor, one drawing function and a sound that was already in the kit.

**Rating-banded matchmaking.** See Duel above.

**Objective bots.** The brains already went for flags, and a small fix was
worth making: a flag another side is carrying is no longer skipped, because in
a game whose round is who holds the set, the flag being run off with is the one
that decides it. What is still missing is defending a stand you already hold
and sitting on a point rather than drifting off to fight. That is the largest
open item on this list.

## What a zone costs after it ships

Each row in the catalog brings more than a mode:

- **A ladder of its own.** A rating is filed under the zone's key, per
  [rating.md](rating.md), so a new row in this catalog is a new ladder that
  every pilot on the fleet starts unrated in. That is the right answer, since
  the games measure different things, and it does mean a zone needs enough
  traffic to get people out of provisional or its ratings say nothing.
- **A bot population that plays the objective.** At our population a zone
  without one is a dead room.
- **A balance surface.** Every mode is a new answer to "which hull wins here".
  Turf, War, Duel and Free Roam are all flying the roster Team Battle was tuned
  for, and none has been measured. They fly it because the tuning is the
  core's: a zone file says what makes it that zone and nothing else, so a room
  that wants a different ship has to say so and be seen saying it.
- **An arena process.** One per declared zone, which is now five, with the
  services, routes and firewall ports that go with them.

This is the honest brake on the list growing. Team Battle got good by being the
only game; five zones divide the population and the tuning attention five ways.

## Where to look next

In rough order of what would move the needle:

1. **Measure them.** `calibrate` and the melee probe are built for one format.
   Turf and War have new answers to which hull wins, and nobody has asked.
2. **Bots that hold a point.** `Mode::Travel` arrives at a flag and then
   re-decides, so a bot that reaches a stand has no reason to stay on it.
   The design for this and the rest of objective play is now in
   [ai-players.md](ai-players.md).
3. **A green worth reading.** Every green draws as the same diamond, because a
   pilot deciding whether one is worth the trip is deciding on the trip. If
   that turns out to be the wrong call, what a green holds is already on the
   wire.
