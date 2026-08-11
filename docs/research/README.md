# Subspace research

vectorwake is a top-down space MMO in the spirit of Subspace Continuum. Before
writing engine code we read the original game's documentation, its open-source
server, and the projects that have tried to rebuild it. These notes are what we
learned, written so a new contributor does not have to repeat the reading.

| Document | Contents |
|---|---|
| [the-game.md](the-game.md) | History of Subspace and Continuum, ships, game modes, how a zone is organized |
| [asss-server.md](asss-server.md) | The ASSS server: modules, capabilities, arenas, lag control, configuration model |
| [protocol-and-simulation.md](protocol-and-simulation.md) | Wire protocol, units, physics, the client-authoritative trust model |
| [turrets.md](turrets.md) | Riding on a teammate: the warp rules attaching inherits, what a rider costs the host, and how little of it the server checks |
| [lvl-format.md](lvl-format.md) | The `.lvl` map format, byte for byte, and the tile types our converter reads |
| [map-measurements.md](map-measurements.md) | What one of the original's maps is made of, counted: density, wall thickness, structure sizes and spacing |
| [prior-art.md](prior-art.md) | Subspace Infinity, nullspace, Subspace Server .NET, tooling, and what each proves |
| [implications.md](implications.md) | What we take, what we drop, open questions for vectorwake |

## Primary sources

- asss User's Guide 1.6.1, Grelminar, 27 May 2025 (https://www.trenchwars.org/ssdl/userguide.pdf).
  Despite the trenchwars.org path this is the current ASSS manual, and it is the
  single most useful document about how a Subspace zone actually works. The
  official site at https://asss.minegoboom.com/ still links to a Bitbucket
  Mercurial repository that no longer resolves.
- ASSS source, read from the mirror at https://github.com/fcxcode/eg-asss
  (original: bitbucket.org/grelminar/asss, GPL, C with optional Python modules).
- nullspace, a from-scratch Continuum-compatible client in C++
  (https://github.com/plushmonkey/nullspace). Its `ShipController.cpp` and
  `ArenaSettings.h` are the clearest statement of Continuum's physics units we
  found anywhere.
- Subspace Infinity (https://github.com/assofohdz/Subspace-Infinity).
- Subspace Server .NET (https://github.com/gigamon-dev/SubspaceServer).
- Packet tables at https://www.twcore.org/SubspaceProtocol/.
- SubSpace on Wikipedia for dates and commercial history
  (https://en.wikipedia.org/wiki/SubSpace_(video_game)).

## Reading order

Start with `the-game.md` if you have never played. Start with
`protocol-and-simulation.md` if you have, and skip to `implications.md` if you
want the argument rather than the evidence.
