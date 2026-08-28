# The catalog

The catalog is the versioned description of one deployment. It names the games
the fleet offers, the files behind them, the pools allowed to register capacity,
and the public half of account identity. Directories load it and hand it to
arena servers.

The catalog is authored as files in Git. Live facts such as room occupancy,
instance health, ratings, and friendships do not belong here. Directories and
the meta-layer own those.

## Layout

The current repository has one zone and six maps:

```text
catalog/
  catalog.toml
  zones/
    melee/
      zone.toml
      drydock.vwmap
      drydock.recipe.toml
      drydock.metrics.json
      drydock.svg
      ... five more map families
```

Each `.vwmap` is playable content. Its recipe, metrics, and SVG are authoring
and review artifacts kept beside it. There is no `modules/` tree or runtime
WebAssembly content. Modes are built into the Rust server.

## `catalog.toml`

The top-level file declares zones instead of discovering directories. Removing a
zone is therefore a reviewed change, and an unfinished directory cannot become
live merely because it exists.

```toml
version = 22
name = "vectorwake"
description = "the reference deployment"
default_zone = "melee"
bans = []

[meta]
url = "https://play.vectorwake.net/meta"
key = "env:VW_META_VERIFY"

[[staff]]
name = "chris"
capabilities = ["ban", "catalog", "kick", "drain", "pin", "reload"]

[[pool]]
name = "vultr atl"
token = "env:VW_POOL_DIGEST"
region = "atl"
max_instances = 8

[[zone]]
name = "melee"
# dir = "zones/melee"       # optional; this is the default
```

`version` must be nonzero. Arena servers prefer the highest catalog version
they receive, so a rollback publishes the older content under a new, higher
number.

Pool tokens are stored as `sha256:` plus 64 hexadecimal characters. The
committed reference uses `env:VW_POOL_DIGEST`, which names an environment
variable holding that public digest. The raw token never enters the catalog.

The meta key is the 64-character Ed25519 verifying key printed by
`vectorwake-server metakey`, or an `env:` reference to it. Its signing half
lives in the meta-layer environment. Omitting the whole `[meta]` block makes a
deployment with no accounts; setting a URL without a key is an error.

An `env:` reference must resolve to a nonempty value when the catalog loads.
`fleet.sh` fills the reference deployment's values from the secrets bucket.
Tests and local debug runs use obvious placeholder public values.

## `zone.toml`

A zone file selects a built-in mode, an ordered map rotation, room policy, team
policy, and simulation tuning. This is a shortened current example:

```toml
label = "Team Battle"
mode = "melee"
maps = [
  "drydock.vwmap",
  "relay.vwmap",
  "convoy.vwmap",
  "shoal.vwmap",
  "breakwater.vwmap",
  "switchyard.vwmap",
]

max_players = 8
max_ships = 8
bot_fill = 1.0
fill_target = 8
max_rooms = 10

teams = ["Pylon", "Caisson"]
max_teams = 2
max_humans_per_team = 4
max_bots_per_team = 4
admission = "any"

[arena]
match_seconds = 180
intermission_seconds = 15
bounce = 12
friction = 12
respawn_delay = 200
bounty_base = 1
bounty_per_kill = 1

[arena.kit]
gun_mods = { multi = 5, bounce = 1, freeze = 1 }
bomb_mods = { prox = 1, shrapnel = 3, bounce = 2, freeze = 1 }
charges = [3, 3, 6]

[[arena.weapons]]
name = "burst"
damage = 515
```

The zone fields are:

| Field | Meaning |
|---|---|
| `label` | What players read the game as, where it differs from the zone's key. The key is what a join names and what a rating is filed under, so renaming the game a player sees cannot move either. |
| `mode` | `arena`, `warzone`, or `melee`. |
| `maps` | One or more `.vwmap` files relative to the zone directory, in rotation order. |
| `max_ships` | Total seats in one room, bots included. A ship index is one byte, so 255 is the parse ceiling. |
| `max_players` | Human seats in one room. |
| `fill_target` | Human occupancy required before the fleet opens another room or instance. |
| `bot_fill` | Share of `max_ships` the bot roster fills, from 0 through 1. |
| `max_rooms` | Maximum simulations one arena process may hold. Rooms are created on demand. |
| `teams` | Public team names in scoring order. An empty list is free-for-all. |
| `max_teams` | Total public and private teams the room may hold. It cannot be below the named team count. |
| `max_humans_per_team` | Human seats allowed on one team. |
| `max_bots_per_team` | Bot seats allowed on one team. |
| `admission` | `any` or `claimed`. |
| `max_watchers` | Watcher connections admitted beside the player seats. |

`[arena]` is the simulation settings overlay. Missing values keep the core
baseline, while zero remains a real value. The current field set is defined by
`ArenaConfig` in `server/src/config.rs`, and the shipped Melee file is the full
working example. Hull flight tuning and collision footprints are not zone
fields. Hull-specific entries can choose gun and bomb ladders, while kit limits
are shared by every hull.

Unknown keys are refused at every level. That strictness is deliberate: a
misspelled setting that silently falls back is a deployment that appears to
work while running a different game.

## Validation

`vectorwake-server catalog catalog` loads the same files the fleet uses and
prints either a summary or an actionable refusal. Loading rejects at least the
following states:

| Rejected | Reason |
|---|---|
| Version zero | Arena servers choose catalogs by version. |
| A pool token that is not a SHA-256 digest | A plaintext or malformed registration credential must not load. |
| An empty or missing `env:` value | Empty has deployment meaning and cannot result from a forgotten variable. |
| An invalid meta verifying key, or a meta URL without a key | Every account token would fail at the arena door. |
| No zones, an unnamed zone, a duplicate zone, or an unknown default zone | The offered game list would be ambiguous or empty. |
| An unknown mode or admission policy | Falling back would turn an authored rule into a dead key. |
| Blank team names, more than 254 teams, or `max_teams` below the named team count | Team IDs use a byte where 255 means none. |
| No maps or a missing map file | The zone would be listed but unplayable. |
| `max_ships` or `max_rooms` equal to zero | The room or process could hold nothing. |
| `fill_target` above `max_players` | The concentration rule could never advance. |
| `bot_fill` outside 0 through 1 | It is a share of room seats. |

## Distribution

Deployment gives each directory the catalog artifact. An arena receives it on
registration and again when the directory publishes a newer version. The
catalog is not fetched from an authoring service at runtime, and directories do
not vote on its contents. The highest version wins; equal-version disagreement
is an authoring error to log and fix.

The artifact carries configuration, not authority over live processes. Which
arena serves a zone, how many rooms it holds, and who is playing are observations
kept by the directory. Accounts, ratings, friends, and match records belong to
the meta-layer. Keeping those boundaries is what lets the catalog remain a
reviewable file instead of becoming another database.
