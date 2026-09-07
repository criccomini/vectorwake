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
 * The widest hull in the roster measures just over 39 pixels at the beam and
 * the longest reaches under 23 pixels from its center at the worst diagonal,
 * against a 16-pixel tile. Two tiles is 32 pixels and holds neither; three is
 * 48 and holds both at any heading. A hull therefore stands on a tile only
 * when the eight around it are open too, and the connectivity of a map is the
 * connectivity of that set.
 *
 * Read one tile at a time instead, a map passes with structures whose only way
 * in is a single-tile notch: open on the drawing, sealed from the cockpit, and
 * no way to tell which from the other except to fly at it. A map shipped that
 * way once, with 59 separate regions a hull could fly and 16,431 tiles of open
 * ground it could not reach, on a generator that had checked it and reported
 * one region.
 *
 * ## A door is a passage, not a wall
 *
 * Everything the verdict rests on is measured with the doors open, because a
 * door is a wall on a clock and the clock keeps running. At the baseline it is
 * shut two seconds in every six. A pocket behind one is somewhere you wait to
 * get into, which is what a door is for, and the one genuinely bad case is
 * already the engine's: a ship caught by a closing door is warped home, which
 * is `SIM_EV_WARP` and not a map fault.
 *
 * This used to be the other way round: connectivity was measured with every
 * door shut, on the argument that a route through one can be held against you
 * for a third of the cycle. True, and an argument that a door-gated pocket is
 * awkward rather than unplayable. What it cost was the whole class. A door
 * could never be the only way into anywhere, so it could never gate a pocket,
 * so it could only ever be a second entrance to somewhere already open, which
 * is a decoration with eight channels of timing on it. The first map anybody
 * drew with doors in it was refused with "a start is walled in", and the map
 * was right and the check was wrong.
 *
 * The shut count is still worth knowing and still measured, as `regions_shut`.
 * A map where it exceeds `regions` is a map whose shape depends on its doors
 * opening, which is true of any map that uses them properly and is worth
 * saying out loud to whoever drew it, because a zone that sets `door_period`
 * to zero never opens them. That is a zone's business and not a map's, so it
 * is a note rather than a refusal.
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

    /* What the doors cost when they are all shut. Nothing here decides
     * anything; it is the number that says a map leans on its doors. Taken
     * first because the pass below leaves the scratch labelled the way the
     * rest of this function needs it. */
    mark(m, s, 1);
    int32_t shut_biggest = 0;
    (void)label(m, s, &shut_biggest);
    for (size_t i = 0; i < (size_t)m->w * (size_t)m->h; i++)
        if (s->comp[i] > r->regions_shut) r->regions_shut = s->comp[i];

    /* Connectivity, with the doors open, which is the shape of the map. */
    mark(m, s, 0);
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
        if (ft->variant < SIM_SIDES) r->spawns_team[ft->variant]++;
        /* The start's own tile, not its neighborhood: a hull is put down
         * centered on it, so the tile has to be one a hull fits on. Asked
         * of the eight around it as well, a start drawn against a wall
         * passed, and every pilot dealt it spawned with the hull inside the
         * wall face, unable to move until they thrust straight away. */
        if (s->comp[(size_t)ft->ty * m->w + (size_t)ft->tx] != main)
            r->spawns_stranded++;
    }

    /* Feature tiles the index could not hold. The table has a ceiling and
     * the index stops at it in scan order, so a map with too many stands,
     * starts, goals and wormholes keeps the tiles and loses the last of them
     * from the table: a side's starts gone, a drawn wormhole that pulls
     * nothing. The panel's fill tool lays hundreds in one click. */
    {
        int32_t drawn = 0;
        for (int32_t y = 0; y < (int32_t)m->h; y++)
            for (int32_t x = 0; x < (int32_t)m->w; x++) {
                uint8_t c = SIM_TILE_CLASS(SIM_MAP_AT(m, x, y));
                if (c == SIM_TILE_WORMHOLE || c == SIM_TILE_GOAL || c == SIM_TILE_TURF
                    || c == SIM_TILE_SPAWN)
                    drawn++;
            }
        r->features_dropped = drawn - (int32_t)m->feature_count;
        if (r->features_dropped < 0) r->features_dropped = 0;
    }

    /* Ground nobody can reach: a place behind a wall is a trap. A ship shoved
     * into one cannot leave, a prize landing there is gone, and a bot routing
     * toward it grinds on the wall in front of it. The labelling from the pass
     * above is the one this wants, so it is reused rather than redone. */
    int32_t open_id = main;
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

