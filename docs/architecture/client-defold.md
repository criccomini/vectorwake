# The Defold client

## The division of labor

Defold draws, plays sound, reads input, and manages screens. The sim core moves
ships and decides collisions. The line between them is strict: no game rule is
implemented in Lua, and the sim core knows nothing about sprites.

This is not tidiness for its own sake. Defold's manual states that the order in
which component `update()` functions run within a collection is unspecified, so
game state distributed across game object scripts has no defined evaluation
order. Worse, LuaJIT is unavailable in HTML5 builds, which fall back to Lua
5.1.4, so a simulation written in Lua would be fastest on the platform that
needs it least. Putting state in one C struct sidesteps both problems.

## What Lua does

- Sample input and build the command sent to the server
- Call `sim.step()` for local prediction and reconciliation
- Drive the camera, the HUD, the radar, chat, and menus with Defold GUI
- Turn sim events into sounds, particles, and screen shake
- Manage connection state, arena joins, and the server browser

## Project layout

```
client/
  game.project
  main/
    main.collection            bootstrap, connection, screen routing
    loader.script
  arena/
    arena.collection           the playing screen
    arena.script               owns the sim handle and the frame loop
    ship_view.script           one per visible ship, presentation only
    camera.script
  render/
    vectorwake.render_script   custom render pipeline
    tiles/                     tilemap window chunks
  gui/
    hud.gui, radar.gui, chat.gui, statbox.gui, menu.gui
  ext/
    simcore/                   native extension wrapping sim/
      ext.manifest
      src/sim_ext.c            Lua bindings
      include/ -> ../../../sim/include
  net/
    transport.lua              UDP on native, WebSocket on web
    protocol.lua               encode and decode
    prediction.lua             rollback and reconciliation
```

The extension under `ext/simcore` is a thin binding layer. It exposes a handful
of functions to Lua and does no game logic:

```lua
local h = sim.create(settings_blob, map_blob)
sim.step(h, input)                    -- advance one tick
sim.apply_snapshot(h, snapshot_blob)  -- authoritative correction
sim.replay(h, from_tick, inputs)      -- rollback and re-simulate
local ships = sim.ships(h)            -- read-only view for rendering
local ev = sim.events(h)              -- events since last drain
```

Defold's build server compiles this for every target it supports, including
WebAssembly, which is the mechanism that lets the browser build run the same
simulation as the dedicated server.

## The frame loop

Rendering is decoupled from simulation. The arena script accumulates real time
and steps the sim at a fixed 100 Hz, then renders at whatever the display gives
us, interpolating between the two most recent states.

Defold offers `fixed_update()` with `engine.fixed_update_frequency`, which looks
like a natural fit. We do not use it for the simulation, because it is tied to
the physics timestep and to the component lifecycle, and because we want the
accumulator under our control for prediction and rollback. We drive stepping
from a single script's `update()` instead. Defold's physics is disabled
entirely; collision is the sim core's job.

Two details that matter in practice. `engine.max_time_step` should be set so a
long stall does not produce a hundred catch-up steps in one frame. And after a
tab regains focus in a browser, we clamp catch-up and request a fresh snapshot
rather than simulating through the gap.

## Prediction and reconciliation

The client predicts only its own ship. Remote players are interpolated between
authoritative snapshots, delayed by a small buffer so packet jitter does not
show as stutter.

Each input frame carries a sequence number and the tick it applies to. The
client keeps its recent inputs. When a snapshot arrives for tick T, the client
compares its stored prediction for T against the authority. On a match it drops
history up to T. On a mismatch it resets its ship to the authoritative value and
replays every input after T, which at 100 Hz and 250 ms of history is at most 25
steps of one ship, cheap enough to do inside a frame.

Weapons are shown immediately on fire and resolved by the server. The visual
projectile is prediction; the damage is not. When the server disagrees, the
projectile disappears and no damage was ever applied locally, so there is
nothing to roll back on the receiving end. This is the deliberate inversion of
Subspace's model, where the victim's client decided.

## Rendering a 16384-pixel world

The map is 1024x1024 tiles. Painting that into a single Defold tilemap component
is not something we should assume works, so the plan is a moving window.

Keep a tilemap sized to the viewport plus a margin, roughly 64x48 tiles. As the
camera crosses a tile boundary, rewrite the newly exposed row or column with
`tilemap.set_tile`. The cost per frame is bounded by the perimeter rather than
by map size, and memory is constant.

The alternative is a custom render script that draws tiles from an atlas
directly, which gives more control and costs us Defold's tooling. Start with the
window, measure, and only write the custom path if the window fails. This is
flagged as an open question rather than a decision.

Radar is a separate concern: it needs the whole map at low resolution, so we
bake a downsampled texture at map load and draw player blips over it.

Ships, projectiles, and effects are ordinary Defold sprites, pooled through
factories. Note `collection.max_instances` defaults to 1024, and a busy arena
with 40 ships and hundreds of live projectiles will exceed that if every
projectile is a game object. Projectiles are therefore drawn from the sim
state's array, not spawned as objects, which also keeps them exactly where the
simulation says they are.

## Presentation state versus simulation state

Ships have a `ship_view.script` for animation, exhaust, banners, and sound. It
reads from the sim view each frame and owns nothing. When a ship dies, the view
is recycled to a pool. Any state that would change the game belongs in the core,
and any state that only changes what you see belongs in the view. Bricks and
doors sit right on that line: their existence is simulation, their animation is
presentation.

## Platforms

Desktop first for development, because that is where we can attach a debugger to
the extension. The web build is the distribution channel and needs to work from
the first milestone, since a link is the whole marketing plan. Mobile is
plausible later given that nullspace ships an Android client, but touch controls
for a game about precise thrust are a design problem we are not solving yet.

## Open questions

Whether the tilemap window holds up at 60 fps while the camera moves fast, or
whether we need the custom tile renderer.

How large the WASM bundle gets with the sim core included, and whether the
HTML5 build's Lua 5.1.4 costs enough in the non-simulation code to matter.

Whether Defold GUI is sufficient for the statbox and chat, which are dense and
text-heavy in a way Defold's GUI system is not obviously built for.
