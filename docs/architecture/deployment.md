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
                     443 (wss)                    loopback
  player ───────────────────────► Caddy ──────────────────────► directory :9000
                                    │                           arena a1 :9001
  directory.vectorwake.net ─────────┤                           arena a2 :9002
  a1.vectorwake.net ────────────────┤                           admin    :9100
  a2.vectorwake.net ────────────────┘                              (no route in)
```

Everything runs `--network host`, so the services reach each other on loopback
and only Caddy listens on a public port.

**Routing is by hostname on 443, not a port per arena.** One port is one thing to
open, and nothing between a player and the game objects to it. Adding an arena is
a name and a compose service rather than a port negotiation, and Caddy issues a
certificate per name without being told to.

**Two arena servers, not one.** A single arena would never make zone selection
do anything: with two, a fresh host comes up with one serving Chaos and the other
War, chosen between themselves against the same catalog. That is the design
running rather than being asserted, and it costs nothing on a host this size.

## What choosing Caddy decided for us

**The directory must bind loopback.** It refuses a credential offered over
cleartext unless the peer is loopback, and behind a reverse proxy every peer *is*
loopback. TLS still protects the token, because Caddy terminates it, but the
directory can no longer tell the difference. So a public port on 9000 would be a
pool token accepted in the clear from anyone who asked. Binding `127.0.0.1:9000`
closes that and costs nothing, since Caddy is on the same host.

**The ephemeral-port plan is not needed yet.** [hosting.md](hosting.md) wants an
arena to bind port zero and report what it got, so that scaling needs no
per-replica configuration. With hostname routing and a fixed port per arena that
problem does not arise, and the code cannot do it anyway: the advertised address
is the string the process was given, so `:0` would advertise port zero. The gap
stays open, and it becomes real the first time one host runs more arenas than
anybody wants to name.

**The arena needs no certificate.** It serves cleartext on loopback and Caddy is
the wss endpoint, so `VW_ADDRESS` advertises `wss://a1.vectorwake.net` for a
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

**The host compiles the server itself.** There is no image registry in the
picture, because pushing to one needs a credential that the machine doing the
deploy did not have, and the repository is public so a clone costs nothing. The
consequence is a ten-minute first boot and a 2 GB instance rather than a 1 GB
one: `cargo` linking tokio and rustls is the peak memory of the whole host's
life, and a linker killed by the OOM reaper is the worst failure available on a
box nobody can log into. 2 GB of swap on top, for the same reason.

**Caddy starts before the build, and serves the deploy log.** That inverts the
obvious order on purpose. The proxy needs none of our code, so it is up in
seconds and answers on the raw IP over plain http for the ten minutes the build
takes:

```
http://<ip>/deploy/status      coarse progress, one line per step
http://<ip>/deploy/build.log   the build, if it failed
https://directory.vectorwake.net/health   the chain up to Caddy, once DNS is live
```

That window, before DNS has propagated and a certificate exists, is exactly when
a fresh host is least diagnosable and most likely to be broken. Nothing secret is
written there, because anyone can read it.

`/health` is plain HTTP for a related reason: everything else here is a WebSocket
upgrade, which plenty of networks and proxies decline to carry, and "cannot
connect" is a useless symptom when the cause could be DNS, the certificate,
Caddy, the firewall, or the game.

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

## What is deliberately not here

No Kubernetes: zone selection is the scheduler, so nothing needs placing. No
image registry, per above. No Nakama and no Postgres, because the first
deployment has no accounts and ratings still sit on the arena's own disk, which
[roadmap.md](roadmap.md) M7.7 is what changes. No monitoring beyond the metrics
in `STATUS` and what the admin page draws from them.
