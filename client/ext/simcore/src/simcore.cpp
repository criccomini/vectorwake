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

// The vertex writer, which lives in vwbuf.cpp and is registered from here.
void VwBufInit(lua_State* L);
void VwBufFinal();

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

// The arenas are built by the core. They used to be these same magic numbers
// written out here and again in the server's Rust, which is one edit away
// from a client predicting collisions against a wall the server has not got.
int Init(lua_State* L) {
    uint32_t seed = (uint32_t)luaL_checkinteger(L, 1);
    sim_map_arena(&g_map);
    sim_settings_baseline(&g_cfg, &g_map);
    sim_init(g_cur, seed);
    return 0;
}

int InitDuel(lua_State* L) {
    uint32_t seed = (uint32_t)luaL_checkinteger(L, 1);
    sim_map_duel(&g_map);
    sim_settings_baseline(&g_cfg, &g_map);
    sim_init(g_cur, seed);
    return 0;
}

// Where the map says a ship of this team starts, or nil when it names none.
int MapSpawn(lua_State* L) {
    uint16_t tx = 0, ty = 0;
    int ok = sim_map_spawn(&g_map, (uint8_t)luaL_checkinteger(L, 1),
                           (uint32_t)luaL_checkinteger(L, 2), &tx, &ty);
    if (!ok) return 0;
    lua_pushnumber(L, tx);
    lua_pushnumber(L, ty);
    return 2;
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

// Change a pilot's hull in place. The menu is open over a running arena, so
// picking a ship must not rebuild the world -- it respawns one pilot in a
// different hull and leaves everyone else flying.
int SetClass(lua_State* L) {
    int i = (int)luaL_checkinteger(L, 1);
    int cls = (int)luaL_checkinteger(L, 2);
    lua_pushboolean(L, sim_set_ship_class(g_cur, &g_cfg, (uint8_t)i,
                                          (uint8_t)cls) == 0);
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

// The rung a trigger is on, and how many of one add-on the pilot holds on
// it. Both are per trigger, so bullets that freeze and bombs that do not is
// a thing the panel has to be able to say.
int ShipLevel(lua_State* L) {
    int i = (int)luaL_checkinteger(L, 1);
    int t = (int)luaL_checkinteger(L, 2);
    lua_pushnumber(L, (t >= 0 && t < SIM_TRIG_COUNT) ? g_cur->ships[i].level[t] : 0);
    return 1;
}

int ShipMod(lua_State* L) {
    int i = (int)luaL_checkinteger(L, 1);
    int t = (int)luaL_checkinteger(L, 2);
    int m = (int)luaL_checkinteger(L, 3);
    if (t < 0 || t >= SIM_TRIG_COUNT || m < 0 || m >= SIM_MOD_COUNT) {
        lua_pushnumber(L, 0);
        return 1;
    }
    lua_pushnumber(L, sim_mod_get(g_cur->ships[i].mods[t], m));
    return 1;
}

// How many of a charge kind a pilot is holding, and how many their hull may
// ever hold. The second is the roster's rule, and the panel needs it to know
// which slots to draw at all.
int ShipCharge(lua_State* L) {
    int i = (int)luaL_checkinteger(L, 1);
    int k = (int)luaL_checkinteger(L, 2);
    lua_pushnumber(L, (k >= 0 && k < SIM_MAX_CHARGES) ? g_cur->ships[i].charge[k] : 0);
    return 1;
}

int ChargeMax(lua_State* L) {
    int i = (int)luaL_checkinteger(L, 1);
    int k = (int)luaL_checkinteger(L, 2);
    if (k < 0 || k >= SIM_MAX_CHARGES) { lua_pushnumber(L, 0); return 1; }
    lua_pushnumber(L, g_cfg.classes[g_cur->ships[i].cls].charge_max[k]);
    return 1;
}

int ShipRadius(lua_State* L) {
    int i = (int)luaL_checkinteger(L, 1);
    lua_pushnumber(L, g_cfg.classes[g_cur->ships[i].cls].radius / 256.0);
    return 1;
}

// How big a spec's blast is, which is what an explosion has to be drawn at
// for the picture to match the damage. Zero means it has none, which is also
// how the client decides a projectile is a bolt rather than a bomb -- a
// weapon that goes off looks like one because it is one, and the simulation
// never has to carry an appearance to say so.
int SpecBlast(lua_State* L) {
    int i = (int)luaL_checkinteger(L, 1);
    if (i < 0 || i >= g_cfg.spec_count) {
        lua_pushnumber(L, 0);
        return 1;
    }
    lua_pushnumber(L, g_cfg.specs[i].blast / 256.0);
    return 1;
}

// The blast a ship's own bomb makes, for the effects that have to be sized
// before anything has been fired.
int ShipBombRadius(lua_State* L) {
    int i = (int)luaL_checkinteger(L, 1);
    const sim_ship* sh = &g_cur->ships[i];
    /* The rung this pilot is actually on: a levelled bomb is a wider one. */
    const sim_ship_class* c = &g_cfg.classes[sh->cls];
    uint8_t lvl = sh->level[SIM_TRIG_BOMB];
    uint8_t pat = SIM_NO_PATTERN;
    for (int r = lvl < SIM_MAX_RUNGS ? lvl : SIM_MAX_RUNGS - 1; r >= 0; r--) {
        if (c->trigger[SIM_TRIG_BOMB][r] != SIM_NO_PATTERN) {
            pat = c->trigger[SIM_TRIG_BOMB][r];
            break;
        }
    }
    if (pat >= g_cfg.pattern_count) {
        lua_pushnumber(L, 0);
        return 1;
    }
    lua_pushnumber(L, g_cfg.specs[g_cfg.patterns[pat].spec].blast / 256.0);
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
    lua_pushnumber(L, w->spec);
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

// x, y, life. A green carries no type: every one of them is takeable by
// everybody, and what it turns out to be is rolled where it is picked up.
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
    lua_pushnumber(L, p->life);
    return 4;
}

// Solid means "a wall that never moves", which is what the static terrain
// mesh is built from. A door is not one of those: it is drawn every frame,
// because a shut door nobody can see is a wall that does not exist.
int Solid(lua_State* L) {
    int tx = (int)luaL_checkinteger(L, 1);
    int ty = (int)luaL_checkinteger(L, 2);
    lua_pushboolean(L, SIM_TILE_CLASS(sim_tile_at(&g_map, tx, ty))
                       == SIM_TILE_SOLID);
    return 1;
}

// class, variant. Everything the renderer needs to tell one tile from another.
int TileAt(lua_State* L) {
    uint8_t t = sim_tile_at(&g_map, (int32_t)luaL_checkinteger(L, 1),
                            (int32_t)luaL_checkinteger(L, 2));
    lua_pushnumber(L, SIM_TILE_CLASS(t));
    lua_pushnumber(L, SIM_TILE_VARIANT(t));
    return 2;
}

int DoorOpen(lua_State* L) {
    lua_pushboolean(L, sim_door_open(&g_cfg, g_cur->tick,
                                     (uint8_t)luaL_checkinteger(L, 1)));
    return 1;
}

int InSafe(lua_State* L) {
    int i = (int)luaL_checkinteger(L, 1);
    lua_pushboolean(L, sim_in_safe(&g_map, g_cur->ships[i].x, g_cur->ships[i].y));
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

// A map arrives from the zone before anything else does, because prediction
// runs collision locally and cannot do that against a room it has not got.
int ApplyMap(lua_State* L) {
    size_t len = 0;
    const char* data = luaL_checklstring(L, 1, &len);
    int r = sim_map_unpack(&g_map, (const uint8_t*)data, (int)len);
    if (r == 0) sim_settings_baseline(&g_cfg, &g_map);
    lua_pushnumber(L, r);
    return 1;
}

// And the zone's tuning, straight after it. Until this arrived a client
// predicted on whatever numbers its own build compiled, which held only for
// as long as no zone tuned anything -- and not at all once one adds a
// weapon, because a spec is an index and two tables do not agree on what an
// index means.
int ApplySettings(lua_State* L) {
    size_t len = 0;
    const char* data = luaL_checklstring(L, 1, &len);
    int r = sim_settings_unpack(&g_cfg, (const uint8_t*)data, (int)len);
    lua_pushnumber(L, r);
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
    {"map_spawn", MapSpawn},
    {"set_class", SetClass},
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
    {"ship_level", ShipLevel},
    {"ship_charge", ShipCharge},
    {"charge_max", ChargeMax},
    {"ship_mod", ShipMod},
    {"ship_radius", ShipRadius},
    {"ship_bomb_radius", ShipBombRadius},
    {"spec_blast", SpecBlast},
    {"tick", Tick},
    {"weapon_count", WeaponCount},
    {"weapon_at", WeaponAt},
    {"prize_count", PrizeCount},
    {"prize_at", PrizeAt},
    {"solid", Solid},
    {"tile", TileAt},
    {"door_open", DoorOpen},
    {"in_safe", InSafe},
    {"event_count", EventCount},
    {"event_at", EventAt},
    {"flag_count", FlagCount},
    {"flag_at", FlagAt},
    {"add_flag", AddFlag},
    {"hash", Hash},
    {"apply_map", ApplyMap},
    {"apply_settings", ApplySettings},
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

    // Tile classes, so the renderer never hard-codes one.
    lua_pushnumber(L, SIM_TILE_EMPTY);    lua_setfield(L, -2, "T_EMPTY");
    lua_pushnumber(L, SIM_TILE_SOLID);    lua_setfield(L, -2, "T_SOLID");
    lua_pushnumber(L, SIM_TILE_SAFE);     lua_setfield(L, -2, "T_SAFE");
    lua_pushnumber(L, SIM_TILE_DOOR);     lua_setfield(L, -2, "T_DOOR");
    lua_pushnumber(L, SIM_TILE_GOAL);     lua_setfield(L, -2, "T_GOAL");
    lua_pushnumber(L, SIM_TILE_WORMHOLE); lua_setfield(L, -2, "T_WORMHOLE");
    lua_pushnumber(L, SIM_TILE_OVER);     lua_setfield(L, -2, "T_OVER");
    lua_pushnumber(L, SIM_TILE_UNDER);    lua_setfield(L, -2, "T_UNDER");
    lua_pushnumber(L, SIM_TILE_TURF);     lua_setfield(L, -2, "T_TURF");

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
    lua_pushnumber(L, SIM_UP_COUNT);     lua_setfield(L, -2, "UP_COUNT");

    // The tech tree's shape, so the panel never hard-codes a layout the core
    // is free to change. The prize space is flat: stats, then a level per
    // trigger, then an add-on per trigger per kind.
    lua_pushnumber(L, SIM_TRIG_COUNT);   lua_setfield(L, -2, "TRIG_COUNT");
    lua_pushnumber(L, SIM_TRIG_GUN);     lua_setfield(L, -2, "TRIG_GUN");
    lua_pushnumber(L, SIM_TRIG_BOMB);    lua_setfield(L, -2, "TRIG_BOMB");
    lua_pushnumber(L, SIM_MOD_COUNT);    lua_setfield(L, -2, "MOD_COUNT");
    lua_pushnumber(L, SIM_PRIZE_COUNT);  lua_setfield(L, -2, "PRIZE_COUNT");
    lua_pushnumber(L, SIM_PRIZE_LEVEL(0)); lua_setfield(L, -2, "PRIZE_LEVEL0");
    lua_pushnumber(L, SIM_PRIZE_MOD(0, 0)); lua_setfield(L, -2, "PRIZE_MOD0");
    lua_pushnumber(L, SIM_PRIZE_CHARGE(0)); lua_setfield(L, -2, "PRIZE_CHARGE0");
    lua_pushnumber(L, SIM_MAX_CHARGES);  lua_setfield(L, -2, "MAX_CHARGES");
    lua_pushnumber(L, SIM_BTN_USE);      lua_setfield(L, -2, "BTN_USE");
    lua_pushnumber(L, 1u << SIM_BTN_SLOT_SHIFT); lua_setfield(L, -2, "BTN_SLOT_STEP");
    lua_pushnumber(L, SIM_EV_CHARGE);    lua_setfield(L, -2, "EV_CHARGE");

    lua_pop(L, 1);
    assert(top == lua_gettop(L));
}

dmExtension::Result AppInitialize(dmExtension::AppParams* params) {
    return dmExtension::RESULT_OK;
}

dmExtension::Result Initialize(dmExtension::Params* params) {
    LuaInit(params->m_L);
    VwBufInit(params->m_L);
    return dmExtension::RESULT_OK;
}

dmExtension::Result AppFinalize(dmExtension::AppParams* params) {
    return dmExtension::RESULT_OK;
}

dmExtension::Result Finalize(dmExtension::Params* params) {
    VwBufFinal();
    return dmExtension::RESULT_OK;
}

}  // namespace

// symbol, name, app_init, app_final, init, update, on_event, final
DM_DECLARE_EXTENSION(simcore, LIB_NAME, AppInitialize, AppFinalize, Initialize,
                     0, 0, Finalize)
