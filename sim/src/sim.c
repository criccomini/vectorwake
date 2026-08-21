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

/* SVS's non-exact bullet damage, with a roll local to this impact.
 *
 * Using the arena generator here would make an off-screen hit advance the
 * server's RNG without advancing a filtered client's. The next nearby hit
 * would then predict a different amount. The impact already has enough
 * deterministic entropy to make the same curve without coupling fights that
 * cannot see each other. */
static int32_t random_bullet_damage(const sim_state *s, const sim_weapon *w,
                                    int32_t ceiling) {
    uint32_t maximum = (uint32_t)(ceiling / 1024);
    uint64_t span = (uint64_t)maximum * maximum + 1;
    uint32_t roll = s->tick ^ (uint32_t)w->x ^ ((uint32_t)w->y << 7)
                    ^ ((uint32_t)w->vx << 13) ^ ((uint32_t)w->vy << 19)
                    ^ ((uint32_t)w->life << 16) ^ w->link
                    ^ ((uint32_t)w->owner << 24) ^ ((uint32_t)w->spec << 28);
    roll = xorshift32(roll);
    uint64_t square = ((uint64_t)roll * 1000u) % span;
    return (int32_t)(isqrt64((int64_t)square) * 1024);
}

/* A whole-pixel position squeezed into an event's one payload word, with the
 * round's rung in two of the bits left over. The map is 16384 px on a side,
 * so fourteen bits hold a coordinate exactly and the pair fits with four to
 * spare; the rung takes two of those. Used by SIM_EV_EXPIRE, which is the
 * only report a caller gets of where a weapon stopped existing.
 *
 * The rung is there for the renderer, and for the same reason the round
 * itself carries `level`: a spec is composed again where a round lands, and
 * the rung it came off is not otherwise recoverable there. By the time the
 * client reads this event the weapon is gone from the state, so without
 * these bits a mine's detonation -- one spec whatever rung was posted -- had
 * no rung to size its ring or pick its color by, and flashed rung one in
 * violet whatever the mine had been. */
