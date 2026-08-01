# Roadmap

## Where we are

| Milestone | State |
|---|---|
| M0 sim core and determinism | Done. Green in CI on x86-64, arm64, and WebAssembly |
| M1 a ship on screen | Done. Web client at 60 fps; flight and energy confirmed by playtest |
| M1.5 prizes and inelastic walls | Done, added after that playtest |
| M2 server authoritative | Done. Peak prediction error 0.9 px at 150 ms, 11 KB/s per client |
| M3.5 AI opponents | Done server-side: input-only bots, labeled, taking and yielding seats |
| M4 rating and modes | Done: damage ledgers, attribution, and the warzone flag game |
| M4.5 duels | Done, offline and networked |
| M5 zone operator surface | Done: zone.toml, live reload, bans, capabilities, persistence |
| M5.5 Defold client | Done: real core as a native extension, builds for host and browser, plays offline and networked |
| M6 meta-layer | Done in code: calibrated bot ladder, visible tiers, touch controls, zone directory and server browser |
| M6 platforms | Blocked on accounts, not on code. See below |

What M6 asked for that is code has landed. The bot ladder is calibrated by
an offline tournament and seeds every zone; ratings show as tiers once a
pilot has earned one; the client takes touch input; and a directory service
lists live zones for a server browser built into the client.

What remains is not engineering. Steam needs a partner account, consoles
need manufacturer approval, and Nakama needs somewhere to run Postgres.
Nakama would replace `persist.rs` -- storing and ranking a number -- and not
`rating.rs`, because damage-weighted attribution across several attackers is
specific to this game and no general backend has an opinion about it.

The Defold client is the production one; `client-web/` remains the prototype
that proved the networking contract, and the two now share it. Both link the
same C core, so neither can drift from the rules.

M6 needs a Steam partner account, console manufacturer approval, and a
Postgres deployment for Nakama. Those are credentials and decisions rather
than engineering, so the milestone waits on somebody making them.

The rest of this document is the original plan, kept as written.


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

The eight classes from [design/ships.md](../design/ships.md) defined entirely by
configuration, the full weapon set, prizes, energy and recharge, specials. Freqs
and spectator mode. Chat. Real art for the ships and the first pass at the audio
direction, since programmer geometry stops being adequate once eight classes
have to be told apart at speed.

Done when a 16-player playtest runs for an hour without a desync, when every
class is identifiable by silhouette at radar scale, and when the settings
importer can read a real `arena.conf` and produce ships that behave the way that
file describes.

## M3.5: something to fight when nobody is online

AI opponents that emit inputs through the same path as human clients: perception
from the snapshot visibility filter, utility-based behavior, inertia-aware
flying, and the archetypes and skill parameters in
[design/ai-players.md](../design/ai-players.md). The population director that
fills an arena and yields to arriving humans.

Done when a solo player joining an empty arena gets a fight worth having, when
bots leave without anybody noticing the seam, and when forty bots cost under a
millisecond per tick.

Placed here because every milestone after this one is easier to test with bots
than without, and because the first external playtest will have more empty
arenas than full ones.

## M4: a game, not a sandbox

Flag and ball modes as sandboxed zone modules, with the adviser hooks the
modules need. Scoring, kill rewards, bounty, and persistence to SQLite. Lag
measurement and the four-threshold response.

Damage ledgers and the rated event log start here, since rating is computed from
events this milestone already produces. Ratings themselves stay hidden until
there is enough data to trust them.

Done when a warzone-style flag game and a powerball game both run as modules,
with no game-mode logic in the sim core or the server.

## M4.5: duels

One on one against a rating-matched bot or human, per
[design/duel-mode.md](../design/duel-mode.md). Ephemeral arenas from a duel
template, the ruleset as a zone module, an in-zone matchmaking queue with rating
and latency bands, practice duels against any bot difficulty, and match replays
from the input log.

Done when a new player can go from launch to a fought duel in under a minute
with nobody else online, and when a replay of that duel plays back frame-exact
from a few kilobytes.

Duels come before the meta-layer because they are the cheapest test of the module
API, the cleanest rating signal we can collect, and the onboarding path for every
player who arrives before the game has a population.

## M5: a zone somebody else can run

Zone directory layout, settings reload without restart, map and overlay
delivery, a server browser, identity, capabilities, bans, and the operator
metrics listed in [server.md](server.md). Bot API and one reference bot.

Done when somebody who is not us runs a zone from a release artifact and a
written guide, and hosts a game we did not design.

## M6: platforms and the meta-layer

Steam release through `extension-steam`, with Steam identity feeding the account
system. A touch control prototype that decides whether mobile is a playing
client or a spectating one. Nakama adopted for identity, friends, parties,
leaderboards, and the zone directory, per
[decision 11](decisions.md).

Ratings become visible here, computed from the event log M4 has been filling and
anchored by bot personalities calibrated in offline tournaments, per
[design/rating.md](../design/rating.md).

Done when a player's name, friends, and rank follow them across zones, and when
the Steam build and the web build share an account.

Consoles come after this, if at all, and only once
[platforms.md](platforms.md)'s moderation question has an answer.

## Ongoing from M2

The determinism harness runs on every commit, across every ABI we ship to.
Bandwidth per player and tick duration per arena are recorded on every playtest
and tracked over time, because both degrade quietly and both are architectural.

## Deliberately deferred

Console builds, which need manufacturer approval, certification work, and a
policy for community-hosted content.

Lag compensation by rewinding the server, which we only add if M2 says shooting
feels wrong.

A Continuum compatibility gateway, which stays a proposal in
[decisions.md](decisions.md) until there is a game worth connecting to.

Anything resembling progression, an economy, or a persistent world.
