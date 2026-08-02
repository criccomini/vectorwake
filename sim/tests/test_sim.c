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

/* What one pull of the gun trigger charges, and how long it locks the
 * trigger for.
 *
 * Measured against an identical tick that did not fire, because recharge
 * lands in the same tick as the shot and the bar alone cannot tell the two
 * apart -- reading the drop directly makes every shot look a recharge
 * cheaper than it is. Energy is dropped below full first so that neither
 * tick clamps at the ceiling and hides part of the answer. */
static int32_t gun_cost(const sim_settings *cfg, uint8_t cls, uint16_t mods,
                        uint16_t *wait) {
    sim_state a, b;
    sim_init(&a, 1);
    sim_spawn(&a, cls, 0, 8192, 8192, 0, cfg);
    a.ships[0].energy /= 2;
    a.ships[0].mods[SIM_TRIG_GUN] = mods;
    b = a;
    step_n(&a, cfg, 0, 0, 1);
    step_n(&b, cfg, SIM_BTN_FIRE, 0, 1);
    if (wait) *wait = b.ships[0].fire_cooldown;
    return a.ships[0].energy - b.ships[0].energy;
}

/* How much of one prize kind a pilot is holding. The core keeps this rule to
 * itself; the test needs it to check that rust took what it says it took. */
static uint8_t held_of(const sim_ship *sh, uint8_t type) {
    if (type < SIM_UP_COUNT) return sh->up[type];
    type = (uint8_t)(type - SIM_UP_COUNT);
    if (type < SIM_TRIG_COUNT) return sh->level[type];
    type = (uint8_t)(type - SIM_TRIG_COUNT);
    if (type < SIM_TRIG_COUNT * SIM_MOD_COUNT)
        return sim_mod_get(sh->mods[type / SIM_MOD_COUNT], type % SIM_MOD_COUNT);
    return sh->charge[type - SIM_TRIG_COUNT * SIM_MOD_COUNT];
}

/* A hull's gun and bomb, through the tables. Tests used to read weapon
 * numbers off the class; they live in the settings now, one step further
 * out, because a weapon is a thing a zone configures rather than a property
 * of a hull. */
static const sim_fire_pattern *gun_of(const sim_settings *cfg, int cls) {
    return &cfg->patterns[cfg->classes[cls].trigger[SIM_TRIG_GUN][0]];
}
static const sim_weapon_spec *gun_spec(const sim_settings *cfg, int cls) {
    return &cfg->specs[gun_of(cfg, cls)->spec];
}
static const sim_fire_pattern *bomb_of(const sim_settings *cfg, int cls) {
    return &cfg->patterns[cfg->classes[cls].trigger[SIM_TRIG_BOMB][0]];
}

