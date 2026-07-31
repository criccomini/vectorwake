# The simulation core

Everything that decides what happens in the game lives in one C99 library with
no dependencies beyond the standard library. The client links it as a Defold
native extension, the server links it as a static library, and the web build
compiles it to WebAssembly through Defold's build server. One source, three
binaries, identical results.

## Why C, and why this shape

The core has to run in three places: inside a Defold native extension, inside a
server process, and inside a browser as WebAssembly. Defold's build server
compiles extension sources for every platform it targets, and C and C++ are
what it compiles. A Rust core is possible through prebuilt static libraries per
platform, but we would own that build matrix, including the WASM target. That
cost buys memory safety in a module with no allocation, no parsing, and no
untrusted input, which is the wrong place to spend it. See
[decision 3](decisions.md).

The shape matters as much as the language. The core is a pure function:

```c
void sim_step(sim_state *next, const sim_state *prev,
              const sim_input *inputs, uint16_t input_count,
              const sim_settings *settings, sim_events *out);
```

No globals, no callbacks into the host, no time source, no logging, no
allocation. Everything the step needs arrives as an argument. That makes rollback
a memcpy, makes an arena a value a thread can own, and makes the determinism
tests trivial to write.

## Determinism through fixed point

The core uses no floating point. Positions, velocities, and energies are
integers with documented scales, following Subspace's own encoding closely
enough that old settings files convert without interpretation:

| Quantity | Representation | Note |
|---|---|---|
| Time | `uint32_t` ticks | 100 Hz, so one tick is 10 ms |
| Position | `int32_t`, 1/256 pixel | 16 px per tile, 1024 tiles gives 16384 px, so a Q8 fraction fits with room |
| Velocity | `int32_t`, 1/256 px per tick | Subspace's px/s/10 converts exactly |
| Heading | `uint16_t`, 1/65536 turn | Rendering quantizes to 40 sprite frames; the sim does not |
| Energy | `int32_t`, 1/1000 units | Cloak and stealth costs are thousandths per tick already |
| Angles in settings | Same scale as Subspace | 111 is one degree |

Two choices are worth defending. Heading is stored at full precision rather than
in Subspace's 40 steps, because 40 steps is a sprite-sheet artifact and coarse
turning feels bad on a modern display. Sprites still snap to 40 frames, so it
looks the same.

Position carries a 1/256 sub-pixel fraction so that low thrust accumulates
instead of rounding to zero. Subspace hid this in a client-side accumulator; we
put it in the state.

Fixed point costs us convenience and buys three things: the client and server
agree bit for bit so a desync is detectable rather than a matter of tolerance,
replays reproduce exactly from an input log, and rollback compares with `memcmp`
instead of an epsilon.

## The step

Each tick, in this order:

1. Apply inputs. Rotation, thrust, afterburner drain, weapon fire requests,
   special activation.
2. Integrate motion. Velocity gains thrust along the heading, clamps to the
   ship's maximum, and position gains velocity. There is no drag term anywhere.
3. Resolve collisions against the tile grid. A ship that hits a wall reflects
   with speed scaled by the arena's bounce factor, where 16/16 means no loss.
4. Advance projectiles, including bounces, proximity triggers, mine arming, and
   lifetime expiry.
5. Resolve damage. Every hit is decided here and nowhere else.
6. Recharge energy, tick down timers, expire bricks and decoys, and settle
   region effects.
7. Emit events. Fired, bounced, hit, killed, prized, flag taken, goal scored.

Events are the core's only output besides the next state. The server turns them
into packets, scores, and module callbacks; the client turns them into sounds
and particles. Nothing outside the core interprets game rules.

## Collision against tiles

The map is a 1024x1024 grid of 16-pixel tiles. Collision is a swept test against
the grid rather than a physics engine: step along the movement vector in tile
increments, stop at the first solid tile, reflect the component that hit.

This is cheap, exact in fixed point, and reproduces Subspace's characteristic
wall-hugging behavior, where you can hold thrust into a wall and slide along it.
A general physics engine would give us friction, resting contacts, and rotation
we do not want, and would cost determinism across platforms.

## State layout

`sim_state` is a flat struct of arrays sized to the arena's configured maximums,
with no pointers, so copying it is a `memcpy` and hashing it is one pass:

```c
typedef struct {
    uint32_t tick;
    uint32_t rng;                       // deterministic PRNG state
    sim_ship ships[SIM_MAX_SHIPS];      // 256
    sim_weapon weapons[SIM_MAX_WEAPONS];// 2048
    sim_flag flags[SIM_MAX_FLAGS];      // 256
    sim_ball balls[SIM_MAX_BALLS];      // 8
    sim_brick bricks[SIM_MAX_BRICKS];   // 256
    uint8_t ship_count, ...;
} sim_state;
```

The measured size matters because rollback keeps a ring of recent states on the
client. At a few hundred kilobytes per state, one second of history at 100 Hz is
tens of megabytes, which is too much. Two answers, in order of preference: keep
the ring at 250 ms, and store only the local ship plus a hash for older ticks,
replaying remote players from the last authoritative snapshot rather than from
local history. The client only ever rolls back its own ship.

Randomness comes from an explicit PRNG in the state, seeded per arena and
advanced only inside `sim_step`. Prize rolls, shrapnel spread, and spawn
selection are therefore reproducible, and the client can predict them.

## What the core does not do

No networking, no serialization of its own, no file access, no strings, no
settings parsing. Settings arrive as a filled struct; whoever loaded the INI is
somebody else's problem. This keeps the WASM build small and the test harness
honest.

## Testing

Three layers, all cheap because the core is a pure function.

Unit tests for movement, collision, and damage, written as input traces with
expected state hashes.

A determinism harness that replays a recorded input log on Linux x86-64, Linux
arm64, and WebAssembly, hashing state every tick and failing on the first
divergent tick. This runs in CI on every commit, because a determinism
regression that ships is a desync bug we will chase for weeks.

A soak test that runs a 40-player arena of scripted bots for an hour and asserts
no state hash divergence between two instances fed identical inputs.

## Open questions

How large `sim_state` actually is once weapons and bricks are real, and whether
the rollback strategy above survives contact with that number.

Whether the tile collision sweep is fast enough at 2048 live projectiles per
arena, or whether projectiles need a coarse grid index. Measure before building
one.

Whether 100 Hz is necessary. It matches the settings vocabulary and makes
weapon delays exact, but 50 Hz halves the server cost. The answer probably
depends on whether bullet-versus-ship collision at high speed produces
tunnelling at 50 Hz, which the swept test should prevent.
