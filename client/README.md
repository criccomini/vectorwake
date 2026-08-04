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
./client/build.sh wasm-web release bundle
./client/tools/single_file.py client/bundle/wasm-web/vectorwake play.html
```

`single_file.py` folds the engine, the archive and the loader into one HTML
with no network requests, so it runs from a static host, under a strict CSP,
or straight off a disk.

`--fragment` drops the document shell for hosts that supply their own, which
takes Defold's `<meta name="viewport">` with it -- so the fragment puts one
back from script. Without it a phone lays the page out at 980 css pixels and
scales the result down: the compact layout never triggers, and the interface
is sized for a display nobody is holding. It only bites the standalone file,
because inside an iframe the parent element sets the width, which is why it
went unnoticed -- the page is normally played in a frame.

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
| `ext/simcore/src/sfx.c` | The synth: every sound in the game, from arithmetic |
| `arena/arena.script` | The frame loop: input, stepping, drawing |
| `arena/net.lua` | Connect, predict, reconcile. Decides nothing |
| `arena/touch.lua` | Thumbstick and weapon pads; emits the same button bits |
| `arena/menu.lua` | The menu tree and the settings it saves |
| `arena/directory.lua` | Asks a directory what games are running |
| `tools/single_file.py` | Folds a bundle into one self-contained page |
| `tools/sfxdump.c` | Writes the kit out as wav files, for listening to |
| `tests/sfx_test.lua` | Which sound each weapon rung reaches |
| `tests/overview_test.lua` | The map view's rectangles, against the maps the fleet serves |
| `tools/shot.sh` | Runs the client on a virtual display and photographs it |
| `arena/world.lua` | Ships, weapons, flags, prizes, terrain, in triangles |
| `arena/ui.lua` | The HUD and the menu, laid out like the web prototype |
| `arena/fx.lua` | Blasts, sparks, shake. Triggered by events, decides nothing |
| `arena/sfx.lua` | Sound, with distance, pan and a per-frame budget |
| `render/vec.lua` | The geometry builder: segments, fans, discs, rings |
| `render/` | Fixed world extent per decision 13; materials and meshes |
| `ui/` | The text gui and its font |
| `sounds/` | Silent placeholders and the `.sound` components over them |
| `main/` | Bootstrap collection and input bindings |
| `websocket/` | Vendored `defold-websocket`, at this path deliberately |

## Playing with other people

`PLAY -> ZONES` asks the official directory what is running and lets the
player pick. The server owns the arena instead of this client, and there is no
way to type an address: a build is pointed at a directory with
`--config=vectorwake.directory=ws://...`, and a player only ever sees the list
it returns.

Nobody types a name. A call sign is generated on first run, kept in the
browser's save file so ratings have a stable identity to accumulate against,
and redrawn by tapping it. That is the whole of naming on a phone, and on a
console it is what we will replace with the platform's own name -- which is
what those platforms expect and what certification generally requires.

There is no text field left in this game at all. That is not tidiness: the
invisible DOM input an address box needs over a canvas, and the focus traded
between it and the engine, produced more defects than any other part of the
client -- a keystroke went to whichever of the two held the caret, and after
typing, the canvas never got the keyboard back.

Run one:

```sh
./server/target/release/vectorwake-server 0.0.0.0:9040 zone
```

Give it a `VW_DIRECTORY` and a `VW_TOKEN` so it registers, point the client at
that directory, and players pick it from `PLAY -> ZONES`. They appear in each
other's rosters, kill feeds, and radar, because online every name comes from
the server's roster rather than from the local one.

In a zone a player can change hull from `SHIP` without leaving: the client
sends `C2S_SHIP`, the server applies it through the core, and the next snapshot
brings back a different ship. Only alive and only at a full bar -- a fresh hull
is a fresh bar, and ungated that is an escape from a fight.

`LEAVE` is how you get out of one. It puts the menu back with nothing behind
it, which is the same state the client starts in.

A build can be pointed at a zone up front, which skips the menu entirely:

```sh
./client/build/x86_64-linux/dmengine \
  --config=vectorwake.server=ws://127.0.0.1:9040 \
  --config=vectorwake.name=alice \
  client/build/default/game.projectc
```

`--config` overrides work for any key, which beats rebuilding to change one.

A zone that cannot be reached puts the menu back on the games list with the
reason under it, and gives up after ten seconds if the socket opens but
nothing arrives. On the web a connection to a dead port can hang without ever
raising an error, so the timeout is the only thing that catches it.

