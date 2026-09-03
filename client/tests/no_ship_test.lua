-- A ship the room would not deal, and the words that come back.
--
--     lua5.1 client/tests/no_ship_test.lua
--
-- The sibling of no_team_test, because it is the same hole in the other
-- message a menu sends. A ship costs a full bar and a respawn, the client
-- will not ask on less, and the core reads the bar again when the ask lands,
-- so the refusal a player actually meets is a round arriving in between. It
-- used to arrive as nothing at all: the column key closes the panel on its
-- way out, so what a player saw was a menu that did nothing. See decision 162.
--
-- Delivered as bytes through the socket, the way the zone delivers it, so
-- what is tested is the parse and not a table lookup written twice.

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

-- --- the engine, as much of it as net.lua touches --------------------------

local sock = {}
_G.websocket = {
    DATA_TYPE_BINARY = 1,
    EVENT_CONNECTED = "connected",
    EVENT_MESSAGE = "message",
    EVENT_DISCONNECTED = "disconnected",
    EVENT_ERROR = "error",
    connect = function(_, _, cb)
        sock.cb = cb
        return {id = 1}
    end,
    send = function() end,
    disconnect = function() end,
}
_G.sys = {
    get_config_string = function(_, d) return d or "" end,
    get_save_file = function() return "/dev/null" end,
    save = function() return true end,
    load = function() return {} end,
    get_engine_info = function() return {version = "test"} end,
}
_G.http = {request = function() end}
_G.json = {encode = function() return "{}" end, decode = function() return {} end}
_G.timer = {delay = function() end}
_G.sim = setmetatable({}, {__index = function() return function() return 0 end end})

local net = require("arena.net")

-- `[S2C_NOSHIP, why]`, which is the whole message.
local function refuse(why)
    sock.cb(nil, 1, {event = "message", message = string.char(21, why)})
end

net.connect("ws://x", 0, "me", function() end, "alpha", false)
check("the socket was dialled", sock.cb ~= nil)

check("nothing is pending before the room says anything", net.no_ship == nil)

-- --- every reason the core refuses a ship for -------------------------------
--
-- Three of the five a crossing can carry, by the same bytes, because what
-- refuses both is one rule in the core.

refuse(5)
check("a hit that landed while the ask was in the air says so",
      net.no_ship == "a hit landed while that was on its way", net.no_ship)

-- Read once. The arena drains it into the note or the feed, and a reason left
-- standing would be shown again the next time a panel opened.
net.no_ship = nil
check("and it is not still there once it has been read", net.no_ship == nil)

refuse(4)
check("a pilot waiting to respawn is told that instead",
      net.no_ship == "not while you are waiting to respawn", net.no_ship)

refuse(1)
check("and a seat that went while the ask was in the air says so",
      net.no_ship == "you are not in the game", net.no_ship)

-- --- the two a side has and a hull does not ---------------------------------
--
-- A side can be private or full. A hull is always there and has no seats of
-- its own, so those bytes name nothing on this message and are not words the
-- client will draw for one.

net.no_ship = nil
refuse(2)
check("a private side is not a reason a ship can be refused for",
      net.no_ship == nil, tostring(net.no_ship))
refuse(3)
check("nor is a full one", net.no_ship == nil, tostring(net.no_ship))

-- --- a reason this build does not know --------------------------------------

refuse(200)
check("a reason this build has no words for says nothing at all",
      net.no_ship == nil, tostring(net.no_ship))

-- --- the two answers do not stand in for each other -------------------------
--
-- One tag each, so a refused ship never reads as a refused crossing. They are
-- drained together and would say the wrong thing about the wrong press.

refuse(5)
check("a refused ship leaves the crossing's answer alone",
      net.no_team == nil, tostring(net.no_team))

-- --- and a fresh connection starts with none --------------------------------

net.connect("ws://y", 0, "me", function() end, "alpha", false)
check("a new connection carries no refusal into the room",
      net.no_ship == nil, tostring(net.no_ship))

-- --- where the sentence lands -----------------------------------------------
--
-- The other half of the fix, which is the half a player sees. `arena.script`
-- is a Defold script and cannot be required, so this pulls `drain_refusals`
-- out and runs it, the way kill_line_test does with the drain beside it.
--
-- A crossing leaves its panel up and reads its answer in the note. A ship
-- never does: the key that spends a draft closes the column on its way out,
-- so the feed is the only place left to say it, and a ship that landed in the
-- note alone would be a sentence nobody is looking at.

local f = assert(io.open("client/arena/arena.script"))
local src = f:read("*a")
f:close()

local body = src:match("local function drain_refusals%(%)(.-)\nend\n")
check("the arena has a drain_refusals to run", body ~= nil)
if not body then os.exit(1) end

-- One drain over whatever is standing on the wire, with the menu up or down.
-- Returns the note it set and every line it put in the feed.
local function drain(team, ship, open)
    net.no_team, net.no_ship = team, ship
    local lines, denied = {}, false
    local env = {
        net = net,
        menu = {open = open or false, note = nil},
        notify = function(text) lines[#lines + 1] = text[1] end,
        sfx = {ui = function(which) denied = denied or which == "ui_deny" end},
    }
    setmetatable(env, {__index = _G})
    local chunk = assert(loadstring("return function()" .. body .. "\nend",
                                    "drain"))
    setfenv(chunk, env)
    chunk()()
    return env.menu.note, lines, denied
end

local note, lines, denied = drain(nil, "a hit landed while that was on its way")
check("a refused ship with the column gone lands in the feed",
      #lines == 1 and lines[1] == "a hit landed while that was on its way",
      #lines .. " lines")
check("and not in a note nobody is looking at", note == nil, tostring(note))
check("and it is denied out loud", denied)
check("and read off the wire once", net.no_ship == nil, tostring(net.no_ship))

note, lines = drain(nil, "not while you are waiting to respawn", true)
check("with the column still up it is the note instead",
      note == "not while you are waiting to respawn", tostring(note))
check("and the feed is left alone", #lines == 0, #lines .. " lines")

-- Both at once is a corner, and a corner that drops one of them is the
-- silence this message exists to end. The note holds one, so the crossing
-- takes it, being the ask whose panel is still up, and the feed keeps the
-- ship.
note, lines = drain("that side is full", "a hit landed while that was on its way", true)
check("a crossing and a ship refused together both get said",
      note == "that side is full" and #lines == 1
      and lines[1] == "a hit landed while that was on its way",
      tostring(note) .. ", " .. #lines .. " lines")
check("and both are read off the wire",
      net.no_team == nil and net.no_ship == nil)

note, lines = drain(nil, nil)
check("and nothing standing says nothing at all",
      note == nil and #lines == 0, #lines .. " lines")

if fails > 0 then
    print(fails .. " failed")
    os.exit(1)
end
print("all good")
