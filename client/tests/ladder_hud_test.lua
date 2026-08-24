-- What a Ladder run says about itself.
--
--     lua5.1 client/tests/ladder_hud_test.lua
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
for _, name in ipairs({"arc", "disc", "flush", "frame", "outline", "quad",
                       "rect", "reset", "ring", "seg", "seg_fade", "seg_flat",
                       "skirt", "tri", "tri_fade"}) do
    layer[name] = noop
end

-- One person and one house rival, which is the only field shape this mode
-- has. Ship 0 is the climber on side 0; ship 1 is the bot on side 1.
local room = {count = 2, teams = {[0] = 0, 1}}
_G.sim = {
    ship_count = function() return room.count end,
    ship_x = function(i) return 100 + i * 180 end,
    ship_y = function(i) return 100 + i * 120 end,
    ship_heading = function() return 0 end,
    ship_active = function() return 1 end,
    ship_alive = function() return 1 end,
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
        zone = "ladder",
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

local function leg(rung, result, kills, deaths, seconds)
    return {rung = rung, result = result, kills = kills, deaths = deaths,
            seconds = seconds}
end

local A_RUN = {
    leg(0, "cleared", 1, 0, 33),
    leg(1, "cleared", 1, 0, 58),
    leg(2, "drawn", 1, 1, 12),
    leg(2, "cleared", 1, 0, 71),
    leg(3, "lost", 0, 1, 9),
    leg(1, "cleared", 1, 0, 25),
    leg(2, "cleared", 1, 0, 44),
}

local function a_fight(over)
    local m = {playing = true, left = 166, score = {[0] = 0, [1] = 0},
               ladder = {rung = 4, streak = 2, checkpoint = 0,
                         active_opponent = 4, desired_opponent = 4,
                         opponent_ready = true, waiting = false,
                         legs = 19, log = A_RUN}}
    for k, v in pairs(over or {}) do m.ladder[k] = v end
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

-- The readout under the clock is centered and grows with the run. At its
-- widest it reaches out past the clock, so nothing else may share that band:
-- a rating on a line of its own under each name collided with both ends of
-- "RUNG 8  STREAK 2  FLOOR 6", which only happens once a run has a floor.
frame({match = a_fight({rung = 7, streak = 2, checkpoint = 5}),
       ratings = {[0] = 1183, [1] = 1347}})
local readout, left_rating, right_rating
for i = 1, state.n do
    local t = state.text[i]
    if t.s == "RUNG 8  STREAK 2  FLOOR 6" then readout = t end
    if t.s == "1183" then left_rating = t end
    if t.s == "1347" then right_rating = t end
end
check("the widest readout and both ratings all draw",
      readout and left_rating and right_rating,
      table.concat(words(), " | "))
-- The box a drawn string covers. Width off the same mono advance ui.lua
-- measures with; height off the size, since every pivot centers vertically.
local function box(t)
    local w = #t.s * t.px * (1233 / 2048)
    local x0 = t.x
    if t.pivot == "right" then x0 = t.x - w
    elseif t.pivot == "center" then x0 = t.x - w / 2 end
    return x0, t.y - t.px / 2, x0 + w, t.y + t.px / 2
end
local function clear(a, b)
    local ax0, ay0, ax1, ay1 = box(a)
    local bx0, by0, bx1, by1 = box(b)
    return ax1 <= bx0 or bx1 <= ax0 or ay1 <= by0 or by1 <= ay0
end
check("the readout does not touch your rating",
      clear(readout, left_rating), left_rating.s .. " vs " .. readout.s)
check("nor the rival's", clear(readout, right_rating),
      right_rating.s .. " vs " .. readout.s)

-- --- the readout under the clock -------------------------------------------

frame({match = a_fight({streak = 0, checkpoint = 0}),
       ratings = {[0] = 1200, [1] = 1200}})
check("a run with nothing behind it says only the rung",
      said("RUNG 5") ~= nil and said("STREAK") == nil and said("FLOOR") == nil,
      table.concat(words(), " | "))

frame({match = a_fight({streak = 3, checkpoint = 4}),
       ratings = {[0] = 1200, [1] = 1200}})
check("a streak and a floor are said once they are worth saying",
      said("RUNG 5  STREAK 3  FLOOR 5") ~= nil,
      table.concat(words(), " | "))

-- --- the run log -----------------------------------------------------------

ui.details = false
frame({match = a_fight(), ratings = {[0] = 1200, [1] = 1200}})
check("the run log is asked for rather than assumed",
      said("run: 19 fights") == nil, table.concat(words(), " | "))

ui.details = true
frame({match = a_fight(), ratings = {[0] = 1200, [1] = 1200}})
check("the scoreboard's toggle opens it with the roster",
      said("run: 19 fights") ~= nil, table.concat(words(), " | "))

-- Newest first: the window is fixed, so the leg that just happened has to be
-- the one that cannot fall off it.
local order = {}
for _, s in ipairs(words()) do
    local n = string.match(s, "^RUNG (%d+)$")
    if n then order[#order + 1] = tonumber(n) end
end
-- The run in A_RUN climbs to rung 4, loses it, and climbs back. A desktop has
-- room for all seven legs the room sent, newest first.
check("every leg that arrived is drawn, newest first",
      table.concat(order, ",") == "3,2,4,3,3,2,1",
      table.concat(order, ","))

check("a leg says what it was", said("won") ~= nil and said("lost") ~= nil
      and said("drew") ~= nil, table.concat(words(), " | "))
check("a leg says what it cost", exactly("1-0") ~= nil
      and exactly("0-1") ~= nil and exactly("1-1") ~= nil,
      table.concat(words(), " | "))
check("and how long it took, on the clock's own reading",
      exactly("0:44") ~= nil and exactly("0:09") ~= nil
      and exactly("1:11") ~= nil, table.concat(words(), " | "))

-- A run shorter than the window draws what it has, and the count agrees with
-- the rows rather than promising more of them.
frame({match = a_fight({legs = 2, log = {A_RUN[1], A_RUN[5]}}),
       ratings = {[0] = 1200, [1] = 1200}})
check("a short run draws every leg it has", said("run: 2 fights") ~= nil
      and said("RUNG 1") ~= nil and said("RUNG 4") ~= nil,
      table.concat(words(), " | "))

frame({match = a_fight({legs = 0, log = {}}),
       ratings = {[0] = 1200, [1] = 1200}})
check("a run with no finished leg draws no panel at all",
      said("run: ") == nil, table.concat(words(), " | "))

frame({match = {playing = true, left = 166, score = {[0] = 2, [1] = 1}},
       ratings = {[0] = 1200, [1] = 1200}})
check("and a mode that is not a run has none either", said("run: ") == nil,
      table.concat(words(), " | "))

-- A phone in landscape is where the column stops fitting. Fewer rows rather
-- than a panel over the loadout, and the newest leg is still the top one.
ui.details = true
frame({w = 844, h = 390, match = a_fight(),
       ratings = {[0] = 1200, [1] = 1200}})
local narrow = {}
for _, s in ipairs(words()) do
    local n = string.match(s, "^RUNG (%d+)$")
    if n then narrow[#narrow + 1] = tonumber(n) end
end
check("a short screen draws fewer legs rather than running off the bottom",
      #narrow > 0 and #narrow < #A_RUN and narrow[1] == 3,
      table.concat(narrow, ","))

if fails > 0 then
    print(fails .. " failed")
    os.exit(1)
end
print("all good")
