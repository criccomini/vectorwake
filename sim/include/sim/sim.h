/* vectorwake simulation core.
 *
 * Deterministic, fixed-point, allocation-free. The client, the server, and the
 * test harness all link this; docs/architecture/simulation-core.md is the
 * contract. No floats, no I/O, no globals, no allocation.
 *
 * Units:
 *   time      ticks of 1/100 s (uint32_t)
 *   position  Q8 pixels: 1/256 px (int32_t); 16 px per tile, 1024x1024 tiles
 *   velocity  Q16 pixels per tick: 1/65536 px/tick (int32_t)
 *   heading   uint16_t, 1/65536 of a turn; 0 = up (-y), increasing clockwise
 *   energy    Q10: 1/1024 energy units (int32_t)
 */
#ifndef SIM_H
#define SIM_H

#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif


#define SIM_MAX_SHIPS 64
#define SIM_MAX_WEAPONS 1024
#define SIM_MAX_PRIZES 64
#define SIM_MAX_FLAGS 16
#define SIM_TEAM_NONE 255
#define SIM_MAX_EVENTS 256
#define SIM_MAX_CLASSES 8
#define SIM_MAP_TILES 1024
#define SIM_TILE_PX 16

#define SIM_MAP_MAX_Q8 (SIM_MAP_TILES * SIM_TILE_PX * 256)

/* Input buttons. Aiming is the nose (decision 17): there is no aim field. */
#define SIM_BTN_LEFT 0x0001u
#define SIM_BTN_RIGHT 0x0002u
#define SIM_BTN_THRUST 0x0004u
#define SIM_BTN_REVERSE 0x0008u
#define SIM_BTN_FIRE 0x0010u  /* guns */
#define SIM_BTN_BOMB 0x0020u  /* bombs */
/* Spend one of the selected charge. Which one is selected is *not* in here
 * and is not simulation state: the client picks a slot and says which, so
 * cycling a selection needs no edge detection down here and no byte in a
 * snapshot. Two bits is four slots, which is what a pilot can carry. */
#define SIM_BTN_USE 0x0040u
#define SIM_BTN_SLOT_SHIFT 7
#define SIM_BTN_SLOT_MASK 0x0180u
#define SIM_BTN_SLOT(b) (((b) & SIM_BTN_SLOT_MASK) >> SIM_BTN_SLOT_SHIFT)

/* What a tile does. The original encoded behaviour in the tile's own number
 * -- doors at 162 through 169, a safe zone at 171, scenery you fly under at
 * 176 through 190 -- so every rule in the engine was a range check against a
 * magic constant, and a map editor had to know all of them.
 *
 * Here a tile is its behaviour and nothing else. How it is drawn is the
 * client's business, which is why there are nine of these rather than 190.
 *
 * The byte is class in the low nibble and a variant in the high one: doors
 * use the variant as a channel, so a map can open one set while another
 * closes, and goals use it as the team that scores there. */
#define SIM_TILE_CLASS(t) ((t) & 0x0f)
#define SIM_TILE_VARIANT(t) ((t) >> 4)
#define SIM_TILE(cls, var) ((uint8_t)(((var) << 4) | (cls)))

typedef enum {
    SIM_TILE_EMPTY = 0,
    SIM_TILE_SOLID,      /* wall */
    SIM_TILE_SAFE,       /* no damage, no firing, and the one place you stop */
    SIM_TILE_DOOR,       /* wall on a clock, by variant */
    SIM_TILE_GOAL,       /* a mode's target; the core only reports entry */
    SIM_TILE_WORMHOLE,   /* pulls anything near it */
    SIM_TILE_OVER,       /* scenery drawn over the ships, never solid */
    SIM_TILE_UNDER,      /* scenery drawn under them */
    SIM_TILE_TURF,       /* a flag stand a mode can find */
    SIM_TILE_SPAWN,      /* where a ship of the variant's team starts */
    SIM_TILE_COUNT
} sim_tile;

