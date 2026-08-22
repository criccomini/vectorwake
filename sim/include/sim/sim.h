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


/* Ships a room can ever hold. 255 is the wire's ceiling, not a preference: a
 * ship index is a uint8_t everywhere it appears -- a projectile's owner, an
 * input's target, a kill event's victim and killer -- and 255 is already the
 * "no ship" sentinel in those fields, so indices run 0 to 254.
 *
 * This is the array bound and not the room size. What a zone actually allows is
 * `sim_settings.max_ships`, which is what sim_spawn enforces, because a room
 * that plays well is a game design question and this is a memory allocation.
 * At the ceiling a state is 51 KB against 37 KB at 64, and a tick costs 50 us
 * against 13.5. See docs/architecture/hosting.md. */
#define SIM_MAX_SHIPS 255
#define SIM_MAX_WEAPONS 1024
#define SIM_MAX_FLAGS 16
#define SIM_TEAM_NONE 255
#define SIM_MAX_EVENTS 256
#define SIM_MAX_CLASSES 7
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
/* Multifire on or off, toggled on the press rather than held.
 *
 * The original made this a key because a fan is not always what you want: it
 * costs more energy and more cooldown per rung, and a single barrel is the
 * shot that hits something small and far away. A pilot who has picked the
 * upgrade up should be able to decline to use it without dropping it.
 *
 * Edge-triggered inside the core rather than pulsed by the client, so a lost
 * input cannot leave the two ends disagreeing about a piece of ship state. */
#define SIM_BTN_MULTI 0x0200u
#define SIM_BTN_SLOT_SHIFT 7
#define SIM_BTN_SLOT_MASK 0x0180u
#define SIM_BTN_SLOT(b) (((b) & SIM_BTN_SLOT_MASK) >> SIM_BTN_SLOT_SHIFT)

/* What a tile does. The original encoded behavior in the tile's own number
 * -- doors at 162 through 169, a safe zone at 171, scenery you fly under at
 * 176 through 190 -- so every rule in the engine was a range check against a
 * magic constant, and a map editor had to know all of them.
 *
 * Here a tile is its behavior and nothing else. How it is drawn is the
 * client's business, which is why there are ten of these rather than 190.
 *
 * The byte is class in the low nibble and a variant in the high one: doors
 * use the variant as a channel, so a map can open one set while another
 * closes, goals use it as the team that scores there, and a slope uses it as
 * the corner the tile is filled from. */
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
    SIM_TILE_SLOPE,      /* half a wall, cut corner to corner, by variant */
    SIM_TILE_COUNT
} sim_tile;

/* Which corner of its tile a slope fills, and so which way its face points.
 *
 * A wall drawn diagonally out of square tiles is a staircase, and a staircase
 * is not a shape a ship can fly along: every step is a fresh axis-aligned
 * bounce, so a hull skimming one rattles down it instead of sliding. A slope
 * is the same wall with the steps cut off. Two of these meeting at a corner
 * make one continuous 45 degree face however long the run is.
 *
 * The four are named for the corner that stays solid, so the face is the
 * diagonal opposite it. Reflecting off a 45 degree plane costs no table and no
 * root: the face through NW and SE turns a velocity into (vy, vx), and the one
 * through NE and SW turns it into (-vy, -vx). Both are exact in fixed point,
 * which is the whole reason the slope is 45 degrees and not an arbitrary
 * angle. */
#define SIM_SLOPE_NW 0
#define SIM_SLOPE_NE 1
#define SIM_SLOPE_SE 2
#define SIM_SLOPE_SW 3

/* Tiles a rule has to reach without walking a million of them every tick.
 * Filled by sim_map_index once, after the tiles are set. */
typedef struct {
    uint16_t tx, ty;
    uint8_t kind;      /* sim_tile */
    uint8_t variant;
} sim_feature;

#define SIM_MAX_FEATURES 256

/* A map is `w` by `h` tiles of the square below, laid out at the full stride
 * so the array never moves and nothing allocates.
 *
 * The size is the map's own rather than the engine's because a 144-tile match
 * room and a 1024-tile arena are not the same room with different furniture.
 * Before this the small ones were drawn as a hole in a solid megabyte: every
 * pass over the map paid for the 1024 square whatever it held, the overview
 * drew a match map as a speck in a black field, and "how big is this map" had
 * no answer to ask for. Outside the declared rect `sim_tile_at` answers solid,
 * so the world ends at the edge a map says it has. */
typedef struct {
    uint8_t tile[SIM_MAP_TILES * SIM_MAP_TILES];
    uint16_t w, h;
    uint16_t feature_count;
    sim_feature features[SIM_MAX_FEATURES];
} sim_map;

/* The stride of the tile array, which is not the map's width. A row starts
 * every SIM_MAP_TILES tiles whatever `w` says, so indexing is a constant and
 * resizing a map moves nothing. */
#define SIM_MAP_AT(m, tx, ty) ((m)->tile[(size_t)(ty) * SIM_MAP_TILES + (size_t)(tx)])

/* Set a map's size and clear it to empty. Call before drawing one; a zeroed
 * map has no size, and a map with no size is solid everywhere.
 *
 * Clamped to SIM_MAP_TILES, and refused below the boundary the index paints,
 * since a map smaller than its own walls is a map with no inside. */
void sim_map_size(sim_map *m, int w, int h);

