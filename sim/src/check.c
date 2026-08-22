/* Whether a map can be flown, asked of a hull rather than of a point.
 *
 * This lives in the core, beside the collision it is about, because three
 * callers need the same answer and a second opinion about a map is worth
 * nothing. The generator refuses to write a map that fails it. The meta-layer
 * runs it on anything an operator draws, before the bytes reach a zone. And a
 * map editor wants to say what is wrong while somebody is still drawing.
 *
 * It used to be inside `sim/tools/mapgen.c`, where only the generator could
 * reach it. The generator still has its own passes -- it has to decide where
 * to dig, not only whether digging worked -- but the verdict is this function's
 * now, so a map a person drew is held to exactly what a generated one is.
 *
 * ## A ship is three tiles across
 *
 * The widest hull in the roster measures 34 pixels at the beam and the longest
 * reaches 23 pixels from its center at the worst diagonal, against a 16-pixel
 * tile. Two tiles is 32 pixels and holds neither; three is 48 and holds both at
 * any heading. So a hull stands on a tile only when the eight around it are
 * open too, and the connectivity of a map is the connectivity of that set.
 *
 * Read one tile at a time instead, a map passes with structures whose only way
 * in is a single-tile notch: open on the drawing, sealed from the cockpit, and
 * no way to tell which from the other except to fly at it. A map shipped that
 * way once, with 59 separate regions a hull could fly and 16,431 tiles of open
 * ground it could not reach, on a generator that had checked it and reported
 * one region.
 *
 * ## Doors count both ways
 *
 * Connectivity is measured with every door shut, which is the worst a channel
 * can do to a route: somewhere reachable only through a door is somewhere a
 * ship can be held for a third of every cycle. Stranded ground is measured
 * with them open, because a tile a hull can reach when the door opens is not
 * stranded, it is behind a door.
 */
#include <stdio.h>
#include <string.h>

#include "sim/sim.h"

/* A hull is this many tiles across. See the header comment. */
#define HULL 3

/* What stops a hull. A slope counts whole, though it is half a tile: this asks
 * whether a map can be flown, and answering that generously is how a map ships
 * with ground nothing can reach. */
static int blocks(const sim_map *m, int32_t tx, int32_t ty, int shut) {
    uint8_t c = SIM_TILE_CLASS(sim_tile_at(m, tx, ty));
    return c == SIM_TILE_SOLID || c == SIM_TILE_SLOPE || (shut && c == SIM_TILE_DOOR);
}

/* Mark every tile a hull's center can occupy. */
static void mark(const sim_map *m, sim_map_scratch *s, int shut) {
    memset(s->nav, 0, (size_t)m->w * (size_t)m->h);
    for (int32_t y = 0; y < (int32_t)m->h; y++)
        for (int32_t x = 0; x < (int32_t)m->w; x++) {
            int fits = 1;
            for (int32_t j = -(HULL / 2); j <= HULL / 2 && fits; j++)
                for (int32_t i = -(HULL / 2); i <= HULL / 2; i++)
                    if (blocks(m, x + i, y + j, shut)) {
                        fits = 0;
                        break;
                    }
            s->nav[(size_t)y * m->w + (size_t)x] = (uint8_t)fits;
        }
}

/* Flood the marked set into regions numbered from one, and hand back the id of
 * the largest with its size. Four-connected, which is what the marking above
 * makes correct: a diagonal step between two tiles a hull fits on always has
 * an orthogonal pair beside it that it also fits on. */
static int32_t label(const sim_map *m, sim_map_scratch *s, int32_t *out_biggest) {
    size_t n = (size_t)m->w * (size_t)m->h;
    memset(s->comp, 0, n * sizeof s->comp[0]);
    int32_t cur = 0, best = 0, best_n = 0;
    for (size_t start = 0; start < n; start++) {
        if (!s->nav[start] || s->comp[start]) continue;
        cur++;
        int32_t count = 0;
        size_t sp = 0;
        s->stack[sp++] = (int32_t)start;
        s->comp[start] = cur;
        while (sp) {
            int32_t at = s->stack[--sp];
            count++;
            int32_t cx = at % (int32_t)m->w, cy = at / (int32_t)m->w;
            static const int32_t dx[4] = {1, -1, 0, 0};
            static const int32_t dy[4] = {0, 0, 1, -1};
            for (int d = 0; d < 4; d++) {
                int32_t nx = cx + dx[d], ny = cy + dy[d];
                if (nx < 0 || ny < 0 || nx >= (int32_t)m->w || ny >= (int32_t)m->h) continue;
                size_t j = (size_t)ny * m->w + (size_t)nx;
                if (!s->nav[j] || s->comp[j]) continue;
                s->comp[j] = cur;
                s->stack[sp++] = (int32_t)j;
            }
        }
        if (count > best_n) {
            best_n = count;
            best = cur;
        }
    }
    *out_biggest = best_n;
    return best;
}

