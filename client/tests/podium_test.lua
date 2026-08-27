-- The ending, as the interface says it.
--
--     lua5.1 client/tests/podium_test.lua
--
-- Twenty five seconds of every three minutes is an intermission, and what is
-- on screen for them is the only place a player is told what just happened:
-- who took the match, what everybody did in it, and what it paid. None of it
-- travels on a wire of its own. It is read out of the roster the scoreboard
-- has been drawing all match, which is what makes it worth a test rather than
-- a look: a number read from the wrong column is a plausible number.
--
-- So this runs the real `M.hud` against a stubbed engine, at a whistle and
-- during play, and reads back the words.

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

-- Lines are kept for the score check. A line behind a large figure is not a
-- styling detail. It changes the figure into something crossed out.
local segs = {}
layer.seg = function(self, x1, y1, x2, y2, t)
    self.n = self.n + 1
    segs[#segs + 1] = {x1 = x1, y1 = y1, x2 = x2, y2 = y2, t = t or 0}
end

-- The room. Ship 0 is us; the rest are strangers, all on one other team so
-- that the free-for-all test can hand out a team per seat instead.
local room = {count = 4, teams = {[0] = 0, 1, 0, 1}, active = {}, alive = {},
              kills = {[0] = 2, 5, 1, 3}, deaths = {[0] = 4, 1, 6, 2},
              assists = {[0] = 6, 0, 2, 1},
              points = {[0] = 7, 19, 3, 11}}
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
    ship_kills = function(i) return room.kills[i] or 0 end,
    ship_deaths = function(i) return room.deaths[i] or 0 end,
    ship_assists = function(i) return room.assists[i] or 0 end,
    ship_points = function(i) return room.points[i] or 0 end,
    ship_bounty = function(i) return 7 + i end,
    ship_up = function() return 0 end,
    ship_level = function() return 0 end,
    ship_charge = function() return 0 end,
    ship_mod = function() return 0 end,
    ship_multi_off = function() return 0 end,
    has_trigger = function() return true end,
    tick = function() return 4242 end,
    weapon_count = function() return 3 end,
    flag_count = function() return 0 end,
    flag_at = function() return 0, 0, 255 end,
    map_coarse = function() return nil end,
    BTN_FIRE = 1,
}
_G.sim = sim

-- `state` is a plain table of text the gui script drains, and `touch` only
-- has to answer that nothing is being touched.
-- The real module: it is plain data, and the budget check below reads
-- its TEXT_POOL.
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

-- One frame, with whatever the caller wants to be true about the room. `w` and
-- `h` are for the handful of checks about a phone: the card lays out against
-- the screen it is on, and the narrow one is where things stop fitting.
local function frame(o)
    o = o or {}
    rects = {}
    segs = {}
    package.loaded["arena.state"].n = 0
    ui.begin(layer, o.w or W, o.h or H, 1, false, o.now)
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
            [1] = {name = "Kestrel", label = "human"},
            [2] = {name = "Plinth", label = "bot", ai = true, house = true},
            [3] = {name = "Vesper", label = "bot", ai = true, house = true},
        },
        ratings = o.ratings,
        watchers = o.watchers,
        teams = o.teams or {},
        match = o.match,
        match_url = o.match_url,
        keep_pilot = o.keep_pilot,
        side_names = o.side_names,
        sayings = o.sayings, said = o.said,
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


-- Every string the frame drew, in the order it drew them.
local state = package.loaded["arena.state"]
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

-- The two pieces of type either side of one join, found by the second of
-- them. The card sets several of its lines as two draws rather than one so
-- that half of it can be in a side's color, and a test that only ever reads
-- the strings cannot tell those from two unrelated lines that happen to be
-- next to each other.
local function abutting(second)
    for i = 2, state.n do
        if string.lower(state.text[i].s) == string.lower(second) then
            return state.text[i - 1], state.text[i]
        end
    end
    return nil, nil
end

local function counted(what)
    local n = 0
    for _, s in ipairs(words()) do
        if string.lower(s) == string.lower(what) then n = n + 1 end
    end
    return n
end

local NAMES = {[0] = "Pylon", [1] = "Caisson"}
local SAYS = {"gg", "nice shot", "close one", "good luck", "thanks", "sorry"}

-- --- while a match is running ----------------------------------------------

frame({match = {playing = true, left = 96, score = {[0] = 4, [1] = 7}},
       side_names = NAMES, side = 0})
check("nothing is settled while the clock is running",
      said("takes it") == nil and said("next match in") == nil,
      tostring(said("takes it") or said("next match in")))

