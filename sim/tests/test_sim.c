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
                          <= (mod == SIM_MOD_MULTI ? SIM_MOD_MULTI_MAX
                                                   : SIM_MOD_MAX),
                      "an add-on stays inside the bits it is packed into");
        }
        for (int charge = 0; charge < SIM_MAX_CHARGES; charge++) {
            CHECK(sh->charge[charge] <= SIM_CHARGE_MAX,
                  "a rack stays inside its ceiling");
            CHECK(cfg->charge[charge] != SIM_NO_PATTERN
                      || sh->charge[charge] == 0,
                  "no ammunition for a charge kind this zone does not have");
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
    sim_map_size(m, SIM_MAP_TILES, SIM_MAP_TILES);
    for (int i = 0; i < SIM_MAP_TILES; i++) {
        SIM_MAP_AT(m, i, 0) = SIM_TILE_SOLID;
        SIM_MAP_AT(m, i, SIM_MAP_TILES - 1) = SIM_TILE_SOLID;
        SIM_MAP_AT(m, 0, i) = SIM_TILE_SOLID;
        SIM_MAP_AT(m, SIM_MAP_TILES - 1, i) = SIM_TILE_SOLID;
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
    int fires, hits, deaths, bounces, spawns, warps, predicted_deaths;
    /* Streaks, and who the last one belonged to, since a count alone cannot
     * say the arena named the right pilot. 255 for nobody. */
    int streaks;
    uint8_t streak_ship;
    int32_t streak_len;
} ev_counts;

static ev_counts step_counting(sim_state *s, const sim_settings *cfg,
                               uint16_t b0, uint16_t b1, int n) {
    ev_counts c = {0, 0, 0, 0, 0, 0, 0, 0, 255, 0};
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
                case SIM_EV_WARP: c.warps++; break;
                case SIM_EV_STREAK:
                    c.streaks++;
                    c.streak_ship = ev.e[e].a;
                    c.streak_len = ev.e[e].v;
                    break;
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

/* How much of one kit slot a pilot is holding, which is the check that a
 * dealt kit put the counts where the kit said. The core keeps this rule to
 * itself, so the test carries its own copy. */
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

/* Hand this ship a random pile of extra slots on top of its profile.
 *
 * A pilot cannot do this: what a hull flies with is its profile and nothing
 * else. The long mixed run does it anyway, because the point there is that no
 * reachable combination of counts, hull changes and side changes can put the
 * state somewhere the invariants refuse, and `sim_grant` clamping every slot
 * is the thing being tested. */
static void random_kit(sim_ship *sh, const sim_settings *cfg, uint32_t *rng) {
    int grants = (int)(next_random(rng) % 31);
    for (int i = 0; i < grants; i++)
        sim_grant(sh, cfg, (uint8_t)(next_random(rng) % SIM_SLOT_COUNT));
}

/* Does a bomb thrown up the screen end on a hull, with an enemy parked `off`
 * px to the side of the line it flies along? Answers with the tick it ended
 * on that hull, or -1 for anything else.
 *
 * Ending on a hull and running out of life both report SIM_EV_EXPIRE, and the
 * second is not an explosion: a bomb that crosses the arena and times out has
 * arrived at nothing. Only the hull the round ended on tells them apart, which
 * is what `b` carries, so that is what this reads. Counting the expiry as a
 * hit is exactly the mistake this test was written to catch, and the first cut
 * of it made that mistake itself.
 *
 * The settings come from the caller, so the same scene can be put to a zone
 * and to a prediction client and the two answers compared. `prox` is the
 * proximity rung; with none the bomb has to actually touch the hull, which is
 * a different question and worth asking separately. */
/* The tick a round seat zero fires ends on a hull, or -1 if it never does.
 * `btn` is the trigger pulled: the bomb for the fuse and contact cases, the
 * gun for the one that says a bullet still lands where a bomb no longer
 * does. */
static int landed(const sim_settings *c, int cls, int off, int prox,
                  uint16_t btn) {
    sim_state s;
    sim_init(&s, 1);
    sim_spawn(&s, (uint8_t)cls, 0, 8192, 8192, 0, c);
    sim_spawn(&s, (uint8_t)cls, 1, 8192 + off, 8192 - 300, 0, c);
    if (prox)
        s.ships[0].mods[SIM_TRIG_BOMB] =
            sim_mod_set(0, SIM_MOD_PROX, (uint8_t)prox);
    sim_state tmp;
    sim_events ev;
    for (int t = 0; t < 400; t++) {
        sim_input in[2];
        in[0].ship = 0;
        in[0].buttons = (uint16_t)(t == 0 ? btn : 0);
        in[1].ship = 1;
        in[1].buttons = 0;
        sim_step(&tmp, &s, in, 2, c, &ev);
        s = tmp;
        for (int i = 0; i < ev.count; i++)
            if (ev.e[i].type == SIM_EV_EXPIRE && ev.e[i].b != 255) return t;
    }
    return -1;
}

static int bombed(const sim_settings *c, int cls, int off, int prox) {
    return landed(c, cls, off, prox, SIM_BTN_BOMB);
}

/* A sim_state is 79 KB. Clang at -O0 gives block locals separate stack slots
 * even when their lifetimes do not overlap, so entered-once cases stay in
 * static storage. Loop locals remain automatic because each iteration needs
 * a fresh value. The Makefile caps every test function's frame as a backstop. */
enum { APEX = 0, ANVIL = 3 };

/* Strip the build every hull arrives on, in place.
 *
 * Most of this file is about physics: what a round does to a wall, how a fuse
 * arms, where a blast reaches. Those tests want one plain round leaving one
 * hull, and the row a pilot arrives on is a whole ship: a second rung on both
 * weapons, a gun that bounces, a fuse and shrapnel on the bomb. `main` strips
 * it once so that every test below flies a bare hull and the ones that are
 * actually about a build deal themselves one. */
static void bare_kits(sim_settings *cfg) {
    for (int i = 0; i < SIM_MAX_CLASSES; i++)
        memset(cfg->classes[i].kit, 0, sizeof cfg->classes[i].kit);
}

static void test_flight_and_damage(const sim_settings *base) {
    sim_settings cfg = *base;
    /* Every ship below spawns bare unless a test hands it a kit. A pilot in
     * a real room is dealt one at the seat; here a "does one trigger pull
     * make one bullet" test wants nothing in the way of the answer. */

    /* Footprint is the roster's only built-in stat, so every hull spends the
     * same target-area budget. Aspect ratio and pivot placement may differ.
     * Check the settings the simulation actually received rather than the
     * source table that built them. */
    for (int c = 0; c < cfg.class_count; c++) {
        const sim_ship_class *h = &cfg.classes[c];
        int64_t area = (int64_t)(h->fore + h->aft) * (2 * h->halfw);
        CHECK(area == (int64_t)625 * 256 * 256,
              "every hull has 625 square pixels of target area");
        int64_t reach = h->fore > h->aft ? h->fore : h->aft;
        CHECK(reach * reach + (int64_t)h->halfw * h->halfw
                  <= (int64_t)23 * 23 * 256 * 256,
              "every hull stays inside the map corner-reach ceiling");
    }

    /* Thrust at heading 0 moves up (-y) and nowhere else. */
    {
        static sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        step_n(&s, &cfg, SIM_BTN_THRUST, 0, 100);
        CHECK(s.ships[0].vy < 0, "thrust up gives negative vy");
        CHECK(s.ships[0].vx == 0, "thrust up gives zero vx");
        CHECK(s.ships[0].y < 8192 * 256, "ship moved up");
    }

    /* No drag: coasting preserves velocity exactly, forever. */
    {
        static sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        step_n(&s, &cfg, SIM_BTN_THRUST, 0, 50);
        int32_t vy = s.ships[0].vy;
        step_n(&s, &cfg, 0, 0, 1000);
        CHECK(s.ships[0].vy == vy, "coasting preserves velocity exactly");
    }

    /* Speed clamps at the class maximum. */
    {
        static sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        step_n(&s, &cfg, SIM_BTN_THRUST, 0, 400);
        int64_t v = -(int64_t)s.ships[0].vy;
        int32_t cap = sim_eff_speed(&cfg.classes[APEX], &s.ships[0]);
        CHECK(v <= cap, "speed does not exceed the effective cap");
        CHECK(v > cap - 2048, "speed reaches near the effective cap");
        CHECK(cap == cfg.classes[APEX].max_speed,
              "which for a hull nobody upgrades is its only speed");
    }

    /* Energy recharges to the cap and stops there. */
    {
        static sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        s.ships[0].energy = 0;
        step_n(&s, &cfg, 0, 0, 10);
        CHECK(s.ships[0].energy > 0, "energy recharges");
        /* Four thousand ticks is deliberately longer than the zero-point
         * hull needs. Its 1070 recharge fills a 1475 bar in about fourteen
         * seconds, and this check is about reaching the cap rather than an
         * exact recovery clock. */
        step_n(&s, &cfg, 0, 0, 4000);
        CHECK(s.ships[0].energy == sim_eff_max_energy(&cfg.classes[APEX], &s.ships[0]),
              "energy clamps at the effective maximum");
    }

    /* Firing costs energy, respects the cooldown, and creates a weapon. */
    {
        sim_settings w = cfg;
        bare_kits(&w);
        static sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &w);
        int32_t e0 = s.ships[0].energy;
        step_n(&s, &w, SIM_BTN_FIRE, 0, 1);
        CHECK(s.weapon_count == 1, "firing creates one weapon");
        CHECK(s.ships[0].energy < e0, "firing costs energy");
        step_n(&s, &w, SIM_BTN_FIRE, 0, 5);
        CHECK(s.weapon_count == 1, "cooldown blocks a second shot");
        step_n(&s, &w, SIM_BTN_FIRE, 0, 25);
        CHECK(s.weapon_count == 2, "cooldown expires and the next shot fires");
    }

    /* A pull throws what the build says and the hull has no opinion: the same
     * spray on two different hulls throws the same rounds. */
    {
        static sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        sim_spawn(&s, ANVIL, 1, 8192, 12000, 0, &cfg);
        for (int i = 0; i < 2; i++)
            s.ships[i].mods[SIM_TRIG_GUN] = sim_mod_set(0, SIM_MOD_MULTI, 1);
        step_n(&s, &cfg, SIM_BTN_FIRE, SIM_BTN_FIRE, 1);
        CHECK(s.weapon_count == 4, "one rung of spray is a pair, on either hull");
    }

    /* A bullet travels away from its firer and expires on its own. */
    {
        sim_settings w = cfg;
        bare_kits(&w);
        static sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &w);
        step_n(&s, &w, SIM_BTN_FIRE, 0, 1);
        int32_t y0 = s.weapons[0].y;
        step_n(&s, &w, 0, 0, 10);
        CHECK(s.weapon_count == 1 && s.weapons[0].y < y0, "bullet moves up");
        step_n(&s, &w, 0, 0, gun_spec(&w, APEX)->life + 5);
        CHECK(s.weapon_count == 0, "bullet expires");
    }

    /* A bullet damages an enemy in its path and eventually kills it. */
    {
        static sim_state s;
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
     * faster than it recharges dies. A hit takes two thirds of the listed 200,
     * so a zero-point 1475-energy hull takes twelve hits before recharge.
     *
     * This asserted the opposite until the firing costs were corrected. A
     * bullet used to cost 35% of a full bar, so an attacker ran itself dry
     * long before the target was in danger, and nothing could ever die at
     * range. That was a bug wearing a test as an alibi. */
    {
        static sim_state s;
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
        static sim_state s;
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
        bare_kits(&w);
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
        static sim_state chase;
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
        static sim_state d;
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

    /* BBombDamagePercent: a pilot whose bombs bounce pays for it on every
     * bomb, whether or not this one bounced. Two pilots on the same hull,
     * differing in the add-on alone, since that is what carries the trait now
     * that the roster does not. */
    {
        sim_settings w = cfg;
        w.bomb_safety = 0;
        w.bbomb_damage = 500;
        int32_t dealt[2];
        for (int bouncer = 0; bouncer < 2; bouncer++) {
            sim_state s;
            sim_init(&s, 1);
            sim_spawn(&s, APEX, 0, 8192, 8192, 0, &w);
            sim_spawn(&s, APEX, 1, 8192, 8192 - 400, 0, &w);
            if (bouncer)
                sim_grant(&s.ships[0], &w,
                          SIM_SLOT_MOD(SIM_TRIG_BOMB, SIM_MOD_BOUNCE));
            int32_t e0 = s.ships[1].energy;
            step_n(&s, &w, SIM_BTN_BOMB, 0, 1);
            s.weapons[0].x = s.ships[1].x;
            s.weapons[0].y = s.ships[1].y;
            s.weapons[0].vx = s.weapons[0].vy = 0;
            /* The bomber stays where it fired, well clear of the blast, so
             * the add-on is the only thing that differs. */
            step_n(&s, &w, 0, 0, 3);
            dealt[bouncer] = e0 - s.ships[1].energy;
        }
        CHECK(dealt[0] > 0, "a plain bomb lands");
        CHECK(dealt[1] < dealt[0], "and a bouncing pilot's lands softer");
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
     * however many gun rungs were held.
     *
     * Read off the fragments rather than off a victim's energy, because a
     * fragment born on top of somebody is inside InactiveShrapDamage's first
     * quarter second and does almost nothing whatever rung it is. What the
     * round carries is the mechanism; the damage is `damage_up` applied to
     * it, which the spec check below pins.
     */
    {
        sim_settings w = cfg;
        w.bomb_safety = 0;
        for (int k = 1; k < SIM_MAX_RUNGS; k++) {
            const sim_weapon_spec *fs =
                &w.specs[w.patterns[w.mod_splinter[k]].spec];
            CHECK(fs->damage_up > 0,
                  "a fragment's damage climbs with the rung that threw it");
        }

        /* Two rungs, written here, because the shipped roster names one each
         * and this is about the rung a fragment inherits rather than about
         * anybody climbing to it. */
        w.classes[APEX].trigger[SIM_TRIG_GUN][1] =
            cfg.classes[ANVIL].trigger[SIM_TRIG_GUN][0];
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
        static sim_state s;
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

}

static void test_maps(const sim_settings *base) {
    sim_settings cfg = *base;

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

        static sim_state s;
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
            static sim_state in_zone, open;
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
        static sim_state g;
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
        static sim_state t;
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
            static sim_state s;
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
        /* And caught in a blank spot *inside* the wall, where the tile under
         * the hull's center is not a door at all.
         *
         * A hull is wider than a tile, so a pilot sitting in an open tile with
         * doors either side has a box overlapping them, and when the doors come
         * down the collision below has both axes blocked. The crush warp above
         * asked what the tile under the center point was, which here is open
         * ground, so it did not fire and the pilot sat inside the laser wall
         * until it opened again. Reported from play: "rather than warping, my
         * ship got frozen inside the laser wall".
         *
         * A door line two tiles thick with one tile of it left open, which is a
         * gap a hull fits in and cannot leave. */
        {
            sim_map *gm = walled_map();
            for (int ty = 503; ty <= 505; ty++)
                for (int tx = 503; tx <= 507; tx++)
                    gm->tile[(size_t)ty * SIM_MAP_TILES + tx] =
                        SIM_TILE(SIM_TILE_DOOR, 0);
            /* The blank spot. */
            gm->tile[(size_t)504 * SIM_MAP_TILES + 505] =
                SIM_TILE(SIM_TILE_EMPTY, 0);
            sim_map_index(gm);
            sim_settings gc;
            memset(&gc, 0, sizeof gc);
            sim_settings_baseline(&gc, gm);

            static sim_state s;
            sim_init(&s, 1);
            uint32_t t0 = 0;
            while (!sim_door_open(&gc, t0, 0)) t0++;
            s.tick = t0;
            int id = sim_spawn(&s, APEX, 0, 505 * 16, 504 * 16, 0, &gc);
            int32_t sx = s.ships[id].spawn_x, sy = s.ships[id].spawn_y;
            CHECK(SIM_TILE_CLASS(sim_tile_at(gm, 505, 504)) == SIM_TILE_EMPTY,
                  "the hull's own tile is open ground");
            CHECK(SIM_TILE_CLASS(sim_tile_at(gm, 504, 504)) == SIM_TILE_DOOR
                  && SIM_TILE_CLASS(sim_tile_at(gm, 506, 504)) == SIM_TILE_DOOR,
                  "with a door either side of it");

            ev_counts c = step_counting(&s, &gc, 0, 0, gc.door_period);
            CHECK(c.warps > 0, "a door shutting around a ship warps it too");
            CHECK(s.ships[id].x == sx && s.ships[id].y == sy,
                  "and puts it back where it started");
            CHECK(s.ships[id].alive, "without killing it");
            free(gm);
        }

        CHECK(crossed, "an open door lets the same ship through");


        /* A flag dropped by a dying carrier, which never asked about the
         * tile either: killed in an open doorway they left it inside the
         * door for the clock to shut on, and a flag nobody can reach is a
         * round nobody can finish. */
        {
            sim_settings dc2 = dc;
            static sim_state s;
            sim_init(&s, 3);
            uint32_t t0 = 0;
            while (!sim_door_open(&dc2, t0, 0)) t0++;
            s.tick = t0;
            int killer = sim_spawn(&s, APEX, 0, 505 * 16, 510 * 16, 0, &dc2);
            int prey = sim_spawn(&s, APEX, 1, 505 * 16, 504 * 16, 0, &dc2);
            CHECK(SIM_TILE_CLASS(sim_tile_at(dm, 505, 504)) == SIM_TILE_DOOR,
                  "the victim is standing in the doorway");
            (void)killer;
            s.ships[prey].energy = 1;

            /* Carrying, set on the state rather than flown for: what is under
             * test is where a drop lands. */
            int flag = sim_add_flag(&s, 505 * 16 + 8, 490 * 16 + 8);
            s.flags[flag].carried = 1;
            s.flags[flag].carrier = (uint8_t)prey;

            ev_counts c = step_counting(&s, &dc2, SIM_BTN_FIRE, 0, 120);
            CHECK(c.deaths == 1, "the pilot in the doorway is killed");
            CHECK(!s.ships[prey].alive, "and is dead");

            CHECK(!s.flags[flag].carried, "the flag is dropped");
            int32_t fx = s.flags[flag].x / (SIM_TILE_PX * 256);
            int32_t fy = s.flags[flag].y / (SIM_TILE_PX * 256);
            int fcls = SIM_TILE_CLASS(sim_tile_at(dm, fx, fy));
            CHECK(fcls != SIM_TILE_DOOR && fcls != SIM_TILE_SOLID,
                  "and the flag is not left in the doorway either");
            int64_t fgx = fx - 505, fgy = fy - 504;
            CHECK(fgx * fgx + fgy * fgy <= 9, "near where it was dropped");
        }
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

        static sim_state s;
        sim_init(&s, 1);
        int id = sim_spawn(&s, APEX, 0, 512 * 16, 520 * 16, 0, &wc);
        int32_t y0 = s.ships[id].y;
        step_n(&s, &wc, 0, 0, 20);
        CHECK(s.ships[id].y < y0, "a drifting ship falls toward a wormhole");
        CHECK(s.ships[id].vy < 0, "and keeps accelerating into it");

        /* Out of range it is not felt at all, or the whole map would sag. */
        static sim_state f;
        sim_init(&f, 1);
        int fid = sim_spawn(&f, APEX, 0, 512 * 16, 700 * 16, 0, &wc);
        int32_t fy = f.ships[fid].y;
        step_n(&f, &wc, 0, 0, 60);
        CHECK(f.ships[fid].y == fy && f.ships[fid].vy == 0,
              "a ship beyond the rim is untouched");

        /* Inverse square, which is the whole shape of the field: twice as far
         * out is a quarter of the pull. Measured as one tick's velocity from
         * rest at four tiles and at eight, because a tick of gravity from a
         * standstill is the acceleration and nothing else. */
        {
            static sim_state near, far;
            sim_init(&near, 1);
            sim_init(&far, 1);
            const int32_t cx = 512 * 16 + 8, cy = 512 * 16 + 8;
            int n = sim_spawn(&near, APEX, 0, cx, cy + 64, 0, &wc);
            int fr = sim_spawn(&far, APEX, 0, cx, cy + 128, 0, &wc);
            step_n(&near, &wc, 0, 0, 1);
            step_n(&far, &wc, 0, 0, 1);
            int64_t an = -near.ships[n].vy, af = -far.ships[fr].vy;
            CHECK(an > 0 && af > 0, "both are pulled in");
            /* Four, to within what integer division of the last digit can
             * move: the check is the exponent, not the rounding. */
            CHECK(an > af * 39 / 10 && an < af * 41 / 10,
                  "half the distance is four times the pull");
        }

        /* The reach is a number of its own rather than a consequence of the
         * strength, so the rim is exactly where the setting says. */
        {
            int32_t rim = wc.wormhole_range / (SIM_TILE_PX * 256);
            CHECK(rim == 38, "the baseline reaches 38 tiles");
            static sim_state in, out;
            sim_init(&in, 1);
            sim_init(&out, 1);
            int i2 = sim_spawn(&in, APEX, 0, 512 * 16, (512 + 36) * 16, 0, &wc);
            int o2 = sim_spawn(&out, APEX, 0, 512 * 16, (512 + 40) * 16, 0, &wc);
            step_n(&in, &wc, 0, 0, 30);
            step_n(&out, &wc, 0, 0, 30);
            CHECK(in.ships[i2].vy < 0, "just inside the rim it still pulls");
            CHECK(out.ships[o2].vy == 0, "just outside it does not");
        }

        /* The ceiling is lifted while the field has hold of a hull, so a well
         * throws a ship rather than only aiming it. Without the lift the clamp
         * takes back every pixel a second the pull just handed over, and a
         * pilot falling into a wormhole arrives at exactly the speed they
         * could have flown there under their own thrust. */
        {
            static sim_settings flat;
            flat = wc;
            flat.wormhole_top_speed = 0;
            int32_t top = wc.classes[APEX].max_speed;
            int32_t lift = wc.wormhole_top_speed;
            CHECK(lift > 0, "the baseline lifts the ceiling at all");
            static sim_state lifted, held;
            sim_init(&lifted, 1);
            sim_init(&held, 1);
            const int32_t cx = 512 * 16 + 8, cy = 512 * 16 + 8;
            int l = sim_spawn(&lifted, APEX, 0, cx, cy + 12 * 16, 0, &wc);
            int h = sim_spawn(&held, APEX, 0, cx, cy + 12 * 16, 0, &flat);
            /* Long enough for the fall itself, which is what decides the
             * number of ticks here rather than any round figure: from twelve
             * tiles the pull needs about 134 of them to bring a hull onto the
             * mouth. The loop stops at the warp because a hull that has been
             * thrown is somewhere else and may be falling into something
             * again, and a second fall is not what this measures. */
            int32_t lmax = 0, hmax = 0;
            for (int t = 0; t < 400; t++) {
                if (lifted.ships[l].vy == 0 && held.ships[h].vy == 0 && t > 0)
                    break;
                step_n(&lifted, &wc, 0, 0, 1);
                step_n(&held, &flat, 0, 0, 1);
                int32_t lv = -lifted.ships[l].vy, hv = -held.ships[h].vy;
                if (lv > lmax) lmax = lv;
                if (hv > hmax) hmax = hv;
            }
            CHECK(hmax > 0 && hmax <= top,
                  "without the lift a fall stops at the hull's own ceiling");
            CHECK(lmax > top, "with it the well carries a hull past that");
            CHECK(lmax <= top + lift, "and no further than the lift allows");
        }

        /* GravityBombs. A thrown round bends and a bullet does not, which is
         * what makes a well worth building a room around: you can lob across
         * one, and the arc is the wormhole's to decide. */
        {
            static sim_settings dry;
            dry = wc;
            dry.gravity_bombs = 0;
            /* Fired east along a line two tiles under the wormhole, so a pull
             * that reaches the round shows up as a sideways velocity it was
             * never given. */
            const uint16_t east = 65536 / 4;
            static sim_state wet, off;
            sim_init(&wet, 1);
            sim_init(&off, 1);
            sim_spawn(&wet, APEX, 0, 500 * 16, 514 * 16, east, &wc);
            sim_spawn(&off, APEX, 0, 500 * 16, 514 * 16, east, &dry);
            step_n(&wet, &wc, SIM_BTN_BOMB, 0, 1);
            step_n(&off, &dry, SIM_BTN_BOMB, 0, 1);
            CHECK(wet.weapon_count == 1 && off.weapon_count == 1,
                  "each fires one bomb");
            step_n(&wet, &wc, 0, 0, 20);
            step_n(&off, &dry, 0, 0, 20);
            CHECK(wet.weapon_count == 1 && off.weapon_count == 1,
                  "and both are still in the air");
            CHECK(off.weapons[0].vy == 0, "with gravity off a bomb flies straight");
            CHECK(wet.weapons[0].vy < 0, "with it on the bomb is drawn upward");

            /* A bullet is not a thrown round, whatever the setting says. */
            static sim_state gun;
            sim_init(&gun, 1);
            sim_spawn(&gun, APEX, 0, 500 * 16, 514 * 16, east, &wc);
            step_n(&gun, &wc, SIM_BTN_FIRE, 0, 1);
            CHECK(gun.weapon_count > 0, "the gun fires");
            step_n(&gun, &wc, 0, 0, 20);
            CHECK(gun.weapon_count > 0 && gun.weapons[0].vy == 0,
                  "a bullet crosses a well without bending");
        }
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
        sim_map_size(bare, SIM_MAP_TILES, SIM_MAP_TILES);
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
        /* Every length short of a whole header, since the size is read out of
         * the header and a bound two bytes light reads it off the end. */
        for (int k = 0; k < 14; k++)
            CHECK(sim_map_unpack(dst, buf, k) == -1,
                  "nothing shorter than a header is a map");

        buf[n] = 0x5a;
        CHECK(sim_map_unpack(dst, buf, n + 1) == -1,
              "a map with trailing records is rejected");

        /* And something that is not a map at all. */
        buf[0] ^= 0xff;
        CHECK(sim_map_unpack(dst, buf, n) == -1, "a bad magic is rejected");

        /* The advertised ceiling also holds for the shape that defeats run
         * length encoding: every tile differs from the one before it. */
        sim_map *worst = malloc(sizeof *worst);
        sim_map_size(worst, SIM_MAP_TILES, SIM_MAP_TILES);
        for (size_t i = 0; i < (size_t)SIM_MAP_TILES * SIM_MAP_TILES; i++)
            worst->tile[i] = (uint8_t)(i & 1u);
        int worst_n = sim_map_pack(worst, buf, SIM_MAP_PACK_MAX);
        CHECK(worst_n == SIM_MAP_PACK_MAX,
              "an alternating map exactly fills the advertised ceiling");
        CHECK(sim_map_pack(worst, buf, SIM_MAP_PACK_MAX - 1) == -1,
              "and one byte less is refused");

        free(src); free(dst); free(pit); free(worst); free(buf);
    }

    /* Every map is closed, whatever the map says. */
    {
        const int LAST = SIM_MAP_TILES - 1;
        sim_map *open = malloc(sizeof *open);
        sim_map_size(open, SIM_MAP_TILES, SIM_MAP_TILES);
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
        static sim_state s;
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

    /* A map is the size it says it is, and it travels at that size. */
    {
        sim_map *small = malloc(sizeof *small);
        sim_map_size(small, 96, 144);
        SIM_MAP_AT(small, 40, 40) = SIM_TILE(SIM_TILE_SPAWN, 0);
        sim_map_index(small);

        CHECK(small->w == 96 && small->h == 144, "a map keeps the size it was given");
        CHECK(SIM_TILE_CLASS(sim_tile_at(small, 95, 70)) == SIM_TILE_SOLID
                  && SIM_TILE_CLASS(sim_tile_at(small, 60, 143)) == SIM_TILE_SOLID,
              "and is walled at its own edge rather than the array's");
        CHECK(SIM_TILE_CLASS(sim_tile_at(small, 200, 70)) == SIM_TILE_SOLID
                  && SIM_TILE_CLASS(sim_tile_at(small, 60, 900)) == SIM_TILE_SOLID,
              "everything past that edge is wall, whatever the array holds");
        CHECK(sim_tile_at(small, 50, 70) == SIM_TILE_EMPTY,
              "and the inside is still the map's own ground");

        uint8_t *sb = malloc(SIM_MAP_PACK_MAX);
        int sn = sim_map_pack(small, sb, SIM_MAP_PACK_MAX);
        CHECK(sn > 0, "a map that is not square packs");
        /* The point of the size being in the file: a 96 by 144 room costs what
         * 96 by 144 costs. Drawn as a hole in the full array instead, the same
         * room spends every row saying "and then nine hundred tiles of
         * nothing", and the empty square below is the floor on that. */
        sim_map *full = malloc(sizeof *full);
        sim_map_size(full, SIM_MAP_TILES, SIM_MAP_TILES);
        sim_map_index(full);
        uint8_t *fb = malloc(SIM_MAP_PACK_MAX);
        CHECK(sn < sim_map_pack(full, fb, SIM_MAP_PACK_MAX) / 4,
              "and costs its own size on the wire, not the array's");
        free(full); free(fb);

        sim_map *round = malloc(sizeof *round);
        CHECK(sim_map_unpack(round, sb, sn) == 0, "and unpacks");
        CHECK(round->w == 96 && round->h == 144, "with its size intact");
        CHECK(sim_map_hash(round) == sim_map_hash(small), "and hashing alike");

        /* Same drawing, different size, so the hash has to disagree: a client
         * that decodes the wrong room would rather be told. */
        sim_map *wider = malloc(sizeof *wider);
        sim_map_size(wider, 97, 144);
        SIM_MAP_AT(wider, 40, 40) = SIM_TILE(SIM_TILE_SPAWN, 0);
        sim_map_index(wider);
        CHECK(sim_map_hash(wider) != sim_map_hash(small),
              "one tile of width is a different map");

        /* A size the array cannot hold is refused rather than trusted. */
        sb[6] = 0xff;
        sb[7] = 0xff;
        CHECK(sim_map_unpack(round, sb, sn) == -1, "a map wider than the array is refused");

        free(sb); free(small); free(round); free(wider);
    }

    /* Whether a map can be flown, which is a question about a hull and not
     * about a tile. */
    {
        sim_map *room = malloc(sizeof *room);
        sim_map_scratch *sc = malloc(sizeof *sc);
        sim_map_report rep;
        char why[192];
        CHECK(room && sc, "the check has room to work in");

        /* An open room with a start in it and nothing else. */
        sim_map_size(room, 80, 60);
        SIM_MAP_AT(room, 40, 30) = SIM_TILE(SIM_TILE_SPAWN, 0);
        sim_map_index(room);
        sim_map_check(room, sc, &rep);
        CHECK(rep.regions == 1, "an open room is one region");
        CHECK(rep.stranded == 0, "with nothing stranded in it");
        CHECK(rep.spawns == 1 && rep.spawns_team[0] == 1, "and one start, on side one");
        CHECK(sim_map_playable(&rep, why, sizeof why), "so it is playable");

        /* A wall straight across it is two rooms, and a hull cannot get from
         * one to the other. */
        for (int tx = 0; tx < 80; tx++) SIM_MAP_AT(room, tx, 30) = SIM_TILE_SOLID;
        SIM_MAP_AT(room, 40, 20) = SIM_TILE(SIM_TILE_SPAWN, 0);
        sim_map_index(room);
        sim_map_check(room, sc, &rep);
        CHECK(rep.regions == 2, "a wall across a room makes two of it");
        CHECK(!sim_map_playable(&rep, why, sizeof why),
              "which is not a map worth serving");

        /* A gap one tile wide is not a way through: a hull is three across,
         * and reading this a tile at a time is how a map ships with rooms
         * nothing can enter. */
        SIM_MAP_AT(room, 40, 30) = SIM_TILE_EMPTY;
        sim_map_index(room);
        sim_map_check(room, sc, &rep);
        CHECK(rep.regions == 2, "a one-tile gap is still a wall to a hull");

        /* Three tiles is. */
        SIM_MAP_AT(room, 39, 30) = SIM_TILE_EMPTY;
        SIM_MAP_AT(room, 41, 30) = SIM_TILE_EMPTY;
        sim_map_index(room);
        sim_map_check(room, sc, &rep);
        CHECK(rep.regions == 1, "three tiles is a doorway");
        CHECK(sim_map_playable(&rep, why, sizeof why), "and the map is whole again");

        /* A closet nothing can reach is stranded ground, however open it
         * looks on the drawing. */
        for (int tx = 60; tx <= 70; tx++) {
            SIM_MAP_AT(room, tx, 40) = SIM_TILE_SOLID;
            SIM_MAP_AT(room, tx, 50) = SIM_TILE_SOLID;
        }
        for (int ty = 40; ty <= 50; ty++) {
            SIM_MAP_AT(room, 60, ty) = SIM_TILE_SOLID;
            SIM_MAP_AT(room, 70, ty) = SIM_TILE_SOLID;
        }
        sim_map_index(room);
        sim_map_check(room, sc, &rep);
        CHECK(rep.stranded > 0, "a sealed closet is ground nobody reaches");
        CHECK(!sim_map_playable(&rep, why, sizeof why),
              "and a map with one is refused");

        /* Two rocks with one tile between them. A hull is three across, so
         * nothing can come within a tile of that gap, and it counts as ground
         * no hull can reach. It is also just a gap between two rocks, which is
         * what an asteroid field is made of, so it is reported and not
         * refused: the first map anybody scattered rocks over came back with
         * thirty-eight of these and nothing wrong with it. */
        sim_map_size(room, 80, 60);
        SIM_MAP_AT(room, 40, 30) = SIM_TILE(SIM_TILE_SPAWN, 0);
        SIM_MAP_AT(room, 20, 20) = SIM_TILE(SIM_TILE_SOLID, SIM_SOLID_ROCK_A);
        SIM_MAP_AT(room, 22, 20) = SIM_TILE(SIM_TILE_SOLID, SIM_SOLID_ROCK_A);
        sim_map_index(room);
        sim_map_check(room, sc, &rep);
        CHECK(rep.stranded == 1, "a gap between two rocks is ground no hull reaches");
        CHECK(rep.regions == 1, "and it is still one room");
        CHECK(sim_map_playable(&rep, why, sizeof why),
              "so a rock field is a map worth serving");

        /* And the editor can be told which tile, rather than only how many. */
        {
            uint32_t at[8];
            int n = sim_map_stranded(room, sc, at, 8);
            CHECK(n == 1, "the stranded tile is named");
            CHECK(at[0] == 20 * 80 + 21, "and it is the one between the rocks");
        }

        /* A sealed room is still refused, and by the region count rather than
         * by the tile count: it is somewhere a hull fits and cannot reach,
         * which is the thing that was ever worth refusing. */
        sim_map_size(room, 80, 60);
        SIM_MAP_AT(room, 40, 30) = SIM_TILE(SIM_TILE_SPAWN, 0);
        for (int tx = 60; tx <= 70; tx++) {
            SIM_MAP_AT(room, tx, 40) = SIM_TILE_SOLID;
            SIM_MAP_AT(room, tx, 50) = SIM_TILE_SOLID;
        }
        for (int ty = 40; ty <= 50; ty++) {
            SIM_MAP_AT(room, 60, ty) = SIM_TILE_SOLID;
            SIM_MAP_AT(room, 70, ty) = SIM_TILE_SOLID;
        }
        sim_map_index(room);
        sim_map_check(room, sc, &rep);
        CHECK(rep.regions == 2, "a sealed room a hull fits in is a second region");
        CHECK(!sim_map_playable(&rep, why, sizeof why),
              "and that is still refused");

        /* A map naming no start is refused too: a zone would fall back to its
         * own tiles, which are drawn for a different room. */
        sim_map_size(room, 60, 60);
        sim_map_index(room);
        sim_map_check(room, sc, &rep);
        CHECK(rep.spawns == 0 && !sim_map_playable(&rep, why, sizeof why),
              "a map with no start is not one a zone can be pointed at");

        /* A door is a passage. A wall of them across a room divides it while
         * they are shut and not otherwise, so the map is one region and the
         * count that says two is the one nothing is refused for. */
        sim_map_size(room, 80, 60);
        SIM_MAP_AT(room, 40, 20) = SIM_TILE(SIM_TILE_SPAWN, 0);
        for (int tx = 0; tx < 80; tx++) SIM_MAP_AT(room, tx, 30) = SIM_TILE(SIM_TILE_DOOR, 0);
        sim_map_index(room);
        sim_map_check(room, sc, &rep);
        CHECK(rep.regions == 1, "a door wall is one region, because doors open");
        CHECK(rep.regions_shut == 2, "and two with every one of them shut");
        CHECK(rep.stranded == 0, "nothing behind it is stranded");
        CHECK(sim_map_playable(&rep, why, sizeof why),
              "and a room divided by doors is a room");

        /* The map that found this: a start in a pocket whose only way out is a
         * door. Refused as "a start is walled in" while the verdict was taken
         * with the doors shut, which made a door useless for the one thing a
         * door is for. */
        sim_map_size(room, 80, 60);
        for (int ty = 0; ty < 60; ty++) SIM_MAP_AT(room, 20, ty) = SIM_TILE_SOLID;
        for (int ty = 24; ty <= 36; ty++) SIM_MAP_AT(room, 20, ty) = SIM_TILE(SIM_TILE_DOOR, 0);
        SIM_MAP_AT(room, 10, 30) = SIM_TILE(SIM_TILE_SPAWN, 0);
        SIM_MAP_AT(room, 50, 30) = SIM_TILE(SIM_TILE_SPAWN, 1);
        sim_map_index(room);
        sim_map_check(room, sc, &rep);
        CHECK(rep.spawns == 2 && rep.spawns_team[0] == 1 && rep.spawns_team[1] == 1,
              "a start each side of a door");
        CHECK(rep.spawns_stranded == 0, "and neither is walled in by it");
        CHECK(rep.regions == 1 && rep.regions_shut == 2,
              "one room through the door, two without it");
        CHECK(sim_map_playable(&rep, why, sizeof why),
              "so a pocket gated by a door is playable");

        /* Bricking the door up is the same drawing and a different map, and
         * that one is refused: with the doors open there is still no way
         * through, which is the question the verdict asks. */
        for (int ty = 24; ty <= 36; ty++) SIM_MAP_AT(room, 20, ty) = SIM_TILE_SOLID;
        sim_map_index(room);
        sim_map_check(room, sc, &rep);
        CHECK(rep.regions == 2, "walling the door up is two rooms");
        CHECK(!sim_map_playable(&rep, why, sizeof why),
              "and that is still refused");

        free(room);
        free(sc);
    }

    /* Slopes: the diagonal a staircase could not be. */
    {
        sim_map *ramp = malloc(sizeof *ramp);
        sim_map_size(ramp, 200, 200);
        /* A wall running down and right at 45 degrees: the face is the run of
         * slope tiles, and everything below and left of it is the wall's body.
         *
         * Drawn as a continuous run on purpose. A hull is three tiles across,
         * so it straddles several tiles of whatever it lands on, and a lone
         * slope cut into an otherwise flat top gives it two surfaces at once
         * to rest on. That is a rule for whoever draws a map, and the reason
         * the generator lays these in runs. */
        for (int ty = 100; ty <= 160; ty++) {
            for (int tx = 60; tx < ty; tx++) SIM_MAP_AT(ramp, tx, ty) = SIM_TILE_SOLID;
            SIM_MAP_AT(ramp, ty, ty) = SIM_TILE(SIM_TILE_SLOPE, SIM_SLOPE_SW);
        }
        sim_map_index(ramp);

        /* The open half of a slope tile is open. A staircase spends a whole
         * tile to say that, which is the jaggedness this replaces. */
        sim_settings sc = cfg;
        sc.map = ramp;
        static sim_state s;
        sim_init(&s, 11);
        sim_spawn(&s, APEX, 0, 130 * 16 + 14, 130 * 16 + 2, 0, &sc);
        CHECK(s.ships[0].active, "a hull stands in the open half of a slope tile");

        /* Falling onto the face is turned along it rather than stopped dead.
         * Dropped straight down, a 45 degree plane sends a hull sideways:
         * that is the whole difference from a wall, which would take the fall
         * and leave it sitting there. */
        sim_init(&s, 12);
        sim_spawn(&s, APEX, 0, 130 * 16, 120 * 16, 0, &sc);
        s.ships[0].vy = 3 * 65536;
        s.ships[0].vx = 0;
        step_n(&s, &sc, 0, 0, 200);
        CHECK(s.ships[0].vx > 0, "a hull dropped on a 45 degree face is turned along it");
        int32_t fx = s.ships[0].x >> 12, fy = s.ships[0].y >> 12;
        CHECK(fy <= fx, "and is left on the open side of it, never inside the wall");

        /* A run of slopes one tile thick is a one-way wall, which is the
         * reason the generator's diagonals are three tiles across and not one.
         *
         * Consecutive tiles of one variant meet at a point, so the face they
         * make is continuous and the material behind it is not. Coming at the
         * side the solid halves face, a hull is stopped. Coming at the other,
         * it goes through, because there is nothing there to stop it: the open
         * halves line up into a corridor. It looks like a wall on the drawing
         * either way, which is what makes it worth a test rather than a
         * comment. */
        {
            sim_map *thin = malloc(sizeof *thin);
            sim_map_size(thin, 200, 200);
            for (int i = 0; i <= 80; i++)
                SIM_MAP_AT(thin, 40 + i, 40 + i) =
                    SIM_TILE(SIM_TILE_SLOPE, SIM_SLOPE_NE);
            sim_map_index(thin);
            sim_settings tc = cfg;
            tc.map = thin;

            /* North-east of the line, pushed south-west at it. The solid
             * halves face north-east, so this is the side that holds. */
            static sim_state t;
            sim_init(&t, 21);
            sim_spawn(&t, APEX, 0, 60 * 16, 90 * 16, 0, &tc);
            t.ships[0].vx = 6 * 65536;
            t.ships[0].vy = -6 * 65536;
            step_n(&t, &tc, 0, 0, 300);
            CHECK((t.ships[0].x >> 12) <= (t.ships[0].y >> 12) + 3,
                  "a thin run of slopes holds from the side its solid half faces");

            /* And the other way, which does not. */
            sim_init(&t, 22);
            sim_spawn(&t, APEX, 0, 90 * 16, 60 * 16, 0, &tc);
            t.ships[0].vx = -6 * 65536;
            t.ships[0].vy = 6 * 65536;
            step_n(&t, &tc, 0, 0, 300);
            CHECK((t.ships[0].y >> 12) > (t.ships[0].x >> 12) + 3,
                  "and lets a hull straight through from the other side");
            free(thin);
        }

        /* Two runs leaning opposite ways, which is the shape the generator
         * draws: no solid tile in it, two tiles across, and the only diagonal
         * of the three that nothing gets through.
         *
         * What makes it work is the shared edge. Each tile is solid the whole
         * length of the side it hands its neighbour, across the run and along
         * it both, where every other diagonal a square grid can draw meets
         * corner to corner and pinches to a point. */
        {
            sim_map *band = malloc(sizeof *band);
            sim_map_size(band, 200, 200);
            for (int i = 0; i <= 80; i++) {
                SIM_MAP_AT(band, 40 + i, 40 + i) =
                    SIM_TILE(SIM_TILE_SLOPE, SIM_SLOPE_NE);
                SIM_MAP_AT(band, 41 + i, 40 + i) =
                    SIM_TILE(SIM_TILE_SLOPE, SIM_SLOPE_SW);
            }
            sim_map_index(band);
            sim_settings bc = cfg;
            bc.map = band;

            static sim_state t;
            sim_init(&t, 23);
            sim_spawn(&t, APEX, 0, 90 * 16, 60 * 16, 0, &bc);
            t.ships[0].vx = -6 * 65536;
            t.ships[0].vy = 6 * 65536;
            step_n(&t, &bc, 0, 0, 300);
            CHECK((t.ships[0].y >> 12) <= (t.ships[0].x >> 12) + 3,
                  "two opposing runs hold a hull from the north-east");

            sim_init(&t, 24);
            sim_spawn(&t, APEX, 0, 60 * 16, 90 * 16, 0, &bc);
            t.ships[0].vx = 6 * 65536;
            t.ships[0].vy = -6 * 65536;
            step_n(&t, &bc, 0, 0, 300);
            CHECK((t.ships[0].x >> 12) <= (t.ships[0].y >> 12) + 3,
                  "and from the south-west, which one run does not");
            free(band);
        }

        /* The end of a finite pair run. The two faces stop there, and what a
         * hull cutting the corner at the exposed end used to find was the
         * inside of the wall: the axis clamps see no slope, and between two
         * parallel faces the deepest alternates every tick, so the hull sat
         * on the seam jittering forever. It is a wall and has to answer like
         * one, whatever the speed and wherever across the tip the hull
         * arrives. */
        {
            sim_map *stub = malloc(sizeof *stub);
            sim_map_size(stub, 200, 200);
            for (int i = 0; i <= 12; i++) {
                SIM_MAP_AT(stub, 60 + i, 60 + i) =
                    SIM_TILE(SIM_TILE_SLOPE, SIM_SLOPE_NE);
                SIM_MAP_AT(stub, 61 + i, 60 + i) =
                    SIM_TILE(SIM_TILE_SLOPE, SIM_SLOPE_SW);
            }
            sim_map_index(stub);
            sim_settings ec = cfg;
            ec.map = stub;

            int stuck = 0;
            for (int spd = 4; spd <= 20 && !stuck; spd += 2) {
                for (int off = -10; off <= 10 && !stuck; off++) {
                    static sim_state t;
                    /* Square across the run, aimed to shave its upper end. */
                    sim_init(&t, 26);
                    sim_spawn(&t, APEX, 0, 61 * 16 - 43 + off,
                              60 * 16 + 100, 0, &ec);
                    t.ships[0].vx = spd * 65536;
                    t.ships[0].vy = -spd * 65536;
                    step_n(&t, &ec, 0, 0, 300);
                    int32_t px = t.ships[0].x / 256, py = t.ships[0].y / 256;
                    if (px > py && px < py + 16 && py >= 60 * 16 - 8
                        && py <= 73 * 16 + 8)
                        stuck = 1;
                    /* And down the run's own axis into the mouth. */
                    sim_init(&t, 27);
                    sim_spawn(&t, APEX, 0, 55 * 16 + 8 + off, 55 * 16,
                              24576, &ec);
                    t.ships[0].vx = spd * 65536;
                    t.ships[0].vy = spd * 65536;
                    step_n(&t, &ec, 0, 0, 300);
                    px = t.ships[0].x / 256;
                    py = t.ships[0].y / 256;
                    if (px > py && px < py + 16 && py >= 60 * 16 - 8
                        && py <= 73 * 16 + 8)
                        stuck = 1;
                }
            }
            CHECK(!stuck, "no approach to a run's end leaves a hull inside it");
            free(stub);
        }

        /* And the reason it is that shape rather than a stepped line with the
         * steps filed off.
         *
         * A pinch is no hole to a hull, which is three tiles across and cannot
         * fit through a point. It is a hole to a bullet. A round fired square
         * at a stepped diagonal travels along the other diagonal, which takes
         * it exactly through the corners where the tiles touch, and it goes
         * straight through a wall that stops every ship. That was true of the
         * generator's diagonals for as long as they were stepped. */
        {
            sim_map *step_wall = malloc(sizeof *step_wall);
            sim_map *pair_wall = malloc(sizeof *pair_wall);
            sim_map_size(step_wall, 200, 200);
            sim_map_size(pair_wall, 200, 200);
            for (int i = -80; i <= 80; i++) {
                int tx = 100 + i, ty = 100 + i;
                if (tx < 1 || ty < 1 || tx > 198 || ty > 198) continue;
                SIM_MAP_AT(step_wall, tx, ty) = SIM_TILE_SOLID;
                SIM_MAP_AT(pair_wall, tx, ty) = SIM_TILE(SIM_TILE_SLOPE, SIM_SLOPE_NE);
                SIM_MAP_AT(pair_wall, tx + 1, ty) = SIM_TILE(SIM_TILE_SLOPE, SIM_SLOPE_SW);
            }
            sim_map_index(step_wall);
            sim_map_index(pair_wall);

            /* Twenty of thirty-two of a turn, which from north-east of the
             * line is the shot aimed square at it. */
            const uint16_t square_on = (uint16_t)(20 * (65536 / 32));
            int got_through[2] = {0, 0};
            sim_map *walls[2] = {step_wall, pair_wall};
            for (int which = 0; which < 2; which++) {
                sim_settings wc = cfg;
                bare_kits(&wc);
                wc.map = walls[which];
                sim_state t;
                sim_init(&t, 25 + which);
                sim_spawn(&t, APEX, 0, 130 * 16, 70 * 16, square_on, &wc);
                sim_deal_kit(&t.ships[0], &wc, 1);
                for (int k = 0; k < 400 && !got_through[which]; k++) {
                    step_n(&t, &wc, k < 3 ? SIM_BTN_FIRE : 0, 0, 1);
                    for (int wpn = 0; wpn < SIM_MAX_WEAPONS; wpn++) {
                        if (!t.weapons[wpn].life) continue;
                        int32_t wx = t.weapons[wpn].x >> 8;
                        int32_t wy = t.weapons[wpn].y >> 8;
                        if (wy > wx + 48) { got_through[which] = 1; break; }
                    }
                }
            }
            CHECK(got_through[0], "a round fired square at a stepped diagonal goes through it");
            CHECK(!got_through[1], "and the same round is stopped by two opposing runs");
            free(step_wall);
            free(pair_wall);
        }

        /* Which is the point: on a staircase the same drop lands on a step and
         * stops. Here it keeps moving, and it moves along the wall. */
        CHECK(fx > 130, "and travels along the face rather than resting on a step");

        /* A round bouncing off one turns the same way a hull does. Per axis it
         * would reverse both and fly back at whoever fired it, which is what a
         * corner does and not what a diagonal does. */
        sim_settings bw = sc;
        bare_kits(&bw);
        sim_weapon_spec sp = bw.specs[gun_of(&bw, APEX)->spec];
        sp.on_wall = SIM_WALL_BOUNCE;
        sp.bounces = 1;
        sim_fire_pattern fp = *gun_of(&bw, APEX);
        fp.spec = (uint8_t)sim_add_spec(&bw, &sp);
        bw.classes[APEX].trigger[SIM_TRIG_GUN][0] = (uint8_t)sim_add_pattern(&bw, &fp);

        sim_init(&s, 13);
        sim_spawn(&s, APEX, 0, 140 * 16, 120 * 16, 32768, &bw);
        step_n(&s, &bw, SIM_BTN_FIRE, 0, 1);
        CHECK(s.weapon_count == 1 && s.weapons[0].vy > 0,
              "a round is fired down the face");
        int32_t down = s.weapons[0].vy;
        step_n(&s, &bw, 0, 0, 200);
        CHECK(s.weapon_count == 1, "the face did not end it");
        CHECK(s.weapons[0].vx == down && s.weapons[0].vy == 0,
              "a 45 degree face turns a round square, keeping every bit of its speed");

        free(ramp);
    }

}

static void test_lifecycle(sim_map *m, const sim_settings *base) {
    sim_settings cfg = *base;

    /* The room size is the zone's, and the array bound is only the ceiling. */
    {
        sim_settings small = cfg;
        small.max_ships = 3;
        static sim_state s;
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
        static sim_state s;
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
         * have bumped it is the writer that was not touched. That has
         * happened, in the very commit that added the fields: every suite
         * stayed green while a joining client flew the weapon differently
         * from the server. Every spec is built by copying a memset local, so
         * the padding is zeroed and memcmp is a fair judge. */
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
        static sim_state s;
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
        static sim_state s;
        sim_settings w = cfg;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &w);
        sim_spawn(&s, APEX, 1, 8192, 8192 - 200, 0, &w);
        s.ships[1].energy = 1;
        ev_counts c = step_counting(&s, &w, SIM_BTN_FIRE, 0, 150);
        CHECK(!s.ships[1].alive, "low energy target dies");
        CHECK(c.deaths == 1, "death is reported once");
        CHECK(s.ships[0].kills == 1, "the killer is credited");
        CHECK(s.ships[1].deaths == 1, "the victim's deaths increment");
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
        static sim_state s;
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


    /* How far out a bomb's fate is settled, which is the whole of why a
     * prediction client should not settle it.
     *
     * Sweeping the enemy sideways off the bomb's line: on contact alone the
     * bomb has to reach the hull, and 11 px to the side it misses. Give it a
     * fuse and the decision moves out to 49, 103 and 157 px by rung, because
     * arming is the decision. Once a fuse has somebody it goes off at closest
     * approach whatever that turns out to be, so what the whole explosion
     * rests on is whether a hull was inside that circle.
     *
     * A client is wrong about where a remote hull is by tens of pixels as a
     * matter of course. It coasts them from the last snapshot, and the
     * correction it eases rather than gives up and snaps runs to 48 px
     * (REMOTE_POS_SNAP, client/ext/simcore/src/smoothing.h). That is the same
     * size as the circle it was deciding inside. */
    {
        CHECK(bombed(&cfg, APEX, 0, 0) > 0, "a bomb on contact reaches a hull");
        CHECK(bombed(&cfg, APEX, 20, 0) < 0, "and misses one 20 px to the side");
        CHECK(bombed(&cfg, APEX, 40, 1) > 0, "one rung of fuse reaches 40 px");
        CHECK(bombed(&cfg, APEX, 100, 2) > 0, "two rungs reach 100");
        CHECK(bombed(&cfg, APEX, 200, 3) < 0, "and three still do not reach 200");
    }

    /* So a prediction client arms no fuse on a hull it is only guessing at.
     * It used to, and then fired: the client blew its own bomb up on somebody
     * who was never inside the circle, the snapshot handed the bomb back, the
     * next prediction blew it up again, and one bomb crossing a fight drew a
     * string of explosions it never had while the bomb itself flew on. */
    {
        sim_settings dc = cfg;
        dc.deathless = 1;
        dc.mortal_ship = 0;
        CHECK(bombed(&dc, APEX, 100, 2) < 0,
              "a client's own bomb does not go off on a hull it guessed at");
        /* Not because the fuse stopped working. Pointed at the one hull this
         * instance simulates for real, it arms and fires as it always did, so
         * being bombed yourself stays as immediate as it ever was. */
        dc.mortal_ship = 1;
        CHECK(bombed(&dc, APEX, 100, 2) == bombed(&cfg, APEX, 100, 2),
              "on the hull it does simulate, the same fuse fires the same tick");
    }

    /* Contact followed, one report later: a pilot filmed their own bomb
     * going off at the muzzle and then flying on to where it really landed.
     * The coasted hull it was drawn hitting was a guess of the same kind the
     * fuse had been arming on, only a smaller target. So a thrown round now
     * passes through any hull a deathless instance is only guessing at, and
     * the ending arrives as the round leaving a snapshot (decision 144). */
    {
        sim_settings dc = cfg;
        dc.deathless = 1;
        dc.mortal_ship = 255;
        CHECK(bombed(&cfg, APEX, 0, 0) >= 0,
              "the zone lands a bomb flown straight into somebody");
        CHECK(bombed(&dc, APEX, 0, 0) < 0,
              "a client lands no bomb on a hull it is only guessing at");
        /* On the hull this instance simulates for real, contact is as
         * immediate as it always was, which is how being bombed stays
         * immediate for the pilot it happens to. */
        dc.mortal_ship = 1;
        CHECK(bombed(&dc, APEX, 0, 0) == bombed(&cfg, APEX, 0, 0),
              "and lands it on the hull it does simulate, the same tick");
        /* Bullets are not thrown and are not deferred: the target has to be
         * reached, the hit is a spark rather than a blast, and predicting it
         * is what keeps a gun feeling immediate. */
        dc.mortal_ship = 255;
        CHECK(landed(&dc, APEX, 0, 0, SIM_BTN_FIRE)
                  == landed(&cfg, APEX, 0, 0, SIM_BTN_FIRE),
              "a client still lands a bullet it flew into somebody");
    }

    /* The one hull named mortal still dies, which is how the client keeps
     * its own death immediate while everyone else's waits for the zone. */
    {
        static sim_state s;
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
    }

    /* The double barrel, through the wire.
     *
     * How wide a pair sits is a settings field of its own, and it was the one
     * field the message did not carry. A client's copy stayed zero, `compose`
     * handed that zero to `spawn_pattern`, and zero spacing on a pattern of
     * more than one round does not mean "no spread": it means scatter, which
     * is what Shrapnel:Random is. So every pair a client predicted left the
     * muzzle at a fresh random angle and was pulled back into line a round
     * trip later, when the zone's snapshot arrived. Filmed off the fleet as
     * bullets going off to the side and then correcting.
     *
     * What is checked is that the two ends throw the same pair, rather than
     * that the pair is any particular width. The point is whose numbers the
     * client is flying. */
    {
        static sim_settings wired;
        memset(&wired, 0, sizeof wired);
        sim_settings_baseline(&wired, m);
        static uint8_t wbuf[SIM_SETTINGS_PACK_MAX];
        int wn = sim_settings_pack(&cfg, wbuf, sizeof wbuf);
        CHECK(wn > 0 && sim_settings_unpack(&wired, wbuf, wn) == 0,
              "a client takes the zone's settings off the wire");
        CHECK(wired.mod_pair_spread == cfg.mod_pair_spread,
              "including how wide a pair sits");

        static sim_state zs, cs;
        sim_init(&zs, 3);
        sim_init(&cs, 3);
        sim_spawn(&zs, APEX, 0, 8192, 8192, 0, &cfg);
        sim_spawn(&cs, APEX, 0, 8192, 8192, 0, &wired);
        zs.ships[0].mods[SIM_TRIG_GUN] = sim_mod_set(0, SIM_MOD_MULTI, 1);
        cs.ships[0].mods[SIM_TRIG_GUN] = sim_mod_set(0, SIM_MOD_MULTI, 1);
        step_n(&zs, &cfg, SIM_BTN_FIRE, 0, 1);
        step_n(&cs, &wired, SIM_BTN_FIRE, 0, 1);
        CHECK(zs.weapon_count == 2 && cs.weapon_count == 2,
              "one rung of spray throws a pair at either end");
        CHECK(zs.weapons[0].vx == cs.weapons[0].vx
                  && zs.weapons[0].vy == cs.weapons[0].vy
                  && zs.weapons[1].vx == cs.weapons[1].vx
                  && zs.weapons[1].vy == cs.weapons[1].vy,
              "and the client throws it down the zone's two lines");
    }

    /* Changing hull is a respawn, not a costume change, and it leaves the
     * rest of the arena exactly where it was.
     *
     * The build crosses, because the build is the pilot's: what you spent is
     * yours and the hull is what you are sitting in. So does the ammunition
     * you have already spent, so a hull change is not a reload. */
    {
        static sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        sim_spawn(&s, APEX, 1, 8500, 8192, 0, &cfg);
        uint8_t spray[SIM_SLOT_COUNT];
        memset(spray, 0, sizeof spray);
        spray[SIM_SLOT_MOD(SIM_TRIG_GUN, SIM_MOD_MULTI)] = 1;
        spray[SIM_SLOT_CHARGE(SIM_CHARGE_REPEL)] = 2;
        CHECK(sim_set_ship_kit(&s, &cfg, 0, spray) == 0, "a build is dealt");
        step_n(&s, &cfg, SIM_BTN_THRUST, SIM_BTN_THRUST, 30);
        CHECK(sim_mod_get(s.ships[0].mods[SIM_TRIG_GUN], SIM_MOD_MULTI) == 1,
              "the pilot bought a pair");
        /* One spent, so the reload this is not can be seen. */
        s.ships[0].charge[SIM_CHARGE_REPEL] = 1;
        int32_t foe_y = s.ships[1].y;
        CHECK(s.ships[0].y != s.ships[0].spawn_y, "the pilot had flown off");
        CHECK(sim_set_ship_class(&s, &cfg, 0, ANVIL, NULL) == 0, "the hull changed");
        CHECK(s.ships[0].cls == ANVIL, "into the one asked for");
        CHECK(s.ships[0].y == s.ships[0].spawn_y, "back at the start");
        CHECK(s.ships[0].vx == 0 && s.ships[0].vy == 0, "and at rest");
        CHECK(sim_mod_get(s.ships[0].mods[SIM_TRIG_GUN], SIM_MOD_MULTI) == 1,
              "still wearing the build it climbed out with");
        CHECK(s.ships[0].charge[SIM_CHARGE_REPEL] == 1,
              "and what it spent stays spent");
        CHECK(s.ships[0].energy ==
              sim_eff_max_energy(&cfg.classes[ANVIL], &s.ships[0]),
              "with a full bar of the new ship");
        CHECK(s.ships[1].y == foe_y, "and nobody else moved");
        CHECK(s.ships[0].team == 0, "and you are still on your own team");
        CHECK(sim_set_ship_class(&s, &cfg, 9, APEX, NULL) == -1, "no such ship");
        CHECK(sim_set_ship_class(&s, &cfg, 0, 99, NULL) == -1, "no such class");
    }

    /* Changing sides is the same respawn under the same gate, and it takes
     * what you were carrying for the other side away with it. What it does
     * not take is the ship: crossing over is not a new hull. */
    {
        static sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        sim_spawn(&s, APEX, 1, 8500, 8192, 0, &cfg);
        step_n(&s, &cfg, SIM_BTN_THRUST, SIM_BTN_THRUST, 30);
        s.ships[0].up[SIM_UP_SPEED] = 3;
        s.ships[0].streak = 4;
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
        CHECK(s.ships[0].streak == 0, "and none of the run they were on");
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
        static sim_state s;
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
        static sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        s.ships[0].up[SIM_UP_SPEED] = 2;
        s.ships[0].energy -= 1;
        CHECK(sim_set_ship_class(&s, &cfg, 0, ANVIL, NULL) == -1,
              "a damaged pilot cannot swap hull");
        CHECK(s.ships[0].cls == APEX, "and is left in the one they had");
        CHECK(s.ships[0].up[SIM_UP_SPEED] == 2, "with what they had collected");
        step_n(&s, &cfg, 0, 0, 40);      /* recharge to the top */
        CHECK(sim_set_ship_class(&s, &cfg, 0, ANVIL, NULL) == 0,
              "and can once the bar is full again");
    }

    /* Nor while dead: this sets `alive`, so allowing it would hand out an
     * early respawn to anybody who opened the menu on the way down. */
    {
        static sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        s.ships[0].alive = 0;
        s.ships[0].respawn_at = 200;
        CHECK(sim_set_ship_class(&s, &cfg, 0, ANVIL, NULL) == -1,
              "a dead pilot cannot swap hull");
        CHECK(s.ships[0].respawn_at == 200, "and still owes the full wait");
    }

    /* The ship you are already flying is not a change, and must not cost you
     * the upgrades that picking it would otherwise throw away. The row is
     * compared as it fits, so a caller handing back the build already on the
     * ship is asking for the ship it is in however it spelled the row. */
    {
        static sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        s.ships[0].up[SIM_UP_ENERGY] = 4;
        s.ships[0].energy = sim_eff_max_energy(&cfg.classes[APEX], &s.ships[0]);
        CHECK(sim_set_ship_class(&s, &cfg, 0, APEX, NULL) == 0, "asking for it succeeds");
        CHECK(s.ships[0].up[SIM_UP_ENERGY] == 4, "and costs nothing");
        uint8_t same[SIM_SLOT_COUNT];
        memcpy(same, s.ships[0].kit, sizeof same);
        CHECK(sim_set_ship_class(&s, &cfg, 0, APEX, same) == 0,
              "and so does handing back the build it is wearing");
        CHECK(s.ships[0].up[SIM_UP_ENERGY] == 4, "which also costs nothing");
    }

    /* A build changed under the same hull is a new ship: the same gate, the
     * same respawn, and the same refusal to hand ammunition back. Without
     * this, the ship menu is two acts that cost differently. Climb into
     * another hull and you pay a respawn; trade a charge for a rung and you
     * pay nothing, which makes a refit the way out of a fight you are
     * losing. */
    {
        static sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        uint8_t row[SIM_SLOT_COUNT];
        memcpy(row, s.ships[0].kit, sizeof row);
        row[SIM_SLOT_CHARGE(SIM_CHARGE_REPEL)] = 2;
        sim_kit_fit(&cfg, APEX, row);
        CHECK(memcmp(row, s.ships[0].kit, sizeof row) != 0,
              "the row asked for is not the row on the ship");
        step_n(&s, &cfg, SIM_BTN_THRUST, 0, 30);
        CHECK(s.ships[0].y != s.ships[0].spawn_y, "the pilot had flown off");
        s.ships[0].energy -= 1;
        CHECK(sim_set_ship_class(&s, &cfg, 0, APEX, row) == -1,
              "a damaged pilot cannot change build either");
        CHECK(memcmp(s.ships[0].kit, row, sizeof row) != 0,
              "and is left flying the one they had");
        step_n(&s, &cfg, 0, 0, 40);      /* recharge to the top */
        CHECK(sim_set_ship_class(&s, &cfg, 0, APEX, row) == 0,
              "and can once the bar is full again");
        CHECK(memcmp(s.ships[0].kit, row, sizeof row) == 0, "in the new row");
        CHECK(s.ships[0].cls == APEX, "on the hull they never left");
        CHECK(s.ships[0].x == s.ships[0].spawn_x
              && s.ships[0].y == s.ships[0].spawn_y, "back at the start");
    }

    /* A bomb detonating on a wall damages a nearby enemy through splash. */
    {
        static sim_state s;
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
        static sim_state s;
        sim_init(&s, 1);
        /* Firing east into a target, with a second enemy a ship's length
         * past it and well inside the 48px blast. */
        sim_spawn(&s, ANVIL, 0, 8192, 8192, 16384, &cfg);
        sim_spawn(&s, APEX, 1, 8192 + 150, 8192, 0, &cfg);
        sim_spawn(&s, APEX, 1, 8192 + 175, 8192, 0, &cfg);
        /* One tick on the trigger, then hands off, so the count means one
         * bomb. The heavy's own blast reaches ten tiles, so the pilot who
         * threw it is inside it here and everybody else takes half: what is
         * under test is that the blast reaches two hulls, not what it did to
         * them. */
        ev_counts c = step_counting(&s, &cfg, SIM_BTN_BOMB, 0, 1);
        ev_counts d = step_counting(&s, &cfg, 0, 0, 120);
        CHECK(c.fires == 1, "one bomb was fired");
        CHECK(d.hits == 2, "the ship it hit and the one beside them both take it");
    }

    /* Out of range is not a detonation: a bomb has to arrive somewhere. */
    {
        static sim_state s;
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

}

static void test_weapon_model(sim_map *m, const sim_settings *base) {
    sim_settings cfg = *base;

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
        bare_kits(&w);
        sim_weapon_spec sp = w.specs[gun_of(&w, APEX)->spec];
        sim_fire_pattern fp = *gun_of(&w, APEX);
        fp.spec = (uint8_t)sim_add_spec(&w, &sp);
        fp.count = 3;
        fp.spacing = 65536 / 18;          /* twenty degrees */
        w.classes[APEX].trigger[SIM_TRIG_GUN][0] = (uint8_t)sim_add_pattern(&w, &fp);

        static sim_state s;
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
        bare_kits(&w);
        sim_weapon_spec sp = w.specs[gun_of(&w, APEX)->spec];
        sp.on_wall = SIM_WALL_BOUNCE;
        sp.bounces = 1;
        sim_fire_pattern fp = *gun_of(&w, APEX);
        fp.spec = (uint8_t)sim_add_spec(&w, &sp);
        w.classes[APEX].trigger[SIM_TRIG_GUN][0] = (uint8_t)sim_add_pattern(&w, &fp);

        static sim_state s;
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
        bare_kits(&w);
        sim_weapon_spec sp = w.specs[gun_of(&w, APEX)->spec];
        sp.on_wall = SIM_WALL_PASS;
        sim_fire_pattern fp = *gun_of(&w, APEX);
        fp.spec = (uint8_t)sim_add_spec(&w, &sp);
        w.classes[APEX].trigger[SIM_TRIG_GUN][0] = (uint8_t)sim_add_pattern(&w, &fp);

        static sim_state s;
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
        static sim_state s;
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
        static sim_state p;
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
        bare_kits(&w);

        sim_weapon_spec sp = w.specs[gun_of(&w, APEX)->spec];
        sp.life = 20;
        sp.expire_ends = 1;
        sp.splinter = shell_id;
        sim_fire_pattern fp = *gun_of(&w, APEX);
        fp.spec = (uint8_t)sim_add_spec(&w, &sp);
        w.classes[APEX].trigger[SIM_TRIG_GUN][0] = (uint8_t)sim_add_pattern(&w, &fp);

        static sim_state s;
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
        static sim_state t;
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

        static sim_state s;
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
        memcpy(sm, m, sizeof *sm);
        for (int ty = 497; ty <= 501; ty++)
            for (int tx = 510; tx <= 514; tx++)
                SIM_MAP_AT(sm, tx, ty) = SIM_TILE_SAFE;
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
        static sim_state s;
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
        uint16_t name = s.weapons[0].id;
        CHECK(name != 0, "a round in the air has a name");
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
        /* And it is the same round. A client used to name a round by its
         * owner, its spec and the tick it worked back from the life left,
         * and the reset above renamed the round under it: the next snapshot
         * carried a stranger, the client drew the old name detonating and
         * then watched the bomb fly back past it. The name is dealt at the
         * spawn now and nothing a round meets changes it. */
        CHECK(s.weapons[0].id == name,
              "and a repelled round keeps the name it was fired with");
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
        sim_settings rp = cfg;
        bare_kits(&rp);
        static sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &rp);         /* lets it off */
        sim_spawn(&s, APEX, 0, 8192 + 200, 8192, 0, &rp);   /* team mate   */
        sim_spawn(&s, APEX, 1, 8192 - 200, 8192, 0, &rp);   /* enemy       */
        s.ships[0].charge[0] = 1;

        /* A round of each side's in the air when it goes off. Both hulls face
         * north, so a bullet leaves with no sideways speed at all and any x
         * it has afterwards came from the shove. */
        static sim_state tmp;
        sim_input in[3] = {{0, 0}, {1, SIM_BTN_FIRE}, {2, SIM_BTN_FIRE}};
        sim_step(&tmp, &s, in, 3, &rp, NULL); s = tmp;
        CHECK(s.weapon_count >= 2, "both sides have a round in the air");

        in[1].buttons = 0;
        in[2].buttons = 0;
        in[0].buttons = SIM_BTN_USE;          /* slot zero is the repel */
        sim_step(&tmp, &s, in, 3, &rp, NULL); s = tmp;
        /* Spent on the tick it is asked for, but the round it makes carries
         * one tick of life, so the blast lands on the step after. */
        in[0].buttons = 0;
        sim_step(&tmp, &s, in, 3, &rp, NULL); s = tmp;

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

        static sim_state s;
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

}

static void test_tech_tree(const sim_settings *base) {
    sim_settings cfg = *base;

    /* --- the roster ----------------------------------------------------
     *
     * Seven ships, and each one is a whole ship: its own flight row, its own
     * gun and bomb, and its own profile over the slot space. Nobody spends
     * points on flight, so what is checked here is that the seven differ,
     * that each is internally consistent, that every weapon on them is a
     * ladder a pilot's credits can climb, and that no profile asks for
     * something its hull cannot carry. */
    {
        const int CHORD = 2, CIPHER = 4, LATTICE = 6;

        /* Flight is per hull and the step is zero, so what a hull flies at is
         * its floor and its ceiling at once. A nonzero step here would mean a
         * profile could buy speed, which is the thing that went. */
        for (int i = 0; i < cfg.class_count; i++) {
            const sim_ship_class *h = &cfg.classes[i];
            CHECK(h->up_speed == 0 && h->up_thrust == 0 && h->up_rot == 0
                      && h->up_energy == 0 && h->up_recharge == 0,
                  "no hull climbs a stat");
            CHECK(h->init_speed == h->max_speed
                      && h->init_thrust == h->thrust
                      && h->init_rot == h->rot
                      && h->init_energy == h->max_energy
                      && h->init_recharge == h->recharge,
                  "so its floor is its ceiling");
            for (int u = 0; u < SIM_UP_COUNT; u++)
                CHECK(h->kit[SIM_SLOT_STAT(u)] == 0,
                      "and no profile spends a stat step it cannot use");
        }

        /* Every hull inside the roster's bounds, which are the original's:
         * the span between what an Alpha Zone ship arrives with and what a
         * greened one reaches. */
        for (int i = 0; i < cfg.class_count; i++) {
            const sim_ship_class *h = &cfg.classes[i];
            CHECK(h->max_speed >= sim_units_speed(SIM_SPEED_MIN)
                      && h->max_speed <= sim_units_speed(SIM_SPEED_MAX),
                  "a hull flies inside the speed band");
            CHECK(h->rot >= sim_units_rotation(SIM_ROTATION_MIN)
                      && h->rot <= sim_units_rotation(SIM_ROTATION_MAX),
                  "and inside the rotation band");
            CHECK(h->max_energy >= sim_units_energy(SIM_ENERGY_MIN)
                      && h->max_energy <= sim_units_energy(SIM_ENERGY_MAX),
                  "and carries a bar inside the energy band");
            CHECK(h->recharge >= sim_units_recharge(SIM_RECHARGE_MIN)
                      && h->recharge <= sim_units_recharge(SIM_RECHARGE_MAX),
                  "and refills it inside the recharge band");
        }

        /* Both ends of the band are held, and a row is pulled back to the
         * edge rather than refused. Thrust is the one column with no bound,
         * so a row that asks for an absurd one keeps it. */
        {
            sim_class_units wild = {9000, 0, 9000, 900,  0, 900, 900, 0, 900,
                                    9000, 0, 9000, 9000, 0, 9000};
            sim_ship_class hot;
            sim_class_from_units(&hot, &wild);
            CHECK(hot.max_speed == sim_units_speed(SIM_SPEED_MAX)
                      && hot.rot == sim_units_rotation(SIM_ROTATION_MAX)
                      && hot.max_energy == sim_units_energy(SIM_ENERGY_MAX)
                      && hot.recharge == sim_units_recharge(SIM_RECHARGE_MAX),
                  "a row over the top is held at the ceiling");
            CHECK(hot.thrust == sim_units_thrust(900),
                  "but thrust is not bounded and keeps what it asked for");

            sim_class_units meek = {1, 0, 1, 1, 0, 1, 1, 0, 1, 1, 0, 1, 1, 0, 1};
            sim_ship_class cold;
            sim_class_from_units(&cold, &meek);
            CHECK(cold.init_speed == sim_units_speed(SIM_SPEED_MIN)
                      && cold.init_rot == sim_units_rotation(SIM_ROTATION_MIN)
                      && cold.init_energy == sim_units_energy(SIM_ENERGY_MIN)
                      && cold.init_recharge == sim_units_recharge(SIM_RECHARGE_MIN),
                  "and one under the bottom is held at the floor");
        }

        /* The spread, which is the roster. Speed and energy run opposite
         * ways down it, so nothing is at the top of two rows at once. */
        CHECK(cfg.classes[CIPHER].max_speed > cfg.classes[ANVIL].max_speed,
              "the raider outruns the heavy");
        CHECK(cfg.classes[ANVIL].max_energy > cfg.classes[CIPHER].max_energy,
              "and the heavy outlasts the raider");
        CHECK(cfg.classes[CHORD].rot > cfg.classes[ANVIL].rot,
              "the interceptor turns inside the heavy");
        CHECK(cfg.classes[CHORD].max_speed < cfg.classes[APEX].max_speed,
              "and cannot run anybody down");
        for (int i = 0; i < cfg.class_count; i++)
            for (int k = i + 1; k < cfg.class_count; k++)
                CHECK(cfg.classes[i].max_speed != cfg.classes[k].max_speed
                          || cfg.classes[i].max_energy
                                 != cfg.classes[k].max_energy,
                      "no two hulls fly the same way");

        /* Every hull has both triggers and they are the same two weapons.
         * A hull is a flight row and a footprint; nothing about what leaves
         * it is written on it, so the raider throws the heavy's bomb. */
        for (int i = 0; i < cfg.class_count; i++)
            for (int t = 0; t < SIM_TRIG_COUNT; t++) {
                CHECK(cfg.classes[i].trigger[t][0] != SIM_NO_PATTERN,
                      "every hull has both triggers");
                CHECK(cfg.classes[i].trigger[t][0]
                          == cfg.classes[0].trigger[t][0],
                      "and the same weapon on each as everybody else");
            }

        /* And every one of those is a ladder rather than a single weapon,
         * because a ladder of one is a slot a pilot cannot spend on.
         *
         * `sim_slot_cap` floors the level slot at the length of the hull's
         * own ladder, so a roster that names one rung each answers zero, and
         * a zero ceiling is a row the hangar does not draw at all. That is
         * how the gun and bomb Rung rows went missing from the ship page
         * while every line that drew them was correct: neither end was wrong
         * and there was no test standing where the two meet. This is that
         * test, and it asks the claim rather than the depth, so a balance
         * pass that shortens a ladder fails on the balance and not here.
         *
         * What a rung buys differs by trigger: a heavier round on the gun,
         * and on the rack the reach of the blast, since a bomb does 750 at
         * every level in the original and the radius is what a level moves.
         * Both cost more to let go of than the rung below, and neither moves
         * the rate, which is what keeps a level a trade. */
        for (int i = 0; i < cfg.class_count; i++) {
            for (int t = 0; t < SIM_TRIG_COUNT; t++) {
                uint8_t cap = sim_slot_cap(&cfg, (uint8_t)i,
                                           SIM_SLOT_LEVEL(t));
                if (cfg.classes[i].trigger[t][0] == SIM_NO_PATTERN) {
                    CHECK(cap == 0, "a trigger with no weapon has no rung");
                    continue;
                }
                CHECK(cap >= 1,
                      "a weapon a hull has is a weapon its pilot can level");
                for (int r = 1; r <= cap; r++) {
                    uint8_t hi = cfg.classes[i].trigger[t][r];
                    uint8_t lo = cfg.classes[i].trigger[t][r - 1];
                    CHECK(hi != SIM_NO_PATTERN,
                          "every rung inside the ceiling exists");
                    if (hi == SIM_NO_PATTERN) continue;
                    const sim_fire_pattern *up = &cfg.patterns[hi];
                    const sim_fire_pattern *at = &cfg.patterns[lo];
                    CHECK(up->energy > at->energy,
                          "and costs more to pull than the one under it");
                    CHECK(up->delay == at->delay,
                          "while the rate it fires at does not move");
                    const sim_weapon_spec *us = &cfg.specs[up->spec];
                    const sim_weapon_spec *as = &cfg.specs[at->spec];
                    if (t == SIM_TRIG_GUN) {
                        CHECK(us->damage > as->damage,
                              "a gun rung is a heavier round");
                        CHECK(us->blast == 0 && as->blast == 0,
                              "and never grows a blast");
                    } else {
                        CHECK(us->damage == as->damage,
                              "a bomb does the same damage at every level");
                        CHECK(us->blast > as->blast,
                              "and what a rung of it buys is reach");
                    }
                }
            }
        }

        /* The row a pilot arrives on, which the suite strips everywhere else.
         * One row, the same in every hull, spending every credit there is:
         * that is what "the build is the pilot's" means where a pilot has not
         * said anything yet. */
        static sim_settings fresh;
        memset(&fresh, 0, sizeof fresh);
        sim_settings_baseline(&fresh, cfg.map);
        for (int i = 0; i < fresh.class_count; i++)
            CHECK(memcmp(fresh.classes[i].kit, fresh.classes[0].kit,
                         SIM_SLOT_COUNT) == 0,
                  "every hull arrives on the same build");
        CHECK(sim_kit_cost(fresh.classes[0].kit) == SIM_KIT_CREDITS,
              "and it spends every credit a pilot has");

        /* Two kinds of charge and no more. A third would bind to no key, per
         * SIM_KIT_CHARGE_SLOTS. */
        {
            int kinds = 0;
            for (int k = 0; k < SIM_MAX_CHARGES; k++)
                if (fresh.classes[0].kit[SIM_SLOT_CHARGE(k)]) kinds++;
            CHECK(kinds <= SIM_KIT_CHARGE_SLOTS,
                  "the arrival build carries no third charge kind");
        }

        /* It never asks for more than a slot can physically hold, so dealing
         * it lands exactly what it names, in whichever hull. */
        for (int i = 0; i < fresh.class_count; i++) {
            static sim_state probe;
            sim_init(&probe, 7);
            int seat = sim_spawn(&probe, (uint8_t)i, 0, 8192, 8192, 0, &fresh);
            CHECK(seat >= 0, "the hull seats");
            const sim_ship *sh = &probe.ships[seat];
            const uint8_t *kit = fresh.classes[i].kit;
            for (int t = 0; t < SIM_TRIG_COUNT; t++) {
                CHECK(sh->level[t] == kit[SIM_SLOT_LEVEL(t)],
                      "the rung it names is the rung it flies");
                for (int m = 0; m < SIM_MOD_COUNT; m++)
                    CHECK(sim_mod_get(sh->mods[t], m)
                              == kit[SIM_SLOT_MOD(t, m)],
                          "every add-on it names is worn");
            }
            for (int k = 0; k < SIM_MAX_CHARGES; k++)
                CHECK(sh->charge[k] == kit[SIM_SLOT_CHARGE(k)],
                      "and every charge it names is racked");
        }

        /* What is left of a hull is its footprint, and it had better still
         * differ or the roster is seven names for one ship. */
        const int FACET = 5;
        CHECK(cfg.classes[CIPHER].halfw < cfg.classes[FACET].halfw,
              "the knife is thinner from the side than the squat one");
        CHECK(cfg.classes[CIPHER].fore > cfg.classes[FACET].fore,
              "and longer down the nose");
        CHECK(cfg.classes[LATTICE].fore != cfg.classes[APEX].fore
                  || cfg.classes[LATTICE].halfw != cfg.classes[APEX].halfw,
              "and the square hulls present differently from the dart");

        /* One named slot at a time, with the arena's ceilings enforced.
         * `sim_deal_kit` is this in a loop. */
        sim_settings tall = cfg;
        /* A hull whose ladder has a second rung, since the shipped roster
         * names one each and a grant needs somewhere to climb to. */
        tall.classes[APEX].trigger[SIM_TRIG_GUN][1] =
            cfg.classes[ANVIL].trigger[SIM_TRIG_GUN][0];
        sim_ship sh;
        memset(&sh, 0, sizeof sh);
        sh.cls = (uint8_t)APEX;
        CHECK(sim_grant(&sh, &tall, SIM_SLOT_LEVEL(SIM_TRIG_GUN)) == 1
              && sh.level[SIM_TRIG_GUN] == 1, "a granted rung is a rung climbed");
        CHECK(sim_grant(&sh, &cfg, SIM_SLOT_MOD(SIM_TRIG_GUN, SIM_MOD_MULTI)) == 1
              && sim_mod_get(sh.mods[SIM_TRIG_GUN], SIM_MOD_MULTI) == 1,
              "and a granted add-on is an add-on held");

        /* Up the ladder until it refuses. A stage asking for more rungs than
         * a hull has is a stage that hull cannot wear, and the harness has to
         * read that off the return: a silent refusal would report a loadout
         * fighting itself as a loadout that is worth nothing. */
        int granted = 1;
        for (int i = 0; i < SIM_MAX_RUNGS + 4 && granted; i++)
            granted = sim_grant(&sh, &tall, SIM_SLOT_LEVEL(SIM_TRIG_GUN));
        CHECK(granted == 0, "the ladder ends and the grant says so");
        uint8_t top = sh.level[SIM_TRIG_GUN];
        CHECK(sim_grant(&sh, &cfg, SIM_SLOT_LEVEL(SIM_TRIG_GUN)) == 0
              && sh.level[SIM_TRIG_GUN] == top, "and it stays refused there");

        /* A trigger the hull does not have refuses outright at rung zero. */
        sim_settings *rackless = malloc(sizeof *rackless);
        *rackless = cfg;
        for (int r = 0; r < SIM_MAX_RUNGS; r++)
            rackless->classes[CIPHER].trigger[SIM_TRIG_BOMB][r] = SIM_NO_PATTERN;
        sim_ship gunner;
        memset(&gunner, 0, sizeof gunner);
        gunner.cls = (uint8_t)CIPHER;
        CHECK(sim_grant(&gunner, rackless, SIM_SLOT_LEVEL(SIM_TRIG_BOMB)) == 0
              && gunner.level[SIM_TRIG_BOMB] == 0,
              "a hull with no rack cannot be granted a bomb rung");
        free(rackless);

        /* Out of the space entirely is refused rather than written past the
         * end of the counts it would have indexed. */
        CHECK(sim_grant(&sh, &cfg, SIM_SLOT_COUNT) == 0, "no such slot");
    }

    {
        /* Spray composes onto whatever rung the trigger is on, and it is the
         * one add-on that changes what pulling the trigger costs.
         *
         * The original charged 20 energy for a bullet and 30 for multifire,
         * and waited 25 ticks against 50: half again the energy and twice the
         * cooldown, for three rounds. Two rounds more, so per round it is a
         * quarter of the energy and half the wait, and that is what the ladder
         * charges. Three rounds therefore lands exactly where the original put
         * it and the rungs above climb at the same rate rather than at one
         * invented for the top.
         *
         * Most of the price is in the rate, which is the half a pilot cannot
         * out-recharge. */
        uint16_t plain_wait = 0, two_wait = 0;
        int32_t plain = gun_cost(&cfg, (uint8_t)APEX, 0, 0, &plain_wait);
        int32_t two = gun_cost(&cfg, (uint8_t)APEX, 0,
                               sim_mod_set(0, SIM_MOD_MULTI, 2), &two_wait);
        CHECK(two == plain * 3 / 2, "three rounds cost half again the energy");
        CHECK(two_wait == plain_wait * 2, "and twice the wait");

        /* Linear in the rung, because every other add-on here is and this one
         * has no reason not to be. */
        uint16_t one_wait = 0;
        int32_t one = gun_cost(&cfg, (uint8_t)APEX, 0,
                               sim_mod_set(0, SIM_MOD_MULTI, 1), &one_wait);
        CHECK(one == plain * 5 / 4, "a pair is a quarter more energy");
        CHECK(one_wait == plain_wait * 3 / 2, "and half again the wait");

        /* And it is still a group of rounds, which is what you paid for. */
        static sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        s.ships[0].mods[SIM_TRIG_GUN] = sim_mod_set(0, SIM_MOD_MULTI, 1);
        step_n(&s, &cfg, SIM_BTN_FIRE, 0, 1);
        CHECK(s.weapon_count == 1 + cfg.mod_step[SIM_MOD_MULTI],
              "a rung of spray is one more round");
        CHECK(s.weapons[0].vx != s.weapons[1].vx, "and they fan out");
    }

    {
        /* Spray. This was two add-ons: a wide multifire fan that charged
         * energy and cooldown, and a tight pair of barrels that charged
         * energy alone. Both spelled "more bullets", so they are one ladder
         * whose rung is a round, and the pair is where the second add-on
         * used to be. */
        const int FACET = 5;
        const uint16_t ONE = sim_mod_set(0, SIM_MOD_MULTI, 1);
        static sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        s.ships[0].mods[SIM_TRIG_GUN] = ONE;
        step_n(&s, &cfg, SIM_BTN_FIRE, 0, 1);
        CHECK(s.weapon_count == 2, "one rung of spray sends two rounds");

        /* One either side of where the nose points. Not exact mirrors: the
         * offsets are, but a heading is quantised to 4096 entries on the way
         * into the table and truncation takes the negative one a step further
         * out, so this asks for the sign and not the magnitude. */
        CHECK((s.weapons[0].vx < 0) != (s.weapons[1].vx < 0),
              "one either side of where it is pointing");

        /* And the count is the build's, all the way up the ladder: four rungs
         * of spray is five rounds, off whichever hull bought them. */
        static sim_state f;
        sim_init(&f, 1);
        sim_spawn(&f, (uint8_t)FACET, 0, 8192, 8192, 0, &cfg);
        f.ships[0].mods[SIM_TRIG_GUN] = sim_mod_set(0, SIM_MOD_MULTI, 4);
        step_n(&f, &cfg, SIM_BTN_FIRE, 0, 1);
        CHECK(f.weapon_count == 5, "four rungs of spray is five at a pull");

        /* Fanned and not scattered, which is a real distinction here: spacing
         * of zero on a pattern of many is the shrapnel encoding, and it rolls
         * every round's heading off the state's own generator. So move the
         * generator and fire again. A fan cannot notice. */
        static sim_state r;
        sim_init(&r, 1);
        sim_spawn(&r, APEX, 0, 8192, 8192, 0, &cfg);
        r.ships[0].mods[SIM_TRIG_GUN] = ONE;
        r.rng = 0x5eed1234u;
        step_n(&r, &cfg, SIM_BTN_FIRE, 0, 1);
        CHECK(r.weapon_count == s.weapon_count
              && r.weapons[0].vx == s.weapons[0].vx
              && r.weapons[1].vx == s.weapons[1].vx,
              "and they are aimed rather than scattered");

        /* A rung is a round, all the way up. Three rungs is four rounds and
         * not the eight a doubling would give: `compose` adds to the
         * pattern's own count, which is what made the original's odd
         * arithmetic fall out of the model. */
        static sim_state m;
        sim_init(&m, 1);
        sim_spawn(&m, APEX, 0, 8192, 8192, 0, &cfg);
        m.ships[0].mods[SIM_TRIG_GUN] = sim_mod_set(0, SIM_MOD_MULTI, 3);
        step_n(&m, &cfg, SIM_BTN_FIRE, 0, 1);
        CHECK(m.weapon_count == 4, "three rungs of spray sends four rounds");

        /* And the ladder reaches six, which needs three bits of the mods
         * word and is the reason spray has its own packing. */
        static sim_state top;
        sim_init(&top, 1);
        sim_spawn(&top, APEX, 0, 8192, 8192, 0, &cfg);
        top.ships[0].mods[SIM_TRIG_GUN] =
            sim_mod_set(0, SIM_MOD_MULTI, SIM_MOD_MULTI_MAX);
        CHECK(sim_mod_get(top.ships[0].mods[SIM_TRIG_GUN], SIM_MOD_MULTI)
                  == SIM_MOD_MULTI_MAX,
              "the top of the ladder survives the word it is packed into");
        step_n(&top, &cfg, SIM_BTN_FIRE, 0, 1);
        CHECK(top.weapon_count == SIM_MOD_MULTI_MAX + 1,
              "and the top of it is six rounds");

        /* And the packing leaves the other six alone: they are two bits each
         * at the bottom of the word and spray is three at the top, so a shot
         * carrying both reads back as both. */
        uint16_t both = sim_mod_set(sim_mod_set(0, SIM_MOD_MULTI, 5),
                                    SIM_MOD_BOUNCE, 3);
        CHECK(sim_mod_get(both, SIM_MOD_MULTI) == 5
                  && sim_mod_get(both, SIM_MOD_BOUNCE) == 3,
              "spray and a rung of bouncing do not share bits");

        /* A pair leaves tight and a spray opens out, which is the step that
         * used to be the difference between two add-ons. */
        CHECK(cfg.mod_pair_spread < cfg.mod_spread,
              "a pair leaves closer together than a fan");
        /* How far off the nose the outermost round leaves, which is the whole
         * of what a spread is. Every ship here points along +y, so vx is the
         * sideways half of the velocity and its largest magnitude is the edge
         * of the group. */
        int32_t widest[2] = {0, 0};
        const sim_state *pair[2] = {&s, &m};
        for (int g = 0; g < 2; g++)
            for (uint16_t k = 0; k < pair[g]->weapon_count; k++) {
                int32_t vx = pair[g]->weapons[k].vx;
                if (vx < 0) vx = -vx;
                if (vx > widest[g]) widest[g] = vx;
            }
        CHECK(widest[1] > widest[0],
              "and a fan throws its outside round wider than a pair does");

        /* What a round costs, which is the half of this that is ours. The
         * original charged nothing for DoubleBarrel, which was fine while one
         * hull had it and could not choose otherwise; as something a pilot
         * buys, free rounds would end every argument about gun add-ons. So
         * every rung charges both energy and cooldown, and the pair that used
         * to be free now pays for itself. */
        uint16_t plain_wait = 0, one_wait = 0, three_wait = 0;
        int32_t plain = gun_cost(&cfg, APEX, 0, 0, &plain_wait);
        int32_t one = gun_cost(&cfg, APEX, 0, ONE, &one_wait);
        int32_t three = gun_cost(&cfg, APEX, 0,
                                 sim_mod_set(0, SIM_MOD_MULTI, 3),
                                 &three_wait);
        CHECK(one > plain, "a round of spray costs energy");
        CHECK(one_wait > plain_wait, "and cooldown, which a barrel did not");
        CHECK(three > one && three_wait > one_wait,
              "and both climb with the ladder");
    }

    {
        /* Climbing a rung swaps which pattern the trigger fires, off the
         * ladder the baseline ships: three rungs, and a credit apiece. */
        sim_settings w = cfg;
        bare_kits(&w);
        static sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &w);
        const sim_ship_class *c = &w.classes[APEX];
        int32_t l1 = w.specs[w.patterns[c->trigger[SIM_TRIG_GUN][0]].spec].damage;
        int32_t l2 = w.specs[w.patterns[c->trigger[SIM_TRIG_GUN][1]].spec].damage;
        CHECK(l2 > l1, "the rung above hits harder");
        s.ships[0].level[SIM_TRIG_GUN] = 1;
        step_n(&s, &w, SIM_BTN_FIRE, 0, 1);
        CHECK(s.weapon_count == 1, "fired");
        CHECK(w.specs[s.weapons[0].spec].damage == l2,
              "and what left the ship is the rung it is on");

        /* And it costs what its own pattern says: BulletFireEnergy times the
         * level, so the rung above is dearer to pull. */
        CHECK(gun_cost(&w, (uint8_t)APEX, 1, 0, NULL)
                  > gun_cost(&w, (uint8_t)APEX, 0, 0, NULL),
              "and the heavier round costs more to throw");
    }

    {
        /* A bullet always deals the old damage curve's mean. Drive rounds
         * directly into a stationary hull so flight and recharge cannot
         * muddy the amount. */
        sim_settings w = cfg;
        w.classes[APEX].recharge = 0;
        static sim_state s;
        sim_init(&s, 0x5eed1234u);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &w);
        sim_spawn(&s, APEX, 1, 8200, 8192, 0, &w);
        uint8_t bullet = gun_of(&w, APEX)->spec;
        int32_t ceiling = w.specs[bullet].damage;
        int32_t expected = (int32_t)((int64_t)ceiling * 2 / 3);
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
            CHECK(dealt == expected,
                  "every bullet deals the fixed average damage");
        }
    }

    {
        /* Every round from one gun pull shares a link. The first hull hit
         * spends the siblings without letting a tight multifire fan stack
         * three hits on the same target. */
        sim_settings w = cfg;
        uint8_t bullet = gun_of(&w, APEX)->spec;
        w.specs[bullet].stall = 1; /* make each sibling collision observable */
        static sim_state s;
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
        static sim_state next;
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
        static sim_state wall;
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
        static sim_state s;
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
        /* What one bounce rung buys, which is not the same round on both
         * triggers. The rung lifts either weapon off the wall; how many walls
         * it then survives is the weapon's own count, and the bullet's is 255.
         * That is the original's BouncingBullets prize, and a bullet cannot
         * spend it: 550 ticks of life over 69 tiles would need a wall every
         * four pixels. The bomb's count is zero and the rung's step is one, so
         * a bomb gets exactly one, which is the whole reason the count sits on
         * the spec rather than on the shared step. */
        const int LATTICE = 6;
        sim_settings w = cfg;

        static sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, LATTICE, 0, 8192, 8192, 0, &w);
        s.ships[0].mods[SIM_TRIG_GUN] = sim_mod_set(0, SIM_MOD_BOUNCE, 1);
        step_n(&s, &w, SIM_BTN_FIRE, 0, 1);
        CHECK(s.weapon_count == 1, "a bullet away");
        CHECK(s.weapons[0].left == 255,
              "and its one rung ricochets without limit");

        sim_init(&s, 1);
        sim_spawn(&s, LATTICE, 0, 8192, 8192, 0, &w);
        s.ships[0].mods[SIM_TRIG_BOMB] = sim_mod_set(0, SIM_MOD_BOUNCE, 1);
        step_n(&s, &w, SIM_BTN_BOMB, 0, 1);
        CHECK(s.weapon_count == 1, "a bomb away");
        CHECK(s.weapons[0].left == 1,
              "and the same rung buys the bomb exactly one wall");

        /* A fragment starts with no free wall and inherits the parent's one
         * bounce rung when the shrapnel is composed. */
        for (int k = 1; k < SIM_MAX_RUNGS; k++) {
            const sim_weapon_spec *fs =
                &w.specs[w.patterns[w.mod_splinter[k]].spec];
            CHECK(fs->bounces == 0, "and a fragment has no hidden free walls");
        }
    }

    {
        /* Shrapnel is the one add-on whose magnitude is another weapon, and
         * fragments do not inherit it: a shell that broke into eight would
         * otherwise have each of those break into eight again. */
        const int WEDGE = 1;
        sim_settings w = cfg;
        static sim_state s;
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
        ev_counts ec = {0, 0, 0, 0, 0, 0, 0, 0, 255, 0};
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
        w.mod_step[SIM_MOD_BOUNCE] = 20;
        sim_weapon_spec sp = w.specs[gun_of(&w, APEX)->spec];
        sp.on_wall = SIM_WALL_BOUNCE;
        sp.bounces = 250;
        sim_fire_pattern fp = *gun_of(&w, APEX);
        fp.spec = (uint8_t)sim_add_spec(&w, &sp);
        w.classes[APEX].trigger[SIM_TRIG_GUN][0] = (uint8_t)sim_add_pattern(&w, &fp);

        static sim_state s;
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
        static sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, LATTICE, 0, 8192, 8192, 0, &cfg);
        sim_spawn(&s, APEX, 1, 8192, 8192 - 120, 0, &cfg);
        s.ships[0].charge[0] = 2;
        int32_t vy0 = s.ships[1].vy, e1 = s.ships[1].energy;

        /* The slot rides in the buttons rather than on the ship: choosing
         * which charge is ready is the client's business. */
        uint16_t use = SIM_BTN_USE | (0u << SIM_BTN_SLOT_SHIFT);
        ev_counts c = step_counting(&s, &cfg, use, 0, 1);
        CHECK(s.ships[0].charge[0] == 1, "one repel is spent");
        CHECK(c.fires > 0, "and it counts as a shot");

        /* A charge goes on the press. Keeping the button down spends nothing
         * more: a rack is a count of presses, not a rate of fire. */
        step_n(&s, &cfg, use, 0, 3);
        CHECK(s.ships[0].charge[0] == 1, "holding it down spends no more");

        /* The repel's own delay is zero, so inventory is the whole of the
         * limit on this kind. Let go, press again, and the second one goes at
         * once while the first is still in the air. */
        step_n(&s, &cfg, 0, 0, 1);
        step_n(&s, &cfg, use, 0, 1);
        CHECK(s.ships[0].charge[0] == 0, "the second follows immediately");
        CHECK(s.ships[1].vy < vy0, "the neighbour is shoved away");
        CHECK(s.ships[1].energy >= e1, "and not hurt");
        for (int i = 0; i < 5; i++) {
            step_n(&s, &cfg, 0, 0, 1);
            step_n(&s, &cfg, use, 0, 1);
        }
        CHECK(s.ships[0].charge[0] == 0, "and an empty slot fires nothing");
    }

    {
        /* A shot outlives its owner, whole.
         *
         * The rung is baked into the projectile's `spec` at the moment it is
         * fired -- a level-two bullet was spawned from the level-two pattern
         * -- exactly as the add-ons are baked into its `mods`. So the
         * inventory a death clears is what gates *firing*, and nothing that
         * is already in the air reads it. */
        sim_settings w = cfg;
        bare_kits(&w);
        static sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &w);
        sim_spawn(&s, APEX, 1, 8192, 8192 - 300, 0, &w);
        const sim_ship_class *c = &w.classes[APEX];
        int32_t l1 = w.specs[w.patterns[c->trigger[SIM_TRIG_GUN][0]].spec].damage;
        int32_t l2 = w.specs[w.patterns[c->trigger[SIM_TRIG_GUN][1]].spec].damage;

        s.ships[0].level[SIM_TRIG_GUN] = 1;
        s.ships[0].mods[SIM_TRIG_GUN] = sim_mod_set(0, SIM_MOD_MULTI, 2);
        step_n(&s, &w, SIM_BTN_FIRE, 0, 1);
        CHECK(s.weapon_count == 3, "a leveled, sprayed shot leaves");
        uint8_t spec = s.weapons[0].spec;
        uint16_t mods = s.weapons[0].mods;
        CHECK(w.specs[spec].damage == l2 && l2 > l1,
              "and it is the harder round");

        /* Kill the owner outright and strip them, exactly as a death does. */
        s.ships[0].alive = 0;
        s.ships[0].respawn_at = 3000;
        memset(s.ships[0].up, 0, sizeof s.ships[0].up);
        memset(s.ships[0].level, 0, sizeof s.ships[0].level);
        memset(s.ships[0].mods, 0, sizeof s.ships[0].mods);
        memset(s.ships[0].charge, 0, sizeof s.ships[0].charge);

        step_n(&s, &w, 0, 0, 1);
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
            sim_step(&tmp, &s, in, 2, &w, &ev);
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
        static sim_state s;
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
        /* And a burst shuts its own key behind it, so the rack is not one
         * approach.
         *
         * Three presses were the whole of it: no energy, no clock, and a hand
         * makes three presses inside a tenth of a second. So a pilot flew in,
         * tapped, and put seventy-two rounds through whoever was standing
         * there, of which the last forty-eight asked nothing of them that the
         * first twenty-four had not already asked. The clock does not touch
         * what a burst does; it decides when the next one may be a decision.
         *
         * Read off the pattern rather than written here, because the number
         * is the arena's. What this pins is that the shipped one is a real
         * wait rather than a rounding error, and that the clock is exactly as
         * long as the pattern says. */
        const int BURST = SIM_CHARGE_BURST;
        const uint16_t use =
            (uint16_t)(SIM_BTN_USE | ((uint16_t)BURST << SIM_BTN_SLOT_SHIFT));
        const uint16_t wait = cfg.patterns[cfg.charge[BURST]].delay;
        CHECK(wait >= 100, "the shipped burst waits a real interval, not ticks");

        static sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        s.ships[0].charge[BURST] = 3;
        /* Press, release, press, release, press: as fast as the rack can be
         * asked for, and faster than any hand actually manages. */
        for (int i = 0; i < 3; i++) {
            step_n(&s, &cfg, use, 0, 1);
            step_n(&s, &cfg, 0, 0, 1);
        }
        CHECK(s.ships[0].charge[BURST] == 2, "one approach throws one burst");
        CHECK(s.weapon_count == 24, "twenty-four rounds in the air, not 72");
        CHECK(s.ships[0].charge_cooldown[BURST] > 0, "with the key shut behind it");

        /* A tick short of the delay it is still shut. */
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        s.ships[0].charge[BURST] = 3;
        step_n(&s, &cfg, use, 0, 1);
        step_n(&s, &cfg, 0, 0, (int)wait - 2);
        step_n(&s, &cfg, use, 0, 1);
        CHECK(s.ships[0].charge[BURST] == 2, "a tick short throws nothing");

        /* On the tick it runs out, the next one goes. */
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        s.ships[0].charge[BURST] = 3;
        step_n(&s, &cfg, use, 0, 1);
        step_n(&s, &cfg, 0, 0, (int)wait - 1);
        step_n(&s, &cfg, use, 0, 1);
        CHECK(s.ships[0].charge[BURST] == 1, "and the second goes when it does");

        /* A clock per kind. A burst does not shut the repel: one is the answer
         * to a round already arriving and the other is why one is arriving, so
         * a single clock over the rack would take the answer away exactly when
         * a pilot wants it. */
        const uint16_t rep = (uint16_t)(SIM_BTN_USE
                             | ((uint16_t)SIM_CHARGE_REPEL << SIM_BTN_SLOT_SHIFT));
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        s.ships[0].charge[SIM_CHARGE_BURST] = 1;
        s.ships[0].charge[SIM_CHARGE_REPEL] = 1;
        step_n(&s, &cfg, use, 0, 1);
        step_n(&s, &cfg, 0, 0, 1);
        step_n(&s, &cfg, rep, 0, 1);
        CHECK(s.ships[0].charge[SIM_CHARGE_REPEL] == 0,
              "a burst leaves the repel alone");

        /* The clock belongs to the ammunition, which is the one thing a death
         * does not give back, so a death does not hand the next burst over
         * early either. */
        sim_settings dk = cfg;
        dk.respawn_delay = 2;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &dk);
        s.ships[0].charge[BURST] = 3;
        step_n(&s, &dk, use, 0, 1);
        s.ships[0].alive = 0;
        s.ships[0].respawn_at = 2;
        step_n(&s, &dk, 0, 0, 4);
        CHECK(s.ships[0].alive, "the pilot is back");
        CHECK(s.ships[0].charge_cooldown[BURST] > 0, "and the key is still shut");
        step_n(&s, &dk, use, 0, 1);
        CHECK(s.ships[0].charge[BURST] == 2, "so dying is not a way to reload");

        /* A whistle is: the rack is dealt afresh at a match start, and its
         * clocks go with it. A burst thrown at the end of one match cannot
         * shut the key at the start of the next. */
        sim_restart(&s, &dk);
        CHECK(s.ships[0].charge_cooldown[BURST] == 0, "a whistle clears them");
    }

    {
        /* A death costs the run and whatever ammunition was already spent.
         * The frame comes back at the respawn, dealt from the build the pilot
         * bought, because a build is what they own rather than something they
         * survived with. */
        sim_settings dk = cfg;
        dk.respawn_delay = 4;
        static sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &dk);
        sim_spawn(&s, APEX, 1, 8192, 8192 - 200, 32768, &dk);
        uint8_t bought[SIM_SLOT_COUNT];
        memset(bought, 0, sizeof bought);
        bought[SIM_SLOT_MOD(SIM_TRIG_GUN, SIM_MOD_MULTI)] = 1;
        bought[SIM_SLOT_CHARGE(SIM_CHARGE_BURST)] = 1;
        CHECK(sim_set_ship_kit(&s, &dk, 0, bought) == 0, "the build is dealt");
        s.ships[0].streak = 5;
        s.ships[0].charge[SIM_CHARGE_BURST] = 0;   /* the one it had, spent */
        s.ships[0].energy = 1;
        step_counting(&s, &dk, 0, SIM_BTN_FIRE, 400);
        CHECK(s.ships[0].deaths > 0, "the target dies");
        CHECK(s.ships[0].streak == 0, "and the run it was on is over");
        CHECK(s.ships[0].alive, "and comes back inside the run");
        CHECK(sim_mod_get(s.ships[0].mods[SIM_TRIG_GUN], SIM_MOD_MULTI) == 1,
              "with the build re-dealt");
        CHECK(s.ships[0].charge[SIM_CHARGE_BURST] == 0,
              "but not the burst it had already spent");
    }

}

