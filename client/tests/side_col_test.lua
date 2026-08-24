-- The color a name wears on the scoreboard and the info box, for seats the
-- snapshot does not carry.
--
--     lua5.1 client/tests/side_col_test.lua
--
-- Snapshots are filtered to this client's interest window, so a pilot across
-- the map is not in the simulation at all, and `sim.ship_team` answers zero
-- for them. The board's sort learned that on the day the filter landed; the
-- board's *drawing* did not, and re-read the simulation at draw time. Every
-- pilot out of sight wore team zero's color, one shared violet across the
-- whole list, and the colors reshuffled as driving carried seats in and out
-- of the window. The roster carries every seat's team byte twice a second,
-- which is where the row now takes it from, so this drives the real `M.hud`
-- and reads the colors back off the drawn names.

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

local layer = {}
local function noop() end
for _, name in ipairs({"arc", "disc", "flush", "frame", "outline", "quad",
                       "rect", "reset", "ring", "seg", "seg_fade", "seg_flat",
                       "skirt", "tri", "tri_fade"}) do
    layer[name] = noop
end

-- The room. Seats 0 and 1 are inside the interest window, so the snapshot
-- carries them; seats 2 and 3 are across the map, absent from the simulation
-- entirely, which the stub renders the way `sim_unpack` does: inactive, and
-- every field zero.
local IN = {[0] = true, [1] = true}
local sim = {
    ship_count = function() return 4 end,
    ship_x = function(i) return IN[i] and (300 + i * 180) or 0 end,
    ship_y = function(i) return IN[i] and (300 + i * 120) or 0 end,
    ship_heading = function() return 0 end,
    ship_active = function(i) return IN[i] and 1 or 0 end,
    ship_alive = function(i) return IN[i] and 1 or 0 end,
    ship_team = function(i) return IN[i] and (3 + i) or 0 end,
    ship_class = function() return 0 end,
    ship_energy = function() return 100 end,
    ship_max_energy = function() return 100 end,
    ship_kills = function() return 0 end,
    ship_deaths = function() return 0 end,
    ship_assists = function() return 0 end,
    ship_points = function() return 0 end,
    ship_bounty = function() return 0 end,
    ship_up = function() return 0 end,
    ship_level = function() return 0 end,
    ship_charge = function() return 0 end,
    ship_mod = function() return 0 end,
    ship_multi_off = function() return 0 end,
    has_trigger = function() return true end,
    tick = function() return 100 end,
    weapon_count = function() return 0 end,
    flag_count = function() return 0 end,
    flag_at = function() return 0, 0, 255 end,
    map_coarse = function() return nil end,
    BTN_FIRE = 1,
}
_G.sim = sim

package.loaded["arena.state"] = {text = {}, n = 0, version = 0}
package.loaded["arena.touch"] = {
    layout = function() return {charge = {}} end,
    used = false,
}
package.loaded["arena.world"] = {
    build_overview = noop, forget_overview = noop,
    overview = function() return {grid = 0, rects = {}} end,
    radar_tiles = {}, radar_safe = {}, radar_doors = {},
}

local ui = require("arena.ui")
local pal = require("arena.palette")

local W, H = 1280, 800

-- Every seat's side, as the roster reports it. The two seats the snapshot
-- carries agree with the simulation, the way a live room does; the two it
-- does not are the seats under test.
local PILOTS = {
    [0] = {name = "you", label = "human", team = 3},
    [1] = {name = "near", label = "human", team = 4},
    [2] = {name = "farone", label = "human", team = 7},
    [3] = {name = "fartwo", label = "human", team = 9},
}

local function frame()
    package.loaded["arena.state"].n = 0
    ui.begin(layer, W, H, 1, false)
    ui.hud({
        me = 0,
        class_names = {"Apex"},
        menu_open = false,
        pilots = PILOTS,
        teams = {},
        feed = {},
        hurt = 0,
        charges = {},
        cam_x = sim.ship_x(0), cam_y = sim.ship_y(0),
        half_w = 640, half_h = 400,
        banner = "",
        lag = 4,
        stats = {lag = 4, lead = 0, err = 0, err_max = 0, rewind = 0,
                 snaps = 10, rx = 0, tx = 0},
        zone = "alpha",
    })
    ui.finish()
end

-- The color a drawn string was given, copied out rather than referenced:
-- `txt()` reuses its table entries, so a held reference is whatever the next
-- frame wrote in it.
local function color_of(s)
    local state = package.loaded["arena.state"]
    for k = 1, state.n do
        local t = state.text[k]
        if t.s == s then return {t.col[1], t.col[2], t.col[3]} end
    end
    return nil
end

local function same(a, b)
    if not a or not b then return false end
    return math.abs(a[1] - b[1]) < 0.001 and math.abs(a[2] - b[2]) < 0.001
       and math.abs(a[3] - b[3]) < 0.001
end

local function rgb(c) return {c[1], c[2], c[3]} end

-- --- the scoreboard ---------------------------------------------------------

ui.details = true
frame()

check("a seat in the snapshot wears its simulation side",
      same(color_of("near"), rgb(pal.team(4))),
      "seat 1 is team 4 in the simulation")
check("a seat out of the snapshot wears its roster side",
      same(color_of("farone"), rgb(pal.team(7))),
      "the simulation answers team zero for an absent seat")
check("two absent seats on different sides wear different colors",
      not same(color_of("farone"), color_of("fartwo")),
      "both drawn in team zero's color is the bug this test pins")
check("an absent seat does not wear team zero's color",
      not same(color_of("farone"), rgb(pal.team(0))),
      "team zero is what the zeroed simulation answers")

-- --- the info box -----------------------------------------------------------

-- Opened on a pilot the snapshot does not carry, which a click on their row
-- can always do: the row is drawn from the roster whether or not the seat is
-- in the window.
ui.inspect = 2
frame()

-- The TEAM row's value is drawn in the side's color, and the side of an
-- absent seat only exists in the roster. "private" is what an unnamed side
-- reads as, drawn through cased(), which upper-cases the interface's words.
check("the info box sides an absent seat from the roster",
      same(color_of("PRIVATE"), rgb(pal.team(7))),
      "the box is open on seat 2, whose roster side is 7")

ui.details = false
ui.inspect = nil

if fails > 0 then
    print(fails .. " check(s) failed")
    os.exit(1)
end
print("all checks passed")
