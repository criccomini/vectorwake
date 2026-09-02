-- The prizes lying on the ground in a free roam zone.
--
--     lua5.1 client/tests/greens_test.lua
--
-- Two dozen greens is six times what a flag game puts on a map, and every one
-- of them draws onto the same bounded glow layer the shots and the hulls use.
-- So what this holds is the culling: a field of greens on the far side of a
-- thousand-tile map must not cost a round fired on this side of it. The rest
-- is the plain reading of the wire, that an inactive slot draws nothing and an
-- active one draws a shape.
--
-- Then the same field on the dial, which is the other place a prize is looked
-- for and the place the zone sows them for: they are put out inside a ring
-- twenty-eight tiles across so they land on somebody's radar, and a prize a
-- pilot can only find by flying over it is one nobody goes and gets.
--
-- And last, what a pickup is called. The core reports one as a slot in the
-- kit space, which is a number, and the feed says a sentence.

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

-- --- the field, as this test arranges it -----------------------------------

local field = {}

_G.sim = {
    green_count = function() return #field end,
    green_at = function(i)
        local g = field[i + 1]
        return g.x, g.y, g.slot, g.active
    end,
    -- world.lua reads these at load; nothing here exercises them.
    ship_count = function() return 0 end,
    flag_count = function() return 0 end,
    weapon_count = function() return 0 end,
    map_w = function() return 1024 end,
    map_h = function() return 1024 end,
    T_EMPTY = 0, T_SOLID = 1, T_SAFE = 2, T_DOOR = 3, T_GOAL = 4,
    T_WORMHOLE = 5, T_OVER = 6, T_UNDER = 7, T_TURF = 8, T_SPAWN = 9,
    T_SLOPE = 10,
    EV_FIRE = 1, EV_BOUNCE = 2, EV_HIT = 3, EV_DEATH = 4, EV_SPAWN = 5,
    EV_EXPIRE = 6, EV_FLAG_TAKE = 8, EV_FLAG_DROP = 9, EV_CHARGE = 7,
    EV_GREEN = 15,
}

-- A layer that counts what was asked of it rather than drawing it.
local function layer()
    local l = {calls = 0}
    local function count() l.calls = l.calls + 1 end
    l.fan, l.outline, l.halo = count, count, count
    l.seg, l.tri, l.quad, l.rect, l.disc, l.ring = count, count, count, count, count, count
    l.tri_fade, l.glow_band = count, count
    return l
end

local ok, world = pcall(require, "arena.world")
if not ok then
    print("FAIL could not load arena.world  -- " .. tostring(world))
    os.exit(1)
end

local function draw(cull)
    local fill, glow = layer(), layer()
    world.greens(fill, glow, 0.0, cull)
    return fill.calls + glow.calls
end

-- The whole map, so nothing is culled for being far away.
local WIDE = {x0 = -1e6, x1 = 1e6, y0 = -1e6, y1 = 1e6}

field = {{x = 100, y = 100, slot = 0, active = true}}
check("an active green draws", draw(WIDE) > 0)

field = {{x = 100, y = 100, slot = 0, active = false}}
check("a green that has been taken draws nothing", draw(WIDE) == 0)

-- Every green in the field, and the same field with one of them off screen.
field = {}
for i = 1, 24 do
    field[i] = {x = 100 + i, y = 100, slot = i % 5, active = true}
end
local all = draw(WIDE)
check("two dozen of them all draw", all > 24)

local NARROW = {x0 = 0, x1 = 110, y0 = 0, y1 = 200}
local some = draw(NARROW)
check("and the ones off screen cost nothing", some < all, all .. " -> " .. some)

field = {{x = 9000, y = 9000, slot = 0, active = true}}
check("a green on the far side of the map draws nothing", draw(NARROW) == 0)

-- --- the same field, on the dial --------------------------------------------
--
-- Counted inside the dial's own published box, by the color: nothing else on
-- the instrument is drawn in the prize green, so every disc wearing it is a
-- green and there is no arithmetic to repeat here about where the square is.
--
-- The world stub goes in after the section above has run, because the harness
-- swaps `arena.world` for one of its own.

local harness = require("tests.ui_harness")
local pal = require("arena.palette")

