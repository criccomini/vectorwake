# Hosting

Where the processes in [zones-and-arenas.md](zones-and-arenas.md) actually run,
what they cost, and why the answer is a plain virtual machine rather than
anything cleverer.

Prices here were checked in August 2026 and will drift. The measurements will
not, so where a decision rests on arithmetic the numbers are written out.

## What a room costs

Measured against the current core rather than estimated:

```
sizeof(sim_map)        1,050,114 B   shared: sim_settings holds a pointer
sim_sizeof_state()        37,636 B   x2, for double buffering
sim_sizeof_settings()      3,872 B
one room                  79,144 B

 2 ships:  1.6 us/tick = 0.02% of a core  ->  6,400 rooms per core
 4 ships:  2.0 us/tick                    ->  5,000 rooms per core
16 ships:  5.3 us/tick                    ->  1,900 rooms per core
64 ships: 16.3 us/tick = 0.16% of a core  ->    615 rooms per core
```

The map being shared rather than copied is what makes the small numbers small. A
zone has one map, so a process holding a hundred duel rooms holds one megabyte of
tiles and a hundred lots of 79 KB, not a hundred megabytes.

Two consequences follow, and they run in opposite directions from what the
architecture first implied.

`SIM_MAX_SHIPS` is 64, so **a zone with 100 to 200 players is already two to
four rooms** whether anybody wanted that or not, and "one zone, 200 players,
running smoothly" means three rooms that each run well plus a policy that keeps
them full. Worth knowing this is a constraint we introduced: ASSS had no
per-arena cap at all. Its only documented player maxima are `Team:MaxPerTeam` and
`Team:MaxPerPrivateTeam`, both defaulting to 1000, which is uncapped in practice.

The fill target is a separate question, and 64 is the wrong anchor for it. The
original's equivalent knob is `General:DesiredPlaying`, whose entire job is
deciding when to open another public arena, and it **defaults to 15** playing
players with spectators excluded. So thirty years of the game this one descends
from settled on a public room being good at roughly 15 to 30, far below any
technical ceiling. Our fill target is a feel number to playtest against, not a
figure to derive from an array bound; `SIM_MAX_SHIPS` is only the wall behind it.

And a room is cheap enough that **one process should be able to hold many of
them**, which [decision 23](decisions.md) did not allow for. See the amendment
there: rooms per process is a property of the zone, because a 64-player War room
wants its own blast radius while a two-player duel wants to share.

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

**Vultr, for everything.** Arena servers, directories, Nakama, and managed
Postgres, all as Docker containers on plain instances, with the database as a
managed service. See [decision 27](decisions.md).

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
Sub-second machine starts optimise an operation we barely perform, since rooms
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
Nakama are all stateless; the database is a connection string.

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

## Nakama and the database

Nakama needs PostgreSQL or CockroachDB and ships official compose files for
both; Postgres is the pick, since CockroachDB only earns its complexity across
regions and the meta-layer's traffic does not justify it. It exposes 7349 for
gRPC, 7350 for REST and WebSocket, and 7351 for its console.

Buy the database rather than running it. Arena servers and directories hold
nothing, so losing one costs capacity and nothing else; an identity and rating
database is the only thing in the system whose loss cannot be repaired by
rebuilding, because it is not derived from anything. Running it in a container on
a bind mount would quietly turn one instance into a machine we can never lose,
which is the exact property the rest of the design works to avoid.

Put the database in the same region as the Nakama container. Nakama talks to it
constantly and is sensitive to that latency in a way that players are not, and
keeping both inside one provider's network keeps the chatter off the public
internet. Managed Postgres being available in all 33 Vultr regions is what makes
that free to arrange.

One caution on operations: Nakama runs schema migrations on startup, against a
database holding every account. That is the highest-risk moment in this stack,
and it deserves a restore-tested backup and a rehearsal on a copy before a
version bump reaches production.

Note the cost shape, because it is counterintuitive. The arena fleet for 200
players is a few dollars a month. A small instance for Nakama plus managed
Postgres is roughly $20. **The meta-layer costs several times the entire
game-serving fleet, and nearly all of it is the database.** That puts a number on
[decision 11](decisions.md)'s warning that an unused dependency is a tax:
adopting Nakama before friends and leaderboards are wanted roughly quadruples the
bill.

And keep decision 11's other rule literal. An arena server never makes a blocking
call to Nakama inside a tick.

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
