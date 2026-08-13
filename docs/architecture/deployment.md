# Deployment

Where the fleet in [zones-and-arenas.md](zones-and-arenas.md) actually runs.
[hosting.md](hosting.md) argues for Vultr, Docker and a managed database; this is
the arrangement that follows from those choices, and the parts of it that were
decided by a constraint rather than a preference.

The first deployment is one host. That is a deliberate floor, not an ambition:
one host exercises the first two rungs of the fill ladder, which are the two
that carry ordinary play, and a second host is a compose service and a DNS
record away. The rungs that need a second process, another instance of the zone
and then a new one, wait for that host. The staged path from this host
to hosts that scale independently is [scaling-plan.md](scaling-plan.md).

## The shape

```
  vectorwake.net, 443                  checkout
      /      ──────────────────────►  deploy/site/

  play.vectorwake.net, 443             loopback
      /      ──────────────────────►  client/dist/, on disk
      /dir   ──────────────────────►  directory :9000
      /meta  ──────────────────────►  meta      :9400
      /a1    ──────────────────────►  arena     :9001   as many rooms as max_rooms
      /metrics/* ──────────────────►  each process     open, loopback ports

  play.vectorwake.net, 9443/udp        direct, no Caddy
      :9443  ──────────────────────►  arena     WebTransport, terminated in-process
```

**The client is served from here because it cannot be served from anywhere
else.** A page delivered by a third party under a Content-Security-Policy of
`connect-src 'self'` cannot open a WebSocket to our arenas at all, so a copy of
the bundle hosted somewhere convenient is a menu listing games it cannot reach.
It used to be a playable practice arena, which made the restriction easy to
forget; since decision 20 there is no game without a server. Serving the page
from the same origin as the game removes the question entirely.

The bundle is built by CI and published as its own image, because building it
needs a JDK, Defold's `bob`, and Defold's remote build server -- three things not
worth putting in a boot path that has no shell. A one-shot container copies it
into a volume Caddy serves and exits.

That indirection buys one thing: a client release never restarts Caddy. Recreating
Caddy severs every WebSocket it is carrying, so baking the page into the Caddy
image would mean a change to a menu label disconnecting everybody mid-match. The
copy is done to a temporary name and renamed, because `mv` inside one filesystem
is atomic and a plain `cp` over a file Caddy is streaming is a truncated bundle.

It was committed to git until CI could build it, and that cost an outage rather
than just history: a commit changed the simulation core, nobody rebuilt the
bundle, and the deployed client read a wire the server had stopped writing. Caddy
still compresses on the way out, 5.2 MB down to 2.9, which matters because egress
is the only cost this deployment has.

Everything runs `--network host`, so the services reach each other on loopback
and only Caddy listens on a public port.

**One game hostname, paths underneath.** `play.vectorwake.net` serves the client at
`/`, the directory at `/dir`, and the arena at `/a1`. One port is one thing to
open and nothing between a player and the game objects to it, and adding an
arena is a path rather than a DNS record.

The bare `vectorwake.net` is a separate static site. It points at the same
central host but has no game routes and no reason to share the client's socket
policy. Caddy reads it from `deploy/site/` in the checkout. A page edit ships
with the updater and does not rebuild the client bundle or restart an arena.

**One arena process, and it is not one room.** A process runs one zone's
configuration and holds as many rooms of it as that zone's `max_rooms` allows,
opened on demand and reclaimed when they empty, so the seats a host offers come
from `zone.toml` rather than from the number of services in the compose file.
The count of processes tracks how many zones a host covers, since an arena
picks a zone nobody is serving and stays with it. It was three when the catalog
held three zones; the catalog holds Alpha alone.

This started as a name per service, which reads better and cost an outage. Caddy
fetches a certificate per name without being told to, a reinstall wipes the volume
holding them, and deploying by reinstall wiped it six times in one day. Let's
Encrypt allows five certificates a week for the same name, so three of the four
ran out and the game went dark -- while the static client kept serving, because
its name was new enough to still have a certificate, and `/health` kept
answering 200 because Caddy was fine. One name means one certificate to lose.