frame({match = {playing = true, left = 96, score = {[0] = 0, [1] = 0},
                ladder = {rung = 7, streak = 3, best = 7,
                          opponent_ready = true, waiting = false}},
       side_names = NAMES, side = 0})
-- The rung, the streak and the floor were a line under the clock. They are
-- rows on the board behind the band now, and the band carries the two pilots
-- instead: a duel's side is a person, so it reads a call sign over a rating.
check("a live Ladder fight keeps the rung off the band",
      said("RUNG 8") == nil and said("STREAK") == nil and said("FLOOR") == nil,
      table.concat(words(), " | "))

frame({match = {playing = false, left = 180, score = {[0] = 0, [1] = 0},
                ladder = {rung = 0, streak = 0, best = 0,
                          active_opponent = 0, desired_opponent = 0,
                          opponent_ready = false, waiting = true}},
       side_names = NAMES, side = 0})
-- A room still looking for a rival is not a room that just lost one. The
-- clock reads dashes and the band says nothing else at all: whoever is about
-- to be across the arena has not been chosen, so a side drawn here would be
-- the last fight's, and a stale name beside a dead clock reads as a fight in
-- progress.
check("waiting for the first rival is not a loss podium",
      said("--:--") ~= nil
      and said("Pylon") == nil and said("Caisson") == nil
      and said("back to rung 1") == nil,
      table.concat(words(), " | "))
check("and says nothing about the rung while it waits",
      said("RUNG") == nil and said("STREAK") == nil and said("FLOOR") == nil,
      table.concat(words(), " | "))

frame({match = {playing = false, left = 0, artifact = 1,
                score = {[0] = 1, [1] = 0},
                ladder = {rung = 1, streak = 1, best = 1,
                          active_opponent = 0, desired_opponent = 1,
                          opponent_ready = true, waiting = true}},
       side_names = NAMES, side = 0})
check("an overdue old rival becomes a waiting state",
      said("--:--") ~= nil and said("rung 1 cleared") == nil,
      table.concat(words(), " | "))

-- A duel's result is the two people in it, so it reads the way melee's does:
-- a name and a verb. The name comes off the leg the room just filed rather
-- than off the roster, because the rival's seat goes to the next one within
-- seconds of the whistle.
local function a_leg(rival, result)
    return {rival = rival, result = result, seconds = 26}
end

frame({match = {playing = false, left = 8, artifact = 1,
                score = {[0] = 1, [1] = 0},
                ladder = {rung = 7, active_opponent = 6, streak = 3,
                          best_streak = 3, legs = 9,
                          log = {a_leg("Vantage 0001", "cleared")},
                          opponent_ready = false, waiting = false}},
       side_names = NAMES, side = 0})
check("a Ladder result remains up while the next rival leaves",
      said("Vantage 0001") ~= nil and said("beaten") ~= nil
      and said("FINDING RIVAL") == nil,
      table.concat(words(), " | "))

ui.podium_at = nil
ui.podium_artifact = nil
frame({now = 5, match = {playing = false, left = 8, artifact = 1,
                         score = {[0] = 1, [1] = 0}},
       side_names = NAMES, side = 0})
local first_podium_at = ui.podium_at
frame({now = 9, match = {playing = false, left = 8, artifact = 2,
                         score = {[0] = 0, [1] = 1}},
       side_names = NAMES, side = 0})
check("a new result starts a fresh podium after rendering was paused",
      first_podium_at == 5 and ui.podium_at == 9,
      tostring(first_podium_at) .. " | " .. tostring(ui.podium_at))
frame({now = 10, match = {playing = true, left = 180,
                          score = {[0] = 0, [1] = 0}},
       side_names = NAMES, side = 0})
check("play releases the prior podium entrance", ui.podium_at == nil,
      tostring(ui.podium_at))

frame({match = {playing = false, left = 8, artifact = 1,
                score = {[0] = 1, [1] = 0},
                ladder = {rung = 7, active_opponent = 6,
                          log = {a_leg("Vantage 0001", "cleared")}}},
       side_names = NAMES, side = 1, watch = {subject = 1}})
check("a watcher sees the climber's result rather than their viewing side",
      said("beaten") ~= nil and said("takes it") == nil,
      table.concat(words(), " | "))

frame({match = {playing = false, left = 8, artifact = 1,
                score = {[0] = 0, [1] = 1},
                ladder = {rung = 5, active_opponent = 7,
                          log = {a_leg("Sable 0001", "lost")}}},
       side_names = NAMES, side = 0})
check("a Ladder loss names whoever took it",
      said("Sable 0001") ~= nil and said("takes it") ~= nil,
      table.concat(words(), " | "))

