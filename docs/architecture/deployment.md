# Deployment

Where the fleet in [zones-and-arenas.md](zones-and-arenas.md) actually runs.
[hosting.md](hosting.md) argues for Vultr, Docker and a managed database; this is
the arrangement that follows from those choices, and the parts of it that were
decided by a constraint rather than a preference.

The first deployment is one host. That is a deliberate floor, not an ambition:
one host exercises everything except the fill ladder's fourth rung, and a second
host is a compose service and a DNS record away.

## The shape

```
  play.vectorwake.net, 443             loopback
      /      ──────────────────────►  client/dist/, on disk
      /dir   ──────────────────────►  directory :9000
      /a1    ──────────────────────►  arena     :9001
      /a2    ──────────────────────►  arena     :9002
      (none) ──────────────────────►  admin     :9100   no route in, by design
```

**The client is served from here because it cannot be served from anywhere
else.** A page delivered by a third party under a Content-Security-Policy of
`connect-src 'self'` cannot open a WebSocket to our arenas at all, and the
published artifact is exactly that: it can only ever be the offline practice
arena. Serving the page from the same origin as the game removes the question
entirely.

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

**One hostname, paths underneath.** `play.vectorwake.net` serves the client at
`/`, the directory at `/dir`, and an arena at `/a1` and `/a2`. One port is one
thing to open and nothing between a player and the game objects to it, and adding
an arena is a path rather than a DNS record.

This started as a name per service, which reads better and cost an outage. Caddy
fetches a certificate per name without being told to, a reinstall wipes the volume
holding them, and deploying by reinstall wiped it six times in one day. Let's
Encrypt allows five certificates a week for the same name, so three of the four
ran out and the game went dark -- while the static client kept serving, because
its name was new enough to still have a certificate, and `/health` kept
answering 200 because Caddy was fine. One name means one certificate to lose.

**Deploys are a push, not a reinstall.** A timer on the host converges on what
`main` and the registry say, every minute, and says nothing when neither moved.

It checks both because they move for different reasons. The checkout carries the
compose file, the Caddyfile and the client bundle, all read from disk at container
start; the image carries the binary and the catalog. So it compares the image
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

**One arena server per zone, and never fewer.** A single arena would make zone
selection do nothing: with three, a fresh host comes up serving Chaos, War and
Alpha, chosen between themselves against the same catalog. That is the design
running rather than being asserted, and it costs nothing on a host this size.

Fewer arenas than zones is the failure worth naming, because it looks like
nothing. An arena takes a zone nobody is serving and then stays with it, so the
zone that misses out is listed in the browse reply, joinable in the client, and
served by no process at all. Adding a zone to the catalog means adding an arena
beside it.

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

**The arena needs no certificate.** It serves cleartext on loopback and Caddy is
the wss endpoint, so `VW_ADDRESS` advertises `wss://play.vectorwake.net/a1` for a
process that has never seen a private key.

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

Two tags come out of CI. `sha-<short>` is immutable, and an OCI `revision` label
means `docker inspect` maps a running container back to a commit. `prod` is the
moving pointer the host follows, so a rollback is retagging `prod` at an older
`sha-` and letting the updater converge -- no revert, no rebuild. `VW_IMAGE` pins
a host to one build when that is wanted.

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

Two, both generated per host and neither committed:

- `VW_POOL_TOKEN`, which authorises the arena servers to register. The catalog
  holds only its `sha256:` digest, which is why the digest is safe in git.
- `VW_ADMIN_TOKEN`, which a human holds for the admin surface.

They live in `deploy/.env` at `0600`, written from the instance's user-data.
Anything on the box can read user-data from the metadata service, which is
acceptable because the box is what holds them anyway, and is the reason they are
per host rather than shared. Rotating either is a new token, a new digest for the
pool one, and a restart.

## Running it somewhere else, or locally

```sh
printf 'VW_DOMAIN=localhost\nVW_POOL_TOKEN=...\nVW_ADMIN_TOKEN=...\n' > deploy/.env
docker compose -f deploy/docker-compose.yml -f deploy/docker-compose.local.yml \
    --env-file deploy/.env up -d --build
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

**Reachable from the internet: 22, 80, 443. Nothing else.** The directory,
arenas and admin surface bind loopback; ufw and the Vultr firewall both filter
on top of that. Two of those layers are redundant on purpose, because the first
deploy was lost to believing one of them was the whole story.

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

## What is deliberately not here

No Kubernetes: zone selection is the scheduler, so nothing needs placing. No
Nakama and no Postgres, because the first deployment has no accounts and ratings
still sit on the arena's own disk, which [roadmap.md](roadmap.md) M7.7 is what
changes. No monitoring beyond the metrics in `STATUS` and what the admin page
draws from them, and in particular nothing that plays the game -- every bug found
in the first days of running this was invisible to `/health` and obvious to
thirty seconds of `tools/pilot`, which is the gap most worth closing next.
