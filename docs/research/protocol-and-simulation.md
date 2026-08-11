# Wire protocol, units, and the trust model

Everything here was read out of the ASSS source (`src/packets/`, `src/core/`),
the nullspace client (`src/null/`), and the packet tables at twcore.org. Where
the three disagreed we took the code.

## Transport

UDP, with a reliability layer built on top. Core packets begin with a `0x00`
byte; everything else is a game packet.

| Core | Purpose |
|---|---|
| `0x01` / `0x02` | Encryption request and response. Protocol version distinguishes VIE (`0x0001`) from Continuum (`0x0010`, `0x0011`) |
| `0x03` / `0x04` | Reliable message and ack. The sender keeps a send log until the matching ack arrives |
| `0x05` / `0x06` | Time sync request and response, carrying timestamps and packet counts both ways |
| `0x07` | Disconnect |
| `0x08` / `0x09` | Small chunk body and tail, for data split across packets |
| `0x0A` .. `0x0C` | Huge chunk transfer, with total length up front, plus cancel and cancel-ack |
| `0x0D` | No-op |
| `0x0E` | Cluster: several game packets in one datagram, each prefixed by a length byte, up to 512 bytes |
| `0x10` .. `0x13` | Continuum encryption and key expansion |

Two properties of this design carried the game. Reliability is per-message and
opt-in, so position updates never block behind a lost chat line. Clustering
amortizes the UDP header across the many small packets a busy arena generates.

Time sync is explicit rather than inferred. Both sides exchange timestamps and
packet counts, which is what makes the lag measurements in `asss-server.md`
possible at all.

## Game packets

The client sends, among others: `0x01` arena login, `0x03` position, `0x05`
death, `0x06` chat, `0x07` take prize, `0x0F` frequency change, `0x10` attach
request, `0x13` flag request, `0x18` set ship, `0x1C` drop brick, `0x1F` fire
ball, `0x21` soccer goal scored.

The server sends: `0x01` player id, `0x03` player entering (several stacked into
one packet, parsed in 64-byte chunks), `0x04` player leaving, `0x05` large
position, `0x06` death, `0x07` chat, `0x08` prize, `0x09` score update, `0x0F`
arena settings, `0x12` flag position, `0x14` create turret, `0x28` small
position, `0x29` map information, `0x2A` compressed map, `0x35`/`0x36` LVZ
toggle and modify, `0x3B` redirect.

The position packet is the hot path and it is dense:

```c
struct S2CWeapons {
    u8  type;        /* 0x05 */
    i8  rotation;    /* one of 40 discrete headings */
    u16 time;
    i16 x;           /* pixels */
    i16 yspeed;      /* pixels/second/10 */
    u16 playerid;
    i16 xspeed;
    u8  checksum;
    u8  status;      /* stealth, cloak, xradar, antiwarp, flash, safety, ufo */
    u8  c2slatency;
    i16 y;
    u16 bounty;
    struct Weapons weapon;      /* 2 bytes */
    struct ExtraPosData extra;  /* 10 bytes, optional */
};
```

Weapons ride inside the position packet rather than travelling separately, which
means a fire event and the ship state that produced it cannot desynchronize:

```c
struct Weapons {         /* 2 bytes */
    u16 type : 5;        /* 1 bullet, 2 bouncing bullet, 3 bomb, 4 prox bomb,
                            5 repel, 6 decoy, 7 burst, 8 thor, 15 shrapnel */
    u16 level : 2;
    u16 shrapbouncing : 1;
    u16 shraplevel : 2;
    u16 shrap : 5;
    u16 alternate : 1;   /* mine vs bomb, multifire vs single */
};
```

`ExtraPosData` adds energy, S2C ping, a timer, and the full special inventory
(shields, super, bursts, repels, thors, bricks, decoys, rockets, portals) in ten
bytes. It is sent only to players allowed to see it, which is what the
`Misc:SeeEnergy` settings and the `seeepd` capability gate.

There is a smaller position packet (`0x28`) for the first 256 player ids, and
batched forms of both. Bandwidth was the design constraint at every level.

## Units

The whole simulation is fixed-point integers with implied scales. From
`ArenaSettings.h` in nullspace and the ASSS settings reference:

| Quantity | Encoding |
|---|---|
| Time | Ticks of 1/100 second. `current_ticks()` in ASSS is centiseconds |
| Map | 1024x1024 tiles, 16 pixels per tile, so 16384 pixels square |
| Position | Pixels, `i16` on the wire |
| Velocity | Pixels per second divided by 10 |
| `MaximumSpeed` | Same: `speed / 10 / 16` gives tiles per second |
| `MaximumThrust` | `thrust * 10 / 16` gives tiles per second of acceleration per second |
| `MaximumRotation` | 400 means one full rotation per second |
| Heading | 40 discrete directions |
| `MaximumRecharge` | `recharge / 10` energy per second |
| Ship radius | Pixels, 8-bit field, typically 14 |
| Cloak, stealth, antiwarp, xradar energy | Thousandths of energy per tick |
| Damage percentages | Tenths of a percent |
| Multifire angle | 111 is one degree, 1000 is one ship rotation point |

