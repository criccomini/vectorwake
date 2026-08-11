# Turrets

A turret is a player riding on a teammate's ship. The rider keeps a hull, an
energy bar, weapons and an aim of their own, and gives up every bit of control
over where the ship goes. Five ride at once in the reference configuration.

## The move

Select a teammate in the player list with PgUp and PgDn, press F7, and wait for
the server to answer. You appear on top of their ship and from then on you can
turn and shoot and nothing else. F7 again detaches you.

The same key does a third thing. Pressed by a host who has riders, F7 throws all
of them off, and a ship carrying riders cannot attach to anybody until it has
thrown them off first. So stacks never chain: the graph is one host deep, always.

## Attaching is a warp

This is the part that decides everything else. Attaching is not a docking
maneuver, it is the warp system aimed at a teammate, and it inherits the warp
rules exactly:

- You need a full energy bar.
- Stealth, cloak, x-radar and antiwarp must all be off.
- An enemy running antiwarp within `Toggle:AntiWarpPixels` blocks it. That is
  1000 pixels in the reference configuration, 62.5 tiles, which the player
  guides describe as about half a sector. The setting carries a condition worth
  keeping: the enemy has to be on your radar to stop you, so a stealthed
  antiwarper does not.
- You arrive with your energy drained to almost nothing.

Nothing bounds the distance. You attach from anywhere in the arena to anywhere
else in it, which is the whole of why the Terrier matters in Trench Wars: it is
a rally point that walks around, and a team that loses it walks back to the
fight from spawn. It is also why killing the enemy Terrier is a job somebody is
assigned rather than something that happens.

The energy drain is the price, and it is a real one. Attach to a host who is in
a live fight and you land next to armed enemies with an empty bar, which is
close enough to suicide that the guides say to verify the host is clear and then
attach inside five seconds or not at all. Desynced mines make this worse: your
client can place you in a minefield the host cannot see.

`Misc:AntiWarpSettleDelay` runs a fake antiwarp on you for a few ticks after
attaching, portaling or warping.

## What a rider costs the host

Four settings, all per ship, so a zone decides which hull is the platform and
whether there is one at all.

| Setting | Applies to | Reference value | Unit |
|---|---|---|---|
| `TurretLimit` | the host's hull | 5 | riders allowed, and 0 forbids attaching to this ship |
| `TurretThrustPenalty` | the host's hull | 1 | thrust lost while carrying, against `MaximumThrust` 17 |
| `TurretSpeedPenalty` | the host's hull | 125 | pixels/second/10, so 12.5 px/s against 325 |
| `AttachBounty` | the rider's hull | 0 | bounty the rider needs before it may attach |

Values are from `dist/conf/svs/ship-terrier`, where, as `original-settings.md`
already says, all eight ships carry identical numbers. Note that all eight also
carry `TurretLimit=5`: any ship can be a carrier, and the zones where only one
can are zones that set the other seven to zero.

Neither penalty scales with the count. The client tests whether the ship has
any riders at all and subtracts once, so the first rider costs the host 6% of
its thrust and 4% of its top speed and the next four are free. The settings
text agrees, saying "with a turret riding" rather than per turret.

That is the entire mechanical cost of carrying people, and it means a carrier
with one rider should always want five. What balances the mechanic is not the
penalty. It is that five ships are now standing in one place.

## Everyone in the stack is a separate ship

They share a position and nothing else.

Damage lands on each hull independently, so a host at full energy can be
carrying a rider one bullet from death, and neither can see the other's bar.
Splash reaches all of them at once, which makes a badly aimed friendly bomb the
most reliable way to wipe a stack, and makes a well aimed enemy one worth
throwing at any stack that holds still. Lag compounds it: the host and the
riders are looking at different screens, so a rider firing a bomb at what looks
from there like a distant enemy may be firing into the group they are sitting in.

Deaths do not propagate in either direction. If the host dies the riders detach
and live. If a rider dies it explodes alone and the rest of the stack does not
notice.

Prizes are the one thing that does propagate, and only downward: a green the
host flies over is granted to every rider, shields and super included. Losses
from negative prizes land on one ship at a time. So a stack is a way to spend
one player's greens on five players, at the cost of four players not out
collecting any.

Cloak and stealth resolve per ship and produce some strange results. A stack
disappears from radar only when the host and every rider are stealthed. A
cloaked rider is not drawn at all. A cloaked host with visible riders shows up
as turrets floating in space. Flags follow the host: a host holding one is red
on radar, and if a rider is the one holding it the host is red only to enemies
with x-radar.

