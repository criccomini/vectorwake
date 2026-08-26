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
flies with the stick alone and a pilot who wants to be going the other way turns
the ship around. See `arena/touch.lua`.


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

**Status:** deferred, code removed

One on one against a rating-matched human or bot, per
[design/duel-mode.md](../design/duel-mode.md). When a match forms, the server
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
[design/duel-mode.md](../design/duel-mode.md), which is the plan for bringing
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
duels in [design/duel-mode.md](../design/duel-mode.md) are the mitigation, and
they need to be good.

**Reconsider if:** playtests show new players bouncing off the controls
entirely. Optional mouse aim later is a protocol extension rather than a
redesign, but ship balance would fork the moment it exists, so late is
expensive and reluctance is correct.

---

## 18. Source-available, noncommercial license

**Status:** accepted 2026-08-10, PolyForm Noncommercial 1.0.0 in `LICENSE.md`

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
nobody yet. (Friends are wanted now and are built, on this meta-layer rather
than on anybody's: see [design/friends.md](../design/friends.md). Parties and
tournaments still are not.) What remains that we need now is identity, and our identity has
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

**Status:** proposed

[Decision 28](#28-no-chat) removed text between players and named its own
cost: any future league or clan scene will organize on Discord, which means
the community's real home is somewhere we do not control. This record accepts
that cost deliberately instead of letting it happen to us. We create the
Discord server, own it, and hold its admin keys, and the game's only
connection to it is pointing at it.

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
redirect, so the raw invite lives in exactly one editable line and never in a
compiled client, a cached page, or the README. A leaked invite is rotated
without a build.

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

**Status:** accepted; the unrestricted footprint areas are superseded by
decision 57

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

**Status:** accepted

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

**Status:** accepted, superseding the split between ship and upgrades

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
all read the same way down the page. Inside a side it is the best gun first,
and that pilot wears the MVP mark wherever they flew.

One layout at every window size. The measure and the type change, and an
upright phone hugs the foot of the window with the whole block so the key
lands under a thumb; nothing else about the arrangement moves. INVITE FRIEND
is the act the share key performed, named for what a player wants out of it
and sized like a key rather than a banner.

Gone with the page: the six phrase chips, the countdown's drain bar, and the
two-column roster. The band stands down while the ending is up, because the
head carries the score and the foot carries the clock.

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

**Cost:** the row is five stops in 390 points, so every label gives up a
little room. Two controls open one page, which is one more thing to explain
than a single door would be. Reaching the name without a pointer is gone; the
rail stop is the keyboard route, and there is no longer a second one.

**Reconsider if:** the row gains a sixth stop, at which point something has
to leave; or career and stats grow into the client somewhere other than this
page, at which point "pilot" is a name promising more than a password form;
or the name in the corner turns out to be pressed so rarely that it is worth
keeping only as text.

## 70. Sign up, and the pilot page is the career

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

**Status:** accepted

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
