# vectorwake Defold client

The production client. It draws the game and reads input; it owns no game
rule, because the rules live in `sim/` and this links them as a native
extension.

## Building

```sh
JAVA_HOME=/path/to/jdk25 ./client/build.sh              # this host
JAVA_HOME=/path/to/jdk25 ./client/build.sh js-web       # the browser
```

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
| `render/` | Fixed world extent per decision 13; line geometry, no atlas |
| `main/` | Bootstrap collection and input bindings |

## Two things worth knowing

The simulation steps at 100 Hz under the arena script's own accumulator
rather than Defold's `fixed_update`. Prediction and rollback want that clock,
and Defold's physics is disabled entirely: collision is the core's job.

Ships, walls, weapons, and flags are drawn as lines through `draw_debug3d`.
That is not a placeholder. The clean vector direction in
`docs/design/identity.md` asks for exactly this, and it costs no atlas, no
material, and almost no bundle.
