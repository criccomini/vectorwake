/* Draw a map from measurements rather than from another map.
 *
 * docs/research/map-measurements.md records what a 1998 zone's map is made of:
 * three per cent of it is wall, four fifths of that wall is one tile thick,
 * and the rest is an open field with several hundred small structures standing
 * in it, clustered, with long empty lanes between the clusters. Those are
 * numbers about a map, not a map, and a number is not somebody's drawing.
 *
 * So this generates its own. The vocabulary below (rooms with gaps in them,
 * corner brackets, lattices of single tiles, stepped diagonals, capped bars)
 * is the vocabulary a thin-walled axis-aligned map is built from at all, and
 * the layout is this program's, seeded and reproducible. Nothing is traced.
 *
 *   make -C sim build/mapgen
 *   sim/build/mapgen catalog/zones/alpha/alpha.vwmap 23
 *
 * The seed is the whole of the map's provenance: same seed, same map, on any
 * machine, which is what lets the file be committed and still be explained.
 * Checks at the end are the part that matters, because a map that fails one
 * is unplayable in a way that only shows up with sixty people in it. Every
 * open tile has to be on one region, doors counted as shut, which means the
 * pockets two structures make between them are dug open before anything is
 * written. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sim/pack.h"
#include "sim/sim.h"

#define TILES SIM_MAP_TILES
#define EDGE 8 /* keep clear of the four-tile boundary sim_map_index paints */

/* ---- randomness ---------------------------------------------------------
 *
 * Park-Miller, and the top bits rather than the low ones: the low bits of a
 * 31-bit LCG are nearly periodic, which once had a card deck dealing four to
 * one (memory of that is in docs, the fix was the same one). */
static uint32_t rng_state = 1;
static void seed(uint32_t s) { rng_state = s ? s % 2147483647u : 1u; }
static uint32_t rnd(void) {
    rng_state = (uint32_t)(((uint64_t)rng_state * 16807u) % 2147483647u);
    return rng_state >> 8;
}
/* Uniform in [lo, hi]. */
static int rr(int lo, int hi) {
    if (hi <= lo) return lo;
    return lo + (int)(rnd() % (uint32_t)(hi - lo + 1));
}
static int chance(int percent) { return (int)(rnd() % 100u) < percent; }

/* ---- the canvas --------------------------------------------------------- */

static uint8_t *T; /* TILES*TILES, the map under construction */

static uint8_t get(int x, int y) {
    if (x < 0 || y < 0 || x >= TILES || y >= TILES) return SIM_TILE_SOLID;
    return T[(size_t)y * TILES + x];
}
static void put(int x, int y, uint8_t t) {
    if (x < EDGE || y < EDGE || x >= TILES - EDGE || y >= TILES - EDGE) return;
    T[(size_t)y * TILES + x] = t;
}
static void hline(int x0, int x1, int y, uint8_t t) {
    for (int x = x0; x <= x1; x++) put(x, y, t);
}
static void vline(int x, int y0, int y1, uint8_t t) {
    for (int y = y0; y <= y1; y++) put(x, y, t);
}

/* Is every tile in this box still empty, with `pad` tiles of margin? A
 * structure that lands on another one reads as a single shapeless mass, and
 * the measured map has almost none of that: its parts stand apart. */
static int clear_box(int x, int y, int w, int h, int pad) {
    if (x - pad < EDGE || y - pad < EDGE) return 0;
    if (x + w + pad >= TILES - EDGE || y + h + pad >= TILES - EDGE) return 0;
    for (int yy = y - pad; yy < y + h + pad; yy++)
        for (int xx = x - pad; xx < x + w + pad; xx++)
            if (T[(size_t)yy * TILES + xx] != SIM_TILE_EMPTY) return 0;
    return 1;
}

/* ---- motifs -------------------------------------------------------------
 *
 * Each draws inside (x, y, w, h) and touches nothing outside it. They are
 * hollow and one tile thick, which is the measured map's dominant texture:
 * cover you can shoot past, not mass you have to go around. */

/* When zero or more, a room hangs a door on this channel in its first gap
 * instead of leaving it open. A file static because the motif signature is
 * fixed and this is a tool rather than a library.
 *
 * Only the first gap, so a room is never shut on every side at once. */
static int room_door = -1;

/* A room, with gaps cut in its walls so it can be flown through rather than
 * only around. A sealed box is a place a bomb cannot reach and a ship can be
 * trapped behind; every room here has at least two ways in. */
