# The admin surface

## The hazard

"See and control the fleet" pulls straight back toward the central authority that
[zones-and-arenas.md](zones-and-arenas.md) exists to avoid. Commands need
somewhere to land, landing places accumulate state, and a stateful thing in the
middle of a running fleet becomes a thing that has to be up.

Splitting the surface into seeing and controlling keeps that from happening, and
splitting *controlling* again, into edits and actions, is what makes the
authority question answerable.

## Seeing costs nothing

A directory already holds what an operator wants to look at: every registered
arena server, the zone it serves, its verified player count, its region, when it
was last observed, and whether it passed verification. The admin UI is therefore
another client of the browse protocol with an authenticated superset of the same
reply.

Built, and the authenticated half landed somewhere this section did not
predict. A directory holds registrations and no accounts, so it cannot tell an
operator from anybody else; the meta-layer holds accounts and no
registrations. So the panel asks the process that can authorise, and that
process asks the process that knows: `/v1/admin/fleet` checks the flag and
relays `O2D_FLEET` to the directory over loopback. The directory answers that
tag only for a request no proxy touched, which is a real distinction on these
hosts and not the loopback test it looks like, because every service runs on
the host network and Caddy proxies from 127.0.0.1 too. What separates them is
the `X-Forwarded-For` Caddy always writes.

Because each directory relays only its own observations, an admin unioning
across all of a deployment's directories sees a more complete picture than any
single directory holds. That is the same union an arena server performs to choose
a zone, run for a different reason.

Build it as a static HTML page rather than inside the Defold client. It wants
tables, forms, and text entry; our client draws vector art and text on purpose,
and [decision 20](decisions.md) deliberately removed the last DOM text input
from it. A static page needs no new server, opens from disk or any host, and
points at directory addresses the way the game client does. A directory may
serve it as a convenience, but nothing depends on that.

## Control, part one: edits

Bans, a zone's map or settings, fill targets, adding a zone, retiring one, pool
tokens and their instance caps. These are not commands, they are edits, and the
architecture already has a distribution path for edits: a versioned catalog
deployed to every directory, which arenas take by highest version.

So the write surface of the admin UI is *producing a new catalog version*. It is
a configuration authoring tool that happens to have a live view attached.

That does create one central place, and the distinction worth holding onto is
that it is central for authorship rather than for runtime. If the authoring side
is down, every directory keeps serving the catalog version it has and every arena
keeps serving the zone it chose. Nothing stops. An assignment scheduler going
down stops joins; a config author going down stops config changes, which is the
correct blast radius for the feature.

Backing the catalog with git gives version history, diffs, and an audit trail for
no work, and makes "who changed War's bomb damage on Tuesday" a question with an
answer.

## Control, part two: actions

Kicking a player, draining an arena server, pinning one to a zone, unpinning it,
restarting it. These have to reach one specific process now.

Send them down the registration socket that already exists, scoped so a
directory may only command arenas registered with it. The arena already trusts
its directories for the catalog, the socket survives NAT and dynamic addressing,
and no arena has to expose an admin listener of its own. The alternative, an
admin credential on every arena plus a second listener each, adds attack surface
to the process that holds the simulation.

Two directories can still send conflicting pins. Rather than designing that
away, make a pin sticky local state on the arena with last-write-wins, and
surface it: `pinned to Chaos by chris at 14:02 via directory B`. A conflict then
reads as visible operator error, which is what it is, instead of a systemic flaw
that needs a protocol.

Actions get no audit trail from the catalog, so log each at both ends, the
directory that sent it and the arena that ran it, and show the log in the UI.

## Capabilities

This is what finally calls `has_capability`. It sat in `config.rs` for months
with tests, a `[[staff]]` block in `zone.toml`, and nothing invoking it, because
there was no command channel to gate. The live copy is `catalog.rs`'s, checked by
`admin.rs` against the catalog's staff table; the `zone.toml` half is gone.

Keep ASSS's model, which [the research notes](../research/asss-server.md) argue
for at length: named powers rather than ranks. `ban`, `setmode`, `reload`,
`kick`, `drain`, `pin`, `catalog`. Each maps to a button the UI shows or hides
and to a check on the message the directory will accept. The staff table moves
into the catalog alongside bans, for the same reason: an operator who can ban in
Chaos but not in War is a support ticket waiting to happen.

One correction for whoever wires it up: the table keys on call signs, and it
cannot keep doing so. Call signs are server-dealt from a word list no operator's
name is in, and `/v1/rename` moves one off its holder in a click. When named
powers arrive they hang off account numbers, or off the account flag below,
which has neither problem.

## Metrics

