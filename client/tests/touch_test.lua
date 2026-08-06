-- The stick's arithmetic, driven the way a thumb drives it.
--
--     lua5.1 client/tests/touch_test.lua
--
-- The stick turns a thumb's position into the same buttons a keyboard
-- sends, and the rear cone makes that mapping worth a test: dead astern is
-- reverse with the nose held, a course outside the cone turns as it always
-- did, and the boundary between them decides whether a player can still
-- come about. All of it is angles, so it is checked as angles, through the
-- real on_touch path rather than by poking the module's internals.

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

-- Dead astern, committed: reverse, with the nose held. No rudder, because
-- a retreat that slewed the nose would take the guns off what it is
-- retreating from.
b = ask(180, 60)
check("dead astern reverses", has(b, sim.BTN_REVERSE))
check("with the nose held",
      not (has(b, sim.BTN_LEFT) or has(b, sim.BTN_RIGHT)))
check("and no forward thrust", not has(b, sim.BTN_THRUST))
check("the stick reports it for the chevrons", touch.reversing == true)

-- Astern but not committed: inside the thrust ring nothing fires, the same
-- rule the forward gesture has always had.
b = ask(180, 30)
check("a timid pull astern does nothing", #b == 0, #b .. " bits")
check("and does not claim reverse", touch.reversing == false)

-- The cone's edges, both sides. REAR is 0.61 radians, just under 35
-- degrees, so 150 is inside it and 140 is a turn.
b = ask(150, 60)
check("well inside the cone still reverses", has(b, sim.BTN_REVERSE))
b = ask(-150, 60)
check("on either side", has(b, sim.BTN_REVERSE))
b = ask(140, 60)
check("outside the cone the ship comes about",
      has(b, sim.BTN_RIGHT) and not has(b, sim.BTN_REVERSE))
b = ask(-140, 60)
check("in both directions",
      has(b, sim.BTN_LEFT) and not has(b, sim.BTN_REVERSE))

-- A turnaround cannot fall into the cone: the cone tracks the heading, and
-- the nose only ever closes on the ask. With the nose already halfway
-- round, the same world-fixed thumb reads as an ordinary turn.
press()
drag(math.sin(math.rad(140)) * 60, math.cos(math.rad(140)) * 60)
local mid = touch.bits(math.floor(70 / 360 * 65536))
lift()
check("a turn in progress stays a turn",
      has(mid, sim.BTN_RIGHT) and not has(mid, sim.BTN_REVERSE))

-- Lifting the thumb clears everything, including the claim to be backing
-- up. The ask itself reverses; what matters is what is left after it.
ask(180, 60)
check("after the lift the stick is quiet", #touch.bits(0) == 0)
check("and reverse is withdrawn", touch.reversing == false)

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
