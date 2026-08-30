-- The landing: the game itself, with the name, the stops and one key over
-- the foot.
--
--     lua5.1 client/tests/landing_test.lua
--
-- Opening the client puts you in the stands of a real room, so the front end
-- is the watcher's HUD rather than a panel describing a game. What is added
-- to it is a lockup, three stops (account, zone, ship) and a PLAY NOW key,
-- in that order up the screen, and what is taken away is the TAKE SEAT chip,
-- because PLAY NOW is that key. All three stops open lists in place. Account
-- was a door into the drawer's pilot page until decision 99, and that page is
-- gone: what it held is a list like the other two.
--
-- These run the real `M.hud` against a stubbed engine on four windows. The
-- questions are the ones a hand at a mouse would ask: can I press it, is it on
-- the screen, is the name over it, and is the room still readable behind it.

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
for _, name in ipairs({"arc", "flush", "outline", "quad", "reset",
                       "ring", "seg", "seg_fade", "seg_flat", "skirt", "tri",
                       "tri_fade", "fan", "seg_glow", "glow_band", "halo",
                       "ring_fade"}) do
    layer[name] = noop
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
}

local ui = require("arena.ui")
local pal = require("arena.palette")
local state = package.loaded["arena.state"]

-- --- the harness -----------------------------------------------------------

-- The window the last frame was drawn at. Only the height is read back, to
-- flip filed type into the space hit boxes are published in.
local H

-- What the arena hands the landing's stops: the pilot, the games with their
-- one-line formats, and the builds with sitting out as the last row.
local LAND = {
    name = "deSoto 412",
    zone = "Team Battle",
    ship = "Gunner",
    zones = {
        {label = "Team Battle", zone = "melee", live = true,
         format = "4v4", here = true},
        {label = "Chaos", zone = "chaos", live = true, format = "1v1"},
    },
    -- One hull at a time, as `menu.ship_panel` builds it: the ship, where it
    -- sits on the five flight rows, the credits spent on it, and the rows
    -- that spend them.
    panel = {
        at = 1, pages = 8, class = 1, label = "Wedge", mine = true,
        bars = {0.2, 0.14, 0.09, 0.71, 0.0},
        free = 2, credits = 7,
        rows = {
            {kind = "sect", label = "gun"},
            {kind = "slot", slot = 7, label = "Spray", value = 2, cap = 5,
             can_up = true, can_down = true},
            {kind = "slot", slot = 8, label = "Bounce", value = 0, cap = 1,
             toggle = true, can_up = true, can_down = false},
            {kind = "sect", label = "bomb"},
            {kind = "slot", slot = 13, label = "Shrapnel", value = 0, cap = 3,
             can_up = true, can_down = false},
            {kind = "slot", slot = 14, label = "Bounce", value = 0, cap = 1,
             toggle = true, can_up = true, can_down = false},
            {kind = "sect", label = "rack"},
            {kind = "slot", slot = 19, label = "Repel", value = 1, cap = 15,
             can_up = true, can_down = true},
            {kind = "slot", slot = 20, label = "Burst", value = 1, cap = 15,
             can_up = true, can_down = true},
            {kind = "reset", label = "Reset", on = true},
        },
    },
    -- A guest's account list, as `menu.account_rows` builds it: the offer
    -- with what it buys, the reroll, a rule, and the way onto an account
    -- that already exists.
    account = {
        {label = "sign up", act = "claim", offer = true,
         note = "keep your points"},
        {label = "new name", act = "reroll"},
        {rule = true},
        {label = "log in", act = "enter_login"},
    },
}

-- A zone holding more than one room, for the checks that need something
-- standing in the top left corner. The row holds nothing at all in an ordinary
-- match, and the ROOM chip is the one thing there that publishes a box at the
-- row's own line and a key's own height.
local ROOMS = {{n = 1, players = 3, bots = 20},
               {n = 2, players = 0, bots = 51}}

-- One frame of the landing, or of an ordinary watch when `o.landing` is false:
-- the two differ in exactly the two things this file is about.
local function frame(w, h, o)
    o = o or {}
    H = h
    boxes, rects, discs = {}, {}, {}
    frosted = {}
    state.n = 0
    -- The scoreboard is off unless a check asks for it, the way it is off
    -- until a player presses PLAYERS.
    ui.details = o.details or false
    -- Which stop's list is down, the way the arena leaves it between frames.
    ui.col_open = o.col_open or nil
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
        landing = o.landing ~= false or nil,
        land = (o.landing ~= false) and (o.land or LAND) or nil,
        side = 0,
        viewer_name = "you",
        menu_open = o.menu_open or false,
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
        rooms = o.rooms, room = o.room,
        fps = 60, frame_ms = 16.7, rx_rate = 0, tx_rate = 0,
    })
    ui.finish()
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
local function press(x, y)
    local r = ui.pick(x, y)
    if r then return r.action end
    return nil
end

-- --- every window carries the key and the name -----------------------------

-- Desktop, a phone on its side, a phone held upright, and the shortest screen
-- the interface claims to support. Two of them have the height for the
-- column and two do not, which is most of what this loop is about: the same
-- four pieces laid out two ways, and neither way over the middle of the
-- screen.
local SHAPES = {
    {1440, 810, "desktop"},
    {844, 390, "sideways", rail = true},
    {390, 844, "portrait"},
    {320, 480, "small", rail = true},
}

