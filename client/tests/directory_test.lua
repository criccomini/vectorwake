-- The games list, and what it does when the directory goes away.
--
--     lua5.1 client/tests/directory_test.lua
--
-- The list is the whole way into the game, and it is watched hardest during a
-- deploy, which is exactly when the directory it is talking to restarts. That
-- made the socket dying a dead end: the error handler cleared the connection,
-- `M.tick` opened by returning when there was none, and nothing anywhere else
-- dialled again. The fleet came back, the list did not, and the only way out
-- was to reload the client.
--
-- Nothing about that is visible in a screenshot and none of it is reachable
-- from the game: the failure needs a server that stops and then starts. So the
-- socket is stubbed here and the events are delivered by hand.

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

-- --- the socket, as a thing this test drives -------------------------------

-- Every dial ever made, so the test can count them and speak to any one: a
-- socket that has been given up on is still able to deliver events, which is
-- the whole point of the generation guard being checked below.
local dials = {}
local sent = {}

_G.websocket = {
    EVENT_CONNECTED = 1,
    EVENT_MESSAGE = 2,
    EVENT_DISCONNECTED = 3,
    EVENT_ERROR = 4,
    DATA_TYPE_BINARY = 1,
    connect = function(url, _, cb)
        local h = {url = url, cb = cb, open = true}
        dials[#dials + 1] = h
        return h
    end,
    disconnect = function(h) if h then h.open = false end end,
    send = function(h, data) sent[#sent + 1] = {h = h, data = data} end,
}

-- Only ever handed the body of a status reply, which this test writes itself.
_G.json = {
    decode = function(s)
        if s == "junk" then error("not json") end
        -- A reply written out in full, for the cases a list of zone names
        -- cannot express. Spent on read, so the next message goes back to the
        -- shorthand above.
        if _G.NEXT_REPLY then
            local r = _G.NEXT_REPLY
            _G.NEXT_REPLY = nil
            return r
        end
        local zones = {}
        for name in s:gmatch("[%a]+") do
            zones[#zones + 1] = {
                name = name, description = name .. " zone", players = 2,
                bots = 40, instances = {{address = "wss://x/" .. name}},
            }
        end
        return {zones = zones}
    end,
}

package.loaded["arena.account"] = {aim = function() end}

local dir = require("arena.directory")

-- The events, as the extension delivers them.
local function connected(h) h.cb(nil, h, {event = websocket.EVENT_CONNECTED}) end
local function message(h, body)
    h.cb(nil, h, {event = websocket.EVENT_MESSAGE,
                  message = string.char(8) .. body})
end
local function died(h) h.cb(nil, h, {event = websocket.EVENT_ERROR}) end

-- Frames, at the rate the menu ticks. The list is on screen throughout, which
-- is what `M.tick` means.
local function run(seconds)
    for _ = 1, math.floor(seconds * 60) do dir.tick(1 / 60) end
end

-- The same, with a directory that is still down: every dial it makes is
-- refused. `websocket.connect` hands back a handle whether or not anything is
-- listening, so without failing them the code under test believes it has a
-- socket and stops dialling, which is not what a down server looks like.
local function run_refused(seconds)
    local failed = {}
    for _ = 1, math.floor(seconds * 60) do
        dir.tick(1 / 60)
        for _, h in ipairs(dials) do
            if not failed[h] then
                failed[h] = true
                died(h)
            end
        end
    end
end

local function last() return dials[#dials] end

-- --- a list that works -----------------------------------------------------

dir.open("wss://dir.example/x")
check("opening the list dials", #dials == 1)
connected(last())
check("a fresh socket is asked at once", #sent == 1)
message(last(), "chaos war")
check("a reply fills the list", #dir.rows == 2,
      "rows: " .. tostring(#dir.rows))
check("and clears the note", dir.note == "",
      "note: " .. tostring(dir.note))

-- The list is on screen, so it re-asks on its own timer.
local before = #sent
run(4)
check("a live list keeps asking", #sent > before)

-- --- the directory goes away -----------------------------------------------

local ghost = last()
died(ghost)
check("a dead socket is not dialled again in the same frame", #dials == 1)

-- Nothing for a second, then a dial. The first retry is quick because the
-- common case is a deploy that takes seconds.
run(1)
check("it does not dial the instant the socket dies", #dials == 1)
run(2)
check("it dials again a couple of seconds later", #dials == 2,
      "dials: " .. #dials)

-- The one that took real thought. The socket we gave up on is still able to
-- deliver its own disconnect, and if that event is allowed to clear the
-- connection it clears the one that replaced it: the list would dial, come up,
-- be torn down by a ghost, and repeat for ever.
connected(last())
local live = last()
died(ghost)
-- Twenty seconds of frames on a socket that is perfectly healthy. If the
-- ghost's event were allowed through, this is where it would show: the
-- connection would read as gone and the backoff would start dialling over the
-- top of a working one.
run(20)
check("a ghost's disconnect cannot kill the socket that replaced it",
      #dials == 2, "dials: " .. #dials)
message(live, "chaos war alpha")
check("and the socket it tried to kill still answers", #dir.rows == 3,
      "rows: " .. tostring(#dir.rows))

-- --- the list comes back on its own ----------------------------------------

-- The whole point. No reload, no going home: the fleet returns and the list
-- fills in.
died(live)
-- Silent, on purpose: a list that is up stays up. A reply that never comes is
-- a worse reason to blank three games off the screen than to leave counts that
-- are a few seconds stale, and the redial below is what makes that true rather
-- than merely hopeful.
check("an outage under a good list leaves the list alone",
      #dir.rows == 3 and dir.note == "",
      "rows " .. #dir.rows .. ", note " .. tostring(dir.note))
run_refused(6)
run(30)
local revived = last()
connected(revived)
message(revived, "chaos war alpha")
check("the list comes back without the client being reloaded",
      #dir.rows == 3 and dir.note == "",
      "rows " .. #dir.rows .. ", note " .. tostring(dir.note))

-- --- the backoff is a backoff ----------------------------------------------

-- A directory that is down for a long time is dialled less and less often, up
-- to a ceiling. A dial is a TLS handshake, not the one byte a refresh costs.
died(last())
local from = #dials
run_refused(60)
local in_first = #dials - from
check("a long outage backs off rather than dialling every couple of seconds",
      in_first <= 8, "dials in 60s: " .. in_first)
check("but it does keep trying", in_first >= 4,
      "dials in 60s: " .. in_first)

-- Two minutes of the same outage: the ceiling holds, so the rate settles
-- rather than thinning out until the list is dead again by another route.
from = #dials
run_refused(120)
local later = #dials - from
check("the ceiling holds the rate steady", later >= 6 and later <= 12,
      "dials in 120s: " .. later)

-- --- walking up to the list is asking now ----------------------------------

-- Somebody who has been elsewhere and comes back should not serve out the tail
-- of a wait that grew while they were gone.
dir.idle()
from = #dials
dir.tick(1 / 60)
check("re-opening the list dials at once", #dials == from + 1,
      "dials: " .. (#dials - from))

-- --- a reply that does not parse -------------------------------------------

connected(last())
message(last(), "chaos war")
local held = #dir.rows
message(last(), "junk")
check("an unreadable reply keeps the last good list", #dir.rows == held,
      "rows: " .. #dir.rows)
check("and says so", dir.note ~= "", "note: " .. tostring(dir.note))

-- --- what the player is actually shown -------------------------------------

-- The list is the whole way in, so an empty one has to say why in words
-- somebody can act on, and it has to say that waiting is one of the actions.
-- Reloading the client used to be the only way out of this screen, and a
-- player has no way to know that it is not still.
--
-- It is a page with nothing in it rather than a row with nothing in it: a
-- blank row carrying the note was a row pretending to be a game.
package.loaded["arena.account"].name = ""
package.loaded["arena.account"].status = function() return "" end
package.loaded["arena.account"].aim = function() end
_G.sys = {get_config_string = function(_, d) return d or "" end,
          load = function() return {} end, save = function() return true end,
          get_save_file = function() return "" end}
local menu = require("arena.menu")
menu.show("play")

dir.rows = {}
dir.note = "no servers found"
dir.why = "retrying"
local view = menu.view()
-- The play page carries one row that is not a game: the way to the community,
-- which is where somebody is already thinking about who to play with. So an
-- empty list is a page with nothing on it a player can join.
local function games_on(v)
    local n = 0
    for _, r in ipairs(v.rows) do
        if r.act == "join" then n = n + 1 end
    end
    return n
end
check("an empty list offers no game to join", games_on(view) == 0,
      games_on(view) .. " games")
check("and says why", view.empty and view.empty.head == dir.note,
      "head: " .. tostring(view.empty and view.empty.head))
check("and that it is still trying",
      view.empty and view.empty.line ~= nil and view.empty.line ~= "",
      "line: " .. tostring(view.empty and view.empty.line))

-- And a page with games on it has nothing to explain.
dir.rows = {{zone = "chaos", name = "chaos", detail = "a brawl", count = "",
             players = 0, bots = 0, live = true}}
check("a list with games in it says nothing", menu.view().empty == nil,
      tostring(menu.view().empty))


-- --- the rooms of a zone, across the servers holding them ------------------
--
-- The panel in the corner lists these and a click on one joins it, so what
-- matters here is that a room's number is the one the server gave it and not
-- anything this file worked out. A directory sorts its instances by how full
-- they are, so a number read off arrival order would move whenever anybody
-- joined anything, and the whole point of a room number is to survive being
-- said out loud.

_G.NEXT_REPLY = {zones = {{
    name = "pit", description = "rooms",
    players = 6, bots = 0,
    instances = {
        -- Fullest first, which is the order a directory sends and deliberately
        -- not the order these come out in.
        {id = "a7", address = "wss://x/a7", wt = "https://x/a7", rooms = {
            {number = 4, players = 3, bots = 1, full = false},
            {number = 2, players = 2, bots = 0, full = true},
        }},
        {id = "a3", address = "wss://x/a3", rooms = {
            {number = 1, players = 1, bots = 5, full = false},
        }},
    },
}}}
message(last(), "ignored")
local rm = dir.rows[1] and dir.rows[1].rooms
check("every room of the zone is listed, whichever server holds it",
      rm ~= nil and #rm == 3, "rooms: " .. tostring(rm and #rm))
check("in the order the servers named them, not the order they arrived",
      rm and rm[1].n == 1 and rm[2].n == 2 and rm[3].n == 4,
      rm and table.concat({rm[1].n, rm[2].n, rm[3].n}, ",") or "none")
check("each carrying the address of the server it is on",
      rm and rm[1].address == "wss://x/a3" and rm[3].address == "wss://x/a7",
      rm and (rm[1].address .. " " .. rm[3].address) or "none")
check("each carrying the stable instance named by a room link",
      rm and rm[1].instance == "a3" and rm[3].instance == "a7",
      rm and (tostring(rm[1].instance) .. " " .. tostring(rm[3].instance)) or "none")
check("and what the server said about it",
      rm and rm[2].full == true and rm[3].players == 3 and rm[3].bots == 1)

-- A zone whose processes hold one room each has no list. A list of the room
-- you are already in is a list of one thing you cannot leave for.
_G.NEXT_REPLY = {zones = {{
    name = "solo", description = "one room", players = 1, bots = 0,
    instances = {{address = "wss://x/a1", rooms = {
        {number = 1, players = 1, bots = 0, full = false},
    }}},
}}}
message(last(), "ignored")
check("one room in the whole zone is not a list",
      dir.rows[1] and dir.rows[1].rooms == nil,
      tostring(dir.rows[1] and dir.rows[1].rooms))

-- And the fleet as it stands today, which sends no rooms at all.
_G.NEXT_REPLY = {zones = {{
    name = "old", description = "no rooms key", players = 0, bots = 0,
    instances = {{address = "wss://x/a1"}},
}}}
message(last(), "ignored")
check("a directory that says nothing about rooms is not an error",
      dir.rows[1] ~= nil and dir.rows[1].rooms == nil)

-- A room with no number cannot be drawn and must not reach the sort, which
-- compares numbers: a nil there raises out of the message handler, past the
-- one pcall around the decode, before the rows are replaced. The list would
-- then keep the counts it had at that moment for the life of the process,
-- reasking every three seconds and throwing on every answer.
_G.NEXT_REPLY = {zones = {{
    name = "torn", description = "a room with no number", players = 2, bots = 0,
    instances = {{address = "wss://x/a1", rooms = {
        {number = 1, players = 1, bots = 0},
        {players = 1, bots = 0},
        {number = 3, players = 0, bots = 4},
    }}},
}}}
message(last(), "ignored")
check("a room the directory did not number is dropped, not thrown over",
      dir.rows[1] ~= nil and dir.rows[1].name == "torn",
      "row: " .. tostring(dir.rows[1] and dir.rows[1].name))
local torn = dir.rows[1] and dir.rows[1].rooms
check("and the rooms that were numbered are still listed",
      torn ~= nil and #torn == 2 and torn[1].n == 1 and torn[2].n == 3,
      "rooms: " .. tostring(torn and #torn))

-- Full is the instance's own answer to "am I out of room", and the row carries
-- it so a full game keeps its counts instead of wearing the dial that means
-- nobody is running one.
_G.NEXT_REPLY = {zones = {{
    name = "packed", description = "no seats", players = 32, bots = 0,
    instances = {{address = "wss://x/a1", full = true}},
}}}
message(last(), "ignored")
check("a full zone says so on its row", dir.rows[1] and dir.rows[1].full == true)
_G.NEXT_REPLY = {zones = {{
    name = "roomy", description = "seats", players = 2, bots = 0,
    instances = {{address = "wss://x/a1"}},
}}}
message(last(), "ignored")
check("and one with seats does not", dir.rows[1] and dir.rows[1].full == false)

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