static void m_room(int x, int y, int w, int h, uint8_t wall) {
    hline(x, x + w - 1, y, wall);
    hline(x, x + w - 1, y + h - 1, wall);
    vline(x, y, y + h - 1, wall);
    vline(x + w - 1, y, y + h - 1, wall);
    /* A sixth of them doubled. The measured map is not uniformly hairline:
     * a fifth of its wall runs are two tiles or more, and a doubled wall is
     * the difference between cover a bomb clears and cover it does not. */
    if (w > 12 && h > 12 && chance(18)) {
        hline(x + 1, x + w - 2, y + 1, wall);
        hline(x + 1, x + w - 2, y + h - 2, wall);
        vline(x + 1, y + 1, y + h - 2, wall);
        vline(x + w - 2, y + 1, y + h - 2, wall);
    }
    /* Cut on opposite sides first, so a room always has a way through and
     * not merely a way in. Two chosen at random can both land on one wall,
     * and a room with one open side is a dead end to be shot into. */
    for (int g = 0; g < rr(2, 4); g++) {
        int side = g < 2 ? (g == 0 ? 0 : 1) : rr(0, 3);
        if (g == 1 && chance(50)) side = 3; /* or opposite the other way */
        /* Shrink the gap to what the wall can hold rather than skipping it.
         * Skipping is how a room ends up sealed, and a sealed room is a
         * pocket no bomb reaches and no ship leaves. */
        int span = (side < 2 ? w : h) - 7;
        if (span < 2) continue;
        int len = rr(4, 7);
        if (len > span) len = span;
        /* Two tiles deep, so a gap goes through a doubled wall as well as a
         * single one. On a single wall the second tile is interior and was
         * empty already. The outer tile takes the door when there is one:
         * the inner one stays open, so a shut door is one tile thick like
         * the wall it stands in. */
        uint8_t outer = (g == 0 && room_door >= 0)
                      ? SIM_TILE(SIM_TILE_DOOR, room_door) : SIM_TILE_EMPTY;
        if (side < 2) {
            int gx = rr(x + 2, x + w - 3 - len);
            int gy = side ? y + h - 1 : y;
            hline(gx, gx + len, gy, outer);
            hline(gx, gx + len, side ? gy - 1 : gy + 1, SIM_TILE_EMPTY);
        } else {
            int gy = rr(y + 2, y + h - 3 - len);
            int gx = side == 2 ? x : x + w - 1;
            vline(gx, gy, gy + len, outer);
            vline(side == 2 ? gx + 1 : gx - 1, gy, gy + len, SIM_TILE_EMPTY);
        }
    }
}

/* Four corner pieces with the sides left open. Cover from one quarter of the
 * compass at a time, which is what makes it worth circling. */
static void m_brackets(int x, int y, int w, int h, uint8_t wall) {
    int a = rr(2, w / 3 > 2 ? w / 3 : 3);
    int b = rr(2, h / 3 > 2 ? h / 3 : 3);
    hline(x, x + a, y, wall);              vline(x, y, y + b, wall);
    hline(x + w - 1 - a, x + w - 1, y, wall);   vline(x + w - 1, y, y + b, wall);
    hline(x, x + a, y + h - 1, wall);      vline(x, y + h - 1 - b, y + h - 1, wall);
    hline(x + w - 1 - a, x + w - 1, y + h - 1, wall);
    vline(x + w - 1, y + h - 1 - b, y + h - 1, wall);
}

/* A regular field of single tiles. Reads as texture at radar scale and as
 * something to weave through up close, and it costs almost no wall to draw. */
static void m_lattice(int x, int y, int w, int h, uint8_t wall) {
    int step = rr(5, 6);
    for (int yy = y; yy < y + h; yy += step)
        for (int xx = x; xx < x + w; xx += step) put(xx, yy, wall);
}

/* A stepped 45-degree run. The only diagonal a tile grid has, and the reason
 * a shot fired along one skips rather than slides. */
static void m_chevron(int x, int y, int w, int h, uint8_t wall) {
    /* One short of the box, since the run thickens downward by a tile and a
     * motif that writes outside its own box lands on its neighbour. */
    int n = (w < h ? w : h) - 1;
    if (n < 2) return;
    int dx = chance(50) ? 1 : -1;
    int sx = dx > 0 ? x : x + n - 1;
    for (int i = 0; i < n; i++) {
        put(sx + dx * i, y + i, wall);
        if (chance(60)) put(sx + dx * i, y + i + 1, wall);
    }
    if (chance(45)) /* mirror it into a V */
        for (int i = 0; i < n; i++) put(sx + dx * (n - 1 - i), y + i, wall);
}

/* A bar with a cap at each end. Blocks along its length, and the caps stop a
 * ship rounding it in one motion. */
static void m_bar(int x, int y, int w, int h, uint8_t wall) {
    if (w >= h) {
        int my = y + h / 2;
        hline(x + 2, x + w - 3, my, wall);
        vline(x, y, y + h - 1, wall);
        vline(x + w - 1, y, y + h - 1, wall);
    } else {
        int mx = x + w / 2;
        vline(mx, y + 2, y + h - 3, wall);
        hline(x, x + w - 1, y, wall);
        hline(x, x + w - 1, y + h - 1, wall);
    }
}

/* Parallel lines of unequal length. Cheap, and it gives a lane a direction. */
static void m_stack(int x, int y, int w, int h, uint8_t wall) {
    int step = rr(4, 7);
    for (int yy = y; yy < y + h; yy += step) {
        int len = rr(w / 3 + 1, w);
        int off = rr(0, w - len);
        hline(x + off, x + off + len - 1, yy, wall);
    }
}

