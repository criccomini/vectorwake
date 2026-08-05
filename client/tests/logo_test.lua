-- The mark, in the two places it exists.
--
--     lua5.1 client/tests/logo_test.lua
--
-- It is drawn twice: as strokes into a mesh layer by `ui.logo`, and as a path
-- in `client/web/icon.svg`, which the page template carries as its favicon.
-- Two drawings of one shape drift, and nothing on screen would say so: the
-- tab would quietly stop matching the home screen. So this reads the shipped
-- SVG's own coordinates and holds the Lua to them.
--
-- It also checks the thing that makes the mark what it is rather than a swap
-- glyph: the two hulls pass, each nose reaching beyond the other's tail.

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

local W, H = 512, 512

-- The layer, recording the segments an outline is made of.
local segs = {}
local layer = {}
local function noop() end
for _, n in ipairs({"disc", "flush", "frame", "quad", "rect", "reset", "ring",
                    "seg_fade", "skirt", "tri", "tri_fade", "fan"}) do
    layer[n] = noop
end
layer.seg = function(_, x1, y1, x2, y2)
    segs[#segs + 1] = {x1 = x1, y1 = H - y1, x2 = x2, y2 = H - y2}
end
layer.outline = function(self, pts, w, col, cap)
    local n = #pts
    for i = 1, n, 2 do
        local j = (i + 1 < n) and i + 2 or 1
        self:seg(pts[i], pts[i + 1], pts[j], pts[j + 1], w, col, cap)
    end
end

_G.sim = setmetatable({}, {__index = function() return function() return 0 end end})
package.loaded["arena.state"] = {text = {}, n = 0, version = 0}
package.loaded["arena.touch"] = {layout = function() return {charge = {}} end,
                                 used = false}
package.loaded["arena.world"] = {build_overview = noop, forget_overview = noop,
                                 overview = function() return {grid = 0} end,
                                 radar_tiles = {}, radar_safe = {},
                                 radar_doors = {}}

local ui = require("arena.ui")

-- The shipped icon, at the scale it is drawn in: one hull unit is 7.6 units
-- of its 512 box, which is the number the mark was cut at.
local SCALE = 7.6
ui.begin(layer, W, H, 1, false)
ui.logo(W / 2, H / 2, SCALE)
ui.finish()

check("the mark is two closed hulls", #segs == 10, "segments: " .. #segs)

-- --- against the file the page actually carries ----------------------------

local f = assert(io.open("client/web/icon.svg", "r"),
                 "run me from the repository root")
local svg = f:read("*a")
f:close()

-- Every point of both paths, in the order the file lists them.
local want = {}
for d in svg:gmatch('<path d="M([^"]-)Z"') do
    -- The tile is the one path with no decimal point in it; the hulls are
    -- drawn to a tenth.
    if d:find("%.") then
        for x, y in d:gmatch("(%-?%d+%.%d+),(%-?%d+%.%d+)") do
            want[#want + 1] = {tonumber(x), tonumber(y)}
        end
    end
end
check("the icon holds two hulls of five points", #want == 10,
      "points: " .. #want)

-- The Lua draws each hull as five segments; the start of each is a vertex, in
-- the same order.
local got = {}
for _, s in ipairs(segs) do got[#got + 1] = {s.x1, s.y1} end

local worst = 0
for i = 1, math.min(#want, #got) do
    worst = math.max(worst, math.abs(want[i][1] - got[i][1]),
                     math.abs(want[i][2] - got[i][2]))
end
-- A tenth is what the file rounds to, so anything inside a quarter of a pixel
-- is the same drawing written two ways.
check("the drawn mark matches the shipped icon", worst < 0.25,
      string.format("worst corner off by %.2f px", worst))

-- --- what makes it the mark rather than a glyph ----------------------------

-- Hull one's nose is its first vertex; hull two's is its sixth. Their tails
-- are the midpoint of the flat cut, which is between the third and fourth
-- vertex of each.
local function mid(a, b) return {(a[1] + b[1]) / 2, (a[2] + b[2]) / 2} end
local nose1, nose2 = got[1], got[6]
local tail1, tail2 = mid(got[3], got[4]), mid(got[8], got[9])

-- The course is the direction a hull points, tail to nose. Taking it from one
-- tail to the other instead is a different line entirely -- the two hulls are
-- offset across the course as well as along it -- and reading the pass off
-- that axis reports the two hulls in the wrong order.
local ax, ay = nose1[1] - tail1[1], nose1[2] - tail1[2]
local m = math.sqrt(ax * ax + ay * ay)
ax, ay = ax / m, ay / m
local function along(p) return (p[1] - tail1[1]) * ax + (p[2] - tail1[2]) * ay end
check("hull one's nose reaches past hull two's tail", along(nose1) > along(tail2),
      string.format("nose at %.1f, tail at %.1f", along(nose1), along(tail2)))
check("hull two's nose reaches past hull one's tail", along(nose2) < 0,
      string.format("nose at %.1f, tail at 0", along(nose2)))

-- And they pass rather than collide: measured across the course, which is the
-- perpendicular of the same axis.
local sep = math.abs((tail2[1] - tail1[1]) * ay - (tail2[2] - tail1[2]) * ax)
check("the two fly clear of each other", sep > SCALE * 4,
      string.format("%.1f px apart", sep))

-- The axis is off vertical, which is what stops the pair reading as the swap
-- glyph it would be at rest.
local tilt = math.deg(math.atan2(ax, -ay))
check("the course is well off vertical", math.abs(tilt) > 20
      and math.abs(tilt) < 70, string.format("%.0f degrees", tilt))

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
