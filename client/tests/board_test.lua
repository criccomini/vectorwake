-- The controls page, measured rather than looked at.
--
--     lua5.1 client/tests/board_test.lua
--
-- The page is mesh geometry nobody can see in CI, and its easy failures are
-- silent: a key drawn over another key, a cluster drawn outside the panel, a
-- chip whose key has run back under its own name, and a list of controls the
-- picture above it disagrees with. All of it is arithmetic about rectangles,
-- so this runs the real `M.menu` against a recording layer and does the
-- arithmetic.

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
-- the mesh takes them. The frame's thickness comes with it: a key with a
-- control on it is stroked heavier than an empty one, and that is the only
-- way from out here to tell a lit key from a dead one.
local frames, rects = {}, {}
local layer = {}
local function noop() end
for _, name in ipairs({"disc", "flush", "outline", "quad", "reset", "ring",
                       "seg", "seg_fade", "seg_flat", "skirt", "tri",
                       "tri_fade"}) do
    layer[name] = noop
end
layer.frame = function(_, x, y, w, h, t)
    frames[#frames + 1] = {x = x, y = H - y - h, w = w, h = h, t = t}
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
local binds = require("arena.binds")

-- The page's rows, built the way arena/menu.lua builds them, so this measures
-- the list the game actually draws rather than a list written out here.
local function chip_rows(arming)
    local rows = {}
    for i, c in ipairs(binds.rows()) do
        rows[i] = {label = c.name, detail = c.show, cat = c.cat,
                   control = c.id, key = c.key, fixed = c.fixed,
                   arming = arming == c.id, pick = true, index = i}
    end
    rows[#rows + 1] = {label = "defaults", pick = true, reset = true,
                       index = #rows + 1}
    return rows
end

local function view(sel, arming)
    return {depth = 2, sel = sel or 1, closable = true, home = false,
            board = true, chips = true, arming = arming ~= nil,
            rows = chip_rows(arming)}
end

ui.begin(layer, W, H, 1, false)
ui.menu(view(1))
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

-- The text stays inside the panel too.
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
         rows = {{label = "rudder", detail = "left thumb", index = 1}}})
