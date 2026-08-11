-- Networking for the Defold client.
--
-- The same contract the web prototype proved out: this client sends buttons,
-- predicts its own ship forward from the last snapshot, and accepts every
-- correction the server sends. It decides no hit, no death, no pickup.
--
-- Snapshots are decoded by the simulation core's own unpacker, so the client
-- and the server cannot disagree about what a snapshot means.

local account = require("arena.account")

local M = {}

local C2S_JOIN, C2S_INPUT = 1, 2
local C2S_SHIP = 5
local C2S_TEAM, C2S_FOUND, C2S_INVITE = 6, 7, 8
-- Whose eyes to borrow. From a player it means sit out; from a watcher, look
-- somewhere else. A request like the team asks: the subject byte of the next
-- snapshot is the answer, and an unlawful ask lands on the room channel.
local C2S_WATCH = 9
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

-- The client wire's own version, checked by the zone before it reads anything
-- else in a join. A stale build is told its build is stale rather than left to
-- misparse snapshots.
local CLIENT_PROTOCOL = 7
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
-- luacheck: ignore DENY_BANNED DENY_VERSION
local DENY_BANNED, DENY_VERSION = 4, 5
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
M.stats = {snaps = 0, err = 0, err_max = 0, rewind = 0, lag = 0, lead = 0,
           rx = 0, tx = 0, msgs = 0, wire = "ws"}

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
-- The last thing this watcher asked to look at, so the keepalive in `step`
-- repeats the ask rather than quietly resetting a follow to the channel.
-- Declared up here because `connect` resets them and Lua scopes a local from
-- its declaration down: assigned any later, these would be globals.
local watch_want = 255
local keepalive = 0
-- Which connection this module is listening to.
--
-- One set of state serves whatever is live, and a socket that has been left
-- can still deliver events, so every callback checks its generation against
-- this before touching anything. Leaving one out is what let a player who
-- hopped from one zone to another end up in both: the old socket kept
-- arriving with snapshots of the old arena, the new one arrived with the new,
-- and the client drew whichever had spoken most recently.
local generation = 0

-- Which wire this connection is on, and how the next one should be dialled.
-- WebTransport is preferred whenever the directory offers an address for it:
-- QUIC retransmits a loss without holding every snapshot behind it, which is
-- the whole of the head-of-line stall networking.md measures. It is also UDP,
-- which enough networks refuse to carry that the WebSocket stays first-class:
-- one dial that goes nowhere and the rest of the session stops asking.
local wt_live = false
-- Seconds a WebTransport dial has gone unanswered, nil when none is pending.
local pending = nil
-- Doors that went unanswered, by address, so the next join to the same one
-- goes straight to the socket.
--
-- This was a single flag for the whole session, on the reasoning that a
-- network which ate one QUIC handshake will eat the next. That is true of a
-- network and it was being applied to something else: a zone advertises its
-- QUIC address as soon as it is configured, including through the half minute
-- a fresh host spends waiting for its certificate and forever after a door
-- that failed to bind. One dial into either of those is indistinguishable
-- from a blocked network here, and it was pinning every zone for the rest of
-- the session to the wire QUIC exists to replace, while the about page told
-- the player their network had eaten it. Keyed by address, a door that is
-- down costs its own joins and nobody else's; a network that really is
-- eating UDP fills this table one zone at a time and reaches the same place.
local wt_avoid = {}
-- Whether *this* connection actually dialled the better door, as opposed to
-- skipping it because an earlier one in this session went unanswered. The two
-- look identical from outside and are not the same fact: one says the network
-- ate a handshake just now, the other says we did not send one. Told apart
-- because they were not, once, and an hour went into asking a firewall why it
-- was dropping packets nobody had sent.
local wt_tried = false
-- What the browser said when a dial failed, when it said anything. Safari and
-- Chrome both put a sentence in the error event, and it is the only account of
-- the failure that exists: the fallback is silent by design, and a phone has no
-- console to read. Kept so the about page can print it, because the device most
-- likely to be on the slower door is the one hardest to attach a debugger to.
local wt_reason = nil
-- What to say on arrival, kept out here so the fallback can redial the
-- WebSocket address and say exactly the same thing.
local join_args = nil
-- How long a QUIC handshake gets before the fallback takes over. A working
-- path answers inside one round trip; three seconds is a blocked one, and a
-- browser left to notice that on its own takes tens of seconds.
local WT_PATIENCE = 3
-- The last snapshot tick applied, for the reorder guard in `on_snapshot`.
local snap_tick = 0

