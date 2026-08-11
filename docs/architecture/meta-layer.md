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
| credentials | account, method (`secret`, `password`, `steam`, more later), identifier or hash. A human account whose only credential is its secret is a guest |
| names | account, call sign, unique fleet-wide under a case-insensitive index |
| rated_events | the log [rating.md](../design/rating.md) specifies: participants, weights, ratings before and after, arena, mode class, opponent kind, timestamp |
| ratings | account, mode class, rating, games. A projection, rebuildable from `rated_events` at any time |

A house bot needs no table of its own: the roster individual's name *is* its
credential, a `house` row in `credentials`, so claiming the account for one is
the same lookup as logging in and an individual is one account however many
times the bot server restarts.

The label a seat wears, human, bot, or unknown, is derived rather than stored:
bot kinds are bots, a human account with a credential beyond its secret is
human, and a human account with only its secret is unknown.

## The routes

Every route takes JSON and answers JSON, hand-rolled over a socket for the
same reason `admin.rs` hand-rolls its responder: the surface is small and a
framework would be the larger change.

| Route | Who calls it | What it does |
|---|---|---|
| `/v1/guest` | a client, once ever | Mints an account, deals it a call sign nobody else holds, and returns its secret. Throttled per address, since free account creation is how the name pool would be burned |
| `/v1/session` | a client, once a session | Secret in, session token out. Where fleet bans are enforced, and the liveness the guest sweeper reads |
| `/v1/claim` | a client | Sets the account's password: claiming and changing it are the same call |
| `/v1/login` | a client | Call sign and password on a new device, which gets a secret of its own. Throttled per address and per name |
| `/v1/rename` | a client | A fresh call sign from the pool; the account and its record stay put |
| `/v1/bot` | the bot server, with a pool token | The account for one roster individual, the same one every time. A new one is seeded from the calibrated ladder |
| `/v1/bot/register` | anyone, with a claimed account | A third-party bot account under that owner, who answers for it |
| `/v1/events` | an arena, with a pool token | Rated events, appended to the log and applied to the projection |
| `/v1/ban` | an operator, with the admin token | Marks an account, which takes effect at the next token issuance |

A client learns the address from the directory's games list, which is the one
thing it asks for before it needs an identity. That keeps the account system a
property of the deployment rather than of the build, and it means a client
pointed at a fleet without accounts simply never signs in.

## The session token

A session is the client presenting its device secret and receiving a
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

A new device rides the same door: call sign and password in, a device secret
of its own out, per [accounts.md](../design/accounts.md). A guest that has not
begun a session in a week is deleted by the sweeper, name and all; claimed
accounts are never swept.

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

The spool is the one new thing on an arena's disk: a JSONL file, appended to
inside the tick and drained by a background task every few seconds. Batches
that cannot be delivered wait there and survive a restart, and a spool is a
buffer rather than a database: an arena destroyed mid-spool loses those events
and nothing else, which is the same bounded loss the fleet already accepts for
a room in progress.

Delivery is at-least-once, and the meta-layer is what makes that safe. A
spool retries a whole batch when any of it fails, and a batch that committed
under a lost reply gets posted again, so events arrive twice in ordinary
operation. Each one carries an id the arena mints when it files it; the log
is unique on that id, and a second arrival is refused without touching the
projection. Without the refusal a retry would re-add deltas the log recorded
once, which is how a rating drifts from its own history.

Only participants with accounts travel. A guest is rated inside the room and
forgotten when it ends, so an event where the victim has no account is not
sent at all, and a guest contributor is dropped from one that is. Sending them
would be reporting a pilot nobody can look up.

`persist.rs` and `ratings.json` are gone. The records they held were keyed by
generated guest names on one box, which nobody can claim, so nothing migrated:
human careers start when accounts arrive.

The calibrated ladder now enters the fleet here rather than in a room. A room
primes its bots by name, and that stopped reaching them the moment their rating
moved to an account, so `/v1/bot` seeds a new house bot account with what the
offline tournament measured. The pinned anchor is the case that matters most:
everything else in the fleet is measured against it, so it has to be at its
rating from the first tick rather than climb to it.

## What the log costs

The event log grows forever by design, and the rate it grows at is not set by
how many people are playing. It is set by the bots, which fight around the
clock at bot fill whether or not anybody is watching.

Measured on the live fleet: Chaos alone resolves about 1.8 deaths a second with
its rooms full, so three arenas run somewhere near 3 to 4 a second, which is
roughly 300,000 events a day and 100 million rows a year. At 400 to 500 bytes a
row with its indexes, that is 40 to 50 GB a year against the 25 GB the
hobbyist plan holds. So the disk fills in six to nine months.

