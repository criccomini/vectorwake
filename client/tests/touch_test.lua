-- The stick's arithmetic, driven the way a thumb drives it.
--
--     lua5.1 client/tests/touch_test.lua
--
-- The stick turns a thumb's position into the same buttons a keyboard
-- sends, and this pins that mapping: ahead thrusts, a course to the side
-- turns toward it, and a course behind the nose is a turn like any other.
-- That last one is a decision, not an accident. A rear cone that held the
-- nose and backed up shipped and was taken out within the day because it
-- did not feel good under a thumb, so glass has no reverse at all, and
-- this test is where that stays true on purpose rather than by nobody
-- having touched the file.

package.path = "client/?.lua;" .. package.path

_G.sim = {
    BTN_LEFT = 1,
    BTN_RIGHT = 2,
    BTN_THRUST = 4,
    BTN_REVERSE = 8,
    BTN_FIRE = 16,
    BTN_BOMB = 32,
}

local touch = require("arena.touch")

local fails = 0
local function check(name, ok, detail)
    if ok then
        print("ok   " .. name)
    else
        fails = fails + 1
        print("FAIL " .. name .. (detail and ("  -- " .. detail) or ""))
    end
end

local W, H = 844, 390

-- A thumb landing, moving, lifting. The stick is relative, so every case
-- starts a fresh press at a spot on the left half that no pad owns.
local OX, OY = 250, 200
local function press()
    touch.on_touch({touch = {{id = 7, pressed = true,
                              screen_x = OX, screen_y = OY}}}, W, H, 1)
end
local function drag(dx, dy)
    touch.on_touch({touch = {{id = 7,
                              screen_x = OX + dx, screen_y = OY + dy}}},
                   W, H, 1)
end
local function lift()
    touch.on_touch({touch = {{id = 7, released = true,
                              screen_x = OX, screen_y = OY}}}, W, H, 1)
end

local function has(list, bit)
    for _, b in ipairs(list) do if b == bit then return true end end
    return false
end

-- A drag of `mag` pixels at `deg` degrees off the nose, against a ship
-- heading north, which is screen up: 0 degrees is dead ahead, 180 dead
-- astern, positive to the right.
local function ask(deg, mag)
    local a = math.rad(deg)
    press()
    drag(math.sin(a) * mag, math.cos(a) * mag)
    local bits = touch.bits(0)
    lift()
    return bits
end

-- Dead ahead, committed: the engine lights and nothing else does.
local b = ask(0, 60)
check("dead ahead thrusts", has(b, sim.BTN_THRUST))
check("and only thrusts", #b == 1, #b .. " bits")

-- Off to the side: a turn, and no thrust while the nose is that far from
-- the ask.
b = ask(90, 60)
check("a course to the right turns right",
      has(b, sim.BTN_RIGHT) and not has(b, sim.BTN_LEFT))
check("and does not thrust yet", not has(b, sim.BTN_THRUST))
b = ask(-90, 60)
check("a course to the left turns left",
      has(b, sim.BTN_LEFT) and not has(b, sim.BTN_RIGHT))

-- A resting thumb inside the dead zone asks nothing.
b = ask(180, 8)
check("a thumb that barely moved does nothing", #b == 0, #b .. " bits")

-- Courses behind the nose, at and around dead astern: every one is a turn
-- toward the ask, and none is a reverse. Glass has no reverse.
for _, deg in ipairs({150, 170, 179, -170, -150}) do
    b = ask(deg, 60)
    local turning = has(b, sim.BTN_LEFT) or has(b, sim.BTN_RIGHT)
    check(deg .. " degrees astern is a turn like any other",
          turning and not has(b, sim.BTN_REVERSE))
end

-- Lifting the thumb clears the ask.
check("after the lift the stick is quiet", #touch.bits(0) == 0)

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
