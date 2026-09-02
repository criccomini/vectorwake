-- Watching: the game, the whole of the HUD a pilot in it gets, and the
-- column over the foot of it.
--
--     lua5.1 client/tests/spectate_test.lua
--
-- Opening the client puts you in the stands of the room you were in last, so
-- a client that has just loaded is a watcher and nothing else. There is no
-- second screen: no landing, no lockup over a column that cannot be put away,
-- no rail it lay down into on a short window, and nothing taken off the HUD
-- because this client has not pressed play yet. What it gets is the five
-- stops, the one key, the radar and the roster, which is what a benched pilot
-- in the same room gets. See decision 158.
--
-- It is one column drawn by one function off one view (decision 143). What is
-- checked here is that column over a room, and the room still being readable
-- behind it.
--
-- These run the real `M.hud` and `M.menu` against a stubbed engine on four
-- windows. The questions are the ones a hand at a mouse would ask: can I
-- press it, is it on the screen, and is the room still readable behind it.

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
for _, name in ipairs({"arc", "flush", "reset",
                       "seg_fade", "seg_flat", "skirt", "tri",
                       "tri_fade", "fan", "seg_glow", "glow_band", "halo",
                       "ring_fade"}) do
    layer[name] = noop
end

-- Rings are kept, because the one instrument out here is made of them: the
-- dial that says a game is being looked for is range rings with a hand
-- sweeping round inside them, and where it lands and how wide it came out is
-- the whole question about it.
local rings = {}
layer.ring = function(self, x, y, r)
    self.n = self.n + 1
    rings[#rings + 1] = {x = x, y = y, r = r}
end

-- Closed runs, corners kept. The other drawing on the carousel is made of
-- nothing else: sitting out draws the badge a seat wears when a person is in
-- it, which is three shapes of hull and six of feather. See decision 135.
local quads = {}
layer.quad = function(self, x1, y1, x2, y2, x3, y3, x4, y4)
    self.n = self.n + 1
    quads[#quads + 1] = {pts = {{x1, y1}, {x2, y2}, {x3, y3}, {x4, y4}},
                         cx = (x1 + x2 + x3 + x4) / 4,
                         cy = (y1 + y2 + y3 + y4) / 4}
end

-- Segments are kept as well, because one drawing out here is made of nothing
-- else: the hull on the body carousel is strokes, and what it is asked is how
-- wide and how tall it came out.
local segs = {}
layer.seg = function(self, x1, y1, x2, y2)
    self.n = self.n + 1
    segs[#segs + 1] = {x1 = x1, y1 = y1, x2 = x2, y2 = y2}
end
layer.outline = function(self, pts)
    self.n = self.n + 1
    for i = 1, #pts - 3, 2 do
        segs[#segs + 1] = {x1 = pts[i], y1 = pts[i + 1],
                           x2 = pts[i + 2], y2 = pts[i + 3]}
    end
end

-- Triangles too, because the carousel's two arrows are drawn as one each and
-- where they sit down the row is the whole question about them.
local tris = {}
layer.tri = function(self, x1, y1, x2, y2, x3, y3)
    self.n = self.n + 1
    tris[#tris + 1] = {x1 = x1, y1 = y1, x2 = x2, y2 = y2, x3 = x3, y3 = y3}
end

-- Frames and rects are kept, because the key is a stroked box over a wash and
-- the question is where the two of them landed. Discs too, for the one mark
-- out here that is a mark rather than a box: the guest dot on the account
-- stop.
local boxes, rects, discs = {}, {}, {}
layer.disc = function(self, x, y, r)
    self.n = self.n + 1
    discs[#discs + 1] = {x = x, y = y, r = r}
end
layer.frame = function(self, x, y, w, h)
    self.n = self.n + 1
    boxes[#boxes + 1] = {x = x, y = y, w = w, h = h}
end
layer.rect = function(self, x, y, w, h, col)
    self.n = self.n + 1
    rects[#rects + 1] = {x = x, y = y, w = w, h = h, col = col}
end

-- The glass layer, which is a second mesh and takes rectangles alone: what
-- goes into it is the boxes the interface wants the scene blurred inside.
local glass = {}
local frosted = {}
glass.reset = function() end
glass.flush = function() end
glass.rect = function(_, x, y, w, h)
    frosted[#frosted + 1] = {x = x, y = y, w = w, h = h}
end

-- Eight seats, four a side, which is what a melee room holds. Seat 0 is the
-- one the channel is pointed at; nobody here is this client, because a watcher
-- has no hull.
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
    ship_kills = function(i) return i end,
    ship_deaths = function(i) return 8 - i end,
    ship_assists = function() return 0 end,
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
    -- One hull for the carousel to turn. `reach` and `mid` are what world.lua
    -- measures off a polygon when it loads, and the drawing wants both.
    HULLS = setmetatable({}, {
        __index = function()
            return {poly = {0, 12, 8, -8, -8, -8}, mid = 2, reach = 12,
                    hot = {1, 0.6, 0.3},
                    lines = {{0, 12, 0, -8}},
                    plates = {{0, 6, 3, 0, -3, 0}},
                    tubes = {{4, 2, 4, -2, 1.4}},
                    canopy = {0, 8, 2, 4, -2, 4}}
        end,
    }),
}

local ui = require("arena.ui")
local pal = require("arena.palette")
local state = package.loaded["arena.state"]

-- --- the harness -----------------------------------------------------------

-- The window the last frame was drawn at. Only the height is read back, to
-- flip filed type into the space hit boxes are published in.
local H

-- The games the zone stop opens, with their one-line formats, as
-- `menu.view()` flattens them: a name said as its owner wrote it, the format
-- under it, and a mark on the one the stands are showing.
local ZONES = {
    {label = "Team Battle", named = true, note = "4v4", mark = true,
     index = 1},
    {label = "Chaos", named = true, note = "1v1", index = 2},
}

-- What the arena hands the column: the five stops with their answers, and
-- whichever page one of them is holding open.
local LAND = {
    name = "deSoto 412",
    zone = "Team Battle",
    ship = "Gunner",
    zones = ZONES,
    -- The ship stop's own menu, as `menu.ship_panel(nil)` builds it: five
    -- parts of a ship over the credits they are bought with, the hull's
    -- flight under the row that names it, and the reset under a rule.
    panel = {
        label = "ship", class = 1, free = 2, credits = 7,
        rows = {
            {kind = "sect", sect = "body", label = "Body", detail = "Wedge",
             raw = true},
                {kind = "sect", sect = "guns", label = "Guns",
             detail = "3 rounds"},
            {kind = "sect", sect = "bombs", label = "Bombs",
             detail = "4 fragments"},
            {kind = "sect", sect = "specials", label = "Specials",
             detail = "1 repel"},
            {kind = "sect", sect = "flair", label = "Flair",
             detail = "standard wake"},
            {kind = "rule"},
            {kind = "reset", label = "Reset", on = true},
        },
    },
    -- A guest's account page, as `menu.account_rows` builds it and
    -- `menu.view` flattens it: the offer with what it buys, the reroll, a
    -- rule, and the way onto an account that already exists.
    account = {
        {label = "sign up", offer = true, note = "keep your points",
         index = 1},
        {label = "new name", index = 2},
        {rule = true, index = 3},
        {label = "log in", index = 4},
    },
}

-- One section of that menu, as `menu.ship_panel("guns")` builds it: the same
-- purse, and the slots this hull can reach with its gun.
local GUNS = {
    label = "guns", class = 1, free = 2, credits = 7,
    rows = {
        {kind = "slot", slot = 5, label = "Level", value = 0, cap = 2,
         base = 1, can_up = true, can_down = false},
        {kind = "slot", slot = 7, label = "Spray", value = 2, cap = 5,
         can_up = true, can_down = true},
        {kind = "slot", slot = 8, label = "Bounce", value = 0, cap = 1,
         toggle = true, can_up = true, can_down = false},
    },
}

-- And the body section, which is one ship turning with its flight read out
-- underneath and an arrow either side of the drawing.
local BODY = {
    label = "body", class = 1, free = 2, credits = 7,
    rows = {
        {kind = "art", label = "Wedge", value = 1, cls = 1, at = 1, pages = 7},
        {kind = "stat", label = "speed", share = 0.2},
        {kind = "stat", label = "thrust", share = 0.14},
        {kind = "stat", label = "turn", share = 0.09},
        {kind = "stat", label = "energy", share = 0.71},
        {kind = "stat", label = "recharge", share = 0.0},
    },
}

-- The flair section: the two rows that are a ship's and cost nothing.
local FLAIR = {
    label = "flair", class = 1, free = 2, credits = 7,
    rows = {
        {kind = "flair", index = 1, label = "wake", detail = "standard",
         choice = 1, choices = 3},
        {kind = "flair", index = 2, label = "charge keys",
         detail = "repel first", choice = 1, choices = 2},
    },
}

-- The same view with one of those sections open over its menu.
local function land_in(sect)
    local out = {}
    for k, v in pairs(LAND) do out[k] = v end
    out.panel = sect
    return out
end

-- The column as the arena hands it over: four stops, whichever one is open,
-- and the rows or the panel behind it. `menu.view()` builds this for real off
-- `menu.stops()`; here the answers come from the fixture so the layout checks
-- have names of known length to measure.
local function view(land, o)
    local open = o.col_open
    local rows = {}
    if open == "zone" then rows = land.zones or {}
    elseif open == "account" then rows = land.account or {} end
    return {
        open = true, key = o.key or "play",
        pilot = {name = land.name},
        stops = {
            {stop = "account", label = "account", value = land.name,
             named = true, warn = land.warn, open = open == "account"},
            {stop = "zone", label = "zone", value = land.zone, named = true,
             open = open == "zone"},
            {stop = "players", label = "players", value = "watching",
             open = open == "players"},
            {stop = "ship", label = "ship", value = land.ship, named = true,
             open = open == "ship"},
            {stop = "settings", label = "settings",
             open = open == "settings"},
        },
        rows = rows,
        panel = open == "ship" and land.panel or nil,
        foot = open == "ship" and o.foot or nil,
    }
end

-- One frame of the watcher's screen, with the column over it unless
-- `o.column` is false, which is what dismissing it leaves.
local function frame(w, h, o)
    o = o or {}
    H = h
    boxes, rects, discs = {}, {}, {}
    rings = {}
    quads = {}
    frosted = {}
    state.n = 0
    -- The scoreboard is off unless a check asks for it, the way it is off
    -- until a player presses PLAYERS.
    ui.details = o.details or false
    -- And where the cursor is standing, which both hands write: the pointer
    -- through `land_hover` in arena.script, the arrows through `col_step`.
    -- `keep` is for the checks that walk it and then look at what was drawn.
    if not o.keep then
        ui.col_sel, ui.col_sel_value = o.sel, o.sel_value
    end
    -- Time zero settles the panel's slide in the frame it starts, which is
    -- what keeps every layout check here still. `now` is for the one section
    -- that is about the slide itself and needs a middle to look at.
    ui.begin(layer, w, h, o.density or 1, false, o.now or 0, glass)
    ui.hud({
        me = 0,
        -- A watcher's HUD: the camera stands behind a hull that is not yours.
        watch = {subject = 0},
        panel = o.col_open ~= nil,
        side = 0,
        viewer_name = "you",
        -- The arena hands the HUD `menu.open or ui.column_up()`, so a frame
        -- that draws the column says so: what it takes down is the foot key
        -- the column is standing on, and the two big centered blocks.
        menu_open = o.menu_open or o.column ~= false,
        pilots = SEATS,
        watchers = {},
        teams = {},
        match = o.match or {playing = true, left = 107,
                            score = {[0] = 3, [1] = 5}},
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
    -- And the column over it, which the arena draws after the HUD because the
    -- ending washes the whole window and a key laid down first would spend
    -- the twenty five seconds between matches buried under it.
    if o.column ~= false then ui.menu(view(o.land or LAND, o)) end
    ui.finish()
end

-- One stop of the column, by name. Every stop publishes the same action and
-- is told from the next by the value it carries, which is what the arena
-- hands back to `menu.press_stop`.
local function stop(name)
    for _, r in ipairs(ui.hits) do
        if r.action == "menu_stop" and r.value == name then return r end
    end
    return nil
end

local function box(action)
    for _, r in ipairs(ui.hits) do
        if r.action == action then return r end
    end
    return nil
end

local function words()
    local out = {}
    for i = 1, state.n do out[#out + 1] = state.text[i] end
    return out
end

-- Type is filed for the gui, which counts up from the bottom, and hit boxes
-- are published in the interface's own space, which counts down from the top.
-- Everything here compares the two, so words come back in the boxes' space.
local function word(s)
    for _, t in ipairs(words()) do
        if t.s == s then
            return {s = t.s, x = t.x, y = H - t.y, px = t.px}
        end
    end
    return nil
end

-- Whether the scene was blurred inside a published box. The glass is drawn
-- into a mesh, which counts up from the bottom, and a hit box is published in
-- the interface's own space, which counts down from the top, so the two are
-- compared the way `word` compares type: by flipping one of them.
local function glazed(b)
    for _, g in ipairs(frosted) do
        if math.abs(g.x - b.x) < 1 and math.abs(g.w - b.w) < 1
           and math.abs(g.h - b.h) < 1
           and math.abs((H - (g.y + g.h)) - b.y) < 1 then
            return true
        end
    end
    return false
end

-- What a press at this point reaches, through the same rule `on_input` uses.
-- The value comes back with it, because every stop of the column publishes one
-- action and is told from the next by what it carries.
local function press(x, y)
    local r = ui.pick(x, y)
    if r then return r.action, r.value end
    return nil
end

-- --- every window carries the key and the stops ----------------------------

-- Desktop, a phone on its side, a phone held upright, and the shortest screen
-- the interface claims to support. One layout on all four: the stops stacked
-- over the key at the key's own width, rising out of the strip the menu key
-- sits in.
--
-- There were two. A short window could not hold a lockup over five stops and
-- keep off the hull in the middle of the screen, so the same pieces lay down
-- into a rail along the foot. Both the lockup and the rule about the middle
-- belonged to the landing: the column is a scrim over a fight that does not
-- pause now, wherever it is raised, and it is the same scrim a pilot in the
-- room raises over the same middle. See decision 158.
local SHAPES = {
    {1440, 810, "desktop"},
    {844, 390, "sideways"},
    {390, 844, "portrait"},
    {320, 480, "small"},
}

for _, s in ipairs(SHAPES) do
    local w, h, shape = s[1], s[2], s[3]
    frame(w, h)
    local key = box("menu_go")
    check(shape .. " publishes one key to press",
          key ~= nil, "no key box")
    if key then
        check(shape .. " keeps the key on the screen",
              key.x >= 0 and key.y >= 0
              and key.x + key.w <= w and key.y + key.h <= h,
              string.format("%.0f,%.0f %.0fx%.0f in %dx%d",
                            key.x, key.y, key.w, key.h, w, h))
        -- A thumb's worth. Anything smaller is a control a phone cannot hit.
        check(shape .. " gives the key a thumb to land on",
              key.h >= 44, string.format("%.0f tall", key.h))
        check(shape .. " presses the key where it is drawn",
              press(key.x + key.w / 2, key.y + key.h / 2) == "menu_go")
    end
    -- The five stops, in the order you would say them: who you are, where you
    -- are going, who else is here, what you fly, and the machine you are on.
    local acct, zone, who, ship, mach = stop("account"), stop("zone"),
        stop("players"), stop("ship"), stop("settings")
    check(shape .. " publishes the five stops",
          acct ~= nil and zone ~= nil and who ~= nil and ship ~= nil
          and mach ~= nil, "a stop is missing")
    local cells = {acct, zone, who, ship, mach}
    if key and acct and zone and who and ship and mach then
        check(shape .. " stacks the stops over the key in saying order",
              acct.y < zone.y and zone.y < who.y and who.y < ship.y
              and ship.y < mach.y and mach.y + mach.h <= key.y + 1,
              string.format("account %.0f zone %.0f players %.0f ship %.0f "
                            .. "settings %.0f key %.0f",
                            acct.y, zone.y, who.y, ship.y, mach.y, key.y))
        for _, b in ipairs(cells) do
            check(shape .. " gives a stop the key's own width",
                  math.abs(b.w - key.w) < 1 and math.abs(b.x - key.x) < 1,
                  string.format("%.0f wide at %.0f against %.0f at %.0f",
                                b.w, b.x, key.w, key.x))
        end
        check(shape .. " centers the key",
              math.abs((key.x + key.w / 2) - w / 2) < 1,
              string.format("middle at %.0f of %d", key.x + key.w / 2, w))
        -- And the whole column stands on the screen. It is taller than the
        -- landing's four ever were, and the shortest window the interface
        -- claims is what says whether five fit.
        check(shape .. " keeps the whole column on the screen",
              acct.y >= 0, string.format("top stop at %.0f", acct.y))
        local hit_act, hit_val =
            press(zone.x + zone.w / 2, zone.y + zone.h / 2)
        check(shape .. " presses a stop where it is drawn",
              hit_act == "menu_stop" and hit_val == "zone",
              tostring(hit_act) .. "/" .. tostring(hit_val))
    end
    -- The stops say their answers, and every one of them is a name: a call
    -- sign, a game's, a build's. The HUD shouts, because an instrument read
    -- out of the corner of an eye is labeled in capitals, and a name is not a
    -- label. DRiFT is not DRIFT and deSoto is neither DESOTO nor DeSoto, so
    -- these three are quoted rather than set. See `txt`.
    check(shape .. " says who you are", word("deSoto 412") ~= nil,
          "no call sign as written")
    check(shape .. " does not shout a call sign", word("DESOTO 412") == nil)
    check(shape .. " says where you are going", word("Team Battle") ~= nil,
          "no game name as written")
    check(shape .. " does not shout a game's name",
          word("TEAM BATTLE") == nil)
    check(shape .. " says what you arrive as", word("Gunner") ~= nil,
          "no build name as written")
    check(shape .. " does not shout a build's name", word("GUNNER") == nil)

    -- And it says the whole of it. The names in these cells are the
    -- catalog's, so the one that does not fit is the next zone somebody adds.
    local LONG = "Capture the Flag"
    local was = LAND.zone
    LAND.zone = LONG
    frame(w, h)
    check(shape .. " says a long game's name without cutting it",
          word(LONG) ~= nil, "no whole name in the cell")
    LAND.zone = was
end

-- --- the name heads the column ----------------------------------------------
--
-- The lockup stands over the column and goes when a stop opens, because the
-- column is one object and a name left hanging over an open panel is the menu
-- refusing to get out of the way. It comes back when the panel does, and it
-- goes with the column when the column is dismissed: the name belongs to the
-- menu rather than to the screen. See decision 160.
do
    for _, s in ipairs(SHAPES) do
        local w, h, shape = s[1], s[2], s[3]
        frame(w, h)
        local name = word("vectorwake")
        local top = stop("account")
        check(shape .. " heads the column with the name", name ~= nil,
              "no wordmark over the stops")
        if name and top then
            check(shape .. " sets it clear above the top stop",
                  name.y < top.y and name.y + name.px / 2 < top.y,
                  string.format("name at %.0f, top stop at %.0f",
                                name.y, top.y))
            check(shape .. " and keeps the whole of it on the screen",
                  name.y - name.px / 2 > 0,
                  string.format("reaches %.0f", name.y - name.px / 2))
            check(shape .. " and centers it on the column's own middle",
                  math.abs(name.x - (top.x + top.w / 2)) < top.w / 2,
                  string.format("name at %.0f, column middle %.0f",
                                name.x, top.x + top.w / 2))
        end
        -- A stop opens and the name goes out through the bottom edge with the
        -- stops it heads.
        frame(w, h, {col_open = "zone"})
        check(shape .. " takes it down under an open panel",
              word("vectorwake") == nil, "the name is still over the panel")
        -- And it is back on the bare column.
        frame(w, h)
        check(shape .. " and puts it back when the panel goes",
              word("vectorwake") ~= nil)
        -- And gone with the column when the column is dismissed.
        frame(w, h, {column = false})
        check(shape .. " and goes with the column",
              word("vectorwake") == nil, "the name outlived the menu")
    end
end

-- --- the rest of the HUD is the rest of the screen --------------------------

frame(1440, 810)
check("a watcher reads the room's own clock", word("1:47") ~= nil)
check("and both sides of the score",
      word("3") ~= nil and word("5") ~= nil)
check("and names the sides", word("PYLON") ~= nil and word("CAISSON") ~= nil)
-- And says nothing about being a watcher. A green play mark and the word
-- CHANNEL sat in the corner row: a label on the obvious, since no hull on
-- screen wears this client's call sign.
check("and says nothing about the channel it is watching",
      word("CHANNEL") == nil)
-- The roster the band opens, the radar in its corner and the way back into
-- the menu are all here. They were the three things the landing took off a
-- watcher, on the reading that the room behind the front page was somebody
-- else's; what that produced was a stranger looking at fourteen people with
-- no way to see who any of them were, and a fight with no way to tell where
-- in the map it was happening. See decision 158.
-- With the column down, which is what dismissing it leaves: an ordinary
-- watcher's screen, and every instrument on it takes a press.
frame(1440, 810, {column = false})
check("and a way into the roster", box("players_open") ~= nil)
check("and a radar over the fight", box("map") ~= nil)
-- The strip the feed hangs under is measured off the corner's own extent, so
-- the square being there is what puts it a hundred and forty points down.
check("and a feed that starts under the radar rather than at the row",
      ui.radar_span() > 168, string.format("%.0f", ui.radar_span()))
-- The column standing over them takes the presses down and leaves the
-- readings: a control that opened what is already open would be a press with
-- nothing on screen answering it, and the instruments are what say you can
-- still be shot while you read. See `F.menu_up`.
frame(1440, 810)
check("and the column takes the presses down without taking the readings",
      box("map") == nil and box("players_open") == nil
      and ui.radar_span() > 168, string.format("%.0f", ui.radar_span()))
-- The whistle is the same roster arriving by another door, and it arrives:
-- the ending is the board with a head over it, and a watcher reads the
-- account of the match they have been watching.
local ENDED = {playing = false, left = 0, artifact = 1,
               score = {[0] = 3, [1] = 5}}
frame(1440, 810, {column = false, match = ENDED})
check("and a result on the band at the whistle",
      word("PYLON") ~= nil and word("CAISSON") ~= nil)
frame(1440, 810)

-- --- and the way back into the menu -----------------------------------------
--
-- The menu key is on this screen, on every window, because the column can be
-- put away on every window. There was a screen where it was not: the landing's
-- column was up and could not be dismissed, so a faint control offering to
-- open it would have done nothing. It comes down now, so the way back has to
-- be there.
--
-- The key itself, its word and its shape are column_test's. What is checked
-- here is that the column standing over it does not take it away, and that it
-- comes back when the column goes.
do
    for _, s in ipairs(SHAPES) do
        local w, h, shape = s[1], s[2], s[3]
        frame(w, h, {column = false})
        check(shape .. " offers the way into the menu", box("open") ~= nil,
              "no key with the column down")
        check(shape .. " says MENU", word("MENU") ~= nil)
        -- And the column comes up out of that key's own strip, so the two
        -- occupy one place rather than stacking a faint control under a lit
        -- one.
        frame(w, h)
        local play = box("menu_go")
        check(shape .. " stands the key on the bottom margin",
              play ~= nil and play.y + play.h > h - 34,
              play and string.format("key ends %.0f of %d",
                                     play.y + play.h, h)
                  or "no key box")
    end
end

-- No chip offering the seat a second time. The corner is empty: the way into a
-- hull is the column's key, and the ship stop is where the hull is picked. See
-- decision 156.
frame(1440, 810)
check("a watcher is offered no seat in the corner", box("take_seat") == nil)

-- --- what a stop lets through ----------------------------------------------
--
-- A stop dims the room behind it and blurs it. Dimming alone left the rock
-- that happened to be passing behind ACCOUNT sharp and legible, competing with
-- the word it was holding; a pane of glass passes the light and not the
-- picture. What is pinned here is that the blur lands in exactly the box the
-- press does, on both layouts, and that nothing pays for it in a fight: the
-- render script draws the frame into a texture only for as long as something
-- is asking to be read through.
do
    for _, s in ipairs(SHAPES) do
        local w, h, shape = s[1], s[2], s[3]
        frame(w, h)
        for _, name in ipairs({"account", "zone", "players", "ship",
                               "settings"}) do
            local b = stop(name)
            check(shape .. " frosts the " .. name .. " stop",
                  b ~= nil and glazed(b),
                  b and string.format("%.0f,%.0f %.0fx%.0f is not glass",
                                      b.x, b.y, b.w, b.h) or "no box")
        end
        local b = box("menu_go")
        check(shape .. " frosts the key",
              b ~= nil and glazed(b),
              b and string.format("%.0f,%.0f %.0fx%.0f is not glass",
                                  b.x, b.y, b.w, b.h) or "no box")
    end
    -- With the column down there is no glass: the HUD's own instruments are
    -- read against the fight rather than through it.
    frame(1440, 810, {column = false})
    check("a bare HUD asks for no glass at all", #frosted == 0,
          #frosted .. " frosted boxes with the column down")
end

-- --- a stop opens a panel over the glass -------------------------------------
--
-- A stop's press slides a panel up through the bottom edge and sends the
-- column out through the same edge. The panel is the window less its margin,
-- capped so a monitor does not get a row the width of the screen; its head
-- names the stop and carries the way back; a row's press beats the glass
-- behind it, and the margin beside the glass puts the panel away.
do
    frame(1440, 810, {col_open = "zone"})
    local pick
    for _, r in ipairs(ui.hits) do
        if r.action == "menu_pick" and r.value == 2 then
            pick = r
        end
    end
    check("the zone list offers the other game", pick ~= nil,
          "no row for the second zone")
    check("and says its name", word("Chaos") ~= nil)
    -- The format is the interface describing the game rather than naming it,
    -- so it is set the way the rest of the HUD is set.
    -- In the menu's voice rather than the HUD's. A panel is read rather than
    -- glanced at, so its rows speak the way every other row in the game does:
    -- the catalog's own words, not shouted back at the reader.
    check("and its format beside it", word("1v1") ~= nil,
          "the format is not in the menu's voice")
    -- The head says which stop you are in, in the same register the stop said
    -- it in, and takes the press that steps back out of it.
    check("the panel names the stop it came from", word("ZONE") ~= nil)
    check("and carries the way back", box("menu_back") ~= nil)
    if pick then
        check("a press on the row is the pick",
              press(pick.x + 5, pick.y + pick.h / 2) == "menu_pick")
        -- The column went with the panel's arrival, so there is nothing of it
        -- left to press: the panel is the screen while it stands.
        check("the key went out with the column", box("menu_go") == nil)
        check("and so did the stops", stop("zone") == nil
              and stop("account") == nil and stop("ship") == nil)
        -- The glass swallows a press that missed a row, so a thumb landing
        -- between two rows does not dismiss the thing it was aiming at.
        local hold = box("panel_hold")
        check("the glass takes a press that missed a row", hold ~= nil)
        if hold then
            check("and that press is not a dismissal",
                  press(hold.x + hold.w / 2, hold.y + hold.h - 4)
                      == "panel_hold",
                  "landed on " .. tostring(
                      press(hold.x + hold.w / 2, hold.y + hold.h - 4)))
        end
        -- And the margin beside it still is one.
        check("the margin beside the glass puts the panel away",
              press(4, 300) == "menu_shut",
              "landed on " .. tostring(press(4, 300)))
    end

    -- The cap: wider than the stop it came from and well short of the window,
    -- centered on the same middle the column stands on.
    frame(1440, 810, {})
    local from = stop("zone")
    frame(1440, 810, {col_open = "zone"})
    local row = nil
    for _, r in ipairs(ui.hits) do
        if r.action == "menu_pick" then row = row or r end
    end
    check("the panel is wider than the stop it came from",
          from and row and row.w > from.w,
          from and row and (from.w .. " against " .. row.w) or "missing")
    check("and capped well short of a wide window",
          row and row.w <= 560 and row.w < 1440 * 0.5,
          row and tostring(row.w) or "missing")
    check("and centered on the column's own middle",
          from and row
          and math.abs((from.x + from.w / 2) - (row.x + row.w / 2)) < 2)
    -- On a phone the cap never binds: the panel is the window less its margin,
    -- which is what "the whole screen" means where there is no width to spare.
    frame(390, 844, {col_open = "zone"})
    local narrow = nil
    for _, r in ipairs(ui.hits) do
        if r.action == "menu_pick" then narrow = narrow or r end
    end
    check("and takes the whole width of a phone", narrow and narrow.w > 340,
          narrow and tostring(narrow.w) or "missing")
    frame(1440, 810, {col_open = "zone"})

    frame(1440, 810, {col_open = "ship"})
    -- Five parts of a ship, each a row that opens the part it names, and the
    -- reset under them. The hull is what body reads rather than a head of its
    -- own.
    check("the ship menu names the five parts",
          word("Body") ~= nil and word("Guns") ~= nil and word("Bombs") ~= nil
          and word("Specials") ~= nil and word("Flair") ~= nil)
    check("and reads the hull off the row that opens it",
          word("Wedge") ~= nil and word("Reset") ~= nil)
    -- The purse is drawn by the frame rather than by the rows, which is what
    -- keeps it on screen at every level.
    check("with the credits over all of it", word("BUILD CREDITS") ~= nil)
    -- Every section takes a press, from a pointer as from a pad.
    local opens = {}
    for _, r in ipairs(ui.hits) do
        if r.action == "land_sect" then opens[r.value] = true end
    end
    check("and each part opens", opens.body and opens.guns and opens.bombs
          and opens.specials and opens.flair)

    -- Inside one: the slots, and the same tray over them.
    frame(1440, 810, {land = land_in(GUNS), col_open = "ship"})
    check("a section carries the rows that spend credits",
          word("Spray") ~= nil and word("Level") ~= nil)
    check("and the same purse over them", word("BUILD CREDITS") ~= nil)
    -- A step publishes the slot and the direction, which is the whole of
    -- what spending a credit is.
    local step
    for _, r in ipairs(ui.hits) do
        if r.action == "land_kit_step" and type(r.value) == "table"
           and r.value.slot == 7 and r.value.dir == 1 then
            step = r
        end
    end
    check("and a credit can be spent on a row", step ~= nil)
    -- And a step that cannot happen still takes the press. The arrow is drawn
    -- either way, so leaving it out of the hit boxes made an empty purse look
    -- like a control that had stopped working: the press went through the
    -- glass and nothing at all happened. It is answered now. See `spend`.
    local dim
    for _, r in ipairs(ui.hits) do
        if r.action == "land_kit_step" and type(r.value) == "table"
           and r.value.slot == 5 and r.value.dir == -1 then
            dim = r
        end
    end
    check("and an arrow drawn dim is one a press still lands on", dim ~= nil)
    -- A switch is the one that does not, because it holds one of two answers
    -- and its box always means the other one.
    local down_off
    for _, r in ipairs(ui.hits) do
        if r.action == "land_kit_step" and type(r.value) == "table"
           and r.value.slot == 8 and r.value.dir == -1 then
            down_off = r
        end
    end
    check("and a switch that is already off cannot be turned off",
          down_off == nil)

    -- Body is one ship, turning, with an arrow either side of the drawing
    -- and its flight read out underneath. The arrows are the whole control:
    -- what a pilot turns to is what they fly, so the drawing itself only
    -- anchors a cursor.
    frame(1440, 810, {land = land_in(BODY), col_open = "ship"})
    local fly, turns = nil, {}
    for _, r in ipairs(ui.hits) do
        if r.action == "land_pick_ship" then fly = r end
        if r.action == "land_page_ship" then turns[r.value] = r end
    end
    -- The anchor carries no hull on it. The carousel is one control whatever
    -- it is turned to, and a box that answered for the hull it was showing
    -- moved out from under the cursor on every step of the arrows.
    check("body turns one ship, an arrow either side of it",
          fly ~= nil and fly.value == nil and turns[-1] and turns[1],
          tostring(fly and fly.value))
    -- And the arrow's press actually lands on it. `M.pick` keeps the first
    -- box of the highest priority, and the glass publishes `panel_hold`
    -- before any row draws, so a control sharing that priority is one the
    -- panel swallows. The roster's own press was at that priority from the
    -- walker onward: the box was published, every check here said so, and
    -- pressing it did nothing. Asking what a press resolves to is the only
    -- question that catches it.
    if turns[1] then
        local t = turns[1]
        check("and a press on an arrow turns the carousel",
              press(t.x + t.w / 2, t.y + t.h / 2) == "land_page_ship",
              tostring(press(t.x + t.w / 2, t.y + t.h / 2)))
    end
    -- The drawing is not a control. It is where a hand stands so that left
    -- and right can turn, the job `land_kit_row` does for a count, so it is
    -- published under the glass and a press on it is the glass's. Drawing a
    -- box a finger lands on and nothing answers is the failure worth naming:
    -- a press on the ship has to reach the panel, not stop somewhere silent.
    if fly then
        check("and the ship itself is a rest, not a press",
              press(fly.x + fly.w / 2, fly.y + fly.h / 2) == "panel_hold",
              tostring(press(fly.x + fly.w / 2, fly.y + fly.h / 2)))
    end
    -- Every section row is a press too, and the same glass sits under them.
    frame(1440, 810, {col_open = "ship"})
    local sect
    for _, r in ipairs(ui.hits) do
        if r.action == "land_sect" and r.value == "guns" then sect = r end
    end
    check("and a press on a part of the ship opens it",
          sect ~= nil and press(sect.x + sect.w / 2,
                                sect.y + sect.h / 2) == "land_sect",
          tostring(sect and press(sect.x + sect.w / 2, sect.y + sect.h / 2)))
    frame(1440, 810, {land = land_in(BODY), col_open = "ship"})
    check("and says the five flight rows under it",
          word("SPEED") ~= nil and word("RECHARGE") ~= nil)
    -- The arrows stand either side of the carousel and level with the middle
    -- of it. The row is a ship over its name and the two turn together, so
    -- the mark that turns them belongs beside the pair rather than beside the
    -- drawing alone: level with the ship it sat in the top third of the row
    -- with the centre line empty between the two of them.
    --
    -- Asked of the mark rather than of the box it publishes. A box centred on
    -- its own mark says nothing about where either one is, and both were
    -- centred on each other before this as well.
    if turns[-1] and turns[1] then
        local l, r2 = turns[-1], turns[1]
        local art
        for _, h in ipairs(ui.hits) do
            if h.action == "land_pick_ship" then art = h end
        end
        -- The one triangle standing inside the box, in both directions.
        -- The frame behind the panel is full of them, the dial and the marks
        -- over the fight among them, and an x range alone catches those.
        local function mark(within)
            local found = nil
            for _, t in ipairs(tris) do
                local lo = math.min(t.x1, t.x2, t.x3)
                local hi = math.max(t.x1, t.x2, t.x3)
                -- Back into the space the boxes are in, since the layer takes
                -- y down from the top of the window.
                local ys = {H - t.y1, H - t.y2, H - t.y3}
                local ylo = math.min(ys[1], ys[2], ys[3])
                local yhi = math.max(ys[1], ys[2], ys[3])
                if lo >= within.x and hi <= within.x + within.w
                    and ylo >= within.y and yhi <= within.y + within.h then
                    found = (ys[1] + ys[2] + ys[3]) / 3
                end
            end
            return found
        end
        local ly, ry2 = mark(l), mark(r2)
        check("with the two arrows level with each other",
              ly and ry2 and math.abs(ly - ry2) < 1,
              tostring(ly) .. " / " .. tostring(ry2))
        check("one either side of the drawing",
              l.x < art.x and r2.x + r2.w > art.x + art.w)
        check("and level with the middle of the row, not the ship in it",
              ly and math.abs(ly - (art.y + art.h / 2)) < 1,
              tostring(ly) .. " against " .. tostring(art.y + art.h / 2))
    end

    -- The ship turns about the axis running up the screen, which is the bank
    -- the renderer already has: local x by the cosine of the angle, and the
    -- length untouched. A quarter of the way round it is edge-on and no
    -- shorter. Drawn in the plane of the screen instead, which is what this
    -- was first, the width and the height would trade places and neither
    -- would hold still.
    local function art_box(now)
        segs = {}
        frame(1440, 810, {land = land_in(BODY), col_open = "ship", now = now})
        local x0, x1, y0, y1 = math.huge, -math.huge, math.huge, -math.huge
        for _, q in ipairs(segs) do
            -- Only the hull. The panel's rules run the full width of the
            -- glass and the arrows are triangles, so a stroke inside the
            -- drawing's own half of the panel is the drawing.
            if math.abs(q.x1 - 700) < 120 and math.abs(q.x2 - 700) < 120 then
                x0 = math.min(x0, q.x1, q.x2)
                x1 = math.max(x1, q.x1, q.x2)
                y0 = math.min(y0, q.y1, q.y2)
                y1 = math.max(y1, q.y1, q.y2)
            end
        end
        return x1 - x0, y1 - y0
    end
    -- A quarter of eleven seconds, which is where the cosine is nought.
    local w0, h0 = art_box(0)
    local w1, h1 = art_box(11 / 4)
    check("the ship turns about the axis up the screen",
          w1 < w0 * 0.2 and math.abs(h1 - h0) < 2,
          string.format("%.0fx%.0f then %.0fx%.0f", w0, h0, w1, h1))
    frame(1440, 810, {land = land_in(BODY), col_open = "ship"})

    -- And it stands in a row of the panel's own, which is 44 points on a
    -- window this size. The drawing carried a radius written down beside it
    -- for as long as it existed, so it was sized against nothing and came out
    -- taller than the five bars it is read against put together.
    check("the drawing stands in one row of the panel's own",
          h0 > 12 and h0 <= 44, string.format("%.0f tall", h0))

    -- And the whole section still opens on a phone, which is the property
    -- the height is spent on. The panel draws whole rows only, so a row that
    -- does not fit is not drawn at all rather than cut: a section that grows
    -- past the glass loses its last rows outright, and the bars are the thing
    -- a pilot is choosing by.
    frame(390, 844, {land = land_in(BODY), col_open = "ship"})
    local missing = nil
    for _, w in ipairs({"SPEED", "THRUST", "TURN", "ENERGY", "RECHARGE"}) do
        if word(w) == nil then missing = w end
    end
    check("and a phone still opens the section on all five flight rows",
          missing == nil and word("Wedge") ~= nil, tostring(missing))
    frame(1440, 810, {land = land_in(BODY), col_open = "ship"})

    -- Flair is the two rows that cost nothing, and they take a press.
    frame(1440, 810, {land = land_in(FLAIR), col_open = "ship"})
    local flair
    for _, r in ipairs(ui.hits) do
        if r.action == "land_flair" and r.value == 1 then flair = r end
    end
    check("flair carries the wake and takes a press",
          word("Wake") ~= nil and flair ~= nil)
    frame(1440, 810, {col_open = "ship"})
end

-- --- a game with no arena is still being looked for --------------------------
--
-- A zone the fleet is not serving is a row, not a gap: a player is better off
-- seeing that Capture the Flag exists and is down than wondering whether they
-- misread the list. Two things are true of that row and it says both. It
-- cannot be pressed, which is what dims it and what keeps a box off it. And
-- something is still looking for it, which is the dial at the right end: the
-- directory is asked again every three seconds and an arena can come back at
-- any of them, so a row that simply sat there dim would be the client saying
-- it had given up when it has not.
--
-- What the row reads is read either way. The format of a game is what the
-- game is, and it is true whether or not anybody is running one.
do
    local DOWN = {}
    for k, v in pairs(LAND) do DOWN[k] = v end
    -- The two formats are written differently on purpose: the one below
    -- asks whether the dead row still reads, and a string both rows carried
    -- would come back from the live one.
    DOWN.zones = {
        {label = "Team Battle", named = true, note = "4v4 \194\183 3:00",
         mark = true, index = 1},
        {label = "Capture the Flag", named = true, note = "4v4", dim = true,
         waiting = true, index = 2},
    }

    frame(1440, 810, {land = DOWN, col_open = "zone"})
    check("a game nobody is serving is still on the list",
          word("Capture the Flag") ~= nil)
    local pressable = {}
    for _, r in ipairs(ui.hits) do
        if r.action == "menu_pick" then pressable[r.value] = true end
    end
    check("and the row for it takes no press",
          pressable[1] and not pressable[2],
          "the dead game published a box")
    -- Two range rings at this size, a hand and its trail inside them. Three
    -- rings across twenty two points would be five apart, which is closer
    -- than the stroke drawing them, so the small dial keeps two.
    check("and wears the dial that is looking for one", #rings == 2,
          #rings .. " rings on screen, wanted 2")
    local row = nil
    for _, r in ipairs(ui.hits) do
        if r.action == "menu_pick" and r.value == 1 then row = r end
    end
    if row and #rings == 2 then
        -- Rows are one height, so the dead one is the row under the live one:
        -- the box the live row published, moved down by its own height. Hit
        -- boxes count down from the top of the window and the mesh counts up
        -- from the bottom of it, so the dial's own y is flipped to meet them.
        local want = row.y + row.h
        local cy = 810 - rings[1].y
        local widest = 0
        for _, g in ipairs(rings) do widest = math.max(widest, g.r) end
        check("standing in the row it belongs to",
              cy > want and cy < want + row.h,
              string.format("%.0f against %.0f..%.0f", cy, want, want + row.h))
        check("and inside the row's own height",
              2 * widest < row.h,
              string.format("%.0f across a row of %.0f", 2 * widest, row.h))
        check("at the end of the row rather than the middle of it",
              rings[1].x > row.x + row.w * 0.8,
              string.format("%.0f across a row from %.0f to %.0f",
                            rings[1].x, row.x, row.x + row.w))
    end
    -- And what the game is is still said, because that is true of a game
    -- whether or not there is an arena running it.
    check("a game that is down still says what it is",
          word("4v4") ~= nil)

    -- A fleet with everything up draws no dial at all. The instrument means
    -- "still looking", and a list where nothing is being looked for that
    -- carried one would be saying so about games it had already found.
    frame(1440, 810, {col_open = "zone"})
    check("and a list with every game up wears none", #rings == 0,
          #rings .. " rings over a fleet that is entirely up")
end

-- --- the account stop opens the same kind of list ---------------------------
--
-- It was a door: a press opened the drawer on the pilot page, which carried
-- the career over these acts. The career went to the site and the page went
-- with it (decision 99), so the acts are a list this stop opens in place,
-- exactly as zone and ship do. What is checked here is that it behaves like
-- the other two and that the one row a guest most needs is the one that
-- stands out.
do
    frame(1440, 810, {col_open = "account"})
    local rows = {}
    for _, r in ipairs(ui.hits) do
        if r.action == "menu_pick" then rows[#rows + 1] = r end
    end
    -- Four rows in the list and three of them pressable: the rule is drawn
    -- rather than published, because it is not a thing to press.
    check("the account list publishes a press for each act", #rows == 3,
          #rows .. " rows")
    -- In the menu's voice, which is where these lists went wrong: they
    -- inherited the case of the screen they were drawn over rather than the
    -- case of the thing they are.
    check("and names them", word("Sign up") ~= nil and word("New name") ~= nil
          and word("Log in") ~= nil, "an act is not in the menu's voice")
    -- The acts travel by their place in the list rather than by name: they
    -- are the interface's own words, and what goes back is a row of the list
    -- this frame drew.
    check("a row carries its place in the list",
          rows[1].value == 1 and rows[3].value == 4,
          tostring(rows[1].value) .. ".." .. tostring(rows[3].value))
    check("and what signing up buys is beside it",
          word("Keep your points") ~= nil)
    local first = rows[1]
    if first then
        check("a press on the row is the pick",
              press(first.x + 5, first.y + first.h / 2)
                  == "menu_pick")
        check("the margin beside the glass puts the panel away",
              press(4, 300) == "menu_shut",
              "landed on " .. tostring(press(4, 300)))
    end
    -- It opens the same panel the other two do, named the same way, and the
    -- column goes out under it: the stop being the top one of the three buys
    -- it nothing any more, because none of them stays.
    check("and the panel names itself", word("ACCOUNT") ~= nil)
    check("and the whole column went out under it",
          stop("zone") == nil and stop("ship") == nil
          and stop("account") == nil and box("menu_go") == nil)

    -- The guest warning: a dot on the stop wherever a lost account would
    -- cost this guest a rated game. The drawer says the same thing in words
    -- on a band; out here the stop is the whole account, so it is a mark.
    local function dots_in_stop(warn)
        local land = {}
        for k, v in pairs(LAND) do land[k] = v end
        land.warn = warn
        frame(1440, 810, {land = land})
        local at = stop("account")
        if not at then return nil end
        local n = 0
        for _, d in ipairs(discs) do
            -- The layer counts up from the bottom and hit boxes count down
            -- from the top, so the mark is flipped into the box's space.
            local y = H - d.y
            if d.r < 4 and d.x >= at.x and d.x <= at.x + at.w
               and y >= at.y and y <= at.y + at.h then
                n = n + 1
            end
        end
        return n
    end
    check("a guest with something to lose gets a dot on the stop",
          dots_in_stop(true) == 1, tostring(dots_in_stop(true)))
    check("and a guest with nothing to lose gets none",
          dots_in_stop(false) == 0, tostring(dots_in_stop(false)))

    -- And it stands beside the call sign rather than beside the word
    -- ACCOUNT. What a guest stands to lose is who they are signed in as, not
    -- the question the row is asking, and down the column those two are at
    -- opposite ends of the row: a mark in the left margin reads as a note on
    -- the label. Asked by lengthening the name, because a mark on the account
    -- moves when the account's name does and one in the margin does not.
    local function dot_x(name)
        local land = {}
        for k, v in pairs(LAND) do land[k] = v end
        land.warn = true
        land.name = name
        frame(1440, 810, {land = land})
        local at = stop("account")
        if not at then return nil end
        for _, d in ipairs(discs) do
            local y = H - d.y
            if d.r < 4 and d.x >= at.x and d.x <= at.x + at.w
               and y >= at.y and y <= at.y + at.h then
                return d.x, at
            end
        end
        return nil, at
    end
    local short_dot, acct = dot_x("Ro 1")
    local long_dot = dot_x("deSoto 4127777")
    check("the dot follows the call sign rather than sitting off the label",
          short_dot ~= nil and long_dot ~= nil
          and short_dot > long_dot + 30,
          tostring(short_dot) .. " for a short name, "
          .. tostring(long_dot) .. " for a long one")
    check("and stands on the answer's half of the row",
          short_dot ~= nil and acct ~= nil
          and short_dot > acct.x + acct.w / 2,
          tostring(short_dot) .. " in a row from " .. tostring(acct and acct.x))

    -- And it stands inside the stop's own outline on every window, since a
    -- narrow one leaves the answer less room to be measured back from.
    frame(844, 390, {land = (function()
        local land = {}
        for k, v in pairs(LAND) do land[k] = v end
        land.warn = true
        return land
    end)()})
    local narrow_stop = stop("account")
    local inside = narrow_stop ~= nil
    for _, d in ipairs(discs) do
        if d.r < 4 and narrow_stop and math.abs(d.x - narrow_stop.x) < 20
           and d.x < narrow_stop.x then
            inside = false
        end
    end
    check("and it stays inside the stop on a phone held sideways", inside,
          "the dot fell outside the row")
end

-- --- what a panel over the fight stands over -------------------------------
--
-- A watcher is in a live room, so every hull on screen wears its pilot's call
-- sign. Type comes from the gui and the gui draws over every mesh, so nothing
-- a panel lays down can cover one: the ship stop's panel climbs from its own
-- stop to the top of the window, and the names of everybody flying behind it
-- were read straight through the build in front of it.
--
-- The column takes the plates down, and so does the ending, and so does a
-- panel one of the stops opened.
do
    local function plates()
        local n = 0
        for _, t in ipairs(words()) do
            if t.s:match("^pilot %d$") then n = n + 1 end
        end
        return n
    end
    frame(1440, 810, {column = false})
    check("a watcher reads a plate on the hulls in front of them",
          plates() > 0, plates() .. " call signs")
    for _, open in ipairs({"ship", "account", "zone"}) do
        frame(1440, 810, {col_open = open})
        check("the " .. open .. " stop's panel takes the plates down",
              plates() == 0, plates() .. " call signs over the panel")
    end
end

-- --- a rung is counted from one --------------------------------------------
--
-- Every other row of the ship panel counts what a pilot has bought, so an
-- untouched row is a nought. A rung is a place on the hull's own ladder, and
-- a gun nobody has spent a credit on is still the first rung rather than no
-- gun: the row read 0 and said the hull was unarmed. `menu.tune_rows` carries
-- what a row reads at nothing spent and the drawing adds it.
do
    local land = {}
    for k, v in pairs(LAND) do land[k] = v end
    land.panel = {
        at = 1, pages = 7, class = 1, label = "Wedge", mine = true,
        bars = {0.2, 0.14, 0.09, 0.71, 0.0}, free = 2, credits = 7,
        rows = {
            {kind = "sect", label = "gun"},
            {kind = "slot", slot = 5, label = "Rung", value = 0, cap = 2,
             base = 1, can_up = true, can_down = false},
            {kind = "slot", slot = 7, label = "Spray", value = 0, cap = 5,
             can_up = true, can_down = false},
        },
    }
    frame(1440, 810, {col_open = "ship", land = land})
    -- Which figure belongs to which row is the row's own line: both rows here
    -- are untouched, and a page of numerals says nothing about where each one
    -- came from.
    local function figure_on(label)
        local row = word(label)
        if not row then return nil end
        for _, t in ipairs(words()) do
            if t.s:match("^%d+$") and math.abs((H - t.y) - row.y) < 2 then
                return t.s
            end
        end
        return nil
    end
    check("an untouched rung reads as the ladder's first rung",
          figure_on("Rung") == "1", tostring(figure_on("Rung")))
    check("and an untouched row that counts what was bought reads none",
          figure_on("Spray") == "0", tostring(figure_on("Spray")))
end

-- --- the card those acts raise stands over the column -----------------------
--
-- What makes a card a card is that nothing behind it can be pressed: it drops
-- every box published before it and publishes its own. The boxes it drops here
-- are the stops and the key, which is exactly the trap: a press meant for an
-- answer that fell through to the key would take a seat.
do
    frame(1440, 810)
    check("the column publishes its key with no card up",
          box("menu_go") ~= nil)
    ui.land_card({head = "Sign up.", sel = 1,
                  note = "keep your points and log in on other devices",
                  fields = {{label = "password", value = "", mask = true}},
                  keys = {{label = "sign up", act = "do_claim"},
                          {label = "cancel"}}})
    ui.finish()
    check("and none of it once a card is up",
          box("menu_go") == nil and stop("account") == nil
              and stop("zone") == nil,
          "the column is still pressable under the card")
    local answers = 0
    for _, r in ipairs(ui.hits) do
        if r.action == "answer" then answers = answers + 1 end
    end
    check("the card's own answers are what can be pressed", answers == 2,
          answers .. " answers")
    local said = nil
    for _, t in ipairs(words()) do
        if string.find(t.s, "SIGN UP") or string.find(t.s, "Sign up") then
            said = t.s
        end
    end
    check("and it says what it is for", said ~= nil,
          "the card drew no heading")
    -- A card with nothing in it is not a card: this is the guard that keeps
    -- the column drawing normally on every frame no card is up.
    frame(1440, 810)
    ui.land_card(nil)
    ui.finish()
    check("no card, no wash, and the key answers again",
          box("menu_go") ~= nil)
end

-- --- the pointer lights what it is resting on -------------------------------
--
-- Out here the stops and the key are the menu: they are everything a first
-- visit presses, and they sat dark under a pointer while every row behind the
-- drawer lit up. What lights is the same field at the same weight, from the
-- action the arena publishes off `ui.pick`.
do
    -- Every rect of this color laid over the box, which is what a lit field
    -- is: the ground goes down first and the wash over it.
    local function lit(b, col)
        if not b then return false end
        for _, r in ipairs(rects) do
            -- Alpha included: the cursor and the row you are already in are
            -- the same cyan at two weights, and telling them apart is half of
            -- what these checks are for.
            local same = r.col and math.abs(r.col[1] - col[1]) < 0.01
                and math.abs(r.col[2] - col[2]) < 0.01
                and math.abs(r.col[3] - col[3]) < 0.01
                and math.abs(r.col[4] - col[4]) < 0.005
            -- Rects are filed in the layer's space, which counts up from the
            -- bottom; hit boxes count down from the top.
            if same and math.abs(r.x - b.x) < 1
               and math.abs((H - r.y - r.h) - b.y) < 1
               and math.abs(r.w - b.w) < 1 and math.abs(r.h - b.h) < 1 then
                return true
            end
        end
        return false
    end
    local CURSOR = pal.a(pal.FRIEND, ui.LIT.CURSOR)

    frame(1440, 810)
    check("nothing is lit with the pointer off the stops",
          not lit(stop("zone"), CURSOR)
          and not lit(stop("account"), CURSOR))

    frame(1440, 810, {sel = "menu_stop", sel_value = "zone"})
    check("the stop under the pointer wears the menu's own field",
          lit(stop("zone"), CURSOR))
    check("and its neighbors do not",
          not lit(stop("account"), CURSOR)
          and not lit(stop("ship"), CURSOR))

    -- The key is lit already and breathing on its own clock, so holding it
    -- still says nothing on its own: it wears the cursor's field over that
    -- ground, which is what says "a press lands here" everywhere else.
    frame(1440, 810, {sel = "menu_go"})
    check("the key stands still and lit under the pointer",
          lit(box("menu_go"), CURSOR))

    -- A row of an open list, told from its neighbors by the value its box
    -- carries: two rows publish the same action and only one of them is under
    -- the pointer.
    frame(1440, 810, {col_open = "zone", sel = "menu_pick", sel_value = 2})
    local rows = {}
    for _, r in ipairs(ui.hits) do
        if r.action == "menu_pick" then rows[r.value] = r end
    end
    -- At the same weight in the same shape a stop wears it in. A row used to
    -- take the menu's wash, which is a flat field plus a skirt against the
    -- panel's left rule; a panel is outlined all the way round and has no such
    -- rule, so the field is flat everywhere and one check answers both.
    check("a row of an open list lights under the pointer",
          lit(rows[2], CURSOR), "the second game did not light")
    check("and the row above it does not",
          not lit(rows[1], CURSOR))

    -- --- and the arrows put it in the same place --------------------------
    --
    -- One cursor, two hands. What up and down move is what a pointer resting
    -- somewhere moves, so a walk to a control lights exactly what a hover on
    -- it lights.
    frame(1440, 810)
    ui.col_sel, ui.col_sel_value = nil, nil
    for _ = 1, 3 do ui.col_step(1) end
    frame(1440, 810, {keep = true})
    check("a walk to the zone stop lights what a hover on it lights",
          lit(stop("zone"), CURSOR),
          "walked to " .. tostring(ui.col_sel) .. "/"
              .. tostring(ui.col_sel_value))

    -- --- and the carousel stays lit as it turns ---------------------------
    --
    -- The arrows either side of the ship are the whole of choosing a hull, so
    -- a hand scrubbing them is a hand that has not moved off the row. The row
    -- answered for the hull it was showing, and the hull is exactly what the
    -- arrows change: every step put the row out from under the cursor.
    local turned = {label = "body", class = 1, free = 2, credits = 7, rows = {}}
    for i, r in ipairs(BODY.rows) do
        if r.kind == "art" then
            local t = {}
            for k, v in pairs(r) do t[k] = v end
            t.value, t.cls, t.at, t.label = 3, 3, 3, "Chord"
            turned.rows[i] = t
        else
            turned.rows[i] = r
        end
    end
    -- The field is laid at the row's own span rather than at the box inside
    -- it, so what is counted is fields of the cursor's weight on the panel.
    local function fields()
        local n = 0
        for _, r in ipairs(rects) do
            if r.col and math.abs(r.col[1] - CURSOR[1]) < 0.01
               and math.abs(r.col[2] - CURSOR[2]) < 0.01
               and math.abs(r.col[3] - CURSOR[3]) < 0.01
               and math.abs(r.col[4] - CURSOR[4]) < 0.005 then
                n = n + 1
            end
        end
        return n
    end
    frame(1440, 810, {land = land_in(BODY), col_open = "ship"})
    check("nothing on the body panel is lit with the cursor off it",
          fields() == 0, fields() .. " fields")
    -- Walked onto rather than placed, so the cursor carries whatever the box
    -- published, which is the half that was wrong.
    ui.col_sel, ui.col_sel_value = "menu_back", nil
    ui.col_step(1)
    frame(1440, 810, {land = land_in(BODY), col_open = "ship", keep = true})
    check("a walk off the head lands on the carousel",
          ui.col_sel == "land_pick_ship", tostring(ui.col_sel))
    check("and lights it", fields() == 1, fields() .. " fields")
    frame(1440, 810, {land = land_in(turned), col_open = "ship", keep = true})
    check("and it stays lit when the arrows turn it to another hull",
          fields() == 1, fields() .. " fields")

    -- --- and a panel opens standing on its own head -----------------------
    --
    -- The head is a row like the rows under it, so it lights like one, and it
    -- is where a panel opens: the stop it climbed off has gone out through
    -- the bottom edge, so a panel that opened with nothing lit opened with
    -- the cursor on a control that is no longer on the screen. `land_act`
    -- puts it here; this is the half that says it can be seen.
    for _, open in ipairs({"account", "zone", "ship"}) do
        frame(1440, 810, {col_open = open, sel = "menu_back"})
        check("the " .. open .. " panel lights its way back",
              lit(box("menu_back"), CURSOR))
    end
end

-- --- the keyboard walks the same controls -----------------------------------
--
-- Out here the stops and the key are the menu: they are everything a first
-- visit presses, and a hand on the arrows has to reach all of them. The walk
-- is read off the boxes the frame published, so what it can reach is what is
-- on the screen.
do
    -- Every stop publishes one action, so what tells them apart in the walk
    -- is the value each carries. A row of an open list is the same: the
    -- action names the list and the value is where the row stands in it.
    local function walk_of()
        local out = {}
        for i, r in ipairs(ui.col_walk()) do
            out[i] = r.action .. (r.value ~= nil
                                  and (":" .. tostring(r.value)) or "")
        end
        return table.concat(out, " ")
    end
    local function step(dir, n)
        for _ = 1, (n or 1) do ui.col_step(dir) end
        return ui.col_sel .. (ui.col_sel_value ~= nil
                              and (":" .. tostring(ui.col_sel_value)) or "")
    end

    for _, shape in ipairs({{1440, 810, "desktop"}, {844, 390, "sideways"}}) do
        frame(shape[1], shape[2])
        check(shape[3] .. " walks the stops in the order they are said",
              walk_of() == "menu_go menu_stop:account menu_stop:zone "
                  .. "menu_stop:players menu_stop:ship menu_stop:settings",
              walk_of())
    end

    -- A first press lands on the end the arrow came from, and the ends wrap,
    -- so nothing out here is more than two presses away. The key is published
    -- before the stops that stand over it, so it is the first of the walk and
    -- the top stop is the second.
    frame(1440, 810)
    ui.col_sel, ui.col_sel_value = nil, nil
    check("down with nothing lit lands on the key", step(1) == "menu_go")
    check("and walks the column", step(1) == "menu_stop:account")
    check("down through the stops", step(1, 4) == "menu_stop:settings")
    check("and off the end back to the top", step(1) == "menu_go")
    ui.col_sel, ui.col_sel_value = nil, nil
    check("up with nothing lit lands on the last stop",
          step(-1) == "menu_stop:settings")

    -- Enter presses what the cursor is on, and the key when nothing is lit:
    -- there is one thing this screen exists for and a keyboard that had to
    -- walk to it would be a front page nobody can start the game from.
    ui.col_sel, ui.col_sel_value = nil, nil
    check("enter with nothing lit is the key", ui.col_go() == "menu_go")
    step(1, 3)
    check("and otherwise is whatever is lit",
          select(2, ui.col_go()) == "zone", tostring(ui.col_sel_value))

    -- A game the fleet is not serving is not a row the walk can land on. It
    -- publishes no box, because it cannot be pressed either.
    frame(1440, 810, {col_open = "zone", land = {
        name = LAND.name, zone = LAND.zone, ship = LAND.ship,
        zones = {
            {label = "Team Battle", named = true, mark = true, index = 1},
            {label = "Chaos", named = true, index = 2},
            {label = "Gauntlet", named = true, dim = true, index = 3},
        }}})
    check("a dark game is not walked onto",
          walk_of() == "menu_back menu_pick:1 menu_pick:2", walk_of())

    -- Inside an open panel the walk is that panel: the way back on its head,
    -- and then its rows. The stop it came from is off the bottom of the screen
    -- and out of the walk with it, which is why the head carries the way out.
    frame(1440, 810, {col_open = "zone"})
    check("an open panel is the whole of the walk",
          walk_of() == "menu_back menu_pick:1 menu_pick:2", walk_of())
    ui.col_sel, ui.col_sel_value = "menu_back", nil
    step(1)
    check("down off the head goes into the rows",
          ui.col_sel == "menu_pick" and ui.col_sel_value == 1,
          tostring(ui.col_sel) .. " " .. tostring(ui.col_sel_value))
    step(1)
    check("and along them", ui.col_sel_value == 2)
    local act, value = ui.col_go()
    check("enter on a row picks that game",
          act == "menu_pick" and value == 2,
          tostring(act) .. " " .. tostring(value))
    step(-1, 2)
    check("and up off the first row is the head again",
          ui.col_sel == "menu_back")
    check("where enter steps back out", ui.col_go() == "menu_back")

    -- The one case where falling back to the key would be wrong: a press
    -- meant for a row would deploy instead of picking one. The key is not on
    -- the screen with a panel up, so the walk cannot reach it and neither can
    -- the fallback.
    ui.col_sel, ui.col_sel_value = "menu_stop", "account"
    check("enter in an open list never reaches the key",
          ui.col_go() == nil, tostring(ui.col_go()))

    -- The ship menu walks the way back and its five parts, and ends on the
    -- reset. The arrows either side of a value are not stops of their own.
    frame(1440, 810, {col_open = "ship"})
    check("the ship menu walks the way back and its five parts",
          walk_of() == "menu_back land_sect:body land_sect:guns "
          .. "land_sect:bombs land_sect:specials land_sect:flair "
          .. "land_kit_reset", walk_of())
    -- Nothing pages any more, so a part answers nothing to an arrow: it is a
    -- press, and enter is what presses it.
    ui.col_sel, ui.col_sel_value = "land_sect", "body"
    check("and a part answers neither arrow", ui.col_side(1) == nil)
    check("while enter on one opens it",
          select(1, ui.col_go()) == "land_sect")
    -- Inside a section, left and right spend a credit from the row the cursor
    -- is standing on, which is the same two keys doing the same kind of work.
    frame(1440, 810, {land = land_in(GUNS), col_open = "ship"})
    ui.col_sel, ui.col_sel_value = "land_kit_row", 7
    local kact, kvalue = ui.col_side(1)
    check("and right on a row spends a credit on it",
          kact == "land_kit_step" and type(kvalue) == "table"
          and kvalue.slot == 7 and kvalue.dir == 1)
    check("while enter on a row does nothing on its own",
          select(1, ui.col_go()) == "land_kit_row")
    -- A flair row steps either way, since every answer it holds is the next
    -- one along.
    frame(1440, 810, {land = land_in(FLAIR), col_open = "ship"})
    ui.col_sel, ui.col_sel_value = "land_flair", 1
    local fact, fvalue = ui.col_side(-1)
    check("and a flair row steps either way",
          fact == "land_flair_step" and type(fvalue) == "table"
          and fvalue.index == 1 and fvalue.dir == -1)
    frame(1440, 810, {col_open = "ship"})
    -- Nothing answers left and right anywhere else out here.
    ui.col_open = "zone"
    check("and the other stops leave both arrows unread",
          ui.col_side(1) == nil)
    ui.col_open = "ship"
end

-- --- and both hands arrive at the same place --------------------------------
--
-- `ui.col_go` names an action and `menu_act` in arena.script is what runs
-- it, so an action this screen publishes that the arena has no branch for is
-- enter pressing nothing at all, silently, on the one screen that has to
-- work. That file is a Defold script and cannot be loaded here, so this reads
-- it, which is what constant_drift_test does with the numbers kept in two
-- languages for the same reason: a comment is not a check.
do
    local f = assert(io.open("client/arena/arena.script"))
    local src = f:read("*a")
    f:close()
    -- The function's own body, ending at the one `end` in the first column.
    local body = src:match("function menu_act%(self, action, value%)(.-)\nend\n")
    check("the arena has a menu handler to read", body ~= nil)

    -- Every action the column publishes, over the screens it has: the bare
    -- stops, and each of the pages one of them opens. Named off what was
    -- drawn rather than written down twice.
    local acts = {}
    for _, o in ipairs({{}, {col_open = "zone"}, {col_open = "ship"},
                        {col_open = "account"}}) do
        frame(1440, 810, o)
        for _, r in ipairs(ui.hits) do
            if r.action:sub(1, 5) == "menu_" or r.action:sub(1, 5) == "land_"
            then
                acts[r.action] = true
            end
        end
    end
    local missing = {}
    for action in pairs(acts) do
        if body and not body:find('"' .. action .. '"', 1, true) then
            missing[#missing + 1] = action
        end
    end
    table.sort(missing)
    check("and it answers every control the column publishes",
          #missing == 0, "no branch for " .. table.concat(missing, ", "))

    -- Escape walks back out of the column a level at a time, and at the last
    -- level it closes: `menu.close` is what refuses that at home, where there
    -- is nothing behind the column to close on to. Pulled out of the same file
    -- and run rather than read, so what is checked is what the branch does and
    -- not how it is spelled.
    local esc = src:match("menu = function%(%)(.-)\n    end,")
    check("the arena has an escape handler to run", esc ~= nil)
    if esc then
        local rang = {}
        local env = {
            menu = {open = true, home = true, stack = {"zone"},
                    page_back = function() return rang.paged end,
                    close = function() rang.close = true end},
            ui = {},
            sfx = {ui = function() end},
            ship_sect_back = function() return false end,
            board_card_back = function() return false end,
            menu_cursor = function() rang.cursor = true end,
            toggle_menu = function() rang.menu = true end,
        }
        local chunk = assert(loadstring(
            "return function()" .. esc .. "\nend", "escape"))
        setfenv(chunk, env)
        local handler = chunk()
        rang.paged = true
        local answered = handler()
        check("escape walks a page off the column before anything else",
              rang.cursor == true and rang.close == nil, tostring(rang.close))
        check("and takes the press rather than leaving it to fall through",
              answered == true, tostring(answered))
        -- With no page left it asks the menu to close, which is where home
        -- and a match part company: `menu.close` keeps the column standing at
        -- home and puts it away in a room. That rule is the menu's, and it is
        -- checked in menu_test.
        rang.paged, rang.close = false, nil
        handler()
        check("and asks it to close once there is no page left",
              rang.close == true)
        -- And with the column down, it is the key that raises one.
        env.menu.open, rang.menu = false, nil
        handler()
        check("with the column down it raises one", rang.menu == true)
    end

    -- Turning the carousel is the whole of choosing a ship. There is no
    -- press after it, so if this branch only moved the page the panel would
    -- draw an Anvil, name it, read out how it flies, and leave the pilot in
    -- an Apex. Pulled out of the file and run rather than read, so what is
    -- checked is what it does.
    local turn = src:match('if action == "land_page_ship" then(.-)\n    end\n')
    check("the arena has a branch for turning the carousel", turn ~= nil)
    if turn then
        local flew, ui_stub = {}, {col_hull = nil}
        local env = {
            ui = ui_stub,
            menu = {
                hull_page = function(at, dir) return at + dir end,
                panel_home = function() return 0 end,
                pick_profile = function(at)
                    flew[#flew + 1] = at
                    return "ship"
                end,
            },
            sfx = {ui = function() end},
            apply_menu = function(_, act) flew.applied = act end,
        }
        local chunk = assert(loadstring(
            "return function(self, action, value)" .. turn .. "\nend", "turn"))
        setfenv(chunk, env)
        local handler = chunk()
        handler(nil, "land_page_ship", 1)
        check("and one step right flies the ship it lands on",
              flew[1] == 1 and flew.applied == "ship" and ui_stub.col_hull == 1,
              tostring(flew[1]) .. ", " .. tostring(flew.applied))
        -- And every page of it is a hull. Sitting out was the page past the
        -- last one until decision 136, so turning one more step off the end
        -- of the roster handed a seat back; there is nothing on this carousel
        -- now but ships.
        ui_stub.col_hull = 6
        handler(nil, "land_page_ship", 1)
        check("and every page it turns to is a ship",
              type(flew[2]) == "number" and flew.applied == "ship",
              tostring(flew[2]))
    end

    -- Where a panel opens standing, which is on its own head. The stop it
    -- climbed off goes out through the bottom edge with the rest of the
    -- column, so a panel that opened with the cursor still on that stop
    -- opened with nothing on it lit: the first arrow had to find the top of a
    -- page already on the screen, and a pointer had nothing saying which
    -- level of the stack it was reading.
    local function branch(pattern, env)
        local part = src:match(pattern)
        if not part then return nil end
        local chunk = loadstring(
            "return function(self, action, value)" .. part .. "\nend", "branch")
        if not chunk then return nil end
        setfenv(chunk, env)
        return chunk()
    end
    do
        local ui_stub = {}
        local opened = {}
        local env = {ui = ui_stub, sfx = {ui = function() end},
                     menu = {panel_home = function() return 0 end,
                             stack = {},
                             page_back = function() return false end,
                             stop_open = function() return opened.at end,
                             press_stop = function(name)
                                 if opened.at == name then
                                     opened.at = nil
                                 else
                                     opened.at = name
                                 end
                                 return nil, true
                             end},
                     apply_menu = function() end,
                     menu_cursor = function()
                         ui_stub.col_sel, ui_stub.col_sel_value =
                             "menu_back", nil
                     end}

        -- A stop, opening its panel.
        local stops = branch(
            '(\n    if action == "menu_stop" then.-\n    end\n)', env)
        check("the arena has a branch for the column's stops", stops ~= nil)
        if stops then
            for _, open in ipairs({"account", "zone", "ship", "settings"}) do
                opened.at = nil
                ui_stub.col_sel, ui_stub.col_sel_value = "menu_stop", open
                stops(nil, "menu_stop", open)
                check("the " .. open .. " stop opens on the way back",
                      opened.at == open
                      and ui_stub.col_sel == "menu_back"
                      and ui_stub.col_sel_value == nil,
                      tostring(ui_stub.col_sel))
            end
            -- And the same press again puts it away, which leaves the cursor
            -- on the stop rather than on a head that has gone.
            opened.at = "zone"
            stops(nil, "menu_stop", "zone")
            check("while the same stop again shuts it", opened.at == nil)
        end

        -- One of the ship's five parts, opened over the menu that names it:
        -- the same rule a level further in.
        local sect = branch('(\n    if action == "land_sect" then.-'
                            .. '\n    end\n)', env)
        check("the arena has a branch for a ship's parts", sect ~= nil)
        if sect then
            opened.at = "ship"
            ui_stub.col_sel, ui_stub.col_sel_value = "land_sect", "guns"
            sect(nil, "land_sect", "guns")
            check("a section opens on the way back too",
                  ui_stub.col_sect == "guns"
                  and ui_stub.col_sel == "menu_back",
                  tostring(ui_stub.col_sel))
        end

        -- And out of one, which leaves the cursor on the part it was opened
        -- from: what took the panel's place on the screen is what is lit.
        env.ship_sect_back = function()
            if opened.at ~= "ship" or not ui_stub.col_sect then return false end
            ui_stub.col_sel, ui_stub.col_sel_value = "land_sect",
                                                     ui_stub.col_sect
            ui_stub.col_sect = nil
            return true
        end
        local back = branch(
            '(\n    if action == "menu_back" then.-\n    end\n)', env)
        check("the arena has a branch for the way back", back ~= nil)
        if back then
            opened.at, ui_stub.col_sect = "ship", "guns"
            ui_stub.col_sel, ui_stub.col_sel_value = "menu_back", nil
            back(nil, "menu_back", nil)
            check("out of a section stands on the part it came from",
                  ui_stub.col_sect == nil
                  and ui_stub.col_sel == "land_sect"
                  and ui_stub.col_sel_value == "guns",
                  tostring(ui_stub.col_sel) .. " "
                  .. tostring(ui_stub.col_sel_value))
        end
    end

    -- And the pointer, which shares the cursor with the arrows and can take it
    -- back. It has to move to do that. It did not have to: the boxes were read
    -- again on every frame, so the panel a stop opened under a hand nobody was
    -- touching handed the cursor to whatever landed under it, and the head the
    -- panel opened on went dark on the frame after it lit.
    local hover = src:match("local function land_hover%(x, y, vh%)(.-)\nend\n")
    check("the arena has a land_hover to run", hover ~= nil)
    -- The arrows either side of a value belong to the row they step, which
    -- this reads out of the file rather than restating.
    local arrows = src:match("local LAND_ARROW = {(.-)\n}\n")
    check("the arena has a table of arrows to run", arrows ~= nil)
    if hover and arrows then
        local under, under_value = "menu_stop", "account"
        local ui_stub = {pick = function()
            return {action = under, value = under_value}
        end}
        local env = {
            ui = ui_stub, touch = {used = false}, land_over = {},
            LAND_HOT = {menu_stop = true, menu_back = true,
                        menu_pick = true, land_kit_row = true},
            LAND_ARROW = assert(loadstring(
                "return {" .. arrows .. "\n}", "arrows"))(),
            -- The branch reads what an arrow carries, so the stub needs the
            -- one standard function it uses to do that.
            type = type,
        }
        local chunk = assert(loadstring(
            "return function(x, y, vh)" .. hover .. "\nend", "hover"))
        setfenv(chunk, env)
        local handler = chunk()

        check("the pointer takes the cursor where it lands",
              handler(100, 200, 810) == true
              and ui_stub.col_sel == "menu_stop")
        -- The stop is gone and a panel row is under the same pixels now.
        under, under_value = "menu_pick", 1
        check("a hand lying still does not answer for the screen moving",
              handler(100, 200, 810) == false
              and ui_stub.col_sel == "menu_stop",
              tostring(ui_stub.col_sel))
        check("and moving it takes the cursor again",
              handler(101, 200, 810) == true
              and ui_stub.col_sel == "menu_pick",
              tostring(ui_stub.col_sel))

        -- Except for the wheel, which is the one thing that puts a different
        -- control under a still hand: the rows slide and the pointer does not.
        local slid = src:match("local function land_slid%(%)(.-)\nend\n")
        check("the arena has a land_slid to run", slid ~= nil)
        if slid then
            local chunk2 = assert(loadstring(
                "return function()" .. slid .. "\nend", "slid"))
            setfenv(chunk2, env)
            under = "menu_back"
            check("a notch of the wheel does not move the cursor by itself",
                  handler(101, 200, 810) == false
                  and ui_stub.col_sel == "menu_pick")
            chunk2()()
            check("but it does ask again where the hand is",
                  handler(101, 200, 810) == true
                  and ui_stub.col_sel == "menu_back",
                  tostring(ui_stub.col_sel))
        end

        -- An arrow is not a control of its own. It steps the row it stands
        -- beside, and a hand resting on one used to take the cursor off that
        -- row: the arrows publish their own boxes over the row's, and none of
        -- those actions lights anything. Scrubbing a slot or the body
        -- carousel left the panel with nothing lit on it.
        under, under_value = "land_kit_step", {slot = 7, dir = 1}
        check("a hand on a slot's arrow stands on the slot",
              handler(140, 200, 810) == true
              and ui_stub.col_sel == "land_kit_row"
              and ui_stub.col_sel_value == 7,
              tostring(ui_stub.col_sel) .. " "
              .. tostring(ui_stub.col_sel_value))
        under, under_value = "land_page_ship", 1
        check("and one on the carousel's stands on the carousel",
              handler(141, 200, 810) == true
              and ui_stub.col_sel == "land_pick_ship"
              and ui_stub.col_sel_value == nil,
              tostring(ui_stub.col_sel) .. " "
              .. tostring(ui_stub.col_sel_value))
    end

    -- And what a step of the ship menu says. Spending a credit has always
    -- made the noise a press makes; a step that cannot happen made none at
    -- all, so an empty purse and a broken control sounded the same.
    local spend = src:match("local function spend%(moved%)(.-)\nend\n")
    check("the arena has a spend to run", spend ~= nil)
    local step_branch = src:match(
        '(\n    if action == "land_kit_step" then.-\n    end\n)')
    check("the arena has a branch for spending a credit", step_branch ~= nil)
    if spend and step_branch then
        local said, allow = {}, true
        local env = {
            type = type,
            sfx = {ui = function(name) said[#said + 1] = name end},
            menu = {class = 1,
                    build_step = function() return allow end},
        }
        local sp = assert(loadstring("return function(moved)" .. spend
                                     .. "\nend", "spend"))
        setfenv(sp, env)
        env.spend = sp()
        local chunk = assert(loadstring(
            "return function(self, action, value)" .. step_branch .. "\nend",
            "step"))
        setfenv(chunk, env)
        local handler2 = chunk()

        handler2(nil, "land_kit_step", {slot = 7, dir = 1})
        check("a credit spent makes the noise a press makes",
              said[1] == "ui_go", tostring(said[1]))
        allow = false
        handler2(nil, "land_kit_step", {slot = 7, dir = 1})
        check("and one that cannot be spent says no",
              said[2] == "ui_deny", tostring(said[2]))
    end
end

-- --- a short window opens the same panel ------------------------------------
--
-- The panel hangs off nothing: whatever the window is, the stops go out
-- through the bottom edge and one panel comes up through it, at the same
-- measure and in the same place. A landscape phone is where that used to be a
-- second layout, and where a panel is most of the window.
do
    frame(844, 390, {land = land_in(BODY), col_open = "ship"})
    local pick = box("land_pick_ship")
    check("a short window's panel carries the carousel", pick ~= nil)
    if pick then
        check("and stays inside the window",
              pick.x >= 0 and pick.x + pick.w <= 844)
    end
    -- A short window cannot hold the whole roster, so what it does instead is
    -- scroll: every row it draws is a whole one, drawn inside the frame.
    local rows = {}
    for _, r in ipairs(ui.hits) do
        if r.action == "land_pick_ship" then rows[#rows + 1] = r end
    end
    check("and draws the rows it has room for", #rows >= 1,
          #rows .. " rows")
    -- And the purse is drawn whatever the window does to the rows, because
    -- the frame draws it rather than the list. That is the whole of what the
    -- sections bought.
    check("with the credits still over them", word("BUILD CREDITS") ~= nil)
    check("the column went out under it",
          stop("account") == nil and stop("zone") == nil
          and box("menu_go") == nil)
    -- Open sky is whatever the panel does not cover, which is the margin it
    -- keeps from the window's own edge.
    check("and open sky still puts it away", press(4, 100) == "menu_shut")

    -- Walking the panel scrolls it, which is the half a scrollbar cannot do
    -- on its own: a row lit under the fold is a row nobody can see
    -- themselves spending on. Body on a short window is where to ask, since
    -- the carousel is taller than the glass and can be scrolled clean off it.
    ui.col_sel, ui.col_sel_value = nil, nil
    frame(844, 390, {land = land_in(BODY), col_open = "ship", keep = true})
    ui.col_scroll = 400
    ui.col_sel, ui.col_sel_value = "land_pick_ship", nil
    frame(844, 390, {land = land_in(BODY), col_open = "ship", keep = true})
    check("walking to a row off the panel brings it back",
          box("land_pick_ship") ~= nil and ui.col_scroll == 0,
          "scrolled to " .. tostring(ui.col_scroll))
    ui.col_sel, ui.col_sel_value = nil, nil
    ui.col_scroll = 0
end

-- --- a phone's top row -----------------------------------------------------
--
-- At 390 points MENU and PLAYERS reached the middle of the screen, which is
-- where a centered clock starts, and the band was drawn straight through them:
-- the front page's first line was two readings on top of each other. The band
-- came off that row to get clear, and gave up the side names on the way down.
--
-- PLAYERS is gone, since the band is what opens the roster now, and the tile
-- readout that still crowded it sits under the dial. MENU went to the foot
-- after it. That leaves a phone's row the same three things a monitor's has,
-- and the band is back on it. Coming off the row had only moved the collision:
-- the line under it is where the radar starts, so the front page read as three
-- headings on two lines with one of them over an instrument. A side gives up
-- its name when the row runs out of width for it, which is a name rather than
-- the line the whole band stands on.
--
-- At 390 points it does. This row is a chip and a clock, and what is left over
-- is not a call sign, so a phone's front page is the clock with a figure
-- either side of it. The names are on a window with the width for them.
--
-- The band keeps its measure whatever is in the far corner: `TOP.row_right()`
-- is where the dial stands rather than whether one is drawn.
--
-- The near corner is empty too: what stood there was a held seat and a room
-- number, and both have gone. So the ruler is the meter's own box at the far
-- end, which spans the row from the top of the safe area down to where the
-- dial starts. The band's own box is a few points taller than the row on
-- purpose so a thumb can find it, and reading the row's line off that box
-- would be reading padding.
--
-- Drawn with the column down, which is what a phone spends most of its time
-- looking at: `F.menu_up` stands the corner's own presses down while the
-- column is up, and these are about the presses.
do
    frame(390, 844, {column = false})
    local meter, clock = box("debug"), word("1:47")
    check("portrait draws the meter and the clock",
          meter and clock, "missing one of them")
    if meter and clock then
        check("portrait keeps the band on the row the meter spans",
              clock.y > meter.y and clock.y < meter.y + meter.h,
              string.format("clock at %.0f, row %.0f to %.0f",
                            clock.y, meter.y, meter.y + meter.h))
        check("and left of the meter rather than through it",
              clock.x < meter.x,
              string.format("clock at %.0f, meter starts %.0f",
                            clock.x, meter.x))
    end
    check("and gives up the side names, the row being 390 points",
          word("PYLON") == nil and word("CAISSON") == nil,
          "a name is drawn where the row has no width for one")
    check("and both figures", word("3") ~= nil and word("5") ~= nil)
    -- The far end of the row is the dial's link meter, with the dial under
    -- it. The meter draws no caption, so what answers for it is the box it
    -- publishes over its bars.
    check("the link meter stands at the far end of the row",
          box("debug") ~= nil, "no meter")
    check("with the dial under it", box("map") ~= nil, "no dial")
    -- And the other half of that strip, which is captioned where you are: the
    -- camera's own tiles, which is the fight this screen is about.
    check("and POS over the corner it stands in", word("POS") ~= nil)

    -- And the band opens the roster on a phone as it does anywhere else.
    check("the band opens the roster on a phone too",
          box("players_open") ~= nil)

    -- And still draws the clock the band is standing under.
    check("and still draws the clock it is standing under",
          word("1:47") ~= nil)

    -- A window with room keeps the same band on the same line.
    frame(1440, 810, {column = false})
    local wide_meter, wide_clock = box("debug"), word("1:47")
    check("a wide window keeps the clock on the row the meter spans",
          wide_meter and wide_clock
              and wide_clock.y > wide_meter.y
              and wide_clock.y < wide_meter.y + wide_meter.h,
          string.format("clock at %s, row ends %s",
                        tostring(wide_clock and wide_clock.y),
                        tostring(wide_meter
                                 and wide_meter.y + wide_meter.h)))
    check("and keeps the side names", word("PYLON") ~= nil)
end

-- With the column dismissed, the screen is the room and nothing else: no key,
-- no name over it, and every instrument a pilot in that room reads.
frame(1440, 810, {column = false})
check("no chip offering the seat a second time", box("take_seat") == nil)
check("and no column key on a screen with no column",
      box("menu_go") == nil)
check("and no name over the fight", word("vectorwake") == nil)
check("and a radar over the room", box("map") ~= nil)
check("and POS over the corner it stands in", word("POS") ~= nil)
check("and a band that opens the roster", box("players_open") ~= nil)

-- --- before a room answers ---------------------------------------------------
--
-- The gap between the engine's first frame and the first snapshot is a
-- directory lookup plus a handshake. What goes there is the dial that is
-- looking for a room, the name under it, and a line when something has gone
-- wrong: everything the client has to say is about a room, and it has not
-- found one.
--
-- It used to be the landing with those taken off it, laid out to the landing's
-- own measure so that nothing moved when the stands arrived. There is no
-- landing to keep still for, so it is measured for itself: this is a loading
-- screen giving way to a game. See decision 158.
do
    for _, s in ipairs(SHAPES) do
        local w, h, shape = s[1], s[2], s[3]

        -- Where the name sits once the column is up, and then without one.
        frame(w, h)
        local landed = word("vectorwake")

        boxes, rects, rings = {}, {}, {}
        state.n = 0
        H = h
        ui.begin(layer, w, h, 1, false, 0)
        ui.waiting(nil)
        ui.finish()
        local waiting = word("vectorwake")

        check(shape .. " waiting says what this is", waiting ~= nil)
        if landed and waiting then
            check(shape .. " waiting puts the name where the column will",
                  math.abs(landed.x - waiting.x) < 0.5
                  and math.abs(landed.y - waiting.y) < 0.5
                  and math.abs(landed.px - waiting.px) < 0.5,
                  string.format("%.1f,%.1f at %.1f against %.1f,%.1f at %.1f",
                                waiting.x, waiting.y, waiting.px,
                                landed.x, landed.y, landed.px))
        end
        -- And nothing that needs a room: no way into the menu, no key into a
        -- seat, and none of the instruments that describe one.
        check(shape .. " waiting offers no menu it has no room for",
              box("open") == nil, "a menu key on a screen with no room")
        check(shape .. " waiting offers no key to a room it has not found",
              box("menu_go") == nil)
        check(shape .. " waiting draws no roster key",
              box("players_open") == nil)
        check(shape .. " waiting draws no radar", box("map") == nil)
        -- The name, and nothing beside it, on every window: a starfield and
        -- the wordmark are the whole of what a normal wait looks like.
        check(shape .. " waiting says nothing while it is only waiting",
              #words() == 1,
              #words() .. " words on screen, wanted 1")
        -- It does not say nothing at all, though. The dial that looks for a
        -- game stands in the middle of the window, which is where the room
        -- will stand.
        --
        -- Three range rings where there is room for three, and two where
        -- there is not: three across a face of twenty two points would be
        -- five apart, which is closer than the stroke drawing them.
        local widest_ring = 0
        for _, g in ipairs(rings) do
            widest_ring = math.max(widest_ring, g.r)
        end
        check(shape .. " waiting looks for the room it has not found",
              #rings == (widest_ring > 24 and 3 or 2),
              #rings .. " rings across " .. string.format("%.0f", widest_ring))
        if #rings >= 2 and waiting then
            -- The mesh counts up from the bottom and everything read back
            -- here counts down from the top, so the dial is flipped to meet
            -- the name.
            local cy = h - rings[1].y
            -- Over the name and clear of it, which is the one measure that
            -- works on every window: the name stands where the column will
            -- head itself, and on a short one that is within a few points of
            -- the middle. A dial sized against the middle had nowhere to go
            -- there and came out at its floor.
            check(shape .. " and stands it on the column's own middle",
                  math.abs(rings[1].x - w / 2) < 1,
                  string.format("%.0f against %.0f", rings[1].x, w / 2))
            check(shape .. " and hangs it over the name, clear of it",
                  cy + widest_ring < waiting.y - waiting.px / 2
                  and cy - widest_ring > 0,
                  string.format("dial %.0f..%.0f, name at %.0f",
                                cy - widest_ring, cy + widest_ring,
                                waiting.y))
            -- And big enough to read as an instrument on every one of them.
            -- The floor is what a window with nothing to spare gets, and
            -- nothing the interface claims to support should be at it.
            check(shape .. " and gives it more than its floor",
                  widest_ring > 20,
                  string.format("%.0f across", widest_ring))
        end
    end

    -- A fleet that is down does say so, on the line under the name. A client
    -- that has finished looking and found nothing must not look like one that
    -- is still trying.
    boxes, rects = {}, {}
    state.n = 0
    H = 810
    ui.begin(layer, 1440, 810, 1, false, 0)
    ui.waiting("no games are running")
    ui.finish()
    local said = word("no games are running")
    local name = word("vectorwake")
    check("a failure is said", said ~= nil)
    if said and name then
        check("and said under the name",
              said.y > name.y and said.y < 810,
              string.format("%.0f against a name at %.0f", said.y, name.y))
    end
end

-- --- the whistle buries nothing ---------------------------------------------
--
-- The column's key is drawn after the ending rather than before it. The ending
-- washes the whole window, so a key laid down first spends the twenty five
-- seconds between matches buried under it: still there to a hit test and gone
-- to a person, which is the stretch a watcher is most likely to be deciding
-- in.
do
    local ended = {playing = false, left = 15, artifact = 7,
                   score = {[0] = 3, [1] = 5}}
    frame(1440, 810, {match = ended})
    local key = box("menu_go")
    check("the key survives a whistle", key ~= nil)
    if key then
        check("and is still what a press there reaches",
              press(key.x + key.w / 2, key.y + key.h / 2) == "menu_go")
    end
end

-- --- a panel takes the screen ----------------------------------------------

-- A panel over this screen draws across all of it, so nothing underneath may
-- still be pressable: a press through a panel is a press nobody aimed. The
-- column sends its own stops and its key out through the bottom edge when one
-- of them opens, and the boxes go with them.
frame(1440, 810, {col_open = "zone"})
check("an open panel takes the key off the screen",
      box("menu_go") == nil)
check("and the stops with it",
      stop("account") == nil and stop("zone") == nil
      and stop("players") == nil and stop("ship") == nil
      and stop("settings") == nil)

-- --- the field of play is still the trigger ---------------------------------

-- With the column down the screen is the room and nothing else, so a press
-- anywhere off the corner instruments is a trigger pull. The column publishes
-- a backdrop while it is up, which is what a press beside it means: put it
-- away. Both halves are checked, because the second used not to hold out here
-- and the difference was a whole screen.
do
    frame(1440, 810, {column = false})
    local free = 0
    for _, at in ipairs({{720, 300}, {400, 500}, {1000, 420}}) do
        free = free + 1
        check(string.format("a press at %d,%d is a trigger pull", at[1], at[2]),
              press(at[1], at[2]) == nil,
              "landed on " .. tostring(press(at[1], at[2])))
    end
    check("the sweep found open sky to press on", free > 0)

    frame(1440, 810)
    check("and the same press puts the column away while it is up",
          press(720, 300) == "menu_shut",
          "landed on " .. tostring(press(720, 300)))
end

-- --- the slide ---------------------------------------------------------------
--
-- Pressing a stop sends the column down through the bottom edge and brings the
-- panel up through the same one, so the two are one movement rather than a
-- swap. Back plays it the other way and the column comes home.
--
-- Asked on a clock, because every frame above runs at time zero, where the
-- slide settles in the frame it starts and there is no middle to look at.
-- `state.text` counts up from the bottom of the window, so a thing on its way
-- down loses y and a thing on its way up gains it.
do
    ui.panel_shut()
    local function said_y(s)
        for i = 1, state.n do
            local t = state.text[i]
            if t and t.s == s then return t.y end
        end
        return nil
    end
    local function at(now, open)
        frame(1440, 810, {col_open = open, now = now})
        return said_y("PLAY"), said_y("Chaos")
    end

    -- The frame the press lands on: nothing has moved yet.
    local shut_key = at(1, nil)
    local mid_key, mid_row = at(1, "zone")
    check("the column has not moved on the frame the stop was pressed",
          shut_key and mid_key and math.abs(shut_key - mid_key) < 1,
          tostring(shut_key) .. " then " .. tostring(mid_key))

    -- Part way through, both halves are travelling.
    local late_key, late_row = at(1.06, "zone")
    check("part way through, the column is on its way down",
          late_key and mid_key and late_key < mid_key - 1,
          tostring(mid_key) .. " to " .. tostring(late_key))
    check("and the panel is on its way up through the same edge",
          late_row and mid_row and late_row > mid_row + 1,
          tostring(mid_row) .. " to " .. tostring(late_row))
    local rest_key, rest_row = at(9, "zone")
    check("with the panel still short of where it comes to rest",
          late_row and rest_row and late_row < rest_row - 1,
          tostring(late_row) .. " against " .. tostring(rest_row))
    check("and at rest the column has gone and the panel stands",
          rest_key == nil and box("menu_pick") ~= nil,
          tostring(rest_key))
    -- The lockup goes with the stops rather than hanging over the panel: the
    -- column is one object, and a wordmark left standing over an open panel is
    -- the front page refusing to get out of the way.
    check("and the name went down with them", word("vectorwake") == nil)

    -- And back the other way.
    at(9, nil)
    check("the frame back is pressed on has not moved either",
          box("menu_go") == nil)
    at(9.06, nil)
    check("and then the column comes home", box("menu_go") ~= nil
          and stop("zone") ~= nil)
    ui.panel_shut()
end

-- --- and the column leaves when the seat is taken --------------------------
--
-- The column sinks out through the bottom edge as a pilot drops into the seat
-- they pressed for, and it does it because it was asked rather than because
-- the view says so. The drawing was told once that a column with no room
-- behind it is always fully up, and the effect was a front page still standing
-- at full height over the match it had just joined.
do
    ui.column_shut()
    local function at(now, open)
        boxes, rects, discs = {}, {}, {}
        state.n = 0
        ui.begin(layer, 1440, 810, 1, false, now, glass)
        local v = view(LAND, {})
        v.open = open
        ui.menu(v)
        ui.finish()
        return box("menu_go")
    end
    local up = at(1, true)
    check("the column stands while the menu is open", up ~= nil)
    local going = at(1.06, false)
    check("and a column on its way out answers no press", going == nil)
    at(9, false)
    check("and is gone once it has left", box("menu_go") == nil
          and stop("account") == nil)
    ui.column_shut()
    ui.panel_shut()
end

print(fails == 0 and "all spectator checks passed"
      or (fails .. " spectator checks failed"))
os.exit(fails == 0 and 0 or 1)