/* Make a map ready to play, which is two things.
 *
 * It closes the world: four tiles of boundary around the declared rect,
 * whatever the map said was there. Every map wants one, so a map that had to
 * carry its own is a map that can be missing it, and a converted one always
 * is. Four tiles
 * and not one, because a hull at full speed crosses more than a tile in a tick
 * and axis-by-axis collision cannot push it back out of a wall it has already
 * passed through.
 *
 * Then it walks the tiles once and collects the ones rules need to find:
 * wormholes to pull from, goals to score in, turf to stand a flag on.
 *
 * Call after building or loading a map, before stepping it. `sim_map_unpack`
 * and the reference maps below already do. */
void sim_map_index(sim_map *m);

/* Whether a map can be flown, asked of a hull rather than of a point.
 *
 * Three callers want the same answer and a second opinion about a map is worth
 * nothing: the generator refuses to write a map that fails, the meta-layer
 * refuses to store one, and an editor says what is wrong while somebody is
 * still drawing. sim/src/check.c has the reasoning; the short version is that
 * a hull is three tiles across, so the connectivity of a map is not the
 * connectivity of its open tiles.
 *
 * The scratch is the caller's because the core does not allocate. It is nine
 * megabytes and only the tools and the panel ever build one, which is why it
 * is a struct to hand in rather than a static to trip over. */
typedef struct {
    int32_t regions;         /* separate places a hull can fly, doors shut */
    int32_t reachable;       /* tiles a hull's center fits in the largest one */
    int32_t stranded;        /* open tiles no hull can reach, doors open */
    int32_t spawns;          /* starts the map names */
    int32_t spawns_team[2];  /* and how they are split */
    int32_t spawns_stranded; /* starts a ship could not leave */
    int32_t solid;           /* wall, slopes counted whole */
    int32_t open;            /* everything a ship flies through */
} sim_map_report;

typedef struct {
    uint8_t nav[SIM_MAP_TILES * SIM_MAP_TILES];
    int32_t comp[SIM_MAP_TILES * SIM_MAP_TILES];
    int32_t stack[SIM_MAP_TILES * SIM_MAP_TILES];
} sim_map_scratch;

void sim_map_check(const sim_map *m, sim_map_scratch *s, sim_map_report *r);

/* Whether that report is a map worth serving, and why not when it is not.
 * `why` takes a sentence naming the first thing wrong with it, which is a
 * message for whoever drew it rather than a code to look up. */
int sim_map_playable(const sim_map *m, const sim_map_report *r, char *why, int cap);
/* `m` is unused today and named anyway: every future rule this could grow
 * (a size a mode needs, a spawn count a roster wants) is a question about the
 * map rather than about the count of what is in it. */

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

/* Sizes of the structs a foreign binding has to mirror.
 *
 * The server keeps a `#[repr(C)]` copy of `sim_state`, allocates it, and hands
 * the pointer to `sim_step`. If its copy is smaller than this one -- one array
 * bound left behind, one field missed -- the core writes past the end of the
 * allocation and the failure is heap corruption a long way from the cause. It
 * has happened twice: a field inserted in the middle, and a table bound
 * raised from 64. Neither is a compile error on the far side, so the far side
 * asserts against these instead. */
uint32_t sim_sizeof_state(void);
/* Where max_ships sits. A mirror in another language cannot rely on sizeof to
 * catch a missing or misplaced field: this one landed inside existing padding,
 * so the struct did not grow by a byte when it was added. */
uint32_t sim_offsetof_settings_max_ships(void);
uint32_t sim_sizeof_settings(void);
uint32_t sim_sizeof_ship(void);
uint32_t sim_sizeof_events(void);
/* The map too, since the server allocates one and hands the core the pointer
 * to fill. It grew a size of its own, which is exactly the kind of change that
 * leaves a mirror a field short and writes past the end of somebody's box. */
uint32_t sim_sizeof_map(void);

void sim_map_arena(sim_map *m);
void sim_map_pit(sim_map *m);

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
 * id in its own table -- the simulation carries no colors, exactly as a tile
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
 * Fourteen bits of add-on fit one word, which is what a projectile carries.
 */