-- The extension is a global on builds that carry it and absent everywhere
-- else, tests and native alike, so it is fetched rather than named.
local function wtx() return rawget(_G, "webtransport") end

local function send_reliable(msg)
    if wt_live then
        pcall(wtx().send, msg)
    elseif conn then
        pcall(websocket.send, conn, msg, {type = websocket.DATA_TYPE_BINARY})
    end
end

-- Inputs only: state the next message supersedes. Over WebTransport this is
-- a datagram, sent once and never retransmitted, because a retransmitted
-- input would arrive naming a tick the room has already run. On the
-- WebSocket it is the same socket as everything else, which is the problem
-- the datagram exists to solve.
local function send_unreliable(msg)
    if wt_live then
        pcall(wtx().send_unreliable, msg)
    elseif conn then
        pcall(websocket.send, conn, msg, {type = websocket.DATA_TYPE_BINARY})
    end
end

-- Reported once, with a reason fit to print, and the connection is over. This
-- lives out here rather than inside `connect` because the decoders need it
-- too: a map or a set of settings this client cannot read is exactly as
-- final as a socket that dropped, and used to set a field nobody read.
local function lost(why)
    if M.lost then return end
    M.lost = why
    M.connected = false
    -- Hung up, not merely forgotten. A decode failure calls this with the
    -- wire still open, and dropping the handle first meant nothing could ever
    -- close it: the socket stayed up, kept receiving an arena the client had
    -- declared unreadable, and held the seat until the zone's own quiet limit
    -- noticed a minute later.
    if conn then pcall(websocket.disconnect, conn) end
    conn = nil
    wt_live = false
    pending = nil
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
        local len = string.byte(s, o + 5)
        -- Six bytes of header, then the name. `string.byte` answers nil past the
        -- end and the arithmetic on it raises, and an error here surfaces inside
        -- a websocket callback where nobody is looking.
        if not len or #s < o + 5 + len then return end
        local ship = string.byte(s, o)
        local label = string.byte(s, o + 1)
        local rating = i16(string.byte(s, o + 2), string.byte(s, o + 3))
        local games = string.byte(s, o + 4)
        pilots[ship] = {
            name = string.sub(s, o + 6, o + 5 + len),
            -- Kept, because everything that used to ask "is this AI" still
            -- wants that answer, and both bot labels are one.
            ai = label == 2 or label == 3,
            label = LABEL[label] or "unknown",
            house = label == 2,
            games = games, tier = M.tier(rating, games),
        }
        ratings[ship] = rating
        o = o + 6 + len
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
local function on_kill(s)
    local victim, killer = string.byte(s, 2), string.byte(s, 3)
    local vr = i16(string.byte(s, 4), string.byte(s, 5))
    local kr = i16(string.byte(s, 6), string.byte(s, 7))
    -- Byte 8 is the contributor count, which nothing here reads yet, and the
    -- payout follows it. Read like every other u16 on the wire rather than
    -- padded with `or 0`: the padding was there for a deploy window against a
    -- zone one image older, and a zone one image older cannot be reached at
    -- all, because the protocol number is checked before a join is answered.
    local paid = u16(string.byte(s, 9), string.byte(s, 10))
    M.kills[#M.kills + 1] = {victim = victim, killer = killer, paid = paid}
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
    local alive, vx, vy = {}, {}, {}
    for i = 0, sim.ship_count() - 1 do
        alive[i] = sim.ship_alive(i)
        vx[i], vy[i] = sim.ship_vel(i)
    end
    local flying = {}
    local tick = sim.tick()
    for i = 0, sim.weapon_count() - 1 do
        local x, y, spec, _, _, _, life, owner, _, level = sim.weapon_at(i)
        -- The rung rides along for the one blast whose colour lives on the
        -- round rather than in the spec table: a mine wears its layer's bomb
        -- rung, and a detonation reconstructed after the fact should flash in
        -- the colour the mine sat there in.
        flying[born_key(tick, spec, life, owner)] =
            {x = x, y = y, spec = spec, life = life, owner = owner,
             level = level}
    end
    return {alive = alive, vx = vx, vy = vy, flying = flying}
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

-- How far back a snapshot may reach and still be a deliberate change of view
-- rather than a packet that overtook another.
--
-- The guard below cannot simply be off while watching, which is what it used
-- to be. The reason it was off is real: the shared channel runs seconds
-- behind live, so leaving a hull for it moves this clock backwards on
-- purpose and a plain monotonic rule would refuse the whole delay. But the
-- two are different sizes. Reordering on a link is a snapshot or two, tens of
-- milliseconds; the channel's delay is five seconds by default. Anything
-- further back than a second is the view changing, and anything nearer is the
-- network, so one number separates them. A zone that sets its channel delay
-- under a second gets a view switch held for that delay and no longer, which
-- is a hitch rather than the double explosions the open guard was giving
-- every watcher on a lossy link.
local WATCH_REWIND = 100

local function on_snapshot(s)
    -- Nothing before the welcome. The zone sends the map, the settings and
    -- the welcome on the reliable lane and snapshots beside it, and only TCP
    -- ever made that an order: over WebTransport a snapshot datagram passes
    -- the map still ramping up on the stream, and this used to apply it to a
    -- world with no terrain, no zone settings, and no seat, as ship zero,
    -- which is somebody else. It healed itself when the map landed and left
    -- the misprediction readout holding a stranger's flight.
    if not M.connected then return end

    -- header: type, subject ship, acked input tick
    --
    -- The pack's own tick comes first in the body, read before anything is
    -- applied. WebTransport's streams and datagrams can pass each other,
    -- which the socket never could, so a snapshot arriving behind one
    -- already applied is dropped rather than walking the room backwards. A
    -- watcher needs that as much as a pilot does: a stale snapshot there
    -- revives a hull the room has already killed, and the next fresh one
    -- kills it again, so one death draws two explosions.
    local sent = u32(string.byte(s, 7), string.byte(s, 8),
                     string.byte(s, 9), string.byte(s, 10))
    if snap_tick ~= 0 and sent <= snap_tick
        and not (M.watching and snap_tick - sent >= WATCH_REWIND) then
        return
    end
    snap_tick = sent
    local body = string.sub(s, 7)

    -- Watching. No prediction to reconcile, no clock to steer, no inputs to
    -- replay: capture what the screen asserts, take the truth whole, and let
    -- the smoothing walk the drawing to it, exactly as a remote hull is
    -- already treated while flying. The subject byte is the one thing the
    -- header says that flying never needed: whose eyes these are.
    if M.watching then
        M.subject = string.byte(s, 2)
        M.stats.snaps = M.stats.snaps + 1
        sim.smooth_capture()
        local before = capture_world()
        if sim.apply_snapshot(body) ~= 0 then return end
        sim.smooth_settle()
        -- Kills and detonations the free-run never lived through still owe
        -- their light and noise; a watcher is here for the explosions.
        harvest_world(before)
        predicted_tick = sim.tick()
        return
    end
    -- The newest input tick the server has received from us. It rode in this
    -- header from the beginning and was skipped over for as long; it is what
    -- says whether our clock is running early enough for an input to reach the
    -- tick it was stamped for.
    local acked = u32(string.byte(s, 3), string.byte(s, 4),
                      string.byte(s, 5), string.byte(s, 6))
    M.stats.snaps = M.stats.snaps + 1

    -- Raw, not what the screen is showing. This measures how far the
    -- prediction missed by, and a number that has had render smoothing folded
    -- into it measures the smoothing instead.
    local px, py = sim.ship_x_raw(M.me), sim.ship_y_raw(M.me)
    -- What the screen is currently asserting about every hull, held across the
    -- correction so the drawing can be walked to the truth rather than cut to
    -- it. See the render section of simcore.cpp.
    sim.smooth_capture()
    -- What the client believes before the truth arrives, for the queues above.
    local before = capture_world()
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

    -- Everything the snapshot and the replay moved is now owed to the drawing,
    -- which pays it off over the next tenth of a second.
    sim.smooth_settle()

    harvest_world(before)

    local dx, dy = sim.ship_x_raw(M.me) - px, sim.ship_y_raw(M.me) - py
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
        if sim.apply_settings(string.sub(s, 2)) ~= 0 then
            lost("the zone sent settings this client cannot read")
        else
            M.settings_epoch = M.settings_epoch + 1
        end
    elseif kind == S2C_WELCOME then
        -- Which of this connection's two lives it is in: a ship, or 255 for
        -- watching. Sitting out and flying again arrive as fresh welcomes on
        -- the same socket, so this is also the view switch, and it gets the
        -- reconnect treatment: the input log and the clock lead belong to the
        -- life that ended, and a channel view can move the tick backwards
        -- across the delay, which the rollback machinery must never see.
        M.me = string.byte(s, 2)
        -- Which room this is, as the server numbered it. Never what was asked
        -- for: a room can fill between a list being read and a key landing,
        -- and the corner of the screen is the one place that must not be
        -- guessing about where you are.
        local lo, hi = string.byte(s, 7, 8)
        M.room = (lo and hi) and (lo + hi * 256) or nil
        if M.room == 0 then M.room = nil end
        local watching = M.me == 255
        if watching ~= M.watching then
            input_log = {}
            predicted_tick = 0
            sim.smooth_reset()
            M.stats.lag, M.stats.lead = 0, 0
            -- The reorder guard's clock belongs to the life that ended: the
            -- channel runs behind live, so coming back to a hull must not
            -- read every live snapshot as older than the delayed one.
            snap_tick = 0
        end
        M.watching = watching
        -- Prediction may kill this hull and no other (decision 40): a death
        -- the client concludes about a coasting remote hull is an explosion
        -- the next snapshot may take back, so everyone else's death waits
        -- for the zone. While watching the byte is already 255, which is
        -- the rule's own word for nobody.
        sim.set_mortal(M.me)
        if not watching then
            M.subject = nil
            M.on_air = false
        end
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
    elseif kind == S2C_YIELD then
        -- The zone wants this seat back. Only ever sent to a client that
        -- declared itself a bot, so a player never sees it; handled anyway,
        -- because a message with no branch is how the scoreboard once spent a
        -- whole session showing the rating somebody walked in with.
        M.denied = "the zone asked for this seat back"
    end
end

-- The join, said the moment a transport opens. One builder for both wires,
-- because the message is the protocol and the transports only carry it.
--
-- class, protocol, flags, then the game we think we picked, then the name.
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
local function join_msg()
    local want = join_args.zone or ""
    local session = account.token or ""
    local flags = join_args.watch and JOIN_WATCH or 0
    -- The room, when a list was read and one was named, and zero when it was
    -- not, which is every arrival that came through the games list. A request
    -- rather than a demand: the room can fill before this lands, and the
    -- welcome says where we actually ended up.
    return string.char(C2S_JOIN, join_args.class, CLIENT_PROTOCOL, flags,
                       #want, #join_args.name, join_args.room or 0)
        .. want .. join_args.name .. session
end

-- One WebSocket dial. Everything that decides *which* wire is in `M.connect`
-- and the fallback; this only knows how. Returns false when the address
-- cannot even be parsed, which throws here rather than failing async.
local function dial_ws()
    local gen = generation
    M.stats.wire = "ws"
    local ok = pcall(function()
        conn = websocket.connect(join_args.url, {}, function(self, cid, data)
            -- A socket we have already left. Closing one buys no promise of
            -- silence, and its parting message would otherwise be read as the
            -- live connection dropping, which clears `conn` and takes the
            -- good connection down with the dead one.
            if gen ~= generation then return end
            if data.event == websocket.EVENT_CONNECTED then
                -- The callback's own handle, not the module's: this can fire
                -- before `websocket.connect` has returned, and `conn` is only
                -- assigned afterwards.
                --
                -- Guarded, because a socket can be closing by the time its own
                -- connect event is delivered, and the extension raises on a
                -- send to one that is. The disconnect that follows carries the
                -- reason a player should see; a Lua error here would take the
                -- frame loop instead.
                pcall(websocket.send, cid, join_msg(),
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
    return ok
end

-- The WebTransport dial went nowhere, so take the socket instead, quietly:
-- the player asked for the game, not for a transport, and the join they get
-- is the same one either wire would have carried. Remembered for the session,
-- because a network that ate one QUIC handshake will eat the next, and three
-- silent seconds per join is a price to pay once.
local function fall_back()
    if join_args and join_args.wt ~= "" then wt_avoid[join_args.wt] = true end
    pending = nil
    wt_live = false
    -- The dead dial can still deliver its own error; it may not speak for
    -- the socket that replaces it.
    generation = generation + 1
    local w = wtx()
    if w then pcall(w.disconnect) end
    if not dial_ws() then
        lost("that address is not a zone URL")
    end
end

local function dial_wt(wt_url)
    local gen = generation
    wt_live = false
    wt_tried = true
    pending = 0
    M.stats.wire = "wt"
    local w = wtx()
    wt_reason = nil
    local ok = pcall(w.connect, wt_url, function(_, data)
        if gen ~= generation then return end
        if data.event == w.EVENT_CONNECTED then
            pending = nil
            wt_live = true
            send_reliable(join_msg())
        elseif data.event == w.EVENT_MESSAGE then
            on_message(data.message)
        elseif pending then
            -- Refused or dropped before it ever opened: the fallback's case,
            -- not the player's problem. The browser's own words are kept
            -- rather than swallowed: a constructor that refused the address
            -- outright and a handshake nobody answered arrive here alike, and
            -- only the message tells them apart.
            if data.message and data.message ~= "" then
                wt_reason = tostring(data.message)
            end
            fall_back()
        else
            wt_live = false
            lost(M.denied or "the zone closed the connection")
        end
    end)
    if not ok then fall_back() end
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
    local w = wtx()
    local url = join_args and join_args.url or ""
    local door = join_args and join_args.wt or ""
    return {
        kind = (wt_live and "wt") or (conn and "ws") or nil,
        secure = string.sub(url, 1, 6) == "wss://",
        able = w ~= nil and w.supported() or false,
        refused = door ~= "" and wt_avoid[door] == true,
        offered = door ~= "",
        tried = wt_tried,
        reason = wt_reason,
        trying = pending ~= nil,
    }
end

-- The WebTransport dial's clock. Called every frame whether or not anything
-- is connected, because a blocked UDP path raises no event to time out on:
-- the browser would notice on its own tens of seconds later, and a player
-- staring at "joining" for that long has already given up.
function M.tick(dt)
    if pending then
        pending = pending + dt
        if pending >= WT_PATIENCE then fall_back() end
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
    M.stats = {snaps = 0, err = 0, err_max = 0, rewind = 0, lag = 0, lead = 0,
               rx = 0, tx = 0, msgs = 0, wire = "ws"}
    M.lost = nil
    snap_tick = 0
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
    -- And its rollback state is worse than useless here, because tick numbers
    -- are per zone. Two arenas that have been up for different lengths of
    -- time are at different ticks, so a log kept across the move is a pile of
    -- inputs filed under a stranger's clock. The replay below walks from the
    -- snapshot's tick up to whatever this said, and against a zone that
    -- happens to be younger that is thousands of extra steps every snapshot,
    -- which a player reads as their ship moving at several times its speed.
    input_log = {}
    predicted_tick = 0
    -- And whatever the drawing was still owed in the last room. An offset is
    -- about a hull in an arena; carried across, it draws the next one beside
    -- itself on arrival.
    sim.smooth_reset()
    on_lost_cb = on_lost
    join_args = {url = url, class = class, name = name, zone = zone,
                 watch = watch, wt = wt, room = room}

    -- The preferred wire first, when there is one to prefer: an address from
    -- the directory, an extension in this build, a browser that has the API,
    -- and no dial already known to go nowhere. Everything else is the socket.
    wt_tried = false
    local w = wtx()
    if wt and wt ~= "" and w and w.supported() and not wt_avoid[wt] then
        dial_wt(wt)
        return true
    end
    -- A malformed address throws in the dial rather than failing
    -- asynchronously, and an unhandled error in init would take the whole
    -- client down.
    if not dial_ws() then
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
-- Everything this client asks a zone for. Requests, all of them: the zone
-- answers with a roster or a team list, and a refusal is that list saying you
-- are still where you were.
local function ask(msg)
    if not M.connected or not (conn or wt_live) then return false end
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
-- that says nothing for 75 seconds, because a flying client sends buttons
-- every frame and silence means the network ate it. A watcher has no buttons,
-- so the ask itself is the heartbeat: it repeats what is already true, and
-- the simulation does not move for it. Counted in this client's own steps
-- rather than in ticks, because a channel snapshot can move the tick
-- backwards across the delay.
local WATCH_KEEPALIVE = 3000

function M.step(buttons)
    if not M.connected or not (conn or wt_live) then return false end
    -- The welcome arrives before the first snapshot. Until one lands there is
    -- no ship to predict, so hold the frame rather than step an empty world.
    if M.stats.snaps == 0 then return true end
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
    predicted_tick = sim.tick() + 1
    input_log[predicted_tick] = buttons
    local t = predicted_tick
    local msg = string.char(
        C2S_INPUT,
        buttons % 256, math.floor(buttons / 256) % 256,
        t % 256, math.floor(t / 256) % 256,
        math.floor(t / 65536) % 256, math.floor(t / 16777216) % 256)
    send_unreliable(msg)
    M.stats.tx = M.stats.tx + #msg
    sim.replay(M.me, buttons)
    return true
end

function M.disconnect()
    -- Bumped whether or not there was a socket, so that anything still in
    -- flight from the last one is stale from here on.
    generation = generation + 1
    if conn then pcall(websocket.disconnect, conn) end
    conn = nil
    local w = wtx()
    if w then pcall(w.disconnect) end
    wt_live = false
    pending = nil
    M.connected = false
end

return M
