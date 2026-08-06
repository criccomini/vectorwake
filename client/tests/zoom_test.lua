-- The small-window zoom rule, measured rather than eyeballed.
--
--     lua5.1 client/tests/zoom_test.lua
--
-- The rule runs inside the render script where CI cannot see a frame, and
-- its failure is quiet: a wrong factor is not an error, it is a phone
-- player whose world is a keyhole, noticed a week later on somebody's
-- hardware. The arithmetic is a pure function, so it is checked here as
-- arithmetic: what each kind of window sees, in world pixels, and where
-- the ships stop shrinking.

package.path = "client/?.lua;" .. package.path

local zoom = require("render.zoom")

local fails = 0
local function check(name, ok, detail)
    if ok then
        print("ok   " .. name)
    else
        fails = fails + 1
        print("FAIL " .. name .. (detail and ("  -- " .. detail) or ""))
    end
end

-- What the short axis of a window holds, in world pixels: points over the
-- factor the rule answers.
local function short_world(w, h, density)
    local f = zoom.factor(w, h, density)
    return math.min(w, h) / density / f, f
end

-- A desktop window is past the threshold and must not move at all: the
-- factor is exactly one, not nearly one, or every laptop resize would
-- nudge the world.
local _, f = short_world(1280, 800, 1)
check("a 1280x800 desktop window keeps zoom 1", f == 1, "factor " .. f)
_, f = short_world(2560, 1600, 2)
check("a retina laptop is the same window, denser", f == 1, "factor " .. f)
_, f = short_world(3840, 2160, 1)
check("a monitor keeps zoom 1", f == 1, "factor " .. f)
_, f = short_world(1024, 768, 1)
check("a tablet-sized window keeps zoom 1", f == 1, "factor " .. f)

-- A landscape phone sees the guaranteed world across its short axis. The
-- drawables are real devices: an iPhone 15 at 3x, a Pixel 8 at 2.625x.
local sw = short_world(2556, 1179, 3)
check("an iPhone's short axis holds the guarantee",
      math.abs(sw - zoom.SHORT_WORLD) < 1, "sees " .. sw)
sw = short_world(2400, 1080, 2.625)
check("a Pixel's short axis holds the guarantee",
      math.abs(sw - zoom.SHORT_WORLD) < 1, "sees " .. sw)

-- The factor never goes below the floor, however small the window: past it
-- the ships stop being readable, so a tiny window sees less rather than
-- shrinking further.
_, f = short_world(960, 320, 3)
check("a very short window stops at the floor", f == zoom.FLOOR,
      "factor " .. f)

-- Continuity at the threshold: a window one point under it backs off by a
-- sliver, not by a step. A step at the boundary is a world that jumps when
-- a browser window is dragged one pixel.
local a = select(2, short_world(zoom.SHORT_WORLD, 1000, 1))
local b = select(2, short_world(zoom.SHORT_WORLD - 1, 1000, 1))
check("the rule is continuous at the threshold",
      a == 1 and b < 1 and (a - b) < 0.01,
      string.format("%.4f then %.4f", a, b))

-- Degenerate sizes do not divide by zero or invert: the first frames of a
-- page can report zero before the canvas settles.
check("a zero-sized window answers 1", zoom.factor(0, 0, 1) == 1)
check("a missing density reads as density 1",
      zoom.factor(800, 600) == zoom.factor(800, 600, 1))

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
