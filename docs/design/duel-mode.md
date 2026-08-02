# Duel mode

One player, one opponent, a small closed map, first to five. The opponent is
either a human near your rating or a bot near your rating, and you choose which
you are willing to accept.

Duels matter more than their player count suggests. They are the fastest way for
a new player to learn the flight model without dying to four people at once, the
cleanest signal a rating system can get, and the natural unit for leagues. The
original had a whole dueling league culture around exactly this, and the ASSS
settings still carry a `NearDeathLevel` knob whose documentation says it exists
for dueling zones.

## The match

**Format.** First to five kills. Both players spawn at opposite ends of a small
symmetric map with full energy, fight, die, respawn, repeat. Eight-minute cap; if
it expires the higher kill count wins, and equal counts are a draw.

**Ships.** Both players lock a ship before the match starts and keep it for the
whole match. A ladder may require a mirror match, where both fly the same class,
which measures pilot skill and nothing else. The default open ladder allows any
pairing, because matchup knowledge is part of the game.

**No prizes.** Greens are off. A duel decided by who flew over a Super first is
not a duel. Both ships fly at their configured initial settings, which is also
what makes duels a clean rating signal: the variables are the pilots.

**Structure.** Ten seconds of warmup with weapons disabled, a three-second
countdown, then live. On each death the killer holds position while the victim
respawns with a brief invulnerability window, long enough to orient and short
enough that it cannot be used offensively.

**No hiding.** Duel maps are small, closed, and free of safe zones, and both
players are permanently visible on each other's radar. Stalling is not a
strategy anybody should have to counter.

**Leaving is losing.** A player who quits mid-match forfeits and takes the
rating loss. A disconnect gets ninety seconds to return before the forfeit
applies, because a dropped connection and a rage quit look identical to the
server and only one of them deserves patience.

All of these are defaults. Every number is zone configuration, the same as
everything else.

## Finding an opponent

**Queue.** You enter a queue with a rating band and a latency band. The rating
band starts at plus or minus 50 and widens to 300 over sixty seconds. The
latency band is not negotiable in the same way: duels are twitch-sensitive and a
match at 200 ms is not worth playing, so distant opponents are excluded rather
than accepted reluctantly.

**Accept AI.** A toggle in the queue says whether you will take a bot if no human
appears. With it on, after about forty-five seconds you get a rating-matched bot
instead of a longer wait. With it off, you keep waiting. Off-peak, the toggle is
the difference between a game and a lobby.

**The opponent is always labeled.** You know before the countdown whether you are
fighting a person or an AI, which archetype it is, and what it is rated. There is
no mode in which the game is coy about this.

**Practice duels.** Unrated, against any bot at any difficulty, available
instantly and repeatedly. This is the tutorial that does not feel like one: pick
the Duelist at 0.3, learn to lead a shot, move up. Nothing about it touches your
rating, and the interface says so.

**Rematch.** Offered to both players after a match. Rematches count, subject to
the repeat dampening in [rating.md](rating.md), so a long session against one
opponent yields progressively less rating movement and remains fun.

## Rating

Duels are their own mode class. Your duel rating and your arena rating are
different numbers, because a duelist and a good flag runner are not measuring the
same skill.

**Rated per match, not per kill.** A first-to-five match is a much stronger
signal than any one kill inside it, and updating per kill would count correlated
outcomes five times. The match produces one Elo update.

**Margin adjusts K, not the outcome.** The outcome is win, loss, or draw. A 5-0
scales K up, a 5-4 scales it down, within a bounded range. This captures
dominance without paying players to run up a score against somebody already
beaten.

**The general model degenerates correctly here.** The damage-weighted pairwise
attribution in [rating.md](rating.md) reduces, in a one-on-one fight, to a single
contributor with weight 1.0. Duel rating is ordinary Elo, and it arrives as a
special case rather than a special implementation.

## Duels against AI

A rated duel against a bot moves your rating exactly as a duel against a human
does, because bots are rated on the same ladder and anchored to a fixed reference
personality. That is the mechanism that lets a player on an empty server still
find out how good they are.

The safeguards from [rating.md](rating.md) apply unchanged: beating a bot far
below you returns nearly nothing, and the share of daily rating gain that can
come from AI is capped once you are above the bot ladder.

Bot opponents in duels are chosen for their archetype as well as their rating, so
a session of duels is a tour of playstyles rather than five matches against the
same aggressive Apex. Rated duels draw from the individuals currently on
schedule, so your recurring rival is sometimes around and sometimes not, which
is what makes it a rival. Practice duels may summon anyone.

## After the match

A summary screen, which duels earn and arenas do not: kills and deaths, accuracy
per weapon, damage dealt and taken, average energy at the moment you killed and
the moment you died, longest streak, and the rating change with the reason for
its size.

The damage ledgers the rating system already keeps make all of this nearly free,
and duels are where players actually want the detail.

**Every duel is replayable.** Deterministic simulation plus a recorded input log
means a replay is the input file, a few kilobytes, reproducing the match exactly.
Watch it, share it, or step through the moment you lost. This falls out of the
architecture rather than being built for it, per
[simulation-core.md](../architecture/simulation-core.md).

## Implementation shape

Duel is a zone, and its arena servers stay alive between matches. A few of them
sit registered and empty; two players arrive, one takes the match, runs it,
reports the result, resets, and takes the next pair. Nobody waits for a machine
to boot.

That is a change from the original plan, which built a fresh arena per match and
threw it away afterwards. It was free when arenas shared a process. It is not
free when an arena is a process, and the reason is not the launch: it is the TLS
handshake, the registration exchange, the config fetch and the verification
callback that stand between launching and being ready for a player. See
[zones-and-arenas.md](../architecture/zones-and-arenas.md).

The queue lives in the arena server too. Everyone waiting for a duel joins the
same one and is paired with whoever else is waiting there, which needs no
matchmaker anywhere else in the system. The client already picks the fullest
instance below its cap, so waiting players collect in one room by default. The
limit is honest: pairing is only as good as one room's queue. A queue that spans
a whole deployment belongs to the meta-layer matchmaker in
[decision 11](../architecture/decisions.md), not to a directory.

The module still owns the rules: round state, spawns, the countdown, weapon
lockout during warmup, the win condition, and the forfeit timer. It uses the same
adviser hooks as any other game mode. If the duel ruleset needs something the
module API cannot express, the module API is wrong, and we would rather find that
out here than in a more complicated mode.

## Maps

Several small symmetric layouts rather than one: an open box that rewards aim, a
pillared room that rewards positioning, a tunnel complex that rewards ship
knowledge. The match picks at random, or a ladder can add a pick and ban phase
later.

Small means roughly 64 by 64 tiles, an area a duel can cross in a few seconds.
The 1024-tile world is for arenas.

## Open questions

Whether first to five is right. Three is quick and noisy, ten is a commitment.
Five is a guess that a playtest should confirm.

Whether mirror matches or open ship picks make the better default ladder. Mirror
is a purer measurement; open is a more interesting game.

Whether 2v2 belongs here. The module would generalize almost unchanged, and team
duels are a large part of what league play actually looks like.

Whether losing rating to a bot feels acceptable to players, or whether the
honesty of it costs more than it buys. The alternative is asymmetric rating where
AI losses cost less, which is a lie we would have to maintain forever.
