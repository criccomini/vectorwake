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
| M4.5 duels | Built, then removed: deferred until a mode is catalog content |
| M5 zone operator surface | Done: zone.toml, live reload, bans, capabilities, persistence |
| M5.5 Defold client | Done: real core as a native extension, builds for host and browser, plays offline and networked |
| M6 meta-layer | Done in code: calibrated bot ladder, visible tiers, touch controls, zone directory and server browser |
| M6 platforms | Blocked on accounts, not on code. See below |
| M7 the fleet | Designed, not built. The directory, catalog and zone selection below |

What M6 asked for that is code has landed. The bot ladder is calibrated by
an offline tournament and seeds every zone; ratings show as tiers once a
pilot has earned one; the client takes touch input; and a directory service
lists live zones for a server browser built into the client.

What remains is not engineering. Steam needs a partner account, consoles
need manufacturer approval, and Nakama needs somewhere to run Postgres.
Nakama would replace `persist.rs` -- storing and ranking a number -- and not
`rating.rs`, because damage-weighted attribution across several attackers is
specific to this game and no general backend has an opinion about it.

The Defold client is the only client. A hand-written web prototype came first
and proved the networking contract, and it is gone: it stopped compiling when
tiles became typed classes, nothing built it, and nothing noticed for as long
as this history goes back. Its palette and panel geometry live on in
`client/arena/palette.lua` and `client/arena/ui.lua`, which is the part of it
worth keeping.

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
modules need. Scoring, kill rewards, bounty, and persistence. Lag
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

## M7: the fleet

Everything in [zones-and-arenas.md](zones-and-arenas.md),
[catalog.md](catalog.md), [discovery.md](discovery.md) and
[admin.md](admin.md). It is large enough that the order matters more than the
total.

The ordering principle is that every step should leave a running game. Nothing
here is a flag day, because at each stage the previous arrangement still works:
a single zone server with a `zone.toml` keeps playing while the catalog grows
beside it.

**M7.1 through M7.6 are built.** A directory serves a catalog, arena servers
register and choose their own zone, rooms open and close on demand, the client
lists games rather than machines, and an operator can see and steer the fleet
from a page. What remains of M7 is 7.7, durable state leaving the arena, which
is a prerequisite for a second instance of a zone rather than a nicety, and
7.8, the bots leaving the arena process. The descriptions below are kept
because each one states its own done condition, and those are the claims that
were checked.

**M7.1, the catalog as a file.** Parse `catalog.toml` and `zones/<name>/zone.toml`
with the validation table from [catalog.md](catalog.md), and make a zone server
able to load a named zone out of it instead of reading one `zone.toml`. Nothing
registers with anything yet. Done when `mode` and `flags` are read rather than
ignored, which retires the oldest dead keys in the file, and when a bad catalog is
refused with a reason rather than half-applied.

**M7.2, registration.** The wire format, the token table, TLS on the directory,
callback verification, and the `VIEW` push. The directory stops reading a
hand-written address list. Arena servers still serve one fixed zone. Done when two
arena servers on different hosts appear in one directory's browse reply within a
second of starting, and when a killed process is delisted as fast.

**M7.3, the client picks a game.** The browse reply carries zones with instances
underneath, and the client's server browser lists games rather than servers,
preferring its own region and the fullest room below the cap. Done when a player
picks Chaos and lands on the busiest Chaos room without knowing an address.

**M7.4, zone selection.** The algorithm, the constants, `INTENT`, the drain path,
and the state machine's failure edges. This is the step that can herd, so it wants
the test below rather than a playtest. Done when ten arena servers booting at once
against a four-zone catalog distribute without piling onto one zone, and when
killing every directory leaves every room playing.

**M7.5, rooms on demand.** More than one simulation in a process, sharing a map,
created as players arrive and reclaimed as rooms empty, capped by the zone's
`max_rooms`. This is where the fill ladder's second rung lands. Done when a duel
zone grows to a hundred rooms in one process at the memory
[hosting.md](hosting.md) predicts, shrinks back as matches end, and refuses the
hundred-and-first rather than growing past the cap.

**M7.6, the admin surface.** The static page, the unioned read view, catalog
authoring, and the imperative verbs down the registration socket with
`has_capability` finally gating them. Done when an operator bans a name, drains an
instance and pins one to a zone without touching a shell.

What those done conditions actually produced, since several of them are the kind
of claim worth writing down once rather than re-deriving:

- Ten arena servers started in the same second against the four-zone catalog
  took one zone each and the remaining six stood down, because nothing was
  needy. No zone got two.
- Killing the directory left all four games playing, kept the player who was
  already in Alpha, and a new player could still join an address directly. The
  browse list is empty during the outage, which is the whole of the damage.
- Bringing the directory back re-registered every instance within ten seconds,
  each still serving the zone it had chosen. This needed the retry ceiling
  brought down from a minute to five seconds: an unregistered arena is a game
  nobody can find, so waiting is more expensive than dialling.
- A hundred rooms in one process grew as players arrived, refused the
  two-hundred-and-first, and fell back as they left. RSS went from 8 MB to
  30 MB, which is the rooms plus two connections each rather than the rooms
  alone.
- A duel zone was the original wording of that last one. Duels are out, so it
  was a small-room test zone instead; the shape of the test is the same and the
  ladder does not know what a zone is for.

**M7.7, durable state leaves the arena.** Deferred, but not indefinitely, and the
deadline is structural rather than chosen: `ratings.json` beside the process is
correct while one instance serves a zone and wrong the moment two do. So this has
to land before the fill ladder's fourth rung ever fires in anger, which makes it
a prerequisite for a second instance of any zone rather than a milestone free to
slip. Rated events batched and handed off, and the open question in
[server.md](server.md) closed. Done when two instances of one zone can both rate
the same pilot without disagreeing.

**M7.8, bots leave the arena process.** The `ai` module becomes a crate shared
with the calibration tournament, and a bot server joins the deployment: one
process flying the roster as declared clients, filling every listed room to its
zone's `bot_fill` and standing bots down one for one as humans arrive, per
[decision 29](decisions.md#29-a-bot-is-a-client). The arena keeps only the seat
policy: declared bots sit outside `max_players` and the newest is dropped when
a full room must seat a human. Done when an arena starts empty and is populated
within seconds of the bot server seeing it, when a human joining a room at
target costs exactly one bot, when killing the bot server empties rooms of bots
and nothing else, and when the snapshot cost of a room at target has been
measured and recorded in [hosting.md](hosting.md).

Duels return after M7.1 and M7.5, because they need a mode to be a catalog row
and rooms on demand in a process. They also need spectating, since a queue is
pilots present and not playing. See
[design/duel-mode.md](../design/duel-mode.md) for what came out and what putting
it back requires.

Two things are deliberately absent. Chat is not deferred, it is gone, per
[decision 28](decisions.md#28-no-chat). Spectating is deferred, which also holds
back the gentlest of the four lag actions in [server.md](server.md), so until it
lands a laggy player gets a harsher response than they should.

### What to test rather than to play

Most milestones here are confirmed by playing. Two are not, and they are the two
most likely to fail quietly in production and not in a playtest.

Herding needs a harness: N arena servers, a catalog of M zones, a fake directory
that can be made slow or partitioned, and an assertion about the distribution that
results. A herd is invisible with three servers on a laptop and obvious with
thirty in a deploy.

The eventually consistent view needs a partition test: two directories that
disagree, an arena that can see one or both, and an assertion that no arrangement
of stale views makes an instance flap between zones while occupied. Rule one says
it cannot, and rule one is worth a test rather than a promise.

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
