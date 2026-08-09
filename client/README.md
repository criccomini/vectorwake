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
| `arena/marks.lua` | Every weapon mark, add-ons and all, for the corner and the pads |
| `arena/menu.lua` | The menu tree and the settings it saves |
| `arena/directory.lua` | Asks a directory what games are running |
| `tools/single_file.py` | Folds a bundle into one self-contained page |
| `tools/sfxdump.c` | Writes the kit out as wav files, for listening to |
| `tools/sfxladder.c` | Whether a pilot can hear which rung fired |
| `tests/sfx_test.lua` | Which sound each weapon rung reaches |
| `tests/rung_test.lua` | That a rung's colour is legible and unlike anything else |
| `tests/pad_layout_test.lua` | Where a thumb's controls are, and what they draw |
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

Every press has to be held. Keys as much as mouse buttons: the engine polls
input once a frame and reports pressed and released as the differences between
two polls, so a down and an up inside one poll produce no difference and no
event, and nothing reaches the client to act on. An instantaneous
`mouse.click()` or `keyboard.press()` under a software renderer, where frames
are long, lands that way every time. Move if you are clicking, then hold for
~90 ms and release:

```js
await p.mouse.move(x, y); await p.waitForTimeout(120);
await p.mouse.down(); await p.waitForTimeout(90); await p.mouse.up();

await p.keyboard.down("m"); await p.waitForTimeout(90); await p.keyboard.up("m");
```

No key is exempt, but not every key gets you into trouble. Flying and firing
are held anyway, so a driver that holds the arrows and Space is already doing
the right thing without knowing why. It is the momentary ones that invite the
one-shot helper and lose the press: Esc, M, P, Enter and the charge keys.

A hand cannot press faster than a frame at 60 Hz, so this is a property of the
harness rather than of the game, and it is Defold's input layer rather than
anything in this client. It has now cost two sessions. The first read fast
clicks plus coordinates measured from a screenshot taken before a button was
added to the row, and reported a dead start screen. The second held a key down,
saw what it does appear, then tapped M and Esc and reported that the map and
the menu did nothing. Both times the interface was fine.

You do not have to click the canvas first to give it the keyboard. The engine
listens at the document, so a key held with nothing focused arrives anyway,
which is worth knowing because clicking to focus is the obvious first move and
in this game a click is a trigger pull.

`release` strips `print`, so a test that reads the client's own log needs a
`debug` bundle. Anything checking whether a player actually reached a zone
should ask the server instead: its status reports players and bots, and it is
the honest witness either way.

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

## What your ship is carrying

Bottom left: a row for the gun, a row for the bomb, a row per charge, and your
bounty. Each row is a mark, a count, and nothing else. The marks used to be
words, which made the one corner a pilot only ever glances at into a column of
reading.

Every round in the game is coloured by one thing: the rung it was fired at.
Green, yellow, orange, red, from `pal.RUNG`, and a bullet, a bomb, yours and
theirs all read off it. There were three ramps before, with hue carrying the
team and lightness the rung, and it failed at both jobs: ten units of colour
between rungs is not a call anybody makes on a three-pixel object crossing the
screen, and blending toward white converged the two teams as they climbed, so
the deadliest rounds were the hardest to attribute. It also put a rung 3 bomb
on the charge colour exactly. `tests/rung_test.lua` measures all of that.

What it gives up is that a round no longer says whose it is. Ships, names and
plates still carry the team, and in a free-for-all every round was worth
dodging anyway. The price of borrowing a scale everybody already knows is that
rung 1 sits nearer the prize green and rung 2 nearer the charge gold than a
ramp of unused hues would.

There is one mark per trigger and nothing else on the row. An add-on is drawn
onto the mark rather than set out beside it, which is the correction to the
first version of this: it gave every add-on a symbol of its own and lined them
up in a column, and six shapes beside a seventh read as seven things the ship
is carrying, when what a player holds is one gun and one bomb that greens have
been changing all match. So a bolt with bouncing on it is a bolt with a ball on
each end of it, and a bomb with proximity is a bomb standing on the area its
fuse reaches.

The level was three cyan rungs beside the mark, and that went the same way. It
was there before the round had a colour of its own, and the round has one now:
it is drawn in the hue of the rung it is fired at, on the ramp above, so the
corner already answers the question the ladder answered and answers it in the
terms the arena uses. Two answers to one question, the second of them in the
team's colour, which a weapon's level has nothing to do with.

