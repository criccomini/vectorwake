/* vectorwake simulation core. See include/sim/sim.h for the contract. */
#include "sim/sim.h"

#include <string.h>

#include "sintab.h"

/* ---- fixed-point helpers ---- */

/* Direction of a heading as a Q15 unit vector. Heading 0 is up (-y),
 * increasing clockwise, so x follows sin and y follows -cos. */
static void heading_dir(uint16_t heading, int32_t *dx, int32_t *dy) {
    uint16_t i = (uint16_t)(heading >> 4); /* 65536 -> 4096 entries */
    *dx = sim_sintab[i & 4095];
    *dy = -sim_sintab[(i + 1024) & 4095]; /* cos(t) = sin(t + quarter) */
}

static int64_t isqrt64(int64_t v) {
    int64_t lo = 0, hi = 3037000499LL;
    if (v < 2) return v < 0 ? 0 : v;
    if (hi * hi > v) hi = v < hi ? v : hi;
    while (lo + 1 < hi) {
        int64_t mid = lo + (hi - lo) / 2;
        if (mid * mid <= v)
            lo = mid;
        else
            hi = mid;
    }
    return lo;
}

static uint32_t xorshift32(uint32_t x) {
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    return x ? x : 0x9e3779b9u;
}

/* A whole-pixel position squeezed into an event's one payload word. The map
 * is 16384 px on a side, so fourteen bits hold a coordinate exactly and the
 * pair fits with four to spare. Used by SIM_EV_EXPIRE, which is the only
 * report a caller gets of where a weapon stopped existing. */
static int32_t pack_pos(int32_t x_q8, int32_t y_q8) {
    int32_t x = (x_q8 >> 8) & 0x3fff;
    int32_t y = (y_q8 >> 8) & 0x3fff;
    return (x << 14) | y;
}

static void emit(sim_events *ev, uint8_t type, uint8_t a, uint8_t b,
                 int32_t v) {
    if (!ev) return;
    if (ev->count >= SIM_MAX_EVENTS) {
        ev->dropped++;
        return;
    }
    sim_event *e = &ev->e[ev->count++];
    e->type = type;
    e->a = a;
    e->b = b;
    e->v = v;
}

/* ---- settings conversion ---- */

int32_t sim_units_speed(int32_t v) {
    return (int32_t)(((int64_t)v << 16) / 1000);
}

int32_t sim_units_thrust(int32_t t) {
    return (int32_t)(((int64_t)t << 16) / 1000);
}

int32_t sim_units_rotation(int32_t r) {
    return (int32_t)(((int64_t)r << 16) / 40000);
}

int32_t sim_units_energy(int32_t e) { return e * 1024; }

/* r is energy*10 per second; per tick that is r/1000 energy. */
int32_t sim_units_recharge(int32_t r) {
    return (int32_t)(((int64_t)r * 1024) / 1000);
}

/* A fresh ship flies at this fraction of its ceiling; SIM_UP_STEPS prizes
 * close the gap. Both numbers are deliberately visible here rather than
 * buried in the baseline, because they set how much a green is worth. */
#define SIM_INIT_PCT 70
#define SIM_UP_STEPS 8

static void tier(int32_t max, int32_t *init, int32_t *step) {
    *init = (int32_t)(((int64_t)max * SIM_INIT_PCT) / 100);
    *step = (max - *init) / SIM_UP_STEPS;
}

void sim_class_from_units(sim_ship_class *c, int32_t speed, int32_t thrust,
                          int32_t rotation, int32_t energy, int32_t recharge,
                          int32_t radius_px) {
    memset(c, 0, sizeof *c);
    c->max_speed = sim_units_speed(speed);
    c->thrust = sim_units_thrust(thrust);
    c->rot = sim_units_rotation(rotation);
    c->max_energy = sim_units_energy(energy);
    c->recharge = sim_units_recharge(recharge);
    c->radius = radius_px * 256;
    tier(c->max_speed, &c->init_speed, &c->up_speed);
    tier(c->thrust, &c->init_thrust, &c->up_thrust);
    tier(c->rot, &c->init_rot, &c->up_rot);
    tier(c->max_energy, &c->init_energy, &c->up_energy);
    tier(c->recharge, &c->init_recharge, &c->up_recharge);
    /* No weapons until something gives it some. What a hull fires is a
     * pattern in the settings, and the settings are what a zone tunes. */
    c->gun = SIM_NO_PATTERN;
    c->bomb = SIM_NO_PATTERN;
}

/* ---- upgrades ---- */

static int32_t eff(int32_t init, int32_t step, int32_t cap, uint8_t n) {
    int64_t v = (int64_t)init + (int64_t)step * n;
    return v > cap ? cap : (int32_t)v;
}

int32_t sim_eff_speed(const sim_ship_class *c, const sim_ship *s) {
    return eff(c->init_speed, c->up_speed, c->max_speed, s->up[SIM_UP_SPEED]);
}
int32_t sim_eff_thrust(const sim_ship_class *c, const sim_ship *s) {
    return eff(c->init_thrust, c->up_thrust, c->thrust, s->up[SIM_UP_THRUST]);
}
int32_t sim_eff_rot(const sim_ship_class *c, const sim_ship *s) {
    return eff(c->init_rot, c->up_rot, c->rot, s->up[SIM_UP_ROTATION]);
}
int32_t sim_eff_max_energy(const sim_ship_class *c, const sim_ship *s) {
    return eff(c->init_energy, c->up_energy, c->max_energy, s->up[SIM_UP_ENERGY]);
}
int32_t sim_eff_recharge(const sim_ship_class *c, const sim_ship *s) {
    return eff(c->init_recharge, c->up_recharge, c->recharge, s->up[SIM_UP_RECHARGE]);
}

