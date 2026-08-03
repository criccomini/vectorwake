// The Lua side of the sound kit.
//
// The synth is in sfx.c and knows nothing about Defold. This hands what it
// renders to Lua as a string, because that is what resource.set_sound takes:
// the bytes of a wav file, which the engine then owns.
//
// Registered from simcore's own init rather than declaring a second
// extension: two DM_DECLARE_EXTENSIONs in one extension folder leaves the
// second one unregistered, and the only symptom is a nil module at the point
// some Lua file asks for it.

#define MODULE_NAME "vwsfx"

#include <dmsdk/sdk.h>
#include <stdlib.h>

#include "sfx.h"

namespace {

// Every sound the kit knows, in order. The names are also the sound component
// ids in main.collection, which is what lets the client wire the two together
// without a list of its own to fall out of date.
int Names(lua_State* L) {
    int top = lua_gettop(L);
    lua_newtable(L);
    for (int i = 0; sfx_names[i]; i++) {
        lua_pushstring(L, sfx_names[i]);
        lua_rawseti(L, -2, i + 1);
    }
    assert(top + 1 == lua_gettop(L));
    return 1;
}

// One sound, as the bytes of a wav file. Nil on a name the kit does not know,
// which the caller is expected to complain about rather than ignore: a client
// that has gone silent looks exactly like a client with the volume down.
int Render(lua_State* L) {
    int top = lua_gettop(L);
    const char* name = luaL_checkstring(L, 1);
    size_t len = 0;
    unsigned char* wav = sfx_render(name, &len);
    if (!wav) {
        lua_pushnil(L);
        assert(top + 1 == lua_gettop(L));
        return 1;
    }
    // Lua copies, so the render can be handed back the moment it lands.
    lua_pushlstring(L, (const char*)wav, len);
    free(wav);
    assert(top + 1 == lua_gettop(L));
    return 1;
}

const luaL_reg kFunctions[] = {{"names", Names}, {"render", Render}, {0, 0}};

}  // namespace

void VwSfxInit(lua_State* L) {
    int top = lua_gettop(L);
    luaL_register(L, MODULE_NAME, kFunctions);
    lua_pop(L, 1);
    assert(top == lua_gettop(L));
}
