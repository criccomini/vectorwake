-- The d-pad, which is the other thing a flying thumb can be.
--
--     lua5.1 client/tests/dpad_test.lua
--
-- It fails quietly. A wrong pad still flies the ship, it just answers a thumb
-- with the wrong button, which reads as bad handling rather than as a bug and
-- gets blamed on the idea instead of on the code. The arithmetic is a pure
-- function of where the thumb is, so it is checked here as arithmetic: every
-- angle of push, what it presses, and what the stick still does when the
-- setting is off.

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

local sim_stub = {BTN_LEFT = 1, BTN_RIGHT = 2, BTN_THRUST = 4,
                  BTN_FIRE = 8, BTN_BOMB = 16, BTN_REVERSE = 32}
package.loaded["arena.marks"] = {}
package.loaded["arena.palette"] = setmetatable({},
    {__index = function() return {0, 0, 0, 1} end})
_G.sim = sim_stub
local touch = require("arena.touch")

local W, H = 400, 800

-- Put a thumb down in the stick's half of the screen and drag it to a
-- direction, in screen degrees clockwise from the top.
local function steer(degrees, distance)
    touch.release_all()
    local px, py = 100, 200
    touch.on_touch({touch = {{id = 1, pressed = true, x = px, y = py}}},
                   W, H, 1, nil)
    local rad = degrees * math.pi / 180
    touch.on_touch({touch = {{id = 1, x = px + math.sin(rad) * distance,
                              y = py + math.cos(rad) * distance}}},
                   W, H, 1, nil)
end

local function held(bits)
    local set = {}
    for _, b in ipairs(bits) do set[b] = true end
    return set
end

-- Headings are the simulation's: 0..65535, zero north, clockwise.
local function heading_of(degrees) return degrees / 360 * 65536 end

-- With the setting off, a thumb names a compass direction and nothing about
-- this has changed. Flying north, a thumb to the east turns right.
touch.dpad = false
steer(90, 60)
local bits = held(touch.bits(heading_of(0)))
check("north up: east of a northbound ship turns right",
      bits[sim_stub.BTN_RIGHT] and not bits[sim_stub.BTN_LEFT])
-- And the same thumb on an eastbound ship turns nothing, because it is
-- already there.
steer(90, 60)
bits = held(touch.bits(heading_of(90)))
check("north up: a thumb on the current heading turns nothing",
      not bits[sim_stub.BTN_RIGHT] and not bits[sim_stub.BTN_LEFT])

-- Switched to the pad, a thumb no longer names a heading. It names a push, and
-- the heading it is handed stops mattering at all: the same push has to give
-- the same buttons whatever the ship is doing.
touch.dpad = true

local function pad(degrees, heading)
    steer(degrees, 60)
    return held(touch.bits(heading_of(heading or 0)))
end

local function only(got, ...)
    local want = {}
    for _, b in ipairs({...}) do want[b] = true end
    for _, b in pairs(sim_stub) do
        if (got[b] or false) ~= (want[b] or false) then return false end
    end
    return true
end

bits = pad(0)
check("the pad: up thrusts and turns nothing",
      only(bits, sim_stub.BTN_THRUST))
bits = pad(180)
check("the pad: down backs up", only(bits, sim_stub.BTN_REVERSE))
bits = pad(90)
check("the pad: right turns right and does not thrust",
      only(bits, sim_stub.BTN_RIGHT))
bits = pad(-90)
check("the pad: left turns left and does not thrust",
      only(bits, sim_stub.BTN_LEFT))

-- The diagonals are the reason for eight ways rather than four: a pilot who
-- cannot thrust while turning cannot fly this game.
bits = pad(45)
check("the pad: up and right does both",
      only(bits, sim_stub.BTN_THRUST, sim_stub.BTN_RIGHT))
bits = pad(-45)
check("the pad: up and left does both",
      only(bits, sim_stub.BTN_THRUST, sim_stub.BTN_LEFT))
bits = pad(135)
check("the pad: down and right backs up while turning",
      only(bits, sim_stub.BTN_REVERSE, sim_stub.BTN_RIGHT))