/* Whether a hull standing anywhere within its own footprint of this tile would
 * be in the main region: a tile is reachable when a ship can get to it, not
 * when a ship can be centered on it. */
static int served_by(const sim_map *m, const sim_map_scratch *s, int32_t x, int32_t y,
                     int32_t main) {
    for (int32_t j = -(HULL / 2); j <= HULL / 2; j++)
        for (int32_t i = -(HULL / 2); i <= HULL / 2; i++) {
            int32_t nx = x + i, ny = y + j;
            if (nx < 0 || ny < 0 || nx >= (int32_t)m->w || ny >= (int32_t)m->h) continue;
            if (s->comp[(size_t)ny * m->w + (size_t)nx] == main) return 1;
        }
    return 0;
}

void sim_map_check(const sim_map *m, sim_map_scratch *s, sim_map_report *r) {
    memset(r, 0, sizeof *r);
    if (!m || !s || m->w == 0 || m->h == 0) return;

    /* Connectivity, with every door shut. */
    mark(m, s, 1);
    int32_t biggest = 0;
    int32_t main = label(m, s, &biggest);
    r->reachable = biggest;
    for (size_t i = 0; i < (size_t)m->w * (size_t)m->h; i++)
        if (s->comp[i] > r->regions) r->regions = s->comp[i];

    /* Where a start sits, and whether a ship put on one can leave it. Read off
     * the feature table rather than the tiles, the way the game finds them. */
    for (uint16_t f = 0; f < m->feature_count; f++) {
        const sim_feature *ft = &m->features[f];
        if (ft->kind != SIM_TILE_SPAWN) continue;
        r->spawns++;
        if (ft->variant < 2) r->spawns_team[ft->variant]++;
        if (!served_by(m, s, ft->tx, ft->ty, main)) r->spawns_stranded++;
    }

    /* Ground nobody can reach, with the doors open: a place behind a door is
     * awkward, and a place behind a wall is a trap. A ship shoved into one
     * cannot leave, a prize landing there is gone, and a bot routing toward it
     * grinds on the wall in front of it. */
    mark(m, s, 0);
    int32_t open_main = 0;
    int32_t open_id = label(m, s, &open_main);
    for (int32_t y = 0; y < (int32_t)m->h; y++)
        for (int32_t x = 0; x < (int32_t)m->w; x++) {
            uint8_t c = SIM_TILE_CLASS(sim_tile_at(m, x, y));
            if (c == SIM_TILE_SOLID || c == SIM_TILE_SLOPE) {
                r->solid++;
                continue;
            }
            if (c == SIM_TILE_DOOR) continue;
            r->open++;
            if (!served_by(m, s, x, y, open_id)) r->stranded++;
        }
}

int sim_map_playable(const sim_map *m, const sim_map_report *r, char *why, int cap) {
    const char *fault = 0;
    (void)m;
    static char line[160];
    if (r->spawns == 0) {
        fault = "it names no start, so a zone would put every ship on its own tiles";
    } else if (r->spawns_stranded > 0) {
        fault = "a start is walled in";
    } else if (r->regions > 1) {
        /* Doors are shut for this count, so two regions is two rooms, not one
         * room with a channel between them. */
        snprintf(line, sizeof line,
                 "a hull cannot fly between all of it: %d separate regions with the "
                 "doors shut",
                 r->regions);
        fault = line;
    } else if (r->regions == 0) {
        fault = "there is nowhere in it a hull fits";
    } else if (r->stranded > 0) {
        snprintf(line, sizeof line, "%d open tile(s) no hull can reach", r->stranded);
        fault = line;
    }
    if (!fault) return 1;
    if (why && cap > 0) {
        int n = (int)strlen(fault);
        if (n > cap - 1) n = cap - 1;
        memcpy(why, fault, (size_t)n);
        why[n] = 0;
    }
    return 0;
}