nullspace's `ShipController::Update` is the clearest statement of the movement
model we found:

```cpp
self->velocity += OrientationToHeading(direction) * (thrust * (10.0f / 16.0f)) * dt;
self->velocity.Truncate(abs((s32)speed / 10.0f / 16.0f));
self->energy += (ship.recharge / 10.0f) * dt;
orientation += (ship.rotation / 400.0f) * dt;
```

No drag term appears anywhere. Velocity changes only through thrust, wall
bounces (scaled by `Misc:BounceFactor`, where 16 means no loss), bomb recoil
(`BombThrust`), repels, and wormhole gravity. Everything else in the game is a
consequence of that.

## The trust model, and why it matters

Subspace is client-authoritative about damage. The victim's client decides it
died and sends `C2S_DIE` naming its killer. Here is what the server does with it
in `game.c`:

```c
killer = pd->PidToPlayer(dead->d1);
if (!killer || killer->status != S_PLAYING || killer->arena != arena) {
    lm->LogP(L_MALICIOUS, "game", p, "reported kill by bad pid %d", dead->d1);
    return;
}
```

That is the whole check: the named killer must exist, be playing, and be in the
same arena. Bounty comes from the packet. The server never simulates the bullet.

Position works the same way. Clients send their own position and the server
relays it, filtering by lag and by region rules but not re-deriving it. This is
why the game felt good on a 1997 modem, and why cheating was rampant enough that
Continuum was written primarily to close those holes.

Continuum's answer was not server-side simulation. It was attestation: the
`security` module challenges clients for checksums over the executable, the
current settings, and the map, and the client's encryption implementation
identifies it. Mismatches log as `MALICIOUS` and can kick. The `bypasssecurity`
capability exists for bots.

For vectorwake this is the fork in the road. Keeping Subspace's feel means
keeping local prediction that never stalls on the server; keeping the game
honest in 2026 means the server has to own damage. Those are not in conflict as
long as the server simulates weapons and the client predicts them, which is
exactly the tradeoff Subspace could not afford in 1997 and we can.

## Arena settings on the wire

Settings arrive as one packed binary blob (`0x0F`), not as text. The client
parses it into a fixed struct: per-ship settings for all eight ships followed by
the arena-wide sections. Both nullspace and the original client hard-code the
layout, which is why zone authors can change any value but nobody can add a new
one.

A version of this worth keeping: settings are pushed to the client, hashed, and
verified. A version worth dropping: the schema is a C struct with reserved
padding bits.

### Numbers worth not re-deriving

From the settings shipped with ASSS (`dist/conf/svs`), which is the closest
thing to a reference zone in the source we have. Identical across all eight
hulls unless noted.

| Setting | Value | Note |
|---|---|---|
| `MaximumSpeed` | 3250 | 325 px/s |
| `BulletSpeed`, `BombSpeed` | 2000 | 200 px/s -- deliberately slower than a ship |
| `BulletFireEnergy` | 20 | of `MaximumEnergy` 1700 |
| `MultiFireEnergy` | 30 | half again, for three rounds |
| `BulletFireDelay` | 25 ticks | |
| `MultiFireDelay` | 50 ticks | twice -- most of multifire's price is rate |
| `BombFireEnergy` | 300 | `+50` per level |
| `PrizeNegativeFactor` | 300 | one green in three hundred takes something back |
| `PrizeDelay` | 700 | |

Projectile speed is added to the ship's velocity, so a bullet's number is its
speed *relative to the shooter* and does not change with how fast anyone is
travelling. Rounds slower than ships is a deliberate choice, not an oversight.

`[PrizeWeight]`, relative, from the same tree:

```
QuickCharge=40  Energy=40   Rotation=40   Stealth=40   Cloak=25    AntiWarp=25
XRadar=40       Warp=7      Gun=25        Bomb=25      Thruster=40 TopSpeed=40
BouncingBullets=25          Recharge=10   MultiFire=30 Proximity=25 Glue=0
AllWeapons=10   Shields=10  Shrapnel=30   Repel=70     Burst=70    Decoy=40
Thor=30         Portal=60   Brick=200     Rocket=50    MultiPrize=130
```

Charges are the heavy entries: a repel or a burst is nearly twice as likely as
a stat, and `Brick` at 200 is the heaviest thing in the table.

These are the subgame-standard values, not any particular live zone's -- Chaos
and Alpha both tuned their own and we do not have those files.

## Maps

`.lvl` is an optional Windows BMP tileset followed by raw tile data to the end
of the file. The extended format inserts metadata between the two and points at
it from the reserved field in the bitmap header, so old tools that use the
header's size field to find the tile data still work.

Maps are downloaded from the server, optionally compressed (`0x2A`), and
checksummed. LVZ files carry the visual overlays (objects, animations) that
Continuum added, toggled at runtime with `0x35` and `0x36`.

[lvl-format.md](lvl-format.md) has the byte layout and the tile types.
