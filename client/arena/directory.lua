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
M.note = "looking for games"
-- Set by the caller before the list is opened. Used once, on first contact
-- with a meta-layer, to name a brand new account.
M.pilot_name = ""

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
-- Which dial a callback belongs to. A socket that has been replaced can still
-- deliver its own disconnect afterwards, and without this that event clears
-- `conn` for the socket that replaced it: the list would then dial, come up,
-- be torn down by the ghost of the last one, and do it again for ever.
local generation = 0

local function on_message(s)
    if string.byte(s, 1) ~= S2C_STATUS then return end
    local ok, reply = pcall(json.decode, string.sub(s, 2))
    if not ok or type(reply) ~= "table" or type(reply.zones) ~= "table" then
        M.note = "the directory sent something unreadable"
        return
    end
    -- Where accounts live, if this deployment has any. It rides the games list
    -- because the list is what a client asks for before it needs an identity.
    if type(reply.meta) == "string" then
        account.aim(reply.meta, M.pilot_name or "")
    end
    local rows = {}
    for _, z in ipairs(reply.zones) do
        local up = z.instances and z.instances[1] or nil
        local players = z.players or 0
        rows[#rows + 1] = {
            zone = z.name,
            -- The head of the zone's list, already ordered by the directory so
            -- it is the fullest instance that still has room.
            address = up and up.address or "",
            name = z.name,
            detail = z.description or "",
            -- A zone with nobody running it is a row, not a gap: a player is
            -- better off seeing that Chaos exists and is down than wondering
            -- whether they misread the list.
            count = up
                and string.format("%d playing, %d AI", players, z.bots or 0)
                or "nobody is running it",
            -- The same two numbers unpacked, for a meter rather than a
            -- sentence: how full a game is reads faster as a row of pips than
            -- as "3 playing, 51 AI" read and compared against the next line.
            players = players,
            bots = z.bots or 0,
            live = up ~= nil,
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
    -- Swapped in whole rather than cleared and refilled. A reply that fails to
    -- parse halfway leaves the last good list up, which is a better answer
    -- than an empty one.
    M.rows = rows
    M.note = (#rows == 0) and "the directory lists no games" or ""
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
                on_message(data.message)
            elseif data.event == websocket.EVENT_DISCONNECTED
                or data.event == websocket.EVENT_ERROR then
                conn = nil
                if #M.rows == 0 then
                    M.note = "no directory at " .. url
                end
            end
        end)
    end)
    if not ok then
        conn = nil
        M.note = "that directory address cannot be reached"
    end
end

function M.open(at)
    M.close()
    M.rows = {}
    M.note = "looking for games"
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
    since = since + dt
    if since >= REFRESH then ask() end
end

-- The list is no longer on screen, so the next look at it starts with an ask
-- rather than with whatever this happens to be holding.
function M.idle()
    watching = false
end

return M