frame({match = {playing = false, left = 8, artifact = 1,
                score = {[0] = 1, [1] = 1},
                ladder = {rung = 7, active_opponent = 7,
                          log = {a_leg("Sable 0001", "drawn")}}},
       side_names = NAMES, side = 0})
-- The row for that fight still names who it was against; the line over the
-- bar does not, because a draw has nobody to put a verb on.
check("a mutual kill is a draw with nobody named over the bar",
      said("drawn") ~= nil and said("takes it") == nil
      and said("beaten") == nil, table.concat(words(), " | "))

frame({match = {playing = false, left = 8, artifact = 1,
                score = {[0] = 1, [1] = 0},
                ladder = {rung = 0, best = 8,
                          active_opponent = 7, desired_opponent = 0,
                          log = {a_leg("Sable 0001", "cleared")},
                          cleared = true}},
       side_names = NAMES, side = 0})
check("clearing the roster gets its own line",
      said("every rival beaten") ~= nil, table.concat(words(), " | "))

-- A duel's ending grows two sections the roster does not have: where the run
-- stands, and the fights that got it there. The block measures all of it
-- before it places any of it, so both windows draw the whole run rather than
-- the two rows the mid-fight rule leaves room for.
local A_RUN = {
    a_leg("Kestrel 0001", "cleared"), a_leg("Cirrus 0001", "drawn"),
    a_leg("Halcyon 0001", "cleared"), a_leg("Ozone 0001", "lost"),
    a_leg("Vantage 0001", "cleared"),
}
local function a_run_ending(w, h)
    frame({w = w, h = h,
           match = {playing = false, left = 6, artifact = 1,
                    score = {[0] = 1, [1] = 0},
                    ladder = {rung = 5, streak = 3, best_streak = 4,
                              best = 6, active_opponent = 5,
                              legs = 11, log = A_RUN}},
           side_names = NAMES, side = 0})
    local head
    for i = 1, state.n do
        if state.text[i].s == "STREAK" then head = state.text[i].y end
    end
    -- Only the call signs under the readings: the line over the bar names the
    -- rival too, and it is not a row of the run.
    local rows, foot = 0, nil
    for i = 1, state.n do
        local t = state.text[i]
        if head and t.y < head and string.match(t.s, "0001$") then
            rows = rows + 1
            foot = math.min(foot or t.y, t.y)
        end
    end
    return rows, head, foot
end

local run_rows, run_head, run_foot = a_run_ending(1280, 800)
check("a desktop ending draws the whole run", run_rows == 5,
      tostring(run_rows))
check("with the readings over it",
      run_head and run_foot and run_head > run_foot,
      tostring(run_head) .. " vs " .. tostring(run_foot))

run_rows, run_head, run_foot = a_run_ending(390, 844)
check("and so does an upright phone", run_rows == 5, tostring(run_rows))
check("without running off the foot of it", run_foot and run_foot > 0,
      tostring(run_foot))
check("and the readings still lead",
      run_head and run_foot and run_head > run_foot,
      tostring(run_head) .. " vs " .. tostring(run_foot))

frame({match = {playing = false, left = 23,
                score = {[0] = 11, [1] = 14}},
       side_names = NAMES, side = 0})
check("a non-Ladder intermission does not require an artifact",
      said("takes it") ~= nil and said("next match") ~= nil
          and said("0:23") ~= nil,
      table.concat(words(), " | "))

-- --- at the whistle --------------------------------------------------------

frame({match = {playing = false, left = 23, artifact = 1, score = {[0] = 11, [1] = 14}},
       side_names = NAMES, side = 0})

-- The result is two draws rather than one line: the winner's name in the
-- winner's color, and the verb after it in ink. So the card names the side in
-- the color the scoreboard has been using for them all match, which is what
-- makes it readable before it is read.
local who_t, verb_t = abutting("takes it")
check("the side that took it is named",
      who_t ~= nil and string.lower(who_t.s) == "caisson",
      table.concat(words(), " | "))
check("the verb follows it on the same line",
      who_t ~= nil and math.abs(who_t.y - verb_t.y) < 0.01
      and verb_t.x > who_t.x)
check("and the name is in the winner's color rather than the verb's",
      who_t ~= nil and who_t.col ~= verb_t.col)
-- With a space between them. The two are measured and placed rather than
-- concatenated, so the air between them is a number this can check rather
-- than a character in a string.
--
-- Measured against the menu's own face, which is what the interface set the
-- name in. The mono advance every other figure on this card is measured with
-- over-reads a proportional word by a tenth, which is enough to report a
-- collision that is not there.
if who_t and verb_t then
    local face = dofile("client/arena/menu_face.lua")
    local nw = 0
    for i = 1, #who_t.s do
        nw = nw + (face.adv[string.byte(who_t.s, i)] or face.widest)
    end
    nw = nw * who_t.px
    check("with a word's worth of air between them",
          verb_t.x - (who_t.x + nw) > who_t.px * 0.2,
          string.format("%.1f", verb_t.x - (who_t.x + nw)))
