# vectorwake architecture

These documents describe how vectorwake is built and why. They assume you have
read [docs/research](../research/README.md), particularly
[implications.md](../research/implications.md), which is where most of these
decisions come from. For what the game is rather than how it is built, see
[docs/design](../design/README.md).

These started as proposals and are no longer uniformly that. The simulation core,
the client, the authoritative server, bots, rating and the zone settings surface
are built and playable; the fleet described in
[zones-and-arenas.md](zones-and-arenas.md), [catalog.md](catalog.md),
[discovery.md](discovery.md) and [admin.md](admin.md) is designed and not built,
and [roadmap.md](roadmap.md) says in what order it should be. Each document says
which of the two it is, and where a decision is still open it says so.

| Document | Contents |
|---|---|
| [goals-and-constraints.md](goals-and-constraints.md) | What we are trying to build, what we refuse to trade away, what we are willing to lose |
| [system-overview.md](system-overview.md) | The pieces and how they fit: sim core, client, zone server, bots, directory |
| [platforms.md](platforms.md) | Browser, Steam, mobile, consoles: what each one costs us and in what order |
| [simulation-core.md](simulation-core.md) | The deterministic C core: fixed point, tick model, state layout, API |
| [client-defold.md](client-defold.md) | What Defold does for us, what it does not, project layout, map rendering, prediction |
| [server.md](server.md) | Authority, extension modules, lag response, persistence, operations |
| [zones-and-arenas.md](zones-and-arenas.md) | One arena to a process, what a zone is, how an arena server picks which one it serves |
| [catalog.md](catalog.md) | The one artifact with an author: every zone, credential and ban, and what validation rejects |
| [discovery.md](discovery.md) | Registration, credentials, verification, the wire format, how a client finds a game |
| [admin.md](admin.md) | The operator web UI: what it observes, what it edits, what it may command |
| [hosting.md](hosting.md) | What a room costs, why the bill is egress, the provider choice, Docker, Nakama's database |
| [deployment.md](deployment.md) | The arrangement on a real host: Caddy, hostname routing, provisioning with nobody logged in |
| [networking.md](networking.md) | Transports, packet model, snapshots and inputs, lag response, anti-cheat |
| [ai-runtime.md](ai-runtime.md) | Where bots run, how they perceive and fly, and why they cannot cheat |
| [content-pipeline.md](content-pipeline.md) | Settings, maps, assets, and how a zone author works |
| [decisions.md](decisions.md) | Numbered decision records with status and the argument for each |
| [roadmap.md](roadmap.md) | Milestones, in the order that retires the most risk |

## The short version

vectorwake is a top-down space MMO in the tradition of Subspace Continuum.
Frictionless inertial flight, energy as both health and ammunition, teams called
freqs, and arenas whose rules come from configuration rather than from our
source code.

The zone and arena model moved after these documents were first written. A zone is
now one game backed by interchangeable arena servers, a directory serves many
zones at once, and one process holds one arena.
[zones-and-arenas.md](zones-and-arenas.md) is the current account; where
[server.md](server.md) and [system-overview.md](system-overview.md) still describe
one process hosting many named arenas, they say so and point here.

The architecture rests on one idea: the simulation is a small, deterministic,
fixed-point C library that both the client and the server run, tick for tick.

```mermaid
flowchart LR
    subgraph Client["Defold client"]
        L["Lua: input, UI, audio, camera"]
        R["Render: tilemap window, sprites, effects"]
        SC1["sim core (native extension / WASM)"]
        L --> SC1
        SC1 --> R
    end

    subgraph Server["Arena server"]
        NET["Transport: UDP + WebSocket"]
        AR["One arena, one sim instance"]
        SC2["sim core (static lib)"]
        MOD["Zone modules (sandboxed)"]
        NET --> AR --> SC2
        AR <--> MOD
    end

    Client -- "inputs (60 Hz)" --> Server
    Server -- "snapshots + events" --> Client
    Bots["Bots (protocol clients)"] <--> Server
```

Defold renders and takes input. It does not own game state. The server is
authoritative over damage, deaths, flags, and scoring, which is the one place
where we deliberately break with the original.

## Why Defold

Defold is a good fit for the client and a poor fit for almost everything else,
and the architecture reflects that split.

What it gives us: a small fast 2D renderer, native extensions compiled by a
hosted build server for every target including WebAssembly, hot reload, and a
bundle size measured in single-digit megabytes. It also reaches every platform
we want, from a browser tab to Nintendo Switch, without a rewrite. For a game
whose visual budget is geometry on a tile grid, that is most of what a client
needs. See [platforms.md](platforms.md).

What it does not give us: a server. Defold can build a headless variant and
people do run game servers with it, but a zone server wants long uptime,
sandboxed extension modules, a database, and predictable memory behavior under
hundreds of connections. Those are not Defold's strengths, and reaching for them
would put our simulation inside a Lua VM whose component update order the manual
explicitly declines to specify.

So Defold is the client. The simulation is C. The server is its own program.
[decisions.md](decisions.md) records the argument in full, including the case
for the headless-Defold shortcut we may still take for the first prototype.
