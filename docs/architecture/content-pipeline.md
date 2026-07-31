# Content and configuration

The research concluded that Subspace survived because a zone author could build
a different game without touching the engine. That claim only holds if the
configuration surface is wide, the map format is editable with real tools, and
neither requires our permission. This document is how we keep that true.

## Settings

An arena's settings are a struct the simulation reads. Everything a ship does
comes from it: thrust, top speed, rotation rate, energy, recharge, weapon
levels, fire costs and delays, special counts, prize weights, bounce factor,
flag rules, ball rules, spawn points, and radar behavior.

We take Subspace's vocabulary wholesale. The names are good, the semantics are
proven, and thirty years of zone configuration is written in them. A section per
concern, a section per ship, and roughly the same key names:

```ini
[Warbird]
MaximumSpeed = 4400
MaximumThrust = 26
MaximumRotation = 380
MaximumEnergy = 1500
MaximumRecharge = 550
BulletFireEnergy = 250
BulletFireDelay = 25
InitialGuns = 2

[Bomb]
BombDamageLevel = 750
BombExplodePixels = 80
ProximityDistance = 3

[Kill]
EnterDelay = 500
PointsPerKilledFlag = 100
```

The differences from the original are deliberate. Values are the units in
[simulation-core.md](simulation-core.md), which are Subspace's units where they
were sane and finer where they were not. The file is parsed by the server and
compiled to the binary struct, so the parser is not in the sim core and not in
the client. And the schema is data rather than a C struct with reserved padding,
so adding a setting does not break every client.

An importer reads an existing `arena.conf` plus its `svs/` includes and produces
our format. It is a test instrument, not a distribution path: importing a real
settings file and flying the result tells us whether we understood the physics.
The output stays on the developer's machine. Shipped zones use our own ships and
our own numbers, per [design/identity.md](../design/identity.md).

Settings reload without restarting the arena. Zone operators tune constantly.

## Maps

The world is 1024x1024 tiles at 16 pixels, matching Subspace so that existing
maps convert directly.

Our map format carries the tile grid, the tileset reference, spawn regions, and
named regions with attributes. Regions are Subspace's best late addition: an
arbitrary set of tiles with rules attached, such as no antiwarp, no weapons, no
flag drops, or an automatic warp on entry. They give a map author mechanical
control without a module.

A converter reads `.lvl`, including the extended format with its embedded region
data, and writes ours. It exists so we can test our collision and region code
against maps whose behavior is known. Like the settings importer, its output is
not content we ship: an existing zone's map belongs to that zone. Going the
other way is not planned.

Editing happens in Tiled, which Defold already integrates with, plus a small
plugin for region attributes. Building our own map editor is a trap; the
original community's editors existed because no general tool did the job in
1998, and now several do.

The client bakes a downsampled radar texture at load rather than shipping one,
since the tile grid is already there.

## Overlays

Continuum added LVZ files for visual objects and animations layered over the
map: banners, goal graphics, decorations, and toggleable elements a server can
switch at runtime. It is how zones got visual identity.

We need the capability and not the format. An overlay here is a list of sprites
with positions, layers, animation references, and an id the server can toggle,
authored alongside the map and delivered with it. Defold draws them as ordinary
sprites in a dedicated layer.

## Delivery

A client joining an arena needs its settings, its map, its overlays, and its
tileset. Downloading all of that on join is what Subspace did and it was slow
even on small maps.

Content is content-addressed and cached. The server sends hashes, the client
requests only what it lacks, and everything is served over HTTP rather than
through the game socket, which keeps a large transfer from competing with
gameplay traffic. Defold's HTTP support handles this on every platform including
the web build.

## Zone modules

A zone whose rules exceed configuration writes a module. See
[server.md](server.md) for the sandbox and the adviser pattern. The relevant
point for content authors is that the module ships in the zone directory next to
the maps and the settings, and is versioned with them.

## What a zone looks like on disk

```
myzone/
  zone.toml                    name, description, identity, listen ports
  arenas/
    pub/
      arena.toml               settings, or includes of shared files
      pub.map
      pub.overlay
    duel/
      arena.toml
  shared/
    ships/warbird.toml         ship definitions the arenas include
    tilesets/standard.png
  modules/
    warzone.wasm
    league.lua
  data/
    zone.db
```

The debt to ASSS's layout is obvious and intentional. It was a good layout, zone
operators already know it, and the parts we changed are the parts that were
1997 artifacts.

## Open questions

Whether TOML is right, or whether staying closer to INI would lower the barrier
for the people most likely to author zones.

How far the `.lvl` and `arena.conf` importers should go. Reading a real zone's
configuration is a strong correctness test, and it stops being one somewhere
short of full fidelity.

Whether tilesets should stay 16-pixel or whether the renderer should support
higher-resolution art on the same 16-pixel collision grid. The second is more
work and is probably what the game deserves visually.
