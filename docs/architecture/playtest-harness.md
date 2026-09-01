# The playtest harness

A program that plays the shipped game the way a person does: through the real
client, over a real WebSocket, against the real server, with a keyboard or a
thumb, for hours at a time. It exists to find the bugs that live in the seam
between client and server, and to produce session-shaped evidence about
balance and dullness that no shorter test produces.

The stage, the probe, the four device profiles, the journeys and the oracles
are built and run in CI. It lives in `harness/`, with `harness/README.md` for
how to run it. The monkey and the player are not built; the last section says
what is left.

It has already earned its place. On its first run against the shipped page it
found that `single_file.py --fragment` drops every script in the head, so the
local build the README told people to make was missing the install prompt, the
link anchors, the ask forms, and the viewport reconciler, and threw on every
load. Production packs without that flag and was never affected, which is
exactly why nobody had noticed.

## Where it sits

The project already tests at four layers, and it is worth being precise about
what each one can and cannot see, because the harness is defined by the gap.

- The sim goldens (`make -C sim check`) prove the C core is deterministic and
  that x86-64, arm64, and WASM agree on every state hash. They say nothing
  about whether anyone can play.
- The server's Rust tests run rooms in process, including a join test that
  reads the actual packed wire the way a client would. They stop at the
  socket.
- Calibration, the drill, and the melee probe
  ([bot-calibration.md](bot-calibration.md)) run whole populations of bots
  through whole matches with real statistics. The bots enter at the protocol,
  so nothing in these runs touches the client at all.
- The client's Lua tests and `ui_harness.lua` check that a press resolves to
  the right action and that layout math holds. They run against a fake engine,
  one module at a time. `shot.sh` photographs the native build under Xvfb so a
  person can look at it.

Nothing plays through the client. Every recent bug that hurt is in that gap:
the deployed client whose compiled core read a wire the server had stopped
writing, so a joining player saw DESTROYED on a healthy fleet; the roster's
fly-this-ship press that resolved to nothing for weeks because a panel
swallowed it at pick priority zero; the join hang the preconstructed-ships
change shipped with; the benched duel pilot who read DESTROYED while waiting
for a rival. Each of these passed every layer above, because each layer above
was honest about a boundary the bug sat on the far side of.

## What the industry settled on

Studios that automate this converged on a few rules, and they transfer.

Most gameplay testing does not drive the real client. Riot runs thousands of
League of Legends tests as headless games with inputs injected at the command
layer, far faster than real time, and boots the full client for only a thin
slice. Factorio re-runs recorded sessions headless and fails on hash
divergence. MMOs load test with thin clients that speak the protocol
without rendering; EVE's mass tests are the known example. Vectorwake already
works this way: the goldens, the bot fleet, and calibration are those layers.

When a real client is driven, input goes in through the game's own input
layer and assertions read game state, never pixels. Rare's Sea of Thieves
harness is the canonical writeup: bots in real clients on real servers issue
virtual controller input and every check is a query against state. The
commercial tools for engines without a DOM (AltTester, GameDriver, NetEase's
Airtest and Poco) all compile a small agent into the build that exposes state
over a socket, because a GPU-composited frame answers no questions.
Screenshots are kept as evidence for the human reading a failure, not used as
oracles.

Balance and fun are not automated directly. King trains agents to predict
Candy Crush difficulty; EA's SEED group uses curiosity-driven agents to find
map holes; Ubisoft has probed fighting balance with agent populations. What
gets automated is anti-fun detection: dominant strategies, stall states,
snowballing, collapsed k/d spreads. Fun itself stays with humans, and the
automation's job is to stop humans wasting a playtest on something the
counters would have rejected.

The device matrix runs in emulation. Real phones catch hardware bugs, so big
mobile studios keep racks of them, but the functional matrix of orientation
and input method is emulated because it costs a thousandth as much.

## The stage

One command stands everything up on localhost, in about two seconds. The
server binary already plays its three roles from three first arguments,
exactly as deployment runs it: a directory, an arena, and the bot server. The
wasm bundle comes from `client/build.sh wasm-web` and `single_file.py`, and is
served by a page server in the same process.

Everything is cleartext on loopback, which the directory allows and refuses
from anywhere else, so there is no Caddy and no certificate. There is no
meta-layer either: the catalog is copied with its `[meta]` block removed and
everybody flies as a guest, which costs the account path and buys a stage that
needs no database. Rated filing is off, because a harness session's kills are
real enough to move a ladder that belongs to other people.

The opposition problem was already solved: the bot server fills the room with
the same pilots that fly the live fleet, so one browser makes a full match.

