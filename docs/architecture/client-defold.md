# The Defold client

## The division of labor

Defold draws, reads input, and manages screens. The sim core moves ships and
decides collisions. The line between them is strict: no game rule is implemented
in Lua, and the sim core knows nothing about how anything looks.

This is not tidiness for its own sake. Defold's manual states that the order in
which component `update()` functions run within a collection is unspecified, so
game state distributed across game object scripts has no defined evaluation
order. Worse, LuaJIT is unavailable in HTML5 builds, which fall back to Lua
5.1.4, so a simulation written in Lua would be fastest on the platform that needs
it least. Putting state in one C struct sidesteps both problems.

Sound is the one place the division is not clean, and deliberately. Defold's
mixer plays the held sounds, but on the web the one-shots go straight to the
browser's audio graph, because the mixer queues four buffers ahead and a gun that
answers a keypress cannot afford them. See [design/audio.md](../design/audio.md).

## What Lua does

- Sample input and build the command sent to the server
- Call `sim.step` for local prediction, and `sim.replay` for reconciliation
- Build the geometry for every layer, the HUD, the radar and the menus
- Turn sim events into sounds, sparks and screen shake
- Manage connection state, arena joins, and the games list

## The shape of it

The file layout, and what each piece is, is in
[client/README.md](../../client/README.md), kept there because that is where
somebody changing it will be looking. The parts worth knowing at this level:

One script owns the frame loop. `arena/arena.script` reads input, drives the
accumulator, steps the core and draws. There is no script per ship and no script
per screen, because component update order inside a collection is unspecified and
one loop has an order by construction.

The native extension under `ext/simcore` is a binding layer with no game logic in
it. The core keeps its state in file-scope structs rather than handing out a
handle, so Lua asks about a ship by index:

```lua
sim.init(seed)                  -- build the arena, settings and state
sim.step(buttons_by_ship)       -- advance one tick
sim.replay(me, buttons)         -- advance one tick, only this ship steering
sim.apply_snapshot(bytes)       -- the server's word, decoded by the core
sim.ship_x(i), sim.ship_heading(i), sim.ship_energy(i)   -- read-only views
sim.event_at(n)                 -- what happened this tick
```

The same extension carries the vertex writer and the sound kit, for the same
reason in both cases: a Lua loop that crosses into C per float, or per sample, is
the cost that actually shows up on the web.

Defold's build server compiles all of it for every target including WebAssembly,
which is the mechanism that lets a browser tab run the same simulation as the
dedicated server.

## The frame loop

Rendering is decoupled from simulation. The arena script accumulates real time
and steps the core at a fixed 100 Hz, then draws at whatever the display gives
us.

Defold offers `fixed_update()` with `engine.fixed_update_frequency`, which looks
like a natural fit. We do not use it for the simulation, because it is tied to
the physics timestep and to the component lifecycle, and because prediction and
rollback want the accumulator under our control. Defold's physics is disabled
entirely; collision is the sim core's job.

Catch-up is capped per frame, so a long stall does not produce a hundred steps at
once. A backgrounded browser tab is the common case for that cap, since the
browser throttles the frame callback the loop is driven from.

## Prediction and reconciliation

The client predicts its own ship and coasts everybody else in the same core.
All hulls and rounds stay on that collision-aware timeline. The renderer
interpolates adjacent simulation ticks and eases snapshot corrections; it does
not move objects backward by subtracting their velocity, because that would
discard wall and collision history.

Inputs are stamped with the tick they apply to and kept. Every datagram repeats
up to four recent states. A snapshot carries the newest tick the server has
received from this client, while the snapshot body names the state tick. On
arrival the client accepts the state wholesale and replays its own inputs from
the state tick forward.
The replay is one ship's buttons over a handful of ticks, which is cheap enough
to do inside a frame.

The first snapshot seeds eight ticks of prediction lead. Later snapshots do not
change the replay horizon. If input margin stays outside its dead band for a
full second, the fixed-step accumulator runs at 99% or 101% until it recovers.
An input that arrives early waits in the server's queue and is applied on the
tick the client applied it, so both ends agree and there is nothing to correct.

Prediction runs the whole core, so the client shows its own hits and deaths
immediately and those events drive the sparks and the sound. None of it is
authoritative. Every snapshot overwrites the lot, and the server decides who
died. This is the deliberate inversion of Subspace's model, where the victim's
client decided.

The transport is a WebSocket everywhere, including native builds, rather than UDP
on native and WebSocket on the web. One protocol, one code path, and the browser
is the platform that matters most.

## Drawing a 16384-pixel world

Nothing is a sprite. The client draws vector geometry into five mesh components,
built fresh each frame in Lua and uploaded once each: two static layers for
terrain, then fill, glow and interface. `render/vec.lua` builds the shapes and
the extension's vertex writer does the writing, so a triangle costs one crossing
into C rather than twenty-one.

Terrain is a window rather than the whole map. A 1024-tile map is meshed for the
tiles around the camera, sized from the drawable and rebuilt when the camera
walks far enough, so the cost tracks the view rather than the map. The window is
meshed whole and held whole, which is why its capacity is fitted to what a build
actually used rather than guessed at.

The fill and glow layers follow the window too, and for the same reason the
terrain does. The camera holds a fixed zoom, so a wider window sees more world
and therefore more starfield, and most of what those two layers carry is
starfield. Their capacity is computed from the view's half-extents against the
table the stars are drawn from, so the budget cannot drift from the drawing. A
fixed capacity is the wrong shape here in a way that hides itself: a layer past
its cap does not raise, it stops writing, so the geometry described after the
overflow is simply absent from the frame. That is what a fixed 6144 vertices
did on a monitor around 2240 points wide, where the two far depths of the
starfield filled the buffer on their own and the near stars came and went
depending on how much of the field was behind rock. Both layers now report
their fill and their refusals in the debug readout, so the next one of these is
a number somebody can read rather than an artifact somebody has to explain.

Projectiles are drawn straight from the core's arrays rather than spawned as
objects, which keeps them exactly where the simulation says they are and avoids
the instance ceiling entirely.

The radar samples the map's own grid, anchored to it rather than to the terrain
window, so the blips do not re-roll every time the window moves.

Text is the one thing Defold's GUI draws, in a single component with no widgets
in it.

## Presentation state versus simulation state

Any state that would change the game belongs in the core, and any state that only
changes what you see belongs in the client. The client holds a few things of its
own: which charge the use key would spend, the bank angle a hull is drawn at, the
kill feed, and the terrain window's extent. None of it is in a snapshot and none
of it is in the core.

Bricks and doors sit right on that line: their existence is simulation, their
animation is presentation.

## Platforms

The web build is the distribution channel and the one that has to work, since a
link is the whole marketing plan. Desktop builds are how the client gets
debugged, and how it is photographed under a virtual display. Touch is
implemented rather than deferred: a drawn thumbstick that asks for a course, and
a row of weapon pads.
