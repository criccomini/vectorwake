/* Convert a Subspace .lvl map into one of ours.
 *
 * The point is not compatibility. It is that a converted map is a room whose
 * behavior somebody already knows, so our collision, our doors and our safe
 * zones can be flown against geometry that was play-tested for years by people
 * who were not us. What comes out is not content we ship: an existing zone's
 * map belongs to that zone, and the tileset it was drawn with does not survive
 * the trip anyway.
 *
 * docs/research/lvl-format.md has the input format. The short version is a
 * flat array of 4-byte records, x:12 y:12 type:8, after an optional bitmap
 * whose header says where they start.
 *
 * The type byte is the interesting part, because the original put behavior in
 * the number: a door is 162 through 169, a safe zone is 171, scenery you fly
 * under is 176 through 190. Here a tile is its class and nothing else, so this
 * is where 190 numbers become nine. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sim/pack.h"
#include "sim/sim.h"

#define TILES SIM_MAP_TILES

/* lvl tile types worth naming. The rest are ranges. */
#define LVL_DOOR_FIRST 162
#define LVL_DOOR_LAST 169
#define LVL_TURF 170
#define LVL_SAFE 171
#define LVL_GOAL 172
#define LVL_OVER_FIRST 173
#define LVL_OVER_LAST 175
#define LVL_UNDER_FIRST 176
#define LVL_UNDER_LAST 190
#define LVL_ASTEROID_SMALL 216
#define LVL_ASTEROID_BIG 217
#define LVL_ASTEROID_SMALL2 218
#define LVL_STATION 219
#define LVL_WORMHOLE 220

typedef struct {
    uint32_t records;   /* 4-byte records read */
    uint32_t offmap;    /* records naming a tile outside the world */
    uint32_t undefined; /* records with a type the format does not define */
    uint32_t wormholes;
    uint32_t tiles[SIM_TILE_COUNT]; /* the finished map, by class */
    uint32_t demoted;   /* features dropped to fit SIM_MAX_FEATURES */
    uint32_t spawns[2];
    uint32_t open;      /* tiles in the largest open region */
    size_t meta_off;    /* eLVL metadata, or 0 */
    int has_tileset;
} report;

static uint32_t rd32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16)
           | ((uint32_t)p[3] << 24);
}

/* The solid variants are sim.h's now, because the editor writes them too and
 * two files guessing at the same numbering is how a rock becomes a station.
 * Short names because this file is thick with them. */
#define V_WALL SIM_SOLID_WALL
#define V_BORDER SIM_SOLID_BORDER
#define V_ROCK_A SIM_SOLID_ROCK_A
#define V_ROCK_B SIM_SOLID_ROCK_B
#define V_ROCK_BIG SIM_SOLID_ROCK_BIG
#define V_ROCK_BODY SIM_SOLID_ROCK_BODY
#define V_STATION SIM_SOLID_STATION
#define V_STATION_BODY SIM_SOLID_STATION_BODY

/* Twenty is the border in every tileset the original shipped. */
#define LVL_BORDER 20

/* What one lvl type becomes, for the types that map to a single tile.
 *
 * Solidity follows Continuum rather than the tileset: a flag stand, a goal and
 * every kind of scenery are passable, and the undefined ranges above 191 stop
 * a ship, so a stray byte in a file is a wall and not a hole. */
static uint8_t translate(unsigned type, int *undefined) {
    *undefined = 0;
    if (type == 0) return SIM_TILE_EMPTY;
    if (type == LVL_BORDER) return SIM_TILE(SIM_TILE_SOLID, V_BORDER);
    if (type <= 161) return SIM_TILE_SOLID;
    /* The eight door tiles become eight channels. The core spaces a variant's
     * phase an eighth of the cycle apart, which is what the original did with
     * its eight door bits, so a converted map keeps its rhythm. */
    if (type <= LVL_DOOR_LAST)
        return SIM_TILE(SIM_TILE_DOOR, type - LVL_DOOR_FIRST);
    if (type == LVL_TURF) return SIM_TILE_TURF;
    if (type == LVL_SAFE) return SIM_TILE_SAFE;
    if (type == LVL_GOAL) return SIM_TILE_GOAL;
    if (type <= LVL_OVER_LAST) return SIM_TILE_OVER;
    if (type <= LVL_UNDER_LAST) return SIM_TILE_UNDER;
    *undefined = 1;
    if (type == 241 || type >= 253) return SIM_TILE_EMPTY;
    return SIM_TILE_SOLID;
}

