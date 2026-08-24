-- The label over a hull: who they are, and what they are worth.
--
--     lua5.1 client/tests/plate_test.lua
--
-- The bounty under a name is the number that decides which of two ships in
-- front of you is worth the risk, and until now it was set as a bare figure.
-- Position was the only thing saying what it counted: kills, deaths, points
-- and bounty are all drawn as a number somewhere, and a reader who has not
-- learned this particular somewhere has no way to tell which one they are
-- looking at. It is a price, so it wears the rivet, the same mark every other
-- price in the game is set with.
--
-- Measured off a real M.hud frame rather than reasoned about, because both
-- halves of this are geometry: a mark half the height of its own number reads
-- as a bullet point rather than as a unit, and a mark that lands on top of
-- the figure reads as neither.

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
for _, n in ipairs({"arc", "disc", "flush", "frame", "outline", "quad",
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
local bty = drawn(tostring(BOUNTY))
check("a hull that is not yours wears its pilot's name", name ~= nil)
check("and the price on their head under it",
      bty ~= nil and name ~= nil and bty.y < name.y,
      bty and name and ("name at %.0f, bounty at %.0f"):format(name.y, bty.y)
          or "one of them missing")

-- --- set as a price --------------------------------------------------------

local mark = bty and near(bty.x - 8, bty.y, 12) or {}
check("the figure is set with the rivet", #mark == 4,
      ("%d strokes beside it"):format(#mark))

if #mark == 4 then
    local x0, x1, y0, y1 = math.huge, -math.huge, math.huge, -math.huge
    local weight = 0
    for _, s in ipairs(mark) do
        x0 = math.min(x0, s.x0, s.x1)
        x1 = math.max(x1, s.x0, s.x1)
        y0 = math.min(y0, s.y0, s.y1)
        y1 = math.max(y1, s.y0, s.y1)
        weight = math.max(weight, s.w or 0)
    end

    -- Left of the figure and clear of it. A unit drawn over its own number is
    -- worse than no unit at all.
    check("standing to the left of the figure rather than over it",
          x1 < bty.x, ("mark ends at %.1f, figure starts at %.1f")
              :format(x1, bty.x))

    -- And flush with the name above, so the two lines are one block hanging
    -- off the hull rather than a name with something indented under it.
    check("and beginning where the name above it begins",
          math.abs(x0 - name.x) < 1.5,
          ("mark at %.1f, name at %.1f"):format(x0, name.x))

    -- The failure pages.priced was written against: a mark half the height of
    -- its own number reads as a bullet point.
    check("as tall as the figure it is a unit for",
          y1 - y0 > bty.px * 0.75,
          ("%.1f tall against %.0f point type"):format(y1 - y0, bty.px))

    -- One label, one color. Gold would say "this is a bounty", which the
    -- position already says; the side's color says whose hull it is over,
    -- and the mark has to be part of the same label to say it.
    check("and in the label's own color, not a color of its own",
          math.abs(mark[1].col[1] - bty.col[1]) < 0.01
          and math.abs(mark[1].col[2] - bty.col[2]) < 0.01
          and math.abs(mark[1].col[3] - bty.col[3]) < 0.01,
          "the mark and the figure disagree")

    check("struck heavily enough to survive the size it is drawn at",
          weight > 0.9, ("%.2f"):format(weight))
end

-- --- and nothing at all where there is nothing to say ----------------------

-- A zone opens every pilot at a bounty of one, so a plate that said so would
-- put a column of ones across the screen saying only that the match had
-- started. The mark does not get to reintroduce that.
BOUNTY = 1
frame()
local still = drawn("mark")
local one = drawn("1")
-- The line under the name, found by asking where the name went rather than
-- by working the plate's offsets out here a second time.
local under = still and near(still.x, still.y - 12, 20) or {}
check("a pilot worth nothing extra says nothing",
      one == nil or math.abs(one.y - (still.y - 12)) > 6,
      one and ("a 1 at %.0f, name at %.0f"):format(one.y, still.y) or "none")
check("and wears no mark either", #under == 0,
      ("%d strokes under the name"):format(#under))

if fails > 0 then
    print(("\n%d check(s) failed"):format(fails))
    os.exit(1)
end
print("\nall ok")
