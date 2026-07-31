# The zone server

## Responsibility

The server owns the truth. It accepts connections, authenticates players, places
them in arenas, feeds inputs to the simulation, decides every kill, and writes
what happened to disk. Clients render its decisions and predict ahead of them.

It is a separate program from the client rather than a headless Defold build.
The reasons are in [decisions.md](decisions.md), and the short version is that a
zone server wants long uptime, sandboxed extensions, a database, and predictable
memory under a few hundred connections, none of which is what Defold is for. A
headless Defold build remains a legitimate shortcut for the first playable
prototype, and it is on the roadmap as one.

## Language

Rust, linking the C simulation core through a thin FFI wrapper.

The server is where the untrusted input arrives: packet parsing, session
handling, chat, file transfer, and module hosting are all attack surface, and
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
    session/          handshake, auth, capabilities, chat
    arena/            arena.rs, scheduler.rs, settings.rs, map.rs
    sim/              FFI bindings to sim/
    lag/              measurement and actions
    ai/               controllers, perception, navigation, population director
    rating/           damage ledgers, rated events, Elo
    modules/          wasm host, adviser dispatch
    persist/          sqlite, scores, bans, rated event log
  tests/
```

## The arena scheduler

Arenas are independent. Each holds a `sim_state`, its settings, its map, its
player list, and its module instances. A worker pool ticks them: one thread owns
an arena for the duration of a tick, and an arena is never ticked concurrently
with itself.

A tick is: drain the input queue for this arena, let AI controllers add their
inputs, call `sim_step`, hand the resulting events to modules, to the rating
layer, and to the snapshot builder, then enqueue any persistence writes. At
100 Hz that is a 10 ms budget, and a 40-player arena should use a small fraction
of it, with under 1 ms of it going to AI per [ai-runtime.md](ai-runtime.md).

Arenas load lazily by name and unload after a grace period with nobody in them.
Naming follows the ASSS convention we liked: `pub1`, `pub2`, and `pub3` all take
their configuration from the `pub` template, which makes running eight identical
public arenas a matter of one directory.

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
tick rate, a chat flood, or a ship change every frame all get throttled at the
session layer before they reach an arena.

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
state, adjust settings at runtime, send chat, set scores, spawn and move flags
and balls, and answer adviser questions. Writing a warzone flag game or a
powerball mode should take a few hundred lines.

Lua as a second module language is likely, since more zone authors write Lua
than compile WASM, and a Lua interpreter inside a WASM module gets us there
without a second sandbox.

## Persistence

SQLite by default, with the schema covering identity, scores per arena and per
interval, bans, and chat history if the operator wants it. ASSS keeps score
intervals as forever, per-reset, and per-game, and shares the first two across
an arena group; we copy that model because it is what tournament and league play
needs.

Writes go through a queue to a dedicated thread. A simulation tick never waits
on the disk.

## Identity

A zone runs standalone with local accounts, which is the `auth_file` case in
ASSS. It may also point at a shared identity service, which is what the original
billing server was, so that a name means the same person across zones. The
protocol treats identity as a token the session layer validates, so which
authority issued it stays out of the arena code.

## Operations

A zone is a directory of configuration, maps, and modules, plus one binary. The
process reloads settings without a restart, because zone operators tune numbers
constantly and taking an arena down to change a bounce factor is how you lose
players.

Metrics we care about from the start: tick duration per arena, bandwidth per
player, snapshot size, input queue depth, and the count of lag actions taken.
Those five numbers tell us whether the architecture is holding.

## Open questions

Whether one process per zone is right, or whether an arena should be able to
move to another process for isolation. Subspace's virtual servers let one
process present as several zones on different ports, which suggests the opposite
direction.

Whether WASM module startup cost is acceptable when an arena loads, and how
modules get distributed to operators.

Whether the arena worker pool needs work stealing, or whether arenas are
uniform enough that a simple assignment holds.