One deployment rule, and it is a browser rule rather than ours: a page served
over `https` may only open `wss`. `ws://127.0.0.1` is the exception, because
browsers treat loopback as trustworthy, which is why the default address
works from a hosted page and `ws://<some other host>` will not. A zone that
strangers are meant to reach needs TLS in front of it.

Online, `net.lua` sends buttons, predicts this ship forward from the last
snapshot, and accepts every correction. It decides no hit, no death, no
pickup. Snapshots are decoded by the core's own `sim_unpack`, so client and
server cannot disagree about what a snapshot means.

The online path still calls `sim.init` before connecting. A snapshot carries
state, not rules, and prediction runs collision locally between snapshots —
so the map and settings have to exist first. Skipping that was a segfault,
not a subtle desync.

## Finding a game

The page opens on the menu, and `PLAY` is the list of games: the client asks
the configured directory what is running, at once on opening the list and every
three seconds after that for as long as it is on screen, so players joining and
leaving show up while somebody is choosing. Up and down move, enter joins. The
game you played last is marked and preselected. The address defaults to the
fleet's directory and is overridden per build.

```sh
./server/target/release/vectorwake-server directory 127.0.0.1:9000 zone
./client/build/x86_64-linux/dmengine \
  --config=vectorwake.directory=ws://127.0.0.1:9000 \
  client/build/default/game.projectc
```

A `server` address connects straight there at startup, which is how a test
pins a client to a zone. Without one the client opens on the menu and waits to
be told which game to join. There is no local game to fall back on: with no
directory and no zone, the client draws a starfield and a list of things it
cannot reach.

## Driving it from a test

Clicks have to be held. The engine polls the mouse once a frame, so a press
and release inside one frame reads as no press at all, and an instantaneous
`mouse.click()` under a software renderer -- where frames are long -- lands
that way every time. Move, wait, hold for ~90 ms, release:

```js
await p.mouse.move(x, y); await p.waitForTimeout(120);
await p.mouse.down(); await p.waitForTimeout(90); await p.mouse.up();
```

A hand cannot click faster than a frame at 60 Hz, so this is a property of
the harness rather than of the game. It cost an afternoon once: fast clicks
plus coordinates measured from a screenshot taken before a button was added
to the row looked exactly like a dead interface.

`release` strips `print`, so a test that reads the client's own log needs a
`debug` bundle. Anything checking whether a player actually reached a zone
should ask the server instead -- its status reports players and bots, and it
is the honest witness either way.

## Two things worth knowing

The simulation steps at 100 Hz under the arena script's own accumulator
rather than Defold's `fixed_update`. Prediction and rollback want that clock,
and Defold's physics is disabled entirely: collision is the core's job.

`websocket/` is vendored rather than declared as a dependency, because
Defold resolves dependencies from GitHub archive URLs and those are blocked
here while `git clone` is not. It sits at `client/websocket` and not under
`ext/` because its manifest hardcodes `upload/websocket/include/wslay`;
moving it breaks the include path on the build server.

Everything visible is triangles in a dynamic vertex buffer, built in Lua and
uploaded once per layer per frame. There are five layers, and the order is the
whole design:

| Layer | Space | Blend | Holds |
|---|---|---|---|
| `bg` | world | alpha | wall interiors, built once per map |
| `bgglow` | world | additive | wall edges, built once per map |
| `fill` | world | alpha | the starfield, and the dark inside of a hull |
| `glow` | world | additive | outlines, bolts, blasts, sparks |
| `ui` | screen | alpha | panels, bars, the radar and the map, buttons |

The starfield is in the per-frame layer rather than the baked one because it
moves: three depths of hashed cell grid, each drawn at `base + cam*(1 - k)`
so it lands on screen at `base - cam*k`, which makes `k` literally the rate a
layer travels against the camera. Nothing is stored between frames, the field
extends as far as anyone can fly, and a star whose tile is solid is dropped --
the wall interiors are in the layer underneath and would otherwise be shone
through.

## What a frame costs, and where it went

The client was spending about eight and a half milliseconds of Lua a frame in
a browser -- half a core at sixty frames a second, and the same with a menu
open as in a fight, because the arena never stops running behind it.
Measured per phase with `socket.gettime` in a debug wasm build, in the
browser rather than natively, which matters: desktop builds run LuaJIT and
HTML5 runs plain Lua 5.1, so a native profile understates the web by five
times and points at the wrong thing.

| phase | before | after |
|---|---|---|
| ships, weapons, prizes, effects | 2.20 ms | 0.39 ms |
| interface and radar | 2.06 ms | 0.43 ms |
| starfield | 1.92 ms | 0.26 ms |
| doors and wormholes | 1.63 ms | 0.09 ms |
| buffer upload | 0.46 ms | 0.37 ms |
| simulation, 100 Hz | 0.09 ms | 0.12 ms |

