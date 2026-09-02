-- The menu raised over a match: a faint key at the foot, and the column it
-- raises.
--
--     lua5.1 client/tests/column_test.lua
--
-- It is the same column the front page is (decision 143), and this is the
-- other arm of it: raised over a fight rather than standing as the screen, so
-- it washes the glass behind it, it can be put away, and it stands where the
-- key that raised it stood. Four stops over one key, and nothing pauses while
-- it is up.
--
-- These run the real `M.hud` and `M.menu` against a stubbed engine. The
-- questions are the ones a hand would ask: where is the way in, did the column
-- land where I pressed, can I still see the fight, and can I reach every row
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
local pal = require("arena.palette")
local state = package.loaded["arena.state"]

-- --- the harness -----------------------------------------------------------

-- The column as `menu.view` builds it in a room holding three sides: where
-- you are, what you fly, the machine, and which side you are on.
local function view(o)
    o = o or {}
    local v = {
        open = o.open ~= false,
        key = o.key or "spectate",
        key_ship = o.key_ship,
        stops = {
            {stop = "account", label = "account", value = "deSoto 412",
             named = true},
            {stop = "zone", label = "zone", value = "Chaos", named = true},
            {stop = "ship", label = "ship", value = "Apex", named = true},
            {stop = "settings", label = "settings"},
        },
        rows = {},
    }
    for _, s in ipairs(v.stops) do s.open = (s.stop == o.at) end
    if o.at == "ship" then
        -- The ship panel: five parts over the purse they are bought with,
        -- and the line on the head that says what closing it will do.
        v.panel = {
            label = "ship", class = 0, free = 2, credits = 7,
            rows = {
                {kind = "sect", sect = "body", label = "Body",
                 detail = "Apex", raw = true},
                {kind = "sect", sect = "guns", label = "Guns",
                 detail = "level 2"},
                {kind = "sect", sect = "bombs", label = "Bombs"},
                {kind = "sect", sect = "specials", label = "Specials",
                 detail = "1 repel"},
                {kind = "sect", sect = "flair", label = "Flair",
                 detail = "standard wake"},
                {kind = "rule"},
                {kind = "reset", label = "Reset", on = true},
            },
        }
        v.foot = o.foot
    elseif o.at == "zone" then
        v.rows = {
            {label = "Chaos", index = 1, note = "4 v 4", mark = true,
             named = true, pick = true},
            {label = "Duel", index = 2, note = "1 v 1", named = true,
             pick = true},
        }
    elseif o.at == "account" then
        v.rows = {
            {label = "sign up", index = 1, offer = true,
             note = "keep your points", pick = true},
            {label = "new name", index = 2, pick = true},
            {rule = true, index = 3},
            {label = "log in", index = 4, pick = true},
        }
    elseif o.at == "settings" then
        v.page = "settings"
        v.rows = {
            {label = "sound", index = 1, detail = "half",
             choice = 2, choices = 4, pick = true},
            {label = "music", index = 2, detail = "quiet", choice = 1,
             choices = 3, pick = true},
            {label = "frames", index = 3,
             detail = "as the display asks", pick = true},
            {label = "fullscreen", index = 4, detail = "fill the screen",
             pick = true},
            {label = "controls", index = 5, detail = "keys", pick = true},
            {label = "about", index = 6, detail = "this build", pick = true},
            -- One row longer than anything the client ships, so the panel is
            -- measured against something that can actually run off it.
            {label = "fire", index = 7,
             detail = "as long an answer as a row will ever carry",
             pick = true},
        }
    end
    return v
end

-- How tall the last frame was. Rects are filed in the layer's space, counting
-- up from the bottom, and hit boxes count down from the top: turning one into
-- the other is the whole of what this is for.
local WIN_H = 0

