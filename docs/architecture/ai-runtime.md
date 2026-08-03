# AI runtime

How the bots described in [design/ai-players.md](../design/ai-players.md)
actually run. The design constraint that shapes everything here survives every
other change in this document: a bot produces inputs and nothing else.

## Placement

Bots run in the bot server, a separate process that connects to arenas over
WebSocket exactly as the Defold client does. One bot server flies a whole
deployment's roster: each bot is one connection, one world decoded from the
snapshots the arena sends, and one brain emitting input messages. The arena
server keeps no bot code at all.

This reverses the placement this document used to argue for. Bots ran inside
the arena's own tick, reading the `World` directly and injecting inputs
without a socket, because in-process bots cost no encoding and no round trip,
and forty per arena would otherwise have tripled our own traffic. That
arithmetic was written before the fleet existed. The deployment is containers
on one host, a bot server beside the arenas pays loopback prices for its
bandwidth, and the encoding cost shrank from an argument into a line item (see
the budget below).

Three things were bought by the reversal.

The protocol gets exercised by its own population. The serious bugs this
deployment has shipped lived on the wire path, and the in-process bots never
touched it: the pong stranded on the wrong half of a split stream, which no
browser ever noticed and which dropped every other kind of client at forty
seconds; the recharge overflow that reached `INT32_MIN` and that only a
harness decoding snapshots ever saw; the prediction divergence caused by a
setting changing without travelling, visible on no other check. Bots that are
clients walk that path all day in every arena and fail loudly the moment it
breaks.

"A bot knows no more than a player" stops being discipline and becomes
structure. In-process, the property was `impl Bot` taking no `&World`, which a
refactor could quietly lose, and the scan feeding it read true server state:
those bots would have seen through cloak on the day cloak existed. A bot
behind the protocol receives the visibility-filtered snapshot a human at its
position would receive, because there is nothing else on the socket.

There is one bot system instead of two. The previous design kept an in-process
path for filler AI and promised a protocol path for third parties. Now the
protocol path is the only path and the house roster is its proof of life: if
our own bots cannot live on it, nobody's can.

An outage of the bot server empties rooms of bots and does nothing else.
Arenas keep serving, humans keep playing, and the population returns when the
process does. That is the same bargain the directory already makes.

## A bot is a declared client

`C2S_JOIN` carries a bot declaration. A declared bot is labeled in the roster
the wire already sends, takes a ship but no seat under `max_players`, which
bounds humans, and is the first thing dropped when a full room must seat an
arriving human. Any client may declare, and a well-behaved bot is one that
does.

House bots also authenticate, presenting a credential from the same table that
authorises arena pools (see [discovery.md](discovery.md)). The split is where
trust lands: anyone's declared bot is welcome, labeled, and rated like any
pilot, but only a house bot's career anchors the rating ladder, because the
anchor is the scale's fixed point and an impostor wearing its name would bend
every rating in the zone.

## The interface

The brain's contract does not change:

```rust
trait Controller {
    fn think(&mut self, view: &Perception, dt: Ticks) -> InputCommand;
}
```

`InputCommand` travels as `C2S_INPUT`, byte-identical to a human client's,
because it is a client's. The arena applies inputs without knowing which
connections declared themselves bots; the declaration matters at the door, for
seats and labels and eviction, and never inside the tick. There is no second
channel into the simulation, so a bot with a bug is a bot that plays badly
rather than a bot that teleports. That used to be a promise kept by code
review. It is now kept by the protocol.

## Perception

A bot decodes snapshots through the simulation core, the way the client and
`tools/pilot` do: map and settings arrive at join, snapshots at 20 Hz, and the
bot server unpacks them into a world the brain reads through the same `own`
and `scan` the calibration harness uses. Whatever visibility filter the server
applied before sending is the filter the bot sees through.

No prediction. Bots look at 10 to 20 Hz and work from a stale picture between
looks, which is both cheaper and more human, so a 20 Hz snapshot stream over
loopback is fresher than the cadence the brain was tuned against. The bot
server holds the latest decoded state and lets each brain look on its own
schedule, offset per bot so the cost spreads.

