# Duel mode

One pilot against one other pilot, one life, first to a single death. Who is
across the arena comes from the door: a person of about your rating where one
is waiting, and a house pilot of about your rating where none is.

Duels matter more than their player count suggests. They are the fastest way for
a new player to learn the flight model without dying to four people at once, the
cleanest signal a rating system can get, and the natural unit for leagues. The
original had a whole dueling league culture around exactly this, and the ASSS
settings still carry a `NearDeathLevel` knob whose documentation says it exists
for dueling zones.

This is the mode that replaced the Ladder, which was the same room and the same
one-life fight with a different answer to who was in it: a solo climb through
eight authored opponents in a fixed order, seated by rung, with progress that
persisted per account. See [decision 92](../architecture/decisions.md).

## Finding an opponent

**At the door, not in a queue.** An arriving pilot is put in the room holding
the nearest-rated person who is waiting, as long as that rating is inside the
band. Rooms still waiting for anybody are preferred over rooms where a bot has
already taken the seat, because taking that seat back costs the pair in it their
fight.

**The band is 300**, about two of the five visible tiers. Wide, deliberately: on
a zone this size the choice is usually between one waiting person and no waiting
person, and a fight against somebody a tier off is a better evening than a fight
against the AI. What the band is really for is the case worth refusing, which is
a Legend and a newcomer meeting because they happened to press play in the same
minute.

**Nobody in range opens a room of their own**, and becomes the person the next
arrival is matched against. That is the same rule read from the other side, and
it is why there is no queue and no widening band: the widening happens because
somebody else arrives, not because a timer ran.

**Ten seconds of holding the seat.** A room with one pilot in it asks for no bot
until the seat across from them has been open that long. Long enough that two
people pressing play within a breath of each other meet, short enough that
somebody alone on the zone is not left looking at an empty room wondering
whether it is broken. The wait is visible: the clock reads dashes and the room
says it is waiting.

**A person arriving later takes the seat from the bot.** That is the eviction
path a room full of AI already had, so the upgrade needs no new machinery. The
fight in progress is voided rather than awarded, which is the same thing that
happens whenever a seat empties mid-fight.

**The opponent is always labeled.** The band beside the clock reads each side's
call sign over their rating, and a house pilot wears the bot mark on the roster.
There is no mode in which the game is coy about this.

## The fight

**Format.** One life. The first death settles it, and the mode refuses any other
value for `duel_first_to`. Each life is the whole decision, then the room gets
the pilots into the next one.

**Both seats are the same kind of thing.** The mode cannot tell a person from a
house pilot and should not: a duel is two ships and a clock, and which of them
has somebody breathing behind it is the door's business. That is the change from
the Ladder, where one seat was a climber and the other was bound to a measured
archetype in a fixed hull with a fixed kit.

**No prizes.** Greens are off. A duel decided by who flew over a Super first is
not a duel, which is also what makes duels a clean rating signal: the variables
are the pilots.

A named house opponent flies the common base entitlement rather than whatever
its own career has banked, and does not shop between fights. Its rating is a
statement about the pilot, so letting a long-lived account's wallet outgrow it
would make the number describe something else. The pair that keep an empty room
playing name nobody, so they fly their careers like any other fill bot.

**A fight starts only when both seats are taken**, on two different sides, and
nobody else is in the room. The match clock waits at its full value while the
second seat is empty.

**A seat that empties mid-fight voids it.** The room files no result, pays no
completion reward, and moves no rating. Both ships reset before the same pairing
reopens against whoever the door sends next. A fight already decided is the
exception and is filed rather than voided: see the two seconds below.

**The whistle settles a fight the pilots did not.** Whoever is ahead takes it,
and a fight nobody has scored in is a draw: it is logged as one and breaks no
streak. Two pilots who spend three minutes refusing each other have said what
they have to say.

## The last two seconds

A duel is not filed on the death that decides it. The arena runs for two more
seconds, and if the other ship goes down inside that window the fight is a draw
rather than a win.

Two seconds is a bomb's flight, which is the exchange the window is there for.
Firing into somebody at close range and taking their last shot on the way past
is a trade, and a trade is a draw: the pilot who died second is as dead as the
one who died first.

