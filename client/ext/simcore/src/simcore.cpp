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

#include <math.h>

#include "flight.h"
#include "smoothing.h"

// The vertex writer, which lives in vwbuf.cpp and is registered from here.
void VwBufInit(lua_State* L);
void VwBufFinal();

// The sound kit, same arrangement, in vwsfx.cpp over sfx.c.
void VwSfxInit(lua_State* L);
void VwSfxFinal();

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
// Where a snapshot is decoded before it is believed. sim_unpack zeroes the
// state it writes into before it validates anything, so unpacking straight
// into the live world made every refusal an erasure: the one truncated or
// skewed message emptied the arena, and the caller's "nonzero means the old
// world is kept" was not true of any rejection the parser itself makes.
sim_state g_snap;

// Whose death prediction may conclude: this client's own pilot and nobody
// else (decision 40). Held beside g_cfg rather than only in it, because a
// settings message and a fresh map both rebuild g_cfg from scratch, and the
// rule about who is asking has to survive the zone retuning what the game
// is. 255 until net.lua says who we are, which is also what watching is:
// nobody dies locally, and every death arrives as the zone's news.
uint8_t g_mortal_ship = 255;

void ReapplyMortal() {
    g_cfg.deathless = 1;
    g_cfg.mortal_ship = g_mortal_ship;
}

// A ship index a caller may actually use. The ships array is SIM_MAX_SHIPS
// wide and 255 is the wire's "nobody", so an unguarded accessor read whatever
// memory sat past the array and said nothing -- and this client's worst bugs
// are the quiet ones. A watcher's code paths never index the sim with their
// 255; this is the backstop that makes the next such bug loud instead.
static int CheckShip(lua_State* L) {
    int i = (int)luaL_checkinteger(L, 1);
    if (i < 0 || i >= SIM_MAX_SHIPS) {
        return luaL_error(L, "ship index %d out of range", i);
    }
    return i;
}


// The arenas are built by the core. They used to be these same magic numbers
// written out here and again in the server's Rust, which is one edit away
// from a client predicting collisions against a wall the server has not got.
int Init(lua_State* L) {
    uint32_t seed = (uint32_t)luaL_checkinteger(L, 1);
    sim_map_arena(&g_map);
    sim_settings_baseline(&g_cfg, &g_map);
    ReapplyMortal();
    sim_init(g_cur, seed);
    return 0;
}