## How it is drawn

Not as ships, which is the thing to know before designing anything.

A ship is a 36 by 36 sprite picked out of a sheet by class and by one of 40
headings. A turret is a 16 by 16 sprite picked out of a different sheet by
heading alone. There is no class in that index: one gun graphic serves all
eight ships, so a Leviathan riding a Terrier and a Warbird riding it look
identical.

The renderer skips any player who is attached, then draws each carrier
followed by its riders, every one of them centred on the carrier's own
position. Five riders is five 16 by 16 guns stacked on the same pixel, each
turned to the heading its pilot is holding. You cannot count them and you
cannot tell what they are.

What you can read is the text. The carrier's name is drawn under it, then each
rider's name twelve pixels below the last, so a full stack carries a column of
six names. The count and the roster live there rather than in the picture.

Two artifacts fall out of the draw order rather than out of any decision. The
riders are drawn outside the test that decides whether the carrier itself is
visible, which is exactly why a cloaked carrier leaves its guns hanging in
space. And a rider's name is laid out using its carrier's sprite size rather
than its own, so the text sits where the carrier is, whatever the rider flies.

## The wire

Four packets and one field.

| Packet | Direction | Payload |
|---|---|---|
| `0x10` attach request | client to server | `u16` target player id, -1 to detach |
| `0x0E` create turret link | server to client | `u16` rider, `u16` host |
| `0x14` drop turrets | client to server | none |
| `0x15` destroy turret link | server to client | `u16` host |

The state is also part of the join snapshot: the 64-byte player entering record
(`0x03`) carries an attachee id at offset 59, so a client that arrives in the
middle of a game learns the whole attach graph with the player list.

## What the server actually enforces

Almost nothing, and the exact shape of that is worth knowing before we copy any
of it.

ASSS's attach handler checks that the target exists, is playing, is not you, is
in your arena, and is on your frequency. Then it broadcasts the link to the
arena and stores it. It never reads `TurretLimit` or `AttachBounty`, never looks
at your energy or your specials, and never detaches you when your host dies. The
kickoff handler is thinner still: it rebroadcasts, and each client decides
whether the packet was about its own host.

Every rule in the two sections above therefore lives in Continuum, on the
machine of the player the rule is aimed at.

The server does use the link for one thing, and this one is worth stealing.
Position packets are relayed on a distance test, and the distance they are
tested against is the receiving client's own screen size, so a player is told
about the ships it could actually draw. A rider is exempt: the host's positions
reach it at any distance. The attachment exists on the server as a routing hint
more than as game state.

## What does not port

The trust model, so all of it. A free unbounded teleport onto a teammate, gated
by conditions only the client checks, is the first thing anyone would write a
cheat for. Attaching has to be a request our server grants after checking the
energy, the specials, the antiwarp field, the rider count and the bounty, and
`sim/` has to own the attached position rather than accepting one from the
rider.

The relay exemption ports as a rule about interest management: whatever decides
which entities a client is told about has to treat the attach graph as an edge
that always transmits, or riders will fly blind on the ship they are sitting on.

## Sources

- ASSS `src/core/game.c`, the whole server side: `PAttach`, `PKickoff`, and the
  one use of the stored attachment in the position relay
  (https://github.com/fcxcode/eg-asss).
- ASSS `src/core/clientset.def` for the four settings and their documented
  meanings, and `src/packets/types.h` for the packet numbers.
- ASSS `dist/conf/svs/ship-terrier` and `dist/conf/svs/misc` for the reference
  values.
- Packet tables at https://www.twcore.org/SubspaceProtocol/, which agree with
  `types.h` and add the field layouts.
- Ship settings on the ASSS wiki for the units
  (http://wiki.minegoboom.com/index.php/Ship_Settings).
- nullspace `src/null/PlayerManager.cpp` for the drawing, `Graphics.cpp` for the
  two sprite sheets, and `ShipController.cpp` for a rider's position being
  assigned from its carrier every tick and for the penalties being subtracted
  once (https://github.com/plushmonkey/nullspace). It is a reimplementation
  rather than Continuum, which is closed, and it is the closest thing to a
  reference there is.
- Rincewind's SubSpace strategy guide for the client-side rules, which are
  documented nowhere in the server source: the energy and specials conditions,
  the drain on arrival, what dies with what, and the radar cases
  (https://steamcommunity.com/sharedfiles/filedetails/?id=476127101).
- A Beginner's Guide to SSCU Trench Wars for how the mechanic is actually used
  (https://steamcommunity.com/sharedfiles/filedetails/?id=474916946).
