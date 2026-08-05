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
--
-- And it checks the lockup, which is the third place the mark appears and the
-- one nothing was watching. The mark shipped a full em and a bit tall and
-- lifted a third of an em above the line the name sits on, so it read as a
-- picture standing over a caption rather than as part of the word. Neither
-- fact is visible in the shape itself; both only exist next to the type.

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
-- Outlines are kept whole as well as broken into segments. The whole menu
-- draws over this layer, so picking the mark back out of a frame means
-- recognising it, and what it is is two closed five point hulls in the two
-- team colours: see M.logo.
local outlines = {}
layer.outline = function(self, pts, w, col, cap)
    local n = #pts
    outlines[#outlines + 1] = {pts = pts, col = col}
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
                                 radar_doors = {},
                                 HULLS = setmetatable({}, {__index = function()
                                     return {poly = {0, 0, 1, 1, 2, 0}, mid = 0}
                                 end})}

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

-- --- the lockup ------------------------------------------------------------

-- The home screen sets the name large with the mark beside it. Where the mark
-- lands is arithmetic against the type size, and arithmetic against a size
-- nobody measures is arithmetic nobody checks.
--
-- Drawn through the real menu rather than by calling the private function, so
-- what is measured is what a player is shown.
local state = package.loaded["arena.state"]

local pal = require("arena.palette")

-- One hull of the mark, or nil: a closed five point outline in one of the two
-- team colours, at full strength. Nothing else the menu draws is all three of
-- those, and if that ever stops being true this returns two candidates and the
-- caller says so rather than measuring the wrong shape.
local function mark_hulls()
    local found = {}
    for _, o in ipairs(outlines) do
        if #o.pts == 10 and o.col and (o.col[4] or 1) > 0.99 then
            for _, team in ipairs({pal.FRIEND, pal.ENEMY}) do
                if o.col[1] == team[1] and o.col[2] == team[2]
                    and o.col[3] == team[3] then
                    found[#found + 1] = o.pts
                end
            end
        end
    end
    return found
end

local function lockup(w, h)
    segs = {}
    outlines = {}
    state.n = 0
    ui.begin(layer, w, h, 1, false)
    local rail = {}
    for i, n in ipairs({"zones", "ship", "pilot", "settings", "help",
                        "about"}) do
        rail[i] = {label = n, icon = n, index = i}
    end
    ui.menu({depth = 1, sel = 0, rail = rail, rail_sel = 1, focus = "rail",
             home = true, closable = false,
             rows = {{label = "chaos", kind = "row"}}})
    ui.finish()
    -- The name, and the box the two hulls occupy beside it.
    local word = nil
    for i = 1, state.n do
        if state.text[i].s == "vectorwake" then word = state.text[i] end
    end
    local hulls = mark_hulls()
    if not word or #hulls ~= 2 then
        return nil, string.format("word %s, %d hulls", tostring(word ~= nil),
                                  #hulls)
    end
    local x0, y0, x1, y1
    for _, pts in ipairs(hulls) do
        for i = 1, #pts, 2 do
            local px, py = pts[i], h - pts[i + 1]
            x0 = math.min(x0 or px, px)
            x1 = math.max(x1 or px, px)
            y0 = math.min(y0 or py, py)
            y1 = math.max(y1 or py, py)
        end
    end
    -- state.text holds y already flipped into the layer's space; put it back
    -- into the top-down coordinates the mark was measured in.
    return {size = word.px, wx = word.x, wy = h - word.y,
            x0 = x0, y0 = y0, x1 = x1, y1 = y1}
end

local L, why = lockup(1280, 800)
check("the home screen draws the name and the mark together", L ~= nil, why)

if L then
    -- On the middle of the word, which is not the middle of its line box.
    -- `txt` centres a string in a box with descender room under it, and this
    -- name is lowercase with no descenders, so its ink and its weight both
    -- sit lower than the box does. How much lower is a judgement made against
    -- a screenshot and recorded as LOGO_DROP; what is checked here is that
    -- the mark is placed against that judgement and not against zero, and
    -- that the offset travels with the type rather than being a pixel count.
    local centre = (L.y0 + L.y1) / 2
    local drop = (centre - L.wy) / L.size
    check("the mark sits on the middle of the word, not of its line box",
          drop > 0.06 and drop < 0.20,
          string.format("%.3f em below the line box centre", drop))
    -- Shorter than the type it stands beside. A mark taller than the em is
    -- the one that made the first draft read as a picture with a caption.
    local tall = L.y1 - L.y0
    check("the mark is no taller than the type", tall < L.size,
          string.format("%.2f em tall", tall / L.size))
    check("and is not so small it reads as punctuation", tall > L.size * 0.5,
          string.format("%.2f em tall", tall / L.size))
    -- To the left of the name, clear of it: they are one lockup, not a
    -- collision.
    check("the mark sits left of the name", L.x1 < L.wx,
          string.format("mark ends at %.1f, name starts at %.1f", L.x1, L.wx))
    check("with air between them", L.wx - L.x1 > L.size * 0.05,
          string.format("%.2f em of gap", (L.wx - L.x1) / L.size))
end

-- A phone sets the name smaller. The lockup is arithmetic against the size,
-- so it has to hold at both, and a constant hiding in it shows up here.
local narrow = lockup(420, 780)
if L and narrow then
    local ndrop = ((narrow.y0 + narrow.y1) / 2 - narrow.wy) / narrow.size
    check("the lockup holds at the small size",
          math.abs(ndrop - (L.y0 + L.y1) / 2 / L.size
                   + L.wy / L.size) < 0.02,
          string.format("%.3f em against %.3f em", ndrop,
                        ((L.y0 + L.y1) / 2 - L.wy) / L.size))
    check("and the mark scales with the type",
          math.abs((narrow.y1 - narrow.y0) / narrow.size
                   - (L.y1 - L.y0) / L.size) < 0.02,
          string.format("%.2f em against %.2f em",
                        (narrow.y1 - narrow.y0) / narrow.size,
                        (L.y1 - L.y0) / L.size))
end

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