Three things, none of which changed a pixel -- the vertex counts before and
after are the same numbers.

**Writing vertices was the whole bill.** Indexing a buffer stream from Lua is
one call into C per float: twenty-one per triangle, fifty-two thousand a
frame. `vwbuf` in the native extension takes a shape at a time instead, so a
rectangle costs one crossing rather than forty-two. The geometry is still
described in Lua, where it can be read.

**`draw_tiles` searched the whole map every frame** -- eighty-nine tiles
square, seven thousand nine hundred crossings into the core, to find four
doors. Tiles do not move, so the search happens once, where the walls are
built.

**A star allocated a colour.** Three hundred and fifty `{r,g,b,a}` tables a
frame is twenty thousand a second, all garbage; eight brightnesses per depth
are made once instead, and at a pixel and a half across nobody can tell.

The interface's text got the same treatment: a node is only told its text,
position, scale, pivot and colour again when one of them changed, and the
vectors it is told with are made once and mutated rather than allocated per
line per frame.

Chrome's `Performance.getMetrics` puts the whole thing at 12% of a core where
it was 40%. The layers are sized against measured watermarks now rather than
by an order of magnitude, since the buffer is uploaded whole every frame
whether it is full or not; the heartbeat prints the high water mark and
anything a layer refused to draw, so a capacity set too tight shows up as a
number rather than as geometry that quietly stopped appearing.

Additive is what makes the glow layer read as light rather than paint:
overlapping bolts brighten instead of stacking, and because addition does not
care about order, the static wall edges share that pass with the per-frame
geometry for free. `render/vec.lua` is the whole vocabulary -- segments,
fans, discs, haloes, rings -- and knows nothing about ships.

Text is the one thing a bare mesh cannot do without an atlas, so it goes
through a gui component (`ui/vwui.gui_script`) that draws a pool of text nodes
and nothing else. The division is absolute: if it has a shape, `arena/ui.lua`
drew it; if it has words, the gui did.

## One menu, opening and mid-game

The client boots onto the menu over a starfield: a hull, a generated call sign,
and the list of games a directory is running. Escape opens the same tree over a
live arena, and nothing pauses while it is up. `client/arena/menu.lua` is the
tree and the settings, `ui.menu` draws whatever level `menu.view()` reports,
and `apply_menu` in `arena/arena.script` is the only place that knows what an
action means.

The single difference between the home screen and the pause screen is
`menu.home`, which says whether there is a game behind the panel. With nothing
behind it the menu will not close, since closing would leave a player on an
empty starfield with no way back.

Changing hull calls `sim_set_ship_class`, which is a respawn in place rather
than an arena rebuild -- the design and its consequences are in
docs/design/menu.md. The page also draws its own starfield and wordmark while
the engine compiles, and the game tells it when to stop, from the first frame
that has an arena on it.

## Two instruments, one corner

The top right holds the radar or the map, never both. The radar is sixty tiles
around you and answers what is near; the map is all 1024 and answers where you
are going, which on a map this size is a question nothing else on screen could
answer. `M` swaps them, and so does clicking either one.

The map draws terrain and nothing else: no ships, no prizes, no flags, nothing
in flight. A view of the whole arena with every pilot on it is a wall hack with
a keyboard shortcut, and contacts are what the radar is for. Its panel is
opaque for the same reason, since at the radar's own 0.55 wash a prize lying
under the dial comes through it and reads as part of the map.

Reading all thousand tiles from Lua would be a call per tile, so `sim.map_coarse`
in the extension does the pass in C and hands back one byte per four tiles,
holding the most important thing standing in that square. A cell rather than a
sample, because at this scale a wall is a pixel wide and a stride steps over
one. `world.build_overview` merges that grid into greedy rectangles once per
map: 928 of them for Chaos, 2195 for Alpha, against roughly 65000 cells. That
is why the `ui` layer holds 24576 vertices rather than 6144.

`lua5.1 client/tests/overview_test.lua` paints those rectangles back into a
grid and compares it to the map they came from, which catches a merge that
reaches too far as well as one that stops short. It reads the catalog's own
maps, so a reconverted map is one this test immediately covers.

## Pointing at things

`ui.lua` publishes a list of rectangles in the pixel space it drew them in, and
`arena.script` takes the first one a press lands in. Nothing else decides what
a click does, which makes two rules load-bearing and neither of them visible in
the code that depends on them.