/* ---- state management ---- */

void sim_init(sim_state *s, uint32_t seed) {
    memset(s, 0, sizeof *s);
    s->rng = seed ? seed : 1u;
}

int sim_spawn(sim_state *s, uint8_t cls, uint8_t team, int32_t x_px,
              int32_t y_px, uint16_t heading, const sim_settings *cfg) {
    if (s->ship_count >= SIM_MAX_SHIPS) return -1;
    int i = s->ship_count++;
    sim_ship *sh = &s->ships[i];
    memset(sh, 0, sizeof *sh);
    sh->active = 1;
    sh->alive = 1;
    sh->cls = cls < cfg->class_count ? cls : 0;
    sh->team = team;
    sh->x = sh->spawn_x = x_px * 256;
    sh->y = sh->spawn_y = y_px * 256;
    sh->heading = heading;
    sh->energy = sim_eff_max_energy(&cfg->classes[sh->cls], sh);
    return i;
}

/* ---- collision ---- */

/* Below this speed a reflected component is treated as rest contact rather
 * than a bounce, so a ship leaning on a wall settles instead of buzzing. */
#define SIM_REST_EPS 4096          /* Q16: 1/16 px per tick */
/* And below this, the hit is a scrape rather than an impact: no event, so a
 * ship grinding along a wall does not fire a sound effect every tick. */
#define SIM_IMPACT_MIN 32768       /* Q16: 1/2 px per tick */

uint8_t sim_tile_at(const sim_map *m, int32_t tx, int32_t ty) {
    if (tx < 0 || ty < 0 || tx >= SIM_MAP_TILES || ty >= SIM_MAP_TILES)
        return SIM_TILE_SOLID;
    return m->tile[(size_t)ty * SIM_MAP_TILES + (size_t)tx];
}

/* A door's variant is its phase, an eighth of the cycle apart, so a map with
 * several channels opens and shuts in sequence instead of all at once. */
int sim_door_open(const sim_settings *cfg, uint32_t tick, uint8_t variant) {
    if (cfg->door_period == 0) return 0;
    uint32_t phase = (tick + (uint32_t)variant * cfg->door_period / 8)
                     % cfg->door_period;
    return phase < cfg->door_open;
}

static int solid(const sim_map *m, const sim_settings *cfg, uint32_t tick,
                 int32_t tx, int32_t ty) {
    uint8_t t = sim_tile_at(m, tx, ty);
    switch (SIM_TILE_CLASS(t)) {
        case SIM_TILE_SOLID: return 1;
        case SIM_TILE_DOOR:
            return !sim_door_open(cfg, tick, SIM_TILE_VARIANT(t));
        default: return 0;
    }
}

static int box_hits(const sim_map *m, const sim_settings *cfg, uint32_t tick,
                    int32_t x, int32_t y, int32_t r) {
    int32_t tx0 = (x - r) >> 12, tx1 = (x + r) >> 12;
    int32_t ty0 = (y - r) >> 12, ty1 = (y + r) >> 12;
    for (int32_t ty = ty0; ty <= ty1; ty++)
        for (int32_t tx = tx0; tx <= tx1; tx++)
            if (solid(m, cfg, tick, tx, ty)) return 1;
    return 0;
}

/* The tile a point stands in, by class. */
static int class_at(const sim_map *m, int32_t x, int32_t y) {
    return SIM_TILE_CLASS(sim_tile_at(m, x >> 12, y >> 12));
}

int sim_in_safe(const sim_map *m, int32_t x, int32_t y) {
    return class_at(m, x, y) == SIM_TILE_SAFE;
}

/* ---- weapons ---- */

int sim_add_spec(sim_settings *cfg, const sim_weapon_spec *spec) {
    if (cfg->spec_count >= SIM_MAX_SPECS) return -1;
    cfg->specs[cfg->spec_count] = *spec;
    return cfg->spec_count++;
}

int sim_add_pattern(sim_settings *cfg, const sim_fire_pattern *pattern) {
    if (cfg->pattern_count >= SIM_MAX_PATTERNS) return -1;
    cfg->patterns[cfg->pattern_count] = *pattern;
    return cfg->pattern_count++;
}

static void spawn_weapon(sim_state *s, uint8_t spec, uint8_t owner,
                         uint8_t team, int32_t x, int32_t y, int32_t vx,
                         int32_t vy, uint16_t life) {
    if (s->weapon_count >= SIM_MAX_WEAPONS) return; /* silently dropped */
    sim_weapon *w = &s->weapons[s->weapon_count++];
    w->spec = spec;
    w->owner = owner;
    w->team = team;
    w->x = x;
    w->y = y;
    w->vx = vx;
    w->vy = vy;
    w->life = life;
}