A gun is a line into a dot and a bomb is a ringed head, which is what each is
in the arena, and one set of add-on marks fits both because every add-on is
something that happens either to the round's body (multifire sends more of
them, freeze rimes it) or to the round itself (shrapnel throws fragments off
it, bouncing rings it, the repel add-on stands a wave in front of it).

The bomb's head is a core filling most of its ring, which is the proportion the
arena draws one in flight at: a 3.6 core inside a 4.6 ring, so the two read as
one object with a lit rim. It was a fifth of that for a while, a small dot a
long way inside a ring, which is the picture the proximity fuse used to draw,
so a bare bomb read as a loaded one.

Proximity is the exception to all of it, and is drawn as ground rather than as
a mark. A fuse is a circle a round goes off inside of, so every drawing of its
boundary is a ring, and this mark already has rings on it. Cutting the ring
finer, squaring it into a reticle and breaking it on the flanks were all drawn
and all still asked a reader to tell one circle from another at three points
across. It is the filled area now, in the round's own hue taken right down and
laid under everything, so the head and the fragments and the bounce ring stand
on it. Nothing else on any mark is filled, and because ground is not a ring it
takes no share of the room: a hull with a fuse and fragments splits the width
two ways rather than three.

The bomb had a fading trail behind it until it did not. An icon is not a round
in flight, so a streak of motion on a thing sitting still in a corner was a
picture of the wrong moment, and a fade cannot be centred: it reaches its full
length at almost none of its brightness, so a bounding box put it square in the
middle of a pad while everything visible crowded one side. Three passes at
biasing it into place all landed somewhere a screenshot said was still off.
`world.lua` still draws one on a bomb that is actually going somewhere.

Rungs are in the shape rather than in a number beside it, and they are the
zone's own arithmetic: one rung of multifire is two more barrels, a rung of
proximity is a wider reach. Read `mod_step` in a `zone.toml` and then read
`dec_multi` and the rest in `marks.lua`; they say the same thing twice on
purpose. Bouncing is the one that does not count: a ring or no ring, on both
marks, because a ring three points across cannot carry a count as well as an
identity.

Shrapnel says it once, not twice. Its magnitude is a whole pattern per rung
rather than a number to scale, so the mark asks `sim.shrap_count` how many
fragments the zone throws and draws one tick each. It used to work the count
out instead, six then eight then ten against a baseline that throws two, four
and eight, and against a zone free to put any pattern on those rungs it could
be wrong by any amount. The ticks thin as they multiply, down to the stroke
floor and no further, so thirty-one of them stay ticks rather than becoming a
filled ring or a row of blinking hairlines.

The room outside the round is shared out before anything draws rather than
spent first come. A row is 22 points tall and the mark has to live inside it
however loaded the hull is, so the add-ons that ring the head are counted
first and each gets an equal ring of what is left. Two of them get half each
and read clearly, and the six-add-on hull that no zone in the catalog hands
out gets a sixth each and reads as a dense mark, which is the right way round.
Spending the room as it was asked for instead would put a Spire's fragments
through the row above.

On a touchscreen the corner is not drawn at all. The pads carry it instead:
`arena/marks.lua` holds the
whole mark, add-ons and all, behind one `marks.weapon` that `ui.lua` and
`touch.lua` both call. Neither draws a stroke of a weapon itself. That is the
only reason it is worth having the marks in a third file, and it was worth it:
the pads once knew about a fan, a bounce ring and a fuse and nothing else, so a
hull carrying shrapnel (22 of the 24 in the shipped zones) carried it invisibly
on a phone, with the corner that would have said so switched off on the grounds
that the pads had it covered.

What each caller still owns is where a mark goes and how big it is. `ui.lua`
hangs one off each row of a column and flips y on the way in, since it reckons
downward and the marks reckon upward. `touch.lua` centres one in a round pad
and sizes it off the pad's own radius, derived rather than picked: a mark
reaches `MARK_REACH` of its own size out from the round and a gun's round sits
`BOLT_BIAS` forward of centre, so the two triggers have different worst cases
and one ratio for both would either spill a gun's fragments over the rim or
draw a bomb head a third smaller than the pad it has to itself.

