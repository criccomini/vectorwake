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

    /* Weapon defaults in the same units; zones override every one. */
    c->bullet_speed = sim_units_speed(2000);
    c->bullet_energy = sim_units_energy(330);
    c->bullet_delay = 25;
    c->bullet_life = 200;
    c->bullet_damage = sim_units_energy(200);

    c->bomb_speed = sim_units_speed(1500);
    c->bomb_energy = sim_units_energy(600);
    c->bomb_delay = 100;
    c->bomb_life = 500;
    c->bomb_damage = sim_units_energy(500);
    c->bomb_radius = 48 * 256;
    c->bomb_thrust = sim_units_speed(200);
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
    sh->energy = cfg->classes[sh->cls].max_energy;
    return i;
}

/* ---- collision ---- */

static int solid(const sim_map *m, int32_t tx, int32_t ty) {
    if (tx < 0 || ty < 0 || tx >= SIM_MAP_TILES || ty >= SIM_MAP_TILES) return 1;
    return m->solid[(size_t)ty * SIM_MAP_TILES + (size_t)tx] != 0;
}

static int box_hits(const sim_map *m, int32_t x, int32_t y, int32_t r) {
    int32_t tx0 = (x - r) >> 12, tx1 = (x + r) >> 12;
    int32_t ty0 = (y - r) >> 12, ty1 = (y + r) >> 12;
    for (int32_t ty = ty0; ty <= ty1; ty++)
        for (int32_t tx = tx0; tx <= tx1; tx++)
            if (solid(m, tx, ty)) return 1;
    return 0;
}

/* ---- weapons ---- */

static void spawn_weapon(sim_state *s, uint8_t type, uint8_t owner,
                         uint8_t team, int32_t x, int32_t y, int32_t vx,
                         int32_t vy, uint16_t life) {
    if (s->weapon_count >= SIM_MAX_WEAPONS) return; /* silently dropped */
    sim_weapon *w = &s->weapons[s->weapon_count++];
    w->type = type;
    w->owner = owner;
    w->team = team;
    w->x = x;
    w->y = y;
    w->vx = vx;
    w->vy = vy;
    w->life = life;
}

/* Remove a weapon by swapping the last one into its slot. Order is
 * deterministic because it depends only on state, never on time. */
static void kill_weapon(sim_state *s, uint16_t i) {
    s->weapons[i] = s->weapons[--s->weapon_count];
}

