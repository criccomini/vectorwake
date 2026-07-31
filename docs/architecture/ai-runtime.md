# AI runtime

How the bots described in [design/ai-players.md](../design/ai-players.md)
actually run. The design constraint that shapes everything here: a bot produces
inputs and nothing else.

## Placement

Bots run inside the zone server process, in the arena's own tick, after the
snapshot builder has produced visibility and before `sim_step`. They are not a
separate process and they are not inside the sim core.

Not separate, because an in-process bot costs no sockets, no encoding, and no
round trip, and forty of them per arena would otherwise triple our own traffic.

Not inside the sim core, because the core stays deterministic, allocation-free,
and portable, and a behavior layer wants hash maps, floats, and pathfinding
scratch space. Keeping AI out of the core also means the client's copy of the
core carries no AI code, which matters for the web bundle.

## The interface

```rust
trait Controller {
    fn think(&mut self, view: &Perception, dt: Ticks) -> InputCommand;
}
```

`InputCommand` is byte-identical to what arrives from a network client. The arena
does not know which players are bots when it applies inputs, and cannot be made
to care.

This is the enforcement mechanism for "bots cannot cheat." There is no second
channel into the simulation, so a bot with a bug is a bot that plays badly rather
than a bot that teleports.

## Perception

A bot's view comes from the same visibility filter that builds snapshots for
human clients. If a cloaked ship would not be in a human's snapshot at that
position, it is not in the bot's perception either.

Perception refreshes at 10 to 20 Hz rather than every tick, and each bot's
refresh is offset so the cost spreads across ticks. Between refreshes the bot
works from a slightly stale picture, which is both cheaper and more human.

Reaction time is modeled as a queue: a stimulus entering perception is not
visible to the decision layer until its personality's reaction delay has elapsed.
This is why a weak bot is slow to respond rather than artificially inaccurate,
and it produces mistakes that look like the mistakes people make.

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

Two layers:

**Route.** A* over a coarse grid, downsampled from 1024x1024 tiles to 128x128
cells of eight tiles each, with cell cost from wall density. Built once at map
load and shared by every bot in the arena. It answers "roughly which way," not
"exactly where."

**Control.** Given the next waypoint, compute the desired velocity, then pick
rotation and thrust that reduce the error while accounting for current momentum
and stopping distance. Braking distance is `v² / 2a` from the ship's own thrust
setting, so a heavy ship starts slowing earlier, exactly as a human learns to.

Wall avoidance uses the sim core's collision sweep rather than a second copy of
the physics. The core exposes read-only queries for this:

```c
bool sim_sweep_blocked(const sim_state*, sim_vec from, sim_vec to, int radius);
int  sim_ticks_to_wall(const sim_state*, uint16_t ship_id, int max_ticks);
```

If the AI ever needs to know how the world moves, it asks the world.

## Aiming

Leading a target with a projectile of known speed is a quadratic in time to
intercept. Solve it, get the aim point, then apply the personality's aim error as
an angular offset plus an error in the estimate of the target's velocity. Perfect
aim is the special case where both errors are zero, which is the correct way
around: skill is the removal of noise.

Bombs need arc and timing rather than a lead point, mines need placement rules
tied to chokepoints from the coarse grid, and bursts are a panic button with a
threshold.

## Budget

Forty bots must fit comfortably inside the arena's 10 ms tick alongside the
simulation. The target is under 1 ms total for all bots in an arena.

It is reached by staggering: bots are bucketed so that on any given tick only a
fraction refresh perception and only a fraction re-plan. Route queries are cached
and shared. Nothing in the AI allocates during a tick.

## Determinism and replays

Bot inputs are written to the arena's input log exactly like human inputs. A
replay therefore reproduces a match without the AI running at all, and without
requiring the AI to be deterministic.

That is worth stating plainly because it buys real freedom: the behavior layer
can use floats, hash iteration order, and wall-clock timing without endangering
the property that makes the whole architecture work.

## Zone-authored bots

A zone declares its roster in configuration: archetype, skill, ship, persona
name, and how many of each the director may spawn. That covers most needs
without code.

A zone that wants its own behavior ships a module implementing `Controller`,
sandboxed under the same rules and fuel limits as any other zone module, per
[server.md](server.md). A misbehaving AI module loses its turn and its bot flies
straight, which is embarrassing rather than fatal.

## External bots

The protocol path stays open. Tooling, league referees, and experimental AI
connect as ordinary clients with capability grants, exactly as the original's bot
ecosystem did. They are subject to the same rule as everything else: inputs only.

The in-process path exists because filler AI is a server feature with tight cost
constraints. It is not a replacement for the bot protocol, and both will exist.

## Testing

Bots are the load generator. The soak test in
[simulation-core.md](simulation-core.md) is forty bots for an hour with state
hash comparison, which exercises the simulation, the snapshot builder, the
persistence path, and the AI at once.

Bot-versus-bot tournaments calibrate the rating ladder before humans arrive, as
described in [design/rating.md](../design/rating.md).

## Open questions

Whether the coarse grid is enough for maps with tight tunnels, or whether some
maps need authored navigation hints. The original's maps were built for humans
who learn a map over months, and some of them are cruel.

Whether perception at 10 Hz is too generous or too stingy. It is a difficulty
parameter as much as a performance one.

How expensive a WASM-sandboxed controller is per bot per decision, and therefore
whether zone-authored AI can run at the same density as built-in AI.
