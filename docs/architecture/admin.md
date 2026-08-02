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

This is finally a caller for `has_capability`, which sits in `config.rs` with
tests, a `[[staff]]` block in `zone.toml`, and nothing invoking it, because there
has never been a command channel to gate.

Keep ASSS's model, which [the research notes](../research/asss-server.md) argue
for at length: named powers rather than ranks. `ban`, `setmode`, `reload`,
`kick`, `drain`, `pin`, `catalog`. Each maps to a button the UI shows or hides
and to a check on the message the directory will accept. The staff table moves
into the catalog alongside bans, for the same reason: an operator who can ban in
Chaos but not in War is a support ticket waiting to happen.

## Metrics

[server.md](server.md) names five numbers as the ones that say whether the
architecture is holding: tick duration, bandwidth per player, snapshot size,
input queue depth, and lag actions taken. They belong in the `STATUS` push an
arena already sends, which gets them to the admin UI through a path that exists
rather than through a metrics stack we would then have to run.

Per-arena rather than per-fleet, because a single arena at 9 ms of tick time is
the interesting case and an average across forty of them hides it.

## Authentication

TLS from the start, for the same reason registration requires it: an admin
credential over cleartext is an admin credential given away.

A token matches every other credential in the system and is fine to begin with.
It is worth being clear that this one is different in kind from a pool token,
because a human holds it, humans reuse credentials, and the powers behind it
include editing what every arena in the fleet runs. Before this is exposed
anywhere public it wants something better than a secret in a file, and a passkey
or an SSO front is the obvious shape. Not first, but not never.

## What it does not do

It is not a place players appear. Chat moderation, appeals, and anything that
needs a player-facing view belong with identity, which
[decision 11](decisions.md) puts outside the directory and this document does
not change.

It is not a deployment tool. Raising a replica count is the container platform's
job, and an admin UI that also spawns processes would need credentials on the
hosting layer, which is a much larger thing to protect than a catalog editor.
