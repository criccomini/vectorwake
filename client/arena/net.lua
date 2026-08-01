-- Networking for the Defold client.
--
-- The same contract the web prototype proved out: this client sends buttons,
-- predicts its own ship forward from the last snapshot, and accepts every
-- correction the server sends. It decides no hit, no death, no pickup.
--
-- Snapshots are decoded by the simulation core's own unpacker, so the client
-- and the server cannot disagree about what a snapshot means.

local M = {}

local C2S_JOIN, C2S_INPUT, C2S_DUEL = 1, 2, 3
local S2C_WELCOME, S2C_SNAPSHOT, S2C_ROSTER = 1, 2, 3
local S2C_KILL, S2C_BANNER, S2C_ZONE, S2C_DENIED = 4, 5, 6, 7

M.connected = false
M.me = 0
M.banner = ""
M.zone = ""
M.denied = nil
M.pilots = {}
M.ratings = {}
M.stats = {snaps = 0, err = 0, err_max = 0, rewind = 0}

local conn = nil
local input_log = {}
local predicted_tick = 0

local function u16(a, b) return a + b * 256 end
local function u32(a, b, c, d) return a + b * 256 + c * 65536 + d * 16777216 end
local function i16(a, b)
    local v = u16(a, b)
    if v >= 32768 then v = v - 65536 end
    return v
end

local function on_roster(s)
    local n = string.byte(s, 2)
    local o = 3
    M.pilots = {}
    for _ = 1, n do
        local ship = string.byte(s, o)
        local is_ai = string.byte(s, o + 1) == 1
        local rating = i16(string.byte(s, o + 2), string.byte(s, o + 3))
        local len = string.byte(s, o + 4)
        local name = string.sub(s, o + 5, o + 4 + len)
        o = o + 5 + len
        M.pilots[ship] = {name = name, ai = is_ai}
        M.ratings[ship] = rating
    end
end

local function on_snapshot(s)
    -- header: type, our ship, acked input tick
    local body = string.sub(s, 7)
    M.stats.snaps = M.stats.snaps + 1

    local px, py = sim.ship_x(M.me), sim.ship_y(M.me)
    if sim.apply_snapshot(body) ~= 0 then return end

    -- Replay the inputs the server had not applied when it sent this.
    local from = sim.tick()
    local steps = 0
    for t = from + 1, predicted_tick do
        sim.replay(M.me, input_log[t] or 0)
        steps = steps + 1
    end
    if steps > M.stats.rewind then M.stats.rewind = steps end

    local dx, dy = sim.ship_x(M.me) - px, sim.ship_y(M.me) - py
    local err = math.sqrt(dx * dx + dy * dy)
    M.stats.err = err
    -- The first snapshots after joining are a teleport, not a misprediction.
    if M.stats.snaps > 3 and err > M.stats.err_max then M.stats.err_max = err end

    for t in pairs(input_log) do
        if t < from - 400 then input_log[t] = nil end
    end
    predicted_tick = sim.tick()
end

local function on_message(s)
    local kind = string.byte(s, 1)
    if kind == S2C_WELCOME then
        M.me = string.byte(s, 2)
        M.connected = true
    elseif kind == S2C_SNAPSHOT then
        on_snapshot(s)
    elseif kind == S2C_ROSTER then
        on_roster(s)
    elseif kind == S2C_BANNER then
        M.banner = string.sub(s, 2)
    elseif kind == S2C_ZONE then
        M.zone = string.sub(s, 2)
    elseif kind == S2C_DENIED then
        M.denied = string.sub(s, 2)
    end
end

function M.connect(url, class, name)
    M.denied = nil
    conn = websocket.connect(url, {}, function(self, cid, data)
        if data.event == websocket.EVENT_CONNECTED then
            local msg = string.char(C2S_JOIN, class) .. name
            websocket.send(conn, msg, {type = websocket.DATA_TYPE_BINARY})
        elseif data.event == websocket.EVENT_MESSAGE then
            on_message(data.message)
        elseif data.event == websocket.EVENT_DISCONNECTED
            or data.event == websocket.EVENT_ERROR then
            M.connected = false
            conn = nil
        end
    end)
end

function M.request_duel(class, name)
    if not conn then return end
    local msg = string.char(C2S_DUEL, class) .. name
    websocket.send(conn, msg, {type = websocket.DATA_TYPE_BINARY})
    M.pilots = {}
    M.ratings = {}
    M.stats = {snaps = 0, err = 0, err_max = 0, rewind = 0}
end

-- One predicted tick. Returns true when the caller should not step locally,
-- which is to say whenever the server owns this arena.
function M.step(buttons)
    if not M.connected or not conn then return false end
    -- The welcome arrives before the first snapshot. Until one lands there is
    -- no ship to predict, so hold the frame rather than step an empty world.
    if M.stats.snaps == 0 then return true end
    predicted_tick = sim.tick() + 1
    input_log[predicted_tick] = buttons
    local t = predicted_tick
    local msg = string.char(
        C2S_INPUT,
        buttons % 256, math.floor(buttons / 256) % 256,
        t % 256, math.floor(t / 256) % 256,
        math.floor(t / 65536) % 256, math.floor(t / 16777216) % 256)
    websocket.send(conn, msg, {type = websocket.DATA_TYPE_BINARY})
    sim.replay(M.me, buttons)
    return true
end

function M.disconnect()
    if conn then websocket.disconnect(conn) end
    conn = nil
    M.connected = false
end

return M
