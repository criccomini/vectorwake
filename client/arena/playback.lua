-- A public match replay. The arena records authoritative checkpoints and the
-- buttons applied after each one; this walks those same bytes through the
-- shared simulation core, so the film is the game rather than a rendering of
-- it made by another implementation.

local M = {}

local alphabet = {}
do
    local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    for i = 1, #chars do alphabet[string.byte(chars, i)] = i - 1 end
end

function M.decode(encoded)
    if type(encoded) ~= "string" then return nil, "missing replay bytes" end
    local out = {}
    local held, bits = 0, 0
    for i = 1, #encoded do
        local value = alphabet[string.byte(encoded, i)]
        if value == nil then return nil, "bad replay bytes" end
        held = held * 64 + value
        bits = bits + 6
        while bits >= 8 do
            bits = bits - 8
            local place = 2 ^ bits
            out[#out + 1] = string.char(math.floor(held / place) % 256)
            held = held % place
        end
    end
    return table.concat(out)
end

local function apply_segment(state, sim, at)
    local segment = state.segments[at]
    if not segment then return false end
    if sim.apply_snapshot(segment.snapshot) ~= 0 then return false end
    state.segment = at
    state.offset = 1
    state.tick = 0
    return true
end

function M.load(payload, sim, net)
    local artifact = type(payload) == "table" and payload.match or nil
    local replay = type(artifact) == "table" and artifact.replay or nil
    if type(replay) ~= "table" or type(replay.segments) ~= "table"
        or #replay.segments == 0 then
        return nil, "this match has no film"
    end
    local map, map_err = M.decode(replay.map)
    local settings, settings_err = M.decode(replay.settings)
    if not map or not settings then return nil, map_err or settings_err end

    local segments = {}
    for _, raw in ipairs(replay.segments) do
        local snapshot, snapshot_err = M.decode(raw.snapshot)
        local frames, frames_err = M.decode(raw.frames)
        if not snapshot or not frames then
            return nil, snapshot_err or frames_err
        end
        segments[#segments + 1] = {
            snapshot = snapshot,
            frames = frames,
            ticks = math.max(0, math.floor(tonumber(raw.ticks) or 0)),
        }
    end

    sim.init(0x5eed)
    if sim.apply_map(map) ~= 0 then return nil, "cannot read replay map" end
    if sim.apply_settings(settings) ~= 0 then
        return nil, "cannot read replay rules"
    end
    local state = {segments = segments, artifact = artifact}
    if not apply_segment(state, sim, 1) then
        return nil, "cannot read replay checkpoint"
    end

    net.pilots, net.ratings, net.watchers = {}, {}, {}
    net.said, net.invited = {}, {}
    net.kills, net.charge_events, net.comings = {}, {}, {}
    local subject = nil
    for _, pilot in ipairs(artifact.pilots or {}) do
        local ship = math.floor(tonumber(pilot.ship) or -1)
        if ship >= 0 and ship < sim.ship_count() then
            net.pilots[ship] = {
                name = pilot.name or ("ship " .. ship),
                ai = pilot.bot == true,
                label = pilot.bot and "bot" or "human",
                house = pilot.bot == true,
                team = tonumber(pilot.team) or 0,
                k = tonumber(pilot.kills) or 0,
                d = tonumber(pilot.deaths) or 0,
                a = tonumber(pilot.assists) or 0,
                p = tonumber(pilot.points) or 0,
                b = 0,
                games = 0,
                tier = "film",
            }
            net.ratings[ship] = 0
            if subject == nil or (net.pilots[subject].ai and not pilot.bot) then
                subject = ship
            end
        end
    end
    if subject == nil then
        for ship = 0, sim.ship_count() - 1 do
            if sim.ship_active(ship) == 1 then subject = ship break end
        end
    end

    net.teams = {}
    for index, name in ipairs(artifact.teams or {}) do
        net.teams[#net.teams + 1] = {
            team = index - 1, public = true, may_join = false,
            humans = 0, bots = 0, name = name,
        }
    end
    local score = {}
    for index, value in ipairs(artifact.score or {}) do score[index - 1] = value end
    net.match = {playing = true, left = 0, score = score, artifact = artifact.id}
    net.zone = payload.zone or "replay"
    net.map_name = artifact.map or ""
    net.room = artifact.room
    net.subject = subject
    net.want = subject or 255
    net.my_team = subject and sim.ship_team(subject) or 255
    net.me = 255
    net.watching = true
    net.on_air = false
    net.banner = "MATCH REPLAY"
    net.stats.wire = "replay"
    net.stats.rtt = 0
    net.map_epoch = net.map_epoch + 1
    net.settings_epoch = net.settings_epoch + 1
    sim.set_mortal(255)
    return state
end

function M.step(state, sim)
    local segment = state.segments[state.segment]
    if state.tick >= segment.ticks or state.offset > #segment.frames then
        local next_segment = state.segment % #state.segments + 1
        if not apply_segment(state, sim, next_segment) then return false end
        segment = state.segments[state.segment]
    end
    local count = string.byte(segment.frames, state.offset)
    if count == nil then return false end
    local offset = state.offset + 1
    local inputs = {}
    for _ = 1, count do
        local ship, lo, hi = string.byte(segment.frames, offset, offset + 2)
        if hi == nil then return false end
        inputs[ship] = lo + hi * 256
        offset = offset + 3
    end
    state.offset = offset
    state.tick = state.tick + 1
    sim.step(inputs)
    return true
end

return M
