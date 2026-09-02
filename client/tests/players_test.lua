-- The players sheet, as the interface says it.
--
--     lua5.1 client/tests/players_test.lua
--
-- Everybody in the room, one row each, in the menu's own panel: who is here,
-- which side they are on, what they have done, and at the whistle what the
-- match paid them. None of it travels on a wire of its own. It is read out of
-- the roster and the simulation together, which is what makes it worth a test
-- rather than a look: a number read from the wrong column is a plausible
-- number.
--
-- It replaces podium_test, which tested a block the whistle used to raise: a
-- line naming the winner, a bar carrying the score, and the roster under both,
-- grown over a wash of the whole window. Decision 145 deleted all of that. The
-- whistle raises this sheet instead, and what says who took the match is the
-- band, which band_test holds.
--
-- So this runs the real `M.hud` and `M.menu` against a stubbed engine, at a
-- whistle and during play, and reads back the words.

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
        rated_from = o.rated_from,
        watchers = o.watchers,
        teams = o.teams or {},
        match = o.match,
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

local function counted(what)
    local n = 0
    for _, s in ipairs(words()) do
        if string.lower(s) == string.lower(what) then n = n + 1 end
    end
    return n
end

local NAMES = {[0] = "Pylon", [1] = "Caisson"}
-- Two public sides. Ours is full, so its rows offer nothing; the other has a
-- seat, which is what makes a card's key a key rather than a sentence.
local TEAMS = {
    {team = 0, public = true, may_join = false, humans = 2, bots = 2,
     name = "Pylon"},
    {team = 1, public = true, may_join = true, humans = 1, bots = 3,
     name = "Caisson"},
}
local WATCHING = {{name = "Halyard", label = "human"}}

-- The stops the arena hands the column, with the players stop open. The sheet
-- itself is not in here: it is drawn from the room `M.hud` just read, which is
-- the whole reason it can be opened without a frame of empty glass.
local function column(open)
    local out = {open = true, home = false, at = open, key = "spectate",
                 pilot = {name = "you"}, rows = {}, stops = {}}
    for i, s in ipairs({{"account", "you"}, {"zone", "Chaos"},
                        {"players", "Pylon"}, {"ship", "Apex"},
                        {"settings"}}) do
        out.stops[i] = {stop = s[1], label = s[1], value = s[2],
                        open = s[1] == open}
    end
    return out
end

-- One frame with the sheet up: the HUD, then the menu over it, which is the
-- order the frame loop draws them in.
local function sheet(o)
    o = o or {}
    frame({menu_open = true, side = 0, teams = o.teams or TEAMS,
           side_names = NAMES, watchers = o.watchers or WATCHING,
           ratings = o.ratings, rated_from = o.rated_from,
           pilots = o.pilots, w = o.w, h = o.h,
           match = o.match or {playing = true, left = 96,
                               score = {[0] = 4, [1] = 7}}})
    ui.menu(column(o.stop or "players"))
    ui.finish()
end

-- Whether a box with this action was published, which is how a control is
-- asked about rather than by looking for the drawing of one.
local function published(action)
    for _, r in ipairs(ui.hits) do
        if r.action == action then return true end
    end
    return false
end

-- Where a string was drawn, or nil. The sheet is columns, so several checks
-- are about which side of the panel a reading landed on.
--
-- Case-sensitive, unlike `said`, and that is the point where a side's name is
-- the thing being looked for: the band shouts PYLON because everything in
-- flight shouts, and the sheet quotes Pylon because a side's name on a menu
-- row is quoted. Asked without the case, every check about the Team column
-- found the band's copy first.
local function at(what)
    for i = 1, state.n do
        if state.text[i].s == what then return state.text[i] end
    end
    return nil
end

local function exactly(what)
    local n = 0
    for i = 1, state.n do
        if state.text[i].s == what then n = n + 1 end
    end
    return n
end

