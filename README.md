# vectorwake

A top-down space MMO inspired by Subspace Continuum. Frictionless inertial
flight, energy as both health and ammunition, and arenas whose rules come from
configuration. The simulation model is inherited from a game that got it right
in 1997; the ships, art, sound, maps, and name are ours.

## Status

Early. The research and design are written; the simulation core is taking its
first steps. Nothing is playable yet.

## Layout

| Path | Contents |
|---|---|
| `docs/research/` | What we learned from Subspace, ASSS, and the projects that rebuilt them |
| `docs/architecture/` | How vectorwake is built, with numbered decision records |
| `docs/design/` | What the game is: identity, ships, AI players, rating, accounts |
| `sim/` | The deterministic simulation core: C99, fixed point, no dependencies |

## The one idea

The simulation is a small deterministic fixed-point C library that the client
(Defold, including the browser build via WebAssembly) and the authoritative
server (Rust) both run, tick for tick. Everything else in
`docs/architecture/README.md` follows from that.

## Building the sim core

```sh
cd sim
make test    # unit tests
make check   # tests plus the golden-trace determinism check
```

CI repeats `make check` on x86-64, arm64, and WebAssembly and fails if any
platform's state hashes differ by one byte from the committed golden output.

## License

Not yet chosen formally; the intent is source-available and noncommercial
(decision 18 in `docs/architecture/decisions.md`). Until a license file exists,
all rights reserved.
