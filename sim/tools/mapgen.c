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
 *   sim/build/mapgen catalog/zones/alpha/alpha.vwmap 28
 *
 * The seed is the whole of the map's provenance: same seed, same map, on any
 * machine, which is what lets the file be committed and still be explained.
 * Checks at the end are the part that matters, because a map that fails one
 * is unplayable in a way that only shows up with sixty people in it. They
 * are made against a hull rather than against a point: what has to come out
 * as one region is the set of tiles a ship fits on, doors counted as shut,
 * and the ground that set cannot reach is walled off before anything is
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

/* ---- centring -----------------------------------------------------------
 *
 * Every part of a structure is placed from the middle of the thing it sits
 * in rather than from a corner, because a shape is read by its axes: a gap
 * one tile off center is a gap that does not face the one opposite it, and
 * the only way to find that out is to fly at it and stop.
 *
 * Parity is the whole of the arithmetic. A run of `k` tiles centers exactly
 * in a span of `len` only when the two are both odd or both even, so a
 * length is adjusted to the span before it is placed rather than rounded
 * into it afterwards. */

/* `k`, moved to the span's parity so `centered` below divides evenly. */
static int fits(int len, int k) { return ((len ^ k) & 1) ? k + 1 : k; }

/* Where a run of `k` starts when it is centered in `len` tiles from `at`. */
static int centered(int at, int len, int k) { return at + (len - k) / 2; }

/* A gap of about `want` tiles, centered in a wall `span` long: as wide as
 * asked for, or as wide as the wall can hold with its corners left standing,
 * and of the wall's parity. Zero when the wall is too short to cut. */
static int gap_len(int span, int want) {
    int most = span - 6;
    if (want > most) want = most;
    if ((span ^ want) & 1) want--;
    return want < 2 ? 0 : want;
}

/* A row of `step`-spaced tiles centered in `span`: how many fit, and where
 * the first one goes. Two structures drawn the same way side by side then
 * line up with each other, which is the point. */
static void grid_span(int at, int span, int step, int *start, int *count) {
    int n = (span - 1) / step + 1;
    *count = n;
    *start = centered(at, span, (n - 1) * step + 1);
}

/* ---- motifs -------------------------------------------------------------
 *
 * Each draws inside (x, y, w, h) and touches nothing outside it. They are
 * hollow and one tile thick, which is the measured map's dominant texture:
 * cover you can shoot past, not mass you have to go around.
 *
 * They are also symmetric, on one axis at least and usually both. A map
 * drawn from random offsets reads as rubble however carefully its density
 * was measured, and rubble is the one thing a player cannot navigate by. */

/* When zero or more, a room hangs doors on this channel across one of its
 * two ways through instead of leaving both open. A file static because the
 * motif signature is fixed and this is a tool rather than a library.
 *
 * One way through only, and only when the room has two, so a room is never
 * shut on every side at once. */
static int room_door = -1;

/* A room, with gaps cut in its walls so it can be flown through rather than
 * only around. A sealed box is a place a bomb cannot reach and a ship can be
 * trapped behind; every room here has at least two ways in.
 *
 * The gaps come in opposite pairs at the middle of the wall, so a room is
 * something to fly straight through on either axis and looks the same from
 * both sides of it. Cut at random offsets they mostly do not line up, which
 * turns a room into a chicane and leaves whichever wall was missed as the
 * side to be shot into with no way out behind you. */
