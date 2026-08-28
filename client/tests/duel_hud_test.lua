-- What a Ladder run says about itself.
--
--     lua5.1 client/tests/duel_hud_test.lua
--
-- A Ladder screen used to carry three overlapping statements at once: the
-- clock with a score either side, a readout under it repeating the rung and
-- two numbers that had not moved yet, and a banner across the middle saying
-- the rung and the score again in the largest type on screen. Two of the three
-- were the same facts. This pins what is left, and the two things that took
-- their place: what each side is rated, and the run behind the rung.
--
-- Against the real `M.hud` and a stubbed engine, the way podium_test does,
-- because everything here is read out of the roster and the clock packet
-- rather than travelling on a wire of its own.

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

local layer = {n = 0}
local function noop(self) self.n = self.n + 1 end
for _, name in ipairs({"arc", "disc", "flush", "frame", "halo", "outline", "quad",
                       "rect", "reset", "ring", "seg", "seg_fade", "seg_flat",
                       "skirt", "tri", "tri_fade"}) do
    layer[name] = noop
end

-- One person and one house rival, which is the only field shape this mode
-- has. Ship 0 is the climber on side 0; ship 1 is the bot on side 1.
-- `alive` is the one row a test moves: a duelist waiting for an opponent is
-- benched by the room, which is the same dead hull the core reports after
-- somebody shoots you.
local room = {count = 2, teams = {[0] = 0, 1}, alive = {}}
_G.sim = {
    ship_count = function() return room.count end,
    ship_x = function(i) return 100 + i * 180 end,
    ship_y = function(i) return 100 + i * 120 end,
    ship_heading = function() return 0 end,
    ship_active = function() return 1 end,
    ship_alive = function(i) return room.alive[i] == false and 0 or 1 end,
    ship_team = function(i) return room.teams[i] or 0 end,
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
package.loaded["arena.world"] = {
    build_overview = function() end,
    forget_overview = function() end,
    overview = function() return {grid = 0, rects = {}} end,
    radar_tiles = {160, 160},
    radar_safe = {},
    radar_doors = {},
}

local ui = require("arena.ui")
local state = package.loaded["arena.state"]

-- --- the harness -----------------------------------------------------------

local W, H = 1280, 800
local NAMES = {[0] = "Pilot", [1] = "Rival"}

local function frame(o)
    o = o or {}
    state.n = 0
    ui.begin(layer, o.w or W, o.h or H, 1, false, o.now)
    ui.hud({
        me = 0,
        side = 0,
        viewer_name = "you",
        class_names = {"Apex", "Wedge"},
        menu_open = false,
        pilots = o.pilots or {
            [0] = {name = "you", label = "human", tier = "Wing", games = 40},
            [1] = {name = "Ozone 12", label = "bot", ai = true,
                   tier = "Ace", games = 900},
        },
        ratings = o.ratings,
        watchers = nil,
        teams = {},
        match = o.match,
        side_names = o.side_names or NAMES,
        feed = {},
        hurt = 0,
        charges = {},
        cam_x = 100, cam_y = 100,
        half_w = 640, half_h = 400,
        banner = o.banner or "",
        rtt = 4,
        zone = "duel",
        fps = 60, frame_ms = 16.7, rx_rate = 0, tx_rate = 0,
    })
    ui.finish()
end

local function words()
    local out = {}
    for i = 1, state.n do out[#out + 1] = state.text[i].s end
    return out
end

local function said(what)
    for _, s in ipairs(words()) do
        if string.find(string.lower(s), string.lower(what), 1, true) then
            return s
        end
    end
    return nil
end

-- Exactly this string, not a line containing it: "1180" would otherwise be
-- found inside a rating of 11800, and a column of numbers is where that kind
-- of near miss hides.
local function exactly(what)
    for i = 1, state.n do
        if state.text[i].s == what then return state.text[i] end
    end
    return nil
end

local function leg(rival, result, seconds)
    return {rival = rival, result = result, seconds = seconds}
end

-- One evening, newest last, which is the order the room sends. The window is
-- five now, because five is what the panel draws.
local A_RUN = {
    leg("Kestrel 0001", "cleared", 33),
    leg("Cirrus 0001", "drawn", 12),
    leg("Cirrus 0001", "cleared", 71),
    leg("Halcyon 0001", "lost", 9),
    leg("Kestrel 0001", "cleared", 44),
}

local function a_fight(over)
    local m = {playing = true, left = 166, score = {[0] = 0, [1] = 0},
               duel = {streak = 1, best_streak = 3, waiting = false,
                       legs = 19, log = A_RUN}}
    for k, v in pairs(over or {}) do m.duel[k] = v end
    return m
end

-- --- both ratings, beside the clock ----------------------------------------

ui.details = false
frame({match = a_fight(), ratings = {[0] = 1183.4, [1] = 1346.6}})
check("your own rating is drawn under your side's name",
      exactly("1183") ~= nil, table.concat(words(), " | "))
check("and the rival's under theirs, so the rung has a price on it",
      exactly("1347") ~= nil, table.concat(words(), " | "))

-- The pilot card rounds the same number the same way. Two roundings of one
-- rating is two ratings to a reader.
frame({match = a_fight(), ratings = {[0] = 1200, [1] = 1200}})
local both = 0
for _, s in ipairs(words()) do if s == "1200" then both = both + 1 end end
check("two sides on the same rating draw it twice, not once", both == 2,
      tostring(both))

-- A rating that has not settled still shows, because the number is real; it
-- is drawn dim, which is what the pilot card does with a placing pilot.
frame({match = a_fight(),
       ratings = {[0] = 1200, [1] = 1400},
       pilots = {
           [0] = {name = "you", label = "unknown", tier = "placing", games = 2},
           [1] = {name = "Ozone 12", label = "bot", ai = true, tier = "Ace"},
       }})
check("a pilot still placing shows the number they have",
      exactly("1200") ~= nil, table.concat(words(), " | "))

-- Not in a game where a side is more than one pilot: the number under a side's
-- name would be whichever of its pilots the scan reached first.
frame({match = {playing = true, left = 166, score = {[0] = 2, [1] = 1}},
       ratings = {[0] = 1183, [1] = 1346}})
check("a match with no run draws no ratings beside its clock",
      exactly("1183") == nil and exactly("1346") == nil,
      table.concat(words(), " | "))

-- --- what the band no longer says ------------------------------------------
--
-- The rung, the streak and the floor were a line under the clock, in the band
-- itself. The rung and the floor left the client first, under decision 74, and
-- then left the game with the ladder under decision 92. What is left of the
-- three is the streak, and it is a reading on the board rather than a word in
-- the band.
ui.details = false
frame({match = a_fight({streak = 2}),
       ratings = {[0] = 1183, [1] = 1347}})
check("the band says nothing about a run at all",
      said("RUNG") == nil and said("STREAK") == nil and said("FLOOR") == nil,
      table.concat(words(), " | "))

ui.details = true
frame({match = a_fight({streak = 2}),
       ratings = {[0] = 1183, [1] = 1347}})
check("the board carries the streak the band gave up",
      said("STREAK") ~= nil and exactly("2") ~= nil,
      table.concat(words(), " | "))
check("and says neither of the two words that went with it",
      said("RUNG") == nil and said("FLOOR") == nil,
      table.concat(words(), " | "))
ui.details = false

-- What it says instead: who is flying, over what they are rated. A duel's
-- side is a person, so the name on the band is the name on their hull rather
-- than the zone's word for the seat they are in.
check("each side is a pilot over their rating",
      exactly("you") ~= nil and exactly("Ozone 12") ~= nil
      and exactly("1183") ~= nil and exactly("1347") ~= nil,
      table.concat(words(), " | "))
check("and not the seat the zone calls them",
      exactly("Pilot") == nil and exactly("Rival") == nil,
      table.concat(words(), " | "))

-- The band's own copy of a string, which is the last one drawn: a rival's
-- call sign is on the plate hanging off their hull as well, and the plates go
-- down before the band does. Without this the rival's stack is measured
-- against a name out in the arena.
local function on_band(what)
    local found
    for i = 1, state.n do
        if state.text[i].s == what then found = state.text[i] end
    end
    return found
end

-- A name and the number under it are one side, so they stand in one column:
-- the two are drawn to the same edge, on the side of the clock they belong
-- to. A rating adrift of its own name is two sides' worth of reading.
local function stack_of(name, rating)
    local nm, rt = on_band(name), on_band(rating)
    if not nm or not rt then return nil end
    return nm, rt
end
local nm, rt = stack_of("you", "1183")
check("your name and rating share an edge",
      nm and rt and nm.pivot == rt.pivot and math.abs(nm.x - rt.x) < 0.5,
      nm and (nm.x .. " " .. tostring(nm.pivot) .. " vs " .. rt.x .. " "
              .. tostring(rt.pivot)) or "missing")
local rnm, rrt = stack_of("Ozone 12", "1347")
check("so do the rival's", rnm and rrt and rnm.pivot == rrt.pivot
      and math.abs(rnm.x - rrt.x) < 0.5,
      rnm and (rnm.x .. " vs " .. rrt.x) or "missing")

-- Each side reads away from the clock: yours ends where the clock begins and
-- theirs begins where it ends, so the two numbers that are compared sit
-- against the numerals they are compared across.
local clock = on_band("2:46")
check("the clock is between them",
      clock and nm.x < clock.x and rnm.x > clock.x,
      clock and (nm.x .. " | " .. clock.x .. " | " .. rnm.x) or "no clock")
check("yours is right aligned into it and theirs left aligned out of it",
      nm.pivot == "right" and rnm.pivot ~= "right",
      tostring(nm.pivot) .. " | " .. tostring(rnm.pivot))

-- The whole point of the stack: a side is exactly as tall as the clock it
-- stands beside, so the band reads as one line rather than as a tall block
-- with a clock in the middle of it. Name box, gap, rating box, and the three
-- of them come to the numerals' own height.
-- state.text counts y up from the bottom, so the name is the higher number
-- and the stack runs from the top of the name box to the bottom of the
-- rating's.
local tall = (nm.y + nm.px / 2) - (rt.y - rt.px / 2)
check("a side is as tall as the clock",
      tall <= clock.px + 0.5 and tall > clock.px * 0.9,
      tall .. " vs " .. clock.px)

-- --- the run ---------------------------------------------------------------
--
-- Two sections, in the order a duel is read: where the run stands, and then
-- the fights that got it there.

ui.details = false
frame({match = a_fight(), ratings = {[0] = 1200, [1] = 1200}})
check("the run is asked for rather than assumed",
      said("STREAK") == nil and said("Kestrel 0001") == nil,
      table.concat(words(), " | "))

ui.details = true
frame({match = a_fight(), ratings = {[0] = 1200, [1] = 1200}})

-- The readings, in the grammar every other machine reading in this interface
-- is set in: a label over a value. They used to be a line where the roster's
-- own K D A sit, at the same size under the same ticked rule, heading columns
-- they had nothing to do with.
check("the readings say where the run stands",
      said("STREAK") ~= nil and said("BEST") ~= nil and said("FIGHTS") ~= nil,
      table.concat(words(), " | "))
check("and carry the run's own numbers",
      exactly("1") ~= nil and exactly("3") ~= nil and exactly("19") ~= nil,
      table.concat(words(), " | "))

-- Above the fights, not below them: the streak is what the mode is played for
-- and the fights are how it got there. state.text counts y up from the
-- bottom, so the higher number is the higher thing on screen.
local head, first = exactly("STREAK"), nil
for i = 1, state.n do
    if state.text[i].s == "Kestrel 0001" then first = state.text[i] break end
end
check("the readings stand above the fights",
      head and first and head.y > first.y,
      head and first and (head.y .. " vs " .. first.y) or "missing")

-- Newest first: the window is fixed, so the fight that just happened has to
-- be the one that cannot fall off it.
local order = {}
for _, s in ipairs(words()) do
    if string.match(s, "0001$") then order[#order + 1] = s end
end
check("every fight that arrived is drawn, newest first",
      table.concat(order, ",") == "Kestrel 0001,Halcyon 0001,Cirrus 0001,"
          .. "Cirrus 0001,Kestrel 0001",
      table.concat(order, ","))

check("a fight says what came of it",
      said("won") ~= nil and said("lost") ~= nil and said("drew") ~= nil,
      table.concat(words(), " | "))
check("and how long it took, on the clock's own reading",
      exactly("0:44") ~= nil and exactly("0:09") ~= nil
      and exactly("1:11") ~= nil, table.concat(words(), " | "))
-- The scoreline went with the column that drew it: this mode is first to one,
-- so it only ever said that somebody died.
check("and not a scoreline",
      exactly("1-0") == nil and exactly("0-1") == nil and exactly("1-1") == nil,
      table.concat(words(), " | "))

-- A run shorter than the window draws what it has, and the count is the
-- run's own rather than the number of rows.
frame({match = a_fight({legs = 2, log = {A_RUN[1], A_RUN[4]}}),
       ratings = {[0] = 1200, [1] = 1200}})
check("a short run draws every fight it has",
      said("Kestrel 0001") ~= nil and said("Halcyon 0001") ~= nil
      and exactly("2") ~= nil, table.concat(words(), " | "))

-- A run with nothing behind it yet still says where it stands. The shipped
-- head hid the streak at zero, so the one number this mode is played for went
-- missing exactly on the screen a player reads after losing.
frame({match = a_fight({legs = 0, log = {}, streak = 0, best_streak = 0}),
       ratings = {[0] = 1200, [1] = 1200}})
check("a run with no finished fight still draws its readings",
      said("STREAK") ~= nil and exactly("0") ~= nil,
      table.concat(words(), " | "))
check("and a broken streak reads zero rather than going quiet",
      said("STREAK") ~= nil, table.concat(words(), " | "))

frame({match = {playing = true, left = 166, score = {[0] = 2, [1] = 1}},
       ratings = {[0] = 1200, [1] = 1200}})
check("and a mode that is not a run has none of it",
      said("STREAK") == nil and said("FIGHTS") == nil,
      table.concat(words(), " | "))

-- A phone in landscape is where the column stops fitting. Fewer fights rather
-- than a panel over the loadout, the newest still on top, and the readings
-- never dropped: they are the section the mode is played for.
ui.details = true
frame({w = 844, h = 390, match = a_fight(),
       ratings = {[0] = 1200, [1] = 1200}})
local narrow = {}
for _, s in ipairs(words()) do
    if string.match(s, "0001$") then narrow[#narrow + 1] = s end
end
check("a short screen draws fewer fights rather than running off the bottom",
      #narrow > 0 and #narrow < #A_RUN and narrow[1] == "Kestrel 0001",
      table.concat(narrow, ","))
check("and keeps the readings whatever it drops",
      said("STREAK") ~= nil, table.concat(words(), " | "))

-- --- the wait for a rival --------------------------------------------------
--
-- The room benches both seats until it has two of them, so a pilot who
-- arrives before their opponent is a dead hull as far as the core is
-- concerned. That is not the same fact as having been shot, and the screen
-- said it was: DESTROYED, in the largest type there is, for the ten seconds
-- the door holds the seat open for a person. It is the first thing a new
-- player sees of this game.
local function a_wait(hold)
    return {playing = false, left = 180, score = {[0] = 0, [1] = 0},
            duel = {streak = 0, best_streak = 0, waiting = true,
                    hold = hold, legs = 0, log = {}}}
end

ui.details = false
room.alive[0] = false
frame({match = a_wait(7)})
check("a pilot waiting for an opponent is not told they were destroyed",
      exactly("D E S T R O Y E D") == nil, table.concat(words(), " | "))
check("the middle of the screen says what the room is doing",
      said("WAITING FOR A RIVAL") ~= nil, table.concat(words(), " | "))
check("and that the wait ends whether or not a person turns up",
      said("house pilot") ~= nil, table.concat(words(), " | "))

-- How much longer, on the room's own count. A wait a player can read is a
-- wait; a wait with nothing moving in it is a screen that might be broken.
check("with how many seconds of it are left",
      said("takes the seat in 7") ~= nil, table.concat(words(), " | "))
frame({match = a_wait(1)})
check("the last second reads one rather than sitting on zero",
      said("takes the seat in 1") ~= nil, table.concat(words(), " | "))

-- And at the end of it the sentence changes rather than the number resting on
-- zero: the room has asked for a house pilot, and how long that one takes to
-- arrive is not a number anybody here has.
frame({match = a_wait(0)})
check("a hold that has run out says a pilot is coming, not zero",
      said("on the way") ~= nil and said("takes the seat in") == nil,
      table.concat(words(), " | "))
check("and the big line is the same line it was",
      said("WAITING FOR A RIVAL") ~= nil, table.concat(words(), " | "))

-- A room that says nothing about a hold is one that is not holding, which is
-- what an older zone's body decodes to as well.
frame({match = {playing = false, left = 180, score = {[0] = 0, [1] = 0},
                duel = {streak = 0, best_streak = 0, waiting = true,
                        legs = 0, log = {}}}})
check("a body with no hold in it draws the sentence rather than a nil",
      said("on the way") ~= nil, table.concat(words(), " | "))

-- The word itself is not going anywhere: dying is what a fight is for, and
-- the room says it is playing while the loser watches their own wreck.
frame({match = a_fight()})
check("a pilot shot down in a live fight still reads DESTROYED",
      exactly("D E S T R O Y E D") ~= nil, table.concat(words(), " | "))
check("and is not told the room is looking for somebody",
      said("WAITING FOR A RIVAL") == nil, table.concat(words(), " | "))
room.alive[0] = nil

if fails > 0 then
    print(fails .. " failed")
    os.exit(1)
end
print("all good")