typedef enum {
    SIM_MOD_MULTI = 0,   /* more projectiles per shot, fanned */
    SIM_MOD_BOUNCE,      /* walls reflect it */
    SIM_MOD_PROX,        /* a fuse, so it goes off near rather than on */
    SIM_MOD_SHRAPNEL,    /* its ending fires the zone's fragment pattern */
    SIM_MOD_FREEZE,      /* it stalls the recharge of whoever it reaches */
    SIM_MOD_PUSH,        /* it shoves: a repel, welded onto something else */
    /* More barrels, abreast rather than fanned. This was DoubleBarrel, a
     * per-hull flag the Terrier alone carried, and it is an add-on now for
     * the reason everything else here is one: a trait only one hull may hold
     * is a trait the shop can never sell, and the hull rows were the only
     * thing standing between a pilot and the upgrade they wanted to buy.
     *
     * It adds to the count rather than multiplying it, which is what made
     * the original's odd arithmetic fall out: two abreast plus a rung of
     * multifire is four rounds, not six. It keeps its own tight spacing, so
     * a pair reads as a pair and not as a cheap rung of multifire, and it
     * pays energy without paying cooldown. That is the whole difference
     * between the two: multifire is a wide fan that slows your rate, barrels
     * are a tight group that does not. Neither dominates. */
    SIM_MOD_BARREL,
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
/* The charge kinds this game ships, and the reason a mine is one of them.
 * A charge is a count you carry and spend, which is what a mine always was
 * once a kit made every count explicit; it used to be the bomb trigger's
 * other posture, limited by how many of yours were already lying about. As a
 * charge it fires one pattern for everybody, so a mine means the same thing
 * in every hangar and the hull's `charge_max` row is what makes mining one
 * ship's job. */
#define SIM_CHARGE_REPEL 0
#define SIM_CHARGE_BURST 1
#define SIM_CHARGE_MINE 2
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
    /* Whether the round starts at rest instead of carrying the firer's
     * velocity. Everything that flies wants the velocity: a bullet fired
     * forwards at a run is faster over the ground than one fired from a
     * standstill, which is the rule every shot in the game has followed since
     * the model was written, so zero is that and the field is only ever set by
     * something that wants the exception.
     *
     * A mine is the exception, and it is the whole reason this exists. Its
     * speed is zero, so with the velocity added it does not sit anywhere: it
     * leaves the rack at exactly the speed the ship was doing and keeps it
     * until a wall stops it, which is a round that happens to do no steering
     * rather than a mine. The doc called that drift for a while. It is not
     * drift, it is flight, and it made the weapon usable only from a
     * standstill. */
    uint8_t still;
    /* arrival: what counts as having got somewhere */
    int32_t trigger;      /* Q8 px from a hull center; 0 is contact */
    uint8_t expire_ends;  /* whether running out of life also counts */
    uint8_t splinter;     /* a pattern fired where it ended, or SIM_NO_PATTERN */
    /* ending */
    int32_t damage;          /* Q10 energy at the center */
    /* Damage a rung adds, which is BulletDamageUpgrade. Zero on everything
     * whose ladder is a row of separate specs, and set on the fragment, whose
     * rung is its thrower's gun rather than a ladder of its own. */
    int32_t damage_up;
    int32_t blast;        /* Q8 px; 0 means the damage lands on one hull */
    /* Blast a rung adds, for the same reason `damage_up` exists: a weapon
     * whose rung comes from somewhere other than a ladder of its own. A mine
     * is the one, since a charge fires one pattern and the rung it wears is
     * the pilot's bomb rung. Without it a top-rung mine is painted red and
     * goes off like a rung one, and the ramp only means anything while it
     * tells the truth about how hard a thing hits. */
    int32_t blast_up;
    int32_t push;         /* Q16 px/tick a ship is shoved outward at */
    /* How long a shoved ship keeps a speed ceiling of `push` rather than its
     * hull's own. RepelTime, and the half of a repel that makes it a repel:
     * without it the clamp takes the shove back on the very next tick, since
     * `push` is deliberately faster than any hull can fly. */
    uint16_t push_time;
    uint16_t stall;       /* ticks of suppressed recharge on whoever it hits */
} sim_weapon_spec;

typedef struct {
    uint8_t spec;
    uint8_t count;        /* projectiles per shot */
    uint16_t spacing;     /* heading units between them; 65536 is a full turn */
    int32_t energy;       /* Q10 to fire */
    /* Energy a rung adds, for a trigger whose rungs are not separate
     * patterns. A bomb ladder charges more per rung by being a pattern per
     * rung; a mine is one pattern wearing the pilot's bomb rung, so without
     * this the rung that widens its blast costs nothing extra.
     * LandmineFireEnergyUpgrade. */
    int32_t energy_up;
    uint16_t delay;       /* trigger cooldown; carried charges ignore it */
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

/* ---- the kit space ----
 *
 * One flat space, because the whole tech tree is one shape: a count with a
 * ceiling. A stat count interpolates a range, a level count indexes a
 * ladder, an add-on count transforms what a trigger fires, a charge count is
 * ammunition. A kit is a vector over this space and its budget is the sum.
 *
 *   0 .. 4     a stat            sim_upgrade
 *   5 .. 6     a level           per trigger
 *   7 .. 20    an add-on         per trigger, per sim_mod
 *  21 .. 24    a charge          per kind
 *
 * This used to be the space a green indexed, one byte per prize, rolled by
 * the server against a table of weights. Greens are gone and the space is
 * not: what was rolled at a pickup is now chosen in the hangar, and the
 * ceilings a roll respected are the ceilings a kit is validated against.
 *
 * Everything a pilot can hold lives here, which is a rule rather than an
 * observation. A trait that sat on the hull instead -- a second barrel, a
 * third bomb rung, the mine count that made one hull the mining hull -- was
 * a trait no shop could sell and no pilot could choose, and the roster was
 * carrying four of them. They are slots now. What tells the hulls apart is
 * the shape they present to a bullet, which is the one difference nobody
 * can buy. */
#define SIM_SLOT_STAT(u)     (u)
#define SIM_SLOT_LEVEL(t)    (SIM_UP_COUNT + (t))
#define SIM_SLOT_MOD(t, m)   (SIM_UP_COUNT + SIM_TRIG_COUNT \
                              + (t) * SIM_MOD_COUNT + (m))
#define SIM_SLOT_CHARGE(k)   (SIM_UP_COUNT + SIM_TRIG_COUNT \
                              + SIM_TRIG_COUNT * SIM_MOD_COUNT + (k))
#define SIM_SLOT_COUNT       (SIM_UP_COUNT + SIM_TRIG_COUNT \
                              + SIM_TRIG_COUNT * SIM_MOD_COUNT \
                              + SIM_MAX_CHARGES)
