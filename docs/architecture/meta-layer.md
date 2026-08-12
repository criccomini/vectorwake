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
| accounts | id, kind (`human`, `house_bot`, `third_party_bot`), created, standing, the admin flag that opens [the panel](admin.md), and the owner id when the kind is a third-party bot |
| credentials | account, method (`secret`, `password`, `steam`, more later), identifier or hash. A human account whose only credential is its secret is a guest |
| names | account, call sign, unique fleet-wide under a case-insensitive index |
| rated_events | the log [rating.md](../design/rating.md) specifies: participants, weights, ratings before and after, arena, mode class, opponent kind, timestamp |
| pilot_events | what happened to a pilot rather than to their rating: arrivals, refusals, hull and side changes, departures and why, tied together by a session. See [the pilot log](#the-pilot-log) |
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
| `/v1/pilot-events` | an arena, with a pool token | The pilot log, appended. No projection to keep in step, because nothing the game reads back is derived from it |
| `/v1/admin/fleet` | the admin panel | Every instance the directory on this host has observed, relayed from it over loopback, plus the catalog version and whether its verifying key is the one this process signs with |
| `/v1/admin/pilots` | the admin panel | Pilots matching what an operator has typed, most recently seen first, searched in the database rather than filtered in the page |
| `/v1/admin/grant` | the admin panel | Gives or takes the admin flag. Claimed humans only, and never the last admin |
| `/v1/admin/pilot` | the admin panel | One pilot by call sign or number: kind, standing, the dates. Behind the account flag |
| `/v1/admin/ban` | the admin panel | A fleet ban, which takes effect at the next token issuance. Refuses accounts that hold the flag |
| `/v1/admin/bans` | the admin panel | Every account currently marked, with its reason |
| `/v1/admin/events` | the admin panel | One pilot's recent history out of the pilot log, or one stay out of it |
| `/v1/admin/recent` | the admin panel | The same log across the fleet, people or bots, optionally one kind, within a time bound. Reports when each kind last filed, so an empty answer says which sort of empty it is |
| `/v1/admin/rename` | the admin panel | Sets a pilot's call sign to a typed one, or deals a fresh one when nothing is typed. Refuses a taken name and refuses a bot, whose name is its roster identity |
| `/v1/admin/admins` | the admin panel | Who holds the flag |

The `/v1/admin` block is the panel's, and [admin.md](admin.md) is its design.
The one rule those routes live by: the `admin` field `/v1/session` answers
with is what the page draws, never what the server trusts. Every admin route
resolves the presented secret and checks the flag in the database itself.

The flag is granted from the panel by whoever already holds one. The first
admin of a deployment is the exception and is made in the database, because
there is nobody to grant it yet; `deploy/README.md` has that command.
[admin.md](admin.md) records what moving this out of the database cost.

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

## The pilot log

`rated_events` answers what a fight did to somebody's number. It does not
answer where they were, how they got in, or why they stopped being there, and
those are the questions anybody actually asks when something goes wrong. A room
knows all of it and keeps none of it: the tick that produced the fact is the
last thing that holds it. When a player says they were bounced from a zone, the
only party that knows which of five refusals they were given is the player.

So there is a second log, on the same road as the first. An arena appends a
line to `pilot.jsonl`, the tick moves on, and a background task posts batches
to `/v1/pilot-events`. Same pool credential, same at-least-once delivery, same
arena-minted id and unique index making a replay harmless. What is different is
that nothing is projected from it. No part of the running game reads this table,
so a row that never arrives costs a question somebody cannot answer later and
nothing else.

### What a session is

Every row carries a session, which is one connection to one arena, minted at
the door before anything can be refused. It rides on the seat rather than
beside the socket, and that placement is the whole trick: a pilot's handles get
reissued underneath them twice over, because sitting out retires the seat and
flying again allocates a fresh player id in a room whose position in the
arena's list may have moved. Keying on any of those would cut one stay into
unrelated pieces.

A session does not span arenas. Crossing to another zone is a new connection
and a new session, and the thing that ties those together is the account, which
is on every row a pilot with one produces. Guests have no account, so a guest's
history is exactly one session long. That is a real limit and the honest one:
the alternative is a durable handle for somebody who has deliberately not told
us who they are.

### What is tracked

Thirteen kinds from an arena. Eleven are changes of state rather than things
that happen every tick, and two are combat. Combat started outside this log on
the reasoning that `rated_events` already keeps every death and a log should
not say things twice; what that produced was a session that read as a join and
a leave with an hour of silence between them. So the human-involving deaths
are filed here too, as the pilot's own rows. The rated log stays the authority
on what a death did to the ladder, this one says it happened to this person in
this room, and bot-on-bot deaths, the overwhelming bulk of every hour, still
never enter. Firing and hitting stay out: they are per-tick, and the sim is
where they live.

| Kind | When | Carries |
|---|---|---|
| `join` | seated in a room | hull, sim slot, side, label, transport |
| `denied` | refused at the door | the deny code, the sentence sent back, the name and zone claimed, protocol, transport |
| `watch` | arrived to spectate | the side they were seated on, and whether they hold the `watch` capability |
| `ship` | a hull change that took effect | from, to |
| `team` | crossed to a side | from, to, whether the side is public |
| `found` | founded a private side | its byte and generated name |
| `invite` | invited somebody to one | who |
| `sit_out` | gave up a hull for the stands | whether they asked or the safe-zone sweep moved them |
| `fly` | took a hull again | hull, sim slot, side |
| `on_air` | became somebody's subject | the slot |
| `leave` | the seat ended | why, the slot, ticks held, and whether it settled as a quit |
| `died` | their hull was destroyed | who by, and what it paid |
| `kill` | they destroyed somebody | who, what it paid, and whether the victim quit the fight |

`leave` is the one that repays the most work. Five callers reach `Room::leave`,
a quit, a sit-out, a bot evicted for an arriving human, a bot sent home by a
drain, and an operator's kick, and until this log existed they were
indistinguishable afterwards. The reason is now a parameter, so the commonest
question about any departure has an answer.

Eight more kinds are written by the meta-layer itself, about an account rather
than a stay: `account`, `claim`, `login`, `rename`, `ban`, `unban`, `grant` and
`revoke`. These carry no session, because there is no connection to tie them to
and inventing one would suggest a continuity that is not there. Failed logins
are not among them. They are already throttled per address and per name, and a
row per guess would let a guessing script size the table.

### What it deliberately holds no room for

No addresses. An arena never learns one, since the accept discards the peer and
the WebTransport session is never asked, and that is a property to keep rather
than a gap to fill. The meta-layer's best quality is that a breach would
disclose a ladder rather than anybody's identity, and a log of how each person
plays, keyed to where they live, is the fastest way to spend it. Correlating two
accounts to one household is the thing this log cannot do, and it is the reason
[community.md](../design/community.md) says a change to that property arrives as
its own decision record.

Nor is it an anti-cheat feed. [networking.md](networking.md) says aim assistance
is a behavioral detection problem we are not solving in the architecture, and
this does not reopen that. It moves one narrower line: [admin.md](admin.md)
notes that an operator can act on a report and not notice one, and this is the
half that lets them act, by making a report checkable against what the fleet saw.

### What it costs, and the two ceilings

Both ceilings exist because half of these are things a pilot can do as fast as
they can press a key.

A session files at most 200 rows, and combat is exempt from the count: a death
is gated by the simulation, which charges a respawn and a flight back before
the next one is possible, so it cannot be flooded, and a long evening of honest
flying must not exhaust the allowance the departure at the end of it needs.
Everything else in an honest stay is somewhere between five and twenty rows,
so reaching the cap is itself the finding, and past it the pilot keeps playing
while the log stops growing on their account. Only changes that
took effect are written at all, which removes most of the rest: the core
refuses a hull or side change for anyone dead or short of a full bar and says
nothing about it, so the asking and the happening are different events and only
one is a row.

Refusals need their own ceiling, because a client looping on one gets a fresh
connection and so a fresh allowance every time, which makes the flooder the cap
cannot see the same client most worth recording. An arena writes at most 60 a
minute. A bot bouncing off a full instance is left out entirely, since that is
the fill ladder working and it is the only refusal that happens by the thousand.

Retention is where this differs most from `rated_events`, and it is stated here
because the section above says plainly that space is what runs out. Nothing in
this table is kept forever. A rated row with a person in it is a claim about
that person that may have to be replayed years later; a pilot event is not, and
after long enough it is just a record of how people play, held by a service
whose whole appeal is holding nothing of the sort. So the same hourly sweeper
runs a second bounded pass: bot rows at seven days, everybody at ninety.

The rate follows the players rather than the bots, which is the point of
leaving routine bot refusals out. A stay is a handful of rows against the 1.8
deaths a second Chaos alone resolves at fill, so this table is a small fraction
of the one beside it and, unlike that one, it converges instead of growing.

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
Both logs, the rated events and the pilot log, since both spools are aimed
together and neither is aimed when the switch is off.

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
