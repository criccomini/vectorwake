-- Where a tap lands, in the menu's own model.
--
--     lua5.1 client/tests/menu_nav_test.lua
--
-- The rail is on screen at every level, so a tap on it means "go there"
-- whatever page is showing. It used to be delivered as a row of the current
-- page, which was right when the menu was one list and the root's rows were
-- the destinations, and became wrong the moment a rail existed: from inside
-- `ship`, a tap on `settings` picked the fourth hull. On a phone the rail is
-- the only way to move, so that is navigation not working at all.
--
-- None of it is visible in a screenshot of one frame -- both taps land, both
-- light something -- so it is checked here, against the model, by pressing
-- what a thumb presses and asking where the stack ended up.

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
    -- The friends page's lists and the one call the menu makes to fill them.
    -- Empty is a pilot with nobody yet, which is what most of this file is
    -- testing around.
    friends = {}, asked = {}, waiting = {}, here = {}, everybody = {},
    have_friends = true,
    asked_friends = 0,
    friended = nil, ignored = nil,
    friend_note = "", friend_bad = false,
    found = {}, found_for = "", asked_for = nil,
}
function account.refresh_week(back)
    account.asked_week = back or 0
end
function account.refresh_friends()
    account.asked_friends = account.asked_friends + 1
end
function account.friend(who, add)
    account.friended = {who = who, add = add}
end
function account.ignore(who, on)
    account.ignored = {who = who, on = on}
end
function account.find_pilots(prefix)
    -- What the real one does with anything under two characters: nothing, and
    -- it forgets whatever was there. Above that it asks and leaves the names
    -- in hand alone until a reply lands, which is the state this page has to
    -- draw correctly.
    if #prefix < 2 then
        account.asked_for = ""
        account.found, account.found_for = {}, prefix
        return
    end
    account.asked_for = prefix
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
package.loaded["arena.net"] = {
    teams = {}, my_team = 0, may_found = false,
    my_team_name = function() return "" end,
    transport = function() return {} end,
    protocol = 5, invite = function() end,
}
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
    rows = {{zone = "chaos", name = "chaos", detail = "a brawl",
             count = "0 playing", players = 0, bots = 51, live = true}},
    note = "", tick = function() end, aim = function() end,
    pilot_name = "",
    -- Where an instance answers, by its id. The friends page turns a friend's
    -- whereabouts into a press with it.
    instances = {},
}
do
    local dir = package.loaded["arena.directory"]
    dir.at_instance = function(id) return dir.instances[id] end
end
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

