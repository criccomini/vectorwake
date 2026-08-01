/* Freestanding shims plus the exported surface the web client calls.
 *
 * The sim core has no libc dependency beyond memcpy and memset, so the whole
 * simulation compiles to WebAssembly with clang alone: no emscripten, no
 * runtime, no glue. The result is a bare .wasm the page instantiates itself.
 */
#include "sim/baseline.h"
#include "sim/pack.h"
#include "sim/sim.h"

/* clang lowers struct assignment and array init to these. */
void *memcpy(void *d, const void *s, unsigned long n) {
    unsigned char *dp = d;
    const unsigned char *sp = s;
    while (n--) *dp++ = *sp++;
    return d;
}

void *memset(void *d, int c, unsigned long n) {
    unsigned char *dp = d;
    while (n--) *dp++ = (unsigned char)c;
    return d;
}

/* Static storage: WebAssembly memory is the heap, and the sim allocates
 * nothing, so every buffer the client needs is declared right here. */
static sim_map g_map;
static sim_settings g_cfg;
static sim_state g_a, g_b;
static sim_state *g_cur = &g_a, *g_nxt = &g_b;
static sim_events g_ev;

#define EXPORT __attribute__((visibility("default")))

/* Arena bounds in tiles. A compact room rather than the full 1024 grid: at
 * the camera's fixed 34-tile view, a bigger space would put every fight out
 * of sight and the walls out of reach. */
#define ARENA_LO 470
#define ARENA_HI 554

static void fill(int x0, int y0, int x1, int y1) {
    for (int ty = y0; ty <= y1; ty++)
        for (int tx = x0; tx <= x1; tx++)
            g_map.solid[(unsigned)ty * SIM_MAP_TILES + tx] = 1;
}

/* An enclosed arena with cover: a wall around the outside, four pillars, and
 * two lanes that break line of sight through the middle. Rotationally
 * symmetric so no spawn has the better ground. */
EXPORT void vw_init(uint32_t seed) {
    for (unsigned i = 0; i < sizeof g_map.solid; i++) g_map.solid[i] = 0;

    fill(ARENA_LO, ARENA_LO, ARENA_HI, ARENA_LO + 1);       /* top    */
    fill(ARENA_LO, ARENA_HI - 1, ARENA_HI, ARENA_HI);       /* bottom */
    fill(ARENA_LO, ARENA_LO, ARENA_LO + 1, ARENA_HI);       /* left   */
    fill(ARENA_HI - 1, ARENA_LO, ARENA_HI, ARENA_HI);       /* right  */

    fill(489, 489, 495, 495);   /* pillars */
    fill(529, 489, 535, 495);
    fill(489, 529, 495, 535);
    fill(529, 529, 535, 535);

    fill(505, 480, 519, 483);   /* centre baffles */
    fill(505, 541, 519, 544);
    fill(480, 505, 483, 519);
    fill(541, 505, 544, 519);

    sim_settings_baseline(&g_cfg, &g_map);
    sim_init(g_cur, seed);
}

/* A duel room: small, closed, two pillars. Playable with no server, which
 * matters because the published page has no server to reach. */
EXPORT void vw_init_duel(uint32_t seed) {
    for (unsigned i = 0; i < sizeof g_map.solid; i++) g_map.solid[i] = 0;
    const int LO = 496, HI = 528;
    fill(LO, LO, HI, LO + 1);
    fill(LO, HI - 1, HI, HI);
    fill(LO, LO, LO + 1, HI);
    fill(HI - 1, LO, HI, HI);
    fill(505, 505, 509, 509);
    fill(515, 515, 519, 519);
    sim_settings_baseline(&g_cfg, &g_map);
    sim_init(g_cur, seed);
}

/* Warmup disarms by holding the cooldown forward, the same trick the server
 * mode uses, so both agree about what a disarmed ship is. */
EXPORT void vw_freeze(int ship) {
    g_cur->ships[ship].fire_cooldown = 60;
}

EXPORT int vw_add_flag(int tile_x, int tile_y) {
    return sim_add_flag(g_cur, tile_x * SIM_TILE_PX, tile_y * SIM_TILE_PX);
}
EXPORT int vw_flag_count(void) { return g_cur->flag_count; }
EXPORT int vw_flag_x(int i) { return g_cur->flags[i].x; }
EXPORT int vw_flag_y(int i) { return g_cur->flags[i].y; }
EXPORT int vw_flag_team(int i) { return g_cur->flags[i].team; }
EXPORT int vw_flag_carried(int i) { return g_cur->flags[i].carried; }
EXPORT int vw_flags_held(int team) { return sim_flags_held(g_cur, (uint8_t)team); }

EXPORT int vw_spawn(int cls, int team, int tile_x, int tile_y, int heading) {
    return sim_spawn(g_cur, (uint8_t)cls, (uint8_t)team, tile_x * SIM_TILE_PX,
                     tile_y * SIM_TILE_PX, (uint16_t)heading, &g_cfg);
}

