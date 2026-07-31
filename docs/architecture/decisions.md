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

**Status:** proposed

Speaking Continuum's protocol would let existing clients connect immediately,
which is a serious answer to the cold-start problem for a multiplayer game.

It also imports `i16` pixel coordinates, a fixed settings struct, eight ship
slots, 40 headings, and a security model built on executable checksums. And it
is incompatible with decision 1, since the protocol's death packet is
client-authoritative by design.

**Cost:** No existing players on day one.

**Reconsider if:** a compatibility gateway proves cheap. A server that speaks
both, with Continuum clients running under the old trust rules in clearly marked
arenas, is worth a prototype before we close this.

---

## 8. Simulation runs at 100 Hz

**Status:** proposed

Subspace's tick is a centisecond, and every published zone setting expresses
delays, costs, and recharge rates in those units. Matching it makes the settings
importer exact and makes weapon timing behave as authors expect.

**Cost:** Twice the server work of 50 Hz, and a rollback buffer twice as deep.

**Reconsider if:** profiling says the tick is the bottleneck. Halving to 50 Hz
means reinterpreting every imported setting, so decide before the importer
ships.

---

## 9. Fixed-window tilemap rendering

**Status:** proposed

A 1024x1024 tile map is a million tiles, and we should not assume a single
Defold tilemap component handles that. A tilemap sized to the viewport plus a
margin, rewritten at the edges as the camera moves, bounds the cost by perimeter
rather than by area.

**Cost:** Rewriting tiles during fast camera movement may cost more than
expected.

**Reconsider if:** measurement says the window stutters, in which case a custom
render script drawing tiles from an atlas replaces it.

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
parties, chat outside the arena, leaderboards, tournaments, and the zone
directory, if and when we want those.

**Cost:** A second backend to run, a Postgres dependency, and two authentication
paths to keep consistent.

**Why not now:** at M0 through M4 we need none of it, and an unused dependency
is a tax. The architecture already treats identity as an opaque token the
session layer validates, so adopting Nakama later is an adapter rather than a
rewrite. That property is worth protecting deliberately.

**Reconsider if:** we catch ourselves hand-writing friends, parties, or
leaderboards before M5, in which case adopt early. Or if the game turns out to
need none of them, in which case skip it.

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

## 13. The camera shows a fixed area of the world

**Status:** accepted

Subspace let a bigger monitor show you more of the map, and arenas fought it
with `MaxXres` and `MaxYres` settings that capped a player's resolution. That is
a workaround for drawing map pixels one to one with screen pixels.

Our camera shows a fixed extent in tiles and scales it to whatever the display
is, bounded on extreme aspect ratios. A phone and an ultrawide see the same
amount of game.

**Cost:** Art must be legible across a wide range of scales, and text in the
world needs care.

**Reconsider if:** competitive play finds an aspect ratio exploit the diagonal
bound does not cover.

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

**Reconsider if:** the pairwise decomposition produces ratings that disagree with
what good players can see with their own eyes. The event log is what makes that
recoverable.

---

## 16. Duels are an ephemeral arena plus a zone module

**Status:** accepted

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
