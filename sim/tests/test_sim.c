/* Unit tests for the sim core. Exit 0 on pass, 1 on first failure. */
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sim/sim.h"
#include "sim/baseline.h"
#include "sim/pack.h"

/* The core's own sine table, for the one test that rebuilds the collision
 * box outside the core to check the core never leaves it inside a wall. */
#include "../src/sintab.h"

static int failures = 0;
#define CHECK(cond, msg)                                          \
    do {                                                          \
        if (!(cond)) {                                            \
            printf("FAIL %s (%s:%d)\n", msg, __FILE__, __LINE__); \
            failures++;                                           \
        }                                                         \
    } while (0)

static int32_t tile_center(int32_t t) {
    return (t * SIM_TILE_PX + SIM_TILE_PX / 2) * 256;
}

static uint32_t next_random(uint32_t *state) {
    *state ^= *state << 13;
    *state ^= *state >> 17;
    *state ^= *state << 5;
    return *state;
}

static void check_state_invariants(const sim_state *s, const sim_settings *cfg) {
    CHECK(s->ship_count <= sim_eff_max_ships(cfg), "ship count stays in bounds");
    CHECK(s->weapon_count <= SIM_MAX_WEAPONS, "weapon count stays in bounds");
    CHECK(s->flag_count <= SIM_MAX_FLAGS, "flag count stays in bounds");

    for (int i = 0; i < s->ship_count; i++) {
        const sim_ship *sh = &s->ships[i];
        if (!sh->active) continue;
        CHECK(sh->cls < cfg->class_count, "an active ship has a valid hull");
        if (sh->cls >= cfg->class_count) continue;
        const sim_ship_class *c = &cfg->classes[sh->cls];
        CHECK(sh->energy >= 0, "ship energy never goes negative");
        CHECK(sh->energy <= sim_eff_max_energy(c, sh),
              "ship energy stays below its current capacity");
        CHECK((sh->alive && sh->energy > 0) || (!sh->alive && sh->energy == 0),
              "life and energy agree");
        for (int t = 0; t < SIM_TRIG_COUNT; t++) {
            CHECK(sh->level[t] < SIM_MAX_RUNGS, "weapon rung stays in bounds");
            if (sh->level[t] < SIM_MAX_RUNGS
                && c->trigger[t][0] != SIM_NO_PATTERN)
                CHECK(c->trigger[t][sh->level[t]] != SIM_NO_PATTERN,
                      "a held rung names a pattern");
            for (int mod = 0; mod < SIM_MOD_COUNT; mod++)
                CHECK(sim_mod_get(sh->mods[t], mod)
                          <= sim_mod_get(c->mod_max[t], mod),
                      "weapon add-ons stay below the hull ceiling");
        }
        for (int charge = 0; charge < SIM_MAX_CHARGES; charge++)
            CHECK(sh->charge[charge] <= c->charge_max[charge],
                  "charges stay below the hull ceiling");
        if (sh->carrier != SIM_NO_CARRIER) {
            CHECK(sh->carrier < s->ship_count, "a gunner names an existing carrier");
            if (sh->carrier >= s->ship_count) continue;
            const sim_ship *carrier = &s->ships[sh->carrier];
            CHECK(carrier->active && carrier->alive, "a gunner rides a live carrier");
            CHECK(carrier->carrier == SIM_NO_CARRIER, "attachments stay one level deep");
            CHECK(carrier->team == sh->team, "a gunner rides their own side");
            CHECK(carrier->x == sh->x && carrier->y == sh->y,
                  "a gunner stays on the carrier");
        }
    }

    for (int i = 0; i < s->weapon_count; i++) {
        const sim_weapon *w = &s->weapons[i];
        CHECK(w->spec < cfg->spec_count, "a weapon names an existing spec");
        CHECK(w->owner < s->ship_count, "a weapon names an existing owner");
        CHECK(w->depth <= SIM_MAX_SPLINTER_DEPTH, "splinter depth stays bounded");
        CHECK(w->fuse_target == 255 || w->fuse_target < s->ship_count,
              "a fuse names an existing target");
        CHECK(w->level < SIM_MAX_RUNGS, "a weapon rung stays in bounds");
        CHECK(w->shrap_level < SIM_MAX_RUNGS, "a fragment rung stays in bounds");
    }

    int live_prizes = 0;
    for (int i = 0; i < SIM_MAX_PRIZES; i++) {
        const sim_prize *p = &s->prizes[i];
        if (!p->active) continue;
        live_prizes++;
        CHECK(p->x >= 0 && p->y >= 0, "a green stays on the map");
        if (p->x < 0 || p->y < 0) continue;
        CHECK((p->x & (SIM_TILE_PX * 256 - 1)) == SIM_TILE_PX * 128,
              "a green stays centered on its tile horizontally");
        CHECK((p->y & (SIM_TILE_PX * 256 - 1)) == SIM_TILE_PX * 128,
              "a green stays centered on its tile vertically");
        CHECK(SIM_TILE_CLASS(sim_tile_at(cfg->map, p->x >> 12, p->y >> 12))
                  != SIM_TILE_SOLID,
              "a green stays out of walls");
    }
    CHECK(live_prizes <= SIM_MAX_PRIZES, "green count stays in bounds");

    for (int i = 0; i < s->flag_count; i++) {
        const sim_flag *f = &s->flags[i];
        CHECK(f->active, "every counted flag is active");
        if (!f->carried) continue;
        CHECK(f->carrier < s->ship_count, "a carried flag names an existing ship");
        if (f->carrier >= s->ship_count) continue;
        const sim_ship *carrier = &s->ships[f->carrier];
        CHECK(carrier->active && carrier->alive, "a flag carrier is alive");
        CHECK(f->team == carrier->team, "a carried flag belongs to its carrier's side");
        CHECK(f->x == carrier->x && f->y == carrier->y,
              "a carried flag stays on its carrier");
    }
}

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
    int fires, hits, deaths, bounces, spawns, prizes, warps, predicted_deaths;
} ev_counts;

