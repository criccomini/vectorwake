-- The landing's ship stop, on the menu's side of the glass.
--
--     lua5.1 client/tests/land_stops_test.lua
--
-- The stop's label and its list come from `hull_name` and `hull_rows`,
-- and a press in the list goes through `pick_profile`. What is worth pinning
-- is the contract the landing draws against: the label is the ship's own
-- name, the list is the roster and nothing else, a pick asks the arena for
-- that hull, and none of it clobbers a kit somebody is mid-tune on.
--
-- Sitting out was the last row of that list and the stop's other answer until
-- decision 136 took handing a seat back off the ship menu. landing_test.lua
-- holds the drawing half.

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

-- A pilot in the stands, flying an Apex.
menu.adrift = false
menu.watching = true
menu.class = 0

check("the stop says the ship a seat would be taken in",
      menu.hull_name() == "Apex",
      "said " .. tostring(menu.hull_name()))

local rows = menu.hull_rows()
check("the list is the roster and nothing else",
      #rows == 7 and rows[1].label == "Apex" and rows[2].label == "Wedge"
      and rows[7].label == "Lattice",
      "got " .. #rows .. " rows")
check("every row names a hull to fly",
      rows[1].value == 0 and rows[7].value == 6)
check("the ship being flown wears the mark",
      rows[1].here == true and not rows[2].here and not rows[7].here)

-- A pick answers with the act the roster's own row answers with, and asks the
-- arena for that hull. The arena is what actually moves `menu.class`, because
-- a hull is the simulation's answer and it can refuse: this plays that part.
local act = menu.pick_profile(1)
check("picking a ship is the roster's own act", act == "ship")
check("and it asks the arena for that hull", menu.pending == 1)
menu.class = 1
check("and the stop follows once the arena agrees",
      menu.hull_name() == "Wedge")

menu.pick_profile(0)
menu.class = 0

-- A hull the roster does not have is refused rather than half applied.
menu.pending = nil
check("a hull off the end of the roster is not a pick",
      menu.pick_profile(99) == nil and menu.pending == nil)