end
check("and the room says when the next one starts",
      said("next match") ~= nil and said("0:23") ~= nil)
-- Once, at the ending's foot. The topbar's own caption stands down for it.
check("and says it once", counted("next match") == 1,
      tostring(counted("next match")))

-- Everybody who flew it is on it, whichever side they were on.
for _, who in ipairs({"you", "Kestrel", "Plinth", "Vesper"}) do
    check(who .. " is on the card", said(who) ~= nil)
end

-- One mvp, and it is the pilot the winning side got the most out of rather
-- than the first row or the one on your side. Caisson took it, and Kestrel
-- comes out of it four ahead where Vesper is one.
check("one pilot is marked mvp", counted("mvp") == 1, tostring(counted("mvp")))
local wore = abutting("mvp")
check("and it is the winner's best net", wore ~= nil
      and string.lower(wore.s) == "kestrel",
      wore and wore.s or "nobody")

-- What the match paid is not said here at all. It was, as BANKED and a rivet
-- in the corner, and it went where the wallet already is: an ending is about
-- the match, and a running total belongs on the page that spends it.
check("the payout is not on the ending", said("banked") == nil,
      table.concat(words(), " | "))

-- Nobody wears it in a match where nothing was shot down.
room.kills = {[0] = 0, 0, 0, 0}
frame({match = {playing = false, left = 23, artifact = 1, score = {[0] = 0, [1] = 0}},
       side_names = NAMES, side = 0})
check("a scoreless match has no mvp", counted("mvp") == 0,
      tostring(counted("mvp")))

-- The mark belongs to the side that took it, so a pilot on the side that did
-- not cannot wear it however the match went for them personally. Here the
-- reader has the best of both columns in the room, seven for one, and Pylon
-- still lost by a kill.
room.kills = {[0] = 7, 5, 1, 4}
room.deaths = {[0] = 1, 2, 6, 3}
frame({match = {playing = false, left = 23, artifact = 1,
                score = {[0] = 8, [1] = 9}},
       side_names = NAMES, side = 0})
wore = abutting("mvp")
check("the losing side cannot hold the mvp", counted("mvp") == 1
      and wore ~= nil and string.lower(wore.s) == "kestrel",
      wore and wore.s or "nobody")

-- And nobody holds it in a draw, because there is no side to hand it out.
room.kills = {[0] = 3, 3, 1, 1}
room.deaths = {[0] = 1, 0, 5, 4}
frame({match = {playing = false, left = 23, artifact = 1,
                score = {[0] = 4, [1] = 4}},
       side_names = NAMES, side = 0})
check("a drawn match has no mvp", counted("mvp") == 0,
      tostring(counted("mvp")))

-- Inside the winning side it is the net and not the column: Kestrel lands
-- seven and gives back seven, Vesper four for one, and the mark follows what
-- the match was worth rather than the bigger number in the kills column.
room.kills = {[0] = 2, 7, 1, 4}
room.deaths = {[0] = 3, 7, 4, 1}
frame({match = {playing = false, left = 23, artifact = 1,
                score = {[0] = 3, [1] = 11}},
       side_names = NAMES, side = 0})
wore = abutting("mvp")
check("net beats the kills column", counted("mvp") == 1
      and wore ~= nil and string.lower(wore.s) == "vesper",
      wore and wore.s or "nobody")

-- Level on net, the one who was in more of it. Both come out two up; Kestrel
-- did it over eight fights and Vesper over two.
room.kills = {[0] = 1, 5, 1, 2}
room.deaths = {[0] = 2, 3, 3, 0}
frame({match = {playing = false, left = 23, artifact = 1,
                score = {[0] = 2, [1] = 7}},
       side_names = NAMES, side = 0})
wore = abutting("mvp")
check("and a tie on net goes to the busier gun", counted("mvp") == 1
      and wore ~= nil and string.lower(wore.s) == "kestrel",
      wore and wore.s or "nobody")

room.kills = {[0] = 2, 5, 1, 3}
room.deaths = {[0] = 4, 1, 6, 2}

-- Names hanging off ships come down with it, for the reason the menu takes
-- them down: text is drawn over every mesh, so nothing the card lays down can
-- cover a plate, and four names scattered through a scoreboard read as a
-- fault rather than as depth.
frame({match = {playing = true, left = 90, score = {[0] = 3, [1] = 3}},
       side_names = NAMES, side = 0})
