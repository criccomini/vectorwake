-- The interface's clickable rectangles: where they are, and what a press on
-- one actually reaches.
--
--     lua5.1 client/tests/hud_hits_test.lua
--
-- `ui.lua` publishes a list of boxes and `arena.script` takes the first one a
-- press lands in, so two rules govern every control on screen and neither is
-- written anywhere else.
--
-- The first is that the field of play holds no boxes at all. A press there is
-- a trigger pull: left is the gun, right is the bomb. A box over a hull, or
-- over the name beside it, swallows the press, so a player lined up on
-- somebody would pull and fire nothing. Asking who a pilot is belongs to the
-- scoreboard, where a click is a click.
--
-- The second is that order decides overlaps, and the scoreboard is where that
-- bites: each row publishes before the panel's own box, which exists to take
-- the wheel and would otherwise eat every press meant for a row.
--
-- Both are invisible until somebody is flying, on a build that takes six
-- minutes to publish. So this runs the real `M.hud` against a stubbed engine
-- and asks the questions a hand at a mouse would.

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
for _, name in ipairs({"arc", "disc", "flush", "frame", "outline", "quad", "rect",
                       "reset", "ring", "seg", "seg_fade", "skirt", "tri",
                       "tri_fade"}) do
    layer[name] = noop
end

