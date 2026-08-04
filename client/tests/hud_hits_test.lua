-- The interface's clickable rectangles, and what wins when two overlap.
--
--     lua5.1 client/tests/hud_hits_test.lua
--
-- `ui.lua` publishes a list of boxes and `arena.script` takes the first one a
-- press lands in. That makes the order the boxes are added into a rule about
-- which control the player gets, and nothing else in the tree states it: a
-- ship drifting under the radar publishes a box over the radar's, and if it
-- were added first, a click meant for the map would open a stranger's record
-- instead. The only other way to find that out is to fly under the dial and
-- click, on a build that takes six minutes to publish.
--
-- So this runs the real `M.hud` against a stubbed engine and asks the
-- questions a hand at a mouse would: what is on screen, and what does a press
-- at these coordinates hit.

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

-- Every mesh call lands here and is counted rather than drawn. The test cares
-- that geometry was emitted, never what it looked like.
local layer = {n = 0}
local function noop(self) self.n = self.n + 1 end
for _, name in ipairs({"disc", "flush", "frame", "outline", "quad", "rect",
                       "reset", "ring", "seg", "seg_fade", "skirt", "tri",
                       "tri_fade"}) do
    layer[name] = noop
end

-- The room. Ship 0 is us; the rest are strangers, all on one other team so
-- that the free-for-all test can hand out a team per seat instead.
local room = {count = 4, teams = {[0] = 1, 1, 1, 1}, alive = {}}
local sim = {
    ship_count = function() return room.count end,
    ship_x = function(i) return 100 + i * 500 end,
    ship_y = function(i) return 100 + i * 300 end,
    ship_heading = function() return 0 end,
    ship_alive = function(i) return room.alive[i] == false and 0 or 1 end,
    ship_team = function(i) return room.teams[i] or 0 end,
    ship_class = function() return 0 end,
    ship_energy = function() return 100 end,
    ship_max_energy = function() return 100 end,
    ship_kills = function(i) return i * 2 end,
    ship_deaths = function(i) return i end,
    ship_points = function(i) return i * 10 end,
    ship_bounty = function(i) return 7 + i end,
    ship_up = function() return 0 end,
    ship_level = function() return 0 end,
    ship_charge = function() return 0 end,
    ship_mod = function() return 0 end,
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
    BTN_FIRE = 1,
}
_G.sim = sim

-- `state` is a plain table of text the gui script drains, and `touch` only
-- has to answer that nothing is being touched.
package.loaded["arena.state"] = {text = {}, n = 0, version = 0}
package.loaded["arena.touch"] = {
    layout = function() return {charge = {}} end,
    used = false,
}
package.loaded["arena.world"] = {
    build_overview = function() end,
    forget_overview = function() end,
    overview = function() return {grid = 0, rects = {}} end,
    -- Flat pairs of world coordinates, which the radar walks two at a time.
    radar_tiles = {160, 160},
    radar_safe = {},
    radar_doors = {},
}

local ui = require("arena.ui")

-- --- the harness -----------------------------------------------------------

local W, H = 1280, 800

-- One frame, with whatever the caller wants to be true about the room.
local function frame(o)
    o = o or {}
    ui.begin(layer, W, H, 1, false)
    ui.hud({
        me = 0,
        class_names = {"Apex", "Wedge", "Chord", "Anvil", "Facet", "Cipher",
                       "Lattice", "Spire"},
        menu_open = o.menu_open or false,
        pilots = o.pilots or {
            [0] = {name = "you", label = "human"},
            [1] = {name = "someone", label = "human"},
            [2] = {name = "a bot", label = "bot", ai = true, house = true},
            [3] = {name = "a guest", label = "unknown"},
        },
        feed = o.feed or {},
        hurt = 0,
        charges = {},
        cam_x = sim.ship_x(0), cam_y = sim.ship_y(0),
        half_w = 640, half_h = 400,
        banner = "",
        lag = 4,
        stats = {lag = 4, lead = 2, err = 1.5, err_max = 9.0, rewind = 3,
                 snaps = 120, rx = 0, tx = 0},
        zone = "chaos",
        fps = 60, frame_ms = 16.7, rx_rate = 31000, tx_rate = 700,
    })
    ui.finish()
end

-- What a press at this point lands on, by the same rule `on_input` uses: the
-- first box in publication order that contains it.
local function press(x, y)
    for _, r in ipairs(ui.hits) do
        if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
            return r.action, r.value
        end
    end
    return nil
end

-- Where a box with this action was published, or nil. Used to compare the
-- standing of two boxes that do not overlap on this screen.
local function rank(action)
    for i, r in ipairs(ui.hits) do
        if r.action == action then return i end
    end
    return nil
end

local function box(action, value)
    for _, r in ipairs(ui.hits) do
        if r.action == action and (value == nil or r.value == value) then
            return r
        end
    end
    return nil