It is also the zone's respawn delay, so the pilot who went down is still down
when the fight is filed. The whistle cannot cut the window short either. A kill
in the last second of regulation is as tradeable as one in the first, so the
clock running out inside a window neither ends the fight early nor takes the
draw away.

A seat that goes away inside the window does not void the fight the way a seat
that goes away mid-fight does. Whoever left had already lost it, and the only
thing the window could still have done is draw it, which needs both pilots on
the field. So the result is filed, on both cards, naming both pilots. The pair
a fight is between is captured when it opens rather than read back off the
seats, because one of them may be gone by the time it is filed.

Calibration does not draw. It flies each leg to a death, with a recorded safety
boundary so a broken or nonterminating leg cannot run forever, because the
question it asks is which pilot wins when the fight is played out, and stopping
at the whistle would throw away exactly the matchups that are hardest to call.
Any leg that reaches that boundary blocks certification; live play itself
remains uncensored.

## The card

Each seat keeps its own evening: the current streak, the longest streak it has
had here, how many fights it has finished, and the last five of them by name,
result and duration.

Per seat rather than per room, because a duel has two pilots in it and each of
them has their own evening. That makes the duel body the one message in the
protocol whose bytes differ per recipient. The old Ladder held exactly one card
per room, which worked only while the other seat was guaranteed to be a bot
nobody was drawing a card for.

The window is fixed at five and the count says what fell off the end of it, so a
long evening reads as its recent stretch plus an honest number rather than as a
short one. A void fight is not a leg: a pilot who leaves mid-fight files no
result, and a log that recorded it would be a log of things that did not count.

A card belongs to the pilot who flew it. It goes with them when they leave, so
the next person into that seat starts empty and nobody inherits a stranger's
evening.

The client draws the card under the roster, behind the same toggle, newest fight
first. The ending draws it too, with the readings over it.

## Duels against AI

A rated duel against a bot moves your rating exactly as a duel against a human
does, because bots are rated on the same scale and anchored to a fixed reference
personality. That is the mechanism that lets a player on an empty server still
find out how good they are.

The safeguards from [rating.md](rating.md) apply unchanged: beating a bot far
below you returns nearly nothing, and the share of daily rating gain that can
come from AI is capped once you are above the bot population.

**Chosen by strength.** The arena asks the director for the authored archetype
whose rating is nearest the waiting pilot's. Where a certified tournament has
measured the roster, that is the measured number. Where it has not, it is a
provisional curve derived from the authored competence and shifted to pass
exactly through the anchor's defined rating, so the guesses sit on the same
scale as the live numbers.

A near miss is a slightly uneven fight rather than a wrong answer, so the room
seats whoever turns up. The Ladder bound that seat to one pilot in one hull with
one kit, because a rung meant nothing if the pilot on it was not the pilot the
tournament measured. A duel wants an opponent of about the right strength.

**A pilot nobody has measured reads as the middle of the scale**, which is where
the anchor sits, so their first opponent is the reference personality and their
first few deaths move them fast enough to find their level in an evening.

The director has 1,024 persistent identities for each archetype so concurrent
rooms never reuse one account. Those replicas have distinct IDs and call signs
but the same controller, hull, behavior, competence and build.

**The game never weakens or strengthens a pilot during a fight.** No hidden aim
change follows a hit, a death, or a low-energy moment. Adaptation happens only
at the opponent boundary.

## A duel is always on

The play page joins the zone under the cursor as a watcher, so the match behind
the menu is the match pressing that row would put you in. A zone nobody is
playing is therefore an empty arena on the screen of everybody deciding whether
to press play, which is an argument against pressing it.

So a duel room with nobody in it fights anyway. The director seats two house
pilots and they fly the same one-life duel a person would. Neither of them names
an archetype: it is a demonstration rather than a match, and drawing them from
the whole roster keeps the menu from showing the same two pilots every time
somebody looks, and keeps a demonstration from moving the pilot the whole rating
scale hangs off.

They are holding the room, not keeping it. A person walking in takes it back on
the tick they arrive, both bots stand down, and the arriving pilot gets a fresh
fight rather than half of one they did not join.