/* Where the stranded ground is, for whoever has to look at it.
 *
 * The count on its own is not something an author can act on: thirty-eight
 * tiles somewhere in a room of twenty thousand is a needle nobody is going to
 * find by squinting. This fills `out` with the tile indices, so the editor can
 * draw them and the question becomes "is that a crevice or a passage I meant
 * to fly down", which is a question a person can answer in a glance.
 *
 * Self-contained rather than reading what `sim_map_check` left in the scratch,
 * because a function whose answer depends on what was called before it is one
 * somebody eventually calls in the wrong order. */
int sim_map_stranded(const sim_map *m, sim_map_scratch *s, uint32_t *out, int cap) {
    if (!m || !s || !out || cap <= 0 || m->w == 0 || m->h == 0) return 0;
    mark(m, s, 0);
    int32_t biggest = 0;
    int32_t main = label(m, s, &biggest);
    int n = 0;
    for (int32_t y = 0; y < (int32_t)m->h && n < cap; y++) {
        for (int32_t x = 0; x < (int32_t)m->w && n < cap; x++) {
            uint8_t c = SIM_TILE_CLASS(sim_tile_at(m, x, y));
            if (c == SIM_TILE_SOLID || c == SIM_TILE_SLOPE || c == SIM_TILE_DOOR) continue;
            if (served_by(m, s, x, y, main)) continue;
            out[n++] = (uint32_t)y * m->w + (uint32_t)x;
        }
    }
    return n;
}

int sim_map_playable(const sim_map_report *r, char *why, int cap) {
    const char *fault = 0;
    char line[160];
    if (r->features_dropped > 0) {
        snprintf(line, sizeof line,
                 "it has more starts, stands, goals and wormholes than the core "
                 "can index: %d past the %d it holds",
                 r->features_dropped, SIM_MAX_FEATURES);
        fault = line;
    } else if (r->spawns == 0) {
        fault = "it names no start, so a zone would put every ship on its own tiles";
    } else if (r->spawns_stranded > 0) {
        fault = "a start is walled in";
    } else if (r->regions > 1) {
        /* Doors are open for this count, so two regions is two rooms with no
         * way between them at all, rather than one room on a clock. */
        snprintf(line, sizeof line,
                 "a hull cannot fly between all of it: %d separate regions, and "
                 "that is with every door open",
                 r->regions);
        fault = line;
    } else if (r->regions == 0) {
        fault = "there is nowhere in it a hull fits";
    }
    /* Stranded ground is reported and not refused. It reads as "somewhere is
     * sealed off" and mostly is not: a hull is three tiles across, so any two
     * rocks with one tile between them leave a tile no hull's center can come
     * within one of, and a drawn asteroid field is hundreds of them. The first
     * map anybody scattered rocks across came back with thirty-eight of these
     * and nothing wrong with it.
     *
     * The three things this was guarding are all somewhere else now. A ship
     * cannot be shoved into a gap it does not fit in. A prize cannot land
     * there, because prizes came out of the core. And a bot cannot route
     * there, because nav counts a tile blocked unless a hull fits on it. What
     * is left is worth knowing and is not a verdict: a two-tile passage that
     * looks like a route and is not, against a crevice between two rocks, and
     * the difference between those is a question about the drawing rather than
     * about the count. The editor draws them so an author can look.
     *
     * A place a hull could fly and cannot reach is still refused, by the
     * region count above: that is the same fact said about ground a ship can
     * actually be on. */
    if (!fault) return 1;
    if (why && cap > 0) {
        int n = (int)strlen(fault);
        if (n > cap - 1) n = cap - 1;
        memcpy(why, fault, (size_t)n);
        why[n] = 0;
    }
    return 0;
}
