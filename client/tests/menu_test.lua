-- The menu's model: the column a pilot raises over a fight, and the pages its
-- stops open.
--
--     lua5.1 client/tests/menu_test.lua
--
-- The questions are the ones a hand asks. Does the leave stop hand the seat
-- back. Does it ask first when there is no seat left to hand back. Are the
-- sides the room's own sides in the room's own words. Does a setting move when
-- it is stepped, does a control move when a key answers it, and does a card
-- that was refused keep what was typed into it.
--
-- Nothing here is about pixels. column_test.lua draws this same column against
-- a recording layer and reads the boxes it publishes; this file is the model
-- under it, and the one cursor either of them has lives out there, over boxes
-- that were actually drawn. The panel's scrolling is scroll_test.lua, and the
-- card a question raises is drawn over the landing by `ui.land_card`, where
-- landing_test.lua reads it.
--
-- It replaces menu_nav_test.lua and menu_view_test.lua, which measured a
-- drawer: a rail of tabs, a stage beside it, a head row with an x on it, a
-- topbar, and a preview of the page the rail cursor was resting on. None of
-- those exist. Every check the two of them carried about the tree underneath
-- is here, and the ones that were about the drawer's own furniture are named
-- where they were dropped.

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

-- The world the menu talks to, as little of it as it asks for. `refuse` is
-- what the meta-layer would say no with; nil means every request lands.
local account = {
    name = "", aim = function() end,
    claimed = true, base = "https://meta",
    refuse = nil, password = nil, logged = nil, renamed = 0,
    profiles = {},
}
function account.online()
    return account.base ~= ""
end
function account.claim(password, cb)
    account.password = password
    if account.refuse == nil then account.claimed = true end
    if cb then cb(account.refuse == nil, account.refuse) end
end
function account.login(name, password, cb)
    account.logged = {name = name, password = password}
    if cb then cb(account.refuse == nil, account.refuse) end
end
function account.rename(cb)
    account.renamed = account.renamed + 1
    -- A refused draw wins no name, which is the whole of what the throttled
    -- reroll looks like from here.
    if account.refuse == nil then
        account.name = "Nimbus " .. (100 + account.renamed)
    end
    if cb then cb(account.refuse == nil, account.refuse) end
end
function account.logout()
    account.claimed = false
    account.name = ""
end
package.loaded["arena.account"] = account
local net = {
    teams = {}, my_team = 0, may_found = false,
    my_team_name = function() return "" end,
    transport = function() return {} end,
    -- The number the about page prints, read off the module that speaks the
    -- wire. Capitalized, because that is the name the page asks for: a stub
    -- answering `protocol` leaves the row saying nil.
    PROTOCOL = 5, invite = function() end,
}
package.loaded["arena.net"] = net
local rolled = 0
package.loaded["arena.callsign"] = {
    roll = function() return "Probe 1" end,
    seed = function() end,
    generate = function()
        rolled = rolled + 1
        return "Probe " .. rolled
    end,
}
package.loaded["arena.directory"] = {
    rows = {{zone = "chaos", name = "Chaos", detail = "a brawl",
             count = "0 playing", players = 0, bots = 51, live = true}},
    note = "", tick = function() end, aim = function() end,
    pilot_name = "",
    -- What a game is called, by its key, looked up in the games list the way
    -- the real one does: the label is the catalog's and the key is the wire's,
    -- and a stub that handed the key back would let a page ship the word
    -- "chaos" to somebody who chose Chaos off a list.
    label_of = function(zone)
        for _, r in ipairs(package.loaded["arena.directory"].rows or {}) do
            if r.zone == zone then return r.name or zone end
        end
        return zone
    end,
}
package.loaded["arena.sfx"] = {ui = function() end, master_gain = function() end,
                               music_gain = function() end}
-- What the last save wrote, so a test can ask what reached the disk rather
-- than what the module happens to be holding.
local saved
_G.sys = {get_config_string = function(_, d) return d end,
          get_config_int = function(_, d) return d end,
          get_engine_info = function() return {version = "test"} end,
          get_save_file = function() return "/tmp/vw-test-save" end,
          load = function() return {} end,
          save = function(_, d) saved = d return true end,
          get_sys_info = function() return {system_name = "Linux"} end}
_G.sound = setmetatable({}, {__index = function() return function() end end})
_G.html5 = nil
_G.hash = function(s) return s end

local menu = require("arena.menu")

-- The middle dot a reading puts between two facts, as `menu.sect_reading`
-- writes it.
local SEP = "\194\183"


-- --- the harness -----------------------------------------------------------