**A host is one of three shapes, and today one host is all of them.** The
processes are split across compose files by what they are: `caddy.yml` is the
proxy, which every host runs; `central.yml` is the front door, the directory a
player browses, the meta-layer they sign in to, and the game page itself;
`arena.yml` is the games and the bots that fill them. A role is which of those
a host runs, and it reaches the host as `COMPOSE_FILE` in the generated `.env`,
so nothing else on the box has to know: provisioning, the updater and a command
typed by hand all say `docker compose --env-file .env` and get the right shape.

The name follows the same rule. `VW_HOST` is the game name a host *serves*, which is
not the machine it is: a central host answers for `play.vectorwake.net`
whichever instance is underneath it, because that address is in the catalog's
meta url and baked into the client, so a rebuild moves a DNS record rather than
a client release. An arena host serves its own name and has a certificate
within a minute of booting. `VW_ROUTES` picks the matching Caddy snippets out
of `deploy/caddy/conf.d`, which is why an arena host has no `/dir` route at all
rather than one pointing at a directory that is not there.

`VW_SITE_HOST` names the bare site on a central host. `fleet.sh point play`
moves its apex record and the admin record beside the game name, so rebuilding
the central host cannot leave either static surface on the old address.

**Deploys are a push, not a reinstall.** A timer on the host converges on what
`main` and the registry say, every minute, and says nothing when neither moved.

It checks both because they move for different reasons. The checkout carries the
compose files, the Caddy config and the client bundle, all read from disk at
container start; the image carries the binary and the catalog. So it compares the image
digest rather than blindly pulling and recreating -- `prod` is retagged on every
push to main, including pushes that build byte-identical images, and recreating
containers for an unchanged digest would restart live games for nothing.

Measured while the host still built its own binary: a push at 04:09 was live at
04:10:15, about fifty seconds, with both zones verified and serving either side
of it. That is what makes the certificate paragraph above safe rather than merely
survived: a converge touches the checkout and the containers and nothing else, so
certificates, ACME account keys and arena instance ids all persist. Compose
recreates only what changed, so a server-image change does not restart Caddy and
therefore cannot disturb TLS. Reinstall is for changing the provisioning script
itself, and each one costs a certificate.

**One arena server per zone, and never fewer.** An arena takes a zone nobody is
serving and then stays with it, so this is the count that matters and the only
one. Fewer arenas than zones is the failure worth naming, because it looks like
nothing: the zone that misses out is listed in the browse reply, joinable in the
client, and served by no process at all. Adding a zone to the catalog means
adding an arena beside it, which is a stanza in `docker-compose.arena.yml`, a
path in `caddy/conf.d/arena.caddy`, and a UDP port in both firewalls.

Not one per room, which is the mistake the other direction and the one this file
made for a while. The catalog held three zones once, the compose file grew three
arenas, and when Chaos and War went nothing re-derived the number, so two
processes sat covering zones that no longer existed. Seats come from `max_rooms`
inside a process, not from processes.

## What choosing Caddy decided for us

**The directory must bind loopback.** It refuses a credential offered over
cleartext unless the peer is loopback, and behind a reverse proxy every peer *is*
loopback. TLS still protects the token, because Caddy terminates it, but the
directory can no longer tell the difference. So a public port on 9000 would be a
pool token accepted in the clear from anyone who asked. Binding `127.0.0.1:9000`
closes that and costs nothing, since Caddy is on the same host.

**The ephemeral-port plan is not needed yet.** [hosting.md](hosting.md) wants an
arena to bind port zero and report what it got, so that scaling needs no
per-replica configuration. With a fixed port and a path per arena that problem
does not arise, and the code cannot do it anyway: the advertised address
is the string the process was given, so `:0` would advertise port zero. The gap
stays open, and it becomes real the first time one host runs more arenas than
anybody wants to name.

