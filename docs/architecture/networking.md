# Networking

## Two transports, one protocol

Native clients speak UDP. Browsers cannot open UDP sockets, so web clients speak
WebSocket over TCP. The server listens on both and the message format is
identical; only the delivery guarantees differ.

Defold bundles LuaSocket for UDP on native platforms and has a maintained
WebSocket extension that covers every target including HTML5, so both paths
exist without us writing a transport from scratch. We may still move the native
path into the sim extension later for finer control over pacing and buffers.

The protocol is designed for the weaker transport. On TCP a lost packet blocks
everything behind it, so snapshots must be individually useful rather than a
chain of deltas that breaks when one link is missing. Every snapshot is
decodable against a baseline the server knows the client has, and the server
never assumes a snapshot arrived until the client says so.

## Message model

Two channels, distinguished per message rather than per connection.

Unreliable messages carry state that a newer message supersedes: input
commands, snapshots, position updates. Losing one costs nothing because another
follows in 50 ms. On UDP they are sent once and never retransmitted. On
WebSocket they inherit TCP's ordering, which we cannot avoid, so we keep them
small and let the client discard stale ones by tick number.

Reliable messages carry things that must arrive exactly once: arena joins,
settings, map metadata, score updates, kill notifications. On UDP they get
sequence numbers, acknowledgements, and retransmission with backoff. On
WebSocket they ride the socket's own guarantees.

Subspace's design put reliability at the same layer, with `0x00 03` reliable
messages and `0x00 04` acks wrapping ordinary game packets, and clustered
several small packets into one datagram with `0x00 0E`. Both ideas survive here.
Clustering in particular matters more than it looks: an arena generates many
small messages per tick, and a UDP header per message wastes more bandwidth than
the messages themselves.

## Client to server

The client sends one input command per simulation tick, batched into a datagram
every other tick or so:

```
input_command {
  u32 tick            // the tick this input applies to
  u16 seq             // monotonic, for ack and dedup
  u16 buttons         // thrust, reverse, left, right, fire, bomb, specials
}
```

There is no aim field. Aiming is the nose, per
[decision 17](decisions.md), so rotation buttons are the whole steering
surface, and an aimbot has nothing to write to that the ship's own rotation
rate does not clamp.

Commands are cumulative and cheap, so each datagram repeats the last several.
Losing a datagram then costs nothing as long as the next arrives within the
window, which is the standard trick and it works here because inputs are tiny.

That is nearly the whole client-to-server surface for gameplay. Everything else
is arena changes, ship changes, and requests, all reliable and all rare.

## Server to client

### Joining: the room, then the rules, then the game

A client that joins gets three things before it gets any state, in this order:
the map, the settings, and a welcome naming its ship.

That order is the dependency order. The map is geometry, and prediction runs
collision locally, so a client cannot step anything without it. The settings
are the rules -- every hull's tuning and the zone's whole weapon table -- and
they land second because decoding a map re-derives settings from the baseline,
which would throw away anything sent before it.

Both are packed by the core (`sim_map_pack`, `sim_settings_pack`), so there is
one definition of each and the two ends cannot drift. Settings are about 1.2 KB
for a full table, sent once at join and again to everyone in the room whenever
an operator reloads the zone file -- retuning a live arena should not leave the
players in it predicting the game as it was when they arrived.

Before this, both ends compiled `sim_settings_baseline` and hoped. That held
exactly as long as no zone overrode anything: a zone that raised a hull's top
speed had every client predicting the old one, which a test measured as 11 px
of peak prediction error against 1 px once the settings travelled. It would not
hold at all for weapons, because a projectile carries a spec *index* and two
different tables do not agree on what an index means.

A client that cannot decode either message loses the connection with a reason
rather than playing on against rules it has guessed.

Snapshots at 20 Hz by default, carrying the authoritative state of everything
the player can see:

```
snapshot {
  u32 tick
  u32 baseline_tick      // what this is encoded against
  ships[]                // id, position, velocity, heading, energy, status
  weapons[]              // id, type, position, velocity, ttl
  events[]               // fired, hit, killed, prize, flag, goal
}
```

Three things keep it small. Fields are quantized to the sim's own fixed-point
scales, so no conversion happens on the wire. Values are delta-encoded against
the last snapshot the client acknowledged. And relevance is graded by distance:
ships near you update every snapshot, ships across the map update every fourth,
and ships outside radar range are radar blips rather than full state.

Events are the interesting part. The client already predicted its own movement,
so a snapshot that matches costs nothing. What the client cannot predict is
whether a shot hit, and events are how it finds out.

## Bandwidth budget

The target is 30 KB/s downstream per player in a 40-player arena, which is
generous by 2026 standards and lets us run arenas larger than Subspace's on a
modest server.

