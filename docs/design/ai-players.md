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
client, every tick, over the same protocol, and sees only what the server
would have sent to a human in its position. It cannot see through walls, cannot
see a cloaked ship it has no business seeing, cannot turn faster than its ship's
rotation rate, and cannot fire faster than the settings allow. Difficulty is
imperfection added, never permission granted.

Since [decision 29](../architecture/decisions.md#29-a-bot-is-a-client) this is
transport rather than aspiration: a bot is a WebSocket client that decodes the
same snapshots and sends the same messages, so the wire enforces the rule.

This is a design commitment with a pleasant side effect: if a bot can play well
under those rules, the input model is rich enough for humans. If it cannot, the
problem is probably our controls.

**Bots are labeled.** The player list, the kill feed, and the profile all say
which players are AI. Two reasons. Players deserve to know who they are fighting,
and a rating system that quietly mixes bots into your record without telling you
is a system nobody will trust. The label is the bot's own declaration at join,
carried in the roster to every client; a fleet credential additionally marks the
house roster apart from visiting bots where trust matters, such as anchoring the
rating scale.

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

## The roster: bots as long-lived individuals

Bots are not spawned from templates on demand. A zone carries a persistent
roster of individuals, each with a name from our naming family, an archetype, a
skill level, its own rating, a presence schedule, and a career. "Bot A" is
somebody: it logs on around the same hours, flies the way it flew last week, and
carries its record with it.

**One individual, one place.** An individual never appears in two arenas at
once, and never twice in one arena. This is the rule that makes it an
individual: its rating is the record of one career, not an average over clones.

**An individual is an account.** The career above is not a metaphor for one:
each individual holds a real account at the meta-layer, claimed by name with
the bot server's pool credential and the same one every time, so a restart
resumes a career rather than starting one. Its rating lives where a human's
does and moves by the same math. A new individual is seeded from the calibrated
prior of its template on the day its account is created, which is where the
offline tournament's work enters the fleet. See
[accounts.md](accounts.md) and
[meta-layer.md](../architecture/meta-layer.md).

**Presence.** Each individual keeps loose hours, a few sessions a week, biased
toward the zone's own peak times with some spread into the off hours. Arenas at
different times of day have different regulars, and a player who keeps getting
killed by the same Ambusher on Tuesday nights should learn its name and start
watching for it. That recognition is most of the difference between an arena
that feels populated and one that feels like a screensaver.

**Careers.** Individuals enter the roster at low skill, improve slowly, plateau
where their parameters settle, and eventually retire and are replaced by new
names. Career movement happens between sessions, never inside one, which keeps
the no-rubber-banding rule intact. Careers give every rating band inhabitants,
so new players land among peers instead of at the empty bottom of a ladder, and
they keep the roster from calcifying into a cast everyone has memorized.

**Texture is not disguise.** Names are visibly marked as AI everywhere, the
schedule exists for rhythm and ladder health rather than mimicry, and bots do
not perform humanity: no fake excuses, no fake typing, no pretending to have a
life the label contradicts. Recognition never becomes deception.

## The population director

The director decides how many bots exist and which ones. It is a deployment
service rather than a per-arena loop: it runs in the bot server, which watches
the directory's browse reply and flies bots into rooms as ordinary declared
clients. [ai-runtime.md](../architecture/ai-runtime.md) has the mechanics.

**Fill to a target.** Every zone names how full its rooms should feel:
`bot_fill`, a share of the room's `max_ships`, 0.8 unless the zone says
otherwise. Bots make up the difference between that target and everybody else
present. A 64-seat room alone in the night holds 51 bots, one human joining
tips it over target and a bot stands down, and a room with humans past the
target holds no bots at all. The unfilled remainder is headroom, so a human
join never waits on a bot leaving.

**Match the room.** Bots are chosen with ratings near the humans present, so a
first-time player is not fed to experts and a strong player is not handed
practice dummies. For a lone newcomer, the target is bots slightly below their
provisional rating, because early losses are how new players leave.

**Draw from the roster.** The director picks from the individuals currently "on
schedule," which is what makes the room's cast feel like the room's cast. When
the online pool cannot cover the fill target or the rating band, it calls in
off-schedule individuals anyway. Fill beats fiction; the schedule is texture,
the target is the job.

**Yield to humans.** When a human joins, a bot is marked for removal and leaves
under the graceful rules above. Bots never outnumber humans on the opposing team
by more than the configured ratio once a room is populated. The arena backstops
the race a burst of joins can win: a join that would otherwise be refused for
space drops the newest declared bot and seats the human, so the headroom is a
courtesy rather than a load-bearing assumption.

**Resist churn.** A bot lives at least thirty seconds. After a removal, no bot is
added for a minute. A player joining and leaving repeatedly should not make the
roster flicker.

**Balance before asking humans to.** If teams are uneven, bots switch sides
first. Nobody enjoys being told to change teams.

**The floor is the target.** Off-peak a room simply sits at `bot_fill`, so an
arriving player finds a game in progress rather than an empty map. A zone that
wants no bots sets it to zero.

## Rating

Bots carry ratings, which is what makes the arena useful for ranking humans. See
[rating.md](rating.md). Three properties matter here: a bot's rating belongs to
the individual and follows its career, a new individual's rating is seeded from
its archetype's calibrated prior so it starts sane, and one reference
personality is pinned to a fixed rating, with no career and no schedule, so the
bot population cannot drift as a closed system.

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
