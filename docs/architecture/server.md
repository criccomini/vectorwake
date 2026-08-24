# The arena server

The Rust binary supplies every server role. With no subcommand it runs an arena
process. The `directory`, `bots`, and `meta` subcommands run the other live
services, while `catalog`, `token`, `metakey`, `calibrate`, `drill`, and
`mapforge` are operator or offline tools.

## Responsibility

The arena owns the truth. Clients send inputs and requests. Position, damage,
death, inventory, objectives, scores, and match results come back as server
decisions. The client runs the same C simulation core for prediction, but a
prediction never becomes authority.

The server links the core through the FFI mirror in `sim.rs`. Rust owns
untrusted input, sessions, room membership, modes, persistence handoff, and
networking. C owns deterministic movement and combat. The boundary is packed
bytes and narrow calls rather than a second implementation of game rules.

## Source shape

The server is one crate with modules split by runtime concern:

| Area | Modules |
|---|---|
| Arena loop and rooms | `main.rs`, `room.rs`, `session.rs`, `modes.rs`, `protocol.rs` |
| Simulation and tuning | `sim.rs`, `config.rs`, `arena.rs`, `delivery.rs` |
| Fleet and catalog | `directory.rs`, `select.rs`, `fleet.rs`, `catalog.rs` |
| Bots | `bots.rs`, `ai.rs`, `pilot.rs`, `pilots.rs`, `nav.rs`, `shopper.rs`, `profiles.rs` |
| Accounts and records | `meta.rs`, `token.rs`, `rating.rs`, `spool.rs`, `presence.rs` |
| Operations and tools | `metrics.rs`, `wt.rs`, `calibrate.rs`, `drill.rs`, `mapforge.rs` |

The crate does not contain the proposed `transport/`, `modules/`, or
`arena/` directory trees from the original design. The flat modules above are
the code that ships.

## Processes, zones, and rooms

An arena process serves one zone at a time. Inside it, `ArenaServer` owns one or
more rooms. The first room exists while the process serves the zone. More rooms
open only when the existing rooms have reached the zone's fill target, up to
`max_rooms`, and empty extra rooms are reclaimed.

Each room owns a simulation state, map rotation position, mode, teams, pilots,
watchers, and delayed room channel. Rooms share the zone definition, packed
maps, event spools, network listeners, and process fate. This is why
`max_rooms` is both a capacity limit and a blast-radius decision.

An arena process registered with directories chooses which under-served zone to
serve. It changes only after every room is empty. The directory observes and
reports; it does not assign a process or move a player. The full selection rule
is in [zones-and-arenas.md](zones-and-arenas.md).

## The tick

One loop steps every room at 100 Hz:

1. Apply due input records and release controls that have gone stale.
2. Call `sim_step` for the room.
3. Hand events to the room mode, rating ledger, effects feed, and persistence
   spools.
4. Send ordinary snapshots at 20 Hz and the nearby-combat lane at 50 Hz.
5. On slower clocks, repeat roster, team, settings, and fleet status so a
   dropped update repairs itself.

Socket sessions, directory registration, WebTransport, and spool delivery are
asynchronous tasks. The tick loop does not wait for a network round trip or for
PostgreSQL.

## Authority and input

An input packet contains a lifecycle generation, selective receipt windows, and
up to four records of simulation tick plus button bits. Records for future
ticks wait in a bounded per-pilot map. A repeated tick replaces the earlier
record. A late record applies where it arrives, and a lead beyond the accepted
window is clamped.

Ship, kit, team, watch, invite, and fixed-phrase messages are requests. The room
validates them and the next authoritative message says what happened. A client
cannot submit a position, hit, death, score, or arbitrary chat line.

Inbound frames are capped at 8 KiB and queued input is bounded. There is no
separate messages-per-second throttle. Load tests pushed hundreds of thousands
of local input messages per second without disturbing the tick cadence, so the
code does not carry a rate limiter for a bottleneck that has not appeared.

## Transport and packing

WebSocket is the universal reliable transport. Browsers try WebTransport first
when an arena advertises it, use datagrams for current input and combat
snapshots, and keep reliable streams for control and ordinary snapshots. Both
doors carry the same protocol messages.

The C core packs settings, maps, and snapshots so client and server cannot
quietly disagree about their layouts. Player and watcher snapshots retain a 64
KiB maximum. Full unfiltered state serialization has a separate, slightly
larger bound for diagnostics and trusted house bots connected over loopback.

When configured, the UDP listener terminates QUIC for WebTransport; the
production fleet uses port 9443. There is no plain UDP game transport for
native clients; they use WebSocket today.

## Lag response

The server measures round trip, jitter, snapshot loss on both lanes, and missed
input deadlines. These are diagnostics. A client can omit or forge receipt
information, so those reports do not decide whether it may shoot or take an
objective.

Gameplay uses arrival facts the server observes directly. With the shipped lag
policy defaults:

- After 250 ms without input, held weapon buttons are released.
- After one second, every held control is released and objective pickup stops.
- After five seconds, the pilot is moved to the stands or disconnected if no
  stand is available.
- After forty-five seconds without any message, the connection closes.

A new valid input clears the objective restriction immediately.

## Modes

Modes are Rust implementations selected by `zone.toml`: `arena`, `warzone`,
and `melee`. A mode receives a narrow room context, reacts to simulation events,
and owns scoring or match flow. It does not replace movement or combat rules in
the core. The catalog recognizes `duel`, but it currently runs the free-for-all
arena mode while the dedicated duel design remains deferred.

Sandboxed WebAssembly and Lua zone modules were proposals and are not in the
runtime. A zone author can currently change the broad settings and weapon
surface, choose a built-in mode, and supply maps. A future extension language
should be designed around a real mode that configuration cannot express.

## Persistence and identity

An arena process has no authoritative database. Ephemeral state dies with a
room. The catalog owns settings, maps, bans, staff, and fleet credentials. The
meta-layer's PostgreSQL database owns accounts, call signs, credentials,
ratings, match artifacts, and the rated event log.

Arena processes append outbound records to local spool files and background
tasks hand them to the meta-layer. The spool is durable across a process
restart, but it is a delivery queue, not a second source of truth.

A client gets a signed session token from the meta-layer and presents it while
joining. The arena verifies the signature offline with the public key delivered
in the catalog. An authenticated pilot taking a flying seat also claims the
account's one rated lease online. If the meta-layer is unavailable, a new rated
session is refused, guests can still fly, and existing leases have three
minutes of renewal slack. Durable records wait in their spools, and a room tick
never touches the database.

## Operations

The process exports role and zone metrics, tick duration, snapshot sizes and
bytes, queue drops, lag actions, room and pilot counts, and spool state. Outbound
queues are bounded. A slow client loses superseded snapshots instead of making
the arena wait or growing memory without limit.

A standalone process reads local settings repeatedly and keeps the last valid
configuration when a reload is broken. A fleet process receives catalog
commits through its directory connections. TLS identities belong to listeners
and require a restart; game tuning does not.