static void paint(sim_map *m, int tx, int ty, uint8_t t) {
    if (tx < 0 || ty < 0 || tx >= TILES || ty >= TILES) return;
    m->tile[(size_t)ty * TILES + (size_t)tx] = t;
}

/* Read the tile records into a map.
 *
 * Records are read to the end of the file and later ones win, which is what
 * the original does: an editor that moves a wall appends rather than rewrites,
 * and a reader that stops early gets a map with the edit missing. */
static void read_tiles(sim_map *m, const uint8_t *p, size_t len, report *rp) {
    for (size_t i = 0; i + 4 <= len; i += 4) {
        uint32_t v = rd32(p + i);
        int x = (int)(v & 0xfff), y = (int)((v >> 12) & 0xfff);
        unsigned type = v >> 24;
        rp->records++;
        if (x >= TILES || y >= TILES) {
            rp->offmap++;
            continue;
        }
        /* Four types are objects rather than tiles: one record places a square
         * of them and the reader is expected to know how big it is. */
        if (type == LVL_WORMHOLE) {
            /* A wormhole is a 5x5 picture around one gravity well. Painting
             * all 25 as wormholes would give the well 25 times its pull, so
             * the center carries the feature and the rest is open space, which
             * is what the original's is: you fly through a wormhole, you do
             * not bounce off it. */
            for (int dy = 0; dy < 5; dy++)
                for (int dx = 0; dx < 5; dx++)
                    paint(m, x + dx, y + dy, SIM_TILE_EMPTY);
            paint(m, x + 2, y + 2, SIM_TILE_WORMHOLE);
            rp->wormholes++;
            continue;
        }
        int size = 1;
        if (type == LVL_ASTEROID_BIG) size = 2;
        else if (type == LVL_STATION) size = 6;
        /* Rock and the station are solid like a wall and drawn like neither,
         * so the variant carries which they are and which tile of them is the
         * corner the picture hangs from. */
        int undefined = 0;
        uint8_t t, body;
        if (type == LVL_ASTEROID_SMALL) {
            t = body = SIM_TILE(SIM_TILE_SOLID, V_ROCK_A);
        } else if (type == LVL_ASTEROID_SMALL2) {
            t = body = SIM_TILE(SIM_TILE_SOLID, V_ROCK_B);
        } else if (type == LVL_ASTEROID_BIG) {
            t = SIM_TILE(SIM_TILE_SOLID, V_ROCK_BIG);
            body = SIM_TILE(SIM_TILE_SOLID, V_ROCK_BODY);
        } else if (type == LVL_STATION) {
            t = SIM_TILE(SIM_TILE_SOLID, V_STATION);
            body = SIM_TILE(SIM_TILE_SOLID, V_STATION_BODY);
        } else {
            t = body = translate(type, &undefined);
        }
        rp->undefined += (uint32_t)undefined;
        for (int dy = 0; dy < size; dy++)
            for (int dx = 0; dx < size; dx++)
                paint(m, x + dx, y + dy, (dx == 0 && dy == 0) ? t : body);
    }
}

/* Somewhere a ship can be, by the core's rule: walls stop one and a shut door
 * stops one, and everything else is a place rather than an obstacle. */
static int passable(const sim_map *m, int tx, int ty) {
    int c = SIM_TILE_CLASS(m->tile[(size_t)ty * TILES + (size_t)tx]);
    return c != SIM_TILE_SOLID && c != SIM_TILE_DOOR;
}

/* Which open space connects to which.
 *
 * A Subspace map is full of sealed rooms: a box drawn as scenery, the inside
 * of a letter in a word spelled out in tiles. Open ground is not the test for
 * a start, because a ship put down inside one of those is stuck there until
 * something kills it, and on a map with no weapons reaching it, forever. So
 * every open tile gets the label of the region it belongs to, and starts are
 * taken from the largest one.
 *
 * Eight megabytes of static arrays, which a converter that runs once can
 * afford and the core could not. */
