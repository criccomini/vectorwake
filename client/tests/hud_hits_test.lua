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
for _, name in ipairs({"arc", "disc", "flush", "frame", "halo", "outline", "quad", "rect",
                       "reset", "ring", "seg", "seg_fade", "seg_flat",
                       "skirt", "tri", "tri_fade"}) do
    layer[name] = noop
end

-- Rectangles are kept as well as counted, because one question here is
-- whether a box covers a drawing rather than whether a drawing happened.
-- Bottom-up, the way the mesh takes them.
local rects = {}
layer.rect = function(self, x, y, w, h)
    self.n = self.n + 1
    rects[#rects + 1] = {x = x, y = y, w = w, h = h}
end

-- The room. Ship 0 is us; the rest are strangers, all on one other team so
-- that the free-for-all test can hand out a team per seat instead.
local room = {count = 4, teams = {[0] = 1, 1, 1, 1}, active = {}, alive = {}}
local sim = {
    ship_count = function() return room.count end,
    -- Spread so that all three strangers land on screen at the extents the
    -- harness uses, which is what makes the sweep below cover more than one.
    ship_x = function(i) return 100 + i * 180 end,
    ship_y = function(i) return 100 + i * 120 end,
    ship_heading = function() return 0 end,
    -- A seat the snapshot carries at all. Filtered snapshots leave far
    -- seats out entirely, so the board asks this before reading a score
    -- out of the simulation; in here every seat the room models is
    -- present.
    ship_active = function(i) return room.active[i] == false and 0 or 1 end,
    ship_alive = function(i) return room.alive[i] == false and 0 or 1 end,
    ship_team = function(i) return room.teams[i] or 0 end,
    -- Nobody is riding anybody unless a test says so.
    ship_class = function() return 0 end,
    ship_energy = function() return 100 end,
    ship_max_energy = function() return 100 end,
    ship_kills = function(i) return i * 2 end,
    ship_deaths = function(i) return i end,
    ship_assists = function(i) return i * 3 end,
    ship_points = function(i) return i * 10 end,
    ship_bounty = function(i) return 7 + i end,
    ship_up = function() return 0 end,
    ship_level = function() return 0 end,
    ship_charge = function() return 0 end,
    ship_mod = function() return 0 end,
    ship_multi_off = function() return 0 end,
    has_trigger = function() return true end,
    tick = function() return 4242 end,
    weapon_count = function() return 3 end,
    green_count = function() return 0 end,
    flag_count = function() return 0 end,
    flag_at = function() return 0, 0, 255 end,
    map_coarse = function() return nil end,
    BTN_FIRE = 1,
}
_G.sim = sim

-- `state` is a plain table of text the gui script drains, and `touch` only
-- has to answer that nothing is being touched.
-- The real module: it is plain data, and the debug readout reads its
-- TEXT_POOL budget.
package.loaded["arena.state"] = dofile("client/arena/state.lua")
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
        me = o.me or 0,
        watch = o.watch,
        side = o.side,
        viewer_name = o.viewer_name or "you",
        class_names = {"Apex", "Wedge", "Chord", "Anvil", "Facet", "Cipher",
                       "Lattice"},
        menu_open = o.menu_open or false,
        pilots = o.pilots or {
            [0] = {name = "you", label = "human"},
            [1] = {name = "someone", label = "human"},
            [2] = {name = "a bot", label = "bot", ai = true, house = true},
            [3] = {name = "a guest", label = "unknown"},
        },
        ratings = o.ratings,
        watchers = o.watchers,
        teams = o.teams or {},
        match = o.match,
        side_names = o.side_names,
        feed = o.feed or {},
        hurt = 0,
        charges = {},
        cam_x = sim.ship_x(0), cam_y = sim.ship_y(0),
        half_w = 640, half_h = 400,
        banner = "",
        rtt = 4,
        stats = o.stats or {wire = "wt", input_margin = -2, rtt = 4, lead = 6,
                 self_err = 1.5, self_err_max = 9.0,
                 remote_pos = 2.0, remote_pos_p95 = 4.0,
                 remote_pos_max = 12.0, remote_turn = 1.0,
                 remote_turn_p95 = 3.0, remote_turn_max = 8.0,
                 smooth_pos = 1.0, smooth_turn = 0.5,
                 replay = 6, replay_max = 9, snap_hz = 20,
                 death_confirmed = 12, death_rejected = 1, death_pending = 1,
                 snap_gap_ms = 50, snap_gap_max_ms = 80,
                 snap_missed = 1, snap_reordered = 2,
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

-- What a press at this point lands on, through the rule itself. `ui.pick` is
-- the copy `on_input` uses, so what this test proves about a press is what a
-- press does, rather than what a second reading of the list would do.
local function press(x, y, finger)
    local r = ui.pick(x, y, finger)
    if r then return r.action, r.value end
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

-- --- the debug readout opens on the meter and closes on itself -------------

-- What opens it is the link meter over the dial, which is the one thing on
-- screen already about the connection. What closes it is either that meter or
-- the slab of numbers itself, because the readout lands under the dial and on
-- a phone that is most of a screen from the four bars that put it there: a
-- player who has finished reading has no reason to look back up in the corner.

local function debug_boxes()
    local out = {}
    for _, r in ipairs(ui.hits) do
        if r.action == "debug" then out[#out + 1] = r end
    end
    return out
end

ui.debug = false
frame()
local shut = debug_boxes()
check("shut, the meter is the one way into it", #shut == 1,
      #shut .. " boxes")
if shut[1] then
    -- Pressed on the bars themselves, at the right of the box: it runs left
    -- to a gap short of them and on to the screen's edge at the other end, so
    -- a thumb aimed at the corner cannot overshoot off the screen.
    local act = press(shut[1].x + shut[1].w - 6,
                      shut[1].y + shut[1].h / 2)
    check("a press on the bars is what opens it", act == "debug",
          "landed on " .. tostring(act))
end

ui.debug = true
frame()
local dbg = debug_boxes()
check("open, the readout publishes a box of its own beside the meter's",
      #dbg == 2, #dbg .. " boxes")
local panel = dbg[2]
if panel then
    check("and it is a slab rather than a chip",
          panel.w > 100 and panel.h > 40,
          string.format("%.0fx%.0f", panel.w, panel.h))
    -- Pressed in the middle, which is where a thumb finishing a read lands.
    local act = press(panel.x + panel.w / 2, panel.y + panel.h / 2)
    check("a press in the middle of it closes it", act == "debug",
          "landed on " .. tostring(act))
    -- And the two do not stand on each other. The slab is published behind
    -- everything, so a meter inside it would be unreachable by order alone.
    check("the meter is clear of the slab it opened",
          dbg[1].y + dbg[1].h <= panel.y,
          string.format("meter ends %.0f, slab starts %.0f",
                        dbg[1].y + dbg[1].h, panel.y))
end
ui.debug = false

-- --- the band is what opens the room ---------------------------------------
--
-- PLAYERS was a key in the corner row carrying the room's head count, and it
-- opened the roster. The band across the top opens the roster now, and the
-- count went with the key: the rows in the panel are the room, one line each,
-- which is the same fact drawn once instead of twice.

local counted_room = {pilots = {
           [0] = {name = "you", label = "human"},
           [1] = {name = "someone", label = "human"},
           [2] = {name = "a bot", label = "bot", ai = true},
           [3] = {name = "a guest", label = "unknown"},
       },
       watchers = {
           {name = "gallery", label = "human"},
           {name = "newcomer", label = "unknown"},
           {name = "camera", label = "bot?"},
       },
       -- The band is the room's clock, so a frame that wants one has to be a
       -- frame with a room in it.
       match = {playing = true, left = 96, score = {[0] = 4, [1] = 7}},
       side_names = {[0] = "Pylon", [1] = "Caisson"}}
frame(counted_room)
do
    local band = box("players_open")
    check("the band publishes the press that opens the roster", band ~= nil)
    -- One box, and it is the band's. This used to ask whether the band began
    -- to the right of the key in the corner, which said what it meant while
    -- MENU stood there and a roster key would have stood beside it. MENU is
    -- at the foot now and that corner is empty in an ordinary match, so the
    -- question left is the one it was always about: how many presses reach
    -- the panel.
    local ways = 0
    for _, r in ipairs(ui.hits) do
        if r.action == "players_open" then ways = ways + 1 end
    end
    check("nothing offers it a second time", ways == 1,
          ways .. " boxes open the roster")
    if band then
        -- And nothing is standing up there to be that second offer. The
        -- chips the corner can hold are all situational, and none of them is
        -- true in a plain match: no seat is being held, the zone has one
        -- room, and the camera is not on this client.
        local standing = {}
        for _, r in ipairs(ui.hits) do
            if r.y < band.y + band.h and r.x + r.w <= band.x then
                standing[#standing + 1] = r.action
            end
        end
        check("and the corner row it left is empty",
              #standing == 0, table.concat(standing, " | "))
        -- The clock is what sits in the middle of the window; the two sides
        -- hang off it and are as wide as their own names, so the band itself
        -- is only centered when both sides are named alike.
        local st = package.loaded["arena.state"]
        local clock
        for k = 1, st.n do
            if st.text[k].s == "1:36" then clock = st.text[k] end
        end
        check("the clock is centered on the window",
              clock ~= nil and clock.pivot == "center"
                  and math.abs(clock.x - W / 2) < 1,
              clock and string.format("%.0f of %d, %s", clock.x, W / 2,
                                      tostring(clock.pivot)) or "no clock")
        check("and the band covers it, across the top of the screen",
              band.x < W / 2 and band.x + band.w > W / 2 and band.y < 60,
              string.format("%.0f..%.0f, top %.0f", band.x, band.x + band.w,
                            band.y))
        check("a press on the clock opens the roster",
              press(W / 2, band.y + band.h / 2) == "players_open",
              tostring(press(W / 2, band.y + band.h / 2)))
        -- The band is the only thing on that line, and it is no wider than
        -- what it draws: every published box eats the press that lands in it,
        -- and on a mouse that press is the gun.
        check("and it is a band rather than a strip across the arena",
              band.w < W / 2, string.format("%.0f of %d", band.w, W))
    end
end

-- --- the menu takes the screen ---------------------------------------------

frame({menu_open = true})
check("the map is not clickable under the menu", box("map") == nil)
check("the link meter is not clickable under the menu", box("debug") == nil)
ui.debug = true
frame({menu_open = true})
check("nor is the open readout under the menu", box("debug") == nil)
ui.debug = false

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

-- --- the feed is bounded ---------------------------------------------------

-- Twelve lines offered, five drawn. The cap is the interface's, and the arena
-- trims its own buffer to the same number.
local many = {}
for i = 1, 12 do many[i] = {text = "line " .. i, t = 0} end
frame({feed = many})
local feed_rows = 0
for i = 1, package.loaded["arena.state"].n do
    if package.loaded["arena.state"].text[i].s:match("^line %d+$") then
        feed_rows = feed_rows + 1
    end
end
check("the feed draws exactly five rows", feed_rows == 5,
      tostring(feed_rows) .. " rows")

-- A line is words with names in it, and neither is touched. A call sign is
-- upper, lower and numeric exactly as its owner has it, which a feed that
-- shouted it back got wrong once; and the words between the names stay lower,
-- because this is the one panel setting a sentence about people rather than
-- labelling an instrument, and leaving the names as the only capitals on the
-- line is what makes them findable.
frame({feed = {{text = {{"Probe 7", identity = "human"}, " killed ",
                        {"vX-9", identity = "bot"}, " (+12)"}, t = 0}}})
local st_feed = package.loaded["arena.state"]
local said_y
for i = 1, st_feed.n do
    if st_feed.text[i].s == " killed " then
        said_y = st_feed.text[i].y
    end
end
local said_parts = {}
for i = 1, st_feed.n do
    local t = st_feed.text[i]
    if t.y == said_y then said_parts[#said_parts + 1] = t end
end
table.sort(said_parts, function(a, b) return a.x < b.x end)
local said_line = ""
for _, t in ipairs(said_parts) do said_line = said_line .. t.s end
check("a feed line quotes the names and does not shout its own words",
      said_line == "Probe 7 killed vX-9 (+12)", tostring(said_line))

-- --- the readouts that are words ------------------------------------------
--
-- Read off the drawn text, because that is what a player sees and the point
-- of every check below is what reaches them. Case is typography rather than
-- content: the HUD sets all of this in capitals.

local function drawn()
    local st = package.loaded["arena.state"]
    local out = {}
    for k = 1, st.n do out[#out + 1] = string.upper(st.text[k].s) end
    return table.concat(out, "\n")
end

local function says(word)
    return drawn():find(string.upper(word), 1, true) ~= nil
end

-- --- the debug readout -----------------------------------------------------

ui.debug = true
frame()
check("the debug readout keeps its own toggle clickable", box("debug") ~= nil)
check("the debug readout shows settled and pending death predictions",
      says("12/13 ok / 1 wait"), drawn())
frame({stats = {wire = "wt", down_loss = 0, combat_loss = 22, up_loss = 0}})
check("the debug readout labels each snapshot path without overlap",
      says("D 0%  F 22%"), drawn())
check("missed input deadlines are not labeled as packet loss",
      says("INPUT MISS") and says("0 holes"), drawn())
ui.debug = false

-- --- the safe zone says so, and says what it is about to cost ------------
--
-- A safe zone is the one part of the map whose rules are different and the
-- tile says so in color alone. And the room takes the seat back after a
-- while, which is a thing that has to be said before it happens rather than
-- after: a hull that simply stops being yours reads as a disconnection.
--
-- The countdown is read off the drawn text because the arithmetic is the
-- whole of it. Ticks in, minutes and seconds out, rounded up so the last
-- second is a 1: a readout that sits on zero while the hull is still there is
-- a readout saying the wrong thing at the one moment anybody is looking at it.

frame()
check("nothing is said in open space", not says("SAFE ZONE"))

frame({safe = 300, safe_limit = 6000})
check("a safe zone names itself", says("SAFE ZONE"))
check("and says what is left", says("moving to spectator in 0:57"), drawn())

frame({safe = 300, safe_limit = 65535})
check("a wait past a minute is clocked rather than counted",
      says("moving to spectator in 10:53"), drawn())

frame({safe = 5951, safe_limit = 6000})
check("the last second is a one rather than a zero",
      says("moving to spectator in 0:01"), drawn())

frame({safe = 6000, safe_limit = 6000})
check("and it never goes negative",
      says("moving to spectator in 0:00"), drawn())

frame({safe = 300, safe_limit = 0})
check("a room with no limit still names the zone", says("SAFE ZONE"))
check("and counts nothing down", not says("moving to spectator"), drawn())

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

-- --- the match clock ---------------------------------------------------------
--
-- A room that plays matches draws a clock and a score at the top; one that
-- runs forever draws neither. Both halves matter: an arena with no clock must
-- not grow one.

do
    frame()
    check("a room with no clock draws none",
          not says("1:47") and not says("NEXT MATCH IN"))

    local SIDES = {[0] = "Pylon", [1] = "Caisson"}
    frame({match = {playing = true, left = 107, score = {[0] = 10, [1] = 7}},
           side_names = SIDES})
    check("the clock reads minutes and seconds", says("1:47"), drawn())
    check("and both sides' scores are on it", says("10") and says("7"))
    check("named, so a score is a side rather than a number",
          says("Pylon") and says("Caisson"))
    check("with nothing about an intermission", not says("NEXT MATCH"))

    frame({match = {playing = false, left = 25, score = {[0] = 10, [1] = 7}},
           side_names = SIDES})
    check("the podium says what the clock is counting down to",
          says("0:25") and says("NEXT MATCH"))

    -- The clock survives the menu, which is a scrim rather than a curtain:
    -- "how are you doing in the thing you are in" is exactly what a player
    -- opening one wants to keep.
    frame({menu_open = true,
           match = {playing = true, left = 107, score = {[0] = 10, [1] = 7}},
           side_names = SIDES})
    check("and it shows through an open menu", says("1:47"))
end

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