static void m_room(int x, int y, int w, int h, uint8_t wall) {
    int x1 = x + w - 1, y1 = y + h - 1;
    hline(x, x1, y, wall);
    hline(x, x1, y1, wall);
    vline(x, y, y1, wall);
    vline(x1, y, y1, wall);
    /* A sixth of them doubled. The measured map is not uniformly hairline:
     * a fifth of its wall runs are two tiles or more, and a doubled wall is
     * the difference between cover a bomb clears and cover it does not. */
    if (w > 12 && h > 12 && chance(18)) {
        hline(x + 1, x1 - 1, y + 1, wall);
        hline(x + 1, x1 - 1, y1 - 1, wall);
        vline(x + 1, y + 1, y1 - 1, wall);
        vline(x1 - 1, y + 1, y1 - 1, wall);
    }
    /* Both axes on most of them, one on the rest. A room cut on one axis is
     * still a room with two ways in, since a pair is what is cut. */
    int across = gap_len(w, rr(5, 8)), down = gap_len(h, rr(5, 8));
    int both = chance(65);
    if (!both && chance(50)) across = 0;
    else if (!both) down = 0;
    if (!across && !down) across = gap_len(w, 5);
    /* The pair on one axis can be hung with doors, and only when the other
     * axis is open: a room shut on every side is a room a ship is held in
     * for as long as the channel is closed. */
    uint8_t shut = SIM_TILE(SIM_TILE_DOOR, room_door < 0 ? 0 : room_door);
    int hang = room_door >= 0 && across && down ? (chance(50) ? 1 : 2) : 0;
    /* Two tiles deep, so a gap goes through a doubled wall as well as a
     * single one. On a single wall the second tile is interior and was
     * empty already. The outer tile takes the door when there is one: the
     * inner one stays open, so a shut door is one tile thick like the wall
     * it stands in. */
    if (across) {
        int gx = centered(x, w, across);
        uint8_t t = hang == 1 ? shut : SIM_TILE_EMPTY;
        hline(gx, gx + across - 1, y, t);
        hline(gx, gx + across - 1, y + 1, SIM_TILE_EMPTY);
        hline(gx, gx + across - 1, y1, t);
        hline(gx, gx + across - 1, y1 - 1, SIM_TILE_EMPTY);
    }
    if (down) {
        int gy = centered(y, h, down);
        uint8_t t = hang == 2 ? shut : SIM_TILE_EMPTY;
        vline(x, gy, gy + down - 1, t);
        vline(x + 1, gy, gy + down - 1, SIM_TILE_EMPTY);
        vline(x1, gy, gy + down - 1, t);
        vline(x1 - 1, gy, gy + down - 1, SIM_TILE_EMPTY);
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

/* A regular field of single tiles, centered in its box so that two of them
 * side by side share one grid. Reads as texture at radar scale and as
 * something to weave through up close, and it costs almost no wall to draw. */
static void m_lattice(int x, int y, int w, int h, uint8_t wall) {
    int step = rr(5, 6), sx, sy, nx, ny;
    grid_span(x, w, step, &sx, &nx);
    grid_span(y, h, step, &sy, &ny);
    for (int j = 0; j < ny; j++)
        for (int i = 0; i < nx; i++) put(sx + i * step, sy + j * step, wall);
}

/* A stepped 45-degree run: the only diagonal a tile grid has, and the reason
 * a shot fired along one skips rather than slides.
 *
 * One tile per step and never two. A second tile below each step drew a
 * diagonal twice as thick as every other wall on the map, which is not a
 * heavier line so much as a different material, and at radar scale it was
 * the one shape that read as a smear rather than as a line.
 *
 * Three forms, each of them symmetric and each centered on its box: one arm,
 * two arms crossed, or two meeting at a point. An odd span, so the two arms
 * of a cross meet on exactly one tile instead of passing each other. */
static void m_chevron(int x, int y, int w, int h, uint8_t wall) {
    int n = w < h ? w : h;
    if (!(n & 1)) n--;
    if (n < 3) return;
    int ox = centered(x, w, n), oy = centered(y, h, n);
    int form = rr(0, 2);
    if (form == 2) { /* two arms meeting at a point: V, its mirror, < or > */
        int m = (n + 1) / 2, far = chance(50), down = chance(50);
        int off = (n - m) / 2; /* the point and its arms span half the box */
        for (int i = 0; i < m; i++) {
            int lo = m - 1 - i, hi = m - 1 + i;
            int at = off + (far ? m - 1 - i : i);
            if (down) { put(ox + at, oy + lo, wall); put(ox + at, oy + hi, wall); }
            else { put(ox + lo, oy + at, wall); put(ox + hi, oy + at, wall); }
        }
        return;
    }
    int cross = chance(45); /* an X, or the single arm on its own */
    int back = chance(50);  /* which way a single arm leans */
    for (int i = 0; i < n; i++) {
        if (cross || !back) put(ox + i, oy + i, wall);
        if (cross || back) put(ox + n - 1 - i, oy + i, wall);
    }
}

/* A bar with a cap at each end. Blocks along its length, and the caps stop a
 * ship rounding it in one motion. The bar sits on the middle of the caps, so
 * the odd span is taken off the box rather than out of the centring. */
static void m_bar(int x, int y, int w, int h, uint8_t wall) {
    if (w >= h) {
        int n = h | 1;
        if (n > h) n = h - 1;
        int y0 = centered(y, h, n);
        hline(x + 2, x + w - 3, y0 + n / 2, wall);
        vline(x, y0, y0 + n - 1, wall);
        vline(x + w - 1, y0, y0 + n - 1, wall);
    } else {
        int n = w | 1;
        if (n > w) n = w - 1;
        int x0 = centered(x, w, n);
        vline(x0 + n / 2, y + 2, y + h - 3, wall);
        hline(x0, x0 + n - 1, y, wall);
        hline(x0, x0 + n - 1, y + h - 1, wall);
    }
}

/* Parallel lines, centered on the box and the same length either side of the
 * middle one, so a stack is a grate rather than a pile.
 *
 * Six tiles between lines at the closest. Four leaves three rows between
 * them, which is a corridor a hull only just fits down at all, and eight
 * stacks side by side at that spacing is the part of a map players stop
 * flying through and start going around. */
static void m_stack(int x, int y, int w, int h, uint8_t wall) {
    int step = rr(6, 9), sy, n;
    grid_span(y, h, step, &sy, &n);
    int len[16];
    if (n > (int)(sizeof len / sizeof len[0])) n = (int)(sizeof len / sizeof len[0]);
    for (int i = 0; i < (n + 1) / 2; i++) {
        int v = fits(w, rr(w / 2, w));
        len[i] = v > w ? w : v;
    }
    for (int i = 0; i < n; i++) {
        int L = len[i < n - 1 - i ? i : n - 1 - i];
        int lx = centered(x, w, L);
        hline(lx, lx + L - 1, sy + i * step, wall);
    }
}

/* A room split into cells. The densest thing here, and the only motif with
 * interior corners worth hiding in. Its dividers are spaced from whichever
 * end is nearer, so the pattern is the same read from either side, and the
 * way through each one is centered rather than dropped in at random. */
static void m_cells(int x, int y, int w, int h, uint8_t wall) {
    m_room(x, y, w, h, wall);
    int cols = rr(1, 3), rows = rr(1, 2);
    /* Five tiles through each divider. Three is the narrowest a hull fits
     * down at all, and the narrowest thing on a map is where every fight in
     * it ends up being fought. */
    int gw = fits(w, 5), gh = fits(h, 5);
    for (int c = 1; c <= cols; c++) {
        int cx = 2 * c <= cols + 1 ? x + c * w / (cols + 1)
                                   : x + w - 1 - (cols + 1 - c) * w / (cols + 1);
        vline(cx, y + 1, y + h - 2, wall);
        int gy = centered(y, h, gh);
        vline(cx, gy, gy + gh - 1, SIM_TILE_EMPTY);
    }
    for (int r = 1; r <= rows; r++) {
        int cy = 2 * r <= rows + 1 ? y + r * h / (rows + 1)
                                   : y + h - 1 - (rows + 1 - r) * h / (rows + 1);
        hline(x + 1, x + w - 2, cy, wall);
        int gx = centered(x, w, gw);
        hline(gx, gx + gw - 1, cy, SIM_TILE_EMPTY);
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

/* Loose single tiles, mirrored across the box so a scatter still has an
 * axis. The measured map is full of them and they are the cheapest way to
 * break a sight line without blocking a lane. */
static void m_debris(int x, int y, int w, int h, uint8_t wall) {
    int n = rr(2, 6);
    for (int i = 0; i < n; i++) {
        int dx = rr(0, (w - 1) / 2), dy = rr(0, h - 1);
        put(x + dx, y + dy, wall);
        put(x + w - 1 - dx, y + dy, wall);
    }
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

/* When set, a cluster is placed near here instead of at a district's site.
 * `fill_voids` below is the only caller that sets it. */
static int aim_x = -1, aim_y = -1;

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
     * on the map is the same size to look at, whatever its parts.
     *
     * Touching or four tiles clear, and nothing between. Two tiles between
     * two walls is a lane no hull fits down: the widest of them is 34 pixels
     * across the beam and a two-tile lane is 32, so it reads as a way
     * through from every distance except the one you find out at. */
    int gap = big ? (chance(45) ? 0 : rr(4, 6)) : rr(7, 16);
    int cw = cols * w + (cols - 1) * gap;
    int ch = rows * h + (rows - 1) * gap;
    if (cw > 260 || ch > 260) return 0;

    int m = pick_motif(w, h);
    if (m < 0) return 0;

    for (int tries = 0; tries < 24; tries++) {
        int x, y;
        if (aim_x >= 0) {
            x = aim_x + rr(-20, 20) - cw / 2;
            y = aim_y + rr(-20, 20) - ch / 2;
        } else {
            int d = pick_district();
            int k = (int)(rnd() % (uint32_t)districts[d].n);
            int rad = districts[d].site[k].r;
            x = districts[d].site[k].x + rr(-rad, rad) - cw / 2;
            y = districts[d].site[k].y + rr(-rad, rad) - ch / 2;
        }
        if (x < EDGE + 2 || y < EDGE + 2) continue;
        if (x + cw >= TILES - EDGE - 3 || y + ch >= TILES - EDGE - 3) continue;
        if (!clear_box(x, y, cw, ch, rr(4, 9))) continue;
        /* A sixth of the groups are hung with doors, all on one channel, so
         * a channel closing shuts a place rather than a scattering of
         * unrelated tiles. */
        room_door = chance(18) ? (int)(rnd() % 6u) : -1;
        /* Every member of a group is drawn off the same roll of the dice, so
         * a row of them is one shape repeated rather than four cousins. A
         * motif makes its own choices as it draws (which way a chevron
         * leans, how far apart a stack's lines are, where a room is cut) and
         * letting each member choose again is what put a neighbour's line
         * one tile off every time, which is the failure a player sees as a
         * map that does not line up with itself. */
        uint32_t stamp = rng_state;
        for (int r = 0; r < rows; r++)
            for (int c = 0; c < cols; c++) {
                /* A group is repetition, not a stencil: one in six members
                 * takes a different shape, so a row reads as built rather
                 * than stamped. */
                int mm = chance(17) ? pick_motif(w, h) : m;
                if (mm < 0) mm = m;
                uint32_t after = rng_state;
                rng_state = stamp;
                MOTIFS[mm].fn(x + c * (w + gap), y + r * (h + gap), w, h,
                              SIM_TILE_SOLID);
                rng_state = after;
            }
        room_door = -1;
        return cols * rows;
    }
    return 0;
}

/* ---- the far corners of the field ---------------------------------------
 *
 * Placement is rejection sampling against districts, so where the dice put
 * nothing there is nothing, and the map that falls out has as much bare
 * ground as this seed happened to leave. Measuring it across seeds, the
 * share of open ground more than forty tiles from any wall runs from under
 * three per cent to over eight, which is the difference between a map with
 * lanes in it and a map with a car park in the middle.
 *
 * The measured 1998 map has 1.7% at that distance. So this picks a tile out
 * of whatever is beyond it, drops a group beside it, and goes again until
 * the share is down to the target. It is not a density knob: the wall it
 * adds goes only where there was none for forty tiles in any direction, and
 * it stops as soon as the map is inside the figure the measurements ask for.
 *
 * Chebyshev distance, which is what a chamfer over eight neighbours gives
 * and is the right metric for a sight line rather than for a walk. */
static int32_t *dist;

static void wall_distance(void) {
    for (size_t i = 0; i < (size_t)TILES * TILES; i++)
        dist[i] = SIM_TILE_CLASS(T[i]) == SIM_TILE_SOLID ? 0 : TILES;
    for (int y = 0; y < TILES; y++)
        for (int x = 0; x < TILES; x++) {
            size_t i = (size_t)y * TILES + x;
            if (!dist[i]) continue;
            int32_t d = dist[i];
            for (int j = -1; j <= 0; j++)
                for (int k = -1; k <= 1; k++) {
                    if (j == 0 && k >= 0) continue;
                    int nx = x + k, ny = y + j;
                    if (nx < 0 || ny < 0 || nx >= TILES) continue;
                    if (dist[(size_t)ny * TILES + nx] + 1 < d)
                        d = dist[(size_t)ny * TILES + nx] + 1;
                }
            dist[i] = d;
        }
    for (int y = TILES - 1; y >= 0; y--)
        for (int x = TILES - 1; x >= 0; x--) {
            size_t i = (size_t)y * TILES + x;
            if (!dist[i]) continue;
            int32_t d = dist[i];
            for (int j = 0; j <= 1; j++)
                for (int k = -1; k <= 1; k++) {
                    if (j == 0 && k <= 0) continue;
                    int nx = x + k, ny = y + j;
                    if (nx < 0 || nx >= TILES || ny >= TILES) continue;
                    if (dist[(size_t)ny * TILES + nx] + 1 < d)
                        d = dist[(size_t)ny * TILES + nx] + 1;
                }
            dist[i] = d;
        }
}

/* Share of open ground further than `far` tiles from a wall, in hundredths
 * of a per cent, and one of those tiles picked at random.
 *
 * At random rather than the furthest, because the furthest is the same tile
 * every time and a group that cannot be fitted beside it cannot be fitted
 * beside it on the next round either. Aiming at the single worst point spent
 * every attempt on one unbuildable spot. */
static int void_share(int far, int *bx, int *by) {
    size_t open_n = 0, out = 0;
    for (int y = EDGE; y < TILES - EDGE; y++)
        for (int x = EDGE; x < TILES - EDGE; x++) {
            size_t i = (size_t)y * TILES + x;
            if (SIM_TILE_CLASS(T[i]) == SIM_TILE_SOLID) continue;
            open_n++;
            if (dist[i] <= far) continue;
            out++;
            if (rnd() % (uint32_t)out == 0) { *bx = x; *by = y; }
        }
    return open_n ? (int)(10000 * out / open_n) : 0;
}

static int fill_voids(int far, int target, int rounds) {
    int placed = 0, stale = 1;
    for (int i = 0; i < rounds; i++) {
        int bx = 0, by = 0;
        if (stale) { wall_distance(); stale = 0; }
        if (void_share(far, &bx, &by) <= target) break;
        aim_x = bx;
        aim_y = by;
        int n = place_cluster(chance(45));
        aim_x = aim_y = -1;
        if (n) { placed += n; stale = 1; }
    }
    return placed;
}

/* ---- the big pieces -----------------------------------------------------
 *
 * A handful of structures far larger than the rest. They are what a player
 * navigates by, since a map with no landmark is a map where every direction
 * looks the same, and they are the only places here with an inside. */
static void place_hall(int x, int y, int w, int h, int channel) {
    int x1 = x + w - 1, y1 = y + h - 1;
    hline(x, x1, y, SIM_TILE_SOLID);
    hline(x, x1, y1, SIM_TILE_SOLID);
    vline(x, y, y1, SIM_TILE_SOLID);
    vline(x1, y, y1, SIM_TILE_SOLID);

    /* Four ways in, one to a wall, each the same width and each centered on
     * the wall it goes through: a landmark is a thing you line up on from
     * across the map, and a mouth a tile off center is one you arrive at
     * sideways.
     *
     * One axis is hung with doors and the other is left open, so a channel
     * closing changes how the hall is entered rather than whether it can be
     * left. Doors on all four was the old arrangement and the connectivity
     * pass tore a hole in a wall to undo it every time, since a room only
     * reachable through a door is a room a ship waits inside. */
    int dw = fits(w, rr(7, 10)), dh = fits(h, rr(7, 10));
    int mx = centered(x, w, dw), my = centered(y, h, dh);
    uint8_t d = SIM_TILE(SIM_TILE_DOOR, channel);
    uint8_t across = chance(50) ? d : SIM_TILE_EMPTY;
    uint8_t down = across == d ? SIM_TILE_EMPTY : d;
    hline(mx, mx + dw - 1, y, across);
    hline(mx, mx + dw - 1, y1, across);
    vline(x, my, my + dh - 1, down);
    vline(x1, my, my + dh - 1, down);

    /* Furniture, so the inside is a fight rather than a courtyard. In
     * mirrored pairs off one roll, and clear of both axes, so the hall reads
     * as a room with a plan and the four ways in still meet in the middle. */
    int pairs = rr(1, 2);
    for (int i = 0; i < pairs; i++) {
        int iw = rr(6, w / 4), ih = rr(6, h / 3);
        int ix = rr(x + 5, x + w / 2 - iw - 6);
        int iy = rr(y + 5, y + h - ih - 6);
        int mm = pick_motif(iw, ih);
        if (mm < 0) continue;
        uint32_t stamp = rng_state;
        MOTIFS[mm].fn(ix, iy, iw, ih, SIM_TILE_SOLID);
        uint32_t after = rng_state;
        rng_state = stamp;
        MOTIFS[mm].fn(x1 - (ix - x) - iw + 1, iy, iw, ih, SIM_TILE_SOLID);
        rng_state = after;
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
        /* Stop short of whatever the walk ran into. A run that ends against
         * a second structure is attached at both ends, which is the one
         * thing a barrier must not be: it divides the field every time its
         * channel shuts. Four tiles, since three is a lane a hull can only
         * just thread and this is the way round a shut door. */
        if (len < want) len -= 4;
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

/* A ship is not a point, and every check here used to treat it as one.
 *
 * The widest hull in the roster measures 34 pixels across the beam and the
 * longest reaches 23 pixels from its center at the worst diagonal, against a
 * tile of 16. Two tiles is 32 pixels and holds neither of them; three is 48
 * and holds both at any heading, which is the same three tiles the hull
 * extents in baseline.c are set to leave room to turn around in.
 *
 * So a hull can stand on a tile only when the eight tiles around it are open
 * as well, and the connectivity of a map is the connectivity of that set
 * rather than of its open tiles. Read one tile at a time instead, a map
 * passes every check with structures whose only way in is a single-tile
 * notch: open on the drawing, sealed from the cockpit, and no way to tell
 * which from the other except to fly at it. */
#define HULL 3

static int32_t *comp; /* region id per tile, 0 = outside the set */
static uint8_t *nav;  /* 1 where a hull's center fits */

/* Only these stop a ship. Everything else is flown through, including the
 * safe tiles of a berth and the wormhole. */
static int blocks(uint8_t t, int shut) {
    uint8_t c = SIM_TILE_CLASS(t);
    return c == SIM_TILE_SOLID || (shut && c == SIM_TILE_DOOR);
}

/* Mark where a hull fits. `shut` counts every door as closed, which is the
 * worst a channel can do to a route and the case a map has to survive. */
static void mark_nav(int shut) {
    for (size_t i = 0; i < (size_t)TILES * TILES; i++) nav[i] = 0;
    for (int y = 1; y < TILES - 1; y++)
        for (int x = 1; x < TILES - 1; x++) {
            int fits_here = 1;
            for (int j = -(HULL / 2); j <= HULL / 2 && fits_here; j++)
                for (int i = -(HULL / 2); i <= HULL / 2; i++)
                    if (blocks(T[(size_t)(y + j) * TILES + x + i], shut)) {
                        fits_here = 0;
                        break;
                    }
            nav[(size_t)y * TILES + x] = (uint8_t)fits_here;
        }
}

/* Flood a mask into regions, numbered from one. Returns the id of the
 * largest and puts its size in *out_main_size. */
static int32_t label(const uint8_t *mask, size_t *out_main_size) {
    static int32_t *stack;
    if (!stack) stack = malloc(sizeof(int32_t) * TILES * TILES);
    memset(comp, 0, sizeof(int32_t) * TILES * TILES);
    int32_t cur = 0;
    int32_t best = 0;
    size_t best_n = 0;
    for (int y = 0; y < TILES; y++)
        for (int x = 0; x < TILES; x++) {
            size_t i0 = (size_t)y * TILES + x;
            if (!mask[i0] || comp[i0]) continue;
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
                    if (!mask[j] || comp[j]) continue;
                    comp[j] = cur;
                    stack[sp++] = (int32_t)j;
                }
            }
            if (n > best_n) { best_n = n; best = cur; }
        }
    *out_main_size = best_n;
    return best;
}

/* Widen a tile into a lane a hull fits down, and say how much wall it cost. */
static int carve(int x, int y) {
    int dug = 0;
    for (int j = -(HULL / 2); j <= HULL / 2; j++)
        for (int i = -(HULL / 2); i <= HULL / 2; i++) {
            uint8_t c = SIM_TILE_CLASS(get(x + i, y + j));
            if (c != SIM_TILE_SOLID && c != SIM_TILE_DOOR) continue;
            put(x + i, y + j, SIM_TILE_EMPTY);
            dug++;
        }
    return dug;
}

/* Join every place a hull can be to every other, so no part of the field is
 * walled off from the rest.
 *
 * Drawing structures independently strands ground whether or not any one of
 * them is closed: two open shapes standing near each other enclose what is
 * between them. It is not a rare case, it is dozens per map.
 *
 * Stranded ground is worse than wasted. A ship warped or shoved into it
 * cannot leave, a prize that lands there is gone, and a bot that routes
 * toward it grinds on the wall in front of it. So each piece is joined to
 * the main region along the shortest line between them: a breadth-first
 * search outward, then a lane carved back along the way it came.
 *
 * The lane is three tiles wide, because the thing being let out is a ship.
 * Digging the single-tile line this used to dig satisfied the check that
 * asked for it and left the structure exactly as sealed as it was found.
 *
 * Doors count as shut throughout, so a place reachable only through a door
 * is still stranded: its channel closes for part of every cycle and a ship
 * inside would be held there until it opened. */
static int join_nav(void) {
    static int32_t *queue, *from;
    if (!queue) queue = malloc(sizeof(int32_t) * TILES * TILES);
    if (!from) from = malloc(sizeof(int32_t) * TILES * TILES);
    if (!queue || !from) return -1;
    int dug = 0;

    /* Carving changes which tiles a hull fits on, so the regions are read
     * again after each sweep and the sweep repeated until one is left. Two
     * passes is the usual answer and the cap is a backstop. */
    for (int sweep = 0; sweep < 8; sweep++) {
        size_t main_n = 0;
        mark_nav(1);
        int32_t main = label(nav, &main_n);
        int joined = 0;

        for (size_t seed_i = 0; seed_i < (size_t)TILES * TILES; seed_i++) {
            if (comp[seed_i] == 0 || comp[seed_i] == main) continue;
            int32_t pocket = comp[seed_i];

            /* Walk out through everything a hull cannot fit on, remembering
             * each tile's predecessor, and stop at the first tile of any
             * other region. */
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
                    if (nx < EDGE + 1 || ny < EDGE + 1) continue;
                    if (nx >= TILES - EDGE - 1 || ny >= TILES - EDGE - 1) continue;
                    size_t j = (size_t)ny * TILES + nx;
                    if (from[j] >= 0) continue;
                    from[j] = i;
                    if (comp[j] != 0 && comp[j] != pocket) hit = (int32_t)j;
                    else if (comp[j] == 0) queue[tail++] = (int32_t)j;
                }
            }
            if (hit < 0) continue; /* nothing to join it to, which cannot
                                    * happen on a bounded map but is not
                                    * worth crashing over if it ever does */

            /* Carve the way the search came, and mark the piece joined so
             * its tiles are not searched again this sweep. */
            for (int32_t i = from[hit]; i != from[i]; i = from[i])
                dug += carve(i % TILES, i / TILES);
            joined = 1;
            int32_t into = comp[hit];
            for (size_t i = 0; i < (size_t)TILES * TILES; i++)
                if (comp[i] == pocket) comp[i] = into;
        }
        if (!joined) return dug;
    }
    return dug;
}

/* Wall in the ground no hull can reach even with every door standing open.
 *
 * What is left over after the joining above is the slivers: the tile between
 * two structures that stopped one apart, the notch inside a corner, the
 * inside of something drawn too small to enter. None of it is anywhere a
 * ship goes, and all of it reads as somewhere to go from outside.
 *
 * Filling rather than digging, because a sliver widened to a lane is a hole
 * knocked in a structure that was fine as it stood. Nothing filled here has
 * a hull's tile beside it, since a tile beside one is a tile a hull can
 * reach, so filling cannot take a lane away from anything. */
static int fill_dead(void) {
    size_t main_n = 0;
    mark_nav(0);
    int32_t main = label(nav, &main_n);

    static uint8_t *reach;
    if (!reach) reach = malloc((size_t)TILES * TILES);
    if (!reach) return -1;
    memset(reach, 0, (size_t)TILES * TILES);
    for (int y = 1; y < TILES - 1; y++)
        for (int x = 1; x < TILES - 1; x++) {
            if (comp[(size_t)y * TILES + x] != main) continue;
            for (int j = -(HULL / 2); j <= HULL / 2; j++)
                for (int i = -(HULL / 2); i <= HULL / 2; i++)
                    reach[(size_t)(y + j) * TILES + x + i] = 1;
        }

    int filled = 0;
    for (size_t i = 0; i < (size_t)TILES * TILES; i++) {
        if (reach[i] || SIM_TILE_CLASS(T[i]) != SIM_TILE_EMPTY) continue;
        int x = (int)(i % TILES), y = (int)(i / TILES);
        if (x < EDGE || y < EDGE || x >= TILES - EDGE || y >= TILES - EDGE) continue;
        T[i] = SIM_TILE_SOLID;
        filled++;
    }
    return filled;
}

/* Ground a hull can reach with the doors open, for the checks at the end. */
static int dead_ground(void) {
    size_t main_n = 0;
    mark_nav(0);
    int32_t main = label(nav, &main_n);
    int dead = 0;
    for (int y = 0; y < TILES; y++)
        for (int x = 0; x < TILES; x++) {
            size_t i = (size_t)y * TILES + x;
            if (blocks(T[i], 0)) continue;
            int seen = 0;
            for (int j = -(HULL / 2); j <= HULL / 2 && !seen; j++)
                for (int i2 = -(HULL / 2); i2 <= HULL / 2; i2++) {
                    int nx = x + i2, ny = y + j;
                    if (nx < 0 || ny < 0 || nx >= TILES || ny >= TILES) continue;
                    if (comp[(size_t)ny * TILES + nx] == main) { seen = 1; break; }
                }
            if (!seen) dead++;
        }
    return dead;
}

/* A spawn needs room around it: a ship that materialises against a wall is a
 * ship that spends its first second stuck to one. */
static int open_around(int x, int y, int r, int32_t main) {
    for (int yy = y - r; yy <= y + r; yy++)
        for (int xx = x - r; xx <= x + r; xx++) {
            if (xx < EDGE || yy < EDGE || xx >= TILES - EDGE || yy >= TILES - EDGE)
                return 0;
            if (SIM_TILE_CLASS(get(xx, yy)) != SIM_TILE_EMPTY) return 0;
        }
    return comp[(size_t)y * TILES + x] == main;
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

/* ---- match arenas -------------------------------------------------------
 *
 * A second layout, for the three minute four a side game rather than for a
 * zone. Everything above draws a thousand tiles of open field with clusters
 * in it; a match wants roughly a hundred, walled, with two home ends far
 * enough apart that the trip between them is the whole death penalty.
 *
 * Two rules shape it and both come out of docs/design/match-game.md. It is
 * point symmetric, a half turn about the middle, so neither side has the
 * better approach and a map cannot quietly favour whoever spawned north.
 * And there is never one lane between the pockets: a single corridor makes
 * the Wedge the only ship in the game, so every layout here has to leave at
 * least two ways across that a hull can fly.
 *
 * The arena sits in the middle of the thousand-tile world because the world
 * is a fixed size in the core. Everything outside it is solid, which costs
 * nothing on the wire: a map packs its runs. */
/* A hundred and forty-four tiles square, which is a number about travel
 * time rather than about taste. A hull tops out near 325 px/s and the
 * pockets sit at opposite ends, so the run at somebody is roughly two
 * thousand pixels and the two sides meet about five seconds in, with a
 * respawn about four. Death costs nothing you own any more: what it costs
 * is the trip back, so this is the dial that prices dying. */
#define ARENA 144

static int arena_lo, arena_hi, arena_cx, arena_cy;

/* Draw at a point and at its half-turn twin, so a layout is symmetric by
 * construction rather than by being drawn twice and checked. */
static void sym_put(int x, int y, uint8_t t) {
    put(x, y, t);
    put(arena_cx * 2 - x, arena_cy * 2 - y, t);
}

static void sym_rect(int x, int y, int w, int h, uint8_t t) {
    for (int j = 0; j < h; j++)
        for (int i = 0; i < w; i++) sym_put(x + i, y + j, t);
}

/* A hollow box with a gap in each face, which is the vocabulary the field
 * above is built from and reads the same at this scale. */
static void sym_room(int x, int y, int w, int h) {
    int gx = x + rr(1, w - 2), gy = y + rr(1, h - 2);
    for (int i = 0; i < w; i++) {
        if (i != gx - x && i != gx - x + 1) {
            sym_put(x + i, y, SIM_TILE_SOLID);
            sym_put(x + i, y + h - 1, SIM_TILE_SOLID);
        }
    }
    for (int j = 0; j < h; j++) {
        if (j != gy - y && j != gy - y + 1) {
            sym_put(x, y + j, SIM_TILE_SOLID);
            sym_put(x + w - 1, y + j, SIM_TILE_SOLID);
        }
    }
}

/* Where the two pockets are, set before a layout draws so cover can be kept
 * out of them: a home end crowded with structures is a home end a wiped team
 * cannot form up in, and the spawn placer simply runs out of room. */
static int pocket_x, pocket_y;

static int in_pocket(int x, int y, int pad) {
    int ox = arena_cx * 2 - pocket_x, oy = arena_cy * 2 - pocket_y;
    int dx = x - pocket_x, dy = y - pocket_y;
    if (dx * dx + dy * dy < pad * pad) return 1;
    dx = x - ox; dy = y - oy;
    return dx * dx + dy * dy < pad * pad;
}

/* Four spawn tiles per side, inside the pocket, spread so a wiped team does
 * not come back stacked on one tile. */
static int match_spawns(int32_t main, int px, int py, int team) {
    int placed = 0;
    for (int i = 0; i < 4; i++) {
        int ok = 0;
        for (int tries = 0; tries < 4000 && !ok; tries++) {
            int x = px + rr(-9, 9), y = py + rr(-6, 6);
            if (!open_around(x, y, 4, main)) continue;
            /* Not on top of one already placed: four ships want four tiles. */
            int near = 0;
            for (int j = -5; j <= 5 && !near; j++)
                for (int k = -5; k <= 5; k++)
                    if (SIM_TILE_CLASS(get(x + k, y + j)) == SIM_TILE_SPAWN)
                        near = 1;
            if (near) continue;
            put(x, y, SIM_TILE(SIM_TILE_SPAWN, (uint8_t)team));
            ok = 1;
            placed++;
        }
    }
    return placed;
}

/* The two shipped layouts. Both are point symmetric and both leave three
 * ways across; what differs is where the pockets sit and what stands
 * between them, which is what makes one a lane fight and the other a
 * scramble around a middle nobody owns. */
typedef enum { LAYOUT_DRYDOCK = 0, LAYOUT_SLIPWAY = 1 } match_layout;

static void draw_drydock(void) {
    /* Pockets north and south, three lanes between them: a wide middle with
     * something standing in it, and a flank down each side. The spines that
     * part the lanes are broken every so often, and the breaks are five
     * tiles rather than two, because a hull is three wide and a gap it
     * cannot fly is a wall with a picture of a door on it. */
    int lo = arena_lo;
    for (int k = 0; k < 2; k++) {
        int x = lo + 38 + k * 68;
        for (int y = lo + 24; y <= arena_hi - 24; y++)
            if ((y - lo) % 19 >= 5) {
                sym_put(x, y, SIM_TILE_SOLID);
                sym_put(x + 1, y, SIM_TILE_SOLID);
            }
    }
    /* The middle, which is the widest lane and should not also be the
     * safest. A room rather than a block: something to fight around and
     * through rather than a wall to go past. */
    sym_room(arena_cx - 9, arena_cy - 22, 12, 10);
    sym_rect(arena_cx - 3, arena_cy - 6, 6, 4, SIM_TILE_SOLID);

    /* Cover in the half between a pocket and the middle, mirrored into the
     * other half. Placement refuses anything that would crowd what is
     * already down, so the count lands where the spacing allows. */
    for (int i = 0; i < 44; i++) {
        int x = lo + 10 + rr(0, ARENA - 26), y = lo + 18 + rr(0, ARENA / 2 - 30);
        if (in_pocket(x, y, 20) || !clear_box(x, y, 9, 8, 5)) continue;
        if (chance(45)) sym_room(x, y, rr(7, 10), rr(6, 8));
        else sym_rect(x, y, rr(3, 6), rr(2, 5), SIM_TILE_SOLID);
    }
    /* And a pair of stubs off each pocket, so a spawn is not an open field. */
    for (int k = 0; k < 4; k++)
        sym_rect(lo + 20 + k * 32, lo + 15, 5, 3, SIM_TILE_SOLID);
}

static void draw_slipway(void) {
    /* Pockets at opposite corners, with a lattice standing along the
     * diagonal between them: the direct line is the short one and the
     * dangerous one, and going round is a real choice rather than a detour.
     */
    int lo = arena_lo;
    for (int i = -7; i <= 7; i++) {
        int x = arena_cx + i * 9, y = arena_cy + i * 9;
        if (in_pocket(x, y, 20)) continue;
        sym_rect(x - 2, y - 2, 5, 5, SIM_TILE_SOLID);
    }
    /* Two long bars off the diagonal, each with a way through, which is what
     * makes the long way round passable at all. */
    for (int k = 0; k < 2; k++) {
        int sgn = k ? 1 : -1;
        for (int t = -30; t <= 30; t++) {
            if (t > -4 && t < 4) continue;      /* the way through */
            int x = arena_cx + t + sgn * 34, y = arena_cy - t + sgn * 34;
            if (in_pocket(x, y, 16)) continue;
            sym_put(x, y, SIM_TILE_SOLID);
            sym_put(x, y + 1, SIM_TILE_SOLID);
        }
    }
    for (int i = 0; i < 52; i++) {
        int x = lo + 10 + rr(0, ARENA - 24), y = lo + 10 + rr(0, ARENA - 24);
        if (in_pocket(x, y, 20) || !clear_box(x, y, 8, 8, 5)) continue;
        if (chance(40)) sym_room(x, y, rr(7, 9), rr(6, 8));
        else sym_rect(x, y, rr(3, 5), rr(3, 5), SIM_TILE_SOLID);
    }
}

/* Draw one match arena into `m`. Same contract as `generate`. */
static int generate_match(sim_map *m, uint32_t s, match_layout layout, int quiet) {
    seed(s);
    T = m->tile;
    memset(m, 0, sizeof *m);
    for (size_t i = 0; i < (size_t)TILES * TILES; i++) T[i] = SIM_TILE_SOLID;

    arena_lo = (TILES - ARENA) / 2;
    arena_hi = arena_lo + ARENA - 1;
    arena_cx = arena_cy = TILES / 2;
    for (int y = arena_lo; y <= arena_hi; y++)
        for (int x = arena_lo; x <= arena_hi; x++)
            T[(size_t)y * TILES + x] = SIM_TILE_EMPTY;

    if (layout == LAYOUT_DRYDOCK) {
        pocket_x = arena_cx;
        pocket_y = arena_lo + 14;
        draw_drydock();
    } else {
        pocket_x = arena_lo + 18;
        pocket_y = arena_lo + 18;
        draw_slipway();
    }
    int px = pocket_x, py = pocket_y;

    sim_map_index(m);

    /* The same two passes the zone maps take, and in the same order. A room
     * with a two-tile door is a room a hull cannot enter, so joining widens
     * what has to be flyable and filling walls off what is still not: a
     * layout is drawn for how it reads and then made passable, rather than
     * every primitive having to know how wide a hull is. */
    int dug = join_nav();
    int filled = fill_dead();
    mark_nav(1);
    size_t nav_n = 0;
    int32_t main_c = label(nav, &nav_n);
    int nav_regions = 0;
    for (size_t i = 0; i < (size_t)TILES * TILES; i++)
        if (comp[i] > nav_regions) nav_regions = comp[i];

    /* An ASCII picture of the arena, for looking at a layout while tuning
     * it. Off unless asked for: the checks below are what decides. */
    if (getenv("VW_DUMP")) {
        for (int y = arena_lo - 1; y <= arena_hi + 1; y += 2) {
            for (int x = arena_lo - 1; x <= arena_hi + 1; x++) {
                uint8_t c = SIM_TILE_CLASS(get(x, y));
                putchar(c == SIM_TILE_SOLID ? '#'
                        : c == SIM_TILE_SPAWN ? '@'
                        : nav[(size_t)y * TILES + x] ? '.' : ':');
            }
            putchar('\n');
        }
    }

    int spawns = match_spawns(main_c, px, py, 0);
    spawns += match_spawns(main_c, arena_cx * 2 - px, arena_cy * 2 - py, 1);

    size_t solid = 0;
    for (int y = arena_lo; y <= arena_hi; y++)
        for (int x = arena_lo; x <= arena_hi; x++)
            if (SIM_TILE_CLASS(T[(size_t)y * TILES + x]) == SIM_TILE_SOLID) solid++;
    double solid_pct = 100.0 * (double)solid / (double)(ARENA * ARENA);
    int dead = dead_ground();

    if (!quiet)
        printf("seed %u %s: %d tiles square, %.2f%% solid, %d spawns,"
               " %d region(s), %d dug, %d walled off, %d dead\n", s,
               layout == LAYOUT_DRYDOCK ? "drydock" : "slipway",
               ARENA, solid_pct, spawns, nav_regions, dug, filled, dead);

    if (dug < 0 || filled < 0) {
        fprintf(stderr, "seed %u: could not join the arena up\n", s);
        return 1;
    }
    if (spawns != 8) {
        fprintf(stderr, "seed %u: %d spawns, wanted 8\n", s, spawns);
        return 1;
    }
    /* One region with every door shut, measured against a hull rather than a
     * point, which is the same promise the zone maps make. */
    if (nav_regions != 1) {
        fprintf(stderr, "seed %u: %d regions a hull can fly, not one\n",
                s, nav_regions);
        return 1;
    }
    if (dead) {
        fprintf(stderr, "seed %u: %d open tiles no hull can reach\n", s, dead);
        return 1;
    }
    /* Denser than a zone map on purpose: a hundred tiles with three per cent
     * wall is an empty room. Too dense and there is nowhere to fly. */
    if (solid_pct < 4.0 || solid_pct > 16.0) {
        fprintf(stderr, "seed %u: %.2f%% solid is outside the intended range\n",
                s, solid_pct);
        return 1;
    }
    return 0;
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

    /* One wormhole, off center. A single one is a landmark and a hazard; a
     * field of them is a physics demo. */
    int wormholes = 0;
    for (int tries = 0; tries < 500 && !wormholes; tries++) {
        int x = rr(380, 660), y = rr(380, 660);
        if (!clear_box(x, y, 1, 1, 20)) continue;
        put(x, y, SIM_TILE_WORMHOLE);
        wormholes = 1;
    }

    /* Then the field. Asking for far more clusters than can fit is how the
     * count lands where it lands: placement refuses anything that would
     * overlap, so what comes out is as much as the spacing rules allow
     * rather than as much as the dice offered. */
    plan_districts();
    int structures = 0;
    for (int i = 0; i < 105; i++) structures += place_cluster(1);
    for (int i = 0; i < 1250; i++) structures += place_cluster(0);
    /* And then wherever the dice left nothing at all. Three per cent of the
     * open ground over forty tiles from a wall, which is where the seeds
     * that came out well already sat and twice as close to the measured
     * map's 1.7% as the ones that did not. */
    int filled_in = fill_voids(40, 300, 400);
    structures += filled_in;

    /* Barriers spread over six channels, so a shut lane here is an open one
     * there rather than the whole map breathing in and out together. Enough
     * of them to reach the measured map's eight hundred door tiles between
     * them and the doors already hung on structures. */
    int barrier_tiles = 0;
    for (int i = 0; i < 11; i++) barrier_tiles += place_barrier(i % 6);

    sim_map_index(m);

    /* Fix what was drawn, in the order the two passes depend on. Joining
     * comes first, since it is what decides which ground is reachable at
     * all; filling comes second and takes away what still is not. Then the
     * regions are read once more, because what the spawns are placed against
     * has to be the map as it will be written rather than as it was drawn. */
    int dug = join_nav();
    int filled = fill_dead();
    size_t nav_n = 0;
    mark_nav(1);
    int32_t main_c = label(nav, &nav_n);
    int nav_regions = 0;
    for (size_t i = 0; i < (size_t)TILES * TILES; i++)
        if (comp[i] > nav_regions) nav_regions = comp[i];
    int spawns = place_spawns(main_c);

    /* Report, and refuse to write a map that cannot be played. */
    size_t solid = 0, safe = 0, door = 0;
    for (size_t i = 0; i < (size_t)TILES * TILES; i++) {
        uint8_t c = SIM_TILE_CLASS(T[i]);
        if (c == SIM_TILE_SOLID) solid++;
        else if (c == SIM_TILE_SAFE) safe++;
        else if (c == SIM_TILE_DOOR) door++;
    }
    size_t inner = (size_t)(TILES - 8) * (TILES - 8);
    double solid_pct = 100.0 * (double)(solid - (size_t)(TILES * TILES - inner))
                     / (double)inner;

    /* A feature is stranded when no hull can stand within reach of it. Read
     * off the shut-door labelling above, so a berth that can only be flown
     * out of while a channel happens to be open counts as stranded. */
    int stranded = 0;
    for (int y = 0; y < TILES; y++)
        for (int x = 0; x < TILES; x++) {
            size_t i = (size_t)y * TILES + x;
            uint8_t c = SIM_TILE_CLASS(T[i]);
            if (c != SIM_TILE_SAFE && c != SIM_TILE_SPAWN && c != SIM_TILE_WORMHOLE)
                continue;
            int seen = 0;
            for (int j = -(HULL / 2); j <= HULL / 2 && !seen; j++)
                for (int k = -(HULL / 2); k <= HULL / 2; k++) {
                    int nx = x + k, ny = y + j;
                    if (nx < 0 || ny < 0 || nx >= TILES || ny >= TILES) continue;
                    if (comp[(size_t)ny * TILES + nx] == main_c) { seen = 1; break; }
                }
            if (!seen) stranded++;
        }

    int dead = dead_ground();
    if (!quiet) {
        printf("seed %u: solid %.2f%% of interior, %zu safe, %zu door (%d in"
               " barriers), %d structures, %d docks, %d spawns\n", s, solid_pct,
               safe, door, barrier_tiles, structures, docks, spawns);
        printf("  %d region(s) a hull can fly, %d wall tiles dug to join them,"
               " %d tiles walled off as unreachable, stranded features: %d\n",
               nav_regions, dug, filled, stranded);
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
    /* One region a hull can fly, not almost one, and measured with every
     * door shut. Anything else is a place a ship can be put and cannot
     * leave, so a threshold here would be a threshold on how much of the map
     * is a trap. */
    if (nav_regions != 1) {
        fprintf(stderr, "seed %u: %d regions a hull can fly, not one\n",
                s, nav_regions);
        return 1;
    }
    /* And nothing left over that looks open and is not. This is the check
     * the single-tile version of all of the above could not make: it counted
     * a one-tile notch as a way in and passed maps full of them. */
    if (dead) {
        fprintf(stderr, "seed %u: %d open tiles no hull can reach\n", s, dead);
        return 1;
    }
    if (dug < 0 || filled < 0) {
        fprintf(stderr, "seed %u: could not join the map up\n", s);
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
        fprintf(stderr,
                "usage: %s <out.vwmap> [seed]\n"
                "       %s --match <drydock|slipway> <out.vwmap> [seed]\n"
                "       %s --selftest\n",
                argv[0], argv[0], argv[0]);
        return 2;
    }
    sim_map *m = calloc(1, sizeof *m);
    comp = malloc(sizeof(int32_t) * TILES * TILES);
    nav = malloc((size_t)TILES * TILES);
    dist = malloc(sizeof(int32_t) * TILES * TILES);
    if (!m || !comp || !nav || !dist) return 1;

    /* Twelve seeds, none of them the shipped one, because the check worth
     * having is that the generator produces a playable map generally and not
     * that it once did. */
    if (strcmp(argv[1], "--selftest") == 0) {
        for (uint32_t k = 101; k <= 112; k++)
            if (generate(m, k, 1) != 0) return 1;
        /* Both match layouts over several seeds, for the same reason: what
         * is worth checking is that the generator makes a playable arena
         * generally, not that one seed once did. */
        for (uint32_t k = 21; k <= 28; k++) {
            if (generate_match(m, k, LAYOUT_DRYDOCK, 1) != 0) return 1;
            if (generate_match(m, k, LAYOUT_SLIPWAY, 1) != 0) return 1;
        }
        printf("mapgen selftest passed\n");
        free(dist); free(nav); free(comp); free(m);
        return 0;
    }

    const char *out;
    uint32_t s;
    if (strcmp(argv[1], "--match") == 0) {
        if (argc < 4) { fprintf(stderr, "--match wants a layout and a path\n"); return 2; }
        match_layout layout;
        if (strcmp(argv[2], "drydock") == 0) layout = LAYOUT_DRYDOCK;
        else if (strcmp(argv[2], "slipway") == 0) layout = LAYOUT_SLIPWAY;
        else { fprintf(stderr, "unknown layout %s\n", argv[2]); return 2; }
        out = argv[3];
        s = argc > 4 ? (uint32_t)strtoul(argv[4], NULL, 10) : 1u;
        if (generate_match(m, s, layout, 0) != 0) return 1;
    } else {
        out = argv[1];
        s = argc > 2 ? (uint32_t)strtoul(argv[2], NULL, 10) : 1u;
        if (generate(m, s, 0) != 0) return 1;
    }

    uint8_t *buf = malloc(SIM_MAP_PACK_MAX);
    if (!buf) return 1;
    int n = sim_map_pack(m, buf, SIM_MAP_PACK_MAX);
    if (n < 0) { fprintf(stderr, "pack failed\n"); return 1; }
    FILE *f = fopen(out, "wb");
    if (!f) { perror(out); return 1; }
    fwrite(buf, 1, (size_t)n, f);
    fclose(f);
    printf("  %s: %d bytes, hash %08x, %u features\n", out, n,
           sim_map_hash(m), m->feature_count);
    free(buf); free(dist); free(nav); free(comp); free(m);
    return 0;
}
