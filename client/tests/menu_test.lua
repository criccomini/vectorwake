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
function account.refresh_career()
    account.asked_career = (account.asked_career or 0) + 1
end
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
_G.sys = {get_config_string = function(_, d) return d end,
          get_config_int = function(_, d) return d end,
          get_engine_info = function() return {version = "test"} end,
          get_save_file = function() return "/tmp/vw-test-save" end,
          load = function() return {} end, save = function() return true end,
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

-- --- the column's stops, and which of them a room offers -------------------
--
-- The way out of the seat, the machine, and which side you are on, top down in
-- that order. LEAVE is farthest from the key that resumes on purpose: the
-- press that ends a match should not be the neighbor of the press that ends
-- the menu.
--
-- There is no rail and no tab row here to grow a stop and lose one. A stop a
-- room cannot offer is not in the list, and the list is the whole of the
-- navigation.

menu.open = true
menu.home = false
menu.watching = false
menu.zone = "chaos"
menu.stack = {}
net.teams = {}

check("a pilot in a hull gets the way out and the machine",
      stop_names() == "leave/settings", stop_names())

-- Leaving goes one step, and which step is whichever one you are standing on.
-- Flying, it hands the seat back and leaves you watching the same room, so the
-- column stays up and the corner's TAKE SEAT is the way back in. Benched, the
-- seat is already gone and the step is out of the room, which costs the match.
--
-- The answer on the stop is the thing being left rather than a sentence about
-- leaving it, which is the grammar every stop in this column speaks and the
-- landing's speak too: the label asks and the answer is a name. "To the
-- stands" was a phrase in the slot a name goes in, set in the face the arena
-- reserves for data, and it read as one.
local flying_leave = stop_of("leave")
check("flying, the leave stop hands the seat back",
      flying_leave.act == "leave_seat" and flying_leave.value == "seat",
      tostring(flying_leave.act) .. "/" .. tostring(flying_leave.value))

menu.watching = true
local benched_leave = stop_of("leave")
check("benched, the same stop is the way out of the room",
      benched_leave.act == "leave" and benched_leave.value == "game",
      tostring(benched_leave.act) .. "/" .. tostring(benched_leave.value))
check("and the column is the same three stops either way",
      stop_names() == "leave/settings", stop_names())

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

-- The sides arrive on the roster broadcast rather than in the join, so this
-- stop appears a frame or two after the rest of the column. It is last for
-- that reason: appearing at the foot shuffles nothing already under a thumb.
check("a room that has not named its sides carries no side stop",
      stop_of("side") == nil, stop_names())
net.teams = {{team = 1, name = "Pylon", humans = 3, bots = 1},
             {team = 2, name = "Caisson", humans = 4, bots = 0}}
net.my_team = 1
net.my_team_name = function() return "Pylon" end
check("and one that has puts it last, under the other two",
      stop_names() == "leave/settings/side", stop_names())
local side = stop_of("side")
check("the side stop says which side you fly for, in its own name",
      side.value == "Pylon" and side.named == true and side.go == "side",
      tostring(side.value))

-- The view carries the same three, and says which one is holding a page open.
-- That is the whole of "where am I" now: a lit stop with its panel climbing
-- off it. The drawer answered it five ways at once, with a rail, a stage, a
-- topbar, a head and a preview, and those checks went with them.
open()
local v = menu.view()
check("the view carries the stops the column is drawn from",
      #v.stops == 3 and v.stops[1].stop == "leave"
      and v.stops[3].stop == "side", #v.stops .. " stops")
check("and none of them is open over the bare column",
      not v.stops[1].open and not v.stops[2].open and not v.stops[3].open)
open("settings")
v = menu.view()
check("the stop whose page is up is the lit one",
      v.stops[2].open == true and v.stops[1].open == false,
      tostring(v.stops[2].open))
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
-- a fortnight later, and the three stops are one press from anywhere anyway.
check("and always on its bare stops", #menu.stack == 0 and menu.at() == nil,
      table.concat(menu.stack, "/"))
check("and the same key puts it away", menu.toggle() == false and not menu.open)

open()
check("a bare column has no page open", menu.stop_open() == nil)
check("pressing a stop opens its page",
      select(2, menu.press_stop("settings")) == true
      and menu.stop_open() == "settings", table.concat(menu.stack, "/"))
-- Pressing the one already open shuts it, which is what the caret on the stop
-- draws and what the landing's own stops do.
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
-- Handing a seat back costs nothing that cannot be taken again, so it happens
-- on the press. Leaving the room costs the match, so it asks. The card owns
-- the keys while it is up, the answer that changes nothing sits under the
-- cursor, and escape answers it with that one rather than shutting the panel.

open()
menu.home, menu.watching = false, false
menu.ask = nil
local act, moved = menu.press_stop("leave")
check("flying, the stop hands the seat back on the press",
      act == "leave_seat" and moved and menu.ask == nil, tostring(act))
-- Nothing about where this client is has moved, so the panel stays where it
-- is: what changed is on the glass behind it.
check("and leaves the panel standing", menu.open)

menu.watching = true
act, moved = menu.press_stop("leave")
check("benched, it asks before it costs the match",
      act == nil and moved and menu.ask ~= nil, tostring(act))
check("and the card names the game in the words the games list has for it",
      string.find(menu.ask.head, "Chaos", 1, true) ~= nil, menu.ask.head)
check("the card offers leaving and staying, nothing else",
      #menu.ask.keys == 2 and menu.ask.keys[1].act == "leave",
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
      act == "leave" and moved and menu.ask == nil, tostring(act))

-- Escape answers it rather than shutting the panel, and answers it with the
-- one that changes nothing: the key that gets out of everything else in here
-- has to get out of this without leaving the game by accident.
menu.press_stop("leave")
act, moved = menu.step({back = true})
check("escape answers the question instead of shutting the menu",
      act == nil and moved and menu.ask == nil and menu.open,
      tostring(act) .. ", open " .. tostring(menu.open))

-- --- the sides, which are the one page that arrives over the wire ----------
--
-- A room says what sides it has, and until it does there are none to stand on.
-- The stop hides itself until they land, which is checked up with the stops;
-- what is checked here is the list a press on it opens.
--
-- A list rather than a value stepped left and right, which is what the side
-- row was while a room held two. Arrows walk: in a zone holding three,
-- reaching the third means crossing the second, and a pilot who wanted the
-- third has joined the second on the way.

net.teams = {{team = 1, name = "Pylon", humans = 3, bots = 1},
             {team = 2, name = "Caisson", humans = 4, bots = 0},
             {team = 3, name = "Meridian", humans = 0, bots = 0}}
net.my_team = 1
net.may_found = false
open()
menu.press_stop("side")
check("the side stop opens the room's own sides",
      menu.stop_open() == "side" and #rows() == 3, labels())
check("in the room's own words",
      rows()[1].label == "Pylon" and rows()[3].label == "Meridian",
      labels())
check("said as somebody named them rather than as this interface speaks",
      rows()[1].named == true)
check("with the one you fly for marked",
      rows()[1].mark == true and rows()[2].mark == false)
-- People and AI apart, because the caps are, and because "four and eleven
-- bots" is a different room from "fifteen".
check("and the count says people and AI apart",
      rows()[1].detail == "3 + 1 AI" and rows()[2].detail == "4",
      tostring(rows()[1].detail) .. " / " .. tostring(rows()[2].detail))
-- Each side is one press, however many there are.
menu.pending = nil
act, moved = menu.press_row(3)
check("picking one asks the room for it",
      act == "team" and moved and menu.pending == 3,
      tostring(act) .. "/" .. tostring(menu.pending))

-- A side of your own, when the room may hold another. A zone whose max_teams
-- is the count of its own sides never offers this, which is how a flag round
-- says there is no third side to be.
check("a room that will hold no more sides offers no way to found one",
      row_at("new team") == nil, labels())
net.may_found = true
check("and one that will offers it under the sides it has",
      row_at("new team") == 4, labels())
act, moved = menu.press_row(4)
check("and founding is an act the arena carries out",
      act == "found" and moved, tostring(act))
net.may_found = false

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

-- A section is a band with a run of rows under it, so a `sect` opens one and
-- the rows after it belong to it. The first row of the page has to open one,
-- since a run with no band over it is a run of rows nothing names.
check("the settings page opens with a section",
      rows()[1] and rows()[1].sect ~= nil,
      tostring(rows()[1] and rows()[1].label))

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

-- A hull that carries two kinds of charge leaves one thing for the pilot to
-- decide: which of the two keys spends which. The core numbers the kinds and
-- the profile carries counts by kind, so without a preference the first key
-- always throws the lower-numbered one, whatever the pilot would rather have.
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
        SLOT_CHARGE0 = 19,
        class_kit = function() return carried end,
    }
    menu.charge_flip = false
    menu.class = 0
    menu.spectate = false

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
    -- pilot who put `map` on W would otherwise have to hunt for their burst.
    menu.press_row(map_at)
    local traded = menu.bind_chord({"space"})
    check("a taken key trades", traded
          and binds.chord_of.map[1] == "space"
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

    -- On glass there is no board to draw and no key column to fill in, so the
    -- same list comes out as gestures. A control a thumb cannot work at all is
    -- left out rather than named.
    menu.touching = true
    local pads = rows()
    local keyed = false
    for _, r in ipairs(pads) do
        if r.control or r.reset then keyed = true end
    end
    check("a thumb gets the gestures rather than the keys",
          #pads > 0 and not keyed, #pads .. " rows")
    check("and every one of them says what the thumb does",
          (function()
              for _, r in ipairs(pads) do
                  if not r.detail or r.detail == "" then return false end
              end
              return true
          end)())
    menu.touching = false
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

-- --- the account, which is a list the landing opens -----------------------
--
-- These acts left the drawer with the pilot page: the account is a stop on the
-- landing now, its rows are `menu.account_rows`, and pressing one runs
-- `menu.activate_act` with the same act name the drawer's rows carried. What
-- they do is unchanged, and it is all still this file's, so it is read here.
-- See decision 99.

menu.ask = nil
menu.home = true
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
local function account_act(label)
    for _, r in ipairs(menu.account_rows()) do
        if r.label == label then return menu.activate_act(r.act) end
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
-- At home the card asks only about the name; there is no ship to cost.
check("and at home says nothing about respawning",
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
menu.home = false
account_act("new name")
check("mid-game the card says a roll respawns your ship",
      menu.ask ~= nil
      and string.find(menu.ask.head, "respawns your ship") ~= nil,
      tostring(menu.ask and menu.ask.head))
menu.step({back = true})
menu.home = true
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
    local kept = {claimed = account.claimed, career = account.career}
    account.claimed = false
    account.career = nil
    check("a fresh guest has nothing to lose", menu.guest_stakes() == false)
    account.career = {games = 1, kills = 0, deaths = 1}
    check("a rated game flown arms the warning", menu.guest_stakes() == true)
    account.claimed = true
    check("and signing up takes it down", menu.guest_stakes() == false)
    account.claimed, account.career = kept.claimed, kept.career
end

-- The figure it arms on is rated games, and a guest's first one is filed while
-- they are flying: the copy fetched when the session woke says none for the
-- whole of the session the game was flown in. So the menu asks again while the
-- answer is still nothing, and stops the moment it is not.
do
    local kept = {claimed = account.claimed, career = account.career,
                  asked = account.asked_career}
    open()
    account.claimed, account.career = false, nil
    account.asked_career = 0
    menu.tick(20)
    check("a guest with nothing recorded re-asks for their career",
          account.asked_career > 0, tostring(account.asked_career))
    local asked = account.asked_career
    account.career = {games = 2, kills = 3, deaths = 1}
    menu.tick(20)
    check("and stops once a game has been flown",
          account.asked_career == asked, tostring(account.asked_career))
    account.career, account.asked_career = nil, 0
    account.claimed = true
    menu.tick(20)
    check("a signed-in pilot is never asked on this timer",
          account.asked_career == 0, tostring(account.asked_career))
    account.claimed = kept.claimed
    account.career, account.asked_career = kept.career, kept.asked
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

-- A stop the column no longer carries is a page you are no longer in. The
-- sides are the one that comes and goes: a room names them on the roster
-- broadcast, and a disconnect takes them away under a pilot standing in the
-- list.
menu.home, menu.watching = false, true
net.teams = {{team = 1, name = "Pylon", humans = 3, bots = 1}}
open("side")
menu.tick(0.1)
check("a page whose stop is still offered stays open",
      menu.stop_open() == "side", table.concat(menu.stack, "/"))
net.teams = {}
menu.tick(0.1)
check("and one whose stop has gone is dropped",
      menu.stop_open() == nil and #menu.stack == 0,
      table.concat(menu.stack, "/"))

-- --- is there still a row there -------------------------------------------
--
-- A press is tested against hit boxes the previous frame published, and some of
-- these lists are rebuilt underneath them: a side can leave the roster between
-- the drawing and the press. The cursor itself is ui.lua's, standing on a box
-- that was actually drawn; this is the one question about a row that only the
-- file holding the rows can answer.

net.teams = {{team = 1, name = "Pylon", humans = 3, bots = 1},
             {team = 2, name = "Caisson", humans = 4, bots = 0}}
open("side")
check("a row that is there is there", menu.has_row(2) == true)
net.teams = {{team = 1, name = "Pylon", humans = 3, bots = 1}}
check("and one the wire has taken away is not", menu.has_row(2) == false)
check("and a press on the row that went answers nothing",
      select(2, menu.press_row(2)) == false)
open()
check("a bare column holds no rows at all", menu.has_row(1) == false)
net.teams = {}

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
            -- A spray and a repel, which is a hull that has spent three of
            -- its seven credits.
            out[8] = 1
            out[20] = 2
            return out
        end,
        -- Flight steps nothing, as the shipped roster does not, so no stat row
        -- is offered; the mods and the rack are what a pilot can reach.
        class_up_step = function() return {0, 0, 0, 0, 0} end,
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

    menu.builds = {}
    menu.class = 0
    -- Off the landing, `spectating` is `M.watching` rather than the saved
    -- preference: this block is asking what the ship menu says about a pilot
    -- with a seat.
    menu.home, menu.spectate, menu.watching = true, false, false
    local panel = menu.ship_panel(nil)
    local kinds, opens = {}, {}
    for _, r in ipairs(panel.rows) do
        kinds[r.kind] = (kinds[r.kind] or 0) + 1
        if r.kind == "sect" then opens[r.sect] = r end
    end
    check("the menu is the five parts of a ship",
          kinds.sect == 5 and opens.body and opens.guns and opens.bombs
          and opens.specials and opens.flair, tostring(kinds.sect))
    check("with the hull's flight under the row that names it",
          kinds.bars == 1 and type(panel.rows[2].bars) == "table"
          and #panel.rows[2].bars == 5)
    check("and the credits it has left to spend",
          panel.credits == 7 and panel.free == 4,
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

    -- Body is the roster, one hull a row, each with its own flight beside it.
    local body = menu.sect_rows(0, "body")
    local hulls, headed = 0, false
    for _, r in ipairs(body) do
        if r.kind == "stat_head" then headed = true end
        if r.kind == "hull" then hulls = hulls + 1 end
    end
    check("body lists the roster under one column head",
          headed and hulls == 8, hulls .. " rows")
    check("and every ship in it carries its own flight",
          type(body[2].bars) == "table" and #body[2].bars == 5)
    -- A stat that steps nothing would take a credit and change nothing, so no
    -- row is offered for one even here.
    local stats = 0
    for _, r in ipairs(body) do
        if r.kind == "slot" then stats = stats + 1 end
    end
    check("no row is offered for a stat that steps nothing", stats == 0,
          stats .. " stat rows")

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
    check("and it is a stepper a pilot with credits can move",
          levels.gun and levels.gun.cap == 2 and levels.gun.toggle ~= true
          and levels.gun.can_up == true,
          tostring(levels.gun and levels.gun.cap))
    check("levelling a weapon spends a credit like anything else",
          menu.build_step(0, 5, 1) == true and menu.build_of(0)[5] == 1
          and menu.build_free(0) == 3)
    menu.builds = {}

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

    -- Spending. The first step copies the hull's own row into a build, so a
    -- pilot who moves one slot keeps everything else the ship came with.
    check("a hull nobody has touched is on its own row",
          menu.build_edited(0) == false)
    check("a credit can be spent", menu.build_step(0, 7, 1) == true)
    check("and the build says so", menu.build_edited(0) == true
          and menu.build_of(0)[7] == 2)
    check("what it did not touch it kept", menu.build_of(0)[19] == 2)
    check("and the purse says what is left", menu.build_free(0) == 3)

    -- Nothing spends past the purse or past a ceiling, and nothing goes below
    -- nothing. All three are refused rather than clamped, which is what lets a
    -- drawing dim an arrow that would do nothing.
    menu.builds = {}
    for _ = 1, 8 do menu.build_step(0, 19, 1) end
    check("the purse is the end of the spending",
          menu.build_free(0) == 0 and menu.build_step(0, 19, 1) == false)
    menu.builds = {}
    check("a slot stops at its own ceiling",
          menu.build_step(0, 8, 1) == true
          and menu.build_step(0, 8, 1) == false)
    check("and nothing goes below nothing",
          menu.build_step(0, 9, -1) == false)

    -- And back to the hull's own row, which is the whole of the build manager.
    check("reset puts the hull back on its profile",
          menu.build_reset(0) == true and menu.build_edited(0) == false)
    check("and does nothing to a hull that is already on it",
          menu.build_reset(0) == false)

    -- What a part says about itself: what it holds in the fight, in the words
    -- a player would use, and nothing at all where it holds nothing worth a
    -- word. The credits are the tray's to report, once, over the whole ship.
    menu.builds = {}
    check("a weapon with nothing bolted to it says nothing",
          menu.sect_reading(0, "bombs") == "",
          "'" .. menu.sect_reading(0, "bombs") .. "'")
    -- Spray is the one add-on a pilot reads as rounds in the air rather than
    -- as steps bought: a spray of one is two rounds.
    menu.build_step(0, 7, 1)
    check("spray reads as the rounds it puts in the air",
          menu.sect_reading(0, "guns"):find("3 rounds") ~= nil,
          menu.sect_reading(0, "guns"))
    menu.builds = {}
    -- And the rack counts what it carries, plural where it is more than one.
    -- This hull's profile deals it two repels and no burst, so what the row
    -- reads is the one kind it has.
    check("the rack counts each kind it carries",
          menu.sect_reading(0, "specials") == "2 repels",
          menu.sect_reading(0, "specials"))
    menu.build_step(0, 20, 1)
    check("and says both where it carries both",
          menu.sect_reading(0, "specials") == "2 repels " .. SEP .. " 1 burst",
          menu.sect_reading(0, "specials"))
    menu.builds = {}
    -- Two facts about one part read as one strip, with the dot between them.
    menu.build_step(0, 8, 1)
    check("and two facts about one part read as one strip",
          menu.sect_reading(0, "guns") == "2 rounds " .. SEP .. " bouncing",
          menu.sect_reading(0, "guns"))
    menu.builds = {}

    -- Sitting out is the roster's last row rather than a page past it, and
    -- the menu reads it off body. Nothing else about the menu changes: a
    -- pilot watching can still set up the ship they will arrive in.
    menu.spectate = true
    local watching = menu.ship_panel(nil)
    check("sitting out is what body reads",
          watching.rows[1].detail == "spectate",
          tostring(watching.rows[1].detail))
    local still = 0
    for _, r in ipairs(watching.rows) do
        if r.kind == "sect" then still = still + 1 end
    end
    check("and the other four parts are still there", still == 5,
          still .. " parts")
    menu.spectate = false

    menu.builds = {}
    _G.sim = kept_core
end

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
