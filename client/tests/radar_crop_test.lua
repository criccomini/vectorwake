-- The bite a small screen takes out of the dial.
--
--     lua5.1 client/tests/radar_crop_test.lua
--
-- The dial is 168 points square on every window, which on a phone is most of
-- a corner: 43% of a 390-point axis, standing in the one place an attack
-- comes from. The compact dial gives two thirds of that back.
--
-- What makes it safe to take is that the side and the reach are cropped by
-- the same factor. The dial is a diagram at a fixed scale, so cutting the
-- square alone would have squeezed sixty tiles into fewer pixels and cost
-- every blip and every contact the separation it needs to be read at all;
-- cutting both leaves the scale exactly where it was and simply shows less
-- ground. That is the claim worth a test, because it is the one a later edit
-- to either number would quietly break, and because it is invisible until
-- somebody is flying on a phone.
--
-- So this measures rather than recomputes: it runs the real `M.hud` at a
-- phone's size and at a monitor's, takes the dial's own published box, and
-- reads the scale off two terrain blips a known distance apart.

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

local rects = {}
local layer = {n = 0}
local function noop(self) self.n = self.n + 1 end
for _, name in ipairs({"arc", "disc", "flush", "frame", "halo", "outline",
                       "quad", "reset", "ring", "seg", "seg_fade", "seg_flat",
                       "skirt", "tri", "tri_fade"}) do
    layer[name] = noop
end
-- Recorded rather than counted: the blips are rectangles and their spacing is
-- the whole measurement.
layer.rect = function(self, x, y, w, h, col)
    self.n = self.n + 1
    rects[#rects + 1] = {x = x, y = y, w = w, h = h, col = col}
end

-- Where the camera is, and the one hull on the field, which is yours. A room
-- of one draws no contacts, so the only marks inside the dial are the terrain
-- blips this test puts there.
local CAM = 100

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
    ship_points = function() return 0 end,
    ship_bounty = function() return 1 end,
    ship_up = function() return 0 end,
    ship_level = function() return 0 end,
    ship_charge = function() return 0 end,
    ship_mod = function() return 0 end,
    ship_multi_off = function() return 0 end,
    has_trigger = function() return true end,
    tick = function() return 4242 end,
    weapon_count = function() return 0 end,
    flag_count = function() return 0 end,
    flag_at = function() return 0, 0, 255 end,
    map_coarse = function() return nil end,
    BTN_FIRE = 1,
}

package.loaded["arena.state"] = dofile("client/arena/state.lua")
package.loaded["arena.touch"] = {
    layout = function() return {charge = {}} end,
    used = false,
}
-- Two samples on one row, a known number of tiles apart. Both sit inside the
-- cropped dial as well as the full one, which is what lets one pair measure
-- the scale of either.
local TILE = 16
local APART = 30
local world = {
    build_overview = function() end,
    forget_overview = function() end,
    overview = function() return {grid = 0, rects = {}} end,
    radar_tiles = {CAM, CAM, CAM + APART * TILE, CAM},
    radar_safe = {},
    radar_doors = {},
}
package.loaded["arena.world"] = world

local ui = require("arena.ui")
local pal = require("arena.palette")
local state = package.loaded["arena.state"]

-- --- the harness -----------------------------------------------------------

