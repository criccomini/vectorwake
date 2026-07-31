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

Reliable messages carry things that must arrive exactly once: chat, arena joins,
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
  u16 heading         // 1/65536 turn, for mouse aim if enabled
}
```

Commands are cumulative and cheap, so each datagram repeats the last several.
Losing a datagram then costs nothing as long as the next arrives within the
window, which is the standard trick and it works here because inputs are tiny.

That is nearly the whole client-to-server surface for gameplay. Everything else
is chat, arena changes, ship changes, and requests, all reliable and all rare.

## Server to client

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

Rough arithmetic at 20 Hz: 40 ships at roughly 16 bytes each after delta
encoding is 640 bytes, plus projectiles and events, so call it 1 KB per snapshot
and 20 KB/s. Upstream is trivial: 8 bytes per tick at 100 Hz, batched, is under
1 KB/s.

When a link cannot carry that, the server throttles by priority the way ASSS
does: weapons and positions outrank chat, some share of bandwidth is reserved
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
head-of-line problem.

How to handle a client whose predicted tick drifts because its clock is bad,
without giving it an advantage by letting it choose its own lead.
