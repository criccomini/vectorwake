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
 */
#ifndef SIM_H
#define SIM_H

#include <stdint.h>

#define SIM_MAX_SHIPS 64
#define SIM_MAP_TILES 1024
#define SIM_TILE_PX 16

/* Q8 position of the map edge. */
#define SIM_MAP_MAX_Q8 (SIM_MAP_TILES * SIM_TILE_PX * 256)

/* Input buttons. */
#define SIM_BTN_LEFT 0x0001u    /* rotate counter-clockwise */
#define SIM_BTN_RIGHT 0x0002u   /* rotate clockwise */
#define SIM_BTN_THRUST 0x0004u  /* accelerate along heading */
#define SIM_BTN_REVERSE 0x0008u /* accelerate against heading */

/* The tile grid. One byte per tile; nonzero is solid. The host owns the
 * allocation (1 MiB); the core only reads it. */
typedef struct {
    uint8_t solid[SIM_MAP_TILES * SIM_MAP_TILES];
} sim_map;

/* Per-ship-class tuning, already converted to core units. Use the
 * sim_vie_* helpers to convert Subspace-vocabulary settings. */
typedef struct {
    int32_t max_speed; /* Q16 px/tick */
    int32_t thrust;    /* Q16 px/tick^2 */
    int32_t rot;       /* heading units per tick */
    int32_t radius;    /* Q8 px, ship center to edge */
} sim_ship_class;

typedef struct {
    sim_ship_class ship;  /* one class for now; eight later */
    int32_t bounce;       /* wall bounce factor, 16 = no speed loss */
    const sim_map *map;   /* world geometry; not part of rolled-back state */
} sim_settings;

typedef struct {
    uint8_t active;
    int32_t x, y;   /* Q8 px */
    int32_t vx, vy; /* Q16 px/tick */
    uint16_t heading;
} sim_ship;

/* Flat, pointer-free, memcpy-able. Copying this struct is a rollback. */
typedef struct {
    uint32_t tick;
    uint32_t rng;
    uint8_t ship_count;
    sim_ship ships[SIM_MAX_SHIPS];
} sim_state;

typedef struct {
    uint8_t ship;     /* ship index */
    uint16_t buttons; /* SIM_BTN_* bitfield */
} sim_input;

typedef struct {
    uint32_t bounces; /* wall hits this tick */
} sim_events;

/* Zero the state and seed the PRNG. */
void sim_init(sim_state *s, uint32_t seed);

/* Add a ship at a pixel position. Returns the ship index, or -1 if full. */
int sim_spawn(sim_state *s, int32_t x_px, int32_t y_px, uint16_t heading);

/* Advance one tick: prev -> next. next and prev may not alias. inputs holds
 * at most one entry per ship; ships without an entry coast. */
void sim_step(sim_state *next, const sim_state *prev, const sim_input *inputs,
              uint16_t input_count, const sim_settings *cfg, sim_events *ev);

/* FNV-1a 64 over the serialized state. Identical across platforms; the
 * determinism harness compares nothing else. */
uint64_t sim_hash(const sim_state *s);

/* Convert Subspace-vocabulary settings to core units.
 *   speed    px/s/10        -> Q16 px/tick
 *   thrust   accel of t*10 px/s^2 -> Q16 px/tick^2
 *   rotation r/400 turns/s  -> heading units per tick */
int32_t sim_vie_speed(int32_t v);
int32_t sim_vie_thrust(int32_t t);
int32_t sim_vie_rotation(int32_t r);

#endif