static int32_t pack_pos(int32_t x_q8, int32_t y_q8, uint8_t level) {
    int32_t x = (x_q8 >> 8) & 0x3fff;
    int32_t y = (y_q8 >> 8) & 0x3fff;
    return ((int32_t)(level & 3) << 28) | (x << 14) | y;
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

static void note_predicted_death(sim_events *ev, uint8_t victim) {
    if (!ev) return;
    for (uint16_t i = 0; i < ev->predicted_death_count; i++)
        if (ev->predicted_death[i] == victim) return;
    if (ev->predicted_death_count < SIM_MAX_SHIPS)
        ev->predicted_death[ev->predicted_death_count++] = victim;
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
int sim_kit_ceilings(const sim_ship_class *c, uint8_t *out) {
    int n = 0;
    memset(out, 0, SIM_SLOT_COUNT);
    for (int u = 0; u < SIM_UP_COUNT; u++) {
        out[SIM_SLOT_STAT(u)] = SIM_UP_STEPS;
        n++;
    }
    for (int t = 0; t < SIM_TRIG_COUNT; t++) {
        /* No trigger, nothing to spend on it. An add-on is a transform on a
         * weapon and a level is a rung of one, so neither means anything
         * without the weapon, and this has to be the code's rule rather than
         * the roster's: enforcing it in the table held only for as long as
         * every rackless hull remembered to zero its own add-on field. */
        if (c->trigger[t][0] == SIM_NO_PATTERN) continue;
        int rungs = 0;
        while (rungs + 1 < SIM_MAX_RUNGS &&
               c->trigger[t][rungs + 1] != SIM_NO_PATTERN) rungs++;
        if (rungs > 0) { out[SIM_SLOT_LEVEL(t)] = (uint8_t)rungs; n++; }
        for (int m = 0; m < SIM_MOD_COUNT; m++) {
            uint8_t mx = sim_mod_get(c->mod_max[t], m);
            if (mx > 0) { out[SIM_SLOT_MOD(t, m)] = mx; n++; }
        }
    }
    for (int k = 0; k < SIM_MAX_CHARGES; k++)
        if (c->charge_max[k] > 0) {
            out[SIM_SLOT_CHARGE(k)] = c->charge_max[k];
            n++;
        }
    return n;
}

int sim_kit_cost(const uint8_t *kit) {
    int n = 0;
    for (int i = 0; i < SIM_SLOT_COUNT; i++) n += kit[i];
    return n;
}

void sim_deal_kit(sim_ship *sh, const sim_settings *cfg, int ammunition) {
    memset(sh->up, 0, sizeof sh->up);
    memset(sh->level, 0, sizeof sh->level);
    memset(sh->mods, 0, sizeof sh->mods);
    if (ammunition) memset(sh->charge, 0, sizeof sh->charge);
    for (int i = 0; i < SIM_SLOT_COUNT; i++) {
        if (i >= SIM_SLOT_CHARGE(0) && !ammunition) continue;
        for (int k = 0; k < sh->kit[i]; k++) sim_grant(sh, cfg, (uint8_t)i);
    }
}

int sim_set_kit(sim_ship *sh, const sim_settings *cfg, const uint8_t *kit) {
    uint8_t ceiling[SIM_SLOT_COUNT];
    sim_kit_ceilings(&cfg->classes[sh->cls], ceiling);
    int cost = 0;
    for (int i = 0; i < SIM_SLOT_COUNT; i++) {
        if (kit[i] > ceiling[i]) return 0;
        cost += kit[i];
    }
    if (cost > SIM_KIT_BUDGET) return 0;
    memcpy(sh->kit, kit, SIM_SLOT_COUNT);
    sim_deal_kit(sh, cfg, 1);
    return 1;
}

uint32_t sim_offsetof_settings_max_ships(void) {
    return (uint32_t)offsetof(sim_settings, max_ships);
}

uint32_t sim_sizeof_state(void) { return (uint32_t)sizeof(sim_state); }
uint32_t sim_sizeof_settings(void) { return (uint32_t)sizeof(sim_settings); }
uint32_t sim_sizeof_ship(void) { return (uint32_t)sizeof(sim_ship); }
uint32_t sim_sizeof_events(void) { return (uint32_t)sizeof(sim_events); }

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

/* Whether a tile is ground: somewhere a thing may be left lying and still be
 * there, and reachable, later.
 *
 * The door is the whole reason this is not `solid`. `solid` answers about a
 * tick, which is the right question for something moving through and the
 * wrong one for something staying put: a green sown through an open door is
 * inside a wall for the third of every cycle the door is shut, unreachable
 * while it is, and drawn embedded in it. Measured on alpha, about one green
 * every ten minutes spent two seconds at a time in a shut door.
 *
 * A hull's own center is never inside a wall, so the door is the whole of what
 * this catches today. It is written against the tile rather than against the
 * door because the property wanted is "the map will not close over this". */
static int ground(const sim_map *m, int32_t tx, int32_t ty) {
    switch (SIM_TILE_CLASS(sim_tile_at(m, tx, ty))) {
        case SIM_TILE_SOLID:
        case SIM_TILE_DOOR: return 0;
        default: return 1;
    }
}

/* The nearest tile a dropped thing may rest in, searched outward from where it
 * fell and giving up after three tiles, which leaves the caller's own tile.
 *
 * Deterministic, since the ring order is fixed and nothing here rolls: a
 * client replaying a death puts the flag where the arena put it. */
static void nearest_ground(const sim_map *m, int32_t *tx, int32_t *ty) {
    if (ground(m, *tx, *ty)) return;
    for (int32_t r = 1; r <= 3; r++) {
        for (int32_t dy = -r; dy <= r; dy++) {
            for (int32_t dx = -r; dx <= r; dx++) {
                if (dx > -r && dx < r && dy > -r && dy < r) continue;
                if (ground(m, *tx + dx, *ty + dy)) {
                    *tx += dx;
                    *ty += dy;
                    return;
                }
            }
        }
    }
}

/* Floor a Q8 coordinate to its tile boundary, defined over the whole range.
 *
 * The obvious spelling is `(v >> 12) << 12`, and it is what stood in the wall
 * collision below until the fuzzer caught it: shifting a negative value left
 * is undefined, and the unpacker admits hull positions the game itself never
 * produces, such as a ship whose reach crosses the origin. Collision has to
 * be defined for anything the unpacker accepts. Masking on the unsigned
 * representation computes the same floor for every input the shifts ever
 * answered, so behavior and the golden hashes do not move. */
static int32_t tile_floor(int32_t v) {
    return (int32_t)((uint32_t)v & ~(uint32_t)0xFFF);
}

/* Is any tile under this box a door that is shut right now?
 *
 * `box_hits` answers "can a hull be here", which a wall and a shut door both
 * refuse. This answers the narrower question the crush warp needs: whether
 * what is refusing is something that just closed, so a hull standing legally a
 * tick ago is now inside it. A wall does not move, so a box overlapping one is
 * a different bug and not this rule's to paper over. */
static int box_shut_door(const sim_map *m, const sim_settings *cfg,
                         uint32_t tick, int32_t x, int32_t y,
                         int32_t rx, int32_t ry) {
    int32_t tx0 = (x - rx) >> 12, tx1 = (x + rx) >> 12;
    int32_t ty0 = (y - ry) >> 12, ty1 = (y + ry) >> 12;
    for (int32_t ty = ty0; ty <= ty1; ty++)
        for (int32_t tx = tx0; tx <= tx1; tx++) {
            uint8_t t = sim_tile_at(m, tx, ty);
            if (SIM_TILE_CLASS(t) == SIM_TILE_DOOR
                && !sim_door_open(cfg, tick, SIM_TILE_VARIANT(t)))
                return 1;
        }
    return 0;
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
 * its oriented footprint. `ox, oy` is where the box's center sits relative to
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

/* The center of a tile, which is where a spawned ship stands.
 *
 * Worth a name because it used to be written out in three places and one of
 * them was wrong: the room and the team-change path both dropped a ship on a
 * tile's top-left corner, eight pixels up and left of where the wormhole path
 * put one, so a hull wide enough to matter sat off center in the gap its tile
 * was checked for. */
static int32_t tile_mid(int32_t t) {
    return t * SIM_TILE_PX * 256 + SIM_TILE_PX * 128;
}

/* Where a ship of this team goes now: on the map's own spawn point for this
 * team, or somewhere within `spawn_radius` tiles of it. See the header for
 * what a zone is choosing between.
 *
 * The point comes first and the radius is applied to it, which is the whole
 * shape of this. An earlier version made the radius mean "ignore the tiles and
 * scatter about the middle of the map", and that is a different game: it
 * throws every side into one place and the map stops having ends. Here the
 * map still says where a side belongs and the radius only says how precisely
 * a ship lands there.
 *
 * The scatter is a square rather than a disc, and that is inherited on
 * purpose: the original's was a square too, in spite of its own configuration
 * help calling it a circle, and rejecting the corners costs a multiply per
 * candidate to buy something no pilot can tell is there.
 *
 * Sixteen tries at open ground, then the spawn point itself. The original took
 * a hundred; ours is a map that is ninety-seven per cent open and whose spawn
 * points are placed with thirteen tiles of clear ground around them, so a draw
 * that fails sixteen times is a radius reaching into a structure rather than a
 * run of bad luck, and the point it falls back to is the one tile here that is
 * guaranteed to be clear.
 *
 * `nth` chooses the point, on both paths. The room passes a counter so
 * arrivals walk the tiles rather than stacking; a respawn passes a roll, so a
 * death sends you to a different one. */
/* The generator a placement draw runs on, which is not the room's.
 *
 * The shared stream cannot serve this. A client is sent the hulls inside its
 * interest radius and no others, so every draw the arena makes for one it
 * cannot see is a draw it does not make, and the two streams have parted
 * before the first snapshot of a prediction is a tick old. Reading a spawn
 * tile off that stream put a pilot's own respawn wherever their client's copy
 * of it happened to be: reported from alphasmall as a 9416 px correction, both
 * positions exact tile centers with no velocity on either side, which is a
 * respawn and cannot be anything else.
 *
 * Seeded from what both ends know about the hull being placed, so the answer
 * is a function of that hull rather than of the room's history, and so that
 * placing one hull no longer moves the stream under everything else. The tick
 * is in it because a pilot who dies twice should not come back to the same
 * tile twice, and the seat because two hulls returning together should not
 * land on top of each other. */
static uint32_t placement_seed(uint32_t tick, uint8_t seat, uint8_t team,
                               uint8_t cls) {
    uint32_t h = 0x9e3779b9u ^ tick;
    h ^= ((uint32_t)seat << 16) | ((uint32_t)team << 8) | (uint32_t)cls;
    h = xorshift32(h);
    return h ? h : 0x9e3779b9u;
}

static void pick_spawn(const sim_settings *cfg, uint32_t *rng, uint32_t tick,
                       uint8_t team, uint8_t cls, uint32_t nth,
                       int32_t *x, int32_t *y) {
    /* A map naming no starts at all falls back to the middle, which is a poor
     * answer and a loud one. That beats scattering ships through whatever the
     * map happens to have at the origin, and with a radius set it is also the
     * arrangement the original had before it had spawn points: everybody
     * around the center. */
    int32_t cx = SIM_MAP_TILES / 2, cy = SIM_MAP_TILES / 2;
    uint16_t mx = 0, my = 0;
    if (sim_map_spawn(cfg->map, team, nth, &mx, &my)) { cx = mx; cy = my; }

    if (cfg->spawn_radius == 0) {
        *x = tile_mid(cx);
        *y = tile_mid(cy);
        return;
    }

    /* The footprint is taken at heading zero rather than at the ship's, since
     * a respawn is about to be handed one anyway and a hull's box is widest
     * across the diagonals. Being slightly generous here costs a candidate,
     * and being slightly mean costs a ship stuck in a wall. */
    int32_t ox, oy, hx, hy;
    hull_box(&cfg->classes[cls < cfg->class_count ? cls : 0], 0,
             &ox, &oy, &hx, &hy);

    int32_t r = (int32_t)cfg->spawn_radius;
    uint32_t span = (uint32_t)r * 2u + 1u;
    for (int n = 0; n < 16; n++) {
        *rng = xorshift32(*rng);
        int32_t tx = cx + (int32_t)((*rng >> 8) % span) - r;
        *rng = xorshift32(*rng);
        int32_t ty = cy + (int32_t)((*rng >> 8) % span) - r;
        /* A radius that reaches past the edge is legal, the way the original's
         * 1024 was. Clamped inside the border the index paints rather than
         * rejected, so a point near a corner still spreads instead of throwing
         * away every draw that lands outside. */
        if (tx < 1) tx = 1; else if (tx > SIM_MAP_TILES - 2) tx = SIM_MAP_TILES - 2;
        if (ty < 1) ty = 1; else if (ty > SIM_MAP_TILES - 2) ty = SIM_MAP_TILES - 2;
        int32_t px = tile_mid(tx), py = tile_mid(ty);
        if (!box_hits(cfg->map, cfg, tick, px + ox, py + oy, hx, hy)) {
            *x = px;
            *y = py;
            return;
        }
    }
    *x = tile_mid(cx);
    *y = tile_mid(cy);
}

void sim_restart(sim_state *s, const sim_settings *cfg) {
    /* Nothing of the last match is left flying. A bomb in the air when the
     * whistle went would otherwise arrive at somebody standing on a start
     * line, and a mine posted in the last minute would still be there. */
    s->weapon_count = 0;

    /* Ships of a side line up along that side's starts rather than drawing
     * one each, so four pilots open a match spread across their pocket
     * instead of piled on whichever tile the roll landed on. `nth` walks the
     * map's starts for a team, which is exactly what this wants and is
     * already what a zone with no spawn radius asks for. */
    uint32_t nth[256] = {0};
    for (int i = 0; i < SIM_MAX_SHIPS; i++) {
        sim_ship *sh = &s->ships[i];
        if (!sh->active) continue;
        const sim_ship_class *cls =
            &cfg->classes[sh->cls < cfg->class_count ? sh->cls : 0];
        uint32_t seed = placement_seed(s->tick, (uint8_t)i, sh->team, sh->cls);
        uint32_t n = nth[sh->team]++;
        pick_spawn(cfg, &seed, s->tick, sh->team, sh->cls, n,
                   &sh->spawn_x, &sh->spawn_y);
        sh->x = sh->spawn_x;
        sh->y = sh->spawn_y;
        sh->vx = sh->vy = 0;
        sh->alive = 1;
        sh->respawn_at = 0;
        sh->fire_cooldown[SIM_TRIG_GUN] = 0;
        sh->fire_cooldown[SIM_TRIG_BOMB] = 0;
        sh->kills = sh->deaths = 0;
        sh->points = 0;
        sh->run = 0;
        /* With ammunition, which is the one thing a match start does that a
         * respawn does not. */
        sim_deal_kit(sh, cfg, 1);
        sh->energy = sim_eff_max_energy(cls, sh);
    }
}

void sim_spawn_point(sim_state *s, const sim_settings *cfg, uint8_t team,
                     uint8_t cls, uint32_t nth, int32_t *x, int32_t *y) {
    pick_spawn(cfg, &s->rng, s->tick, team, cls, nth, x, y);
}

/* Whether a point falls within `pad` of the hull's oriented rectangle. The
 * padding is round: sixteen pixels past a side and sixteen pixels past a
 * corner are the same pickup radius. Expanding both axes independently made
 * the corner reach sqrt(2) times larger, which let a hull take a green before
 * its diagonal had visibly reached it.
 *
 * The delta is rotated into the hull's own frame; along runs tail to nose,
 * across runs wing to wing. */
static int hull_reaches(const sim_ship_class *c, uint16_t heading,
                        int32_t sx, int32_t sy, int32_t px, int32_t py,
                        int32_t pad) {
    int32_t fx, fy;
    heading_dir(heading, &fx, &fy);
    int64_t dx = (int64_t)px - sx, dy = (int64_t)py - sy;
    int64_t along = (dx * fx + dy * fy) >> 15;
    int64_t across = (dy * fx - dx * fy) >> 15;
    if (across < 0) across = -across;

    int64_t along_gap = 0;
    if (along < -(int64_t)c->aft) along_gap = -(int64_t)c->aft - along;
    else if (along > c->fore) along_gap = along - c->fore;
    int64_t across_gap = across > c->halfw ? across - c->halfw : 0;
    int64_t reach = pad > 0 ? pad : 0;
    return along_gap * along_gap + across_gap * across_gap <= reach * reach;
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
                         uint8_t depth, uint16_t mods, uint32_t link,
                         uint8_t level,
                         uint8_t shrap_level, uint8_t shrap_bounce) {
    if (s->weapon_count >= SIM_MAX_WEAPONS) return; /* silently dropped */
    sim_weapon *w = &s->weapons[s->weapon_count++];
    w->spec = spec;
    w->owner = owner;
    w->team = team;
    w->left = left;
    w->depth = depth;
    w->mods = mods;
    w->link = link;
    w->level = level;
    w->shrap_level = shrap_level;
    w->shrap_bounce = shrap_bounce;
    w->x = x;
    w->y = y;
    w->vx = vx;
    w->vy = vy;
    w->life = life;
    w->fuse_target = 255;
    w->fuse = 0;
    w->near = 0;
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
        int32_t fuse = n * cfg->mod_step[SIM_MOD_PROX] + level * cfg->prox_step;
        /* The larger of the two, for a weapon that already senses on its own.
         * Adding is right for a bomb, which is a contact round until the
         * add-on gives it a fuse -- there is nothing to add to. A mine comes
         * with one, so a sum double-dips: it reached two tiles further than a
         * proximity bomb of the same rung, which inverts the reason its own
         * fuse is the tighter of the two. A mine does not have to be dodged
         * in the air first, so it should not also out-range the round that
         * does. Matching rather than exceeding still pays the add-on. */
        if (sp->trigger > 0) {
            if (fuse > sp->trigger) sp->trigger = fuse;
        } else {
            sp->trigger += fuse;
        }
    }
    /* A rung of damage, for the one spec whose rung is not a ladder: a
     * fragment is a bullet of whatever the thrower's guns were, so its damage
     * climbs with a number rather than by pointing at another row. */
    if (sp->damage_up) sp->damage += level * sp->damage_up;
    /* And a rung of blast, for the other one. A mine is one pattern wearing
     * the pilot's bomb rung rather than a row per rung, and this is what makes
     * that rung worth anything. */
    if (sp->blast_up) sp->blast += level * sp->blast_up;
    /* What that rung costs, for the same reason and on the pattern rather than
     * the spec: a bomb ladder charges more per rung by being a different
     * pattern per rung, and a weapon with one pattern has nowhere else to put
     * it. Without this the rung that widens a mine's hole is free. */
    if (p && p->energy_up) p->energy += level * p->energy_up;
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
                          uint8_t shrap_level, uint8_t shrap_bounce,
                          uint32_t link, sim_events *ev);

/* Remove a weapon by swapping the last one into its slot. Order is
 * deterministic because it depends only on state, never on time. */
static void kill_weapon(sim_state *s, uint16_t i) {
    s->weapons[i] = s->weapons[--s->weapon_count];
}

static void drop_flags(sim_state *s, const sim_settings *cfg, uint8_t ship,
                       sim_events *ev);

int32_t sim_bounty(const sim_settings *cfg, const sim_ship *sh) {
    return (int32_t)cfg->bounty_base + sh->run;
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
        /* A prediction client concludes no death but its own pilot's. The
         * hull keeps a sliver and flies on; the death, if the zone agrees
         * there is one, arrives as a snapshot state change instead. Report
         * the suppressed conclusion separately so the client can measure how
         * often the zone agrees without drawing the death. The hit above has
         * already reported, so the spark still draws. */
        if (cfg->deathless && victim != cfg->mortal_ship) {
            note_predicted_death(ev, victim);
            v->energy = 1;
            return;
        }
        v->energy = 0;
        v->alive = 0;
        v->deaths++;
        v->respawn_at = cfg->respawn_delay;
        v->vx = v->vy = 0;
        /* What the kill is worth, read before the pilot is stripped: the
         * price is what they were carrying, and in one more instruction it
         * will be nothing.
         *
         * That used to carry a second claim, that a fresh spawn is therefore
         * worth nothing and this game needs no anti-farming rule because
         * camping a respawn pays zero. True while `spawn_prizes` was zero and
         * not since: the greens a ship is handed at spawn are things it holds,
         * `sim_bounty` sums what a pilot holds, and at the baseline's thirty
         * that is about 29.5 a kill for shooting people as they arrive. The
         * levers on it are `spawn_prizes` and `spawn_radius`, which is what a
         * radius is for as much as distance is. */
        int32_t paid = 0;
        if (attacker != 255 && attacker != victim) {
            sim_ship *k = &s->ships[attacker];
            k->kills++;
            /* A teammate's death pays neither points nor bounty. The rating
             * layer already refuses to score teammate damage; this is the
             * same rule where a player can see it. */
            if (k->team != v->team) {
                paid = sim_bounty(cfg, v);
                for (int f = 0; f < s->flag_count; f++)
                    if (s->flags[f].active && s->flags[f].carried
                        && s->flags[f].carrier == victim)
                        paid += cfg->points_per_flag;
                k->points += (uint32_t)paid;
                k->run = (uint16_t)(k->run + cfg->bounty_per_kill);
            }
        }
        /* What a death takes is the run, which is the whole of what a pilot
         * was worth, and the ammunition they had already spent, which does
         * not come back. The frame is re-dealt at the respawn: a kit is
         * something you own rather than something you survived with. */
        v->repel = 0;
        v->repel_speed = 0;
        v->run = 0;
        drop_flags(s, cfg, victim, ev);
        emit(ev, SIM_EV_DEATH, victim, attacker, paid);
    }
}

/* A mine: a round laid rather than thrown, that goes off where it sits.
 *
 * Derived rather than flagged, because both halves are already load-bearing
 * and neither is true of anything else. `still` is what stops it leaving at
 * the ship's speed, and a blast is what makes it a weapon instead of a marker.
 * A repel has no blast damage and is skipped before this is ever asked. The
 * client draws mines off the same two fields, so the two cannot end up
 * disagreeing about what a mine is. */
static int is_mine(const sim_weapon_spec *sp) {
    return sp->still && sp->blast > 0;
}

/* The bomb spec of a hull's rung, or SIM_NO_PATTERN when it has no rack there.
 *
 * A repelled mine becomes a bomb of the rung it was laid at, so the ladder has
 * to be read back from the class that laid it. The rung is clamped rather than
 * refused: a pilot who swapped to a hull with a shorter ladder while their
 * mines were still out gets the top of what that hull has, which is the same
 * rule a level takes everywhere else. */
static uint8_t bomb_spec_at(const sim_settings *cfg, const sim_state *s,
                            uint8_t owner, uint8_t level) {
    if (owner >= s->ship_count) return SIM_NO_PATTERN;
    const sim_ship *sh = &s->ships[owner];
    if (!sh->active || sh->cls >= cfg->class_count) return SIM_NO_PATTERN;
    const sim_ship_class *c = &cfg->classes[sh->cls];
    for (int r = (level < SIM_MAX_RUNGS ? level : SIM_MAX_RUNGS - 1); r >= 0; r--) {
        uint8_t pat = c->trigger[SIM_TRIG_BOMB][r];
        if (pat != SIM_NO_PATTERN && pat < cfg->pattern_count)
            return cfg->patterns[pat].spec;
    }
    return SIM_NO_PATTERN;
}

/* What a projectile does where it ends.
 *
 * One ending, four things it might do, all optional and all read off the
 * spec: hurt the hull it touched, hurt everything inside a blast, shove what
 * is nearby, and fire another pattern from the same spot. A plain bullet has
 * only the first; a bomb has the first two; shrapnel is the fourth, and a
 * repel is the third with nothing else at all.
 *
 * Damage inside a blast falls off linearly from the center, which is what
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
    /* ExactDamage is off in SVS. Bullets, burst rounds, and shrapnel draw
     * from a square distribution, then take its square root. That makes the
     * listed damage a ceiling, with an average near two thirds of it. Bombs
     * stay exact and continue through their distance falloff below. */
    if (spec->blast == 0 && damage > 0) {
        damage = random_bullet_damage(s, w, damage);
    }
    if (spec->blast > 0) {
        int64_t rad = spec->blast;
        /* BBombDamagePercent. A hull whose bombs bounce pays for the trick on
         * every bomb it throws rather than on the ones that come back, so the
         * ceiling its roster row allows is the test and not what this round is
         * carrying. */
        if (cfg->bbomb_damage != 1000 && w->owner < SIM_MAX_SHIPS) {
            const sim_ship_class *oc = &cfg->classes[s->ships[w->owner].cls];
            if (sim_mod_get(oc->mod_max[SIM_TRIG_BOMB], SIM_MOD_BOUNCE))
                damage = (int32_t)(((int64_t)damage * cfg->bbomb_damage) / 1000);
        }
        /* How far the pilot who threw it is standing from their own blast.
         * Everyone else's damage is cut by half of whatever that distance
         * would have paid them, so a bomb let off at your own feet lands at
         * half strength on the pilot in front of you and full strength on
         * you. That is the original's rule and it is the whole reason a bomb
         * is a thrown weapon rather than a bigger bullet. */
        int64_t sd = rad;
        if (w->owner < SIM_MAX_SHIPS && s->ships[w->owner].active) {
            const sim_ship *o = &s->ships[w->owner];
            int64_t ox = (int64_t)o->x - w->x, oy = (int64_t)o->y - w->y;
            int64_t o2 = ox * ox + oy * oy;
            sd = o2 > rad * rad ? rad : isqrt64(o2);
        }
        for (int i = 0; i < s->ship_count; i++) {
            sim_ship *sh = &s->ships[i];
            if (!sh->active || !sh->alive) continue;
            int64_t ddx = (int64_t)sh->x - w->x, ddy = (int64_t)sh->y - w->y;
            int64_t d2 = ddx * ddx + ddy * ddy;
            if (d2 > rad * rad) continue;
            int64_t d = isqrt64(d2);
            int32_t dmg = (int32_t)((int64_t)damage * (rad - d) / rad);
            if ((uint8_t)i != w->owner && sd < rad) {
                dmg -= (int32_t)(((int64_t)damage * (rad - sd) / rad) / 2);
                if (dmg < 0) dmg = 0;
            }
            /* A round that only stalls does no damage at all, so `dmg > 0`
             * cannot be the test for whether anything happened -- that is
             * what made the first stall round land silently. */
            if (dmg > 0 || spec->stall > 0)
                apply_damage(s, cfg, (uint8_t)i, w->owner, dmg, spec->stall, ev);
        }
    } else if (hit_ship >= 0 && (damage > 0 || spec->stall > 0)) {
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
     * charge spawns at a muzzle offset rather than at the hull center, so the
     * "dead center has no direction" guard below never saw them. It shoved
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
                if (d == 0) continue;      /* dead center has no direction */
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
                /* A mine that is shoved stops being a mine.
                 *
                 * Everything about the shape is wrong for a round in flight:
                 * it sits on a minute of life, so pushed as itself it crosses
                 * the map at repel speed and then keeps going, and it senses
                 * on a fuse tuned to something standing still next to it. The
                 * pilot who let the repel off has cleared the doorway, which
                 * is what a repel is for, and what leaves is a bomb of the
                 * rung it was laid at -- the same rung it has been wearing as
                 * its color the whole time it sat there, so the thing flying
                 * away is recognisably the thing that was posted. Whoever laid
                 * it still owns it, so it can still kill them. */
                if (is_mine(&cfg->specs[o->spec])) {
                    uint8_t b = bomb_spec_at(cfg, s, o->owner, o->level);
                    if (b != SIM_NO_PATTERN) {
                        o->spec = b;
                        o->left = cfg->specs[b].bounces;
                        /* It was laid, not thrown, so it never armed a fuse.
                         * Leaving one latched would hand the bomb a target it
                         * found while it was furniture. */
                        o->fuse_target = 255;
                        o->fuse = 0;
                    }
                }
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
            uint16_t fm = w->shrap_bounce
                ? sim_mod_set(0, SIM_MOD_BOUNCE, 1) : 0;
            spawn_pattern(s, cfg, spec->splinter, w->owner, w->team, w->x, w->y,
                          0, 0, 0, (uint8_t)(w->depth + 1), fm,
                          w->shrap_level, 0, 0, 0, ev);
        }
    }
}