## What a thumb gets

The two triggers own the bottom right corner, side by side, sized so the gun
is the larger of them. Round, because the charges are square: which class of
control a thing is reads before the picture inside it does, and a round pad
beside a square cell can never be taken for another trigger.

One ring per control and nothing outside it. The gun wore its energy on a
second arc past the rim for a while, so it had two rings where the bomb has
one, and the outer one was a copy of an instrument thirty degrees of eye travel
away: every hull in the game carries a bar above it saying the same thing,
yours included, and that one is where you are already looking.

The charges go above the triggers rather than beside them, so reaching the gun
never crosses one. They climb the edge as a column while there is edge to
climb, and step sideways when there is not: on a phone held upright there is
most of a screen of it, and held sideways the dial takes better than half the
height and leaves room for one cell. `M.ceiling` is where the dial ends,
handed down by the caller -- `touch.lua` knows where a thumb goes and `ui.lua`
knows where the instruments go, and neither reaching into the other is what
lets the two of them not depend on each other at all.

How many of a charge are in hand is pips along the cell's floor, one per slot
the hull can hold, filled as far as it is. It was a numeral floating above the
pad, which is the one thing on this screen a bare mesh cannot draw, and it sat
in the gap between two controls belonging to neither.

The bounty went the same way. It was the last row the corner had left on
glass, and it is a number you read between fights rather than during one, which
the scoreboard has: one figure in the corner of a phone is furniture for the
sake of the corner not being empty, and that corner is where a thumb rests.

A charge you have spent out gets no cell, and the rail closes up behind it.
Both surfaces do this: the corner drops the row and the block shrinks by it,
since the block hangs off the bottom of the window and what a row costs comes
off the top. A control that does nothing when pressed is bad enough with a
keyboard, and on glass there is no travel and no cursor, so the only way to
learn a cell is dead is to tap it in a fight and get nothing back. Q, W, A and
S stay bound to the hull's slots rather than to the rows drawn: binding them to
the drawing would move Q onto your burst the moment your last repel went.

`lua5.1 client/tests/pad_layout_test.lua` draws the real controls through a
recording layer and measures where a tap lands against where the ink went,
because the layout and the hit test were written out separately once and had
drifted, so half a pad did nothing and the dead space beside it fired. It also
runs stack_test's own add-on loop against the pads, walks all 64 combinations
looking for a mark that leaves its control, and checks that no round wears a
trail.

Where a mark looks centred is measured as the midpoint of two answers that
disagree. Weighing a drawing by how much of it there is centres a gun on its
dot, since a solid disc outweighs the hairline reaching it; taking the
drawing's extent centres it near the middle of the line, since the far tip of a
hairline counts for as much as the dot. The eye lands between them, a strip of
the mark drawn at biases either side agrees, and `marks.BOLT_BIAS` came out of
that measurement rather than off a screenshot.

`lua5.1 client/tests/stack_test.lua` runs the real `M.hud` against a stubbed
engine and measures: every add-on draws something, a third rung looks
different from a first, a fan's rounds are the colour of the round the gun
fires, the row's hover box covers everything its mark drew, no team colour
appears beside a mark at any level, and no combination of the six at full depth
leaves its own row or reaches the column the rows below it count in. That last
one walks all 64 combinations, because the case that overflows is never the one
somebody thought to try.

Since the shapes are the row now, pointing at one names what this hull is
actually carrying rather than what weapons can carry in general. A shape drawn
onto a mark is learnable exactly once, by being told.

## The screen naming its own parts

Rest the pointer on an instrument and it says what it is: what a rung buys,
what a bounty is a price for, which dial is standing in the corner. Move off
and the word goes. One instrument at a time, because the pointer is already an
expression of what you are asking about, so the question and the answer land in
the same place. Nothing answers under the menu, which is a different screen and
has the drawn keyboard on it already.

A held key did this for a while, naming every instrument at once. What killed
it is the sentences getting longer. They say what the card a dead pilot reads
says, word for word, so that learning what a bomb is from the wait after one
killed you and then pointing at the `BOMB` row is not learning it twice in two
different sets of words. A card does not fit on a row, so all of them at once
had to be gathered into a column off to one side, and a column says which
instrument each line belongs to by colour rather than by position. Position was
the whole point.