A build is how the client is told where its fleet is, because
`vectorwake.directory` is compiled into game.projectc. It could have been read
from the page instead, and deliberately is not: a client that took its catalog
address from a URL would follow any link that named one, and a catalog names
the meta-layer that client sends an account secret to. `build.sh` takes a
settings overlay in `VW_SETTINGS` for this.

The page is packed the way CI packs what it publishes, without `--fragment`.
That flag strips the document to its styles and its body, and the shell's
`window.vw*` helpers live in the head, so a fragment loses them. A harness
testing a page the fleet does not serve would be worse than no harness.

The harness lives in `harness/` at the repository root: Node, a pinned
Playwright, and the run scripts. It spans client and server, so it belongs to
neither tree.

## The probe

The GUI is meshes and text. There is no DOM to query and no accessibility
tree, which is the same corner every game engine paints testers into, and the
industry answer is the right one here: the client publishes its own state.

The web shell already carries a family of `vw*` bridge functions between page
and engine. The probe is one more, in `client/arena/probe.lua`, published at
the end of the frame from `browser.finish` so that every panel, card and pad
has finished saying what it drew. The driver reads `window.vwProbe` with
`page.evaluate`. The report carries what a player could state about their own
screen:

- which screen is up, which stop or panel, and where the cursor is
- every control the client published, and what a press on each would fire
- whether the pilot is in a room, and the roster
- own ship: alive, energy, position, hull
- the tick, a frame counter, and the link state
- the touch pads' hit boxes
- the fault, if the probe itself failed

The second of those is the one that matters. It does not publish rectangles
and leave the reader to work out the rest: it runs `ui.pick` at the middle of
every box and publishes what actually wins, so a control that something else
covers says so in its own words. The rule that follows, learned once already
on the roster press, is that every assertion reads the probe or the server and
never a screenshot. What a press resolves to is a fact; that a box exists is
not. Screenshots and video are evidence for the person reading a failure.

Two things were easy to be wrong about and are settled in one place each.
`ui.hits` counts y downward and `touch.layout` counts it upward, so both are
converted here, once, into CSS pixels from the top. And `ship_x_raw` is
pixels, not the core's Q8, so a tile is sixteen of them and not four thousand:
the harness's first flight measurement was off by that factor and reported a
ship that had crossed the map as one that never moved.

The probe is off unless something sets `window.vwProbeHz` before the engine
boots, which the harness does with an init script rather than a query
parameter: nothing in a URL can make somebody else's client start describing
their screen. Disarmed it costs one `html5.run` every two seconds. Armed it
publishes ten times a second rather than every frame, so that it stays out of
the frame time it reports. Nothing in it is secret; it is the player's own
view of their own screen.

## Input

Input goes in as real browser events, never as calls into Lua, because the
input path is much of what is under test.

The desktop profile types with Playwright's keyboard against the real binds.
The mobile profiles run Chromium's device emulation and send every touch
through one CDP session, and the driver aims taps at the pad boxes the probe
publishes, which is what a thumb does. One channel for touch, not two: a
version of this that tapped with Playwright's own touchscreen and dragged
through CDP left Chrome's touch bookkeeping disagreeing with itself.

Four profiles cover the matrix, and every journey runs on all four:

- desktop, 1280x800
- desktop short, the window height where the landing lies down into its rail
- phone portrait, 390x844 at 3x, touch
- phone landscape, 844x390 at 3x, touch

A real phone stays a manual spot check. Emulation covers layout, orientation,
touch, and pixel ratio, which is where the functional bugs are; it does not
cover thermals or Safari, and pretending otherwise would be false comfort.

## The drivers

Three drivers share the stage and the probe, in increasing looseness. The
first is built.

Journeys are scripted walks, sharing an `arrive` prologue: boot, find the
fleet, press PLAY NOW with whichever hand the profile has, take a seat.

`boot-to-match` then flies, and fails if the ship never gets a tile from where
it started. `ship-change` opens the menu mid-match, opens the ship stop, turns
the body carousel, checks the room has *not* moved the pilot yet, closes the
panel, and waits for the server to put them in the hull they built. That
second assertion is the one worth having a browser for: the panel drafts, so
nothing is supposed to reach the room until it closes, and no test on either
side of the wire can see both halves of that. It asks again where the close is
refused, because nothing pauses while that menu is up and a ship costs a full
bar, so a stray round between the last press and the close is a refusal by
design; what it does insist on is that the client names the reason rather than
dropping the work in silence.

The ones still to write are every landing stop opened and backed out of,
settings changed and the change observed, leave and rejoin. They are the smoke
test, and they are quick: four profiles in under two minutes.

