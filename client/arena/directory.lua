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

M.rows = {}
M.note = "looking for games"
-- Set by the caller before the list is opened. Used once, on first contact
-- with a meta-layer, to name a brand new account.
M.pilot_name = ""

local conn = nil
local address = nil
local since = 0
-- Whether the list is the thing on screen. The rising edge is an ask, so
-- opening the list never shows counts from the last time somebody stood here.
local watching = false

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

function M.open(url)
    M.close()
    address = url
    M.rows = {}
    M.note = "looking for games"
    since = 0
    watching = false
    local ok = pcall(function()
        conn = websocket.connect(url, {}, function(self, cid, data)
            if data.event == websocket.EVENT_CONNECTED then
                -- The callback's own handle: this can fire before
                -- `websocket.connect` has returned, and `conn` is only
                -- assigned afterwards.
                pcall(websocket.send, cid, string.char(C2S_STATUS),
                      {type = websocket.DATA_TYPE_BINARY})
            elseif data.event == websocket.EVENT_MESSAGE then
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

function M.close()
    if conn then pcall(websocket.disconnect, conn) end
    conn = nil
end

-- Called every frame the list is the thing on screen. Nobody needs a fresh
-- player count for a list they are not looking at, so this is the whole of the
-- polling and it stops the moment the list does.
function M.tick(dt)
    if not conn then return end
    -- Opening the list asks at once. Somebody who has been three levels down
    -- setting the volume, or in a game for ten minutes, would otherwise be
    -- shown the counts from whenever they last stood here and have to wait out
    -- the interval for the truth, which is the staleness this exists to
    -- remove.
    if not watching then
        watching = true
        ask()
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