### Where it actually goes, measured

A snapshot of the shipped arena -- nine ships, a full green field, projectiles
in the air -- came to 3048 bytes, or 59.5 KB/s at 20 Hz. Twice the target, and
the split was not where the design above assumes:

| | bytes | |
|---|---|---|
| prizes | 1651 | **54%** |
| weapons | 827 | 27% |
| ships | 559 | 18% |

Prizes outweighed the ships and every projectile in the air put together,
because a full-size map carries two hundred greens and every one of them was
being sent to every client twenty times a second.

Two changes, neither of which a player can observe:

**A prize's position travels as two tile indices, not two Q8 pixel
coordinates.** A prize is always at the centre of a tile -- `spawn_prize` puts
it there and nothing moves it, checked over 5.7 million samples -- so four of
its eight position bytes were carrying nothing. The unpacked state is
bit-identical; `sim_unpack` reconstructs with the same expression that placed
it. Saves 600 bytes.

**A client is only sent the prizes within 256 tiles of its own ship**
(`sim_pack_around`). That is four times the radar's reach, which is the
furthest a client can see a green by any means, and a hull covers 24 px between
snapshots against 3136 px of margin -- the boundary is not somewhere a player
can arrive at. Safe because an unpack replaces the state outright, so nothing
goes stale, and because prediction runs off the same core and the same rng and
reaches the same prizes inside the radius it was told about.

Everything that is not a prize still travels whole. Ships, weapons and flags
are few and all of them matter: a scoreboard names every pilot in the arena,
and a client that was not told about a ship could not draw its name.

Measured on one state with nine ships at the map's real spawns, packed both
ways: **2898 to 1323 bytes, 56.6 to 25.8 KB/s, 54% off** -- and under the
target it was twice over. A live client against a live server reports 0.00 px
of prediction error across the change.

The packing cost is under two microseconds, so doing it per player rather than
once for everybody is thirty microseconds of a fifty millisecond period.

### What prediction actually costs, measured against the deployed server

Six clients flown at the live fleet by `tools/pilot`, which decodes snapshots
through the core rather than a second implementation of the wire format:

```
                    snapshots   egress      predict error (px)
War, 6 pilots       20.0/s      24.5 KB/s   worst 0.50, mean 0.12-0.30
Chaos, 4 pilots     20.0/s      16.7 KB/s   worst 0.50, mean 0.27-0.32
```

0.50 px is a hard ceiling rather than an average: every pilot in every run hits
exactly it and none exceeds it, which is what fixed-point rounding looks like
when the two sides agree. Chaos is cheaper per client than War because it has no
flags to carry.

Death is the only thing that diverges, and it is not a prediction failure: a
respawn teleports the ship, so comparing a still-flying prediction against a
fresh spawn point measures the teleport. Those samples are counted separately,
and they appear if and only if a pilot died -- two per death, the death tick and
the respawn tick, at 38 to 69 px. Accepting them is the client's stated
contract.

Worth saying why this is measured with real clients rather than asserted: the
signed overflow fixed in the recharge clamp was invisible to every other check
in the deployment. The arena was serving, registered and verified, the browse
reply was correct, and the energy bar read INT32_MIN.

### Load time is the host's job, and it is already doing it

Worth writing down so nobody optimizes it twice. The published browser build is
a single 4.03 MB HTML file, most of which is base64 of a 2.43 MB wasm binary.
That looks like an obvious target -- embed the wasm pre-compressed and inflate
it with `DecompressionStream` -- and it is not one.

The host serves the page with `content-encoding: br`, so a browser downloads
**1.55 MB**. Pre-compressing the wasm and base64-ing it gives 1.21 MB for the
binary plus about 0.3 MB for the loader and assets, which is the same number --
except that base64 of compressed data is incompressible, so it would arrive at
that size rather than compressing further, and it would put an inflate step in
front of a loader that already needs a shim to stop it streaming. Measured, not
assumed: 4,034,007 bytes of HTML, 1,549,745 after brotli.

Rough arithmetic at 20 Hz: 40 ships at roughly 16 bytes each after delta
encoding is 640 bytes, plus projectiles and events, so call it 1 KB per snapshot
and 20 KB/s. Upstream is trivial: 8 bytes per tick at 100 Hz, batched, is under
1 KB/s.

When a link cannot carry that, the server throttles by priority the way ASSS
does: weapons and positions outrank everything else, some share of bandwidth is
reserved
per class, and the snapshot rate for distant players degrades before anything
near you does.

## Lag handling

Measurement mirrors Subspace: timestamps in both directions, acknowledgement
round-trip times, and packet counters compared periodically, with the client
reporting its own view because neither side alone sees the truth.