for _, s in ipairs(SHAPES) do
    local w, h, shape, rail = s[1], s[2], s[3], s.rail
    frame(w, h)
    local key = box("play_now")
    check(shape .. " publishes one key to press",
          key ~= nil, "no play_now box")
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
              press(key.x + key.w / 2, key.y + key.h / 2) == "play_now")
    end
    local name = word("vectorwake")
    check(shape .. " says what the game is", name ~= nil, "no wordmark")
    -- The name sits over the block rather than in a corner: a stranger's eye
    -- ends on the pulsing thing at the foot, climbs the stops, and the name
    -- has to be where that look ends. Placement A of the three drawn for
    -- decision 61, with the stops of .design/start-flow under it.
    if name and key then
        check(shape .. " puts the name above the key",
              name.y < key.y,
              string.format("name at %.0f, key top %.0f", name.y, key.y))
    end
    -- The three stops, in the order you would say them: who you are, where
    -- you are going, what you arrive as, then the key that commits.
    local acct, zone, ship =
        box("land_account"), box("land_zone"), box("land_ship")
    check(shape .. " publishes the three stops",
          acct ~= nil and zone ~= nil and ship ~= nil, "a stop is missing")
    if key and acct and zone and ship then
        if rail then
            -- Lying down: the stops run left to right in the same order and
            -- the key ends the line, so the whole front end is one band along
            -- the foot.
            check(shape .. " lays the stops along one line in saying order",
                  acct.x < zone.x and zone.x < ship.x
                  and math.abs(acct.y - zone.y) < 1
                  and math.abs(zone.y - ship.y) < 1,
                  string.format("account %.0f,%.0f zone %.0f,%.0f "
                                .. "ship %.0f,%.0f", acct.x, acct.y,
                                zone.x, zone.y, ship.x, ship.y))
            for _, b in ipairs({acct, zone, ship}) do
                check(shape .. " gives every cell the same measure",
                      math.abs(b.w - acct.w) < 1
                          and math.abs(b.h - acct.h) < 1,
                      string.format("%.0fx%.0f against %.0fx%.0f",
                                    b.w, b.h, acct.w, acct.h))
            end
            check(shape .. " keeps the key clear of the cells",
                  ship.x + ship.w <= key.x + 1
                  or ship.y + ship.h <= key.y + 1,
                  string.format("ship ends %.0f,%.0f, key at %.0f,%.0f",
                                ship.x + ship.w, ship.y + ship.h,
                                key.x, key.y))
        else
            check(shape .. " stacks the stops over the key in saying order",
                  acct.y < zone.y and zone.y < ship.y
                  and ship.y + ship.h <= key.y + 1,
                  string.format("account %.0f zone %.0f ship %.0f key %.0f",
                                acct.y, zone.y, ship.y, key.y))
            for _, b in ipairs({acct, zone, ship}) do
                check(shape .. " gives a stop the key's own width",
                      math.abs(b.w - key.w) < 1 and math.abs(b.x - key.x) < 1,
                      string.format("%.0f wide at %.0f against %.0f at %.0f",
                                    b.w, b.x, key.w, key.x))
            end
            check(shape .. " centers the key",
                  math.abs((key.x + key.w / 2) - w / 2) < 1,
                  string.format("middle at %.0f of %d",
                                key.x + key.w / 2, w))
            if name then
                check(shape .. " sets the name on the key's own middle",
                      math.abs(name.x - (key.x + key.w / 2)) < key.w / 2,
                      string.format("name at %.0f, key middle %.0f",
                                    name.x, key.x + key.w / 2))
            end
        end
        -- Whichever way it lies, the block is centered on the window and the
        -- name heads it.
        local left = math.min(acct.x, key.x)
        local right = math.max(ship.x + ship.w, key.x + key.w)
        check(shape .. " centers the block it draws",
              math.abs((left + right) / 2 - w / 2) < 1.5,
              string.format("%.0f..%.0f of %d", left, right, w))
        if name then
            check(shape .. " heads the block with the name",
                  name.x > left and name.x < right,
                  string.format("name at %.0f, block %.0f..%.0f",
                                name.x, left, right))
            check(shape .. " keeps the name with the block",
                  acct.y - name.y < 60 or key.y - name.y < 60,
                  string.format("name at %.0f, stops at %.0f, key at %.0f",
                                name.y, acct.y, key.y))
        end
        check(shape .. " presses a stop where it is drawn",
              press(zone.x + zone.w / 2, zone.y + zone.h / 2) == "land_zone")
        -- The one thing this whole layout exists for. The camera stands
        -- behind the hull the stands are watching, so the middle of the
        -- screen is that hull, and nothing the landing draws may reach it.
        -- The column did on any window under about 530 points tall: at 390
        -- it put the wordmark on the ship and the account stop on its call
        -- sign.
        if name then
            check(shape .. " keeps the whole of it out of the middle",
                  name.y - name.px / 2 > h / 2,
                  string.format("reaches %.0f of %d",
                                name.y - name.px / 2, h))
        end
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
end

-- --- the rest of the HUD is the rest of the screen --------------------------

frame(1440, 810)
check("the landing draws the room's own clock", word("1:47") ~= nil)
check("and both sides of the score",
      word("3") ~= nil and word("5") ~= nil)
check("and names the sides", word("PYLON") ~= nil and word("CAISSON") ~= nil)
-- And says nothing about being a watcher. A green play mark and the word
-- CHANNEL sat in the corner row: a label on the obvious, since no hull on
-- screen wears this client's call sign.
check("and says nothing about the channel it is watching",
      word("CHANNEL") == nil)
check("and offers no menu, this being a room nobody here is in",
      box("open") == nil)
-- The roster is opened from the band across the top rather than from a key
-- beside this one. What is asserted here is that a watcher can still reach it.
check("and a way into the roster", box("details") ~= nil)

