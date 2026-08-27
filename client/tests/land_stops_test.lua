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

-- A kit is 23 slots. Two builds that differ in the first slot are two
-- different answers to `matching_profile`.
local function kit(first)
    local out = {}
    for i = 1, 23 do out[i] = 0 end
    out[1] = first
    return out
end

local account = {
    name = "", token = nil, claimed = false, load = function() end,
    base = "http://meta", kits = {}, profiles = {},
}
account.save_kit = function(class, k) account.kits[class] = k end
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

-- A pilot at home in the stands: an Apex whose saved kit is the Gunner
-- build, and one other build to pick.
menu.home = true
menu.spectate = false
menu.class = 0
account.profiles = {
    {name = "Gunner", kit = kit(3)},
    {name = "Bomber", kit = kit(5)},
}
account.kits = {Apex = kit(3)}

check("the stop says the build the next deploy flies",
      menu.landing_ship() == "Gunner",
      "said " .. tostring(menu.landing_ship()))

local rows = menu.landing_ships()
check("the list is the builds and sitting out",
      #rows == 3 and rows[1].label == "Gunner" and rows[2].label == "Bomber"
      and rows[3].label == "spectate",
      "got " .. #rows .. " rows")
check("sitting out is the last row",
      rows[3].value == "spectate")
check("the build in hand wears the mark",
      rows[1].here == true and not rows[2].here and not rows[3].here)

-- A pick loads that build as the kit in hand and answers with the act the
-- ship page's own row answers with. The arena runs that act and it saves the
-- kit to the account at once, which this plays the arena's part of: the
-- label below reads the account, so the save is what makes the pick stick.
local act = menu.pick_profile(2)
check("picking a build is the ship page's own act", act == "kit")
if act == "kit" then account.save_kit("Apex", menu.kit) end
check("and the kit in hand is that build",
      menu.kit and menu.kit[1] == 5,
      "slot 1 holds " .. tostring(menu.kit and menu.kit[1]))
check("and the stop now says so", menu.landing_ship() == "Bomber")

-- Sitting out is remembered; picking a build takes it back off, because
-- picking a build means arriving in one.
menu.spectate = true
check("a remembered spectate is the stop's answer",
      menu.landing_ship() == "spectate")
check("and wears the mark in the list",
      menu.landing_ships()[3].here == true)
if menu.pick_profile(1) == "kit" then account.save_kit("Apex", menu.kit) end
check("picking a build takes spectate off", menu.spectate == false)
check("and the stop follows", menu.landing_ship() == "Gunner")

-- The label follows the account without clobbering an edit. A build chosen
-- elsewhere lands in `account.kits` and the stop picks it up; a kit mid-tune
-- in the hangar does not get reloaded out from under the tuner.
account.kits.Apex = kit(5)
check("a build saved elsewhere reaches the stop",
      menu.landing_ship() == "Bomber")
menu.kit_step(0, 1)
local edited = menu.kit[1]
account.kits.Apex = kit(3)
check("an edit in hand is not reloaded away",
      menu.kit[1] == edited and menu.landing_ship() ~= nil,
      "slot 1 holds " .. tostring(menu.kit[1]))

print(fails == 0 and "all land stop checks passed"
      or (fails .. " land stop checks failed"))
os.exit(fails == 0 and 0 or 1)