-- The column's stops, by name, in the order they are drawn.
local function stop_names()
    local out = {}
    for _, s in ipairs(menu.stops()) do out[#out + 1] = s.stop end
    return table.concat(out, "/")
end

local function stop_of(name)
    for _, s in ipairs(menu.stops()) do
        if s.stop == name then return s end
    end
    return nil
end

-- The column, raised, with a page open where one is named. The whole stack is
-- the stop that is open and whatever it opened, which is as deep as this tree
-- goes: a page climbs off its own stop rather than hanging under a root.
local function open(...)
    menu.open = true
    menu.ask = nil
    menu.stack = {}
    for _, id in ipairs({...}) do menu.stack[#menu.stack + 1] = id end
end

local function rows()
    return menu.view().rows
end

-- Where a row is, by the word on it. Rows are pressed by index, because that
-- is what a press carries: the drawing publishes the box and the index in it.
local function row_at(label)
    for i, r in ipairs(rows()) do
        if string.lower(r.label or "") == string.lower(label) then return i end
    end
    return nil
end

local function row_named(label)
    local i = row_at(label)
    return i and rows()[i] or nil
end

local function labels()
    local out = {}
    for _, r in ipairs(rows()) do out[#out + 1] = r.label end
    return table.concat(out, ", ")
end

-- --- the column's stops --------------------------------------------------
--
-- Who you are, where you are, who else is here, what you fly, and the
-- machine, top down in that order. There is one menu (decision 143): the
-- landing and the in-match column were the same drawing off two models, each
-- carrying the stop the other lacked, so the settings lived only in a match
-- and the account only on the front page.
--
-- The players stop was the one exception to that, dropped whenever this
-- client held no seat on the grounds that the room behind the front page was
-- somebody else's (decision 108). There is no front page and a watcher is in
-- the room, so the five are unconditional. See decisions 147 and 151.
--
-- SIDE is not here either. Crossing to another team is about the room rather
-- than about you, and the players sheet is where it went: a side is joined
-- from the card of somebody already on it.

menu.open = true
menu.adrift = false
menu.watching = false
menu.zone = "chaos"
menu.class = 0
menu.stack = {}
net.teams = {}

check("the column is five stops in a room",
      stop_names() == "account/zone/players/ship/settings", stop_names())

-- Where you stand in the room, which is what that stop answers with: your
-- side by the name the zone gave it, or the interface's own word when you
-- are on none. A side's name is quoted; "watching" is the interface talking.
menu.side = "Pylon"
local who_with = stop_of("players")
check("the players stop opens a panel and says which side you fly for",
      who_with.panel == true and who_with.value == "Pylon"
      and who_with.named == true, tostring(who_with.value))
menu.side = nil
check("and says so in its own word when you fly for none",
      stop_of("players").value == "watching"
      and stop_of("players").named == false,
      tostring(stop_of("players").value))

-- The answer on a stop is a name rather than a sentence about the stop, which
-- is the grammar every stop in this column speaks: the label asks and the
-- answer names. So the zone stop answers with the game you are in, in the
-- words the games list has for it, and the ship stop with the hull you are
-- flying.
local zone_stop = stop_of("zone")
check("the zone stop opens the games and says which one you are in",
      zone_stop.go == "zone" and zone_stop.value == "Chaos"
      and zone_stop.named == true,
      tostring(zone_stop.go) .. "/" .. tostring(zone_stop.value))

local ship_stop = stop_of("ship")
check("the ship stop opens a panel and says what you fly",
      ship_stop.panel == true and ship_stop.value == "Apex"
      and ship_stop.go == nil,
      tostring(ship_stop.value))

menu.watching = true
check("and the same five from the stands",
      stop_names() == "account/zone/players/ship/settings", stop_names())
menu.watching = false

-- Who you are, which the front page used to be the only screen to carry. It
-- opens the account acts as a page of the tree like any other.
local who = stop_of("account")
check("the account stop says the call sign and opens the acts",
      who.go == "account" and who.value == menu.name and who.named == true,
      tostring(who.value))

-- Settings is a page rather than a value, so it is the one stop here with
-- nothing to say in the slot the others put an answer in.
local machine = stop_of("settings")
check("the machine stop opens a page", machine.go == "settings",
      tostring(machine.go))
-- And nothing at all beside its name. It carried a gauge for a while, drawn
-- by the tab rail's mark table: a seventh right end in a language with six,
-- sitting on the caret it was drawn next to and saying the word already on the
-- row. `land_stop` gives a stop with no answer the ink instead.
check("and carries no answer and no mark",
      machine.value == nil and machine.mark == nil,
      tostring(machine.mark))

-- The view carries the same four, and says which one is holding a page open.
-- That is the whole of "where am I" now: a lit stop with its panel climbing
-- off it. The drawer answered it five ways at once, with a rail, a stage, a
-- topbar, a head and a preview, and those checks went with them.
open()
local v = menu.view()
check("the view carries the stops the column is drawn from",
      #v.stops == 5 and v.stops[1].stop == "account"
      and v.stops[5].stop == "settings", #v.stops .. " stops")
-- And what the one key does, which is the one thing on the column that reads
-- where this client is sitting rather than setting it.
check("a pilot with a seat is offered the stands",
      v.key == "spectate", tostring(v.key))
menu.watching = true
check("and anybody watching is offered a seat instead",
      menu.view().key == "play", tostring(menu.view().key))
menu.watching = false
-- And a seat with a ship drafted over it is offered the refit, which is the
-- one press that spends a draft in a match. It names the hull, because that
-- is the whole of what the press does. From the stands the key already means
-- "in whatever the ship stop says", so there is nothing to add out there.
-- See decision 154.
menu.draft_open()
menu.pick_profile(1)
check("a seat with a ship drafted over it is offered the refit",
      menu.view().key == "fly" and menu.view().key_ship == "Wedge",
      tostring(menu.view().key) .. " " .. tostring(menu.view().key_ship))
menu.watching = true
check("and the stands are offered the seat, with no hull to name",
      menu.view().key == "play" and menu.view().key_ship == nil,
      tostring(menu.view().key))
menu.watching = false
menu.draft_drop()
check("and a draft nobody touched leaves the key alone",
      menu.view().key == "spectate", tostring(menu.view().key))
check("and none of them is open over the bare column",
      not v.stops[1].open and not v.stops[2].open and not v.stops[3].open)
open("settings")
v = menu.view()
check("the stop whose page is up is the lit one",
      v.stops[5].open == true and v.stops[1].open == false,
      tostring(v.stops[5].open))
check("and the view still names who is reading, for the pages that need it",
      v.pilot ~= nil and v.pilot.name == menu.name,
      tostring(v.pilot and v.pilot.name))

-- --- raising it, and putting it away ---------------------------------------
--
-- One press puts the column up and one press takes it down. What walks back
-- through the pages is a level at a time, which is a different question with
-- its own key: escape asks `page_back` first and closes when there is no page
-- left to leave.

menu.open = false
menu.stack = {"settings", "controls"}
check("the key raises the column", menu.toggle() == true and menu.open)
-- It comes up on its bare stops every time, whatever was open last. A menu
-- that reopens where it was left is a menu that reopens on the controls board
-- a fortnight later, and the four stops are one press from anywhere anyway.
check("and always on its bare stops", #menu.stack == 0 and menu.at() == nil,
      table.concat(menu.stack, "/"))
check("and the same key puts it away", menu.toggle() == false and not menu.open)

open()
check("a bare column has no page open", menu.stop_open() == nil)
check("pressing a stop opens its page",
      select(2, menu.press_stop("settings")) == true
      and menu.stop_open() == "settings", table.concat(menu.stack, "/"))
-- Pressing the one already open shuts it, which is what the caret on the stop
-- draws.
check("and opening the open one shuts it",
      menu.open_stop("settings") == nil and #menu.stack == 0)
check("a stop the room is not offering answers nothing",
      select(2, menu.press_stop("nowhere")) == false)

open("settings")
check("there is a level to come back out of", menu.can_back() == true)
check("and coming out of the first one leaves the bare column standing",
      menu.page_back() == true and #menu.stack == 0)
check("with nothing left to come out of",
      menu.can_back() == false and menu.page_back() == false)

-- Closing forgets where you were, and everything the panel was holding. A
-- question left standing would be waiting on the next thing to open the menu,
-- which is a player pressing escape mid-fight and being asked something they
-- have forgotten; a control left waiting for a key holds the whole keyboard,
-- so behind a shut menu it would swallow the next press of anything.
open("settings", "controls")
menu.ask = {head = "?", keys = {{label = "ok"}}, sel = 1}
menu.arming, menu.foot = "map", "waiting"
check("closing forgets the page, the question and the key it was waiting for",
      menu.close() == true and not menu.open and #menu.stack == 0
      and menu.ask == nil and menu.arming == nil and menu.foot == nil,
      table.concat(menu.stack, "/"))

-- --- the way out of the room, and the card in front of it ------------------
--
-- The way out is a game off the zone stop's list, including the one you are
-- already in: leaving is choosing where to be instead. It costs the match
-- either way, so it asks. The card owns the keys while it is up, the answer
-- that changes nothing sits under the cursor, and escape answers it with that
-- one rather than shutting the panel.

open()
menu.adrift, menu.watching = false, false
menu.ask = nil
local act, moved = menu.press_stop("zone")
check("the zone stop opens the games rather than acting",
      act == nil and moved and menu.ask == nil and menu.at() == "zone",
      tostring(act))
check("and the list is the games the fleet is running",
      #rows() == 1 and rows()[1].label == "Chaos", labels())
check("with a mark on the one you are in", rows()[1].mark == true)

act, moved = menu.press_row(1)
check("and a game asks before it costs the match",
      act == nil and moved and menu.ask ~= nil, tostring(act))
check("naming the game it would leave for", menu.pending == "chaos")
check("and the card names the game in the words the games list has for it",
      string.find(menu.ask.head, "Chaos", 1, true) ~= nil, menu.ask.head)
check("the card offers leaving and staying, nothing else",
      #menu.ask.keys == 2 and menu.ask.keys[1].act == "leave_for",
      #menu.ask.keys .. " answers, first is "
          .. tostring(menu.ask.keys[1].act))
check("with the answer that changes nothing under the cursor",
      menu.ask.sel == #menu.ask.keys
      and menu.ask.keys[menu.ask.sel].act == nil,
      "on " .. tostring(menu.ask.sel) .. " of " .. tostring(#menu.ask.keys))
check("and the view carries it", menu.view().ask == menu.ask)

-- The answers sit side by side, so left and right are what they are laid out
-- along, but a hand that has been walking a list all the way here reaches for
-- down first. All four move between them.
menu.step({down = true})
check("the arrows move between the answers, whichever pair",
      menu.ask.sel == 1, "on " .. tostring(menu.ask.sel))
menu.step({left = true})
check("and back the other way", menu.ask.sel == 2,
      "on " .. tostring(menu.ask.sel))
menu.ask.sel = 1
act, moved = menu.step({go = true})
check("and the answer that leaves is a leave",
      act == "leave_for" and moved and menu.ask == nil, tostring(act))

-- Escape answers it rather than shutting the panel, and answers it with the
-- one that changes nothing: the key that gets out of everything else in here
-- has to get out of this without leaving the game by accident.
open("zone")
menu.press_row(1)
act, moved = menu.step({back = true})
check("escape answers the question instead of shutting the menu",
      act == nil and moved and menu.ask == nil and menu.open,
      tostring(act) .. ", open " .. tostring(menu.open))

-- A game the fleet is not serving is on the list all the same, and says two
-- things about itself. It cannot be flown to, which is what dims it, and it is
-- still being looked for, which is the dial the drawing puts at the end of the
-- row: the directory is asked again every three seconds and an arena can come
-- back to a game at any of them.
--
-- One list draws these rows wherever the column stands, so what is checked
-- here is the field the drawing reads: a row that only dimmed would be the
-- client saying it had given up when it has not.
do
    local dir = package.loaded["arena.directory"]
    dir.rows[#dir.rows + 1] = {zone = "war", name = "Capture the Flag",
                               teams = "4v4", count = "", players = 0,
                               bots = 0, live = false}
    open("zone")
    local up, down = row_named("Chaos"), row_named("Capture the Flag")
    check("a game with no arena behind it is still a row on the list",
          down ~= nil, labels())
    if up and down then
        check("and is dim, because it cannot be flown to",
              down.dim == true and not up.dim)
        check("and is being looked for, which is not the same thing",
              down.waiting == true and not up.waiting)
        check("while still saying what the game is",
              down.note == "4v4", tostring(down.note))
    end
    dir.rows[#dir.rows] = nil
end

-- --- settings, which are values rather than destinations -------------------
--
-- A setting carries a `choice`, where the value sits along its range, as well
-- as the word for it. The interface draws that range as steps and lights the
-- one it is on, which says "two of three" in the shape of the thing rather
-- than in a word that has to be read and compared against the row above.
--
-- Sound and music count their steps from off rather than from their first
-- value, so silence is an empty range. Lighting a box for off is a control
-- saying it is doing a little of something while doing none of it, and that is
-- the state somebody sets deliberately and then comes back wondering about.

open("settings")

-- One run of rows and nothing over them. The page grouped its rows under small
-- labels once, and six settings are not enough of a page to want chapters.
check("the settings page is one run of rows",
      (function()
          for _, r in ipairs(rows()) do
              if r.sect then return false end
          end
          return true
      end)())

menu.volume, menu.music = 3, 3
menu.apply_settings()
local sound_row = row_named("sound")
check("sound says the level it is on in a word",
      sound_row ~= nil and sound_row.detail == "half",
      tostring(sound_row and sound_row.detail))
check("and where that sits along its range, counted from off",
      sound_row.choice == 2 and sound_row.choices == 3,
      tostring(sound_row.choice) .. " of " .. tostring(sound_row.choices))
check("stepping it moves it one",
      select(2, menu.step_row(row_at("sound"), 1)) == true
      and menu.volume == 4, tostring(menu.volume))
check("and stepping back the other way puts it where it was",
      select(2, menu.step_row(row_at("sound"), -1)) == true
      and menu.volume == 3, tostring(menu.volume))
menu.step_row(row_at("sound"), -1)
menu.step_row(row_at("sound"), -1)
check("and off is an empty range rather than the first value of one",
      row_named("sound").detail == "off"
      and row_named("sound").choice == 0,
      tostring(row_named("sound").detail) .. " at "
          .. tostring(row_named("sound").choice))
menu.volume = 3

-- The soundtrack is its own row because wanting the game loud and the music
-- off is the commonest thing anybody wants out of a game's audio, and one
-- number cannot say it.
check("music is a row of its own", row_at("music") ~= nil, labels())
menu.press_row(row_at("music"))
check("and a press cycles it round its own range",
      menu.music == 4 and menu.volume == 3,
      tostring(menu.music) .. " with sound at " .. tostring(menu.volume))
menu.music = 3

-- A browser drives the frame loop from requestAnimationFrame, so on a 120 Hz
-- laptop the game renders twice as often as on a 60 Hz one and costs twice the
-- battery for it. Where the engine will not be asked, the row says what is
-- actually happening rather than offering a range that does nothing.
menu.can_cap = false
local frames = row_named("frames")
check("with no engine to ask, frames says the display is deciding",
      frames.detail == "as the display asks", tostring(frames.detail))
check("and offers no range to step", frames.choice == nil,
      tostring(frames.choice))
_G.sys.set_update_frequency = function() return true end
menu.apply_settings()
frames = row_named("frames")
check("with one, the row offers the caps it can be held to",
      menu.can_cap == true and frames.choices == 3 and frames.choice == 1,
      tostring(frames.detail) .. " at " .. tostring(frames.choice))
menu.step_row(row_at("frames"), 1)
check("and stepping it changes the cap", row_named("frames").detail
      == "60 a second", tostring(row_named("frames").detail))
menu.cap = 1
_G.sys.set_update_frequency = nil
menu.apply_settings()

-- Fullscreen is neither a value nor a page: it is a thing the arena does, so
-- the press hands the act straight back.
act, moved = menu.press_row(row_at("fullscreen"))
check("fullscreen is handed to the arena to carry out",
      act == "fullscreen" and moved, tostring(act))
check("and it has no range for an arrow to walk",
      select(2, menu.step_row(row_at("fullscreen"), 1)) == false)

-- The two rows that are destinations. A press descends; an arrow means
-- nothing on them, because left is the way back out and it has its own key.
act, moved = menu.press_row(row_at("controls"))
check("controls opens the board", act == nil and moved
      and menu.at() == "controls", table.concat(menu.stack, "/"))
menu.page_back()
check("about opens its readings",
      select(2, menu.press_row(row_at("about"))) == true
      and menu.at() == "about", table.concat(menu.stack, "/"))
menu.page_back()

-- The row that puts this on a home screen, in both of the forms it has. The
-- difference is not a choice we made: Chrome hands the page the install and
-- waits to be asked, Safari has no such call. install_test.lua holds what
-- pressing each of them does; what is read here is that the settings page
-- grows the row the browser's answer calls for and nothing else.
do
    local said = ""
    local install = require("arena.install")
    _G.html5 = {run = function(js)
        if string.find(js, "vwInstallState", 1, true) then return said end
        return ""
    end}
    local function state(s)
        said = s
        -- Past the cache, which holds an answer for a second of real time and
        -- none passes in here.
        install.tick(9)
        return row_named("add to home screen")
    end
    check("nothing to add on a machine with no home screen",
          state("") == nil)
    local tap = state("tap")
    check("a browser that will install offers one tap",
          tap ~= nil and tap.detail == "one tap",
          tap and tostring(tap.detail) or "no row")
    local share = state("share")
    check("and one that will not says it is going to explain instead",
          share ~= nil and share.detail == "how to",
          share and tostring(share.detail) or "no row")
    state("")
    _G.html5 = nil
end

-- --- the wake, and which key throws which charge --------------------------
--
-- The two things a pilot decides that are not about how a ship fights. They
-- sat under the drawer's roster, went to the settings page when the ship page
-- became a list of slots to spend credits on, and are the flair section of
-- the ship menu now: a section that costs nothing sits fine beside four that
-- do. See decision 112.

-- The one row the settings page kept nothing of.
open("settings")
check("settings has no ship band left", row_named("wake") == nil)

menu.wake = 0
local function flair_named(name)
    for _, r in ipairs(menu.sect_rows(menu.class or 0, "flair")) do
        if r.label == name then return r end
    end
    return nil
end
local function flair_at(name)
    for i, r in ipairs(menu.sect_rows(menu.class or 0, "flair")) do
        if r.label == name then return i end
    end
    return nil
end
local wake = flair_named("wake")
check("the wake says which trail this ship leaves",
      wake ~= nil and wake.detail == "standard"
      and wake.choices == #menu.WAKES, tostring(wake and wake.detail))
menu.flair_step(flair_at("wake"), 1)
check("and a press steps it round",
      menu.wake == 1 and flair_named("wake").detail == "long",
      tostring(flair_named("wake").detail))
menu.flair_step(flair_at("wake"), -1)
check("as does an arrow, the other way", menu.wake == 0,
      tostring(menu.wake))

-- A build that carries two kinds of charge leaves one thing for the pilot to
-- decide: which of the two keys spends which. The core numbers the kinds and a
-- build carries counts by kind, so without a preference the first key always
-- throws the lower-numbered one, whatever the pilot would rather have.
do
    local kept_core = _G.sim
    local two = {}
    for i = 1, 23 do two[i] = 0 end
    two[20], two[21] = 2, 1        -- two kinds aboard
    local one = {}
    for i = 1, 23 do one[i] = 0 end
    one[20] = 3                    -- one kind, so nothing to trade
    local carried = two
    _G.sim = {
        UP_COUNT = 5, TRIG_COUNT = 2, MOD_COUNT = 6, MAX_CHARGES = 4,
        MOD_MULTI = 0, SLOT_COUNT = 23, SLOT_LEVEL0 = 5, SLOT_MOD0 = 7,
        SLOT_CHARGE0 = 19, KIT_CREDITS = 7,
        class_kit = function() return carried end,
        slot_cap = function(_, slot) return slot >= 19 and 3 or 5 end,
    }
    menu.charge_flip = false
    menu.class = 0

    local function keys_row()
        for _, r in ipairs(menu.sect_rows(menu.class or 0, "flair")) do
            if r.label == "charge keys" then return r end
        end
        return nil
    end
    local row = keys_row()
    check("a hull carrying two kinds gets a row for the keys", row ~= nil,
          "no row")
    local said = row and row.detail
    check("and the row says which kind the first key throws",
          said ~= nil and said:find("first") ~= nil, tostring(said))
    menu.swap_charges()
    check("swapping trades the two",
          menu.charge_flip == true and keys_row().detail ~= said,
          tostring(keys_row() and keys_row().detail))
    menu.swap_charges()
    check("and swapping back puts them where they were",
          keys_row().detail == said, tostring(keys_row().detail))

    -- One kind aboard is nothing to trade, so the row is not there at all: a
    -- control that cannot do anything is worse than no control.
    carried = one
    check("a hull carrying one kind gets no row", keys_row() == nil)
    check("and the act refuses on it", select(2, menu.swap_charges()) == false)

    menu.charge_flip = false
    _G.sim = kept_core
end

-- --- a control asks, and the next key answers -----------------------------
--
-- Two presses, not one. The row stops saying where its control is and starts
-- asking where it should go, and the key pressed after that is the answer. The
-- page used to draw a keyboard as well, and a click on a key was the same act
-- arriving by pointer; that picture came out at 15 points a key on a phone and
-- this is the whole of the gesture now.
--
-- Rows are pressed here the way a thumb presses them, through `press_row`,
-- because arming is a branch of the press and reaching past it would leave the
-- one press that starts this untested.

do
    local binds = require("arena.binds")
    local keyset = require("arena.keys")
    binds.reset()
    menu.touching = false
    open("settings", "controls")

    local page = rows()
    local catalog = binds.rows()
    local drift = {}
    for i, control in ipairs(catalog) do
        local row = page[i]
        if not row or row.label ~= control.name or row.detail ~= control.show
           or row.control ~= control.id or row.fixed ~= control.fixed then
            drift[#drift + 1] = control.id
        end
    end
    check("the controls page is built from the live binding catalog",
          #drift == 0 and #page == #catalog + 1 and page[#page].reset == true,
          table.concat(drift, ", "))

    local map_at, menu_at = nil, nil
    for i, r in ipairs(page) do
        if r.control == "map" then map_at = i end
        if r.control == "menu" then menu_at = i end
    end
    check("the controls page lists the map key", map_at ~= nil)

    -- Pressing the row is the half that asks. Nothing is bound by it.
    menu.press_row(map_at)
    check("pressing a control row sets it asking",
          menu.arming == "map" and binds.chord_of.map[1] ~= "z",
          tostring(menu.arming))
    check("and the page says what it is waiting for",
          (menu.foot or ""):find("press a key") ~= nil, tostring(menu.foot))
    check("and the view says a key is being waited for",
          menu.view().arming == true and menu.view().foot == menu.foot,
          tostring(menu.view().arming))

    -- A key nothing is using. The control moves and the asking is over.
    local landed = menu.bind_chord({"z"})
    check("a free key moves the control that was asking",
          landed and binds.chord_of.map[1] == "z" and menu.arming == nil,
          table.concat(binds.chord_of.map, "+"))
    check("and the page says so", (menu.foot or ""):find("map is on Z") ~= nil,
          tostring(menu.foot))

    -- A key somebody else is on: the two trade, and nothing is left over. That
    -- is the property that makes this safe with no confirmation on it, and a
    -- pilot who put `map` on W would otherwise have to hunt for their charge.
    menu.press_row(map_at)
    local traded = menu.bind_chord({"d"})
    check("a taken key trades", traded
          and binds.chord_of.map[1] == "d"
          and binds.chord_of.guns[1] == "z",
          table.concat(binds.chord_of.map, "+") .. " / "
          .. table.concat(binds.chord_of.guns, "+"))
    check("and the foot names what took the keys it left",
          (menu.foot or ""):find("guns took") ~= nil, tostring(menu.foot))

    -- The menu key is nobody's to move, and the row says why rather than doing
    -- nothing. It refuses at the asking rather than at the answer: a control
    -- that will not move never starts waiting for a key at all.
    menu.arming, menu.note = nil, nil
    menu.press_row(menu_at)
    check("the menu control refuses to start asking and says why",
          menu.arming == nil and binds.chord_of.menu[1] == "esc"
          and (menu.note or ""):find("escape") ~= nil,
          tostring(menu.note))
    check("and escape is not a key anything could be put on",
          not keyset.bindable("esc"))

    -- A key with nothing asking is a key the page is not listening for. It
    -- lands nowhere rather than on whatever the cursor happens to be over.
    menu.arming = nil
    local stray = menu.bind_chord({"j"})
    check("a key arriving with nothing asking binds nothing",
          stray == false and binds.control_of.j == nil,
          tostring(stray))

    -- A chord is two keys held together, which is a thing a keyboard can say
    -- and the rest of this interface cannot.
    menu.press_row(map_at)
    local chorded = menu.bind_chord({"shift", "j"})
    check("a chord typed at an asking control lands whole",
          chorded and table.concat(binds.chord_of.map, "+") == "shift+j",
          table.concat(binds.chord_of.map, "+"))

    -- A key with no trigger under it is a key a control would vanish onto.
    check("and the catalog only takes keys that report",
          keyset.bindable("backslash") and keyset.bindable("slash")
          and not keyset.bindable("caps") and not keyset.bindable("enter"))

    -- Escape while a control is asking goes back to where it was, which is the
    -- answer that changes nothing here as everywhere else.
    menu.press_row(map_at)
    check("escape leaves an asking control where it is",
          menu.cancel_bind() == true and menu.arming == nil
          and menu.foot == nil, tostring(menu.arming))
    check("and means nothing when nothing is asking",
          menu.cancel_bind() == false)

    -- Last, and after every control, because it is about all of them.
    menu.press_row(#rows())
    check("the last row puts every key back where it started",
          binds.chord_of.map[1] == "m"
          and (menu.foot or ""):find("back where") ~= nil,
          table.concat(binds.chord_of.map, "+") .. ", " .. tostring(menu.foot))

    -- The rows the page holds and the rows it hands the drawing are two
    -- shapes, and the second is built by copying named fields out of the
    -- first. A field renamed on one side and not the other is invisible from
    -- both: the page goes on holding the right answer and the drawing goes on
    -- asking for a name nothing sets. That shipped once, when the page still
    -- drew a keyboard, and every key on the board came out unlit.
    binds.set("map", {"shift", "tab"})
    local mute, adrift = {}, {}
    for _, r in ipairs(rows()) do
        if not r.reset then
            if not (r.detail and r.detail ~= "") then
                mute[#mute + 1] = tostring(r.label)
            end
            if not r.control or r.act ~= "bind" then
                adrift[#adrift + 1] = tostring(r.label)
            end
        end
    end
    check("every drawn row says the key it is on", #mute == 0,
          table.concat(mute, ", "))
    check("and which control a press on it would move", #adrift == 0,
          table.concat(adrift, ", "))
    local map_row = nil
    for _, r in ipairs(rows()) do
        if r.control == "map" then map_row = r end
    end
    check("a chord reaches the drawing with both its keys",
          map_row ~= nil and map_row.detail == "Shift+Tab",
          map_row and tostring(map_row.detail) or "no map row")

    -- And the way in is a keyboard's. There is no key to bind on glass, and
    -- the page a phone used to get was a list of the pads it was already
    -- holding: the pads say what they are by being drawn, and the stick
    -- writes its own gesture around its rim.
    local function offers_controls()
        open("settings")
        return row_at("controls") ~= nil
    end
    check("the settings page offers the board where there are keys",
          offers_controls(), labels())
    menu.touching = true
    check("and not on glass", not offers_controls(), labels())
    menu.touching = false
    open("settings", "controls")
    binds.reset()
    menu.foot, menu.note = nil, nil
end

-- --- about, which is what this build is rather than what the game is ------
--
-- The page used to be six lines explaining energy and the score, which is what
-- help is for, and one build number at the bottom. Anybody who opens it in a
-- game that updates several times a day wants to know which build they are
-- looking at and what it is talking to, and that is the one question no other
-- screen answers.

open("settings", "about")
do
    local said = {}
    for _, r in ipairs(rows()) do said[string.lower(r.label or "")] = r end
    local want = {"build", "wire", "protocol", "line", "engine", "screen",
                  "viewport", "zone", "account"}
    local missing = {}
    for _, w in ipairs(want) do
        if not said[w] then missing[#missing + 1] = w end
    end
    check("about carries the readings a player opens it for", #missing == 0,
          table.concat(missing, ", "))
    check("the build is quoted rather than said",
          said.build.verbatim == true and said.build.detail == "dev",
          tostring(said.build.detail))
    check("and the protocol is read off the module that speaks the wire",
          said.protocol.detail == "5", tostring(said.protocol.detail))
end

-- Which of the two doors this connection came through, and what that door is
-- made of. The difference is worth a line because it is the difference a
-- player feels on a bad link: QUIC loses a packet and delays only that packet,
-- TCP loses one and holds everything behind it.
net.transport = function() return {kind = "wt"} end
check("the wire says which door the game came through",
      row_named("wire").detail == "webtransport, quic datagrams",
      tostring(row_named("wire").detail))
-- And why this pilot is on the slower one, in the two forms that want
-- different things looked at. A dial that went unanswered just now points at
-- the network; a dial this join never made points at the one before it, and
-- reading the first for the second sends somebody to interrogate a firewall
-- about packets nobody sent.
net.transport = function()
    return {kind = "ws", secure = true, refused = true, offered = true,
            tried = true}
end
check("and says why it is on the slower one when it is",
      row_named("wire").detail == "websocket, tls over tcp (quic did not answer)",
      tostring(row_named("wire").detail))
net.transport = function()
    return {kind = "ws", secure = true, refused = true, offered = true}
end
check("and tells a dial never made from one that went unanswered",
      string.find(row_named("wire").detail, "not retried", 1, true) ~= nil,
      tostring(row_named("wire").detail))
net.transport = function() return {} end

-- No address anywhere on it. Whoever runs the fleet reads logs; a player
-- reading a wss url is reading something not addressed to them, which is the
-- same call the empty games list makes. The zone reading is the games list's
-- own label for a room, never the key the wire uses or the address behind it.
menu.zone = "chaos"
check("the zone reading is the game's name rather than its key",
      row_named("zone").detail == "Chaos",
      tostring(row_named("zone").detail))
do
    local bare, seen = {}, 0
    for _, where in ipairs({{"settings"}, {"settings", "controls"},
                            {"settings", "about"}, {"side"}}) do
        local page = where[#where]
        open(unpack(where))
        for _, r in ipairs(rows()) do
            seen = seen + 1
            local d = type(r.detail) == "string" and r.detail or ""
            if string.find(d, "://", 1, true) then
                bare[#bare + 1] = page .. "/" .. tostring(r.label)
            end
            -- And nothing carries a live address for the page to lay an
            -- anchor over. One row did: the invite on the community page,
            -- because nothing this client does from its own loop is inside
            -- the tap that asked for it and every phone called a frame-late
            -- window.open a popup.
            if r.link then bare[#bare + 1] = page .. "/link" end
        end
    end
    check("no reading on any page spells out an address",
          #bare == 0 and seen > 0,
          #bare > 0 and table.concat(bare, ", ") or "no rows read")
end

-- The two documents, which are the only way out of the game left in it. They
-- are on about because the account is minted before a player has a reason to
-- visit the bare site.
do
    local asked
    for label, url in pairs({privacy = "https://vectorwake.net/privacy",
                             terms = "https://vectorwake.net/terms"}) do
        asked = nil
        menu.ask = nil
        _G.sys.open_url = function(got, attrs)
            asked = {url = got, target = attrs and attrs.target}
            return true
        end
        open("settings", "about")
        local at = row_at(label)
        check("about carries " .. label, at ~= nil, "absent")
        if at then menu.press_row(at) end
        check(label .. " opens the public document",
              asked and asked.url == url and asked.target == "_blank",
              asked and asked.url or "nothing asked")
    end

    -- Nothing is put on screen when the browser says no: a card with the
    -- address and an OK on it is what a phone actually got, and a card is not
    -- a link.
    menu.ask = nil
    menu.note = nil
    _G.sys.open_url = function() return false end
    open("settings", "about")
    menu.press_row(row_at("terms"))
    check("a refusal puts nothing on screen", menu.view().ask == nil,
          tostring(menu.view().ask and menu.view().ask.head))

    -- And an engine with no open_url at all does not take the menu down.
    _G.sys.open_url = nil
    open("settings", "about")
    local at = row_at("privacy")
    check("an engine without open_url survives the press",
          at ~= nil and pcall(menu.press_row, at))
end

-- A browser navigates the tab it is in. A new tab asked for from the game loop
-- is outside the original tap, and mobile browsers block it.
do
    local js
    _G.html5 = {run = function(code) js = code return "" end}
    for label, url in pairs({privacy = "https://vectorwake.net/privacy",
                             terms = "https://vectorwake.net/terms"}) do
        js = nil
        open("settings", "about")
        menu.press_row(row_at(label))
        check("a browser navigates to " .. label,
              js and js:find("window.location.assign", 1, true)
                  and js:find(url, 1, true),
              tostring(js))
    end
    _G.html5 = nil
end

-- --- the account, which is the column's first stop ------------------------
--
-- These acts left the drawer with the pilot page (decision 99) and stood on
-- the landing alone until the menus were unified (decision 143). They are a
-- page of the tree now, pressed by index like every other row here, and what
-- they do is unchanged.

menu.ask = nil
menu.adrift, menu.watching = false, true
menu.zone = ""
open()
account.claimed = false

local function account_labels()
    local out = {}
    for _, r in ipairs(menu.account_rows()) do
        out[#out + 1] = r.rule and "--" or r.label
    end
    return table.concat(out, ", ")
end
-- Pressed the way the interface presses one: the account page open on the
-- column, and a row of it named by where it stands in the list the frame
-- drew.
local function account_act(label)
    open("account")
    for i, r in ipairs(menu.account_rows()) do
        if r.label == label then return (menu.press_row(i)) end
    end
    return nil
end

check("a guest is offered the sign up, the reroll and the login",
      account_labels() == "sign up, new name, --, log in",
      account_labels())
-- Signing up and claiming this account are one act: the server has one
-- endpoint for it and what it does is put a password on the account this
-- client already holds. So one row, in the player's word for it.
check("and the offer leads the list, with what it buys beside it",
      menu.account_rows()[1].offer == true
          and menu.account_rows()[1].note == "keep your points",
      tostring(menu.account_rows()[1].note))

-- --- a password is typed into a card, and the card is the whole flow -------
--
-- The only text entry in this client. Claiming asks for one line, logging in
-- for two; enter sends, escape cancels, and a refusal turns the card into the
-- refusal without eating what was typed.

account_act("sign up")
check("signing up asks for a password, discs and all",
      menu.ask ~= nil and menu.ask.fields ~= nil
          and #menu.ask.fields == 1 and menu.ask.fields[1].mask == true,
      tostring(menu.ask and menu.ask.fields and #menu.ask.fields))
check("and the card says what signing up buys",
      menu.ask.note == "keep your points and log in on other devices",
      tostring(menu.ask.note))
-- A card raised to be filled in starts on the answer that sends it, unlike a
-- plain question: the whole point of raising one is to fill it in and send it.
check("with the sending answer under the cursor", menu.ask.sel == 1
          and menu.ask.keys[1].act == "do_claim",
      tostring(menu.ask.sel))

check("a letter lands in the field", menu.type_field("h")
          and menu.ask.fields[1].value == "h", menu.ask.fields[1].value)
check("case is the typist's own", menu.type_field("U")
          and menu.ask.fields[1].value == "hU", menu.ask.fields[1].value)
check("a control character is refused", menu.type_field("\t") == false
          and menu.ask.fields[1].value == "hU", menu.ask.fields[1].value)
check("backspace takes one back",
      menu.rub_field() and menu.ask.fields[1].value == "h",
      menu.ask.fields[1].value)
for ch in string.gmatch("unter2", ".") do menu.type_field(ch) end

account.refuse = nil
menu.step({go = true})
check("enter sends the claim and takes the card down",
      account.password == "hunter2" and menu.ask == nil and account.claimed,
      tostring(account.password) .. ", ask " .. tostring(menu.ask))

-- A refusal keeps the card and what was typed: the next thing anybody does
-- with a refused password is fix it, not retype it.
account.claimed = false
account.refuse = "a password needs at least six characters"
menu.ask_password()
for ch in string.gmatch("abc", ".") do menu.type_field(ch) end
menu.step({go = true})
-- On its own line rather than in the head. A card with lines to fill in is a
-- panel now (decision 104), and a panel's head is the name of the section with
-- the way back on it: a reason written there costs a pilot both of those
-- exactly when a press has just failed and they most need the way out.
check("a refusal keeps the card up with the reason on it",
      menu.ask ~= nil and menu.ask.status == account.refuse .. "."
          and menu.ask.fields[1].value == "abc",
      tostring(menu.ask and menu.ask.status))
check("and the head goes on naming the section",
      menu.ask ~= nil and menu.ask.head == "sign up",
      tostring(menu.ask and menu.ask.head))
account.refuse = nil
menu.ask = nil

-- --- logging in is two lines, walked with the arrows ----------------------

account_act("log in")
check("logging in asks for a name in the clear and a password in discs",
      menu.ask ~= nil and menu.ask.fields ~= nil and #menu.ask.fields == 2
          and not menu.ask.fields[1].mask and menu.ask.fields[2].mask,
      tostring(menu.ask and menu.ask.fields and #menu.ask.fields))

for ch in string.gmatch("Vesper 412", ".") do menu.type_field(ch) end
check("the name takes its space", menu.ask.fields[1].value == "Vesper 412",
      menu.ask.fields[1].value)
-- On a card with lines to fill in, up and down walk the lines and left and
-- right walk the answers, so an arrow never does nothing.
menu.step({down = true})
check("down moves to the password line", menu.ask.field == 2,
      tostring(menu.ask.field))
for ch in string.gmatch("hunter2", ".") do menu.type_field(ch) end
check("and the typing follows the focus",
      menu.ask.fields[2].value == "hunter2"
          and menu.ask.fields[1].value == "Vesper 412",
      menu.ask.fields[2].value)
menu.step({up = true})
check("up walks back", menu.ask.field == 1, tostring(menu.ask.field))

menu.step({go = true})
check("enter logs in with both lines",
      account.logged ~= nil and account.logged.name == "Vesper 412"
          and account.logged.password == "hunter2" and menu.ask == nil,
      tostring(account.logged and account.logged.name))

-- The wrong pair comes back as the same card wearing the refusal.
account.refuse = "that name and password do not match"
menu.ask_login()
for ch in string.gmatch("Vesper 412", ".") do menu.type_field(ch) end
menu.step({down = true})
for ch in string.gmatch("wrong", ".") do menu.type_field(ch) end
menu.step({go = true})
check("a wrong pair keeps the card and both lines",
      menu.ask ~= nil and menu.ask.fields[1].value == "Vesper 412"
          and menu.ask.fields[2].value == "wrong",
      tostring(menu.ask and menu.ask.head))
check("and escape still walks away",
      select(2, menu.step({back = true})) == true and menu.ask == nil,
      tostring(menu.ask))
account.refuse = nil

-- --- signed in, the list changes shape ------------------------------------

account.claimed = true
check("a claimed pilot is offered the password, the reroll and the way out",
      account_labels() == "set password, new name, --, log off",
      account_labels())
account_act("log off")
check("logging off asks first", menu.ask ~= nil and menu.ask.fields == nil,
      tostring(menu.ask))
menu.ask.sel = 1
menu.step({go = true})
check("and the answer that leaves actually leaves",
      account.claimed == false and menu.ask == nil,
      tostring(account.claimed))

-- Without a meta-layer there is nothing to sign up to, so the list is the one
-- act that has an offline answer of its own.
do
    local kept = account.base
    account.base = ""
    check("with no account layer the list is the reroll alone",
          account_labels() == "new name", account_labels())
    account.base = kept
end

-- --- and the one act on that list that throws something away --------------
--
-- A call sign is the only name anybody here has, and it is the name on the
-- scoreboard of every game this pilot has flown. The row showed it and
-- replaced it on the press, with nothing said and nothing to say no to.

menu.chosen = nil
menu.ask = nil
local was = menu.name
act = account_act("new name")
check("rolling a call sign asks first",
      act == nil and menu.ask ~= nil and menu.name == was,
      tostring(act) .. ", name " .. tostring(menu.name))
-- Watching, the card asks only about the name; there is no ship to cost.
check("and from the stands says nothing about respawning",
      not string.find(menu.ask.head, "respawns"), menu.ask.head)
menu.step({back = true})
check("and escape keeps the one you have",
      menu.name == was and menu.ask == nil, tostring(menu.name))
account_act("new name")
menu.ask.sel = 1
act, moved = menu.step({go = true})
check("rolling rolls, and the arena is never told",
      menu.name ~= was and act == nil and moved,
      tostring(was) .. " -> " .. tostring(menu.name) .. ", act "
          .. tostring(act))

-- The cap the server keeps on rerolling, which anybody enjoying the names
-- reaches: thirty an hour from one address. The refusal has to land on the
-- card, because the alternative is what this used to do, which is stop
-- changing the name and say nothing at all about why.
account.refuse = "that is plenty of rerolling. Try again later"
local held = menu.name
local rolls = account.renamed
account_act("new name")
menu.ask.sel = 1
menu.step({go = true})
check("a refused roll keeps the card up wearing the reason",
      menu.ask ~= nil and menu.ask.head == account.refuse .. "."
          and menu.name == held,
      tostring(menu.ask and menu.ask.head) .. ", name " .. tostring(menu.name))
check("and the server was asked", account.renamed == rolls + 1,
      tostring(account.renamed))
-- Still sending would mean the card refuses every answer, which is a refusal
-- you cannot get out of.
check("and the card takes answers again",
      menu.ask ~= nil and menu.ask.sending == false,
      tostring(menu.ask and menu.ask.sending))
check("and escape walks away from the refusal",
      select(2, menu.step({back = true})) == true and menu.ask == nil,
      tostring(menu.ask))
account.refuse = nil

-- Mid-game the same card owes one more sentence. A new name is a new pilot,
-- and a new pilot gets a fresh seat: the client rejoins the game on its own,
-- which costs the ship. The card is the one place that can say so before it
-- happens, and this is the act whose whole design is asking first.
menu.watching = false
account_act("new name")
check("flying, the card says a roll respawns your ship",
      menu.ask ~= nil
      and string.find(menu.ask.head, "respawns your ship") ~= nil,
      tostring(menu.ask and menu.ask.head))
menu.step({back = true})
menu.watching = true
menu.ask = nil

-- --- what the page holds, when the page is holding it ---------------------
--
-- In a browser the lines are input elements on the page rather than strings in
-- here, because a canvas cannot raise a phone's keyboard and an input element
-- can, and because a password manager can fill a form and cannot fill a
-- drawing. Nothing above changes: the send still reads `fields[i].value`. What
-- changes is where those values come from, which is one crossing at the moment
-- the card is answered.
--
-- Worth a test of its own because it is the one path where every character a
-- player typed lives outside this program until the instant it is needed, and
-- the failure is silent: an empty send, refused by the server, looks exactly
-- like a wrong password.

do
    local ran = {}
    _G.html5 = {run = function(code)
        ran[#ran + 1] = code
        if string.find(code, "vwAskRead", 1, true) then
            return "Vesper 412\nhunter2!#"
        end
        return ""
    end}

    account.refuse = nil
    account.logged = nil
    menu.dom = true
    menu.ask_login()
    check("nothing typed into this side", menu.ask.fields[1].value == "",
          menu.ask.fields[1].value)
    menu.step({go = true})
    check("the page's text is what gets sent",
          account.logged ~= nil and account.logged.name == "Vesper 412"
              and account.logged.password == "hunter2!#",
          tostring(account.logged and account.logged.name) .. " / "
              .. tostring(account.logged and account.logged.password))
    check("punctuation among it, which no drawn keyboard offered",
          account.logged ~= nil
              and string.find(account.logged.password, "!", 1, true) ~= nil,
          tostring(account.logged and account.logged.password))

    -- And not otherwise. A keyboard's own lines are read from this side, and a
    -- crossing made anyway would overwrite them with whatever an absent form
    -- said, which is nothing.
    ran = {}
    menu.dom = false
    account.logged = nil
    menu.ask_login()
    for ch in string.gmatch("Torrent 65", ".") do menu.type_field(ch) end
    menu.step({down = true})
    for ch in string.gmatch("secret1", ".") do menu.type_field(ch) end
    menu.step({go = true})
    check("a keyboard's lines are not asked of the page", #ran == 0,
          table.concat(ran, " ; "))
    check("and are sent as typed",
          account.logged ~= nil and account.logged.name == "Torrent 65"
              and account.logged.password == "secret1",
          tostring(account.logged and account.logged.name))
    _G.html5 = nil
end

-- --- a card owns the keys, and the column is walked somewhere else ---------
--
-- `M.step` reads a question and nothing else. Walking the column is ui.lua's,
-- over the boxes the drawing published, which is how the landing has always
-- been walked: one cursor over what is actually on the screen rather than a
-- second tree of rows kept in step with the drawing by hand.
--
-- What went with the drawer was a rail axis, a head row, a grid branch no page
-- set, and a call to `rub_new` that has never existed: backspace with the
-- panel up and nothing asking raised `attempt to call a nil value` in the
-- arena's input handler.

open("settings")
menu.ask = nil
act, moved = menu.step({down = true})
check("an arrow with no question up moves nothing",
      act == nil and moved == false, tostring(moved))
act, moved = menu.step({rub = true})
check("and backspace with nothing to rub answers the same",
      act == nil and moved == false, tostring(moved))
check("this file holds no cursor of its own",
      menu.sel == nil and menu.head_sel == nil and menu.hover == nil
      and menu.click_stage == nil and menu.click_rail == nil,
      "a second cursor survives in the model")

-- --- the guest warning arms only when there is something to lose ----------
--
-- A rating is the only durable thing a pilot has, so the question is whether
-- they have started earning one. Before there is anything to lose the warning
-- stays away, because a warning over an empty account is nagging.
--
-- The band the drawer drew across every page went with the drawer. The same
-- question is a dot on the landing's account stop now, which landing_test.lua
-- reads; what is left here is the rule underneath it.
do
    local kept = {claimed = account.claimed, rated = account.rated,
                  pilots = net.pilots, me = net.me}
    account.claimed, account.rated = false, nil
    net.pilots, net.me = {}, 0
    check("a fresh guest has nothing to lose", menu.guest_stakes() == false)
    account.rated = true
    check("a rated zone on the session arms the warning",
          menu.guest_stakes() == true)
    account.claimed = true
    check("and signing up takes it down", menu.guest_stakes() == false)

    -- The other half, and the one the warning is really for: a guest whose
    -- first rated game lands in the room they are sitting in. The session
    -- said no and cannot be asked again mid-match, so the roster is what
    -- arms it, off the games flown in this seat.
    account.claimed, account.rated = false, false
    net.me = 3
    net.pilots = {[3] = {games = 0}}
    check("a seat that has flown nothing leaves it down",
          menu.guest_stakes() == false)
    net.pilots = {[3] = {games = 1}}
    check("and the first rated game on the roster arms it",
          menu.guest_stakes() == true)
    -- A watcher holds no seat, so there is no row to read and nothing to say.
    net.me = 255
    check("a watcher with no seat is not warned",
          menu.guest_stakes() == false)

    account.claimed, account.rated = kept.claimed, kept.rated
    net.pilots, net.me = kept.pilots, kept.me
end

-- --- what a tick tidies up ------------------------------------------------
--
-- A control can only be waiting for a key on the page that asked, with nothing
-- over it. A pointer can leave that page without ever pressing one, since the
-- keyboard is taken and the mouse is not, so the state is let go here rather
-- than in each of the four ways out.

open("settings", "controls")
menu.arming, menu.foot = "map", "press a key"
menu.tick(0.1)
check("a control goes on waiting while its own page is up",
      menu.arming == "map" and menu.foot == "press a key",
      tostring(menu.arming))
menu.ask = {head = "?", keys = {{label = "ok"}}, sel = 1}
menu.tick(0.1)
check("a card over the page takes the key it was waiting for",
      menu.arming == nil, tostring(menu.arming))
menu.ask = nil
menu.arming, menu.foot = "map", "press a key"
open("settings")
menu.tick(0.1)
check("and leaving the page lets go of it",
      menu.arming == nil and menu.foot == nil,
      tostring(menu.arming) .. "/" .. tostring(menu.foot))

-- A stop the column no longer carries is a page you are no longer in. All
-- five are unconditional now, so nothing arrives or leaves under a hand; what
-- this holds is that a stack pointed at a page the column does not draw is not
-- a menu somebody can be stranded in.
menu.adrift, menu.watching = false, false
open("zone")
menu.tick(0.1)
check("a page whose stop is still offered stays open",
      menu.stop_open() == "zone", table.concat(menu.stack, "/"))
menu.stack = {"nowhere"}
menu.tick(0.1)
check("and one whose stop has gone is dropped",
      menu.stop_open() == nil and #menu.stack == 0,
      table.concat(menu.stack, "/"))

-- --- is there still a row there -------------------------------------------
--
-- A press is tested against hit boxes the previous frame published, and some
-- of these lists are rebuilt underneath them: a zone can leave the directory
-- between the drawing and the press. The cursor itself is ui.lua's, standing
-- on a box that was actually drawn; this is the one question about a row that
-- only the file holding the rows can answer.

local dir = package.loaded["arena.directory"]
local all_zones = dir.rows
dir.rows = {
    {zone = "chaos", name = "Chaos", live = true},
    {zone = "duel", name = "Duel", live = true},
}
open("zone")
check("a row that is there is there", menu.has_row(2) == true)
dir.rows = {{zone = "chaos", name = "Chaos", live = true}}
check("and one the wire has taken away is not", menu.has_row(2) == false)
check("and a press on the row that went answers nothing",
      select(2, menu.press_row(2)) == false)
open()
check("a bare column holds no rows at all", menu.has_row(1) == false)
dir.rows = all_zones

-- --- the ship panel, which is the landing's rather than the column's -------
--
-- The drawer had a ship page: seven hulls down a column with their flight bars
-- and what they carried. It went with the drawer, and so did the tab that
-- opened it. What replaced it is the landing's own ship stop, which pages one
-- hull at a time and carries the rows that spend its credits. It is built here
-- and drawn out there, so it is read here. See decision 100.
--
-- The core is stubbed, because everything on this panel is read off it: what a
-- hull flies with, how high a slot goes, and what a step of a stat is worth. A
-- page that made any of that up here would draw a key the arena refuses.

do
    local kept_core = _G.sim
    _G.sim = {
        SLOT_COUNT = 23, TRIG_COUNT = 2, MOD_COUNT = 6, MOD_MULTI = 0,
        SLOT_LEVEL0 = 5, SLOT_MOD0 = 7, SLOT_CHARGE0 = 19, MAX_CHARGES = 4,
        UP_STEPS = 8, KIT_CREDITS = 7,
        -- Two hulls apart on every row, so the shares are not all 1.
        class_flight = function(cls)
            local k = (cls % 3) + 1
            return 1000 * k, 100 * k, 200 * k, 1500 * k, 900 * k
        end,
        class_kit = function()
            local out = {}
            for i = 1, 23 do out[i] = 0 end
            -- The row a pilot arrives on, which is the core's and the same in
            -- every hull: both weapons a rung up, a bouncing gun, a fused
            -- bomb throwing fragments, and one of each charge. Seven credits.
            out[6], out[7] = 1, 1        -- the two levels
            out[9] = 1                   -- gun bounce
            out[16], out[17] = 1, 1      -- bomb prox and shrapnel
            out[20], out[21] = 1, 1      -- one repel, one burst
            return out
        end,
        -- Flight steps nothing, as the shipped roster does not, so no stat row
        -- is offered; the mods and the rack are what a pilot can reach.
        class_up_step = function() return {0, 0, 0, 0, 0} end,
        -- The shipped ladder: ShrapnelRate is two fragments and every rung
        -- above it doubles. Stubbed because the reading is the one number on
        -- the panel that is not its own count, so a stub that left it out
        -- would test the fallback rather than the ship.
        splinter_count = function(n) return ({[0] = 0, 2, 4, 8})[n] or 0 end,
        slot_cap = function(cls, slot)
            local _ = cls
            if slot < 5 then return 8 end          -- a stat
            if slot < 7 then return 2 end          -- a ladder of three rungs
            if slot == 7 then return 5 end         -- spray, three bits of it
            if slot < 19 then return 1 end         -- an add-on that is on or off
            if slot < 21 then return 15 end        -- a charge the zone fills
            return 0                               -- and two kinds it does not
        end,
        has_trigger = function(cls) return cls ~= 4 end,
    }

    menu.kit = nil
    menu.class = 0
    menu.adrift, menu.watching = false, true
    local panel = menu.ship_panel(nil)
    local kinds, opens = {}, {}
    for _, r in ipairs(panel.rows) do
        kinds[r.kind] = (kinds[r.kind] or 0) + 1
        if r.kind == "sect" then opens[r.sect] = r end
    end
    check("the menu is the five parts of a ship",
          kinds.sect == 5 and opens.body and opens.guns and opens.bombs
          and opens.specials and opens.flair, tostring(kinds.sect))
    -- And nothing else. The hull's five bars stood under the row that names
    -- it for a while, which put a second instrument on a page of five plain
    -- rows; they belong to the section that is about the hull.
    check("and nothing on it but rows", kinds.bars == nil
          and #panel.rows == 7, tostring(#panel.rows))
    -- All seven are spent before a pilot touches anything: the ship everybody
    -- starts in is the second rung of both weapons, a bouncing gun, a fused
    -- bomb throwing four fragments and one of each charge.
    check("and the credits it has left to spend",
          panel.credits == 7 and panel.free == 0,
          tostring(panel.free) .. " of " .. tostring(panel.credits))
    check("with a way back to the hull's own build under them",
          kinds.reset == 1)
    -- Each part says what it holds rather than what it cost, in the words a
    -- player would use for it.
    check("body reads the hull and quotes it",
          opens.body.detail == "Apex" and opens.body.raw == true,
          tostring(opens.body.detail))
    check("flair reads the wake",
          opens.flair.detail == "standard wake", tostring(opens.flair.detail))

    -- Body is one ship, turning, with its five flight rows read out under it.
    local body = menu.sect_rows(0, "body", 0)
    local stats = {}
    for _, r in ipairs(body) do
        if r.kind == "stat" then stats[#stats + 1] = r.label end
    end
    check("body turns one ship at a time",
          body[1] and body[1].kind == "art" and body[1].label == "Apex"
          and body[1].cls == 0 and body[1].pages == 7,
          tostring(body[1] and body[1].label))
    check("and reads its five flight rows under it",
          #stats == 5 and stats[1] == "speed" and stats[5] == "recharge"
          and type(body[2].share) == "number",
          table.concat(stats, " "))
    -- A hull is its name, its drawing and those five bars, and nothing else.
    --
    -- Each one used to carry a sentence drawn under the name, saying where
    -- the hull stood in speed, thrust, turn, energy and recharge. The bars
    -- immediately under it say that, against the rest of the roster rather
    -- than in adjectives, so the page was agreeing with itself out loud and
    -- spending two wrapped lines a hull to do it.
    local said = nil
    for at = 0, 6 do
        local art = menu.sect_rows(0, "body", at)[1]
        if art.note or art.detail then said = art.label end
    end
    check("no hull carries a sentence of its own", said == nil,
          tostring(said))

    -- Turning wraps at either end, and every page of it is a hull. Sitting
    -- out was the page past the roster until decision 136, so one more step
    -- off the last ship handed a seat back.
    check("the carousel wraps at either end",
          menu.hull_page(6, 1) == 0 and menu.hull_page(0, -1) == 6,
          menu.hull_page(6, 1) .. "/" .. menu.hull_page(0, -1))
    local out = menu.sect_rows(0, "body", 6)
    check("and its last page is the last ship",
          out[1] ~= nil and out[1].kind == "art" and out[1].value == 6
          and out[1].cls == 6, #out .. " rows")
    -- A stat that steps nothing would take a credit and change nothing, so no
    -- slot is offered for one even here.
    local slots = 0
    for _, r in ipairs(body) do
        if r.kind == "slot" then slots = slots + 1 end
    end
    check("no row is offered for a stat that steps nothing", slots == 0,
          slots .. " slot rows")

    -- The three that spend, each holding what the core says this hull can
    -- reach.
    local guns = menu.sect_rows(0, "guns")
    local bombs = menu.sect_rows(0, "bombs")
    local rack = menu.sect_rows(0, "specials")
    check("the weapons and the rack each open on their own slots",
          #guns > 0 and #bombs > 0 and #rack > 0,
          #guns .. "/" .. #bombs .. "/" .. #rack)
    for _, r in ipairs(guns) do panel.rows[#panel.rows + 1] = r end
    for _, r in ipairs(bombs) do panel.rows[#panel.rows + 1] = r end
    for _, r in ipairs(rack) do panel.rows[#panel.rows + 1] = r end

    -- Which rung of its own ladder a hull fires is the first row under each
    -- weapon, and it is a row a pilot can actually move. It was not: the
    -- shipped roster named one rung a weapon, so the ceiling came back zero
    -- and the row was dropped on every hull, on a page whose every other line
    -- was right. A section that opens on its add-ons is that bug.
    local levels = {gun = guns[1], bomb = bombs[1]}
    check("each weapon opens on the level it fires",
          levels.gun and levels.gun.label == "Level"
          and levels.bomb and levels.bomb.label == "Level",
          tostring(levels.gun and levels.gun.label))
    check("and it is a stepper rather than a switch",
          levels.gun and levels.gun.cap == 2 and levels.gun.toggle ~= true,
          tostring(levels.gun and levels.gun.cap))
    -- Its arrow is drawn off the purse, and the default leaves nothing in it,
    -- so the arrow is dead until a pilot hands something back. Asked of the
    -- rows twice, before and after, because the drawing takes `can_up` at its
    -- word and dims what it says cannot happen.
    check("and its arrow is dead while the purse is empty",
          levels.gun and levels.gun.can_up == false,
          tostring(levels.gun and levels.gun.can_up))
    menu.build_step(0, 16, -1)
    local freed = menu.sect_rows(0, "guns")[1]
    check("and live once a credit is free",
          freed and freed.can_up == true, tostring(freed and freed.can_up))
    check("levelling a weapon spends a credit like anything else",
          menu.build_step(0, 5, 1) == true and menu.build_of(0)[5] == 2
          and menu.build_free(0) == 0)
    menu.kit = nil

    -- And it is the one row on the page that is not counted from nothing.
    -- Everywhere else the figure is what a pilot has bought, so an untouched
    -- row is a nought; a rung is a place on a ladder the hull is already
    -- standing on, and a gun nobody has spent on is the first rung rather
    -- than no gun. The row said 0 and read as an empty rack.
    local counts_from = {}
    for _, r in ipairs(panel.rows) do
        if r.kind == "slot" then
            counts_from[r.label] = r.base or 0
        end
    end
    check("the level is counted from one", counts_from.Level == 1,
          tostring(counts_from.Level))
    local others = 0
    for label, base in pairs(counts_from) do
        if label ~= "Level" and base ~= 0 then others = others + 1 end
    end
    check("and every other row from nothing", others == 0,
          others .. " rows count from somewhere else")

    -- A slot that only goes to one is on and off and draws as a switch;
    -- anything you can have more of counts. The panel does not decide that,
    -- the ceiling does.
    local spray, bounce
    for _, r in ipairs(panel.rows) do
        if r.label == "Spray" and not spray then spray = r end
        if r.label == "Bounce" and not bounce then bounce = r end
    end
    check("a slot with room to count is a stepper",
          spray and spray.toggle ~= true and spray.cap == 5,
          tostring(spray and spray.cap))
    check("and one that only goes to one is a switch",
          bounce and bounce.toggle == true)

    -- Spending. The first step copies the default into a build of the
    -- pilot's own, so moving one slot keeps everything else the ship came
    -- with. What is different about a default that spends the whole purse is
    -- which step comes first: there is nothing to add until something is
    -- handed back, so a pilot trades rather than shops.
    check("a pilot who has spent nothing is on the ship everybody starts in",
          menu.build_edited() == false)
    check("which is both weapons a rung up, bouncing, fused and throwing "
          .. "fragments, with one of each charge",
          menu.build_of(0)[5] == 1 and menu.build_of(0)[6] == 1
          and menu.build_of(0)[8] == 1 and menu.build_of(0)[15] == 1
          and menu.build_of(0)[16] == 1
          and menu.build_of(0)[19] == 1 and menu.build_of(0)[20] == 1
          and menu.build_cost(0) == 7)
    check("and it spends the whole purse", menu.build_free(0) == 0)
    check("so nothing goes up until something comes down",
          menu.build_step(0, 7, 1) == false)
    check("a credit can be handed back", menu.build_step(0, 16, -1) == true)
    check("and the build says so", menu.build_edited() == true
          and menu.build_of(0)[16] == 0 and menu.build_free(0) == 1)
    check("and then spent on something else",
          menu.build_step(0, 7, 1) == true and menu.build_of(0)[7] == 1)
    check("what it did not touch it kept", menu.build_of(0)[19] == 1)
    check("and the purse says what is left", menu.build_free(0) == 0)

    -- And the build is the pilot's rather than the hull's: climbing into
    -- something else does not change what is bolted to it.
    check("changing hulls does not change the build",
          menu.build_of(1)[7] == 1 and menu.build_of(1)[8] == 1
          and menu.build_of(6)[7] == 1)
    -- A hull that cannot reach a slot carries nothing in it and is charged
    -- nothing for it, and the credit comes back the moment the pilot climbs
    -- into something that can.
    do
        local kept = _G.sim.slot_cap
        _G.sim.slot_cap = function(cls, slot)
            -- The bomb and only the bomb: its own rung and its own add-ons.
            if cls == 3 and (slot == 6 or (slot >= 13 and slot < 19)) then
                return 0
            end
            return kept(cls, slot)
        end
        -- Five of the pilot's seven: what a hull with no bomb cannot reach is
        -- the bomb's own rung and its fuse, the fragments having already been
        -- traded for the spray just above.
        check("and a hull with no bomb is charged nothing for one",
              menu.build_of(3)[15] == 0 and menu.build_cost(3) == 5
              and menu.build_free(3) == 2, tostring(menu.build_cost(3)))
        check("while the build keeps it for one that has a bomb",
              menu.build_of(0)[15] == 1)
        _G.sim.slot_cap = kept
    end

    -- Nothing spends past the purse or past a ceiling, and nothing goes below
    -- nothing. All three are refused rather than clamped, which is what lets a
    -- drawing dim an arrow that would do nothing.
    menu.kit = nil
    for _ = 1, 8 do menu.build_step(0, 19, 1) end
    check("the purse is the end of the spending",
          menu.build_free(0) == 0 and menu.build_step(0, 19, 1) == false)
    menu.kit = nil
    check("a slot stops at its own ceiling",
          menu.build_step(0, 8, -1) == true
          and menu.build_step(0, 8, 1) == true
          and menu.build_step(0, 8, 1) == false)
    check("and nothing goes below nothing",
          menu.build_step(0, 9, -1) == false)

    -- And back to the ship everybody starts in, which is the whole of the
    -- build manager. Stepping a slot down and back up is not an edit, so the
    -- one to reset from has to be a real one.
    menu.kit = nil
    menu.build_step(0, 8, -1)
    check("reset puts the pilot back on the default",
          menu.build_reset(0) == true and menu.build_edited() == false)
    check("and does nothing to a pilot already on it",
          menu.build_reset(0) == false)

    -- What a part says about itself: what it holds in the fight, in the words
    -- a player would use, and nothing at all where it holds nothing worth a
    -- word. The credits are the tray's to report, once, over the whole ship.
    menu.kit = nil
    check("a weapon says the rung it fires and what is bolted to it",
          menu.sect_reading(0, "bombs")
              == "level 2 " .. SEP .. " fused " .. SEP .. " 2 fragments",
          "'" .. menu.sect_reading(0, "bombs") .. "'")
    -- And nothing at all where there is nothing to say. A pilot who has taken
    -- the bomb back down to its own bottom rung and stripped it has a bomb
    -- the reading has no news about.
    menu.build_step(0, 6, -1)
    menu.build_step(0, 15, -1)
    menu.build_step(0, 16, -1)
    check("and nothing where it has none",
          menu.sect_reading(0, "bombs") == "",
          "'" .. menu.sect_reading(0, "bombs") .. "'")
    menu.kit = nil
    -- Spray is the one add-on a pilot reads as rounds in the air rather than
    -- as steps bought: a spray of one is two rounds. Bought with the credit
    -- the fragments were holding, because the default holds all seven.
    menu.build_step(0, 16, -1)
    menu.build_step(0, 7, 1)
    check("spray reads as the rounds it puts in the air",
          menu.sect_reading(0, "guns"):find("2 rounds") ~= nil,
          menu.sect_reading(0, "guns"))
    menu.kit = nil
    -- And the rack counts what it carries, plural where it is more than one.
    -- This hull's profile deals it two repels and no burst, so what the row
    -- reads is the one kind it has.
    check("the rack counts each kind it carries",
          menu.sect_reading(0, "specials") == "1 repel " .. SEP .. " 1 burst",
          menu.sect_reading(0, "specials"))
    menu.build_step(0, 16, -1)
    menu.build_step(0, 19, 1)
    check("and pluralizes what it carries more than one of",
          menu.sect_reading(0, "specials") == "2 repels " .. SEP .. " 1 burst",
          menu.sect_reading(0, "specials"))
    menu.kit = nil
    -- Two facts about one part read as one strip, with the dot between them.
    menu.build_step(0, 16, -1)
    menu.build_step(0, 7, 1)
    check("and the facts about one part read as one strip",
          menu.sect_reading(0, "guns")
              == "level 2 " .. SEP .. " 2 rounds " .. SEP .. " bouncing",
          menu.sect_reading(0, "guns"))
    menu.kit = nil

    -- The menu is the same five parts from the bench, and body reads the
    -- hull a watcher would fly back in rather than the fact that they are
    -- watching: sitting out is not something the ship menu can ask for any
    -- more (decision 136), so it has nothing to say about it.
    menu.watching = true
    local benched = menu.ship_panel(nil)
    check("body reads the hull a watcher would fly back in",
          benched.rows[1].detail == "Apex",
          tostring(benched.rows[1].detail))
    local still = 0
    for _, r in ipairs(benched.rows) do
        if r.kind == "sect" then still = still + 1 end
    end
    check("and all five parts are still there", still == 5,
          still .. " parts")
    menu.watching = false

    -- --- the draft, which is what makes this panel an editor in a match ----
    --
    -- A ship is the hull and the build together and changing it costs a
    -- respawn, so in a match it is settled once rather than as it is read.
    -- Walking the carousel from an Apex to a Lattice and trading a charge on
    -- the way is one ship change, not seven, and nothing about it leaves this
    -- client until the arena says so.
    menu.kit = nil
    menu.class = 0
    net.kits = {}
    net.set_kit = function(cls, kit)
        net.kits[#net.kits + 1] = {cls = cls, kit = kit}
        return true
    end

    menu.draft_open()
    check("a draft stands as soon as the panel opens",
          menu.drafting() and not menu.drafted())
    check("and looking at the ship is not asking for one",
          #net.kits == 0)

    menu.pick_profile(3)
    check("turning the carousel moves the hull the panel draws",
          menu.class == 3 and menu.drafted())
    -- Flair costs nothing and crosses no wire, so it takes effect and is
    -- saved as it is pressed. What it must not save is the draft standing
    -- over it: a pilot who backs out of a ship should not boot into it.
    saved = nil
    menu.save_identity()
    check("a save while a draft stands writes the ship under it",
          saved ~= nil and saved.class == 0, tostring(saved and saved.class))
    menu.build_step(3, 19, -1)
    check("and spending moves the build",
          menu.build_of(3)[19] == 0 and menu.build_edited())
    check("but nothing has been asked of the room yet",
          #net.kits == 0, #net.kits .. " sent")

    -- Backing out puts the ship back the way the draft found it, hull and
    -- row together: a pilot who never got the ship they were building must
    -- not be left with a menu describing one they are not in.
    menu.draft_drop()
    check("dropping a draft puts the ship back",
          menu.class == 0 and menu.kit == nil and not menu.drafting()
          and #net.kits == 0, tostring(menu.class))

    -- And keeping one is the pilot's ship, saved. The arena sends it, since
    -- only it knows whether there is a room to send it to.
    menu.draft_open()
    menu.pick_profile(2)
    menu.build_step(2, 19, -1)
    menu.draft_keep()
    check("keeping a draft keeps the ship that was built",
          menu.class == 2 and menu.build_of(2)[19] == 0
          and not menu.drafting())
    menu.send_build(menu.class)
    check("and it goes out as one message carrying both",
          #net.kits == 1 and net.kits[1].cls == 2
          and (net.kits[1].kit[19] or 0) == 0,
          #net.kits .. " sent, slot 19 at "
              .. tostring(net.kits[1] and net.kits[1].kit[19]))

    -- --- and what spends one --------------------------------------------
    --
    -- A draft outlives the panel it was made in and dies with the menu. The
    -- panel used to settle on any of the six ways out of it, so escape, a
    -- press on the glass beside it, or the back chevron all cost a respawn:
    -- a dismissal is not a decision. What spends a draft now is the column's
    -- key, and everything that puts the column away drops one. See
    -- decision 154.
    menu.class = 0
    menu.kit = nil
    menu.open = true
    menu.stack = {"ship"}
    menu.draft_open()
    menu.pick_profile(4)
    -- Backing out of the panel to the bare column, which is where every way
    -- out of it lands.
    menu.stack = {}
    check("a draft outlives the panel it was made in",
          menu.drafting() and menu.drafted() and menu.class == 4,
          tostring(menu.class))
    check("and the ship stop says what is pending",
          menu.hull_name() == "Cipher", menu.hull_name())

    -- Reopening it is the same undecided ship rather than a new one, or the
    -- hull it reverts to would be whatever the carousel was last showing.
    menu.stack = {"ship"}
    menu.draft_open()
    menu.stack = {}
    menu.close()
    check("and closing the column puts the ship back where it started",
          menu.class == 0 and not menu.drafting(), tostring(menu.class))

    net.set_kit = nil
    menu.kit = nil
    menu.class = 0
    _G.sim = kept_core
end

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