/* Tiles a rule has to reach without walking a million of them every tick.
 * Filled by sim_map_index once, after the tiles are set. */
typedef struct {
    uint16_t tx, ty;
    uint8_t kind;      /* sim_tile */
    uint8_t variant;
} sim_feature;

#define SIM_MAX_FEATURES 256

typedef struct {
    uint8_t tile[SIM_MAP_TILES * SIM_MAP_TILES];
    uint16_t feature_count;
    sim_feature features[SIM_MAX_FEATURES];
} sim_map;

/* Walk the tiles once and collect the ones rules need to find: wormholes to
 * pull from, goals to score in, turf to stand a flag on. Call after building
 * or loading a map, before stepping it. */
void sim_map_index(sim_map *m);

/* The reference arenas, in the core so the client and the server cannot hold
 * different ideas of the same room. They used to be the same magic numbers
 * written out in C++ and in Rust, which is one edit away from a client that
 * predicts collisions against a wall the server does not have. */
uint8_t sim_tile_at(const sim_map *m, int32_t tx, int32_t ty);
int sim_in_safe(const sim_map *m, int32_t x, int32_t y);

/* Where a ship of this team starts, as a tile. `nth` walks the map's spawn
 * points in order and wraps, so a roster spreads across them instead of
 * stacking on one. Returns 0 when the map names none, which is the signal to
 * fall back to whatever the zone configured.
 *
 * A map that carries its own spawns is a map that can be dropped into a zone
 * without the zone knowing anything about its geometry. Without this,
 * pointing a zone at a new map put every ship outside its walls. */
int sim_map_spawn(const sim_map *m, uint8_t team, uint32_t nth,
                  uint16_t *tx, uint16_t *ty);

void sim_map_arena(sim_map *m);
void sim_map_duel(sim_map *m);

/* ---- weapons ----
 *
 * One model for everything that leaves a ship, in two halves.
 *
 * A *pattern* is what pressing a trigger makes: how many projectiles, how far
 * apart, at what cost. A *spec* is what one projectile is: how it flies, what
 * ends it, and what happens where it ends. A spec's splinter names another
 * pattern, and that recursion is the whole trick -- a burst is a pattern of
 * sixteen at a full turn's spacing, a spread is three at twenty degrees, and
 * shrapnel is a bomb whose ending fires a burst. Three features in the
 * original; one mechanism here.
 *
 * Two things stay out deliberately. Appearance is the client's, keyed by spec
 * id in its own table -- the simulation carries no colours, exactly as a tile
 * class carries no picture. And nothing here is per-shot random: the angles
 * come out of the table, so a rosette is the same rosette on every machine.
 */
/* Room for a ladder per trigger per hull, and a zone's own weapons on top.
 * The roster alone is twenty-three rungs. */
#define SIM_MAX_SPECS 64
#define SIM_MAX_PATTERNS 64
#define SIM_NO_PATTERN 255
/* One generation of fragments. Sixteen become two hundred and fifty-six
 * become four thousand, and the weapon table holds a thousand. */
#define SIM_MAX_SPLINTER_DEPTH 1

/* The two triggers a hull has. Everything a pilot upgrades is per trigger,
 * so bullets that freeze and bombs that do not is a thing you can hold. */
#define SIM_TRIG_GUN 0
#define SIM_TRIG_BOMB 1
#define SIM_TRIG_COUNT 2

/* ---- what a pilot does to a weapon ----
 *
 * A weapon has a *level* and a set of *add-ons*, and they are different
 * things. A level is the same weapon, harder: a rung on a ladder of patterns
 * the hull carries, and climbing it swaps which one the trigger fires. An
 * add-on changes the weapon's character, and it cannot be a rung -- three
 * levels against six on/off add-ons is a hundred and ninety-two rows for one
 * weapon, and the table holds thirty-two. So an add-on is a *transform*
 * applied to the rung, at the moment of firing.
 *
 * Each add-on is a count rather than a flag, two bits wide, so a pilot can
 * hold three rungs of shrapnel the same way they hold three rungs of speed.
 * Twelve bits of add-on fit one word, which is what a projectile carries.
 */
