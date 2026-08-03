-- Networking for the Defold client.
--
-- The same contract the web prototype proved out: this client sends buttons,
-- predicts its own ship forward from the last snapshot, and accepts every
-- correction the server sends. It decides no hit, no death, no pickup.
--
-- Snapshots are decoded by the simulation core's own unpacker, so the client
-- and the server cannot disagree about what a snapshot means.

local M = {}

local C2S_JOIN, C2S_INPUT = 1, 2
local C2S_SHIP = 5
local S2C_WELCOME, S2C_SNAPSHOT, S2C_ROSTER = 1, 2, 3
local S2C_KILL, S2C_BANNER, S2C_ZONE, S2C_DENIED = 4, 5, 6, 7
local S2C_MAP, S2C_SETTINGS = 9, 10

-- The client wire's own version, checked by the zone before it reads anything
-- else in a join. A stale build is told its build is stale rather than left to
-- misparse snapshots.
local CLIENT_PROTOCOL = 1

-- Why a join was refused. Three of these mean the address was fine and another
-- instance would have taken us, which is a different thing to tell a player than
-- "stop trying". See the refusal table in docs/architecture/zones-and-arenas.md.
local DENY_FULL, DENY_DRAINING, DENY_WRONG_ZONE = 1, 2, 3
local DENY_BANNED, DENY_VERSION = 4, 5
-- True when picking the same game again would plausibly land somewhere with
-- room. The refusal drops the player back on the games list either way, so
-- this only decides how the reason is worded.
local RETRYABLE = {
    [DENY_FULL] = true, [DENY_DRAINING] = true, [DENY_WRONG_ZONE] = true,
}

M.connected = false
M.me = 0
M.banner = ""
M.zone = ""
M.denied = nil
M.lost = nil
M.pilots = {}
M.ratings = {}
M.stats = {snaps = 0, err = 0, err_max = 0, rewind = 0, lag = 0, lead = 0}

-- Where this client's clock wants to sit, measured in ticks of input lag: how
-- long after we stamp an input the server is still to reach that tick.
--
-- Negative is the goal. An input that arrives before the tick it belongs to
-- waits in the server's queue and is applied on the same tick we applied it,
-- so both ends agree and there is nothing to correct. Positive means the
-- server ran that tick without us and used whatever we were holding before,
-- which for an acceleration costs a fraction of a pixel and for the safe-zone
-- brake costs a tick of speed every tick it is late.
--
-- Two ticks of margin, with a dead band three wide so a clock that is
-- comfortably early is left alone rather than trimmed every snapshot. The
-- ceiling is what a pathological link is allowed to cost everybody else: the
-- further ahead we run, the longer remote ships coast between snapshots.
local LAG_TARGET, LAG_SLACK, LEAD_MAX = -2, 3, 40

-- Set when a map arrives, so the arena knows to rebuild terrain it had
-- already decided was static.
M.map_epoch = 0
-- Bumped when the zone's tuning changes, so anything the client cached about
-- what a weapon *is* can be thrown away.
M.settings_epoch = 0

local conn = nil
local on_lost_cb = nil
local input_log = {}
-- Which connection this module is listening to.
--
-- One set of state serves whatever is live, and a socket that has been left
-- can still deliver events, so every callback checks its generation against
-- this before touching anything. Leaving one out is what let a player who
-- hopped from one zone to another end up in both: the old socket kept
-- arriving with snapshots of the old arena, the new one arrived with the new,
-- and the client drew whichever had spoken most recently.
local generation = 0

-- Reported once, with a reason fit to print, and the connection is over. This
-- lives out here rather than inside `connect` because the decoders need it
-- too: a map or a set of settings this client cannot read is exactly as
-- final as a socket that dropped, and used to set a field nobody read.
local function lost(why)
    if M.lost then return end
    M.lost = why
    M.connected = false
    conn = nil
    if on_lost_cb then on_lost_cb(why) end
end
local predicted_tick = 0

local function u16(a, b) return a + b * 256 end
local function u32(a, b, c, d) return a + b * 256 + c * 65536 + d * 16777216 end
local function i16(a, b)
    local v = u16(a, b)
    if v >= 32768 then v = v - 65536 end
    return v
end

-- Visible tiers, matching server/src/rating.rs. Coarse bands mean a pilot is
-- not watching a number twitch after every death.
local TIERS = {
    {1700, "Wake"}, {1500, "Shockwave"}, {1350, "Contrail"},
    {1200, "Vector"}, {1050, "Trace"}, {-1e9, "Drift"},
}
local PROVISIONAL_GAMES = 10

function M.tier(rating, games)
    if games < PROVISIONAL_GAMES then return "placing" end
    for _, t in ipairs(TIERS) do
        if rating >= t[1] then return t[2] end
    end
    return "Drift"
end