What a journey measures is worth one caution. `boot-to-match` watches how far
the ship ever got from its spawn, not where it finished, because a pilot who
flies a circuit finishes near the spawn having crossed the map twice. The
first version measured net displacement and called a ship that had flown 69
tiles a ship that had not moved.

The monkey issues random but legal input, seeded, for a long time: over
the menus, in flight, across joins and leaves. Random input is embarrassingly
good at finding soft locks and Lua errors, and the seed goes in the failure
report so any run replays exactly.

The player is a policy loop shaped like a session rather than a test:
pick a zone, fly a plain pursue-and-evade policy off the probe, die, sit out,
wander back to the menu, change hull, rejoin, stay for hours. Skill is not the
point and the policy should stay dumb; the point is real occupancy of the real
code paths at human cadence, with the bot population supplying the fights.
This driver deliberately does not duplicate the server-side pilot brains. They
answer a different question at a thousand times the speed.

## Oracles

A run fails on:

- a fault the client reports about itself
- an uncaught exception on the page
- a disconnect nobody asked for
- a stalled frame counter or a stalled tick
- a probe invariant: in a room implies knowing of ships; flying implies having
  a ship; energy inside the hull's own ceiling
- the arena counting no humans while the client believes it is in a room
- soak curves: JS heap and frame time sampled over a long run, with growth
  that survives the whole run a failure

The first of those replaced a blunter rule, and the difference is worth
keeping. Failing on any console error sounds right and is not: Defold
surfaces a Lua error through `console.error`, and so does Chrome when it
wants to complain that it declined a `preventDefault`. A browser advisory
about touch dispatch ended runs that were flying perfectly.

The client already tells the two apart. Its diagnostics wrap `console.error`
and post to `/meta/v1/client-error` with a stack, which the stage serves, so
anything page script logs is a reported fault while a message the browser
itself printed never reaches that wrapper. Console errors are therefore
recorded as advisories: counted, printed at the end of a passing run, never
fatal on their own. Muting them would have been the other wrong answer.

The oracle this harness was built for is not among them yet.
`agreesWithServer` compares the client's account of its own ship against the
server's, which is the DESTROYED-on-a-healthy-fleet class and the one thing
no single-sided test can catch. It is written and has nothing to ask: nothing
the arena publishes carries a position, so it wants a spectating connection
that decodes snapshots the way `tools/pilot` does. What the stage can answer
today is the humans count, which is coarser and still catches a client that
believes it joined something the arena never seated.

Every failure ships its evidence to `client/dist/harness-runs/`: the fault,
the journey's log, the client's last full reading, the console, and every
server's log for the same seconds. CI keeps it as an artifact.

## Balance and dullness

The harness does not judge balance. Calibration does, with declared
hypotheses and corrected families, and forty browser hours would buy what the
protocol-level tournament buys in a minute. What the harness adds is the one
dimension calibration cannot reach: sessions at browser latency, through
prediction, with menu time and death time in them.

From those sessions it reports the anti-fun counters, in the spirit the melee
probe established: time to first contact, stall seconds, deaths with no input
in the preceding second, repel exhaustion, the room's k/d spread. The
counters gate nothing on their own. They land in the run report for a person
to read, and a threshold only becomes a failing check once it has earned that
by catching something.

## Where it runs

Locally, `node harness/bin/vwplay.mjs journeys`, and `--headed` when you want
to watch it play. In CI, the `playtest` job in `client.yml` runs the journeys
on all four profiles on any push touching `client/**`, `sim/**` or
`harness/**`, beside the existing gates, and keeps the evidence of a failure
as an artifact. The monkey and the player are meant to run nightly for hours,
once they exist.

The soak targets localhost only. The live fleet gets humans; pointing an
input-fuzzing browser at production would test the wrong thing and bother
real players while doing it.

## What is left

Done: the stage, the probe, the four profiles, `boot-to-match`,
`ship-change`, the oracles above, and the CI job.

1. The rest of the journeys: every landing stop opened and backed out of,
   settings changed and observed, leave and rejoin.
2. The monkey, nightly.
3. The player, and with it the soak curves and the counter report.
4. The spectating connection that `agreesWithServer` needs, which is the
   oracle this was built for.

One thing found along the way and not chased: in an emulated portrait phone,
a touch in the bottom band of the window makes Chrome report a `touchstart`
it would not let the page cancel. It is not the canvas, which takes every
gesture (`touch-action: none`, added because the harness looked), and it is
not the engine, which asks for cancelable events properly. It does not appear
in landscape, on a desktop window, or anywhere outside a match, and the game
plays through it. It is recorded as an advisory on every portrait run, which
is the right amount of attention for it until somebody sees it on a real
phone.