typedef enum {
    SIM_MOD_MULTI = 0,   /* more projectiles per shot, fanned */
    SIM_MOD_BOUNCE,      /* walls reflect it */
    SIM_MOD_PROX,        /* a fuse, so it goes off near rather than on */
    SIM_MOD_SHRAPNEL,    /* its ending fires the zone's fragment pattern */
    SIM_MOD_FREEZE,      /* it stalls the recharge of whoever it reaches */
    SIM_MOD_PUSH,        /* it shoves: a repel, welded onto something else */
    SIM_MOD_COUNT
} sim_mod;

#define SIM_MOD_MAX 3    /* rungs per add-on; two bits each */
#define SIM_MAX_RUNGS 4  /* levels a weapon ladder can hold */

/* ---- charges ----
 *
 * A charge is a weapon you carry a count of and spend, rather than one a
 * trigger fires for free: a repel, a burst, a portal. It needs no new
 * mechanism at all -- it is a pattern, exactly like a gun's, plus an
 * inventory. The whole of a repel is `push` with no damage, which the model
 * has had since the day it was written.
 *
 * Four kinds, zone-wide, so slot two means the same weapon for everybody and
 * a zone can weight "the odds of finding a burst". What each hull may carry
 * is its own row, the same way add-ons work. */
#define SIM_MAX_CHARGES 4
#define SIM_CHARGE_MAX 15  /* how many of one kind a pilot can hold */

/* The slot field in the buttons and the number of charge kinds are two halves
 * of one fact. Raising SIM_MAX_CHARGES without widening the field would leave
 * the top slots quietly unreachable, so say it here and fail to compile
 * instead. */
typedef char sim_slot_field_is_wide_enough[
    ((SIM_BTN_SLOT_MASK >> SIM_BTN_SLOT_SHIFT) + 1 >= SIM_MAX_CHARGES) ? 1 : -1];

/* Add-on counts pack two bits each into one word, on the ship and on every
 * projectile it fires. */
static inline uint8_t sim_mod_get(uint16_t mods, int m) {
    return (uint8_t)((mods >> (m * 2)) & 3u);
}
static inline uint16_t sim_mod_set(uint16_t mods, int m, uint8_t n) {
    return (uint16_t)((mods & ~(3u << (m * 2))) | ((uint32_t)(n & 3u) << (m * 2)));
}

typedef enum {
    SIM_WALL_END = 0,   /* stop, and do whatever ending does */
    SIM_WALL_BOUNCE,    /* reflect, spending one of the spec's bounces */
    SIM_WALL_PASS       /* ignore walls entirely */
} sim_wall_rule;

typedef struct {
    /* flight */
    int32_t speed;        /* Q16 px/tick, along the firing heading */
    uint16_t life;        /* ticks before it runs out */
    uint8_t on_wall;      /* sim_wall_rule */
    uint8_t bounces;      /* walls survived, when bouncing */
    /* arrival: what counts as having got somewhere */
    int32_t trigger;      /* Q8 px from a hull; 0 is contact */
    uint8_t expire_ends;  /* whether running out of life also counts */
    uint8_t splinter;     /* a pattern fired where it ended, or SIM_NO_PATTERN */
    /* ending */
    int32_t damage;       /* Q10 energy at the centre */
    int32_t blast;        /* Q8 px; 0 means the damage lands on one hull */
    int32_t push;         /* Q16 px/tick shoved outward at the centre */
    uint16_t stall;       /* ticks of suppressed recharge on whoever it hits */
} sim_weapon_spec;

typedef struct {
    uint8_t spec;
    uint8_t count;        /* projectiles per shot */
    uint16_t spacing;     /* heading units between them; 65536 is a full turn */
    int32_t energy;       /* Q10 to fire */
    uint16_t delay;       /* ticks of cooldown */
    int32_t recoil;       /* Q16 px/tick backwards on the ship that fired */
} sim_fire_pattern;

