# Rating

Every player carries a skill rating that moves when they kill and when they die,
against humans and against AI alike. It is separate from score: bounty and points
are gameplay, configured per zone, and they stay exactly as the zone author wants
them -- see [bounty.md](bounty.md). Rating is a cross-zone estimate of how good you are.

## The hard part

A kill in this game is rarely a duel. Three players shoot someone, a bomb takes
half their energy, a fourth player finishes them, and the game has to decide who
gets credit. Standard Elo assumes a two-player contest with one winner. We have a
victim, several contributors, and a killing blow that may be the smallest
contribution of the set.

The answer we are taking: every death becomes a set of pairwise contests between
the victim and each contributor, weighted by how much of the death each one
caused.

## Attribution

The simulation already emits a damage event for every hit, since damage
resolution is server-side. The rating layer keeps a decaying ledger per victim.

**Decay.** Damage that has been recharged away did not contribute to the death.
Each attacker's credit decays with a half-life tied to the arena's recharge
rate, roughly the time it takes that ship to refill from empty, clamped to
between two and ten seconds. A player who took you to 20% and let you escape and
recover gets almost nothing when someone else kills you a minute later. A player
who did that four seconds ago gets most of the credit.

```
on damage(attacker, victim, amount):
    ledger[victim][attacker] *= exp(-dt / tau)      # applied lazily
    ledger[victim][attacker] += amount

on death(victim):
    drop self-damage and teammate damage
    total = sum(ledger[victim])
    if total == 0: no rating event      # environmental death, disconnect, safety
    weight[i] = ledger[victim][i] / total
```

**No killing-blow bonus.** The killing blow's damage is already counted, and a
bonus on top of it creates a kill-stealing incentive that fights the in-game
bounty award, which already pays the finisher in points. Rating and score do
different jobs; let them.

**Support credit.** A Spire carrying turrets contributes to kills it did not
deal damage for. When a turret attached to a carrier earns credit, a configurable
share of that credit, defaulting to 15%, transfers to the carrier. Without
something like this, every rating system in this genre tells support players
they are bad at the game.

## The update

For each contributor `i` against victim `v` with weight `w_i`:

```
E_i  = 1 / (1 + 10^((R_v - R_i) / 400))     # expected score, standard Elo
ΔR_i = K_i · w_i · (1 - E_i)
ΔR_v = -Σ_i K_v · w_i · (1 - E_i)
```

With equal K the exchange is zero-sum: the victim loses exactly what the
contributors gain, apportioned by damage. K differs during a player's provisional
period, which breaks strict zero-sum in the direction of letting new players
find their level quickly, and that is the intended tradeoff.

`K` starts at 64 and decays toward 16 over roughly fifty rated deaths, so a new
player converges in an evening rather than a month.

**Repeat dampening.** Killing the same opponent repeatedly within a few minutes
yields progressively less, on a `1/(1+n)` curve. This is the anti-spawn-camp
provision, and it also stops two players from trading kills into orbit.

**Per-event cap.** No single death moves a rating more than a fixed maximum,
which bounds the damage from a bug in the attribution ledger.

## AI as the measuring stick

Bots are rated the same way and by the same math, which is what lets a player be
ranked in an arena with no humans in it.

**Ratings belong to individuals.** Bots are long-lived roster individuals, per
[ai-players.md](ai-players.md), and each owns its rating the way a player does.
Convergence is hierarchical: a new individual's rating is seeded from the
calibrated prior of its archetype-and-skill template, then refined by its own
games. Since an individual exists in one place at a time, its rating is the
record of one career rather than an average over clones.

**Careers move slowly.** When an individual's parameters improve between
sessions, its rating lags its true strength until play reconverges it, and
during the lag humans lose slightly more to it than its rating promises.
Improvement rates are therefore capped well below the convergence rate, so the
lag stays inside noise.

**One personality is pinned.** A reference bot has a fixed rating, by definition,
and is never updated. It has no career and no schedule. Everything else, human
and AI, floats relative to it. Bots would otherwise form a closed economy whose
absolute scale drifts, which would quietly make everyone's rating meaningless.

**Bots update slowly.** Their K is small. A human should move against a bot far
more than the bot moves against the human.

**Initial calibration is offline.** Bot personalities play each other in
tournaments before they ever meet a human, which produces a sane ladder from the
start. Human play refines it.