Sight reaches sixty tiles, the radar's own reach. That bound arrived after the
map did, and it exposed something the unbounded version had been hiding: a
pilot who could see nobody produced no input at all and stopped where it
stood. On a map 1024 tiles across with starts 256 tiles apart, "nobody in
sight" is the ordinary state of a fresh room, so the arena came up as a
gallery of statues, which is what a player reported, in those words. A pilot
with nothing in sight now heads for the contested middle, offset per pilot and
re-rolled on arrival, because that is where the map keeps its furniture and
therefore where anybody else looking for a fight is also going. Measured on
the ladder: 539 kills over 168 bouts without a rally, 2634 with one.

Reaction time is modeled as a queue: a stimulus entering perception is not
visible to the decision layer until its personality's reaction delay has
elapsed. This is why a weak bot is slow to respond rather than artificially
inaccurate, and it produces mistakes that look like the mistakes people make.

## Deciding

Utility scoring over a small set of behaviors: engage, disengage, patrol, escort,
take objective, deny area, reposition, recover. Each behavior scores itself from
the current perception and the bot's personality weights, the highest score wins,
and a hysteresis margin stops the bot from flapping between two near-equal
choices.

Utility rather than behavior trees, because personality then becomes a vector of
weights instead of a hand-authored tree per archetype. Adding a style is data.
That is the same argument as zones-are-content, applied one level down.

Decisions run at 5 to 10 Hz. Inputs are emitted every tick, holding the last
decision's intent in between, because a ship that only steers ten times a second
flies like one.

## Flying

This is the difficult part and it is where naive bots give themselves away.
Frictionless flight means reaching a point is a control problem rather than a
pathfinding one: a bot that thrusts at its target arrives at speed and sails past
it into a wall.

Neither layer below is built. What exists instead is one rule, and it is worth
saying why, because the obvious reading of this section is that routing is done.

A pilot heads straight for where it wants to be and gives up when that stops
working: it keeps the closest it has come to its destination, and two seconds
without closing by 32 px means the destination is behind something. Then it
abandons that kind of destination for five seconds and falls through to the next
thing it would rather be doing. Greens also get a straight-line check before
they are chosen at all, since a green does not move and one behind a wall is
selected again by every plan that follows.

That fixed the bug that was actually reported, which was bots pressing their
noses into a wall with a green on the other side, and A* would not have. A plan
committed to a destination and then re-derived the same destination for ever, so
anything chosen badly once was chosen badly until the pilot died. A pathfinder
needs the give-up underneath it anyway, for every case where the path is right
and the flying is not.

The two layers below are still the plan for when a map has corridors worth
routing through. On a lattice of mostly open cells, straight-line steering plus
give-up covers it.

**Route.** A* over a coarse grid, downsampled from 1024x1024 tiles to 128x128
cells of eight tiles each, with cell cost from wall density. Built once at map
load and shared by every bot in the arena. It answers "roughly which way," not
"exactly where."

**Control.** Given the next waypoint, compute the desired velocity, then pick
rotation and thrust that reduce the error while accounting for current momentum
and stopping distance. Braking distance is `v² / 2a` from the ship's own thrust
setting, so a heavy ship starts slowing earlier, exactly as a human learns to.

Wall avoidance works from the map the bot was sent at join, walked the same way
the brain's line-of-sight test walks it. The bot holds no second copy of the
physics; if it needs to know how the world moves, it reads the world it
decoded.

## Aiming

Leading a target with a projectile of known speed is a quadratic in time to
intercept. Solve it, get the aim point, then apply the personality's aim error as
an angular offset plus an error in the estimate of the target's velocity. Perfect
aim is the special case where both errors are zero, which is the correct way
around: skill is the removal of noise.

Bombs need arc and timing rather than a lead point, mines need placement rules
tied to chokepoints from the coarse grid, and bursts are a panic button with a
threshold.

## The population director

The policy the bot server runs. [design/ai-players.md](../design/ai-players.md)
names its principles; this is the loop.

The bot server browses a directory as a client does and reads the reply it
already gets, which carries `players` and `bots` per zone and per instance. For
every listed instance it holds each room at the zone's fill: `bot_fill` in the
catalog, a share of `max_ships`, defaulting to 0.8. Bots make up the
difference between the target and everyone else present. An empty 64-seat room
gets 51 bots, the first human tips the room over target and one bot stands
down, and a room with humans past the target holds no bots at all.