/* Prizes, the original's "greens": fly over one and the ship improves until
 * it dies. Every upgrade is a count, and the effective stat is the initial
 * value plus that many increments, capped by the class maximum. */
typedef enum {
    SIM_UP_ENERGY = 0,
    SIM_UP_RECHARGE,
    SIM_UP_SPEED,
    SIM_UP_THRUST,
    SIM_UP_ROTATION,
    SIM_UP_COUNT
} sim_upgrade;

/* ---- what a green can be ----
 *
 * One flat space, because the whole tech tree is one shape: a count with a
 * ceiling. A stat count interpolates a range, a level count indexes a
 * ladder, an add-on count transforms what a trigger fires. The zone weights
 * this space to decide what its greens are; the client colours and names
 * from it; a prize carries one byte of it.
 *
 *   0 .. 4     a stat            sim_upgrade
 *   5 .. 6     a level           per trigger
 *   7 .. 18    an add-on         per trigger, per sim_mod
 *  19 .. 22    a charge          per kind
 */
#define SIM_PRIZE_STAT(u)     (u)
#define SIM_PRIZE_LEVEL(t)    (SIM_UP_COUNT + (t))
#define SIM_PRIZE_MOD(t, m)   (SIM_UP_COUNT + SIM_TRIG_COUNT \
                               + (t) * SIM_MOD_COUNT + (m))
#define SIM_PRIZE_CHARGE(k)   (SIM_UP_COUNT + SIM_TRIG_COUNT \
                               + SIM_TRIG_COUNT * SIM_MOD_COUNT + (k))
#define SIM_PRIZE_COUNT       (SIM_UP_COUNT + SIM_TRIG_COUNT \
                               + SIM_TRIG_COUNT * SIM_MOD_COUNT \
                               + SIM_MAX_CHARGES)
#define SIM_PRIZE_NONE 255


/* Per-class tuning in core units. sim_class_from_units fills this from
 * settings-file units. */
typedef struct {
    /* Each stat has a floor a fresh ship starts at, a ceiling upgrades climb
     * toward, and the step one prize adds. */
    int32_t max_speed, init_speed, up_speed;       /* Q16 px/tick */
    int32_t thrust, init_thrust, up_thrust;        /* Q16 px/tick^2 */
    int32_t rot, init_rot, up_rot;                 /* heading units per tick */
    int32_t max_energy, init_energy, up_energy;    /* Q10 */
    int32_t recharge, init_recharge, up_recharge;  /* Q10 per tick */
    int32_t radius;                                /* Q8 px */

    /* What the two triggers fire: a ladder of patterns per trigger, climbed
     * by the pilot's level. Rung zero is what a fresh hull carries, and
     * SIM_NO_PATTERN ends the ladder -- so a hull with no bomb rack has
     * SIM_NO_PATTERN at rung zero, and the length of a ladder is the hull's
     * ceiling for that weapon without a second number to keep in step. */
    uint8_t trigger[SIM_TRIG_COUNT][SIM_MAX_RUNGS];
    /* Add-ons this hull may hold on each trigger, packed as counts the same
     * way the pilot's are. Zero is a hull that never gets that add-on, which
     * is how the roster stays a roster: shrapnel belongs to bombers. */
    uint16_t mod_max[SIM_TRIG_COUNT];
    /* How many of each charge kind this hull may carry. Zero is a hull that
     * never gets one, which is how a repel stays the denial ship's thing. */
    uint8_t charge_max[SIM_MAX_CHARGES];
} sim_ship_class;

