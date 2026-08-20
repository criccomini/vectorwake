# Progression

> **Proposed, not built.** The roadmap has carried the line "deliberately
> deferred: anything resembling progression, an economy, or a persistent
> world" since M0. This document is that deferral coming due, on purpose,
> because playtesting said so. It is written to be argued with before
> anything lands.

## What playtesting said

Six gripes, from the owner's own sessions:

1. You land in the arena and there is no obvious point.
2. A session has no beginning, middle, or end.
3. You cannot shape your ship to your liking. Greens are random.
4. A death takes everything you built.
5. Rating tiers and `/pilots` exist, but nothing inside the game ranks you at
   a cadence that pulls you back for one more.
6. Points buy nothing. There is no economy.

The live fleet agrees. Of 241 human accounts read off the public pilot API on
2026-08-17, 67% never scored a rated exchange, the median career among those
who did is three games, and nine accounts have passed twenty. Arrivals are
fine. The first session is the wall, and these six gripes are the wall
described from the inside.

They are also one gripe wearing six coats: nothing in the game accumulates
meaning. The only thing a pilot builds across a session is the stack of greens
on their hull, and the game is designed to take that away. So there is nothing
to aim at (1), nothing that resolves (2), nothing that is yours (3), nothing
death spares (4), no ladder short enough to climb tonight (5), and nothing to
spend (6).

## The shape of the answer

Leave the fight alone and build a persistent layer around it. The in-round
game is the inherited system working as designed: greens are random, bounty
is derived from what you hold, death strips all of it, and the pilot who is
winning is the pilot everyone hunts. [bounty.md](bounty.md) gets its two best
rules free from that derivation, and hunt-the-leader pressure dies the moment
a kit survives its pilot. None of this document touches any of it.

What changes is what surrounds it:

- **Rounds** give a session its arc and its point. Gripes 1 and 2.
- **Rivets**, a currency banked from round points, are the economy. Gripe 6.
- **Fittings**, bought once and owned forever, are the customization. Gripe 3.
- **The week**, a per-zone standings table with livery for the top of it, is
  the short ladder. Gripe 5.
- Gripe 4 is answered by all of it at once: a death still empties the hull,
  and it no longer erases the evening.

One rule holds the layer together, and every section below is downstream of
it: **nothing persistent makes a ship stronger.** A fitting moves strength
sideways under a measured gate, livery moves nothing, and rivets buy only
those two. The moment something bought outlives death and wins fights, bounty
stops pricing risk, the rating stops measuring pilots, and the first-session
wall gains a second story built from other people's head starts.

## Rounds

A zone plays in rounds. The defaults, all per-arena configuration like
everything else:

```toml
[arena]
round_minutes = 12
intermission_seconds = 30
```

**The middle is the game today**, untouched. A round of `mode = "arena"` runs
kills for the clock; a flag mode ends early when a side sweeps, which is the
shape the warzone module already has. The mode owns the win condition, the
round machinery owns the clock, the reset, and the ceremony.

**The end is a podium and a payday.** When the round ends, weapons die for the
intermission and every seat sees the same card: who won, the top pilots by
round points, the best streak, and what the round just paid you. In Alpha the
round belongs to the top pilots rather than a side, because ten sides of
mostly bots make a side victory nobody's story.

**The beginning is a fresh deal.** The field's greens resweep, every hull
respawns with its `spawn_prizes`, and the room starts even. That evenness is
half of what makes losing your kit an honest wager: a round is a hand of
cards, not a lease you can be evicted from.

**Joining mid-round costs nothing.** You are seated instantly, the HUD carries
the round clock, and the guide's first line says the point: what pays, who is
ahead, when it ends. A new player's first minute currently opens on a question
this line answers.

