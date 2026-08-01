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

## Two things worth knowing

The simulation steps at 100 Hz under the arena script's own accumulator
rather than Defold's `fixed_update`. Prediction and rollback want that clock,
and Defold's physics is disabled entirely: collision is the core's job.

`websocket/` is vendored rather than declared as a dependency, because
Defold resolves dependencies from GitHub archive URLs and those are blocked
here while `git clone` is not. It sits at `client/websocket` and not under
`ext/` because its manifest hardcodes `upload/websocket/include/wslay`;
moving it breaks the include path on the build server.

Ships, walls, weapons, and flags are drawn as lines through `draw_debug3d`.
That is not a placeholder. The clean vector direction in
`docs/design/identity.md` asks for exactly this, and it costs no atlas, no
material, and almost no bundle.