#define SIM_SLOT_NONE 255

/* Steps a stat may climb, and what a kit may spend in total. Six over five
 * stats is exactly the budget, so an all-stats kit is exactly achievable and
 * exactly exhausting; the last two steps of each are the shop's, and five at
 * eight is forty against a budget of thirty, so no purchase ever stops the
 * kit being a set of tradeoffs. docs/design/match-game.md. */
#define SIM_UP_STEPS 8
#define SIM_UP_STEPS_BASE 6
#define SIM_KIT_BUDGET 30


/* Per-class tuning in core units. sim_class_from_units fills this from
 * settings-file units. */
typedef struct {
    /* Each stat has a floor a fresh ship starts at, a ceiling upgrades climb
     * toward, and the step one kit slot adds. */
    int32_t max_speed, init_speed, up_speed;       /* Q16 px/tick */
    int32_t thrust, init_thrust, up_thrust;        /* Q16 px/tick^2 */
    int32_t rot, init_rot, up_rot;                 /* heading units per tick */
    int32_t max_energy, init_energy, up_energy;    /* Q10 */
    int32_t recharge, init_recharge, up_recharge;  /* Q10 per tick */
    /* The hull's footprint, in Q8 px from the point it turns about: how far
     * it reaches past the nose, behind the tail, and to either side. One
     * square radius stood here, and it could not be right for this roster: a
     * square that covers an Apex's nose floats its flanks eleven pixels off
     * every wall, and one that hugs the flanks buries the nose. The walls
     * collide against the world-axis box of these extents at the current
     * heading, and weapons and pickups test the oriented rectangle itself,
     * so what you hit is what is drawn, whichever way it points. */
    int32_t fore, aft, halfw;                      /* Q8 px */

    /* What the two triggers fire: a ladder of patterns per trigger, climbed
     * by the pilot's level. Rung zero is what a fresh hull carries, and
     * SIM_NO_PATTERN ends the ladder, so a hull with no bomb rack has
     * SIM_NO_PATTERN at rung zero.
     *
     * The baseline builds the same ladders for every class, because how far
     * a weapon climbs is the zone's business now and lives in `kit_ceiling`
     * below. This stays per class so a zone that wants a hull with no rack
     * can still write one, and `trigger_pattern` clamps to whatever is
     * actually here, so the two disagreeing costs a pilot points rather than
     * crashing anything. */
    uint8_t trigger[SIM_TRIG_COUNT][SIM_MAX_RUNGS];
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
    /* The most a kit may put in each slot, over the flat space above. Zero is
     * a slot this zone does not have at all, which is how "bombs do not
     * multifire here" gets said.
     *
     * Zone-wide, and that is the change worth naming. This was a row per hull:
     * which add-ons that hull could hold and how deep, how far each trigger
     * climbed, how many of each charge it carried. Seven rows meant a pilot
     * could buy an upgrade and then find the hull they wanted to fly would not
     * take it, and it meant the shop's shelf was whatever the roster happened
     * to allow rather than whatever the game has. One row for the arena ends
     * both: everything on the shelf fits in every hangar. */
    uint8_t kit_ceiling[SIM_SLOT_COUNT];
    /* What a kill adds to the killer's own bounty. Bounty is a run rather
     * than a loadout now, so this is the whole of what makes one: a fresh
     * pilot is worth `bounty_base` and each kill adds this. */
    uint16_t bounty_per_kill;
    /* What a pilot who has just spawned is worth. One, so that killing one
     * pays almost nothing and camping a spawn is not a living, which is the
     * free anti-farming property docs/design/bounty.md wants and which a kit
     * counted into bounty would have destroyed. */
    uint16_t bounty_base;
    /* Points on top of the victim's bounty for each flag they were carrying. */
    uint16_t points_per_flag;
    /* What one rung of each add-on is worth. Units are the field it changes:
     * extra projectiles, walls, Q8 px of fuse, ticks of stall, Q16 push. */
    int32_t mod_step[SIM_MOD_COUNT];
    /* Spacing a multifire add-on fans to, when the pattern has none of its
     * own. A pattern that already spreads keeps its own angle. */
    uint16_t mod_spread;
    /* What a rung of multifire adds to the cost of pulling the trigger, as a
     * percentage of the shot's own energy and cooldown. The original's
     * numbers, which are 50 and 100: three bullets for half again the energy
     * and twice the wait. */
    uint16_t mod_multi_energy;
    uint16_t mod_multi_delay;
    /* And what a rung of barrels adds to the energy, on the same scale. There
     * is no delay to match it: a barrel does not slow the gun down, which is
     * the whole reason to take one over a rung of multifire. Free rounds are
     * the balance problem the multifire note above is about, so the energy
     * half is not optional.
     *
     * `mod_barrel_spread` is the angle a pair leaves at, and it is deliberately
     * tighter than `mod_spread`: barrels are abreast and multifire is a fan.
     * It has to be nonzero, because a pattern of many at spacing zero is the
     * shrapnel encoding and scatters. */
    uint16_t mod_barrel_energy;
    uint16_t mod_barrel_spread;
    /* What each rung of shrapnel breaks into. Shrapnel is the one add-on
     * whose magnitude is another weapon rather than a number. */
    uint8_t mod_splinter[SIM_MAX_RUNGS];
    /* Proximity widens with the bomb's level: ProximityDistance is the L1
     * radius and "each bomb level adds 1 to this amount". Q8 px per level.
     *
     * The sensor itself is not that distance. The original scales it, at
     * `radius * 18 / 16 - 14` px, and then adds the target hull's own half
     * width, so a fuse set to three tiles reaches about fifty pixels. The
     * safety below uses the unscaled distance instead, which is the original's
     * own inconsistency and not ours.
     *
     * `prox_delay` is BombExplodeDelay: once a fuse has found somebody it
     * fires when they start pulling away, or when this runs out. */
    int32_t prox_step;
    uint16_t prox_delay;
    /* BombSafety. A proximity bomb refuses to leave the tube at all while an
     * enemy is already inside the fuse's distance, so it cannot be walked up
     * to somebody and posted through their letterbox. */
    uint8_t bomb_safety;
    /* BBombDamagePercent, per thousand. A hull whose bombs bounce pays for it
     * in damage, on every bomb it throws rather than only the ones that
     * bounce. */
    uint16_t bbomb_damage;
    /* InactiveShrapDamage, and how long a fragment counts as inactive. A
     * shard does almost nothing for its first quarter second, which is what
     * stops a bomb killing at point blank twice over: once with the blast and
     * again with the shrapnel born inside the hull it just hit. Q10 energy
     * and ticks. */
    int32_t shrap_inactive;
    uint16_t shrap_inactive_ticks;
    int32_t bounce;   /* restitution on the axis that hit, out of 16 */
    int32_t friction; /* retained speed along the wall, out of 16 */
    uint16_t respawn_delay; /* ticks dead before respawn */
    /* How precisely a ship lands on the map's spawn point for its side.
     *
     * Zero puts it exactly on the tile, which stacks a roster: the point is
     * one tile, and at a room's worth of ships several arrive on the same one
     * with nothing between them. Above zero the ship lands on a random tile
     * within this many of the point instead, redrawn on every death.
     *
     * The point is chosen first and this is applied to it, which is the shape
     * worth holding on to. A radius that meant "ignore the tiles and scatter
     * about the middle of the map" was tried and is a different game: every
     * side lands in one place and the map stops having ends. Here the map
     * still says where a side belongs.
     *
     * Size it by seconds of bullet flight to the nearest enemy rather than by
     * tiles, because what it is really spreading is a crowd. At the 51 ships
     * one of our rooms holds, a radius of 15 leaves 11 tiles and under a
     * second, 30 leaves 22 tiles, and 60 leaves 40 tiles and a bit over three
     * seconds, which is long enough to pick a direction. A map that names no
     * spawn points at all has nothing to aim at, and there the radius falls
     * back to scattering about the center, which is what the original did
     * before it had spawn points. */
    uint16_t spawn_radius;
    /* Whether a client marks the map's spawn tiles. Render only: nothing in
     * this core reads it, and it travels here so the room and the client read
     * one value rather than two that have to be kept in step, the same
     * arrangement `safe_limit` below has.
     *
     * A client ignores it when `spawn_radius` is set, and that is a
     * consequence rather than a default somebody can override: with a radius
     * nobody arrives on those tiles, so a mark on one is a lie rather than a
     * preference. What this setting is actually for is the other case. We draw
     * every spawn, including the enemy's, in the enemy's color, so a zone
     * that does not want one side's home end advertised to the other has to be
     * able to say so. */
    uint8_t show_spawns;
    /* How long a ship may sit in a safe zone before the room takes its seat
     * back, in ticks, and zero for never.
     *
     * Nothing in this core enforces it or counts toward it. A seat is a thing
     * a server hands out and a client asks for, and the simulation has no
     * model of either; the clock is kept by the room, which acts on it, and
     * by the client, which draws it. The number lives here because it is a
     * rule of the game rather than of the deployment, so it travels in the
     * settings and both ends read one value rather than two that have to be
     * kept in step. */
    uint16_t safe_limit;
    /* Doors. A cycle is open then shut; variant n leads by n eighths of it,
     * so one map can breathe rather than blink. */
    uint16_t door_period;  /* ticks for a full cycle; 0 leaves doors shut */
    uint16_t door_open;    /* ticks of that cycle a door stands open */
    int32_t wormhole_pull;   /* Q16 px/tick^2 at the mouth */
    int32_t wormhole_range;  /* Q8 px, beyond which it does not reach */
    int32_t flag_radius;    /* Q8 px, pickup distance */
    uint16_t flag_drop_cooldown; /* ticks a dropped flag is untouchable */
    /* Ships this room will hold, which is a rule about the game rather than
     * about memory: the array is always SIM_MAX_SHIPS long. Clamped to that on
     * the way in, so a zone asking for more gets the ceiling instead of an
     * overflow. Zero means the ceiling too, since a zone that says nothing
     * should not get a room nobody can enter. */
    uint8_t max_ships;
    /* Whose death this instance may conclude on its own. The server keeps
     * the zero default and every death is real here. A prediction client
     * sets `deathless` and names its own hull in `mortal_ship`, or 255 for
     * none, which is what a watcher is: damage still lands and still
     * reports SIM_EV_HIT, but any other hull stops at its last sliver of
     * energy instead of dying. The event output records that suppressed
     * conclusion for measurement only. A kill a client concludes about a
     * coasting remote hull is an explosion the next snapshot may take back,
     * so a remote death only ever arrives as a snapshot state change, which the
     * client already turns into light and sound (decision 40). A deathless
     * Neither field is packed or hashed: this is a fact about who is
     * simulating, not about the world. */
    uint8_t deathless;
    uint8_t mortal_ship;
    const sim_map *map;    /* geometry; not part of rolled-back state */
} sim_settings;

