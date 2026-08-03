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

A player has to find a game before joining one. A directory holds the catalog
and the token table, takes registrations from arena servers, verifies the
address each one claims, and answers browse requests.

```sh
vectorwake-server directory 127.0.0.1:9000 ../catalog
```

The second argument is a catalog directory holding `catalog.toml`. Arena
servers reach it with `VW_DIRECTORY` and a `VW_TOKEN` from one of its pool
rows; there is no list of addresses to maintain, because a listing is a held
socket. See docs/architecture/discovery.md for the wire format.

It speaks the same WebSocket protocol the zones do, so a client already able
to talk to a zone needs no second transport, and a zone needs no HTTP
endpoint bolted on. A zone answers `C2S_STATUS` without requiring a join, so
browsing costs nobody a seat.

A directory is authoritative over nothing and holds no state worth losing. If
it is down, a player who knows an address still connects straight to it, and
every arena already running keeps running.

## Calibrating the bot ladder

```sh
vectorwake-server calibrate 8 zone     # writes zone/ladder.json
```

Every roster pilot fights every other, repeatedly, in the real simulation with
the real bots and the real rating math. Zones seed their bots from the
result. Without it the bots simply start level and earn their places in live
play.

The ladder is not sorted by skill and should not be: these pilots fly
different hulls, and a rating measures the individual, hull included.

## Serving a zone strangers can reach

A client delivered over `https` may only open a `wss` socket. Browsers refuse
a plain `ws` connection from a secure origin, and loopback is the only
exception — which is why `ws://127.0.0.1` works from the hosted page and
`ws://<anything else>` silently will not.

So a public zone needs TLS. Point the zone at a certificate and it serves
`wss` itself:

```toml
tls_cert = "/etc/letsencrypt/live/zone.example/fullchain.pem"
tls_key  = "/etc/letsencrypt/live/zone.example/privkey.pem"
```

```
$ vectorwake-server 0.0.0.0:9443 /srv/zone
vectorwake zone server listening on wss://0.0.0.0:9443
```

Setting one of the two without the other is refused at startup rather than
quietly served as cleartext: an operator who asked for `wss` and got `ws`
would have no way to tell from the outside.

Certificates are read once, when the listener binds. They are not part of the
live reload, because swapping a listener's identity underneath connections
that are already open is not something anybody asked for — restart instead.

If you would rather not manage renewal, terminate TLS in front with something
that does ACME on its own and leave `tls_cert` empty:

```
zone.example {
  reverse_proxy 127.0.0.1:9040
}
```

The directory polls zones over the same protocol and can reach `wss` ones, but
it validates against the public roots — a self-signed certificate will show
the zone as not answering even while a browser told to ignore the error can
play on it.