/* A room split into cells. The densest thing here, and the only motif with
 * interior corners worth hiding in. */
static void m_cells(int x, int y, int w, int h, uint8_t wall) {
    m_room(x, y, w, h, wall);
    int cols = rr(1, 3), rows = rr(1, 2);
    for (int c = 1; c <= cols; c++) {
        int cx = x + c * w / (cols + 1);
        vline(cx, y + 1, y + h - 2, wall);
        int gy = rr(y + 1, y + h - 4);
        vline(cx, gy, gy + 2, SIM_TILE_EMPTY);
    }
    for (int r = 1; r <= rows; r++) {
        int cy = y + r * h / (rows + 1);
        hline(x + 1, x + w - 2, cy, wall);
        int gx = rr(x + 1, x + w - 4);
        hline(gx, gx + 2, cy, SIM_TILE_EMPTY);
    }
}

/* Two long thin parallel lines. A lane with walls, open at both ends. */
static void m_spar(int x, int y, int w, int h, uint8_t wall) {
    if (w >= h) {
        hline(x, x + w - 1, y, wall);
        hline(x, x + w - 1, y + h - 1, wall);
    } else {
        vline(x, y, y + h - 1, wall);
        vline(x + w - 1, y, y + h - 1, wall);
    }
}

/* Loose single tiles. The measured map is full of them and they are the
 * cheapest way to break a sight line without blocking a lane. */
static void m_debris(int x, int y, int w, int h, uint8_t wall) {
    int n = rr(3, 12);
    for (int i = 0; i < n; i++) put(x + rr(0, w - 1), y + rr(0, h - 1), wall);
}

typedef void (*motif_fn)(int, int, int, int, uint8_t);

/* Weighted so the small cheap shapes dominate, which is what puts the
 * structure-span median near thirteen tiles rather than near forty. */
static const struct { motif_fn fn; int weight; int min_w, min_h; } MOTIFS[] = {
    { m_room,     18, 11, 11 },
    { m_brackets, 16, 10, 10 },
    { m_lattice,  12, 11, 11 },
    { m_chevron,  10, 7, 7 },
    { m_bar,      12, 7, 5 },
    { m_stack,    11, 8, 6 },
    { m_cells,     7, 18, 16 },
    { m_spar,      8, 12, 4 },
    { m_debris,    4, 8, 8 },
};
#define MOTIF_COUNT ((int)(sizeof MOTIFS / sizeof MOTIFS[0]))

static int pick_motif(int w, int h) {
    int total = 0;
    for (int i = 0; i < MOTIF_COUNT; i++)
        if (w >= MOTIFS[i].min_w && h >= MOTIFS[i].min_h) total += MOTIFS[i].weight;
    if (!total) return -1;
    int r = (int)(rnd() % (uint32_t)total);
    for (int i = 0; i < MOTIF_COUNT; i++) {
        if (w < MOTIFS[i].min_w || h < MOTIFS[i].min_h) continue;
        r -= MOTIFS[i].weight;
        if (r < 0) return i;
    }
    return -1;
}

/* ---- districts ----------------------------------------------------------
 *
 * Spreading structures perfectly evenly is not what the measured map does:
 * three quarters of its open runs are under seventy tiles and a tenth are
 * over a hundred and eighty, and uniform placement gives neither end. So the
 * field is divided into districts and each is built to its own density.
 *
 * How much variation is the whole question, and it has a measured answer.
 * Sorted into 128-tile squares, the measured map has **no empty square at
 * all**: its emptiest is 1.6% wall and its fullest 7.3%, a spread of 0.42
 * against the mean. At 64 tiles it is 3.6% empty and a spread of 0.65. In
 * other words it varies a lot up close and hardly at all across the map.
 *
 * An earlier version of this left a third of the districts empty outright,
 * which reads as the same idea and is not: it put 6% of the 128-squares at
 * zero and left 6.6% of the open ground more than forty tiles from any wall,
 * against 1.7% in the measured map. Wide open at that scale is not distance,
 * it is absence, and the map grows a quarter with nothing to fly to.
 *
 * So every district gets some wall, and the districts overlap. The long lanes
 * come from where the clusters inside a district happen not to be, which is
 * where they come from in the measured map too. */
#define DISTRICTS 30
#define SITES 3
static struct {
    int fullness;
    int n;
    struct { int x, y, r; } site[SITES];
} districts[DISTRICTS];

