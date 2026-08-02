# The catalog

The catalog is what a deployment *is*. Every zone it offers, every credential it
honours, every ban it enforces, versioned as one artifact and handed to
directories, which hand it to arena servers.

It is also the only part of this architecture with a single author. Everything
else decides for itself; see the thesis in
[zones-and-arenas.md](zones-and-arenas.md) for why that exception exists and
[admin.md](admin.md) for who does the authoring.

## Layout

```
catalog/                        one artifact, versioned as a unit
  catalog.toml                  the deployment: version, zones, staff, bans, pools
  zones/
    war/
      zone.toml                 mode, fill target, rooms per process, settings
      war.vwmap
    chaos/
      zone.toml
      chaos.vwmap
    duel/
      zone.toml
      duel.vwmap
  shared/
    ships/apex.toml             included by zones that want a common roster
    tilesets/standard.png
  modules/
    warzone.wasm
```

Git is the obvious host: the version history, the diffs, and the audit trail come
free, and "who widened Chaos on Tuesday" becomes a question with an answer.

## catalog.toml

```toml
# Bumped by the author on every publish. An arena server takes the highest
# version any directory offers and logs a mismatch rather than voting, so this
# number is the whole of the conflict resolution.
version = 37
name = "vectorwake"
description = "the reference deployment"

# The zone a directory hands an arena server that has never been told anything
# else, and the one an arena falls back to when the catalog names a zone it
# cannot load.
default_zone = "chaos"

# Fleet-wide, because a ban that applies in Chaos and not in War is a support
# ticket waiting to happen. A zone may add its own; see zone.toml.
bans = ["griefer"]

[[staff]]
name = "chris"
capabilities = ["ban", "catalog", "kick", "drain", "pin", "reload"]

# Pool credentials: whose capacity, named by us so it cannot be claimed, with a
# cap on what one leaked token can do. See discovery.md.
[[pool]]
name = "us-east pool"
token = "sha256:9f86d081884c7d65..."
region = "us-east"
max_instances = 20

[[zone]]
name = "chaos"
dir = "zones/chaos"      # optional; defaults to zones/<name>
[[zone]]
name = "war"
[[zone]]
name = "duel"
```

The zone list is a list rather than a directory scan on purpose. Retiring a zone
should be a line removed from a file under review, not a directory quietly
disappearing, and a zone half-written on disk should not become live because a
scan found it.

## zone.toml

One game. The name is the same file the old model used, and it keeps that name
because it always described a game rather than a host: the listen address, the
TLS paths and the player cap that used to sit alongside are gone, since those
belong to a process and this belongs to a deployment.

```toml
description = "four flags, eight hulls"

mode = "warzone"          # warzone | arena | duel; read now, unlike before
map = "war.vwmap"         # relative to this zone's directory

# How many pilots a room holds, bots included. 255 is the wire's ceiling. Absent
# keeps the core's 64. See hosting.md for why 64 and not more.
max_ships = 64

# How many humans of those seats people get, which is what leaves the bot roster
# somewhere to sit.
max_players = 16

# The concentration rule. An arena server opens another instance of this zone
# only when every live instance is at or above this, so it is the number that
# decides whether a population concentrates or scatters. The original's
# equivalent, General:DesiredPlaying, defaulted to 15.
fill_target = 20

# Rooms one process holds. War wants one, because a 64-player fight deserves its
# own blast radius. Duel wants a hundred, because a room is 79 KB and they share
# a map.
rooms_per_process = 1

# Everything below is the settings surface that already existed, unchanged.
[arena]
flags = 4
bounce = 10
friction = 14
respawn_delay = 300
spawn_prizes = 0

[[arena.ships]]
name = "Apex"
speed = 4900

[[arena.weapons]]
name = "anvil-bomb"
on_wall = "bounce"
```

Three fields are new and the rest is the zone file we already had, which is the
point: a zone was always mostly settings, and what this adds is the handful of
facts a fleet needs to place it.

## What validation must reject

A catalog that loads badly is worse than one that fails to load, because a
half-applied deployment is hard to diagnose from inside a game. So the author's
tooling validates and the directory validates again on load:

| Rejected | Because |
|---|---|
| A `[[zone]]` whose directory or map is missing | The zone would be listed and unplayable |
| `mode` naming something the server has no constructor for | Silently falling back to warzone is how `arena.mode` came to be a dead key |
| `max_ships` above 255 | The wire cannot address it; clamping quietly hides an operator's mistake |
| `fill_target` above `max_players` | The rule would never fire and the zone would never scale out |
| `rooms_per_process` of zero | A process that holds no rooms is a process doing nothing |
| Two `[[zone]]` entries with one name | Which one a client joins would depend on parse order |
| A `[[pool]]` token that is not `sha256:` and 64 hex digits | A plaintext token in the catalog is a leaked token |
| A `version` not greater than the one being replaced | Arena servers take the highest; a rollback needs a new higher number, not a reused one |

That last row is worth stating plainly because it is the surprising one. To roll
back, publish the old content under a *new, higher* version. Version numbers are
a sequence, not a label, because "highest wins" is the only conflict rule in the
design and it has to be total.

## Distribution

The author publishes a version. Each directory is given the artifact by whatever
deploys it, a git pull or an image build. Directories do not fetch it from each
other and do not fetch it from the author at runtime, because a directory that
depends on the authoring side being up is a directory that stops working when it
is not.

An arena server receives the catalog on the registration socket, in `ACCEPTED`
and again in `CATALOG` when it changes. It takes the highest version offered,
logs any disagreement with the pool name and version each directory reported,
and keeps what it holds when versions tie but content differs. That last case is
an author error rather than a race, and the log line is how it gets found.

A running arena does not switch zone because the catalog changed. It applies new
*settings* for the zone it is already serving, which is the live reload that
already works, and takes the rest of the change at its next drain. A catalog
edit is not a reason to disconnect a room.

## What the catalog is not

It holds no runtime state. Which arena serves what, who is playing, how full a
room is, and which instances exist are all observations, and they live in the
directories that observed them and nowhere else. Anything the catalog held about
a live process would have to be written by a directory, which would make the
catalog a database with many writers rather than an artifact with one author,
and the single-author property is what lets it be a file in git.

It also holds no identity. Accounts, ratings, friends and the durable record of
who played what belong to the meta-layer per
[decision 11](decisions.md#11-nakama-for-the-meta-layer-never-for-the-arena-tick),
and keeping them out of both the catalog and the directory is what lets a
directory be a process you can lose.
