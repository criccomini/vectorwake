-- What the directory says is running.
--
-- One request, one reply, re-asked on a timer while somebody is looking at the
-- list. It speaks the same protocol a zone does, so this needs no second
-- transport, and it holds nothing: close it and the answer is forgotten.
--
-- A player picks a game, not a machine. The directory's reply is a list of
-- zones with the instances running each one underneath, so a row here is a
-- game and choosing it takes the head of that zone's instance list, which the
-- directory has already ordered so the head is the fullest one with room. The
-- address never reaches the player. The zone's name travels with the join, so
-- arriving at an instance that has since changed game is a refusal rather than
-- a surprise.
--
-- The list is the whole way into the game, so a directory that cannot be
-- reached has to say so in words a player can act on rather than leaving an
-- empty list that looks like a fleet with nothing running on it.

local account = require("arena.account")

local M = {}

local C2S_STATUS = 4
local S2C_STATUS = 8

-- How often to re-ask while the list is on screen. A request is one byte and
-- the reply a few hundred, and what the list is for is how busy each game is
-- right now, which is a number that moves while somebody reads it.
local REFRESH = 3

-- How long to wait before dialling again after a socket dies, and the ceiling
-- it backs off to. A dial is a TLS handshake rather than the one byte a
-- refresh costs, so a directory that is down for ten minutes should not be
-- handshaked two hundred times; but the first retry is quick, because the
-- common case by far is a deploy and the list should come back on its own
-- within seconds of the server doing.
local RETRY_FIRST, RETRY_MAX = 2, 15

M.rows = {}
-- Seconds since the last good reply landed. The clocks on the rows were true
-- at that moment and count down from it.
M.aged = 0
-- What the list says when it has nothing to list: a heading and the line
-- under it. Two strings rather than one, because an empty page has room to
-- say what is happening as well as what will happen.
--
-- It carried the address being asked as a third, on the argument that
-- whoever is running this would want to know which endpoint was silent.
-- They read logs; a player reads this.
M.note = "looking for games"
M.why = "asking the directory"
-- Whether any answer has landed, good or bad. The waiting screen reads it to
-- tell a normal two second wait from a fleet that is not there: before the
-- first reply it says nothing, and after one it can say what came back.
M.answered = false
-- The deployment's own front door, by zone key. See `M.head`. Empty against a
-- directory that predates the field, and `M.head` answers off the list alone.
M.default_zone = ""

local conn = nil
local since = 0
-- Whether the list is the thing on screen. The rising edge is an ask, so
-- opening the list never shows counts from the last time somebody stood here.
local watching = false
-- Where to dial, kept so that a socket that dies can be replaced without the
-- caller being involved. It is the same address for the life of the client.
local url = nil
-- The redial timer: how long since the socket went, and how long to wait.
local down_for = 0
local retry_in = RETRY_FIRST
-- How long the socket has been up without a word from the far end. A socket
-- that connects and never answers used to be asked every three seconds for
-- the life of the process, with the loading screen on "looking for games"
-- and nothing ever dialling again, since only a socket that had gone was
-- redialled. Past this it is hung up on, and the retry clock takes over.
local MUTE = 12
local quiet = 0
-- Which dial a callback belongs to. A socket that has been replaced can still
-- deliver its own disconnect afterwards, and without this that event clears
-- `conn` for the socket that replaced it: the list would then dial, come up,
-- be torn down by the ghost of the last one, and do it again for ever.
local generation = 0

-- Where an instance answers, by its id.
--
-- A deep link names a room by zone, instance and number, and this list is the
-- only thing that knows where that instance is. Rebuilt with the rows rather
-- than searched on demand, because the games list changes every few seconds
-- at most and a link is followed once.
--
-- An instance the directory is no longer listing is simply absent, and the
-- route stays pending: the frame loop tries it again on every list, so a link
-- followed while an arena is registering lands as soon as it appears.
M.instances = {}

