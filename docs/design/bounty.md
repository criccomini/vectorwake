# Bounty and points

Two numbers that are constantly confused for each other.

**Bounty** is what you are worth. It goes up as you get stronger, everyone can
see it, and dying takes all of it.

**Points** are what you have been paid. They only go up, nobody can take them,
and they are the scoreboard.

The mechanic is that the first is the price of the second: killing someone pays
exactly their bounty. So the player who is winning is the player everyone else
is hunting, and a snowball is visible and contested rather than quiet.

## Bounty is derived, not stored

```c
int32_t sim_bounty(const sim_ship *sh);   /* up[] + level[] + mods + charge[] + earned */
```

Every count in the tech tree is already authoritative state, so bounty is a sum
over it. Everything held counts one, which makes bounty **exactly the number of
greens a pilot has successfully absorbed**, plus `earned` — the small
accumulator for kills.

Not storing it is the whole trick, and it buys three rules for free:

- **rust lowers your price** in the same instruction that takes the upgrade.
- **a green at the ceiling does not inflate you.** You were told what you found
  and nothing moved; your bounty does not move either.
- **death resets it**, because death already strips everything.

None of those is written anywhere. They are consequences of the sum.

The original could not do this. Subspace's bounty is a counter inside Continuum
that the server copies out of the position packet without ever deriving or
checking it — `p->position.bounty = pos->bounty;` is the whole of the server's
involvement. That number *can* disagree with what a pilot is actually carrying.
Ours cannot, and it is authoritative because it is a function of state the
server owns.

It also costs the wire nothing. Every count it sums is already in the snapshot,
so the client computes it locally rather than being told.

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

### The best part is what falls out

**A fresh spawn is worth nothing, so camping a respawn pays nothing.** No
anti-farming rule, no repeat-kill decay, no timer. The original needed
`DebtKills` and `NoRewardKillDelay`; this needs neither, because the payout is
the victim's bounty and a pilot who has just died is carrying zero.

That property depends on there being no fixed component to a kill. If a zone
ever adds one, it buys back the farming problem, and that is the trade to know
about before adding it.

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
