-- The band across the top, and the board a press on it opens.
--
--     lua5.1 client/tests/band_test.lua
--
-- The scoreboard used to be three things in three places: a clock with a score
-- either side of it, a PLAYERS key in the corner that opened the roster, and a
-- sentence across the middle of the arena in the largest type on screen. This
-- pins what replaced them. The band is one instrument, each side a name over a
-- number and both as tall as the clock between them, and it is the control
-- that opens the roster, so nothing in the corner offers that panel a second
-- time.
--
-- The corner row is not the way into the menu either, and there is no corner
-- row: the held seat, the room number and the ON AIR tally have all gone, so
-- the top left is empty in every state a room has. What the row carries is the
-- band in the middle and the dial's two readouts at the right, and those are
-- what the checks here measure against.
--
-- Against the real `M.hud` and a stubbed engine.

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

local rects = {}
local layer = {n = 0}
local function noop(self) self.n = self.n + 1 end
for _, name in ipairs({"arc", "arc_aa", "arc_fade", "bloom", "flush", "halo",
                       "outline", "quad", "reset", "ring", "ring_aa",
                       "ring_fade", "seg", "seg_fade", "seg_flat",
                       "skirt", "tri", "tri_fade"}) do
    layer[name] = noop
end

-- Outlines were measured here for a while: a hard-edged rect thinner than a
-- pixel covers a pixel center or misses it depending on where the row happens
-- to sit, so the same edge goes missing on every chip sharing the row at once.
-- The check moved from the podium's saying chips to the corner MENU key to the
-- corner chips, and each time the thing it measured was deleted under it.
-- Nothing on this row wears an outline now, so it is gone rather than pointed
-- at a fourth subject.
layer.frame = noop
-- Recorded rather than counted: the wash the board lays over the fight is a
-- rect the size of the window, and nothing else on screen is.
layer.rect = function(self, x, y, w, h, col)
    self.n = self.n + 1
    rects[#rects + 1] = {x = x, y = y, w = w, h = h, col = col}
end
-- The flag strip is drawn as mesh rather than as type, so it is the only
-- thing on the band's column a check cannot find by its words. Every disc on
-- the frame is kept; which of them are the strip is `strip`'s question,
-- below, since it takes the window's own size to ask.
--
-- Discs rather than upright segments, which is what this collected while a
-- flag was a staff and a pennant. The mark is a core inside a ring now and
-- has no upright in it at all.
local marks = {}
layer.disc = function(self, x, y, r)
    self.n = self.n + 1
    marks[#marks + 1] = {x = x, y = y, r = r}
end

local room = {count = 4, teams = {[0] = 0, 1, 0, 1}}
-- What the room's flags are this frame, swapped by the section that asks
-- about them. Each row is what `sim.flag_at` answers: x, y, owning team,
-- carried. Empty everywhere else, which is every mode but Turf and Capture
-- the Flag.
local flags = {}
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
    green_count = function() return 0 end,
    flag_count = function() return #flags end,
    flag_at = function(i)
        local f = flags[i + 1]
        return f[1], f[2], f[3], f[4]
    end,
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
    -- The shape `overview` really has: a table, not a call, and `rect` rather
    -- than `rects`. It was both of those the wrong way round here for as long
    -- as nothing in this file opened the map.
    overview = {grid = 0, n = 0, rect = {}},
    radar_tiles = {160, 160},
    radar_safe = {},
    radar_doors = {},
}

local ui = require("arena.ui")
local pal = require("arena.palette")
local state = package.loaded["arena.state"]

-- --- the harness -----------------------------------------------------------

local W, H = 1280, 800
local NAMES = {[0] = "Pylon", [1] = "Caisson"}
local PILOTS = {
    [0] = {name = "you", label = "human"},
    [1] = {name = "Mantis 7", label = "bot", ai = true},
    [2] = {name = "Vireo 9", label = "human"},
    [3] = {name = "Sable 09", label = "bot", ai = true},
}

local w_now, h_now = W, H

-- The link meter's box is what this file measures the row against. It runs
-- from the top of the safe area down to where the dial starts, so its bottom
-- edge is the row's own, and it is the one thing left up here that publishes a
-- rectangle. The band's hit box is a few points taller than the row on
-- purpose, so a finger can find it, and reading the row's line off that box
-- would be reading the padding.

local function frame(o)
    o = o or {}
    w_now, h_now = o.w or W, o.h or H
    rects = {}
    marks = {}
    flags = o.flags or {}
    state.n = 0
    ui.begin(layer, w_now, h_now, 1, false, o.now)
    ui.hud({
        me = 0,
        side = 0,
        watch = o.watch,
        -- A seat holds a rating and the row reads it, so the harness carries
        -- one: every measurement below is taken against the row a pilot in a
        -- match actually has in front of them. `rated_from` is what the
        -- whistle latched, so this pilot is six points down on the match.
        ratings = o.ratings ~= false and (o.ratings or {[0] = 1494}) or nil,
        rated_from = o.ratings ~= false and (o.rated_from or {[0] = 1500})
            or nil,
        viewer_name = "you",
        class_names = {"Apex", "Wedge"},
        menu_open = o.menu_open or false,
        pilots = o.pilots or PILOTS,
        watchers = nil,
        teams = {},
        -- `false` for a room that runs forever, which is what a zone with no
        -- match sends: Free Roam is the one, and the row reads differently
        -- there.
        match = o.match ~= false
            and (o.match or {playing = true, left = 33,
                             score = {[0] = 15, [1] = 19}})
            or nil,
        side_names = NAMES,
        feed = {},
        hurt = 0,
        charges = {},
        cam_x = 100, cam_y = 100,
        half_w = w_now / 2, half_h = h_now / 2,
        banner = o.banner or "",
        rtt = 4,
        zone = o.zone or "melee",
        fps = 60, frame_ms = 16.7, rx_rate = 0, tx_rate = 0,
    })
    ui.finish()
end

-- The band draws last, so its own copy of a string is the last one filed: a
-- pilot's call sign is on the plate hanging off their hull as well.
--
-- Copied out rather than handed back, because the queue reuses its rows: a
-- reading held across two frames would quietly become the second frame's.
-- Matched without case, since the HUD sets its own and this is asking what
-- was drawn rather than how it was spelled.
local function drawn(s)
    local found
    for i = 1, state.n do
        local t = state.text[i]
        if string.lower(t.s) == string.lower(s) then
            found = {s = t.s, x = t.x, y = t.y, px = t.px, col = t.col,
                     pivot = t.pivot}
        end
    end
    return found
end

local function words()
    local out = {}
    for i = 1, state.n do out[#out + 1] = state.text[i].s end
    return out
end

local function box(action)
    for _, r in ipairs(ui.hits) do
        if r.action == action then return r end
    end
    return nil
end

-- Type is filed for the gui, which counts up from the bottom; hit boxes are
-- published counting down from the top. Everything here compares the two.
local function down(t) return h_now - t.y end

-- --- a side is a figure and a name, on the row's one line ------------------

frame()

local pylon, caisson = drawn("PYLON"), drawn("CAISSON")
local fifteen, nineteen = drawn("15"), drawn("19")
local clock = drawn("0:33")
check("both sides are named", pylon ~= nil and caisson ~= nil,
      table.concat(words(), " | "))
check("both scores are drawn", fifteen ~= nil and nineteen ~= nil,
      table.concat(words(), " | "))
check("and the clock between them", clock ~= nil)

if pylon and fifteen and caisson and nineteen and clock then
    -- One line. A side was a name over a number and the two of them together
    -- were as tall as the clock, which is three sizes in eight characters and
    -- the largest of them on the clock. Everything on the row shares the
    -- row's own middle now. See decision 162.
    check("a side stands on the clock's own line",
          math.abs(pylon.y - clock.y) < 0.5
              and math.abs(fifteen.y - clock.y) < 0.5
              and math.abs(caisson.y - clock.y) < 0.5
              and math.abs(nineteen.y - clock.y) < 0.5,
          string.format("%.1f %.1f | %.1f | %.1f %.1f", fifteen.y, pylon.y,
                        clock.y, caisson.y, nineteen.y))
    -- And at one size, which is the whole of the change: what tells a score
    -- from a name from the clock is color and order, not weight.
    check("and everything on it is set in one size",
          math.abs(pylon.px - clock.px) < 0.5
              and math.abs(fifteen.px - clock.px) < 0.5
              and math.abs(caisson.px - clock.px) < 0.5
              and math.abs(nineteen.px - clock.px) < 0.5,
          string.format("%.0f %.0f | %.0f | %.0f %.0f", fifteen.px, pylon.px,
                        clock.px, caisson.px, nineteen.px))
    -- The figure leads, reading outward from the middle, so the two numbers
    -- sit at the band's own ends and the two names bracket the clock.
    check("a side's figure is the far half of it",
          fifteen.x < pylon.x and nineteen.x > caisson.x,
          string.format("%.0f/%.0f and %.0f/%.0f", fifteen.x, pylon.x,
                        caisson.x, nineteen.x))
    -- Your own side first, whichever way the zone numbered the teams, so the
    -- reading is positional and never has to be worked out from a color.
    check("your own side is the one on the left",
          pylon.x < clock.x and caisson.x > clock.x,
          string.format("%.0f | %.0f | %.0f", pylon.x, clock.x, caisson.x))
    check("yours reads into the clock and theirs out of it",
          pylon.pivot == "right" and fifteen.pivot == "right"
              and caisson.pivot ~= "right" and nineteen.pivot ~= "right",
          tostring(pylon.pivot) .. "/" .. tostring(caisson.pivot))
    -- The sides wear the colors every other instrument uses for them, so a
    -- score never has to be worked out from where it is standing.
    check("each side is drawn in its own color",
          pylon.col[1] == pal.FRIEND[1] and fifteen.col[1] == pal.FRIEND[1]
              and caisson.col[1] == pal.ENEMY[1]
              and nineteen.col[1] == pal.ENEMY[1],
          "a side is in the wrong ink")

    -- The clock is the reading ink rather than either side's color or the
    -- interface's own: it is the one number up here nobody is playing for,
    -- and at one size the ink is what says so.
    check("and the clock is the reading between them",
          clock.col[1] == pal.READ[1] and clock.col[2] == pal.READ[2],
          "the clock is in the wrong ink")
    -- And the row still stands in a box a key tall, which is what the flags,
    -- the room's line and the board under the band are placed against. The
    -- clock filled that box on its own once; now it sits inside it, and the
    -- meter's own box is what publishes where it ends.
    local meter = box("debug")
    check("the row's line sits inside the row's box", meter ~= nil
              and down(clock) + clock.px / 2 < meter.y + meter.h
              and down(clock) - clock.px / 2 > meter.y,
          meter and string.format("clock %.1f to %.1f, row %.1f to %.1f",
                                  down(clock) - clock.px / 2,
                                  down(clock) + clock.px / 2,
                                  meter.y, meter.y + meter.h)
              or "no meter in the corner")
end

-- --- your standing is on the row ------------------------------------------
--
-- A rating is the one durable thing a pilot has, and until decision 162 there
-- was nowhere to watch it: the sheet carries it at the whistle and the ending
-- is where it was read, which is a figure you are told about after the fact.
-- It stands in the near corner now, the way POS stands over the dial at the
-- far one, and it says what the sheet says in the same words.

frame()
do
    local caption, standing, moved = drawn("RATING"), drawn("1494"), drawn("(-6)")
    check("the row carries your own standing",
          caption ~= nil and standing ~= nil and moved ~= nil,
          table.concat(words(), " | "))
    if caption and standing and moved and clock then
        check("on the row's own line",
              math.abs(standing.y - clock.y) < 0.5
                  and math.abs(moved.y - clock.y) < 0.5
                  and math.abs(caption.y - clock.y) < 0.5,
              string.format("%.1f %.1f %.1f against %.1f", caption.y,
                            standing.y, moved.y, clock.y))
        check("and at the row's own size",
              math.abs(standing.px - clock.px) < 0.5
                  and math.abs(moved.px - clock.px) < 0.5,
              string.format("%.0f %.0f against %.0f", standing.px, moved.px,
                            clock.px))
        -- Reading order, in the near corner and nowhere near the middle.
        check("in the corner, the caption first",
              caption.x < standing.x and standing.x < moved.x
                  and moved.x < W / 4,
              string.format("%.0f %.0f %.0f", caption.x, standing.x, moved.x))
        -- The standing is a reading and no rating is good or bad, so only the
        -- movement takes a color. Six points down, so this one is the hurt.
        check("with the movement colored and the standing not",
              moved.col[1] == pal.HURT[1] and standing.col[1] == pal.INK[1],
              "the pair is in one ink")
    end
    -- And the band stops short of it, the way it stops short of the dial's
    -- strip at the other end. The row has an instrument at each end now and
    -- the band grows between them.
    local press = box("players_open")
    if press and moved then
        check("and the band starts clear of it",
              press.x > moved.x, string.format("band at %.0f, standing ends "
                                               .. "somewhere past %.0f",
                                               press.x, moved.x))
    end
end

-- A match that has moved nothing reads a bracketed zero, because "this one
-- has cost you nothing so far" is an answer and a blank is not.
frame({ratings = {[0] = 1494}, rated_from = {[0] = 1494}})
check("a standing that has not moved says so", drawn("(0)") ~= nil,
      table.concat(words(), " | "))

-- A phone spends the caption, the way the middle of the row spends the sides'
-- names. The figures always draw: they are the reading.
frame({w = 390, h = 844})
check("a phone keeps the figures and drops the caption",
      drawn("1494") ~= nil and drawn("(-6)") ~= nil and drawn("RATING") == nil,
      table.concat(words(), " | "))

-- Nothing for a watcher, whose rating this room is not moving: a figure under
-- a caption reading RATING in that corner would be read as theirs. Nothing
-- either for a pilot who has no rating yet, which is a guest before their
-- first rated death.
frame({watch = true})
check("a watcher is shown no standing at all",
      drawn("RATING") == nil and drawn("1494") == nil,
      table.concat(words(), " | "))
frame({ratings = false})
check("and neither is a pilot who has not earned one",
      drawn("RATING") == nil and drawn("(0)") == nil,
      table.concat(words(), " | "))

-- --- the clock says how long is left, and then that it is nearly gone ------
--
-- Under half a minute the clock goes to the warning color. It is the one
-- reading on the row that says something other than what it reads, and the
-- band said it by being twice the size of everything beside it for the whole
-- three minutes.

frame({match = {playing = true, left = 92, score = {[0] = 15, [1] = 19}}})
do
    local early = drawn("1:32")
    frame({match = {playing = true, left = 29, score = {[0] = 15, [1] = 19}}})
    local late = drawn("0:29")
    check("the clock is a reading with a minute to go",
          early ~= nil and early.col[1] == pal.READ[1],
          early and "in the wrong ink" or "no clock")
    check("and a warning under half a minute",
          late ~= nil and late.col[1] == pal.HURT[1],
          late and "in the wrong ink" or "no clock")
    check("at the same size either way",
          early and late and math.abs(early.px - late.px) < 0.5,
          "the clock grows")
end

-- --- a duel is two pilots and the clock ------------------------------------
--
-- One clean kill takes a duel (decision 146), so its score stands at nil to
-- nil for the whole match and then the match is over: there is nothing there
-- to read. What its two sides are is the two pilots, and the zone's own names
-- for them, Pilot and Rival, name neither.

frame({zone = "duel",
       match = {playing = true, left = 97, score = {[0] = 0, [1] = 0}},
       pilots = {[0] = {name = "you", label = "human", team = 0},
                 [1] = {name = "DRiFT", label = "human", team = 1}}})
do
    local mine, theirs, tick = drawn("you"), drawn("DRiFT"), drawn("1:37")
    check("a duel names its two pilots on the row",
          mine ~= nil and theirs ~= nil and tick ~= nil
              and math.abs(mine.y - tick.y) < 0.5
              and math.abs(theirs.y - tick.y) < 0.5,
          table.concat(words(), " | "))
    check("and neither side by the zone's word for it",
          drawn("PYLON") == nil and drawn("CAISSON") == nil,
          table.concat(words(), " | "))
    -- A call sign keeps the case its owner gave it, the way the roster and
    -- the plate on the hull keep it. The interface's own words are capitals.
    check("in the case its owner gave it", theirs and theirs.s == "DRiFT",
          theirs and theirs.s or "no name")
    local zeros = 0
    for i = 1, state.n do
        if state.text[i].s == "0" then zeros = zeros + 1 end
    end
    check("and no score, because a duel has none to show", zeros == 0,
          zeros .. " zeros on the row")
end

-- --- a room that runs forever ----------------------------------------------
--
-- Free Roam has no clock and no score, so the middle carries how many are in
-- the room. An empty row over a room of thirty one reads as an instrument
-- that has given up rather than as a quiet room.

frame({zone = "roam", match = false})
check("a room with no match counts the room instead",
      drawn("4 flying") ~= nil, table.concat(words(), " | "))
check("and still carries your standing",
      drawn("1494") ~= nil, table.concat(words(), " | "))

-- --- the top row is a row ---------------------------------------------------

-- The corner chips at the left, the band beside them and the dial at the far
-- end, on one line, at every window size. The readouts each worked their own
-- vertical out of the padding once, which is a horizontal measurement, and
-- came out four points high on a monitor and ten on a phone. The band then
-- spent a while dropping off the row on a phone, which put it through the
-- radar instead and cost the row the alignment it is for.
--
-- The right end of the row is the dial's two readouts, standing over the
-- instrument they are about: the link meter at the far corner and the tile
-- you are on beside it. The dial itself hangs on the line under them.
--
-- Measured against the clock and the meter's box, since those are what the row
-- has left. The near corner is empty on every window, so there is nothing over
-- there to hold a ruler against and nothing over there for the band to keep
-- clear of either.
local function row_shares_a_center(where, w, h)
    frame({w = w, h = h})
    local meter, tick = box("debug"), drawn("0:33")
    if not (meter and tick) then
        check("the row is drawn on " .. where, false,
              table.concat(words(), " | "))
        return
    end
    -- The tile you are on, which is the reading the bars are not: a pair of
    -- numbers with the word that says they are a place.
    check("and where you are is written out on " .. where,
          drawn("POS") ~= nil and drawn("6,6") ~= nil,
          table.concat(words(), " | "))
    -- The clock is the row's line and the meter's box is the row's box, so
    -- the clock stands inside it at every window size. Said between two
    -- things that were drawn rather than worked out here.
    local mid = down(tick)
    check("the row's line sits inside the row's box on " .. where,
          mid + tick.px / 2 < meter.y + meter.h and mid - tick.px / 2 > meter.y,
          string.format("clock %.1f to %.1f, row %.1f to %.1f",
                        mid - tick.px / 2, mid + tick.px / 2,
                        meter.y, meter.y + meter.h))
    -- The readout at the far end stands on the clock's own line, which is the
    -- whole of what the row is: a clock and two readings on one line. It took
    -- its own vertical off the padding once and came out four points high on a
    -- monitor and ten on a phone.
    local pos = drawn("POS")
    if pos then
        check("and the readout over the dial stands on it on " .. where,
              math.abs(down(pos) - mid) < 0.5,
              string.format("%.1f off a center of %.1f", down(pos), mid))
    end
    -- The band grows outward from the middle and has an instrument at one end
    -- of the row and the window's own edge at the other, so it stays off both.
    local press, corner = box("players_open"), box("map")
    if press then
        check("and the band stays on the screen on " .. where,
              press.x >= 0,
              string.format("band starts %.0f", press.x))
        check("and off the right edge on " .. where,
              press.x + press.w <= w_now + 0.5,
              string.format("band ends %.0f, window is %.0f",
                            press.x + press.w, w_now))
    end
    if press and corner then
        check("and out of the dial on " .. where,
              press.x + press.w <= corner.x,
              string.format("band ends %.0f, dial starts %.0f",
                            press.x + press.w, corner.x))
    end
end

-- --- the dial hangs under its own readouts ---------------------------------

-- The corner is a stack: the meter and the tile readout on the row, the
-- instrument they are about on the line under it. What holds it together is
-- that the meter's own box ends where the dial starts, so the row has one
-- bottom edge and the two are one column of furniture rather than two things
-- that happen to be near each other.
--
-- Everything is asked for its own published box rather than for a number
-- written down here. This used to pair the dial's margin off the right edge
-- against the corner chip's off the left, and that corner is empty now:
-- nothing over there publishes a box or draws a word, so there is no margin
-- to pair against and the pairing would be a constant copied out of the
-- layout. What the two still share is the line, and that is what is checked.
local function dial_hangs_under_its_row(where, w, h)
    frame({w = w, h = h})
    local corner, meter = box("map"), box("debug")
    if not (corner and meter) then
        check("the corner is drawn on " .. where, false,
              "no dial or no meter")
        return
    end
    -- The meter is in the row above it, in the same corner, and reaches the
    -- screen's own edge: a thumb aimed at a corner cannot overshoot off it, and
    -- four bars are narrower than a fingertip.
    check("and the meter is on the row over it on " .. where,
          meter.y + meter.h <= corner.y + 0.5,
          string.format("meter ends %.1f, dial starts %.1f",
                        meter.y + meter.h, corner.y))
    check("and runs into the corner itself on " .. where,
          meter.x + meter.w >= w - 0.5 and meter.y <= 0.5,
          string.format("meter %.0f,%.0f to %.0f,%.0f of %.0f",
                        meter.x, meter.y, meter.x + meter.w,
                        meter.y + meter.h, w))
    -- And the tile readout hangs off the dial's own left edge, so the strip is
    -- as wide as the instrument under it and no wider. That is what keeps the
    -- clock band clear of both: it stops at one measurement rather than two.
    local pos, press = drawn("POS"), box("players_open")
    if pos then
        check("the readout starts where the dial does on " .. where,
              math.abs(pos.x - corner.x) < 0.5,
              string.format("readout at %.1f, dial at %.1f", pos.x, corner.x))
        if press then
            check("and the band stops short of it on " .. where,
                  press.x + press.w <= pos.x,
                  string.format("band ends %.1f, readout starts %.1f",
                                press.x + press.w, pos.x))
        end
    end
end

row_shares_a_center("a monitor", W, H)
dial_hangs_under_its_row("a monitor", W, H)

-- A phone is the same drawing at its own size, and it is on the row: the band
-- came off the corner row's line once and went back when the keys beside it
-- lost PLAYERS and the readout beside it went under the dial.
--
-- What it does not keep at 390 points is the names. A corner chip, a centered
-- clock and a dial a third of the screen wide are what that row holds, and a
-- call sign does not fit in what is left. The figures do, and they are the
-- reading.
frame({w = 390, h = 844})
local small_clock = drawn("0:33")
check("a phone draws the same band", small_clock ~= nil,
      table.concat(words(), " | "))
check("and both figures on it",
      drawn("15") ~= nil and drawn("19") ~= nil,
      table.concat(words(), " | "))
if small_clock and clock then
    -- At the same size, since the key it matches is the same size on both.
    check("and at the same size a monitor draws it",
          math.abs(small_clock.px - clock.px) < 0.5,
          string.format("%.0f against %.0f", small_clock.px, clock.px))
end
row_shares_a_center("a phone", 390, 844)
dial_hangs_under_its_row("a phone", 390, 844)

-- Held sideways it is the same phone with 844 points of row, which is width
-- enough for the names, so the drop above is the width rather than the size
-- of the type or a rule about touchscreens.
frame({w = 844, h = 390})
check("a phone on its side has the room and keeps them",
      drawn("PYLON") ~= nil and drawn("CAISSON") ~= nil,
      table.concat(words(), " | "))
dial_hangs_under_its_row("a phone on its side", 844, 390)

-- A call sign runs to twenty four characters and the band grows with it, so
-- the longest one a pilot can register is what decides whether the band fits
-- the row. It gives up the name rather than the row: the number under it is
-- the reading, and a name drawn through the chips in the corner is what put
-- the band on a line of its own the first time.
--
-- Both names or neither, whichever end runs out first. The row's two ends are
-- a small chip and a square a third of a phone across, so asking each side
-- against the end it happens to face dropped one name and drew the other,
-- which reads as a fault rather than as a band out of room. The pair is the
-- unit.
local SHORT = NAMES
NAMES = {[0] = string.rep("W", 24), [1] = string.rep("M", 24)}
frame({w = 390, h = 844})
check("names that would reach either instrument are both dropped",
      drawn(NAMES[0]) == nil and drawn(NAMES[1]) == nil,
      table.concat(words(), " | "))
check("and both figures are drawn either way",
      drawn("15") ~= nil and drawn("19") ~= nil,
      table.concat(words(), " | "))
row_shares_a_center("a phone with the longest names there are", 390, 844)
-- And kept where the row has the width for them, which is the whole point of
-- measuring rather than dropping the names on every phone.
frame()
check("a monitor has the room and keeps them",
      drawn(NAMES[0]) ~= nil and drawn(NAMES[1]) ~= nil,
      table.concat(words(), " | "))
-- And on the screen rather than merely drawn: the check above says the names
-- were placed, and this says where the far one stops.
local grown = drawn(NAMES[1])
if grown then
    check("the names it kept stay inside the row",
          grown.x + #NAMES[1] * grown.px * (1233 / 2048) <= box("map").x,
          string.format("ends %.0f, dial starts %.0f",
                        grown.x + #NAMES[1] * grown.px * (1233 / 2048),
                        box("map").x))
end
NAMES = SHORT

-- --- the map takes the same corner, on the same line ----------------------

-- One corner, one instrument, and the map is the radar pulled back to the
-- whole arena. Same line, same margin, and wider: two thirds of the short side
-- of the window reaches past the middle of an upright phone, so a map on the
-- clock's row would be a map with the clock drawn on top of it, and both
-- instruments hang under that row for the map's sake.
--
-- The row's end does not move when it opens, either. That is the radar's
-- resting edge, so a band that had room for its names keeps them while a
-- player reads the map, and the two readouts over the corner stay where the
-- radar left them.
do
    -- The same names either way: the section above leaves the longest call
    -- signs there are in `NAMES`, and a band measured against those is not
    -- the band this compares.
    --
    -- The radar at rest is what the map is measured against, since the map is
    -- that same corner drawn wider, and the meter's box is the row it has to
    -- start under. Both were published rather than worked out here.
    frame()
    local before, pos_before = box("players_open"), drawn("POS")
    local rest, meter = box("map"), box("debug")
    ui.map = true
    frame()
    local corner, press = box("map"), box("players_open")
    check("the map stands in the dial's corner", corner ~= nil)
    -- The strip over it belongs to the corner rather than to whichever
    -- instrument is in it, and it is measured against the dial at rest. A
    -- readout that walked left with the map would take the band's names with
    -- it and land the meter's press somewhere else.
    local pos_after = drawn("POS")
    check("and the readouts over it stay where the radar left them",
          pos_before and pos_after
              and math.abs(pos_after.x - pos_before.x) < 0.5,
          pos_before and pos_after
              and string.format("%.1f against %.1f", pos_after.x, pos_before.x)
              or "no readout on one of the two frames")
    if corner and rest and meter then
        check("wider than the dial at rest",
              corner.w > 168, string.format("%.0f wide", corner.w))
        check("and under the row rather than on it",
              corner.y >= meter.y + meter.h,
              string.format("map at %.0f, row ends %.0f",
                            corner.y, meter.y + meter.h))
        check("keeping the radar's own margin from the right edge",
              math.abs((W - (corner.x + corner.w))
                       - (W - (rest.x + rest.w))) < 0.5,
              string.format("map leaves %.1f, radar leaves %.1f",
                            W - (corner.x + corner.w),
                            W - (rest.x + rest.w)))
    end
    check("and a monitor's band is untouched by opening it",
          drawn("PYLON") ~= nil and drawn("CAISSON") ~= nil
              and press and before
              and math.abs(press.w - before.w) < 0.5,
          table.concat(words(), " | "))
    -- A phone's map is the case that forced the line: on the row it would
    -- start left of the clock.
    frame({w = 390, h = 844})
    local small, small_meter = box("map"), box("debug")
    if small and small_meter then
        check("a phone's map reaches past the middle of the window",
              small.x < 195,
              string.format("starts at %.0f of 390", small.x))
        check("and is under the row, clear of the clock",
              small.y >= small_meter.y + small_meter.h,
              string.format("map at %.0f, row ends %.0f",
                            small.y, small_meter.y + small_meter.h))
    end
    ui.map = false
    frame()
end

-- --- the band is the control -----------------------------------------------

frame()
local band = box("players_open")
check("the band publishes the press that opens the roster", band ~= nil)
if band and clock then
    check("the press covers the band and no more of the arena",
          band.w < W / 2 and band.y < 40,
          string.format("%.0f wide at %.0f", band.w, band.y))
    check("a press on the clock reaches it",
          ui.pick(W / 2, band.y + band.h / 2) ~= nil
              and ui.pick(W / 2, band.y + band.h / 2).action == "players_open",
          "the clock is not the control")
    -- The field of play is the trigger's. A box over the arena eats the shot
    -- that lands in it, so the band's own is the only one up here.
    check("and the arena under it is still the gun's",
          ui.pick(W / 2, 300) == nil, "something is published over the fight")
end
-- Once, and from the band. PLAYERS was a key in the corner that carried the
-- head count and opened this same panel; the count is a column of the panel
-- now, one line per pilot, so a second box for it would be the offer made
-- twice. Counted rather than compared against a key's edge, which is what
-- this asked while there was always something standing in that corner.
local ways = 0
for _, r in ipairs(ui.hits) do
    if r.action == "players_open" then ways = ways + 1 end
end
check("nothing else opens the roster", ways == 1,
      ways .. " boxes open it")

-- And in an ordinary match there is nothing up there to be the second one.
-- Every chip the corner can hold is situational: a seat the room is keeping
-- for a watcher, a second room to move to, the camera being on you. None of
-- the three is true here, and the way into the menu left for the foot, so
-- that corner is the fight.
local standing = {}
for _, r in ipairs(ui.hits) do
    if r.y < band.y + band.h and r.x + r.w <= band.x then
        standing[#standing + 1] = r.action
    end
end
check("and the corner row is empty in an ordinary match",
      #standing == 0, table.concat(standing, " | "))

-- --- at the whistle -------------------------------------------------------
--
-- The band is what says who took the match. It used to give both sides up
-- here and hand the result to a block of its own a few lines down the window;
-- the block is gone with decision 147, so the one instrument that has carried
-- the score for three minutes carries the result as well, in the same pixels.

frame({match = {playing = false, left = 18, score = {[0] = 15, [1] = 19}}})
check("the whistle keeps both sides on the band",
      drawn("PYLON") ~= nil and drawn("CAISSON") ~= nil,
      table.concat(words(), " | "))
check("and says what the clock is counting to",
      drawn("NEXT MATCH IN") ~= nil, table.concat(words(), " | "))
do
    -- Who won, said by weight rather than by a word: the winner keeps its ink
    -- and the beaten side stands down. Read off the score rather than the
    -- name, since a name is dropped where the row runs out of room and a
    -- score never is.
    local lost, won = drawn("15"), drawn("19")
    local la = lost and lost.col and lost.col[4]
    local wa = won and won.col and won.col[4]
    check("the side that took it keeps its ink",
          la ~= nil and wa ~= nil and wa > la * 1.5,
          la and wa and string.format("%.2f won, %.2f lost", wa, la)
          or "a score is missing")
end
-- A draw stands neither side down, which is what a draw is.
frame({match = {playing = false, left = 18, score = {[0] = 17, [1] = 17}}})
do
    local both = 0
    for i = 1, state.n do
        if state.text[i].s == "17" then both = both + 1 end
    end
    check("and a draw stands neither of them down", both == 2,
          both .. " scores drawn")
end

-- And nothing it opens while the sheet the whistle raised is up: what the
-- band opens is a stop of that menu, and a control that opens what is already
-- open is a press with nothing answering it.
frame({match = {playing = false, left = 18, score = {[0] = 15, [1] = 19}},
       menu_open = true})
check("and offers no press while the menu it opens is standing",
      box("players_open") == nil)

-- --- what the room says ----------------------------------------------------
--
-- The banner was 24 points of ink across the middle of the arena, over the
-- fight it was about. What is left of it is a label under the band, in the
-- register every other instrument here uses.

frame({banner = "Every rival beaten. A new run starts now"})
local note = drawn("Every rival beaten. A new run starts now")
check("the room's line is drawn", note ~= nil, table.concat(words(), " | "))
if note and clock then
    check("under the band rather than over the fight",
          down(note) > down(clock) and down(note) < H / 3,
          string.format("%.0f of %d", down(note), H))
    check("and at a label's size rather than a headline's",
          note.px <= 13, string.format("%.0f", note.px))
end

-- --- the flag strip is a line of its own ------------------------------------
--
-- A mode with flags hangs one mark per flag off the band, colored by who
-- holds it. This is where it goes, and the check is mostly that it goes
-- anywhere at all: the strip was pinned twenty-five points above where the
-- room's line lands, which is eight points inside the band, so in Turf and
-- Capture the Flag every flag stood a staff up through the clock and the
-- score read as garble.
-- Nothing caught it because until those zones there were no flags to draw.
--
-- Measured against the clock's own box rather than a number written here. The
-- band is a key tall and the strip is placed off its foot, so a check against a
-- constant would pass on a band that had moved.

local FLAGS = {{100, 100, 0, 0}, {200, 100, 1, 0},
               {300, 100, 255, 0}, {400, 100, 0, 0}}

-- The strip, in the coordinates everything here counts in: down from the top,
-- where the mesh the marks come off counts up from the bottom.
--
-- Which discs are the strip's takes two bounds, and both earn their place.
-- The dial draws the same mark for the same flags in its own corner, and the
-- roster draws a dot per contact, so asking for a disc alone collects the
-- whole screen and asking for near the top alone still collects the dial's,
-- which on a phone hang level with these. What is left after both is the
-- band's column: the middle of the window, above the fight.
--
-- Counted by column rather than by disc, because one mark is two of them: a
-- soft one for the light and a hard core inside it, both on the same x.
--
-- Read with the board shut. An open board is a panel standing in that same
-- column and lays discs of its own; where the board goes is asked below by
-- taking its published box on one frame and the strip on another, since
-- neither moves for the other.
local function strip()
    local reach = {top = nil, bottom = nil, left = nil, right = nil, n = 0}
    local seen = {}
    for _, g in ipairs(marks) do
        local hi, lo = h_now - (g.y + g.r), h_now - (g.y - g.r)
        if math.abs(g.x - w_now / 2) < w_now / 6 and hi < h_now / 4 then
            local col = string.format("%.1f", g.x)
            if not seen[col] then
                seen[col] = true
                reach.n = reach.n + 1
            end
            if not reach.top or hi < reach.top then reach.top = hi end
            if not reach.bottom or lo > reach.bottom then reach.bottom = lo end
            if not reach.left or g.x < reach.left then reach.left = g.x end
            if not reach.right or g.x > reach.right then reach.right = g.x end
        end
    end
    if reach.n == 0 then return nil end
    return reach
end

do
    frame()
    check("a mode with no flags draws no strip", strip() == nil,
          "something upright is drawn on the band with no flags out")

    frame({flags = FLAGS})
    local pennants, tick = strip(), drawn("0:33")
    check("a mode with flags draws one mark per flag",
          pennants ~= nil and pennants.n == #FLAGS,
          pennants and (pennants.n .. " marks for " .. #FLAGS .. " flags")
              or "no strip at all")
    if pennants and tick then
        local band_low = down(tick) + tick.px / 2
        check("and the strip stands clear under the band",
              pennants.top >= band_low,
              string.format("strip starts %.1f, the clock ends %.1f",
                            pennants.top, band_low))
        check("and is centered on the same middle the band is",
              math.abs((pennants.left + pennants.right) / 2 - W / 2) < 0.5,
              string.format("%.1f of %d",
                            (pennants.left + pennants.right) / 2, W / 2))
    end

    -- And the rest of the column comes down to meet it, rather than the strip
    -- being drawn through whatever was already standing there. The room's line
    -- and the board are both placed off the band, so both have to know.
    local line = "Keel holds all 4 flags"
    frame({flags = FLAGS, banner = line})
    local said, penn = drawn(line), strip()
    check("the room's line is still drawn with flags out", said ~= nil,
          table.concat(words(), " | "))
    if said and penn then
        check("and lands under the pennants rather than through them",
              down(said) - said.px / 2 >= penn.bottom,
              string.format("the line starts %.1f, the strip ends %.1f",
                            down(said) - said.px / 2, penn.bottom))
    end

    -- Nothing moves in a mode without them. The stack is the same column it
    -- was before flags existed when the room has none to hang on it.
    frame({banner = line})
    local bare = drawn(line)
    frame({flags = FLAGS, banner = line})
    local under = drawn(line)
    check("and a room with no flags keeps the line where it always was",
          bare ~= nil and under ~= nil and down(under) > down(bare),
          bare and under and string.format("%.1f against %.1f",
                                           down(under), down(bare))
              or "the line went missing")

    -- At the whistle the band's own slot goes back to the clock's countdown:
    -- the match is over, so who is holding what is a reading about a fight
    -- that has finished, and NEXT MATCH IN wants the line under the band.
    frame({flags = FLAGS,
           match = {playing = false, left = 21, score = {[0] = 15, [1] = 19}}})
    check("and the whistle takes the strip down", strip() == nil,
          "the flag strip outlived the match")
    local next_up = drawn("NEXT MATCH IN")
    frame({match = {playing = false, left = 21, score = {[0] = 15, [1] = 19}}})
    local flagless = drawn("NEXT MATCH IN")
    check("so the countdown's caption is where it is without them",
          next_up ~= nil and flagless ~= nil
              and math.abs(down(next_up) - down(flagless)) < 0.5,
          next_up and flagless
              and string.format("%.1f against %.1f",
                                down(next_up), down(flagless))
              or "no caption")
end

if fails > 0 then
    print(fails .. " failed")
    os.exit(1)
end
print("all good")