**The arena needs no certificate for the WebSocket.** It serves cleartext on
loopback and Caddy is the wss endpoint, so `VW_ADDRESS` advertises
`wss://play.vectorwake.net/a1` for a process that has never seen a private key.

**The WebTransport door is the exception, and it borrows rather than owns.**
Caddy cannot front QUIC the way it fronts the socket: a WebTransport session
is the HTTP/3 connection itself, not an upgrade a proxy can pass along. So
each arena terminates QUIC on its own public UDP port, 9443 for the first, and
reads the certificate out of Caddy's own store, mounted read-only into the
container. `VW_WT_CERT` and `VW_WT_KEY` are glob patterns because the store
nests the PEM pair under the ACME issuer's directory name, which is Caddy's
choice and has changed before; the arena picks the newest match, re-reads on
a timer so a renewal lands without a restart, and simply waits when a fresh
host has no certificate yet. The one ACME account, the one certificate, and
the rate-limit arithmetic in the Caddyfile all stay exactly as they were:
nothing here asks Let's Encrypt for anything.

A host provisioned before that port existed needs it opened in both firewalls,
once. On the host:

```sh
ufw allow 9443/udp
```

And in the Vultr firewall group the instance belongs to, UDP 9443 from
anywhere. Opening one and not the other looks exactly like opening neither,
because the arena binds its endpoint either way and reports itself listening.

`provision.sh` carries the same rule for every host built after it, but it
runs at first boot and the updater never re-runs it: a deploy is a `git reset`
and a `compose up`, which is what keeps a release off the certificate rate
limit and is also why nothing in a release can open a port. Until the rule is
added the arenas bind the door and nothing reaches it, so every client waits
three seconds and falls back to the WebSocket. That is the designed failure
and it costs a player nothing, which is exactly why it can go unnoticed:
the symptom of a closed port here is a game that works.

## The admin surface is not routed

[admin.md](admin.md) says a secret in a file is not enough to put it on the
public internet, and its read view needs no token at all, so a route to it would
hand a stranger the fleet. It listens on loopback and is reached through a
tunnel:

```sh
ssh -L 9100:127.0.0.1:9100 root@<host>    # then http://127.0.0.1:9100
```

## Provisioning, with nobody logged in

`deploy/cloud-init.yml` is the host's entire configuration, run once at first
boot: swap, Docker, a clone of this repository, the tokens, and `docker compose
up`. There is no second step done by hand, so rebuilding the box is one API call
rather than a remembered sequence.

Two things about it are shaped by a constraint rather than taste.

**The host runs a published image and compiles nothing.** It used to compile the
server itself, for one reason: pushing to a registry needs a credential the
machine doing the deploy did not have. GitHub Actions has one for free, so
`.github/workflows/image.yml` builds `ghcr.io/criccomini/vectorwake` and the host
pulls it.

What that reason cost while it stood is worth recording, because it is the shape
of every build-on-the-box arrangement. A ten-minute first boot; a 2 GB instance
rather than a 1 GB one, because cargo linking tokio and rustls was the peak
memory of the whole host's life and a linker killed by the OOM reaper is the
worst failure available on a box nobody can log into; 2 GB of swap on top for the
same reason; and a Rust toolchain and a C compiler sitting on a public-facing
machine for the rest of its life. Measured at the end: a source change took ten
minutes to deploy, against the fifty seconds a cached layer managed, and every
one-line fix paid the full price.

The instance outlived the reason for it. Nothing re-derived the size once the
build left, so 2 GB stood for a while as the answer to a question nobody was
asking any more. Measured on the running host instead: the four game processes
total 70 MB resident, about 110 MB with all three arenas serving rather than
one, and Docker, Caddy and the base system bring it near 400 MB. New hosts are
1 GB, with the same 2 GB of swap underneath, which is the part of that paragraph
that was never about compiling.

Per client the cost is small, and measured rather than argued: the bot server
holds 153 connections in 28 MB, so a full 64-player room adds ten or fifteen
megabytes. What actually decides an arena host's size is its uplink, per
[hosting.md](hosting.md).

