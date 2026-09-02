-- The safe-area insets, measured rather than looked at.
--
--     lua5.1 client/tests/safe_test.lua
--
-- An iPhone's island and corners cover the screen's edges, and the page
-- runs under them on purpose, so the interface steps its edge-anchored
-- furniture inside the insets the page measures. None of that is visible
-- in CI, and Chromium's emulation reports every inset as zero, so the
-- browser cannot test it either. What can be tested is the arithmetic:
-- the same frame drawn with and without insets, and the difference read
-- off the geometry. The bottom is deliberately uninset; the home
-- indicator overlays the pads the way it overlays every full-screen
-- game's controls, and that decision is pinned here too.

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

-- --- a recording layer -----------------------------------------------------

local shapes = {}
local function box(x0, y0, x1, y1)
    if x1 < x0 then x0, x1 = x1, x0 end
    if y1 < y0 then y0, y1 = y1, y0 end
    shapes[#shapes + 1] = {x0 = x0, y0 = y0, x1 = x1, y1 = y1}
end

local layer = {}
function layer:seg(x1, y1, x2, y2, w) box(x1 - w, y1 - w, x2 + w, y2 + w) end
function layer:seg_fade(x1, y1, x2, y2, w1, w2)
    local w = math.max(w1, w2)
    box(x1 - w, y1 - w, x2 + w, y2 + w)
end
function layer:seg_flat(x1, y1, x2, y2, w)
    box(x1 - w, y1 - w, x2 + w, y2 + w)
end
function layer:disc(x, y, r) box(x - r, y - r, x + r, y + r) end
function layer:halo(x, y, r) box(x - r, y - r, x + r, y + r) end
function layer:ring(x, y, r, w) box(x - r - w, y - r - w, x + r + w, y + r + w) end
function layer:ring_fade(x, y, r, w)
    box(x - r - w, y - r - w, x + r + w, y + r + w)
end
function layer:arc(x, y, r, a0, a1, w)
    box(x - r - w, y - r - w, x + r + w, y + r + w)
end
function layer:ring_aa(x, y, r, w)
    box(x - r - w, y - r - w, x + r + w, y + r + w)
end
function layer:arc_aa(x, y, r, a0, a1, w)
    box(x - r - w, y - r - w, x + r + w, y + r + w)
end
function layer:arc_fade(x, y, r, a0, a1, w)
    box(x - r - w, y - r - w, x + r + w, y + r + w)
end
function layer:bloom(x, y, r) box(x - r, y - r, x + r, y + r) end
function layer:rect(x, y, w, h) box(x, y, x + w, y + h) end
function layer:frame(x, y, w, h) box(x, y, x + w, y + h) end
function layer:outline(pts, w)
    for i = 1, #pts - 1, 2 do
        box(pts[i] - w, pts[i + 1] - w, pts[i] + w, pts[i + 1] + w)
    end
end
function layer:fan(pts)
    for i = 1, #pts - 1, 2 do
        box(pts[i], pts[i + 1], pts[i], pts[i + 1])
    end
end
function layer:tri(x1, y1, x2, y2, x3, y3)
    box(math.min(x1, x2, x3), math.min(y1, y2, y3),
        math.max(x1, x2, x3), math.max(y1, y2, y3))
end
for _, name in ipairs({"flush", "quad", "reset", "skirt", "tri_fade"}) do
    layer[name] = function() end
end

-- --- the engine ------------------------------------------------------------

local sim = {
    ship_count = function() return 1 end,
    ship_x = function() return 400 end,
    ship_y = function() return 400 end,
    ship_heading = function() return 0 end,
    ship_alive = function() return 1 end,
    ship_team = function() return 1 end,
    -- Nobody is riding anybody unless a test says so.
    ship_class = function() return 0 end,
    ship_energy = function() return 100 end,
    ship_max_energy = function() return 100 end,
    ship_kills = function() return 0 end,
    ship_deaths = function() return 0 end,
    ship_assists = function() return 0 end,
    ship_points = function() return 0 end,
    ship_bounty = function() return 47 end,
    ship_up = function() return 0 end,
    ship_level = function() return 1 end,
    ship_charge = function() return 2 end,
    ship_mod = function() return 0 end,
    ship_multi_off = function() return false end,
    has_trigger = function() return true end,
    tick = function() return 1000 end,
    weapon_count = function() return 0 end,
    flag_count = function() return 4 end,
    flag_at = function() return 0, 0, 255 end,
    map_coarse = function() return nil end,
    TRIG_GUN = 0,
    TRIG_BOMB = 1,
    BTN_FIRE = 1,
}
_G.sim = sim

local state = {text = {}, n = 0, version = 0}
package.loaded["arena.state"] = state
package.loaded["arena.world"] = {
    build_overview = function() end,
    forget_overview = function() end,
    overview = {grid = 0, n = 0, rect = {}},
    radar_tiles = {},
    radar_safe = {},
    radar_doors = {},
    -- The menu draws hulls on its ship page and marks; the rail below needs
    -- the module to answer for one rather than to be right about it.
    HULLS = setmetatable({}, {__index = function()
        return {poly = {0, 0, 1, 1, 2, 0}, mid = 0}
    end}),
}

local touch = require("arena.touch")
local ui = require("arena.ui")

-- --- the harness -----------------------------------------------------------

local W, H = 844, 390
local L_INS, R_INS, T_INS = 59, 44, 24

local function frame(touching)
    shapes = {}
    state.n = 0
    ui.begin(layer, W, H, 1, touching)
    ui.hud({
        me = 0,
        class_names = {"Apex", "Wedge", "Chord", "Anvil", "Facet", "Cipher",
                       "Lattice"},
        menu_open = false,
        pilots = {[0] = {name = "you", label = "human"}},
        teams = {},
        feed = {},
        hurt = 0,
        charges = {{name = "repel", short = "RPL", count = 2, max = 3}},
        cam_x = 400, cam_y = 400,
        half_w = W / 2, half_h = H / 2,
        banner = "",
        lag = 4,
        stats = {lag = 4, lead = 2, err = 1.5, err_max = 9.0, rewind = 3,
                 snaps = 120, rx = 0, tx = 0},
        zone = "chaos",
        fps = 60, frame_ms = 16.7, rx_rate = 0, tx_rate = 0,
    })
    ui.finish()
    -- The mesh counts up from the bottom and the text counts down from the
    -- top, so the shapes flip through H before the two can be compared:
    -- "topmost" means the smallest top-down y, which for a shape is H minus
    -- its highest edge.
    local x0, y0, x1 = math.huge, math.huge, 0
    for _, s in ipairs(shapes) do
        x0 = math.min(x0, s.x0)
        y0 = math.min(y0, H - s.y1)
        x1 = math.max(x1, s.x1)
    end
    -- The text goes to the edges too, the clock band being among the topmost
    -- things on screen, and text is not a shape. It rides the same bottom-up
    -- frame the mesh does, so it flips through H the same way.
    for k = 1, state.n do
        local t = state.text[k]
        y0 = math.min(y0, H - t.y - t.px / 2)
        if t.pivot ~= "right" then x0 = math.min(x0, t.x) end
    end
    return {x0 = x0, y0 = y0, x1 = x1}
end

-- The whole interface, with and without something to dodge. Everything
-- anchored to an edge steps inside by exactly the inset: the leftmost ink
-- moves right by the left inset, the rightmost in by the right, the topmost
-- down by the top.
ui.safe(0, 0, 0)
local a = frame(false)
ui.safe(L_INS, R_INS, T_INS)
local b = frame(false)
check("the leftmost furniture steps in by the left inset",
      math.abs((b.x0 - a.x0) - L_INS) < 1,
      string.format("%.1f then %.1f", a.x0, b.x0))
check("the rightmost steps in by the right inset",
      math.abs((a.x1 - b.x1) - R_INS) < 1,
      string.format("%.1f then %.1f", a.x1, b.x1))
check("the topmost steps down by the top inset",
      math.abs((b.y0 - a.y0) - T_INS) < 1,
      string.format("%.1f then %.1f", a.y0, b.y0))

-- The column is the one thing at the bottom that reads the bottom inset, and
-- it has to read it: the menu key and the key the column stands on are both
-- down there, and a control under the home indicator is a control a thumb
-- cannot press without dismissing the app.
--
-- The rail used to be what this measured. A tab bar's surface runs under the
-- indicator and its icons do not, and the rail was stepped up bodily instead,
-- which stacked the indicator's 34 points on top of the 24 the block already
-- kept and left the words half an inch off the bottom of a phone. There is no
-- rail now and no surface running to the edge: the column is keys over a
-- fight, so the question is simply whether the lowest key clears the
-- indicator. The pads below are the opposite case and keep their ground,
-- because the indicator is allowed to overlap a thumbstick.
local B_INS = 34

-- How far the menu key's own box stops short of the bottom edge, at a given
-- inset. Measured off the published box rather than off ink, because the key
-- is the thing a thumb aims at.
local function key_gap(inset)
    shapes = {}
    state.n = 0
    ui.safe(0, 0, 0, inset)
    ui.begin(layer, 390, 844, 1, true)
    ui.hud({
        me = 0, side = 0, viewer_name = "you", menu_open = false,
        pilots = {}, watchers = {}, teams = {},
        match = {playing = true, left = 60, score = {[0] = 0, [1] = 0}},
        side_names = {[0] = "Pylon", [1] = "Caisson"},
        feed = {}, hurt = 0, charges = {},
        cam_x = 3000, cam_y = 3000, half_w = 195, half_h = 422,
        banner = "", zone = "melee",
        fps = 60, frame_ms = 16.7, rx_rate = 0, tx_rate = 0,
    })
    ui.finish()
    for _, r in ipairs(ui.hits) do
        if r.action == "open" then return 844 - (r.y + r.h) end
    end
    return -1
end
local flat_gap = key_gap(0)
local step_gap = key_gap(B_INS)
check("the menu key stands clear of the bottom edge",
      flat_gap > 4 and flat_gap < 24, string.format("%.1f", flat_gap))
check("and steps up by the whole of the home indicator",
      math.abs((step_gap - flat_gap) - B_INS) < 1,
      string.format("%.1f then %.1f", flat_gap, step_gap))
ui.safe(0, 0, 0, 0)

-- The pads and the stick's resting mark, against the real layout: sides
-- step in, and the bottom stays put because the home indicator is allowed
-- to overlap.
touch.safe_l, touch.safe_r = 0, 0
local La = touch.layout(W, H, 1)
touch.safe_l, touch.safe_r = L_INS, R_INS
local Lb = touch.layout(W, H, 1)
check("the gun pad steps in from the right",
      math.abs((La.guns.x - Lb.guns.x) - R_INS) < 0.01)
check("the stick's mark steps in from the left",
      math.abs((Lb.home.x - La.home.x) - L_INS) < 0.01)
check("the pad row keeps its height: the indicator may overlap",
      La.guns.y == Lb.guns.y and La.home.y == Lb.home.y)

-- Zero insets change nothing at all, which is every desktop and most of
-- the phones: the two frames must be identical, not merely close.
touch.safe_l, touch.safe_r = 0, 0
ui.safe(0, 0, 0)
local c = frame(false)
check("zero insets are the untouched layout",
      c.x0 == a.x0 and c.y0 == a.y0 and c.x1 == a.x1)

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