-- One frame at a given window, and what the dial did in it.
--
-- Density one throughout, so a point is a pixel and the two windows are
-- directly comparable. The size class is read off the window's short axis, so
-- 390 by 844 is a phone either way up and 1280 by 800 is not.
local function measure(w, h)
    rects = {}
    state.n = 0
    ui.details = false
    ui.map = false
    ui.begin(layer, w, h, 1, false)
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
        half_w = w / 2, half_h = h / 2,
        banner = "",
        rtt = 4,
        zone = "melee",
        fps = 60, frame_ms = 16.7, rx_rate = 0, tx_rate = 0,
    })
    ui.finish()

    -- The dial's box, as the dial itself published it: pressing the square is
    -- how the map opens, so the instrument files its own extent and this asks
    -- for it rather than working the corner out a second time here.
    local box
    for _, r in ipairs(ui.hits) do
        if r.action == "map" then box = r end
    end

    -- The blips, by the color they are drawn in. `pal.a` builds a fresh color
    -- per call, so everything else that wears this ink at some alpha carries a
    -- copy; the terrain pass is the one that passes the palette's own table
    -- through, and an identity test finds exactly it.
    local blips = {}
    for _, r in ipairs(rects) do
        if r.col == pal.RADAR_TILE then blips[#blips + 1] = r end
    end
    table.sort(blips, function(a, b) return a.x < b.x end)
    -- Asked here rather than after the fact: it reports on the frame that was
    -- last laid out, and every window this test draws would otherwise answer
    -- with the measurements of whichever one ran last.
    return {box = box, blips = blips, span = ui.radar_span()}
end

local phone = measure(390, 844)
local land = measure(844, 390)
local desk = measure(1280, 800)

-- --- both windows draw the pair ---------------------------------------------

-- Nothing below means anything if the samples fell outside the square, and a
-- cropped dial is exactly the thing that could put them there.
check("a phone draws both terrain samples", #phone.blips == 2,
      #phone.blips .. " blips")
check("and so does a monitor", #desk.blips == 2, #desk.blips .. " blips")
check("both windows publish a dial", phone.box ~= nil and desk.box ~= nil)

if #phone.blips == 2 and #desk.blips == 2 and phone.box and desk.box then
    -- What one tile is worth on screen, read off the gap between two samples
    -- a known number of tiles apart.
    local function scale(m) return (m.blips[2].x - m.blips[1].x) / APART end
    local phone_k, desk_k = scale(phone), scale(desk)

    -- --- the room comes back ------------------------------------------------

    check("a phone gets a smaller dial than a monitor",
          phone.box.w < desk.box.w,
          string.format("%.0f against %.0f", phone.box.w, desk.box.w))
    -- Two thirds, the factor written down in ui.lua. Named here as a number
    -- rather than read out of the file, so changing it is a decision that has
    -- to be made in both places.
    check("and it is two thirds of it",
          math.abs(phone.box.w / desk.box.w - 2 / 3) < 0.01,
          string.format("%.3f", phone.box.w / desk.box.w))
    -- Both directions the corner was crowding, each asked against the axis it
    -- actually eats. Upright the dial is a width: it was 43% of a 390-point
    -- screen. On its side it is a height, and the readout hanging off its foot
    -- counts too, which is what `radar_span` is for; that was 63% of the
    -- window before the crop, so a feed under it began below the midline.
    check("the dial is under a third of a phone's width",
          phone.box.w / 390 < 1 / 3,
          string.format("%.0f of 390", phone.box.w))
    check("and on its side the instrument clears half the height",
          land.span < 390 / 2,
          string.format("%.0f of 390", land.span))

    -- --- and the scale does not move ----------------------------------------

    -- The whole point. A blip is under three pixels and a contact is a
    -- five-pixel diamond, so a dial that kept its reach while losing a third
    -- of its side would draw both a third closer together, and two ships
    -- flying side by side would land on one mark.
    --
    -- The tolerance is a rounding allowance, not a margin: blips snap to whole
    -- pixels, so a pair thirty tiles apart can sit a pixel wide of where the
    -- arithmetic puts it, which is a thirtieth of a pixel per tile.
    check("a tile is worth the same pixels either way",
          math.abs(phone_k - desk_k) < 0.05,
          string.format("%.3f against %.3f", phone_k, desk_k))

    -- --- what pays for it ---------------------------------------------------

    -- Reach, in tiles, derived from the two measurements above rather than
    -- from either constant: half the square divided by what a tile is worth.
    -- Sixty is the reach the zone culls a snapshot to, and forty is a phone's
    -- own screen twice over, since its short axis holds forty tiles.
    local function reach(m, k) return m.box.w / k / 2 end
    check("a monitor reaches the sixty tiles the zone sends",
          math.abs(reach(desk, desk_k) - 60) < 1,
          string.format("%.1f tiles", reach(desk, desk_k)))
    check("and a phone reaches forty, which is a screen either side",
          math.abs(reach(phone, phone_k) - 40) < 1,
          string.format("%.1f tiles", reach(phone, phone_k)))
end

print(fails == 0 and "all ok" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