/* Put a pattern's projectiles into the world.
 *
 * The angles are laid out symmetrically about `heading` -- an odd count puts
 * one down the middle, an even count straddles it -- and they come out of the
 * table rather than a random number, so the same shot is the same shot on
 * every machine.
 *
 * Origin and heading are arguments rather than read off a ship, because the
 * other caller is a projectile that just ended: shrapnel is this function
 * called from inside `weapon_end`.
 */
static void spawn_pattern(sim_state *s, const sim_settings *cfg, uint8_t pat,
                          uint8_t owner, uint8_t team, int32_t x, int32_t y,
                          int32_t vx0, int32_t vy0, uint16_t heading,
                          sim_events *ev);

/* Remove a weapon by swapping the last one into its slot. Order is
 * deterministic because it depends only on state, never on time. */
static void kill_weapon(sim_state *s, uint16_t i) {
    s->weapons[i] = s->weapons[--s->weapon_count];
}

static void drop_flags(sim_state *s, const sim_settings *cfg, uint8_t ship,
                       sim_events *ev);

static void apply_damage(sim_state *s, const sim_settings *cfg, uint8_t victim,
                         uint8_t attacker, int32_t amount, sim_events *ev) {
    sim_ship *v = &s->ships[victim];
    if (!v->active || !v->alive) return;
    /* Nothing reaches a ship in a safe zone. A splash that clips the edge of
     * one does not leak in either, which is the whole point of the tile. */
    if (sim_in_safe(cfg->map, v->x, v->y)) return;
    v->energy -= amount;
    emit(ev, SIM_EV_HIT, victim, attacker, amount);
    if (v->energy <= 0) {
        v->energy = 0;
        v->alive = 0;
        v->deaths++;
        v->respawn_at = cfg->respawn_delay;
        v->vx = v->vy = 0;
        memset(v->up, 0, sizeof v->up);  /* dying costs you everything */
        if (attacker != 255 && attacker != victim) s->ships[attacker].kills++;
        drop_flags(s, cfg, victim, ev);
        emit(ev, SIM_EV_DEATH, victim, attacker, 0);
    }
}

/* What a projectile does where it ends.
 *
 * One ending, four things it might do, all optional and all read off the
 * spec: hurt the hull it touched, hurt everything inside a blast, shove what
 * is nearby, and fire another pattern from the same spot. A plain bullet has
 * only the first; a bomb has the first two; shrapnel is the fourth, and a
 * repel is the third with nothing else at all.
 *
 * Damage inside a blast falls off linearly from the centre, which is what
 * makes the damage a measure of how close you were standing -- the screen
 * shake reads it back out.
 */
static void weapon_end(sim_state *s, const sim_settings *cfg,
                       const sim_weapon_spec *spec, const sim_weapon *w,
                       int hit_ship, sim_events *ev) {
    if (spec->blast > 0) {
        int64_t rad = spec->blast;
        for (int i = 0; i < s->ship_count; i++) {
            sim_ship *sh = &s->ships[i];
            if (!sh->active || !sh->alive) continue;
            int64_t ddx = (int64_t)sh->x - w->x, ddy = (int64_t)sh->y - w->y;
            int64_t d2 = ddx * ddx + ddy * ddy;
            if (d2 > rad * rad) continue;
            int64_t d = isqrt64(d2);
            int32_t dmg = (int32_t)((int64_t)spec->damage * (rad - d) / rad);
            if (dmg > 0) apply_damage(s, cfg, (uint8_t)i, w->owner, dmg, ev);
        }
    } else if (hit_ship >= 0 && spec->damage > 0) {
        apply_damage(s, cfg, (uint8_t)hit_ship, w->owner, spec->damage, ev);
    }

    /* A shove, outward, falling off to nothing at the rim. Weapons are moved
     * too: pushing an incoming bomb away is the whole point of the thing. */
    if (spec->push > 0) {
        int64_t rad = spec->blast > 0 ? spec->blast : spec->trigger;
        if (rad > 0) {
            for (int i = 0; i < s->ship_count; i++) {
                sim_ship *sh = &s->ships[i];
                if (!sh->active || !sh->alive) continue;
                int64_t ddx = (int64_t)sh->x - w->x, ddy = (int64_t)sh->y - w->y;
                int64_t d2 = ddx * ddx + ddy * ddy;
                if (d2 > rad * rad) continue;
                int64_t d = isqrt64(d2);
                if (d == 0) continue;      /* dead centre has no direction */
                int64_t k = (int64_t)spec->push * (rad - d) / rad;
                sh->vx += (int32_t)(ddx * k / d);
                sh->vy += (int32_t)(ddy * k / d);
            }
            for (uint16_t i = 0; i < s->weapon_count; i++) {
                sim_weapon *o = &s->weapons[i];
                int64_t ddx = (int64_t)o->x - w->x, ddy = (int64_t)o->y - w->y;
                int64_t d2 = ddx * ddx + ddy * ddy;
                if (d2 > rad * rad || d2 == 0) continue;
                int64_t d = isqrt64(d2);
                int64_t k = (int64_t)spec->push * (rad - d) / rad;
                o->vx += (int32_t)(ddx * k / d);
                o->vy += (int32_t)(ddy * k / d);
            }
        }
    }

    if (spec->splinter != SIM_NO_PATTERN) {
        /* Fragments leave from where the parent stopped, at rest, spread
         * about world north. A shell of sixteen is rotationally symmetric, so
         * the base angle does not matter and a fixed one is one less thing to
         * get wrong across machines. A *directional* splinter -- a cone that
         * follows the parent's travel -- would need the heading kept on the
         * projectile, which is state, which is a snapshot byte. Not until
         * something wants it. */
        spawn_pattern(s, cfg, spec->splinter, w->owner, w->team, w->x, w->y,
                      0, 0, 0, ev);
    }
}

