-- Who arrived and who left, worked out from two rosters.
--
--     lua5.1 client/tests/roster_test.lua
--
-- The room broadcasts its whole roster whenever anything about it changes, and
-- the feed's join and leave lines are the difference between one of those and
-- the last. That is the cheap way to get them and it has three ways to be
-- wrong, none of which shows up until somebody is watching the feed at the
-- moment it happens.
--
-- A seat is reused the instant it is free, so a diff by ship index can watch
-- one person replace another and report nothing. A player who takes a seat, or
-- gives one up to watch, moves between the two halves of one roster and is
-- neither arriving nor leaving. And the first roster of a room is the room,
-- not an arrival: announced, it greets a player by listing everybody already
-- there, one line at a time, including them.
--
-- So the roster is built here as bytes and delivered through the socket the
-- way the zone delivers it, which tests the parse and the diff together.

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
-- The core, which a roster never reaches. Only the calls connect and
-- disconnect make on the way past are needed, and they are all resets.
_G.sim = setmetatable({}, {__index = function() return function() return 0 end end})

local net = require("arena.net")

-- --- a roster, as the zone packs one ---------------------------------------

-- `[S2C_ROSTER, n, (ship, label, rating16, games, len, name) * n,
--   wn, (label, len, name) * wn]`. Labels: 1 human, 2 bot.
local function roster(seats, watchers)
    local out = {string.char(3, #seats)}
    for _, s in ipairs(seats) do
        -- ship, label, rating(2), games, team, kills(2), deaths(2),
        -- assists(2), points(4), earned(2), then the name's length. The scores
        -- joined the roster when snapshots stopped carrying every seat: a
        -- board has to be able to name and score a pilot it is not being
        -- shown.
        out[#out + 1] = string.char(s.ship, s.bot and 2 or 1, 0, 0, 0,
                                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                                    #s.name)
            .. s.name
    end
    out[#out + 1] = string.char(#(watchers or {}))
    for _, w in ipairs(watchers or {}) do
        out[#out + 1] = string.char(1, #w) .. w
    end
    return table.concat(out)
end

local function deliver(seats, watchers)
    sock.cb(nil, 1, {event = "message", message = roster(seats, watchers)})
end

-- What the diff said, as a sorted list of "name joined" / "name left".
local function drained()
    local out = {}
    for _, c in ipairs(net.comings) do
        out[#out + 1] = c.name .. (c.joined and " joined" or " left")
    end
    net.comings = {}
    table.sort(out)
    return table.concat(out, ", ")
end

net.connect("ws://x", 0, "me", function() end, "alpha", false)
check("the socket was dialled", sock.cb ~= nil)

-- --- the first roster is the room, not an arrival --------------------------

deliver({{ship = 1, name = "Halcyon"}, {ship = 2, name = "Ridgeline"}},
        {"Vantage"})
check("nobody arrives on the first roster", drained() == "",
      "a player who has just joined is greeted with a list of everyone here")

-- --- and then it is the difference -----------------------------------------

deliver({{ship = 1, name = "Halcyon"}, {ship = 2, name = "Ridgeline"},
         {ship = 3, name = "Tideline"}}, {"Vantage"})
check("somebody arriving is one line", drained() == "Tideline joined")

deliver({{ship = 1, name = "Halcyon"}, {ship = 3, name = "Tideline"}},
        {"Vantage"})
check("and somebody leaving is one line", drained() == "Ridgeline left")

-- --- a seat reused between two rosters -------------------------------------

-- The case a diff by ship index cannot see. Ridgeline's old seat is handed to
-- somebody else and the roster still has two entries with the same indexes.
deliver({{ship = 1, name = "Halcyon"}, {ship = 3, name = "Meridian"}},
        {"Vantage"})
check("a seat changing hands is a leave and an arrival",
      drained() == "Meridian joined, Tideline left",
      "one index held two people and the diff saw one roster")

-- --- moving between flying and watching ------------------------------------

deliver({{ship = 1, name = "Halcyon"}}, {"Vantage", "Meridian"})
check("giving up a seat to watch is neither", drained() == "",
      "they are still in the room")

deliver({{ship = 1, name = "Halcyon"}, {ship = 4, name = "Vantage"}},
        {"Meridian"})
check("and taking one is neither", drained() == "")

deliver({{ship = 1, name = "Halcyon"}, {ship = 4, name = "Vantage"}}, {})
check("a watcher leaving is a leave", drained() == "Meridian left")

-- --- the machines are not people -------------------------------------------

deliver({{ship = 1, name = "Halcyon"}, {ship = 4, name = "Vantage"},
         {ship = 5, name = "vX-9", bot = true},
         {ship = 6, name = "vX-3", bot = true}}, {})
check("bots do not arrive", drained() == "",
      "fifty of them cycling would be the whole feed")

deliver({{ship = 1, name = "Halcyon"}, {ship = 4, name = "Vantage"}}, {})
check("and they do not leave", drained() == "")

-- --- a new room starts over ------------------------------------------------

net.disconnect()
net.connect("ws://y", 0, "me", function() end, "alpha", false)
deliver({{ship = 1, name = "Aperture"}, {ship = 2, name = "Spandrel"}}, {})
check("the next room seeds silently too", drained() == "",
      "the old room's people would read as having left it")

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