typedef struct {
    uint8_t active;
    uint8_t alive;
    /* Set only by `sim_unpack` for a remote record whose owner-only tail was
     * withheld. Authoritative states and owner records leave it clear. The
     * prediction core uses it to avoid applying limits derived from inventory
     * it was deliberately not told about. */
    uint8_t public_only;
    uint8_t cls;   /* index into settings.classes */
    uint8_t team;
    int32_t x, y;
    int32_t vx, vy;
    uint16_t heading;
    int32_t energy;        /* Q10 */
    /* One per trigger. The original keeps two and crosses them: a bullet
     * locks the bombs for the bullet's own delay and a bomb locks the guns
     * for the bomb's, so the pair reads as one lockout almost everywhere.
     * Almost, because an EmpBomb hull's bombs do not touch the guns, and that
     * exception is the whole reason there are two counters rather than one. */
    uint16_t fire_cooldown[SIM_TRIG_COUNT];
    uint16_t stall;   /* ticks of suppressed recharge; what a stall round does */
    /* A shove in progress: ticks left of it, and the speed ceiling it lifts
     * this hull to while they last. */
    uint16_t repel;
    int32_t repel_speed;
    uint16_t respawn_at;    /* ticks remaining while dead */
    int32_t spawn_x, spawn_y;
    uint16_t kills, deaths;
    /* What this hull is, which is the kit dealt back at every spawn. These
     * are not accumulated any more and are not lost by dying: a death
     * re-deals the frame. */
    uint8_t up[SIM_UP_COUNT];
    uint8_t level[SIM_TRIG_COUNT];
    uint16_t mods[SIM_TRIG_COUNT];
    /* The kit itself, over the flat slot space, kept on the ship so a
     * respawn can re-deal it without the caller being asked twice. Set by
     * `sim_set_kit`, which validates it against the hull and the budget. */
    uint8_t kit[SIM_SLOT_COUNT];
    /* Multifire declined. The add-on stays held and stays on the scoreboard;
     * this only stops it being applied when the trigger is pulled. Cleared by
     * death with everything else, because the add-on it refuses is. */
    uint8_t multi_off;
    /* Last tick's buttons, for the toggles that fire on a press rather than
     * on a hold. Nothing else needs it, which is why it took this long to
     * appear, and it rides in the snapshot with the rest: an edge detector
     * that starts every snapshot believing nothing was held sees a press that
     * never happened. */
    uint16_t btn_prev;
    /* Charges in hand, spent one at a time, and the one thing a death does
     * NOT give back: the kit deals them once and the match spends them.
     * Dying to reload would otherwise be free at a bounty of one. */
    uint8_t charge[SIM_MAX_CHARGES];
    /* Kills since this hull last spawned, which is the whole of its bounty
     * beyond the base. Cleared by death, which is what makes the number over
     * a ship say "this one is on a run" rather than "this one shopped well". */
    uint16_t run;
    /* The score. Not cleared by death: what you have been paid is yours,
     * and what you are worth is a different number entirely. */
    uint32_t points;
} sim_ship;