There are no leader lines either. The first version had eleven captions with
eleven strokes running out across the arena to reach them, and the strokes were
the whole of what made it unreadable. Every instrument here already sits
against an edge with clear space beside it, so a word set next to a thing is
read as being about that thing, at none of the cost. What is left is one line
in the colour that instrument already wears, and only where the label on the
row does not say it already: `GUN` names itself, so the line beside it explains
the rung.

What can be pointed at is a list of rectangles filed the same way and at the
same time as the anchors, and deliberately not `M.hits`. A hit box is a press,
and the field of play holds none at all because left click is the gun; these
are read by the pointer and by nothing else, so naming a thing can never cost a
trigger pull. A touchscreen sends no pointer and gets nothing here, which is
what the cards under `DESTROYED` are for.

Where the words go is filed rather than worked out twice. Each element records
where it landed as it draws itself, into `anchor` in `ui.lua`, and the label
reads that; the corner stack also reports how far right it actually reached, so
a hull carrying three add-ons pushes the sentence right rather than having it
printed through its own loadout. `lua5.1 client/tests/help_test.lua` runs the
real `M.hud` against a stubbed engine and measures where the text came out: on
the row it names, clear of what is already on that row, and inside the screen,
which for the bottom row of the stack takes a clamp.

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

Clicking a pilot's row on the scoreboard opens one box about them: their side,
what the zone will vouch for the seat being, their record and their bounty. It
belongs to that list and goes when the list goes, since a box standing under a
shut scoreboard says nothing about who it is for.

The side is named only when the zone marked it public, or when it is your own,
which you are in and may know either way. A private side is a squad who
arranged themselves and naming it here would hand the room a roster the zone
deliberately did not send. An unknown side gets no row at all: falling back to
the team byte, which the client can read off any ship, would be the same leak
by a duller instrument.

Escape shuts what is open before it opens anything, innermost outwards: the
pilot box, then the info panel it came from, then the menu. It is the key a
hand reaches for to dismiss whatever is on screen, and answering it with a menu
answers a question nobody asked while leaving the thing they meant standing
behind it.

A bot is marked with a drawn head rather than the letters AI. Two letters after
a name read as part of the name until you have learned they are not, and the
scoreboard is scanned rather than read; the mark sits at its own column so a
scan finds them in a line.

The feed stands five lines deep, and two of them are lit: green for a kill you
took, red for one taken off you. Those are the two lines out of a busy feed
worth finding without reading it, and lighting a third would mean none of them
stands out. A kill's payout rides in brackets, `(+40)`, because the line is
already a sentence and a second clause on the end of it is one more thing to
read past.

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

## The mark

Six strokes, `\|\|\|`, read as the V of vector and the W of wake. Each wedge
is a diagonal falling into a vertical and meeting it on the baseline; the first
is the V, in the colour the interface gives the other side, and the second and
third together are the W, in yours. One gap throughout, so nothing marks where
one letter stops and the next starts and the run reads as one gesture: you get
the letters out of it the way you get them out of the name.

The diagonals are wakes, dark where they leave and full where they land, which
is what a thing arriving looks like everywhere else in this game. The verticals
stand. Every one of the six is the same hairline, so what changes along a wake
is the light in it and not the line: drawn at two weights the wakes read as
shadows cast by the verticals rather than as strokes of the same word. That is
the whole vocabulary, and it is the same one the weapon marks are drawn in,
which is the argument for it: a wordmark made of strokes belongs to an
interface that has nothing else in it.

What it replaced was two hulls passing on a course off vertical. That was a
picture of the game; this is the name, which is what a wordmark is for.

On the menu it draws itself. A bullet falls down the first diagonal, bounces
off the baseline where the vertical stands, runs up it, hops to the next wedge
and does it again, six strokes in about a second, and the mark is left standing
when it finishes. Nothing tells it the menu opened: the run restarts whenever
the mark has not been drawn for a moment, so every way into the menu replays it
and nothing has to remember to ask.

