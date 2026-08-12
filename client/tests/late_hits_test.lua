-- The rollback's news reaches the drawing, and its reruns do not. This
-- drives net.lua through snapshots whose replay relives ticks the free-run
-- already stepped, which is every rollback, and checks both roads:
--
--     lua5.1 client/tests/late_hits_test.lua
--
-- A hit the free-run already reported is not reported again, however many
-- rollbacks relive its tick. A hit that only ever happens inside a rollback,
-- because the round that lands it arrived in a snapshot after the free-run
-- had passed the crossing tick, queues on `snap_hits` exactly once. And a
-- blast that only happens inside a rollback queues on `snap_blasts` with
-- the event's own position unpacked.

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

-- --- the world, scripted per tick -------------------------------------------

local tick = 1000
-- Events the simulation reports for a tick, whichever step lives it: the
-- free-run first, then every rollback that walks across it again.
local events = {}
-- The tick a snapshot hands the world when it is applied.
local apply_tick = nil

local EV_HIT, EV_EXPIRE = 3, 4

_G.sim = {
    EV_HIT = EV_HIT,
    EV_EXPIRE = EV_EXPIRE,
    tick = function() return tick end,
    replay = function() tick = tick + 1 end,
    step = function() tick = tick + 1 end,
    apply_snapshot = function()
        tick = apply_tick
        return 0
    end,
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
    spec_life = function() return 100 end,
    spec_blast = function(spec) return spec == 7 and 40 or 0 end,
    spec_still = function() return false end,
    event_count = function() return #(events[tick] or {}) end,
    event_at = function(i)
        local e = events[tick][i + 1]
        return e[1], e[2], e[3], e[4]
    end,
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

local function le32(n)
    return string.char(n % 256, math.floor(n / 256) % 256,
                       math.floor(n / 65536) % 256,
                       math.floor(n / 16777216) % 256)
end

-- Steered into the dead band: acked two ticks ahead of the pack keeps the
-- clock exactly where it is, so the replay window is the only thing moving.
local function snapshot(sent)
    deliver(string.char(2, 0) .. le32(sent + 2) .. le32(sent) .. "body")
end

net.connect("ws://zone", 0, "pilot", function() end)
handle.cb(nil, handle, {event = websocket.EVENT_CONNECTED})
deliver(string.char(1, 0, 0, 0, 0, 0))

apply_tick = 5000
snapshot(5000)
check("the first snapshot lands", net.stats.snaps == 1)

-- Five free-run ticks, with a hit reported on the third. The live event is
-- the drawing's to take from the buffer; nothing may queue.
events[5003] = {{EV_HIT, 0, 1, 50}}
for _ = 1, 5 do net.step(0) end
check("the free-run queues nothing", #net.snap_hits == 0)

-- A rollback relives tick 5003 and its hit is reported to it again. The
-- ledger knows the drawing has had it.
apply_tick = 5001
snapshot(5001)
check("a relived hit is a rerun, not news", #net.snap_hits == 0,
      tostring(#net.snap_hits))

-- A round this client had not seen crossed the hull on tick 5004, which the
-- free-run stepped before the round existed. The rollback is the only place
-- the crossing ever happens, and it is news exactly once, however many
-- rollbacks walk across it.
events[5004] = {{EV_HIT, 0, 2, 75}}
apply_tick = 5002
snapshot(5002)
check("a hit lived only in rollback queues", #net.snap_hits == 1,
      tostring(#net.snap_hits))
check("naming the hull and the damage", net.snap_hits[1].ship == 0
      and net.snap_hits[1].dmg == 75)
apply_tick = 5003
snapshot(5003)
check("and the next rollback does not queue it again",
      #net.snap_hits == 1, tostring(#net.snap_hits))

-- A blast lived only in rollback: an arriving bomb ending on a wall the
-- free-run had already flown past. The event's packed word carries the
-- position and the rung, and the queue entry reads like a captured round.
local blasts0 = #net.snap_blasts
events[5005] = {{EV_EXPIRE, 7, 255,
                 2 * 268435456 + 100 * 16384 + 200}}
apply_tick = 5004
snapshot(5004)
check("a blast lived only in rollback queues",
      #net.snap_blasts == blasts0 + 1, tostring(#net.snap_blasts))
local b = net.snap_blasts[#net.snap_blasts]
check("with the event's own position and rung",
      b.x == 100 and b.y == 200 and b.spec == 7 and b.level == 2)

if fails > 0 then os.exit(1) end
print("all fine")
