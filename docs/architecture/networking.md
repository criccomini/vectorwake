# Networking

## One protocol, two doors

Every message in this file travels the same whichever transport carries it,
and there are two. The WebSocket is the door that is always open: TCP, carried
by every browser and every network, terminated by Caddy in the deployed fleet.
WebTransport is the door a browser is offered first when the zone serves one,
because it is QUIC: streams that do not wait for each other and datagrams that
are never retransmitted, which between them remove the head-of-line stall
measured at the bottom of this file. A client that cannot raise the QUIC door
takes the socket on its own, silently, which is why the WebSocket stays
first-class rather than legacy: enough networks eat UDP that the preferred
transport can only ever be a preference.

Native clients would speak plain UDP, and still will if a native client ever
ships; nothing about the messages changes.

The protocol is designed for the weakest transport. On TCP a lost packet blocks
everything behind it, so snapshots must be individually useful rather than a
chain of deltas that breaks when one link is missing. Every snapshot is
decodable against a baseline the server knows the client has, and the server
never assumes a snapshot arrived until the client says so.

## Message model

Two channels, distinguished per message rather than per connection.

Unreliable messages carry state that a newer message supersedes: input
commands, snapshots, position updates. Losing one costs nothing because another
follows in 50 ms. On WebTransport they are datagrams when they fit under the
path's MTU and a unidirectional stream of their own when they do not; either
way a loss delays only the message it hit, and the client discards a stale one
by tick number. On WebSocket they inherit TCP's ordering, which we cannot
avoid, so we keep them small and lean on the same tick numbers.

Reliable messages carry things that must arrive exactly once: arena joins,
settings, map metadata, score updates, kill notifications. On WebTransport they
ride one bidirectional stream, length-framed with a u32 because a packed map
outgrows a u16; on WebSocket they ride the socket's own guarantees. Both are
TCP-shaped lanes and the same code serves them: the server's handler reads
whole messages from a queue and has never heard of either transport.

