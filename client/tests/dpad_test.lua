-- The d-pad, which is the other thing a flying thumb can be.
--
--     lua5.1 client/tests/dpad_test.lua
--
-- It fails quietly. A wrong pad still flies the ship, it just answers a thumb
-- with the wrong button, which reads as bad handling rather than as a bug and
-- gets blamed on the idea instead of on the code. The pad is anchored at the
-- resting mark and fresh turns ramp up to the hull's rate, so what is checked
-- here is every angle of press against the anchor, the share of frames a
-- young turn is allowed, and what the stick still does when the setting is
-- off. Frames advance only through touch.step, which the tests drive at
-- sixty a second the way the arena does.

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

-- Switched to the pad, a thumb no longer names a heading. It names a push
-- against the anchored pad, and the heading it is handed stops mattering at
-- all: the same press has to give the same buttons whatever the ship is doing.
touch.dpad = true

-- The pad is anchored at the resting mark, so a press is already a direction:
-- the anchor plus `distance` toward `degrees`, clockwise from straight up the
-- screen. No drag, which is most of the point.
local home = touch.layout(W, H, 1).home

local function pad_press(degrees, distance)
    touch.release_all()
    local rad = degrees * math.pi / 180
    touch.on_touch({touch = {{id = 1, pressed = true,
                              x = home.x + math.sin(rad) * distance,
                              y = home.y + math.cos(rad) * distance}}},
                   W, H, 1, nil)
end

local function pad(degrees, heading)
    pad_press(degrees, 40)
    return held(touch.bits(heading_of(heading or 0)))
end

-- A held thumb, watched for `n` frames at sixty a second: how many carried a
-- turn bit, and how many the engine.
local function frames(n)
    local turns, thrusts = 0, 0
    for _ = 1, n do
        touch.step(1 / 60)
        local b = held(touch.bits(heading_of(0)))
        if b[sim_stub.BTN_LEFT] or b[sim_stub.BTN_RIGHT] then
            turns = turns + 1
        end
        if b[sim_stub.BTN_THRUST] then thrusts = thrusts + 1 end
    end
    return turns, thrusts
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

-- --- the anchor -----------------------------------------------------------

-- A tap works, and works immediately. The accumulator seeds full so the first
-- frame of a fresh turn always answers; a pad that waited a frame to say
-- anything would read as broken exactly when a tap is quickest.
pad_press(90, 40)
check("a tap answers on the frame it lands",
      held(touch.bits(heading_of(0)))[sim_stub.BTN_RIGHT])

-- The direction is the thumb against the anchor, not against the press. A
-- press on the right arm dragged to above the anchor is thrust, which is what
-- lets a held thumb slide between arms without lifting.
pad_press(90, 40)
touch.on_touch({touch = {{id = 1, x = home.x, y = home.y + 40}}},
               W, H, 1, nil)
bits = held(touch.bits(heading_of(0)))
check("the thumb is read against the anchor, not the press",
      only(bits, sim_stub.BTN_THRUST))

-- The middle is inert: a thumb resting on the anchor is resting.
pad_press(37, 5)
check("a thumb on the anchor itself is not a push",
      not next(held(touch.bits(heading_of(0)))))

-- --- the ramp --------------------------------------------------------------

-- A fresh turn runs below the hull's rate: some early frames carry no turn
-- bit. This is the tap becoming a nudge and the end of a swing arriving
-- gently, and it must never touch the engine, which would read as mush.
pad_press(45, 40)
local young, young_thrusts = frames(12)
check("a young turn is withheld from a share of frames",
      young >= 4 and young <= 9, tostring(young))
check("while thrust rides every frame", young_thrusts == 12,
      tostring(young_thrusts))

-- Held past the ramp, every frame turns: the player decides when the turn
-- ends by letting go, at the hull's whole rate.
frames(30)
local grown = frames(10)
check("a held turn reaches the hull's full rate", grown == 10,
      tostring(grown))

-- Reversing a held turn starts the ramp over, so correcting an overshoot is
-- as gentle as the tap that caused it.
pad_press(90, 40)
frames(40)
touch.on_touch({touch = {{id = 1, x = home.x - 40, y = home.y}}},
               W, H, 1, nil)
-- The frame that sees the reversal must answer on the spot: the reset seeds
-- the accumulator full, the same as a fresh press, or the one moment a
-- correction is most urgent would be the one moment the pad said nothing.
touch.step(1 / 60)
check("and the correction answers on its first frame",
      held(touch.bits(heading_of(0)))[sim_stub.BTN_LEFT])
local corrected = frames(12)
check("reversing a held turn starts the ramp over",
      corrected >= 3 and corrected <= 9, tostring(corrected))

-- And a lifted thumb forgets everything: the next tap answers on its first
-- frame however long the last turn ran.
touch.release_all()
pad_press(-90, 40)
check("a lifted thumb resets the ramp",
      held(touch.bits(heading_of(0)))[sim_stub.BTN_LEFT])

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
bits = held(touch.bits(0))
check("and its space steers instead",
      bits[sim_stub.BTN_THRUST] and not bits[sim_stub.BTN_REVERSE])
touch.release_all()

if fails > 0 then
    print(fails .. " failed")
    os.exit(1)
end
print("all ok")
