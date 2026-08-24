-- The stick's arithmetic, driven the way a thumb drives it.
--
--     lua5.1 client/tests/touch_test.lua
--
-- The stick turns a thumb's position into the same buttons a keyboard
-- sends, and this pins that mapping: ahead thrusts, a course to the side
-- turns toward it, and a course behind the nose is a turn like any other.
-- That last one is a decision, not an accident. A rear cone that held the
-- nose and backed up shipped and was taken out within the day because it did
-- not feel good under a thumb; a second attempt read the same push as backing
-- out of a fight, lasted longer, and is gone as well. A phone has no reverse,
-- so a course behind the nose means one thing whatever else is held.

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
local function ask(deg, mag, heading)
    local a = math.rad(deg)
    press()
    drag(math.sin(a) * mag, math.cos(a) * mag)
    local bits = touch.bits(heading or 0)
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

-- The stick names a course rather than a direction to spin in, so a thumb
-- already on the ship's heading asks for no turn wherever that heading is.
-- Headings are the simulation's: 0..65535, zero north, clockwise.
b = ask(90, 60, 65536 / 4)
check("a thumb on the current heading turns nothing",
      not has(b, sim.BTN_LEFT) and not has(b, sim.BTN_RIGHT))
check("and drives the ship along it", has(b, sim.BTN_THRUST))

-- A resting thumb inside the dead zone asks nothing.
b = ask(180, 8)
check("a thumb that barely moved does nothing", #b == 0, #b .. " bits")

-- Courses behind the nose, at and around dead astern: every one is a turn
-- toward the ask, and none silently becomes reverse.
for _, deg in ipairs({150, 170, 179, -170, -150}) do
    b = ask(deg, 60)
    local turning = has(b, sim.BTN_LEFT) or has(b, sim.BTN_RIGHT)
    check(deg .. " degrees astern is a turn like any other",
          turning and not has(b, sim.BTN_REVERSE))
end

-- Lifting the thumb clears the ask.
check("after the lift the stick is quiet", #touch.bits(0) == 0)

-- --- and none of it changes while a trigger is down -------------------------
--
-- The trigger used to be half of what said "fight", and in a fight a rearward
-- push backed the ship out instead of turning it. It says nothing now: the
-- pads decide what is fired and the stick decides where the nose goes, and
-- neither reads the other.

local L = touch.layout(W, H, 1)
touch.on_touch({touch = {{id = 9, pressed = true,
                          screen_x = L.guns.x, screen_y = L.guns.y}}}, W, H, 1)
touch.on_touch({touch = {{id = 8, pressed = true,
                          screen_x = 120, screen_y = 250}}}, W, H, 1)
touch.on_touch({touch = {{id = 8, screen_x = 120, screen_y = 190}}}, W, H, 1)
local held = touch.bits(0)
check("firing, a push behind the nose is still a turn",
      (has(held, sim.BTN_LEFT) or has(held, sim.BTN_RIGHT))
          and not has(held, sim.BTN_REVERSE))
check("and the gun is still firing through it", has(held, sim.BTN_FIRE))
touch.release(9)
held = touch.bits(0)
check("letting the trigger go leaves the same turn",
      (has(held, sim.BTN_LEFT) or has(held, sim.BTN_RIGHT))
          and not has(held, sim.BTN_FIRE))
touch.release(8)

-- --- the gun's multifire gesture -------------------------------------------
--
-- Multifire stays part of the gun. One deliberate upward pull toggles it while
-- the trigger remains held, and no standalone cell can overlap the gun.

local function tap(x, y)
    touch.on_touch({touch = {{id = 3, pressed = true,
                              screen_x = x, screen_y = y}}}, W, H, 1)
    touch.on_touch({touch = {{id = 3, released = true,
                              screen_x = x, screen_y = y}}}, W, H, 1)
end

check("nothing latched before a tap", touch.fired_multi() == false)
touch.has_fan = true
L = touch.layout(W, H, 1)
tap(L.guns.x, L.guns.y)
check("a gun tap is not a toggle", touch.fired_multi() == false)

touch.on_touch({touch = {{id = 3, pressed = true,
                          screen_x = L.guns.x, screen_y = L.guns.y}}}, W, H, 1)
touch.on_touch({touch = {{id = 3,
                          screen_x = L.guns.x + 42,
                          screen_y = L.guns.y + 8}}}, W, H, 1)
check("a sideways gun pull is not a toggle", touch.fired_multi() == false)
touch.on_touch({touch = {{id = 3,
                          screen_x = L.guns.x,
                          screen_y = L.guns.y + 40}}}, W, H, 1)
check("an upward gun pull toggles once", touch.fired_multi() == true)
check("the toggle is consumed once", touch.fired_multi() == false)
check("the gun keeps firing through the gesture",
      has(touch.bits(0), sim.BTN_FIRE))
touch.on_touch({touch = {{id = 3,
                          screen_x = L.guns.x,
                          screen_y = L.guns.y + 60}}}, W, H, 1)
check("one gun hold cannot toggle twice", touch.fired_multi() == false)
touch.release(3)
check("lifting after the gesture releases the gun",
      not has(touch.bits(0), sim.BTN_FIRE))

-- Losing the fan disables the gesture without changing the gun.
touch.has_fan = false
touch.on_touch({touch = {{id = 3, pressed = true,
                          screen_x = L.guns.x, screen_y = L.guns.y}}}, W, H, 1)
touch.on_touch({touch = {{id = 3,
                          screen_x = L.guns.x,
                          screen_y = L.guns.y + 50}}}, W, H, 1)
check("without a fan the upward pull only fires",
      touch.fired_multi() == false and has(touch.bits(0), sim.BTN_FIRE))
touch.release_all()

-- A UI press can consume a whole multitouch batch. The arena forwards releases
-- through this narrow path first, so the pad held by another finger still lets
-- go even when the rest of the action belongs to the panel.
touch.has_bomb = true
L = touch.layout(W, H, 1)
touch.on_touch({touch = {{id = 9, pressed = true,
                          screen_x = L.guns.x, screen_y = L.guns.y}}}, W, H, 1)
check("a held gun reaches the buttons", has(touch.bits(0), sim.BTN_FIRE))
touch.release(9)
check("a release consumed by the UI still clears it",
      not has(touch.bits(0), sim.BTN_FIRE))

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