static void spawn_pattern(sim_state *s, const sim_settings *cfg, uint8_t pat,
                          uint8_t owner, uint8_t team, int32_t x, int32_t y,
                          int32_t vx0, int32_t vy0, uint16_t heading,
                          sim_events *ev) {
    if (pat >= cfg->pattern_count) return;
    const sim_fire_pattern *p = &cfg->patterns[pat];
    if (p->spec >= cfg->spec_count) return;
    const sim_weapon_spec *spec = &cfg->specs[p->spec];
    int count = p->count ? p->count : 1;
    for (int n = 0; n < count; n++) {
        /* (2n - (count-1)) / 2 is the symmetric offset in units of spacing:
         * zero for a single shot, ±half for a pair, -1/0/+1 for a trio. C
         * truncates toward zero, which is symmetric, so the two halves of a
         * spread are mirror images rather than one being a unit wider. */
        int32_t off = (int32_t)p->spacing * (2 * n - (count - 1)) / 2;
        uint16_t h = (uint16_t)((int32_t)heading + off);
        int32_t dx, dy;
        heading_dir(h, &dx, &dy);
        int32_t vx = vx0 + (int32_t)(((int64_t)spec->speed * dx) >> 15);
        int32_t vy = vy0 + (int32_t)(((int64_t)spec->speed * dy) >> 15);
        spawn_weapon(s, p->spec, owner, team, x, y, vx, vy, spec->life);
    }
    emit(ev, SIM_EV_FIRE, owner, p->spec, 0);
}

/* ---- flags ---- */

int sim_add_flag(sim_state *s, int32_t x_px, int32_t y_px) {
    if (s->flag_count >= SIM_MAX_FLAGS) return -1;
    int i = s->flag_count++;
    sim_flag *f = &s->flags[i];
    f->active = 1;
    f->carried = 0;
    f->carrier = 0;
    f->team = SIM_TEAM_NONE;
    f->x = x_px * 256;
    f->y = y_px * 256;
    f->cooldown = 0;
    return i;
}

int sim_flags_held(const sim_state *s, uint8_t team) {
    int n = 0;
    for (int i = 0; i < s->flag_count; i++)
        if (s->flags[i].active && s->flags[i].team == team) n++;
    return n;
}

/* Drop every flag a ship is carrying where it died, keeping the team that
 * held it: a dropped flag stays yours until somebody takes it back. */
static void drop_flags(sim_state *s, const sim_settings *cfg, uint8_t ship,
                       sim_events *ev) {
    for (int i = 0; i < s->flag_count; i++) {
        sim_flag *f = &s->flags[i];
        if (!f->active || !f->carried || f->carrier != ship) continue;
        f->carried = 0;
        f->x = s->ships[ship].x;
        f->y = s->ships[ship].y;
        f->cooldown = cfg->flag_drop_cooldown;
        emit(ev, SIM_EV_FLAG_DROP, (uint8_t)i, f->team, 0);
    }
}

/* Change a pilot's hull without changing the arena around them.
 *
 * A hull is not a costume: it is a different tank, a different gun and a
 * different turn rate, so swapping one mid-flight has to cost what dying
 * costs. You reappear at your start, at rest, with a full bar of the new
 * ship's energy and none of the upgrades you had collected, and anything you
 * were carrying goes back on the map. Everyone else keeps flying, which is
 * the whole point: a menu that rebuilt the arena to change your ship would
 * throw away the match to answer a question about yourself. */
int sim_set_ship_class(sim_state *s, const sim_settings *cfg, uint8_t i,
                       uint8_t cls) {
    if (i >= s->ship_count || cls >= cfg->class_count) return -1;
    sim_ship *sh = &s->ships[i];
    if (!sh->active) return -1;
    /* The hull you are already in is not a change. Without this, picking the
     * ship you are flying would cost you every upgrade you had collected for
     * no reason at all. */
    if (sh->cls == cls) return 0;
    /* Only from a full bar, and only alive.
     *
     * A hull swap hands you a fresh ship, so without a gate it is a way to
     * refill a bar mid-fight: take a beating, switch, come back whole. Full
     * energy means you are not in one -- or you have already flown clear of
     * it long enough to recover, which is the same thing. And a dead pilot is
     * refused rather than being handed an early respawn: this sets `alive`,
     * so allowing it while dead would skip the respawn delay entirely. */
    if (!sh->alive) return -1;
    if (sh->energy < sim_eff_max_energy(&cfg->classes[sh->cls], sh)) return -1;
    drop_flags(s, cfg, i, 0);
    sh->cls = cls;
    memset(sh->up, 0, sizeof sh->up);
    sh->alive = 1;
    sh->respawn_at = 0;
    sh->x = sh->spawn_x;
    sh->y = sh->spawn_y;
    sh->vx = sh->vy = 0;
    sh->fire_cooldown = 0;
    sh->energy = sim_eff_max_energy(&cfg->classes[cls], sh);
    return 0;
}

