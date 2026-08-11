-- The guide's drawing path, driven through the real M.hud.
--
--     lua5.1 client/tests/guide_draw_test.lua
--
-- guide_test proves what the guide decides to say; this proves the saying.
-- The two meet nowhere else: guide_test stubs the interface out entirely, and
-- help_test never passes a guide line in, so without this file the code that
-- turns a line into pixels only ever runs in a live client. That is how a
-- crash shipped: the ship anchor read e.text where a card-based line carries
-- none, and the first green a new player picked up would have taken the
-- client down. Every anchor shape a line can carry is pushed through here.
package.path = "client/?.lua;" .. package.path
local layer = {n = 0, rects = {}}
local function noop(self) self.n = self.n + 1 end
for _, name in ipairs({"arc", "disc", "flush", "frame", "halo", "outline",
                       "quad", "reset", "ring", "seg", "seg_fade",
                       "skirt", "tri", "tri_fade"}) do layer[name] = noop end
function layer:rect(x, y, w, h, col)
    self.n = self.n + 1
    self.rects[#self.rects + 1] = {x = x, y = y, w = w, h = h}
end
local mods = {[0] = 1, [1] = 0, [2] = 1, [3] = 0, [4] = 0, [5] = 0}
_G.sim = {
    ship_count = function() return 2 end,
    ship_x = function(i) return 100 + i * 180 end,
    ship_y = function(i) return 100 + i * 120 end,
    ship_heading = function() return 0 end,
    ship_alive = function() return 1 end,
    ship_team = function(i) return i end,
    ship_carrier = function() return 255 end,
    ship_class = function() return 0 end,
    ship_energy = function() return 100 end,
    ship_max_energy = function() return 100 end,
    ship_kills = function() return 1 end,
    ship_deaths = function() return 1 end,
    ship_points = function() return 10 end,
    ship_bounty = function() return 34 end,
    ship_up = function() return 0 end,
    ship_level = function() return 1 end,
    ship_charge = function() return 2 end,
    ship_mod = function(_, t, m) return (t == 0 and mods[m]) or 0 end,
    ship_multi_off = function() return 0 end,
    charge_max = function() return 3 end,
    has_trigger = function() return true end,
    trigger_rate = function() return 1 end,
    tick = function() return 4242 end,
    weapon_count = function() return 3 end,
    prize_count = function() return 0 end,
    prize_at = function() return 0, 0, 0 end,
    flag_count = function() return 0 end,
    flag_at = function() return 0, 0, 255 end,
    map_coarse = function() return nil end,
    TRIG_GUN = 0, BTN_FIRE = 1,
}
local state = {text = {}, n = 0, version = 0}
package.loaded["arena.state"] = state
package.loaded["arena.touch"] = {layout = function() return {charge = {}} end, used = false}
package.loaded["arena.world"] = {
    build_overview = function() end, forget_overview = function() end,
    overview = {grid = 0, n = 0, rect = {}},
    radar_tiles = {160, 160}, radar_safe = {}, radar_doors = {},
}
local ui = require("arena.ui")
local W, H = 1280, 800
local function frame(g, touching)
    ui.map = false
    ui.begin(layer, W, H, 1, touching or false)
    ui.hud({
        me = 0, guide = g,
        class_names = {"Apex"}, menu_open = false,
        pilots = {[0] = {name = "you"}, [1] = {name = "someone"}},
        teams = {}, feed = {}, hurt = 0,
        charges = {{name = "repel", short = "RPL", max = 3, count = 2},
                   {name = "mine", short = "MNE", max = 3, count = 1}},
        cam_x = sim.ship_x(0), cam_y = sim.ship_y(0),
        half_w = 640, half_h = 400, banner = "", lag = 4,
        stats = {lag = 4, lead = 2, err = 1, err_max = 9, rewind = 3,
                 snaps = 120, rx = 0, tx = 0},
        zone = "z", fps = 60, frame_ms = 16, rx_rate = 0, tx_rate = 0,
    })
    ui.finish()
    local joined = {}
    for i = 1, state.n do joined[#joined + 1] = string.upper(state.text[i].s) end
    return table.concat(joined, " ")
end
local fails = 0
local function want(name, hay, needle)
    if hay:find(string.upper(needle), 1, true) then print("ok   " .. name)
    else fails = fails + 1 print("FAIL " .. name) end
end
want("ship anchor draws", frame({id = "steer", at = "ship",
     text = "Left and right turn your ship."}), "left and right")
want("instrument anchor draws", frame({id = "fire", at = "gun",
     text = "Space fires your guns."}), "space fires")
want("card entry resolves", frame({id = "green", at = "ship", card = "green"}),
     "greens contain prizes")
want("mine card resolves", frame({id = "charge", at = "charge:mine",
     card = "mine"}), "mines stay where you drop them")
want("radar anchor draws right-aligned", frame({id = "map", at = "radar",
     text = "M toggles a larger map."}), "larger map")
want("touch falls back to pad text", frame({id = "fire", at = "gun",
     text = "Space fires your guns.", pad = "The big pad fires."}, true),
     "big pad")
-- Instrument missing on touch (no corner stack): falls back to the ship.
want("gun anchor on touch falls back to ship", frame({id = "fire", at = "gun",
     text = "key words", pad = "pad words"}, true), "pad words")
if fails > 0 then print(fails .. " failed") os.exit(1) end
print("all good")