-- Built up beside the live roster and swapped in whole, rather than cleared and
-- refilled in place. Clearing first meant a message that ran out halfway left
-- the board holding however far it got, which was usually nothing, and since the
-- roster arrived once and never again that was the roster for the rest of the
-- session: a scoreboard of "ship 5" with real kills beside it. Keeping the last
-- good one beats keeping part of a bad one.
local function on_roster(s)
    local n = string.byte(s, 2)
    if not n then return end
    local o = 3
    local pilots, ratings = {}, {}
    for _ = 1, n do
        local len = string.byte(s, o + 5)
        -- Six bytes of header, then the name. `string.byte` answers nil past the
        -- end and the arithmetic on it raises, and an error here surfaces inside
        -- a websocket callback where nobody is looking.
        if not len or #s < o + 5 + len then return end
        local ship = string.byte(s, o)
        local is_ai = string.byte(s, o + 1) == 1
        local rating = i16(string.byte(s, o + 2), string.byte(s, o + 3))
        local games = string.byte(s, o + 4)
        pilots[ship] = {
            name = string.sub(s, o + 6, o + 5 + len), ai = is_ai,
            games = games, tier = M.tier(rating, games),
        }
        ratings[ship] = rating
        o = o + 6 + len
    end
    M.pilots, M.ratings = pilots, ratings
end

-- A death, with both pilots' rating after the exchange and how many people
-- contributed to it. The zone works this out and sends it on every death, and
-- this client used to have no branch for the message at all: ratings arrived
-- only with a roster, which is sent when somebody joins or leaves, so a pilot
-- fighting for ten minutes was shown the number they had when they walked in.
--
-- The feed itself is drawn from local simulation events rather than from here,
-- because the client is already stepping the same core and knows who died.
local function on_kill(s)
    local victim, killer = string.byte(s, 2), string.byte(s, 3)
    local vr = i16(string.byte(s, 4), string.byte(s, 5))
    local kr = i16(string.byte(s, 6), string.byte(s, 7))
    M.ratings[victim] = vr
    M.ratings[killer] = kr
    -- A rated death is a game played, which is what decides whether the number
    -- is shown at all. Counting it here stops a pilot reading "placing" for a
    -- whole session after their tenth.
    for _, ship in ipairs({victim, killer}) do
        local p = M.pilots[ship]
        if p then
            p.games = (p.games or 0) + 1
            p.tier = M.tier(M.ratings[ship], p.games)
        end
    end
end

local function on_snapshot(s)
    -- header: type, our ship, acked input tick
    local body = string.sub(s, 7)
    -- The newest input tick the server has received from us. It rode in this
    -- header from the beginning and was skipped over for as long; it is what
    -- says whether our clock is running early enough for an input to reach the
    -- tick it was stamped for.
    local acked = u32(string.byte(s, 3), string.byte(s, 4),
                      string.byte(s, 5), string.byte(s, 6))
    M.stats.snaps = M.stats.snaps + 1

    local px, py = sim.ship_x(M.me), sim.ship_y(M.me)
    if sim.apply_snapshot(body) ~= 0 then return end

    -- Replay the inputs the server had not applied when it sent this.
    --
    -- Bounded, because the length of this walk is the difference between two
    -- clocks and nothing checks that they belong to the same zone. Clearing
    -- the log on connect is what makes that true; this is the belt for it. A
    -- second of prediction is already far more than a playable connection
    -- ever needs, and anything past it is a bug rather than latency.
    local from = sim.tick()

    -- Steer the clock, one tick per snapshot.
    --
    -- Twenty a second, so a cold start settles in under a second, and small
    -- enough that the clock never jumps. A jump would be its own correction,
    -- which is the thing this exists to remove.
    --
    -- Moving the clock is done by moving the target of the replay below rather
    -- than by stepping anything here: raise it and the walk runs an extra tick,
    -- lower it and it runs one fewer. A tick added past the end of the log
    -- inherits the buttons we were already holding, because a key held through
    -- the gap is what actually happened; filling it with zero would insert a
    -- phantom frame of hands-off flying that the server never saw.
    if acked > 1 then
        local lag = from - acked
        M.stats.lag = lag
        if lag > LAG_TARGET and predicted_tick - from < LEAD_MAX then
            predicted_tick = predicted_tick + 1
            input_log[predicted_tick] = input_log[predicted_tick - 1] or 0
        elseif lag < LAG_TARGET - LAG_SLACK and predicted_tick > from then
            predicted_tick = predicted_tick - 1
        end
        M.stats.lead = predicted_tick - from
    end

    local last = predicted_tick
    if last > from + 100 then last = from + 100 end
    local steps = 0
    for t = from + 1, last do
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
    if kind == S2C_MAP then
        local r = sim.apply_map(string.sub(s, 2))
        if r == 0 then
            M.map_epoch = M.map_epoch + 1
        else
            -- -2 is a hash mismatch, which means the zone and this client
            -- disagree about the room. Better to say so than to spend a match
            -- bouncing off walls nobody else can see.
            lost((r == -2) and "the zone sent a map that did not verify"
                 or "the zone sent a map this client cannot read")
        end
    elseif kind == S2C_SETTINGS then
        -- The zone's numbers, over this client's compiled defaults. Refusing
        -- them would mean predicting a different game, so a message we
        -- cannot read is worth losing the connection over -- the same call
        -- the map makes, for the same reason.
        if sim.apply_settings(string.sub(s, 2)) ~= 0 then
            lost("the zone sent settings this client cannot read")
        else
            M.settings_epoch = M.settings_epoch + 1
        end
    elseif kind == S2C_WELCOME then
        M.me = string.byte(s, 2)
        M.connected = true
    elseif kind == S2C_SNAPSHOT then
        on_snapshot(s)
    elseif kind == S2C_KILL then
        on_kill(s)
    elseif kind == S2C_ROSTER then
        on_roster(s)
    elseif kind == S2C_BANNER then
        M.banner = string.sub(s, 2)
    elseif kind == S2C_ZONE then
        M.zone = string.sub(s, 2)
    elseif kind == S2C_DENIED then
        -- Code first, then the sentence. Reading from byte 2 put the code
        -- itself at the front of the text a player was shown.
        M.deny_code = string.byte(s, 2) or 0
        M.denied = string.sub(s, 3)
        if RETRYABLE[M.deny_code] then
            M.denied = M.denied .. " (another server for this game may have room)"
        end
    end
