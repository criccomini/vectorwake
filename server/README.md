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