local plates_playing = counted("Kestrel")
frame({match = {playing = false, left = 23, artifact = 1, score = {[0] = 11, [1] = 14}},
       side_names = NAMES, side = 0})
check("a plate is drawn while the match runs", plates_playing > 0,
      tostring(plates_playing))
check("and only the card's copy survives the whistle",
      counted("Kestrel") == 1, tostring(counted("Kestrel")))

-- --- a draw ----------------------------------------------------------------

frame({match = {playing = false, left = 9, artifact = 1, score = {[0] = 9, [1] = 9}},
       side_names = NAMES, side = 0})
check("level at the whistle is a draw rather than a winner",
      said("drawn") ~= nil and said("takes it") == nil,
      table.concat(words(), " | "))

-- --- the scoreline ---------------------------------------------------------
--
-- One band: a figure at each end and, between them, each side's share of the
-- bar with its name inside it. The check that matters is which figure is on
-- which side, and at the ending that is the side which took the match rather
-- than the reader's own. Mid-fight the band up top puts yours on the left,
-- because a name is only worth reading once you know which end of the gun it
-- is on; a finished match has a better answer, and it is what the ending is
-- about.

frame({match = {playing = false, left = 23, artifact = 1,
                score = {[0] = 11, [1] = 14}},
       side_names = NAMES, side = 0})