end

-- A connection that never lands, or one that drops, has to be reportable:
-- the player is looking at a start screen they just left, and "nothing
-- happened" is the one thing the client must never say. `on_lost` is called
-- once, with a reason fit to print.
function M.connect(url, class, name, on_lost, zone)
    -- Whatever we were in, we are leaving. This module holds one arena's
    -- worth of state and the core holds one arena, so a second connection is
    -- not a second game, it is two servers writing over each other.
    M.disconnect()
    local gen = generation

    M.denied = nil
    M.deny_code = 0
    M.pilots = {}
    M.ratings = {}
    M.stats = {snaps = 0, err = 0, err_max = 0, rewind = 0}
    M.lost = nil
    -- The zone we came from should not have its name or its banner still on
    -- screen while the next one is being reached.
    M.me = 0
    M.zone = ""
    M.banner = ""
    -- And its rollback state is worse than useless here, because tick numbers
    -- are per zone. Two arenas that have been up for different lengths of
    -- time are at different ticks, so a log kept across the move is a pile of
    -- inputs filed under a stranger's clock. The replay below walks from the
    -- snapshot's tick up to whatever this said, and against a zone that
    -- happens to be younger that is thousands of extra steps every snapshot,
    -- which a player reads as their ship moving at several times its speed.
    input_log = {}
    predicted_tick = 0
    -- The clock offset is per zone for the same reason the log is, and it is
    -- earned rather than remembered: a new arena's latency is its own, so the
    -- lead starts at nothing and climbs into place over the first second.
    M.stats.lag, M.stats.lead = 0, 0
    on_lost_cb = on_lost

    local ok, err = pcall(function()
        conn = websocket.connect(url, {}, function(self, cid, data)
            -- A socket we have already left. Closing one buys no promise of
            -- silence, and its parting message would otherwise be read as the
            -- live connection dropping, which clears `conn` and takes the
            -- good connection down with the dead one.
            if gen ~= generation then return end
            if data.event == websocket.EVENT_CONNECTED then
                -- class, protocol, then the game we think we picked, then the
                -- name. An empty zone means "whatever you are running", which
                -- is what typing an address directly means.
                local want = zone or ""
                local msg = string.char(C2S_JOIN, class, CLIENT_PROTOCOL, #want)
                    .. want .. name
                -- The callback's own handle, not the module's: this can fire
                -- before `websocket.connect` has returned, and `conn` is only
                -- assigned afterwards.
                --
                -- Guarded, because a socket can be closing by the time its own
                -- connect event is delivered, and the extension raises on a
                -- send to one that is. The disconnect that follows carries the
                -- reason a player should see; a Lua error here would take the
                -- frame loop instead.
                pcall(websocket.send, cid, msg,
                      {type = websocket.DATA_TYPE_BINARY})
            elseif data.event == websocket.EVENT_MESSAGE then
                on_message(data.message)
            elseif data.event == websocket.EVENT_DISCONNECTED then
                lost(M.denied or "the zone closed the connection")
            elseif data.event == websocket.EVENT_ERROR then
                lost(M.denied or (data.message and tostring(data.message))
                     or "could not reach that zone")
            end
        end)
    end)
    -- A malformed address throws here rather than failing asynchronously,
    -- and an unhandled error in init would take the whole client down.
    if not ok then
        lost("that address is not a zone URL")
        return false
    end
    return true
end

-- One predicted tick. Returns true when the caller should not step locally,
-- which is to say whenever the server owns this arena.
-- Ask the zone for a different hull. There is no reply and nothing to
-- predict: the server owns the roster, so the change arrives in the next
-- snapshot or does not arrive at all. The core refuses it unless the pilot is
-- alive and at a full bar, and it refuses the same way on both sides.
function M.set_class(cls)
    if not conn or not M.connected then return false end
    websocket.send(conn, string.char(C2S_SHIP, cls),
                   {type = websocket.DATA_TYPE_BINARY})
    return true
end

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
    -- Bumped whether or not there was a socket, so that anything still in
    -- flight from the last one is stale from here on.
    generation = generation + 1
    if conn then pcall(websocket.disconnect, conn) end
    conn = nil
    M.connected = false
end

return M
