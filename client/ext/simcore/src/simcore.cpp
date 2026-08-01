// Defold native extension wrapping the vectorwake simulation core.
//
// This file is a binding layer and nothing else: no game rule is implemented
// here, and none may be. Defold's build server compiles it for every target
// including WebAssembly, which is the mechanism that lets a browser tab run
// the same simulation as the dedicated server.
//
// The C core is copied in by client/build.sh rather than vendored, so the
// repository holds one copy of the rules.

#define LIB_NAME "simcore"
#define MODULE_NAME "sim"

#include <dmsdk/sdk.h>

// The headers carry their own extern "C" guard, which matters here because
// Defold's build server compiles .c files with clang++: without it the
// definitions would take C++ linkage and nothing would resolve.
#include "sim/baseline.h"
#include "sim/pack.h"
#include "sim/sim.h"

namespace {

// Static storage. The core allocates nothing, so the extension does not
// either, and an arena is a plain value this module owns.
sim_map g_map;
sim_settings g_cfg;
sim_state g_a, g_b;
sim_state* g_cur = &g_a;
sim_state* g_nxt = &g_b;
sim_events g_ev;
uint8_t g_net[SIM_PACK_MAX];

void Fill(int x0, int y0, int x1, int y1) {
    for (int ty = y0; ty <= y1; ty++)
        for (int tx = x0; tx <= x1; tx++)
            g_map.solid[(unsigned)ty * SIM_MAP_TILES + tx] = 1;
}

// The public arena: a wall around the outside, four pillars, and baffles
// that break line of sight through the middle.
int Init(lua_State* L) {
    uint32_t seed = (uint32_t)luaL_checkinteger(L, 1);
    memset(g_map.solid, 0, sizeof g_map.solid);
    const int LO = 470, HI = 554;
    Fill(LO, LO, HI, LO + 1);
    Fill(LO, HI - 1, HI, HI);
    Fill(LO, LO, LO + 1, HI);
    Fill(HI - 1, LO, HI, HI);
    Fill(489, 489, 495, 495);
    Fill(529, 489, 535, 495);
    Fill(489, 529, 495, 535);
    Fill(529, 529, 535, 535);
    Fill(505, 480, 519, 483);
    Fill(505, 541, 519, 544);
    Fill(480, 505, 483, 519);
    Fill(541, 505, 544, 519);
    sim_settings_baseline(&g_cfg, &g_map);
    sim_init(g_cur, seed);
    return 0;
}

int InitDuel(lua_State* L) {
    uint32_t seed = (uint32_t)luaL_checkinteger(L, 1);
    memset(g_map.solid, 0, sizeof g_map.solid);
    const int LO = 496, HI = 528;
    Fill(LO, LO, HI, LO + 1);
    Fill(LO, HI - 1, HI, HI);
    Fill(LO, LO, LO + 1, HI);
    Fill(HI - 1, LO, HI, HI);
    Fill(505, 505, 509, 509);
    Fill(515, 515, 519, 519);
    sim_settings_baseline(&g_cfg, &g_map);
    sim_init(g_cur, seed);
    return 0;
}

int Spawn(lua_State* L) {
    int cls = (int)luaL_checkinteger(L, 1);
    int team = (int)luaL_checkinteger(L, 2);
    int tx = (int)luaL_checkinteger(L, 3);
    int ty = (int)luaL_checkinteger(L, 4);
    int heading = (int)luaL_checkinteger(L, 5);
    int id = sim_spawn(g_cur, (uint8_t)cls, (uint8_t)team, tx * SIM_TILE_PX,
                       ty * SIM_TILE_PX, (uint16_t)heading, &g_cfg);
    lua_pushnumber(L, id);
    return 1;
}

// One tick. Buttons arrive as a table indexed by ship id, which keeps the
// Lua side free of any notion of how inputs reach the simulation.
int Step(lua_State* L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    sim_input in[SIM_MAX_SHIPS];
    uint16_t n = 0;
    for (int i = 0; i < g_cur->ship_count && n < SIM_MAX_SHIPS; i++) {
        lua_pushnumber(L, i);
        lua_gettable(L, 1);
        int b = lua_isnil(L, -1) ? 0 : (int)lua_tonumber(L, -1);
        lua_pop(L, 1);
        in[n].ship = (uint8_t)i;
        in[n].buttons = (uint16_t)b;
        n++;
    }
    sim_step(g_nxt, g_cur, in, n, &g_cfg, &g_ev);
    sim_state* t = g_cur;
    g_cur = g_nxt;
    g_nxt = t;
    return 0;
}

int Replay(lua_State* L) {
    sim_input in;
    in.ship = (uint8_t)luaL_checkinteger(L, 1);
    in.buttons = (uint16_t)luaL_checkinteger(L, 2);
    sim_step(g_nxt, g_cur, &in, 1, &g_cfg, &g_ev);
    sim_state* t = g_cur;
    g_cur = g_nxt;
    g_nxt = t;
    return 0;
}

// A snapshot arrives as a Lua string of bytes and is decoded by the core's
// own unpacker, so client and server cannot disagree about the format.
int ApplySnapshot(lua_State* L) {
    size_t len = 0;
    const char* data = luaL_checklstring(L, 1, &len);
    if (len > sizeof g_net) {
        lua_pushnumber(L, -1);
        return 1;
    }
    memcpy(g_net, data, len);
    lua_pushnumber(L, sim_unpack(g_cur, g_net, (int)len));
    return 1;
}

// Read-only views. Rendering asks; it never writes.
#define SHIP_GETTER(NAME, EXPR)                          \
    int NAME(lua_State* L) {                             \
        int i = (int)luaL_checkinteger(L, 1);            \
        const sim_ship* s = &g_cur->ships[i];            \
        (void)s;                                         \
        lua_pushnumber(L, (EXPR));                       \
        return 1;                                        \
    }

SHIP_GETTER(ShipX, s->x / 256.0)
SHIP_GETTER(ShipY, s->y / 256.0)
SHIP_GETTER(ShipHeading, s->heading)
SHIP_GETTER(ShipAlive, s->alive)
SHIP_GETTER(ShipTeam, s->team)
SHIP_GETTER(ShipClass, s->cls)
SHIP_GETTER(ShipEnergy, s->energy)
SHIP_GETTER(ShipKills, s->kills)
SHIP_GETTER(ShipDeaths, s->deaths)

// Velocity, in pixels per tick. The renderer leans on it for motion trails
// and the HUD reports speed, so both would otherwise have to difference
// positions across frames and get it wrong whenever a snapshot lands.
int ShipVel(lua_State* L) {
    int i = (int)luaL_checkinteger(L, 1);
    const sim_ship* s = &g_cur->ships[i];
    lua_pushnumber(L, s->vx / 65536.0);
    lua_pushnumber(L, s->vy / 65536.0);
    return 2;
}

// Upgrades held, by sim_upgrade index.
int ShipUp(lua_State* L) {
    int i = (int)luaL_checkinteger(L, 1);
    int k = (int)luaL_checkinteger(L, 2);
    lua_pushnumber(L, (k >= 0 && k < SIM_UP_COUNT) ? g_cur->ships[i].up[k] : 0);
    return 1;
}

int ShipRadius(lua_State* L) {
    int i = (int)luaL_checkinteger(L, 1);
    lua_pushnumber(L, g_cfg.classes[g_cur->ships[i].cls].radius / 256.0);
    return 1;
}

// The blast radius of this ship's bombs, which is what an explosion has to
// be drawn at for the picture to match the damage.
int ShipBombRadius(lua_State* L) {
    int i = (int)luaL_checkinteger(L, 1);
    lua_pushnumber(L, g_cfg.classes[g_cur->ships[i].cls].bomb_radius / 256.0);
    return 1;
}

int ShipCount(lua_State* L) {
    lua_pushnumber(L, g_cur->ship_count);
    return 1;
}

int ShipMaxEnergy(lua_State* L) {
    int i = (int)luaL_checkinteger(L, 1);
    lua_pushnumber(L, sim_eff_max_energy(&g_cfg.classes[g_cur->ships[i].cls],
                                         &g_cur->ships[i]));
    return 1;
}

int Tick(lua_State* L) {
    lua_pushnumber(L, g_cur->tick);
    return 1;
}

int WeaponCount(lua_State* L) {
    lua_pushnumber(L, g_cur->weapon_count);
    return 1;
}

// x, y, type, vx, vy, team, life. A bolt is drawn as a streak along its own
// velocity and tinted by whose it is, so the renderer needs all of it, and
// asking for it in seven separate calls per weapon per frame is the kind of
// cost that only shows up on the platform that matters most.
int WeaponAt(lua_State* L) {
    int i = (int)luaL_checkinteger(L, 1);
    const sim_weapon* w = &g_cur->weapons[i];
    lua_pushnumber(L, w->x / 256.0);
    lua_pushnumber(L, w->y / 256.0);
    lua_pushnumber(L, w->type);
    lua_pushnumber(L, w->vx / 65536.0);
    lua_pushnumber(L, w->vy / 65536.0);
    lua_pushnumber(L, w->team);
    lua_pushnumber(L, w->life);
    return 7;
}

int PrizeCount(lua_State* L) {
    lua_pushnumber(L, SIM_MAX_PRIZES);
    return 1;
}

// x, y, type, life. Inactive slots report life 0 and nothing else valid.
int PrizeAt(lua_State* L) {
    int i = (int)luaL_checkinteger(L, 1);
    const sim_prize* p = &g_cur->prizes[i];
    if (!p->active) {
        lua_pushboolean(L, 0);
        return 1;
    }
    lua_pushboolean(L, 1);
    lua_pushnumber(L, p->x / 256.0);
    lua_pushnumber(L, p->y / 256.0);
    lua_pushnumber(L, p->type);
    lua_pushnumber(L, p->life);
    return 5;
}

int Solid(lua_State* L) {
    int tx = (int)luaL_checkinteger(L, 1);
    int ty = (int)luaL_checkinteger(L, 2);
    int solid = (tx < 0 || ty < 0 || tx >= SIM_MAP_TILES || ty >= SIM_MAP_TILES)
                    ? 1
                    : g_map.solid[(unsigned)ty * SIM_MAP_TILES + tx];
    lua_pushboolean(L, solid);
    return 1;
}

int EventCount(lua_State* L) {
    lua_pushnumber(L, g_ev.count);
    return 1;
}

int EventAt(lua_State* L) {
    int i = (int)luaL_checkinteger(L, 1);
    lua_pushnumber(L, g_ev.e[i].type);
    lua_pushnumber(L, g_ev.e[i].a);
    lua_pushnumber(L, g_ev.e[i].b);
    lua_pushnumber(L, g_ev.e[i].v);
    return 4;
}

int FlagCount(lua_State* L) {
    lua_pushnumber(L, g_cur->flag_count);
    return 1;
}

int FlagAt(lua_State* L) {
    int i = (int)luaL_checkinteger(L, 1);
    const sim_flag* f = &g_cur->flags[i];
    lua_pushnumber(L, f->x / 256.0);
    lua_pushnumber(L, f->y / 256.0);
    lua_pushnumber(L, f->team);
    lua_pushboolean(L, f->carried);
    return 4;
}

int AddFlag(lua_State* L) {
    int tx = (int)luaL_checkinteger(L, 1);
    int ty = (int)luaL_checkinteger(L, 2);
    lua_pushnumber(L, sim_add_flag(g_cur, tx * SIM_TILE_PX, ty * SIM_TILE_PX));
    return 1;
}

int Hash(lua_State* L) {
    lua_pushnumber(L, (double)(uint32_t)(sim_hash(g_cur) & 0xffffffffu));
    return 1;
}

const luaL_reg kFunctions[] = {
    {"init", Init},
    {"init_duel", InitDuel},
    {"spawn", Spawn},
    {"step", Step},
    {"replay", Replay},
    {"apply_snapshot", ApplySnapshot},
    {"ship_count", ShipCount},
    {"ship_x", ShipX},
    {"ship_y", ShipY},
    {"ship_heading", ShipHeading},
    {"ship_alive", ShipAlive},
    {"ship_team", ShipTeam},
    {"ship_class", ShipClass},
    {"ship_energy", ShipEnergy},
    {"ship_max_energy", ShipMaxEnergy},
    {"ship_kills", ShipKills},
    {"ship_deaths", ShipDeaths},
    {"ship_vel", ShipVel},
    {"ship_up", ShipUp},
    {"ship_radius", ShipRadius},
    {"ship_bomb_radius", ShipBombRadius},
    {"tick", Tick},
    {"weapon_count", WeaponCount},
    {"weapon_at", WeaponAt},
    {"prize_count", PrizeCount},
    {"prize_at", PrizeAt},
    {"solid", Solid},
    {"event_count", EventCount},
    {"event_at", EventAt},
    {"flag_count", FlagCount},
    {"flag_at", FlagAt},
    {"add_flag", AddFlag},
    {"hash", Hash},
    {0, 0}};

void LuaInit(lua_State* L) {
    int top = lua_gettop(L);
    luaL_register(L, MODULE_NAME, kFunctions);

    // Button bits, so the Lua side never hard-codes them.
    lua_pushnumber(L, SIM_BTN_LEFT);    lua_setfield(L, -2, "BTN_LEFT");
    lua_pushnumber(L, SIM_BTN_RIGHT);   lua_setfield(L, -2, "BTN_RIGHT");
    lua_pushnumber(L, SIM_BTN_THRUST);  lua_setfield(L, -2, "BTN_THRUST");
    lua_pushnumber(L, SIM_BTN_REVERSE); lua_setfield(L, -2, "BTN_REVERSE");
    lua_pushnumber(L, SIM_BTN_FIRE);    lua_setfield(L, -2, "BTN_FIRE");
    lua_pushnumber(L, SIM_BTN_BOMB);    lua_setfield(L, -2, "BTN_BOMB");
    lua_pushnumber(L, SIM_TILE_PX);     lua_setfield(L, -2, "TILE_PX");

    // Event and weapon kinds, so the client never hard-codes an enum the
    // core is free to renumber.
    lua_pushnumber(L, SIM_EV_FIRE);      lua_setfield(L, -2, "EV_FIRE");
    lua_pushnumber(L, SIM_EV_BOUNCE);    lua_setfield(L, -2, "EV_BOUNCE");
    lua_pushnumber(L, SIM_EV_HIT);       lua_setfield(L, -2, "EV_HIT");
    lua_pushnumber(L, SIM_EV_DEATH);     lua_setfield(L, -2, "EV_DEATH");
    lua_pushnumber(L, SIM_EV_SPAWN);     lua_setfield(L, -2, "EV_SPAWN");
    lua_pushnumber(L, SIM_EV_EXPIRE);    lua_setfield(L, -2, "EV_EXPIRE");
    lua_pushnumber(L, SIM_EV_PRIZE);     lua_setfield(L, -2, "EV_PRIZE");
    lua_pushnumber(L, SIM_EV_FLAG_TAKE); lua_setfield(L, -2, "EV_FLAG_TAKE");
    lua_pushnumber(L, SIM_EV_FLAG_DROP); lua_setfield(L, -2, "EV_FLAG_DROP");
    lua_pushnumber(L, SIM_W_BULLET);     lua_setfield(L, -2, "W_BULLET");
    lua_pushnumber(L, SIM_W_BOMB);       lua_setfield(L, -2, "W_BOMB");
    lua_pushnumber(L, SIM_UP_COUNT);     lua_setfield(L, -2, "UP_COUNT");

    lua_pop(L, 1);
    assert(top == lua_gettop(L));
}

dmExtension::Result AppInitialize(dmExtension::AppParams* params) {
    return dmExtension::RESULT_OK;
}

dmExtension::Result Initialize(dmExtension::Params* params) {
    LuaInit(params->m_L);
    return dmExtension::RESULT_OK;
}

dmExtension::Result AppFinalize(dmExtension::AppParams* params) {
    return dmExtension::RESULT_OK;
}

dmExtension::Result Finalize(dmExtension::Params* params) {
    return dmExtension::RESULT_OK;
}

}  // namespace

// symbol, name, app_init, app_final, init, update, on_event, final
DM_DECLARE_EXTENSION(simcore, LIB_NAME, AppInitialize, AppFinalize, Initialize,
                     0, 0, Finalize)