One room does this, the zone's first, which is the room that outlives all the
others and the one a browsing client watches. A second room opens because people
arrived and is given back when it empties, and a room with bots flying in it
never empties.

Nothing about them is durable. A bot beating a bot moves no rating.

## Persistence

Nothing about a fight is durable except its effect on rating, which lives in
`ratings` with every other class and reaches the meta-layer through the ordinary
rated settlement path.

That is the whole of it now. The Ladder kept a rung and a best rung per account
per Ladder zone, in its own table, carried in the signed session claims and
projected out of completed match events; the exclusive-lease release barrier had
a second half whose only job was to land those rows before a reconnect could
read them stale. All of it is gone with the rungs it measured. The rating half
of that barrier stays, because the same read-after-write hazard applies to the
number that is left.

A card is one sitting in one seat and does not outlive either.

Duels are their own rating class. Your duel rating and your arena rating are
different numbers, because a duelist and a good flag runner are not measuring
the same skill.

**The general model degenerates correctly here.** The damage-weighted pairwise
attribution in [rating.md](rating.md) reduces, in a one-on-one fight, to a
single contributor with weight 1.0. Duel rating is ordinary Elo, and it arrives
as a special case rather than a special implementation.

## Maps

Duel plays Team Battle's five, in the same rotation: maelstrom, gantry, warren,
redoubt and ringworks. That was the plan here in a different form, which asked
for several small symmetric layouts rather than one, each rewarding something
different. The rooms that answer it are the melee rotation's, because a theme
owns its geometry there now and the five already differ that way. A pilot learns
a map once and knows it in both games.

They are 160 square and 192 by 144 rather than the 64 tiles this section used to
ask for, so a duel happens in a room built for eight. That is deliberate: two
ships in a room bigger than the fight makes where to fight a decision. The
one-life clock stops it becoming a chase.

Gantry is also the calibration ground, and calibration flies it alone. Keeping
the live arena and the measurement fixture aligned prevents a rating earned in
open space from pretending to describe a close fight around walls, and holding
the fixture to one map keeps a rating comparable from week to week while the
room a player lands in varies.

Wormholes were the open question, since maelstrom and ringworks carry them and a
warp sends a ship to its own start, which in a longer series is a way out of a
fight nobody can follow. Measured at one a side over thirty matches apiece, the
two warp maps sit at 0.7 and 0.6 deaths per pilot-minute against 0.6 to 0.7 for
the three without. A duel on them is the same duel.

## The economy

The same movement, collision, weapon and kit economy melee uses. A duel should
measure the pilot, not a private ruleset the player never sees in the main game.
`a_duel_runs_the_melee_economy` holds every line of the zone file against
melee's own, because this was prose once and prose does not fail a build: melee's
spray tuning moved and the duel's did not, and for a while a duel was measuring a
ruleset nobody played anywhere else.

## What should feel good

The single-life format makes every engagement legible and keeps rematches fast.
Meeting a person when one is there is the point of the mode; meeting a bot at
your own level when one is not is what keeps it playable at four in the morning.

Those are design hypotheses. Bot tournaments can verify population ordering
under their fixture and measure how noisy one life is. Only play with people can
tell us whether the band is wide enough to find anybody, whether ten seconds is
the right thing to ask somebody to wait, and whether losing rating to a bot
feels acceptable or whether the honesty of it costs more than it buys.

## Open questions

Whether the ten-second hold should widen with the population, or shorten when
the zone is plainly empty.

Whether a person taking a bot's seat mid-fight is the right trade. It voids a
fight somebody was enjoying in order to give them a better one, and the
alternative is making them wait for the whistle.

Whether the pairing band should be tighter once there are enough people for
tightness to find anybody, and whether a deployment-wide queue belongs in the
meta-layer rather than at each arena's door. See
[decision 30](../architecture/decisions.md#30-the-meta-layer-is-ours-and-identity-leaves-nakamas-list).

Whether best rung was worth keeping in some other form. Nothing durable survives
a duel now except the rating, and a number that says how far an evening got is a
thing players ask for.

Whether 2v2 belongs here. The mode would generalize almost unchanged, and team
duels are a large part of what league play actually looks like.
