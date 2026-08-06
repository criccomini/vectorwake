-- The loadout worn on the touch pads, measured rather than looked at.
--
--     lua5.1 client/tests/pads_test.lua
--
-- On a touchscreen the corner stack's weapon rows fold into the trigger
-- pads: the mark inside the ring, the rung ladder under it, and no rows at
-- the other corner but the bounty. None of that is visible in CI, and its
-- two easy failures are quiet ones: a loaded mark that outgrows its pad and
-- draws over the ring, and a stack row that comes back and stands in the
-- thumb's way. Both are rectangle arithmetic, so this runs the real M.hud
-- with the real touch.layout against a recording layer and measures.

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

-- Every primitive as the box it occupies, in the layer's own bottom-up
-- coordinates, with the colour where one is passed: the ladder's rungs are
-- found by colour below.
local shapes = {}
local function box(x0, y0, x1, y1, col)
    if x1 < x0 then x0, x1 = x1, x0 end
    if y1 < y0 then y0, y1 = y1, y0 end
    shapes[#shapes + 1] = {x0 = x0, y0 = y0, x1 = x1, y1 = y1, col = col}
end

local layer = {}
function layer:seg(x1, y1, x2, y2, w, col)
    box(x1 - w, y1 - w, x2 + w, y2 + w, col)
end
function layer:seg_fade(x1, y1, x2, y2, w1, w2, a1, a2, col)
    local w = math.max(w1, w2)
    box(x1 - w, y1 - w, x2 + w, y2 + w, col)
end
function layer:disc(x, y, r, _, col) box(x - r, y - r, x + r, y + r, col) end
function layer:halo(x, y, r, _, col) box(x - r, y - r, x + r, y + r, col) end
function layer:ring(x, y, r, w, _, col)
    box(x - r - w, y - r - w, x + r + w, y + r + w, col)
end
function layer:ring_fade(x, y, r, w, _, col)
    box(x - r - w, y - r - w, x + r + w, y + r + w, col)
end
function layer:arc(x, y, r, a0, a1, w, _, col)
    box(x - r - w, y - r - w, x + r + w, y + r + w, col)
end
function layer:rect(x, y, w, h, col) box(x, y, x + w, y + h, col) end
function layer:frame(x, y, w, h, s, col) box(x, y, x + w, y + h, col) end
function layer:outline(pts, w, col)
    for i = 1, #pts - 1, 2 do
        box(pts[i] - w, pts[i + 1] - w, pts[i] + w, pts[i + 1] + w, col)
    end
end
function layer:fan(pts, col)
    for i = 1, #pts - 1, 2 do
        box(pts[i], pts[i + 1], pts[i], pts[i + 1], col)
    end
end
function layer:tri(x1, y1, x2, y2, x3, y3, col)
    box(math.min(x1, x2, x3), math.min(y1, y2, y3),
        math.max(x1, x2, x3), math.max(y1, y2, y3), col)
end
for _, name in ipairs({"flush", "quad", "reset", "skirt", "tri_fade"}) do
    layer[name] = function() end
end

-- --- the engine ------------------------------------------------------------

-- Everything at once: both triggers, every add-on at full count, so the
-- marks measured are the widest this client can draw.
local mods = {[0] = {}, [1] = {}}
for m = 0, 5 do mods[0][m] = 3 mods[1][m] = 3 end
local bombs_held = true

local sim = {
    ship_count = function() return 1 end,
    ship_x = function() return 400 end,
    ship_y = function() return 400 end,
    ship_heading = function() return 0 end,
    ship_alive = function() return 1 end,
    ship_team = function() return 1 end,
    ship_class = function() return 0 end,
    ship_energy = function() return 100 end,
    ship_max_energy = function() return 100 end,
    ship_kills = function() return 0 end,
    ship_deaths = function() return 0 end,
    ship_points = function() return 0 end,
    ship_bounty = function() return 47 end,
    ship_up = function() return 0 end,
    ship_level = function() return 1 end,
    ship_charge = function() return 2 end,
    ship_mod = function(_, t, m) return (mods[t] and mods[t][m]) or 0 end,
    ship_multi_off = function() return false end,
    charge_max = function() return 3 end,
    has_trigger = function(_, t) return t == 0 or bombs_held end,
    trigger_rate = function() return 1 end,
    tick = function() return 1000 end,
    weapon_count = function() return 0 end,
    prize_count = function() return 0 end,
    prize_at = function() return 0, 0, 0 end,
    flag_count = function() return 0 end,
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
}

-- The real touch module, not a stub: the point is to measure the marks
-- against the pads exactly where taps will be tested.
local touch = require("arena.touch")
local ui = require("arena.ui")
local pal = require("arena.palette")

-- --- the harness -----------------------------------------------------------

local W, H = 844, 390        -- a landscape phone, in points at density 1
local S = 1

local function frame(touching)
    shapes = {}
    state.n = 0
    ui.begin(layer, W, H, S, touching)
    ui.hud({
        me = 0,
        class_names = {"Apex", "Wedge", "Chord", "Anvil", "Facet", "Cipher",
                       "Lattice", "Spire"},
        menu_open = false,
        pilots = {[0] = {name = "you", label = "human"}},
        teams = {},
        feed = {},
        hurt = 0,
        charges = {{name = "repel", short = "RPL", count = 2, max = 3},
                   {name = "burst", short = "BST", count = 1, max = 3}},
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
end

local function inside(s, pad, slack)
    local reach = pad.r * (slack or 1)
    return s.x0 >= pad.x - reach and s.x1 <= pad.x + reach
       and s.y0 >= pad.y - reach and s.y1 <= pad.y + reach
end
local function near(s, pad)
    local cx, cy = (s.x0 + s.x1) / 2, (s.y0 + s.y1) / 2
    local dx, dy = cx - pad.x, cy - pad.y
    return dx * dx + dy * dy <= (pad.r * 1.5) ^ 2
end
local function is_col(s, col)
    return s.col and s.col[1] == col[1] and s.col[2] == col[2]
       and s.col[3] == col[3]
end

-- --- on glass, the pads carry the loadout ----------------------------------

touch.has_bomb = true
frame(true)
local L = touch.layout(W, H, S)

-- The marks drew: each trigger pad holds shapes it did not hold before this
-- change, and with every add-on worn at once nothing outgrows its ring. The
-- slack is the ring's own stroke.
for _, which in ipairs({{"gun", L.guns}, {"bomb", L.bombs}}) do
    local name, pad = which[1], which[2]
    local n, out = 0, 0
    for _, s in ipairs(shapes) do
        if near(s, pad) then
            n = n + 1
            if not inside(s, pad, 1.08) then out = out + 1 end
        end
    end
    check("the " .. name .. " pad wears a mark", n > 3, n .. " shapes")
    check("the fully loaded " .. name .. " mark stays inside its pad",
          out == 0, out .. " shapes past the ring")
end

-- The ladder is in the pad: the team colour's lit rungs sit inside the
-- trigger pads and nowhere else on a touchscreen.
local strays = 0
for _, s in ipairs(shapes) do
    if is_col(s, pal.FRIEND) and not (near(s, L.guns) or near(s, L.bombs))
       and s.y1 < H * 0.6 then
        strays = strays + 1
    end
end
check("no stack row is drawn for the thumbs to reach around", strays == 0,
      strays .. " team-colour shapes outside the pads")

-- The one row the pads do not speak for survives: the bounty, worth 47
-- here, is still said at the left edge.
local bounty = false
for k = 1, state.n do
    local t = state.text[k]
    if t.s == "47" and t.x < W * 0.2 then bounty = true end
end
check("the bounty still has its row", bounty)

-- --- a hull with no rack ---------------------------------------------------

touch.has_bomb = false
bombs_held = false
frame(true)
local Lg = touch.layout(W, H, S)
local n = 0
for _, s in ipairs(shapes) do if near(s, Lg.guns) then n = n + 1 end end
check("a rackless hull still wears its gun mark", n > 3, n .. " shapes")
touch.has_bomb = true
bombs_held = true

-- --- and on a desktop, the stack stands ------------------------------------

frame(false)
local rows = 0
for _, s in ipairs(shapes) do
    if is_col(s, pal.FRIEND) and s.x0 < 200 then rows = rows + 1 end
end
check("a desktop window keeps its corner stack", rows > 0)

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