static void plan_districts(void) {
    int cols = 6, rows = 5, i = 0;
    int cw = (TILES - 2 * EDGE) / cols, ch = (TILES - 2 * EDGE) / rows;
    for (int r = 0; r < rows; r++)
        for (int c = 0; c < cols; c++) {
            /* Never zero. The thinnest district still gets built, it just
             * gets built sparsely, which is the difference between a quiet
             * quarter and an empty one. */
            districts[i].fullness = rr(3, 30);
            /* Two levels, because one is not enough to produce both halves of
             * what was measured. A district says which part of the map gets
             * built at all, and every district gets something: that is what
             * keeps any 128-tile square from coming out bare. A site says
             * where inside it the building goes, and a site is small: that is
             * what leaves open ground beside the structures rather than
             * spreading them over the whole district.
             *
             * Placing clusters evenly inside a district gives 4.5% of the
             * open ground more than twenty tiles from a wall where the
             * measured map has 15.3%. Same wall, same districts, nothing
             * wrong with it except that it was smeared. */
            districts[i].n = rr(1, SITES);
            for (int k = 0; k < districts[i].n; k++) {
                districts[i].site[k].x =
                    EDGE + c * cw + cw / 2 + rr(-cw / 3, cw / 3);
                districts[i].site[k].y =
                    EDGE + r * ch + ch / 2 + rr(-ch / 3, ch / 3);
                districts[i].site[k].r = rr(28, 62);
            }
            i++;
        }
}

static int pick_district(void) {
    int total = 0;
    for (int i = 0; i < DISTRICTS; i++) total += districts[i].fullness;
    /* Every district empty is a one-in-a-very-large-number seed rather than
     * an impossible one, and the modulo below would divide by zero on it. */
    if (total <= 0) return (int)(rnd() % DISTRICTS);
    int r = (int)(rnd() % (uint32_t)total);
    for (int i = 0; i < DISTRICTS; i++) {
        r -= districts[i].fullness;
        if (r < 0) return i;
    }
    return 0;
}

/* Structures do not sit alone at even spacing. They come in groups of two to
 * six of the same kind at the same size, in a row or a small grid. That is
 * what gives a map a ten-tile nearest-neighbour spacing at the same time as
 * open lanes: the short distances are inside a group. */
static int place_cluster(int big) {
    int cols = rr(1, 4), rows = rr(1, 3);
    if (cols * rows > 8) rows = 1;
    int w = big ? rr(28, 52) : rr(9, 26), h = big ? rr(26, 48) : rr(8, 24);
    /* A big cluster is drawn tight, so its members touch and the thing reads
     * as one compound rather than as three boxes in a row. That tight gap is
     * the whole of the span distribution's tail: without it every structure
     * on the map is the same size to look at, whatever its parts. */
    int gap = big ? rr(2, 5) : rr(7, 16);
    int cw = cols * w + (cols - 1) * gap;
    int ch = rows * h + (rows - 1) * gap;
    if (cw > 260 || ch > 260) return 0;

    int m = pick_motif(w, h);
    if (m < 0) return 0;

    for (int tries = 0; tries < 24; tries++) {
        int d = pick_district();
        int k = (int)(rnd() % (uint32_t)districts[d].n);
        int rad = districts[d].site[k].r;
        int x = districts[d].site[k].x + rr(-rad, rad) - cw / 2;
        int y = districts[d].site[k].y + rr(-rad, rad) - ch / 2;
        if (x < EDGE + 2 || y < EDGE + 2) continue;
        if (x + cw >= TILES - EDGE - 3 || y + ch >= TILES - EDGE - 3) continue;
        if (!clear_box(x, y, cw, ch, rr(4, 9))) continue;
        /* A sixth of the groups are hung with doors, all on one channel, so
         * a channel closing shuts a place rather than a scattering of
         * unrelated tiles. */
        room_door = chance(18) ? (int)(rnd() % 6u) : -1;
        for (int r = 0; r < rows; r++)
            for (int c = 0; c < cols; c++) {
                /* A group is repetition, not a stencil: one in six members
                 * takes a different shape, so a row reads as built rather
                 * than stamped. */
                int mm = chance(17) ? pick_motif(w, h) : m;
                if (mm < 0) mm = m;
                MOTIFS[mm].fn(x + c * (w + gap), y + r * (h + gap), w, h,
                              SIM_TILE_SOLID);
            }
        room_door = -1;
        return cols * rows;
    }
    return 0;
}

/* ---- the big pieces -----------------------------------------------------
 *
 * A handful of structures far larger than the rest. They are what a player
 * navigates by, since a map with no landmark is a map where every direction
 * looks the same, and they are the only places here with an inside. */
static void place_hall(int x, int y, int w, int h, int channel) {
    m_room(x, y, w, h, SIM_TILE_SOLID);
    /* Axial ways in, on a door channel, so the inside can be shut. */
    int dw = rr(4, 7);
    int mx = x + w / 2 - dw / 2, my = y + h / 2 - dw / 2;
    hline(mx, mx + dw, y, SIM_TILE(SIM_TILE_DOOR, channel));
    hline(mx, mx + dw, y + h - 1, SIM_TILE(SIM_TILE_DOOR, channel));
    vline(x, my, my + dw, SIM_TILE(SIM_TILE_DOOR, channel));
    vline(x + w - 1, my, my + dw, SIM_TILE(SIM_TILE_DOOR, channel));

    /* Furniture, so the inside is a fight rather than a courtyard. */
    int inner = rr(2, 4);
    for (int i = 0; i < inner; i++) {
        int iw = rr(6, w / 3), ih = rr(6, h / 3);
        int ix = rr(x + 4, x + w - iw - 5), iy = rr(y + 4, y + h - ih - 5);
        int mm = pick_motif(iw, ih);
        if (mm >= 0) MOTIFS[mm].fn(ix, iy, iw, ih, SIM_TILE_SOLID);
    }
}