static uint32_t region[(size_t)TILES * TILES];

static uint32_t main_region(const sim_map *m, uint32_t *size_out) {
    static uint32_t queue[(size_t)TILES * TILES];
    const uint32_t total = (uint32_t)TILES * TILES;
    memset(region, 0, sizeof region);
    uint32_t next = 0, best = 0, best_size = 0;
    for (uint32_t start = 0; start < total; start++) {
        if (region[start]) continue;
        if (!passable(m, (int)(start % TILES), (int)(start / TILES))) continue;
        uint32_t id = ++next, head = 0, tail = 0;
        region[start] = id;
        queue[tail++] = start;
        while (head < tail) {
            uint32_t i = queue[head++];
            int x = (int)(i % TILES), y = (int)(i / TILES);
            const int step[4][2] = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}};
            for (int k = 0; k < 4; k++) {
                int nx = x + step[k][0], ny = y + step[k][1];
                if (nx < 0 || ny < 0 || nx >= TILES || ny >= TILES) continue;
                uint32_t j = (uint32_t)ny * TILES + (uint32_t)nx;
                if (region[j] || !passable(m, nx, ny)) continue;
                region[j] = id;
                queue[tail++] = j;
            }
        }
        if (tail > best_size) {
            best_size = tail;
            best = id;
        }
    }
    *size_out = best_size;
    return best;
}

/* A tile a ship can be put down on: open, open for a tile around so a hull
 * that is 28 pixels across does not arrive already inside a wall, and on the
 * open space that leads somewhere. */
static int landable(const sim_map *m, uint32_t open, int tx, int ty) {
    if (tx < 1 || ty < 1 || tx >= TILES - 1 || ty >= TILES - 1) return 0;
    if (m->tile[(size_t)ty * TILES + (size_t)tx] != SIM_TILE_EMPTY) return 0;
    if (region[(size_t)ty * TILES + (size_t)tx] != open) return 0;
    for (int dy = -1; dy <= 1; dy++)
        for (int dx = -1; dx <= 1; dx++)
            if (!passable(m, tx + dx, ty + dy)) return 0;
    return 1;
}

#define SPAWN_CAP 128
#define SPAWN_STEP 4    /* candidates are sampled every fourth tile each way */
#define SPAWN_MARGIN 16 /* tiles of the world edge that are nobody's start */
#define CELL 32         /* the block a start has to share with some structure */

/* Which blocks of the map have anything in them.
 *
 * Most of a Subspace map is void: the structures are scattered across the
 * thousand tiles and the space between them is empty. A start in the middle of
 * that is a long flight from anything, so a candidate has to share its block
 * with a wall. This is also what keeps starts out of the four corners, which
 * are open, quiet, and the first thing a scan running north to south finds. */
static void built_blocks(const sim_map *m, uint8_t *cell) {
    memset(cell, 0, (TILES / CELL) * (TILES / CELL));
    for (int ty = 0; ty < TILES; ty++)
        for (int tx = 0; tx < TILES; tx++)
            if (SIM_TILE_CLASS(m->tile[(size_t)ty * TILES + (size_t)tx])
                == SIM_TILE_SOLID)
                cell[(ty / CELL) * (TILES / CELL) + tx / CELL] = 1;
}

/* Open ground, no two pieces of it within `sep` tiles of each other. Returns
 * how many were found, which is what the caller is really asking about. */
static int candidates(const sim_map *m, const uint8_t *cell, uint32_t open,
                      int sep, uint16_t *px, uint16_t *py) {
    int got = 0;
    for (int ty = SPAWN_MARGIN; ty < TILES - SPAWN_MARGIN; ty += SPAWN_STEP) {
        for (int tx = SPAWN_MARGIN; tx < TILES - SPAWN_MARGIN;
             tx += SPAWN_STEP) {
            if (!cell[(ty / CELL) * (TILES / CELL) + tx / CELL]) continue;
            if (!landable(m, open, tx, ty)) continue;
            int ok = 1;
            for (int i = 0; i < got; i++) {
                int dx = tx - (int)px[i], dy = ty - (int)py[i];
                if (dx * dx + dy * dy < sep * sep) {
                    ok = 0;
                    break;
                }
            }
            if (!ok) continue;
            px[got] = (uint16_t)tx;
            py[got] = (uint16_t)ty;
            if (++got == SPAWN_CAP) return got;
        }
    }
    return got;
}

