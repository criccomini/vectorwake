-- A side the room would not give, and the words that come back.
--
--     lua5.1 client/tests/no_team_test.lua
--
-- The client will not send the ask on a part-full bar, so the refusals that
-- reach a player through this message are the ones it could not have seen
-- coming. The one worth having is the last: whole when the key went down, a
-- round short by the time the room read it. That used to arrive as a team
-- list saying where the pilot already was, which reads as a key that did
-- nothing. See decision 150.
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

-- `[S2C_NOTEAM, why]`, which is the whole message.
local function refuse(why)
    sock.cb(nil, 1, {event = "message", message = string.char(20, why)})
end

net.connect("ws://x", 0, "me", function() end, "alpha", false)
check("the socket was dialled", sock.cb ~= nil)

check("nothing is pending before the room says anything", net.no_team == nil)

-- --- every reason the room can give ----------------------------------------

refuse(5)
check("a hit that landed while the ask was in the air says so",
      net.no_team == "a hit landed while that was on its way", net.no_team)

-- And it is read once. The arena drains it into the note or the feed, and a
-- reason left standing would be shown again the next time a panel opened.
net.no_team = nil
check("and it is not still there once it has been read", net.no_team == nil)

refuse(4)
check("a pilot waiting to respawn is told that instead",
      net.no_team == "not while you are waiting to respawn", net.no_team)

refuse(3)
check("a full side says it is full", net.no_team == "that side is full",
      net.no_team)

refuse(2)
check("a private side says it is private",
      net.no_team == "that side is private", net.no_team)

refuse(1)
check("and a side that was reaped between the reading and the ask says so",
      net.no_team == "that side is gone", net.no_team)

-- --- a reason this build does not know --------------------------------------
--
-- The words are here rather than on the wire, so a zone one release ahead can
-- name a reason this client has never heard of. Saying nothing is right;
-- inventing a sentence, or printing a number at a player, is not.

net.no_team = nil
refuse(200)
check("a reason this build has no words for says nothing at all",
      net.no_team == nil, tostring(net.no_team))

-- --- and a fresh connection starts with none --------------------------------
--
-- It belongs to one ask in one room. Carried across a connection it would
-- answer a key pressed in a room that is gone.

refuse(3)
net.connect("ws://y", 0, "me", function() end, "alpha", false)
check("a new connection carries no refusal into the room",
      net.no_team == nil, tostring(net.no_team))

if fails > 0 then
    print(fails .. " failed")
    os.exit(1)
end
print("all good")
