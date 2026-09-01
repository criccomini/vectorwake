-- What the match clock says out loud, and when.
--
--     lua5.1 client/tests/clock_test.lua
--
-- Two clocks run in this game and both spend their last five seconds
-- speaking. The one counting down to a match is watched from a hangar, where
-- a pilot picking a hull is not looking at the podium; the one inside a match
-- is watched from a fight, where nobody is looking at the top of the screen
-- either, and where the last five seconds is the difference between taking a
-- shot and holding a lead.
--
-- Only the intermission spoke. The pip is on both clocks now, and this is
-- what says so, because a sound that fires twice, or never, or on the wrong
-- edge is invisible in a screenshot and obvious here.

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

-- net.lua reaches the account module on the way in, and that reaches the
-- engine. Neither has anything to do with a clock, so both are stubs.
_G.sim = setmetatable({}, {__index = function() return function() return 0 end end})
_G.sys = {get_sys_info = function() return {} end,
          get_config_string = function() return "" end,
          get_config_int = function(_, d) return d or 0 end,
          load = function() return {} end, save = function() return true end,
          get_save_file = function() return "" end}
package.loaded["arena.account"] = {token = nil, name = "",
                                   aim = function() end}
local net = require("arena.net")

-- The wire, one message at a time, with the two pieces of state the caller
-- carries between them. Answers with what the clock asked to be said.
local said, playing = nil, nil
local function tick(m)
    net.match = m
    local what
    what, said, playing = net.clock_says(said, playing)
    return what
end
local function reset()
    said, playing = nil, nil
end

-- --- the clock counting down to a match ------------------------------------

do
    reset()
    check("nothing is said before a match has been seen at all",
          tick(nil) == nil)
    check("nor with a whole intermission still to run",
          tick({playing = false, left = 25}) == nil)
    local heard = {}
    for n = 5, 1, -1 do
        heard[#heard + 1] = tick({playing = false, left = n}) or "-"
    end
    check("the last five seconds each say one thing",
          table.concat(heard, " ") == "tick tick tick tick tick",
          table.concat(heard, " "))
    -- The message repeats and the frame runs a hundred times a second.
    check("a second that repeats says nothing twice",
          tick({playing = false, left = 1}) == nil)
    check("and the whistle is the edge into the match",
          tick({playing = true, left = 180}) == "start")
    check("said once, not once a frame",
          tick({playing = true, left = 180}) == nil)
end

-- --- and the clock inside the match ----------------------------------------

do
    check("a match with time on it says nothing",
          tick({playing = true, left = 12}) == nil)
    local heard = {}
    for n = 5, 1, -1 do
        heard[#heard + 1] = tick({playing = true, left = n}) or "-"
    end
    check("its last five seconds count down the same way",
          table.concat(heard, " ") == "tick tick tick tick tick",
          table.concat(heard, " "))
    check("and repeat no more than the other clock does",
          tick({playing = true, left = 1}) == nil)
end

-- --- and the two do not set each other off ---------------------------------

do
    -- A match ending is not a match starting. The clock rolls over into an
    -- intermission and the whistle belongs to the other edge.
    check("the end of a match blows no whistle",
          tick({playing = false, left = 25}) == nil)

    -- A clock that ticks back up inside a match would have blown the whistle
    -- mid-fight, back when the whistle was hung on the count rather than on
    -- the state. This is that case.
    reset()
    tick({playing = true, left = 180})
    tick({playing = true, left = 3})
    check("a clock jumping about inside a match blows none either",
          tick({playing = true, left = 30}) == nil)

    -- Unless the room started the match over, which the message says: a
    -- duel opens a fresh match when a seat changes hands, and the pilot who
    -- was already in the room hears the whistle for it.
    reset()
    tick({playing = true, left = 40})
    local again = {playing = true, left = 180, fresh = true}
    check("a match started over blows the whistle", tick(again) == "start")
    check("once", tick(again) == nil)
    check("and spends the mark", again.fresh == nil)

    -- Somebody who joined a match already running never heard it start.
    reset()
    check("and arriving mid-match is not a start", tick({playing = true, left = 90}) == nil)

    -- A clock that stalls says where it stalled once; one that jumps says
    -- only where it landed.
    reset()
    tick({playing = true, left = 5})
    check("a clock that skips says only where it landed",
          tick({playing = true, left = 2}) == "tick")
    check("and nothing for the seconds it skipped over",
          tick({playing = true, left = 2}) == nil)

    -- Leaving the room. Nothing left to count, and the next match is a fresh
    -- arrival rather than a start anybody heard.
    reset()
    tick({playing = true, left = 60})
    check("losing the match message says nothing", tick(nil) == nil)
    check("and coming back into one is an arrival, not a start",
          tick({playing = true, left = 60}) == nil)
end

if fails > 0 then
    print(("\n%d check(s) failed"):format(fails))
    os.exit(1)
end
print("\nall good")