It exists twice, which is the risk worth knowing about. `client/web/icon.svg`
is the source the page template carries as three data URIs, and `ui.logo` in
`arena/ui.lua` draws the same six strokes beside the wordmark, because the
interface has no way to put a picture on screen and would not want one.
`lua5.1 client/tests/logo_test.lua` reads the shipped SVG's own coordinates and
holds the Lua to them, so the two cannot drift apart without CI saying so. It
also checks what makes the mark a word rather than a pattern, that each wake
lands where its vertical stands and that the three wedges are evenly spaced,
and it drives the animation to make sure it starts from nothing and finishes
into the shape itself rather than into an approximation of it.

The favicon is its own cut rather than the logo shrunk: a heavier line and a
wider gap, since at sixteen pixels the logo's hairline is a hairline and the
three wedges run together into one smudge. What does not change between the
cuts is the wake: it fades exactly as `seg_fade` draws it in the interface,
which in SVG is a stroke painted with a `linearGradient` running end to end.
Drawn flat, as it was at first, the icon is three bars and a colour change, and
the thing the shape is about stops happening. At the logo's own weight it also
stops happening, because a stroke that fine sits under a pixel on a tab: the
whole reason the favicon is cut separately.

Both cuts stand left of centre in the tile. Centred on the box they fill, they
look shoved right, because a wake arrives out of nothing and weighs almost none
of the width it covers: the drawn box wants the mark 3 px left and the drawn
ink wants it 47, on a tile 512 across. It sits at the midpoint of the two,
which is how `marks.BOLT_BIAS` was settled for the gun and for the same reason.
Past about 36 px the first wake's thin end runs off the left edge, and a hard
cut across a gradient is worse than the thing being fixed. `logo_test` holds
both ends: clear of both edges, and biased the way the weight is not.

## The repel nobody could see

A repel is a weapon whose life is one tick. It is spawned in the ship phase and
ends in the weapon phase of the very next step, so the only snapshot that can
carry it is one packed on the tick it was fired: at 20 Hz over a 100 Hz
simulation, one shove in five. The other four reach a watcher with no weapon to
draw and no expiry to hear, only ships suddenly moving. Your own is fine,
because you simulate all of it yourself.

That went unnoticed for as long as nobody fired one, and the bots learned to
spend charges this week.

Extending its life is not the fix: the shove is applied in `weapon_end`, so a
round that lives five ticks is a repel that fires 50 ms late, and a repel is a
panic button. So `world.charges` reads the firer's inventory instead, which is
in every snapshot. A remote pilot's count moves only when a snapshot lands,
since prediction runs their ship with no buttons, and a drop is a charge spent.
It draws only for a charge that leaves nothing else to look at, which is the
life test: a burst puts twenty-four rounds in the air and draws itself.

`a_repel_is_gone_before_a_snapshot_can_carry_it` in the server pins the fact
from the other side, so the day a repel becomes packable the client can go back
to drawing it from the weapon. `lua5.1 client/tests/charges_test.lua` covers
what must not draw: your own hull, a pickup, a death, a respawn, a seat
somebody new has taken, and a charge that flies before it goes off.

## The games list survives its directory

`arena/directory.lua` holds one socket and re-asks on a timer while the list is
the thing on screen. The socket dying is the case that matters, because the
moment it is most likely to happen is a deploy, which is also the moment
somebody is most likely to be staring at this list waiting for the fleet to
come back. So `M.tick` dials again when there is no connection, backing off
from two seconds to fifteen: a dial is a TLS handshake rather than the one byte
a refresh costs, but the first retry is quick because a restart takes seconds.

Every dial carries a generation, and a callback from a socket that has been
replaced is dropped. Without that, a socket given up on can still deliver its
own disconnect, clear the connection belonging to its replacement, and leave
the list dialling over the top of a working link for ever.

An outage under a list that already has rows is silent and leaves them up: a
reply that never came is a worse reason to blank three games off the screen
than counts a few seconds stale. An outage with nothing to show says where it
was looking, and the line under the list says the list fills in by itself,
because reloading the whole client used to be the only way out of that screen.

`lua5.1 client/tests/directory_test.lua` stubs the socket and delivers the
events by hand, since none of this is reachable without a server that stops and
then starts.

## No audio ships in the page

The kit is twenty-four sounds and 1.15 MB of 16-bit PCM, which compresses to
almost exactly that because that is what PCM does. None of it is in the
download. `ext/simcore/src/sfx.c` synthesises all of it on the player's
machine at boot, `arena/sfx.lua` hands each buffer to `resource.set_sound`, and
the page is 1.4 MB smaller for it, or 1.0 MB over the wire, which is 40% of the
compressed build.

