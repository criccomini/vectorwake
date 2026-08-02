# Discovery

How an arena server gets listed, how a player finds one, and who is trusted with
what. The structural argument for this shape is in
[zones-and-arenas.md](zones-and-arenas.md); this document is the protocol and the
trust model.

## Push, not poll

Today a directory reads a hand-written list of addresses from `directory.toml`
and polls each one every ten seconds. Adding a zone means editing that file and
restarting the directory, because `Directory::load` runs once before the accept
loop and never again.

Arena servers register instead. Each connects to every directory it knows,
presents a credential, and holds the socket open. The entry lives as long as the
connection, which buys three things the poll cannot: a listing appears the
moment an arena is ready, player counts arrive when they change rather than up to
ten seconds late, and an arena that dies is delisted immediately instead of
lingering as a row that nobody can join.

Registration state is therefore a held socket and a local file, and never a
database. That is what lets a deployment run several directories with no shared
storage and no agreement between them.

A registered-but-disconnected arena is dropped rather than shown as down. The
"not answering" row in today's code is an artifact of the poll model, and a
restart blinking out of the list for three seconds costs a player nothing.

## The poll survives as verification

Push tells a directory that an arena is alive and how full it is. It does not
establish that the address the arena reported is an address that works, or that
anything at it speaks our protocol. A self-reported address is a redirect: a
credentialed arena could point its listing at a third party.

So `directory::poll` keeps its job, with a different name for it. On
registration, and periodically after, the directory connects to the claimed
address, sends `C2S_STATUS`, and requires a well-formed `S2C_STATUS` back. An
arena that fails verification is registered but not listed. This is the same
check a client is about to perform, run by the party that has a reason to care,
and it means an operator can move hosts without asking anyone for a new
credential.

## Credentials

A directory holds a table of rows rather than a set of interchangeable
passwords:

```toml
name = "vectorwake"
catalog = "catalog.toml"                 # the zones this directory serves

[[pool]]
name  = "us-east pool"                   # the directory names it, not the pool
token = "sha256:9f86d081884c7d65..."     # hashed at rest
region = "us-east"
max_instances = 20
```

A single shared secret stops strangers registering but does nothing about a
credentialed party registering *as somebody else*. Per-row credentials fix
three things at once: the name comes from our side of the table so
impersonation is structurally impossible, revocation is one row rather than a
rotation across the fleet, and a leaked token costs one pool's listing.

The name labels an operator's pool in the admin surface and is never shown to
players, who see zones. One token therefore authorises many instances, which is
what makes horizontal scaling a matter of raising a replica count, and it says
nothing about which zone any of them serves: pools are capacity, zones are games,
and the two groupings cut across each other. `max_instances` bounds what a
compromised token can do.

Tokens are generated (`vectorwake-server token`), never typed. Hashing at rest
is only worth anything if the input carries real entropy, and an operator left
to invent a token will invent a short one. Hashing means a directory's
configuration can be committed and shared without handing out working
credentials, at the cost of a lost token being reissued rather than recovered.
Compare in constant time; it is one line and the argument against is only that
the attack is impractical anyway.

**Registration requires TLS.** A bearer token over plain `ws://` is a token
given to everyone on the path. The directory refuses a credential offered over a
cleartext connection from a non-loopback peer, rather than accepting it and
hoping. `run_directory` currently binds a bare `TcpListener`, so this means
reusing the `tls_acceptor` the arena side already has.

**Keep tokens out of the arena's config file.** With several directories an
arena holds several secrets, and its config file is exactly what an operator
pastes into a bug report. `token = "env:VW_TOKEN_MAIN"` or a `token_file` path
costs a few lines and makes the config safe to hand around.

**Newest registration for a token wins**, and the older socket is dropped. A
half-open TCP connection outliving a restart is ordinary, and locking an arena
out of its own pool because of one would be a self-inflicted outage.

## Identity of an instance

