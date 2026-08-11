# Hosting

Where the processes in [zones-and-arenas.md](zones-and-arenas.md) actually run,
what they cost, and why the answer is a plain virtual machine rather than
anything cleverer.

Prices here were checked in August 2026 and will drift. The measurements will
not, so where a decision rests on arithmetic the numbers are written out.

## What a room costs

Measured against the current core rather than estimated:

```
SIM_MAX_SHIPS                  255
sizeof(sim_map)          1,050,114 B   shared: sim_settings holds a pointer
sim_sizeof_state()          51,388 B   x2, for double buffering
sim_sizeof_settings()        3,872 B
one room                   106,648 B

  2 ships:  1.8 us/tick = 0.02% of a core  ->  5,500 rooms per core
  4 ships:  2.2 us/tick                    ->  4,600 rooms per core
 16 ships:  5.5 us/tick                    ->  1,800 rooms per core
 64 ships: 16.4 us/tick = 0.16% of a core  ->    610 rooms per core
128 ships: 29.9 us/tick                    ->    334 rooms per core
255 ships: 58.0 us/tick = 0.58% of a core  ->    172 rooms per core
```

The map being shared rather than copied is what makes the small numbers small. A
zone has one map and its rooms hold an `Arc` of it, so a process with a hundred
small rooms holds one megabyte of tiles and a hundred lots of 107 KB, not a
hundred megabytes. Nothing in a step writes to the map -- doors are computed from
the tick rather than stored, and the core takes it as `const sim_map *` -- so
sharing it costs nothing in correctness. A test asserts two rooms of a zone point
at the same allocation, because the first implementation quietly unpacked the
bytes again per room and the arithmetic above would have been out by a factor of
ten.

Two consequences follow, and they run in opposite directions from what the
architecture first implied.

A room's ship array is 255 long and a zone says how much of it to use, so **a
zone with 100 to 200 players can be one room or four**, and which it is becomes a
game-design decision rather than a limit. Raising the ceiling from 64 was cheap
in exactly the way it looked: `sim_hash` iterates `ship_count` rather than the
array bound, so the golden trace was unaffected, and ship indices were already
`uint8_t` with 255 as the "no ship" sentinel. What it cost is memory, 27 KB per
room, paid whether a zone uses the width or not, and tick time proportional to
the ships actually present rather than to the bound.

Two constants have to move together, the header and `MAX_SHIPS` in
`server/src/sim.rs`, and a mismatch there is heap corruption rather than a
compile error, which is why a test asserts the struct sizes agree with
`sim_sizeof_state`. This is also not a limit we inherited: ASSS had no per-arena
player cap at all, and its only documented maxima are `Team:MaxPerTeam` and
`Team:MaxPerPrivateTeam`, both defaulting to 1000.

The fill target is a separate question, and the array bound is the wrong anchor
for it. The original's equivalent knob is `General:DesiredPlaying`, whose entire
job is deciding when to open another public arena, and it **defaults to 15**
playing players with spectators excluded. So thirty years of the game this one
descends from settled on a public room being good at roughly 15 to 30, far below
any technical ceiling. Our fill target is a feel number to playtest against;
`SIM_MAX_SHIPS` is only the wall behind it, and a zone's own `max_ships` is where
a zone says how much of that wall it wants.

And a room is cheap enough that **one process should be able to hold many of
them**, which [decision 23](decisions.md) did not allow for. See the amendment
there: `max_rooms` is a property of the zone, because a 64-player War room wants
its own blast radius while a two-player duel wants to share.

## What a room full of bots costs