ui.finish()
check("a touchscreen gets rows, not a picture of keys", #frames == 0,
      "frames: " .. #frames)

-- --- the chips --------------------------------------------------------------
--
-- The picture cannot say which of four charge keys is which, which is the
-- whole reason the chips are under it. So every control has to be named down
-- there, and its key has to be readable beside the name rather than under it.

local function draw_at(w, h, sel, arming)
    -- The recorder flips y against H, so that has to be this window's height
    -- before anything is drawn into it.
    H = h
    frames, rects = {}, {}
    st.n = 0
    ui.hits = {}
    ui.begin(layer, w, h, 1, false)
    ui.menu(view(sel, arming))
    ui.finish()
    local x0, x1, y0, y1 = math.huge, 0, math.huge, 0
    for _, f in ipairs(frames) do
        x0, x1 = math.min(x0, f.x), math.max(x1, f.x + f.w)
        y0, y1 = math.min(y0, f.y), math.max(y1, f.y + f.h)
    end
    local said, lit = {}, 0
    for _, f in ipairs(frames) do
        -- A key carrying a control is stroked at 1.1, an empty one at 0.8.
        if f.t > 1 then lit = lit + 1 end
    end
    for k = 1, st.n do
        local t = st.text[k]
        y1 = math.max(y1, h - t.y + t.px)
        local reach = t.x + (t.pivot ~= "right" and #t.s * t.px * 0.62 or 0)
        x1 = math.max(x1, reach)
        said[string.upper(t.s)] = {x = t.x, px = t.px, pivot = t.pivot,
                                   reach = reach}
    end
    return {x0 = x0, x1 = x1, y0 = y0, y1 = y1, said = said, lit = lit,
            keyh = frames[1] and frames[1].h, hits = #ui.hits}
end

for _, shape in ipairs({{1280, 800}, {1920, 1080}, {900, 600}, {1400, 400},
                        {700, 500}}) do
    local b = draw_at(shape[1], shape[2])
    check(string.format("%dx%d keeps the page on screen", shape[1], shape[2]),
          b.x0 >= 0 and b.x1 <= shape[1] and b.y0 >= 0 and b.y1 <= shape[2],
          string.format("extent %.0f..%.0f x %.0f..%.0f",
                        b.x0, b.x1, b.y0, b.y1))
end

-- Every control named, at every shape. A page that quietly drops the last two
-- chips off the bottom is the failure this is here for: the list is the only
-- place the four charge keys are told apart.
for _, shape in ipairs({{1280, 800}, {1920, 1080}, {900, 600}, {1400, 400}}) do
    local b = draw_at(shape[1], shape[2])
    local missing = {}
    for _, c in ipairs(binds.rows()) do
        if not b.said[string.upper(c.name)] then
            missing[#missing + 1] = c.name
        end
    end
    check(string.format("%dx%d names every control", shape[1], shape[2]),
          #missing == 0, table.concat(missing, ", "))
end

-- The key sits beside the name rather than back under it. Both are on one
-- chip, so the right-aligned key's left edge has to clear the end of the name.
local b = draw_at(1280, 800)
local clashes = {}
for _, c in ipairs(binds.rows()) do
    local name = b.said[string.upper(c.name)]
    local key = b.said[string.upper(c.show)]
    -- The key column is right-aligned, so `x` is its right edge; back off by
    -- what the glyphs take. Only where the two are on the same line, which a
    -- shared row height makes a question about the name's own chip.
    if name and key and key.pivot == "right" then
        local left = key.x - #c.show * key.px * 0.62
        if left < name.reach and math.abs(left - name.x) < 400 then
            clashes[#clashes + 1] = c.name
        end
    end
end
check("a chip's key clears its name", #clashes == 0,
      table.concat(clashes, ", "))

-- Every chip is pressable. The page is walked by a cursor and by a pointer,
-- and a chip with no hit box under it is a control a mouse cannot reach.
check("every chip publishes a hit box", b.hits >= #binds.rows() + 1,
      b.hits .. " boxes for " .. (#binds.rows() + 1) .. " chips")

-- Every key a control may be put on is drawn. A catalog offering a key the
-- picture does not show is a key nobody can find, and the page's whole claim
-- is that what you see is what you may press.
do
    local keys = require("arena.keys")
    local shown = draw_at(1280, 800)
    local unseen = {}
    for _, k in ipairs(keys.list) do
        -- The arrows are triangles rather than words, so they are counted by
        -- the cluster's four frames instead of by what is written on them.
        if k.label and not shown.said[string.upper(k.label)] then
            unseen[#unseen + 1] = k.id
        end
    end
    check("every bindable key is drawn on the board", #unseen == 0,
          table.concat(unseen, ", "))
end

-- Arming takes the light off the board. Every key but the one that is asking
-- drops to the outline an unbound key wears, which is what says the whole
-- keyboard is an answer.
local resting = draw_at(1280, 800, 5)
local asking = draw_at(1280, 800, 5, "guns")
check("resting, the bound keys are lit", resting.lit > 8,
      "lit " .. resting.lit)
check("arming lights one key and no other", asking.lit == 1,
      "lit " .. asking.lit)

-- And it is the key of the control that is asking, not of the row the cursor
-- happens to be on. They are the same row in the game, since arming is what
-- enter does to the row under the cursor; reading the cursor for it anyway let
-- the board light one key while the chip with the empty slot in it sat
-- somewhere else, which is the page contradicting itself in the one state it
-- exists for.
do
    local elsewhere = draw_at(1280, 800, 1, "guns")
    check("and it is the asking control's key, not the cursor's",
          elsewhere.lit == 1, "lit " .. elsewhere.lit)
end

-- And the point of all of it: on a desktop window the keys are drawn at a
-- size somebody can read across a desk, not at the width of a phone's menu
-- column.
check("a desktop window draws a readable board", (resting.keyh or 0) > 30,
      "key height " .. tostring(resting.keyh))

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