local function index_instances(zones)
    local out = {}
    for _, z in ipairs(zones) do
        for _, inst in ipairs(type(z.instances) == "table" and z.instances or {}) do
            if type(inst.id) == "string" and inst.id ~= "" then
                out[inst.id] = {zone = z.name, instance = inst.id,
                                address = inst.address or "",
                                wt = inst.wt or "", rooms = inst.rooms or {}}
            end
        end
    end
    return out
end

function M.at_instance(id)
    return type(id) == "string" and M.instances[id] or nil
end

-- The room a press on the zone's row would put you in: the head instance's
-- first room with a seat, or its first room when every one is full. This is
-- the room whose clock the play page counts down, so it has to be the same
-- pick the join makes; a clock read off one room and a whistle heard in
-- another is worse than no clock.
-- What to call a zone, by its key. The games list is where the labels arrive,
-- so it is where everything else asks: the play tab's own detail, the card
-- that asks about leaving one game for another, and the chip in the corner
-- of a room all name a game a player chose off this list.
function M.label_of(zone)
    if zone == nil or zone == "" then return "" end
    for _, r in ipairs(M.rows or {}) do
        if r.zone == zone then return r.name or zone end
    end
    return zone
end

-- The game to open on, for a client that has not chosen one.
--
-- Deliberately not `M.rows[1]`. That list is sorted alphabetically, for
-- reading, and the head of it is whichever game the alphabet put first. Two
-- things follow, and both were live until a deployment ran more than one game.
--
-- The alphabet is not the deployment's opinion about where a new player should
-- start, and the catalog already holds one: `default_zone`, the same line an
-- arena reads when nothing has told it what to serve. So that is asked first.
--
-- And a game with no arena behind it is still a row, on purpose, so a player
-- can see that it exists and is down. The landing dials this row for its
-- backdrop and draws the whole screen behind that connection, so taking a dead
-- one head-on was a wordmark on a starfield with no way in and nothing saying
-- why, however many other games were running.
--
-- The head is what is left when nothing is up. That is not a game anybody can
-- join; it is a name to put on the press so a fleet that is down feels like a
-- join that waits, which is what it is.
function M.head()
    local rows = M.rows or {}
    local up
    for _, r in ipairs(rows) do
        if r.live and (r.address or "") ~= "" then
            if r.zone == M.default_zone then return r end
            up = up or r
        end
    end
    return up or rows[1]
end

local function join_room(z)
    local up = z.instances and z.instances[1] or nil
    if not up or type(up.rooms) ~= "table" then return nil end
    local first = nil
    for _, rm in ipairs(up.rooms) do
        if type(rm) == "table" then
            first = first or rm
            if rm.full ~= true then return rm end
        end
    end
    return first
end