Rounds are also the door duels come back through.
[Decision 16](../architecture/decisions.md#16-duels-are-an-ephemeral-arena-plus-a-zone-module)
left duels waiting for a mode to be catalog content, and
[duel-mode.md](duel-mode.md) lists the exact fields the return needs: a target
score, a warmup, a countdown, a time limit, read from the zone file rather
than hardcoded. Rounds are those fields with a different config in them.
Build rounds first and duels become the second customer of the same
machinery.

## Rivets

The currency. Named for the register the teams are named in, and the name is
the least settled thing in this document.

**Banked from round points, one for one.** Points are already the number that
tracks contribution, already carry bounty's anti-farming properties, and
already cannot be taken by death. Rivets are round points made spendable,
banked when the round ends or when you leave, whichever comes first. The
scoreboard stays the immutable record [bounty.md](bounty.md) says it is; the
wallet is a separate sum. A podium bonus on top, configured per zone and
small, makes the end of a round a payday rather than only a card.

**Stored at the meta-layer**, beside ratings, as a sum of round events. Two
instances of one zone pay the same pilot without disagreeing for the same
reason two instances rate without disagreeing: addition commutes, per M7.7.

**There is no farming problem, because there is nothing to protect.** The
rating system caps what the AI pays past Ace because rating is a measurement
and a farmed measurement lies. Rivets measure nothing. A pilot who grinds
bot rounds at 4 a.m. earns the right to buy a fitting they could also have
bought Tuesday, and every fitting is gated to win nothing. Farming rivets is
farming variety. Bots bank rivets like anyone, since they hold accounts and
fly rated careers, and their wallets are simply inert.

## Fittings

What a pilot owns, and the answer to a ship you cannot make yours.

**A fitting is a named preset over the hull space the zone already tunes:**
the floors, ceilings, and rows that `zone.toml` sets per class. Chosen in the
hangar, applied when you take a seat, and never *held*, which is the
load-bearing distinction: greens fill counts on the hull and die with it, a
fitting moves the frame those counts live in, and it survives because there
is nothing on the hull to take. Bounty is unchanged by construction, and that is
correct rather than convenient: the price on your head is the price of what
you can lose.

**Every fitting is a sidegrade, and a harness says so.** Each one prices its
gain with a loss, and the drill harness is the referee: matched bouts against
the bare hull, and a shipped fitting must land between 45% and 55% on at
least two hulls, because this repository has already learned that a balance
result measured on one hull is a result about that hull. A fitting outside
the band goes back to the shop, however good it feels.

Three examples, to make the shape concrete rather than to ship:

- *Long burn* (Apex): a step more top speed floor, a step less recharge
  ceiling. You arrive sooner and leave poorer.
- *Corridor rack* (Wedge): bombs start with a bounce, the gun ladder tops at
  L1. All in on the hallway.
- *Deep racks* (Lattice): two more mines live at once, one fewer repel
  charge held. You own more ground and escape it less.

**Zones own legality.** A zone lists the fittings it admits, the same way it
already writes its prize weights, and a duel zone lists none: the variables
in a duel are the pilots, per [duel-mode.md](duel-mode.md).

**The first one is cheap.** An evening of ordinary rounds buys it, because the
first purchase is the moment the persistent layer becomes real to a new
player, and that moment wants to land in session one or two, not week three.
Later fittings cost multiples of that. Exact prices are knobs and guesses
until the wallet data exists.

## The week, and livery

Rating already answers "how good am I" on a career scale, and tiers move too
slowly to end an evening on. The week is the short ladder beside it.

**A per-zone standings table** of round wins, podiums, points, and best
streak, rolling over Monday 00:00 UTC. The top of the closing week is paid in
livery marks. Rating measures skill and ignores attendance; the week measures
what you did with it lately, and resets often enough that this Tuesday is
always worth starting.

**Streaks ship as [bounty.md](bounty.md) designed them**: announced, never
paid, ended by death, teamkill, or quit. The round gives a streak the stage
it was missing, a best-streak line on every podium card, and the re-deal at
a round's end is not a death for the streak's purposes. The record a streak
leaves is exactly the kind of thing this layer exists to keep.

**Livery is decoration under the art direction's law.** The outline and the
fill are the team read and the weapon hues are semantic bands, per
[identity.md](identity.md), so livery may never touch a hull's paint. It
lives where nothing tactical is written: the wake, the nameplate badge, the
podium card. The trail system that just shipped is the natural first
surface, with styles and palettes carved outside the reserved hues. A pilot
should be recognizable across a room by their wake before anyone reads a
name, which is flair doing the one job flair has.

## What death takes, now

The inherited rule stands: prizes upgrade a ship and vanish on death, and
[identity.md](identity.md) lists that among the things we came here to keep.
What changes is the blast radius. Today a death near the end of a long climb
erases the only story the session had. Under this design the wager is
bounded by the round, since everyone re-levels in minutes anyway, and the
things that carry meaning sit outside the blast: points, rivets, fittings,
livery, the week's standing, the streak record. Death keeps its teeth inside
the fight, where bounty needs them, and loses the power to send anyone to
bed with nothing.

## What stays out

**Money.** The game is free and source available. Rivets are earned by
flying and by nothing else. There is no store that takes anything but them.

**Trading.** Wallets are personal. No gifting, no market, no auction. A
player economy is a moderation surface and a real-money market by the end of
its first week, and nothing here needs one.

**Hull gates.** All seven hulls are free from the first minute, forever, as
the original's eight were. Progression that locks content is the
first-session wall rebuilt on purpose.

**Consumables.** Anything bought that burns on use is strength for wealth,
whatever it costs, and breaks the one rule the layer has.

**XP levels.** A number that grows with hours played is a worse rating than
the rating. The persistent layer keeps records and property, never a fake
skill number.

## Implementation shape

Round state lives in the mode layer, not the sim: the target, the clock, the
intermission, the reset. The sim already rebuilds a hull on death; a re-deal
is that, for everyone, plus a prize resweep. Round results and wallet deltas
ride the arena's existing spool to the meta-layer exactly as rated events do,
which is what makes the sums instance-proof.

A fitting is a per-seat override of the hull's spec, dealt when the seat is
taken and carried in the snapshot, so a late joiner predicts the same hull
everyone else sees. That is a new field for `pack.c` to learn, a regenerated
golden reference, and a byte or two per seat. The shop itself is the menu's
business against the meta-layer's `/v1`; the arena only ever learns which
fitting a session chose.

## Order of work

Each step leaves a running game, in the M7 sense.

1. **Rounds in Alpha**, no economy attached. Done when a pilot lands
   mid-round, the HUD says what pays and when it ends, and the round ends,
   shows its podium, and re-deals without anyone rejoining. The number this
   step exists to move is the median first-session career, three games today.
2. **Rivets.** Banking, the wallet on the pilot card, the podium payday.
   Done when the wallet equals the sum of round events across two instances
   of one zone.
3. **Fittings.** The hangar, the shop, the per-seat override. Done when
   every shipped fitting sits inside the 45-55 band on two hulls in the
   drill harness, and a chosen fitting survives death, rejoin, and a zone
   hop.
4. **The week.** Standings, streaks, livery. Done when a week rolls over and
   pays its marks with no operator in the loop.

## Open questions

Whether Alpha keeps scored kill rounds or takes the flag objective the
warzone module already implements. A sweep is a better ending than a bell,
and also a bigger change to what Alpha is. The drill can A/B the fight;
only retention can judge the feel.

Whether the weekly table lists bots. In the room a bot's streak is worth
announcing, because it tells humans who to hunt. A weekly page led by bot
names is presence noise in exactly the sense
[community.md](community.md) draws the line at.

Whether podium bonuses in bot-heavy rooms invite idle farming off-peak.
They are priced small on purpose; if it matters anyway, scaling the bonus
by humans seated punishes the empty room honestly.

Whether the wallet is global per account or per zone class, as rating is.
Proposed: one wallet, since fittings legality is already per zone and a
wallet split by class is two small numbers instead of one useful one.

The name. Rivets is a proposal in the house register, not an attachment.

Every price in this document, which no harness can measure. The drill can
gate what a fitting does; only players say what one is worth.
