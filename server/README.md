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

Binary messages, over WebSocket frames or WebTransport lanes; the bytes are
identical and `wt.rs` explains the lanes. Snapshots are serialized by
`sim_pack` in the core itself, so the server and the client cannot disagree
about the format.

| Direction | Byte 0 | Payload |
|---|---|---|
| C2S | 1 | join: class, name |
| C2S | 2 | input: buttons u16, tick u32 (the tick it applies to, and honoured) |
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
the real bots and the real rating math. Every room seeds its bots from the
result.

`zone/ladder.json` is compiled into the binary, because the roster is code and
the same nine pilots fly in every room this build serves. So there is no file to
deploy and no path to get wrong, which is how the fleet came to be running with
level bots: the arena's directory is a data volume, the image never put a ladder
in it, and nothing said so. Regenerate with the command above and commit the
file; a `ladder.json` beside a running zone still wins over the compiled one, so
a local calibration takes effect on restart rather than on rebuild.

The ladder is not sorted by skill and should not be: these pilots fly
different hulls, and a rating measures the individual, hull included.

## Pricing the tech tree

```sh
vectorwake-server calibrate stages 24 Apex alpha .   # writes ./stages.json
```

Naming a zone loads the catalog, and the catalog wants this deployment's
identity before it will hand anything over: `VW_POOL_DIGEST` and
`VW_META_VERIFY`. Neither has the least bearing on a measurement, so set them to
anything shaped right and forget them, which is what `set_placeholder_identity`
does for the tests. Measuring `baseline` needs no catalog and no variables.

The ladder holds the tech tree at zero so it can rank pilots, which means it can
never price one. This is the same harness with the pilots held still instead:
one hull, one skill on both sides, and a fixed kit as the only difference
between them. What comes out is a win rate for each stage of the tree against
every other.

The fourth argument names a zone in the catalog and takes its arena block. That
matters more than it sounds, because a zone owns its weapon table and its
add-on steps: Alpha fans multifire to five degrees where the compiled baseline
fans it to fifteen, which moves the hit rate of the stage being priced from 65%
to 80%. Pass `baseline`, or leave it off, to measure the roster as this binary
compiled it.

That example holds for six of the seven hulls. `mod_spread` is the angle a
multifire add-on supplies to a pattern that has none of its own, and the Facet's
gun has one: it fires two barrels seven and a half degrees apart, and keeps that
angle whatever a zone sets. So the Facet is the hull whose fan a zone cannot
widen or tighten from the arena block, and on Alpha it is the hull that fans
*wider* than everyone rather than narrower. Retuning it means setting `spread`
on the `facet-gun` weapons. A named zone that is not in the catalog stops the run rather than
falling back, since silently pricing the baseline under a zone's name is the one
outcome worse than not running.

The map stays the pit whichever zone you name. A zone's own map would put
routing, corridors and a thousand tiles of looking for each other into a
measurement that exists to isolate the kit. Two settings are also held against
the zone's wishes, `spawn_prizes` and `prize_max`, for the same reason the
ladder holds them: Alpha opens with thirty greens, which is precisely what would
erase the thing being measured.

The argument for it is the one the ladder's own comments make, read backwards.
Thirty spawn greens flatten a two-to-one gap between skill levels, so somewhere
between nothing and thirty the kit stops garnishing the flying and becomes the
whole result. This says where.

A kit is granted through `sim_grant`, the core's own prize machinery with the
dice taken out, and it is re-granted at every spawn: death clears the tech tree,
a bout runs to five kills, and a kit issued once would measure one loaded life
and four bare ones.

Three things in the report are worth knowing before reading the matrix.

The **wear column** says what actually went on. Ladders differ per hull, so
`bomb 2` reads `1/2` on anything but an Anvil, and an add-on the roster does not
give that hull reads `0/1`. Those rows are bare hulls under another name, and
the report names them rather than leaving them to be spotted.

The **`+-95%` column** is what a row's count is worth, and it is the number to
read a gap against. A win rate is a coin counted `bouts()` times: at four bouts
a pair that is 48 bouts a row and about fourteen points either way, and only at
32 does it come in near five. Two stages differ when their intervals come apart,
and a gap of ten points off a short run is nothing at all.

The **control** is a second bare kit, identical to the first, so the two ought to
agree. How far they miss by is printed, and unwearable stages land in the same
bucket. Treat it as a diagnostic rather than as an error bar. It is the range of
a handful of samples, which is mostly luck: it has come out at 4.2 points on a
run whose sampling spread alone was nearer fifteen, which is exactly how a coin
flip gets written up as a finding. It also climbs with the bout count where real
noise falls, because more bouts let those rows separate on whatever genuinely
differs between them, and they do not each meet the same field. When the spread
runs wider than sampling explains, that is worth chasing: something is varying
that the harness is not holding still.

**`dmg/hit` and `self%`** are why a stage won or lost, where the win column only
says that it did. A blast falls off to nothing at its rim, so a fuse that goes
off early lands the same count of impacts for a fraction of the damage, and the
hit rate alone reads that as an improvement. Proximity is the case: it lifts the
hit rate three points and cuts damage per impact, which is a losing trade the
win column cannot explain on its own. `self%` is the share of a stage's damage
it dealt to itself, since a bomb's blast has no owner test. It answers "is this
stage losing because the pilot keeps standing in it" with a number rather than
a theory: proximity sits at bare's 1.7%, and the bomb rungs at 5.6%.

The **mirror column** is each stage against itself, kept out of the win column
on purpose. Folding it in would credit one win and one loss to the same row
whatever happened and drag every rate toward a half. Left out, it is a second
check on the harness: a mirror far from fifty says the bouts are biased, not
that the kit is good.

Nothing loads `stages.json`. It is a measurement to diff a tuning change
against, which is why it lands wherever you point it instead of in the zone
directory beside `ladder.json`, where a reader would reasonably assume the
server reads it.

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
