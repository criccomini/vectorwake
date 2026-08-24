# The scaling plan

How the deployment goes from one box running everything to hosts that scale
independently, in stages that are each shippable alone. [hosting.md](hosting.md)
holds the arithmetic and the target shape; [deployment.md](deployment.md)
describes the single host as it runs today. This document is the path between
them.

The premise, worth stating because it decides what the work is: the software
half already exists. Arena servers pick their own zones from a fleet view, so
nothing needs a scheduler. Pools authorize an operator's block of capacity by
token, so adding a provider is a catalog row. `VW_DIRECTORY` takes a comma list
and resolves a hostname to every record behind it, and registration speaks the
same wss a browse does, so a remote arena reaches the directory with
configuration alone. What remains is deploy plumbing, plus exactly two gaps in
code: the client holds one directory address where it needs a list, and arenas
bind pinned ports where a scaled host wants ephemeral ones.

## The shape we are leaving and the shape we are going to

Today: one Vultr instance running both roles off three compose files. Caddy is
the only thing on the public interface; the directory, the meta-layer, two
arenas and the bot server sit on loopback behind it; a payload container
delivers the client page. Each arena holds every room its zone allows, so two
processes cover Melee and Ladder. Deploys are a git push picked up by a systemd
timer.

Target, from hosting.md:

```
central (one small instance)          vectorwake.net, play.vectorwake.net
  caddy, public site, directory, meta, client page
  -> managed Postgres, same region

arena host (any region, any count)    <name>.vectorwake.net
  caddy, one arena per zone served, bots

second directory (elsewhere, tiny)    directory.vectorwake.net with the first
```

Arena hosts are disposable and hold no state. The central host holds none
either; the only durable thing anywhere is the managed database. Sizing is
egress rather than compute throughout: a 64-ship room costs 0.16% of a core and
a client costs about 30 KB/s, so an arena host saturates its uplink long before
its cores.

## The commands that create a host

Deploys stay a git push and need no command at all. Host lifecycle is the part
that was console clicking: a host is an instance, a certificate volume, a
firewall group membership and a DNS record, in that order, with names that have
to match, and `deploy/provision.sh` has carried unfilled placeholders that
somebody substituted by hand every time. Doing that by hand is how the Vultr
firewall group stayed half open for a day while ufw looked right and the arena
reported listening.

`deploy/fleet.sh` is that ritual, as recipes over `vultr-cli`:

```sh
fleet.sh secrets init [region]           # the bucket the fleet's secrets live in
fleet.sh secrets put <NAME>              # store one, value from stdin
fleet.sh secrets ls                      # names and dates, never values
fleet.sh secrets env                     # exports: eval "$(fleet.sh secrets env)"
fleet.sh firewall                        # create or complete the group
fleet.sh db [--url]                      # the database, and its connection string
fleet.sh db create [region]              # bring one up
fleet.sh db destroy                      # take it down, which is final
fleet.sh render <role> <name>            # the user-data, to read before sending
fleet.sh new    <role> <name> [region]   # volume, instance, attach, DNS
fleet.sh point  <name> <host>            # move a name onto a host: the cutover
fleet.sh rm     <name>                   # instance and record, volume survives
```

`--dry-run` on any of them prints every call it would make and makes none.
Reads still happen, because they are what the decisions are made from, so a dry
run truthfully says whether it would reuse a certificate volume or create one.
It cannot know an id that does not exist yet. Flag names, positional arguments
and JSON keys were checked against vultr-cli v3.11.0's source, which caught
three that were wrong; the live API's answers are the one thing reading cannot
verify. Honest about the plan, silent about the execution.

`firewall` is idempotent by reading the rules back and adding only what is
missing, which is how a port added to the list reaches a group that already
exists. `new` finds the group by label rather than taking an id, and refuses
outright when there is none: a host outside the group binds, reports listening
and receives nothing, which is indistinguishable from a host inside a shut one
and cost a day to diagnose once already.

