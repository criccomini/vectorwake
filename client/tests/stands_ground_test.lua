-- The settings that follow a map are that map's, whatever generation they
-- name.
--
--     lua5.1 client/tests/stands_ground_test.lua
--
-- An older generation on its own still cannot roll the tuning backward;
-- wire_test pins that. Behind a map it is the zone handing a pilot who just
-- sat out the copy the stands are holding, five seconds behind the room, next
-- to the ground it belongs to. This used to be refused as stale while the map
-- beside it had already gone in, and a whistle inside those five seconds left
-- the client on the old ground under the new generation: every frame the
-- stands then served carried the old one and was refused, and a seat taken
-- back inside the window was flown on the wrong walls for a match.

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

local calls = {apply = 0, settings = 0, maps = 0}
local tick = 1000

_G.sim = {
    tick = function() return tick end,
    replay = function() tick = tick + 1 end,
    step = function() tick = tick + 1 end,
    apply_snapshot = function() calls.apply = calls.apply + 1; return 0 end,
    apply_settings = function() calls.settings = calls.settings + 1; return 0 end,
    apply_map = function() calls.maps = calls.maps + 1; return 0 end,
    smooth_capture = function() end,
    smooth_settle = function() end,
    smooth_reset = function() end,
    set_mortal = function() end,
    ship_count = function() return 2 end,
    ship_alive = function() return 1 end,
    ship_deaths = function() return 0 end,
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
    send = function() end,
}

package.loaded["arena.account"] = {token = nil}

local net = require("arena.net")

local function deliver(s)
    handle.cb(nil, handle, {event = websocket.EVENT_MESSAGE, message = s})
end

local function le32(v)
    return string.char(v % 256, math.floor(v / 256) % 256,
                       math.floor(v / 65536) % 256,
                       math.floor(v / 16777216) % 256)
end

local S2C_SNAPSHOT, S2C_MAP, S2C_SETTINGS = 2, 9, 10

local function welcome(subject, lifecycle)
    return string.char(1, subject) .. le32(lifecycle) .. le32(0)
        .. string.char(1, 0) .. le32(0) .. string.char(0)
end

local function settings(generation)
    return string.char(S2C_SETTINGS) .. le32(generation) .. "rules"
end

local snapshot_seq = 0
local function snapshot(subject, at, watching, lifecycle, generation)
    snapshot_seq = snapshot_seq + 1
    return string.char(S2C_SNAPSHOT, subject, watching and 1 or 0)
        .. le32(lifecycle) .. le32(generation) .. le32(0) .. le32(0)
        .. le32(snapshot_seq) .. string.rep("\0", 9) .. le32(at) .. "body"
end

-- --- a pilot handed the new match's rules, then the stands' copy ------------

net.connect("ws://zone", 0, "pilot", function() end)
handle.cb(nil, handle, {event = websocket.EVENT_CONNECTED})
deliver(string.char(S2C_MAP) .. "ground")
deliver(settings(1))
deliver(welcome(3, 1))
deliver(snapshot(3, 1000, false, 1, 1))
check("a frame under the generation held is applied", calls.apply == 1)

-- The whistle: the room sends the next map and its generation straight to
-- every hull.
deliver(string.char(S2C_MAP) .. "next ground")
deliver(settings(2))
check("the new rules went in", calls.settings == 2)
deliver(snapshot(3, 1001, false, 1, 1))
check("and a frame packed under the old ones is refused", calls.apply == 1)
deliver(snapshot(3, 1002, false, 1, 2))
check("while one under the new ones lands", calls.apply == 2)
deliver(settings(1))
check("an old pack on its own is still refused", calls.settings == 2)

-- Sitting out inside the window: the zone hands over what the stands are
-- being shown, which is the last match's ground and the last match's rules.
deliver(welcome(255, 2))
deliver(string.char(S2C_MAP) .. "ground")
local epochs = net.map_epoch
deliver(settings(1))
check("the stands' rules go in beside the stands' map",
      calls.settings == 3, "applied " .. calls.settings)
check("the map went in first", net.map_epoch == epochs and calls.maps == 3)
deliver(snapshot(1, 1003, true, 2, 1))
check("so the frames the stands are served are read",
      calls.apply == 3, "applied " .. calls.apply)

-- Then the channel catches up, and the frames packed under the new rules
-- follow the rules themselves.
deliver(string.char(S2C_MAP) .. "next ground")
deliver(settings(2))
deliver(snapshot(1, 1004, true, 2, 2))
check("and the new ground reads again once the stands reach it",
      calls.apply == 4, "applied " .. calls.apply)

if fails > 0 then
    print(fails .. " failing")
    os.exit(1)
end
print("all passing")