What is in `sounds/` is twenty-four wav files of silence, 172 bytes each. A
sound component has to point at a resource at build time and `resource.set_sound`
needs its own resource per component to write into, so there is one placeholder
per sound, named after the component that claims it. The `.sound` files beside
them are real: gain, mixer group and looping live there and are maintained by
hand.

Twelve of the twenty-four are the weapon ladders: `gun0` to `gun3`, `bomb0` to
`bomb3` and `blast0` to `blast3`. `sfx.play` takes a rung as a fourth argument
and appends it to the family name, so `gun` plus rung 2 is the component
`gun2`. The budget stays keyed on the family, because four rungs of one gun are
still guns. A rung past the end of a family plays the top of it, and the ceiling
is read off the kit rather than written down, so adding `gun4` to `sfx.c` and
wiring a component for it is the whole change.

The eight launch sounds are eight functions with nothing shared between them but
the tools they call, which is the third design and the first that worked. Twice
before they were one recipe with a table of numbers per rung, and both times a
player who flew the whole ladder reported the rungs as one sound. What each of
them is meant to be, and the three synthesis tools that arrived to build them,
are in [docs/design/audio.md](../docs/design/audio.md).

Where the rung comes from is different for each. A shot reads it off the ship
that pulled the trigger, because a spec says what a projectile does and not
which rung fired it, and the firing tick is the one tick the two cannot have
drifted apart on. A detonation reads it off the blast radius instead: for a bomb
that is the same answer, since a rung is exactly a wider blast, and for a repel
it is the only answer there is, its 512 pixels being wider than any bomb while
its level comes back -1.

Every buffer is normalised to one peak, so the buffer decides timbre only and
the loudness climb lives in the `.sound` gains. Those gains are not in order and
that is not a mistake: a folded bolt is a dense buffer and a resonant one is
sparse, so equal peaks are unequal loudnesses. The numbers come from solving each
sound's loudest 300 ms window for an even climb, two decibels a rung and three
for the detonations.

`make -C client/tools check` is the one client test that cannot be Lua: it
renders the kit with this same C and measures whether the rungs can be told
apart. Two axes, because either alone has been satisfied by a kit that still
sounded the same: a spectral distance across third-octave bands over hundredths
of a second, and a step in register of at least a tritone. It also measures how
long each sound takes to arrive, which is what tells a gun from a bomb now that
the tinny end of one ladder and the nasty end of the other share an octave.
`client/tools/sfxladder.c` says what it measures and why each floor sits where it
does. It also builds the synth as C rather than the C++ Defold's build server
makes of it, which is what catches the dialect drift.

`lua5.1 client/tests/sfx_test.lua` checks which component each rung reaches and
that every sound the kit renders has a component behind it. It runs under plain
Lua 5.1 with the engine stubbed, because the path it covers needs an arena, an
opponent and a climbed tech tree to reach in a browser, where a wrong component
id sounds like nothing rather than like a failure.

Rendering costs about a sixth of a second, four fifths of it the one soundtrack
that boot needs, and it is spent in `init` rather than spread over frames
because `init` is behind the menu the client opens on. `sfx.init` prints one
line when it is done, of the shape `SOUND: 24 sounds, 1153 KB, 210 ms, 22
direct, track 5`, which is how you tell a client that generated its audio from a
client that is quiet for some other reason. Only in a debug build: a release engine compiles
`print` out, so this line and the complaint in `sfx.fire` are both invisible on
the published page.

There are eight soundtracks and the game rotates through them, three minutes
each, so `music` is the one component the kit does not render from a name.
`sfx_music_begin` starts a track and `sfx_music_step` builds it in pieces small
enough to hide inside a frame; `sfx.music_tick` spends one piece at a time on
frames that had room, which is why a rotation costs nothing when it lands. The
rotation, and why it is not eight components, are in
[docs/design/audio.md](../docs/design/audio.md).

The synth was a Python script until it moved into the client, and the port
reproduces CPython's Mersenne Twister so it could be checked against the files
it replaced rather than judged by ear. All fifteen of them at the time came out
byte for byte identical. The generator stays for that reason: a sound changing
should be somebody changing it, not the noise moving underneath.

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
