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
      zone.toml                 mode, fill target, room cap, teams, settings
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

# Where accounts live, and the key every arena checks session tokens against.
# `vectorwake-server metakey` prints both halves: the signing key goes in the
# meta-layer's environment and this one goes here. Absent means a deployment
# without accounts, which works: everyone flies as a guest and nothing durable
# is written. A url without a key is refused, since no arena could check a
# token minted by it.
[meta]
url = "https://play.vectorwake.net/meta"
key = "ecfb32390297ac33057396977f67b62f9ec265564bd20377a827ad00716c8f96"

[[staff]]
name = "chris"
capabilities = ["ban", "catalog", "kick", "drain", "pin", "reload"]

# Pool credentials: whose capacity, named by us so it cannot be claimed, with a
# cap on what one leaked token can do. See discovery.md.
[[pool]]
name = "us-east pool"
token = "env:VW_POOL_DIGEST"   # or "sha256:9f86d081884c7d65..." inline
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

### Two values the catalog names rather than carries

`[[pool]] token` and `[meta] key` accept `env:NAME`, resolved when the catalog
loads. Both are public halves, safe to commit, and both were committed. The
trouble was what they are paired with. The raw pool token and the meta signing
key reach a host in its `.env` and nowhere else, so rotating an identity meant
editing this file, pushing, waiting for an image, and then editing a `.env` per
host, with a window in between where the published half had moved and no host
had. `env:` puts both halves in one file, from one place, changed at once.

Nothing else about distribution changes, because only two processes read these
and both run on the central host: the directory checks a registering arena's
token against the digest and hands the verifying key to arenas over the wire,
and the meta-layer checks the digest when a bot claims an account. An arena
never reads either from a catalog file.

A resolved value faces exactly the checks an inline one does, so a digest that
is not `sha256:` and 64 hex is still a refusal. An unset or empty variable is
one too, because empty means "no pool" and "a deployment with no accounts", and
neither is a thing to arrive at by forgetting.

The cost is that the shipped catalog no longer loads from a bare checkout.
`catalog::set_placeholder_identity()` supplies obvious non-values for tests,
drills and local runs; a host gets the real ones from `fleet.sh`.

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
max_players = 32

# How full the bot server keeps this zone's rooms: bots fill to this share of
# max_ships and stand down one for one as others arrive. The unfilled remainder
# is headroom, so a human join rarely has to evict anybody. Absent it is 0.8,
# and zero is a zone with no bots. See ai-runtime.md and decision 29.
bot_fill = 0.8

# The concentration rule: another room or instance opens only when every live one
# is at or above this, so it is the number that decides whether a population
# concentrates or scatters. Absent it is 15, which is General:DesiredPlaying's
# default in ASSS and what thirty years of the original settled on for a public
# room. It must not exceed max_players, or the rule can never fire and the zone
# can never grow, which is a validation error rather than a warning. It counts
# humans only: bots hold every room at bot_fill regardless, and a rule that
# counted them would read every botted room as ready to scale and grow the
# fleet without end.
fill_target = 20

# The most simulations one process may hold for this zone. Rooms are created on
# demand up to this and reclaimed when they empty, so it is a ceiling and not a
# count. It bounds memory at max_rooms x 107 KB plus one shared map, and it bounds
# the blast radius, since rooms in a process share its fate: War keeps 1 because
# sixty-four players should not lose a flag game to somebody else's crash, and
# Duel takes 100 because a duel is two people and a fresh room.
max_rooms = 1

# The zone's own sides, by name, in the order the mode scores them. Names are
# what players see, and they are stable across rounds on purpose so a side is a
# place rather than a number. An empty list is a free-for-all: no side to join,
# every pilot their own. See design/teams.md.
teams = ["Keel", "Vantage"]
# The three caps, which are the whole team policy: the most sides this room may
# hold at once counting its own, and how many of each kind fit on one. Writing
# max_teams as the count of the zone's own sides is how a zone says no player
# may found one.
max_teams = 2
max_humans_per_team = 8
max_bots_per_team = 26

# Who this zone lets in: "any", the default, or "claimed" for a room that wants
# a field it can vouch for. The bar is on the label a seat wears, which comes
# from the account rather than from anything a client asserted. Most rooms
# should stay "any": the cost of caring is a newcomer turned away in the second
# they arrived. See design/accounts.md.
admission = "any"

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

Everything under `[arena]` is the zone file we already had. What is new above it
is the handful of facts a fleet needs in order to place a game rather than tune
one: where it runs, how full is full, how many rooms to a process, and what a team
means here. A zone was always mostly settings, and it still is.

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
| `bot_fill` outside 0 to 1 | It is a share of `max_ships`; above one the target is unreachable, below zero it means nothing |
| `max_rooms` of zero | A process that may hold no rooms cannot serve the zone |
| Two `[[zone]]` entries with one name | Which one a client joins would depend on parse order |
| A `[[pool]]` token that is not `sha256:` and 64 hex digits | A plaintext token in the catalog is a leaked token |
| An `env:` naming a variable that is unset or empty | Empty means "no pool" and "no accounts" to the checks below, and neither should be reachable by forgetting a variable |
| A `[meta]` key that is not 64 hex characters of Ed25519 verifying key | Every session token in the fleet would fail at the door |
| A `[meta]` url with no key | No arena could check a token the meta-layer minted |
| `teams` of zero | Every pilot needs a team; one team is a free-for-all, none is nothing |
| `balance` naming something unimplemented | The same dead-key failure as `mode`, one field over |
| `admission` that is not `any` or `claimed` | The same again, and reading it as the default would silently open a zone meant to be closed |
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
[decision 30](decisions.md#30-the-meta-layer-is-ours-and-identity-leaves-nakamas-list),
and keeping them out of both the catalog and the directory is what lets a
directory be a process you can lose. What the catalog does carry is the
meta-layer's token-verifying key, since it is already the versioned artifact
every arena receives whole, which makes key rotation a publish.