static void test_scoring(const sim_settings *base) {
    sim_settings cfg = *base;

    /* --- the counters ---------------------------------------------------
     *
     * Kills, deaths, assists and a streak. There were two more and they were
     * the same number twice: bounty priced a kill and points banked it. Both
     * are gone, so what a kill moves is the killer's own count and the room's
     * score, and the streak is the one thing this game still says about how a
     * pilot is doing right now.
     *
     * The count is its own field rather than something derived, so a zone
     * that retunes anything else does not thereby change what a streak is. */
    {
        sim_ship sh;
        memset(&sh, 0, sizeof sh);
        sh.streak = 2;
        CHECK(!sim_on_streak(&cfg, &sh), "two kills is not a streak");
        sh.streak = 3;
        CHECK(sim_on_streak(&cfg, &sh), "the third kill makes one");
        sh.streak = 9;
        CHECK(sim_on_streak(&cfg, &sh), "and it holds while the run does");

        /* And a zone that wants none of it says so with a zero. */
        sim_settings off = cfg;
        off.streak_kills = 0;
        CHECK(!sim_on_streak(&off, &sh), "no threshold, no streak");
    }

    {
        /* The arena is told, once, on the kill that reaches the threshold.
         *
         * A respawn draws a fresh start somewhere else on the map, so the
         * victim is put back in front of the guns each time rather than left
         * to be hunted: what is under test is the counter, not the shooting.
         */
        static sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 32768, &cfg);      /* faces down */
        sim_spawn(&s, APEX, 1, 8192, 8192 + 200, 0, &cfg);    /* the victim */
        int streaks = 0, at_two = -1;
        uint8_t who = 255;
        int32_t len = 0;
        /* Positions inside the state are Q8, where sim_spawn takes pixels. */
        const int32_t px = 8192 << 8, py = (8192 + 200) << 8;
        for (int t = 0; t < 4000 && s.ships[0].kills < 4; t++) {
            if (s.ships[1].alive) {
                s.ships[1].x = px;
                s.ships[1].y = py;
                s.ships[1].vx = s.ships[1].vy = 0;
                s.ships[1].energy = 1;
            }
            sim_state tmp;
            sim_events ev;
            sim_input in[2] = {{0, SIM_BTN_FIRE}, {1, 0}};
            sim_step(&tmp, &s, in, 2, &cfg, &ev);
            s = tmp;
            for (uint16_t e = 0; e < ev.count; e++) {
                if (ev.e[e].type != SIM_EV_STREAK) continue;
                streaks++;
                who = ev.e[e].a;
                len = ev.e[e].v;
            }
            if (s.ships[0].kills == 2 && at_two < 0) at_two = streaks;
        }
        CHECK(s.ships[0].kills == 4, "four kills, and no death in between");
        CHECK(at_two == 0, "nothing is said at two");
        CHECK(streaks == 1, "the third says it, and the fourth says nothing");
        CHECK(who == 0, "named the pilot who is on it");
        CHECK(len == (int32_t)cfg.streak_kills, "and how long it is");
        CHECK(s.ships[0].streak == 4, "the count carries on past the news");
        CHECK(sim_on_streak(&cfg, &s.ships[0]), "and they are still on it");

        /* Until somebody takes them, which is the whole of what ends it. */
        s.ships[0].x = px;
        s.ships[0].y = 8192 << 8;
        s.ships[0].vx = s.ships[0].vy = 0;
        s.ships[0].energy = 1;
        s.ships[1].x = px;
        s.ships[1].y = py;
        s.ships[1].heading = 0;
        s.ships[1].vx = s.ships[1].vy = 0;
        /* The victim was mid-respawn when the loop stopped. Put them back on
         * their feet with a bar to shoot with, since what is under test now
         * is the streak ending rather than how they got up. */
        s.ships[1].alive = 1;
        s.ships[1].respawn_at = 0;
        s.ships[1].energy =
            sim_eff_max_energy(&cfg.classes[APEX], &s.ships[1]);
        ev_counts c = step_counting(&s, &cfg, 0, SIM_BTN_FIRE, 400);
        CHECK(c.deaths > 0, "the pilot on the streak dies");
        CHECK(s.ships[0].streak == 0, "which is what ends a streak");
        CHECK(!sim_on_streak(&cfg, &s.ships[0]), "they are off it");
        CHECK(c.streaks == 0, "the kill that ended it was only their first");
    }

    {
        /* Every kill counts once, whoever it was against. Nothing is paid,
         * which takes the anti-farming question with it: camping a respawn is
         * worth exactly what any other kill is worth. */
        static sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 32768, &cfg);      /* faces down */
        sim_spawn(&s, APEX, 1, 8192, 8192 + 200, 0, &cfg);    /* the victim */
        s.ships[1].energy = 1;
        step_counting(&s, &cfg, SIM_BTN_FIRE, 0, 400);
        CHECK(s.ships[1].deaths > 0, "the fresh pilot dies");
        CHECK(s.ships[0].kills == 1, "and it counts as a kill");
        CHECK(s.ships[0].streak == 1, "which is one into a run");

        /* The same kill against somebody deep into a run counts the same,
         * and ends theirs. */
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 32768, &cfg);
        sim_spawn(&s, APEX, 1, 8192, 8192 + 200, 0, &cfg);
        s.ships[1].streak = 4;
        s.ships[1].energy = 1;
        step_counting(&s, &cfg, SIM_BTN_FIRE, 0, 400);
        CHECK(s.ships[1].deaths > 0, "they die too");
        CHECK(s.ships[0].kills == 1, "and it is still one kill");
        CHECK(s.ships[1].streak == 0, "with their run ended by it");
    }

    {
        /* A teammate's death pays neither points nor bounty, which is the
         * rule the rating layer already applies to teammate damage.
         *
         * A weapon never arrives at a teammate, so the only way to kill one
         * is a blast -- which does not check teams, and is exactly why the
         * rule has to exist. */
        static sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, ANVIL, 0, 8192, 120, 0, &cfg);        /* faces the wall */
        sim_spawn(&s, APEX, 0, 8192, 55, 0, &cfg);          /* same team, near it */
        s.ships[1].up[SIM_UP_SPEED] = 6;
        s.ships[1].energy = 1;
        ev_counts c = step_counting(&s, &cfg, SIM_BTN_BOMB, 0, 200);
        CHECK(c.deaths > 0, "the bomb's blast kills the teammate");
        CHECK(s.ships[1].deaths == 1, "and it is the teammate who died");
        CHECK(s.ships[0].streak == 0, "and starts no run");
        /* And it costs a kill, from zero, which is what makes the counter
         * signed. It used to *credit* one: the same number went up whether
         * you shot an enemy or your own wingman. */
        CHECK(s.ships[0].kills == -1, "a teamkill takes a kill off the board");
    }

    {
        /* Your own bomb, at your own feet. Same arithmetic as a teamkill and
         * for the same reason: a scoreboard that can only go up says nothing
         * about the pilot who is mostly killing themselves. */
        static sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, ANVIL, 0, 8192, 55, 0, &cfg);         /* on top of it */
        s.ships[0].kills = 2;
        /* Held, so the rack keeps throwing them: one bomb at this range does
         * not empty an Anvil, and what kills the pilot is doing it again. */
        ev_counts c = step_counting(&s, &cfg, SIM_BTN_BOMB, 0, 600);
        CHECK(c.deaths > 0, "bombing the wall in their own lap kills them");
        CHECK(s.ships[0].deaths >= 1, "which is a death like any other");
        CHECK(s.ships[0].kills < 2, "and it costs them what they had taken");
    }

    {
        /* Two kinds of charge and no more, on every hull in the roster.
         *
         * Whichever two a profile names bind to Q and W in kind order, so a
         * third would have no key to be thrown with. The rack holds four so a
         * zone can fill a spare slot; what it may not do is fill three on one
         * hull. */
        for (int i = 0; i < cfg.class_count; i++) {
            static sim_state s;
            sim_init(&s, 1);
            int seat = sim_spawn(&s, (uint8_t)i, 0, 8192, 8192, 0, &cfg);
            CHECK(seat >= 0, "the hull seats");
            int kinds = 0;
            for (int k = 0; k < SIM_MAX_CHARGES; k++)
                if (s.ships[seat].charge[k]) kinds++;
            CHECK(kinds <= SIM_KIT_CHARGE_SLOTS,
                  "no hull is dealt a third kind of charge");
        }

        /* A kind the zone leaves empty is a kind nothing is dealt, however
         * loudly a build asks for it. */
        const int LATTICE = 6;
        static sim_settings none;
        none = cfg;
        none.charge[SIM_CHARGE_REPEL] = SIM_NO_PATTERN;
        for (int i = 0; i < none.class_count; i++) {
            none.classes[i].kit[SIM_SLOT_CHARGE(SIM_CHARGE_REPEL)] = 2;
            none.classes[i].kit[SIM_SLOT_CHARGE(SIM_CHARGE_BURST)] = 1;
        }
        static sim_state s;
        sim_init(&s, 1);
        int seat = sim_spawn(&s, LATTICE, 0, 8192, 8192, 0, &none);
        CHECK(seat >= 0, "the support hull seats");
        CHECK(s.ships[seat].charge[SIM_CHARGE_REPEL] == 0,
              "and is racked with none of a charge this zone does not have");
        CHECK(s.ships[seat].charge[SIM_CHARGE_BURST] > 0,
              "while the kind it does have is dealt as usual");
    }

    {
        /* An assist: two pilots on the victim, one of them lands the last
         * round, and the other's column says they were there.
         *
         * Ship 0 opens on the victim and stops. Ship 2 finishes it a moment
         * later, inside the window, so the kill is ship 2's and the assist is
         * ship 0's. What this is really guarding is that the two are separate
         * counters: the pilot who did most of the work and lost the finish
         * used to read as a pilot who had done nothing.
         */
        static sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 32768, &cfg);         /* fires +y */
        sim_spawn(&s, APEX, 1, 8192, 8192 + 200, 0, &cfg);       /* between */
        sim_spawn(&s, APEX, 0, 8192, 8192 + 400, 0, &cfg);       /* fires -y */
        /* One burst, then everything it threw runs out, so the finish below
         * is unambiguously the other pilot's. */
        step_counting(&s, &cfg, SIM_BTN_FIRE, 0, 20);
        step_counting(&s, &cfg, 0, 0, 120);
        CHECK(s.ships[1].alive, "the first pilot softens them and stops");
        CHECK(s.ships[1].hurt_by[0] == 0, "and is on the victim's ledger");
        s.ships[1].energy = 1;
        /* The assist events of the tick the victim died on, which is the only
         * tick that has any: a caller that wants to tell a pilot they helped
         * has to be able to read it off the death rather than by watching a
         * column for movement. */
        int said = 0, said_right = 0, said_of_killer = 0;
        for (int t = 0; t < 400 && s.ships[1].alive; t++) {
            sim_state tmp;
            sim_events ev;
            sim_input in[1] = {{2, SIM_BTN_FIRE}};
            sim_step(&tmp, &s, in, 1, &cfg, &ev);
            s = tmp;
            for (uint16_t e = 0; e < ev.count; e++) {
                if (ev.e[e].type != SIM_EV_ASSIST) continue;
                said++;
                if (ev.e[e].a == 0 && ev.e[e].b == 1) said_right++;
                if (ev.e[e].v == 2) said_of_killer++;
            }
        }
        CHECK(!s.ships[1].alive, "the second one finishes it");
        CHECK(s.ships[2].kills == 1, "whose kill it is");
        CHECK(s.ships[2].assists == 0, "and it is not also their assist");
        CHECK(s.ships[0].kills == 0, "the other took nothing");
        CHECK(s.ships[0].assists == 1, "and is credited with the help");
        CHECK(said == 1, "the death says so once, for the one who helped");
        CHECK(said_right == 1, "naming the pilot credited and the victim");
        CHECK(said_of_killer == 1, "and who finished it");
    }

    {
        /* Killing a carrier drops what they held rather than paying for it.
         *
         * A flag used to add to the kill, through `points_per_flag`, and that
         * went with points: there is nothing left for a carry to be worth. A
         * mode with an objective pays in its own score when one is written. */
        static sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 32768, &cfg);
        sim_spawn(&s, APEX, 1, 8192, 8192 + 200, 0, &cfg);
        sim_add_flag(&s, 100, 100);
        sim_add_flag(&s, 200, 200);
        for (int f = 0; f < 2; f++) {
            s.flags[f].carried = 1;
            s.flags[f].carrier = 1;
        }
        s.ships[1].energy = 1;
        step_counting(&s, &cfg, SIM_BTN_FIRE, 0, 400);
        CHECK(s.ships[1].deaths > 0, "the carrier dies");
        CHECK(s.ships[0].kills == 1, "for one kill like any other");
        for (int f = 0; f < 2; f++)
            CHECK(!s.flags[f].carried, "and both flags are on the ground");
    }

    /* A stand a zone will not let anybody carry changes hands where it
     * stands, which is the whole of a turf claim: fly over it and it is
     * yours, and the next pilot of another side to cross it takes it back. */
    {
        sim_settings turf = cfg;
        turf.flag_carry = 0;
        turf.flag_drop_cooldown = 100;

        static sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &turf);
        sim_spawn(&s, APEX, 1, 8192, 8192, 0, &turf);
        int f = sim_add_flag(&s, 8192, 8192);
        int32_t was_x = s.flags[f].x, was_y = s.flags[f].y;

        step_n(&s, &turf, 0, 0, 1);
        CHECK(s.flags[f].team == 0, "the first hull over it claims it");
        CHECK(!s.flags[f].carried, "without picking it up");
        CHECK(s.flags[f].held == 0, "so no carry clock is running");
        CHECK(s.flags[f].x == was_x && s.flags[f].y == was_y,
              "and the stand has not moved");

        /* A rival is sitting on the same stand. Without the settling window
         * the two of them would take it from each other every tick. */
        step_n(&s, &turf, 0, 0, 98);
        CHECK(s.flags[f].team == 0, "and it holds while the window runs");

        step_n(&s, &turf, 0, 0, 4);
        CHECK(s.flags[f].team == 1, "then the rival on it takes it");
        CHECK(s.flags[f].x == was_x && s.flags[f].y == was_y, "still put");
    }

    /* Greens: prizes that appear near the people who might take them.
     *
     * The ring is the whole design and is why this checks where they land
     * rather than only that they exist. Scattered by area they were a zone
     * that read to its players as having none; see docs/design/maps.md. */
    {
        sim_settings g = cfg;
        g.green_target = 6;
        g.green_every = 10;
        g.green_life = 2000;
        g.green_near = 6 * SIM_TILE_PX * 256;
        g.green_far = 28 * SIM_TILE_PX * 256;
        g.green_radius = 18 * 256;
        /* Everything a green can be, in this room, is one more energy step. */
        memset(g.green_weight, 0, sizeof g.green_weight);
        g.green_weight[SIM_SLOT_STAT(SIM_UP_ENERGY)] = 1;

        static sim_state s;
        sim_init(&s, 7);
        /* The field is the authority's and does not sow without a stream of
         * its own; see `prize_rng`. A test is the authority here. */
        sim_prize_seed(&s, 0xc0ffeeu);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &g);
        int live = 0;
        for (int t = 0; t < 400 && live < 6; t++) {
            step_n(&s, &g, 0, 0, 1);
            live = 0;
            for (int i = 0; i < s.green_count; i++)
                if (s.greens[i].active) live++;
        }
        CHECK(live == 6, "the room fills to what the zone asked for");

        for (int i = 0; i < s.green_count; i++) {
            const sim_green *p = &s.greens[i];
            if (!p->active) continue;
            CHECK(p->slot == SIM_SLOT_STAT(SIM_UP_ENERGY),
                  "and every one of them is what the table allows");
            int64_t dx = (int64_t)p->x - 8192 * 256;
            int64_t dy = (int64_t)p->y - 8192 * 256;
            int64_t d2 = dx * dx + dy * dy;
            CHECK(d2 >= (int64_t)g.green_near * g.green_near,
                  "no closer than the ring's inside, so it is a trip");
            CHECK(d2 <= (int64_t)g.green_far * g.green_far,
                  "and no further than its outside, so it is on the radar");
            int32_t tx = p->x / (SIM_TILE_PX * 256);
            int32_t ty = p->y / (SIM_TILE_PX * 256);
            CHECK(SIM_TILE_CLASS(sim_tile_at(cfg.map, tx, ty)) != SIM_TILE_SOLID,
                  "and none of them is inside a wall");
        }

        /* Taking one raises what the pilot is flying. */
        int held_before = s.ships[0].up[SIM_UP_ENERGY];
        int idx = -1;
        for (int i = 0; i < s.green_count; i++)
            if (s.greens[i].active) { idx = i; break; }
        CHECK(idx >= 0, "there is one to take");
        /* Walk the hull onto it rather than the green onto the hull, so the
         * pickup test is the one the game runs. */
        s.ships[0].x = s.greens[idx].x;
        s.ships[0].y = s.greens[idx].y;
        step_n(&s, &g, 0, 0, 1);
        CHECK(!s.greens[idx].active, "the green is taken");
        CHECK(s.ships[0].up[SIM_UP_ENERGY] == held_before + 1,
              "and the pilot is flying one step more energy");

        /* And death puts them back on their own build, because a respawn
         * deals `kit` again and a green never touched it. That is the whole
         * of the death policy: a green lasts a life. */
        s.ships[0].alive = 0;
        s.ships[0].respawn_at = 2;
        step_n(&s, &g, 0, 0, 4);
        CHECK(s.ships[0].alive, "the pilot comes back");
        CHECK(s.ships[0].up[SIM_UP_ENERGY] == held_before,
              "on the build they own, without what the green lent them");
    }

    /* A green goes out on its own, so a room nobody visits does not silently
     * carpet itself with everything anybody ever failed to collect. */
    {
        sim_settings g = cfg;
        g.green_target = 1;
        /* Long between two, so what this watches expire is not replaced in
         * the same slot before it can be looked at. */
        g.green_every = 500;
        g.green_life = 50;
        g.green_near = 6 * SIM_TILE_PX * 256;
        g.green_far = 28 * SIM_TILE_PX * 256;
        g.green_radius = 18 * 256;
        memset(g.green_weight, 0, sizeof g.green_weight);
        g.green_weight[SIM_SLOT_STAT(SIM_UP_ENERGY)] = 1;

        static sim_state s;
        sim_init(&s, 3);
        sim_prize_seed(&s, 0xbeef01u);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &g);
        step_n(&s, &g, 0, 0, 5);
        int idx = -1;
        for (int i = 0; i < s.green_count; i++)
            if (s.greens[i].active) { idx = i; break; }
        CHECK(idx >= 0, "one is out");
        step_n(&s, &g, 0, 0, 60);
        CHECK(!s.greens[idx].active, "and it has gone out on its own");
    }

    /* The field belongs to the zone, and a prediction client only takes from
     * it. Same rule as a death and a proximity fuse, for the same reason: a
     * green a client puts out or expires on its own is one the next snapshot
     * takes back.
     *
     * The flicker this stops was worth watching. Interest filtering writes an
     * out-of-radius green inert, so a client counts a handful live against a
     * room-wide target and always believes the field is short; `green_at` is
     * state rather than wire, so every snapshot left it at zero and the very
     * next tick put a green out. At snapshot rate that is a prize blinking in
     * and out of existence somewhere near you, twenty times a second, none of
     * them real. */
    {
        sim_settings g = cfg;
        g.green_target = 6;
        g.green_every = 10;
        g.green_life = 50;
        g.green_near = 6 * SIM_TILE_PX * 256;
        g.green_far = 28 * SIM_TILE_PX * 256;
        g.green_radius = 18 * 256;
        memset(g.green_weight, 0, sizeof g.green_weight);
        g.green_weight[SIM_SLOT_STAT(SIM_UP_ENERGY)] = 1;

        /* The zone first, to get a real green in a real place. */
        static sim_state s;
        sim_init(&s, 11);
        sim_prize_seed(&s, 0xd0d0d0u);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &g);
        sim_spawn(&s, APEX, 1, 8192 + 4096, 8192, 0, &g);
        step_n(&s, &g, 0, 0, 20);
        int idx = -1;
        for (int i = 0; i < s.green_count; i++)
            if (s.greens[i].active) { idx = i; break; }
        CHECK(idx >= 0, "the zone has put one out");

        /* Now the same world as a client holds it after a snapshot: seat zero
         * is this pilot, and `green_at` is zero because no snapshot carries
         * it. */
        sim_settings c = g;
        c.deathless = 1;
        c.mortal_ship = 0;

        static sim_state cs;
        cs = s;
        cs.green_at = 0;
        uint8_t was = cs.green_count;
        step_n(&cs, &c, 0, 0, 1);
        CHECK(cs.green_count == was, "a client puts none out on the tick after a snapshot");
        step_n(&cs, &c, 0, 0, 300);
        CHECK(cs.green_count == was, "nor over three hundred ticks of being short");
        CHECK(cs.greens[idx].active,
              "and the one the zone put out has not expired under it");

        /* A stranger flying over one takes nothing here: that pickup is the
         * zone's to report, and it arrives as the green leaving a snapshot. */
        cs.ships[1].x = cs.greens[idx].x;
        cs.ships[1].y = cs.greens[idx].y;
        step_n(&cs, &c, 0, 0, 1);
        CHECK(cs.greens[idx].active, "a remote hull on a green does not take it");

        /* This pilot's own is predicted, so the prize and its sound land on
         * the frame they were earned rather than a round trip later. */
        cs.ships[0].x = cs.greens[idx].x;
        cs.ships[0].y = cs.greens[idx].y;
        step_n(&cs, &c, 0, 0, 1);
        CHECK(!cs.greens[idx].active, "this client's own pilot takes it");
    }

    /* A zone that asks for none gets none, which is every match game we
     * ship: there a pilot flies the build they chose and nothing else. The
     * stream is installed here so what is being tested is `green_target` and
     * not the absence of one. */
    {
        static sim_state s;
        sim_init(&s, 5);
        sim_prize_seed(&s, 0x515151u);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &cfg);
        step_n(&s, &cfg, 0, 0, 500);
        CHECK(s.green_count == 0, "the baseline puts out no greens");
    }

    /* And a room with no stream of its own sows nothing whatever the zone
     * asked for. Loud rather than quiet: a field nobody seeded is empty, and
     * an empty Free Roam is noticed in a minute, where greens landing where a
     * client could have worked out in advance would not be noticed at all. */
    {
        sim_settings g = cfg;
        g.green_target = 6;
        g.green_every = 10;
        g.green_life = 2000;
        g.green_near = 6 * SIM_TILE_PX * 256;
        g.green_far = 28 * SIM_TILE_PX * 256;
        g.green_radius = 18 * 256;
        memset(g.green_weight, 0, sizeof g.green_weight);
        g.green_weight[SIM_SLOT_STAT(SIM_UP_ENERGY)] = 1;

        static sim_state s;
        sim_init(&s, 7);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &g);
        step_n(&s, &g, 0, 0, 500);
        CHECK(s.green_count == 0, "an unseeded field puts out nothing");

        /* Seeded, the same room fills. */
        sim_prize_seed(&s, 0x9e3779b9u);
        step_n(&s, &g, 0, 0, 500);
        CHECK(s.green_count > 0, "and fills once the zone installs one");
    }

    /* A carry clock puts a flag down on its own, keeping the side that took
     * it. Without one, a hull that can stay alive takes a flag out of the
     * game for as long as it keeps flying. */
    {
        sim_settings timed = cfg;
        timed.flag_carry = 1;
        timed.flag_carry_ticks = 300;
        timed.flag_drop_cooldown = 50;

        static sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 8192, 0, &timed);
        int f = sim_add_flag(&s, 8192, 8192);

        step_n(&s, &timed, 0, 0, 2);
        CHECK(s.flags[f].carried && s.flags[f].carrier == 0,
              "a carrying zone still picks it up");
        CHECK(s.flags[f].team == 0, "for the side that took it");

        step_n(&s, &timed, SIM_BTN_THRUST, 0, 250);
        CHECK(s.flags[f].carried, "and it is still held before the clock is up");
        CHECK(s.flags[f].held > 0, "with a clock running on it");

        /* One tick at a time from here, so the checks land on the tick the
         * flag comes down rather than a hundred ticks after it. */
        int dropped_on = -1;
        for (int t = 0; t < 100 && dropped_on < 0; t++) {
            step_n(&s, &timed, SIM_BTN_THRUST, 0, 1);
            if (!s.flags[f].carried) dropped_on = t;
        }
        CHECK(dropped_on >= 0, "the clock puts it down");
        CHECK(s.flags[f].team == 0, "still owned by the side that had it");
        CHECK(s.flags[f].held == 0, "with the clock wound back");
        CHECK(s.flags[f].cooldown > 0, "and untouchable for a moment");
    }
}

