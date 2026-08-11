# Where a ship arrives

Two mechanisms, an era apart. The original shipped without spawn points at all
and worked out a region from settings that do not look like spawn settings.
Explicit points arrived years later, and when they did the placement rule was
not quite the one the documentation describes.

The short answer to the question this file was written for: with a radius of
zero you land on the exact tile, every time, and with a radius above zero you
land on a random tile inside a square around it.

## The Continuum settings

Spawn points are a late addition. From the subgame changelog, version 1.34.13:

> New cfg variables: Spawn:Team0-X, Spawn:Team0-Y, Spawn:Team0-Radius - allows
> specify spawn location and radius per team. If only Team0 variables are set,
> all teams use them, if Team0 and Team1 variables are set, even teams use Team0
> ones and odd team Team1 ones. It is possible to set spawn positions upto 4
> teams (Team0-Team3) [Continuum 0.38+]

Twelve values, three per team, and freqs past the fourth wrap around. They
travel in the settings blob (`0x0F`) as four packed words:

```c
struct /* 4 bytes */
{
	u32 x : 10;
	u32 y : 10;
	u32 r : 9;
	u32 pad : 3;
} spawn_pos[4];
```

Ten bits of x and ten of y is exactly the 0 to 1023 tile range of a map, so a
spawn point is a tile rather than a pixel. Nine bits of radius allows 0 to 511,
which is half the map.

ASSS reads all twelve with a default of zero and packs them without clamping or
converting anything:

```c
/* spawn locations */
for (i = 0; i < 4; i++)
{
	char xname[] = "Team#-X";
	...
	cs->spawn_pos[i].x = cfg->GetInt(conf, "Spawn", xname, 0);
	cs->spawn_pos[i].y = cfg->GetInt(conf, "Spawn", yname, 0);
	cs->spawn_pos[i].r = cfg->GetInt(conf, "Spawn", rname, 0);
}
```

That pass-through is the tell. The server does not place anybody. It hands the
numbers to the client, the client picks a tile, and the position packet that
comes back is the first the server hears of where the ship is. Spawning sits on
the same side of the trust line as damage does, for the same 1997 reasons
described in [protocol-and-simulation.md](protocol-and-simulation.md).

## What the radius actually does

From nullspace's `PlayerManager::Spawn`, which is the clearest statement of the
rule we have:

```c
u32 spawn_index = self->frequency % spawn_count;
float x_center = (float)connection.settings.SpawnSettings[spawn_index].X;
...
// Default to exact center in the case that a random position wasn't found
self->position = Vector2f(x_center, y_center);

if (radius > 0) {
  // Try 100 times to spawn in a random spot.
  for (int i = 0; i < 100; ++i) {
    float x_offset = (float)((rand() % (radius * 2)) - radius);
    float y_offset = (float)((rand() % (radius * 2)) - radius);
    Vector2f spawn(x_center + x_offset, y_center + y_offset);
    if (connection.map.CanFit(spawn, ship_radius, self->frequency)) {
      self->position = spawn;
      break;
    }
  }
}
```

Five things fall out of that.

**A radius of zero skips the loop entirely.** Not a one-tile circle, not a
retry against the walls: the position was already set to the exact centre and
nothing touches it again. Everybody on the freq arrives on the same tile,
stacked, and there is no fit test at all, so a point drawn inside rock spawns the
whole team inside rock.

**Above zero it is a square, not a circle.** The config help says "How large of
a circle from the center point freq 0 can start", and both offsets are drawn
independently, which makes the reachable area a square of side 2r. Corners are
as likely as the middle. The offsets run from -r to r-1 rather than -r to r,
because `rand() % (radius * 2)` yields 0 to 2r-1, so the box is very slightly
off centre toward the top left.

**Everything is whole tiles.** No sub-tile placement, and the fit test is
`CanFit`, which walks solid tiles across the hull's radius. Ship radius comes
from `ShipSettings.GetRadius()`, which is the `Radius` setting over 16 and
defaults to 14 pixels when the setting is zero.

**A hundred failures means the exact centre anyway.** The fallback is not "try
harder" or "give up", it is the unchecked centre tile. A radius that mostly
covers wall degrades to the radius-zero behaviour rather than to an error.

**The team index counts entries, not slots.** `frequency % spawn_count`, where
`spawn_count` is how many of the four entries have any non-zero field. Setting
Team0 and Team1 gives the even and odd split the changelog describes. Setting
only Team2 gives a count of one, so everybody uses entry zero, which is the
all-zeros Team0 and therefore the map centre.

One more quirk in the same function: an X or Y of zero reads as 512. Zero is how
the settings say "unset", so a point cannot sit on column zero or row zero.

## Before that, there were no spawn points

The alpha had none of this. No `[Spawn]` section, nothing named a spawn point,
and nothing for a map maker to look at. What it had instead were two settings
that still exist and still do this job whenever the spawn entries are all zero.

The first is `Misc:WarpRadiusLimit`, whose help text gives the whole model away:

> When ships are randomly placed in the arena, this parameter will limit how far
> from the center of the arena they can be placed (1024=anywhere)