-- One frame in a seat: the HUD, and the column over it when one is up.
local function frame(w, h, o)
    o = o or {}
    WIN_H = h
    boxes, rects, segs = {}, {}, {}
    state.n = 0
    ui.details = false
    if not o.keep then
        ui.col_sel, ui.col_sel_value = o.sel, o.sel_value
    end
    ui.page_scroll = o.scroll or 0
    ui.begin(layer, w, h, o.density or 1, o.touching or false, 0, glass)
    ui.hud({
        me = 0,
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

-- Four stops over the key, in the order they are said: who you are, where you
-- are, what you fly, and the machine.
do
    frame(1440, 810, {open = true})
    local stops = hits_of("menu_stop")
    check("the column carries every stop", #stops == 4, "got " .. #stops)
    local by = {}
    for _, r in ipairs(stops) do by[r.value] = r end
    if by.account and by.zone and by.ship and by.settings then
        check("the account stands at the top",
              by.account.y < by.zone.y and by.zone.y < by.ship.y
              and by.ship.y < by.settings.y)
        local go = hit_of("menu_go")
        check("and furthest from the key",
              go and by.account.y < by.settings.y and by.settings.y < go.y)
    else
        check("the account stands at the top", false, "stops missing")
        check("and furthest from the key", false, "stops missing")
    end
end

-- No stop wears a mark saying it opens. Every one of them opens something, so
-- the mark sorted nothing from anything, and the corner it stood in is the
-- answer's now.
do
    frame(1440, 810, {open = true})
    -- The caret was two strokes drawn near a stop's right edge and it was the
    -- only thing in that corner, so counting strokes there counts carets.
    -- Settings shared the corner with a gauge before that, and was asked for
    -- the caret's two strokes on top of whatever the mark drew; both are gone
    -- and nothing is stroked there now.
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
    check("the settings stop wears no caret", strokes_in("settings") == 0,
          tostring(strokes_in("settings")))
    check("and neither does the account stop", strokes_in("account") == 0,
          tostring(strokes_in("account")))
    check("and no stop here wears one, since every one of them opens",
          strokes_in("zone") == 0, tostring(strokes_in("zone")))
end

-- The column is measured off however many stops it carries rather than off a
-- number written down beside it, so it grows upward out of the key's own
-- strip and nothing already under a thumb moves.
do
    frame(1440, 810, {open = true})
    local go = hit_of("menu_go")
    local stops = hits_of("menu_stop")
    local top = go and go.y or 0
    for _, r in ipairs(stops) do
        if r.y < top then top = r.y end
    end
    check("every stop stands over the key",
          go ~= nil and top < go.y, tostring(top))
    frame(1440, 810)
    local shut = hit_of("open")
    check("and the key comes to rest on the strip the menu key had",
          go and shut and math.abs((go.y + go.h) - (shut.y + shut.h)) < 1,
          go and shut and ((go.y + go.h) .. " against " .. (shut.y + shut.h))
              or "no key")
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

-- --- the account ------------------------------------------------------------

-- Who you are, in a match. This page stood on the front end alone until the
-- menus were unified: signing up three minutes into a game meant leaving it.
do
    frame(1440, 810, {open = true, at = "account"})
    local picks = hits_of("menu_pick")
    check("the account stop opens its acts", #picks == 3, "got " .. #picks)
    local seen = {}
    for _, r in ipairs(picks) do seen[r.value] = true end
    check("and each is its own press", seen[1] and seen[2] and seen[4])
    check("the offer that keeps what a guest is carrying is there",
          said("Sign up") ~= nil)
    check("and the way onto an account that already exists",
          said("Log in") ~= nil)
    check("the stop it hangs off is not drawn under its own list",
          hit_of("menu_stop", "account") == nil)
end

-- --- settings --------------------------------------------------------------

-- The settings panel climbs off its stop, the way the ship panel climbs off
-- the ship stop.
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
          and hit_of("menu_stop", "zone") == nil)
    -- As tall as what it holds, standing on the edge it slid out of. It used
    -- to take the whole window, which is right for a hull's build and absurd
    -- for four rows, so what is checked is that it reaches the foot and stops
    -- short of the top rather than that it fills everything.
    local top, foot = math.huge, 0
    for _, r in ipairs(rows) do
        top = math.min(top, r.y)
        foot = math.max(foot, r.y + r.h)
    end
    check("the panel stands on the foot it slid out of",
          foot > 810 - 90, "last row ends at " .. foot)
    check("and is no taller than the rows it holds",
          top > 120, "panel top " .. top)
end

-- One run of rows and nothing over them. The page came in bands once, a small
-- label and a ticked rule over each run: audio, video, the machine. Six
-- settings do not need chapters, and the headings said what the rows under
-- them already said.
do
    frame(1440, 810, {open = true, at = "settings"})
    check("the panel bands nothing",
          said("AUDIO") == nil and said("VIDEO") == nil
          and said("THE MACHINE") == nil, "a section head is still drawn")
    -- And every row is still on the page, which is the thing a lost band
    -- could have taken with it.
    local rows = hits_of("menu_row")
    check("with every row still on it", #rows == 7, #rows .. " rows")
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
    local left, right = nil, nil
    for _, r in ipairs(rows) do
        left, right = left or r.x, right or (r.x + r.w)
    end
    -- Measured rather than eyeballed: the panel cuts a run at its own edge
    -- rather than wrapping it, so a sentence that would have spilled comes
    -- back from `state.text` shorter than it was written. What this asks is
    -- where the ink ended. The mono's advance is one number for every glyph,
    -- which is what the face this row is set in gives us.
    --
    -- Runs that start inside the panel, since the frame this is measured on is
    -- a whole screen and the arena has mono of its own on it. A sentence that
    -- spills is a sentence that begins on its row and ends past the edge, so
    -- the ones this is about are all in here; what is dropped is the readouts
    -- standing over the dial in a corner the panel does not reach.
    local ADVANCE = 1233 / 2048
    local widest, over = nil, 0
    for i = 1, state.n do
        local t = state.text[i]
        if t.font ~= "menu" and t.s and t.pivot ~= "right"
           and t.pivot ~= "center"
           and left and t.x >= left and t.x <= right then
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
    check("the walk reaches every stop and the key", #walk == 5,
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

-- --- the key says what the press does -------------------------------------
--
-- Three states of one control: no seat, a seat, and a seat with a hull drafted
-- over it. The third names the hull, because naming it is the whole of what
-- the press does, and the longest name in the roster is what says whether a
-- word that long fits the key it is set in. See decision 157.
do
    for _, s in ipairs({{1440, 810, "desktop"}, {390, 844, "portrait"},
                        {320, 480, "small"}}) do
        local w, h, shape = s[1], s[2], s[3]
        frame(w, h, {open = true, key = "play"})
        check(shape .. " offers a seat to a client that holds none",
              said("PLAY") ~= nil and said("SPECTATE") == nil)
        frame(w, h, {open = true, key = "spectate"})
        check(shape .. " offers the stands to a pilot in a seat",
              said("SPECTATE") ~= nil)
        frame(w, h, {open = true, key = "fly", key_ship = "Lattice"})
        local word = said("FLY LATTICE")
        local key = hit_of("menu_go")
        check(shape .. " offers the refit over a drafted hull, named",
              word ~= nil, "no FLY LATTICE on the key")
        -- The longest hull in the roster on the narrowest key. A word set
        -- wider than the box it stands in is a key that reads as broken, and
        -- the roster is where the next long name comes from. The word is set
        -- on the key's middle in the mono, whose advance is one number for
        -- every glyph, so where its ink ends is arithmetic rather than a
        -- guess. Same measure the panel's own overflow check uses.
        if word and key then
            local run = #word.s * word.px * (1233 / 2048)
            check(shape .. " keeps the longest hull inside the key",
                  word.x - run / 2 > key.x
                  and word.x + run / 2 < key.x + key.w,
                  string.format("%.0f of ink at %.0f in a key %.0f wide at %.0f",
                                run, word.x, key.w, key.x))
        end
    end
end

-- --- the way back ----------------------------------------------------------

-- Everybody with a room on screen gets the menu key, which is what dismissing
-- the column has to be paid for with. There was a screen without one, the
-- landing, where the column was up and could not be put away; a faint control
-- offering to open what was already open would have done nothing. The column
-- comes down everywhere now, so the way back is on every screen that has a
-- room behind it. See decision 156.
do
    frame(1440, 810, {watch = {subject = 1}})
    check("a spectator gets the key", hit_of("open") ~= nil)
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
        return said_y("SPECTATE"), said_y("Sound")
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
          and hit_of("menu_stop", "zone") ~= nil)
    ui.panel_shut()
end

-- --- where a page opens standing --------------------------------------------
--
-- A stop sends the column out through the bottom edge and brings its page up
-- through it, so the stop that was pressed is not on the screen any more. The
-- cursor was left on it: the page opened with nothing lit, and an arrow had to
-- be pressed to find the top of a page already being read. It opens on its own
-- head now, which is the row that says which level this is and the way back
-- off it. The landing does the same, one file over.
do
    -- Every rect of this color laid over the box, which is what a lit field
    -- is: the ground goes down first and the wash over it.
    local function lit(b)
        if not b then return false end
        local col = pal.a(pal.FRIEND, ui.LIT.CURSOR)
        for _, r in ipairs(rects) do
            local same = r.col and math.abs(r.col[1] - col[1]) < 0.01
                and math.abs(r.col[2] - col[2]) < 0.01
                and math.abs(r.col[3] - col[3]) < 0.01
                and math.abs(r.col[4] - col[4]) < 0.005
            if same and math.abs(r.x - b.x) < 1
               and math.abs((WIN_H - r.y - r.h) - b.y) < 1
               and math.abs(r.w - b.w) < 1 and math.abs(r.h - b.h) < 1 then
                return true
            end
        end
        return false
    end

    -- Every stop publishes `menu_stop` and tells itself apart by the value on
    -- the box. Lighting on the action alone lit all four at once.
    frame(1440, 810, {open = true, sel = "menu_stop", sel_value = "settings"})
    check("the stop under the cursor lights",
          lit(hit_of("menu_stop", "settings")))
    check("and its neighbors do not",
          not lit(hit_of("menu_stop", "ship"))
          and not lit(hit_of("menu_stop", "account")))

    -- Walked rather than placed, which is how the fault was found: a step off
    -- the key lit every stop at once because they publish one action between
    -- them, and the arrow that lands on one of them is the ordinary way to
    -- get there.
    frame(1440, 810, {open = true, sel = nil})
    ui.col_sel, ui.col_sel_value = "menu_go", nil
    ui.col_step(-1)
    frame(1440, 810, {open = true, keep = true})
    check("a step back off the key lands on the last stop",
          ui.col_sel == "menu_stop" and ui.col_sel_value == "settings",
          tostring(ui.col_sel) .. " " .. tostring(ui.col_sel_value))
    local n = 0
    for _, stop in ipairs({"account", "zone", "ship", "settings"}) do
        if lit(hit_of("menu_stop", stop)) then n = n + 1 end
    end
    check("and lights that one alone", n == 1, n .. " stops lit")

    -- And the head of the page a stop opens, which is where the cursor lands.
    for _, at in ipairs({"settings", "account"}) do
        frame(1440, 810, {open = true, at = at, sel = "menu_back"})
        check("the " .. at .. " page lights its way back",
              lit(hit_of("menu_back")))
    end
end

-- --- the ship, which is the landing's panel in this column ------------------
--
-- One menu for the ship wherever it is read from. The stop opens the same
-- five parts over the same purse the front page opens, drawn by the same
-- function off the same rows, and what differs is only what closing it means.
do
    frame(1440, 810, {open = true, at = "ship"})
    local parts = {}
    for _, r in ipairs(ui.hits) do
        if r.action == "land_sect" then parts[r.value] = r end
    end
    check("the ship stop opens the five parts of a ship",
          parts.body and parts.guns and parts.bombs and parts.specials
          and parts.flair, "got " .. tostring(next(parts)))
    check("with the reset under them", hit_of("land_kit_reset") ~= nil)
    check("and the purse on the frame, where a credit is spent",
          said("BUILD CREDITS") ~= nil)
    check("the way back off it is the column's own",
          hit_of("menu_back") ~= nil and hit_of("land_back") == nil)

    -- The line that says what closing it will do, on the head, so nobody
    -- finds out afterwards that they respawned.
    frame(1440, 810, {open = true, at = "ship",
                      foot = "you respawn in it"})
    check("and the head says what leaving it costs",
          said("respawn") ~= nil)

    -- The walk is the panel's rows and the way back, and nothing behind it:
    -- the stops went out through the bottom edge with the column.
    frame(1440, 810, {open = true, at = "ship", sel = "land_sect",
                      sel_value = "guns"})
    local walk = ui.col_walk()
    local seen = {}
    for _, r in ipairs(walk) do seen[r.action] = true end
    check("the walk is the panel's rows and its head",
          seen.land_sect and seen.menu_back and seen.land_kit_reset
          and not seen.menu_stop, #walk .. " stops")

    -- And left and right step the rows that hold a value, which is how a
    -- build is spent with a pad or a keyboard.
    ui.col_sel, ui.col_sel_value = "land_kit_row", 7
    local act, value = ui.col_side(1)
    check("a slot under the cursor steps with the arrows",
          act == "land_kit_step" and value.slot == 7 and value.dir == 1,
          tostring(act))
    ui.col_sel, ui.col_sel_value = "land_pick_ship", nil
    act, value = ui.col_side(-1)
    check("and the carousel turns with them",
          act == "land_page_ship" and value == -1, tostring(act))
    ui.col_sel, ui.col_sel_value = nil, nil
end

-- --- and the arena is what puts it there ------------------------------------
--
-- `arena.script` is a Defold script and cannot be loaded here, so this pulls
-- the branches out and runs them, which is what landing_test does with the
-- same file for the same reason: a comment is not a check.
do
    local f = assert(io.open("client/arena/arena.script"))
    local src = f:read("*a")
    f:close()

    local cursor = src:match("local function menu_cursor%(stop%)(.-)\nend\n")
    check("the arena has a menu_cursor to run", cursor ~= nil)
    if cursor then
        local ui_stub, menu_stub = {}, {stack = {}}
        local env = {ui = ui_stub, menu = menu_stub,
                     sfx = {ui = function() end},
                     apply_menu = function() end}
        local chunk = loadstring("return function(stop)" .. cursor .. "\nend",
                                 "cursor")
        setfenv(chunk, env)
        env.menu_cursor = chunk()
        menu_stub.stop_open = function() return menu_stub.stack[1] end

        -- The way back off a part of the ship is its own function, shared by
        -- the arrow on the panel's head and by escape, so both branches reach
        -- it and this has to be in scope for either to run.
        local sect_back = src:match(
            "local function ship_sect_back%(%)(.-)\nend\n")
        check("the arena has a ship_sect_back to run", sect_back ~= nil)
        local sb = loadstring(
            "return function()" .. (sect_back or " return false") .. "\nend",
            "sect_back")
        setfenv(sb, env)
        env.ship_sect_back = sb()

        -- And the way back off a pilot's card onto the sheet it stands on,
        -- which is the same kind of step and reached by the same two hands.
        local card_back = src:match(
            "local function board_card_back%(%)(.-)\nend\n")
        check("the arena has a board_card_back to run", card_back ~= nil)
        local cb = loadstring(
            "return function()" .. (card_back or " return false") .. "\nend",
            "card_back")
        setfenv(cb, env)
        env.board_card_back = cb()

        local function branch(pattern)
            local body = src:match(pattern)
            if not body then return nil end
            local c = loadstring(
                "return function(self, action, value)" .. body .. "\nend",
                "branch")
            if not c then return nil end
            setfenv(c, env)
            return c()
        end

        -- A stop, opening its page. The menu it drives is the real one's
        -- shape: a stack that a press pushes a level onto.
        local stop = branch('(\n    if action == "menu_stop" then.-\n    end\n)')
        check("the arena has a branch for the column's stops", stop ~= nil)
        if stop then
            menu_stub.press_stop = function(name)
                menu_stub.stack = {name}
                return nil, true
            end
            ui_stub.col_sel, ui_stub.col_sel_value = "menu_stop", "settings"
            stop(nil, "menu_stop", "settings")
            check("a stop opens its page on the way back",
                  ui_stub.col_sel == "menu_back"
                  and ui_stub.col_sel_value == nil,
                  tostring(ui_stub.col_sel))
            -- And the stop already open shuts instead, which puts the cursor
            -- back on the stop: that is what took the page's place.
            menu_stub.press_stop = function()
                menu_stub.stack = {}
                return nil, true
            end
            stop(nil, "menu_stop", "settings")
            check("while shutting it stands on the stop again",
                  ui_stub.col_sel == "menu_stop"
                  and ui_stub.col_sel_value == "settings",
                  tostring(ui_stub.col_sel) .. " "
                  .. tostring(ui_stub.col_sel_value))
        end

        -- A row of the settings page. One that opens a page of its own is a
        -- stop a level in; one that only sets something leaves the cursor
        -- where the hand left it, or every press would jump to the head.
        local row = branch('(\n    if action == "menu_row" then.-\n    end\n)')
        check("the arena has a branch for a settings row", row ~= nil)
        if row then
            menu_stub.stack = {"settings"}
            menu_stub.press_row = function()
                menu_stub.stack = {"settings", "controls"}
                return nil, true
            end
            ui_stub.col_sel, ui_stub.col_sel_value = "menu_row", 5
            row(nil, "menu_row", 5)
            check("a row that opens a page opens it on the way back",
                  ui_stub.col_sel == "menu_back", tostring(ui_stub.col_sel))
            menu_stub.press_row = function() return nil, true end
            ui_stub.col_sel, ui_stub.col_sel_value = "menu_row", 1
            row(nil, "menu_row", 1)
            check("while a row that only sets something keeps the cursor",
                  ui_stub.col_sel == "menu_row" and ui_stub.col_sel_value == 1,
                  tostring(ui_stub.col_sel))
        end

        -- And the way back off a page's head: onto the head under it where
        -- there is one, and onto the stop itself once the last page is off.
        local back = branch('(\n    if action == "menu_back" then.-\n    end\n)')
        check("the arena has a branch for the way back", back ~= nil)
        if back then
            menu_stub.page_back = function()
                table.remove(menu_stub.stack)
                return true
            end
            menu_stub.stack = {"settings", "controls"}
            ui_stub.col_sel, ui_stub.col_sel_value = "menu_back", nil
            back(nil, "menu_back", nil)
            check("out of a page stands on the head under it",
                  ui_stub.col_sel == "menu_back", tostring(ui_stub.col_sel))
            back(nil, "menu_back", nil)
            check("and out of the last one stands on its stop",
                  ui_stub.col_sel == "menu_stop"
                  and ui_stub.col_sel_value == "settings",
                  tostring(ui_stub.col_sel) .. " "
                  .. tostring(ui_stub.col_sel_value))

            -- The ship stop's levels are the panel's rather than the stack's,
            -- so back steps out of a part of the ship onto the ship menu
            -- before it steps out of the stop, and leaves the cursor on the
            -- part it came out of: what took the panel's place is what lights.
            menu_stub.stack = {"ship"}
            ui_stub.col_sect, ui_stub.col_hull = "guns", nil
            ui_stub.col_sel, ui_stub.col_sel_value = "menu_back", nil
            back(nil, "menu_back", nil)
            check("out of a part of the ship stands on that part",
                  ui_stub.col_sect == nil
                  and ui_stub.col_sel == "land_sect"
                  and ui_stub.col_sel_value == "guns"
                  and menu_stub.stack[1] == "ship",
                  tostring(ui_stub.col_sel) .. " "
                  .. tostring(ui_stub.col_sel_value))
            back(nil, "menu_back", nil)
            check("and only then out of the stop",
                  #menu_stub.stack == 0
                  and ui_stub.col_sel == "menu_stop"
                  and ui_stub.col_sel_value == "ship",
                  tostring(ui_stub.col_sel_value))
        end

        -- The column's one key, which is the arena's own branch pulled out
        -- and run. Which of the three acts a press is, and what a refusal
        -- does with the draft, are the whole of what the key means.
        do
            local go = branch('(\n    if action == "menu_go" then.-\n    end\n)')
            check("the arena has a branch for the column's key", go ~= nil)
            if go then
                local sent, closed, seat_taken, sat_out = {}, 0, 0, 0
                local m = {class = 3, stack = {}}
                m.flying = function() return m.in_seat end
                m.drafted = function() return m.touched end
                m.draft_keep = function() m.touched, m.kept = false, true end
                m.draft_drop = function() m.touched, m.dropped = false, true end
                m.send_build = function(cls) sent[#sent + 1] = cls end
                m.close = function() closed = closed + 1 end
                local was_menu = env.menu
                env.menu = m
                env.net = {sit_out = function() sat_out = sat_out + 1 end}
                env.session = {take_seat = function()
                    seat_taken = seat_taken + 1
                    return true
                end}
                env.full_bar = function(what)
                    if not env.full then
                        m.note = what .. " needs a full bar"
                    end
                    return env.full
                end

                -- Watching: one act. The room owes this client a hull and the
                -- hull it owes is whatever the ship stop names, so a draft
                -- made from the stands is spent by the same press that takes
                -- the seat rather than by a second one.
                m.in_seat, m.touched = false, true
                go(nil, "menu_go", nil)
                check("from the stands the key takes a seat",
                      seat_taken == 1 and sat_out == 0 and #sent == 0,
                      seat_taken .. " seats, " .. #sent .. " builds")

                -- Flying, with a ship drafted over the seat and a bar to pay
                -- for it: one message carrying the hull and the build, and the
                -- menu comes down onto the fight behind it.
                m.in_seat, m.touched, env.full = true, true, true
                go(nil, "menu_go", nil)
                check("a drafted ship is kept and sent on the key",
                      m.kept and sent[1] == 3 and closed == 1
                      and sat_out == 0 and seat_taken == 1,
                      tostring(sent[1]) .. ", closed " .. closed)

                -- And short of a bar it is refused with the draft still
                -- standing. The menu is open beside a key that will work as
                -- soon as the bar fills, which is what settling on the way out
                -- of the panel could never offer: out there the panel had
                -- already gone and the draft went with it.
                sent, closed, env.full = {}, 0, false
                m.in_seat, m.touched, m.kept, m.dropped = true, true, nil, nil
                go(nil, "menu_go", nil)
                check("a refused refit holds the draft rather than dropping it",
                      m.touched and m.kept == nil and m.dropped == nil
                      and #sent == 0 and closed == 0,
                      tostring(m.note))

                -- A seat and nothing pending: the key is the way back to the
                -- stands of the room you are in.
                env.full = true
                m.in_seat, m.touched = true, false
                go(nil, "menu_go", nil)
                check("with nothing drafted the key hands the seat back",
                      sat_out == 1 and #sent == 0 and closed == 1,
                      sat_out .. " sit-outs, closed " .. closed)

                -- Gated the same way, since standing a ship down is the same
                -- act whichever of the two it is.
                env.full = false
                sat_out, closed = 0, 0
                go(nil, "menu_go", nil)
                check("and a part bar refuses that too",
                      sat_out == 0 and closed == 0,
                      sat_out .. " sit-outs, closed " .. closed)

                env.menu = was_menu
            end
        end

        -- A stop opening the ship panel opens it on the ship being flown, at
        -- the top of the menu, the way the landing's ship stop does: a stop
        -- opens where the pilot is rather than where they last read to.
        local stop2 = branch(
            '(\n    if action == "menu_stop" then.-\n    end\n)')
        if stop2 then
            menu_stub.press_stop = function(name)
                menu_stub.stack = {name}
                return nil, true
            end
            ui_stub.col_sect, ui_stub.col_hull = "bombs", 4
            ui_stub.col_scroll = 220
            stop2(nil, "menu_stop", "ship")
            check("the ship stop opens on its own menu",
                  ui_stub.col_sect == nil and ui_stub.col_hull == nil
                  and ui_stub.col_scroll == 0,
                  tostring(ui_stub.col_sect))
        end
    end
end

if fails == 0 then
    print("all good")
else
    print(fails .. " column checks failed")
    os.exit(1)
end
