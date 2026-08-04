-- The help page's drawn keyboard, measured rather than looked at.
--
--     lua5.1 client/tests/board_test.lua
--
-- The board is mesh geometry nobody can see in CI, and its two easy failures
-- are silent: a key drawn over another key, and a cluster drawn outside the
-- panel. Both are plain arithmetic about rectangles, so this runs the real
-- `M.menu` against a recording layer and does the arithmetic.

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

local W, H = 1280, 800

-- The layer, recording frames and rects in bottom-left coordinates the way
-- the mesh takes them.
local frames, rects = {}, {}
local layer = {}
local function noop() end
for _, name in ipairs({"disc", "flush", "outline", "quad", "reset", "ring",
                       "seg", "seg_fade", "skirt", "tri", "tri_fade"}) do
    layer[name] = noop
end
layer.frame = function(_, x, y, w, h)
    frames[#frames + 1] = {x = x, y = H - y - h, w = w, h = h}
end
layer.rect = function(_, x, y, w, h)
    rects[#rects + 1] = {x = x, y = H - y - h, w = w, h = h}
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

ui.begin(layer, W, H, 1, false)
ui.menu({title = "help", depth = 2, sel = 1, closable = true,
         home_root = false, board = true, rows = {}})
ui.finish()

-- Every frame drawn while the board is up is a key outline; the panel edges
-- are segs and washes, so the recording is clean of them by construction.
check("the board drew a keyboard's worth of keys", #frames > 40,
      "frames: " .. #frames)

-- No key over another. Keys keep a gap by construction, so even touching is
-- a failure worth hearing about.
local overlaps = 0
for i = 1, #frames do
    for j = i + 1, #frames do
        local a, b = frames[i], frames[j]
        if a.x < b.x + b.w - 1 and b.x < a.x + a.w - 1
           and a.y < b.y + b.h - 1 and b.y < a.y + a.h - 1 then
            overlaps = overlaps + 1
        end
    end
end
check("no key is drawn over another", overlaps == 0,
      overlaps .. " overlapping pairs")

-- Everything inside the panel. The menu column is at most MENU_W wide and
-- the board gets its width minus the margins, so a key past the panel's
-- right edge means the units stopped adding up.
local minx, maxx, miny, maxy = math.huge, 0, math.huge, 0
for _, f in ipairs(frames) do
    minx = math.min(minx, f.x)
    maxx = math.max(maxx, f.x + f.w)
    miny = math.min(miny, f.y)
    maxy = math.max(maxy, f.y + f.h)
end
check("the board stays inside the screen",
      minx >= 0 and maxx <= W and miny >= 0 and maxy <= H,
      string.format("extent %d..%d x %d..%d", minx, maxx, miny, maxy))
check("the board is as wide as a board",
      maxx - minx > 300, "width " .. (maxx - minx))

-- The text stays inside the panel too: captions are the widest lines.
local st = package.loaded["arena.state"]
local wide = 0
for k = 1, st.n do
    local t = st.text[k]
    -- Monospace at t.px points advances about 0.62 of the size per glyph.
    local reach = t.x + (t.pivot == "left" and #t.s * t.px * 0.62 or 0)
    if reach > wide then wide = reach end
end
check("no caption runs off the screen", wide <= W, "reach " .. wide)

-- On a touchscreen the board yields to the thumb rows: same view, touching.
frames, rects = {}, {}
ui.begin(layer, W, H, 1, true)
ui.menu({title = "help", depth = 2, sel = 1, closable = true,
         home_root = false, board = true,
         rows = {{label = "steer", detail = "left thumb", index = 1}}})
ui.finish()
check("a touchscreen gets rows, not a picture of keys", #frames == 0,
      "frames: " .. #frames)

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
