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
local reject_snapshot = false
local settings_applied = 0
local own_x, own_y, own_alive = 0, 0, 1
local next_x, next_y, next_alive = nil, nil, nil
local own_vx, own_vy, own_repel_ticks, own_repel_speed = 0, 0, 0, 0
local next_vx, next_vy, next_repel_ticks, next_repel_speed = nil, nil, nil, nil
local smooth_repel_started, smooth_correction_absorbed = false, false
local sim_events = {}
_G.sim = {
    tick = function() return tick end,
    replay = function() tick = tick + 1 end,
    step = function() tick = tick + 1 end,
    apply_snapshot = function(body)
        if reject_snapshot then reject_snapshot = false return -1 end
        tick = string.byte(body, 1) + string.byte(body, 2) * 256
            + string.byte(body, 3) * 65536
            + string.byte(body, 4) * 16777216
        if next_x ~= nil then own_x, next_x = next_x, nil end
        if next_y ~= nil then own_y, next_y = next_y, nil end
        if next_alive ~= nil then own_alive, next_alive = next_alive, nil end
        if next_vx ~= nil then own_vx, next_vx = next_vx, nil end
        if next_vy ~= nil then own_vy, next_vy = next_vy, nil end
        if next_repel_ticks ~= nil then
            own_repel_ticks, next_repel_ticks = next_repel_ticks, nil
        end
        if next_repel_speed ~= nil then
            own_repel_speed, next_repel_speed = next_repel_speed, nil
        end
        return 0
    end,
    apply_settings = function()
        settings_applied = settings_applied + 1
        return 0
    end,
    smooth_capture = function() end,
    smooth_settle = function()
        return smooth_repel_started, smooth_correction_absorbed
    end,
    smooth_debt = function() return 1.5, 0.25 end,
    smooth_reset = function() end,
    set_mortal = function() end,
    ship_count = function() return 2 end,
    ship_alive = function(i) return i == 3 and own_alive or 1 end,
    ship_deaths = function() return 0 end,
    ship_active = function() return 1 end,
    ship_vel = function() return own_vx, own_vy end,
    ship_repel = function() return own_repel_ticks, own_repel_speed end,
    ship_x_raw = function(i) return i == 3 and own_x or 0 end,
    ship_y_raw = function(i) return i == 3 and own_y or 0 end,
    ship_heading_raw = function() return 0 end,
    weapon_count = function() return 0 end,
    weapon_at = function() end,
    spec_life = function() return 0 end,
    spec_blast = function() return 0 end,
    event_count = function() return #sim_events end,
    event_at = function(i)
        local event = sim_events[i + 1]
        return event[1], event[2], event[3], event[4]
    end,
}

-- --- both wires, as stubs ---------------------------------------------------