/* What this pilot is worth to whoever kills them: the base plus their run.
 *
 * This used to be a sum over everything held, which was the right answer
 * while what you held was what you had survived to collect. Once a kit is
 * dealt back at every spawn that sum says only what you shopped for, it is
 * the same for a pilot who has just undocked as for one on a tear, and a
 * fresh spawn becomes worth thirty to whoever camps it. So bounty counts the
 * run instead: one on arrival, one more per kill, gone when you die. */
int32_t sim_bounty(const sim_settings *cfg, const sim_ship *sh);


/* What an account owns before it has bought anything, over the same flat
 * space, and 255 for a slot the account never limits.
 *
 * A kit is checked against the zone's ceiling and the account's entitlements
 * together, and the smaller of the two wins. The zone's row is the arena
 * saying what it has; this is the shop's half, and it exists so that "what
 * rivets buy is which upgrades you may slot, never how many" has somewhere to
 * be true.
 *
 * Six of each stat, which is exactly the budget over five of them and is why
 * the budget is thirty: a pilot who buys nothing can still take every stat to
 * its base ceiling and own nothing else, which is a legibly poor ship and a
 * useful landmark. The last two steps are the shop's.
 *
 * One rung of each ladder and one of each add-on, so a new account flies a
 * whole ship rather than a chassis. Repel and burst without limit, which is
 * what "the two everybody starts with" means; the other two charge kinds are
 * bought.
 *
 * Barrels are the exception and the only add-on a new account holds none of.
 * Every other add-on changes what a round does; this one changes how many
 * leave, and a rung of it handed out free is the one upgrade that would make
 * the starting kit strictly better than it should be. It is also the trait
 * this whole space was flattened to make sellable, so selling it is rather
 * the point. See docs/design/match-game.md. */
void sim_base_entitlements(uint8_t *out);

