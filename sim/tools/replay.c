/* Determinism harness: replay an input trace and print state hashes.
 *
 *   replay <trace-file> [--every N]
 *
 * Trace format, one command per line:
 *   ship <n> <class> <team> <tile_x> <tile_y> <heading>   add a ship
 *   <ticks> <buttons0> [buttons1 ...]                     hold inputs
 * '#' starts a comment. Buttons: 1 left, 2 right, 4 thrust, 8 reverse,
 * 16 fire, 32 bomb.
 *
 * Output: "tick <n> hash <hex>" every N ticks (default 500) plus a final
 * line carrying the whole-run totals. Two platforms that print different
 * bytes have diverged, and that is the entire test.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sim/sim.h"
#include "sim/baseline.h"

/* The test map: a solid border plus a square block near the center, so
 * traces exercise open flight, wall bounces, and bombs against geometry. */
static void build_map(sim_map *m) {
    memset(m->tile, SIM_TILE_EMPTY, sizeof m->tile);
    for (int i = 0; i < SIM_MAP_TILES; i++) {
        for (int b = 0; b < 2; b++) {
            m->tile[(size_t)b * SIM_MAP_TILES + i] = SIM_TILE_SOLID;
            m->tile[(size_t)(SIM_MAP_TILES - 1 - b) * SIM_MAP_TILES + i] = SIM_TILE_SOLID;
            m->tile[(size_t)i * SIM_MAP_TILES + b] = SIM_TILE_SOLID;
            m->tile[(size_t)i * SIM_MAP_TILES + (SIM_MAP_TILES - 1 - b)] = SIM_TILE_SOLID;
        }
    }
    for (int ty = 500; ty < 512; ty++)
        for (int tx = 520; tx < 532; tx++)
            m->tile[(size_t)ty * SIM_MAP_TILES + tx] = SIM_TILE_SOLID;
    /* A safe zone, a door and a wormhole, so the trace covers the tile
     * behaviours as well as the walls. */
    for (int ty = 496; ty < 500; ty++)
        for (int tx = 496; tx < 502; tx++)
            m->tile[(size_t)ty * SIM_MAP_TILES + tx] = SIM_TILE_SAFE;
    for (int tx = 508; tx < 516; tx++)
        m->tile[(size_t)492 * SIM_MAP_TILES + tx] = SIM_TILE(SIM_TILE_DOOR, 0);
    m->tile[(size_t)520 * SIM_MAP_TILES + 500] = SIM_TILE_WORMHOLE;
    sim_map_index(m);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <trace-file> [--every N]\n", argv[0]);
        return 2;
    }
    long every = 500;
    if (argc >= 4 && strcmp(argv[2], "--every") == 0) every = atol(argv[3]);

    FILE *f = fopen(argv[1], "r");
    if (!f) {
        fprintf(stderr, "cannot open %s\n", argv[1]);
        return 2;
    }

    sim_map *map = malloc(sizeof *map);
    sim_state *a = malloc(sizeof *a), *b = malloc(sizeof *b);
    if (!map || !a || !b) return 2;
    build_map(map);

    sim_settings cfg;
    memset(&cfg, 0, sizeof cfg);
    sim_settings_baseline(&cfg, map);

    sim_init(a, 0x5eedu);

    char line[256];
    long tick = 0;
    unsigned long long fires = 0, hits = 0, deaths = 0, bounces = 0;
    while (fgets(line, sizeof line, f)) {
        if (line[0] == '#') continue;
        if (strncmp(line, "ship", 4) == 0) {
            int n, cls, team, tx, ty, hd;
            if (sscanf(line, "ship %d %d %d %d %d %d", &n, &cls, &team, &tx, &ty,
                       &hd) == 6) {
                (void)n;
                sim_spawn(a, (uint8_t)cls, (uint8_t)team, tx * SIM_TILE_PX,
                          ty * SIM_TILE_PX, (uint16_t)hd, &cfg);
            }
            continue;
        }
        long count;
        unsigned btn[SIM_MAX_SHIPS] = {0};
        int consumed = 0;
        if (sscanf(line, "%ld%n", &count, &consumed) != 1) continue;
        int nb = 0;
        char *p = line + consumed;
        while (nb < SIM_MAX_SHIPS) {
            int used = 0;
            unsigned v;
            if (sscanf(p, "%u%n", &v, &used) != 1) break;
            btn[nb++] = v;
            p += used;
        }
        for (long k = 0; k < count; k++) {
            sim_input in[SIM_MAX_SHIPS];
            uint16_t n_in = 0;
            for (int i = 0; i < a->ship_count && i < nb; i++) {
                in[n_in].ship = (uint8_t)i;
                in[n_in].buttons = (uint16_t)btn[i];
                n_in++;
            }
            sim_events ev;
            sim_step(b, a, in, n_in, &cfg, &ev);
            for (uint16_t e = 0; e < ev.count; e++) {
                switch (ev.e[e].type) {
                    case SIM_EV_FIRE: fires++; break;
                    case SIM_EV_HIT: hits++; break;
                    case SIM_EV_DEATH: deaths++; break;
                    case SIM_EV_BOUNCE: bounces++; break;
                    default: break;
                }
            }
            sim_state *t = a;
            a = b;
            b = t;
            tick++;
            if (every > 0 && tick % every == 0)
                printf("tick %ld hash %016llx\n", tick,
                       (unsigned long long)sim_hash(a));
        }
    }
    fclose(f);
    printf("final tick %ld hash %016llx fires %llu hits %llu deaths %llu bounces %llu\n",
           tick, (unsigned long long)sim_hash(a), fires, hits, deaths, bounces);
    free(a);
    free(b);
    free(map);
    return 0;
}