local big = nil
for i = 1, state.n do
    local t = state.text[i]
    if t.px >= 20 and (t.s == "11" or t.s == "14") then
        big = big or {}
        big[#big + 1] = t
    end
end
if big then table.sort(big, function(a, b) return a.x < b.x end) end
check("both figures are set large", big ~= nil and #big == 2,
      tostring(big and #big))
check("and stay in the instrument face",
      big ~= nil and big[1].font == nil and big[2].font == nil)
check("and the side that took it is the left of the two",
      big ~= nil and big[1].s == "14",
      big and (big[1].s .. " at " .. math.floor(big[1].x)))
-- Caisson took it, so Caisson leads the sentence over the bar as well.
check("which is the side the line names", said("caisson") ~= nil
      and said("takes it") ~= nil, table.concat(words(), " | "))

-- --- one block, one column -------------------------------------------------
--
-- The ending is the board with a head and a foot, so what a window changes is
-- the measure and where the block sits, never the arrangement. The only
-- screen-wide rectangle is the scrim; everything else lands inside one column.

local function block_geometry(width, height)
    frame({match = {playing = false, left = 23,
                    score = {[0] = 11, [1] = 14}},
           side_names = NAMES, side = 0, w = width, h = height,
           match_url = "https://vectorwake.net/matches/42"})

    local full = 0
    local covers = false
    for _, r in ipairs(rects) do
        if math.abs(r.x) < 0.01 and math.abs(r.w - width) < 0.01 then
            full = full + 1
            if math.abs(r.y) < 0.01 and math.abs(r.h - height) < 0.01 then
                covers = true
            end
        end
    end
    check(width .. " ending has one screen-wide field",
          full == 1 and covers, tostring(full))

    -- The roster is the board's own panel, so the ending publishes its
    -- backdrop exactly as the mid-match board does, in one column rather than
    -- two halves.
    local panel = nil
    for _, r in ipairs(ui.hits) do
        if r.action == "scores" then panel = r end
    end
    check(width .. " draws the board as one column", panel ~= nil,
          "no roster panel")
    if panel then
        check(width .. " keeps the column inside the window",
              panel.x > 0 and panel.x + panel.w < width,
              string.format("%.0f..%.0f of %d", panel.x,
                            panel.x + panel.w, width))
        -- Wider than the 340 the band opens mid-match, and capped, so a
        -- monitor does not stretch eight rows across a thousand points.
        check(width .. " spends more on it than the band does",
              panel.w > 340 or panel.w >= width - 30,
              string.format("%.0f", panel.w))
    end

    -- Both figures and the bar between them stand inside that same column.
    local scores = {}
    for i = 1, state.n do
        local t = state.text[i]
        if t.px >= 20 and (t.s == "11" or t.s == "14") then
            scores[#scores + 1] = t
        end
    end
    table.sort(scores, function(a, b) return a.x < b.x end)
    check(width .. " sets the scoreline on the column",
          #scores == 2 and panel ~= nil
          and math.abs(scores[1].x - panel.x) < 2
          and math.abs(scores[2].x - (panel.x + panel.w)) < 2,
          #scores == 2 and panel
              and string.format("%.0f/%.0f against %.0f/%.0f", scores[1].x,
                                scores[2].x, panel.x, panel.x + panel.w)
              or "missing")
end

block_geometry(710, 378)
block_geometry(1280, 720)

-- A phone held upright hugs the foot of the window with the whole block, so
-- the one key on it lands under a thumb rather than in the middle of a tall
-- screen.
do
    frame({match = {playing = false, left = 23, artifact = 1,
                    score = {[0] = 11, [1] = 14}},
           side_names = NAMES, side = 0, w = 390, h = 844,
           match_url = "https://vectorwake.net/matches/42"})
    local key = nil
    for _, r in ipairs(ui.hits) do
        if r.action == "share" then key = r end
    end
    check("an upright phone puts the key near the foot",
          key ~= nil and key.y + key.h > 844 * 0.8,
          key and string.format("%.0f of 844", key.y + key.h) or "no key")

    frame({match = {playing = false, left = 23, artifact = 1,
                    score = {[0] = 11, [1] = 14}},
           side_names = NAMES, side = 0, w = 1280, h = 720,
           match_url = "https://vectorwake.net/matches/42"})
    local wide_key = nil
    for _, r in ipairs(ui.hits) do
        if r.action == "share" then wide_key = r end
    end
    check("and a window with room centers the block instead",
          wide_key ~= nil and wide_key.y + wide_key.h < 720 * 0.8,
          wide_key and string.format("%.0f of 720", wide_key.y + wide_key.h)
              or "no key")
end

-- --- drawn zoomed ----------------------------------------------------------
--
-- The ending borrowed the board's own type, sized for a corner of a live
-- fight, and at the whistle it read as a footnote: the one thing on screen,
-- set in the smallest type on it. So the whole block draws larger than the
-- instruments around it, held back only by the window's height, and a finger
-- dragging its roster is measured against the rows as drawn.

frame({match = {playing = false, left = 23, artifact = 1,
                score = {[0] = 11, [1] = 14}},
       side_names = NAMES, side = 0, w = 1280, h = 800})
check("a roomy window draws the ending at full zoom",
      math.abs(ui.podium_zoom - 1.45) < 0.001, tostring(ui.podium_zoom))
local zoomed = nil
for i = 1, state.n do
    local t = state.text[i]
    if t.s == "14" and t.px > 30 then zoomed = t end
end
check("and the score figures wear the zoom", zoomed ~= nil)
check("as does the pitch a dragging finger is measured by",
      ui.row_pitch() > 18 * 1.4, tostring(ui.row_pitch()))
-- Two things stand outside the zoom at Chris's request: the countdown at the
-- foot and the bar between the score figures both keep the interface's own
-- size, so the readings stay readings while the block around them grows.
local clock = nil
for i = 1, state.n do
    local t = state.text[i]
    if t.s == "0:23" and math.abs(t.px - 21) < 0.01 then clock = t end
end
check("while the countdown keeps its size", clock ~= nil)
local bar = nil
for _, r in ipairs(rects) do
    if math.abs(r.h - 26) < 0.01 then bar = r end
end
check("and so does the score bar", bar ~= nil)

frame({match = {playing = false, left = 23, artifact = 1,
                score = {[0] = 11, [1] = 14}},
       side_names = NAMES, side = 0, w = 710, h = 300})
check("a short window takes only the zoom it has room for",
      ui.podium_zoom > 1 and ui.podium_zoom < 1.45,
      tostring(ui.podium_zoom))

frame({match = {playing = true, left = 96, score = {[0] = 4, [1] = 7}},
       side_names = NAMES, side = 0})
check("and play puts the pitch back", ui.row_pitch() == 18,
      tostring(ui.row_pitch()))

-- --- the foot --------------------------------------------------------------
--
-- The countdown as a reading rather than a draining bar, and one key beside
-- it: the bar was a second clock next to the first, and a key the width of
-- the measure was a banner. A guest keeps the key that claims their pilot,
-- which is the moment they are most likely to want it.

ui.hits = {}
frame({match = {playing = false, left = 23, artifact = 1,
                score = {[0] = 11, [1] = 14}},
       side_names = NAMES, side = 0,
       match_url = "https://vectorwake.net/matches/42", keep_pilot = true})
check("a filed match offers the invite", said("invite friend") ~= nil
      and ui.link_dom ~= nil
      and string.find(ui.link_dom, "vwshare:https://vectorwake.net/matches/42",
                      1, true))
local actions = {}
for _, hit in ipairs(ui.hits) do actions[hit.action] = true end
-- And offers nothing beside it. Watching the film was a second key of equal
-- weight on the one screen with a countdown running, which made the ending a
-- choice between leaving and staying rather than a result.
check("and no film beside it", said("watch replay") == nil
      and actions.open_replay == nil)
check("an unclaimed winner can keep their pilot", said("keep you") ~= nil
      and actions.keep_pilot == true)

do
    local keys = {}
    for _, r in ipairs(ui.hits) do
        if r.action == "share" or r.action == "keep_pilot" then
            keys[#keys + 1] = r
        end
    end
    table.sort(keys, function(a, b) return a.x < b.x end)
    check("the keys share one row at the foot", #keys == 2
          and math.abs(keys[1].y - keys[2].y) < 0.01,
          tostring(#keys))
    -- Sized to their own words rather than to the measure. The old key ran
    -- the width of the page, which is a banner rather than a control.
    local panel = nil
    for _, r in ipairs(ui.hits) do
        if r.action == "scores" then panel = r end
    end
    check("and each is a key rather than a banner",
          #keys == 2 and panel ~= nil and keys[1].w < panel.w / 2
          and keys[2].w < panel.w / 2,
          #keys == 2 and panel
              and string.format("%.0f and %.0f of %.0f", keys[1].w, keys[2].w,
                                panel.w) or "missing")
end

-- Nothing on the ending sends a phrase. Six chips at the foot of the card
-- were the widest thing on it, and they are going to be a key: this pins that
-- the ending stopped drawing them, and there is nothing else on it to press
-- but the two keys above.
ui.hits = {}
frame({match = {playing = false, left = 23, artifact = 1,
                score = {[0] = 11, [1] = 14}},
       side_names = NAMES, side = 0, sayings = SAYS})
local chips = 0
for _, r in ipairs(ui.hits) do
    if r.action == "say" then chips = chips + 1 end
end
check("the ending draws no phrase chips", chips == 0, tostring(chips))
for _, phrase in ipairs(SAYS) do
    check("nor the words of " .. phrase, said(phrase) == nil)
end

-- --- four columns, not one string ------------------------------------------
--
-- The roster is the board's, so its columns are the board's: at the ending,
-- four figures on a row, each with its own edge, the same edge on every row
-- and under its own head. Bounty is not among them: it prices the next kill,
-- and at the whistle there is no next kill. Points hold the outer edge under
-- the rivet mark, which is drawn rather than written, so the heads this can
-- read back are the three worded ones.

local kept_k, kept_d, kept_a = room.kills, room.deaths, room.assists
room.kills = {[0] = 4, 14, 1, 0}
room.deaths = {[0] = 3, 6, 6, 3}
room.assists = {[0] = 2, 2, 6, 11}
frame({match = {playing = false, left = 12, artifact = 1,
                score = {[0] = 5, [1] = 8}},
       side_names = NAMES, side = 0})
check("the ending words neither PTS nor BTY",
      said("PTS") == nil and said("BTY") == nil,
      tostring(said("PTS") or said("BTY")))
local lines = {}
for i = 1, state.n do
    local t = state.text[i]
    if t.pivot == "right" and string.match(t.s, "^%-?%d+$") then
        local key = string.format("%.1f", t.y)
        lines[key] = lines[key] or {}
        table.insert(lines[key], t.x)
    end
end
local rows = {}
for _, xs in pairs(lines) do
    if #xs == 4 then
        table.sort(xs)
        rows[#rows + 1] = xs
    end
end
local function edges(xs, n)
    local out = {}
    for i = 1, (n or #xs) do out[i] = xs[i] end
    return table.concat(out, ",")
end
check("every pilot draws a line of four figures", #rows == 4, tostring(#rows))
local same = #rows == 4
for i = 2, #rows do same = same and edges(rows[i]) == edges(rows[1]) end
check("and every figure stands in one of four columns", same,
      tostring(#rows))
-- And the worded heads stand over their columns, at the edge the figures
-- under them end at; the fourth column's head is the mark.
local heads = {}
for i = 1, state.n do
    local t = state.text[i]
    if t.pivot == "right" and (t.s == "K" or t.s == "D" or t.s == "A") then
        heads[#heads + 1] = t.x
    end
end
table.sort(heads)
check("with a head over each worded column",
      #heads == 3 and #rows > 0 and table.concat(heads, ",") == edges(rows[1], 3),
      table.concat(heads, ",") .. "  vs  " .. tostring(rows[1] and edges(rows[1])))

room.kills, room.deaths, room.assists = kept_k, kept_d, kept_a

-- --- and it stands down for the menu ---------------------------------------
--
-- The intermission is when the hangar opens, so the one thing a player is
-- likely to do here is open it. The card sits exactly where the menu does.

frame({match = {playing = false, left = 23, artifact = 1, score = {[0] = 11, [1] = 14}},
       side_names = NAMES, side = 0, menu_open = true})
check("the menu covers it", said("takes it") == nil,
      tostring(said("takes it")))
-- The clock survives, because it is the topbar's and a player reading a menu
-- still wants to know how long they have. And it takes back the caption the
-- card was carrying, since with the card gone nothing else says what the
-- number is counting down to.
check("but the clock does not", said("0:23") ~= nil)
check("and the topbar says what it is counting to",
      said("next match in") ~= nil)

-- --- and the pads ask the same question ------------------------------------
--
-- The arena stops drawing the touch pads while the ending is up: the whistle
-- benched every hull, so the pads have nothing to drive, and the board's foot
-- keys land exactly where the gun pad draws. What the arena asks is
-- M.match_ended, so the predicate has to agree with the board it stands down
-- for: up at an intermission, down mid-match, down in a room with no clock,
-- and down while a Ladder room is still looking for a rival, since that
-- player is not benched.

check("the arena can ask whether the ending is up",
      ui.match_ended({playing = false, left = 23, score = {}}) == true
      and ui.match_ended({playing = true, left = 96, score = {}}) == false
      and ui.match_ended(nil) == false)
check("and a Ladder room waiting for a rival keeps the pads",
      ui.match_ended({playing = false, left = 180,
                      ladder = {waiting = true}}) == false)

-- --- the whole ending, against the text budget -----------------------------
--
-- The worst frame this interface draws is the one this file is about: a full
-- room at the whistle, the scoreboard open, the pilot box open, the feed
-- still holding lines, a phrase standing on a row and every chip on the
-- card. The gui draws state.TEXT_POOL strings and silently drops the rest,
-- which is how a live podium lost the words off its chips while their boxes,
-- being mesh, stayed: the pool was 128 and the chips queue last. So the
-- worst frame is built whole and measured against the budget, and the
-- phrases have to land inside it, not merely in the queue.

room.count = 8
for i = 4, 7 do
    room.teams[i] = i % 2
    room.kills[i] = i
    room.deaths[i] = 9 - i
    room.assists[i] = i
    room.points[i] = 2 * i
end
local eight = {
    [0] = {name = "you", label = "human"},
    [1] = {name = "Kestrel", label = "human"},
    [2] = {name = "Plinth", label = "bot", ai = true, house = true},
    [3] = {name = "Vesper", label = "bot", ai = true, house = true},
    [4] = {name = "Ridgeline", label = "bot", ai = true, house = true},
    [5] = {name = "Halcyon", label = "bot", ai = true, house = true},
    [6] = {name = "Tessellate", label = "bot", ai = true, house = true},
    [7] = {name = "Ozone", label = "bot", ai = true, house = true},
}
-- The chip outlines have to hold a whole pixel as well: a hard-edged rect
-- thinner than one covers a pixel center or misses it on where the row
-- happens to sit, and the six chips share a row, so the same edge went
-- missing on all of them at once. Thickness is recorded rather than trusted.
local thinnest = nil
layer.frame = function(self, _, _, _, _, t)
    self.n = self.n + 1
    if not thinnest or t < thinnest then thinnest = t end
end
ui.details = true
ui.inspect = 1
frame({match = {playing = false, left = 23, artifact = 1, score = {[0] = 11, [1] = 14}},
       side_names = NAMES, side = 0, sayings = SAYS, pilots = eight,
       said = {[1] = {phrase = "nice shot", n = 1, t = 0.2}},
       feed = {{text = "sable killed cirrus (+3)", t = 1},
               {text = "kestrel killed halcyon (+1)", t = 2},
               {text = "tessellate killed ozone (+2)", t = 3},
               {text = "ridgeline killed vesper (+3)", t = 4},
               {text = "plinth killed kestrel (+1)", t = 5}}})
check("the budget is a number both sides share",
      type(state.TEXT_POOL) == "number" and state.TEXT_POOL > 0,
      tostring(state.TEXT_POOL))
check("the whole ending fits the text budget",
      state.n <= state.TEXT_POOL,
      state.n .. " queued of " .. tostring(state.TEXT_POOL))
-- The phrases are not on this frame at all now, which is most of what the
-- worst frame used to spend its budget on.
for _, phrase in ipairs(SAYS) do
    local at = nil
    for i = 1, state.n do
        if string.lower(state.text[i].s) == phrase then at = i break end
    end
    check("no chip is drawn for " .. phrase, at == nil, tostring(at))
end
check("no outline on the ending is thinner than a pixel",
      thinnest ~= nil and thinnest >= 1, tostring(thinnest))
ui.details = false
ui.inspect = nil

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
