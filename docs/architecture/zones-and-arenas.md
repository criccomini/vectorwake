# Zones, directories, and arena servers

## The thesis

The directory observes and reports. The edges decide.

An arena server decides which zone it serves. A client decides which arena
server it joins. Nothing in the middle assigns work, which means nothing in the
middle has to be elected, agreed with, or kept alive for the game to continue.

Everything below follows from that sentence, including the parts that look like
inconveniences.

## Vocabulary

**Zone.** A named game: one configuration, plus however many arena servers are
running it. Alpha, Chaos, War, Duel. This is what a player picks from a list,
and it is what the original's directory listed.

**Arena server**, or **arena**. One process running one zone's configuration:
one map, one mode, one simulation, one tick loop at 100 Hz. Interchangeable with
every other arena server running the same zone.

**Directory.** The front door for many zones. It holds every zone's
configuration, the token table, and a live registration from every arena server,
which between them are serving a mix of zones. A deployment runs several
directories for availability, and anyone may run their own. Directories never
talk to each other.

**Catalog.** The set of zone configurations a directory serves, versioned as a
unit.

**Pool.** An operator's block of arena-server capacity, authorised by one row of
the token table and bounded by an instance cap.

Pools and zones are orthogonal, and it is worth saying so plainly because the
containment reads either way until you check. A pool is *whose capacity this
is*; a zone is *what game is being played on it*. Arena servers in one pool will
be serving different zones, and a busy zone is normally served by arena servers
drawn from several pools.

```mermaid
flowchart TB
    D1["Directory A<br/>catalog v37 + tokens"]
    D2["Directory B<br/>catalog v37 + tokens"]
    A1["arena server<br/>Chaos, 33 players, us-east"]
    A2["arena server<br/>War, 23 players, us-west"]
    A3["arena server<br/>Alpha, 3 players, us-west"]
    D1 <--> A1 & A2 & A3
    D2 <--> A1 & A3
    P["Client"] -. "browse: Alpha, Chaos, War, Duel" .-> D1
    P -- play --> A1
```

An arena server registered with both directories carries each one's observations
to the other. The shared picture propagates through the workers rather than
between the controllers, which is why no directory needs a peer list.

One thing this vocabulary gives up. In Subspace a zone held several arenas with
different maps, so Trench Wars was one zone containing a public room, a duel
room and a league room. Here each of those is a zone, and what used to be their
grouping is now just several zones a directory lists next to each other. The
social unity that grouping implied is already gone with
[decision 23](decisions.md), so this costs nothing that was still standing.

## What each layer owns

| | Owns | Does not own |
|---|---|---|
| Catalog | Every zone's map, mode, settings and fill target. Bans and staff. Versioned. | Anything about a running arena server |
| Directory | Token table, its own observations, browse answers | Which zone anybody serves, player state, durable records |
| Arena server | One simulation, its choice of zone, its players | The catalog, other arena servers |
| Bot server | The bot population: which bots fly, where, and when they stand down | Seats, admission, anything authoritative |
| Client | Which directory to ask, which arena server to join | Nothing authoritative, as before |

## The arena server lifecycle

An arena server boots knowing two things: the directories it should register
with, and its token for each. Nothing else, which is the property that makes a
deployment one container image and a horizontal scale a non-event.

1. **Register.** Connect to each directory over TLS, present the token, hold the
   socket open. The directory names the pool from the token row, so an arena
   server cannot claim to be somebody else's capacity.
2. **Learn.** Each directory pushes what it has observed: every arena server it
   holds a registration for, with the zone it serves, its verified player count,
   its region, and an observation timestamp. The arena server unions these and
   deduplicates by instance id, keeping the most recent observation of each.
3. **Choose a zone.** Apply the selection rules below. Fetch that zone's map and
   settings, which arrive as the same packed bytes a client receives at join.
4. **Serve.** Tick at 100 Hz, push status updates as counts change, answer
   direct status queries.
5. **Drain and re-choose.** Stop accepting joins, let the room empty, then go
   back to step 3.

An arena server that cannot reach any directory keeps serving whatever it last
chose. One that has never reached a directory serves the catalog's default zone,
or the built-in arena if it has no catalog at all. Neither case is an error worth
exiting over.

