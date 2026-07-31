# AI players

A new multiplayer game has nobody in it. That is the whole problem, and it kills
most of them: the first player arrives, finds an empty arena, and never comes
back. AI opponents exist to make an empty server into a game worth playing, and
to get out of the way as humans arrive.

They are also a practice partner, a way to keep off-peak arenas alive, a load
generator for testing, and the calibration anchor for the rating system in
[rating.md](rating.md).

## Principles

**Bots play by the same rules.** A bot emits the same input command as a human
client, every tick, through the same interface, and sees only what the server
would have sent to a human in its position. It cannot see through walls, cannot
see a cloaked ship it has no business seeing, cannot turn faster than its ship's
rotation rate, and cannot fire faster than the settings allow. Difficulty is
imperfection added, never permission granted.

This is a design commitment with a pleasant side effect: if a bot can play well
under those rules, the input model is rich enough for humans. If it cannot, the
problem is probably our controls.

**Bots are labeled.** The player list, the kill feed, and the profile all say
which players are AI. Two reasons. Players deserve to know who they are fighting,
and a rating system that quietly mixes bots into your record without telling you
is a system nobody will trust.

**Bots leave gracefully.** They do not blink out when a human joins. They fly to
spectator and then leave the arena the way a player does, preferring the moment
after their own death, preferring bots far from any human, and never leaving
mid-fight or while carrying a flag or the ball.

**No rubber-banding inside a fight.** A bot's skill is set when it spawns and
does not change while you are fighting it. Adaptation happens at the roster
level: the director spawns harder or easier opponents. Players can feel a bot
that suddenly starts missing, and it insults them.

**Bots are content.** Zone authors define their own rosters and, if they want,
their own behavior. A zone whose bots feel like that zone is a zone with an
identity.

## Styles

Each bot is an archetype plus a skill level plus a ship. The archetypes map to
the roster in [ships.md](ships.md) without being locked to it:

| Archetype | Usual ship | Behavior |
|---|---|---|
| Duelist | Apex | Seeks one-on-one fights, chases hard, breaks off at low energy |
| Bombardier | Wedge, Anvil | Holds corridors and chokepoints, avoids open space, lobs into traffic |
| Skirmisher | Chord | Pokes from range, sustains fire, retreats early and often |
| Ambusher | Cipher | Cloaks near routes, waits, commits once, leaves |
| Anchor | Spire | Stays with the group, keeps recharge up, runs when isolated |
| Brawler | Facet | Closes to knife range, fights in tunnels, dies in the open |
| Denier | Lattice | Mines chokepoints, defends the flag room, rarely chases |
| Runner | Any | Plays the objective over the kill, takes flags, chases the ball |

An arena's bot roster mixes these, so the room feels like a room rather than
eight copies of one opponent.

## Skill

Skill is a set of parameters, not a set of behaviors. A weak bot and a strong bot
run the same code and differ in how well they execute:

| Parameter | Weak | Strong |
|---|---|---|
| Reaction | ~400 ms before responding to something new | ~40 ms |
| Aim | Poor lead prediction, wide error | Near-exact lead within the projectile solution |
| Discipline | Fires at any energy, chases to its death | Manages energy, disengages on a threshold |
| Awareness | Tracks one contact, ignores its back | Tracks the room, checks radar constantly |
| Greed | Overcommits or flees at random | Correct risk for the situation |
| Map | Bumps walls, takes bad routes | Uses chokepoints, carries speed through corners |

A single skill dial from 0 to 1 drives all of them, with per-archetype jitter, so
a 0.7 Duelist and a 0.7 Ambusher are about equally hard and feel nothing alike.

## Personas

Bots have stable names drawn from our naming family, and they keep them. A player
who keeps getting killed by the same Ambusher should learn its name and start
watching for it. This costs nothing and it is most of the difference between an
arena that feels populated and an arena that feels like a screensaver.

Names are visibly marked as AI, so recognition never becomes deception.

## The population director

Each arena runs a director that decides how many bots exist and which ones.

**Fill to a target.** The arena configures a target number of playing pilots and
a target per team, in the same spirit as the original's `DesiredPlaying`. The
director fills the gap with bots.

**Match the room.** Bots are chosen with ratings near the humans present, so a
first-time player is not fed to experts and a strong player is not handed
practice dummies. For a lone newcomer, the target is bots slightly below their
provisional rating, because early losses are how new players leave.

**Yield to humans.** When a human joins, a bot is marked for removal and leaves
under the graceful rules above. Bots never outnumber humans on the opposing team
by more than the configured ratio once a room is populated.

**Resist churn.** A bot lives at least thirty seconds. After a removal, no bot is
added for a minute. A player joining and leaving repeatedly should not make the
roster flicker.

**Balance before asking humans to.** If teams are uneven, bots switch sides
first. Nobody enjoys being told to change teams.

**Keep a floor.** Off-peak, the director keeps enough bots that an arriving
player finds a game in progress rather than an empty map. Whether the floor is
zero in a zone with real population is a per-zone setting.

## Rating

Bots carry ratings, which is what makes the arena useful for ranking humans. See
[rating.md](rating.md). Two properties matter here: a bot's rating belongs to its
personality rather than to an instance, and one reference personality is pinned
to a fixed rating so the bot population cannot drift as a closed system.

## Duels

Bots are also the opponent of last resort in the duel queue, and the opponent of
first resort for a player who wants practice. A rated duel against a bot moves
your rating exactly as a duel against a person does. [duel-mode.md](duel-mode.md)
covers the format and the queue.

## What we are not doing

No machine learning in the first version. Hand-authored utility behavior with
parameters is cheap, debuggable, tunable by a designer, and good enough to be
fun. Imitation learning from recorded human play is an interesting later
experiment and a bad way to start.

No bots that pretend to be human. No fake chat, no fake typing, no unlabeled
entries in the player list.

## Open questions

Whether bots should chat at all. A little canned banter makes an arena feel
alive; too much is uncanny and annoying.

Whether bots should be allowed in rated arenas at all times, or only below a
population threshold. A zone at full capacity has no need of them, and their
presence complicates ratings.

How good bots actually need to be. The target is not "beats a good player" but
"is worth fighting," and we do not know where that line is until people play.