local ws = {dialled = 0, sent = {}}
_G.websocket = {
    EVENT_CONNECTED = 1,
    EVENT_MESSAGE = 2,
    EVENT_DISCONNECTED = 3,
    EVENT_ERROR = 4,
    EVENT_PROGRESS = 5,
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

local wt = {dialled = 0, disconnects = 0, sent = {}, unsent = {}, on_connect = nil}
_G.webtransport = {
    EVENT_CONNECTED = 1,
    EVENT_MESSAGE = 2,
    EVENT_DISCONNECTED = 3,
    EVENT_ERROR = 4,
    EVENT_PROGRESS = 5,
    supported = function() return true end,
    connect = function(url, cb)
        wt.dialled = wt.dialled + 1
        wt.url, wt.cb = url, cb
        if wt.on_connect then wt.on_connect(cb) end
        return true
    end,
    disconnect = function() wt.disconnects = wt.disconnects + 1 end,
    send = function(data) wt.sent[#wt.sent + 1] = data end,
    send_unreliable = function(data) wt.unsent[#wt.unsent + 1] = data end,
}

local debug_reports = {}
local account_stub = {
    token = nil,
    account = 7,
    report_debug = function(report) debug_reports[#debug_reports + 1] = report end,
}
package.loaded["arena.account"] = account_stub

-- The module keeps its transport memory for the life of the client, which is
-- the point of `wt_avoid` and the enemy of a test that needs a fresh one.
local function fresh_net()
    package.loaded["arena.net"] = nil
    ws.dialled, ws.sent, ws.cb = 0, {}, nil
    wt.dialled, wt.disconnects, wt.sent, wt.unsent, wt.cb = 0, 0, {}, {}, nil
    own_x, own_y, own_alive = 0, 0, 1
    next_x, next_y, next_alive = nil, nil, nil
    sim_events = {}
    debug_reports = {}
    return require("arena.net")
end

local function u32le(v)
    return string.char(v % 256, math.floor(v / 256) % 256,
                       math.floor(v / 65536) % 256,
                       math.floor(v / 16777216) % 256)
end

local snapshot_seq = 0
-- A snapshot as the wire carries it: subject, input receipt window, sequence,
-- lag telemetry, then the pack, whose first field is the simulation tick.
local function welcome(ship, lifecycle, settings, room)
    return string.char(1, ship) .. u32le(lifecycle or 1) .. u32le(0)
        .. string.char(room or 1, 0) .. u32le(settings or 0)
end

local function snapshot(ship, sim_tick, input_ack, input_mask, watching, lifecycle,
                        settings)
    snapshot_seq = snapshot_seq % 4294967295 + 1
    return string.char(2, ship, watching and 1 or 0)
        .. u32le(lifecycle or 1) .. u32le(settings or 0)
        .. u32le(input_ack or 0)
        .. u32le(input_mask or 0) .. u32le(snapshot_seq)
        .. string.char(80, 0, 5, 0, 2, 3, 4, 0, 0)
        .. u32le(sim_tick) .. "rest"
end

local function records(message)
    local out = {}
    for i = 0, string.byte(message, 2) - 1 do
        local at = 15 + i * 6
        local named = string.byte(message, at)
            + string.byte(message, at + 1) * 256
            + string.byte(message, at + 2) * 65536
            + string.byte(message, at + 3) * 16777216
        local buttons = string.byte(message, at + 4)
            + string.byte(message, at + 5) * 256
        out[named] = buttons
    end
    return out
end

-- --- the preferred wire -----------------------------------------------------

local net = fresh_net()
net.connect("wss://zone/a1", 0, "pilot", function() end,
            "chaos", false, "https://zone:9443")
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
local canonical_join = string.char(1, 0, net.PROTOCOL, 0, 5, 5, 0, 0)
    .. "chaospilot"
check("the join header and payload agree byte for byte",
      wt.sent[1] == canonical_join)

wt.cb(nil, {event = webtransport.EVENT_MESSAGE,
            message = welcome(3)})
wt.cb(nil, {event = webtransport.EVENT_MESSAGE, message = snapshot(3, 5000)})
check("the welcome and the snapshot land", net.connected
      and net.stats.snaps == 1)
check("server lag telemetry reaches the readout",
      net.stats.server_rtt_ms == 80 and net.stats.jitter_ms == 5
      and net.stats.down_loss == 2
      and net.stats.combat_loss == 3 and net.stats.up_loss == 4)
local startup_records = {}
for _, message in ipairs(wt.unsent) do
    for named, buttons in pairs(records(message)) do
        startup_records[named] = buttons
    end
end
local startup_complete = #wt.unsent == 2 and net.stats.lead == 8
for named = 5001, 5008 do
    startup_complete = startup_complete and startup_records[named] == 0
end
check("the first snapshot seeds a coherent prediction lead", startup_complete,
      "packets " .. #wt.unsent .. ", lead " .. net.stats.lead)
wt.cb(nil, {event = webtransport.EVENT_MESSAGE,
            message = string.char(16, 1, 0, 120, 0, 25, 0, 20, 30, 10)})
check("stale input policy is visible to the pilot",
      net.lag_notice == "INPUT STREAM: objectives locked")
wt.cb(nil, {event = webtransport.EVENT_MESSAGE,
            message = string.char(16, 0, 0, 80, 0, 5, 0, 2, 3, 4)})
check("the lag notice clears when policy recovers", net.lag_notice == "")

net.step(0)
check("inputs ride the unreliable lane", #wt.unsent == 3
      and string.byte(wt.unsent[#wt.unsent], 1) == 2,
      tostring(#wt.unsent))
check("inputs acknowledge the snapshot receipt window",
      string.byte(wt.unsent[#wt.unsent], 7) == 1
      and string.byte(wt.unsent[#wt.unsent], 11) == 1)
check("and nothing leaks onto the socket", ws.dialled == 0)

-- The clock and the score, which is the newest answer rather than a queue:
-- one lost to a full socket costs a second of clock and the next repairs it.
wt.cb(nil, {event = webtransport.EVENT_MESSAGE,
            message = string.char(14, 1, 97, 2, 3, 0, 5, 0)})
check("a match clock arrives",
      net.match and net.match.playing and net.match.left == 97
      and net.match.score[0] == 3 and net.match.score[1] == 5)
wt.cb(nil, {event = webtransport.EVENT_MESSAGE,
            message = string.char(14, 0, 25, 2, 3, 0, 5, 0)})
check("and the whistle replaces it rather than queueing behind it",
      net.match and not net.match.playing and net.match.left == 25)
local artifact = 4294967296 + 123456
wt.cb(nil, {event = webtransport.EVENT_MESSAGE,
            message = string.char(14, 2, 24, 2, 3, 0, 5, 0)
                .. u32le(123456) .. u32le(1)})
check("the whistle carries its public match film",
      net.match and net.match.artifact == artifact,
      tostring(net.match and net.match.artifact))

wt.cb(nil, {event = webtransport.EVENT_MESSAGE,
            message = string.char(14, 4, 180, 2, 0, 0, 0, 0, 1, 6)
                .. u32le(0) .. u32le(0) .. u32le(0) .. string.char(0)})
check("an unopened duel arrives as one waiting match state",
      net.match and not net.match.playing and net.match.artifact == nil
      and net.match.duel and net.match.duel.waiting
      and net.match.duel.streak == 0
      and net.match.duel.legs == 0
      and #net.match.duel.log == 0)
-- The byte after the status: how long the room will go on keeping the second
-- seat open for a person. Timed by the room, because the room is what started
-- the wait, and drawn in the middle of the screen while it runs.
check("and carries how long the second seat is still held for",
      net.match.duel.hold == 6, tostring(net.match.duel.hold))

-- One opponent taken and the next one lost, which is the shape of every
-- evening. A leg is variable width, because it carries a call sign: result,
-- seconds, the length of the name and then the name.
local function leg(rival, result, seconds)
    return string.char(result)
        .. string.char(seconds % 256, math.floor(seconds / 256))
        .. string.char(#rival) .. rival
end

wt.cb(nil, {event = webtransport.EVENT_MESSAGE,
            message = string.char(14, 6, 24, 2, 3, 0, 5, 0)
                .. u32le(123456) .. u32le(1) .. string.char(0, 0)
                .. u32le(3) .. u32le(4) .. u32le(19) .. string.char(2)
                .. leg("Vantage 0001", 1, 41) .. leg("Sable 0001", 0, 7)})
check("a duel result replaces clock, film, and card atomically",
      net.match and net.match.duel
      and not net.match.duel.waiting
      and net.match.duel.hold == 0
      and net.match.duel.streak == 3
      and net.match.duel.best_streak == 4
      and net.match.artifact == artifact)
-- The card rides in the same packet as the result that moved it, so no client
-- ever holds a log from one state beside a streak from another.
check("and the card rides with it, oldest fight first",
      net.match.duel.legs == 19
      and #net.match.duel.log == 2
      and net.match.duel.log[1].rival == "Vantage 0001"
      and net.match.duel.log[1].result == "cleared"
      and net.match.duel.log[1].seconds == 41
      and net.match.duel.log[2].rival == "Sable 0001"
      and net.match.duel.log[2].result == "lost"
      and net.match.duel.log[2].seconds == 7,
      tostring(net.match.duel.legs) .. " legs, "
      .. tostring(#net.match.duel.log) .. " logged")

-- A body promising more legs than it carries is a truncated message, not a
-- short run. Half a log would draw an evening that stopped where the packet
-- did, so the whole message is dropped and the last good one stands.
local before = net.match.duel.log[2].rival
wt.cb(nil, {event = webtransport.EVENT_MESSAGE,
            message = string.char(14, 4, 24, 2, 3, 0, 5, 0)
                .. string.char(0)
                .. u32le(3) .. u32le(4) .. u32le(19)
                .. string.char(4) .. leg("Kestrel 0001", 1, 5)})
check("a truncated card is refused rather than half read",
      net.match.duel.log[2] ~= nil
      and net.match.duel.log[2].rival == before
      and #net.match.duel.log == 2)

-- And a name that runs past the end of the body is the same fault: the length
-- byte is a promise the packet has to keep.
wt.cb(nil, {event = webtransport.EVENT_MESSAGE,
            message = string.char(14, 4, 24, 2, 3, 0, 5, 0)
                .. string.char(0)
                .. u32le(3) .. u32le(4) .. u32le(19) .. string.char(1)
                .. string.char(1) .. string.char(5, 0) .. string.char(20)
                .. "short"})
check("a call sign cut off by the end of the body is refused too",
      net.match.duel.log[2] ~= nil
      and net.match.duel.log[2].rival == before
      and #net.match.duel.log == 2)

local reliable_before, unreliable_before = #wt.sent, #wt.unsent
check("focus loss can release held controls", net.release_controls())
check("the release uses both input lanes",
      #wt.sent == reliable_before + 1
      and #wt.unsent == unreliable_before + 1)
check("the release belongs to this lifecycle and holds no buttons",
      string.byte(wt.sent[#wt.sent], 3) == 1
      and next(records(wt.sent[#wt.sent])) ~= nil
      and select(2, next(records(wt.sent[#wt.sent]))) == 0)

-- The next datagram carries the tick before it as well. Treat the first as
-- lost and the second still contains the exact state that disappeared with it.
net.step(0x1234)
net.step(0)
local repaired = wt.unsent[#wt.unsent]
local count = string.byte(repaired, 2)
local repair_records = records(repaired)
local pressed_tick = nil
for named, value in pairs(repair_records) do
    if value == 0x1234 then pressed_tick = named end
end
check("a fresh datagram repairs a lost input", count >= 2
      and pressed_tick ~= nil, "count " .. count)

-- The server has received the ticks on either side but not the press itself.
-- Once that selective zero comes back, the next packet spends a record on the
-- hole even though it is no longer in the newest consecutive tail.
wt.cb(nil, {event = webtransport.EVENT_MESSAGE,
            message = snapshot(3, 5001, pressed_tick + 1, 0x7fd)})
net.step(0)
check("an acknowledged input hole is repaired directly",
      records(wt.unsent[#wt.unsent])[pressed_tick] == 0x1234)

-- --- the reorder guard ------------------------------------------------------

wt.cb(nil, {event = webtransport.EVENT_MESSAGE, message = snapshot(3, 4999)})
check("a snapshot from behind is dropped", net.stats.snaps == 2,
      "applied " .. net.stats.snaps)
wt.cb(nil, {event = webtransport.EVENT_MESSAGE, message = snapshot(3, 5002)})
check("and the next fresh one lands", net.stats.snaps == 3)

net = fresh_net()
snapshot_seq = 4294967294
local lost_reason = nil
net.connect("wss://zone/a1", 0, "pilot", function(why) lost_reason = why end,
            "chaos", false,
            "https://zone:9443")
wt.cb(nil, {event = webtransport.EVENT_CONNECTED})
wt.cb(nil, {event = webtransport.EVENT_MESSAGE, message = welcome(3)})
wt.cb(nil, {event = webtransport.EVENT_MESSAGE,
            message = snapshot(3, 4294967295)})
wt.cb(nil, {event = webtransport.EVENT_MESSAGE, message = snapshot(3, 1)})
check("snapshot sequences and world ticks cross rollover together",
      net.stats.snaps == 2 and net.stats.snap_reordered == 0)

-- Reliable events can pass the datagram carrying the state that depicts them.
-- They wait for that authoritative tick, then become visible together.
-- The last byte is the private one: 1 says this pilot helped with that kill,
-- and the zone sets it on one copy of the message and zeroes every other.
local remote_kill = string.char(4, 1, 0, 176, 4, 176, 4, 1, 5, 0)
    .. u32le(5010) .. string.char(0)
local my_kill = string.char(4, 1, 3, 176, 4, 176, 4, 1, 5, 0)
    .. u32le(5010) .. string.char(0)
local my_death = string.char(4, 3, 0, 176, 4, 176, 4, 1, 5, 0)
    .. u32le(5010) .. string.char(0)
local my_assist = string.char(4, 2, 0, 176, 4, 176, 4, 2, 5, 0)
    .. u32le(5010) .. string.char(1)
local charge = string.char(15, 1, 0)
    .. string.char(0, 1, 0, 0, 0, 2, 0, 0) .. u32le(5010)
wt.cb(nil, {event = webtransport.EVENT_MESSAGE, message = remote_kill})
wt.cb(nil, {event = webtransport.EVENT_MESSAGE, message = my_kill})
wt.cb(nil, {event = webtransport.EVENT_MESSAGE, message = my_death})
wt.cb(nil, {event = webtransport.EVENT_MESSAGE, message = my_assist})
wt.cb(nil, {event = webtransport.EVENT_MESSAGE, message = charge})
check("combat news waits for its snapshot",
      #net.kills == 0 and #net.charge_events == 0)
wt.cb(nil, {event = webtransport.EVENT_MESSAGE, message = snapshot(3, 5010)})
check("combat news lands with its authoritative tick",
      #net.kills == 4 and #net.charge_events == 1)
-- Whether you helped with one is carried on the kill it belongs to rather
-- than as news of its own, so the feed has one line to write and not two.
check("a kill you helped with says so, and the others do not",
      net.kills[4].assist == true and net.kills[1].assist == false
      and net.kills[2].assist == false and net.kills[3].assist == false,
      tostring(net.kills[4].assist))
-- Every kill in the room, in the order the wire carried them, whoever was in
-- it. The queue used to hold only the two you were part of, which left the
-- feed unable to say who was doing the killing while it happened; a melee room
-- is eight ships and the whole fight is a few lines a minute. Which of them is
-- yours is decided where the line is written, not here.
check("every kill in the room is news, not only yours",
      net.kills[1].killer == 0 and net.kills[1].victim == 1
      and net.kills[2].killer == 3 and net.kills[3].victim == 3,
      #net.kills .. " kills")
-- The delayed room channel may carry the same event again. Tick identity keeps
-- that second copy from printing twice when a pilot has just sat out.
wt.cb(nil, {event = webtransport.EVENT_MESSAGE, message = remote_kill})
wt.cb(nil, {event = webtransport.EVENT_MESSAGE, message = my_kill})
wt.cb(nil, {event = webtransport.EVENT_MESSAGE, message = my_death})
wt.cb(nil, {event = webtransport.EVENT_MESSAGE, message = my_assist})
wt.cb(nil, {event = webtransport.EVENT_MESSAGE, message = charge})
check("combat news is idempotent",
      #net.kills == 4 and #net.charge_events == 1)

-- A pack the core refuses has not happened. It is not counted, and the client
-- reports that this build cannot read the zone rather than calling a broken
-- connection healthy.
reject_snapshot = true
wt.cb(nil, {event = webtransport.EVENT_MESSAGE, message = snapshot(3, 9000)})
check("a rejected snapshot is not counted", net.stats.snaps == 3,
      "applied " .. net.stats.snaps)
check("and ends the unreadable connection", not net.connected
      and lost_reason == "the zone sent a snapshot this client cannot read",
      tostring(lost_reason))

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
            message = welcome(3)})
wt.cb(nil, {event = webtransport.EVENT_MESSAGE, message = snapshot(3, 5001)})
check("and the first one after it is", net.stats.snaps == 1)

-- --- the guard covers a watcher too -----------------------------------------
--
-- The shared channel runs seconds behind live, so a view change may move the
-- clock backwards on purpose. Its lifecycle says that happened. Within one
-- life, every backward packet is stale and cannot revive a dead hull.

net = fresh_net()
net.connect("wss://zone/a1", 0, "pilot", function() end, "chaos", true,
            "https://zone:9443")
wt.cb(nil, {event = webtransport.EVENT_CONNECTED})
-- A welcome seating nobody: 255 is the watcher's seat.
wt.cb(nil, {event = webtransport.EVENT_MESSAGE,
            message = welcome(255)})
check("the watcher is watching", net.watching)
wt.cb(nil, {event = webtransport.EVENT_MESSAGE,
            message = snapshot(3, 5000, nil, nil, true)})
check("a channel snapshot lands", net.stats.snaps == 1,
      "applied " .. net.stats.snaps)
wt.cb(nil, {event = webtransport.EVENT_MESSAGE,
            message = snapshot(3, 4995, nil, nil, true)})
check("a stale one is dropped rather than reviving the dead",
      net.stats.snaps == 1, "applied " .. net.stats.snaps)
wt.cb(nil, {event = webtransport.EVENT_MESSAGE,
            message = snapshot(3, 4000, nil, nil, true)})
check("a large stale rewind is dropped too",
      net.stats.snaps == 1, "applied " .. net.stats.snaps)
wt.cb(nil, {event = webtransport.EVENT_MESSAGE,
            message = snapshot(3, 4000, nil, nil, true, 2)})
check("a newer lifecycle may deliberately rewind the view",
      net.stats.snaps == 2, "applied " .. net.stats.snaps)

-- A transition is stated on every snapshot as well as the reliable welcome.
-- That makes a dropped one-shot transition self-healing without letting a
-- delayed packet from the old life change whether the client flies or watches.
net = fresh_net()
net.connect("wss://zone/a1", 0, "pilot", function() end, "chaos", false,
            "https://zone:9443")
wt.cb(nil, {event = webtransport.EVENT_CONNECTED})
wt.cb(nil, {event = webtransport.EVENT_MESSAGE, message = welcome(3, 1)})
wt.cb(nil, {event = webtransport.EVENT_MESSAGE,
            message = snapshot(3, 5000, nil, nil, false, 1)})
wt.cb(nil, {event = webtransport.EVENT_MESSAGE,
            message = snapshot(3, 5001, nil, nil, true, 1)})
check("one lifecycle cannot change modes",
      net.stats.snaps == 1 and not net.watching)
wt.cb(nil, {event = webtransport.EVENT_MESSAGE,
            message = snapshot(4, 4500, nil, nil, true, 2)})
check("a snapshot repairs a dropped watching welcome",
      net.stats.snaps == 2 and net.watching)
local watching_inputs = #wt.unsent
net.step(0)
check("a repaired watcher does not send ship inputs",
      #wt.unsent == watching_inputs)
wt.cb(nil, {event = webtransport.EVENT_MESSAGE,
            message = snapshot(3, 4600, nil, nil, false, 3)})
local flying_inputs = #wt.unsent
net.step(0)
check("a snapshot repairs a dropped flying welcome",
      net.stats.snaps == 3 and not net.watching
      and #wt.unsent == flying_inputs + 1
      and string.byte(wt.unsent[#wt.unsent], 3) == 3)

-- --- settings and snapshots agree across independent lanes -----------------

net = fresh_net()
settings_applied = 0
net.connect("wss://zone/a1", 0, "pilot", function() end, "chaos", false,
            "https://zone:9443")
wt.cb(nil, {event = webtransport.EVENT_CONNECTED})
wt.cb(nil, {event = webtransport.EVENT_MESSAGE, message = welcome(3, 1, 2)})
wt.cb(nil, {event = webtransport.EVENT_MESSAGE,
            message = snapshot(3, 5000, nil, nil, false, 1, 2)})
check("a snapshot cannot outrun the settings it was simulated with",
      net.stats.snaps == 0)
wt.cb(nil, {event = webtransport.EVENT_MESSAGE,
            message = string.char(10) .. u32le(2) .. "settings"})
wt.cb(nil, {event = webtransport.EVENT_MESSAGE,
            message = string.char(10) .. u32le(1) .. "stale"})
check("a late old settings pack cannot roll tuning backward",
      settings_applied == 1 and net.settings_epoch == 1)
wt.cb(nil, {event = webtransport.EVENT_MESSAGE,
            message = snapshot(3, 5001, nil, nil, false, 1, 2)})
check("the matching snapshot lands after its settings", net.stats.snaps == 1)

-- --- callbacks from the connection that ended are inert --------------------

net = fresh_net()
net.connect("wss://zone/a1", 0, "pilot", function() end, "chaos", false,
            "https://zone:9443")
local stale_cb = wt.cb
net.connect("wss://zone/a2", 0, "pilot", function() end, "war", false,
            "https://zone:9444")
local live_cb = wt.cb
stale_cb(nil, {event = webtransport.EVENT_CONNECTED})
stale_cb(nil, {event = webtransport.EVENT_MESSAGE, message = welcome(3)})
stale_cb(nil, {event = webtransport.EVENT_MESSAGE, message = snapshot(3, 5000)})
check("a previous session cannot write into the new arena",
      not net.connected and net.stats.snaps == 0)
live_cb(nil, {event = webtransport.EVENT_CONNECTED})
live_cb(nil, {event = webtransport.EVENT_MESSAGE, message = welcome(4)})
live_cb(nil, {event = webtransport.EVENT_MESSAGE, message = snapshot(4, 5001)})
check("the current session still lands", net.connected and net.stats.snaps == 1)

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
      and ws.sent[1] == canonical_join)
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
            message = welcome(3)})
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
      and ws.sent[1] == canonical_join)

-- Bytes moving on either lane prove the session is working through a slow
-- map or a large first snapshot. Progress resets the settle clock without
-- pretending the join is complete.
net = fresh_net()
net.connect("wss://zone/a1", 0, "pilot", function() end, "chaos", false,
            "https://zone:9443")
wt.cb(nil, {event = webtransport.EVENT_CONNECTED})
for _ = 1, 4 do net.tick(1) end
wt.cb(nil, {event = webtransport.EVENT_PROGRESS})
for _ = 1, 4 do net.tick(1) end
check("join progress buys time for a slow first world", ws.dialled == 0,
      "dialled " .. ws.dialled)
for _ = 1, 2 do net.tick(1) end
check("progress cannot hide a permanently incomplete join", ws.dialled == 1,
      "dialled " .. ws.dialled)

-- A welcome alone is not deliverance: the wedge that prompted this carried
-- the other half dead, and a session whose datagrams never arrive is a game
-- at snapshot-rate zero. The snapshot is the proof, whichever lane it rode.
net = fresh_net()
net.connect("wss://zone/a1", 0, "pilot", function() end, "chaos", false,
            "https://zone:9443")
wt.cb(nil, {event = webtransport.EVENT_CONNECTED})
wt.cb(nil, {event = webtransport.EVENT_MESSAGE,
            message = welcome(3)})
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
            message = welcome(3)})
wt.cb(nil, {event = webtransport.EVENT_MESSAGE, message = snapshot(3, 5000)})
for _ = 1, 6 do net.tick(1) end
check("one snapshot settles the session", ws.dialled == 0
      and net.stats.wire == "wt", "dialled " .. ws.dialled)

-- --- the pilot a seat wears ---------------------------------------------------
--
-- A join binds the seat to whoever the client was at that moment, and the
-- zone never hears about the identity again: the roster and every kill filed
-- belong to that pilot for the life of the connection. So when the client
-- stops being that pilot -- a login, a reroll, a logout whose fresh guest has
-- landed -- the connection has to say so, and the arena rejoins on its word.

net = fresh_net()
account_stub.account = 7
net.connect("wss://zone/a1", 0, "Nimbus 101", function() end, "chaos", false,
            "https://zone:9443")
check("a fresh join wears the client's own identity",
      not net.identity_moved("Nimbus 101", 7))
check("a reroll moves it", net.identity_moved("Vesper 412", 7))
check("a login moves it whatever the name says",
      net.identity_moved("Nimbus 101", 9))
-- Between a logout and the guest that replaces it the client is briefly
-- nobody, and nobody is not an identity to chase: chasing it would rejoin as
-- an empty name and then rejoin again when the guest landed.
check("the gap between logout and a fresh guest is not a move",
      not net.identity_moved("", 0))
check("but the guest who lands is", net.identity_moved("Talon 88", 8))

-- The join this connection was made with, handed back for the rejoin: the
-- same doors, the same room, the same side of the flying/watching line.
local j = net.last_join()
check("the last join hands back its own doors",
      j.url == "wss://zone/a1" and j.zone == "chaos"
          and j.wt == "https://zone:9443" and j.watch == false,
      j and (tostring(j.url) .. " " .. tostring(j.zone)) or "nil")

-- And the rejoin re-binds: whoever connects is the seat's pilot now.
account_stub.account = 9
net.connect("wss://zone/a1", 0, "Vesper 412", function() end, "chaos", false,
            "https://zone:9443")
check("a rejoin wears the new identity",
      not net.identity_moved("Vesper 412", 9))
account_stub.account = 7

-- --- the quiet clock, on a session that has proven itself --------------------
--
-- A killed arena says nothing over QUIC: the kernel closes a dead process's
-- TCP sockets, so the WebSocket gets its hangup within a second, but a QUIC
-- peer's death is pure silence until the browser's own idle timer gives up,
-- tens of seconds later. A player spends them in a ghost room, every hull
-- coasting and nothing killable. Eight seconds without a snapshot is a dead
-- wire on any network worth playing over, and it is reported rather than
-- redialled: mid-game the seat is gone whichever wire comes next.

net = fresh_net()
why = nil
net.connect("wss://zone/a1", 0, "pilot", function(w) why = w end, "chaos",
            false, "https://zone:9443")
wt.cb(nil, {event = webtransport.EVENT_CONNECTED})
wt.cb(nil, {event = webtransport.EVENT_MESSAGE,
            message = welcome(3)})
wt.cb(nil, {event = webtransport.EVENT_MESSAGE, message = snapshot(3, 5000)})
for _ = 1, 60 do net.tick(0.1) end
check("six quiet seconds are not a verdict", why == nil and net.connected)
wt.cb(nil, {event = webtransport.EVENT_MESSAGE, message = snapshot(3, 5100)})
for _ = 1, 60 do net.tick(0.1) end
check("a snapshot rewinds the quiet clock", why == nil and net.connected)
for _ = 1, 25 do net.tick(0.1) end
check("a proven session that goes silent is reported",
      why == "the zone went quiet" and not net.connected, tostring(why))
check("and reported rather than redialled", ws.dialled == 0,
      "dialled " .. ws.dialled)

-- A tab waking from the background hands the first frame a monster dt, with
-- the queued snapshots right behind it. One frame must never be the whole
-- verdict, however large.
net = fresh_net()
why = nil
net.connect("wss://zone/a1", 0, "pilot", function(w) why = w end, "chaos",
            false, "https://zone:9443")
wt.cb(nil, {event = webtransport.EVENT_CONNECTED})
wt.cb(nil, {event = webtransport.EVENT_MESSAGE,
            message = welcome(3)})
wt.cb(nil, {event = webtransport.EVENT_MESSAGE, message = snapshot(3, 5000)})
net.tick(30)
check("one monster frame is not eight seconds of silence",
      why == nil and net.connected, tostring(why))

-- The socket is silent the same way when a NAT eats it mid-hold, and the
-- clock owes it the same reading.
net = fresh_net()
why = nil
net.connect("wss://zone/a1", 0, "pilot", function(w) why = w end, "chaos",
            false, "")
ws.cb(nil, ws.handle, {event = websocket.EVENT_CONNECTED})
ws.cb(nil, ws.handle, {event = websocket.EVENT_MESSAGE,
            message = welcome(3)})
ws.cb(nil, ws.handle, {event = websocket.EVENT_MESSAGE,
                       message = snapshot(3, 5000)})
for _ = 1, 85 do net.tick(0.1) end
check("a silent socket gets the same verdict",
      why == "the zone went quiet", tostring(why))

-- A session that dies while settling is a loss with a reason, and the clock
-- dies with it rather than redialling over the report.
net = fresh_net()
why = nil
net.connect("wss://zone/a1", 0, "pilot", function(w) why = w end, "chaos",
            false, "https://zone:9443")
wt.cb(nil, {event = webtransport.EVENT_CONNECTED})
wt.cb(nil, {event = webtransport.EVENT_MESSAGE,
            message = welcome(3)})
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
            message = welcome(3)})
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

-- Address parsing can fail before connect returns. The loss callback fires in
-- that same stack, and the false return is what keeps the arena from marking
-- the already-failed join as online again.
local ws_connect = websocket.connect
websocket.connect = function() error("bad address") end
net = fresh_net()
why = nil
local started = net.connect("not a zone", 0, "pilot", function(w) why = w end,
                            "", false, nil)
check("a synchronous dial failure returns false", not started,
      tostring(started))
check("and reports its reason once", why == "that address is not a zone URL",
      tostring(why))
websocket.connect = ws_connect

-- Fifty ticks can still be replayed without throwing away local inputs. The
-- next tick crosses the half-second ceiling and must leave the world alone.
net = fresh_net()
net.connect("wss://zone/a1", 0, "pilot", function() end, "chaos", false,
            "https://zone:9443", 2)
wt.cb(nil, {event = webtransport.EVENT_CONNECTED})
wt.cb(nil, {event = webtransport.EVENT_MESSAGE,
            message = welcome(3, nil, nil, 2)})
wt.cb(nil, {event = webtransport.EVENT_MESSAGE, message = snapshot(3, 7000)})
for _ = 1, 43 do net.step(0) end
wt.cb(nil, {event = webtransport.EVENT_MESSAGE, message = snapshot(3, 7001)})
check("a snapshot exactly half a second behind still replays",
      net.stats.snaps == 2 and net.stats.replay == 50 and tick == 7051,
      "tick " .. tick .. ", replay " .. net.stats.replay)
for _ = 1, 2 do net.step(0) end
local before_ceiling = tick
wt.cb(nil, {event = webtransport.EVENT_MESSAGE, message = snapshot(3, 7002)})
check("a snapshot beyond half a second is discarded",
      net.stats.snaps == 2 and net.stats.snap_stale == 1
      and tick == before_ceiling,
      "tick " .. tick .. ", stale " .. net.stats.snap_stale)

-- A reliable QUIC snapshot stream may finish seconds after the world inside
-- it was current. It cannot be reconciled once the client has predicted past
-- the replay ceiling: applying it would throw away the older inputs and move
-- the ship backward. Give that session a moment to produce something current,
-- then close it normally if it cannot.
net = fresh_net()
why = nil
net.connect("wss://zone/a1", 0, "pilot", function(w) why = w end, "chaos", false,
            "https://zone:9443", 2)
wt.cb(nil, {event = webtransport.EVENT_CONNECTED})
wt.cb(nil, {event = webtransport.EVENT_MESSAGE,
            message = welcome(3, nil, nil, 2)})
wt.cb(nil, {event = webtransport.EVENT_MESSAGE, message = snapshot(3, 7000)})
local disconnects_before_stale = wt.disconnects
for _ = 1, 150 do net.step(0) end
local before_stale = tick
wt.cb(nil, {event = webtransport.EVENT_MESSAGE, message = snapshot(3, 7005)})
check("a snapshot beyond the replay ceiling changes no world state",
      tick == before_stale and net.stats.snaps == 1
      and net.stats.snap_stale == 1,
      "tick " .. tick .. ", snaps " .. net.stats.snaps)
for _ = 1, 11 do net.tick(0.1) end
check("a stale stream gets one second to recover, then disconnects",
      wt.disconnects == disconnects_before_stale + 1 and ws.dialled == 0
      and not net.connected and why == "the snapshot stream stalled",
      tostring(why))
for _ = 1, 6 do net.tick(0.1) end
check("an established stale session never falls back to the socket",
      ws.dialled == 0 and net.transport().kind == nil)

-- Snapshot margin is an observation, not permission to move the simulation
-- clock. Both sides of the old threshold used to add or remove one replay
-- tick here, which moved a coasting ship by exactly one tick of velocity.
net = fresh_net()
net.connect("wss://zone/a1", 0, "pilot", function() end, "chaos", false,
            "https://zone:9443", 2)
wt.cb(nil, {event = webtransport.EVENT_CONNECTED})
wt.cb(nil, {event = webtransport.EVENT_MESSAGE,
            message = welcome(3, nil, nil, 2)})
wt.cb(nil, {event = webtransport.EVENT_MESSAGE, message = snapshot(3, 8000)})
wt.cb(nil, {event = webtransport.EVENT_MESSAGE,
            message = snapshot(3, 8001, 8004, 1)})
check("one low-margin snapshot cannot add a replay tick",
      tick == 8008 and net.stats.replay == 7,
      "tick " .. tick .. ", replay " .. net.stats.replay)
wt.cb(nil, {event = webtransport.EVENT_MESSAGE,
            message = snapshot(3, 8002, 8010, 1)})
check("one high-margin snapshot cannot remove a replay tick",
      tick == 8008 and net.stats.replay == 6,
      "tick " .. tick .. ", replay " .. net.stats.replay)

-- A small correction is evidence only while the same living hull continues
-- across it. File the state around that moment once, outside the gameplay
-- wire, so a later screenshot is not the first record of what happened.
net = fresh_net()
net.connect("wss://zone/a1", 0, "pilot", function() end, "chaos", false,
            "https://zone:9443", 2)
wt.cb(nil, {event = webtransport.EVENT_CONNECTED})
wt.cb(nil, {event = webtransport.EVENT_MESSAGE,
            message = welcome(3, nil, nil, 2)})
for sent = 6000, 6003 do
    wt.cb(nil, {event = webtransport.EVENT_MESSAGE, message = snapshot(3, sent)})
end
net.tick(0.025)
own_x, own_y = 100, 50
own_vx, own_vy, own_repel_ticks, own_repel_speed = 1, -0.5, 0, 0
next_x, next_y = 0, 50
next_vx, next_vy, next_repel_ticks, next_repel_speed = 5, 0.25, 212, 5
smooth_repel_started, smooth_correction_absorbed = true, true
wt.cb(nil, {event = webtransport.EVENT_MESSAGE,
            message = snapshot(3, 6004, 6007, 4294967295)})
check("a fully smoothed authoritative repel files no diagnostic",
      #debug_reports == 0, tostring(#debug_reports))

own_x, next_x = 100, 98
own_vx, own_vy, next_vx, next_vy = 1, -0.5, 5, 0.25
own_repel_ticks, next_repel_ticks = 80, 220
smooth_repel_started, smooth_correction_absorbed = true, false
wt.cb(nil, {event = webtransport.EVENT_MESSAGE,
            message = snapshot(3, 6005, 6008, 4294967295)})
local report = debug_reports[1]
check("a repel that cannot be fully smoothed files a diagnostic",
      #debug_reports == 1 and report and report.kind == "local_correction")
check("the diagnostic captures the correction and its clocks",
      report.correction_px == 2 and report.predicted_x == 100
      and report.reconciled_x == 98 and report.frame_ms == 25
      and report.snapshot_tick == 6005 and report.wire == "wt"
      and report.account == 7 and report.zone == "chaos" and report.room == 2)
check("the diagnostic captures motion, smoothing, clock and repel state",
      report.predicted_vx == 1 and report.predicted_vy == -0.5
      and report.reconciled_vx == 5 and report.reconciled_vy == 0.25
      and report.local_debt_px == 1.5 and report.local_debt_deg == 0.25
      and report.clock_adjust == 0 and report.repel_before_ticks == 80
      and report.repel_before_speed == 5 and report.repel_after_ticks == 220
      and report.repel_after_speed == 5)

own_x, next_x = 100, 98
smooth_repel_started, smooth_correction_absorbed = false, false
wt.cb(nil, {event = webtransport.EVENT_MESSAGE, message = snapshot(3, 6006)})
check("small correction reports have a five-second cooldown",
      #debug_reports == 1, tostring(#debug_reports))
own_x, next_x = 100, 0
wt.cb(nil, {event = webtransport.EVENT_MESSAGE, message = snapshot(3, 6007)})
check("the small-report cooldown does not hide a large correction",
      #debug_reports == 2 and debug_reports[2].correction_px == 100,
      tostring(#debug_reports))

if fails > 0 then os.exit(1) end
print("all fine")
