-- The turning camera, and the thumb that has to steer against it.
--
--     lua5.1 client/tests/turn_test.lua
--
-- Two halves of one setting, and both fail quietly. A wrong up vector is a
-- world that turns the wrong way, which nobody sees in CI because CI never
-- draws a frame. A wrong stick frame is worse: the ship still flies, it just
-- turns for as long as a thumb is held instead of stopping where it was
-- pointed, which reads as bad handling rather than as a bug.
--
-- Both are arithmetic. So is the promise that a desktop is untouched, which is
-- the first thing checked here.

package.path = "client/?.lua;" .. package.path

local turn = require("render.turn")

local fails = 0
local function check(name, ok, detail)
    if ok then
        print("ok   " .. name)
    else
        fails = fails + 1
        print("FAIL " .. name .. (detail and ("  -- " .. detail) or ""))
    end
end

local function near(a, b) return math.abs(a - b) < 1e-9 end

-- --- the camera ------------------------------------------------------------

-- Nil is every view that did not ask, which is every desktop and every phone
-- with the setting off. It has to be exactly the vector the render script
-- passed before this existed.
local ux, uy = turn.up(nil)
check("north up is unchanged", near(ux, 0) and near(uy, 1),
      string.format("(%g, %g)", ux, uy))
local ew, eh = turn.extent(400, 900, nil)
check("north up builds exactly its own frame", ew == 400 and eh == 900,
      string.format("%g x %g", ew, eh))

-- Heading zero is north, so asking for a turn to north is asking for nothing.
-- Worth its own line: it is the seam between the two paths, and a formula that
-- was out by a quarter turn would still look plausible everywhere else.
ux, uy = turn.up(0)
check("a turn to north is the same as no turn", near(ux, 0) and near(uy, 1),
      string.format("(%g, %g)", ux, uy))

-- The four quarters. The up vector names the world direction that lands at the
-- bottom of the screen, so it points opposite the nose: flying east, west is
-- underfoot.
for _, case in ipairs({
    {name = "east", spin = math.pi / 2, x = -1, y = 0},
    {name = "south", spin = math.pi, x = 0, y = -1},
    {name = "west", spin = 3 * math.pi / 2, x = 1, y = 0},
}) do
    ux, uy = turn.up(case.spin)
    check("flying " .. case.name .. " puts its opposite underfoot",
          near(ux, case.x) and near(uy, case.y),
          string.format("(%g, %g)", ux, uy))
end

-- Whatever the angle, up stays a unit vector: a view matrix handed a longer
-- one would scale the world rather than turn it.
local worst = 0
for i = 0, 359 do
    ux, uy = turn.up(i * math.pi / 180)
    worst = math.max(worst, math.abs(math.sqrt(ux * ux + uy * uy) - 1))
end
check("up stays a unit vector at every angle", worst < 1e-9, tostring(worst))

-- The extent has to cover the frame's own corners at every angle, or the
-- corners of a turned view are built out of nothing. Checked against the
-- turned rectangle itself rather than against the formula that produced it.
--
-- Swept finely rather than degree by degree. The angle where a corner actually
-- touches the extent is not a whole number of degrees, so a coarse sweep shows
-- slack that is the sampling rather than the rule, and would let a padded
-- extent pass as a tight one.
local hw, hh = 195, 422           -- a portrait phone, in world pixels
local ok_cover, worst_slack = true, math.huge
local STEPS = 36000
for i = 0, STEPS - 1 do
    local spin = i * math.pi * 2 / STEPS
    local sw, sh = turn.extent(hw, hh, spin)
    local c, s = math.cos(spin), math.sin(spin)
    -- Every corner of the frame, turned into world axes.
    for _, corner in ipairs({{hw, hh}, {hw, -hh}, {-hw, hh}, {-hw, -hh}}) do
        local x = corner[1] * c - corner[2] * s
        local y = corner[1] * s + corner[2] * c
        if math.abs(x) > sw + 1e-9 or math.abs(y) > sh + 1e-9 then
            ok_cover = false
        end
        worst_slack = math.min(worst_slack, sw - math.abs(x))
    end
end
check("a turned frame's corners are always inside the extent", ok_cover)
-- And it is the tightest bound that does: somewhere in the sweep a corner
-- arrives at the edge with nothing to spare. An extent padded for safety would
-- cover the corners too, and would be caught here.
check("the extent is no larger than the corners need",
      worst_slack < 1e-4, tostring(worst_slack))

-- The number that matters to a phone's memory. Stated so a change to the rule
-- has to say what it costs rather than quietly costing it.
local sw = select(1, turn.extent(hw, hh, 1))
check("a portrait phone builds about 2.5x its starfield",
      math.abs((sw * sw) / (hw * hh) - 2.63) < 0.01,
      string.format("%.3fx", (sw * sw) / (hw * hh)))