## Choosing a zone

Every arena server applies the same rule to nearly the same data, which is
exactly the condition under which a correct local decision becomes a bad global
outcome. Four rules keep that from happening.

**Only an empty arena server chooses.** Switching zone means a new map and a new
mode, so it disconnects everyone in the room. An arena server that wants to
change drains first. This is the rule that makes the rest of the design safe
rather than merely clever: instances may flap all they like while nobody is
affected, and drain time rate-limits decisions for free.

**Prefer not to exist.** An arena server opens a new instance of a zone only when
every live instance of that zone is out of room. Five War rooms holding four
players each is a worse game than one holding twenty, and concentration was the
entire point of the arena model we are replacing. Scaling out is the easy half of
autoscaling; declining to is the half that needs a rule.

"Out of room" has two levels now, because rooms are created on demand inside a
process and not fixed at its start. See the fill ladder below: a process grows a
room before the fleet grows a process, and that ordering is what keeps the number
of registered instances small.

**Jitter, announce, re-read.** Ten arena servers booting after a deploy will all
union the same view, all conclude Alpha is underserved, and all become Alpha. So
an arena server waits a random interval, announces the zone it intends to serve,
waits again, re-reads the union, and commits only if the announcements it can see
still leave room. This is carrier sense with collision backoff. It blunts herding
rather than eliminating it, and it is a lock protocol running over an eventually
consistent channel, which is worth saying out loud rather than discovering later.

**Region is a preference, not a constraint.** An arena server prefers a zone that
is underprovisioned in its own region, and falls back to global need. A
deployment in one region ignores the field entirely.

### The rules as an algorithm

Prose is enough to argue with and not enough to build. The four rules resolve to
this, run by every arena server on its own:

```
constants (all overridable per deployment, defaults chosen to be boring)
  DECIDE_JITTER      0..5000 ms   spread before a cold instance decides
  ANNOUNCE_HOLD      3000 ms      wait between announcing and committing
  INTENT_TTL         15000 ms     how long an announcement reserves a zone
  DRAIN_GRACE        120000 ms    empty-room patience before re-choosing
  RECHOOSE_COOLDOWN  60000 ms     minimum between two commits by one instance

choose():
  if room is not empty:            return            # rule 1, and it is absolute
  if pinned by an operator:        return pin.zone   # admin.md wins over policy
  if now - last_commit < RECHOOSE_COOLDOWN: return

  view = union(per-directory views, dedup by instance, keep newest observed_at)
  sleep(random 0..DECIDE_JITTER)                     # rule 3, first half

  want = pick(view)
  if want is none:                 return            # nothing is short; stay put
  announce(INTENT{want, now + INTENT_TTL})           # rule 3, second half
  sleep(ANNOUNCE_HOLD)

  view = union(...)                        # re-read; peers announced too
  if pick(view) != want:           return            # somebody else covered it
  commit(want); last_commit = now

pick(view):
  live(z)  = instances serving z, plus unexpired intents naming z
  # Rule 2, and the fill ladder: an instance with room headroom can grow its own
  # room, so it is not a reason to add an instance. Only a zone whose every
  # instance is capped -- or which has none at all -- needs one.
  capped(i) = i.rooms >= max_rooms(i.zone) and every room at fill_target
  needy    = [z for z in willing
                if live(z) is empty or all(capped(i) for i in live(z))]
  if needy is empty:               return none
  prefer   = [z in needy if under-provisioned in my region]   # rule 4
  return lowest-priority-index of (prefer if prefer else needy)
```

Three things in there are load-bearing and easy to get wrong.

`live(z)` counts unexpired intents as though they were instances. That is the
whole of the anti-herding mechanism: an announcement occupies the zone it names
for `INTENT_TTL`, so nine of ten instances booting together see the tenth's claim
and look elsewhere. It also means a crashed announcer releases its claim on a
timer rather than holding a zone empty forever, which is why the TTL travels in
the message rather than being a directory-side rule.

`needy` is zones with no live instance *or* no headroom left in any of them, and
the second half is doing the same work the first half is: a zone with one
instance holding six players of twenty does not want another instance, and it
does not want another room either. It wants the next six players, which the
client's own preference for the fullest room below cap delivers. Loosening
`capped` to "below target" is the mistake that turns the concentration rule
inside out and scatters a population across half-empty rooms, and it is easier
to make now that there are two places to make it.

