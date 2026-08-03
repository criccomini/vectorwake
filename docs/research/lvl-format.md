# The .lvl map format

A Subspace map is one file holding two things that have nothing to do with each
other: a bitmap of the tileset the client draws with, and the tiles themselves.
The second half is what we care about. Everything a rule in the engine reads,
walls, doors, safe zones, flag stands, is one byte per placed tile.

The format is documented here because our converter reads it. That converter is
`sim/tools/lvl2vw.c`, and
[architecture/content-pipeline.md](../architecture/content-pipeline.md) says how
to run it. The output looks nothing like the input: a tile in vectorwake is its
behaviour, so the 160 wall pictures collapse to one class and the tileset does
not survive the trip.

## The file

```
+-------------------------+  0
| BITMAPFILEHEADER        |
| BITMAPINFOHEADER        |
| 256-colour palette      |
| pixels: the tileset     |
+-------------------------+  bfReserved1 (optional)
| eLVL metadata           |
+-------------------------+  bfSize
| tile data to EOF        |
+-------------------------+
```

The bitmap is optional. If the first two bytes are not `BM` (0x4D42) the file is
tile data from byte zero and the client draws with its own tileset. Two of the
five maps we tested are like that.

The header doubles as the directory:

| Offset | Field | Use |
|---|---|---|
| 0 | `bfType` | 0x4D42, the only thing that says a tileset is present |
| 2 | `bfSize` | where the tile data starts |
| 6 | `bfReserved1`, `bfReserved2` | zero, or the offset of the eLVL metadata |
| 10 | `bfOffBits` | where the bitmap pixels start |

`bfSize` is authoritative and is not always the end of the pixels. Two of our
three tilesets leave a two-byte gap between the last pixel and the tile data,
so a reader that computes the offset from the bitmap dimensions lands one
record and a half out of phase and decodes noise.

The reserved field is nominally two `u16`s, but ASSS reads four bytes at offset
6 and so does everyone else. It has to: the metadata sits after the bitmap, and
a tileset larger than 64 KB would put it beyond what a `u16` can address.

## Tiles

The tile section is a flat array of 4-byte little-endian records, read until
the file ends. There is no count and no terminator.

```c
struct tile { u32 x : 12, y : 12, type : 8; };
```

Only placed tiles are stored, so the file is about as big as the map has
structure in it. The world is 1024x1024 either way, and a record outside that
is an error rather than a wrap. The five maps we tested carry 21,836 to 30,935
records, which is 2 to 3 percent of the grid.

The type byte is the whole vocabulary:

| Type | Meaning | Solid |
|---|---|---|
| 0 | empty | no |
| 1-161 | ordinary tiles, indices into the tileset; 20 is the border | yes |
| 162-165 | vertical doors | yes when shut |
| 166-169 | horizontal doors | yes when shut |
| 170 | turf flag stand | no |
| 171 | safe zone | no |
| 172 | soccer goal | no |
| 173-175 | scenery drawn over the ships | no |
| 176-190 | scenery drawn under them | no |
| 216 | small asteroid, 1x1 | yes |
| 217 | large asteroid, 2x2 | yes |
| 218 | second small asteroid, 1x1 | yes |
| 219 | space station, 6x6 | yes |
| 220 | wormhole, 5x5 | no |
| 250 | brick | until it expires |

Bricks are placed at runtime by the brick weapon and never appear in a file.
The gaps in the table are unused, and Continuum treats 192 to 240 and 242 to
252 as solid anyway, so a stray value stops a ship rather than being ignored.

The four types above 215 are objects rather than tiles. One record places the
whole thing and the reader expands it, filling `size` by `size` tiles from the
record's corner with copies of the same type. Everything below 217 occupies the
single tile it names.

Only types 1 to 160 and the safe zone feed the map checksum the server uses to
catch a client flying on different geometry. Decoration may differ between
clients. Walls and safe zones may not.

## The eLVL extension

ASSS needed somewhere to keep regions, and the constraint was that every
existing map tool had to go on working. So the metadata goes in the middle of
the file, where a reader that trusts `bfSize` skips straight over it.

```c
struct metadata_header { u32 magic; u32 totalsize; u32 reserved; };
struct chunk_header    { u32 type;  u32 size; };
```

The magic is `elvl`, 0x6C766C65 on the wire. Chunks follow the header until
`totalsize` is spent, each padded to a 4-byte boundary without counting the
padding in `size`.

| Chunk | Contents |
|---|---|
| `ATTR` | one `key=value` pair of ASCII, not terminated |
| `REGN` | a region, as sub-chunks |
| `TSET`, `TILE` | reserved for a future replacement of the bitmap and tile sections |

A region is a set of tiles with rules attached, which is the one late addition
to the original worth having. Its sub-chunks are `rNAM` the name, `rTIL` the
tiles it covers, `rBSE` a base, `rNAW` no antiwarp, `rNWP` no weapons, `rNFL`
no flag drops, `rAWP` an autowarp destination as `i16 x, i16 y` and an optional
16-byte arena name, and `rPYC` embedded Python. The rule sub-chunks carry no
payload: present or absent is the whole value.

`rTIL` has a run encoding of its own, unrelated to the sparse list, walking the
grid in rows. The top three bits of a byte pick between runs of absent tiles,
present tiles, empty rows, and repeats of the last row, with a one-byte form
for runs up to 32 and a two-byte form for runs up to 1024.

None of the five maps we tested carry any metadata at all, which is worth
knowing before building anything on it. Regions came late and most maps in
circulation predate them.

## What the tilesets look like

Three of the five carry one: 8-bit paletted bitmaps, 304 pixels wide, 144 or
160 tall. That is 19 tiles across at 16 pixels, and 9 or 10 rows, so a tileset
holds 171 or 190 tiles and the type byte indexes it in reading order. The
palette is the standard 1024-byte BMP table and the pixels are uncompressed.

We do not read any of this. Our client draws vector art from tile classes and
has no tileset to fill.

## Sources

- ASSS `src/core/mapdata.c` and `src/include/mapdata.h`, which is the reference
  reader and the origin of every type number above
  (https://github.com/fcxcode/eg-asss).
- ASSS `doc/extended-lvl-format.txt`, version 0.4, for the metadata section.
- nullspace `src/null/Map.cpp`, whose `IsSolid` is the clearest statement of
  which types stop a ship (https://github.com/plushmonkey/nullspace).
- Five maps from criccomini, measured with a throwaway parser to check the
  above against files that were actually shipped.