typedef struct {
    sim_ship_class classes[SIM_MAX_CLASSES];
    uint8_t class_count;
    /* Every weapon in the zone, and every way of firing one. */
    sim_weapon_spec specs[SIM_MAX_SPECS];
    sim_fire_pattern patterns[SIM_MAX_PATTERNS];
    uint8_t spec_count;
    uint8_t pattern_count;
    /* What each charge kind fires, as a pattern index, or SIM_NO_PATTERN for
     * a slot this zone does not use. Zone-wide rather than per hull, so a
     * charge means the same thing to everybody who has one. */
    uint8_t charge[SIM_MAX_CHARGES];
    /* Odds a green turns out to be each thing, over the flat prize space.
     * Relative rather than percentages -- doubling every number changes
     * nothing -- and read against the pool of the hull that took it, so what
     * a zone writes is the shape of the tree rather than its arithmetic. */
    uint16_t prize_weight[SIM_PRIZE_COUNT];
    /* Out of a thousand, how often a green corrodes something instead of
     * granting it. Rust can only take what a pilot is actually holding, so a
     * fresh one is never punished for arriving; when there is nothing to take
     * the green is an ordinary upgrade. */
    uint16_t rust_chance;
    /* What one rung of each add-on is worth. Units are the field it changes:
     * extra projectiles, walls, Q8 px of fuse, ticks of stall, Q16 push. */
    int32_t mod_step[SIM_MOD_COUNT];
    /* Spacing a multifire add-on fans to, when the pattern has none of its
     * own. A pattern that already spreads keeps its own angle. */
    uint16_t mod_spread;
    /* What each rung of shrapnel breaks into. Shrapnel is the one add-on
     * whose magnitude is another weapon rather than a number. */
    uint8_t mod_splinter[SIM_MAX_RUNGS];
    int32_t bounce;   /* restitution on the axis that hit, out of 16 */
    int32_t friction; /* retained speed along the wall, out of 16 */
    uint16_t respawn_delay; /* ticks dead before respawn */
    uint16_t prize_delay;  /* ticks between prize spawns */
    uint16_t prize_max;    /* prizes alive on the map at once */
    uint16_t prize_life;   /* ticks a prize waits to be collected */
    /* Doors. A cycle is open then shut; variant n leads by n eighths of it,
     * so one map can breathe rather than blink. */
    uint16_t door_period;  /* ticks for a full cycle; 0 leaves doors shut */
    uint16_t door_open;    /* ticks of that cycle a door stands open */
    int32_t wormhole_pull;   /* Q16 px/tick^2 at the mouth */
    int32_t wormhole_range;  /* Q8 px, beyond which it does not reach */
    int32_t prize_radius;  /* Q8 px, pickup distance */
    int32_t prize_lo, prize_hi; /* tile bounds prizes spawn within */
    int32_t flag_radius;    /* Q8 px, pickup distance */
    uint16_t flag_drop_cooldown; /* ticks a dropped flag is untouchable */
    const sim_map *map;    /* geometry; not part of rolled-back state */
} sim_settings;

typedef struct {
    uint8_t active;
    uint8_t alive;
    uint8_t cls;   /* index into settings.classes */
    uint8_t team;
    int32_t x, y;
    int32_t vx, vy;
    uint16_t heading;
    int32_t energy;        /* Q10 */
    uint16_t fire_cooldown;
    uint16_t stall;   /* ticks of suppressed recharge; what a stall round does */
    uint16_t respawn_at;    /* ticks remaining while dead */
    int32_t spawn_x, spawn_y;
    uint16_t kills, deaths;
    uint8_t up[SIM_UP_COUNT];  /* stat upgrades held; cleared by death */
    /* The rung each trigger is on, and the add-ons held on each. Cleared by
     * death with everything else: what you are carrying is what you have
     * survived with. */
    uint8_t level[SIM_TRIG_COUNT];
    uint16_t mods[SIM_TRIG_COUNT];
    /* Charges in hand, spent one at a time. */
    uint8_t charge[SIM_MAX_CHARGES];
} sim_ship;

/* A green carries no type. Every green is takeable by everybody, and what it
 * turns out to be is rolled where it is picked up, from what that hull could
 * ever hold -- so there is no such thing as a green with somebody else's name
 * on it, and every one of them is worth crossing the map for. */
typedef struct {
    uint8_t active;
    int32_t x, y;   /* Q8 px */
    uint16_t life;  /* ticks remaining */
} sim_prize;

