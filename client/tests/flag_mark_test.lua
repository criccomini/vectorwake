-- Carrying the flag puts you on the map, and the instruments draw it.
--
--     lua5.1 client/tests/flag_mark_test.lua
--
-- Decision 132: the wire tells every client where every flag is, carried ones
-- included, so the client shows it. The dial draws the flags in its window
-- the way it always has, pins a carried enemy flag beyond the window to its
-- rim as a bearing, and leaves a grounded far flag to the map; the map view
-- draws every flag wherever it is. What this holds is each of those edges,
-- because every one of them is a quiet `if` a later change could lose.
--
-- Counted inside the instrument's own published box, against a flagless
-- frame. The HUD draws marks of its own, and every flag also adds one to the
-- strip at the top of the screen, so raw totals say nothing: what is asked is
-- how many landed on the dial, and where.

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

-- A flag's mark is a core inside a ring, and that ring is the one thing on
-- this screen drawn with `ring_aa`, so collecting those is exactly one row
-- per mark however many land on the same pixel. It was a staff and a triangle
-- and this counted triangles; the instruments draw what the arena draws, and
-- the arena stopped drawing cloth.
local rings = {}
local layer = {n = 0}
local function noop(self) self.n = self.n + 1 end
for _, name in ipairs({"arc", "arc_aa", "arc_fade", "bloom", "disc", "flush",
                       "frame", "halo", "outline", "quad", "rect", "reset",
                       "ring", "ring_fade", "seg", "seg_fade", "seg_flat",
                       "skirt", "tri", "tri_fade"}) do
    layer[name] = noop
end
layer.ring_aa = function(self, x, y, r)
    self.n = self.n + 1
    rings[#rings + 1] = {x = x, y = y, r = r}
end

local CAM = 5000

-- The flags this frame carries, swapped per case. Each row is what
-- `sim.flag_at` answers: x, y, owning team, carried.
local flags = {}

_G.sim = {
    ship_count = function() return 1 end,
    ship_x = function() return CAM end,
    ship_y = function() return CAM end,
    ship_heading = function() return 0 end,
    ship_active = function() return 1 end,
    ship_alive = function() return 1 end,
    ship_team = function() return 0 end,
    ship_class = function() return 0 end,
    ship_energy = function() return 100 end,
    ship_max_energy = function() return 100 end,
    ship_kills = function() return 0 end,
    ship_deaths = function() return 0 end,
    ship_assists = function() return 0 end,
    ship_up = function() return 0 end,
    ship_level = function() return 0 end,
    ship_charge = function() return 0 end,
    ship_mod = function() return 0 end,
    ship_multi_off = function() return 0 end,
    has_trigger = function() return true end,
    tick = function() return 4242 end,
    weapon_count = function() return 0 end,
    green_count = function() return 0 end,
    flag_count = function() return #flags end,
    flag_at = function(i)
        local f = flags[i + 1]
        return f[1], f[2], f[3], f[4]
    end,
    map_coarse = function() return nil end,
    BTN_FIRE = 1,
}

package.loaded["arena.state"] = dofile("client/arena/state.lua")
package.loaded["arena.touch"] = {
    layout = function() return {charge = {}} end,
    used = false,
}
local world = {
    build_overview = function() end,
    forget_overview = function() end,
    -- One cell of wall, so the map view has a grid to scale by. A table
    -- rather than a call: `overview` is the built product, not a getter.
    overview = {grid = 256, gw = 256, gh = 256, n = 5,
                rect = {10, 10, 1, 1, 1}},
    radar_tiles = {},
    radar_safe = {},
    radar_doors = {},
}
package.loaded["arena.world"] = world

local ui = require("arena.ui")
local state = package.loaded["arena.state"]

-- One frame on a monitor, and how many marks it took.
local function frame(map)
    rings = {}
    state.n = 0
    ui.details = false
    ui.map = map
    ui.begin(layer, 1280, 800, 1, false)
    ui.hud({
        me = 0,
        side = 0,
        viewer_name = "you",
        class_names = {"Apex", "Wedge"},
        menu_open = false,
        pilots = {[0] = {name = "you", label = "human"}},
        teams = {},
        match = {playing = true, left = 33, score = {[0] = 0, [1] = 0}},
        side_names = {[0] = "Pylon", [1] = "Caisson"},
        feed = {},
        hurt = 0,
        charges = {},
        cam_x = CAM, cam_y = CAM,
        half_w = 640, half_h = 400,
        banner = "",
        rtt = 4,
        zone = "war",
        fps = 60, frame_ms = 16.7, rx_rate = 0, tx_rate = 0,
    })
    ui.finish()
    local box
    for _, r in ipairs(ui.hits) do
        if r.action == "map" then box = r end
    end
    -- The marks that landed on the instrument, and the rightmost of them. By
    -- x alone: a mark's y goes through `ry` into the layer's flipped space
    -- while the hit box stays in the interface's, and the two do not compare.
    -- The x axis is the same in both, and at a monitor's width the dial's
    -- corner shares no x with the strip at the window's center, which is the
    -- only other place a flag draws.
    local inside, right = 0, nil
    if box then
        for _, t in ipairs(rings) do
            if t.x >= box.x and t.x <= box.x + box.w then
                inside = inside + 1
                if not right or t.x > right.x then right = t end
            end
        end
    end
    return inside, box, right
end

-- The dial's window is sixty tiles either side of the camera; these two are
-- squarely inside and far outside it.
local NEAR = {CAM + 300, CAM, 255, false}
local FAR_GROUND = {CAM + 5000, CAM, 1, false}
local FAR_CARRIED = {CAM + 5000, CAM, 1, true}
local FAR_OURS = {CAM + 5000, CAM, 0, true}

flags = {}
local base = frame(false)
flags = {NEAR}
check("a flag in the window draws on the dial", frame(false) == base + 1)

flags = {FAR_GROUND}
check("a grounded far flag waits for the map", frame(false) == base)

flags = {FAR_OURS}
check("our own runner is not pinned; your side you can ask", frame(false) == base)

flags = {FAR_CARRIED}
local n, box, pin = frame(false)
check("a carried enemy flag beyond the window pins to the rim", n == base + 1)
check("on the rim it left by, not floating mid-dial",
      box ~= nil and pin ~= nil and pin.x > box.x + box.w * 0.9,
      pin and box and (pin.x - box.x) .. " of " .. box.w)

-- The map view shows everything, which is the disclosure drawn honestly:
-- the wire already told every client all of this.
flags = {}
local map_base = frame(true)
flags = {NEAR, FAR_GROUND, FAR_CARRIED}
check("the map draws every flag wherever it is", frame(true) == map_base + 3)

os.exit(fails == 0 and 0 or 1)