The unfilled fifth of the room is what lets this loop run relaxed. A join
burst can eat the whole margin before the bot server reacts, and the arena
covers that race itself: a join that would otherwise be refused for space
drops the newest declared bot and seats the human, which is the same
seat-stealing the in-process director performed, moved behind a disconnect. A
human is refused for space only by a room genuinely full of people.

Which bot leaves is the bot server's decision, under the graceful rules of the
design doc: prefer the moment after a death, prefer bots far from any human,
never mid-fight and never carrying a flag. The churn guards hold too: a bot
lives at least thirty seconds and a removal is not refilled for a minute, so a
player joining and leaving repeatedly does not make the roster flicker.

Topology is not its mandate. A zone no instance serves is a deployment
problem, visible in the admin surface; the bot server fills the rooms that
exist and conjures none.

## Calibration stays direct

The ladder tournament in `calibrate.rs` keeps calling the brain against a bare
`World`, no server and no socket, because it is a measuring instrument that
wants thousands of matches at CPU speed rather than a seat in the fleet. What
keeps the instrument honest is that it measures the code the bot server
deploys: the `ai` module leaves the server binary for a crate both depend on.
A copy would drift, and a ladder computed from a drifted copy ranks pilots
that no longer exist. That is not hypothetical. The shipped `ladder.json` once
predated bounded sight and the reserve retune, and its 279-point spread was
staleness, not skill.

The residual gap is the wire itself. Calibration feeds the brain fresh state
at look cadence; a live bot reads 20 Hz snapshots over loopback. The brain was
tuned for 10 to 20 Hz looks, so the live picture is no staler than the
measured one, but calibration measures the brain and not the path around it,
and a wire bug will show up in play before it shows up in a tournament.

## Budget

The costs moved. The bot server's own side is small: a decoded room is 79 KB
with the 1 MB map shared per zone, the brain allocates nothing per tick, and a
few hundred WebSocket connections are what an async runtime is for. Eighty
bots is megabytes and a fraction of a core.

The real cost lands on the arena, which builds an interest-filtered snapshot
stream per bot where the in-process roster needed none. That work was
significant enough to have been halved once already, and it now scales with
the bot population. It is the number that decides whether 0.8 is an affordable
default, so it gets measured before it gets shipped: snapshot build time per
send at fifty-plus clients, read against the 16 us a 64-ship tick costs.

Traffic is free while the bot server sits beside its arenas, since 30 KB/s per
client is loopback. It stops being free only for a region with arenas and no
bot server, so the deployment rule is simply to run one wherever arenas run.

## Determinism and replays

Bot inputs arrive on the same sockets and are written to the arena's input log
exactly like human inputs, which they are. A replay reproduces a match without
any AI running, and without requiring the AI to be deterministic: the behavior
layer can use floats, hash iteration order, and wall-clock timing without
endangering the property that makes the whole architecture work.

## Zone-authored bots

A zone declares its roster shape in configuration: the archetype mix, the
skill distribution, and the roster size. The bot server generates the
individuals from that shape and persists them, with their ratings, careers,
and schedules. That covers most needs without code.

A zone that wants its own behavior ships a module the bot server runs
sandboxed, where a misbehaving controller loses its turn and its bot flies
straight, which is embarrassing rather than fatal. None of it touches the
arena anymore, which is the improvement: custom AI used to be a tenant of the
server's tick and is now a tenant of a process whose whole job is bots.

## Testing

Bots stay the load generator, and they become the wire's canary: a soak test
is the bot server pointed at a real arena, and every hour of fill is an hour
of protocol exercise on the path players use. `tools/pilot` keeps its separate
job of measuring prediction agreement, since bots do not predict.

Bot-versus-bot tournaments calibrate the rating ladder before humans arrive,
as described in [design/rating.md](../design/rating.md).

## Open questions

Whether the coarse grid is enough for maps with tight tunnels, or whether some
maps need authored navigation hints. The original's maps were built for humans
who learn a map over months, and some of them are cruel.

Whether perception at 10 Hz is too generous or too stingy. It is a difficulty
parameter as much as a performance one.

How expensive a sandboxed zone-authored controller is per bot per decision,
now inside the bot server's budget rather than the arena's.