The response is the four-metric, four-threshold model described in
[server.md](server.md). It stays in the server rather than in the simulation,
because it is policy and policy is configuration.

Clock sync is explicit. The client estimates the server's tick from exchanged
timestamps and runs its prediction slightly ahead so that its input for tick T
arrives before the server simulates T. That lead adjusts with measured latency
and is the client's only latency compensation. We are not doing lag compensation
by rewinding the server, and the reason is in the next section.

## Anti-cheat, and what we are not doing

Because the server simulates weapons and damage, the cheats that killed
Subspace's integrity do not apply. A client cannot claim a kill, cannot claim it
did not die, cannot teleport, and cannot fire faster than the settings allow,
because none of those are things a client asserts.

What remains is the class of cheats that make a legitimate client better:
aimbots, and clients that render information the player should not have, like
cloaked ships. Those need different answers. Information the player should not
have is not sent, which is a server-side visibility filter and the same
mechanism that gates energy visibility in Subspace's `Misc:SeeEnergy`. Aim
assistance is a behavioral detection problem, and we are not solving it in the
architecture.

We deliberately do not follow Continuum's approach of checksumming the
executable, the settings, and the map to prove the client is unmodified. That
treadmill costs a permanent reverse-engineering war, and it is the reason
nullspace depends on a private service to answer checksum challenges. Our
answer is to make a modified client useless rather than detectable.

Server-side lag compensation, where the server rewinds other players to what the
shooter saw, is also out for now. It makes hitscan weapons feel better and it
makes you die behind cover, and Subspace's slow projectiles do not need it.
Revisit if the shooting feels wrong at 150 ms.

## Open questions

Whether 20 Hz snapshots are enough for the weapon density a busy arena
generates, or whether projectiles need their own faster channel.

Whether WebTransport is worth adopting when browser support settles, since it
would give web clients unreliable datagrams and delete the whole TCP
head-of-line problem. Measured, below, before deciding.

How to handle a client whose predicted tick drifts because its clock is bad,
without giving it an advantage by letting it choose its own lead.


## What head-of-line blocking actually costs

Measured rather than assumed, because the M2 gate was written as 150 ms and
3% loss and only the latency half had ever been run.

Snapshot inter-arrival at the client, 20 s per condition, 20 Hz snapshots so
50 ms is perfect:

| RTT | Loss | median | p95 | p99 | max | gaps > 150 ms |
|---|---|---|---|---|---|---|
| 40 ms | 0% | 50.0 | 50.9 | 61.1 | 70.2 | 0 |
| 40 ms | 3% | 50.0 | 51.6 | 90.0 | 91.1 | 0 |
| 40 ms | 10% | 50.0 | 89.8 | 91.0 | 91.9 | 0 |
| 150 ms | 0% | 50.0 | 51.1 | 51.9 | 55.0 | 0 |
| 150 ms | 3% | 49.9 | 142.5 | 207.6 | 307.3 | 14 |
| 150 ms | 10% | 49.6 | 191.1 | 200.5 | 309.5 | 35 |

The snapshot count is unchanged in every condition -- 392 to 398 of an
expected 400. Nothing is lost, and that is the whole shape of the problem:
the stream stalls and then delivers the backlog at once, so the median never
moves and the damage is entirely in the tail.

Near players are fine. At 40 ms even 10% loss never produces a gap a player
could name, because a stall costs one RTT and one RTT is shorter than the
interval between snapshots.

Distant players on a lossy link are not. At 150 ms and 3% -- the gate's own
numbers -- 14 gaps over 150 ms in 20 seconds is a hitch roughly every 1.4
seconds, the worst of them 307 ms.

What keeps that from being as bad as it reads: nothing interpolates, but
`net.step` advances the whole simulation every tick, so ships with no fresh
input coast on their last known velocity. Flight is frictionless and has no
drag term, which makes coasting an unusually good predictor -- a remote ship
is only wrong by however much it accelerated during the gap. The artifact is
a correction when the late snapshot lands, not a freeze.

So the tail is real and bounded, and the cheap mitigation is already in
place. Before spending WebTransport on it, the thing to measure is how large
those corrections actually are at 150 ms and 3%, since that is what a player
sees. Transport work is only justified if they are large.

### Method, and its limits

This kernel has no netem and no module to load, so packets could not actually
be dropped. A relay reproduced the consequence instead: each direction has a
release clock, and a loss pushes that clock forward one RTT, which delays the
chunk it hit and everything queued behind it. That is what a receiver holding
a stream does.

Recovery is modelled as fast retransmit, one RTT. Real RTO-based recovery is
slower -- Linux will not go below 200 ms -- so these are the optimistic
numbers, and a real network is somewhat worse than this table.