[server.md](server.md) names five numbers as the ones that say whether the
architecture is holding: tick duration, bandwidth per player, snapshot size,
input queue depth, and lag actions taken. They belong in the `STATUS` push an
arena already sends, which gets them to the admin UI through a path that exists
rather than through a metrics stack we would then have to run.

Per-arena rather than per-fleet, because a single arena at 9 ms of tick time is
the interesting case and an average across forty of them hides it.

## The panel that exists

A first surface, a page and two endpoints behind basic auth at `/admin`, was
removed the same day as weight: the browse reply already showed every
registered instance to anyone who asked, and a fleet this size had nothing
left for a page to say. What earned the surface back was accounts. Once the
meta-layer existed, "this account may operate the fleet" became a fact it
could hold and check, and the ban stopped being a curl with a token in it.

So the panel is `deploy/admin/`: static files Caddy serves at
`admin.<domain>` on the central host, with `/v1` proxied to the meta-layer so
the page and its API share an origin and nothing needs CORS. Static for the
reason the top of this document gives: it wants tables, forms and text entry,
which the game client refuses to draw on purpose.

It opens on the fleet, because "is anything wrong right now" is the question
somebody opens a dashboard for. Every registered instance with its zone,
region, occupancy, rooms and tick time, and a state that reads `ok` or names
the one thing worth knowing: unverified, silent, a tick near budget, a queue
that is not draining, lag actions taken, a drain announced, capped. Above it
the totals, the catalog version, and the key check below. Under that a pilot
lookup with ban and unban, the ban list, and who holds the flag.

Two deployment-wide faults show there and nowhere else. Two directories on
different catalog versions is a publish that half landed, which the fleet
resolves correctly and silently by taking the highest. And a verifying key in
the catalog that is not the public half of the meta-layer's signing key means
every session token fails its check: pilots keep flying, as guests, rating
nothing, with nothing on fire to say so.

The catalog editor and the action verbs above are still in front of it. So is
a roster: `RoomView` carries counts and not names, so kicking somebody needs
either rosters on the status push or a kick by call sign that every arena
checks against its own room.

The name is its own certificate, which this file's opening comment prices as
the thing a mistake can burn. Taken anyway, and as isolation rather than
risk: the certificate volume outlives reinstalls now, and if the panel's name
ever hits the issuance limit it strands the panel while the game plays on.
The page also sends a strict CSP, `default-src 'self'` with nothing inline,
so the free text it renders (a ban reason is operator-typed) cannot become
script on the one origin where a script holds an operator's credential.

## Authentication

TLS from the start, for the same reason registration requires it: an admin
credential over cleartext is an admin credential given away.

Entry is a flag on the operator's own account. `accounts.admin` is written by
no route at all: granting and revoking are SQL run by the operator on the
central host, per the runbook in `deploy/README.md`, so the authority over
who operates the fleet is the database credential and nothing reachable over
HTTP. Signing in to the panel is `/v1/login` with the operator's call sign
and password, the same credential the game uses, and the device secret it
answers with is what the panel holds.

One rule makes that safe, and every route the panel grows has to keep it: the
`admin` field a session reply carries is decoration for the page. The
authorization is `admin_for` in `meta.rs`, which resolves the presented
secret and checks the flag in the database inside every admin route. Checked
per action rather than per login, so revoking the flag or banning the account
lands on the next click, not the next session. A client can dress its screen
up as an admin's and every action still comes back 403.

Two containments back that up. A leaked panel session can act as an admin but
never appoint one, because granting is not an HTTP action at all. And the
panel's ban refuses accounts holding the flag, so one compromised session
cannot lock the other operators out; unseating an admin starts in the
database. The same shape is why there is no admin token any more: the one
route it guarded was grant, and a guarded route on a host-network deployment
is still a thing a compromised neighbour process can call, where SQL against
the managed database is not.

The cost, stated plainly: fleet-wide reach now stands behind a password whose
only floor is six characters. The login throttle holds guessing to ten tries
a quarter hour per name however many addresses join in, which is a brake and
not a proof, so the flag goes to accounts whose passwords deserve it. An
earlier draft of this section wanted a passkey or an SSO front before any
surface returned; the flag traded that bar for a credential the fleet already
had, and a passkey remains the upgrade path if the trade stops feeling right.

## What it does not do

It is not a place players appear. Chat moderation, appeals, and anything that
needs a player-facing view belong with identity, which
[decision 11](decisions.md) puts outside the directory and this document does
not change.

It is not a deployment tool. Raising a replica count is the container platform's
job, and an admin UI that also spawns processes would need credentials on the
hosting layer, which is a much larger thing to protect than a catalog editor.
