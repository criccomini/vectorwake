// The vertex writer.
//
// Everything the client draws is triangles appended to a dynamic buffer, and
// on the web that cost more than the game did. A buffer stream indexed from
// Lua is one call into C per float: a triangle is twenty-one of them, a frame
// is fifty thousand, and Lua 5.1 -- which is what HTML5 builds run, not
// LuaJIT -- spent about five milliseconds a frame doing nothing but crossing
// that boundary.
//
// The geometry still comes from Lua. Only the writing moved here, so a
// triangle costs one crossing instead of twenty-one and the arithmetic that
// decides where it goes stays where it is readable.

#define MODULE_NAME "vwbuf"

#include <dmsdk/sdk.h>
#include <string.h>

namespace {

struct VwLayer {
    dmBuffer::HBuffer buf;
    float* pos;
    float* col;
    uint32_t stride;   // floats between one vertex and the next
    uint32_t cap;      // vertices the buffer holds
    uint32_t n;        // vertices written this frame
    uint32_t high;     // vertices written last frame
    uint32_t dropped;  // shapes refused this frame, for want of room
    uint32_t peak;     // the busiest frame so far
    uint32_t lost;     // shapes refused since the layer was made
};

const int VW_MAX_LAYERS = 8;
VwLayer g_layers[VW_MAX_LAYERS];
int g_layer_count = 0;

// Stream pointers are re-read every frame rather than cached once. They do not
// move in practice, and a stale pointer here would be a write into freed
// memory rather than a wrong triangle.
bool Resolve(VwLayer* v) {
    void* p = 0;
    uint32_t count = 0, comps = 0, stride = 0;
    if (dmBuffer::GetStream(v->buf, dmHashString64("position"), &p, &count,
                            &comps, &stride) != dmBuffer::RESULT_OK ||
        comps != 3) {
        return false;
    }
    v->pos = (float*)p;
    v->cap = count;
    v->stride = stride;
    if (dmBuffer::GetStream(v->buf, dmHashString64("color"), &p, &count,
                            &comps, &stride) != dmBuffer::RESULT_OK ||
        comps != 4) {
        return false;
    }
    v->col = (float*)p;
    return true;
}

VwLayer* Layer(lua_State* L, int idx) {
    int id = (int)lua_tonumber(L, idx);
    if (id < 0 || id >= g_layer_count) {
        luaL_error(L, "vwbuf: no layer %d", id);
        return 0;
    }
    return &g_layers[id];
}

// Four floats out of a Lua {r, g, b, a}. rawgeti rather than lua_getfield
// because these tables are the palette's and have no metatable worth
// consulting sixty thousand times a second.
inline void Colour(lua_State* L, int idx, float* out) {
    for (int i = 0; i < 4; i++) {
        lua_rawgeti(L, idx, i + 1);
        out[i] = (float)lua_tonumber(L, -1);
        lua_pop(L, 1);
    }
}

inline void Vertex(float* p, float* c, float x, float y, const float* rgba,
                   float alpha) {
    p[0] = x;
    p[1] = y;
    p[2] = 0.0f;
    c[0] = rgba[0];
    c[1] = rgba[1];
    c[2] = rgba[2];
    c[3] = rgba[3] * alpha;
}

int Attach(lua_State* L) {
    dmBuffer::HBuffer b = dmScript::CheckBufferUnpack(L, 1);
    // The same buffer twice is a reload, not a second layer. Handing back the
    // slot it already has is what keeps a hot reload from walking off the end
    // of the table.
    for (int i = 0; i < g_layer_count; i++) {
        if (g_layers[i].buf == b) {
            lua_pushnumber(L, i);
            return 1;
        }
    }
    if (g_layer_count >= VW_MAX_LAYERS) return luaL_error(L, "vwbuf: full");
    VwLayer* v = &g_layers[g_layer_count];
    memset(v, 0, sizeof *v);
    v->buf = b;
    if (!Resolve(v)) {
        return luaL_error(L, "vwbuf: need float3 position and float4 color");
    }
    lua_pushnumber(L, g_layer_count);
    g_layer_count++;
    return 1;
}

int Reset(lua_State* L) {
    VwLayer* v = Layer(L, 1);
    Resolve(v);
    v->lost += v->dropped;
    v->n = 0;
    v->dropped = 0;
    return 0;
}

int Tri(lua_State* L) {
    VwLayer* v = Layer(L, 1);
    if (v->n + 3 > v->cap) {
        v->dropped++;
        return 0;
    }
    float c[4];
    Colour(L, 8, c);
    float* p = v->pos + (size_t)v->n * v->stride;
    float* q = v->col + (size_t)v->n * v->stride;
    Vertex(p, q, (float)lua_tonumber(L, 2), (float)lua_tonumber(L, 3), c, 1.0f);
    p += v->stride;
    q += v->stride;
    Vertex(p, q, (float)lua_tonumber(L, 4), (float)lua_tonumber(L, 5), c, 1.0f);
    p += v->stride;
    q += v->stride;
    Vertex(p, q, (float)lua_tonumber(L, 6), (float)lua_tonumber(L, 7), c, 1.0f);
    v->n += 3;
    return 0;
}

// A triangle whose corners carry their own alpha, which is every soft edge in
// the game: glow falloff, trail fade, blast rim.
int TriFade(lua_State* L) {
    VwLayer* v = Layer(L, 1);
    if (v->n + 3 > v->cap) {
        v->dropped++;
        return 0;
    }
    float c[4];
    Colour(L, 11, c);
    float* p = v->pos + (size_t)v->n * v->stride;
    float* q = v->col + (size_t)v->n * v->stride;
    Vertex(p, q, (float)lua_tonumber(L, 2), (float)lua_tonumber(L, 3), c,
           (float)lua_tonumber(L, 4));
    p += v->stride;
    q += v->stride;
    Vertex(p, q, (float)lua_tonumber(L, 5), (float)lua_tonumber(L, 6), c,
           (float)lua_tonumber(L, 7));
    p += v->stride;
    q += v->stride;
    Vertex(p, q, (float)lua_tonumber(L, 8), (float)lua_tonumber(L, 9), c,
           (float)lua_tonumber(L, 10));
    v->n += 3;
    return 0;
}

// Two triangles from four corners, so a rectangle is one crossing rather than
// two. Quads are most of what the interface and the starfield draw.
int Quad(lua_State* L) {
    VwLayer* v = Layer(L, 1);
    if (v->n + 6 > v->cap) {
        v->dropped++;
        return 0;
    }
    float c[4];
    Colour(L, 10, c);
    float x[4], y[4];
    for (int i = 0; i < 4; i++) {
        x[i] = (float)lua_tonumber(L, 2 + i * 2);
        y[i] = (float)lua_tonumber(L, 3 + i * 2);
    }
    static const int order[6] = {0, 1, 2, 0, 2, 3};
    float* p = v->pos + (size_t)v->n * v->stride;
    float* q = v->col + (size_t)v->n * v->stride;
    for (int i = 0; i < 6; i++) {
        Vertex(p, q, x[order[i]], y[order[i]], c, 1.0f);
        p += v->stride;
        q += v->stride;
    }
    v->n += 6;
    return 0;
}

// An axis-aligned rectangle from a corner and a size: the one shape the
// interface, the radar and the starfield are almost entirely made of.
int Rect(lua_State* L) {
    VwLayer* v = Layer(L, 1);
    if (v->n + 6 > v->cap) {
        v->dropped++;
        return 0;
    }
    float c[4];
    Colour(L, 6, c);
    float x0 = (float)lua_tonumber(L, 2);
    float y0 = (float)lua_tonumber(L, 3);
    float x1 = x0 + (float)lua_tonumber(L, 4);
    float y1 = y0 + (float)lua_tonumber(L, 5);
    const float xs[6] = {x0, x1, x1, x0, x1, x0};
    const float ys[6] = {y0, y0, y1, y0, y1, y1};
    float* p = v->pos + (size_t)v->n * v->stride;
    float* q = v->col + (size_t)v->n * v->stride;
    for (int i = 0; i < 6; i++) {
        Vertex(p, q, xs[i], ys[i], c, 1.0f);
        p += v->stride;
        q += v->stride;
    }
    v->n += 6;
    return 0;
}

// Degenerate whatever a busier frame left behind. Three corners on the same
// point cover no pixels, which is cheaper than resizing the buffer to fit.
int Finish(lua_State* L) {
    VwLayer* v = Layer(L, 1);
    for (uint32_t i = v->n; i < v->high; i++) {
        float* p = v->pos + (size_t)i * v->stride;
        p[0] = 0.0f;
        p[1] = 0.0f;
        p[2] = 0.0f;
    }
    v->high = v->n;
    if (v->n > v->peak) v->peak = v->n;
    lua_pushnumber(L, v->n);
    lua_pushnumber(L, v->dropped);
    return 2;
}

// The busiest frame a layer has had, and everything it has ever refused to
// draw. A capacity chosen too tight is otherwise invisible: geometry simply
// stops appearing, in exactly the frames nobody is looking at a debugger.
int Stats(lua_State* L) {
    VwLayer* v = Layer(L, 1);
    lua_pushnumber(L, v->peak);
    lua_pushnumber(L, v->lost + v->dropped);
    lua_pushnumber(L, v->cap);
    return 3;
}

const luaL_reg kFunctions[] = {{"attach", Attach}, {"reset", Reset},
                               {"tri", Tri},       {"tri_fade", TriFade},
                               {"quad", Quad},     {"rect", Rect},
                               {"finish", Finish},
                               {"stats", Stats}, {0, 0}};

}  // namespace

// Registered from simcore's own init rather than declaring a second
// extension: two DM_DECLARE_EXTENSIONs in one extension folder leaves the
// second one unregistered, and the only symptom is a nil module at the point
// some Lua file asks for it.
void VwBufFinal() {
    g_layer_count = 0;
}

void VwBufInit(lua_State* L) {
    int top = lua_gettop(L);
    luaL_register(L, MODULE_NAME, kFunctions);
    lua_pop(L, 1);
    assert(top == lua_gettop(L));
}
