-- Pickup audio begins at predicted contact, while the server's result still
-- controls the visual outcome and any rust warning.

package.path = "client/?.lua;" .. package.path

local fails = 0
local function check(name, ok)
    if ok then
        print("ok   " .. name)
    else
        fails = fails + 1
        print("FAIL " .. name)
    end
end

_G.sim = {
    ship_count = function() return 1 end,
    ship_active = function() return 1 end,
    ship_x = function() return 12 end,
    ship_y = function() return 34 end,
}

local waves, bursts = 0, 0
package.loaded["arena.fx"] = {
    wave = function() waves = waves + 1 end,
    burst = function() bursts = bursts + 1 end,
}

local world = require("arena.world")
local sounds = {}
local function sound(name, x, y)
    sounds[#sounds + 1] = {name = name, x = x, y = y}
end

world.prize_touch(0, sound)
check("touch plays the pickup sound immediately",
      #sounds == 1 and sounds[1].name == "prize"
      and sounds[1].x == 12 and sounds[1].y == 34)

world.prize(0, 0, 1, sound, true)
check("a matched positive result does not play twice", #sounds == 1)
check("the authoritative result still draws its effect",
      waves == 1 and bursts == 1)

world.prize(0, 0, 1, sound, false)
check("an unmatched positive result still has audio",
      #sounds == 2 and sounds[2].name == "prize")

world.prize(0, 0, -1, sound, true)
check("rust keeps its authoritative warning",
      #sounds == 3 and sounds[3].name == "rust")

if fails > 0 then os.exit(1) end
print("all fine")
