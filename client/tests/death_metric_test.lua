-- A predicted remote death is measured without being shown.
--
--     lua5.1 client/tests/death_metric_test.lua

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
local next_active = active
local next_alive = alive
local emit_victim = nil
local predicted_deaths = {}

local function u32(a, b, c, d)
    return (a or 0) + (b or 0) * 256 + (c or 0) * 65536
        + (d or 0) * 16777216
end

_G.sim = {
    tick = function() return tick end,
    replay = function()
        tick = tick + 1
        predicted_deaths = {}
        if emit_victim then
            predicted_deaths[1] = emit_victim
            emit_victim = nil
        end
    end,
    step = function() tick = tick + 1; predicted_deaths = {} end,
    apply_snapshot = function(body)
        tick = u32(string.byte(body, 1, 4))
        active, alive = next_active, next_alive
        predicted_deaths = {}
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
    ship_vel = function() return 0, 0 end,
    ship_x_raw = function() return 0 end,
    ship_y_raw = function() return 0 end,
    ship_heading_raw = function() return 0 end,
    weapon_count = function() return 0 end,
    weapon_at = function() end,
    spec_life = function() return 0 end,
    spec_blast = function() return 0 end,
    predicted_death_count = function() return #predicted_deaths end,
    predicted_death_at = function(i) return predicted_deaths[i + 1] end,
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

net.connect("ws://zone", 0, "pilot", function() end)
handle.cb(nil, handle, {event = websocket.EVENT_CONNECTED})
deliver(string.char(1, 0) .. le32(1) .. le32(0)
    .. string.char(1, 0) .. le32(0))
deliver(snapshot(1000))

emit_victim = 1
net.step(0)
check("a local death conclusion becomes pending",
      net.stats.death_pending == 1 and net.stats.death_confirmed == 0)
check("measurement does not queue a death effect", #net.snap_deaths == 0)

next_active = {[0] = 1, [1] = 1, [2] = 1}
next_alive = {[0] = 1, [1] = 0, [2] = 1}
deliver(snapshot(1001))
check("an authoritative death confirms the prediction",
      net.stats.death_confirmed == 1 and net.stats.death_pending == 0)

emit_victim = 2
net.step(0)
next_alive = {[0] = 1, [1] = 0, [2] = 1}
local reject_at = tick
for authoritative_tick = reject_at, reject_at + 5 do
    deliver(snapshot(authoritative_tick))
end
check("six living snapshots reject the prediction",
      net.stats.death_rejected == 1 and net.stats.death_pending == 0)

emit_victim = 2
net.step(0)
next_active = {[0] = 1, [1] = 1, [2] = 0}
next_alive = {[0] = 1, [1] = 0, [2] = 0}
deliver(snapshot(tick))
check("a hull leaving sight is excluded rather than rejected",
      net.stats.death_censored == 1 and net.stats.death_rejected == 1
          and net.stats.death_pending == 0)

if fails > 0 then os.exit(1) end
print("all fine")
