# Goals and constraints

## What we are building

A top-down space MMO with Subspace Continuum's feel: frictionless inertial
flight, energy serving as health and ammunition at once, eight ship classes
whose statistics live in configuration, teams called freqs, and arenas that can
host genuinely different games without an engine fork.

Inspired by, not a remake. The simulation model is inherited; the ships, art,
sound, maps, and fiction are ours. [design/identity.md](../design/identity.md)
draws the line and [design/ships.md](../design/ships.md) names the roster.

The target experience is a 40-player arena where the game stays readable and
fair on a connection that occasionally drops packets, and where a zone author
who has never compiled anything can build a game we did not anticipate.

## Non-negotiable

**Feel before fidelity.** Subspace's movement is the product: no drag, momentum
you fight rather than manage, and a bounce off a wall that keeps most of your
speed. If a design choice makes the ship feel heavier or mushier, it is wrong,
whatever else it buys.

**Input to pixel under one frame locally.** The client predicts its own ship
immediately. Nothing about the network model may introduce a stall between
pressing thrust and seeing thrust.

**The server owns damage.** Subspace let the victim's client declare its own
death and name its killer. We read the code that does it (see
[protocol-and-simulation.md](../research/protocol-and-simulation.md)) and we are
not shipping that. Kills, damage, flag captures, and scores are server
decisions.

**Zones are content, not code.** A new game mode should be a configuration file,
a map, and at most a sandboxed module. If we find ourselves adding a C flag for
a zone's rule, the extension surface is wrong.

**The web is a first-class target.** A game with no installed base needs to be
one link away. Anything that cannot run in a browser tab cannot be on the
critical path. Desktop through Steam follows, then mobile, then consoles if
they earn their certification cost. [platforms.md](platforms.md) has the
ordering and what each target extracts from us.

**No borrowed assets.** Not one sprite, sound, map, or name from Subspace or
Continuum, including as a placeholder in a prototype. This is not a constraint
we expect to feel, since our art direction is nothing like theirs, but it is
absolute.

## What we will trade away

**Continuum protocol compatibility.** Keeping the original wire format would let
existing Continuum clients connect on day one, which is a real shortcut to
having anybody to play against. It also locks us to `i16` pixel coordinates, a
1024x1024 tile world, eight ship slots, 40 discrete headings, and a settings
struct with reserved padding bits. We are choosing our own protocol and treating
Continuum compatibility as a possible gateway experiment rather than a
requirement. This is the decision most likely to be revisited.

**Native module extensibility.** ASSS lets a zone load a `.so` with full access
to the process, and the manual is candid that such a module can crash or
deadlock the server. We want the extensibility and not the crashes, so zone
modules run sandboxed and pay for it in speed.

**Exact numeric compatibility with Subspace settings.** We will read the old
settings vocabulary because it is a good vocabulary, but we are not bound to
tenths-of-a-percent integer encodings on the wire.

## Constraints we did not choose

**Browsers cannot open UDP sockets.** A web client speaks WebSocket over TCP, so
the server has to serve two transports and the simulation has to tolerate the
head-of-line blocking that TCP brings. This shapes [networking.md](networking.md)
more than any other single fact.

**Defold runs Lua 5.1, with LuaJIT on most platforms but not all.** HTML5 builds
use plain Lua 5.1.4, and iOS forbids JIT. Any code whose speed matters cannot
live in Lua.

**Defold does not specify component update order** within a collection. Game
state spread across game object scripts would have no defined evaluation order,
so game state does not live there.

**Defold's build server compiles extension sources.** C and C++ compile
everywhere it targets, including WebAssembly. Other languages need prebuilt
static libraries per platform, which we would have to produce ourselves.

## Success criteria for the architecture

We will know the shape is right when:

1. The same simulation source produces identical state on a Linux server and in
   a browser tab, verified by hashing state at every tick over a recorded input
   trace.
2. A 40-player arena costs a single server core and stays under 30 KB/s
   downstream per player.
3. Adding a game mode touches configuration and one sandboxed module, with no
   change to the sim core.
4. A player on 250 ms with 5% loss is annoying to play against but not unfair,
   and the rules that make that true are configuration.

## Explicit non-goals

Not a persistent-world MMO with an economy and character progression. Sessions
are arenas, and the persistence surface is scores, bans, and identity.

Not 3D, not physics-engine-driven, and not a general engine. The simulation is
small on purpose.

Not a Continuum replacement. Existing zones have thirty years of investment and
we are not asking anyone to migrate.