static void update_flags(sim_state *s, const sim_settings *cfg, sim_events *ev) {
    for (int i = 0; i < s->flag_count; i++) {
        sim_flag *f = &s->flags[i];
        if (!f->active) continue;

        if (f->carried) {
            const sim_ship *sh = &s->ships[f->carrier];
            if (!sh->active || !sh->alive) {
                /* The carrier stopped existing without dying properly. */
                f->carried = 0;
                f->cooldown = cfg->flag_drop_cooldown;
                continue;
            }
            f->x = sh->x;
            f->y = sh->y;
            continue;
        }

        if (f->cooldown > 0) { f->cooldown--; continue; }

        for (int k = 0; k < s->ship_count; k++) {
            sim_ship *sh = &s->ships[k];
            if (!sh->active || !sh->alive) continue;
            if (f->team == sh->team) continue;  /* already ours */
            int64_t dx = (int64_t)sh->x - f->x, dy = (int64_t)sh->y - f->y;
            int64_t r = cfg->flag_radius + cfg->classes[sh->cls].radius;
            if (dx * dx + dy * dy > r * r) continue;
            f->carried = 1;
            f->carrier = (uint8_t)k;
            f->team = sh->team;
            emit(ev, SIM_EV_FLAG_TAKE, (uint8_t)k, (uint8_t)i, 0);
            break;
        }
    }
}

/* ---- prizes ---- */

/* Spawn one prize at a random open tile inside the configured bounds. Every
 * draw comes from the state's own PRNG, so prize placement is part of the
 * deterministic stream and a client can predict it exactly. */
static void spawn_prize(sim_state *s, const sim_settings *cfg) {
    if (cfg->prize_hi <= cfg->prize_lo) return;
    int slot = -1;
    for (int i = 0; i < SIM_MAX_PRIZES; i++)
        if (!s->prizes[i].active) { slot = i; break; }
    if (slot < 0) return;

    int32_t span = cfg->prize_hi - cfg->prize_lo;
    for (int attempt = 0; attempt < 24; attempt++) {
        s->rng = xorshift32(s->rng);
        int32_t tx = cfg->prize_lo + (int32_t)(s->rng % (uint32_t)span);
        s->rng = xorshift32(s->rng);
        int32_t ty = cfg->prize_lo + (int32_t)(s->rng % (uint32_t)span);
        if (solid(cfg->map, cfg, s->tick, tx, ty)) continue;
        if (SIM_TILE_CLASS(sim_tile_at(cfg->map, tx, ty)) == SIM_TILE_SAFE)
            continue;
        s->rng = xorshift32(s->rng);
        sim_prize *p = &s->prizes[slot];
        p->active = 1;
        p->type = (uint8_t)(s->rng % SIM_UP_COUNT);
        p->x = (tx * SIM_TILE_PX + SIM_TILE_PX / 2) * 256;
        p->y = (ty * SIM_TILE_PX + SIM_TILE_PX / 2) * 256;
        p->life = cfg->prize_life;
        return;
    }
}

static void update_prizes(sim_state *s, const sim_settings *cfg, sim_events *ev) {
    uint16_t live = 0;
    for (int i = 0; i < SIM_MAX_PRIZES; i++) {
        sim_prize *p = &s->prizes[i];
        if (!p->active) continue;
        if (p->life > 0 && --p->life == 0) { p->active = 0; continue; }
        live++;

        for (int k = 0; k < s->ship_count; k++) {
            sim_ship *sh = &s->ships[k];
            if (!sh->active || !sh->alive) continue;
            int64_t dx = (int64_t)sh->x - p->x, dy = (int64_t)sh->y - p->y;
            int64_t r = cfg->prize_radius + cfg->classes[sh->cls].radius;
            if (dx * dx + dy * dy > r * r) continue;
            if (sh->up[p->type] < 255) sh->up[p->type]++;
            /* Collecting energy or recharge should feel immediate rather than
             * arriving over the next few seconds. */
            if (p->type == SIM_UP_ENERGY || p->type == SIM_UP_RECHARGE)
                sh->energy = sim_eff_max_energy(&cfg->classes[sh->cls], sh);
            emit(ev, SIM_EV_PRIZE, (uint8_t)k, p->type, 0);
            p->active = 0;
            live--;
            break;
        }
    }

    if (cfg->prize_delay == 0 || live >= cfg->prize_max) return;
    if (++s->prize_timer >= cfg->prize_delay) {
        s->prize_timer = 0;
        spawn_prize(s, cfg);
    }
}

/* ---- the step ---- */