The tie-break is the catalog's zone order rather than anything computed. Two
instances with identical views must reach the same answer or the announce step
has nothing to detect a collision against, and "first in the file" is the only
total order both of them already agree on.

## The arena server as a state machine

The lifecycle above is the happy path. The edges are where the design either
holds or does not:

```mermaid
stateDiagram-v2
    [*] --> Booting
    Booting --> Registering: instance id loaded or minted
    Registering --> Unverified: ACCEPTED, verified=false
    Registering --> Offline: REJECTED, or no directory reachable
    Registering --> Choosing: ACCEPTED, verified=true
    Unverified --> Choosing: verification passes on retry
    Offline --> Choosing: serve default_zone anyway
    Offline --> Registering: a directory answers
    Choosing --> Announcing: picked a zone
    Choosing --> Choosing: nothing short; wait and re-read
    Announcing --> Choosing: peer covered it
    Announcing --> Serving: committed, map and settings loaded
    Serving --> Serving: catalog changed; new settings, same zone
    Serving --> Serving: room opened or reclaimed; below max_rooms
    Serving --> Draining: operator drain, or a better zone exists
    Draining --> Choosing: empty, or DRAIN_GRACE elapsed
    Serving --> Serving: pinned; policy stops applying
```

`Offline` is the state worth defending. An arena server that cannot reach any
directory serves the last zone it chose, or the catalog's `default_zone` if it
never chose one, or the built-in arena if it has no catalog at all. It keeps
ticking and keeps accepting the clients that already know its address. A
discovery outage must not be a gameplay outage, and this is the state where that
promise is either kept or quietly broken.

`Unverified` is registered but unlisted: the directory holds the socket and will
keep retrying the callback, and the arena serves anybody who reaches it directly.
That combination is deliberate. A misconfigured address should cost an operator
visibility, not the players already connected.

## The catalog

Zone configurations are the one thing that must not be gossiped. Two directories
disagreeing about which map War uses hands an arena server a conflict it has no
way to resolve, and resolving it by vote is the consensus this design exists to
avoid.

So the catalog is a versioned artifact with a single author, deployed to every
directory. An arena server takes the highest version it is offered, logs a
mismatch when directories disagree, and keeps what it already has rather than
flapping between two definitions. This is configuration management, not
agreement: the authoring side can be down for a week and every arena server keeps
serving the last version it received.

A zone also declares `max_rooms`, the most simulations one process may hold for
it. Rooms are created on demand up to that ceiling and reclaimed when they empty,
so the number is a cap rather than a count: a process configured for a hundred
duel rooms holds as many as there are matches, and its memory is bounded at
`max_rooms` times 107 KB plus one shared map. War sets it to 1, because a 64-player
fight deserves its own blast radius. Duel sets it to 100, because the rooms are
tiny and share a map. Same binary either way. The measurements are in
[hosting.md](hosting.md), and the amendment to [decision 23](decisions.md) records
why the original fixed one-room-per-process rule did not survive contact with
them.

### The fill ladder

With rooms appearing on demand, "where does the next player go" has four rungs,
and they are tried in order. The order is the concentration rule, restated as a
procedure:

1. **The fullest room below its player cap, on the instance the client chose.**
   This is the client's own preference and it does most of the work.
2. **A new room on that instance**, if every room it holds for this zone is at
   `fill_target` and it is below `max_rooms`. Costs 107 KB and no coordination,
   which is why it comes before anything involving another process.
3. **Another instance already serving this zone**, if that one is at `max_rooms`.
   The client tries the next address the directory gave it.
4. **A new instance**, which is the only rung that needs the selection algorithm,
   an announcement, and a wait. It fires when every instance of the zone is at
   `max_rooms` with every room at target.

Rung 2 is the one that changes the shape of the fleet. A duel zone with
`max_rooms = 100` covers its first hundred concurrent matches inside a single
registered process, so the fleet stays small, `VIEW` stays short, and the herding
problem barely arises because there is rarely a reason to add an instance. The
cost is that a process is no longer a fixed size, and a hard cap is what keeps
that honest: unbounded growth inside a process would turn one busy zone into an
out-of-memory kill that takes every room in it down together.

