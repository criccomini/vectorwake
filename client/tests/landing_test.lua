-- The landing: the game itself, with the name, the stops and one key over
-- the foot.
--
--     lua5.1 client/tests/landing_test.lua
--
-- Opening the client puts you in the stands of a real room, so the front end
-- is the watcher's HUD rather than a panel describing a game. What is added
-- to it is a lockup, three stops (account, zone, ship) and a PLAY NOW key,
-- in that order up the screen, and what is taken away is the TAKE SEAT chip,
-- because PLAY NOW is that key. The zone and ship stops open lists in place;
-- account opens the drawer on the pilot page, so its press leaves this file
-- at the arena's door.
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
for _, name in ipairs({"arc", "disc", "flush", "outline", "quad", "reset",
                       "ring", "seg", "seg_fade", "seg_flat", "skirt", "tri",
                       "tri_fade", "fan", "seg_glow", "glow_band", "halo",
                       "ring_fade"}) do
    layer[name] = noop
end

-- Frames and rects are kept, because the key is a stroked box over a wash and
-- the question is where the two of them landed.
local boxes, rects = {}, {}
layer.frame = function(self, x, y, w, h)
    self.n = self.n + 1
    boxes[#boxes + 1] = {x = x, y = y, w = w, h = h}
end
layer.rect = function(self, x, y, w, h)
    self.n = self.n + 1
    rects[#rects + 1] = {x = x, y = y, w = w, h = h}
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
local state = package.loaded["arena.state"]

-- --- the harness -----------------------------------------------------------

-- The window the last frame was drawn at. Only the height is read back, to
-- flip filed type into the space hit boxes are published in.
local H

-- What the arena hands the landing's stops: the pilot, the games with their
-- one-line formats, and the builds with sitting out as the last row.
local LAND = {
    name = "Vesper 412",
    zone = "Team Battle",
    ship = "Gunner",
    zones = {
        {label = "Team Battle", zone = "melee", live = true,
         format = "4v4", here = true},
        {label = "Duel", zone = "duel", live = true, format = "1v1"},
    },
    ships = {
        {label = "Gunner", value = 1, here = true},
        {label = "Bomber", value = 2},
        {label = "spectate", value = "spectate"},
    },
}

-- One frame of the landing, or of an ordinary watch when `o.landing` is false:
-- the two differ in exactly the two things this file is about.
local function frame(w, h, o)
    o = o or {}
    H = h
    boxes, rects = {}, {}
    state.n = 0
    -- The scoreboard is off unless a check asks for it, the way it is off
    -- until a player presses PLAYERS.
    ui.details = o.details or false
    -- Which stop's list is down, the way the arena leaves it between frames.
    ui.land_open = o.land_open or nil
    ui.begin(layer, w, h, o.density or 1, false, 0)
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

-- What a press at this point reaches, through the same rule `on_input` uses.
local function press(x, y)
    local r = ui.pick(x, y)
    if r then return r.action end
    return nil
end

-- --- every window carries the key and the name -----------------------------

-- Desktop, a phone on its side, a phone held upright, and the shortest screen
-- the interface claims to support.
local SHAPES = {
    {1440, 810, "desktop"},
    {844, 390, "sideways"},
    {390, 844, "portrait"},
    {320, 480, "small"},
}

for _, s in ipairs(SHAPES) do
    local w, h, shape = s[1], s[2], s[3]
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
        check(shape .. " centers the key",
              math.abs((key.x + key.w / 2) - w / 2) < 1,
              string.format("middle at %.0f of %d", key.x + key.w / 2, w))
        check(shape .. " presses the key where it is drawn",
              press(key.x + key.w / 2, key.y + key.h / 2) == "play_now")
    end
    local name = word("vectorwake")
    check(shape .. " says what the game is", name ~= nil, "no wordmark")
    -- The name sits over the column rather than in a corner: a stranger's
    -- eye ends on the pulsing thing at the foot, climbs the stops, and the
    -- name has to be where that look ends. Placement A of the three drawn
    -- for decision 61, with the stops of .design/start-flow between.
    if name and key then
        check(shape .. " puts the name above the key",
              name.y < key.y,
              string.format("name at %.0f, key top %.0f", name.y, key.y))
        check(shape .. " sets the name on the key's own middle",
              math.abs(name.x - (key.x + key.w / 2)) < key.w / 2,
              string.format("name at %.0f, key middle %.0f",
                            name.x, key.x + key.w / 2))
    end
    -- The three stops, in the order you would say them: who you are, where
    -- you are going, what you arrive as, then the key that commits.
    local acct, zone, ship =
        box("land_account"), box("land_zone"), box("land_ship")
    check(shape .. " publishes the three stops",
          acct ~= nil and zone ~= nil and ship ~= nil, "a stop is missing")
    if key and acct and zone and ship then
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
        check(shape .. " presses a stop where it is drawn",
              press(zone.x + zone.w / 2, zone.y + zone.h / 2) == "land_zone")
        if name then
            check(shape .. " keeps the name with the stack",
                  name.y < acct.y and acct.y - name.y < 60,
                  string.format("name at %.0f, stack top %.0f",
                                name.y, acct.y))
        end
        -- The stops say their answers, in the case the HUD sets everything.
        check(shape .. " says who you are", word("VESPER 412") ~= nil)
        check(shape .. " says where you are going",
              word("TEAM BATTLE") ~= nil)
        check(shape .. " says what you arrive as", word("GUNNER") ~= nil)
    end
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
check("and keeps the way into the menu", box("open") ~= nil)
-- The roster is opened from the band across the top rather than from a key
-- beside this one. What is asserted here is that a watcher can still reach it.
check("and a way into the roster", box("details") ~= nil)

-- --- the way in wears three bars ------------------------------------------
--
-- The menu key is a hamburger: the mark alone on a phone in either
-- orientation, the mark and the word on anything wider. The box stays in both,
-- because `key_box` is the one shape a thing to press wears here and bars
-- floating on the glass would make this control the exception the corner keys
-- were drawn as boxes to stop being.
do
    for _, s in ipairs(SHAPES) do
        local w, h, shape = s[1], s[2], s[3]
        frame(w, h)
        local key = box("open")
        check(shape .. " keeps a way into the menu", key ~= nil, "no key")
        local worded = word("MENU") ~= nil
        if shape == "desktop" then
            check("a desktop names the key as well as marking it", worded,
                  "no MENU beside the bars")
        else
            check(shape .. " gives the key the mark alone", not worded,
                  "MENU is still written on a phone")
        end
        if key then
            -- Square where it is the mark alone, so it reads as a key rather
            -- than as a word's box with a picture left in it.
            local square = math.abs(key.w - key.h) < 1.5
            check(shape .. " shapes the key to what is in it",
                  worded and not square or (not worded and square),
                  string.format("%.0fx%.0f, word %s", key.w, key.h,
                                tostring(worded)))
            -- A finger reaches it whatever its width: `M.pick` grows a box to
            -- the touch floor for a press made with one.
            check(shape .. " answers a finger aimed near the key",
                  ui.pick(key.x + key.w / 2, key.y + key.h + 8, true)
                      == key,
                  "a near miss found nothing")
        end
    end
end

-- The one thing a landing takes away. PLAY NOW is the way into a hull here,
-- and a chip in the corner offering the same act is the offer made twice.
check("the landing carries no TAKE SEAT chip",
      box("take_seat") == nil)

-- --- a stop's list opens over the glass -------------------------------------
--
-- Zone and ship drop their lists in place, upward so the key stays clear. A
-- row's press beats the stop behind it, open sky puts the list away instead
-- of pulling a trigger, and PLAY NOW answers through all of it: it is the
-- press that commits, whatever else is open.
do
    frame(1440, 810, {land_open = "zone"})
    local pick
    for _, r in ipairs(ui.hits) do
        if r.action == "land_pick_zone" and r.value == "duel" then
            pick = r
        end
    end
    check("the zone list offers the other game", pick ~= nil,
          "no row for the second zone")
    check("and says its name", word("DUEL") ~= nil)
    check("and its format beside it", word("1V1") ~= nil)
    if pick then
        check("a press on the row is the pick",
              press(pick.x + 5, pick.y + pick.h / 2) == "land_pick_zone")
        local key = box("play_now")
        check("the list stays clear of the key",
              key and pick.y + pick.h <= key.y,
              "a row is over PLAY NOW")
        check("open sky puts the list away",
              press(400, 300) == "land_shut",
              "landed on " .. tostring(press(400, 300)))
        check("and PLAY NOW still answers",
              key and press(key.x + key.w / 2, key.y + key.h / 2)
                  == "play_now")
    end

    frame(1440, 810, {land_open = "ship"})
    check("the ship list is the builds by name", word("BOMBER") ~= nil)
    check("with sitting out as an answer", word("SPECTATE") ~= nil)
    local spec
    for _, r in ipairs(ui.hits) do
        if r.action == "land_pick_ship" and r.value == "spectate" then
            spec = r
        end
    end
    check("and sitting out can be pressed", spec ~= nil)
    -- No hull is named anywhere in it: which hull a build rides is the
    -- hangar's business.
    check("and no hull is named in it",
          word("APEX") == nil and word("WEDGE") == nil)
end

-- --- a phone's top row -----------------------------------------------------
--
-- At 390 points MENU and PLAYERS reached the middle of the screen, which is
-- where a centered clock starts, and the band was drawn straight through them:
-- the front page's first line was two readings on top of each other. The band
-- came off that row to get clear, and gave up the side names on the way down.
--
-- PLAYERS is gone, since the band is what opens the roster now, and the tile
-- readout that still crowded it sits under the dial. That leaves a phone's row
-- the same three things a monitor's has, and the band is back on it. Coming off
-- the row had only moved the collision: the line under it is where the radar
-- starts, so the front page read as three headings on two lines with one of
-- them over an instrument. A side gives up its name when the row runs out of
-- width for it, which is a name rather than the line the whole band stands on.
--
-- At 390 points it does. This row is a key, a clock and a dial hard into the
-- far corner, and what is left over is not a call sign, so a phone's front
-- page is the clock with a figure either side of it. The names are on the
-- board a press opens, and on a window with the width for them.
do
    frame(390, 844)
    local menu_key, clock = box("open"), word("1:47")
    check("portrait draws the corner key and the clock",
          menu_key and clock, "missing one of them")
    if menu_key and clock then
        check("portrait keeps the band on the corner key's own line",
              math.abs(clock.y - (menu_key.y + menu_key.h / 2)) < 1,
              string.format("clock at %.0f, key mid %.0f",
                            clock.y, menu_key.y + menu_key.h / 2))
        check("and to the right of the key rather than through it",
              clock.x > menu_key.x + menu_key.w,
              string.format("clock at %.0f, key ends %.0f",
                            clock.x, menu_key.x + menu_key.w))
    end
    check("and gives up the side names, the row being 390 points",
          word("PYLON") == nil and word("CAISSON") == nil,
          "a name is drawn where the row has no width for one")
    check("and both figures", word("3") ~= nil and word("5") ~= nil)
    -- The far end of the row is the dial, at the same margin from its corner
    -- that the way into the menu keeps from the opposite one. The link meter
    -- stood out here until it went into the menu's head and the dial came up
    -- into the corner it left. The meter draws no caption, so what answers for
    -- it is the box it would publish over its bars.
    check("and nothing in the far corner of the row but the dial",
          box("debug") == nil, "the link meter is still on the landing")
    local corner = box("map")
    if menu_key and corner then
        check("which hugs it at the corner key's own margin",
              math.abs(corner.y - menu_key.y) < 0.5
                  and math.abs((390 - (corner.x + corner.w)) - menu_key.x) < 0.5,
              string.format("dial at %.0f,%.0f ending %.0f of 390",
                            corner.x, corner.y, corner.x + corner.w))
    end

    -- The band is the control, so the press that opens the roster is on the
    -- band rather than in the corner beside the way into the menu.
    local band = box("details")
    check("the roster opens from the band itself",
          band and clock and clock.x > band.x
              and clock.x < band.x + band.w,
          band and string.format("band %.0f..%.0f, clock at %.0f",
                                 band.x, band.x + band.w, clock.x)
              or "no band press")
    check("and nothing in the corner row offers it a second time",
          band == nil or band.x > menu_key.x + menu_key.w,
          "a roster key is still beside MENU")

    -- The board opens under the band, wherever the band ends.
    frame(390, 844, {details = true})
    local heading, clock2 = word("PILOTS"), word("1:47")
    check("portrait starts the roster under the clock",
          heading and clock2 and heading.y > clock2.y,
          string.format("roster at %s, clock at %s",
                        tostring(heading and heading.y),
                        tostring(clock2 and clock2.y)))

    -- A window with room keeps the same band on the same line.
    frame(1440, 810)
    local wide_menu, wide_clock = box("open"), word("1:47")
    check("a wide window keeps the clock on the corner key's own line",
          wide_menu and wide_clock
              and math.abs(wide_clock.y - (wide_menu.y + wide_menu.h / 2)) < 24,
          string.format("clock at %s, key mid %s",
                        tostring(wide_clock and wide_clock.y),
                        tostring(wide_menu and wide_menu.y + wide_menu.h / 2)))
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
-- only thing that happens is that the room and the key appear.
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
        -- A way into the menu, because a directory that never answers must
        -- not leave a wordmark and no exit.
        local menu_key = box("open")
        check(shape .. " waiting keeps a way into the menu", menu_key ~= nil)
        if menu_key then
            check(shape .. " waiting puts that key where it always is",
                  menu_key.x < w / 2 and menu_key.y < h / 2,
                  string.format("%.0f,%.0f", menu_key.x, menu_key.y))
        end
        -- And nothing that needs a room: no key into one, and none of the
        -- instruments that describe one.
        check(shape .. " waiting offers no key to a room it has not found",
              box("play_now") == nil)
        check(shape .. " waiting draws no roster key", box("details") == nil)
        check(shape .. " waiting draws no radar", box("map") == nil)
        -- The name, and the word on the menu key where that key carries one.
        -- A phone's is the three bars alone, in either orientation, so there
        -- the name is the only word on the screen.
        local said = (shape == "desktop") and 2 or 1
        check(shape .. " waiting says nothing while it is only waiting",
              #words() == said,
              #words() .. " words on screen, wanted " .. said)
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

-- Opening the menu draws the panel over all of this, so the key underneath it
-- must not still be pressable: a press through a panel is a press nobody aimed.
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

print(fails == 0 and "all landing checks passed"
      or (fails .. " landing checks failed"))
os.exit(fails == 0 and 0 or 1)