**One ladder, not two.** A player has one rating per mode class, and kills
against humans and against AI feed the same number. A separate vs-human rating
would sit empty during exactly the months when placement matters most, and a
mixed room, which is the normal early room, would leave the matchmaker unsure
which number to read. The pinned anchor is what makes bot and human ratings
commensurable enough to share a scale.

The profile still shows vs-human and vs-AI records separately as statistics,
because the event log records which kind of opponent every event involved. If
the combined ladder ever proves gameable, that same log lets us recompute split
ratings from history rather than resetting anyone.

## Farming

If beating AI raises your rating, people will farm AI. Four things make it not
worth doing.

Elo's own geometry does most of the work: beating a bot rated far below you
returns nearly zero, and losing to it costs a lot.

The population director removes bots as humans arrive, so a farm requires an
empty arena.

Above a threshold, the fraction of a player's rating gain that can come from AI
in a day is capped. Bots exist to place a player on the ladder, not to climb it.

Zones mark arenas as rated or unrated. A practice arena rates nothing.

## What it means, and what it does not

Rating is per mode class rather than global. A hockey zone, a warzone, and a
duel ladder measure different skills, and one number for all of them is a number
about nothing. Zones declare which class they belong to and a player carries one
rating per class, with the default class being general arena combat.

Duels are their own class and are rated per match rather than per kill, since a
first-to-five result is a stronger signal than the five correlated outcomes
inside it. The attribution math below degenerates to ordinary Elo when there is
exactly one contributor, so duels need no separate implementation. See
[duel-mode.md](duel-mode.md).

Rating measures killing and dying. It does not measure flag captures, goals, or
the thousand quiet things good players do. That is a real gap, and the plan is
objective-based rated events later rather than pretending kills are the whole
game.

What a player sees is a tier rather than a number, and nothing at all until
they are out of provisional. The bands live in `server/src/rating.rs`, from
Drift to Wake. This began as an open question below and the shipped answer has
held: a number invites anxiety over ten-point noise, and a coarse band moves
only when something real has changed.

## Storage

Every rated event is stored with its inputs: participants, weights, ratings
before and after, arena, mode class, and timestamp. Ratings are a projection of
that log, not the source of truth.

This costs disk and buys the ability to change the model. When we replace Elo
with something better, we recompute history rather than resetting everybody,
and we can test a proposed model against real data before shipping it. The disk
is not a rounding error once bots hold accounts, because bots fight around the
clock: the measured rate and what to do about it are in
[meta-layer.md](../architecture/meta-layer.md).
The same log read along its time axis is a career, which is how a profile draws
rating over time without any storage of its own, per [accounts.md](accounts.md).

## Where it runs

The arena emits kill events with attribution weights. The rating layer consumes
them outside the simulation, since rating is not a game rule and the sim core
does not know it exists. The arena keeps a running ledger for what it shows
mid-session and batches the rated events to the meta-layer, whose projection of
them is the authoritative number, per
[meta-layer.md](../architecture/meta-layer.md) and
[decision 30](../architecture/decisions.md#30-the-meta-layer-is-ours-and-identity-leaves-nakamas-list).
Events and ratings are keyed by account id, per [accounts.md](accounts.md),
which is what lets one career span every zone.

## Model choice

Version one is Elo with damage-weighted pairwise updates, because it is simple,
explainable to players, and easy to get right.

The intended successor is a Bayesian rating with explicit uncertainty, which
handles new players, inactivity, and partial credit far better. The candidate is
the Weng-Lin model as implemented by OpenSkill, which is patent-free and
commercially usable. TrueSkill is the obvious alternative and we are not using
it: Microsoft licenses it for Xbox Live titles and non-commercial projects only.
Glicko-2 is also free to use and is a reasonable fallback if a rating-period
model turns out to fit better than a per-event one.

Storing the event log is what makes that migration cheap, which is why it is not
optional.

## Open questions

Whether a ladder arena should show the number behind the tier. Tiers shipped
as the general answer, and a dedicated competitive arena is the one place
where the anxiety a raw number creates might be the point.

How to rate the objective game without letting a player farm rating by taking
uncontested flags in an empty arena.

Whether survival should count. A player who escapes at 5% energy did something
skillful that the current model scores as nothing.

Whether team outcomes should adjust individual ratings, as they do in most team
games. It rewards playing for the team and it punishes people for their
teammates, and both effects are real.