A room that empties is reclaimed rather than kept warm, except that an instance
serving a zone always keeps one room, so it still *is* an instance of that zone
and appears as one. Draining, then, means all rooms empty and the last one closes,
which is when the instance may choose a different zone.

Bans and staff capabilities live in the catalog rather than beside one zone. A
player banned from Chaos but not from War is a support ticket waiting to happen,
and a per-zone ban is available as a field on the row for the cases that want it.
This moves bans out of the `bans` list in `zone.toml`, which today has exactly one
call site.

## Joining, seats, and teams

A client has picked an arena server. What happens between that and flying is the
part of this design most easily left implicit, and it has a hole in it today:
every human who joins is forced onto team 0, because the code that would decide
otherwise does not exist.

The sequence is four questions, and each has an answer that belongs to a different
layer:

1. **Is this pilot allowed in?** A fleet ban never reaches this door: the
   meta-layer refuses a banned account its session token, per
   [meta-layer.md](meta-layer.md), so the arena checks the token's signature
   and the catalog's per-zone bans, and nothing else.
2. **Is there a seat?** A room holds `max_ships` ships and admits `max_players`
   humans; a declared bot takes a ship but never one of the human seats, per
   [decision 29](decisions.md#29-a-bot-is-a-client). A room with every ship taken
   and a declared bot aboard is not full: the arena drops the newest declared bot
   and seats the arrival, which is the backstop under the bot server's own habit
   of leaving a share of the room unfilled. A join is refused for space only by a
   room genuinely full of people.
3. **Which team?** The mode decides, and the catalog gives it a number to work
   with. Warzone wants balance, so it puts the arrival on the smaller side. Free
   for all wants none, so everyone shares a team and friendly fire is off by being
   irrelevant. Duel wants exactly two.
4. **Flying or watching?** A pilot may join as a spectator, and some are put there
   without asking.

Team assignment is the one that needs a decision rather than a description, and it
should not be a fifth rule in the selection algorithm or a field in the client's
join message. It belongs to the mode, because "what is a team here" is the same
question as "what game is this," and a client asserting a team is a client
asserting something the server should own. So the catalog carries the shape and
the mode carries the policy:

```toml
teams = 2              # how many the mode may use; 1 is a free-for-all
balance = "smaller"    # smaller | random | none
private_teams = false  # whether players may form their own, ASSS's private freqs
```

**A free-for-all is no teams, not one team.** `teams = 1` reads as "everybody on
side zero", and side zero was what it did: every hostility test in the stack asks
whether two teams differ, so a weapon skipped every ship, a kill paid no points
and no bounty, a repel pushed nobody, and a bot did not so much as look at
anybody. Chaos shipped that way and ran for a day with combat switched off --
nine pilots holding perfectly still, because there was nothing any of them could
see or shoot. A pilot's seat is their side in a one-team zone, which fits because
ship indices stop at 254 and 255 is `TEAM_NONE`, and it needs no rule of its own
in the core or in the client: the client already draws anybody not on your side
as hostile, so a free-for-all colours itself.

`balance = "smaller"` is ASSS's default behaviour and the right one to ship:
`Team:MaxTeamDifference` defaults to 1 there, so the balancer tolerates almost
nothing. Private teams are off until there is a reason, because the original's
private freqs came with passwords, ownership and a whole social layer we have no
use for yet.

### Spectating is not a feature, it is three

Spectating keeps arriving from different directions, which is the sign it should
be built once rather than three times:

- The duel queue needs pilots present but not playing while they wait for a pair.
- Lag response needs `SpecToSpec`'s force-to-spectator, which
  [server.md](server.md) lifts from ASSS as the gentlest of the four thresholds.
- An operator wants to watch a room without joining it, and the admin surface has
  no other way to see a game rather than a number.

A spectator is a player with a seat in the player list and no ship in the
simulation. That is the whole of it, and it is why it costs almost nothing: the
sim needs no spectator concept, `sim_state` gains no field, and a spectator is
simply a connection that receives snapshots and sends no inputs. The one thing it
does need is a snapshot that is not centred on a ship the viewer does not have,
which the interest radius currently assumes.

A pilot moving between spectating and flying is a spawn and a despawn, not a
reconnect. That matters for the duel queue especially: waiting in a room and then
being paired should not cost a round trip to a directory.

### What a refusal has to say

A join can fail for five reasons and the client has to tell them apart, because
three of them mean "try another instance" and two mean "stop trying":

| Reason | The client should |
|---|---|
| Room full | Try the next instance of this zone |
| Draining | Try the next instance; this one is on its way out |
| Zone no longer served here | Re-browse; the instance changed zone under it |
| Banned | Say so and stop |
| Bad protocol version | Say so and stop; the build is stale |

`S2C_DENIED` carries the code in its first byte and then the sentence, so a client
acts on the first three without parsing English.

Two of the five need the client to say something, which is why `C2S_JOIN` carries
more than a hull and a name:

```
C2S_JOIN class protocol zone_len zone name
```

The protocol is checked first, before anything else in the message is trusted: a
build that misparses this wire would misparse the refusal too. The zone is the
game the player picked out of a browse list, and it is checked rather than
assumed, because an instance is free to change zone the moment its last player
leaves and the browse reply a client is acting on may be seconds old. Empty means
"whatever you are running", which is what typing an address directly means and the
only case where a wrong-zone refusal cannot happen.

## Duel is the exception

Duels are not currently built. They worked, offline and networked, and the code
came out rather than being carried through this rebuild; the reasoning is under
[decision 16](decisions.md) and the plan for their return is in
[design/duel-mode.md](../design/duel-mode.md). This section is what the shape
should be when they come back, and it is the case that most tests whether a mode
can really be a row in a catalog.

A War arena server is long-lived and shared. A duel is one match between two
pilots, and [decision 16](decisions.md) makes each match its own arena, created
when the match forms and destroyed when it ends. That was cheap when arenas
shared a process: build a small map, construct the mode, insert it into a map of
live arenas. Microseconds, and you could do it per match forever.

One arena per process makes it expensive. Not because launching a program is
slow, which it is not, but because of everything between launch and being ready
for a player: a TLS handshake to each directory, the registration exchange, the
catalog fetch, and the directory's verification call back. That is a second or
more, and on a platform that has to schedule a container first it is several.
Nobody should wait that long to fight someone.

So a duel arena server stays alive and runs matches back to back, out of a small
set of them kept registered and idle. A player waits for an opponent and never
for a machine. This is the warm pool [decision 16](decisions.md) held in reserve,
promoted from fallback to design.

Something has to pair players, and nothing in this architecture is a matchmaker.
The answer that needs no new authority is to put the queue inside the duel arena
server: everyone waiting for a duel joins the same one and is paired with whoever
else is waiting there. The join rule already sends a client to the fullest
instance below its cap, which is exactly the concentration a waiting room wants.
The cost is that rating-matched pairing is only as good as one room's queue,
which is fine while the players fit in one room and worse when they do not. A
queue that spans a deployment needs somewhere to live, and that somewhere is the
meta-layer matchmaker in [decision 11](decisions.md) rather than the directory.

So Duel appears in the catalog and in the player's list like any other zone, but
what it offers is a queue rather than a room. Worth naming, rather than
pretending the four are symmetric.

## Joining

A client asks a directory for the catalog and the live arena server list, then
decides for itself. Preferring its own region and the fullest instance below the
fill cap gives concentration a second enforcer at no cost, and gives the player
the busiest room rather than the emptiest.

The list is cacheable and worth caching. Under assignment the directory would sit
in the join path and its outage would block every join, including joins to arena
servers running perfectly well. Reporting instead of routing means a stale list
still works: the client tries an address, gets refused if it is full or gone, and
moves to the next.

## What this deletes

The old model needed a named-arena registry, template resolution by name prefix,
per-arena configuration files, arena groups sharing score intervals, lazy
loading, unload grace periods, an arena worker pool, and a scheduler to assign
arenas to threads. None of it survives, and most of it was documented in
[server.md](server.md) without ever being built. One process holding one arena
also answers that document's open question about process isolation in the
direction that needs no code: a wedged arena server takes down only itself, and
the supervisor that restarts it is whatever already restarts containers.

It also settled four keys that `zone.toml` parsed while nothing read them.
`arena.mode` and `arena.flags` lost to a hardcoded `Warzone::new(4)` and
`max_players` lost to a `const`; all three are now part of a zone's definition
in the catalog, read because they are the only source of the answer. `[[bots]]`
lost to the roster in `ai.rs` and is simply gone, along with `[[staff]]`, whose
table belongs to the deployment rather than to one game.

## Costs

Eventually consistent scheduling means transient over- and under-provision. A
deployment will sometimes hold two half-full War rooms for a few minutes. At tens
of arena servers that trade is obviously right; at hundreds the backoff starts
doing serious work and this document needs revisiting.

Rooms sharing a process share its fate. A wedged or killed arena server takes
down every room it holds, so `max_rooms` is also a blast-radius setting and not
only a memory one. That is the honest reason War keeps it at 1: a hundred
duellists losing their match to one crash is annoying, and sixty-four players
losing a flag game they were twenty minutes into is worse.

Population is no longer one social space by construction. ASSS got zone-wide
chat and instant arena switching for free because one process held everything.
Moving between zones is now a reconnect, which is a real regression against the
original and against [server.md](server.md)'s promise that it would not be. Chat
is not paid for at all: [decision 28](decisions.md#28-no-chat) removes it,
partly because this model would have made it a hub in the middle that has to be
up.

Authorship moves up a level. A third-party author no longer runs a zone with
their own settings on their own box; they run a *directory* with their own catalog
and their own arena servers behind it. That preserves what the research notes
credit for the original's thirty years, and arguably improves on it, since the
author defines War once and the capacity behind it is elastic. But it raises the
floor on running your own game, from one binary and a config file to a catalog, a
directory, and at least one arena server.

There is no global list of directories, and we are not building one. A player
reaches ours because the client resolves `directory.vectorwake.net`, and reaches
anybody else's because somebody handed them a hostname.

## Open questions
One is genuinely open. Five were closed by the decisions below, and two of those
closed by being deferred rather than answered, which is a different thing and
worth keeping visible.

**Open: whether the herding backoff holds at scale.** The announce-and-recheck
step is a lock protocol over an eventually consistent channel, and it blunts
collisions rather than preventing them. At tens of instances the arithmetic is
comfortable. At hundreds, `INTENT_TTL` and `ANNOUNCE_HOLD` start doing real work
and a leader begins to look cheap by comparison. This one cannot be argued to a
conclusion, which is why [roadmap.md](roadmap.md) asks for a harness rather than
a playtest.

The fill ladder makes it less pressing than it was. Rung 2 means a process grows
a room before the fleet grows a process, so most demand is absorbed without any
instance choosing anything, and choosing is the only thing that can herd.

**Closed: chat does not exist.** [Decision 28](decisions.md#28-no-chat). The
question was where a hub would live, and the answer is that there is no hub
because there is no chat. This model helped force that: chat here would have
been a stateful thing in the middle, which is what the whole design avoids.

**Closed: the client finds directories through DNS.**
`directory.vectorwake.net` resolves to every directory of this deployment; the
client shuffles the records and takes the first that answers. Arena servers
resolve the same name. See [discovery.md](discovery.md) for what that does to
the TLS certificate, which is the one non-obvious consequence.

**Closed: rooms are dynamic, with a hard cap.** The fill ladder above, and
`max_rooms` in [catalog.md](catalog.md). The cap earns its keep twice, bounding
memory and bounding the blast radius of one process dying.

**Deferred: where a rated event goes.** Not answered, and deliberately not
blocking. `persist.rs` writing `ratings.json` beside the process is correct for
one instance per zone and wrong the moment there are two, so this has to be
settled before a zone is ever served by more than one arena server at once.
Until then the argument is recorded in [server.md](server.md): the directory is
the tempting sink and the wrong one.

**Deferred: spectators.** The design is in the join path above and stands; it is
simply not being built yet. Two things wait on it. The duel queue needs pilots
present but not playing, which is one reason duels stay out. And lag response's
force-to-spectator is the gentlest of ASSS's four thresholds, so until
spectating exists, the only lag actions available are the harsher ones.