/* Every prize id this hull could ever be handed, into `out` (which must hold
 * SIM_PRIZE_COUNT), returning how many. This is the roster's half of the tech
 * tree: a hull whose ladder is one rung deep is never offered a level, and one
 * whose row allows no shrapnel is never offered shrapnel. */
int sim_prize_pool(const sim_ship_class *c, uint8_t *out);

/* Roll what a green is for this pilot, apply it, and return which it was.
 * `delta` comes back +1 for an upgrade and -1 for rust.
 *
 * The roll is over what the hull could *ever* hold rather than what it can
 * still take, so a pilot at the ceiling is told what they found and the count
 * simply does not move -- a green that is eaten in silence is a green that
 * lies. Advances `rng` in place, which is state, which is why the roll can
 * happen here at all and still be the same roll on both machines. */
uint8_t sim_take_prize(sim_ship *sh, const sim_settings *cfg, uint32_t *rng,
                       int *delta);

/* Flags. The core owns pickup, carry, and drop, exactly as the original's
 * flagcore did; which arrangement of flags wins a round is a game mode's
 * business and lives outside the simulation. */
typedef struct {
    uint8_t active;
    uint8_t carried;      /* 1 while a ship is holding it */
    uint8_t carrier;      /* ship index while carried */
    uint8_t team;         /* owning team, or SIM_TEAM_NONE */
    int32_t x, y;         /* Q8 px; tracks the carrier while carried */
    uint16_t cooldown;    /* ticks before it may be picked up again */
} sim_flag;

typedef struct {
    uint8_t spec;  /* index into the settings' spec table */
    uint8_t owner; /* ship index */
    uint8_t team;
    uint8_t left;  /* bounces remaining, when the spec bounces */
    uint8_t depth; /* splinter generations behind it; a fork-bomb stop */
    /* The add-ons of the trigger that fired it, so a shot is what it was
     * when it left rather than what its owner is carrying now. A bomb thrown
     * while you had shrapnel still breaks up after you are dead. */
    uint16_t mods;
    int32_t x, y;
    int32_t vx, vy;
    uint16_t life; /* ticks remaining */
} sim_weapon;

typedef enum {
    SIM_EV_FIRE = 1,
    SIM_EV_BOUNCE,   /* a: ship, b: unused */
    SIM_EV_HIT,      /* a: victim, b: attacker, v: damage Q10 */
    SIM_EV_DEATH,    /* a: victim, b: killer (255 = none) */
    SIM_EV_SPAWN,    /* a: ship */
    /* A weapon stopped existing: it ran out of life, hit a wall, or struck a
     * ship. The position is where, which is the only report of it there is:
     * by the time a caller looks, the weapon is gone from the state. Whole
     * pixels, packed (x << 14) | y. */
    SIM_EV_EXPIRE,   /* a: weapon type, b: owner, v: packed position */
    SIM_EV_PRIZE,    /* a: ship, b: sim_upgrade collected */
    /* A charge was spent. b is the slot, v is how many are left, which is
     * what a panel wants and what a sound wants to know it happened. */
    SIM_EV_CHARGE,
    SIM_EV_FLAG_TAKE,/* a: ship, b: flag index */
    SIM_EV_FLAG_DROP,/* a: flag index, b: team that keeps it */
    SIM_EV_GOAL,     /* a: ship, b: the goal's variant */
    SIM_EV_WARP      /* a: ship caught by a closing door, sent home */
} sim_event_type;

typedef struct {
    uint8_t type;
    uint8_t a, b;
    int32_t v;
} sim_event;

/* Flat, pointer-free, memcpy-able. Copying this struct is a rollback. */
typedef struct {
    uint32_t tick;
    uint32_t rng;
    uint8_t ship_count;
    uint16_t weapon_count;
    uint16_t prize_timer;
    sim_ship ships[SIM_MAX_SHIPS];
    sim_weapon weapons[SIM_MAX_WEAPONS];
    sim_prize prizes[SIM_MAX_PRIZES];
    sim_flag flags[SIM_MAX_FLAGS];
    uint8_t flag_count;
} sim_state;

