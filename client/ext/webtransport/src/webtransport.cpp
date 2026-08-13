// The browser's other transport.
//
// WebTransport rides QUIC, which gives the one thing a WebSocket cannot: a
// lost packet delays only what it carried. The protocol is byte-identical to
// the WebSocket's; what differs is the lanes, and they are this extension's
// whole job. Reliable messages travel on one bidirectional stream, framed
// with a u32 length. Snapshots arrive out of band, as datagrams or one
// unidirectional stream each, and inputs leave as datagrams. The framing has
// to match server/src/wt.rs, which is the other half of this file.
//
// The API mirrors the websocket extension's shape, connect with a callback
// and events delivered from the engine's update, so net.lua can hold either
// transport with one set of habits. One session at a time, because the client
// holds one arena and a second connection is two servers writing over each
// other.
//
// Everything real is HTML5-only: WebTransport is a browser API, and the
// browser's own JS speaks it below via EM_JS. Native builds get a module
// whose supported() says no, which is also the truthful answer.

#define LIB_NAME "WebTransport"
#define MODULE_NAME "webtransport"

#include <dmsdk/sdk.h>
#include <stdlib.h>
#include <string.h>

namespace dmWebTransport {

enum Event {
    EVENT_CONNECTED = 1,
    EVENT_MESSAGE = 2,
    EVENT_DISCONNECTED = 3,
    EVENT_ERROR = 4,
    EVENT_PROGRESS = 5,
};

// What the JS side reports: nothing yet, connecting, open, failed, closed.
enum JsState {
    JS_NONE = 0,
    JS_CONNECTING = 1,
    JS_OPEN = 2,
    JS_ERROR = 3,
    JS_CLOSED = 4,
};

// The largest message this client will accept from a zone.
//
// The server has always capped what it reads at C2S_MAX, on the stated
// grounds that a stranger on an open port gets to cost kilobytes; this
// direction had no cap at all, and the two ends are not symmetric. The
// biggest thing a zone legitimately says is the map, a megabyte and a half
// packed, so two mebibytes clears it with room and still refuses the frame
// header that claims four gigabytes.
//
// Without this the length word off the wire was believed outright: the
// reader assembled whatever it named, the allocation for it could fail, and
// the copy went in at address zero. A cap turns a hostile or broken length
// into a closed session instead of a corrupted heap, and it keeps every
// length small enough that the int VWWT_NextLen returns cannot go negative.
static const int WT_S2C_MAX = 2 * 1024 * 1024;

#if defined(DM_PLATFORM_HTML5)

#include <emscripten/emscripten.h>

// The session lives on Module so a stale promise from an abandoned session
// writes into an object nothing reads any more: each open() replaces the
// whole state, and every async callback closed over the old one.
EM_JS(int, VWWT_Supported, (), {
    return (typeof WebTransport !== 'undefined') ? 1 : 0;
});

EM_JS(void, VWWT_Open, (const char* url, int len, int cap), {
    // UTF8ToString rather than a loop over fromCharCode: the byte-at-a-time
    // version decoded the address as Latin-1, so any non-ASCII character in
    // a hostname or a query arrived as mojibake and dialled nothing.
    var u = UTF8ToString(url, len);
    var S = { st: 1, q: [], err: '', wt: null, rel: null, dg: null,
              cap: cap, progress: 0 };
    Module.vwwt = S;
    var wt;
    try {
        wt = new WebTransport(u);
    } catch (e) {
        S.st = 3;
        S.err = '' + e;
        return;
    }
    S.wt = wt;
    var fail = function(e) {
        if (S.st !== 4) {
            S.st = 3;
            S.err = '' + e;
            if (S.wt) { try { S.wt.close(); } catch (_) {} }
        }
    };
    // State packs supersede older state packs. The other repeatable messages
    // are whole current values too. Coalescing them keeps a backgrounded tab
    // from storing minutes of obsolete room state, while the hard bound turns
    // an event flood into a closed session instead of an unbounded heap.
    var replaceable = { 2: true, 3: true, 5: true, 10: true,
                        12: true, 13: true, 16: true };
    var enqueue = function(m) {
        if (S.st === 3 || S.st === 4 || !m || !m.length) return;
        var tag = m[0];
        if (replaceable[tag]) {
            for (var i = S.q.length - 1; i >= 0; i--) {
                if (S.q[i].length && S.q[i][0] === tag) S.q.splice(i, 1);
            }
        }
        if (S.q.length >= 128) {
            fail('zone message backlog exceeded 128 messages');
            return;
        }
        S.q.push(m);
    };
    // Held on the session so a send can report what a read would have.
    S.fail = fail;
    // What this session is made of, named before it is touched.
    //
    // Every one of these is standard and Chrome hands them over the moment
    // the object exists, which is why the first version reached straight
    // through them. Safari refused a join with `TypeError: undefined is not
    // an object (evaluating 'wt...` and that is all the room a phone had to
    // print, so the missing piece stayed anonymous through two rounds of
    // guessing. An engine that lacks one now says which one, and the client
    // takes the socket knowing why rather than reporting a stack trace at a
    // player.
    var need = function(o, path) {
        var cur = o;
        var parts = path.split('.');
        for (var i = 0; i < parts.length; i++) {
            if (cur === null || cur === undefined) {
                fail('this browser has no ' + path);
                return null;
            }
            cur = cur[parts[i]];
        }
        if (cur === null || cur === undefined) {
            fail('this browser has no ' + path);
            return null;
        }
        return cur;
    };
    wt.closed.then(function() { if (S.st !== 3) S.st = 4; }, fail);
    wt.ready.then(function() {
        // Read after the handshake rather than before it. These were taken
        // the instant the object existed, on the strength of one engine
        // populating them that early; doing it here costs nothing and asks
        // for nothing before the session it belongs to is real.
        if (!need(wt, 'datagrams.readable') ||
            !need(wt, 'incomingUnidirectionalStreams') ||
            !need(wt, 'createBidirectionalStream')) {
            return null;
        }
        // The datagram writer, under whichever name this engine has for it.
        //
        // There are two, and no engine has both. `datagrams.writable` is the
        // original, now deprecated and off the standards track; the current
        // spelling is the `datagrams.createWritable()` method. Chrome and
        // Firefox ship only the property, WebKit shipped only the method when
        // WebTransport arrived in Safari 26.4.
        //
        // Asking for the property by name is what put every iPhone on the
        // WebSocket. The QUIC handshake had already succeeded, which is
        // why this runs at all, and then the check above rejected the session
        // over a writer that was there under its other name. The about page
        // read "this browser has no datagrams.writable" while the wire row
        // blamed the network, and a player has no way to tell those apart.
        var dgw = wt.datagrams.createWritable ? wt.datagrams.createWritable()
                                              : wt.datagrams.writable;
        if (!dgw) {
            fail('this browser cannot write datagrams');
            return null;
        }
        // The next stream is accepted before this one is drained. Draining first
        // put every snapshot back in one queue: a stream whose tail was lost held
        // up snapshots that had arrived whole behind it, which is the head-of-line
        // stall this transport exists to remove, rebuilt on the client. Snapshots
        // may now finish out of order, which costs nothing: on_snapshot drops any
        // whose tick is not newer than the one it already applied.
        (function() {
            var streams = wt.incomingUnidirectionalStreams.getReader();
            var next = function() {
                streams.read().then(function(r) {
                    if (r.done) return;
                    next();
                    var chunks = [], total = 0;
                    var rd = r.value.getReader();
                    var drain = function() {
                        rd.read().then(function(c) {
                            if (c.done) {
                                var m = new Uint8Array(total), o = 0;
                                for (var i = 0; i < chunks.length; i++) {
                                    m.set(chunks[i], o);
                                    o += chunks[i].length;
                                }
                                enqueue(m);
                                return;
                            }
                            total += c.value.length;
                            S.progress += c.value.length;
                            if (total > S.cap) {
                                // Same refusal as the framed lane, for a stream
                                // that simply never ends.
                                rd.cancel().catch(function() {});
                                fail('zone sent a snapshot over ' + S.cap +
                                     ' bytes');
                                return;
                            }
                            chunks.push(c.value);
                            drain();
                        }, function() {});
                    };
                    drain();
                }, function() {});
            };
            next();
        })();
        // Snapshots that fit one packet.
        (function() {
            var rd = wt.datagrams.readable.getReader();
            var next = function() {
                rd.read().then(function(r) {
                    if (r.done) return;
                    S.progress += r.value.length;
                    enqueue(r.value);
                    next();
                }, function() {});
            };
            next();
        })();
        return wt.createBidirectionalStream().then(function(s) {
            S.rel = s.writable.getWriter();
            S.dg = dgw.getWriter();
            // The reliable lane back: u32-framed messages on our own stream.
            //
            // Chunks are held as they arrive and each message is assembled
            // once, when all of it is here. The previous version concatenated
            // the whole backlog with every read, so a map delivered in
            // packet-sized pieces copied its own prefix once per piece.
            var chunks = [], total = 0;
            var at = function(i) {
                for (var k = 0; k < chunks.length; k++) {
                    if (i < chunks[k].length) return chunks[k][i];
                    i -= chunks[k].length;
                }
                return 0;
            };
            var take = function(n) {
                var out = new Uint8Array(n), o = 0;
                while (o < n) {
                    var c = chunks[0], want = n - o;
                    if (c.length <= want) {
                        out.set(c, o);
                        o += c.length;
                        chunks.shift();
                    } else {
                        out.set(c.subarray(0, want), o);
                        chunks[0] = c.subarray(want);
                        o += want;
                    }
                }
                total -= n;
                return out;
            };
            var pump = function() {
                rd.read().then(function(r) {
                    if (r.done) { if (S.st === 2) S.st = 4; return; }
                    chunks.push(r.value);
                    total += r.value.length;
                    for (;;) {
                        if (total < 4) break;
                        var n = (at(0) | (at(1) << 8) | (at(2) << 16) |
                                 (at(3) << 24)) >>> 0;
                        // A length no message of ours can have. Believing it
                        // meant assembling whatever a zone claimed, so this
                        // ends the session rather than the heap.
                        if (n > S.cap) {
                            fail('zone sent a ' + n + ' byte message');
                            return;
                        }
                        if (total < 4 + n) break;
                        enqueue(take(4 + n).subarray(4));
                    }
                    S.progress += r.value.length;
                    pump();
                }, fail);
            };
            var rd = s.readable.getReader();
            pump();
            S.st = 2;
        });
    }).catch(fail);
    // Snapshots that outgrew a datagram: one unidirectional stream each,
    // read to the end and queued as one message.
    //
});

EM_JS(int, VWWT_State, (), {
    return Module.vwwt ? Module.vwwt.st : 0;
});

EM_JS(int, VWWT_NextLen, (), {
    var S = Module.vwwt;
    return (S && S.q.length) ? S.q[0].length : -1;
});

EM_JS(int, VWWT_Progress, (), {
    var S = Module.vwwt;
    if (!S) return 0;
    var n = S.progress;
    S.progress = 0;
    return n;
});

EM_JS(void, VWWT_Take, (void* dst), {
    var S = Module.vwwt;
    HEAPU8.set(S.q.shift(), dst);
});

// Throw the head away, for the one caller that cannot hold it.
EM_JS(void, VWWT_Drop, (), {
    var S = Module.vwwt;
    if (S) S.q.shift();
});

EM_JS(void, VWWT_Send, (const void* p, int n, int reliable), {
    var S = Module.vwwt;
    if (!S || S.st !== 2) return;
    if (reliable) {
        var b = new Uint8Array(4 + n);
        b[0] = n & 0xff;
        b[1] = (n >> 8) & 0xff;
        b[2] = (n >> 16) & 0xff;
        b[3] = (n >> 24) & 0xff;
        b.set(HEAPU8.subarray(p, p + n), 4);
        // A rejection here is the stream being gone, not the stream being
        // busy: back pressure arrives through writer.ready and resolves.
        // Swallowed, it left a session reporting itself open with every
        // reliable word falling on the floor, and a watcher, whose only
        // proof of life is this lane, silently kicked a minute later.
        S.rel.write(b).catch(function(e) { S.fail(e); });
    } else {
        // A copy, not a view: the wasm heap may move before the browser
        // consumes the buffer, and a datagram is small.
        //
        // This one really is dropped in silence, because that is what the
        // lane promises: an input nobody received is superseded by the next
        // one a frame later, and the reliable lane above speaks for the
        // session's health.
        var d = new Uint8Array(HEAPU8.subarray(p, p + n));
        S.dg.write(d).catch(function() {});
    }
});

EM_JS(void, VWWT_Close, (), {
    var S = Module.vwwt;
    if (!S) return;
    S.st = 4;
    if (S.wt) { try { S.wt.close(); } catch (e) {} }
});

EM_JS(int, VWWT_ErrLen, (), {
    var S = Module.vwwt;
    return S ? S.err.length : 0;
});

EM_JS(void, VWWT_ErrTake, (void* dst, int cap), {
    var S = Module.vwwt;
    var n = Math.min(S.err.length, cap);
    for (var i = 0; i < n; i++) HEAPU8[dst + i] = S.err.charCodeAt(i) & 0x7f;
});

#else // not DM_PLATFORM_HTML5

static int VWWT_Supported() { return 0; }
static void VWWT_Open(const char*, int, int) {}
static int VWWT_State() { return JS_NONE; }
static int VWWT_NextLen() { return -1; }
static int VWWT_Progress() { return 0; }
static void VWWT_Take(void*) {}
static void VWWT_Drop() {}
static void VWWT_Send(const void*, int, int) {}
static void VWWT_Close() {}
static int VWWT_ErrLen() { return 0; }
static void VWWT_ErrTake(void*, int) {}

#endif

// The one callback, and which state Lua has been told about. `m_Told` trails
// the JS state so each transition is delivered exactly once, from Update,
// where a Lua error lands in the engine's handler rather than inside a
// promise the game never sees.
struct State {
    dmScript::LuaCallbackInfo* m_Callback;
    int m_Told;
};
static State g_State = { 0, JS_NONE };

// Whether Deliver's PCall is on the C stack, and the callback a reentrant
// drop had to leave alive because that PCall's teardown is still coming.
//
// net.lua answers a refused dial or a dropped session by disconnecting, from
// inside the very callback delivering the event. Destroying the callback
// right there hands TeardownCallback a dead object the moment PCall returns,
// and the first push into its freed lua_State is a wasm trap: the fleet
// deploying under a WebTransport player took the whole client down this way.
// So a drop that lands mid-delivery only unhooks the callback, and Deliver
// destroys it after the teardown it still owes.
static bool g_InCallback = false;
static dmScript::LuaCallbackInfo* g_Zombie = 0;

static void Deliver(int event, const char* message, size_t length) {
    // Pinned across PCall: the Lua it runs may replace or clear
    // g_State.m_Callback, and the teardown must pair with this setup.
    dmScript::LuaCallbackInfo* cbk = g_State.m_Callback;
    if (!cbk || !dmScript::IsCallbackValid(cbk))
        return;
    lua_State* L = dmScript::GetCallbackLuaContext(cbk);
    DM_LUA_STACK_CHECK(L, 0);
    if (!dmScript::SetupCallback(cbk))
        return;
    lua_newtable(L);
    lua_pushinteger(L, event);
    lua_setfield(L, -2, "event");
    lua_pushlstring(L, message ? message : "", length);
    lua_setfield(L, -2, "message");
    g_InCallback = true;
    dmScript::PCall(L, 2, 0);
    g_InCallback = false;
    dmScript::TeardownCallback(cbk);
    if (g_Zombie) {
        dmScript::DestroyCallback(g_Zombie);
        g_Zombie = 0;
    }
}

static void DropCallback() {
    if (!g_State.m_Callback)
        return;
    if (g_InCallback && !g_Zombie) {
        // The one being delivered to right now. A second drop in the same
        // delivery can only concern a callback a reentrant connect installed
        // afterwards, which no C stack frame holds, so it dies directly.
        g_Zombie = g_State.m_Callback;
    } else {
        dmScript::DestroyCallback(g_State.m_Callback);
    }
    g_State.m_Callback = 0;
}

// Drop the callback that was just delivered to, and only that one.
//
// The state transitions end a session, so the callback goes with them. But
// the Lua that just ran may have dialled again and installed its own, and
// the plain drop above would take that one instead: a fresh session with
// nothing listening, which then times out and blames the network. So the
// end of one session may only retire the callback that session had.
static void DropDelivered(dmScript::LuaCallbackInfo* cbk) {
    if (g_State.m_Callback == cbk)
        DropCallback();
}

static int Lua_Supported(lua_State* L) {
    DM_LUA_STACK_CHECK(L, 1);
    lua_pushboolean(L, VWWT_Supported());
    return 1;
}

static int Lua_Connect(lua_State* L) {
    DM_LUA_STACK_CHECK(L, 1);
    size_t len = 0;
    const char* url = luaL_checklstring(L, 1, &len);
    luaL_checktype(L, 2, LUA_TFUNCTION);
    if (!VWWT_Supported()) {
        lua_pushboolean(L, 0);
        return 1;
    }
    VWWT_Close();
    DropCallback();
    g_State.m_Callback = dmScript::CreateCallback(L, 2);
    g_State.m_Told = JS_CONNECTING;
    VWWT_Open(url, (int)len, WT_S2C_MAX);
    lua_pushboolean(L, 1);
    return 1;
}

static int Lua_Send(lua_State* L) {
    DM_LUA_STACK_CHECK(L, 0);
    size_t len = 0;
    const char* data = luaL_checklstring(L, 1, &len);
    VWWT_Send(data, (int)len, 1);
    return 0;
}

// The unreliable lane, for what the next message supersedes: inputs, and
// nothing else the client says today. Silently a no-op when the session is
// not open, exactly as a lost datagram would be.
static int Lua_SendUnreliable(lua_State* L) {
    DM_LUA_STACK_CHECK(L, 0);
    size_t len = 0;
    const char* data = luaL_checklstring(L, 1, &len);
    VWWT_Send(data, (int)len, 0);
    return 0;
}

static int Lua_Disconnect(lua_State* L) {
    DM_LUA_STACK_CHECK(L, 0);
    VWWT_Close();
    DropCallback();
    g_State.m_Told = JS_NONE;
    return 0;
}

static const luaL_reg Module_methods[] = {
    { "supported", Lua_Supported },
    { "connect", Lua_Connect },
    { "send", Lua_Send },
    { "send_unreliable", Lua_SendUnreliable },
    { "disconnect", Lua_Disconnect },
    { 0, 0 }
};

static void LuaInit(lua_State* L) {
    DM_LUA_STACK_CHECK(L, 0);
    luaL_register(L, MODULE_NAME, Module_methods);
#define SETCONSTANT(name) \
    lua_pushnumber(L, (lua_Number)name); \
    lua_setfield(L, -2, #name);
    SETCONSTANT(EVENT_CONNECTED)
    SETCONSTANT(EVENT_MESSAGE)
    SETCONSTANT(EVENT_DISCONNECTED)
    SETCONSTANT(EVENT_ERROR)
    SETCONSTANT(EVENT_PROGRESS)
#undef SETCONSTANT
    lua_pop(L, 1);
}

static dmExtension::Result Initialize(dmExtension::Params* params) {
    LuaInit(params->m_L);
    return dmExtension::RESULT_OK;
}

static dmExtension::Result Finalize(dmExtension::Params*) {
    VWWT_Close();
    DropCallback();
    return dmExtension::RESULT_OK;
}

// Where a message is assembled on its way to Lua.
//
// One buffer that grows to the biggest message a session has seen and is
// then reused, rather than a malloc and a free per message per frame: at
// twenty snapshots a second that was steady churn in the frame loop for a
// block whose life is one call. WT_S2C_MAX bounds how far it can grow.
static char* g_msg = 0;
static int g_msg_cap = 0;

static dmExtension::Result OnUpdate(dmExtension::Params*) {
    if (!g_State.m_Callback)
        return dmExtension::RESULT_OK;
    if (VWWT_Progress() > 0) {
        Deliver(EVENT_PROGRESS, 0, 0);
        if (!g_State.m_Callback)
            return dmExtension::RESULT_OK;
    }
    // Messages first: anything that arrived before the session ended is
    // still the arena talking, and a refusal is exactly the message that
    // precedes a close.
    int len;
    int delivered = 0;
    while (delivered < 32 && (len = VWWT_NextLen()) >= 0) {
        if (len > g_msg_cap) {
            char* grown = (char*)realloc(g_msg, (size_t)len);
            if (!grown) {
                // Nothing to copy into. The message is dropped rather than
                // written through a null pointer, which is what the old
                // unchecked malloc did: straight to address zero, over
                // whatever the bottom of the heap was holding.
                VWWT_Drop();
                continue;
            }
            g_msg = grown;
            g_msg_cap = len;
        }
        VWWT_Take(g_msg);
        Deliver(EVENT_MESSAGE, g_msg, (size_t)len);
        delivered++;
        if (!g_State.m_Callback)
            return dmExtension::RESULT_OK;
    }
    int st = VWWT_State();
    if (st == g_State.m_Told)
        return dmExtension::RESULT_OK;
    g_State.m_Told = st;
    // Whose session is ending, so that a dial the handler starts keeps its
    // own callback. See DropDelivered.
    dmScript::LuaCallbackInfo* cbk = g_State.m_Callback;
    if (st == JS_OPEN) {
        Deliver(EVENT_CONNECTED, 0, 0);
    } else if (st == JS_ERROR) {
        char err[256] = { 0 };
        int n = VWWT_ErrLen();
        if (n > (int)sizeof(err) - 1) n = (int)sizeof(err) - 1;
        VWWT_ErrTake(err, n);
        Deliver(EVENT_ERROR, err, (size_t)n);
        DropDelivered(cbk);
    } else if (st == JS_CLOSED) {
        Deliver(EVENT_DISCONNECTED, 0, 0);
        DropDelivered(cbk);
    }
    return dmExtension::RESULT_OK;
}

static dmExtension::Result AppInitialize(dmExtension::AppParams*) {
    return dmExtension::RESULT_OK;
}

static dmExtension::Result AppFinalize(dmExtension::AppParams*) {
    return dmExtension::RESULT_OK;
}

} // namespace dmWebTransport

DM_DECLARE_EXTENSION(WebTransport, LIB_NAME, dmWebTransport::AppInitialize,
                     dmWebTransport::AppFinalize, dmWebTransport::Initialize,
                     dmWebTransport::OnUpdate, 0, dmWebTransport::Finalize)
