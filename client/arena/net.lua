-- Networking for the Defold client.
--
-- The same contract the web prototype proved out: this client sends buttons,
-- predicts its own ship forward from the last snapshot, and accepts every
-- correction the server sends. It decides no hit, no death, no pickup.
--
-- Snapshots are decoded by the simulation core's own unpacker, so the client
-- and the server cannot disagree about what a snapshot means.

local account = require("arena.account")
local codec = require("arena.net_codec")
local reconcile = require("arena.net_reconcile")
local net_transport = require("arena.net_transport")

local u16, u32 = codec.u16, codec.u32
local i16, i32 = codec.i16, codec.i32
local put_u32, byte_or_zero = codec.put_u32, codec.byte_or_zero
local u32n = reconcile.u32n
local serial_after = reconcile.serial_after
local serial_at_or_before = reconcile.serial_at_or_before
local serial_delta = reconcile.serial_delta
local next_tick, previous_tick = reconcile.next_tick, reconcile.previous_tick
local receipt_bit = reconcile.receipt_bit

local M = {}
local transport = net_transport.new()

local C2S_JOIN, C2S_INPUT = 1, 2
local C2S_SHIP = 5
local C2S_TEAM, C2S_FOUND, C2S_INVITE = 6, 7, 8
-- Whose eyes to borrow. From a player it means sit out; from a watcher, look
-- somewhere else. A request like the team asks: the subject byte of the next
-- snapshot is the answer, and an unlawful ask lands on the room channel.
local C2S_WATCH = 9
-- Ride a teammate as a gunner, or 255 to get off. A request like the rest:
-- the core decides, and the answer is the carrier byte of the next snapshot.
local C2S_ATTACH = 10
-- The one flag a player sets in a join: this client came to watch, not to
-- fly. The class byte is ignored, no ship is spawned, and the seat taken is a
-- watcher's. The other bit is JOIN_BOT, which a player never sets.
local JOIN_WATCH = 2
local S2C_WELCOME, S2C_SNAPSHOT, S2C_ROSTER = 1, 2, 3
local S2C_KILL, S2C_BANNER, S2C_ZONE, S2C_DENIED = 4, 5, 6, 7
local S2C_MAP, S2C_SETTINGS, S2C_YIELD, S2C_TEAMS = 9, 10, 11, 12
-- You are the room channel's subject, or you have stopped being it. The
-- channel's camera picks you without asking, so being told is the one
-- courtesy it owes: two minutes on air is something a pilot can play around.
local S2C_ONAIR = 13
local S2C_PRIZE, S2C_CHARGE = 14, 15
local S2C_LAG = 16

-- The client wire's own version, checked by the zone before it reads anything
-- else in a join. A stale build is told its build is stale rather than left to
-- misparse snapshots.
local CLIENT_PROTOCOL = 15
-- Published, because the about page says what this build talks, and a second
-- copy of the number is a second thing to forget to bump.
M.PROTOCOL = CLIENT_PROTOCOL

-- Why a join was refused. Three of these mean the address was fine and another
-- instance would have taken us, which is a different thing to tell a player than
-- "stop trying". See the refusal table in docs/architecture/zones-and-arenas.md.
local DENY_FULL, DENY_DRAINING, DENY_WRONG_ZONE = 1, 2, 3
-- Named for the table's sake rather than for this file's: nothing here tests
-- for them, because neither is worth retrying and the generic path already
-- says so. Written down so the numbering is readable next to the three above.
-- luacheck: ignore DENY_BANNED DENY_VERSION DENY_RATED_SESSION
local DENY_BANNED, DENY_VERSION, DENY_RATED_SESSION = 4, 5, 6
-- True when picking the same game again would plausibly land somewhere with
-- room. The refusal drops the player back on the games list either way, so
-- this only decides how the reason is worded.
local RETRYABLE = {
    [DENY_FULL] = true, [DENY_DRAINING] = true, [DENY_WRONG_ZONE] = true,
}

M.connected = false
M.me = 0
-- Watching rather than flying. 255 in the welcome is a watcher's ship, and
-- everything below branches on this rather than on `me`, because 255 must
-- never be handed to a `sim.*` accessor: the ships array is narrower than
-- that, and the extension now refuses the read loudly rather than serving
-- whatever memory sits past it.
M.watching = false
-- Whose eyes the last snapshot was: the followed hull, or whoever the room
-- channel is on. 255 when the room is empty and the camera holds the middle.
M.subject = nil
-- The last hull this client asked to follow, 255 for the room channel. The
-- subject alone cannot say which of the two you are on, since the channel is
-- usually pointed at somebody too; asked-for and got, together, can.
M.want = 255
-- Whether this pilot is the channel's subject right now, for the mark that
-- says so.
M.on_air = false
-- Everybody watching this room, by name, from the roster's second section.
M.watchers = {}
M.banner = ""
M.lag_notice = ""
M.zone = ""
-- Which of the zone's rooms this connection was seated in, as the server
-- numbered it in the welcome. Nil on a zone holding one room, and nil until a
-- welcome lands. It is the server's answer rather than the row that was
-- pressed: a room can fill between a list being drawn and a key landing, and
-- what the corner says has to be where we actually are.
M.room = nil
M.denied = nil
M.lost = nil
M.pilots = {}
M.ratings = {}
-- Kills the zone has announced and the arena has not yet turned into feed
-- lines. The feed reads these rather than the local simulation's death
-- events, because prediction re-kills the same victim after every rollback
-- that arrives from before the death: one kill printed once per snapshot.
-- The zone says each death exactly once, to everyone.
M.kills = {}
-- Authoritative prize rolls waiting for the frame that draws their effect and
-- feed line. The prediction core removes a touched green but never rolls it.
M.prizes = {}
-- Public charge actions inside the server's fairness circle. These name the
-- charge that was used, never how many remain in the private inventory.
M.charge_events = {}

-- People arriving and leaving, drained into feed lines the same way. Worked
-- out here by comparing one roster against the last rather than sent, because
-- the roster is already broadcast on every change and a second message saying
-- what changed in it is a second thing to keep in step.
--
-- Names rather than seats. A seat is reused the moment somebody leaves it, so
-- two rosters a tick apart can show the same index holding two different
-- people and no diff at all; and a player who takes a seat or gives one up is
-- moving between the two halves of the same roster rather than arriving or
-- going, which a set of names gets right and a set of seats reports as both
-- at once.
--
-- Bots are excluded. Fifty of them cycling through a room would be the whole
-- feed, and nobody arrives to find out that a bot did.
M.comings = {}
-- Who was here last time, or nil before the first roster of a room. The first
-- one seeds this silently: a player who has just joined does not want the
-- room's whole population announced to them one line at a time, and they do
-- not want to be told that they themselves arrived.
local present = nil

-- Deaths and bomb endings the local simulation never announced, found by
-- comparing the world the client had with the world a snapshot handed it. A
-- snapshot replaces state outright and emits no events, and anything emitted
-- inside the rollback replay is cleared by the next step before anyone reads
-- it. This queue began as a patch for kills the prediction mistimed, 15% of
-- deaths against a server on loopback; since decision 40 it is the road every
-- remote death takes, because prediction is no longer allowed to conclude
-- one. The arena drains these into the same light and noise the events would
-- have made.
M.snap_deaths = {}
M.snap_blasts = {}

-- The sides this room holds, as this client is allowed to see them: the
-- zone's own, the one you are on, and any that has invited you. Each row is
-- {team, name, public, may_join, humans, bots}, in the order the zone scores
-- them. `M.my_team` is the byte you are on and `M.may_found` says whether the
-- found-a-team row is worth drawing.
--
-- Sent whole rather than diffed, and rebuilt whole here, because a room holds
-- a handful of sides and a partial update is a class of bug this file has
-- already paid for once.
M.teams = {}
M.my_team = 0
M.may_found = false

-- Ships this client has sent an invitation to, by ship index. The zone does
-- not report an invitation back, and it does not need to: this is the sender
-- remembering what they asked for, so the button says SENT instead of sitting
-- there looking unpressed. It is not a claim that anybody accepted.
M.invited = {}