[Decision 29](decisions.md#29-a-bot-is-a-client) moved the AI out of the arena
and onto sockets, which trades AI time inside the tick for a snapshot stream per
bot. The trade was recorded owing a measurement, since snapshot building is the
one cost that now scales with the population and it had been optimized once
already. Measured on a Chaos room at its shipped `bot_fill` of 0.8, which is 51
bots in 64 seats, with the arena and the bot server on one host:

```
arena, 51 bots     17.7 MB RSS   3.0% of a core
  tick + broadcast   36 us median, 216 us p90, 314 us worst
  of the 10 ms tick budget                      3.1% worst case
bot server, 51 bots 14.9 MB RSS  14.3% of a core
directory            6.4 MB RSS   0.0%
```

The median is a tick with no snapshot in it and the p90 is a tick with 51
interest-filtered packs, which is where the cost went and it is affordable: four
fifths of a full room costs the arena three percent of its budget. So 0.8 stands
as the default rather than being something to tune down.

The bot server's own share is the larger one and it is the price of the brain
keeping its timing. Each bot steps its own copy of the room at 100 Hz between
snapshots, because reaction delay and look cadence are counted in ticks and a
brain fed a 20 Hz picture would have five times the reaction time it was
calibrated with. Fifty-one worlds at 16 us a step is most of that 14%. Memory is
nothing, because the bots of one zone share one map by `Arc` exactly as the rooms
of one zone do.

Egress is the number that would have hurt and it is zero here: bot traffic is
loopback while the bot server sits beside its arenas, which is the deployment
rule. A region with arenas and no bot server would pay 30 KB/s a bot in real
bandwidth, which is why there is no such region.

## What the processes actually cost

The arithmetic above is per room, which is the right unit for memory and the
wrong one for everything else. Measured on the live host over 756 seconds, one
arena serving a 51-ship room, another two idle, and the bot server supplying
them:

| process | CPU | resident |
|---|---|---|
| arena, one room of 51 | 13.3% of a core | 21 MB |
| bot server, 153 client connections | 14.8% | 28 MB |
| directory | 0.08% | 10 MB |
| meta-layer | 0.01% | 10 MB |

A 64-ship room simulates in 16.4 us of a 10 ms tick, which is the 0.16% above,
yet the arena holding one costs thirteen percent. The difference is not
simulation: it is fifty-one sockets, their snapshots and their interest
filtering. **CPU scales with clients, not with rooms.** That lands in the same
place the egress argument does, since both count clients, and it means an arena
host is sized by how many people it carries rather than by how many games it
runs.

Two numbers on that table are knobs rather than facts. The bot server is the
largest CPU line here and `bot_fill` decides it; and the whole measurement is
bot-only, so per-client egress under real players is still the figure nobody has
taken.

Directories and meta-layers are a rounding error, which is worth saying plainly
because it decides the central host's size: it is sized by Caddy compressing a
5 MB bundle to 2.9 on every cold load, not by the game.

## The bill is egress

Compute rounds to nothing. The measured snapshot rate is about 30 KB/s per
client after the tile-coordinate and interest-radius work, which is 2.6 GB a day
or roughly 75 GiB a month for one concurrent player. Set that against the
compute those players need:

| Concurrent players | Rooms | Tick cost | Egress |
|---|---|---|---|
| 200 | 4 | 64 us, 0.6% of a core | 14.6 TiB/month |
| 2,000 | 33 | 538 us, 5.4% of a core | 146 TiB/month |

So the hosting question is not "can it keep up" but "who sells bandwidth
cheaply, in enough places, without much operational work." Everything below
follows from that one sentence, and it is the reason a provider comparison
belongs in the architecture documents at all.

## What we chose

**Vultr, for everything.** Arena servers, directories, the meta-layer, and
managed Postgres, all as Docker containers on plain instances, with the
database as a managed service. See [decision 27](decisions.md).

| | Regions | Egress | Managed Postgres | Ops |
|---|---|---|---|---|
| **Vultr** | 33 in 19 countries | $0.01/GB, **$0.10 Australia** | **$15/mo, all regions** | console and API as easy as DO |
| DigitalOcean | 12 | $0.01/GiB, pooled per team | $15/mo | best documentation |
| OVHcloud | 15 | **unmetered** in EU and NA | $64/mo per node | roughest |
| Hetzner | 6 | 20 TB in EU, 1 TB in US | **none** | fine |
| Fly.io | ~35 | $0.02/GB NA+EU, up to $0.12 | not first-party | easiest deploys |

Vultr wins or ties on every axis: the most regions by a factor of nearly three
over DigitalOcean, managed Postgres at $15 in all of them, plain instances with
their own public addresses so Docker and UDP both behave, and tooling as
straightforward as DigitalOcean's. Its weakness is the metered egress that this
document just established is the dominant cost, which is why the growth path
below exists.

Two providers were eliminated on the database rather than on price. Hetzner
sells no managed Postgres at all, so one vendor would have meant third parties
like Ubicloud running inside Hetzner's datacenters. OVHcloud sells it at $64 per
month per node against Vultr's $15, which spends much of the advantage its
unmetered bandwidth had earned.

## Why not Fly.io

Worth recording, because it looked like the obvious answer and is not.

A browser cannot set headers on a WebSocket handshake, so `fly-force-instance-id`
is unavailable to the web client, and reaching one specific machine needs
`fly-replay`: the instance id goes in the URL, the proxy drops the join on any
machine, and that machine returns a replay header instead of upgrading. It works
and costs one hop at join, but it is machinery we would own for a problem plain
instances do not have.

`fly-replay` is HTTP-only, so there is no per-machine UDP addressing through the
proxy. That would have killed [networking.md](networking.md)'s UDP path for
native clients. On instances with their own IP addresses it survives untouched.

Its two headline advantages turn out to be ones this design does not need.
Sub-second machine starts optimize an operation we barely perform, since rooms
appear inside a running process in microseconds. And anycast region steering is
something the directory already does: it reports each arena server's region and
the client prefers its own, which is the same outcome in our own code.

Egress at $0.02/GB is also 10 to 30 times what the alternatives charge for this
workload, which at 2,000 concurrent players is about $3,100 a month against
$8.50 on unmetered bandwidth.

Serverless of every kind is out for a plainer reason: these are long-lived
stateful connections ticking at 100 Hz with a per-room address, which is the
opposite of a request workload. The one interesting exception is Cloudflare,
where egress is free and a room could in principle live in a Durable Object.
That is the only architecture in which bandwidth stops being the bill, and it
would cost a rewrite of the Rust server around a JavaScript and WASM runtime,
no UDP, and a 100 Hz tick inside a runtime built for hibernation. Not now, but
it is the shape of the answer if bandwidth ever becomes existential.

## The growth path

The staged plan that carries these numbers into practice, role by role and host
by host, is [scaling-plan.md](scaling-plan.md); this section is the provider
arithmetic behind its later stages.

At 200 concurrent players Vultr costs roughly $50 to $100 a month in transfer
where OVHcloud would cost $4.54. That difference is a rounding error. At 2,000
players it is about $1,400 a month against $8.50, and it stops being one.

When that happens, add an OVHcloud pool carrying European and North American
volume while Vultr keeps the regions OVHcloud cannot reach and keeps the
database. This is additive rather than a migration, because a pool in
[discovery.md](discovery.md) already carries a provider and a region, and arena
servers from different pools serving the same zone is the normal case rather
than a special one.

Two regional traps to keep in view. Vultr charges $0.10/GB in Australia, ten
times its North American and European rate, so a Sydney room costs ten times a
Frankfurt one in bandwidth and is the first place a second provider pays off.
And OVHcloud's Asia-Pacific locations are quota'd rather than unmetered and
throttle to 10 Mbps past the quota, which is about 40 concurrent players, so
OVHcloud is a European and North American answer only.

## Docker

Everything ships as a container, and with the database managed there is nothing
left on a disk we own that needs backing up. Arena servers, directories and
the meta-layer are all stateless; the database is a connection string.

**Host networking, not bridge.** Docker's default publishes ports through NAT
and a userland proxy, which adds latency, hides the client's source address, and
puts pressure on `nf_conntrack` once a host holds thousands of long-lived
connections. For UDP it is worse. On a dedicated instance `--network host`
avoids all of it.

**An arena binds an ephemeral port and reports it.** Host networking means
containers share the host's port space, so scaling to twenty arena servers would
otherwise need per-replica port configuration. The registration message already
carries a client-facing address, so let the process take a free port and tell the
directory. Then `docker compose up --scale arena=20` needs no per-container
configuration and the directory naturally lists `host:port` per instance, which
is the direct addressing the design wants anyway.

**No Kubernetes.** The zone selection in
[zones-and-arenas.md](zones-and-arenas.md) *is* the scheduler: arena servers pick
their own zone from a unioned view and drain when they should. Nothing needs to
place work, so the deployment story stays `docker compose up` per host at any
scale we will reach. Container count still wants to stay low, because a thousand
containers is a thousand of everything; that is what rooms-per-process is for.

Build to a small image with a multi-stage build. The arena server is a Rust
binary linking the C core, which lands in the low tens of megabytes on a
distroless or Alpine base, and small images are what make a deploy to a dozen
regions unremarkable.

## The meta-layer and the database

The meta-layer is our own service per
[decision 30](decisions.md#30-the-meta-layer-is-ours-and-identity-leaves-nakamas-list),
and it is the one piece of the stack that needs PostgreSQL. Plain Postgres,
because its traffic is logins and rated event batches, which stresses nothing.

Bought and running: `vectorwake-meta`, the 25 GB hobbyist plan in ewr beside
the game host, $15 a month. Size it by disk rather than by load. The event log
grows at bot speed rather than player speed, which is 40 to 50 GB a year and
outgrows this plan inside a year; the arithmetic and the retention answer are
in [meta-layer.md](meta-layer.md).

**The connection needs TLS, and not as a hardening pass.** A managed database
refuses a cleartext connection outright, and Vultr signs each project's
databases with a CA of its own rather than a publicly trusted one, so
`webpki-roots` alone cannot verify it either. `deploy/db-ca.pem` carries that
CA and `VW_META_CA` points at it. This is the kind of thing that fails on the
host and nowhere else, which is exactly why it is written down here.

Buy the database rather than running it. Arena servers and directories hold
nothing, so losing one costs capacity and nothing else; an identity and rating
database is the only thing in the system whose loss cannot be repaired by
rebuilding, because it is not derived from anything. Running it in a container on
a bind mount would quietly turn one instance into a machine we can never lose,
which is the exact property the rest of the design works to avoid.

Put the database in the same region as the meta-layer's container. The service
talks to it constantly and is sensitive to that latency in a way that players are not, and
keeping both inside one provider's network keeps the chatter off the public
internet. Managed Postgres being available in all 33 Vultr regions is what makes
that free to arrange.

One caution on operations: a schema migration runs against a database holding
every account. That is the highest-risk moment in this stack, and it deserves
a restore-tested backup and a rehearsal on a copy before it reaches
production.

Note the cost shape, because it is counterintuitive. The arena fleet for 200
players is a few dollars a month. The meta-layer itself is the same binary in
one more container on a box already paid for, so what adopting it adds is the
managed database, roughly $15 a month. **The database costs several times the
entire game-serving fleet.** That is less than the $20 or so
[decision 27](decisions.md) priced when the plan was Nakama, and the warning
attached to that number still holds: it is a tax worth paying only once there
are accounts to put in it.

And keep decision 11's surviving rule literal. An arena server never makes a
blocking call to the meta-layer inside a tick.

## The shape of a deployment

```
per arena host (Vultr instance, any region):
  docker compose: arena x N   --network host, ephemeral ports

central (one small instance):
  docker compose: nakama, directory
  -> Vultr managed Postgres, same region

second directory (another instance, another region):
  docker: directory
```

Two directories, in different places, because they are the front door and cost
almost nothing. Arena hosts are disposable and carry no state. The only durable
thing in the picture is a managed database somebody else backs up.

## What to measure before this matters

The bandwidth figure that drives every number here is 30 KB/s per client,
measured in a busy 64-ship room. Interest management means a client only receives
the ships near it, so a duel should be far below that, and if it lands near
5 KB/s then a thousand concurrent duels is 10 MB/s and fits on one instance's
uplink with room to spare. That measurement is worth taking before sizing
anything for duels, and it is the one number in this document most likely to
change the arithmetic.