The field of play holds no boxes. A press there is a trigger pull, left for the
gun and right for the bomb, and a box over a hull or the name beside it eats
that press: a player lined up on somebody would pull and fire nothing. This is
why nameplates are drawn and not clickable.

Order decides overlaps. The scoreboard is where that bites: each row publishes
its box before the panel publishes the one that takes the wheel, so a press on
a row reaches the pilot instead of the list.

Clicking a pilot's row on the scoreboard opens one box about them: which side
they are on when sides mean anything, what the zone will vouch for the seat
being, their record and their bounty. It belongs to that list and goes when the
list goes, since a box standing under a shut scoreboard says nothing about who
it is for. Escape closes it before it reaches the menu, because it is the
newest thing on screen and the key that shuts things is the one a hand reaches
for.

A bot is marked with a drawn head rather than the letters AI. Two letters after
a name read as part of the name until you have learned they are not, and the
scoreboard is scanned rather than read; the mark sits at its own column so a
scan finds them in a line.

The four link bars are the whole of the connection readout a player gets.
Clicking them opens the numbers behind it: frame rate, round trip, clock lead,
prediction error, rewind depth, bytes each way, tick, and what is in the room.
That is for whoever is working on the client, which is why it is behind a click
on the thing it is about rather than in the menu, and why it takes the feed's
strip while it is up.

`lua5.1 client/tests/hud_hits_test.lua` runs the real `M.hud` against a stubbed
engine and asks what a press at a given point hits: on every ship on screen and
on the name beside it, which have to reach nothing, and on a scoreboard row,
which has to reach the pilot. Both rules are invisible until somebody is
flying, on a build that takes six minutes to publish.

## No audio ships in the page

The kit is fifteen sounds and about a megabyte of 16-bit PCM, which compresses
to almost exactly a megabyte because that is what PCM does. None of it is in
the download. `ext/simcore/src/sfx.c` synthesises all of it on the player's
machine at boot, `arena/sfx.lua` hands each buffer to `resource.set_sound`, and
the page is 1.4 MB smaller for it, or 1.0 MB over the wire, which is 40% of the
compressed build.

What is in `sounds/` is fifteen wav files of silence, 172 bytes each. A sound
component has to point at a resource at build time and `resource.set_sound`
needs its own resource per component to write into, so there is one placeholder
per sound, named after the component that claims it. The `.sound` files beside
them are real: gain, mixer group and looping live there and are maintained by
hand.

The gun and the bomb have one sound per rung of their ladder, `gun0` to `gun3`
and `bomb0` to `bomb3`, picked by `sfx.play` from the rung the firing ship is
on. A rung is the same weapon harder rather than a different weapon, which is
what the panel says and what the core does, so the rungs share their character
and differ in weight. Since every buffer is normalised to one peak, the buffer
decides timbre only and the loudness climb lives in the `.sound` gains. A rung
past the end of a family plays the top of it, and the ceiling is read off the
kit rather than written down, so adding `gun4` to `sfx.c` and wiring a
component for it is the whole change.

`lua5.1 client/tests/sfx_test.lua` checks which component each rung reaches and
that every sound the kit renders has a component behind it. It runs under plain
Lua 5.1 with the engine stubbed, because the path it covers needs an arena, an
opponent and a climbed tech tree to reach in a browser, where a wrong component
id sounds like nothing rather than like a failure.

Rendering costs 259 ms in a debug wasm build, seven eighths of it the
soundtrack, and it is spent in `init` rather than spread over frames because
`init` is behind the menu the client opens on. `sfx.init` prints one line when
it is done, `SOUND: 15 sounds, 997 KB, 259 ms`, which is how you tell a client
that generated its audio from a client that is quiet for some other reason.
Only in a debug build: a release engine compiles `print` out, so this line and
the complaint in `sfx.fire` are both invisible on the published page.

The synth was a Python script until it moved into the client, and the port
reproduces CPython's Mersenne Twister so it could be checked against the files
it replaced rather than judged by ear. All fifteen came out byte for byte
identical. That property is worth keeping: it means a sound changing is
somebody changing it.

To hear the kit without running the game:

```sh
make -C client/tools sfx && client/tools/sfxdump /tmp/kit
```

## One-shots skip the engine's mixer on the web

Defold's HTML5 sound device mixes into chunks of 1024 samples and hands each to
Web Audio scheduled at the end of the last one, keeping four pending. Measured
on the shipped page, that is 43 to 75 ms of already mixed audio waiting to play,
and a gun fired now joins the back of it.