local discs = {}
local order = {}
local ui_layer = harness.layer()
ui_layer.disc = function(_, x, y, r, _, col)
    discs[#discs + 1] = {x = x, y = y, r = r, col = col}
    if col and col[1] == pal.GREEN[1] and col[2] == pal.GREEN[2]
        and col[3] == pal.GREEN[3] then
        order[#order + 1] = "green"
    end
end
-- A contact is a diamond in the palette's own team color, passed through
-- rather than copied, so this finds exactly the hulls on the dial.
ui_layer.quad = function(_, _, _, _, _, _, _, _, _, col)
    if col == pal.FRIEND or col == pal.ENEMY then
        order[#order + 1] = "contact"
    end
end

-- Where the camera is, and the field around it in tiles off that point.
local CAM = 5000
local TILE = 16

local SIM = setmetatable({
    green_count = function() return #field end,
    green_at = function(i)
        local g = field[i + 1]
        return g.x, g.y, g.slot, g.active
    end,
    -- Two seats: yours, and one enemy near enough to land on the dial, since
    -- what the greens have to stay under is a contact.
    ship_count = function() return 2 end,
    ship_x = function(i) return CAM + i * 8 * TILE end,
    ship_y = function(i) return CAM + i * 6 * TILE end,
    ship_team = function(i) return i end,
    ship_alive = function() return 1 end,
    ship_active = function() return 1 end,
    ship_heading = function() return 0 end,
    ship_energy = function() return 100 end,
    ship_max_energy = function() return 100 end,
    has_trigger = function() return true end,
    flag_count = function() return 0 end,
    flag_at = function() return 0, 0, 255 end,
    map_coarse = function() return nil end,
    BTN_FIRE = 1,
}, {__index = function() return function() return 0 end end})

local ui = harness.install({sim = SIM})

-- One frame at a monitor's size, and the greens that landed on the dial.
local function dial()
    discs, order = {}, {}
    ui.details = false
    ui.map = false
    ui.begin(ui_layer, 1280, 800, 1, false)
    ui.hud({
        me = 0,
        side = 0,
        viewer_name = "you",
        class_names = {"Apex", "Wedge"},
        menu_open = false,
        pilots = {[0] = {name = "you", label = "human"},
                  [1] = {name = "them", label = "human"}},
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
        zone = "roam",
        fps = 60, frame_ms = 16.7, rx_rate = 0, tx_rate = 0,
    })
    ui.finish()

    local box
    for _, r in ipairs(ui.hits) do
        if r.action == "map" then box = r end
    end
    local n = 0
    for _, d in ipairs(discs) do
        local green = d.col and d.col[1] == pal.GREEN[1]
            and d.col[2] == pal.GREEN[2] and d.col[3] == pal.GREEN[3]
        if green and box and d.x >= box.x and d.x <= box.x + box.w then
            n = n + 1
        end
    end
    return n
end

field = {{x = CAM + 10 * TILE, y = CAM, slot = 0, active = true}}
check("a green in reach lands on the dial", dial() == 1)

field = {{x = CAM + 10 * TILE, y = CAM, slot = 0, active = false}}
check("one that has been taken does not", dial() == 0)

-- Past the sixty tiles the dial spans, which is also the radius the zone
-- filters a snapshot to: a client should never hold this green at all, and if
-- it does the instrument still has to leave it off.
field = {{x = CAM + 400 * TILE, y = CAM, slot = 0, active = true}}
check("and one on the far side of the map does not", dial() == 0)

field = {}
for i = 1, 24 do
    field[i] = {x = CAM + (i - 12) * 2 * TILE, y = CAM + (i % 7) * 3 * TILE,
                slot = i % 5, active = true}
end
local whole = dial()
check("a whole field in reach lands whole", whole == 24, whole .. " drawn")

-- What the order is for: a prize is a decision about where to fly next and a
-- contact is a decision about right now, so the dot must never be laid over
-- the hull.
local last_green, first_contact = 0, math.huge
for i, what in ipairs(order) do
    if what == "green" then last_green = i end
    if what == "contact" and i < first_contact then first_contact = i end
end
-- The contact has to have drawn, or this reads a frame with nothing to be
-- under and passes on an empty list.
check("the enemy on the dial drew", first_contact < math.huge)
check("and every green went under it", last_green < first_contact,
      "last green " .. last_green .. ", first contact " .. tostring(first_contact))

-- --- what a pickup is called ------------------------------------------------
--
-- The kit space as the core publishes it: five stats, a rung per trigger,
-- an add-on per trigger per kind, then the charges. Written out here rather
-- than asked of the extension, so a layout that moves has to move in a test
-- as well as in the words.

_G.sim = {
    UP_COUNT = 5, TRIG_COUNT = 2, MOD_COUNT = 6,
    SLOT_LEVEL0 = 5, SLOT_MOD0 = 7, SLOT_CHARGE0 = 19,
}
local prize = require("arena.prize")

-- The name, and only the name. A bare count in a sentence cannot be read:
-- "recharge x3" is not three recharges, and no phrasing of a number in a
-- feed line makes it one. The one number that stays is a rung, because a
-- rung is which weapon you are firing rather than how many you have.
check("a stat is named", prize.words(0, 1) == "energy", prize.words(0, 1))
check("and says nothing more when a pilot holds several",
      prize.words(1, 3) == "recharge", prize.words(1, 3))
check("a rung counts from one, the way the corner card does",
      prize.words(5, 1) == "gun level 2", prize.words(5, 1))
check("the second trigger is the bomb",
      prize.words(6, 2) == "bomb level 3", prize.words(6, 2))
check("an add-on says which trigger it landed on",
      prize.words(7, 1) == "gun spray", prize.words(7, 1))
check("jargon is spelled out, as it is on the card",
      prize.words(7 + 6 + 2, 1) == "bomb proximity detonation",
      prize.words(7 + 6 + 2, 1))
check("a charge is named", prize.words(19, 1) == "repel", prize.words(19, 1))
check("a full rack of one reads the same",
      prize.words(19, 3) == "repel", prize.words(19, 3))

-- A slot the core grew that this client has no word for still has to answer
-- something: a feed line reading "picked up" and nothing else is a bug a
-- player sees, where an unlovely word is one they shrug at.
check("a slot past the ones named still says something",
      prize.words(99, 1) ~= "" and prize.words(99, 1) ~= nil,
      tostring(prize.words(99, 1)))

-- Off a core that answers nothing, which is every test and tool that stubs
-- the engine: the layout falls back to the one that shipped and the words
-- still come out.
_G.sim = nil
check("with no core at all it still names the slot",
      prize.words(1, 3) == "recharge", tostring(prize.words(1, 3)))
check("and still counts a rung from one",
      prize.words(5, 1) == "gun level 2", tostring(prize.words(5, 1)))

os.exit(fails == 0 and 0 or 1)