int main(void) {
    sim_map *m = walled_map();
    sim_settings cfg;
    memset(&cfg, 0, sizeof cfg);
    sim_settings_baseline(&cfg, m);
    /* Every test below that is not about the opening loadout wants a plain
     * ship: with the baseline's thirty spawn greens, a "does one trigger pull
     * make one bullet" test is really asking whether the roll handed out
     * multifire. The feature has its own test, which sets this back. */
    cfg.spawn_prizes = 0;
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
        step_n(&s, &cfg, 0, 0, gun_spec(&cfg, APEX)->life + 5);
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
        CHECK(bomb_of(&cfg, APEX)->energy * 3 < full,
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

        /* Walking them spreads a roster out rather than stacking it, and on
         * a map this size "spread" has to mean spread: eight pilots inside
         * one 84-tile box on a 1024-tile map is the small arena again with
         * unused address space around it. So the starts are checked for
         * distance, not just for being different tiles. */
        uint16_t ax, ay, bx, by;
        sim_map_spawn(am, 1, 0, &ax, &ay);
        sim_map_spawn(am, 1, 1, &bx, &by);
        CHECK(ax != bx || ay != by, "consecutive starts differ");

        int far_apart = 0, count = 0;
        for (uint32_t n = 0; n < 64; n++) {
            uint16_t nx, ny;
            sim_map_spawn(am, 1, n, &nx, &ny);
            if (n > 0 && nx == ax && ny == ay) { count = (int)n; break; }
            int dx = (int)nx - (int)ax, dy = (int)ny - (int)ay;
            if (dx * dx + dy * dy > 200 * 200) far_apart++;
        }
        CHECK(count > 4, "a side has more than a corner's worth of starts");
        CHECK(far_apart >= 3, "and they are hundreds of tiles apart");

        /* They wrap, so a roster longer than the map's starts still fits. */
        uint16_t wx, wy;
        sim_map_spawn(am, 1, (uint32_t)count, &wx, &wy);
        CHECK(wx == ax && wy == ay, "walking past the last wraps to the first");

        /* And the two sides start apart, or the map has no front line. */
        uint16_t zx, zy;
        sim_map_spawn(am, 0, 0, &zx, &zy);
        CHECK((int)zy - (int)ay > 300 || (int)ay - (int)zy > 300,
              "the two sides start in different halves");

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
        /* A megabyte of tiles has no business costing a megabyte on the
         * wire. Twenty-eight kilobytes for the full-size arena -- it was
         * under four when the arena was an 84-tile room, and the difference
         * is the two hundred and fifty-six structures in the field. Sent
         * once, when a client joins, so the bound is here to catch the run
         * encoding breaking rather than to hold a budget. */
        CHECK(n < 32768, "an arena packs to under 32 KB");

        sim_map *dst = malloc(sizeof *dst);
        memset(dst->tile, 0xee, sizeof dst->tile);
        CHECK(sim_map_unpack(dst, buf, n) == 0, "and unpacks");
        CHECK(memcmp(src->tile, dst->tile, sizeof src->tile) == 0,
              "every tile survives the round trip");
        CHECK(dst->feature_count == src->feature_count,
              "and the features are rebuilt on arrival");
        CHECK(sim_map_hash(src) == sim_map_hash(dst), "the hashes agree");

        /* A different map must not hash the same, or the check is theatre. */
        sim_map *pit = malloc(sizeof *pit);
        sim_map_pit(pit);
        CHECK(sim_map_hash(pit) != sim_map_hash(src),
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

        free(src); free(dst); free(pit); free(buf);
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

    /* Changing hull is a respawn, not a costume change, and it leaves the
     * rest of the arena exactly where it was. */
    {
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        sim_spawn(&s, APEX, 1, 8500, 8192, 0, &cfg);
        step_n(&s, &cfg, SIM_BTN_THRUST, SIM_BTN_THRUST, 30);
        s.ships[0].up[SIM_UP_SPEED] = 3;
        int32_t foe_y = s.ships[1].y;
        CHECK(s.ships[0].y != s.ships[0].spawn_y, "the pilot had flown off");
        CHECK(sim_set_ship_class(&s, &cfg, 0, ANVIL) == 0, "the hull changed");
        CHECK(s.ships[0].cls == ANVIL, "into the one asked for");
        CHECK(s.ships[0].y == s.ships[0].spawn_y, "back at the start");
        CHECK(s.ships[0].vx == 0 && s.ships[0].vy == 0, "and at rest");
        CHECK(s.ships[0].up[SIM_UP_SPEED] == 0, "upgrades cost what dying costs");
        CHECK(s.ships[0].energy ==
              sim_eff_max_energy(&cfg.classes[ANVIL], &s.ships[0]),
              "with a full bar of the new ship");
        CHECK(s.ships[1].y == foe_y, "and nobody else moved");
        CHECK(s.ships[0].team == 0, "and you are still on your own team");
        CHECK(sim_set_ship_class(&s, &cfg, 9, APEX) == -1, "no such ship");
        CHECK(sim_set_ship_class(&s, &cfg, 0, 99) == -1, "no such class");
    }

    /* Only from a full bar. A fresh hull is a full bar, so without this the
     * ship list is a way out of a fight you are losing. */
    {
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        s.ships[0].up[SIM_UP_SPEED] = 2;
        s.ships[0].energy -= 1;
        CHECK(sim_set_ship_class(&s, &cfg, 0, ANVIL) == -1,
              "a damaged pilot cannot swap hull");
        CHECK(s.ships[0].cls == APEX, "and is left in the one they had");
        CHECK(s.ships[0].up[SIM_UP_SPEED] == 2, "with what they had collected");
        step_n(&s, &cfg, 0, 0, 40);      /* recharge to the top */
        CHECK(sim_set_ship_class(&s, &cfg, 0, ANVIL) == 0,
              "and can once the bar is full again");
    }

    /* Nor while dead: this sets `alive`, so allowing it would hand out an
     * early respawn to anybody who opened the menu on the way down. */
    {
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        s.ships[0].alive = 0;
        s.ships[0].respawn_at = 200;
        CHECK(sim_set_ship_class(&s, &cfg, 0, ANVIL) == -1,
              "a dead pilot cannot swap hull");
        CHECK(s.ships[0].respawn_at == 200, "and still owes the full wait");
    }

    /* The hull you are already in is not a change, and must not cost you the
     * upgrades that picking it would otherwise throw away. */
    {
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        s.ships[0].up[SIM_UP_ENERGY] = 4;
        s.ships[0].energy = sim_eff_max_energy(&cfg.classes[APEX], &s.ships[0]);
        CHECK(sim_set_ship_class(&s, &cfg, 0, APEX) == 0, "asking for it succeeds");
        CHECK(s.ships[0].up[SIM_UP_ENERGY] == 4, "and costs nothing");
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

    /* A bomb that connects goes off too. The ship it hits is not the only one
     * hurt -- otherwise a well aimed bomb is a slow bullet, and the area is
     * the whole point of the weapon. */
    {
        sim_state s;
        sim_init(&s, 1);
        /* Firing east into a target, with a second enemy a ship's length
         * past it and well inside the 48px blast. */
        sim_spawn(&s, ANVIL, 0, 8192, 8192, 16384, &cfg);
        sim_spawn(&s, APEX, 1, 8192 + 150, 8192, 0, &cfg);
        sim_spawn(&s, APEX, 1, 8192 + 175, 8192, 0, &cfg);
        /* One tick on the trigger, then hands off: the Anvil reloads in 60
         * and the flight is longer than that, so holding it fires twice and
         * the count stops meaning anything. Far enough out, too, that the
         * blast does not reach back to the ship that fired it. */
        ev_counts c = step_counting(&s, &cfg, SIM_BTN_BOMB, 0, 1);
        ev_counts d = step_counting(&s, &cfg, 0, 0, 120);
        CHECK(c.fires == 1, "one bomb was fired");
        CHECK(d.hits == 2, "the ship it hit and the one beside them both take it");
    }

    /* Out of range is not a detonation: a bomb has to arrive somewhere. */
    {
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, ANVIL, 0, 8192, 8192, 16384, &cfg);
        sim_settings brief = cfg;
        brief.specs[bomb_of(&brief, ANVIL)->spec].life = 60;
        step_n(&s, &brief, SIM_BTN_BOMB, 0, 50);
        CHECK(s.weapon_count == 1, "the bomb is still in the air at 50 ticks");
        /* Beside where it is about to die: inside the blast, too far off the
         * line to be a collision. Read rather than predicted, so the test
         * does not quietly stop covering anything when a speed changes. */
        int32_t bx = s.weapons[0].x / 256, by = s.weapons[0].y / 256;
        sim_spawn(&s, APEX, 1, bx + 8, by - 30, 0, &cfg);
        ev_counts c = step_counting(&s, &brief, 0, 0, 20);
        CHECK(s.weapon_count == 0, "and it has run out by then");
        CHECK(c.hits == 0, "a bomb that runs out hurts nobody");
    }

    /* --- the weapon model ---------------------------------------------
     *
     * The shipped zone uses two plain rows of the table, so these build
     * their own: a spec and a pattern per test, pointed at a hull's gun.
     * That is the whole claim of the model -- a new weapon is a table row
     * and no new code -- and it is only true if it can be demonstrated
     * without touching the core. */
    {
        /* Spread: one trigger, three projectiles, none of them parallel. */
        sim_settings w = cfg;
        sim_weapon_spec sp = w.specs[gun_of(&w, APEX)->spec];
        sim_fire_pattern fp = *gun_of(&w, APEX);
        fp.spec = (uint8_t)sim_add_spec(&w, &sp);
        fp.count = 3;
        fp.spacing = 65536 / 18;          /* twenty degrees */
        w.classes[APEX].trigger[SIM_TRIG_GUN][0] = (uint8_t)sim_add_pattern(&w, &fp);

        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &w);
        step_n(&s, &w, SIM_BTN_FIRE, 0, 1);
        CHECK(s.weapon_count == 3, "one shot, three projectiles");
        CHECK(s.weapons[0].vx < s.weapons[1].vx
              && s.weapons[1].vx < s.weapons[2].vx,
              "and they fan out in order");
        CHECK(s.weapons[1].vx == 0, "with the middle one straight ahead");
    }

    {
        /* Bounce, and only as many times as the spec allows. */
        sim_settings w = cfg;
        sim_weapon_spec sp = w.specs[gun_of(&w, APEX)->spec];
        sp.on_wall = SIM_WALL_BOUNCE;
        sp.bounces = 1;
        sim_fire_pattern fp = *gun_of(&w, APEX);
        fp.spec = (uint8_t)sim_add_spec(&w, &sp);
        w.classes[APEX].trigger[SIM_TRIG_GUN][0] = (uint8_t)sim_add_pattern(&w, &fp);

        sim_state s;
        sim_init(&s, 1);
        /* Two tiles from the top wall, facing it. */
        sim_spawn(&s, APEX, 0, 8192, 40, 0, &w);
        step_n(&s, &w, SIM_BTN_FIRE, 0, 1);
        CHECK(s.weapon_count == 1, "fired");
        int32_t up = s.weapons[0].vy;
        CHECK(up < 0, "travelling up");
        step_n(&s, &w, 0, 0, 30);
        CHECK(s.weapon_count == 1, "the wall did not end it");
        CHECK(s.weapons[0].vy > 0, "it came back down");
        /* Send it back at the same wall rather than waiting for a second one:
         * a round travels 2 px a tick and the far wall is half a map away, so
         * the flight would run out of life long before it arrived. */
        s.weapons[0].vy = -s.weapons[0].vy;
        step_n(&s, &w, 0, 0, 40);
        CHECK(s.weapon_count == 0, "and the wall did the second time, with no bounce left");
    }

    {
        /* Straight through, for something that ignores walls. */
        sim_settings w = cfg;
        sim_weapon_spec sp = w.specs[gun_of(&w, APEX)->spec];
        sp.on_wall = SIM_WALL_PASS;
        sim_fire_pattern fp = *gun_of(&w, APEX);
        fp.spec = (uint8_t)sim_add_spec(&w, &sp);
        w.classes[APEX].trigger[SIM_TRIG_GUN][0] = (uint8_t)sim_add_pattern(&w, &fp);

        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 40, 0, &w);
        step_n(&s, &w, SIM_BTN_FIRE, 0, 1);
        step_n(&s, &w, 0, 0, 40);
        CHECK(s.weapon_count == 1, "a wall is not an ending for everything");
        CHECK(s.weapons[0].y < 0, "and it is on the other side of it");
    }

    {
        /* A proximity fuse: it never touches the hull. */
        sim_settings w = cfg;
        sim_weapon_spec sp = w.specs[gun_of(&w, APEX)->spec];
        sp.trigger = 60 * 256;
        sim_fire_pattern fp = *gun_of(&w, APEX);
        fp.spec = (uint8_t)sim_add_spec(&w, &sp);
        w.classes[APEX].trigger[SIM_TRIG_GUN][0] = (uint8_t)sim_add_pattern(&w, &fp);

        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &w);
        sim_spawn(&s, APEX, 1, 8192, 8192 - 140, 0, &w);
        step_n(&s, &w, SIM_BTN_FIRE, 0, 1);
        /* Where it was on the last tick it existed. Read rather than
         * predicted: the claim is that it stopped short, and a computed
         * answer would only be restating the arithmetic under test. */
        int32_t last = s.weapons[0].y;
        for (int t = 0; t < 60 && s.weapon_count; t++) {
            last = s.weapons[0].y;
            step_n(&s, &w, 0, 0, 1);
        }
        CHECK(s.weapon_count == 0, "it went off");
        CHECK(s.ships[1].energy
              < sim_eff_max_energy(&w.classes[APEX], &s.ships[1]),
              "close enough counted");
        CHECK(last - s.ships[1].y > w.classes[APEX].radius,
              "without ever reaching the hull");
    }

    {
        /* Shrapnel: an ending that fires another pattern, once. */
        sim_settings w = cfg;
        sim_weapon_spec frag;
        memset(&frag, 0, sizeof frag);
        frag.speed = sim_units_speed(1200);
        frag.life = 40;
        frag.expire_ends = 1;
        frag.damage = sim_units_energy(50);
        frag.splinter = SIM_NO_PATTERN;
        sim_fire_pattern shell;
        memset(&shell, 0, sizeof shell);
        shell.spec = (uint8_t)sim_add_spec(&w, &frag);
        shell.count = 8;
        shell.spacing = 65536 / 8;
        uint8_t shell_id = (uint8_t)sim_add_pattern(&w, &shell);
        /* Point the fragments back at their own pattern, which is the honest
         * shape of the danger: nothing in a table stops a weapon naming
         * itself, so the depth on the projectile has to. */
        w.specs[shell.spec].splinter = shell_id;

        sim_weapon_spec sp = w.specs[gun_of(&w, APEX)->spec];
        sp.life = 20;
        sp.expire_ends = 1;
        sp.splinter = shell_id;
        sim_fire_pattern fp = *gun_of(&w, APEX);
        fp.spec = (uint8_t)sim_add_spec(&w, &sp);
        w.classes[APEX].trigger[SIM_TRIG_GUN][0] = (uint8_t)sim_add_pattern(&w, &fp);

        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &w);
        step_n(&s, &w, SIM_BTN_FIRE, 0, 1);
        step_n(&s, &w, 0, 0, 21);
        CHECK(s.weapon_count == 8, "running out broke it into eight");
        for (uint16_t i = 0; i < s.weapon_count; i++) {
            CHECK(s.weapons[i].depth == 1, "each one a generation down");
        }
        /* And they do not go on doing it. Sixty-four here would be the first
         * step of a fork bomb, and the table has room for a thousand. */
        step_n(&s, &w, 0, 0, 45);
        CHECK(s.weapon_count == 0, "fragments do not fragment");
    }

    {
        /* A shove, with no damage at all: the whole of a repel. */
        sim_settings w = cfg;
        sim_weapon_spec sp;
        memset(&sp, 0, sizeof sp);
        sp.speed = 0;
        sp.life = 1;
        sp.on_wall = SIM_WALL_PASS;
        sp.expire_ends = 1;
        sp.blast = 300 * 256;
        sp.push = sim_units_speed(3000);
        sp.splinter = SIM_NO_PATTERN;
        sim_fire_pattern fp;
        memset(&fp, 0, sizeof fp);
        fp.spec = (uint8_t)sim_add_spec(&w, &sp);
        fp.count = 1;
        fp.delay = 25;
        w.classes[APEX].trigger[SIM_TRIG_GUN][0] = (uint8_t)sim_add_pattern(&w, &fp);

        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &w);
        sim_spawn(&s, APEX, 1, 8192, 8192 - 200, 0, &w);
        int32_t e1 = s.ships[1].energy;
        step_n(&s, &w, SIM_BTN_FIRE, 0, 3);
        CHECK(s.ships[1].vy < 0, "the neighbour was shoved away");
        CHECK(s.ships[1].energy >= e1, "and not hurt");

        /* But not into somebody standing in a safe zone.
         *
         * Nothing reaches a ship in one -- `apply_damage` has said so since
         * the tile existed -- and a shove is a thing reaching it. Worse than
         * damage, in fact: the zone is the one place in the arena you can
         * stop, so throwing somebody out of it at speed takes away exactly
         * what they went there for.
         *
         * Two victims, so this cannot pass by the repel having failed to go
         * off at all: the one on the safe tile keeps still and the one beside
         * it in the open is thrown. */
        sim_map *sm = malloc(sizeof *sm);
        memcpy(sm->tile, m->tile, sizeof sm->tile);
        for (int ty = 497; ty <= 501; ty++)
            for (int tx = 510; tx <= 514; tx++)
                sm->tile[(size_t)ty * SIM_MAP_TILES + (size_t)tx] = SIM_TILE_SAFE;
        sim_map_index(sm);
        w.map = sm;

        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &w);          /* the firer */
        sim_spawn(&s, APEX, 1, 8192, 8192 - 200, 0, &w);    /* on safe ground */
        sim_spawn(&s, APEX, 2, 8192 + 200, 8192, 0, &w);    /* in the open */
        CHECK(sim_in_safe(sm, s.ships[1].x, s.ships[1].y),
              "the sheltered one is actually on a safe tile");
        CHECK(!sim_in_safe(sm, s.ships[2].x, s.ships[2].y),
              "and the other is not");
        step_n(&s, &w, SIM_BTN_FIRE, 0, 3);
        CHECK(s.ships[1].vx == 0 && s.ships[1].vy == 0,
              "a repel does not move a ship in a safe zone");
        CHECK(s.ships[2].vx > 0, "and still shoves the one out in the open");
        w.map = m;
        free(sm);
    }

    {
        /* A stall round: the bar stops refilling rather than emptying. */
        sim_settings w = cfg;
        sim_weapon_spec sp = w.specs[gun_of(&w, APEX)->spec];
        sp.damage = 0;
        sp.stall = 200;
        sim_fire_pattern fp = *gun_of(&w, APEX);
        fp.spec = (uint8_t)sim_add_spec(&w, &sp);
        w.classes[APEX].trigger[SIM_TRIG_GUN][0] = (uint8_t)sim_add_pattern(&w, &fp);

        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &w);
        sim_spawn(&s, APEX, 1, 8192, 8192 - 140, 0, &w);
        step_n(&s, &w, SIM_BTN_FIRE, 0, 120);
        CHECK(s.ships[1].stall > 0, "the victim is stalled");
        /* Knocked down by hand, because the round itself takes nothing off:
         * a full bar has nowhere to recharge to and would prove nothing. */
        int32_t held = s.ships[1].energy / 2;
        s.ships[1].energy = held;
        step_n(&s, &w, 0, 0, 60);
        CHECK(s.ships[1].energy == held, "and the bar does not move");
        step_n(&s, &w, 0, 0, 300);
        CHECK(s.ships[1].stall == 0, "it wears off");
        CHECK(s.ships[1].energy > held, "and the bar fills again");
    }

    /* --- the tech tree -------------------------------------------------
     *
     * A level is the same weapon harder, a rung on the hull's ladder. An
     * add-on is a transform over that rung, applied when the shot is made.
     * Keeping them apart is the whole design: as rows, three levels against
     * six add-ons would be a hundred and ninety-two patterns per weapon. */
    {
        /* What a hull can be handed is its roster row, and nothing else. */
        uint8_t pool[SIM_PRIZE_COUNT];
        const int SPIRE = 4, LATTICE = 7;
        int n = sim_prize_pool(&cfg.classes[APEX], pool);
        int has_gun_level = 0, has_bomb_level = 0, has_multi = 0, has_shrap = 0;
        for (int i = 0; i < n; i++) {
            if (pool[i] == SIM_PRIZE_LEVEL(SIM_TRIG_GUN)) has_gun_level = 1;
            if (pool[i] == SIM_PRIZE_LEVEL(SIM_TRIG_BOMB)) has_bomb_level = 1;
            if (pool[i] == SIM_PRIZE_MOD(SIM_TRIG_GUN, SIM_MOD_MULTI)) has_multi = 1;
            if (pool[i] == SIM_PRIZE_MOD(SIM_TRIG_BOMB, SIM_MOD_SHRAPNEL)) has_shrap = 1;
        }
        CHECK(n >= SIM_UP_COUNT, "every hull can be handed every stat");
        CHECK(has_gun_level, "an Apex gun levels once, so a level is on offer");
        CHECK(!has_bomb_level, "its bomb ladder is one rung, so that is not");
        CHECK(has_multi, "multifire is universal, as it is in the original");
        CHECK(has_shrap, "and so is shrapnel, on any hull with a rack");

        /* A hull with no rack is offered no bomb add-on: an add-on is a
         * transform on a trigger, and the Spire has no bomb trigger. That,
         * rather than a list of forbidden items, is what keeps it out of the
         * bombing business. */
        n = sim_prize_pool(&cfg.classes[SPIRE], pool);
        int bomb_addon = 0;
        for (int i = 0; i < n; i++)
            if (pool[i] >= SIM_PRIZE_MOD(SIM_TRIG_BOMB, 0)
                && pool[i] < SIM_PRIZE_CHARGE(0)) bomb_addon = 1;
        CHECK(!bomb_addon, "a hull with no rack is offered no bomb add-on");

        /* The roster is ceilings now, so that is what to check it by. Two
         * bits per add-on and `GUN_ALL | M2(MULTI)` is three rungs rather
         * than two, so these also catch a row built by OR-ing over the
         * macro. */
        const int CHORD = 2, FACET = 6, WEDGE = 1;
        CHECK(sim_mod_get(cfg.classes[CHORD].mod_max[SIM_TRIG_GUN],
                          SIM_MOD_MULTI) == 2, "a Chord climbs two of multifire");
        CHECK(sim_mod_get(cfg.classes[FACET].mod_max[SIM_TRIG_GUN],
                          SIM_MOD_MULTI) == 2, "and so does a Facet");
        CHECK(sim_mod_get(cfg.classes[APEX].mod_max[SIM_TRIG_GUN],
                          SIM_MOD_MULTI) == 1, "where an Apex climbs one");
        CHECK(sim_mod_get(cfg.classes[WEDGE].mod_max[SIM_TRIG_BOMB],
                          SIM_MOD_SHRAPNEL) == 3, "a bomber holds the most shrapnel");

        n = sim_prize_pool(&cfg.classes[LATTICE], pool);
        int has_push = 0;
        for (int i = 0; i < n; i++)
            if (pool[i] == SIM_PRIZE_MOD(SIM_TRIG_BOMB, SIM_MOD_PUSH)) has_push = 1;
        CHECK(has_push, "the denial hull is the one whose bombs shove");
    }

    {
        /* A hundred greens into one Apex: everything it can hold fills to its
         * ceiling and stops, and nothing it cannot hold ever appears. Which
         * is the claim -- the roll is over the roster row, so luck cannot
         * turn one hull into another. */
        sim_settings w = cfg;
        w.rust_chance = 0;          /* rust has its own tests below */
        sim_ship sh;
        memset(&sh, 0, sizeof sh);
        uint32_t rng = 12345;
        for (int i = 0; i < 4000; i++) {
            uint8_t got = sim_take_prize(&sh, &w, &rng, NULL);
            CHECK(got != SIM_PRIZE_NONE, "a green is always something");
        }
        for (int u = 0; u < SIM_UP_COUNT; u++)
            CHECK(sh.up[u] == 8, "every stat reaches its eighth step and stops");
        CHECK(sh.level[SIM_TRIG_GUN] == 1, "the gun climbs its one rung");
        CHECK(sh.level[SIM_TRIG_BOMB] == 0, "the bomb has none to climb");
        CHECK(sim_mod_get(sh.mods[SIM_TRIG_GUN], SIM_MOD_MULTI) == 1,
              "multifire fills to the row's allowance");
        CHECK(sim_mod_get(sh.mods[SIM_TRIG_BOMB], SIM_MOD_SHRAPNEL) == 2,
              "and so does shrapnel, which every racked hull may hold");
        CHECK(sim_mod_get(sh.mods[SIM_TRIG_GUN], SIM_MOD_FREEZE) == 0,
              "while freeze, which is ours and not on its row, never arrives");
    }

    {
        /* A pilot at the ceiling is still told what they found. The count
         * does not move; the green is taken and named. */
        sim_settings w = cfg;
        w.rust_chance = 0;
        sim_ship sh;
        memset(&sh, 0, sizeof sh);
        uint32_t rng = 999;
        for (int i = 0; i < 4000; i++) sim_take_prize(&sh, &w, &rng, NULL);
        sim_ship before = sh;
        int delta = 0;
        uint8_t got = sim_take_prize(&sh, &w, &rng, &delta);
        CHECK(got != SIM_PRIZE_NONE, "a maxed pilot still gets an answer");
        CHECK(delta > 0, "still reported as an upgrade");
        CHECK(memcmp(before.up, sh.up, sizeof sh.up) == 0
              && memcmp(before.level, sh.level, sizeof sh.level) == 0
              && memcmp(before.mods, sh.mods, sizeof sh.mods) == 0
              && memcmp(before.charge, sh.charge, sizeof sh.charge) == 0,
              "and no count moves");
        /* But they are worth more for having taken it. A pilot at every
         * ceiling who keeps hoovering keeps becoming a target. */
        CHECK(sim_bounty(&sh) == sim_bounty(&before) + 1,
              "while still being worth one more");
    }

    {
        /* And the same green in two places gives the same answer, because
         * the roll runs off the state's own generator. */
        sim_ship a, b;
        memset(&a, 0, sizeof a);
        memset(&b, 0, sizeof b);
        uint32_t ra = 7, rb = 7;
        for (int i = 0; i < 50; i++) {
            CHECK(sim_take_prize(&a, &cfg, &ra, NULL)
                  == sim_take_prize(&b, &cfg, &rb, NULL),
                  "the roll is the same roll on both machines");
        }
        CHECK(memcmp(&a, &b, sizeof a) == 0, "and lands in the same place");
    }

    {
        /* Weights decide what a green usually is, read against the pool of
         * whoever took it. Ten thousand greens into a pilot who is reset
         * between each, so nothing fills up and skews the counting. */
        sim_settings w = cfg;
        w.rust_chance = 0;
        uint32_t rng = 4242;
        int stats = 0, levels = 0, mods = 0, charges = 0;
        for (int i = 0; i < 10000; i++) {
            sim_ship sh;
            memset(&sh, 0, sizeof sh);
            uint8_t got = sim_take_prize(&sh, &w, &rng, NULL);
            if (got < SIM_UP_COUNT) stats++;
            else if (got < SIM_UP_COUNT + SIM_TRIG_COUNT) levels++;
            else if (got < SIM_PRIZE_CHARGE(0)) mods++;
            else charges++;
        }
        /* On the original's table an Apex's pool is five stats at 40, a gun
         * level at 25, four add-ons at 110 between them, and both charges at
         * 70: 475 in total. So a green is a stat a little over four times in
         * ten, a charge three, an add-on two, and a level about one in
         * twenty. Bands rather than exact numbers, because the point under
         * test is the shape of the tree and not the generator. */
        CHECK(stats > 3950 && stats < 4500, "stats are the bread of the tree");
        CHECK(levels > 420 && levels < 660, "a level is the rare one");
        CHECK(mods > 2100 && mods < 2550, "an add-on is ordinary now");
        CHECK(charges > 2700 && charges < 3200, "and a charge is common");

        /* And a zone that says otherwise gets otherwise. */
        for (int i = 0; i < SIM_UP_COUNT; i++) w.prize_weight[i] = 0;
        int only_level = 1;
        for (int i = 0; i < 500; i++) {
            sim_ship sh;
            memset(&sh, 0, sizeof sh);
            if (sim_take_prize(&sh, &w, &rng, NULL) < SIM_UP_COUNT)
                only_level = 0;
        }
        CHECK(only_level, "zeroing the stats takes them out of the roll");
    }

    {
        /* A ship starts loaded. Thirty greens, rolled the way a green on the
         * floor is rolled, so what a pilot opens with respects the hull's
         * roster and every ceiling in it. */
        sim_settings w = cfg;
        w.spawn_prizes = 30;
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &w);
        const sim_ship *sh = &s.ships[0];

        int held_count = 0;
        for (int u = 0; u < SIM_UP_COUNT; u++) held_count += sh->up[u];
        for (int t = 0; t < SIM_TRIG_COUNT; t++) {
            held_count += sh->level[t];
            for (int mo = 0; mo < SIM_MOD_COUNT; mo++)
                held_count += sim_mod_get(sh->mods[t], mo);
        }
        for (int k = 0; k < SIM_MAX_CHARGES; k++) held_count += sh->charge[k];

        /* Not exactly thirty: a green that lands on something already at its
         * ceiling is taken and named without moving a count, and one in a
         * hundred rusts. The claim is that a spawn is loaded, not that it is
         * loaded to a number. */
        CHECK(held_count > 18, "a ship spawns carrying most of thirty greens");
        CHECK(held_count <= 30, "and never more than it was handed");
        CHECK(sim_bounty(sh) >= held_count, "which is what it is worth");

        /* The roster still holds. An Apex has no bomb ladder and freeze is
         * not on its row, however the thirty fall. */
        CHECK(sh->level[SIM_TRIG_BOMB] == 0, "a hull cannot be handed a rung it lacks");
        CHECK(sim_mod_get(sh->mods[SIM_TRIG_GUN], SIM_MOD_FREEZE) == 0,
              "nor an add-on that is not on its row");

        /* And the bar is filled after the prizes land, not before: a spawn
         * that rolled energy steps must open at the ceiling it just earned,
         * not at the one it would have had empty. */
        CHECK(s.ships[0].energy == sim_eff_max_energy(&w.classes[APEX], sh),
              "the bar opens full at the ceiling the greens just bought");

        /* Two ships spawned from one state differ, because the roll runs off
         * the state's own generator rather than a fixed seed per ship. */
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &w);
        CHECK(memcmp(&s.ships[0].up, &s.ships[1].up, sizeof s.ships[0].up) != 0
              || s.ships[0].mods[SIM_TRIG_GUN] != s.ships[1].mods[SIM_TRIG_GUN]
              || memcmp(&s.ships[0].charge, &s.ships[1].charge,
                        sizeof s.ships[0].charge) != 0,
              "and two spawns are not the same spawn");

        /* A zone that wants pilots to earn it says so, and gets a plain ship. */
        w.spawn_prizes = 0;
        sim_state t;
        sim_init(&t, 1);
        sim_spawn(&t, APEX, 0, 8192, 8192, 0, &w);
        CHECK(sim_bounty(&t.ships[0]) == 0, "zero spawn prizes is a plain ship");

        /* A respawn is a spawn: dying strips everything and the next life is
         * outfitted again, or the setting would only apply to the first. */
        w.spawn_prizes = 30;
        sim_init(&t, 1);
        sim_spawn(&t, APEX, 0, 8192, 8192, 0, &w);
        t.ships[0].alive = 0;
        t.ships[0].respawn_at = 1;
        memset(t.ships[0].up, 0, sizeof t.ships[0].up);
        memset(t.ships[0].level, 0, sizeof t.ships[0].level);
        memset(t.ships[0].mods, 0, sizeof t.ships[0].mods);
        memset(t.ships[0].charge, 0, sizeof t.ships[0].charge);
        t.ships[0].earned = 0;
        step_n(&t, &w, 0, 0, 1);
        CHECK(t.ships[0].alive, "the respawn happened");
        CHECK(sim_bounty(&t.ships[0]) > 0, "and it came back loaded");
    }

    {
        /* Rust takes something back, and only something you are holding. */
        sim_settings w = cfg;
        w.rust_chance = 1000;      /* every green, so the test is not a lottery */
        sim_ship sh;
        memset(&sh, 0, sizeof sh);
        uint32_t rng = 31337;

        /* A pilot who has just arrived holds nothing, so there is nothing to
         * corrode and the green is an ordinary one. */
        int delta = 0;
        uint8_t got = sim_take_prize(&sh, &w, &rng, &delta);
        CHECK(delta > 0, "an empty pilot cannot be rusted");
        CHECK(held_of(&sh, got) == 1, "and is given the thing instead");

        /* Load one up and it goes the other way. */
        sh.up[SIM_UP_SPEED] = 4;
        sh.up[SIM_UP_THRUST] = 2;
        int before = sh.up[SIM_UP_SPEED] + sh.up[SIM_UP_THRUST];
        got = sim_take_prize(&sh, &w, &rng, &delta);
        CHECK(delta < 0, "a loaded pilot is");
        CHECK(got == SIM_UP_SPEED || got == SIM_UP_THRUST,
              "and what corrodes is something they had");
        CHECK(sh.up[SIM_UP_SPEED] + sh.up[SIM_UP_THRUST] == before - 1,
              "one step of it");

        /* It never goes below nothing, and never leaves the pilot in a state
         * the hull could not have reached. */
        for (int i = 0; i < 200; i++) sim_take_prize(&sh, &w, &rng, &delta);
        for (int u = 0; u < SIM_UP_COUNT; u++)
            CHECK(sh.up[u] == 0, "and rust stops at empty");
    }

    {
        /* Losing an energy step clamps the bar down to the new ceiling rather
         * than leaving a pilot over it. */
        sim_settings w = cfg;
        w.rust_chance = 1000;
        for (int i = 0; i < SIM_PRIZE_COUNT; i++) w.prize_weight[i] = 0;
        sim_state s;
        sim_init(&s, 3);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &w);
        s.ships[0].up[SIM_UP_ENERGY] = 6;
        s.ships[0].energy = sim_eff_max_energy(&w.classes[APEX], &s.ships[0]);
        int32_t full = s.ships[0].energy;
        step_n(&s, &w, 0, 0, w.prize_delay + 2);
        int idx = -1;
        for (int i = 0; i < SIM_MAX_PRIZES; i++)
            if (s.prizes[i].active) { idx = i; break; }
        CHECK(idx >= 0, "a prize appears");
        s.ships[0].x = s.prizes[idx].x;
        s.ships[0].y = s.prizes[idx].y;
        step_n(&s, &w, 0, 0, 2);
        CHECK(s.ships[0].energy <= sim_eff_max_energy(&w.classes[APEX], &s.ships[0]),
              "the bar is never above the ceiling it now has");
        CHECK(s.ships[0].energy < full || s.ships[0].up[SIM_UP_ENERGY] == 6,
              "and it came down if the ceiling did");
    }

    {
        /* Multifire composes onto whatever rung the trigger is on, and it is
         * the one add-on that changes what pulling the trigger costs. The
         * original charged 20 energy for a bullet and 30 for multifire, and
         * waited 25 ticks against 50: half again the energy and twice the
         * cooldown for three rounds.
         *
         * Most of the price is in the rate, which is the half a pilot cannot
         * out-recharge. */
        uint16_t plain_wait = 0, multi_wait = 0;
        int32_t plain = gun_cost(&cfg, (uint8_t)APEX, 0, &plain_wait);
        int32_t multi = gun_cost(&cfg, (uint8_t)APEX,
                                 sim_mod_set(0, SIM_MOD_MULTI, 1), &multi_wait);
        CHECK(multi == plain * 3 / 2, "multifire costs half again the energy");
        CHECK(multi_wait == plain_wait * 2, "and twice the wait");

        /* A second rung is a second helping of both, because every other
         * add-on here is linear in its rung and this one has no reason not
         * to be. */
        uint16_t two_wait = 0;
        int32_t two = gun_cost(&cfg, (uint8_t)APEX,
                               sim_mod_set(0, SIM_MOD_MULTI, 2), &two_wait);
        CHECK(two == plain * 2, "two rungs, twice the energy");
        CHECK(two_wait == plain_wait * 3, "and three times the wait");

        /* And it is still a fan of barrels, which is what you paid for. */
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        s.ships[0].mods[SIM_TRIG_GUN] = sim_mod_set(0, SIM_MOD_MULTI, 1);
        step_n(&s, &cfg, SIM_BTN_FIRE, 0, 1);
        CHECK(s.weapon_count == 1 + cfg.mod_step[SIM_MOD_MULTI],
              "a rung of multifire is a pair of extra barrels");
        CHECK(s.weapons[0].vx != s.weapons[1].vx, "and they fan out");
    }

    {
        /* Climbing a rung swaps which pattern the trigger fires, and the one
         * above hits harder. */
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        const sim_ship_class *c = &cfg.classes[APEX];
        int32_t l1 = cfg.specs[cfg.patterns[c->trigger[SIM_TRIG_GUN][0]].spec].damage;
        int32_t l2 = cfg.specs[cfg.patterns[c->trigger[SIM_TRIG_GUN][1]].spec].damage;
        CHECK(l2 > l1, "the rung above hits harder");
        s.ships[0].level[SIM_TRIG_GUN] = 1;
        step_n(&s, &cfg, SIM_BTN_FIRE, 0, 1);
        CHECK(s.weapon_count == 1, "fired");
        CHECK(cfg.specs[s.weapons[0].spec].damage == l2,
              "and what left the ship is the rung it is on");
    }

    {
        /* A shot is what it was when it left. The add-ons ride on the
         * projectile, so losing them does not reach back and disarm what is
         * already in the air. */
        sim_settings w = cfg;
        w.classes[APEX].mod_max[SIM_TRIG_GUN] =
            sim_mod_set(0, SIM_MOD_BOUNCE, 1);
        sim_state s;
        sim_init(&s, 1);
        /* Two tiles under the wall: a round travels 2 px a tick, so a
         * distant wall would outlast the flight. */
        sim_spawn(&s, APEX, 0, 8192, 40, 0, &w);
        s.ships[0].mods[SIM_TRIG_GUN] = sim_mod_set(0, SIM_MOD_BOUNCE, 1);
        step_n(&s, &w, SIM_BTN_FIRE, 0, 1);
        CHECK(s.weapon_count == 1, "fired");
        CHECK(s.weapons[0].mods == s.ships[0].mods[SIM_TRIG_GUN],
              "the shot carries what fired it");
        CHECK(s.weapons[0].left > 0, "with a bounce on it");
        s.ships[0].mods[SIM_TRIG_GUN] = 0;
        step_n(&s, &w, 0, 0, 60);
        CHECK(s.weapon_count == 1, "and the wall did not end it");
        CHECK(s.weapons[0].vy > 0, "it came back down");
    }

    {
        /* Shrapnel is the one add-on whose magnitude is another weapon, and
         * fragments do not inherit it: a shell that broke into eight would
         * otherwise have each of those break into eight again. */
        const int WEDGE = 1;
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, WEDGE, 0, 8192, 300, 0, &cfg);
        s.ships[0].mods[SIM_TRIG_BOMB] = sim_mod_set(0, SIM_MOD_SHRAPNEL, 1);
        step_n(&s, &cfg, SIM_BTN_BOMB, 0, 1);
        CHECK(s.weapon_count == 1, "one bomb away");
        step_n(&s, &cfg, 0, 0, 200);
        CHECK(s.weapon_count > 1, "the wall broke it up");
        for (uint16_t i = 0; i < s.weapon_count; i++)
            CHECK(s.weapons[i].mods == 0, "and the fragments carry nothing");
    }

    {
        /* A charge: a weapon you carry a count of and spend. The Lattice
         * carries repels, which are `push` with no damage at all -- the
         * shape the weapon model has been able to express since it was
         * written, now with an inventory in front of it. */
        const int LATTICE = 7;
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, LATTICE, 0, 8192, 8192, 0, &cfg);
        sim_spawn(&s, APEX, 1, 8192, 8192 - 120, 0, &cfg);
        s.ships[0].charge[0] = 2;
        int32_t vy0 = s.ships[1].vy, e1 = s.ships[1].energy;

        /* The slot rides in the buttons rather than on the ship: choosing
         * which charge is ready is the client's business. */
        uint16_t use = SIM_BTN_USE | (0u << SIM_BTN_SLOT_SHIFT);
        ev_counts c = step_counting(&s, &cfg, use, 0, 3);
        CHECK(s.ships[0].charge[0] == 1, "one repel is spent");
        CHECK(s.ships[1].vy < vy0, "the neighbour is shoved away");
        CHECK(s.ships[1].energy >= e1, "and not hurt");
        CHECK(c.fires > 0, "and it counts as a shot");

        /* The cooldown holds, then it fires the last one and stops. */
        step_n(&s, &cfg, use, 0, 200);
        CHECK(s.ships[0].charge[0] == 0, "the second is spent too");
        step_n(&s, &cfg, use, 0, 400);
        CHECK(s.ships[0].charge[0] == 0, "and an empty slot fires nothing");
    }

    {
        /* A hull carries what its row allows, and a slot the zone never
         * filled is not a slot.
         *
         * The shipped roster gives every hull three of each charge, which is
         * the original's rule -- RepelMax through RocketMax are 3 on all
         * eight of its ships. So the gate is tested by closing one rather
         * than by finding a hull that happens to be shut. */
        uint8_t pool[SIM_PRIZE_COUNT];
        const int LATTICE = 7;
        int n = sim_prize_pool(&cfg.classes[LATTICE], pool);
        int repel = 0, burst = 0, empty_slot = 0;
        for (int i = 0; i < n; i++) {
            if (pool[i] == SIM_PRIZE_CHARGE(0)) repel = 1;
            if (pool[i] == SIM_PRIZE_CHARGE(1)) burst = 1;
            if (pool[i] == SIM_PRIZE_CHARGE(2)
                || pool[i] == SIM_PRIZE_CHARGE(3)) empty_slot = 1;
        }
        CHECK(repel && burst, "a hull is offered both charges the zone filled");
        CHECK(!empty_slot, "and never a slot the zone left empty");

        /* Close one on the hull and it leaves that hull's pool. */
        sim_settings w = cfg;
        w.rust_chance = 0;
        w.classes[LATTICE].charge_max[1] = 0;
        n = sim_prize_pool(&w.classes[LATTICE], pool);
        burst = 0;
        for (int i = 0; i < n; i++)
            if (pool[i] == SIM_PRIZE_CHARGE(1)) burst = 1;
        CHECK(!burst, "a hull with no room for a burst is not offered one");

        sim_ship sh;
        memset(&sh, 0, sizeof sh);
        sh.cls = LATTICE;
        uint32_t rng = 77;
        for (int i = 0; i < 4000; i++) sim_take_prize(&sh, &w, &rng, NULL);
        CHECK(sh.charge[1] == 0, "and never picks one up however lucky");
        CHECK(sh.charge[0] == cfg.classes[LATTICE].charge_max[0],
              "while the one it may hold fills to the row and stops");
    }

    {
        /* A shot outlives its owner, whole.
         *
         * The rung is baked into the projectile's `spec` at the moment it is
         * fired -- a level-two bullet was spawned from the level-two pattern
         * -- exactly as the add-ons are baked into its `mods`. So the
         * inventory a death clears is what gates *firing*, and nothing that
         * is already in the air reads it. */
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        sim_spawn(&s, APEX, 1, 8192, 8192 - 300, 0, &cfg);
        const sim_ship_class *c = &cfg.classes[APEX];
        int32_t l1 = cfg.specs[cfg.patterns[c->trigger[SIM_TRIG_GUN][0]].spec].damage;
        int32_t l2 = cfg.specs[cfg.patterns[c->trigger[SIM_TRIG_GUN][1]].spec].damage;

        s.ships[0].level[SIM_TRIG_GUN] = 1;
        s.ships[0].mods[SIM_TRIG_GUN] = sim_mod_set(0, SIM_MOD_MULTI, 1);
        step_n(&s, &cfg, SIM_BTN_FIRE, 0, 1);
        CHECK(s.weapon_count == 3, "a levelled, multifired shot leaves");
        uint8_t spec = s.weapons[0].spec;
        uint16_t mods = s.weapons[0].mods;
        CHECK(cfg.specs[spec].damage == l2 && l2 > l1,
              "and it is the harder round");

        /* Kill the owner outright and strip them, exactly as a death does. */
        s.ships[0].alive = 0;
        s.ships[0].respawn_at = 3000;
        memset(s.ships[0].up, 0, sizeof s.ships[0].up);
        memset(s.ships[0].level, 0, sizeof s.ships[0].level);
        memset(s.ships[0].mods, 0, sizeof s.ships[0].mods);
        memset(s.ships[0].charge, 0, sizeof s.ships[0].charge);

        step_n(&s, &cfg, 0, 0, 1);
        CHECK(s.weapon_count == 3, "the shots are still in the air");
        CHECK(s.weapons[0].spec == spec, "carrying the rung they left on");
        CHECK(s.weapons[0].mods == mods, "and the add-ons they left with");

        /* Read off the hit event rather than the bar: recharge erases the
         * evidence within a second, which is why every damage test here
         * counts events. */
        int32_t worst = 0;
        for (int t = 0; t < 200; t++) {
            sim_state tmp;
            sim_events ev;
            sim_input in[2] = {{0, 0}, {1, 0}};
            sim_step(&tmp, &s, in, 2, &cfg, &ev);
            s = tmp;
            for (uint16_t e = 0; e < ev.count; e++)
                if (ev.e[e].type == SIM_EV_HIT && ev.e[e].v > worst)
                    worst = ev.e[e].v;
        }
        CHECK(worst == l2, "a dead pilot's shot lands for what it was worth");
    }

    {
        /* And the same for a charge, which is the case where the inventory
         * really is gone: the burst is spent at the trigger, and the sixteen
         * rounds it made are ordinary projectiles from that moment on. */
        const int CIPHER = 5;
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, CIPHER, 0, 8192, 8192, 0, &cfg);
        /* Close, and for two reasons. A burst round lives 70 ticks at 1.8 px
         * a tick, so the ring reaches about 126 px. And sixteen is an even
         * count, which straddles the heading rather than putting one down the
         * middle -- the two nearest rounds leave at eleven degrees, so a
         * target far enough away is missed on both sides. */
        sim_spawn(&s, APEX, 1, 8192, 8192 - 60, 0, &cfg);
        s.ships[0].charge[1] = 1;
        step_n(&s, &cfg, SIM_BTN_USE | (1u << SIM_BTN_SLOT_SHIFT), 0, 1);
        CHECK(s.weapon_count == 16, "a burst is sixteen rounds");
        CHECK(s.ships[0].charge[1] == 0, "and the charge is spent");

        s.ships[0].alive = 0;
        s.ships[0].respawn_at = 3000;
        memset(s.ships[0].charge, 0, sizeof s.ships[0].charge);
        int32_t e0 = s.ships[1].energy;
        ev_counts ec = step_counting(&s, &cfg, 0, 0, 120);
        CHECK(ec.hits > 0, "the ring still reaches whoever was standing there");
        CHECK(s.ships[1].energy < e0, "and still hurts");
    }

    {
        /* Dying costs the tree as well as the stats. */
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        sim_spawn(&s, APEX, 1, 8192, 8192 - 200, 32768, &cfg);
        s.ships[0].level[SIM_TRIG_GUN] = 1;
        s.ships[0].mods[SIM_TRIG_GUN] = sim_mod_set(0, SIM_MOD_MULTI, 1);
        s.ships[0].up[SIM_UP_SPEED] = 3;
        s.ships[0].energy = 1;
        step_counting(&s, &cfg, 0, SIM_BTN_FIRE, 400);
        CHECK(s.ships[0].deaths > 0, "the target dies");
        CHECK(s.ships[0].level[SIM_TRIG_GUN] == 0, "and loses the rung");
        CHECK(s.ships[0].mods[SIM_TRIG_GUN] == 0, "and the add-ons");
        CHECK(s.ships[0].up[SIM_UP_SPEED] == 0, "and the stats, as before");
    }

    /* --- bounty and points ----------------------------------------------
     *
     * Bounty is what you are worth and points are what you have been paid,
     * and they are different numbers. Bounty is derived from what a pilot is
     * holding rather than stored, which is what keeps it honest: rust lowers
     * it, a green at the ceiling does not raise it, and death resets it
     * without a line of code in any of those places. */
    {
        sim_ship sh;
        memset(&sh, 0, sizeof sh);
        CHECK(sim_bounty(&sh) == 0, "a fresh pilot is worth nothing");
        sh.up[SIM_UP_SPEED] = 3;
        sh.level[SIM_TRIG_GUN] = 1;
        sh.mods[SIM_TRIG_GUN] = sim_mod_set(0, SIM_MOD_MULTI, 2);
        sh.charge[1] = 4;
        CHECK(sim_bounty(&sh) == 10, "and otherwise worth what it holds");
        sh.earned = 6;
        CHECK(sim_bounty(&sh) == 16, "plus what killing has earned");
    }

    {
        /* Every green raises it by exactly one, and rust lowers it. Which is
         * not a rule anybody wrote: it falls out of the sum. */
        sim_settings w = cfg;
        w.rust_chance = 0;
        sim_ship sh;
        memset(&sh, 0, sizeof sh);
        uint32_t rng = 4;
        for (int i = 1; i <= 12; i++) {
            sim_take_prize(&sh, &w, &rng, NULL);
            CHECK(sim_bounty(&sh) == i, "a green is worth one bounty");
        }
        w.rust_chance = 1000;
        int before = sim_bounty(&sh);
        sim_take_prize(&sh, &w, &rng, NULL);
        CHECK(sim_bounty(&sh) == before - 1, "and rust takes one back");

        /* And it keeps being one a green, long past every ceiling: four
         * hundred of them is four hundred bounty, whatever the hull could
         * actually absorb. */
        w.rust_chance = 0;
        before = sim_bounty(&sh);
        for (int i = 0; i < 400; i++) sim_take_prize(&sh, &w, &rng, NULL);
        CHECK(sim_bounty(&sh) == before + 400,
              "a ceiling stops the upgrade, not the price");
    }

    {
        /* A kill pays the victim's bounty, and nothing at all for a pilot
         * who was carrying nothing. Camping a respawn is worthless without
         * an anti-farming rule, because a fresh spawn is worth zero. */
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 32768, &cfg);      /* faces down */
        sim_spawn(&s, APEX, 1, 8192, 8192 + 200, 0, &cfg);    /* the victim */
        s.ships[1].energy = 1;
        step_counting(&s, &cfg, SIM_BTN_FIRE, 0, 400);
        CHECK(s.ships[1].deaths > 0, "the empty pilot dies");
        CHECK(s.ships[0].kills == 1, "and it counts as a kill");
        CHECK(s.ships[0].points == 0, "worth nothing to whoever did it");
        CHECK(sim_bounty(&s.ships[0]) == (int32_t)cfg.bounty_per_kill,
              "though the killer is a little more dangerous for it");

        /* Load the victim up and the same kill pays. */
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 32768, &cfg);
        sim_spawn(&s, APEX, 1, 8192, 8192 + 200, 0, &cfg);
        s.ships[1].up[SIM_UP_SPEED] = 5;
        s.ships[1].up[SIM_UP_THRUST] = 4;
        int32_t worth = sim_bounty(&s.ships[1]);
        CHECK(worth == 9, "a loaded pilot is worth what they carry");
        s.ships[1].energy = 1;
        step_counting(&s, &cfg, SIM_BTN_FIRE, 0, 400);
        CHECK(s.ships[1].deaths > 0, "they die too");
        CHECK(s.ships[0].points == (uint32_t)worth,
              "and the killer is paid exactly what they were worth");
        CHECK(sim_bounty(&s.ships[1]) == 0, "the dead are worth nothing again");
    }

    {
        /* Points are the score and survive dying; bounty is the price and
         * does not. */
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 32768, &cfg);
        sim_spawn(&s, APEX, 1, 8192, 8192 + 200, 0, &cfg);
        s.ships[0].points = 500;
        s.ships[0].earned = 12;
        s.ships[0].up[SIM_UP_SPEED] = 2;
        s.ships[0].energy = 1;
        step_counting(&s, &cfg, 0, SIM_BTN_FIRE, 400);
        CHECK(s.ships[0].deaths > 0, "the scorer dies");
        CHECK(s.ships[0].points == 500, "and keeps every point they were paid");
        CHECK(sim_bounty(&s.ships[0]) == 0, "while their price goes to nothing");
    }

    {
        /* A teammate's death pays neither points nor bounty, which is the
         * rule the rating layer already applies to teammate damage.
         *
         * A weapon never arrives at a teammate, so the only way to kill one
         * is a blast -- which does not check teams, and is exactly why the
         * rule has to exist. */
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, ANVIL, 0, 8192, 120, 0, &cfg);        /* faces the wall */
        sim_spawn(&s, APEX, 0, 8192, 55, 0, &cfg);          /* same team, near it */
        s.ships[1].up[SIM_UP_SPEED] = 6;
        s.ships[1].energy = 1;
        ev_counts c = step_counting(&s, &cfg, SIM_BTN_BOMB, 0, 200);
        CHECK(c.deaths > 0, "the bomb's blast kills the teammate");
        CHECK(s.ships[1].deaths == 1, "and it is the teammate who died");
        CHECK(s.ships[0].points == 0, "a teamkill pays no points");
        CHECK(s.ships[0].earned == 0, "and no bounty");
    }

    {
        /* Flags a victim was carrying are worth extra, on top of what they
         * were carrying in upgrades. */
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 32768, &cfg);
        sim_spawn(&s, APEX, 1, 8192, 8192 + 200, 0, &cfg);
        sim_add_flag(&s, 100, 100);
        sim_add_flag(&s, 200, 200);
        for (int f = 0; f < 2; f++) {
            s.flags[f].carried = 1;
            s.flags[f].carrier = 1;
        }
        s.ships[1].up[SIM_UP_ENERGY] = 2;
        int32_t worth = sim_bounty(&s.ships[1]);
        s.ships[1].energy = 1;
        step_counting(&s, &cfg, SIM_BTN_FIRE, 0, 400);
        CHECK(s.ships[1].deaths > 0, "the carrier dies");
        CHECK(s.ships[0].points == (uint32_t)(worth + 2 * cfg.points_per_flag),
              "and the flags they held are worth extra");
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
        /* A green carries no type, so what it turns out to be is whatever
         * the roll says. Start the pilot one step below every ceiling and
         * something has to move. */
        for (int u = 0; u < SIM_UP_COUNT; u++) s.ships[0].up[u] = 7;
        sim_ship before = s.ships[0];
        s.ships[0].x = s.prizes[idx].x;
        s.ships[0].y = s.prizes[idx].y;
        ev_counts c = step_counting(&s, &cfg, 0, 0, 2);
        CHECK(c.prizes > 0, "flying over a prize collects it");
        CHECK(!s.prizes[idx].active, "and takes it off the map");
        CHECK(memcmp(&before.up, &s.ships[0].up, sizeof before.up) != 0
              || before.level[SIM_TRIG_GUN] != s.ships[0].level[SIM_TRIG_GUN]
              || before.mods[SIM_TRIG_GUN] != s.ships[0].mods[SIM_TRIG_GUN]
              || memcmp(&before.charge, &s.ships[0].charge, sizeof before.charge) != 0,
              "and something the pilot holds went up");

        /* Dying strips everything. */
        s.ships[0].up[SIM_UP_SPEED] = 4;
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

        /* With a prize field on it, because prizes are most of a snapshot
         * and their position is the one thing on the wire that is not stored
         * the way it is sent -- two tile indices out, two Q8 pixel
         * coordinates back. A round trip over an empty field would prove
         * nothing about the part most likely to be wrong. */
        int live = 0;
        for (int i = 0; i < SIM_MAX_PRIZES; i++) live += s.prizes[i].active;
        CHECK(live > 20, "the state under test carries a prize field");

        static uint8_t buf[SIM_PACK_MAX];
        int n = sim_pack(&s, buf, sizeof buf);
        CHECK(n > 0, "a snapshot packs");
        CHECK(sim_unpack(&back, buf, n) == 0, "a snapshot unpacks");
        CHECK(sim_hash(&back) == sim_hash(&s), "the round trip is exact");
        CHECK(memcmp(back.prizes, s.prizes, sizeof s.prizes) == 0,
              "every prize comes back at the pixel it went out on");

        /* And an unpacked state steps identically to the original, which is
         * the property client prediction actually depends on. */
        sim_state a2, b2;
        sim_input in = {0, SIM_BTN_THRUST};
        sim_step(&a2, &s, &in, 1, &cfg, NULL);
        sim_step(&b2, &back, &in, 1, &cfg, NULL);
        CHECK(sim_hash(&a2) == sim_hash(&b2), "an unpacked state steps identically");

        /* And a snapshot packed around a point carries the prizes near it
         * and none of the far ones -- which is the claim the wire saving
         * rests on. The near ones still arrive at the pixel they left. */
        {
            int32_t cx = s.ships[0].x, cy = s.ships[0].y;
            /* Two hundred tiles rather than the radar's sixty. This state
             * holds about forty-five prizes spread over a thousand tiles
             * square, so a sixty-tile circle catches none of them and the
             * test would be asserting over an empty set. The radius under
             * test is the filter, not the number the server picks. */
            const int32_t R = 200 * 16 * 256;
            int near = 0, far = 0;
            for (int i = 0; i < SIM_MAX_PRIZES; i++) {
                if (!s.prizes[i].active) continue;
                int64_t dx = (int64_t)s.prizes[i].x - cx;
                int64_t dy = (int64_t)s.prizes[i].y - cy;
                if (dx * dx + dy * dy <= (int64_t)R * R) near++; else far++;
            }
            CHECK(near > 0 && far > 0, "the field straddles the radius");

            int m = sim_pack_around(&s, buf, sizeof buf, cx, cy, R);
            CHECK(m > 0 && m < n, "a filtered snapshot is smaller");
            sim_state cut;
            CHECK(sim_unpack(&cut, buf, m) == 0, "and unpacks");

            int got = 0;
            for (int i = 0; i < SIM_MAX_PRIZES; i++) {
                if (!cut.prizes[i].active) continue;
                got++;
                CHECK(cut.prizes[i].x == s.prizes[i].x
                      && cut.prizes[i].y == s.prizes[i].y
                      && cut.prizes[i].life == s.prizes[i].life,
                      "a prize that was sent is unchanged");
                int64_t dx = (int64_t)cut.prizes[i].x - cx;
                int64_t dy = (int64_t)cut.prizes[i].y - cy;
                CHECK(dx * dx + dy * dy <= (int64_t)R * R,
                      "and nothing outside the radius was sent");
            }
            CHECK(got == near, "every prize inside the radius was sent");

            /* Everything that is not a prize still travels whole: a client
             * that was not told about a ship could not name it. */
            CHECK(cut.ship_count == s.ship_count, "every ship still travels");
            CHECK(cut.weapon_count == s.weapon_count, "and every projectile");
            CHECK(cut.flag_count == s.flag_count, "and every flag");
        }

        CHECK(sim_pack(&s, buf, 8) == -1, "packing reports an undersized buffer");
        CHECK(sim_unpack(&back, buf, 3) == -1, "unpacking rejects a truncated snapshot");
    }

    /* Settings travel too, and the test that matters is not that the fields
     * survive but that a fresh core given them steps the same way. A client
     * compiles its own baseline; that is only ever a starting guess. */
    {
        /* A zone that has tuned something and added a weapon nobody else
         * has: the case where compiling the same defaults is not enough. */
        sim_settings zone = cfg;
        zone.bounce = 16;
        zone.classes[APEX].max_speed = sim_units_speed(6000);
        sim_weapon_spec sp = *gun_spec(&zone, APEX);
        sp.on_wall = SIM_WALL_BOUNCE;
        sp.bounces = 2;
        sim_fire_pattern fp = *gun_of(&zone, APEX);
        fp.spec = (uint8_t)sim_add_spec(&zone, &sp);
        fp.count = 3;
        fp.spacing = 65536 / 24;
        zone.classes[APEX].trigger[SIM_TRIG_GUN][0] = (uint8_t)sim_add_pattern(&zone, &fp);

        static uint8_t buf[SIM_SETTINGS_PACK_MAX];
        int n = sim_settings_pack(&zone, buf, sizeof buf);
        CHECK(n > 0, "settings pack");
        CHECK(n < SIM_SETTINGS_PACK_MAX, "and fit in the buffer they claim to");

        /* The receiving end is a client: baseline settings, and a map it
         * already had. Unpacking must not disturb the geometry. */
        sim_settings got;
        memset(&got, 0, sizeof got);
        sim_settings_baseline(&got, m);
        CHECK(sim_settings_unpack(&got, buf, n) == 0, "settings unpack");
        CHECK(got.map == m, "and leave the map alone");

        sim_state s1, s2;
        sim_init(&s1, 7);
        sim_init(&s2, 7);
        sim_spawn(&s1, APEX, 0, 8192, 300, 0, &zone);
        sim_spawn(&s2, APEX, 0, 8192, 300, 0, &got);
        step_n(&s1, &zone, SIM_BTN_THRUST | SIM_BTN_FIRE, 0, 200);
        step_n(&s2, &got, SIM_BTN_THRUST | SIM_BTN_FIRE, 0, 200);
        CHECK(sim_hash(&s1) == sim_hash(&s2),
              "and the two ends step to the same state");
        /* Which is a claim about the zone's numbers, not about any numbers:
         * the same run on the baseline must reach somewhere else, or the
         * test would pass with the message thrown away. */
        sim_state s3;
        sim_init(&s3, 7);
        sim_spawn(&s3, APEX, 0, 8192, 300, 0, &cfg);
        step_n(&s3, &cfg, SIM_BTN_THRUST | SIM_BTN_FIRE, 0, 200);
        CHECK(sim_hash(&s3) != sim_hash(&s1),
              "where a client on its own defaults would not have");

        CHECK(sim_settings_pack(&zone, buf, 8) == -1,
              "packing reports an undersized buffer");
        CHECK(sim_settings_unpack(&got, buf, 3) == -1,
              "unpacking rejects a truncated message");
        buf[0] ^= 0xff;
        CHECK(sim_settings_unpack(&got, buf, n) == -1,
              "and something that is not settings at all");
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