Both workflows publish `sha-<short>` for every commit on main. The tag is
immutable, and an OCI `revision` label means `docker inspect` maps a running
container back to a commit. The updater pulls the server and client tags for the
same commit before it changes the checkout or containers. A workflow that
finishes first waits for its pair instead of creating a mixed release. The
moving `prod` tags remain for local and manual work; production exports the two
immutable image names.

**Caddy starts before the build, and serves the deploy log.** That inverts the
obvious order on purpose. The proxy needs none of our code, so it is up in
seconds and answers on the raw IP over plain http for the ten minutes the build
takes:

```
http://<ip>/deploy/status       coarse progress, one line per step
http://<ip>/deploy/update.log   what the updater did, after provisioning
https://play.vectorwake.net/health   Caddy, and only Caddy, once DNS is live
```

That window, before DNS has propagated and a certificate exists, is exactly when
a fresh host is least diagnosable and most likely to be broken. Nothing secret is
written there, because anyone can read it.

`/health` is plain HTTP for a related reason: everything else here is a WebSocket
upgrade, which plenty of networks and proxies decline to carry, and "cannot
connect" is a useless symptom when the cause could be DNS, the certificate,
Caddy, the firewall, or the game.

It answers `caddy up; this says nothing about the game`, at length and on
purpose. It used to answer `ok`, which is indistinguishable from "the service is
up" -- it answered 200 throughout a reinstall with no game running at all, and
its own author read it as healthy an hour after writing it. A health endpoint that
can only see the proxy should say so in the body.

## DNS

`vectorwake.net` is registered at name.com and delegated to Vultr's nameservers,
so records are an API call rather than a form. Delegation is the only step in
this document that has to be done by hand, and the order matters: the zone exists
at Vultr **before** the nameservers point at it, or resolvers get an outright
failure for as long as it takes somebody to notice.

Caddy uses HTTP-01 for certificates, not DNS-01, so it needs no credential for
any of this. It only needs the A records to be right and port 80 reachable.

## Secrets

Three, none committed. One is minted per host:

- `VW_POOL_TOKEN`, which authorises the arena servers to register. The catalog
  holds only its `sha256:` digest, which is why the digest is safe in git.

Two belong to the deployment rather than to any host, so they are supplied
rather than generated:

- `VW_META_DATABASE`, the managed database's connection string with its user and
  password inline. One database however many hosts read it.
- `VW_META_KEY`, the meta-layer's signing half. Its other half is the catalog's
  verifying key and is committed, so minting one per host would give that host a
  private world no other arena can verify a token against.

`VW_ACCOUNTS=0` is how a deployment says it keeps no accounts. Without it an
empty database is a refusal to start rather than a fleet that comes up healthy
with every pilot a guest, no rating kept, and nothing on fire to say so. That is
not hypothetical: the two meta values were live and undocumented for a while,
held only in the `.env` on one box, having been pasted there after it booted.
Anything that rebuilt the host would have lost accounts silently.

They live in `deploy/.env` at `0600`, written from the instance's user-data.
Anything on the box can read user-data from the metadata service, which is
acceptable because the box is what holds them anyway, and is the reason the pool
token is per host rather than shared. Rotating it is a new token, a new digest,
and a restart.

## Running it somewhere else, or locally

```sh
printf 'VW_HOST=play.localhost\nVW_POOL_TOKEN=...\n' > deploy/.env
docker compose -f deploy/docker-compose.caddy.yml \
    -f deploy/docker-compose.central.yml -f deploy/docker-compose.arena.yml \
    -f deploy/docker-compose.local.yml --env-file deploy/.env up -d --build
```

The overlay exists for name resolution: Caddy routes by hostname, and glibc does
not resolve `*.localhost` however much it looks like it should.

One thing local testing cannot cover. The directory's address check dials the
public `wss://` address the way a player would, and locally that certificate is
Caddy's own internal CA, which the directory does not trust and should not. So
both arenas stay unverified and the browse reply offers nothing while every game
is in fact running. The check reports the reason now (`UnknownIssuer` for exactly
this case), because that symptom is otherwise indistinguishable from four other
causes.