local function on_message(s)
    if string.byte(s, 1) ~= S2C_STATUS then return end
    local ok, reply = pcall(json.decode, string.sub(s, 2))
    if not ok or type(reply) ~= "table" or type(reply.zones) ~= "table" then
        M.note = "the directory sent something unreadable"
        M.answered = true
        M.why = "retrying"
        return
    end
    -- Where accounts live, if this deployment has any. It rides the games list
    -- because the list is what a client asks for before it needs an identity.
    if type(reply.meta) == "string" then
        account.aim(reply.meta)
    end
    -- Which of the games below is the way in. Read before the rows are built
    -- because `M.head` reads both together, and a reply that named a new front
    -- door while the old rows were still up would open on the wrong one.
    M.default_zone = type(reply.default_zone) == "string"
        and reply.default_zone or ""
    local rows = {}
    for _, z in ipairs(reply.zones) do
        local up = z.instances and z.instances[1] or nil
        local landing = join_room(z)
        local players = z.players or 0
        rows[#rows + 1] = {
            zone = z.name,
            -- The head of the zone's list, already ordered by the directory so
            -- it is the fullest instance that still has room.
            address = up and up.address or "",
            instance = up and up.id or nil,
            -- The same instance's WebTransport door, when it has one. The
            -- join prefers it and keeps `address` as the fallback; a build
            -- with no extension never reads it.
            wt = up and up.wt or "",
            -- What the row says, which is the zone's label where it has one
            -- and its own key where it does not. The key is what a join
            -- names and what a rating is filed under, so renaming the game a
            -- player reads cannot move either.
            name = (type(z.label) == "string" and z.label ~= "") and z.label
                or z.name,
            -- The format strip: what the row's stacks say under TEAMS, TIME
            -- and SCORING, in the catalog's own words. A directory from
            -- before the strip sends none and the row is its name alone.
            teams = type(z.teams) == "string" and z.teams or "",
            time = type(z.time) == "string" and z.time or "",
            scoring = type(z.scoring) == "string" and z.scoring or "",
            -- A zone with nobody running it is a row, not a gap: a player is
            -- better off seeing that Chaos exists and is down than wondering
            -- whether they misread the list. It says so without a sentence,
            -- by wearing the dial that is looking for an arena where the busy
            -- rows carry their counts.
            count = up
                and string.format("%d people, %d AI", players, z.bots or 0)
                or "",
            -- The same two numbers unpacked, for a meter rather than a
            -- sentence: how full a game is reads faster as a row of pips than
            -- as "3 playing, 51 AI" read and compared against the next line.
            players = players,
            bots = z.bots or 0,
            -- One room's seats, for drawing the room as a row of them. Zero
            -- from a directory that predates the field, and the drawing
            -- falls back to bare marks.
            seats = z.seats or 0,
            -- The clock of the room a join would land in and whether that
            -- room is mid-match. Zero and false from an older fleet keep the
            -- ordinary countdown.
            clock = landing and landing.clock or 0,
            playing = landing ~= nil and landing.playing == true,
            live = up ~= nil,
            -- No seat and no headroom to make one, as the instance at the head
            -- of the list reports it. The row keeps its counts rather than
            -- wearing the dial that means "looking for an arena": a full game
            -- is the opposite of an absent one, and the count is the reason it
            -- cannot be entered.
            full = up ~= nil and up.full == true,
        }
    end
    -- Alphabetical, rather than the order the reply arrives in. That order is
    -- the catalog's declaration order, which is the deployment's own business
    -- and reads as arbitrary from in here: it puts a newly added game last for
    -- good, so the list quietly becomes a history of when each one was written.
    -- Lowercased for the comparison so a capital cannot jump a game to the top,
    -- and the raw name breaks a tie so the order is total.
    table.sort(rows, function(a, b)
        local la, lb = string.lower(a.name), string.lower(b.name)
        if la ~= lb then return la < lb end
        return a.name < b.name
    end)
    M.instances = index_instances(reply.zones)
    -- Swapped in whole rather than cleared and refilled. A reply that fails to
    -- parse halfway leaves the last good list up, which is a better answer
    -- than an empty one.
    M.rows = rows
    -- The room clocks in this reply are as fresh as they will ever be. The
    -- page subtracts this age from a row's clock so the count moves every
    -- second instead of every refresh.
    M.aged = 0
    M.note = (#rows == 0) and "no games are running" or ""
    M.answered = true
    M.why = "the list fills in by itself when one starts"
end

local function ask()
    if not conn then return end
    since = 0
    pcall(websocket.send, conn, string.char(C2S_STATUS),
          {type = websocket.DATA_TYPE_BINARY})
end

-- One dial. Everything that decides *when* to dial is in `M.tick`; this only
-- knows how.
local function dial()
    generation = generation + 1
    local mine = generation
    down_for = 0
    quiet = 0
    local ok = pcall(function()
        conn = websocket.connect(url, {}, function(self, cid, data)
            -- A reply from a socket we have already given up on. It may not
            -- touch `conn`, which by now belongs to its replacement.
            if mine ~= generation then return end
            if data.event == websocket.EVENT_CONNECTED then
                -- The callback's own handle: this can fire before
                -- `websocket.connect` has returned, and `conn` is only
                -- assigned afterwards.
                pcall(websocket.send, cid, string.char(C2S_STATUS),
                      {type = websocket.DATA_TYPE_BINARY})
            elseif data.event == websocket.EVENT_MESSAGE then
                -- A directory that is answering is a directory worth dialling
                -- straight away next time it is not.
                retry_in = RETRY_FIRST
                quiet = 0
                on_message(data.message)
            elseif data.event == websocket.EVENT_DISCONNECTED
                or data.event == websocket.EVENT_ERROR then
                conn = nil
                if #M.rows == 0 then
                    -- What a player can see from where they are sitting. It
                    -- said "no directory answered", which names a piece of
                    -- this fleet nobody playing has heard of and reads as
                    -- something they have done wrong; the address under it
                    -- is still there for whoever is running the thing.
                    M.note = "no servers found"
                    M.answered = true
                    M.why = "retrying"
                end
            end
        end)
    end)
    if not ok then
        conn = nil
        M.note = "that address cannot be dialled"
        M.answered = true
        M.why = "the client was pointed somewhere it cannot reach"
    end
end

function M.open(at)
    M.close()
    M.rows = {}
    M.note = "looking for games"
    M.why = "asking the directory"
    since = 0
    watching = false
    retry_in = RETRY_FIRST
    url = at
    dial()
end

function M.close()
    -- Bumped whether or not there was a socket, so nothing still in flight
    -- from the last one can speak for the next.
    generation = generation + 1
    if conn then pcall(websocket.disconnect, conn) end
    conn = nil
end

-- Called every frame the list is the thing on screen. Nobody needs a fresh
-- player count for a list they are not looking at, so this is the whole of the
-- polling and it stops the moment the list does.
function M.tick(dt)
    -- Opening the list asks at once. Somebody who has been three levels down
    -- setting the volume, or in a game for ten minutes, would otherwise be
    -- shown the counts from whenever they last stood here and have to wait out
    -- the interval for the truth, which is the staleness this exists to
    -- remove.
    --
    -- With no socket it is a dial rather than an ask, and the backoff starts
    -- over: somebody who has just walked up to the list is asking now, and
    -- should not be serving out the tail of a wait that grew while they were
    -- somewhere else.
    if not watching then
        watching = true
        retry_in = RETRY_FIRST
        if conn then
            ask()
        elseif url then
            dial()
        end
        return
    end
    -- The reply's clocks keep ageing whether or not the socket is up: a row
    -- from a directory that has just gone quiet counts down honestly until
    -- the next reply replaces it or the drawing clamps it at zero.
    M.aged = M.aged + dt
    -- The socket went and nothing else will replace it. Without this the list
    -- is a dead end for the life of the process: the fleet restarts, the
    -- directory comes back, and the only way to see it is to reload the whole
    -- client. The moment it is most likely to happen is a deploy, which is
    -- also the moment somebody is most likely to be watching this list.
    if not conn then
        if not url then return end
        down_for = down_for + dt
        if down_for >= retry_in then
            -- Grown before the dial rather than after it, so a directory that
            -- refuses instantly cannot be dialled every frame.
            retry_in = math.min(retry_in * 2, RETRY_MAX)
            dial()
        end
        return
    end
    quiet = quiet + dt
    if quiet >= MUTE then
        -- Hung up on rather than asked again. The generation moves so a late
        -- reply cannot speak for the socket that replaces this one.
        M.close()
        if #M.rows == 0 then
            M.note = "no servers found"
            M.answered = true
            M.why = "retrying"
        end
        return
    end
    since = since + dt
    if since >= REFRESH then ask() end
end

-- The list is no longer on screen, so the next look at it starts with an ask
-- rather than with whatever this happens to be holding.
function M.idle()
    watching = false
end

return M
