/* A real client's eyes, for a test harness that is not written in Lua.
 *
 * The point of this shim is that the checking is done by the same code the game
 * is: snapshots are unpacked by sim_unpack, settings by sim_settings_unpack,
 * and prediction steps sim_step off the zone's own tables. A harness that
 * reimplemented the wire format would be testing its own reimplementation.
 *
 * Everything is deliberately behind small accessors so the Python side needs no
 * struct layouts, which is where a hand-written mirror goes wrong.
 */
#include <stdlib.h>
#include <string.h>
#include "sim/sim.h"
#include "sim/pack.h"
#include "sim/baseline.h"

typedef struct {
    sim_map map;
    sim_settings cfg;
    sim_state cur;
    sim_state next;
    sim_events ev;
    int have_map, have_cfg;
} vw;

vw *vw_new(void) {
    vw *c = calloc(1, sizeof *c);
    if (!c) return NULL;
    sim_map_arena(&c->map);          /* replaced by the zone's map on arrival */
    sim_settings_baseline(&c->cfg, &c->map);
    sim_init(&c->cur, 0x5eed);
    return c;
}
void vw_free(vw *c) { free(c); }

int vw_load_map(vw *c, const unsigned char *b, int n) {
    int r = sim_map_unpack(&c->map, b, n);
    if (r == 0) { c->cfg.map = &c->map; c->have_map = 1; }
    return r;
}
int vw_load_settings(vw *c, const unsigned char *b, int n) {
    int r = sim_settings_unpack(&c->cfg, b, n);
    if (r == 0) { c->cfg.map = &c->map; c->have_cfg = 1; }
    return r;
}
int vw_apply(vw *c, const unsigned char *b, int n) {
    return sim_unpack(&c->cur, b, n);
}

/* One predicted tick with these buttons on this ship, exactly as the client
 * does between snapshots. */
void vw_step(vw *c, unsigned char ship, unsigned short buttons) {
    sim_input in; in.ship = ship; in.buttons = buttons;
    sim_step(&c->next, &c->cur, &in, 1, &c->cfg, &c->ev);
    memcpy(&c->cur, &c->next, sizeof c->cur);
}

unsigned int vw_tick(vw *c)        { return c->cur.tick; }
int vw_ship_count(vw *c)           { return c->cur.ship_count; }
int vw_weapon_count(vw *c)         { return c->cur.weapon_count; }
/* Where a round is, so the harness can ask how far the furthest thing it was
 * sent actually is. That distance is the interest radius seen from outside:
 * the server's own claim about what it culls, checked rather than believed. */
int vw_wx(vw *c, int i)            { return c->cur.weapons[i].x; }
int vw_wy(vw *c, int i)            { return c->cur.weapons[i].y; }
int vw_active(vw *c, int i)        { return c->cur.ships[i].active; }
int vw_alive(vw *c, int i)         { return c->cur.ships[i].alive; }
int vw_x(vw *c, int i)             { return c->cur.ships[i].x; }
int vw_y(vw *c, int i)             { return c->cur.ships[i].y; }
int vw_vx(vw *c, int i)            { return c->cur.ships[i].vx; }
int vw_vy(vw *c, int i)            { return c->cur.ships[i].vy; }
int vw_energy(vw *c, int i)        { return c->cur.ships[i].energy; }
int vw_kills(vw *c, int i)         { return c->cur.ships[i].kills; }
int vw_deaths(vw *c, int i)        { return c->cur.ships[i].deaths; }
int vw_team(vw *c, int i)          { return c->cur.ships[i].team; }
int vw_cls(vw *c, int i)           { return c->cur.ships[i].cls; }
int vw_max_ships(vw *c)            { return c->cfg.max_ships; }
int vw_spec_count(vw *c)           { return c->cfg.spec_count; }
int vw_flag_count(vw *c) {
    int n = 0;
    for (int i = 0; i < SIM_MAX_FLAGS; i++) if (c->cur.flags[i].active) n++;
    return n;
}
/* Tiles that are not empty, as a cheap fingerprint of which map arrived. */
unsigned int vw_map_fingerprint(vw *c) {
    unsigned int n = 0;
    for (int i = 0; i < SIM_MAP_TILES * SIM_MAP_TILES; i++)
        if (c->map.tile[i]) n++;
    return n;
}
int vw_prize_count(vw *c) {
    int n = 0;
    for (int i = 0; i < SIM_MAX_PRIZES; i++) if (c->cur.prizes[i].active) n++;
    return n;
}