-- What the connection is doing, for the debug readout and for the clock
-- steering. `rx` and `tx` are bytes since the socket opened; a rate is the
-- difference between two readings, which the reader takes rather than keeping
-- a second clock here.
local function fresh_stats(wire)
    return {
        snaps = 0, snap_hz = 0, snap_gap_ms = 0, snap_gap_max_ms = 0,
        snap_missed = 0, snap_reordered = 0, snap_stale = 0,
        self_err = 0, self_err_max = 0,
        remote_pos = 0, remote_pos_p95 = 0, remote_pos_max = 0,
        remote_turn = 0, remote_turn_p95 = 0, remote_turn_max = 0,
        smooth_pos = 0, smooth_turn = 0,
        replay = 0, replay_max = 0,
        death_confirmed = 0, death_rejected = 0, death_pending = 0,
        death_censored = 0,
        input_margin = 0, input_holes = 0, rtt = 0, lead = 0,
        server_rtt_ms = 0, jitter_ms = 0,
        down_loss = 0, combat_loss = 0, up_loss = 0,
        lag_state = 0,
        rx = 0, tx = 0, msgs = 0, wire = wire or "ws",
    }
end
M.stats = fresh_stats("ws")

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
local LAG_TARGET, LOSS_TARGET, LAG_SLACK, LEAD_MAX = -4, -7, 3, 40
-- Seed a conservative lead near an ordinary round trip. The first snapshot is
-- not drawn until these idle ticks have been replayed, so startup does not
-- spend its first second speeding up the local clock one snapshot at a time.
local START_LEAD = 8
local INPUT_HISTORY = 4

-- Set when a map arrives, so the arena knows to rebuild terrain it had
-- already decided was static.
M.map_epoch = 0
-- Bumped when the zone's tuning changes, so anything the client cached about
-- what a weapon *is* can be thrown away.
M.settings_epoch = 0
-- The settings generation spoken on the wire. `settings_epoch` above is for
-- local caches; this one orders settings against snapshots from independent
-- WebTransport lanes.
local settings_generation = 0
-- Every move between flying and watching starts another life on this socket.
-- Inputs and snapshots carry the same number, which makes packets from the
-- life that ended harmless after the transition.
local lifecycle = 0
local have_snapshot = false
M.join_progress = 0

local on_lost_cb = nil
local input_log = {}
local receipts = reconcile.new()
-- Each entry is the first remote death the local simulation would have
-- concluded while the authoritative world still had that hull alive. The
-- deathless core leaves the hull on one energy and records a telemetry signal,
-- so this ledger can measure the old decision without changing what anybody
-- sees. Six authoritative observations take about 120 ms in nearby combat and
-- 300 ms on the ordinary lane. A hull that leaves the interest window is
-- censored rather than called wrong because the client no longer knows its fate.
local death_candidates = {}
local DEATH_CONFIRM_SNAPSHOTS = 6

local function note_predicted_deaths()
    -- Lightweight net.lua tests use a counter-only simulation stub. The real
    -- extension always provides this pair, while those tests have no combat
    -- state to measure and can skip the ledger.
    if not sim.predicted_death_count then return end
    for i = 0, sim.predicted_death_count() - 1 do
        local victim = sim.predicted_death_at(i)
        if not death_candidates[victim] then
            death_candidates[victim] = {tick = sim.tick(), observations = 0}
            M.stats.death_pending = M.stats.death_pending + 1
        end
    end
end

local function resolve_predicted_deaths(sent)
    for victim, candidate in pairs(death_candidates) do
        if victim >= sim.ship_count() or sim.ship_active(victim) ~= 1 then
            death_candidates[victim] = nil
            M.stats.death_pending = M.stats.death_pending - 1
            M.stats.death_censored = M.stats.death_censored + 1
        elseif sim.ship_alive(victim) ~= 1 then
            death_candidates[victim] = nil
            M.stats.death_pending = M.stats.death_pending - 1
            M.stats.death_confirmed = M.stats.death_confirmed + 1
        elseif serial_at_or_before(candidate.tick, sent) then
            candidate.observations = candidate.observations + 1
            if candidate.observations >= DEATH_CONFIRM_SNAPSHOTS then
                death_candidates[victim] = nil
                M.stats.death_pending = M.stats.death_pending - 1
                M.stats.death_rejected = M.stats.death_rejected + 1
            end
        end
    end
end
-- The last thing this watcher asked to look at, so the keepalive in `step`
-- repeats the ask rather than quietly resetting a follow to the channel.
-- Declared up here because `connect` resets them and Lua scopes a local from
-- its declaration down: assigned any later, these would be globals.
local watch_want = 255
local keepalive = 0
-- The transport rejects callbacks from a connection this facade has left, so
-- the state below belongs only to the live arena.
-- The last snapshot tick applied, for the reorder guard in `on_snapshot`.
local snap_tick = 0
-- Reliable news and snapshots use independent WebTransport lanes. Hold news
-- until an authoritative snapshot at or beyond its tick has landed, so the
-- feed and effects cannot announce state the picture has not shown.
local pending_kills, pending_charges = {}, {}
local seen_kills, seen_charges = {}, {}
local net_clock, last_snap_at = 0, nil
local SNAP_TICKS = 5
-- Corrections on a continuous local hull are filed for diagnosis. Half a pixel
-- catches the small camera wobble a pilot can feel without turning every
-- fixed-point rounding difference into a report. Small reports get five
-- seconds between them; a jump over the presentation snap threshold keeps a
-- separate one-second lane, so an earlier wobble cannot hide it. The endpoint
-- applies a second bound, but the client should not spend those requests first.
local DEBUG_CORRECTION_PX = 0.5
local DEBUG_LARGE_CORRECTION_PX = 64
local DEBUG_REPORT_MAX = 20
local DEBUG_SMALL_REPORT_MAX = 15
local DEBUG_SMALL_COOLDOWN = 500
local DEBUG_LARGE_COOLDOWN = 100
local debug_reports, debug_small_reports = 0, 0
local last_debug_tick, last_large_debug_tick, last_frame_ms = nil, nil, 0
-- A snapshot further behind than the input history can faithfully replay is
-- stale state, not authority. Half a second is already ten ordinary snapshots
-- or twenty-five combat snapshots. Give QUIC one more second to produce
-- current state, then leave normally rather than moving the seat to a new wire.
local REPLAY_MAX_TICKS = 50
local STALE_RECOVERY_SECONDS = 1
local stale_snapshot_wait = nil
-- The room channel trails live play by five seconds by default. Twenty seconds
-- keeps enough identity to reject that delayed copy without retaining every
-- event for the life of the connection.
local EVENT_MEMORY = 2000
local CORRECTION_SAMPLES = 512
local pos_samples, turn_samples, sample_at = {}, {}, 1

local function sample_correction(pos, turn)
    pos_samples[sample_at], turn_samples[sample_at] = pos, turn
    sample_at = sample_at % CORRECTION_SAMPLES + 1
end

