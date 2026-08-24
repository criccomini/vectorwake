# vectorwake server

The server is authoritative over everything that matters. Clients send inputs
and requests. Positions, damage, deaths, inventory, scores, and match results
are outputs of the shared simulation and the room around it.

The one Rust binary supplies the arena, directory, bot supervisor, meta-layer,
and offline tools. Its first argument selects a role.

## Run a standalone arena

From the repository root:

```sh
cargo run --release --manifest-path server/Cargo.toml -- \
  127.0.0.1:9010 zone
```

The second argument is a directory containing `zone.toml`. Without a usable
file the process runs the compiled baseline and says why. The root `zone/`
directory is the documented standalone example.

Valid local settings reload while the process runs. A broken edit is logged and
the last valid configuration stays live. A fleet arena instead receives its
zone from a catalog through the directory.

An arena process serves one zone and grows rooms inside it up to `max_rooms`.
One 100 Hz loop steps all rooms. Pilots receive ordinary snapshots at 20 Hz and
nearby-combat snapshots at 50 Hz.

## Source shape

- `sim.rs` mirrors the C interface and links the deterministic core through
  `build.rs`. It is deliberately broader than its current Rust callers.
- `room.rs`, `session.rs`, `modes.rs`, and `protocol.rs` own rooms,
  membership, built-in game modes, and the client wire.
- `directory.rs`, `select.rs`, `fleet.rs`, and `catalog.rs` own
  discovery and zone selection.
- `bots.rs` runs the live bot supervisor. `ai.rs`, `pilots.rs`, and
  `nav.rs` are shared with offline calibration; `pilot.rs` records live pilot
  telemetry.
- `meta.rs` owns accounts and the admin API over PostgreSQL. Arena processes
  hand it records through the delivery spools in `spool.rs`.

[The server architecture](../docs/architecture/server.md) describes the
boundaries in more detail.

## Client protocol

Client messages are binary and currently use protocol version 20. WebSocket and
WebTransport carry the same message definitions; `wt.rs` assigns the reliable
and datagram lanes.

A join declares a hull, protocol version, flags, requested zone and room, call
sign, optional house-bot build, and optional session token. Input messages carry
a lifecycle generation, selective receipt windows, and up to four independently
ticked button records. The other client messages request a hull, kit, team
action, watch target, or one of the fixed phrases.

The server replies with a welcome, complete owner-filtered snapshots, rosters,
events, map and settings packs, teams, lag policy, and match state. The C core
serializes settings, maps, and simulation snapshots so the client and server do
not carry separate layout implementations.

Player and watcher snapshots keep a 64 KiB maximum. Full unfiltered state
serialization has its own slightly larger bound for diagnostics and trusted
house bots connected over loopback.

`server/src/protocol.rs` is the canonical message list. Any layout change must
bump its protocol number and the matching number in `client/arena/net.lua` and
`tools/pilot/pilot.py`.

## Run a directory

```sh
VW_POOL_DIGEST=sha256:... VW_META_VERIFY=... \
  vectorwake-server directory 127.0.0.1:9000 catalog
```

A directory loads one catalog, accepts held registrations from arena processes,
verifies the addresses they advertise, and answers browse requests. It assigns
nothing and owns no durable game state. An arena already serving a zone keeps
running if every directory disappears.

Arena processes register with `VW_DIRECTORY` and the raw `VW_TOKEN` paired
with a pool digest in the catalog. See
[discovery.md](../docs/architecture/discovery.md) for that wire and
[catalog.md](../docs/architecture/catalog.md) for the artifact.

## Run the bot supervisor

```sh
vectorwake-server bots
```

The bot process browses the directory and joins rooms as declared clients. It
uses the ordinary protocol, snapshots, input messages, and simulation core. A
room publishes how many bots it wants, and the supervisor yields seats as
humans arrive.

The calibrated roster is shared code between this role and the offline
tournament. That keeps the pilots being rated and the pilots being deployed
identical.

## Accounts and ratings

The meta-layer is the only server role with a database:

```sh
VW_META_DATABASE=postgres://... VW_META_KEY=... \
  vectorwake-server meta /var/lib/vectorwake
```

