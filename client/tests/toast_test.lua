-- The one feed line a phone shows.
--
--     lua5.1 client/tests/toast_test.lua
--
-- A desktop reads the whole feed in the corner. A phone cannot: that corner
-- is where a thumb flies the ship. So the phone gets the same feed filtered
-- to one line, the newest one that is about this pilot, over the middle of
-- the screen and away from the thumbs in whichever way the phone is held.
--
-- Three rules, and each has a way of going quietly wrong that only shows up
-- on somebody's phone mid-fight: a stranger's kill leaking through, two
-- lines stacking into a panel over the game, and the line landing on the
-- controls in portrait, where the charge rail's height depends on what the
-- hull happens to be carrying. All three are arithmetic about what was
-- drawn, so they are measured here.

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

local rects = {}
local layer = {n = 0}
local function noop(self) self.n = self.n + 1 end
for _, name in ipairs({"arc", "disc", "flush", "frame", "outline", "quad",
                       "reset", "ring", "ring_fade", "seg", "seg_fade",
                       "skirt", "tri", "tri_fade", "halo", "fan"}) do
    layer[name] = noop
end
layer.rect = function(self, x, y, w, h)
    self.n = self.n + 1
    rects[#rects + 1] = {x = x, y = y, w = w, h = h}
end

_G.sim = setmetatable({
    ship_count = function() return 1 end,
    ship_x = function() return 400 end,
    ship_y = function() return 400 end,
    ship_alive = function() return 1 end,
    ship_bounty = function() return 12 end,
    ship_charge = function() return 2 end,
    charge_max = function() return 3 end,
    has_trigger = function() return true end,
    ship_level = function() return 0 end,
    ship_mod = function() return 0 end,
    ship_multi_off = function() return false end,
    flag_count = function() return 0 end,
    flag_at = function() return 0, 0, 255 end,
    map_coarse = function() return nil end,
    prize_count = function() return 0 end,
    weapon_count = function() return 0 end,
    tick = function() return 1000 end,
    TRIG_GUN = 0, TRIG_BOMB = 1, TRIG_COUNT = 2, MOD_COUNT = 6,
    MAX_CHARGES = 4, BTN_FIRE = 1,
}, {__index = function() return function() return 0 end end})

local state = {text = {}, n = 0, version = 0}
package.loaded["arena.state"] = state
package.loaded["arena.world"] = {
    build_overview = function() end,
    forget_overview = function() end,
    overview = {grid = 0, n = 0, rect = {}},
    radar_tiles = {}, radar_safe = {}, radar_doors = {},
}

local touch = require("arena.touch")
local ui = require("arena.ui")
local pal = require("arena.palette")

-- --- the harness -----------------------------------------------------------

-- The same reach the frame loop hands down: how far up the controls climb.
local function pad_reach(w, h, s)
    local L = touch.layout(w, h, s)
    local reach = L.guns.y + L.guns.r
    for _, c in ipairs(L.charge or {}) do
        local top = c.y + (c.w and c.w / 2 or c.r)
        if top > reach then reach = top end
    end
    return reach
end

local H

local function frame(w, h, feed, opts)
    opts = opts or {}
    H = h
    rects = {}
    state.n = 0
    touch.charges = opts.charges or {}
    touch.used = true
    ui.begin(layer, w, h, 1, true)
    ui.hud({
        me = 0,
        class_names = {"Apex", "Wedge", "Chord", "Anvil", "Facet", "Cipher",
                       "Lattice", "Spire"},
        menu_open = false,
        pilots = {[0] = {name = "you", label = "human"}},
        teams = {}, feed = feed or {}, hurt = 0,
        charges = {}, pad_top = pad_reach(w, h, 1),
        cam_x = 400, cam_y = 400, half_w = w / 2, half_h = h / 2,
        banner = "", lag = 4,
        stats = {lag = 4, lead = 2, err = 1, err_max = 2, rewind = 1,
                 snaps = 10, rx = 0, tx = 0},
        zone = "chaos", fps = 60, frame_ms = 16,
        rx_rate = 0, tx_rate = 0,
    })
    ui.finish()
end

-- What the toast drew, found by its words. Returns the text entry, in the
-- interface's own top-down coordinates.
local function shown(words)
    for k = 1, state.n do
        local t = state.text[k]
        if t.s == words then
            return {x = t.x, y = H - t.y, px = t.px, pivot = t.pivot}
        end
    end
    return nil
end

local MINE = {text = "+ BOMB", col = pal.CHARGE_COL, t = 0, mine = true}
local THEIRS = {text = {{"someone"}, " killed ", {"other"}}, t = 0}
local MY_KILL = {text = {{"you"}, " killed ", {"other"}},
                 col = pal.PRIZE, t = 0, mine = true}

-- --- only what is about you ------------------------------------------------

frame(844, 390, {THEIRS})
check("a stranger's kill is not shown on a phone", shown("someone KILLED other") == nil)

frame(844, 390, {MINE})
check("a green you flew through is", shown("+ BOMB") ~= nil)

frame(844, 390, {MY_KILL})
check("and so is a kill you made", shown("you KILLED other") ~= nil)

-- --- one at a time ---------------------------------------------------------

-- Newest first, the way the arena inserts them. Two of yours means the newer
-- one and only the newer one.
frame(844, 390, {MINE, MY_KILL})
check("the newest of yours is shown", shown("+ BOMB") ~= nil)
check("and the older one is not", shown("you KILLED other") == nil)

-- A stranger's line arriving on top of yours does not hide yours: it is
-- skipped, not counted as the one line.
frame(844, 390, {THEIRS, MINE})
check("a stranger's line does not take the slot", shown("+ BOMB") ~= nil)

-- --- it expires -------------------------------------------------------------

frame(844, 390, {{text = "+ BOMB", col = pal.CHARGE_COL, t = 9, mine = true}})
check("a line older than the toast's life is gone", shown("+ BOMB") == nil)

-- --- where it lands ---------------------------------------------------------

-- Landscape: across the top, clear of the thumbs entirely.
frame(844, 390, {MINE})
local land = shown("+ BOMB")
check("landscape puts it in the upper band", land and land.y < 390 * 0.33,
      land and string.format("y %.0f of 390", land.y) or "not drawn")
check("and centred", land and math.abs(land.x - 844 / 2) < 1,
      land and string.format("x %.0f", land.x) or "not drawn")

-- Portrait: two thirds down, and above the controls. Checked with a full
-- rack, since the charge rail is as tall as the hull's charges.
frame(390, 844, {MINE}, {charges = {0, 1, 2, 3}})
local port = shown("+ BOMB")
local reach = pad_reach(390, 844, 1)
check("portrait puts it two thirds down",
      port and port.y > 844 * 0.55 and port.y <= 844 * 0.67,
      port and string.format("y %.0f of 844", port.y) or "not drawn")
check("and centred", port and math.abs(port.x - 390 / 2) < 1)
-- touch.lua counts up from the bottom; the toast counts down from the top.
check("and clear of the controls under it",
      port and port.y + 12 < 844 - reach,
      port and string.format("line at %.0f, controls reach %.0f",
                             port.y, 844 - reach) or "not drawn")

-- The clamp has to bite when a rail climbs into that two-thirds line, or the
-- fraction is just a guess that happens to work on one loadout.
frame(390, 500, {MINE}, {charges = {0, 1, 2, 3}})
local tight = shown("+ BOMB")
local treach = pad_reach(390, 500, 1)
check("a short window pulls it up off the controls",
      tight and tight.y + 12 < 500 - treach,
      tight and string.format("line at %.0f, controls reach %.0f",
                              tight.y, 500 - treach) or "not drawn")

-- --- and a desktop is untouched --------------------------------------------

-- Not touching: the corner feed does the work and no slab lands mid-screen.
H = 800
rects, state.n = {}, 0
touch.used = false
ui.begin(layer, 1280, 800, 1, false)
ui.hud({
    me = 0, class_names = {"Apex"}, menu_open = false,
    pilots = {[0] = {name = "you", label = "human"}},
    teams = {}, feed = {MINE}, hurt = 0, charges = {},
    cam_x = 400, cam_y = 400, half_w = 640, half_h = 400,
    banner = "", lag = 4,
    stats = {lag = 4, lead = 2, err = 1, err_max = 2, rewind = 1, snaps = 10,
             rx = 0, tx = 0},
    zone = "chaos", fps = 60, frame_ms = 16, rx_rate = 0, tx_rate = 0,
})
ui.finish()
local desk = shown("+ BOMB")
check("a desktop draws the line in its corner, not the middle",
      desk ~= nil and desk.x > 1280 * 0.6,
      desk and string.format("x %.0f", desk.x) or "not drawn")

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
