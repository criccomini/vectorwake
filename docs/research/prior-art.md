# Prior art

Four projects matter to us, for different reasons.

## ASSS (Grelminar, C + Python, GPL)

The reference server. Still the thing most live zones run, still receiving
manual updates as recently as May 2025. Its architecture is covered in
[asss-server.md](asss-server.md).

Status caveat: the canonical repository was a Mercurial repo on Bitbucket, which
stopped hosting Mercurial in 2020. The homepage at asss.minegoboom.com still
points there and now 403s on direct fetch. We read the source from the GitHub
mirror at https://github.com/fcxcode/eg-asss.

What to take: the module boundaries, the adviser pattern, the capability system,
and the lag response model. What to leave: 32-bit-only assumptions, Berkeley DB,
and modules that can segfault the server.

## Subspace Server .NET (gigamon-dev, C#)

A modern reimplementation of ASSS on .NET, cross-platform, actively developed.
It keeps ASSS's module architecture close enough that the repo ships an
"equivalents" document mapping module to module, and a quickstart aimed at
people migrating an existing ASSS zone.

The interesting parts are the performance choices, because they show what it
costs to keep this design in a managed runtime: object pooling through
`Microsoft.Extensions.ObjectPool`, `RecyclableMemoryStream` and `StringPool` to
hold allocations down, SQLite or PostgreSQL instead of Berkeley DB, Protocol
Buffers for its own serialization, and SkiaSharp for map image generation.

The lesson we take: ASSS's architecture survives a language port intact. The
module-and-interface decomposition is not a C artifact, it is the actual design.

## nullspace (plushmonkey, C++/OpenGL)

A from-scratch Continuum-compatible client for Windows, Linux, and Android. It
implements the protocol, both encryption schemes, the full weapon set (bullets,
bouncing bullets, bombs, prox bombs, mines, repels, shrapnel, bursts, decoys,
thors, bricks, rockets, portals), energy and recharge, afterburners, cloak,
shields, door synchronization, prize weighting, and LVZ rendering.

This is the most valuable single artifact we found. Reimplementing the client
forced the author to pin down every unit and formula the original left implicit,
and the result is readable C++ rather than a disassembly. Our units table in
[protocol-and-simulation.md](protocol-and-simulation.md) comes mostly from it.

Two limits are worth knowing. The author says outright they will probably never
finish it. And it depends on a private network service for Continuum checksum
and key expansion, so it cannot join Continuum-only zones unless the server also
allows VIE encryption. That dependency is a good illustration of how the
original anti-cheat design constrains anyone rebuilding the client.

## Subspace Infinity (assofohdz, Java)

The closest project in spirit to what we are doing: a fan reimplementation of
both client and server on a modern engine, aiming for a "faithful re-creation of
the Subspace Continuum experience," BSD-3-Clause, single maintainer, pre-alpha
with no playable gameplay yet.

The stack is entirely Simsilica ecosystem: JMonkeyEngine 3 for the engine, Zay-ES
for entities, Zay-ES-Net and SpiderMonkey for networking, SimEthereal for state
synchronization, Lemur for UI, MOSS for physics and world grid, Pager for
streaming, Groovy as a hot-reloadable DSL for zone and arena configuration.

Two decisions there are worth arguing with rather than copying:

Choosing an ECS plus a general-purpose engine buys tooling and loses control of
the simulation loop. Subspace's feel comes from a specific fixed-point movement
model at a specific tick rate. Layering that on someone else's physics is
possible but the constraint runs the wrong way.

Replacing the INI settings format with a Groovy DSL is a real improvement in
expressiveness and a real loss in compatibility. Thirty years of zone
configurations exist in the old format, and they are the game.

The project's stated goals we agree with: server-side truth with clients as
renderers, and zones authored without forking the engine.

## Tooling and community infrastructure

Worth knowing exists, mostly as evidence of what an ecosystem needs:

- MervBot and TWCore: bot frameworks that speak the client protocol. Nearly
  every zone's game logic (leagues, duels, matchmaking) runs in bots rather than
  server modules, because a bot can be written by anyone and restarted without
  dropping the arena.
- Continuum Level / Ini Tool and lvltool: map editors that support the extended
  LVL format with regions.
- The billing server: a central account authority that zones can attach to,
  which is how identity worked across independent servers. `auth_file` is the
  local fallback.

The bot ecosystem is the part we underestimated before reading. A zone's
identity mostly lives in bots, not in the server, which suggests any engine we
build should treat "a program that connects as a player and has elevated rights"
as a first-class supported thing rather than an accident.

## Sources

- https://github.com/fcxcode/eg-asss (ASSS mirror)
- https://github.com/gigamon-dev/SubspaceServer
- https://github.com/plushmonkey/nullspace
- https://github.com/assofohdz/Subspace-Infinity
- https://github.com/ZacharyRead/subspace-modules (ASSS modules written by zone staff)
- https://www.twcore.org/SubspaceProtocol/
- https://www.mervbot.com/files/addendum.txt
