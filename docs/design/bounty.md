# Bounty and points

Two numbers that are constantly confused for each other.

**Bounty** is what you are worth. It goes up as you get stronger, everyone can
see it, and dying takes all of it.

**Points** are what you have been paid. They only go up, nobody can take them,
and they are the scoreboard.

The mechanic is that the first is the price of the second: killing someone pays
exactly their bounty. So the player who is winning is the player everyone else
is hunting, and a snowball is visible and contested rather than quiet.

## Bounty is mostly derived

```c
int32_t sim_bounty(const sim_ship *sh);   /* up[] + level[] + mods + charge[] + earned */
```

Every count in the tech tree is already authoritative state, so most of bounty
is a sum over it. Everything held counts one; `earned` carries the rest — what
killing has paid, and what greens taken at a ceiling were worth.

**Every green is worth exactly one bounty**, whatever it turned out to be. A
green that raised a count is worth one because the count went up. A green that
found you already at the ceiling is worth one because `earned` went up instead.

That second case matters more than it looks. If a maxed pilot stopped
accumulating bounty, the pressure this whole mechanic exists to apply would
stop growing at exactly the moment somebody is most dominant — the best player
in the room would become the safest. So a ceiling stops the upgrade, not the
price.

Deriving the held part still buys two rules for free:

- **rust lowers your price** in the same instruction that takes the upgrade.
- **death resets it**, because death already strips everything.

Neither of those is written anywhere. They are consequences of the sum.

Ours can exceed what a pilot is holding, and that is deliberate: the gap is
exactly what killing has paid them and what they hoovered after filling up. It
cannot be *lower* than what they hold, and it cannot drift, because the held
part is not a copy of anything — it is the counts themselves.

The original's could drift, in both directions. Subspace's bounty is a counter
inside Continuum that the server copies out of the position packet without ever
deriving or checking it — `p->position.bounty = pos->bounty;` is the whole of
the server's involvement. Ours is authoritative because it is a function of
state the server owns, and the one piece that is a counter (`earned`) is only
ever written by the simulation.

It costs the wire two bytes. Every count the sum runs over is already in the
snapshot, so the client adds them up locally rather than being told a total.

## Points are the victim's bounty

```
points[killer] += bounty(victim) + flags_carried(victim) * points_per_flag
```

Straight from the original, where `Kill:FixedKillReward` defaults to −1 and −1
means "use the bounty of the killed player". Not a percentage, not a base plus
a share: the number over their head, one for one.

Paid to the **finisher**, deliberately unfairly. [rating.md](rating.md) is the
system that gets attribution right — damage-weighted across every contributor,
decaying, cross-zone — which frees the in-game payout to be a blunt readable
prize worth sniping for. Two systems, two jobs. Making points fair as well
would build the same thing twice and lose the moment where you steal the loaded
one out from under someone.

A teamkill pays neither points nor bounty, which is the rule the rating layer
already applies to teammate damage.

### What falls out, and what `spawn_prizes` costs

**A fresh spawn is worth whatever it spawned holding**, and that is a knob.
With `spawn_prizes = 0` a pilot who has just died carries zero, so camping a
respawn pays nothing -- no anti-farming rule, no repeat-kill decay, no timer,
where the original needed `DebtKills` and `NoRewardKillDelay`. The property is
free, because the payout is the victim's bounty and the victim has none.

**The baseline's 30 spawn greens buy that property back.** Every fresh spawn
is worth about thirty, so a pilot camped on a respawn point is being paid
thirty a kill for shooting people who have been alive for a second. That is
the cost of a loaded opening and it should be a deliberate trade, not a
surprise: a zone that cares about spawn camping either turns `spawn_prizes`
down or needs the anti-farming rule this design was pleased to be doing
without.

It also raises the floor under every number in the game. Nobody is ever worth
nothing, so the spread between a fresh pilot and a loaded one narrows from
"everything" to "thirty against sixty", and the hunt-the-leader pressure this
mechanic exists to create is correspondingly softer.

The other property still holds regardless: there is no *fixed* component to a
kill. The payout is the victim's bounty and nothing else, so a zone that sets
`spawn_prizes = 0` gets the free anti-farming back with one line.

## What a kill is worth to the killer

`bounty_per_kill`, default **3**. A pilot on a streak becomes a target without
having touched a green.

The original's reference zone used 6. Three is lower on purpose: the tech tree
now carries real power, so the number over a ship is mostly a readout of what
they are *holding*, and the kill term is a thumb on the scale rather than half
the total.

Note the asymmetry it creates, which is intended: killing an empty pilot pays
no points but still makes you slightly more dangerous. You got better at the
cost of becoming more worth killing.

## Showing it

**Under every name, always.** It is the one number that says which of two ships
in front of you is worth the risk, and hiding it below a threshold would mean
the interesting information is missing exactly when a fight starts.

Your own is on the status panel next to your points — `0 points` and `worth 6`
— because those are the two questions you have about yourself and they have
different answers.

The scoreboard sorts by points and keeps kills and deaths on the row. They say
different things: a pilot who kills loaded ships outscores one who kills more
of the empty, and both facts are worth seeing.

The feed says what a kill paid, and stays quiet when it paid nothing rather
than printing a zero.

## Configuration

```toml
[arena]
bounty_per_kill = 3
points_per_flag = 100
```

## What is deliberately out

**A jackpot.** `Kill:JackpotBountyPercent` feeds an arena-wide pot in the
original. It needs a payout event and a reason to care, and we have neither.

**Points as currency.** The original's `Cost` section lets a zone sell upgrades
for points. That is a different game, and an interesting one.

**A fixed kill reward.** Available in the original and deliberately not here,
because the zero-payout-for-fresh-spawns property depends on its absence.

**Two reward formulas.** The original has one in Continuum
(`RewardBase`, `MaxBonus`, `MaxPenalty`) and another in the server
(`points_kill.c`), plus settings like `KillPointsMinimumBounty` that appear in
the shipped config and are read by nothing at all. We get one formula, in one
place, and it is the one the server runs.
