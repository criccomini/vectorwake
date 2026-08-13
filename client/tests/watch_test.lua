-- Watching is a second life on the same socket, and this drives net.lua
-- through both of them.
--
--     lua5.1 client/tests/watch_test.lua
--
-- The welcome byte is the switch: a ship number is flying, 255 is watching.
-- What this pins is the shape of each life. Flying steps the core by
-- replaying your own buttons and sends an input per tick; watching sends no
-- inputs at all and *still* steps the core, with nobody's hands on anything,
-- because `sim.replay` is the step in this client and a watcher that skipped
-- it froze the room into a snapshot-rate slideshow. The keepalive is the
-- other promise: a watcher repeats its ask, not 255, or thirty seconds of
-- silence would quietly reset a follow to the channel.

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

local calls = {replay = 0, step = 0, apply = 0}
local tick = 1000

_G.sim = {
    tick = function() return tick end,
    replay = function() calls.replay = calls.replay + 1; tick = tick + 1 end,
    step = function() calls.step = calls.step + 1; tick = tick + 1 end,
    apply_snapshot = function() calls.apply = calls.apply + 1; return 0 end,
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
    ship_heading_raw = function() return 0 end,
    weapon_count = function() return 0 end,
    weapon_at = function() end,
    spec_life = function() return 0 end,
    spec_blast = function() return 0 end,
}

local sent = {}
local handle = nil
_G.websocket = {
    EVENT_CONNECTED = 1,
    EVENT_MESSAGE = 2,
    EVENT_DISCONNECTED = 3,
    EVENT_ERROR = 4,
    DATA_TYPE_BINARY = 1,
    connect = function(url, _, cb)
        handle = {url = url, cb = cb}
        return handle
    end,
    disconnect = function() end,
    send = function(_, data) sent[#sent + 1] = data end,
}

package.loaded["arena.account"] = {token = nil}

local net = require("arena.net")

local function deliver(s)
    handle.cb(nil, handle, {event = websocket.EVENT_MESSAGE, message = s})
end

local function sent_kinds()
    local out = {}
    for _, m in ipairs(sent) do out[#out + 1] = string.byte(m, 1) end
    return table.concat(out, ",")
end

-- --- flying first -----------------------------------------------------------

net.connect("ws://zone", 0, "pilot", function() end)
handle.cb(nil, handle, {event = websocket.EVENT_CONNECTED})
check("the join speaks the wire's own protocol",
      string.byte(sent[1], 3) == net.PROTOCOL,
      "spoke " .. tostring(string.byte(sent[1], 3)))

deliver(string.char(1, 3, 0, 0, 0, 0))
check("a ship in the welcome is flying", net.me == 3 and not net.watching)

-- A snapshot, so `step` stops holding the frame. Header, then a body the
-- stubbed unpacker accepts.
deliver(string.char(2, 3, 0, 0, 0, 0) .. "body")
check("the snapshot landed", net.stats.snaps == 1)

local replays = calls.replay
net.step(0)
check("flying replays your own ship", calls.replay == replays + 1)
check("and sends an input", string.byte(sent[#sent], 1) == 2, sent_kinds())

-- --- sitting out ------------------------------------------------------------

deliver(string.char(1, 255, 0, 0, 0, 0))
check("255 in the welcome is watching", net.watching and net.me == 255)

local before = #sent
replays = calls.replay
local steps = calls.step
net.step(0)
check("watching sends nothing per tick", #sent == before)
check("and never replays a ship it does not have", calls.replay == replays)
check("but the world still steps", calls.step == steps + 1,
      "a watcher that stops stepping is a slideshow")

deliver(string.char(2, 1, 0, 0, 0, 0) .. "body")
check("the subject byte says whose eyes these are", net.subject == 1)
check("and the snapshot was taken whole", calls.apply >= 2)
check("without a rollback replay behind it", calls.replay == replays)

-- The ask, and the keepalive that repeats it.
net.watch(7)
check("an ask goes out as C2S_WATCH", string.byte(sent[#sent], 1) == 9
      and string.byte(sent[#sent], 2) == 7, sent_kinds())
before = #sent
for _ = 1, 3000 do net.step(0) end
check("the keepalive fires on the quiet socket", #sent == before + 1)
check("and repeats the ask rather than resetting it",
      string.byte(sent[#sent], 2) == 7,
      "asked for " .. tostring(string.byte(sent[#sent], 2)))

-- On air, and off again.
deliver(string.char(13, 1))
check("the channel tells its subject", net.on_air)
deliver(string.char(13, 0))
check("and tells them when the camera moves on", not net.on_air)

-- The roster's second section: watchers, by name, after the ships.
-- ship 0, label 1, rating 712, games 3, team 2, then the four score fields
-- the board reads for seats a filtered snapshot leaves out, then the name.
deliver(string.char(3, 1, 0, 1, 200, 2, 3, 2,
                    4, 0, 1, 0, 9, 0, 0, 0, 6, 0, 5) .. "pilot"
        .. string.char(1, 1, 7) .. "gallery")
check("the ships section still parses", net.pilots[0] ~= nil
      and net.pilots[0].name == "pilot")
check("the watcher section names its people", #net.watchers == 1
      and net.watchers[1].name == "gallery",
      tostring(#net.watchers))

-- --- and back in ------------------------------------------------------------

deliver(string.char(1, 4, 0, 0, 0, 0))
check("a ship in the welcome is flying again",
      not net.watching and net.me == 4)
replays = calls.replay
net.step(0)
check("and the input path is back", calls.replay == replays + 1)

if fails > 0 then os.exit(1) end
print("all fine")