Each arena server mints a random id at first boot and persists it, so a restart
keeps its identity. The id is not derived from the token, because many instances
share a token and the point of the id is to tell them apart.

That id is load-bearing in two places. Unioning observations from several
directories requires deduplicating, and an address cannot do it because
addressing can legitimately differ per directory. And it is what makes
client-side merging of directory lists viable, so neither arenas nor clients
need to trust one directory's account of another's.

## The registration channel

A separate message space from the client protocol, since the direction and the
role differ, and one that can afford to be verbose: this channel carries a
handful of messages a second between servers, not snapshots at 20 Hz to
thousands of clients. So the bodies are JSON behind a one-byte tag, which is the
same shape the browse reply already uses and costs nothing anybody will measure.

The tags live in their own space starting at 0x40, far from the client protocol's
1 to 10, so a message arriving on the wrong socket is a recognisable mistake
rather than a plausible one.

Arena to directory:

| Tag | Message | Body |
|---|---|---|
| `0x40` | `REGISTER` | `{token, instance, address, region, pool_hint, willing, version}` |
| `0x41` | `STATUS` | `{zone, players, bots, rooms, metrics{tick_us, bw_per_player, snapshot_bytes, queue_depth, lag_actions}}` |
| `0x42` | `INTENT` | `{zone, expires_ms}` |
| `0x43` | `ACK` | `{command_id, outcome, detail}` |

Directory to arena:

| Tag | Message | Body |
|---|---|---|
| `0x50` | `ACCEPTED` | `{pool, catalog_version, catalog, verified}` |
| `0x51` | `REJECTED` | `{reason}` where reason is `unknown_token`, `pool_full`, `unverified`, `bad_address`, `version_unsupported` |
| `0x52` | `VIEW` | `{observed_at, instances:[{instance, zone, players, region, intent, observed_at}]}` |
| `0x53` | `CATALOG` | `{catalog_version, catalog}` |
| `0x54` | `COMMAND` | `{command_id, verb, args, actor}` where verb is `kick`, `drain`, `pin`, `unpin`, `restart` |

Field notes, in the order they bite:

`instance` is the id from the section above, minted once and persisted. `address`
is what a client should dial, host and port, and it is a claim the directory
verifies rather than a fact it accepts. `region` is self-reported and only ever a
preference, so lying costs the liar placement.

`pool_hint` exists because one token authorises many instances and an operator
running two blocks on one credential wants to tell them apart in the admin view.
It is a label, never an authorisation: the pool name in `ACCEPTED` comes from the
token row and is the one anything else uses.

`willing` is the list of zones this instance will serve, defaulting to all of
them, which is what a block of identical containers wants. It covers
heterogeneous hardware and an operator who only wants to host one game.

`version` on `REGISTER` is the registration protocol's own version, answered with
`version_unsupported` rather than by guessing. This is the one field whose
absence would make every later change a flag day.

`intent` in `VIEW` is what makes the announce step of zone selection work: an
arena server can see what its peers propose to become, not only what they are.
It carries the announcing instance's own expiry, so a crashed announcer stops
blocking a zone once its `expires_ms` passes rather than holding a reservation
forever.

`ACK` closes the loop on commands so [admin.md](admin.md)'s audit trail has both
ends. `outcome` is `done`, `refused` or `unknown_verb`, and `unknown_verb` is
what lets a directory be newer than an arena without either pretending.

## Framing and cadence

One WebSocket binary message per protocol message, tag byte then JSON. No length
prefixes and no fragmentation of our own, because the transport already frames.

The arena sends `STATUS` when its player count changes and at least every five
seconds regardless, so a directory can distinguish a quiet room from a wedged
process. A directory sends `VIEW` when anything in it changes and at least every
five seconds likewise. Both sides treat thirty seconds of silence as a dead peer
and close, which is short enough that a delisting is prompt and long enough that
a garbage-collection pause is not fatal.

The arena reconnects with exponential backoff from one second to a minute, with
jitter, and keeps serving throughout. Losing every directory is not an outage for
the players already in a room.

