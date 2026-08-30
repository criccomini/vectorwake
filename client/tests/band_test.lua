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
-- The corner row is not the way into the menu either. That key is at the foot
-- now (see column_test.lua), and what is left up there is chips about this
-- room and this pilot: a held seat, a room number, the ON AIR tally. None of
-- the three is drawn in an ordinary match, so the checks that need something
-- standing on the row ask for a zone holding a second room, which is what
-- draws the ROOM chip.
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
for _, name in ipairs({"arc", "disc", "flush", "halo", "outline", "quad",
                       "reset", "ring", "seg", "seg_fade", "seg_flat",
                       "skirt", "tri", "tri_fade"}) do
    layer[name] = noop
end

-- How thin the thinnest outline on the row came out.
--
-- A hard-edged rect thinner than a pixel covers a pixel center or misses it on
-- where the row happens to sit, so the same edge goes missing on every chip
-- that shares the row at once. It is arithmetic no assertion about strings can
-- see and no screenshot in CI would catch, so the thickness is recorded rather
-- than trusted.
--
-- This lived in podium_test, guarding the saying chips on the match ending.
-- Those chips went, and the check spent a while satisfied by the corner MENU
-- key's own box, which was the last outline on that frame; when the key
-- stopped wearing a box there was nothing left for it to measure at all. The
-- chips it is really about are the ones in this corner.
local thinnest = nil
layer.frame = function(self, _, _, _, _, t)
    self.n = self.n + 1
    if t and (not thinnest or t < thinnest) then thinnest = t end