void sim_step(sim_state *next, const sim_state *prev, const sim_input *inputs,
              uint16_t input_count, const sim_settings *cfg, sim_events *ev) {
    memcpy(next, prev, sizeof *next);
    next->tick = prev->tick + 1;
    next->rng = xorshift32(prev->rng);
    if (ev) {
        ev->count = 0;
        ev->dropped = 0;
    }

    uint16_t buttons[SIM_MAX_SHIPS] = {0};
    for (uint16_t i = 0; i < input_count; i++)
        if (inputs[i].ship < SIM_MAX_SHIPS) buttons[inputs[i].ship] = inputs[i].buttons;

    /* --- ships --- */
    for (int i = 0; i < next->ship_count; i++) {
        sim_ship *sh = &next->ships[i];
        if (!sh->active) continue;
        const sim_ship_class *cls = &cfg->classes[sh->cls];

        if (!sh->alive) {
            if (sh->respawn_at > 0 && --sh->respawn_at == 0) {
                sh->alive = 1;
                sh->x = sh->spawn_x;
                sh->y = sh->spawn_y;
                sh->vx = sh->vy = 0;
                sh->energy = sim_eff_max_energy(cls, sh);
                sh->fire_cooldown = 0;
                emit(ev, SIM_EV_SPAWN, (uint8_t)i, 0, 0);
            }
            continue;
        }

        uint16_t b = buttons[i];
        if (sh->fire_cooldown > 0) sh->fire_cooldown--;

        const int32_t e_rot = sim_eff_rot(cls, sh);
        const int32_t e_thrust = sim_eff_thrust(cls, sh);
        const int32_t e_speed = sim_eff_speed(cls, sh);

        /* 1. Rotate. */
        if (b & SIM_BTN_LEFT) sh->heading = (uint16_t)(sh->heading - e_rot);
        if (b & SIM_BTN_RIGHT) sh->heading = (uint16_t)(sh->heading + e_rot);

        int32_t dx, dy;
        heading_dir(sh->heading, &dx, &dy);

        /* 2. Thrust along the nose. */
        if (b & (SIM_BTN_THRUST | SIM_BTN_REVERSE)) {
            int32_t sign = (b & SIM_BTN_THRUST) ? 1 : -1;
            sh->vx += (int32_t)(((int64_t)e_thrust * dx * sign) >> 15);
            sh->vy += (int32_t)(((int64_t)e_thrust * dy * sign) >> 15);
        }

        /* 3. Fire. Guns take precedence over bombs when both are held, and
         * one cooldown covers both, so a ship cannot alternate to cheat it. */
        /* A safe zone is safe both ways: nothing can hurt you there and you
         * cannot shoot out of it, which is what stops it being a firing
         * position with immunity attached.
         *
         * Flight is otherwise untouched. A ship crosses one at speed like
         * anywhere else -- braking on entry made it flypaper, and a zone you
         * cannot pass through is a wall wearing a different colour.
         *
         * The trigger is the brake. Pressing fire in here does not shoot; it
         * stops you dead, which is the only way to come to rest in a game
         * with no friction, and it puts that under the pilot's thumb rather
         * than under the floor. */
        int in_safe = sim_in_safe(cfg->map, sh->x, sh->y);
        if (in_safe) {
            if (b & (SIM_BTN_FIRE | SIM_BTN_BOMB)) {
                sh->vx = 0;
                sh->vy = 0;
            }
            /* Whatever this ship still has in the air comes down with it. A
             * pilot who fires and runs for cover should not be scoring from
             * inside the one place nothing can answer. */
            for (uint16_t wi = 0; wi < next->weapon_count;) {
                if (next->weapons[wi].owner == (uint8_t)i) {
                    kill_weapon(next, wi);
                } else {
                    wi++;
                }
            }
        }
        if (!in_safe && sh->fire_cooldown == 0
            && (b & (SIM_BTN_FIRE | SIM_BTN_BOMB))) {
            uint8_t pat = ((b & SIM_BTN_FIRE) == 0) ? cls->bomb : cls->gun;
            if (pat < cfg->pattern_count) {
                const sim_fire_pattern *p = &cfg->patterns[pat];
                /* The cost is the shot's, not each projectile's: a burst of
                 * sixteen costs what pulling the trigger costs. */
                if (sh->energy > p->energy) {
                    /* Muzzle just outside the hull, so a shot never spawns
                     * inside its own ship. */
                    int32_t mx = sh->x + (int32_t)(((int64_t)(cls->radius + 512) * dx) >> 15);
                    int32_t my = sh->y + (int32_t)(((int64_t)(cls->radius + 512) * dy) >> 15);
                    spawn_pattern(next, cfg, pat, (uint8_t)i, sh->team, mx, my,
                                  sh->vx, sh->vy, sh->heading, ev);
                    sh->energy -= p->energy;
                    sh->fire_cooldown = p->delay;
                    sh->vx -= (int32_t)(((int64_t)p->recoil * dx) >> 15);
                    sh->vy -= (int32_t)(((int64_t)p->recoil * dy) >> 15);
                }
            }
        }

        /* 3b. Wormholes. The pull falls off linearly to nothing at the
         * rim, so a ship can cross the outer edge and still get away. */
        for (uint16_t f = 0; f < cfg->map->feature_count; f++) {
            const sim_feature *ft = &cfg->map->features[f];
            if (ft->kind != SIM_TILE_WORMHOLE) continue;
            int32_t wx = (int32_t)ft->tx * SIM_TILE_PX * 256 + (SIM_TILE_PX * 128);
            int32_t wy = (int32_t)ft->ty * SIM_TILE_PX * 256 + (SIM_TILE_PX * 128);
            int64_t dx = (int64_t)wx - sh->x, dy = (int64_t)wy - sh->y;
            int64_t d2 = dx * dx + dy * dy;
            int64_t range = cfg->wormhole_range;
            if (d2 == 0 || d2 > range * range) continue;
            int64_t d = isqrt64(d2);
            if (d == 0) continue;
            int64_t strength = (int64_t)cfg->wormhole_pull * (range - d) / range;
            sh->vx += (int32_t)(dx * strength / d);
            sh->vy += (int32_t)(dy * strength / d);
        }

        /* 4. Clamp to top speed. No drag term anywhere. */
        {
            int64_t mag2 = (int64_t)sh->vx * sh->vx + (int64_t)sh->vy * sh->vy;
            int64_t max = e_speed;
            if (mag2 > max * max) {
                int64_t mag = isqrt64(mag2);
                sh->vx = (int32_t)((int64_t)sh->vx * max / mag);
                sh->vy = (int32_t)((int64_t)sh->vy * max / mag);
            }
        }

        /* 4b. A door that shuts on a ship warps it rather than swallowing it.
         * The alternative is a ship inside a wall, which the axis-by-axis
         * collision below cannot resolve: both axes are blocked, so it stays
         * stuck until something kills it. Warping keeps the door lethal to
         * position without being lethal to the pilot. */
        if (SIM_TILE_CLASS(sim_tile_at(cfg->map, sh->x >> 12, sh->y >> 12))
                == SIM_TILE_DOOR
            && box_hits(cfg->map, cfg, next->tick, sh->x, sh->y, 0)) {
            sh->x = sh->spawn_x;
            sh->y = sh->spawn_y;
            sh->vx = 0;
            sh->vy = 0;
            emit(ev, SIM_EV_WARP, (uint8_t)i, 0, 0);
        }

        /* 5. Integrate and collide, one axis at a time so a wall kills only
         * the normal component and the ship slides along it. */
        {
            const sim_map *m = cfg->map;
            int32_t r = cls->radius;

            int32_t nx = sh->x + sh->vx / 256;
            if (box_hits(m, cfg, next->tick, nx, sh->y, r)) {
                if (sh->vx > 0)
                    nx = ((((sh->x + r) >> 12) + 1) << 12) - r - 1;
                else if (sh->vx < 0)
                    nx = (((sh->x - r) >> 12) << 12) + r;
                else
                    nx = sh->x;
                /* Reverse and damp the component that hit, and scrub some
                 * speed along the wall too: hitting a wall should cost you. */
                int32_t impact = sh->vx < 0 ? -sh->vx : sh->vx;
                sh->vx = (int32_t)(-(int64_t)sh->vx * cfg->bounce / 16);
                sh->vy = (int32_t)((int64_t)sh->vy * cfg->friction / 16);
                if (sh->vx < SIM_REST_EPS && sh->vx > -SIM_REST_EPS) sh->vx = 0;
                if (impact >= SIM_IMPACT_MIN)
                    emit(ev, SIM_EV_BOUNCE, (uint8_t)i, 0, impact);
            }
            sh->x = nx;

            int32_t ny = sh->y + sh->vy / 256;
            if (box_hits(m, cfg, next->tick, sh->x, ny, r)) {
                if (sh->vy > 0)
                    ny = ((((sh->y + r) >> 12) + 1) << 12) - r - 1;
                else if (sh->vy < 0)
                    ny = (((sh->y - r) >> 12) << 12) + r;
                else
                    ny = sh->y;
                int32_t impact = sh->vy < 0 ? -sh->vy : sh->vy;
                sh->vy = (int32_t)(-(int64_t)sh->vy * cfg->bounce / 16);
                sh->vx = (int32_t)((int64_t)sh->vx * cfg->friction / 16);
                if (sh->vy < SIM_REST_EPS && sh->vy > -SIM_REST_EPS) sh->vy = 0;
                if (impact >= SIM_IMPACT_MIN)
                    emit(ev, SIM_EV_BOUNCE, (uint8_t)i, 0, impact);
            }
            sh->y = ny;
        }

        {
            uint8_t t = sim_tile_at(cfg->map, sh->x >> 12, sh->y >> 12);
            if (SIM_TILE_CLASS(t) == SIM_TILE_GOAL)
                emit(ev, SIM_EV_GOAL, (uint8_t)i, SIM_TILE_VARIANT(t), 0);
        }

        /* 6. Recharge, after firing, so a shot costs a full tick of energy. */
        sh->energy += sim_eff_recharge(cls, sh);
        {
            int32_t cap = sim_eff_max_energy(cls, sh);
            if (sh->energy > cap) sh->energy = cap;
        }
    }

    update_prizes(next, cfg, ev);
    update_flags(next, cfg, ev);

    /* --- weapons ---
     *
     * Four phases, in order: it runs out, it moves, something ends it, and
     * the ending happens. Every difference between a bullet, a bomb, a mine
     * and a fragment is a number in its spec rather than a branch here.
     */
    for (uint16_t wi = 0; wi < next->weapon_count;) {
        sim_weapon *w = &next->weapons[wi];
        const sim_weapon_spec *spec = &cfg->specs[w->spec];
        int ended = 0, hit_ship = -1;

        /* 1. Out of life. Arriving somewhere is what sets a weapon off, and
         * running out is not arriving: at five seconds of flight a bomb that
         * simply expires has crossed the arena without touching anything.
         * A spec can ask for the other rule -- a mine's whole life is its
         * timer -- which is what `expire_ends` is. */
        if (w->life == 0) {
            if (spec->expire_ends) weapon_end(next, cfg, spec, w, -1, ev);
            emit(ev, SIM_EV_EXPIRE, w->spec, w->owner, pack_pos(w->x, w->y));
            kill_weapon(next, wi);
            continue;
        }
        w->life--;
        w->x += w->vx / 256;
        w->y += w->vy / 256;

        /* 2. Walls: stop here, bounce off, or ignore them entirely. */
        if (spec->on_wall != SIM_WALL_PASS
            && box_hits(cfg->map, cfg, next->tick, w->x, w->y, 0)) {
            ended = 1;
        }

        /* 3. Ships. A weapon never arrives at its owner or a teammate, and
         * `trigger` is how close counts: zero is contact with the hull, which
         * is a bullet, and anything larger is a proximity fuse. */
        if (!ended) {
            for (int i = 0; i < next->ship_count && !ended; i++) {
                sim_ship *sh = &next->ships[i];
                if (!sh->active || !sh->alive) continue;
                if ((uint8_t)i == w->owner || sh->team == w->team) continue;
                int64_t ddx = (int64_t)sh->x - w->x, ddy = (int64_t)sh->y - w->y;
                int64_t d2 = ddx * ddx + ddy * ddy;
                int64_t r = cfg->classes[sh->cls].radius + spec->trigger;
                if (d2 <= r * r) {
                    ended = 1;
                    hit_ship = i;
                }
            }
        }

        /* 4. The ending. */
        if (ended) {
            weapon_end(next, cfg, spec, w, hit_ship, ev);
            emit(ev, SIM_EV_EXPIRE, w->spec, w->owner, pack_pos(w->x, w->y));
            kill_weapon(next, wi);
            continue;
        }
        wi++;
    }
}

