/* Determinism harness: replay an input trace and print state hashes.
 *
 *   replay <trace-file> [--every N]
 *
 * Trace format, one command per line: "<count> <buttons>", meaning hold this
 * button bitfield for count ticks. '#' starts a comment. Buttons: 1 left,
 * 2 right, 4 thrust, 8 reverse.
 *
 * Output: one "tick <n> hash <hex>" line every N ticks (default 500) and a
 * final line. Two platforms that print different bytes have diverged, and
 * that is the whole test.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sim/sim.h"

/* The M0 test map: a solid border plus a square block near the center so
 * traces exercise both open flight and wall bounces. */
static void build_map(sim_map *m) {
    memset(m->solid, 0, sizeof m->solid);
    for (int i = 0; i < SIM_MAP_TILES; i++) {
        for (int b = 0; b < 2; b++) {
            m->solid[(size_t)b * SIM_MAP_TILES + i] = 1;
            m->solid[(size_t)(SIM_MAP_TILES - 1 - b) * SIM_MAP_TILES + i] = 1;
            m->solid[(size_t)i * SIM_MAP_TILES + b] = 1;
            m->solid[(size_t)i * SIM_MAP_TILES + (SIM_MAP_TILES - 1 - b)] = 1;
        }
    }
    for (int ty = 500; ty < 512; ty++)
        for (int tx = 520; tx < 532; tx++)
            m->solid[(size_t)ty * SIM_MAP_TILES + tx] = 1;
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
    if (!map) return 2;
    build_map(map);

    /* Placeholder tuning in Subspace vocabulary; the svs importer replaces
     * these numbers with the real Standard VIE Settings in M3. */
    sim_settings cfg = {0};
    cfg.ship.max_speed = sim_vie_speed(4375);
    cfg.ship.thrust = sim_vie_thrust(25);
    cfg.ship.rot = sim_vie_rotation(380);
    cfg.ship.radius = 14 * 256;
    cfg.bounce = 16;
    cfg.map = map;

    sim_state *a = malloc(sizeof *a), *b = malloc(sizeof *b);
    if (!a || !b) return 2;
    sim_init(a, 0x5eedu);
    sim_spawn(a, 400 * SIM_TILE_PX, 400 * SIM_TILE_PX, 0);

    char line[128];
    long tick = 0;
    unsigned long long total_bounces = 0;
    while (fgets(line, sizeof line, f)) {
        long count;
        unsigned buttons;
        if (line[0] == '#' || sscanf(line, "%ld %u", &count, &buttons) != 2)
            continue;
        for (long k = 0; k < count; k++) {
            sim_input in = {0, (uint16_t)buttons};
            sim_events ev;
            sim_step(b, a, &in, 1, &cfg, &ev);
            total_bounces += ev.bounces;
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
    printf("final tick %ld hash %016llx bounces %llu\n", tick,
           (unsigned long long)sim_hash(a), total_bounces);
    free(a);
    free(b);
    free(map);
    return 0;
}
