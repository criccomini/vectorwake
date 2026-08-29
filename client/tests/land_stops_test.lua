-- The landing's ship stop, on the menu's side of the glass.
--
--     lua5.1 client/tests/land_stops_test.lua
--
-- The stop's label and its list come from `landing_ship` and `landing_ships`,
-- and a press in the list goes through `pick_profile`. What is worth pinning
-- is the contract the landing draws against: the label is the profile's own
-- name or spectate, the list is builds by name with sitting out last, a pick
-- loads that build as the kit in hand and takes a remembered spectate off,
-- and none of it clobbers a kit somebody is mid-tune on in the hangar.
-- landing_test.lua holds the drawing half.

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

local account = {
    name = "", token = nil, claimed = false, load = function() end,
    base = "http://meta",
}
package.loaded["arena.account"] = account
package.loaded["arena.net"] = {
    teams = {}, my_team = 0, may_found = false,
    my_team_name = function() return "" end,
    transport = function() return {} end,
    protocol = 5, invite = function() end,
}
package.loaded["arena.callsign"] = {
    roll = function() return "Probe 1" end,
    seed = function() end,
    generate = function() return "Probe 1" end,
}
package.loaded["arena.directory"] = {
    rows = {}, note = "", tick = function() end, aim = function() end,
    pilot_name = "",
}
package.loaded["arena.sfx"] = {ui = function() end, master_gain = function() end,
                               music_gain = function() end}

-- Enough of the core for a kit to survive `open_kit`: ceilings that admit
-- what the saved builds hold, so nothing here is about trimming.
_G.sim = {
    kit_ceilings = function()
        local t = {}
        for i = 1, 23 do t[i] = 9 end
        return t
    end,
}
_G.sys = {get_config_string = function(_, d) return d end,
          get_config_int = function(_, d) return d end,
          get_engine_info = function() return {version = "test"} end,
          get_save_file = function() return "/tmp/vw-land-stops-test" end,
          load = function() return {} end,
          save = function() return true end,
          set_update_frequency = function() return true end,
          get_sys_info = function() return {system_name = "Linux"} end}
_G.sound = setmetatable({}, {__index = function() return function() end end})
_G.html5 = nil
_G.hash = function(s) return s end

local menu = require("arena.menu")

-- A pilot at home in the stands, flying an Apex.
menu.home = true
menu.spectate = false
menu.class = 0

check("the stop says the ship the next deploy flies",
      menu.landing_ship() == "Apex",
      "said " .. tostring(menu.landing_ship()))

local rows = menu.landing_ships()
check("the list is the roster and sitting out",
      #rows == 8 and rows[1].label == "Apex" and rows[2].label == "Wedge"
      and rows[8].label == "spectate",
      "got " .. #rows .. " rows")
check("sitting out is the last row", rows[8].value == "spectate")
check("the ship being flown wears the mark",
      rows[1].here == true and not rows[2].here and not rows[8].here)

-- A pick answers with the act the roster's own row answers with, and asks the
-- arena for that hull. The arena is what actually moves `menu.class`, because
-- a hull is the simulation's answer and it can refuse: this plays that part.
local act = menu.pick_profile(1)
check("picking a ship is the roster's own act", act == "ship")
check("and it asks the arena for that hull", menu.pending == 1)
menu.class = 1
check("and the stop follows once the arena agrees",
      menu.landing_ship() == "Wedge")

-- Sitting out is remembered; picking a ship takes it back off, because
-- picking a ship means arriving in one.
menu.spectate = true
check("a remembered spectate is the stop's answer",
      menu.landing_ship() == "spectate")
check("and wears the mark in the list",
      menu.landing_ships()[8].here == true)
check("sitting out is a pick of its own",
      menu.pick_profile("spectate") == "spectate" and menu.spectate == true)
menu.pick_profile(0)
check("picking a ship takes spectate off", menu.spectate == false)

-- A hull the roster does not have is refused rather than half applied.
menu.pending = nil
check("a hull off the end of the roster is not a pick",
      menu.pick_profile(99) == nil and menu.pending == nil)

