-- Two wires, one protocol, and this drives net.lua across both of them.
--
--     lua5.1 client/tests/wire_test.lua
--
-- What this pins is the choosing, which no server test can see. A zone that
-- advertises a WebTransport address gets dialled there first, the join is the
-- same message either way, and inputs ride the unreliable lane. A dial that
-- goes nowhere falls back to the WebSocket without a word and without asking
-- again for the rest of the session, since three silent seconds is a price a
-- player should pay once. And the reorder guard: streams and datagrams can pass
-- each other, so a snapshot arriving behind one already applied is dropped
-- rather than walking the room backwards.

package.path = "client/?.lua;" .. package.path

local fails = 0
local function check(name, ok, detail)
    if ok then
        print("ok   " .. name)
    else
        fails = fails + 1
        print("FAIL " .. name .. (detail and ("  -- " .. detail) or ""))
    end
end

-- --- the world, as a counter ------------------------------------------------

local tick = 1000
_G.sim = {
    tick = function() return tick end,
    replay = function() tick = tick + 1 end,
    step = function() tick = tick + 1 end,
    apply_snapshot = function() return 0 end,
    smooth_capture = function() end,
    smooth_settle = function() end,
    smooth_reset = function() end,
    set_mortal = function() end,
    ship_count = function() return 2 end,
    ship_alive = function() return 1 end,
    ship_active = function() return 1 end,
    ship_vel = function() return 0, 0 end,
    ship_x_raw = function() return 0 end,
    ship_y_raw = function() return 0 end,
    weapon_count = function() return 0 end,
    weapon_at = function() end,
    spec_life = function() return 0 end,
    spec_blast = function() return 0 end,
}

-- --- both wires, as stubs ---------------------------------------------------

