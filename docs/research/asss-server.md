# ASSS: how a Subspace zone server is built

ASSS ("a small subspace server") is Grelminar's from-scratch replacement for
subgame, the original Virgin server. It is GPL, written in C with an optional
Python module loader, and the manual we read is version 1.6.1 dated 27 May 2025.
The guide notes it targets 32-bit Intel because of byte-order assumptions, and
that Windows support is second-class.

Reading the source and the manual together, five design decisions do most of the
work.

## 1. Everything is a module

The server binary is a loader. About 79 modules ship with it, and a zone loads
only what it uses: Chaos Zone has no flags or balls, so it never loads
`flagcore` or `balls`. Modules load at boot from `modules.conf` and at runtime
with `?insmod`, unload with `?rmmod`, and list with `?lsmod`.

A module registers packet handlers, config-backed behavior, commands, and
callbacks. `game.c` handles position and death, `net.c` owns the UDP transport,
`flagcore.c` implements the flag protocol while `fg_wz.c` and `fg_turf.c`
implement the rules, `balls.c` runs powerball, `bricks.c`, `koth.c`,
`security.c`, `lagaction.c`, and so on. Python modules exist for the same
extension points, which is how zone authors write game logic without a C
toolchain.

The tradeoff is stated plainly in the manual: a loaded module has full access to
player IPs, machine IDs, scores, and passwords, and can crash or deadlock the
server. There is no sandbox. Python modules cannot crash it but can still
deadlock it and still touch the filesystem.

There is also an "adviser" pattern in the source worth stealing. Before the
server finalizes a kill it walks a list of `A_KILL` advisers, each of which may
rewrite the killer, the victim, or the bounty, or drop the kill entirely. That
gives zone modules a veto and an edit on core events without patching core.

## 2. The filesystem is the database

A zone is a directory:

```
myzone/
  bin/        asss binary plus every .so/.dll/.py module
  conf/       global.conf, modules.conf, groupdef.conf, staff.conf, svs/
  arenas/     one directory per arena, each with arena.conf
  maps/       .lvl files
  log/        asss.log
  data/       data.db (Berkeley DB: scores and persistent state)
  news.txt
```

Two arena directories are special. `(public)` configures public arenas and
`(default)` catches any arena without its own directory. `conf/svs/` holds the
Standard VIE Settings split by ship and function, which most zones include and
then override.

Config files are INI with a C preprocessor bolted on: `#include`, `#define`,
`$(MACRO)`, `#ifdef`/`#ifndef`/`#else`/`#endif`, backslash line continuation,
and a `Section:Key = value` form that lets one line reach into another section.
Sections and keys are case-insensitive. This is how a zone keeps eight ships and
several hundred settings maintainable.

Arena groups fall out of naming. Ask for `smallpb1`, `smallpb2`, `smallpb3` and
all three take their configuration from `arenas/smallpb`. Scores in the
"forever" and "per-reset" intervals are shared across the group; "per-game"
scores are not.

## 3. Authority is a capability, not a rank

Subgame had three levels: mod, smod, sysop. ASSS replaced them with named
capabilities. Every command implies two capability names, one for public use
(`cmd_lastlog`) and one for private use (`privcmd_freqkick`). Non-command
powers are capabilities too: `seeprivfreq`, `seeepd` (energy and inventory from
spectator mode), `seemodchat`, `sendmodchat`, `bypasslock`, `bypasssecurity`,
`unlimitedchat` (for bots), `changesettings`, `invisiblespectator`.

`groupdef.conf` maps groups to capabilities, `staff.conf` maps players to groups
per arena with a `(global)` section that overrides. The old three-tier model is
reproduced by having each group `#include` the tiers below it. Capabilities can
also gate whole arenas: set `General:NeedCap` and only holders may enter.

## 4. Lag is a first-class game mechanic

This is the part most modern engines get wrong, and Subspace has thought about
it longer than most.

The server measures four things per player: average ping (an exponential average
over S2C, C2S, and reliable round-trips), S2C packet loss, S2C weapons packet
loss, and C2S packet loss. Clients measure the same values independently and
report them, because neither side alone sees the truth.

Each metric carries four thresholds, and each threshold has a different
consequence:

| Threshold | Effect |
|---|---|
| `*ToSpec` | Force the player into spectator mode |
| `*ToDisallowFlags` | Player may not pick up flags or balls (keeps what they hold) |
| `*ToStartIgnoringWeapons` | Begin dropping a share of their weapons |
| `*ToIgnoreAllWeapons` | Drop all of their weapons |