That guarantee is narrower than it sounds. TCP delivers what the server hands it,
and the server hands messages to a bounded per-connection queue, forty deep,
where every enqueue is a `try_send` whose failure is discarded. Right for a
snapshot, which is worthless a tick later. Wrong for anything a client cannot get
a second time. The roster was sent once on join and after that only when somebody
arrived or left, so one full queue cost a player every name in the room for the
rest of the session: a scoreboard of ship numbers, and a kill feed reading "ship
5 killed ship 8". It repeats every two seconds now. Anything else that has to
arrive and is not on a clock has the same hole in it.

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
  u16 buttons         // thrust, reverse, left, right, fire, bomb, use, slot
  u32 tick            // the tick this input applies to
}
```

The tick is honoured rather than advisory, and that distinction is the whole of
the input path. An input naming a tick the arena has not reached waits in a
per-player queue until it does, so a client whose clock runs ahead of the
server's applies the same buttons on the same tick number the server will. One
naming a tick already simulated takes effect immediately instead, because the
server must not rewind a room to accommodate one late packet.

A tick with nothing scheduled reuses whatever that pilot was already holding.
That is the right default rather than a fallback of convenience: a held key is
the ordinary case, so a lost input reads as a continued hold instead of a
stutter.

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
coordinates.** A prize is always at the center of a tile -- `spawn_prize` puts
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

That was the first cut, and it aged badly. It reasoned that ships and weapons
were few, which stopped being true: a room fills to fifty-one bots, and the
measurement below found nearly four hundred rounds in the air at once.

**Ships and rounds now go through the same radius**, and that change is about
two things at once.

The bytes. Measured on the live arena by parsing weapon positions out of the
real wire and testing each against the radius, **20.9% of 191,115
weapon-snapshots fell inside it**. Rounds were 77.6% of a snapshot, so four
fifths of the traffic was bullets from fights the viewer could not see.

The sight. A snapshot used to hand every client the position, velocity, energy
and held buttons of every ship on the map, so a maphack was not an exploit but
a rendering choice: draw what you were sent. This is the game the original
lost, and its own answer was to gate seeing other pilots' energy behind a
capability. A client is now told about what it could lawfully look at, and a
modified one has nothing else to draw. The boundary is worth stating plainly:
inside the radius everything still travels, because prediction needs it, so
near-field ESP survives. The property bought is "no knowledge beyond lawful
sight", not "no knowledge at all".

Three details make it work. Ships travel behind a **presence bitmap** rather
than a shortened array, because a ship index is identity for the roster, the
kill feed and the team lists; the count stays the arena's and absent seats
arrive inactive. Rounds need no bitmap, since a weapon index is not identity
and the array is rebuilt from the wire every snapshot. And **the scores moved
to the roster**, which already carried every seat in the arena twice a second,
so a board can still name and score a pilot the snapshot leaves out. The client
prefers the simulation for seats it can see, because that arrives twenty times
a second, and the roster for the rest.

The exemption is our own bots, and it is keyed on the token's label rather than
on what the client said about itself at join. That distinction is the whole of
it: the old test was `Player::bot`, the declaration, so anybody could declare
themselves a bot from any address and be handed every ship on the map. The
label is derived from the account a token was minted for and cannot be
asserted, so a third-party bot is filtered exactly like the person running it.
Flags still travel whole, being few and being objectives every pilot is
entitled to know the state of.

### Sizing the radius against what can be drawn

It was 256 tiles, four times the radar's reach, chosen when it filtered prizes
alone. Ships and rounds care about a different bound: `TUNE.STATIC_MAX` in
arena.script holds the terrain window at **137 tiles** either side and says so
out loud when a view asks for more, so 137 is the furthest anything can be
rendered by any means.

So the radius is 160 tiles, that plus 23. What has to cross the margin before
the next snapshot announces it: a hull at 490 px/s covers 24 px in the 50 ms
period, and the quickest round in the baseline is `sim_units_speed(3000)`, 300
px/s, covering 15. Against 368 px of margin that is fifteen periods of warning
for the fastest thing in the game.

The area ratio is what pays. (160/256) squared is 0.39, so the same rule costs
61% fewer rounds in range, for one constant and no change to the wire.

### Measured

Against a full fifty-two ship room, one pilot flown by `tools/pilot`:

| | KB/s | predict err worst/mean |
|---|---|---|
| before | 312.0 | 0.75 / 0.38 |
| ships and rounds culled, 256 tiles | 24.4 | 0.61 / 0.24 |
| radius sized to the render window, 160 tiles | **17.0** | 0.73 / 0.40 |

94.6% off, with no corrections at any point and prediction error staying at the
0.5 px band that fixed-point rounding puts it in.

Against the live fleet, two pilots in a room of fifty-three: **30.7 and 66.2
KB/s**, from 312 and 345 before. The spread is fight density rather than noise
and it is the honest shape of this: a pilot in a quiet corner is at the target,
a pilot in the middle of the room's one big fight is twice it, because
everything the cull removes is by definition somewhere you are not.

One sharp edge came out of filtering ships, and it is worth writing down
because nothing about it is obvious. A proximity fuse latches a ship index, and
`sim_step` reads that seat and ends the round the moment it is inactive. An
absent seat is a zeroed seat, so a round inside the radius that had latched
somebody just outside it detonated on the client while the server flew it on:
a phantom explosion at the edge of the view. Such a round now travels unarmed,
which is the honest statement rather than a workaround, since the client is
being told it does not know what the round is tracking and the fuse was always
the server's to resolve.

One operator-facing number had to change with it. `bw/seat` divided the whole
process's snapshot bytes by every seat, and a room seats fifty-one house bots
against a handful of people. Those bots are on loopback and are sent the whole
room by design, so the average was over a population that costs nothing and
reads everything: it reported 305 kB/s while a real client was pulling 17. It
counts the seats a snapshot is actually filtered for now, which is the same
boolean that chooses the radius, so the two cannot disagree. That it did not degrade is
worth stating, because it might have: a client no longer consumes rng for
shrapnel it cannot see, so its generator can drift from the server's inside a
snapshot period. The resync every 50 ms evidently dominates. A fix that derives
the spread from state rather than the shared generator is written down here in
case that stops being true.

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

Clock sync is explicit, and it needs no timestamps. Every snapshot header
already carries the newest input tick the server has received from that client,
so the gap between it and the tick the snapshot was packed on *is* the round
trip, measured in the only unit the simulation cares about. A positive gap means
inputs are arriving after the ticks they name.

The client steers on that number: one tick of lead added or given back per
snapshot, twenty times a second, aiming to sit about two ticks early with a dead
band so a clock that is comfortably ahead is left alone. From a cold start it
settles in under a second, and it never jumps, because a jump is itself the
correction this exists to remove.

Measured against a local arena, three pilots for fifteen seconds. Without a
lead, inputs ran a mean of 2.7 ticks late and never once arrived early. With the
loop, a mean of 3.4 ticks early, settling at a lead of six to eight; the only
late inputs are in the first second while it converges. That is on loopback,
where the whole figure is send cadence and snapshot timing rather than distance,
so a real link starts further behind and the loop simply settles further ahead.

The cost of running ahead is paid by everyone else on your screen. Remote
ships have no inputs to predict from and coast on their last known velocity
between snapshots, so a larger lead means a longer coast. Frictionless flight
makes coasting an unusually good predictor, which is why the cost is mild, but
it is the reason the lead is the smallest number that works rather than a
comfortable margin.

Holding each remote ship's last-seen buttons through the predicted ticks --
`btn_prev` already rides in every snapshot -- was tried and reverted within a
day. It survived a two-human test, because people hold keys for hundreds of
milliseconds, and fell apart in a room of bots, whose bang-bang steering flips
buttons faster than snapshots sample them: the button a snapshot catches is
wrong about half the time, and holding it for the lead amplifies dither into
hulls twitching at snapshot rate. The lesson is written down because the idea
will look good again someday: an extrapolator here has to be right about the
median ship in the room, and the median ship is a bot.

That lead is the client's only latency compensation. We are not doing lag
compensation by rewinding the server, and the reason is in the next section.

## What the screen shows, against what the simulation holds

Two jitters, neither of them a prediction failure, both fixed in the drawing
rather than in the state. See the render section of `client/ext/simcore/src/simcore.cpp`.

**The tick grid against the refresh rate.** The core runs at 100 Hz and no
display refreshes at a multiple of it, so drawing the newest tick advances the
world by one tick on some frames and two on others at 60 Hz, and by one or none
at 120. That is a speed ripple on every frame of every screen, on the camera and
everything in it, and it has nothing to do with the network. Positions are
interpolated between the last two ticks by where the frame actually falls. The
cost is one tick of visual latency, ten milliseconds, less than a frame anywhere;
the gain is that it is *constant*, in place of a random nought to ten. Constant
latency is invisible. Varying latency is the judder.

Raising the tick rate to 120 would divide 60 and 120 cleanly and fix the same
thing without interpolating, and it was considered and dropped. Every delay,
lifetime and cooldown in every zone file is a tick count inherited from a server
that ran at 100 Hz, `original-settings.md` turns on the two rates being equal,
the unit conversions in `sim.c` bake in the thousand, and it would still alias on
a 144 Hz screen. Interpolation makes the sim rate and the refresh rate
independent, which is the property actually wanted.

**The snapshot against the extrapolation.** A snapshot lands twenty times a
second and replaces state outright, so a remote ship extrapolated wrong snaps to
the truth. `smooth_capture` and `smooth_settle` bracket the correction: whatever
the screen was asserting about each hull is held, and the difference between it
and the truth is carried as a per-ship offset that decays on an eighty
millisecond half-life. Past four tiles it is a teleport rather than a correction
-- a respawn, a wormhole -- and snaps, because easing one reads as a ship being
dragged rather than arriving. Forty pixels caps what the drawing may be lying by
at any moment. Both numbers were cut once -- to fifty milliseconds and sixteen
pixels, priced against a shot visibly passing through a hull drawn somewhere its
box is not -- and restored within a day. The mechanism also carries the clock
steering for the pilot's own camera, and on a live link those corrections are
small, frequent, and alternating in sign; the decay sets how much of each one
shows before the next cancels it, and at fifty milliseconds the sum read as the
whole screen juddering at snapshot rate. A wall measured in a player's recording
stepped backwards seven pixels every few frames. Detonations are pinned to hulls
from the other side: a weapon's ending names the hull it ended on, and the
renderer moves the blast by that hull's current offset so the ring stays on the
ship the shooter is looking at.

The clock steering rides in the same mechanism, deliberately: a snapshot that
trims the lead by a tick moves every hull by a tick of flight, which is exactly
the kind of jump worth walking off rather than cutting to.

Both live in the extension rather than at the twenty call sites that draw a
position, because one of those being missed is worse than none of them being
fixed. A hull that judders against its own health bar reads as broken in a way a
hull that judders with everything else does not. `ship_x_raw` and its two
siblings are the exceptions: measuring how far a prediction missed by, and
reading what the pilot's own hands asked for, are the two things that must not be
told a comfortable story.

What this does *not* do is interpolate remote ships from the past, the way a
Source-lineage game renders everyone 100 ms back. Aiming here is the nose, so
showing a remote ship where it was would systematically shift where players aim
at it. Extrapolation stays; these two smooth how it is presented.

One more pass-through had nothing to do with the network at all. The weapon
hit test sampled once per tick, at the end of the tick's travel, and a round
plus its shooter's velocity covers up to 6.25 px a tick against a flank 12 px
thick: a grazing crossing could fall entirely between two samples, on the
server, with everyone on loopback. The sim walks each tick's travel in 4 px
samples now, walls included, so nothing shipped or retuned tunnels. That fix
lives in `sim.c` rather than anywhere near this file, which is the point:
before hiding lag, be sure the thing being hidden is actually lag.

## Anti-cheat, and what we are not doing

Because the server simulates weapons and damage, the cheats that killed
Subspace's integrity do not apply. A client cannot claim a kill, cannot claim it
did not die, cannot teleport, and cannot fire faster than the settings allow,
because none of those are things a client asserts.

What remains is the class of cheats that make a legitimate client better:
aimbots, and clients that render information the player should not have. Those
need different answers, and the second is decided but not built. Today a
snapshot carries the whole room to every client, and the 60-tile sight limit
is drawn by the client rather than enforced by the wire, so a modified client
reads the map. The answer, when it is worth its weight, is a visibility filter
where snapshots pack, the mechanism behind Subspace's `Misc:SeeEnergy`, with
full view becoming a named capability like the staff powers the catalog
already carries: granted per account and zone, held by the house fleet, whose
shared prediction needs whole-room snapshots, and by staff. The bot flag a
client declares at join grants the whole prize table in the meantime, which is
this capability issued by the wrong authority, the client itself; the filter
and the capability ship together, because until data is withheld there is
nothing for a grant to open.

The leak has depth as well as reach. A packed ship is the whole ship: exact
energy, charge counts, greens held, weapon rungs. A modified client can put an
energy bar over every enemy, which is precisely the read `SeeEnergy` existed
to gate, and can know whether a pilot still holds a repel before committing to
the rush that repel would answer. So the filter, when it comes, trims fields
as well as culling distant ships. One dependency to mind by then: the
legitimate client reads remote charge counts to draw other people's repels,
because a one-tick weapon never survives into a snapshot. Withholding those
counts means sending the shove as its own message the way kills are sent,
which is the cleaner shape anyway.

A filter has a ceiling worth stating: clients can pool their lawful sights,
which is a scout team and is answered like one, with seats, visibility on
radar, and bans. The filter's job is economics rather than secrecy, making
global knowledge cost what a team costs instead of nothing. Aim assistance is
a behavioral detection problem, and we are not solving it in the architecture.

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

How large the corrections on a remote ship actually are at 150 ms and 3% loss,
now that there is something absorbing them. That number, rather than own-ship
prediction error, is what the WebTransport door was built to shrink, and
`tools/pilot` measures the wrong one for it. With both doors live the question
has a control group: the same fleet serves both wires, so the comparison is
waiting in the metrics rather than in a lab.

What share of real clients actually lands on WebTransport. Every QUIC failure
is silent by design, one fallback per session, so only counting per wire says
whether the preferred door is where most players come through or an
optimization for the well-connected. `vw_wt_sessions_total` against
`vw_connections_total` is that count, waiting to be read; the arenas carry
`vw_wt_listening` beside it, because a door that never opened and a door
nobody uses are the same zero otherwise.

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

What keeps that from being as bad as it reads: `net.step` advances the whole
simulation every tick, so ships with no fresh input coast on their last known
velocity. Flight is frictionless and has no
drag term, which makes coasting an unusually good predictor -- a remote ship
is only wrong by however much it accelerated during the gap. The artifact is
a correction when the late snapshot lands, not a freeze.

So the tail is real and bounded, and the cheap mitigation is already in
place. This table is what the WebTransport door in the next section was built
against: every number in the two lossy rows is TCP holding delivered snapshots
hostage to a retransmit, and QUIC's independent streams make that particular
tail structurally impossible. What the door cannot fix is the loss itself,
which is why the correction sizes stay on the open questions list with a
before-and-after now available to measure.

### Method, and its limits

This kernel has no netem and no module to load, so packets could not actually
be dropped. A relay reproduced the consequence instead: each direction has a
release clock, and a loss pushes that clock forward one RTT, which delays the
chunk it hit and everything queued behind it. That is what a receiver holding
a stream does.

Recovery is modeled as fast retransmit, one RTT. Real RTO-based recovery is
slower -- Linux will not go below 200 ms -- so these are the optimistic
numbers, and a real network is somewhat worse than this table.

## The WebTransport door

Built once the support question settled: WebTransport ships in every current
browser, the server side is one Rust module over a maintained crate, and the
client side is one extension speaking the browser's own API. The protocol did
not move at all, which was the test of the message model above: the same tags,
the same bytes, sorted onto lanes that finally match the two channels the
design always described.

The one place the extension has to know which browser it is talking to is the
datagram writer. It has two names: `datagrams.writable`, the original, now
deprecated; and `datagrams.createWritable()`, the current spelling. No engine
has both. Chrome and Firefox have the property, Safari has had the method since
26.4, so the extension takes whichever is there. Naming the property outright
cost every iPhone the faster door: the handshake succeeded, the client refused
the session it had just opened, and the about page blamed a network that had
done nothing.

Three lanes, chosen per message. The client opens one bidirectional stream and
speaks first on it; both directions carry every reliable message there,
u32-framed. Snapshots leave as datagrams when one fits and on a fresh
unidirectional stream each when it does not, so a loss delays the snapshot it
hit and nothing else. Inputs are datagrams, sent once: a lost input costs a
tick of held buttons, which is what the input model already does with silence,
and a retransmitted one would arrive naming a tick the room has already run.

Three consequences land on the client. Lanes can pass each other, which the
socket never allowed, so `net.lua` reads the pack's own tick and drops a
snapshot that arrives behind one already applied rather than walking the room
backwards. A watcher needs that guard as much as a pilot, and cannot have the
same one: the shared channel runs deliberately behind live, so a view switch
moves that clock backwards on purpose and a plain monotonic rule would refuse
the whole delay. The two are told apart by size. Reordering is a snapshot or
two; the channel's delay is five seconds. Anything further back than a second
is a change of view and anything nearer is the network. The guard was simply
off while watching, and what that cost is two explosions for one death: the
stale snapshot revives a hull the room has already killed, and the next fresh
one kills it again.

Lanes not passing each other is also something the join sequence had been
quietly relying on. The map, the settings and the welcome ride the reliable
lane and snapshots ride beside it, and on TCP that was an order; on QUIC a
snapshot datagram passes a map still ramping up, and the client was applying
it to a world with no terrain and no seat. Snapshots now wait for the welcome,
which is the message that says which seat is yours.

And a dial can go nowhere without an error, because a network that eats UDP
eats the handshake too: three silent seconds and the client redials the
WebSocket address with the same join, and the player sees nothing but the
game. What it remembers is the door, not the network. A zone advertises its
QUIC address as soon as it is configured, including through the half minute a
fresh host spends waiting for its certificate, so a silent door is as likely
to be one arena starting up as a network blocking UDP; remembering it for the
session put players on the slower wire for every zone and told them their
network had eaten it.

The handshake is not the session, so a second clock runs from the open to the
first snapshot. A desktop browser with an update staged has been seen
completing the QUIC handshake and then wedging half-open, the reliable lane
stalled while datagrams flowed, which left a player staring at "joining" over
a live arena with nothing to report and no way out but a reload. The dial
clock cannot catch that state: it stopped the moment the session opened. Five
seconds without a snapshot now loses the join to the socket by the same quiet
road as an unanswered dial, and a snapshot is the right proof because it rides
behind the welcome's own gate: one in hand means both lanes spoke. The window
is wider than the dial's because it carries the map, and a slow link is not a
stalled one.

A proven session keeps a quiet clock of its own, because of how a QUIC peer
dies. The kernel closes a dead process's TCP sockets, so the WebSocket's
players get their hangup within a second of an arena going down; QUIC lives in
userspace and a killed arena says nothing, which left a WebTransport player
coasting in a ghost room until the browser's own idle timer noticed, tens of
seconds later: every hull drifting on its last course, and nothing killable,
because deaths only ever arrive as snapshots. Eight seconds without a snapshot
is a dead wire on any network worth playing over, and it is reported rather
than redialled, since mid-game the seat is gone whichever wire comes next. The
arena does its half on the way out: SIGTERM closes the WebTransport endpoint
before the process exits, so a deploy's restart reads as a hangup rather than
as eight seconds of drift.

Which is why both readouts say which door a connection came through, since
otherwise nothing would. The debug readout carries it in flight, as `wt` or
`ws` beside the lag and the lead. The menu's about page carries it in words,
because that page is what somebody quotes into a bug report: it names the
transport and what it is made of, QUIC datagrams against TLS over TCP, and
when a pilot is on the socket having been offered the other door it says that
QUIC went unanswered, which is the one line that explains a slower game. It
says none of this with an address in it. Whoever runs the fleet reads logs,
and a player reading a `wss` url is reading something not addressed to them.

The deployed fleet's one entanglement is the certificate. Caddy cannot front
this door: a WebTransport session *is* the HTTP/3 connection, not something a
proxy can pass along. So each arena terminates QUIC itself on its own public
UDP port and reads the PEM pair out of Caddy's certificate store, mounted
read-only. The paths are glob patterns because the store nests certificates
under the ACME issuer's directory name, which is Caddy's business, and the
files are re-read on a timer so a renewal lands without a restart: a QUIC
handshake presents whatever was loaded, and a fleet that needed a restart to
notice a renewal would fail exactly as silently as the renewal succeeded.

The directory advertises the second address as `wt` beside each instance's
`address`, unverified where the WebSocket address is verified, and that is
deliberate: the client's own fallback is the safety net, so a dead claim costs
one three-second dial rather than a stranded player. `server/src/wt.rs` and
`client/ext/webtransport` are the two halves; `wire_test.lua` pins the
client's choosing and the server's own test joins an arena over the real
thing, self-signed, datagram acknowledgement and all.

The door also has to bound what a stranger on its port can cost, which the
first version of it did not. The WebSocket door caps a frame at eight
kilobytes and always said why: whoever finds an open port gets to cost
kilobytes, not gigabytes. QUIC's defaults are the opposite kind of generous,
a hundred streams at a megabyte and a quarter of buffer each and no
connection-wide ceiling at all, which is a quarter of a gigabyte for one
handshake from a peer that opens streams and never reads them. An arena
accepts one bidirectional stream and no unidirectional ones, so everything
else a client opens is buffered and never looked at. The transport config now
names all four numbers, and the connection-wide one is the one that actually
bounds it. The client needed the mirror of the same rule: it believed the
length word on the reliable lane, so a zone could name a message of any size
and the client would try to hold it. Both directions are capped now, each at
the largest thing that direction legitimately says.

Two smaller rules follow from lanes being independent. A reliable stream that
ends takes its session with it, because the datagram lane cannot speak for it:
without that, a client whose asks all vanished kept flying, and a watcher,
whose keepalive *is* an ask, was dropped for silence a minute later while it
was still writing. And an input that arrives late is applied only if it is not
older than one already applied, because two datagrams can swap in flight and
the older one was undoing the newer one's press.
