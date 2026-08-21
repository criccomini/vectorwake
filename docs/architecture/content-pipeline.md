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
our format. Importing a real settings file and flying the result is how we
found out whether we had understood the physics, and it is how Alpha's tuning
started: as a translation, one value at a time.

What comes out of it is a starting point rather than a shipped zone, and the
difference is what happens next. Alpha's tech tree was priced by win rate over
thousands of simulated matches, its proximity fuse rebuilt after measuring it,
its thrust and gun ladder changed because somebody flew them, and a hull
dropped. Ship names and the map were never the importer's to give.
[design/identity.md](../design/identity.md) draws the line: the numbers are the
system and we inherit those deliberately, the files are somebody's work and we
do not ship them.

Settings reload without restarting the arena. Zone operators tune constantly.

## Maps

The world is 1024x1024 tiles at 16 pixels, matching Subspace so that existing
maps convert directly.

Our map format carries the tile grid, the tileset reference, spawn regions, and
named regions with attributes. Regions are Subspace's best late addition: an
arbitrary set of tiles with rules attached, such as no antiwarp, no weapons, no
flag drops, or an automatic warp on entry. They give a map author mechanical
control without a module.

A converter reads `.lvl` and writes ours. It exists so we can test our collision
code against maps whose behavior is known. Like the settings importer, its
output is not content we ship: a converted map from an existing zone is that
zone's map, and being handed the file does not change that. Shipped maps are
drawn by `sim/tools/mapgen`, which builds from the measurements in
[research/map-measurements.md](../research/map-measurements.md) rather than
from anybody's geometry. Going the other way is not planned.

```sh
make -C sim build/lvl2vw
sim/build/lvl2vw somemap.lvl catalog/zones/somezone/somezone.vwmap [starts]
```

It is `sim/tools/lvl2vw.c`, and it reads the plain tile records only.
[research/lvl-format.md](../research/lvl-format.md) has the format it walks and
the type numbers it translates. The eLVL metadata section is reported and
skipped: none of the maps we have carry any, and regions are not something the
core does yet.

Two things the input cannot supply. A `.lvl` has no starts, because the
original kept spawn regions in `arena.conf`, so the converter derives them from
open ground and splits them north and south into two home ends. And the tileset
is dropped, because a tile here is its behavior: the 160 wall pictures become
one class, and what a wall looks like is the client's business.

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

## What is built, and what it looks like

The plan above is the destination. What exists is `zone/zone.toml`: one file,
re-read while running, carrying the arena's scalars, its kit ceilings, each
hull's footprint, and the weapon tables by name under `[[arena.weapons]]`,
documented in [design/weapons.md](../design/weapons.md). Applying it rebuilds from the
baseline first, so the arena means the file as it stands rather than every
version of it since boot.

Weapons being *in* that file is the load-bearing part of zones-are-content.
A weapon is two table rows, so a zone that wants bouncing bombs or a repel
edits a file rather than waiting for a release, and the tables travel to every
client in the room on save.

## Delivery

A client joining an arena needs its settings, its map, its overlays, and its
tileset. Downloading all of that on join is what Subspace did and it was slow
even on small maps.

Settings and maps are built and travel over the game socket, packed by the
core (`sim_settings_pack`, `sim_map_pack`) -- about 1.2 KB and a few hundred
bytes respectively, which is small enough that content-addressing them would
be machinery for nothing. Overlays and tilesets are the part that will need
the scheme below.

A map's size is really a property of how detailed it is, and the built-in rooms
are not detailed. The run-length encoding gives up when structure is everywhere:
the five converted Subspace maps pack to between 63 and 84 KB, which is still
one transfer at join and not worth a cache, but it is two orders of magnitude
off the figure above.

Content is content-addressed and cached. The server sends hashes, the client
requests only what it lacks, and everything is served over HTTP rather than
through the game socket, which keeps a large transfer from competing with
gameplay traffic. Defold's HTTP support handles this on every platform including
the web build.

## Zone modules

A zone whose rules exceed configuration writes a module. See
[server.md](server.md) for the sandbox and the adviser pattern. The relevant
point for content authors is that the module ships in the catalog next to the maps
and the settings, and is versioned with them.

## What the content looks like on disk

Every zone a deployment serves lives in one catalog, authored in one place,
versioned as a unit, and handed to arena servers over the registration socket
rather than read off the serving machine's own disk. The layout and every field
in it are [catalog.md](catalog.md); this document is about how a zone author
works, not about the schema, and repeating the schema here would only give it two
places to drift.

Two things about it belong to authoring rather than to structure.

`zone.toml` keeps its name and loses its second job. It always described a game,
so what left it is the part that described a host: the listen address, the TLS
paths, the player cap. An author edits games; an operator sizes machines.

And an arena server holds almost nothing of its own. Its config names the
directories it registers with, where to read each token, its region, and which
zones it is willing to serve. Everything a game consists of arrives over the
socket as the same packed bytes a client gets at join, which means an author never
deploys to a serving host at all: they publish a catalog version and the fleet
picks it up.

The debt to ASSS's layout is still obvious and still intentional. What moved is
the ownership. ASSS put the game on the disk of the machine serving it, and a
fleet that scales by replica count cannot.

## Open questions

Whether TOML is right, or whether staying closer to INI would lower the barrier
for the people most likely to author zones.

How far the `.lvl` and `arena.conf` importers should go. Reading a real zone's
configuration is a strong correctness test, and it stops being one somewhere
short of full fidelity.

Whether tilesets should stay 16-pixel or whether the renderer should support
higher-resolution art on the same 16-pixel collision grid. The second is more
work and is probably what the game deserves visually.