/* ---- barriers -----------------------------------------------------------
 *
 * A long line of door tiles running out of a wall: open for part of its cycle
 * and a wall for the rest, so a route has to be re-read rather than
 * memorised.
 *
 * Two things here were measured rather than invented, and both corrected a
 * guess. The measured map's door tiles are not scattered entrances: they are
 * 28 runs, half of them longer than nine tiles and the longest 255, and every
 * single one of them is attached to a wall. None stands on its own in open
 * ground.
 *
 * The free-standing version this replaced also played worse, which is how the
 * guess was caught before the measurement was taken properly: twenty fences
 * in open lanes cost a third of the kills, a fence across a lane being
 * something to fly around on the way to a fight rather than through.
 *
 * Attached at one end only, and that is the whole of why it cannot seal
 * anything. A barrier bridging two structures divides the field when its
 * channel shuts; one with a free end is always flown around. */
static int place_barrier(int channel) {
    static const int DX[4] = { 1, -1, 0, 0 };
    static const int DY[4] = { 0, 0, 1, -1 };
    for (int tries = 0; tries < 900; tries++) {
        int x = rr(EDGE + 20, TILES - EDGE - 21);
        int y = rr(EDGE + 20, TILES - EDGE - 21);
        if (SIM_TILE_CLASS(get(x, y)) != SIM_TILE_SOLID) continue;
        int d = rr(0, 3);
        int want = rr(25, 120);
        /* Step off the wall first: the run starts in open ground beside it. */
        int sx = x + DX[d], sy = y + DY[d];
        if (SIM_TILE_CLASS(get(sx, sy)) != SIM_TILE_EMPTY) continue;
        /* Walk as far as the open ground goes, keeping a tile of clearance
         * either side so the line does not graze another structure. */
        int len = 0;
        while (len < want) {
            int cx = sx + DX[d] * len, cy = sy + DY[d] * len;
            if (SIM_TILE_CLASS(get(cx, cy)) != SIM_TILE_EMPTY) break;
            int px = DY[d], py = DX[d]; /* perpendicular */
            if (SIM_TILE_CLASS(get(cx + px, cy + py)) != SIM_TILE_EMPTY) break;
            if (SIM_TILE_CLASS(get(cx - px, cy - py)) != SIM_TILE_EMPTY) break;
            len++;
        }
        if (len < 12) continue;
        uint8_t t = SIM_TILE(SIM_TILE_DOOR, channel);
        for (int i = 0; i < len; i++) put(sx + DX[d] * i, sy + DY[d] * i, t);
        return len;
    }
    return 0;
}

/* ---- safe zones ---------------------------------------------------------
 *
 * The one place a ship can stop, so they are spread rather than paired: a
 * player who wants out of a fight should not have to cross the map to find
 * the exit, and a player camping one should not be covering the only one.
 *
 * Nine anchors rather than nine rolls of the dice. Placed at random they
 * clustered, which is measurable and was: a median of 94 tiles between
 * neighbours where the measured map has 291, and five of the map's sixteen
 * quarters holding all of them where the measured map uses eight. Spread is
 * the entire point of having nine, so it is arranged rather than hoped for. */
static const struct { int x, y; } DOCK_ANCHORS[9] = {
    { 170, 150 }, { 512, 120 }, { 860, 170 },
    { 130, 500 }, { 600, 380 }, { 890, 480 },
    { 180, 860 }, { 520, 900 }, { 870, 850 },
};

static int place_dock(int n) {
    /* Matched to the measured map's berths: nine wide and eight tall for
     * most of them, and two in five cut down to a narrow berth. Their median
     * is 72 tiles against a mean of 58, which is a spread of sizes rather
     * than nine of a kind. */
    int w = rr(8, 11), h = rr(7, 8);
    if (chance(42)) { w = rr(5, 6); h = rr(7, 8); }
    int ax = DOCK_ANCHORS[n].x, ay = DOCK_ANCHORS[n].y;
    /* Search outward from the anchor rather than across the map, so a berth
     * that cannot sit exactly where it was asked for still lands near it. */
    for (int radius = 20; radius <= 220; radius += 12) {
        for (int tries = 0; tries < 120; tries++) {
            int x = ax + rr(-radius, radius), y = ay + rr(-radius, radius);
            if (x < EDGE + 20 || y < EDGE + 20) continue;
            if (x + w >= TILES - EDGE - 20 || y + h >= TILES - EDGE - 20) continue;
            if (!clear_box(x, y, w, h, 16)) continue;
            for (int yy = y; yy < y + h; yy++)
                for (int xx = x; xx < x + w; xx++) put(xx, yy, SIM_TILE_SAFE);
            /* A frame on two sides, so it reads as a berth and not as a
             * stain, and so a ship inside has something to hide behind on
             * the way out. */
            hline(x - 2, x + w + 1, y - 2, SIM_TILE_SOLID);
            hline(x - 2, x + w + 1, y + h + 1, SIM_TILE_SOLID);
            return 1;
        }
    }
    return 0;
}