`db` covers the database's whole life, because a rebuild in a new region is a
database as well as hosts, and the step left to the console is the step that
gets done wrong at midnight. The cost of a mistake is what shapes the verbs.
Bare `db` creates nothing, since the usual reason to run it is to read the
connection string, which it assembles rather than stores and which is what
`VW_META_DATABASE` wants. `db create` names the plan, the region and the
monthly bill before it asks, then waits: credentials do not exist until the
thing is Running, and that is minutes. It is a no-op when one already exists,
since two would be an expensive way to notice.

`db destroy` is the only verb in the file that a rebuild cannot undo. A host is
disposable, a volume holds certificates that reissue, a DNS record is one call,
and this holds every account, every rating and the rated event log, of which
nothing in this repository is a copy. So it prints what is inside, asks the
operator to confirm Vultr's automatic backup status, and requires the label to
be typed rather than a keystroke.

`secrets` is where the fleet's identity lives: the raw pool token, the meta
signing key and its verifying half, the database connection string and the
deploy key, in one bucket in Vultr object storage. The catalog names the two
public halves with `env:` rather than carrying them, so minting a new identity
is a `secrets put` and a rebuild, with no commit, no image and no version bump.
The pool digest is not even stored, since it is the sha256 of a token already
in the bucket and two copies of one fact can disagree.

The secrets used to exist in exactly one place, the `.env` of a host built to
be destroyed, and every rebuild began by remembering to rescue them. The
bucket's credentials come back from the same API the rest of this file speaks,
so `VULTR_API_KEY` is the one thing an operator holds; `render` and `new` fill
anything not exported from the bucket, and an exported value always wins.

The hosts never see that bucket. Vultr object storage has one credential pair
per subscription and no way to scope it, so a host that could pull anything
would hold a credential that pulls everything, and an arena host must not be
one curl away from the meta key. fleet.sh reads the bucket at render time and
bakes into each host's user-data exactly what its role needs, which is the same
delivery every host already gets and adds no boot-time dependency. The objects
themselves move through the `aws` CLI pointed at the Vultr endpoint, because
vultr-cli manages the subscription and does not speak S3.

`point` is the rebuild. `new` gives a host its own name, but `play.vectorwake.net`
is in the catalog's meta url, the client's baked directory address and every
arena's advertised address, so a rebuild keeps the name and moves the address
under it. The record is updated rather than deleted and recreated, since a name
that briefly does not resolve is worse than one that briefly points at the wrong
place, and it warns when the record's existing TTL is longer than the cutover
window somebody is expecting.

Not Terraform, and no state file of any kind. Every verb reads the authority
that already exists, the provider's API, and reconciles by looking rather than
by remembering; whether a host actually serves is the browse list any client
sees. A tfstate would be a third opinion about questions already answered. The plan-and-apply habit of recreating resources also points
straight at this deployment's most expensive known mistake, since a reinstall
costs one of five weekly certificates.

Recreating a host is the case that has to be got right, because it is the one
that cost this deployment its certificates. Let's Encrypt allows five for the
same name in a week, and a host destroyed and recreated four times in an
afternoon is a name that cannot be served until the week turns. So `rm` leaves
the certificate volume behind and `new` looks for it and attaches it: a
replacement mounts certificates that are still valid and issues nothing. A
volume of that name still attached to a live host stops `new` rather than
letting it create a second, since creating one would spend an issuance and
stealing one would take the certificates off a running host.

Hosts default to the $5 1 GB plan in Atlanta. The 1 GB is measured, about
400 MB for the whole box over 2 GB of swap, and the plan's 1 TB of included
transfer carries a dozen concurrent players at 30 KB/s each, which is the
number an arena host actually runs out of. The 512 MB plans are a trap with
three doors: the IPv4 one at $3.50 is sold in New Jersey and nowhere else,
the $2.50 one is IPv6 only and cannot pull from ghcr, and the free one has no
transfer. Atlanta is a base-rate egress region and one of three selling
Standard-tier object storage. Sydney is the one region worth naming before
choosing, at ten times the egress of everywhere else.

One region for everything is a convenience rather than a requirement. The
bucket is reached over HTTPS from a laptop, and one that already exists in
another region keeps working untouched, since every verb finds it by listing.
The database wants to be beside the central host, since every account
operation crosses that distance. The region reaches the host as well as the
API, because an arena reports its own region and a browse reply repeats it.