Throughput is not the problem and will not be for a long time. A batch arrives
every five seconds, each event is one small transaction, and the projection
update is an indexed upsert per participant. That is single-digit transactions
per second against a database that does thousands on one vCPU, and login is a
primary-key lookup. What runs out is space.

What is kept follows from what the log is for. The rows worth keeping forever
are the ones with a human in them, because a model migration or a disputed
rating replays those; bot-on-bot events have done their work the moment the
projection applies them, and a bot's career re-seeds from calibration anyway.

So every event carries a `bots_only` flag, set in the arena because that is the
only place that knows which pilot was a person, and an hourly sweeper deletes
bot-only rows older than three weeks. Everything with a human on either side
stays. A partial index covers exactly the rows the sweeper is looking for,
which in steady state is one hour's worth of newly expired events in a table of
millions.

This is a plainer mechanism than the partitioning this document used to
specify, and the reason is what partitioning would have cost around it. Dropping
a partition is cheaper per row than deleting one, but it needs the table
partitioned by bot-only and by month at once, a job to create next month's
partitions ahead of time, and a migration for the table already in service.
A month nobody created is a month that refuses every write. Measured on a
database loaded with a day of fleet production, a sweep costs about 16
milliseconds, which is far enough below one vCPU's idle capacity that the extra
machinery buys nothing.

The cruder alternatives are worth naming so they are not rediscovered as
insights. Not spooling bot-vs-bot events at all would break the rule that a
rating is a projection of the log, for bots. Buying a larger plan defers the
question by about a year per step and answers nothing.

[Decision 15](decisions.md#15-rating-is-damage-weighted-pairwise-elo-stored-as-an-event-log)
priced this as "an event log that grows forever" and meant it, but the estimate
behind it assumed human-speed growth. Giving bots accounts is what changed the
rate.

The same stream has a second, smaller home worth knowing about: an arena keeps
`Rating::log` in memory for the life of a room, so a busy room accretes on the
order of 15 MB a day until it empties and is reclaimed. Not a database problem
and not urgent, since a room that never empties is a room somebody is enjoying,
but it is the same unbounded thing in a place nobody is watching.

## Turning it on over a running fleet

Two things do not happen by themselves, and both were found by turning it on.

The bot server claims a bot's account when that bot joins, so bots already
flying when the meta-layer arrives keep flying without one. Restart it and the
whole population reconnects with accounts and the calibrated ladder behind
them, the anchor included. Left alone it resolves only as bots are evicted and
refilled around arriving players, which in a quiet room is never.

Until that happens the ladder does not move at all, and the reason looks like a
fault but is the rule working: a death with an accounted victim and no
accounted killer is dropped rather than sent, because there is nobody to credit
and the alternative is letting anybody farm a real pilot's rating down from a
throwaway account.

## Turning reporting off

`VW_REPORT=0` on an arena stops it filing anything, and stops nothing else.

Pilots still sign in, still arrive carrying the rating they earned, and still
watch it move on the scoreboard, because a room rates its own exchanges and
always did. The meta-layer keeps running and keeps serving tokens. What the
arena stops doing is posting the result, so the ladder in the database does not
move on anything that happens there.

It is the same machinery an accountless deployment uses rather than a second
path: the spool is simply never aimed, and an unaimed spool writes nothing and
posts nothing. That is checked in `spool.rs`, which is the invariant the switch
rests on.

The default is on, and deliberately that way round. Reporting is what the
ladder is made of, so a deployment that quietly kept its results to itself
would be a worse surprise than one that quietly sent them: the off switch has
to be something an operator wrote down. Only `0`, `off`, `false` or `no` count
as off; a typo meant to silence a fleet leaves it recording rather than
silently stopping it.

Events raised while it is off are dropped where they are made, not queued, so
turning it back on starts from then. Anything already spooled from before is
still owed and is held, and the arena says so once at startup.

What this does not do is unsay anything already recorded. A fleet that has been
reporting has rows in the database, and turning the switch off leaves them
exactly where they are.

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
Postgres in the same region. Arenas and the bot server reach it on loopback
through `VW_META`, rather than through the public address the catalog carries
for clients, so their traffic never leaves the box. The account secret is a random 256-bit bearer
value, minted by the service and carried only over TLS; the password, the one
credential a person chooses, is stored argon2-hashed rather than sha256,
because chosen strings are guessable and minted ones are not. There is no external dependency at all: no mail
sender, no OAuth registration, nothing to sign up for. The service also holds
no personal data, no email addresses, and no names beyond generated call
signs, so a breach would disclose a ladder rather than anybody's identity, and
vectorwake.net's mail-free DNS stays exactly as the security pass left it.

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
