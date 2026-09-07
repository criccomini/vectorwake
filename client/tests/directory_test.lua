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
                name = name, players = 2,
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
-- Twenty seconds of frames on a socket that is perfectly healthy, which is
-- to say one that answers what it is asked. If the ghost's event were
-- allowed through, this is where it would show: the connection would read
-- as gone and the backoff would start dialling over the top of a working
-- one.
for _ = 1, 4 do
    run(5)
    message(live, "chaos war alpha")
end
check("a ghost's disconnect cannot kill the socket that replaced it",
      #dials == 2, "dials: " .. #dials)
message(live, "chaos war alpha")
check("and the socket it tried to kill still answers", #dir.rows == 3,
      "rows: " .. tostring(#dir.rows))

-- A socket that is up and says nothing is not healthy. It used to be asked
-- every three seconds for the life of the process, the loading screen on
-- "looking for games" throughout, since only a socket that had gone was
-- ever dialled again.
run(20)
check("a socket that never answers is hung up on and dialled again",
      #dials == 3, "dials: " .. #dials)
connected(last())
live = last()
message(live, "chaos war alpha")

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

-- The menu is not where a game is picked. The landing's zone stop is the one
-- list of them, so nothing the directory says reaches a menu page: a fleet
-- that is down says so on the waiting screen, which reads `directory.note`
-- once the directory has answered, and a fleet that is up is a list under the
-- landing's zone stop with the key that joins it underneath.
--
-- What is worth pinning here is that the drawer offers no game at all, with a
-- list and without one. It carried the same games twice for a while, once in
-- its own page and once on the landing behind it.
package.loaded["arena.account"].name = ""
package.loaded["arena.account"].status = function() return "" end
package.loaded["arena.account"].aim = function() end
_G.sys = {get_config_string = function(_, d) return d or "" end,
          load = function() return {} end, save = function() return true end,
          get_save_file = function() return "" end}
local menu = require("arena.menu")
menu.show()

local function games_on(v)
    local n = 0
    for _, r in ipairs(v.rows) do
        if r.zone ~= nil or r.act == "join" then n = n + 1 end
    end
    return n
end
dir.rows = {}
dir.note = "no servers found"
dir.why = "retrying"
check("an empty fleet puts no game in the drawer",
      games_on(menu.view()) == 0, games_on(menu.view()) .. " games")
dir.rows = {{zone = "chaos", name = "chaos", count = "",
             players = 0, bots = 0, live = true}}
check("and neither does one with games in it",
      games_on(menu.view()) == 0, games_on(menu.view()) .. " games")

-- --- a room the directory did not number ------------------------------------
--
-- The games list flattened every room of a zone into a list of its own for as
-- long as the corner chip opened one, and it sorted that list by number: a
-- room the directory sent without one raised out of the message handler, past
-- the one pcall around the decode, before the rows were replaced. The list
-- then kept the counts it had at that moment for the life of the process,
-- reasking every three seconds and throwing on every answer.
--
-- The chip and its panel are gone and nothing sorts rooms any more, but the
-- reply still carries them and the row still reads the first one for its
-- clock, so a malformed room must still not take the list down with it.
_G.NEXT_REPLY = {zones = {{
    name = "torn", players = 2, bots = 0,
    instances = {{address = "wss://x/a1", rooms = {
        {number = 1, players = 1, bots = 0},
        {players = 1, bots = 0},
        {number = 3, players = 0, bots = 4},
    }}},
}}}
message(last(), "ignored")
check("a room the directory did not number is not thrown over",
      dir.rows[1] ~= nil and dir.rows[1].name == "torn",
      "row: " .. tostring(dir.rows[1] and dir.rows[1].name))

-- And the fleet as it stands today, which sends no rooms at all.
_G.NEXT_REPLY = {zones = {{
    name = "old", players = 0, bots = 0,
    instances = {{address = "wss://x/a1"}},
}}}
message(last(), "ignored")
check("a directory that says nothing about rooms is not an error",
      dir.rows[1] ~= nil and dir.rows[1].name == "old")

-- --- the format words -------------------------------------------------------
--
-- What a game's format says under TEAMS, TIME and SCORING travels on the reply
-- beside the label, in the catalog's own words. The client lays them out and
-- never derives one, so what matters here is that they land on the row
-- verbatim and that a directory that states none leaves the row bare. The
-- landing's zone list is what reads them; see client/tests/landing_test.lua.

_G.NEXT_REPLY = {zones = {{
    name = "melee", label = "Team Battle",
    teams = "4 v 4", time = "3:00", scoring = "kills",
    players = 3, bots = 5, instances = {{address = "wss://x/m"}},
}}}
message(last(), "ignored")
check("the format lands on the row in the catalog's words",
      dir.rows[1] and dir.rows[1].teams == "4 v 4"
      and dir.rows[1].time == "3:00" and dir.rows[1].scoring == "kills",
      tostring(dir.rows[1] and dir.rows[1].teams))

-- A directory that says nothing about a format is the fleet from before the
-- words existed, and the row carries none rather than inventing one.
_G.NEXT_REPLY = {zones = {{
    name = "old", players = 0, bots = 0,
    instances = {{address = "wss://x/a1"}},
}}}
message(last(), "ignored")
check("a directory that states no format leaves the row bare",
      dir.rows[1] and dir.rows[1].teams == "" and dir.rows[1].scoring == "",
      tostring(dir.rows[1] and dir.rows[1].teams))

-- A zone whose mode has words for only part of it sends only that part.
_G.NEXT_REPLY = {zones = {{
    name = "bare", scoring = "kills",
    players = 0, bots = 0, instances = {{address = "wss://x/b"}},
}}}
message(last(), "ignored")
check("a partial format is what it stated and no more",
      dir.rows[1] and dir.rows[1].scoring == "kills"
      and dir.rows[1].teams == "" and dir.rows[1].time == "",
      tostring(dir.rows[1] and dir.rows[1].scoring))

-- Full is the instance's own answer to "am I out of room", and the row carries
-- it so a full game keeps its counts instead of wearing the dial that means
-- nobody is running one.
_G.NEXT_REPLY = {zones = {{
    name = "packed", players = 32, bots = 0,
    instances = {{address = "wss://x/a1", full = true}},
}}}
message(last(), "ignored")
check("a full zone says so on its row", dir.rows[1] and dir.rows[1].full == true)
_G.NEXT_REPLY = {zones = {{
    name = "roomy", players = 2, bots = 0,
    instances = {{address = "wss://x/a1"}},
}}}
message(last(), "ignored")
check("and one with seats does not", dir.rows[1] and dir.rows[1].full == false)

-- --- the game a client with no choice of its own opens on -------------------
--
-- `dir.head` is what the landing dials for its backdrop and what its one key
-- joins, and the whole screen is drawn behind that connection. It used to be
-- the head of `rows`, which is sorted alphabetically for reading: a deployment
-- running five games had five chances for the alphabet to put a game with no
-- arena behind it first, and the client showed a wordmark on a starfield with
-- four games running and nothing on screen saying why.
--
-- The reference deployment is exactly that shape. Its rows sort Capture the
-- Flag, Duel, Free Roam, Team Battle, Turf, and the front door it names is
-- melee.

local FLEET = {
    default_zone = "melee",
    zones = {
        {name = "duel", label = "Duel", players = 0, bots = 0,
         instances = {{address = "wss://x/d"}}},
        {name = "roam", label = "Free Roam", players = 0, bots = 0,
         instances = {{address = "wss://x/r"}}},
        {name = "melee", label = "Team Battle", players = 4, bots = 4,
         instances = {{address = "wss://x/m"}}},
    },
}

-- A deep copy, so a case that drops an arena cannot leak into the next.
local function fleet(edit)
    local out = {default_zone = FLEET.default_zone, zones = {}}
    for i, z in ipairs(FLEET.zones) do
        out.zones[i] = {name = z.name, label = z.label, players = z.players,
                        bots = z.bots,
                        instances = {{address = z.instances[1].address}}}
    end
    if edit then edit(out) end
    return out
end

_G.NEXT_REPLY = fleet()
message(last(), "ignored")
check("the list still reads alphabetically",
      dir.rows[1] and dir.rows[1].zone == "duel",
      tostring(dir.rows[1] and dir.rows[1].zone))
check("but the way in is the front door the deployment named",
      dir.head() and dir.head().zone == "melee",
      tostring(dir.head() and dir.head().zone))

-- The front door down is the case that has to fall through rather than stop:
-- there are two other games running and one of them is the answer.
_G.NEXT_REPLY = fleet(function(f)
    for _, z in ipairs(f.zones) do
        if z.name == "melee" then z.instances = {} end
    end
end)
message(last(), "ignored")
check("a front door with no arena falls through to one that has",
      dir.head() and dir.head().zone == "duel",
      tostring(dir.head() and dir.head().zone))

-- And an alphabetically earlier game being down does not take the fleet with
-- it, which is the failure this exists for.
_G.NEXT_REPLY = fleet(function(f)
    for _, z in ipairs(f.zones) do
        if z.name == "duel" then z.instances = {} end
    end
end)
message(last(), "ignored")
check("a dead head of the list is skipped, not taken",
      dir.head() and dir.head().zone == "melee",
      tostring(dir.head() and dir.head().zone))

-- Nothing running at all is still a row to press. The join waits, which is
-- what a fleet that is down should feel like, rather than a screen with no
-- answer on it.
_G.NEXT_REPLY = fleet(function(f)
    for _, z in ipairs(f.zones) do z.instances = {} end
end)
message(last(), "ignored")
check("a fleet with nothing up still names a game",
      dir.head() and dir.head().zone == "duel",
      tostring(dir.head() and dir.head().zone))

-- A directory from before the field says nothing about a front door, and the
-- list answers for itself.
_G.NEXT_REPLY = {zones = {
    {name = "duel", label = "Duel", players = 0, bots = 0, instances = {}},
    {name = "melee", label = "Team Battle", players = 4, bots = 0,
     instances = {{address = "wss://x/m"}}},
}}
message(last(), "ignored")
check("a directory that names no front door still skips what is down",
      dir.default_zone == "" and dir.head() and dir.head().zone == "melee",
      tostring(dir.head() and dir.head().zone))

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