## The browse reply

A client sends `C2S_STATUS` as it does today and gets `S2C_STATUS` back, so the
tag and the direction are unchanged. What grew is the body, because a player now
picks a game rather than a server:

```json
{
  "name": "vectorwake",
  "catalog_version": 37,
  "zones": [
    {"name": "chaos", "description": "...", "players": 41, "bots": 6,
     "instances": [
       {"address": "wss://a3.us-east.example:9010", "region": "us-east",
        "players": 22, "full": false},
       {"address": "wss://a7.eu-west.example:9010", "region": "eu-west",
        "players": 19, "full": false}
     ]},
    {"name": "duel", "description": "...", "players": 4, "bots": 0,
     "instances": [...]}
  ]
}
```

Per-zone totals so the list can be drawn without arithmetic, and the instances
underneath so the client can choose. `full` is the directory's summary of whether
a join would be refused, which saves a client a round trip it would otherwise
spend learning the same thing.

The client caches this and may use a stale copy. Under assignment a directory
outage would block every join including joins to rooms running perfectly well;
reporting instead of routing means the addresses in a stale list still work, and
a refusal is just a reason to try the next one.

## What a directory may relay

**Only what it observed itself.** A directory forwards registrations it holds
and counts it verified, never another directory's account of a third party.

Without that rule a single arena server poisons the shared picture by claiming
Alpha holds five hundred players, and every other one avoids Alpha. With it, the
worst available lie is about the liar's own numbers, and both directions of that
lie are self-limiting: claim to be full and nobody is routed to you, claim to be
empty and players arrive to be turned away. Region is self-reported for the same
reason and only ever used as a preference, so a lie about it costs the liar
placement.

A directory operator, by contrast, is trusted. They hold the token table, they
serve the catalog, and they can send commands, so a compromised directory can
mislead its own arena servers and its own players. Splitting a deployment's
directories across operators does not divide that trust, it multiplies it. This
is inherent rather than a gap to close.

## Several directories

Two different things share one mechanism, and they behave differently enough to
keep apart.

*Replicas* are several directories of one deployment: same catalog, same token
table, for availability. Because registration is a socket and the token table is
a file, replicas need no consensus, no gossip and no shared storage. They will
report slightly different player counts at any instant, which nobody notices.

*Federation* is somebody else's deployment: their catalog, their zones, their
tokens, their arena servers. The mechanism is identical, and it is what keeps the
ecosystem from being ours alone.

Load is not the argument for either. A directory serving fifty arena servers
sends about six kilobytes of JSON per browse and holds idle sockets the rest of
the time; one small host absorbs every player we are going to get. The arguments
are that the directory is the front door, so its outage stops new players from
finding anything, and that a list nobody else can run is a list we own.

Directories never connect to each other. An arena server registered with several
carries each one's observations to the others, so the shared picture propagates
through the workers. Completeness therefore depends on registration overlap,
which makes the natural configuration every arena server registering with every
directory of its deployment.

## The client

The client needs a list of directories, not one address. `menu.lua:44` holds a
single string and `browser.connect` takes a single address, so redundancy would
currently be invisible to players, which is the same as not having it.

Ship a short list, shuffle it at use, take the first that answers. The shuffle
is the load spreading, and it needs neither a DNS failover window nor a load
balancer that reintroduces the single point. An operator override for pointing
at their own directory stays.

A client may also union across directories, since instance ids make
deduplication well defined. That gives a complete picture without either
directory trusting the other, and at two or three directories it costs a couple
of extra sockets per browse. Failing over to one complete-enough list is the
simpler default; unioning is available when a deployment's registration overlap
is poor.

The browse reply grows from a list of addresses into the catalog plus the live
arena list, because a player now picks a game rather than a server. `Status`
carrying `arenas: u32` was all a one-room-per-process zone could say.

There is no global registry of directories. A player reaches one because the
client
ships its directory addresses or because somebody handed them one, and we are
not building the thing that would list every fleet.
