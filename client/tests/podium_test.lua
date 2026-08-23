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
for _, name in ipairs({"arc", "disc", "flush", "frame", "outline", "quad", "rect",
                       "reset", "ring", "seg", "seg_fade", "seg_flat",
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
    package.loaded["arena.state"].n = 0
    ui.begin(layer, o.w or W, o.h or H, 1, false)
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

-- --- while a match is running ----------------------------------------------

frame({match = {playing = true, left = 96, score = {[0] = 4, [1] = 7}},
       side_names = NAMES, side = 0})
check("nothing is settled while the clock is running",
      said("takes it") == nil and said("next match in") == nil,
      tostring(said("takes it") or said("next match in")))

-- --- at the whistle --------------------------------------------------------

frame({match = {playing = false, left = 23, score = {[0] = 11, [1] = 14}},
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
check("and the room says when the next one starts",
      said("next match in 0:23") ~= nil)
-- Once, at the card's foot. The topbar's own caption stands down for it.
check("and says it once", counted("next match in") == 0,
      tostring(counted("next match in")))

-- Everybody who flew it is on it, whichever side they were on.
for _, who in ipairs({"you", "Kestrel", "Plinth", "Vesper"}) do
    check(who .. " is on the card", said(who) ~= nil)
end

-- One mvp, and it is the pilot with the most kills rather than the first row
-- or the one on your side. Kestrel has five against everybody else's fewer.
check("one pilot is marked mvp", counted("mvp") == 1, tostring(counted("mvp")))

-- What the match paid you is your own bounty taken, which is what the wallet
-- moves by. Seat zero collected seven.
check("the payout is your own bounty taken", said("banked 7 rivets") ~= nil,
      table.concat(words(), " | "))

-- Nobody is the best gun in a match where nothing was shot down.
room.kills = {[0] = 0, 0, 0, 0}
frame({match = {playing = false, left = 23, score = {[0] = 0, [1] = 0}},
       side_names = NAMES, side = 0})
check("a scoreless match has no mvp", counted("mvp") == 0,
      tostring(counted("mvp")))
room.kills = {[0] = 2, 5, 1, 3}

-- Names hanging off ships come down with it, for the reason the menu takes
-- them down: text is drawn over every mesh, so nothing the card lays down can
-- cover a plate, and four names scattered through a scoreboard read as a
-- fault rather than as depth.
frame({match = {playing = true, left = 90, score = {[0] = 3, [1] = 3}},
       side_names = NAMES, side = 0})
local plates_playing = counted("Kestrel")
frame({match = {playing = false, left = 23, score = {[0] = 11, [1] = 14}},
       side_names = NAMES, side = 0})
check("a plate is drawn while the match runs", plates_playing > 0,
      tostring(plates_playing))
check("and only the card's copy survives the whistle",
      counted("Kestrel") == 1, tostring(counted("Kestrel")))

-- --- a draw ----------------------------------------------------------------

frame({match = {playing = false, left = 9, score = {[0] = 9, [1] = 9}},
       side_names = NAMES, side = 0})
check("level at the whistle is a draw rather than a winner",
      said("drawn") ~= nil and said("takes it") == nil,
      table.concat(words(), " | "))

-- --- the scoreline ---------------------------------------------------------
--
-- Two numbers set large either side of a bar, which is the shape of the match
-- in one mark. The check that matters is which figure is on which side: your
-- own side is on the left however the zone numbered the teams, the same rule
-- the clock's own score follows, and a card that reversed them would be
-- telling everybody in the losing half that they won.

frame({match = {playing = false, left = 23, score = {[0] = 11, [1] = 14}},
       side_names = NAMES, side = 0})
local big = nil
for i = 1, state.n do
    local t = state.text[i]
    if t.px >= 40 and (t.s == "11" or t.s == "14") then
        big = big or {}
        big[#big + 1] = t
    end
end
check("the score is set large", big ~= nil and #big == 2,
      tostring(big and #big))
check("and your own side is the left of the two",
      big ~= nil and big[1].s == "11" and big[1].x < big[2].x,
      big and (big[1].s .. " at " .. math.floor(big[1].x)))

-- A filed result turns the podium into the earned sharing moment. The share
-- press is a real browser overlay, while film and claim return through the
-- ordinary action path.
ui.hits = {}
frame({match = {playing = false, left = 23, score = {[0] = 11, [1] = 14}},
       side_names = NAMES, side = 0,
       match_url = "https://vectorwake.net/matches/42", keep_pilot = true})
check("a filed match offers its share link", said("share match") ~= nil
      and ui.link_dom ~= nil
      and string.find(ui.link_dom, "vwshare:https://vectorwake.net/matches/42", 1, true))
local actions = {}
for _, hit in ipairs(ui.hits) do actions[hit.action] = true end
check("the podium offers its film", said("watch replay") ~= nil
      and actions.open_replay == true)
check("an unclaimed winner can keep their pilot", said("keep you") ~= nil
      and actions.keep_pilot == true)

-- --- what there is to say --------------------------------------------------
--
-- The closed phrase list, drawn as chips at the foot of the card and as one
-- line on the sayer's own row. There is nothing else in this game a player
-- can send another player, so what this test is really guarding is that the
-- list on screen is the list the wire has and nothing else can get onto it.

local SAYS = {"gg", "nice shot", "close one", "good luck", "thanks", "sorry"}
ui.hits = {}
frame({match = {playing = false, left = 23, score = {[0] = 11, [1] = 14}},
       side_names = NAMES, side = 0, sayings = SAYS})
for _, phrase in ipairs(SAYS) do
    check("you can say " .. phrase, said(phrase) ~= nil)
end
local chips = 0
for _, r in ipairs(ui.hits) do
    if r.action == "say" then chips = chips + 1 end
end
check("every phrase is a press", chips == #SAYS, tostring(chips))
check("and each one carries its number on the wire",
      (function()
          local seen_n = {}
          for _, r in ipairs(ui.hits) do
              if r.action == "say" then seen_n[r.value] = true end
          end
          for i = 0, #SAYS - 1 do if not seen_n[i] then return false end end
          return true
      end)())

-- Somebody said one. It lands on their row, in place of their name, with the
-- name kept small after it: a phrase in a column of its own would be a chat
-- window, and a row that lost its name for four seconds is a card you cannot
-- find yourself on.
frame({match = {playing = false, left = 23, score = {[0] = 11, [1] = 14}},
       side_names = NAMES, side = 0, sayings = SAYS,
       said = {[1] = {phrase = "nice shot", n = 1, t = 0.2}}})
local line, name_after = nil, nil
for i = 1, state.n - 1 do
    if state.text[i].s == "NICE SHOT" and state.text[i].px > 11 then
        line, name_after = state.text[i], state.text[i + 1]
    end
end
check("what a pilot said is on their own row", line ~= nil,
      table.concat(words(), " | "))
check("and it is where their name was rather than over it",
      counted("kestrel") == 1, tostring(counted("kestrel")))
check("with the name kept, small, after the words",
      name_after ~= nil and string.lower(name_after.s) == "kestrel"
      and name_after.x > line.x
      and math.abs(name_after.y - line.y) < 0.01,
      name_after and name_after.s)

-- On a phone the column is half of three hundred and ninety points, and the
-- phrase and a call sign together ran through the kills and deaths at the
-- other end of it. The name is what goes.
ui.compact = nil
frame({match = {playing = false, left = 23, score = {[0] = 11, [1] = 14}},
       side_names = NAMES, side = 0, sayings = SAYS, w = 390, h = 844,
       said = {[1] = {phrase = "nice shot", n = 1, t = 0.2}}})
local narrow, beside = nil, nil
for i = 1, state.n do
    if state.text[i].s == "NICE SHOT" then narrow = state.text[i] end
end
for i = 1, state.n do
    if narrow and string.lower(state.text[i].s) == "kestrel"
       and math.abs(state.text[i].y - narrow.y) < 0.01 then
        beside = state.text[i]
    end
end
check("a narrow column keeps the phrase and drops the name",
      narrow ~= nil and beside == nil,
      table.concat(words(), " | "))

-- A phrase this build does not have is an arena talking about a list it does
-- not share. Nothing is drawn for it rather than a number or a blank chip.
ui.hits = {}
frame({match = {playing = false, left = 23, score = {[0] = 11, [1] = 14}},
       side_names = NAMES, side = 0})
local none = 0
for _, r in ipairs(ui.hits) do
    if r.action == "say" then none = none + 1 end
end
check("a room with no phrase list draws no chips", none == 0, tostring(none))

-- --- three columns, not one string -----------------------------------------
--
-- The three figures on a row were one right-aligned string, so a pilot with a
-- two-figure count pushed the two beside it left: every row on the card lined
-- up differently from every other and none of them lined up with the heads.
-- Each column has its own edge now, the same edge on every row and on both
-- sides of the card.

local kept_k, kept_d, kept_a = room.kills, room.deaths, room.assists
room.kills = {[0] = 4, 14, 1, 0}
room.deaths = {[0] = 3, 6, 6, 3}
room.assists = {[0] = 2, 2, 6, 11}
frame({match = {playing = false, left = 12, score = {[0] = 5, [1] = 8}},
       side_names = NAMES, side = 0})
-- Every right-aligned figure on the card, gathered by the line it sits on.
-- Both sides draw a row at the same height, so a line carries six of them:
-- three columns twice, and the whole card is checked at once.
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
    if #xs == 6 then
        table.sort(xs)
        rows[#rows + 1] = table.concat(xs, ",")
    end
end
check("both sides draw a pilot line at each height", #rows == 2,
      tostring(#rows))
check("and every figure on the card stands in one of six columns",
      #rows == 2 and rows[1] == rows[2], table.concat(rows, "  vs  "))
-- And the heads stand over them. One letter each, at the edge the figures
-- under it end at.
local heads = {}
for i = 1, state.n do
    local t = state.text[i]
    if t.pivot == "right" and (t.s == "K" or t.s == "D" or t.s == "A") then
        heads[#heads + 1] = t.x
    end
end
table.sort(heads)
check("with a head over each column",
      #heads == 6 and table.concat(heads, ",") == rows[1],
      table.concat(heads, ",") .. "  vs  " .. tostring(rows[1]))
room.kills, room.deaths, room.assists = kept_k, kept_d, kept_a

-- --- and it stands down for the menu ---------------------------------------
--
-- The intermission is when the hangar opens, so the one thing a player is
-- likely to do here is open it. The card sits exactly where the menu does.

frame({match = {playing = false, left = 23, score = {[0] = 11, [1] = 14}},
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
frame({match = {playing = false, left = 23, score = {[0] = 11, [1] = 14}},
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
for _, phrase in ipairs(SAYS) do
    local at = nil
    for i = 1, state.n do
        if string.lower(state.text[i].s) == phrase then at = i break end
    end
    check("the chip for " .. phrase .. " lands inside the pool",
          at ~= nil and at <= state.TEXT_POOL,
          tostring(at) .. " of " .. tostring(state.TEXT_POOL))
end
check("no outline on the ending is thinner than a pixel",
      thinnest ~= nil and thinnest >= 1, tostring(thinnest))
ui.details = false
ui.inspect = nil

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
