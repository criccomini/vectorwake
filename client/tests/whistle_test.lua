-- A match ending is not eight deaths.
--
--     lua5.1 client/tests/whistle_test.lua
--
-- The whistle benches every hull in the room and sweeps the air: the zone
-- writes the fields rather than taking the death path, so nothing is filed,
-- nothing is paid, and the tallies the podium is about to draw stay where the
-- match left them. All the client sees is a snapshot in which everybody is
-- suddenly down and every round is suddenly gone, which read as a room full
-- of kills and answered with a room full of explosions. What separates the
-- two is the victim's own death count.

package.path = "client/?.lua;" .. package.path

local fails = 0
local function check(name, ok, detail)
    if ok then
        print("ok   " .. name)
    else
        fails = fails + 1
        print("FAIL " .. name .. (detail and ("  " .. detail) or ""))
    end
end

local tick = 1000
local active = {[0] = 1, [1] = 1, [2] = 1}
local alive = {[0] = 1, [1] = 1, [2] = 1}
local deaths = {[0] = 0, [1] = 0, [2] = 0}
local next_active, next_alive, next_deaths = active, alive, deaths

-- What is in the air, as birth ticks. A round is named across a snapshot by
-- when it was fired, which the client works back out of the life it has left,
-- so a round that ages by a tick with the room keeps its name and a round
-- that does not is a different round every time it is looked at.
local BOMB, BOMB_LIFE = 3, 500
local air = {1000}
local next_air = air

local function u32(a, b, c, d)
    return (a or 0) + (b or 0) * 256 + (c or 0) * 65536
        + (d or 0) * 16777216
end

_G.sim = {
    tick = function() return tick end,
    replay = function() tick = tick + 1 end,
    step = function() tick = tick + 1 end,
    apply_snapshot = function(body)
        tick = u32(string.byte(body, 1, 4))
        active, alive, deaths = next_active, next_alive, next_deaths
        air = next_air
        return 0
    end,
    apply_settings = function() return 0 end,
    smooth_capture = function() end,
    smooth_settle = function() end,
    smooth_reset = function() end,
    set_mortal = function() end,
    ship_count = function() return 3 end,
    ship_alive = function(i) return alive[i] or 0 end,
    ship_active = function(i) return active[i] or 0 end,
    ship_deaths = function(i) return deaths[i] or 0 end,
    ship_vel = function() return 0, 0 end,
    ship_x_raw = function() return 0 end,
    ship_y_raw = function() return 0 end,
    ship_heading_raw = function() return 0 end,
    weapon_count = function() return #air end,
    weapon_at = function(i)
        local born = air[i + 1]
        return 100, 100, BOMB, 0, 0, 0, BOMB_LIFE - (tick - born), 0, 0, 0
    end,
    spec_life = function() return BOMB_LIFE end,
    spec_blast = function(spec) return spec == BOMB and 40 or 0 end,
    predicted_death_count = function() return 0 end,
    predicted_death_at = function() end,
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

local function le32(v)
    return string.char(v % 256, math.floor(v / 256) % 256,
                       math.floor(v / 65536) % 256,
                       math.floor(v / 16777216) % 256)
end

local snapshot_seq = 0
local function snapshot(v)
    snapshot_seq = snapshot_seq + 1
    return string.char(2, 0, 0) .. le32(1) .. le32(0) .. le32(0)
        .. le32(0) .. le32(snapshot_seq) .. string.rep("\0", 9)
        .. le32(v) .. "body"
end

local function deliver(message)
    handle.cb(nil, handle, {event = websocket.EVENT_MESSAGE, message = message})
end

-- The frame drains both queues into the drawing every time round; a test
-- reading one has to do the same or it is reading the last snapshot's.
local function drain()
    net.snap_deaths, net.snap_blasts = {}, {}
end

net.connect("ws://zone", 0, "pilot", function() end)
handle.cb(nil, handle, {event = websocket.EVENT_CONNECTED})
deliver(string.char(1, 0) .. le32(1) .. le32(0)
    .. string.char(1, 0) .. le32(0))
deliver(snapshot(1000))
drain()

-- A round in the air stays one round while it flies, rather than being a
-- fresh one on every snapshot and a detonation on every one after that.
deliver(snapshot(1001))
check("a bomb still flying is nothing to draw",
      #net.snap_deaths == 0 and #net.snap_blasts == 0,
      #net.snap_deaths .. " wrecks, " .. #net.snap_blasts .. " blasts")

-- The whistle: every hull down on one snapshot, none of them killed, and the
-- air swept with them.
next_alive = {[0] = 0, [1] = 0, [2] = 0}
next_air = {}
deliver(snapshot(1002))
check("a benched room draws no wrecks", #net.snap_deaths == 0,
      "queued " .. #net.snap_deaths)
check("and the bomb it swept up does not go off", #net.snap_blasts == 0,
      "queued " .. #net.snap_blasts)
drain()

-- The next match: everybody back up, and somebody's bomb in the air again.
next_alive = {[0] = 1, [1] = 1, [2] = 1}
next_air = {1003}
deliver(snapshot(1003))
check("a match opening is not an event either",
      #net.snap_deaths == 0 and #net.snap_blasts == 0)
drain()

-- A kill, which is the same state change with the victim's tally moved, and
-- the bomb that did it landing rather than being swept.
next_alive = {[0] = 1, [1] = 0, [2] = 1}
next_deaths = {[0] = 0, [1] = 1, [2] = 0}
next_air = {}
deliver(snapshot(1004))
check("a killed hull still leaves a wreck", #net.snap_deaths == 1,
      "queued " .. #net.snap_deaths)
check("and it is the one that died",
      net.snap_deaths[1] and net.snap_deaths[1].ship == 1)
check("the round that killed them still lands", #net.snap_blasts == 1,
      "queued " .. #net.snap_blasts)
drain()

-- A bomb only the prediction has fired, which the corrected world then fires
-- a couple of ticks later: the tick a held key fires on hangs on cooldown,
-- energy and the proximity safety, and a snapshot can change any of them.
-- No snapshot ever carried the first birth, so nothing the zone knew about
-- ended, and drawing it put a detonation at the muzzle while the bomb flew
-- on to its real one.
air = {1005}
next_air = {1007}
deliver(snapshot(1010))
check("a bomb reborn under correction does not go off",
      #net.snap_blasts == 0, "queued " .. #net.snap_blasts)
drain()

-- The same when the corrected world refuses the shot altogether: a round
-- the zone never saw cannot have landed on anything.
air = {1012}
next_air = {}
deliver(snapshot(1015))
check("a bomb the correction takes back does not go off",
      #net.snap_blasts == 0, "queued " .. #net.snap_blasts)
drain()

-- But once a snapshot has carried the round, the zone has spoken for it, and
-- its disappearance is a real ending however young it is.
next_air = {1016}
deliver(snapshot(1020))
drain()
next_air = {}
deliver(snapshot(1025))
check("a bomb a snapshot vouched for still lands",
      #net.snap_blasts == 1, "queued " .. #net.snap_blasts)

if fails > 0 then os.exit(1) end
print("all fine")
