/* Unit tests for the sim core. Exit 0 on pass, 1 on first failure. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sim/sim.h"

static int failures = 0;
#define CHECK(cond, msg)                                        \
    do {                                                        \
        if (!(cond)) {                                          \
            printf("FAIL %s (%s:%d)\n", msg, __FILE__, __LINE__); \
            failures++;                                         \
        }                                                       \
    } while (0)

static sim_map *empty_map(void) {
    sim_map *m = malloc(sizeof *m);
    memset(m->solid, 0, sizeof m->solid);
    for (int i = 0; i < SIM_MAP_TILES; i++) {
        m->solid[i] = 1;
        m->solid[(size_t)(SIM_MAP_TILES - 1) * SIM_MAP_TILES + i] = 1;
        m->solid[(size_t)i * SIM_MAP_TILES] = 1;
        m->solid[(size_t)i * SIM_MAP_TILES + SIM_MAP_TILES - 1] = 1;
    }
    return m;
}

static sim_settings test_cfg(const sim_map *m) {
    sim_settings cfg = {0};
    cfg.ship.max_speed = sim_vie_speed(4375);
    cfg.ship.thrust = sim_vie_thrust(25);
    cfg.ship.rot = sim_vie_rotation(380);
    cfg.ship.radius = 14 * 256;
    cfg.bounce = 16;
    cfg.map = m;
    return cfg;
}

static void step_n(sim_state *s, const sim_settings *cfg, uint16_t buttons,
                   int n) {
    sim_state tmp;
    for (int i = 0; i < n; i++) {
        sim_input in = {0, buttons};
        sim_step(&tmp, s, &in, 1, cfg, NULL);
        *s = tmp;
    }
}

int main(void) {
    sim_map *m = empty_map();
    sim_settings cfg = test_cfg(m);

    /* Thrust at heading 0 moves up (-y) and nowhere else. */
    {
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, 8192, 8192, 0);
        step_n(&s, &cfg, SIM_BTN_THRUST, 100);
        CHECK(s.ships[0].vy < 0, "thrust up gives negative vy");
        CHECK(s.ships[0].vx == 0, "thrust up gives zero vx");
        CHECK(s.ships[0].y < 8192 * 256, "ship moved up");
        CHECK(s.ships[0].x == 8192 * 256, "ship did not move sideways");
    }

    /* No drag: velocity is unchanged by coasting. */
    {
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, 8192, 8192, 0);
        step_n(&s, &cfg, SIM_BTN_THRUST, 50);
        int32_t vy = s.ships[0].vy;
        step_n(&s, &cfg, 0, 1000);
        CHECK(s.ships[0].vy == vy, "coasting preserves velocity exactly");
    }

    /* Speed clamps at the class maximum. 400 ticks reaches the cap (~176)
     * without crossing enough map to hit the border wall. */
    {
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, 8192, 8192, 0);
        step_n(&s, &cfg, SIM_BTN_THRUST, 400);
        int64_t v = -(int64_t)s.ships[0].vy;
        CHECK(v <= cfg.ship.max_speed, "speed does not exceed max");
        CHECK(v > cfg.ship.max_speed - 2048, "speed reaches near max");
    }

    /* Rotation wraps and a full turn returns home. 40000/380 is not an
     * integer, so check half turn reverses the sign of motion instead. */
    {
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, 8192, 8192, 0);
        int half_ticks = 32768 / cfg.ship.rot;
        step_n(&s, &cfg, SIM_BTN_RIGHT, half_ticks);
        step_n(&s, &cfg, SIM_BTN_THRUST, 100);
        CHECK(s.ships[0].vy > 0, "after half turn, thrust moves down");
    }

    /* A wall bounce with factor 16 preserves speed and flips the sign. */
    {
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, 40, 8192, 0); /* near the left wall */
        int half_ticks = 16384 / cfg.ship.rot;
        step_n(&s, &cfg, SIM_BTN_LEFT, half_ticks); /* face left-ish */
        step_n(&s, &cfg, SIM_BTN_THRUST, 400);
        sim_state before = s;
        sim_events ev = {0};
        sim_state tmp;
        int bounced = 0;
        for (int i = 0; i < 4000 && !bounced; i++) {
            sim_step(&tmp, &s, NULL, 0, &cfg, &ev);
            before = s;
            s = tmp;
            if (ev.bounces) bounced = 1;
        }
        CHECK(bounced, "ship eventually hits the wall");
        if (bounced) {
            CHECK(before.ships[0].vx < 0 && s.ships[0].vx > 0,
                  "bounce flips vx");
            CHECK(s.ships[0].vx == -before.ships[0].vx,
                  "bounce 16/16 preserves speed exactly");
        }
    }

    /* Determinism: identical runs give identical hashes. */
    {
        sim_state s1, s2;
        sim_init(&s1, 42);
        sim_init(&s2, 42);
        sim_spawn(&s1, 5000, 5000, 1234);
        sim_spawn(&s2, 5000, 5000, 1234);
        step_n(&s1, &cfg, SIM_BTN_THRUST | SIM_BTN_LEFT, 3000);
        step_n(&s2, &cfg, SIM_BTN_THRUST | SIM_BTN_LEFT, 3000);
        CHECK(sim_hash(&s1) == sim_hash(&s2), "identical runs hash equal");
        CHECK(memcmp(&s1, &s2, sizeof s1) == 0, "identical runs memcmp equal");
    }

    free(m);
    if (failures == 0) printf("all tests passed\n");
    return failures ? 1 : 0;
}