end
-- Recorded rather than counted: the wash the board lays over the fight is a
-- rect the size of the window, and nothing else on screen is.
layer.rect = function(self, x, y, w, h, col)
    self.n = self.n + 1
    rects[#rects + 1] = {x = x, y = y, w = w, h = h, col = col}
end

local room = {count = 4, teams = {[0] = 0, 1, 0, 1}}
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

-- A zone holding more than one room, which is what puts a ROOM chip in the
-- corner. The chip is what this file measures the row against: it publishes a
-- box at exactly a key's height, on exactly the row's line. The band's own box
-- is a few points taller than the row on purpose, so a finger can find it, and
-- reading the row's line off that box would be reading the padding.
local ROOMS = {{n = 1, players = 3, bots = 20},
               {n = 2, players = 0, bots = 51}}

local function frame(o)
    o = o or {}
    w_now, h_now = o.w or W, o.h or H
    rects = {}
    thinnest = nil
    state.n = 0
    ui.begin(layer, w_now, h_now, 1, false, o.now)
    ui.hud({
        me = 0,
        side = 0,
        viewer_name = "you",
        class_names = {"Apex", "Wedge"},
        menu_open = o.menu_open or false,
        pilots = o.pilots or PILOTS,
        watchers = nil,
        teams = {},
        match = o.match or {playing = true, left = 33,
                            score = {[0] = 15, [1] = 19}},
        side_names = NAMES,
        feed = {},
        hurt = 0,
        charges = {},
        cam_x = 100, cam_y = 100,
        half_w = w_now / 2, half_h = h_now / 2,
        banner = o.banner or "",
        rtt = 4,
        zone = "melee",
        rooms = o.rooms, room = o.room,
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

-- --- a side is a name over a number ----------------------------------------

ui.details = false
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
    check("a team's score sits under its own name",
          down(fifteen) > down(pylon) and down(nineteen) > down(caisson),
          string.format("%.0f under %.0f, %.0f under %.0f",
                        down(fifteen), down(pylon),
                        down(nineteen), down(caisson)))
    check("and shares its edge",
          math.abs(pylon.x - fifteen.x) < 0.5
              and math.abs(caisson.x - nineteen.x) < 0.5,
          string.format("%.1f/%.1f and %.1f/%.1f", pylon.x, fifteen.x,
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

    -- The whole point of the stack: a side is exactly as tall as the clock it
    -- stands beside, so the band reads as one line of instrument rather than
    -- as a block with a clock in the middle of it.
    local tall = (pylon.y + pylon.px / 2) - (fifteen.y - fifteen.px / 2)
    check("a side is as tall as the clock",
          tall <= clock.px + 0.5 and tall > clock.px * 0.9,
          string.format("%.1f against %.1f", tall, clock.px))
    -- And one key tall. The band, the corner chips and the dial are what the
    -- top row carries, so the row has one height and the clock is measured
    -- against a chip rather than against a number written down here:
    -- `corner_row` publishes that box at exactly a key's own size.
    --
    -- Drawn with a second room in the zone, because an ordinary match leaves
    -- that corner empty and there is then nothing up there to hold a ruler
    -- against. The reading being compared was taken above and copied out, so
    -- redrawing the window does not disturb it.
    frame({rooms = ROOMS, room = 1})
    local key = box("rooms")
    check("the clock is as tall as a corner chip", key ~= nil
              and math.abs(clock.px - key.h) < 0.5,
          key and string.format("%.1f against %.1f", clock.px, key.h)
              or "no room chip")
end

-- --- the outlines up there hold a pixel -------------------------------------

do
    frame({rooms = ROOMS, room = 1})
    check("the corner chips are outlined at all", thinnest ~= nil,
          "nothing on the row drew an outline")
    check("and no outline on the row is thinner than a pixel",
          thinnest ~= nil and thinnest >= 1, tostring(thinnest))
end

-- --- the top row is a row ---------------------------------------------------

-- The corner chips at the left, the band beside them and the dial at the far
-- end, on one line, at every window size. The readouts each worked their own
-- vertical out of the padding once, which is a horizontal measurement, and
-- came out four points high on a monitor and ten on a phone. The band then
-- spent a while dropping off the row on a phone, which put it through the
-- radar instead and cost the row the alignment it is for.
--
-- The link meter used to be the right end of this row and is in the menu's
-- head now. What took the corner it left is the dial, which used to start a
-- line lower, so the row is a chip, a band and an instrument and nothing
-- else: the tile readout that stood up here on the wider windows is gone from
-- the interface entirely.
--
-- Measured against a chip's published box, because that is the height the row
-- takes from and the one thing here that cannot drift out of step with
-- itself. The window is redrawn with a second room in the zone so there is a
-- chip to measure. A match with one room puts nothing in that corner at all,
-- which the section on the band as a control checks on its own.
local function row_shares_a_center(where, w, h)
    frame({w = w, h = h, rooms = ROOMS, room = 1})
    local key, tick = box("rooms"), drawn("0:33")
    if not (key and tick) then
        check("the row is drawn on " .. where, false,
              table.concat(words(), " | "))
        return
    end
    -- The link meter draws four bars and no caption, so what says it is not
    -- up here is the box it would publish over itself.
    check("and the link meter is not on it on " .. where,
          box("debug") == nil, "the meter is still in the corner")
    -- And no tile readout anywhere on the screen, not merely off this row.
    -- Where you are was a caption on the dial and then a word in this corner
    -- before that, and the instrument under it draws the same fact.
    check("and nothing writes out where you are on " .. where,
          drawn("POS") == nil, "the tile readout is back")
    local mid = key.y + key.h / 2
    check("the row shares one center on " .. where,
          math.abs(down(tick) - mid) < 0.5,
          string.format("%.1f off a center of %.1f", down(tick), mid))
    -- Both ends of the row are instruments and the band grows outward from
    -- the middle, so it is aligned with neither for longer than it stays off
    -- them.
    local press, corner = box("details"), box("map")
    if press then
        check("and the band keeps out of the chip on " .. where,
              press.x > key.x + key.w,
              string.format("band starts %.0f, chip ends %.0f",
                            press.x, key.x + key.w))
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

-- --- the dial hugs the corner ----------------------------------------------

-- What the row's right end is: the dial itself, hard into the corner, at the
-- margin the chips keep from the corner opposite. It hung a row lower for as
-- long as the link bars stood above it, and with those in the menu's head
-- there was nothing left up there to start under.
--
-- Both instruments are asked for their own published box rather than for a
-- number written down here, because the check is that the two margins match.
-- A `PAD` that moved on one of them and not the other would pass against a
-- constant and still look wrong on the screen. The chip stands for the near
-- corner, so the window is redrawn with a second room in the zone.
local function dial_hugs_the_corner(where, w, h)
    frame({w = w, h = h, rooms = ROOMS, room = 1})
    local key, corner = box("rooms"), box("map")
    if not (key and corner) then
        check("the dial is in the corner on " .. where, false,
              "no dial or no room chip")
        return
    end
    check("the dial starts on the chip's own line on " .. where,
          math.abs(corner.y - key.y) < 0.5,
          string.format("dial at %.1f, chip at %.1f", corner.y, key.y))
    check("and keeps the chip's own margin from its corner on " .. where,
          math.abs((w - (corner.x + corner.w)) - key.x) < 0.5
              and math.abs(corner.y - key.y) < 0.5,
          string.format("gap %.1f right and %.1f top against the chip's %.1f",
                        w - (corner.x + corner.w), corner.y, key.x))
end

row_shares_a_center("a monitor", W, H)
dial_hugs_the_corner("a monitor", W, H)

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
dial_hugs_the_corner("a phone", 390, 844)

-- Held sideways it is the same phone with 844 points of row, which is width
-- enough for the names, so the drop above is the width rather than the size
-- of the type or a rule about touchscreens.
frame({w = 844, h = 390})
check("a phone on its side has the room and keeps them",
      drawn("PYLON") ~= nil and drawn("CAISSON") ~= nil,
      table.concat(words(), " | "))
dial_hugs_the_corner("a phone on its side", 844, 390)

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

-- --- the map takes the same corner, a line lower --------------------------

-- One corner, one instrument, and the map is the radar pulled back to the
-- whole arena. It does not take the radar's line with it: two thirds of the
-- short side of the window reaches past the middle of an upright phone, so a
-- map on the row would be a map with the clock drawn on top of it. It hangs
-- under the row instead, which is where both of them used to start.
--
-- The row's end does not move when it opens, either. That is the radar's
-- resting edge, so a band that had room for its names keeps them while a
-- player reads the map.
do
    -- The same names either way: the section above leaves the longest call
    -- signs there are in `NAMES`, and a band measured against those is not
    -- the band this compares. A room chip stands in the corner throughout, so
    -- the row it hangs under has an edge and a height that were published
    -- rather than worked out here.
    frame({rooms = ROOMS, room = 1})
    local before = box("details")
    ui.map = true
    frame({rooms = ROOMS, room = 1})
    local corner, key, press = box("map"), box("rooms"), box("details")
    check("the map stands in the dial's corner", corner ~= nil)
    if corner and key then
        check("wider than the dial at rest",
              corner.w > 168, string.format("%.0f wide", corner.w))
        check("and under the row rather than on it",
              corner.y >= key.y + key.h,
              string.format("map at %.0f, row ends %.0f",
                            corner.y, key.y + key.h))
        check("keeping the dial's own margin from the right edge",
              math.abs((W - (corner.x + corner.w)) - key.x) < 0.5,
              string.format("gap %.1f against the chip's %.1f",
                            W - (corner.x + corner.w), key.x))
    end
    check("and a monitor's band is untouched by opening it",
          drawn("PYLON") ~= nil and drawn("CAISSON") ~= nil
              and press and before
              and math.abs(press.w - before.w) < 0.5,
          table.concat(words(), " | "))
    -- A phone's map is the case that forced the line: on the row it would
    -- start left of the clock.
    frame({w = 390, h = 844, rooms = ROOMS, room = 1})
    local small, small_key = box("map"), box("rooms")
    if small and small_key then
        check("a phone's map reaches past the middle of the window",
              small.x < 195,
              string.format("starts at %.0f of 390", small.x))
        check("and is under the row, clear of the clock",
              small.y >= small_key.y + small_key.h,
              string.format("map at %.0f, row ends %.0f",
                            small.y, small_key.y + small_key.h))
    end
    ui.map = false
    frame()
end

-- --- the band is the control -----------------------------------------------

frame()
local band = box("details")
check("the band publishes the press that opens the roster", band ~= nil)
if band and clock then
    check("the press covers the band and no more of the arena",
          band.w < W / 2 and band.y < 40,
          string.format("%.0f wide at %.0f", band.w, band.y))
    check("a press on the clock reaches it",
          ui.pick(W / 2, band.y + band.h / 2) ~= nil
              and ui.pick(W / 2, band.y + band.h / 2).action == "details",
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
    if r.action == "details" then ways = ways + 1 end
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

-- --- the board opens under it ----------------------------------------------

ui.details = true
frame()
local heading = drawn("PILOTS")
local panel = box("scores")
check("the roster opens", heading ~= nil and panel ~= nil,
      table.concat(words(), " | "))
if heading and panel and band then
    check("under the band rather than under the corner keys",
          panel.y > band.y + band.h,
          string.format("board at %.0f, band ends %.0f",
                        panel.y, band.y + band.h))
    check("and centered on the window the band is centered on",
          math.abs((panel.x + panel.w / 2) - W / 2) < 2,
          string.format("%.0f of %d", panel.x + panel.w / 2, W / 2))
end

-- The board is what is being read while it is up, so the fight behind it
-- stands back: one wash over the whole window, the way the menu does it.
local washed = nil
for _, r in ipairs(rects) do
    if r.x == 0 and r.y == 0 and r.w == W and r.h == H then washed = r end
end
check("the fight behind it is dimmed", washed ~= nil,
      "no wash over the window")

ui.details = false
frame()
local still = nil
for _, r in ipairs(rects) do
    if r.x == 0 and r.y == 0 and r.w == W and r.h == H then still = r end
end
check("and undimmed once it is shut", still == nil,
      "the wash outlived the board")

-- A phone gives the board the width between its margins rather than a column
-- down the middle of it with a gutter either side.
ui.details = true
frame({w = 390, h = 844})
local phone_panel = box("scores")
check("a phone spends the whole width on the board",
      phone_panel ~= nil and phone_panel.w > 390 * 0.8,
      phone_panel and string.format("%.0f of 390", phone_panel.w) or "no board")
ui.details = false

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

if fails > 0 then
    print(fails .. " failed")
    os.exit(1)
end
print("all good")
