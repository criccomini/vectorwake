/* Unit tests for the sim core. Exit 0 on pass, 1 on first failure. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sim/sim.h"
#include "sim/baseline.h"

static int failures = 0;
#define CHECK(cond, msg)                                          \
    do {                                                          \
        if (!(cond)) {                                            \
            printf("FAIL %s (%s:%d)\n", msg, __FILE__, __LINE__); \
            failures++;                                           \
        }                                                         \
    } while (0)

static sim_map *walled_map(void) {
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

static void step_n(sim_state *s, const sim_settings *cfg, uint16_t b0,
                   uint16_t b1, int n) {
    sim_state tmp;
    for (int i = 0; i < n; i++) {
        sim_input in[2] = {{0, b0}, {1, b1}};
        sim_step(&tmp, s, in, s->ship_count > 1 ? 2 : 1, cfg, NULL);
        *s = tmp;
    }
}

/* Counts of each event type over n ticks. Energy is a poor probe for damage
 * because recharge erases the evidence within a second; events do not lie. */
typedef struct {
    int fires, hits, deaths, bounces, spawns, prizes;
} ev_counts;

static ev_counts step_counting(sim_state *s, const sim_settings *cfg,
                               uint16_t b0, uint16_t b1, int n) {
    ev_counts c = {0, 0, 0, 0, 0, 0};
    sim_state tmp;
    sim_events ev;
    for (int i = 0; i < n; i++) {
        sim_input in[2] = {{0, b0}, {1, b1}};
        sim_step(&tmp, s, in, s->ship_count > 1 ? 2 : 1, cfg, &ev);
        *s = tmp;
        for (uint16_t e = 0; e < ev.count; e++) switch (ev.e[e].type) {
                case SIM_EV_FIRE: c.fires++; break;
                case SIM_EV_HIT: c.hits++; break;
                case SIM_EV_DEATH: c.deaths++; break;
                case SIM_EV_BOUNCE: c.bounces++; break;
                case SIM_EV_SPAWN: c.spawns++; break;
                case SIM_EV_PRIZE: c.prizes++; break;
                default: break;
            }
    }
    return c;
}