/* Where ships start.
 *
 * A .lvl carries none of this: the original kept spawn regions in arena.conf,
 * which we are not reading. Without starts the server falls back to a tile it
 * has hardcoded, and on a converted map that tile is usually somebody's wall,
 * so a converted map with no starts is a map nobody can fly.
 *
 * So the starts are derived, at the widest spacing the map will give: try 256
 * tiles apart, and keep halving until there are enough places to stand. The
 * first spacing that fits is used rather than the smallest that works, because
 * a start every four tiles is a crowd and the point of these is to spread a
 * roster out.
 *
 * Then the northern half of what was chosen becomes team one and the southern
 * half team zero, so a flag game gets two home ends out of a file that says
 * nothing about sides. Splitting by rank rather than by the map's midpoint
 * matters: a map whose open ground is all in the north would otherwise put
 * every start on one team and leave the other side spawning wherever the
 * core's fallback lands. A mode without teams ignores the variant. */
static void place_spawns(sim_map *m, report *rp, int want) {
    uint16_t px[SPAWN_CAP], py[SPAWN_CAP];
    static uint8_t cell[(TILES / CELL) * (TILES / CELL)];
    int got = 0;
    if (want > SPAWN_CAP) want = SPAWN_CAP;
    built_blocks(m, cell);
    uint32_t open = main_region(m, &rp->open);
    for (int sep = 256; sep >= 1; sep /= 2) {
        got = candidates(m, cell, open, sep, px, py);
        if (got >= want) break;
    }
    if (got > want) {
        /* Thin the list evenly rather than taking the first of it: the scan
         * runs north to south, so the front of the list is the top of the
         * map. */
        for (int i = 0; i < want; i++) {
            int src = i * got / want;
            px[i] = px[src];
            py[i] = py[src];
        }
        got = want;
    }
    for (int i = 1; i < got; i++) { /* by latitude, so the split is a split */
        uint16_t kx = px[i], ky = py[i];
        int j = i - 1;
        for (; j >= 0 && py[j] > ky; j--) {
            px[j + 1] = px[j];
            py[j + 1] = py[j];
        }
        px[j + 1] = kx;
        py[j + 1] = ky;
    }
    for (int i = 0; i < got; i++) {
        uint8_t team = i < got / 2 ? 1 : 0;
        paint(m, px[i], py[i], SIM_TILE(SIM_TILE_SPAWN, team));
        rp->spawns[team]++;
    }
}

/* The core indexes wormholes, goals, turf and starts into a fixed table and
 * stops when it is full, in the order it walks the tiles. A turf map can have
 * more flag stands than that on its own, and the tiles it would lose are the
 * ones furthest down the map, which on a converted map is where half the
 * starts are. Rather than ship a map whose starts silently did not fit, the
 * surplus is dropped here, and the operator is told how much of it there was. */
static void fit_features(sim_map *m, report *rp) {
    int spawns = (int)(rp->spawns[0] + rp->spawns[1]);
    int budget = SIM_MAX_FEATURES - spawns;
    int seen = 0;
    for (size_t i = 0; i < sizeof m->tile; i++) {
        int c = SIM_TILE_CLASS(m->tile[i]);
        if (c != SIM_TILE_WORMHOLE && c != SIM_TILE_GOAL && c != SIM_TILE_TURF)
            continue;
        if (seen++ < budget) continue;
        m->tile[i] = SIM_TILE_EMPTY;
        rp->demoted++;
    }
}

