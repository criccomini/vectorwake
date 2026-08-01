# vectorwake Defold client

The production client. It draws the game and reads input; it owns no game
rule, because the rules live in `sim/` and this links them as a native
extension.

## Building

```sh
JAVA_HOME=/path/to/jdk25 ./client/build.sh              # this host
JAVA_HOME=/path/to/jdk25 ./client/build.sh wasm-web     # the browser
```

Platform names are bob's. The browser target is `wasm-web`; `js-web` is
rejected outright.

The third argument picks the bob task. `headless` has no renderer at all —
it is what verifies determinism and networking from a terminal, and it draws
nothing in a browser. To get something playable:

```sh
./client/build.sh wasm-web debug bundle
./client/tools/single_file.py client/bundle/wasm-web/vectorwake play.html
```

`single_file.py` folds the engine, the archive and the loader into one HTML
with no network requests, so it runs from a static host, under a strict CSP,
or straight off a disk.

Needs `bob.jar` (set `BOB_JAR`, defaults to `/tmp/bob.jar`) and a JDK new
enough to run it: 1.13.0 wants Java 25. Native extensions are compiled by
Defold's build server, so the build needs network access.

`build.sh` copies the simulation core into `ext/simcore/` before building.
Defold uploads an extension's directory to its build server and a symlink
does not survive that trip, so the copies are refreshed every run and git
ignores them. There is one copy of the rules in this repository and it is
in `sim/`.

## Shape

| Path | What it is |
|---|---|
| `ext/simcore/` | The native extension: a Lua binding over the C core, no rules |
| `arena/arena.script` | The frame loop: input, stepping, drawing |
| `arena/net.lua` | Connect, predict, reconcile. Decides nothing |
| `arena/touch.lua` | Thumbstick and weapon pads; emits the same button bits |
| `arena/browser.lua` | The server browser, over the directory protocol |
| `tools/single_file.py` | Folds a bundle into one self-contained page |
| `render/` | Fixed world extent per decision 13; line geometry, no atlas |
| `main/` | Bootstrap collection and input bindings |
| `websocket/` | Vendored `defold-websocket`, at this path deliberately |

## Playing against a server

With no `server` set the client runs the whole game locally against bots, so
a build with nothing behind it is still playable. Point it at a zone and the
server owns the arena instead:

```sh
./server/target/release/vectorwake-server 127.0.0.1:9040 zone
./client/build/x86_64-linux/dmengine \
  --config=vectorwake.server=ws://127.0.0.1:9040 \
  client/build/default/game.projectc
```

`--config` overrides work for any key, which beats rebuilding to change one.

Online, `net.lua` sends buttons, predicts this ship forward from the last
snapshot, and accepts every correction. It decides no hit, no death, no
pickup. Snapshots are decoded by the core's own `sim_unpack`, so client and
server cannot disagree about what a snapshot means.

The online path still calls `sim.init` before connecting. A snapshot carries
state, not rules, and prediction runs collision locally between snapshots —
so the map and settings have to exist first. Skipping that was a segfault,
not a subtle desync.

## Finding a game

With `directory` set, the client opens a server browser at startup: it asks
the directory what is running and lets the player pick. Up and down move,
enter joins, escape plays offline instead.

```sh
./server/target/release/vectorwake-server directory 127.0.0.1:9000 zone
./client/build/x86_64-linux/dmengine \
  --config=vectorwake.directory=ws://127.0.0.1:9000 \
  client/build/default/game.projectc
```

A `server` address skips the browser and connects straight there. Neither
set plays the local game, which is what keeps a build with nothing behind it
playable.

## Two things worth knowing

The simulation steps at 100 Hz under the arena script's own accumulator
rather than Defold's `fixed_update`. Prediction and rollback want that clock,
and Defold's physics is disabled entirely: collision is the core's job.

`websocket/` is vendored rather than declared as a dependency, because
Defold resolves dependencies from GitHub archive URLs and those are blocked
here while `git clone` is not. It sits at `client/websocket` and not under
`ext/` because its manifest hardcodes `upload/websocket/include/wslay`;
moving it breaks the include path on the build server.

Ships, walls, weapons, and flags are drawn as lines through `draw_debug3d`,
which matches the clean vector direction in `docs/design/identity.md` and
costs no atlas and no material.

**It cannot ship as it stands.** Defold's `release` variant compiles the
debug renderer out, so a release build draws an empty arena while `debug`
and `headless` builds are correct. Verified both natively and in the
browser. Before any release build, the line art has to become real geometry:
a mesh component with a dynamic vertex buffer and a material of our own.
Until then `build.sh wasm-web debug bundle` is the playable target.