It runs from a laptop with `VULTR_API_KEY` in the environment, and refuses to
run under `CI`. Machines appearing as a side effect of a push is the class of
surprise this deployment keeps paying to remove.

## Stage 1: split the deploy into roles

Done. One compose file became three: `caddy.yml` is the proxy every host runs,
`central.yml` is the directory, the meta-layer and the page, `arena.yml` is the
arenas and their bots. A role is which of those a host runs, and it travels as
`COMPOSE_FILE` in the `.env` provisioning writes, so no command anywhere had to
learn a flag: provisioning, the updater and anything typed on the box all say
`docker compose --env-file .env` and get the shape that host is.

The existing box runs `all`, which is central and arena together, and it renders
byte for byte what the single file rendered: same eight services, same images,
same commands, same loopback ports. The only differences are the ones the split
requires. `depends_on` lost the edges that crossed the boundary, since ordering
that can only be expressed on one shape of host is worse than none, and neither
edge was load bearing: an arena retries registration and a bot retries its claim.

The hostname stopped being `play.` in a file. `VW_HOST` is the name a host
serves rather than the machine it is, so a central host answers for
`play.vectorwake.net` whichever instance is underneath it, and an arena host
answers for its own name and has a certificate a minute after booting. Caddy's
routes moved to `deploy/caddy/conf.d` and `VW_ROUTES` picks which of them a host
imports, so an arena host has no `/dir` route rather than one pointed at a
directory that is not there.

An arena host also needs the directory and the meta-layer, which are not on it.
`VW_DIRECTORY` and `VW_META` default to loopback and provisioning overrides both
with the front door's public `wss` and `https` on that role alone. The token
travels over TLS, which is what the directory's refusal of credentials in the
clear requires.

The game origin did not move. `play.vectorwake.net` still holds the client, the
directory, and the meta-layer, so the address baked into the client and the
meta url riding the catalog both stay true. The bare site joined the same host
under its own Caddy block and follows it during a DNS cutover.

What is not proven: no host of the `central` or `arena` role has ever booted. All
three shapes parse under compose, all of Caddy's adapt, and the `.env` each role
generates was extracted from a rendered user-data and fed to compose to check it,
but the first real one is stage 3.

## Stage 2: a second directory, and a client that can use one

The directory is the front door, and one of it means an outage stops new
players from finding anything. Two changes, one of them client code:

- A second tiny instance runs a directory from the same image, same catalog.
  Directories never talk to each other; arena servers registering with both
  carry each one's observations to the other, which is the availability model
  [discovery.md](discovery.md) already specifies.
- The client learns a list. `menu.lua` holds a single directory string, so
  today redundancy would be invisible to players, which is the same as not
  having it. Per discovery.md: `directory.vectorwake.net` resolves to every
  directory of the deployment, the client shuffles the records and takes the
  first that answers.

The shared hostname has a certificate consequence: both directory hosts need a
cert for `directory.vectorwake.net`, which means DNS-01 issuance, which brings
back the Caddy DNS build we dropped when the wildcard went. That is a known
build, not new ground.

Ship the client change first. It is protocol-neutral, one address in DNS
behaves exactly as today, and it removes a client release from the critical
path of every directory added later.

Done when: killing either directory leaves the games list working, verified by
actually killing one.

## Stage 3: the first remote arena host

`fleet.sh new arena <name> <region>` is the whole of it, and the list below is
what that one command does rather than a checklist anybody works through:

- Its own hostname and certificate. One name per host, paths per arena under
  it, exactly the pattern the central host uses today. Never a name per
  service: that is the Let's Encrypt rate-limit lesson provision.sh already
  encodes, paid for with an outage.
- `VW_DIRECTORY=wss://directory.vectorwake.net`. The token travels over TLS,
  which satisfies the directory's refusal of credentials over cleartext, and
  the arena advertises its own host's public `wss://` paths in `VW_ADDRESS`.