/* ---- placement checks ---------------------------------------------------
 *
 * Everything below runs on the finished tiles. A map is not done because it
 * was drawn; it is done when a ship can get from any start to any other. */

static int32_t *comp; /* component id per tile, 0 = wall */

/* Flood the open tiles, doors counted as walls, which is the worst case a
 * shut channel can produce. Returns the id of the largest region. */
static int32_t label_open(size_t *out_main_size) {
    static int32_t *stack;
    if (!stack) stack = malloc(sizeof(int32_t) * TILES * TILES);
    memset(comp, 0, sizeof(int32_t) * TILES * TILES);
    int32_t cur = 0;
    int32_t best = 0;
    size_t best_n = 0;
    for (int y = 0; y < TILES; y++)
        for (int x = 0; x < TILES; x++) {
            size_t i0 = (size_t)y * TILES + x;
            uint8_t c = SIM_TILE_CLASS(T[i0]);
            if (c == SIM_TILE_SOLID || c == SIM_TILE_DOOR || comp[i0]) continue;
            cur++;
            size_t n = 0, sp = 0;
            stack[sp++] = (int32_t)i0;
            comp[i0] = cur;
            while (sp) {
                int32_t i = stack[--sp];
                n++;
                int cx = i % TILES, cy = i / TILES;
                static const int dx[4] = { 1, -1, 0, 0 };
                static const int dy[4] = { 0, 0, 1, -1 };
                for (int d = 0; d < 4; d++) {
                    int nx = cx + dx[d], ny = cy + dy[d];
                    if (nx < 0 || ny < 0 || nx >= TILES || ny >= TILES) continue;
                    size_t j = (size_t)ny * TILES + nx;
                    uint8_t jc = SIM_TILE_CLASS(T[j]);
                    if (jc == SIM_TILE_SOLID || jc == SIM_TILE_DOOR || comp[j]) continue;
                    comp[j] = cur;
                    stack[sp++] = (int32_t)j;
                }
            }
            if (n > best_n) { best_n = n; best = cur; }
        }
    *out_main_size = best_n;
    return best;
}

/* Break every sealed pocket open, so no part of the field is walled off.
 *
 * Drawing structures independently makes pockets whether or not any one of
 * them is closed: two open shapes standing near each other enclose the ground
 * between them. It is not a rare case, it is dozens per map.
 *
 * An enclosed pocket is worse than wasted ground. A ship warped or shoved
 * into one cannot leave, a prize that lands in one is gone, and a bot that
 * routes toward one grinds on the wall in front of it. So each is joined to
 * the main region by digging out the shortest line of wall between them: a
 * breadth-first search outward from the pocket through wall tiles, cleared
 * once it arrives. Shortest, so a one-tile wall costs one tile, which is what
 * nearly all of them are.
 *
 * Doors count as wall throughout, so a pocket reachable only through a door
 * is still a pocket: its channel shuts for part of every cycle and a ship
 * inside would be held there until it opened. */
static int open_pockets(int32_t main) {
    static int32_t *queue, *from;
    if (!queue) queue = malloc(sizeof(int32_t) * TILES * TILES);
    if (!from) from = malloc(sizeof(int32_t) * TILES * TILES);
    if (!queue || !from) return -1;
    int dug = 0;

    for (size_t seed_i = 0; seed_i < (size_t)TILES * TILES; seed_i++) {
        if (comp[seed_i] == 0 || comp[seed_i] == main) continue;
        int32_t pocket = comp[seed_i];

        /* Walk out through wall, remembering each tile's predecessor, and
         * stop at the first tile of any other region. */
        size_t head = 0, tail = 0;
        for (size_t i = 0; i < (size_t)TILES * TILES; i++) from[i] = -1;
        for (size_t i = 0; i < (size_t)TILES * TILES; i++)
            if (comp[i] == pocket) { queue[tail++] = (int32_t)i; from[i] = (int32_t)i; }

        int32_t hit = -1;
        static const int dx[4] = { 1, -1, 0, 0 };
        static const int dy[4] = { 0, 0, 1, -1 };
        while (head < tail && hit < 0) {
            int32_t i = queue[head++];
            int cx = i % TILES, cy = i / TILES;
            for (int d = 0; d < 4 && hit < 0; d++) {
                int nx = cx + dx[d], ny = cy + dy[d];
                if (nx < EDGE || ny < EDGE) continue;
                if (nx >= TILES - EDGE || ny >= TILES - EDGE) continue;
                size_t j = (size_t)ny * TILES + nx;
                if (from[j] >= 0) continue;
                from[j] = i;
                if (comp[j] != 0 && comp[j] != pocket) hit = (int32_t)j;
                else if (comp[j] == 0) queue[tail++] = (int32_t)j;
            }
        }
        if (hit < 0) continue; /* nothing to join it to, which cannot happen
                                * on a bounded map but is not worth crashing
                                * over if it ever does */

        /* Clear the wall the search came through, and mark the pocket joined
         * so its tiles are not searched again. */
        for (int32_t i = from[hit]; i != from[i]; i = from[i]) {
            if (SIM_TILE_CLASS(T[i]) == SIM_TILE_EMPTY) continue;
            T[i] = SIM_TILE_EMPTY;
            dug++;
        }
        int32_t joined = comp[hit] == main ? main : comp[hit];
        for (size_t i = 0; i < (size_t)TILES * TILES; i++)
            if (comp[i] == pocket) comp[i] = joined;
    }
    return dug;
}

