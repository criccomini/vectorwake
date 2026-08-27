-- The starfield's vertex budget, against the starfield.
--
--     lua5.1 client/tests/star_budget_test.lua
--
-- Run under plain Lua 5.1, which is what HTML5 builds run, with the engine
-- stubbed out.
--
-- This exists because of how a layer fails. A vertex buffer that is too small
-- does not raise and does not warn: the geometry past the cap stops being
-- written and the frame is drawn without it. The sky's layer was fixed at 6144
-- vertices, which is a window about 2100 points wide; past that the far and
-- middle depths fill the buffer on their own and the near stars, the big
-- bright ones, disappear. Whether they came back depended on where the camera
-- was sitting, which changes as you fly, so on a 2240-point iMac they
-- flickered. Nobody could have found that from the code: the budget was a
-- constant with no relationship to the thing it bounded.
--
-- So the budget is derived from the same table the drawing reads, and this
-- checks the derivation by drawing. Anything that changes a star's size, its
-- density, the halo's segment count or the depths themselves moves both, and
-- if it moves them apart this fails here rather than on somebody's monitor.

package.path = "client/?.lua;" .. package.path

-- The sky draws under the map now, so nothing about the terrain changes what
-- it costs: a wall hides stars by being drawn on top of them rather than by
-- taking them out of the buffer. The stub is what the module wants at load.
_G.sim = {solid = function() return false end}

local world = require("arena.world")

local fails = 0
local function check(desc, ok, why)
    if not ok then fails = fails + 1 end
    print(string.format("%-52s %s", desc, ok and "ok" or ("FAIL: " .. why)))
end

-- A layer that counts instead of drawing, through the same primitives the sky
-- reaches for. `rect` is two triangles, `halo` is one per segment, a tapered
-- segment is four and a bloom is six, which is what the native writer behind
-- vec.lua does.
--
-- It holds the drawing to the prices the budget was built from as well as
-- counting, because the budget's slack is wide enough to hide a shape that
-- grew: the fill bound assumes every cell carries a star against a real
-- density of nine to thirteen in sixteen, and the glow bound assumes every
-- near star blooms against a real one in seventeen. A star that started
-- costing two rects, or a halo that gained four segments, would fit inside
-- that slack and be caught by nothing. Priced here, it is caught at once.
--
-- Three segment counts are legitimate and no others: the eight the sky draws
-- almost everything at, the twenty-four the two-thousand-pixel washes need to
-- stop being visible polygons, and the six the flare's ghosts are cut from,
-- which are hexagons because the iris throwing them is. All three are
-- published, and a fourth would mean the budget is pricing a shape the drawing
-- no longer uses.
local wrong = nil
local function blades(segs)
    return segs == world.HALO_SEGS or segs == world.WIDE_SEGS
        or segs == world.IRIS_SEGS
end
local function counter()
    local L = {n = 0}
    function L:rect()
        self.n = self.n + 6
    end
    function L:halo(_, _, _, segs)
        if not blades(segs) and not wrong then
            wrong = string.format("a halo of %d segments is priced at %d, %d" ..
                                  " or %d", segs, world.HALO_SEGS,
                                  world.WIDE_SEGS, world.IRIS_SEGS)
        end
        self.n = self.n + segs * 3
    end
    -- A ring is a quad a segment, which is two triangles rather than one.
    function L:ring(_, _, _, _, segs)
        if not blades(segs) and not wrong then
            wrong = string.format("a ring of %d segments is priced at %d, %d" ..
                                  " or %d", segs, world.HALO_SEGS,
                                  world.WIDE_SEGS, world.IRIS_SEGS)
        end
        self.n = self.n + segs * 6
    end
    function L:seg_fade()
        self.n = self.n + 12
    end
    function L:bloom()
        self.n = self.n + 18
    end
    return L
end

-- Half-extents in world pixels, which is what the render script hands the
-- arena: the drawable over twice the zoom. A phone stands the camera back so
-- its short axis holds 640 world pixels, which is why the small end of this
-- list is not as small as the screen is.
local VIEWS = {
    {"phone, sideways", 692, 320},
    {"phone, upright", 320, 692},
    {"1280 x 800", 640, 400},
    {"1440 x 900", 720, 450},
    {"1920 x 1080", 960, 540},
    {"2240 x 1260", 1120, 630},
    {"2560 x 1440", 1280, 720},
    {"3840 x 2160", 1920, 1080},
    {"ultrawide 5120 x 1440", 2560, 720},
    -- Off the round numbers, since a browser window is any size at all and
    -- the bound turns on where the camera sits inside a cell.
    {"odd size", 813, 477},
}

