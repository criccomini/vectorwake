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
local pal = require("arena.palette")

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
            [1] = {name = "Kestrel", label = "human"},
            [2] = {name = "Plinth", label = "bot", ai = true, house = true},
            [3] = {name = "Vesper", label = "bot", ai = true, house = true},
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

-- --- while a match is running ----------------------------------------------

frame({match = {playing = true, left = 96, score = {[0] = 4, [1] = 7}},
       side_names = NAMES, side = 0})
check("nothing is settled while the clock is running",
      said("takes it") == nil and said("next match in") == nil,
      tostring(said("takes it") or said("next match in")))

-- --- at the whistle --------------------------------------------------------

frame({match = {playing = false, left = 23, score = {[0] = 11, [1] = 14}},
       side_names = NAMES, side = 0})

check("the side that took it is named", said("caisson takes it") ~= nil,
      table.concat(words(), " | "))
check("and the room says when the next one starts",
      said("next match in 0:23") ~= nil)

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

-- --- a draw ----------------------------------------------------------------

frame({match = {playing = false, left = 9, score = {[0] = 9, [1] = 9}},
       side_names = NAMES, side = 0})
check("level at the whistle is a draw rather than a winner",
      said("drawn") ~= nil and said("takes it") == nil,
      table.concat(words(), " | "))

-- --- and it stands down for the menu ---------------------------------------
--
-- The intermission is when the hangar opens, so the one thing a player is
-- likely to do here is open it. The card sits exactly where the menu does.

frame({match = {playing = false, left = 23, score = {[0] = 11, [1] = 14}},
       side_names = NAMES, side = 0, menu_open = true})
check("the menu covers it", said("takes it") == nil,
      tostring(said("takes it")))
-- The clock survives, because it is the topbar's and a player reading a menu
-- still wants to know how long they have.
check("but the clock does not", said("next match") ~= nil or said("0:23") ~= nil)

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