local ws = {dialled = 0, sent = {}}
_G.websocket = {
    EVENT_CONNECTED = 1,
    EVENT_MESSAGE = 2,
    EVENT_DISCONNECTED = 3,
    EVENT_ERROR = 4,
    DATA_TYPE_BINARY = 1,
    connect = function(url, _, cb)
        ws.dialled = ws.dialled + 1
        ws.url, ws.cb = url, cb
        ws.handle = {url = url}
        return ws.handle
    end,
    disconnect = function() end,
    send = function(_, data) ws.sent[#ws.sent + 1] = data end,
}

local wt = {dialled = 0, sent = {}, unsent = {}, on_connect = nil}
_G.webtransport = {
    EVENT_CONNECTED = 1,
    EVENT_MESSAGE = 2,
    EVENT_DISCONNECTED = 3,
    EVENT_ERROR = 4,
    supported = function() return true end,
    connect = function(url, cb)
        wt.dialled = wt.dialled + 1
        wt.url, wt.cb = url, cb
        if wt.on_connect then wt.on_connect(cb) end
        return true
    end,
    disconnect = function() end,
    send = function(data) wt.sent[#wt.sent + 1] = data end,
    send_unreliable = function(data) wt.unsent[#wt.unsent + 1] = data end,
}

package.loaded["arena.account"] = {token = nil}

-- The module keeps its transport memory for the life of the client, which is
-- the point of `wt_avoid` and the enemy of a test that needs a fresh one.
local function fresh_net()
    package.loaded["arena.net"] = nil
    ws.dialled, ws.sent, ws.cb = 0, {}, nil
    wt.dialled, wt.sent, wt.unsent, wt.cb = 0, {}, {}, nil
    return require("arena.net")
end

local function u32le(v)
    return string.char(v % 256, math.floor(v / 256) % 256,
                       math.floor(v / 65536) % 256,
                       math.floor(v / 16777216) % 256)
end

-- A snapshot as the wire carries it: kind, subject, acked tick, then the
-- pack, whose first field is the simulation tick.
local function snapshot(ship, sim_tick)
    return string.char(2, ship, 0, 0, 0, 0) .. u32le(sim_tick) .. "rest"
end

-- --- the preferred wire -----------------------------------------------------

local net = fresh_net()
net.connect("wss://zone/a1", 0, "pilot", function() end, "chaos", false,
            "https://zone:9443")
check("an advertised door is dialled first", wt.dialled == 1 and ws.dialled == 0)
check("and it is the advertised address", wt.url == "https://zone:9443")
check("the readout names the wire", net.stats.wire == "wt")

wt.cb(nil, {event = webtransport.EVENT_CONNECTED})
check("the join rides the reliable lane", #wt.sent == 1
      and string.byte(wt.sent[1], 1) == 1, tostring(#wt.sent))
-- Read off the module rather than written down again. A number in two places
-- is a test that fails on every bump of a wire it is not about.
check("and speaks the wire's own protocol",
      string.byte(wt.sent[1], 3) == net.PROTOCOL,
      "spoke " .. tostring(string.byte(wt.sent[1], 3)))

wt.cb(nil, {event = webtransport.EVENT_MESSAGE,
            message = string.char(1, 3, 0, 0, 0, 0)})
wt.cb(nil, {event = webtransport.EVENT_MESSAGE, message = snapshot(3, 5000)})
check("the welcome and the snapshot land", net.connected
      and net.stats.snaps == 1)

net.step(0)
check("inputs ride the unreliable lane", #wt.unsent == 1
      and string.byte(wt.unsent[1], 1) == 2,
      tostring(#wt.unsent))
check("and nothing leaks onto the socket", ws.dialled == 0)

-- --- the reorder guard ------------------------------------------------------

wt.cb(nil, {event = webtransport.EVENT_MESSAGE, message = snapshot(3, 4999)})
check("a snapshot from behind is dropped", net.stats.snaps == 1,
      "applied " .. net.stats.snaps)
wt.cb(nil, {event = webtransport.EVENT_MESSAGE, message = snapshot(3, 5001)})
check("and the next fresh one lands", net.stats.snaps == 2)

-- --- nothing before the welcome ---------------------------------------------
--
-- The zone sends map, settings and welcome on the reliable lane and snapshots
-- beside it. Only TCP ever made that an order: a datagram passes the map on
-- its way up, and applying it would step a world with no terrain and no seat,
-- as ship zero, who is somebody else.

net = fresh_net()
net.connect("wss://zone/a1", 0, "pilot", function() end, "chaos", false,
            "https://zone:9443")
wt.cb(nil, {event = webtransport.EVENT_CONNECTED})
wt.cb(nil, {event = webtransport.EVENT_MESSAGE, message = snapshot(3, 5000)})
check("a snapshot before the welcome is not applied", net.stats.snaps == 0,
      "applied " .. net.stats.snaps)
wt.cb(nil, {event = webtransport.EVENT_MESSAGE,
            message = string.char(1, 3, 0, 0, 0, 0)})
wt.cb(nil, {event = webtransport.EVENT_MESSAGE, message = snapshot(3, 5001)})
check("and the first one after it is", net.stats.snaps == 1)

-- --- the guard covers a watcher too -----------------------------------------
--
-- It used to be off entirely while watching, because the shared channel runs
-- seconds behind live and a view change moves this clock backwards on
-- purpose. Reordering is a snapshot or two and a view change is seconds, so
-- the two are told apart by size: a stale packet is refused, and a rewind big
-- enough to be a change of view is taken. Left open, one death drew two
-- explosions, because the stale snapshot revived a hull the room had killed.

net = fresh_net()
net.connect("wss://zone/a1", 0, "pilot", function() end, "chaos", true,
            "https://zone:9443")
wt.cb(nil, {event = webtransport.EVENT_CONNECTED})
-- A welcome seating nobody: 255 is the watcher's seat.
wt.cb(nil, {event = webtransport.EVENT_MESSAGE,
            message = string.char(1, 255, 0, 0, 0, 0)})
check("the watcher is watching", net.watching)
wt.cb(nil, {event = webtransport.EVENT_MESSAGE, message = snapshot(3, 5000)})
check("a channel snapshot lands", net.stats.snaps == 1,
      "applied " .. net.stats.snaps)
wt.cb(nil, {event = webtransport.EVENT_MESSAGE, message = snapshot(3, 4995)})
check("a stale one is dropped rather than reviving the dead",
      net.stats.snaps == 1, "applied " .. net.stats.snaps)
wt.cb(nil, {event = webtransport.EVENT_MESSAGE, message = snapshot(3, 4000)})
check("but a rewind the size of the channel delay is a change of view",
      net.stats.snaps == 2, "applied " .. net.stats.snaps)

-- --- the fallback, on silence -----------------------------------------------

net = fresh_net()
net.connect("wss://zone/a1", 0, "pilot", function() end, "chaos", false,
            "https://zone:9443")
check("the dial starts on the preferred wire", wt.dialled == 1)
for _ = 1, 4 do net.tick(1) end
check("three quiet seconds turn to the socket", ws.dialled == 1,
      "dialled " .. ws.dialled)
ws.cb(nil, ws.handle, {event = websocket.EVENT_CONNECTED})
check("and the join is the same message", #ws.sent == 1
      and string.byte(ws.sent[1], 1) == 1)
check("the readout says so", net.stats.wire == "ws")

-- The same door again. It went unanswered a moment ago and three more
-- seconds of silence would buy nothing, so the join goes straight to the
-- socket.
net.connect("wss://zone/a1", 0, "pilot", function() end, "chaos", false,
            "https://zone:9443")
check("a burned dial is not asked again", wt.dialled == 1 and ws.dialled == 2)

-- A different zone's door, which is a different fact. An arena spends its
-- first half minute waiting for a certificate and advertises the address
-- throughout, so one silent door says nothing about the next one; blaming
-- the whole session for it put players back on the wire QUIC replaces and
-- told them their network had eaten it.
net.connect("wss://zone/a2", 0, "pilot", function() end, "war", false,
            "https://zone:9444")
check("another zone's door still gets its own dial",
      wt.dialled == 2 and ws.dialled == 2,
      "wt " .. wt.dialled .. " ws " .. ws.dialled)

-- --- the fallback, on refusal -----------------------------------------------

net = fresh_net()
wt.on_connect = function(cb)
    cb(nil, {event = webtransport.EVENT_ERROR, message = "no route"})
end
net.connect("wss://zone/a1", 0, "pilot", function() end, "chaos", false,
            "https://zone:9443")
wt.on_connect = nil
check("a refused dial falls back at once", ws.dialled == 1)
-- And keeps what the browser said. On a phone this is the whole of the
-- diagnosis: there is no console to open, and a refusal and a timeout are
-- the same silence without it.
check("and keeps the browser's own words", net.transport().reason == "no route",
      tostring(net.transport().reason))

-- A dial nobody answered has nothing to quote, and must not borrow the last
-- refusal's words: no reason at all is the reading that says the packets left
-- and none came back.
net = fresh_net()
net.connect("wss://zone/a1", 0, "pilot", function() end, "chaos", false,
            "https://zone:9443")
for _ = 1, 4 do net.tick(1) end
check("a timeout reports no reason rather than a stale one",
      net.transport().reason == nil, tostring(net.transport().reason))

-- --- a drop after the join is a loss, not a fallback ------------------------

net = fresh_net()
local why = nil
net.connect("wss://zone/a1", 0, "pilot", function(w) why = w end, "chaos",
            false, "https://zone:9443")
wt.cb(nil, {event = webtransport.EVENT_CONNECTED})
wt.cb(nil, {event = webtransport.EVENT_MESSAGE,
            message = string.char(1, 3, 0, 0, 0, 0)})
wt.cb(nil, {event = webtransport.EVENT_DISCONNECTED})
check("a drop mid-game reports rather than redialling", why ~= nil
      and ws.dialled == 0, tostring(why))

-- --- the fallback, on a session that opens and says nothing ------------------
--
-- The handshake is not the session. A browser mid-update has been seen
-- completing the QUIC handshake and then wedging half-open, the reliable lane
-- stalled with datagrams still flowing, and the dial clock cannot catch that:
-- it stopped the moment the session opened. Only a snapshot proves the whole
-- wire works, so an opened session gets a few seconds to produce one and then
-- the socket takes the join, exactly as an unanswered dial would have gone.

net = fresh_net()
net.connect("wss://zone/a1", 0, "pilot", function() end, "chaos", false,
            "https://zone:9443")
wt.cb(nil, {event = webtransport.EVENT_CONNECTED})
check("the wedge case starts on the fast door",
      net.stats.wire == "wt" and ws.dialled == 0)
for _ = 1, 4 do net.tick(1) end
check("an open session gets more patience than a dial", ws.dialled == 0,
      "dialled " .. ws.dialled)
for _ = 1, 2 do net.tick(1) end
check("but a session that never delivers loses the join", ws.dialled == 1,
      "dialled " .. ws.dialled)
ws.cb(nil, ws.handle, {event = websocket.EVENT_CONNECTED})
check("and the socket carries the same join", #ws.sent == 1
      and string.byte(ws.sent[1], 1) == 1)

-- A welcome alone is not deliverance: the wedge that prompted this carried
-- the other half dead, and a session whose datagrams never arrive is a game
-- at snapshot-rate zero. The snapshot is the proof, whichever lane it rode.
net = fresh_net()
net.connect("wss://zone/a1", 0, "pilot", function() end, "chaos", false,
            "https://zone:9443")
wt.cb(nil, {event = webtransport.EVENT_CONNECTED})
wt.cb(nil, {event = webtransport.EVENT_MESSAGE,
            message = string.char(1, 3, 0, 0, 0, 0)})
for _ = 1, 6 do net.tick(1) end
check("a welcome without snapshots still loses the join", ws.dialled == 1,
      "dialled " .. ws.dialled)

-- And one snapshot settles the wire for good: the clock stops, and six quiet
-- seconds later the session is still the one that was joined.
net = fresh_net()
net.connect("wss://zone/a1", 0, "pilot", function() end, "chaos", false,
            "https://zone:9443")
wt.cb(nil, {event = webtransport.EVENT_CONNECTED})
wt.cb(nil, {event = webtransport.EVENT_MESSAGE,
            message = string.char(1, 3, 0, 0, 0, 0)})
wt.cb(nil, {event = webtransport.EVENT_MESSAGE, message = snapshot(3, 5000)})
for _ = 1, 6 do net.tick(1) end
check("one snapshot settles the session", ws.dialled == 0
      and net.stats.wire == "wt", "dialled " .. ws.dialled)

-- A session that dies while settling is a loss with a reason, and the clock
-- dies with it rather than redialling over the report.
net = fresh_net()
why = nil
net.connect("wss://zone/a1", 0, "pilot", function(w) why = w end, "chaos",
            false, "https://zone:9443")
wt.cb(nil, {event = webtransport.EVENT_CONNECTED})
wt.cb(nil, {event = webtransport.EVENT_MESSAGE,
            message = string.char(1, 3, 0, 0, 0, 0)})
wt.cb(nil, {event = webtransport.EVENT_DISCONNECTED})
for _ = 1, 6 do net.tick(1) end
check("a loss while settling stays a loss", why ~= nil and ws.dialled == 0,
      tostring(why) .. ", dialled " .. ws.dialled)

-- --- what the about page reads ----------------------------------------------
--
-- The page prints one line per state, so every state has to be answerable.
-- Nothing here checks the wording, which belongs to the page; what it checks
-- is that each answer is distinguishable from the others, because a readout
-- that says the same thing on the good door and the bad one is furniture.

net = fresh_net()
local t = net.transport()
check("between games it reports no wire", t.kind == nil)
check("and says the better door is available", t.able and not t.refused)

net.connect("wss://zone/a1", 0, "pilot", function() end, "chaos", false,
            "https://zone:9443")
check("a dial in the air says so", net.transport().trying)
wt.cb(nil, {event = webtransport.EVENT_CONNECTED})
-- Open is not proven: until a snapshot lands the settle clock is running and
-- the readout keeps saying so, because a session that opened and delivered
-- nothing is exactly the state the reader is trying to diagnose.
check("an open session still counts as trying", net.transport().trying)
wt.cb(nil, {event = webtransport.EVENT_MESSAGE,
            message = string.char(1, 3, 0, 0, 0, 0)})
wt.cb(nil, {event = webtransport.EVENT_MESSAGE, message = snapshot(3, 5000)})
t = net.transport()
check("a proven session names webtransport", t.kind == "wt" and not t.trying)

net = fresh_net()
net.connect("wss://zone/a1", 0, "pilot", function() end, "chaos", false,
            "https://zone:9443")
for _ = 1, 4 do net.tick(1) end
t = net.transport()
check("after the fallback it names the socket", t.kind == "ws")
check("and remembers why it is on it", t.refused)
check("and that the socket is encrypted", t.secure)

-- Rejoining the same door, which skips the dial on the strength of the first
-- attempt. It ends on the socket for the same stated reason and is a
-- different fact: no handshake was sent, so nothing downstream saw one, and a
-- reader who cannot tell them apart goes looking for a firewall dropping
-- packets that were never sent.
net.connect("wss://zone/a1", 0, "pilot", function() end, "chaos", false,
            "https://zone:9443")
t = net.transport()
check("a skipped dial is not reported as an unanswered one", not t.tried)
check("and it is still on the socket for a reason", t.refused and t.offered)

net = fresh_net()
net.connect("ws://localhost:9001", 0, "pilot", function() end, "", false, nil)
t = net.transport()
check("a cleartext socket is reported as one", t.kind == "ws" and not t.secure)
-- A zone that advertises no door at all is not a network that ate one, and
-- the page must not blame it for a QUIC dial nobody was ever offered. The
-- session's own memory of a fallback outlives the game that caused it.
check("and it is not blamed for a door it was never offered", not t.offered)

-- A build with no extension at all: native, or a browser without the API.
-- The page has to say "websocket only" rather than promising a door that
-- does not exist here.
local saved = _G.webtransport
_G.webtransport = nil
net = fresh_net()
check("with no extension it reports it cannot", not net.transport().able)
_G.webtransport = saved

if fails > 0 then os.exit(1) end
print("all fine")
