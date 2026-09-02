# harness

Plays the game. The real client in a browser, against a real directory, arena
and bot server on loopback, driven the way a person drives it.

    cd harness && npm install
    node bin/vwplay.mjs journeys

[docs/architecture/playtest-harness.md](../docs/architecture/playtest-harness.md)
is the design and the argument for it. This file is how to run it.

## What it needs

- **JDK 25**, because bob 1.13.0 is compiled to class file 69. If `JAVA_HOME`
  points at an older one the harness says so rather than letting bob fail with
  a class file version nobody reads the first time.
- **A server binary.** `cargo build --release --manifest-path server/Cargo.toml`.
  A debug build is used if that is all there is.
- **Chromium**, from `npx playwright install chromium`. It has to be the
  build the pinned playwright drives, which is why the package comes from
  the `npm install` above and has to resolve out of the registry: a
  container that already has playwright installed globally can end up
  linked to that copy, which puts a path only that container has into
  `package-lock.json`. CI installs from the lockfile and gets a dangling
  link, and `npx` with no local playwright then fetches whatever is newest
  and lays down a browser the harness cannot drive.
- **python3**, for the packer that folds the bundle into one file.

## Running it

```sh
node bin/vwplay.mjs journeys                     # every journey, all four windows
node bin/vwplay.mjs journeys --profile desktop   # one window
node bin/vwplay.mjs journeys --flight 5 --verbose # a short flight, while iterating
node bin/vwplay.mjs journeys --headed            # watch it play
node bin/vwplay.mjs journeys --rebuild           # force a fresh client build
node bin/vwplay.mjs journeys --video             # record each run
```

The client is rebuilt when anything under `client/` or `sim/` is newer than the
last page it built, and reused otherwise, so iterating on a driver does not pay
two minutes a run.

The four windows are desktop, a short desktop (where the column has least room
to stand in), and a phone in portrait and landscape. Desktop plays with the
keyboard; the phones play with a thumb.

## When it fails

Everything it knew goes to `client/dist/harness-runs/<journey>-<profile>/`:

- `failure.json`: the fault, the journey's log, the client's last full account
  of its own screen, anything the client reported through its own error
  channel, the browser console, and every server's log for the same seconds.
- `failure.png`, and `end.png` on a pass.

Read `last_reading.boxes` first. Each entry is a control the client published,
and `hits` is what a press there would actually fire. A row whose `action` and
`hits` differ is covered by something.

## How it works

`bin/vwplay.mjs` is the front door. Under `src/`:

- `stage.mjs` runs the fleet: a directory on 9700, an arena on 9701, the bots,
  and the page on 9702. No meta-layer, so no accounts and no database;
  everybody flies as a guest. The arena's metrics are on 9703, which is the
  only second opinion on the stage.
- `build.mjs` builds the client from the working tree with the stage's own
  directory address baked in, and packs it the way CI packs what it publishes.
- `pilot.mjs` is one browser: real key and touch events in, the client's own
  account of its screen out.
- `oracles.mjs` is what makes a run a failure.
- `journeys/` are the scripted walks.

## The probe

The client publishes what it is showing into `window.vwProbe`, from
`client/arena/probe.lua`. It is off unless something sets `window.vwProbeHz`
before the engine boots, which the harness does with an init script. Not a
query parameter, deliberately: nothing in a URL can make somebody else's client
start describing their screen.

Assertions read that, or the server. Never a pixel: the frame is composited on
a GPU and everything on it is moving, so a screenshot can tell you a color and
not whether a press does anything. Screenshots are evidence for a person
reading a failure.

## Two things to know before writing a journey

**A press goes to the box that takes it, not the box that drew it.** `ui.pick`
keeps the first box of the highest priority, and a panel publishes
`panel_hold` at priority 0 before any row, so a row published at 0 afterwards
is unpressable. `pilot.tap(action)` aims only at a box whose own testimony says
a press there fires `action`, and throws naming the thief otherwise. That bug
sat in the roster for weeks.

**Wait for a state, never for a duration.** `pilot.until(what, predicate)`
polls the probe and fails with the client's last account of itself. A sleep
long enough to be reliable on a slow machine is wasted on a fast one, and a
sleep short enough to be quick is a flake.

**A press waits for its control to stop moving.** Panels here arrive by
sliding: a column rises out of the key that raised it and a page climbs up
through the bottom edge, over about a fifth of a second. `pilot.tap` reads the
box, then reads it again until two readings put it in the same place, because
a press aimed at a box read mid-slide lands where that box used to be, which
by then is a different control. Aimed at the second stop of the menu column it
opened the fourth, and did it every time.

## What is not built yet

The monkey and the player, per the build order in the design. And the oracle
that compares the client's account of its own ship against the server's: it is
written, in `agreesWithServer`, and has nothing to ask. Nothing the arena
publishes carries a position, so it wants a spectating connection that decodes
snapshots the way `tools/pilot` does. What the stage can answer today is
coarser and still real: the arena says how many humans it holds, so a client
that believes it is flying while the arena counts nobody is caught.