static ev_counts step_counting(sim_state *s, const sim_settings *cfg,
                               uint16_t b0, uint16_t b1, int n) {
    ev_counts c = {0, 0, 0, 0, 0, 0, 0, 0};
    sim_state tmp;
    sim_events ev;
    for (int i = 0; i < n; i++) {
        sim_input in[2] = {{0, b0}, {1, b1}};
        sim_step(&tmp, s, in, s->ship_count > 1 ? 2 : 1, cfg, &ev);
        *s = tmp;
        c.predicted_deaths += ev.predicted_death_count;
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
static int32_t gun_cost(const sim_settings *cfg, uint8_t cls, uint8_t level,
                        uint16_t mods, uint16_t *wait) {
    sim_state a, b;
    sim_init(&a, 1);
    sim_spawn(&a, cls, 0, 8192, 8192, 0, cfg);
    a.ships[0].energy /= 2;
    a.ships[0].level[SIM_TRIG_GUN] = level;
    a.ships[0].mods[SIM_TRIG_GUN] = mods;
    b = a;
    step_n(&a, cfg, 0, 0, 1);
    step_n(&b, cfg, SIM_BTN_FIRE, 0, 1);
    if (wait) *wait = b.ships[0].fire_cooldown[SIM_TRIG_GUN];
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
        /* Four thousand ticks, not two. A fresh hull recharges at
         * InitialRecharge, which is 400 in the original's units and so 40
         * energy a second against a 1000 bar: twenty-five seconds to fill
         * from empty, where our own numbers used to do it in nine. */
        step_n(&s, &cfg, 0, 0, 4000);
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
     * faster than it recharges dies. The listed 200 is a ceiling and the SVS
     * random curve averages near two thirds of it, so a fresh 1000-energy
     * hull usually takes around eight hits rather than exactly five.
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

    /* A proximity fuse catches a near miss without weakening a bomb already
     * on course for contact. */
    {
        const int32_t GAP = 200;
        /* Straight at a stationary target, contact arrives before the armed
         * delay expires, so the fuse must change nothing. */
        int32_t dealt[2];
        for (int fused = 0; fused < 2; fused++) {
            sim_settings w = cfg;
            sim_state s;
            sim_init(&s, 1);
            sim_spawn(&s, APEX, 0, 8192, 8192, 0, &w);
            sim_spawn(&s, APEX, 1, 8192, 8192 - GAP, 0, &w);
            if (fused) {
                s.ships[0].mods[SIM_TRIG_BOMB] =
                    sim_mod_set(s.ships[0].mods[SIM_TRIG_BOMB], SIM_MOD_PROX, 1);
            }
            int32_t e0 = s.ships[1].energy;
            step_n(&s, &w, SIM_BTN_BOMB, 0, 200);
            dealt[fused] = e0 - s.ships[1].energy;
        }
        CHECK(dealt[0] > 0, "a plain bomb reaches a target dead ahead");
        /* Sampling can move the two endings by a fraction, but arming the
         * fuse must not turn a direct hit into peripheral damage. */
        CHECK(dealt[1] * 4 > dealt[0] * 3,
              "and a fused one lands what the plain one would, not a fifth");

        /* Past the flank: this is what the fuse is for. A bomb thrown wide
         * enough to miss the hull entirely still goes off beside it, where
         * an unfused one sails on. */
        int32_t wide[2];
        for (int fused = 0; fused < 2; fused++) {
            sim_settings w = cfg;
            sim_state s;
            sim_init(&s, 1);
            sim_spawn(&s, APEX, 0, 8192, 8192, 0, &w);
            /* Offset sideways by more than the hull's half width, so nothing
             * touches, and less than the fuse's reach. */
            sim_spawn(&s, APEX, 1, 8192 + 40, 8192 - GAP, 0, &w);
            if (fused) {
                s.ships[0].mods[SIM_TRIG_BOMB] =
                    sim_mod_set(s.ships[0].mods[SIM_TRIG_BOMB], SIM_MOD_PROX, 1);
            }
            int32_t e0 = s.ships[1].energy;
            step_n(&s, &w, SIM_BTN_BOMB, 0, 200);
            wide[fused] = e0 - s.ships[1].energy;
        }
        CHECK(wide[1] > wide[0], "a fuse catches the near miss a plain bomb misses");
    }

    /* Proximity, the original's way: a square sensor about the bomb, the
     * larger of the two axis gaps as the distance, one hull latched, and a
     * clock that ends the wait if the target never pulls away.
     *
     * Rounds are placed by hand and given velocities, because every claim
     * here is geometry: a fired round arrives on whatever path the muzzle
     * gave it and would prove none of them.
     */
    {
        const int32_t REACH = 60;
        sim_settings w = cfg;
        w.prox_delay = 5;
        sim_weapon_spec sp = w.specs[gun_of(&w, APEX)->spec];
        sp.speed = 0;
        sp.trigger = REACH * 256;
        sp.blast = 80 * 256;
        sim_fire_pattern fp = *gun_of(&w, APEX);
        fp.spec = (uint8_t)sim_add_spec(&w, &sp);
        w.classes[APEX].trigger[SIM_TRIG_GUN][0] = (uint8_t)sim_add_pattern(&w, &fp);

        /* `trigger * 18 / 16 - 14` is 53.5 px on a 60 px fuse, and an Apex
         * adds its 10 px flank, so the sensor reaches 63.5 px along an axis.
         * Not the 60 it was set to, which is the point: the original scales
         * the number before it uses it. */
        struct { int32_t ox, oy; int arms; const char *what; } placed[] = {
            {55,  0, 1, "inside the reach it arms"},
            {70,  0, 0, "outside it does not"},
            /* A square, not a circle. Fifty each way is seventy from the
             * hull as the crow flies, well outside any circle this fuse
             * could draw, and inside the box on both axes. */
            {50, 50, 1, "and the corners are in, because the sensor is square"},
        };
        for (size_t k = 0; k < sizeof placed / sizeof *placed; k++) {
            sim_state s;
            sim_init(&s, 1);
            sim_spawn(&s, APEX, 0, 8192, 8192, 0, &w);
            sim_spawn(&s, APEX, 1, 8192, 8192 - 200, 0, &w);
            step_n(&s, &w, SIM_BTN_FIRE, 0, 1);
            CHECK(s.weapon_count == 1, "the test round left");
            s.weapons[0].x = s.ships[1].x + placed[k].ox * 256;
            s.weapons[0].y = s.ships[1].y + placed[k].oy * 256;
            /* Stationary: never closing, never opening. So the clock is the
             * only thing that can end it, which is what makes this a test of
             * the reach and of BombExplodeDelay at once. */
            s.weapons[0].vx = s.weapons[0].vy = 0;
            step_n(&s, &w, 0, 0, 2);
            CHECK(s.weapon_count == 1, "an armed round waits out its delay");
            step_n(&s, &w, 0, 0, 6);
            CHECK((s.weapon_count == 0) == placed[k].arms, placed[k].what);
        }

        /* Closing holds the shot; opening takes it. */
        sim_state chase;
        sim_init(&chase, 1);
        sim_spawn(&chase, APEX, 0, 8192, 8192, 0, &w);
        sim_spawn(&chase, APEX, 1, 8192, 8192 - 200, 0, &w);
        step_n(&chase, &w, SIM_BTN_FIRE, 0, 1);
        chase.weapons[0].x = chase.ships[1].x + 55 * 256;
        chase.weapons[0].y = chase.ships[1].y;
        chase.weapons[0].vx = -65536;          /* a pixel a tick, toward it */
        chase.weapons[0].vy = 0;
        step_n(&chase, &w, 0, 0, 1);
        CHECK(chase.weapon_count == 1, "a round still closing holds its shot");

        /* And then the target outruns it, which is the moment. */
        chase.ships[1].vx = -2 * 65536;
        step_n(&chase, &w, 0, 0, 1);
        CHECK(chase.weapon_count == 0, "and takes it when the gap opens again");
    }

    /* BombSafety: a proximity bomb will not leave the tube with somebody
     * already inside the fuse's distance. The original's safety catch, and
     * the reason a bomb cannot be walked up to a hull and posted through it. */
    {
        sim_settings w = cfg;
        w.bomb_safety = 1;
        for (int close = 0; close < 2; close++) {
            sim_state s;
            sim_init(&s, 1);
            int me = sim_spawn(&s, APEX, 0, 8192, 8192, 0, &w);
            /* Inside the fuse's three tiles, or well outside them. */
            sim_spawn(&s, APEX, 1, 8192, 8192 - (close ? 40 : 300), 0, &w);
            s.ships[me].mods[SIM_TRIG_BOMB] =
                sim_mod_set(s.ships[me].mods[SIM_TRIG_BOMB], SIM_MOD_PROX, 1);
            step_n(&s, &w, SIM_BTN_BOMB, 0, 1);
            if (close) {
                CHECK(s.weapon_count == 0, "the safety refuses the shot");
                CHECK(s.ships[me].energy
                      == sim_eff_max_energy(&w.classes[APEX], &s.ships[me]),
                      "and refusing costs nothing, since nothing was fired");
            } else {
                CHECK(s.weapon_count == 1, "with room, the bomb goes");
            }
        }
        /* A plain bomb has no sensor and so no safety on it. */
        sim_state d;
        sim_init(&d, 1);
        sim_spawn(&d, APEX, 0, 8192, 8192, 0, &w);
        sim_spawn(&d, APEX, 1, 8192, 8192 - 40, 0, &w);
        step_n(&d, &w, SIM_BTN_BOMB, 0, 1);
        CHECK(d.weapon_count == 1, "an unfused bomb is not held back");
    }

    /* Standing in your own blast costs the pilot in front of you.
     *
     * The original takes half of whatever the shooter's own distance would
     * have paid off everybody else's damage, so a bomb let off at your feet
     * lands at half strength on them and full strength on you. It is what
     * makes a bomb a thrown weapon rather than a large bullet. */
    {
        sim_settings w = cfg;
        w.bomb_safety = 0;      /* measuring the damage, not the catch */
        int32_t dealt[2];
        for (int near = 0; near < 2; near++) {
            sim_state s;
            sim_init(&s, 1);
            /* The victim sits still; only the bomber's distance moves. */
            sim_spawn(&s, APEX, 0, 8192, 8192, 0, &w);
            sim_spawn(&s, APEX, 1, 8192, 8192 - 400, 0, &w);
            int32_t e0 = s.ships[1].energy;
            step_n(&s, &w, SIM_BTN_BOMB, 0, 1);
            CHECK(s.weapon_count == 1, "the bomb is away");
            /* Park it on the victim so it goes off there, with the bomber
             * either standing in the blast or back where it fired from. */
            s.weapons[0].x = s.ships[1].x;
            s.weapons[0].y = s.ships[1].y;
            s.weapons[0].vx = s.weapons[0].vy = 0;
            if (near) {
                s.ships[0].x = s.ships[1].x;
                s.ships[0].y = s.ships[1].y;
            }
            step_n(&s, &w, 0, 0, 3);
            dealt[near] = e0 - s.ships[1].energy;
        }
        CHECK(dealt[0] > 0, "a bomb thrown from a distance lands");
        CHECK(dealt[1] * 3 < dealt[0] * 2,
              "and one let off at your own feet lands about half as hard");
    }

    /* BBombDamagePercent: a hull whose bombs may bounce pays for it on every
     * bomb, whether or not this one bounced. */
    {
        sim_settings w = cfg;
        w.bomb_safety = 0;
        w.bbomb_damage = 500;
        /* An Apex may not bounce a bomb; give a copy of it the ceiling and
         * nothing else, so the hulls differ in that alone. */
        const int OTHER = 1;
        w.classes[OTHER] = w.classes[APEX];
        w.classes[OTHER].mod_max[SIM_TRIG_BOMB] =
            sim_mod_set(w.classes[APEX].mod_max[SIM_TRIG_BOMB], SIM_MOD_BOUNCE, 1);
        int32_t dealt[2];
        for (int bouncer = 0; bouncer < 2; bouncer++) {
            sim_state s;
            sim_init(&s, 1);
            sim_spawn(&s, bouncer ? OTHER : APEX, 0, 8192, 8192, 0, &w);
            sim_spawn(&s, APEX, 1, 8192, 8192 - 400, 0, &w);
            int32_t e0 = s.ships[1].energy;
            step_n(&s, &w, SIM_BTN_BOMB, 0, 1);
            s.weapons[0].x = s.ships[1].x;
            s.weapons[0].y = s.ships[1].y;
            s.weapons[0].vx = s.weapons[0].vy = 0;
            /* The bomber stays where it fired, well clear of the blast, so
             * the hull's ceiling is the only thing that differs. */
            step_n(&s, &w, 0, 0, 3);
            dealt[bouncer] = e0 - s.ships[1].energy;
        }
        CHECK(dealt[0] > 0, "the plain hull's bomb lands");
        CHECK(dealt[1] < dealt[0], "and a bouncing hull's lands softer");
    }

    /* An EMP bomb leaves its own guns running, which is the one exception to
     * every trigger locking every other. Read off the round rather than a
     * flag on the hull: a bomb that suppresses the recharge is what EmpBomb
     * means. */
    {
        sim_settings w = cfg;
        w.bomb_safety = 0;
        uint16_t after[2];
        for (int emp = 0; emp < 2; emp++) {
            sim_settings v = w;
            if (emp) {
                uint8_t pat = v.classes[APEX].trigger[SIM_TRIG_BOMB][0];
                v.specs[v.patterns[pat].spec].stall = 400;
            }
            sim_state s;
            sim_init(&s, 1);
            int me = sim_spawn(&s, APEX, 0, 8192, 8192, 0, &v);
            step_n(&s, &v, SIM_BTN_BOMB, 0, 1);
            CHECK(s.weapon_count == 1, "the bomb is away");
            after[emp] = s.ships[me].fire_cooldown[SIM_TRIG_GUN];
        }
        CHECK(after[0] > 0, "an ordinary bomb shuts the guns too");
        CHECK(after[1] == 0, "an EMP bomb leaves them open");
    }

    /* Shrapnel is bullets, so a fragment is a bullet of your gun's rung.
     *
     * The rung is read off the guns when the bomb is thrown and carried by
     * the bomb, so climbing the gun ladder makes a bomber's burst harder
     * without touching their bombs. This is the claim the old fragment could
     * not make: it was one spec at a flat two hundred, an L1 bullet forever
     * however many gun prizes were found.
     *
     * Read off the fragments rather than off a victim's energy, because a
     * fragment born on top of somebody is inside InactiveShrapDamage's first
     * quarter second and does almost nothing whatever rung it is. What the
     * round carries is the mechanism; the damage is `damage_up` applied to
     * it, which the spec check below pins.
     */
    {
        sim_settings w = cfg;
        w.prize_max = 0;
        w.bomb_safety = 0;
        for (int k = 1; k < SIM_MAX_RUNGS; k++) {
            const sim_weapon_spec *fs =
                &w.specs[w.patterns[w.mod_splinter[k]].spec];
            CHECK(fs->damage_up > 0,
                  "a fragment's damage climbs with the rung that threw it");
        }

        int rungs = 0;
        for (int g = 0; g < SIM_MAX_RUNGS; g++) {
            if (w.classes[APEX].trigger[SIM_TRIG_GUN][g] == SIM_NO_PATTERN) break;
            rungs++;
            for (int bouncy = 0; bouncy < 2; bouncy++) {
                /* Burst against the top wall, with nobody else about. A
                 * fragment born on a hull contacts it on the same tick and
                 * is gone before it can be read; a wall leaves them flying. */
                sim_state s;
                sim_init(&s, 1);
                int me = sim_spawn(&s, APEX, 0, 8192, 300, 0, &w);
                s.ships[me].level[SIM_TRIG_GUN] = (uint8_t)g;
                s.ships[me].mods[SIM_TRIG_BOMB] =
                    sim_mod_set(0, SIM_MOD_SHRAPNEL, 3);
                if (bouncy)
                    s.ships[me].mods[SIM_TRIG_GUN] =
                        sim_mod_set(0, SIM_MOD_BOUNCE, 1);
                step_n(&s, &w, SIM_BTN_BOMB, 0, 1);
                CHECK(s.weapon_count == 1, "the bomb is away");
                CHECK(s.weapons[0].shrap_level == (uint8_t)g,
                      "the bomb carries the gun rung it was thrown at");
                int waited = 0;
                while (s.weapon_count == 1 && waited < 400) {
                    step_n(&s, &w, 0, 0, 1);
                    waited++;
                }
                CHECK(s.weapon_count > 0, "and it broke into fragments");
                for (uint16_t i = 0; i < s.weapon_count; i++) {
                    CHECK(s.weapons[i].level == (uint8_t)g,
                          "every fragment is a bullet of that rung");
                    CHECK((s.weapons[i].mods != 0) == bouncy,
                          "and bounces exactly when their bullets do");
                }
            }
        }
        CHECK(rungs >= 2, "an Apex has a gun ladder to climb");

        /* The rung is the thrower's at the moment of the throw. A gun found
         * while the bomb is in the air does not improve the burst it is on
         * its way to making. */
        sim_state s;
        sim_init(&s, 1);
        int me = sim_spawn(&s, APEX, 0, 8192, 300, 0, &w);
        s.ships[me].mods[SIM_TRIG_BOMB] = sim_mod_set(0, SIM_MOD_SHRAPNEL, 3);
        s.ships[me].mods[SIM_TRIG_GUN] = sim_mod_set(0, SIM_MOD_BOUNCE, 1);
        step_n(&s, &w, SIM_BTN_BOMB, 0, 1);
        s.ships[me].level[SIM_TRIG_GUN] = 2;   /* too late */
        int held = 0;
        while (s.weapon_count == 1 && held < 400) {
            step_n(&s, &w, 0, 0, 1);
            held++;
        }
        CHECK(s.weapon_count > 0, "the burst happened");
        for (uint16_t i = 0; i < s.weapon_count; i++)
            CHECK(s.weapons[i].level == 0,
                  "a gun found mid-flight does not improve the burst");
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
         * different color. */
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

        /* A different map must not hash the same, or the check is theater. */
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

        buf[n] = 0x5a;
        CHECK(sim_map_unpack(dst, buf, n + 1) == -1,
              "a map with trailing records is rejected");

        /* And something that is not a map at all. */
        buf[0] ^= 0xff;
        CHECK(sim_map_unpack(dst, buf, n) == -1, "a bad magic is rejected");

        free(src); free(dst); free(pit); free(buf);
    }

    /* Every map is closed, whatever the map says. */
    {
        const int LAST = SIM_MAP_TILES - 1;
        sim_map *open = malloc(sizeof *open);
        memset(open->tile, SIM_TILE_EMPTY, sizeof open->tile);
        sim_map_index(open);

        CHECK(SIM_TILE_CLASS(sim_tile_at(open, 0, 512)) == SIM_TILE_SOLID
                  && SIM_TILE_CLASS(sim_tile_at(open, LAST, 512))
                         == SIM_TILE_SOLID
                  && SIM_TILE_CLASS(sim_tile_at(open, 512, 0)) == SIM_TILE_SOLID
                  && SIM_TILE_CLASS(sim_tile_at(open, 512, LAST))
                         == SIM_TILE_SOLID,
              "a map with no walls of its own is still closed on four sides");
        CHECK(SIM_TILE_CLASS(sim_tile_at(open, 3, 512)) == SIM_TILE_SOLID,
              "the boundary is four tiles thick");
        CHECK(sim_tile_at(open, 4, 512) == SIM_TILE_EMPTY,
              "and no thicker, so the map keeps the rest of its ground");
        CHECK(SIM_TILE_VARIANT(sim_tile_at(open, 0, 512)) == 1,
              "and says it is a boundary rather than a wall");

        /* Which is the whole reason it is four and not one. A hull crosses
         * more than a tile in a tick at speed, and the collision resolves one
         * axis at a time against the tiles it lands on: through a thin wall,
         * there is nothing left to push it back out of. */
        sim_settings edge = cfg;
        edge.map = open;
        sim_state s;
        sim_init(&s, 5);
        sim_spawn(&s, APEX, 0, 40 * 16, 512 * 16, 49152, &edge);
        s.ships[0].vx = -edge.classes[APEX].max_speed * 4;
        step_n(&s, &edge, SIM_BTN_THRUST, 0, 400);
        CHECK(s.ships[0].x > 4 * 16 * 256,
              "a hull thrown at the edge faster than it can fly stays inside");

        /* And a map that arrives over the wire is closed on arrival, not only
         * one that was built here. */
        uint8_t *ob = malloc(SIM_MAP_PACK_MAX);
        int on = sim_map_pack(open, ob, SIM_MAP_PACK_MAX);
        sim_map *back = malloc(sizeof *back);
        CHECK(sim_map_unpack(back, ob, on) == 0, "a closed map packs and unpacks");
        CHECK(SIM_TILE_CLASS(sim_tile_at(back, 0, 512)) == SIM_TILE_SOLID,
              "and is still closed at the far end");
        free(ob); free(back); free(open);
    }

    /* The room size is the zone's, and the array bound is only the ceiling. */
    {
        sim_settings small = cfg;
        small.max_ships = 3;
        sim_state s;
        sim_init(&s, 1);
        for (int i = 0; i < 3; i++)
            CHECK(sim_spawn(&s, APEX, 0, 8192, 8192, 0, &small) == i,
                  "spawns fill the room the zone asked for");
        CHECK(sim_spawn(&s, APEX, 0, 8192, 8192, 0, &small) == -1,
              "and the next one is refused");
        CHECK(s.ship_count == 3, "a refused spawn takes no seat");

        /* Zero is not an empty room. A zone that says nothing gets the ceiling
         * rather than a game nobody can join. */
        sim_settings unset = cfg;
        unset.max_ships = 0;
        CHECK(sim_eff_max_ships(&unset) == SIM_MAX_SHIPS,
              "an unset limit reads as the ceiling");
        CHECK(sim_eff_max_ships(&cfg) == 64,
              "and the baseline ships a 64-pilot room");
    }

    /* The ceiling itself holds: fill it and the next spawn is refused. */
    {
        sim_settings full = cfg;
        full.max_ships = SIM_MAX_SHIPS;
        sim_state s;
        sim_init(&s, 1);
        for (int i = 0; i < SIM_MAX_SHIPS; i++)
            CHECK(sim_spawn(&s, APEX, (uint8_t)(i % 4),
                            (300 + (i % 24) * 8) << 8,
                            (300 + (i / 24) * 8) << 8, 0, &full) == i,
                  "every index up to the ceiling is available");
        CHECK(sim_spawn(&s, APEX, 0, 8192, 8192, 0, &full) == -1,
              "the array bound is still a bound");
        CHECK(s.ship_count == SIM_MAX_SHIPS, "and the count stops there");
    }

    /* A room size survives the wire, which is what lets a client predict in a
     * zone that widened its arena. */
    {
        sim_settings src = cfg, dst;
        src.max_ships = 200;
        uint8_t buf[SIM_SETTINGS_PACK_MAX];
        int n = sim_settings_pack(&src, buf, sizeof buf);
        CHECK(n > 0, "settings pack");
        memset(&dst, 0, sizeof dst);
        CHECK(sim_settings_unpack(&dst, buf, n) == 0, "settings unpack");
        CHECK(dst.max_ships == 200, "the room size crosses the wire");

        /* Whole tables, byte for byte, not a spot check. The pack is a
         * hand-written mirror of the spec struct, so a field added to the
         * struct and forgotten by the mirror arrives at every client as
         * zero -- with the version matching, because the writer that should
         * have bumped it is the writer that was not touched. That happened
         * to `still` and `blast_up` in the very commit that added them: every
         * suite stayed green while a joining client's mines flew off at
         * their layer's speed. Every spec is built by copying a memset
         * local, so the padding is zeroed and memcmp is a fair judge. */
        CHECK(memcmp(dst.specs, src.specs,
                     sizeof(sim_weapon_spec) * src.spec_count) == 0,
              "every spec field crosses the wire");
        CHECK(memcmp(dst.patterns, src.patterns,
                     sizeof(sim_fire_pattern) * src.pattern_count) == 0,
              "and every pattern field");
        CHECK(memcmp(dst.classes, src.classes,
                     sizeof(sim_ship_class) * src.class_count) == 0,
              "and every hull field");
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
        sim_settings w = cfg;
        w.prize_delay = 0;
        w.prize_max = 1;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &w);
        sim_spawn(&s, APEX, 1, 8192, 8192 - 200, 0, &w);
        s.prizes[0].active = 1;
        s.prizes[0].x = tile_center(20);
        s.prizes[0].y = tile_center(20);
        s.prizes[0].life = w.prize_life;
        s.ships[1].energy = 1;
        ev_counts c = step_counting(&s, &w, SIM_BTN_FIRE, 0, 150);
        CHECK(!s.ships[1].alive, "low energy target dies");
        CHECK(c.deaths == 1, "death is reported once");
        CHECK(s.ships[0].kills == 1, "the killer is credited");
        CHECK(s.ships[1].deaths == 1, "the victim's deaths increment");
        int greens = 0;
        for (int i = 0; i < SIM_MAX_PRIZES; i++) {
            if (!s.prizes[i].active) continue;
            greens++;
            CHECK(s.prizes[i].x
                      == tile_center(s.ships[1].x / (SIM_TILE_PX * 256))
                  && s.prizes[i].y
                      == tile_center(s.ships[1].y / (SIM_TILE_PX * 256)),
                  "death leaves a green where the hull exploded");
        }
        CHECK(greens == 1, "a death green replaces a full field prize");
        step_n(&s, &w, 0, 0, w.respawn_delay + 2);
        CHECK(s.ships[1].alive, "the dead respawn");
        CHECK(s.ships[1].energy == sim_eff_max_energy(&w.classes[APEX], &s.ships[1]),
              "respawn restores full energy");
        CHECK(s.ships[1].x == s.ships[1].spawn_x, "respawn returns to spawn");
    }

    /* A deathless instance concludes no death but its named pilot's
     * (decision 40). The hit still reports, so the client's spark still
     * draws; the hull keeps a sliver and flies on, and no kill is credited,
     * because the death is the zone's to announce. */
    {
        sim_state s;
        sim_settings dc = cfg;
        dc.deathless = 1;
        dc.mortal_ship = 255;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &dc);
        sim_spawn(&s, APEX, 1, 8192, 8192 - 200, 0, &dc);
        s.ships[1].energy = 1;
        ev_counts c = step_counting(&s, &dc, SIM_BTN_FIRE, 0, 150);
        CHECK(s.ships[1].alive, "a deathless instance kills nobody");
        CHECK(s.ships[1].energy >= 1, "the hull keeps a sliver");
        CHECK(c.hits > 0, "the hit still reports");
        CHECK(c.predicted_deaths > 0,
              "the suppressed death reports for measurement");
        CHECK(c.deaths == 0, "the death does not happen");
        CHECK(s.ships[0].kills == 0, "and no kill is credited");
    }

    /* A deathless instance sows no prizes, for the same reason it concludes
     * no death: it is a prediction client simulating a snapshot filtered to
     * its interest window, so its live count is about the window, not the
     * map. Left to sow, it seeded a green near the player every prize_delay
     * ticks and the next snapshot swept it: greens blinking in and out of
     * the visible screen. The authority run beside it is what proves the
     * gate is doing the work rather than the field being unsowable. */
    {
        sim_state s;
        sim_settings dc = cfg;
        dc.deathless = 1;
        dc.mortal_ship = 0;
        sim_init(&s, 5);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &dc);
        step_counting(&s, &dc, 0, 0, dc.prize_delay * 4);
        int live = 0;
        for (int i = 0; i < SIM_MAX_PRIZES; i++) live += s.prizes[i].active;
        CHECK(live == 0, "a deathless instance sows nothing");

        sim_state a;
        sim_init(&a, 5);
        sim_spawn(&a, APEX, 0, 8192, 8192, 0, &cfg);
        step_counting(&a, &cfg, 0, 0, cfg.prize_delay * 4);
        live = 0;
        for (int i = 0; i < SIM_MAX_PRIZES; i++) live += a.prizes[i].active;
        CHECK(live > 0, "the authority sows the same field");
    }

    /* The one hull named mortal still dies, which is how the client keeps
     * its own death immediate while everyone else's waits for the zone. */
    {
        sim_state s;
        sim_settings dc = cfg;
        dc.deathless = 1;
        dc.mortal_ship = 1;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &dc);
        sim_spawn(&s, APEX, 1, 8192, 8192 - 200, 0, &dc);
        s.ships[1].energy = 1;
        ev_counts c = step_counting(&s, &dc, SIM_BTN_FIRE, 0, 150);
        CHECK(!s.ships[1].alive, "the named hull still dies");
        CHECK(c.deaths == 1, "and its death is reported");
        CHECK(c.predicted_deaths == 0,
              "a real local death is not a prediction candidate");
        int live = 0;
        for (int i = 0; i < SIM_MAX_PRIZES; i++) live += s.prizes[i].active;
        CHECK(live == 1, "and its death green appears in the predicted tick");
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

    /* Changing sides is the same respawn under the same gate, and it takes
     * what you were carrying for the other side away with it. What it does
     * not take is the ship: crossing over is not a new hull. */
    {
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        sim_spawn(&s, APEX, 1, 8500, 8192, 0, &cfg);
        step_n(&s, &cfg, SIM_BTN_THRUST, SIM_BTN_THRUST, 30);
        s.ships[0].up[SIM_UP_SPEED] = 3;
        s.ships[0].earned = 40;
        sim_add_flag(&s, 100, 100);
        s.flags[0].team = 0;
        s.flags[0].carried = 1;
        s.flags[0].carrier = 0;
        int32_t foe_y = s.ships[1].y;
        CHECK(s.ships[0].y != s.ships[0].spawn_y, "the pilot had flown off");

        CHECK(sim_set_ship_team(&s, &cfg, 0, 5) == 0, "the side changed");
        CHECK(s.ships[0].team == 5, "to the one asked for");
        CHECK(s.ships[0].cls == APEX, "in the hull they were already flying");
        CHECK(s.ships[0].up[SIM_UP_SPEED] == 3,
              "keeping what they had collected for it");
        CHECK(s.ships[0].earned == 0, "and none of the bounty they had earned");
        CHECK(s.ships[0].x == s.ships[0].spawn_x
              && s.ships[0].y == s.ships[0].spawn_y, "back at a start");
        CHECK(s.ships[0].vx == 0 && s.ships[0].vy == 0, "at rest");
        CHECK(s.ships[0].energy ==
              sim_eff_max_energy(&cfg.classes[APEX], &s.ships[0]),
              "with a full bar");
        CHECK(s.ships[1].y == foe_y, "and nobody else moved");
        CHECK(!s.flags[0].carried && s.flags[0].carrier == 0,
              "and the flag is no longer attached to the pilot");
        CHECK(s.flags[0].team == 0, "the dropped flag stays with the old side");

        /* A side the map has never marked a start for still gets one, or a
         * private team formed mid-round would spawn inside the walls. */
        CHECK(sim_set_ship_team(&s, &cfg, 0, 200) == 0, "any side is a side");
        CHECK(SIM_TILE_CLASS(sim_tile_at(cfg.map, s.ships[0].x >> 12,
                                         s.ships[0].y >> 12)) != SIM_TILE_SOLID,
              "and its start is somewhere you can fly");

        CHECK(sim_set_ship_team(&s, &cfg, 0, 200) == 0, "asking again is fine");
        CHECK(sim_set_ship_team(&s, &cfg, 9, 1) == -1, "no such ship");
    }

    /* And the gate itself, which is the only thing standing between a team
     * list and a heal button. */
    {
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        s.ships[0].energy /= 2;
        CHECK(sim_set_ship_team(&s, &cfg, 0, 1) == -1, "not while hurt");
        CHECK(s.ships[0].team == 0, "and the side did not move");
        s.ships[0].energy = sim_eff_max_energy(&cfg.classes[APEX], &s.ships[0]);
        s.ships[0].alive = 0;
        CHECK(sim_set_ship_team(&s, &cfg, 0, 1) == -1, "nor while dead");
        s.ships[0].alive = 1;
        CHECK(sim_set_ship_team(&s, &cfg, 0, 1) == 0, "whole and alive, yes");
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
        /* Two tiles clear of the top wall, facing it. The boundary is four
         * tiles thick, so "clear of it" starts at 64 px. */
        sim_spawn(&s, APEX, 0, 8192, 96, 0, &w);
        step_n(&s, &w, SIM_BTN_FIRE, 0, 1);
        CHECK(s.weapon_count == 1, "fired");
        int32_t up = s.weapons[0].vy;
        CHECK(up < 0, "traveling up");
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
        /* A proximity fuse may still reach contact before its clock ends. */
        sim_settings w = cfg;
        sim_weapon_spec sp = w.specs[gun_of(&w, APEX)->spec];
        const int32_t REACH = 60;
        sp.trigger = REACH * 256;
        sim_fire_pattern fp = *gun_of(&w, APEX);
        fp.spec = (uint8_t)sim_add_spec(&w, &sp);
        w.classes[APEX].trigger[SIM_TRIG_GUN][0] = (uint8_t)sim_add_pattern(&w, &fp);

        /* Dead on, the round reaches the hull before its armed clock ends. */
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &w);
        sim_spawn(&s, APEX, 1, 8192, 8192 - 140, 0, &w);
        step_n(&s, &w, SIM_BTN_FIRE, 0, 1);
        /* Where it was on the last tick it existed. Read rather than
         * predicted: the claim is about where it stopped, and a computed
         * answer would only restate the arithmetic under test. */
        int32_t last = s.weapons[0].y;
        for (int t = 0; t < 60 && s.weapon_count; t++) {
            last = s.weapons[0].y;
            step_n(&s, &w, 0, 0, 1);
        }
        CHECK(s.weapon_count == 0, "it went off");
        CHECK(s.ships[1].energy
              < sim_eff_max_energy(&w.classes[APEX], &s.ships[1]),
              "and it counted");
        /* Both sides Q8, which is what `trigger` is already in. */
        CHECK(last - s.ships[1].y < sp.trigger,
              "a fuse aimed dead on does not stop at its own rim");

        /* Beside it. Offset by more than the hull's half width so nothing can
         * touch, and less than the reach so the fuse still has something to
         * find. Here it goes off without contact when the pass opens.
         *
         * It takes longer than a straight run, and that is the square sensor
         * showing through: the gap it watches is the larger of the two axes,
         * so on a pass forty pixels wide the gap sits at forty for the whole
         * span the round is level with the hull, and only grows once the
         * round is forty past. A round measuring the diagonal would have
         * fired at the crossing. */
        sim_state p;
        sim_init(&p, 1);
        sim_spawn(&p, APEX, 0, 8192, 8192, 0, &w);
        sim_spawn(&p, APEX, 1, 8192 + 40, 8192 - 140, 0, &w);
        step_n(&p, &w, SIM_BTN_FIRE, 0, 1);
        for (int t = 0; t < 200 && p.weapon_count; t++) step_n(&p, &w, 0, 0, 1);
        CHECK(p.weapon_count == 0, "the near miss went off too");
        CHECK(p.ships[1].energy
              < sim_eff_max_energy(&w.classes[APEX], &p.ships[1]),
              "close enough counted, without ever reaching the hull");
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

        /* And breaking up is not firing. The client hears a fire event as a
         * trigger and puts the noise on the hull that pulled it, so a
         * fragment counted here was a gunshot at the shooter every time one
         * of their rounds broke, from wherever on the map it broke. */
        sim_state t;
        sim_init(&t, 1);
        sim_spawn(&t, APEX, 0, 8192, 8192, 0, &w);
        ev_counts pull = step_counting(&t, &w, SIM_BTN_FIRE, 0, 1);
        CHECK(pull.fires == 1, "pulling the trigger is one fire event");
        ev_counts flight = step_counting(&t, &w, 0, 0, 25);
        CHECK(flight.fires == 0, "and the eight fragments it became are none");
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
        /* The three numbers a repel is, and it is all three of them.
         *
         * RepelDistance is the half-width of a *square*, not the radius of a
         * circle: the original tests a point against a box, so the corners
         * reach about 724 px where the sides reach 512. RepelSpeed is a speed
         * and not an impulse -- a shoved hull is set to exactly that, from
         * anywhere inside the box, with no falloff and no memory of what it
         * was doing. And RepelTime is how long it may fly at it, because that
         * speed is deliberately faster than any hull and its own ceiling
         * would otherwise take the shove back on the very next tick.
         */
        sim_settings w = cfg;
        sim_weapon_spec sp;
        memset(&sp, 0, sizeof sp);
        sp.speed = 0;
        sp.life = 1;
        sp.on_wall = SIM_WALL_PASS;
        sp.expire_ends = 1;
        sp.blast = 512 * 256;
        sp.push = sim_units_speed(5000);
        sp.push_time = 225;
        sp.splinter = SIM_NO_PATTERN;
        sim_fire_pattern fp;
        memset(&fp, 0, sizeof fp);
        fp.spec = (uint8_t)sim_add_spec(&w, &sp);
        fp.count = 1;
        fp.delay = 25;
        w.classes[APEX].trigger[SIM_TRIG_GUN][0] = (uint8_t)sim_add_pattern(&w, &fp);

        /* Flat, not falling off. One victim almost on top of the repel and
         * one almost at the rim leave at the same speed.
         *
         * Speed, not the x component: the charge leaves the muzzle rather
         * than the hull's center, so two victims level with the firer are on
         * slightly different bearings from it, and the whole point of this is
         * that the magnitude does not care. */
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &w);
        sim_spawn(&s, APEX, 1, 8192 + 40, 8192, 0, &w);
        sim_spawn(&s, APEX, 2, 8192 + 500, 8192, 0, &w);
        step_n(&s, &w, SIM_BTN_FIRE, 0, 3);
        int64_t near2 = (int64_t)s.ships[1].vx * s.ships[1].vx
                      + (int64_t)s.ships[1].vy * s.ships[1].vy;
        int64_t far2 = (int64_t)s.ships[2].vx * s.ships[2].vx
                     + (int64_t)s.ships[2].vy * s.ships[2].vy;
        int64_t want = (int64_t)sim_units_speed(5000) * sim_units_speed(5000);
        /* Within a per-cent, which is integer division rounding and nothing
         * else: the direction is a unit vector made with one divide. */
        CHECK(near2 > want * 98 / 100 && near2 < want * 102 / 100,
              "a repel sets the speed of a hull beside it to RepelSpeed");
        CHECK(far2 > want * 98 / 100 && far2 < want * 102 / 100,
              "and shoves the far edge exactly as hard as the middle");

        /* Square, not circular. A ship out at 400 px on both axes is 566 px
         * away and well outside a 512 px circle, and inside the box. */
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &w);
        sim_spawn(&s, APEX, 1, 8192 + 400, 8192 + 400, 0, &w);
        sim_spawn(&s, APEX, 2, 8192 + 600, 8192, 0, &w);
        step_n(&s, &w, SIM_BTN_FIRE, 0, 3);
        CHECK(s.ships[1].vx > 0 && s.ships[1].vy > 0,
              "the corner of the box is inside the repel");
        CHECK(s.ships[2].vx == 0 && s.ships[2].vy == 0,
              "and past the side of it is outside");

        /* The window. The shove is held while it lasts and taken back when it
         * shuts, which is what a hull's own ceiling does to anything faster
         * than itself. */
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &w);
        sim_spawn(&s, APEX, 1, 8192 + 200, 8192, 0, &w);
        step_n(&s, &w, SIM_BTN_FIRE, 0, 3);
        int32_t hull = sim_eff_speed(&w.classes[APEX], &s.ships[1]);
        CHECK(s.ships[1].vx > hull, "a repel outruns the hull it shoved");
        step_n(&s, &w, 0, 0, 200);
        CHECK(s.ships[1].vx > hull, "and is still doing it two seconds later");
        step_n(&s, &w, 0, 0, 40);
        CHECK(s.ships[1].vx <= hull,
              "and is back inside the hull's own ceiling once the window shuts");

        /* A round is moved the same way, and its clock starts again: a bomb
         * batted back the way it came has the whole of its life to make the
         * trip. The repel is on the Apex's trigger in these settings, so the
         * enemy is a different hull and keeps an ordinary gun.  */
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &w);
        sim_spawn(&s, 1, 1, 8192 + 200, 8192, 49152, &w);   /* facing west */
        step_n(&s, &w, 0, SIM_BTN_FIRE, 1);
        step_n(&s, &w, 0, 0, 20);
        CHECK(s.weapon_count == 1, "the enemy round is in the air");
        int32_t before = s.weapons[0].vx;
        uint16_t life = s.weapons[0].life;
        uint8_t bullet = s.weapons[0].spec;
        CHECK(before < 0, "and traveling toward the repel");
        step_n(&s, &w, SIM_BTN_FIRE, 0, 3);
        CHECK(s.weapon_count >= 1, "and survived being repelled");
        CHECK(s.weapons[0].vx > 0, "a repel turns an enemy round around");
        CHECK(s.weapons[0].life > life,
              "and gives it its whole life again to make the trip");
        /* Its own full alive time, less the couple of ticks spent getting
           here, rather than whatever was left of the old clock. */
        CHECK(s.weapons[0].life >= w.specs[bullet].life - 3,
              "which is the round's own alive time, not what was left of it");
        w.map = m;
    }

    {
        /* Hostile only, ships and rounds alike.
         *
         * A repel in the original moves enemies and enemy fire and leaves
         * you, your side and your own rounds alone. Without the team test the
         * shove was symmetric, and the worst of it landed on the pilot who
         * let it off: the charge spawns at a muzzle offset rather than at the
         * hull center, so the guard for a body at dead center never saw them
         * and they were thrown backwards at 484 px/s, which is faster than
         * any hull in the roster can fly.
         *
         * The shipped charge rather than a spec built here, because this is a
         * claim about the item a player picks up. */
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);         /* lets it off */
        sim_spawn(&s, APEX, 0, 8192 + 200, 8192, 0, &cfg);   /* team mate   */
        sim_spawn(&s, APEX, 1, 8192 - 200, 8192, 0, &cfg);   /* enemy       */
        s.ships[0].charge[0] = 1;

        /* A round of each side's in the air when it goes off. Both hulls face
         * north, so a bullet leaves with no sideways speed at all and any x
         * it has afterwards came from the shove. */
        sim_state tmp;
        sim_input in[3] = {{0, 0}, {1, SIM_BTN_FIRE}, {2, SIM_BTN_FIRE}};
        sim_step(&tmp, &s, in, 3, &cfg, NULL); s = tmp;
        CHECK(s.weapon_count >= 2, "both sides have a round in the air");

        in[1].buttons = 0;
        in[2].buttons = 0;
        in[0].buttons = SIM_BTN_USE;          /* slot zero is the repel */
        sim_step(&tmp, &s, in, 3, &cfg, NULL); s = tmp;
        /* Spent on the tick it is asked for, but the round it makes carries
         * one tick of life, so the blast lands on the step after. */
        in[0].buttons = 0;
        sim_step(&tmp, &s, in, 3, &cfg, NULL); s = tmp;

        CHECK(s.ships[0].vx == 0 && s.ships[0].vy == 0,
              "a repel does not move the pilot who let it off");
        CHECK(s.ships[1].vx == 0 && s.ships[1].vy == 0, "nor a team mate");
        CHECK(s.ships[2].vx < 0, "and still throws the enemy clear");

        int friendly_still = 1, hostile_thrown = 0;
        for (uint16_t i = 0; i < s.weapon_count; i++) {
            if (s.weapons[i].team == 0) {
                if (s.weapons[i].vx != 0) friendly_still = 0;
            } else if (s.weapons[i].vx < 0) {
                hostile_thrown = 1;
            }
        }
        CHECK(friendly_still, "and leaves the rounds your own side fired");
        CHECK(hostile_thrown, "while still turning theirs away");
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
        const int CIPHER = 4, LATTICE = 6;
        int n = sim_prize_pool(&cfg.classes[APEX], pool);
        int has_gun_level = 0, has_bomb_level = 0, has_multi = 0, has_shrap = 0;
        for (int i = 0; i < n; i++) {
            if (pool[i] == SIM_PRIZE_LEVEL(SIM_TRIG_GUN)) has_gun_level = 1;
            if (pool[i] == SIM_PRIZE_LEVEL(SIM_TRIG_BOMB)) has_bomb_level = 1;
            if (pool[i] == SIM_PRIZE_MOD(SIM_TRIG_GUN, SIM_MOD_MULTI)) has_multi = 1;
            if (pool[i] == SIM_PRIZE_MOD(SIM_TRIG_BOMB, SIM_MOD_SHRAPNEL)) has_shrap = 1;
        }
        CHECK(n >= SIM_UP_COUNT, "every hull can be handed every stat");
        CHECK(has_gun_level, "MaxGuns is 3, so a gun level is on offer");
        CHECK(has_bomb_level, "and MaxBombs is 2, so a bomb level is too");
        CHECK(has_multi, "multifire is universal, as it is in the original");
        CHECK(has_shrap, "and so is shrapnel, on any hull with a rack");

        /* A hull with no rack is offered no bomb add-on: an add-on is a
         * transform on a trigger, and a trigger that does not exist cannot be
         * transformed. No shipped hull is in that position any more, since
         * every one of the original's ships carries a rack, so this takes the
         * rack away to prove the rule still holds for a zone that does. */
        sim_settings *nb = malloc(sizeof *nb);
        *nb = cfg;
        for (int r = 0; r < SIM_MAX_RUNGS; r++)
            nb->classes[CIPHER].trigger[SIM_TRIG_BOMB][r] = SIM_NO_PATTERN;
        n = sim_prize_pool(&nb->classes[CIPHER], pool);
        int bomb_addon = 0;
        for (int i = 0; i < n; i++)
            if (pool[i] >= SIM_PRIZE_MOD(SIM_TRIG_BOMB, 0)
                && pool[i] < SIM_PRIZE_CHARGE(0)) bomb_addon = 1;
        CHECK(!bomb_addon, "a hull with no rack is offered no bomb add-on");
        free(nb);

        /* The roster is ceilings now, so that is what to check it by. Two
         * bits per add-on and `GUN_ALL | M2(MULTI)` is three rungs rather
         * than two, so these also catch a row built by OR-ing over the
         * macro. */
        const int CHORD = 2, FACET = 5, WEDGE = 1;
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

        /* A kit handed over rather than rolled for. The loadout tournament
         * hands both sides of a bout a fixed list of these, so what it is
         * measuring is the kit and not the dice. */
        sim_ship sh;
        memset(&sh, 0, sizeof sh);
        sh.cls = (uint8_t)APEX;
        CHECK(sim_grant(&sh, &cfg, SIM_PRIZE_LEVEL(SIM_TRIG_GUN)) == 1
              && sh.level[SIM_TRIG_GUN] == 1, "a granted rung is a rung climbed");
        CHECK(sim_grant(&sh, &cfg, SIM_PRIZE_MOD(SIM_TRIG_GUN, SIM_MOD_MULTI)) == 1
              && sim_mod_get(sh.mods[SIM_TRIG_GUN], SIM_MOD_MULTI) == 1,
              "and a granted add-on is an add-on held");

        /* Up the ladder until it refuses. A stage asking for more rungs than
         * a hull has is a stage that hull cannot wear, and the harness has to
         * read that off the return: a silent refusal would report a loadout
         * fighting itself as a loadout that is worth nothing. */
        int granted = 1;
        for (int i = 0; i < SIM_MAX_RUNGS + 4 && granted; i++)
            granted = sim_grant(&sh, &cfg, SIM_PRIZE_LEVEL(SIM_TRIG_GUN));
        CHECK(granted == 0, "the ladder ends and the grant says so");
        uint8_t top = sh.level[SIM_TRIG_GUN];
        CHECK(sim_grant(&sh, &cfg, SIM_PRIZE_LEVEL(SIM_TRIG_GUN)) == 0
              && sh.level[SIM_TRIG_GUN] == top, "and it stays refused there");
        CHECK(sh.earned == 0, "a grant is not a green and pays no bounty");

        /* A trigger the hull does not have refuses outright, at rung zero,
         * where a green would never have offered it in the first place. */
        sim_settings *rackless = malloc(sizeof *rackless);
        *rackless = cfg;
        for (int r = 0; r < SIM_MAX_RUNGS; r++)
            rackless->classes[CIPHER].trigger[SIM_TRIG_BOMB][r] = SIM_NO_PATTERN;
        sim_ship gunner;
        memset(&gunner, 0, sizeof gunner);
        gunner.cls = (uint8_t)CIPHER;
        CHECK(sim_grant(&gunner, rackless, SIM_PRIZE_LEVEL(SIM_TRIG_BOMB)) == 0
              && gunner.level[SIM_TRIG_BOMB] == 0,
              "a hull with no rack cannot be granted a bomb rung");
        free(rackless);

        /* Out of the space entirely is refused rather than written past the
         * end of the counts it would have indexed. */
        CHECK(sim_grant(&sh, &cfg, SIM_PRIZE_COUNT) == 0, "no such prize");
        CHECK(sim_grant(&sh, &cfg, SIM_PRIZE_NONE) == 0, "and none is not one");
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
        CHECK(sh.level[SIM_TRIG_GUN] == 2, "the gun climbs MaxGuns rungs");
        CHECK(sh.level[SIM_TRIG_BOMB] == 1, "and the bomb climbs MaxBombs");
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
         * test is the shape of the tree and not the generator.
         *
         * Two charges and not three: a mine is not one. It is the bomb
         * trigger's other posture and there is no green for it, so it takes
         * nothing out of this pool -- which is the half of the change a
         * distribution test can see. */
        CHECK(stats > 3950 && stats < 4500, "stats are the bread of the tree");
        CHECK(levels > 850 && levels < 1250, "a level is the rare one");
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

        /* What is left of the roster still holds. Freeze is not on an Apex
         * row, however the thirty fall, and a rung above the ladder cannot be
         * handed out. */
        CHECK(sh->level[SIM_TRIG_BOMB] <= 1, "a hull cannot be handed a rung it lacks");
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

        /* Load one up and it goes the other way. Cleared first, because the
         * green above left something in their hands and rust takes whatever
         * is there: with a bomb level now on offer to every hull, the thing
         * it reached for stopped being one of the two set below. */
        memset(&sh, 0, sizeof sh);
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
         * the hull could not have reached.
         *
         * Checked every step rather than at the end. An empty pilot is given
         * a green instead of being rusted, so the two alternate and where two
         * hundred of them happen to stop is a parity rather than a property:
         * it used to land on empty and stopped doing so the moment a bomb
         * level joined the pool and changed what a give hands out. */
        int wrapped = 0;
        for (int i = 0; i < 200; i++) {
            sim_take_prize(&sh, &w, &rng, &delta);
            for (int u = 0; u < SIM_UP_COUNT; u++)
                if (sh.up[u] > 8) wrapped = 1;
            for (int t = 0; t < SIM_TRIG_COUNT; t++)
                if (sh.level[t] >= SIM_MAX_RUNGS) wrapped = 1;
        }
        CHECK(!wrapped, "and rust never takes a pilot past nothing");
    }

    {
        /* A prediction client may consume the visible green, but it does not
         * roll or apply the server-secret result. */
        sim_settings w = cfg;
        w.deathless = 1;
        w.spawn_prizes = 0;
        w.prize_delay = 0;
        sim_state s, next;
        sim_events ev;
        sim_init(&s, 77);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &w);
        s.prizes[0].active = 1;
        s.prizes[0].x = s.ships[0].x;
        s.prizes[0].y = s.ships[0].y;
        s.prizes[0].life = 100;
        sim_ship before = s.ships[0];
        sim_step(&next, &s, NULL, 0, &w, &ev);
        CHECK(!next.prizes[0].active, "prediction removes a touched green");
        CHECK(memcmp(next.ships[0].up, before.up, sizeof before.up) == 0
              && memcmp(next.ships[0].level, before.level, sizeof before.level) == 0
              && memcmp(next.ships[0].mods, before.mods, sizeof before.mods) == 0
              && memcmp(next.ships[0].charge, before.charge, sizeof before.charge) == 0,
              "but applies no guessed outcome");
        int announced = 0, touched = 0;
        for (uint16_t i = 0; i < ev.count; i++) {
            announced += ev.e[i].type == SIM_EV_PRIZE;
            touched += ev.e[i].type == SIM_EV_PRIZE_TOUCH
                       && ev.e[i].a == 0;
        }
        CHECK(announced == 0, "and emits no guessed prize event");
        CHECK(touched == 1, "and reports the touch without an outcome");

        w.spawn_prizes = 30;
        next.ships[0].alive = 0;
        next.ships[0].respawn_at = 1;
        sim_step(&s, &next, NULL, 0, &w, &ev);
        CHECK(s.ships[0].alive, "prediction still advances the respawn");
        CHECK(sim_bounty(&s.ships[0]) == 0,
              "but does not invent a server-secret respawn kit");
    }

    {
        /* Pickup radius is the seven-pixel body of the drawn green, padded
         * circularly around the hull. A square adds the full radius on both
         * axes, so a green off one corner disappears before either visible
         * body has reached the other. */
        sim_settings w = cfg;
        w.deathless = 1;
        w.prize_delay = 0;
        CHECK(w.prize_radius == 7 * 256,
              "the pickup padding matches the green's visible body");
        sim_state s;
        sim_init(&s, 91);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &w);
        sim_ship *sh = &s.ships[0];
        const sim_ship_class *hull = &w.classes[APEX];
        sim_prize *green = &s.prizes[0];
        green->active = 1;
        green->life = 100;
        green->x = sh->x + hull->halfw + 6 * 256;
        green->y = sh->y - hull->fore - 6 * 256;

        step_n(&s, &w, 0, 0, 1);
        CHECK(s.prizes[0].active,
              "a green beyond the radius at a hull corner stays put");

        green = &s.prizes[0];
        green->x = s.ships[0].x + hull->halfw + 8 * 256;
        green->y = s.ships[0].y;
        step_n(&s, &w, 0, 0, 1);
        CHECK(s.prizes[0].active,
              "a visible one-pixel gap straight off the side stays put");

        green->x = s.ships[0].x + hull->halfw + w.prize_radius;
        step_n(&s, &w, 0, 0, 1);
        CHECK(!s.prizes[0].active, "visible contact collects the green");
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
        /* Greens appear where somebody can find them.
         *
         * A map 1024 tiles across holding twenty greens, placed uniformly, is a
         * map with no greens in it: a pilot sees sixty tiles, so the odds of one
         * being in reach are about one in fifty. That shipped, and a player
         * reported a zone with none at all -- which also means an unreachable
         * tech tree, since spawn_prizes is zero and greens are the only way in. */
        sim_settings w = cfg;
        sim_state s;
        sim_init(&s, 17);
        sim_spawn(&s, APEX, 0, 512 * SIM_TILE_PX, 512 * SIM_TILE_PX, 0, &w);
        step_n(&s, &w, 0, 0, w.prize_delay * (w.prize_max + 2));

        int live = 0, worst = 0;
        for (int i = 0; i < SIM_MAX_PRIZES; i++) {
            if (!s.prizes[i].active) continue;
            live++;
            int32_t dx = (s.prizes[i].x - s.ships[0].x) / (SIM_TILE_PX * 256);
            int32_t dy = (s.prizes[i].y - s.ships[0].y) / (SIM_TILE_PX * 256);
            int d = (int)(dx * dx + dy * dy);
            if (d > worst) worst = d;
        }
        CHECK(live > 1, "greens appear at all");
        /* The ship does not move here, so every green must be inside the ring
         * it was placed in -- with a tile of slack for the truncating divide. */
        CHECK(worst <= (SIM_PRIZE_NEAR_HI + 1) * (SIM_PRIZE_NEAR_HI + 1) * 2,
              "and every one of them is within reach of the pilot they spawned by");

        /* Nobody alive is the fallback, and it must still put greens out: a
         * room between rounds comes back up with a field on it. */
        sim_state e;
        sim_init(&e, 19);
        step_n(&e, &w, 0, 0, w.prize_delay * 4);
        int empty_live = 0;
        for (int i = 0; i < SIM_MAX_PRIZES; i++) empty_live += e.prizes[i].active;
        CHECK(empty_live > 0, "an empty room still grows a prize field");
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
        int32_t plain = gun_cost(&cfg, (uint8_t)APEX, 0, 0, &plain_wait);
        int32_t multi = gun_cost(&cfg, (uint8_t)APEX, 0,
                                 sim_mod_set(0, SIM_MOD_MULTI, 1), &multi_wait);
        CHECK(multi == plain * 3 / 2, "multifire costs half again the energy");
        CHECK(multi_wait == plain_wait * 2, "and twice the wait");

        /* A second rung is a second helping of both, because every other
         * add-on here is linear in its rung and this one has no reason not
         * to be. */
        uint16_t two_wait = 0;
        int32_t two = gun_cost(&cfg, (uint8_t)APEX, 0,
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
        /* DoubleBarrel. The Facet fires two for one pull where everyone else
         * fires one, which is the Terrier's setting and the only weapon
         * number besides MaxBombs that the original varied by ship. */
        const int FACET = 5;
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, (uint8_t)FACET, 0, 8192, 8192, 0, &cfg);
        step_n(&s, &cfg, SIM_BTN_FIRE, 0, 1);
        CHECK(s.weapon_count == 2, "a Facet's gun sends two rounds");

        /* One either side of where the nose points. Not exact mirrors: the
         * offsets are, but a heading is quantised to 4096 entries on the way
         * into the table and truncation takes the negative one a step further
         * out, so this asks for the sign and not the magnitude. */
        CHECK((s.weapons[0].vx < 0) != (s.weapons[1].vx < 0),
              "one either side of where it is pointing");

        /* Fanned and not scattered, which is a real distinction here: spacing
         * of zero on a pattern of many is the shrapnel encoding, and it rolls
         * every round's heading off the state's own generator. So move the
         * generator and fire again. A fan cannot notice. */
        sim_state r;
        sim_init(&r, 1);
        sim_spawn(&r, (uint8_t)FACET, 0, 8192, 8192, 0, &cfg);
        r.rng = 0x5eed1234u;
        step_n(&r, &cfg, SIM_BTN_FIRE, 0, 1);
        CHECK(r.weapon_count == s.weapon_count
              && r.weapons[0].vx == s.weapons[0].vx
              && r.weapons[1].vx == s.weapons[1].vx,
              "and they are barrels rather than a scatter");

        /* Four with a rung of multifire, not the six a pilot expects out of
         * three times two. `compose` adds barrels rather than multiplying
         * them, so the original's odd number falls out of the model rather
         * than being special-cased for this hull. */
        sim_state m;
        sim_init(&m, 1);
        sim_spawn(&m, (uint8_t)FACET, 0, 8192, 8192, 0, &cfg);
        m.ships[0].mods[SIM_TRIG_GUN] = sim_mod_set(0, SIM_MOD_MULTI, 1);
        step_n(&m, &cfg, SIM_BTN_FIRE, 0, 1);
        CHECK(m.weapon_count == 4, "and four with a rung of multifire, not six");

        /* DoubleBarrel changes the rounds, not the trigger price. The SVS
         * Terrier pays the same BulletFireEnergy and BulletFireDelay as the
         * Warbird, and the multifire surcharge lands on that one-pull cost. */
        uint16_t facet_wait = 0, apex_wait = 0;
        int32_t facet_plain = gun_cost(&cfg, (uint8_t)FACET, 0, 0, &facet_wait);
        int32_t apex_plain = gun_cost(&cfg, (uint8_t)APEX, 0, 0, &apex_wait);
        CHECK(facet_plain == apex_plain, "two barrels cost one trigger");
        CHECK(facet_wait == apex_wait, "and use the same trigger delay");
        int32_t facet_multi = gun_cost(&cfg, (uint8_t)FACET, 0,
                                       sim_mod_set(0, SIM_MOD_MULTI, 1), NULL);
        CHECK(facet_multi == facet_plain * 3 / 2,
              "and multifire is half again on top of that");
    }

    {
        /* Climbing a rung swaps which pattern the trigger fires, and the one
         * above hits harder and costs its level's multiple of base energy. */
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

        int32_t c1 = gun_cost(&cfg, (uint8_t)APEX, 0, 0, NULL);
        int32_t c2 = gun_cost(&cfg, (uint8_t)APEX, 1, 0, NULL);
        int32_t c3 = gun_cost(&cfg, (uint8_t)APEX, 2, 0, NULL);
        CHECK(c2 == c1 * 2, "a level-two gun costs twice the base energy");
        CHECK(c3 == c1 * 3, "and a level-three gun costs three times the base");
    }

    {
        /* ExactDamage is off in SVS. A bullet's table damage is the ceiling,
         * not the amount every hit removes. Drive rounds directly into a
         * stationary hull so flight and recharge cannot muddy the sample. */
        sim_settings w = cfg;
        w.classes[APEX].recharge = 0;
        sim_state s;
        sim_init(&s, 0x5eed1234u);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &w);
        sim_spawn(&s, APEX, 1, 8200, 8192, 0, &w);
        uint8_t bullet = gun_of(&w, APEX)->spec;
        int32_t ceiling = w.specs[bullet].damage;
        int32_t lo = ceiling, hi = 0;
        int64_t total = 0;
        for (int n = 0; n < 128; n++) {
            sim_weapon *round = &s.weapons[s.weapon_count++];
            memset(round, 0, sizeof *round);
            round->spec = bullet;
            round->owner = 0;
            round->team = 0;
            round->x = s.ships[1].x;
            round->y = s.ships[1].y;
            round->life = 10;
            round->fuse_target = 255;
            s.ships[1].energy = sim_eff_max_energy(&w.classes[APEX],
                                                    &s.ships[1]);
            int32_t before = s.ships[1].energy;
            step_n(&s, &w, 0, 0, 1);
            int32_t dealt = before - s.ships[1].energy;
            if (dealt < lo) lo = dealt;
            if (dealt > hi) hi = dealt;
            total += dealt;
        }
        CHECK(lo >= 0 && hi <= ceiling,
              "random bullet damage stays inside its listed ceiling");
        CHECK(lo < ceiling / 2 && hi > ceiling * 9 / 10,
              "the damage curve reaches both ends of the range");
        CHECK(total > (int64_t)ceiling * 128 * 3 / 5
              && total < (int64_t)ceiling * 128 * 3 / 4,
              "and averages near two thirds of the ceiling");
    }

    {
        /* Every round from one gun pull shares a link. The first hull hit
         * spends the siblings without letting a tight multifire fan stack
         * three hits on the same target. */
        sim_settings w = cfg;
        uint8_t bullet = gun_of(&w, APEX)->spec;
        w.specs[bullet].stall = 1; /* even a zero-damage roll reports the hit */
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &w);
        sim_spawn(&s, APEX, 1, 8200, 8192, 0, &w);
        for (int n = 0; n < 3; n++) {
            sim_weapon *round = &s.weapons[s.weapon_count++];
            memset(round, 0, sizeof *round);
            round->spec = bullet;
            round->owner = 0;
            round->team = 0;
            round->link = 77;
            round->x = s.ships[1].x;
            round->y = s.ships[1].y;
            round->life = 10;
            round->fuse_target = 255;
        }
        sim_state next;
        sim_events ev;
        sim_input in[2] = {{0, 0}, {1, 0}};
        sim_step(&next, &s, in, 2, &w, &ev);
        int hits = 0, expires = 0;
        for (uint16_t e = 0; e < ev.count; e++) {
            hits += ev.e[e].type == SIM_EV_HIT;
            expires += ev.e[e].type == SIM_EV_EXPIRE;
        }
        CHECK(hits == 1, "one linked volley can hit a hull only once");
        CHECK(expires == 3 && next.weapon_count == 0,
              "and the remaining rounds are spent with it");

        /* A wall is not a hull. Put one linked round a tick from the top wall
         * and its sibling in open space. Only the one that reaches masonry
         * should end. */
        sim_state wall;
        sim_init(&wall, 1);
        sim_spawn(&wall, APEX, 0, 8192, 100, 0, &w);
        for (int n = 0; n < 2; n++) {
            sim_weapon *round = &wall.weapons[wall.weapon_count++];
            memset(round, 0, sizeof *round);
            round->spec = bullet;
            round->owner = 0;
            round->team = 0;
            round->link = 88;
            round->x = 8192 * 256;
            round->y = (n == 0 ? 17 : 100) * 256;
            round->vy = n == 0 ? -2 * 256 : 0;
            round->life = 10;
            round->fuse_target = 255;
        }
        sim_input idle = {0, 0};
        sim_step(&next, &wall, &idle, 1, &w, &ev);
        CHECK(next.weapon_count == 1 && next.weapons[0].link == 88,
              "a wall ends one linked round without spending its sibling");
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
        /* Two tiles under the wall, which is four tiles thick and so ends at
         * 64 px: a round travels 2 px a tick, and a distant wall would outlast
         * the flight. */
        sim_spawn(&s, APEX, 0, 8192, 96, 0, &w);
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
        /* One add-on, two weapons, two different budgets: a bouncing bullet
         * bounces for as long as it lives and a bouncing bomb bounces once a
         * rung.
         *
         * The original counts a bomb's bounces and never a bullet's.
         * `BombBounceCount` is per ship, 1 on the Lancaster and 0 elsewhere,
         * and `BBombDamagePercent` sits beside it; bullets have neither,
         * because on the wire bouncing is a weapon *type* rather than a
         * budget, 1 against 2 in the five bits that name a round. Ours
         * counted both, so a bouncing bullet died on its second wall when
         * the original's fills a corridor for five and a half seconds.
         *
         * `mod_step` cannot say this: a step is one number for every weapon
         * that takes the add-on. The base count in each spec can, and does.
         * Measured on the Lattice because it is the Lancaster, the one hull
         * whose bombs may bounce at all. */
        const int LATTICE = 6;
        sim_settings w = cfg;
        w.prize_max = 0;

        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, LATTICE, 0, 8192, 8192, 0, &w);
        s.ships[0].mods[SIM_TRIG_GUN] = sim_mod_set(0, SIM_MOD_BOUNCE, 1);
        step_n(&s, &w, SIM_BTN_FIRE, 0, 1);
        CHECK(s.weapon_count == 1, "a bullet away");
        CHECK(s.weapons[0].left == 255,
              "and it bounces for its whole life rather than once");

        sim_init(&s, 1);
        sim_spawn(&s, LATTICE, 0, 8192, 8192, 0, &w);
        s.ships[0].mods[SIM_TRIG_BOMB] = sim_mod_set(0, SIM_MOD_BOUNCE, 1);
        step_n(&s, &w, SIM_BTN_BOMB, 0, 1);
        CHECK(s.weapon_count == 1, "a bomb away");
        CHECK(s.weapons[0].left == 1,
              "and the same rung buys the bomb exactly one wall");

        /* A fragment is a bullet, so it takes the bullet's answer. Read off
         * the shrapnel spec rather than fired, since what a bomb breaks into
         * is composed where it lands. */
        for (int k = 1; k < SIM_MAX_RUNGS; k++) {
            const sim_weapon_spec *fs =
                &w.specs[w.patterns[w.mod_splinter[k]].spec];
            CHECK(fs->bounces == 255, "and a fragment bounces like the bullet it is");
        }
    }

    {
        /* Shrapnel is the one add-on whose magnitude is another weapon, and
         * fragments do not inherit it: a shell that broke into eight would
         * otherwise have each of those break into eight again. */
        const int WEDGE = 1;
        /* No prize field. Greens appear near a pilot now, so leaving one
         * running under a test about one add-on lets a green hand the shooter
         * another one, and spends draws from the rng that the scatter angles
         * come out of. Two ways for this to fail for a reason that is not
         * shrapnel. */
        sim_settings w = cfg;
        w.prize_max = 0;
        sim_state s;
        sim_init(&s, 1);
        /* Broken on a ship out in the open rather than against a wall, so
         * that what this watches is the hull: fragments born at the point of
         * impact are born inside the ship that was hit, and dying against it
         * is the hull's collision rule, not the wall's. The wall case has its
         * own test below. */
        sim_spawn(&s, WEDGE, 0, 8192, 300, 0, &w);
        sim_spawn(&s, WEDGE, 1, 8192, 150, 0, &w);   /* short of the wall */
        /* The top rung, eight fragments, which is both the case the sentence
         * above is about and the only rung with anything to look at. A shell
         * breaks at the point of impact, which is inside the hull it hit, and a
         * fragment thrown into that hull dies in the tick it was born; at rungs
         * one and two all of them do, so whether any survives is down to which
         * way one seed threw two of them. This test passed on that luck for as
         * long as the seed held, and reported shrapnel broken the day an
         * unrelated change spent a different number of draws. */
        s.ships[0].mods[SIM_TRIG_BOMB] = sim_mod_set(0, SIM_MOD_SHRAPNEL, 3);
        step_n(&s, &w, SIM_BTN_BOMB, 0, 1);
        CHECK(s.weapon_count == 1, "one bomb away");
        /* Looked for every tick rather than at the end. Fragments come into
         * being at the point of impact, which is on top of the hull that was
         * hit, and scattered ones mostly die against it in the same tick they
         * were born. That is faithful, and is the reason the original pays
         * shrapnel almost nothing for its first quarter second.
         *
         * This used to count fire events instead, which was quicker to write
         * and wrong twice over: it read a splinter as a trigger pull, and it
         * stopped being true the day splinters stopped emitting one. */
        int seen = 0, carried = 0;
        ev_counts ec = {0, 0, 0, 0, 0, 0, 0, 0};
        for (int t = 0; t < 200; t++) {
            ev_counts one = step_counting(&s, &w, 0, 0, 1);
            ec.fires += one.fires;
            for (uint16_t i = 0; i < s.weapon_count; i++)
                if (s.weapons[i].depth > 0) {
                    seen = 1;
                    if (s.weapons[i].mods != 0) carried = 1;
                }
        }
        CHECK(seen, "the hit broke it up");
        CHECK(ec.fires == 0, "without anybody pulling a trigger");
        CHECK(!carried, "and the fragments carry nothing");
    }

    {
        /* Shrapnel against the wall its bomb hit, with and without the
         * bullets that bounce.
         *
         * A bomb mostly goes off against a wall, and fragments leave from a
         * point a couple of pixels off its face, so fragments that end on
         * walls lose the half thrown wallward inside a tick or two. That is
         * real, and it is what the original does to a pilot who has not found
         * bouncing bullets: shrapnel is bullets, so it bounces exactly when
         * their bullets do. Both halves are checked here, because the rule is
         * the difference between them. */
        const int WEDGE = 1;
        sim_settings w = cfg;
        w.prize_max = 0;
        for (int k = 1; k < SIM_MAX_RUNGS; k++) {
            const sim_weapon_spec *fs =
                &w.specs[w.patterns[w.mod_splinter[k]].spec];
            CHECK(fs->on_wall == SIM_WALL_END,
                  "a fragment ends on a wall on its own");
            CHECK(fs->damage_up > 0, "and climbs with the rung that threw it");
        }

        int alive[2];
        for (int bouncy = 0; bouncy < 2; bouncy++) {
            sim_state s;
            sim_init(&s, 1);
            /* Facing the top wall with nobody else in the arena, so the wall
             * is the only thing a fragment can die against. */
            sim_spawn(&s, WEDGE, 0, 8192, 300, 0, &w);
            s.ships[0].mods[SIM_TRIG_BOMB] = sim_mod_set(0, SIM_MOD_SHRAPNEL, 3);
            if (bouncy) {
                s.ships[0].mods[SIM_TRIG_GUN] =
                    sim_mod_set(0, SIM_MOD_BOUNCE, 1);
            }
            step_n(&s, &w, SIM_BTN_BOMB, 0, 1);
            CHECK(s.weapon_count == 1, "one bomb away");

            sim_state tmp;
            sim_events ev;
            int waited = 0;
            while (s.weapon_count == 1 && waited < 400) {
                sim_input in = {0, 0};
                sim_step(&tmp, &s, &in, 1, &w, &ev);
                s = tmp;
                waited++;
            }
            /* Not counted here: without the bounce the wallward half is
             * already gone by the tick the bomb ended, which is the thing
             * being measured rather than a step on the way to it. */
            for (int t = 0; t < 120; t++) {
                sim_input in = {0, 0};
                sim_step(&tmp, &s, &in, 1, &w, &ev);
                s = tmp;
            }
            alive[bouncy] = s.weapon_count;
        }
        CHECK(alive[0] < 8, "plain bullets lose the wallward half to the wall");
        CHECK(alive[1] == 8, "and bouncing ones keep every fragment");
    }

    {
        /* The bounce add-on saturates a spec's bounce count rather than
         * wrapping it. Base counts near the top of the byte exist now,
         * shrapnel sits at 255, and a wrap would hand a whole-life bouncer
         * a handful. */
        sim_settings w = cfg;
        w.prize_max = 0;
        w.mod_step[SIM_MOD_BOUNCE] = 20;
        sim_weapon_spec sp = w.specs[gun_of(&w, APEX)->spec];
        sp.on_wall = SIM_WALL_BOUNCE;
        sp.bounces = 250;
        sim_fire_pattern fp = *gun_of(&w, APEX);
        fp.spec = (uint8_t)sim_add_spec(&w, &sp);
        w.classes[APEX].trigger[SIM_TRIG_GUN][0] = (uint8_t)sim_add_pattern(&w, &fp);

        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &w);
        s.ships[0].mods[SIM_TRIG_GUN] = sim_mod_set(0, SIM_MOD_BOUNCE, 1);
        step_n(&s, &w, SIM_BTN_FIRE, 0, 1);
        CHECK(s.weapon_count == 1, "fired");
        CHECK(s.weapons[0].left == 255, "250 base and 20 more saturates at 255");
    }

    {
        /* A charge: a weapon you carry a count of and spend. The Lattice
         * carries repels, which are `push` with no damage at all -- the
         * shape the weapon model has been able to express since it was
         * written, now with an inventory in front of it. */
        const int LATTICE = 6;
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
        const int LATTICE = 6;
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
        /* A mine, which is the bomb trigger in its other posture.
         *
         * The whole of it is fields the model already had, so what these
         * check is that the combination behaves like a mine rather than that
         * any new mechanism works. It stays where it was let go, it goes off
         * on its own clock, and it wears the rung its layer's bombs are on.
         */
        const uint16_t MINE = SIM_BTN_MINE;
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);

        /* Laid at a run. This is the one the `still` field exists for: with
         * the ship's velocity added, a speed-zero round leaves the rack doing
         * exactly what the ship was doing and never stops, which is a bomb
         * that does not steer rather than a mine. */
        step_n(&s, &cfg, SIM_BTN_THRUST, 0, 120);
        CHECK(s.ships[0].vy < -10000, "the pilot is moving when they lay it");
        step_n(&s, &cfg, MINE, 0, 1);
        CHECK(s.weapon_count == 1, "a mine is in the world");
        CHECK(s.ships[0].energy < sim_eff_max_energy(&cfg.classes[APEX],
                                                     &s.ships[0]),
              "and it cost energy rather than an item in a slot");
        int32_t mx = s.weapons[0].x, my = s.weapons[0].y;
        CHECK(s.weapons[0].vx == 0 && s.weapons[0].vy == 0,
              "a mine is laid at rest however fast its layer was going");
        step_n(&s, &cfg, 0, 0, 200);
        CHECK(s.weapon_count == 1, "and is still there two seconds later");
        CHECK(s.weapons[0].x == mx && s.weapons[0].y == my,
              "in exactly the place it was left");

        /* Its life is its whole mechanism, and running out is an ending
         * rather than a round quietly ceasing to exist. */
        uint8_t mine_spec = s.weapons[0].spec;
        CHECK(cfg.specs[mine_spec].expire_ends,
              "a mine that runs out goes off");
        CHECK(cfg.specs[mine_spec].blast > 0, "and takes a blast with it");
        CHECK(cfg.specs[mine_spec].trigger > 0, "and senses on a fuse");
    }

    {
        /* The rung a mine wears is the rung its layer's bombs are on, and it
         * is a real number rather than a coat of paint: the blast climbs the
         * bomb ladder's own arithmetic, so the color the client paints from
         * cannot promise more than the mine delivers. */
        const uint16_t MINE = SIM_BTN_MINE;
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        step_n(&s, &cfg, MINE, 0, 1);
        CHECK(s.weapons[0].level == 0, "a rung one pilot lays a rung one mine");

        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        s.ships[0].level[SIM_TRIG_BOMB] = 2;
        step_n(&s, &cfg, MINE, 0, 1);
        CHECK(s.weapons[0].level == 2, "and a rung three pilot a rung three one");

        /* What that rung buys, measured where it lands rather than read off
         * the spec: a victim standing 150 px out, inside a rung three mine's
         * 240 px blast and outside a rung one's 80. The composition happens
         * in the update loop, off the level the round carries, so this is
         * the path a real detonation takes and not arithmetic done here. */
        sim_state det;
        for (int lvl = 0; lvl <= 2; lvl += 2) {
            sim_init(&det, 1);
            sim_spawn(&det, APEX, 0, 8192, 8192, 0, &cfg);
            sim_spawn(&det, APEX, 1, 8192 + 150, 8192, 0, &cfg);
            det.ships[0].level[SIM_TRIG_BOMB] = (uint8_t)lvl;
            step_n(&det, &cfg, MINE, 0, 1);
            CHECK(det.weapon_count == 1, "the mine is down");
            /* The layer clears out, as a layer does. Standing next to your
             * own blast discounts what it deals everyone else -- the mercy
             * rule -- and a layer camped on its own mine would discount this
             * victim to nothing. */
            det.ships[0].x -= 2000 * 256;
            det.weapons[0].life = 2;      /* run the minute out now */
            int32_t e0 = det.ships[1].energy;
            step_n(&det, &cfg, 0, 0, 4);
            CHECK(det.weapon_count == 0, "and its timer set it off");
            if (lvl == 0)
                CHECK(det.ships[1].energy == e0,
                      "150 px is outside a rung one mine's blast");
            else
                CHECK(det.ships[1].energy < e0,
                      "and inside a rung three's, off the same spec");
        }

        /* The expiry event carries the rung, in the payload bits above the
         * position, because by the time a client reads it the round is gone
         * from the state and a mine is one spec whatever rung was posted.
         * Without it the detonation flashed rung one in violet. */
        sim_init(&det, 1);
        sim_spawn(&det, APEX, 0, 8192, 8192, 0, &cfg);
        det.ships[0].level[SIM_TRIG_BOMB] = 2;
        step_n(&det, &cfg, MINE, 0, 1);
        det.weapons[0].life = 2;
        int rung_seen = -1;
        {
            sim_state tmp;
            sim_events ev;
            for (int i = 0; i < 4; i++) {
                sim_input in = {0, 0};
                sim_step(&tmp, &det, &in, 1, &cfg, &ev);
                det = tmp;
                for (uint16_t e = 0; e < ev.count; e++)
                    if (ev.e[e].type == SIM_EV_EXPIRE)
                        rung_seen = (int)((ev.e[e].v >> 28) & 3);
            }
        }
        CHECK(rung_seen == 2, "the expiry event says which rung went off");
    }

    {
        /* A repelled mine stops being a mine.
         *
         * It is the one round in the game whose shape is wrong for being in
         * flight: a minute of life and a fuse tuned to something standing
         * still beside it. So the shove turns it into a bomb of the rung it
         * was laid at and sends it off in the push direction, which is what
         * clearing a doorway with a repel should look like.
         *
         * The Lattice carries the repel here; the mine is the Apex's, so the
         * two are different hulls and the round crossing between them is
         * unambiguous. */
        const uint16_t MINE = SIM_BTN_MINE;
        const int LATTICE = 6;
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);            /* lays it */
        sim_spawn(&s, LATTICE, 1, 8192 - 200, 8192, 0, &cfg);   /* repels */
        s.ships[0].level[SIM_TRIG_BOMB] = 1;
        step_n(&s, &cfg, MINE, 0, 1);
        CHECK(s.weapon_count == 1, "the mine is posted");
        uint8_t was = s.weapons[0].spec;
        CHECK(cfg.specs[was].still, "and it is the still kind of round");

        s.ships[1].charge[0] = 1;
        step_n(&s, &cfg, 0, SIM_BTN_USE, 3);
        CHECK(s.weapon_count >= 1, "and it survives being repelled");
        const sim_weapon *m = &s.weapons[0];
        CHECK(m->spec != was, "a repelled mine is not a mine any more");
        CHECK(!cfg.specs[m->spec].still, "it is a round that flies now");
        CHECK(cfg.specs[m->spec].blast > 0, "and still a bomb");
        CHECK(m->vx > 0, "thrown away from the repel, not toward it");
        CHECK(m->owner == 0, "still owned by whoever laid it");
        CHECK(m->life <= cfg.specs[m->spec].life
              && m->life > cfg.specs[m->spec].life - 8,
              "on a bomb's clock rather than the minute a mine sits for");
        /* The rung survives the change, which is the point of reading it off
         * the ladder rather than handing every repelled mine the same bomb. */
        CHECK(m->spec == cfg.patterns[cfg.classes[APEX]
                                      .trigger[SIM_TRIG_BOMB][1]].spec,
              "and it is a bomb of the rung the mine was laid at");
    }

    {
        /* Your own repel does not disarm your own minefield. The push loop
         * has always been hostile-only; this is that rule reaching the new
         * round, because a mine you cleared yourself would make the charge a
         * way to tidy up after an ally rather than a way through a door. */
        const uint16_t MINE = SIM_BTN_MINE;
        const int LATTICE = 6;
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        sim_spawn(&s, LATTICE, 0, 8192 - 200, 8192, 0, &cfg);   /* same team */
        step_n(&s, &cfg, MINE, 0, 1);
        uint8_t was = s.weapons[0].spec;
        s.ships[1].charge[0] = 1;
        step_n(&s, &cfg, 0, SIM_BTN_USE, 3);
        CHECK(s.weapon_count >= 1, "the friendly mine is still there");
        CHECK(s.weapons[0].spec == was, "and still a mine");
        CHECK(s.weapons[0].vx == 0 && s.weapons[0].vy == 0,
              "and has not moved an inch");
    }

    {
        /* A mine is your own bomb put on the floor, so the bomb trigger's
         * add-ons reach it. A bomber who climbed to shrapnel and watched
         * their mines go off as bare blasts was being told the two are
         * different weapons, and they are not.
         *
         * Fragments are looked for every tick rather than counted at the
         * end, for the reason the shrapnel test above gives: they are born
         * at the point of impact and the short-lived ones are gone by the
         * next sample. A peak weapon count misses them entirely, which is
         * how this was first measured and first got the wrong answer. */
        const uint16_t MINE = SIM_BTN_MINE;
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, ANVIL, 0, 8192, 8192, 0, &cfg);
        sim_spawn(&s, ANVIL, 1, 8192 + 60, 8192, 0, &cfg);
        s.ships[0].level[SIM_TRIG_BOMB] = 1;
        s.ships[0].level[SIM_TRIG_GUN] = 2;
        s.ships[0].mods[SIM_TRIG_BOMB] = sim_mod_set(0, SIM_MOD_SHRAPNEL, 3);
        step_n(&s, &cfg, MINE, 0, 1);
        CHECK(s.weapon_count == 1, "one charge lays one mine");
        CHECK(sim_mod_get(s.weapons[0].mods, SIM_MOD_SHRAPNEL) == 3,
              "and the mine carries the bomb trigger's shrapnel");
        CHECK(s.weapons[0].shrap_level == 2,
              "with fragments of the layer's gun rung, as a thrown bomb has");
        s.ships[0].x -= 3000 * 256;
        s.weapons[0].life = 2;
        int frags = 0;
        for (int t = 0; t < 120; t++) {
            step_n(&s, &cfg, 0, 0, 1);
            for (uint16_t i = 0; i < s.weapon_count; i++)
                if (s.weapons[i].depth > 0) frags++;
        }
        CHECK(frags > 0, "and a mine that goes off breaks up");

        /* Multifire is the one add-on that does not follow, because it
         * multiplies the pattern rather than transforming the round: three
         * mines out of one charge is not a stronger mine, it is a different
         * inventory. */
        sim_init(&s, 1);
        sim_spawn(&s, ANVIL, 0, 8192, 8192, 0, &cfg);
        s.ships[0].mods[SIM_TRIG_BOMB] = sim_mod_set(0, SIM_MOD_MULTI, 3);
        step_n(&s, &cfg, MINE, 0, 1);
        CHECK(s.weapon_count == 1, "multifire does not lay three mines");
        CHECK(sim_mod_get(s.weapons[0].mods, SIM_MOD_MULTI) == 0,
              "and the round does not carry it either");
    }

    {
        /* A fuse the weapon already has does not stack with the add-on.
         *
         * A bomb is a contact round until proximity gives it a fuse, so there
         * the add-on is the whole of the reach and adding is right. A mine
         * comes with one, and summing made it sense two tiles further than a
         * proximity bomb of the same rung -- which inverts the reason its own
         * fuse is the tighter of the two, since a mine does not have to be
         * dodged in the air first.
         *
         * Measured as the furthest a standing hull can be and still arm the
         * thing, because that is the number a player meets. The bomb is
         * pinned where the mine sits so the two are compared at one
         * geometry rather than wherever flight happened to take it. */
        const uint16_t MINE = SIM_BTN_MINE;
        for (int rung = 0; rung < 3; rung++) {
            int arm[2] = {0, 0};
            for (int kind = 0; kind < 2; kind++) {
                for (int d = 8; d < 400; d += 2) {
                    sim_state s;
                    sim_init(&s, 1);
                    sim_spawn(&s, ANVIL, 0, 8192, 8192, 0, &cfg);
                    sim_spawn(&s, ANVIL, 1, 8192 + d, 8192, 0, &cfg);
                    s.ships[0].level[SIM_TRIG_BOMB] = (uint8_t)rung;
                    s.ships[0].mods[SIM_TRIG_BOMB] =
                        sim_mod_set(0, SIM_MOD_PROX, 1);
                    if (kind == 0) {
                        step_n(&s, &cfg, MINE, 0, 1);
                    } else {
                        step_n(&s, &cfg, SIM_BTN_BOMB, 0, 1);
                        if (s.weapon_count < 1) continue;
                        s.weapons[0].x = 8192 * 256;
                        s.weapons[0].y = 8192 * 256;
                        s.weapons[0].vx = 0;
                        s.weapons[0].vy = 0;
                    }
                    if (s.weapon_count < 1) continue;
                    step_n(&s, &cfg, 0, 0, 1);
                    if (s.weapon_count > 0 && s.weapons[0].fuse_target != 255)
                        arm[kind] = d;
                }
            }
            CHECK(arm[0] > 0 && arm[1] > 0, "both armed on somebody");
            CHECK(arm[0] == arm[1],
                  "a proximity mine senses exactly as far as the bomb it is");
        }

        /* And without the add-on it keeps a fuse of its own, which is the
         * half of this that makes a mine a mine: a bomb there is contact. */
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, ANVIL, 0, 8192, 8192, 0, &cfg);
        sim_spawn(&s, ANVIL, 1, 8192 + 30, 8192, 0, &cfg);
        step_n(&s, &cfg, MINE, 0, 1);
        step_n(&s, &cfg, 0, 0, 1);
        CHECK(s.weapon_count > 0 && s.weapons[0].fuse_target != 255,
              "a mine with no add-on still senses on its own two tiles");
    }

    {
        /* Push follows too, and the thing to hold is that it does not make a
         * mine repel-proof. The push loop skips a round whose spec pushes, so
         * that two repels cannot throw each other about, and it reads the
         * *base* spec: a mine carrying push as an add-on still has none of
         * its own, so an enemy repel converts it like any other. Pinned
         * because it is load-bearing and accidental -- reading the composed
         * spec there instead would silently make a Lattice's minefield
         * immune to the one thing meant to clear it. */
        const uint16_t MINE = SIM_BTN_MINE;
        const int LATTICE = 6;
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, LATTICE, 0, 8192, 8192, 0, &cfg);        /* lays it */
        sim_spawn(&s, LATTICE, 1, 8192 - 200, 8192, 0, &cfg);  /* repels */
        s.ships[0].mods[SIM_TRIG_BOMB] = sim_mod_set(0, SIM_MOD_PUSH, 2);
        step_n(&s, &cfg, MINE, 0, 1);
        CHECK(s.weapon_count == 1, "the pushing mine is posted");
        CHECK(sim_mod_get(s.weapons[0].mods, SIM_MOD_PUSH) == 2,
              "and it carries the push add-on");
        uint8_t was = s.weapons[0].spec;
        s.ships[1].charge[0] = 1;
        step_n(&s, &cfg, 0, SIM_BTN_USE, 3);
        CHECK(s.weapon_count >= 1, "it survived the repel");
        CHECK(s.weapons[0].spec != was,
              "a mine that pushes is still a mine a repel can clear");
        CHECK(s.weapons[0].vx > 0, "and it leaves in the push direction");
    }

    {
        /* What laying one costs, and what the rung adds to it.
         *
         * LandmineFireEnergy is 270 against the bomb's 300 and the upgrade is
         * 150 against the bomb's 50, so a mine starts cheaper and ends dearer:
         * a rung 3 mine costs 570 where a rung 3 bomb costs 400. That is the
         * original's own arrangement and it is the thing stopping the rung
         * being free on the weapon that does not have to be aimed.
         *
         * A mine is one pattern for every rung, so this needs `energy_up` the
         * way its blast needs `blast_up`: the bomb ladder charges per rung by
         * being a pattern per rung and has somewhere to put the number. It was
         * resolved bare here at first, which priced every rung at the first
         * one and made the widest blast in the game free. */
        const uint16_t MINE = SIM_BTN_MINE;
        int32_t cost[3];
        for (int lvl = 0; lvl < 3; lvl++) {
            sim_state s;
            sim_init(&s, 1);
            sim_spawn(&s, ANVIL, 0, 8192, 8192, 0, &cfg);
            s.ships[0].level[SIM_TRIG_BOMB] = (uint8_t)lvl;
            int32_t e0 = s.ships[0].energy;
            step_n(&s, &cfg, MINE, 0, 1);
            CHECK(s.weapon_count == 1, "a mine went down");
            cost[lvl] = e0 - s.ships[0].energy;
        }
        CHECK(cost[1] > cost[0] && cost[2] > cost[1],
              "a rung of the ladder costs more to lay");
        /* The steps are equal, which is what an upgrade per rung means, and
         * measured against each other rather than against a literal so a tick
         * of recharge in the same step cancels out. */
        CHECK(cost[2] - cost[1] == cost[1] - cost[0],
              "and each rung adds the same again");

        /* Refused rather than half-charged when the bar cannot cover it. */
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, ANVIL, 0, 8192, 8192, 0, &cfg);
        s.ships[0].level[SIM_TRIG_BOMB] = 2;
        s.ships[0].energy = cost[2] / 2;
        int32_t before = s.ships[0].energy;
        step_n(&s, &cfg, MINE, 0, 1);
        CHECK(s.weapon_count == 0, "a bar that cannot pay lays nothing");
        CHECK(s.ships[0].energy >= before, "and is not charged for it");
    }

    {
        /* You have mines because you have bombs.
         *
         * No inventory, no green, nothing to run out of: a fresh hull that has
         * touched nothing can lay one on the tick it spawns. That is the
         * original's arrangement -- a mine there is a bomb with one bit set,
         * and the special inventory a position packet carries lists bursts and
         * repels and thors and no mines -- and it is the whole reason the
         * ceiling below has to exist. */
        const uint16_t MINE = SIM_BTN_MINE;
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        CHECK(s.ships[0].charge[0] == 0 && s.ships[0].charge[1] == 0,
              "the pilot is carrying nothing");
        step_n(&s, &cfg, MINE, 0, 1);
        CHECK(s.weapon_count == 1, "and lays a mine anyway");

        /* A hull with no rack lays none, because there is no bomb to not
         * throw. That is the only licence a mine needs and the only one it
         * has. */
        sim_settings w = cfg;
        w.classes[APEX].trigger[SIM_TRIG_BOMB][0] = SIM_NO_PATTERN;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &w);
        step_n(&s, &w, MINE, 0, 1);
        CHECK(s.weapon_count == 0, "a hull with no rack lays nothing");

        /* And a zone that wants a hull out of the mining business says so
         * directly, which is what makes mining somebody's job rather than
         * everybody's. */
        w = cfg;
        w.classes[APEX].mine_max = 0;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &w);
        step_n(&s, &w, MINE, 0, 1);
        CHECK(s.weapon_count == 0, "nor does a hull the zone allows none");
    }

    {
        /* The ceiling, which is the only thing limiting a weapon with no
         * ammunition: how many of yours are already lying about.
         *
         * Walked rather than counted on the ship, so it cannot drift. What
         * this pins is the consequence of that choice: every way a mine
         * leaves the world gives the slot back, including ones a counter
         * would have to be told about. */
        const uint16_t MINE = SIM_BTN_MINE;
        sim_settings w = cfg;
        w.classes[APEX].mine_max = 3;
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &w);
        s.ships[0].energy = sim_eff_max_energy(&w.classes[APEX], &s.ships[0]);

        for (int n = 0; n < 3; n++) {
            /* Nose somewhere new each time so they do not stack in one spot,
             * and wait out the bomb clock the laying locked. */
            s.ships[0].heading = (uint16_t)(n * 8000);
            s.ships[0].energy =
                sim_eff_max_energy(&w.classes[APEX], &s.ships[0]);
            step_n(&s, &w, MINE, 0, 1);
            step_n(&s, &w, 0, 0, 160);
        }
        CHECK(s.weapon_count == 3, "three down, which is the hull's ceiling");
        s.ships[0].energy = sim_eff_max_energy(&w.classes[APEX], &s.ships[0]);
        step_n(&s, &w, MINE, 0, 1);
        CHECK(s.weapon_count == 3, "and the fourth press does nothing at all");
        /* Refused rather than fired and wasted, the way the bomb safety is:
         * a trigger that costs you a bar for nothing is a bug that reads as
         * lag. */
        CHECK(s.ships[0].energy
              == sim_eff_max_energy(&w.classes[APEX], &s.ships[0]),
              "and costs nothing, since nothing was laid");

        /* One goes off and the room is there again. */
        s.weapons[0].life = 2;
        step_n(&s, &w, 0, 0, 5);
        CHECK(s.weapon_count == 2, "one ran out");
        step_n(&s, &w, MINE, 0, 1);
        CHECK(s.weapon_count == 3, "so another may be laid");

        /* Dying does not clear them, so a pilot who spent their allowance and
         * died comes back unable to mine until the old ones age out. That
         * falls out of the count being a walk of the world rather than a
         * number on the hull, and it is the right way round: the mines are
         * still out there, still yours, still dangerous. */
        int before = s.weapon_count;
        s.ships[0].alive = 0;
        step_n(&s, &w, 0, 0, 2);
        CHECK(s.weapon_count == before, "a death leaves your minefield where it is");
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
        CHECK(s.weapon_count == 3, "a leveled, multifired shot leaves");
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
        CHECK(worst > 0 && worst <= l2,
              "a dead pilot's shot keeps its level-two damage ceiling");
    }

    {
        /* And the same for a charge, which is the case where the inventory
         * really is gone: the burst is spent at the trigger, and the sixteen
         * rounds it made are ordinary projectiles from that moment on. */
        const int CIPHER = 4;
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, CIPHER, 0, 8192, 8192, 0, &cfg);
        /* Close, because twenty-four is an even count, which straddles the
         * heading rather than putting one round down the middle: the two
         * nearest leave at seven and a half degrees, so a target far enough
         * away is missed on both sides. */
        sim_spawn(&s, APEX, 1, 8192, 8192 - 60, 0, &cfg);
        s.ships[0].charge[1] = 1;
        step_n(&s, &cfg, SIM_BTN_USE | (1u << SIM_BTN_SLOT_SHIFT), 0, 1);
        CHECK(s.weapon_count == 24, "a burst is BurstShrapnel rounds");
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

    /* A weapon coming off a wall is a ricochet and not a ship's bounce.
     *
     * They shared SIM_EV_BOUNCE once, and the two carry different things in
     * v: an impact speed for a ship, a packed position for a weapon. Nothing
     * in the event says which, so a reader that assumed impact got a position
     * and could not tell. The client's was drawing and sounding every one of
     * its own ricochets on its own hull. */
    {
        sim_state s;
        sim_init(&s, 5);
        /* Well clear of every wall but the one it is aimed at, and told to
         * hold still, so the only thing that can reach a wall is the bullet. */
        sim_spawn(&s, APEX, 0, 8192, 400, 0, &cfg);
        s.ships[0].mods[SIM_TRIG_GUN] =
            sim_mod_set(s.ships[0].mods[SIM_TRIG_GUN], SIM_MOD_BOUNCE, 1);

        sim_state tmp;
        sim_events ev;
        int ricochets = 0, bounces = 0;
        int32_t where = 0;
        uint8_t owner = 255;
        for (int i = 0; i < 500; i++) {
            sim_input in = {0, (uint16_t)(i == 0 ? SIM_BTN_FIRE : 0)};
            sim_step(&tmp, &s, &in, 1, &cfg, &ev);
            s = tmp;
            for (uint16_t e = 0; e < ev.count; e++) {
                if (ev.e[e].type == SIM_EV_BOUNCE) bounces++;
                if (ev.e[e].type == SIM_EV_RICOCHET) {
                    ricochets++;
                    where = ev.e[e].v;
                    owner = ev.e[e].a;
                }
            }
        }
        CHECK(ricochets > 0, "a bouncing bullet reports a ricochet");
        CHECK(bounces == 0, "and not a ship's bounce, with no ship near a wall");
        if (ricochets > 0) {
            /* Packed (x << 14) | y in whole pixels, which is what makes it
             * unusable as an impact: near enough any position clears any
             * threshold a caller would put on one. */
            int32_t px = where >> 14, py = where & 16383;
            CHECK(owner == 0, "the ricochet names the ship that fired it");
            /* The boundary every map is closed with is four tiles thick, so
             * the face a shot comes off is at 64 px and not at the top of the
             * world. */
            CHECK(py >= 16 * 4 && py <= 16 * 5,
                  "the ricochet is at the wall it hit");
            CHECK(px > 8192 - 64 && px < 8192 + 64,
                  "and under the ship that fired straight up");
        }
    }

    /* A snapshot round trip reproduces the state exactly. This is what lets
     * a client accept the server's word without drifting from it. */
    {
        sim_state s, back;
        sim_init(&s, 11);
        sim_spawn(&s, APEX, 0, 8000, 8000, 900, &cfg);
        sim_spawn(&s, ANVIL, 1, 8000, 7800, 32768, &cfg);
        /* A third pilot, four hundred tiles away and left alone. Greens appear
         * near a live ship, so a field with everybody in one place is a field
         * in one place -- and the interest-radius check below needs prizes on
         * both sides of the radius to be checking anything. Somebody off on
         * their own is also the ordinary case on a map this size. */
        sim_spawn(&s, APEX, 1, 8000 + 400 * SIM_TILE_PX, 8000, 0, &cfg);
        /* Long enough for the field to fill: one green a second to a field of
         * two dozen, so a few hundred ticks would be checking the round trip
         * against three of them. */
        step_counting(&s, &cfg, SIM_BTN_THRUST | SIM_BTN_FIRE, SIM_BTN_BOMB,
                      cfg.prize_delay * (cfg.prize_max + 4));

        /* With a prize field on it, because prizes are most of a snapshot
         * and their position is the one thing on the wire that is not stored
         * the way it is sent -- two tile indices out, two Q8 pixel
         * coordinates back. A round trip over an empty field would prove
         * nothing about the part most likely to be wrong. */
        int live = 0;
        for (int i = 0; i < SIM_MAX_PRIZES; i++) live += s.prizes[i].active;
        CHECK(live > 10, "the state under test carries a prize field");

        /* Keep a known linked round in the state. A zero would let the new
         * snapshot field be omitted on both sides while this broad round-trip
         * test still looked healthy. */
        if (s.weapon_count == 0) {
            sim_weapon *round = &s.weapons[s.weapon_count++];
            memset(round, 0, sizeof *round);
            round->spec = gun_of(&cfg, APEX)->spec;
            round->owner = 0;
            round->team = s.ships[0].team;
            round->x = s.ships[0].x;
            round->y = s.ships[0].y;
            round->life = 10;
            round->fuse_target = 255;
        }
        s.weapons[0].link = 0xa1b2c3d4u;

        static uint8_t buf[SIM_PACK_MAX];
        int n = sim_pack(&s, buf, sizeof buf);
        CHECK(n > 0, "a snapshot packs");
        CHECK(sim_unpack(&back, buf, n) == 0, "a snapshot unpacks");
        CHECK(sim_hash(&back) == sim_hash(&s), "the round trip is exact");
        CHECK(back.weapons[0].link == 0xa1b2c3d4u,
              "a gun-volley link survives the snapshot");

        /* Network snapshots never reveal the prize stream. Two otherwise
         * identical states with different future prize decisions produce the
         * same bytes. */
        {
            static uint8_t a_buf[SIM_PACK_MAX], b_buf[SIM_PACK_MAX];
            sim_state other = s;
            other.prize_rng ^= 0x5a5aa5a5u;
            other.prize_timer ^= 37;
            int an = sim_pack_around(&s, a_buf, sizeof a_buf, s.ships[0].x,
                                     s.ships[0].y, 84 * SIM_TILE_PX * 256,
                                     0, 0, 0);
            int bn = sim_pack_around(&other, b_buf, sizeof b_buf, other.ships[0].x,
                                     other.ships[0].y, 84 * SIM_TILE_PX * 256,
                                     0, 0, 0);
            CHECK(an > 0 && an == bn && memcmp(a_buf, b_buf, an) == 0,
                  "network bytes hide prize randomness and timing");
        }

        /* A message longer than this build knows how to read is refused.
         *
         * This is the case that reached a player. Three fields were added to the
         * wire for repel and the browser bundle was not rebuilt, so the server
         * wrote the new layout and the deployed client read the old one --
         * stopping before the new fields, leaving them unread, and reporting
         * success on a state it had misread from that point on. What the player
         * saw was DESTROYED, permanently, on a healthy server.
         *
         * Appending a byte is the same shape as a field added on the far side:
         * the reader lands short of the end. `underflow` never caught it, because
         * that only fires on reading too far. */
        {
            static uint8_t longer[SIM_PACK_MAX + 8];
            memcpy(longer, buf, (size_t)n);
            longer[n] = 0x5a;
            sim_state ignored;
            CHECK(sim_unpack(&ignored, longer, n + 1) != 0,
                  "a snapshot with bytes this build cannot read is refused");
            CHECK(sim_unpack(&ignored, buf, n) == 0,
                  "and the exact same bytes at the right length still unpack");

            uint64_t before = sim_hash(&ignored);
            buf[8] ^= 0x80;
            CHECK(sim_unpack(&ignored, buf, n) != 0,
                  "a malformed snapshot is refused");
            CHECK(sim_hash(&ignored) == before,
                  "and does not partly replace the live state");
            buf[8] ^= 0x80;
        }

        /* And the same for settings, which is the message that actually broke. */
        {
            static uint8_t sbuf[SIM_PACK_MAX + 8];
            int sn = sim_settings_pack(&cfg, sbuf, SIM_PACK_MAX);
            CHECK(sn > 0, "settings pack");
            sim_settings other;
            CHECK(sim_settings_unpack(&other, sbuf, sn) == 0, "settings unpack");
            sbuf[sn] = 0x5a;
            CHECK(sim_settings_unpack(&other, sbuf, sn + 1) != 0,
                  "settings carrying a field this build does not know are refused");
        }
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

            /* Give one visible opponent a capacity upgrade and an unrelated
             * private upgrade. A zero rung would let the wire omit capacity
             * and still pass, while copying the whole upgrade array would
             * restore the information leak this split is meant to keep shut. */
            int public_energy_ship = -1;
            for (int i = 1; i < s.ship_count; i++) {
                if (!s.ships[i].active) continue;
                int64_t dx = (int64_t)s.ships[i].x - cx;
                int64_t dy = (int64_t)s.ships[i].y - cy;
                if (dx * dx + dy * dy > (int64_t)R * R) continue;
                public_energy_ship = i;
                s.ships[i].up[SIM_UP_ENERGY] = 3;
                s.ships[i].up[SIM_UP_SPEED] = 2;
                s.ships[i].energy = sim_eff_max_energy(
                    &cfg.classes[s.ships[i].cls], &s.ships[i]) / 2;
                break;
            }
            CHECK(public_energy_ship >= 0,
                  "a visible opponent can exercise public energy capacity");

            int m = sim_pack_around(&s, buf, sizeof buf, cx, cy, R, 255, 0, 0);
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

            /* Ships and rounds are filtered by the same radius, and that is
             * the half of this that is about cheating rather than bytes: a
             * client is not told where anybody is that it could not lawfully
             * see, so a modified one has nothing beyond its own sight to
             * draw. Flags still travel whole, being few and being objectives
             * every pilot is entitled to know the state of.
             *
             * The seat count is the arena's either way. Indices are identity
             * for the roster, the kill feed and the team lists, so a filtered
             * snapshot keeps them and marks the absent seats inactive. */
            CHECK(cut.ship_count == s.ship_count, "the seat count is the arena's");
            CHECK(cut.flag_count == s.flag_count, "and every flag travels");

            int ship_near = 0, ship_far = 0;
            for (int i = 0; i < s.ship_count; i++) {
                if (!s.ships[i].active) continue;
                int64_t dx = (int64_t)s.ships[i].x - cx;
                int64_t dy = (int64_t)s.ships[i].y - cy;
                if (dx * dx + dy * dy <= (int64_t)R * R) {
                    ship_near++;
                    CHECK(cut.ships[i].active, "a ship inside the radius is sent");
                    CHECK(cut.ships[i].x == s.ships[i].x
                          && cut.ships[i].y == s.ships[i].y,
                          "and its public state arrives unchanged");
                    CHECK((i == 0) == !cut.ships[i].public_only,
                          "only the owner receives private ship state");
                    if (i == 0)
                        CHECK(cut.ships[i].energy == s.ships[i].energy,
                              "the owner's energy travels");
                    else
                        CHECK(cut.ships[i].energy == s.ships[i].energy,
                              "visible remote energy is public");
                    CHECK(cut.ships[i].up[SIM_UP_ENERGY]
                          == s.ships[i].up[SIM_UP_ENERGY],
                          "visible energy capacity is public");
                    if (i == public_energy_ship)
                        CHECK(cut.ships[i].up[SIM_UP_SPEED] == 0,
                              "other visible upgrades remain private");
                } else {
                    ship_far++;
                    CHECK(!cut.ships[i].active,
                          "a ship outside it is not sent at all");
                    CHECK(cut.ships[i].x == 0 && cut.ships[i].y == 0
                          && cut.ships[i].energy == 0,
                          "and leaves nothing behind to read");
                }
            }
            CHECK(ship_near > 0 && ship_far > 0, "the seats straddle the radius");

            /* A round whose fuse latched a seat outside the radius travels
             * unarmed. Without this the client reads the fuse against a seat
             * it was not sent, finds it inactive, and detonates a bomb the
             * server is still flying: an explosion at the edge of the view
             * that never happened. */
            for (uint16_t i = 0; i < cut.weapon_count; i++) {
                uint8_t ft = cut.weapons[i].fuse_target;
                if (ft == 255) continue;
                CHECK(ft < cut.ship_count && cut.ships[ft].active,
                      "an armed fuse names a seat that was sent");
            }

            int wnear = 0;
            for (uint16_t i = 0; i < s.weapon_count; i++) {
                int64_t dx = (int64_t)s.weapons[i].x - cx;
                int64_t dy = (int64_t)s.weapons[i].y - cy;
                if (dx * dx + dy * dy <= (int64_t)R * R) wnear++;
            }
            CHECK(cut.weapon_count == wnear, "only the near rounds are sent");
            for (uint16_t i = 0; i < cut.weapon_count; i++) {
                int64_t dx = (int64_t)cut.weapons[i].x - cx;
                int64_t dy = (int64_t)cut.weapons[i].y - cy;
                CHECK(dx * dx + dy * dy <= (int64_t)R * R,
                      "and every round that arrived is one of them");
            }
        }

        /* Except a pilot's own, which travel however far off they are.
         *
         * This is the minefield. A mine sits for two minutes and the pilot who
         * laid it flies away, so it is the one round that leaves the radius
         * without ending, and a client that stops being told about it draws it
         * detonating and then lays a sixth mine because it can no longer count
         * the five. Measured on alpha, every mine laid left its own layer's
         * snapshot inside seven seconds while the arena flew it on for the
         * best part of a minute.
         *
         * Written as the round the pilot owns rather than as the mine they
         * own: their bullets are inside the radius by construction, so the
         * narrower rule buys nothing and reads as a special case. */
        {
            sim_state m;
            sim_init(&m, 3);
            int layer = sim_spawn(&m, APEX, 0, 2048, 2048, 0, &cfg);
            int other = sim_spawn(&m, APEX, 1, 2200, 2048, 0, &cfg);
            CHECK(layer == 0 && other == 1, "two pilots, two sides");
            step_n(&m, &cfg, SIM_BTN_MINE, 0, 1);
            CHECK(m.weapon_count == 1, "one of them lays a mine");
            /* Somewhere the radius below cannot reach. Moved rather than
             * flown, because what is under test is the filter and not how
             * long the trip takes. */
            m.ships[0].x += 400 * 16 * 256;

            const int32_t R = 84 * 16 * 256;    /* the floor a client gets */
            int32_t vx = m.ships[0].x, vy = m.ships[0].y;
            int n2 = sim_pack_around(&m, buf, sizeof buf, vx, vy, R, 0, 0, 0);
            sim_state mine_seen;
            CHECK(n2 > 0 && sim_unpack(&mine_seen, buf, n2) == 0,
                  "the layer's own snapshot packs");
            CHECK(mine_seen.weapon_count == 1,
                  "and still carries the mine they left behind");
            CHECK(mine_seen.weapons[0].x == m.weapons[0].x
                  && mine_seen.weapons[0].y == m.weapons[0].y
                  && mine_seen.weapons[0].life == m.weapons[0].life,
                  "at the pixel and on the clock it actually has");

            int n3 = sim_pack_around(&m, buf, sizeof buf, vx, vy, R, 1, 1, 0);
            sim_state stranger;
            CHECK(n3 > 0 && sim_unpack(&stranger, buf, n3) == 0,
                  "and so does somebody else's from the same place");
            CHECK(stranger.weapon_count == 0,
                  "which is told nothing about a mine that far away");

            /* 255 is nobody, and it has to be: every round is owned by a seat,
             * so the sentinel can never be somebody by accident. */
            int n5 = sim_pack_around(&m, buf, sizeof buf, vx, vy, R, 255, 255, 0);
            sim_state nobody;
            CHECK(n5 > 0 && sim_unpack(&nobody, buf, n5) == 0, "packs");
            CHECK(nobody.weapon_count == 0, "and carries no round's exception");

            /* And the exception is the owner rather than the distance: from
             * next to the mine, everybody is told about it. */
            int n4 = sim_pack_around(&m, buf, sizeof buf,
                                     m.weapons[0].x, m.weapons[0].y, R, 1, 1, 0);
            sim_state near_by;
            CHECK(n4 > 0 && sim_unpack(&near_by, buf, n4) == 0, "packs");
            CHECK(near_by.weapon_count == 1,
                  "a stranger standing on the minefield sees it");
        }

        /* A negative radius is the whole state, and has to stay bit-identical
         * to it: the replay tool, the golden hashes and every test above pack
         * that way, so a filtered format that changed the unfiltered bytes
         * would be a format change wearing a disguise. */
        {
            int whole = sim_pack_around(&s, buf, sizeof buf, 0, 0, -1, 255, 255,
                                        SIM_PACK_PRIVATE_ALL | SIM_PACK_SECRET);
            CHECK(whole == n, "an unfiltered pack is the same size as sim_pack");
            sim_state all;
            CHECK(sim_unpack(&all, buf, whole) == 0, "and unpacks");
            CHECK(sim_hash(&all) == sim_hash(&s),
                  "and carries the whole arena");
        }

        /* The bitmap is read a byte at a time and a seat count is rarely a
         * multiple of eight, so the seats either side of a byte boundary are
         * where an off-by-one would live. Packed around one seat with a
         * radius of zero, exactly that seat comes back. */
        for (int pick = 0; pick < s.ship_count; pick++) {
            if (!s.ships[pick].active) continue;
            int m = sim_pack_around(&s, buf, sizeof buf,
                                    s.ships[pick].x, s.ships[pick].y, 0, 255,
                                    (uint8_t)pick, 0);
            CHECK(m > 0, "a pack around one seat succeeds");
            sim_state one;
            CHECK(sim_unpack(&one, buf, m) == 0, "and unpacks");
            for (int i = 0; i < s.ship_count; i++) {
                int want = s.ships[i].active
                           && s.ships[i].x == s.ships[pick].x
                           && s.ships[i].y == s.ships[pick].y;
                CHECK(!one.ships[i].active == !want,
                      "each seat is present exactly when it is in range");
            }
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
        sim_settings before = got;
        buf[0] ^= 0xff;
        CHECK(sim_settings_unpack(&got, buf, n) == -1,
              "and something that is not settings at all");
        CHECK(memcmp(&got, &before, sizeof got) == 0,
              "and a refused reload leaves the live tuning intact");
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

    /* A bar above the ceiling comes down to it, rather than wrapping past
     * zero. Adding a tick of recharge before clamping is signed overflow, and
     * the wrapped result was a hugely negative bar the clamp ignored because it
     * only ever looked for too much energy. A live server really produced this:
     * it set INT32_MAX to mean "full", and joining ships spent their first tick
     * at INT32_MIN, one hit from dead. Undefined behavior is also the one thing
     * that could make this core step differently on different platforms, which
     * is the property everything else here depends on. */
    {
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        int32_t cap = sim_eff_max_energy(&cfg.classes[APEX], &s.ships[0]);
        for (int32_t start = 0; start < 3; start++) {
            /* INT32_MAX, one below it, and exactly the cap. */
            s.ships[0].energy = start == 0 ? INT32_MAX
                              : start == 1 ? INT32_MAX - 1 : cap;
            s.ships[0].alive = 1;
            step_n(&s, &cfg, 0, 0, 1);
            CHECK(s.ships[0].energy == cap,
                  "an over-full bar settles at the ceiling");
            CHECK(s.ships[0].energy > 0, "and never wraps negative");
        }
    }

    /* Touching a wormhole puts you somewhere else.
     *
     * The pull was already there and did nothing but bend a course. What a
     * wormhole is for is the other side of it, so contact with the tile itself
     * moves the ship to a spawn point chosen at random and stops it dead: an
     * exit that keeps your velocity puts you through the wall behind wherever
     * you came out. */
    {
        sim_map *wm = malloc(sizeof *wm);
        memset(wm->tile, SIM_TILE_EMPTY, sizeof wm->tile);
        for (int i = 0; i < SIM_MAP_TILES; i++) {
            wm->tile[i] = SIM_TILE_SOLID;
            wm->tile[(size_t)(SIM_MAP_TILES - 1) * SIM_MAP_TILES + i] = SIM_TILE_SOLID;
            wm->tile[(size_t)i * SIM_MAP_TILES] = SIM_TILE_SOLID;
            wm->tile[(size_t)i * SIM_MAP_TILES + SIM_MAP_TILES - 1] = SIM_TILE_SOLID;
        }
        wm->tile[(size_t)512 * SIM_MAP_TILES + 512] = SIM_TILE_WORMHOLE;
        /* Two of them, far apart, so "went to a spawn" cannot be satisfied by
         * standing still. */
        wm->tile[(size_t)300 * SIM_MAP_TILES + 300] = SIM_TILE(SIM_TILE_SPAWN, 0);
        wm->tile[(size_t)700 * SIM_MAP_TILES + 700] = SIM_TILE(SIM_TILE_SPAWN, 0);
        sim_map_index(wm);
        sim_settings wc;
        memset(&wc, 0, sizeof wc);
        sim_settings_baseline(&wc, wm);
        wc.spawn_prizes = 0;

        sim_state s;
        sim_init(&s, 1);
        /* Four tiles above the hole, pointing down at it. Stepped one tick at
         * a time because the interesting state is the tick the warp lands on:
         * a ship still holding thrust is off the spawn tile a second later,
         * which is the game working rather than the test failing. */
        int id = sim_spawn(&s, APEX, 0, 512 * 16, 508 * 16, 32768, &wc);
        int warped = 0;
        for (int t = 0; t < 200 && !warped; t++) {
            ev_counts c = step_counting(&s, &wc, SIM_BTN_THRUST, 0, 1);
            warped = c.warps > 0;
        }
        CHECK(warped, "flying into a wormhole warps the ship");
        int at_a = (s.ships[id].x >> 12) == 300 && (s.ships[id].y >> 12) == 300;
        int at_b = (s.ships[id].x >> 12) == 700 && (s.ships[id].y >> 12) == 700;
        CHECK(at_a || at_b, "and puts it on a spawn tile");
        CHECK(s.ships[id].vx == 0 && s.ships[id].vy == 0,
              "with its speed taken off it");
        CHECK(s.ships[id].alive, "and without killing it");
        free(wm);
    }

    /* Multifire is a switch the pilot holds, not one the prize decides.
     *
     * A fan is worse than a single shot down a corridor, and the add-on
     * arrives from a green rather than by choice, so a pilot who has one needs
     * a way to stop using it. The button toggles on the press rather than
     * while held: this is a state, and a state you have to keep a finger on is
     * a state you cannot fly with. */
    {
        sim_state s;
        sim_init(&s, 1);
        int id = sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        s.ships[id].mods[SIM_TRIG_GUN] = sim_mod_set(0, SIM_MOD_MULTI, 1);
        int fan = 1 + cfg.mod_step[SIM_MOD_MULTI];

        step_n(&s, &cfg, SIM_BTN_FIRE, 0, 1);
        CHECK(s.weapon_count == fan, "multifire fans by default");

        /* Held down, the toggle flips once. */
        step_n(&s, &cfg, SIM_BTN_MULTI, 0, 30);
        CHECK(s.ships[id].multi_off, "the button turns it off");
        s.weapon_count = 0;
        s.ships[id].fire_cooldown[SIM_TRIG_GUN] = 0;
        s.ships[id].fire_cooldown[SIM_TRIG_BOMB] = 0;
        step_n(&s, &cfg, SIM_BTN_FIRE, 0, 1);
        CHECK(s.weapon_count == 1, "and then the gun fires one");
        CHECK(sim_mod_get(s.ships[id].mods[SIM_TRIG_GUN], SIM_MOD_MULTI) == 1,
              "while the add-on is still held");

        /* Released and pressed again, it flips back. */
        step_n(&s, &cfg, 0, 0, 1);
        step_n(&s, &cfg, SIM_BTN_MULTI, 0, 1);
        CHECK(!s.ships[id].multi_off, "a second press turns it back on");
        s.weapon_count = 0;
        s.ships[id].fire_cooldown[SIM_TRIG_GUN] = 0;
        s.ships[id].fire_cooldown[SIM_TRIG_BOMB] = 0;
        step_n(&s, &cfg, SIM_BTN_FIRE, 0, 1);
        CHECK(s.weapon_count == fan, "and the fan is back");

        /* A snapshot landing under a held key does not read as a new press.
         *
         * This is the whole reason last tick's buttons ride the wire.
         * `sim_unpack` clears the state it fills, so a client that took a
         * snapshot mid-press would see an edge the server never saw, and at
         * ten snapshots a second one deliberate press becomes four. */
        {
            static uint8_t buf[1 << 16];
            sim_state s2;
            step_n(&s, &cfg, SIM_BTN_MULTI, 0, 1);   /* down: toggles once */
            CHECK(s.ships[id].multi_off, "the key goes down and it toggles");
            int m = sim_pack_around(&s, buf, sizeof buf, 0, 0, -1, 255, 255,
                                    SIM_PACK_PRIVATE_ALL | SIM_PACK_SECRET);
            CHECK(m > 0, "the state packs");
            CHECK(sim_unpack(&s2, buf, m) == 0, "and reads back");
            CHECK(s2.ships[id].btn_prev == SIM_BTN_MULTI,
                  "with the press still recorded");
            step_n(&s2, &cfg, SIM_BTN_MULTI, 0, 1);  /* still held */
            CHECK(s2.ships[id].multi_off,
                  "so holding it through a snapshot does not toggle again");
        }

        /* A fan that leaves takes the switch with it, so the next one picked
         * up fans. A decline sitting on a hull that has nothing to decline is
         * a setting nobody can see, waiting to surprise whoever finds the
         * green. */
        s.ships[id].mods[SIM_TRIG_GUN] = 0;
        step_n(&s, &cfg, 0, 0, 1);
        CHECK(!s.ships[id].multi_off, "losing the add-on puts the switch back");

        s.ships[id].mods[SIM_TRIG_GUN] = sim_mod_set(0, SIM_MOD_MULTI, 1);
        s.ships[id].fire_cooldown[SIM_TRIG_GUN] = 0;
        s.ships[id].fire_cooldown[SIM_TRIG_BOMB] = 0;
        s.weapon_count = 0;
        step_n(&s, &cfg, SIM_BTN_FIRE, 0, 1);
        CHECK(s.weapon_count == fan, "so the next fan arrives fanning");
    }

    /* And the switch does nothing at all on a hull that has no fan.
     *
     * There is no state to move: turning off an add-on you are not carrying
     * changes no shot, and the client says the key landed by watching this
     * flag, so a flag that moved would be a sound about nothing. */
    {
        sim_state s;
        sim_init(&s, 1);
        int id = sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        CHECK(sim_mod_get(s.ships[id].mods[SIM_TRIG_GUN], SIM_MOD_MULTI) == 0,
              "a fresh Apex carries no fan");

        step_n(&s, &cfg, SIM_BTN_MULTI, 0, 1);
        CHECK(!s.ships[id].multi_off, "and the button leaves the switch alone");
        step_n(&s, &cfg, 0, 0, 1);
        step_n(&s, &cfg, SIM_BTN_MULTI, 0, 1);
        CHECK(!s.ships[id].multi_off, "however many times it is pressed");

        /* So the fan it picks up later arrives fanning: the presses that
         * landed on nothing left nothing behind. */
        s.ships[id].mods[SIM_TRIG_GUN] = sim_mod_set(0, SIM_MOD_MULTI, 1);
        s.ships[id].fire_cooldown[SIM_TRIG_GUN] = 0;
        s.ships[id].fire_cooldown[SIM_TRIG_BOMB] = 0;
        s.weapon_count = 0;
        step_n(&s, &cfg, SIM_BTN_FIRE, 0, 1);
        CHECK(s.weapon_count == 1 + cfg.mod_step[SIM_MOD_MULTI],
              "and a fan picked up afterwards fans");
    }

    /* A hull's box follows its heading. The extents are measured off what
     * the client draws, which is why client/tests/hull_fit_test.lua reads
     * the table they come from; here we check the properties the core
     * depends on. Every hull has all three, none reaches past 23 px in any
     * direction at any heading -- the ceiling the shipped maps were
     * flood-filled and spawn-checked against, now applied to the diagonal
     * corner rather than a square's side -- and a ship flown at a wall
     * nose-first stops at its nose where the same ship drifted in sideways
     * stops at its flank. */
    {
        for (int c = 0; c < cfg.class_count; c++) {
            int64_t fore = cfg.classes[c].fore, aft = cfg.classes[c].aft;
            int64_t w = cfg.classes[c].halfw;
            CHECK(fore > 0 && aft > 0 && w > 0, "every hull has extents");
            CHECK(fore * fore + w * w <= (int64_t)(23 * 256) * (23 * 256),
                  "the nose corner is inside the roster ceiling");
            CHECK(aft * aft + w * w <= (int64_t)(23 * 256) * (23 * 256),
                  "and so is the tail corner");
        }
        CHECK(cfg.classes[0].fore != cfg.classes[0].halfw,
              "an Apex is longer than it is wide");

        sim_map *wm = walled_map();
        for (int y = 0; y < 40; y++)
            for (int x = 0; x < SIM_MAP_TILES; x++)
                wm->tile[(size_t)y * SIM_MAP_TILES + x] = SIM_TILE_SOLID;
        sim_map_index(wm);
        sim_settings hc;
        memset(&hc, 0, sizeof hc);
        sim_settings_baseline(&hc, wm);
        hc.spawn_prizes = 0;
        const int32_t face = 40 * 16 * 256;   /* the wall's south edge */

        /* Nose-first: thrust straight up at the wall and take the closest
         * approach, since holding thrust against a wall bounces. */
        {
            sim_state s;
            sim_init(&s, 1);
            int id = sim_spawn(&s, APEX, 0, 512 * 16, 60 * 16, 0, &hc);
            int32_t lo = s.ships[id].y;
            for (int t = 0; t < 3000; t++) {
                step_n(&s, &hc, SIM_BTN_THRUST, 0, 1);
                if (s.ships[id].y < lo) lo = s.ships[id].y;
            }
            /* One Q8 unit inside the face: the clamp's deliberate -1,
             * which keeps the box's edge strictly out of the wall tile. */
            CHECK(lo - hc.classes[APEX].fore == face - 1,
                  "flown at a wall, an Apex stops at its nose");
        }

        /* Sideways: same hull, same wall, but drifting in flank-first with
         * the nose pointing along it. The stop is the half-width, which for
         * an Apex is ten pixels closer than the nose gets. */
        {
            sim_state s;
            sim_init(&s, 1);
            /* Heading east, so the hull lies along x and its flank faces
             * the wall above. */
            int id = sim_spawn(&s, APEX, 0, 512 * 16, 60 * 16, 16384, &hc);
            int32_t lo = s.ships[id].y;
            for (int t = 0; t < 3000; t++) {
                s.ships[id].vy = -60000;   /* pushed at the wall, no thrust */
                step_n(&s, &hc, 0, 0, 1);
                if (s.ships[id].y < lo) lo = s.ships[id].y;
            }
            CHECK(lo - hc.classes[APEX].halfw == face - 1,
                  "drifted in sideways, it stops at its flank");
            CHECK(hc.classes[APEX].fore - hc.classes[APEX].halfw > 9 * 256,
                  "and the two stops are most of a tile apart");
        }

        /* Rotating against the wall. Parked flank-on a pixel off it, holding
         * a turn sweeps the nose across the wall with nothing moving, which
         * the sliding clamp can never fix. The rule is that the ship gets
         * nudged out or the turn is refused; either way the box never ends a
         * tick inside the wall, and the ship never teleports. */
        {
            sim_state s;
            sim_init(&s, 1);
            int id = sim_spawn(&s, APEX, 0, 512 * 16,
                               41 * 16 + hc.classes[APEX].halfw / 256 + 1,
                               16384, &hc);
            int32_t x0 = s.ships[id].x, y0 = s.ships[id].y;
            int ok = 1;
            for (int t = 0; t < 400 && ok; t++) {
                step_n(&s, &hc, SIM_BTN_LEFT, 0, 1);
                const sim_ship *sh = &s.ships[id];
                /* The box, recomputed here the way the core computes it. */
                int32_t fx = 0, fy = 0;
                {
                    uint16_t hidx = (uint16_t)(sh->heading >> 4);
                    fx = sim_sintab[hidx & 4095];
                    fy = -sim_sintab[(hidx + 1024) & 4095];
                }
                int32_t afx = fx < 0 ? -fx : fx, afy = fy < 0 ? -fy : fy;
                int32_t half = (hc.classes[APEX].fore
                                + hc.classes[APEX].aft) / 2;
                int32_t off = (hc.classes[APEX].fore
                               - hc.classes[APEX].aft) / 2;
                int32_t bx = sh->x + (int32_t)(((int64_t)off * fx) >> 15);
                int32_t by = sh->y + (int32_t)(((int64_t)off * fy) >> 15);
                int32_t hx = (int32_t)(((int64_t)half * afx
                                        + (int64_t)hc.classes[APEX].halfw * afy) >> 15);
                int32_t hy = (int32_t)(((int64_t)half * afy
                                        + (int64_t)hc.classes[APEX].halfw * afx) >> 15);
                for (int32_t ty = (by - hy) >> 12; ty <= (by + hy) >> 12; ty++)
                    for (int32_t tx = (bx - hx) >> 12; tx <= (bx + hx) >> 12; tx++)
                        if (SIM_TILE_CLASS(sim_tile_at(wm, tx, ty))
                                == SIM_TILE_SOLID)
                            ok = 0;
                int32_t moved_x = sh->x - x0, moved_y = sh->y - y0;
                if (moved_x < 0) moved_x = -moved_x;
                if (moved_y < 0) moved_y = -moved_y;
                CHECK(moved_x < 16 * 256 && moved_y < 16 * 256,
                      "the nudge is pixels, never a teleport");
                x0 = sh->x;
                y0 = sh->y;
            }
            CHECK(ok, "turning beside a wall never leaves the box inside it");
        }
        free(wm);
    }

    /* A round faster than a hull is thick still hits it.
     *
     * The hit test used to sample once per tick, at the end of the tick's
     * travel. A Cipher's flank is 12 px thick and a round can cross more than
     * that in one tick, so a crossing could land entirely between two samples
     * and pass through, deterministically, on both ends of the wire at once.
     * The sweep walks the travel in 4 px samples instead. The velocity here
     * is written onto the round directly, standing in for any zone that
     * retunes its weapons faster than the baseline flies. */
    {
        const int CIPHER = 4;
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, CIPHER, 0, 8192, 8192, 0, &cfg);

        sim_weapon *w = &s.weapons[s.weapon_count++];
        memset(w, 0, sizeof *w);
        w->spec = gun_of(&cfg, APEX)->spec;
        w->owner = 1;          /* nobody's round arrives at its owner */
        w->team = 1;
        w->life = 10;
        /* 16 px a tick, eastward, from 8 px short of the near flank: the
         * endpoint lands 2 px past the far one, so the old single sample
         * would have seen empty space on both sides of the crossing. */
        w->x = 8184 * 256;
        w->y = 8192 * 256;
        w->vx = 16 * 65536;

        ev_counts c = step_counting(&s, &cfg, 0, 0, 1);
        CHECK(c.hits == 1, "a 16 px/tick round cannot cross a 12 px flank");
        CHECK(s.weapon_count == 0, "and it ended on the hull it hit");
    }

    /* And the same round cannot cross a wall one tile thick. */
    {
        for (int ty = 500; ty < 525; ty++)
            m->tile[(size_t)ty * SIM_MAP_TILES + 512] = SIM_TILE_SOLID;
        sim_map_index(m);

        sim_state s;
        sim_init(&s, 1);
        sim_weapon *w = &s.weapons[s.weapon_count++];
        memset(w, 0, sizeof *w);
        w->spec = gun_of(&cfg, APEX)->spec;
        w->owner = 1;
        w->team = 1;
        w->life = 10;
        /* The wall column covers x 8192..8208 px. From 8180 at 48 px a tick
         * the endpoint is 8228, past the far face, so the endpoint sample
         * alone would have read clear air. */
        w->x = 8180 * 256;
        w->y = 8072 * 256;   /* tile 504, inside the column's run */
        w->vx = 48 * 65536;

        step_n(&s, &cfg, 0, 0, 1);
        CHECK(s.weapon_count == 0, "a 48 px/tick round cannot cross a wall");

        for (int ty = 500; ty < 525; ty++)
            m->tile[(size_t)ty * SIM_MAP_TILES + 512] = SIM_TILE_EMPTY;
        sim_map_index(m);
    }

    /* Gunners. A ride is refused below a full bar, granted from anywhere in
     * the arena, and ends when the carrier does. */
    {
        sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);   /* the carrier */
        sim_spawn(&s, APEX, 0, 2000, 2000, 0, &cfg);   /* half the map away */
        sim_spawn(&s, APEX, 1, 8192, 8300, 0, &cfg);   /* the other side */

        CHECK(s.ships[1].carrier == SIM_NO_CARRIER, "a fresh ship rides nobody");
        CHECK(sim_attach(&s, &cfg, 2, 0) == -1, "an enemy cannot ride you");
        CHECK(sim_attach(&s, &cfg, 1, 1) == -1, "a ship cannot ride itself");

        s.ships[1].energy -= 1;
        CHECK(sim_attach(&s, &cfg, 1, 0) == -1, "a ride needs a full bar");
        s.ships[1].energy += 1;

        CHECK(sim_attach(&s, &cfg, 1, 0) == 0, "a teammate may be ridden");
        CHECK(s.ships[1].x == s.ships[0].x && s.ships[1].y == s.ships[0].y,
              "attaching crosses the map");
        CHECK(s.ships[1].energy < sim_eff_max_energy(&cfg.classes[APEX],
                                                     &s.ships[1]) / 4,
              "and arrives with almost nothing");
        CHECK(sim_gunners(&s, 0) == 1, "the carrier counts one gunner");
        CHECK(sim_attach(&s, &cfg, 0, 1) == -1, "a gunner cannot be ridden");

        /* Riding is not flying: the gunner keeps the carrier's position
         * whatever it holds down, and turns while it does. */
        uint16_t was = s.ships[1].heading;
        step_n(&s, &cfg, SIM_BTN_THRUST, SIM_BTN_THRUST | SIM_BTN_LEFT, 30);
        CHECK(s.ships[1].x == s.ships[0].x && s.ships[1].y == s.ships[0].y,
              "a gunner rides where the carrier is");
        CHECK(s.ships[1].heading != was, "a gunner still turns");

        /* And the carrier pays for the passenger, once. */
        int32_t one = sim_eff_thrust(&cfg.classes[APEX], &s.ships[0]);
        CHECK(cfg.classes[APEX].gunner_thrust > 0, "carrying costs thrust");
        CHECK(one > 0, "the carrier still has thrust");

        s.ships[0].energy = 1;
        s.ships[2].x = s.ships[0].x;
        s.ships[2].y = s.ships[0].y + 200 * 256;
        s.ships[2].heading = 0;
        int died = 0;
        for (int tick = 0; tick < 400 && !died; tick++) {
            sim_state next;
            sim_events ev;
            sim_input fire = {2, SIM_BTN_FIRE};
            sim_step(&next, &s, &fire, 1, &cfg, &ev);
            s = next;
            for (uint16_t e = 0; e < ev.count; e++)
                if (ev.e[e].type == SIM_EV_DEATH && ev.e[e].a == 0) died = 1;
        }
        CHECK(died, "the carrier dies in the weapon phase");
        CHECK(s.ships[1].carrier == SIM_NO_CARRIER,
              "the death snapshot already drops its gunners");
    }

    /* --- where a ship comes back ------------------------------------------
     *
     * Two arrangements behind one number, so both are measured against the
     * same map: an empty room inside a border, with four spawn tiles marked
     * for team 0 well away from the center.
     */
    {
        sim_map *sm = malloc(sizeof *sm);
        memcpy(sm, m, sizeof *sm);
        const int SPAWN_TX[4] = {100, 300, 700, 900};
        for (int i = 0; i < 4; i++)
            sm->tile[(size_t)200 * SIM_MAP_TILES + SPAWN_TX[i]] =
                SIM_TILE(SIM_TILE_SPAWN, 0);
        sim_map_index(sm);

        sim_settings sc;
        memset(&sc, 0, sizeof sc);
        sim_settings_baseline(&sc, sm);
        sc.spawn_prizes = 0;
        sc.respawn_delay = 1;

        CHECK(sc.spawn_radius == 0, "the baseline spawns on the map's tiles");
        CHECK(sc.show_spawns == 1, "and a client marks them");

        /* Tiles: `nth` walks them and the position is the tile's middle, not
         * its corner. The corner is where two of the three callers used to
         * put a ship, which left a hull sitting eight pixels out of the gap
         * its tile had been checked for. */
        {
            sim_state s;
            sim_init(&s, 7);
            int32_t x = 0, y = 0;
            int seen[4] = {0, 0, 0, 0};
            for (uint32_t n = 0; n < 4; n++) {
                sim_spawn_point(&s, &sc, 0, APEX, n, &x, &y);
                CHECK(y == 200 * SIM_TILE_PX * 256 + SIM_TILE_PX * 128,
                      "a tile spawn lands on the middle of its row");
                for (int i = 0; i < 4; i++)
                    if (x == SPAWN_TX[i] * SIM_TILE_PX * 256
                            + SIM_TILE_PX * 128)
                        seen[i] = 1;
            }
            CHECK(seen[0] && seen[1] && seen[2] && seen[3],
                  "four arrivals in a row take the four tiles");
        }

        /* Death redraws it. Before this a spawn was fixed for the length of a
         * visit: whichever tile the door handed you was yours until you left,
         * so this asks for more than one tile across a run of deaths rather
         * than for any particular one. */
        {
            sim_state s;
            sim_init(&s, 11);
            sim_spawn(&s, APEX, 0, 500 * SIM_TILE_PX, 500 * SIM_TILE_PX, 0, &sc);
            int32_t first = 0;
            int moved = 0;
            for (int round = 0; round < 24; round++) {
                s.ships[0].alive = 0;
                s.ships[0].respawn_at = 1;
                step_n(&s, &sc, 0, 0, 1);
                CHECK(s.ships[0].alive == 1, "the delay ran out and it flew");
                if (round == 0) first = s.ships[0].x;
                else if (s.ships[0].x != first) moved = 1;
                CHECK(s.ships[0].x == s.ships[0].spawn_x,
                      "and the stored start moved with it, for the door warp");
            }
            CHECK(moved, "a run of deaths does not reuse one tile");
        }

        /* The radius lands you near one of the map's points rather than on
         * it. Near, and not somewhere else: the point still decides which part
         * of the map a side comes back to, which is the whole difference from
         * the arrangement this replaced. */
        {
            sim_settings rc = sc;
            rc.spawn_radius = 40;
            sim_state s;
            sim_init(&s, 3);
            const int32_t reach = 40 * SIM_TILE_PX * 256;
            const int32_t row = 200 * SIM_TILE_PX * 256 + SIM_TILE_PX * 128;
            int off_point = 0;
            for (uint32_t n = 0; n < 200; n++) {
                int32_t x = 0, y = 0;
                sim_spawn_point(&s, &rc, 0, APEX, n, &x, &y);
                int near_one = 0;
                for (int i = 0; i < 4; i++) {
                    int32_t px = SPAWN_TX[i] * SIM_TILE_PX * 256
                               + SIM_TILE_PX * 128;
                    if (x >= px - reach && x <= px + reach
                            && y >= row - reach && y <= row + reach)
                        near_one = 1;
                }
                CHECK(near_one, "a radius spawn stays within reach of a point");
                if (x != SPAWN_TX[0] * SIM_TILE_PX * 256 + SIM_TILE_PX * 128
                        && y != row)
                    off_point = 1;
            }
            CHECK(off_point, "and does not sit exactly on one every time");
        }

        /* A map naming no starts at all is the one case where the radius
         * scatters about the middle, which is what the original did before it
         * had spawn points. */
        {
            sim_settings bc;
            memset(&bc, 0, sizeof bc);
            sim_settings_baseline(&bc, m);   /* the plain walled map: no spawns */
            bc.spawn_radius = 30;
            sim_state s;
            sim_init(&s, 17);
            const int32_t mid = (SIM_MAP_TILES / 2) * SIM_TILE_PX * 256
                              + SIM_TILE_PX * 128;
            const int32_t reach = 30 * SIM_TILE_PX * 256;
            for (uint32_t n = 0; n < 100; n++) {
                int32_t x = 0, y = 0;
                sim_spawn_point(&s, &bc, 0, APEX, n, &x, &y);
                CHECK(x >= mid - reach && x <= mid + reach
                          && y >= mid - reach && y <= mid + reach,
                      "with no points to aim at, the middle is the point");
            }
        }

        /* Deterministic, which is the whole reason the roll is in here rather
         * than in the room: a client predicting a respawn has to land on the
         * tile the server did. */
        {
            sim_settings rc = sc;
            rc.spawn_radius = 60;
            sim_state a, b;
            sim_init(&a, 99);
            sim_init(&b, 99);
            int same = 1;
            for (uint32_t n = 0; n < 50; n++) {
                int32_t ax = 0, ay = 0, bx = 0, by = 0;
                sim_spawn_point(&a, &rc, 0, APEX, n, &ax, &ay);
                sim_spawn_point(&b, &rc, 0, APEX, n, &bx, &by);
                if (ax != bx || ay != by) same = 0;
            }
            CHECK(same, "one seed, one sequence of spawn points");
        }

        /* A radius wider than the map means anywhere, the way the original's
         * 1024 did, and lands inside the border rather than on it. */
        {
            sim_settings rc = sc;
            rc.spawn_radius = 4000;
            sim_state s;
            sim_init(&s, 5);
            for (uint32_t n = 0; n < 200; n++) {
                int32_t x = 0, y = 0;
                sim_spawn_point(&s, &rc, 0, APEX, n, &x, &y);
                CHECK(SIM_TILE_CLASS(sim_tile_at(sm, x >> 12, y >> 12))
                          != SIM_TILE_SOLID,
                      "a spawn anywhere is still not inside a wall");
            }
        }

        /* And the settings survive a round trip, which is what lets a client
         * predict any of the above. */
        {
            sim_settings rc = sc, got;
            rc.spawn_radius = 133;
            rc.show_spawns = 0;
            uint8_t buf[SIM_PACK_MAX];
            int n = sim_settings_pack(&rc, buf, sizeof buf);
            CHECK(n > 0, "settings with a spawn radius pack");
            memset(&got, 0, sizeof got);
            got.map = sm;
            CHECK(sim_settings_unpack(&got, buf, n) == 0, "and unpack");
            CHECK(got.spawn_radius == 133, "the radius crosses the wire");
            CHECK(got.show_spawns == 0, "and so does the mark");
        }

        free(sm);
    }

    /* A long mixed run checks relationships rather than one scripted answer.
     * The seed is fixed so a failure can be replayed, but inputs, hull changes,
     * side changes, attachments, weapons, deaths, respawns, flags, and greens
     * still meet in combinations the examples above do not enumerate. */
    {
        sim_settings mixed = cfg;
        mixed.prize_delay = 7;
        mixed.prize_max = 48;
        mixed.respawn_delay = 25;
        mixed.flag_drop_cooldown = 5;
        sim_state s;
        sim_init(&s, 0x71a9c3u);
        uint32_t random = 0x4d3b2a19u;
        for (int i = 0; i < 12; i++) {
            int32_t x = 7900 + (i % 4) * 70;
            int32_t y = 7900 + (i / 4) * 70;
            CHECK(sim_spawn(&s, (uint8_t)(i % mixed.class_count),
                            (uint8_t)(i % 3), x, y,
                            (uint16_t)next_random(&random), &mixed) == i,
                  "the invariant run seats every pilot");
        }
        sim_add_flag(&s, 7950, 7950);
        sim_add_flag(&s, 8050, 8050);
        sim_add_flag(&s, 8150, 7950);

        const uint16_t buttons = SIM_BTN_LEFT | SIM_BTN_RIGHT | SIM_BTN_THRUST
                                 | SIM_BTN_REVERSE | SIM_BTN_FIRE | SIM_BTN_BOMB
                                 | SIM_BTN_USE | SIM_BTN_SLOT_MASK | SIM_BTN_MULTI
                                 | SIM_BTN_MINE;
        for (int tick = 0; tick < 12000; tick++) {
            sim_input in[12];
            for (int i = 0; i < 12; i++) {
                in[i].ship = (uint8_t)i;
                in[i].buttons = (uint16_t)next_random(&random) & buttons;
            }

            if (tick % 173 == 0) {
                uint8_t i = (uint8_t)(next_random(&random) % 12);
                uint8_t action = (uint8_t)(next_random(&random) % 3);
                if (action == 0)
                    sim_set_ship_class(&s, &mixed, i,
                                       (uint8_t)(next_random(&random)
                                                 % mixed.class_count));
                else if (action == 1)
                    sim_set_ship_team(&s, &mixed, i,
                                      (uint8_t)(next_random(&random) % 3));
                else
                    sim_attach(&s, &mixed, i,
                               (uint8_t)(next_random(&random) % 12));
            }

            sim_state next;
            sim_step(&next, &s, in, 12, &mixed, NULL);
            s = next;
            check_state_invariants(&s, &mixed);

            if (tick % 127 == 0) {
                static uint8_t packed[SIM_PACK_MAX];
                sim_state decoded;
                int n = sim_pack(&s, packed, sizeof packed);
                CHECK(n > 0, "an invariant state packs");
                CHECK(sim_unpack(&decoded, packed, n) == 0,
                      "an invariant state unpacks");
                CHECK(sim_hash(&decoded) == sim_hash(&s),
                      "an invariant state survives the wire exactly");
            }
        }
    }

    free(m);
    if (failures == 0) printf("all tests passed\n");
    return failures ? 1 : 0;
}