Random placement around the centre of the map, with a cap, and the cap is the
half of this that decides everything: the reference server ships it at 20, on a
map 1024 tiles across. The second setting is `Radar:RadarMode`, which looks
like a display setting and turns out to be doing a second job:

> Radar mode (0=normal, 1=half/half, 2=quarters, 3=half/half-see team mates,
> 4=quarters-see team mates)

The client takes a half and half radar as a statement that the map has two ends
and a quartered radar as a statement that it has four, then spawns accordingly:

| RadarMode | Where a freq lands |
|---|---|
| 1, 3 | `x = (freq & 1) * 768 + rand(0..255)`, `y = 256 + rand(0..255)`. Even freqs against the left edge, odd against the right. |
| 2, 4 | `x = (freq & 1) * 768 + rand(0..255)`, `y = ((freq / 2) & 1) * 768 + rand(0..255)`. Four corners by freq mod 4. |
| 0 | A box around the map centre whose width grows with the room's population. |

That third row is the strange one, and it is the row where reading the code
without reading the settings gets you a wrong answer. The width is
`((players / 8) * 8192 + 1024) / 96 + 256`, clamped to `WarpRadiusLimit` with a
floor of 3, and then the tile is drawn from it with about 20 tiles of extra
jitter. Taken alone the formula widens as the room fills:

| Players in the arena | Width the formula asks for |
|---|---|
| 0 to 7 | 266 |
| 8 to 15 | 352 |
| 16 to 23 | 437 |
| 24 to 31 | 522 |

None of which happens on a stock server. `dist/conf/svs/misc` sets
`WarpRadiusLimit=20`, and 20 is below every row of that table, so the clamp
fires on an empty arena and the population term never reaches the arithmetic.
What a default zone actually does is put arrivals in x 493 to 529 and y the
same: a 37-tile square dead in the middle of the map, about one screen across,
whatever the room holds.

So the growth is real code and, at the settings the reference server ships, it
is unreachable. It only means anything in a zone that raises the limit past
266, and `RadarMode=0` with `WarpRadiusLimit=20` is what the same file pairs it
with. Read the two together or the fallback looks like a scatter when it is the
opposite: everybody, both sides, into one screen at the centre.

All three modes run the same hundred attempts against the same fit test, falling
back to 512, 512. One caveat on those attempts, and it is a caveat about the
reimplementation rather than about the original: nullspace seeds its generator
once before the loop and reconstructs it from that same seed inside every
iteration, so modes 1 to 4 compute an identical tile all hundred times and mode
0 varies only by its 20 tiles of jitter. Either Continuum does the same thing,
which would mean the retry is far weaker than the loop count suggests, or the
seeding is an artefact of transcribing it. We have not established which.

So the answer to whether spawn points were visible in the alpha's settings is
that there was nothing to make visible. A map maker picked a radar mode and drew
the map to suit the region it implied, which is why so many maps of that era put
two bases hard against the left and right edges. Spawn points are not drawn on
screen either, then or now: there is no tile class for one and no radar marker,
so under Continuum the coordinates live in `arena.conf` and nowhere else.

## How much of this to trust

Continuum is closed source, so it matters where each part of this came from.

The setting names, the units, the packet layout and the version history come
from ASSS and the subgame changelog. Those are as good as primary: ASSS had to
interoperate with the real client to work at all.

The arithmetic in this file comes from nullspace, which is a reimplementation
built from disassembly rather than a copy of anything. Treat the constants as
strong evidence rather than as a quoted specification. The Lehmer generator
behind the fallback modes carries VIE's original constants (`0x1F31D`, `0x41A7`,
`0xB14`), which is the kind of detail nobody arrives at by guessing.

## What we do instead

vectorwake spawns from the map rather than from settings. A spawn is a tile,
`SIM_TILE_SPAWN`, with the team in the variant, and `sim_map_spawn` walks the
map's list twice: the asking team's own tiles first, then anybody's, so a map
that marks only neutral starts still works and a team the map never heard of
still gets a berth. There is no radius and no fit test at the moment of arrival,
because the checking happens when the map is drawn: `place_spawns` in
`sim/tools/mapgen.c` marks a tile only when it has thirteen tiles of clear
ground around it, all of it inside the map's one connected region, and the
generator rejects the seed if it cannot place all sixteen.

Three differences from the original are worth stating plainly.

The server places the ship, inside the deterministic core, so the client
predicts the same tile rather than choosing it.

Arrivals go round robin rather than random. `nth` is the room's ship count at
the moment of entry (`server/src/main.rs:1229`), which spreads a roster across
the available tiles instead of letting the draw stack them.

And a spawn point is chosen once. `spawn_x` and `spawn_y` are fixed when the
ship enters, so death returns you to that same tile for the rest of your stay in
the room, and only a team change redraws it. Subspace redraws on every respawn.
The one other thing that picks a spawn tile at random is a wormhole, which drops
you on one without touching where your next death will put you.

Where our maps' spawn tiles come from, and why there are eight a side, is in
[map-measurements.md](map-measurements.md) under "The spawns are not the
original's". They are our converter's arithmetic, not a measurement of anything.