local function percentile(values, q)
    if #values == 0 then return 0 end
    local ordered = {}
    for i, v in ipairs(values) do ordered[i] = v end
    table.sort(ordered)
    return ordered[math.max(1, math.ceil(#ordered * q))]
end

local function record_snapshot(seq)
    M.stats.snap_missed = M.stats.snap_missed
        + receipts:record_snapshot(seq)
end

local function input_received(tick)
    return receipts:input_received(tick)
end

local function lag_telemetry(ping, jitter, down, combat, up, state)
    M.stats.server_rtt_ms = ping
    M.stats.jitter_ms = jitter
    M.stats.down_loss = down
    M.stats.combat_loss = combat
    M.stats.up_loss = up
    M.stats.lag_state = state
    local parts = {}
    if math.floor(state / 4) % 2 == 1 then
        parts[#parts + 1] = "moving to spectator"
    end
    if state % 2 == 1 then
        parts[#parts + 1] = "objectives locked"
    end
    M.lag_notice = #parts > 0
        and ("INPUT STREAM: " .. table.concat(parts, " / ")) or ""
end

local function note_snapshot(sent, seq)
    if seq == 0 and have_snapshot and serial_after(sent, snap_tick) then
        local gap = u32n(sent - snap_tick)
        if gap > SNAP_TICKS then
            M.stats.snap_missed = M.stats.snap_missed
                + math.max(0, math.floor(gap / SNAP_TICKS) - 1)
        end
    end
    if last_snap_at then
        local gap = net_clock - last_snap_at
        M.stats.snap_gap_ms = gap * 1000
        M.stats.snap_gap_max_ms = math.max(M.stats.snap_gap_max_ms, gap * 1000)
        if gap > 0 then
            local hz = 1 / gap
            M.stats.snap_hz = M.stats.snap_hz == 0 and hz
                or M.stats.snap_hz * 0.9 + hz * 0.1
        end
    end
    last_snap_at = net_clock
end

local function send_reliable(msg)
    transport:send_reliable(msg)
end

-- Inputs only. Each datagram carries a short tick-stamped repair window, so it
-- needs no transport retransmission and a fresh packet can replace one lost in
-- flight. On the WebSocket it is the same socket as everything else, which is
-- the problem the datagram exists to solve.
local function send_unreliable(msg)
    transport:send_unreliable(msg)
end

local function send_input_records(records)
    for first = 1, #records, INPUT_HISTORY do
        local count = math.min(INPUT_HISTORY, #records - first + 1)
        local msg = {string.char(C2S_INPUT, count),
                     put_u32(lifecycle), put_u32(receipts.snapshot_ack),
                     put_u32(receipts.snapshot_mask)}
        for at = first, first + count - 1 do
            local record = records[at]
            local buttons = record.buttons
            msg[#msg + 1] = put_u32(record.tick)
            msg[#msg + 1] = string.char(buttons % 256,
                math.floor(buttons / 256) % 256)
        end
        msg = table.concat(msg)
        send_unreliable(msg)
        M.stats.tx = M.stats.tx + #msg
    end
end

-- Reported once, with a reason fit to print, and the connection is over. This
-- lives out here rather than inside `connect` because the decoders need it
-- too: a map or a set of settings this client cannot read is exactly as
-- final as a socket that dropped, and used to set a field nobody read.
-- Put both wires down and forget what the connection was in the middle of.
--
-- One copy, because there are two ways a connection ends -- it failed, or we
-- left -- and they used to hang up in two places that had to be kept
-- identical. Everything here is about the wire itself, so a transport field
-- added to one path and missed on the other is how a ghost session gets left
-- open in the page.
local function hangup()
    transport:hangup()
    M.connected = false
    -- News belonging to the connection that just ended. Undrained kills and
    -- arrivals outlived their socket, and the frame that notices the loss
    -- drains them afterwards against a seat number that has been reset and a
    -- roster that has been emptied.
    M.kills = {}
    M.prizes = {}
    M.charge_events = {}
    pending_kills, pending_charges = {}, {}
    seen_kills, seen_charges = {}, {}
    M.comings = {}
    M.snap_deaths = {}
    M.snap_blasts = {}
end

local function lost(why)
    if M.lost then return end
    M.lost = why
    hangup()
    if on_lost_cb then on_lost_cb(why) end
end
local predicted_tick = 0

-- Visible tiers, matching server/src/rating.rs. Coarse bands mean a pilot is
-- not watching a number twitch after every death.
local TIERS = {
    {1700, "Legend"}, {1350, "Ace"}, {1200, "Lead"},
    {1050, "Wing"}, {-1e9, "Newb"},
}
local PROVISIONAL_GAMES = 10

function M.tier(rating, games)
    if games < PROVISIONAL_GAMES then return "placing" end
    for _, t in ipairs(TIERS) do
        if rating >= t[1] then return t[2] end
    end
    return "Newb"
end

-- Built up beside the live roster and swapped in whole, rather than cleared and
-- refilled in place. Clearing first meant a message that ran out halfway left
-- the board holding however far it got, which was usually nothing, and since the
-- roster arrived once and never again that was the roster for the rest of the
-- session: a scoreboard of "ship 5" with real kills beside it. Keeping the last
-- good one beats keeping part of a bad one.
-- What a seat is, as the zone sees it. Derived from the account rather than
-- asserted by the client, so it is worth showing: a pilot cannot dress a guest
-- as a human by asking to. Unknown is most of the people you meet in their
-- first session, so it reads as "not vouched for" rather than as an accusation.
local LABEL = {[0] = "unknown", [1] = "human", [2] = "bot", [3] = "bot?"}

local function on_roster(s)
    local n = string.byte(s, 2)
    if not n then return end
    local o = 3
    local pilots, ratings = {}, {}
    for _ = 1, n do
        local len = string.byte(s, o + 16)
        -- Seventeen bytes of header, then the name. `string.byte` answers nil
        -- past the end and the arithmetic on it raises, and an error here
        -- surfaces inside a websocket callback where nobody is looking.
        if not len or #s < o + 16 + len then return end
        local ship = string.byte(s, o)
        local label = string.byte(s, o + 1)
        local rating = i16(string.byte(s, o + 2), string.byte(s, o + 3))
        local games = string.byte(s, o + 4)
        pilots[ship] = {
            name = string.sub(s, o + 17, o + 16 + len),
            -- Kept, because everything that used to ask "is this AI" still
            -- wants that answer, and both bot labels are one.
            ai = label == 2 or label == 3,
            label = LABEL[label] or "unknown",
            house = label == 2,
            games = games, tier = M.tier(rating, games),
            -- The score, for a seat the snapshot no longer carries. Snapshots
            -- are filtered to what this client could lawfully see, so a pilot
            -- on the far side of the map is absent from the simulation and
            -- there is nowhere else to read their kills from. The board
            -- prefers the simulation for seats it can see, because this
            -- arrives twice a second and that arrives twenty times.
            team = string.byte(s, o + 5),
            k = u16(string.byte(s, o + 6), string.byte(s, o + 7)),
            d = u16(string.byte(s, o + 8), string.byte(s, o + 9)),
            p = u32(string.byte(s, o + 10), string.byte(s, o + 11),
                    string.byte(s, o + 12), string.byte(s, o + 13)),
            b = u16(string.byte(s, o + 14), string.byte(s, o + 15)),
        }
        ratings[ship] = rating
        o = o + 17 + len
    end
    -- The watchers, after the ships: count, then label and name per row. No
    -- ship index and no rating, since a watcher is not fighting in this room.
    -- Bailing on a short read keeps the ships that already parsed, which is
    -- the roster's own rule.
    local watchers = {}
    local wn = string.byte(s, o)
    if wn then
        o = o + 1
        for _ = 1, wn do
            local len = string.byte(s, o + 1)
            if not len or #s < o + 1 + len then break end
            watchers[#watchers + 1] = {
                label = LABEL[string.byte(s, o)] or "unknown",
                name = string.sub(s, o + 2, o + 1 + len),
            }
            o = o + 2 + len
        end
    end
    M.pilots, M.ratings, M.watchers = pilots, ratings, watchers

    -- Who is in the room, both halves of it, minus the machines.
    local now = {}
    for _, p in pairs(pilots) do
        if not p.ai then now[p.name] = true end
    end
    for _, w in ipairs(watchers) do
        if w.label == "human" then now[w.name] = true end
    end
    if present then
        for name in pairs(now) do
            if not present[name] then
                M.comings[#M.comings + 1] = {name = name, joined = true}
            end
        end
        for name in pairs(present) do
            if not now[name] then
                M.comings[#M.comings + 1] = {name = name, joined = false}
            end
        end
    end
    present = now
end

-- The team list. Walked with a cursor exactly as the roster is, and it bails
-- on a short read for the same reason: `string.byte` answers nil past the end,
-- the arithmetic on nil raises, and an error in here surfaces inside a
-- websocket callback where nothing is watching.
local function on_teams(s)
    local was = M.my_team
    M.my_team = string.byte(s, 2) or 0
    M.may_found = (string.byte(s, 3) or 0) ~= 0
    -- Invitations belong to the side that sent them, so crossing to another
    -- one forgets who you asked. Leaving your own side usually ends it
    -- outright, and the marks would otherwise claim you had already invited
    -- somebody to a team that no longer exists.
    if M.my_team ~= was then M.invited = {} end
    local n = string.byte(s, 4)
    if not n then return end
    local o = 5
    local teams = {}
    for _ = 1, n do
        local len = string.byte(s, o + 5)
        if not len or #s < o + 5 + len then return end
        teams[#teams + 1] = {
            team = string.byte(s, o),
            public = string.byte(s, o + 1) ~= 0,
            may_join = string.byte(s, o + 2) ~= 0,
            humans = string.byte(s, o + 3),
            bots = string.byte(s, o + 4),
            name = string.sub(s, o + 6, o + 5 + len),
        }
        o = o + 6 + len
    end
    M.teams = teams
end

-- What the side you are on is called, for the menu row that says so.
function M.my_team_name()
    for _, t in ipairs(M.teams) do
        if t.team == M.my_team then return t.name end
    end
    return ""
end

-- Whether an invitation from you would mean anything, which is true exactly
-- when your own side is private. The zone refuses one sent from a public side
-- and is right to: everybody may already walk into those, so the message would
-- change nothing. Asked before the button is drawn rather than after it is
-- pressed, so there is no control that quietly does nothing.
function M.may_invite()
    for _, t in ipairs(M.teams) do
        if t.team == M.my_team then return not t.public end
    end
    return false
end

-- A death, with both pilots' rating after the exchange and how many people
-- contributed to it. The zone works this out and sends it on every death, and
-- this client used to have no branch for the message at all: ratings arrived
-- only with a roster, which is sent when somebody joins or leaves, so a pilot
-- fighting for ten minutes was shown the number they had when they walked in.
--
-- The feed's kill lines are drawn from these rather than from the local
-- simulation's death events, which is a correction: prediction runs ahead, a
-- snapshot from before a death revives the victim, and the next predicted ticks
-- kill them again, so one death printed a line per rollback. The zone says each
-- one exactly once.
local function publish_kill(e)
    local victim, killer = e.victim, e.killer
    local vr, kr = e.vr, e.kr
    -- Byte 8 is the contributor count, which nothing here reads yet, and the
    -- payout follows it. Read like every other u16 on the wire rather than
    -- padded with `or 0`: the padding was there for a deploy window against a
    -- zone one image older, and a zone one image older cannot be reached at
    -- all, because the protocol number is checked before a join is answered.
    M.kills[#M.kills + 1] = {victim = victim, killer = killer, paid = e.paid}
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

local function publish_timed_events()
    local waiting = {}
    for _, e in ipairs(pending_kills) do
        if serial_at_or_before(e.tick, snap_tick) then
            publish_kill(e)
        else
            waiting[#waiting + 1] = e
        end
    end
    pending_kills = waiting
    waiting = {}
    for _, e in ipairs(pending_charges) do
        if serial_at_or_before(e.tick, snap_tick) then
            M.charge_events[#M.charge_events + 1] = e
        else
            waiting[#waiting + 1] = e
        end
    end
    pending_charges = waiting
    for key, tick in pairs(seen_kills) do
        if serial_after(snap_tick, tick)
            and u32n(snap_tick - tick) > EVENT_MEMORY then
            seen_kills[key] = nil
        end
    end
    for key, tick in pairs(seen_charges) do
        if serial_after(snap_tick, tick)
            and u32n(snap_tick - tick) > EVENT_MEMORY then
            seen_charges[key] = nil
        end
    end
end

local function on_kill(s)
    if #s < 14 then return end
    local e = {
        victim = string.byte(s, 2), killer = string.byte(s, 3),
        vr = i16(string.byte(s, 4), string.byte(s, 5)),
        kr = i16(string.byte(s, 6), string.byte(s, 7)),
        paid = u16(string.byte(s, 9), string.byte(s, 10)),
        tick = u32(string.byte(s, 11, 14)),
    }
    local key = e.tick .. ":" .. e.victim .. ":" .. e.killer
    if seen_kills[key] then return end
    seen_kills[key] = e.tick
    if serial_at_or_before(e.tick, snap_tick) then publish_kill(e)
    else pending_kills[#pending_kills + 1] = e end
end

local function on_charge(s)
    if #s < 15 then return end
    local e = {
        ship = string.byte(s, 2), slot = string.byte(s, 3),
        x = i32(string.byte(s, 4, 7)) / 256,
        y = i32(string.byte(s, 8, 11)) / 256,
        tick = u32(string.byte(s, 12, 15)),
    }
    local key = e.tick .. ":" .. e.ship .. ":" .. e.slot
    if seen_charges[key] then return end
    seen_charges[key] = e.tick
    if serial_at_or_before(e.tick, snap_tick) then
        M.charge_events[#M.charge_events + 1] = e
    else pending_charges[#pending_charges + 1] = e end
end

-- What names a round on both sides of a snapshot: its owner, its spec and
-- the tick it was fired on, which is the current tick less the life it has
-- already spent. Written once because it has to agree with itself across the
-- unpack, and a formula copied four times is a formula with four chances to
-- be edited three times.
local function born_key(tick, spec, life, owner)
    return owner * 16777216 + spec * 65536
        + (tick - (sim.spec_life(spec) - life)) % 65536
end

-- What the client believes, held across a snapshot that is about to replace
-- it: who was flying, how fast they were going, and every round in the air.
local function capture_world()
    local alive, vx, vy, x, y, heading = {}, {}, {}, {}, {}, {}
    for i = 0, sim.ship_count() - 1 do
        alive[i] = sim.ship_alive(i)
        vx[i], vy[i] = sim.ship_vel(i)
        if alive[i] == 1 and sim.ship_active(i) == 1 then
            x[i], y[i] = sim.ship_x_raw(i), sim.ship_y_raw(i)
            heading[i] = sim.ship_heading_raw(i)
        end
    end
    local flying = {}
    local tick = sim.tick()
    for i = 0, sim.weapon_count() - 1 do
        local wx, wy, spec, _, _, _, life, owner, _, level = sim.weapon_at(i)
        -- The rung rides along for the one blast whose color lives on the
        -- round rather than in the spec table: a mine wears its layer's bomb
        -- rung, and a detonation reconstructed after the fact should flash in
        -- the color the mine sat there in.
        flying[born_key(tick, spec, life, owner)] =
            {x = wx, y = wy, spec = spec, life = life, owner = owner,
             level = level}
    end
    return {alive = alive, vx = vx, vy = vy, x = x, y = y,
            heading = heading, flying = flying}
end

local function measure_remote_corrections(before)
    local pos_max, turn_max = 0, 0
    for i = 0, sim.ship_count() - 1 do
        if i ~= M.me and before.x[i] and sim.ship_active(i) == 1
            and sim.ship_alive(i) == 1 then
            local dx = sim.ship_x_raw(i) - before.x[i]
            local dy = sim.ship_y_raw(i) - before.y[i]
            local pos = math.sqrt(dx * dx + dy * dy)
            local dh = sim.ship_heading_raw(i) - before.heading[i]
            dh = (dh + 32768) % 65536 - 32768
            local turn = math.abs(dh) * 360 / 65536
            pos_max, turn_max = math.max(pos_max, pos), math.max(turn_max, turn)
            sample_correction(pos, turn)
        end
    end
    M.stats.remote_pos, M.stats.remote_turn = pos_max, turn_max
    M.stats.remote_pos_max = math.max(M.stats.remote_pos_max, pos_max)
    M.stats.remote_turn_max = math.max(M.stats.remote_turn_max, turn_max)
    if M.stats.snaps % 20 == 0 then
        M.stats.remote_pos_p95 = percentile(pos_samples, 0.95)
        M.stats.remote_turn_p95 = percentile(turn_samples, 0.95)
    end
end

-- And what the snapshot did without saying so, against that.
--
-- Whoever was flying and is now dead in an occupied seat died without a
-- word; an empty seat is a departure, not a death. The velocity is the one
-- the client was drawing, so the pieces leave along the course the hull was
-- seen on. Every round that was in the air and is not any more, with life
-- left to fly, ended on something: twenty ticks of margin excludes a round
-- the local simulation was about to expire by itself.
local function harvest_world(before)
    for i = 0, sim.ship_count() - 1 do
        if before.alive[i] == 1 and sim.ship_active(i) == 1
            and sim.ship_alive(i) ~= 1 then
            M.snap_deaths[#M.snap_deaths + 1] =
                {ship = i, vx = before.vx[i] or 0, vy = before.vy[i] or 0}
        end
    end
    local flying = before.flying
    local tick = sim.tick()
    for i = 0, sim.weapon_count() - 1 do
        local _, _, spec, _, _, _, life, owner = sim.weapon_at(i)
        flying[born_key(tick, spec, life, owner)] = nil
    end
    -- A mine that vanished did one of two things, and only one of them is an
    -- explosion. An enemy repel turns a mine into a bomb of its rung, and the
    -- repel lives a single tick, so this client never simulates one: the
    -- conversion always lands here, as a mine gone from the world. Reporting
    -- it as a blast made a scattered minefield flash and sound like it had
    -- detonated -- three blasts, no damage, exactly when a repel already has
    -- the player's attention. The bomb the mine became is in the snapshot,
    -- though: same owner, a blast of its own, freshly born, a stone's throw
    -- from where the mine sat. Finding one is what tells a scatter from a
    -- detonation. The radius is generous against jitter, and the cost of a
    -- rare mismatch is one missing flash rather than a false one.
    local born = nil
    for _, w in pairs(flying) do
        if w.life > 20 and sim.spec_blast(w.spec) > 0 then
            local scattered = false
            if sim.spec_still(w.spec) then
                if not born then
                    born = {}
                    for i = 0, sim.weapon_count() - 1 do
                        local x, y, spec, _, _, _, life, owner = sim.weapon_at(i)
                        if sim.spec_blast(spec) > 0 and not sim.spec_still(spec)
                            and sim.spec_life(spec) - life <= 30 then
                            born[#born + 1] = {x = x, y = y, owner = owner}
                        end
                    end
                end
                for _, b in ipairs(born) do
                    if b.owner == w.owner
                        and math.abs(b.x - w.x) < 120
                        and math.abs(b.y - w.y) < 120 then
                        scattered = true
                        break
                    end
                end
            end
            if not scattered then
                M.snap_blasts[#M.snap_blasts + 1] = w
            end
        end
    end
end

-- Said when the core refuses a snapshot, which is the same kind of news as a
-- map or a set of settings this client cannot read: the zone is describing a
-- game this build does not understand. It used to be said to nobody. The
-- refusal returned, the arriving message had already cleared the quiet clock
-- on its way in, and the player kept a connection reported healthy in a room
-- that had stopped updating -- the failure the wire's protocol number is
-- supposed to prevent, wearing the one disguise it cannot catch.
local SNAP_UNREADABLE = "the zone sent a snapshot this client cannot read"

local function adopt_lifecycle(epoch, watching, subject)
    if lifecycle ~= 0 and epoch ~= lifecycle and not serial_after(epoch, lifecycle) then
        return false
    end
    if epoch ~= lifecycle then
        lifecycle = epoch
        input_log = {}
        receipts:reset()
        death_candidates = {}
        M.stats.death_pending = 0
        predicted_tick = 0
        sim.smooth_reset()
        M.stats.input_margin, M.stats.rtt, M.stats.lead = 0, 0, 0
        snap_tick = 0
        have_snapshot = false
    elseif watching ~= M.watching then
        -- One lifecycle cannot describe two presence states. The newer
        -- authoritative snapshot or welcome will carry another generation.
        return false
    end
    M.watching = watching
    M.me = watching and 255 or subject
    sim.set_mortal(M.me)
    if not watching then
        M.subject = nil
        M.on_air = false
    end
    return true
end

local function on_snapshot(s)
    -- Nothing before the welcome. The zone sends the map, the settings and
    -- the welcome on the reliable lane and snapshots beside it, and only TCP
    -- ever made that an order: over WebTransport a snapshot datagram passes
    -- the map still ramping up on the stream, and this used to apply it to a
    -- world with no terrain, no zone settings, and no seat, as ship zero,
    -- which is somebody else. It healed itself when the map landed and left
    -- the misprediction readout holding a stranger's flight.
    if not M.connected then return end

    -- Long enough to hold the header and the body's own tick before any of it
    -- is read as a number. string.byte past the end answers nil, not zero, so
    -- a short message used to raise inside the transport's callback and go on
    -- raising once per arriving snapshot -- the roster and the teams decoders
    -- guard the same way and say why.
    if #s < 36 then return end

    -- header: type, subject, input receipt window, snapshot sequence, server
    -- lag telemetry, then the simulation pack.
    --
    -- The pack's own tick comes first in the body, read before anything is
    -- applied. WebTransport's streams and datagrams can pass each other,
    -- which the socket never could, so a snapshot arriving behind one
    -- already applied is dropped rather than walking the room backwards. A
    -- watcher needs that as much as a pilot does: a stale snapshot there
    -- revives a hull the room has already killed, and the next fresh one
    -- kills it again, so one death draws two explosions.
    local watching = string.byte(s, 3) == 1
    local epoch = u32(string.byte(s, 4), string.byte(s, 5),
                      string.byte(s, 6), string.byte(s, 7))
    if not adopt_lifecycle(epoch, watching, string.byte(s, 2)) then return end
    local first_flying_snapshot = not have_snapshot and not watching
    local settings = u32(string.byte(s, 8), string.byte(s, 9),
                         string.byte(s, 10), string.byte(s, 11))
    if settings ~= settings_generation then return end
    local seq = u32(string.byte(s, 20), string.byte(s, 21),
                    string.byte(s, 22), string.byte(s, 23))
    record_snapshot(seq)
    local sent = u32(string.byte(s, 33), string.byte(s, 34),
                     string.byte(s, 35), string.byte(s, 36))
    if have_snapshot and not serial_after(sent, snap_tick) then
        M.stats.snap_reordered = M.stats.snap_reordered + 1
        return
    end
    -- Oversized WebTransport snapshots ride reliable unidirectional streams.
    -- A stalled stream may finish seconds after the state inside it was true.
    -- Applying it and replaying only the bounded tail is a rewind: build
    -- c4931f4 caught debts of 505 and 290 ticks becoming 572 px and 469 px
    -- jumps. Reject before `apply_snapshot` can mutate the world.
    if not watching and have_snapshot
        and serial_delta(predicted_tick, sent) > REPLAY_MAX_TICKS then
        M.stats.snap_stale = M.stats.snap_stale + 1
        if not stale_snapshot_wait then stale_snapshot_wait = 0 end
        return
    end
    stale_snapshot_wait = nil
    local body = string.sub(s, 33)

    -- Watching. No prediction to reconcile, no clock to steer, no inputs to
    -- replay: capture what the screen asserts, take the truth whole, and let
    -- the smoothing walk the drawing to it, exactly as a remote hull is
    -- already treated while flying. The subject byte is the one thing the
    -- header says that flying never needed: whose eyes these are.
    if M.watching then
        sim.smooth_capture()
        local before = capture_world()
        if sim.apply_snapshot(body) ~= 0 then
            lost(SNAP_UNREADABLE)
            return
        end
        note_snapshot(sent, seq)
        snap_tick = sent
        have_snapshot = true
        M.subject = string.byte(s, 2)
        M.stats.snaps = M.stats.snaps + 1
        transport:prove()
        measure_remote_corrections(before)
        sim.smooth_settle()
        -- Kills and detonations the free-run never lived through still owe
        -- their light and noise; a watcher is here for the explosions.
        harvest_world(before)
        publish_timed_events()
        predicted_tick = sim.tick()
        return
    end
    -- The newest input tick the server has received from us. It rode in this
    -- header from the beginning and was skipped over for as long; it is what
    -- says whether our clock is running early enough for an input to reach the
    -- tick it was stamped for.
    local acked = u32(string.byte(s, 12), string.byte(s, 13),
                      string.byte(s, 14), string.byte(s, 15))
    receipts:set_input(
        acked,
        u32(string.byte(s, 16), string.byte(s, 17),
            string.byte(s, 18), string.byte(s, 19))
    )
    lag_telemetry(
        (string.byte(s, 24) or 0) + (string.byte(s, 25) or 0) * 256,
        (string.byte(s, 26) or 0) + (string.byte(s, 27) or 0) * 256,
        string.byte(s, 28) or 0, string.byte(s, 29) or 0,
        string.byte(s, 30) or 0, string.byte(s, 31) or 0)
    local holes = 0
    for behind = 1, 31 do
        local tick = u32n(receipts.input_ack - behind)
        if serial_after(tick, snap_tick) and input_log[tick]
            and not receipt_bit(receipts.input_mask, behind) then
            holes = holes + 1
        end
    end
    M.stats.input_holes = holes
    -- Raw, not what the screen is showing. This measures how far the
    -- prediction missed by, and a number that has had render smoothing folded
    -- into it measures the smoothing instead.
    local client_tick = sim.tick()
    local px, py = sim.ship_x_raw(M.me), sim.ship_y_raw(M.me)
    local predicted_vx, predicted_vy = sim.ship_vel(M.me)
    local repel_before_ticks, repel_before_speed = 0, 0
    if sim.ship_repel then
        repel_before_ticks, repel_before_speed = sim.ship_repel(M.me)
    end
    local alive_before = sim.ship_alive(M.me) == 1
    local carrier_before = sim.ship_carrier and sim.ship_carrier(M.me) or 255
    -- What the screen is currently asserting about every hull, held across the
    -- correction so the drawing can be walked to the truth rather than cut to
    -- it. See the render section of simcore.cpp.
    sim.smooth_capture()
    -- What the client believes before the truth arrives, for the queues above.
    local before = capture_world()
    if sim.apply_snapshot(body) ~= 0 then
        lost(SNAP_UNREADABLE)
        return
    end
    note_snapshot(sent, seq)
    snap_tick = sent
    have_snapshot = true
    M.stats.snaps = M.stats.snaps + 1
    transport:prove()
    resolve_predicted_deaths(sent)

    -- Replay the inputs the server had not applied when it sent this.
    --
    -- Bounded, because the length of this walk is the difference between two
    -- clocks and nothing checks that they belong to the same zone. Clearing
    -- the log on connect is what makes that true; this is the belt for it. A
    -- second of prediction is already far more than a playable connection
    -- ever needs, and anything past it is a bug rather than latency.
    local from = sim.tick()

    if first_flying_snapshot then
        predicted_tick = from
        local startup = {}
        for _ = 1, START_LEAD do
            predicted_tick = next_tick(predicted_tick)
            input_log[predicted_tick] = 0
            startup[#startup + 1] = {tick = predicted_tick, buttons = 0}
        end
        send_input_records(startup)
        M.stats.lead = START_LEAD
    end

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
    local clock_adjust = 0
    if receipts.input_mask ~= 0 then
        local margin = serial_delta(from, acked)
        M.stats.input_margin = margin
        local target = holes > 0 and LOSS_TARGET or LAG_TARGET
        local lead = serial_delta(predicted_tick, from)
        if margin > target and lead < LEAD_MAX then
            local prior_tick = predicted_tick
            predicted_tick = next_tick(predicted_tick)
            input_log[predicted_tick] = input_log[prior_tick] or 0
            clock_adjust = 1
        elseif margin < target - LAG_SLACK and lead > 0 then
            predicted_tick = previous_tick(predicted_tick)
            clock_adjust = -1
        end
        M.stats.lead = serial_delta(predicted_tick, from)
        -- Lead contains downlink age and the clock offset; margin contains
        -- uplink age minus that offset. Their sum cancels the offset and is the
        -- round trip in simulation ticks.
        M.stats.rtt = math.max(0, M.stats.lead + margin)
    end

    local steps = math.max(0,
        math.min(REPLAY_MAX_TICKS, serial_delta(predicted_tick, from)))
    local t = from
    for _ = 1, steps do
        t = next_tick(t)
        sim.replay(M.me, input_log[t] or 0)
        note_predicted_deaths()
    end
    M.stats.replay = steps
    if steps > M.stats.replay_max then M.stats.replay_max = steps end

    measure_remote_corrections(before)

    -- Everything the snapshot and the replay moved is now owed to the drawing,
    -- which pays it off over the next tenth of a second.
    sim.smooth_settle()

    local local_debt_px, local_debt_deg = 0, 0
    if sim.smooth_debt then
        local_debt_px, local_debt_deg = sim.smooth_debt(M.me)
    end

    harvest_world(before)
    publish_timed_events()

    local reconciled_x, reconciled_y =
        sim.ship_x_raw(M.me), sim.ship_y_raw(M.me)
    local reconciled_vx, reconciled_vy = sim.ship_vel(M.me)
    local repel_after_ticks, repel_after_speed = 0, 0
    if sim.ship_repel then
        repel_after_ticks, repel_after_speed = sim.ship_repel(M.me)
    end
    local dx, dy = reconciled_x - px, reconciled_y - py
    local err = math.sqrt(dx * dx + dy * dy)
    M.stats.self_err = err
    -- The first snapshots after joining are a teleport, not a misprediction.
    if M.stats.snaps > 3 and err > M.stats.self_err_max then
        M.stats.self_err_max = err
    end

    local alive_after = sim.ship_alive(M.me) == 1
    local carrier_after = sim.ship_carrier and sim.ship_carrier(M.me) or 255
    local large = err > DEBUG_LARGE_CORRECTION_PX
    local last_report = last_debug_tick
    if large then last_report = last_large_debug_tick end
    local cooldown = large and DEBUG_LARGE_COOLDOWN or DEBUG_SMALL_COOLDOWN
    local cooled = not last_report
        or (serial_after(from, last_report)
            and u32n(from - last_report) >= cooldown)
    if not first_flying_snapshot and M.stats.snaps > 3
        and err > DEBUG_CORRECTION_PX
        and alive_before and alive_after and carrier_before == carrier_after
        and debug_reports < DEBUG_REPORT_MAX
        and (large or debug_small_reports < DEBUG_SMALL_REPORT_MAX) and cooled
        and account.report_debug then
        debug_reports = debug_reports + 1
        if not large then debug_small_reports = debug_small_reports + 1 end
        last_debug_tick = from
        if large then last_large_debug_tick = from end
        account.report_debug({
            kind = "local_correction",
            account = M.joined and M.joined.account or 0,
            zone = M.zone ~= "" and M.zone
                or (M.joined and M.joined.zone or ""),
            room = M.room,
            wire = M.stats.wire,
            client_tick = client_tick,
            snapshot_tick = from,
            snapshot_seq = seq,
            correction_px = err,
            predicted_x = px,
            predicted_y = py,
            reconciled_x = reconciled_x,
            reconciled_y = reconciled_y,
            predicted_vx = predicted_vx,
            predicted_vy = predicted_vy,
            reconciled_vx = reconciled_vx,
            reconciled_vy = reconciled_vy,
            local_debt_px = local_debt_px,
            local_debt_deg = local_debt_deg,
            clock_adjust = clock_adjust,
            repel_before_ticks = repel_before_ticks,
            repel_before_speed = repel_before_speed,
            repel_after_ticks = repel_after_ticks,
            repel_after_speed = repel_after_speed,
            frame_ms = last_frame_ms,
            snapshot_gap_ms = M.stats.snap_gap_ms,
            input_ack = acked,
            input_mask = receipts.input_mask,
            input_margin = M.stats.input_margin,
            input_lead = M.stats.lead,
            input_holes = M.stats.input_holes,
            alive_before = alive_before,
            alive_after = alive_after,
        })
    end

    for logged_tick in pairs(input_log) do
        if serial_after(from, logged_tick)
                and u32n(from - logged_tick) > 400 then
            input_log[logged_tick] = nil
        end
    end
    predicted_tick = sim.tick()
end

local function on_message(s)
    transport:progress()
    M.stats.rx = M.stats.rx + #s
    M.stats.msgs = M.stats.msgs + 1
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
        if #s < 5 then return end
        local epoch = u32(string.byte(s, 2), string.byte(s, 3),
                          string.byte(s, 4), string.byte(s, 5))
        if settings_generation ~= 0 and epoch ~= settings_generation
            and not serial_after(epoch, settings_generation) then
            return
        end
        if sim.apply_settings(string.sub(s, 6)) ~= 0 then
            lost("the zone sent settings this client cannot read")
        else
            settings_generation = epoch
            M.settings_epoch = M.settings_epoch + 1
        end
    elseif kind == S2C_WELCOME then
        -- Which of this connection's two lives it is in: a ship, or 255 for
        -- watching. Sitting out and flying again arrive as fresh welcomes on
        -- the same socket, so this is also the view switch, and it gets the
        -- reconnect treatment: the input log and the clock lead belong to the
        -- life that ended, and a channel view can move the tick backwards
        -- across the delay, which the rollback machinery must never see.
        if #s < 16 then return end
        local seat = string.byte(s, 2)
        local epoch = u32(string.byte(s, 3), string.byte(s, 4),
                          string.byte(s, 5), string.byte(s, 6))
        if not adopt_lifecycle(epoch, seat == 255, seat) then return end
        -- Which room this is, as the server numbered it. Never what was asked
        -- for: a room can fill between a list being read and a key landing,
        -- and the corner of the screen is the one place that must not be
        -- guessing about where you are.
        local lo, hi = string.byte(s, 11, 12)
        M.room = (lo and hi) and (lo + hi * 256) or nil
        if M.room == 0 then M.room = nil end
        M.connected = true
    elseif kind == S2C_SNAPSHOT then
        on_snapshot(s)
    elseif kind == S2C_KILL then
        on_kill(s)
    elseif kind == S2C_ROSTER then
        on_roster(s)
    elseif kind == S2C_TEAMS then
        on_teams(s)
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
    elseif kind == S2C_ONAIR then
        M.on_air = string.byte(s, 2) == 1
    elseif kind == S2C_PRIZE and #s >= 3 then
        local delta = string.byte(s, 3)
        if delta >= 128 then delta = delta - 256 end
        M.prizes[#M.prizes + 1] = {type = string.byte(s, 2), delta = delta}
    elseif kind == S2C_CHARGE then
        on_charge(s)
    elseif kind == S2C_LAG and #s >= 10 then
        lag_telemetry(
            (string.byte(s, 4) or 0) + (string.byte(s, 5) or 0) * 256,
            (string.byte(s, 6) or 0) + (string.byte(s, 7) or 0) * 256,
            string.byte(s, 8) or 0, string.byte(s, 9) or 0,
            string.byte(s, 10) or 0, string.byte(s, 2) or 0)
    elseif kind == S2C_YIELD then
        -- A bot yields to make room, a watcher leaves with a draining arena,
        -- and a connection beyond the final lag threshold leaves when the
        -- stands are full. A denial sent just before this carries the specific
        -- reason; otherwise the generic one is enough.
        lost(M.denied or "the zone asked for this seat back")
    end
end

-- The join, said the moment a transport opens. One builder for both wires,
-- because the message is the protocol and the transports only carry it.
--
-- Class, protocol, flags, and the room fields, then the game we think we
-- picked, the name, and the account session.
-- An empty zone means "whatever you are running", which is what typing an
-- address directly means.
--
-- The bot bit is never set here: the zone takes a client at its word, and
-- what a declared bot gets is a label on the scoreboard, a seat outside the
-- human cap, and first call to give that seat up. A player wants none of the
-- three. See JOIN_BOT in the server. The watch bit is the ship page's answer
-- carried into the join, so arriving to watch costs no seat and no spawn.
--
-- The session token runs to the end, so the name needs a length of its own.
-- An empty token is a pilot who has never reached the meta-layer, or reached
-- it while it was down, and they fly as a guest rather than being turned
-- away.
-- Anything this message puts in a byte goes through here first.
--
-- string.char raises on a number a byte cannot hold, and every value below
-- arrived from outside: the room and the zone name come off a directory reply,
-- which is checked for being a number and not for being one of these. A reply
-- naming room 300 used to raise inside the transport's connected callback,
-- where the surrounding pcall cannot help because Lua evaluates an argument
-- before the call it is an argument to. The join was never sent and the player
-- watched the ten-second give-up blame the zone for not answering.
local function join_msg()
    local join = transport.join
    -- Cut to what their length bytes can describe, so the header and the
    -- payload cannot disagree. A name too long to say is a join the zone will
    -- refuse and say why, which beats one this client cannot express.
    local want = string.sub(join.zone or "", 1, 255)
    local name = string.sub(join.name, 1, 255)
    local session = account.token or ""
    local flags = join.watch and JOIN_WATCH or 0
    -- The room, when a list was read and one was named, and zero when it was
    -- not, which is every arrival that came through the games list. A request
    -- rather than a demand: the room can fill before this lands, and the
    -- welcome says where we actually ended up.
    return string.char(C2S_JOIN, join.class, CLIENT_PROTOCOL, flags,
                       #want, #name, byte_or_zero(join.room))
        .. want .. name .. session
end

transport:configure({
    join_message = join_msg,
    message = on_message,
    lost = function(reason) lost(M.denied or reason) end,
    progress = function() M.join_progress = M.join_progress + 1 end,
    wire = function(wire) M.stats.wire = wire end,
})

-- Whether the pilot this connection wears is still the pilot the client is.
-- True after a mid-game login, a reroll, or a logout whose fresh guest has
-- landed, and the reading that says the seat belongs to somebody the client
-- has stopped being: the roster shows the old name to everyone, and every
-- kill still credits the old account. An empty name is the moment between a
-- logout and the guest that replaces it, when the client is briefly nobody,
-- and nobody is not an identity to chase.
function M.identity_moved(name, acct)
    if not M.joined or name == "" or name == nil then return false end
    return M.joined.name ~= name or M.joined.account ~= (acct or 0)
end

-- The join this connection was made with, for whoever has to make it again.
-- A copy rather than the table, because the caller feeds it back into
-- `connect`, which resets the original mid-read.
function M.last_join()
    return transport:last_join()
end

-- What is carrying this connection, and what would carry the next one.
--
-- Facts rather than a sentence: the about page composes the words, because
-- wording is that page's business and this file's answers are the same in
-- every language it might use.
--
--   kind     "wt" while a WebTransport session is open, "ws" on a socket,
--            nil when neither is.
--   secure   whether the socket is wss. Not reported for WebTransport,
--            which is QUIC and therefore always encrypted.
--   able     whether this build could dial WebTransport at all: the
--            extension compiled in, and a browser that has the API.
--   refused  this connection's own door was dialled earlier in the session
--            and went unanswered, so this join skipped it. A fact about that
--            address rather than about the session: a zone whose door is
--            down does not say anything about the next zone's.
--   offered  whether *this* connection had a WebTransport address to try.
--            Separate from `refused`, which is a fact about the session:
--            without it, a local arena that advertises no door at all was
--            reported as one whose QUIC went unanswered, which blames the
--            network for an address nobody ever gave.
--   tried    whether this connection dialled QUIC, as opposed to skipping it
--            on the strength of an earlier failure this session. Both end up
--            on the socket for the same stated reason, and they are not the
--            same fact: one is a handshake the network ate just now, the
--            other is a handshake nobody sent.
--   reason   what the browser said when the dial failed, if it said anything.
--            A dial that times out has nothing to report and leaves this nil,
--            which is itself the useful reading: silence means the packets
--            went out and none came back.
--   trying   a dial is in the air and its three seconds are running.
function M.transport()
    return transport:info()
end

-- The WebTransport dial's clock. Called every frame whether or not anything
-- is connected, because a blocked UDP path raises no event to time out on:
-- the browser would notice on its own tens of seconds later, and a player
-- staring at "joining" for that long has already given up.
function M.tick(dt)
    last_frame_ms = math.max(0, dt * 1000)
    net_clock = net_clock + dt
    transport:tick(dt, M.connected)
    if stale_snapshot_wait and transport:is_webtransport() then
        -- A resume frame may carry several seconds in one dt. Count at most a
        -- tenth so the recovery window is real time after the stale stream was
        -- observed, not time the page spent asleep before observing it.
        stale_snapshot_wait = stale_snapshot_wait + math.min(dt, 0.1)
        if stale_snapshot_wait >= STALE_RECOVERY_SECONDS then
            stale_snapshot_wait = nil
            lost("the snapshot stream stalled")
        end
    end
end

-- A connection that never lands, or one that drops, has to be reportable:
-- the player is looking at a start screen they just left, and "nothing
-- happened" is the one thing the client must never say. `on_lost` is called
-- once, with a reason fit to print.
--
-- `wt` is the zone's WebTransport address when the directory offered one,
-- dialled first on builds that can speak it; `url` is the WebSocket that
-- serves everybody else and catches the fallback.
function M.connect(url, class, name, on_lost, zone, watch, wt, room)
    -- Whatever we were in, we are leaving. This module holds one arena's
    -- worth of state and the core holds one arena, so a second connection is
    -- not a second game, it is two servers writing over each other.
    M.disconnect()

    M.denied = nil
    M.deny_code = 0
    M.room = nil
    M.pilots = {}
    M.ratings = {}
    M.kills = {}
    M.prizes = {}
    M.charge_events = {}
    -- Back to knowing nobody, so the next room's first roster seeds rather
    -- than announcing everyone in it as having just walked in.
    M.comings = {}
    present = nil

    M.teams = {}
    M.my_team = 0
    M.may_found = false
    M.invited = {}
    M.snap_deaths = {}
    M.snap_blasts = {}
    -- Built whole rather than cleared field by field, so a field added above
    -- cannot be a field somebody forgot to reset here. The clock offset is
    -- among them and is earned rather than remembered: a new arena's latency
    -- is its own, so the lead starts at nothing and climbs into place over
    -- the first second.
    M.stats = fresh_stats("ws")
    death_candidates = {}
    M.lost = nil
    snap_tick = 0
    lifecycle = 0
    settings_generation = 0
    have_snapshot = false
    M.join_progress = 0
    net_clock, last_snap_at = 0, nil
    pos_samples, turn_samples, sample_at = {}, {}, 1
    -- The zone we came from should not have its name or its banner still on
    -- screen while the next one is being reached.
    M.me = 0
    M.watching = false
    -- Nobody is mortal between rooms. Seat zero above is a placeholder
    -- rather than a pilot, and the next welcome names the real one.
    sim.set_mortal(255)
    M.subject = nil
    M.on_air = false
    M.watchers = {}
    watch_want = 255
    M.want = 255
    keepalive = 0
    M.zone = ""
    M.banner = ""
    M.lag_notice = ""
    -- And its rollback state is worse than useless here, because tick numbers
    -- are per zone. Two arenas that have been up for different lengths of
    -- time are at different ticks, so a log kept across the move is a pile of
    -- inputs filed under a stranger's clock. The replay below walks from the
    -- snapshot's tick up to whatever this said, and against a zone that
    -- happens to be younger that is thousands of extra steps every snapshot,
    -- which a player reads as their ship moving at several times its speed.
    input_log = {}
    receipts:reset()
    predicted_tick = 0
    -- And whatever the drawing was still owed in the last room. An offset is
    -- about a hull in an arena; carried across, it draws the next one beside
    -- itself on arrival.
    sim.smooth_reset()
    on_lost_cb = on_lost
    -- The pilot this seat is about to wear. The zone binds a seat's identity
    -- exactly once, from this join's name and token, and never hears about
    -- either again: the roster, the ratings and every kill filed for the life
    -- of the connection belong to whoever this was at this moment.
    M.joined = {name = name, account = account.account or 0, zone = zone or ""}
    debug_reports, debug_small_reports = 0, 0
    last_debug_tick, last_large_debug_tick, last_frame_ms = nil, nil, 0
    stale_snapshot_wait = nil

    return transport:connect({
        url = url,
        class = class,
        name = name,
        zone = zone,
        watch = watch,
        wt = wt,
        room = room,
    }) and not M.lost
end

-- One predicted tick. Returns true when the caller should not step locally,
-- which is to say whenever the server owns this arena.
-- Ask the zone for a different hull. There is no reply and nothing to
-- predict: the server owns the roster, so the change arrives in the next
-- snapshot or does not arrive at all. The core refuses it unless the pilot is
-- alive and at a full bar, and it refuses the same way on both sides.
-- Everything this client asks a zone for. Requests, all of them: the zone
-- answers with a roster or a team list, and a refusal is that list saying you
-- are still where you were.
local function ask(msg)
    if not M.connected or not transport:has_wire() then return false end
    send_reliable(msg)
    return true
end

function M.set_class(cls)
    return ask(string.char(C2S_SHIP, cls))
end

function M.set_team(team)
    return ask(string.char(C2S_TEAM, team))
end

function M.found_team()
    return ask(string.char(C2S_FOUND))
end

function M.invite(ship)
    if not ask(string.char(C2S_INVITE, ship)) then return false end
    M.invited[ship] = true
    return true
end

-- Climb onto a teammate, or 255 to drop off. Nothing is recorded here the way
-- an invitation is: an invitation vanishes into a team list that does not name
-- the invitee, where this one comes back as state on the hull, so the panel
-- reads the answer off the ship rather than off a note it wrote itself.
function M.attach(ship)
    return ask(string.char(C2S_ATTACH, ship or 255))
end

-- Watch somebody, or 255 for the room channel. From a flying pilot this is
-- sitting out; from a watcher it is looking somewhere else. Either way the
-- next snapshot's subject byte is the answer, and an ask the sight rules
-- refuse lands on the channel rather than erroring.
function M.watch(ship)
    watch_want = ship or 255
    M.want = watch_want
    keepalive = 0
    return ask(string.char(C2S_WATCH, watch_want))
end

-- How often a watcher repeats its ask, in steps. The server drops a socket
-- that says nothing for 45 seconds, because a flying client sends buttons
-- every frame and silence means the network ate it. A watcher has no buttons,
-- so the ask itself is the heartbeat: it repeats what is already true, and
-- the simulation does not move for it. Counted in this client's own steps
-- rather than in ticks, because a channel snapshot can move the tick
-- backwards across the delay.
local WATCH_KEEPALIVE = 3000

function M.release_controls()
    if not M.connected or M.watching or not have_snapshot
        or not transport:has_wire() then
        return false
    end
    local tick = next_tick(predicted_tick)
    predicted_tick = tick
    input_log[tick] = 0
    local msg = table.concat({
        string.char(C2S_INPUT, 1), put_u32(lifecycle),
        put_u32(receipts.snapshot_ack), put_u32(receipts.snapshot_mask),
        put_u32(tick), string.char(0, 0),
    })
    -- Reliable is the release that must arrive. The datagram gives it the
    -- ordinary low-latency path when the browser still has time to flush one
    -- before suspension.
    send_reliable(msg)
    if transport:is_webtransport() then
        send_unreliable(msg)
        M.stats.tx = M.stats.tx + #msg * 2
    else
        M.stats.tx = M.stats.tx + #msg
    end
    return true
end

function M.step(buttons)
    if not M.connected or not transport:has_wire() then return false end
    -- The welcome arrives before the first snapshot. Until one lands there is
    -- no ship to predict, so hold the frame rather than step an empty world.
    if not have_snapshot then return true end
    -- Watching: no input log, no send, no replay of a ship this connection
    -- does not have. The world still steps, with nobody's hands on anything,
    -- because `sim.replay` is the step in this client and skipping it froze
    -- the room into a snapshot-rate slideshow. Stepped with no buttons the
    -- room coasts exactly the way remote hulls already do while flying, and
    -- each snapshot corrects it.
    if M.watching then
        sim.step({})
        keepalive = keepalive + 1
        if keepalive >= WATCH_KEEPALIVE then
            keepalive = 0
            local msg = string.char(C2S_WATCH, watch_want)
            -- Reliable on either wire: this is the socket's proof of life,
            -- and a datagram that vanished would leave the next proof a
            -- minute out with the server's patience running.
            send_reliable(msg)
            M.stats.tx = M.stats.tx + #msg
        end
        return true
    end
    predicted_tick = next_tick(sim.tick())
    input_log[predicted_tick] = buttons
    local t = predicted_tick
    local records = {{tick = t, buttons = buttons}}
    local selected = {[t] = true}

    -- Repair acknowledged holes first, oldest while they can still reach the
    -- authoritative tick. A consecutive history guesses at which datagram was
    -- lost; this reads the server's receipt window and spends bytes on the
    -- missing records themselves.
    for behind = 31, 1, -1 do
        if #records >= INPUT_HISTORY then break end
        local tick = u32n(receipts.input_ack - behind)
        if serial_after(tick, snap_tick) and serial_after(t, tick) then
            if input_log[tick] ~= nil and not input_received(tick) then
                records[#records + 1] = {tick = tick, buttons = input_log[tick]}
                selected[tick] = true
            end
        end
    end

    -- The rest is newest unacknowledged history. Before the next snapshot has
    -- identified a hole this still gives each tick several independent rides.
    local tick = previous_tick(t)
    for _ = 1, 32 do
        if #records >= INPUT_HISTORY then break end
        if not serial_after(tick, snap_tick) then break end
        if not selected[tick] and input_log[tick] ~= nil
            and not input_received(tick) then
            records[#records + 1] = {tick = tick, buttons = input_log[tick]}
            selected[tick] = true
        end
        tick = previous_tick(tick)
    end
    table.sort(records, function(a, b)
        return u32n(t - a.tick) > u32n(t - b.tick)
    end)
    send_input_records(records)
    sim.replay(M.me, buttons)
    note_predicted_deaths()
    return true
end

function M.disconnect()
    -- Bumped whether or not there was a socket, so that anything still in
    -- flight from the last one is stale from here on.
    transport:invalidate()
    hangup()
end

return M