static const char *class_name(int c) {
    switch (c) {
    case SIM_TILE_EMPTY: return "empty";
    case SIM_TILE_SOLID: return "solid";
    case SIM_TILE_SAFE: return "safe";
    case SIM_TILE_DOOR: return "door";
    case SIM_TILE_GOAL: return "goal";
    case SIM_TILE_WORMHOLE: return "wormhole";
    case SIM_TILE_OVER: return "over";
    case SIM_TILE_UNDER: return "under";
    case SIM_TILE_TURF: return "turf";
    case SIM_TILE_SPAWN: return "spawn";
    default: return "?";
    }
}

/* Find the tile records, and the metadata if the file has any.
 *
 * `bfSize` is where the tiles start and it is not always where the pixels end:
 * two of the five maps this was written against pad the gap by two bytes, so a
 * reader that measures the bitmap instead of believing the header decodes
 * every record half a field out of place. */
static const uint8_t *tile_section(const uint8_t *buf, size_t len, size_t *n,
                                   report *rp) {
    if (len >= 14 && buf[0] == 'B' && buf[1] == 'M') {
        size_t start = rd32(buf + 2);
        size_t meta = rd32(buf + 6);
        rp->has_tileset = 1;
        if (meta != 0 && meta + 12 <= len && rd32(buf + meta) == 0x6c766c65)
            rp->meta_off = meta;
        if (start > len) start = len;
        *n = len - start;
        return buf + start;
    }
    *n = len;
    return buf;
}

static uint8_t *slurp(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    if (fseek(f, 0, SEEK_END) != 0) {
        fclose(f);
        return NULL;
    }
    long end = ftell(f);
    if (end < 0) {
        fclose(f);
        return NULL;
    }
    rewind(f);
    uint8_t *buf = malloc((size_t)end + 1);
    if (!buf) {
        fclose(f);
        return NULL;
    }
    *len = fread(buf, 1, (size_t)end, f);
    fclose(f);
    return buf;
}

static int convert(const uint8_t *buf, size_t len, sim_map *m, report *rp,
                   int spawns) {
    /* A .lvl is a thousand tiles square and says so nowhere: the size is the
     * one thing about the original's format that was never in the file. */
    sim_map_size(m, TILES, TILES);
    memset(rp, 0, sizeof *rp);
    size_t n = 0;
    const uint8_t *tiles = tile_section(buf, len, &n, rp);
    read_tiles(m, tiles, n, rp);
    place_spawns(m, rp, spawns);
    fit_features(m, rp);
    for (size_t i = 0; i < sizeof m->tile; i++)
        rp->tiles[SIM_TILE_CLASS(m->tile[i])]++;
    sim_map_index(m);
    return rp->records > 0;
}

/* ---- self-test ----
 *
 * There is no fixture file to test against, on purpose: no asset from the
 * original enters this repository, and a .lvl is an asset. So the input is
 * built here, one record per rule worth checking. */
static void put(uint8_t *p, int i, int x, int y, unsigned type) {
    uint32_t v = (uint32_t)x | ((uint32_t)y << 12) | ((uint32_t)type << 24);
    for (int b = 0; b < 4; b++) p[i * 4 + b] = (uint8_t)(v >> (b * 8));
}

static int fails;

static void expect(int cond, const char *what) {
    if (!cond) {
        fprintf(stderr, "lvl2vw selftest: %s\n", what);
        fails++;
    }
}

static uint8_t at(const sim_map *m, int x, int y) {
    return m->tile[(size_t)y * TILES + (size_t)x];
}