static void spawn_pattern(sim_state *s, const sim_settings *cfg, uint8_t pat,
                          uint8_t owner, uint8_t team, int32_t x, int32_t y,
                          int32_t vx0, int32_t vy0, uint16_t heading,
                          uint8_t depth, uint16_t mods, uint8_t level,
                          uint8_t shrap_level, uint8_t shrap_bounce,
                          uint32_t link, sim_events *ev) {
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
        /* A still round ignores what the ship was doing and takes only its own
         * speed, which for a mine is none. See `still` on the spec. */
        int32_t bx = spec->still ? 0 : vx0, by = spec->still ? 0 : vy0;
        int32_t vx = bx + (int32_t)(((int64_t)spec->speed * dx) >> 15);
        int32_t vy = by + (int32_t)(((int64_t)spec->speed * dy) >> 15);
        spawn_weapon(s, p->spec, owner, team, x, y, vx, vy, spec->life,
                     spec->bounces, depth, mods, link, level,
                     shrap_level, shrap_bounce);
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
        f->carrier = 0;
        f->x = s->ships[ship].x;
        f->y = s->ships[ship].y;
        /* Where they fell, unless the map is going to close over it. A carrier
         * killed in an open door left the flag inside the door, and a flag
         * nobody can reach is a round nobody can finish. Only then is it moved,
         * so an ordinary drop still lands exactly where the hull was. */
        if (!ground(cfg->map, f->x / (SIM_TILE_PX * 256),
                    f->y / (SIM_TILE_PX * 256))) {
            int32_t tx = f->x / (SIM_TILE_PX * 256);
            int32_t ty = f->y / (SIM_TILE_PX * 256);
            nearest_ground(cfg->map, &tx, &ty);
            f->x = tile_mid(tx);
            f->y = tile_mid(ty);
        }
        f->cooldown = cfg->flag_drop_cooldown;
        emit(ev, SIM_EV_FLAG_DROP, (uint8_t)i, f->team, 0);
    }
}



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
    memset(sh->kit, 0, sizeof sh->kit);
    sh->run = 0;
    sh->alive = 1;
    sh->respawn_at = 0;
    sh->x = sh->spawn_x;
    sh->y = sh->spawn_y;
    sh->vx = sh->vy = 0;
    sh->fire_cooldown[SIM_TRIG_GUN] = 0;
    sh->fire_cooldown[SIM_TRIG_BOMB] = 0;
    /* A kit is validated against the hull it was built for, so it does not
     * cross to another one. The caller sets one for the new hull; until it
     * does, this pilot flies the bare frame. */
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

    /* What you were carrying belongs to the side you are leaving. Gunners
     * too. */
    drop_flags(s, cfg, i, 0);
    sh->team = team;
    /* A run does not cross sides with you. Two pilots trading sides to feed
     * each other kills is the oldest arrangement in this genre, and what a
     * kill pays is the victim's bounty. */
    sh->run = 0;

    /* And your start moves to the new side's. A map that marks no start for
     * this team hands out somebody else's, which `sim_map_spawn` already does
     * and is the whole reason a team the map has never heard of -- a private
     * one, formed in a room mid-round -- works at all. */
    uint32_t seed = placement_seed(s->tick, i, team, sh->cls);
    pick_spawn(cfg, &seed, s->tick, team, sh->cls, seed >> 8,
               &sh->spawn_x, &sh->spawn_y);
    sh->x = sh->spawn_x;
    sh->y = sh->spawn_y;
    sh->vx = sh->vy = 0;
    sh->fire_cooldown[SIM_TRIG_GUN] = 0;
    sh->fire_cooldown[SIM_TRIG_BOMB] = 0;
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
                f->carrier = 0;
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
            f->x = sh->x;
            f->y = sh->y;
            emit(ev, SIM_EV_FLAG_TAKE, (uint8_t)k, (uint8_t)i, 0);
            break;
        }
    }
}

