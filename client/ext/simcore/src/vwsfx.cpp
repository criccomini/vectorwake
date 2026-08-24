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

// Bytes as base64, for the browser.
//
// A sound that has to reach Web Audio goes through html5.run, which is an
// eval of a string, so the wav has to survive being spliced into JavaScript
// source. Base64 is the alphabet that does: no quote, no backslash, no
// newline, nothing eval has an opinion about.
//
// Encoded here rather than in Lua because Lua 5.1 has no bitwise operators,
// and doing this a nibble at a time in arithmetic, over a megabyte, at boot,
// on the platform that is already the slowest, is not a trade worth making.
//
// Takes what was rendered rather than a name, so a sound is synthesised once
// and spent twice: on the engine's mixer, which still holds the fallback, and
// on the browser's own audio graph.
int B64(lua_State* L) {
    static const char kB64[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    int top = lua_gettop(L);
    size_t len = 0;
    const unsigned char* wav = (const unsigned char*)luaL_checklstring(L, 1, &len);
    size_t out_len = (len + 2) / 3 * 4;
    char* out = (char*)malloc(out_len + 1);
    if (!out) {
        lua_pushnil(L);
        assert(top + 1 == lua_gettop(L));
        return 1;
    }
    size_t i = 0, o = 0;
    while (i + 2 < len) {
        uint32_t n = ((uint32_t)wav[i] << 16) | ((uint32_t)wav[i + 1] << 8) |
                     (uint32_t)wav[i + 2];
        out[o++] = kB64[(n >> 18) & 63];
        out[o++] = kB64[(n >> 12) & 63];
        out[o++] = kB64[(n >> 6) & 63];
        out[o++] = kB64[n & 63];
        i += 3;
    }
    if (i < len) {
        // One or two bytes over, padded, which is the half of base64 that is
        // easy to write wrong and silent when it is: a decoder reads the tail
        // as zeros and the sound ends in a click.
        uint32_t n = (uint32_t)wav[i] << 16;
        int two = (i + 1 < len);
        if (two) n |= (uint32_t)wav[i + 1] << 8;
        out[o++] = kB64[(n >> 18) & 63];
        out[o++] = kB64[(n >> 12) & 63];
        out[o++] = two ? kB64[(n >> 6) & 63] : '=';
        out[o++] = '=';
    }
    lua_pushlstring(L, out, o);
    free(out);
    assert(top + 1 == lua_gettop(L));
    return 1;
}

// Whether a sound loops, which is what decides how the client plays it.
int IsLoop(lua_State* L) {
    int top = lua_gettop(L);
    lua_pushboolean(L, sfx_is_loop(luaL_checkstring(L, 1)));
    assert(top + 1 == lua_gettop(L));
    return 1;
}

// --- the soundtrack, built a step at a time --------------------------------
//
// A track takes about an eighth of a second to render, which the client cannot
// spend in one frame, so sfx.c builds one in steps and this hands Lua the
// three calls that drive it. One job at a time: the client is building the
// next track and there is never a second thing it wants at once. Beginning a
// new one throws away whatever was half built, which is what should happen
// when the rotation is cut short.
sfx_music_job* g_job = 0;

int MusicCount(lua_State* L) {
    int top = lua_gettop(L);
    lua_pushinteger(L, sfx_music_count());
    assert(top + 1 == lua_gettop(L));
    return 1;
}

// Tracks are numbered from one in Lua, like everything else there.
int MusicBegin(lua_State* L) {
    int top = lua_gettop(L);
    int i = (int)luaL_checkinteger(L, 1) - 1;
    if (g_job) sfx_music_cancel(g_job);
    g_job = sfx_music_begin(i);
    lua_pushboolean(L, g_job != 0);
    assert(top + 1 == lua_gettop(L));
    return 1;
}

// True when there is nothing left to do, including when there was no job.
int MusicStep(lua_State* L) {
    int top = lua_gettop(L);
    lua_pushboolean(L, g_job ? sfx_music_step(g_job) : 1);
    assert(top + 1 == lua_gettop(L));
    return 1;
}

// The finished track as the bytes of a wav, or nil. The job is spent either
// way, so a caller that gets nil should begin another rather than step again.
int MusicTake(lua_State* L) {
    int top = lua_gettop(L);
    size_t len = 0;
    unsigned char* wav = g_job ? sfx_music_take(g_job, &len) : 0;
    g_job = 0;
    if (!wav) {
        lua_pushnil(L);
        assert(top + 1 == lua_gettop(L));
        return 1;
    }
    lua_pushlstring(L, (const char*)wav, len);
    free(wav);
    assert(top + 1 == lua_gettop(L));
    return 1;
}

const luaL_reg kFunctions[] = {{"names", Names},
                               {"render", Render},
                               {"b64", B64},
                               {"is_loop", IsLoop},
                               {"music_count", MusicCount},
                               {"music_begin", MusicBegin},
                               {"music_step", MusicStep},
                               {"music_take", MusicTake},
                               {0, 0}};

}  // namespace

void VwSfxInit(lua_State* L) {
    int top = lua_gettop(L);
    luaL_register(L, MODULE_NAME, kFunctions);
    lua_pop(L, 1);
    assert(top == lua_gettop(L));
}

void VwSfxFinal() {
    if (!g_job) return;
    sfx_music_cancel(g_job);
    g_job = 0;
}