/* A whole budget spent on a hull, without asking anybody what they wanted.
 *
 * Every seat has to be flying something: a pilot who has never opened the
 * hangar, a bot, and a new account all arrive with no kit of their own, and a
 * bare hull against a built one is not a game. So this is the answer to "what
 * would a sensible pilot bring", and it is here rather than in a server
 * because the same thirty points have to land the same way for a new account,
 * for a bot, and for the hangar drawing a starting point.
 *
 * One rung on each trigger the hull has, the charges it will hold, and the
 * rest spread evenly over the five stats. That is deliberately an
 * all-rounder: it is a decent ship on any hull and the best ship on none, so
 * the first thing a player learns in the hangar is that spending differently
 * is worth doing.
 *
 * Takes the ceilings rather than the hull, because what a pilot may slot is
 * the zone's row and their account's entitlements together, and the account
 * is not something this core knows about. `cfg->kit_ceiling` is the zone's
 * half; a caller with no account to consult passes that straight in.
 *
 * `out` is SIM_SLOT_COUNT bytes. Returns what it spent, which is
 * SIM_KIT_BUDGET in any arena with room for it and less in one with almost
 * nothing to spend it on. */
int sim_starter_kit(const uint8_t *ceiling, uint8_t *out);

/* What a kit spends, which is just its sum, because every slot costs one. */
int sim_kit_cost(const uint8_t *kit);

/* Validate a kit against the zone and the budget, store it on the ship, and
 * deal it with ammunition. Returns 0 and changes nothing if any slot is over
 * its ceiling or the total is over `SIM_KIT_BUDGET`, so a refused kit leaves
 * the pilot in what they were already flying rather than half dressed.
 *
 * The hull is not consulted. A kit that validated in the hangar flies on
 * anything in the roster, which is what makes changing hull between matches a
 * free choice rather than a rebuild. */
int sim_set_kit(sim_ship *sh, const sim_settings *cfg, const uint8_t *kit);

/* Deal the stored kit onto the hull.
 *
 * `ammunition` is the whole of the difference between arriving and
 * respawning. A match deals charges once and a death re-deals only the
 * frame, so a pilot who has spent both repels flies the rest of the match
 * without them and cannot reload by dying, which at a bounty of one would
 * otherwise be a trade worth making. */
void sim_deal_kit(sim_ship *sh, const sim_settings *cfg, int ammunition);

/* Hand a pilot one named slot, with the arena's ceilings enforced. Returns 1
 * if the count moved and 0 if the slot is already full, which is how a caller
 * tells "wearing the kit" from "cannot wear it". `sim_deal_kit` is this in a
 * loop; the calibration harness calls it directly to build a ship a slot at
 * a time. */
int sim_grant(sim_ship *sh, const sim_settings *cfg, uint8_t type);

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
    /* Nonzero rounds with the same link left on one gun pull. The first one
     * to hit a hull spends the whole volley, as SVS multifire does. Walls do
     * not: one side of a fan may end while the rest carries on. */
    uint32_t link;
    int32_t x, y;
    int32_t vx, vy;
    uint16_t life; /* ticks remaining */
    /* A proximity fuse, once it has found somebody.
     *
     * The original latches one hull and then watches only that one: a second
     * pilot crossing an armed bomb does not set it off. `fuse` is
     * BombExplodeDelay counting down, and `near` is the closest the latched
     * hull has been, as the larger of the two axis gaps. The fuse fires when
     * that gap grows or the clock runs out, whichever comes first. */
    uint8_t fuse_target;  /* ship index, or 255 while unarmed */
    uint16_t fuse;
    int32_t near;         /* Q8 px */
    /* The rung this round was fired at. Carried rather than recomputed,
     * because a spec is composed again where a round lands and the rung it
     * came off is not otherwise recoverable there: without this a bomb level
     * added nothing to its own fuse once the bomb was in the air. */
    uint8_t level;
    /* What its fragments will be, taken off the pilot's *guns* when the bomb
     * was thrown and carried by the bomb.
     *
     * Shrapnel is bullets in the original, so a fragment is a bullet of your
     * gun's rung and bounces if your bullets do. Both are read at the moment
     * of firing, so a bomber who upgrades while their bomb is in the air does
     * not improve the burst it is about to make, and one who dies still
     * throws the fragments they earned. */
    uint8_t shrap_level;
    uint8_t shrap_bounce;
} sim_weapon;