Between the two weapon thresholds the server interpolates: at the start
threshold it ignores 0% of incoming weapons, at the upper threshold 100%, and it
takes the maximum across metrics. C2S loss deliberately never causes weapon
ignoring, because losing your own packets hurts you rather than helping you.
`SpikeToSpec` covers the case where packets stop arriving entirely.

The philosophy is worth naming: high-lag players are not banned, they are
progressively de-fanged, and the degradation is proportional and per-metric.

Bandwidth throttling sits alongside it. Outgoing packets are prioritized by
function, so weapons beat chat for the last bytes of a slow link, some share of
bandwidth is reserved per priority class, and the limit adapts to connection
quality using TCP-like techniques.

## 5. One process can be several servers

`net` can listen on several ports. Each `[ListenN]` section takes a port, an
optional bind address, and an optional `ConnectAs` identifier. Players arriving
on port 5000 land in `pb1`, players on 7500 land in `aswz`, and the directory
module advertises each virtual server under its own name and description. They
all share one process, so players can move between them and chat across them as
if they had connected to the same server. It is a cheap way to run several
"zones" with one population.

## Maps and regions

Maps are `.lvl` files: an optional BMP tileset followed by tile data, 1024x1024
tiles. ASSS extends the format backwards-compatibly by inserting metadata
between the bitmap and the tile data, using the size and reserved fields in the
bitmap header that every existing tool already respects.

The interesting addition is regions: named, arbitrary sets of tiles with
attributes the server enforces. `no-antiwarp` clears the antiwarp bit of players
inside, `no-weapons` drops their weapons, `no-flags` prevents flag drops, and
`autowarp` teleports anyone entering to another location, possibly in another
arena.

The manual is candid that some of these fool the player: your antiwarp still
looks active to you, and you still see your own weapons fire. Server-side
suppression with no client feedback is a design hazard we should not copy
blindly.

## The settings surface

Arena configuration is where the game actually lives. The sections, with rough
counts from the 1.6.1 reference:

| Section | What it controls |
|---|---|
| `All` (per-ship) | 88 keys: thrust, speed, rotation, energy, recharge, weapon levels, specials, initial and maximum values, upgrade amounts |
| `Misc` | 37 keys: bounce factor, safety limits, energy visibility, ship change interval, periodic messages, timed games |
| `Flag` | 32 keys: carry rules, drop and neut behavior, flagger buffs and penalties, spawn, reward formula, win delay |
| `PrizeWeight` / `DPrizeWeight` | 27 each: relative likelihood of every green, with a separate table for death prizes |
| `Cost` | 25 keys: point prices when a zone lets players buy upgrades |
| `Soccer` | 23 keys: ball count, goal layout, pass delay, capture points, win conditions |
| `Kill` | 9 keys: bounty transfer, fixed rewards, per-flag bonuses, jackpot share, respawn delay |
| `Bomb`, `Bullet`, `Burst`, `Shrapnel`, `Repel`, `Rocket`, `Mine` | Weapon damage, radius, lifetime, EMP and bounce damage percentages |
| `Brick`, `Door`, `Wormhole`, `Radar` | Map-affecting objects and radar mode |
| `Team` | Freq sizes, balancing, private freq threshold, spectator freq, initial spec |
| `TurfReward` | The periodic scoring algorithm for turf zones, with recovery windows and weight tables |
| `Prize` | Green spawn rate, count scaling with player count, negative prize odds |
| `Spawn` | Per-team spawn points and radii |
| `Lag`, `Latency`, `Net` | The thresholds above, plus position and weapon interpolation pixels |

Some numbers give the flavor. `Flag:FlagReward` defaults to 5000 and the payout
is `(players in arena)^2 * reward / 1000`, so flag games pay out superlinearly
with population. `Kill:PointsPerKilledFlag` defaults to 100. `DamageFactor`
runs from 1 (extremely likely to lose a prize) to 5000 (almost never), with 0 as
a special case meaning never. `Misc:BounceFactor` uses 16 for no speed loss on
a wall hit. Energy costs for cloak, stealth, antiwarp, and xradar are in
thousandths per tick.

The pattern to notice: nearly every value is an integer with an implied scale
(tenths of a percent, thousandths per tick, pixels per second divided by ten).
That is a 1997 fixed-point decision, and it is contagious, because the wire
format and the client both assume it.
