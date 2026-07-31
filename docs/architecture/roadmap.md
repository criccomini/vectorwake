# Roadmap

Ordered by risk retired per week of work, not by what is satisfying to build.
The three things that could invalidate the architecture are cross-platform
determinism, the feel of server-authoritative shooting, and whether Defold can
draw the world at 60 fps. All three appear in the first three milestones.

## M0: the core moves a ship

A `sim_state` with one ship, thrust, rotation, top speed, and tile collision.
No networking, no client, no server. A command-line harness that replays an
input file and prints state hashes.

Done when the determinism harness runs the same trace on Linux x86-64, Linux
arm64, and WebAssembly and produces identical hashes at every tick, in CI.

This is first because decision 2 is the load-bearing one, and if fixed-point
determinism across those three targets is impractical we want to know in week
one rather than in month six.

## M1: a ship on screen

Defold client with the sim core as a native extension. One ship, keyboard
input, a camera that follows, a tilemap window over a real converted `.lvl`, and
a HUD showing energy.

Done when the ship feels right to somebody who has played Subspace, and when the
web build runs at 60 fps with the camera moving fast.

Feel is a subjective gate and it belongs here anyway. If frictionless flight
with our numbers does not feel like the original, everything downstream is
premature.

## M2: two players, server authoritative

Zone server with one hard-coded arena. UDP for native, WebSocket for web,
inputs up, snapshots down, client prediction with rollback for the local ship,
interpolation for the remote one. Bullets that the server resolves.

Done when two clients on 150 ms of simulated latency and 3% loss can dogfight
and it feels fair, and when a state hash comparison between server and client
shows no divergence outside the prediction window.

This is the milestone that tests decision 1. Server-authoritative shooting with
a revoked hit is the single largest departure from the original, and it either
feels acceptable here or the design changes.

## M3: an arena worth playing

Eight ships defined by configuration, the full weapon set, prizes, energy and
recharge, specials, and the settings importer reading a real `arena.conf`. Freqs
and spectator mode. Chat.

Done when a 16-player playtest runs for an hour without a desync, and when a
Trench Wars settings file imports and produces ships that behave like the ones
it describes.

## M4: a game, not a sandbox

Flag and ball modes as sandboxed zone modules, with the adviser hooks the
modules need. Scoring, kill rewards, bounty, and persistence to SQLite. Lag
measurement and the four-threshold response.

Done when a warzone-style flag game and a powerball game both run as modules,
with no game-mode logic in the sim core or the server.

## M5: a zone somebody else can run

Zone directory layout, settings reload without restart, map and overlay
delivery, a server browser, identity, capabilities, bans, and the operator
metrics listed in [server.md](server.md). Bot API and one reference bot.

Done when somebody who is not us runs a zone from a release artifact and a
written guide, and hosts a game we did not design.

## Ongoing from M2

The determinism harness runs on every commit. Bandwidth per player and tick
duration per arena are recorded on every playtest and tracked over time, because
both degrade quietly and both are architectural.

## Deliberately deferred

Mobile clients, though the Android target stays in reach through Defold.

Lag compensation by rewinding the server, which we only add if M2 says shooting
feels wrong.

A Continuum compatibility gateway, which stays a proposal in
[decisions.md](decisions.md) until there is a game worth connecting to.

Anything resembling progression, an economy, or a persistent world.
