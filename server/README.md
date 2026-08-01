# vectorwake zone server

Authoritative over everything that matters. Clients send inputs; positions,
damage, deaths, and prize pickups are outputs of `sim_step` and cannot be
asserted from outside.

```sh
cargo run --release -- 127.0.0.1:9010 ../zone
```

The second argument is a zone directory holding `zone.toml`. Without one the
server runs on the built-in defaults and says so. `../zone` in this repo is a
reference zone worth reading: it documents every setting an operator can
touch.

Settings reload while the server runs. Save `zone.toml` and the numbers
change with nobody disconnected; a broken edit is logged and ignored rather
than taking the zone down. Bans apply the same way.

Ratings persist to `ratings.json` beside the config, written through a
temporary file so a crash cannot leave half a record.

Then open the client, put the URL in the box, and press CONNECT.

## Shape

- `sim.rs` binds the C simulation core, linked as a static library by
  `build.rs`. The server reimplements no game rule.
- `ai.rs` holds the AI pilots. They produce an input bitfield and nothing
  else, from a view no better than a human's.
- `main.rs` runs one arena at 100 Hz and broadcasts a snapshot every fifth
  tick (20 Hz).

## Protocol

WebSocket, binary frames. Snapshots are serialized by `sim_pack` in the core
itself, so the server and the client cannot disagree about the format.

| Direction | Byte 0 | Payload |
|---|---|---|
| C2S | 1 | join: class, name |
| C2S | 2 | input: buttons u16, tick u32 |
| S2C | 1 | welcome: your ship id, tick |
| S2C | 2 | snapshot: your ship, acked input tick, packed state |
| S2C | 3 | roster: ship, is-ai flag, name |

Snapshots are whole rather than delta-encoded. A busy arena costs about
11 KB/s per client, well inside the 30 KB/s budget in
docs/architecture/networking.md, so delta encoding is an optimization we have
not needed yet.

UDP for native clients is the same message format on a different socket and
is not built.

## The zone directory

A player has to find a game before joining one. `directory.toml` lists zone
addresses; the directory polls each on a timer and serves the answers.

```sh
vectorwake-server directory 127.0.0.1:9000 zone
```

It speaks the same WebSocket protocol the zones do, so a client already able
to talk to a zone needs no second transport, and a zone needs no HTTP
endpoint bolted on. A zone answers `C2S_STATUS` without requiring a join, so
browsing costs nobody a seat.

A directory is authoritative over nothing and holds no state worth losing. If
it is down, a player who knows an address still connects straight to it, and
a listed zone that stops answering is shown as down rather than hidden --
that is information a player wants.

## Calibrating the bot ladder

```sh
vectorwake-server calibrate 8 zone     # writes zone/ladder.json
```

Every roster pilot duels every other, repeatedly, in the real simulation with
the real bots and the real rating math. Zones seed their bots from the
result. Without it the bots simply start level and earn their places in live
play.

The ladder is not sorted by skill and should not be: these pilots fly
different hulls, and a rating measures the individual, hull included.
