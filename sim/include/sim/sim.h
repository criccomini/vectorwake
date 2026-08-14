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
/* Greens alive at once. The snapshot writes a u8 index and a u8 count, so
 * 255 is the wire's ceiling and not an arbitrary one. */
#define SIM_MAX_PRIZES 255

/* Where a green appears, in tiles from a live pilot: outside the first so it is
 * a trip rather than a gift, inside the second so it lands on their radar,
 * whose reach is thirty tiles either way.
 *
 * Raising `prize_max` is not the alternative it looks like. Placed uniformly, a
 * thousand-tile map needs thousands of greens before one is reliably inside the
 * sixty tiles a pilot can see, and the wire ceiling is 255. Placing them where
 * the people are costs no extra state at all. */
#define SIM_PRIZE_NEAR_LO 6
#define SIM_PRIZE_NEAR_HI 28
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
/* Lay a mine, which is the bomb trigger in its other posture.
 *
 * Its own button and not a charge slot, because a mine is not a thing you
 * carry a count of: you have mines because you have bombs, exactly as the
 * original has it -- there a mine is not a weapon type at all but a bomb with
 * one bit set, and the inventory its position packet carries lists bursts,
 * repels, thors and portals and no mines. What limits it is how many of yours
 * are already out, which is `mine_max` on the hull. */
#define SIM_BTN_MINE 0x0400u
#define SIM_BTN_SLOT_SHIFT 7
#define SIM_BTN_SLOT_MASK 0x0180u
#define SIM_BTN_SLOT(b) (((b) & SIM_BTN_SLOT_MASK) >> SIM_BTN_SLOT_SHIFT)

/* What a tile does. The original encoded behavior in the tile's own number
 * -- doors at 162 through 169, a safe zone at 171, scenery you fly under at
 * 176 through 190 -- so every rule in the engine was a range check against a
 * magic constant, and a map editor had to know all of them.
 *
 * Here a tile is its behavior and nothing else. How it is drawn is the
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

/* Make a map ready to play, which is two things.
 *
 * It closes the world: four tiles of boundary around the square, whatever the
 * map said was there. Every map wants one, so a map that had to carry its own
 * is a map that can be missing it, and a converted one always is. Four tiles
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
 * has happened twice: a field inserted in the middle, and `SIM_MAX_PRIZES`
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

/* ---- what a green can be ----
 *
 * One flat space, because the whole tech tree is one shape: a count with a
 * ceiling. A stat count interpolates a range, a level count indexes a
 * ladder, an add-on count transforms what a trigger fires. The zone weights
 * this space to decide what its greens are; the client colors and names
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
    /* How many of this hull's mines may be in the world at once. MaxMines,
     * which the original bounds at twenty.
     *
     * This is the whole of what limits mines, because nothing else does: a
     * pilot has them for as long as they have a bomb rack, so there is no
     * ammunition to run out of and no green to wait for. Zero is a hull that
     * lays none, which is how a zone makes mining one ship's job. */
    uint8_t mine_max;

    /* Gunners: teammates riding this hull, aiming and firing their own
     * weapons out of a ship they cannot steer. Zero forbids it, which is how
     * a zone makes one hull the carrier and leaves the rest alone.
     *
     * The two penalties are charged once, when the first gunner arrives, and
     * not again for the next four. That is what the original does and it is
     * worth knowing rather than inheriting by accident: a carrier with one
     * gunner always wants five. */
    uint8_t gunner_limit;
    int32_t gunner_thrust;   /* Q16 px/tick^2 off the carrier while carrying */
    int32_t gunner_speed;    /* Q16 px/tick off the carrier while carrying */
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
    /* What a mine is, as a pattern index, or SIM_NO_PATTERN in a zone with
     * none. One pattern for the whole room rather than a ladder per hull: the
     * rung a mine wears is the layer's bomb rung, and `blast_up` is what turns
     * that rung into a hole the size of that rung's bomb. */
    uint8_t mine;
    /* Odds a green turns out to be each thing, over the flat prize space.
     * Relative rather than percentages -- doubling every number changes
     * nothing -- and read against the pool of the hull that took it, so what
     * a zone writes is the shape of the tree rather than its arithmetic. */
    uint16_t prize_weight[SIM_PRIZE_COUNT];
    /* What a kill adds to the killer's own bounty, so a pilot on a streak
     * becomes a target without having touched a green. */
    uint16_t bounty_per_kill;
    /* Points on top of the victim's bounty for each flag they were carrying. */
    uint16_t points_per_flag;
    /* Out of a thousand, how often a green corrodes something instead of
     * granting it. Rust can only take what a pilot is actually holding, so a
     * fresh one is never punished for arriving; when there is nothing to take
     * the green is an ordinary upgrade. */
    uint16_t rust_chance;
    /* Greens a ship is handed the moment it spawns, rolled the same way a
     * green found on the floor is. A zone that wants pilots to start plain
     * sets it to zero; the baseline starts everyone loaded, because a fight
     * between two empty ships is the least interesting fight in the game and
     * it is the one every match opens with. */
    uint16_t spawn_prizes;
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
     * instance sows no ambient prizes either, and for the same reason: it
     * simulates a snapshot filtered to its interest window, so its live-prize
     * count says nothing about the map. Its one exception is the named mortal
     * hull's death green. That death is already predicted, the green is
     * guaranteed, and drawing both on the same tick keeps the local death from
     * splitting into two beats. Neither field is packed or hashed: this is a
     * fact about who is simulating, not about the world. */
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
    uint8_t up[SIM_UP_COUNT];  /* stat upgrades held; cleared by death */
    /* The rung each trigger is on, and the add-ons held on each. Cleared by
     * death with everything else: what you are carrying is what you have
     * survived with. */
    uint8_t level[SIM_TRIG_COUNT];
    uint16_t mods[SIM_TRIG_COUNT];
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
    /* Charges in hand, spent one at a time. */
    uint8_t charge[SIM_MAX_CHARGES];
    /* Bounty that is not sitting in an upgrade slot: what killing has paid,
     * and what greens taken at a ceiling were worth. Cleared by death with
     * everything else. */
    uint16_t earned;
    /* The score. Not cleared by death: what you have been paid is yours,
     * and what you are worth is a different number entirely. */
    uint32_t points;
    /* The ship this one is riding, or SIM_NO_CARRIER. A gunner keeps its own
     * heading, its own energy and its own weapons, and gives up thrust and
     * position: it sits exactly where its carrier sits, takes damage there,
     * and is as big as one point. */
    uint8_t carrier;
} sim_ship;

