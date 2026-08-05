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

**Status:** accepted

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

---

## 14. AI opponents are in-process bots that emit inputs and nothing else

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

**Status:** proposed

Kills in this game have several contributors and a finisher who may have done the
least. Each death becomes a set of pairwise contests between the victim and each
contributor, weighted by damage share, with damage decaying at the ship's
recharge rate so that healed damage stops counting. The math is in
[design/rating.md](../design/rating.md).

Bots are rated by the same math, which is what lets a player be ranked in an
arena with no humans in it, with one reference personality pinned to a fixed
rating so the bot population cannot drift as a closed system.

Every rated event is stored with its weights and the ratings before and after.
Ratings are a projection of that log rather than the source of truth.

**On model choice:** Elo first because it is explainable. The intended successor
is the Weng-Lin model as implemented by OpenSkill, which is patent-free and
commercially usable. TrueSkill is deliberately excluded: Microsoft licenses it
only for Xbox Live titles and non-commercial projects. Glicko-2 is a free
fallback if rating periods fit better than per-event updates.

**Cost:** Damage ledgers per victim, an event log that grows forever, and a
model that will need retuning once real data exists.

**Measured, once bots held accounts:** "grows forever" turned out to be set by
the bot population rather than by the players, since bots fight at fill around
the clock. The live fleet writes on the order of 300,000 events a day, which is
40 to 50 GB a year and fills a 25 GB database in six to nine months. Throughput
is nowhere near a limit; space is. The answer is retention rather than a bigger
disk, and it is in [meta-layer.md](meta-layer.md).

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

**Status:** proposed, requires counsel before anything goes public

The intent: anyone can read the code, contribute to it, and run a zone. Nobody
but the project can sell it or profit from it. That is not OSI open source; it
is source-available with a noncommercial grant, and saying so plainly costs
less than being accused of pretending otherwise.

Candidates, in current order of preference:

1. **PolyForm Noncommercial 1.0.0.** Purpose-built for exactly this grant.
   Simple, no conversion machinery.
2. **BUSL-1.1** with an Additional Use Grant for noncommercial zone hosting and
   a change date converting to Apache-2.0. More moving parts, and a standing
   promise of eventual open source that a community raised on GPL'd ASSS would
   value.

Either way, contributions require a CLA granting the project commercial rights.
Without one, the first outside contribution would bind the project under its own
noncommercial terms and forfeit the Steam release.

**Cost:** Some contributors only touch OSI licenses and will pass. The
"noncommercial" boundary has fuzzy edges (donation-funded zones, tournaments
with prizes) that the final text has to address explicitly.

**Reconsider if:** counsel advises differently, or if the contributor pool the
license costs us turns out to matter more than the exclusivity it buys.

---

## 19. A tile is its behaviour, not a number in a tileset

**Status:** accepted

Map tiles carry a behaviour class -- empty, solid, safe, door, goal, wormhole,
over, under, turf -- in the low nibble of a byte, and a variant in the high
one. The variant is a door's channel or a goal's team.

The original encoded behaviour in the tile's own value: 1 through 160 were
walls, 162 through 169 doors, 171 a safe zone, 176 through 190 scenery you
flew under. Every rule in the engine was a range check against a constant, a
map editor had to know all of them, and the 160 wall values existed to say
which *picture* to draw -- a rendering concern welded into the simulation.

Nine classes replace 190 numbers because appearance is not in the list. What
a wall looks like is the client's business.

**Cost:** No compatibility with `.lvl` files. A converter has to map tileset
indices onto classes, and the 160 wall pictures collapse to one class, so a
converted map loses its look until the client is given a way to vary it.

**Reconsider if:** a mode needs per-tile behaviour the nine classes cannot
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
the roster a roster once greens are flying: no run of luck turns a Spire into
a bomber.

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
alternatives. Its fast machine starts optimise an operation we barely perform,
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
through play, which caps how organised a team can be and changes what the mode
should ask of them. No zone bots, which the research notes identify as where most
zone identity lived. And any future league or clan scene will organise on Discord,
which means the community's real home is somewhere we do not control.

**Reconsider if:** the answer is a bounded channel rather than a general one.
Fixed phrases, a ping wheel, or team-only signals cost no moderation because there
is nothing unsafe to say, and they recover most of the coordination a flag game
wants. That is a different feature from chat and it would get its own record.

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
been optimised once already. Measured before shipping the fill target, on a
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
nobody yet. What remains that we need now is identity, and our identity has
shapes Nakama does not: accounts minted silently on first contact, bot
accounts with owners, a human, bot, or unknown label derived from credential
shape, session tokens carrying rating claims that arenas verify offline, and a
rating that is a projection of an event log no general backend has an opinion
about.

Meanwhile the cost argument collapsed. Decision 27 priced Nakama at roughly
$20 a month and observed that nearly all of it is Postgres, and this design
buys that Postgres anyway. On top of a database we still had to schema
ourselves, Nakama would add an authentication layer, and the authentication we
actually want, bearer secrets, account keys, platform identities later, is
small.

So the meta-layer is `vectorwake-server meta`: a fourth subcommand of the one
binary, on managed Postgres, holding accounts, credentials, names, the rated
event log, the rating projection, and fleet bans. It issues signed session
tokens that arenas verify with a key distributed in the catalog, it refuses
tokens to banned accounts, and it ingests the rated event batches that arenas
submit under their pool credential. [meta-layer.md](meta-layer.md) is the
design, and [design/accounts.md](../design/accounts.md) is the account model.

This also closes the handoff question in [server.md](server.md): rated events
go to the meta-layer rather than the directory, because the directory is the
piece we most want to be able to lose and the event log is the piece we can
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