end

-- --- the world is behind every panel ---------------------------------------

frame()
check("a ship publishes a box to ask about it", box("pilot", 1) ~= nil)

-- The rule this file exists for. Every panel is tested before the world, so a
-- ship flying under one cannot take its clicks.
local world_at = rank("pilot")
for _, panel in ipairs({"map", "debug", "open", "details"}) do
    local at = rank(panel)
    check(panel .. " is tested before any ship",
          at ~= nil and world_at ~= nil and at < world_at,
          "panel at " .. tostring(at) .. ", ships from " .. tostring(world_at))
end

-- And the same thing asked the way a player would ask it: a press on the dial
-- opens the map even when a name is under it. Ship 2 is parked on the radar.
--
-- The camera sits on ship 0 and the projection is a pixel per unit at these
-- extents, so screen (1160, 90) is world (620, -210). The label hangs off the
-- hull's lower right, which puts it inside the dial: 168 wide against the
-- right margin.
local held_x, held_y = sim.ship_x, sim.ship_y
sim.ship_x = function(i) return i == 2 and 620 or held_x(i) end
sim.ship_y = function(i) return i == 2 and -210 or held_y(i) end
frame()
local dial = box("map")
local dx, dy = dial.x + dial.w / 2, dial.y + dial.h / 2
-- The setup is only worth anything if a ship really is under the dial, so the
-- test says so rather than trusting the arithmetic above.
local over = false
for _, r in ipairs(ui.hits) do
    if r.action == "pilot" and dx >= r.x and dx <= r.x + r.w
       and dy >= r.y and dy <= r.y + r.h then over = true end
end
check("the setup put a ship under the dial", over)
check("a press on the dial is the dial, whoever is flying over it",
      press(dx, dy) == "map", "landed on " .. tostring(press(dx, dy)))
sim.ship_x, sim.ship_y = held_x, held_y

-- --- the trigger keeps the hull --------------------------------------------

-- The left button is the gun, so a box over a ship would eat the shot at the
-- moment a player is lined up on somebody. Only the name is clickable, and a
-- press on the hull itself has to fall through to nothing.
frame()
local scale = W / (2 * 640)
for _, i in ipairs({1, 2, 3}) do
    local sx = W / 2 + (sim.ship_x(i) - sim.ship_x(0)) * scale
    local sy = H / 2 + (sim.ship_y(i) - sim.ship_y(0)) * scale
    if sx > 0 and sx < W and sy > 0 and sy < H then
        check("a press on ship " .. i .. "'s hull is not a click",
              press(sx, sy) == nil,
              "landed on " .. tostring(press(sx, sy)))
        check("a press on ship " .. i .. "'s name asks about them",
              press(sx + 30 * 1, sy + 10 * 1) == "pilot",
              "landed on " .. tostring(press(sx + 30, sy + 10)))
    end
end

-- --- the menu takes the screen ---------------------------------------------

frame({menu_open = true})
check("no ship is clickable under the menu", box("pilot", 1) == nil)
check("the map is not clickable under the menu", box("map") == nil)
check("the debug readout is not clickable under the menu", box("debug") == nil)

-- --- the scoreboard is the other way to ask --------------------------------

ui.details = true
frame()
check("a scoreboard row asks about its pilot", box("pilot", 3) ~= nil)
local row = box("pilot", 3)
check("a row's click reaches the pilot rather than the list",
      row ~= nil and press(row.x + 4, row.y + 4) == "pilot",
      "landed on " .. tostring(row and press(row.x + 4, row.y + 4)))
ui.details = false

-- --- the feed is bounded ---------------------------------------------------

-- Twelve lines offered, five drawn. The cap is the interface's, and the arena
-- trims its own buffer to the same number.
local many = {}
for i = 1, 12 do many[i] = {text = "line " .. i, t = 0} end
local before = package.loaded["arena.state"].n
frame({feed = many})
local drawn = package.loaded["arena.state"].n
check("the feed is capped at FEED_MAX", ui.FEED_MAX == 5,
      "FEED_MAX is " .. tostring(ui.FEED_MAX))
check("a long feed still draws something", drawn > 0 and before ~= nil)

-- --- the info box ----------------------------------------------------------

ui.inspect = 2
frame()
check("the info box publishes its close box", box("uninspect") ~= nil)
check("the close box is tested before the world",
      rank("uninspect") ~= nil and rank("uninspect") < rank("pilot"))

-- A pilot who left. The box goes with them rather than describing a seat that
-- is no longer in the room.
ui.inspect = 9
frame()
check("an info box for a departed pilot closes itself", ui.inspect == nil)

-- --- the debug readout -----------------------------------------------------

ui.debug = true
frame()
check("the debug readout keeps its own toggle clickable", box("debug") ~= nil)
ui.debug = false
ui.inspect = nil

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
