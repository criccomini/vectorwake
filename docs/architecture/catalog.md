# The catalog

The catalog is the versioned description of one deployment. It names the games
the fleet offers, the files behind them, the pools allowed to register capacity,
and the public half of account identity. Directories load it and hand it to
arena servers.

The catalog is authored as files in Git. Live facts such as room occupancy,
instance health, and ratings do not belong here. Directories and the
meta-layer own those.

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

`default_zone` must name a declared zone. It answers two questions with one
line: what an arena serves when nothing has told it, and which game a client
that has not chosen one opens on. The second travels to clients in the browse
reply, where [discovery.md](discovery.md#the-browse-reply) says what a client
does when the front door is down.

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
policy, and whatever simulation tuning makes it a different game from the one
the core ships. What it leaves out it plays as shipped, which is how five zones
share a ship, a wall and an economy without any of them holding a copy. This is
a shortened current example:

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
spawn_radius = 0
```

The zone fields are:

| Field | Meaning |
|---|---|
| `label` | What players read the game as, where it differs from the zone's key. The key is what a join names and what a rating is filed under, so renaming the game a player sees cannot move either. |
| `mode` | `arena`, `warzone`, `melee`, or `turf`. |
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
`ArenaConfig` in `server/src/config.rs`.

Write a key only where the zone wants a different answer from the baseline's.
That is not a style rule. The five shipped zones each restated about twenty
settings once, most of them already the baseline's own value and the rest Team
Battle's tuning copied four times, which meant every tuning pass had five files
to remember and a catalog that could disagree with itself about the wall while
loading cleanly. The numbers are in `sim/src/baseline.c` now, and the shipped
zone files are the worked examples of how short a zone gets:
`catalog/zones/duel/zone.toml` is a room shape, a map list and a clock, and
`catalog/zones/roam/zone.toml` is the longest because it is the most different.
`every_shipped_zone_flies_the_same_ship` in `server/src/main.rs` is what holds
the line: it applies each zone, blanks the fields a zone is allowed to differ
on, and fails if what is left is not identical across the catalog.

Three groups in there are what a zone reaches for to be a different game rather
than a differently tuned one:

| Field | Meaning |
|---|---|
| `flags` | How many of the map's flag stands this zone plays for. Absent is all of them. Flags come down but never up: where a stand is belongs to the map, which draws them with `SIM_TILE_TURF`, and a map that draws none is not a flag game. |
| `flag_carry` | Whether taking a flag picks it up. True is Capture the Flag, where a flag rides its taker and drops where they die; false is Turf, where a stand changes hands where it stands. |
| `flag_carry_seconds` | How long one pilot may hold a flag before it drops on its own, keeping their side. Absent or zero is no limit. |
| `turf_seconds` | Seconds between two turf payouts, each paying a side one point per stand it holds. Turf only. |
| `greens` | Greens the room keeps on the field. Absent or zero is a zone with none, which is every match game. |
| `green_seconds`, `green_every_seconds` | How long one lies there, and how often one is put out. |
| `green_near_tiles`, `green_far_tiles` | The ring around a live pilot a green may appear in. See [design/maps.md](../design/maps.md) for why greens are placed around people rather than over the map. |
| `green_radius` | Px a green is taken from, past the hull's own edge. |

`[arena.green_weights]` is what a green may be, by kit slot name, weighted
against the sum of them all. An empty table is no greens whatever `greens`
says, since there would be nothing for one to be. The slot names are the ones
the rest of a zone file uses: a stat by its own name (`energy`, `recharge`,
`speed`, `thrust`, `rotation`), a weapon rung as `gun` or `bomb`, an add-on as
`gun.multi` or `bomb.prox`, and a charge as `repel` or `burst`. A name that is
not a slot is reported rather than ignored.

`[[arena.ships]]` is one hull, named, and it is a flight row: `speed`,
`thrust`, `rotation`, `energy`, `recharge`. A hull left out keeps the
baseline's row for it, so a zone retunes one ship without restating the other
six, and no zone in this catalog writes the block at all.

Nothing about a weapon is in it. A hull is how it flies; the gun, the bomb and
the two charges belong to the arena, and a pilot's seven credits say what they
carry, so a zone tunes a weapon by name under `[[arena.weapons]]` and the whole
room gets it. Collision footprints are not zone fields either: every hull
occupies the same 625 square pixels and the shapes are the core's.

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
kept by the directory. Accounts, ratings, and match records belong to
the meta-layer. Keeping those boundaries is what lets the catalog remain a
reviewable file instead of becoming another database.