/* Advance one tick. buttons_ptr is a byte per ship, indexed by ship id. */
EXPORT void vw_step(const uint8_t *buttons, int n) {
    sim_input in[SIM_MAX_SHIPS];
    uint16_t count = 0;
    for (int i = 0; i < n && i < SIM_MAX_SHIPS; i++) {
        in[count].ship = (uint8_t)i;
        in[count].buttons = buttons[i];
        count++;
    }
    sim_step(g_nxt, g_cur, in, count, &g_cfg, &g_ev);
    sim_state *t = g_cur;
    g_cur = g_nxt;
    g_nxt = t;
}

/* Accessors. The page reads state through these rather than parsing the
 * struct layout, so the layout stays free to change. */
EXPORT uint32_t vw_tick(void) { return g_cur->tick; }
EXPORT int vw_ship_count(void) { return g_cur->ship_count; }
EXPORT int vw_ship_x(int i) { return g_cur->ships[i].x; }
EXPORT int vw_ship_y(int i) { return g_cur->ships[i].y; }
EXPORT int vw_ship_vx(int i) { return g_cur->ships[i].vx; }
EXPORT int vw_ship_vy(int i) { return g_cur->ships[i].vy; }
EXPORT int vw_ship_heading(int i) { return g_cur->ships[i].heading; }
EXPORT int vw_ship_energy(int i) { return g_cur->ships[i].energy; }
EXPORT int vw_ship_alive(int i) { return g_cur->ships[i].alive; }
EXPORT int vw_ship_team(int i) { return g_cur->ships[i].team; }
EXPORT int vw_ship_cls(int i) { return g_cur->ships[i].cls; }
EXPORT int vw_ship_kills(int i) { return g_cur->ships[i].kills; }
EXPORT int vw_ship_deaths(int i) { return g_cur->ships[i].deaths; }
EXPORT int vw_ship_max_energy(int i) {
    return sim_eff_max_energy(&g_cfg.classes[g_cur->ships[i].cls], &g_cur->ships[i]);
}
EXPORT int vw_ship_radius(int i) {
    return g_cfg.classes[g_cur->ships[i].cls].radius;
}
EXPORT int vw_ship_max_speed(int i) {
    return g_cfg.classes[g_cur->ships[i].cls].max_speed;
}

EXPORT int vw_weapon_count(void) { return g_cur->weapon_count; }
EXPORT int vw_weapon_x(int i) { return g_cur->weapons[i].x; }
EXPORT int vw_weapon_y(int i) { return g_cur->weapons[i].y; }
EXPORT int vw_weapon_vx(int i) { return g_cur->weapons[i].vx; }
EXPORT int vw_weapon_vy(int i) { return g_cur->weapons[i].vy; }
EXPORT int vw_weapon_type(int i) { return g_cur->weapons[i].type; }
EXPORT int vw_weapon_team(int i) { return g_cur->weapons[i].team; }

/* Networking. The page writes snapshot bytes into this buffer and calls
 * vw_unpack; the unpacker is the core's own, so the client cannot disagree
 * with the server about what a snapshot means. */
static uint8_t g_net[SIM_PACK_MAX];
EXPORT uint8_t *vw_netbuf(void) { return g_net; }
EXPORT int vw_netbuf_size(void) { return (int)sizeof g_net; }

EXPORT int vw_apply_snapshot(int len) {
    return sim_unpack(g_cur, g_net, len);
}

/* Re-simulate one tick applying only the local ship's input. Remote ships
 * coast, which is what prediction between snapshots amounts to. */
EXPORT void vw_replay(int ship, int buttons) {
    sim_input in = {(uint8_t)ship, (uint16_t)buttons};
    sim_step(g_nxt, g_cur, &in, 1, &g_cfg, &g_ev);
    sim_state *t = g_cur;
    g_cur = g_nxt;
    g_nxt = t;
}

EXPORT unsigned vw_hash_lo(void) { return (unsigned)(sim_hash(g_cur) & 0xffffffffu); }

EXPORT int vw_prize_count(void) { return SIM_MAX_PRIZES; }
EXPORT int vw_prize_active(int i) { return g_cur->prizes[i].active; }
EXPORT int vw_prize_x(int i) { return g_cur->prizes[i].x; }
EXPORT int vw_prize_y(int i) { return g_cur->prizes[i].y; }
EXPORT int vw_prize_type(int i) { return g_cur->prizes[i].type; }
EXPORT int vw_ship_up(int i, int u) { return g_cur->ships[i].up[u]; }
EXPORT int vw_ship_speed_pct(int i) {
    const sim_ship_class *c = &g_cfg.classes[g_cur->ships[i].cls];
    return (int)((int64_t)sim_eff_speed(c, &g_cur->ships[i]) * 100 / c->max_speed);
}

EXPORT int vw_solid(int tx, int ty) {
    if (tx < 0 || ty < 0 || tx >= SIM_MAP_TILES || ty >= SIM_MAP_TILES) return 1;
    return g_map.solid[(unsigned)ty * SIM_MAP_TILES + (unsigned)tx];
}

/* Events from the last step, for sound and effects. */
EXPORT int vw_event_count(void) { return g_ev.count; }
EXPORT int vw_event_type(int i) { return g_ev.e[i].type; }
EXPORT int vw_event_a(int i) { return g_ev.e[i].a; }
EXPORT int vw_event_b(int i) { return g_ev.e[i].b; }
