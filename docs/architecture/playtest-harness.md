# The playtest harness

A program that plays the shipped game the way a person does: through the real
client, over a real WebSocket, against the real server, with a keyboard or a
thumb, for hours at a time. It exists to find the bugs that live in the seam
between client and server, and to produce session-shaped evidence about
balance and dullness that no shorter test produces.

This is a design. Nothing below is built yet except the pieces credited to
other documents.

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

One command stands everything up on localhost. The server binary already
plays its three roles from three first arguments, exactly as deployment runs
it: a directory on port 9000, an arena, and the bot server. The wasm bundle
comes from `client/build.sh wasm-web` plus `single_file.py` and is served by
any static file server. Chromium, driven by Playwright, loads the page.

Two facts make this cheap. The client's directory default is already
`ws://127.0.0.1:9000`, with `menu.defaults(name, dir)` there to point a build
anywhere else, so a local page finds a local fleet with no configuration and
no certificate. And the opposition problem is already solved: the bot server
fills the room with the same pilots that fly the live fleet, so one browser is
enough to make a full match.

The harness lives in `harness/` at the repository root: Node, a pinned
Playwright, and the run scripts. It spans client and server, so it belongs to
neither tree.

## The probe

The GUI is meshes and text. There is no DOM to query and no accessibility
tree, which is the same corner every game engine paints testers into, and the
industry answer is the right one here: the client publishes its own state.

The web shell already carries a family of `vw*` bridge functions between page
and engine. The probe is one more: the Lua side keeps a small state report
fresh in a JS global, and the driver reads it with `page.evaluate`. The report
carries what a player could state about their own screen:

- which screen is up, which stop or panel, and where the cursor is
- what a press at the cursor would resolve to, in the `M.pick` sense
- whether the pilot is in a room, and the roster as drawn
- own ship as drawn: alive, energy, position, current hull
- the tick, the frame clock, and the link state
- the touch pads' hit boxes, when the pads are up
- the last Lua error, if any

The probe is the client's testimony about what it is showing. It answers only
in game terms, never in pixels, and it is armed by a query parameter on the
page so the shipped bundle carries the code but spends nothing when nobody is
reading. Nothing in it is secret; it is the player's own view of the world.

The rule that follows, learned once already on the roster press: every
assertion reads the probe or the server, never a screenshot. What a press
resolves to is a fact; that a box exists is not. Screenshots and video get
attached to failures for the person who reads them.

## Input

Input goes in as real browser events, never as calls into Lua, because the
input path is much of what is under test.

The desktop profile types with Playwright's keyboard against the real binds.
The mobile profiles run Chromium's device emulation and send touches through
CDP, and the driver aims taps at the pad boxes the probe publishes, which is
what a thumb does. Four profiles cover the matrix, and every journey runs on
all four:

- desktop, 1280x800
- desktop short, the window height where the landing lies down into its rail
- phone portrait, 390x844 at 3x, touch
- phone landscape, 844x390 at 3x, touch

A real phone stays a manual spot check. Emulation covers layout, orientation,
touch, and pixel ratio, which is where the functional bugs are; it does not
cover thermals or Safari, and pretending otherwise would be false comfort.

## The drivers

Three drivers share the stage and the probe, in increasing looseness.

Journeys are scripted walks: boot to a joined match inside a time budget;
every landing stop opened and backed out of; settings changed and the change
observed; hull changed mid-session; leave and rejoin; the guest path and the
account path. They are the smoke test, and they are quick.

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

- a Lua error, an engine error, or a console error
- a disconnect nobody asked for
- a stalled frame clock or a stalled tick
- a probe invariant: in a match implies a roster; a press must resolve to
  what the journey expects; a screen the walker cannot leave
- disagreement between client testimony and server truth: the harness holds a
  side channel to the arena (the metrics surface, or a spectator connection)
  and compares the probe's account of the own ship against the server's, with
  tolerance for snapshot delay. This is the oracle for the DESTROYED-on-a-
  healthy-fleet class, which no single-sided test can catch.
- soak curves: JS heap, frame time, and message rate sampled over hours, with
  monotone growth a failure

Every failure ships its evidence: the probe trace, the input log with its
seed, video of the last minute, and the server's log for the same window.

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

Locally, one command runs any driver, and Chromium can run headed when you
want to watch it play. In CI, the journeys run on all four profiles on any
push touching `client/**` or `sim/**`, in minutes, beside the existing gates.
The monkey and the player run nightly for hours and publish their artifacts.

The soak targets localhost only. The live fleet gets humans; pointing an
input-fuzzing browser at production would test the wrong thing and bother
real players while doing it.

## Build order

1. The walking skeleton: stage up, page loaded, one keyboard journey from
   boot to a joined match, sixty seconds of flight, every oracle armed. This
   is the proof that the stage, the probe, and one driver hold together, and
   it is worth shipping before anything else grows.
2. The probe filled out, the touch profiles, and the journeys as a CI gate.
3. The monkey, nightly.
4. The player, the server-truth oracle, the soak curves, and the counter
   report.
