<img src="docs/banner.svg" alt="vectorwake" width="100%">

[![play in browser](https://img.shields.io/badge/play-in_browser-0e6d85?style=flat-square&labelColor=05070c)](https://play.vectorwake.net)
[![discord](https://img.shields.io/discord/1536450325236687030?style=flat-square&labelColor=05070c&logo=discord&logoColor=white&label=discord&color=5865F2)](https://vectorwake.net/discord)
[![ai: auto](https://img.shields.io/badge/ai-auto-33404d?style=flat-square&labelColor=05070c)](AI-DECLARATION.md)

vectorwake is a top-down space MMO built around frictionless, inertial combat. Energy is both health and ammunition. Pilots fight over flags in rooms whose physics, weapons, and rules come from configuration.

The physics model is inspired by [Subspace Continuum](https://store.steampowered.com/app/352700/Subspace_Continuum/). vectorwake has its own ships, art, sounds, maps, names, interface, and so on.

The browser client and live fleet work today. They include seven hulls, keyboard and touch controls, AI pilots, configurable rooms, accounts, and ratings. The game is still under active development and does not preserve backward compatibility.

## How it works

The **simulation core** has no floats, I/O, or runtime dependencies. The client runs it for prediction; the server runs it to decide positions, hits, deaths, and scoring. Snapshots are packed by the core itself, so the two sides share both the rules and the wire representation.

The **client** draws the world as vector geometry across five mesh layers. Ships and weapons are readable by silhouette, color, and motion rather than by copied sprites. The client also synthesizes its short combat sounds from code.

Zone authors configure maps, ship tuning, weapons, modes, and room limits without forking the **arena server**. The servers themselves are disposable workers that can serve any zone in a catalog. Bots connect through the same protocol as human players and send the same input bits.

## Quick start

You need a C99 compiler, Make, and a Rust toolchain with Cargo for the simulation and server.

Run the deterministic core checks and the server tests from the repository root:

```sh
make -C sim check
cargo test --manifest-path server/Cargo.toml
```

Start one standalone arena on `ws://127.0.0.1:9010`:

```sh
cargo run --release --manifest-path server/Cargo.toml -- 127.0.0.1:9010 zone
```

That command loads [`zone/zone.toml`](zone/zone.toml). Most settings reload when you save the file. A bad edit is logged and ignored instead of taking the room down.

### Run a native client against the arena

The client build needs JDK 25 and Defold Bob 1.13.0. Native extensions are compiled by Defold's build service, so this step needs network access.

```sh
curl -fsSL -o /tmp/bob.jar \
  https://github.com/defold/defold/releases/download/1.13.0/bob.jar

VW_PLATFORM=x86_64-linux
JAVA_HOME=/path/to/jdk25 ./client/build.sh "$VW_PLATFORM" release build
./client/build/"$VW_PLATFORM"/dmengine \
  --config=vectorwake.server=ws://127.0.0.1:9010 \
  client/build/default/game.projectc
```

Replace `x86_64-linux` with the Bob target for your machine. [`client/README.md`](client/README.md) covers browser bundles, directory-based discovery, runtime overrides, and client testing.

### Build the browser client

```sh
JAVA_HOME=/path/to/jdk25 ./client/build.sh wasm-web release bundle
python3 client/tools/single_file.py \
  client/bundle/wasm-web/vectorwake vectorwake.html
```

The result is one self-contained HTML file. By default it opens the official games directory. CI builds and publishes the production page whenever `client/` or `sim/` changes; generated bundles are not committed.

## Repository guide

| Path | What lives there |
|---|---|
| [`sim/`](sim/) | Dependency-free C99 simulation, packers, maps, tests, and golden trace |
| [`server/`](server/) | Rust arena, directory, bot process, meta-layer, rating, and fleet logic |
| [`client/`](client/) | Defold client, native extensions, Lua UI, vector renderer, audio, and tests |
| [`catalog/`](catalog/) | The zones served by a fleet |
| [`zone/`](zone/) | A documented standalone zone configuration |
| [`deploy/`](deploy/) | Docker Compose, Caddy, provisioning, and fleet update scripts |
| [`docs/`](docs/) | The game's design, the system's architecture, and the research behind both |

## Documentation

Start with [the game and its design](docs/design/README.md) if you want to understand what is being built. Read the [system overview](docs/architecture/system-overview.md) before changing a boundary between the client, core, and server. The [research notes](docs/research/README.md) preserve the source material and measurements behind the inherited mechanics.

For operating the full stack, read [deployment](docs/architecture/deployment.md). A production deployment includes Caddy, the directory, arena and bot processes, the meta-layer, and PostgreSQL.

## AI declaration

Fable, Opus, and Sol were used to create this codebase. I steered the design. See [`AI-DECLARATION.md`](AI-DECLARATION.md) for details.

## License

vectorwake is source-available under the [PolyForm Noncommercial License 1.0.0](LICENSE.md). It permits use, modification, and distribution for noncommercial purposes.