-- The one price the budget takes on faith. A rect is two triangles in the
-- native writer behind vec.lua, which no Lua test can see, so the number is
-- stated in both places and checked against itself here.
check("the budget prices a rect the way the buffer writes one",
      world.STAR_VERTS == 6, "priced at " .. tostring(world.STAR_VERTS))

-- The camera has to be walked, not sampled once: the cell counts depend on
-- its position within a cell, and which cells carry a star depends on the
-- hash. Steps that share no factor with any cell size, so the sweep does not
-- land on the same phase every time.
local STEPS = 300
local function sweep(hw, hh, fn)
    for i = 0, STEPS do
        fn(1000 + i * 37.3, 4000 + i * 91.7)
    end
end

for _, v in ipairs(VIEWS) do
    local name, hw, hh = v[1], v[2], v[3]
    local want_f, want_g = world.star_cost(hw, hh)
    local got_f, got_g = 0, 0
    sweep(hw, hh, function(cx, cy)
        local f, g = counter(), counter()
        world.stars(f, g, cx, cy, hw, hh)
        if f.n > got_f then got_f = f.n end
        if g.n > got_g then got_g = g.n end
    end)

    check(name .. ": the fill bound holds", got_f <= want_f,
          string.format("drew %d vertices, budgeted %d", got_f, want_f))
    check(name .. ": the glow bound holds", got_g <= want_g,
          string.format("drew %d vertices, budgeted %d", got_g, want_g))
    -- Non-vacuity, and the only thing standing between this file and a budget
    -- of a billion. The fill bound is every cell carrying a star against a
    -- density of nine to thirteen in sixteen, which on its own is a third
    -- over. The band widens that and widens it with the window: it is a stripe
    -- of fixed width, so the bigger the window the more of it is sky rather
    -- than band, while the bound goes on reserving the whole window at full
    -- density inside its stripe, where the real thing thins toward both edges.
    -- Every window here lands between about half over and twice over, so this
    -- allows a little past that; anything looser means the derivation has
    -- stopped tracking what is drawn.
    check(name .. ": the fill bound is not wild", got_f > 0 and want_f < got_f * 2.5,
          string.format("drew %d, budgeted %d", got_f, want_f))
    -- The glow bound is every near star blooming against one in seventeen, so
    -- it is loose on purpose and only checked for being finite and covered.
    check(name .. ": stars reach both layers", got_f > 0 and got_g > 0,
          string.format("fill %d, glow %d", got_f, got_g))

    local bf, bg = world.sky_budget(hw, hh)
    check(name .. ": the layer budget covers the field", bf > got_f and bg > got_g,
          string.format("fill %d of %d, glow %d of %d", got_f, bf, got_g, bg))
    print(string.format("   %-22s fill %6d drawn, %6d bound, layer %6d" ..
                        "   glow %5d drawn, %5d bound, layer %6d",
                        name, got_f, want_f, bf, got_g, want_g, bg))
end

check("every halo drawn costs what the budget pays for it",
      wrong == nil, tostring(wrong))

-- The budget has to grow with the window, which is the whole point of it, and
-- it has to grow in steps rather than continuously so that dragging a window
-- edge is not a buffer allocation per frame.
local small = select(1, world.sky_budget(640, 400))
local large = select(1, world.sky_budget(1920, 1080))
check("a bigger window gets a bigger budget", large > small * 2,
      string.format("640x400 got %d, 1920x1080 got %d", small, large))
check("budgets land on a step", small % 1024 == 0 and large % 1024 == 0,
      string.format("%d and %d", small, large))
local a = select(1, world.sky_budget(960, 540))
local b = select(1, world.sky_budget(961, 540))
check("a pixel of drag does not move the budget", a == b,
      string.format("%d became %d", a, b))

-- What the fill layer used to be, and the window where it stopped being
-- enough. This is the bug, pinned: if somebody puts the constant back, or
-- makes the sky cheap enough that it never mattered, this says so.
--
-- The window it ran out at has come in a long way since it was found. It was
-- about 2100 points wide against three star layers and a round nebula; the
-- band, the clouds and the rest cost roughly three times that, so the old
-- capacity would now run out on a phone, which is to say on every window there
-- is rather than on somebody's large monitor.
local OLD_CAP = 6144
local over = nil
for w = 600, 2600, 20 do
    local f = select(1, world.star_cost(w / 2, w * 9 / 32))
    if f > OLD_CAP and not over then over = w end
end
check("the old fixed capacity ran out inside a desktop's range",
      over ~= nil and over > 600 and over < 2560,
      "the old 6144 was outgrown at " .. tostring(over) .. " points wide")
print(string.format("   the old fixed 6144 covered a 16:9 window up to about" ..
                    " %d points wide", (over or 0) - 20))

if fails > 0 then
    print(fails .. " check(s) failed")
    os.exit(1)
end
print("all checks passed")
