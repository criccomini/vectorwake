# The meta-layer

One service owns everything durable about a pilot: `vectorwake-server meta`,
the fourth face of the binary that is already an arena, a directory, and a bot
server. Behind it is PostgreSQL, bought as a managed database per
[decision 27](decisions.md#27-vultr-for-everything-in-docker-with-the-database-bought)
rather than run by us. In front of it is the rest of the fleet, which is
designed to need it rarely and briefly.

[accounts.md](../design/accounts.md) says what an account is. This document is
where accounts live, how an arena trusts one without calling anybody, and how
rated events get here. [Decision 30](decisions.md#30-the-meta-layer-is-ours-and-identity-leaves-nakamas-list)
records why this is our own service rather than Nakama.

## What it holds

| Table | Contents |
|---|---|
| accounts | id, kind (`human`, `house_bot`, `third_party_bot`), created, standing, and the owner id when the kind is a third-party bot |
| credentials | account, method (`secret`, `email`, `steam`, more later), identifier. A human account whose only credential is its secret is a guest |
| names | account, call sign, whether it is reserved |
| rated_events | the log [rating.md](../design/rating.md) specifies: participants, weights, ratings before and after, arena, mode class, opponent kind, timestamp |
| ratings | account, mode class, rating, games. A projection, rebuildable from `rated_events` at any time |
| roster | house bot account to roster individual, per [ai-players.md](../design/ai-players.md) |

The label a seat wears, human, bot, or unknown, is derived rather than stored:
bot kinds are bots, a human account with a credential beyond its secret is
human, and a human account with only its secret is unknown.

## The session token

Login is the client presenting its account secret and receiving a session
token: account id, kind, label, call sign, a rating snapshot per mode class,
and an expiry, fifteen minutes by default. The token carries an Ed25519
signature, and every arena holds the verifying key, so admission is a signature
check and a clock. Nothing on the join path talks to the meta-layer or to
Postgres.

This is the property [server.md](server.md) has been protecting since before
the service existed: identity is an opaque token the session layer validates,
and which authority issued it stays out of arena code. The verifying key
travels in the catalog, which arenas already receive versioned and whole, so
key rotation is a catalog publish.

Fleet bans are enforced here and only here. A banned account is refused a
token, which is why no arena carries a fleet ban list and why a ban takes
effect within one token lifetime.

## Rated events leave the arena

An arena batches rated events and posts them with its pool credential, and the
meta-layer appends them to the log and advances the rating projection. This
closes the question [server.md](server.md) left open, and it lands on the
meta-layer rather than the directory for the reason that document predicted:
the directory is the piece we most want to be able to lose, and the event log
is the piece we can least afford to.

Two instances of one zone can now both rate the same pilot without
disagreeing, which is M7.7's exit test. Both submit events, the log orders
them, and the projection is computed in one place. What an arena shows
mid-session is its own running ledger, so the in-room rating display is a
prediction of the authoritative number in exactly the way a client's sim is a
prediction of the arena's: small, brief disagreement, converging on the
authority.

The spool is the one new thing on an arena's disk. Batches that cannot be
delivered wait there and drain when the service returns, and a spool is a
buffer rather than a database: an arena destroyed mid-spool loses those events
and nothing else, which is the same bounded loss the fleet already accepts for
a room in progress.

`persist.rs` and `ratings.json` retire when this lands. The records they hold
are keyed by generated guest names on one box, which nobody can claim, so
nothing migrates: human careers start when accounts arrive, and house bots are
reseeded from the calibration ladder under their new accounts.

## When it is down

The meta-layer is allowed to be down, and the fleet's job is to make that
boring. A client holding a live token joins and plays normally. A client with
an expired token, or none, still flies: the arena admits it as an unknown
guest with a room-local name and rates nothing, which is exactly what every
pilot was before this service existed. What an outage costs is persistence and
claiming, never play, and never the arena tick, which touches no database in
any design this repository has ever had.

## Operations

One more container beside the directory on the existing host, and the managed
Postgres in the same region. The account secret is a random 256-bit bearer
value, minted by the service and carried only over TLS. Claiming adds the one
new external dependency, an email sender for magic links, and the DNS for
vectorwake.net is currently locked down to send and receive no mail at all, so
loosening that deliberately is part of the work rather than a surprise after
it.

## What it does not do

It never touches the arena tick, per
[decision 11](decisions.md#11-nakama-for-the-meta-layer-never-for-the-arena-tick),
whose title outlives its Nakama half. It is not the directory, holds no view
of live arenas, and cannot make a room exist. It holds no zone configuration,
because the catalog stays a file in git with one author. And it has no social
surface, because there is no chat, per
[decision 28](decisions.md#28-no-chat), and no friends yet.

ASSS's score intervals, forever, per reset, and per game, belong in this
schema when tournament and league play arrive, as [server.md](server.md)
already notes.