-- The order the rows came out in, by name, which is the whole of what
-- `by_column` decides.
local function order()
    local out = {}
    local known = {you = true, Kestrel = true, Plinth = true, Vesper = true,
                   Halyard = true}
    for i = 1, state.n do
        if known[state.text[i].s] then out[#out + 1] = state.text[i].s end
    end
    return table.concat(out, ",")
end

-- --- the sheet, mid match ---------------------------------------------------
--
-- Your own side first, then everyone else, then the watchers, each run by
-- name Z to A. The partition is "who is with me", which is the question a list
-- of a room is opened with, and the Team column says the side on every row so
-- the grouping is a reading rather than the only way to tell.

ui.col_pilot = nil
sheet()

check("the sheet names itself and lists the room",
      said("players") ~= nil and said("Kestrel") ~= nil,
      table.concat(words(), " | "))
check("your own side runs first, then the rest, then the watchers",
      order() == "you,Plinth,Vesper,Kestrel,Halyard", order())
check("and every row says which side it is on",
      exactly("Pylon") == 2 and exactly("Caisson") == 2,
      exactly("Pylon") .. " Pylon rows")
check("a watcher is a row like any other, with Watching for a side",
      exactly("Watching") == 1, table.concat(words(), " | "))
-- And the two words the interface supplies take the interface's case, where
-- a side's own name keeps the one the zone gave it.
check("the interface's own words are said, not quoted",
      exactly("watching") == 0 and exactly("Pylon") == 2,
      table.concat(words(), " | "))
-- The four headings, which name the columns and nothing else. They were four
-- controls that sorted by what they named; one order everybody learns beats
-- four to find a way back from.
check("the columns are named", at("TEAM") ~= nil and at("K") ~= nil
      and at("D") ~= nil and at("A") ~= nil)
check("and no heading is a control any more",
      not published("sort_kills") and not published("sort_name"))
-- The Team column is a column: it lines up down the panel rather than being
-- set after each name.
do
    local a, b = at("Pylon"), at("Caisson")
    check("the sides line up in a column",
          a and b and math.abs(a.x - b.x) < 0.5,
          a and b and (a.x .. " vs " .. b.x) or "missing")
end

-- --- the card a row opens ---------------------------------------------------
--
-- A panel that stacked, with the pilot as its head, and one act at its foot.

ui.col_pilot = 1
sheet()
check("a pressed row opens the card about that pilot",
      said("Kestrel") ~= nil and said("this match") ~= nil,
      table.concat(words(), " | "))
check("the card reads their side, their seat and their standing",
      said("team") ~= nil and said("seat") ~= nil and said("rating") ~= nil)
check("and its one key is the way onto their side",
      said("join caisson") ~= nil, table.concat(words(), " | "))
check("which the sheet behind it is not offering",
      counted("you") == 0, table.concat(words(), " | "))

-- Your own side is full in this room, so a pilot on it has nothing to offer.
ui.col_pilot = 2
sheet()
check("a pilot on your own side offers no key at all",
      said("join") == nil, table.concat(words(), " | "))

-- And a side with no seat says so rather than drawing a key that would be
-- refused.
ui.col_pilot = 1
sheet({teams = {
    {team = 0, public = true, may_join = true, humans = 2, bots = 2,
     name = "Pylon"},
    {team = 1, public = true, may_join = false, humans = 4, bots = 0,
     name = "Caisson"},
}})
check("a full side stands its key down and says why",
      said("is full") ~= nil and said("join caisson") == nil,
      table.concat(words(), " | "))

-- A pilot who leaves while their card is open takes the card with them.
ui.col_pilot = 9
sheet()
check("a card about nobody is not drawn",
      said("this match") == nil and said("players") ~= nil,
      table.concat(words(), " | "))
ui.col_pilot = nil

-- --- case decides nothing about the order ----------------------------------
--
-- A pilot who capitalises their call sign does not get an end of the room for
-- it. Lowercased for the comparison, with the raw name breaking the tie so
-- the order is total and two pilots who differ only in case cannot flicker
-- past each other.

ui.col_pilot = nil
room.teams = {[0] = 0, 0, 1, 1}
frame({menu_open = true, side = 0, teams = TEAMS, side_names = NAMES,
       watchers = {},
       pilots = {[0] = {name = "zulu", label = "human"},
                 [1] = {name = "Alpha", label = "human"},
                 [2] = {name = "bravo", label = "human"},
                 [3] = {name = "Charlie", label = "human"}},
       match = {playing = true, left = 96, score = {[0] = 4, [1] = 7}}})
ui.menu(column("players"))
ui.finish()
do
    local out = {}
    local known = {zulu = true, Alpha = true, bravo = true, Charlie = true}
    for i = 1, state.n do
        if known[state.text[i].s] then out[#out + 1] = state.text[i].s end
    end
    check("your side first, then the rest, each run by name Z to A",
          table.concat(out, ",") == "zulu,Alpha,Charlie,bravo",
          table.concat(out, ","))
end
room.teams = {[0] = 0, 1, 0, 1}

-- --- whose side a pilot is on -----------------------------------------------
--
-- The zone decides what may be said. A side it marks public is one anybody may
-- read; a private one is a squad who arranged themselves, and naming it in a
-- column would hand the room a roster the zone deliberately did not send.
--
-- What is withheld is the name and never the fact. Which side somebody is on
-- is on their hull, in the color of their plate, so a row that said nothing
-- at all would be keeping a secret the screen has already given away.

sheet({teams = {{team = 0, name = "blue", public = true, may_join = false},
                {team = 1, name = "gold", public = true, may_join = true}}})
check("a public side is named on every row of it",
      exactly("gold") == 2, exactly("gold") .. " gold rows")

sheet({teams = {{team = 0, name = "blue", public = true, may_join = false},
                {team = 1, name = "gold", public = false, may_join = true}}})
check("a private side is not named", exactly("gold") == 0,
      table.concat(words(), " | "))
check("and its rows say so rather than going blank",
      exactly("Private") == 2, exactly("Private") .. " private rows")

-- Your own side is yours to know however it is marked, since you are in it.
sheet({teams = {{team = 0, name = "blue", public = false, may_join = false},
                {team = 1, name = "gold", public = false, may_join = true}}})
check("your own side is named even when it is private",
      exactly("blue") == 2, table.concat(words(), " | "))

-- A zone that has sent no team list at all says nothing. Falling back to the
-- raw team byte would be the same leak by a duller instrument.
sheet({teams = {}})
check("no team list means no side is named",
      exactly("Pylon") == 0 and exactly("Caisson") == 0,
      table.concat(words(), " | "))

-- --- the tier a pilot wears -------------------------------------------------
--
-- The band is the only thing a player is ever told about a rating, so if it
-- does not reach the card then the whole ladder is a number two servers pass
-- between themselves. It travels on the roster and is recomputed on every
-- kill, and for a long time it arrived and was drawn nowhere.

ui.col_pilot = 1
sheet({ratings = {[1] = 1620},
       pilots = {[0] = {name = "you", label = "human"},
                 [1] = {name = "Kestrel", label = "human", tier = "Ace"}}})
check("the tier reaches the card, with the number it is a rounding of",
      at("1620 Ace") ~= nil, table.concat(words(), " | "))
check("under a label saying what it is", said("rating") ~= nil)

-- Provisional is the absence of an answer rather than a low one. A newcomer
-- who read as the bottom band would be told something untrue about
-- themselves on their first evening.
sheet({ratings = {[1] = 1620},
       pilots = {[0] = {name = "you", label = "human"},
                 [1] = {name = "Kestrel", label = "human", tier = "placing"}}})
check("a pilot still placing says so", said("placing") ~= nil,
      table.concat(words(), " | "))
check("and is not given the bottom band instead", said("newb") == nil)

-- A roster that never carried one at all. The row is still drawn, because a
-- card with a hole where a row belongs reads as a fault rather than as
-- silence, and "unrated" is the honest word for it.
sheet({pilots = {[0] = {name = "you", label = "human"},
                 [1] = {name = "Kestrel", label = "human"}}})
check("a pilot with no tier at all still gets the row",
      said("unrated") ~= nil, table.concat(words(), " | "))
ui.col_pilot = nil

-- --- at the whistle ---------------------------------------------------------
--
-- The same sheet, raised by the arena rather than by a hand, plus the one
-- column a mid-fight list has no business carrying.

local ENDED = {playing = false, left = 18, score = {[0] = 4, [1] = 7}}
sheet({match = ENDED,
       ratings = {[0] = 1500, [1] = 1620, [2] = 1400, [3] = 1310},
       rated_from = {[0] = 1506, [1] = 1611, [2] = 1400, [3] = 1315}})
check("the whistle adds what the match paid", at("RATING") ~= nil,
      table.concat(words(), " | "))
check("and says it as a signed figure, either way",
      said("-6") ~= nil and said("+9") ~= nil,
      table.concat(words(), " | "))
check("a rating that did not move reads a zero rather than a blank",
      counted("0") >= 1)
check("and a watcher, who was not in the match, reads nothing at all",
      exactly("Watching") == 1, table.concat(words(), " | "))
-- The head is the panel's own name, not a result: who took the match is the
-- band's to say, and the sheet is a list of a room.
check("the sheet says nothing about who won",
      said("takes it") == nil and said("drawn") == nil,
      table.concat(words(), " | "))
check("and draws no bar under its head",
      said("caisson takes") == nil)

-- --- and it fits the windows ------------------------------------------------
--
-- An upright phone is where the columns stop fitting. Assists go first: it is
-- the one figure of the four about a kill somebody else finished, and the Team
-- column is what this sheet exists to carry.

sheet({w = 390, h = 844})
check("an upright phone keeps the sides and the score",
      at("TEAM") ~= nil and at("K") ~= nil and at("D") ~= nil,
      table.concat(words(), " | "))
check("and gives up assists rather than the column that names the side",
      at("A") == nil, table.concat(words(), " | "))

-- --- nothing of the old board is left --------------------------------------

sheet()
check("no heading sorts, no box opens a pilot elsewhere",
      not published("scores") and not published("pilot")
      and not published("uninspect"))
check("and the rows are the only way to a pilot",
      published("board_row"))

print()
if fails > 0 then
    print(fails .. " failed")
    os.exit(1)
end
print("all ok")