## Security posture

What a stranger can reach, what each layer is for, and the risks that are
accepted rather than closed. Checked against the live host from outside, not
asserted from the config.

**Reachable from the internet: 22, 80 and 443, and UDP 9443.** The
directory, the meta-layer and the admin surface bind loopback; the arena binds
loopback for its WebSocket and Caddy is the only way in. Its WebTransport
endpoint is the exception, and the only part of this fleet a stranger reaches
without passing through Caddy: QUIC cannot be proxied, so each arena terminates
its own. What that exposes is the same protocol the WebSocket already serves,
bounded the same way, plus two limits the transport needs of its own: a
reliable-stream frame is refused above the same 8 KB a WebSocket frame is, and
a session that does not open its stream within five seconds is closed, so a
port scanner cannot hold tasks open by connecting and saying nothing.

ufw and the Vultr firewall both filter on top of that, and **both have to be
opened.** Two layers are redundant on purpose, because the first deploy was
lost to believing one of them was the whole story, and the WebTransport ports
cost an evening to the same mistake in the other direction: ufw was opened, the
arenas reported their endpoints bound and listening, and every browser still
fell back to the socket, because the cloud firewall in front of the host was
still dropping UDP and nothing in the fallback can tell that apart from a
network that simply cannot carry QUIC. `vw_wt_attempts_total` is what tells
them apart now: zero of it, against a client that waited and gave up, means
the packets never arrived.

**What an unauthenticated stranger can do** is speak the client protocol to
Caddy. That surface is bounded: incoming WebSocket frames are capped at 8 KB on
the game port and 64 KB on the registration port (the library default is 64 MiB,
buffered in full), the per-connection outbound queue is bounded, and a call sign
is reduced to printable ASCII and 24 characters before it can reach a roster,
the kill feed, the logs, or the ratings file. A newline in a name is a forged
log line; the sanitizer is what stands in front of that.

**Containers run with every capability dropped** and `no-new-privileges`, except
Caddy, which keeps exactly `NET_BIND_SERVICE` for ports 80 and 443. The point is
the C simulation core: it parses operator content, not player bytes, but it is
the one memory-unsafe thing in the stack, and a host-network container with
root's default capabilities would make a bug in it a bug on the host.

**Secrets.** The pool token and admin token live in `deploy/.env` (0600, root)
and the read-only deploy key in `/root/.ssh` (0600). They arrive via instance
user-data, which anything on the box can read back from the metadata service --
so after provisioning succeeds, user-data is overwritten with a stub through the
API. The tokens on disk are the box's own credentials; the scrub is what keeps
them from being readable by any unprivileged process that can open a socket to
169.254.169.254. Rotation is: new token, new digest in the catalog, redeploy.

**Accepted, with reasons:**

- *SSH on 22 with root password auth.* The Vultr console needs no SSH, but the
  admin surface is reached by SSH tunnel, and disabling password auth with no
  key installed locks the operator out. Vultr's generated root passwords are
  long and random, so brute force is impractical rather than impossible. The
  right fix is an operator SSH key and `PasswordAuthentication no`, which needs
  a key we do not hold.
- *Verification is a blind dial.* A token-holding operator can point their
  claimed address at anything, and the directory will connect to it and send a
  status request. It follows no redirects, discloses nothing, and the caller
  learns only verified-or-not, so the worst case is a GET-shaped knock on a
  door the operator names. Restricting targets would break the local overlay
  and buys little against a party the token table already trusts.
- *Names are not identity.* Anyone can join as any name, including a staff
  name. Capabilities are checked against the admin token and the catalog's
  staff table, never against an in-game name, so impersonation grants nothing;
  it is still impersonation, and it ends when identity lands (decision 11).
