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
                       "reset", "ring", "seg", "seg_fade", "seg_fade_flat",
                       "skirt", "tri", "tri_fade"}) do
    layer[name] = noop
end

-- Rectangles are kept as well as counted, because one question here is
-- whether a box covers a drawing rather than whether a drawing happened:
-- the LINK bars are rects, and a toggle that misses them is the fault.
-- Bottom-up, the way the mesh takes them.
local rects = {}
layer.rect = function(self, x, y, w, h)
    self.n = self.n + 1
    rects[#rects + 1] = {x = x, y = y, w = w, h = h}
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
    -- Nobody is riding anybody unless a test says so.
    ship_carrier = function() return 255 end,
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
    rects = {}
    package.loaded["arena.state"].n = 0
    ui.begin(layer, W, H, 1, false)
    ui.hud({
        me = 0,
        class_names = {"Apex", "Wedge", "Chord", "Anvil", "Facet", "Cipher",
                       "Lattice"},
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
        rooms = o.rooms, room = o.room,
        safe = o.safe, safe_limit = o.safe_limit,
        fps = 60, frame_ms = 16.7, rx_rate = 31000, tx_rate = 700,
    })
    -- Where the frame loop draws it, and the placement is the point: the card
    -- drops every box published before it, so it has to come after everything
    -- that publishes one.
    ui.room_card(o.rooms)
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

-- And what that one box has to cover is the thing it looks like: the whole
-- word LINK and all four of its bars. It used to be a rectangle hung off the
-- right edge that took the bars and the last quarter of the word, so most of
-- the only label on screen saying LINK did nothing when pressed, which is
-- what made it hard to hit on a phone.
do
    local chip = debug_boxes()[1]
    -- The word, from the text the interface published. Right-pivoted, so it
    -- runs leftward from where it was placed, and stored bottom-up.
    local st = package.loaded["arena.state"]
    local wx0, wx1, wy
    for k = 1, st.n do
        local t = st.text[k]
        if t.s == "LINK" then
            wx1 = t.x
            wx0 = t.x - #t.s * t.px * (1233 / 2048)
            wy = H - t.y
        end
    end
    check("the readout draws its word", wx0 ~= nil)
    if wx0 and chip then
        check("the toggle covers the whole word",
              wx0 >= chip.x and wx1 <= chip.x + chip.w
              and wy >= chip.y and wy <= chip.y + chip.h,
              string.format("word %.0f..%.0f at %.0f, box %.0f..%.0f y %.0f..%.0f",
                            wx0, wx1, wy, chip.x, chip.x + chip.w,
                            chip.y, chip.y + chip.h))
        -- The bars: the four small rects in the same strip.
        local bars = 0
        for _, r in ipairs(rects) do
            local top = H - (r.y + r.h)
            if r.w < 8 and top < chip.y + chip.h + 8 and r.x > W / 2 then
                bars = bars + 1
                check("bar at x " .. math.floor(r.x) .. " is inside the toggle",
                      r.x >= chip.x and r.x + r.w <= chip.x + chip.w
                      and top >= chip.y and H - r.y <= chip.y + chip.h)
            end
        end
        check("all four bars were found", bars == 4, bars .. " bars")
        -- And it is a target rather than a hairline. A thumb wants about
        -- forty points; the strip above the dial is what the layout leaves,
        -- so the width makes up what the height cannot.
        check("the toggle is a thumb's worth of screen",
              chip.w >= 60 and chip.h >= 24 and chip.w * chip.h >= 44 * 44 * 0.9,
              string.format("%.0fx%.0f", chip.w, chip.h))
        -- Anchored at the very top, so a thumb aiming for the corner cannot
        -- overshoot upward past it.
        check("it starts at the top edge", chip.y <= 0.01,
              string.format("y %.1f", chip.y))
        -- And it stops where the dial starts, because the dial is the
        -- control that opens the map and one control does not eat another.
        local mapbox = box("map")
        check("it does not reach into the dial",
              mapbox ~= nil and chip.y + chip.h <= mapbox.y + 0.01,
              mapbox and string.format("box ends %.0f, dial starts %.0f",
                                       chip.y + chip.h, mapbox.y) or "no map box")
    end
end

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

-- --- the rooms list, and the question it raises ----------------------------
--
-- The panel stands in the scoreboard's slot and behaves the way it does: rows
-- before the box that takes the wheel, and the row you are already in is read
-- rather than pressed. The question is the part worth pinning. It dims the
-- whole readout while it stands, and it shipped once with nothing drawing it,
-- so a press on a room darkened the instruments and offered nothing to answer.

local ROOMS = {{n = 1, players = 3, bots = 20},
               {n = 2, players = 0, bots = 51},
               {n = 4, players = 9, bots = 12, full = true}}

ui.rooms_open = true
frame({rooms = ROOMS, room = 1})
check("a room you are not in is a room you can press", box("room", 2) ~= nil)
check("the room you are in is not", box("room", 1) == nil)
check("nor is a full one", box("room", 4) == nil)
check("rows are tested before the panel that holds them",
      rank("room") ~= nil and rank("rooms_list") ~= nil
      and rank("room") < rank("rooms_list"))

ui.room_ask = 2
frame({rooms = ROOMS, room = 1})
check("pressing a room asks about it", box("room_answer") ~= nil)
check("and the question is the only thing on screen that can be pressed",
      box("rooms_list") == nil and box("room") == nil)
local move = box("room_answer")
check("the first answer is the one that moves",
      move ~= nil and press(move.x + 4, move.y + 4) == "room_answer")

-- A question about a room that is gone by the time it is drawn puts itself
-- away, rather than dimming the screen over a card naming nothing.
ui.room_ask = 7
frame({rooms = ROOMS, room = 1})
check("a question about a reclaimed room clears itself", ui.room_ask == nil)
check("and the list underneath comes back", box("rooms_list") ~= nil)
ui.rooms_open = false

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

-- --- and it carries four numbers in 248 points ------------------------------
--
-- Kills, deaths, points and bounty, right-aligned off the panel's edge, with a
-- name and a bot mark to the left of them. Points is the wide one: five digits
-- after a long session, where the rest are two or three. Fixed offsets fitted
-- three columns and could not fit four, so the widths are measured off the
-- numbers in the room, and this is the question a fixed offset got wrong.
--
-- Asked with the widest row a room can produce. Everything on it is either
-- left- or right-pivoted text, so the spans are exact, and none of them may
-- touch: a scoreboard whose columns collide reads as one long number.

ui.details = true
ui.sort = "name"
room.teams = {[0] = 1, 1, 1, 1}
local kills, deaths, points, bounty =
    sim.ship_kills, sim.ship_deaths, sim.ship_points, sim.ship_bounty
sim.ship_kills = function(i) return i == 1 and 137 or 1 end
sim.ship_deaths = function(i) return i == 1 and 118 or 1 end
sim.ship_points = function(i) return i == 1 and 12750 or 1 end
sim.ship_bounty = function(i) return i == 1 and 812 or 1 end
frame({pilots = {[0] = {name = "aaa", label = "human"},
                 [1] = {name = "Wintermute-99", label = "bot", ai = true},
                 [2] = {name = "ccc", label = "human"},
                 [3] = {name = "ddd", label = "human"}}})
do
    local st = package.loaded["arena.state"]
    -- The widest row, found by its points, and then everything sharing its
    -- baseline inside the panel. Bottom-up, so one y is one row.
    local row_y
    for k = 1, st.n do
        local t = st.text[k]
        if t.s == "12750" and t.x < 300 then row_y = t.y end
    end
    local span = {}
    for k = 1, st.n do
        local t = st.text[k]
        if t.y == row_y and t.x < 300 then
            local wide = #t.s * t.px * (1233 / 2048)
            local x0 = t.pivot == "right" and (t.x - wide) or t.x
            span[#span + 1] = {s = t.s, x0 = x0, x1 = x0 + wide}
        end
    end
    table.sort(span, function(a, b) return a.x0 < b.x0 end)
    check("the widest row draws a name and four numbers", #span == 5,
          "drew " .. #span)
    for k = 2, #span do
        check(string.format("%s clears %s", span[k].s, span[k - 1].s),
              span[k].x0 >= span[k - 1].x1,
              string.format("%.1f into %.1f", span[k].x0, span[k - 1].x1))
    end
    -- The bot mark has a column of its own between the name and the kills, so
    -- the marks line up down the list rather than trailing each name. It is
    -- drawn rather than written, so what is measurable here is the gap the
    -- name gives up for it: MARK_K plus the gap either side.
    if #span == 5 then
        check("the name leaves the mark its column",
              span[2].x0 - span[1].x1 >= 11 + 7,
              string.format("%.1f of gap", span[2].x0 - span[1].x1))
    end
end
sim.ship_kills, sim.ship_deaths = kills, deaths
sim.ship_points, sim.ship_bounty = points, bounty
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

-- A line is words with names in it, and neither is touched. A call sign is
-- upper, lower and numeric exactly as its owner has it, which a feed that
-- shouted it back got wrong once; and the words between the names stay lower,
-- because this is the one panel setting a sentence about people rather than
-- labelling an instrument, and leaving the names as the only capitals on the
-- line is what makes them findable.
frame({feed = {{text = {{"Probe 7"}, " killed ", {"vX-9"}, " (+12)"}, t = 0}}})
local st_feed = package.loaded["arena.state"]
local said_line
for i = 1, st_feed.n do
    if st_feed.text[i].s:lower():find("killed", 1, true) then
        said_line = st_feed.text[i].s
    end
end
check("a feed line quotes the names and does not shout its own words",
      said_line == "Probe 7 killed vX-9 (+12)", tostring(said_line))

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

-- --- the tier a pilot wears ------------------------------------------------
--
-- The band is the only thing a player is ever told about a rating, so if it
-- does not reach this panel then the whole ladder is a number two servers
-- pass between themselves. It travels on the roster and is recomputed on
-- every kill, and for a long time it arrived and was drawn nowhere.
--
-- Read off the drawn text for the same reason the team rows are: what is
-- being asked is what reaches a player.

-- A whole drawn string rather than a substring of all of them. "ACE" sits
-- inside "SPACE", so the obvious spelling of this test passes on text that
-- has nothing to do with the ladder.
local function drew(word)
    local st = package.loaded["arena.state"]
    for k = 1, st.n do
        if st.text[k].s:upper() == word:upper() then return true end
    end
    return false
end

ui.inspect = 1

frame({pilots = {[0] = {name = "you", label = "human"},
                 [1] = {name = "someone", label = "human", tier = "Ace"}}})
check("the tier reaches the panel", drew("Ace"), drawn())
check("under a label saying what it is", drew("TIER"))

-- Provisional is the absence of an answer rather than a low one. A newcomer
-- who read as the bottom band would be told something untrue about
-- themselves on their first evening.
frame({pilots = {[0] = {name = "you", label = "human"},
                 [1] = {name = "someone", label = "human", tier = "placing"}}})
check("a pilot still placing says so", drew("placing"), drawn())
check("and is not given the bottom band instead", not drew("Newb"))

-- A roster that never carried one at all. The row is still drawn, because a
-- panel with a hole where a row belongs reads as a bug rather than as
-- silence, and "unrated" is the honest word for it.
frame({pilots = {[0] = {name = "you", label = "human"},
                 [1] = {name = "someone", label = "human"}}})
check("a pilot with no tier at all still gets the row", drew("unrated"), drawn())

ui.inspect = nil
ui.details = false

-- --- the debug readout -----------------------------------------------------

ui.debug = true
frame()
check("the debug readout keeps its own toggle clickable", box("debug") ~= nil)
ui.debug = false
ui.inspect = nil

-- --- the safe zone says so, and says what it is about to cost ------------
--
-- A safe zone is the one part of the map whose rules are different and the
-- tile says so in color alone. And the room takes the seat back after a
-- while, which is a thing that has to be said before it happens rather than
-- after: a hull that simply stops being yours reads as a disconnection.
--
-- The countdown is read off the drawn text because the arithmetic is the
-- whole of it. Ticks in, seconds out, rounded up so the last second is a 1:
-- a readout that sits on zero while the hull is still there is a readout
-- saying the wrong thing at the one moment anybody is looking at it.

frame()
check("nothing is said in open space", not says("SAFE ZONE"))

frame({safe = 300, safe_limit = 6000})
check("a safe zone names itself", says("SAFE ZONE"))
check("and says what is left", says("seat released in 57"), drawn())

frame({safe = 5951, safe_limit = 6000})
check("the last second is a one rather than a zero",
      says("seat released in 1"), drawn())

frame({safe = 6000, safe_limit = 6000})
check("and it never goes negative", says("seat released in 0"), drawn())

frame({safe = 300, safe_limit = 0})
check("a room with no limit still names the zone", says("SAFE ZONE"))
check("and counts nothing down", not says("seat released"), drawn())

-- --- and the corner says nothing about a room there is only one of --------
--
-- A zone that holds one room seats everybody in room 1, so the chip drew
-- "ROOM 1" beside a key that opened a list of the room the player was already
-- standing in. The number cannot tell: it is 1 either way. What tells is the
-- zone's room list, which the directory drops to nil below two.

ui.rooms_open = false
frame({room = 1})
check("one room is not worth a chip", not says("ROOM"), drawn())
check("and there is nothing to press for it", box("rooms") == nil)

frame({room = 1, rooms = ROOMS})
check("several rooms bring it back", says("ROOM 1"))
check("with a way into the list", box("rooms") ~= nil)

-- The server's answer, not the row that was pressed: a room can fill between
-- a list being drawn and a key landing.
frame({room = 3, rooms = ROOMS})
check("and it says the room the server seated us in", says("ROOM 3"))

-- A welcome that has not landed leaves nothing to say, however many rooms the
-- zone is holding.
frame({rooms = ROOMS})
check("no answer yet is no chip", not says("ROOM"), drawn())

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