// How big this map is, in tiles. Not the array's bound: a match room is 160
// and the arena is a thousand, and anything drawing the whole of one wants to
// know which it is holding.
int MapSize(lua_State* L) {
    lua_pushnumber(L, g_map.w);
    lua_pushnumber(L, g_map.h);
    return 2;
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

// Remote ships coast: only the pilot's own buttons are replayed, and everyone
// else extrapolates ballistically from their snapshot velocity.
//
// Holding each remote ship's last-seen movement buttons through the predicted
// ticks was tried here and reverted the same day. It read well on paper --
// btn_prev already rides in every snapshot, and a sustained thrust or turn is
// exactly what a ballistic guess misses -- and it survived a test with two
// human pilots, because people hold keys for hundreds of milliseconds. Bots do
// not. Their steering is bang-bang, flipping buttons many times a second, so
// the button a snapshot happens to catch is wrong about half the time, and
// holding it for the whole lead amplifies ten milliseconds of dither into a
// lead-sized error that reverses direction with every correction: a room full
// of hulls twitching at snapshot rate, which is what a player filmed and
// reported the day it shipped. A tracked hull in that recording swung about
// twelve pixels against the world, alternating sign at snapshot rate.
// Frictionless flight is why coasting wins: velocity is the whole short-term
// truth of a ship, and the accelerations are too small to matter across a
// snapshot gap.
int Replay(lua_State* L) {
    sim_input in;
    in.ship = (uint8_t)CheckShip(L);
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
    int rc = sim_unpack(&g_snap, g_net, (int)len);
    if (rc == 0) *g_cur = g_snap;
    lua_pushnumber(L, rc);
    return 1;
}

// --- what the screen shows, against what the simulation holds ---------------
//
// The core runs at 100 Hz and no display refreshes at a multiple of it. Drawing
// the newest tick therefore advances the world by one tick on some frames and
// two on others at 60 Hz, and by one or none at 120: a speed ripple on every
// frame of every screen, on the camera and everything in it. Interpolating
// between the last two ticks by where the frame actually falls costs one tick
// of visual latency, ten milliseconds and less than a frame anywhere, and buys
// a constant one in place of a random nought-to-ten. Constant latency is
// invisible. Varying latency is the judder.
//
// The other jitter is the network's. A snapshot replaces state outright, so a
// remote ship that was extrapolated wrong snaps to
// the truth. `smooth_capture` and `smooth_settle` bracket that: whatever the
// screen was last asserting about a ship is held, and the difference between it
// and the truth is carried as an offset that decays away over about a tenth of a
// second. The simulation is never touched; only the drawing lies, briefly, and
// then stops.
//
// Both live here rather than at the call sites because there are twenty of those
// and one of them being missed is worse than none of them being fixed: a hull
// that judders against its own health bar reads as broken in a way a hull that
// judders with everything else does not.

float g_alpha = 0.0f;
float g_off_x[SIM_MAX_SHIPS];
float g_off_y[SIM_MAX_SHIPS];
// The heading's own owed correction, in turn units, decayed with the two
// above. Position always had this and heading never did, and under coasting
// the difference is the whole of how a remote ship rotates: prediction holds
// no buttons for it, so its heading is frozen between snapshots and all of
// its actual turning arrives in snapshot-sized lumps. Note this eases only
// corrections of the past; it predicts nothing, which is the line the
// held-button experiment crossed and the reason that one is gone.
float g_off_h[SIM_MAX_SHIPS];
int32_t g_held_x[SIM_MAX_SHIPS];
int32_t g_held_y[SIM_MAX_SHIPS];
uint16_t g_held_h[SIM_MAX_SHIPS];
uint16_t g_held_repel[SIM_MAX_SHIPS];
uint8_t g_held[SIM_MAX_SHIPS];
// A correction caused by an enemy repel is continuous flight the client could
// not predict, not a teleport. Keep that presentation debt on its own faster
// decay until it has been paid.
uint8_t g_repel_debt[SIM_MAX_SHIPS];

// Local clock steering moves the camera, while a remote correction moves one
// target against truthful projectiles. They need different limits. The local
// envelope keeps the measured camera stability. The remote envelope stops an
// opponent being drawn more than one tile away from the server's position and
// clears large discontinuities sooner.
const double LOCAL_TURN_SNAP = 65536.0 * 90.0 / 360.0;
const double REMOTE_TURN_SNAP = 65536.0 * 45.0 / 360.0;
const double LOCAL_TURN_MAX = 65536.0 * 30.0 / 360.0;
const double REMOTE_TURN_MAX = 65536.0 * 15.0 / 360.0;
const double LOCAL_HALF_LIFE = 0.08;
const double REMOTE_HALF_LIFE = 0.05;
const double INTERPOLATION_SNAP = 64.0;

// Whether the other buffer really holds the tick before this one.
//
// `sim_step` writes into the spare and swaps, so it does -- except across an
// arriving snapshot, which rewrites the current state from the wire and leaves
// the spare holding whatever tick it held before. Asking the tick numbers is
// self-checking, where a flag would be one more thing to remember to clear.
bool has_prev() {
    return g_nxt->tick + 1 == g_cur->tick;
}

double blend(int32_t prev, int32_t cur) {
    if (!has_prev()) return cur / 256.0;
    return (prev + (cur - prev) * (double)g_alpha) / 256.0;
}

// Angles are a wrapping sixteen-bit turn, so the blend has to take the short way
// round or a hull crossing north spins the long way once per lap.
double blend_turn(uint16_t prev, uint16_t cur) {
    if (!has_prev()) return cur;
    int32_t d = (int32_t)cur - (int32_t)prev;
    if (d > 32768) d -= 65536;
    if (d < -32768) d += 65536;
    double h = (double)prev + (double)d * (double)g_alpha;
    if (h < 0.0) h += 65536.0;
    if (h >= 65536.0) h -= 65536.0;
    return h;
}

// Whether a ship's two ticks are the same continuous ship. A respawn moves a
// hull the width of the map between one tick and the next, and interpolating
// through that draws it streaking across the room.
bool ship_continuous(const sim_ship* p, const sim_ship* c) {
    if (!p->active || !c->active || p->alive != c->alive) return false;
    double dx = (c->x - p->x) / 256.0, dy = (c->y - p->y) / 256.0;
    return dx * dx + dy * dy < INTERPOLATION_SNAP * INTERPOLATION_SNAP;
}

// Read-only views. Rendering asks; it never writes.
#define SHIP_GETTER(NAME, EXPR)                          \
    int NAME(lua_State* L) {                             \
        int i = CheckShip(L);                            \
        const sim_ship* s = &g_cur->ships[i];            \
        (void)s;                                         \
        lua_pushnumber(L, (EXPR));                       \
        return 1;                                        \
    }

// Where a hull is, as the frame being drawn should show it: between the last
// two ticks, plus whatever the drawing is still owed from the last correction.
// Everything that draws asks for this, which is why it is the plain name.
#define SHIP_SEEN(NAME, AXIS, OFF)                                     \
    int NAME(lua_State* L) {                                           \
        int i = CheckShip(L);                                          \
        const sim_ship* c = &g_cur->ships[i];                          \
        const sim_ship* p = &g_nxt->ships[i];                          \
        double v = ship_continuous(p, c) ? blend(p->AXIS, c->AXIS)     \
                                         : c->AXIS / 256.0;            \
        lua_pushnumber(L, v + OFF[i]);                                 \
        return 1;                                                      \
    }
SHIP_SEEN(ShipX, x, g_off_x)
SHIP_SEEN(ShipY, y, g_off_y)

int ShipHeading(lua_State* L) {
    int i = CheckShip(L);
    const sim_ship* c = &g_cur->ships[i];
    const sim_ship* p = &g_nxt->ships[i];
    double h = ship_continuous(p, c) ? blend_turn(p->heading, c->heading)
                                     : (double)c->heading;
    // Plus whatever turn the drawing still owes from the last correction,
    // exactly as the position getters add theirs.
    h += (double)g_off_h[i];
    if (h < 0.0) h += 65536.0;
    if (h >= 65536.0) h -= 65536.0;
    lua_pushnumber(L, h);
    return 1;
}

// The tick as the simulation actually holds it, for the two things that must
// not be told a comfortable story: measuring how far a prediction missed by,
// and deciding what the pilot's own hands asked for.
SHIP_GETTER(ShipXRaw, s->x / 256.0)
SHIP_GETTER(ShipYRaw, s->y / 256.0)
SHIP_GETTER(ShipHeadingRaw, s->heading)
SHIP_GETTER(ShipAlive, s->alive)
SHIP_GETTER(ShipActive, s->active)
int ShipPrivate(lua_State* L) {
    int i = CheckShip(L);
    lua_pushboolean(L, g_cur->ships[i].public_only == 0);
    return 1;
}
SHIP_GETTER(ShipTeam, s->team)
SHIP_GETTER(ShipClass, s->cls)
SHIP_GETTER(ShipEnergy, s->energy)
SHIP_GETTER(ShipKills, s->kills)
SHIP_GETTER(ShipDeaths, s->deaths)
SHIP_GETTER(ShipAssists, s->assists)

// Velocity, in pixels per tick. The renderer leans on it for motion trails
// and the HUD reports speed, so both would otherwise have to difference
// positions across frames and get it wrong whenever a snapshot lands.
int ShipVel(lua_State* L) {
    int i = CheckShip(L);
    const sim_ship* s = &g_cur->ships[i];
    lua_pushnumber(L, s->vx / 65536.0);
    lua_pushnumber(L, s->vy / 65536.0);
    return 2;
}

// The authoritative shove still carried by this hull: ticks left and speed in
// pixels per tick. Rendering has no use for it, but reconciliation diagnostics
// need to tell a network correction from a repel the client could not foresee.
int ShipRepel(lua_State* L) {
    int i = CheckShip(L);
    const sim_ship* s = &g_cur->ships[i];
    lua_pushnumber(L, s->repel);
    lua_pushnumber(L, s->repel_speed / 65536.0);
    return 2;
}

// Stat steps dealt onto the hull, by sim_upgrade index. This is what the kit
// bought, not what the kit asked for: a slot over the hull's ceiling grants
// nothing, and the panel should draw the ship the pilot is actually flying.
int ShipUp(lua_State* L) {
    int i = CheckShip(L);
    int k = (int)luaL_checkinteger(L, 2);
    lua_pushnumber(L, (k >= 0 && k < SIM_UP_COUNT) ? g_cur->ships[i].up[k] : 0);
    return 1;
}

// The rung a trigger is on, and how many of one add-on the pilot holds on
// it. Both are per trigger, so bullets that freeze and bombs that do not is
// a thing the panel has to be able to say.
int ShipLevel(lua_State* L) {
    int i = CheckShip(L);
    int t = (int)luaL_checkinteger(L, 2);
    lua_pushnumber(L, (t >= 0 && t < SIM_TRIG_COUNT) ? g_cur->ships[i].level[t] : 0);
    return 1;
}

// A hull's footprint, in px: how far it reaches past the nose, behind
// the tail, and to either side.
//
// One of the three things that tell one hull from another, beside its flight
// row and its profile. Every rectangle spends the same 625 square pixels;
// what a hull chooses is which way to spend them.
int HullExtent(lua_State* L) {
    int cls = (int)luaL_checkinteger(L, 1);
    if (cls < 0 || cls >= g_cfg.class_count) { lua_pushnil(L); return 1; }
    const sim_ship_class* c = &g_cfg.classes[cls];
    lua_pushnumber(L, c->fore / 256.0);
    lua_pushnumber(L, c->aft / 256.0);
    lua_pushnumber(L, c->halfw / 256.0);
    return 3;
}

// What a hull flies with, over the flat slot space.
//
// The profile: dealt at every spawn, owned by nobody, and the whole of what
// tells one ship from another besides its flight row and its shape. The ship
// page reads it to draw what a hull carries.
//
// Three functions stood here, and all three were about a kit a pilot spent
// thirty points on: the arena's ceiling, the account's entitlements, and the
// starter kit a seat flew before it had chosen. There is nothing to choose.
// A hull's flight, in the core's own units: speed, thrust, rotation, energy
// and recharge.
//
// Raw rather than converted back to the settings file's units, because the
// ship page draws these as bars against the rest of the roster and a bar only
// needs the order. A conversion back would be an inverse of five different
// scales kept in step with the core by hand, to display a number nobody reads
// off a bar anyway.
int ClassFlight(lua_State* L) {
    int cls = (int)luaL_checkinteger(L, 1);
    if (cls < 0 || cls >= g_cfg.class_count) { lua_pushnil(L); return 1; }
    const sim_ship_class* c = &g_cfg.classes[cls];
    lua_pushnumber(L, c->max_speed);
    lua_pushnumber(L, c->thrust);
    lua_pushnumber(L, c->rot);
    lua_pushnumber(L, c->max_energy);
    lua_pushnumber(L, c->recharge);
    return 5;
}

int ClassKit(lua_State* L) {
    int cls = (int)luaL_checkinteger(L, 1);
    if (cls < 0 || cls >= g_cfg.class_count) { lua_pushnil(L); return 1; }
    lua_createtable(L, SIM_SLOT_COUNT, 0);
    for (int k = 0; k < SIM_SLOT_COUNT; k++) {
        lua_pushnumber(L, g_cfg.classes[cls].kit[k]);
        lua_rawseti(L, -2, k + 1);
    }
    return 1;
}


// How deep this ship's rack is in one slot, which is a fact about the pilot
// again.
//
// It read the ship's own build when a kit was thirty points, then the class
// profile when a hull was the whole ship, and it is back on the ship because
// a build is a pilot's once more: two people in the same hull no longer carry
// the same rack. The corner stack and the touch pads ask this every frame to
// draw the empty places beside the full ones, which is why it stays an
// accessor rather than becoming a table they would have to allocate.
int ShipKit(lua_State* L) {
    int i = CheckShip(L);
    int slot = (int)luaL_checkinteger(L, 2);
    if (slot < 0 || slot >= SIM_SLOT_COUNT) {
        lua_pushnumber(L, 0);
        return 1;
    }
    lua_pushnumber(L, g_cur->ships[i].kit[slot]);
    return 1;
}

// How high one slot goes for a hull, which is where a stepper stops.
//
// The core's own answer rather than one worked out here: a ceiling drawn from
// a different arithmetic than the one the arena enforces is a key that looks
// pressable and does nothing.
int SlotCap(lua_State* L) {
    int cls = (int)luaL_checkinteger(L, 1);
    int slot = (int)luaL_checkinteger(L, 2);
    if (cls < 0 || cls >= g_cfg.class_count || slot < 0
        || slot >= SIM_SLOT_COUNT) {
        lua_pushnumber(L, 0);
        return 1;
    }
    lua_pushnumber(L, sim_slot_cap(&g_cfg, (uint8_t)cls, (uint8_t)slot));
    return 1;
}

int ShipMod(lua_State* L) {
    int i = CheckShip(L);
    int t = (int)luaL_checkinteger(L, 2);
    int m = (int)luaL_checkinteger(L, 3);
    if (t < 0 || t >= SIM_TRIG_COUNT || m < 0 || m >= SIM_MOD_COUNT) {
        lua_pushnumber(L, 0);
        return 1;
    }
    lua_pushnumber(L, sim_mod_get(g_cur->ships[i].mods[t], m));
    return 1;
}

// Whether this pilot has switched multifire off. The add-on is still held and
// still shows in the loadout; this is the trigger's own setting, and the panel
// says which way it is set because a fan that stopped fanning is otherwise a
// weapon that looks broken.
int ShipMultiOff(lua_State* L) {
    int i = CheckShip(L);
    lua_pushboolean(L, g_cur->ships[i].multi_off != 0);
    return 1;
}

// Ticks left before this pilot's trigger answers again.
//
// It is here for what it says about somebody else. A shot sets it and every
// tick takes one off, so it only ever counts down, apart from the tick a
// trigger is pulled, and a client predicts nobody's trigger but its own. A
// remote pilot's cooldown going *up* therefore came from the wire, and means
// they fired. See world.shots.
//
// The core keeps one of these per trigger now, and this hands back the longer.
// Every trigger locks every other, so the pair moves together almost always,
// and the one exception, an EMP bomb leaving its own guns running, still
// raises the bomb's. So a rise in the larger is a shot fired whichever
// trigger fired it, which is all this is asked.
int ShipCooldown(lua_State* L) {
    int i = CheckShip(L);
    const sim_ship* sh = &g_cur->ships[i];
    uint16_t hi = sh->fire_cooldown[0];
    for (int t = 1; t < SIM_TRIG_COUNT; t++)
        if (sh->fire_cooldown[t] > hi) hi = sh->fire_cooldown[t];
    lua_pushnumber(L, hi);
    return 1;
}

// The same clock, one trigger at a time, and about your own ship rather than
// somebody else's.
//
// ShipCooldown above hands back the longer of the pair because it is asked a
// question about a stranger: did they just fire. A control drawn on the
// trigger it belongs to is asking something narrower, how long until this one
// answers, and the pair does come apart -- an EMP bomb leaves its own guns
// running -- so the gun's key must read the gun's counter.
int ShipTriggerWait(lua_State* L) {
    int i = CheckShip(L);
    int t = (int)luaL_checkinteger(L, 2);
    lua_pushnumber(L, (t >= 0 && t < SIM_TRIG_COUNT)
                          ? g_cur->ships[i].fire_cooldown[t] : 0);
    return 1;
}

// And how long that wait is when it starts: the delay of the pattern this
// hull's trigger fires at the rung it is on.
//
// Asked of the ship rather than of a class and a rung, because a control
// showing how far a recovery has run needs both ends of the same fraction and
// getting them from two different questions is how they come apart. Zero for a
// trigger the hull does not carry, which is the same answer a rack-less hull
// gives everywhere else.
int ShipTriggerDelay(lua_State* L) {
    int i = CheckShip(L);
    int t = (int)luaL_checkinteger(L, 2);
    if (t < 0 || t >= SIM_TRIG_COUNT) { lua_pushnumber(L, 0); return 1; }
    const sim_ship* sh = &g_cur->ships[i];
    int lvl = sh->level[t];
    if (lvl < 0 || lvl >= SIM_MAX_RUNGS) { lua_pushnumber(L, 0); return 1; }
    uint8_t pat = g_cfg.classes[sh->cls].trigger[t][lvl];
    if (pat == SIM_NO_PATTERN || pat >= g_cfg.pattern_count) {
        lua_pushnumber(L, 0);
        return 1;
    }
    lua_pushnumber(L, g_cfg.patterns[pat].delay);
    return 1;
}

// How long this room lets a ship sit in a safe zone before it takes the seat
// back, in ticks, and zero when it never does.
//
// The core neither counts this nor acts on it: the room keeps the clock and
// makes the decision. What the client needs is the number the room is counting
// against, so the countdown it draws is the one that is actually running.
int SafeLimit(lua_State* L) {
    lua_pushnumber(L, g_cfg.safe_limit);
    return 1;
}

// Whether to mark the map's spawn tiles.
//
// This used to fold `spawn_radius` in and refuse the mark whenever a zone set
// one, because a radius then meant "ignore the tiles and scatter about the
// middle" and a mark on a tile nobody arrived at was a lie. A radius is now
// how precisely a ship lands on the tile, so the tile is still the answer to
// where somebody is about to appear and the mark is still true. What it is no
// longer is exact, which is the honest reading of a mark on a map anyway.
int ShowSpawns(lua_State* L) {
    lua_pushboolean(L, g_cfg.show_spawns);
    return 1;
}

// How many of a charge kind a pilot is holding, and how many their hull may
// ever hold. The second is the roster's rule, and the panel needs it to know
// which slots to draw at all.
int ShipCharge(lua_State* L) {
    int i = CheckShip(L);
    int k = (int)luaL_checkinteger(L, 2);
    lua_pushnumber(L, (k >= 0 && k < SIM_MAX_CHARGES) ? g_cur->ships[i].charge[k] : 0);
    return 1;
}

// Ticks before this pilot may throw that kind of charge again, and how many
// the kind waits in the first place. Two numbers rather than a fraction,
// because the fraction is a drawing decision and this file does not make
// those: a corner that washes a row out and a pad that does the same want the
// same two numbers and divide them differently.
//
// The second is the zone's, off the pattern, so a kind the zone leaves without
// a delay reports zero and nothing drawn from it ever dims.
int ShipChargeWait(lua_State* L) {
    int i = CheckShip(L);
    int k = (int)luaL_checkinteger(L, 2);
    lua_pushnumber(L, (k >= 0 && k < SIM_MAX_CHARGES)
                          ? g_cur->ships[i].charge_cooldown[k] : 0);
    return 1;
}

int ChargeDelay(lua_State* L) {
    int k = (int)luaL_checkinteger(L, 1);
    uint8_t pat = (k >= 0 && k < SIM_MAX_CHARGES) ? g_cfg.charge[k]
                                                  : SIM_NO_PATTERN;
    if (pat == SIM_NO_PATTERN || pat >= g_cfg.pattern_count) {
        lua_pushnumber(L, 0);
        return 1;
    }
    lua_pushnumber(L, g_cfg.patterns[pat].delay);
    return 1;
}

// Whether this hull has the trigger at all, as opposed to being on rung zero
// of it. A hull with no bomb rack carries SIM_NO_PATTERN at rung zero, which
// is a different thing from carrying a bomb that happens to be weak -- and the
// interface has to tell them apart, because a control for a weapon that cannot
// exist is a control that does nothing when pressed.
int HasTrigger(lua_State* L) {
    int i = CheckShip(L);
    int t = (int)luaL_checkinteger(L, 2);
    if (t < 0 || t >= SIM_TRIG_COUNT) { lua_pushboolean(L, 0); return 1; }
    const sim_ship_class* c = &g_cfg.classes[g_cur->ships[i].cls];
    lua_pushboolean(L, c->trigger[t][0] != SIM_NO_PATTERN);
    return 1;
}

// Kills without dying, and whether they add up to a streak by this zone's
// reckoning. Both come off the snapshot and the settings the client already
// holds, so a hull on a tear can be drawn as one without a message for it.
//
// The threshold is asked of the core rather than compared here, because the
// same comparison decides what the pilot is worth and the two must not be
// able to disagree.
SHIP_GETTER(ShipStreak, s->streak)

int ShipOnStreak(lua_State* L) {
    int i = CheckShip(L);
    lua_pushboolean(L, sim_on_streak(&g_cfg, &g_cur->ships[i]));
    return 1;
}

// What a streak takes in this zone, for the one thing the client says rather
// than draws: how many kills the pilot the arena just named has strung
// together.
int StreakKills(lua_State* L) {
    lua_pushnumber(L, g_cfg.streak_kills);
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

// The radius a spec's fuse senses at, in world pixels; 0 is a contact round.
//
// It comes from the spec rather than from a constant in the renderer that a
// zone could quietly make a lie.
int SpecTrigger(lua_State* L) {
    int i = (int)luaL_checkinteger(L, 1);
    if (i < 0 || i >= g_cfg.spec_count) {
        lua_pushnumber(L, 0);
        return 1;
    }
    lua_pushnumber(L, g_cfg.specs[i].trigger / 256.0);
    return 1;
}

// How long a spec's rounds live, in ticks.
//
// Read for one reason: a weapon whose life is a single tick is one no watcher
// can ever be sent. It is spawned and gone inside one step, so it appears in a
// snapshot only when the tick it was fired on happens to be a snapshot tick,
// and a client that misses it has nothing to draw and no way to know it
// happened. The repel is exactly that weapon. See `charges` in world.lua.
int SpecLife(lua_State* L) {
    int i = (int)luaL_checkinteger(L, 1);
    if (i < 0 || i >= g_cfg.spec_count) {
        lua_pushnumber(L, 0);
        return 1;
    }
    lua_pushnumber(L, g_cfg.specs[i].life);
    return 1;
}

// The spec a charge slot fires, or -1 for a slot this zone leaves empty. A
// charge is a pattern plus an inventory, and the pattern names the spec, so
// this is two hops the client would otherwise need two more bindings to make.
int ChargeSpec(lua_State* L) {
    int k = (int)luaL_checkinteger(L, 1);
    if (k < 0 || k >= SIM_MAX_CHARGES) {
        lua_pushnumber(L, -1);
        return 1;
    }
    uint8_t pat = g_cfg.charge[k];
    if (pat == SIM_NO_PATTERN || pat >= g_cfg.pattern_count) {
        lua_pushnumber(L, -1);
        return 1;
    }
    lua_pushnumber(L, g_cfg.patterns[pat].spec);
    return 1;
}

// How many fragments a bomb breaks into at this many rungs of shrapnel.
//
// Shrapnel is the one add-on whose magnitude is another weapon rather than a
// number, so the zone says how many by naming a pattern per rung and the count
// lives on the pattern. The corner and the pads draw one tick per fragment,
// and the alternative was a ramp written into the drawing: the baseline
// doubles 2, 4, 8 while the drawing said 6, 8, 10, and a zone free to put any
// pattern on a rung could disagree with it by any amount.
//
// The clamp matches `compose` in sim.c exactly, so what a mark counts and what
// a bomb throws come off the same shelf.
int ShrapCount(lua_State* L) {
    int n = (int)luaL_checkinteger(L, 1);
    if (n <= 0) {
        lua_pushinteger(L, 0);
        return 1;
    }
    uint8_t pat = g_cfg.mod_splinter[n < SIM_MAX_RUNGS ? n : SIM_MAX_RUNGS - 1];
    if (pat == SIM_NO_PATTERN || pat >= g_cfg.pattern_count) {
        lua_pushinteger(L, 0);
        return 1;
    }
    lua_pushinteger(L, g_cfg.patterns[pat].count);
    return 1;
}

// The volley a pull throws: how many rounds leave, and how far apart.
//
// Same argument as ShrapCount above, and the same fault it was written to
// fix. The corner and the pads draw every round a trigger fires at the angle
// it fires it, and the alternative was the two spreads copied into the
// drawing as constants. The baseline opens a pair seven and a half degrees
// and a fan fifteen, adds one round a rung, and ships every gun pattern at
// one round; a zone is free to disagree with all three, and the drawing
// would have gone on saying what the baseline said.
//
// Read the way `compose` in sim.c reads it, off the pattern the rung
// actually fires. Both numbers come back in the core's own units, spacing
// included: heading units at 65536 to the turn, the way the pattern holds
// it, so this does no arithmetic of its own and the drawing converts to the
// unit it draws in. A count of zero means there is no pattern there to ask
// about, and a spacing of zero on a count above one is the scatter
// encoding, which is a roll rather than an angle and nothing a still mark
// can show.
int SprayShape(lua_State* L) {
    int cls = (int)luaL_checkinteger(L, 1);
    int t = (int)luaL_checkinteger(L, 2);
    int lvl = (int)luaL_checkinteger(L, 3);
    int n = (int)luaL_checkinteger(L, 4);
    if (cls < 0 || cls >= g_cfg.class_count || t < 0 || t >= SIM_TRIG_COUNT
        || lvl < 0 || lvl >= SIM_MAX_RUNGS) {
        lua_pushinteger(L, 0);
        lua_pushnumber(L, 0);
        return 2;
    }
    uint8_t pat = g_cfg.classes[cls].trigger[t][lvl];
    if (pat == SIM_NO_PATTERN || pat >= g_cfg.pattern_count) {
        lua_pushinteger(L, 0);
        lua_pushnumber(L, 0);
        return 2;
    }
    const sim_fire_pattern* p = &g_cfg.patterns[pat];
    int32_t count = p->count ? p->count : 1;
    uint16_t spacing = p->spacing;
    if (n > 0) {
        count += n * g_cfg.mod_step[SIM_MOD_MULTI];
        if (count > 255) count = 255;
        // A pattern that already fans keeps its own angle; one that does not
        // gets the pair's spacing at one rung and the zone's fan above it.
        if (spacing == 0)
            spacing = (n == 1) ? g_cfg.mod_pair_spread : g_cfg.mod_spread;
    }
    lua_pushinteger(L, count);
    lua_pushinteger(L, spacing);
    return 2;
}

// Which rung of the tech tree fires this spec, learned from the ladders. A
// spec deliberately carries no level -- it says what a projectile does, not
// where it came from -- but every hull's trigger ladder says which rung each
// pattern sits on, and a pattern names its spec, so the fact is there to be
// read. The highest rung found wins, and -1 is a spec on no ladder at all: a
// charge like the burst, or a bomb's shrapnel, which is its own kind of
// answer and drawn as one.
int SpecLevel(lua_State* L) {
    int i = (int)luaL_checkinteger(L, 1);
    int lvl = -1;
    if (i >= 0 && i < g_cfg.spec_count) {
        for (int c = 0; c < g_cfg.class_count; c++) {
            for (int t = 0; t < SIM_TRIG_COUNT; t++) {
                for (int r = 0; r < SIM_MAX_RUNGS; r++) {
                    uint8_t pat = g_cfg.classes[c].trigger[t][r];
                    if (pat == SIM_NO_PATTERN || pat >= g_cfg.pattern_count) continue;
                    if (g_cfg.patterns[pat].spec == i && r > lvl) lvl = r;
                }
            }
        }
    }
    lua_pushinteger(L, lvl);
    return 1;
}

int ShipCount(lua_State* L) {
    lua_pushnumber(L, g_cur->ship_count);
    return 1;
}

int ShipMaxEnergy(lua_State* L) {
    int i = CheckShip(L);
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

// x, y, type, vx, vy, team, life, owner, depth, level. A bolt is drawn as a
// streak along its own velocity and tinted by whose it is, so the renderer
// needs all of it, and asking for it in ten separate calls per weapon per
// frame is the kind of cost that only shows up on the platform that matters
// most.
//
// The last three are not for drawing directly. Owner is who to put a fire
// sound on, and depth tells a round somebody aimed from a fragment of one that
// broke. Level is the rung the round was fired at, which for everything on a
// ladder `spec_level` already answers from the spec. Shrapnel is the exception
// and the reason this is here: every fragment in the game is one spec, and
// which bullet it turns out to be is a number carried on the round.

int WeaponAt(lua_State* L) {
    int i = (int)luaL_checkinteger(L, 1);
    const sim_weapon* w = &g_cur->weapons[i];
    // Walked back along its own flight rather than interpolated against
    // whatever last held this slot. See flight.h for why a slot is not a name.
    const vw_flight::Point at =
        vw_flight::seen(w->x, w->y, w->vx, w->vy, (double)g_alpha);
    lua_pushnumber(L, at.x);
    lua_pushnumber(L, at.y);
    lua_pushnumber(L, w->spec);
    lua_pushnumber(L, w->vx / 65536.0);
    lua_pushnumber(L, w->vy / 65536.0);
    lua_pushnumber(L, w->team);
    lua_pushnumber(L, w->life);
    lua_pushnumber(L, w->owner);
    lua_pushnumber(L, w->depth);
    lua_pushnumber(L, w->level);
    return 10;
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

// What a cell of the overview shows when several kinds of tile stand in it.
// A wall beats a door beats a safe zone beats a wormhole, and everything else
// a map can hold is scenery the overview leaves out. A slope is wall: at four
// tiles to a cell there is no room to say which half of one is solid.
int OverviewRank(int cls) {
    switch (cls) {
        case SIM_TILE_SOLID: return 4;
        case SIM_TILE_SLOPE: return 4;
        case SIM_TILE_DOOR: return 3;
        case SIM_TILE_SAFE: return 2;
        case SIM_TILE_WORMHOLE: return 1;
        default: return 0;
    }
}

// The whole map at one cell per `cell` tiles, as a string of tile classes,
// with the grid it came out as.
//
// Showing every tile at once means reading every tile, and from Lua that is a
// call apiece: a million of those is a stall a player sees. Here it is one
// pass over an array this module already holds, which costs about a
// millisecond and happens once per map.
//
// A cell reports the most important thing standing in it rather than whatever
// tile a stride happened to land on. At this scale a wall is a pixel or two
// wide, and sampling drops one between samples, which is a map with gaps in
// it exactly where the rooms are.
//
// The map's own rect, so a 144-tile room comes back as a 144-tile room. Read
// across the whole array instead it came back as a speck in the corner of a
// field of nothing, which is what the overview drew before a map had a size.
int MapCoarse(lua_State* L) {
    // Two tiles is the finest this will go, which is what the buffer below is
    // sized for and finer than any screen can show a thousand of.
    int cell = (int)luaL_checkinteger(L, 1);
    if (cell < 2) cell = 2;
    if (cell > SIM_MAP_TILES) cell = SIM_MAP_TILES;
    const int gw = (g_map.w + cell - 1) / cell;
    const int gh = (g_map.h + cell - 1) / cell;
    static uint8_t out[(SIM_MAP_TILES / 2) * (SIM_MAP_TILES / 2)];
    if (gw <= 0 || gh <= 0) {
        lua_pushlstring(L, "", 0);
        lua_pushnumber(L, 0);
        lua_pushnumber(L, 0);
        return 3;
    }
    memset(out, 0, (size_t)gw * (size_t)gh);
    for (int ty = 0; ty < g_map.h; ty++) {
        uint8_t* row = out + (ty / cell) * gw;
        for (int tx = 0; tx < g_map.w; tx++) {
            int cls = SIM_TILE_CLASS(sim_tile_at(&g_map, tx, ty));
            uint8_t* cur = row + tx / cell;
            if (OverviewRank(cls) > OverviewRank(*cur)) *cur = (uint8_t)cls;
        }
    }
    lua_pushlstring(L, (const char*)out, (size_t)gw * (size_t)gh);
    lua_pushnumber(L, gw);
    lua_pushnumber(L, gh);
    return 3;
}

int DoorOpen(lua_State* L) {
    lua_pushboolean(L, sim_door_open(&g_cfg, g_cur->tick,
                                     (uint8_t)luaL_checkinteger(L, 1)));
    return 1;
}

int InSafe(lua_State* L) {
    int i = CheckShip(L);
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

int PredictedDeathCount(lua_State* L) {
    lua_pushnumber(L, g_ev.predicted_death_count);
    return 1;
}

int PredictedDeathAt(lua_State* L) {
    int i = (int)luaL_checkinteger(L, 1);
    if (i < 0 || i >= g_ev.predicted_death_count) {
        return luaL_error(L, "predicted death index %d out of range", i);
    }
    lua_pushnumber(L, g_ev.predicted_death[i]);
    return 1;
}

int FlagCount(lua_State* L) {
    lua_pushnumber(L, g_cur->flag_count);
    return 1;
}

int FlagAt(lua_State* L) {
    int i = (int)luaL_checkinteger(L, 1);
    const sim_flag* f = &g_cur->flags[i];
    const sim_flag* p = &g_nxt->flags[i];
    // A carried flag is wherever its carrier is, so it has to move the way the
    // carrier does or it swims against the hull holding it. Flags keep their
    // index for the life of the arena, so there is no identity to check; a
    // dropped or taken flag jumps, and the distance guard covers that.
    double dx = (f->x - p->x) / 256.0, dy = (f->y - p->y) / 256.0;
    bool same = has_prev() && p->active && f->active
                && dx * dx + dy * dy < INTERPOLATION_SNAP * INTERPOLATION_SNAP;
    lua_pushnumber(L, same ? blend(p->x, f->x) : f->x / 256.0);
    lua_pushnumber(L, same ? blend(p->y, f->y) : f->y / 256.0);
    lua_pushnumber(L, f->team);
    lua_pushboolean(L, f->carried);
    return 4;
}

// A map arrives from the zone before anything else does, because prediction
// runs collision locally and cannot do that against a room it has not got.
int ApplyMap(lua_State* L) {
    size_t len = 0;
    const char* data = luaL_checklstring(L, 1, &len);
    int r = sim_map_unpack(&g_map, (const uint8_t*)data, (int)len);
    if (r == 0) sim_settings_baseline(&g_cfg, &g_map);
    ReapplyMortal();
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
    ReapplyMortal();
    lua_pushnumber(L, r);
    return 1;
}

// Who this client is, for the death rule above: the one hull prediction may
// kill. 255 while watching, so the free-run kills nobody at all.
int SetMortal(lua_State* L) {
    int i = (int)luaL_checkinteger(L, 1);
    if (i < 0 || i > 255) {
        return luaL_error(L, "mortal ship %d out of range", i);
    }
    g_mortal_ship = (uint8_t)i;
    ReapplyMortal();
    return 0;
}

// The frame's place between the last two ticks, nought to one. Set once per
// frame, before anything draws.
int RenderAlpha(lua_State* L) {
    double a = luaL_checknumber(L, 1);
    g_alpha = (float)(a < 0.0 ? 0.0 : (a > 1.0 ? 1.0 : a));
    return 0;
}

// Hold what the screen is currently asserting about every hull. Called before a
// snapshot is applied, while that assertion is still true.
int SmoothCapture(lua_State* L) {
    (void)L;
    for (int i = 0; i < g_cur->ship_count && i < SIM_MAX_SHIPS; i++) {
        const sim_ship* c = &g_cur->ships[i];
        g_held[i] = c->active && c->alive;
        // The raw tick rather than the blended position: the offset is a
        // correction to the tick grid, and the blend rides on top of whatever
        // it comes out as. Folding the blend in here would count it twice.
        g_held_x[i] = c->x;
        g_held_y[i] = c->y;
        g_held_h[i] = c->heading;
        g_held_repel[i] = c->repel;
    }
    for (int i = g_cur->ship_count; i < SIM_MAX_SHIPS; i++) {
        g_held[i] = 0;
        g_held_repel[i] = 0;
    }
    return 0;
}

// And afterwards, once the replay has run: whatever moved, keep drawing where it
// was and owe the difference.
//
// The clock steering rides in here too, and deliberately. A snapshot that trims
// the client's lead by a tick moves every hull by a tick of flight, which is
// exactly the kind of jump worth hiding rather than snapping through.
int SmoothSettle(lua_State* L) {
    bool local_repel_started = false;
    bool local_correction_absorbed = false;
    for (int i = 0; i < SIM_MAX_SHIPS; i++) {
        const sim_ship* c = &g_cur->ships[i];
        if (!g_held[i] || !c->active || !c->alive) {
            g_off_x[i] = g_off_y[i] = g_off_h[i] = 0.0f;
            g_repel_debt[i] = 0;
            continue;
        }
        double ox = g_off_x[i] + (g_held_x[i] - c->x) / 256.0;
        double oy = g_off_y[i] + (g_held_y[i] - c->y) / 256.0;
        const bool local = i == g_mortal_ship;
        const bool repel_started =
            local && vw_smoothing::authoritative_repel(g_held_repel[i],
                                                        c->repel);
        const bool repel = local && (repel_started || g_repel_debt[i]);
        const vw_smoothing::Position pos =
            vw_smoothing::settle_position(ox, oy, local, repel);
        if (local) {
            local_repel_started = repel_started;
            // With no cap or snap, the offset preserves the exact position the
            // player saw before reconciliation. The correction is real, but
            // it does not produce an immediate jump on screen.
            local_correction_absorbed = !pos.limited;
        }
        g_off_x[i] = (float)pos.x;
        g_off_y[i] = (float)pos.y;
        if (pos.snapped || (pos.x == 0.0 && pos.y == 0.0)) {
            g_repel_debt[i] = 0;
        } else if (repel) {
            g_repel_debt[i] = 1;
        }

        // The heading's owed turn, by the short way round the circle, since
        // an angle has no long way worth easing through.
        int32_t dh = (int32_t)g_held_h[i] - (int32_t)c->heading;
        if (dh > 32768) dh -= 65536;
        if (dh < -32768) dh += 65536;
        double oh = g_off_h[i] + (double)dh;
        if (oh > 32768.0) oh -= 65536.0;
        if (oh < -32768.0) oh += 65536.0;
        const double turn_snap = local ? LOCAL_TURN_SNAP : REMOTE_TURN_SNAP;
        const double turn_max = local ? LOCAL_TURN_MAX : REMOTE_TURN_MAX;
        if (oh > turn_snap || oh < -turn_snap) {
            oh = 0.0;
        } else if (oh > turn_max) {
            oh = turn_max;
        } else if (oh < -turn_max) {
            oh = -turn_max;
        }
        g_off_h[i] = (float)oh;
    }
    lua_pushboolean(L, local_repel_started);
    lua_pushboolean(L, local_correction_absorbed);
    return 2;
}

// Bleed the offsets away. Exponential on a half-life, so the pull is strongest
// where the lie is largest and there is no moment at which it stops.
int SmoothDecay(lua_State* L) {
    double dt = luaL_checknumber(L, 1);
    double local_half = luaL_optnumber(L, 2, LOCAL_HALF_LIFE);
    double remote_half = luaL_optnumber(L, 3, REMOTE_HALF_LIFE);
    if (dt <= 0.0 || local_half <= 0.0 || remote_half <= 0.0) return 0;
    float local_k = (float)vw_smoothing::decay_factor(dt, local_half);
    float remote_k = (float)vw_smoothing::decay_factor(dt, remote_half);
    float repel_k =
        (float)vw_smoothing::decay_factor(dt, vw_smoothing::REPEL_HALF_LIFE);
    for (int i = 0; i < SIM_MAX_SHIPS; i++) {
        float k = i == g_mortal_ship ? local_k : remote_k;
        float position_k = g_repel_debt[i] ? repel_k : k;
        g_off_x[i] *= position_k;
        g_off_y[i] *= position_k;
        g_off_h[i] *= k;
        // Under a hundredth of a pixel it is arithmetic nobody can see, and
        // leaving it running means every hull carries a decaying number for the
        // rest of the session.
        if (g_off_x[i] * g_off_x[i] + g_off_y[i] * g_off_y[i] < 0.0001f) {
            g_off_x[i] = g_off_y[i] = 0.0f;
            g_repel_debt[i] = 0;
        }
        // Two turn units is a hundredth of a degree.
        if (g_off_h[i] < 2.0f && g_off_h[i] > -2.0f) g_off_h[i] = 0.0f;
    }
    return 0;
}

// Leaving a zone. Offsets are about a room, and carrying one into the next is a
// hull drawn beside itself on arrival.
int SmoothReset(lua_State* L) {
    (void)L;
    for (int i = 0; i < SIM_MAX_SHIPS; i++) {
        g_off_x[i] = g_off_y[i] = g_off_h[i] = 0.0f;
        g_held[i] = 0;
        g_held_repel[i] = 0;
        g_repel_debt[i] = 0;
    }
    g_alpha = 0.0f;
    return 0;
}

// The largest correction still visible on a remote hull, in pixels and
// degrees. Raw reconciliation and presentation debt are separate metrics.
int SmoothStats(lua_State* L) {
    int local = (int)luaL_optinteger(L, 1, -1);
    double pos_max = 0.0, turn_max = 0.0;
    for (int i = 0; i < g_cur->ship_count && i < SIM_MAX_SHIPS; i++) {
        const sim_ship* s = &g_cur->ships[i];
        if (i == local || !s->active || !s->alive) continue;
        double pos = sqrt(g_off_x[i] * g_off_x[i] + g_off_y[i] * g_off_y[i]);
        double turn = fabs(g_off_h[i]) * 360.0 / 65536.0;
        if (pos > pos_max) pos_max = pos;
        if (turn > turn_max) turn_max = turn;
    }
    lua_pushnumber(L, pos_max);
    lua_pushnumber(L, turn_max);
    return 2;
}

// Presentation debt on one hull after a correction has settled. The public
// smooth_stats intentionally excludes the local hull, so it cannot answer why
// the camera is easing backward or forward after reconciliation.
int SmoothDebt(lua_State* L) {
    int i = CheckShip(L);
    double pos = sqrt(g_off_x[i] * g_off_x[i] + g_off_y[i] * g_off_y[i]);
    double turn = fabs(g_off_h[i]) * 360.0 / 65536.0;
    lua_pushnumber(L, pos);
    lua_pushnumber(L, turn);
    return 2;
}

const luaL_reg kFunctions[] = {
    {"init", Init},
    {"map_size", MapSize},
    {"step", Step},
    {"replay", Replay},
    {"apply_snapshot", ApplySnapshot},
    {"ship_count", ShipCount},
    {"ship_x", ShipX},
    {"ship_y", ShipY},
    {"ship_heading", ShipHeading},
    {"ship_alive", ShipAlive},
    {"ship_active", ShipActive},
    {"ship_private", ShipPrivate},
    {"ship_team", ShipTeam},
    {"ship_class", ShipClass},
    {"ship_energy", ShipEnergy},
    {"ship_max_energy", ShipMaxEnergy},
    {"ship_kills", ShipKills},
    {"ship_deaths", ShipDeaths},
    {"ship_assists", ShipAssists},
    {"ship_vel", ShipVel},
    {"ship_repel", ShipRepel},
    {"ship_up", ShipUp},
    {"ship_kit", ShipKit},
    {"slot_cap", SlotCap},
    {"class_kit", ClassKit},
    {"class_flight", ClassFlight},
    {"hull_extent", HullExtent},
    {"ship_level", ShipLevel},
    {"ship_charge", ShipCharge},
    {"ship_charge_wait", ShipChargeWait},
    {"charge_delay", ChargeDelay},
    {"ship_streak", ShipStreak},
    {"ship_on_streak", ShipOnStreak},
    {"streak_kills", StreakKills},
    {"has_trigger", HasTrigger},
    {"ship_mod", ShipMod},
    {"ship_multi_off", ShipMultiOff},
    {"ship_cooldown", ShipCooldown},
    {"ship_trigger_wait", ShipTriggerWait},
    {"ship_trigger_delay", ShipTriggerDelay},
    {"safe_limit", SafeLimit},
    {"show_spawns", ShowSpawns},
    {"spec_blast", SpecBlast},
    {"spec_trigger", SpecTrigger},
    {"spec_life", SpecLife},
    {"spec_level", SpecLevel},
    {"shrap_count", ShrapCount},
    {"spray_shape", SprayShape},
    {"charge_spec", ChargeSpec},
    {"tick", Tick},
    {"weapon_count", WeaponCount},
    {"weapon_at", WeaponAt},
    {"solid", Solid},
    {"tile", TileAt},
    {"map_coarse", MapCoarse},
    {"door_open", DoorOpen},
    {"in_safe", InSafe},
    {"event_count", EventCount},
    {"event_at", EventAt},
    {"predicted_death_count", PredictedDeathCount},
    {"predicted_death_at", PredictedDeathAt},
    {"flag_count", FlagCount},
    {"flag_at", FlagAt},
    {"ship_x_raw", ShipXRaw},
    {"ship_y_raw", ShipYRaw},
    {"ship_heading_raw", ShipHeadingRaw},
    {"render_alpha", RenderAlpha},
    {"smooth_capture", SmoothCapture},
    {"smooth_settle", SmoothSettle},
    {"smooth_decay", SmoothDecay},
    {"smooth_reset", SmoothReset},
    {"smooth_stats", SmoothStats},
    {"smooth_debt", SmoothDebt},
    {"apply_map", ApplyMap},
    {"apply_settings", ApplySettings},
    {"set_mortal", SetMortal},
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
    lua_pushnumber(L, SIM_TILE_SPAWN);    lua_setfield(L, -2, "T_SPAWN");
    lua_pushnumber(L, SIM_TILE_SLOPE);    lua_setfield(L, -2, "T_SLOPE");

    // Event and weapon kinds, so the client never hard-codes an enum the
    // core is free to renumber.
    lua_pushnumber(L, SIM_EV_FIRE);      lua_setfield(L, -2, "EV_FIRE");
    lua_pushnumber(L, SIM_EV_BOUNCE);    lua_setfield(L, -2, "EV_BOUNCE");
    lua_pushnumber(L, SIM_EV_HIT);       lua_setfield(L, -2, "EV_HIT");
    lua_pushnumber(L, SIM_EV_DEATH);     lua_setfield(L, -2, "EV_DEATH");
    lua_pushnumber(L, SIM_EV_SPAWN);     lua_setfield(L, -2, "EV_SPAWN");
    lua_pushnumber(L, SIM_EV_EXPIRE);    lua_setfield(L, -2, "EV_EXPIRE");
    lua_pushnumber(L, SIM_EV_FLAG_TAKE); lua_setfield(L, -2, "EV_FLAG_TAKE");
    lua_pushnumber(L, SIM_EV_FLAG_DROP); lua_setfield(L, -2, "EV_FLAG_DROP");
    lua_pushnumber(L, SIM_EV_CHARGE);    lua_setfield(L, -2, "EV_CHARGE");
    lua_pushnumber(L, SIM_UP_COUNT);     lua_setfield(L, -2, "UP_COUNT");

    // The kit space, so the hangar never hard-codes a layout the core is free
    // to change. It is flat and every slot in it costs one: five stats, then a
    // rung per trigger, then an add-on per trigger per kind, then a charge.
    lua_pushnumber(L, SIM_TRIG_COUNT);   lua_setfield(L, -2, "TRIG_COUNT");
    lua_pushnumber(L, SIM_TRIG_GUN);     lua_setfield(L, -2, "TRIG_GUN");
    lua_pushnumber(L, SIM_TRIG_BOMB);    lua_setfield(L, -2, "TRIG_BOMB");
    lua_pushnumber(L, SIM_MOD_COUNT);    lua_setfield(L, -2, "MOD_COUNT");
    lua_pushnumber(L, SIM_MOD_MULTI);    lua_setfield(L, -2, "MOD_MULTI");
    lua_pushnumber(L, SIM_SLOT_COUNT);   lua_setfield(L, -2, "SLOT_COUNT");
    lua_pushnumber(L, SIM_SLOT_LEVEL(0)); lua_setfield(L, -2, "SLOT_LEVEL0");
    lua_pushnumber(L, SIM_SLOT_MOD(0, 0)); lua_setfield(L, -2, "SLOT_MOD0");
    lua_pushnumber(L, SIM_SLOT_CHARGE(0)); lua_setfield(L, -2, "SLOT_CHARGE0");
    lua_pushnumber(L, SIM_UP_STEPS);     lua_setfield(L, -2, "UP_STEPS");
    lua_pushnumber(L, SIM_KIT_CREDITS);  lua_setfield(L, -2, "KIT_CREDITS");
    lua_pushnumber(L, SIM_MOD_COUNT * SIM_TRIG_COUNT);
    lua_setfield(L, -2, "MOD_SLOTS");
    lua_pushnumber(L, SIM_MAX_CHARGES);  lua_setfield(L, -2, "MAX_CHARGES");
    lua_pushnumber(L, SIM_KIT_CHARGE_SLOTS);
    lua_setfield(L, -2, "KIT_CHARGE_SLOTS");
    lua_pushnumber(L, SIM_CHARGE_REPEL); lua_setfield(L, -2, "CHARGE_REPEL");
    lua_pushnumber(L, SIM_CHARGE_BURST); lua_setfield(L, -2, "CHARGE_BURST");
    lua_pushnumber(L, SIM_BTN_USE);      lua_setfield(L, -2, "BTN_USE");
    lua_pushnumber(L, SIM_BTN_MULTI);    lua_setfield(L, -2, "BTN_MULTI");
    lua_pushnumber(L, 1u << SIM_BTN_SLOT_SHIFT); lua_setfield(L, -2, "BTN_SLOT_STEP");

    lua_pop(L, 1);
    assert(top == lua_gettop(L));
}

dmExtension::Result AppInitialize(dmExtension::AppParams* params) {
    return dmExtension::RESULT_OK;
}

dmExtension::Result Initialize(dmExtension::Params* params) {
    LuaInit(params->m_L);
    VwBufInit(params->m_L);
    VwSfxInit(params->m_L);
    return dmExtension::RESULT_OK;
}

dmExtension::Result AppFinalize(dmExtension::AppParams* params) {
    return dmExtension::RESULT_OK;
}

dmExtension::Result Finalize(dmExtension::Params* params) {
    VwSfxFinal();
    VwBufFinal();
    return dmExtension::RESULT_OK;
}

}  // namespace

// symbol, name, app_init, app_final, init, update, on_event, final
DM_DECLARE_EXTENSION(simcore, LIB_NAME, AppInitialize, AppFinalize, Initialize,
                     0, 0, Finalize)
