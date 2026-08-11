# The original's numbers

Reference points taken from a real server's configuration rather than from
feel. Source: [eg-asss](https://github.com/fcxcode/eg-asss) — `dist/conf/svs/`
holds the per-ship files and `misc` the damage levels; `src/core/clientset.def`
documents the units, which is the part that actually matters.

Those ship files are a template where all eight ships carry identical numbers,
so they are not a roster to copy. They are something better: a set of ratios
that say how much a shot should cost against the bar it draws from.

## Units, which are where this goes wrong

| Setting | Unit | Note |
|---|---|---|
| `BulletFireDelay`, `BombFireDelay` | ticks | The original ticks at 100 Hz, and so do we, so these transfer directly |
| `BulletDamageLevel` | energy | Damage a level 1 bullet does at most |
| `BombDamageLevel` | energy | Damage at the center of the blast |
| `MaximumRecharge` | energy × 10 per second | `1150` is 115 energy/second |
| `MaximumEnergy` | energy | The bar |

## The ratios

| Quantity | Original | Fraction of max energy |
|---|---|---|
| `MaximumEnergy` | 1700 | — |
| `InitialEnergy` | 1000 | 59% |
| `MaximumRecharge` | 1150 | full bar in 14.8 s |
| `InitialRecharge` | 400 | 35% of maximum |
| `BulletFireEnergy` | 20 | **1.2%** |
| `BombFireEnergy` | 300 | **17.6%** |
| `BulletDamageLevel` | 200 | 12% |
| `BombDamageLevel` | 750 | 44% |
| `BulletFireDelay` | 25 ticks | 4.0 shots/second |
| `BombFireDelay` | 150 ticks | 0.67 shots/second |

Two things fall out of that table. A fresh bar of 1000 buys three bombs, and
a bullet is nearly free — the delay is what limits gunfire, not the cost.

## What we had

vectorwake priced a shot off its own damage: `bullet_damage + 130` and
`bomb_damage + 200`. Against an Apex that came to 35% of a full bar for a
bullet and 63% for a bomb, which is 29× and 3.6× the original.

The delays were right all along. The cost gated the guns long before the
delay did, so the real sustained rate was set by recharge instead:

| | Delay implies | Priced by damage | Priced by the original's ratio |
|---|---|---|---|
| Bullets | 4.0/s | 0.6/s | 4.0/s |
| Bombs | 0.67/s | 0.3/s | 0.7/s |

A bomb cost more than half of everything a ship had, so outside of a quiet
corner the key did nothing — and said nothing, because there was no energy
bar to say it with.

Firing costs are now taken as the original's fractions of each class's own
maximum energy, which keeps the roster's variety while fixing the scale.

## What we deliberately kept

Damage is close enough to leave alone: our Apex bullet does 200 against 1350,
where the original did 200 against 1700. Five bullets kills either way.

Our ships are faster — 490 px/s against roughly 325 — and recharge a full bar
in 9 s against 14.8. Both were confirmed by playtest before this comparison
existed, and neither is what made the guns feel wrong.
