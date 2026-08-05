-- The menu's rail and stage, measured rather than looked at.
--
--     lua5.1 client/tests/menu_view_test.lua
--
-- Four things here are invisible in CI and each of them has already been
-- wrong once: a stage cursor drawn while the cursor is on the rail, a list
-- longer than its room quietly showing only what fits, a rail stop with no
-- hit box under it, and a block that runs off the side of the screen when it
-- shifts to clear the corner stack. All four are arithmetic about rectangles
-- and indices, so this runs the real `M.menu` against a recording layer.

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
local frames, rects, segs = {}, {}, {}
local layer = {}
local function noop() end
for _, name in ipairs({"disc", "flush", "outline", "quad", "reset", "ring",
                       "skirt", "tri", "tri_fade", "fan", "seg_glow",
                       "glow_band", "halo", "ring_fade", "seg_fade"}) do
    layer[name] = noop
end
layer.frame = function(_, x, y, w, h)
    frames[#frames + 1] = {x = x, y = H - y - h, w = w, h = h}
end
layer.rect = function(_, x, y, w, h)
    rects[#rects + 1] = {x = x, y = H - y - h, w = w, h = h}
end
layer.seg = function(_, x0, y0, x1, y1)
    segs[#segs + 1] = {x0 = x0, y0 = y0, x1 = x1, y1 = y1}
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

local RAIL = {}
for i, n in ipairs({"play", "ship", "pilot", "settings", "help", "about"}) do
    RAIL[i] = {label = n, icon = n, index = i}
end

local function draw(view, w, h, touching)
    W, H = w or 1280, h or 800
    frames, rects, segs = {}, {}, {}
    local st = package.loaded["arena.state"]
    st.n = 0
    ui.begin(layer, W, H, 1, touching or false)
    ui.menu(view)
    ui.finish()
    return st
end

local function texts(st)
    local out = {}
    for i = 1, st.n do out[#out + 1] = st.text[i].s end
    return out
end

local function has(st, s)
    for _, t in ipairs(texts(st)) do if t == s then return true end end
    return false
end

-- --- the rail is always there, and every stop is reachable by pointer ------

local rows = {}
for i = 1, 3 do
    rows[i] = {label = "zone" .. i, detail = "", index = i, pick = true,
               players = i, bots = 4, live = true}
end
local st = draw({title = "vectorwake", stage_title = "games", depth = 1,
                 sel = 0, rail = RAIL, rail_sel = 1, focus = "rail",
                 home_root = true, closable = false, rows = rows})

local rail_hits = 0
for _, h in ipairs(ui.hits) do
    if h.action == "row" and h.value and h.value >= 1 then rail_hits = rail_hits + 1 end
end
check("every rail stop publishes a hit box", rail_hits == #RAIL,
      rail_hits .. " of " .. #RAIL)
check("the rail names its stops", has(st, "play") and has(st, "about"))
check("the stage shows what the rail points at", has(st, "zone1"))

-- --- a preview carries no cursor -------------------------------------------
--
-- `sel` counts rail stops at this level. A stage that highlighted row `sel`
-- put a cursor on the second hull while the arrow keys moved the rail.

-- The cursor is a bracket, and a bracket is segs. Drawing the same view
-- focused and unfocused must differ by exactly that.
check("a previewed stage draws no cursor bracket",
      (function()
          -- with focus on the rail nothing in the stage may be bracketed:
          -- the bracket is drawn only when `sel and focused`.
          local view = {title = "v", stage_title = "ship", depth = 1, sel = 2,
                        rail = RAIL, rail_sel = 2, focus = "rail",
                        home_root = true, closable = false, rows = rows}
          draw(view)
          local a = #segs
          view.focus = "stage"
          view.sel = 2
          draw(view)
          return #segs > a
      end)(), "focused and unfocused drew the same")

-- --- a long list scrolls rather than stopping -----------------------------

local many = {}
for i = 1, 30 do
    many[i] = {label = "row" .. i, detail = "", index = i, pick = true}
end
st = draw({title = "v", stage_title = "games", depth = 2, sel = 25,
           rail = RAIL, rail_sel = 1, focus = "stage", home_root = false,
           closable = true, rows = many})
check("a cursor near the end of a long list is on screen", has(st, "row25"),
      "drew: " .. table.concat(texts(st), " "))
-- And the other way it can go wrong: a list that draws every row regardless
-- puts most of them off the bottom of the screen, where they are as good as
-- skipped and cost vertices besides.
local below = 0
for i = 1, st.n do
    local t = st.text[i]
    -- state holds y counting up from the bottom, so off the bottom is y < 0
    if t.y < 0 or t.y > H then below = below + 1 end
end
check("and no row is drawn off the screen to get there", below == 0,
      below .. " lines outside")
st = draw({title = "v", stage_title = "games", depth = 2, sel = 1,
           rail = RAIL, rail_sel = 1, focus = "stage", home_root = false,
           closable = true, rows = many})
check("and one at the start is too", has(st, "row1"))

-- --- the block stays on screen wherever it is pushed ----------------------

for _, shape in ipairs({{1280, 800}, {900, 600}, {700, 500}, {1600, 900},
                        {390, 844}, {844, 390}}) do
    draw({title = "v", stage_title = "games", depth = 2, sel = 1,
          rail = RAIL, rail_sel = 1, focus = "stage", home_root = false,
          closable = true, rows = rows}, shape[1], shape[2])
    local x1, y1 = 0, 0
    for _, r in ipairs(rects) do
        x1 = math.max(x1, r.x + r.w)
        y1 = math.max(y1, r.y + r.h)
    end
    -- The backdrop is the whole screen, so the test is that nothing exceeds
    -- it rather than that everything is inside some margin.
    check(string.format("%dx%d keeps the menu on screen", shape[1], shape[2]),
          x1 <= shape[1] + 1 and y1 <= shape[2] + 1,
          string.format("reaches %.0f x %.0f", x1, y1))
end

-- --- settings draw as steps rather than words -----------------------------

draw({title = "v", stage_title = "settings", depth = 2, sel = 1,
      rail = RAIL, rail_sel = 4, focus = "stage", home_root = false,
      closable = true,
      rows = {{label = "sound", detail = "half", choice = 3, choices = 4,
               index = 1, pick = true}}})
local steps = 0
for _, f in ipairs(frames) do
    if math.abs(f.h - 10) < 0.01 then steps = steps + 1 end
end
local lit = 0
for _, r in ipairs(rects) do
    if math.abs(r.h - 10) < 0.01 then lit = lit + 1 end
end
check("a setting draws one step per value", steps + lit == 4,
      steps .. " outlined, " .. lit .. " filled")
check("and lights the one it is on", lit == 3, lit .. " filled")

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