/* ---- prizes ---- */

/* Spawn one prize at a random open tile inside the configured bounds. Every
 * draw comes from the state's own PRNG, so prize placement is part of the
 * deterministic stream and a client can predict it exactly. */

/* Move one count by a step, within its ceiling and never below zero. */
/* How far a proximity sensor reaches, from the bomb's center, in Q8 px.
 *
 * The original does not use ProximityDistance as the radius. It scales it by
 * eighteen pixels a tile and then takes fourteen back, which on a three-tile
 * fuse turns 48 px into 40, and the caller then adds the target hull's own
 * half width. Odd arithmetic, faithfully copied: guessing that a distance
 * setting is a distance is what put our sensor eight pixels short on the axes
 * and thirty short into the corners. */
static int32_t prox_reach(int32_t trigger) {
    int32_t r = (int32_t)(((int64_t)trigger * 18) / 16) - 14 * 256;
    return r < 0 ? 0 : r;
}

/* Hold a trigger shut for at least this long.
 *
 * Never shortens one, which is the whole of the rule: the original raises each
 * of its two clocks and never lowers either, so a bomb thrown a tick after a
 * bullet cannot hand the guns back early. Written as a max rather than an
 * assignment for that reason alone. */
static void lock_trigger(sim_ship *sh, int trig, uint16_t ticks) {
    if (ticks > sh->fire_cooldown[trig]) sh->fire_cooldown[trig] = ticks;
}

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