/* ---- hashing ---- */

static uint64_t fnv1a(uint64_t h, const void *data, size_t len) {
    const uint8_t *p = (const uint8_t *)data;
    for (size_t i = 0; i < len; i++) {
        h ^= p[i];
        h *= 0x100000001b3ULL;
    }
    return h;
}

static uint64_t hash_u32(uint64_t h, uint32_t v) {
    uint8_t b[4] = {(uint8_t)v, (uint8_t)(v >> 8), (uint8_t)(v >> 16),
                    (uint8_t)(v >> 24)};
    return fnv1a(h, b, 4);
}

/* Serialize field by field in little-endian order so struct padding and host
 * endianness cannot leak into the hash. */
uint64_t sim_hash(const sim_state *s) {
    uint64_t h = 0xcbf29ce484222325ULL;
    h = hash_u32(h, s->tick);
    h = hash_u32(h, s->rng);
    h = hash_u32(h, s->ship_count);
    h = hash_u32(h, s->weapon_count);
    for (int i = 0; i < s->ship_count; i++) {
        const sim_ship *sh = &s->ships[i];
        h = hash_u32(h, (uint32_t)(sh->active | (sh->alive << 8) |
                                   (sh->cls << 16) | (sh->team << 24)));
        h = hash_u32(h, (uint32_t)sh->x);
        h = hash_u32(h, (uint32_t)sh->y);
        h = hash_u32(h, (uint32_t)sh->vx);
        h = hash_u32(h, (uint32_t)sh->vy);
        h = hash_u32(h, sh->heading);
        h = hash_u32(h, (uint32_t)sh->energy);
        h = hash_u32(h, (uint32_t)(sh->fire_cooldown | (sh->respawn_at << 16)));
        h = hash_u32(h, (uint32_t)(sh->kills | (sh->deaths << 16)));
        for (int u = 0; u < SIM_UP_COUNT; u++) h = hash_u32(h, sh->up[u]);
    }
    h = hash_u32(h, s->prize_timer);
    h = hash_u32(h, s->flag_count);
    for (int i = 0; i < s->flag_count; i++) {
        const sim_flag *f = &s->flags[i];
        h = hash_u32(h, (uint32_t)(f->active | (f->carried << 8) |
                                   (f->carrier << 16) | (f->team << 24)));
        h = hash_u32(h, (uint32_t)f->x);
        h = hash_u32(h, (uint32_t)f->y);
        h = hash_u32(h, f->cooldown);
    }
    for (int i = 0; i < SIM_MAX_PRIZES; i++) {
        const sim_prize *p = &s->prizes[i];
        if (!p->active) continue;
        h = hash_u32(h, (uint32_t)(i | (p->type << 8) | (p->active << 16)));
        h = hash_u32(h, (uint32_t)p->x);
        h = hash_u32(h, (uint32_t)p->y);
        h = hash_u32(h, p->life);
    }
    for (uint16_t i = 0; i < s->weapon_count; i++) {
        const sim_weapon *w = &s->weapons[i];
        h = hash_u32(h, (uint32_t)(w->spec | (w->owner << 8) | (w->team << 16)));
        h = hash_u32(h, (uint32_t)w->x);
        h = hash_u32(h, (uint32_t)w->y);
        h = hash_u32(h, (uint32_t)w->vx);
        h = hash_u32(h, (uint32_t)w->vy);
        h = hash_u32(h, w->life);
    }
    return h;
}