-- --- and no way into the menu ----------------------------------------------
--
-- The menu key is not on this screen, on any window. It stood in its own strip
-- under PLAY NOW for a while, on the argument that the stands are a room and a
-- room has a menu about it. It is not a room you are in: everything the menu
-- holds is about the seat you took, and out here you have not taken one. What
-- the key added to the front page was a faint fourth control under the one key
-- the screen exists for.
--
-- The key itself, its word, its shape and where it stands are column_test's,
-- since a match is now the only place it appears.
do
    for _, s in ipairs(SHAPES) do
        local w, h, shape = s[1], s[2], s[3]
        frame(w, h)
        check(shape .. " offers no way into the menu", box("open") == nil,
              "a key on the front page")
        check(shape .. " does not say MENU", word("MENU") == nil)
        -- And PLAY NOW takes the strip back. The column was lifted clear of
        -- the key, and a landing that keeps the lift with nothing in it ends
        -- on a gap where a reader expects the screen to.
        local play = box("play_now")
        check(shape .. " stands PLAY NOW on the bottom margin",
              play ~= nil and play.y + play.h > h - 34,
              play and string.format("play ends %.0f of %d",
                                     play.y + play.h, h)
                  or "no play_now box")
    end
end

-- The one thing a landing takes away. PLAY NOW is the way into a hull here,
-- and a chip in the corner offering the same act is the offer made twice.
check("the landing carries no TAKE SEAT chip",
      box("take_seat") == nil)

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
        for _, action in ipairs({"land_account", "land_zone", "land_ship",
                                 "play_now"}) do
            local b = box(action)
            check(shape .. " frosts " .. action,
                  b ~= nil and glazed(b),
                  b and string.format("%.0f,%.0f %.0fx%.0f is not glass",
                                      b.x, b.y, b.w, b.h) or "no box")
        end
    end
    -- A watcher who deployed has no landing and no glass: the HUD's own
    -- instruments are read against the fight rather than through it.
    frame(1440, 810, {landing = false})
    check("a hull's HUD asks for no glass at all", #frosted == 0,
          #frosted .. " frosted boxes with no landing up")
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
        if r.action == "land_pick_zone" and r.value == "chaos" then
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
    check("and carries the way back", box("land_back") ~= nil)
    if pick then
        check("a press on the row is the pick",
              press(pick.x + 5, pick.y + pick.h / 2) == "land_pick_zone")
        -- The column went with the panel's arrival, so there is nothing of it
        -- left to press: the panel is the screen while it stands.
        check("the key went out with the column", box("play_now") == nil)
        check("and so did the stops", box("land_zone") == nil
              and box("land_account") == nil and box("land_ship") == nil)
        -- The glass swallows a press that missed a row, so a thumb landing
        -- between two rows does not dismiss the thing it was aiming at.
        local hold = box("panel_hold")
        check("the glass takes a press that missed a row", hold ~= nil)
        if hold then
            check("and that press is not a dismissal",
                  press(hold.x + hold.w / 2, hold.y + hold.h - 4)
                      == "panel_hold")
        end
        -- And the margin beside it still is one.
        check("the margin beside the glass puts the panel away",
              press(4, 300) == "land_shut",
              "landed on " .. tostring(press(4, 300)))
    end

    -- The cap: wider than the stop it came from and well short of the window,
    -- centered on the same middle the column stands on.
    frame(1440, 810, {})
    local stop = box("land_zone")
    frame(1440, 810, {col_open = "zone"})
    local row = nil
    for _, r in ipairs(ui.hits) do
        if r.action == "land_pick_zone" then row = row or r end
    end
    check("the panel is wider than the stop it came from",
          stop and row and row.w > stop.w,
          stop and row and (stop.w .. " against " .. row.w) or "missing")
    check("and capped well short of a wide window",
          row and row.w <= 560 and row.w < 1440 * 0.5,
          row and tostring(row.w) or "missing")
    check("and centered on the column's own middle",
          stop and row
          and math.abs((stop.x + stop.w / 2) - (row.x + row.w / 2)) < 2)
    -- On a phone the cap never binds: the panel is the window less its margin,
    -- which is what "the whole screen" means where there is no width to spare.
    frame(390, 844, {col_open = "zone"})
    local narrow = nil
    for _, r in ipairs(ui.hits) do
        if r.action == "land_pick_zone" then narrow = narrow or r end
    end
    check("and takes the whole width of a phone", narrow and narrow.w > 340,
          narrow and tostring(narrow.w) or "missing")
    frame(1440, 810, {col_open = "zone"})

    frame(1440, 810, {col_open = "ship"})
    -- The panel names the ship it is showing, and the rows that spend its
    -- credits, rather than seven names in a column.
    check("the ship panel names the hull it is on", word("Wedge") ~= nil)
    check("and the rows that spend its credits",
          word("Spray") ~= nil and word("Reset") ~= nil)
    check("under the section they belong to", word("GUN") ~= nil)
    -- Both arrows publish a press, so a hand on a pointer and a hand on a
    -- pad walk the roster the same way.
    local left, right = nil, nil
    for _, r in ipairs(ui.hits) do
        if r.action == "land_page_ship" then
            if r.value == -1 then left = r elseif r.value == 1 then right = r end
        end
    end
    check("the pager walks either way", left ~= nil and right ~= nil)
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
    -- A step that cannot happen has no press behind it, so an arrow drawn
    -- dim is one nothing lands on.
    local down_off
    for _, r in ipairs(ui.hits) do
        if r.action == "land_kit_step" and type(r.value) == "table"
           and r.value.slot == 8 and r.value.dir == -1 then
            down_off = r
        end
    end
    check("and a switch that is already off cannot be turned off",
          down_off == nil)
    -- The hull's name is the press that flies it, so a pilot who has paged
    -- to a ship is one press from arriving in it.
    local flyable
    for _, r in ipairs(ui.hits) do
        if r.action == "land_pick_ship" then flyable = r end
    end
    check("and the ship it is on can be flown", flyable ~= nil)

    -- Sitting out is the page past the roster, and carries no rows because
    -- there is no ship to say anything about.
    frame(1440, 810, {land = {name = LAND.name, zone = LAND.zone,
                              ship = "spectate", watching = true,
                              zones = LAND.zones,
                              panel = {at = 7, pages = 8, watching = true,
                                       label = "spectate",
                                       note = "watch the room"}}})
    check("the ship stop says sitting out in the interface's own case",
          word("SPECTATE") ~= nil and word("spectate") == nil)
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
        if r.action == "land_pick_account" then rows[#rows + 1] = r end
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
                  == "land_pick_account")
        check("the margin beside the glass puts the panel away",
              press(4, 300) == "land_shut",
              "landed on " .. tostring(press(4, 300)))
    end
    -- It opens the same panel the other two do, named the same way, and the
    -- column goes out under it: the stop being the top one of the three buys
    -- it nothing any more, because none of them stays.
    check("and the panel names itself", word("ACCOUNT") ~= nil)
    check("and the whole column went out under it",
          box("land_zone") == nil and box("land_ship") == nil
          and box("land_account") == nil and box("play_now") == nil)

    -- The guest warning: a dot on the stop wherever a lost account would
    -- cost this guest a rated game. The drawer says the same thing in words
    -- on a band; out here the stop is the whole account, so it is a mark.
    local function dots_in_stop(warn)
        local land = {}
        for k, v in pairs(LAND) do land[k] = v end
        land.warn = warn
        frame(1440, 810, {land = land})
        local stop = box("land_account")
        if not stop then return nil end
        local n = 0
        for _, d in ipairs(discs) do
            -- The layer counts up from the bottom and hit boxes count down
            -- from the top, so the mark is flipped into the box's space.
            local y = H - d.y
            if d.r < 4 and d.x >= stop.x and d.x <= stop.x + stop.w
               and y >= stop.y and y <= stop.y + stop.h then
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
        local stop = box("land_account")
        if not stop then return nil end
        for _, d in ipairs(discs) do
            local y = H - d.y
            if d.r < 4 and d.x >= stop.x and d.x <= stop.x + stop.w
               and y >= stop.y and y <= stop.y + stop.h then
                return d.x, stop
            end
        end
        return nil, stop
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

    -- It stands inside the stop's own outline rather than a measure off the
    -- label, which on the rail's narrower cell put it outside the box.
    frame(844, 390, {land = (function()
        local land = {}
        for k, v in pairs(LAND) do land[k] = v end
        land.warn = true
        return land
    end)()})
    local rail_stop = box("land_account")
    local inside = rail_stop ~= nil
    local on_the_name = false
    for _, d in ipairs(discs) do
        if d.r < 4 and rail_stop and math.abs(d.x - rail_stop.x) < 20
           and d.x < rail_stop.x then
            inside = false
        end
        -- A rail cell sets the answer under the question at the same left
        -- edge, so out here the dot says which of the two it is about by
        -- which line it is on rather than by how far along the row it is.
        if d.r < 4 and rail_stop and d.x < rail_stop.x + 20
           and (H - d.y) > rail_stop.y + rail_stop.h / 2
           and (H - d.y) < rail_stop.y + rail_stop.h then
            on_the_name = true
        end
    end
    check("and it stays inside the stop on a phone held sideways", inside,
          "the dot fell outside the cell")
    check("and rides the name's line there, not the label's", on_the_name,
          "the dot sat on the question")
end

-- --- what a panel over the fight stands over -------------------------------
--
-- The front page is a live room, so every hull on it wears its pilot's call
-- sign. Type comes from the gui and the gui draws over every mesh, so nothing
-- a panel lays down can cover one: the ship stop's panel climbs from its own
-- stop to the top of the window, and the names of everybody flying behind it
-- were read straight through the build in front of it.
--
-- The menu's column has taken the plates down since it arrived and the ending
-- takes them down too. The landing's own column did not, which went unnoticed
-- because the drawer was where a panel used to stand and the drawer was
-- already named on that line.
do
    local function plates()
        local n = 0
        for _, t in ipairs(words()) do
            if t.s:match("^pilot %d$") then n = n + 1 end
        end
        return n
    end
    frame(1440, 810)
    check("the landing wears a plate on the hulls it is watching",
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
        at = 1, pages = 8, class = 1, label = "Wedge", mine = true,
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

-- --- the card those acts raise stands on the landing ------------------------
--
-- The acts left the drawer with the pilot page, so the card they raise has to
-- stand on a screen the drawer is not on. `ui.land_card` draws it there, and
-- what makes a card a card is that nothing behind it can be pressed: it drops
-- every box published before it and publishes its own. Out here the boxes it
-- drops are the stops and PLAY NOW, which is exactly the trap: a press meant
-- for an answer that fell through to the key would deploy.
do
    frame(1440, 810)
    check("the landing publishes its key with no card up",
          box("play_now") ~= nil)
    ui.land_card({head = "Sign up.", sel = 1,
                  note = "keep your points and log in on other devices",
                  fields = {{label = "password", value = "", mask = true}},
                  keys = {{label = "sign up", act = "do_claim"},
                          {label = "cancel"}}})
    ui.finish()
    check("and none of it once a card is up",
          box("play_now") == nil and box("land_account") == nil
              and box("land_zone") == nil,
          "the landing is still pressable under the card")
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
    -- the landing drawing normally on every frame no card is up.
    frame(1440, 810)
    ui.land_card(nil)
    ui.finish()
    check("no card, no wash, and the key answers again",
          box("play_now") ~= nil)
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
    -- The same weight in the shape a row wears it in.
    --
    -- A stop and the key are objects standing on their own, outlined all the
    -- way round, and they take the field flat. A row inside a panel takes the
    -- menu's wash: most of the weight laid flat and the rest put in a skirt
    -- against the panel's left rule, which is what a selection looks like
    -- everywhere a row is drawn. One weight, two shapes, because they are two
    -- kinds of thing; `wash` is where the 0.8 comes from.
    local function washed(b, weight)
        return lit(b, pal.a(pal.FRIEND, weight * 0.8))
    end

    frame(1440, 810)
    check("nothing is lit with the pointer off the stops",
          not lit(box("land_zone"), CURSOR)
          and not lit(box("land_account"), CURSOR))

    frame(1440, 810, {sel = "land_zone"})
    check("the stop under the pointer wears the menu's own field",
          lit(box("land_zone"), CURSOR))
    check("and its neighbors do not",
          not lit(box("land_account"), CURSOR)
          and not lit(box("land_ship"), CURSOR))

    -- The key is lit already and breathing on its own clock, so holding it
    -- still says nothing on its own: it wears the cursor's field over that
    -- ground, which is what says "a press lands here" everywhere else.
    frame(1440, 810, {sel = "play_now"})
    check("the key stands still and lit under the pointer",
          lit(box("play_now"), CURSOR))

    -- A row of an open list, told from its neighbors by the value its box
    -- carries: two rows publish the same action and only one of them is under
    -- the pointer.
    frame(1440, 810, {col_open = "zone", sel = "land_pick_zone",
                      sel_value = "chaos"})
    local rows = {}
    for _, r in ipairs(ui.hits) do
        if r.action == "land_pick_zone" then rows[r.value] = r end
    end
    check("a row of an open list lights under the pointer",
          washed(rows.chaos, ui.LIT.CURSOR), "the second game did not light")
    check("and the row above it does not",
          not washed(rows.melee, ui.LIT.CURSOR))

    -- --- and the arrows put it in the same place --------------------------
    --
    -- One cursor, two hands. What up and down move is what a pointer resting
    -- somewhere moves, so a walk to a control lights exactly what a hover on
    -- it lights.
    frame(1440, 810)
    ui.col_sel, ui.col_sel_value = nil, nil
    ui.col_step(1)
    ui.col_step(1)
    frame(1440, 810, {keep = true})
    check("a walk to the zone stop lights what a hover on it lights",
          lit(box("land_zone"), CURSOR),
          "walked to " .. tostring(ui.col_sel))
end

-- --- the keyboard walks the same controls -----------------------------------
--
-- Out here the stops and the key are the menu: they are everything a first
-- visit presses, and a hand on the arrows has to reach all of them. The walk
-- is read off the boxes the frame published, so what it can reach is what is
-- on the screen.
do
    local function walk_of()
        local out = {}
        for i, r in ipairs(ui.col_walk()) do out[i] = r.action end
        return table.concat(out, " ")
    end
    local function step(dir, n)
        for _ = 1, (n or 1) do ui.col_step(dir) end
        return ui.col_sel
    end

    for _, shape in ipairs({{1440, 810, "desktop"}, {844, 390, "sideways"}}) do
        frame(shape[1], shape[2])
        check(shape[3] .. " walks the stops in the order they are said",
              walk_of() == "land_account land_zone land_ship play_now",
              walk_of())
    end

    -- A first press lands on the end the arrow came from, and the ends wrap,
    -- so nothing out here is more than two presses away.
    frame(1440, 810)
    ui.col_sel, ui.col_sel_value = nil, nil
    check("down with nothing lit lands on the first stop",
          step(1) == "land_account")
    check("and walks the column", step(1) == "land_zone")
    check("down to the key", step(1, 2) == "play_now")
    check("and off the end back to the top", step(1) == "land_account")
    ui.col_sel, ui.col_sel_value = nil, nil
    check("up with nothing lit lands on the key",
          step(-1) == "play_now")

    -- Enter presses what the cursor is on, and the key when nothing is lit:
    -- there is one thing this screen exists for and a keyboard that had to
    -- walk to it would be a front page nobody can start the game from.
    ui.col_sel, ui.col_sel_value = nil, nil
    check("enter with nothing lit is the key", ui.col_go() == "play_now")
    step(1, 2)
    check("and otherwise is whatever is lit", ui.col_go() == "land_zone")

    -- A game the fleet is not serving is not a stop the walk can land on. It
    -- publishes no box, because it cannot be pressed either.
    frame(1440, 810, {col_open = "zone", land = {
        name = LAND.name, zone = LAND.zone, ship = LAND.ship,
        ships = LAND.ships,
        zones = {
            {label = "Team Battle", zone = "melee", live = true, here = true},
            {label = "Chaos", zone = "chaos", live = true},
            {label = "Gauntlet", zone = "gauntlet", live = false},
        }}})
    check("a dark game is not walked onto",
          walk_of() == "land_back land_pick_zone land_pick_zone",
          walk_of())

    -- Inside an open panel the walk is that panel: the way back on its head,
    -- and then its rows. The stop it came from is off the bottom of the screen
    -- and out of the walk with it, which is why the head carries the way out.
    frame(1440, 810, {col_open = "zone"})
    check("an open panel is the whole of the walk",
          walk_of() == "land_back land_pick_zone land_pick_zone",
          walk_of())
    ui.col_sel, ui.col_sel_value = "land_back", nil
    step(1)
    check("down off the head goes into the rows",
          ui.col_sel == "land_pick_zone" and ui.col_sel_value == "melee",
          tostring(ui.col_sel) .. " " .. tostring(ui.col_sel_value))
    step(1)
    check("and along them", ui.col_sel_value == "chaos")
    local act, value = ui.col_go()
    check("enter on a row picks that game",
          act == "land_pick_zone" and value == "chaos",
          tostring(act) .. " " .. tostring(value))
    step(-1, 2)
    check("and up off the first row is the head again",
          ui.col_sel == "land_back")
    check("where enter steps back out", ui.col_go() == "land_back")

    -- The one case where falling back to the key would be wrong: a press
    -- meant for a row would deploy instead of picking one.
    ui.col_sel, ui.col_sel_value = "land_account", nil
    check("enter in an open list never reaches the key",
          ui.col_go() == nil, tostring(ui.col_go()))

    -- The ship panel walks the way back, the ship it is on, one stop a row,
    -- and back to the hull's own build. The arrows either side of a value are
    -- not stops of their own.
    frame(1440, 810, {col_open = "ship"})
    check("the ship panel walks its ship and its rows",
          walk_of():match("^land_back land_pick_ship land_kit_row")
          and walk_of():match("land_kit_reset$"),
          walk_of())
    ui.col_sel, ui.col_sel_value = "land_pick_ship", 1
    -- Left and right page the roster from the ship's own row.
    local pact, pvalue = ui.col_side(1)
    check("right off the ship pages the roster",
          pact == "land_page_ship" and pvalue == 1,
          tostring(pact) .. " " .. tostring(pvalue))
    -- And spend a credit from any other row, which is the same two keys
    -- doing the same kind of work one row down.
    ui.col_sel, ui.col_sel_value = "land_kit_row", 7
    local kact, kvalue = ui.col_side(1)
    check("and right on a row spends a credit on it",
          kact == "land_kit_step" and type(kvalue) == "table"
          and kvalue.slot == 7 and kvalue.dir == 1)
    check("while enter on a row does nothing on its own",
          select(1, ui.col_go()) == "land_kit_row")
    -- Nothing answers left and right anywhere else out here.
    ui.col_open = "zone"
    check("and the other stops leave both arrows unread",
          ui.col_side(1) == nil)
    ui.col_open = "ship"
end

-- --- and both hands arrive at the same place --------------------------------
--
-- `ui.col_go` names an action and `land_act` in arena.script is what runs
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
    local body = src:match("function land_act%(self, action, value%)(.-)\nend\n")
    check("the arena has a landing handler to read", body ~= nil)

    -- Every action the landing publishes, over the three screens it has: no
    -- list, and each of the two open. Named off what was drawn rather than
    -- written down twice.
    local acts = {}
    for _, o in ipairs({{}, {col_open = "zone"}, {col_open = "ship"}}) do
        frame(1440, 810, o)
        for _, r in ipairs(ui.hits) do
            if r.action == "play_now" or r.action:sub(1, 5) == "land_" then
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
    check("and it answers every control the landing publishes",
          #missing == 0, "no branch for " .. table.concat(missing, ", "))

    -- Escape is the other way into the menu, and it has to answer the same
    -- rule the drawing does: no key on the front page means no menu there,
    -- and a keyboard that opens one anyway is the absence worked around.
    -- Pulled out of the same file and run rather than read, so what is
    -- checked is what the branch does and not how it is spelled.
    local esc = src:match("menu = function%(%)(.-)\n    end,")
    check("the arena has an escape handler to run", esc ~= nil)
    if esc then
        local rang = {}
        local env = {
            menu = {open = false, home = true,
                    page_back = function() return false end,
                    close = function() rang.close = true end},
            ui = {},
            sfx = {ui = function() end},
            toggle_menu = function() rang.menu = true end,
            toggle_details = function() rang.details = true end,
            land_shut = function() rang.shut = true end,
        }
        local chunk = assert(loadstring(
            "return function()" .. esc .. "\nend", "escape"))
        setfenv(chunk, env)
        local handler = chunk()
        local answered = handler()
        check("escape opens no menu on the front page", rang.menu == nil,
              "the menu came up where its key is not drawn")
        check("and takes the press rather than leaving it to fall through",
              answered == true, tostring(answered))
        env.menu.home = false
        handler()
        check("and opens it in a room, which is what it is for",
              rang.menu == true)
    end
end

-- --- and the rail opens the same panel -------------------------------------
--
-- Lying down used to change where the panel hung from and how much room it
-- had: down the column it dropped out of a stop the key's own width, along the
-- rail it opened over the fight from one cell of three.
--
-- It hangs off nothing now. Whatever shape the landing is in, the stops go out
-- through the bottom edge and one panel comes up through it, at the same
-- measure and in the same place. That is one layout for both shapes rather
-- than two, which is the argument that took the landscape phone's own
-- three-section version out years' worth of decisions ago.
do
    frame(844, 390, {col_open = "ship"})
    local pick = box("land_pick_ship")
    check("a rail's panel carries the ship it is on", pick ~= nil)
    if pick then
        check("and stays inside the window",
              pick.x >= 0 and pick.x + pick.w <= 844)
    end
    -- A short window cannot hold the whole panel, so what it does instead is
    -- scroll: every row it draws is a whole one, drawn inside the frame.
    local rows = {}
    for _, r in ipairs(ui.hits) do
        if r.action == "land_kit_row" then rows[#rows + 1] = r end
    end
    check("and draws the rows it has room for", #rows >= 1,
          #rows .. " rows")
    check("the rail went out under it like the column does",
          box("land_account") == nil and box("land_zone") == nil
          and box("play_now") == nil)
    -- Open sky is whatever the panel does not cover, which is the margin it
    -- keeps from the window's own edge.
    check("and open sky still puts it away", press(4, 100) == "land_shut")

    -- Walking the panel scrolls it, which is the half a scrollbar cannot do
    -- on its own: a row lit under the fold is a row nobody can see
    -- themselves spending on. The last row is the one to ask for, since a
    -- short window is exactly where it will not already be drawn.
    local last = nil
    for _, r in ipairs(LAND.panel.rows) do
        if r.kind == "slot" then last = r.slot end
    end
    ui.col_scroll = 0
    ui.col_sel, ui.col_sel_value = "land_kit_row", last
    frame(844, 390, {col_open = "ship", keep = true})
    local lit
    for _, r in ipairs(ui.hits) do
        if r.action == "land_kit_row" and r.value == last then lit = r end
    end
    check("walking to a row under the fold brings it into the panel",
          lit ~= nil, "row " .. tostring(last) .. " stayed off the panel")
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
-- At 390 points it does. This row is a chip, a clock and a dial hard into the
-- far corner, and what is left over is not a call sign, so a phone's front
-- page is the clock with a figure either side of it. The names are on the
-- board a press opens, and on a window with the width for them.
--
-- The chip is the ruler here, so these frames are drawn with a second room in
-- the zone. A landing with one room puts nothing in that corner at all, and
-- the band's own box is a few points taller than the row on purpose so a thumb
-- can find it: reading the row's line off that box would be reading padding.
do
    frame(390, 844, {rooms = ROOMS, room = 1})
    local chip, clock = box("rooms"), word("1:47")
    check("portrait draws the corner chip and the clock",
          chip and clock, "missing one of them")
    if chip and clock then
        check("portrait keeps the band on the corner row's own line",
              math.abs(clock.y - (chip.y + chip.h / 2)) < 1,
              string.format("clock at %.0f, chip mid %.0f",
                            clock.y, chip.y + chip.h / 2))
        check("and to the right of the chip rather than through it",
              clock.x > chip.x + chip.w,
              string.format("clock at %.0f, chip ends %.0f",
                            clock.x, chip.x + chip.w))
    end
    check("and gives up the side names, the row being 390 points",
          word("PYLON") == nil and word("CAISSON") == nil,
          "a name is drawn where the row has no width for one")
    check("and both figures", word("3") ~= nil and word("5") ~= nil)
    -- The far end of the row is the dial, at the same margin from its corner
    -- that the chips keep from the opposite one. The link meter stood out here
    -- until it went into the menu's head and the dial came up into the corner
    -- it left. The meter draws no caption, so what answers for it is the box
    -- it would publish over its bars.
    check("and nothing in the far corner of the row but the dial",
          box("debug") == nil, "the link meter is still on the landing")
    local corner = box("map")
    if chip and corner then
        check("which hugs it at the corner chip's own margin",
              math.abs(corner.y - chip.y) < 0.5
                  and math.abs((390 - (corner.x + corner.w)) - chip.x) < 0.5,
              string.format("dial at %.0f,%.0f ending %.0f of 390",
                            corner.x, corner.y, corner.x + corner.w))
    end

    -- The band is the control, so the press that opens the roster is on the
    -- band rather than in the corner beside it.
    local band = box("details")
    check("the roster opens from the band itself",
          band and clock and clock.x > band.x
              and clock.x < band.x + band.w,
          band and string.format("band %.0f..%.0f, clock at %.0f",
                                 band.x, band.x + band.w, clock.x)
              or "no band press")
    check("and nothing in the corner row offers it a second time",
          band ~= nil and chip ~= nil and band.x > chip.x + chip.w,
          band and chip and string.format("band starts %.0f, chip ends %.0f",
                                          band.x, chip.x + chip.w)
              or "no band press")

    -- The board opens under the band, wherever the band ends.
    frame(390, 844, {details = true})
    local heading, clock2 = word("PILOTS"), word("1:47")
    check("portrait starts the roster under the clock",
          heading and clock2 and heading.y > clock2.y,
          string.format("roster at %s, clock at %s",
                        tostring(heading and heading.y),
                        tostring(clock2 and clock2.y)))

    -- A window with room keeps the same band on the same line.
    frame(1440, 810, {rooms = ROOMS, room = 1})
    local wide_chip, wide_clock = box("rooms"), word("1:47")
    check("a wide window keeps the clock on the corner row's own line",
          wide_chip and wide_clock
              and math.abs(wide_clock.y - (wide_chip.y + wide_chip.h / 2)) < 24,
          string.format("clock at %s, chip mid %s",
                        tostring(wide_clock and wide_clock.y),
                        tostring(wide_chip and wide_chip.y + wide_chip.h / 2)))
    check("and keeps the side names", word("PYLON") ~= nil)
end

-- A pilot the room is holding a seat for is not on the landing, and keeps it.
frame(1440, 810, {landing = false})
check("a benched pilot still gets TAKE SEAT",
      box("take_seat") ~= nil)
check("and no key that would join a room they are already in",
      box("play_now") == nil)
check("and no name over the fight they are already in",
      word("vectorwake") == nil)

-- --- before a room answers ---------------------------------------------------
--
-- The gap between the engine's first frame and the first snapshot is a
-- directory lookup plus a handshake. What goes there is this same screen with
-- everything that needs a room taken off it, so when the stands arrive the
-- only thing that happens is that the room, the stops and the menu key
-- appear.
--
-- The name is the thing to hold still. It was drawn centered for a while,
-- which made the logo jump to the foot of the screen the moment a room
-- answered: the one move a hand-off should never make.
do
    for _, s in ipairs(SHAPES) do
        local w, h, shape = s[1], s[2], s[3]

        -- Where the name sits with a room, and then without one.
        frame(w, h)
        local landed = word("vectorwake")

        boxes, rects = {}, {}
        state.n = 0
        H = h
        ui.begin(layer, w, h, 1, false, 0)
        ui.waiting(nil)
        ui.finish()
        local waiting = word("vectorwake")

        check(shape .. " waiting says what this is", waiting ~= nil)
        if landed and waiting then
            check(shape .. " waiting puts the name where the room will put it",
                  math.abs(landed.x - waiting.x) < 0.5
                  and math.abs(landed.y - waiting.y) < 0.5
                  and math.abs(landed.px - waiting.px) < 0.5,
                  string.format("%.1f,%.1f at %.1f against %.1f,%.1f at %.1f",
                                waiting.x, waiting.y, waiting.px,
                                landed.x, landed.y, landed.px))
        end
        -- And no way into the menu, because there is nothing yet for a menu
        -- to be about: leaving, which side you are on and the machine are all
        -- things a room has, and the column that holds them arrives with the
        -- room. This screen carried a MENU key while that key sat in the
        -- corner and the panel behind it was the whole front end. The front
        -- end is the stands now, and what is left here is the wordmark.
        check(shape .. " waiting offers no menu it has no room for",
              box("open") == nil, "a menu key on a screen with no room")
        -- And nothing that needs a room: no key into one, and none of the
        -- instruments that describe one.
        check(shape .. " waiting offers no key to a room it has not found",
              box("play_now") == nil)
        check(shape .. " waiting draws no roster key", box("details") == nil)
        check(shape .. " waiting draws no radar", box("map") == nil)
        -- The name, and nothing beside it, on every window. The count was two
        -- on a desktop while this screen drew a menu key with MENU written on
        -- it; with the key gone a starfield and the wordmark are the whole of
        -- what a normal wait looks like.
        check(shape .. " waiting says nothing while it is only waiting",
              #words() == 1,
              #words() .. " words on screen, wanted 1")
    end

    -- A fleet that is down does say so, in the slot the key will take. A
    -- client that has finished looking and found nothing must not look like
    -- one that is still trying.
    frame(1440, 810)
    local key = box("play_now")
    boxes, rects = {}, {}
    state.n = 0
    H = 810
    ui.begin(layer, 1440, 810, 1, false, 0)
    ui.waiting("no games are running")
    ui.finish()
    local said = word("no games are running")
    check("a failure is said", said ~= nil)
    if said and key then
        check("and said where the key would be",
              said.y > key.y and said.y < key.y + key.h,
              string.format("%.0f against %.0f..%.0f",
                            said.y, key.y, key.y + key.h))
    end
end

-- --- the podium does not bury the key ---------------------------------------
--
-- Between matches the room puts up a podium, and the podium washes the whole
-- window at 0.8 so the card is what gets read. The landing's key is drawn
-- after that wash rather than before it: laid down first it is still there to
-- a hit test and gone to a person, for the twenty five seconds a stranger is
-- most likely to be deciding. Deploying then is legal and lands you at the
-- next whistle.
do
    local ended = {playing = false, left = 15, artifact = 7,
                   score = {[0] = 3, [1] = 5}}
    frame(1440, 810, {match = ended})
    local key = box("play_now")
    check("the key survives a podium", key ~= nil)
    check("and the name with it", word("vectorwake") ~= nil)
    if key then
        check("and is still what a press there reaches",
              press(key.x + key.w / 2, key.y + key.h / 2) == "play_now")
        -- The podium is centered and the key sits at the foot, so the wash is
        -- the only thing between them. Nothing the podium writes may land on
        -- the key itself.
        local on_key = 0
        for _, t in ipairs(words()) do
            local y = H - t.y
            if y >= key.y - 6 and y <= key.y + key.h + 6
               and t.s ~= "PLAY NOW" then
                on_key = on_key + 1
            end
        end
        check("and the podium writes nothing across it",
              on_key == 0, on_key .. " words on the key")
    end
end

-- --- the menu takes the screen ---------------------------------------------

-- A column over this screen draws its panel across all of it, so nothing
-- underneath may still be pressable: a press through a panel is a press nobody
-- aimed. The arena no longer puts the two together, since the menu is not
-- reachable from the front page, so what this pins is `M.hud`'s own rule
-- rather than a screen a player can get to: whoever sets `menu_open` gets the
-- landing stood down with it.
frame(1440, 810, {menu_open = true})
check("an open menu takes the key off the landing",
      box("play_now") == nil)
check("and the stops with it",
      box("land_account") == nil and box("land_zone") == nil
      and box("land_ship") == nil)

-- --- the field of play is still the trigger ---------------------------------

-- The landing adds two things at the foot of the screen and must not put a box
-- anywhere else. Everything above the key stays what it was: a fight, with the
-- trigger under the pointer.
frame(1440, 810)
local key = box("play_now")
local free = 0
for _, at in ipairs({{720, 300}, {400, 500}, {1000, 420}}) do
    if key and at[2] > key.y - 80 then
        -- Inside the block the landing owns, which is allowed to take a press.
    else
        free = free + 1
        check(string.format("a press at %d,%d is still a trigger pull",
                            at[1], at[2]),
              press(at[1], at[2]) == nil,
              "landed on " .. tostring(press(at[1], at[2])))
    end
end
check("the sweep found open sky to press on", free > 0)

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
        return said_y("PLAY NOW"), said_y("Chaos")
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
          rest_key == nil and box("land_pick_zone") ~= nil,
          tostring(rest_key))
    -- The lockup goes with the stops rather than hanging over the panel: the
    -- column is one object, and a wordmark left standing over an open panel is
    -- the front page refusing to get out of the way.
    check("and the name went down with them", word("vectorwake") == nil)

    -- And back the other way.
    at(9, nil)
    check("the frame back is pressed on has not moved either",
          box("play_now") == nil)
    at(9.06, nil)
    check("and then the column comes home", box("play_now") ~= nil
          and box("land_zone") ~= nil)
    ui.panel_shut()
end

print(fails == 0 and "all landing checks passed"
      or (fails .. " landing checks failed"))
os.exit(fails == 0 and 0 or 1)