-- The room. Ship 0 is us; the rest are strangers, all on one other team so
-- that the free-for-all test can hand out a team per seat instead.
local room = {count = 4, teams = {[0] = 1, 1, 1, 1}, alive = {}}
local sim = {
    ship_count = function() return room.count end,
    -- Spread so that all three strangers land on screen at the extents the
    -- harness uses, which is what makes the sweep below cover more than one.
    ship_x = function(i) return 100 + i * 180 end,
    ship_y = function(i) return 100 + i * 120 end,
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
        teams = o.teams or {},
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

-- --- the trigger owns the field of play ------------------------------------

-- Every ship on screen, pressed on the hull and on the label beside it. Both
-- have to fall through to nothing, or that press was a shot a player did not
-- get to take.
frame()
local scale = W / (2 * 640)
local tested = 0
for i = 1, 3 do
    local sx = W / 2 + (sim.ship_x(i) - sim.ship_x(0)) * scale
    local sy = H / 2 + (sim.ship_y(i) - sim.ship_y(0)) * scale
    if sx > 0 and sx < W and sy > 0 and sy < H then
        tested = tested + 1
        check("a press on ship " .. i .. "'s hull is not a click",
              press(sx, sy) == nil, "landed on " .. tostring(press(sx, sy)))
        -- Where the nameplate is drawn: the hull's lower right.
        check("a press on ship " .. i .. "'s name is not a click",
              press(sx + 30, sy + 14) == nil,
              "landed on " .. tostring(press(sx + 30, sy + 14)))
    end
end
check("the sweep found ships to press on", tested > 0)

-- --- the debug readout closes itself ---------------------------------------

-- What opens it is the LINK bars in the far corner, and on a phone the
-- readout lands under the dial a screen's width away from them. So the panel
-- itself has to be the way out, or a player who opened it has nothing to
-- press but the four bars they have no reason to look back at.
-- Both boxes carry the same action, so they are told apart by size: the
-- bars are a chip in the corner and the panel is a slab under the dial.
local function debug_boxes()
    local out = {}
    for _, r in ipairs(ui.hits) do
        if r.action == "debug" then out[#out + 1] = r end
    end
    return out
end

ui.debug = false
frame()
check("shut, only the bars answer", #debug_boxes() == 1,
      #debug_boxes() .. " boxes")

ui.debug = true
frame()
local dbg = debug_boxes()
check("open, the readout publishes a box of its own", #dbg == 2,
      #dbg .. " boxes")
local panel = dbg[#dbg]
if #dbg == 2 then
    check("and it is a slab rather than a chip",
          panel.w > 100 and panel.h > 40,
          string.format("%.0fx%.0f", panel.w, panel.h))
    -- Pressed in the middle, which is where a thumb finishing a read lands,
    -- and nowhere near the four bars that opened it.
    local act = press(panel.x + panel.w / 2, panel.y + panel.h / 2)
    check("a press in the middle of it closes it", act == "debug",
          "landed on " .. tostring(act))
    -- The corner it came from is a long way off, which is the whole reason
    -- this box exists.
    check("the bars are nowhere near it",
          math.abs((panel.y + panel.h / 2) - (dbg[1].y + dbg[1].h / 2)) > 40)
end
ui.debug = false

-- --- the menu takes the screen ---------------------------------------------

frame({menu_open = true})
check("the map is not clickable under the menu", box("map") == nil)
check("the debug readout is not clickable under the menu", box("debug") == nil)
ui.debug = true
frame({menu_open = true})
check("nor is the open readout under the menu", box("debug") == nil)
ui.debug = false

-- --- the scoreboard is where you ask ---------------------------------------

ui.details = true
frame()
check("a scoreboard row asks about its pilot", box("pilot", 3) ~= nil)
local row = box("pilot", 3)
-- The ordering rule, asked the way a hand asks it. The panel publishes its own
-- box to take the wheel; a row published after it would be unreachable.
check("a row's click reaches the pilot rather than the list",
      row ~= nil and press(row.x + 4, row.y + 4) == "pilot",
      "landed on " .. tostring(row and press(row.x + 4, row.y + 4)))
check("every row is tested before the panel that holds them",
      rank("pilot") ~= nil and rank("scores") ~= nil
      and rank("pilot") < rank("scores"))
ui.details = false

-- --- the roster is a list of names, ordered like one -----------------------
--
-- Your own side first, then everybody else as one group, and inside each of
-- them alphabetical without case deciding anything: a pilot who capitalises
-- their call sign does not get the top of the room for it.

ui.details = true
ui.sort = "name"
room.teams = {[0] = 1, 1, 9, 9}
frame({pilots = {[0] = {name = "zulu", label = "human"},
                 [1] = {name = "Alpha", label = "human"},
                 [2] = {name = "bravo", label = "human"},
                 [3] = {name = "Charlie", label = "human"}}})
-- Read out of the scoreboard's own column rather than off the whole screen:
-- the same names are drawn again over the hulls they belong to.
local order = {}
for k = 1, package.loaded["arena.state"].n do
    local t = package.loaded["arena.state"].text[k]
    for _, nm in ipairs({"zulu", "Alpha", "bravo", "Charlie"}) do
        if t.s == nm and t.x < 300 then order[#order + 1] = nm end
    end
end
check("your side comes first, then the rest, each alphabetical",
      table.concat(order, ",") == "Alpha,zulu,bravo,Charlie",
      table.concat(order, ","))
ui.details = false

-- --- the feed is bounded ---------------------------------------------------

-- Twelve lines offered, five drawn. The cap is the interface's, and the arena
-- trims its own buffer to the same number.
local many = {}
for i = 1, 12 do many[i] = {text = "line " .. i, t = 0} end
local before = package.loaded["arena.state"].n
frame({feed = many})
local lines = package.loaded["arena.state"].n
check("the feed is capped at FEED_MAX", ui.FEED_MAX == 5,
      "FEED_MAX is " .. tostring(ui.FEED_MAX))
check("a long feed still draws something", lines > 0 and before ~= nil)

-- A line is words with names in it, and the two are not set the same way: the
-- interface says its own words in capitals and quotes everybody else's. A call
-- sign is upper, lower and numeric exactly as its owner has it, and a feed
-- that shouted it back was the one place this pass got it wrong.
frame({feed = {{text = {{"Probe 7"}, " killed ", {"vX-9"}, " (+12)"}, t = 0}}})
local st_feed = package.loaded["arena.state"]
local said_line
for i = 1, st_feed.n do
    if st_feed.text[i].s:find("killed", 1, true)
       or st_feed.text[i].s:find("KILLED", 1, true) then
        said_line = st_feed.text[i].s
    end
end
check("a feed line shouts its own words and quotes the names",
      said_line == "Probe 7 KILLED vX-9 (+12)", tostring(said_line))

-- --- the info box ----------------------------------------------------------

-- It belongs to the scoreboard, which is the only thing that opens it.
ui.details = true
ui.inspect = 2
frame()
check("the info box publishes its close box", box("uninspect") ~= nil)

-- A pilot who left. The box goes with them rather than describing a seat that
-- is no longer in the room.
ui.inspect = 9
frame()
check("an info box for a departed pilot closes itself", ui.inspect == nil)

-- And it goes with the list it came from, rather than standing alone with
-- nothing on screen saying who it is about or how to get another.
ui.inspect = 2
ui.details = false
frame()
check("shutting the scoreboard shuts the info box", ui.inspect == nil)
check("and takes its close box with it", box("uninspect") == nil)

-- --- whose side a pilot is on ----------------------------------------------

-- The zone decides what may be said. A side it marks public is one anybody may
-- read; a private one is a squad who arranged themselves, and naming it here
-- would hand the room a roster the zone deliberately did not send.
--
-- Read off the drawn text, because that is what a player sees and the point of
-- the rule is what reaches them. Ship 0 is us on team 1; ship 3 is on team 9.
local function drawn()
    local st = package.loaded["arena.state"]
    local out = {}
    for k = 1, st.n do out[#out + 1] = string.upper(st.text[k].s) end
    return table.concat(out, "\n")
end
-- Case is typography, not content: what these ask is which words reach a
-- player, and the interface sets every one of them in capitals.
local function says(word)
    return drawn():find(string.upper(word), 1, true) ~= nil
end

room.teams = {[0] = 1, 1, 1, 9}
ui.details = true
ui.inspect = 3

frame({teams = {{team = 1, name = "blue", public = true},
                {team = 9, name = "gold", public = true}}})
check("a public side is named", says("gold"), "no side in: " .. drawn())

frame({teams = {{team = 1, name = "blue", public = true},
                {team = 9, name = "gold", public = false}}})
check("a private side is not named", not says("gold"))
check("and the row is dropped rather than blanked", not says("SIDE"))

-- Your own side is yours to know however it is marked, since you are in it.
room.teams = {[0] = 9, 1, 1, 9}
frame({teams = {{team = 9, name = "gold", public = false}}})
check("your own side is named even when it is private", says("gold"))

-- A zone that has sent no team list at all says nothing. Falling back to the
-- raw team byte would be the same leak by a duller instrument.
frame({teams = {}})
check("no team list means no side row", not says("SIDE"))

room.teams = {[0] = 1, 1, 1, 1}
ui.inspect = nil
ui.details = false

-- --- the debug readout -----------------------------------------------------

ui.debug = true
frame()
check("the debug readout keeps its own toggle clickable", box("debug") ~= nil)
ui.debug = false
ui.inspect = nil

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
