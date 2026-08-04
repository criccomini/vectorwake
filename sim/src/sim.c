/* vectorwake simulation core. See include/sim/sim.h for the contract. */
#include "sim/sim.h"

#include <stddef.h>
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

/* A repel reaches over a square rather than a circle: the original tests a
 * point against a box of RepelDistance on each side, so the corners reach
 * about 724 px where the sides reach 512. Kept because it is what the game
 * does, not because it is tidier. */
static int in_box(int64_t dx, int64_t dy, int64_t half) {
    if (dx < 0) dx = -dx;
    if (dy < 0) dy = -dy;
    return dx <= half && dy <= half;
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

/* How many prizes of one kind a pilot may hold. The ceiling is what stops a
 * stat climbing, not this: `eff` clamps at the maximum, so collecting more
 * than the ladder needs does nothing, which is what the original does too. */
#define SIM_UP_STEPS 8

void sim_class_from_units(sim_ship_class *c, const sim_class_units *u) {
    memset(c, 0, sizeof *c);
    c->max_speed = sim_units_speed(u->max_speed);
    c->thrust = sim_units_thrust(u->max_thrust);
    c->rot = sim_units_rotation(u->max_rotation);
    c->max_energy = sim_units_energy(u->max_energy);
    c->recharge = sim_units_recharge(u->max_recharge);
    /* Where a fresh hull starts and what one prize is worth, both named
     * rather than derived. They used to be a flat seventy per cent of the
     * ceiling and an eighth of the gap, which is tidy and is not what the
     * original does: it starts a pilot at 62% of top speed but 88% of top
     * thrust, and one green is worth a quarter of the speed gap against a
     * seventh of the energy gap. A rule cannot express that, so it is a
     * table. */
    c->init_speed = sim_units_speed(u->init_speed);
    c->up_speed = sim_units_speed(u->up_speed);
    c->init_thrust = sim_units_thrust(u->init_thrust);
    c->up_thrust = sim_units_thrust(u->up_thrust);
    c->init_rot = sim_units_rotation(u->init_rotation);
    c->up_rot = sim_units_rotation(u->up_rotation);
    c->init_energy = sim_units_energy(u->init_energy);
    c->up_energy = sim_units_energy(u->up_energy);
    c->init_recharge = sim_units_recharge(u->init_recharge);
    c->up_recharge = sim_units_recharge(u->up_recharge);
    /* No weapons until something gives it some, and no add-ons it may hold.
     * What a hull fires is a ladder of patterns in the settings, and the
     * settings are what a zone tunes. */
    for (int t = 0; t < SIM_TRIG_COUNT; t++) {
        for (int r = 0; r < SIM_MAX_RUNGS; r++) c->trigger[t][r] = SIM_NO_PATTERN;
        c->mod_max[t] = 0;
    }
    for (int k = 0; k < SIM_MAX_CHARGES; k++) c->charge_max[k] = 0;
}

/* ---- upgrades ---- */

/* The rung a trigger is on, clamped to the ladder the hull actually has. A
 * pilot keeps their level through a hull change, so the Anvil's third rung
 * has to mean rung zero on a hull with one. */
static uint8_t trigger_pattern(const sim_ship_class *c, int t, uint8_t level) {
    for (int r = level < SIM_MAX_RUNGS ? level : SIM_MAX_RUNGS - 1; r >= 0; r--)
        if (c->trigger[t][r] != SIM_NO_PATTERN) return c->trigger[t][r];
    return SIM_NO_PATTERN;
}

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
uint8_t sim_eff_max_ships(const sim_settings *cfg) {
    /* Written as a min rather than a range check because max_ships is a u8 and
     * the ceiling is 255, so `> SIM_MAX_SHIPS` is unreachable and -Wtype-limits
     * says so. This stays correct if the ceiling is ever lowered. */
    if (cfg->max_ships == 0) return SIM_MAX_SHIPS;
    return cfg->max_ships < SIM_MAX_SHIPS ? cfg->max_ships : SIM_MAX_SHIPS;
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

/* Hand a fresh ship its opening greens.
 *
 * The same roll a green on the floor gets, run `spawn_prizes` times off the
 * state's own generator -- so it is deterministic, it respects the hull's
 * roster and every ceiling in it, and a zone that reweights the tree gets the
 * spawn it asked for without a second table.
 *
 * Rust is left in rather than suppressed. It cannot bite on the first roll --
 * an empty pilot has nothing to corrode -- and after that it is one green in a
 * hundred, so it costs a spawn a fraction of an item on average and needs no
 * special case to say so.
 *
 * The caller sets energy afterwards, not before: the energy ceiling is a
 * function of `up[SIM_UP_ENERGY]`, and filling the bar before the prizes lands
 * would leave a ship at less than the full one it just earned. */
static void outfit(sim_ship *sh, const sim_settings *cfg, uint32_t *rng) {
    for (uint16_t n = 0; n < cfg->spawn_prizes; n++)
        sim_take_prize(sh, cfg, rng, NULL);
}

uint32_t sim_offsetof_settings_max_ships(void) {
    return (uint32_t)offsetof(sim_settings, max_ships);
}

uint32_t sim_sizeof_state(void) { return (uint32_t)sizeof(sim_state); }
uint32_t sim_sizeof_settings(void) { return (uint32_t)sizeof(sim_settings); }
uint32_t sim_sizeof_ship(void) { return (uint32_t)sizeof(sim_ship); }

int sim_spawn(sim_state *s, uint8_t cls, uint8_t team, int32_t x_px,
              int32_t y_px, uint16_t heading, const sim_settings *cfg) {
    /* An inactive slot before a new one. Without this the count only ever rose:
     * a room's capacity to seat a *new* ship was its lifetime arrivals rather
     * than its concurrent ones, so a busy arena eventually refused a tenth
     * player in a room built for thirty-two, and until it did, it paid to
     * simulate and to broadcast every ship anyone had ever occupied. The count
     * stays a high-water mark, which is what bounds every loop and the hash. */
    int i = -1;
    for (int k = 0; k < s->ship_count; k++) {
        if (!s->ships[k].active) { i = k; break; }
    }
    if (i < 0) {
        if (s->ship_count >= sim_eff_max_ships(cfg)) return -1;
        i = s->ship_count++;
    }
    sim_ship *sh = &s->ships[i];
    memset(sh, 0, sizeof *sh);
    sh->active = 1;
    sh->alive = 1;
    sh->cls = cls < cfg->class_count ? cls : 0;
    sh->team = team;
    sh->x = sh->spawn_x = x_px * 256;
    sh->y = sh->spawn_y = y_px * 256;
    sh->heading = heading;
    outfit(sh, cfg, &s->rng);
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
                    int32_t x, int32_t y, int32_t rx, int32_t ry) {
    int32_t tx0 = (x - rx) >> 12, tx1 = (x + rx) >> 12;
    int32_t ty0 = (y - ry) >> 12, ty1 = (y + ry) >> 12;
    for (int32_t ty = ty0; ty <= ty1; ty++)
        for (int32_t tx = tx0; tx <= tx1; tx++)
            if (solid(m, cfg, tick, tx, ty)) return 1;
    return 0;
}

/* The world-axis box a hull stands in at a heading: the tight bounding box of
 * its oriented footprint. `ox, oy` is where the box's centre sits relative to
 * the ship's position, because a hull reaches further past its nose than
 * behind its tail; `hx, hy` are the half-extents. An Apex flying diagonally
 * really is wider than one flying straight, so a gap it threads nose-first is
 * a gap it has to straighten up for, which is the point of computing this
 * from the heading rather than keeping one number.
 *
 * Two table reads, six multiplies. The thrust code pays the same table read
 * every tick and has never shown up in a profile. */
static void hull_box(const sim_ship_class *c, uint16_t heading,
                     int32_t *ox, int32_t *oy, int32_t *hx, int32_t *hy) {
    int32_t fx, fy;
    heading_dir(heading, &fx, &fy);
    int32_t afx = fx < 0 ? -fx : fx;
    int32_t afy = fy < 0 ? -fy : fy;
    int32_t half = (c->fore + c->aft) / 2;
    int32_t off = (c->fore - c->aft) / 2;
    *ox = (int32_t)(((int64_t)off * fx) >> 15);
    *oy = (int32_t)(((int64_t)off * fy) >> 15);
    *hx = (int32_t)(((int64_t)half * afx + (int64_t)c->halfw * afy) >> 15);
    *hy = (int32_t)(((int64_t)half * afy + (int64_t)c->halfw * afx) >> 15);
}

/* Whether a point falls within `pad` of the hull's oriented rectangle, which
 * is the shape the client draws. Weapons and pickups use this rather than the
 * world-axis box above: a wall stops you where your box is, but a bullet into
 * a Cipher's flank should have to reach the knife, not a square drawn around
 * it. The delta is rotated into the hull's own frame; along runs tail to
 * nose, across runs wing to wing. */
static int hull_reaches(const sim_ship_class *c, uint16_t heading,
                        int32_t sx, int32_t sy, int32_t px, int32_t py,
                        int32_t pad) {
    int32_t fx, fy;
    heading_dir(heading, &fx, &fy);
    int64_t dx = (int64_t)px - sx, dy = (int64_t)py - sy;
    int64_t along = (dx * fx + dy * fy) >> 15;
    int64_t across = (dy * fx - dx * fy) >> 15;
    if (across < 0) across = -across;
    return along >= -((int64_t)c->aft + pad) && along <= (int64_t)c->fore + pad
        && across <= (int64_t)c->halfw + pad;
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
                         int32_t vy, uint16_t life, uint8_t left,
                         uint8_t depth, uint16_t mods) {
    if (s->weapon_count >= SIM_MAX_WEAPONS) return; /* silently dropped */
    sim_weapon *w = &s->weapons[s->weapon_count++];
    w->spec = spec;
    w->owner = owner;
    w->team = team;
    w->left = left;
    w->depth = depth;
    w->mods = mods;
    w->x = x;
    w->y = y;
    w->vx = vx;
    w->vy = vy;
    w->life = life;
}

/* ---- add-ons ----
 *
 * A pilot's add-ons are a transform over the rung their trigger is on, applied
 * where the shot is made rather than stored as a row. Three levels against six
 * on/off add-ons is a hundred and ninety-two rows for one weapon; the table
 * holds thirty-two. So this is the only place a weapon becomes what the pilot
 * is actually carrying.
 *
 * Each rung is worth `mod_step`, which the zone sets in the units of the field
 * it moves. `p` is NULL when a projectile already in flight is being resolved:
 * how it was fired is settled, and only what it *is* still matters.
 */
static void compose(const sim_settings *cfg, uint16_t mods, uint8_t level,
                    sim_weapon_spec *sp, sim_fire_pattern *p) {
    uint8_t n;
    if (p && (n = sim_mod_get(mods, SIM_MOD_MULTI)) != 0) {
        int32_t base = (int32_t)(p->count ? p->count : 1);
        int32_t extra = n * cfg->mod_step[SIM_MOD_MULTI];
        int32_t total = base + extra;
        p->count = (uint8_t)(total > 255 ? 255 : total);
        /* A pattern that already fans keeps its own angle; one that does not
         * gets the zone's, or the extra barrels would all fire down the
         * same line. */
        if (p->spacing == 0) p->spacing = cfg->mod_spread;
        /* Multifire is the one add-on that costs more to pull the trigger
         * with. Everything else here is a shape or a fuse; this is literally
         * more bullets, and free bullets is the whole of the balance problem.
         *
         * The original priced it as two separate numbers rather than per
         * round -- `BulletFireEnergy=20` against `MultiFireEnergy=30`, and
         * `BulletFireDelay=25` against `MultiFireDelay=50` -- so three
         * bullets cost half again as much energy and twice the cooldown. Most
         * of the price is in the rate, which is the part that cannot be
         * out-recharged. Ours is those two ratios as a percentage per rung,
         * because we have rungs and it did not. */
        p->energy = (int32_t)((int64_t)p->energy
                              * (100 + n * cfg->mod_multi_energy) / 100);
        {
            int32_t d = (int32_t)p->delay * (100 + n * cfg->mod_multi_delay) / 100;
            p->delay = (uint16_t)(d > 65535 ? 65535 : d);
        }
    }
    if ((n = sim_mod_get(mods, SIM_MOD_BOUNCE)) != 0) {
        sp->on_wall = SIM_WALL_BOUNCE;
        /* Saturating, not wrapping. Shrapnel's base is already 255, and a
         * fragment inherits its parent's mods, so a bounce add-on under a
         * u8 wrap would hand whole-life fragments a handful of bounces. */
        int32_t b = sp->bounces + n * cfg->mod_step[SIM_MOD_BOUNCE];
        sp->bounces = (uint8_t)(b > 255 ? 255 : b);
    }
    if ((n = sim_mod_get(mods, SIM_MOD_PROX)) != 0) {
        /* ProximityDistance is the L1 radius and each bomb level adds one
         * tile to it, so a fuse is what the prize gives plus what the ladder
         * has climbed. The level has to be passed in because the rung picks
         * the spec before an add-on is ever applied to it, so by here the
         * pattern no longer knows which rung it came from. */
        sp->trigger += n * cfg->mod_step[SIM_MOD_PROX] + level * cfg->prox_step;
    }
    if ((n = sim_mod_get(mods, SIM_MOD_SHRAPNEL)) != 0)
        sp->splinter = cfg->mod_splinter[n < SIM_MAX_RUNGS ? n : SIM_MAX_RUNGS - 1];
    if ((n = sim_mod_get(mods, SIM_MOD_FREEZE)) != 0)
        sp->stall = (uint16_t)(sp->stall + n * cfg->mod_step[SIM_MOD_FREEZE]);
    if ((n = sim_mod_get(mods, SIM_MOD_PUSH)) != 0) {
        sp->push += n * cfg->mod_step[SIM_MOD_PUSH];
        /* A shove needs somewhere to reach from, and it reaches as far as the
         * blast or the fuse. Welded onto a bullet that has neither, it would
         * be a repel with no radius, so it brings a fuse with it. */
        if (sp->blast == 0 && sp->trigger == 0)
            sp->trigger = cfg->mod_step[SIM_MOD_PROX];
    }
}

/* A trigger's pattern and projectile as the pilot holding these add-ons
 * actually fires them. Zero when the trigger has nothing on it. */
static int resolve(const sim_settings *cfg, uint8_t pat, uint16_t mods,
                   uint8_t level, sim_fire_pattern *p, sim_weapon_spec *sp) {
    if (pat >= cfg->pattern_count) return 0;
    *p = cfg->patterns[pat];
    if (p->spec >= cfg->spec_count) return 0;
    *sp = cfg->specs[p->spec];
    compose(cfg, mods, level, sp, p);
    return 1;
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
                          uint8_t depth, uint16_t mods, uint8_t level,
                          sim_events *ev);

/* Remove a weapon by swapping the last one into its slot. Order is
 * deterministic because it depends only on state, never on time. */
static void kill_weapon(sim_state *s, uint16_t i) {
    s->weapons[i] = s->weapons[--s->weapon_count];
}

static void drop_flags(sim_state *s, const sim_settings *cfg, uint8_t ship,
                       sim_events *ev);

int32_t sim_bounty(const sim_ship *sh) {
    int32_t n = sh->earned;
    for (int u = 0; u < SIM_UP_COUNT; u++) n += sh->up[u];
    for (int t = 0; t < SIM_TRIG_COUNT; t++) {
        n += sh->level[t];
        for (int m = 0; m < SIM_MOD_COUNT; m++) n += sim_mod_get(sh->mods[t], m);
    }
    for (int k = 0; k < SIM_MAX_CHARGES; k++) n += sh->charge[k];
    return n;
}

static void apply_damage(sim_state *s, const sim_settings *cfg, uint8_t victim,
                         uint8_t attacker, int32_t amount, uint16_t stall,
                         sim_events *ev) {
    sim_ship *v = &s->ships[victim];
    if (!v->active || !v->alive) return;
    /* Nothing reaches a ship in a safe zone. A splash that clips the edge of
     * one does not leak in either, which is the whole point of the tile. */
    if (sim_in_safe(cfg->map, v->x, v->y)) return;
    /* A stall round suppresses the victim's recharge rather than taking more
     * off the bar: in a game where energy is the health and the ammunition,
     * stopping the refill is its own kind of damage, and the longer of two
     * stalls wins rather than them adding up. */
    if (stall > v->stall) v->stall = stall;
    v->energy -= amount;
    emit(ev, SIM_EV_HIT, victim, attacker, amount);
    if (v->energy <= 0) {
        v->energy = 0;
        v->alive = 0;
        v->deaths++;
        v->respawn_at = cfg->respawn_delay;
        v->vx = v->vy = 0;
        /* What the kill is worth, read before the pilot is stripped: the
         * price is what they were carrying, and in one more instruction it
         * will be nothing. A fresh spawn is therefore worth nothing at all,
         * which is why this game needs no anti-farming rule -- camping a
         * respawn pays exactly zero. */
        int32_t paid = 0;
        if (attacker != 255 && attacker != victim) {
            sim_ship *k = &s->ships[attacker];
            k->kills++;
            /* A teammate's death pays neither points nor bounty. The rating
             * layer already refuses to score teammate damage; this is the
             * same rule where a player can see it. */
            if (k->team != v->team) {
                paid = sim_bounty(v);
                for (int f = 0; f < s->flag_count; f++)
                    if (s->flags[f].active && s->flags[f].carried
                        && s->flags[f].carrier == victim)
                        paid += cfg->points_per_flag;
                k->points += (uint32_t)paid;
                k->earned = (uint16_t)(k->earned + cfg->bounty_per_kill);
            }
        }
        /* Dying costs you everything: stats, rungs, add-ons and the bounty
         * killing earned you. What you are carrying is what you have
         * survived with -- but the points already paid to you are yours. */
        v->repel = 0;
        v->repel_speed = 0;
        memset(v->up, 0, sizeof v->up);
        memset(v->level, 0, sizeof v->level);
        memset(v->mods, 0, sizeof v->mods);
        memset(v->charge, 0, sizeof v->charge);
        v->earned = 0;
        drop_flags(s, cfg, victim, ev);
        emit(ev, SIM_EV_DEATH, victim, attacker, paid);
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
    /* InactiveShrapDamage: a fragment does almost nothing for its first
     * quarter second.
     *
     * Shrapnel comes into being at the point of impact, which is inside the
     * hull the bomb just hit, so without this a bomb lands twice over -- once
     * as a blast and again as a ring of fragments already touching their
     * victim, none of which had to be aimed. Depth is what marks a fragment:
     * it is only ever set by a splinter.
     *
     * Age rather than a flag on the projectile, because the spec knows the
     * life it was born with and the weapon knows what is left of it, so this
     * costs nothing on the wire. */
    int32_t damage = spec->damage;
    if (w->depth > 0 && cfg->shrap_inactive_ticks > 0
        && spec->life > w->life
        && (uint16_t)(spec->life - w->life) < cfg->shrap_inactive_ticks) {
        damage = cfg->shrap_inactive;
    }
    if (spec->blast > 0) {
        int64_t rad = spec->blast;
        for (int i = 0; i < s->ship_count; i++) {
            sim_ship *sh = &s->ships[i];
            if (!sh->active || !sh->alive) continue;
            int64_t ddx = (int64_t)sh->x - w->x, ddy = (int64_t)sh->y - w->y;
            int64_t d2 = ddx * ddx + ddy * ddy;
            if (d2 > rad * rad) continue;
            int64_t d = isqrt64(d2);
            int32_t dmg = (int32_t)((int64_t)damage * (rad - d) / rad);
            /* A round that only stalls does no damage at all, so `dmg > 0`
             * cannot be the test for whether anything happened -- that is
             * what made the first stall round land silently. */
            if (dmg > 0 || spec->stall > 0)
                apply_damage(s, cfg, (uint8_t)i, w->owner, dmg, spec->stall, ev);
        }
    } else if (hit_ship >= 0 && (spec->damage > 0 || spec->stall > 0)) {
        apply_damage(s, cfg, (uint8_t)hit_ship, w->owner, damage,
                     spec->stall, ev);
    }

    /* A shove, outward, falling off to nothing at the rim. Weapons are moved
     * too: pushing an incoming bomb away is the whole point of the thing.
     *
     * Hostile only, both loops. A repel in the original moves enemies and
     * enemy fire and leaves you, your side and your own rounds alone, and
     * without the test this was symmetric: it threw the pilot who let it off
     * backwards at 484 px/s -- faster than any hull can fly -- because the
     * charge spawns at a muzzle offset rather than at the hull centre, so the
     * "dead centre has no direction" guard below never saw them. It shoved
     * team mates as hard as enemies, and it scattered the volley you had just
     * fired along with the one coming at you.
     *
     * The test is on team rather than on owner, which covers the firer too,
     * since a round carries the team of whoever fired it. It applies to every
     * spec with push, not just the charge: the push add-on on a Lattice bomb
     * should no more knock your own side about than the charge does. */
    if (spec->push > 0) {
        int64_t rad = spec->blast > 0 ? spec->blast : spec->trigger;
        if (rad > 0) {
            for (int i = 0; i < s->ship_count; i++) {
                sim_ship *sh = &s->ships[i];
                if (!sh->active || !sh->alive) continue;
                if (sh->team == w->team) continue;
                /* Nothing reaches a ship in a safe zone, and a shove is a
                 * thing reaching it. `apply_damage` has had this rule since
                 * the tile existed; the push loop never learned it, so a
                 * repel could throw somebody out of the one place in the
                 * arena that is supposed to be somewhere you cannot be
                 * touched -- and out into the open, at speed, which is worse
                 * than damage because the zone is where you stop. */
                if (sim_in_safe(cfg->map, sh->x, sh->y)) continue;
                int64_t ddx = (int64_t)sh->x - w->x, ddy = (int64_t)sh->y - w->y;
                if (!in_box(ddx, ddy, rad)) continue;
                int64_t d = isqrt64(ddx * ddx + ddy * ddy);
                if (d == 0) continue;      /* dead centre has no direction */
                sh->vx = (int32_t)(ddx * spec->push / d);
                sh->vy = (int32_t)(ddy * spec->push / d);
                sh->repel = spec->push_time;
                sh->repel_speed = spec->push;
            }
            for (uint16_t i = 0; i < s->weapon_count; i++) {
                sim_weapon *o = &s->weapons[i];
                if (o->team == w->team) continue;
                /* A repel does not move another repel. Otherwise two let off
                 * near each other throw one another around, which is a thing
                 * the original explicitly excludes. */
                if (cfg->specs[o->spec].push > 0) continue;
                int64_t ddx = (int64_t)o->x - w->x, ddy = (int64_t)o->y - w->y;
                if (!in_box(ddx, ddy, rad)) continue;
                int64_t d = isqrt64(ddx * ddx + ddy * ddy);
                if (d == 0) continue;
                o->vx = (int32_t)(ddx * spec->push / d);
                o->vy = (int32_t)(ddy * spec->push / d);
                /* And its clock starts again. A bomb batted back the way it
                 * came has the whole of its life to make the trip. */
                o->life = cfg->specs[o->spec].life;
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
        /* One generation. A fragment that fragments is a fork bomb: sixteen
         * become two hundred and fifty-six become four thousand, and the
         * weapon table has room for a thousand. The depth carried on the
         * projectile is the stop. */
        if (w->depth < SIM_MAX_SPLINTER_DEPTH) {
            spawn_pattern(s, cfg, spec->splinter, w->owner, w->team, w->x, w->y,
                          0, 0, 0, (uint8_t)(w->depth + 1), 0, 0, ev);
        }
    }
}

static void spawn_pattern(sim_state *s, const sim_settings *cfg, uint8_t pat,
                          uint8_t owner, uint8_t team, int32_t x, int32_t y,
                          int32_t vx0, int32_t vy0, uint16_t heading,
                          uint8_t depth, uint16_t mods, uint8_t level,
                          sim_events *ev) {
    sim_fire_pattern fp;
    sim_weapon_spec sp;
    if (!resolve(cfg, pat, mods, level, &fp, &sp)) return;
    const sim_fire_pattern *p = &fp;
    const sim_weapon_spec *spec = &sp;
    int count = p->count ? p->count : 1;
    for (int n = 0; n < count; n++) {
        /* (2n - (count-1)) / 2 is the symmetric offset in units of spacing:
         * zero for a single shot, ±half for a pair, -1/0/+1 for a trio. C
         * truncates toward zero, which is symmetric, so the two halves of a
         * spread are mirror images rather than one being a unit wider. */
        int32_t off = (int32_t)p->spacing * (2 * n - (count - 1)) / 2;
        /* Spacing of zero on a pattern of many means they scatter instead of
         * sitting on a ring. That is Shrapnel:Random, which the original
         * ships set, and it is the difference between a wall of fragments and
         * a cloud of them: an even ring has gaps a pilot can be standing in,
         * and the same eight pieces thrown at random do not.
         *
         * Zero used to mean every round left on the same heading, which is
         * not a thing any pattern wants, so the encoding was free. The roll
         * comes off the state's own generator, so it is as deterministic as
         * everything else here. */
        if (p->spacing == 0 && count > 1) {
            s->rng = xorshift32(s->rng);
            off = (int32_t)(s->rng >> 16);
        }
        uint16_t h = (uint16_t)((int32_t)heading + off);
        int32_t dx, dy;
        heading_dir(h, &dx, &dy);
        int32_t vx = vx0 + (int32_t)(((int64_t)spec->speed * dx) >> 15);
        int32_t vy = vy0 + (int32_t)(((int64_t)spec->speed * dy) >> 15);
        spawn_weapon(s, p->spec, owner, team, x, y, vx, vy, spec->life,
                     spec->bounces, depth, mods);
    }
    /* A fire event is a trigger being pulled, so shrapnel is not one: nobody
     * aimed it and its owner may well be dead. The client reads this event as
     * a muzzle, at the ship rather than at the weapon, because a shot leaves a
     * hull. So a fragment reported here put a gunshot and a muzzle flash on
     * the bomber every time one of their bombs went off, anywhere on the map.
     * Depth is the whole of the test: only a splinter has one. */
    if (depth == 0) emit(ev, SIM_EV_FIRE, owner, p->spec, 0);
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
    memset(sh->level, 0, sizeof sh->level);
    memset(sh->mods, 0, sizeof sh->mods);
    memset(sh->charge, 0, sizeof sh->charge);
    sh->earned = 0;
    sh->alive = 1;
    sh->respawn_at = 0;
    sh->x = sh->spawn_x;
    sh->y = sh->spawn_y;
    sh->vx = sh->vy = 0;
    sh->fire_cooldown = 0;
    /* Rerolled for the new hull rather than carried across: the roster row
     * changed, so the old items may not be things this hull can hold. */
    outfit(sh, cfg, &s->rng);
    sh->energy = sim_eff_max_energy(&cfg->classes[cls], sh);
    return 0;
}

int sim_set_ship_team(sim_state *s, const sim_settings *cfg, uint8_t i,
                      uint8_t team) {
    if (i >= s->ship_count) return -1;
    sim_ship *sh = &s->ships[i];
    if (!sh->active) return -1;
    /* The side you are already on is not a change. A pilot who picks their own
     * team out of a list should not be charged a respawn for reading it. */
    if (sh->team == team) return 0;
    /* The gate a hull change gets, for the reason a hull change gets it: this
     * hands out a fresh position and a full bar, so ungated it is a way out of
     * a fight that is going badly. */
    if (!sh->alive) return -1;
    if (sh->energy < sim_eff_max_energy(&cfg->classes[sh->cls], sh)) return -1;

    /* What you were carrying belongs to the side you are leaving. */
    drop_flags(s, cfg, i, 0);
    sh->team = team;
    /* Bounty earned by killing does not cross with you. Two pilots trading
     * sides to feed each other kills is the oldest arrangement in this genre,
     * and what a kill pays is the victim's bounty. */
    sh->earned = 0;

    /* And your start moves to the new side's. A map that marks no start for
     * this team hands out somebody else's, which `sim_map_spawn` already does
     * and is the whole reason a team the map has never heard of -- a private
     * one, formed in a room mid-round -- works at all. */
    uint16_t tx = 0, ty = 0;
    s->rng = xorshift32(s->rng);
    if (sim_map_spawn(cfg->map, team, s->rng >> 8, &tx, &ty)) {
        sh->spawn_x = (int32_t)tx * SIM_TILE_PX * 256;
        sh->spawn_y = (int32_t)ty * SIM_TILE_PX * 256;
    }
    sh->x = sh->spawn_x;
    sh->y = sh->spawn_y;
    sh->vx = sh->vy = 0;
    sh->fire_cooldown = 0;
    sh->energy = sim_eff_max_energy(&cfg->classes[sh->cls], sh);
    /* The hull and everything collected for it stay, which is where this parts
     * company with a hull change. That one rerolls because the roster row
     * moved and the old add-ons may not be things the new ship can hold;
     * crossing to another side changes nothing about what you are flying. */
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
            if (!hull_reaches(&cfg->classes[sh->cls], sh->heading,
                              sh->x, sh->y, f->x, f->y, cfg->flag_radius))
                continue;
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
/* Everything this hull could ever be given.
 *
 * Built per pickup rather than stored on the class, because it is a dozen
 * comparisons and a stored copy is a second version of the roster row that
 * can disagree with the first. A ladder with one rung is a weapon that never
 * levels, so a level is not something that hull can be handed.
 */
int sim_prize_pool(const sim_ship_class *c, uint8_t *out) {
    int n = 0;
    for (int u = 0; u < SIM_UP_COUNT; u++) out[n++] = (uint8_t)SIM_PRIZE_STAT(u);
    for (int t = 0; t < SIM_TRIG_COUNT; t++) {
        /* No trigger, nothing to hand out for it. An add-on is a transform on
         * a weapon and a level is a rung of one, so neither means anything
         * without the weapon -- and this has to be the code's rule rather
         * than the roster's. It used to be enforced by the table, by giving a
         * rackless hull an empty add-on field, which held only for as long as
         * every such hull remembered to. Every shipped hull carries a rack
         * now, so the table cannot say it at all. */
        if (c->trigger[t][0] == SIM_NO_PATTERN) continue;
        if (c->trigger[t][1] != SIM_NO_PATTERN)
            out[n++] = (uint8_t)SIM_PRIZE_LEVEL(t);
        for (int m = 0; m < SIM_MOD_COUNT; m++)
            if (sim_mod_get(c->mod_max[t], m) > 0)
                out[n++] = (uint8_t)SIM_PRIZE_MOD(t, m);
    }
    for (int k = 0; k < SIM_MAX_CHARGES; k++)
        if (c->charge_max[k] > 0) out[n++] = (uint8_t)SIM_PRIZE_CHARGE(k);
    return n;
}

/* Move one count by a step, within its ceiling and never below zero. */
static void move_count(sim_ship *sh, const sim_ship_class *c, uint8_t type,
                       int by) {
    if (type < SIM_UP_COUNT) {
        if (by < 0) { if (sh->up[type]) sh->up[type]--; }
        else if (sh->up[type] < SIM_UP_STEPS) sh->up[type]++;
        return;
    }
    type = (uint8_t)(type - SIM_UP_COUNT);
    if (type < SIM_TRIG_COUNT) {
        if (by < 0) {
            if (sh->level[type]) sh->level[type]--;
        } else {
            int next = sh->level[type] + 1;
            if (next < SIM_MAX_RUNGS && c->trigger[type][next] != SIM_NO_PATTERN)
                sh->level[type] = (uint8_t)next;
        }
        return;
    }
    type = (uint8_t)(type - SIM_TRIG_COUNT);
    if (type < SIM_TRIG_COUNT * SIM_MOD_COUNT) {
        int t = type / SIM_MOD_COUNT, m = type % SIM_MOD_COUNT;
        uint8_t have = sim_mod_get(sh->mods[t], m);
        if (by < 0) {
            if (have) sh->mods[t] = sim_mod_set(sh->mods[t], m, (uint8_t)(have - 1));
        } else if (have < sim_mod_get(c->mod_max[t], m)) {
            sh->mods[t] = sim_mod_set(sh->mods[t], m, (uint8_t)(have + 1));
        }
        return;
    }
    {
        int k = type - SIM_TRIG_COUNT * SIM_MOD_COUNT;
        if (by < 0) {
            if (sh->charge[k]) sh->charge[k]--;
        } else if (sh->charge[k] < c->charge_max[k]) {
            sh->charge[k]++;
        }
    }
}

/* How much of `type` this pilot is holding, which is what rust can take. */
static uint8_t held(const sim_ship *sh, uint8_t type) {
    if (type < SIM_UP_COUNT) return sh->up[type];
    type = (uint8_t)(type - SIM_UP_COUNT);
    if (type < SIM_TRIG_COUNT) return sh->level[type];
    type = (uint8_t)(type - SIM_TRIG_COUNT);
    if (type < SIM_TRIG_COUNT * SIM_MOD_COUNT)
        return sim_mod_get(sh->mods[type / SIM_MOD_COUNT], type % SIM_MOD_COUNT);
    return sh->charge[type - SIM_TRIG_COUNT * SIM_MOD_COUNT];
}

/* Rust: a green that takes something instead of giving it.
 *
 * It can only corrode what the pilot is actually holding, chosen evenly among
 * those, which is the whole of why it is not simply cruel. A pilot who has
 * just spawned holds nothing and cannot be rusted at all, so the punishment
 * lands on the loaded rather than on the arriving -- the same pressure bounty
 * applies, coming from a second direction. Returns 0 when there is nothing to
 * take, and the green goes back to being an ordinary one.
 */
static int rust_one(sim_ship *sh, const sim_ship_class *c, uint32_t *rng,
                    uint8_t *out) {
    uint8_t pool[SIM_PRIZE_COUNT], have[SIM_PRIZE_COUNT];
    int n = sim_prize_pool(c, pool), k = 0;
    for (int i = 0; i < n; i++)
        if (held(sh, pool[i])) have[k++] = pool[i];
    if (k == 0) return 0;
    *rng = xorshift32(*rng);
    *out = have[*rng % (uint32_t)k];
    move_count(sh, c, *out, -1);
    return 1;
}

uint8_t sim_take_prize(sim_ship *sh, const sim_settings *cfg, uint32_t *rng,
                       int *delta) {
    const sim_ship_class *c = &cfg->classes[sh->cls];
    if (delta) *delta = 1;

    if (cfg->rust_chance) {
        *rng = xorshift32(*rng);
        if (*rng % 1000u < cfg->rust_chance) {
            uint8_t got;
            if (rust_one(sh, c, rng, &got)) {
                if (delta) *delta = -1;
                return got;
            }
        }
    }

    uint8_t pool[SIM_PRIZE_COUNT];
    int n = sim_prize_pool(c, pool);
    if (n == 0) return SIM_PRIZE_NONE;
    /* Weighted over the hull's own pool, so a zone writes the shape of its
     * tree and the roster decides which parts of it this pilot can see. A
     * zone that zeroes everything gets an even roll rather than a division
     * by nothing. */
    uint32_t total = 0;
    for (int i = 0; i < n; i++) total += cfg->prize_weight[pool[i]];
    *rng = xorshift32(*rng);
    uint8_t type;
    if (total == 0) {
        type = pool[*rng % (uint32_t)n];
    } else {
        uint32_t r = *rng % total;
        int i = 0;
        for (; i < n - 1; i++) {
            uint32_t w = cfg->prize_weight[pool[i]];
            if (r < w) break;
            r -= w;
        }
        type = pool[i];
    }
    /* A green is worth one bounty whatever it turns out to be, including one
     * that turns out to be nothing. A pilot at every ceiling still gets more
     * dangerous by hoovering, which is the point: otherwise the pressure
     * bounty applies stops growing exactly when somebody is at their most
     * dominant, and the best player in the room becomes the safest. */
    uint8_t was = held(sh, type);
    move_count(sh, c, type, 1);
    if (held(sh, type) == was && sh->earned < 60000) sh->earned++;
    return type;
}

/* A green appears near somebody, not somewhere.
 *
 * Uniform placement over the whole map was right when the arena was one room.
 * The map is 1024 tiles across now and `prize_max` is twenty, which is one
 * green per fifty thousand tiles: a pilot who can see sixty tiles finds one
 * about never. Measured against the live arena, two greens inside the entire
 * 256-tile interest radius, and a player reported a zone with none in it at
 * all. Since `spawn_prizes` is zero on purpose -- greens are the only way into
 * the tech tree, and handing them out at spawn flattens the skill gap -- an
 * unfindable green is an unreachable tech tree.
 *
 * So the ring is around a live pilot: outside NEAR_LO so a green is a trip
 * rather than a gift, inside NEAR_HI so it lands on their radar, whose reach is
 * thirty tiles either way. Twenty greens where the people are beats twenty
 * greens in a million tiles of nobody, and it needs no extra state, no larger
 * snapshot, and no per-zone tuning.
 *
 * With nobody alive it falls back to the old uniform band, because a room
 * between rounds should still have greens on the map when the lights come up.
 */
static void spawn_prize(sim_state *s, const sim_settings *cfg) {
    if (cfg->prize_hi <= cfg->prize_lo) return;
    int slot = -1;
    for (int i = 0; i < SIM_MAX_PRIZES; i++)
        if (!s->prizes[i].active) { slot = i; break; }
    if (slot < 0) return;

    /* Whose neighbourhood. Chosen from the rng rather than by scanning from
     * zero, so greens do not all pile up around whoever holds the first seat. */
    int host = -1;
    if (s->ship_count > 0) {
        s->rng = xorshift32(s->rng);
        int start = (int)(s->rng % (uint32_t)s->ship_count);
        for (int k = 0; k < s->ship_count; k++) {
            int i = (start + k) % s->ship_count;
            if (s->ships[i].active && s->ships[i].alive) { host = i; break; }
        }
    }

    int32_t span = cfg->prize_hi - cfg->prize_lo;
    for (int attempt = 0; attempt < 24; attempt++) {
        int32_t tx, ty;
        if (host >= 0) {
            const int32_t R = SIM_PRIZE_NEAR_HI;
            s->rng = xorshift32(s->rng);
            int32_t ox = (int32_t)(s->rng % (uint32_t)(2 * R + 1)) - R;
            s->rng = xorshift32(s->rng);
            int32_t oy = (int32_t)(s->rng % (uint32_t)(2 * R + 1)) - R;
            if (ox * ox + oy * oy < SIM_PRIZE_NEAR_LO * SIM_PRIZE_NEAR_LO) continue;
            tx = s->ships[host].x / (SIM_TILE_PX * 256) + ox;
            ty = s->ships[host].y / (SIM_TILE_PX * 256) + oy;
            if (tx < cfg->prize_lo || tx > cfg->prize_hi) continue;
            if (ty < cfg->prize_lo || ty > cfg->prize_hi) continue;
        } else {
            s->rng = xorshift32(s->rng);
            tx = cfg->prize_lo + (int32_t)(s->rng % (uint32_t)span);
            s->rng = xorshift32(s->rng);
            ty = cfg->prize_lo + (int32_t)(s->rng % (uint32_t)span);
        }
        if (solid(cfg->map, cfg, s->tick, tx, ty)) continue;
        if (SIM_TILE_CLASS(sim_tile_at(cfg->map, tx, ty)) == SIM_TILE_SAFE)
            continue;
        sim_prize *p = &s->prizes[slot];
        p->active = 1;
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
            if (!hull_reaches(&cfg->classes[sh->cls], sh->heading,
                              sh->x, sh->y, p->x, p->y, cfg->prize_radius))
                continue;
            /* Every green is takeable by everybody; what it turns out to be
             * is rolled here, from what this hull could ever hold. A pilot
             * already at that ceiling is still told what they found -- the
             * count simply does not move. A green that refuses to be picked
             * up reads as a broken pickup, and one that is eaten in silence
             * is a green that lies. */
            int delta = 1;
            uint8_t got = sim_take_prize(sh, cfg, &s->rng, &delta);
            /* Collecting energy or recharge should feel immediate rather than
             * arriving over the next few seconds. Losing one is not the same
             * shape: the bar is clamped down to the new ceiling rather than
             * refilled to it. */
            if (got == SIM_UP_ENERGY || got == SIM_UP_RECHARGE) {
                int32_t cap = sim_eff_max_energy(&cfg->classes[sh->cls], sh);
                if (delta > 0 || sh->energy > cap) sh->energy = cap;
            }
            emit(ev, SIM_EV_PRIZE, (uint8_t)k, got, delta);
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
                outfit(sh, cfg, &next->rng);
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
        /* Multifire, declined or taken back, on the press. The add-on is
         * untouched: this only decides whether it is applied when the trigger
         * is pulled, so a pilot can hold a fan and still take a single
         * accurate shot. Edge-detected here rather than pulsed by the client,
         * because a pulse that arrives twice or not at all is a ship state
         * the two ends disagree about. */
        if ((b & SIM_BTN_MULTI) && !(sh->btn_prev & SIM_BTN_MULTI)) {
            sh->multi_off = (uint8_t)(sh->multi_off ? 0 : 1);
        }
        sh->btn_prev = b;

        /* 3a. A charge: a weapon carried by the count and spent. The slot
         * comes down in the buttons rather than living on the ship, so
         * choosing which one is ready is the client's business and costs the
         * simulation nothing -- no selection byte in a snapshot, and no edge
         * detection to get wrong when a shot is replayed. */
        if (!in_safe && sh->fire_cooldown == 0 && (b & SIM_BTN_USE)) {
            int k = (int)SIM_BTN_SLOT(b);
            uint8_t pat = cfg->charge[k];
            sim_fire_pattern cp;
            sim_weapon_spec cs;
            if (sh->charge[k] > 0 && resolve(cfg, pat, 0, 0, &cp, &cs)
                && sh->energy > cp.energy) {
                int32_t mx = sh->x + (int32_t)(((int64_t)(cls->fore + 512) * dx) >> 15);
                int32_t my = sh->y + (int32_t)(((int64_t)(cls->fore + 512) * dy) >> 15);
                /* A charge carries none of the pilot's add-ons. It is a thing
                 * you found whole, not a weapon you have been improving, and
                 * a repel that inherited shrapnel would be a surprise nobody
                 * asked for. */
                spawn_pattern(next, cfg, pat, (uint8_t)i, sh->team, mx, my,
                              sh->vx, sh->vy, sh->heading, 0, 0, 0, ev);
                sh->charge[k]--;
                sh->energy -= cp.energy;
                sh->fire_cooldown = cp.delay;
                sh->vx -= (int32_t)(((int64_t)cp.recoil * dx) >> 15);
                sh->vy -= (int32_t)(((int64_t)cp.recoil * dy) >> 15);
                emit(ev, SIM_EV_CHARGE, (uint8_t)i, (uint8_t)k, sh->charge[k]);
            }
        }

        if (!in_safe && sh->fire_cooldown == 0
            && (b & (SIM_BTN_FIRE | SIM_BTN_BOMB))) {
            int trig = ((b & SIM_BTN_FIRE) == 0) ? SIM_TRIG_BOMB : SIM_TRIG_GUN;
            uint8_t pat = trigger_pattern(cls, trig, sh->level[trig]);
            sim_fire_pattern fp;
            sim_weapon_spec fs;
            uint16_t use_mods = sh->mods[trig];
            if (sh->multi_off) {
                use_mods = sim_mod_set(use_mods, SIM_MOD_MULTI, 0);
            }
            if (resolve(cfg, pat, use_mods, sh->level[trig], &fp, &fs)) {
                /* The cost is the shot's, not each projectile's: a burst of
                 * sixteen costs what pulling the trigger costs, and so does
                 * multifire -- an add-on that made a shot cost per barrel
                 * would be an upgrade you could not afford to use. */
                if (sh->energy > fp.energy) {
                    /* Muzzle just outside the hull, so a shot never spawns
                     * inside its own ship. */
                    int32_t mx = sh->x + (int32_t)(((int64_t)(cls->fore + 512) * dx) >> 15);
                    int32_t my = sh->y + (int32_t)(((int64_t)(cls->fore + 512) * dy) >> 15);
                    spawn_pattern(next, cfg, pat, (uint8_t)i, sh->team, mx, my,
                                  sh->vx, sh->vy, sh->heading, 0,
                                  use_mods, sh->level[trig], ev);
                    sh->energy -= fp.energy;
                    sh->fire_cooldown = fp.delay;
                    sh->vx -= (int32_t)(((int64_t)fp.recoil * dx) >> 15);
                    sh->vy -= (int32_t)(((int64_t)fp.recoil * dy) >> 15);
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

        /* 4. Clamp to top speed. No drag term anywhere.
         *
         * A repel lifts the ceiling rather than holding a velocity: for
         * RepelTime the hull may fly at the repel's own speed, and when the
         * window shuts the clamp takes back whatever is left of it. That is
         * the whole mechanism -- the shove itself is one assignment, and this
         * is what stops the next tick undoing it, since a repel is
         * deliberately faster than any hull. A pilot can still steer and
         * thrust throughout; they simply cannot exceed the ceiling. */
        if (sh->repel > 0) sh->repel--;
        {
            int64_t mag2 = (int64_t)sh->vx * sh->vx + (int64_t)sh->vy * sh->vy;
            int64_t max = e_speed;
            if (sh->repel > 0 && sh->repel_speed > max) max = sh->repel_speed;
            if (mag2 > max * max) {
                int64_t mag = isqrt64(mag2);
                sh->vx = (int32_t)((int64_t)sh->vx * max / mag);
                sh->vy = (int32_t)((int64_t)sh->vy * max / mag);
            }
        }

        /* 4a. A wormhole taken at close range throws the ship somewhere else
         * on the map.
         *
         * The pull above is the whole of what a wormhole used to do, which
         * made it a hazard to steer around rather than a thing to steer
         * *for*: it dragged a pilot in and then let them coast out the far
         * side having gained nothing but a bad angle. Touching it now moves
         * you, which is what a wormhole is for.
         *
         * Contact is the tile, the same test the door below makes, so a
         * wormhole drawn six tiles across is entered by flying into the part
         * of it that is drawn rather than by passing over a point.
         *
         * The destination is any of the map's spawns rather than the pilot's
         * own team's, because a wormhole that only ever sent you home would
         * be a retreat button. Drawn from the state's own generator, so the
         * two ends of the wire agree about where a ship went. */
        if (sh->alive
            && SIM_TILE_CLASS(sim_tile_at(cfg->map, sh->x >> 12, sh->y >> 12))
                   == SIM_TILE_WORMHOLE) {
            uint16_t stx = 0, sty = 0;
            next->rng = xorshift32(next->rng);
            if (sim_map_spawn(cfg->map, sh->team, next->rng >> 8, &stx, &sty)) {
                sh->x = (int32_t)stx * SIM_TILE_PX * 256 + (SIM_TILE_PX * 128);
                sh->y = (int32_t)sty * SIM_TILE_PX * 256 + (SIM_TILE_PX * 128);
                /* Momentum does not survive the trip. Arriving at a spawn at
                 * four hundred pixels a second is arriving inside whatever is
                 * next to it. */
                sh->vx = 0;
                sh->vy = 0;
                emit(ev, SIM_EV_WARP, (uint8_t)i, 1, 0);
            }
        }

        /* 4b. A door that shuts on a ship warps it rather than swallowing it.
         * The alternative is a ship inside a wall, which the axis-by-axis
         * collision below cannot resolve: both axes are blocked, so it stays
         * stuck until something kills it. Warping keeps the door lethal to
         * position without being lethal to the pilot. */
        if (SIM_TILE_CLASS(sim_tile_at(cfg->map, sh->x >> 12, sh->y >> 12))
                == SIM_TILE_DOOR
            && box_hits(cfg->map, cfg, next->tick, sh->x, sh->y, 0, 0)) {
            sh->x = sh->spawn_x;
            sh->y = sh->spawn_y;
            sh->vx = 0;
            sh->vy = 0;
            emit(ev, SIM_EV_WARP, (uint8_t)i, 0, 0);
        }

        /* 5. Integrate and collide, one axis at a time so a wall kills only
         * the normal component and the ship slides along it.
         *
         * The box follows the heading: hull_box gives the world-axis bounds
         * of the hull as oriented this tick, and its centre sits `ox, oy`
         * from the ship because a hull is longer ahead of its pivot than
         * behind it. The clamps below are the old flush-to-tile arithmetic
         * with the reach on each side spelt out, since with an offset box
         * the reach to the right is no longer the reach to the left. */
        {
            const sim_map *m = cfg->map;
            int32_t ox, oy, hx, hy;
            hull_box(cls, sh->heading, &ox, &oy, &hx, &hy);

            /* 5a. Turning grows the box: a dart rotating beside a wall
             * sweeps its nose across it with nothing moving, which the
             * axis-by-axis clamp below can never resolve. So a rotation that
             * leaves the box overlapping gets the ship nudged out sideways,
             * a pixel or two at most since the box grows under a pixel per
             * tick. It reads as the nose levering the hull off the wall. If
             * no nudge frees it, the turn is taken back: a slot exactly your
             * width is a slot you cannot spin in, which is not a bug to a
             * pilot looking at a 40-pixel ship and a 40-pixel gap. */
            if ((b & (SIM_BTN_LEFT | SIM_BTN_RIGHT))
                && box_hits(m, cfg, next->tick, sh->x + ox, sh->y + oy,
                            hx, hy)) {
                int freed = 0;
                for (int32_t d = 256; d <= 1024 && !freed; d += 256) {
                    const int32_t nudge[4][2] = {
                        {-d, 0}, {d, 0}, {0, -d}, {0, d}};
                    for (int k = 0; k < 4; k++) {
                        if (!box_hits(m, cfg, next->tick,
                                      sh->x + nudge[k][0] + ox,
                                      sh->y + nudge[k][1] + oy, hx, hy)) {
                            sh->x += nudge[k][0];
                            sh->y += nudge[k][1];
                            freed = 1;
                            break;
                        }
                    }
                }
                if (!freed) {
                    sh->heading = prev->ships[i].heading;
                    hull_box(cls, sh->heading, &ox, &oy, &hx, &hy);
                }
            }

            int32_t east = ox + hx, west = hx - ox;   /* reach each way */
            int32_t south = oy + hy, north = hy - oy;

            int32_t nx = sh->x + sh->vx / 256;
            if (box_hits(m, cfg, next->tick, nx + ox, sh->y + oy, hx, hy)) {
                if (sh->vx > 0)
                    nx = ((((sh->x + east) >> 12) + 1) << 12) - east - 1;
                else if (sh->vx < 0)
                    nx = (((sh->x - west) >> 12) << 12) + west;
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
            if (box_hits(m, cfg, next->tick, sh->x + ox, ny + oy, hx, hy)) {
                if (sh->vy > 0)
                    ny = ((((sh->y + south) >> 12) + 1) << 12) - south - 1;
                else if (sh->vy < 0)
                    ny = (((sh->y - north) >> 12) << 12) + north;
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

        /* 6. Recharge, after firing, so a shot costs a full tick of energy --
         * unless something stalled it, in which case the bar simply sits
         * where it is until the stall runs out.
         *
         * The addition is guarded and done wide. Adding first and clamping
         * afterwards overflows for any ship already above the cap, and signed
         * overflow is undefined behaviour: the wrapped result was a huge
         * negative bar, which the clamp then let through because it only ever
         * looked for too much. A spawning ship really did arrive at INT32_MAX
         * -- the server set that, meaning "full" -- and left the tick at
         * INT32_MIN, one hit from dead.
         *
         * Worth more than the symptom: this core's whole contract is that every
         * platform steps it identically, and undefined behaviour is exactly the
         * thing a compiler is free to render differently. No input may reach it. */
        int32_t cap = sim_eff_max_energy(cls, sh);
        if (sh->stall > 0) {
            sh->stall--;
        } else if (sh->energy < cap) {
            int64_t charged = (int64_t)sh->energy + sim_eff_recharge(cls, sh);
            sh->energy = charged > cap ? cap : (int32_t)charged;
        }
        if (sh->energy > cap) sh->energy = cap;
    }

    update_prizes(next, cfg, ev);
    update_flags(next, cfg, ev);

    /* --- weapons ---
     *
     * Four phases, in order: it runs out, it moves, something ends it, and
     * the ending happens. Every difference between a bullet, a bomb, a mine
     * and a fragment is a number in its spec rather than a branch here.
     */
    /* What a projectile is depends only on the spec it was fired from and the
     * add-ons that were on the trigger, so resolving it is the same answer for
     * every round of the same shot. It used to be a struct copy and a pass of
     * `compose` per weapon per tick, which at four hundred rounds in the air is
     * forty thousand of each a second for a handful of distinct answers.
     *
     * One entry is enough because the rounds that share an answer are adjacent
     * in the array: a burst of sixteen and a multifire of three are spawned
     * together, so they sit together. `weapon_end` takes its spec const, and
     * nothing else writes through the pointer, so handing out the cached one
     * is the same value by a different address. */
    uint32_t cached_key = 0xffffffffu;
    sim_weapon_spec cached;
    memset(&cached, 0, sizeof cached);

    /* Where every ship is, which way it points, and how far it reaches, in
     * one compact array.
     *
     * The test below runs once per projectile per ship -- four hundred rounds
     * against forty hulls is sixteen thousand a tick -- and each iteration was
     * striding a 72-byte ship to read two coordinates and then chasing the
     * class's extents in a different structure again. Pulling everything into
     * 64 x 24 bytes puts the whole scan in L1, and resolving the heading to a
     * unit vector once per ship here keeps the table lookup out of the inner
     * loop entirely.
     *
     * Position, class, team and heading do not move during this loop: ships
     * were stepped before it and an ending only changes energy and velocity.
     * `alive` is deliberately *not* cached -- a weapon that kills a ship early
     * in the loop must leave later weapons seeing a dead one, and freezing
     * that flag would let a corpse be shot twice. */
    struct { int32_t x, y, fx, fy, fore, aft, halfw; } hull[SIM_MAX_SHIPS];
    for (int i = 0; i < next->ship_count; i++) {
        const sim_ship_class *hc = &cfg->classes[next->ships[i].cls];
        hull[i].x = next->ships[i].x;
        hull[i].y = next->ships[i].y;
        heading_dir(next->ships[i].heading, &hull[i].fx, &hull[i].fy);
        hull[i].fore = hc->fore;
        hull[i].aft = hc->aft;
        hull[i].halfw = hc->halfw;
    }

    for (uint16_t wi = 0; wi < next->weapon_count;) {
        sim_weapon *w = &next->weapons[wi];
        /* The add-ons ride on the shot rather than on its owner: a bomb thrown
         * while you had shrapnel still breaks up, whatever you are carrying by
         * the time it lands. */
        uint32_t key = ((uint32_t)w->spec << 16) | w->mods;
        if (key != cached_key) {
            cached = cfg->specs[w->spec];
            compose(cfg, w->mods, 0, &cached, NULL);
            cached_key = key;
        }
        const sim_weapon_spec *spec = &cached;
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

        /* 2. Walls: stop here, bounce off, or ignore them entirely.
         *
         * A bounce reflects the axis that hit, tested one axis at a time so
         * a corner turns a projectile around rather than letting it through
         * -- the same treatment a ship gets, and for the same reason. */
        int32_t px = w->x - w->vx / 256, py = w->y - w->vy / 256;
        if (spec->on_wall != SIM_WALL_PASS
            && box_hits(cfg->map, cfg, next->tick, w->x, w->y, 0, 0)) {
            if (spec->on_wall == SIM_WALL_BOUNCE && w->left > 0) {
                w->left--;
                if (box_hits(cfg->map, cfg, next->tick, w->x, py, 0, 0)) {
                    w->vx = -w->vx;
                    w->x = px;
                }
                if (box_hits(cfg->map, cfg, next->tick, px, w->y, 0, 0)) {
                    w->vy = -w->vy;
                    w->y = py;
                }
                emit(ev, SIM_EV_RICOCHET, w->owner, w->spec,
                     pack_pos(w->x, w->y));
            } else {
                /* End on the near side of the wall rather than a step inside
                 * it. A blast centred in the tile spends half its reach on
                 * the far side where nobody is, and shrapnel spawned in there
                 * dies on its own first tick. */
                w->x = px;
                w->y = py;
                ended = 1;
            }
        }

        /* 3. Ships. A weapon never arrives at its owner or a teammate, and
         * `trigger` is how close counts: zero is contact with the hull, which
         * is a bullet, and anything larger is a proximity fuse. */
        if (!ended) {
            for (int i = 0; i < next->ship_count && !ended; i++) {
                const sim_ship *sh = &next->ships[i];
                if (!sh->active || !sh->alive) continue;
                if ((uint8_t)i == w->owner || sh->team == w->team) continue;
                /* The hull's own rectangle, not a circle drawn around it: a
                 * round into a Cipher's flank has to reach the knife. The
                 * weapon's trigger distance pads every face, so a proximity
                 * fuse still goes off near rather than on. */
                int64_t ddx = (int64_t)w->x - hull[i].x;
                int64_t ddy = (int64_t)w->y - hull[i].y;
                int64_t along = (ddx * hull[i].fx + ddy * hull[i].fy) >> 15;
                int64_t across = (ddy * hull[i].fx - ddx * hull[i].fy) >> 15;
                if (across < 0) across = -across;
                if (along >= -((int64_t)hull[i].aft + spec->trigger)
                    && along <= (int64_t)hull[i].fore + spec->trigger
                    && across <= (int64_t)hull[i].halfw + spec->trigger) {
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
        h = hash_u32(h, sh->stall);
        h = hash_u32(h, (uint32_t)(sh->kills | (sh->deaths << 16)));
        for (int u = 0; u < SIM_UP_COUNT; u++) h = hash_u32(h, sh->up[u]);
        for (int t = 0; t < SIM_TRIG_COUNT; t++)
            h = hash_u32(h, (uint32_t)(sh->level[t] | (sh->mods[t] << 8)));
        for (int k = 0; k < SIM_MAX_CHARGES; k++) h = hash_u32(h, sh->charge[k]);
        /* What the next shot will be, and what the last press was. Both are
         * state: the second decides whether the next tick sees an edge, and a
         * client that guessed at it would toggle when the server did not. */
        h = hash_u32(h, sh->multi_off);
        h = hash_u32(h, sh->btn_prev);
        h = hash_u32(h, sh->earned);
        h = hash_u32(h, sh->points);
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
        h = hash_u32(h, (uint32_t)(i | (p->active << 16)));
        h = hash_u32(h, (uint32_t)p->x);
        h = hash_u32(h, (uint32_t)p->y);
        h = hash_u32(h, p->life);
    }
    for (uint16_t i = 0; i < s->weapon_count; i++) {
        const sim_weapon *w = &s->weapons[i];
        h = hash_u32(h, (uint32_t)(w->spec | (w->owner << 8) | (w->team << 16)));
        h = hash_u32(h, (uint32_t)(w->left | (w->depth << 8) | (w->mods << 16)));
        h = hash_u32(h, (uint32_t)w->x);
        h = hash_u32(h, (uint32_t)w->y);
        h = hash_u32(h, (uint32_t)w->vx);
        h = hash_u32(h, (uint32_t)w->vy);
        h = hash_u32(h, w->life);
    }
    return h;
}