It stores accounts, credentials, call signs, ratings, match artifacts, and the
rated event log. An arena has no `ratings.json` and no authoritative local
record. It keeps only its instance id and outbound spool files until the
meta-layer accepts them.

Clients carry signed session tokens. Arenas verify them offline with the public
key delivered by the catalog. An authenticated flying join also claims the
account's one rated lease online. A meta-layer outage therefore refuses new
rated sessions while guests and active matches continue; short outages fit
inside the lease's renewal slack, and durable records wait in local spools.

## Calibrate the bot ladder

Run an exploratory pilot tournament from the repository root:

```sh
mkdir -p /tmp/vectorwake-pilots
vectorwake-server calibrate pilots 32 /tmp/vectorwake-pilots
```

That writes raw paired observations to `pilot-calibration-data.json` and the
complete analysis to `pilot-calibration-report.json`, but it cannot change the
live Ladder. The command prints separate superiority and side-equivalence
requirements and uses the larger count. Every scenario mirrors two single-life
fights on the shipped Ladder fixture.

A confirmatory run also names its registered attempt. Run it from the immutable
release-candidate image that contains the registered attempt, since the
attestation binds the compiler, target, build profile, C compiler, and container
recipe:

```sh
mkdir -p "$PWD/pilot-output"
docker run --rm \
  -e VW_META_KEY -e VW_META_VERIFY \
  -v "$PWD/pilot-output:/out" \
  "$VW_IMAGE" \
  calibrate pilots <printed-count> /out release-2026-01
```

Add the attempt and printed design fingerprint to the append-only
`zone/pilot-calibration-attempts.json` first. Set `VW_META_KEY` to the release
signing key, set `VW_META_VERIFY` to its deployed public half, and set
`VW_IMAGE` to that image's immutable digest. The command checks the
registration, exact sample count, output volume, and key pair before it
collects any scenarios. A passing run writes a signed compact
`pilot-calibration.json` attestation and a derived `ladder.json` beside the
full report and raw data.

The release gate checks power, practical effect, family-wise multiplicity,
simultaneous intervals, validation replication, a final holdout, per-matchup
side equivalence, convergence, censoring, and current-content fingerprints.
The order measures whole pilots, including hull, strategy, competence, and
build. It does not isolate any one field, and bot evidence does not establish
monotonic human difficulty. See
[bot-calibration.md](../docs/architecture/bot-calibration.md) for the contract.

Review and archive the evidence, then commit the attestation and Ladder map
under `zone/`. A loose Elo map is ignored. Until a powered attestation is
checked in, the server uses the authored provisional order and seeds only the
fixed rating anchor.

Long measurements that explain the ladder are commands rather than ignored
tests:

```sh
vectorwake-server calibrate diagnostics skill-ladder
vectorwake-server calibrate diagnostics real-map
vectorwake-server calibrate diagnostics stability
```

An unknown name prints the full diagnostics list.

## Measure the tech tree

```sh
VW_POOL_DIGEST=sha256:... VW_META_VERIFY=... \
  vectorwake-server calibrate stages 24 Apex melee .
```

The stage harness holds hull and skill constant, varies only the granted kit,
and writes `stages.json`. It uses the pit to isolate equipment from route
choice, but a named zone supplies the real weapon table and add-on limits.
Passing `baseline` avoids catalog loading.

Nothing loads `stages.json`. It is a balance report to compare across tuning
changes. The same `calibrate` command also provides `profiles`, `hulls`, and
`teams` measurements for questions that need the shipped map rotation or more
than one pilot per side.

## Public transport

A page served over HTTPS may connect only to secure transports. For a standalone
arena, set both `tls_cert` and `tls_key` in `zone.toml` or terminate TLS at a
reverse proxy. Setting only one is refused. Certificates are read when the
listener starts and are not hot-reloaded.

WebTransport is optional and configured separately with `wt_listen`,
`wt_cert`, and `wt_key`, or their `VW_WT_*` environment overrides. Clients
fall back to WebSocket when that door is absent or cannot be opened.