static void apply_damage(sim_state *s, const sim_settings *cfg, uint8_t victim,
                         uint8_t attacker, int32_t amount, sim_events *ev) {
    sim_ship *v = &s->ships[victim];
    if (!v->active || !v->alive) return;
    v->energy -= amount;
    emit(ev, SIM_EV_HIT, victim, attacker, amount);
    if (v->energy <= 0) {
        v->energy = 0;
        v->alive = 0;
        v->deaths++;
        v->respawn_at = cfg->respawn_delay;
        v->vx = v->vy = 0;
        if (attacker != 255 && attacker != victim) s->ships[attacker].kills++;
        emit(ev, SIM_EV_DEATH, victim, attacker, 0);
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
                sh->energy = cls->max_energy;
                sh->fire_cooldown = 0;
                emit(ev, SIM_EV_SPAWN, (uint8_t)i, 0, 0);
            }
            continue;
        }

        uint16_t b = buttons[i];
        if (sh->fire_cooldown > 0) sh->fire_cooldown--;

        /* 1. Rotate. */
        if (b & SIM_BTN_LEFT) sh->heading = (uint16_t)(sh->heading - cls->rot);
        if (b & SIM_BTN_RIGHT) sh->heading = (uint16_t)(sh->heading + cls->rot);

        int32_t dx, dy;
        heading_dir(sh->heading, &dx, &dy);

        /* 2. Thrust along the nose. */
        if (b & (SIM_BTN_THRUST | SIM_BTN_REVERSE)) {
            int32_t sign = (b & SIM_BTN_THRUST) ? 1 : -1;
            sh->vx += (int32_t)(((int64_t)cls->thrust * dx * sign) >> 15);
            sh->vy += (int32_t)(((int64_t)cls->thrust * dy * sign) >> 15);
        }

        /* 3. Fire. Guns take precedence over bombs when both are held, and
         * one cooldown covers both, so a ship cannot alternate to cheat it. */
        if (sh->fire_cooldown == 0 && (b & (SIM_BTN_FIRE | SIM_BTN_BOMB))) {
            int bomb = (b & SIM_BTN_FIRE) == 0;
            int32_t cost = bomb ? cls->bomb_energy : cls->bullet_energy;
            if (sh->energy > cost) {
                int32_t sp = bomb ? cls->bomb_speed : cls->bullet_speed;
                int32_t vx = sh->vx + (int32_t)(((int64_t)sp * dx) >> 15);
                int32_t vy = sh->vy + (int32_t)(((int64_t)sp * dy) >> 15);
                /* Muzzle just outside the hull so a shot never spawns
                 * inside its own ship. */
                int32_t mx = sh->x + (int32_t)(((int64_t)(cls->radius + 512) * dx) >> 15);
                int32_t my = sh->y + (int32_t)(((int64_t)(cls->radius + 512) * dy) >> 15);
                spawn_weapon(next, bomb ? SIM_W_BOMB : SIM_W_BULLET, (uint8_t)i,
                             sh->team, mx, my, vx, vy,
                             bomb ? cls->bomb_life : cls->bullet_life);
                sh->energy -= cost;
                sh->fire_cooldown = bomb ? cls->bomb_delay : cls->bullet_delay;
                if (bomb) { /* recoil */
                    sh->vx -= (int32_t)(((int64_t)cls->bomb_thrust * dx) >> 15);
                    sh->vy -= (int32_t)(((int64_t)cls->bomb_thrust * dy) >> 15);
                }
                emit(ev, SIM_EV_FIRE, (uint8_t)i, bomb ? SIM_W_BOMB : SIM_W_BULLET, 0);
            }
        }

        /* 4. Clamp to top speed. No drag term anywhere. */
        {
            int64_t mag2 = (int64_t)sh->vx * sh->vx + (int64_t)sh->vy * sh->vy;
            int64_t max = cls->max_speed;
            if (mag2 > max * max) {
                int64_t mag = isqrt64(mag2);
                sh->vx = (int32_t)((int64_t)sh->vx * max / mag);
                sh->vy = (int32_t)((int64_t)sh->vy * max / mag);
            }
        }

        /* 5. Integrate and collide, one axis at a time so a wall kills only
         * the normal component and the ship slides along it. */
        {
            const sim_map *m = cfg->map;
            int32_t r = cls->radius;

            int32_t nx = sh->x + sh->vx / 256;
            if (box_hits(m, nx, sh->y, r)) {
                if (sh->vx > 0)
                    nx = ((((sh->x + r) >> 12) + 1) << 12) - r - 1;
                else if (sh->vx < 0)
                    nx = (((sh->x - r) >> 12) << 12) + r;
                else
                    nx = sh->x;
                sh->vx = (int32_t)(-(int64_t)sh->vx * cfg->bounce / 16);
                emit(ev, SIM_EV_BOUNCE, (uint8_t)i, 0, 0);
            }
            sh->x = nx;

            int32_t ny = sh->y + sh->vy / 256;
            if (box_hits(m, sh->x, ny, r)) {
                if (sh->vy > 0)
                    ny = ((((sh->y + r) >> 12) + 1) << 12) - r - 1;
                else if (sh->vy < 0)
                    ny = (((sh->y - r) >> 12) << 12) + r;
                else
                    ny = sh->y;
                sh->vy = (int32_t)(-(int64_t)sh->vy * cfg->bounce / 16);
                emit(ev, SIM_EV_BOUNCE, (uint8_t)i, 0, 0);
            }
            sh->y = ny;
        }

        /* 6. Recharge, after firing, so a shot costs a full tick of energy. */
        sh->energy += cls->recharge;
        if (sh->energy > cls->max_energy) sh->energy = cls->max_energy;
    }

    /* --- weapons --- */
    for (uint16_t wi = 0; wi < next->weapon_count;) {
        sim_weapon *w = &next->weapons[wi];
        const sim_ship_class *ocls = &cfg->classes[next->ships[w->owner].cls];
        int removed = 0;

        if (w->life == 0) {
            emit(ev, SIM_EV_EXPIRE, w->type, 0, 0);
            kill_weapon(next, wi);
            continue;
        }
        w->life--;
        w->x += w->vx / 256;
        w->y += w->vy / 256;

        /* Walls. Bullets die on contact; bombs detonate. */
        if (box_hits(cfg->map, w->x, w->y, 0)) {
            if (w->type == SIM_W_BOMB) {
                for (int i = 0; i < next->ship_count; i++) {
                    sim_ship *sh = &next->ships[i];
                    if (!sh->active || !sh->alive) continue;
                    int64_t ddx = (int64_t)sh->x - w->x, ddy = (int64_t)sh->y - w->y;
                    int64_t d2 = ddx * ddx + ddy * ddy;
                    int64_t rad = ocls->bomb_radius;
                    if (d2 <= rad * rad) {
                        /* Linear falloff from center to edge. */
                        int64_t d = isqrt64(d2);
                        int32_t dmg =
                            (int32_t)((int64_t)ocls->bomb_damage * (rad - d) / rad);
                        if (dmg > 0) apply_damage(next, cfg, (uint8_t)i, w->owner, dmg, ev);
                    }
                }
            }
            kill_weapon(next, wi);
            removed = 1;
        }

        /* Ships. A weapon never hits its owner or a teammate. */
        if (!removed) {
            for (int i = 0; i < next->ship_count && !removed; i++) {
                sim_ship *sh = &next->ships[i];
                if (!sh->active || !sh->alive) continue;
                if ((uint8_t)i == w->owner || sh->team == w->team) continue;
                const sim_ship_class *vcls = &cfg->classes[sh->cls];
                int64_t ddx = (int64_t)sh->x - w->x, ddy = (int64_t)sh->y - w->y;
                int64_t d2 = ddx * ddx + ddy * ddy;
                int64_t r = vcls->radius;
                if (d2 <= r * r) {
                    int32_t dmg = (w->type == SIM_W_BOMB) ? ocls->bomb_damage
                                                          : ocls->bullet_damage;
                    apply_damage(next, cfg, (uint8_t)i, w->owner, dmg, ev);
                    kill_weapon(next, wi);
                    removed = 1;
                }
            }
        }

        if (!removed) wi++;
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
    }
    for (uint16_t i = 0; i < s->weapon_count; i++) {
        const sim_weapon *w = &s->weapons[i];
        h = hash_u32(h, (uint32_t)(w->type | (w->owner << 8) | (w->team << 16)));
        h = hash_u32(h, (uint32_t)w->x);
        h = hash_u32(h, (uint32_t)w->y);
        h = hash_u32(h, (uint32_t)w->vx);
        h = hash_u32(h, (uint32_t)w->vy);
        h = hash_u32(h, w->life);
    }
    return h;
}
