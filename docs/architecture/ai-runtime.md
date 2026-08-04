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

House bots hold accounts of their own, claimed with the bot server's pool
credential and one per roster individual, per
[design/accounts.md](../design/accounts.md). That is what makes the label a
player sees say *house bot* rather than *somebody's bot*, and it is what lets
one of them anchor the ladder.

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

Both layers are built now, in `server/src/nav.rs` and the back half of
`server/src/ai.rs`. What stood here for a long time was one rule, and it is worth
keeping the account of why that was not enough.

A pilot headed straight for where it wanted to be and gave up when that stopped
working: it kept the closest it had come, and two seconds without closing by
32 px meant the destination was behind something. Then it abandoned that kind of
destination for five seconds. That fixed the bug that was reported, which was
bots pressing their noses into a wall with a green on the other side. It did not
fix flying, and a drill on Chaos eventually caught what it left: a pilot holding
thrust into a wall for ninety seconds, travelling one pixel every ten ticks,
because every replacement destination was rolled from the same box in the middle
of the map and lay through the same wall.

**Route.** A* over the map at two tiles to a cell, 512 by 512, any solid tile
shutting a cell, built once per map and shared by every pilot flying it. Cells
against a wall cost three times an open one, which puts a route down the middle
of a corridor rather than along its edge.

Two tiles rather than the eight this document specified for years, and the
difference is not a detail. Our walls are two tiles through, so an eight-tile
cell holding a wall right across it is a quarter solid: any density threshold
loose enough to keep the corridors open lets a route pass straight through the
wall beside them. Built to spec it changed nothing measurable, because every cell
on Chaos came out passable. A hull is 28 px across and a two-tile cell is 32, so
"any wall shuts it" needs no threshold and no tuning.

**Control.** The pilot wants a velocity, not a heading: `v² = v_end² + 2as`
gives the speed that can still be shed in the road left, and the difference
between that and what the hull is doing is the burn. The nose points at the burn
when there is nothing to shoot and at the target when there is, since decision 17
makes the nose the gun and the engine at once, and thrust then fires only when it
happens to help. That is what makes a fight look like circling rather than a
charge.

The `v_end` term is where the first version of this went wrong, and it cost the
roster half its life. Braking to zero at the *steer point* means parking at every
waypoint of every route and at every green, then turning from a standstill at
230 rotation and accelerating from nothing, over and over: the drill measured
50 to 70 per cent of all bot-ticks under half a pixel of motion, nearly all of it
in travel. So a route carries a pass speed per bend, set by the angle between its
legs, and a destination carries one too -- a green's pickup radius is sixteen
pixels, so it is taken at a slow pass rather than a stop. Waypoints advance at
the tick rate the moment they are passed; only deciding waits for a reaction.
Crawling fell to about a quarter of ticks, and kills roughly doubled.

Deciding and flying run on different clocks, and that split is load-bearing.
Steering used to be decided with the plan and held until the next one, so a pilot
on a 38 tick reaction held a turn for 38 ticks: at 230 rotation that is 79 degrees
of swing with nothing looking. Reaction time belongs on what to do. A servo loop
belongs on every tick.

The give-up timer stays underneath all of it, watching the waypoint rather than
the destination. Going the long way round a wall closes no straight-line distance
for seconds at a time, so a timer watching the destination calls every correct
detour a failure.

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

Solved in `ai.rs` now, and in the pilot's own frame, which is the part that is
easy to get wrong: the core fires a round at `vx0 + speed * direction`, so a shot
carries the ship's velocity with it and only the target's *relative* motion has to
be led. A hull does 3.25 px a tick and a bullet 2, so the ship outruns its own
gun and a lead that ignores this is not a small error. What stood here was
`lead = distance / 2`, a constant that happens to match the bullet the shipped
zones fire and no other weapon in the game.

A shot is also held unless the line to the target is clear and the aim is inside
the angle the target actually subtends, rather than a flat 0.16 radians that was
two ships wide up close and four at range. Before both, one shot in seventy-seven
landed.

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

## One binary, three programs

The bot server is `vectorwake-server bots`, the same binary the arena and the
directory are, told what to be by its first argument. A deployment is that
image run four times with different commands.

That settles a question this document was going to answer differently. The
calibration tournament and the live bots must run identical code, because a
ladder computed from a drifted copy ranks pilots who no longer exist, and that
is not hypothetical: the shipped `ladder.json` once predated bounded sight and
the reserve retune, and its 279-point spread turned out to be staleness rather
than skill. The plan was to lift the brain into a crate both binaries depend
on. Being one binary is the same guarantee with nothing to arrange.

## Calibration stays direct

The ladder tournament in `calibrate.rs` keeps calling the brain against a bare
`World`, with no server and no socket, because it is a measuring instrument
that wants thousands of matches at CPU speed rather than a seat in the fleet.

The residual gap is the wire itself. Calibration feeds the brain fresh state at
look cadence; a live bot reads 20 Hz snapshots and steps its own copy between
them. The brain was tuned for 10 to 20 Hz looks, so the live picture is no
staler than the measured one, but calibration measures the brain and not the
path around it, and a wire bug will show up in play before it shows up in a
tournament.

## Budget

The costs moved rather than grew. Measured on a 64-seat room at `bot_fill` 0.8,
which is 51 bots, with the numbers in [hosting.md](hosting.md): the arena spends
3% of its tick budget in the worst case, almost all of it building 51
interest-filtered snapshots on the ticks that carry one, and the bot server
spends 14% of a core and 15 MB.

The bot server's share is the larger one and it is the price of the brain
keeping its timing: each bot steps its own copy of the room at 100 Hz between
snapshots. Memory stays small because the bots of one zone share one map by
`Arc`, the same trick that keeps a room at 79 KB.

Traffic is free while the bot server sits beside its arenas, since 30 KB/s per
client is loopback. It stops being free for a region with arenas and no bot
server, so the deployment rule is to run one wherever arenas run.

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

That tournament is not a test of flying, and reading it as one cost a long time.
It is fought in `sim_map_pit`, a bare thirty-tile box with two blocks in it, no
greens and two ships, which is the right room for ranking two pilots and a room
in which routing, dodging, a crowd and a prize economy cannot happen. Every
failure that only shows up in Chaos is invisible to the ladder rating them.

`vectorwake-server drill [zone] [seconds] [bots]` is the other half: the roster on
a zone's own map, reporting kills, wall contacts, shots, what fraction of them
land, how much of the time a pilot is going nowhere and how much ground the
roster covers. It ranks nobody. It exists so that a change to the brain has a
number on either side of it. `DRILL_TRACE=1 DRILL_FROM=<tick>` prints one pilot's
control loop tick by tick, which is how the wall-pusher above was found.

## Open questions

Whether the grid is enough for maps with tight tunnels, or whether some maps need
authored navigation hints. The original's maps were built for humans who learn a
map over months, and some of them are cruel.

Why pilots still spend most of their time travelling rather than fighting. On the
drill it is about nine parts in ten, which is a roster that keeps missing each
other:
sight is sixty tiles, a map is a thousand, and roaming aims everybody at the
middle. Somewhere between a smarter patrol and a reason to be anywhere in
particular.

Whether perception at 10 Hz is too generous or too stingy. It is a difficulty
parameter as much as a performance one.

How expensive a sandboxed zone-authored controller is per bot per decision,
now inside the bot server's budget rather than the arena's.