static int selftest(void) {
    static uint8_t file[64 * 4];
    int i = 0;
    put(file, i++, 10, 10, 1);              /* ordinary wall */
    put(file, i++, 11, 10, 161);            /* last of the wall range */
    put(file, i++, 9, 11, LVL_BORDER);      /* the map edge */
    put(file, i++, 12, 10, 162);            /* first door, channel 0 */
    put(file, i++, 13, 10, 169);            /* last door, channel 7 */
    put(file, i++, 14, 10, 170);            /* turf */
    put(file, i++, 15, 10, 171);            /* safe */
    put(file, i++, 16, 10, 172);            /* goal */
    put(file, i++, 17, 10, 174);            /* over */
    put(file, i++, 18, 10, 190);            /* under */
    put(file, i++, 19, 10, 200);            /* undefined, and solid */
    put(file, i++, 20, 20, LVL_ASTEROID_BIG);
    put(file, i++, 30, 30, LVL_STATION);
    put(file, i++, 40, 40, LVL_WORMHOLE);
    put(file, i++, 50, 50, LVL_ASTEROID_SMALL);
    put(file, i++, 2000, 10, 1);            /* outside the world */
    put(file, i++, 60, 60, 1);              /* overwritten by the next */
    put(file, i++, 60, 60, 0);

    sim_map *m = malloc(sizeof *m);
    if (!m) return 1;
    report rp;
    /* No starts for the tile checks: a start is written over open ground, and
     * open ground is most of this map. */
    convert(file, (size_t)i * 4, m, &rp, 0);

    expect(rp.records == (uint32_t)i, "record count");
    expect(rp.offmap == 1, "off-map record counted");
    expect(rp.undefined == 1, "undefined type counted");
    expect(at(m, 10, 10) == SIM_TILE_SOLID, "wall");
    expect(at(m, 9, 11) == SIM_TILE(SIM_TILE_SOLID, V_BORDER),
           "the border is a wall that knows it");
    expect(at(m, 11, 10) == SIM_TILE_SOLID, "tile 161 is a wall");
    expect(at(m, 12, 10) == SIM_TILE(SIM_TILE_DOOR, 0), "first door channel");
    expect(at(m, 13, 10) == SIM_TILE(SIM_TILE_DOOR, 7), "last door channel");
    expect(at(m, 14, 10) == SIM_TILE_TURF, "turf");
    expect(at(m, 15, 10) == SIM_TILE_SAFE, "safe");
    expect(at(m, 16, 10) == SIM_TILE_GOAL, "goal");
    expect(at(m, 17, 10) == SIM_TILE_OVER, "over");
    expect(at(m, 18, 10) == SIM_TILE_UNDER, "under");
    expect(at(m, 19, 10) == SIM_TILE_SOLID, "undefined type is solid");
    /* Every tile of an object is solid; only its corner carries the picture,
     * which is what keeps a six-tile station from being drawn thirty-six
     * times. */
    expect(at(m, 20, 20) == SIM_TILE(SIM_TILE_SOLID, V_ROCK_BIG)
               && at(m, 21, 21) == SIM_TILE(SIM_TILE_SOLID, V_ROCK_BODY)
               && at(m, 22, 22) == SIM_TILE_EMPTY,
           "big asteroid is 2x2, cornered");
    expect(at(m, 30, 30) == SIM_TILE(SIM_TILE_SOLID, V_STATION)
               && at(m, 35, 35) == SIM_TILE(SIM_TILE_SOLID, V_STATION_BODY)
               && at(m, 36, 36) == SIM_TILE_EMPTY,
           "station is 6x6, cornered");
    expect(SIM_TILE_CLASS(at(m, 21, 21)) == SIM_TILE_SOLID
               && SIM_TILE_CLASS(at(m, 35, 35)) == SIM_TILE_SOLID,
           "an object's body is still a wall to fly into");
    expect(at(m, 42, 42) == SIM_TILE_WORMHOLE, "wormhole center");
    expect(at(m, 40, 40) == SIM_TILE_EMPTY && at(m, 44, 44) == SIM_TILE_EMPTY,
           "wormhole rim is open");
    expect(at(m, 50, 50) == SIM_TILE(SIM_TILE_SOLID, V_ROCK_A),
           "small asteroid");
    expect(at(m, 60, 60) == SIM_TILE_EMPTY, "a later record wins");

    /* Starts: asked for four, evenly split, and none of them in a wall. */
    report rps;
    convert(file, (size_t)i * 4, m, &rps, 4);
    expect(rps.spawns[0] == 2 && rps.spawns[1] == 2, "starts placed and split");
    int found = 0, boxed = 0;
    for (size_t k = 0; k < sizeof m->tile; k++) {
        if (SIM_TILE_CLASS(m->tile[k]) != SIM_TILE_SPAWN) continue;
        found++;
        int sx = (int)(k % TILES), sy = (int)(k / TILES);
        for (int dy = -1; dy <= 1; dy++)
            for (int dx = -1; dx <= 1; dx++)
                if ((dx || dy) && !passable(m, sx + dx, sy + dy)) boxed++;
    }
    expect(found == 4, "four starts on the map");
    expect(boxed == 0, "no start is in a wall");
    expect(m->feature_count >= 4, "starts reached the feature table");

    /* The same records behind a bitmap header, with the two-byte gap between
     * the pixels and the tiles that real maps have. */
    static uint8_t withbmp[64 * 4 + 64];
    size_t off = 40;
    memset(withbmp, 0, sizeof withbmp);
    withbmp[0] = 'B';
    withbmp[1] = 'M';
    for (int b = 0; b < 4; b++) withbmp[2 + b] = (uint8_t)(off >> (b * 8));
    memcpy(withbmp + off, file, (size_t)i * 4);
    report rp2;
    convert(withbmp, off + (size_t)i * 4, m, &rp2, 4);
    expect(rp2.has_tileset == 1, "bitmap seen");
    expect(rp2.records == rp.records, "same records behind a header");
    expect(at(m, 10, 10) == SIM_TILE_SOLID, "tiles found after the header");

    free(m);
    if (fails == 0) printf("lvl2vw selftest passed\n");
    return fails != 0;
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--selftest") == 0) return selftest();
    if (argc < 3) {
        fprintf(stderr,
                "usage: %s <in.lvl> <out.vwmap> [starts]\n"
                "       %s --selftest\n",
                argv[0], argv[0]);
        return 2;
    }
    int spawns = argc > 3 ? atoi(argv[3]) : 16;
    if (spawns < 0 || spawns > 64) {
        fprintf(stderr, "starts must be 0 to 64\n");
        return 2;
    }

    size_t len = 0;
    uint8_t *buf = slurp(argv[1], &len);
    if (!buf) {
        perror(argv[1]);
        return 1;
    }
    sim_map *m = malloc(sizeof *m);
    if (!m) return 1;
    report rp;
    if (!convert(buf, len, m, &rp, spawns)) {
        fprintf(stderr, "%s: no tile records, so this is not a map\n", argv[1]);
        return 1;
    }
    free(buf);

    uint8_t *out = malloc(SIM_MAP_PACK_MAX);
    if (!out) return 1;
    int n = sim_map_pack(m, out, SIM_MAP_PACK_MAX);
    if (n < 0) {
        fprintf(stderr, "pack failed\n");
        return 1;
    }
    /* Read back what is about to be written, through the same call the server
     * uses. An operator finds out here that a map does not load, rather than
     * on a live arena that refused to open. */
    sim_map *back = malloc(sizeof *back);
    if (!back) return 1;
    int r = sim_map_unpack(back, out, n);
    free(back);
    if (r != 0) {
        fprintf(stderr, "%s: packed to something the core will not load (%d)\n",
                argv[2], r);
        return 1;
    }

    FILE *f = fopen(argv[2], "wb");
    if (!f) {
        perror(argv[2]);
        return 1;
    }
    fwrite(out, 1, (size_t)n, f);
    fclose(f);

    printf("%s: %u records", argv[1], rp.records);
    if (rp.has_tileset) printf(", tileset dropped");
    if (rp.meta_off) printf(", eLVL metadata at %lu ignored",
                            (unsigned long)rp.meta_off);
    printf("\n");
    for (int c = 1; c < SIM_TILE_COUNT; c++)
        if (rp.tiles[c]) printf("  %-9s %u\n", class_name(c), rp.tiles[c]);
    printf("  starts    %u south, %u north, on %u tiles of open space\n",
           rp.spawns[0], rp.spawns[1], rp.open);
    if (rp.offmap) printf("  %u records outside the world, skipped\n", rp.offmap);
    if (rp.undefined)
        printf("  %u records of a type the format does not define\n",
               rp.undefined);
    if (rp.demoted)
        printf("  %u features past the core's %d, cleared\n", rp.demoted,
               SIM_MAX_FEATURES);
    printf("%s: %d bytes, hash %08x, %u features\n", argv[2], n,
           sim_map_hash(m), m->feature_count);
    free(out);
    free(m);
    return 0;
}
