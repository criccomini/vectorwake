# The arena server

> The zone and arena model in this document has been superseded. One process now
> holds one arena, a zone is one game backed by interchangeable arena servers, and
> an arena server picks which zone it serves rather than being placed by a
> scheduler. See
> [zones-and-arenas.md](zones-and-arenas.md), [discovery.md](discovery.md) and
> decisions 23 through 27. Authority and validation, lag response, modules and
> identity stand unchanged. Persistence does not: an arena server now holds
> nothing durable, and the section below says where each kind of state went.

## Responsibility

The server owns the truth. It accepts connections, authenticates players, feeds
inputs to the simulation, decides every kill, and emits a durable record of what
happened. Clients render its decisions and predict ahead of them.

It is a separate program from the client rather than a headless Defold build.
The reasons are in [decisions.md](decisions.md), and the short version is that a
zone server wants long uptime, sandboxed extensions, a database, and predictable
memory under a few hundred connections, none of which is what Defold is for. A
headless Defold build remains a legitimate shortcut for the first playable
prototype, and it is on the roadmap as one.

## Language

Rust, linking the C simulation core through a thin FFI wrapper.

The server is where the untrusted input arrives: packet parsing, session
handling, file transfer, and module hosting are all attack surface, and
they are the parts of the system where memory safety earns its keep. The
simulation, by contrast, sees only validated integers and allocates nothing,
which is why it stays in C where Defold's build server can compile it.

The cost is honest: three languages in one project, C for the core, Rust for the
server, Lua for the client shell. We accept it because each boundary is narrow
and each choice is forced by a different constraint.

## Structure

```
server/
  src/
    main.rs
    transport/        udp.rs, websocket.rs, throttle.rs
    session/          handshake, auth, capabilities
    arena/            arena.rs, settings.rs, map.rs
    directory/        registration client, the unioned view, zone selection
    sim/              FFI bindings to sim/
    lag/              measurement and actions
    ai/               controllers, perception, navigation, population director
    rating/           damage ledgers, rated events, Elo
    modules/          wasm host, adviser dispatch
    persist/          rated-event batching and handoff; no local database
  tests/
```

## The tick

One process, one arena, one tick loop. The arena holds a `sim_state`, its
settings, its map, its player list, and its module instances, and nothing else in
the process competes for them. The worker pool, the lazy load by name, the
template resolution and the unload grace period that used to be described here
are all gone with [decision 23](decisions.md); capacity is many processes and the
container platform schedules them.

A tick is: drain the input queue, let AI controllers add their inputs, call
`sim_step`, hand the resulting events to modules, to the rating layer, and to the
snapshot builder, then enqueue any persistence writes. At 100 Hz that is a 10 ms
budget, and a 40-player arena should use a small fraction of it, with under 1 ms
going to AI per [ai-runtime.md](ai-runtime.md). Measured tick cost is in memory
#75: 64 ships ran at 205 microseconds before the weapon-spec cache took a third
off that.

Which zone this process serves, and when it drains to serve a different one, is
[zones-and-arenas.md](zones-and-arenas.md). Duels keep their own lifecycle: a
duel arena runs matches back to back out of a warm pool rather than being created
per match, per the amendment to [decision 16](decisions.md). See
[design/duel-mode.md](../design/duel-mode.md).

## Authority and validation

Inputs are the only thing a client may assert. An input command carries a tick,
a sequence number, a button bitfield, and the aim heading. The server clamps the
tick to a window around its own clock, rejects duplicates, and feeds the rest to
the simulation.

Positions, deaths, damage, prize pickups, flag claims, and goals are outputs of
`sim_step` and cannot be asserted by a client. This deletes the entire class of
cheats that Subspace's `C2S_DIE` packet enabled, and it means the security
module we do not have to write is the checksum treadmill Continuum is stuck on.

Rate limiting and sanity checks stay: an input stream arriving faster than the
tick rate or a ship change every frame gets throttled at the session layer before
it reaches an arena.

## Lag response

Lifted almost intact from ASSS, because it encodes operational experience we do
not have. The server measures average ping, downstream loss, weapon-packet loss,
and upstream loss per player, and applies four thresholds per metric: force to
spectator, disallow flag and ball pickup, start ignoring weapons, and ignore all
weapons. Between the two weapon thresholds the ignored fraction interpolates,
and the maximum across metrics wins. Upstream loss never triggers weapon
ignoring, since it already hurts the player who has it.

One change from the original: when the server suppresses something, it tells the
client. ASSS clears a player's antiwarp bit inside a no-antiwarp region while
the player's own HUD still shows antiwarp active, and the manual admits this is
confusing. Suppression here is visible.

