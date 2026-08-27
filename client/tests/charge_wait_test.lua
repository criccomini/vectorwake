-- A charge whose key is shut, and the corner saying so.
--
--     lua5.1 client/tests/charge_wait_test.lua
--
-- A burst holds its own key for five seconds after it goes. Without a sign of
-- that, the corner draws a full row over a key that does nothing. So the row
-- goes out on the tick the burst leaves and comes back as the clock runs down,
-- and this reads the alpha the interface actually drew its pips at rather than
-- working the wash out a second time.
--
-- The repel is the control: its delay is zero, it never waits, and it must
-- never dim.

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

-- --- the engine, as much of it as the corner touches -----------------------

-- Every filled pip in the stack, as the color it was drawn in. `pages.dot`
-- draws one as a disc and an empty slot as a ring, and the charge column is
-- the only thing in the corner drawing discs in the charge hue.
local discs, rings = {}, {}
local layer = {n = 0}
local function noop(self) self.n = self.n + 1 end
for _, name in ipairs({"arc", "flush", "frame", "outline", "quad",
                       "reset", "ring_fade", "seg", "seg_fade",
                       "seg_flat", "skirt", "tri", "tri_fade", "halo",
                       "fan", "rect", "glow_band", "seg_glow"}) do
    layer[name] = noop
end
layer.disc = function(self, x, y, r, sides, col)
    self.n = self.n + 1
    discs[#discs + 1] = {x = x, y = y, r = r, col = col}
end
layer.ring = function(self, x, y, r, w, sides, col)
    self.n = self.n + 1
    rings[#rings + 1] = {x = x, y = y, r = r, col = col}
end

_G.sim = setmetatable({
    ship_count = function() return 1 end,
    ship_x = function() return 400 end,
    ship_y = function() return 400 end,
    ship_alive = function() return 1 end,
    has_trigger = function() return false end,
    flag_count = function() return 0 end,
    weapon_count = function() return 0 end,
    tick = function() return 1000 end,
    TRIG_GUN = 0, TRIG_BOMB = 1, TRIG_COUNT = 2, MOD_COUNT = 6,
    MOD_MULTI = 0,
    MAX_CHARGES = 4, BTN_FIRE = 1,
}, {__index = function() return function() return 0 end end})

package.loaded["arena.state"] = {text = {}, n = 0, version = 0}
package.loaded["arena.world"] = {
    build_overview = function() end,
    forget_overview = function() end,
    overview = {grid = 0, n = 0, rect = {}},
    radar_tiles = {}, radar_safe = {}, radar_doors = {},
}

local ui = require("arena.ui")
local pal = require("arena.palette")

local W, H = 1280, 720

-- The pips are the only discs drawn in the charge hue, and the hue is the
-- palette's rather than a copy of it, so a recolored charge does not quietly
-- stop this test from finding anything.
local function is_charge(col)
    return col and math.abs(col[1] - pal.CHARGE_COL[1]) < 0.01
        and math.abs(col[2] - pal.CHARGE_COL[2]) < 0.01
        and math.abs(col[3] - pal.CHARGE_COL[3]) < 0.01
end

-- Draw one frame with these charge rows and hand back what the pips came out
-- at: how many were filled, and the alpha they wore.
local function pips(charges)
    discs, rings = {}, {}
    ui.begin(layer, W, H, 1, false)
    ui.hud({
        me = 0,
        class_names = {"Apex"},
        menu_open = false,
        pilots = {[0] = {name = "you", label = "human"}},
        teams = {}, feed = {}, hurt = 0,
        charges = charges, pad_top = nil,
        cam_x = 400, cam_y = 400, half_w = W / 2, half_h = H / 2,
        banner = "", lag = 4,
        stats = {lag = 4, lead = 2, err = 1, err_max = 2, rewind = 1,
                 snaps = 10, rx = 0, tx = 0},
        zone = "alpha", fps = 60, frame_ms = 16,
        rx_rate = 0, tx_rate = 0,
    })
    ui.finish()
    local n, alpha = 0, nil
    for _, d in ipairs(discs) do
        if is_charge(d.col) then
            n = n + 1
            alpha = math.max(alpha or 0, d.col[4] or 1)
        end
    end
    return n, alpha
end

local function burst(wait)
    return {{name = "burst", short = "BST", count = 2, max = 3,
             wait = wait, delay = 500}}
end

-- --- what a shut key looks like --------------------------------------------

local open_n, open_a = pips(burst(0))
check("a ready burst draws its rack", open_n == 2, tostring(open_n))
check("at full strength", open_a and open_a > 0.99, tostring(open_a))

local shut_n, shut_a = pips(burst(500))
check("a burst just thrown still says how many are left", shut_n == 2,
      tostring(shut_n))
check("but the row is washed out", shut_a and shut_a < 0.4, tostring(shut_a))
check("and not washed away", shut_a and shut_a > 0.15, tostring(shut_a))

local half_n, half_a = pips(burst(250))
check("half way through the wait it is half way back", half_n == 2,
      tostring(half_n))
check("brighter than the tick it went", half_a > shut_a + 0.1,
      string.format("%.2f vs %.2f", half_a, shut_a))
check("and dimmer than a ready one", half_a < open_a - 0.1,
      string.format("%.2f vs %.2f", half_a, open_a))

-- --- and what a kind with no clock looks like ------------------------------

local _, rep_a = pips({{name = "repel", short = "RPL", count = 2, max = 3,
                        wait = 0, delay = 0}})
check("a repel has no delay and never dims", rep_a and rep_a > 0.99,
      tostring(rep_a))

-- A row that has never been told about a clock, which is what every harness
-- that predates this hands in. It reads as ready rather than as shut.
local _, old_a = pips({{name = "burst", short = "BST", count = 2, max = 3}})
check("a row with no clock on it draws ready", old_a and old_a > 0.99,
      tostring(old_a))

os.exit(fails == 0 and 0 or 1)
