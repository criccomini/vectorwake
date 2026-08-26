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
function account.refresh_friends()
    account.asked_friends = account.asked_friends + 1
end
function account.refresh_career()
    account.asked_career = (account.asked_career or 0) + 1
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
    -- What a game is called, by its key. The list is where the labels arrive,
    -- so it is what everything else asks.
    label_of = function(zone) return zone end,
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
local pilot_at = top_index("pilot")
local tabs = {}
for _, r in ipairs(menu.view().rail) do tabs[#tabs + 1] = r.label end
check("the tab row is play, ship, friends, settings, pilot",
      table.concat(tabs, "/") == "play/ship/friends/settings/pilot",
      table.concat(tabs, "/"))
check("the rail carries the destinations", ship_at and settings_at and pilot_at,
      "ship " .. tostring(ship_at) .. ", settings " .. tostring(settings_at)
      .. ", pilot " .. tostring(pilot_at))

-- The pilot stop is the account page: the same page the corner call sign
-- opens, one press from the rail. Two doors onto one page, on purpose.
menu.click_rail(pilot_at)
check("a rail tap on pilot opens the account page", menu.stack[2] == "pilot",
      table.concat(menu.stack, "/"))
menu.stack = {"root"}
menu.sel = {}

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
    -- check above about right rather than about an empty list. A press on a
    -- game is one act with one name: be in this zone. The arena dials it and
    -- goes on dialing while a network or an arena is down.
    check("and enter on the same row still does",
          menu.step({go = true}) == "want_zone", "nothing asked for")
    check("and the press remembers which game it is waiting on",
          menu.await == "chaos", tostring(menu.await))
    -- A thumb is the same act. There is no key at the foot of the column any
    -- more, so the row is the only way into a game, and a tap has to land
    -- where enter lands rather than only moving the cursor onto it.
    menu.stack, menu.sel = {"root", "play"}, {play = 1}
    local tapped, took = menu.click_stage(1)
    check("and a tap on a game asks for it too",
          tapped == "want_zone" and took,
          tostring(tapped) .. "/" .. tostring(took))
    -- And the panel stays up for it. The press is a thing the client is now
    -- trying to do, and this is where it says so until a room answers: on a
    -- fleet that is down, that is the whole of the feedback there is.
    check("and the panel stays up until a room answers", menu.open)
    menu.arrived("chaos")
    check("and goes when one does", not menu.open and menu.await == nil,
          tostring(menu.open) .. "/" .. tostring(menu.await))
    menu.open = true
    menu.stack, menu.sel = kept_stack, kept_sel
end

-- --- the game you are in, and the way out of it ---------------------------
--
-- Three states, and the games list answers a press differently in each. In a
-- hull: the row you are on carries a leave, and a press on the row itself is
-- the way back to the fight. Watching: a press on the room you are watching
-- puts the panel away, because that is the only thing between you and it.
-- Adrift: nothing is in this list that you are in, so every press waits.
do
    local kept_stack, kept_sel = menu.stack, menu.sel
    local kept_zone, kept_home = menu.zone, menu.home
    menu.open, menu.home, menu.watching = true, false, false
    menu.zone = "chaos"
    menu.stack, menu.sel = {"root", "play"}, {play = 1}

    local flying = menu.view()
    local acts = flying.rows[1] and flying.rows[1].acts
    check("the game you are flying carries a leave",
          acts ~= nil and #acts == 1 and acts[1].label == "leave",
          acts and tostring(#acts) or "none")

    -- Right is the arrow that reaches it: it is drawn at the row's right hand
    -- end, and right had nothing else to do on a list of games.
    local left, moved = menu.step({right = true})
    check("and right reaches it", left == "leave_seat" and moved,
          tostring(left) .. "/" .. tostring(moved))
    -- The panel stays: what changed is on the glass behind it, and nothing
    -- about where this client is has moved.
    check("and leaving the seat leaves the panel standing", menu.open)
    -- A pointer takes the same route to the same act.
    local clicked = menu.click_row_act(1, 1)
    check("and a press on the button is the same act",
          clicked == "leave_seat", tostring(clicked))

    -- Watching it instead: no leave, because there is no seat to hand back.
    menu.watching = true
    local benched = menu.view()
    check("a game you are only watching carries none",
          benched.rows[1] and benched.rows[1].acts == nil)

    -- The pilot stop stays home: an account is not a thing to edit from
    -- inside a room, which is the guard the corner press wears too.
    local away = {}
    for _, r in ipairs(benched.rail) do away[#away + 1] = r.label end
    check("the rail carries no pilot stop away from home",
          not table.concat(away, "/"):find("pilot"),
          table.concat(away, "/"))

    menu.zone, menu.home = kept_zone, kept_home
    menu.watching = false
    menu.stack, menu.sel = kept_stack, kept_sel
end

-- --- the button at the end of that row is on the row -----------------------
--
-- The call sign sits beside the tabs and does what a tab does: the row is the
-- x and then it, left to right, and it loops between the two.
--
-- They were stops on the end of the rail for a while, reached by pressing
-- right off the last tab. That is a row along the foot of the column wrapping
-- into a button drawn at the top of it: the cursor crossed the whole height of
-- the panel sideways, and a hand walking the tabs met two highlights nowhere
-- near the row it was walking. They are their own row now, over the page they
-- are drawn over, and up off the first row of a page is what reaches them.
--
-- What the old arrangement was protecting is kept: the rail's lit stop means
-- "where you are" and the head's cursor means "where the arrows are", so the
-- two are never the same claim made twice.
do
    local kept_name = menu.name
    menu.name = "Tester 1"
    menu.open, menu.home = true, true
    menu.stack = {"root"}
    menu.sel = {root = pilot_at}
    menu.head_sel = nil
    menu.step({right = true})
    check("the rail row is the tabs alone, and it wraps",
          menu.head_sel == nil and menu.sel.root == 1,
          tostring(menu.head_sel) .. "/" .. tostring(menu.sel.root))
    menu.step({left = true})
    check("and back the other way", menu.sel.root == pilot_at,
          tostring(menu.sel.root))

    -- Up off the first row of a page is the way onto that line, and it lands
    -- on the call sign: it is the far end of the row and the control somebody
    -- pressing up at the top of a page is reaching for.
    menu.stack = {"root", "play"}
    menu.sel = {play = 1}
    menu.head_sel = nil
    menu.step({up = true})
    check("up off the first row of a page lands on the call sign",
          menu.view().head_sel == "pilot",
          tostring(menu.view().head_sel))
    menu.step({left = true})
    check("left of it is the x", menu.view().head_sel == "close",
          tostring(menu.view().head_sel))
    menu.step({left = true})
    check("and left again loops back round to the call sign",
          menu.view().head_sel == "pilot",
          tostring(menu.view().head_sel))
    menu.step({right = true})
    check("right off the call sign wraps to the x the same way",
          menu.view().head_sel == "close",
          tostring(menu.view().head_sel))
    -- Nothing is over this line, so up on it does nothing rather than
    -- inventing a place to go.
    local _, moved = menu.step({up = true})
    check("and up off the head does nothing",
          moved == false and menu.view().head_sel == "close",
          tostring(moved) .. "/" .. tostring(menu.view().head_sel))
    -- The page keeps its cursor off the panel while the head has it, so the
    -- panel never lights two rows at once.
    check("the page draws unfocused while the head has the arrows",
          menu.view().focus == "head", tostring(menu.view().focus))
    menu.step({down = true})
    check("down goes back into the page, at the top of it",
          menu.head_sel == nil and menu.sel.play == 1,
          tostring(menu.head_sel) .. "/" .. tostring(menu.sel.play))

    -- Enter on the call sign opens the page a press on it opens, which is the
    -- page the pilot tab leads to. Two doors onto one page, on purpose.
    menu.stack = {"root", "play"}
    menu.sel = {play = 1}
    menu.head_sel = nil
    menu.step({up = true})
    menu.step({go = true})
    check("enter on the call sign opens the account page",
          menu.at() == "pilot", table.concat(menu.stack, "/"))
    check("and the cursor comes off the head with it",
          menu.head_sel == nil, tostring(menu.head_sel))

    -- And the x shuts the panel, which is what a cross means everywhere.
    menu.open = true
    menu.stack = {"root", "play"}
    menu.sel = {play = 1}
    menu.head_sel = nil
    menu.step({up = true})
    menu.step({left = true})
    menu.step({go = true})
    check("enter on the x shuts the panel", not menu.open,
          tostring(menu.open))
    menu.open = true

    -- Reachable is not the same as lit for the page: the rail's own stop is
    -- the one mark saying where you are.
    menu.stack = {"root", "pilot"}
    menu.head_sel = nil
    local on_pilot = menu.view()
    check("the rail lights the pilot stop while its page is up",
          on_pilot.rail_sel == pilot_at, tostring(on_pilot.rail_sel))
    check("and the call sign does not light with it",
          on_pilot.head_sel == nil, tostring(on_pilot.head_sel))

    -- A pointer still opens it, which is the whole of what the name is for
    -- besides saying who you are.
    menu.stack = {"root"}
    menu.sel = {}
    menu.click_pilot()
    check("and a press on the name still opens the page",
          menu.at() == "pilot", table.concat(menu.stack, "/"))

    -- Away from home the account is not a thing to edit, so the name is a
    -- label and the x is the whole of that row.
    menu.home = false
    menu.stack = {"root", "settings"}
    menu.sel = {settings = 1}
    menu.head_sel = nil
    menu.step({up = true})
    check("in a match the head is the x alone",
          menu.view().head_sel == "close",
          tostring(menu.view().head_sel))
    menu.step({left = true})
    check("and it has nowhere to wrap to",
          menu.view().head_sel == "close",
          tostring(menu.view().head_sel))
    menu.home = true

    -- A tap on a tab takes the cursor off the head, so the panel never looks
    -- like the arrows are in two places.
    menu.head_sel = 1
    menu.click_rail(ship_at)
    check("and a tap on a tab clears it", menu.head_sel == nil,
          tostring(menu.head_sel))
    menu.stack = {"root"}
    menu.sel = {}
    menu.head_sel = nil
    menu.name = kept_name
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

-- In a match the tab row is a shorter row: play, friends and settings, which
-- is everything a pilot can act on from a cockpit. The hangar is not on it,
-- because a hull is locked for the match and a three minute match is short
-- enough that browsing one costs a real fraction of it.
--
-- Play comes first, and it is the one stop that used not to be here at all.
-- Leaving is a button on the row of the game you are in now, so the list is
-- the route to it; a tab called "leave" beside the sound settings was the way
-- out of a game filed a page away from the game it was about.
menu.home = false
menu.open = true
menu.stack = {"root"}
menu.sel = {}
local in_match = {}
for _, r in ipairs(menu.view().rail) do in_match[#in_match + 1] = r.label end
check("a match carries three tabs",
      #in_match == 3 and in_match[1] == "play"
      and in_match[2] == "friends" and in_match[3] == "settings",
      table.concat(in_match, "/"))

local match_leave = top_index("leave")
check("and none of them is a leave", match_leave == nil,
      tostring(match_leave))

local match_settings = top_index("settings")
menu.click_rail(match_settings)
check("and settings is one of them",
      menu.stack[2] == "settings", table.concat(menu.stack, "/"))
local setting_view = menu.view()
-- And it is a page of settings, which is what the ground under it is set for.
-- It carried a "what this changes" section under the rows as well, saying the
-- selected row's own name, its value and its help line back at whoever had
-- just walked onto it: three things the row already says, in a block that
-- moved every time the cursor did.
check("and it draws as a reading",
      setting_view.settings == true and setting_view.aside == nil,
      tostring(setting_view.aside))
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
      #between == 4 and between[2] == "ship", table.concat(between, "/"))

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

-- --- the call sign in the corner is a way to the pilot page ----------------
--
-- The rail carries a pilot stop at home now, and the name at the far end of
-- the top line opens the same page: two doors, because the name says who you
-- are and the stop looks like a button. The corner press has to survive the
-- guard that shuts a page the row has stopped carrying, which it does by the
-- row actually carrying it at home.

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
check("with the pilot stop on the row beside it",
      table.concat(rail_names, "/"):find("pilot") ~= nil,
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
-- The hull rides the flair row's own range now rather than a list beside the
-- page: `choice` is the cell it is showing and `choices` is how many there
-- are, which is what the arrows either side of it turn.
local hull_cells = 0
for _, r in ipairs(ship_page.rows) do
    if r.ship then hull_cells = r.choices or 0 end
end
check("every hull rides the carousel, and sitting out with them",
      hull_cells > 1, hull_cells .. " cells")
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
-- The band is the page's own head: the build's name, which opens the
-- library, and the points, which open what they are. Both are rows so the
-- arrows reach them, and the cursor opens on the first of them.
check("with the cursor on the band the page carries instead of a head",
      ship_page.sel == 1 and ship_page.rows[1].group == "band"
      and ship_page.rows[2].group == "band",
      "cursor " .. tostring(ship_page.sel) .. " on "
      .. tostring(ship_page.rows[1].group))
-- And it keeps the head every other page has. It used to put the band on that
-- line instead and drop the call sign and the rule, so walking into this page
-- from the rail shifted the whole panel up by the height of its own head.
check("and the head over it is the one every page carries",
      ship_page.headless == nil, tostring(ship_page.headless))

-- Left and right turn the carousel while the cursor stands on the hull row.
-- At home that is the choice itself: what a hull means with no game on is
-- the ship you will arrive in, and a pilot who spins to one, likes it and
-- walks away should be flying it.
menu.sel.hangar = hull_row
menu.pending = nil
local turned = menu.step({right = true})
-- What the flair row is showing, which is the whole of what the page says
-- about the roster now: one cell, its place in the ring, and the arrows.
local function showing()
    for _, r in ipairs(menu.view().rows) do
        if r.ship then return r.choice end
    end
end
check("right turns the carousel",
      menu.hull_index() == 2 and showing() == 2,
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
check("and it wraps round to the last cell",
      menu.hull_index() == hull_cells,
      "showing " .. tostring(menu.hull_index()))
check("which is sitting out rather than a hull",
      out_act == "spectate", tostring(out_act))
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

-- Up off the first row goes onto the head over the page, which is what up
-- means everywhere in this menu.
menu.stack = {"root", "hangar"}
menu.sel = {}
menu.head_sel = nil
menu.step({up = true})
check("up from the first row goes onto the head",
      menu.stack[2] == "hangar" and menu.view().head_sel == "pilot",
      table.concat(menu.stack, "/") .. "/" .. tostring(menu.view().head_sel))
menu.head_sel = nil

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

-- The same page, seen from the rail. The stage previews the page a rail stop
-- leads to before you go in, and that preview flattens rows down its own
-- path, so what the page draws has to survive both. It is the ship page
-- either way: a preview of a page is that page, not a second drawing of it.
local was_stack, was_sel, was_home = menu.stack, menu.sel, menu.home
menu.home = true
menu.stack = {"root"}
menu.sel = {root = ship_at}
local peek = menu.view()
check("the rail previews the page it points at",
      peek.kit == true and peek.sel == 0,
      tostring(peek.kit) .. ", cursor " .. tostring(peek.sel))
check("flattened, not handed over as it was written",
      type(peek.rows[1].label) ~= "function")
check("and nothing in a preview takes a press",
      peek.kit_preview == true, tostring(peek.kit_preview))
-- The head stands over the preview and over the page alike, which is what
-- makes walking into the ship page from the rail a step rather than a jump:
-- the panel used to drop its own head the moment this page was entered.
check("and the head stays while it is only a preview",
      peek.headless == nil, tostring(peek.headless))
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
-- The mark rides the cell the carousel is showing, since that is the only
-- cell the page draws: turn to the hull you are in and the row says so, turn
-- off it and nothing claims to be where you are.
local function mark_at(cell)
    menu.hull_at = cell
    for _, r in ipairs(menu.view().rows) do
        if r.ship then return r.mark == true end
    end
    return false
end
check("at home, no choice made yet marks the hull you will arrive in",
      mark_at(3) and not mark_at(hull_cells))
menu.spectate = true
check("and choosing to watch moves the wash to the last cell",
      mark_at(hull_cells) and not mark_at(3))
check("which is what the root row says too",
      menu.view().rail[2].detail == "spectating",
      tostring(menu.view().rail[2].detail))
-- In a game the connection is the truth, whatever was remembered: the server
-- can refuse a hull and the page must not claim you got it.
menu.home = false
check("in a game the connection wins over what was remembered",
      mark_at(3) and not mark_at(hull_cells),
      "spectate remembered but watching is false")
menu.spectate = false
menu.home = true

-- Which cell wears the "you are here" wash follows the connection, not the
-- last hull picked: a watcher is in no hull, so no hull is marked at all.
menu.home = false
menu.class = 2
menu.watching = false
check("flying marks the hull you are in",
      mark_at(3) and not mark_at(hull_cells))
menu.watching = true
check("watching marks the last cell instead, and no hull",
      mark_at(hull_cells) and not mark_at(3))
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
check("and starts on the games",
      opened_match.rail[opened_match.rail_sel]
          and opened_match.rail[opened_match.rail_sel].label == "play",
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

-- --- choosing the game you are already in puts the panel away -------------
--
-- The list used to carry a "leave this game" row at its foot, which is a way
-- out written a long way from the thing it was a way out of, in a list that is
-- otherwise entirely places to go. Leaving is a button on the game's own row
-- now, so a press on the row itself means what it means everywhere else in
-- this list: be in this game. On the one you are in that is already true, and
-- the panel is the only thing between you and it.

menu.hover_stage(nil)
menu.home = false
menu.watching = false
menu.zone = "chaos"
menu.ask = nil
menu.show("play")
local zones = menu.view()
-- The games and nothing else. This page carried a community section and a
-- friends section beside them once; friends is a tab of its own now, because
-- who is on is a question asked from wherever you are standing rather than
-- one you go to the games page to ask, and the community section left the
-- game with the rest of it. See docs/design/friends.md.
local heads = {}
for _, r in ipairs(zones.rows) do
    if r.sect then heads[#heads + 1] = r.sect end
end
-- And no heading over them either. The page is the games, so a label reading
-- "zones" over the only list on it was the interface naming what the reader
-- can already see.
check("the play page is the zones and nothing else",
      #heads == 0, table.concat(heads, "/"))
check("nothing at the foot of the list leaves the game",
      #zones.rows == 1 and zones.rows[1].label == "chaos",
      table.concat(texts_of(zones), ", "))

local act2 = menu.step({go = true})
check("enter on the game you are in shuts the panel onto it",
      act2 == nil and menu.ask == nil and not menu.open,
      tostring(act2) .. ", open " .. tostring(menu.open))
-- And it costs nothing else. A press meaning "be here" on the room you are
-- already in must not hand back the seat you are in it with.
check("and nothing is left waiting on a room", menu.await == nil,
      tostring(menu.await))
menu.show("play")

-- A different game asks first, because arriving there costs the game you are
-- in and the press that costs it is the same press. The one card left on this
-- list, and it is only ever raised on a pilot in a hull.
menu.zone = "elsewhere"
menu.chosen = nil
local act5 = menu.step({go = true})
check("a different game asks before it takes the one you are in",
      act5 == nil and menu.ask ~= nil, tostring(act5))
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

-- Two answers, and watching is not one of them: this card is about which game
-- you are in, and what you are flying is the ship page's question.
check("the card offers switching and staying, nothing else",
      #menu.ask.keys == 2 and menu.ask.keys[1].act == "join",
      #menu.ask.keys .. " answers, first is "
          .. tostring(menu.ask.keys[1].act))
menu.ask.sel = 2
menu.step({left = true})
check("left moves to the answer beside it", menu.ask.sel == 1,
      "on " .. tostring(menu.ask.sel))
local act6 = menu.step({go = true})
check("and the answer that switches is a join",
      act6 == "join" and menu.chosen ~= nil and menu.ask == nil,
      tostring(act6))

-- Escape answers it rather than shutting the panel, and answers it with the
-- one that changes nothing: the key that gets out of everything else in here
-- has to get out of this without leaving the game by accident.
menu.step({go = true})
local act4, moved4 = menu.step({back = true})
check("escape answers the question instead of shutting the menu",
      act4 == nil and moved4 and menu.ask == nil and menu.open,
      tostring(act4) .. ", open " .. tostring(menu.open))

-- With no seat there is nothing to lose, so nothing to ask: the press is the
-- one act the list has, and the stands dial it.
menu.home = true
menu.scenery = false
menu.ask = nil
local act7 = menu.step({go = true})
check("and from the home screen it just asks for the game",
      act7 == "want_zone" and menu.ask == nil, tostring(act7))

-- Unless the room it names is the one already playing behind the panel, which
-- is the home screen's own version of being there. A remembered zone name is
-- not: `scenery` is what says a room actually answered, and without it a press
-- would put the panel away over a starfield.
menu.await = nil
menu.zone = "chaos"
menu.scenery = true
local standing = menu.step({go = true})
check("and the game the stands are already showing just shuts the panel",
      standing == nil and not menu.open and menu.await == nil,
      tostring(standing) .. ", open " .. tostring(menu.open))
menu.open = true
menu.scenery = false

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
-- The call sign in the corner of the tab row, beside the stop that opens the
-- same page: the stop is the door a stranger finds, and the name is the one a
-- returning player knows.
check("the tab row carries the pilot stop",
      top_index("pilot") ~= nil,
      table.concat(texts_of(menu.view()), ", "))
menu.click_pilot()
check("and pressing the name opens the page",
      menu.at() == "pilot", table.concat(menu.stack, "/"))
local v_guest = menu.view()
check("a guest is offered the sign up and the login",
      texts_of(v_guest)[2] == "sign up"
          and texts_of(v_guest)[3] == "log in",
      table.concat(texts_of(v_guest), ", "))
check("with the reroll behind its own key rather than the name",
      texts_of(v_guest)[1] == "new name",
      table.concat(texts_of(v_guest), ", "))
check("and the page travels as a card, not an aside",
      v_guest.pilot_card ~= nil and v_guest.aside == nil
          and v_guest.pilot_card.claimed == false,
      tostring(v_guest.pilot_card))

menu.sel.pilot = 2
menu.step({go = true})
check("signing up asks for a password, discs and all",
      menu.ask ~= nil and menu.ask.fields ~= nil
          and #menu.ask.fields == 1 and menu.ask.fields[1].mask == true,
      tostring(menu.ask and menu.ask.fields and #menu.ask.fields))
check("and the card says what signing up buys",
      menu.ask.note == "keep your points and log in on other devices",
      tostring(menu.ask.note))
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

-- --- a control asks, and the next key answers ------------------------------
--
-- Two presses, not one. The row stops saying where its control is and starts
-- asking where it should go, and the key pressed after that is the answer.
-- The page used to draw a keyboard as well, and a click on a key was the same
-- act arriving by pointer; that picture came out at 390 points and this is the
-- whole of the gesture now.
--
-- Rows are pressed here the way a thumb presses them, through `click_stage`,
-- because arming is a branch of `activate` and reaching past it would leave
-- the one press that starts this untested.

do
    local binds = require("arena.binds")
    local keyset = require("arena.keys")
    binds.reset()
    open_controls()

    local rows = menu.view().rows
    local catalog = binds.rows()
    local drift = {}
    for i, control in ipairs(catalog) do
        local row = rows[i]
        if not row or row.label ~= control.name or row.detail ~= control.show
           or row.control ~= control.id or row.fixed ~= control.fixed then
            drift[#drift + 1] = control.id
        end
    end
    check("the controls page is built from the live binding catalog",
          #drift == 0 and #rows == #catalog + 1 and rows[#rows].reset == true,
          table.concat(drift, ", "))

    local map_at, menu_at = nil, nil
    for i, r in ipairs(rows) do
        if r.control == "map" then map_at = i end
        if r.control == "menu" then menu_at = i end
    end
    check("the controls page lists the map key", map_at ~= nil)

    -- Pressing the row is the half that asks. Nothing is bound by it.
    menu.click_stage(map_at)
    check("pressing a control row sets it asking",
          menu.arming == "map" and binds.chord_of.map[1] ~= "z",
          tostring(menu.arming))
    check("and the page says what it is waiting for",
          (menu.foot or ""):find("press a key") ~= nil, tostring(menu.foot))

    -- A key nothing is using. The control moves and the asking is over.
    local moved = menu.bind_chord({"z"})
    check("a free key moves the control that was asking",
          moved and binds.chord_of.map[1] == "z" and menu.arming == nil,
          table.concat(binds.chord_of.map, "+"))
    check("and the page says so", (menu.foot or ""):find("map is on Z") ~= nil,
          tostring(menu.foot))

    -- A key somebody else is on: the two trade, and nothing is left over.
    menu.click_stage(map_at)
    local traded = menu.bind_chord({"space"})
    check("a taken key trades", traded
          and binds.chord_of.map[1] == "space"
          and binds.chord_of.guns[1] == "z",
          table.concat(binds.chord_of.map, "+") .. " / "
          .. table.concat(binds.chord_of.guns, "+"))

    -- The menu key is nobody's to move, and the row says why rather than
    -- doing nothing. It refuses at the asking rather than at the answer: a
    -- control that will not move never starts waiting for a key at all.
    menu.arming, menu.note = nil, nil
    menu.click_stage(menu_at)
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
    menu.click_stage(map_at)
    local chorded = menu.bind_chord({"shift", "j"})
    check("a chord typed at an asking control lands whole",
          chorded and table.concat(binds.chord_of.map, "+") == "shift+j",
          table.concat(binds.chord_of.map, "+"))

    -- A key with no trigger under it is a key a control would vanish onto.
    check("and the catalog only takes keys that report",
          keyset.bindable("backslash") and keyset.bindable("slash")
          and not keyset.bindable("caps") and not keyset.bindable("enter"))
    binds.reset()
    menu.foot, menu.note = nil, nil
end

-- --- and the view carries what the page needs to draw itself ---------------
--
-- The rows the page holds and the rows it hands the renderer are two shapes,
-- and the second is built by copying named fields out of the first. A field
-- that gets renamed on one side and not the other is invisible from both: the
-- page goes on holding the right answer and the drawing goes on asking for a
-- name nothing sets. That shipped once, when the page still drew a keyboard:
-- every key on the board came out unlit, because the chords were in the rows
-- and `keys` was being read from a flattened row that still said `key`.
--
-- The board went with the width and took `keys` and `cat` with it. What is
-- left to lose the same way is what a row says and what it stands for, which
-- is checked from the far end of `M.view` because that is where the copy is.

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
    local mute, adrift = {}, {}
    for _, r in ipairs(v.rows) do
        -- Every row but the one that resets everything stands for a control,
        -- says which key it is on, and can be pressed to move it.
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

    -- And a chord arrives whole rather than as its trigger.
    local chorded = nil
    for _, r in ipairs(v.rows) do
        if r.control == "map" then chorded = r end
    end
    check("a chord reaches the drawing with both its keys",
          chorded ~= nil and chorded.detail == "Shift+Tab",
          chorded and tostring(chorded.detail) or "no map row")
    binds.reset()
end

-- --- the only way out of the game is the two documents ---------------------
--
-- The game carried a community door for a while: a corner button on the tab
-- row that opened a page about the Discord server, with the invite on it as a
-- link the browser laid a real anchor over. It is gone, and the site is where
-- it lives now. What is left inside the game is privacy and terms, which are
-- on the about page because the account is minted before a player has a
-- reason to visit the bare site.

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

local function about_row(label)
    open_about()
    for i, entry in ipairs(menu.view().rows) do
        if entry.label == label then return i end
    end
    return nil
end

do
    local asked

    menu.open = true
    -- Nothing on the tab row but the tabs and the call sign, and no page
    -- behind a stop that is not one of theirs.
    menu.home = true
    menu.stack = {"root"}
    menu.sel = {}
    check("no community door is left on the tab row",
          menu.view().discord == nil and menu.open_discord == nil,
          "one is")

    for label, url in pairs({privacy = "https://vectorwake.net/privacy",
                             terms = "https://vectorwake.net/terms"}) do
        asked = nil
        menu.ask = nil
        _G.sys.open_url = function(got, attrs)
            asked = {url = got, target = attrs and attrs.target}
            return true
        end
        local row = about_row(label)
        check("about carries " .. label, row ~= nil, "absent")
        if row then menu.click_stage(row) end
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
    local refused = about_row("terms")
    if refused then menu.click_stage(refused) end
    check("a refusal puts nothing on screen", menu.view().ask == nil,
          tostring(menu.view().ask and menu.view().ask.head))

    -- And an engine with no open_url at all does not take the menu down.
    _G.sys.open_url = nil
    local bare = about_row("privacy")
    local ok = bare ~= nil and pcall(menu.click_stage, bare)
    check("an engine without open_url survives the tap", ok)
end

-- --- and no page asks the browser for an anchor over the canvas -----------
--
-- One row did: the invite on the community page, because nothing the client
-- does from its own loop is inside the tap that asked for it and every phone
-- called a frame-late window.open a popup. No row in the menu leaves the game
-- any more, so no row carries an address for the page to lay an anchor over,
-- and a stray one would put a live link over a page of the game's own.

do
    menu.open = true
    menu.home = true
    local strays = {}
    for _, page in ipairs({"play", "hangar", "friends", "settings",
                           "pilot"}) do
        menu.stack = {"root", page}
        local view = menu.view()
        for _, r in ipairs(view.rows or {}) do
            if r.link then strays[#strays + 1] = page .. "/" .. r.label end
        end
        for _, r in ipairs(view.rail or {}) do
            if r.link then strays[#strays + 1] = "rail/" .. r.label end
        end
    end
    check("no row or rail stop carries an address", #strays == 0,
          table.concat(strays, ", "))
    menu.stack = {"root"}
    menu.sel = {}
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
    menu.head_sel = nil
    menu.stack = {"root"}
    menu.sel = {root = top_index("friends")}
    -- An arrow off the rail is a step in a direction, so it lands at the end
    -- of the list it came in at rather than in the box over it. Down opened
    -- the box, which meant pressing up on `friends` -- reaching for the last
    -- name on the page -- landed in the add field at the top of it instead.
    menu.step({down = true})
    check("down off the tabs opens friends at the top of the list",
          menu.at() == "friends" and menu.add_on == false
          and menu.sel.friends == 1,
          menu.at() .. "/" .. tostring(menu.add_on) .. "/"
          .. tostring(menu.sel.friends))
    menu.stack = {"root"}
    menu.sel = {root = top_index("friends")}
    menu.add_on = false
    -- The last row a cursor may stand on, which is the last one carrying an
    -- act: the readouts under it are not stops anywhere in this menu.
    local last_name = nil
    for i, r in ipairs(menu.view().rows) do
        if r.pick then last_name = i end
    end
    menu.step({up = true})
    check("and up off them opens it on the last name instead",
          menu.at() == "friends" and menu.add_on == false
          and last_name ~= nil and last_name > 1
          and menu.sel.friends == last_name,
          tostring(menu.sel.friends) .. " of " .. tostring(last_name)
          .. "/" .. tostring(menu.add_on))
    menu.sel.friends = 1
    menu.step({up = true})
    check("up off the first row comes to the field", menu.add_on == true,
          tostring(menu.add_on))
    menu.step({down = true})
    check("and down again goes back to the list",
          menu.at() == "friends" and menu.add_on == false,
          tostring(menu.add_on))
    menu.sel.friends = 1
    menu.step({up = true})
    menu.step({up = true})
    check("and up out of the field goes onto the head",
          menu.at() == "friends" and menu.add_on == false
          and menu.view().head_sel == "pilot",
          menu.at() .. "/" .. tostring(menu.view().head_sel))
    -- And back down into it, because the box is what is drawn under that
    -- line on this page.
    menu.step({down = true})
    check("down off the head lands in the field again",
          menu.head_sel == nil and menu.add_on == true,
          tostring(menu.head_sel) .. "/" .. tostring(menu.add_on))
    menu.add_on = false
    menu.head_sel = nil

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
        check("and up out of it still goes onto the head",
              menu.at() == "friends" and menu.add_on == false
              and menu.view().head_sel == "pilot",
              menu.at() .. "/" .. tostring(menu.view().head_sel))
        menu.head_sel = nil
        account.friends, account.asked, account.here = kept[1], kept[2], kept[3]
        account.waiting, account.everybody = kept[4], kept[5]
    end

    -- And the field is the page's, not the rail's preview of it. A letter
    -- typed at the top of the menu would land in a box nobody can see.
    menu.stack = {"root"}
    menu.sel = {root = top_index("play")}
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
        -- And a keyboard reaches the swap through the reading, which is
        -- where enter on a slot row goes: the box on the row is a pointer's
        -- control, and the reading is where the same act is a key.
        local at = nil
        for i, r in ipairs(menu.view().rows) do
            if r.charge_slot == 1 then at = i end
        end
        check("a charge row is on the page", at ~= nil, "none")
        menu.sel.hangar = at
        menu.step({go = true})
        check("enter on it opens the reading", menu.at() == "slot",
              table.concat(menu.stack, "/"))
        local swap_at = nil
        for i, r in ipairs(menu.view().rows) do
            if r.act == "swap_charges" then swap_at = i end
        end
        check("which carries the swap as a key of its own",
              swap_at ~= nil, "none")
        menu.sel.slot = swap_at
        menu.step({go = true})
        menu.stack = {"root", "hangar"}
        check("and pressing it trades the two",
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
    -- The band, then every slot this arena has, then flair. Every slot the
    -- arena takes, not every slot the account owns: what the page could not
    -- say before is that there is more of a thing and it is not yours yet.
    -- No save key on a kit nobody has touched yet.
    check("the band, the arena's slots and the flair",
          #v.rows == 7, table.concat(labels, ", "))
    check("with the hull and the wake in the flair at the foot",
          hull_at2 == #v.rows - 1 and wake_at2 == #v.rows
              and v.rows[hull_at2].detail == "Apex",
          table.concat(labels, ", "))
    check("and no save key until something moves",
          v.rows[#v.rows].group == "flair",
          tostring(v.rows[#v.rows].group))
    -- One point spent, and the key that keeps it appears.
    menu.kit_step(0, 1)
    local moved_rows = menu.view().rows
    check("a point spent puts the save key at the foot",
          moved_rows[#moved_rows].group == "save",
          tostring(moved_rows[#moved_rows].group))
    menu.kit_step(0, -1)
    local back_rows = menu.view().rows
    check("and taking it back takes the key away again",
          back_rows[#back_rows].group == "flair",
          tostring(back_rows[#back_rows].group))
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
    check("and covers every one of them", #order == want,
          #order .. " of " .. want)
    -- And the press after the last row leaves the page for the stops drawn
    -- under it. The list used to wrap from its foot back to its head, which
    -- made the page a ring a hand could not get out of downward.
    check("then down off the last row goes to the tabs",
          menu.at() == "root", table.concat(menu.stack, "/"))
    -- Up from there comes back in, to the row it left.
    menu.step({up = true})
    check("and up from the tabs goes back into the page",
          menu.at() == "hangar" and menu.sel.hangar == order[#order],
          table.concat(menu.stack, "/") .. " row "
              .. tostring(menu.sel.hangar))
    menu.stack = {"root", "hangar"}
    menu.sel.hangar = 1

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
    -- The library is a page behind the band's name key rather than a column
    -- on the ship page: a list of builds and a kit are two activities, and
    -- the one that happens once a session does not deserve a third of the
    -- longest page in the menu.
    local function band_key(which)
        for i, row in ipairs(menu.view().rows) do
            if row.group == "band" and row.act == which then return i end
        end
    end
    check("the band opens the library and the points",
          band_key("builds") == 1 and band_key("points") == 2,
          tostring(band_key("builds")) .. "/" .. tostring(band_key("points")))
    menu.sel.hangar = band_key("builds")
    menu.step({go = true})
    check("pressing the build's name opens the library",
          menu.at() == "builds", table.concat(menu.stack, "/"))

    local function library()
        local listed, keys = {}, {}
        for i, row in ipairs(menu.view().rows) do
            if row.act == "profile" then listed[#listed + 1] = i end
            if row.act == "new_build" then keys.new = i end
            if row.act == "delete_profile" then keys.delete = i end
        end
        return listed, keys
    end
    local listed, keys = library()
    check("every build is a row, with the two keys under them",
          #listed == 2 and listed[1] == 1 and listed[2] == 2
          and keys.new == 3 and keys.delete == 4,
          #listed .. " builds, keys " .. tostring(keys.new) .. "/"
              .. tostring(keys.delete))
    check("and the one the kit matches carries the mark",
          menu.view().rows[listed[1]].choice == 1
          and menu.view().rows[listed[2]].choice == 0,
          tostring(menu.view().rows[listed[2]].choice))
    -- Nothing marks one of them out. The three a pilot is dealt are rows of
    -- their own list, so nothing here says otherwise and both keys act on
    -- them like they act on anything else.
    check("and nothing renames one, or calls one the game's",
          menu.view().rows[keys.delete].label == "delete"
          and #menu.view().rows == 4
          and menu.view().rows[listed[1]].starter == nil,
          tostring(#menu.view().rows) .. " rows")
    check("delete is a live key on a build you were dealt",
          menu.view().rows[keys.delete].dim ~= true,
          tostring(menu.view().rows[keys.delete].dim))
    menu.sel.builds = listed[2]
    local selected_profile = menu.step({go = true})
    check("pressing a row loads that whole build",
          selected_profile == "kit" and menu.profile_at == 2
          and menu.kit[1] == 4 and menu.kit[6] == 2,
          tostring(selected_profile) .. "/" .. tostring(menu.profile_at))
    check("and the band names it",
          menu.profile_band().name == "Bomber"
          and menu.profile_band().state == nil,
          menu.profile_band().name .. "/"
              .. tostring(menu.profile_band().state))

    -- Entering the ship page lands the cursor on the band, which is the first
    -- thing on it and the one row a hand coming down off the tabs meets.
    menu.stack = {"root"}
    menu.sel.root = ship_at
    menu.step({go = true})
    check("entering the hangar lands on the band",
          menu.at() == "hangar" and (menu.sel.hangar or 1) == 1,
          table.concat(menu.stack, "/") .. " row "
              .. tostring(menu.sel.hangar or 1))

    -- --- keeping a build ----------------------------------------------------
    --
    -- The save key is at the foot of the ship page and is there only while
    -- the thirty points in hand differ from the build they came from. Its
    -- absence is the answer to "is there anything to keep here".
    local function save_key()
        for i, row in ipairs(menu.view().rows) do
            if row.act == "save_kit" then return i end
        end
    end
    check("a build nobody has touched offers no save",
          save_key() == nil, tostring(save_key() or "none"))
    menu.kit_step(0, -1)
    check("editing it turns it into a custom build",
          menu.profile_at == nil, tostring(menu.profile_at))
    check("and the page says the kit has moved since it opened",
          menu.kit_changed() == true, tostring(menu.kit_changed()))
    check("and the band still says which build it came from",
          menu.profile_band().name == "Bomber"
          and menu.profile_band().state == "edited",
          menu.profile_band().name .. "/"
              .. tostring(menu.profile_band().state))
    check("and the save key is on the page now",
          save_key() ~= nil and menu.view().rows[save_key()].group == "save",
          tostring(save_key()))

    -- Save writes over the build these thirty points came from, whichever it
    -- is: the three a pilot is dealt are rows of their own list and there is
    -- nothing left that refuses one.
    menu.sel.hangar = save_key()
    local over = menu.step({go = true})
    check("saving writes over the build it came from",
          over == "save_profile" and menu.pending_profile == "Bomber"
          and menu.at() == "hangar",
          tostring(over) .. "/" .. tostring(menu.pending_profile))

    -- A kit that came from nowhere has no name to write to, so the key goes
    -- to the page that gives it one, which is where the library's NEW key
    -- goes too.
    menu.profile_from, menu.profile_at = nil, nil
    menu.new_name, menu.new_on = "", false
    menu.sel.hangar = save_key()
    menu.step({go = true})
    check("a kit from nowhere goes to the naming page instead",
          menu.at() == "newbuild" and menu.new_on == true,
          table.concat(menu.stack, "/") .. "/" .. tostring(menu.new_on))
    check("with nothing offered back, since it answers to no name",
          menu.view().new.name == "", tostring(menu.view().new.name))
    check("and one row on it, the key that makes the build",
          #menu.view().rows == 1
          and menu.view().rows[1].act == "create_build"
          and menu.view().newbuild == true,
          tostring(#menu.view().rows))

    -- The box takes type, and an empty one is a build with no name.
    menu.note = nil
    local named = menu.click_create()
    check("creating with an empty box says so rather than sending it",
          named == nil and menu.note ~= nil
          and string.find(menu.note, "name", 1, true) ~= nil,
          tostring(menu.note))
    for ch in string.gmatch("Screen", ".") do menu.type_new(ch) end
    check("the box takes letters", menu.new_name == "Screen", menu.new_name)
    menu.rub_new()
    check("and gives them back", menu.new_name == "Scree", menu.new_name)
    menu.type_new("n")
    named = menu.click_create()
    check("creating hands the named build to the arena",
          named == "save_profile" and menu.pending_profile == "Screen",
          tostring(named) .. "/" .. tostring(menu.pending_profile))
    -- And the page goes with it. A page for naming one thing has nothing left
    -- to say once it is named, and it stayed up behind the build it had just
    -- made.
    check("and the naming page slides back off",
          menu.at() ~= "newbuild" and menu.new_on == false,
          table.concat(menu.stack, "/") .. "/" .. tostring(menu.new_on))

    -- Over one of your own the key writes to it rather than asking for a
    -- name: that is what save means on a thing that already has one.
    account.profiles[3] = {name = "Screen", builtin = false,
                           kit = second_profile}
    menu.profile_from, menu.profile_at = 3, nil
    menu.stack = {"root", "hangar"}
    menu.sel.hangar = save_key()
    local saved = menu.step({go = true})
    check("saving over one of yours needs no name",
          saved == "save_profile" and menu.pending_profile == "Screen"
          and menu.at() == "hangar",
          tostring(saved) .. "/" .. tostring(menu.pending_profile))

    -- And a build can be dropped, from the library, which asks first: it is
    -- the one thing here that takes something away for good.
    menu.profile_from, menu.profile_at = 3, nil
    menu.stack = {"root", "builds"}
    menu.sel = {}
    local _, own_keys = library()
    menu.sel.builds = own_keys.delete
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
    menu.stack = {"root", "hangar"}
    menu.sel = {}

    -- --- the price rides the row it belongs to -------------------------------
    --
    -- The shelf was a tab of its own drawing the same slots in the same order
    -- for the other question. It is the same page now: a rung the account
    -- does not own is a dim circle, and where it is for sale the row ends in
    -- what it costs. See docs/design/match-game.md and .design/hangar.
    account.entitlements = {[1] = 1}
    account.rivets = 500
    account.catalog = {{slot = 0, label = "energy depth", price = 40,
                        owned = 1, ceiling = 4, base = 0,
                        note = "a 7th step, on this stat alone"}}
    menu.kit = nil
    menu.open_kit(0)
    local priced = nil
    for _, r in ipairs(menu.view().rows) do
        if r.label == "energy" then priced = r end
    end
    check("the ship page carries the price of the next rung",
          priced ~= nil and priced.price == 40 and priced.afford == true,
          priced and tostring(priced.price) or "no energy row")
    check("with what is owned against how far the arena's own ladder runs",
          priced.choices == 1 and priced.arena_max == 4,
          tostring(priced.choices) .. "/" .. tostring(priced.arena_max))

    -- An arrow that runs out of ladder says so. It is a control for setting a
    -- value, so it does not open a page nobody asked for; the price it is
    -- refusing over is already drawn on the end of the row.
    menu.sel.hangar = first_slot()
    menu.ask = nil
    menu.note = nil
    for _ = 1, 4 do menu.step({right = true}) end
    check("the ladder stops at what the account owns", menu.kit[1] == 1,
          tostring(menu.kit[1]))
    check("and an arrow at the top of it raises no card", menu.ask == nil,
          menu.ask and menu.ask.head or "quiet")
    check("but says the rung above is not yours yet",
          menu.note ~= nil
          and string.find(menu.note, "not yours yet", 1, true) ~= nil,
          tostring(menu.note))

    -- --- the reading, which is where anything is bought ----------------------
    --
    -- Enter on a slot row, a press on its name, or a press on the part of its
    -- ladder nobody owns: all three are the same question, and this page is
    -- the answer.
    menu.ask, menu.note = nil, nil
    menu.sel.hangar = first_slot()
    menu.step({go = true})
    check("enter on a slot opens its reading", menu.at() == "slot",
          table.concat(menu.stack, "/"))
    local reading = menu.view()
    check("which is about that slot", reading.item ~= nil
          and reading.item.label == "energy" and reading.item.price == 40,
          reading.item and reading.item.label or "nothing")
    check("and carries the lesson and the wallet, which no other page does",
          reading.item.teach ~= nil and reading.wallet == 500,
          tostring(reading.wallet))
    check("with the buy as its one key",
          #reading.rows == 1 and reading.rows[1].act == "buy",
          tostring(#reading.rows))
    menu.step({go = true})
    check("and the key asks before it spends",
          menu.ask ~= nil and string.find(menu.ask.head, "40", 1, true),
          menu.ask and menu.ask.head or "no card")
    check("with the answer that changes nothing under the cursor",
          menu.ask.keys[menu.ask.sel].act == nil, tostring(menu.ask.sel))
    menu.pending = nil
    local bought = menu.click_answer(1)
    check("and answering it buys that slot",
          bought == "buy" and menu.pending == 0,
          tostring(bought) .. "/" .. tostring(menu.pending))
    menu.ask = nil

    -- The chevron and the swipe both come back out of it.
    check("there is a level to come back out of", menu.can_back() == true,
          tostring(menu.can_back()))
    menu.click_back()
    check("and coming back lands on the ship page", menu.at() == "hangar",
          table.concat(menu.stack, "/"))

    -- A rung nobody owns, pressed directly. Same question, same answer.
    menu.ask, menu.note = nil, nil
    menu.click_kit_at(first_slot(), 3)
    check("a press on a rung nobody owns opens the reading",
          menu.at() == "slot" and menu.ask == nil,
          table.concat(menu.stack, "/"))
    menu.click_back()
    -- The circle a slot is already on takes the point back, which is the only
    -- way a pointer can walk a ladder down: every other circle means "this
    -- many of these", and the lit one already means the level it is at.
    menu.click_kit_at(first_slot(), 1)
    check("pressing the one it is on takes the point back",
          menu.at() == "hangar" and menu.kit[1] == 0,
          tostring(menu.kit[1]))
    menu.click_kit_at(first_slot(), 1)
    check("and a rung you own is still just a rung",
          menu.at() == "hangar" and menu.kit[1] == 1,
          tostring(menu.kit[1]))

    -- A wallet too light is told the price rather than asked to pay it.
    account.rivets = 10
    menu.kit = nil
    menu.open_kit(0)
    menu.stack = {"root", "hangar"}
    menu.sel.hangar = first_slot()
    menu.ask = nil
    menu.step({go = true})
    menu.step({go = true})
    check("a short wallet is told the price rather than asked to pay it",
          menu.ask ~= nil and #menu.ask.keys == 1
          and string.find(menu.ask.note or "", "10", 1, true),
          menu.ask and (menu.ask.head .. "/" .. tostring(menu.ask.note))
              or "no card")
    menu.ask = nil
    menu.stack = {"root", "hangar"}
    account.catalog = nil
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

    -- --- what is on the page is every slot the arena has ---------------------
    --
    -- A slot the account owns none of used to be off the page altogether, on
    -- the argument that this page is what you fly. What that cost was the one
    -- thing a pilot asks it: why does this stop here, and what would it take.
    -- Every slot the arena takes is a row now, and the ones nobody owns are
    -- dim circles with a price on the end.
    for i = 1, 23 do CEIL[i] = 0 end
    CEIL[1] = 4          -- the first stat
    CEIL[6] = 2          -- the gun's ladder
    CEIL[8] = 3          -- gun spray, three rounds' worth
    CEIL[9] = 2          -- gun bounce, two rungs
    CEIL[12] = 1         -- gun freeze, one
    CEIL[20] = 3         -- the first charge
    account.catalog = nil
    account.entitlements = {}
    menu.stack = {"root", "hangar"}
    menu.sel = {}
    menu.kit = nil
    menu.open_kit(0)
    local owned = {}
    for _, r in ipairs(menu.view().rows) do owned[#owned + 1] = r.label end
    -- Ten: the band's two, the six slots this zone allows, the hull and the
    -- wake. Nothing has moved since the page opened, so no save key.
    check("every slot the arena takes is on the page",
          #owned == 10, table.concat(owned, ", "))

    -- Now the account owns none of the gun's ladder and one of three repels.
    -- The rows stay: what changes is how much of each ladder is lit.
    account.entitlements = {[6] = 0, [20] = 1}
    menu.kit = nil
    menu.open_kit(0)
    local mine, charge, gun = {}, nil, nil
    for _, r in ipairs(menu.view().rows) do
        mine[#mine + 1] = r.label
        if r.label == "repel" then charge = r end
        if r.label == "gun level" then gun = r end
    end
    check("a slot the account owns none of is still on the page",
          #mine == 10 and gun ~= nil, table.concat(mine, ", "))
    check("drawn with nothing of it owned, and the arena's ladder behind it",
          gun.choices == 0 and gun.arena_max == 2,
          tostring(gun.choices) .. "/" .. tostring(gun.arena_max))
    check("and a ladder lights what the account owns, against the arena's",
          charge ~= nil and charge.choices == 1 and charge.arena_max == 3,
          charge and (tostring(charge.choices) .. "/"
                      .. tostring(charge.arena_max)) or "no repel row")

    -- --- every slot is a ladder, and the arrows walk it ---------------------
    --
    -- The add-ons were chips: a row of boxes across the page, where left and
    -- right went to the box beside this one and enter threw the one you were
    -- on. That was a second control grammar on a page that already had
    -- ladders, and a third for the count spray keeps. Every slot is a ladder
    -- now, so there is one control here and both directions of it work.
    account.entitlements = {}
    -- A build with a point already on it, so `open_kit` does not fall back to
    -- the starter kit and hand this test a row that is already spent on.
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
    check("the add-ons are rows of the gun's own section",
          bounce ~= nil and freeze == bounce + 1,
          tostring(bounce) .. "/" .. tostring(freeze))
    menu.sel.hangar = bounce
    menu.step({right = true})
    check("right spends a point on it", (menu.kit[9] or 0) == 1,
          tostring(menu.kit[9]))
    check("without the cursor leaving the row", menu.sel.hangar == bounce,
          "cursor " .. tostring(menu.sel.hangar))
    menu.step({right = true})
    check("and again, up the rungs it has", (menu.kit[9] or 0) == 2,
          tostring(menu.kit[9]))
    menu.step({left = true})
    menu.step({left = true})
    check("and left gives them back", (menu.kit[9] or 0) == 0,
          tostring(menu.kit[9]))

    -- Spray reads as a count of rounds rather than a position on a ladder,
    -- which is a difference in what the row says and not in how it works.
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

    -- And enter goes to the reading, on every one of them, which is the one
    -- press left over once the arrows do both directions.
    menu.sel.hangar = bounce
    menu.step({go = true})
    check("enter on an add-on opens its reading rather than throwing it",
          menu.at() == "slot" and (menu.kit[9] or 0) == 0,
          table.concat(menu.stack, "/"))
    menu.click_back()

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
    menu.add_on = false

    local kept_rows = account.rows
    local kept_here, kept_friends = account.here, account.friends

    -- The games, with the directory still on its way. It used to be the
    -- upgrades tab that could stand empty; the shelf is the ship page now and
    -- the ship page always has a band to stand on, so the list of games is
    -- the page this guard is about.
    local dir = package.loaded["arena.directory"]
    local kept_dir = dir.rows
    dir.rows = {}
    local up_at = top_index("play")
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
    dir.rows = kept_dir
    menu.stack = {"root"}
    menu.sel.root = up_at
    menu.step({down = true})
    check("once the list is there the same press goes in",
          menu.at() == "play", table.concat(menu.stack, "/"))

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

    -- The tab set follows the cockpit, not the zone. Five stops with no hull
    -- at home; the short row only once you are flying one.
    local function labels()
        local out = {}
        for _, r in ipairs(menu.view().rail) do out[#out + 1] = r.label end
        return table.concat(out, " ")
    end

    menu.home, menu.scenery, menu.watching = true, true, false
    menu.open, menu.stack, menu.sel = true, {"root"}, {}
    check("the stands carry the whole row",
          labels() == "play ship friends settings pilot",
          labels())

    -- The short row keeps the games, because that is where the way out of the
    -- one you are in is written now, and drops the hangar, because a hull is
    -- locked for the match.
    menu.home, menu.watching = false, false
    check("a pilot in a hull gets the short one",
          labels() == "play friends settings", labels())

    -- A pilot the room benched is in the stands too: same empty cockpit, same
    -- time to read, so the same stops. What they keep that the landing does
    -- not is `leave`: they are in a zone, and no row of the list carries a
    -- way out of one you are not flying. What they lose is `pilot`, which
    -- needs there to be no zone: an account is not edited from inside a room.
    menu.home, menu.watching = false, true
    check("a benched pilot gets the whole row back",
          labels() == "play ship friends settings leave",
          labels())

    menu.home, menu.scenery, menu.watching = kept.home, kept.scenery,
                                             kept.watching
    menu.open, menu.stack, menu.sel = kept.open, kept.stack, kept.sel
end

-- --- the guest banner arms only when there is something to lose ----------
do
    local kept = {claimed = account.claimed, friends = account.friends,
                  home = menu.home, stack = menu.stack, sel = menu.sel}
    menu.open, menu.home = true, true
    menu.stack, menu.sel = {"root"}, {}
    account.claimed = false
    account.friends = {}
    account.career = nil
    check("a fresh guest gets no banner and no dot",
          menu.view().banner ~= true and menu.view().guest_dot ~= true)
    account.friends = {{name = "Sable"}}
    check("a friend made arms the banner",
          menu.view().banner == true and menu.view().guest_dot == true)
    menu.stack = {"root", "pilot"}
    check("but not over the page it points at",
          menu.view().banner ~= true and menu.view().guest_dot == true,
          tostring(menu.view().banner))
    menu.stack = {"root"}
    menu.home = false
    check("and not away from home, where the page is not",
          menu.view().banner ~= true)
    menu.home = true
    account.claimed = true
    check("signing up takes it down",
          menu.view().banner ~= true and menu.view().guest_dot ~= true)
    account.claimed, account.friends = kept.claimed, kept.friends
    menu.home, menu.stack, menu.sel = kept.home, kept.stack, kept.sel
end

-- --- an arrow off the tabs walks into the page at the end it came in at -----
--
-- The tab row is at the foot of the drawer and the page is above it, so up is
-- the direction the page is in and the row it reaches first is the last one.
-- Down is the other way round the same fact: it comes in over the top of the
-- list and lands on the first row.
--
-- Both used to land wherever that page was last left. What that produced is
-- the pair of presses this pins: press up on `ship` to read the foot of the
-- kit, come back out, press down, and the cursor went to the wake at the
-- bottom of the page rather than the first ladder at the top of it. Neither
-- arrow was pointing anywhere.
--
-- Enter is not a step in a direction, so it still lands where the page was
-- left. That is what makes walking down off the foot of a list and straight
-- back in with enter land you where you were.

do
    local kept = {home = menu.home, stack = menu.stack, sel = menu.sel,
                  head = menu.head_sel}
    menu.open, menu.home = true, true

    for _, tab in ipairs({"ship", "settings", "pilot"}) do
        menu.stack = {"root"}
        menu.sel = {root = top_index(tab)}
        menu.head_sel = nil
        local n = #menu.view().rows
        menu.step({up = true})
        local landed = menu.sel[menu.stack[#menu.stack]]
        check("up into " .. tab .. " lands on its last row",
              n > 1 and landed == n,
              tostring(landed) .. " of " .. tostring(n))
    end

    -- And down lands on the first row, whatever the page was left on. The
    -- ship page's band is not it: the build's name and the points meter are
    -- drawn over the ladders rather than in them, so the first row of the
    -- list is the first ladder.
    for _, tab in ipairs({"settings", "pilot"}) do
        menu.stack = {"root"}
        menu.sel = {root = top_index(tab)}
        menu.head_sel = nil
        menu.step({up = true})
        local page = menu.stack[#menu.stack]
        menu.step({down = true})
        menu.sel = {root = top_index(tab)}
        menu.step({down = true})
        check("down into " .. tab .. " lands on its first row",
              menu.sel[page] == 1, tostring(menu.sel[page]))
    end

    menu.stack = {"root"}
    menu.sel = {root = top_index("ship")}
    menu.head_sel = nil
    menu.step({down = true})
    local kit = menu.view()
    local first = menu.sel.hangar
    check("down into ship lands on the first ladder, not the band over it",
          menu.at() == "hangar" and kit.rows[first] ~= nil
          and kit.rows[first].group ~= "band"
          and kit.rows[first - 1].group == "band",
          tostring(first) .. "/"
          .. tostring(kit.rows[first] and kit.rows[first].group))

    -- Down off the foot of a list reaches the tabs, and enter goes back to the
    -- row it left rather than to either end: enter is not a step in a
    -- direction, it is a way in.
    menu.stack = {"root"}
    menu.sel = {root = top_index("settings")}
    menu.head_sel = nil
    menu.step({up = true})
    local page = menu.stack[#menu.stack]
    menu.sel[page] = 2
    menu.step({go = true})
    check("enter still lands where the page was left",
          menu.sel[menu.stack[#menu.stack]] == 2,
          tostring(menu.sel[menu.stack[#menu.stack]]))

    menu.home, menu.stack, menu.sel = kept.home, kept.stack, kept.sel
    menu.head_sel = kept.head
end

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
