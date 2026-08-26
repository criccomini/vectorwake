-- The band across the top, and the board a press on it opens.
--
--     lua5.1 client/tests/band_test.lua
--
-- The scoreboard used to be three things in three places: a clock with a score
-- either side of it, a PLAYERS key in the corner that opened the roster, and a
-- sentence across the middle of the arena in the largest type on screen. This
-- pins what replaced them. The band is one instrument -- each side a name over
-- a number, both as tall as the clock between them -- and it is the control
-- that opens the roster, so the corner row carries the way into the menu and
-- nothing else.
--
-- Against the real `M.hud` and a stubbed engine, the way ladder_hud_test does.
-- The duel's own reading of the band is pinned there; this is the team game's,
-- and the parts both games share.

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
for _, name in ipairs({"arc", "disc", "flush", "frame", "outline", "quad",
                       "reset", "ring", "seg", "seg_fade", "seg_flat",
                       "skirt", "tri", "tri_fade"}) do
    layer[name] = noop
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
    overview = function() return {grid = 0, rects = {}} end,
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

local function frame(o)
    o = o or {}
    w_now, h_now = o.w or W, o.h or H
    rects = {}
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
    -- And one key tall. The band and the way into the menu are the two
    -- things on the top row, so the row has one height and the clock is
    -- measured against the key rather than against a number written down
    -- here: `menu_button` publishes that box at exactly the key's own size.
    local key = box("open")
    check("the clock is as tall as the MENU key", key ~= nil
              and math.abs(clock.px - key.h) < 0.5,
          key and string.format("%.1f against %.1f", clock.px, key.h)
              or "no menu key")
end

-- --- the top row is a row ---------------------------------------------------

-- The way into the menu at the left, the band in the middle and the link bars
-- at the right, on one line, at every window size. The readouts each worked
-- their own vertical out of the padding once, which is a horizontal
-- measurement, and came out four points high on a monitor and ten on a phone.
-- The band then spent a while dropping off the row on a phone, which put it
-- through the radar instead and cost the row the alignment it is for.
--
-- Measured against the key's published box, because that is the height the
-- row takes from and the one thing here that cannot drift out of step with
-- itself. `pos_on_row` is the one thing that differs between the two: the
-- tile readout is up here on a monitor and under the dial on a phone, which
-- is what leaves a 390-point row wide enough for the band.
local function row_shares_a_center(where, pos_on_row)
    local key = box("open")
    local pos, bars, tick = drawn("POS"), drawn("LINK"), drawn("0:33")
    if not (key and pos and bars and tick) then
        check("the row is drawn on " .. where, false,
              table.concat(words(), " | "))
        return
    end
    local mid = key.y + key.h / 2
    local off = math.max(math.abs(down(bars) - mid),
                         math.abs(down(tick) - mid),
                         pos_on_row and math.abs(down(pos) - mid) or 0)
    check("the row shares one center on " .. where, off < 0.5,
          string.format("%.1f off a center of %.1f", off, mid))
    if not pos_on_row then
        -- Under the instrument that says the same thing in a picture, and
        -- above where the feed starts, rather than over either of them.
        check("and the tile readout is under the dial on " .. where,
              ui.row_at(pos.x + 1, down(pos)) ~= "radar"
                  and down(pos) < ui.radar_span(),
              string.format("POS at %.0f, dial ends %.0f",
                            down(pos), ui.radar_span()))
    end
    -- The band grows outward from the middle and the row's two ends are
    -- controls, so it is only aligned with them for as long as it stays off
    -- them. `debug` is the box the link cluster publishes over itself, which
    -- is where the right end of the row is.
    local press, bell = box("details"), box("debug")
    if press and bell then
        check("and the band keeps out of both ends of it on " .. where,
              press.x > key.x + key.w and press.x + press.w < bell.x,
              string.format("band %.0f..%.0f between %.0f and %.0f",
                            press.x, press.x + press.w,
                            key.x + key.w, bell.x))
    end
end

row_shares_a_center("a monitor", true)

-- A phone is the same drawing at its own size, and the sides stay on it: the
-- band came off the corner row's line to make room for them once, and both the
-- key that crowded it and the readout that crowded it are out of its way now.
frame({w = 390, h = 844})
local small_clock = drawn("0:33")
check("a phone draws the same band, sides and all",
      drawn("PYLON") ~= nil and drawn("CAISSON") ~= nil
          and small_clock ~= nil,
      table.concat(words(), " | "))
if small_clock and clock then
    -- At the same size, since the key it matches is the same size on both.
    check("and at the same size a monitor draws it",
          math.abs(small_clock.px - clock.px) < 0.5,
          string.format("%.0f against %.0f", small_clock.px, clock.px))
end
row_shares_a_center("a phone", false)

-- A call sign runs to twenty four characters and the band grows with it, so
-- the longest one a pilot can register is what decides whether the band fits
-- the row. It gives up the name rather than the row: the number under it is
-- the reading, and a name drawn through the way into the menu is what put the
-- band on a line of its own the first time.
local SHORT = NAMES
NAMES = {[0] = string.rep("W", 24), [1] = string.rep("M", 24)}
frame({w = 390, h = 844})
check("a name with nowhere to go is dropped rather than drawn over the row",
      drawn(NAMES[0]) == nil and drawn(NAMES[1]) == nil
          and drawn("15") ~= nil and drawn("19") ~= nil,
      table.concat(words(), " | "))
row_shares_a_center("a phone with the longest names there are", false)
-- And kept where the row has the width for it, which is the whole point of
-- asking rather than dropping the name on every phone.
frame()
check("a monitor has the room and keeps them",
      drawn(NAMES[0]) ~= nil and drawn(NAMES[1]) ~= nil,
      table.concat(words(), " | "))
NAMES = SHORT

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
check("nothing in the corner row opens it a second time",
      box("open") ~= nil and band.x > box("open").x + box("open").w,
      "a roster key is still beside MENU")

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

frame({banner = "Sudden death"})
local note = drawn("Sudden death")
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