/* How much of `type` this pilot is holding. */
static uint8_t held(const sim_ship *sh, uint8_t type) {
    if (type < SIM_UP_COUNT) return sh->up[type];
    type = (uint8_t)(type - SIM_UP_COUNT);
    if (type < SIM_TRIG_COUNT) return sh->level[type];
    type = (uint8_t)(type - SIM_TRIG_COUNT);
    if (type < SIM_TRIG_COUNT * SIM_MOD_COUNT)
        return sim_mod_get(sh->mods[type / SIM_MOD_COUNT], type % SIM_MOD_COUNT);
    return sh->charge[type - SIM_TRIG_COUNT * SIM_MOD_COUNT];
}

int sim_grant(sim_ship *sh, const sim_settings *cfg, uint8_t type) {
    if (type >= SIM_SLOT_COUNT) return 0;
    const sim_ship_class *c = &cfg->classes[sh->cls];
    uint8_t was = held(sh, type);
    move_count(sh, c, type, 1);
    return held(sh, type) != was;
}

/* Whether this hull is carrying a fan at all. Multifire is held per trigger
 * and the decline is one switch over both, so a pilot with a fanning bomb and
 * a plain gun still has something to turn off. */
static int ship_has_multi(const sim_ship *sh) {
    for (int t = 0; t < SIM_TRIG_COUNT; t++)
        if (sim_mod_get(sh->mods[t], SIM_MOD_MULTI)) return 1;
    return 0;
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
        ev->predicted_death_count = 0;
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
                /* A fresh draw, not the tile you came in on. A spawn used to
                 * be fixed for the length of a visit, which made whichever
                 * tile the door happened to hand you a property of your whole
                 * session: an enemy who found it owned you until you left, and
                 * on a map whose starts are scattered over half of it, two
                 * pilots on one side were up to twenty seconds apart on the
                 * way back to the same fight for as long as they both stayed.
                 *
                 * It also moves `spawn_x`, so the door-crush warp below keeps
                 * sending a ship somewhere it could currently arrive rather
                 * than to a tile it has not used since it walked in. */
                uint32_t seed = placement_seed(next->tick, (uint8_t)i,
                                               sh->team, sh->cls);
                pick_spawn(cfg, &seed, next->tick, sh->team, sh->cls,
                           seed >> 8, &sh->spawn_x, &sh->spawn_y);
                sh->x = sh->spawn_x;
                sh->y = sh->spawn_y;
                sh->vx = sh->vy = 0;
                sim_deal_kit(sh, cfg, 0);
                sh->energy = sim_eff_max_energy(cls, sh);
                sh->fire_cooldown[SIM_TRIG_GUN] = 0;
                sh->fire_cooldown[SIM_TRIG_BOMB] = 0;
                emit(ev, SIM_EV_SPAWN, (uint8_t)i, 0, 0);
            }
            continue;
        }

        uint16_t b = buttons[i];
        for (int k = 0; k < SIM_TRIG_COUNT; k++)
            if (sh->fire_cooldown[k] > 0) sh->fire_cooldown[k]--;

        const int32_t e_rot = sim_eff_rot(cls, sh);
        int32_t e_thrust = sim_eff_thrust(cls, sh);
        int32_t e_speed = sim_eff_speed(cls, sh);

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
         * cannot pass through is a wall wearing a different color.
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
         * the two ends disagree about.
         *
         * The switch exists only while there is a fan to throw it on. A hull
         * carrying none has nothing to decline, so the press does nothing at
         * all: the flag does not move, and a client that says the key landed
         * by watching the flag stays quiet with it. And a fan that leaves, to
         * a death or to a green that takes rather than gives, takes the
         * switch with it, rather than leaving a decline lying in wait for
         * whatever the pilot picks up next. Enforced here, once a tick,
         * rather than at each of the three places a rung can leave a ship;
         * a dead hull skips this loop, so the clear lands on the first tick
         * of the next life, before there is anything to pick up. */
        if (!ship_has_multi(sh)) {
            sh->multi_off = 0;
        } else if ((b & SIM_BTN_MULTI) && !(sh->btn_prev & SIM_BTN_MULTI)) {
            sh->multi_off = (uint8_t)(sh->multi_off ? 0 : 1);
        }
        sh->btn_prev = b;

        /* 3a. A charge: a weapon carried by the count and spent. The slot
         * comes down in the buttons rather than living on the ship, so
         * choosing which one is ready is the client's business and costs the
         * simulation nothing -- no selection byte in a snapshot, and no edge
         * detection to get wrong when a shot is replayed. */
        if (!in_safe && (b & SIM_BTN_USE)) {
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
                 * asked for. Nor a rung: neither of the two scales with one. */
                spawn_pattern(next, cfg, pat, (uint8_t)i, sh->team, mx, my,
                              sh->vx, sh->vy, sh->heading, 0, 0, 0, 0, 0, 0,
                              ev);
                sh->charge[k]--;
                sh->energy -= cp.energy;
                /* A carried charge is independent of the gun and bomb
                 * clocks. Repel and burst are defensive answers a pilot may
                 * need while either trigger is still shut, and neither has a
                 * fire-delay setting in the original. */
                sh->vx -= (int32_t)(((int64_t)cp.recoil * dx) >> 15);
                sh->vy -= (int32_t)(((int64_t)cp.recoil * dy) >> 15);
                emit(ev, SIM_EV_CHARGE, (uint8_t)i, (uint8_t)k, sh->charge[k]);
            }
        }

        int want = ((b & SIM_BTN_FIRE) == 0) ? SIM_TRIG_BOMB : SIM_TRIG_GUN;
        if (!in_safe && sh->fire_cooldown[want] == 0
            && (b & (SIM_BTN_FIRE | SIM_BTN_BOMB))) {
            int trig = want;
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
                /* BombSafety. A proximity bomb will not leave the tube while
                 * somebody is already inside the fuse's reach, so it cannot be
                 * carried up to a hull and posted through it. The distance is
                 * the plain one rather than the sensor's scaled version, which
                 * is the original's own inconsistency, kept because copying it
                 * is the point.
                 *
                 * Measured hull to hull, and refused rather than fired and
                 * wasted: the trigger simply does nothing, which is what a
                 * safety catch is. */
                int safe_off = 0;
                if (cfg->bomb_safety && trig == SIM_TRIG_BOMB
                    && sim_mod_get(use_mods, SIM_MOD_PROX)) {
                    int64_t r = fs.trigger;
                    for (int k = 0; k < next->ship_count && !safe_off; k++) {
                        const sim_ship *o = &next->ships[k];
                        if (!o->active || !o->alive) continue;
                        if (k == (int)i || o->team == sh->team) continue;
                        int64_t ox = (int64_t)o->x - sh->x;
                        int64_t oy = (int64_t)o->y - sh->y;
                        if (ox * ox + oy * oy <= r * r) safe_off = 1;
                    }
                }
                if (!safe_off && sh->energy > fp.energy) {
                    /* Muzzle just outside the hull, so a shot never spawns
                     * inside its own ship. */
                    int32_t mx = sh->x + (int32_t)(((int64_t)(cls->fore + 512) * dx) >> 15);
                    int32_t my = sh->y + (int32_t)(((int64_t)(cls->fore + 512) * dy) >> 15);
                    /* Shrapnel is bullets, so what a bomb will break into
                     * is read off the guns rather than off the bomb: the
                     * pilot's gun rung, and whether their bullets bounce.
                     * Taken here, at the throw, so it is what they were
                     * carrying then and not what they hold when it lands. */
                    uint32_t link = trig == SIM_TRIG_GUN
                        ? ((next->tick & 0x01ffffffu) << 7)
                              | ((uint32_t)i + 1u)
                        : 0;
                    spawn_pattern(next, cfg, pat, (uint8_t)i, sh->team, mx, my,
                                  sh->vx, sh->vy, sh->heading, 0,
                                  use_mods, sh->level[trig],
                                  sh->level[SIM_TRIG_GUN],
                                  sim_mod_get(sh->mods[SIM_TRIG_GUN],
                                              SIM_MOD_BOUNCE) != 0,
                                  link, ev);
                    sh->energy -= fp.energy;
                    /* Every trigger locks every other for its own delay, so
                     * one clock is what a pilot feels almost always. The
                     * exception is the EMP bomb, which leaves its own guns
                     * running: that is the only reason these are two counters
                     * rather than one, and it is the original's rule rather
                     * than a kindness. It is read off the round instead of a
                     * flag on the hull, because a bomb that suppresses the
                     * recharge is what EmpBomb means, and a zone that hands
                     * one to somebody has made them an EMP ship whether or not
                     * a second setting agrees. */
                    lock_trigger(sh, trig, fp.delay);
                    if (!(trig == SIM_TRIG_BOMB && fs.stall > 0)) {
                        lock_trigger(sh, trig ^ 1, fp.delay);
                    }
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
        if (!sh->public_only) {
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
         * The destination is wherever this pilot could currently respawn,
         * drawn from the state's own generator so the two ends of the wire
         * agree about where a ship went. Which under a spawn radius is a tile
         * near the middle, and under spawn tiles is one of this team's own:
         * the comment here used to claim it was anybody's, on the grounds that
         * a wormhole which only sent you home would be a retreat button, but
         * it has always passed the pilot's team and `sim_map_spawn` prefers a
         * team's own tiles. Left as it behaves rather than as it was described,
         * because changing which it is belongs in a decision about wormholes
         * rather than in a change about spawning. */
        if (sh->alive
            && SIM_TILE_CLASS(sim_tile_at(cfg->map, sh->x >> 12, sh->y >> 12))
                   == SIM_TILE_WORMHOLE) {
            uint32_t seed = placement_seed(next->tick, (uint8_t)i, sh->team,
                                           sh->cls);
            pick_spawn(cfg, &seed, next->tick, sh->team, sh->cls, seed >> 8,
                       &sh->x, &sh->y);
            /* Momentum does not survive the trip. Arriving at a spawn at four
             * hundred pixels a second is arriving inside whatever is next to
             * it. */
            sh->vx = 0;
            sh->vy = 0;
            emit(ev, SIM_EV_WARP, (uint8_t)i, 1, 0);
        }

        /* 4b. A door that shuts on a ship warps it rather than swallowing it.
         * The alternative is a ship inside a wall, which the axis-by-axis
         * collision below cannot resolve: both axes are blocked, so it stays
         * stuck until something kills it. Warping keeps the door lethal to
         * position without being lethal to the pilot.
         *
         * Asked of the hull's box, because that is what gets caught. This used
         * to ask what the tile under the ship's center was, and a hull is
         * wider than a tile: a pilot sitting in a blank spot inside a door
         * structure has doors either side of a center standing on open ground,
         * so the warp did not fire and the collision below could not move
         * them. Reported from play as a ship frozen inside a laser wall until
         * the wall opened again, which is exactly how long it lasts. */
        {
            int32_t dox, doy, dhx, dhy;
            hull_box(cls, sh->heading, &dox, &doy, &dhx, &dhy);
            if (box_shut_door(cfg->map, cfg, next->tick, sh->x + dox,
                              sh->y + doy, dhx, dhy)) {
                sh->x = sh->spawn_x;
                sh->y = sh->spawn_y;
                sh->vx = 0;
                sh->vy = 0;
                emit(ev, SIM_EV_WARP, (uint8_t)i, 0, 0);
            }
        }

        /* 5. Integrate and collide, one axis at a time so a wall kills only
         * the normal component and the ship slides along it.
         *
         * The box follows the heading: hull_box gives the world-axis bounds
         * of the hull as oriented this tick, and its center sits `ox, oy`
         * from the ship because a hull is longer ahead of its pivot than
         * behind it. The clamps below are the old flush-to-tile arithmetic
         * with the reach on each side spelled out, since with an offset box
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
                    nx = tile_floor(sh->x + east) + 4096 - east - 1;
                else if (sh->vx < 0)
                    nx = tile_floor(sh->x - west) + west;
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
                    ny = tile_floor(sh->y + south) + 4096 - south - 1;
                else if (sh->vy < 0)
                    ny = tile_floor(sh->y - north) + north;
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
         * overflow is undefined behavior: the wrapped result was a huge
         * negative bar, which the clamp then let through because it only ever
         * looked for too much. A spawning ship really did arrive at INT32_MAX
         * -- the server set that, meaning "full" -- and left the tick at
         * INT32_MIN, one hit from dead.
         *
         * Worth more than the symptom: this core's whole contract is that every
         * platform steps it identically, and undefined behavior is exactly the
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
        uint32_t key = ((uint32_t)w->spec << 24) | ((uint32_t)w->level << 16)
                     | w->mods;
        if (key != cached_key) {
            cached = cfg->specs[w->spec];
            compose(cfg, w->mods, w->level, &cached, NULL);
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
            /* The second argument is the hull it ended on, or 255 for none.
             * It used to be the owner, which nothing ever read; the renderer
             * wants the victim, so a detonation can be drawn stuck to the
             * ship it hit rather than to a coordinate the render smoothing
             * has moved the ship away from. */
            emit(ev, SIM_EV_EXPIRE, w->spec, 255, pack_pos(w->x, w->y, w->level));
            kill_weapon(next, wi);
            continue;
        }
        w->life--;

        /* The tick's travel, walked in samples no further apart than 4 px
         * rather than tested once at the far end. One endpoint sample was the
         * old rule, and it is exactly what a projectile passing *through* a
         * hull looks like: a bullet plus its shooter's velocity covers up to
         * 6.25 px a tick, an incoming hull adds its own, and a Cipher's flank
         * is 12 px thick, so a grazing crossing could fall entirely between
         * two samples and never register -- on the server, with no lag
         * involved at all. Walls had the same hole at higher speeds than any
         * shipped zone uses, but a zone file can retune speed upward and
         * nothing here should quietly stop working when one does.
         *
         * The count comes from the velocity alone, so it is as deterministic
         * as the flight. Capped because a step count is a cost multiplier:
         * sixteen samples covers 64 px a tick, five times the fastest thing
         * any current tuning can make, and past the cap spacing grows instead
         * of the loop. */
        int32_t dx = w->vx / 256, dy = w->vy / 256;
        int32_t adx = dx < 0 ? -dx : dx, ady = dy < 0 ? -dy : dy;
        int32_t span = adx > ady ? adx : ady;
        int sweep = 1 + span / 1024;
        if (sweep > 16) sweep = 16;
        int32_t x0 = w->x, y0 = w->y;

        for (int si = 1; si <= sweep && !ended; si++) {
            /* 2. Walls: stop here, bounce off, or ignore them entirely.
             *
             * A bounce reflects the axis that hit, tested one axis at a time
             * so a corner turns a projectile around rather than letting it
             * through -- the same treatment a ship gets, and for the same
             * reason. Bouncing forfeits the rest of this tick's walk, since
             * the precomputed samples describe a flight the reflection just
             * ended. */
            int32_t px = w->x, py = w->y;
            w->x = x0 + (int32_t)((int64_t)dx * si / sweep);
            w->y = y0 + (int32_t)((int64_t)dy * si / sweep);
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
                         pack_pos(w->x, w->y, w->level));
                    break;
                }
                /* End on the near side of the wall rather than a step inside
                 * it. A blast centered in the tile spends half its reach on
                 * the far side where nobody is, and shrapnel spawned in there
                 * dies on its own first tick. */
                w->x = px;
                w->y = py;
                ended = 1;
                break;
            }

            /* 3. Ships. Contact is the hull's own rectangle: a round into a
             * Cipher's flank has to reach the knife.
             *
             * A proximity fuse is a different shape and a different rule, and
             * both are the original's. The sensor is a square about the bomb,
             * `trigger * 18 / 16 - 14` px to a side from its center, widened
             * by the target hull's own half width; the arming test is that
             * square against the hull's, which makes it the larger of the two
             * axis gaps rather than a distance. A three-tile fuse comes out
             * near fifty pixels on the axes and half again as far into the
             * corners, which is why the shape is worth copying rather than
             * rounding off to a circle. */
            for (int i = 0; i < next->ship_count && !ended; i++) {
                const sim_ship *sh = &next->ships[i];
                if (!sh->active || !sh->alive) continue;
                if ((uint8_t)i == w->owner || sh->team == w->team) continue;
                int64_t ddx = (int64_t)w->x - hull[i].x;
                int64_t ddy = (int64_t)w->y - hull[i].y;
                int64_t along = (ddx * hull[i].fx + ddy * hull[i].fy) >> 15;
                int64_t across = (ddy * hull[i].fx - ddx * hull[i].fy) >> 15;
                if (across < 0) across = -across;
                if (along >= -(int64_t)hull[i].aft
                    && along <= (int64_t)hull[i].fore
                    && across <= (int64_t)hull[i].halfw) {
                    ended = 1;
                    hit_ship = i;
                    continue;
                }
                if (spec->trigger == 0 || w->fuse_target != 255) continue;
                int64_t reach = prox_reach(spec->trigger) + hull[i].halfw;
                int64_t ax = ddx < 0 ? -ddx : ddx;
                int64_t ay = ddy < 0 ? -ddy : ddy;
                if (ax >= reach || ay >= reach) continue;
                /* Found somebody. From here the fuse watches this hull and no
                 * other: a second pilot crossing an armed bomb does not set it
                 * off, which is the original's rule and the reason the target
                 * is remembered rather than re-found. */
                w->fuse_target = (uint8_t)i;
                w->fuse = cfg->prox_delay;
                w->near = (int32_t)(ax > ay ? ax : ay);
            }
        }

        /* 3c. An armed fuse, which watches its one hull and nothing else.
         *
         * It fires when the gap stops shrinking or when BombExplodeDelay runs
         * out, whichever comes first, and the gap is the larger of the two
         * axis distances rather than a diagonal, matching the square the
         * sensor is. The blast lands where the bomb was at the top of this
         * tick rather than where the tick carried it: the growth was noticed
         * one step late, so the step before it is the nearest the round ever
         * got, and that is where it should go off.
         *
         * A target that dies or leaves takes the bomb with it, since there is
         * nothing left to be near.
         *
         * The walls above still win, because a bomb that reaches one has
         * arrived at something whatever its fuse thinks. */
        if (!ended && w->fuse_target != 255) {
            const sim_ship *ft = &next->ships[w->fuse_target];
            if (!ft->active || !ft->alive || ft->team == w->team) {
                ended = 1;
                hit_ship = w->fuse_target;
            } else {
                int64_t ax = (int64_t)w->x - ft->x, ay = (int64_t)w->y - ft->y;
                if (ax < 0) ax = -ax;
                if (ay < 0) ay = -ay;
                int64_t gap = ax > ay ? ax : ay;
                if (w->fuse > 0) w->fuse--;
                if (gap > w->near || w->fuse == 0) {
                    w->x = x0;
                    w->y = y0;
                    ended = 1;
                    hit_ship = w->fuse_target;
                } else {
                    w->near = (int32_t)gap;
                }
            }
        }

        /* 4. The ending. The event names the hull it ended on, 255 for a
         * wall, so the renderer can pin the detonation to the ship the
         * player is looking at. */
        if (ended) {
            uint32_t link = w->link;
            weapon_end(next, cfg, spec, w, hit_ship, ev);
            emit(ev, SIM_EV_EXPIRE, w->spec,
                 hit_ship >= 0 ? (uint8_t)hit_ship : 255,
                 pack_pos(w->x, w->y, w->level));
            kill_weapon(next, wi);
            /* SVS links every round made by one gun pull. Once one touches a
             * player, the rest disappear without dealing damage. A wall hit
             * leaves its siblings alone, so a spread can wrap a corner. */
            if (hit_ship >= 0 && link != 0) {
                for (uint16_t li = 0; li < next->weapon_count;) {
                    sim_weapon *sibling = &next->weapons[li];
                    if (sibling->link != link) {
                        li++;
                        continue;
                    }
                    emit(ev, SIM_EV_EXPIRE, sibling->spec, 255,
                         pack_pos(sibling->x, sibling->y, sibling->level));
                    kill_weapon(next, li);
                }
            }
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
        h = hash_u32(h, (uint32_t)sh->active | ((uint32_t)sh->alive << 8)
                            | ((uint32_t)sh->public_only << 16)
                            | ((uint32_t)sh->cls << 24));
        h = hash_u32(h, sh->team);
        h = hash_u32(h, (uint32_t)sh->x);
        h = hash_u32(h, (uint32_t)sh->y);
        h = hash_u32(h, (uint32_t)sh->vx);
        h = hash_u32(h, (uint32_t)sh->vy);
        h = hash_u32(h, sh->heading);
        h = hash_u32(h, (uint32_t)sh->energy);
        h = hash_u32(h, (uint32_t)sh->fire_cooldown[SIM_TRIG_GUN]
                            | ((uint32_t)sh->fire_cooldown[SIM_TRIG_BOMB] << 16));
        h = hash_u32(h, sh->respawn_at);
        h = hash_u32(h, sh->stall);
        h = hash_u32(h, (uint32_t)sh->kills | ((uint32_t)sh->deaths << 16));
        for (int u = 0; u < SIM_UP_COUNT; u++) h = hash_u32(h, sh->up[u]);
        for (int t = 0; t < SIM_TRIG_COUNT; t++)
            h = hash_u32(h, (uint32_t)sh->level[t] | ((uint32_t)sh->mods[t] << 8));
        for (int k = 0; k < SIM_MAX_CHARGES; k++) h = hash_u32(h, sh->charge[k]);
        /* What the next shot will be, and what the last press was. Both are
         * state: the second decides whether the next tick sees an edge, and a
         * client that guessed at it would toggle when the server did not. */
        h = hash_u32(h, sh->multi_off);
        h = hash_u32(h, sh->btn_prev);
        h = hash_u32(h, sh->run);
        h = hash_u32(h, sh->points);
        /* The kit, because a respawn re-deals from it: a client holding a
         * different one would rebuild a different ship on the tick a pilot
         * comes back, which is the loudest desync there is. */
        for (int k = 0; k < SIM_SLOT_COUNT; k++) h = hash_u32(h, sh->kit[k]);
    }
    h = hash_u32(h, s->flag_count);
    for (int i = 0; i < s->flag_count; i++) {
        const sim_flag *f = &s->flags[i];
        h = hash_u32(h, (uint32_t)f->active | ((uint32_t)f->carried << 8)
                            | ((uint32_t)f->carrier << 16)
                            | ((uint32_t)f->team << 24));
        h = hash_u32(h, (uint32_t)f->x);
        h = hash_u32(h, (uint32_t)f->y);
        h = hash_u32(h, f->cooldown);
    }
    for (uint16_t i = 0; i < s->weapon_count; i++) {
        const sim_weapon *w = &s->weapons[i];
        h = hash_u32(h, (uint32_t)w->spec | ((uint32_t)w->owner << 8)
                            | ((uint32_t)w->team << 16));
        h = hash_u32(h, (uint32_t)w->left | ((uint32_t)w->depth << 8)
                            | ((uint32_t)w->mods << 16));
        h = hash_u32(h, w->link);
        h = hash_u32(h, (uint32_t)w->x);
        h = hash_u32(h, (uint32_t)w->y);
        h = hash_u32(h, (uint32_t)w->vx);
        h = hash_u32(h, (uint32_t)w->vy);
        h = hash_u32(h, w->life);
        h = hash_u32(h, (uint32_t)(w->fuse_target | (w->fuse << 8)));
        h = hash_u32(h, (uint32_t)w->near);
        h = hash_u32(h, (uint32_t)(w->level | (w->shrap_level << 8)
                                   | (w->shrap_bounce << 16)));
    }
    return h;
}
