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

typedef enum {
    SIM_W_NONE = 0,
    SIM_W_BULLET,
    SIM_W_BOMB
} sim_weapon_type;

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

    int32_t bullet_speed;  /* Q16 px/tick */
    int32_t bullet_energy; /* Q10 cost per shot */
    uint16_t bullet_delay; /* ticks between shots */
    uint16_t bullet_life;  /* ticks before expiry */
    int32_t bullet_damage; /* Q10 */

    int32_t bomb_speed;
    int32_t bomb_energy;
    uint16_t bomb_delay;
    uint16_t bomb_life;
    int32_t bomb_damage;
    int32_t bomb_radius;  /* Q8 px, blast radius */
    int32_t bomb_thrust;  /* Q16 px/tick recoil */
} sim_ship_class;

typedef struct {
    sim_ship_class classes[SIM_MAX_CLASSES];
    uint8_t class_count;
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
    uint16_t fire_cooldown; /* ticks until the next shot may be fired */
    uint16_t respawn_at;    /* ticks remaining while dead */
    int32_t spawn_x, spawn_y;
    uint16_t kills, deaths;
    uint8_t up[SIM_UP_COUNT];  /* upgrades held; cleared by death */
} sim_ship;

typedef struct {
    uint8_t active;
    uint8_t type;   /* sim_upgrade */
    int32_t x, y;   /* Q8 px */
    uint16_t life;  /* ticks remaining */
} sim_prize;

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
    uint8_t type;  /* sim_weapon_type */
    uint8_t owner; /* ship index */
    uint8_t team;
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
int sim_spawn(sim_state *s, uint8_t cls, uint8_t team, int32_t x_px,
              int32_t y_px, uint16_t heading, const sim_settings *cfg);

/* Put a pilot in a different hull. A respawn, not a costume change: back to
 * your start at rest, a full bar of the new ship, upgrades gone, anything you
 * were carrying dropped -- and the arena and everyone in it untouched.
 * Returns 0, or -1 for an unknown ship or class. */
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