#define SIM_NO_CARRIER 0xFFu

/* What this pilot is worth to whoever kills them.
 *
 * Derived rather than stored, and that is the whole trick. Every count in the
 * tech tree is already authoritative state, so bounty is a sum over it plus
 * what killing has earned -- which means rust lowers your price, a green
 * taken at the ceiling does not inflate you, and dying resets it, all without
 * a line of code in any of those places. The original kept bounty as its own
 * counter, in the client, where it could disagree with what you were actually
 * carrying. This one cannot.
 *
 * Everything held counts one, and a green taken at a ceiling counts one in
 * `earned` instead -- so every green is worth exactly one bounty whatever it
 * turned out to be, and a pilot who is already at every ceiling still gets
 * more dangerous by taking them. */
int32_t sim_bounty(const sim_ship *sh);

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

/* Hand a pilot one named thing from the prize space, with no roll in it.
 *
 * A green is a roll and a grant welded together, and something that measures
 * what a kit is worth needs the second half without the first: the server's
 * loadout tournament fights fixed kits against each other, so the only thing
 * varying between two pilots is what they are carrying rather than what the
 * dice said. Nothing in a live arena calls this, and nothing should: greens
 * are how the tech tree is reached in a game.
 *
 * Ceilings still hold, because holding them is `move_count`'s job either way:
 * a hull with no rack cannot be granted a bomb level any more than it can be
 * handed one. Returns 1 if the count moved and 0 if it did not, which is how a
 * caller tells "this hull is wearing the kit" from "this hull cannot".
 *
 * `earned` is left alone. That is a green's consolation for landing on a count
 * already at its ceiling, and paying it here would make a hull more dangerous
 * for being handed something it cannot hold. */
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
    /* a: ship, b: the flat prize index (see SIM_PRIZE_LEVEL and friends,
     * not sim_upgrade alone), v: +1 collected, -1 rusted away. */
    SIM_EV_PRIZE,
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
    SIM_EV_RICOCHET, /* a: owner, b: weapon type, v: packed position */
    /* A deathless prediction client touched a green. It names no outcome,
     * because the prize generator is server-private. Appended so every event
     * number already mirrored outside the core stays put. */
    SIM_EV_PRIZE_TOUCH /* a: ship */
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
    /* Prize rolls and green placement are server decisions. This stream is
     * distinct from the prediction stream above and is omitted from every
     * network snapshot. */
    uint32_t prize_rng;
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
 * What you are flying is untouched -- hull, levels, add-ons and charges all
 * cross with you -- because unlike a hull change nothing about the roster row
 * moved. Which team numbers exist and who may enter one is the zone's
 * business; this core only knows that a ship has a side and that sides differ.
 *
 * Returns 0, or -1 for an unknown ship, a dead pilot, or one not at full
 * energy. Asking for the side you are already on does nothing and succeeds. */
/* Ride a teammate, or SIM_NO_CARRIER to stop. Returns 0 if the state
 * changed and -1 if the request was refused.
 *
 * Refused unless both ships are alive on the same side, the target is not
 * itself riding somebody, it has room under its hull's `gunner_limit`, and
 * the asker is at full energy. Granting it moves the asker onto the target
 * from anywhere in the arena and leaves it with almost nothing in the bar,
 * which is the whole shape of the mechanic: the ride is free and arriving is
 * what costs. Detaching is never refused. */
int sim_attach(sim_state *s, const sim_settings *cfg, uint8_t i,
               uint8_t target);

/* How many gunners are riding this ship. */
uint8_t sim_gunners(const sim_state *s, uint8_t i);

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
    /* Gunners allowed on this hull, and what carrying any costs it. The
     * penalties are authored in the same units as the stat each comes off:
     * thrust like `max_thrust`, speed like `max_speed`. */
    int32_t gunner_limit, gunner_thrust_penalty, gunner_speed_penalty;
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
