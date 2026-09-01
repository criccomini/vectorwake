-- The label over a hull: who they are, and nothing else.
--
--     lua5.1 client/tests/plate_test.lua
--
-- One line. A name, and after it the mark saying whether a person or a machine
-- is flying, which is worth knowing while you are deciding whether to chase.
--
-- There was a second line under it, and it was the price on their head. Bounty
-- is gone with the shop it fed, so what this now guards is that nothing came
-- back: a plate carrying a figure would be a column of numbers across the
-- screen saying nothing, which is the failure the bounty line was trimmed
-- twice to avoid.
--
-- Measured off a real M.hud frame rather than reasoned about, because a plate
-- is geometry: a mark that lands on its own name reads as neither.

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

-- --- the engine, as much of it as ui.lua touches ---------------------------

local W, H = 1280, 800
local segs = {}
local layer = {}
local function noop() end
for _, n in ipairs({"arc", "disc", "flush", "frame", "outline",
                    "rect", "reset", "ring", "ring_fade", "seg_fade",
                    "seg_flat", "skirt", "tri", "tri_fade", "halo", "fan",
                    "glow_band", "seg_glow"}) do
    layer[n] = noop
end
-- Kept in the layer's own frame, which is the one the drawn text is in too,
-- so a mark and the figure beside it can be compared without either being
-- flipped a second time.
layer.seg = function(_, x0, y0, x1, y1, w, col)
    segs[#segs + 1] = {x0 = x0, y0 = y0, x1 = x1, y1 = y1, w = w,
                       col = col and {col[1], col[2], col[3]} or nil}
end
-- Closed runs go in the same record, at their own middle. What this page
-- asks is where the marks around a name landed, and since the feathers were
-- recut the pilot's badge is cut shapes rather than struck lines: read off
-- the strokes alone the mark beside a call sign is not there at all.
layer.quad = function(_, x1, y1, x2, y2, x3, y3, x4, y4)
    local cx = (x1 + x2 + x3 + x4) / 4
    local cy = (y1 + y2 + y3 + y4) / 4
    segs[#segs + 1] = {x0 = cx, y0 = cy, x1 = cx, y1 = cy, w = 0}
end

-- Seat 0 is the pilot, seat 1 is the hull being read. Sixty pixels apart on
-- an unzoomed camera, so the plate lands well inside the glass.
local BOUNTY = 37
local sim = setmetatable({
    ship_count = function() return 2 end,
    ship_x = function(i) return 600 + i * 60 end,
    ship_y = function() return 400 end,
    ship_alive = function() return 1 end,
    ship_active = function() return 1 end,
    ship_team = function(i) return i end,
    ship_bounty = function(i) return i == 1 and BOUNTY or 0 end,
    ship_energy = function() return 100 end,
    ship_max_energy = function() return 100 end,
    has_trigger = function() return true end,
    tick = function() return 100 end,
    flag_at = function() return 0, 0, 255 end,
    map_coarse = function() return nil end,
    BTN_FIRE = 1,
}, {__index = function() return function() return 0 end end})
_G.sim = sim

package.loaded["arena.state"] = {text = {}, n = 0, version = 0}
package.loaded["arena.touch"] = {layout = function() return {charge = {}} end,
                                 used = false}
package.loaded["arena.world"] = {
    build_overview = noop, forget_overview = noop,
    overview = function() return {grid = 0, rects = {}} end,
    radar_tiles = {}, radar_safe = {}, radar_doors = {}}

local ui = require("arena.ui")
local st = package.loaded["arena.state"]

local function frame()
    segs, st.n = {}, 0
    ui.begin(layer, W, H, 1, false)
    ui.hud({me = 0, class_names = {"Apex"}, menu_open = false,
            pilots = {[0] = {name = "you", label = "human"},
                      [1] = {name = "mark", label = "human"}},
            teams = {}, feed = {}, hurt = 0, charges = {},
            cam_x = 600, cam_y = 400, half_w = 640, half_h = 400,
            banner = "", lag = 4,
            stats = {lag = 4, lead = 0, err = 0, err_max = 0, rewind = 0,
                     snaps = 10, rx = 0, tx = 0},
            zone = "alpha"})
    ui.finish()
end

-- A drawn string, copied out: txt reuses its entries, so a held reference is
-- whatever the next frame put in it.
local function drawn(s)
    for i = 1, st.n do
        local t = st.text[i]
        if t.s == s then
            return {x = t.x, y = t.y, px = t.px,
                    col = {t.col[1], t.col[2], t.col[3]}}
        end
    end
end

-- Everything struck inside the label's own box, which is the only way to ask
-- about the plate on a screen that is also drawing a radar and a scoreboard.
local function near(x, y, reach)
    local out = {}
    for _, s in ipairs(segs) do
        if math.abs(s.x0 - x) < reach and math.abs(s.y0 - y) < reach then
            out[#out + 1] = s
        end
    end
    return out
end

-- --- what the plate says ---------------------------------------------------

frame()

local name = drawn("mark")
check("a hull that is not yours wears its pilot's name", name ~= nil)

-- --- and one line only -----------------------------------------------------

-- Where a second line would land, found by asking where the name went rather
-- than by working the plate's offsets out here a second time.
local under = name and near(name.x, name.y - 12, 24) or {}
check("nothing is drawn under it", #under == 0,
      ("%d strokes under the name"):format(#under))

local figure = drawn(tostring(BOUNTY)) or drawn("1")
check("and no figure hangs off the hull at all",
      figure == nil or math.abs(figure.y - name.y) > 8,
      figure and ("a figure at %.0f, name at %.0f"):format(figure.y, name.y)
          or "none")

-- The mark that says who is flying sits after the name on the same line, not
-- under it: the plate is one row, and a reader scanning the fight reads it in
-- one glance rather than in two.
if name then
    local beside = near(name.x + 40, name.y, 40)
    check("the pilot mark stands beside the name rather than below it",
          #beside > 0, ("%d strokes beside it"):format(#beside))
end

if fails > 0 then
    print(("\n%d check(s) failed"):format(fails))
    os.exit(1)
end
print("\nall ok")
