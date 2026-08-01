/* Unit tests for the sim core. Exit 0 on pass, 1 on first failure. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sim/sim.h"
#include "sim/baseline.h"
#include "sim/pack.h"

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
    memset(m->tile, SIM_TILE_EMPTY, sizeof m->tile);
    for (int i = 0; i < SIM_MAP_TILES; i++) {
        m->tile[i] = SIM_TILE_SOLID;
        m->tile[(size_t)(SIM_MAP_TILES - 1) * SIM_MAP_TILES + i] = SIM_TILE_SOLID;
        m->tile[(size_t)i * SIM_MAP_TILES] = SIM_TILE_SOLID;
        m->tile[(size_t)i * SIM_MAP_TILES + SIM_MAP_TILES - 1] = SIM_TILE_SOLID;
    }
    sim_map_index(m);
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
    int fires, hits, deaths, bounces, spawns, prizes, warps;
} ev_counts;

static ev_counts step_counting(sim_state *s, const sim_settings *cfg,
                               uint16_t b0, uint16_t b1, int n) {
    ev_counts c = {0, 0, 0, 0, 0, 0, 0};
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
                case SIM_EV_WARP: c.warps++; break;
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

    /* Sustained unanswered fire kills. Energy is the whole economy: it is the
     * health pool and the ammunition at once, and a ship that is being hit
     * faster than it recharges dies. Roughly five bullets does it, which is
     * where the original sat too -- 200 damage against 1000 starting energy.
     *
     * This asserted the opposite until the firing costs were corrected. A
     * bullet used to cost 35% of a full bar, so an attacker ran itself dry
     * long before the target was in danger, and nothing could ever die at
     * range. That was a bug wearing a test as an alibi. */
    {
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        sim_spawn(&s, APEX, 1, 8192, 8192 - 200, 0, &cfg);
        ev_counts c = step_counting(&s, &cfg, SIM_BTN_FIRE, 0, 4000);
        CHECK(c.hits > 3, "many hits land over a long exchange");
        CHECK(c.deaths > 0, "sustained fire eventually kills");
    }

    /* A bomb has to be affordable from a full bar, or the key is dead. It
     * costs 300 against a fresh bar of 1000 in the original -- three of them
     * -- so a fight has bombs in it rather than one opening move. */
    {
        sim_state s;
        sim_init(&s, 1);
        int id = sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        int32_t full = sim_eff_max_energy(&cfg.classes[APEX], &s.ships[id]);
        CHECK(cfg.classes[APEX].bomb_energy * 3 < full,
              "a fresh bar affords three bombs, as the original's 1000/300 did");
        ev_counts c = step_counting(&s, &cfg, SIM_BTN_BOMB, 0, 600);
        CHECK(c.fires > 1, "bombs actually leave the ship");
    }

    /* --- tiles ------------------------------------------------------- */

    /* A safe zone is the only brake in the game. Everywhere else momentum is
     * permanent, so without one a ship can never come to rest. */
    {
        sim_map *sm = walled_map();
        for (int ty = 500; ty < 506; ty++)
            for (int tx = 500; tx < 506; tx++)
                sm->tile[(size_t)ty * SIM_MAP_TILES + tx] = SIM_TILE_SAFE;
        sim_map_index(sm);
        sim_settings sc;
        memset(&sc, 0, sizeof sc);
        sim_settings_baseline(&sc, sm);

        sim_state s;
        sim_init(&s, 1);
        int id = sim_spawn(&s, APEX, 0, 502 * 16, 502 * 16, 0, &sc);
        CHECK(sim_in_safe(sm, s.ships[id].x, s.ships[id].y),
              "the ship is standing in the safe zone");
        /* Flight is untouched. Braking on entry made a safe zone flypaper,
         * and a zone that cannot be crossed at speed is a wall in a
         * different colour. */
        step_n(&s, &sc, SIM_BTN_THRUST, 0, 30);
        int32_t vy = s.ships[id].vy;
        CHECK(vy != 0, "a ship accelerates inside a safe zone");
        step_n(&s, &sc, 0, 0, 5);
        CHECK(s.ships[id].vy == vy, "and coasts through one unimpeded");

        /* Flight in a safe zone is not merely "not braked", it is identical
         * to flight anywhere else. Measured against open space rather than
         * against a threshold, because "slower but moving" is exactly what
         * the first attempt at this felt like and a threshold would have
         * passed it. */
        {
            sim_map *om = walled_map();
            sim_settings oc;
            memset(&oc, 0, sizeof oc);
            sim_settings_baseline(&oc, om);
            sim_state in_zone, open;
            sim_init(&in_zone, 1);
            sim_init(&open, 1);
            int a_id = sim_spawn(&in_zone, APEX, 0, 502 * 16, 502 * 16, 0, &sc);
            int b_id = sim_spawn(&open, APEX, 0, 502 * 16, 502 * 16, 0, &oc);
            step_n(&in_zone, &sc, SIM_BTN_THRUST, 0, 100);
            step_n(&open, &oc, SIM_BTN_THRUST, 0, 100);
            CHECK(in_zone.ships[a_id].vy == open.ships[b_id].vy,
                  "a safe zone does not slow a ship by so much as a unit");
            CHECK(in_zone.ships[a_id].y == open.ships[b_id].y,
                  "and it travels exactly as far");
            free(om);
        }

        /* The trigger is the brake, and it is the only one in the game. */
        ev_counts c = step_counting(&s, &sc, SIM_BTN_FIRE, 0, 1);
        CHECK(s.ships[id].vx == 0 && s.ships[id].vy == 0,
              "pressing fire in a safe zone stops the ship dead");
        c = step_counting(&s, &sc, SIM_BTN_FIRE, 0, 200);
        CHECK(c.fires == 0, "and no weapon leaves one");

        /* Whatever was already in the air comes down. Firing and running for
         * cover must not score from inside the one place nothing answers. */
        sim_state g;
        sim_init(&g, 1);
        int gid = sim_spawn(&g, APEX, 0, 502 * 16, 516 * 16, 0, &sc);
        step_n(&g, &sc, SIM_BTN_FIRE, 0, 1);
        CHECK(g.weapon_count > 0, "a shot fired outside exists");
        /* Walk it in rather than guess the distance: an Apex at full thrust
         * crosses a six tile zone and out the far side inside a second. */
        int arrived = 0;
        for (int t = 0; t < 400 && !arrived; t++) {
            step_n(&g, &sc, SIM_BTN_THRUST, 0, 1);
            arrived = sim_in_safe(sm, g.ships[gid].x, g.ships[gid].y);
        }
        CHECK(arrived, "the ship reached the safe zone");
        /* The sweep reads the position it had at the top of the tick, so it
         * takes effect on the one after it arrives. */
        step_n(&g, &sc, 0, 0, 2);
        CHECK(g.weapon_count == 0,
              "and its shots are gone with it");

        /* And nothing reaches in. */
        sim_state t;
        sim_init(&t, 1);
        int a_id = sim_spawn(&t, APEX, 0, 502 * 16, 520 * 16, 0, &sc);
        int v_id = sim_spawn(&t, APEX, 1, 502 * 16, 502 * 16, 0, &sc);
        (void)a_id;
        int32_t e0 = t.ships[v_id].energy;
        step_counting(&t, &sc, SIM_BTN_FIRE, 0, 400);
        CHECK(t.ships[v_id].energy >= e0,
              "a ship in a safe zone takes no damage");
        free(sm);
    }

    /* A door is a wall on a clock. Both states have to actually happen, or it
     * is either a wall or nothing at all. */
    {
        CHECK(cfg.door_period > 0, "doors have a cycle");
        int opened = 0, shut = 0;
        for (uint32_t t = 0; t < cfg.door_period; t++) {
            if (sim_door_open(&cfg, t, 0)) opened++; else shut++;
        }
        CHECK(opened > 0 && shut > 0, "a door both opens and shuts");
        /* Variants are phase offsets, so one channel can be open while
         * another is not -- a map that breathes rather than blinks. */
        int differ = 0;
        for (uint32_t t = 0; t < cfg.door_period; t++)
            if (sim_door_open(&cfg, t, 0) != sim_door_open(&cfg, t, 4)) differ = 1;
        CHECK(differ, "two door variants are out of phase");

        sim_map *dm = walled_map();
        for (int tx = 500; tx < 510; tx++)
            dm->tile[(size_t)504 * SIM_MAP_TILES + tx] = SIM_TILE(SIM_TILE_DOOR, 0);
        sim_map_index(dm);
        sim_settings dc;
        memset(&dc, 0, sizeof dc);
        sim_settings_baseline(&dc, dm);

        /* Shut, the door stops a ship; open, the same ship crosses it. */
        int blocked = 0, crossed = 0;
        for (int phase = 0; phase < 2; phase++) {
            sim_state s;
            sim_init(&s, 1);
            /* Start on the tick where the door is in the state we want. */
            uint32_t t0 = 0;
            while (sim_door_open(&dc, t0, 0) != phase) t0++;
            s.tick = t0;
            int id = sim_spawn(&s, APEX, 0, 505 * 16, 508 * 16, 0, &dc);
            step_n(&s, &dc, SIM_BTN_THRUST, 0, 120);
            int past = s.ships[id].y < 504 * 16 * 256;
            if (phase == 0 && !past) blocked = 1;
            if (phase == 1 && past) crossed = 1;
        }
        CHECK(blocked, "a shut door stops a ship");

        /* Caught in the doorway when it shuts, a ship is warped. Left where
         * it was, both axes are blocked and the collision below cannot free
         * it: it would sit inside a wall until something killed it. */
        {
            sim_state s;
            sim_init(&s, 1);
            uint32_t t0 = 0;
            while (!sim_door_open(&dc, t0, 0)) t0++;
            s.tick = t0;
            int id = sim_spawn(&s, APEX, 0, 505 * 16, 504 * 16, 0, &dc);
            int32_t sx = s.ships[id].spawn_x, sy = s.ships[id].spawn_y;
            /* Sit in the doorway until it comes down. */
            ev_counts c = step_counting(&s, &dc, 0, 0, dc.door_period);
            CHECK(c.warps > 0, "a door shutting on a ship warps it");
            CHECK(s.ships[id].x == sx && s.ships[id].y == sy,
                  "and puts it back where it started");
            CHECK(s.ships[id].alive, "without killing it");
        }
        CHECK(crossed, "an open door lets the same ship through");
        free(dm);
    }

    /* A wormhole pulls. It is the one force in the game a pilot does not
     * apply themselves. */
    {
        sim_map *wm = walled_map();
        wm->tile[(size_t)512 * SIM_MAP_TILES + 512] = SIM_TILE_WORMHOLE;
        sim_map_index(wm);
        CHECK(wm->feature_count == 1, "the wormhole is indexed as a feature");
        sim_settings wc;
        memset(&wc, 0, sizeof wc);
        sim_settings_baseline(&wc, wm);

        sim_state s;
        sim_init(&s, 1);
        int id = sim_spawn(&s, APEX, 0, 512 * 16, 520 * 16, 0, &wc);
        int32_t y0 = s.ships[id].y;
        step_n(&s, &wc, 0, 0, 60);
        CHECK(s.ships[id].y < y0, "a drifting ship falls toward a wormhole");
        CHECK(s.ships[id].vy < 0, "and keeps accelerating into it");

        /* Out of range it is not felt at all, or the whole map would sag. */
        sim_state f;
        sim_init(&f, 1);
        int fid = sim_spawn(&f, APEX, 0, 512 * 16, 700 * 16, 0, &wc);
        int32_t fy = f.ships[fid].y;
        step_n(&f, &wc, 0, 0, 60);
        CHECK(f.ships[fid].y == fy && f.ships[fid].vy == 0,
              "a ship beyond the rim is untouched");
        free(wm);
    }

    /* A map carries its own starts, so a zone can be pointed at one without
     * knowing its geometry. Without this, every ship began outside the walls
     * of the first custom map and drifted off. */
    {
        sim_map *am = malloc(sizeof *am);
        sim_map_arena(am);
        uint16_t tx = 0, ty = 0;
        CHECK(sim_map_spawn(am, 0, 0, &tx, &ty), "the arena names a start");
        CHECK(SIM_TILE_CLASS(sim_tile_at(am, tx, ty)) == SIM_TILE_SPAWN,
              "and it points at a spawn tile");

        /* Every start has to be somewhere a ship can actually be. */
        for (uint8_t team = 0; team < 2; team++) {
            for (uint32_t n = 0; n < 8; n++) {
                CHECK(sim_map_spawn(am, team, n, &tx, &ty), "a start exists");
                int cls = SIM_TILE_CLASS(sim_tile_at(am, tx, ty));
                CHECK(cls != SIM_TILE_SOLID, "no start is inside a wall");
            }
        }

        /* Walking them spreads a roster out rather than stacking it. */
        uint16_t ax, ay, bx, by;
        sim_map_spawn(am, 1, 0, &ax, &ay);
        sim_map_spawn(am, 1, 1, &bx, &by);
        CHECK(ax != bx || ay != by, "consecutive starts differ");

        /* And they wrap, so a roster longer than the map's starts still fits. */
        uint16_t wx, wy;
        sim_map_spawn(am, 1, 4, &wx, &wy);
        CHECK(wx == ax && wy == ay, "the fifth start wraps to the first");

        /* A map with no starts says so rather than inventing one. */
        sim_map *bare = malloc(sizeof *bare);
        memset(bare->tile, SIM_TILE_EMPTY, sizeof bare->tile);
        sim_map_index(bare);
        CHECK(!sim_map_spawn(bare, 0, 0, &tx, &ty),
              "a map with no starts reports none");
        free(am);
        free(bare);
    }

    /* A map survives the trip and is caught when it does not. */
    {
        sim_map *src = malloc(sizeof *src);
        sim_map_arena(src);
        uint8_t *buf = malloc(SIM_MAP_PACK_MAX);
        int n = sim_map_pack(src, buf, SIM_MAP_PACK_MAX);
        CHECK(n > 0, "the arena packs");
        /* A megabyte of tiles that is almost all one value has no business
         * costing a megabyte on the wire. */
        CHECK(n < 4096, "an arena packs to under 4 KB");

        sim_map *dst = malloc(sizeof *dst);
        memset(dst->tile, 0xee, sizeof dst->tile);
        CHECK(sim_map_unpack(dst, buf, n) == 0, "and unpacks");
        CHECK(memcmp(src->tile, dst->tile, sizeof src->tile) == 0,
              "every tile survives the round trip");
        CHECK(dst->feature_count == src->feature_count,
              "and the features are rebuilt on arrival");
        CHECK(sim_map_hash(src) == sim_map_hash(dst), "the hashes agree");

        /* A different map must not hash the same, or the check is theatre. */
        sim_map *duel = malloc(sizeof *duel);
        sim_map_duel(duel);
        CHECK(sim_map_hash(duel) != sim_map_hash(src),
              "two different maps hash differently");

        /* Corruption in the tiles is what the hash is for. */
        buf[n - 1] ^= 0xff;
        CHECK(sim_map_unpack(dst, buf, n) == -2, "a flipped tile is rejected");
        buf[n - 1] ^= 0xff;

        /* Truncation is not an empty tail. */
        CHECK(sim_map_unpack(dst, buf, n - 3) == -1, "a short map is rejected");
        CHECK(sim_map_unpack(dst, buf, 4) == -1, "a stub is rejected");

        /* And something that is not a map at all. */
        buf[0] ^= 0xff;
        CHECK(sim_map_unpack(dst, buf, n) == -1, "a bad magic is rejected");

        free(src); free(dst); free(duel); free(buf);
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

    /* A snapshot round trip reproduces the state exactly. This is what lets
     * a client accept the server's word without drifting from it. */
    {
        sim_state s, back;
        sim_init(&s, 11);
        sim_spawn(&s, APEX, 0, 8000, 8000, 900, &cfg);
        sim_spawn(&s, ANVIL, 1, 8000, 7800, 32768, &cfg);
        step_counting(&s, &cfg, SIM_BTN_THRUST | SIM_BTN_FIRE, SIM_BTN_BOMB, 900);

        static uint8_t buf[SIM_PACK_MAX];
        int n = sim_pack(&s, buf, sizeof buf);
        CHECK(n > 0, "a snapshot packs");
        CHECK(sim_unpack(&back, buf, n) == 0, "a snapshot unpacks");
        CHECK(sim_hash(&back) == sim_hash(&s), "the round trip is exact");

        /* And an unpacked state steps identically to the original, which is
         * the property client prediction actually depends on. */
        sim_state a2, b2;
        sim_input in = {0, SIM_BTN_THRUST};
        sim_step(&a2, &s, &in, 1, &cfg, NULL);
        sim_step(&b2, &back, &in, 1, &cfg, NULL);
        CHECK(sim_hash(&a2) == sim_hash(&b2), "an unpacked state steps identically");

        CHECK(sim_pack(&s, buf, 8) == -1, "packing reports an undersized buffer");
        CHECK(sim_unpack(&back, buf, 3) == -1, "unpacking rejects a truncated snapshot");
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