- Its own bot server, pointed at its own arenas. Bots dial as ordinary
  clients, so a central bot server would pay inter-host egress and latency to
  do a worse job. `VW_ARENAS` is stamped per host by the compose file.
- Its own WebTransport certs and UDP range, terminated by each arena as they
  are today, since the QUIC session is the connection and cannot be fronted.
- Its own `/metrics` routes and its own tunneled admin port.

The directory needs nothing: the browse reply already lists instances by the
address they advertise, and the client already dials whichever it is handed.
If this host belongs to somebody or somewhere new, that is a pool row in the
catalog with its own token and `max_instances`; otherwise the existing pool
grows by one registration.

Done when: browse lists instances on two hosts, a join lands on the remote one
and plays, and pulling the remote host's plug removes its rows and nothing
else. All three checked with `tools/pilot`, which flies real clients.

## Stage 4: ephemeral ports, when a host wants more zones than stanzas

hosting.md prescribes it: an arena binds a free port and reports it, so scaling
a host is `--scale arena=20` with no per-replica configuration. Nothing
implements it yet, and this stage is further away than it used to look.

The reason is that "more arenas" was never how a host grows. An arena process
holds as many rooms of its zone as `max_rooms` allows, opened on demand, so
seats per host is a number in `zone.toml` and a process count is a count of
zones covered. That is rung 2 of the fill ladder doing the work rungs 3 and 4
would otherwise need a second process for. A host runs one arena per catalog
zone today, not because a fixed number of stanzas is the limit.

So this becomes worth building when a host wants more zones than stanzas, or
when one process holding every room of a busy zone is the wrong failure domain,
which is a measurement nobody has taken. It changes addressing: `host:port` directly rather
than a path per arena, which means arenas terminate their own TLS on the ws
listener. The support exists, `tls_cert`/`tls_key` in the zone file already
serve wss, and the WebTransport path already reads certificates off disk, so
this is wiring rather than invention. Caddy keeps the page and the directory
and stops proxying game sockets on such a host.

Done when: one compose service scaled to N registers N instances, and a
process restart re-registers under its persisted instance id with a new port
and strands nobody.

## Stage 5: observability that survives three hosts

Open `/metrics` routes per host stop being readable by eye at three hosts. A
Prometheus on the central host scrapes every host's routes; the per-process
`vw_build_info` rows become the one dashboard that answers "what is actually
deployed where", which this fleet has already needed twice in one day.
Alerting starts minimal: a host not scraped, a directory with zero registered
instances, an arena with a pegged tick. The admin surface stays unrouted and
tunneled, per [admin.md](admin.md).

## Stage 6: a second provider, when the bill says so

The trigger is arithmetic, not ambition. At 200 concurrent players the egress
difference between Vultr and OVHcloud is a rounding error; at 2,000 it is about
$1,400 a month against $8.50. When the bill approaches the first number, add an
OVHcloud pool for European and North American volume and keep Vultr for the
regions OVHcloud cannot serve and for the database. Additive, not a migration:
a pool already carries provider and region, and arenas from different pools
serving one zone is the normal case. The regional traps are recorded in
hosting.md: Australian egress at ten times the base rate, and OVHcloud
Asia-Pacific quotas that throttle past roughly 40 concurrent players.

## What deliberately does not change

No Kubernetes and no load balancer, at any stage. Zone selection is the
scheduler and the directory-plus-client is the balancer for game traffic; DNS
spreads the front door. No service mesh: two wire protocols exist, both over
TLS, both already carrying tokens. The meta-layer and database stay on the
central host's address for as long as `play.vectorwake.net` exists, because the
meta URL rides the catalog and moving it is a catalog version like any other.
And every host of every role keeps deploying by git push through the same
updater, because a deploy step that differs per host is the class of thing this
repository keeps paying to remove.

## The one measurement that reorders this plan

Everything above sizes hosts by 30 KB/s per client, measured in a busy 64-ship
room. Interest management should put a duel far below that; if it lands near
5 KB/s, a thousand concurrent duels fit on one instance's uplink and the
remote-arena stages move out past a second directory in priority. Take that
measurement before sizing anything for duels.