-- The extent must not move as the player turns, or every frame of a held turn
-- reallocates the mesh buffer it sizes.
local a1, a2 = turn.extent(hw, hh, 0.3)
local b1, b2 = turn.extent(hw, hh, 2.9)
check("the extent is the same at every angle", a1 == b1 and a2 == b2)

-- --- what is drawn over a hull ----------------------------------------------

-- Nil is the ordinary game, and has to be the plain subtraction it replaced.
local ox, oy = turn.offset(nil, 37, -11)
check("north up moves nothing on the glass", ox == 37 and oy == -11,
      string.format("(%g, %g)", ox, oy))

-- A ship dead ahead is at the top of the screen whatever the heading, which is
-- the whole promise of the setting and the thing a nameplate has to agree with.
-- Screen y runs down, so "up" is negative.
for _, deg in ipairs({0, 37, 90, 180, 270, 313}) do
    local spin = deg * math.pi / 180
    -- 100 world pixels along the nose.
    local ax, ay = math.sin(spin) * 100, -math.cos(spin) * 100
    ox, oy = turn.offset(spin, ax, ay)
    check("what is ahead at " .. deg .. " degrees draws above the ship",
          near(ox, 0) and near(oy, -100),
          string.format("(%g, %g)", ox, oy))
end

-- And the distance is untouched: this turns the offset, it does not scale it.
worst = 0
for i = 0, 359 do
    local spin = i * math.pi / 180
    ox, oy = turn.offset(spin, 240, -70)
    worst = math.max(worst,
        math.abs(math.sqrt(ox * ox + oy * oy) - math.sqrt(240 * 240 + 70 * 70)))
end
check("turning an offset keeps its length", worst < 1e-9, tostring(worst))

-- The turn the view applies and the turn a nameplate applies are the same
-- number read opposite ways. If they ever drift apart the names slide off the
-- hulls, so they are checked against each other rather than each on its own:
-- the up vector says which world direction is underfoot, and that direction
-- has to land straight below the ship on the glass.
for i = 0, 359, 7 do
    local spin = i * math.pi / 180
    local uxv, uyv = turn.up(spin)
    ox, oy = turn.offset(spin, uxv * 50, uyv * 50)
    if not (near(ox, 0) and near(oy, 50)) then
        check("the camera turn and the glass turn agree at " .. i, false,
              string.format("(%g, %g)", ox, oy))
    end
end
check("the camera turn and the glass turn agree at every angle", true)

-- --- the thumb -------------------------------------------------------------

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
touch.shipup = false
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

-- With the world turning, the top of the screen is wherever the nose is, so
-- the same thumb means different things and the difference is the point.
touch.shipup = true
steer(0, 60)
bits = held(touch.bits(heading_of(140)))
check("world turning: a thumb at the top holds the heading",
      not bits[sim_stub.BTN_RIGHT] and not bits[sim_stub.BTN_LEFT])
check("world turning: a thumb at the top still thrusts",
      bits[sim_stub.BTN_THRUST])

steer(90, 60)
bits = held(touch.bits(heading_of(140)))
check("world turning: a thumb to the right turns right",
      bits[sim_stub.BTN_RIGHT] and not bits[sim_stub.BTN_LEFT])

steer(-90, 60)
bits = held(touch.bits(heading_of(140)))
check("world turning: a thumb to the left turns left",
      bits[sim_stub.BTN_LEFT] and not bits[sim_stub.BTN_RIGHT])

-- The one that decides whether this is a stick or a rotate key. Hold the thumb
-- still and walk the heading round to where it was pointed: the turn has to
-- stop there rather than carry on for as long as the thumb is down.
steer(90, 60)
local turned_at = nil
for step = 0, 120 do
    local b = held(touch.bits(heading_of(step)))
    if not b[sim_stub.BTN_RIGHT] and not b[sim_stub.BTN_LEFT] then
        turned_at = step
        break
    end
end
check("world turning: a held thumb stops on the heading it named",
      turned_at ~= nil and math.abs(turned_at - 90) <= 4,
      tostring(turned_at))

-- Past it, the same held thumb turns back rather than round again.
steer(90, 60)
touch.bits(heading_of(0))
bits = held(touch.bits(heading_of(120)))
check("world turning: overshooting a named heading turns back",
      bits[sim_stub.BTN_LEFT] and not bits[sim_stub.BTN_RIGHT])

-- Lifting and pressing again re-reads the screen, so the top of it means
-- "carry on" every time a thumb arrives, whatever the ship is doing.
steer(0, 60)
bits = held(touch.bits(heading_of(250)))
check("world turning: a fresh press reads the screen it landed on",
      not bits[sim_stub.BTN_RIGHT] and not bits[sim_stub.BTN_LEFT])

if fails > 0 then
    print(fails .. " failed")
    os.exit(1)
end
print("all ok")
