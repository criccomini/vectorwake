-- The in-game menu: a faint key at the foot, and the column it raises.
--
--     lua5.1 client/tests/column_test.lua
--
-- Settings live in the match and nowhere else, so this column is the whole of
-- the menu: the way out of the seat, which side you are on, and the machine.
-- It stands where the key that raised it stood, at the landing's own width,
-- with the stops over a breathing RESUME. Nothing pauses while it is up.
--
-- These run the real `M.hud` and `M.menu` against a stubbed engine. The
-- questions are the ones a hand would ask: where is the way in, did the column
-- land where I pressed, can I still see the fight, and can I reach every side
-- in one press.

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
for _, name in ipairs({"arc", "flush", "outline", "quad", "reset", "ring",
                       "seg", "seg_fade", "seg_flat", "skirt", "tri",
                       "tri_fade", "fan", "seg_glow", "glow_band", "halo",
                       "ring_fade", "disc", "clip", "unclip", "arc_aa",
                       "bloom", "ring_aa", "resize"}) do
    layer[name] = noop
end
layer.round_segs = function(_, r)
    return math.max(12, math.min(96, math.ceil((r or 1) / 2)))
end

local boxes, rects, segs = {}, {}, {}
layer.seg = function(self, x0, y0, x1, y1)
    self.n = self.n + 1
    segs[#segs + 1] = {x0 = x0, y0 = y0, x1 = x1, y1 = y1}
end
layer.frame = function(self, x, y, w, h)
    self.n = self.n + 1
    boxes[#boxes + 1] = {x = x, y = y, w = w, h = h}
end
layer.rect = function(self, x, y, w, h, col)
    self.n = self.n + 1
    rects[#rects + 1] = {x = x, y = y, w = w, h = h, col = col}
end

local glass = {reset = function() end, flush = function() end,
               rect = function() end}

local SEATS = {}
for i = 0, 7 do
    SEATS[i] = {name = "pilot " .. i, label = i % 2 == 0 and "human" or "bot",
                ai = i % 2 == 1}
end
_G.sim = setmetatable({
    ship_count = function() return 8 end,
    ship_active = function() return 1 end,
    ship_alive = function() return 1 end,
    ship_x = function(i) return 3000 + i * 90 end,
    ship_y = function(i) return 3000 + i * 60 end,
    ship_team = function(i) return i < 4 and 0 or 1 end,
    ship_energy = function() return 100 end,
    ship_max_energy = function() return 100 end,
    has_trigger = function() return true end,
    weapon_count = function() return 0 end,
    flag_count = function() return 0 end,
    flag_at = function() return 0, 0, 255 end,
    map_coarse = function() return nil end,
    BTN_FIRE = 1,
}, {__index = function() return function() return 0 end end})

package.loaded["arena.state"] = dofile("client/arena/state.lua")
package.loaded["arena.touch"] = {
    layout = function() return {charge = {}} end,
    used = false,
}
package.loaded["arena.world"] = {
    build_overview = function() end,
    forget_overview = function() end,
    overview = function() return {grid = 0, rects = {}} end,
    radar_tiles = {2960, 2960},
    radar_safe = {},
    radar_doors = {},
}

local ui = require("arena.ui")
local state = package.loaded["arena.state"]

-- --- the harness -----------------------------------------------------------

-- The column as `menu.view` builds it in a room holding three sides: the way
-- out, the machine, and which side you are on.
local function view(o)
    o = o or {}
    local v = {
        open = o.open ~= false,
        stops = {
            {stop = "leave", label = "leave", value = "seat"},
            {stop = "settings", label = "settings", mark = "settings"},
            {stop = "side", label = "side", value = "Pylon", named = true},
        },
        rows = {},
    }
    if o.stops == 2 then table.remove(v.stops) end
    for _, s in ipairs(v.stops) do s.open = (s.stop == o.at) end
    if o.at == "side" then
        v.rows = {
            {label = "Pylon", index = 1, detail = "8", tint = 0, mark = true,
             named = true, pick = true},
            {label = "Caisson", index = 2, detail = "7", tint = 1,
             named = true, pick = true},
            {label = "Meridian", index = 3, detail = "6", tint = 2,
             named = true, pick = true},
        }
    elseif o.at == "settings" then
        v.page = "settings"
        v.rows = {
            {label = "sound", index = 1, sect = "audio", detail = "half",
             choice = 2, choices = 4, pick = true},
            {label = "music", index = 2, detail = "quiet", choice = 1,
             choices = 3, pick = true},
            {label = "frames", index = 3, sect = "video",
             detail = "as the display asks", pick = true},
            {label = "fullscreen", index = 4, detail = "fill the screen",
             pick = true},
            {label = "controls", index = 5, sect = "the machine",
             detail = "keys and pads", pick = true},
            {label = "about", index = 6, detail = "this build", pick = true},
            -- One row as long as the longest the client ships, which is a
            -- thumb sentence off the controls board. It is here so the panel
            -- is measured against something that can actually run off it.
            {label = "fire", index = 7, sect = "the machine",
             detail = "Left thumb: point where you want the nose",
             pick = true},
        }
    end
    return v
end

-- One frame in a seat: the HUD, and the column over it when one is up.
local function frame(w, h, o)
    o = o or {}
    boxes, rects, segs = {}, {}, {}
    state.n = 0
    ui.details = false
    ui.col_open = nil
    if not o.keep then
        ui.col_sel, ui.col_sel_value = o.sel, o.sel_value
    end
    ui.page_scroll = o.scroll or 0
    ui.begin(layer, w, h, o.density or 1, o.touching or false, 0, glass)
    ui.hud({
        me = 0,
        landing = o.landing or nil,
        land = nil,
        side = 0,
        viewer_name = "you",
        menu_open = o.open or false,
        pilots = SEATS,
        watchers = {},
        teams = {},
        match = {playing = true, left = 107, score = {[0] = 3, [1] = 5}},
        side_names = {[0] = "Pylon", [1] = "Caisson"},
        feed = {},
        hurt = 0,
        charges = {},
        cam_x = 3000, cam_y = 3000,
        half_w = w / 2, half_h = h / 2,
        banner = "",
        link_bars = 4,
        zone = "melee",
        fps = 60, frame_ms = 16.7, rx_rate = 0, tx_rate = 0,
    })
    if o.open then ui.menu(view(o)) end
    ui.finish()
end

-- Where a named box was published, in the interface's own coordinates.
local function hit_of(action, value)
    for _, r in ipairs(ui.hits) do
        if r.action == action and (value == nil or r.value == value) then
            return r
        end
    end
    return nil
end

local function hits_of(action)
    local out = {}
    for _, r in ipairs(ui.hits) do
        if r.action == action then out[#out + 1] = r end
    end
    return out
end

local function said(word)
    for i = 1, state.n do
        local t = state.text[i]
        if t and t.s and string.find(t.s, word, 1, true) then return t end
    end
    return nil
end

-- --- the way in ------------------------------------------------------------

-- The key is at the bottom middle on every window, which is where the column
-- it opens will stand. It spent years in the top left corner, opening a panel
-- docked to the left edge; a control detached from what it does is the thing
-- this move was made to fix.
for _, win in ipairs({{1440, 810, "monitor"}, {390, 844, "phone upright"},
                      {844, 390, "phone sideways"}}) do
    local w, h, name = win[1], win[2], win[3]
    frame(w, h)
    local key = hit_of("open")
    check(name .. ": the menu key is published", key ~= nil)
    if key then
        local mid = w / 2
        check(name .. ": and stands at the middle",
              math.abs(key.x + key.w / 2 - mid) < 2,
              "center " .. (key.x + key.w / 2) .. " against " .. mid)
        check(name .. ": and at the foot",
              key.y + key.h > h - 40,
              "bottom " .. (key.y + key.h) .. " of " .. h)
    end
end

-- The word rides along, on every window. The corner never had the room for it
-- on a phone, so the mark stood alone there and a first visit had to know what
-- three bars meant.
for _, win in ipairs({{1440, 810, "monitor"}, {390, 844, "phone"}}) do
    frame(win[1], win[2])
    check(win[3] .. ": the key says MENU", said("MENU") ~= nil)
end

-- And it is faint. The key lives inside the fight rather than beside it, so at
-- rest it is furniture: what it must not do is compete with the instruments a
-- pilot is actually flying by.
do
    frame(1440, 810)
    local t = said("MENU")
    check("the key's word is drawn faint", t ~= nil and t.col and t.col[4]
          and t.col[4] < 0.7,
          t and t.col and ("alpha " .. tostring(t.col[4])) or "no word")
end

-- And it wears no box. Every other pressable thing here is a stroked
-- rectangle, and this one is not, because it is the only one standing alone.
-- Over a match a box reads as an instrument, since the band, the dial and the
-- corner chips are the boxes up there. The mark and the word carry it instead.
do
    frame(1440, 810)
    local key = hit_of("open")
    local boxed = 0
    for _, b in ipairs(boxes) do
        if key and b.w and math.abs(b.w - key.w) < 2 then boxed = boxed + 1 end
    end
    check("the menu key is drawn without a box", boxed == 0,
          tostring(boxed) .. " outlines at the key's width")
end

-- Nothing in the corner opens it any more.
do
    frame(1440, 810)
    local corner = false
    for _, r in ipairs(ui.hits) do
        if r.action == "open" and r.y < 200 then corner = true end
    end
    check("the corner row no longer carries the way in", not corner)
end

-- --- where the column lands ------------------------------------------------

-- The press and the panel share a spot. The key's box and RESUME's overlap,
-- which is the whole sentence this layout is making: the thing you pressed is
-- the thing that opened.
do
    frame(1440, 810)
    local key = hit_of("open")
    frame(1440, 810, {open = true})
    local go = hit_of("menu_go")
    check("RESUME is published", go ~= nil)
    if key and go then
        local over = math.min(key.y + key.h, go.y + go.h)
            - math.max(key.y, go.y)
        check("the column comes up where the key was", over > 0,
              "key " .. key.y .. "+" .. key.h .. ", resume " .. go.y
              .. "+" .. go.h)
        check("and on the same middle",
              math.abs((key.x + key.w / 2) - (go.x + go.w / 2)) < 2)
    end
    check("and the key is not drawn under it", hit_of("open") == nil)
end

-- Three stops over the key, in the order they are said, with LEAVE furthest
-- from the thumb that resumes. A press that ends a match should not be the
-- neighbour of the press that ends the menu.
do
    frame(1440, 810, {open = true})
    local stops = hits_of("menu_stop")
    check("the column carries every stop", #stops == 3, "got " .. #stops)
    local by = {}
    for _, r in ipairs(stops) do by[r.value] = r end
    if by.leave and by.settings and by.side then
        check("leave stands at the top",
              by.leave.y < by.settings.y and by.settings.y < by.side.y)
        local go = hit_of("menu_go")
        check("and furthest from the key",
              go and by.leave.y < by.side.y and by.side.y < go.y)
    else
        check("leave stands at the top", false, "stops missing")
        check("and furthest from the key", false, "stops missing")
    end
end

-- A caret on a stop is a promise that a list is about to come up. Two of the
-- three stops keep it: settings opens a panel and side opens a list. Leaving
-- acts, so it wears none, and the count of carets is the count of stops that
-- open something.
do
    frame(1440, 810, {open = true})
    -- The caret is two strokes drawn near a stop's right edge and it is the
    -- only thing in that corner, so counting strokes there counts carets.
    local function strokes_in(stop)
        local r = hit_of("menu_stop", stop)
        if not r then return -1 end
        local n = 0
        for _, sg in ipairs(segs) do
            local mx = (sg.x0 + sg.x1) / 2
            local my = 810 - (sg.y0 + sg.y1) / 2
            if mx > r.x + r.w - 30 and mx < r.x + r.w
               and my > r.y and my < r.y + r.h then
                n = n + 1
            end
        end
        return n
    end
    -- Settings shares that corner with its own mixer mark, so it is asked for
    -- the caret's two strokes on top of whatever the mark drew rather than for
    -- a bare two.
    check("the settings stop wears a caret", strokes_in("settings") > 2,
          tostring(strokes_in("settings")))
    check("and so does the side stop", strokes_in("side") == 2,
          tostring(strokes_in("side")))
    check("and leave, which acts rather than opening, wears none",
          strokes_in("leave") == 0, tostring(strokes_in("leave")))
end

-- A room that has not named its sides yet gets a shorter column, and it grows
-- upward: the sides arrive on the roster broadcast, a frame or two after the
-- column could first be raised, and nothing already under a thumb should move.
do
    frame(1440, 810, {open = true, stops = 2})
    local two = hit_of("menu_go")
    local top2 = hits_of("menu_stop")
    frame(1440, 810, {open = true})
    local three = hit_of("menu_go")
    check("a side that has not arrived leaves two stops", #top2 == 2)
    check("and the key does not move when it does",
          two and three and math.abs(two.y - three.y) < 0.5,
          two and three and (two.y .. " against " .. three.y) or "no key")
end

-- --- nothing pauses --------------------------------------------------------

-- The wash is thin. The ship goes on flying under this, so a curtain would be
-- the interface lying about what the simulation is doing.
do
    frame(1440, 810, {open = true})
    local darkest = 0
    for _, r in ipairs(rects) do
        if r.w >= 1440 and r.h >= 810 and r.col and r.col[4] then
            darkest = math.max(darkest, r.col[4])
        end
    end
    check("the fight is washed rather than covered",
          darkest > 0 and darkest < 0.6, "alpha " .. darkest)
end

-- And the instruments that say a pilot is still in danger keep their line. The
-- drawer covered a phone's whole window, so the clock and the radar stood down
-- under it; the column reaches no corner.
do
    frame(390, 844, {open = true})
    check("the clock still reads under an open menu", said(":47") ~= nil)
    frame(390, 844)
    local shut = said(":47")
    check("as it does with the menu down", shut ~= nil)
end

-- --- the sides -------------------------------------------------------------

-- Every side is one press, however many there are. This was a value stepped
-- left and right while a room held two: in a zone holding three, reaching the
-- third meant crossing the second, and a pilot who wanted the third had joined
-- the second on the way.
do
    frame(1440, 810, {open = true, at = "side"})
    local picks = hits_of("menu_pick")
    check("the side stop opens a row per side", #picks == 3,
          "got " .. #picks)
    local seen = {}
    for _, r in ipairs(picks) do seen[r.value] = true end
    check("and each is its own press", seen[1] and seen[2] and seen[3])
    check("the one you fly for is named", said("Pylon") ~= nil)
    check("and so is the one you would cross to", said("Meridian") ~= nil)
    -- No stepper. The two triangles either side of a value are what a range
    -- wears, and a list of sides is not a range.
    check("the stop it hangs off is not drawn under its own list",
          hit_of("menu_stop", "side") == nil)
end

-- --- settings --------------------------------------------------------------

-- The settings panel climbs off its stop, the way the landing's ship panel
-- climbs off the ship stop.
do
    frame(1440, 810, {open = true, at = "settings"})
    local rows = hits_of("menu_row")
    check("the settings stop opens its rows", #rows >= 6, "got " .. #rows)
    check("sound is on it", said("Sound") ~= nil)
    check("and the controls board is a row of it", said("Controls") ~= nil)
    check("and the way back out is published", hit_of("menu_back") ~= nil)
    -- The column went out through the bottom edge to make room for it, so
    -- there is no key on the screen to stand over: the panel is the screen
    -- while it is up, and RESUME comes back when back is pressed.
    check("the key it came from is off the screen with the column",
          hit_of("menu_go") == nil)
    check("and so are the stops", hit_of("menu_stop", "side") == nil
          and hit_of("menu_stop", "leave") == nil)
    local top = math.huge
    for _, r in ipairs(rows) do top = math.min(top, r.y) end
    check("the panel stands where the column was and higher",
          top < 810 / 2, "panel top " .. top)
end

-- The rows come in bands, which is what a page of eight settings cannot say in
-- its title: audio, video, the machine. The drawer grouped them and the panel
-- that replaced it did not for a while, because nothing in the drawing read
-- `sect` off a row.
do
    frame(1440, 810, {open = true, at = "settings"})
    check("the panel draws its section heads", said("AUDIO") ~= nil,
          "no audio band")
    check("and every one of them", said("VIDEO") ~= nil
          and said("THE MACHINE") ~= nil)
end

-- Nothing the panel draws leaves the panel. A row's sentence is the one thing
-- here whose length this file does not choose: at a landscape phone's width
-- the controls board's thumb sentences ran off the panel and over the fight
-- beside it.
do
    -- Scrolled to the foot, because the row that can overflow is the last one
    -- and a landscape phone shows five at a time. A check that measured only
    -- the rows above it would pass whatever the panel did with that one.
    frame(844, 390, {open = true, at = "settings", scroll = 9999})
    local rows = hits_of("menu_row")
    local right = nil
    for _, r in ipairs(rows) do right = right or (r.x + r.w) end
    -- Measured rather than eyeballed: the panel cuts a run at its own edge
    -- rather than wrapping it, so a sentence that would have spilled comes
    -- back from `state.text` shorter than it was written. What this asks is
    -- where the ink ended. The mono's advance is one number for every glyph,
    -- which is what the face this row is set in gives us.
    local ADVANCE = 1233 / 2048
    local widest, over = nil, 0
    for i = 1, state.n do
        local t = state.text[i]
        if t.font ~= "menu" and t.s and t.pivot ~= "right"
           and t.pivot ~= "center" then
            local _, cont = string.gsub(t.s, "[\128-\191]", "")
            local ends = t.x + (#t.s - cont) * t.px * ADVANCE
            if right and ends > right + 1 then
                over = over + 1
                widest = math.max(widest or 0, ends)
            end
        end
    end
    check("nothing the panel draws reaches outside it", over == 0,
          tostring(over) .. " runs past " .. tostring(right)
          .. ", worst " .. tostring(widest))
end

-- The panel is the window less its margin, capped, and centered on the same
-- middle the column stands on.
--
-- Wider than the stop it came from, so opening one reads as a step up rather
-- than sideways, and capped so that a monitor does not get a row eleven
-- hundred points wide with a name at one end and its reading at the other. The
-- cap is what leaves the fight showing either side of the glass, which is what
-- the frost was for.
do
    frame(1440, 810, {open = true})
    local stop = hit_of("menu_stop", "settings")
    frame(1440, 810, {open = true, at = "settings"})
    local row = hits_of("menu_row")[1]
    check("the panel is wider than the stop it came from",
          stop and row and row.w > stop.w,
          stop and row and (stop.w .. " against " .. row.w) or "missing")
    check("and capped well short of the window",
          row and row.w <= 560 and row.w < 1440 * 0.5,
          row and tostring(row.w) or "missing")
    check("and centered on the column's own middle",
          stop and row
          and math.abs((stop.x + stop.w / 2) - (row.x + row.w / 2)) < 2)
    -- A phone has no width to spare, so there the cap never binds and the
    -- panel is the window less its margin, the way every panel here is.
    frame(390, 844, {open = true, at = "settings"})
    local narrow = hits_of("menu_row")[1]
    check("and takes the whole width of a phone", narrow and narrow.w > 340,
          narrow and tostring(narrow.w) or "missing")
end

-- --- the walk --------------------------------------------------------------

-- One cursor, walked by the arrows over the boxes the drawing published. The
-- landing walks the same way, which is what makes this one interface rather
-- than two that look alike.
do
    frame(1440, 810, {open = true})
    ui.col_sel, ui.col_sel_value = nil, nil
    local walk = ui.col_walk()
    check("the walk reaches every stop and the key", #walk == 4,
          "got " .. #walk)
    check("a first press down lands somewhere", ui.col_step(1))
    local first = ui.col_sel
    check("and moves on", ui.col_step(1) and ui.col_sel ~= nil)
    check("and the ends wrap", (function()
        for _ = 1, 8 do ui.col_step(1) end
        return ui.col_sel ~= nil
    end)(), first)
end

-- Enter with nothing lit is RESUME, the way it is PLAY NOW on the landing:
-- there is one thing either column exists for and a keyboard should not have
-- to walk to it.
do
    frame(1440, 810, {open = true})
    ui.col_sel, ui.col_sel_value = nil, nil
    local action = ui.col_go()
    check("enter with nothing lit resumes", action == "menu_go",
          tostring(action))
end

-- Left and right step a settings row, which is how sound, music and frames are
-- all set. A row that is a page answers nothing, because left is the way back
-- out and it has its own key.
do
    frame(1440, 810, {open = true, at = "settings"})
    ui.col_sel, ui.col_sel_value = "menu_row", 1
    local action, value = ui.col_side(1)
    check("an arrow steps the row the cursor is on", action == "menu_step",
          tostring(action))
    check("and says which way", type(value) == "table" and value.dir == 1
          and value.index == 1)
end

-- --- the landing -----------------------------------------------------------

-- The front page carries no key at all. The landing watches a live room, and
-- for a while that was taken as reason enough for a menu about it: the key
-- stood in its own strip under PLAY NOW and the column lifted to leave it one.
-- It is not a room you are in. Everything the menu holds is about the seat you
-- took, and out here the three stops over PLAY NOW are the choices that have
-- answers. What the key added was a faint fourth control under the one key the
-- screen exists for.
do
    frame(1440, 810, {landing = true})
    check("the front page carries no menu key", hit_of("open") == nil)
    check("and does not say MENU either", said("MENU") == nil)
    local play = hit_of("play_now")
    check("PLAY NOW is still there", play ~= nil)
    -- And it sits on the bottom margin, with the strip the key used to have
    -- given back. A gap under the one key the screen is for reads as
    -- something missing.
    if play then
        check("and stands on the bottom margin", play.y + play.h > 810 - 30,
              "play ends " .. (play.y + play.h) .. " of 810")
    end
end

-- A player or a spectator inside a room gets it, which is the other half of
-- the same rule: a watcher who chose this room has a seat to leave, a side to
-- be on and a machine to set up.
do
    frame(1440, 810, {watch = {subject = 1}})
    check("a spectator in the room gets the key", hit_of("open") ~= nil)
    frame(1440, 810)
    check("and so does a pilot flying it", hit_of("open") ~= nil)
end

-- --- the slide -------------------------------------------------------------

-- The column is still on screen while it goes away, so the fight comes back
-- through a wash that is fading rather than a panel that vanished. Nothing it
-- publishes can be pressed on the way out: a key that is leaving is not a key.
do
    frame(1440, 810, {open = true})
    ui.begin(layer, 1440, 810, 1, false, 0, glass)
    ui.menu(view({open = false}))
    ui.finish()
    check("a column on its way out answers no press",
          hit_of("menu_go") == nil and hit_of("menu_stop") == nil)
end

-- And the second slide inside it: opening a stop sends the column down through
-- the bottom edge while the panel comes up through the same one, so the two
-- are one movement rather than a swap.
--
-- Asked on a clock, because the harness runs at time zero, where the slide
-- settles in the frame it starts and there is no middle to look at. One frame
-- at the moment of the press and one a little after it is enough to say which
-- way each half is travelling.
do
    -- Settle the column open with nothing else, so the only thing moving in
    -- the frames below is the panel and what it displaces.
    ui.panel_shut()
    frame(1440, 810, {open = true})

    -- Measured off the drawing rather than off the hit boxes: half way through
    -- the column stops answering a press, which is the point of it leaving,
    -- and the question here is where the two of them are rather than what can
    -- be pressed. `state.text` counts up from the bottom of the window, so a
    -- thing going down loses y and a thing coming up gains it.
    local function said_y(word)
        for i = 1, state.n do
            local t = state.text[i]
            if t and t.s == word then return t.y end
        end
        return nil
    end
    local function at(now, v)
        boxes, rects, segs = {}, {}, {}
        state.n = 0
        ui.begin(layer, 1440, 810, 1, false, now, glass)
        ui.menu(v)
        ui.finish()
        return said_y("RESUME"), said_y("Sound")
    end

    -- The frame the press lands on: the column is still where it was and the
    -- panel has not started up yet.
    local shut_key = at(1, view({open = true}))
    local mid_key, mid_row = at(1, view({open = true, at = "settings"}))
    check("the column has not moved on the frame the stop was pressed",
          shut_key and mid_key and math.abs(shut_key - mid_key) < 1,
          tostring(shut_key) .. " then " .. tostring(mid_key))

    -- Part way through, both halves are travelling and neither has arrived.
    local late_key, late_row = at(1.06, view({open = true, at = "settings"}))
    check("part way through, the column is on its way down",
          late_key and mid_key and late_key < mid_key - 1,
          tostring(mid_key) .. " to " .. tostring(late_key))
    check("and the panel is on its way up through the same edge",
          late_row and mid_row and late_row > mid_row + 1,
          tostring(mid_row) .. " to " .. tostring(late_row))
    local rest_key, rest_row = at(9, view({open = true, at = "settings"}))
    check("with the panel still short of where it comes to rest",
          late_row and rest_row and late_row < rest_row - 1,
          tostring(late_row) .. " against " .. tostring(rest_row))

    -- And at rest the column is gone and the panel is standing.
    check("and at rest the column has gone and the panel stands",
          rest_key == nil and hit_of("menu_row") ~= nil,
          tostring(rest_key))

    -- Back plays it the other way. The frame it is pressed on is the mirror of
    -- the frame the stop was pressed on: nothing has moved yet, and the column
    -- is still off the bottom of the screen.
    at(9, view({open = true}))
    check("the frame back is pressed on has not moved either",
          hit_of("menu_go") == nil)
    at(9.06, view({open = true}))
    check("and then the column comes home", hit_of("menu_go") ~= nil
          and hit_of("menu_stop", "leave") ~= nil)
    ui.panel_shut()
end

if fails == 0 then
    print("all good")
else
    print(fails .. " column checks failed")
    os.exit(1)
end