local function texts_of(v)
    local out = {}
    for _, r in ipairs(v.rows) do out[#out + 1] = r.label end
    return out
end

local function top_index(name)
    -- Which stop on the rail carries this destination.
    local v = menu.view()
    for i, r in ipairs(v.rail) do
        if r.label == name then return i end
    end
end

-- --- a tap on the rail goes there, from wherever you are -------------------

menu.open = true
menu.home = true
menu.stack = {"root"}
menu.sel = {}

local ship_at = top_index("ship")
local settings_at = top_index("settings")
local tabs = {}
for _, r in ipairs(menu.view().rail) do tabs[#tabs + 1] = r.label end
check("the tab row is play, ship, upgrades, friends, standings, settings",
      table.concat(tabs, "/")
      == "play/ship/upgrades/friends/standings/settings",
      table.concat(tabs, "/"))
check("the rail carries the destinations", ship_at and settings_at,
      "ship " .. tostring(ship_at) .. ", settings " .. tostring(settings_at))

-- The week's filter is the same field the friends page takes a call sign in,
-- and it answers the same arrows: down off the tabs lands in it, down again is
-- the table, up comes back, up again is the tabs.
do
    local kept_stack, kept_sel = menu.stack, menu.sel
    menu.open, menu.home = true, true
    menu.stack = {"root"}
    menu.sel = {root = top_index("standings")}
    menu.filter_on = false
    menu.step({down = true})
    check("down off the tabs opens standings with the cursor in its filter",
          menu.at() == "standings" and menu.filter_on == true,
          menu.at() .. "/" .. tostring(menu.filter_on))
    check("and the page says so", menu.view().week.filter_on == true,
          tostring(menu.view().week.filter_on))
    menu.step({down = true})
    check("and down again goes to the table", menu.filter_on == false,
          tostring(menu.filter_on))
    menu.sel.standings = 1
    menu.step({up = true})
    check("up off the first row comes back to it", menu.filter_on == true,
          tostring(menu.filter_on))
    menu.step({up = true})
    check("and up out of it goes back to the tabs",
          menu.at() == "root" and menu.filter_on == false,
          menu.at() .. "/" .. tostring(menu.filter_on))
    menu.stack, menu.sel = kept_stack, kept_sel
end

-- Right is enter on a list of places and nothing on a list of games. An arrow
-- is how a list is read, and reading the third game on it should not put you
-- in the second.
do
    local kept_stack, kept_sel = menu.stack, menu.sel
    menu.open, menu.home = true, true
    menu.stack = {"root", "play"}
    menu.sel = {play = 1}
    local joined, moved = menu.step({right = true})
    check("right on a game does not join it",
          joined == nil and moved == false and menu.at() == "play",
          tostring(joined) .. "/" .. tostring(moved) .. "/" .. menu.at())
    -- And the row under the cursor really was a game, which is what makes the
    -- check above about right rather than about an empty list.
    check("and enter on the same row still does",
          menu.step({go = true}) == "join", "nothing joined")
    menu.stack, menu.sel = kept_stack, kept_sel
end

-- --- and the two buttons at the end of that row are on the row -------------
--
-- They sit beside the tabs, they do what a tab does, and until now a hand on
-- the arrows could not reach either: the way to an account was a mouse or
-- nothing. The row is the tabs and then those, left to right, and it loops.
do
    local kept_name, kept_url = menu.name, _G.sys.open_url
    menu.name = "Tester 1"
    menu.open, menu.home = true, true
    menu.stack = {"root"}
    menu.sel = {root = settings_at}
    menu.corner_sel = nil
    menu.step({right = true})
    check("right off the last tab reaches discord",
          menu.view().corner_sel == "discord",
          tostring(menu.view().corner_sel))
    -- Standing on a corner stop is standing on it: the tab the cursor left
    -- goes dark, and the stage previews the stop's page the way it previews
    -- a tab's. It kept the old tab lit and the old page up, which read as a
    -- cursor in two places and a button that did nothing.
    check("and the tab it left goes dark",
          (menu.view().rail_sel or 0) == 0,
          tostring(menu.view().rail_sel))
    check("and the stage previews the discord page",
          menu.showing() == "discord"
          and (menu.view().rows[1] or {}).label == "join discord",
          menu.showing() .. "/" .. tostring((menu.view().rows[1] or {}).label))
    menu.step({right = true})
    check("and the account is the next one along",
          menu.view().corner_sel == "pilot",
          tostring(menu.view().corner_sel))
    check("previewing the pilot page and its call sign card",
          menu.showing() == "pilot"
          and ((menu.view().aside or {}).head == "call sign"),
          menu.showing() .. "/" .. tostring((menu.view().aside or {}).head))
    menu.step({right = true})
    check("and right again is the first tab, the way the row wraps",
          menu.view().corner_sel == nil and menu.sel.root == 1,
          tostring(menu.view().corner_sel) .. "/" .. tostring(menu.sel.root))
    menu.step({left = true})
    check("left off the first tab is the last of them",
          menu.view().corner_sel == "pilot",
          tostring(menu.view().corner_sel))
    menu.step({left = true})
    check("and walks back through them", menu.view().corner_sel == "discord",
          tostring(menu.view().corner_sel))
    menu.step({left = true})
    check("and off their end onto the last tab",
          menu.view().corner_sel == nil and menu.sel.root == settings_at,
          tostring(menu.view().corner_sel) .. "/" .. tostring(menu.sel.root))

    -- Enter on the account is the account page.
    menu.sel = {root = settings_at}
    menu.corner_sel = nil
    menu.step({right = true})
    menu.step({right = true})
    menu.step({go = true})
    check("enter on the account opens its page", menu.at() == "pilot",
          table.concat(menu.stack, "/"))
    -- And the button stays lit while you are on its page, which is what a tab
    -- does. It went dark instead, so the one row on screen that says where
    -- you are said nothing about the two stops at the end of it.
    check("and the button stays lit while its page is up",
          menu.view().corner_sel == "pilot", tostring(menu.view().corner_sel))
    -- Not from a page a tab leads to, though: there the lit tab is the
    -- answer and a lit button beside it would be a cursor in two places.
    menu.stack = {"root"}
    menu.sel = {root = ship_at}
    menu.corner_sel = nil
    menu.step({down = true})
    check("but nothing in the corner is lit from a page off the tabs",
          menu.at() == "hangar" and menu.view().corner_sel == nil,
          menu.at() .. "/" .. tostring(menu.view().corner_sel))
    menu.stack = {"root"}
    menu.sel = {}

    -- Down is the same press, the way it is on a tab: what is under one of
    -- these is a page, and the Discord button has one now rather than a
    -- browser tab it opens without warning.
    local asked = nil
    _G.sys.open_url = function(url) asked = url return true end
    menu.stack = {"root"}
    menu.sel = {root = settings_at}
    menu.corner_sel = nil
    menu.step({right = true})
    menu.step({down = true})
    check("down on discord opens its page", menu.at() == "discord",
          table.concat(menu.stack, "/"))
    check("and nothing has left for the browser", asked == nil,
          tostring(asked))
    menu.stack = {"root"}

    -- A tap on a tab takes the cursor off them, so the row never looks like
    -- the arrows are in two places.
    menu.corner_sel = 1
    menu.click_rail(ship_at)
    check("and a tap on a tab clears them", menu.corner_sel == nil,
          tostring(menu.corner_sel))
    menu.stack = {"root"}
    menu.sel = {}
    menu.name, _G.sys.open_url = kept_name, kept_url
end

menu.click_rail(ship_at)
check("a rail tap goes in", menu.stack[2] == "hangar",
      table.concat(menu.stack, "/"))

-- The one that was broken: a second rail tap, from inside the first page.
local before_class = menu.class
menu.click_rail(settings_at)
check("a rail tap from inside a page goes to that page",
      menu.stack[2] == "settings", table.concat(menu.stack, "/"))
check("and does not act on the page it left", menu.class == before_class,
      "hull moved to " .. tostring(menu.class))

-- Back out, and the rail still works.
menu.click_rail(ship_at)
check("and again, the other way", menu.stack[2] == "hangar",
      table.concat(menu.stack, "/"))

-- The stop you are already standing in. On a phone the rail is the whole of
-- the navigation and there is nothing outside the panel to press, so tapping
-- the lit stop is the way back into the game. Re-entering the page you are
-- already reading is the only other thing it could mean, and that is nothing.
--
-- It shuts the menu wherever you are, seat or no seat. There used to be an
-- exception for the front end, which had nothing behind the panel to shut it
-- onto; the stands are behind it now, and before they arrive the waiting
-- screen is, so there is no state this strands anybody in.
menu.click_rail(ship_at)
check("the lit stop shuts the menu",
      not menu.open, table.concat(menu.stack, "/"))

-- In a match the tab row is a different row: settings, friends and leave,
-- which is everything a pilot can act on from a cockpit. Nothing about an
-- upgrade or a hull is on it, because a hull is locked for the match and a
-- three minute match is short enough that browsing one costs a real fraction
-- of it.
--
-- Settings comes first because it is the safe, common reason to open a menu
-- while the fight continues behind it. Friends stays one stop away because the
-- people to add are the people you are flying with.
menu.home = false
menu.open = true
menu.stack = {"root"}
menu.sel = {}
local in_match = {}
for _, r in ipairs(menu.view().rail) do in_match[#in_match + 1] = r.label end
check("a match carries three tabs",
      #in_match == 3 and in_match[1] == "settings"
      and in_match[2] == "friends" and in_match[3] == "leave",
      table.concat(in_match, "/"))

local match_leave = top_index("leave")
menu.click_rail(match_leave)
check("leave asks before dropping the game",
      menu.ask ~= nil and menu.ask.keys[1].act == "leave",
      tostring(menu.ask and menu.ask.head))
menu.step({back = true})
check("and escape keeps the game", menu.ask == nil and menu.open,
      tostring(menu.ask) .. "/" .. tostring(menu.open))

local match_settings = top_index("settings")
menu.click_rail(match_settings)
check("and settings is one of them",
      menu.stack[2] == "settings", table.concat(menu.stack, "/"))
local setting_view = menu.view()
check("with a selected setting explained in the spare column",
      setting_view.settings and setting_view.aside
          and setting_view.aside.label == "sound"
          and string.find(setting_view.aside.note or "", "weapon audio", 1, true),
      tostring(setting_view.aside and setting_view.aside.note))
menu.click_rail(match_settings)
check("the lit stop over a game is the way back to it", not menu.open)

-- Except between matches, which is the twenty five seconds the hull is not
-- locked for. The hangar opens there and closes again at the whistle, and a
-- pilot still standing in it when that happens is put back on the row rather
-- than left picking a hull for a match already running.
local net = package.loaded["arena.net"]
menu.open = true
net.match = {playing = false, left = 20, score = {}}
menu.stack = {"root"}
menu.sel = {}
local between = {}
for _, r in ipairs(menu.view().rail) do between[#between + 1] = r.label end
check("the intermission opens the hangar",
      #between == 4 and between[1] == "ship", table.concat(between, "/"))

menu.click_rail(top_index("ship"))
check("and it can be walked into", menu.stack[2] == "hangar",
      table.concat(menu.stack, "/"))
net.match = {playing = true, left = 180, score = {}}
menu.tick(0.1)
check("the whistle puts a pilot back on the row",
      #menu.stack == 1, table.concat(menu.stack, "/"))
local playing = {}
for _, r in ipairs(menu.view().rail) do playing[#playing + 1] = r.label end
check("and takes the hangar off it", #playing == 3,
      table.concat(playing, "/"))
net.match = nil

-- At the root the same stop is lit while the page under it is only a preview,
-- so a tap there goes in, which is what it has always done.
menu.open = true
menu.home = true
menu.stack = {"root"}
menu.sel = {}
menu.click_rail(ship_at)
check("the lit stop at the root still goes in",
      menu.open and menu.stack[2] == "hangar", table.concat(menu.stack, "/"))
menu.stack = {"root"}
menu.sel = {}

-- --- the call sign in the corner is the way to the pilot page -------------
--
-- There is no pilot stop on the tab row. The name at the far end of that row
-- is the one thing on screen already naming the pilot, so it is the way in.
-- What that has to survive is the guard that shuts a page the row has stopped
-- carrying: it read the second level of the stack against the row and found
-- nothing, so the corner let a pilot in and the next frame put them out.

menu.home = true
menu.stack = {"root"}
menu.sel = {}
menu.click_pilot()
check("the call sign opens the pilot page", menu.at() == "pilot",
      table.concat(menu.stack, "/"))
menu.tick(0.1)
check("and it is still open a frame later", menu.at() == "pilot",
      table.concat(menu.stack, "/"))
local rail_names = {}
for _, r in ipairs(menu.view().rail) do rail_names[#rail_names + 1] = r.label end
check("with no pilot stop on the row itself",
      table.concat(rail_names, "/"):find("pilot") == nil,
      table.concat(rail_names, "/"))
menu.stack = {"root"}
menu.sel = {}

-- --- a tap on a row is still a tap on a row -------------------------------

menu.home = true
menu.class = 0
menu.spectate = false
menu.hull_at = nil
menu.stack = {"root"}
menu.sel = {}
menu.click_rail(ship_at)
menu.pending = nil
local landing_hull = nil
for i, row in ipairs(menu.view().rows) do
    if row.ship then landing_hull = i end
end
menu.click_stage(landing_hull)
check("a stage tap picks from the page it is on", menu.pending == 0,
      "asked for hull " .. tostring(menu.pending))

-- --- the roster is a carousel at the head of the ship page ----------------
--
-- It was a grid: every hull laid out as a cell, the kit of whichever one the
-- cursor stood on drawn beside them, and a second page behind a press for
-- editing that kit. Two thirds of the page went to choosing between eight
-- things you choose between once, and the kit drawn beside the roster looked
-- exactly like the editor while answering no press at all.
--
-- One page now. The ship is the first row of it, the arrows either side of
-- the drawing are what left and right do while the cursor is there, and
-- everything below is the thirty points being spent on it.

menu.hull_at = nil
menu.stack = {"root"}
menu.sel = {}
menu.click_rail(ship_at)
local ship_page = menu.view()
local CELLS = #ship_page.hulls
check("every hull rides the carousel, and sitting out with them",
      CELLS > 1 and ship_page.hull_sel == 1,
      CELLS .. " cells, showing " .. tostring(ship_page.hull_sel))
-- The hull is a flair row near the foot of the page now, with the wake
-- beside it: choosing a shape and choosing a wake are the same kind of
-- choice. No budget row anywhere: the figure rides the view, so the cursor
-- never opens on a readout.
local hull_row, wake_row = nil, nil
for i, r in ipairs(ship_page.rows) do
    if r.ship then hull_row = i end
    if r.group == "flair" and not r.ship then wake_row = i end
end
check("the hull is a flair row, the wake beside it",
      hull_row ~= nil and wake_row == hull_row + 1,
      tostring(hull_row) .. "/" .. tostring(wake_row))
check("and the kit budget rides the view, not a row",
      ship_page.kit_spent ~= nil and ship_page.rows[1].bar == nil,
      tostring(ship_page.kit_spent))
check("live, because there is no level above it left to preview from",
      ship_page.kit_preview == nil, tostring(ship_page.kit_preview))
check("with the cursor on the first thing a press can change",
      ship_page.sel == 1 and ship_page.rows[1].pick == true,
      "cursor " .. tostring(ship_page.sel) .. " on "
      .. tostring(ship_page.rows[1].group))

-- Left and right turn the carousel while the cursor stands on the hull row.
-- At home that is the choice itself: what a hull means with no game on is
-- the ship you will arrive in, and a pilot who spins to one, likes it and
-- walks away should be flying it.
menu.sel.hangar = hull_row
menu.pending = nil
local turned = menu.step({right = true})
check("right turns the carousel",
      menu.hull_index() == 2 and menu.view().hull_sel == 2,
      "showing " .. tostring(menu.hull_index()))
check("and at home turning it is choosing",
      turned == "ship" and menu.pending == 1,
      tostring(turned) .. ", asked for " .. tostring(menu.pending))
menu.step({left = true})
check("left turns it back", menu.hull_index() == 1,
      "showing " .. tostring(menu.hull_index()))

-- It wraps, so nothing on the roster is more than a few presses away and an
-- arrow never does nothing.
local out_act = menu.step({left = true})
check("and it wraps round to the last cell", menu.hull_index() == CELLS,
      "showing " .. tostring(menu.hull_index()))
check("which is sitting out rather than a hull",
      out_act == "spectate" and menu.view().hulls[CELLS].hull == nil,
      tostring(out_act))
-- A cell with no hull and no figure falls back to hull zero and draws an
-- Apex, which is what this one did until `figure` was carried through the
-- view. The drawing reads this field; nothing else can say what it gets.
check("so it says what to draw instead",
      menu.view().hulls[CELLS].figure == "pilot",
      tostring(menu.view().hulls[CELLS].figure))
menu.step({right = true})
check("and back onto the first hull", menu.hull_index() == 1,
      "showing " .. tostring(menu.hull_index()))

-- In a game the same turn is a browse. There a hull ask is a request the room
-- answers and sitting out despawns you, so the press is what commits.
menu.home = false
menu.pending = nil
local browsed = menu.step({right = true})
check("in a game turning it commits nothing",
      browsed == nil and menu.pending == nil,
      tostring(browsed) .. ", asked for " .. tostring(menu.pending))
local picked = menu.step({go = true})
check("and the press is what asks", picked == "ship" and menu.pending == 1,
      tostring(picked) .. ", asked for " .. tostring(menu.pending))
menu.home = true
menu.hull_at = nil

-- Up off the first row goes back to the tab row, which is what up means
-- everywhere in this menu.
menu.stack = {"root", "hangar"}
menu.sel = {}
menu.step({up = true})
check("up from the first row goes back to the tabs", menu.stack[2] == nil,
      table.concat(menu.stack, "/"))

-- The wake steps in a ring, from the keys and from its own act, and what is
-- picked survives the trip through the saved identity's shape.
menu.stack = {"root", "hangar"}
menu.sel = {hangar = wake_row}
menu.wake = 0
menu.step({right = true})
check("right steps the wake", menu.wake == 1, tostring(menu.wake))
menu.step({left = true})
menu.step({left = true})
check("and it wraps the other way", menu.wake == #menu.WAKES - 1,
      tostring(menu.wake))
menu.click_wake(1)
check("the triangles step it too", menu.wake == 0, tostring(menu.wake))
menu.stack = {"root"}
menu.sel = {}

-- The same cell, seen from the rail. The stage previews the page a rail stop
-- leads to before you go in, and that preview flattens rows down its own
-- path, so a field the carousel reads has to survive both. `figure` survived
-- only one: escape into the menu and arrow left onto the rail, and the last
-- cell was an Apex; step into the page and it was the helmet again.
local was_stack, was_sel, was_home = menu.stack, menu.sel, menu.home
menu.home = true
menu.stack = {"root"}
menu.sel = {root = ship_at}
local peek = menu.view()
check("the rail previews the page it points at",
      #peek.hulls == CELLS and peek.sel == 0,
      #(peek.hulls or {}) .. " hulls, cursor " .. tostring(peek.sel))
check("flattened, not handed over as it was written",
      type(peek.hulls[CELLS].mark) ~= "function")
check("and the last cell is a pilot there too",
      peek.hulls[CELLS].figure == "pilot", tostring(peek.hulls[CELLS].figure))
check("and nothing in a preview takes a press",
      peek.kit_preview == true, tostring(peek.kit_preview))
menu.stack, menu.sel, menu.home = was_stack, was_sel, was_home

-- On the home screen the same page answers a different tense: not what you
-- are, which is nothing, but what you will arrive as. So the wash follows the
-- remembered choice there and the live connection in a game, and the two are
-- read through one question rather than by each caller checking `home`.
menu.home = true
menu.stack = {"root", "hangar"}
menu.sel = {}
menu.watching = false
menu.class = 2
menu.spectate = false
check("at home, no choice made yet marks the hull you will arrive in",
      menu.view().hulls[3].mark and not menu.view().hulls[CELLS].mark)
menu.spectate = true
check("and choosing to watch moves the wash to the last cell",
      menu.view().hulls[CELLS].mark and not menu.view().hulls[3].mark)
check("which is what the root row says too",
      menu.view().rail[2].detail == "spectating",
      tostring(menu.view().rail[2].detail))
-- In a game the connection is the truth, whatever was remembered: the server
-- can refuse a hull and the page must not claim you got it.
menu.home = false
check("in a game the connection wins over what was remembered",
      menu.view().hulls[3].mark and not menu.view().hulls[CELLS].mark,
      "spectate remembered but watching is false")
menu.spectate = false
menu.home = true

-- Which cell wears the "you are here" wash follows the connection, not the
-- last hull picked: a watcher is in no hull, so no hull is marked at all.
-- Read off a fresh view each time, since that is where a mark stops being a
-- question and becomes an answer.
menu.home = false
menu.class = 2
menu.watching = false
local flying_view = menu.view().hulls
check("flying marks the hull you are in",
      flying_view[3].mark and not flying_view[CELLS].mark,
      tostring(flying_view[3].mark) .. "/" .. tostring(flying_view[CELLS].mark))
menu.watching = true
local watching_view = menu.view().hulls
check("watching marks the last cell instead, and no hull",
      watching_view[CELLS].mark and not watching_view[3].mark,
      tostring(watching_view[3].mark) .. "/" .. tostring(watching_view[CELLS].mark))
menu.watching = false
menu.home = true
menu.class = 0
menu.hull_at = nil
menu.stack = {"root"}
menu.sel = {}

-- --- the client opens on the games, with the cursor in the list -----------
--
-- Startup shows the zones page rather than the root, so somebody who has just
-- loaded the client is looking at the list of games with the cursor in it and
-- one press from flying. What that rests on is `show` naming a level and the
-- stage taking the cursor when it does.

menu.hover_stage(nil)
menu.home = true
menu.show("play")
local opened = menu.view()
check("showing a level puts the cursor in the stage",
      opened.focus == "stage" and menu.at() == "play",
      tostring(opened.focus) .. " at " .. table.concat(menu.stack, "/"))
check("and on a row of it", opened.sel >= 1 and opened.rows[opened.sel] ~= nil,
      "row " .. tostring(opened.sel) .. " of " .. tostring(#opened.rows))
-- And the rail still says which page that is, since nothing else does now.
check("with the tab lit at the stop it belongs to",
      opened.rail[opened.rail_sel]
          and opened.rail[opened.rail_sel].label == "play",
      "tabs on " .. tostring(opened.rail_sel))

-- --- escape opens on the games, and escape leaves ------------------------
--
-- The key that puts the panel up over a fight has to take it down again, from
-- wherever you have got to in it. It opens one level in now, so walking back
-- out a level at a time would have made leaving cost three presses where it
-- used to cost two.

menu.home = false
menu.open = false
menu.toggle()
check("escape over a game opens on the tab row",
      menu.open and menu.at() == "root" and menu.view().focus == "rail",
      table.concat(menu.stack, "/"))
local opened_match = menu.view()
check("and starts on settings",
      opened_match.rail[opened_match.rail_sel]
          and opened_match.rail[opened_match.rail_sel].label == "settings",
      tostring(opened_match.rail_sel))
menu.click_rail(top_index("settings"))
check("and the rail still goes where it says", menu.at() == "settings",
      table.concat(menu.stack, "/"))
menu.step({back = true})
check("escape from a page inside it puts the fight back", not menu.open,
      "still open at " .. table.concat(menu.stack, "/"))

-- Escape means the same thing with no seat as with one: put the panel away,
-- from whatever level you are on. It used to walk back a level here, which
-- was not a decision but a consequence of the front end refusing to close;
-- both halves of that are gone. Left and the chevron still walk back.
menu.home = true
menu.open = true
menu.show("ship")
menu.step({back = true})
check("escape from a page shuts the menu with no seat too",
      not menu.open, table.concat(menu.stack, "/")
          .. ", open " .. tostring(menu.open))
menu.open = true
menu.show("ship")
menu.step({left = true})
check("but left still walks back a level",
      menu.open and menu.at() == "root", table.concat(menu.stack, "/")
          .. ", open " .. tostring(menu.open))

-- --- choosing the game you are already in asks rather than rejoins --------
--
-- The list used to carry a "leave this game" row at its foot, which is a way
-- out written a long way from the thing it was a way out of, in a list that is
-- otherwise entirely places to go. Leaving is the game's own row now: pressing
-- enter on the one you are in cannot mean join, so it means the other thing it
-- could mean and asks first.

menu.hover_stage(nil)
menu.home = false
menu.zone = "chaos"
menu.ask = nil
menu.show("play")
local zones = menu.view()
-- One game and the community row, headed as two. Discord is not a way out of
-- the game: it is where somebody thinking about who to play with already is,
-- which is the argument for it being here rather than on the tab row. Friends
-- was the third section and is a tab of its own now, because who is on is a
-- question asked from wherever you are standing rather than one you go to the
-- games page to ask. See docs/design/friends.md.
local heads = {}
for _, r in ipairs(zones.rows) do
    if r.sect then heads[#heads + 1] = r.sect end
end
check("the play page is the zones and nothing else",
      table.concat(heads, "/") == "zones", table.concat(heads, "/"))
-- Discord left this page for the same reason friends did: a row on a page is
-- a place you find by going somewhere else first. It is a button in the
-- corner of the top line now, on every page and both layouts, and the view
-- carries the address for it.
check("and the way out to Discord is a corner button, not a row",
      zones.discord ~= nil and zones.rows[1].button == nil,
      tostring(zones.discord))

check("nothing at the foot of the list leaves the game",
      #zones.rows == 1 and zones.rows[1].label == "chaos",
      table.concat(texts_of(zones), ", "))

local act2 = menu.step({go = true})
check("enter on the game you are in asks instead of joining",
      act2 == nil and menu.ask ~= nil,
      tostring(act2) .. ", ask " .. tostring(menu.ask))
check("with the answer that changes nothing under the cursor",
      menu.ask.sel == #menu.ask.keys and menu.ask.keys[menu.ask.sel].act == nil,
      "on " .. tostring(menu.ask.sel) .. " of " .. tostring(#menu.ask.keys))
check("and the view carries it", menu.view().ask == menu.ask)

-- The question owns the keys while it is up. Anything else and the list walks
-- under a card that is asking about the row it walked off.
local before = menu.sel.play
menu.step({down = true})
check("the list underneath cannot be walked", menu.sel.play == before,
      tostring(before) .. " -> " .. tostring(menu.sel.play))
-- Down moved between the answers instead. The answers sit side by side, so
-- left and right are what they are laid out along, but a hand that has been
-- walking a list all the way here reaches for down first.
check("the arrows move between the answers, whichever pair", menu.ask.sel == 1,
      "on " .. tostring(menu.ask.sel))

-- Two answers, and watching is not one of them: this card is about the game
-- you are in, and what you are flying is the ship page's question.
check("the card offers leaving and staying, nothing else",
      #menu.ask.keys == 2 and menu.ask.keys[1].act == "leave",
      #menu.ask.keys .. " answers, first is "
          .. tostring(menu.ask.keys[1].act))
menu.ask.sel = 2
menu.step({left = true})
check("left moves to the answer beside it", menu.ask.sel == 1,
      "on " .. tostring(menu.ask.sel))
local act3 = menu.step({go = true})
check("and enter is worth what that answer is worth",
      act3 == "leave" and menu.ask == nil,
      tostring(act3) .. ", ask " .. tostring(menu.ask))

-- Escape answers it rather than shutting the panel, and answers it with the
-- one that changes nothing: the key that gets out of everything else in here
-- has to get out of this without leaving the game by accident.
menu.step({go = true})
local act4, moved4 = menu.step({back = true})
check("escape answers the question instead of shutting the menu",
      act4 == nil and moved4 and menu.ask == nil and menu.open,
      tostring(act4) .. ", open " .. tostring(menu.open))

-- A different game asks as well, because arriving there costs the game you
-- are in just the same, and the press that costs it is the same press.
menu.zone = "elsewhere"
menu.chosen = nil
local act5 = menu.step({go = true})
check("a different game asks before it takes the one you are in",
      act5 == nil and menu.ask ~= nil, tostring(act5))
menu.ask.sel = 1
local act6 = menu.step({go = true})
check("and the answer that switches is a join",
      act6 == "join" and menu.chosen ~= nil and menu.ask == nil,
      tostring(act6))

-- With nothing behind the panel there is nothing to lose, so nothing to ask.
menu.home = true
menu.ask = nil
local act7 = menu.step({go = true})
check("and from the home screen it just joins",
      act7 == "join" and menu.ask == nil, tostring(act7))

-- --- a password is typed into the card, and the card is the whole flow ----
--
-- The only text entry in this client. Claiming asks for one line, logging in
-- for two; enter sends, escape cancels, and a refusal turns the card into
-- the refusal without eating what was typed.

menu.hover_stage(nil)
menu.ask = nil
menu.home = true
menu.stack = {"root"}
menu.sel = {}
account.claimed = false
-- The call sign in the corner of the tab row rather than a stop on it. There
-- is no pilot tab: a tab whose whole detail is the name written beside it says
-- the name twice, so the name is the control.
check("the tab row has no pilot stop",
      top_index("pilot") == nil,
      table.concat(texts_of(menu.view()), ", "))
menu.click_pilot()
check("and pressing the name opens the page",
      menu.at() == "pilot", table.concat(menu.stack, "/"))
local v_guest = menu.view()
check("a guest is offered the claim and the login",
      texts_of(v_guest)[2] == "keep this pilot"
          and texts_of(v_guest)[3] == "log in",
      table.concat(texts_of(v_guest), ", "))

menu.sel.pilot = 2
menu.step({go = true})
check("keeping this pilot asks for a password, discs and all",
      menu.ask ~= nil and menu.ask.fields ~= nil
          and #menu.ask.fields == 1 and menu.ask.fields[1].mask == true,
      tostring(menu.ask and menu.ask.fields and #menu.ask.fields))
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
check("a refusal keeps the card up with the reason on it",
      menu.ask ~= nil and menu.ask.head == account.refuse .. "."
          and menu.ask.fields[1].value == "abc",
      tostring(menu.ask and menu.ask.head))
account.refuse = nil
menu.ask = nil

-- --- logging in is two lines, walked with the arrows ----------------------

menu.stack = {"root"}
menu.sel = {}
menu.click_pilot()
menu.sel.pilot = 3
menu.step({go = true})
check("logging in asks for a name in the clear and a password in discs",
      menu.ask ~= nil and menu.ask.fields ~= nil and #menu.ask.fields == 2
          and not menu.ask.fields[1].mask and menu.ask.fields[2].mask,
      tostring(menu.ask and menu.ask.fields and #menu.ask.fields))

for ch in string.gmatch("Vesper 412", ".") do menu.type_field(ch) end
check("the name takes its space", menu.ask.fields[1].value == "Vesper 412",
      menu.ask.fields[1].value)
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
check("and escape still walks away", select(2, menu.step({back = true})) == true
          and menu.ask == nil, tostring(menu.ask))
account.refuse = nil

-- --- signed in, the page changes shape ------------------------------------

account.claimed = true
menu.stack = {"root"}
menu.sel = {}
menu.click_pilot()
local v_in = menu.view()
check("a claimed pilot is offered the password change and the way out",
      texts_of(v_in)[2] == "change password"
          and texts_of(v_in)[3] == "log out",
      table.concat(texts_of(v_in), ", "))
menu.sel.pilot = 3
menu.step({go = true})
check("logging out asks first", menu.ask ~= nil and menu.ask.fields == nil,
      tostring(menu.ask))
menu.ask.sel = 1
menu.step({go = true})
check("and the answer that leaves actually leaves",
      account.claimed == false and menu.ask == nil,
      tostring(account.claimed))

-- --- and the one row on the pilot page that throws something away ---------
--
-- A call sign is the only name anybody here has, and it is the name on the
-- scoreboard of every game this pilot has flown. The row showed it and
-- replaced it on the press, with nothing said and nothing to say no to.

menu.zone = ""
menu.chosen = nil
menu.ask = nil
menu.stack = {"root"}
menu.sel = {}
menu.click_pilot()
local was = menu.name
local act8 = menu.step({go = true})
check("rolling a call sign asks first",
      act8 == nil and menu.ask ~= nil and menu.name == was,
      tostring(act8) .. ", name " .. tostring(menu.name))
-- At home the card asks only about the name; there is no ship to cost.
check("and at home says nothing about respawning",
      not string.find(menu.ask.head, "respawns"), menu.ask.head)
menu.step({back = true})
check("and escape keeps the one you have",
      menu.name == was and menu.ask == nil, tostring(menu.name))
menu.step({go = true})
menu.ask.sel = 1
local act9, moved9 = menu.step({go = true})
check("rolling rolls, and the arena is never told",
      menu.name ~= was and act9 == nil and moved9,
      tostring(was) .. " -> " .. tostring(menu.name) .. ", act "
          .. tostring(act9))

-- The cap the server keeps on rerolling, which anybody enjoying the names
-- reaches: thirty an hour from one address. The refusal has to land on the
-- card, because the alternative is what this used to do, which is stop
-- changing the name and say nothing at all about why.
account.refuse = "that is plenty of rerolling. Try again later"
local held = menu.name
local rolls = account.renamed
menu.step({go = true})
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

menu.ask = nil
menu.stack = {"root"}
menu.sel = {}

-- --- mid-game, the same card owes one more sentence -------------------------
--
-- A new name is a new pilot, and a new pilot gets a fresh seat: the client
-- rejoins the game on its own, which costs the ship. The card is the one
-- place that can say so before it happens, and this is the row whose whole
-- design is asking first.

-- Reached the way a player reaches it, which is the front end: the tab row in
-- a match carries only controls that remain useful in the fight. The card knows
-- the difference, because `home` is what it asks and a pilot can be connected
-- with the panel up.
menu.stack = {"root"}
menu.sel = {}
menu.home = true
menu.click_pilot()
menu.home = false
menu.step({go = true})
check("mid-game the card says a roll respawns your ship",
      menu.ask ~= nil and string.find(menu.ask.head, "respawns your ship") ~= nil,
      tostring(menu.ask and menu.ask.head))
menu.step({back = true})
menu.home = true
menu.ask = nil
menu.stack = {"root"}
menu.sel = {}

-- --- a pointer resting on a row is the same cursor the arrows move --------

menu.home = true
menu.stack = {"root"}
menu.sel = {}
menu.hover_stage(nil)
-- The ship page is a ladder a slot only where the arena has said what a kit
-- may hold, so the pointer is tried on one that has rows to land on.
local was_core = _G.sim
_G.sim = {
    UP_COUNT = 5, TRIG_COUNT = 2, MOD_COUNT = 7, MAX_CHARGES = 4,
    SLOT_COUNT = 25, SLOT_LEVEL0 = 5, SLOT_MOD0 = 7, SLOT_CHARGE0 = 21,
    KIT_BUDGET = 30,
    kit_ceilings = function()
        local c = {}
        for i = 1, 25 do c[i] = 3 end
        return c
    end,
}
menu.click_rail(ship_at)
check("a hover moves the cursor", menu.hover_stage(4) and menu.sel.hangar == 4,
      "cursor " .. tostring(menu.sel.hangar))
check("and resting on the same row says nothing more",
      menu.hover_stage(4) == false)
-- A pointer left lying on a row must not put the cursor back on it, or the
-- arrows could never leave the row the mouse happens to be over.
menu.step({down = true})
check("and does not hold the arrows to it", menu.sel.hangar == 5,
      "cursor " .. tostring(menu.sel.hangar))
_G.sim = was_core
menu.kit, menu.kit_class = nil, nil

menu.hover_stage(nil)
menu.stack = {"root"}
menu.sel = {}
local rail_before = menu.view().rail_sel
menu.hover_stage(3)
check("a hover in a preview leaves the rail where it is",
      menu.view().rail_sel == rail_before,
      tostring(rail_before) .. " -> " .. tostring(menu.view().rail_sel))
check("and says where the pointer is instead", menu.view().hover == 3,
      tostring(menu.view().hover))
menu.hover_stage(nil)

-- --- but the rail only ever lights, at every depth -------------------------
--
-- Not the same rule read the other way round, which is what it used to be:
-- the hover moved the cursor wherever the cursor lived, and the cursor lives
-- in the rail at the root and in the stage below it. So the tab row changed
-- the page under the mouse on the home screen and did nothing from inside a
-- page, and which of the two you got depended on how you had arrived. One
-- gesture, two behaviors, no way to tell them apart from the screen.
--
-- On the rail, lit is what a press would open. Never what is open, and never
-- a thing that happens on its own.

menu.stack = {"root"}
menu.sel = {}
menu.hover_stage(nil)
menu.hover_rail(nil)
menu.sel.root = 1
check("a hover at the root lights a stop", menu.hover_rail(ship_at) == true)
check("and leaves the cursor where it was", menu.sel.root == 1,
      "cursor " .. tostring(menu.sel.root))
check("so the stage goes on previewing the tab the arrows are on",
      menu.view().rail_sel == 1, tostring(menu.view().rail_sel))
check("while the view still says where the pointer is",
      menu.view().rail_hover == ship_at, tostring(menu.view().rail_hover))
check("resting on the same stop says nothing more",
      menu.hover_rail(ship_at) == false)
-- And the press is what goes there, which is the half of the gesture that
-- still works.
menu.click_rail(ship_at)
check("pressing it opens that page", menu.at() == "hangar",
      table.concat(menu.stack, "/"))

-- One level in, the same rule, which is the point of it.
menu.sel.hangar = 4
menu.hover_rail(settings_at)
check("a hover from inside a page leaves the cursor alone",
      menu.sel.hangar == 4, "cursor " .. tostring(menu.sel.hangar))
check("and leaves the lit stop saying where you are",
      menu.view().rail_sel == ship_at, tostring(menu.view().rail_sel))
check("and leaving the rail puts it out",
      menu.hover_rail(nil) == false and menu.view().rail_hover == nil,
      tostring(menu.view().rail_hover))

menu.stack = {"root"}
menu.sel = {}

-- --- what the view says about the window does not depend on the page -----
--
-- `home` decides where the whole block is measured from: clear of the corner
-- stack over an arena, centered over the starfield. It used to be
-- `M.home and #M.stack == 1`, which is two questions with one answer, so
-- going a level in on the start screen moved the block as if a game had
-- appeared behind it.

menu.stack = {"root"}
menu.sel = {}
menu.home = true
local at_root = menu.view().home
menu.click_rail(ship_at)
check("the window does not change under the page", menu.view().home == at_root,
      tostring(at_root) .. " -> " .. tostring(menu.view().home))
menu.home = false
menu.stack = {"root"}
check("and over a game it says so", menu.view().home == false,
      tostring(menu.view().home))
menu.home = true

-- --- what the page holds, when the page is holding it ---------------------
--
-- On a touchscreen the lines are input elements on the page rather than
-- strings in here, because a canvas cannot raise a phone's keyboard and an
-- input element can. Nothing above changes: the send still reads
-- `fields[i].value`. What changes is where those values come from, which is
-- one crossing at the moment the card is answered.
--
-- Worth a test of its own because it is the one path where every character a
-- player typed lives outside this program until the instant it is needed,
-- and the failure is silent: an empty send, refused by the server, looks
-- exactly like a wrong password.

local ran = {}
html5 = {run = function (code)
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
html5 = nil

-- --- and every page is reachable from the tab row, which is where it started

-- The controls board and `about` are pages under settings now rather than tabs
-- of their own: both are about the machine rather than about a match, which is
-- what that tab is for.
local function open_controls()
    menu.home = true
    menu.stack = {"root"}
    menu.sel = {}
    menu.click_rail(top_index("settings"))
    local rows = menu.view().rows
    for i, r in ipairs(rows) do
        if string.lower(r.label) == "controls" then
            menu.sel.settings = i
            menu.step({go = true})
            return
        end
    end
end

open_controls()
check("every page is reachable", menu.stack[3] == "controls",
      table.concat(menu.stack, "/"))

-- --- a key on the drawn board is a control, not a diagram ------------------
--
-- The page draws a keyboard and lists the controls under it, and for a while
-- only the list answered a press: you could point at the key a control was on
-- and nothing happened, which is a picture somebody has to be told is not the
-- thing. A click on a key goes to whichever control is asking, and to the one
-- under the cursor when none is.

do
    local binds = require("arena.binds")
    local keyset = require("arena.keys")
    binds.reset()
    open_controls()

    -- The cursor on `map`, and a key nothing is using.
    local rows = menu.view().rows
    local catalog = binds.rows()
    local drift = {}
    for i, control in ipairs(catalog) do
        local row = rows[i]
        if not row or row.label ~= control.name or row.detail ~= control.show
           or row.control ~= control.id or row.cat ~= control.cat
           or row.keys ~= control.keys or row.fixed ~= control.fixed then
            drift[#drift + 1] = control.id
        end
    end
    check("the controls page is built from the live binding catalog",
          #drift == 0 and #rows == #catalog + 1 and rows[#rows].reset == true,
          table.concat(drift, ", "))

    local map_at = nil
    for i, r in ipairs(rows) do
        if r.control == "map" then map_at = i end
    end
    check("the controls page lists the map key", map_at ~= nil)
    menu.sel[menu.at()] = map_at
    local _, moved = menu.click_key("z")
    check("clicking a free key moves the control under the cursor",
          moved and binds.chord_of.map[1] == "z",
          table.concat(binds.chord_of.map, "+"))
    check("and the page says so", (menu.foot or ""):find("map is on Z") ~= nil,
          tostring(menu.foot))

    -- A key somebody else is on: the two trade, and nothing is left over.
    local _, traded = menu.click_key("space")
    check("clicking a taken key trades", traded
          and binds.chord_of.map[1] == "space"
          and binds.chord_of.guns[1] == "z",
          table.concat(binds.chord_of.map, "+") .. " / "
          .. table.concat(binds.chord_of.guns, "+"))

    -- The menu key is nobody's to move, and the page says why rather than
    -- doing nothing. It is the one refusal a pointer can reach: the board
    -- publishes no box for escape, so the other half of the pair cannot be
    -- clicked at all.
    local menu_at = nil
    for i, r in ipairs(rows) do
        if r.control == "menu" then menu_at = i end
    end
    menu.sel[menu.at()] = menu_at
    menu.foot = nil
    menu.click_key("j")
    check("the menu control refuses a key and says why",
          binds.chord_of.menu[1] == "esc"
          and (menu.foot or ""):find("escape") ~= nil,
          tostring(menu.foot))
    check("and escape is not a key the board offers",
          not keyset.bindable("esc"))

    -- The row that resets everything is not a control, so a key has nothing
    -- to land on and the page says which half of the gesture is missing.
    menu.sel[menu.at()] = #rows
    menu.foot = nil
    menu.click_key("j")
    check("a key clicked with no control under the cursor binds nothing",
          binds.control_of.j == nil
          and (menu.foot or ""):find("pick a control") ~= nil,
          tostring(menu.foot))

    -- And while a control is asking, the click answers that rather than the
    -- cursor, which are the same row in the game and need not be here.
    menu.sel[menu.at()] = map_at
    menu.arming = "bombs"
    local _, armed = menu.click_key("k")
    check("a click answers whichever control is asking",
          armed and binds.chord_of.bombs[1] == "k" and menu.arming == nil,
          table.concat(binds.chord_of.bombs, "+"))

    -- A chord comes off the keyboard rather than a click, since there is no
    -- holding two keys down in one press of a mouse.
    menu.arming = "map"
    local chorded = menu.bind_chord({"shift", "j"})
    check("a chord typed at an asking control lands whole",
          chorded and table.concat(binds.chord_of.map, "+") == "shift+j",
          table.concat(binds.chord_of.map, "+"))

    -- Every key the picture draws is one the catalog will take. The board
    -- publishes a box per key and this is the other end of that promise.
    check("and the board only offers keys that bind",
          keyset.bindable("backslash") and keyset.bindable("slash")
          and not keyset.bindable("caps") and not keyset.bindable("enter"))
    binds.reset()
    menu.foot = nil
end

-- --- and the view carries what the board needs to draw itself -------------
--
-- The rows the page holds and the rows it hands the renderer are two shapes,
-- and the second is built by copying named fields out of the first. A field
-- that gets renamed on one side and not the other is invisible from both: the
-- page goes on holding the right answer and the drawing goes on asking for a
-- name nothing sets. That shipped once. Every key on the board came out
-- unlit, because the chords were in the rows and `keys` was being read from a
-- flattened row that still said `key`.
--
-- board_test builds its own rows and cannot see this; it is only visible from
-- the far end of `M.view`.

do
    local binds = require("arena.binds")
    binds.reset()
    -- Nothing ships on a chord, so one is bound here: what this checks is
    -- that a chord survives the trip to the drawing, not that any particular
    -- control starts on one.
    binds.set("map", {"shift", "tab"})
    menu.stack = {"root"}
    open_controls()
    local v = menu.view()
    local mute, unnamed = {}, {}
    for _, r in ipairs(v.rows) do
        -- Every row but the one that resets everything stands for a control,
        -- and every control has a chord and a color band.
        if not r.reset then
            if not (r.keys and #r.keys > 0) then
                mute[#mute + 1] = tostring(r.label)
            end
            if not r.cat then unnamed[#unnamed + 1] = tostring(r.label) end
        end
    end
    check("every drawn row carries the keys it is on", #mute == 0,
          table.concat(mute, ", "))
    check("and the color band the board lights it in", #unnamed == 0,
          table.concat(unnamed, ", "))

    -- And a chord arrives whole rather than as its trigger.
    local chorded = nil
    for _, r in ipairs(v.rows) do
        if r.control == "map" then chorded = r end
    end
    check("a chord reaches the drawing with both its keys",
          chorded ~= nil and #chorded.keys == 2
          and table.concat(chorded.keys, "+") == "shift+tab",
          chorded and table.concat(chorded.keys or {}, "+") or "no map row")
    binds.reset()
end

-- --- the discord stop leaves, rather than going somewhere in here ----------
--
-- Every other row pushes a page onto the stack. This one hands a URL to the
-- browser and leaves the stack where it was, so the two things worth pinning
-- are that it opens the right address in a new tab and that it does not
-- quietly navigate the menu somewhere as well.
--
-- It sits at the foot of the play page rather than on the tab row. That is
-- where somebody is already thinking about who to play with, and it is the one
-- outbound link in a game that carries no chat.

local function discord_row()
    menu.home = true
    menu.stack = {"root"}
    menu.sel = {}
    menu.click_rail(top_index("play"))
    for i, r in ipairs(menu.view().rows) do
        if r.button == "discord" then return i end
    end
    return nil
end

local function open_about()
    menu.home = true
    -- Said rather than assumed. The front end used to hold the menu open on
    -- its own, so every helper in here inherited an open panel; nothing opens
    -- it but a player now.
    menu.open = true
    menu.stack = {"root"}
    menu.sel = {}
    menu.click_rail(top_index("settings"))
    for i, r in ipairs(menu.view().rows) do
        if string.lower(r.label) == "about" then
            menu.sel.settings = i
            menu.step({go = true})
            return
        end
    end
end

do
    local asked = nil
    _G.sys.open_url = function(url, attrs)
        asked = {url = url, target = attrs and attrs.target}
        return true
    end

    menu.open = true
    -- No row to press any more: Discord is a button in the corner of the top
    -- line, on every page and both layouts, and this is the press it takes.
    check("the play page has no discord row left", discord_row() == nil,
          "still a row")

    -- And that press opens a page rather than a browser tab. What the button
    -- used to do was leave the game for somewhere the player had not been
    -- told about, which is a fine control once you know what is behind it and
    -- a poor one the first time.
    menu.home = true
    menu.stack = {"root"}
    menu.sel = {}
    menu.open_discord()
    check("the corner button opens a page about the server",
          menu.at() == "discord", table.concat(menu.stack, "/"))
    check("and nothing has left for the browser yet", asked == nil,
          asked and asked.url or "")

    -- One row, and it is the way out, so a hand on the arrows presses enter
    -- twice and is there. Everything else the page says it says as words
    -- rather than as rows: three of the four rows this used to have went
    -- nowhere and were set in the face and size of rows that do.
    local view = menu.view()
    local page = view.rows
    check("the page has one row and it is the invite",
          #page == 1 and page[1].pick == true,
          #page .. " rows")
    check("carrying the address, so the browser can lay an anchor over it",
          page[1] and page[1].link == "https://play.vectorwake.net/discord",
          page[1] and tostring(page[1].link))
    check("and it is drawn as the page about the door",
          view.door == true, tostring(view.door))
    check("which leads with the reason to use it",
          view.door_head == "Rally for the next match.",
          tostring(view.door_head))
    check("and explains the room in one short block",
          type(view.door_body) == "string"
          and string.find(view.door_body, "Meet pilots", 1, true) ~= nil,
          tostring(view.door_body))
    check("with the tab behavior beside the action",
          type(view.door_note) == "string"
          and string.find(view.door_note, "new tab", 1, true) ~= nil,
          tostring(view.door_note))
    -- The one address, cut from the one constant. Two copies of an address is
    -- one address that goes stale.
    check("and the address a player can retype, with no scheme on it",
          view.door_addr == "play.vectorwake.net/discord",
          tostring(view.door_addr))
    check("which is the address the button opens",
          view.door_addr and page[1].link:sub(-#view.door_addr)
              == view.door_addr,
          tostring(view.door_addr) .. " against " .. tostring(page[1].link))

    menu.step({go = true})
    check("pressing it asks the browser to open the invite",
          asked and asked.url == "https://play.vectorwake.net/discord",
          asked and asked.url or "nothing asked")
    check("in a new tab", asked and asked.target == "_blank",
          asked and tostring(asked.target))
    -- The redirect, not the invite: an invite that has to be reissued should
    -- be one line of Caddy rather than a client release.
    check("and it is the redirect rather than a discord.gg link",
          asked and not asked.url:find("discord.gg", 1, true))
    check("and the menu stays on the page", menu.at() == "discord",
          table.concat(menu.stack, "/"))
    check("which left is still the way out of",
          select(1, menu.step({left = true})) == nil and menu.at() == "root",
          table.concat(menu.stack, "/"))

    menu.stack = {"root", "play"}

    -- Nothing is put on screen when the browser says no, and there is no
    -- browser here to say yes: a card with the address and an OK on it is
    -- what a phone actually got, and a card is not a link.
    menu.stack = {"root"}
    menu.sel = {}
    menu.note = nil
    _G.sys.open_url = function() return false end
    menu.click_rail(top_index("discord"))
    check("a refusal puts nothing on screen", menu.view().ask == nil,
          tostring(menu.view().ask and menu.view().ask.head))

    -- The account is minted before a player has a reason to visit the bare
    -- site, so the about page carries the two documents that govern it.
    for label, url in pairs({privacy = "https://vectorwake.net/privacy",
                             terms = "https://vectorwake.net/terms"}) do
        asked = nil
        menu.ask = nil
        _G.sys.open_url = function(got, attrs)
            asked = {url = got, target = attrs and attrs.target}
            return true
        end
        open_about()
        local row = nil
        for i, entry in ipairs(menu.view().rows) do
            if entry.label == label then row = i end
        end
        check("about carries " .. label, row ~= nil, "absent")
        if row then menu.click_stage(row) end
        check(label .. " opens the public document",
              asked and asked.url == url and asked.target == "_blank",
              asked and asked.url or "nothing asked")
    end

    -- And an engine with no open_url at all does not take the menu down.
    _G.sys.open_url = nil
    local link = discord_row()
    local ok = pcall(menu.click_stage, link)
    check("an engine without open_url survives the tap", ok)
end

-- --- and on the web the page holds a real link over it --------------------
--
-- Nothing the client does from its own loop is inside the tap that asked for
-- it, and a browser will not open a tab for anything else: desktop allowed a
-- frame-late window.open, every phone called it a popup and blocked it. So
-- the view carries the address for the page to lay an anchor over, and the
-- finger lands on that rather than on the canvas.

do
    menu.open = true
    menu.stack = {"root", "play"}
    local view = menu.view()
    check("the view carries the address", view.discord ~= nil, "none")
    check("and it is the redirect",
          view.discord == "https://play.vectorwake.net/discord",
          tostring(view.discord))
    -- No row does, or the page would put a link over a page of the game's
    -- own. It is one button in the corner and nothing else.
    local strays = {}
    for _, r in ipairs(view.rows) do
        if r.link then strays[#strays + 1] = r.label end
    end
    check("and no row does", #strays == 0, table.concat(strays, ", "))
end

-- `about` is a page under settings rather than a tab of its own, on the same
-- argument as the controls board: it is about the machine and not about a
-- match, and it is three lines that never deserved a destination.

-- Policy rows navigate the current browser tab. A new tab requested from
-- the game loop is outside the original tap and mobile browsers block it.
do
    local js
    _G.html5 = {run = function(code) js = code return "" end}
    for label, url in pairs({privacy = "https://vectorwake.net/privacy",
                             terms = "https://vectorwake.net/terms"}) do
        js = nil
        open_about()
        local row = nil
        for i, entry in ipairs(menu.view().rows) do
            if entry.label == label then row = i end
        end
        if row then menu.click_stage(row) end
        check("a browser navigates to " .. label,
              js and js:find("window.location.assign", 1, true)
                  and js:find(url, 1, true),
              tostring(js))
    end
    _G.html5 = nil
end

-- --- friends -----------------------------------------------------------------
--
-- Five sections from one reply, a field to type a call sign into, and the
-- four things a row can carry: accept, ignore, join, unfriend. The buttons
-- are drawn off each row's own `acts`, and the card a press of the row raises
-- is built from the same list, so a d-pad is offered what a pointer is.

do
    -- Saved and put back, so this block leaves the menu where it found
    -- it. Named apart from the three at the top of the file, which do the
    -- same job for a different block.
    local kept_home, kept_stack, kept_sel = menu.home, menu.stack, menu.sel
    local dir = package.loaded["arena.directory"]
    account.friends = {
        {account = 11, name = "Rill 121", zone = "melee", instance = "abc"},
        {account = 12, name = "Sable 4", zone = "", instance = ""},
    }
    account.asked = {{account = 13, name = "Kestrel 9", ago = 7200}}
    account.here = {{account = 14, name = "Vantage 2"}}
    account.waiting = {{account = 15, name = "Marl 30", ago = 90000}}
    account.everybody = {
        {account = 16, name = "Cirrus 55", ago = 345600, state = "ignored"},
        {account = 13, name = "Kestrel 9", ago = 7200, state = "waiting"},
        {account = 11, name = "Rill 121", ago = 900000, state = "friend"},
    }
    account.have_friends = true
    dir.instances = {abc = {zone = "melee", address = "ws://a", wt = ""}}

    menu.home = true
    menu.stack = {"root", "friends"}
    menu.sel = {}
    local v = menu.view()
    local said = {}
    for _, r in ipairs(v.rows) do
        said[#said + 1] = r.label .. "/" .. tostring(r.detail)
            .. "/" .. tostring(r.sect)
    end
    check("the page is every list in one", #v.rows == 8,
          table.concat(said, " "))
    -- The page it draws is its own, not the list renderer's: an add field
    -- over sections whose rows carry buttons.
    check("and it is drawn as a page rather than a list", v.social == true,
          tostring(v.social))

    -- Whoever is waiting on an answer is first, because it is the only
    -- section asking anything of you.
    check("the inbox opens the page",
          v.rows[1].sect == "waiting on you"
          and v.rows[1].label == "Kestrel 9"
          and v.rows[1].detail == "added you 2h ago",
          said[1])
    check("and it says how many and what the two buttons do",
          v.rows[1].sect_note == "1"
          and string.find(v.rows[1].sect_line or "", "ignore", 1, true) ~= nil,
          tostring(v.rows[1].sect_note) .. "/"
          .. tostring(v.rows[1].sect_line))
    check("with accept and ignore on it",
          v.rows[1].acts[1].act == "do_befriend"
          and v.rows[1].acts[2].act == "do_ignore",
          tostring(v.rows[1].acts[1].label))

    check("a friend in a game says which one",
          v.rows[2].label == "Rill 121" and v.rows[2].detail == "melee"
          and v.rows[2].sect == "friends", said[2])
    check("and the head counts them and how many are on",
          v.rows[2].sect_note == "2, 1 flying", tostring(v.rows[2].sect_note))
    -- One head per run. The list renderer draws a head wherever it finds a
    -- `sect` and dedupes nothing, so a section label on every row is that
    -- label over every row.
    check("and the head belongs to the row that opens the run",
          v.rows[3].sect == nil, said[3])
    check("and one who is not on says so", v.rows[3].detail == "not on",
          said[3])
    -- Spelled out on every layout. It was a cross on a phone, which is the
    -- mark for shutting a panel everywhere else in this interface.
    check("a friend can be joined and unfriended, in that order",
          v.rows[2].acts[1].act == "do_join_friend"
          and v.rows[2].acts[2].label == "unfriend",
          tostring(v.rows[2].acts[2] and v.rows[2].acts[2].label))
    check("and one who is not on has only the one button",
          #v.rows[3].acts == 1 and v.rows[3].acts[1].label == "unfriend",
          tostring(#v.rows[3].acts))

    -- Adds nobody has answered, straight under the friends they are trying to
    -- join: they asked you, it closed, you asked them, in that order. It was
    -- headed "you added", which names the press rather than what is sitting
    -- there, and it sat below the room roster.
    check("what you sent sits under the friends it is trying to join",
          v.rows[4].sect == "sent" and v.rows[4].detail == "yesterday",
          said[4])
    check("the room you are in comes after it",
          v.rows[5].sect == "in this game"
          and v.rows[5].acts[1].act == "do_befriend", said[5])

    -- And the list that makes an ignore reversible. The ignored are the only
    -- rows on it anybody presses; the rest are what makes the heading true.
    check("everybody who added you closes the page",
          v.rows[6].sect == "everybody who added you"
          and v.rows[6].label == "Cirrus 55"
          and v.rows[6].detail == "ignored 4d ago", said[6])
    check("an ignored pilot can still be accepted",
          #v.rows[6].acts == 1
          and v.rows[6].acts[1].act == "do_befriend", said[6])
    check("and the ones it already came to something press nothing",
          #v.rows[7].acts == 0 and #v.rows[8].acts == 0
          and v.rows[7].detail == "waiting on you"
          and v.rows[8].detail == "friend",
          said[7] .. " " .. said[8])

    -- And the card that says there is nobody stays down while there is
    -- somebody: a page saying two things at once has one of them wrong.
    check("with no card saying the page is empty", v.empty == nil,
          tostring(v.empty and v.empty.head))

    -- --- the buttons
    --
    -- A pointer presses one directly. `which` is its place in that row's own
    -- list, so the drawing and the press agree by construction.
    account.friended, account.ignored = nil, nil
    menu.click_friend(1, 1)
    check("accepting is an add", account.friended ~= nil
          and account.friended.who == 13 and account.friended.add == true,
          tostring(account.friended and account.friended.who))
    menu.click_friend(1, 2)
    check("and ignoring is its own call", account.ignored ~= nil
          and account.ignored.who == 13 and account.ignored.on == true,
          tostring(account.ignored and account.ignored.who))
    account.friended = nil
    menu.click_friend(3, 1)
    check("unfriending takes both directions", account.friended ~= nil
          and account.friended.who == 12 and account.friended.add == false,
          tostring(account.friended and account.friended.who))
    -- And taking back an add you sent is the same call from the other end.
    account.friended = nil
    menu.click_friend(4, 1)
    check("and cancelling what you sent takes it back",
          account.friended ~= nil and account.friended.who == 15
          and account.friended.add == false,
          tostring(account.friended and account.friended.who))
    account.friended = nil
    menu.click_friend(6, 1)
    check("and accepting an ignored pilot is the same add",
          account.friended ~= nil and account.friended.who == 16
          and account.friended.add == true,
          tostring(account.friended and account.friended.who))
    check("a row with no buttons answers nothing",
          select(2, menu.click_friend(7, 1)) == false,
          tostring(select(2, menu.click_friend(7, 1))))

    -- --- five inputs get the same list as a card
    menu.sel.friends = 2
    menu.ask = nil
    menu.step({go = true})
    check("a friend asks rather than acting", menu.ask ~= nil,
          tostring(menu.ask))
    check("and offers the game they are in first",
          menu.ask.keys[1].label == "join melee"
          and menu.ask.keys[1].act == "do_join_friend",
          menu.ask.keys[1] and menu.ask.keys[1].label or "no key")
    check("with the answer that changes nothing under the cursor",
          menu.ask.sel == #menu.ask.keys
          and menu.ask.keys[menu.ask.sel].act == nil,
          "on " .. tostring(menu.ask.sel))
    -- Joining is the arena's half: this file names the pilot and stops.
    local joined = menu.click_answer(1)
    check("joining names the pilot and leaves the socket to the arena",
          joined == "join_friend" and menu.pending == 11,
          tostring(joined) .. "/" .. tostring(menu.pending))

    -- The inbox card carries both answers, in the order the buttons are in.
    menu.sel.friends = 1
    menu.step({go = true})
    check("the inbox card offers accept then ignore",
          menu.ask.keys[1].act == "do_befriend"
          and menu.ask.keys[2].act == "do_ignore",
          tostring(menu.ask.keys[1].label))

    -- A friend the directory is no longer listing reads as on and is not
    -- joinable, which is the honest answer for an arena that has just gone.
    dir.instances = {}
    menu.ask = nil
    menu.sel.friends = 2
    menu.step({go = true})
    check("an unlisted instance is on but not joinable",
          menu.ask ~= nil and menu.ask.keys[1].act == "do_unfriend",
          menu.ask and menu.ask.keys[1].label or "no card")
    menu.ask = nil

    -- --- the add field
    --
    -- The one way onto this page that does not start with the two of you
    -- being in the same room. It needs the call sign whole: nothing is
    -- offered and nothing is searched.
    menu.add_name, menu.add_on = "", false
    check("typing lights the field",
          menu.type_add("H") and menu.add_name == "H" and menu.add_on == true,
          menu.add_name)
    menu.type_add("a")
    check("and backspace takes it back",
          menu.rub_add() and menu.add_name == "H", menu.add_name)
    check("and the mark on its end empties it",
          select(2, menu.wipe_add()) == true and menu.add_name == "",
          menu.add_name)

    account.friended = nil
    menu.add_name, menu.add_on = "Halcyon 1", true
    menu.send_add()
    check("sending it names the pilot rather than numbering them",
          account.friended ~= nil and account.friended.who == "Halcyon 1"
          and account.friended.add == true,
          tostring(account.friended and account.friended.who))
    check("and the field empties on the way out", menu.add_name == ""
          and menu.add_on == false, menu.add_name)

    -- Answered here, because the meta-layer would have to be told the call
    -- sign to say it back and nothing needs to go out to know this.
    -- --- and what the box turns up as you type
    --
    -- A call sign is a word and three digits and it has to be exact, which is
    -- a small task nobody should have to be careful about. So the meta-layer
    -- answers a prefix and the names land under the box.
    account.found, account.found_for = {}, ""
    menu.add_name, menu.add_on = "", false
    menu.type_add("H")
    check("one letter asks for nothing",
          account.asked_for == nil or account.asked_for == "",
          tostring(account.asked_for))
    menu.type_add("a")
    check("and two asks", account.asked_for == "Ha", tostring(account.asked_for))
    account.found_for = "Ha"
    account.found = {{account = 31, name = "Halcyon 1"},
                     {account = 32, name = "Halcyon 12"}}
    check("the page draws what came back",
          #menu.view().add.found == 2, tostring(#menu.view().add.found))
    -- Only while the answer is about what is in the box. A reply to an older
    -- prefix is a list of the wrong names sitting under the right ones.
    menu.type_add("l")
    check("and drops it the moment the box says something else",
          #menu.view().add.found == 0, tostring(#menu.view().add.found))

    -- Pressed, it adds that pilot by number rather than by the letters in the
    -- box: two call signs can open the same way and only one was pressed.
    account.found_for = menu.add_name
    account.found = {{account = 31, name = "Halcyon 1"},
                     {account = 32, name = "Halcyon 12"}}
    account.friended = nil
    menu.click_found(2)
    check("pressing a name adds that pilot by number",
          account.friended ~= nil and account.friended.who == 32
          and account.friended.add == true,
          tostring(account.friended and account.friended.who))
    check("and the box empties behind it",
          menu.add_name == "" and #account.found == 0,
          menu.add_name .. "/" .. tostring(#account.found))

    account.friended = nil
    menu.name = "Quarrel 214"
    menu.add_name, menu.add_on = "quarrel 214", true
    menu.send_add()
    check("your own call sign is answered without asking anybody",
          account.friended == nil and account.friend_note == "that is you."
          and account.friend_bad == true,
          tostring(account.friend_note))
    account.friend_note, account.friend_bad = "", false

    -- Enter sends the field rather than pressing the row the cursor is on,
    -- while the field is the thing taking type.
    account.friended = nil
    menu.add_name, menu.add_on = "Ozone 42", true
    menu.step({go = true})
    check("enter sends what is in the field",
          account.friended ~= nil and account.friended.who == "Ozone 42",
          tostring(account.friended and account.friended.who))

    -- --- and the arrows reach it
    --
    -- The field is a stop above the first row. Before this the only way into
    -- it was to start typing, which is a control you have to already know is
    -- there: nothing on the page said so and no arrow went anywhere near it.
    account.found, account.found_for = {}, ""
    menu.add_name, menu.add_on, menu.found_sel = "", false, nil
    menu.stack = {"root"}
    menu.sel = {root = 4}
    menu.step({down = true})
    check("down off the tabs opens friends with the cursor in the field",
          menu.at() == "friends" and menu.add_on == true,
          menu.at() .. "/" .. tostring(menu.add_on))
    menu.step({down = true})
    check("and down again goes on to the list",
          menu.at() == "friends" and menu.add_on == false,
          tostring(menu.add_on))
    menu.sel.friends = 1
    menu.step({up = true})
    check("up off the first row comes back to it", menu.add_on == true,
          tostring(menu.add_on))
    menu.step({up = true})
    check("and up out of it goes back to the tabs",
          menu.at() == "root" and menu.add_on == false,
          menu.at() .. "/" .. tostring(menu.add_on))

    -- With names under the box the arrows walk those first. The list is drawn
    -- over the sections, so a cursor stepping straight past it into the rows
    -- underneath would be a cursor nobody can see.
    menu.stack = {"root", "friends"}
    menu.sel = {friends = 1}
    menu.add_name, menu.add_on, menu.found_sel = "Ha", true, nil
    account.found_for = "Ha"
    account.found = {{account = 31, name = "Halcyon 1"},
                     {account = 32, name = "Halcyon 12"}}
    menu.step({down = true})
    check("down out of the field walks what it turned up",
          menu.found_sel == 1 and menu.add_on == true,
          tostring(menu.found_sel))
    menu.step({down = true})
    check("and the next name after that", menu.found_sel == 2,
          tostring(menu.found_sel))
    check("and the page says which one is lit",
          menu.view().add.sel == 2, tostring(menu.view().add.sel))
    -- Enter on a name is a press on that name, not on the letters that found
    -- it: two call signs can open the same way.
    account.friended = nil
    menu.step({go = true})
    check("enter on one adds that pilot by number",
          account.friended ~= nil and account.friended.who == 32
          and menu.found_sel == nil,
          tostring(account.friended and account.friended.who))

    menu.add_name, menu.add_on, menu.found_sel = "Ha", true, 1
    account.found_for = "Ha"
    account.found = {{account = 31, name = "Halcyon 1"}}
    menu.step({down = true})
    check("and down off the last name goes on to the page",
          menu.add_on == false and menu.found_sel == nil,
          tostring(menu.add_on) .. "/" .. tostring(menu.found_sel))
    account.found, account.found_for = {}, ""
    menu.add_name, menu.add_on = "", false

    -- The page a new player sees is the one that most needs this: nobody on
    -- it, nothing to walk, and a field that is the only thing there. The page
    -- gives up on the arrows when it has no rows, and under that the box was
    -- reachable on every friends page except that one.
    do
        local kept = {account.friends, account.asked, account.here,
                      account.waiting, account.everybody}
        account.friends, account.asked, account.here = {}, {}, {}
        account.waiting, account.everybody = {}, {}
        menu.stack = {"root", "friends"}
        menu.sel = {}
        menu.add_name, menu.add_on, menu.found_sel = "", false, nil
        check("an empty friends page lists nobody", #menu.view().rows == 0,
              tostring(#menu.view().rows))
        menu.step({up = true})
        check("and the arrows still reach its field",
              menu.at() == "friends" and menu.add_on == true,
              menu.at() .. "/" .. tostring(menu.add_on))
        menu.step({down = true})
        check("and stay in it, since there is nothing below to go to",
              menu.add_on == true, tostring(menu.add_on))
        menu.step({up = true})
        check("and up out of it still goes back to the tabs",
              menu.at() == "root" and menu.add_on == false,
              menu.at() .. "/" .. tostring(menu.add_on))
        account.friends, account.asked, account.here = kept[1], kept[2], kept[3]
        account.waiting, account.everybody = kept[4], kept[5]
    end

    -- And the field is the page's, not the rail's preview of it. A letter
    -- typed at the top of the menu would land in a box nobody can see.
    menu.stack = {"root"}
    menu.sel = {root = 3}
    check("nothing types into a page you are only looking at",
          menu.type_add("x") == false, menu.add_name)

    -- Nor into a shut menu. The model keeps its stack when the panel comes
    -- down, and in a match the shut menu parks where friends is the first
    -- tab, so the letters a pilot's hands make in a fight, P and M and H
    -- driving the HUD among them, were landing in the invisible box and
    -- surfacing as a garbage call sign the next time the menu opened.
    menu.stack = {"root", "friends"}
    menu.open = false
    menu.add_name = ""
    check("nothing types into a shut menu",
          menu.type_add("p") == false and menu.add_name == "",
          menu.add_name)
    check("and nothing rubs one",
          menu.rub_add() == false)
    menu.open = true

    -- The games page asks for this too, because the row on it counts friends
    -- in a game and a count that only arrives once you have opened the page it
    -- is advertising cannot be the reason you open it.
    account.asked_friends = 0
    menu.stack = {"root"}
    menu.sel = {root = 1}
    menu.show("play")
    menu.tick(0.1)
    check("the games page asks who is on", account.asked_friends > 0,
          tostring(account.asked_friends))

    account.friends, account.asked, account.here = {}, {}, {}
    account.waiting, account.everybody = {}, {}
    menu.add_name, menu.add_on = "", false
    menu.home, menu.stack, menu.sel = kept_home, kept_stack, kept_sel
end

-- --- the hangar: thirty points, spent -----------------------------------------
--
-- Picking a hull descends into what thirty points buy on it. Only the slots
-- the hull will take and the account owns appear, left and right spend and
-- unspend, and the budget is what every row is spending against.

do
    -- The core's own shape and ceilings, stubbed the way the extension
    -- publishes them: an arena that will take four steps of the first stat,
    -- one rung of the gun, and three repels, and nothing else.
    --
    -- Six add-ons and twenty-three slots. It was seven and twenty-five: gun
    -- spray and a "double barrel" were two ladders that both meant more
    -- bullets, and they are one. `kit_ceilings` takes no argument, because
    -- the roster has nothing to say about what a kit may hold.
    local CEIL = {}
    for i = 1, 23 do CEIL[i] = 0 end
    CEIL[1] = 4          -- the first stat
    CEIL[6] = 2          -- the gun's ladder
    CEIL[20] = 3         -- the first charge
    _G.sim = {
        UP_COUNT = 5, TRIG_COUNT = 2, MOD_COUNT = 6, MAX_CHARGES = 4,
        MOD_MULTI = 0, KIT_CHARGE_SLOTS = 2,
        SLOT_COUNT = 23, SLOT_LEVEL0 = 5, SLOT_MOD0 = 7, SLOT_CHARGE0 = 19,
        KIT_BUDGET = 6,
        kit_ceilings = function(cls)
            assert(cls == nil, "the hangar asks the arena, not a hull")
            return CEIL
        end,
        hull_extent = function(cls) return 20 - cls, 11, 10 end,
    }
    account.entitlements = {}
    account.kits = {}

    -- --- which key throws which charge -------------------------------------
    --
    -- A kit carries two kinds, and which of them the first key spends is the
    -- only thing left to decide once both are aboard. The kit is counts by
    -- kind and the core numbers the kinds, so without a preference the
    -- lower-numbered one always came first.
    do
        -- Two kinds aboard, which is what a slot each means. The ceiling this
        -- block sets up carries one, so the second is opened for this check
        -- and shut again after it.
        CEIL[21] = 3
        menu.charge_flip = false
        menu.kit, menu.kit_class = nil, nil
        menu.stack = {"root", "hangar"}
        menu.sel = {}
        menu.open_kit(0)
        menu.kit_set(19, 1)
        menu.kit_set(20, 1)
        local function charges()
            local out = {}
            for _, r in ipairs(menu.view().rows) do
                if r.charge_slot then out[r.charge_slot] = r.label end
            end
            return out
        end
        local first = charges()
        check("both charges say which slot they are in",
              first[1] ~= nil and first[2] ~= nil and first[1] ~= first[2],
              tostring(first[1]) .. "/" .. tostring(first[2]))
        menu.swap_charges()
        local swapped = charges()
        check("and swapping them trades the two",
              swapped[1] == first[2] and swapped[2] == first[1],
              tostring(swapped[1]) .. "/" .. tostring(swapped[2]))
        check("which is a preference rather than a change to the ship",
              menu.charge_flip == true, tostring(menu.charge_flip))
        menu.swap_charges()
        check("and swapping again puts them back",
              charges()[1] == first[1], tostring(charges()[1]))
        -- And enter on a charge row is that press. On a ladder enter only
        -- ever repeated what right does, so the row spends it on the other
        -- question it answers.
        local at = nil
        for i, r in ipairs(menu.view().rows) do
            if r.charge_slot == 1 then at = i end
        end
        check("a charge row is on the page", at ~= nil, "none")
        menu.sel.hangar = at
        menu.step({go = true})
        check("and enter on it swaps the two",
              charges()[1] == first[2], tostring(charges()[1]))
        menu.swap_charges()
        CEIL[21] = 0
        menu.charge_flip = false
        menu.kit, menu.kit_class = nil, nil
    end


    menu.home = true
    menu.class = 0
    menu.hull_at = nil
    menu.kit, menu.kit_class = nil, nil
    menu.stack = {"root"}
    menu.sel = {}
    menu.click_rail(top_index("ship"))
    local v = menu.view()
    local labels = {}
    local hull_at2, wake_at2 = nil, nil
    for i, r in ipairs(v.rows) do
        labels[#labels + 1] = r.label
        if r.ship then hull_at2 = i end
        if r.group == "flair" and not r.ship then wake_at2 = i end
    end
    check("the arena's slots and the add key are on the page",
          #v.rows == 6, table.concat(labels, ", "))
    -- The library first, then the slots, then flair: the hull with the wake
    -- beside it at the foot, since choosing a shape and choosing a wake are
    -- the same kind of choice. This account has no profiles, so the head of
    -- the page is the one chip that does not need any. No budget row
    -- anywhere: the figure rides the view, so the cursor never opens on a
    -- readout.
    check("with the hull and the wake in the flair at the foot",
          hull_at2 == #v.rows - 1 and wake_at2 == #v.rows
              and v.rows[hull_at2].detail == "Apex",
          table.concat(labels, ", "))
    check("and the budget riding the view rather than a row",
          v.kit_spent ~= nil and v.kit_total == 6,
          tostring(v.kit_spent) .. "/" .. tostring(v.kit_total))

    menu.sel.hangar = hull_at2
    local pressed = menu.step({go = true})
    check("pressing the hull row asks for the hull under it",
          pressed == "ship" and menu.pending == 0, tostring(pressed))
    check("and stays on the page, because its kit is the rest of it",
          menu.at() == "hangar", table.concat(menu.stack, "/"))

    -- Right spends a point, left takes it back, and neither goes anywhere.
    -- Found rather than counted to: the library rides above the stats, so
    -- which row the first of them is depends on how many builds this pilot
    -- has saved.
    local function first_slot()
        for i, r in ipairs(menu.view().rows) do
            if r.act == "kit_step" then return i end
        end
    end
    local slot1 = first_slot()
    menu.sel.hangar = slot1
    menu.step({right = true})
    check("right spends a point",
          menu.kit[1] == 1 and menu.at() == "hangar",
          tostring(menu.kit[1]) .. " at " .. table.concat(menu.stack, "/"))
    menu.step({right = true})
    menu.step({right = true})
    check("and again", menu.kit[1] == 3, tostring(menu.kit[1]))
    menu.step({left = true})
    check("left takes one back",
          menu.kit[1] == 2 and menu.at() == "hangar",
          tostring(menu.kit[1]) .. " at " .. table.concat(menu.stack, "/"))

    -- The arena's ceiling, which is the zone's own rule and not a budget.
    for _ = 1, 6 do menu.step({right = true}) end
    check("and never past the arena's ceiling", menu.kit[1] == 4,
          tostring(menu.kit[1]))

    -- The budget, which is what every row on the page is spending against.
    menu.sel.hangar = slot1 + 2
    for _ = 1, 6 do menu.step({right = true}) end
    check("nor past the budget", menu.kit_spent() == 6,
          tostring(menu.kit_spent()))

    -- What the account owns is the other ceiling. This one owns two of the
    -- first stat and nothing else has moved, so the page stops at two.
    account.entitlements = {[1] = 2}
    menu.kit = nil
    menu.open_kit(0)
    menu.sel.hangar = first_slot()
    for _ = 1, 6 do menu.step({right = true}) end
    check("and never past what the account owns", menu.kit[1] == 2,
          tostring(menu.kit[1]))
    account.entitlements = {}

    -- The whole page, walked with nothing but down. Every stop the cursor
    -- makes has to be a row the arrows can do something to, and between them
    -- they have to cover every such row exactly once before wrapping: a slot
    -- the cursor cannot reach is a slot a player with no mouse cannot spend.
    for i = 1, 23 do CEIL[i] = 2 end
    CEIL[20], CEIL[21], CEIL[22] = 3, 3, 3
    _G.sim.KIT_BUDGET = 30
    menu.kit = nil
    menu.open_kit(0)
    local page = menu.view().rows
    local want = 0
    for _, r in ipairs(page) do if r.pick then want = want + 1 end end
    check("the page has slots to walk", want > 20, tostring(want) .. " rows")
    menu.sel.hangar = 1
    local seen, order, dead = {}, {}, 0
    for _ = 1, want do
        local at = menu.sel.hangar
        local r = page[at]
        if not (r and r.pick) then dead = dead + 1 end
        if seen[at] then dead = dead + 100 end
        seen[at] = true
        order[#order + 1] = at
        menu.step({down = true})
    end
    check("down stops only on rows the arrows can work", dead == 0,
          dead .. " stops on a readout or a repeat")
    check("and covers the page before it wraps", #order == want
          and menu.sel.hangar == order[1],
          #order .. " of " .. want .. ", back at "
              .. tostring(menu.sel.hangar))

    -- Turning the carousel loads that hull's own saved kit rather than
    -- carrying this one onto it. The page re-reads only where the class it
    -- holds disagrees with the class it is asked about, so setting the class
    -- and nothing else left an Apex build under a Wedge drawing, and the next
    -- point spent would have saved it there.
    menu.kit = nil
    menu.open_kit(0)
    menu.kit[1] = 3
    local wedge = {}
    for i = 1, 25 do wedge[i] = 0 end
    wedge[1] = 1
    account.kits = {Wedge = wedge}
    menu.click_carousel(1)
    check("turning the carousel loads that hull's own kit",
          menu.kit_class == 1 and menu.kit[1] == 1,
          "class " .. tostring(menu.kit_class) .. ", first stat "
              .. tostring(menu.kit[1]))
    account.kits = {}

    -- A hull with nothing saved against it opens on what the arena would have
    -- dealt, which the core works out and nobody here second-guesses. It
    -- opened on an empty kit once, and an empty kit is a ship that does not
    -- exist: every seat is dealt something the moment it is filled.
    local asked = nil
    _G.sim.starter_kit = function(ceiling)
        asked = ceiling
        local out = {}
        for i = 1, 25 do out[i] = ceiling[i] or 0 end
        return out
    end
    account.entitlements = {[1] = 1}
    menu.kit = nil
    menu.open_kit(0)
    check("a hull with nothing saved opens on the core's starter kit",
          menu.kit_spent() > 0, tostring(menu.kit_spent()))
    check("and the core is asked against both ceilings at once",
          asked ~= nil and asked[1] == 1 and asked[22] == 3,
          asked and (tostring(asked[1]) .. "/" .. tostring(asked[22])) or "unasked")
    account.entitlements = {}

    -- A kit that is saved is the kit, even where it spends nothing on a slot
    -- the starter kit would have.
    account.kits = {Apex = {[1] = 2}}
    menu.kit = nil
    menu.open_kit(0)
    check("and a saved kit is left alone", menu.kit[1] == 2 and menu.kit[6] == 0,
          tostring(menu.kit[1]) .. "/" .. tostring(menu.kit[6]))

    -- The three starter profiles and any named builds are a list that drops
    -- out of the box at the head of the page. Nothing of them is on the page
    -- while it is shut. Pressing a row replaces the editor whole and puts the
    -- list away; changing a point makes it custom, and saving that custom
    -- build raises a named field with the name it was edited from in it.
    CEIL[1], CEIL[6] = 4, 2
    local first_profile, second_profile = {}, {}
    for i = 1, 23 do
        first_profile[i], second_profile[i] = 0, 0
    end
    first_profile[1] = 2
    second_profile[1], second_profile[6] = 4, 2
    account.profiles = {
        {name = "Gunner", builtin = true, kit = first_profile},
        {name = "Bomber", builtin = true, kit = second_profile},
    }
    menu.kit = nil
    menu.open_kit(0)
    check("a saved hull build recognizes its matching profile",
          menu.profile_at == 1, tostring(menu.profile_at))
    local function library()
        local add_row, rows_at, keys = nil, {}, {}
        for i, row in ipairs(menu.view().rows) do
            if row.act == "save_profile" then add_row = i end
            if row.act == "profile" then rows_at[#rows_at + 1] = i end
            if row.act == "rename_profile" then keys.rename = i end
            if row.act == "delete_profile" then keys.delete = i end
        end
        return add_row, rows_at, keys
    end
    local add_row, listed, keys = library()
    check("every build is a row, with the key that adds one under them",
          add_row == 3 and #listed == 2 and listed[1] == 1 and listed[2] == 2,
          tostring(add_row) .. "/" .. #listed)
    check("and the one the kit matches carries the mark",
          menu.view().rows[listed[1]].choice == 1
          and menu.view().rows[listed[2]].choice == 0,
          tostring(menu.view().rows[listed[2]].choice))
    check("a starter offers both keys, dim",
          keys.rename ~= nil and keys.delete ~= nil
          and menu.view().rows[keys.rename].dim == true
          and menu.view().rows[keys.delete].dim == true,
          tostring(keys.rename) .. "/" .. tostring(keys.delete))
    menu.sel.hangar = keys.rename
    menu.note = nil
    check("and pressing one explains instead of opening a card",
          menu.step({go = true}) == nil and menu.ask == nil
          and menu.note ~= nil
          and string.find(menu.note, "starter", 1, true) ~= nil,
          tostring(menu.note))
    menu.note = nil
    menu.sel.hangar = listed[2]
    local selected_profile = menu.step({go = true})
    check("pressing a row loads that whole build",
          selected_profile == "kit" and menu.profile_at == 2
          and menu.kit[1] == 4 and menu.kit[6] == 2,
          tostring(selected_profile) .. "/" .. tostring(menu.profile_at))
    check("and the head of the pane names it",
          menu.profile_band().name == "Bomber"
          and menu.profile_band().state == nil,
          menu.profile_band().name .. "/"
              .. tostring(menu.profile_band().state))

    -- The list is a selector: an arrow landing on a build loads it, so the
    -- pane beside the list is always about the row the cursor is on. Enter
    -- commits the same load, for a pointer.
    menu.sel.hangar = listed[1]
    local walked = menu.step({up = true, down = false})
    check("up onto a build is back off the page",
          walked == nil and menu.at() ~= "hangar",
          table.concat(menu.stack, "/"))
    menu.stack = {"root", "hangar"}
    menu.sel.hangar = listed[1]
    walked = menu.step({down = true})
    check("down onto a build loads it",
          walked == "kit" and menu.profile_at == 2
          and menu.kit[1] == 4 and menu.kit[6] == 2,
          tostring(walked) .. "/" .. tostring(menu.profile_at))
    walked = menu.step({up = true})
    check("and up onto the one above loads that one",
          walked == "kit" and menu.profile_at == 1
          and menu.kit[1] == 2 and menu.kit[6] == 0,
          tostring(walked) .. "/" .. tostring(menu.profile_at))

    -- Entering the page lands the cursor on the build the kit in hand is,
    -- so the washed row and the name in the head agree from the first
    -- frame. It opened on row one, which washed the first starter while the
    -- head named whichever build the kit actually was.
    menu.sel.hangar = add_row
    menu.stack = {"root"}
    menu.sel.root = ship_at
    menu.step({go = true})
    check("entering the hangar lands on the matching build",
          menu.at() == "hangar" and menu.sel.hangar == 1,
          table.concat(menu.stack, "/") .. " row "
              .. tostring(menu.sel.hangar))

    -- Back onto the second build for the edits below.
    menu.sel.hangar = listed[2]
    menu.step({go = true})
    menu.kit_step(0, -1)
    check("editing a profile turns it into a custom build",
          menu.profile_at == nil, tostring(menu.profile_at))
    check("and the head still says which build it came from",
          menu.profile_band().name == "Bomber"
          and menu.profile_band().state == "edited",
          menu.profile_band().name .. "/"
              .. tostring(menu.profile_band().state))
    menu.sel.hangar = add_row
    menu.step({go = true})
    check("a custom build can be named",
          menu.ask ~= nil and menu.ask.fields[1].label == "profile name",
          menu.ask and menu.ask.head or "no card")
    -- Nothing offered, because this build was edited from a starter and the
    -- meta-layer keeps those three names for itself.
    check("and a starter's name is not offered back",
          menu.ask.fields[1].value == "", menu.ask.fields[1].value)
    menu.ask.fields[1].value = "Screen"
    local save_action = menu.click_answer(1)
    check("saving hands the named profile to the arena",
          save_action == "save_profile" and menu.pending_profile == "Screen",
          tostring(save_action) .. "/" .. tostring(menu.pending_profile))

    -- Saving over one of your own is the same two presses as naming a new
    -- one: the card opens with the name the build already answers to.
    account.profiles[3] = {name = "Screen", builtin = false,
                           kit = second_profile}
    menu.profile_from, menu.profile_at = 3, nil
    menu.ask = nil
    menu.sel.hangar = (library())
    menu.step({go = true})
    check("a build tuned from one of yours offers its name back",
          menu.ask ~= nil and menu.ask.fields[1].value == "Screen",
          menu.ask and menu.ask.fields[1].value or "no card")
    menu.ask = nil

    -- A build of the pilot's own can be renamed and dropped, and both are the
    -- pane's own keys rather than rows in the list: they are about the one
    -- build the pane is showing.
    local _, _, own_keys = library()
    check("one of yours offers both",
          own_keys.rename ~= nil and own_keys.delete ~= nil,
          tostring(own_keys.rename) .. "/" .. tostring(own_keys.delete))
    menu.sel.hangar = own_keys.rename
    menu.step({go = true})
    check("rename opens a card carrying the name it would change",
          menu.ask ~= nil and menu.ask.fields[1].value == "Screen"
          and menu.pending_profile == "Screen",
          menu.ask and menu.ask.fields[1].value or "no card")
    menu.ask.fields[1].value = "Bomb run"
    local renamed = menu.click_answer(1)
    check("and answering it hands both names to the arena",
          renamed == "rename_profile" and menu.pending_profile == "Screen"
          and menu.pending_rename == "Bomb run",
          tostring(renamed) .. "/" .. tostring(menu.pending_rename))
    menu.ask = nil
    menu.sel.hangar = own_keys.delete
    menu.step({go = true})
    check("delete asks first, and the answer that changes nothing is the one lit",
          menu.ask ~= nil and menu.ask.sel == 2
          and menu.ask.keys[2].act == nil,
          menu.ask and menu.ask.head or "no card")
    local dropped = menu.click_answer(1)
    check("and answering it names the build to drop",
          dropped == "delete_profile" and menu.pending_profile == "Screen",
          tostring(dropped) .. "/" .. tostring(menu.pending_profile))
    menu.ask = nil
    menu.profile_from = nil
    account.profiles = {}

    -- Nothing on this page is for sale. The prices rode these rows for a
    -- while and buying is the upgrades tab again: a panel with a wallet and a
    -- budget on it has the word "spend" meaning two things at once.
    account.entitlements = {[1] = 1}
    account.rivets = 500
    account.catalog = {{slot = 0, label = "energy depth", price = 40,
                        owned = 1, ceiling = 2, base = 0,
                        note = "a 7th step, on this stat alone"}}
    menu.kit = nil
    menu.open_kit(0)
    local priced = nil
    for _, r in ipairs(menu.view().rows) do
        if r.label == "energy" then priced = r end
    end
    check("the ship page carries no price",
          priced ~= nil and priced.price == nil,
          priced and tostring(priced.price) or "no energy row")

    -- And a press that cannot spend says which of the two refusals it is,
    -- rather than offering to sell the way out of one of them.
    menu.sel.hangar = first_slot()
    menu.ask = nil
    for _ = 1, 4 do menu.step({right = true}) end
    check("the ladder stops at what the account owns", menu.kit[1] == 1,
          tostring(menu.kit[1]))
    check("and an arrow at the top of it raises no card", menu.ask == nil,
          menu.ask and menu.ask.head or "quiet")
    menu.step({go = true})
    check("and the next press points at the page that sells it",
          menu.ask == nil and menu.note ~= nil
          and string.find(menu.note, "upgrades", 1, true) ~= nil,
          tostring(menu.note))

    -- A rung nobody owns, pressed directly. Same answer: the pip has been
    -- advertising something this page does not sell.
    menu.ask = nil
    menu.click_kit_at(1, 2)
    check("a rung nobody owns says where it is sold",
          menu.ask == nil and menu.note ~= nil
          and string.find(menu.note, "upgrades", 1, true) ~= nil,
          tostring(menu.note))
    menu.click_kit_at(1, 1)
    check("and a rung you own is still just a rung",
          menu.ask == nil and menu.kit[1] == 1,
          tostring(menu.kit[1]))

    -- --- the page that does sell it
    --
    -- Every slot the game has, owned marked, with the price of the next rung
    -- on the ones that have one. It listed only what was left to buy once,
    -- which is a page that shrinks as a pilot gets stronger and loses the
    -- whole ladder on the last purchase in it.
    account.rivets = 500
    account.catalog = {
        {slot = 0, label = "energy depth", owned = 1, ceiling = 2, base = 0,
         price = 40, note = "a 7th step, on this stat alone"},
        {slot = 1, label = "recharge depth", owned = 2, ceiling = 2, base = 0},
    }
    menu.stack = {"root", "upgrades"}
    menu.sel = {}
    local shop = menu.view()
    check("the catalog is drawn as its own page", shop.shop == true,
          tostring(shop.shop))
    check("and lists what is owned as well as what is for sale",
          #shop.rows == 2, tostring(#shop.rows))
    check("a slot with a rung left carries its price",
          shop.rows[1].price == 40 and shop.rows[1].afford == true
          and shop.rows[1].owned == 1 and shop.rows[1].arena_max == 2,
          tostring(shop.rows[1].price))
    check("and one taken to the top of its ladder carries none",
          shop.rows[2].price == nil and shop.rows[2].owned == 2,
          tostring(shop.rows[2].price))

    menu.sel.upgrades = 1
    menu.ask = nil
    menu.step({go = true})
    check("pressing a priced row asks before it spends",
          menu.ask ~= nil and string.find(menu.ask.head, "40", 1, true),
          menu.ask and menu.ask.head or "no card")
    check("with the answer that changes nothing under the cursor",
          menu.ask.keys[menu.ask.sel].act == nil,
          tostring(menu.ask.sel))
    menu.pending = nil
    local bought = menu.click_answer(1)
    check("and answering it buys that slot",
          bought == "buy" and menu.pending == 0,
          tostring(bought) .. "/" .. tostring(menu.pending))

    -- And the two hands do different things here, which is the one page
    -- where they should. A press of the key acts on the cursor, and the
    -- thing it acts on is the button beside the pane. A pointer landing on a
    -- row is reading: it moves the cursor there and spends nothing, because
    -- what the pane fills up with is the answer to why you clicked.
    menu.sel.upgrades = 2
    menu.ask = nil
    account.rivets = 500
    local act = menu.click(1)
    check("a pointer on a row moves the cursor to it",
          menu.sel.upgrades == 1, tostring(menu.sel.upgrades))
    check("and spends nothing",
          menu.ask == nil and act == nil,
          menu.ask and menu.ask.head or tostring(act))

    -- The button does. It names its own row rather than reading the cursor,
    -- since the pane it sits under follows the pointer.
    menu.sel.upgrades = 2
    menu.ask = nil
    menu.click_buy(1)
    check("the buy button asks about the row it was drawn for",
          menu.ask ~= nil and string.find(menu.ask.head, "40", 1, true),
          menu.ask and menu.ask.head or "no card")
    check("and takes the cursor there, so the pane agrees with the card",
          menu.sel.upgrades == 1, tostring(menu.sel.upgrades))
    menu.ask = nil
    check("a row with nothing to sell has no buy in it",
          select(2, menu.click_buy(2)) == false, "bought a topped-out slot")

    -- A row with nothing left to sell is not a control.
    menu.sel.upgrades = 2
    menu.ask = nil
    menu.step({go = true})
    check("a slot you have taken to the top presses nothing",
          menu.ask == nil, menu.ask and menu.ask.head or "quiet")

    -- A wallet too light is told so instead of being asked a question whose
    -- only answer is a refusal.
    menu.sel.upgrades = 1
    account.rivets = 10
    menu.ask = nil
    menu.step({go = true})
    check("a short wallet is told the price rather than asked to pay it",
          menu.ask ~= nil and #menu.ask.keys == 1
          and string.find(menu.ask.note or "", "10", 1, true),
          menu.ask and (menu.ask.head .. "/" .. tostring(menu.ask.note))
              or "no card")
    menu.ask = nil
    account.shelf = nil
    account.rivets = 0
    account.entitlements = {}

    -- A build can outgrow its owner: add-ons stopped being granted, so every
    -- kit saved with one in it holds a slot the account no longer owns. The
    -- room trims such a kit on the way in, and the page has to show the same
    -- thing or it is promising a ship nobody will fly.
    account.kits = {Apex = {[1] = 2, [12] = 1}}
    account.entitlements = {[1] = 6, [12] = 0}
    menu.kit = nil
    menu.note = nil
    menu.open_kit(0)
    check("a slot the account no longer owns comes off the build",
          menu.kit[12] == 0 and menu.kit[1] == 2,
          tostring(menu.kit[1]) .. "/" .. tostring(menu.kit[12]))
    check("and the page says why rather than quietly shrinking",
          menu.note ~= nil and string.find(menu.note, "not yours yet", 1, true),
          tostring(menu.note))
    account.entitlements = {}
    account.kits = {}

    -- --- what is on the page is what you can fly
    --
    -- A slot the arena has and the account does not own used to be drawn here
    -- anyway, backed off, so the page could say "this exists and is not
    -- yours". The upgrades tab says that now, with the price attached, and
    -- here it left unreachable rows and chips too dim to read taking the room
    -- a legible one would have.
    -- An arena with one stat, the gun's ladder, two of the gun's add-ons and
    -- one charge. The walk test above filled every slot; this is a shape small
    -- enough to name every row it should produce.
    for i = 1, 23 do CEIL[i] = 0 end
    CEIL[1] = 4          -- the first stat
    CEIL[6] = 2          -- the gun's ladder
    CEIL[8] = 3          -- gun spray, three rounds' worth
    CEIL[9] = 2          -- gun bounce, two rungs
    CEIL[12] = 1         -- gun freeze, one
    CEIL[20] = 3         -- the first charge
    -- Back on the ship page, which the upgrades block above left.
    account.catalog = nil
    account.entitlements = {}
    menu.stack = {"root", "hangar"}
    menu.sel = {}
    menu.kit = nil
    menu.open_kit(0)
    local owned = {}
    for _, r in ipairs(menu.view().rows) do owned[#owned + 1] = r.label end
    -- Nine: the six slots this zone allows, the hull and the wake, and the
    -- key that adds a build. This account has kept none, so the column down
    -- the left is that key alone.
    check("every slot the arena takes is on the page while the account owns it",
          #owned == 9, table.concat(owned, ", "))

    -- Now the account owns none of the gun's ladder and one of three repels.
    account.entitlements = {[6] = 0, [20] = 1}
    menu.kit = nil
    menu.open_kit(0)
    local mine, charge = {}, nil
    for _, r in ipairs(menu.view().rows) do
        mine[#mine + 1] = r.label
        if r.label == "repel" then charge = r end
    end
    check("a slot the account owns none of is off the page altogether",
          #mine == 8 and not string.find(table.concat(mine, ","),
                                         "gun level", 1, true),
          table.concat(mine, ", "))
    check("and a ladder stops at what the account owns, not at the arena's",
          charge ~= nil and charge.owned == 1 and charge.choices == 1,
          charge and (tostring(charge.owned) .. "/" .. tostring(charge.choices))
              or "no repel row")

    -- --- an add-on is a switch, and the arrows walk them
    --
    -- The chips are drawn as a row of boxes across the page, so left and right
    -- go to the chip beside this one. They set the value before, which is a
    -- ladder's control: the arrow pointing at the next chip turned the one it
    -- was on off, and walking the group meant pressing up and down through a
    -- row that reads left to right.
    account.entitlements = {}
    -- A build with a point already on it, so `open_kit` does not fall back to
    -- the starter kit and hand this test a chip that is already switched on.
    account.kits = {Apex = {[1] = 1}}
    menu.kit = nil
    menu.open_kit(0)
    menu.sel = {}
    local spray, bounce, freeze = nil, nil, nil
    for i, r in ipairs(menu.view().rows) do
        if r.label == "gun spray" then spray = i end
        if r.label == "gun bounce" then bounce = i end
        if r.label == "gun freeze" then freeze = i end
    end
    check("the add-ons are on the page as chips",
          bounce ~= nil and freeze == bounce + 1,
          tostring(bounce) .. "/" .. tostring(freeze))
    menu.sel.hangar = bounce
    menu.step({right = true})
    check("right goes to the chip beside it", menu.sel.hangar == freeze,
          "cursor " .. tostring(menu.sel.hangar))
    check("and nothing was switched on the way", (menu.kit[9] or 0) == 0,
          tostring(menu.kit[9]))
    menu.step({left = true})
    check("and left comes back", menu.sel.hangar == bounce,
          "cursor " .. tostring(menu.sel.hangar))

    -- Enter throws it, and the trigger is enter here: a switch wants one
    -- press, and at the top the next press takes it off again.
    menu.step({go = true})
    check("enter switches the chip on", (menu.kit[9] or 0) == 1,
          tostring(menu.kit[9]))
    menu.step({go = true})
    check("and enter walks it up the rungs it has", (menu.kit[9] or 0) == 2,
          tostring(menu.kit[9]))
    menu.step({go = true})
    check("and off again at the top", (menu.kit[9] or 0) == 0,
          tostring(menu.kit[9]))

    -- Spray is the exception in that group, because it is a count of rounds
    -- rather than a switch with rungs behind it: it takes the arrows the way
    -- a stat does. It used to be a chip beside a second chip called "double
    -- barrel", and both of them meant more bullets.
    check("spray is on the page", spray ~= nil, tostring(spray))
    menu.sel.hangar = spray
    menu.step({right = true})
    check("spray takes a step from the arrows", (menu.kit[8] or 0) == 1,
          tostring(menu.kit[8]))
    menu.step({right = true})
    check("and another", (menu.kit[8] or 0) == 2, tostring(menu.kit[8]))
    check("without the cursor leaving it", menu.sel.hangar == spray,
          "cursor " .. tostring(menu.sel.hangar))
    menu.step({left = true})
    menu.step({left = true})
    check("and gives them back", (menu.kit[8] or 0) == 0,
          tostring(menu.kit[8]))

    -- A stat is still a ladder, because that is what it is: left and right
    -- spend and unspend along it.
    menu.sel.hangar = first_slot()
    menu.step({right = true})
    check("but a stat still takes a step from the arrows",
          (menu.kit[1] or 0) == 2, tostring(menu.kit[1]))
    menu.step({left = true})
    check("and gives it back", (menu.kit[1] or 0) == 1, tostring(menu.kit[1]))

    account.entitlements = {}
    account.kits = {}
    menu.kit = nil
    _G.sim = nil
end

-- --- the week's table is read four ways ------------------------------------
--
-- One reply, and a page that orders it, narrows it, and asks for another week.
-- All four belong to the page: the fleet sends a week and has no opinion about
-- how somebody wants to look at it.
do
    account.week = {
        {name = "Sable", kills = 14, deaths = 6, banked = 210, run = 42,
         rating = 1310, swing = 38, seconds = 720},
        {name = "Ozone", kills = 9, deaths = 9, banked = 130, run = 12,
         rating = 1204, swing = -4, seconds = 900},
        {name = "Kestrel", kills = 2, deaths = 11, banked = 30, run = 4,
         rating = 1118, swing = -22, seconds = 640},
    }
    account.week_since = "Aug 17"
    account.asked_week = 0
    menu.home = true
    menu.stack = {"root", "standings"}
    menu.sel = {}
    menu.sort, menu.sort_up, menu.filter, menu.week_back = "kills", false, "", 0

    local function names()
        local out = {}
        for _, r in ipairs(menu.view().rows) do out[#out + 1] = r.label end
        return table.concat(out, "/")
    end
    check("the table opens ordered by kills", names() == "Sable/Ozone/Kestrel",
          names())
    check("and carries what a week came to",
          menu.view().rows[1].banked == 210 and menu.view().rows[1].run == 42,
          tostring(menu.view().rows[1].banked))
    -- Two rating numbers, and they are not the same fact: what a pilot is
    -- rated at, and what this week did to it.
    check("with a rating and the week's swing kept apart",
          menu.view().rows[1].rating == 1310
          and menu.view().rows[1].swing == 38,
          tostring(menu.view().rows[1].rating))
    -- The ratio the old card worked out, worked out here instead, where the
    -- table can order on it.
    check("and a ratio the column can sort by",
          math.abs(menu.view().rows[1].kd - 14 / 6) < 1e-9,
          tostring(menu.view().rows[1].kd))

    menu.click_sort("kd")
    check("the ratio orders the table",
          names() == "Sable/Ozone/Kestrel", names())
    menu.click_sort("rating")
    check("and so does the rating itself",
          names() == "Sable/Ozone/Kestrel", names())
    menu.sort, menu.sort_up = "kills", false

    menu.click_sort("deaths")
    check("a column head orders by it", names() == "Kestrel/Ozone/Sable",
          names())
    menu.click_sort("deaths")
    check("and the same one again turns it over",
          names() == "Sable/Ozone/Kestrel", names())
    menu.click_sort("pilot")
    check("a name column sorts as names", names() == "Kestrel/Ozone/Sable",
          names())
    menu.sort, menu.sort_up = "kills", false

    -- Typing narrows it, and a rank stays the rank it had in the week: a
    -- pilot who is third does not become first because two rows were hidden.
    for ch in string.gmatch("kes", ".") do menu.type_filter(ch) end
    check("typing narrows the table", names() == "Kestrel", names())
    check("and a rank is a place in the week, not in the filter",
          menu.view().rows[1].rank == 3, tostring(menu.view().rows[1].rank))
    menu.rub_filter()
    menu.rub_filter()
    menu.rub_filter()
    check("and backspace widens it again", names() == "Sable/Ozone/Kestrel",
          names())

    for ch in string.gmatch("zzz", ".") do menu.type_filter(ch) end
    local card = menu.view().empty
    check("a filter matching nobody is not an empty week",
          card ~= nil and string.find(card.head, "name", 1, true),
          card and card.head or "no card")
    menu.filter = ""

    -- And the week itself steps back, which is a fresh request rather than a
    -- different reading of the one in hand.
    menu.step_week(1)
    check("a week back is asked for", menu.week_back == 1
          and account.asked_week == 1, tostring(account.asked_week))
    check("and there is no forward from the week that is running",
          select(2, menu.step_week(-1)) == true and menu.week_back == 0
          and select(2, menu.step_week(-1)) == false,
          tostring(menu.week_back))
    -- The box the letters land in. Typing lights it without a click, a press
    -- lights it on its own, and a press anywhere else lets it go.
    menu.filter_on = false
    menu.type_filter("k")
    check("typing lights the box", menu.filter_on == true,
          tostring(menu.filter_on))
    menu.wipe_filter()
    check("and the mark on its end empties it", menu.filter == "",
          "'" .. tostring(menu.filter) .. "'")
    menu.filter_on = false
    menu.click_filter()
    check("pressing it puts a caret in it", menu.filter_on == true,
          tostring(menu.filter_on))
    check("and letting go says so once",
          menu.blur_filter() == true and menu.blur_filter() == false,
          tostring(menu.filter_on))

    -- On glass there are no keys, so the press raises the card instead: a
    -- card's line is a real input element on the web, which is the only thing
    -- that raises a phone's keyboard.
    menu.touching = true
    menu.ask = nil
    menu.click_filter()
    check("a thumb gets a card it can type into",
          menu.ask ~= nil and menu.ask.fields ~= nil,
          menu.ask and menu.ask.head or "no card")
    if menu.ask then menu.ask.fields[1].value = "ozo" end
    menu.click_answer(1)
    check("and what it answers is the filter",
          menu.filter == "ozo" and names() == "Ozone",
          "'" .. tostring(menu.filter) .. "' " .. names())
    menu.touching = false
    menu.filter = ""

    account.week = nil
    account.week_since = ""
end

-- --- a tab with nothing under it yet does not take the cursor --------------
--
-- The catalog and the games list arrive over the wire. Until they do, those
-- pages are one line saying so, and stepping into one put the cursor on a
-- list of none: down did nothing visible, the tab row no longer had the
-- arrows, and the way back was a key nobody had a reason to press. The stage
-- previews the page from the tab above it either way, so the same words are
-- on screen; what changes is whether the press moves anything.
--
-- The friends page is the exception the rule has to carry: with nobody on it
-- the whole page is the box you type a call sign into, which is exactly the
-- page a new player opens.

do
    menu.home = true
    menu.stack = {"root"}
    menu.sel = {}
    menu.corner_sel = nil
    menu.filter_on = false
    menu.add_on = false

    local kept_rows = account.rows
    local kept_here, kept_friends = account.here, account.friends

    -- Upgrades, with the catalog still on its way.
    local kept_catalog = account.catalog
    account.catalog = nil
    local up_at = top_index("upgrades")
    menu.sel.root = up_at
    local _, moved = menu.step({down = true})
    check("down on a tab still asking for its page stays on the tab",
          menu.at() == "root", table.concat(menu.stack, "/"))
    check("and says nothing moved, so the menu makes no noise",
          moved == false, tostring(moved))
    check("the cursor is still on that tab", menu.sel.root == up_at,
          tostring(menu.sel.root))
    check("and the stage is still previewing what it is waiting for",
          menu.view().empty ~= nil,
          menu.view().empty and menu.view().empty.head or "nothing")

    -- A pointer gets the same answer, or the two hands disagree about what
    -- the same tab does.
    menu.click_rail(up_at)
    check("and a tap on it does not go in either", menu.at() == "root",
          table.concat(menu.stack, "/"))

    -- And the moment it lands, the same press works, which is the half of
    -- this that says the guard is about the page and not about the tab.
    account.catalog = {{slot = 0, level = 1, price = 40, label = "speed"}}
    menu.stack = {"root"}
    menu.sel.root = up_at
    menu.step({down = true})
    check("once the catalog is there the same press goes in",
          menu.at() == "upgrades", table.concat(menu.stack, "/"))
    account.catalog = kept_catalog

    -- Friends with nobody on it is still somewhere to be.
    menu.stack = {"root"}
    menu.sel = {}
    account.here, account.friends = {}, {}
    local fr_at = top_index("friends")
    menu.sel.root = fr_at
    menu.step({down = true})
    check("an empty friends page opens, because the field is the page",
          menu.at() == "friends", table.concat(menu.stack, "/"))
    check("with the cursor in the box", menu.add_on == true,
          tostring(menu.add_on))

    menu.add_on = false
    account.rows = kept_rows
    account.here, account.friends = kept_here, kept_friends
    menu.stack = {"root"}
    menu.sel = {}
end

-- --- and across the week's table is time -----------------------------------
--
-- Down the page is the ladder; there is nothing to the side of a pilot's row.
-- So left and right are the pair of arrows already drawn over the table, and
-- the week is walked from wherever the cursor is standing rather than only by
-- pointing at them.

do
    menu.home = true
    menu.stack = {"root", "standings"}
    menu.sel = {}
    menu.filter = ""
    menu.filter_on = false
    menu.week_back = 0
    account.week = {
        {name = "Ozone", kills = 9, deaths = 2, seconds = 600},
        {name = "Quarry", kills = 4, deaths = 5, seconds = 300},
    }
    account.week_since = "Aug 17"

    local asked = nil
    local kept_refresh = account.refresh_week
    account.refresh_week = function(back) asked = back end

    local _, moved = menu.step({left = true})
    check("left on a row goes back a week", menu.week_back == 1,
          tostring(menu.week_back))
    check("and says so, so the menu ticks", moved == true, tostring(moved))
    check("and the table is asked for that week", asked == 1, tostring(asked))
    check("and the cursor has not left the table", menu.at() == "standings",
          table.concat(menu.stack, "/"))

    menu.step({right = true})
    check("right comes forward again", menu.week_back == 0,
          tostring(menu.week_back))

    asked = nil
    local _, again = menu.step({right = true})
    check("and there is no forward from the week that is running",
          menu.week_back == 0 and again == false,
          menu.week_back .. " " .. tostring(again))
    check("so nothing is asked for", asked == nil, tostring(asked))

    -- The way back up is up, which is what took over from left: out of the
    -- first row into the box, and out of the box to the tabs.
    menu.sel.standings = 1
    menu.step({up = true})
    check("up out of the first row lights the filter box",
          menu.filter_on == true, tostring(menu.filter_on))
    menu.step({up = true})
    check("and up out of the box is the way back to the tabs",
          menu.at() == "root", table.concat(menu.stack, "/"))

    -- In the box, left is still the way out of the box rather than a week.
    menu.stack = {"root", "standings"}
    menu.filter_on = true
    menu.week_back = 0
    menu.step({left = true})
    check("left in the box leaves the box rather than the week",
          menu.filter_on == false and menu.week_back == 0,
          tostring(menu.filter_on) .. " " .. tostring(menu.week_back))

    account.refresh_week = kept_refresh
    account.week = nil
    account.week_since = ""
    menu.week_back = 0
    menu.filter_on = false
    menu.stack = {"root"}
    menu.sel = {}
end

-- --- the menu is a panel over the stands ----------------------------------
--
-- The front end is a room now: opening the client seats you in the stands of
-- one, so a menu opened there has a game behind it and closes like any other.
-- What is left unclosable is a client that has reached no room at all, where
-- escape really would land on an empty starfield with no way back.
do
    local kept = {home = menu.home, scenery = menu.scenery,
                 watching = menu.watching, open = menu.open,
                 stack = menu.stack, sel = menu.sel}

    menu.home, menu.scenery = true, true
    menu.open, menu.stack, menu.sel = true, {"root"}, {}
    check("a menu over the stands closes", menu.close() == true)
    check("and says so to the drawing", (function()
        menu.open, menu.stack, menu.sel = true, {"root"}, {}
        return menu.view().closable == true
    end)())

    -- Including with no room reached at all, which is the case the old rule
    -- existed for. What is behind the panel then is the waiting screen, and
    -- that carries MENU, so closing onto it strands nobody.
    menu.home, menu.scenery = true, false
    menu.open, menu.stack, menu.sel = true, {"root"}, {}
    check("a menu with no room behind it closes too",
          menu.close() == true and menu.open == false)
    check("and says so as well", (function()
        menu.open, menu.stack, menu.sel = true, {"root"}, {}
        return menu.view().closable == true
    end)())

    -- The tab set follows the cockpit, not the zone. Six stops with no hull,
    -- wherever you are standing; the short row only once you are flying one.
    local function labels()
        local out = {}
        for _, r in ipairs(menu.view().rail) do out[#out + 1] = r.label end
        return table.concat(out, " ")
    end

    menu.home, menu.scenery, menu.watching = true, true, false
    menu.open, menu.stack, menu.sel = true, {"root"}, {}
    check("the stands carry the whole row",
          labels() == "play ship upgrades friends standings settings",
          labels())

    menu.home, menu.watching = false, false
    check("a pilot in a hull gets the short one",
          labels():find("play") == nil and labels():find("leave") ~= nil,
          labels())

    -- A pilot the room benched is in the stands too: same empty cockpit, same
    -- time to read, so the same six stops. What they keep that the landing
    -- does not is `leave`, because they are in a zone there is something to
    -- leave.
    menu.home, menu.watching = false, true
    check("a benched pilot gets the whole row back",
          labels() == "play ship upgrades friends standings settings leave",
          labels())

    menu.home, menu.scenery, menu.watching = kept.home, kept.scenery,
                                             kept.watching
    menu.open, menu.stack, menu.sel = kept.open, kept.stack, kept.sel
end

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