static void test_physics_and_wire(sim_map *m, const sim_settings *base) {
    sim_settings cfg = *base;

    /* A bounce returns the speed the restitution setting says, and a ship
     * resting against a wall settles rather than buzzing. The baseline is
     * Misc:BounceFactor 16, so it comes back with all of it. */
    {
        static sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, APEX, 0, 8192, 2000, 0, &cfg);  /* faces the top wall */
        step_n(&s, &cfg, SIM_BTN_THRUST, 0, 100);     /* build speed, coast in */

        static sim_state before, tmp;
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
            /* Both ways round, so this reads the setting rather than
             * assuming a wall costs anything: at 16 it must not, and below
             * 16 it must. The slack is one fixed-point pixel of rounding. */
            CHECK(now * 16 <= was * cfg.bounce + 16
                      && now * 16 >= was * cfg.bounce - 16,
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
        static sim_state s;
        sim_init(&s, 5);
        /* Well clear of every wall but the one it is aimed at, and told to
         * hold still, so the only thing that can reach a wall is the bullet. */
        sim_spawn(&s, APEX, 0, 8192, 400, 0, &cfg);
        s.ships[0].mods[SIM_TRIG_GUN] =
            sim_mod_set(s.ships[0].mods[SIM_TRIG_GUN], SIM_MOD_BOUNCE, 1);

        static sim_state tmp;
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

        /* Every number of it, and not only the ones this scenario happens to
         * touch. A field added to the struct and forgotten on the wire is
         * silent, and one of them was: see the double barrel below. Comparing
         * the whole thing is the only version of this check that cannot be
         * written to pass. The three fields held back are the three the
         * message deliberately does not carry. */
        sim_settings bare = zone, back = got;
        bare.map = back.map = NULL;
        bare.deathless = back.deathless = 0;
        bare.mortal_ship = back.mortal_ship = 0;
        CHECK(memcmp(&bare, &back, sizeof bare) == 0,
              "and every number the zone tuned arrives");

        static sim_state s1, s2;
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
        static sim_state s3;
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
        static sim_state s1, s2;
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
        static sim_state s, saved, tmp;
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
        static sim_state s;
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


    /* Multifire is a switch the pilot holds.
     *
     * A fan is worse than a single shot down a corridor, and the add-on
     * is part of the chosen kit, so a pilot who has one needs a way to stop
     * using it. The button toggles on the press rather than
     * while held: this is a state, and a state you have to keep a finger on is
     * a state you cannot fly with. */
    {
        static sim_state s;
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
            static sim_state s2;
            step_n(&s, &cfg, SIM_BTN_MULTI, 0, 1);   /* down: toggles once */
            CHECK(s.ships[id].multi_off, "the key goes down and it toggles");
            int m = sim_pack_around(&s, buf, sizeof buf, 0, 0, -1, 255,
                                    SIM_PACK_PRIVATE_ALL);
            CHECK(m > 0, "the state packs");
            CHECK(sim_unpack(&s2, buf, m) == 0, "and reads back");
            CHECK(s2.ships[id].btn_prev == SIM_BTN_MULTI,
                  "with the press still recorded");
            step_n(&s2, &cfg, SIM_BTN_MULTI, 0, 1);  /* still held */
            CHECK(s2.ships[id].multi_off,
                  "so holding it through a snapshot does not toggle again");
        }

        /* A fan that leaves takes the switch with it, so the next one fans.
         * A decline on a hull with nothing to decline is invisible state that
         * would surprise the pilot after a later kit change. */
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
        sim_settings w = cfg;
        bare_kits(&w);
        static sim_state s;
        sim_init(&s, 1);
        int id = sim_spawn(&s, APEX, 0, 8192, 8192, 0, &w);
        CHECK(sim_mod_get(s.ships[id].mods[SIM_TRIG_GUN], SIM_MOD_MULTI) == 0,
              "a hull with no fan in its profile carries none");

        step_n(&s, &w, SIM_BTN_MULTI, 0, 1);
        CHECK(!s.ships[id].multi_off, "and the button leaves the switch alone");
        step_n(&s, &w, 0, 0, 1);
        step_n(&s, &w, SIM_BTN_MULTI, 0, 1);
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


    /* A round faster than a hull is thick still hits it.
     *
     * The hit test used to sample once per tick, at the end of the tick's
     * travel. A Cipher's flank is 16 px thick and a round can cross more than
     * that in one tick, so a crossing could land entirely between two samples
     * and pass through, deterministically, on both ends of the wire at once.
     * The sweep walks the travel in 4 px samples instead. The velocity here
     * is written onto the round directly, standing in for any zone that
     * retunes its weapons faster than the baseline flies. */
    {
        const int CIPHER = 4;
        static sim_state s;
        sim_init(&s, 1);
        sim_spawn(&s, CIPHER, 0, 8192, 8192, 0, &cfg);

        sim_weapon *w = &s.weapons[s.weapon_count++];
        memset(w, 0, sizeof *w);
        w->spec = gun_of(&cfg, APEX)->spec;
        w->owner = 1;          /* nobody's round arrives at its owner */
        w->team = 1;
        w->life = 10;
        /* 20 px a tick, eastward, from 2 px short of the near flank: the
         * endpoint lands 2 px past the far one, so the old single sample
         * would have seen empty space on both sides of the crossing. */
        w->x = 8182 * 256;
        w->y = 8192 * 256;
        w->vx = 20 * 65536;

        ev_counts c = step_counting(&s, &cfg, 0, 0, 1);
        CHECK(c.hits == 1, "a 20 px/tick round cannot cross a 16 px flank");
        CHECK(s.weapon_count == 0, "and it ended on the hull it hit");
    }

    /* And the same round cannot cross a wall one tile thick. */
    {
        for (int ty = 500; ty < 525; ty++)
            m->tile[(size_t)ty * SIM_MAP_TILES + 512] = SIM_TILE_SOLID;
        sim_map_index(m);

        static sim_state s;
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




    /* Touching a wormhole puts you somewhere else.
     *
     * The pull was already there and did nothing but bend a course. What a
     * wormhole is for is the other side of it, so contact with the tile itself
     * moves the ship to a spawn point chosen at random and stops it dead: an
     * exit that keeps your velocity puts you through the wall behind wherever
     * you came out. */
    {
        sim_map *wm = malloc(sizeof *wm);
        sim_map_size(wm, SIM_MAP_TILES, SIM_MAP_TILES);
        for (int i = 0; i < SIM_MAP_TILES; i++) {
            SIM_MAP_AT(wm, i, 0) = SIM_TILE_SOLID;
            SIM_MAP_AT(wm, i, SIM_MAP_TILES - 1) = SIM_TILE_SOLID;
            SIM_MAP_AT(wm, 0, i) = SIM_TILE_SOLID;
            SIM_MAP_AT(wm, SIM_MAP_TILES - 1, i) = SIM_TILE_SOLID;
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

        static sim_state s;
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

    /* A hull's box follows its heading. The core fixes the target budget and
     * client/tests/hull_fit_test.lua checks that each drawing fits it; here we
     * check the properties the core depends on. Every hull has all three,
     * none reaches past 23 px in any
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
        const int32_t face = 40 * 16 * 256;   /* the wall's south edge */

        /* Nose-first: thrust straight up at the wall and take the closest
         * approach, since holding thrust against a wall bounces. */
        {
            static sim_state s;
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
            static sim_state s;
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
            static sim_state s;
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

}

static void test_spawning_and_snapshots(sim_map *m, const sim_settings *base) {
    sim_settings cfg = *base;

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
            SIM_MAP_AT(sm, SPAWN_TX[i], 200) = SIM_TILE(SIM_TILE_SPAWN, 0);
        sim_map_index(sm);

        sim_settings sc;
        memset(&sc, 0, sizeof sc);
        sim_settings_baseline(&sc, sm);
        sc.respawn_delay = 1;

        CHECK(sc.spawn_radius == 0, "the baseline spawns on the map's tiles");
        CHECK(sc.show_spawns == 1, "and a client marks them");

        /* Tiles: `nth` walks them and the position is the tile's middle, not
         * its corner. The corner is where two of the three callers used to
         * put a ship, which left a hull sitting eight pixels out of the gap
         * its tile had been checked for. */
        {
            static sim_state s;
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
            static sim_state s;
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
            static sim_state s;
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
            static sim_state s;
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
            static sim_state a, b;
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
            static sim_state s;
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
     * The seed is fixed so a failure can be replayed, but inputs, hull
     * changes, side changes, kits, weapons, deaths, respawns and flags still
     * meet in combinations the examples above do not enumerate. */
    {
        sim_settings mixed = cfg;
        mixed.respawn_delay = 25;
        mixed.flag_drop_cooldown = 5;
        static sim_state s;
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
                                 | SIM_BTN_USE | SIM_BTN_SLOT_MASK
                                 | SIM_BTN_MULTI;
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
                                                 % mixed.class_count),
                                       NULL);
                else if (action == 1)
                    sim_set_ship_team(&s, &mixed, i,
                                      (uint8_t)(next_random(&random) % 3));
                else
                    random_kit(&s.ships[i], &mixed, &random);
            }

            sim_state next;
            sim_step(&next, &s, in, 12, &mixed, NULL);
            s = next;
            check_state_invariants(&s, &mixed);

            if (tick % 127 == 0) {
                static uint8_t packed[SIM_STATE_PACK_MAX];
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

    /* A snapshot round trip reproduces the state exactly. This is what lets
     * a client accept the server's word without drifting from it. */
    {
        static sim_state s, back;
        sim_init(&s, 11);
        sim_spawn(&s, APEX, 0, 8000, 8000, 900, &cfg);
        sim_spawn(&s, ANVIL, 1, 8000, 7800, 32768, &cfg);
        sim_spawn(&s, APEX, 1, 8000 + 400 * SIM_TILE_PX, 8000, 0, &cfg);
        /* Long enough for both triggers to leave rounds in the state. */
        step_counting(&s, &cfg, SIM_BTN_THRUST | SIM_BTN_FIRE, SIM_BTN_BOMB,
                      600);

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

        static uint8_t buf[SIM_STATE_PACK_MAX];
        int n = sim_pack(&s, buf, sizeof buf);
        CHECK(n > 0, "a snapshot packs");
        CHECK(sim_unpack(&back, buf, n) == 0, "a snapshot unpacks");
        CHECK(sim_hash(&back) == sim_hash(&s), "the round trip is exact");
        CHECK(back.weapons[0].link == 0xa1b2c3d4u,
              "a gun-volley link survives the snapshot");
        /* The names too, and the counter they come from: a client's own
         * spawns carry on from the zone's numbering, so its predicted
         * rounds never wear a name a round in the snapshot already holds. */
        CHECK(s.weapons[0].id != 0 && back.weapons[0].id == s.weapons[0].id,
              "a round's name survives the snapshot");
        CHECK(s.weapon_serial != 0 && back.weapon_serial == s.weapon_serial,
              "and so does the counter it was dealt from");
        {
            int distinct = 1;
            for (int i = 0; i < s.weapon_count && distinct; i++)
                for (int j = i + 1; j < s.weapon_count; j++)
                    if (s.weapons[i].id == s.weapons[j].id) distinct = 0;
            CHECK(s.weapon_count > 1 && distinct,
                  "no two rounds in the air share a name");
        }

        /* The prize stream and its clock stay behind. This is the check that
         * keeps them off the wire: a green is rolled from `prize_rng`, so a
         * snapshot carrying it would tell every client in the room where the
         * next one is going to land. `sim_hash` is the other half, because
         * the round trip above is asserted by comparing hashes, and a field
         * that is hashed but not packed would break that instead of this. */
        {
            static sim_state seeded, seeded_back;
            seeded = s;
            sim_prize_seed(&seeded, 0x1234abcdu);
            seeded.green_at = 77;
            CHECK(sim_hash(&seeded) == sim_hash(&s),
                  "the private stream is not in the hash");
            int m = sim_pack(&seeded, buf, sizeof buf);
            CHECK(m == n, "nor does it cost the snapshot a byte");
            CHECK(sim_unpack(&seeded_back, buf, m) == 0, "and it unpacks");
            CHECK(seeded_back.prize_rng == 0 && seeded_back.green_at == 0,
                  "and neither reaches the far end");
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
            static uint8_t longer[SIM_STATE_PACK_MAX + 8];
            memcpy(longer, buf, (size_t)n);
            longer[n] = 0x5a;
            static sim_state ignored;
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

        /* And an unpacked state steps identically to the original, which is
         * the property client prediction actually depends on. */
        static sim_state a2, b2;
        sim_input in = {0, SIM_BTN_THRUST};
        sim_step(&a2, &s, &in, 1, &cfg, NULL);
        sim_step(&b2, &back, &in, 1, &cfg, NULL);
        CHECK(sim_hash(&a2) == sim_hash(&b2), "an unpacked state steps identically");

        /* And a snapshot packed around a point carries what is near it and
         * none of the far ones, which is the claim the wire saving rests
         * on, and the half of it that is about cheating rather than bytes. */
        {
            int32_t cx = s.ships[0].x, cy = s.ships[0].y;
            /* Two hundred tiles rather than the radar's sixty: the third
             * pilot is four hundred tiles out, so this catches the pair
             * and not them. The radius under test is the filter, not the
             * number the server picks. */
            const int32_t R = 200 * 16 * 256;

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

            int m = sim_pack_around(&s, buf, sizeof buf, cx, cy, R, 0, 0);
            CHECK(m > 0 && m < n, "a filtered snapshot is smaller");
            static sim_state cut;
            CHECK(sim_unpack(&cut, buf, m) == 0, "and unpacks");


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

        /* A respawn lands on the same tile for the arena and for the client
         * predicting it.
         *
         * The client is sent the ships inside its interest radius and no
         * others, so every draw the arena makes for a hull it cannot see is a
         * draw it does not make. Taken off the shared generator, a spawn tile
         * is therefore whatever that client's copy of the stream happened to
         * reach: a different tile, on a different side of the map. Reported
         * from alphasmall as a 9416 px correction with both positions exact
         * tile centers and no velocity either side, which is a respawn and
         * nothing else.
         *
         * Two hulls far enough apart to filter, both about to come back. */
        {
            sim_settings rc = cfg;
            rc.spawn_radius = 40;      /* a scatter, so the draw decides a tile */
            rc.respawn_delay = 2;

            static sim_state s;
            sim_init(&s, 12345);
            /* The unseen hull takes the lower seat, because the step walks
             * seats in order: the arena's draw for it lands before the
             * pilot's, and the client's does not happen at all. A room where
             * every hull the client cannot see sits behind it in the roster
             * would hide this. */
            int far = sim_spawn(&s, APEX, 1, 900 * 16, 900 * 16, 0, &rc);
            int near = sim_spawn(&s, APEX, 0, 300 * 16, 300 * 16, 0, &rc);
            CHECK(far == 0 && near == 1, "two hulls, far apart");
            /* Both dead and due back on the same tick. */
            for (int k = 0; k < 2; k++) {
                s.ships[k].alive = 0;
                s.ships[k].energy = 0;
                s.ships[k].respawn_at = 2;
            }

            /* What this pilot is actually sent, which leaves the far hull out. */
            const int32_t R = 84 * 16 * 256;
            int n = sim_pack_around(&s, buf, sizeof buf, s.ships[near].x,
                                    s.ships[near].y, R, (uint8_t)near, 0);
            static sim_state client;
            CHECK(n > 0 && sim_unpack(&client, buf, n) == 0, "the snapshot reads");
            CHECK(!client.ships[far].active,
                  "and the far hull is not in it, which is the whole point");
            CHECK(client.rng == s.rng, "the generator arrives with it");

            /* Both step the same two ticks: the arena with the room it has,
             * the client with the room it was told about. */
            step_n(&s, &rc, 0, 0, 2);
            step_n(&client, &rc, 0, 0, 2);
            CHECK(s.ships[near].alive && client.ships[near].alive,
                  "the pilot is back on both sides");
            CHECK(s.ships[near].x == client.ships[near].x
                  && s.ships[near].y == client.ships[near].y,
                  "and back on the same tile, whatever else the room did");
        }

        /* A green is filtered like a ship and unlike a flag, per decision
         * 133: one is put out near a live pilot, so an unfiltered field is a
         * beacon on everybody in the room, lawful sight or not. Out of
         * radius it arrives as eleven bytes of nothing, so the count and the
         * indices hold and the format does not move. */
        {
            static sim_state m;
            sim_init(&m, 5);
            sim_spawn(&m, APEX, 0, 300 * 16, 300 * 16, 0, &cfg);
            m.green_count = 2;
            m.greens[0].active = 1;
            m.greens[0].slot = 3;
            m.greens[0].x = 310 * 16 * 256; /* ten tiles off: in sight */
            m.greens[0].y = 300 * 16 * 256;
            m.greens[0].life = 500;
            m.greens[1] = m.greens[0];
            m.greens[1].x = 900 * 16 * 256; /* the far side of the map */
            m.greens[1].y = 900 * 16 * 256;

            const int32_t R = 84 * 16 * 256;
            int n = sim_pack_around(&m, buf, sizeof buf, m.ships[0].x,
                                    m.ships[0].y, R, 0, 0);
            static sim_state client;
            CHECK(n > 0 && sim_unpack(&client, buf, n) == 0,
                  "the filtered snapshot reads");
            CHECK(client.green_count == 2, "the count is the room's");
            CHECK(client.greens[0].active && client.greens[0].slot == 3,
                  "the green in reach arrives whole");
            CHECK(!client.greens[1].active && client.greens[1].x == 0,
                  "and the far one arrives as nothing at all");

            /* The whole-state path is the replay's and stays unfiltered. */
            int whole = sim_pack(&m, buf, sizeof buf);
            CHECK(whole > 0 && sim_unpack(&client, buf, whole) == 0,
                  "the whole state reads");
            CHECK(client.greens[1].active, "with every green in it");
        }

        /* Distance is the only rule a round meets, with no exception for
         * whose it is. Every round in the game is spent within seconds and
         * near the hull that fired it, so a pilot's own are inside the radius
         * by construction; a weapon that outlived the trip home would need an
         * exception here, and there is none in the game. */
        {
            static sim_state m;
            sim_init(&m, 3);
            int shooter = sim_spawn(&m, APEX, 0, 2048, 2048, 0, &cfg);
            int other = sim_spawn(&m, APEX, 1, 2200, 2048, 0, &cfg);
            CHECK(shooter == 0 && other == 1, "two pilots, two sides");
            step_n(&m, &cfg, SIM_BTN_FIRE, 0, 1);
            CHECK(m.weapon_count > 0, "one of them shoots");
            /* Somewhere the radius below cannot reach. Moved rather than
             * flown, because what is under test is the filter and not how
             * long the trip takes. */
            m.ships[0].x += 400 * 16 * 256;

            const int32_t R = 84 * 16 * 256;    /* the floor a client gets */
            int32_t vx = m.ships[0].x, vy = m.ships[0].y;
            int n2 = sim_pack_around(&m, buf, sizeof buf, vx, vy, R, 0, 0);
            static sim_state left_behind;
            CHECK(n2 > 0 && sim_unpack(&left_behind, buf, n2) == 0,
                  "the shooter's own snapshot packs");
            CHECK(left_behind.weapon_count == 0,
                  "and carries nothing of the round they flew away from");

            /* From next to it, everybody is told about it, on the distance
             * and nothing else. */
            int n4 = sim_pack_around(&m, buf, sizeof buf,
                                     m.weapons[0].x, m.weapons[0].y, R, 1, 0);
            static sim_state near_by;
            CHECK(n4 > 0 && sim_unpack(&near_by, buf, n4) == 0, "packs");
            CHECK(near_by.weapon_count > 0,
                  "a stranger standing on the round sees it");
        }

        /* A negative radius is the whole state, and has to stay bit-identical
         * to it: the replay tool, the golden hashes and every test above pack
         * that way, so a filtered format that changed the unfiltered bytes
         * would be a format change wearing a disguise. */
        {
            int whole = sim_pack_around(&s, buf, sizeof buf, 0, 0, -1, 255,
                                        SIM_PACK_PRIVATE_ALL);
            CHECK(whole == n, "an unfiltered pack is the same size as sim_pack");
            static sim_state all;
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
                                    s.ships[pick].x, s.ships[pick].y, 0,
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

    /* The network and whole-state packers have different maxima. A network
     * snapshot carries one private ship tail; a whole-state snapshot carries
     * all of them for replay and trusted in-process users. */
    {
        static sim_state full;
        memset(&full, 0, sizeof full);
        full.ship_count = SIM_MAX_SHIPS;
        for (int i = 0; i < SIM_MAX_SHIPS; i++) {
            full.ships[i].active = 1;
            /* The dearest build to send is not the dearest build to fly: a
             * spent slot costs a byte whatever it holds, so seven credits in
             * seven different slots is the widest a pilot can make this,
             * and seven in one slot is the narrowest. */
            for (int k = 0; k < SIM_KIT_CREDITS; k++) full.ships[i].kit[k] = 1;
        }
        full.weapon_count = SIM_MAX_WEAPONS;
        full.flag_count = SIM_MAX_FLAGS;
        full.green_count = SIM_MAX_GREENS;

        static uint8_t packed[SIM_STATE_PACK_MAX];
        int whole = sim_pack(&full, packed, sizeof packed);
        CHECK(whole == SIM_STATE_PACK_MAX,
              "a full whole-state snapshot exactly fills its ceiling");
        CHECK(sim_pack(&full, packed, SIM_STATE_PACK_MAX - 1) == -1,
              "and the whole-state ceiling is not understated");

        int network = sim_pack_around(&full, packed, SIM_PACK_MAX,
                                      0, 0, -1, 0, 0);
        CHECK(network > 0 && network <= SIM_PACK_MAX,
              "the largest network shape fits its separate ceiling");
    }

}

static void test_kits_and_matches(const sim_settings *base) {
    sim_settings cfg = *base;

    /* --- the arrival build -----------------------------------------------
     *
     * A ship is dealt a build at the seat and dealt it again at every
     * respawn, minus the ammunition, which is the whole of what a death takes
     * besides the run. Nobody has said anything here, so what lands is the
     * row the baseline ships, which is why this one settings copy is the
     * shipped one rather than the suite's stripped cfg. */
    {
        static sim_settings kc;
        memset(&kc, 0, sizeof kc);
        sim_settings_baseline(&kc, cfg.map);
        static sim_state s;
        sim_init(&s, 3);
        const int FACET = 5;
        int id = sim_spawn(&s, FACET, 0, 8192, 8192, 0, &kc);
        sim_ship *sh = &s.ships[id];
        const uint8_t *kit = kc.classes[FACET].kit;

        for (int k = 0; k < SIM_SLOT_COUNT; k++)
            CHECK(held_of(sh, (uint8_t)k) == kit[k],
                  "every slot holds exactly what the build names");
        CHECK(sh->level[SIM_TRIG_GUN] == 1 && sh->charge[SIM_CHARGE_REPEL] == 1,
              "which is the second rung and a repel to get out with");

        /* A slot that would overflow the bits it is packed into is clamped
         * rather than wrapping, whatever a zone writes into a profile. Held
         * inside the budget on its own, so what is being read here is the
         * ceiling rather than the purse. */
        sim_settings fat = kc;
        memset(fat.classes[FACET].kit, 0, SIM_SLOT_COUNT);
        fat.classes[FACET].kit[SIM_SLOT_MOD(SIM_TRIG_GUN, SIM_MOD_MULTI)] = 60;
        static sim_state f;
        sim_init(&f, 3);
        int fid = sim_spawn(&f, FACET, 0, 8192, 8192, 0, &fat);
        CHECK(sim_mod_get(f.ships[fid].mods[SIM_TRIG_GUN], SIM_MOD_MULTI)
                  == SIM_MOD_MULTI_MAX,
              "an overlong spray clamps to what the word holds");

        /* And a profile nobody could afford is cut to something they can,
         * which is the second gate and the one a budget adds: every slot is
         * inside its own ceiling here and the sum still is not. */
        sim_settings rich = kc;
        memset(rich.classes[FACET].kit, 0, SIM_SLOT_COUNT);
        rich.classes[FACET].kit[SIM_SLOT_STAT(SIM_UP_SPEED)] = SIM_UP_STEPS;
        rich.classes[FACET].kit[SIM_SLOT_CHARGE(SIM_CHARGE_REPEL)] = 4;
        static sim_state g;
        sim_init(&g, 3);
        int gid = sim_spawn(&g, FACET, 0, 8192, 8192, 0, &rich);
        CHECK(sim_kit_cost(g.ships[gid].kit) == SIM_KIT_CREDITS,
              "a profile over budget is fitted to the budget");
        CHECK(g.ships[gid].up[SIM_UP_SPEED] < SIM_UP_STEPS,
              "and the tallest slot is what pays for it");

        /* A rung the hull's ladder does not have is a rung it does not climb
         * to, so a profile reaching past the end of one stops at the top rung
         * that exists rather than naming a pattern that is not there. Held
         * inside the budget again, so it is the ladder doing the cutting. */
        sim_settings tall = kc;
        memset(tall.classes[FACET].kit, 0, SIM_SLOT_COUNT);
        tall.classes[FACET].kit[SIM_SLOT_LEVEL(SIM_TRIG_GUN)]
            = SIM_MAX_RUNGS - 1;
        static sim_state t;
        sim_init(&t, 3);
        int tid = sim_spawn(&t, FACET, 0, 8192, 8192, 0, &tall);
        CHECK(t.ships[tid].level[SIM_TRIG_GUN]
                  == sim_slot_cap(&tall, FACET, SIM_SLOT_LEVEL(SIM_TRIG_GUN)),
              "the hull stops at the top of the ladder it has");

        /* And a trigger with no ladder at all has no rung to buy. Every hull
         * this game ships carries both, so the rack is taken away here: a
         * zone may still write a weapon nobody has, and the credit is refused
         * rather than spent on a bomb that cannot be thrown. */
        const int CIPHER = 4;
        static sim_settings bare;
        bare = kc;
        for (int r = 0; r < SIM_MAX_RUNGS; r++)
            bare.classes[CIPHER].trigger[SIM_TRIG_BOMB][r] = SIM_NO_PATTERN;
        memset(bare.classes[CIPHER].kit, 0, SIM_SLOT_COUNT);
        bare.classes[CIPHER].kit[SIM_SLOT_LEVEL(SIM_TRIG_BOMB)] = 1;
        static sim_state b;
        sim_init(&b, 3);
        int bid = sim_spawn(&b, CIPHER, 0, 8192, 8192, 0, &bare);
        CHECK(b.ships[bid].level[SIM_TRIG_BOMB] == 0,
              "and a hull with no rack stays on the rung it has not got");

        /* Death re-deals the frame and never the ammunition. */
        sh->charge[SIM_CHARGE_REPEL] = 1;
        sh->mods[SIM_TRIG_GUN] = 0;
        sh->streak = 4;
        sh->alive = 0;
        sh->energy = 0;
        sh->respawn_at = 1;
        step_n(&s, &kc, 0, 0, 2);
        CHECK(sh->alive, "the pilot comes back");
        CHECK(sim_mod_get(sh->mods[SIM_TRIG_BOMB], SIM_MOD_PROX) == 1,
              "with the build re-dealt, add-ons and all");
        CHECK(sh->charge[SIM_CHARGE_REPEL] == 1,
              "and exactly the ammunition they had left");
    }

    /* A pilot spends their own credits, and what they spent is what a death
     * hands back. The whole point of a build living on the ship rather than
     * on the class: a respawn happens inside the step, where there is nobody
     * to ask what this pilot chose. */
    {
        static sim_settings kc;
        memset(&kc, 0, sizeof kc);
        sim_settings_baseline(&kc, base->map);
        static sim_state s;
        sim_init(&s, 3);
        const int APEX_ = 0;
        int id = sim_spawn(&s, APEX_, 0, 8192, 8192, 0, &kc);
        sim_ship *sh = &s.ships[id];

        uint8_t mine[SIM_SLOT_COUNT];
        sim_kit_default(&kc, APEX_, mine);
        CHECK(sim_kit_cost(mine) == SIM_KIT_CREDITS,
              "a pilot arrives on every credit they have");

        /* Spent another way: four rounds at a pull and one repel, which is a
         * different ship in the same hull. */
        memset(mine, 0, sizeof mine);
        mine[SIM_SLOT_MOD(SIM_TRIG_GUN, SIM_MOD_MULTI)] = 3;
        mine[SIM_SLOT_CHARGE(SIM_CHARGE_REPEL)] = 1;
        CHECK(sim_set_ship_kit(&s, &kc, (uint8_t)id, mine) == 0,
              "a pilot may spend their credits their own way");
        CHECK(sim_mod_get(sh->mods[SIM_TRIG_GUN], SIM_MOD_MULTI) == 3,
              "and the frame is dealt from what they spent");
        CHECK(sh->charge[SIM_CHARGE_REPEL] == 1,
              "the rack clamped down to the build, never up");
        CHECK(sh->charge[SIM_CHARGE_BURST] == 0,
              "and a kind they stopped paying for is gone");

        /* Editing hands back no energy either, which is what lets it need no
         * gate: a hull change is refused to anybody short of a full bar
         * because a fresh ship is a fresh bar, and this is not one. */
        sh->energy = 100;
        CHECK(sim_set_ship_kit(&s, &kc, (uint8_t)id, mine) == 0,
              "a pilot at a tenth of a bar may still spend");
        CHECK(sh->energy == 100,
              "and is still at a tenth of a bar afterwards");

        /* Editing is not a reload. Spend the rack, ask for it back. */
        sh->charge[SIM_CHARGE_REPEL] = 0;
        CHECK(sim_set_ship_kit(&s, &kc, (uint8_t)id, mine) == 0,
              "the same build again is allowed");
        CHECK(sh->charge[SIM_CHARGE_REPEL] == 0,
              "and hands back no ammunition at all");

        /* A death re-deals the build the pilot chose, not the hull's row. */
        sh->alive = 0;
        sh->energy = 0;
        sh->respawn_at = 1;
        step_n(&s, &kc, 0, 0, 2);
        CHECK(sh->alive, "the pilot comes back");
        CHECK(sim_mod_get(sh->mods[SIM_TRIG_GUN], SIM_MOD_MULTI) == 3,
              "on their own build rather than the hull's");

        /* Nobody can outspend the budget, whatever they send. */
        uint8_t greedy[SIM_SLOT_COUNT];
        memset(greedy, 0, sizeof greedy);
        for (int k = 0; k < SIM_SLOT_COUNT; k++) greedy[k] = 9;
        CHECK(sim_set_ship_kit(&s, &kc, (uint8_t)id, greedy) == 0,
              "an impossible build is taken rather than refused");
        CHECK(sim_kit_cost(sh->kit) == SIM_KIT_CREDITS,
              "and fitted to exactly what a pilot has to spend");
        for (int k = 0; k < SIM_SLOT_COUNT; k++)
            CHECK(sh->kit[k] <= sim_slot_cap(&kc, sh->cls, (uint8_t)k),
                  "with every slot inside its own ceiling");

        /* A build crosses a hull change with the caller, because a build
         * belongs to a hull and only the caller holds both rows. */
        uint8_t bomber[SIM_SLOT_COUNT];
        memset(bomber, 0, sizeof bomber);
        bomber[SIM_SLOT_MOD(SIM_TRIG_BOMB, SIM_MOD_SHRAPNEL)] = 2;
        sh->energy = sim_eff_max_energy(&kc.classes[sh->cls], sh);
        CHECK(sim_set_ship_class(&s, &kc, (uint8_t)id, 1, bomber) == 0,
              "a pilot climbs into a Wedge with a Wedge's build");
        CHECK(sim_mod_get(sh->mods[SIM_TRIG_BOMB], SIM_MOD_SHRAPNEL) == 2,
              "and arrives carrying what they spent on it");
    }

    /* The ceilings are the balance lever, so what they hold has to be
     * written down: a step cannot be made dearer, and a slot left open to
     * the budget alone is a slot every pilot spends everything on.
     *
     * `calibrate builds` found both of these by flying them. Seven of one
     * charge beat every hull's own row on every hull, and an add-on that
     * belongs on a bomb wins outright on a gun. */
    {
        sim_settings kc = *base;
        CHECK(sim_slot_cap(&kc, 0, SIM_SLOT_CHARGE(SIM_CHARGE_REPEL))
                  < SIM_KIT_CREDITS,
              "a rack is capped below the budget rather than by it");
        CHECK(sim_slot_cap(&kc, 0, SIM_SLOT_CHARGE(SIM_CHARGE_BURST))
                  < SIM_KIT_CREDITS,
              "both kinds of it");
        CHECK(sim_slot_cap(&kc, 0, SIM_SLOT_MOD(SIM_TRIG_GUN, SIM_MOD_PROX))
                  == 0,
              "a gun carries no proximity fuse");
        CHECK(sim_slot_cap(&kc, 0,
                           SIM_SLOT_MOD(SIM_TRIG_GUN, SIM_MOD_SHRAPNEL)) == 0,
              "and no shrapnel");
        CHECK(sim_slot_cap(&kc, 0, SIM_SLOT_MOD(SIM_TRIG_BOMB, SIM_MOD_PROX))
                  > 0,
              "while a bomb carries both");
        /* And a ceiling is a ceiling however it is asked for: spending past
         * one is fitted down rather than refused. */
        uint8_t over[SIM_SLOT_COUNT];
        memset(over, 0, sizeof over);
        over[SIM_SLOT_MOD(SIM_TRIG_GUN, SIM_MOD_PROX)] = 3;
        sim_kit_fit(&kc, 0, over);
        CHECK(sim_kit_cost(over) == 0,
              "a build spending on a shut slot spends nothing");
    }

    /* Every hull the game ships is affordable on the budget, which is the
     * claim the roster makes and the one thing that would quietly stop being
     * true if somebody wrote a richer profile. */
    {
        sim_settings kc = *base;
        for (uint8_t c = 0; c < kc.class_count; c++) {
            uint8_t row[SIM_SLOT_COUNT];
            memcpy(row, kc.classes[c].kit, sizeof row);
            CHECK(sim_kit_cost(row) <= SIM_KIT_CREDITS,
                  "a shipped profile spends no more than a pilot has");
            uint8_t fitted[SIM_SLOT_COUNT];
            sim_kit_default(&kc, c, fitted);
            CHECK(memcmp(row, fitted, sizeof row) == 0,
                  "so fitting one changes nothing about it");
            /* Which also says the ceilings are not below the roster: a cap
             * that cut a shipped hull's own row would be a hull nobody can
             * fly as designed. */
            for (int k = 0; k < SIM_SLOT_COUNT; k++) {
                CHECK(row[k] <= sim_slot_cap(&kc, c, (uint8_t)k),
                      "and no hull ships above a ceiling");
            }
        }
    }

    /* A match opens with everybody home, whole, and reloaded. This is the
     * edge between two matches in one room, and the one place ammunition
     * comes back: a death re-deals the frame and a whistle re-deals the
     * lot. */
    {
        /* The built-in arena, because it marks a start per side and what this
         * checks is that two sides open a match at their own ends. */
        sim_map *mm = malloc(sizeof *mm);
        sim_map_arena(mm);
        sim_settings mc;
        memset(&mc, 0, sizeof mc);
        sim_settings_baseline(&mc, mm);
        mc.spawn_radius = 0;
        static sim_state s;
        sim_init(&s, 9);
        int a = sim_spawn(&s, APEX, 0, 8192, 8192, 0, &mc);
        int b = sim_spawn(&s, APEX, 1, 9216, 9216, 0, &mc);
        /* A match played: one pilot dead with a tally, both out of repels,
         * a round in the air, and somebody a long way from home. */
        s.ships[a].kills = 3;
        s.ships[a].streak = 3;
        s.ships[a].charge[SIM_CHARGE_REPEL] = 0;
        s.ships[a].x = 4096;
        s.ships[a].vx = 30000;
        s.ships[b].alive = 0;
        s.ships[b].deaths = 3;
        s.ships[b].respawn_at = 300;
        s.ships[b].charge[SIM_CHARGE_REPEL] = 1;
        s.weapon_count = 1;

        sim_restart(&s, &mc);

        CHECK(s.weapon_count == 0, "nothing of the last match is still flying");
        for (int i = 0; i < 2; i++) {
            const sim_ship *sh = &s.ships[i == 0 ? a : b];
            CHECK(sh->alive && sh->respawn_at == 0, "everybody is on the field");
            CHECK(sh->kills == 0 && sh->deaths == 0,
                  "the tally is the match's own and starts again");
            CHECK(sh->streak == 0, "and so does the run");
            CHECK(sim_mod_get(sh->mods[SIM_TRIG_BOMB], SIM_MOD_PROX) == 1,
                  "the build is dealt");
            CHECK(sh->charge[SIM_CHARGE_REPEL] == 1,
                  "with the ammunition, which is what a whistle gives back");
            CHECK(sh->x == sh->spawn_x && sh->y == sh->spawn_y,
                  "on a start rather than wherever the last match left them");
            CHECK(sh->vx == 0 && sh->vy == 0, "at rest");
            CHECK(sh->energy == sim_eff_max_energy(&mc.classes[sh->cls], sh),
                  "and full");
        }
        CHECK(s.ships[a].spawn_x != s.ships[b].spawn_x
              || s.ships[a].spawn_y != s.ships[b].spawn_y,
              "two sides do not open a match on the same tile");

        /* And a side lines up along its own starts rather than piling onto
         * one, which is what the walk over `nth` is for. */
        int c = sim_spawn(&s, APEX, 0, 8192, 8192, 0, &mc);
        sim_restart(&s, &mc);
        CHECK(s.ships[a].spawn_x != s.ships[c].spawn_x
              || s.ships[a].spawn_y != s.ships[c].spawn_y,
              "two pilots of one side open on different starts");
        free(mm);
    }

    /* Every seat flies something, whoever is in it. There is no kit to be
     * missing and no account to consult: a hull always has a profile, so a
     * pilot who has never opened a menu, a bot, and a new account all arrive
     * in a whole ship. */
    {
        for (int c = 0; c < cfg.class_count; c++) {
            static sim_state ks;
            sim_init(&ks, 4);
            int id = sim_spawn(&ks, (uint8_t)c, 0, 8192, 8192, 0, &cfg);
            CHECK(id >= 0, "the hull seats");
            const sim_ship *sh = &ks.ships[id];
            CHECK(sh->energy > 0, "with a bar");
            CHECK(sim_eff_speed(&cfg.classes[c], sh) > 0, "and an engine");
            CHECK(cfg.classes[c].trigger[SIM_TRIG_GUN][sh->level[SIM_TRIG_GUN]]
                      != SIM_NO_PATTERN,
                  "and a gun that names a pattern");
        }
    }

}

int main(void) {
    sim_map *m = walled_map();
    sim_settings cfg;
    memset(&cfg, 0, sizeof cfg);
    sim_settings_baseline(&cfg, m);
    /* Bare, for the whole suite. What a hull carries is a build now, not a
     * property of the hull, so a test that wants one says so. */
    bare_kits(&cfg);

    test_flight_and_damage(&cfg);
    test_maps(&cfg);
    test_lifecycle(m, &cfg);
    test_weapon_model(m, &cfg);
    test_tech_tree(&cfg);
    test_scoring(&cfg);
    test_physics_and_wire(m, &cfg);
    test_spawning_and_snapshots(m, &cfg);
    test_kits_and_matches(&cfg);

    free(m);
    if (failures == 0) printf("all tests passed\n");
    return failures ? 1 : 0;
}
