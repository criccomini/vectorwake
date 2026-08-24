-- A browser replay route, through the fetch and into playback.
--
--     lua5.1 client/tests/deep_route_test.lua

package.path = "client/?.lua;" .. package.path

local fails = 0
local function check(name, ok, detail)
    if ok then
        print("ok   " .. name)
    else
        fails = fails + 1
        print("FAIL " .. name .. (detail and (": " .. detail) or ""))
    end
end

local ready = true
local note = nil
local asked, answer = nil, nil
local started = nil
local route = require("arena.deep_route").new({
    ready = function() return ready end,
    note = function(text) note = text end,
    fetch = function(id, callback) asked, answer = id, callback end,
    start = function(state, reply) started = {state = state, reply = reply} end,
})

local state = {deep_route = "replay/42", clock = 10}
check("a non-replay route falls through", route(state, "join/melee") == nil)
check("the replay route waits for its fetch", route(state, state.deep_route) == false
      and asked == 42 and state.replay_loading == "replay/42"
      and state.replay_tries == 1 and note == "loading match replay")

local reply = {match = 42}
answer(reply)
check("a fetched replay reaches playback",
      started and started.state == state and started.reply == reply)
check("starting clears the deep-link state",
      state.deep_route == nil and state.replay_loading == nil
      and state.replay_after == nil and state.replay_tries == nil)

state = {deep_route = "replay/43", clock = 20}
route(state, state.deep_route)
answer(nil, "no such match")
check("a match still being filed schedules a retry",
      state.deep_route == "replay/43" and state.replay_after == 21)
asked = nil
route(state, state.deep_route)
check("the retry waits one client second", asked == nil)
state.clock = 21
route(state, state.deep_route)
check("and asks again when that second arrives", asked == 43)

ready = false
state = {deep_route = "replay/44"}
asked = nil
route(state, state.deep_route)
check("replay waits for the account endpoint", asked == nil)

os.exit(fails == 0 and 0 or 1)
