# Decision records

Each record states what we decided, why, what it costs, and what would make us
change our minds. Status is `accepted`, `proposed`, or `superseded`.

---

## 1. The server is authoritative over damage and death

**Status:** accepted

Subspace has the victim's client send a death packet naming its killer, and the
server validates only that the named killer exists and is in the same arena.
Positions are relayed rather than verified. This is why the game ran on a 1997
modem and why cheating was rampant enough that Continuum was written to fight
it.

We simulate weapons and damage on the server. A client asserts inputs and
nothing else.

**Cost:** Hits are confirmed a round-trip late, so a shot that looks like it
connected can be revoked. Bandwidth rises, since the server must send projectile
state rather than trusting clients to agree.

**Reconsider if:** the revocation is visible enough at 150 ms to hurt the feel,
in which case we look at server-side lag compensation rather than at giving
authority back.

---

## 2. One deterministic simulation, shared by client and server

**Status:** accepted

The alternative is two implementations, one in Lua for prediction and one on the
server for authority. Every game that has tried this has spent years chasing
divergence between them.

One C library, fixed point, no floats, compiled into the Defold client as a
native extension, into the server as a static library, and into the web build as
WebAssembly.

**Cost:** Fixed-point arithmetic is more annoying to write than floats. The
client build depends on Defold's build server for the extension. Debugging
crosses a language boundary.

**Reconsider if:** determinism across platforms proves impractical, in which case
the fallback is floats plus tolerance-based reconciliation, which nullspace
demonstrates is close enough to feel right.

---

## 3. The simulation core is C99

**Status:** accepted

Defold's build server compiles extension sources for every target it supports,
including WebAssembly, and what it compiles is C, C++, Objective-C, Java, and
JavaScript, with C# experimental. A Rust core would need prebuilt static
libraries for every platform, produced and maintained by us.

The core also has the profile where C's dangers are smallest: no allocation, no
parsing, no strings, no untrusted input, fixed-size arrays.

**Cost:** C in 2026, with the tooling and the footguns that implies.

**Reconsider if:** Defold's C# or Rust support matures to the point where the
build matrix is not ours to own, or if the core grows features that make manual
memory management a real risk.

---

## 4. The server is a separate Rust program, not headless Defold

**Status:** accepted, with a prototype exception

Defold can build a headless variant and people do run game servers with it. It
would share every line of client code, which is genuinely attractive for a first
prototype.

For production it is the wrong tool. A zone server wants long uptime, sandboxed
extension modules, a database, hundreds of connections, and predictable memory,
and Defold's runtime is built around a game loop and a Lua VM with unspecified
component update order. Rust gives us memory safety exactly where untrusted
input arrives.

**Cost:** Three languages. A second build system. No code sharing with the
client outside the sim core.

**Prototype exception:** milestone 1 may use headless Defold to get a playable
loop faster, provided the sim core is already separate so the switch is a
transport rewrite rather than a rewrite.

---

## 5. Defold owns presentation only

**Status:** accepted

Defold's manual states that component update order within a collection is
unspecified, and HTML5 builds run Lua 5.1.4 rather than LuaJIT. Game state
distributed across game object scripts would therefore have neither a defined
evaluation order nor adequate speed on our most important platform.

Game state lives in one `sim_state`. Defold draws it.

**Cost:** We give up most of what an engine's scene graph offers for gameplay,
and we write our own object pooling and view management.

**Reconsider if:** never, in this form. This is the load-bearing decision.

---

## 6. Zone modules are sandboxed

**Status:** superseded

No module runtime or module ABI was built. Current modes are compiled Rust
implementations selected by `zone.toml`, and `ModeCtx` is a direct internal Rust
surface rather than a boundary that WebAssembly could consume. Adding sandboxed
modules now would require a new ABI and a new authoring system, not merely a new
host for the existing trait. The proposal below is kept as the original
decision.

ASSS loads native modules with full process access, and its manual states
plainly that such a module can crash or deadlock the server. That model produced
an enormous body of zone content, so the extensibility is proven and the safety
is not.

Modules run as WebAssembly with a fuel limit per tick, no filesystem, and no
network, using ASSS's adviser pattern so a module can edit or veto core events.

**Cost:** Slower than native calls, and a build step for module authors that
plain C did not need. Mitigated by hosting a Lua interpreter inside the sandbox
for authors who want Lua.

**Reconsider if:** the per-tick sandbox overhead is a measurable share of the
budget at 100 Hz.

---

## 7. Our own protocol, not Continuum's

**Status:** accepted

Speaking Continuum's protocol would let existing clients connect immediately,
which is a serious answer to the cold-start problem for a multiplayer game.

It also imports `i16` pixel coordinates, a fixed settings struct, eight ship
slots, 40 headings, and a security model built on executable checksums. And it
is incompatible with decision 1, since the protocol's death packet is
client-authoritative by design.

Closed as accepted alongside decision 12: everything since this record was
written (server authority, the rating system, the no-clone identity) leans on
owning the protocol, and the gateway cannot coexist with decision 1.

**Cost:** No existing players on day one. The AI players in decision 14 are the
mitigation.

**Reconsider if:** never for the main protocol. A read-only spectator bridge for
Continuum clients could be revisited as a curiosity, nothing more.

---

## 8. Simulation runs at 100 Hz

**Status:** accepted

Subspace's tick is a centisecond, and every published zone setting expresses
delays, costs, and recharge rates in those units. Matching it makes the settings
importer exact and makes weapon timing behave as authors expect.

**Cost:** Twice the server work of 50 Hz, and a rollback buffer twice as deep.

**Reconsider if:** profiling says the tick is the bottleneck, and only before
the settings importer ships. After that, halving the tick means reinterpreting
every imported setting and rebalancing every playtest result, and the answer is
to optimize the step instead.

---

## 9. Fixed-window tilemap rendering

**Status:** superseded

A 1024x1024 tile map is a million tiles, and we should not assume a single
Defold tilemap component handles that. A tilemap sized to the viewport plus a
margin, rewritten at the edges as the camera moves, bounds the cost by perimeter
rather than by area.

**Cost:** Rewriting tiles during fast camera movement may cost more than
expected.

**Reconsider if:** measurement says the window stutters, in which case a custom
render script drawing tiles from an atlas replaces it.

**Superseded:** no tilemap was ever built. The art direction went to vector
geometry rather than sprites, which took the question with it: there is no atlas
to draw tiles from and nothing to rewrite at the edges. The client meshes the
terrain around the camera into two static layers and uploads them when the camera
walks far enough, so what survives of this record is the window, not the tilemap.
The window sizes itself from the drawable now rather than from a constant.

---

## 10. Ship browser, desktop, mobile, and eventually consoles

**Status:** accepted

Defold reaches all of them: HTML5, Windows, macOS, Linux, Android, iOS,
Nintendo Switch, PlayStation 4 and 5, with Xbox announced. Console builds are
free but gated on being an approved developer with the manufacturer, who then
authorizes a private plugin and a build server token.

Priority is browser first, desktop through Steam second, mobile third, consoles
last. [platforms.md](platforms.md) has the reasoning and the per-platform
constraints.

**Cost:** The browser has no UDP, so we serve two transports forever. Consoles
impose certification and content moderation obligations that shape the server
browser. Mobile needs a control scheme nobody has solved well for this kind of
flight.

**Reconsider if:** the touch prototype fails badly enough that mobile becomes a
spectator client, which changes nothing architecturally but changes the roadmap.

---

## 11. Nakama for the meta-layer, never for the arena tick

**Status:** proposed, adopt around M5

Nakama is an Apache-2.0, self-hostable game backend on Postgres with
authentication across device, email, and social providers including Steam,
friends and groups, chat, leaderboards, tournaments, a matchmaker, storage,
parties, and notifications. It has an official Defold client written in Lua 5.1
that uses HTTP and WebSocket, so it works everywhere Defold does. That is a
large amount of infrastructure we would otherwise write badly.

It is the wrong place for an arena. Nakama's authoritative match loop runs
between 1 and 60 Hz, and we simulate at 100. Match handlers are written in Go,
TypeScript, or Lua, none of which is our C core; a Go handler could reach it
through cgo, but it would still inherit the tick ceiling and the transport.
Realtime delivery is WebSocket-centric with guidance of roughly one message per
tick per presence and a 1500-byte message ceiling, which does not fit our
snapshot, delta, and priority model. And it would cost native clients their UDP.

So: our zone server keeps the arenas, and Nakama gets identity, friends,
parties, leaderboards, tournaments, and the zone directory, if and when we want
those. Not chat: there is none, per
[decision 28](#28-no-chat).

**Cost:** A second backend to run, a Postgres dependency, and two authentication
paths to keep consistent.

**Why not now:** at M0 through M4 we need none of it, and an unused dependency
is a tax. The architecture already treats identity as an opaque token the
session layer validates, so adopting Nakama later is an adapter rather than a
rewrite. That property is worth protecting deliberately.

**Reconsider if:** we catch ourselves hand-writing friends, parties, or
leaderboards before M5, in which case adopt early. Or if the game turns out to
need none of them, in which case skip it.

**Priced, by decision 27:** the tax this record warns about has a number. Nakama
needs PostgreSQL, and a small instance plus managed Postgres runs about $20 a
month against a few dollars for the entire arena fleet, so adopting it early
roughly quadruples the hosting bill and nearly all of that is the database.

**Amended by [decision 25](#25-an-arena-server-chooses-which-zone-it-serves):**
the zone directory is no longer on the list of things Nakama gets. A directory
that holds a catalog, a token table, and a live view of the arena servers is a
piece of our own infrastructure rather than a leaderboard, and nothing Nakama
offers implements it. Identity, friends, parties, leaderboards and tournaments
are unchanged, and keeping identity *out* of the directory process is now
load-bearing: it is what lets directory replicas stay independent.

**Superseded in part by [decision 30](#30-the-meta-layer-is-ours-and-identity-leaves-nakamas-list):**
identity, accounts and ratings follow the directory off Nakama's list, and the
meta-layer is our own service. What survives of this record is its title:
nothing meta ever touches the arena tick. Friends, parties and tournaments
stay deferred, and Nakama remains a candidate for them as a social layer fed
by our identity rather than the owner of it.

---

## 12. Inspired by, not a clone

**Status:** accepted

We inherit the simulation model, the tick and unit vocabulary, the zone, arena,
and freq structure, and the lag response policy. We invent every ship, sound,
sprite, map, tileset, and name.

No asset from Subspace or Continuum enters the repository, including as a
placeholder. The `.lvl` and `arena.conf` importers exist to validate our physics
against a known reference and their output is not distributed.
[design/identity.md](../design/identity.md) states the rules.

**Cost:** No borrowed art to prototype with, and no ready-made zone content on
day one. Every map we ship, we make.

**Reconsider if:** never. This one is not a tradeoff.

---

## 13. The camera holds a fixed zoom

**Status:** accepted, superseding a fixed extent in tiles

Subspace let a bigger monitor show you more of the map, and arenas fought it
with `MaxXres` and `MaxYres` settings that capped a player's resolution. That
is a workaround for drawing map pixels one to one with screen pixels.

We tried the other way first: a fixed extent in tiles, scaled to whatever the
display was, so a phone and an ultrawide saw the same amount of game. It has
a defect that competitive fairness does not pay for. The scale then depends
on the window, so the same ship is a different size on every screen, the
world stretches as the window changes shape, and hulls authored in pixels are
never drawn at the size they were drawn for.

The camera now holds a fixed zoom -- one world pixel to one screen pixel by
default, `vectorwake.zoom` to change it. A bigger window sees further.

**Cost:** the original's problem, back again. A wide monitor sees more than a
phone, and that is an advantage in a game about who saw whom first.

**Reconsider if:** competitive play cares. The answer then is the original's:
cap the visible extent per zone rather than rescale the world per player,
which keeps a pixel a pixel and puts the limit where an operator can set it.

**Amended: small windows stand back.** The cost above landed hardest where
nobody was looking. A phone in landscape holds under four hundred points on
its short side, so under the fixed zoom it saw a third of the world a
desktop window did while rounds crossed it at the same speed: less a
disadvantage than a different game about being surprised. So the short axis
of the view is now guaranteed 640 world pixels. A window already showing
that keeps zoom one, untouched, and a smaller one backs the camera off
until it holds 640, down to a floor of 0.6 past which the hulls stop being
readable and the shrink stops. The rule reads only the window's size, the
same fact the fixed zoom already read, so there is no device sniffing and a
desktop browser squeezed to phone proportions gets the same relief. Ships
on a phone draw at about two thirds of authored size, which the vector art
survives; it is the trade the whole amendment is, sharpness of one ship
against sight of the room. The rule lives in `client/render/zoom.lua`, and
`zoom_test.lua` pins what each kind of window sees.

**Tried and dropped: a phone keeping its ship pointing up.** The view turned to
the flying ship's heading, so the nose stayed at the top of the screen and the
world turned underneath. Built behind a setting, flown, removed.

What is wrong with it is not the turning, it is that a camera can turn the view
and cannot turn the velocity. This game is inertia: coast north, flick east to
line up a shot, and the world slides across a nose that is not moving that way.
A fixed view shows the same fact as a nose swinging off a steady drift, which is
the easier of the two to read, and reading it is most of the skill. The turning
view also spends a phone held at face distance rotating the whole field every
time the pilot steers, and it costs the arena the frame's circumcircle rather
than the frame, since a turned frame reaches into corners its width and height
do not describe.

The control it was built with outlived it, though not by long. The turning view
had no direction left on the glass to point at, so it needed a d-pad, and the
d-pad was kept afterward as a second steering setting beside the stick, on a
north-up screen like everybody else's. Both that and the reverse that came with
it are gone now. One push of a thumb meant one thing on the pad and another on
the stick, and on the stick it changed again while the guns were up, so a phone
flies with the stick alone. Reverse came back later as a stance the pilot sets
rather than a push the stick reads into, which is
[decision 88](#88-a-phones-reverse-is-a-stance-not-a-push); the d-pad did not.
See `arena/touch.lua`.


**Status:** accepted

An empty arena is how a new multiplayer game dies. Bots fill arenas until humans
arrive and then leave, per [design/ai-players.md](../design/ai-players.md).

They run inside the zone server, in the arena tick, and their only output is an
`InputCommand` identical to the one a network client sends. Their perception
comes from the same visibility filter that builds human snapshots. There is no
second channel into the simulation, so a bot cannot cheat by construction, and
difficulty is imperfection added rather than permission granted.

Bots are labeled as AI everywhere they appear. A rating system that quietly mixes
bots into a player's record is one nobody will trust.

**Cost:** In-process AI is a server feature with a real CPU budget, and the
behavior layer is a system we have to build and tune. Bots that emit only inputs
are harder to write than bots allowed to set their own position.

**Reconsider if:** never for the input-only rule. The placement is softer: if
zone-authored AI becomes the dominant case, external protocol bots may matter
more than built-in ones.

**Superseded on placement by [decision
29](#29-a-bot-is-a-client).** That reconsideration fired for a reason this
record did not anticipate: not that zone-authored AI took over, but that the
in-process path skipped the protocol, and the protocol is where the bugs were.
The input-only rule survives untouched and is stronger for the move, since a
bot behind the wire has no second channel available to it rather than merely
declining to use one.

---

## 15. Rating is damage-weighted pairwise Elo, stored as an event log

**Status:** accepted, and running

Kills in this game have several contributors and a finisher who may have done the
least. Each death becomes a set of pairwise contests between the victim and each
contributor, weighted by damage share, with damage decaying at the ship's
recharge rate so that healed damage stops counting. The math is in
[design/rating.md](../design/rating.md).

Bots are rated by the same math, which is what lets a player be ranked in an
arena with no humans in it, with one reference personality pinned to a fixed
rating so the bot population cannot drift as a closed system.

Every human-involving rated event is stored with its weights and the ratings
before and after. Bot-only events advance the same rating projection but keep a
compact exactly-once receipt instead of the full payload.

**On model choice:** Elo first because it is explainable. The intended successor
is the Weng-Lin model as implemented by OpenSkill, which is patent-free and
commercially usable. TrueSkill is deliberately excluded: Microsoft licenses it
only for Xbox Live titles and non-commercial projects. Glicko-2 is a free
fallback if rating periods fit better than per-event updates.

**Cost:** Damage ledgers per victim, a human event log that grows forever, and a
model that will need retuning once real data exists.

**Measured, once bots held accounts:** "grows forever" turned out to be set by
the bot population rather than by the players, since bots fight at fill around
the clock. The live fleet writes on the order of 300,000 events a day, which is
40 to 50 GB a year and fills a 25 GB database in six to nine months. Throughput
is nowhere near a limit; space is. Full bot-only rows were first retained for
three weeks, but even that left millions of irrelevant payloads on the weekly
query path. The running design keeps a compact receipt for three weeks and no
bot-only payload, while human rows are kept for good. That is what makes
"stored as an event log" affordable, and it is in [meta-layer.md](meta-layer.md).

**Reconsider if:** the pairwise decomposition produces ratings that disagree with
what good players can see with their own eyes. The event log is what makes that
recoverable.

---

## 16. Duels are an ephemeral arena plus a zone module

**Status:** superseded by [decision 96](#96-duels-are-gone)

One on one against a rating-matched human or bot, per
`docs/design/duel-mode.md`. When a match forms, the server
creates an arena from the duel template under a generated name, loads the duel
module, and unloads the whole thing when the match ends.

No special case in the server. Arenas already load lazily and unload when empty,
and the duel ruleset is exactly the kind of thing zone modules exist for: round
state, spawns, countdown, weapon lockout, win condition, forfeit timer.

This makes duel mode a test of the module API. If the simplest game mode we have
needs a hook the API cannot express, we would rather learn that here than in
powerball.

**Cost:** Ephemeral arenas need name generation, a lifecycle shorter than the
usual grace period, and a matchmaking queue the zone server did not previously
have.

**Reconsider if:** duel matches turn out to need sub-second creation at a rate
that arena loading cannot sustain, in which case a pool of warm duel arenas
replaces creation on demand.

**Deferred, and the code is out.** Duels were built and worked, offline and
networked, and then came out again while the zone and arena model is being
rebuilt underneath them. Keeping a mode alive across that rebuild meant carrying
a duel-shaped hole in every piece of it: a bespoke `C2S_DUEL` message, a second
map generator in the simulation core, a second copy of the ruleset in Lua for the
offline page, and the multi-arena container that existed for nothing else. What
remains of the removal is written up in
`docs/design/duel-mode.md`, which is the plan for bringing
them back once a mode is a row in a catalog rather than a branch in the server.

**Amended by [decision 23](#23-one-arena-per-process):** that reconsideration has
fired. With one arena to a process, an arena per match means a *process* per
match, and the cost is not the launch. It is the setup between launching and
being ready for a player: TLS to each directory, the registration exchange, the
catalog fetch, and the verification call back, which is a second or more and
several if a container has to be scheduled first. So the warm pool named above
becomes the design rather than the fallback, and a duel arena server runs matches
back to back instead of dying with each one.

The queue moves with it. Pairing players is the one thing
[decision 25](#25-an-arena-server-chooses-which-zone-it-serves) leaves nobody in
charge of, and the answer that adds no authority is to hold it inside the duel
arena server, so everyone waiting joins the same one and is paired there. The
ruleset and the module-API argument are unaffected.

---

## 17. Nose aim only

**Status:** accepted

Guns fire where the ship points. Turning is aiming, on every input device.

This is how the original played and it is a large part of the feel we committed
to preserving. It also dissolves the input-fairness problem in
[platforms.md](platforms.md) by construction: mouse, stick, and touch all steer
the same nose, so no input class owns an aim advantage.

It simplifies the wire and hardens it at once. The input command carries buttons
only, no aim heading, so there is nothing for an aimbot to inject aim into
except rotation inputs, which the simulation clamps to the ship's own
`MaximumRotation`. Perfect play is bounded by the ship, not by the mouse.

**Cost:** A higher skill floor than twin-stick players expect. The practice
duels in `docs/design/duel-mode.md` are the mitigation, and
they need to be good.

**Reconsider if:** playtests show new players bouncing off the controls
entirely. Optional mouse aim later is a protocol extension rather than a
redesign, but ship balance would fork the moment it exists, so late is
expensive and reluctance is correct.

---

## 18. Source-available, noncommercial license

**Status:** accepted 2026-08-10, PolyForm Noncommercial 1.0.0 in `LICENSE.md`.
The licensor it grants on behalf of is named in decision 137.

The intent: anyone can read the code, contribute to it, and run a zone. Nobody
but the project can sell it or profit from it. That is not OSI open source; it
is source-available with a noncommercial grant, and saying so plainly costs
less than being accused of pretending otherwise.

PolyForm Noncommercial 1.0.0 was chosen over BUSL-1.1 with an Additional Use
Grant: it is purpose-built for exactly this grant, with no conversion
machinery. BUSL's change date converting to Apache-2.0 carried a standing
promise of eventual open source that a community raised on GPL'd ASSS would
value, but also more moving parts.

Contributions require a CLA granting the project commercial rights. Without
one, the first outside contribution would bind the project under its own
noncommercial terms and forfeit the Steam release. That CLA does not exist
yet, so the license is ahead of the machinery it needs.

**Cost:** Some contributors only touch OSI licenses and will pass. The
"noncommercial" boundary has fuzzy edges (donation-funded zones, tournaments
with prizes) that the final text has to address explicitly.

**Reconsider if:** counsel advises differently, or if the contributor pool the
license costs us turns out to matter more than the exclusivity it buys.

---

## 19. A tile is its behavior, not a number in a tileset

**Status:** accepted

Map tiles carry a behavior class -- empty, solid, safe, door, goal, wormhole,
over, under, turf -- in the low nibble of a byte, and a variant in the high
one. The variant is a door's channel or a goal's team.

The original encoded behavior in the tile's own value: 1 through 160 were
walls, 162 through 169 doors, 171 a safe zone, 176 through 190 scenery you
flew under. Every rule in the engine was a range check against a constant, a
map editor had to know all of them, and the 160 wall values existed to say
which *picture* to draw -- a rendering concern welded into the simulation.

Nine classes replace 190 numbers because appearance is not in the list. What
a wall looks like is the client's business.

**Cost:** No compatibility with `.lvl` files. A converter has to map tileset
indices onto classes, and the 160 wall pictures collapse to one class, so a
converted map loses its look until the client is given a way to vary it.

**Reconsider if:** a mode needs per-tile behavior the nine classes cannot
express, in which case the variant nibble is the place to look before adding
a tenth class.

## 20. One menu: the home screen and the pause screen are the same tree

**Status:** accepted, replacing an earlier version of this decision that had
the client land in an offline practice arena and open the menu only while
flying

The page opens on the menu, at the root, with a starfield behind it. It asks
three things, all of them optional: which hull, which call sign, which game.
Escape opens the same tree over a live arena, where every row means what it
meant on the way in. One list at a time, five inputs, a stack behind it, and
nothing pauses while it is open.

The single difference between the two is whether there is a game behind the
panel. When there is not, the menu cannot be closed, because closing it would
leave a player on an empty starfield with no way back. That is one flag,
`menu.home`, and it is the whole of the special case.

What this replaced was a client that flew its own game. Landing in a practice
arena meant the client carried a roster of eight bots and about three hundred
lines of AI shadowing `server/src/ai.rs`, and the two drifted: bounded sight,
the reserve retune and the bomb-band rule were each fixed twice, once on each
side. It also meant a second full screen, the zone browser, with its own draw
path and its own input handling, reachable only from inside the game it
existed to leave. Folding the browser into the tree as a level deleted that
screen, and deleting the practice arena deleted the second copy of the AI. The
live fleet is what practice is now: Chaos is a room full of the server's bots,
which are the ones that get maintained.

Five inputs is what a d-pad has and what a phone can draw, so the same tree
serves keyboard, touch and, later, a console, without a second layout.

**Cost:** no connection, no game. A build with nothing behind it now shows a
list of games it cannot reach, where it used to be playable on its own, so a
published artifact can no longer be a demo of anything (see `docs/
architecture/deployment.md`). The arrow keys drive the menu while it is open,
so a ship coasts while its pilot reads: opening it mid-fight is a risk rather
than a timeout, and a player can die during it. A hull change inside a zone
goes through the server (`C2S_SHIP`) and is not predicted, so it arrives a
frame late, and it is refused unless you are alive and at a full bar.

**Reconsider if:** the game wants a single-player mode on its own terms rather
than as a fallback for a missing server, at which point it is a game mode with
a design, not an empty arena the client fills with a copy of the server's
bots. Or if a level needs more than a list, a map preview or a keybind grid,
at which point the single-column stack stops being enough and the answer is a
second row kind, not a second layout.

## 21. A weapon is two table rows, not a kind

**Status:** accepted

Everything that leaves a ship is one model. A *fire pattern* is what pulling a
trigger makes -- how many projectiles, how far apart, at what cost, with what
recoil. A *spec* is what one projectile is -- how it flies, what ends it, and
what happens where it ends. A hull's gun and bomb are pattern indices, and
that is all a hull knows about weapons.

The original has bullets, bombs, bursts, repels, decoys, thors and mines as
seven systems. They differ along eight axes -- spread, bounce, proximity,
splinter, level, freezing, through-walls, repel -- and none of those is a kind
of weapon. Building the space instead of seven points in it collapses the
seven into rows, and gives away the combinations between them: a bomb that
repels, a bullet that stalls a bar, a bouncing shrapnel shell. `docs/design/
weapons.md` has the recipes.

A spec's `splinter` names another pattern, and that recursion is what makes
shrapnel free: a bomb whose ending is a burst. The update loop is four phases
in order -- it runs out, it moves, something ends it, the ending happens -- so
every difference between a bullet, a bomb, a mine and a fragment is a number
read during those phases rather than a branch between them.

Because a spec is an *index*, the table has to travel: a zone sends its whole
settings block to every client at join, straight after the map. Both ends
compiled the same baseline before this, which held only for as long as no zone
overrode anything -- a raised top speed measured as 11 px of peak prediction
error against 1 px once the settings were on the wire.

**Cost:** two more bytes on every projectile in every snapshot (`left` bounces
and splinter `depth`, both spent as it flies, both needed by a client that
predicts). A recursion that has to be bounded by hand, because nothing in a
table stops a fragment naming the pattern that made it -- one generation, and
the cap lives on the projectile. An indirection: reading what a hull fires now
means two table hops instead of a field. And 1.2 KB at join, plus a version
byte that will refuse an old client outright rather than let it play a game it
half understands.

**Reconsider if:** a weapon needs a genuinely new verb rather than a new
number -- homing, charging, chaining -- at which point the question is whether
it is a fifth phase or a different system, and the answer had better be the
first one.

## 22. A weapon has a level and a set of add-ons, and they are different things

**Status:** accepted

A *level* is the same weapon harder: a rung on a ladder of patterns the hull
carries, swapped in when a prize climbs it. An *add-on* -- multifire, bounce,
proximity, shrapnel, freeze, repel -- changes the weapon's character, and is a
**transform applied to that rung at the moment of firing** rather than a row of
its own.

The split is forced by arithmetic. Three levels against six on/off add-ons is
192 patterns for one weapon and the table holds 64, so precomputing every
combination was never available. Composing at fire time costs one function and
gives away every combination for free, including the ones the original never
had: bombs that repel, bullets that stall a bar.

That makes the whole tech tree one shape -- a count with a ceiling. A stat
count interpolates a range, a level count indexes a ladder, an add-on count
transforms a shot, and a charge count is inventory you spend. Which charge is
*ready* is deliberately not in there: the client picks a slot and sends it in
two spare button bits, so selection costs no snapshot byte and no edge
detection in a function that gets replayed. One flat prize
space, one byte on a green, one table for a zone to weight.

Add-ons are per trigger, so "bounce on guns, shrapnel on bombs" is a thing a
pilot holds. Each hull's row says which it may ever have, which is what keeps
the roster a roster once greens are flying: no run of luck turns a skirmisher
into a bomber. (Superseded twice over: greens went in decision 34 and the hull
rows in decision 50.)

Greens carry no type, and what one turns out to be is rolled where it is
picked up, from what that hull could ever hold. Typing them at spawn filled
the arena with greens that refused two thirds of the players -- and the roll
covers what the hull can hold rather than what it can still take, so a pilot
at the ceiling is told what they found and simply does not move.

**Cost:** two more bytes on every projectile in the snapshot, because a shot
has to carry the add-ons it was fired with -- reading them off the owner would
disarm a bomb already in the air when its owner died. Four more on the pilot.
And you cannot choose which green to chase: they are identical on the map,
which is the price of every one of them being worth taking.

**Reconsider if:** an add-on wants a magnitude that is not a number and not a
pattern. Shrapnel already needs a per-rung pattern rather than a per-rung
integer, and a second of those would mean the transform table has outgrown
being a table.

---

## 23. One arena per process

**Status:** proposed

A zone server hosts exactly one arena: one map, one mode, one tick loop, one
simulation. Many arenas means many processes, and the fleet is horizontal.

This reverses the shape we inherited from ASSS, where one process holds every
arena and players move between them without reconnecting. The reason is that
almost everything the multi-arena process buys us has to be built, while
everything the flat model buys us comes from the container platform for free.
Named arenas, template resolution by name prefix, per-arena configuration files,
arena groups sharing score intervals, lazy loading, unload grace periods, a
worker pool and a scheduler to assign arenas to threads are all described in
[server.md](server.md) and none of them exist. Under one arena per process none
of them ever need to.

It also answers that document's own open question about process isolation in the
direction that needs no code. A wedged arena takes down only itself, and the
supervisor that restarts it is whatever already restarts containers. Resource
accounting per arena stops being a metric we compute and starts being a number
the platform reports.

Players see zones rather than servers, which is the user-visible half: Alpha,
Chaos, War and Duel are things you join, and which arena server you land on is a
routing detail. See [zones-and-arenas.md](zones-and-arenas.md).

**Cost:** Population stops being one social space by construction. Zone-wide
chat and instant arena switching were free when one process held everything.
Moving rooms becomes a reconnect, and chat is not rebuilt at all, per [decision
28](#28-no-chat), which is a subtraction this record helped force. That is a
real regression against the original and against what [server.md](server.md)
promised. Duels lose their cheap ephemeral arena, per the amendment to [decision
16](#16-duels-are-an-ephemeral-arena-plus-a-zone-module). And a small zone that
would have been one process is now a directory plus at least one arena, which
raises the floor on running your own game.

**Reconsider if:** zone-wide social presence turns out to matter more to players
than elastic capacity does, or if the process-per-room overhead stops being
noise at the population we actually reach.

**Amended: rooms per process is a property of the zone.** That last
reconsideration fired as soon as anybody measured. A room is 107 KB, because the
map is shared by pointer rather than copied, and it steps in 1.8 microseconds at
two ships and 16.4 at sixty-four, which is 610 to 5,500 rooms per core. So a
thousand concurrent duels is 107 MB and a fifth of a core, and insisting each one
gets a process would mean a thousand of everything: runtimes, TLS stacks,
registration sockets, container overhead.

The strict form of this record conflated three things that were never the same:
a room is one simulation, a process is one OS process, a host is one machine
somebody bills you for. Only the first two were ever coupled, and the numbers say
even that should be a setting. So the catalog carries `max_rooms` per zone: a
ceiling on simulations in one process, with rooms created on demand up to it and
reclaimed when they empty. War says one, because a 64-player room deserves its own
blast radius and its own memory. Duel says a hundred, because the rooms are tiny
and share a map. Same binary, same registration, same autonomous zone selection;
only the number of simulations inside the process differs.

Dynamic rather than fixed, because a process configured for a hundred duel rooms
should not hold a hundred while four are busy. The cap is what keeps that honest:
growth inside a process is bounded memory and a bounded blast radius, and
unbounded growth would turn one popular zone into an out-of-memory kill that takes
every room in it down together. It also gives the concentration rule a second
rung, since a process grows a room before the fleet grows a process; the ladder is
in [zones-and-arenas.md](zones-and-arenas.md).

This does bring back a container of rooms inside one process, which is what
[decision 16](#16-duels-are-an-ephemeral-arena-plus-a-zone-module)'s removal
deleted. The difference is that it is now configuration read from the catalog
rather than a duel-shaped special case in the server. See
[hosting.md](hosting.md) for the measurements and
[zones-and-arenas.md](zones-and-arenas.md) for how a zone declares it.

---

## 24. An arena registers with a directory, and a token names its pool

**Status:** proposed

Arena servers push. Each connects to every directory it knows over TLS, presents
a token, and holds the socket open; the listing lives as long as the connection.
This replaces a directory that reads a hand-written address list once at startup
and polls it every ten seconds.

The credential is a row in a table rather than one shared secret, and the row
carries the name. A single shared password stops strangers registering but does
nothing about a credentialed party registering *as somebody else*, which is
precisely how the original's directory filled with duplicates and junk: it
believed whatever a zone said about itself. Because the name comes from the
directory's side of the table, impersonation is structurally unavailable rather
than merely discouraged. One row authorises a pool of instances with an instance
cap, which is what makes scaling out a replica count.

The old poll survives with a new job. Push establishes that an arena is alive and
how full it is; it cannot establish that the address the arena reported works, or
that anything there speaks our protocol. So the directory calls the claimed
address back and requires a well-formed status reply before listing it, which
closes the redirect and lets an operator move hosts without asking for a new
credential.

Details, including the message tables and what a directory may relay, are in
[discovery.md](discovery.md).

**Cost:** Credentials to issue, rotate and revoke, where before there were none.
TLS on the directory, which today binds a bare `TcpListener`. Tokens that want to
live outside the arena's config file, since that file is what an operator pastes
into a bug report. And a listed-but-down arena stops being a row a player can
see, which the current code deliberately shows.

**Reconsider if:** we ever want an open, unauthenticated public list, at which
point the question is what stops it filling with junk, and the honest answer is
probably an account rather than a token.

---

## 25. An arena server chooses which zone it serves

**Status:** proposed

No scheduler assigns work. Each directory tells its registered arena servers
what it has observed itself; each of them unions those reports, deduplicates by
instance id, keeps the most recent observation of each, and decides for itself
which zone to serve. Clients decide for themselves which arena server to join.
The directory observes and reports; the edges decide.

The alternative we rejected was assignment, which reads as simpler until two
directories assign the same instance two different zones. Fixing that needs one
authority, which needs election or shared state, which is the coordination the
flat model was supposed to buy us out of. Autonomy costs a herding problem
instead, and a herding problem can be blunted locally.

Four rules do the blunting. Only an empty arena server chooses, so a change of
zone never disconnects anybody and drain time rate-limits decisions. An arena
server opens a new instance of a zone only when every live instance of that zone
is above its fill target, because five War rooms of four players is worse than
one of twenty and declining to scale is the hard half of autoscaling. Decisions
are jittered, then announced and re-read before committing, which is carrier
sense with backoff. And region is a preference rather than a constraint.

Zone definitions are the exception: the catalog is a versioned artifact with one
author, deployed identically to a deployment's directories, and an arena server
takes the highest version it is offered and logs a mismatch rather than voting
on it. Configuration management, not agreement.

**Cost:** Eventually consistent scheduling, so transient over- and
under-provision is normal and a fleet will sometimes hold two half-full rooms for
a few minutes. The announce-and-backoff step is a lock protocol over an
eventually consistent channel, which is worth naming rather than discovering. And
a directory's view is only as complete as its registration overlap, so
every arena wants to register with every directory.

**Reconsider if:** a fleet reaches the hundreds of instances, where backoff starts
doing serious work and a leader begins to look cheap by comparison.

---

## 26. The admin surface writes configuration, not commands

**Status:** proposed

One web UI, and it does two separable things. It reads the same view an arena
server reads, unioned across a deployment's directories, which makes the whole
observability half a second consumer of a protocol that exists. And it edits the
catalog, producing a new version that flows to directories and then to arenas by
the path already built for it.

Bans, a zone's map and settings, fill targets, staff and their capabilities are
all edits rather than commands, and treating them as edits puts the central
thing in the right place. The authoring side is central for *authorship* and not
for *runtime*: if it is down, directories keep serving the version they hold and
arena servers keep serving the zone they chose. Nothing stops. Backing the
catalog with git makes the audit trail free.

The genuinely imperative actions, kicking a player and draining, pinning or
restarting an arena, travel down the registration socket that already exists,
scoped so a directory may only command arenas registered with it. No arena needs
an admin listener of its own. Two directories can still send conflicting pins, so
a pin is sticky local state with last-write-wins and it is displayed with who set
it and when, which turns a conflict into visible operator error instead of a
protocol problem.

This is also the first caller for `has_capability`, which has sat in `config.rs`
with tests and no invocation because there has never been a command channel to
gate. See [admin.md](admin.md).

**Cost:** A human-held credential with fleet-wide reach, which wants better than
a token in a file before it is exposed publicly. A second UI to build and keep,
in HTML rather than in the client, because our client draws vector art and text
on purpose. And imperative actions get no audit trail from the catalog, so they
need logging at both ends.

**Reconsider if:** operators end up wanting to script the fleet more than click
it, in which case the catalog wants an API and a CLI before it wants more
buttons.

---

## 27. Vultr for everything, in Docker, with the database bought

**Status:** accepted

Arena servers, directories and Nakama all ship as Docker containers on plain
Vultr instances, with Vultr's managed PostgreSQL behind Nakama. One vendor, one
API, one bill.

The choice is driven by a measurement rather than a preference. Compute for this
game rounds to nothing: 200 concurrent players is four rooms and under one
percent of a core. Egress does not: at 30 KB/s per client it is 75 GiB a month
per concurrent player, so the hosting question is only ever who sells bandwidth
cheaply, in enough places, with the least operational work.

Vultr wins or ties on every axis that matters. Thirty-three regions in nineteen
countries against DigitalOcean's twelve, including the South America, Japan and
Africa coverage that a latency-sensitive game wants and DigitalOcean has none of.
Managed Postgres at $15 a month in all of them, so the database sits beside
Nakama wherever Nakama sits. Plain instances with their own public addresses, so
Docker with host networking behaves, UDP for native clients survives, and a
client can connect straight to the arena server the directory named without a
proxy in the way. And tooling as straightforward as DigitalOcean's, which is the
simplicity half of the requirement.

Two candidates lost on the database rather than the price. Hetzner is the cost
champion, with 20 TB of European traffic included for about five dollars, and
sells no managed Postgres at all. OVHcloud has unmetered bandwidth in Europe and
North America, which is structurally the best possible answer to an
egress-dominated bill, and charges $64 per node per month for managed Postgres
against Vultr's $15.

Fly.io lost on three counts recorded in [hosting.md](hosting.md): reaching a
named machine from a browser needs a `fly-replay` bounce because a browser cannot
set headers on a WebSocket handshake, `fly-replay` is HTTP-only so per-machine
UDP addressing is unavailable, and egress at $0.02/GB is ten to thirty times the
alternatives. Its fast machine starts optimize an operation we barely perform,
and its anycast region steering duplicates what the directory already does.

Buying the database rather than running it is the one place "Docker for
everything" bends, and it bends for a reason: arena servers and directories hold
nothing, so losing one costs capacity, while the identity and rating database is
the only thing here whose loss cannot be repaired by rebuilding. A container on a
bind mount would turn one instance into a machine we can never lose.

**Cost:** metered egress, which is the dominant line. Roughly $50 to $100 a
month in transfer at 200 concurrent players where unmetered bandwidth would cost
five, and about $1,400 against $8.50 at two thousand. Australia is charged at
$0.10/GB, ten times the North American and European rate. And the meta-layer is
now the expensive part: a small instance plus managed Postgres is around $20 a
month against a few dollars for the entire game-serving fleet, which puts a
number on [decision 11](#11-nakama-for-the-meta-layer-never-for-the-arena-tick)'s
warning about unused dependencies.

**Reconsider if:** the egress line gets annoying, at which point the answer is
additive rather than a migration. An OVHcloud pool carries European and North
American volume while Vultr keeps the regions OVHcloud cannot reach and keeps the
database, because a pool already carries a provider and a region and arena
servers from several pools serving one zone is the normal case. Australia is the
first place that pays off. If bandwidth ever becomes existential rather than
annoying, the only structural escape is a provider that does not charge for
egress at all, and that means a room living somewhere like a Durable Object and a
rewrite this project should not want.

---

## 28. No chat

**Status:** accepted

vectorwake has no chat. Not a deferred chat, not chat behind a flag: the game does
not carry text between players.

This is the largest deliberate subtraction in the project, and it needs saying
plainly because the original's social layer was substantially chat. Zone-wide
messages, private freq coordination, the mod channel, and the bots that lived on
all of it are most of what made a Subspace zone feel like a place.

Three things make the subtraction survivable rather than merely cheap. The
architecture no longer wants it: one process held every arena in ASSS, so chat
across a population was free, and [decision 23](#23-one-arena-per-process) spread
the population across processes, which means chat would now be a hub in the middle
that has to be up. Whatever we most want to be able to lose, a chat hub is the
opposite. The game reads without it, because flight, bounty and the feed already
carry what a fight needs to communicate, and the moment-to-moment vocabulary of
this game is manoeuvre rather than talk. And the thing we would be building is not
a message router, it is moderation: reporting, muting, blocking, appeals, logs,
and somebody to read them.

That last point is the real one. Text between strangers is a moderation
commitment, permanently, and it is the commitment this project is least equipped
to keep. [platforms.md](platforms.md) already gates consoles on having an answer
to it, and this decision is that answer: there is nothing to moderate.

**Cost:** The game is less of a social space and more of a sport, and some players
will bounce off that immediately. Team coordination in a flag game has to happen
through play, which caps how organized a team can be and changes what the mode
should ask of them. No zone bots, which the research notes identify as where most
zone identity lived. And any future league or clan scene will organize on Discord,
which means the community's real home is somewhere we do not control.

**Reconsider if:** the answer is a bounded channel rather than a general one.
Fixed phrases, a ping wheel, or team-only signals cost no moderation because there
is nothing unsafe to say, and they recover most of the coordination a flag game
wants. That is a different feature from chat and it would get its own record.
It did: [decision 51](#51-six-phrases-and-no-way-to-add-a-seventh) is six
phrases on the podium between matches, which is the smallest version of this
that is worth anything. Nothing about it changes what is written above: no text
reaches the server, nothing can be aimed at a person, and there is still
nothing to moderate.

**Cascades:** [decision
11](#11-nakama-for-the-meta-layer-never-for-the-arena-tick) no longer wants
Nakama's chat. The client's `chat.gui` and the server's chat throttling, module
`send chat` hook, and reliable-message chat class all come out or never go in.

---

## 29. A bot is a client

**Status:** proposed

The house AI moves out of the arena server into a bot server: one process per
deployment that flies many bots, each a WebSocket connection decoding
snapshots through the sim core and sending the same input messages a human
client sends. The arena keeps no bot code, only a seat policy: a bot declares
itself in `C2S_JOIN`, is labeled in the roster, takes no seat under
`max_players`, and is dropped first when a full room must seat a human.

[ai-runtime.md](ai-runtime.md) placed bots inside the arena tick for cost, and
the cost it named was sockets, encoding and round trips that a same-host
deployment does not pay: the fleet is containers on one box, so bot traffic is
loopback. What in-process bots actually cost was coverage. This deployment's
real bugs lived on the protocol path, which the resident population never
touched: the pong stranded on the wrong half of a split stream, found by a
harness because browsers never ping; the recharge overflow at `INT32_MIN`,
seen only by a client decoding snapshots. In-process bots also made "bots
cannot cheat" a code-review property, and their scan read true server state,
which would have seen through cloak the day cloak existed. Behind the protocol
the guarantee is structural: a bot has nothing to read but the filtered
snapshot the server chose to send.

It is also one bot system instead of two. The old design kept an in-process
path for filler AI and promised a protocol path for third parties. Now the
third-party path is the only path, kept working by the fact that our own
roster has no other way in. The JOIN declaration plus a fleet credential
separates trust: anyone may declare a bot and be labeled, and only an
authenticated house bot anchors the rating ladder.

**Cost:** The arena builds an interest-filtered snapshot stream per bot where
the in-process roster needed none, and that build was expensive enough to have
been optimized once already. Measured before shipping the fill target, on a
64-seat room at 0.8: the arena's worst tick costs 314 microseconds of its 10
millisecond budget, and the bot server costs 14% of a core and 15 MB for 51
bots. So 0.8 stands. The numbers and what drives them are in
[hosting.md](hosting.md).

An empty deployment also needs two processes before a room has a population,
where one used to do, so the dev loop grows a compose entry. It is the same
binary under a different first argument, as the directory already was, which
also settles where the brain lives: one program cannot drift from itself, so
the calibration tournament and the live bots are guaranteed to be the same
code without a crate boundary to arrange.

**Reconsider if:** snapshot building at fill-target populations eats the tick
budget and per-client interest filtering cannot be made cheaper, or a
multi-region fleet makes a bot server per region more operational surface than
an in-process director was.

---

## 30. The meta-layer is ours, and identity leaves Nakama's list

**Status:** proposed

[Decision 11](#11-nakama-for-the-meta-layer-never-for-the-arena-tick) adopted
Nakama for everything durable outside the arena tick. That list has been
shrinking ever since: the directory left with
[decision 25](#25-an-arena-server-chooses-which-zone-it-serves), chat with
[decision 28](#28-no-chat), and friends, parties and tournaments are wanted by
nobody yet. (Friends were wanted for a while and were built, on this
meta-layer rather than on anybody's; they came out again with
[decision 95](#95-friends-are-gone). Parties and tournaments never were.)
What remains that we need now is identity, and our identity has
shapes Nakama does not: accounts minted silently on first contact, bot
accounts with owners, a human, bot, or unknown label derived from credential
shape, session tokens carrying rating claims that arenas verify offline, and
transactional rating settlement no general backend has an opinion about.

Meanwhile the cost argument collapsed. Decision 27 priced Nakama at roughly
$20 a month and observed that nearly all of it is Postgres, and this design
buys that Postgres anyway. On top of a database we still had to schema
ourselves, Nakama would add an authentication layer, and the authentication we
actually want, bearer secrets, account keys, platform identities later, is
small.

So the meta-layer is `vectorwake-server meta`: a fourth subcommand of the one
binary, on managed Postgres, holding accounts, credentials, names, the human
event log, compact event receipts, the rating projection, and fleet bans. It
issues signed session
tokens that arenas verify with a key distributed in the catalog, it refuses
tokens to banned accounts, and it ingests the rated event batches that arenas
submit under their pool credential. [meta-layer.md](meta-layer.md) is the
design, and [design/accounts.md](../design/accounts.md) is the account model.

This also closes the handoff question in [server.md](server.md): rated events
go to the meta-layer rather than the directory, because the directory is the
piece we most want to be able to lose and the rating state is the piece we can
least afford to.

**Cost:** Authentication becomes our security surface: token signing, secret
storage, and every sharp edge auth code has. And a second stateful service to
operate, though its state is the database we were buying regardless. What it
deliberately does not cost is external infrastructure: claiming runs on
account keys and link codes, so there is no mail sender and no OAuth
registration, and vectorwake.net's mail-free DNS stands.

**Reconsider if:** friends, parties or tournaments become real wants, where
Nakama re-enters as a social layer fed by this identity rather than the owner
of it. Or if authentication outgrows a small service, with passkeys, SSO, or
console certification requirements, at which point the thing to buy is an
identity provider rather than a game backend.

---

## 31. Every pilot is an account, and bots hold them too

**Status:** proposed

First contact mints a guest account and the client keeps its secret, so play
never waits on a signup and rating accrues from the first death. Claiming
attaches an account key, a generated secret the player keeps, or a platform
identity where the platform forces one, several to one account, and there are
no passwords anywhere. Names come from the call sign generator only, and a
claimed account's name is reserved fleet-wide.

Every seat wears one of three labels, derived from account shape rather than
asserted by the client. A bot account is a bot, house or third-party. A
claimed human account is human. A guest is unknown, because the server cannot
know and refuses to guess. Third-party bot accounts hang under a claimed owner
who answers for them, and a join whose declaration disagrees with its account
kind is refused.

Fleet bans mark the account and are enforced at token issuance, per
[decision 30](#30-the-meta-layer-is-ours-and-identity-leaves-nakamas-list).
The full design is [design/accounts.md](../design/accounts.md).

**Cost:** Honest newcomers wear the same unknown label as anyone hiding a bot,
until they claim. Guest rows accumulate at one per drive-by page load.
Smurfing is free by construction, bounded by placement convergence rather than
prevented. And the roster message grows a label field every client must
render.

**Reconsider if:** playtests read unknown as an accusation rather than a plain
fact, in which case the label needs softer words rather than different
mechanics. Or if unclaimed churn makes ratings in the low tiers meaningless,
at which point rated play may need an `admission` bar of `claimed` by default.

## 32. Teams are named doors with sizes

**Status:** proposed

A team is a name, a door, and a size, and nothing else. Public teams are the
zone's: operator-named, stable across rounds, scored by the mode. Private
teams are the players': founded from the menu, named by a generator, entered
by invitation from any member, dead when empty. Three settings shape a room's
teams, `max_teams`, `max_humans_per_team` and `max_bots_per_team`, and the
only refusal a player can meet is a full team. The simulation keeps its team
byte; names ride the roster like call signs. Changing teams is gated like
changing hulls: alive, full bar, a respawn that drops flags and clears earned
bounty. Free-for-all stops being `teams = 1` with ship-index-as-side and
becomes settings: everyone a team of one, pact size capped. The bot server
prefers the short side, inside its cap, so human choices never strand one.

This adopts the original's freq structure and drops its addressing: freqs
were numbers because the interface was a chat box, and this client has no
text input. It also rejects two designs considered on the way. Passwords for
private teams lose to invitations, which need no keyboard and do not leak. A
relative balance invariant, refusing moves that widen the human gap past one,
loses to plain caps: it needed a case table, froze legal swaps, and could
deadlock two players who both wanted to cross, all to prevent a stacking that
bot backfill, pairwise rating, and a low cap in a zone that cares already
bound. The full design is [design/teams.md](../design/teams.md).

**Cost:** Stacking inside the caps is legal, and a generous cap plus an
indifferent operator makes lopsided rooms. No kick means an unwelcome pilot
is shed by everyone else migrating, which respawns them all and reads odd the
first time a player sees it. And stable public names are one more thing an
operator must write before a zone feels finished.

**Reconsider if:** playtests show pacts dominating free-for-all rooms even at
small caps, which argues for pact-versus-pact scoring rather than smaller
pacts. Or if migration-as-exclusion becomes a griefing ritual in itself, at
which point a founder's kick is the smaller evil after all.

## 33. The original's keys, where the browser permits them

**Status:** accepted

Test players asked for Continuum's controls. Continuum fires guns with Ctrl
and bombs with Tab, and the pair cannot be given to a browser tab: gun held
plus bomb tapped is Ctrl+Tab, the tab switcher in Chrome, Firefox and Safari
alike, acted on before `preventDefault` is consulted; and macOS takes Ctrl
with every arrow for Spaces and Mission Control at the window server, so a
Mac player holding the authentic gun key cannot steer at all. This is also
the second attempt: the first shipped Ctrl and Tab on day one and retreated
inside the day, but retreated all the way to Space and Shift instead of to
the nearest keys the browser leaves alive.

So the layout is the original's wherever a key survives, and the nearest
safe key where one does not. Arrows fly and Tab bombs, both Continuum's own
and both verified against the deployed engine, which keeps the canvas
focused straight through held Shift+Tab. Guns sit on Shift: the same left
pinky as Ctrl, one row up, and a modifier, which keyboards wire on their own
matrix lines, so the layout cannot ghost the way arrows-plus-Space could.
Digits spend charges by row of the corner stack, the keyboard catching up to
the touch pads, which have named their slot directly all along, and the
ready-and-cycle model went with the catching up: a selection is a thing to
have forgotten to move, and with every control naming its own charge there
is nothing left for one to do. The rows wear their digits in the corner
stack, C and V are unbound, and the whole of spending is "press the number
you can read". WASD is gone, arrows are flight, and every held-Ctrl letter
chord that a browser owns dies with it.

Fullscreen gives the literal keys back. The fullscreen action requests the
Keyboard Lock alongside, and a *held lock*, not fullscreen itself, is what
turns Ctrl into a gun: Firefox fullscreen still switches tabs on Ctrl+Tab,
and the lock API needs a JS-initiated fullscreen, so F11 counts for nothing.
Unlocked, Ctrl does nothing at all, which is the honest reading of a key the
browser owns half of; a Ctrl that fired windowed would spring the tab
switcher on exactly the veterans it was courting, and one that still spent a
charge would be worse. Windowed play stays first-class, because this game's
ancestor was a chat program with a dogfight attached, and its players are
the alt-tab-to-Discord crowd.

**Cost:** windowed guns are one key from authentic, and the fullscreen Ctrl
is Chromium's to grant, so Firefox and Safari never get the literal key.
Existing testers' Shift finger fires guns where it fired bombs. Tap-firing
Shift five times is Windows' Sticky Keys chord, mitigated by guns being held
rather than tapped and by Space and Z remaining. Shift+Esc opening Chrome's
task manager over the menu is unverified on hardware, as is whether the lock
beats Mission Control's claim on Ctrl+arrows on a Mac.

**Reconsider if:** hardware testing shows the lock losing Ctrl+arrows to
macOS anyway, at which point the fullscreen promise shrinks to Windows and
Linux and the help text should say so. Or if a rebinding screen ever ships,
at which point this whole layout becomes the default rather than the rule.

**Amended: one key per job, and the charges move to the letters.** The layout
above handed guns four keys and bombs two, on the theory that whichever one a
player's hands already knew would be there waiting. What it built instead was a
board where half the lit keys were aliases of each other, and a drawn keyboard
that lights six keys for two weapons does not tell anybody what to press. Shift
and Z are gone from the guns, leaving Space and, under the lock, Ctrl. X is gone
from the bombs, leaving Tab. Sticky Keys stops being a hazard along with them,
since nothing a fight needs sits on a modifier now.

Charges moved off the digits and onto Q, W, A and S. A hand flying with the
arrows has its other hand on the letters, and the number row is a reach away
from there, so "press the number you can read" cost a glance down at the
keyboard to find the number. The four letters are a square block under that
hand: read across and then down, which is the order the corner stack lists its
rows in, and the fingers never leave home.

Multifire took the backquote key, Q having gone to the first charge. It is a
switch you flip between fights rather than something pressed during one, so the
far corner of the board suits it, and it is bound as both KEY_BACKQUOTE and
KEY_TILDE because the two legends are one physical key and which of them the
engine reports through a browser is not something we could check without
hardware. The help page draws it, along with the rest of this: the key picture
is now the whole answer to what the controls are.

**Cost:** everyone who learned Shift or Z for guns and X for bombs has to
unlearn them, and this is the second time that has happened. Q was multifire
for a week and is a charge now, which is the same key changing hands rather
than a key going away, so a habit that survives the change fires the wrong
thing rather than nothing. And Space is the only gun a windowed player has,
where there used to be three.

---

## 34. WebTransport beside the WebSocket, never instead of it

**Status:** accepted

The networking file measured what TCP costs the game: at 150 ms and 3% loss,
a snapshot stall every 1.4 seconds, worst case 307 ms, entirely in the tail,
because a lost packet holds hostage everything delivered behind it. The
protocol was designed around that weakness from the start, which meant the
cure was always going to be cheap to adopt: the messages already divide into
what must arrive and what a newer message supersedes, so a transport with
independent streams and datagrams carries them unchanged.

Adopted now because the reasons to wait ran out. Every current browser ships
WebTransport, a maintained Rust crate serves it, and the client's half is one
extension over the browser's own API. The zone gains a QUIC endpoint on its
own UDP port; reliable messages ride one bidirectional stream, snapshots ride
datagrams or a unidirectional stream each, inputs ride datagrams. The server's
connection handler reads whole messages from a queue and cannot tell the doors
apart.

The clause after "beside" is the decision's actual content. Enough networks
silently eat UDP that QUIC can only ever be offered, not required, so the
directory advertises both addresses, the client tries the better door for
three seconds and takes the socket without a word, and every player is a
WebSocket player on the networks that insist. The fallback is also the safety
net that lets the advertised WebTransport address go unverified where the
WebSocket address is proven by the directory before it is offered.

**Cost:** the arenas hold a certificate for the first time, read out of
Caddy's store through a glob and a reload timer, which is a coupling to
Caddy's directory layout that a Caddy upgrade could move. Three public UDP
ports and their firewall rules exist because of it. And the client carries a
reorder guard the socket never needed, because independent lanes can hand a
snapshot to the game after its successor.

**Reconsider if:** live metrics show almost nobody lands on the QUIC door, in
which case the certificate coupling and the ports are rent paid on an empty
room; or the correction sizes the open questions list is waiting on turn out
indistinguishable across the two wires at real latencies.

---

## 35. A password on the name you already hold

**Status:** accepted

Decision 31 claimed accounts with a generated key and ruled passwords out on
the grounds that a password table is a liability. The key shipped, and it
carried the liability's weight without its familiarity: twelve characters
nobody could remember, a card begging them to write it down, a clipboard
module built for one string, and a link-code flow beside it for the devices
where typing hurt. Meanwhile the call sign, the one string every player
already knows, was doing no work: decorative, suffixed on collision, unique
only after a claim happened to reserve it.

So the two trade places. Names are unique from birth, dealt by the server and
never accepted from a client, since whoever proposes a name chooses it and a
curated register is only safe while the server curates. Claiming is choosing
a password for the name you already hold; logging in elsewhere is typing the
pair; rerolling is a server draw that leaves the account number, and so the
record, in place. Guests still cost nothing and now expire after a quiet
week, handing the name back to the pool. The layers beneath do not move: a
password's only job is to obtain a per-device secret, and the secret's only
job is to obtain a fifteen-minute token that arenas verify offline.

**Cost:** a password table, argon2 rather than sha256, and throttles on the
two routes worth hammering, which is the surface decision 31 declined. No
reset flow, said plainly at the claim: a forgotten password is a lost pilot,
because the alternative is a mail sender and vectorwake.net's mail-free DNS
is worth more. Existing key-claimed accounts lose their way in and revert to
claimable, which the empty fleet makes free today and would not tomorrow.

**Reconsider if:** the first lost Wake-tier rating makes "no reset" untenable,
where the answer is a passkey or a platform identity as a second credential
rather than email.

---

## 36. The roster is seven hulls, and the Shark has no counterpart

**Status:** accepted, superseding an eighth hull

Every hull here answers to one of the original's ships, and seven of those
answers came out of a preserved settings file: the Warbird's rotation and
thrust, the Javelin's speed, the Spider's opening recharge, the Leviathan's
three-rung rack, the Terrier's double barrel, the Weasel's
EMP and its bombs that never break up, the Lancaster's wall bounce. Each is a
line in that file and each is a line in a zone here.

The Shark was never one of them. That file has seven ship sections and no
`[Shark]`, so the Spire was built instead from the reference server's own
`dist/conf/svs/ship-shark`, and it took a single number: `ShrapnelMax=31`
against everyone else's 8, which landed as the top rung of shrapnel and made
the Spire the only hull in a zone that could reach it.

That number is wrong. The legacy configuration this project reads its
settings from gives the Shark `MaximumRotation=280`, `MaximumThrust=19` and
`MaximumEnergy=1750`, with `ShrapnelMax` at 8 like every other ship: a hull
that turns and pushes almost as hard as the Warbird and carries a little more
energy, and has no shrapnel distinction at all. The modern copy has drifted,
and the drift is exactly on the one ship we had nothing else to go on.

So the Spire had a gimmick it should never have had and lacked every number
that made the Shark a Shark. It could have been corrected to the legacy
values. It is withdrawn instead, and the roster is seven.

The reason to withdraw rather than repair is that the Spire was never carrying
its own weight. Its design role was support: turrets, best recharge, the hull
a team forms around. Turrets do not exist here and there is no per-hull
recharge ceiling, so nothing of that role was ever built. What shipped was a
generic ship with one borrowed number, wearing a description of a ship that
does not exist. Correcting the number would have made it an agile hull with
no reason to be agile; the honest move is to stop claiming the archetype
until something is built for it.

**Cost:** a player who flew the Spire loses it, and the class byte of every
hull after it moves down one, so a remembered hull choice reads as its
neighbour once. The one-to-one mapping to the original's eight ships is gone,
which was a tidy thing to be able to say. `docs/design/ships.md` keeps support
on its list of open questions rather than pretending six roles cover seven.

**Reconsider if:** turrets get built, or a per-hull recharge ceiling does, at
which point there is a role for a hull to fill and the Shark's real numbers
are recorded above to start from. Do not re-derive them from
`gigamon-dev/SubspaceServer/conf/svs`: that copy is the drifted one, and it
is what produced the hull this record removes.

---

## 37. The phone's own keyboard, through an element the canvas cannot be

**Status:** accepted, superseding a drawn keyboard

Decision 35 gave the game a password, and a password is the first thing here
anybody has ever had to type. Decision 20's menu was built on the opposite
premise, stated in `menu.lua`: nothing is typed, the name is generated, so a
phone never has to raise a keyboard. The password broke that premise and the
client paid for it with a keyboard of its own, drawn on the canvas: four rows
of cells, a one-shot shift, a rub, and a space bar.

It was drawn because a browser will not raise the soft keyboard for a canvas.
It raises it for a focused editable element and for nothing else, which is
why Defold has no `gui.show_keyboard` on HTML5 (defold/defold#3383) and why
every engine with a web target has the same hole. The fix every one of their
communities converged on is the same: put a real `<input>` over the canvas
and let the tap land on it. Nothing is proxied and no gesture is replayed,
which is where the reputation for fiddliness comes from; the element takes
the press itself and the browser does what it always does.

This client has been here before and it went badly, which is worth stating
because the record of it is still in `menu.lua` and in `client/README.md`: an
address box, an invisible input over the canvas, focus handed back and forth,
enter delivered to whichever of the two held the caret, and after typing the
canvas never got the keyboard back. That was the largest source of bugs the
client ever had. The invisibility is what did it. An element nobody can see
cannot be tapped, so focus had to be moved by hand on gestures meant for
something else and given back afterwards, and every one of those moves was a
guess about what the player wanted. These elements are visible, take their
own tap, and exist only while a card is up. No focus is moved on anybody's
behalf, and there is nothing to hand back.

So the drawn keyboard goes. `ask_card` publishes the rectangles it drew, in
CSS pixels, and the page lays an input on each one wearing the `autocomplete`
word that says which box it is. What that buys is not convenience:

- Autofill. A manager cannot fill a field drawn in mesh, and this credential
  has no reset flow, so a manager is the nearest thing to recovery that will
  ever exist for it. It is also typed once at a claim and once per device,
  which is exactly the frequency at which people forget things.
- Punctuation. The drawn pad reached 63 characters. `type_field` accepts
  printable ASCII and the server accepts any six to sixty four bytes, so a
  password chosen at a desk with a `!` in it was accepted there and could not
  be typed on a phone at all. That was a live lockout, not a limitation.
- Paste, dictation, whichever alphabet the player types in, and a field a
  screen reader can find.

The alternative considered and rejected was to keep the pad and narrow every
password to what it can type. The entropy argument against that is weak: 63
characters against 95 is about half a bit each, which a character of length
buys back, and the pad has a space bar so passphrases were always expressible.
It fails on the manager. Restricting the charset makes a generated password
refused at the claim, which pushes the player onto one they invented and may
not remember, against a credential with no way back.

**Cost:** the type on those two lines is the browser's font rather than the
interface's, on a card that otherwise draws every glyph itself. The client
keeps drawing the label and the rule, so the card is still the card, but the
value sitting on the rule is not ours. Accepted because it is a card seen
twice in a pilot's life and because the alternative is the interface's face
on a field nothing can fill.

**Amended: every browser build, not only the touchscreens.** This shipped as
a touchscreen change, on the argument that a desktop already has the keys and
the drawn line reads in the interface's own face. The face was the smaller
thing. A password manager fills a form and cannot fill a drawing, and this
credential has no reset flow, so the machine where people keep their
passwords was the one still unable to reach the field. The gate is now
whether there is a page at all: browser builds hand the lines over, native
builds draw them.

Unifying deleted more than it added. A paste bridge had been built for the
drawn card, catching the paste event on the canvas and handing the text over
a character at a time, because a canvas cannot be pasted into; a real input
pastes on its own, so the bridge went. So did an exemption in the focus
guards for the space bar, and the clipping the drawn line needed once a
pasted password could be longer than the rule.

Two faults on the drawn card were found on the way and are worth recording,
because both had been there since decision 35 and neither was visible from
the code. The space bar is the trigger, `go` read the trigger, and every call
sign has a space in it, so typing one sent the card partway through the first
line: "Vesper 412" logged in as "Vesper". The desktop card had never been
usable. And a line drew every character it held, so a long password left the
card and crossed the screen.

What the unification costs is keyboard navigation of the answers. While a
line holds focus the engine is sent no keys at all, so left and right are the
caret's now rather than walking the answer row. Return sends, escape takes
the card back down, up and down still walk the lines, and both answers are a
click away, so nothing is unreachable; it is one habit, not a capability.

The engine focuses the canvas from its own mouse handlers, on the way up as
well as down, so the caret cannot be put in the first line while the press
that opened the card is still in flight. It waits for the release. Clicking a
line directly was never affected, because the engine only reclaims focus when
the canvas is what was pressed. When a card comes down the canvas is focused
explicitly, since a card dismissed from the keyboard would otherwise leave
the game deaf to it, which is the address box's failure exactly.

The guards in `single_file.py` had to learn about it. All three exist to keep
a canvas focused in a page it does not own: focus taken on any pointer down,
focus polled for ten seconds, and arrows, tab and space stopped from
scrolling the host page. Every one of them is hostile to a text field, and
the third is worse than hostile: a call sign has a space in it, so "Vesper
412" was typed and "Vesper412" arrived. They now stand down while the focus
is inside the form.

**Reconsider if:** a native build happens, where the platform raises its own
keyboard from `gui.show_keyboard` and none of this is needed; or if the same
elements are wanted on a desktop, which would close the autofill hole there
at the price of the menu's arrow keys, since a focused input is where those
keys would go.

---

## 38. A quit under fire is a death

**Status:** accepted

The rating settles on death: damage accrues in a per-victim ledger, and the
death event consumes it and pays the attackers. A leave dropped that ledger
unsettled. So a pilot losing a dogfight could close the tab and keep the
death off their record while the attackers kept nothing, which made quitting
strictly better than fighting to the end. Games that solved this well make
quitting not work rather than making it expensive: EVE leaves the ship in
space, Left 4 Dead hands it to a bot, fighting games record the loss. The
punishment family, bans and deserter queues, spends population, and
population is the scarce resource here.

A disconnect now settles as a death when the pilot was plausibly about to
die, and as an ordinary leave otherwise. Two conditions, each held where its
facts live. The damage must be recent, three seconds, judged by the rating
from its own ledger; recency is the only gate that layer can hold, because
credit shares are normalized and any nonzero ledger resolves at full weight.
And the tank must be low, forty percent of the hull's effective ceiling,
judged by the room from the ship state; energy is health and escape both and
refills in seconds, so a pilot above the line could as easily have flown
away, and one below it is about one hit from dead. A menu leave and a dropped
socket are treated alike, since intent is unknowable at the socket. The
settlement is exactly-once by construction: the ledger is consumed whichever
of the killing blow or the disconnect lands first, so nothing double-counts.

The sim is not told. No mode hook fires, no bounty pays, the hull vanishes on
the tick as it always did. This is bookkeeping about a fight that already
happened, not a death in the world, and rating is by design not a game rule.
The feed line rides the ordinary kill message, credited to the largest
contributor still seated.

**Cost:** an innocent disconnect mid-fight, the tunnel or the dead battery,
now costs a death. Accepted openly: at the socket it is indistinguishable
from a rage quit, and "you were dead to rights when your wifi died" is the
same bargain every pilot is already under. A pilot who disengages to just
above the energy line and quits escapes judgment; given how fast energy
refills, that pilot could usually have escaped for real, and if people learn
to surf the threshold, lowering one constant is the whole fix.

**Reconsider if:** quitting still looks bad in practice even though it no
longer pays, in which case the next step is leaving the hull flying for a few
seconds, bot-driven per decision 31, so the kill happens in the world where
both pilots can see it. That was deferred, not rejected: it drags in flag
carriage and scoring edges, and the incentive is already gone once the death
is recorded.

---

## 39. The community lives on Discord, and the game only points at it

**Status:** proposed, amended by [decision 73](#73-the-community-door-is-the-sites-not-the-games)

[Decision 28](#28-no-chat) removed text between players and named its own
cost: any future league or clan scene will organize on Discord, which means
the community's real home is somewhere we do not control. This record accepts
that cost deliberately instead of letting it happen to us. We create the
Discord server, own it, and hold its admin keys, and our only connection to it
is pointing at it. Decision 73 moved that pointer off the game and onto the
site; everything else here stands.

The reasoning is the same one that removed chat, run forwards. We refused to
carry text because moderation is a permanent commitment this project cannot
staff. Discord staffs it: reporting, muting, banning, audit logs, and an
escalation path that ends at their trust and safety operation rather than at
us. The commitment we could not keep in the game is one we can keep in a
server, because the hard part is rented.

The integration is one-way by rule. The fleet publishes into Discord, an
invite link, presence, release notes, and never reads from it. No Discord
identity enters the meta-layer, which depends on no external service, and a
Discord user id would break both rules. Nothing in the
fleet waits on Discord or fails when it is down.

The one address that reaches the server is `vectorwake.net/discord`, a Caddy
redirect, so the raw invite lives in one editable line and never in a compiled
client, a cached page, or the README. A leaked invite is rotated without a
build.

[community.md](../design/community.md) is the working form of this record:
the server's ownership and rules, the door, and the staged wire from fleet to
channel.

**Cost:** the community's home is rented, subject to Discord's terms, prices,
outages, and age floor, none of which we set. Running a server is itself a
moderation commitment; the tooling is borrowed but somebody still reads the
reports, which is why the server has more than one admin and written rules
before it has members. And the game's social life happening off the game
means the game must read complete to a player who never joins, which is a
constraint on the game, not just a note about Discord.

**Reconsider if:** Discord's terms or API turn hostile to small games, at
which point the redirect is the moving van: one Caddy line points somewhere
else and nothing shipped needs to change. Or if bounded in-game signals per
decision 28's reconsider clause ever arrive and take enough coordination back
into the game that the server matters less.

**Cascades:** decision 28 stands untouched; its cost paragraph becomes this
record. [platforms.md](platforms.md)'s console gate is unchanged, since
in-game there is still nothing to moderate. The presence bot, when it comes,
wants per-zone population gauges on the directory's metrics page, which do
not exist yet.

---

## 40. Prediction concludes no death but your own

**Status:** accepted

The client's predicted ticks run the whole simulation, damage included, so a
local tick could kill any hull in the room. When the dead hull was somebody
else's, that conclusion rested on the least reliable thing the client holds:
remote ships coast between snapshots, wrong by however much their pilot
dodged inside the gap, while the client's own hull tracks the server to half
a pixel. The result was a full death burst and sound for a kill the zone had
not agreed to, and when it disagreed, the victim popping back onto the screen
a beat later. A false "you got him" changes what the shooter does next, which
makes it worse than a slightly late true one. The kill feed had already
stopped trusting local death events for the same reason, and net.lua's
header claimed the client "decides no hit, no death, no pickup" while the
explosion said otherwise.

Muting the death effect alone would have made it worse, not better: the
local simulation still marked the hull dead, so the ship would vanish in
silence and maybe return, and on a correctly predicted kill the snapshot
would arrive already agreeing, leaving no state change for the late-death
queue to see and no explosion ever drawn. So the rule sits in the damage
path instead. `sim_settings` carries `deathless` and `mortal_ship`, neither
packed nor hashed; with `deathless` set, lethal damage clamps every hull
except `mortal_ship` at one point of energy instead of killing it. The hit
still reports, so the shooter's spark still draws. The server leaves the
fields at their baseline zero and is bit-for-bit unchanged, which is why the
golden hashes did not move. The client names its own seat mortal at each
welcome, and nobody while watching. Every remote death then reaches the
client as a snapshot alive-to-dead transition, and the `snap_deaths` queue,
built for the 15% of kills the prediction used to mistime, now draws all of
them, at the confirmed moment, on the hull the screen was already showing.

The client measures the bargain without changing it. When the deathless core
suppresses a remote death, it records a telemetry signal with no visual or
simulation effect. The signal sits outside the bounded visual event array, so
measurement cannot displace an explosion or sound. The client holds one
candidate per hull and compares it with the next six authoritative snapshots.
A dead hull confirms the candidate;
a hull still alive after all six rejects it. A hull that leaves the interest
window is excluded because its outcome is no longer visible. The debug
readout's `DEATH?` row reports confirmed over settled candidates, followed by
the number still waiting. This supplies the evidence needed before using the
reconsideration below.

**Cost:** the kill burst arrives roughly a round trip plus up to one
snapshot late, which is the standard bargain in server-authoritative
shooters, and the spark keeps the shot feeling connected meanwhile. A hull
the local simulation would have killed keeps flying for that beat and can
absorb a following shot the server never saw; the snapshot corrects it. The
clamp is visible in one place besides the hull itself: the pip over a wounded
ship reads off predicted energy, so a mispredicted kill shows its victim on a
sliver of bar until the next snapshot lifts it back. That is the same
correction every other predicted number gets, on 22 pixels rather than on the
whole screen, which is the trade this record is making. Your own death stays
immediate, and stays a prediction: the rare revival of your own hull is still
possible, but everything feeding that prediction is the most accurate state
the client has.

**Reconsider if:** confirmed-death latency reads as lag on real links, in
which case the next lever is a provisional effect, dimmer than the real
burst, rather than a return to concluding deaths locally.

---

## 41. The admin panel opens with an account flag

**Status:** accepted

`accounts.admin` is a boolean on the meta-layer's own table. An operator
signs in to a static page at `admin.<domain>` with the call sign and password
of their vectorwake account, and every admin route resolves the presented
device secret and checks the flag in the database before acting. The `admin`
field the session reply carries is decoration for the page; nothing a client
asserts about itself is trusted.

Two alternatives were designed and set aside. A signed admin token, minted
and verified by the same process, is ceremony: the signature machinery in
`token.rs` exists so arenas can verify without calling anybody, and no such
boundary sits between the panel and the meta-layer, while a stateless token
cannot be revoked and the flag check makes revocation land on the next click.
The catalog's `[[staff]]` table keys on call signs, which are server-dealt
words no operator's account holds and rerollable besides; it stays for the
day named verbs need named powers, per decision 26.

Granting moved twice and landed in the panel. It began as a route behind
`VW_ADMIN_TOKEN`, then became SQL an operator ran against the database, which
retired that token and the `/v1/ban` curl with it. It is now an admin action
like the others.

Each move traded containment for reach, and the last one is the largest: a
leaked session or a bug in the page can mint an operator that outlives it,
where the database-only arrangement meant the worst a session could do was
act as an admin until somebody revoked it. What that bought is adding a
second operator without a shell and a database credential, which is the thing
an operator actually wanted and the reason this panel exists at all.

The guards that did not depend on the containment all survive. Only a claimed
human may hold the flag, since the panel signs in with a password a guest
does not have and a bot's `house` credential is not. The panel's ban refuses
flagged accounts, so one rogue session cannot lock the others out. The last
admin cannot be revoked, because a deployment with nobody who can open the
panel is a trip to the database. And the first admin is still made there,
since there is nobody to grant it yet.

**Cost:** Fleet-wide reach behind a password whose floor is six characters,
throttled to ten guesses a quarter hour per name. [admin.md](admin.md) wanted
a passkey or an SSO front before any surface returned, and this trades that
bar for a credential the fleet already had. That cost rose when granting
moved into the panel: one guessed password now appoints operators rather than
only impersonating one. Also a second certificate, priced low now that the
store survives reinstalls and a burned limit on the admin name strands only
the panel.

**Reconsider if:** the panel grows verbs with different blast radii, which is
when one flag stops being an authority model; or a password behind fleet
reach stops being comfortable, in which case a passkey bolts onto the login
without moving anything else.

---

## 42. The arena keeps a pilot log, with an expiry on every row

**Status:** accepted

A room knows things no other process can reconstruct afterwards, and keeps none
of them. Which of five refusals a client was handed at the door, whether a
departure was a quit or a seat taken back for somebody arriving, which hull
somebody swapped into and when: all of it lives for one tick. `rated_events`
records what a fight did to a number and nothing about the stay it happened in.
So when a player reports being bounced, the only party who knows why is the
player, and [admin.md](admin.md) already notes that an operator can act on a
report and not notice one.

So arenas file a second log to the meta-layer, `pilot_events`, on the road the
rated log already built: append a line, let the tick move on, drain the batch in
the background, refuse a replay on an arena-minted id. Thirteen kinds of arena
event and eight account events from the meta-layer itself.

Two of the thirteen are combat, and they arrived a day after the rest, because
the first cut kept kills out on the rule that `rated_events` already holds
every death and a log should not say things twice. The rule held and the log
was useless: a session read as a join and a leave with an hour of silence
between them, which its first operator noticed within the hour. The
human-involving deaths are filed here too now, `died` and `kill`, a row per
human participant and nothing for the machines. The rated log keeps the
authority on ratings and the full credit list; these rows put the death in the
story of a stay. Every arena row
carries a session, which is one connection and rides on the seat, because
sitting out and flying again reissue every other handle a pilot has.

The panel reads it two ways: under a pilot's card, and fleet-wide in a Recent
section that separates people from bots. The second one crosses the line
admin.md draws between acting on a report and noticing one, and it is here
because the deployment asked for it. What stays true is that nothing watches on
anybody's behalf. There is no alert, no threshold and no score, so the log
answers a question when somebody asks it and is silent otherwise.

Three things it is not, each ruled out by something already written down.

It holds no addresses. An arena never learns one, and the meta-layer's stated
best property is that a breach would disclose a ladder rather than anybody's
identity. A behavior log keyed to where somebody lives spends that, so
correlating two accounts to one household is the thing this cannot do.
[community.md](../design/community.md) says a change to that property arrives as
its own record, and this is not it.

It is not an anti-cheat feed.
[networking.md](networking.md) says aim assistance is a behavioral detection
problem we are not solving in the architecture, and this does not reopen it.

And nothing in it is kept. The rated log keeps human rows forever because a
rating is a claim that may have to be replayed; this makes no such claim, and
past ninety days it is a record of how people play held by a service whose
appeal is holding nothing of the sort. Bot rows go at seven days, and there are
two orders of magnitude more of them.

Two ceilings, because half of these are things a pilot can do as fast as they
can press a key. A session files at most 200 rows, and only changes that took
effect are rows at all. Refusals get their own ceiling of 60 a minute per arena,
since a client looping on one gets a fresh session every time and so never meets
the first cap.

**Cost:** A second spool file and a second drain task on every arena, and a
`Seat` that now carries a session. `Room::leave` grew a reason parameter, which
touched all five of its callers and is the change that makes the log worth
having. The stop signal is handled now, so a converge files a `leave` for every
open session before the process goes; before that, every deploy cut the open
stories short, and the first session anybody inspected was one of them. The
human-involving death rows repeat a fact the rated log holds, which is the
price of a session that reads whole; the repeat is bounded by there being
humans in the fight. Rows expire, so a question asked late enough has no answer, and the
ninety-day figure is a guess at how late that is rather than a measurement.

**Reconsider if:** the ninety days turns out to be wrong in either direction,
which the first real investigation will say; or the fleet wants to follow one
person across arenas in a single session, which needs the meta-layer to mint the
session at `/v1/session` and carry it in the token, and is a bigger change than
it looks because a token is reminted every fifteen minutes.

## 43. A snapshot carries what you could lawfully see

**Decided:** ships and rounds are filtered to the interest radius that already
governed prizes, and the scores move to the roster so a scoreboard survives it.

**Why:** two problems with one shape, and the second is the one that matters.

The bytes were measurable and bad. A live client was pulling 312 KB/s against
a target of 30, and parsing the real wire said 77.6% of it was rounds, of which
only 20.9% were inside the radius. Four fifths of the traffic was bullets from
fights nobody here could see.

The sight was worse and had no number on it. Every client was sent the
position, velocity and held buttons of every ship on the map, twenty times a
second. A maphack against that is not an exploit, it is a rendering choice:
draw what you were sent.

Both are the same fix, because the reason to send a distant ship and the reason
to send a distant bullet are the same reason, and it was never a good one.

**Cost:** the wire changed, so `CLIENT_PROTOCOL` went to 8 and a stale build is
refused with a reload rather than left misreading an arena. Ships travel behind
a presence bitmap, because a ship index is identity for the roster, the kill
feed and the team lists and renumbering would break all three. The scoreboard
grew a branch: the simulation for seats it can see, the roster for the rest,
because the roster is the only channel that still knows about everybody. And
`sim_pack_around` is no longer a prize filter with a misleading name, so the
constant is `INTEREST` now.

One bug was closed on the way, and it was live. The whole-room exemption keyed
off `Player::bot`, which is what a client says about itself at join. Anybody
could declare themselves a bot from any address and be handed the map. It keys
off the token's label now, which is derived from an account and cannot be
asserted, so a third-party bot is filtered exactly like the person running it.

Two pieces of fallout surfaced in the first hour of play, both the same shape:
client code that treated the snapshot as the whole room. The prediction core
kept sowing prizes, and against a filtered state its live count says nothing
about the map, so it seeded a phantom green near the player every prize_delay
ticks for the next snapshot to sweep; a deathless instance now sows no ambient
greens, by the same reasoning as decision 40. And the scoreboard's drawing read
`sim.ship_team` per row, which answers zero for every absent seat, so every
out-of-sight name wore one shared color; the row takes its side from the
roster now, as its sort already did.

Mines were the third piece, and they arrived later because there were no mines
yet. The argument for filtering a round by distance is that it is spent within
seconds and never leaves the hull that fired it, so nothing can enter the view
without a snapshot announcing it first. A mine breaks both halves: it sits for
two minutes and the pilot flies away from it. Filtered like any other round it
simply stopped being in the snapshot, and a client reads a round that stops
existing as a round that went off, so the pilot was shown their own minefield
detonating behind them while the arena flew it on. Their client then laid a
sixth mine, because it could no longer count the five, and that one really did
vanish, this time as a blast at their own nose. A pilot's own rounds now travel
however far off they are, which costs at most their five mines a snapshot.

**Measured:** 312 KB/s to 24.4 KB/s against a full fifty-two ship room, under
the 30 KB/s target it was ten times over. Prediction error improved rather than
degraded, 0.75/0.38 px worst/mean to 0.61/0.24, with no corrections: a client
not told about distant rounds cannot mispredict them. Simulation behavior is
untouched, which the golden hashes confirm by not moving.

On the mines: one pilot mining for two minutes on alpha laid twelve, and all
twelve left that pilot's own snapshot while the arena was still flying them.
The ones the run was long enough to time went at four and a half to seven
seconds after being laid, against real lifetimes with a median of fifty-two
seconds and nothing under three. None leave now, on the same seed, and every
one of the twelve lasts exactly as long as it did before.

**Reconsider if:** a zone wants a whole-arena spectator view, which is now a
capability rather than a default and would want the watcher path to ask for it;
or fights cluster so hard that the surviving in-radius rounds are still the
budget, which is what the record diets are for and what the live number after
this lands will say.

## 44. Fair sight and rated concurrency are server policy

**Decided:** human snapshots use one server-defined 84-tile radius, public ship
records exclude owner state, prize decisions use an unshipped random stream,
and one account may hold one active rated session across the fleet.

**Why:** each client-controlled input was an allowance rather than a fact. A
window declaration widened sight, a spectator camera inherited the subject's
private record, the prediction seed revealed future greens, sitting out could
discard a wounded hull, and the same account could enter rated rooms on two
arena processes. Local limits did not cover any of those boundaries.

The sight radius now comes from the arena. A camera subject controls centering,
while a separate owner byte controls the private ship tail. Public records carry motion, side, score, bounty, shove and
carrier state. Cooldowns, upgrades, rungs, add-ons, charges, respawn state and
input edges stay in the owner tail. Follow and channel snapshots name no owner.
Remote one-tick charges use a filtered public action message, so the effect
remains visible without putting the remaining inventory on the wire.

The core keeps a public prediction generator and a private prize generator.
Network snapshots omit the latter and its timer. A deathless prediction client
removes a green it touched but applies no guessed grant; the arena sends the
collector `S2C_PRIZE` and the next snapshot carries the resulting owner state.
The local touch emits a result-free presentation event, which starts the pickup
sound on contact without revealing the roll. A matched positive result does not
play it again; a rust result still announces itself when the authority arrives.

Rated exclusion is a renewable row in the meta-layer, keyed by account. The
arena claims before seating an authenticated account, renews every thirty
seconds, and releases on disconnect. A three-minute expiry recovers a row left
by a dead process. Watching without a hull takes no claim; sitting out from a
rated seat keeps the connection's existing claim. Every entrance to the stands
counts against `max_watchers`, and a voluntary entrance also requires the full
energy gate used by hull and side changes.

**Cost:** the snapshot wire changed and `CLIENT_PROTOCOL` moved to 9. New rated
joins depend on a meta-layer round trip and fail closed when exclusion cannot
be checked, while active rooms and guests remain independent of that service.

**Reconsider if:** measured traffic makes 84 tiles too expensive, in which case
the replacement is another server policy rather than a client declaration; or
the product wants multiple simultaneous rated seats under one accountable
party, which needs an explicit party model instead of an account loophole.

## 45. Energy is public combat state

**Decided:** every visible ship record carries current energy and its capacity
rung. Its bar is drawn for the owner, teammates, opponents and spectators
whenever that hull is wounded.

**Why:** energy is both health and ammunition. Reading who is close to death is
part of choosing a target, committing to a fight and knowing whether a hit
landed. Hiding it removed the bars that make combat legible and protected no
inventory decision worth protecting. The fairness radius already withholds the
whole hull when it is outside lawful sight.

Other upgrades, weapon rungs, add-ons, charges, cooldowns and input edges
remain in the owner-only tail.

**Cost:** five bytes per visible ship per snapshot. The ship record layout
changed, so `CLIENT_PROTOCOL` moved to 10.

## 46. Inputs repair loss and combat news waits for its picture

**Decided:** every input datagram repeats four tick-stamped states, reliable
combat events name their authoritative tick, and the debug readout separates
input scheduling, latency, prediction and presentation metrics.

**Why:** three clean-looking numbers hid three different failures.

A WebTransport input was sent once. That was acceptable for a held direction,
where the next state repairs the hand, but not for a charge, mine or touch
toggle that exists for one tick. Losing that datagram erased the action on the
server after the client had already shown it. The newest later tick still came
back acknowledged, so the clock readout stayed healthy while the snapshot took
the action away.

The clock readout also called input scheduling margin round-trip latency. It
cannot be that: the target margin is negative. The actual estimate is lead plus
margin, which cancels the client's clock offset. Finally, the only correction
number belonged to the local hull's X and Y. Remote ships could be wrong in
position or heading without moving it at all.

Protocol 11 makes the input packet a base tick followed by one to four
consecutive button states. The server replaces overlap still queued and ignores
a repeated tick already consumed. One lost packet is repaired ten milliseconds
later, normally while every repeated tick is still in the future.

Kills and public charge actions now carry the simulation tick that produced
them. The client holds either until it has applied a snapshot at that tick or
later, and deduplicates the delayed room-channel copy by tick and subject. A
reliable stream can pass a snapshot datagram without letting the feed spoil the
result.

The debug view now reports input margin, estimated round trip, snapshot gaps,
prediction pace, rolling p95 remote corrections and the correction debt still
visible.

**Cost:** steady input traffic grows from seven to fourteen bytes per tick,
about 0.7 KB/s of uplink.

**Reconsider if:** remote correction p95 remains large on WebTransport. The next
step is a snapshot lane with a higher cadence for nearby combat, justified by
measured correction and bandwidth together rather than by another smoothing
constant.

## 47. Remote presentation stays inside the collision-aware core

**Decided:** remote hulls and rounds use the predicted core's positions. The
renderer no longer backs them toward estimated server time or extends an
observed heading rate. Heading corrections again use the same eighty-millisecond
half-life as position.

**Why:** the first live implementation held remote presentation at a fixed
point relative to each snapshot. Ships froze between 20 Hz snapshots, then
jumped. One recording showed 34.4 pixels of visible smoothing debt while the
underlying remote correction was only 1.4 pixels at p95. The presentation layer
was creating a much larger error than the predictor.

The same implementation moved a remote round backward along its current
velocity. That arithmetic has no record of walls, bounces or impacts, so it
could draw a round on the wrong side of a wall even though the simulation had
handled the collision correctly. A shorter heading half-life made each 20 Hz
step easier to see.

**Cost:** remote state still inherits the pilot's prediction lead and coasts on
snapshot velocity. Corrections may grow on a slow link, but the drawing now
respects the simulation's collision history and the metrics report the actual
miss instead of one introduced by presentation.

**Reconsider if:** measured remote correction remains large after this revert.
Use a collision-aware state buffer or a faster snapshot lane rather than
rewriting coordinates outside the simulation.

## 48. Loss repair, lag policy, and combat presentation have separate budgets

The gameplay enforcement in this decision was replaced by decision 49. The
selective repair, measurements, and combat presentation remain.

**Decided:** protocol 12 uses selective acknowledgements for input and snapshot
delivery. The arena measures each pilot's round trip, ordinary snapshot loss,
combat-lane loss, and missed input deadlines. Zone-defined thresholds may deny
flag pickup, suppress a proportional share of weapon inputs, or move a
persistently severe connection to the stands. Nearby combat receives full
lawful snapshots at 50 Hz. Local and remote render corrections use separate
limits.

**Why:** repeating the newest four consecutive inputs handled one lost packet,
but it could not identify an older hole after later inputs arrived. A selective
32-tick receipt window can. The client sends the current input, any acknowledged
holes that can still arrive in time, then the newest unacknowledged history.
Four ticks of scheduling margin give each input several independent rides. A
detected hole is repaired directly and does not steer the prediction clock.

The server previously had no per-player lag measurement or gameplay response.
Snapshot acknowledgements now provide round-trip samples using only server
ticks and the variation between them provides jitter, plus separate loss rates
for the 20 Hz ordinary lane and the 50 Hz nearby-combat lane. A named input that
is absent when its tick runs is an input deadline miss. It may deny objectives
or force spectating, but it never suppresses weapons because the missing input
already did that. Proportional suppression uses a server-secret random stream
outside the deterministic simulation, so a modified client cannot schedule
shots around a known pattern.

A fresh seat does not have an input stream to judge while its client is loading
the map and establishing prediction lead. The arena waits until it holds the
current input and two future inputs, clears the startup history, then collects a
full policy window before a deadline miss can restrict the pilot. Input
deadlines use an exact half-second current window rather than the five-second
path average. When a browser resumes after a pause, old misses age out within
half a second and the input-only objective lock clears with them. It does not
wait for the path's five-second recovery timer. Deadline accounting keeps a
server-only 128-tick receipt window because the 32-bit mask returned to the
client is a repair protocol, not enough history to judge a client running more
than 31 ticks ahead. Flag pickup is denied silently before synchronization. If
a partial input stream never becomes coherent, the lock becomes visible one
path sample after its first packet. The client seeds eight idle prediction
ticks with the first snapshot so an ordinary connection starts near its target
lead. Later snapshots never add or remove replay ticks. Margin must remain
outside a three-tick dead band for a full second before the fixed-step
accumulator runs at 99% or 101%. Missing snapshots or input holes reset that
evidence.

The live debug capture that prompted the change had an estimated 80 ms round
trip, a 12-tick prediction lead, no local correction, and remote correction
peaking near 100 px. Tightening one shared smoothing constant had already made
the local camera judder. The local path therefore keeps its 80 ms half-life and
40 px budget. Remote hulls use a 50 ms half-life and a 16 px budget, with lower
heading and snap thresholds. A nearby fight also gets fresher authority instead
of asking presentation smoothing to hide stale state.

The combat lane sends the same complete server-filtered snapshot as the ordinary
lane. It does not send a smaller radius, because applying a partial replacement
would delete lawful distant state between ordinary snapshots.

**Cost:** input packets grow to at most 34 bytes, and a client sends two of them
once to seed its prediction clock. Each player snapshot gains 17 bytes of
acknowledgement and lag telemetry. A nearby fight can consume two and a half
times the normal snapshot bandwidth. Packing remains per player and the fleet
metrics report the resulting egress.

**Reconsider if:** measured combat egress is too high. Change the server's lane
selection or add a state format that can apply partial updates without deleting
the rest of the lawful view. Do not reduce the fairness circle or merge local
camera smoothing back into the remote correction budget.

## 49. Delivery receipts are diagnostics, not gameplay authority

**Decided:** round trip, jitter, ordinary snapshot loss, combat snapshot loss,
and missed input deadlines remain visible in telemetry. They do not suppress
weapons, deny objectives, or force a pilot to spectate. Objective access and
stale controls depend only on how long the server has gone without a valid
input packet. Weapon holds release after 250 ms, every control and objective
access release after one second, and five seconds of silence moves the pilot
to the stands. One fresh packet clears the objective restriction immediately.
Forty-five seconds of complete silence closes the connection, below the
transport's sixty-second QUIC idle timeout.

**Why:** the snapshot receipt bitmap comes from the client. An honest browser
may discard an obsolete snapshot before Lua sees it, while a modified client can
claim every snapshot arrived. That made the old policy both noisy and easy to
evade. It punished healthy players for browser scheduling and gave dishonest
clients control over the measurement used to punish them.

The server still owns movement, energy, cooldowns, collisions, damage, prize
results, and objectives. Sending an input packet does not make an illegal action
legal. It only proves that the client is still supplying current controls.

**Cost:** reported snapshot loss does not remove a pilot from a match. The loss
numbers remain in the debug readout for diagnosing transport and presentation
problems. The client does close an established WebTransport session when every
usable snapshot is more than half a second behind for a full second. At that
point it cannot reconcile its view without erasing inputs, and the server
settles the closed connection like any other departure. This uses state the
client needs for presentation, not client telemetry as gameplay authority.

**Reconsider if:** a concrete exploit survives server validation and depends on
a stale downstream view. Fix that exploit at the authoritative rule it crosses,
not by trusting a client receipt bitmap again.

---

## 50. A hull is a shape, and everything else is on the shelf

**Status:** superseded by
[decision 97](#97-ships-are-preconstructed-and-nothing-is-bought); the
unrestricted footprint areas were superseded by decision 57

Seven hulls carried a row apiece: how far each weapon climbed, which add-ons
they could hold and how deep, how many of each charge they carried. Four things
in those rows existed on exactly one hull. A second barrel was the Facet's, a
third bomb rung the Anvil's, six mines the Lattice's, and the deepest rung of
shrapnel belonged to whichever two hulls the table called bombers.

Two problems, one cause. A shop cannot sell a trait that exists on one hull, so
none of the four was ever for sale and the shelf was whatever the roster
happened to allow rather than whatever the game has. And a kit was validated
against three composing ceilings, one of them the hull's, so a pilot could buy a
rung and then find the ship they wanted refused it. The shop's own source said
so out loud: "a pilot who buys a rung their hull lacks has bought nothing they
can slot on it."

So the rows became one row for the arena, `sim_settings::kit_ceiling`, set from
the union of what the seven allowed. `sim_kit_ceilings` went with them: once
the answer stopped depending on which hull was asking, the call was a copy of a
field every caller could already read. `DoubleBarrel` becomes `SIM_MOD_BARREL`,
an add-on that adds to
the round count rather than multiplying it, keeps its own tight spacing, and
charges energy without charging cooldown, which is the whole of its trade
against multifire. Nobody is dealt a rung of it; it is the one add-on that is
bought.

Flight went the same way, in the shipped zone rather than in the core. The
baseline has always given every hull one shared `flight` struct, following the
original, where all eight ships fly identically. The melee zone was overriding
it per hull, so the game people actually played did have a faster Apex. That
override is gone, because a kit is thirty points and the match game rests on
every pilot dealing the same thirty: with different floors per hull, thirty
buys a different amount of ship depending on what you are sitting in, and the
drill harness has seven baselines to measure against instead of one.

What is left of a hull is its footprint. That is not a consolation prize: the
collision box follows the heading and weapons test the oriented rectangle, so a
Cipher turned side-on is a six-pixel target where facing it is twenty-two, and
a Lattice is near square and can turn anywhere it fits. It is also the one
advantage no shop could sell even if it wanted to, which is why hulls stay free
and cosmetics live on the wake, the nameplate badge and the podium card.

Decision 57 keeps the directional difference and gives every footprint one
fixed area. The dimensions above record the state before that budget existed.

**Cost:** the roster is thinner. Seven silhouettes with identical engines is
less differentiation than seven stat blocks, and the roles in `ships.md` are now
names for shapes rather than for capabilities. Balance also moved without a
referee. The profile harness now measures full kits directly, but a simulation
cannot price what people enjoy building or expose a live metagame before it
exists, so the new ceilings still need selection and outcome telemetry.

**Reconsider if:** shapes turn out not to be enough to tell hulls apart in play.
The answer then is more shape, not a stat table coming back: extents that vary
more, or something a silhouette can express that a number cannot. Bringing
per-hull flight back means giving up "everyone deals thirty", and that trade
should be made deliberately rather than by adding a line to a zone file.

---

## 51. Six phrases, and no way to add a seventh

**Status:** accepted

Between matches, a player can press one of six chips and put a phrase on their
own row of the podium: "gg", "nice shot", "close one", "good luck", "thanks",
"sorry". Every other client in the room draws it for four seconds beside the
name it belongs to, and then it is gone. That is the whole feature.

[Decision 28](#28-no-chat) said what would make this worth doing and named it
as a separate record: "Fixed phrases, a ping wheel, or team-only signals cost
no moderation because there is nothing unsafe to say." This is the first half
of that, built because the intermission was fifteen seconds of nobody being
able to acknowledge the match they had just played.

What keeps it costing no moderation is the shape of the wire rather than a
policy. `C2S_SAY` carries one byte and it is an index; the room checks it
against a count and drops anything past the end. No text goes to the server, so
there is nothing to filter, nothing to log, and nothing to report. A phrase
cannot be aimed: there is no recipient field, only the room, and no phrase on
the list means anything unpleasant no matter who is meant to read it. The list
lives in the client build, so an operator cannot extend it by editing a config,
and a client that shipped with a shorter list draws nothing for a number it
does not have rather than a blank.

Two more rules, both about the same thing. It is refused while a match is
running, so nothing here can be used to talk over somebody trying to play. And
it is one every two seconds a seat, which is slower than the line takes to
read, so it cannot be used to shout.

**Cost:** it is a moderation surface that is exactly zero today and will be
argued about the first time somebody wants a seventh phrase. Every addition is
a judgment about what six strangers can say to each other, and the list is
short enough that "sorry" and "nice shot" carry sarcasm in the right hands. We
think a sarcastic "nice shot" is a game, not an incident, and the answer to
being tired of one is that it is gone in four seconds. It is also duplicated:
the phrases are written down in the client and the count in the server, and
adding one means touching both.

**Reconsider if:** somebody wants a phrase aimed at a person, or wants one
during a match. Both are chat with a smaller vocabulary and the argument in
decision 28 applies to them unchanged. Team-only signals during play are the
one thing on the reconsider list that is still open, and they would be a
different feature again: a ping on the radar rather than a word on a card.

---

## 52. A misfire costs a kill and a rivet

**Status:** accepted

Killing yourself with your own bomb, or killing a teammate with it, takes one
off your kill count in the arena and one rivet off your wallet. The kill count
goes below zero. The wallet does not.

Before this, a teamkill *credited* a kill. It paid no points and no bounty,
which was the rating layer's rule made visible, but the number on the
scoreboard went up either way: the same figure moved whether you shot an enemy
or your own wingman. A self-kill moved nothing at all, so the pilot who spent a
match bombing their own feet read as a pilot who had simply not managed
anything.

The signed counter is the part worth arguing about, and it is the part that
makes this work. Clamping at zero would make the first mistake free and every
one after it visible, which is exactly backwards: the pilot most in need of the
signal is the one at zero. `sim_ship.kills` is `int16_t` now and it is the only
counter in that struct that is signed; deaths only ever climb.

The rivet is not a fine. A kill is worth dozens, so one is the smallest amount
a wallet can move by, and the point is the direction rather than the size. It
is floored at zero because a negative score is a fact about a match and a
negative balance is a debt, and there is nothing in this game that could ever
collect one.

Flying into a rock is free. A wall death has no thrower: the arena reports seat
255, which is nobody, and the walk back is already what it costs. What is
charged is the two deaths somebody aimed.

**Cost:** two surfaces have to agree about one number and they are computed
differently. The arena counts on the ship; the week's table counts rows in the
pilot log, so a `misfire` row is a new kind there and the query subtracts it.
Add a third surface and it will need the same subtraction. The side's score in
a match is also clamped at zero, because the wire carries it as a pair of
unsigned numbers and the podium draws a bar as a share of their sum, so a side
four misfires under with no kills at all reads as nil rather than as minus
four. That is a guard, not a rule anybody will play against.

**Reconsider if:** the penalty turns out to change nothing, in which case it is
too small rather than wrong, and the lever is the rivet rather than the kill. Or
if repel becomes a way to push somebody into their own bomb, which would make
this a thing done *to* a pilot rather than by one. The arena knows who threw the
round and not who arranged for it to matter, and if that becomes a way to play
the answer is a rule about the shove rather than a softer rule about the bomb.

---

## 53. Assists are counted in the core

**Status:** accepted

The simulation counts assists on the ship, beside kills and deaths, and packs
them into the snapshot. A hull remembers the last four pilots to damage it and
when; a death hands one assist to each of them inside a six-second window,
except the pilot who landed the finish.

The alternative was to derive them on the server. The rating layer already
computes exactly this and better: `rating::death` returns a weighted credit per
contributor, decayed on a four-second half-life, and the kill message on the
wire already carries a contributor count. Counting them there would have been
no new state anywhere.

What it could not do is answer for a pilot who was not watching. A scoreboard
column has to be right for somebody who joined thirty seconds ago, for a
watcher who joined this second, and for a seat on the far side of the map that
the snapshot filter is not sending. Kills and deaths are right for all three
because they live on the ship and ride the snapshot, and a column that was
right only for clients present since the whistle would be a different kind of
number sitting in the same row.

So it is core state, and it is deliberately cruder than the rating layer's
version. An assist is whole rather than a share: this column counts deaths you
were part of, and how much of each you did is a judgment, which is the rating's
job. Four slots and a flat window, in fixed point, because the core has no
floats and a decaying weight per attacker per ship is a ledger the wire would
then have to carry.

**Cost:** two definitions of an assist now exist, and they can disagree at the
edges. The week's table counts them out of `rated_events.credits`, because the
pilot log has no row for helping, so a pilot who is credited with a sliver of
damage gets a week's assist and might not have got an arena one, or the other
way round past the window. Both are "kills you helped with" to a player and
neither is the authority on the other. The ledger is also four bytes and a byte
per attacker on every ship in the state, which is small but is memory the core
did not want before, and it is one more thing a snapshot has to agree about.

**Reconsider if:** the two numbers visibly disagree often enough that somebody
notices, in which case the answer is to file assists as pilot-log rows from the
arena, so both surfaces read the same source. That is a bigger change than it
sounds: it means the arena has to know which contributor is which account at
the moment of the kill, which today only the rating layer does.

---

## 54. Barrels and multifire are one ladder called spray

**Status:** accepted

There were two add-ons that bought a pilot more bullets. Barrels put a second
round abreast of the first and charged energy for it. Multifire opened a wide
fan of three and charged energy and cooldown both. A pilot shopping for either
was shopping for the same thing, and the shelf asked them to learn which of two
names meant a tighter pair and which meant a wider spread before they could
answer a question they did not have.

Now there is one: `SIM_MOD_MULTI`, a six-rung ladder from 0 to 5, sold as
"spray". A rung is a round. Zero rungs is the single barrel every gun already
had, one rung is the old pair, and the rest keep going. The pair's tight
spacing survives as the first rung's angle: a pattern that does not already fan
gets `mod_pair_spread` at one rung and the zone's `mod_spread` above it, so the
step that used to be the choice between two add-ons is now the step between the
first rung and the second.

The pricing came out of the old numbers rather than out of the air. Spray is
the only add-on that costs anything to pull the trigger with, so each rung adds
25 % to a shot's energy and 50 % to its cooldown; three rounds therefore land
exactly where multifire used to sit, and the rungs on either side of it fall
where you would guess.

Merging them freed a slot. The flat kit space went from 25 to 23 and
`SIM_MOD_COUNT` from 7 to 6. The packed word narrowed too, from fourteen bits
of two-bit pairs to thirteen: three at the bottom for the ladder, then two each
for the five above it. That moves every mod and charge slot
underneath, so the wire went to protocol 17 and the meta layer runs a one-shot
`spray_merged` migration: barrel entitlements fold into the spray of the same
trigger at `2 * multi + barrels`, capped at the ceiling, and then everything
below shifts down. Saved kits are dropped rather than remapped. A kit is a
preference a pilot re-sets in a few seconds; a purchase is money, and only one
of those is worth the risk of a subtle remap.

**Cost:** a pilot who owned both add-ons at once gets a ladder position that is
worth roughly what they had, not exactly. The fold treats a multifire rung as
two barrels because that is what it threw, but multifire also bought cooldown,
which the fold does not refund. Nobody outside our own test accounts has both,
which is the only reason a one-line `case` is an acceptable answer here.

**Reconsider if:** the top of the ladder is never worth buying, which would mean
the compounding cost outruns the extra rounds before rung five. The fix then is
the two zone knobs rather than the shape: `multi_energy` and `multi_delay` are
per-rung percentages and can taper. And if some future weapon wants a tight
pair specifically, that is a weapon with its own `spacing`, not a second add-on
coming back.

---

## 55. One rung ramp for every round, re-decided for the team game

**Status:** accepted

The projectile ramp is one scale for every round in the game: green, yellow,
orange, red by rung, the same four for a bullet and a bomb, for yours and for
theirs. The argument that closed it was written for the open arena: in a
free-for-all every round is worth dodging, so a round that stopped saying
whose it was gave up nothing. The game is exclusively three-minute 4v4 melee
now, and the core never lands a teammate's bullet, since contact damage and
the push add-on both skip the firer's side. Half the bullets crossing a
pilot's screen are harmless to them, the paint says nothing about which half,
and the old rationale is dead. This entry is the re-decision the palette was
resting on, made on the live facts rather than inherited.

The ramp stays, for three reasons that are still true. The team ramps this
replaced were removed on measurement, not taste: rungs sat ten units of color
apart, and blending toward white converged the teams exactly where the rungs
mattered most, so a three-pixel round crossing the screen has room for one
reading and the rung is the one that says what a hit costs. Bomb blasts are
team-blind, and deliberately so: `sim.c` applies blast damage to every hull in
radius, the thrower and their side included, so the class of round that
actually kills is worth dodging whoever threw it. And the team read already
lives on the hull, the plate and the radar, at sizes where it works.

**Cost:** a teammate's bullet stream reads as a threat and buys a flinch that
a fully honest screen would not. In a 4v4 room where half the ships are
hostile, a flinch at a crossing stream is usually the right reflex anyway.

**Reconsider if:** players report giving up position to dodge friendly
streams often enough to name it, or a mode with more sides lands. The first
thing to try then is luminance rather than hue: a friendly round drawn a step
dimmer keeps the whole ramp and spends a channel the ramp does not use.

## 56. The landing shows the game, and the shop teaches it

**Decision:** the play page joins the selected zone as a watcher while it is
on screen, so the actual match plays behind the menu; one panel on the left
carries the zone carousel, the room's own clock and split score bar, the
standings with the ground beside them, and the deploy key, which converts
the standing watch connection into the seat rather than re-dialling. The
zones list is gone from the landing: with three to five game types the
carousel on the name is the whole picker. The shop gained a reading pane
(a drill-in page on a phone) with an animated firing-range demo and a
client-side teaching sentence per slot.

**Why:** the landing described the game in labeled numbers and asked a new
player to want it anyway. An arcade cabinet runs its attract loop instead,
and this game's honest draw is that a match is always on: the clock, the
score, the fight and who is winning are all real and all live, and pressing
deploy drops into exactly what the screen was showing. The shop knew every
price and could not say what a fuse was for; thirty points of animation and
one sentence per slot answer what a name and a ladder cannot.

**Cost:** an idle landing holds a live connection per viewer, and the
directory's people count includes watchers, so a browsing player reads as a
person in the room. The backdrop also brings the battle's sounds to the
menu, which is either atmosphere or noise depending on who is asked.

**Reconsider if:** landing connections become a real load on small hosts
(gate the attract on desktop or on focus), or watchers inflating the room
count starts steering players at fleet scale (count seated humans in the
directory instead).

---

## 57. Every hull spends 625 square pixels

**Status:** accepted, superseding the unrestricted footprint areas in decision
50

Footprint is the only built-in stat one hull has over another. Flight, energy,
weapons and kit depth are shared. The old footprints did not give that stat a
budget: Cipher occupied 408 square pixels and Lattice 840, with the other five
scattered between them. A Cipher pilot received less than half the target for
choosing a silhouette.

Every oriented collision rectangle now occupies exactly 625 square pixels:

| Hull | Length | Beam | Area |
|---|---:|---:|---:|
| Apex | 31.25 | 20 | 625 |
| Wedge | 20 | 31.25 | 625 |
| Chord | 16 | 39.0625 | 625 |
| Anvil | 25 | 25 | 625 |
| Cipher | 39.0625 | 16 | 625 |
| Facet | 25 | 25 | 625 |
| Lattice | 25 | 25 | 625 |

The old roster averaged 639.7 square pixels, so 625 is a small overall change.
It is also exact in the core's Q8 units for a 25-pixel square and for the two
reciprocal aspect pairs. No rounding or floating point enters collision.

Equal area does not make every heading equal. Cipher presents 16 pixels
nose-on and just over 39 broadside; Chord makes the opposite trade. Apex and
Wedge are milder versions of the same choice. The three square footprints have
no especially good angle, but their silhouettes remain distinct. Shape still
matters. It now spends a fixed target budget.

Every nose corner remains inside the 23-pixel reach used to validate maps. The
client refits every part of each drawing around the new rectangle, and tests
check the rendered faces, the runtime area and the map ceiling.

**Cost:** a sparse silhouette such as Lattice does not fill every corner of its
rectangle. That was already true of oriented boxes around concave art. Equal
area fixes target quantity, not pixel-perfect collision against every visible
edge.

**Reconsider if:** the simulation adopts polygon collision. Normalize the
polygon areas then and retire the rectangle budget rather than layering one
shape contract over another.

---

## 58. The Ladder zone always has a duel in it

**Status:** superseded by [decision 96](#96-duels-are-gone)

Decision 56 made the play page a watcher on the zone under the cursor, so the
match behind the menu is the match a deploy would put you in. That works
because melee is filled to eight seats by the bot server and is therefore
always playing. Ladder is not: its room asked for a rival only once a person
was in it, so the zone a visitor previews second is an empty arena, and the
readings beside it are dashes and a sentence about looking for a rival.

A Ladder room with nobody in it now climbs anyway. The director seats a
stand-in beside the rung's own rival and the two fly the ordinary one-life
duel: same rungs, same measured rival builds, same clock, same progression.
The stand-in comes from the generated roster rather than the eight authored
archetypes, since those are the rungs it is climbing and one of them anchors
every rating in the fleet. A person arriving takes the seat back on the tick
they arrive, and the run starts over at their own floor, because a run belongs
to whoever is flying it.

Only the zone's first room does this. Rooms open because people arrive and are
given back when they empty, and a room with a stand-in flying in it never
empties, so any other rule would leave a bot duel in every room a busy evening
ever opened.

**Cost:** two bot connections and one predicted room, permanently, per Ladder
zone, plus a rival swap every time the stand-in clears a rung. That is the load
of one person playing continuously, which is the load the zone was built for.
The rung a visitor sees is also wherever the stand-in's run happens to be
rather than rung one, so the preview is not a picture of what a new player's
first fight looks like.

**Reconsider if:** the fleet grows enough zones that a permanent duel in each
of them is real load, in which case the stand-in should start when somebody is
watching and stop when the last watcher leaves. The room already knows its
watchers; it was left out here because a duel that starts when you look at it
starts too late to be the thing you looked at.

## 59. Spectating is one shared feed, five seconds behind

**Decision:** a watcher sees the room channel and nothing else. Same-side live
follow, the `watch` staff capability that granted live sight of anybody, and
the per-zone `channel_delay_ticks` dial are all removed. The delay is a server
constant at five seconds. `C2S_WATCH` loses its ship byte and means sit out,
so `CLIENT_PROTOCOL` moves to 23.

**Why:** the sight rule had three branches and the interesting one was already
never granted. Watching a hostile hull live is a wallhack with a menu entry,
so that ask always fell to the channel. What remained lawful was following a
teammate, on the reasoning that a teammate's screen is knowledge the side
already has, and a named staff account following anybody. Neither was wrong.
Both were expensive: a second stream packed per follower beside the shared
one, a lawfulness check on every frame in case the followed hull crossed
sides, a control in the info box, a camera walk on the arrow keys, a tap
target on each half of a phone screen, a capability checked at the door and
carried on every request, and a byte on the wire whose values mostly meant
"the channel". All of it served, live, a fight the channel already shows five
seconds later.

The dial went for a different reason. `channel_delay_ticks` defaulted to five
seconds and the ladder zone set zero, which is the protection switched off in
a file nobody reads twice. What that zone wanted was an audience, and the
channel is an audience whatever the delay; what zero bought on top of that was
a fresh map of a live room for anybody who opened a second tab. Five seconds
is a server constant now, so a zone file cannot turn it down.

The rule that is left fits in a sentence: one feed per room, the same bytes to
everybody on it, five seconds late.

**Cost:** a benched pilot cannot watch their own side. In a four a side match
a sit-out, a dropped socket or a lag bench now means watching the room's
camera, seconds behind, while your side plays without you. Operators lose the
live room view and get the delayed one everybody else has. Replays from the
input trace answer both, and they cost no egress at match time because a
deterministic core means a match is its initial state plus its inputs.

**Reconsider if:** a competitive format wants a produced broadcast, which
wants a director and a longer delay rather than a shorter one; or replays
land and somebody still asks to follow a teammate live, which would be
evidence that the delay rather than the sharing was what people minded.
---

## 60. Every flight stat gets eight real steps

**Status:** accepted, superseding decision 50's inherited flight ranges

The hangar once drew eight pips for every flight stat even though the core
stopped changing Energy after seven points, Recharge and Speed after five, and
Thrust and Rotation after one. Removing the dead pips fixed the lie, but it
also reduced the flight build space to nineteen useful points. Rotation and
Thrust were settings more than choices.

The five shared flight rows now each have eight useful steps:

| Stat | Zero points | Per point | Starter | Eight points |
|---|---:|---:|---:|---:|
| Speed | 2010 | 248 | 5 = 3250 | 3994 |
| Thrust | 15.4 | 0.8 | 2 = 17 | 21.8 |
| Rotation | 210 | 10 | 2 = 230 | 290 |
| Energy | 1475 | 25 | 5 = 1600 | 1675 |
| Recharge | 1070 | 20 | 4 = 1150 | 1230 |

The `5/4/5/2/2` starter spends eighteen points and resolves to the same
familiar ship. Its Speed floor also stays at 2010, which keeps the authored map
contact-time contract intact. The change opens space on both sides of the
starter instead of making the default ship faster or moving the first fight.

Forty useful stat points now compete for a thirty-point kit. A pilot can build
an engine or a tank, but cannot maximize both, and a kit spent entirely on
flight gives up weapon rungs, add-ons and charges. Stats remain universal
choices rather than shop purchases. The profile harness tests each stat's next
starter pip and eighth pip against the same bomb-bounce point. Those ten margins
form its confirmatory family. The more conservative fifteen-comparison planning
bound needs 3,384 paired seeds
for the stated 90% power target under worst-case paired variance. The
prespecified screen rounds that minimum to 3,402, or 81 complete blocks across
six maps and seven cyclic lineups. Every hull occupies four lineup seats per
cycle. The report keeps every mirrored seed-level row. Fixed activity and
mirrored sensitivity gates reject a fixture that cannot expose build
differences. A gross observed side gap is preserved as a
warning because the estimator averages both assignments. These diagnostics are
unpowered and sit outside the contrast-power claim.

**Cost:** saved custom kits store counts, not resolved values. Active kits and
named copies carrying the exact old starter allocation are remapped because
the new allocation costs the same eighteen points and preserves their handling.
Other custom counts keep what their authors picked and may resolve to a
slightly different ship. House-pilot build plans also have more room to
specialize, so their provisional Ladder order must be measured again before it
can become certified.

**Reconsider if:** live selection concentrates at the edges, or a matched
starter-margin or eighth-pip contrast falls outside the balance band. Adjust
the range or the per-point jump while keeping eight meaningful steps. Do not
bring back pips that spend a point without changing the ship.

---

## 61. The landing is the game, watched from the stands

**Status:** accepted, superseding decision 56's deck

**Decision:** opening the client seats you in the stands of a real melee room
and draws the watcher's own HUD. The front end is that screen plus two things
over its foot: the wordmark, and a breathing PLAY NOW key that takes a seat in
the room already on screen. The deck is deleted, along with the zone carousel
it carried. The menu becomes an ordinary panel over the stands, closable like
the one opened mid-fight, and forced up only when the client has reached no
room at all. Its tab row is decided by whether you are in a hull rather than by
which screen you are on: six stops with none, the short row with one, so a
pilot the room benched gets the whole row back with `leave` added to it.

**Why:** decision 56 already ran a real watch connection behind the landing and
already converted it on deploy, so the panel in front of it was describing a
room the player could see. Every reading on it, the clock and the score and the
roster and who is winning, is one the HUD draws better, to the people in the
room, in code that has to be right anyway. Deleting the deck removes a second
renderer for the same facts rather than adding a screen.

It is also aimed at a number: 67% of accounts have never scored, and the wall
is the first session. A stranger now watches a real fight in the real
interface before deciding anything, which is how the game this one inherits
its simulation from taught itself, and the thing they press is the only
control on the screen.

The name goes directly over the key. Three placements were drawn (over the key,
under the clock, in the corner the missing corner stack leaves empty); the
mocks are in `.design/spectator-landing`. A stranger's eye ends on the pulsing
thing at the foot of the screen, so the name has to be where that look lands.

Nothing opens the menu but a player. Between the engine's first frame and the
first snapshot there is a directory lookup and a handshake, and what fills that
gap is this same screen with everything that needs a room taken off it: the
starfield, the name where the room will leave it, and MENU. The menu standing
itself up there was the first version and it was the same mistake in miniature,
a panel nobody asked for between a player and the game; a lockup centered in
the window was the second, and it made the name jump to the foot of the screen
the moment a game answered. That is also what lets the menu always close, since
whatever is behind it carries a way back in.

**Cost:** the same as decision 56's, and more of it: every page load holds a
watcher slot, so `max_watchers` is now the front door's capacity rather than a
gallery's. Arena servers open rooms as they fill, which is the answer at this
population and is not the answer at every population. Every drive-by visitor is
also a named row in the roster and puts pilots on air more of the time, which
dilutes what the tally says; that is accepted rather than fixed, because the
alternative is an unnamed watcher and decision 59 spent real effort killing the
second kind of watcher.

**Reconsider if:** watcher slots become the thing that fills first on a popular
room (give the landing a lighter feed, or seat visitors only where a room has
spare egress), or the roster noise makes the on-air tally something pilots stop
reading.

---

## 62. Mines are gone

**Decided:** the mine is removed from the game. `SIM_CHARGE_MINE`, its pattern
and its kit ceiling go; so do the three spec and pattern fields that existed
only for it, `still`, `blast_up` and `energy_up`. The charge rack still holds
four kinds and ships two, a repel and a burst. `CFG_VERSION` moves to 19.

**Why:** it was the one weapon that did not fit any rule the rest of the game
runs on, and every one of those exceptions cost something somewhere else.

A round takes the firer's velocity on top of its own speed, which is why a shot
fired at a run is faster over the ground. A mine had to not, so the spec grew
`still`. A weapon's rung is a row on its ladder, so a rung is a different spec
with different numbers; a charge fires one pattern for everybody, so a mine
wore its layer's bomb rung instead, and the spec grew `blast_up` and the
pattern grew `energy_up` to make that rung mean anything. A proximity add-on
adds a fuse to a round that has none, so on the one round that arrived with a
fuse the add-on had to take the larger of the two instead of the sum. A repel
shoves a round, so a mine had to stop being a mine when shoved, which needed a
lookup from the round back to the class that laid it. The renderer could not
recover a mine's rung from its spec, so the expiry event carried the rung in
two spare bits of its position word, and the client learned to mask them.

The network paid the largest bill. Rounds are filtered by distance, and the
whole argument for that is that a round is spent within seconds and never
leaves the hull that fired it. A mine sat for two minutes while its layer flew
away, so `sim_pack_around` grew a `viewer` seat whose own rounds traveled
however far off they were (decision 43). The client then had to tell a mine
that detonated from a mine an enemy repel had converted, by scanning the
snapshot for a freshly born bomb near where the mine had been, or a scattered
field flashed and banged as though it had gone off.

Every one of those is a special case sitting at a point where the model is
otherwise uniform, and all of them are the price of one round that is laid
rather than thrown. The four phases a projectile lives through exist so that a
weapon is a set of numbers instead of a branch. This weapon was the branch.

**Cost:** the game loses its only way to deny ground without standing on it,
and nothing left in the arena does that job. The Denier profile stays, since a
long working range and low pursuit hold up on their own, but it no longer has
the weapon it was named for. Bots lose `should_mine`, the corridor test behind
it, and the `mine_preference` knob. Accounts that bought mine rungs hold rows
in a slot whose ceiling is now zero: the shelf already skips those and a kit
that names one is already trimmed, so nothing breaks, but nobody is refunded
either.

**Reconsider if:** area denial turns out to be what the melee arena is missing,
in which case the thing to build is a weapon designed for these rules rather
than the original's mine bolted onto them. A charge with a short life and a
wide blast that leaves the rack at the ship's speed would need none of the
exceptions above.

---

## 63. The menu is one column docked to the left edge

**Status:** accepted, superseding the two-layout menu

**Decision:** the menu is drawn once, at 390 points wide, and stood against the
left edge of the window. A head carries the wordmark and the call sign, the page
sits under it, and the six stops sit at its foot. A window narrower than 390
points gives the column everything it has, which is what a phone held upright
already got. A window wider keeps the fight beside it: the wash covers the
column and stops at its edge, and a press on the game beside it closes the menu
the way escape does.

Three consequences follow from the width rather than from taste. The picture of
a keyboard on the controls page is deleted, because a board drawn across 362
points comes out with 15-point keys; that page is a row per control with its key
at the end, which is what a phone always had. The reading pane beside the
upgrades shelf is gone the same way, so a row opens the item as a page on every
device rather than only on a phone. And the column that used to stand beside a
list, carrying the room's roster, follows the rows down the one column there is.

**Since it was built,** three things this decision described have changed, none
of them touching the argument for docking. The column opens as a drawer: a
hamburger key raises it, it slides in from the left over 160ms and back out the
same way, a thumb can push it off, and the two instruments it comes to cover
stand down for the overlap and come back after it. The way out moved into the
square the key occupies, at the head's left, with the wordmark shifted right.
And the play page lost the DEPLOY key described above along with the roster
under its rows: a row is the way into a game, by a tap or by enter, so the key
was one control for an act the page already had, and a roster there is a second
scoreboard on the page about leaving for somewhere else.

**Why:** the menu was two layouts. Below 620 points it was a tab bar under a
thumb; above it, a row of words across the top with the page and sometimes a
second column beneath. Two layouts is two things for a player to learn, two sets
of measurements to keep in step, and in practice one of them was always the one
nobody was looking at. Every page in the tree was already laid out to survive
390 points, because a phone held upright is 390 points and the menu had to fit
one; what the wider windows were doing with the rest of the screen was a second
design living off that fact.

Docking rather than centering is what makes the menu work from the stands.
Decision 61 put every player in a live room the moment the client opens, so the
menu is nearly always a panel over a fight. A panel in the middle of the screen
sits exactly where the ship is. Against an edge, the match keeps playing beside
the column, which is what makes changing a ship or a zone from the stands a
thing you can do while watching rather than a thing you leave to do.

Three directions were drawn before this one was picked, and the mocks are in
`.design/menu-unify`: this column docked to the edge, the same column floating
as a centered card, and a persistent bar carrying the six stops with a sheet
rising from it. The card loses the fight behind it. The bar is the stronger
answer in the stands and the wrong one over a match, where a permanent strip of
chrome is a fork in the same behavior this decision exists to remove; it stays
available later, because the bar is this column's foot row promoted onto the
glass and nothing here forecloses it.

**Cost:** a desktop window spends 390 points on a menu that used to fill it, so
every page is a phone's page, and the pages that were richer for the room are
poorer: the week's table is the packed two-line row on every window now rather
than a line of columns. The column also covers the corner keys it is docked
over, so MENU and PLAYERS are not drawn or published while it is open, and the
boxes any other furniture published under it are dropped: `M.pick` breaks a tie
on publish order and the HUD publishes first, so covering a box is not enough to
beat it.

**Reconsider if:** a page turns up that genuinely cannot be read at 390 points
and cannot be split, or the stands stop being where players spend their time
between matches, which is the whole argument for keeping the fight visible.

## 64. The ship page is the shelf

**Status:** superseded by
[decision 97](#97-ships-are-preconstructed-and-nothing-is-bought); it
superseded the split between ship and upgrades

**Decision:** the upgrades tab is gone and every slot the arena has is a row of
the ship page. A slot's ladder is circles: solid is a point equipped, a ring in
the slot's own color is a step this account owns and has not spent a point on,
and a dim grey ring is a rung the arena has that the account does not. A row
with a rung still for sale ends in what the next one costs, behind the rivet
mark. Pressing a row's name, or the part of its ladder nobody owns, slides a
reading in from the right: what the thing is, what it does in a fight, how far
it goes, the price, the wallet, and one key that spends it. The chevron or a
swipe right puts the page back. The drawer carries five stops now rather than
six.

Three things move with it. The build library comes off the page into a screen
behind the band's name key, carrying the list, a key that makes a new build and
a key that drops one; rename is deleted, because a build is named when it is
made and a name that wants changing is a new build and a delete. The save key
moves to the foot of the ship page and is drawn only while the thirty points in
hand differ from the build they came from, so its absence is the answer to "is
there anything to keep here". And the ship page carries no head at all: the
wordmark and the call sign come off that line and the page's own band, the
build's name and a points meter, stands there instead, with the x where it
always was.

**Why:** decision 63's split was right about the confusion it fixed and wrong
about what it cost. Two stops drew the same twenty-three slots in the same order
for two questions, and the page a pilot was actually on could not answer the one
they were asking it: why does this ladder stop here, and what would it take. The
answer lived on the other tab, which is a walk rather than an answer.

The shelf is also much smaller than its page suggested. Stats are never sold,
the gun's ladder and most add-on rungs are dealt whole, and what melee actually
sells a new account is eight purchases. Eight prices do not need a stop of their
own, and the stop they had cost a duplicate drawing of the whole slot space.

The old objection, that a wallet and a budget on one screen make the word
"spend" mean two things, is answered by shape rather than by keeping them apart,
and the vocabulary that answers it is the split's own work: points are circles
in the slot's color and their figure is the meter in the band; a price always
wears the rivet mark and the shop's gold; and the wallet is never on the ship
page at all. It is on the reading, which is the one place in the menu anything
is bought.

**Cost:** the ship page is the longest in the menu and now carries rows for
slots the account owns none of, so a phone held sideways scrolls it where it
used to fit. Gold is on the page while a pilot is fitting rather than buying,
which the sparse shelf keeps rare in practice but does not remove. And one
grammar for every row means the add-ons lose the chip they were drawn as, which
was a better picture of a switch than a one-circle ladder is.

**Since it was built,** the three starter builds stopped being special. They
were prepended to every read of a pilot's list and never stored, so they could
not be saved over or dropped and the client had to draw them differently and
explain why. They are ordinary rows now, dealt at account creation and
backfilled once for accounts that predate the change, and the save key, the
delete key and the name check treat them like anything else. A pilot who drops
all three keeps flying: the kit in hand is untouched by a delete, and a hull
with no saved kit falls back to the core's own starter.

The save key also stopped following whether the kit matches some build and
started following whether anything has moved since the page opened. Drawn
against the match, it stood there on a pilot whose saved kit happened to match
none of their builds, offering to keep what was already kept.

**Reconsider if:** the shelf grows enough that eight prices becomes eighty, at
which point browsing what is for sale is its own activity again and wants its
own page; or if the gold on the fitting page proves noisy, in which case
`.design/hangar` holds a drawn fallback, a FIT | BUY toggle over the same rows,
that shares nearly all of this drawing.

## 65. The standings are gone

**Status:** accepted, superseding the week's table

**Decision:** the standings tab comes off the menu and the page under it goes
with it: the week's table, the column heads that ordered it, the box you typed
into to narrow it, the arrows that stepped back a week, and the `/v1/week`
request the client made to fill any of it. The front end carries four stops
now, play, ship, friends and settings, and a match still carries three.

The route itself stays. The site's weekly page is drawn from `/v1/week`, and
`/pilots` is untouched, so the ladder is still published. It is no longer
inside the game.

**Why:** asked for. What comes out with it is the heaviest page the menu had.
It was the only one drawn as a table rather than a list, it kept sort state, a
text field, a week cursor and a request of its own, and it was the one page
that took left and right away from walking back out of itself, which is why the
goldens walk had to photograph it last. The glyph pool sits at 1024 because of
this page: it drew ten pilots of twenty-two at a pool of 128 and gave no sign
it had stopped.

**Cost:** gripe 5 from [match-game.md](../design/match-game.md) is answered
outside the game again. Nothing in the client now says where a pilot stands
over a week; the scoreboard says who is winning the three minutes you are in
and a tier on a nameplate says roughly what somebody is worth, and that is the
whole of it. A player who wants the ladder opens the site.

**Reconsider if:** the week turns out to be what brings players back on a
Monday, in which case the thing to build is a smaller answer than a sortable
table of everybody: where you placed, what moved, and who is above you.

## 66. A game row is one press, and leaving is a button on it

**Status:** accepted, superseding the `leave` stop on the tab row

**Decision:** a press on a game in the games list means one thing everywhere:
be in that game. Where this client already is, that is true the moment it is
asked and the panel goes. Where it is not, the press is recorded in
`menu.await`, the stands dial the zone and go on dialing while a network or an
arena is down, and the panel goes when a room actually answers. Arriving that
way arrives as a watcher, which is what the stands are.

The one exception is a pilot in a hull pressing a different game, because that
press costs the match they are in. It asks first, and the answer that switches
joins the way it always did.

Leaving is a button at the right hand end of the row of the game you are in,
drawn only while you are flying it. It hands the seat back and keeps the room:
you are a watcher in the same arena, the corner offers TAKE SEAT, and the panel
is left standing because nothing about where this client is has changed. Right
is the arrow that reaches the button, which is where it is drawn and the one
thing right had no other use for on a list of games. The short tab row a pilot
in a match gets is play, friends and settings.

**Why:** the three states a player can open this panel in were answered by
three different mechanisms, and two of them lied. In a hull, the way out was a
stop called `leave` at the end of the tab row, which filed leaving beside the
sound settings and a page away from the game it was about, and which meant
"drop the room" where a pilot who wants to stop flying means "give the seat
back". Watching, a press on the game already on screen tore down a working
connection and handshaked its way back to where it already was, behind a card
asking whether that was meant. And with the fleet down, a press did nothing at
all: there was no room to enter, so the act failed silently and the panel sat
there looking like it had not registered the tap.

One act with one name answers all three, because the difference between them is
not what the player is asking for. It is only whether the client is there yet.

`menu.await` is what makes the third state visible. A press is a thing this
client is now trying to do rather than a thing it has done, so the panel is
where it says so: the row wears the dial that is looking for a room, the stands
keep dialing, and `menu.arrived` takes the panel away the moment one answers.

**Cost:** the games list is on the tab row during a match, which is one more
stop than a cockpit had and a page that scrolls where the short row's pages did
not. A row now carries two controls on one line, which is a grammar the rest of
this list does not have and which rests on `M.pick` breaking a tie on publish
order. And a press that waits gives no words while it waits, only the panel
staying up, which is honest but quiet.

**Reconsider if:** a second button turns up wanting the same right hand end, at
which point one row is a toolbar and the friends page's card is the better
shape; or a zone list grows long enough that the row you are in is off screen
when you open the panel, which would put the way out somewhere you have to
scroll to find.

## 67. The scoreboard is a band you press

**Decision:** the clock and the score are one instrument across the top of the
screen, and pressing it opens everything else. Each side of the clock is a
two-line stack in that side's color: a team over its score in a team game, a
pilot over their rating in a duel. The two lines and the gap between them add
up to the clock's own height, so a side is exactly as tall as the numerals it
stands beside and the band reads as one line however many words are in it. The
left side is right-aligned into the clock and the right side left-aligned out
of it. Nothing else rides the band: no rung, no streak, no zone's line of its
own.

A press opens the board, in a column centered under the band. The board is
sections, and the sections are what a zone shares or does not: every zone
stacks the roster, a duel adds the run of fights under it headed by where the
run stands, and any zone's row opens the same pilot box. While the board is up
the fight behind it is washed and every other instrument's type recedes, the
way they do behind the menu, because the board is the thing being read.

The PLAYERS key is gone. So is the sentence across the middle of the arena:
what the room still has to say is a label under the band, and the ladder
stopped saying most of it.

**Why:** four complaints, one cause. The band overran an upright phone, Melee
and Ladder filled it so differently that the two zones looked unrelated, its
type was fixed at 13 and 30 points and read small across a desk, and match
events arrived as 24-point white text over the fight.

The cause is that the scoreboard was three things in three places. A clock with
a score either side of it, a key in the corner that opened the roster, and a
banner in the middle that repeated what both already said. Nothing bounded any
of them, so each grew until it hit something.

One object with one control fixes all four at once. Bounded, because a side is
the height of the clock and the board has a column of its own. Common, because
the chassis is the same drawing in every zone and only the sections under it
differ. Legible, because the type is sized off the window rather than fixed.
And quiet, because an event that used to shout now prints small under the band
or, in the ladder's case, is not sent at all: "rung 3 cleared, next rung 4,
streak 3" was every one of those numbers a second time, and all of them are on
the board a press away.

The band is an instrument, not a control, which is why it does not wear a key's
box or sit in the key row. It is dynamic, colored and progressive; MENU is
static, plain and not. Dressing one as the other was what made the first draft
of this look wrong, and it is why the two now sit at opposite ends of the same
line.

**Cost:** a published hit box over the top center of the arena eats the press
that lands in it, and on a mouse that press is the gun. The box is exactly the
drawn band and no wider for that reason, but a cursor resting up there costs a
shot. A phone gives the band a line of its own under the corner key, because
the dial's own readouts own the top right at 390 points, which is a line of
chrome a monitor does not spend. And nothing on the glass says the band opens
anything: it is an instrument that happens to be pressable, discovered the way
the rest of this interface is discovered, by pressing it.

**Reconsider if:** the gun and the band start arguing on a desk, which would
mean publishing the box only while the pointer is already resting on it; or a
zone turns up whose scoreboard is not a clock and two sides, at which point the
chassis is a third thing rather than the shared one.

## 68. The match ending is the board

**Decision:** there is no ending page. At the whistle the board the band opens
comes up whether or not anybody asked for it, in a column of its own, and
grows a head and a foot: a line naming the side that took the match, a bar
under it carrying each side's name inside its own share of it with the points
on the ends, the roster with the reader's row washed, and a foot with the
countdown and one key.

The list is the board's list, re-ordered once: the side that took it runs
first, whether or not it is the reader's, so the line, the bar and the rows
all read the same way down the page. Inside a side the pilot who did most for
the result comes first, and on the winning side that pilot wears the MVP mark
([decision 76](#76-the-mvp-is-the-winners-best-net) revises what the mark
measures and who can hold it).

One layout at every window size. The measure and the type change, and an
upright phone hugs the foot of the window with the whole block so the key
lands under a thumb; nothing else about the arrangement moves. INVITE FRIEND
is the act the share key performed, named for what a player wants out of it
and sized like a key rather than a banner
([decision 94](#94-the-ending-has-no-foot-and-the-clock-never-moves) takes
that key off the foot, along with the one a guest was offered beside it, and
then takes the foot itself).

Gone with the page: the six phrase chips, the countdown's drain bar, and the
two-column roster. The band stands down while the ending is up, because the
head carries the score and the foot carries the clock
([decision 94](#94-the-ending-has-no-foot-and-the-clock-never-moves) puts the
band back and gives it the countdown, the foot having gone).

**Why:** the page had grown into a second scoreboard. It carried a title, a
score bar, both rosters, six chips, a countdown with a bar beside it and a key
the width of the measure, and once the band could open the board mid-match
most of that was the same content twice. Read on a monitor it was small and
busy, and none of it answered the question a player actually has at the
whistle, which is how they did.

Reusing the board answers that without adding anything: the roster is the one
place this interface says what each pilot did, so the ending says it in the
same rows, in the same columns, with the reader's own row lit the way it is
lit mid-match. What the ending adds is only what the board cannot know: who
won, by how much, and how long until the next one.

The winner-first rule is the one thing the ending does not share with the
band. Mid-fight the partition is "who is with me", because a name is only
worth reading once you know which end of the gun it is on. A finished match
has a better answer to which side comes first, and it is what the ending is
about.

**Cost:** nothing on this client can send a phrase any more. The chips were
the only way to, and the key meant to replace them does not exist yet, so
`SAY_LIFE`, the wire and the roster's own phrase line are kept as the spine of
a feature currently unreachable. The screen a player reads after losing is
also the one that reorders itself, which is the price of the winner leading.
And the board is on screen for the whole intermission whether or not the
reader wanted it, which is the point but is also one fewer thing they control.

**Reconsider if:** the phrase key lands somewhere other than this screen, at
which point the ending has room it does not need; or a zone turns up whose
ending is not a roster and a score, which would make this a melee-and-duel
answer rather than the shared one.

## 69. The account page is a stop on the rail

**Status:** superseded by
[decision 99](#99-the-account-is-a-dropdown-and-the-pilot-page-is-gone)

**Decision:** the home tab row carries a fifth stop, `pilot`, at its far end:
the account page, wearing the helmet mark the interface already uses for a
person. The call sign pill at the end of the top line stays and opens the
same page, as a shortcut rather than a second stop: the arrows walk past it,
and it never lights for the page, because the rail's stop is what says you
are on it. It brightens under a pointer that could take it somewhere and goes
quiet once you are there. The stop is home-only. A benched or flying pilot's
row does not carry it, which is the guard the pill's own press already wore:
an account is not a thing to edit from inside a room.

**Why:** the page behind the name is the whole account model. "Keep this
pilot" is the one control that makes a guest durable across machines, and it
lived behind a pill that reads as a status chip: a name in the corner does
not look like a button, and the one flow a new player most needs to find was
behind the least button-looking control in the menu. A stop on the bottom
rail is the pattern every phone user already knows, in the strip a thumb
actually reaches. The pill stays because it does the other half of the job,
saying who you are signed in as at a glance, and dropping it would trade one
answer for the other.

The pill lit alongside the stop for one commit, and it was confusing on
sight: this row's lit mark means "where you are", and two of them means the
cursor is in two places. Fixing it settled what the name is. A control on
this row is a stop the arrows walk and the light can rest on, or a shortcut a
pointer presses; it cannot be half of each, because a stop the cursor can
reach has to light to show the cursor. The name was only ever a stop because
it was the sole route to an account, and the rail stop retired that job.

**Revised, later:** the name is a stop the arrows walk after all. What the
paragraph above got wrong is that a lit button says one thing. It says two,
and they are separable: "the cursor is resting here" and "this is the page
you are on". The rail owns the second for every page it carries, so the call
sign never wears it; the first is the arrows' own, and withholding it left a
button drawn like a button that no key could reach. That was reported as the
account button being unselectable, which is what it was. The corner row is
Discord and then the name, left to right, and both take the light only while
the arrows are on them at the root.

**Cost:** the row is five stops in 390 points, so every label gives up a
little room. Two controls open one page, which is one more thing to explain
than a single door would be, and walking the row to its end now passes two
buttons rather than one.

**Reconsider if:** the row gains a sixth stop, at which point something has
to leave; or career and stats grow into the client somewhere other than this
page, at which point "pilot" is a name promising more than a password form;
or the name in the corner turns out to be pressed so rarely that it is worth
keeping only as text.

## 70. Sign up, and the pilot page is the career

**Status:** the vocabulary stands; the page is superseded by
[decision 99](#99-the-account-is-a-dropdown-and-the-pilot-page-is-gone)

**Decision:** the account's player-facing words are sign up and log in, and
the pilot page is rebuilt around what the account holds rather than around
the offer. The name leads, large, with the reroll behind a NEW NAME key;
under a ship-page section rule sits the career as bare totals, served by a
new session-authenticated `/v1/career`: the most-flown class's rating and
tier, withheld while provisional the way `/pilots` withholds them, rated
games across every class, the kill and death record, and the rivets already
on the client. At the foot, the one act each state has: a guest's lit SIGN
UP under "Keep your points and log in on other devices" and "Already have a
pilot? log in"; signed in, the password and the way out as a pair of keys.
The reading column is gone, and the sign-up card carries the one explaining
line.

A guest with something to lose, an upgrade bought past the baseline, a
friend made, a rated game flown, gets a band in the caution color standing
on the rail on every tab but the pilot page: "You are using a guest
account. Press here to set your password." The whole band is the press, it
takes its room off the page rather than covering it, and a gold spark rides
the pilot rail stop under the same rule. Before there is anything to lose,
both stay away.

Claiming keeps its name on the wire and in accounts.md; nothing about the
mechanism moved. Sign up attaches a password to the account the guest
already is, and the card says what that keeps.

**Why:** "keep this pilot" named a consequence and hid the act, and the
page around it spent a whole column saying the call sign a third time and
the password sentence a second, over an empty gap. The claim flow is the
one control a surviving player most needs to find, and it lived on a page
nobody had a reason to open. The career gives the page that reason, and a
guest's record standing directly above the key that keeps it is the best
sign-up pitch the game can make. The reroll moved behind a key because a
press on your own name destroying it is a landmine on the row a curious
player presses first.

**Cost:** one more meta call per session and per pilot-page visit. The
banner is chrome that shows up uninvited, which this menu otherwise never
does; the something-to-lose gate is what keeps it from being nagging, and
it is drawer-only, so a guest who never opens the menu never sees it. A
client older than the meta, or the reverse, degrades to a career of rivets
alone.

**Reconsider if:** the banner's gate proves wrong in either direction,
guests with stakes still losing pilots or fresh guests complaining of the
band; or a second place grows that shows the career, at which point the
page and `/pilots` need one shape.

## 71. A game row states its format, and the catalog states the words

**Status:** accepted, amended by
[decision 82](#82-a-game-row-is-a-name-and-its-format)

**Decision:** every row of the games list carries a format strip under its
sentence: three label-over-value stacks reading TEAMS, TIME and SCORING,
with a thin rule between them, in the room band's own grammar. Team Battle
reads 4 v 4, 3:00, kills; Duel reads 1 v 1, one life, rungs. The words
travel on the directory reply beside the label and the description
(`BrowseZone.teams/time/scoring`), derived by the catalog from what each
zone already declares (`ZoneDef::format`): a mode the derivation has no
words for, or a fact a zone never stated, sends an empty string and the
row closes that stack up rather than inventing a number. A directory from
before the strip sends none and the row is the name and the sentence, as
decision 63 left it.

With the numbers in the strip, the two shipped descriptions stopped
restating them and carry the hook the strip cannot: "every rung is a
harder rival; a loss drops you two" and "the longer your run, the bigger
the bounty on you". Catalog v29, renumbered in the merge around the Duel
economy fix that took v28 on main first.

**Why:** the play page was two names and two sentences that never changed,
and Chris's brief, after two rounds of alternatives in
`.design/play-menu`, was a structured description of each zone's format.
The facts live in the zone files, so the client reading them off the wire
means a tuning edit that moves the clock or the side cap moves the strip
with it, and a new zone gets a strip by declaring what it already had to
declare. Liveness ideas lost to the room itself: the stands beside the
drawer already show a game in flight.

**Cost:** three more short strings per zone per browse reply, and a games
list whose rows are a line taller. The derivation is per mode, so a new
mode wants a `format` arm or its rows go without.

**Reconsider if:** a zone wants words the derivation cannot say (a flag
mode scoring something that is not kills), at which point the fields
belong in zone.toml as overrides rather than in a longer match arm; or the
fleet grows enough games that the rows want the aligned table that was
version J of the mocks.

## 72. One field lights a row, at two weights, in one column

**Status:** accepted

**Decision:** a row of the menu is lit by one drawing, `LIT.field`: a wash
in team blue across the full width of the drawer, at the row's full height,
and the hit box every page publishes is the same span, so what lights up is
what a press lands on. There are two weights and nothing between them.
`LIT.CURSOR` at 0.18 is where a press would go, whether a pointer is
resting there or the arrows are standing on it, and whether or not the page
holds the arrows. `LIT.HERE` at 0.07 is where you already are: the game you
are flying, the hull you fly, the build that is loaded. Both can be true of
one row, and the cursor wins, because what a press does next is the more
urgent of the two.

The row you are already on also says so in the color and breathes, on the
clock the landing key breathes on, its ink floored at 0.74 so the trough
never reads as a row that has gone out. A row under the cursor is at full
ink and still, so the one thing moving on the page is always the thing you
left running somewhere else.

The lit wedge that used to mark that row is gone. Two shapes that are not
rows keep the two weights and light their own outline instead of the
drawer: a hull cell in the ship grid, and a rail stop under a pointer. The
lit rail stop keeps the tab gradient it had, which answers where you are
rather than where the pointer is.

**Why:** the menu answered "which row is this" eight different ways. The
stage washed the drawer span at 0.18; the kit page bled left and stopped
fourteen points short of the right edge, at 0.2 falling to 0.1 while the
page was unfocused, with two points shaved off the row's top; the friends
page floated a band inset sixteen points either side at 0.16; the builds
page hung its field past the panel's right edge at 0.2; the hull grid, the
rail and the call sign dropdown drew their own at 0.14 and 0.16. Each was
defensible where it was written and none of them agreed, which is what a
player sees walking from the games list into the hangar. The mocks are in
`.design/menu-rows`.

**And the column the field is lit behind.** The type has one measure too:
`MENU_PAD`, twenty points in from each edge of the drawer, and every page is
handed that column and draws inside it. A name, the rule of the section
above it, a sentence, a price and a count all begin and end on the same two
lines down the panel, and nothing a page sets may cross them.

That was three numbers stacked on each other and it came out different at
each edge and on each page. The panel kept a margin of 14; a gutter of 22
went on top of it for the type; then fourteen points were held back at the
right for the scroll tick and sixteen more on a row's own detail. A row's
name stood 36 in from the left while its price stopped 50 short of the
right, the hangar's names started six points outside the games list's, and a
row's sentence was clamped by nothing at all: at the phone's width the two
shipped zone descriptions ran to within eight and fifteen points of the
glass, straight under the leave key on the row they belonged to. The scroll
tick draws out in the margin now, where there is already room for it, and a
sentence too long for what its row has left wraps inside the column, the
list taking the height of the longest one so the pitch does not change
halfway down.

**Cost:** twenty points is tight enough that the longer of the two shipped
descriptions clears the column by under four, so a description a few
characters longer wraps to a second line and its row grows. That is the
designed behavior rather than a failure, but it means the games list is one
line taller the day somebody writes a longer hook. The head keeps the
panel's own margin of 14 rather than the column: the x and the call sign are
boxes, and a box sits a little outside the type it lines up with.

The focused and unfocused weights on the kit page collapsed into one, so a
kit page that has handed the arrows to the rail still shows its cursor at
full strength.

**Reconsider if:** a page turns up whose rows are genuinely not the width
of the drawer, at which point the field wants to follow the page's own
measure rather than the panel's, and `LIT.field` grows an argument for it.

---

## 73. The community door is the site's, not the game's

**Status:** accepted

**Decision:** the game carries no link to Discord. The corner button on the
menu's tab row, the page it opened, the traced Clyde mark on the rail, the
`DISCORD` constant, and the `/discord` redirect on the game origin are all
gone. The community server is unchanged and so is everything in
[decision 39](#39-the-community-lives-on-discord-and-the-game-only-points-at-it)
about owning it; what moved is the door. It is on the site now, at
`vectorwake.net/discord`, redirecting from the site block of
`deploy/caddy/Caddyfile` rather than from `conf.d/central.caddy`, and the nav
button, the founder's paragraph, the footer, support and the deletion
instructions all point at it there.

**Why:** Chris asked for it. The reasoning that survives the ask is that the
door had been through four placements looking for one that fit, which is what
a control with no home looks like: a section on the play page, then a row at
the foot of it, then a corner button that opened a browser tab, then a corner
button that opened a page about the room with the invite on it. Each move was
a fair answer to the complaint about the one before, and none of them made a
game with no chat into a place where the link belonged. The site is where
somebody is reading about the game rather than playing it, which is the moment
a link to a chat server is worth anything.

It also takes real weight out of the client. The Discord page was the only
outbound link in the menu, so it was the only reason menu rows and rail stops
carried an address for the browser to lay a real anchor over, and the only
reason a row could be drawn as a button rather than as a line of a list. Both
mechanisms came out with it. The link bridge itself stays, because the match
ending's share key still needs a real anchor to copy inside a gesture, so what
was learned about phones and popup blockers is still in the tree and still
exercised by a test.

The tab row is one stop shorter at the corner: the call sign alone, which
never lights for its own page because the rail carries that page and the lit
mark on that row means "where you are". With Discord gone there is nothing on
the row whose page the rail does not lead to, so `corner_lit` answers only
while the cursor is standing on the row.

**Cost:** a player who never leaves the client never learns the server exists.
That is the trade being made and it is not a small one for a game whose whole
social life is off the game. The bet is that the people who would join a chat
server are people who read the site, and that the ones who would not are not
converted by a button in a menu they opened to change the volume. It is
recoverable: the page is in git history and the link machinery is intact, so
putting a door back is a page and a corner stop rather than a rebuild.

Two copies of the invite code exist rather than one, which was true before
this and is worth writing down: the Caddy redirect, and `deploy/site/site.js`,
which asks Discord for the member count beside the button. Rotating an invite
is those two lines.

**Reconsider if:** the server stops growing and the site turns out not to be
where the audience is, at which point the question is where in the game a link
belongs rather than whether one does, and this record's four placements are
the list of answers already tried.

**Cascades:** decision 39 stands, minus its sentence about the game pointing
at the server; `community.md`, `menu.md`, `interface.md`, `friends.md` and
`match-game.md` were updated (`friends.md` is gone with
[decision 95](#95-friends-are-gone)). Decision 28 is untouched: this removes a link,
not a reason.

---

## 74. The duel counts a streak, and names who it beat

**Status:** superseded by [decision 96](#96-duels-are-gone)

**What:** the Duel's board drops the rung and the floor, and the panel under
its roster becomes two sections. The readings say where the run stands, as a
label over a value with a thin rule between the stacks: `STREAK`, `BEST`,
`FIGHTS`. Under them, the last five fights, one row each, naming the rival in
the menu face with what came of it in that word's own color and how long it
took.

The line over the bar reads the way melee's does, a name and a verb:
"Vantage 0001 beaten", "Tessellate 0001 takes it", "drawn", and "every rival
beaten" for a cleared roster. The play page's format strip says `streak`
where it said `rungs`, the zone's hook line is "every win is a harder rival;
one death ends the streak", and the two `Ladder::banner` lines that named a
rung and a checkpoint say neither.

The MVP mark is withheld unless three or more pilots scored.

**Why:** the shipped panel headed a list of fights with `RUNG 6  FLOOR 6` and
put a rung number on every row. A rung is a roster slot and a floor is the
checkpoint a loss cannot cross, and the screen that named them explained
neither. The rung was then said a third time over the bar. The rival, the one
thing on the panel that is a person, was nowhere: the roster names whoever you
just fought and forgets them at the next whistle, so a run of twelve fights
was twelve slot numbers and no opponents.

Two smaller faults went with it. The middle column read `1-0` or `0-1` on
every row, because `ladder_first_to` is 1 and catalog validation refuses any
other value, so all it ever said was that somebody died. And the streak, the
one number a climber says out loud, was hidden at zero under a rule that a
streak of none is not a streak, so it was missing exactly on the screen a
player reads after losing. It reads zero now.

The MVP mark had the same shape of fault. In a first-to-one duel the winner is
the only pilot with a kill, so the best gun in the room is always whoever just
won and the mark was the bar over it said again. Three scorers is where a
prize starts picking somebody out rather than restating the result.

The readings sit above the fights and not inside their head. They were drawn
in the head first, where the roster's own `K D A` sit, at the same size under
the same ticked rule, and a shape is read before the words in it are: three
readings in the heading slot are read as headings for the columns under them.
The list has no head at all now. Mocks and the passed-over drawings are in
`.design/duel-run`.

**Cost:** a leg has to carry a call sign, because by the time the board draws
one the rival's seat belongs to the next rung. That is `CallSign` on
`modes::LadderLeg`, `rival_name` on `ModeCtx`, and a variable-width leg on
`S2C_MATCH`: a result byte, two seconds, a length and the name. The window
shrank from twelve legs to five, which is what the panel draws, and the
scoreline left the wire with the column, so the packet is smaller than it was
despite the names. Protocol 25, catalog v30.

`best_streak` is a number the run did not keep. It is a max over the streak,
one `u32` on the wire, and it is what gives the readings something to say the
moment a streak breaks.

**Reconsider if:** the floor stops being a kindness nobody reads. It is still
there, unnamed: a loss drops two rungs and stops at the last checkpoint, so a
run deep enough cannot fall to the bottom. Either that stays an unstated
mercy, or the streak becomes the mechanic outright, a win putting a harder
rival across the arena and a loss putting back the first. The board draws the
same either way, which is why this decision does not settle it.

---

## 75. The head is a row of its own, and every page carries it

**Status:** accepted

**Decision:** the two controls on the drawer's top line, the x that shuts the
panel and the call sign that opens the account, are a row the arrows walk.
Left and right step between them and loop; down goes back into the page under
them, at the top of it; enter presses what it is on; up does nothing, because
nothing is drawn over that line. A hand reaches the row by pressing up off the
first row of a page. Away from home the call sign is not a stop, since an
account is not a thing to edit from inside a room, and the x is the whole of
the row.

The rail is the tabs and nothing else. An arrow off it is a step in a
direction: up walks into the page from underneath and lands on its last row,
down comes in over the top and lands on its first, and neither of them opens a
page whose first control is a text field. A page's own band is not the top of
its list, so down into the ship page lands on the first ladder rather than on
the build's name. Enter is the one press that is not a direction, so it is the
one that still lands where the page was left and still opens a field page with
the cursor in the box.

Every page carries the head. The ship page and the four screens it opens draw
their own band under it rather than on its line.

And the settings page lost the block under its rows that explained whichever
row the cursor was on.

**Why:** Chris reported these in one message as separate bugs. The navigation
ones are one bug: the panel is three rows stacked down a column, and only two
of them were being walked as rows.

The x and the call sign were the far end of the tab row
([decision 73](#73-the-community-door-is-the-sites-not-the-games) records the
last of the reasoning), which put a horizontal wrap between a row along the
foot of the column and a button at the top of it. Pressing right off the last
tab moved the cursor the height of the panel sideways, and the two lit
highlights a hand met walking that row were nowhere near each other. Up off the
first row of a page went to the tabs at the foot, so the one control the arrows
could not reach was the one at the top of the panel, which is where somebody
pressing up is looking.

The rest follow from the same reading. Up and down off the rail both landed
wherever the page had last been left, so pressing up on `ship` to read the foot
of the kit and then pressing down on it again lit `wake` at the bottom of the
page: the arrow pointed one way and the cursor went the other. Pressing up on
`friends` opened the add box at the top of the page when what it was reaching
for was the last name on it, because entering a field page always opened its
field. And the ship page dropped the head when it was entered, so walking into
it from the rail jumped the whole panel up by the height of its own head, and
left one page where the account was unreachable by any key.

The settings block is the separate one. It said the selected row's name, its
value and its help line back to somebody who had just walked onto that row, and
it moved every time the cursor did. Everything in it was already on the row.

**Cost:** the ship page gives up about seventy points of height to the head it
now carries, which on a phone held upright is two or three ladders' worth of
list before it scrolls. The page has scrolled and carried a scroll thumb since
it became one page, so this is a page that scrolls sooner rather than a page
that scrolls where it did not.

The head is reachable only from the top of a page. From the rail it is up into
the page and then up through it, which is a walk; the account also has a rail
stop of its own at home, so the walk is never the only route.

**Reconsider if:** the ship page turns out to need the height more than it
needs the head, at which point the answer is a shorter head rather than no
head: the line is a 26 point square at one end and a pill at the other, and
there is air around both.

## 76. The MVP is the winner's best net

**Status:** accepted

**Decision:** the mark on the ending's roster goes to the pilot with the
highest kills less deaths on the side that took the match. A pilot on the side
that lost cannot hold it, however the match went for them personally, and a
draw hands out nothing because there is no side to hand it out. Level on net,
it goes to the one with more kills. The two rules already on it stand: only at
the whistle, and only once three or more pilots have scored, so a pilot who
never shot anything down is not in the running.

The ending's list sorts each side by the same number, so whoever wears the
mark is the top row of their side and the page reads in one direction.

**Why:** it was the most kills in the room, ties to the fewest deaths, which
is a different question from the one the mark is asking. A side's score is the
kills its pilots landed and nothing else, so a death is a kill handed to the
other side: the pilot who took eight and gave back seven moved the match by
one, and the pilot who took four and died twice moved it by two. The column
was reporting how much of the fight somebody was seen in. The mark now reports
what came of it.

Restricting it to the winning side is the other half. The mark was landing on
the losing side often enough to be its own reading, since the pilot carrying a
side that still lost tends to have the busiest kill column in the room. That
mark says the match was won by the wrong team, which is a thing a scoreboard
should not be telling anybody: the match is the result, and the prize on it is
the winner's to hand out.

**Cost:** the reader's own row can now hold the best numbers on the board and
no mark, which will read as a snub the first time it happens to somebody. It
is the correct snub. Their side lost.

Kills less deaths also goes negative, and most of a losing roster sits there,
which is fine while the mark is winner-only but rules out ever showing the
number itself in a column without deciding what a negative one looks like.

**Reconsider if:** a zone turns up whose score is not the sum of its pilots'
kills, at which point net is the wrong arithmetic rather than the right one
and the mark has to ask that mode what a pilot contributed. Or if assists get
priced into the score, since a pilot who does four fifths of the work on every
kill in the match would still be nowhere on this measure.

## 77. A duel that runs the clock out is a draw

**Status:** superseded by [decision 96](#96-duels-are-gone)

**Decision:** the Duel match timer ends the life. Whoever is ahead takes it,
and a life nobody has scored in is a draw. A drawn leg is filed like any
other: it goes on the run's board as its own row, it moves no rung, it breaks
no streak, and the same rival is fought again. Sudden death is gone, along
with the banner that announced it.

The calibration harness keeps flying past the whistle, which is the one place
in the game that now outlives the rule. It is measuring which pilot wins when
the fight is played out, and a draw there would censor the matchups the
ranking most needs to separate. That is stated at the constant so nobody
tidies it into agreement with the mode.

**Why:** a duel is one life at first-to-one, so no score exists until somebody
dies. That is what put sudden death here: with nothing to compare at the
whistle, the clock could not call the rung, so the fight carried on until a
death did. It reads as the fair answer and plays as the wrong one. The timer
was doing a job already, which is stopping a pilot from running out the clock
on a rung they are losing, and overtime hands that same pilot the rest of the
evening instead. Two pilots who have spent three minutes not closing are not
usually thirty seconds from closing; they are flying a fight neither wants,
and the room's answer was to keep them in it.

A draw is also a result the mode already knew how to file. A double death has
always produced one, so the leg, the byte on the wire and the "drew" the board
draws were all in place; the whistle now reaches the same door.

**Cost:** a rung can now end with nothing decided, which is a worse outcome
than either pilot wanted and the only one honest about what happened. A
climber meeting a rival they cannot beat and cannot lose to will draw them
repeatedly and sit on the same rung, where sudden death would eventually have
moved somebody. It moves them by handing the win to whoever blinks first,
which is not the thing the ladder is trying to measure.

The clock also becomes worth playing to. A pilot who is ahead can now sit on a
lead, which is a tactic Duel has never had, and at first-to-one being ahead
means having already won, so this costs nothing today. It would cost something
the moment first-to rises above one, and the catalog refuses that.

**Reconsider if:** draws turn out to be common between well-matched pilots
rather than rare, at which point the timer is too short for the fight rather
than the rule being wrong, and the answer is a longer clock. Or if the ladder
starts wanting every rung settled, which would need a decider that measures
something other than who dies first: damage dealt, or distance held.
## 78. The friends page is who is on, and one way to reach who is not

**Status:** superseded

The page is gone and so is the feature under it, per
[decision 95](#95-friends-are-gone). What follows is the record of what it
was and why it was shaped that way, which is what the next attempt at the
question would want to read first.

**Decision:** the page is four things down the screen: a field that takes a
call sign, the adds waiting on an answer under RECEIVED, your friends, and a
key at the foot that hands the game's address to whatever the device shares
with.

A friend is one line: a dot, a name, and the game they are in. The dot is
solid green while they are flying and a hollow grey ring while they are not,
and the game is named the way the games list names it, so a friend is in Team
Battle rather than in melee. A friend who is off carries nothing beside their
name. No key is drawn on those rows; join and unfriend are on the card the row
raises, which is where five inputs always had to find them.

Three sections are gone: the roster of the room you are flying in, the adds
you had sent and nobody had answered, and the ledger of everybody who had ever
added you. `/v1/friends` stops computing them as well as the page stopping
drawing them.

**Why:** the page answered its three questions and looked like none of them.
Five headings deep before it said who was on, an identical row grammar for
every one of them, a key or two on every row with unfriend drawn three times
for each join, and the fact the page exists for reduced to a six-point square
and a dim word. The one thing worth crossing the room for was the quietest
thing on it.

The sent list was a receipt for a press whose consequence is a row on somebody
else's screen. The ledger was context under a heading nobody opened this page
to read. The room roster is the one with a real job, and the cost of cutting
it is below.

**Cost:** adding somebody you have just flown with is now typing their call
sign rather than pressing a key beside their name. The room roster was where
most friends were made, and the in-match pilot box's key is a team invitation
rather than an add, so nothing else in the client offers a name to add. The
completions take most of the sting out of it, since a letter is enough to
start and pressing a name adds that pilot by number, and a call sign is
readable off the scoreboard the match just showed. It is still the press this
decision spends, and the first thing to put back if adding falls off.

Ignoring is final now. The ledger was where an ignored add could
still be accepted, and with it gone the ignore is the end of that ask: nothing
draws it and nothing can take it back. `friend_ignores` still holds the row,
so the pilot who was ignored cannot ask again, which is what it is for.

Joining a friend is two presses rather than one, since the row raises the card
and the card carries the join. A one-press join needs a key on the row, and a
key on the row is the grammar this decision is spending to be rid of.

The invite key sends the site's front page rather than anything that knows who
sent it, so a pilot who invites four people and gets one is told nothing about
it, and the new player arrives with an empty friends page rather than with the
person who invited them already on it.

**Reconsider if:** the invite is worth closing the loop on, which is a token
on the link and a signup that seeds the edge, and would turn the key at the
foot into the thing that actually fills the page above it. Or if somebody
reports being unable to undo an ignore, at which point the ledger comes back
somewhere quieter than the page it used to close.

## 79. The sky is the map's, and it has weather in it

**Status:** accepted, amended by
[decision 93](#93-the-sky-has-nothing-in-it-with-a-shape)

**Decision:** the background is no longer three layers of star and a round
fade. It draws, from the back forward: two enormous washes under everything, a
band of fine grain and dust filaments along one diagonal, clouds strung out as
runs of knots rather than round smudges, three depths of star in four
temperatures with a rare one burning a four-point cross, and a near layer of
dust that draws as dots standing still and as streaks under way.

The suns, the comets and the lens flare described below are gone; decision 93
says why. The rest of this stands, and everything it says about the set pieces
is the record of what was tried.

Everything that is not hashed from its own position is placed from the map's
name: the band's angle and where it runs, the two washes, and how many set
pieces there are with the size, color, depth and distance of each. A map may
get two suns, or none, and a sky with nothing in it but stars is a fine sky.
So a room has a sky of its own, and has the same one every time it is played.

One of each at one size in one color made every room look like the last one
seen from a slightly different chair, which is the same complaint the band
drew: its density test ran off a Lehmer hash, and Lehmer is affine, so walking
a grid a cell at a time walked the output by a constant and the test landed on
a lattice sixteen cells wide. Measured over a grid, a two by two block of cells
all carrying a star came up 0.250 of the time where independent draws give
0.436. Squaring the value between two Lehmer steps breaks the line, because the
cross term depends on what is being squared rather than only on the step; the
same measurement then comes to 0.440 against 0.440.

The two set pieces sit at middling depth rather than out with the band. A
match room is a hundred and sixty tiles across, and anything drawn at the
band's depth moves a couple of hundred pixels while a pilot crosses the whole
map, which is wallpaper in the corner of the screen for three minutes. At a
quarter and two fifths of the camera's rate they arrive and leave as you fly,
which is what lets a side be told to regroup under the comet.

The sun throws a lens flare, which is the one thing here that is not out in the
world: a flare happens inside the camera, so its ghosts are laid out on the
frame rather than in the sky, sitting on the line from the sun through the
middle of the view. They are hexagons because a six-bladed iris is a hexagon,
warm on the sun's side of the middle and cool past it. The chain swings about
that middle as the sun crosses the frame, passes through it and comes out the
other side, and goes out as the sun leaves. It draws on the sky's own layer
with everything else, so a wall cuts it: over the map would be truer to a
camera and would put bright geometry across the fight.

The sky draws under the map, in two passes of its own that the render script
puts before the wall interiors. That is where its occlusion comes from: a wall
interior is opaque and is drawn on top, so the sky behind it is not there.

**Why:** the old field was correct and boring. It had real depth in it, from
parallax that costs nothing to store, and nothing to look at: a flat sprinkle
over a flat black, the same in every room of every zone. The constraint that
shaped it is still the right one, and it is not a constraint against having a
sky. It is a constraint against a sky that competes with a projectile, which
is a question about brightness and placement rather than about how much is
there. So the clouds stay faint enough to read as distance, the sun is dim and
thrown far enough out to sit at the rim of the view instead of over the fight,
and the band's grain is no brighter than the far stars already were.

That pass order is a correction rather than the original plan. The sky shipped
sharing the fill layer with everything else, over the wall interiors, and each
star asked the core whether it stood on a solid tile so it could take itself
out of the drawing. That works for a star and cannot work for a sun: two
hundred pixels of set piece is over a wall and behind it at the same time, and
no single answer about its center covers that, so the sun and the comet drew
straight over the map. Under the map the question does not come up, the clip is
to the wall's real edge rather than to the tile it stands in, and the eight
hundred and seventy crossings into the core the culling cost every frame are
gone with it.

The band is the one that had to be argued with twice. Written with a half
width of eight hundred pixels it put the whole window inside itself, which
draws as a starfield with the density turned up rather than as a band; it
needs to end somewhere inside the window, with plain sky on both sides. And it
is the expensive part: the whole sky costs 0.52 ms a frame in plain Lua at
1280 by 800 against 0.20 before, and reserves about half a megabyte of vertex
buffer on a laptop against two hundred kilobytes. Three percent of a frame at
sixty is a fair price for the room looking like somewhere.

**Reconsider if:** a zone wants a sky of its own rather than one derived from
its map names, which is the open question identity.md already carries about
how much a zone gets to change. Or if the band's grain turns up in a profile
on a real phone, where the crossings into the core to ask what is behind each
star are the part that would show first.

## 80. What the menu pins at a foot stands on the rail

**Status:** accepted

**Decision:** the column's page runs down to the rule the tab row hangs
under, and the three things pinned at the foot of it are drawn against that
rule: the guest warning, the friends page's invite, and the pilot page's
account keys.

The invite becomes a band of the guest warning's shape. Edge to edge of the
column, standing on the rail, a line saying what the press is for over a line
saying to press, the whole of it the target, and the browser's share anchor
laid over the whole of it rather than over a key inside it. Both bands are 46
points tall and both begin their words in the column every page's type stands
in. The color is what tells them apart where a guest opens the friends page
and gets both: gold warns, green offers.

The keys at the foot of the pilot page stay keys, because a full-width band
that is really two buttons is neither. They clear the rule by the twenty
points the column keeps at its sides, which is the only margin this drawer
has.

**Why:** the guest warning sat on the rule and the other two stood forty
points clear of it, which on a phone looks like furniture that has come away
from the bottom of the panel it belongs to. The forty points were two numbers
nobody had put beside each other. The stage stopped fourteen points short of
the rail, and the room handed to a page took another twenty-six under that for
the one line of notice drawn across the foot of the stage. That line is a
refusal on the ship page or a confirmation on the bindings page, both of them
answers to a press somebody just made, so nearly every frame of nearly every
page had nothing to put there and paid for it anyway. The reservation is taken
when there is something to say, and the pages get the rest.

The invite had a second problem the spacing was hiding. It was a labeled key
floating over a rule with the page's own ground under it, which reads as the
last row of a list that has run out rather than as the foot of the panel, and
it was the only thing in the menu shaped that way.

**Cost:** two bands stacked is a lot of foot for one page, and the friends
page is where it happens. A guest with something to lose loses 92 points of
list to them on the one page whose list is the point. The alternative is
suppressing one of the two, and neither is the one to suppress: the warning is
about an account that can be swept, and the band under it is the page's only
answer to an empty friends list.

The one-line notice can now move a page. A frame that has something to say
pulls the foot up 26 points for as long as it says it, where before the room
was always missing and nothing ever moved. What that trades is a permanent
strip of nothing for a rare step under a sentence somebody just caused.

**Reconsider if:** the two bands on the friends page prove to be one too many
in a real hand, at which point the invite is the one that gives way, since the
empty state above it already offers the same act in words.

## 81. The menu's pages all begin one margin under the head

**Status:** accepted

**Decision:** the air between the bar at the top of the menu and the page
under it is MENU_PAD, on every page, and it is written once. The stage begins
at the head's rule, `STAGE_TOP` is the whole of what a page holds back from
it, and there is no second number and no branch on what kind of page it is.

MENU_PAD because that is what the column already keeps back from each of its
two side edges. A page is inset the same from the bar over it as from the
edges beside it, so the drawer has one margin rather than one for the sides
and another for the top.

What stands on that line is whatever object the page opens with: a row's lit
field on a list, the ship page's band, the box on the friends page. Where an
object centers something inside itself, the type falls where the object puts
it, which is why the first word on a page is not at the same height on all of
them and should not be made to be. A name centered in a row tall enough for a
sentence and a strip of figures sits lower than a label near the top of a
section head, and both are right.

The friends page's add box goes with it. Its label sat eight points down while
every other label on that page sits where a section head puts one, so it is a
section head now like the rest, with the head's own rule left to the one
already drawn under the bar.

And a section head is one object with one set of numbers. The list drew its
rule at 0.45 of the head and its label at 0.85; the friends page drew the same
head at 0.42 and 0.82, so the first label on the settings page and the first
on the friends page sat most of a point apart for no reason either of them
could give. Both read `pages.SECT_RULE` and `pages.SECT_LABEL` now.

**Why:** the gap was three numbers with a branch in the middle. Eight points
were taken where the stage begins, thirty more where the page begins, and ten
instead of the thirty for a page carrying a band or a head of its own. Nobody
reading either site could say what the air under the head was meant to be,
because neither site held the whole of it.

The thirty was room held for two things that had moved out from under it: the
ticked rule that used to introduce a list, and the way out, which sits on the
head row now beside the call sign. Its own comment still said so. What it left
behind was thirty-eight points of nothing over the games list against eighteen
over the hangar, and then each page's own lead-in on top of whichever it got.
Measured off the head rule, the first word on a page landed anywhere from 42
to 61 points under it depending on which stop you were standing on. It is 40.2
to 44 now. Walking the tab row, the panel appeared to change height under a
hand that had not moved.

This is the same fault decision 80 found at the other end of the column, and
the same sentence answers it: two numbers nobody had put beside each other.

**Cost:** the pages that carried a band gain two points rather than losing
any, since eighteen was under the new twenty. Nothing here makes the first
word on a page land at the same height on all of them, and the four points
left over are the objects rather than the gap: a 48-point band centers its key
and sets its type at 24, a 24-point section head puts its label at 20, and a
list row sets its name at a fraction of a row height that moves with what the
row holds. Forcing those to agree would push the band's key off its own
center, which is a worse fault than the one it would fix. Nothing else in the menu moves
sideways or changes size, and the room a page has grows by what the gap gave
back, which on a list is another row and a half on a phone.

Tying the top margin to MENU_PAD means a change to the column's side margin
moves the head's gap with it. That is the point, and it is worth saying out
loud, because it is also the way this comes back: a future edit that wants the
sides wider and the top where it is has to say so, and say why.

**Reconsider if:** a page turns up whose first object cannot stand on that
line, at which point the answer is the object's own shape rather than a second
number here.

## 82. A game row is a name and its format

**Status:** accepted

**Decision:** the games list drops the sentence under each name. A row is the
game's name with the format strip under it, TEAMS, TIME and SCORING in the
words the catalog states, and nothing else. The strip moves up into the line
the sentence held and the row is 70 points tall rather than 86, with the same
seven points of air over the name and under the values that it had before.

The sentence is gone from the wire and from the zone files with it.
`ZoneDef::description` and `BrowseZone::description` are deleted, so is the
copy `WireZone` carried to every arena, and `S2C_ZONE` is the zone's name with
nothing after it. `ZoneConfig::description` goes too, since a local zone
file's sentence existed to fill that same second line. Catalog v32.

**Why:** Chris asked for the two descriptions to go, and what they said the
strip already says. "Every win is a harder rival; one death ends the streak"
sat over TEAMS 1 v 1, TIME one life, SCORING streak. "The longer your run, the
bigger the bounty on you" sat over 4 v 4, 3:00, kills. Decision 71 put the
strip under the sentence and rewrote both sentences to carry what the numbers
could not, which kept two answers to one question on every row, and the
sentence is the answer nobody has to read.

Nothing else read the string. The client dropped the second line of `S2C_ZONE`
at both places it draws a zone, the debug readout and the head of the rooms
panel, so the games list was the only surface it ever reached.

**Cost:** a zone can no longer say anything its mode's `format` arm has no
words for. A flag zone scoring something that is not kills gets three stacks
that do not describe it and no sentence to say so. Decision 71 already names
that fix: fields in zone.toml as overrides rather than a longer match arm.

**Reconsider if:** two games arrive whose strips read alike and play
differently. Telling those apart is what a sentence is for, and the row has
the room for one.

## 83. Settings is the last stop on every row

**Status:** accepted

**Decision:** the tab row ends with settings wherever the panel draws it. At
home that is play, ship, friends, pilot, settings. A benched pilot gets play,
ship, friends, leave, settings. A pilot in a hull gets play, friends, settings,
with ship back in the window between matches where the hull is not locked. The
fourth slot is the stop that answers where you are standing, `pilot` at home
and `leave` in a room, and settings sits behind it at the end.

**Why:** asked for. Settings was fourth of five at home and last in a match, so
the one stop that is on the row in every state was in a different place
depending on the state, and the code comment beside it claimed the opposite:
"Last, in the place it holds on the row a pilot sees everywhere else." Nobody
chose the order. The account stop arrived with decision 69 and was appended to
a row that already finished with settings, and the append is the whole of the
reason.

The outside argument says the same thing twice. A phone's tab bar either ends
with settings or does not carry it at all: WhatsApp and Telegram close the row
with it, while Instagram, TikTok and YouTube keep it off the row and put it
inside the account page, which is also Apple's guidance, that a tab bar carries
top-level content areas rather than a drawer somebody opens twice a year.
Ordering a row by how often each stop gets pressed lands settings at the end
either way, because it is the least pressed stop we have and the only one that
is not part of the game.

The second of those conventions is closed to us, and the row itself is why.
`pilot` is off the row a match gets, since an account is not a thing to edit
from inside a room, and settings is the only route to sound, to fullscreen and
to the controls reference on a phone in a match. Folding one into the other
would strand a player who needs to mute the game.

**Cost:** the call sign at the far right of the top line is the second door
onto the pilot page, and a pilot stop at the far right of the tab row rhymed
with it. That pairing is gone.

`leave` moves with `pilot`, because the two share the slot. It had been last on
the benched row, which is where a way out usually goes. Holding it there would
have meant fixing the order at home by breaking it one state over, which is the
thing this decision is about.

**Reconsider if:** the pilot page is ever wanted on the row a match gets. That
is the one change that would let settings fold into it the way most phones do
it, and the row would drop a stop rather than reorder one.

## 84. The menu has one type system

**Date:** 2026-08-27

The menu was set in two faces, fifteen sizes and no contrast floor, and on a
desktop it was small as well. Driving the shipped menu and reading back every
run of type it asked for: 34 of 91 runs across the five pages landed under the
4.5:1 that small type wants.

Three rules replace all of it.

**Face is decided by one question:** would you read it aloud as a sentence, or
look it up in a column? Language takes the menu face, values take the mono. That
rule was already written down in `docs/design/interface.md` and was followed in
one place, so every sentence in the menu was set in DejaVu Sans Mono at 11.5
points. Moving them is close to free: weighted by English letter frequency the
menu face sets at 0.511 em against the mono's 0.602, so 14 points of it runs as
wide as 11.9 points of mono. `wrapped` takes a face now, because a line has to
be measured in the one it is set in.

**Text draws at alpha 1,** and state says itself with a color instead. Every
failing site was a fraction of alpha on a color with no headroom, so one rule
deletes all of them. `pal.DIM` is that color: 4.68:1 on the column at full
alpha, which cannot survive being drawn on a lit row, and thirty-three call
sites passed it a fraction. `pal.READ` and `pal.MUTE` replace it in the menu at
9.81 and 6.54, both measured on the three grounds a row actually has. The worst
number in the menu is now 4.61.

**Sizes come from a ladder of five:** LABEL 12, BODY 14, ROW 17, LEAD 21, PAGE
26. There were fifteen, near enough all of them bare numbers at the call site,
with four fifths of a page at 13 points or under.

And the menu multiplies its whole scale by 1.25 on a window with room. It had a
constant for this, `MENU_ZOOM` at 1.18, which went out with decision 63 and was
never replaced, so for five decisions the menu was a phone screen shown on a
desk. A phone keeps the measure it already had.

**Cost:** a plain row name is 17 points against 18 on a phone, and the call sign
in the head steps down a rung to LABEL. The head is a strip of fixed height
sharing its width with the way out at one end and the line meter at the other,
and at BODY the longest call sign anybody can register leaves a phone 54 points
for a readout that needs 80. Everything else on a phone got larger.

**What the sweep turned up:** `stage_row` wrote a room nobody is serving back a
shade with `col = pal.a(col, 0.6)`, and both places that draw the name ask for
`pal.a(col, label_a)`, which replaces an alpha rather than multiplying one. The
0.6 was thrown away, so the name drew at the weight of a room you could join
while the figures under it dimmed through a separate multiplier that worked,
down to 1.97:1. The row said the wrong half of itself quietly. A register
carries it now, which cannot be discarded by the next hand that sets an alpha.

**Reconsider if:** a page turns up that needs a size between two rungs. The
answer is to move a rung rather than add one, since fifteen sizes is what
adding one looks like fifty edits later.

## 85. A burst shuts its own key for a second and a half

**Status:** accepted

**Decision:** every charge kind keeps a firing clock of its own, read off the
same `delay` a trigger's pattern uses, and the burst's is 150 ticks, which is
the bomb's own delay and the longest wait any weapon here asks for. The
repel's stays at zero. Nothing else about a burst moves: the same twenty-four
rounds at the same damage, the same rack of three, still dealt once a match and
still not handed back by a death.

The clock is per kind rather than one over the rack, and it is not cleared by
dying. It belongs to the ammunition, and a match start is the only thing that
refills the rack, so a whistle clears it along with the rest.

A key that does nothing has to look like one, so the corner rail and the touch
cells wash a kind's row down on the tick it goes and bring it back as the clock
runs out. The ticks left travel in the owner-only tail of a snapshot, because
the clock is set at a press that may be older than the tick a snapshot begins
from and a client that could not read it would predict a key the zone has shut.
That is protocol 26.

**Why:** inventory was the whole limit, and inventory limits nothing at the
scale a hand works at. Three presses take a tenth of a second, a burst costs no
energy at all, and three rosettes thrown from one standing position is
seventy-two rounds, of which three end anybody. So the play was to fly at
somebody and empty the rack, and what it asked of the pilot was one approach:
the second and third bursts asked nothing the first had not already asked. That
is a weapon that beats a better pilot without out-flying them.

The number prices the cadence and not the fight. Emptying the rack takes three
seconds now, where three presses took a tenth of one, which is long enough that
the second and third bursts are flown between and aimed separately, and short
enough that all three are still available inside the exchange the first one was
thrown into. A wait that pushed the next burst into the next fight is several
times this: five seconds was written first and rejected, because it decides
what a rack is for as well as how fast it may be spent, and that is a bigger
rule than this one needs to be. The number to move if the fly-in survives is
this one.

Per kind, because the two kinds are opposite things. A repel is the answer to a
round already in the air and is wanted precisely when a fight is going badly,
so shutting it because a burst had just gone would take the answer away at the
moment it is asked for. It also does no damage, which makes chaining repels a
way of wasting them rather than a way of winning.

**Cost:** a pilot who wants two bursts in one fight still has them, a second
and a half apart. This does not end the fly-in on its own. It makes the pilot
fly for three seconds under fire to spend the rack rather than press a key
three times, and whether that is enough is the open question here.

The number is also argued rather than measured. The authored bots throw a burst
only at close range on a nearly empty bar, so the melee probe has nothing to
say about the case this fixes, and the evidence is the arithmetic above and not
a run. Twenty matches on gantry either side of the change say only that the
room still plays the same: 59.5 rounds in the air against 60.1, the repel rack
spent at 61s, 102s and 131s against 58s, 100s and 129s, skill against k/d at
+0.86 against +0.93.

The wire and the mirrors also grow: eight bytes on every owner record, one more
array on the ship, and one more thing the two ends have to agree about, which
is what the protocol number is for.

**Reconsider if:** a pilot can still fly in and end somebody on two bursts a
second and a half apart, which would be this number too short rather than the
rule wrong, and the answer is a longer one. Or if matches start ending with
bursts still in the rack, which is the same lever the other way. Or if the
fly-in comes back off one burst alone, which would be what a burst does at
contact range rather than how often it may be thrown, and the answer is its
damage instead.

## 86. The dial hugs the corner the link bars left

**Status:** superseded by
[decision 107](#107-the-dials-two-readings-stand-over-it)

**Decision:** the radar sits hard in the top right, one PAD from the top edge
and one from the right, which is the margin the way into the menu keeps from
the corner opposite. Same margin on both axes and at every window size. Its
POS caption hangs under its foot everywhere rather than standing above it on
the windows wide enough for that, and the clock band, which used to grow to
the screen's own edge, stops at the radar's left side again.

The map keeps the lower line both of them used to start on. It is two thirds
of the window's short side, which on an upright phone reaches past the middle,
so a map on the row would have the clock drawn over it, and capping its width
to clear the band leaves something narrower at 390 points than the radar it
grew from. The row's end stays the radar's resting edge for the same reason,
so opening the map does not take a name off the band.

**Why:** asked for. The dial used to start a key's height lower because the
LINK bars stood in the strip above it, and the bars went into the head of the
menu a day before this. Nothing replaced them, so the instrument was left
indented off a row that no longer existed, which reads as having slipped down
the screen rather than as leaving room for something.

Both instruments anchored to the top of the window now hang off one padding
instead of one of them hanging off the other, which is the whole of what
`PAD` was already for.

**Cost:** an upright phone gives up the two side names on the band. 390 points
hold the way into the menu, a centered clock and a 112-point dial, and a call
sign does not fit in the eighteen points left over. The figures under the
names always draw, the board a press on the band opens carries both names, and
a phone held sideways has 844 points of row and keeps them.

The band gives up both names or neither, which is new. Each side used to be
measured against the end of the row it faced, and those ends are not the same
width: a small key at one and a square a third of a phone across at the other.
So the left name drew while the right one was dropped, which reads as a fault
rather than as a band that has run out of room. The pair is the unit now, and
the cost is a monitor with one very long call sign and one short one, where
both go instead of the long one alone.

**Reconsider if:** a phone's band is wanted with names on it. The dial would
have to give up about a third of its width to pay for one, and it was cropped
to 112 points on a phone already; the reach that crop bought back is worth
more than a name that is on the board one press away.

## 87. The tile readout goes

**Status:** superseded by
[decision 107](#107-the-dials-two-readings-stand-over-it)

**Decision:** POS and the pair of numbers beside it are gone from the arena.
Nothing is captioned in that corner now. The radar keeps its whole square, the
feed starts a gap under it rather than under a line of type, and `radar_span`
is the instrument and that gap.

**Why:** asked for, one commit after decision 86 moved the readout under the
dial's foot. Moving it was what made it worth looking at, and what a look
found is that the instrument it now hangs off already answers the question.
The dial is a picture of where you are, sixty tiles wide with the terrain in
it. A pair of tile numbers is the same fact written out, and written out is
not the form a reading gets taken in mid-fight.

Two things go with it. `TOP.coord_line` measured a line for the caption alone
and has no other reader, and the hover zone the dial published was placed so
that a word beside it could be hung off the square's full height rather than
off one line of type. Nothing in the client reads a zone called `radar`: the
card that reads zones knows the corner stack's rows and nothing else.

**Cost:** the exact figures are not on screen anywhere now. Nothing else
writes them out: the debug readout behind the link meter is frame times and
wire statistics, and the map draws you as an arrow over the whole arena rather
than as a number. A pilot who was calling a position across a room has the
dial to read by eye and nothing to read off, which is the whole of what this
takes away.

**Reconsider if:** a mode arrives where a named place matters, a flag post or
a base to call, in which case the answer is probably a name on the dial rather
than the numbers back in the corner.


## 88. A phone's reverse is a stance, not a push

**Status:** accepted

**Decision:** a double tap anywhere on the stick's half of the screen flips the
ship into reverse, and it holds until another double tap flips it back. The
stick names the course either way. Reversed, the nose is held at the far end of
that course rather than on it, so a pilot backs away from their own thumb with
the guns still on whatever they are backing away from. Everything else about
the stick is unchanged, the rule that the engine waits for the nose included.

The stance is drawn twice over. The stick turns the color the ship's plumes are
drawn in, and the middle of its resting mark becomes the down arrow the
keyboard's reverse key already wears; while a thumb is on it, a headed spur out
the far side of the press says where the nose is being carried. The ship has
drawn retros off its bow all along, and the note in `arena/world.lua` saying
they exist for a touchscreen reverse was written for the one that had gone. A
watch, a lost window or a shutdown drops the stance with the rest of the
controls.

**Why:** [decision 13](#13-the-camera-holds-a-fixed-zoom) took two reverses out
of this client, and both went for the same reason: the stick was guessing. Down
on the d-pad and a rearward push on the stick were one thumb movement meaning
two different things, and on the stick the meaning changed again mid-burst,
since it read as backing out only when the guns were up or a hostile sat ahead.
What was wrong was never that a phone had a reverse. It was that nothing the
pilot did decided which reading they got.

A latch has none of that. The pilot sets the stance, the screen says which one
is up, and a push means what it has always meant. It costs the simulation
nothing: the core has had `SIM_BTN_REVERSE` from the start and still receives
the bitfield a keyboard sends.

Holding the nose opposite rather than on the thumb is the other half of this,
and the half worth arguing. The alternative reads better in source and worse in
the hand, because the same push would name a course going forward and a target
going back, which is the mid-burst change wearing a switch. It is also the only
reason to fly backward at all. A ship that can reverse only straight away from
where it is pointed has a slower way of turning around, not a way of retreating
under fire.

**Cost:** a mode a pilot can forget they set. The drawing is the whole answer to
that, which is why the arrow on the resting mark is counted in
`client/tests/touch_test.lua` rather than left to a look. An indicator that goes
quiet leaves a ship flying backward for a reason nothing on screen explains.

It is also a gesture nobody stumbles on. The controls page a phone reads names
it and that is all there is, so a pilot who never opens that page never finds
reverse. The keyboard has the same problem and answers it the same way.

And `arena/touch.lua` keeps a clock again, which was one of the three costs
listed when the last reverse went. It is one number set at the single call site
rather than a timer the module runs, and the gesture asks that time have passed
rather than merely that not too much of it has, so a caller that stops setting
it loses the flip instead of firing it on every pair of quick presses.

**Reconsider if:** nobody finds it. The gesture is named on the controls page
and nowhere else, and a stance no one sets is worth less than the corner of the
screen it colors; the answer then is a control that says what it is rather than
a longer sentence about this one.

## 89. The landing carries the choices, and their lists open in place

**What:** the landing's foot is a column now: the wordmark, three stops at the
key's own width, and PLAY NOW. The stops are the choices the screen can make,
in the order you would say them. Account shows the call sign and opens the
drawer on the pilot page. Zone shows the game the stands are dialed to and
drops the games list in place; picking one re-dials the stands to it, and PLAY
NOW stays the press that commits. Ship shows the build the next deploy flies
and drops the pilot's saved builds by name, no hulls anywhere in the list, with
SPECTATE as the last row; picking a build saves it as the hull's kit exactly as
the ship page's own row does, and picking SPECTATE is the ship page's old
eighth cell moved to where it can be seen. PLAY NOW no longer forces a
remembered spectate off, because the stop right over it says SPECTATE out loud.
Three directions were mocked in `.design/start-flow`, a column, a rail along
the foot and a sentence of pressable words; the column won on being the one a
first visit cannot miss and the one that degrades best to a phone.

**Why:** three observations from watching arrivals. The drawer went
undiscovered, so most first visits never learned there was a second game or a
different ship to be: PLAY NOW and a hamburger were the whole offer, and the
hamburger lost. Choosing anything meant a round trip through the drawer that
ended back on the landing, where a zone pressed in the games list left the
player exactly where they started, in front of a key they had to press again.
And there was no way to say what you would arrive as without finding the ship
page. The stops put every choice on the screen the choice is about.

**Cost:** the landing is taller, and the column covers fight the old two-piece
landing left open. An open list stands the stops above it down, and the
wordmark with them when it climbs that far, because glyphs draw over every
mesh: a panel cannot cover text, so the text has to come off. The waiting
screen keeps only the name and MENU, so the column is one more thing that
appears when the room answers.

**Reconsider if:** the stops outgrow three, at which point this is the drawer
drawn twice and the landing should send people to the real one; or spectating
via PLAY NOW turns out to read as a dead key despite the stop naming it, which
is the trap the old forced `spectate = false` existed to avoid.

## 90. A duel stays open for two seconds after the death that decides it

**Status:** superseded by [decision 96](#96-duels-are-gone)

**Decision:** the deciding death no longer files a Duel life. The arena keeps
running for two seconds afterwards, and a death of the other ship inside that
window makes the life a draw rather than a win. The window survives the
whistle: regulation running out inside one neither files the fight early nor
takes the draw away. Nothing is announced during it, and a draw filed this way
is the draw the mode already had, which moves no rung, breaks no streak, and
puts the same rival back across the arena.

A seat lost inside the window files the fight rather than voiding it, which is
the one place this departs from the rule that a seat leaving mid-life voids it.
Whoever left had already lost, and a draw needs both pilots on the field.

The double death that was already a draw is the same rule seen at zero
seconds. `Ladder::on_deaths` existed so that two deaths on one tick could not
be settled by the order the core reported them in, and it is gone with the
batch hook it overrode: a fight held open for two seconds is indifferent to
event order by construction.

**Why:** asked for, and it fixes an exchange the mode was reading wrong. A
duel is one life at first to one, so the fight ended on the first death in the
room. Kill somebody at close range with a bomb of theirs already in the air and
the trade was scored as a clean win, because the shot that killed you landed in
a room that had stopped listening a tenth of a second earlier. The pilot who
died second won the rung.

Two seconds is a bomb's flight, and it is also the zone's respawn delay, so the
loser is still down when the fight is filed and never appears on the field for
the frame before the podium. It buys something that was not the point and is
worth keeping: the kill can be watched. The arena used to cut to the result on
the tick of the explosion.

**Cost:** the podium is two seconds later than the kill that earned it, which
is two seconds of a decided fight. The scoreboard reads 1-0 through all of it,
so nothing is hidden, but a pilot who has just won is flying a fight that is
already over and can still lose it to a stray round. That is the rule rather
than a side effect of it. A duel can now also be drawn by a bomb nobody aimed, which is a
worse result than either pilot wanted and an honest description of what
happened to them.

Calibration keeps its own rule, as it already does for the whistle. The pilot
harness stops a leg on the first tick with a death in it and calls that tick's
mutual death a draw, because it is measuring which pilot wins a fight played
out rather than what the mode does with the answer.

**Reconsider if:** the window turns out to be long enough to draw fights that
were not trades, at which point the length is wrong rather than the rule.

## 91. The landing lies down where the column would cover the ship

**What:** the landing asks the window two questions instead of one. Width still
decides how wide PLAY NOW is. Height decides the shape: where the column of
decision 89 would reach the middle of the screen, the same four pieces lie down
into a rail along the foot, three stops as cells beside the key with the name
over them. A cell carries its question over its answer with the caret on the
question's line, which is what lets three of them and the key share one line;
where that line is wider than the window the cells take a line of their own
over the key. A list opens upward from the cell it hangs on rather than from
the key, at a width a build name can be read at. What a stop is and what
pressing it does are the same either way.

**Why:** the column is a fixed 260 points tall and the window is not. That is a
third of a monitor, which is what it was drawn against, but 55% of a phone held
sideways and 69% of a browser window 315 points tall. The camera stands behind
the hull the stands are watching, so the middle of the screen is that hull: at
844 by 390 the wordmark was drawn across the ship and the account stop across
its call sign, which is a front page that hides the one thing it is supposed to
be showing off. The interface already asks height and width separately for the
menu, where height decides how much room there is to spend; the landing asked
about width alone. The rail is direction B of the mocks the column won, in
`.design/start-flow`, so the look was drawn before it was needed.

**Cost:** two layouts to keep working rather than one, and the landing's
regression tests now ask each window which of them it should be getting. PLAY
NOW is no longer centered on the window when the rail is up: it ends the band,
and the band is what is centered. Opening a list takes the name off the screen
every time, because the list opens over the band the name sits directly above,
where the column only lost it when a list climbed that far. A cell is 120
points wide, so an answer longer than that is cut at the cell's edge; a 24
character call sign is shown as much of itself as fits.

**Reconsider if:** the rail turns out to read better on a monitor too, at which
point the column is the special case and the question is whether an upright
phone still wants it; or the stops outgrow three, which is the reconsider
decision 89 already carries.

## 92. Duel is two pilots, and the door decides which two

**Status:** superseded by [decision 96](#96-duels-are-gone)

**Decision:** the Ladder is gone. In its place is a duel: two seats, one life,
first to a single death, and nothing in the mode that can tell which of them has
somebody breathing behind it.

Who is across the arena comes from the door. An arriving pilot is put beside the
nearest-rated person already waiting, as long as that rating is inside a band of
300; nobody in range opens a room of their own and becomes the person the next
arrival is matched against. A room holding one pilot asks for no bot until the
seat across from them has been open ten seconds, and a person arriving later
takes that seat back through the eviction path a room full of AI already had.
When a bot is asked for, it is named by strength: the authored archetype whose
rating sits nearest the waiting pilot's.

What goes with the climb is larger than the climb. The rung, the roster order
between a rung and a pilot, the fixture that bound the opponent seat to one
measured archetype in one hull with one kit, the per-account `ladder_progress`
table, the ladder half of the signed token, and the half of the exclusive-lease
release barrier that existed to land those rows: all of it. The rating half of
that barrier stays, because the same read-after-write hazard applies to the
number that is left.

What each pilot keeps is a card: their streak, their best streak, how many
fights they have finished here, and the last five by name. That is per seat,
which makes the duel body the one message in the protocol whose bytes differ
per recipient. The old body held one card per room, which worked only while the
other seat was guaranteed to be a bot nobody was drawing a card for.

**Why:** asked for, and it is what this zone was always supposed to be.
`docs/design/duel-mode.md` described a duel as "a human near your rating or
a bot near your rating" since before there was a mode to put it in; it was
deferred, and the Ladder was what shipped instead.

The Ladder's own failure is what made the question live. The opponent was a pure
function of the rung, the rung was a pure function of results, and the interval
that banked a rung sat exactly the loss drop below the top of an eight-rung
roster. Every loss from the top three landed on the same opponent, so a player
who had banked the middle of the ladder met two names alternately for as long as
they kept playing, every evening, for ever. That was the report that started
this. Removing the save points fixed the arithmetic and left the shape: a solo
climb through a fixed list, in a zone whose whole reason to exist is that it is
the cleanest possible measurement of one pilot against another.

Most of what that shape required turns out to be scaffolding for a question the
new mode does not ask. A rung meant nothing unless the pilot standing on it was
the pilot the tournament measured, which is why the room checked identity, hull,
entitlement ceiling and current kit before it would call the seat ready. A duel
wants an opponent of about the right strength, so a near miss is a slightly
uneven fight rather than a wrong answer, and all of that goes.

Calibration is unaffected and more relevant than before. It never used the mode:
it is an in-process harness that needs a zone file with the melee economy, first
to one, and gantry in its rotation, all of which the duel zone still is. What it
certifies, a rating for each authored pilot, is now what the matchmaker reads.

**Cost:** a duel zone can seat two people who are far apart, because refusing at
the door would be the arena telling a player the zone is full when it is not.
The band only decides who is preferred, not who is admitted.

A person taking a bot's seat voids the fight in progress. That trades a fight
somebody was enjoying for a better one, and the alternative is making the
arriving player wait for a whistle they cannot see.

Ten seconds is a guess. It is long enough to lose a pairing that was one second
away and short enough to feel like a bug on an empty zone, and only play will
say which way it is wrong.

Nothing durable survives a duel now except the rating. Best rung was the last
number that said how far an evening got, and players ask for that; it left
because it was a rung, and rungs are gone.

`CLIENT_PROTOCOL` moves to 28, the catalog to 34 and the token to 4. The zone,
the mode name and the rating class all become `duel`, so a Ladder-class rating
does not follow a pilot into it.

**Reconsider if:** the population grows enough that a band of 300 is loose
rather than merely wide, at which point the number is wrong rather than the rule
and a deployment-wide queue in the meta-layer starts to earn its keep. Or if the
hold turns out to be the thing players notice about the mode, in which case it
belongs on a clock the zone file sets rather than a constant.

## 93. The sky has nothing in it with a shape

**Status:** accepted, amending
[decision 79](#79-the-sky-is-the-maps-and-it-has-weather-in-it)

**Decision:** the suns and the comets are out of the sky, and so is the lens
flare the brightest sun threw. What is left is what does not have an outline:
the two washes under the black, the diagonal band with its grain and
filaments, the knotted clouds, the three depths of star in four temperatures,
and the near dust that streaks along the camera's motion. A map's name still
places the band and the washes, so a room still has a sky of its own.

Everything the set pieces needed goes with them: the counts and kinds a name
was dealt from, the per-piece size, color, depth and distance, the hexagonal
ghost chain and the gate that faded it as the light left the frame, and the
budget lines that priced all of it. `world.IRIS_SEGS` is not published any
more, and the two segment counts left are the ones the sky actually draws at.

**Why:** asked for, after playing it. The reason given is that they are not
working, and that is the whole of what was said, so what follows is the file's
reading rather than the request's.

The set pieces are the part of decision 79 that was already closest to the line
identity.md draws, and they had been argued with once before this. They shipped
one to a map at one size in one color, and flying that turned up rooms that all
looked like each other; the answer was to deal each one from the map's name,
which made every room's version different rather than making the objection go
away. Two goes at the same complaint is usually the shape of a thing that is
wrong rather than mistuned.

The rest of the sky is kept because the objection does not reach it. A wash, a
cloud and a band have no edge to find and no size to judge, so they stay
distance no matter how long they are looked at, which is what the field is for.
A sun is a shape at a size, and this game spends shape and brightness on ships
and shots.

**Cost:** the reason the set pieces were placed at a quarter and two fifths of
the camera's rate was to give a room a fixed point, something a side could be
told to regroup under. Nothing in the sky answers that now, so where you are is
a question for the dial and the map, both of which are pictures you have to
look away from the fight to read. If that turns out to be a real loss it is a
landmark question rather than a sky question, and the answer is a named thing
in the terrain rather than a light painted on the distance.

**Measured:** 726 vertices off the glow layer's reservation at every window
size, which on a 1920 by 1080 window drops the stepped layer from 11264 to
10240. Frame time does not move outside the noise, and should not have: a
handful of set pieces was never what the sky cost, the thousands of hashed
cells behind them are.

**Reconsider if:** a mode arrives that wants a fixed point to call, and the
thing to call turns out to belong in the sky rather than on the map.

## 94. The ending has no foot, and the clock never moves

**Status:** accepted, amending
[decision 67](#67-the-scoreboard-is-a-band-you-press) and
[decision 68](#68-the-match-ending-is-the-board)

**Decision:** what the whistle puts up is a line naming the side that took the
match, the bar under it, the roster, and the zone's own sections where it has
them. Nothing below that. The foot decision 68 gave the block is gone, and so
is everything that used to stand in it.

The countdown moved into the band, which is where the clock has been for the
three minutes before the whistle. Between matches the band gives up its two
sides, because the block a few lines under it names both of them inside a bar
with their points on the ends, and keeps the numerals with NEXT MATCH IN under
them. It stops taking a press there too: the box opens the board, and the board
is already on screen covering the window. So the band is back through the
ending, against decision 68, and what it carries is the one reading the ending
does not already make.

It reads at full strength while it does. The ending washes the whole window
and draws its block over the top, and the countdown belongs to what is being
said rather than to what is behind it: at a third of an alpha the one number on
screen that was still moving was the faintest thing on it.

The two keys that shared the foot with the countdown are gone rather than
moved. INVITE FRIEND handed the match's own page on the site to whatever the
device shares with; the key beside it offered a guest their call sign to keep.
With them go the address the arena built for the filed match, the question of
whether this pilot is a guest with something to lose, the tray-and-arrow share
mark, the breath the invite key drew on the clock, and the press that opened
the password ask. What the block takes a press for now is the board's own rows
and the heads over its columns.

The block is centered in what the band leaves rather than in the window, and
never starts above it. An upright phone still hugs the foot of the screen with
the whole block, for the roster rather than for a key: a list is dragged with a
thumb and a thumb reaches the bottom of a tall screen.

**Why:** asked for, in two goes, and both asks are a line long, so what follows
is the file's reading rather than the request's.

The keys first. Somebody reading the ending is answering one question, which is
how they did, and each key put a different question in front of it. The invite
wanted them to go and fetch a person. The claim key wanted a password. Both
were asked at the one moment in a room when nobody is flying and everybody is
reading the same panel, which is what made that moment look like the place to
ask, and it is also why they were the loudest thing on a screen whose job is to
report a result. The invite had already been quieted once for exactly that,
dropped from PLAY NOW's full wash to a breath under it, which is the shape of a
control in the wrong place rather than at the wrong volume.

Neither ask goes away with the keys. The menu draws the guest band, which is
where an account is claimed, and the friends page pins the invite at the foot
of a page somebody opened on purpose. What both have that the ending does not
is a reader who is not being counted down.

Then the clock, which is the part that decided the shape. A foot holding one
reading is a row of chrome under a list, and the reading it held was already
drawn somewhere else half a second earlier: the band counts the match down in
the top row and the whistle moved that same number sixty points down the
screen into different type. Reading the ending meant finding the clock again.
Putting it back in the band costs the ending its foot and buys an instrument
that does not move: three minutes of match clock and then the wait for the next
one, same pixels, same size, whether the board is up, a menu is over it, or a
fight is on.

Decision 68 stood the band down for the ending on the grounds that the head
carried the score and the foot carried the clock. Half of that still holds and
is why the band drops its sides here. The other half was the foot, and once the
foot has nothing but the clock in it, the argument runs the other way.

**Cost:** the invite loses its audience. Eight people looking at one panel with
fifteen seconds on the clock is as close as this client gets to a room paying
attention at once, and the friends page is opened by one person who was already
thinking about it. If the game turns out to need word of mouth from inside
itself more than the ending needs to be quiet, this is what it cost.

The clock also leaves the block it belongs to. On a 1280 by 800 window the
countdown sits at 27 points down and the line naming the winner at 260, so
there are two hundred points of nothing between the number and the result it
is counting away from, and they can read as two panels rather than one. That
is the price of an instrument that does not move, and what it buys back is
that a player never has to look for the clock: the alternative is a number in
the top row for three minutes and somewhere else for fifteen seconds.

**Reconsider if:** guests are found to be losing pilots they would have kept,
which is the menu's band failing to say so rather than something the ending has
to say for it. Or if the invite is ever worth closing the loop on, per
[decision 78](#78-the-friends-page-is-who-is-on-and-one-way-to-reach-who-is-not),
at which point the question is where a link that knows who sent it belongs, and
the answer may not be the ending either.

---

## 95. Friends are gone

**Status:** accepted

**Decision:** the friends feature is removed from the game, end to end. In the
client that is the `friends` tab and the page under it, the add field and the
call sign completion behind it, the received-and-friends sections, the accept,
ignore, join and unfriend acts, the green presence dot, the two-badge rail
mark, and the band at the foot that shared a link with somebody who has never
played. In the meta-layer it is the `friends` and `friend_ignores` tables, the
`/v1/friends`, `/v1/friend`, `/v1/friend/find` and `/v1/friend/ignore` routes,
and the hundred-edge bound they were written against. `active_rated_sessions`
loses its `zone` column and the arena stops sending one: that column existed
so a list could say which game somebody was in, and the seat lock it rides on
never needed it. `docs/design/friends.md` and the three mock canvases under
`.design/` go with them.

The guest warning now arms on a rung bought or a rated game flown, which is
what is left of the three things it watched. The home tab row is play, ship,
pilot, settings; a match carries play and settings.

**Why:** Chris asked for it, and that is the whole of the decision.

What survives the ask is worth writing down, because
[decision 78](#78-the-friends-page-is-who-is-on-and-one-way-to-reach-who-is-not)
is a good record of a page that was rebuilt three times and never earned its
tab. It reached its final shape by deleting: five sections became two, an
ignore that was reversible became final, a count and a ledger went, and what
was left was a page one person opens alone to find out that nobody is on. The
claim under all of it, "people stay for people", was never tested by anything
that shipped, because nothing in the game gave two people a reason to be on it
at the same time. A roster is not a reason.

It also takes real weight out of the tree. Friends was the only page that
re-asked the meta-layer on a timer, the only one whose rows carried per-row
buttons and a card built from the same list, the only one with a text field
that sent, and the only writer of the browser's link anchor. Every one of
those mechanisms existed for one page and most of them come out with it. The link
bridge does not: it predates this feature, it has tests of its own, and
[decision 73](#73-the-community-door-is-the-sites-not-the-games) already chose
to leave it standing once when its caller went. It stands again, with none.

**Cost:** the game has no way for two people who know each other to find each
other in it, and no way at all to reach somebody who is not already here. That
is not a small thing for a game whose whole population problem is that a new
player arrives alone. What is left is the mode list saying where the humans
are and the sort putting you where they already are, per
[match-game.md](../design/match-game.md), and the site's Discord door for
everything else.

Accounts keep nothing: the tables are dropped, so every edge anybody made is
gone and no migration puts them back. That is the same call
[decision 92](#92-duel-is-two-pilots-and-the-door-decides-which-two) made about
banked rungs, and it is the right one for a feature nobody is being asked to
keep using.

**Reconsider if:** the answer to "why did you stop playing" turns out to be
"there was nobody I knew there". The thing to build then is a reason for two
people to be in the same room at the same time, and a list is what that reason
would need afterwards rather than what it starts as. This record's own history
is the list of shapes already tried.

**Cascades:** decision 78 is superseded whole. Decision 80's rule about what a
menu foot pins stands, minus the invite band, which was one of its two
examples; decision 81's line about where a page begins stands, minus the add
box. Decision 94's ending is untouched: it had already dropped its invite.
`menu.md`, `match-game.md`, `accounts.md`, `interface.md`, `spectating.md`,
`meta-layer.md`, `catalog.md`, `roadmap.md` and `zones-and-arenas.md` are
updated, and `friends.md` is deleted. Decision 28 is untouched: this removes a
roster, not a reason.

---

## 96. Duels are gone

**Status:** accepted, superseding
[decision 16](#16-duels-are-an-ephemeral-arena-plus-a-zone-module),
[decision 58](#58-the-ladder-zone-always-has-a-duel-in-it),
[decision 74](#74-the-duel-counts-a-streak-and-names-who-it-beat),
[decision 77](#77-a-duel-that-runs-the-clock-out-is-a-draw),
[decision 90](#90-a-duel-stays-open-for-two-seconds-after-the-death-that-decides-it)
and [decision 92](#92-duel-is-two-pilots-and-the-door-decides-which-two)

**Decision:** the duel zone is removed, and so is everything that existed to
serve it. Chris asked for the feature to go.

The zone file and its entry in the catalog, first, which is what stops a
deployment serving one. Then the mode: `Duel`, the card a pilot kept there, the
window a decided fight was held open for, the ten second hold on the second
seat, and the draw a whistle produced. The `ModeCtx` fields nothing else read
go with it, which is the seat name list, the seats slice, and the abort flag,
along with `Mode::on_departure`, `Mode::first_human` and `Mode::duel_state`.
Melee and warzone never set any of them.

The matchmaking is the larger half. Pairing an arrival against the nearest
rating inside a band of 300, the room a lone pilot opened to become the next
arrival's rival, the stand-in pair that kept an empty room playing for the play
page, the bot named by strength, and the persistent replicas that named one:
all of it. A bot request is a room and a count again. `RoomView.waiting` leaves
the directory, so a games row no longer has a rival wait to draw.

Two protocol changes fall out. `S2C_MATCH` loses its per pilot card, which
makes the clock the same bytes for everybody in a room and takes the one
message whose contents differed per recipient out of the protocol; and
`C2S_JOIN` loses the build claim field, whose only reader was the check that a
certified duel zone ran house opponents from the verified release. The wire is
protocol 30.

The offline pilot tournament stays and moves house. It flew gantry under the
duel zone's tuning, and that tuning was held line for line against melee's by a
test, so its fixture is melee's own `zone.toml` now and the ruleset it measures
under is unchanged. Single life is the harness's rule rather than the zone's,
which is where it belonged: the rig plays each leg to a death and past the
whistle on purpose.

**Cost:** the game is one thing to play again. What a duel offered that melee
does not is a fight where the result is about you and one other person, which
is the shape a player who wants to know how good they are goes looking for.
Melee's rating still measures a pilot, and it measures them in a room of eight
where a death has four people's damage in it.

Duel ratings already earned are dropped from the `ratings` table by the meta
migration. Nothing reads the class now, and leaving the rows would have the
pilot page name a game that does not exist: the career line reports whichever
class a pilot has flown most.

**Reconsider if:** a rated one against one is wanted again. It would not come
back as this: the pieces worth keeping are the pairing rule at the door and the
card, and both were built around a zone whose rooms hold two seats, which is
the constraint that made every other piece necessary.

---

## 97. Ships are preconstructed, and nothing is bought

**Status:** accepted, superseding
[decision 50](#50-a-hull-is-a-shape-and-everything-else-is-on-the-shelf)
and [decision 64](#64-the-ship-page-is-the-shelf)

**Decision:** every hull is a whole ship. Its flight row, its gun, its bomb and
what those weapons carry all belong to the hull and are set by the zone, and a
pilot picks one off a roster of seven. The kit, the thirty point budget, the
shelf, the wallet, the bounty and the points are all removed. Chris asked for
preconstructed profiles back, balanced, and asked for rivets, points and bounty
to go with them.

Decision 50 deleted the per-hull rows on the argument that a trait one hull
holds is a trait a shop can never sell. That was correct, and it named its own
reconsider clause: uniform flight was what made a thirty point kit a fair
trade, so if the budget ever went, the argument for uniform flight went with
it. This is that trade being made deliberately.

What the budget was really costing is easier to see now. Thirty points against
one shared flight row means every pilot in the room starts from the same ship
and spends the same thirty, so the only thing a hull could be was a rectangle.
Seven silhouettes with identical engines is a thinner roster than seven ships,
and "you cannot shape your ship to your liking" is better answered by seven
real ships than by one ship with thirty sliders on it.

So `sim_ship_class` gains a `kit` vector, which is the same twenty-three slot
space the kit used to spend points on, moved from the ship record to the class.
`sim_spawn` deals it. `sim_settings` loses `kit_ceiling`, because `sim_grant`
clamps to the core's own maxima and a zone that wants a shallower hull writes a
shallower hull. The flight row is per class again, with the floor equal to the
cap and the step at zero, so a profile can name a stat slot and it buys
nothing.

Bounty and points go together because they were one number by the time this
started: a bounty was the length of a run, points were what a kill paid, and
rivets were points banked. With nothing to buy, the wallet has nothing to be
for, and with the wallet gone the two numbers a kill moved are a kill and an
assist. `SIM_EV_DEATH` carries nothing, `S2C_KILL` is thirteen bytes, and the
pilot log files a run rather than a bounty.

Two live bugs surfaced on the way and are fixed here. The AI weighted a target
by `bounty / 60.0` against a bounty that had not been a sum over held counts
for months, so the term was dead; it reads the streak now. And the map gate
that holds every melee map to a home-to-home flight time was timing class
zero's *floor* speed, which is a speed nobody flew because every pilot spent
points on it: the gate is the roster's median now and every window is rescaled
by the same factor.

The client's ship page loses four pages and a carousel. What is left is the
roster, one row a ship, carrying its name, the shape it presents, its flight as
five bars against the rest of the roster and what it flies with. Pressing a row
flies it. The podium grows a rating column, which is what a match is worth now
that nothing is paid; it is drawn at the whistle and never during the fight,
because a rating is a standing and a number climbing over somebody's head while
they are being shot at is the shape the bounty had.

**Cost:** balance is harder, and it is the point. Seven ships that are actually
different have to be held level against each other with nothing a pilot could
have spent to answer a bad matchup, so `calibrate hulls` is the primary harness
now and the kit's profile experiment, with its ten preregistered marginal-pip
contrasts, is gone with the question it answered.

The first roster written against it came out between 28% and 90%, and four
measured passes brought it to 45 to 55. The largest single correction was not a
hull: melee charged a whole base cooldown for every round of spray past the
first, which was the right price for a rung anybody could buy and a tax on the
three ships that have barrels once nobody could. Every spray hull was in the
bottom three on both rooms, in order. That is the shape of mistake this change
invites, and it is worth naming: a number tuned against a shop is a number to
re-derive, not to keep.

A pilot on two kills looks exactly like a pilot on none, since the bounty over
a hull was the only thing that said otherwise below the streak threshold. Chris
accepted that: the streak at three is the one thing this game says about how
somebody is doing right now, and a second quieter marker would be the bounty in
a smaller font.

And a new account has nothing to look forward to but a rating. The drip is
gone, the shop that was its point is gone, and the bet is that a game worth
playing does not need one.

**Reconsider if:** the roster cannot be balanced, in which case the answer is
fewer ships rather than a budget coming back. Or if the game needs something to
earn, in which case it is something that is not strength: livery, a name, a
mark. Strength behind a price is what came out.

## 98. The drawer stops carrying the games

**Status:** accepted, superseding the games half of
[decision 66](#66-a-game-row-is-one-press-and-leaving-is-a-button-on-it)

**Decision:** the play tab and the page under it are removed from the menu. The
landing's zone stop is the one list of games, and the drawer is what is left:
the ship, who you are, the side you are on, the way out, and settings.

**Why:** Chris asked for it, and the reason is on the screen. Decision 89 put
three stops on the landing because the drawer went undiscovered, and one of
them is the games. From then on a player standing at home with the drawer open
was looking at the same games twice, once in a page and once in the column
behind it, each with its own cursor and its own idea of which game the stands
should be showing. Two lists of one thing is two things to keep in step, and
the attract loop was already reading both: whichever the drawer's cursor was
on, or whichever the landing's stop last named.

Two things on that page were not games, and both moved onto the tab row.

The side you are on was its last row. It is a stop now, first in a room, and it
appears only where the room has named sides, which is the same answer the page
gave by leaving the row off.

Leaving was a button on the row of the game you were flying, which decision 66
put there on the argument that a stop beside the sound settings filed the way
out of a game a page away from the game it was about. That argument needed a
list to hang the button on, and there is no list. So leave is a stop again, in
the slot before settings that decision 83 gave to whatever varies with where
you are standing, and it goes one step: flying, it hands the seat back and
leaves you watching the room, which costs nothing that TAKE SEAT cannot undo,
so it does not ask; benched, it leaves the room for the stands, which costs the
match and asks first. Both acts already existed and both were already reachable.
What changed is that they answer to one label in one place.

A pilot mid-match therefore has leave and settings, which is what a locked hull
leaves anybody. Getting from a match into a different game costs two presses
more than it did: hand the seat back, leave the room, then pick from the
landing. That is the price of having the games in one place, and it is paid by
the pilot least likely to be shopping for another game.

**Cost:** the drawer no longer refreshes the directory by being open on the
games, so the landing's open zone list is what keeps it fresh instead. A row
vocabulary went with the page: the format strip of TEAMS, TIME and SCORING
stacks, the sweep dial a zone nobody was serving wore, and the buttons a row
could carry at its right hand end, along with the pointer hover and the press
route behind those. The landing's own zone row says the format as one line, so
what is lost is the stacked layout rather than the facts.

**Reconsider if:** a second way into a game turns out to be wanted from inside
one, which is the case this makes worse. The answer then is a stop that opens
the landing rather than a page that lists games a second time.

## 99. The account is a dropdown, and the pilot page is gone

**Status:** accepted, superseding
[decision 70](#70-sign-up-and-the-pilot-page-is-the-career) and the
call sign half of
[decision 69](#69-the-account-page-is-a-stop-on-the-rail)

**Decision:** the landing's account stop opens a list in place, the way zone
and ship already do, and that list is the whole of the account interface: for
a guest SIGN UP, NEW NAME, a rule, LOG IN; signed in, SET PASSWORD, NEW NAME,
the rule, LOG OFF. The pilot page, its tab on the home row, and the call sign
in the drawer's head as a door onto it are all removed.

**Why:** Chris asked for it, and decision 89 had already made the account stop
the odd one out. Three stops went onto the landing because the drawer went
undiscovered; two of them answer their own question in place and the third was
a door that opened a panel over the screen you were standing on, to show a
page whose acts are four short lines. Two presses and a panel to reach four
lines, on the one screen an account is worth editing on.

What the page had that a list cannot hold is the career, and the career had
already stopped being the client's to show: it is bare totals on `/v1/career`
and the site draws the same figures at `/pilots`. What is left after it is the
acts, and the acts are a list.

Signing up and claiming this account are one row, not two. The mocks in
`.design/pilot-dropdown` drew them as two, an offer above a rule and a fresh
start below it, and the account model says otherwise: there is one endpoint,
`/v1/claim`, and what it does is put a password on the account this client was
handed on its first run. There is no second act that makes a fresh account and
signs it up, because a fresh account is what a guest already has. So it is one
row, in the player's word for it rather than the endpoint's, which is the
vocabulary decision 70 settled on and this keeps.

The rule between the rows is what the page's foot was saying by position: above
it, what you can do to the account you are; below it, how to be a different
one.

Two things the page carried had to land somewhere else. The reroll asks first,
which is the guard decision 70 put there after a curious player pressed their
own call sign and lost it, and that guard lived in the row-press path rather
than in the act: a list that ran the act directly would have rolled on the
press with nothing said. It is one function now and both ways in pass through
it. The guest banner pointed at the page; it raises the sign-up card itself
now, from wherever it is standing, and the dot that rode the pilot tab rides
the landing's account stop, which is what the band now points at.

The call sign in the drawer's head stays exactly where it is and stops being a
button. It was the second door onto the page, kept because a name saying who
you are signed in as is worth pressing; with no page behind it, what is left is
the sentence it was always also saying.

**Cost:** the career is no longer anywhere in the client. A player who wants
their rating, record or games reads them on the site, and the client says
nothing about how they have flown. The account acts are also home only, since
the landing is only up in the stands: mid-match there is no way to set a
password, where the pilot tab was equally home only but the call sign in the
head was not. Nothing that raises a card from out here can be reached with the
drawer open, so the card learned to stand on the landing with no panel behind
it, which is a second place the same card is drawn from.

A type rung went with the page. PAGE, the size a page called itself, had the
pilot page's call sign as its last live user and a card's device code as its
last reference, and that code had no caller: the ladder is four rungs now.

**Reconsider if:** the client wants to show a career again, at which point the
question is whether it belongs on a page of its own or on the site it is
already on. The list itself does not care: it is the acts, and a career is not
one.

## 100. Seven credits, and every step costs one

**Status:** accepted, partly superseding
[decision 97](#97-ships-are-preconstructed-and-nothing-is-bought) and
superseding the ship page half of
[decision 89](#89-the-landing-grows-stops)

**Decision:** a pilot spends seven build credits over the core's flat slot
space, and every step costs one credit. Each hull's profile is its default
spend, so a player who never opens anything flies the ship as it ships. There
is nothing to own, nothing to buy, nothing to name and nothing to price. The
drawer's ship page and its tab are removed, and the landing's ship stop opens
a panel that pages one hull at a time and carries the rows that spend its
credits.

**Why:** Chris asked for the configurable kit back, and named what it died of
rather than what it was: his son could not work out what anything on it was or
how it worked. The interface was the problem and the spending was not.

Most of that interface was the economy rather than the kit. A shop tab, rivet
prices, per-account ceilings that trimmed a build to what you owned, a wallet,
BUY keys, named builds saved under a library. All of that goes and does not
come back: everything is reachable by everybody from the first session, which
is what Chris asked for and also what removes the family of bugs the economy
generated, from stale session tokens after a purchase to builds silently cut
down to owned slots.

What was left after the economy was still too much to read. Twenty-three slots
drawn as ladders of pips under three-letter marks, thirty points, and a build
manager with NEW, SAVE, RENAME and DELETE on it. Two things fix that, and both
came out of the mocks in `.design/ship-kit` rather than out of an argument.

The first is the price list. Thirty points against slots priced from two to
nine puts arithmetic on the screen: every row needs a number, the budget needs
a bar, and a player has to compare a nine against a three to know what a repel
is worth. Seven credits at one credit a step needs none of it. There is no
number on the page, because there is nothing to add up: the tray holds seven
chips and a step takes one. That is the version a nine year old can read, and
it is the version that fits on a phone.

What flat pricing costs is the balance lever. A slot that is too strong used
to be made expensive; it now has to be made weaker or given a lower ceiling,
and `sim_slot_cap` is the one place a ceiling is written down, asked by the
pilot spending, by the deal, and by the client drawing a stepper. The
ceilings are the zone's, they travel with the settings, and the shipped ones
are in `sim/src/baseline.c` and tabled in [ships.md](../design/ships.md).

Two of them were set by the sweep rather than by argument, which is the whole
case for having built it. Seven of one charge beat every hull's own row on
every hull, because a rack answered to the budget and nothing else; and an
add-on that belongs on a bomb wins outright on a gun, since a round with a
proximity fuse does not have to hit and rounds that bounce fill a room the way
the Lattice's did before its gun stopped bouncing. Under thirty points and
variable prices both would have been answered by charging more, and neither
would have been found in the first place. What flat
pricing buys back is that the build space becomes small enough to sweep:
`calibrate builds` flies every runaway shape against the hull it was spent on,
which is a question the hull tournament cannot ask and nobody could have
afforded to ask against thirty points and variable prices.

The second is that the roster and the editor are one surface. The ship stop
opened a list of seven names; the drawer's ship page held the same seven with
their flight bars. Two places saying the same thing, and neither could hold a
build. The stop opens a panel now: one hull, its flight against the rest of
the roster, its credits, and its rows. Left and right walk the roster, which
is the friendliest gesture there is for a pad or a thumb, and it retires the
list on its own terms, since seven hulls with bars and a build apiece is a
page wearing a list's clothes.

Which rows that panel draws is the core's answer rather than a list written in
Lua. A slot whose ceiling is zero is one the hull cannot reach, so a hull with
no bomb rack grows no bomb section; a stat whose step is zero would take a
credit and change nothing, so it is not offered. That is what keeps the page
honest for a zone nobody has written yet, and it is why `sim_slot_cap` and
`class_up_step` are exported to the client at all.

Seven is not a round number picked for looking like one. Every hull's profile
in `sim/src/baseline.c` already summed to seven or less, from the Anvil's three
credits to the Facet's and the Lattice's seven, so the roster arrived on this
budget rather than being moved onto it, and a test in `sim/tests/test_sim.c`
holds it there. The lighter hulls ship with credits in hand, which is a nicer
first edit than a trade: a new pilot's first act is spending something rather
than giving something up.

A build lives on the ship in the core rather than on the seat in the server,
because every re-deal happens inside the step. A respawn and a whistle both
hand back what a pilot spent, and neither has a caller to ask. That is also
the bug the last kit shipped with: a build that lived beside the arena was a
build a whistle could forget, and a player flew a bare hull for a whole match
before anybody noticed. It rides the owner's snapshot tail as the slots it
actually spent, one byte each, since seven credits cannot reach eight slots.

One build a hull, remembered on the device beside the wake and the key
bindings. Nothing is owned, so there is nothing an account could be
protecting, and seven ones over a dozen slots is not worth a table, a route, a
migration and a login to carry between machines. A pilot on a new machine
flies the shipped profiles, which is the same thing they would see having
never opened the panel.

**Cost:** flight stays the hull's. The credits buy weapons, add-ons and the
rack, and not speed or energy, so decision 97's per-hull flight rows stand
exactly as they are. The other side of that fork is drawn in `.design/ship-kit`
and was not taken: two hulls tuned to the same numbers fly as the same ship,
and a roster of seven silhouettes over one flight row is what decision 97 was
undoing. The slots stay in the space and the panel offers them the moment a
zone writes a hull whose flight climbs.

The other cost is granularity. Thirty points let a pilot shave a fine trade;
seven picks are coarse, and a build is now a handful of yes-or-no answers. For
three minute matches that is the right trade, and it is the direction the whole
front end has been going since decision 61.

## 101. A weapon's level is a slot a pilot spends on

**Status:** accepted, extending
[decision 100](#100-seven-credits-and-every-step-costs-one)

**Decision:** every hull's gun and every hull's rack is a ladder of three
rungs. Rung zero is the weapon the ship arrives with, and the two above it
cost one credit each out of the same seven that pay for spray, an add-on or a
repel. A gun rung is half the row's round again on the damage and on the
energy a pull costs; a bomb rung adds forty pixels of blast and half the row's
energy, since a bomb does the same damage at every level in the original and
the reach is what a level buys. Neither moves the rate.

**Why:** because the hangar already said you could and you could not. The ship
page has drawn each weapon section opening on a "Rung" row since decision 100,
with a note under it saying which gun off this hull's own ladder it fires, and
the row has never once appeared on a screen.

Nothing between the two ends was broken. `sim_slot_cap` floors a level slot at
the length of the hull's own ladder, which is right: a rung the hull does not
carry is a rung nothing climbs to, and it is what gives the Cipher no bomb row
without the Cipher being named anywhere. The panel draws no row for a slot
whose ceiling is zero, which is also right, and is what keeps it honest for a
zone nobody has written yet. The roster underneath named one rung a weapon.
Two correct rules over a roster of ones is a row that silently does not exist,
on a page where every line about it was written and tested.

So the ladders are real now, and three is the number because three is what a
gun and a bomb each have in the original. `SIM_MAX_RUNGS` is four and stays
four: the fourth is for a zone that wants a hull climbing past this roster,
which is what the machinery was kept for and is still the only thing keeping
it honest.

What a rung sells is the size of one arriving hit rather than a discount. The
energy climbs with the damage, so rounds per bar is where it was and a level
does not pay for itself; the delay does not move, because BulletFireDelay is
one number in the original whatever the level and a rung that fired faster as
well as harder would be the gun bought twice. On the rack the blast is added
to rather than multiplied, because this roster's own bombs already sit up the
original's ladder: the Wedge's bay is its L2 and the Anvil's is past it, and
tripling either would put a hull's own blast most of the way across a room
with the thrower inside it. Forty pixels a rung puts a plain rack on 80, 120
and 160 and the Anvil's on 240, which is the original's own L3.

**Cost:** two more slots a pilot can dump seven credits into, on a price list
that cannot make a step dearer. `calibrate builds` is the answer to that and
the ceiling is where the answer lands, which is the arrangement decision 100
set up. The ceiling on a level is not a number anybody writes: it is the
length of the hull's ladder, so shortening a ladder is how a rung gets cheaper
to hold and there is nothing to keep in step with it.

The sweep was run at forty bouts a build, on the pit and again on Gantry off
`mapforge`, and neither rung needed a ceiling. In both rooms a gun rung is
third of the four gun slots and a bomb rung sits inside the bomb group, and
the 26 shapes the two added left the share of the space that runs away where
it was. On the real map nothing at all cleared the line by more than luck
would put there.

That is a screen passing rather than a measurement. Forty bouts a build is
the exploratory tier under `experiment.rs`, far from its alpha and power, and
the ordering the sweep prints is not evidence: the pit and Gantry disagree
about nearly every slot, because the pit pays for closing and a real map does
not. [ships.md](../design/ships.md) carries the numbers, the floor they have
to be read against, and what the arithmetic will and will not support.

The other cost is the tables. Three rungs on seven hulls is 42 of the core's
64 weapon specs and 44 of its 64 patterns, where one rung each was 16 and 18.
A zone adding weapons of its own has half the room it had.

## 102. The drawer is gone, and settings live in the match

**Status:** accepted, superseding the drawer half of
[decision 83](#83-settings-is-the-last-stop-on-every-row) and finishing what
[decision 98](#98-the-drawer-stops-carrying-the-games),
[decision 99](#99-the-account-is-a-dropdown-and-the-pilot-page-is-gone) and
[decision 100](#100-seven-credits-and-every-step-costs-one) started

**Decision:** the slide-out menu is deleted. What is left of it is a column at
the foot of the screen, raised by a faint key standing in the same place,
holding the three things a seat can want: the way out of it, which side it is
on, and the machine. That column is the only place settings can be reached at
all. The landing goes on saying who, where and what, and holds nothing about
the machine.

**Why:** Chris asked for a menu that lets a pilot leave, change sides and edit
settings, and said settings should live in the game and nowhere else.

The drawer had been emptying for three decisions before that. The games went
to the landing's zone stop, the account to its account stop, the ship and its
credits to the ship stop. What it still held at home was settings on its own,
plus side and leave in a room, which is a rail of tabs, a stage, a topbar and a
head row carrying four rows between them. Everything it did that anybody used
was already being done better by the column of stops the landing had grown.

So the column is that column. The stops sit at the same width, in the same
place, over the same breathing key, and the settings stop opens a panel
climbing off its own row exactly as the ship stop does at home. One interface,
learned once, pressed in both places. What died with the drawer is its own
navigation: a rail on screen at every level, a stage previewing the page the
rail cursor rested on, a head row with an x on it, and a cursor that could be
in any of the three. A lit stop with its panel over it says where you are, and
says it the way the landing has always said it.

The key moved with it. MENU stood in the top left corner for as long as there
was a drawer to pull out of the left edge, and once the panel it opened stood
at the foot, a key in the far corner was a control detached from what it does.
It is at the bottom middle now, where the column stands: the press and what it
raises share a spot, the column slides up out of that edge, and RESUME comes to
rest on the key's own pixels. It is drawn faint because it lives inside the
fight rather than beside it, and a first visit should be reading the word
rather than working around the weight. The word rides along on a phone as well,
which the corner never had the room for.

It is drawn in a room you are in and nowhere else. The landing watches a live
room, and that was taken as reason enough to carry the key out there: it stood
in a strip of its own under PLAY NOW, with the column above lifted to leave it
one. The stands are a room you are looking at rather than a room you are in.
Everything the menu holds is about the seat you took, and out on the front page
none of it has an answer: no seat to leave, no side to be on, and nobody flying
anything yet. What the key added there was a faint fourth control under the one
key that page exists for. Escape answers the same rule, so a keyboard is not a
way around the absence.

It wears no box, which makes it the one pressable thing in this interface that
is not a stroked rectangle. That is because it is the only one standing alone:
over a match a box reads as an instrument, since the band, the dial and the
corner chips are the boxes up there. The mark and the word carry it instead,
which is what the footer line in `.design/no-drawer` was already doing: three
bars say "press me" on every screen anybody has used.

Side is a list rather than a value stepped left and right. Arrows walk, which
is fine while a room holds two sides and wrong the moment it holds three:
reaching the third means crossing the second, and a pilot who wanted the third
has joined the second on the way. A row per side says them all at once, marks
the one you fly for, carries the counts you weigh before switching, and puts
any other one press away. The wire never needed changing for it, because
`C2S_TEAM` has always carried the side you want by its own byte.

Nothing pauses, which the drawer never did either, and which the drawing now
says out loud. The wash behind the column is a tint rather than a curtain, and
the clock band and the radar keep their line: a pilot reading their own
settings is still being shot at, and the two instruments that say so go on
saying it. The drawer covered a phone's whole window and stood both of them
down.

**Cost:** a pilot who wants the music down has to be in a room to do it, and
the front page is not one. PLAY NOW is the whole of what that costs, sitting
out included: the ship stop's last page puts you in the room as a watcher
rather than in a hull, and a watcher gets the key like anybody else. What it
buys is a front page that is four presses wide and answers exactly one
question.

The top left corner is also empty in an ordinary match. PLAYERS folded into the
clock band a while ago and MENU has now left, so what remains up there are
chips that come and go: TAKE SEAT, ROOM n, and the on-air tally. A corner with
nothing in it is the fight, which is what that corner is for.

**Reconsider if:** the faint key goes unfound. A control drawn at a fifth of
the weight of everything around it is a control a first session can miss, and
the answer would be a notch of alpha rather than a new location, since the word
beside the mark is already doing the work brightness would. Drawn in
`.design/game-menu`, where a corner-docked panel, the console center card and a
hold-and-flick radial stand beside the column and were not taken.

## 103. A stop opens a panel, not a list

**Status:** accepted, changing what
[decision 99](#99-the-account-is-a-dropdown-and-the-pilot-page-is-gone) and
[decision 102](#102-the-drawer-is-gone-and-settings-live-in-the-match) opened
without changing what either of them holds

**Decision:** pressing a stop no longer unrolls a list above it. It slides the
column down through the bottom edge and brings a panel up through the same one.
The panel is the window less its margin, capped at 560 points; it wears the
frost the stops wear; its head names the stop and carries the way back. Back
plays the movement in reverse and the column comes home.

**Why:** Chris asked for it, in those terms, off three screenshots.

The lists opened upward because they had to keep off PLAY NOW. That put every
one of them in the strip between the stops and the top of the window, and made
the ship panel's height a standing argument with the window: it asked for more
than the strip had and scrolled inside whatever it was given. The in-match
settings page had the same argument and lost it outright on a phone, where
eight rows and two bands over a three-stop column overran the stops they were
standing on. One of the three screenshots is that overlap.

A panel does not have the argument, because the buttons go with it. Nothing has
to be kept clear of anything, so the height is the window's and the only
measure left to choose is the width.

That width is capped, which is the one thing Chris added to the mock. Full
width is right on a phone and wrong on a monitor: a row eleven hundred points
wide sets a game's name at one end and its format at the other, two things too
far apart to read as one row, and glass that wide stops being a panel over a
fight and becomes the screen. At 560 it is comfortably wider than the 320-point
column, so opening one reads as a step up rather than sideways, and it leaves
the room showing either side, which is what the frost was for. A phone never
reaches the cap and gets the window less its margin, which is what "the whole
screen" means where there is no width to spare.

The head is the in-match settings page's, which had it first: a triangle
pointing back and the name of the section. It is worth more now than it was,
because the stop that opened the panel is no longer on the screen to press
again. That is also what the walk says: the way back, then the rows.

What this buys beyond the room is that a row which opens something stops being
a special case. It slides the next panel in over this one and back steps one
level out, rather than everything shutting at once. Nothing stacks yet -- the
account acts still raise a card over the landing, which is the one surface out
here with no ground behind it -- but the grammar no longer forbids it, and that
card is the obvious first thing to become a panel.

Both columns took the change, because they are one column: decision 102 made
the in-match menu the landing's grammar carried into a match, and a grammar
that only half holds is two grammars. Nothing pauses either way, and the cap is
what keeps that promise honest: the fight goes on showing beside the glass and
through it.

**Cost:** the clock band and the radar are behind the panel now rather than
beside it. They read through the frost rather than over it, which is a real
step down from decision 102's "the two instruments that say so go on saying
it". Full height is what Chris asked for and what the mock he approved drew, so
this takes it as asked and leaves the reading to a look at the built page.

The landing loses one small thing with it: the lockup goes down with the stops
instead of standing over an open panel. That is right -- the column is one
object -- but it means the game's name is off the screen while a panel is up,
where before it was merely covered.

**Reconsider if:** the cap reads wrong at either end. 560 is a judgment about
where a row stops being one object, made against the two lists this holds
today; a panel that grows a third column of figures would want more, and the
number is one constant in `ui.lua`. Mocked in `.design/dropdown-stack`, where
the full-width version Chris corrected is still on the canvas.

## 104. One menu language

**Status:** accepted, finishing
[decision 103](#103-a-stop-opens-a-panel-not-a-list) by giving the container
it shipped one interior

**Decision:** every menu in the game is a panel, every panel is rows, and a row
is one shape. The name stands at the left in the menu's own voice; what stands
at the right end says what the row does, and it is the only thing that varies.
Six ends: opens, reads, steps, fills, switches, walks. One glass, one head, one
band, one wash pair, one breathing key. A card is a panel that stacked.

**Why:** Chris looked at the panels decision 103 shipped and said the menus were
not quite standardized in look and feel. They were not, and it was measurable.

The games and account lists set their names in the HUD's twelve point mono
capitals, because a list grew out of a strip drawn over a fight. The settings
page set its in the menu's own face at seventeen, sentence case. A hull's slots
were a third shape again, with their own row height, their own arrows and their
own inset. Walking from the games list into settings into a ship changed
dialect twice. Grounds sat at four opacities, rules at four alphas, and the
account card was the one menu surface in the game standing on no glass at all.

None of it had been decided. Each was written by whoever wrote the page, and
every one was defensible where it was written.

So there is one row now, and it draws all of them. `stage_row` was already the
richest of the three and closest to what the language wanted, so it became
`menu_row` and grew the four ends it did not have: the caret, the stepper, the
switch and the walker. The lists hand it their rows, the ship panel hands it
its slots, the settings page always did.

The voice is the menu's everywhere a panel stands. That was the whole of what
made the lists shout: a string takes its case from `F.case`, which the HUD sets
to upper, and a panel drawn over the landing inherited the case of the screen
it was drawn on rather than the case of the thing it is. The landing sets the
menu's voice around its panel now, the way `M.menu` always did around its own.

Three measures were unified on the way, and each was a real difference rather
than a rounding: rows are inset fourteen points on every panel, where the
settings page used twelve; a row is forty four points tall on every panel,
where a list row was thirty on a monitor; and the head's mark now starts on the
same line its rows' names do. Forty four is the touch floor and it is also what
a row needs before it can carry a sentence of its own, which is why the whole
interface moves to it rather than to the smaller number.

The ship panel stopped heading itself twice. It had the section's name on one
line and the roster's pager on another, which is two answers to "where am I";
the pager is an ordinary row now, the walker, with the arrows at its own edges
and the name between them.

The account card became a panel. It was a small centered rectangle on a ground
of its own at 0.98, outlined in a color nothing else here uses, with no way
back on it and no glass behind it: the odd one out on every count the language
names. As a panel it takes the head with the way back, the lines to fill in are
its rows, and the answer that commits is the breathing key at its foot. Cancel
and back were always the same act and one of them had no button.

That is also the first thing to stack. Pressing an account act used to shut the
account panel and raise a card over the bare landing; the panel stays open
underneath now and back steps onto it rather than all the way out, which is
what decision 103 said the grammar had bought and nothing had yet spent. It
turned up the one thing a stack needs that a single panel does not: glyphs come
from the gui and draw over every mesh, so a panel cannot cover the type of the
panel beneath it. The covered one stands down, which is the rule the nameplates
and the lockup already follow.

**Cost:** two things the mocked sheet drew are not in the code, deliberately.
The sheet captioned a reading at twelve points; every settings row already read
at fourteen, and fourteen is right beside a name at seventeen, so twelve is now
the band label's rung and nothing else's. And the sheet drew a dense thirty six
point row beside the forty four; no surface wanted one, and two heights is the
thing this decision exists to stop, so there is one.

A question with two equal answers is still a card. `M.room_card` asks whether
to move room, which costs a pilot everything they are carrying, and a confirm
is not a menu: it has no commit, both answers are real, and it should not be
the size of the screen. It stays a card and says so in its own head.

**Reconsider if:** a row wants a seventh end. Six is not a law, but the reason
this decision exists is that three surfaces each grew their own vocabulary
quietly, and a seventh end should be added to `menu_row` where every panel can
reach it rather than drawn once inside whichever page wanted it.
`client/tests/menu_language_test.lua` is where the cross-surface rules live:
it drives two or more real panels per check and asks whether what came back is
the same, because a test that drove one of them would pass forever while the
language came apart. Drawn in `.design/menu-language`.

## 105. Six corrections to the menu language

**Status:** accepted, correcting
[decision 104](#104-one-menu-language) where the language was right and the
drawing was not

**Decision:** a row's field is flat; a panel's head lights like the control it
is; a switch answers enter and space; a panel is as tall as what it holds and
slides between heights; a pointer lights every row a panel publishes; and the
shrapnel row reads the fragments a rung throws rather than the rung.

**Why:** Chris used it and found six things. Each is small and each was the
language failing to reach somewhere, rather than the language being wrong.

**The field was flat everywhere but one shape.** `LIT.field` laid most of the
weight flat and put the rest in a skirt against the left edge, falling off over
a hundred and thirty points. That is what a selection looks like against a lit
rule, and it was written for the drawer, which was docked to the left of the
screen and hung its rows off one. A panel is a floating rectangle outlined all
the way round: there is no rule for the accent to bleed off, so it drew a
brighter quarter of a row with a visible edge where the falloff ran out. The
scoreboard and the plate keep the skirt, because they still hang off a `vrule`.

**The head did not light.** It is the way back and it takes a press, and
`M.col_walk` names it, so the arrows could stand on it with nothing on screen
saying so. It lights now, from either hand, exactly as a row does.

**A switch took neither enter nor space.** Standing on a row that counts is
deliberately inert -- the row is where a hand stands so the arrows can spend,
and enter on it would have to guess which arrow was meant. A switch has nothing
to guess: it holds one of two answers and both arrows already mean "the other
one". Space presses in a menu now as well as enter; it is the guns key in
flight and cannot be a second enter there, but nothing in that branch is
flying.

**A panel was the height of the window.** Decision 103 said the whole screen
less the padding, which is right for a hull's build and absurd for three
account acts: a head, three rows and six hundred points of empty glass over a
fight somebody is watching. A panel is as tall as what it holds now, anchored
at the foot it slides out of, and over the room it has it takes the room and
scrolls. Its height eases when it changes, so opening a panel over another
slides the glass to fit rather than swapping two rectangles -- and it snaps on
arrival, because a panel rising through the edge is already a movement and a
height growing out of nothing at the same time is two gestures for one act.

**A pointer lit some rows and not others.** `LAND_HOT` was a list of the
controls that had been thought about, and two whole panels were missing: an
account act and a hull's slot lit under the arrows and stayed dark under a
pointer. One row, one way of being under a hand, whichever hand it is.

**Shrapnel counted the wrong thing.** It is the one add-on whose magnitude is
another weapon rather than a number: rung one throws four fragments and the
rungs above climb by two. A pilot spending a credit there is choosing between
four in the air and six, and the row said "1". `sim_splinter_count` is a new
read-only accessor on the core, because the ladder is the core's and nothing
else knows it; the row reads it through a `reads` field, which is the same
shape the rung rows' `base` already had for the same reason.

Two things followed from decision 104 rather than from Chris. The account
panels' heads were sentences ending in full stops, which is right for a card
asking a question and wrong for a head naming the section you are standing in.
And a claim or a log-in in flight replaced that head with "One moment.", which
on a card is the whole point and on a panel costs a pilot both the section name
and the label on the way back, exactly when a press has just failed: the status
goes on the line under the head now, in the caution color, superseding the
note.

**Cost:** the row height moved to forty four everywhere, which is what a list
row was not and what every settings row already was. That is more generous than
the thirty a monitor used to get, and a games list of eight zones is now taller
than it was; the panel grows to hold them and scrolls past the room it has.

**Reconsider if:** the height easing reads as slack. It runs on the same curve
and span the rise does, which is the right default and is one constant away
from being its own. The boards in `.design/menu-language` carry all six
corrections, so the sheet and the client agree again.

## 106. A lit row is the glass, edge to edge

**Status:** accepted, finishing
[decision 105](#105-six-corrections-to-the-menu-language)'s first correction

**Decision:** the field that says where a hand is runs the panel's full width,
and it is laid by the page rather than by the row. `menu_row` draws type and
nothing else.

**Why:** decision 105 made the field flat and left it at the wrong extent.
Chris opened the zone panel, put the cursor on a row and saw plain glass
showing either side of the highlight.

The row function is handed a type column, fourteen points inside the glass on
both sides, because that is where a name and its reading are set. It lit that
box. Two of the four surfaces lit the glass as well, so a games row came out
with a brighter band up the middle and two dimmer strips at the edges, and a
settings row came out as a box floating on a panel with no relationship to
anything around it. Neither is a selection. A selection is the row, and the row
is as wide as the panel it is in.

So the page lays the field now, through `LIT.state`, at the same rectangle it
publishes the press on. That was already what `menu_row`'s own comment claimed
and it had never been true of the code under it. The type column is published
as `M.ROW_INSET` instead, because the field used to be the only thing that said
where the column was.

**Cost:** one more line in each of the five places a row is drawn, against a
row function that decided its own lighting. Worth it: the thing that knows
where the glass ends is the thing holding the glass.

**Verified:** `menu_language_test` measures the lit field against the press box
on all four surfaces, which is one rectangle now rather than two. It fails on
the old drawing. `row_field_test` measures the type column off the field and
the published inset, and the pictures `hud_svg` writes carry a cursor at last,
so the panels can be looked at with a row lit.

## 107. The dial's two readings stand over it

**Status:** accepted, reversing
[decision 86](#86-the-dial-hugs-the-corner-the-link-bars-left) and
[decision 87](#87-the-tile-readout-goes)

**Decision:** the top right is a stack again. On the top row, over the dial and
inside its width: the tile you are on at the instrument's left edge, and four
bars of link quality flush against its right. The strip holds nothing else. The
radar and the map both begin on the line under it. Pressing the bars opens the
connection readout; pressing them again closes it, and so does a press on the
readout itself.

The bars carry no word. LINK stood beside them when the meter was last in this
corner, and four bars climbing in the corner of a screen are a signal meter on
every device a player owns.

**Why:** asked for. Both readings were taken out a decision apart and both are
wanted back where they were.

What each of those decisions said still holds as far as it went. The dial came
up into the corner because the strip above it was empty and an instrument
indented off a row that no longer exists reads as having slipped down the
screen. The strip is not empty now. The tile numbers went because the dial is
already a picture of where you are, which is true, and a picture is not the
form a position gets said out loud in: a pilot calling a place across a room
reads the numbers.

**What is different this time.** The readouts are placed against the dial's own
resting box rather than against the window, so the strip is exactly as wide as
the instrument under it and no wider. That is what stops the collision this
corner had before: the clock band stops at `TOP.dial_x`, which is one
measurement for the band, the meter and the tile readout together, and opening
the map moves none of them. The old arrangement placed the bars against the
window's right edge and the band against the bars, and at 390 points a call
sign was drawn straight through the coordinates.

Dropping LINK is what buys the room. The meter is 26 points of bars instead of
a word and bars, which leaves a phone's 112-point strip holding a caption, a
pair of four-digit tiles and the meter with ten points to spare.

**Cost:** the dial and everything under it start a key's height lower, so the
feed and the connection readout lose 26 points of the column they hang in,
which is a line and a half of feed.

A phone's strip is full at 112 points. An arena wider than the 1024 tiles
`SIM_MAP_TILES` allows would put five digits on each axis and overrun it.

**Reconsider if:** that arena arrives. The answer is to drop POS and keep the
figures, since the numbers are the reading and the word only says they are a
place.

**Verified:** `band_test` measures the stack at three window sizes: the meter
and the readout on the chip's own line, the dial under it at the chip's margin,
the readout starting where the dial does, the band stopping short of it, and
the pair holding still when the map opens. `hud_hits_test` presses the bars to
open the readout and the slab to close it. `hud_svg` draws the corner, and the
pictures were read at 1280x800 and at 390x844.

## 108. The front page carries no instruments of a room nobody is in

**Status:** accepted

**Decision:** the landing draws no radar, no board behind the band, and no
ending board at the whistle. The band keeps the clock and both sides' scores,
and the link meter over the empty corner keeps its bars. The instruments
arrive with the room: spectating counts as joining, because a spectator has
walked into one.

**Why:** decision 61 made the front page a live room watched from the stands,
and it inherited the watcher's HUD whole. A radar answers what is near you,
and there is no you on that screen: the camera is standing behind somebody
else's hull and the blips are their neighbors. A roster is the list of a room,
read by somebody in it to know which end of the gun they are on. The ending is
that same board with a head over it, so every three minutes the wordmark spent
twenty five seconds under a full roster and a line saying who took a match
nobody had watched the start of.

`ui.waiting` had already made the argument for the screen one step earlier:
before a room answers, the radar and the roster are absent rather than drawn
empty. The landing found a room and put them back. What it owes a stranger is
the fight, the name and the way in.

Decision 107 divides in the middle here. The bars are about the connection,
and the stands are a live connection, so they stay. POS is captioned where you
are, and on this screen it would put a stranger's tiles under that word, so it
goes with the instrument it stands over.

The keys stand down with the panels. The map key on the front page used to set
a flag nothing drew, which the next seat then cashed: press it in the stands
and the whole thousand tiles opened the moment you arrived in a room.

**Cost:** a visitor cannot look up who is in the fight they are watching until
they are in it. That is a press away rather than a screen away, and the band
still says what the score is. The corner keeps a strip with nothing under it,
which is the price of leaving the band's measure alone: `TOP.row_right` stops
at the strip, the strip is exactly as wide as the dial, and one measurement
answers on both screens. A band that spread into the space the missing
instrument left would hand an upright phone its two side names and take them
away again on PLAY NOW.

**Verified:** `landing_test` checks both directions on four windows: no radar
box, no POS, no press on the band, no board with the roster flag set anyway,
no board at the whistle and no wash for one, the meter still at the end of the
row, and the feed's strip starting under it rather than under a square nobody
drew. The same file checks that a pilot the room is holding a seat for keeps
all of it. The pictures `hud_svg` writes for the landing show an empty corner
at 1280 by 800 and at 390 by 844, and a match still shows the dial.

## 109. The in-match column speaks the menu language too

**Status:** accepted, finishing
[decision 104](#104-one-menu-language) on the one surface it did not reach

**Decision:** the settings stop carries no mark. Every stop insets its name by
`ROW_INSET`, and the sides list stands its rows at the panel row height like
every other panel in the game.

The ink this record also gave a stop with no answer is reversed by
[decision 111](#111-a-columns-labels-are-one-weight); the paragraph about it
below is kept as what was argued at the time.

**Why:** Chris opened the in-match menu and said he saw dim text and an icon
on the settings button. Both were there, and pulling on them found four things
wrong with the one column decision 104 never drove.

The icon was the tab rail's. `ui_menu_marks` drew a destination for each tab
of the drawer, and decision 102 deleted the drawer; one mark survived, on the
settings stop, because that stop had no word to put in the slot the others put
an answer in. It was a seventh right end in a language with six. It said the
word already written on the row, which is the argument that took LINK off the
bars and CHANNEL out of the corner. And it was drawn from the stop's right
edge at the same measure as the caret, so the two overlapped: the gauge ran
17.6 to 34.4 points in, the caret 11 to 19.

The dim text was the same stop. Every other stop is a question at the label's
weight with its answer beside it at full strength, and this one had no answer
to carry the ink, so it was a muted word alone on a lit box. That reads as a
control you cannot press. Its name is the answer, so its name takes the
strength.

Two measures were still on the numbers decision 104 replaced. A stop inset its
name by twelve, so pressing one stepped the type column two points sideways at
the moment the panel climbed out of it, on both columns. And the sides list
stood its rows thirty six points apart on a monitor and thirty on a phone,
because `M.menu` handed it the column's stop height rather than a panel's row
height. Thirty on a monitor is the exact number decision 104 quotes as the one
it was replacing. It survived because that list is built from the column, and
because the language sheet in `.design/menu-language` draws panels and rows
and has never drawn a stop.

**Cost:** `ui_menu_marks.lua` loses its last caller and goes, and with it eight
hand-drawn marks, `thumb` and its two tests. Seven of the eight were already
unreachable, and everything is one revert away in the history. The settings
stop is now a name and a caret, which is less than it had; what it says is
what the other two stops say, in the same words.

**Reconsider if:** a stop somewhere earns a picture. The rule that removed this
one is that a mark repeating the label is the label said twice, not that stops
may not have marks.

**Verified:** `menu_language_test` grew the two checks that would have caught
this, both cross-surface like the rest of the file: a stop insets its name by
`ROW_INSET` on both columns, and the sides list stands its rows the same height
apart as the games list, a hull's slots and the settings page. Both fail on the
old drawing (`landing 12, menu 12` and `sides 36`) and pass now. `column_test`
asks the settings stop for exactly two strokes in its right corner where it
used to allow more than two, since the mark shared that corner. `hud_svg` grew
`menu`, `menu-settings` and `menu-side`, which is how the collision was seen
in the first place, and the three were read at 1440 by 810.

## 110. Three corrections to the in-match menu

**Status:** accepted, finishing
[decision 109](#109-the-in-match-column-speaks-the-menu-language-too)

**Decision:** the in-match column draws at full strength, the settings page
opens each of its sections once, and the phone's kill line goes down under a
panel with the nameplates.

**Why:** Chris put the landing and the menu side by side and said the dimming
and the coloring were still wrong. They were, and by exactly a factor of
three.

`M.hud` drops every word on screen to 0.34 while a menu is up, so the
instruments the column stands over recede, and then it returns early with that
still set. The landing's column is drawn inside `M.hud` before that return and
came out lit. The in-match column is drawn after it, by `arena.script`, and
inherited a dim meant for what it covers: the same rows through the same
function, at 1.00 on one screen and 0.34 on the other. RESUME was grey against
PLAY NOW's white, a stop's answer was 0.32, and the ink decision 109 gave the
settings stop was a third of the way to being visible.

`M.land_card` and `ask_card` have always set the strength back for themselves,
for this reason. `M.menu` never did. It does now, except under a card, where
the dim is meant for the column too: a question is drawn after the column and
cannot reach back to quiet what it covers.

Nothing caught it because the shared test harness answers zero to
`ship_count`, and `M.hud` returns before the dim on an empty world. Every test
that drives the column drove it lit. The check that closes this measures the
two columns against each other, which is the only way to see it: 0.34 looks
deliberate until the identical row beside it is 1.00.

Two more came out of the same photographs. The settings page drew SHIP twice
with one row under each, because the wake and the charge keys both carried a
`sect` and a `sect` opens a band. And on a phone the kill line was drawn
through the middle of a settings row: glyphs come from the gui and the gui
draws over every mesh, so a panel cannot cover it, and on a phone a panel is
most of the window. It goes down under anything read over the arena now, on
the rule the nameplates already follow. The instruments stay, because a pilot
reading a menu can still be shot; the feed is news rather than an instrument,
and the corner feed is already off on a touchscreen for the same kind of
reason.

**Cost:** a phone loses the one line telling it who just killed you for as long
as a panel is open. That is a panel the player opened, and closing it is one
press.

**Verified:** `menu_language_test` measures the landing's key, label and answer
against the column's and asks them to match, plus the settings stop's ink and
the one case that keeps the dim. All four fail on the old drawing with the
numbers off the screenshots (`landing 1, menu 0.34`). `menu_test` asks the
settings page that no section opens twice, inside the block that gives a hull
two kinds of charge, since that is the only page carrying both ship rows.
`toast_test` asks for the line to be absent under a panel and present without
one. `hud_svg`'s settings scenario carries the real page's four sections now,
and the three pictures were read at 1440 by 810 and 390 by 844.

## 111. A column's labels are one weight

**Status:** accepted, reversing one clause of
[decision 109](#109-the-in-match-column-speaks-the-menu-language-too)

**Decision:** every stop's label is drawn at the label's weight, on both
columns, whether or not the stop has an answer beside it.

**Why:** Chris looked at the column and said the settings stop was too bright
against the two either side of it. It was. Three labels down a column with one
of them white is a column that looks broken rather than one that says
something.

Decision 109 gave that stop its name in ink on the argument that a stop with
nothing at full strength reads as a control that cannot be pressed. That was a
true observation with the wrong cause behind it. What made the stop read as
unpressable was decision 110's dim: the whole column was at a third, so the
muted label was at 0.34 and there was nothing on the row to say it was live.
The ink was a second fix for the same symptom, written before the first one was
found, and once the dim was fixed it was left holding a lit word in a column of
muted ones.

Which is the thing to take from it rather than the rule. Two changes for one
symptom is one change too many, and the one that survives is the one that names
the cause.

**Cost:** none that has shown up. The left edge of a stop is the question
column and it reads as a column now.

**Verified:** `menu_language_test` asks the color rather than the alpha, since
both labels were at 1.00 and only the ink differed: the three stops of the
in-match column and the landing's are one color, and the check fails with 109's
rule back in (`settings 0.87,0.91,0.96` against the others' `0.52,0.58,0.66`).

## 112. The ship menu is five parts of a ship

**Status:** accepted

**Decision:** the ship stop opens five rows, body, guns, bombs, specials and
flair, each one opening the part it names, with the build credits under the
back bar on the menu and on every section.

Body is the roster as a list, one hull a row, each row carrying that hull's
five flight bars, with the five words said once at the head over the columns
they name. A press on a row flies that hull. The same bars stand under the
body row on the menu, so the row names the ship and the strip says how it
flies.

Each section reads what it holds rather than what it cost, in the voice the
games list reads a format in: `menu_row` puts a detail at `TYPE.BODY` in
`pal.MUTE`, hard against the right of the type column. Guns reads "2 rounds ·
bouncing", specials "2 repels · 1 burst", flair "standard wake", body the
hull's own name. A part with nothing worth a word says nothing.

Flair comes back from the settings page, which loses its ship band. The level
row says Level rather than Rung.

**Why:** Chris asked for it, and the panel it replaces had grown into the
thing this menu language exists to stop. One glass held the roster walked on
its top row, the flight bars, the credit tray and then every slot the hull
could reach under three band labels: fourteen rows on an Apex, 762 points of
panel against the 782 an 810-point window has to give it. It fit a monitor by
twenty points and scrolled on everything else, and the first thing off the top
was the tray. A pilot stepping a slot near the foot was spending a purse they
could not see.

Five sections fix the tray by moving it out of the content: `panel_frame`
draws it beside the head, so it cannot scroll away at any level or any window
size. That is the whole of what was asked for, and the rest follows from
having room again.

The roster stopped being a pager for the reason decision 100 made it one and
then stopped applying. That decision called seven hulls with five bars apiece
a page in a list's clothes, which was true of a page that also held every slot
the hull could spend on. A section that holds nothing else is a list, and a
list is where the bars pay: seven read down a column compare, seven read one
at a time have to be remembered.

The readings are contents rather than credits because the tray already reports
the credits, once, over the whole ship. Both were drawn in
`.design/ship-sections` and Chris picked the contents; the count version is
still on that canvas as the record of the choice.

**Cost:** one press deeper to reach a slot. Spending a credit was two presses
from the landing and is three, which is the trade for a menu that fits and a
purse that stays on screen. `M.col_sect` is a second level of state on a stop
that had one, and `land_back` walks it down before it shuts the stop.

The spray reading assumes the zone steps one round a credit off a pattern of
one, which is the shipped arithmetic and what every hull's line in
`docs/design/ships.md` counts by. A zone that steps by two would read wrong
where shrapnel, which asks the core, would not.

**Verified:** built and photographed. The ship menu, all five sections and the
settings page it took the flair rows off were shot from a local zone through
`client/tools/shot.sh`; the Apex's tray reads three of seven in hand, guns
reads "2 rounds", specials "2 repels · 1 burst", bombs reads nothing, and the
body list stands seven hulls and sitting out under one column head with Anvil
at the floor of speed and Cipher at the top of it. `landing_test` covers the
five rows, every section, the walk and the tray at a rail's measure;
`menu_test` covers the readings, the roster rows and the level counted from
one. The middle dot in a reading was written `\u{00b7}` first, which is not an
escape in Lua 5.1 and drew as those six characters: the reading test is what
caught it.

## 113. Body is a carousel

**Status:** accepted, replacing the list [decision
112](#112-the-ship-menu-is-five-parts-of-a-ship) gave the body section

**Decision:** the body section turns one ship at a time. The hull is drawn
large and rotating in the middle of the panel, an arrow either side of the
drawing and level with it, the ship's name under it, and its five flight rows
read out one to a line below that. The name is the press that flies it; the
arrows only look. Sitting out is the page past the roster, with the sentence
about it standing where a ship would be.

The flight bars take a floor of 0.035, so the hull at the bottom of a row
draws a stub rather than nothing.

**Why:** Chris asked for it, looking at the list. What a hull looks like is
most of what a pilot is choosing between, and neither shape this section has
had could draw one: the pager had the room and never used it, and a row of a
list has no room to use.

Decision 112 argued the list from comparison, that seven read down a column
compare and seven read one at a time have to be remembered. That is still
true and it is not the whole question. The roster's spread is anti-correlated
by construction, so the comparison a player actually needs is one hull against
the range, which is what a bar against the roster's own low and high already
says on a single page. What the list bought was reading two hulls against each
other; what it cost was seeing either of them.

The floor came out of the same drawing. The Anvil is the floor of speed,
thrust and turn all three, so its page came out with three of five rows blank
and read as an instrument that had failed rather than as the slowest ship in
the game. On the list it was one row among seven and easy to miss; one hull to
a page is what made it obvious.

**Cost:** two hulls can no longer be read against each other without turning
between them, which is the thing decision 112 bought and this gives back. The
floor is a small lie about the share: a hull at nought of the range draws 3.5%
of the track. It keeps the order down every row and it stops a true zero
reading as a broken instrument.

`M.col_hull` is a third piece of state on the ship stop, and `land_page_ship`
comes back with it.

**Verified:** built and photographed. Apex, Anvil and the spectate page were
shot through `client/tools/shot.sh`, with the arrows turning the carousel
three ships along and wrapping past the end onto sitting out. Anvil reads
empty on speed, thrust and turn and full on energy and recharge, which is its
row in `sim/src/baseline.c` exactly. `landing_test` holds the two arrows level
with each other, either side of the drawing and above the name under it;
`menu_test` covers the page, the wrap and the sitting-out page.

## 114. The carousel draws the ship, and the ship takes the press

**Status:** accepted, correcting [decision
113](#113-body-is-a-carousel)

**Decision:** four corrections to the body section.

The hull turns about the axis running up the screen rather than spinning in
the plane of it: local x scaled by the cosine of the angle and the length left
alone, which is the bank `world.ship` already has. Broadside at nought,
edge-on at a quarter turn, nose up the whole way round.

The drawing is the ship rather than an outline of one. Plates washed and
outlined in the panel ink, hardpoints drawn hot, the canopy, and a silhouette
whose every edge carries its own brightness off `h.hot`. Every element and
every weight is `world.ship`'s, read off the same tables. What it leaves out
is the two skirts of bloom, which live on the fight's additive layer; a panel
draws on the interface's, which composites, so a skirt there hazes rather than
lights.

The ship carries the hull's own line under its name, which is the sentence the
roster in `menu.lua` has held since it was written and nothing had ever drawn.

And the press that flies a ship is published at the priority every other
control on a panel is published at.

**Why:** Chris said the rotation was about the wrong axis, that he could not
select the ship, that going back still showed an Apex, and that the graphics
were fake. All four are his, and the middle two are one bug.

`M.pick` keeps the first box of the highest priority it finds. `panel_frame`
publishes `panel_hold` at priority nought before any row draws, so that box
is first and any control sharing that priority is one the glass swallows.
The roster's press has been at nought since the walker had it, which means
pressing the ship to fly it has never worked on any shape this section has
taken: the box was published, every check asked whether it was published, and
none of them asked what a press resolved to. That is the test that was
missing, and it is the one that catches this class of bug rather than this
instance of it.

Nothing else was wrong with picking. `apply_menu` sets `menu.class` from
`menu.pending` on the landing, so the moment the press lands the menu follows
it: the Apex that would not go away was the press never arriving.

**Cost:** the drawing repeats `world.ship`'s recipe rather than calling it.
Threading a scale through that function reaches about twenty-five sites in the
arena's hot draw path, all of them multiplying by one for every ship in every
frame, and the two drawings can now drift. What the repetition buys is the
fight's own draw path untouched.

**Verified:** built and photographed. Apex broadside, Cipher part way through
its turn, and a Wedge picked off the carousel with the menu behind it reading
Wedge, its own bars, "Fused, 6 fragments" on bombs and two credits left of
seven, which is the Wedge's row in `sim/src/baseline.c` exactly.
`landing_test` measures the drawing at two points of the turn and holds the
width to shrink while the height does not, which fails on the spin it
replaced (`104x130 then 130x104`), and asks what a press on the ship, on an
arrow and on a section row each resolve to, which fails on the priority this
decision corrects (`panel_hold`).

## 115. A hull's line is about how it flies

**Status:** accepted, replacing the sentence [decision
114](#114-the-carousel-draws-the-ship-and-the-ship-takes-the-press) drew

**Decision:** the sentence under a hull on the carousel says what flying it is
like rather than what it is shaped like. The Cipher is the fastest hull in the
game and the only one with no bomb; the Anvil has the deepest pool and the
hardest round on the slowest hull; the Lattice has the weakest gun in the
roster and the deepest rack. The shape word beside each name is gone with the
shape sentence, nothing having read it.

A sentence that wraps is drawn raw.

**Why:** Chris asked for it, and the reason the sentence described the shape
had already stopped being true.

It said so itself: "these used to describe stats, none of it was true of the
simulation, every hull flies alike, so the sentence describes the shape". That
was right when it was written. A kit was thirty points and thirty points had
to buy the same ship whatever you were sitting in, so one flight row stood for
all seven and the shape was the only thing that differed. There is no kit to
be fair about any more and the hulls have their engines back, which
`sim/src/baseline.c` says in as many words. Seven distinct rows, and every one
of the five columns has a hull at the floor and a hull at the top.

The carousel finished the argument. A page that draws a long narrow ship at
seventy-eight points, turning, and puts "long and narrow" underneath is saying
twice what the drawing says once. The sentence is the one thing on that page
that can say what the picture cannot.

The raw drawing is a bug the wrap turned up. `pages.note_lines` cases a
sentence once and then breaks it, and its own comment says why: left to `txt`,
the case is applied per line as it is drawn. Drawn cased, the Wedge's line came
out "behind a fused blast and six / Fragments", with a capital in the middle of
itself. Only a phone wraps these, so only a phone showed it.

**Cost:** seven sentences to keep true as the roster moves, where the shape
ones were true as long as the polygons were. They are checkable, at least:
every claim here is a row in `baseline.c` or a line of `docs/design/ships.md`.

**Verified:** `menu_test` asks all seven for a sentence, holds the three that
name a superlative to it, and fails if any of them goes back to describing a
silhouette. `landing_test` draws the longest at a phone's measure and holds it
inside the glass on more than one line with no capital on the second, which
fails on the cased drawing with "Fragments". Photographed: the Chord reads
"Turns inside everything and outruns nothing" over a full turn bar and a speed
stub, which is its row in the flight table.

## 116. The ship menu carries no bars

**Status:** accepted, removing the strip [decision
112](#112-the-ship-menu-is-five-parts-of-a-ship) put on the menu

**Decision:** the hull's five flight bars come off the ship menu. They stay in
the body section, one to a line under the ship they belong to. The menu is
five rows and a reset over the tray, and nothing else.

**Why:** Chris asked for it. The strip went on the menu because the bars are
the answer to the question the body row asks, which is true and is not enough:
the row already answers with the hull's name, and a page of five plain rows
with one instrument wedged under the first is a page with a shape it does not
need. The bars belong to the section that is about the hull, and every one of
them is one press away.

It was also the last thing on that panel that was not a row. What is left is
the language decision 104 settled and nothing else.

**Cost:** comparing a build against the hull it is on is a press further away
than it was for four decisions. Nothing else reads a hull's flight from the
menu, so nothing else changes.

**Verified:** `menu_test` counts the menu's rows and holds it to seven with no
strip among them, which fails with the row back in. Photographed: five rows
evenly spaced over the tray, and the body section still reading a Wedge's
five lines under it.

## 117. The build is the pilot's, not the hull's

**Status:** accepted

**Decision:** a pilot has one build, and changing the ship it is bolted to does
not change it. Guns, bombs, specials and flair are the pilot's; the hull owns
its flight row, the two ladders its gun and bomb climb, and whether it has a
bomb at all.

It starts as the second rung of both weapons, a gun that comes off walls, a
fuse on the bomb and one of each charge: six credits of the seven, which
leaves one to put somewhere. Every pilot starts there, on every hull.

A hull that cannot reach a slot carries nothing in it and is charged nothing
for it, and the credit comes back the moment the pilot climbs into something
that can. The build is kept whole either way; what changes per hull is what it
costs, which is what `sim_kit_fit` has always done on the other side of the
wire.

Bots build their own ships too, off the personality the rest of their choices
come from, and no two off one strategy build alike. `pilots::kit` spends the
strategy's half first (a bombardier levels and fuses its bomb, a pilot who
works close buys rounds, one who breaks contact early buys a second repel) and
the pilot's own seed spends what is left. The bot server sends it as
`C2S_KIT`, which is the message a player's client sends, right after the
welcome that seats the pilot.

**Why:** Chris asked for both halves.

What it replaces is one build a hull, defaulting to that hull's own profile
off `baseline.c`. That put the roster's add-ons on the hull rather than on the
pilot: a Wedge came with its own fragments and an Apex with its own repels, so
picking a body picked a kit with it, and a pilot who had decided they wanted a
bouncing gun had to say so seven times. Seven chances to arrive in a ship they
did not build.

The bots' half is the same change seen from the other side. Every Wedge in the
fleet flew the same two rungs of shrapnel, because `sim_deal_kit` put the
hull's profile on and nothing replaced it; the only thing separating one
bombardier from another was how it flew. `pilots.rs` said as much at the top,
that what a pilot flies with is not among the things that make one distinct
"and no longer can be". It can again.

**Cost:** the roster loses the part of its identity that lived in the add-ons.
A Wedge is no longer the hull that comes with six fragments, and what is left
to tell one hull from another is its flight row and its two weapons. That is
still a real spread, and it is the spread the flight table and `gun_row` were
written to have; but `docs/design/ships.md` describes seven ships in terms of
kits that are now nobody's but the pilot's, and three of the hull lines in
`menu.lua` had to be rewritten for the same reason.

A save from before this wrote a build per hull. There is nothing to migrate it
to, since seven builds do not answer "which one is yours", so those saves start
on the default.

**Verified:** `cargo test` over the whole server, with three new checks in
`pilots`: every generated pilot spends its seven credits, the fleet builds more
than eight distinct ships and more than one bombardier build, and a bombardier
levels and fuses its bomb where a duelist buys no fuse. `menu_test` holds the
default to its six credits, holds the build across three hulls, and takes the
bomb away from a hull to watch the credit come back. Photographed: a Wedge
reading "Level 2, bouncing", "Level 2, fused", "1 repel, 1 burst" with one
credit in hand, which is the same menu every hull now opens on.

## 118. Turning the carousel is choosing the ship

**Status:** accepted

**Decision:** the arrows either side of the body carousel are the whole of
picking a hull. One step and the pilot is in it: the profile is set, the build
goes with it and the identity is saved, on the step rather than on a press
afterwards. The drawing itself takes no press. Its box stays, at the priority
a row that only anchors a cursor is published at, so a hand on a pad can stand
there and step left and right, which is what `land_kit_row` does for the
arrows either side of a count.

**Why:** Chris asked for it, and the panel was already telling the pilot they
had chosen. It drew the hull they turned to, named it in their own color, read
out how it flies and wrapped a line about it underneath, and then flew a
different one until they found the press. Everything on the glass said Anvil
and the ship in the stands was an Apex.

The press was there because the roster used to be a list and a list needs one:
you walk it to compare and then say which. A carousel shows one ship at a time
and has already narrowed to it, so the turn and the choice were the same act
being asked for twice.

An ask per step costs nothing because of where this panel lives. `land` is
built only while the stands are up, so `apply_menu` takes its home-screen arm
every time: a hull remembered and saved, nothing sent, nothing closed. The
arms that spend a respawn and shut the panel belong to the drawer's roster,
which is still a press and should be.

**Cost:** the carousel cannot be browsed without arriving. A pilot curious what
an Anvil looks like flies one to find out, and lands back where they started by
turning back. That is cheap on the home screen, where nothing has begun, and it
is the same trade the zone stop makes: turning the games list changes which
game PLAY NOW joins.

The `here` mark went with the press. There was a wash and a breath on the
carousel saying "this is the one you fly", which had something to point at only
while the drawing and the flown hull could differ. They cannot now, so the ship
is drawn in the pilot's own color, always.

**Verified:** `landing_test` pulls the `land_page_ship` branch out of
`arena.script` and runs it, the way the escape handler is run there: one step
right picks the hull it lands on and applies it, and a step off the end of the
roster sits out. The press checks that go with it hold the shape the drawing
has to have, since a box published at the wrong priority is invisible to a
finger and to nothing else: the arrows resolve to a turn, and the ship's own
box resolves to the glass behind it rather than to a control nothing answers.
Photographed on the Linux build: a Wedge, one press of the right arrow, and
the ship menu behind it reading Chord with the build untouched; then the same
again, reopening body to find it turned to the ship that was chosen rather
than back at the start.

## 119. A hull's line reads the five bars under it

**Status:** superseded by [decision
128](#128-the-ship-is-a-row-and-says-nothing)

**Decision:** the sentence under a hull's name on the body carousel says where
that hull stands in speed, thrust, turn, energy and recharge, and says nothing
else. Every line is a claim about the `flight` table in `sim/src/baseline.c`,
and the five bars it is claiming about are drawn directly underneath it.

**Why:** Chris said the old lines no longer make sense, and they do not. They
named the weapons: a wide blast and a chipping gun on the Wedge, a heavy round
on the Facet, a light round fired cheaply on the Lattice. Those stopped being
the hull's the day the build became the pilot's (decision 117). A pilot
reading "a wide blast" on a Wedge they are about to fly is reading somebody
else's build, and the blast they actually throw is whatever they bought.

This is the second time the line has described the wrong thing, and the first
time is worth remembering because it is the same mistake. It was the
silhouette for years, and that was right while a kit was thirty points and
thirty points had to buy the same ship whatever you were sitting in: one
flight row stood for all seven hulls and the only thing that told them apart
was their shape. The hulls got their engines back, the reason expired, and the
line went on saying it. A sentence describing something that used to be the
difference is how both faults look from inside.

What is left is what the hull owns and cannot be talked out of. Two things
qualify: the flight row, and the two ladders its gun and bomb climb. The
ladders are out too, and for a reason about the page rather than about
ownership: they are nowhere on it, so a line about them is one a pilot has to
take on faith, and it would be sitting directly over five bars saying
something else. The five under the sentence are the five the sentence is
about, and the eye can check it on the spot.

**Cost:** the lines are duller. "A wide blast and a chipping gun" tells you
what a Wedge does to somebody; "a deep pool that fills slower than any, on a
hull slow to turn" tells you what it is like to fly. The first is the better
sentence and the wrong one. What a hull does to somebody now depends on who is
flying it, and the panel already has a place that answers that: the four
sections under body, which read out the build the pilot is actually carrying.

They are also claims about the shipped roster, so a zone that retunes flight
makes them wrong. They were already that kind of claim, and the alternative is
generating a sentence from the numbers, which reads like a spreadsheet.

**Verified:** `menu_test` holds every line to the five rows: the Cipher's says
fastest, the Anvil's says slowest, and each of the seven names at least two of
the rows drawn beneath it. Two lists of words are banned outright, one for the
weapons and one for the shape, matched on whole words so a hull that outruns
everything is not read as a hull with rounds. Photographed on the Linux build.

## 120. The default build spends all seven credits

**Status:** accepted

**Decision:** the build every pilot starts in carries one rung of shrapnel on
the bomb, which the core throws as four fragments. With it the default spends
all seven credits: the second rung of both weapons, a gun that comes off
walls, a fuse, four fragments and one of each charge.

**Why:** Chris asked for the fragments. What comes with them is that the purse
starts empty, and that is worth stating rather than discovering. Before this
the default spent six and left one loose, so a pilot's first act was to find
somewhere to put a credit nobody had spent for them. Now it is to decide what
they are trading away.

That is the better first question. A loose credit is a small unfinished chore
handed to somebody who has not flown the ship yet and has no idea what they
want; a full purse is a ship, and every arrow on the panel is dead until the
pilot has an opinion. The rows say so on their own: `can_up` is false
everywhere while nothing is free, which the drawing already dims.

A hull that cannot reach a slot is charged nothing for it, so the purse is not
empty on every body. A Cipher has no bomb, so its rung, its fuse and its
fragments all come back: three credits in hand the moment a pilot climbs into
one, and the same three go back into the bomb when they climb out.

**Cost:** nothing on the ship menu can be bought without first selling
something, and on a first visit that reads as a panel where every arrow is
off. The tray says why, in the one place a purse belongs, and the alternative
is holding a credit back from the ship a pilot flies so the menu looks
livelier.

Bots are unaffected. `pilots::kit` spends the whole seven off personality and
seed and never read this default (decision 117).

**Verified:** `menu_test` holds the default to seven credits and to the seven
slots it fills, checks that no row goes up until one comes down, and reads the
bomb section back as "level 2, fused, 4 fragments" with the core's own
shrapnel ladder stubbed, since that reading is the one number on the panel
that is not its own count. Photographed on the Linux build: an empty tray over
five rows, and the bomb section reading its four fragments.

## 121. The loadout is nobody's ship

**Status:** accepted, superseding the per-hull weapon rows and profiles

**Decision:** a hull is a flight row and a footprint. There is one gun in this
game and one bomb, the same two whichever body is carrying them, and both are
ladders of three that any pilot may climb with their seven credits. The
per-hull `gun_row`, `bomb_row` and `profile` tables are gone from
`sim/src/baseline.c`, and so are `gun`, `bomb`, `gun_mods`, `bomb_mods`,
`charges`, `gun_rung` and `bomb_rung` from a zone's `[[arena.ships]]` block,
which now carries flight and nothing else. Weapons are named `gun`, `gun-2`,
`bomb`, `bomb-3` rather than `apex-gun` and `anvil-bomb-2`, and tuning one
tunes it for the room.

The ladder is the original's, every step of it:

| | first rung | a level adds |
|---|---|---|
| `BulletDamageLevel` | 200 | 100 |
| `BulletFireEnergy` | 20 | times the level, so 20, 40, 60 |
| `BulletFireDelay` | 25 | nothing |
| `BombDamageLevel` | 750 | nothing |
| `BombExplodePixels` | 80 | times the level, so 80, 160, 240 |
| `BombFireEnergy` | 300 | 50 |
| `BombFireDelay` | 150 | nothing |

With three more of its numbers put back beside them: `ShrapnelRate` is 2, so
the shrapnel rungs are 2, 4 and 8 fragments rather than 4, 6 and 8;
`BurstDamageLevel` is 700 everywhere, so the melee zone's 515 override is
deleted; and `BurstMax` is 3, which the burst rack now reaches. A fragment was
already the bullet of the thrower's gun rung and stays that way, which under
this ladder means an L2 gun breaks a bomb into L2 rounds exactly.

**Why:** Chris asked for it, and the reason is the one the roster kept running
into. A Cipher that could not be handed a bomb rack is a silhouette choosing a
loadout: a player who picks a body has picked a gun, a rack and a fuse without
being asked about any of them, and the one thing they were actually choosing,
how the ship flies, arrives bundled with six decisions they did not make.

It is also what the original does. All eight of its ships carry identical
weapon numbers and its per-ship section is a flight row; `MultiFire`,
`BouncingBullets`, `Proximity` and `Shrapnel` are `[PrizeWeight]` entries any
ship can be handed. Decision 117 had already moved the build off the hull and
onto the pilot. This finishes the move: the weapons went with it.

**Cost:** the roster is thinner. Seven hulls that differ by a fifth of a bar
and a tenth of a turn is less to choose between than seven that also differed
by a cannon, an empty rack and five barrels, and the hull tournament now
measures flight alone. The balance table in `ships.md` was measured against
the old roster and is marked as a record rather than a reading. A zone can no
longer take the rack away from one hull, or give one a weapon of its own,
because there is no per-hull ladder left to write; a zone that wants a
different weapon retunes the room's.

`calibrate builds` gets more interesting and `calibrate hulls` gets less: with
every hull on the same weapons, a slot that is too strong is too strong for
everybody at once, which is a cleaner question and a duller tournament.

**Verified:** `make -C sim check`, with the suite's settings stripped bare once
in `main` so a physics test flies a plain hull and the tests that are about a
build deal themselves one; the roster test now asserts that every hull names
the same two patterns and arrives on the same seven credits. `cargo test`,
`cargo clippy` and the client's Lua suite pass. The state hashes moved, so
`make -C sim golden` was rerun.

## 122. Walls give back what they take

**Status:** accepted, superseding the inelastic wall

**Decision:** `Misc:BounceFactor` is 16, which is the original's, so a wall
returns the whole of the speed that hit it. The baseline moves from 10 and the
melee zone from 12. `friction`, the speed kept along the face, stays at 14 in
the baseline and 12 in melee.

**Why:** Chris asked for the original's number. The one it replaces was ours,
and the argument for it was that clipping a wall should hurt, which is what
makes tight flying a skill. That argument does not survive being looked at:
what a lossy wall actually charges is a brake, and it charges it only to
pilots who touch things. A pilot flying clean pays nothing either way, so the
tax fell on the ones already having the worse time of it.

It also sat oddly in a model with no drag term anywhere. Velocity here changes
through thrust, a wall, bomb recoil, a repel and a wormhole, and nothing else,
so a wall that quietly ate a third of your speed was the only place momentum
went to die. Now it does not: what you carry into a wall you carry out.

**Cost:** the arena is faster and less forgiving. A ship that hits something at
speed leaves at that speed rather than being slowed into a place it can
recover from, which makes a wall a hazard to steer around rather than a
surface to lean on. Nothing measured that; it is a claim about feel and the
next playtest is what checks it.

`friction` is the loose end. The original has no term for the slide, so
matching it fully would be 16 there as well, and what ships is a wall that is
lossless head on and takes an eighth at an angle. That is a hybrid nobody
designed; it is left standing rather than changed in the same breath, since
the ask named one setting.

**Verified:** `make -C sim check`, with the wall test rewritten to read the
restitution setting in both directions rather than assuming a wall costs
anything, so it fails at 16 if the bounce loses speed and fails below 16 if it
does not. The grinding check still holds: a ship leaning on a wall under
thrust settles rather than buzzing, which was the other half of what the lossy
number was doing. State hashes moved, so `make -C sim golden` was rerun.

## 123. Recharge runs against the bar, not with it

**Status:** accepted, superseding a flight table where the two rose together

**Decision:** the last two columns of the flight table are anti-correlated. A
deep bar refills slowly and a shallow one refills fast: the Anvil fills in
twenty-four seconds and the Cipher in nine. Three rows moved and the energy
spread did not: Anvil recharge 1250 to 875, Cipher 1400/1100 to 1300/1450,
Facet 1400/1100 to 1450/1225. The four bodies already inside the margin were
left alone.

**Why:** decision 121 took the weapons off the hulls, which left a hull as its
flight row and nothing else, and `calibrate bodies` was built to ask what that
row is worth. The first run said the roster was not close: over 99,600 seats
the Anvil took 60% of its seats in a team match and 69% in a duel, the Cipher
42%, and only eleven of twenty-one body-by-skill cells sat inside a five-point
band.

The cause was one relationship rather than seven numbers. Fitting win rate
against energy and recharge explained 94% of the spread, at 1.7 win points a
hundred energy and 2.7 a hundred recharge, and the two columns ran the same
way round: the Anvil held the deepest bar in the game and nearly the fastest
refill at once. Nothing paid for the bar. What was supposed to pay for it, being
slow, pays nothing at all, since speed correlates *negatively* with winning
here at -0.75.

The obvious repair was to compress the energy spread until the fast hulls
caught up, and it is the wrong one: with speed worth nothing, that ends at
seven ships with the same bar and different top speeds, which is balance by
erasure. Turning recharge around instead leaves the spread alone, puts every
body on the fit's line, and buys an axis rather than spending one. The heavy
wins the long fight and is slow to be ready for the next; the knife loses any
fight it stays in and is whole again almost at once. It is also the only thing
in this table that makes speed worth having, because a fast refill pays a hull
that can break contact and nobody else.

The rerun says it worked: nineteen of twenty-one cells, the Anvil within half
a point of even at every skill, and at mid skill a roster sitting between 48.9
and 52.6 whose k/d spread has closed from 0.80-to-1.54 down to 0.93-to-1.09.
The Cipher gaining nine points on a *smaller* bar is the other half of the
answer to the open question decision 121 left: the bots were not ignoring
speed, nothing was paying them for it.

**Cost:** two cells still miss, both at high skill, and they are left alone.
The Cipher reads 52.7, 50.4, 45.2 across the strata and the Chord 47.7, 49.8,
55.1, so both slope against skill while these two columns are flat across it;
buying five points at the top would spend two certified cells to gain one.
What is left belongs to speed and rotation, or to the bots.

The duel arm is the other cost, and it was accepted rather than discovered.
It improved from six certified cells to eleven, but the Cipher overshoots to
62.6% at mid there and the Chord sits at 36.7%, untouched. The pit's fitted
coefficients are nearly twice the team arm's, because a room nobody can leave
turns a fast refill into flat extra life where a room they can leave makes it
conditional. The correction was solved on the team arm because melee is the
mode that ships, and a table balancing both rooms is probably not reachable
from two columns.

**Reconsider if:** the bots learn to disengage, which would change what speed
is worth and move every coefficient here; or a duel mode returns, at which
point the pit stops being a diagnostic and its numbers start counting.

**Verified:** `calibrate bodies 4 1200 melee` and `calibrate bodies 1 3500
melee`, before and after, at three skill strata: 99,600 seats an arm, sides
swapped inside every pair, equivalence tested at five points with the family
Holm-adjusted across the seven. `make -C sim check` with the hashes
regenerated, 457 server tests, clippy and fmt.

## 124. A wormhole is the original's field

**Status:** accepted, superseding a well that pulled linearly; the strength
retuned by decision 125

**Decision:** a wormhole pulls on an inverse square law. `wormhole_pull` is
quoted one tile out rather than at the mouth, and inside that tile it stops
climbing, so one number is both the reference distance the law needs and the
cap on the hardest kick anything can take. It is 5859, the original's.
`wormhole_range` is a setting of its own rather than a consequence of the
strength, and it is 38 tiles. A field lifts a caught hull's speed ceiling by
100 instead of replacing it. `gravity_bombs` is on, so a thrown round bends
across a well and a bullet crosses it straight. Settings version 21.

**Why:** the well this replaces was ours and it had the wrong shape: 90 at the
mouth, falling off linearly to nothing at a hard rim 220 px out. Fourteen tiles
of fairly even pressure and then nothing at all. It nudged a hull that flew
near one and nudged harder a hull that flew into one, and no part of it caught
anybody, so a wormhole was a texture on the map rather than something to plan a
route around.

The original's law catches. Its `gravity * 1000 / distance^2`, at the Gravity
of 1500 every ship in the Alpha Zone settings carries, is 5859 at one tile out,
and an inverse square is close to nothing across most of a wide field and
overwhelming in the last few tiles. That inverts the bargain: most of the field
becomes a current to correct for and the middle becomes a place not to be.

Quoting the strength at the mouth is not available under that law, since the
center of a well is a divide by nothing. So it is quoted a tile out, and a tile
in is where it stops climbing.

The reach is the one place we do not follow. There the range falls out of the
strength, so the original cannot express a well that is strong and small. Ours
can, and it has to: 76 tiles is where its field ends at that Gravity, drawn for
a 1024-tile map, and our melee rooms are 160 across. This shipped at 76 and was
halved to 38 the same day, which is 608 px, close enough to the mouth to be a
landmark rather than the weather over an entire room. Nothing else moved for
the halving, because what an inverse square puts in the outer half of a field
is almost nothing.

The ceiling lift is what makes a well throw a ship instead of only aiming one.
Without it the speed clamp takes back every pixel a second the pull just handed
over, so a hull falling in arrives at exactly the speed it could have flown
there under thrust. 100 is the original's, and it is small on purpose: it
applies anywhere in the field, and the field is most of a small map.

**Cost:** 5859 came in on the original's authority without being measured
against our maps, and it did not survive being measured. It put the point of no
return, the distance inside which a hull at rest cannot pull away on held
thrust, at seventeen to twenty-one tiles of the 38-tile field. That is the same
error the reach had, at a smaller radius, and halving the reach while leaving
the strength alone was reading half of it. Decision 125 cuts the pull to 2000.

`wormhole_pull` keeps its name and its type and changes what it means: it was
the pull at the mouth of a linear well and it is the pull one tile out of an
inverse square one. A zone file carrying the old number parses cleanly and
flies nothing like it did, which is the case a settings version exists for, so
this is version 21.

**Verified:** `make -C sim check`, with new tests that pin the shape rather
than the numbers. A probe at half the distance is pulled four times as hard,
the rim sits where the setting says, a hull inside a field tops out at exactly
`max_speed + wormhole_top_speed`, and a bomb thrown across a well bends where a
bullet does not. Sim behavior changed deliberately, so `sim/tests/golden.txt`
was regenerated with `make -C sim golden`: the replay map has a wormhole at
500,520 and the new reach touches the trace where the old one did not, so the
hashes move from tick 1000 on. The halving needed no regeneration of its own,
since the trace's nearest hull sits 127 tiles from that wormhole and outside
both rims. Widening the baseline to 400 tiles did move them, which is how that
null result was checked.

## 125. A wormhole you can still fly out of

**Status:** accepted, tuning the field decision 124 gave a wormhole

**Decision:** `wormhole_pull` is 2000, down from 5859. The reach stays at 38
tiles and the falloff stays an inverse square. Maelstrom's core drops from
four wormhole tiles to two.

**Why:** 5859 was the original's own number, what its `gravity * 1000 /
distance^2` produces at one tile from the Gravity of 1500 every Alpha Zone
ship carries. It is a number for a 1024-tile map, and we fly 160-tile ones.

What it bought here is easiest to see as the point of no return: the distance
inside which a hull sitting still cannot get out on held thrust. Measured
against the core by dropping each hull at rest and holding thrust straight
away from the mouth, that radius was seventeen to twenty-one tiles of a
38-tile field. Half the reach was not somewhere to fly, it was a verdict
already delivered. At 2000 it is ten to twelve tiles and the rest of the field
is a current to correct for.

Maelstrom was worse than the setting, and separately. `spiral_nebula` laid
four wormhole tiles as a 2x2 block, and every wormhole tile in range sums, so
that map ran at four times the pull of a lone mouth. Its point of no return
was 33 to 38 tiles of a 38-tile field: reaching the field at all was the whole
decision, and the Wedge, the Anvil and the Lattice could not thrust out of it
from anywhere inside. No amount of tuning the shared number fixes one map
being four times another, so the core is two tiles now, which is one call to
`Canvas::wormhole` rather than two.

Chris asked to keep the reach and to stay off a linear falloff, and the second
of those turns out to carry an argument of its own. An n-tile core multiplies
the pull by n and the point of no return by the root of n. A shallower law
moves it by n itself, so a stacked core under anything gentler than an inverse
square is worse, not better. The shape was already the right one.

**Cost:** the far field goes quiet, and that is the trade the reach could not
avoid. With one reference distance, an inverse square ties what a well is
worth at the rim to what it is worth in the middle, so the same cut that frees
the middle drains the edge. Five seconds of ignoring a well at the very rim
used to hand a hull 202 px/s toward it, two thirds of a top speed near 305;
now it hands over 69. The 38 tiles are honest either way, but they are a bend
to correct for rather than weather that owns the room.

Ringworks scores half marks on the wormhole term of its own theme fidelity,
because `rings` places one pair against a denominator of four. That is
untouched here. It predates this and changing it would move which seeds the
generator picks for a map nobody asked about.

**Verified:** the point-of-no-return figures come from a probe against the
core itself, spawning each hull at rest at a bisected distance and holding
thrust outward until it either clears the rim or loses ground. `make -C sim
check`, with the ceiling-lift test given a window long enough for the slower
fall: it sampled 80 ticks, and from twelve tiles a hull now needs about 134 to
reach the mouth. The lift still tops out at exactly `max_speed +
wormhole_top_speed`. State hashes moved, so `make -C sim golden` was rerun.
459 server tests, clippy, fmt, and the 70 client Lua tests. Maelstrom's
recipe was re-pinned and its map regenerated; quality is unchanged at 92.5,
since the theme's fidelity denominator moved with the core it counts.

## 126. The roster flies inside the original's bands

**Status:** accepted

**What:** four of the five flight columns get bounds, and they are the
original's own. The Alpha Zone settings are eight ships climbing one ladder,
so the span between what a ship arrives with and what a fully greened one
reaches is everything anybody ever flew there: speed 2010 to 3750, rotation
200 to 300, energy 1000 to 1700, recharge 400 to 1150. Ours are seven hulls
that do not climb, so those become the edges of the roster instead.
`sim_class_clamp` holds both ends of every ladder wherever a row is written,
the zone-apply path included, and a zone asking for more gets the edge and a
warning rather than a number that quietly did something else. Thrust keeps no
bound: the original runs 15 to 19 across every ship and every upgrade, which
is narrower than this roster wants and is the one column a bound would flatten
rather than shape.

Every row was then carried onto the bands by a straight linear rescale, and
three of them were retuned afterwards to pay for what the rescale cost.

**Why:** the roster had drifted past the game it is copying at both ends,
running 2650 to 3900 on speed where the original never exceeded 3750, and
1300 to 2100 on energy against a flat 1700. Bounds make that a rule rather
than a habit, and they make it a rule a zone cannot leave.

**Cost:** the rescale broke the balance, and the measurement is the record of
putting it back. Nineteen certified cells fell to fourteen, because narrowing
the energy spread an eighth while widening the recharge spread a third moved
weight onto the refill, and because holding speed inside the band slowed the
roster a sixth, which raised the price of turning. Rotation is worth -0.26 win
points a hundred units at low skill, +6.76 at mid and +11.78 at high; energy
and recharge explained 94% of the roster's spread before the rescale and 72%
after. Two corrections got it back to nineteen: the Anvil off the recharge
floor to 560, the Chord off the rotation ceiling to 265 and down to 750
recharge, the Cipher to 1075. The first of the two overshot because it trusted
the regression's one-to-three points a hundred over the roster's measured
four, which is the lasting lesson: `calibrate bodies` fits seven bodies
against three predictors, so it gives a direction and not a magnitude.

The maps got 18.8% longer to cross, since the contact gate times the shortest
home route against the median hull and that fell from 3050 to 2567. Only
drydock lacked the headroom; its ceiling was carried across by the same ratio.
The other recipes now allow less geometry than they were written to.

**Verified:** three runs of `calibrate bodies` at 99,600 seats each, 1,200
swapped pairs a stratum in the team arm and 3,500 in the duel. Team arm ends
at nineteen of twenty-one with the high stratum the tightest band in the
roster, 48.5 to 51.9. The duel arm is unchanged at eleven, Chord 35.5% and
Cipher 60.1% at mid against the 36.7 and 62.6 already on record: a correction
solved on the team arm arrives in the pit at roughly double strength, which
decision 123 predicted and this measured twice. `make -C sim check` with the
golden regenerated, 460 server tests, clippy and fmt.

Two things fell out worth keeping. The Chord's thrust buys nothing measurable:
energy, recharge and rotation explain 97% of the high-skill spread and its
residual is half a point, so the hull at the top of the thrust column is not
strong because of it. And the roster's energy-against-recharge anti-correlation
is monotonic across all seven for the first time, the Chord having been the one
hull with more energy than an Apex and a faster refill besides.

## 127. A bench says why

**Status:** accepted

**What:** the welcome carries a reason byte, and a pilot the room moves to the
stands is told which of the two ways it happened. `S2C_WELCOME` gains a
trailing `why`: zero for every seat a pilot brought about themselves, 1 for the
safe-zone sweep, 2 for input silence. The client prints one line in the feed,
red and marked as its own, and plays `ui_deny`:

    moved to spectator: unstable connection
    moved to spectator: too long in the safe zone

**Why:** the two five-second clocks in this game are the same number by
coincidence, and they meet badly. A pilot whose input stops for
`spectate_silence_ticks` loses the seat, and a new watcher is deliberately
landed on the channel's warm ring rather than staring at nothing for
`CHANNEL_DELAY`. Both are 500 ticks. So the first frame a benched pilot is
served is the tick their own inputs stopped: they watch their own hull drift
inputless, get killed, and disappear, and nothing on screen says any of it
already happened. The reading available without a line is that the game has
come apart.

The replay itself is right, and so is the delay. Serving a benched watcher the
live edge instead would make going quiet for five seconds a button that buys a
live view of the room you were just fighting in, which is the hole the delay
exists to close, and giving one watcher a different ring position breaks the
one feed everybody else is on. Only the sentence was missing.

**Cost:** `CLIENT_PROTOCOL` moves to 33. A client built for 32 reads the
message it wants and ignores a byte, so the refusal is not protecting it
against a misparse the way 22 and 31 were; it is there so the fleet and the
page are never one build apart on a wire field.

The reason rides the welcome rather than being worked out at the far end. Both
involuntary benchings arrive as an ordinary welcome on seat 255, identical to
the one a pilot gets for pressing the key, so a client left to infer it would
have to pair the swap up with a lag notice by timing, which is the thing
`S2C_KILL`'s assist byte exists not to do.

**Verified:** 461 server tests including a new one reading the reason off all
four welcomes the zone sends, clippy and fmt. The client's own suite with a new
watch_test arm walking a socket through both benchings and both voluntary
seats, plus a constant_drift guard holding `CLIENT_PROTOCOL` and the two reason
codes against their Rust originals: perturbing either side fails it. luacheck
clean.

## 128. The ship is a row, and says nothing

**Status:** accepted, superseding [decision
119](#119-a-hulls-line-reads-the-five-bars-under-it)

**Decision:** the hull on the body carousel is drawn in one ordinary row of
the panel, with its name under it at a row's own weight and an arrow either
side level with the middle of the two. The sentence that ran under the name
is gone, and the roster in `menu.lua` is seven names.

**Why:** Chris said the drawing was too tall, twice. It was 168 points of
picture over five bars that take 130 between them, and taking sixteen points
off the radius did not change what it was: a drawing with a size of its own,
written down beside it and answering to nothing on the page around it. Every
other row on that panel is 44 points because 44 is the floor a platform puts
under a fingertip, and the carousel is the one row that had opted out. It is
a row now, and the radius is whatever that leaves.

The sentence went with the height, and for its own reason. Decision 119 had
already narrowed it twice: it was the silhouette, then the weapons, then where
the hull stands in speed, thrust, turn, energy and recharge. That last one is
what the five bars directly beneath it draw. So the page was agreeing with
itself out loud, in adjectives above and in lengths below, and spending two
wrapped lines a hull to do it. The bars are the better half of the pair, since
they answer "faster than what" against the rest of the roster where a sentence
can only assert.

**Cost:** the ship is small. The Wedge was drawn 83 by 103 points and is now
27 by 33, measured off the strokes it puts on the layer. It comes out smaller
than the row even so, because `reach` is a radius over the whole polygon
rather than along the length, so a hull as wide as it is long sits well inside
its own circle. What the drawing has to do at that size is tell seven
silhouettes apart, and it does, because the identity was built around a front
visibly not a back rather than around detail. It is no longer a portrait.

The seven lines are gone from the tree. They were good sentences and nothing
reads them now; `docs/design/ships.md` is where the roster is described at
length, and that is the right place for prose about a hull.

Two things followed the height down. The name was set at `TYPE.LEAD`, the
largest type the interface has, which left the biggest thing on the page
announcing the smallest; it is `TYPE.ROW` now, the weight every other label on
this panel is set at, and its band is 26 rather than 30, the same as one of
the flight rows under it. And the arrows moved off the drawing's middle onto
the row's. They stood beside the ship because the ship is what they turn, but
the name turns with it: beside the upper half of the pair they sat in the top
third of the row with its centre line empty between them.

**Verified:** `landing_test` measures the drawing off the strokes it puts on
the layer and holds it inside one row, which fails at 103 points against the
code this replaces. `menu_test` holds every page of the carousel to a name
with no sentence on it. The arrow marks are read off the layer rather than off
the boxes they publish, since a box centred on its own mark says nothing about
where either sits, and held to the middle of the row: level with the ship it
misses by thirteen points and fails. Their boxes were a fixed 52 points and
hung over the edge of a row this short, so each takes the whole row instead.
A second check opens the section at a phone's measure and finds all five
flight rows drawn; it passes against the old height too, so it is a guard on
what the room is spent on rather than evidence of a fix. luacheck clean, the
client's whole suite green, and the section photographed at both measures.

---

## 129. A flag stands where the map says

**Status:** accepted

**What:** flags come off the map's own `SIM_TILE_TURF` tiles. A map that draws
none is not a flag game and gets no flags. `arena.flags` becomes a cap on how
many of them a zone plays rather than a count of how many to invent, and
mapforge lays stands beside the spawns, so any theme can carry them.

The core gets two settings to go with it. `flag_carry` decides whether taking a
flag picks it up, which is the original's `Flag:CarryFlags` read as a yes or a
no, and it is the whole difference between War and Turf. `flag_carry_ticks`
puts a carried flag down on its own after a while, keeping the side that took
it.

**Why:** both paths that built a room laid four flags at tiles 472 and 552,
which are the built-in arena's quadrants, measured on the 1024-tile ground that
arena is. Every map a zone ships is 96 to 256 tiles, so those four flags sat
outside the map's own wall, unreachable, and Team Battle drew a pennant apiece
across the top of its HUD for a game it was not playing. Nothing was going to
notice: the melee mode does not read flags, so the only symptom was four grey
marks nobody could explain.

A turf zone made the same bug the other way round. Its stands are the whole of
where the fight happens and there was nowhere for them to come from, because
nothing had ever read a stand off a map.

The carry clock is a separate answer to a separate problem, and it is here
because it is the same three fields. Without it the other side's only reply to
a pilot running off with a flag is to kill them, and a hull built not to be
killed takes a four flag round down to three that nobody can finish.

**Cost:** `CFG_VERSION` moves to 22. The determinism golden did not move: no
flag in the replay trace is carried, and the state hash of a flag with no clock
running on it is what it always was.

A zone that wants the old four-flag arena on a map with no stands cannot have
it. That is deliberate. The alternative is a room deciding for itself where a
game's objective goes, which is what produced the flags outside the wall.

**Reconsider if:** a map wants stands somewhere a half-turn cannot put them.
Stands are drawn in pairs, so the count is even, and a map with an odd number
of them is refused rather than quietly given one more than it asked for.

---

## 130. Turf is paid, War is a match

**Status:** superseded by
[decision 165](#165-a-flag-game-is-won-by-holding-the-set), which took the
payout and the rounds out and made both zones one game: hold every flag for
fifteen seconds and the match is yours. The flag rules below are unchanged and
are still the whole difference between the two.

**What:** two zones off the flag mechanism above.

Turf pays each side one point per stand held, every five seconds, and the match
belongs to whoever has the most at the whistle. Its flags cannot be carried:
flying over a stand claims it, and it then settles for the drop cooldown before
it can change hands again.

War keeps the original's round, where a side takes it by holding every flag at
once for ten seconds, and wraps a four-minute match around the rounds. The
match score is rounds taken.

**Why:** the payout is what stops turf collapsing into one scrum. Holding two
stands of six is not a losing position, it is two points every five seconds, so
a side that gives up the middle and keeps its own half is playing rather than
waiting to be beaten, and a scrum that wins one stand is paying for it with the
four it left.

The settling window is not a nicety. Two pilots of opposite sides sitting on
one stand take it from each other every tick, a hundred times a second: the
pennant strobes and which side the clock happens to pay is decided by the tick
the payout lands on rather than by the fight.

The match around War's rounds is ours and the original had nothing like it. A
room that ran rounds forever had no score to show, no clock beside the deploy
key, no ending board and no reason to change ground, which made it the one game
in the catalog a player could not read from outside the room.

**Cost:** three modes now want the same two-phase clock, so it moved out into
one that reports which beat a tick is. Melee is the same game through it, and
the whistle tick still belongs to the match it ended, which is what makes a
bomb already in the air count and what lets a round completed as the clock runs
out be a round taken.

Two more zones is two more bot populations to keep honest and two more balance
surfaces. Neither has been measured yet; both are drawing the roster Team
Battle was tuned for.

**Reconsider if:** the five second period reads as arbitrary in play. It is
thirty-six payouts over a three minute match, which puts a stand held end to
end at 36 and the six between them at 216, and none of that has been played.

---

## 131. A duel is a two-seat zone and nothing else

**Status:** accepted

**What:** the duel comes back as a catalog zone running the melee mode with one
pilot a side, on maps ninety-six tiles across. No matchmaker, no rival hold, no
per-seat card.

**Why:** [decision 96](#96-duels-are-gone) took duels out and its own note on
what would bring them back said the pieces worth keeping were the pairing rule
at the door and the card, and that both were built around a zone whose rooms
hold two seats. A two-seat room turns out to make the first of those free: the
fill ladder already prefers the fullest room below its cap, which for a room of
two means the one with somebody waiting in it, and a pilot who finds nobody
opens a room and becomes the person the next arrival is put beside.

The maps are the reason this is a zone rather than a line in the melee file.
Two pilots searching a hundred and sixty tiles for each other is a draw, which
is what a 1v1 on melee ground measured as. Ninety-six tiles with two routes
between the pockets is four to six seconds home to home rather than twelve to
fifteen.

**Cost:** a zone now rates into its own name rather than its mode. Filed by
mode, a duel's rating would have been pooled with Team Battle's, and holding
your own against one rival in a small room has almost nothing to do with being
useful in a four a side fight. Nothing already recorded moves: the only zone
that has rated anybody is melee, whose key and mode are the same word.

Pairing by rating stays out. It is decision 92's, it needs a band and a queue,
and it is a decision to take on its own rather than something to slip in with a
zone file.

**Reconsider if:** the door pairs people who should not be paired. The fill
ladder is blind to rating, so at any population above a handful the first two
people to arrive are the fight, whoever they are.

---

## 132. A green raises what you fly, not what you own

**Status:** accepted

**What:** greens are back in the simulation core, and a free roam zone turns
them on. A green fills a slot in the kit space; a pilot keeps it until they
die, because a respawn deals `sim_ship::kit` again and a green never touched
it. That is the whole death policy and it has no setting.

They are put out in a ring six to twenty-eight tiles from a live ship, two
dozen at a time, rolled against a per-zone weight table.

**Why:** the zone this catalog did not have is the one the original was about.
Every other game here is a match, and what replaces the match as a reason to
keep flying is growth over a life.

The ring is the part that was got wrong the first time and is recorded in
[design/maps.md](../design/maps.md). Scattered by area, two hundred greens over
a million tiles is one per five thousand against a pilot who sees sixty tiles,
and the zone that ran that way read to its players as having none at all. Two
dozen where the people are beats two hundred in a million tiles of nobody, and
it also answers the bandwidth: eleven bytes a green, and every one of them near
somebody who might take it.

Filling a slot rather than granting a thing is what makes this cheap. The kit
space is already the shape of the question, its own header records that it used
to be what a green indexed, and `sim_grant` already refuses to push a slot past
the hull's ceiling. So a green that lands on a full slot is spent for nothing,
which is a real cost of taking one you did not need.

Who runs the field is a rule this repository had already made, and this went
out without it. Decision 43 states it: interest filtering writes an
out-of-radius green inert, so a client's live count says something about the
few greens near it rather than about the room, and a client that believes the
field is short sows a phantom prize for the next snapshot to sweep. Here it
was louder than it had been in 43, because `green_at` is state rather than
wire. Every snapshot left the timer at zero, so the next tick put one out, and
what Free Roam showed a pilot was a green blinking in and out of existence
near them at snapshot rate, none of them real. A deathless instance now puts
none out, expires none, and takes one only for its own pilot; `sim.h` carries
that beside the two rules of the same shape it already had.

Decision 44's private prize generator was lost the same way, and is back. A
green was being rolled from `sim_state::rng`, which every snapshot carries
because a client needs it to predict a scattergun's spread and a spawn. A
client could advance it and work out where the next green would land and what
it would be, then go and wait there. The greens now roll from `prize_rng`,
which no snapshot carries and which `sim_prize_seed` installs: the arena gives
each room a value out of its own entropy, and the shipped client never calls
it. The stream and its clock are out of `sim_hash` as well as off the wire,
which is one rule rather than two exceptions, because what the hash covers is
what a snapshot carries and a pack round trip is checked by comparing hashes.

Zero means no stream and a state with no stream sows nothing. That is the loud
failure on purpose: a room that skips the seeding is a Free Roam with no
prizes in it, which somebody notices within a minute, where greens landing
somewhere a client could have named in advance is a thing nobody sees at all.

44's other half does not carry over. It had a client remove a green it touched
while applying no grant, because back then the roll happened at the moment of
pickup and a guessed grant would have shown a player the roll. A green decides
what it is when it is put out now, and `slot` rides in the snapshot beside its
position, so there is nothing left at pickup to hide and the client's own is
predicted whole.

**Cost:** `CLIENT_PROTOCOL` moves to 34 and `CFG_VERSION` to 23, and the
determinism golden is regenerated. The state hash covers the greens now, which
moves it even in a room that has none, and every match game we ship has none.

The protocol bump is a real refusal rather than a courtesy. Greens go in the
snapshot after the flags, so a client built for 33 stops reading where the
flags end, and `sim_unpack` treats a short read as an error exactly as it
treats a long one: every snapshot from a room with greens in it would be
refused rather than misread. On a match game the difference is one zero byte;
Free Roam is the zone a stale build could not have joined at all.

The map is not mapforge's. Its envelope stops at 256 tiles and past about 300
every theme thins below its own cover band, because the geometry is written in
tiles rather than in fractions of the map. `mapgen` draws the 1024-tile arena
instead, from the measurements in
[research/map-measurements.md](../research/map-measurements.md), and the seed is
the provenance. That leaves one map in the catalog with no `mapforge verify`
behind it.

**Reconsider if:** the weights are wrong, which they have not been played
against. They are stats-heavy, which is what Alpha Zone's own file is, on the
argument that growth should feel like a slope rather than a series of unlocks.

---

## 133. Carrying the flag puts you on the map

**Status:** accepted; the client's side of it and the green filter are not
built yet, and this record gains a Verified section when they are.

**What:** three rulings on what the objective wire discloses, made together
because they are one question.

Flags keep traveling whole, carried flags included, to every client in the
room. A carried flag reports its carrier's exact position, so this is a
deliberate disclosure: pick up a flag and you are lit, map-wide, until it
comes down. The client is taught to draw what the wire already says, so
lawful sight matches disclosure: flags go on the map overview at their true
positions, and a carried enemy flag outside the radar's window pins to the
radar's edge as a bearing.

Greens go behind the interest filter with the ships and the rounds,
out-of-radius entries written inert so the format does not move.

**Why:** the doctrine in [networking.md](networking.md) is "no knowledge
beyond lawful sight", and the two entities break it in opposite directions,
so they get opposite fixes.

Flag state is the scoreboard. The pennant strip already tells every pilot who
holds what, grounded flags stand on tiles the map file itself publishes, and
the original showed its flags zone-wide on the big map. The one thing the
wire said that the client did not show was the carrier's position, which made
it a maphack: information only a modified build could render. Freezing or
blurring the carried position was considered and rejected, because hunting
the runner is the game War is about, and a carry clock already bounds how
long anybody stays lit. So the fix runs the other way: widen lawful sight to
match the wire. The overview's own rule survives intact. It draws no ships
because a map of everybody would be a wall hack, and a flag is not a ship; a
carried flag putting its carrier on the map is the cost of the flag, paid
knowingly by whoever takes it.

Greens have no scoreboard argument and carry a second signal flags do not:
one is put out six to twenty-eight tiles from a live ship, so an unfiltered
field is a beacon on every pilot in the room, including the ones far outside
anybody's lawful sight. The honest client draws them only inside the render
window and never on the radar, so beyond the fairness radius they are
disclosure with no legitimate reader. The interest radius was originally
sized "when it filtered prizes alone"; the rebuild of greens dropped that
without noticing, and this puts it back.

**Cost:** an inert green record is the same eleven bytes, so the filter buys
disclosure and not bandwidth, and the wire format holds: no protocol move.
The overview gives up a little of its austerity, and a pilot who wants to
stay dark in War has one honest way to do it, which is to not pick up the
flag.

**Reconsider if:** being lit makes nobody carry. The counterweight is the
carry clock: thirty seconds of being hunted is a shift, not a sentence.

---

## 134. The career endpoint goes; the session and the roster already said it

**Status:** accepted

**What:** `/v1/career` is deleted, along with the ten second poll behind it.
The one fact its caller wanted, whether this pilot has ever been rated, now
comes off two things the client already receives.

**Why:** the endpoint was built for the in-game career page in
[decision 70](#70-sign-up-and-the-pilot-page-is-the-career) and
outlived it.
[Decision 99](#99-the-account-is-a-dropdown-and-the-pilot-page-is-gone)
moved the career to the site's own `/pilots` and deleted the page, leaving
one reader: `guest_stakes()` in the menu, which took `.games > 0` off the
reply and ignored the rating, the tier and the lifetime totals that came
with it. Every unclaimed guest asked for all of that every ten seconds to
learn one bit.

Both halves of that bit were already on hand and neither costs a request.
`/v1/session` returns a row per zone with the games flown in each, because the
token is minted from those same rows and the reply carries them for the panel;
the client received the array and dropped it. That answers for a pilot who
arrives already rated. It cannot answer for the guest whose first rated game
lands in the room they are sitting in, which is the case the poll existed for,
and the roster broadcast answers that one: it carries games flown per seat and
arrives twice a second, so the warning arms about as fast as the death that
earned it is drawn.

The two are read together because they answer different questions. The session
is every zone and the whole account's history; the roster is this seat in this
zone, and a guest rated in Team Battle shows nothing on a Free Roam roster.
Either one alone under-reports.

**Cost:** the warning is now armed by a latch over two sources rather than one
number from one place, which is more moving parts in exchange for no endpoint,
no poll, and no query. A watcher holds no seat, so mid-match arming does not
apply to them; the session still covers what they have already earned.

**Reconsider if:** something wants the lifetime kill and death totals in the
client. They are on the site's pilot page and nothing in the game asks for
them, which is why they left with the route rather than being kept against a
caller that might appear.

---

## 135. Sitting out wears the badge

**Status:** accepted, and its first half superseded within the day by
[decision 136](#136-a-ship-is-one-thing-and-changing-it-costs-a-respawn),
which took the page it drew off the carousel. The recut feathers stand: they
are the badge everywhere it is drawn, and four callers still draw it.

**What:** the ship stop's body carousel draws the pilot's badge on its last
page, where seven hulls turn through the pages before it. `pilot_mark` gets a
fourth caller, at the circle a hull is drawn in rather than at eleven points,
in the instrument gray rather than in the pilot's color, and it holds still
while every hull on the same carousel turns.

The badge's feathers are recut, everywhere it is drawn. They were three struck
lines a side, at 32.1, 28.3 and 30.8 degrees, capped round. They are six
closed shapes now, all six at 30 degrees, cut against two lines and tapered
from 0.020 of the mark at the root to 0.039 at the tip.

**Why:** the carousel had a hole in it. `sect_rows` sets a row's `cls` only
where the roster's value is a number and `land_row` draws a ship only where
`cls` is set, but the row keeps a hull's height whether or not there is a hull
to put in it. So sitting out was a word under an empty space with an arrow
either side of it, and it read as a row that had failed to load rather than as
a choice. Nothing else on this menu has a hole in it.

Four drawings were made for that hole and mocked over the real menu in
`.design/spectate-body`: the roster's own shape with the canopy outlined and
empty, a camera whose bright cell is a pupil where a hull carries a canopy, a
relay with a dish, and a viewfinder that is not a craft at all. Chris asked
whether the badge could do the job instead, and it is the better answer for a
reason none of the four can match. It is the only mark in this game whose
subject is the pilot rather than the ship, and this is the only stop on the
carousel whose subject is the pilot rather than the ship. `pilot_mark`'s own
comment had already said a badge is what a seat is issued rather than what
sits in it, and [spectating.md](../design/spectating.md) opens by calling a
watcher a connection with a seat in the roster and no ship in the simulation.
Both sentences are about the seat.

The gray is the same argument in paint. A hull on this carousel is drawn in
`pal.FRIEND` because the ship you turn to is the ship you fly; a watcher flies
nothing and holds no side, so the badge is drawn in the ink the interface uses
for everything that describes rather than belongs to you. The name under it
stays blue, because the stop is still the one you are standing on.

The recut is a separate fault, found by drawing the mark eight times its own
size to look at it. Three feathers at 32.1, 28.3 and 30.8 degrees are close
enough to look like a mistake and far enough to lose the even gap the roots
were cut for, and that is wrong at any size. Parallel turned out to cost
nothing: run each one out to the line the old tips already lay on and the
bottom feather lands within a thousandth of where it was, the middle one
within two hundredths. Both ends are cut on a line now, the tips on that rake
and the roots on the hull's own leading edge, which is what the roots were
placed against in the first place, so the wing is one band with a clean edge
either side and the same gap behind every feather. The taper is what gives a
feather a direction where a constant width is a bar, and round caps are what
made three of them read as three sausages at any size worth looking at.

**Cost:** the recut changes the mark everywhere and pays off in one place.
Three of the four callers draw it at ten or eleven points, where the widths
are both on the floor `pen` already puts under a stroke, nine tenths of a
point, and the mark comes out where it always did. The taper only says
anything from about twenty up, which since
[decision 128](#128-the-ship-is-a-row-and-says-nothing) put the carousel in an
ordinary row is the carousel alone. A wider change than its payoff, and the
payoff is the page this decision is about.

Six drawings rather than six strokes is six `quad` calls where there were six
`seg` calls, in a function that was already drawing its hull with `quad`
twice. The shapes are rebuilt when a caller asks for a width the last one did
not, which in a frame is at most twice, since the nameplates draw at ten and
everything else at eleven.

An eighth entry in `world.HULLS` would have been the other way to fill the
hole, and it is a crash rather than a ship: `TAIL` walks that list and reads
`.jets` off every entry, and a badge has no engines.

**Verified:** the client's suite, with `marks_test` rewritten around the new
grammar and `landing_test` grown three arms on the spectate page. The wings
finder now identifies the mark by six shapes lying along one angle rather than
by six round-capped strokes, which is the property the recut was for, and it
asks that the six agree within a degree, that each widens on its way out, and
that the three a side still arrive apart. The landing asks that the page draws
nine shapes where a hull would go, at the width of the circle a hull is drawn
in, and that its span does not move between two points of the turn. Both were
made to fail by perturbing the angle and by handing the row a turn.

Writing the finder turned up a measuring trap worth recording. Taking a band's
two shortest edges as its ends is wrong at eleven points, where the shortest
feather is barely longer than it is wide and its slanted end cuts make one of
its sides the shortest edge of the run: read that way it answered six degrees
where its neighbors answered thirty, which looks exactly like a drawing fault.
The sides are the opposite pair that lie parallel.

The shipped cut was read back out of the client through the test harness and
checked against the board Chris picked from: the angle, both end widths and
all three lengths agree to a thousandth of a mark unit. luacheck clean.

---

## 136. A ship is one thing, and changing it costs a respawn

**Status:** accepted

**What:** the ship menu the landing opens is the ship menu the in-match column
opens. `SHIP` joins the column as a stop, and a pilot in a room reads the same
five parts over the same purse they read on the front page. Editing it in a
match is a draft: the carousel turns and credits move without a single message
leaving the client, and the whole ship is settled once, when the panel closes.

A ship is the hull and the build together, so both are gated the same way. The
core's `sim_set_ship_class` compares the fitted row as well as the hull: asking
for the ship you are flying still costs nothing, and anything else needs a full
bar and pays a respawn, whether what moved is the body or a charge. The server
routes a build from a pilot in the air through that gate and deals one to a
benched seat in place, which is how a build still arrives with somebody who
joined during a podium.

`LEAVE SEAT` is gone, and so is `SPECTATE` at the end of the ship roster. They
were the same act reached two ways, and what replaces the stop is the games
list the landing already opens: leaving is choosing where to be instead, and
picking the game you are in lands you in its stands, which is what the old
answer did. The column is `ZONE`, `SHIP`, `SETTINGS`, `SIDE`.

That takes the page decision 135 had just finished drawing, which was decided
in parallel and landed first. The badge on it was the right answer to the
question 135 was asked, and the recut feathers it brought are kept, since they
are the badge wherever it is drawn; what goes is the page, because the act
behind it goes. Chris asked for that twice.

**Why:** the ship page was a front-page screen. A pilot who wanted a different
hull three minutes into a match had to leave the game to get one, and a pilot
who wanted a different build had to leave and come back. Everything needed to
edit one mid-match was already on the glass; it was reachable from one screen
only.

Drafting rather than sending is the part worth defending. Every other panel in
this menu applies as it is read, and this one cannot: turning the carousel from
an Apex to a Lattice is six steps, and six ship changes is six respawns, one
per arrow. So the panel edits a copy, its head says what closing it will do,
and closing it is the one act. Nothing pauses while it is up, so a pilot can be
shot for reading it and the close is refused; the refusal names itself in the
feed rather than dropping the work in silence.

Sitting yourself down was reachable from two places and worth neither. A
watcher of the room you hold a seat in is a state with nothing to do in it and
one key out of it, and the ship menu could reach it by turning one page too far
off the end of the roster. The front page is the stands already, and the zone
stop is how you pick which game you are watching.

**Cost:** the wire is unmoved: `C2S_KIT` already carried a hull and a row, and
it is now the whole of a ship change. Between matches everybody is benched at
zero energy, so the gate refuses a change during a podium and the note says so;
that was already true of a hull change and is now true of a build.

A build dealt to a seat that is not in the air is dealt in place, which means a
dead pilot can respec on the way back for the price of the death they have
already paid. That is the same hole the ungated deal had and it is strictly
smaller; closing it would take the between-matches case with it.

**Verified:** `make -C sim check` with two new core cases, one holding that a
build changed under the same hull is gated and respawns and one that handing
back the row already on the ship is free. The golden is unmoved, since the
determinism trace never changes a ship. 463 server tests including the in-air
and benched arms of `Room::set_ship_kit`, clippy and fmt. The client's suite
with the draft, the panel in the column, the walk through it, the way back out
of a part of the ship, and every arm of `settle_ship`; luacheck clean. And the
playtest harness plays it: a new `ship-change` journey boots the real client
against a real fleet, opens the menu mid-match, turns the carousel, checks the
room has not moved the pilot, closes the panel, and waits for the server to put
them in the hull they built. It passes on all four device profiles.

---

## 137. Loopweld LLC is the licensor

**Status:** accepted

Decision 18 picked PolyForm Noncommercial 1.0.0 and then said "the project"
wherever it meant the party granting the license. PolyForm does not work that
way: its Notices section makes anyone who passes on a copy also pass on the
`Required Notice:` lines "that the licensor provided", and there were none. So
the file granted rights on behalf of nobody in particular, and nobody in
particular could enforce it or waive it.

Copyright is held by Loopweld LLC. The notice sits at the top of `LICENSE.md`,
which is where PolyForm looks for it and where a fork carries it away, and the
terms page says the same for the hosted service.

An entity rather than a person, because decision 18 already assumes one: the
CLA it wants needs a party for contributors to sign with, and the commercial
release it protects needs a party to sell. Both are worse to retrofit than to
name now, before there is a contributor or a buyer to renegotiate with.

**Cost:** for a few hours the site named two parties, since the terms still
made their agreement with Chris. [Decision 139](#139-the-site-speaks-as-the-company)
closed that.

**Reconsider if:** counsel wants a different entity to hold the game separately
from the code.

---

## 138. A duel is too small to hold a wormhole

**Status:** accepted

**What:** `allow_wormholes` in a map brief is an instruction and not only a
check. A brief that refuses one gets its theme's pattern with the mouth left
out and everything else on the tile it was already on. Eddy and gimbal are
regenerated that way, so no map in the duel rotation warps.

**Why:** a wormhole sends the ship that touches it back to its own start, and
its field reaches thirty-eight tiles. That reach was set against the match
maps, which are a hundred and sixty tiles across. The duel's are ninety-six.
Eddy's mouth sits on the middle of the map and half its tiles are inside the
field; gimbal has two mouths fifty-five tiles apart, and nearly three quarters
of its tiles are. A well that covers the room is weather rather than somewhere
a pilot chooses to go, which is the reading
[decision 125](#125-a-wormhole-you-can-still-fly-out-of) cut the pull to get
away from.

What the warp does to the game is worse than what it does to the ground. This
zone exists because two pilots on melee ground spend the round looking for each
other, and ninety-six tiles is close enough that the fight starts at the
whistle and restarts after every death. Touching a warp puts you back on your
own start with the map between you again. On a melee map that costs part of a
twelve to fifteen second crossing; here it undoes the one thing the small map
was for.

**Cost:** both maps score lower against their own theme, and the score is right
to say so. A fifth of the nebula's fidelity mark rides on its wormholes and a
tenth of the rings', so eddy falls from 96 to 92 and gimbal from 84 to 82. Eddy
is a spiral nebula with nothing at the middle of it now, and the rock collar
drawn to give the mouth four approaches is a ring around an empty pocket. It is
still the middle of the map, which is most of what it was worth to a fight.

Nothing else moves. The refusal is taken at the mouth rather than by choosing
another theme or another seed, and a mouth's clearing is reserved whether or
not the mouth is laid, so every rock, wall, door and star on both maps is on
the tile it was on. Both hashes move and both recipes are re-pinned.

Doors are still checked rather than obeyed. A brief that refuses them on a
theme that draws them is rejected at the gate, because nothing has wanted the
other answer yet.

**Reconsider if:** a duel map is drawn big enough that a well is a landmark
again. Nothing about the format stops one; the flag is per map, and sconce
already refused a warp before this by being drawn from a theme that has none.

**Verified:** `mapforge verify` on all twenty recipes in the catalog: the two
regenerated maps against their new hashes, and the other eighteen unmoved.
Read out of the packed files rather than out of the generator's own report,
eddy and gimbal each differ from the map they shipped as in exactly two tiles,
both of them a wormhole that is now empty, and sconce in none. Their metrics
move only where that can move them: the hash, the landmark count, and the
fidelity term the missing mouths were worth.

485 server tests. One is new and holds that a theme's warp is left out for a
brief that refuses one while every other tile stays where it was, and the
rotation test now pins all fourteen version 2 maps in the catalog rather than
the five in melee, so the turf and war rooms are held to their recipes too.
clippy and fmt.

---

## 139. The site speaks as the company

**Status:** accepted

Decision 137 put the copyright on Loopweld LLC and stopped there. The terms
still made their agreement with Chris, and the clause limiting liability still
limited his. A company that holds the rights while a person signs the contract
absorbs nothing, which is the one thing it was formed to do. So the operator on
the terms page is Loopweld LLC, and the privacy notice names it as the party
deciding what the service keeps.

The privacy notice needed more than a swapped name. Its section headed "Who runs
Vectorwake" never said who: it listed the sites the notice covers and pointed at
support. `docs/launch/legal-review.md` measures that notice against GDPR
Article 13, which asks first for the identity of the controller.

The founder letter is gone, at Chris's ask. It was the landing page's only
first person voice and its only mention of a person, and it named SubSpace,
which `docs/design/identity.md` had ruled out in marketing. The launch brief
carried that as a contradiction for counsel to settle, and removing the letter
settles it. Every footer now carries the copyright line. No page had one, and it
is the first place a reader looks for a holder.

**Cost:** the landing page loses its middle. It is the hero, then Features,
then the foot, and the letter's "Start playing now" was the only call to act
between the first and the last. The hero's button and the nav still lead to the
same places, so nothing is unreachable, but a page that used to say something in
a human voice now only lists what the game has.

Terms and privacy moved to an effective date of September 1, 2026, because
both pages say the date changes when they change and the party you are
contracting with is not a small change. The terms also promise to announce a
material change before it takes effect when practical, and no announcement has
gone out. That one is Chris's to post, not something a commit can do.

**Reconsider if:** the landing page wants a voice in the middle again, in which
case it is the company's and not a person's, and it does not name another game.

---

## 140. The baseline is what the fleet plays

**Status:** accepted

Five zone files each carried an `[arena]` block of about twenty settings, and
the four newest were Team Battle's copied across. Reading them against
`sim_settings_baseline` showed most of the copying bought nothing: ten of the
keys and the whole `[arena.mod_step]` table were already the core's own value,
restated. Only seven numbers ever differed from it, and every zone differed in
the same direction.

So the core baseline carries those seven now, and a zone file states what makes
it that zone. `bounce` and `friction` are 12, `respawn_delay` is 200,
`safe_limit` is 65535, `mod_spread` is five degrees, a bullet's spec holds 255
walls, and a burst does 515. What that leaves in the catalog is short: Duel is a
room shape, a map list and the clock, Turf and War add their flag rules, and
Free Roam, being the one game that is not a match, is the longest at two
overrides and its greens.

The mechanism did not change and nothing new was built. `apply_config` has
always reset to the baseline and overlaid what a file names, and
docs/architecture/catalog.md has always said that missing values keep the core
baseline. What changed is that the baseline is now the game rather than a
neutral reference nobody flies.

Verified rather than assumed: every one of the five zones packs byte-identical
settings before and after, which is the whole claim. The guard against it
drifting back is `every_shipped_zone_flies_the_same_ship`, which applies each
shipped zone, blanks the fields a zone is allowed to differ on, and fails if
what is left is not identical across the catalog.

**Cost:** tuning the house numbers is now a C edit, a regenerated golden and a
client rebuild, where it used to be a TOML edit that reloaded without a
restart. That is a real loss for a live tuning session and close to nothing for
how this fleet actually tunes, which is by commit. It also means a fork gets
our wall as its default, which is already true of the roster: the flight rows
in that file were solved off Team Battle measurements in decisions 123 and 126.

The other half of the cost is that the reasoning moved with the numbers. The
prose explaining why spray costs 25 and 50, why a fan is five degrees and not
fifteen, and why a burst is 515 now lives in `sim/src/baseline.c` beside the
values rather than in the zone file, and anybody looking for a setting's
argument has one place to look instead of five that agree.

**Reconsider if:** a zone genuinely wants a different game rather than a
different room, and the override blocks grow back to where the shared half is
worth pulling into a layer of its own. A defaults file under `catalog/` would
be the shape of that, layered between the core and a zone, and it is worth
building the day two zones disagree on tuning for a reason somebody can state.

---

## 141. In a duel, the door is the whistle

**Status:** accepted, extending
[decision 131](#131-a-duel-is-a-two-seat-zone-and-nothing-else).

**What:** a duel room opens a fresh match whenever a seat changes hands while
one is being played: whole clock, nothing on the board, both pilots home.
An arrival lands on the side across from whoever is already in the room.

**Why:** a player joined a duel and was shown a 5 to 0 loss at a whistle they
had done nothing to earn, with the bot they had been paired against listed on
their own side for the first few seconds. Every part of that was the melee's
rules doing what they say in a room they were not written for.

The duel zone fills to two bots, so an empty room is two bots fighting each
other on the match clock, and a person at the door takes one bot's seat in the
middle of that match. The seating rule puts an arrival on the emptiest side by
humans, and with none on either side the tie went to the first side, which was
as likely as not the surviving bot's. Then the ballast rule saw two heads
against none and moved the bot across once its bar was full, and the melee
score is a tally of the kills on the field by the side each ship is on now, so
the bot's five kills against the bot it had replaced crossed with it. The
clock ran out a minute later and the podium said what the tally said.

Landing the arrival across from the bot fixes the side, and it is a rule the
melee wanted anyway: heads of both kinds now break the tie that humans alone
cannot, so a person joining one bot lands opposite it rather than beside it
until the ballast moves. It does not fix the match. Whoever was in the room
before has been scoring against a seat that is now somebody else's, and in a
room whose whole match is those two seats, that score is about a fight that
is over. So the room starts the match again. The mode's clock learned to
reopen, which is the path a fresh room's first tick already takes, and a duel
room asks for it from the join.

Two limits. It is the duel's rule and nobody else's, decided by the shape the
zone file declares: one human a side on two sides. Team Battle keeps letting a
late arrival into the match being played, since eight seats are not two and a
match that restarted every time a seat changed hands there would never
finish. And it happens only while playing. With the podium up the next match
opens on its own inside fifteen seconds, and an arrival joins the wait as
everybody else does.

The client hears it. Its whistle hung on the edge from a podium into a match,
so a match started over mid-play would have moved the clock to three minutes
in silence and the ending would have read the pilot's rating from a latch two
fights old. The arena's clock never goes back up inside a match otherwise, so
that jump is the signal: the match message marks itself, the clock rule blows
the whistle once and spends the mark, and the ratings latch again.

**Cost:** a pilot whose rival quits keeps a lead over nobody until the bot
arrives, and loses it when the bot does, because that arrival is a seat
changing hands too. Their kills are already rated; what goes is a podium
against an empty chair. Bot on bot in an empty duel room goes on as before,
and a room's first person still evicts one; that is harmless now that the
match they walk into is their own.

**Verified:** server tests for the clock reopening from a running score, for
the arrival landing across from the bot that stays whichever bot is evicted,
for the fresh match a duel opens on a join with every tally at zero and a
whole clock, for an arrival during the podium waiting for the next match, and
for a melee arrival landing opposite a lone bot. Client tests for the whistle
on a marked message, once, and for the wire latching ratings again when the
clock goes back up.

**Reconsider if:** the restart is what players wait on rather than what they
came for: a rival who leaves and returns restarts the match twice, and a room
that sees that often wants a grace period rather than a whistle.

---

## 142. A duel is rounds, and two of them take it

**Status:** accepted, amending
[decision 131](#131-a-duel-is-a-two-seat-zone-and-nothing-else) and
[decision 141](#141-in-a-duel-the-door-is-the-whistle), and reinstating the
round rule from
[decision 92](#92-duel-is-two-pilots-and-the-door-decides-which-two) that
[decision 96](#96-duels-are-gone) removed.

**What:** the duel zone runs a mode of its own. A death ends the round rather
than the match. Two seconds later both pilots are back on their own starts
with a full bar and a full rack. The first side to two rounds with nobody
level takes the match; level at two plays on. The three minute clock stays as
the backstop, where the leader takes it and level is a draw.

**Why:** asked for. Decision 131 brought the duel back as melee in a two seat
room and said plainly that the maps were the only thing making it a zone.
That left a 1v1 scored as a three minute kills tally, which is Team Battle's
answer to a question the duel does not ask. A duel is one fight with a winner,
and the word carries that expectation before a player has read anything.

Two rounds rather than one, which is the part worth arguing. The old duel was
first to a single death and the record of what that cost is still here.
Decision 90 had to hold a decided fight open for two seconds because a bomb
already in the air scored a trade as a clean win. Decision 74 found the MVP
mark meaningless, since in a first-to-one duel the winner is the only pilot
with a kill. And the roster sweep measured 1v1 draws at 27 to 37 percent in
the low skill band, in a pit built so neither pilot can avoid the other; most
of this population is that band. Rounds absorb all three. A freak trade costs
one round instead of the match, and losing the opening exchange leaves a pilot
one round from level rather than watching out a decided fight, which is the
best thing that happens in a duel and the thing first blood has none of.

Two rather than three or five because a round is fight time plus two seconds
and nobody has measured fight time on this ground yet. Two is three rounds at
most, which fits inside the clock at any plausible round length. Five could
run to nine rounds and would mostly end on the whistle, which would make the
backstop the referee. It is one line in the zone file when there is a number
to move it to.

The score is rounds taken, read off the other side's deaths rather than off
your own kills. Both cases a player has an opinion about come out right that
way: fly into a wall and the round goes across the arena instead of coming off
your own tally, and a trade gives one each. A kills tally answers neither, and
in a two seat room that was the whole scoreboard.

The two second window is the trade rule and it is the respawn delay, which
every zone in the catalog already runs at 200 ticks. So a bomb thrown by a
pilot who is already dead still lands, still kills, and the round goes to both
sides, and the loser is still down when the round is filed. Decision 90 needed
a rule for that. Here it falls out of a constant that was there anyway.

Racks refill every round. Keeping them across a match makes spending a repel
in round one a real decision, which is interesting, and it is invisible: the
charge is simply not there and nothing on the screen says why. A round is a
fresh fight or it is not one.

**Cost:** a fourth mode, about a hundred lines, and one new `ModeCtx` flag.
The flag earns itself by being the thing `open_match` must not be: a match
start zeroes every tally in the room, and here the tallies are the score, so
the round reset writes no kill and no death. It benches both pilots with a
respawn one tick out and lets the core's own spawn path pick the starts and
fill the bars, which is why a pilot arriving for round two lands exactly where
one arriving after a death does.

The catalog moves to v41, because `ZoneDef` denies unknown fields and the zone
file gains `first_to`. An arena on the old build refuses the offer whole and
holds nothing, which is what `take_catalog` is built to do with a catalog it
cannot read. Nothing else moves: no protocol, no `CFG_VERSION`, no golden. The
client already draws two numbers a side in the band, already writes "Rival
takes it, 2 to 0" on the ending, and reads the banner off the wire, so it
needed no change at all.

Rating is untouched and this decision does not improve it. Rating settles per
death with damage split by contribution, so the match result was decorative
before and still is. This is about how the room reads.

**Verified:** 499 server tests, clippy and fmt clean, the client suite and
luacheck clean. Eight on the mode: a death ending the round and the round
going to the other side, a trade inside the window giving both sides one, two
rounds taking the match, level at the target playing on to three-two, the
whistle giving it to whoever leads and calling level a draw, a death on the
whistle scoring without opening a round under the podium, a fresh match
forgetting both the rounds and an open window, and a self kill handing the
round across. Two on the room: the reset clearing the air and re-dealing the
rack while leaving every tally alone, and a duel played through the room in
rounds into a podium.

**Reconsider if:** rounds turn out to run long enough that two is a short
match, at which point the number moves rather than the rule. The harness
already flies 1v1 legs to a death and records ticks per leg, so pointing it at
the three duel maps is what settles it.

---

## 143. One menu

**Status:** accepted

**What:** the landing and the in-match column are one menu. Four stops,
`ACCOUNT`, `ZONE`, `SHIP`, `SETTINGS`, over one key, drawn by one function off
one view, in the same order wherever it stands. `SIDE` leaves the column.

The key reads where this client is sitting rather than which screen it is on.
No seat anywhere, on the front page or on a bench, and it says `PLAY` and is
the way into one; a seat of your own and it says `SPECTATE`, hands the hull
back over `C2S_WATCH`, and leaves this pilot watching the room they were in
from its own gallery. `RESUME` is gone: escape, the menu key, or a press on
the glass beside the column put it away in a match, which is what a press
beside a panel means everywhere else here.

`home` is the one thing left that the two places disagree about, and it is
about the screen rather than about the menu. Out there the column is the whole
front end, so it carries the lockup, washes nothing behind it, and cannot be
dismissed, because dismissing it would leave somebody looking at a starfield
with no way back. In a match it is a panel raised over a fight.

**Why:** they were the same drawing already. `land_stop`, `land_list`,
`land_panel`, `panel_frame` and `commit_key` drew both, and the second
geometry was written as "the same stops at the same width over the same
breathing key" as the first. What they did not share was the model, and two
models drift: the landing grew `ACCOUNT` and the column grew `SETTINGS`, so
where a thing lived depended on whether you had taken a seat yet. A pilot who
learned the front page arrived in a room and found the settings somewhere else
and their account nowhere.

It cost more than a stop apiece. Two keyboard walks, one a written list of
four named controls and the other a filter over everything published, which
disagreed about whether a row was reachable before its list had arrived. Two
sets of actions for one press, so eight branches in `arena.script` where four
would do. Two pieces of state saying which stop was open, `ui.col_open` and
`menu.stack`, kept in step by hand. `landing_test` and `column_test` each
checking half of one object.

Sitting yourself down comes back, which decision 136 removed and Chris asked
for twice. What 136 removed was a `LEAVE SEAT` stop with two different answers
and a `SPECTATE` row at the end of the ship roster: the same act reached two
ways, one of them by turning a carousel one page too far. This is neither. It
is the state the column already reports, on the one control that reports state,
and the act it performs is the one the zone list already performed when you
picked the game you were in. It is a better version of that act: the room, the
map, the roster and the delayed channel all stay, where leaving for the stands
tore the session down and dialed it again.

`SIDE` goes because crossing to another team is a thing you do about the room
you are in rather than about yourself, and the room is about to be rebuilt: the
scoreboard and the zone and arena lists are next, and a side belongs beside
them. `team_rows`, `NODES.side` and the `team` and `found` acts go with the
stop rather than sitting unreachable until then.

**Cost:** the fourth stop does not fit the rail. On a short window the landing
lies its column down into cells beside the key, and four of them at 320 points
came to 67 points each, which holds neither a call sign nor a game's name. The
rail takes a floor now: one line where the window can hold every cell at 96
points, and a grid of two otherwise. A landscape phone that used to get one
band along the foot gets two rows of two.

The wire is unmoved. `C2S_WATCH` has been in the protocol since before decision
136 and the server still answers it, gate and all: a wounded pilot keeps their
hull, a full gallery refuses, and the next welcome is the answer. Nothing in
`sim/` moved and no golden was regenerated.

**Verified:** the client's suite, with `landing_test` rewritten to drive the
one column through `ui.menu` on all four windows, `column_test` and
`menu_language_test` retargeted at the four stops, and `menu_test` holding the
new model: the same stops at home, on a bench and in a seat, the key naming
`play` or `spectate` off `menu.flying`, and the account acts pressed as rows of
the tree. luacheck clean over 107 files. The playtest harness plays it:
`arrive` presses `menu_go` with whichever hand the profile has, and
`ship-change` walks the column into the ship panel and back.

**Reconsider if:** the front page wants something the column cannot hold. It is
four stops and a key at a phone's measure, and the argument for docking it
there (decision 63) was that a phone held upright gives it the whole window.
A fifth stop is the number to watch.

## 144. A bomb ends where the zone says it did

**Status:** accepted

Chris filmed his own bomb going off the moment it left the tube and then
flying on to where it really landed. Decision 40 had made remote deaths the
zone's to conclude, and the fuse followed it in the client's proximity fix,
but contact was left predicted on purpose: a round has to reach the hull, and
the spark of a bullet landing is what makes a gun feel immediate. That was
right about bullets and wrong about bombs. A remote hull on a client is a
coasted guess, a bot's steering flips its buttons many times a second, and a
bomb thrown in a close fight crosses that guess within a few ticks of leaving.
The client's core ended the round on a hull that was not there, drew the blast
at the muzzle, and the next snapshot handed the bomb back.

So a deathless instance now lands a thrown round on its own pilot's hull and on
walls, and flies it through anybody else: `sim_step` skips the contact test for
a round with a blast against any hull `may_settle` refuses, the same gate the
fuse already sat behind. Bullets keep landing on contact, for the reason the
old test gave. The ending reaches the client as the round leaving a snapshot,
which `harvest_world` was already turning into light and sound for the fuse
case, so every bomb ending on somebody else takes one road now.

The second half is the name a round wears on that road. The client named a
round across snapshots by its owner, its spec and the tick it was fired on,
worked back from the life it had left. A repel gives a round its whole life
again, so a bomb an enemy batted back came out of the next snapshot with a
birth seconds later than the client knew, and the old name was simply gone
from a snapshot that had vouched for it. The harvest read that as the bomb
detonating where it had been, and the pilot watched their bomb explode and
then fly back past its own blast. A round carries a two byte `id` now, dealt
from a counter in the state at the spawn, and the counter rides ahead of the
records so a client's predicted rounds continue the zone's numbering rather
than reusing a name a round in the snapshot holds.

**Cost:** a direct hit on somebody else is drawn a snapshot late, the way a
kill already is, and where the client can best put it rather than exactly
where it landed. The harvest draws the blast where the round was on the tick
the snapshot describes, walked back along its own velocity from where the
capture found it, because the zone had ended it by then and that is the
furthest it can have reached. That is at most a snapshot interval of flight
past the hull, where it used to be a lead's flight past it on the fuse road.
The wire grows two bytes a round plus two a snapshot; `CLIENT_PROTOCOL` is 35,
the whole-state pack bound is 65638, and the golden hashes moved because the
hash covers what the wire carries.

**Reconsider if:** the late blast reads as a miss in play, in which case the
harvest knows the last coasted position of every enemy hull and could pin the
blast to the one the round's flight crossed, as the expire event already pins
a landed hit to its victim. Or if bullets start drawing hits the zone takes
back often enough to notice, which would be the same fix one weapon over.

## 145. Say the game's name, and say the rest once

**Status:** accepted

Three notes from Chris, all of them the interface saying either the wrong
thing or too much of it.

**The flag game is Capture the Flag.** It shipped as War, after the original's
War Zone, which is where the mode key `warzone` and the zone key `war` come
from. Nobody calls the game that. A player reading a list of five games knows
what Capture the Flag is before they read the format strip beside it, and has
to be told what War is. One line does it, the label in
`catalog/zones/war/zone.toml`: the key stays `war`, because a key is what a
join, a room and every rating already written are filed under, and
`Catalog::zone_label` exists exactly so the two can differ. Team Battle has
been keyed `melee` since decision 129 for the same reason.

The new name is five letters longer than the longest the catalog held, which
found a cell that could not take it. The landing lies down into a rail on a
short window, and a rail cell is 120 points wide: eleven point type wanted 106
of the 104 inside one, so a landscape phone drew "Capture the Fla". The answer
in a rail cell now takes whatever size fits it, floored at nine points, which
is the rule `land_stop` already claimed to follow. `landing_test` pins a long
name arriving whole on all four window shapes rather than pinning the size,
since the next zone name is the one that will find this again.

**Settings is one run of rows.** It banded them under small ticked labels:
audio over sound and music, video over frames and fullscreen, the machine over
controls and about. Six settings are not enough of a page to want chapters. The
headings said what the rows under them already said, and three bands of
twenty-four points over six rows of forty-four spent a fifth of the panel
saying nothing, on the page a phone has the least room for.

**A phone is not offered the controls board.** There is no key to bind on
glass, so the page fell back to naming the pads: "the big pad on the right",
"left thumb: point where you want the nose". That is a caption for controls the
reader is holding while they read it. Every pad draws the weapon it fires, and
the one gesture a mark cannot carry, the double tap that reverses, is written
around the stick's own rim by `arena/touch.lua` while you fly. The `pad`
sentences in `arena/controls.lua` went with the row, since nothing else read
them.

**Cost:** the label rides the directory's reply, so the name changes with a
catalog publish (version 42) rather than with a client build, and a page
already open takes it on the next browse. Ratings written under `war` keep that
key forever, so anything that reads a class straight out of the database and
prints it says `war`; everything a player sees goes through `zone_label`.

Decision 88 listed the controls page as the one place the reverse gesture was
named. That was true when it was written and is not now: the stick hint landed
after it, says the same thing in two words, and says it under the thumb it is
about, wherever the stick is drawn.

**Reconsider if:** a phone player cannot find something a pad does not draw.
The answer then is on the control rather than in a page about the controls,
the way the stick's rim already answers reverse.
---

## 146. A duel is one kill, and the room deals you a rival

**Status:** accepted, moving the number
[decision 142](#142-a-duel-is-rounds-and-two-of-them-take-it) set and
extending [decision 131](#131-a-duel-is-a-two-seat-zone-and-nothing-else).

**What:** three things, one shape. A duel match is one clean kill rather than
two rounds. A pilot flying against somebody is replaced after three matches, or
at once where it never suited them. And the replacement is chosen for the room
rather than being the next free name on a list.

**Why:** asked for, after a card that said `Pilot TAKES IT` over a rating of
minus twenty-two. Both halves of that turned out to be the same problem seen
from two ends.

The rating was arithmetic. Rating settles per death against the opponent in
front of you, and the opponent was a fill bot two hundred points below. Elo
pays for surprise, so each kill was worth a quarter of the pilot's K and the
one death three quarters of it. Nothing is wrong there. What was wrong is that
the opponent had been the same pilot all evening, chosen because `claim` walked
the pool from index zero and handed back the lowest free individual every time.
A duel room never releases its seat at a whistle, a lone arrival always lands in
the room the fill ladder kept, and between them a session was one opponent.

That also flattens the measurement, which is the part that makes it a bug
rather than a preference. Repeat dampening discounts a kill on the same person
by `1/(1+n)` and holds the count for five minutes past the last one, so
back-to-back matches against one seat run at 1, then a half, then a third. By
the fifth the ending card has stopped moving with the play.

So the room learns who is in it and asks for somebody worth fighting. The
population director already had every part of this and was using none of them:
a bot parses the roster it is sent, which carries every seat's rating and
whether it is a machine, so a connection inside a room can see who it is
across from. That observation goes back to the director on the same handle its
stand-down flag rides. Nothing new is published and no wire moves.

Which is deliberate, and it is why the band does not live on `BotRequest`.
That struct rides `status_json`, which `C2S_STATUS` answers to anybody who asks
without joining, so a competence band on it would publish a readout of whoever
is in the room. Choosing the rival from inside the process also keeps the
choice off the one input a client controls: a client picks its room at join, so
a rival dealt on arrival would make leaving and rejoining a reroll, and the
direction that pays is rolling for an opponent rated far above you. The swap is
on the room's clock instead.

The band itself is a designed table of five rows, one per tier, on
`ordering_prior`, which is the roster's own strength order and deliberately not
a rating. There is nothing checked in to derive it from: the generated pool has
no calibrated prior and only a powered report can produce one. So it is written
down where a designer can move it, the rows are the tiers from `rating.rs`, and
a test fails if the two lists drift apart. The rows overlap by design, because a
band is where to look rather than a bracket to be sorted into.

One kill rather than two rounds is the last piece and the one that makes the
rest work: a match is the unit a rival is dealt on, so a short match is how a
pilot meets more than one opponent in an evening.

Decision 142 argued for two, and its strongest argument no longer holds. It
worried that a freak trade would take a first-blood match, which decision 90 had
to hold a fight open for two seconds to prevent. `Duel::decided` wants a leader
and not a number, so a trade gives both sides a round, neither leads, and the
match plays on to two-one whatever `first_to` says. The rule that absorbs the
trade is the trade window, not the round count.

What is genuinely lost is the second thing 142 wanted: a pilot who loses the
opening exchange is no longer one round from level. They are in the next match
instead, which is a different answer to the same discomfort and now a much
shorter wait.

**Cost:** the podium is a bigger share of the loop. Fifteen seconds of ending
after a fight that may be thirty is a lot more waiting than fifteen after two
minutes, and the number is not moved here because nobody has measured a fight
on this ground. The harness flies 1v1 legs to a death and records ticks per
leg, which is what settles it.

A swap costs the room a pilot for about a second. The outgoing one leaves at the
intermission, which is the departure a yielding bot already takes rather than
the forty second graceful walk, and the replacement is claimed on the next
director cycle. That lands inside the fifteen second podium, so the seat is full
again before the whistle and decision 141 never fires. If the claim were ever
slow enough to miss it, the arrival would restart the match, which is
141 working as designed and reads as an unlucky whistle.

The churn guard had to learn the difference. It holds refill for thirty seconds
after any stand-down, which is right for a person joining and leaving and wrong
for a seat changing occupant on purpose, and it is keyed to the whole instance,
so one duel room rotating would have stalled twenty. A pilot leaving to be
replaced now keeps filling its request until it is actually gone, so the room is
never counted short and the guard never fires.

The authored roster is still dealt first and in order. Only the generated pool
is entered at random, which keeps the pinned anchor in the air: it holds the
ladder's whole scale and does that by fighting rather than by being written
down.

The catalog moves to v43, because the zone file's `first_to` changed and a
games list prints it. A duel to one round says `first kill` on the strip rather
than `first to 1`, which is arithmetic a player would have to finish.

**Verified:** 511 server tests, clippy and fmt clean. Two on the mode: one
clean kill taking the match, and a trade at one round each playing on to
two-one. Six on the director: the tiers and the bands naming the same five
things in the same order, a band following its rival's tier, a banded claim
landing inside the band it asked for, a claim skipping the pilots a room has
just had, a pilot leaving to be replaced leaving its room neither short nor
over-full, and the rival being the best person in a room and never a machine.

**Reconsider if:** three matches is the wrong cadence. It is set where repeat
dampening has halved what a kill is worth, which is a fact about the rating
layer rather than about how long it is interesting to fight somebody, and those
two numbers have no reason to be the same one. Or if the bands turn out to
matter less than the archetype does, in which case what a room should ask for is
a pilot who fights differently from the last one rather than one who fights as
well.

---

## 147. The players sheet is the menu's, and the band says who won

**Status:** accepted, superseding
[decision 67](#67-the-scoreboard-is-a-band-you-press) below the band and
[decision 68](#68-the-match-ending-is-the-board) entirely, and amending
[decision 94](#94-the-ending-has-no-foot-and-the-clock-never-moves) and
[decision 143](#143-one-menu)

**What:** the scoreboard, the roster, the pilot box, the side picker and the
match ending are one panel, and that panel is a stop of the menu. `PLAYERS`
sits between `ZONE` and `SHIP`, and its answer is where you stand: the side
you fly for by the name the zone gave it, or `watching`. The band opens it,
the key that opened the old board opens it, and at the whistle the arena
raises it the way a hand would.

It is one flat list. Every player in the room gets a row: their name in their
side's color, the seat's mark after it, then the side in a `TEAM` column and
the figures the zone counts. Your own side runs first, then everyone else,
then the watchers, each of those three by name. A watcher is a row like any
other, with `Watching` where a side would be and zeros for figures, so the
list has no divider in it. The band above carries the score and the Team
column names every side, so the sheet says neither again.

A press on a row opens that pilot's card, which is a panel that stacked: the
pilot's name in their color on the head, rows reading their side, what the
zone vouches for the seat as, where the ladder has them and what they have
done this match, and one breathing key at the foot, `JOIN <side>`. That is how
a side is joined now. On your own side's pilot, on yourself and on a watcher
there is no key; on a side the zone will not take you into, the foot says so
instead of drawing a key that would be refused.

At the whistle the sheet gains one column, what the match paid each pilot, and
nothing else. Who took the match is the band's to say: both sides stay on it,
the winner at its own strength and the beaten side stood down to a third, over
the clock counting to the next one. A draw stands neither down.

**Why:** asked for, over four rounds of drawings in `.design/one-board` and
`.design/scoreboard-sheet`, and the ask each time was the same one from a
different angle. Five things on the glass were about who is in the room and
how it is going, and they were five drawings: a band, a 340-point column under
it with four pressable headings, a box that opened under a pressed row, a side
list that had been sitting outside the menu since decision 143, and an ending
block that zoomed the column 1.45 times over a wash of the whole window.

Nothing about that was one object. The board had its own column, its own
scroll, its own wash, its own row height and its own sort; the ending had a
second copy of all of it at a second size; the pilot box had a third. Three
panels, three geometries, three sets of state to keep in step, all of them
saying things about the same room. The menu had already solved this once, for
the zone list and the ship and the settings, and decision 104 wrote down what
the answer looked like: one glass, one head, rows at the touch floor, a panel
that stacked. The room is a list. This is that list, in that language.

What falls out of moving it there is most of the work. Escape walks out of it
because escape walks out of every panel. The arrows walk its rows because they
walk every panel's rows. A thumb drags it and a wheel scrolls it because the
menu's own page already answers both. A press on a row opens a stacked panel
because that is what a press on a row does. Four hundred lines of drawing and
a dozen pieces of state went, and the two controls that stepped a selection
through the roster went with them: Page Up and Page Down were an arrow walk
written a second time for one panel.

The Team column is what made the flattening possible, and it is the change
Chris asked for that carries the rest. Sections grouped by side meant a side's
head was a row that was also a control, which the language had no name for and
would have had to grow one. A column that names the side on every row says the
same thing without a new shape, orders the list by something other than the
grouping, and works in the two zones grouping never did: a duel, where a side
is one pilot, and Free Roam, where eight sides cannot be told apart by color.

The ending is the part with the longest argument behind it, and it ends up
where decision 68 was heading. That decision made the ending the board with a
head over it; decision 94 took the foot off; this takes the head off too. What
is left is the board, which is the sheet, which is a panel a player can already
open. The head was a line naming the winner and a bar carrying the score, and
both were readings the band had been making for three minutes in the same
pixels. So the band makes them for one minute longer, by standing the beaten
side down, and the whistle stops being a screen with a layout of its own.

The stop is the fifth, which decision 143 named as the number to watch, and it
is the one thing this column does not say the same way in both places: there
is no players stop at home. Decision 108 took the instruments of a room nobody
is in off the front page, and a roster is the clearest example of one. That
makes the front page four stops and a room five, which is a real cost and the
right one: the alternative is a stop that opens a list of strangers a stranger
has no business in.

**Cost:** a side with nobody on it cannot be joined, because there is no row to
press. That is a real hole in Free Roam, where founding a side is a thing
players do, and it needs a door of its own. It was already true in a narrower
way, since the side list decision 102 drew never had a found key either.

The sheet is a panel over the fight, so reading it takes the screen the way
every other panel does. The board it replaces was a 340-point column with the
arena visible around it. Nothing pauses either way, and the band and the dial
still read over the top of it, which is the bargain decision 102 struck.

Page Up and Page Down are unbound. A pilot who had moved them onto something
else keeps that; a pilot who had left them where they were has two free keys.

**Verified:** the client's suite, with `players_test` written for the sheet in
place of `podium_test` (the block it tested no longer exists): the order, the
Team column and its case, a private side that is not named, the card and its
three states, the rating column at the whistle, and an upright phone giving up
assists rather than the column that names the side. `band_test` holds the
band's new whistle, `side_col_test` follows the sheet, and `hud_hits_test`,
`landing_test`, `marks_test`, `menu_test`, `binds_test` and `column_test` move
with it. luacheck clean over 108 files.

---

## 148. A banking hull shades the wing it drops

**Status:** accepted

**What:** a hull's bank grades the light across its beam. The wing that drops
turns away and loses most of what it had, the wing that comes up gains a
little, and every point between them is graded by how far out along the beam
it sits. At the full bank the client allows, 0.95 radians, the low wingtip
draws at 0.33 of what it would flat and the high one at 1.24.

Lit surfaces only: the body's wash, the plates and panel lines, the
silhouette's hot edge and both of the bloom skirts hanging off it. The
thruster flame, the muzzles, the lamps and the canopy do not take it, being
lights rather than lit. Neither does the round bloom under the hull, which is
one soft ball centered on the ship, and lopsiding it would move the ship
rather than shade it. The opaque base stays flat too: it is a hole in the
starfield rather than a surface with a lit side.

The grade is on alpha and never on hue.

**Why:** the bank has always been a cosine on local x, which foreshortens the
wings and moves nothing else. That is the right projection of a roll seen from
above, and it is also the same number left or right. A hull rolled hard one
way therefore drew exactly like one rolled hard the other, and with nothing
breaking the symmetry the eye reads a hull that got thinner rather than one
that tipped. The sine of that same angle is what says which wing went down,
and shading is the only thing on the ship that can carry it.

Four to one across the beam is more than the light on a real wing would do,
and it is meant to be. A hull is about 30 world pixels across and the whole
tilt has to say what it is at a glance, across a room, on a phone. A first
pass ran at about two to one, and at the size a player actually sees it you
had to be told where to look.

Alpha and never hue is the bargain the hurt grade already struck on the same
stroke. Friend or foe is the call a pilot makes in a tenth of a second, and a
hard turn may not put a second question inside it. The grade changes how
bright a rim is, so the side a hull is on survives a bank intact.

Nothing in the simulation moves. A rolled hull's collision radius is whatever
the core says it is, per
[decision 5](#5-defold-owns-presentation-only).

**Cost:** a dropped wing's silhouette goes faint, and per
[decision 50](#50-a-hull-is-a-shape-and-everything-else-is-on-the-shelf) the
silhouette is the whole identity system. Two hulls are a little harder to tell
apart while one of them is holding a hard turn. It comes back the moment the
pilot stops turning, and a bank is a maneuver rather than a state, but it is
a real reading given up for a real one gained.

The hangar's carousel draws hulls with its own code and is not touched, so a
hull turning there stays flat. That is a different motion, a yaw about the
vertical rather than a roll about the long axis, and the two now look
different for a reason a player has no way to know.

**Verified:** photographed rather than reasoned about. A melee on maelstrom
through the playtest harness, a held rudder, and a burst of frames paired by
attitude afterwards, since a screenshot takes about half a second and a
turning hull sweeps most of a circle inside it. Both turn directions on the
Chord and the Apex, at the window the game plays in and again at the pixels a
player actually gets. The client's suite passes and luacheck is clean over 108
files.

---

## 149. A flag is a beacon, and a carrier wears one ring a flag

**Status:** accepted, was 148 and renumbered behind the banking hull
at the landing, replacing the drawing that
[decision 129](#129-a-flag-stands-where-the-map-says) put on the map and
[decision 133](#133-carrying-the-flag-puts-you-on-the-map) put on the
instruments.

**What:** the flag stops being a staff with a cloth triangle on it and becomes
a transponder seen from above: a core, a ring, three arcs standing off it that
turn, and a ping that leaves on a beat. Carried, it opens into a collar
outside the hull, and a pilot holding several flags wears one ring per flag.
Turf and Capture the Flag use the same drawing.

**Why:** asked for. The flags looked silly, and it is worth being precise
about why, because the answer decided the replacement.

A pennant was the only object in this game drawn in elevation. A turf stand is
an octagon, a spawn is two rings, a wall is its own lit face, a wormhole is a
field; the flag alone was drawn as though the camera had turned ninety degrees
to watch cloth flap in a wind, in a vacuum. That is why it read as a golf pin.
A pin is the one real object shaped like that.

It also lied about where it was. The cloth hung up and to the right of the
flag's own position, so the shape a pilot flew at sat a dozen pixels from the
point `sim_flag` tests, and `flag_radius` at eighteen was wider than the whole
drawing with nothing saying so. And at the zoom the game is played at, four
pennants on a map next to three hulls took hunting for.

Five candidates were drawn against it in `.design/flag-graphics` and Chris
picked the beacon. What a flag has to say is where the game is, so it draws
the broadcast rather than a piece of cloth.

**Carried is a collar, not a badge.** The first pass drew the mark on the hull
carrying it and failed twice over: a mark on a hull hides the thing everybody
in the room is trying to shoot, and at the range where a carried flag decides
a round it is a smudge on a hull rather than a flag, because the hull's own
outline is already using that space. Everything inside the widest hull in the
roster is left to the ship. That number is read off `M.HULLS` after the bake
rather than typed, because the Cipher is a knife and reaches twenty two down
its own length while the Apex, which looks like the big one, reaches twenty
and a half. A clearance picked by eye clears the wrong hull, and it did.

**A stack, because holding the set is the round.** The case that matters is
not two carriers in one place, it is one carrier holding several flags. With
no carry limit that is a ring of arcs per flag, alternate rings turning
against each other, since two turning the same way at the same phase read as
one thick ring and the point of a stack is being countable. Where a zone runs
a limit it is one ring of arcs and a draining rim per flag instead, sorted so
the rim about to expire is outermost: that is the one which turns the other
side's color, and it is the answer to the only question a carrier is asking.
Stacking both would put eight rings around a ship and say neither.

**Turf takes the same drawing.** A stand is never carried, so half of it never
runs there. That is the argument for one flag across the catalog rather than
two a player has to learn separately, and a transponder pinging on claimed
ground is what a held stand has to say anyway.

**What the wire owed it.** Three fields. A flag's `held` clock is packed now,
two bytes after its cooldown: `sim_hash` had always covered it and the hash is
what a pack round trip is checked against, so a snapshot had been restoring
carriers whose clock was wound back to nothing, which in a zone with a limit
hands the flag back to the room late. `flag_at` answers the carrier and the
clock, because a pilot's flags have to be gathered onto one hull to be drawn
as one mark and a client that joins mid carry never saw the pickup, so it
cannot count for itself; that is decision 43's rule and Free Roam's greens
learned it the hard way. And `flag_carry_ticks` has an accessor, without which
`held` is a count with nothing to divide by. Protocol 36,
`SIM_STATE_PACK_MAX` up thirty two bytes, no behavior in the core and no
golden moved.

**What it costs.** `Layer:arc_fade` is new and is what makes the drawing look
like the rest of the game rather than like wire: `seg_glow` bent round a
circle, the bloom every wide stroke here carries. `ring_fade` is the whole
circle of it rather than a second copy of the arithmetic. Measured over a
whole beat, since the ping travels and a bigger circle wants more facets, a
flag on a stand is 366 triangles and a carrier with a clock 930, against the
twenty the pennant cost. Capture the Flag's worst case is four carriers
holding one apiece at 3720, and Turf's six stands are 2196, so `GLOW_FIGHT`
goes from 40960 vertices to 49152. A glow layer that runs out does not report
it; it stops drawing whatever came last.

The bloom runs at three quarters of the stroke's facets and the ping at all of
them. Half was the first try and it showed: a circle that is visibly a polygon
is a defect whatever its alpha, and the ping is the biggest circle in the
drawing.

**The instruments follow**, because `ui.lua` already said a flag should look
like a flag on the dial, on the map and pinned to a rim. The dial, the map and
the strip under the band draw a core inside a ring, which is what the world's
mark reduces to once there is no room for the arcs. `pennant_test` is
`flag_mark_test` and probes the ring rather than counting triangles, and
`band_test` finds the strip by its discs rather than by uprights it no longer
draws.

`client/tools/flags_svg.lua` is the sheet, and it loads `arena/world.lua` for
real against a stubbed engine rather than keeping a copy of the drawing: it is
a view of what ships, triangle counts included, so a change to the flag is a
change to the sheet.

## 150. A refused crossing says what stopped it

**Status:** accepted, amending
[decision 147](#147-the-players-sheet-is-the-menus-and-the-band-says-who-won),
which gave the pilot card its join key and left the answer to that key
half written.

**What:** the room answers a crossing it will not make. `S2C_NOTEAM` carries
one byte to the pilot who asked, beside the team list that already went back
to them, saying which gate stopped it: the side is gone, private, or full;
or the pilot is down, or hurt. The client turns the byte into a sentence and
puts it where the pilot is looking, in the panel's note if the panel is up
and in the feed if it is not. Protocol 37.

**Why:** because the promise was already written down and was not being kept.
The comment over `board_join` in `arena.script` said a side was "refused with
the reason rather than in silence", and that was true of the client's own
gate and false of the room's. `Room::join_team` put an ask past two gates and
answered a refusal with a team list that still said where you were, on the
stated grounds that the list is the only thing the client asked about.

The gap that leaves is not a corner case. It is the ordinary one. The client
will not send `C2S_TEAM` on a part-full bar, and the core will not let a hurt
pilot leave where they stand, so the two checks bracket a flight time: press
the key whole, take a hit while the message is in the air, and the room keeps
you where you are without a word. By then the client has played its yes and
put the card away, so what a player gets is a confirmation followed by
nothing changing, which is worse than a plain silence. It turns up under
fire, which is exactly when somebody wants to change sides.

**What was considered and rejected:** having the client notice for itself.
It can see that its side did not change; it cannot see whether the room
refused or has yet to answer, and the only way to tell those apart without
being told is to wait a while and conclude. That is the conclusion about the
shared world that [decision 40](#40-prediction-concludes-no-death-but-your-own)
says a client does not draw, and a timer long enough to be right on a bad
connection is long enough to be wrong on a good one. The reason belongs on
the wire because the room is the only party that knows it.

Reusing `S2C_DENIED` was rejected too. It is the door: FULL, DRAINING,
BANNED, and the rest are answers to a join, and a client reading one
concludes it is not in the room.

**The cost:** a protocol bump for a message an old client would have skipped
rather than misread, which refuses every tab built for 36. The number moves
for the reason protocol 33's did, written out beside `CLIENT_PROTOCOL`: a
build that cannot hear this answer goes on showing
the silence the message exists to end, and the fleet and the page sitting one
build apart on a wire field is the fault that once drew DESTROYED over a
healthy fleet.

**The words are the client's.** The room sends which reason, never the
sentence, the way it sends which saying. A zone a release ahead can name a
reason this build has never heard of, and a build with no words for it says
nothing rather than printing a number at a player.

`a_refused_crossing_says_what_stopped_it` in the server pins each reason
against the gate that produces it, and `client/tests/no_team_test.lua`
pins the parse, the read-once, and the silence on a byte this build does not
know.

## 151. A green is on the dial, and taking one says what it was

**Status:** accepted, finishing
[decision 132](#132-a-green-raises-what-you-fly-not-what-you-own),
which put the prizes on the ground and left them off the one instrument that
answers where to fly next.

**What:** the radar draws every green the client holds, as a dot in the prize
green, over the terrain and under the flags and the contacts. Taking one puts
a line in the feed naming what it filled and nothing else: "picked up
recharge", "picked up gun level 2", "picked up bomb proximity detonation".
The line is marked as this pilot's, so the one line a phone shows can be
spent on it.

**Why:** the zone was already sowing them for the radar and nothing was
drawing them there. The ring a green is put out in is six to twenty-eight
tiles from a live ship, and `baseline.c` and the roam zone's own file both say
why in as many words: outside the near edge so a prize is a trip rather than a
gift, inside the far one so it lands on the radar of the pilot it appeared for
and is a decision rather than a discovery. The dial spans the same sixty tiles
the zone filters a snapshot to, so a green the client holds was already inside
the square at rest and simply not drawn. What that left is a prize you find by
flying over it, which is not a decision at all, in the one zone whose whole
reason to keep flying is that prizes are worth going and getting.

The line in the feed answers a different question. A green on the ground is
deliberately anonymous, because a pilot deciding whether one is worth the trip
is deciding on the trip; the moment it is taken that reasoning expires and the
only thing they want is what they got. The core has always said so.
`SIM_EV_GREEN` carries the slot and the count, and the comment over it in
`sim.h` says it is there so a client can tell a step up from a shrug. The
client was throwing both away and playing a sound that says something
happened and never says what.

**What was considered and rejected:** the map. It answers where am I going
over a thousand tiles, and it is terrain plus flags on purpose, since a view
of the whole arena with everything on it is a wall hack with a keyboard
shortcut. Prizes appear and expire, so they would also be the first thing on
it that is not a still picture of the room.

A diamond on the dial, matching the shape the arena draws on the ground. That
shape is already a contact up there, and two dozen prize diamonds read as a
room full of ships. The dial separates by shape before it separates by color,
because at three pixels the shape is what survives, so the mark that is not a
hull cannot be the hull's.

Coloring the feed line. Three colors in that corner are the fight, yours and
theirs and the one you helped with, and a feed where every line is lit says
nothing by lighting one. The words carry this on their own.

Naming a green before it is taken, on the dial or on the ground. That is
still the call [decision 132](#132-a-green-raises-what-you-fly-not-what-you-own)
made and this does not reopen it.

Printing the count, which the line did at first as the corner card's "x n".
It does not survive being put in a sentence: a card's "spray x2" is two
sprays, where a feed line's "recharge x3" reads as three recharges at once,
which is not a thing anybody holds. The count is drawn live in the corner
stack, and a line read in a tenth of a second wants one fact.

Then a word for a slot with no room left, which was the count's one real
job: a green that lands on a full slot is a trip spent for nothing. It went
the same way, on Chris's call, and the argument against it is the argument
against the count. The line is a name. The event cannot say whether the
grant moved anyway, since the green that fills the last step and the green
that lands on an already full slot report the same number, so the best it
could offer was a condition and not the thing a pilot would want to know.

**The cost:** two dozen more marks on the dial in the one zone that has them,
which is a real crowd on a phone's cropped square, and the first mark up there
that is not terrain, a flag or a hull. Nothing on the wire and nothing in the
core moved: the client already held the field and already got the event.

**The words are the interface's.** `client/arena/prize.lua` turns a kit slot
into the same words the corner card uses for the same kit, at the same length,
so a pilot who reads what a green gave them can find it on the card a second
later. `client/tests/greens_test.lua` holds the field on the ground, the field
on the dial, the order that keeps a dot under a hull, and every shape of word.

## 152. A death floats what it did to your rating

**Status:** accepted, amending
[decision 97](#97-ships-are-preconstructed-and-nothing-is-bought),
which put the rating column on the podium and said nothing carries it during
the fight.

**What:** the figure that used to drift off a wreck is back, and it is the
rating. When a death moves this pilot's rating, the change floats off the
victim's wreck, signed: green for a kill, the feed's red for a death, green
again for a victim they had softened, and a plus zero when the kill was theirs
and paid nothing. Anchored in the world, so it falls behind a moving player the
way the wreck does, held a quarter second, gone in a second and a half. Nobody
else's death gets a figure, and a watcher gets none.

The wire grew two bytes to make the third case possible. `S2C_KILL` names the
killer and the victim and carried their two ratings, so a pilot who only
softened the victim was told they helped and never what it was worth, and
their client's copy of their own rating went stale until a roster or a kill of
their own. Protocol 38 puts the recipient's own rating after the helped byte,
built per copy as that byte already was; the stands read a zero. The client
works the change out from the copy it holds, so the figure is the difference
of the two rounded numbers the pilot would otherwise read.

**Why:** 97's objection was to a standing being read mid-fight, and the bounty
was one: a price on every other hull, on screen all the time, saying who to go
after. This is a receipt about one fight, over in a moment, and it answers the
question the feed line does not. The feed says who took whom; now that nothing
pays, the rating is the only way kills differ, and a pilot who leaves before
the whistle never saw the board that carried the column. Chris asked for the
plus, then for the minus and the assist as well: a rating that moves in silence
in one direction and out loud in the other is a rating nobody trusts.

**Cost:** two bytes a death a seat. The quit kill, brought to the ordinary
layout on main a few hours earlier, goes through the same send as every other
death, so there is one place the message is finished. The podium column is
unchanged, and rating.md and interface.md say the figure exists again.

## 153. A corner takes two faces, so it takes a notch

**Status:** accepted.

**What:** two changes to how a crossed diagonal is drawn, and a new solid
variant. `fill_dead` in `sim/tools/mapgen.c` no longer walls in a tile with a
slope beside it, so the crotches of an X and a V stay the open ground they
were drawn as. `SIM_SOLID_NOTCH_W/E/N/S` is a whole solid tile whose picture
is three quarters of a square, the missing quarter a wedge with its apex at
the tile's centre; `m_chevron` writes two of them where its arms collide.
`expanse.vwmap` is redrawn at seed 61 and carries 46 of them, two to each of
its 23 crossings.

**Why:** because an X was not reading as one, and it took three goes to find
out why. Each arm is a band two tiles across stepping one tile a row. Where
two cross, the crotches narrow past three tiles and the sweep that walls in
unreachable ground plugged all four with square wall: a flat ledge in each.
That is the first change, and on its own it left a sixteen pixel flat on each
side of the waist.

The flat is the real answer. Four faces meet at the middle of an X in two
pairs, and where those pairs land is fixed by the arms' parity: two corners
fall on the tile grid, where the diagonals either side already draw them, and
two fall at the middle of a tile. A slope is one face and cannot make a
corner. So the tile carries both: a notch is a corner drawn on one tile.

**Solid to the core, and deliberately.** Every `SIM_SOLID_*` variant is a
picture; the core stops a ship the same way on all of them, which is written
down beside the enum and was true before this. So the eight pixels inside the
wedge are wall, and a round bounces off them a little early. No hull reaches
them: a hull is three tiles across and grounds on the diagonals either side of
the crossing well before its box could enter, so the mismatch is a round in a
dead-end corner. The honest version is a second face in `slope_hit`, a second
triangle test in the collision path, the Rust mirror, and a regenerated
determinism golden on three architectures, to move a bounce eight pixels
somewhere nothing with a hull can go.

**What was tried and reverted.** A junction laid by `m_chevron` that widened
the waist to four tiles and capped each crotch with a pair of slopes meeting
at a point. It drew a bar with two triangles stuck to it, and because a solid
wedge is ground the next structure cannot stand on, it moved every structure
placed after it and redrew the whole map. An X pinches at the waist. Both
later drafts leave placement alone: the map is the one that shipped with 353
plugs removed and 46 tiles renamed.

**What is left.** The vertex of a V has the same problem and the other half of
it too: the inside corner wants a notch, and the outside point wants a
wedge-shaped solid, which does not exist. Eight tiles on the open arena, left
alone. `m_chevron` draws only NOTCH_W and NOTCH_E, since an X's two
middle-of-a-tile corners are always its left and right; N and S exist for the
editor and for whoever draws the V.

**The renderer had a fault in the same place, and it is a different one.** A
face is drawn once, by the first tile of its run, and `runs` in
`client/arena/world.lua` picked that tile with the set that also answers
whether a face is covered. Slopes belong in that answer and not in this one,
so every open side of a crossing's knot handed its line to a slope, which
draws a diagonal face and never a square one. 164 faces on the shipped map
came out unlit. Fixing that is what made the flats visible enough to argue
about.

**And the vocabulary is closed there.** A slope's face is `x - y` or `x + y` at
a whole number and a wall's is `x` or `y` at one, so a diagonal running into a
wall corners at whole numbers on both axes, on the grid, where the tiles either
side already draw it. Only two diagonals cross at a half. There is no tile
wanted for a diagonal meeting a bracket, a bar, or the map's own edge.

What that junction wanted was for the wall to know its face was showing. A tile
hands its whole shared edge to its neighbour on some sides and not others:
square wall on all four, a slope only on its two legs, a notch on every side
but the one it opens toward. `runs` asked whether anything was there instead,
which answers covered for the half of a diagonal that meets a wall at one
corner, and left a tile of unlit wall at every such junction on the map. All
three readers of that question, the face runs, the corner chamfers and the
diagonal's own end caps, go through `fills` now.

`terrain_style_test.lua` pins the notch on a tile of its own, its apex at the
centre and no face across the side it opens toward, pins that a crossing's
waist draws both corners and no flat, and pins that a wall keeps the face a
diagonal only corners against while handing over the half it lies flush along.
`constant_drift_test.lua` holds the four numbers level across `sim.h`, the
renderer and the editor.

## 154. Nothing in the menu promises a panel

**Status:** accepted.

**What:** the caret is gone from every row that opens one. `land_caret` in
`client/arena/ui.lua` is deleted with its three callers: two on a landing
stop, one down the column and one on a rail cell, and one on `menu_row`'s
`caret` end. The end goes with it, so the row language has five right hand
ends rather than six and a row that opens is an ordinary reading. The four
stops of the column and the ship menu's five sections are what wore it, and
the sections set what they hold where it stood. `hud_svg.lua` put one on the
settings page's Controls and About rows, which the client itself never did.

**Why:** it told a hand nothing. Every stop of the column opens a panel and
every section of the ship menu opens one, so the mark was true of all nine
rows and separated none of them from any other. What it cost was the corner.
A section's reading is the one thing on that row a pilot came for, and it was
set eighteen points short of the glass to keep clear of two strokes.

**The answers moved out to the inset.** A column stop's answer ended fourteen
points inside the panel's own inset while the caret held that corner, so the
right hand side of the column was ragged against a left hand side that was
not. It is flush with `M.ROW_INSET` now, which is the measure decision 104
unified the panels on, and the guest dot that hangs off the front of an
answer is measured from the same edge rather than from where the caret began.

**What is left standing.** The marks that point at something a hand can act
on, which is the back mark in a panel's head and the arrows: either side of a
count, either side of the carousel, and at the edges of a row that pages its
own name. Those tell one row from another. This one did not.

`menu_language_test.lua` holds it cross-surface, on the column's stops and on
the ship menu's sections both, because the mark was shared and a check on one
of them would have passed while the other kept it. `column_test.lua` asks the
same question of the stop it always asked it of.

## 155. A kill says what it did to your rating, and a pickup wears a color

**Status:** accepted, amending
[decision 152](#152-a-death-floats-what-it-did-to-your-rating), which put the
figure over the wreck and left the feed line silent, and reopening the last
paragraph of
[decision 151](#151-a-green-is-on-the-dial-and-taking-one-says-what-it-was),
which left a pickup line the color of everything else in that column.

**What:** three changes, all in the top right corner.

The feed's line about a death ends in what the death did to this pilot's
rating, signed: "OZONE killed KESTREL +12", "KESTREL killed OZONE -9",
"OZONE killed WREN, you assisted +3". The same deaths that float a figure over
the wreck are the ones that carry it here, off one condition in
`drain_announced` rather than two, and both print through `ui.signed`, which
signs a gain, a loss and a nought alike.

The figure over the wreck stands for two and a half seconds instead of one and
a half, at full strength for the first 0.9 of them. `M.RISE` is unchanged, so
it now covers the same 26 points at half the speed.

And the line that says what a green gave you is gold, `#ffd166`, the gold the
corner stack draws a count in and the hangar prices a build in.

**Why the figure needed a second place.** A kill pays nothing, so the rating is
the only way two of them differ, and 152 said it in the world: over the wreck,
for a second and a half, anchored where the death happened. That is the right
first place, because a pilot who has just taken somebody is looking at the
explosion. It is a bad only place. The wreck can be behind you, off the edge of
the glass, or under a bomb going off; the glance that reads a number is the
second glance, and by the time a player in a fight has one to spare the figure
has gone. The feed line about the same death stands for nine seconds in a
corner nothing moves through. So the figure is said in both places, and one
condition in `drain_announced` writes them, which is what stops a kill floating
a number the corner disagrees with.

The longer life is Chris's, and it is the same argument one step further:
notice and read are different lengths of time. Slowing the rise falls out of it
rather than being chosen, and it is the half worth slowing, since the rise is
what says the figure is leaving and a number is easier to read when it is not
travelling.

**Why gold, and why not the obvious green.** 151 left the line uncolored and
said why: three colors in that corner are the fight, and a feed where every
line is lit says nothing by lighting one. What that missed is which lines were
sharing the unlit ink. Arrivals, departures, a refused crossing and a refused
refit are all in it, and every one of them is a line a player can ignore. The
pickup is the only line in the column about the pilot's own kit, and it was
dressed as the five they cannot use.

The obvious color is the prize green the diamond wears on the ground and the
dot wears on the dial, and it is the one color it cannot be. The two greens in
this column are what a kill did to your rating, `#8dffb0` for a payout and
`#5aa874` for an assist, and the prize green sits between them: 1.4 to 1 in
contrast against the payout, at the same hue, on a thirteen-pixel line. A third
green there is a third light in one family, told apart by nobody at a glance,
which is the whole of what a color in this corner is for. The prize green stays
where it is unambiguous, on the field and on the dial.

Gold is the band that was left, and it also happens to be the one that means
this. The corner stack has said what you carry is gold since it was drawn, the
hangar prices a build in the same gold, and a green is a thing you now carry.
The streak is the neighbor, and what makes a streak line a streak line is the
shimmer rather than the hue, which is a claim the feed's own code has made since
that line was written. A still gold beside a moving one reads as a different
kind of line.

**What was considered and rejected.** Violet, which is free in the feed and
means "in the world and nobody's" in the palette, the same thing a green is. It
is ruled out by the note over `M.GREEN`: violet means a place, and a prize is a
thing you pick up, which is why the diamond is not violet either. Coloring the
line violet and the diamond green is one thing wearing two colors, and one
thing per hue is the rule that keeps the palette honest.

The feed's full ink, `#dfe9f5`, which conflicts with nothing because it is not a
hue. It is what the phone's toast already draws an uncolored line in, so it
would have closed a real gap between the two surfaces. It was rejected as an
answer to the wrong question: a brighter slate says "this line matters more",
where the corner's language is that a color says what kind of line it is.

Dropping the wreck's figure now that the line carries one. The wreck is where a
pilot is looking on the tick it happens, and the corner is where they are
looking a second later. Neither covers the other's moment.

**The cost.** A fifth kind of lit line in a column that argued for three, which
is a real price and is the price Chris asked to pay. Nothing on the wire moved:
`k.gain` has been on every kill message since protocol 38 and the client was
already working the change out from the copy it holds.

**Held by** `client/tests/kill_line_test.lua`, which pulls `drain_announced`
out of the arena and runs it over the three lines that are yours, the ones that
are not, and a watcher's seat, then sweeps every shape of death asking only
that the line and the wreck answer together; the figure's clock is at the foot
of the same file, pinned as what a player can read rather than as the constant
behind it. `client/tests/greens_test.lua` runs the arena's event loop and pins
the pickup's color by value, along with the three greens it has to stay out of.

## 156. The corner is the fight

**Status:** accepted.

**What:** the two chips left in the top left corner are gone, and the panel
one of them opened goes with them. `TAKE SEAT`, which a benched pilot pressed
to get back in a hull, and `ROOM n`, which named which copy of the game you
were in and opened a list of the others. What is left up there is the on-air
tally, which is not a control and is drawn only while the room's channel is
pointed at you. In an ordinary match that corner holds nothing at all.

**Why:** each of them was a second way to do something already offered.
Pressing `TAKE SEAT` set the pilot's current class and opened the ship stop,
which is exactly what opening the ship stop does: the panel's foot reads "you
take a seat in it" from the bench, and settling it sends the class and the
build together. The chip was the ship stop with the hull picked for you, in a
corner, and it had already been taken off the landing for the same reason
(decision 143's column key says it better there).

`ROOM n` is the same argument one step out. A game is what a player picks, and
which copy of it seats them is the fill ladder's business: that is why the
number never travels with a row of the games list. The chip put the seam back
on screen, and the panel behind it made moving between copies a reconnect, a
fresh spawn, and a confirm card asking whether the pilot meant it. A zone
holding one room, which is most of them, drew nothing.

**What went with the panel.** `rooms_panel`, `M.room_card` and their state in
`ui.lua`; `zone_rooms` in `directory.lua` and the `rooms` field it put on every
row of the games list; `menu.chosen_room`, whose only writer was the card's
answer; the `rooms`, `rooms_list`, `room`, `room_answer` and `take_seat`
actions in `arena.script`, with the wheel and drag paths that scrolled the
list. `in_list` went too: it tested for `scores` as well, which nothing has
published since the scoreboard became a panel of the menu, so the row-scrolling
half of the drag has been unreachable for a while. Dragging is the menu's page
and the column now, which is what a phone actually needed. The key cap
(`key_w`, `key_frame`, `key_cap`) had no other caller, nor did `population`,
which set a count of people beside a count of machines and was the last reader
of `COL_W`.

**A room is still nameable**, by a deep link, which carries zone, instance and
number and is the one thing that ever asked for a particular one. `net.room` is
still on the wire and `session.enter` still takes a room; nothing in the
interface names one.

`hud_hits_test.lua` holds the corner empty in every state a room has.
`band_test.lua` and `landing_test.lua` measured the top row against the chip's
published box, which was the one thing up there at a key's own height; they
read the row off the on-air tally and off the link meter's box instead, since
neither corner publishes a box any more. `marks_test.lua` read the pilot and
bot marks off a row of the rooms list, and reads them off the players sheet.

## 157. A flag game rates the whistle and not the wreck

**Status:** accepted, amending
[decision 131](#131-a-duel-is-a-two-seat-zone-and-nothing-else), which filed
a rating under the zone's key and left every zone rating by the death.

**What:** Turf and Capture the Flag rate the match. A death in either moves
nobody: `rating.damage` keeps no ledger in a room rated by match, so `death`
and `quit` find nothing to settle and the kill feed's line is the whole of
what a death does. At the whistle the room runs one exchange over every seat
that was on a public side for thirty seconds or more, the same field time the
participation grant asks for. It is team Elo: a side's strength is the mean of
its pilots, each pair of sides is a contest decided by the score, and every
pilot on a side takes the same signed result at their own K, capped by the
same constant a death is. A level score is a draw. The anchor holds, a bot
moves at its K, and the farm brake applies where everybody on the other side
was a machine. A match is one game toward provisional.

The exchange travels as its own record, `spool::MatchEvent`, on its own spool
and route, `/v1/rated-matches`, into its own table, `rated_matches`, and
through the receipt table a death already uses, since the arena mints every id
from one space. The week's swing reads both tables. The release barrier a
rated session settles through posts both spools.

Team Battle, Duel and Free Roam are untouched: kills and deaths, as before.
`modes::rated_by_match` is the one place that says which zones are which.

**Why:** a rating filed under `turf` was a rating about the dogfights on turf
maps, since deaths were the only thing it saw, and a pilot who held four stands
all match and traded two deaths doing it went down. The ladders of every
objective game that has kept one work the way this now does: the match result
moves rating, and per-action credit stays a stat, because a stat can be padded
and a win cannot. Per-flag credit was the alternative and is what rating.md's
open question warned would be farmed in an empty arena; a win over a side of
bots pays nothing once you outrate them and the brake caps the rest.

**Cost:** two ways of being rated, meeting in one function on the room and one
flag on `Rating`. A pilot in a flag zone waits ten matches, not ten deaths, to
leave provisional. The client's death figure is gated on the contributor byte
`S2C_KILL` already carried, so a death that rated nobody floats nothing, and
the client stops counting games off kills, since in these zones the games are
matches and come with the roster. No wire change.

## 158. Nobody is told they are on camera

**Status:** accepted, amending
[decision 156](#156-the-corner-is-the-fight), which left the on-air tally
standing as the one thing in the top left corner.

**What:** the tally is gone, and the corner with it. `corner_row` in
`client/arena/ui.lua` is deleted whole, along with `TOP.chip_right`, which was
how far the chips reached across and is nothing now: the map's width cap falls
back to the plain 124 points it always resolved to, and the clock band gets the
left of the row back, so two names fit on a slightly narrower window than
before.

The wire goes with it. `S2C_ONAIR` is not sent, `net.on_air` and the tag it
parsed are deleted, and tag 13 is retired in `protocol.rs` rather than freed:
a build in the field still listens on it and would take whatever arrived there
as that message, so reusing the number wants a bump. `CLIENT_PROTOCOL` does
not move for this. Nothing misparses, which is what a bump is for; a stale
build simply never lights a chip, which is what a room with no watchers looked
like anyway.

**What stays.** `Room::refresh_on_air` keeps its set and keeps filing an
`on_air` row on the rising edge. That was always two jobs in one function, and
only one of them was about the interface: what the room disclosed about
somebody who did not choose to be watched is worth being able to answer for
later, whether or not anything on their screen said so at the time. The admin
console's activity filter reads those rows and is untouched.

**Why, and what it costs.** The cost is the honest part, so it goes first: a
pilot can no longer tell that the room is looking at them. Two minutes on
camera is something a pilot could play around, and that is gone. The argument
that takes it anyway is the one that took the other five chips. The corner is
the part of the screen the fight is in, and every chip that stood there was
either a control the interface offered somewhere better or a caption on
something already visible. This one was neither, which is why it outlived the
others, and it is still a red mark swelling in the corner of a fight for a
fact a pilot can do very little with. The disclosure it announced is recorded
either way.

`band_test.lua` measured the top row against whatever stood in that corner,
first the ROOM chip and then the tally. It reads the row off the clock's own
foot and the link meter's box now, which meet on one line, and three checks
about the map that had been silently skipped since the ROOM chip went are
anchored again and running. `watch_test.lua` pinned the two edges of the
notice; it pins that a byte on tag 13 now moves nothing. The server test that
read the sends reads the set, which is what gates the log row.

## 159. There is no landing

**Status:** accepted, superseding the landing arm of
[decision 143](#143-one-menu) and the part of
[decision 108](#108-the-front-page-carries-no-instruments-of-a-room-nobody-is-in)
that took the room's instruments off a client with no seat.

**What:** opening the client puts you in the stands of the game you were in
last, and that is an ordinary watcher's session. One screen, and it is the
screen a benched pilot in the same room is looking at: the five stops of the
column over the menu key, the radar in its corner with `POS` over it, the band
that opens the players sheet, the ending at the whistle. The column starts up, because it names the game behind it and holds
the key that gets you into it, and it is dismissed the way it is dismissed
mid-match.

`menu.home` is gone. What is left of it is `menu.adrift`, which says there is no
room on the glass at all, and what stands in for one then is a loading screen:
the dial that is looking for a room, the wordmark under it, and a line when
something has gone wrong.

The attract loop is gone with it. `session.seek_tick` dials a room whenever
there is none, preferring the zone the pilot was last in over the deployment's
own front door, and the connection it makes is the session. Pressing the
column's key no longer promotes anything: `session.take_seat` asks the room for
a hull on the socket already standing, which is what `TAKE SEAT` in the corner
meant until [decision 156](#156-the-corner-is-the-fight) emptied that corner.

**Why:** Chris opened the client and could not find the players list. It was
not a bug in the sheet. Decision 108 had reasoned that the room behind the
front page was somebody else's, so the instruments about a room, the radar, the
roster and `POS`, did not belong on it. That reasoning was sound about a screen
called the landing and wrong about the room: fourteen people were in the game
on the glass, and the interface offered no way to see who any of them were.

The same argument had been made about the same instruments three times, and
each time it took something a watcher wants. The radar answers where in the map
the fight is happening, which is exactly what somebody watching wants to know.
The menu key was withheld because the column out there could not be put away,
and the column could not be put away because there was nothing behind it, and
there was a room behind it the whole time.

What the split cost in code was two of everything: two meanings for the ship
stop, one saving each turn of the carousel and one drafting; two ways to be in
a room, `session.enter` and the attract dial; a `landing` flag through the HUD
payload and a `home` flag through the menu's; a second column geometry with a
lockup and a rail for the short windows the lockup would not fit on. Decision
143 merged the two menus and left this seam, and the seam is where the players
stop fell through.

It also hid a real fault. Decision 136 took the watching arm out of
`apply_menu("ship")` when the ship stop learned to draft, and the two callers
that reached a seat through it, the column's key on a bench and the `TAKE SEAT`
chip, went on calling a function that had stopped doing anything. Both were
controls that made a noise and no difference. Nobody found it because the
landing's key took a different path, and the landing was where anybody pressed.

**What was considered and rejected:** keeping the wordmark over the column on a
client that has just opened, so a first visit still reads the game's name. It
is the landing's signature, and a name that is there for some watchers and not
others is the dichotomy in one more place. The page title, the favicon and
vectorwake.net carry the name; the loading screen keeps the lockup, which is
where a browser tab's first second is spent anyway.

Also rejected: holding the ship stop as pure configuration for a client with no
seat, so that turning the carousel and closing the panel does not put you in
the fight. That is the landing's rule wearing a different hat. A watcher is on
a bench, `ship_foot` says "you take a seat in it" on the panel's head for as
long as the panel is open, and the pilot who reads that and closes it meant to.

**Cost:** the column is five stops tall on every window, and a landscape phone
draws it across the middle of the screen where the watched hull is. That is
what the rail existed to avoid. It is also what the in-match column has done on
that window since decision 147 added the players stop, and the menu is a scrim
over a fight that does not pause: the fight goes on being visible through it,
and one press puts it away.

A watcher at the whistle now gets the players sheet raised over the ending, the
way a pilot in the room does. That is decision 147 applied to somebody who is
not playing, and it is the account of the match they have been watching.

**Verified:** the client's suite, with `landing_test` rewritten as
`spectate_test`: the five stops over the key on four windows, the radar, the
roster press and `POS` on a watcher's screen, the presses standing
down under an open column, and the loading screen measured for itself. luacheck
clean over 109 files. The playtest harness reads `screen.adrift` where it read
`screen.landing`, and `arrive` waits for a room rather than for a front page.

## 160. A dismissal is not a decision

**Status:** accepted, amending [decision 136](#136-a-ship-is-one-thing-and-changing-it-costs-a-respawn),
which made the ship panel an editor and settled its draft on the way out.

**What:** the ship panel's draft is spent by one press, the column's key, and
by nothing else. Escape, the back chevron, the stop pressed again and a press
on the glass beside the panel all leave the draft standing; the key reads it
and says so, and putting the column away drops it.

The key already read where this client is sitting. It reads what it is holding
too: no seat and it says `PLAY`, which flies whatever the ship stop names,
drafted or not; a seat with nothing pending and it says `SPECTATE`; a seat with
a hull drafted over it and it says `FLY WEDGE`, which is the refit and costs a
respawn like any hull change. Three states of one control, on a column whose
other four rows are questions.

A draft lives as long as the column does. Backing out of the panel leaves it on
the ship stop, which names the pending hull, and reopening the panel is the
same undecided ship rather than a fresh baseline: the hull it reverts to is the
one this pilot was flying when the menu went up.

**Why:** because a menu that acts on a hand waved past it teaches people to
stop trusting it. Decision 136 was right that a ship is the hull and the build
together and has to be settled once, and it put the settle on the panel closing
because that was the only moment it had. What that bought was six ways to spend
a respawn, four of which are the universal gesture for "never mind". A pilot
who opened the ship stop mid-fight to see what a Lattice does, turned the
carousel to look, and pressed escape, was respawned in a Lattice.

Decision 159 made it worse before this fixed it, by making everybody a watcher
on the way in: a stranger who opened the client and turned the carousel to
browse hulls was dropped into a live match by clicking outside the panel.

The draft was already doing the work decision 136 wanted. Nothing about
settling on a dismissal is what stops a walk of the carousel from costing seven
respawns; the draft is. So there is no cost side to weigh, only a choice of
which press spends it.

**What was considered and rejected:** a key on the ship panel itself, at the
foot where the head line now stands, with back and escape and the glass all
reverting. It puts the commit where the decision is made, which is a real
advantage, and it keeps the whole transaction inside the panel that owns it.
It was rejected because it makes the ship panel the one page in this menu with
a key of its own, where every other page acts on a row press, and because it
costs height on the panel that has least to spare: five sections over a credit
tray on a 320 by 480 window.

Reverting only for a client with no seat was rejected as backwards on cost. An
accidental commit from the stands means "you are in the game now", which is
surprising; for a pilot it is a respawn in the middle of a fight, which is
expensive. It also reads the same rule two ways depending on whether you hold a
seat, which is the split decision 159 removed.

**The cost:** `SPECTATE` is unreachable while a draft stands, since the key is
wearing the refit. Dropping the draft is escape, and the key is back. That is
two presses on a combination nobody has asked for: handing your seat back is
what you do when you are done flying, and picking a hull first is not part of
it.

And the commit is off screen while the panel is open, because the column slides
out through the bottom edge to let a panel up. A pilot who turns the carousel
has nothing in front of them saying what happens next, so the panel's head line
names the key: `PLAY takes a seat in it` from the stands, `FLY WEDGE respawns
you` in a seat, and the refusals where the bar cannot pay.

**A refusal now holds the draft.** It used to drop it and say so in the feed,
because the panel had already gone by the time anything was asked. The menu is
still open when the key is pressed, so the reason lands beside a key that will
work as soon as the bar fills.

**Verified:** `column_test` runs the arena's own `menu_go` branch through the
three states and the two refusals; `menu_test` holds the draft's lifetime, that
it outlives the panel and dies with the column, and that the key and the hull
it names come off `menu.drafted`. The playtest harness plays it: `ship-change`
backs out of the panel, checks the pilot is still flying what they were flying,
and presses the key.

## 161. The name heads the menu

**Status:** accepted, amending [decision 159](#159-there-is-no-landing), which
took the lockup off the live screen along with the landing it was drawn for.

**What:** the wordmark stands over the column, centered on the column's own
middle and a line clear of the top stop. It goes when a stop opens a panel and
comes back when the panel does, and it rides the column's slide, so it arrives
and leaves with the menu rather than being pinned to the screen. The loading
screen puts it in the same place, off the same measure, so nothing moves when
the room arrives.

`column_geom` measures it, next to the stops it heads.

**Why:** because the name belongs to the menu, and decision 159 read it as
belonging to the landing. It was drawn only at home, so removing the landing
removed it, and what a client that had just opened said about itself was
nothing. The page title and the site carry the name, which is not the same as
the screen carrying it.

Which is also the answer to why it is not simply on the screen at all times. A
watcher with the column dismissed is looking at a game, and a name laid over a
fight is chrome; the menu is the thing that introduces the game, so the name
heads the menu.

Going down under an open panel is the rule decision 159 inherited and kept
without noticing it was still right: the column is one object, and a name left
hanging over a panel that has climbed to the top of the window is the menu
refusing to get out of the way. `at <= 0.001` is that test, and it was already
written; what it needed was the `home` beside it taken off.

**The slide is new.** The old lockup was drawn at a fixed height while the
stops sank underneath it, which nobody saw because the screen it stood on could
not be dismissed. It can now, so the mark rides `rise` with everything else.

**The cost:** the column is five stops tall and the lockup adds about forty
points over it, so on a landscape phone the pair reaches well above the middle
of the screen where the watched hull is. That is the cost decision 159 already
accepted for the column, extended by one line of type; the old landing answered
the same problem by lying the column down into a rail, and the rail went with
the landing.

The loading screen's dial came off the middle of the window and hangs over the
name instead. The middle is where the hull will be, which was the right measure
while the name sat at the foot; with the name where the column heads itself, a
1280 by 560 window puts the two within twelve points of each other and the dial
came out at its floor, a ring the size of a full stop tucked under the type. A
stack has room on every window, and on the two with height to spare it lands on
the middle anyway.

**Verified:** `spectate_test` holds the three states on four windows, that the
name is clear above the top stop and whole on the screen, and that the loading
screen puts it exactly where the column will.

## 162. A refused ship says what stopped it

**Status:** accepted, finishing
[decision 150](#150-a-refused-crossing-says-what-stopped-it), which closed
this hole in one of the two asks a menu makes on a full bar and left it open
in the other.

**What:** the room answers a ship it will not deal. `S2C_NOSHIP` carries one
byte to the pilot who asked, saying what stopped it: the seat is gone, or the
pilot is down, or hurt. The client turns the byte into a sentence and puts it
where the pilot is looking, which for a ship is the feed. Protocol 39.

**Why:** because it is the same fault in the same shape, and decision 150 read
it as being about sides. `Room::set_ship_kit` returned nothing at all. The
comment over the `C2S_KIT` arm in `session.rs` said as much and called it
harmless, on the grounds that the next snapshot carries the hull either way,
which is the reasoning a refused crossing sat on for as long as it did.

The gate is one flight time wide, exactly as it is for a crossing. A ship
costs a full bar and a respawn, the client checks the bar before it sends, and
`sim_set_ship_class` reads it again when the ask lands. So the refusal a
player actually meets is the one nobody can see coming: press the key whole,
take a round while the message is in the air, and the room keeps you in the
hull you were in.

What that looked like was worse than for a crossing. The column key spends the
draft and closes the panel on the way out, because a pilot put back at their
start should be looking at the map. So a refused ship closed the menu, played
the yes, changed nothing, and said nothing. The playtest journey met it often
enough to need a retry, and its own failure message is the plainest statement
of the fault there is: the client said nothing about it.

**Three reasons, not five, and they are the crossing's own bytes.** What
refuses both asks is one rule in the core: it will not move a pilot who is not
there, who is down, or who is hurt. `Room::why_refused` is that reading, used
by both, and `REFUSED_GONE`, `REFUSED_DOWN` and `REFUSED_HURT` are named for
the rule rather than for whichever message needed them first. A side can also
be gone, private or full, and those stay the room's own. A hull is always
there.

The words are still the client's, per decision 150: the room sends which
reason, never the sentence. Two tables rather than one, because the same byte
wants different words. "That side is gone" is a side somebody chose and lost;
a seat that went while an ask was in the air is the connection, and a player
who is told "that side is gone" about their own ship has been told something
untrue.

**What was considered and rejected:** reopening the menu on a refusal, so the
note carries it the way the client's own gate does. The player is flying by
then, usually because a round just landed on them, and a panel that comes back
uninvited during a fight is worse than the silence. The feed is where a
dropped ship is already said.

Generalizing `S2C_NOTEAM` to carry which ask it is answering was rejected too.
The two have different reason sets and different words, so the byte after the
tag would have had to say which table to read, which is a tag with extra
steps.

**The cost:** a protocol bump for a message an old client would have skipped
rather than misread, which refuses every tab built for 38. The number moves
for the reason 37's did, written out beside `CLIENT_PROTOCOL`.

**Verified:** `a_refused_ship_says_what_stopped_it` in the server pins each
reason against the gate that produces it, and that a ship which is dealt says
nothing, because the snapshot carrying the new hull is the answer.
`client/tests/no_ship_test.lua` pins the parse, the read-once, the silence on
a byte this build does not know, and that a private or full side names nothing
on this message. `constant_drift_test` now reads both tags and all five reason
bytes out of `protocol.rs` and checks the client has words at each, since only
the byte crosses the wire and a renumbering would tell a player the wrong
thing rather than fail to parse.

## 163. The row is one line at one size, and it carries your rating

**Status:** accepted, replacing
[decision 67](#67-the-scoreboard-is-a-band-you-press), which made the
scoreboard a band at top center, and amending
[decision 94](#94-the-ending-has-no-foot-and-the-clock-never-moves)'s countdown caption.

**What:** the top of the window is one row set in one size. Your own standing
stands at its near end, the clock with a side either side of it in the middle,
and the dial's two readouts at the far end. Everything on it is the body size,
13 points, the size POS and the feed are already set in.

A side is its score and its name, the figure leading and reading outward, so
the two numbers sit at the band's own ends and the two names bracket the
clock. The sides keep their colors, cyan for yours and amber for theirs; the
clock between them is the reading ink, and under thirty seconds it goes to the
warning color. A name that will not fit is dropped, both or neither, measured
against the tighter of the row's two ends.

Your standing is the figure in the interface's ink with what this match has
done to it in brackets after it, green up, red down, mute at nothing, which is
the pair the players sheet already draws in those words. A watcher is shown
none and neither is a pilot who has not earned one. The movement is the live
figure less what the whistle latched, subtracted on the client, so nothing new
crosses the wire.

Two zones read differently, because a row says what its zone counts, and
neither of them fills the gap with something else. A duel draws no score at
all: one clean kill takes one
([decision 146](#146-a-duel-is-one-kill-and-the-room-deals-you-a-rival)), so
the score would stand at nil to nil for the whole match and then the match
would be over, and what its two sides are is two pilots, so it carries their
call signs. A room that runs forever has no clock and no score, so the middle
of its row is empty and the top edge of that zone is the fight's.

At the whistle both sides stay on the row at their own strength, and `NEXT
MATCH IN` goes on the line under the clock, which is the flag strip's line
during a match and free at the whistle. Not on a window held upright, or one
too narrow for it: the caption's line is the dial's, and the dial is a third
of a phone across.

**Why:** three reasons, and the last one is the one that started it.

The band was three sizes inside eight characters: a 26 point clock with a 9
point name over a 14 point number either side of it. That put the largest type
on the screen on the one reading nobody is playing for, and the smallest on
the two a match is played for. It read as a headline with two footnotes rather
than as an instrument, and nothing about the three sizes said anything, since
what a player wants from the top of the window is which figure is whose.
Color and order carry that at one size, and the row picks up the same body
size everything else on the HUD is set in.

The clock's size was doing one real job, saying "nearly out of time", and it
did it for the whole three minutes. The warning color says it at the moment it
is worth saying and costs the row nothing.

And a rating had nowhere to live. It is the only durable thing a pilot has
([decision 100](#100-seven-credits-and-every-step-costs-one) took the last of
the rest away), it moves on every rated death, and the only places it was
written were the sheet at the whistle and the pages on the site. A number you
are told about after the fact is not something you can play toward. It sits in
the near corner because that corner had emptied
([decision 158](#158-nobody-is-told-they-are-on-camera)) and because the row
already had an instrument at the far end in the same register; the argument
against, that a figure climbing over your head while you fly is the shape the
bounty had, is about a figure on a hull rather than a reading in a corner.

The band is also carrying less than it did. The players sheet holds the roster
now ([decision 147](#147-the-players-sheet-is-the-menu-s-and-the-band-says-who-won)), so what the
band has left is the clock, the score and the result, and a smaller instrument
is the honest size for that.

Four shapes were drawn for it in `.design/scoreboard-band`: this one, a pair
of corner stacks, a filled bar with the stands sitting on it, and a broadcast
tally in the corner. This one keeps the first glance where it has been all
along and changes the least about where a player looks.

**Verified:** `band_test` holds the row at one size on one line, the figure
outside the name, the clock in the reading ink and in the warning color under
thirty seconds, the standing and its movement in the corner with only the
movement colored, the phone dropping the caption and the names but never the
figures, a watcher and an unrated pilot getting no standing at all, a duel
drawing two call signs and no score, and a room with no match counting itself.
`players_test` holds the sheet's own column beside it. `client/tools/hud_svg.lua`
draws the row in every scenario for a look.

---

## 164. The players sheet says where the room stands, all match

**Status:** accepted, amending
[decision 97](#97-ships-are-preconstructed-and-nothing-is-bought), which drew
the rating column at the whistle and never during the fight, and
[decision 147](#147-the-players-sheet-is-the-menus-and-the-band-says-who-won),
which carried that into the sheet

**What:** the sheet's `RATING` column reads whenever the room has standings,
not only once the whistle has gone. It says what it has always said: where the
ladder has each pilot, in the interface's ink, and what this match has done to
it in brackets after it, green up, red down and mute at nothing. A watcher
reads nothing, since the room is not moving theirs, and a room whose ratings
have not arrived gets no column at all rather than a column of empty brackets.
Neither does one seat inside a room that has them, which is a pilot the
snapshot carries and the roster has not named yet: a bracket with no figure in
front of it says the match has cost them nothing, and what is known about them
is nothing.

Nothing else about the panel changes. The band opens it, the `PLAYERS` stop
opens it, the whistle raises it, and it is the same column in the same words in
all three, so what the whistle adds now is the sheet rather than a reading
inside it. An upright phone keeps the column and still gives up assists first.

**Why:** asked for. Decision 97 put the column behind the whistle because a
number climbing over somebody's head while they are being shot at is the shape
the bounty had, and decision 163 then put your own standing at the near end of
the row for the whole match, on the argument that a number you are told about
after the fact is not one you can play toward. Both cannot be right about the
same figure, and the one that has been on screen since decision 163 is the
second: a rating a pilot can watch while they fly is a rating the room can be
read for.

97's objection survives, and it is about something else. It was written about a
price on every hull, drawn in the world, unasked for, all the time. This is a
column in a panel a player chose to open, over a fight they are not looking at
while they read it, and
[decision 152](#152-a-death-floats-what-it-did-to-your-rating) already drew
that line for the figure that floats off a wreck.

What the column answers is who you are up against, and that is worth knowing
before a fight rather than after one. Three of the four columns beside it say
what somebody has done in this match; this is the one that says how they
usually do, and in a room of strangers it is most of the reason a name gets
pressed at all.

**Cost:** in a flag zone the column reads `(0)` for every seat until the
whistle, since those zones rate the whistle and not the wreck
([decision 157](#157-a-flag-game-rates-the-whistle-and-not-the-wreck)). That
is the honest reading of a match that has moved nobody rather than a hole, and
decision 163 took the same reading for one seat in the corner of the row.

An upright phone carries four columns for the length of a match where it
carried three, and a call sign is cut at them. That is the sheet's own rule,
that the figures are what it is opened for, but it bites more often now: a name
at the 24-character limit loses its last few characters on a 390-point window.

**Verified:** `players_test` reads the column mid-match on a monitor and on an
upright phone, with every seat's standing and its movement, and reads no column
at all in a room whose standings have not arrived and nothing on the one row
inside such a room that has none; put back behind the whistle, four of those
checks fail. The whistle's own checks are unchanged and pass.
`client/tools/hud_svg.lua` grew a `menu-players` scenario, which is the first
picture of this panel the tool could draw, and the column reads down a room of
eight with a watcher's row at the foot at both 1280x800 and 390x844. The client
suite and luacheck are clean.

## 165. A flag game is won by holding the set

**Status:** accepted, replacing
[decision 130](#130-turf-is-paid-war-is-a-match), which paid Turf per stand
every five seconds and wrapped War's rounds in a four minute match

**What:** Turf and Capture the Flag have no match clock. A match runs until one
side holds every flag at once and keeps them for fifteen seconds, and then the
room stands the flags back up, changes ground and deals another. Losing one
flag during those fifteen seconds ends the hold; the next completed set starts
a fresh one.

The band draws that and nothing else. No score, because there is none: the
pennant per flag, colored by who holds it, is the whole standing. No clock
either, except the countdown, which appears the moment the set is completed,
reads fifteen, and goes when the set breaks. It wears the color of the side
holding the set, the same two colors the marks under it are wearing.

The two modes became one. `Turf` and `Warzone` differed in what they scored and
in nothing else, so `mode = "flags"` is what both zone files name, and what
still separates the two games is `flag_carry`: four flags gathered and carried
in Capture the Flag, six stands that change hands where they stand in Turf.
`turf_seconds` is gone, and so is `match_seconds` in both files.

Three smaller pieces fall out of it:

- `MatchState::seconds_left` is an `Option`, and `Clock` grew an open-ended
  match: `Clock::open_ended` plays until the mode blows the whistle and answers
  nothing until the podium is up. On the wire that absence is a zero, which no
  running clock can be, since a phase reads at least one second until the tick
  it ends on.
- `MatchState` grew `scored`, and a mode that says no sends no sides. The score
  itself stays: a flag match's ledger is a one against the side that took it,
  which is what `Rating::matched` reads and what the pilot log files. Nobody is
  shown it.
- At the whistle the row has a clock and nothing else, so the line under it
  carries the banner, "Vantage takes it", instead of the `NEXT MATCH IN`
  caption. In a scored game the caption stays: the sides are up there saying
  who won and the caption is about the clock beside them.

**Why:** asked for, and the two zones were funny in the same way for two
different reasons.

Turf's payout was a real design and it read as arithmetic. The scoreboard said
`96` against `120` and the honest question a player had was which stands are
mine, which is what the pennants already answered a mark at a time. Two figures
derived from those marks, integrated over three minutes, is the same fact in a
form nobody can act on: there is no play that changes 96 to 121, only more of
what you were already doing.

War's rounds were the opposite. A round was a real event with a real countdown,
and then it was filed as a tally mark and the flags went back on their stands
with three minutes still on the clock. A player who took the set had won
something the interface immediately put away.

What both games were actually about was the same moment, and neither one ended
on it. Holding every flag is the thing the map is shaped for and the thing four
pilots against four cannot quite manage; making it the end of the match rather
than a point or a round means the fight that decides the game is the fight
everybody can see coming.

Fifteen seconds rather than War's ten. Ten was a round's length and this is a
match's, so it wants to be long enough that a set completed by one lucky sweep
is not a match, and short enough to be watched. Six stands on a turf map is the
harder version of the same problem, which is what the extra five seconds are
for.

No clock at all rather than a long one. A backstop would decide the match by
whoever happened to hold more when it ran out, which is the payout again with a
worse resolution.

**Cost:** a flag match has no length, so a room can hold one for as long as
neither side sweeps, and Turf's six stands are the case to watch: four pilots
covering six stands against four doing the same is a set that may take a while
to complete. That is the pressure the zone was built on, but it is now the
thing that ends the match rather than the thing that colors it, and if rooms
run long the answer is fewer stands rather than a clock. Nothing measures this
yet; the zone probe in [ai-players.md](../design/ai-players.md) is where it
should go, reporting how long a match takes to decide and how often a hold is
broken.

`CLIENT_PROTOCOL` moves to 40 although no byte moved, which is exactly why it
has to: a client built for 39 reads a flag game's packet cleanly and draws
`0:00` over an empty score for the whole match.

Bots read the clock byte to decide what a charge is worth, and in a flag game
that byte is zero for most of a match. `None` there already means "no pace to
keep, pay the asking price", which is right; the fifteen seconds of a hold are
seconds until the whistle like any other and are paced against.

**Verified:** `modes.rs` has ten checks on the new mode: no clock until the set
is completed, the countdown starting at fifteen and running to the whistle, one
flag taken back stopping it and the retake starting a whole fresh fifteen, a
simultaneous change of holder restarting it, a side above three winning, the
podium counting only itself, and the next match opening from nothing.
`a_flag_match_ends_on_the_hold_and_the_next_one_opens_neutral` in `main.rs`
runs the same arc against a room, which is the half the mode cannot reach: it
no longer resets the flags itself, since `open_match` stands them back up on
ground that may have changed. That test is what found the one-tick countdown a
fresh match inherited from the match that had just been won, since an opening
tick sees the old arrangement and the room only clears it afterwards; nothing
is read off an opening tick now. `the_shipped_turf_zone_plays_turf` and its war
counterpart run the shipped zone files end to end. `band_test` reads the row in a flag game: no clock and no
sides with the set loose, the countdown appearing in the holder's color and
going when it breaks, the press that opens the players sheet reaching down over
the pennants since the row above them is empty, and the banner taking the
caption's line at the whistle. `wire_test` reads both absences off the packet
and checks that a countdown appearing from nothing is not read as a match
started over. `client/tools/hud_svg.lua` grew a `hold` scenario beside `turf`,
and both render at 1280x800 and 390x844. Server suite, client suite, luacheck
and clippy are clean.

---

## 166. The corner is a badge and a figure, and every mark wears its band

**Status:** accepted, amending
[decision 163](#163-the-row-is-one-line-at-one-size-and-it-carries-your-rating),
which put the standing in the corner under a `RATING` caption with the match's
movement in brackets after it

**What:** the near end of the row is your standing and the pilot's badge, in
the color of the band you are in. Nothing else stands there. The caption is
deleted and so is the bracketed movement.

Five bands, five colors, and they are the ones already in
`server/src/rating.rs`: Newb in the mute this mark has always been drawn in,
Wing green, Lead gold, Ace violet, Legend in the interface's own ink. Neither
side's color is in the set, since cyan is yours and amber is theirs everywhere
else up here and a badge in either would be read as a side. A pilot inside
their first ten rated games has no band, so the badge takes the mute at a lower
alpha and the figure goes to the mute with it, which is what the pilot's card
already does with the word `placing`. A watcher gets none of it, and neither
does a pilot who has not earned a rating, both as before.

The badge is 14 points wide against the row's 13 point type, so the mark is
seen first and the figure read second.

The same color goes on every mark beside a name, wherever one is drawn: the
plate hanging off a hull in the fight, and the players sheet's rows. Those were
drawn in the side's color on a plate and in one flat mute in the sheet. The
shape still says what is in the seat, wings for a pilot and a chip for a bot,
and the color now says how good they are. On a plate that lifts the alpha a
tenth, from 0.45 to 0.55: the ladder's floor is a mute where both sides'
colors are bright, and at the old alpha the band most pilots are in would have
come out fainter than the mark it replaced.

**Why:** asked for, and the reasons are worth writing down because two of them
were faults rather than tastes.

The caption was a word that said nothing. `RATING` under a four-digit figure in
a corner names a reading the reader has already made, and it was the first
thing a narrow window dropped, which left a phone showing a bare number with
nothing to say what kind of number it was. That is the opposite of what a
caption is for.

The bracket was worse, because it read differently by zone without saying so.
Turf and Capture the Flag rate the whistle and not the wreck
([decision 157](#157-a-flag-game-rates-the-whistle-and-not-the-wreck)), so in
those zones the movement read `(0)` for the length of a match and then jumped.
A figure that cannot change while it is on screen tells a reader nothing.
What a death did to a rating is still said twice where it happens, on the
wreck and at the end of the feed's line
([decisions 152](#152-a-death-floats-what-it-did-to-your-rating) and
[155](#155-a-kill-says-what-it-did-to-your-rating-and-a-pickup-wears-a-color)),
and the players sheet still carries the movement in its column for the whole
room
([decision 164](#164-the-players-sheet-says-where-the-room-stands-all-match)).
The corner said it a third time, in the one place it could be wrong.

What replaces both is a mark rather than a word, and it says the thing a
caption could not: which band the figure is in. That is the reading a number
needs from somebody who has not memorized the ladder, it survives a narrow
window because it is not made of type, and the mark itself is one a player has
been reading all along beside every name in the room.

Colorizing those other marks is the same argument taken to where the mark
already was. A plate over a hull carried its side three times, in the name's
color, in the hull under it and in the mark after the name, and a third reading
of one fact is a color spent saying nothing; how good the pilot is was written
nowhere in the world. The sheet's column gives the room's standings in figures,
and the colored marks give the same reading down the list at a glance, which is
most of what a room of strangers is opened for.

**Cost:** the movement is no longer on the row at all, so a pilot who wants to
know what this match has cost them reads it off the wreck as it happens or
opens the players sheet. That is the trade decision 163 made in the other
direction, and what changes it is that the figure it was drawing was a
bracketed zero in two of the five zones.

Five colors is also five things to learn, and nothing on the HUD teaches them.
The pilot's card names the band in words beside the same figure, which is where
the pairing is learned, and the ladder is coarse enough that most pilots see
their own color change a handful of times ever.

**Verified:** `band_test` holds the corner: the badge and the figure with no
caption and no bracket, the badge in the band's color and the figure in the
interface's ink, the badge first and both inside the near quarter of the
window, a Legend drawn in the ink and a placing pilot drawn in the mute badge
and figure both, a phone keeping both since there is nothing left to drop, and
a watcher and an unrated pilot getting neither. `players_test` holds the sheet:
every band in the room on a mark, the watcher's mark in the mute, and a room
whose roster carries no bands drawing every mark in the mute; its counts of
`RATING` and of the viewer's own movement drop from two to one, which is the
corner's copy going. `client/tools/hud_svg.lua` draws the marks in their bands
in every scenario, working the band out from each pilot's rating rather than
writing it down beside it. Client suite and luacheck are clean.

## 167. A gamepad is the third hand

**Status:** accepted

**What:** the web client reads a gamepad. The browser's Gamepad API reaches
the engine as its standard layout, two sticks, a d-pad, four face buttons, two
shoulders and two triggers, and `client/arena/pad.lua` says what each of them
does in the terms the keyboard and the thumb already use: a control from
`arena/controls.lua`, latched by the frame loop under the control's own name.
Nothing past the latch knows which hand pressed it, which is the arrangement
rebinding put in place for keys and the reason a third hand costs the rest of
the client nothing.

The layout is fixed. The d-pad is the arrow keys: left and right turn, up
thrusts, down backs up. The left stick points where the nose should go, the
way the thumb does on glass, and the engine lights once the push is committed
and the nose is roughly there. The arithmetic that turns a push into rudder
and engine moved out of `arena/touch.lua` into `arena/course.lua` so both
sticks read it and neither can drift. The pad's stick sets no reverse stance:
the pad has a key for backing up, and holding it while the stick points at
what you are backing away from is the one move the thumb on glass never had.
The right trigger and A fire, the left trigger and X bomb, the shoulders spend
the two charges, Y fans the gun, Back is the map and Start is the menu key. B
opens the players sheet while flying and is the way back while the column is
up. With the column up, the d-pad, the stick and A walk it, latched under nav
names of their own rather than under the arrow keys, so a control waiting for
a chord on the controls page cannot read a d-pad press as the up arrow. The
controls table under H is the one control with no button.

Once a pad has spoken, every row of the controls page and of the table under H
writes the pad's button after the key, and the controls page is offered on
glass as well as beside a keyboard. The about page says whether a pad is
connected. A browser reports no pad until a button on it is pressed, so with
none seen the line says to press one.

**Why:** asked for. The rest is how, and two choices in it are worth writing
down.

The layout is fixed rather than bindable. Keys can be moved because a keyboard
has sixty of them and a pilot's hand may sit anywhere on it. A pad has one
place for each finger, every game of this shape puts the same things in the
same places, and a rebinding page for it would be a second catalog, a second
column and a second swap rule for a layout nobody would move. What is fixed is
at least written down where the keys are, on the same rows.

The face buttons change meaning with the column up, which nothing else in the
client does. A pad's convention is that the bottom button chooses and the
right one goes back, and a pilot who has held a pad expects both. Flying, the
same two buttons are the gun and the players sheet, because a button that did
nothing in a fight would be a thumb's reach wasted. The split is decided at
the press, from whether the column is up, and remembered until the release,
the same way a chord's modifier is.

**Cost:** one more mapping the controls page writes and a pilot cannot change.
Walking the column with the stick wants a full push, since the engine marks a
press on an axis at nine tenths of its travel. And the feel of it is unproven:
the routing, the stick's arithmetic and the binding file are held by tests,
and nobody has yet flown a match with a pad in hand.

**Verified:** `pad_test` holds the binding file against the catalog both ways,
every button against a control the game offers, the one control with no
button, the face buttons' two meanings, the stick's course in each direction
with a push behind the nose read as a turn and a half push steering without
lighting the engine, a direction the engine stops mentioning reading as rest,
the pad count across connect and disconnect, and the row label with and
without a pad seen. `touch_test` is unchanged through the shared course
module. `first_tap_test` stubs the pad beside the bindings it already stubbed.
Client suite, browser page tests and luacheck are clean.