## Zone modules

Game modes and zone-specific rules run as sandboxed modules. Each module
receives events from the arena and may register as an adviser, which is ASSS's
best idea: before the server finalizes a kill it asks the advisers, and each may
edit the killer, the victim, or the bounty, or drop the event entirely. That
gives a zone author a veto over core behavior without patching core.

Modules run in a WebAssembly sandbox with a fuel limit per tick, no filesystem,
and no network. A module that loops forever loses its turn instead of hanging
the arena. This is the deliberate reversal of ASSS's model, where a `.so` has
full process access and can segfault the server.

The module API is small on purpose: subscribe to events, read arena and player
state, adjust settings at runtime, set scores, spawn and move flags and balls, and
answer adviser questions. Writing a warzone flag game or a
powerball mode should take a few hundred lines.

Lua as a second module language is likely, since more zone authors write Lua
than compile WASM, and a Lua interpreter inside a WASM module gets us there
without a second sandbox.

## Persistence

An arena server holds nothing durable. That is a change from what this document
said, and the reason is that the rest of the architecture now depends on it: a
process that owns a database is a process you cannot lose, and
[zones-and-arenas.md](zones-and-arenas.md) is built on arena servers being
disposable. SQLite per arena would have quietly made every instance precious.

So the split is:

| Lives where | What |
|---|---|
| Nowhere; dies with the room | Positions, energy, upgrades, the round in progress, flags held |
| The meta-layer's Postgres | Identity, ratings, the rated event log, career records |
| The catalog, in git | Bans, staff and capabilities, every zone's settings |
| An arena's local disk | Its instance id, and nothing else |

The rated event log is the case that decides the shape. Rating is computed from
events rather than stored as a number, per
[design/rating.md](../design/rating.md), so a match produces a durable record
that must outlive both the room and the process. An arena server therefore
*emits* rated events rather than owning them: it batches them and hands them off,
and a tick never waits on the network any more than it used to wait on a disk.

Handing off to what is the open question. The candidates are the directory, which
would make a directory stateful and cost us the property that its replicas need
no shared storage, or the meta-layer directly, which is one more thing an arena
must reach and authenticate to. The second is more likely right for exactly the
reason the first is tempting: the directory is the piece we most want to be able
to lose.

Until that is settled, `persist.rs` writing `ratings.json` beside the process is
the honest interim, and its own header says so. It is correct for one process
serving one zone and wrong the moment two instances of the same zone both hold
opinions about a pilot's rating.

ASSS's score intervals, forever and per-reset and per-game, are still the model
worth copying when this lands, because they are what tournament and league play
needs. They belong in the meta-layer's schema rather than in an arena.

## Identity

A zone runs standalone with local accounts, which is the `auth_file` case in
ASSS. It may also point at a shared identity service, which is what the original
billing server was, so that a name means the same person across zones. The
protocol treats identity as a token the session layer validates, so which
authority issued it stays out of the arena code.

## Operations

An arena server is one binary and a short config naming its directories. The
configuration it serves arrives from a directory and reloads without a restart,
because zone operators tune numbers constantly and taking an arena down to change
a bounce factor is how you lose players. What used to be a zone directory on the
serving host is now the catalog, per
[content-pipeline.md](content-pipeline.md).

Metrics we care about from the start: tick duration per arena, bandwidth per
player, snapshot size, input queue depth, and the count of lag actions taken.
Those five numbers tell us whether the architecture is holding.

Queue depth is the one that is load-bearing rather than merely interesting. Each
connection has a bounded outbound queue and the arena drops rather than blocks
when it is full, which is safe because a snapshot is a whole state pack: the next
one supersedes any that was dropped. Unbounded was the original, and it made a
client that stopped reading into a memory leak with a socket on the end of it --
two hundred stalled clients in one room took a process from 8 MB to 450 MB in
twenty-five seconds, measured, and the bound holds it to a tenth of that. Reported
depth is the worst-off connection in the process, because that is the one whose
player is losing frames. Disconnecting a client that stays at the bound is a lag
action, and lag actions are still deferred.

## Open questions

Whether WASM module startup cost is acceptable when an arena loads, and how
modules get distributed to operators. The catalog is now the obvious channel for
the second half of that, which makes module bytes something a directory hands out
alongside a map.

Two questions that used to live here are answered. Whether an arena should be
able to move to another process for isolation: yes, and it is the only thing in a
process now, per [decision 23](decisions.md). Whether the arena worker pool needs
work stealing: there is no pool.
