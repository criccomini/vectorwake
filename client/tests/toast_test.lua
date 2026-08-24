-- The one feed line a phone shows.
--
--     lua5.1 client/tests/toast_test.lua
--
-- A desktop reads the whole feed in the corner. A phone cannot: that corner
-- is where a thumb flies the ship. So the phone gets the same feed filtered
-- to one line, the newest one that is about this pilot, over the middle of
-- the screen and clear of the thumbs.
--
-- Two rules, and each has a way of going quietly wrong that only shows up on
-- somebody's phone mid-fight: a stranger's kill leaking through, and two
-- lines stacking into a panel over the game. Both are arithmetic about what
-- was drawn, so they are measured here.

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
                       "seg_flat", "skirt", "tri", "tri_fade", "halo",
                       "fan"}) do
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
    has_trigger = function() return true end,
    ship_level = function() return 0 end,
    ship_mod = function() return 0 end,
    ship_multi_off = function() return false end,
    flag_count = function() return 0 end,
    flag_at = function() return 0, 0, 255 end,
    map_coarse = function() return nil end,
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
                       "Lattice"},
        menu_open = false,
        pilots = {[0] = {name = "you", label = "human"}},
        teams = {}, feed = feed or {}, hurt = 0,
        charges = {},
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
    local rows = {}
    for k = 1, state.n do
        local t = state.text[k]
        if t.s == words then
            local w = #t.s * t.px * (1233 / 2048)
            local x = t.pivot == "right" and t.x - w / 2
                or t.pivot == "center" and t.x or t.x + w / 2
            return {x = x, y = H - t.y, px = t.px, pivot = t.pivot}
        end
        rows[t.y] = rows[t.y] or {}
        rows[t.y][#rows[t.y] + 1] = t
    end
    -- A kill is drawn in parts now, with a mark after each named pilot. Find
    -- the run of text around those marks while leaving bare notices on their
    -- original one-entry path above.
    local advance = 1233 / 2048
    for y, row in pairs(rows) do
        table.sort(row, function(a, b) return a.x < b.x end)
        for first = 1, #row do
            local s = ""
            local x0, x1
            for last = first, #row do
                local t = row[last]
                local w = #t.s * t.px * advance
                local left = t.pivot == "right" and t.x - w
                    or t.pivot == "center" and t.x - w / 2 or t.x
                s = s .. t.s
                x0 = math.min(x0 or left, left)
                x1 = math.max(x1 or left + w, left + w)
                if s == words then
                    return {x = (x0 + x1) / 2, y = H - y,
                            px = t.px, pivot = "center"}
                end
                if #s >= #words then break end
            end
        end
    end
    return nil
end

local THEIRS = {text = {{"someone"}, " killed ", {"other"}}, t = 0}
local MY_KILL = {text = {{"you"}, " killed ", {"other"}},
                 col = pal.PAID, t = 0, mine = true}
local MY_DEATH = {text = {{"other"}, " killed ", {"you"}},
                  col = pal.HURT, t = 0, mine = true}

-- --- only what is about you ------------------------------------------------

frame(844, 390, {THEIRS})
check("a stranger's kill is not shown on a phone", shown("someone killed other") == nil)

frame(844, 390, {MY_DEATH})
check("a death of yours is shown on a phone", shown("other killed you") ~= nil)

frame(844, 390, {MY_KILL})
check("and so is a kill you made", shown("you killed other") ~= nil)

-- --- one at a time ---------------------------------------------------------

-- Newest first, the way the arena inserts them. Two of yours means the newer
-- one and only the newer one.
frame(844, 390, {MY_DEATH, MY_KILL})
check("the newest of yours is shown", shown("other killed you") ~= nil)
check("and the older one is not", shown("you killed other") == nil)

-- A stranger's line arriving on top of yours does not hide yours: it is
-- skipped, not counted as the one line.
frame(844, 390, {THEIRS, MY_DEATH})
check("a stranger's line does not take the slot", shown("other killed you") ~= nil)

-- --- it expires -------------------------------------------------------------

frame(844, 390, {{text = MY_DEATH.text, col = pal.HURT, t = 9, mine = true}})
check("a line older than the toast's life is gone", shown("other killed you") == nil)

-- --- where it lands ---------------------------------------------------------

-- Landscape: across the top, clear of the thumbs entirely.
frame(844, 390, {MY_DEATH})
local land = shown("other killed you")
check("landscape puts it in the upper band", land and land.y < 390 * 0.33,
      land and string.format("y %.0f of 390", land.y) or "not drawn")
check("and centered", land and math.abs(land.x - 844 / 2) < 1,
      land and string.format("x %.0f", land.x) or "not drawn")

-- A rack full of charges builds a taller rail, and the line stays where it
-- is: the top band is measured off the safe area rather than off the
-- controls, so nothing a hull happens to carry can push it. There was a
-- second placement here, two thirds down a phone held upright, clamped clear
-- of that rail. A game is landscape only now, so both are gone.
frame(844, 390, {MY_DEATH}, {charges = {0, 2}})
local packed = shown("other killed you")
check("a full charge rail does not move it",
      packed and land and math.abs(packed.y - land.y) < 0.01,
      packed and string.format("y %.0f, was %.0f", packed.y,
                               land and land.y or -1) or "not drawn")

-- --- and a desktop is untouched --------------------------------------------

-- Not touching: the corner feed does the work and no slab lands mid-screen.
H = 800
rects, state.n = {}, 0
touch.used = false
ui.begin(layer, 1280, 800, 1, false)
ui.hud({
    me = 0, class_names = {"Apex"}, menu_open = false,
    pilots = {[0] = {name = "you", label = "human"}},
    teams = {}, feed = {MY_DEATH}, hurt = 0, charges = {},
    cam_x = 400, cam_y = 400, half_w = 640, half_h = 400,
    banner = "", lag = 4,
    stats = {lag = 4, lead = 2, err = 1, err_max = 2, rewind = 1, snaps = 10,
             rx = 0, tx = 0},
    zone = "chaos", fps = 60, frame_ms = 16, rx_rate = 0, tx_rate = 0,
})
ui.finish()
local desk = shown("other killed you")
check("a desktop draws the line in its corner, not the middle",
      desk ~= nil and desk.x > 1280 * 0.6,
      desk and string.format("x %.0f", desk.x) or "not drawn")

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
