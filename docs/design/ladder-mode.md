# Ladder mode

Ladder is a solo run through the house bot roster. One human faces one bot. A
win asks the director for the next difficulty slot, while a loss moves the run
back far enough to matter without discarding the whole evening.

Ladder is one life per opponent. `ladder_first_to` is one, so the first death
settles the rung. Catalog validation refuses a longer series under this mode.
Each life is the whole decision, then the room gets the player into the next
fight.

## Run progression

The server stores the next opponent as a zero-based slot. The player sees rung
one for slot zero.

| Result | Ordinary Ladder | Default |
|---|---|---|
| Win | Advance one rung and add one to the streak | `+1` |
| Loss | Clear the streak and move back, stopping at the saved checkpoint | `-2` rungs |
| Checkpoint | Save a floor after clearing each interval | Every 5 cleared rungs |

The loss rule is `max(checkpoint, rung - ladder_loss_drop)`. With the defaults,
a loss on the opponent at rung eight sends the next fight to rung six, the
floor earned after clearing the first five opponents.

`ladder_checkpoint_interval = 0` disables new checkpoints. All progression
arithmetic saturates at its numeric bounds, so an unusual zone setting cannot
wrap a run from the top to the bottom.

## One opponent for one life

A life starts only when the room contains exactly one human and one bot. The
match clock waits at its full value while the first opponent is being seated.
If the rival leaves during play, that life is void. The room files no result,
pays no completion reward, and changes no progress or rating. Both ships reset
before the same rung reopens against a replacement. A damaged rival cannot
return with a fresh ship while the player keeps the damage from the abandoned
fight.

The opponent slot is locked when a life opens. A result changes the requested
slot for the next life, not the bot already on the field. During intermission,
the old bot leaves and the director seats the requested replacement. The room
must observe the old seat vacant before it accepts a different slot as ready.
That prevents a fast reconnect from opening the next life against the previous
opponent.

The configured match timer is a guard against stalling. No score exists before
the deciding death, so an expired clock enters sudden death and the next death
settles the rung. Calibration gives sudden death a recorded safety boundary so
a broken or nonterminating leg cannot run forever. Any leg that reaches that
boundary blocks certification; live play itself remains uncensored.

## Persistence

Checkpoint and best rung are durable per account and per Ladder zone. The
server carries them in the signed session claims and projects completed match
events into the meta-layer. Replaying an event is safe because progress only
moves forward in that projection.

An unfinished stretch above the checkpoint is intentionally temporary. A new
session resumes at the saved checkpoint with a streak of zero, while best rung
remains available for the player's record. This gives checkpoints a real job
and prevents reconnecting from becoming a way to preserve every attempt.

Ladder progress is not Elo. Rung records progress through a run. Rating
estimates strength across rated results. The bot roster may use calibrated Elo
to order opponents, but winning one Ladder life always advances one slot even
when two neighboring opponents have overlapping rating intervals.

## Difficulty policy

The game never weakens or strengthens a pilot during a life. No hidden aim
change follows a hit, a death, or a low-energy moment. Adaptation happens only
at the opponent boundary, where the next room-specific request names a new
difficulty slot.

Each rung resolves to one of eight authored pilot specifications. The player
can learn that archetype's range, weapon preferences, and willingness to chase,
while the prespecified order moves toward pilots expected to be stronger. A
powered bot tournament can validate that order against the bot population. It
cannot prove that every archetype is monotonically harder for an adapting
human; that claim needs session-level player results. The director
has 1,024 persistent identities for each archetype so concurrent rooms never
reuse one account. Those replicas have distinct IDs and call signs but the
same controller, hull, behavior, competence, build, and base-account kit the
experiment measured.

The provisional roster has eight rungs. Clearing its final opponent records
best rung eight, marks the run as cleared, and starts the next run from the
saved checkpoint after the podium. The server never turns a larger rung number
into a hidden rematch against the strongest pilot. A certified roster artifact
may replace the provisional order only when its content fingerprints and
statistical release gates pass together and its release signature verifies.
Until such an artifact ships, the
live order is labeled provisional and comes from the authored competence and
behavior prior.

## What should feel good

The single-life format makes every engagement legible and keeps rematches fast.
The two-rung loss supplies tension without making one bomb erase a long run.
Checkpoints turn a sequence of short fights into an evening-scale objective.

Those are design hypotheses. Bot tournaments can verify population ordering
under their fixture and measure how noisy one life is. Only play with people can tell us whether the
loss feels fair, whether the checkpoint interval creates useful tension, and
whether players choose another run because they enjoyed the previous one.
