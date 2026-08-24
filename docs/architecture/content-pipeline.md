# Content and configuration

The engine should not need a release for every tuning or map change. Current
content has two shipped forms: TOML for a zone's rules and `.vwmap` for its
ground. Both live under the deployment catalog, are validated before use, and
reach arena processes through the directory.

## The catalog is the source

`catalog/catalog.toml` declares the zones a deployment serves. Each declared
zone has a directory under `catalog/zones/` containing its `zone.toml` and the
maps named by that file. The catalog is versioned as one artifact. See
[catalog.md](catalog.md) for the schema and [admin.md](admin.md) for the bounded
operator surface over it.

The reference deployment currently has one zone, `melee`, with a six-map
rotation. Its source is:

```
catalog/
  catalog.toml
  zones/melee/
    zone.toml
    drydock.recipe.toml
    drydock.metrics.json
    drydock.svg
    drydock.vwmap
    ... five more map sets
```

An arena process can also run standalone from a directory containing
`zone.toml`. That path is useful for local work and reloads valid settings while
the process runs. The fleet path is the catalog: directories distribute one
validated zone definition to interchangeable arena processes.

## Zone settings

`zone.toml` is the game. It names the mode and map rotation, room and team caps,
match timing, bot fill, lag policy, hull settings, kit ceilings, and weapon
tables. Host concerns such as listen addresses, certificates, and instance caps
belong to the process or catalog instead.

The Rust server parses TOML, starts from the compiled simulation baseline, and
applies the fields that are present. This makes a reload mean the file as it
stands, not every edit made since the process started. The resulting settings
struct is packed by the C core and sent to clients, so prediction uses the same
numbers as authority.

Hull flight and weapon tuning remain content. Collision footprints are a fixed
core contract shared by collision code and the fitted client art.

Weapons are content too. A zone can change a projectile, add-on step, cost, or
delay in `[[arena.weapons]]` without adding a rule to the client. The simulation
core still validates the final table and executes it.

There is no `arena.conf` importer in the current tree. The reference tuning was
translated and then changed through play and calibration. Historical
Subspace settings remain research material, not a second live configuration
format.

## Map files

A `.vwmap` carries a width, height, hash, and run-length encoded tile classes.
Tile classes describe behavior and semantic variants, not pictures. The client
turns those classes into vector geometry, while the simulation uses the same
bytes for collision, starts, goals, doors, wormholes, and safe ground.

Packing and unpacking live in the C core for the server, client extension, and
map tools. The admin editor has a small JavaScript codec for local files; every
save still passes through the server and the core's verifier. A map is sent
during join before the first snapshot, then sent again when a room rotates to a
different map.

The core's `sim_map_check` reports maps at hull scale: connected regions,
usable and stranded starts, open ground, and tiles a hull cannot reach.
`sim_map_playable` refuses a map with no named start, any stranded start, or
multiple hull-sized regions. Mapforge adds the match recipe's four starts per
side, route, and geometry requirements. The admin API applies the core verdict
and the editor displays its report.

## Authoring shipped maps

The six current match maps come from `vectorwake-server mapforge`. Each accepted
map keeps four files together:

- `.recipe.toml` is the design brief and pins the expected output hash.
- `.vwmap` is the packed room the game serves.
- `.metrics.json` records routes, cover, travel time, balance, and checks.
- `.svg` is the review image with the accepted route overlay.

Generate or verify one from the repository root:

```sh
cargo run --manifest-path server/Cargo.toml -- \
  mapforge generate catalog/zones/melee/drydock.recipe.toml /tmp/drydock.vwmap

cargo run --manifest-path server/Cargo.toml -- \
  mapforge verify catalog/zones/melee/drydock.recipe.toml \
  catalog/zones/melee/drydock.vwmap
```

The admin panel also contains a tile editor. It can draw a new map, import a
local `.vwmap`, load mapforge metrics for review, run the core's playability
check, save catalog maps, and edit a zone's rotation. Its canvas tools are the
editor for hand-built work; Tiled is not part of this pipeline.

## Conversion and provenance tools

Two older tools remain on purpose.

`sim/tools/lvl2vw.c` reads the original `.lvl` tile records and writes a
`.vwmap`. It exists for collision research and compatibility checks. Converted
maps are somebody else's authored content and are not shipped here.

`sim/tools/mapgen.c` owns the large reference arenas and the frozen
`--match` recipe path that reproduces the two maps preceding the current
rotation. Mapforge is the source for the six curated maps, but deleting the
older generator would delete that reproducible provenance.

## Delivery

Settings and maps travel over the game connection in dedicated messages before
snapshots begin. A room also broadcasts the new map when its rotation advances.
The core supplies separate packing bounds for settings, maps, ordinary network
snapshots, and a whole simulation state. Player and watcher snapshots stay
inside their 64 KiB transport contract. Full-state diagnostics and trusted
house bots on loopback use the slightly larger whole-state bound.

The current format has no tileset, overlay bundle, region metadata, HTTP asset
cache, or zone-module payload. Those were proposals in the original plan. Add
them when shipped content needs them, not as empty architecture around files
that do not exist.