int main(void) {
    sim_map *m = walled_map();
    sim_settings cfg;
    memset(&cfg, 0, sizeof cfg);
    sim_settings_baseline(&cfg, m);
    const int APEX = 0, ANVIL = 3;

    /* Thrust at heading 0 moves up (-y) and nowhere else. */
    {
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        step_n(&s, &cfg, SIM_BTN_THRUST, 0, 100);
        CHECK(s.ships[0].vy < 0, "thrust up gives negative vy");
        CHECK(s.ships[0].vx == 0, "thrust up gives zero vx");
        CHECK(s.ships[0].y < 8192 * 256, "ship moved up");
    }

    /* No drag: coasting preserves velocity exactly, forever. */
    {
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        step_n(&s, &cfg, SIM_BTN_THRUST, 0, 50);
        int32_t vy = s.ships[0].vy;
        step_n(&s, &cfg, 0, 0, 1000);
        CHECK(s.ships[0].vy == vy, "coasting preserves velocity exactly");
    }

    /* Speed clamps at the class maximum. */
    {
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        step_n(&s, &cfg, SIM_BTN_THRUST, 0, 400);
        int64_t v = -(int64_t)s.ships[0].vy;
        int32_t cap = sim_eff_speed(&cfg.classes[APEX], &s.ships[0]);
        CHECK(v <= cap, "speed does not exceed the effective cap");
        CHECK(v > cap - 2048, "speed reaches near the effective cap");
        CHECK(cap < cfg.classes[APEX].max_speed,
              "a fresh ship flies below its upgraded ceiling");
    }

    /* Energy recharges to the cap and stops there. */
    {
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        s.ships[0].energy = 0;
        step_n(&s, &cfg, 0, 0, 10);
        CHECK(s.ships[0].energy > 0, "energy recharges");
        step_n(&s, &cfg, 0, 0, 2000);
        CHECK(s.ships[0].energy == sim_eff_max_energy(&cfg.classes[APEX], &s.ships[0]),
              "energy clamps at the effective maximum");
    }

    /* Firing costs energy, respects the cooldown, and creates a weapon. */
    {
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        int32_t e0 = s.ships[0].energy;
        step_n(&s, &cfg, SIM_BTN_FIRE, 0, 1);
        CHECK(s.weapon_count == 1, "firing creates one weapon");
        CHECK(s.ships[0].energy < e0, "firing costs energy");
        step_n(&s, &cfg, SIM_BTN_FIRE, 0, 5);
        CHECK(s.weapon_count == 1, "cooldown blocks a second shot");
        step_n(&s, &cfg, SIM_BTN_FIRE, 0, 25);
        CHECK(s.weapon_count == 2, "cooldown expires and the next shot fires");
    }

    /* A bullet travels away from its firer and expires on its own. */
    {
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        step_n(&s, &cfg, SIM_BTN_FIRE, 0, 1);
        int32_t y0 = s.weapons[0].y;
        step_n(&s, &cfg, 0, 0, 10);
        CHECK(s.weapon_count == 1 && s.weapons[0].y < y0, "bullet moves up");
        step_n(&s, &cfg, 0, 0, cfg.classes[APEX].bullet_life + 5);
        CHECK(s.weapon_count == 0, "bullet expires");
    }

    /* A bullet damages an enemy in its path and eventually kills it. */
    {
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);   /* faces up */
        sim_spawn(&s, APEX, 1, 8192, 8192 - 200, 0, &cfg); /* directly above */
        int32_t e0 = s.ships[1].energy;
        ev_counts c = step_counting(&s, &cfg, SIM_BTN_FIRE, 0, 150);
        CHECK(c.hits > 0, "bullets hit the enemy"); /* 2 px/tick, 200 px gap */
        CHECK(s.ships[1].energy < e0, "bullet damaged the enemy");
        CHECK(s.ships[1].alive, "one bullet does not kill");
    }

    /* Trading fire at range does not kill: energy is the whole economy, and
     * a target that recharges faster than it is hit survives. Landing the
     * kill means landing a burst, which is the game the original played. */
    {
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        sim_spawn(&s, APEX, 1, 8192, 8192 - 200, 0, &cfg);
        ev_counts c = step_counting(&s, &cfg, SIM_BTN_FIRE, 0, 4000);
        CHECK(c.hits > 3, "many hits land over a long exchange");
        CHECK(c.deaths == 0, "recharge outpaces sustained ranged fire");
    }

    /* Friendly fire passes through: same team, no damage. */
    {
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        sim_spawn(&s, APEX, 0, 8192, 8192 - 200, 0, &cfg); /* same team */
        int32_t e0 = s.ships[1].energy;
        step_n(&s, &cfg, SIM_BTN_FIRE, 0, 400);
        CHECK(s.ships[1].energy == e0, "teammates take no bullet damage");
        CHECK(s.ships[1].alive, "teammates survive");
    }

    /* Death respawns at the spawn point after the configured delay. */
    {
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        sim_spawn(&s, APEX, 1, 8192, 8192 - 200, 0, &cfg);
        s.ships[1].energy = 1;
        ev_counts c = step_counting(&s, &cfg, SIM_BTN_FIRE, 0, 150);
        CHECK(!s.ships[1].alive, "low energy target dies");
        CHECK(c.deaths == 1, "death is reported once");
        CHECK(s.ships[0].kills == 1, "the killer is credited");
        CHECK(s.ships[1].deaths == 1, "the victim's deaths increment");
        step_n(&s, &cfg, 0, 0, cfg.respawn_delay + 2);
        CHECK(s.ships[1].alive, "the dead respawn");
        CHECK(s.ships[1].energy == sim_eff_max_energy(&cfg.classes[APEX], &s.ships[1]),
              "respawn restores full energy");
        CHECK(s.ships[1].x == s.ships[1].spawn_x, "respawn returns to spawn");
    }

    /* A bomb detonating on a wall damages a nearby enemy through splash. */
    {
        sim_state s;
        sim_init(&s, 1);
        /* Anvil at the left wall firing into it, enemy just behind it.
         * Assert on the hit event rather than on energy: recharge erases
         * the evidence of a glancing blast within a second. */
        sim_spawn(&s, ANVIL, 0, 40, 8192, 49152, &cfg); /* faces left */
        sim_spawn(&s, APEX, 1, 60, 8192, 0, &cfg);
        ev_counts c = step_counting(&s, &cfg, SIM_BTN_BOMB, 0, 60);
        CHECK(c.fires == 1, "the bomb was fired");
        CHECK(c.hits > 0, "bomb splash damages a nearby enemy");
    }

    /* Prizes spawn, get collected, and raise the ship's effective stats. */
    {
        sim_state s;
        sim_init(&s, 3);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        step_n(&s, &cfg, 0, 0, cfg.prize_delay + 2);
        int live = 0;
        for (int i = 0; i < SIM_MAX_PRIZES; i++) live += s.prizes[i].active;
        CHECK(live > 0, "a prize appears");

        /* Teleport the ship onto one and confirm the pickup. */
        int idx = -1;
        for (int i = 0; i < SIM_MAX_PRIZES; i++)
            if (s.prizes[i].active) { idx = i; break; }
        s.ships[0].up[SIM_UP_SPEED] = 0;
        uint8_t want = SIM_UP_SPEED;
        s.prizes[idx].type = want;
        s.ships[0].x = s.prizes[idx].x;
        s.ships[0].y = s.prizes[idx].y;
        int32_t before = sim_eff_speed(&cfg.classes[APEX], &s.ships[0]);
        ev_counts c = step_counting(&s, &cfg, 0, 0, 2);
        CHECK(c.prizes > 0, "flying over a prize collects it");
        CHECK(s.ships[0].up[want] == 1, "the upgrade is recorded");
        CHECK(sim_eff_speed(&cfg.classes[APEX], &s.ships[0]) > before,
              "the upgrade raises effective speed");

        /* Dying strips everything. */
        s.ships[0].up[SIM_UP_ENERGY] = 4;
        /* Spawn the shooter above and facing down, or it fires away. */
        sim_spawn(&s, APEX, 1, s.ships[0].x / 256, s.ships[0].y / 256 - 200,
                  32768, &cfg);
        s.ships[0].energy = 1;
        step_counting(&s, &cfg, 0, SIM_BTN_FIRE, 400);
        CHECK(s.ships[0].deaths > 0, "the target dies");
        CHECK(s.ships[0].up[SIM_UP_SPEED] == 0 && s.ships[0].up[SIM_UP_ENERGY] == 0,
              "death strips every upgrade");
    }

    /* Walls are inelastic: a bounce returns less speed than it took, and a
     * ship resting against one settles rather than buzzing. */
    {
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 2000, 0, &cfg);  /* faces the top wall */
        step_n(&s, &cfg, SIM_BTN_THRUST, 0, 100);     /* build speed, coast in */

        sim_state before, tmp;
        sim_events ev;
        int bounced = 0;
        for (int i = 0; i < 4000 && !bounced; i++) {
            before = s;
            sim_step(&tmp, &s, NULL, 0, &cfg, &ev);
            s = tmp;
            for (uint16_t e = 0; e < ev.count; e++)
                if (ev.e[e].type == SIM_EV_BOUNCE) bounced = 1;
        }
        CHECK(bounced, "the ship reaches the wall");
        if (bounced) {
            int64_t was = -(int64_t)before.ships[0].vy;  /* upward, so negative */
            int64_t now = (int64_t)s.ships[0].vy;        /* downward after */
            CHECK(now > 0, "the bounce reverses direction");
            CHECK(now < was, "the bounce loses speed");
            CHECK(now * 16 <= was * cfg.bounce + 16,
                  "speed retained matches the restitution setting");
        }

        /* Left leaning on the wall under thrust, it must not jitter forever. */
        step_n(&s, &cfg, SIM_BTN_THRUST, 0, 600);
        ev_counts c = step_counting(&s, &cfg, SIM_BTN_THRUST, 0, 200);
        CHECK(c.bounces < 20, "grinding on a wall does not spam impacts");
    }

    /* Determinism: identical runs give identical hashes and bytes. */
    {
        sim_state s1, s2;
        sim_init(&s1, 42);
        sim_init(&s2, 42);
        sim_spawn(&s1, APEX, 0, 5000, 5000, 1234, &cfg);
        sim_spawn(&s1, ANVIL, 1, 5000, 4800, 0, &cfg);
        sim_spawn(&s2, APEX, 0, 5000, 5000, 1234, &cfg);
        sim_spawn(&s2, ANVIL, 1, 5000, 4800, 0, &cfg);
        step_n(&s1, &cfg, SIM_BTN_THRUST | SIM_BTN_LEFT | SIM_BTN_FIRE,
               SIM_BTN_BOMB, 3000);
        step_n(&s2, &cfg, SIM_BTN_THRUST | SIM_BTN_LEFT | SIM_BTN_FIRE,
               SIM_BTN_BOMB, 3000);
        CHECK(sim_hash(&s1) == sim_hash(&s2), "identical runs hash equal");
        CHECK(memcmp(&s1, &s2, sizeof s1) == 0, "identical runs memcmp equal");
    }

    /* Rollback: a saved state replayed forward reproduces the future. */
    {
        sim_state s, saved, tmp;
        sim_init(&s, 7);
        sim_spawn(&s, APEX, 0, 6000, 6000, 0, &cfg);
        sim_spawn(&s, APEX, 1, 6000, 5800, 0, &cfg);
        step_n(&s, &cfg, SIM_BTN_THRUST, 0, 100);
        saved = s;
        step_n(&s, &cfg, SIM_BTN_FIRE | SIM_BTN_RIGHT, SIM_BTN_THRUST, 250);
        uint64_t future = sim_hash(&s);
        s = saved; /* rollback is an assignment */
        step_n(&s, &cfg, SIM_BTN_FIRE | SIM_BTN_RIGHT, SIM_BTN_THRUST, 250);
        CHECK(sim_hash(&s) == future, "replay after rollback reproduces state");
        (void)tmp;
    }

    free(m);
    if (failures == 0) printf("all tests passed\n");
    return failures ? 1 : 0;
}