typedef struct {
    uint8_t ship;
    uint16_t buttons;
} sim_input;

/* Events produced by one step. Truncated at SIM_MAX_EVENTS; overflow is
 * counted so a caller can tell the difference between quiet and clipped. */
typedef struct {
    uint16_t count;
    uint16_t dropped;
    sim_event e[SIM_MAX_EVENTS];
} sim_events;

void sim_init(sim_state *s, uint32_t seed);

/* Add a ship. Returns its index, or -1 if full. */
/* Append a projectile spec, or a way of firing one, and hand back its index.
 * Both return -1 when the table is full. A pattern names a spec; a spec's
 * splinter names a pattern, which is how one ending fires the next. */
int sim_add_spec(sim_settings *cfg, const sim_weapon_spec *spec);
int sim_add_pattern(sim_settings *cfg, const sim_fire_pattern *pattern);

int sim_spawn(sim_state *s, uint8_t cls, uint8_t team, int32_t x_px,
              int32_t y_px, uint16_t heading, const sim_settings *cfg);

/* Put a pilot in a different hull. A respawn, not a costume change: back to
 * your start at rest, a full bar of the new ship, upgrades gone, anything you
 * were carrying dropped -- and the team, the arena, and everyone else in it
 * untouched.
 *
 * Only from a full bar and only alive, because a fresh ship is a full bar:
 * ungated, changing hull is a way out of a fight you are losing. Asking for
 * the hull you are already in does nothing and succeeds.
 *
 * Returns 0, or -1 for an unknown ship or class, a dead pilot, or one who is
 * not at full energy. */
int sim_set_ship_class(sim_state *s, const sim_settings *cfg, uint8_t i,
                       uint8_t cls);

void sim_step(sim_state *next, const sim_state *prev, const sim_input *inputs,
              uint16_t input_count, const sim_settings *cfg, sim_events *ev);

uint64_t sim_hash(const sim_state *s);

/* Settings-file units to core units. The settings file uses integer scales
 * with implied denominators; these are the only place that mapping lives. */
/* Whether a door of this variant stands open on this tick. */
int sim_door_open(const sim_settings *cfg, uint32_t tick, uint8_t variant);

int32_t sim_units_speed(int32_t v);    /* px/s/10 -> Q16 px/tick */
int32_t sim_units_thrust(int32_t t);   /* -> Q16 px/tick^2 */
int32_t sim_units_rotation(int32_t r); /* r/400 turns/s -> units/tick */
int32_t sim_units_energy(int32_t e);   /* energy units -> Q10 */
int32_t sim_units_recharge(int32_t r); /* r/10 energy per second -> Q10/tick */

/* Fill a class from settings-file units. Initial values start at `init_pct`
 * percent of maximum and eight prizes climb the rest of the way. */
void sim_class_from_units(sim_ship_class *c, int32_t speed, int32_t thrust,
                          int32_t rotation, int32_t energy, int32_t recharge,
                          int32_t radius_px);

/* Effective stats after upgrades. The client HUD and the AI both ask. */
int32_t sim_eff_speed(const sim_ship_class *c, const sim_ship *s);
int32_t sim_eff_thrust(const sim_ship_class *c, const sim_ship *s);
int32_t sim_eff_rot(const sim_ship_class *c, const sim_ship *s);
int32_t sim_eff_max_energy(const sim_ship_class *c, const sim_ship *s);
int32_t sim_eff_recharge(const sim_ship_class *c, const sim_ship *s);

/* Place a flag. Returns its index, or -1 if the arena is full. */
int sim_add_flag(sim_state *s, int32_t x_px, int32_t y_px);

/* How many flags a team holds, counting carried and grounded alike. */
int sim_flags_held(const sim_state *s, uint8_t team);

#ifdef __cplusplus
}
#endif

#endif