/* A spawn needs room around it: a ship that materialises against a wall is a
 * ship that spends its first second stuck to one. */
static int open_around(int x, int y, int r, int32_t main) {
    for (int yy = y - r; yy <= y + r; yy++)
        for (int xx = x - r; xx <= x + r; xx++) {
            if (xx < EDGE || yy < EDGE || xx >= TILES - EDGE || yy >= TILES - EDGE)
                return 0;
            if (SIM_TILE_CLASS(get(xx, yy)) != SIM_TILE_EMPTY) return 0;
            if (comp[(size_t)yy * TILES + xx] != main) return 0;
        }
    return 1;
}

/* Eight a side, north and south, spread across the width. Two home ends
 * rather than sixteen scattered points, because a team that spawns among its
 * opponents is a team that never forms up. */
static int place_spawns(int32_t main) {
    int placed = 0;
    for (int team = 0; team < 2; team++) {
        int y_lo = team ? EDGE + 24 : TILES / 2 + 40;
        int y_hi = team ? TILES / 2 - 40 : TILES - EDGE - 25;
        for (int i = 0; i < 8; i++) {
            /* One band of the width per spawn, so eight ships do not stack. */
            int x_lo = EDGE + 24 + i * (TILES - 2 * EDGE - 48) / 8;
            int x_hi = EDGE + 24 + (i + 1) * (TILES - 2 * EDGE - 48) / 8 - 1;
            int ok = 0;
            for (int tries = 0; tries < 3000 && !ok; tries++) {
                int x = rr(x_lo, x_hi), y = rr(y_lo, y_hi);
                if (!open_around(x, y, 6, main)) continue;
                put(x, y, SIM_TILE(SIM_TILE_SPAWN, team));
                ok = 1; placed++;
            }
        }
    }
    return placed;
}

/* Draw one whole map into `m`. Returns 0 when every check passes, and says
 * on stderr which one did not otherwise. `quiet` is for the selftest, which
 * runs several seeds and wants a line only when something is wrong. */
