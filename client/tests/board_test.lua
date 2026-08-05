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
ui.menu({depth = 2, sel = 1, closable = true,
         home = false, board = true, rows = {}})
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
ui.menu({depth = 2, sel = 1, closable = true,
         home = false, board = true,
         rows = {{label = "steer", detail = "left thumb", index = 1}}})
ui.finish()
check("a touchscreen gets rows, not a picture of keys", #frames == 0,
      "frames: " .. #frames)

-- Every colour the board lights a key in has a word under it, and the words
-- are the whole of the explanation now that the line of prose naming the
-- interface keys is gone.
local LEGEND_WORDS = {}
for _, w in ipairs({"fly", "guns", "multifire", "bombs", "charges", "players",
                    "map", "menu"}) do
    LEGEND_WORDS[w] = true
end

-- The page takes the room a desktop window has, and gives it back when the
-- window has not got it. Both directions bound the same drawing: the board
-- is as tall as it is wide, so a short window is as much a limit as a narrow
-- one, and the width backs off until the whole thing fits.
local function draw_at(w, h)
    -- The recorder flips y against H, so that has to be this window's height
    -- before anything is drawn into it.
    H = h
    frames, rects = {}, {}
    st.n = 0
    ui.begin(layer, w, h, 1, false)
    ui.menu({depth = 2, sel = 1, closable = true,
             home = false, board = true, rows = {}})
    ui.finish()
    local x0, x1, y0, y1 = math.huge, 0, math.huge, 0
    for _, f in ipairs(frames) do
        x0, x1 = math.min(x0, f.x), math.max(x1, f.x + f.w)
        y0, y1 = math.min(y0, f.y), math.max(y1, f.y + f.h)
    end
    -- How far right the keys themselves reach, which is the board's own
    -- width and what the legend under it has to stay inside.
    local keyx1 = x1
    -- The captions hang below the last key row, so the drawing reaches
    -- further down than the keys do. Take the text into account or the fit
    -- check passes on a page whose last line is off the bottom.
    local legend = 0
    for k = 1, st.n do
        local t = st.text[k]
        y1 = math.max(y1, h - t.y + t.px)
        local reach = t.x + (t.pivot ~= "right" and #t.s * t.px * 0.62 or 0)
        x1 = math.max(x1, reach)
        if LEGEND_WORDS[t.s] then legend = math.max(legend, reach) end
    end
    return {x0 = x0, x1 = x1, y0 = y0, y1 = y1, keyx1 = keyx1,
            legend = legend, keyh = frames[1] and frames[1].h}
end

for _, shape in ipairs({{1280, 800}, {1920, 1080}, {900, 600}, {1400, 400},
                        {700, 500}}) do
    local b = draw_at(shape[1], shape[2])
    check(string.format("%dx%d keeps the board on screen", shape[1], shape[2]),
          b.x0 >= 0 and b.x1 <= shape[1] and b.y0 >= 0 and b.y1 <= shape[2],
          string.format("extent %.0f..%.0f x %.0f..%.0f", b.x0, b.x1, b.y0, b.y1))
end

-- The legend wraps rather than running off the end of the board. Eight
-- colours and their words fit across a wide board and do not fit across a
-- narrow one, and a line that overflowed would carry away the last two of
-- them. Since the captions naming those keys are gone, the legend is the only
-- place the page says what they are.
for _, shape in ipairs({{1280, 800}, {1920, 1080}, {1400, 400}, {900, 600},
                        {700, 500}}) do
    local b = draw_at(shape[1], shape[2])
    check(string.format("%dx%d keeps the legend inside the board",
                        shape[1], shape[2]),
          b.legend > 0 and b.legend <= b.keyx1 + 1,
          string.format("legend reaches %.0f, board ends %.0f", b.legend,
                        b.keyx1))
end

-- And the point of all of it: on a desktop window the keys are drawn at a
-- size somebody can read across a desk, not at the width of a phone's menu
-- column. Forty points is comfortably past what the fixed 460 column gave.
local big = draw_at(1280, 800)
check("a desktop window draws a readable board", (big.keyh or 0) > 40,
      "key height " .. tostring(big.keyh))

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