typedef enum {
    SIM_EV_FIRE = 1,
    /* A ship hit a wall hard enough to be worth reporting. The impact is the
     * speed the wall took out of it, before the wall gave any back. */
    SIM_EV_BOUNCE,   /* a: ship, b: unused, v: impact speed Q16 */
    SIM_EV_HIT,      /* a: victim, b: attacker, v: damage Q10 */
    /* a: victim, b: killer (255 = none), v: points the kill paid, which is
     * the victim's bounty plus what their flags were worth. */
    SIM_EV_DEATH,
    SIM_EV_SPAWN,    /* a: ship */
    /* A weapon stopped existing: it ran out of life, hit a wall, or struck a
     * ship. The position is where, which is the only report of it there is:
     * by the time a caller looks, the weapon is gone from the state. Whole
     * pixels, packed (x << 14) | y. */
    SIM_EV_EXPIRE,   /* a: weapon type, b: owner, v: packed position */
    /* A charge was spent. b is the slot, v is how many are left, which is
     * what a panel wants and what a sound wants to know it happened. */
    SIM_EV_CHARGE,
    SIM_EV_FLAG_TAKE,/* a: ship, b: flag index */
    SIM_EV_FLAG_DROP,/* a: flag index, b: team that keeps it */
    SIM_EV_GOAL,     /* a: ship, b: the goal's variant */
    SIM_EV_WARP,     /* a: ship caught by a closing door, sent home */
    /* A weapon came off a wall instead of ending on it. Its own event rather
     * than a ship's bounce, which is what it used to be: the two carry
     * different things in v, one an impact and the other a position, and a
     * caller reading a position as an impact cannot tell it is doing so. It
     * cost a bouncing bullet a wall thump at the shooter's hull, once per
     * ricochet, anywhere on the map.
     *
     * Appended rather than slotted next to SIM_EV_BOUNCE where it belongs,
     * because the numbers are mirrored by hand in server/src/sim.rs. */
    SIM_EV_RICOCHET /* a: owner, b: weapon type, v: packed position */
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
    sim_ship ships[SIM_MAX_SHIPS];
    sim_weapon weapons[SIM_MAX_WEAPONS];
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
    /* Remote hulls a deathless prediction would have killed this tick. Kept
     * outside the event array so measurement cannot displace a visual event
     * when that bounded array is full. The hull remains alive. */
    uint16_t predicted_death_count;
    uint8_t predicted_death[SIM_MAX_SHIPS];
} sim_events;

void sim_init(sim_state *s, uint32_t seed);

/* Add a ship. Returns its index, or -1 if full. */
/* Append a projectile spec, or a way of firing one, and hand back its index.
 * Both return -1 when the table is full. A pattern names a spec; a spec's
 * splinter names a pattern, which is how one ending fires the next. */
int sim_add_spec(sim_settings *cfg, const sim_weapon_spec *spec);
int sim_add_pattern(sim_settings *cfg, const sim_fire_pattern *pattern);

/* How many ships this room allows: the zone's number, clamped to the array
 * bound, with zero reading as the ceiling. One place so the server, the client
 * and the core cannot disagree about it. */
uint8_t sim_eff_max_ships(const sim_settings *cfg);

/* Open a match: every active pilot home, alive, full, and freshly kitted with
 * their ammunition, with nothing of the last match left in the air.
 *
 * A match game plays match after match in one room, so this is the edge
 * between two of them and it belongs here rather than in a server: it touches
 * the same fields a spawn touches and it has to land identically on every
 * architecture the state hash is compared across.
 *
 * Kills, deaths and points are the match's own tally and go back to zero with
 * it. The kit does not, because a kit is what you own. */
void sim_restart(sim_state *s, const sim_settings *cfg);

int sim_spawn(sim_state *s, uint8_t cls, uint8_t team, int32_t x_px,
              int32_t y_px, uint16_t heading, const sim_settings *cfg);

/* Where to put a ship of this team now, as a Q8 world position, honouring
 * `spawn_radius`. `nth` walks the map's spawn tiles when the setting is zero
 * and is ignored when it is not; a caller that wants a random tile rather than
 * the next one rolls `s->rng` itself first and passes it in. Rolls `s->rng`
 * further on the radius path, which is why it takes the state at all.
 *
 * Exported because the room places arrivals and the core places respawns, and
 * a seat handed out at the door has to land where a death would. Those used to
 * be separate arithmetic in two languages, neither of which knew about a
 * radius. */
void sim_spawn_point(sim_state *s, const sim_settings *cfg, uint8_t team,
                     uint8_t cls, uint32_t nth, int32_t *x, int32_t *y);

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

/* Put a pilot on a different side. Gated exactly as a hull change is, and for
 * the same reason: it is a respawn at the new side's start with a full bar, so
 * ungated it is an escape. Flags are dropped and bounty earned by killing is
 * cleared, which is what stops two pilots swapping sides to feed each other.
 *
 * What you are flying is untouched: hull, levels, add-ons and charges all
 * cross with you, because a side is not a thing a ship is built against.
 * Which team numbers exist and who may enter one is the zone's
 * business; this core only knows that a ship has a side and that sides differ.
 *
 * Returns 0, or -1 for an unknown ship, a dead pilot, or one not at full
 * energy. Asking for the side you are already on does nothing and succeeds. */
int sim_set_ship_team(sim_state *s, const sim_settings *cfg, uint8_t i,
                      uint8_t team);

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

/* A hull's flight stats in settings-file units, laid out the way the original
 * writes them: what a fresh pilot has, what one green adds, and the ceiling.
 * Its `InitialSpeed`, `UpgradeSpeed` and `MaximumSpeed` and so on down.
 *
 * All three, rather than a ceiling and a rule for the rest, because there is
 * no rule: the original starts a pilot at 62% of top speed and 88% of top
 * thrust, and one green closes a quarter of the speed gap against a seventh
 * of the energy gap. */
typedef struct {
    int32_t init_speed, up_speed, max_speed;
    int32_t init_thrust, up_thrust, max_thrust;
    int32_t init_rotation, up_rotation, max_rotation;
    int32_t init_energy, up_energy, max_energy;
    int32_t init_recharge, up_recharge, max_recharge;
    /* No footprint here: the settings files these units mirror never carried
     * one, and the extents are measured off our own hulls in baseline.c. */
} sim_class_units;

/* Fill a class from settings-file units. Weapons, add-ons and charges are
 * left empty: what a hull fires is a ladder of patterns a zone tunes. */
void sim_class_from_units(sim_ship_class *c, const sim_class_units *u);

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