bits = pad(-135)
check("the pad: down and left backs up while turning",
      only(bits, sim_stub.BTN_REVERSE, sim_stub.BTN_LEFT))

-- Straight down arrives at either end of the sweep depending on which side of
-- it the thumb sits, and both ends have to read the same. Pinned on its own
-- because the two are far apart in the arithmetic and adjacent under a thumb.
bits = pad(179.5)
check("the pad: the bottom of the sweep backs up",
      only(bits, sim_stub.BTN_REVERSE), "just right of straight down")
bits = pad(-179.5)
check("the pad: and so does the other end of it",
      only(bits, sim_stub.BTN_REVERSE), "just left of straight down")

-- No gap anywhere in the sweep. A thumb pushed at any angle at all has to be
-- doing something, and never both thrusting and reversing.
local silent, contradictory = {}, {}
for deg = -179, 180 do
    local b = pad(deg)
    if not next(b) then silent[#silent + 1] = deg end
    if b[sim_stub.BTN_THRUST] and b[sim_stub.BTN_REVERSE] then
        contradictory[#contradictory + 1] = deg
    end
end
check("the pad answers a push from every angle", #silent == 0,
      table.concat(silent, ",", 1, math.min(#silent, 8)))
check("and never thrusts and reverses at once", #contradictory == 0,
      table.concat(contradictory, ",", 1, math.min(#contradictory, 8)))

-- Held, it keeps turning. This is the whole difference from the stick: the
-- player decides when the turn ends by letting go, rather than the arithmetic
-- deciding by arriving.
steer(90, 60)
local still_turning = true
for step = 0, 359, 10 do
    if not held(touch.bits(heading_of(step)))[sim_stub.BTN_RIGHT] then
        still_turning = false
    end
end
check("the pad keeps turning for as long as it is held", still_turning)

-- A thumb inside the dead zone does nothing, whichever way it leans.
touch.release_all()
touch.on_touch({touch = {{id = 1, pressed = true, x = 100, y = 200}}},
               W, H, 1, nil)
touch.on_touch({touch = {{id = 1, x = 104, y = 203}}}, W, H, 1, nil)
check("a thumb that has barely moved is not a push",
      not next(held(touch.bits(heading_of(0)))))

-- And the stick is still the stick with the setting off, on the same push that
-- the pad reads as a plain turn.
touch.dpad = false
steer(90, 60)
bits = held(touch.bits(heading_of(90)))
check("with the setting off the same push is a heading, not a turn",
      not bits[sim_stub.BTN_RIGHT] and not bits[sim_stub.BTN_LEFT])

-- --- the reverse pad ------------------------------------------------------

-- Down on the pad is backwards, so the held reverse pad is not drawn beside
-- one. Two controls for the same bit would be the smaller problem; the real
-- one is a target sitting where the pad's own down arm has to be pushed.
local function layout_has_reverse()
    return touch.layout(W, H, 1).reverse ~= nil
end

touch.dpad = false
check("the stick keeps its reverse pad", layout_has_reverse())
touch.dpad = true
check("the pad does not carry one as well", not layout_has_reverse())

-- Absent rather than merely undrawn: the space has to fall through to the
-- flying control, or a thumb reaching for the bottom of the pad is swallowed
-- by a target nothing is drawing any more.
--
-- Proved by pushing up from where the pad used to be. A thumb that still
-- landed on a reverse target would come back reversing; one that reached the
-- flying control comes back thrusting, and the two cannot be confused.
touch.dpad = false
local where = touch.layout(W, H, 1).reverse
touch.dpad = true
touch.release_all()
touch.on_touch({touch = {{id = 1, pressed = true, x = where.x, y = where.y}}},
               W, H, 1, nil)
touch.on_touch({touch = {{id = 1, x = where.x, y = where.y + 60}}},
               W, H, 1, nil)
bits = held(touch.bits(0))
check("and its space steers instead",
      bits[sim_stub.BTN_THRUST] and not bits[sim_stub.BTN_REVERSE])
touch.release_all()

if fails > 0 then
    print(fails .. " failed")
    os.exit(1)
end
print("all ok")