The queue is the engine's insurance against a slow frame, and its depth in
seconds is both the delay and the stall margin, so no setting shortens one
without shortening the other. Both alternatives were built and measured:
`sample_frame_count` at 768 and at 512 cut the delay and crackled at 26 fps
(0.3% and 7.3% of buffers arriving late), which is a frame cap this menu offers.
`use_thread` with the pthread engine and cross-origin isolation made it worse,
3.6% at full speed, because Web Audio exists only on the main thread and a sound
thread's calls are proxied back to it anyway.

So one-shots stand beside the mixer instead of shortening its queue.
`arena/sfx.lua` installs a small Web Audio graph through `html5.run`, hands it
the same buffers `sfx.c` renders, and plays each effect as an
`AudioBufferSourceNode` started immediately: 2.7 ms out rather than 45, measured
against the mixer's queue in the same page at the same moment.

The engine's own `AudioContext` is reused rather than a second one created, so
the autoplay gate, the gesture unlock in `tools/single_file.py` and the iOS
audio-session fix keep applying with nothing to hold in step. Per-sound gain is
read back off the `.sound` components with `go.get`, so the mix those files
carry is not duplicated in a second table to drift.

Held sounds stay on the mixer. A queue is only late at the start, and the start
of a rumble that runs for minutes is not something anyone can time. The
soundtrack alone is four fifths of the kit's bytes, so moving it would be work
in exchange for nothing audible.

Everything degrades rather than breaks. No `html5` module, a graph that fails to
install, a component whose gain will not read, a buffer still inside
`decodeAudioData`: each falls back to the mixer for that sound, which is where it
worked before. The `SOUND:` line at boot ends with how many made it, `19 direct`
being all of them.

Costs, measured: about 89 us per sound to build and start the nodes, so 1.25 ms
in a frame that plays the budget's full fourteen. The `html5.run` bridge itself
is 0.2 us and not worth batching away. Native builds are untouched, because the
whole path is behind `if html5`.

## Sound in a browser is gated, and the engine's gate is narrow

The soundtrack waits for that gate rather than starting into it. Audio mixed
into a suspended context is discarded, not held: the engine keeps mixing and the
device throws it away, so a track started at boot runs on silently and the first
thing a player hears is the middle of it. `sfx.music_tick` asks the context
directly whether it is `running`, and starts the track once, when it is.

It used to poll `sound.is_playing` and restart the track whenever the answer was
not yes. There is no `sound.is_playing` in Defold's sound module. The call raised
every frame under its `pcall`, the answer was never yes, and the bounded backstop
meant for a misreported component became the normal path: twelve restarts at two
second intervals across the first twenty-three seconds of every session, measured
in the shipped build. The test stub had invented the function, which is why no
test noticed; it now stubs only what the module really has.

Every page starts muted: the audio context is created suspended and only a
user gesture resumes it. The engine asks for that resume from exactly one
place -- a mouse or touch event whose `target` is the canvas -- and never
from the keyboard. A pilot now lands in the arena without a pointer ever
touching the page, so without this they would fly a whole match in silence.

Measured on the shipped build with autoplay gated on activation: a click
reaches `running` and queues audio immediately; `enter`, space and the arrows
leave it `suspended` indefinitely. A cross-origin iframe reaches `running`
either way, with or without `allow="autoplay"`, so an embedded page is not
the reason -- which was worth knowing, because it is the first thing anyone
suspects.

`tools/single_file.py` unlocks it instead, from any pointer, touch or key
anywhere on the page, and keeps watching until `resume()` takes, because the
first gesture can easily land before the engine has opened its audio device.
It also sets `navigator.audioSession.type = "playback"`, without which an
iPhone with the ring switch off mutes Web Audio by policy no matter what the
page does.

One sound has a duration rather than an instant: thrust, which is a looping
component switched on and off at the edges of the button. `sound.play` on a
looping component does not restart it, it starts a second voice, so calling
it every frame the key is held stacks sixty a second until the mixer runs
out. `sfx.c` renders a buffer that wraps: no envelope, sines snapped
to a whole number of cycles in the buffer, and the noise filter run twice
around the same buffer so the state it enters the loop with is the state it
left with.

The diagnosis is worth repeating because "no sound" looks identical whether
the cause is the gate, a missing component, or a silent mixer. Wrap
`AudioBuffer.copyToChannel` from the test harness and read the peak
amplitude: firing peaks at 0.32 across 194 non-silent buffers, which says the
generator, the components and the mixer are all fine and the fault is
upstream of all of them.

This replaced `draw_debug3d`, which was one pixel wide, one blend mode, and --
the part that mattered -- compiled out of `release` builds entirely, so a
shipped bundle drew an empty arena. **`release` is now the shipping target**,
verified in a browser.