- *The deploy log is public.* `/deploy` on plain HTTP serves provisioning
  progress and the build log to anyone. It is written to hold no secrets --
  checked, not assumed -- because a box that cannot report its own failure gets
  debugged by guessing.

## Every process says what it costs

Each service serves Prometheus text on its own loopback port when `VW_METRICS`
names an address, and opens no port at all when it does not.

| Port | Process |
|---|---|
| 9101 | the arena, and 9102 up for any beside it |
| 9105 | the bot server |
| 9106 | the directory |
| 9107 | the meta-layer |

9100 is missing from the list because the admin surface has it.

Caddy publishes them at `/metrics/a1`, `/metrics/bots`, `/metrics/dir` and
`/metrics/meta`, open to anyone. The ports themselves stay on loopback, so those
routes are the only way in.

They carried a `basic_auth` once, on the argument that a read view is the
dangerous kind to publish because it is useful without a token. The password
came off: what these expose is population, capacity and build stamps, which the
games list already hands to any client, and a credential nobody uses is pure
friction against pointing a dashboard at them. The admin surface remains the
line that matters, and it is not routed at all.

The reason it is per process rather than per host is an afternoon spent on the
wrong question. A host graph showed a pegged core and could not say which of
six processes held it, so the answer came from arithmetic and a commit message
instead. The bot server, which turned out to be the larger half, was the one
process with nothing to ask at all. So every process reads its own
`/proc/self` and reports its own processor time, which makes attribution exact
and costs no agent and nothing to keep in step.

What each one carries beyond the standard process numbers: an arena its tick
time, populations, sockets, snapshot bytes and dropped sends; the bot server
its pilots and the arena connections it has opened; the directory what it has
registered and what it turned away.

Tick time is a histogram rather than a number, and that is the same lesson
twice. `STATUS` reports the last tick, and one reading of an arena said 2300
microseconds against 150 next door, which read as one room costing fifteen
times its neighbours. Twelve readings put its median at 289. The 2300 was
real: it was the tick every two seconds that also rebuilds the roster, and a
point sample of a periodic process finds it eventually. Buckets cannot be
caught out that way.

Counters that would always read zero are not here. A metric nobody incremented
does not say "nothing happened", it says nothing, and the two look identical
on a graph.

## Deploys are marked in the binary

Every process reports `vw_build_info{commit=...}`, stamped into the image at
build time from the same short sha the image is tagged with. So the question
that gets asked during an incident, whether the thing running now is the thing
that was running an hour ago, has an answer that does not involve `docker
inspect` or reading a log.

Stamped into the image and deliberately not passed in as an environment
variable. Compose recreates a container whose configuration moved, so a commit
in the environment would restart every service on every push, Caddy included.
Caddy restarting is how this game once spent three of its five weekly
certificate issuances and went dark. An image only replaces the containers
whose image changed, which is exactly the set with new code in them.

`server/build.rs` declares `rerun-if-env-changed=VW_COMMIT`, because
`option_env!` is resolved at compile time and cargo will otherwise serve a
cached build. Without that line the stamp is whatever it was when the source
last changed, which is a deploy marker that lies.

The updater's own log at `/deploy` is still the other half of this, and stays:
it says when a deploy landed, where the metrics say what is running now.

## What is deliberately not here

No Kubernetes: zone selection is the scheduler, so nothing needs placing.

No collector, no dashboards and no alerts yet. Every process exposes its
numbers, above, and nothing gathers them: a scrape is a `curl` from the host.
That is a deliberate stopping point rather than an unfinished one. The endpoint
is the part that cannot be added later from outside, and a number nobody is
recording is still a number somebody can read while something is going wrong.

And nothing that plays the game, which is still the gap most worth closing.
Every bug found in the first days of running this was invisible to `/health`
and obvious to thirty seconds of `tools/pilot`.

The meta-layer used to be on this list, on the grounds that the first
deployment had no accounts and ratings sat on the arena's own disk. Both halves
of that stopped being true when accounts landed: there is a `meta` container
here now and a bought database behind it, per
[meta-layer.md](meta-layer.md).