static int generate(sim_map *m, uint32_t s, int quiet) {
    seed(s);
    T = m->tile;
    memset(T, SIM_TILE_EMPTY, (size_t)TILES * TILES);

    /* Landmarks first, while there is room for them. Placed by hand in a
     * loose ring rather than at random, because four big rooms that land in
     * one corner leave half the map featureless. */
    static const struct { int x, y, w, h; } HALLS[] = {
        { 190, 150, 120, 104 }, { 690, 190, 132, 116 },
        { 140, 660, 128, 112 }, { 720, 700, 116, 124 },
        { 430, 430, 150, 140 },
    };
    for (int i = 0; i < (int)(sizeof HALLS / sizeof HALLS[0]); i++) {
        int jx = rr(-24, 24), jy = rr(-24, 24);
        place_hall(HALLS[i].x + jx, HALLS[i].y + jy, HALLS[i].w, HALLS[i].h, i % 6);
    }

    /* Everything that has to exist asks before anything that merely fills.
     * Placement is rejection sampling, so the last caller asks for room that
     * is already gone: nine berths on nine anchors became four when the field
     * went in first, and the same ordering is why the big clusters run ahead
     * of the small ones. */
    int docks = 0;
    for (int i = 0; i < 9; i++) docks += place_dock(i);

    /* One wormhole, off centre. A single one is a landmark and a hazard; a
     * field of them is a physics demo. */
    int wormholes = 0;
    for (int tries = 0; tries < 500 && !wormholes; tries++) {
        int x = rr(380, 660), y = rr(380, 660);
        if (!clear_box(x, y, 1, 1, 20)) continue;
        put(x, y, SIM_TILE_WORMHOLE);
        wormholes = 1;
    }

    /* Then the field. Asking for more clusters than can fit is how the count
     * lands where it lands: placement refuses anything that would overlap. */
    plan_districts();
    int structures = 0;
    for (int i = 0; i < 85; i++) structures += place_cluster(1);
    for (int i = 0; i < 950; i++) structures += place_cluster(0);

    /* Barriers spread over six channels, so a shut lane here is an open one
     * there rather than the whole map breathing in and out together. Enough
     * of them to reach the measured map's eight hundred door tiles between
     * them and the doors already hung on structures. */
    int barrier_tiles = 0;
    for (int i = 0; i < 11; i++) barrier_tiles += place_barrier(i % 6);

    sim_map_index(m);

    /* Join every pocket to the field, then label again: the digging changes
     * the answer, and what the spawns are checked against has to be the map
     * as it will be written rather than as it was drawn. */
    size_t main_n = 0;
    int32_t main_c = label_open(&main_n);
    int dug = open_pockets(main_c);
    main_c = label_open(&main_n);
    int spawns = place_spawns(main_c);

    /* Report, and refuse to write a map that cannot be played. */
    size_t solid = 0, safe = 0, door = 0, open_total = 0;
    for (size_t i = 0; i < (size_t)TILES * TILES; i++) {
        uint8_t c = SIM_TILE_CLASS(T[i]);
        if (c == SIM_TILE_SOLID) solid++;
        else if (c == SIM_TILE_SAFE) safe++;
        else if (c == SIM_TILE_DOOR) door++;
        if (c != SIM_TILE_SOLID && c != SIM_TILE_DOOR) open_total++;
    }
    size_t inner = (size_t)(TILES - 8) * (TILES - 8);
    double solid_pct = 100.0 * (double)(solid - (size_t)(TILES * TILES - inner))
                     / (double)inner;

    int stranded = 0;
    for (size_t i = 0; i < (size_t)TILES * TILES; i++) {
        uint8_t c = SIM_TILE_CLASS(T[i]);
        if ((c == SIM_TILE_SAFE || c == SIM_TILE_SPAWN || c == SIM_TILE_WORMHOLE)
            && comp[i] != main_c) stranded++;
    }

    double one_region = 100.0 * (double)main_n / (double)open_total;
    if (!quiet) {
        printf("seed %u: solid %.2f%% of interior, %zu safe, %zu door (%d in"
               " barriers), %d structures, %d docks, %d spawns\n", s, solid_pct,
               safe, door, barrier_tiles, structures, docks, spawns);
        printf("  open in one region: %.2f%%, %d wall tiles dug to join pockets,"
               " stranded features: %d\n", one_region, dug, stranded);
    }

    if (spawns != 16) {
        fprintf(stderr, "seed %u: only %d spawns placed\n", s, spawns);
        return 1;
    }
    if (docks != 9) {
        fprintf(stderr, "seed %u: only %d docks placed\n", s, docks);
        return 1;
    }
    if (!wormholes) {
        fprintf(stderr, "seed %u: no room for the wormhole\n", s);
        return 1;
    }
    if (stranded) {
        fprintf(stderr, "seed %u: %d features walled off\n", s, stranded);
        return 1;
    }
    /* Every open tile on one region, not almost every one. A pocket is a
     * place a ship can be put and cannot leave, so a threshold here would be
     * a threshold on how much of the map is a trap. */
    if (one_region < 100.0) {
        fprintf(stderr, "seed %u: open space is not one region (%.4f%%)\n",
                s, one_region);
        return 1;
    }
    if (dug < 0) {
        fprintf(stderr, "seed %u: could not join the pockets\n", s);
        return 1;
    }
    /* A map far off the measured three per cent is not wrong so much as not
     * the thing this program is for, and the seed that produced it should be
     * looked at rather than shipped. */
    if (solid_pct < 2.0 || solid_pct > 4.5) {
        fprintf(stderr, "seed %u: %.2f%% solid is outside the intended range\n",
                s, solid_pct);
        return 1;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <out.vwmap> [seed]\n       %s --selftest\n",
                argv[0], argv[0]);
        return 2;
    }
    sim_map *m = calloc(1, sizeof *m);
    comp = malloc(sizeof(int32_t) * TILES * TILES);
    if (!m || !comp) return 1;

    /* Twelve seeds, none of them the shipped one, because the check worth
     * having is that the generator produces a playable map generally and not
     * that it once did. */
    if (strcmp(argv[1], "--selftest") == 0) {
        for (uint32_t k = 101; k <= 112; k++)
            if (generate(m, k, 1) != 0) return 1;
        printf("mapgen selftest passed\n");
        free(comp); free(m);
        return 0;
    }

    uint32_t s = argc > 2 ? (uint32_t)strtoul(argv[2], NULL, 10) : 1u;
    if (generate(m, s, 0) != 0) return 1;

    uint8_t *buf = malloc(SIM_MAP_PACK_MAX);
    if (!buf) return 1;
    int n = sim_map_pack(m, buf, SIM_MAP_PACK_MAX);
    if (n < 0) { fprintf(stderr, "pack failed\n"); return 1; }
    FILE *f = fopen(argv[1], "wb");
    if (!f) { perror(argv[1]); return 1; }
    fwrite(buf, 1, (size_t)n, f);
    fclose(f);
    printf("  %s: %d bytes, hash %08x, %u features\n", argv[1], n,
           sim_map_hash(m), m->feature_count);
    free(buf); free(comp); free(m);
    return 0;
}
