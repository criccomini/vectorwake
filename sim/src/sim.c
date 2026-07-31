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

/* Integer square root of a non-negative 64-bit value. */
static int64_t isqrt64(int64_t v) {
    int64_t lo = 0, hi = 3037000499LL; /* floor(sqrt(2^63 - 1)) */
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
    return x ? x : 0x9e3779b9u; /* never park at zero */
}

/* ---- settings conversion ---- */

int32_t sim_vie_speed(int32_t v) {
    /* v px/s/10 -> px/tick = v/1000 -> Q16 */
    return (int32_t)(((int64_t)v << 16) / 1000);
}

int32_t sim_vie_thrust(int32_t t) {
    /* accel t*10 px/s^2 -> px/tick^2 = t/1000 -> Q16 */
    return (int32_t)(((int64_t)t << 16) / 1000);
}

int32_t sim_vie_rotation(int32_t r) {
    /* r/400 turns/s -> heading units/tick = r*65536/40000 */
    return (int32_t)(((int64_t)r << 16) / 40000);
}

/* ---- state management ---- */

void sim_init(sim_state *s, uint32_t seed) {
    memset(s, 0, sizeof *s);
    s->rng = seed ? seed : 1u;
}

int sim_spawn(sim_state *s, int32_t x_px, int32_t y_px, uint16_t heading) {
    if (s->ship_count >= SIM_MAX_SHIPS) return -1;
    int i = s->ship_count++;
    sim_ship *sh = &s->ships[i];
    sh->active = 1;
    sh->x = x_px * 256;
    sh->y = y_px * 256;
    sh->vx = 0;
    sh->vy = 0;
    sh->heading = heading;
    return i;
}

/* ---- collision ---- */

static int solid(const sim_map *m, int32_t tx, int32_t ty) {
    if (tx < 0 || ty < 0 || tx >= SIM_MAP_TILES || ty >= SIM_MAP_TILES)
        return 1; /* out of bounds is wall */
    return m->solid[(size_t)ty * SIM_MAP_TILES + (size_t)tx] != 0;
}

/* Does the ship box centered at (x, y) with radius r overlap a solid tile?
 * Coordinates are Q8; tile index is q8 >> 12 (256 subpixels * 16 px). */
static int box_hits(const sim_map *m, int32_t x, int32_t y, int32_t r) {
    int32_t tx0 = (x - r) >> 12, tx1 = (x + r) >> 12;
    int32_t ty0 = (y - r) >> 12, ty1 = (y + r) >> 12;
    for (int32_t ty = ty0; ty <= ty1; ty++)
        for (int32_t tx = tx0; tx <= tx1; tx++)
            if (solid(m, tx, ty)) return 1;
    return 0;
}

/* ---- the step ---- */

void sim_step(sim_state *next, const sim_state *prev, const sim_input *inputs,
              uint16_t input_count, const sim_settings *cfg, sim_events *ev) {
    const sim_ship_class *cls = &cfg->ship;
    memcpy(next, prev, sizeof *next);
    next->tick = prev->tick + 1;
    next->rng = xorshift32(prev->rng);
    if (ev) ev->bounces = 0;

    /* Gather this tick's buttons per ship. */
    uint16_t buttons[SIM_MAX_SHIPS] = {0};
    for (uint16_t i = 0; i < input_count; i++)
        if (inputs[i].ship < SIM_MAX_SHIPS) buttons[inputs[i].ship] = inputs[i].buttons;

    for (int i = 0; i < next->ship_count; i++) {
        sim_ship *sh = &next->ships[i];
        if (!sh->active) continue;
        uint16_t b = buttons[i];

        /* 1. Rotate. u16 wraps by definition. */
        if (b & SIM_BTN_LEFT) sh->heading = (uint16_t)(sh->heading - cls->rot);
        if (b & SIM_BTN_RIGHT) sh->heading = (uint16_t)(sh->heading + cls->rot);

        /* 2. Thrust along (or against) the nose. There is no other way to
         * change your own velocity; that is the game. */
        if (b & (SIM_BTN_THRUST | SIM_BTN_REVERSE)) {
            int32_t dx, dy;
            heading_dir(sh->heading, &dx, &dy);
            int32_t sign = (b & SIM_BTN_THRUST) ? 1 : -1;
            sh->vx += (int32_t)(((int64_t)cls->thrust * dx * sign) >> 15);
            sh->vy += (int32_t)(((int64_t)cls->thrust * dy * sign) >> 15);
        }

        /* 3. Clamp to the class top speed. No drag: velocity persists
         * untouched below the cap, forever. */
        {
            int64_t mag2 = (int64_t)sh->vx * sh->vx + (int64_t)sh->vy * sh->vy;
            int64_t max = cls->max_speed;
            if (mag2 > max * max) {
                int64_t mag = isqrt64(mag2);
                sh->vx = (int32_t)((int64_t)sh->vx * max / mag);
                sh->vy = (int32_t)((int64_t)sh->vy * max / mag);
            }
        }

        /* 4. Integrate and collide, one axis at a time so hitting a wall
         * kills only the normal component and the ship slides. Q16 velocity
         * to Q8 position: divide by 256, truncating toward zero. Per-tick
         * displacement is far below one tile at any legal speed, so a
         * single box test per axis cannot tunnel. */
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
                if (ev) ev->bounces++;
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
                if (ev) ev->bounces++;
            }
            sh->y = ny;
        }
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

/* Serialize field by field in little-endian order so struct padding and host
 * endianness cannot leak into the hash. */
static uint64_t hash_u32(uint64_t h, uint32_t v) {
    uint8_t b[4] = {(uint8_t)v, (uint8_t)(v >> 8), (uint8_t)(v >> 16),
                    (uint8_t)(v >> 24)};
    return fnv1a(h, b, 4);
}

uint64_t sim_hash(const sim_state *s) {
    uint64_t h = 0xcbf29ce484222325ULL;
    h = hash_u32(h, s->tick);
    h = hash_u32(h, s->rng);
    h = hash_u32(h, s->ship_count);
    for (int i = 0; i < s->ship_count; i++) {
        const sim_ship *sh = &s->ships[i];
        h = hash_u32(h, sh->active);
        h = hash_u32(h, (uint32_t)sh->x);
        h = hash_u32(h, (uint32_t)sh->y);
        h = hash_u32(h, (uint32_t)sh->vx);
        h = hash_u32(h, (uint32_t)sh->vy);
        h = hash_u32(h, sh->heading);
    }
    return h;
}
