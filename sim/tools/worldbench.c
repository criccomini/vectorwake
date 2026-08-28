/* What a world costs, and how big one is in seconds.
 *
 * Written for the open-world proposal (docs/design/open-world.md), which
 * claims two things about the engine that were worth measuring rather than
 * asserting: that the core's whole 255-ship ceiling fits inside a tick with
 * room to spare, and that what a seat pays for is its neighbors rather than
 * the population, so a larger world is cheaper per player and not dearer.
 *
 * Two reports.
 *
 * `crossing` flies each hull down an empty corridor at full thrust and reads
 * its terminal speed off the last three seconds, which turns a map's width in
 * tiles into a flight in seconds. That is the unit maps.md already sizes
 * arenas in, and the unit an open world has to be argued in.
 *
 * `load` furnishes a world with rock, fills it with ships that thrust and fire
 * every single tick, steps it at 100 Hz, and packs a filtered snapshot for
 * every seat at 20 Hz. Nobody plays like that: every gun in the room held down
 * for the whole run is the ceiling rather than a session. Against a 10 ms tick
 * the margin is the answer.
 *
 * This is a measuring tool and not a test. It asserts nothing and `make check`
 * does not run it, because a wall-clock number is a fact about the machine
 * that produced it.
 */
#define _POSIX_C_SOURCE 199309L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "sim/baseline.h"
#include "sim/pack.h"
#include "sim/sim.h"

/* Seconds of the monotonic clock, in milliseconds. */
static double now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec * 1000.0 + (double)t.tv_nsec / 1e6;
}

/* Integer square root, so the tool needs no libm and the Makefile rule for it
 * is the same one every other tool in here uses. */
static int isqrt_(int v) {
    int r = 0;
    while ((r + 1) * (r + 1) <= v) r++;
    return r;
}

/* One state pair is about a megabyte and a half of map, so these are static
 * rather than automatic: the build caps a frame at four. */
static sim_map map;
static sim_settings cfg;
static sim_state prev, next;
static sim_events ev;
static sim_input in[SIM_MAX_SHIPS];
static uint8_t buf[SIM_STATE_PACK_MAX];

/* Terminal speed in tiles per second, per hull, and what that makes of a map.
 *
 * Sampled over the last three seconds of a twelve second burn rather than over
 * the whole of it, since the first seconds are the hull getting up to speed
 * and would report an average nobody flies at. */
static void crossing(void) {
    sim_map_size(&map, SIM_MAP_TILES, SIM_MAP_TILES);
    sim_map_index(&map);
    sim_settings_baseline(&cfg, &map);

    printf("hull        tiles/s   1024 tiles    144 tiles\n");
    for (int c = 0; c < SIM_MAX_CLASSES; c++) {
        sim_init(&prev, 7);
        int i = sim_spawn(&prev, (uint8_t)c, 0, SIM_MAP_TILES / 2 * SIM_TILE_PX,
                          SIM_MAP_TILES / 2 * SIM_TILE_PX, 0, &cfg);
        if (i < 0) continue;
        in[0].ship = (uint8_t)i;
        in[0].buttons = SIM_BTN_THRUST;

        int32_t mark = 0;
        next = prev;
        for (int t = 0; t < 1200; t++) {
            sim_step(&next, &prev, in, 1, &cfg, &ev);
            prev = next;
            if (t == 900) mark = prev.ships[i].y;
        }
        int32_t moved = prev.ships[i].y - mark;
        if (moved < 0) moved = -moved;
        double tiles = (double)moved / 256.0 / SIM_TILE_PX;
        double tps = tiles / 3.0;
        printf("%-10s %7.1f %10.1fs %11.1fs\n", sim_class_names[c], tps,
               tps > 0 ? SIM_MAP_TILES / tps : 0.0, tps > 0 ? 144 / tps : 0.0);
    }
}

/* Step a furnished world of `ships` hulls for `ticks`, packing every seat's
 * snapshot at 20 Hz, and report the tick against its 10 ms budget. */
static void load(int tiles, int ships, int ticks, int radius) {
    sim_map_size(&map, tiles, tiles);
    /* One solid tile every five in both directions, which is roughly the
     * furniture a shipped arena carries. An empty plane would measure the
     * collision path that no real map takes. */
    for (int y = 6; y < tiles - 6; y += 5)
        for (int x = 6; x < tiles - 6; x += 5)
            SIM_MAP_AT(&map, x, y) = SIM_TILE(SIM_TILE_SOLID, SIM_SOLID_ROCK_A);
    sim_map_index(&map);
    sim_settings_baseline(&cfg, &map);
    cfg.max_ships = 0; /* zero reads as the array bound */

    sim_init(&prev, 12345);
    int per = isqrt_(ships) + 1;
    int span = tiles - 2 * (tiles / 8);
    int n = 0;
    for (int r = 0; r < per && n < ships; r++) {
        for (int c = 0; c < per && n < ships; c++) {
            int32_t x = (int32_t)((tiles / 8 + (int64_t)c * span / per) * SIM_TILE_PX);
            int32_t y = (int32_t)((tiles / 8 + (int64_t)r * span / per) * SIM_TILE_PX);
            if (sim_spawn(&prev, (uint8_t)(n % SIM_MAX_CLASSES), (uint8_t)(n % 2), x,
                          y, (uint16_t)(n * 1013 % 1024), &cfg) < 0)
                goto seated;
            n++;
        }
    }
seated:
    for (int i = 0; i < n; i++) {
        in[i].ship = (uint8_t)i;
        in[i].buttons = (uint16_t)(SIM_BTN_THRUST | SIM_BTN_FIRE |
                                   ((i % 3) ? SIM_BTN_LEFT : SIM_BTN_RIGHT));
    }

    next = prev;
    long packs = 0, bytes = 0;
    double t0 = now_ms();
    for (int t = 0; t < ticks; t++) {
        sim_step(&next, &prev, in, (uint16_t)n, &cfg, &ev);
        prev = next;
        if (t % 5) continue;
        for (int i = 0; i < n; i++) {
            int len = sim_pack_around(&prev, buf, (int)sizeof buf, prev.ships[i].x,
                                      prev.ships[i].y,
                                      (int32_t)radius * SIM_TILE_PX * 256,
                                      (uint8_t)i, 0);
            if (len > 0) {
                packs++;
                bytes += len;
            }
        }
    }
    double ms = now_ms() - t0;
    double mean = packs ? (double)bytes / (double)packs : 0.0;

    printf("%4d tiles  %3d ships  %6.2f ms/tick (of 10)  %6.0f B  %6.1f KB/s a seat"
           "  %4d rounds up\n",
           tiles, n, ms / ticks, mean, mean * 20 / 1024, prev.weapon_count);
}

int main(int argc, char **argv) {
    if (argc > 1 && !strcmp(argv[1], "--selftest")) {
        /* Cheap enough to be worth having: proves the tool still builds and
         * runs against the current core without spending a benchmark's time. */
        load(256, 16, 100, 84);
        return 0;
    }
    int ticks = argc > 1 ? atoi(argv[1]) : 2000;

    printf("How long a world takes to cross, at the baseline:\n\n");
    crossing();

    printf("\nWhat a world costs, every gun held down, %d ticks:\n\n", ticks);
    load(SIM_MAP_TILES, 80, ticks, 84);
    load(SIM_MAP_TILES, 128, ticks, 84);
    load(SIM_MAP_TILES, SIM_MAX_SHIPS, ticks, 84);
    load(SIM_MAP_TILES / 2, SIM_MAX_SHIPS, ticks, 84);
    return 0;
}
