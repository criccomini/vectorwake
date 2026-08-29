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
    -- What a game is called, by its key, looked up in the games list the way
    -- the real one does: the label is the catalog's and the key is the wire's,
    -- and a stub that handed the key back would let a page ship the word
    -- "melee" to somebody who chose Team Battle off a list.
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
-- Two stops at home since decision 99. A pilot stop stood between them,
-- opening an account page that is now the landing's account stop: what the
-- drawer has left at home is the ship and the machine.
check("the tab row is ship, settings",
      table.concat(tabs, "/") == "ship/settings",
      table.concat(tabs, "/"))
check("the rail carries the destinations", ship_at and settings_at,
      "ship " .. tostring(ship_at) .. ", settings " .. tostring(settings_at))
check("and no pilot stop", top_index("pilot") == nil,
      table.concat(tabs, "/"))
menu.stack = {"root"}
menu.sel = {}

-- --- the game you are in, and the way out of it ---------------------------
--
-- Leaving goes one step, and which step is whichever one you are standing on.
-- Flying, it hands the seat back and leaves the panel standing, because what
-- changed is on the glass behind it. Benched, the seat is already gone and the
-- step is out of the room, which costs the match and asks first.
--
-- It was a button on the row of the game you were flying, drawn on a games
-- list this drawer no longer has.
do
    local kept_stack, kept_sel = menu.stack, menu.sel
    local kept_zone, kept_home = menu.zone, menu.home
    menu.open, menu.home, menu.watching = true, false, false
    menu.zone = "chaos"
    menu.stack, menu.sel = {"root"}, {}

    local flying = menu.view()
    local out = nil
    for i, r in ipairs(flying.rail) do
        if r.label == "leave" then out = i end
    end
    check("the tab row of a pilot in a hull carries a leave", out ~= nil,
          table.concat((function()
              local t = {}
              for _, r in ipairs(flying.rail) do t[#t + 1] = r.label end
              return t
          end)(), "/"))
    check("and it stands in the slot before settings",
          out ~= nil and flying.rail[out + 1]
          and flying.rail[out + 1].label == "settings",
          tostring(out))

    -- Pressing it hands the seat back. The panel stays: nothing about where
    -- this client is has moved, and the corner's TAKE SEAT is the way in.
    menu.sel = {root = out}
    local left, moved = menu.step({go = true})
    check("and pressing it hands the seat back",
          left == "leave_seat" and moved,
          tostring(left) .. "/" .. tostring(moved))
    check("and leaves the panel standing", menu.open)

    -- Benched in the same room: the seat is gone, so the same stop is the way
    -- out of the room, and that one asks first.
    menu.watching = true
    local benched = menu.view()
    local out2 = nil
    for i, r in ipairs(benched.rail) do
        if r.label == "leave" then out2 = i end
    end
    check("a benched pilot's leave is the way out of the room", out2 ~= nil)
    menu.sel = {root = out2}
    menu.ask = nil
    local asked = menu.step({go = true})
    check("and it asks before costing the match",
          asked == nil and menu.ask ~= nil,
          tostring(asked) .. "/" .. tostring(menu.ask))
    menu.ask = nil

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
    -- From the last stop, which is settings on every row the panel draws.
    menu.sel = {root = settings_at}
    menu.head_sel = nil
    menu.step({right = true})
    check("the rail row is the tabs alone, and it wraps",
          menu.head_sel == nil and menu.sel.root == 1,
          tostring(menu.head_sel) .. "/" .. tostring(menu.sel.root))
    menu.step({left = true})
    check("and back the other way", menu.sel.root == settings_at,
          tostring(menu.sel.root))

    -- Up off the first row of a page is the way onto that line, and it lands
    -- on the x, which is the whole of that row since decision 99. The call
    -- sign at the far end of it was the other stop, a second door onto the
    -- pilot page; it is a label now, and a label is not walked to.
    menu.stack = {"root", "hangar"}
    menu.sel = {hangar = 1}
    menu.head_sel = nil
    menu.step({up = true})
    check("up off the first row of a page lands on the x",
          menu.view().head_sel == "close",
          tostring(menu.view().head_sel))
    -- One stop, so the two directions that walk this row have nowhere else
    -- to land and leave the cursor where it is.
    menu.step({left = true})
    check("left of it is itself", menu.view().head_sel == "close",
          tostring(menu.view().head_sel))
    menu.step({right = true})
    check("and so is right of it", menu.view().head_sel == "close",
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
          menu.head_sel == nil and menu.sel.hangar == 1,
          tostring(menu.head_sel) .. "/" .. tostring(menu.sel.hangar))

    -- And the x shuts the panel, which is what a cross means everywhere.
    menu.open = true
    menu.stack = {"root", "hangar"}
    menu.sel = {hangar = 1}
    menu.head_sel = nil
    menu.step({up = true})
    menu.step({go = true})
    check("enter on the x shuts the panel", not menu.open,
          tostring(menu.open))
    menu.open = true

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

-- In a match the tab row is a shorter row: leave and settings, which is
-- everything a pilot can act on from a cockpit. The hangar is not on it,
-- because a hull is locked for the match and a three minute match is short
-- enough that browsing one costs a real fraction of it. Neither are the
-- games: the landing is where one is picked, and there is no landing behind a
-- fight you are flying in.
menu.home = false
menu.open = true
menu.stack = {"root"}
menu.sel = {}
local in_match = {}
for _, r in ipairs(menu.view().rail) do in_match[#in_match + 1] = r.label end
check("a match carries two tabs",
      #in_match == 2 and in_match[1] == "leave"
      and in_match[2] == "settings",
      table.concat(in_match, "/"))

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
      #between == 3 and between[1] == "ship", table.concat(between, "/"))

menu.click_rail(top_index("ship"))
check("and it can be walked into", menu.stack[2] == "hangar",
      table.concat(menu.stack, "/"))
net.match = {playing = true, left = 180, score = {}}
menu.tick(0.1)
check("the whistle puts a pilot back on the row",
      #menu.stack == 1, table.concat(menu.stack, "/"))
local playing = {}
for _, r in ipairs(menu.view().rail) do playing[#playing + 1] = r.label end
check("and takes the hangar off it", #playing == 2,
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

-- --- the call sign in the corner says who you are and nothing more ---------
--
-- It was a second door onto the pilot page, kept because the name says who
-- you are signed in as and a stop looks like a button. There is no page: the
-- account is a stop on the landing, and what the head keeps is the sentence
-- the button was also saying. See decision 99.

menu.home = true
menu.stack = {"root"}
menu.sel = {}
local v_head = menu.view()
check("the head still carries the call sign", v_head.pilot.name == menu.name,
      tostring(v_head.pilot ~= nil and v_head.pilot.name))
check("and the drawer has no page behind it",
      menu.click_pilot == nil and menu.pilot_hot == nil,
      "a way into the pilot page survives")

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
    if row.hull == 0 then landing_hull = landing_hull or i end
end
menu.click_stage(landing_hull)
check("a stage tap picks from the page it is on", menu.pending == 0,
      "asked for hull " .. tostring(menu.pending))

-- --- the ship page is the roster, one row a ship -------------------------
--
-- It was a grid of hulls with the kit of whichever one the cursor stood on
-- beside them, then a carousel showing one hull at a time with thirty points
-- being spent below it. Both existed to leave room for a kit, and there is no
-- kit: a hull is a whole ship, so the page is the roster read down a column
-- with the wake under it.

-- With a core installed, because a row's flight bars and the words for what
-- it carries are read off the class rather than written down here.
local was_ship_core = _G.sim
_G.sim = {
    -- Two hulls apart on every row, so the shares are not all 1.
    class_flight = function(cls)
        local k = (cls % 3) + 1
        return 1000 * k, 100 * k, 200 * k, 1500 * k, 900 * k
    end,
    class_kit = function(cls)
        local out = {}
        for i = 1, 23 do out[i] = 0 end
        -- One gun add-on and one charge, so `carried` has something to say.
        out[8] = (cls % 2) + 1
        out[20] = 2
        return out
    end,
    has_trigger = function(cls) return cls ~= 4 end,
}

menu.hull_at = nil
menu.stack = {"root"}
menu.sel = {}
menu.click_rail(ship_at)
local ship_page = menu.view()
local hull_rows, wake_row, watch_row = {}, nil, nil
for i, r in ipairs(ship_page.rows) do
    if r.group == "ships" and r.hull ~= nil then hull_rows[#hull_rows + 1] = i end
    if r.group == "ships" and r.figure == "pilot" then watch_row = i end
    if r.group == "flair" then wake_row = i end
end
local roster = #hull_rows
check("every hull the game has is a row of its own", roster >= 7,
      roster .. " hulls")
check("with sitting out as the last of them, and the wake under it",
      watch_row == roster + 1 and wake_row == roster + 2,
      tostring(watch_row) .. "/" .. tostring(wake_row))
-- The row is the reading: where the ship stands on the flight rows against
-- the rest of the roster, and what it flies with. Both are read off the core,
-- so with none installed they are empty rather than absent, and the page
-- draws the same shape either way.
local first = ship_page.rows[hull_rows[1]]
check("and a row carries the whole ship",
      type(first.bars) == "table" and #first.bars == 5
      and type(first.carries) == "table" and #first.carries > 0,
      tostring(first.bars and #first.bars) .. "/"
      .. tostring(first.carries and #first.carries))
-- The one hull with no rack says so, since a page that left the line out
-- would read as a page that forgot.
local rackless = 0
for _, i in ipairs(hull_rows) do
    if ship_page.rows[i].rack == false then rackless = rackless + 1 end
end
check("and a hull with no bomb rack is marked as one", rackless == 1,
      rackless .. " hulls without a rack")
_G.sim = was_ship_core
-- Nothing on the page is a ladder or a price, because nothing on it is bought.
local spends = false
for _, r in ipairs(ship_page.rows) do
    if r.price or r.arena_max then spends = true end
end
check("and nothing on it spends anything", not spends)
check("live, because there is no level above it left to preview from",
      ship_page.ships_preview == nil, tostring(ship_page.ships_preview))
-- And it keeps the head every other page has.
check("and the head over it is the one every page carries",
      ship_page.headless == nil, tostring(ship_page.headless))
check("with the cursor on the first ship rather than on a readout",
      ship_page.sel == hull_rows[1], "cursor " .. tostring(ship_page.sel))

-- Enter on a ship row asks for that ship. At home that is what you will
-- arrive in; in a game it is a request the room answers.
menu.sel.hangar = hull_rows[2]
menu.pending = nil
local picked = menu.step({go = true})
check("enter on a ship asks for it",
      picked == "ship" and menu.pending == 1,
      tostring(picked) .. ", asked for " .. tostring(menu.pending))
menu.sel.hangar = watch_row
menu.pending = nil
check("and the last row sits out instead",
      menu.step({go = true}) == "spectate")
menu.sel.hangar = hull_rows[1]

-- Up off the first row goes onto the head over the page, which is what up
-- means everywhere in this menu.
menu.stack = {"root", "hangar"}
menu.sel = {}
menu.head_sel = nil
menu.step({up = true})
check("up from the first row goes onto the head",
      menu.stack[2] == "hangar" and menu.view().head_sel == "close",
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
      peek.ships_preview == true and peek.sel == 0,
      tostring(peek.ships_preview) .. ", cursor " .. tostring(peek.sel))
check("flattened, not handed over as it was written",
      type(peek.rows[1].label) ~= "function")
-- The head stands over the preview and over the page alike, which is what
-- makes walking into the ship page from the rail a step rather than a jump:
-- the panel used to drop its own head the moment this page was entered.
check("and the head stays while it is only a preview",
      peek.headless == nil, tostring(peek.headless))
menu.stack, menu.sel, menu.home = was_stack, was_sel, was_home

-- On the home screen the same page answers a different tense: not what you
-- are, which is nothing, but what you will arrive as. So the lit row follows
-- the remembered choice there and the live connection in a game, and the two
-- are read through one question rather than by each caller checking `home`.
menu.home = true
menu.stack = {"root", "hangar"}
menu.sel = {}
menu.watching = false
menu.class = 2
menu.spectate = false
-- Which row wears the "you are here" light. A watcher is in no hull, so no
-- hull is lit at all and the last row carries it instead.
local function lit_at(index)
    for _, r in ipairs(menu.view().rows) do
        if r.index == index then return (r.choice or 0) > 0 end
    end
    return false
end
check("at home, no choice made yet lights the hull you will arrive in",
      lit_at(hull_rows[3]) and not lit_at(watch_row))
menu.spectate = true
check("and choosing to watch moves the light to the last row",
      lit_at(watch_row) and not lit_at(hull_rows[3]))
check("which is what the root row says too",
      menu.view().rail[top_index("ship")].detail == "spectating",
      tostring(menu.view().rail[top_index("ship")].detail))
-- In a game the connection is the truth, whatever was remembered: the server
-- can refuse a hull and the page must not claim you got it.
menu.home = false
check("in a game the connection wins over what was remembered",
      lit_at(hull_rows[3]) and not lit_at(watch_row),
      "spectate remembered but watching is false")
menu.spectate = false
menu.home = true

menu.home = false
menu.class = 2
menu.watching = false
check("flying lights the hull you are in",
      lit_at(hull_rows[3]) and not lit_at(watch_row))
menu.watching = true
check("watching lights the last row instead, and no hull",
      lit_at(watch_row) and not lit_at(hull_rows[3]))
menu.watching = false
menu.home = true
menu.class = 0
menu.hull_at = nil
menu.stack = {"root"}
menu.sel = {}

-- --- showing a level puts the cursor in the page -------------------------
--
-- `show` names a level and the stage takes the cursor when it does, which is
-- what a failed connection wants: the reason belongs next to the thing that
-- would fix it.

menu.hover_stage(nil)
menu.home = true
menu.show("hangar")
local opened = menu.view()
check("showing a level puts the cursor in the stage",
      opened.focus == "stage" and menu.at() == "hangar",
      tostring(opened.focus) .. " at " .. table.concat(menu.stack, "/"))
check("and on a row of it", opened.sel >= 1 and opened.rows[opened.sel] ~= nil,
      "row " .. tostring(opened.sel) .. " of " .. tostring(#opened.rows))
-- And the rail still says which page that is, since nothing else does now.
check("with the tab lit at the stop it belongs to",
      opened.rail[opened.rail_sel]
          and opened.rail[opened.rail_sel].label == "ship",
      "tabs on " .. tostring(opened.rail_sel))

-- --- escape opens on the tab row, and escape leaves ----------------------
--
-- The key that puts the panel up over a fight has to take it down again, from
-- wherever you have got to in it.
--
-- Over a game the cursor opens on the last stop, which is settings: the safe
-- action during a fight, and it keeps leave off the opening cursor now that
-- the two are neighbours. Opening straight onto the way out of your seat is
-- how an escape-then-enter costs somebody a match.

menu.home = false
menu.open = false
menu.toggle()
check("escape over a game opens on the tab row",
      menu.open and menu.at() == "root" and menu.view().focus == "rail",
      table.concat(menu.stack, "/"))
local opened_match = menu.view()
check("and starts on settings, not on the way out",
      opened_match.rail[opened_match.rail_sel]
          and opened_match.rail[opened_match.rail_sel].label == "settings",
      tostring(opened_match.rail_sel))

-- And it stays there while the row grows underneath it. A room names its sides
-- on the roster broadcast rather than in the join, so `side` can appear at the
-- head of the row a frame or two after the drawer went up. Written into
-- `menu.sel` as a number, the opening cursor would shuffle along one, and the
-- stop it would shuffle onto is the way out of the seat.
do
    local kept_teams = net.teams
    net.teams = {}
    menu.open = false
    menu.toggle()
    local before = menu.view()
    check("the drawer opens on settings before the sides land",
          before.rail[before.rail_sel]
              and before.rail[before.rail_sel].label == "settings",
          tostring(before.rail_sel))
    net.teams = {{team = 1, name = "Pylon", humans = 3, bots = 1},
                 {team = 2, name = "Caisson", humans = 4, bots = 0}}
    local after = menu.view()
    check("and is still on settings once they do",
          after.rail[after.rail_sel]
              and after.rail[after.rail_sel].label == "settings",
          (after.rail[after.rail_sel]
              and after.rail[after.rail_sel].label or "?")
              .. " of " .. tostring(#after.rail))
    net.teams = kept_teams
    menu.stack, menu.sel = {"root"}, {}
end

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

-- --- the card that asks before it costs you something ---------------------
--
-- Raised by the acts that cannot be taken back, and leaving the room is one:
-- it costs the match. The card owns the keys while it is up, the answer that
-- changes nothing sits under the cursor, and escape answers it with that one
-- rather than shutting the panel.
--
-- The games list raised the same card, for a press on a game other than the
-- one you were flying. Picking a game is the landing's now, and it has no
-- match to cost: nothing is joined until PLAY NOW is pressed.

menu.hover_stage(nil)
menu.open = true
menu.home = false
-- Benched, where the leave stop is the way out of the room rather than the
-- way out of a seat. Handing a seat back costs nothing, so it never asks.
menu.watching = true
menu.zone = "chaos"
menu.ask = nil
menu.stack, menu.sel = {"root"}, {root = top_index("leave")}
local act5 = menu.step({go = true})
check("leaving the room asks before it takes the match",
      act5 == nil and menu.ask ~= nil, tostring(act5))
check("with the answer that changes nothing under the cursor",
      menu.ask.sel == #menu.ask.keys and menu.ask.keys[menu.ask.sel].act == nil,
      "on " .. tostring(menu.ask.sel) .. " of " .. tostring(#menu.ask.keys))
check("and the view carries it", menu.view().ask == menu.ask)

-- The question owns the keys while it is up. Anything else and the row walks
-- under a card that is asking about the stop it walked off.
local before = menu.sel.root
menu.step({down = true})
check("the row underneath cannot be walked", menu.sel.root == before,
      tostring(before) .. " -> " .. tostring(menu.sel.root))
-- Down moved between the answers instead. The answers sit side by side, so
-- left and right are what they are laid out along, but a hand that has been
-- walking a list all the way here reaches for down first.
check("the arrows move between the answers, whichever pair", menu.ask.sel == 1,
      "on " .. tostring(menu.ask.sel))

check("the card offers leaving and staying, nothing else",
      #menu.ask.keys == 2 and menu.ask.keys[1].act == "leave",
      #menu.ask.keys .. " answers, first is "
          .. tostring(menu.ask.keys[1].act))
menu.ask.sel = 2
menu.step({left = true})
check("left moves to the answer beside it", menu.ask.sel == 1,
      "on " .. tostring(menu.ask.sel))
local act6 = menu.step({go = true})
check("and the answer that leaves is a leave",
      act6 == "leave" and menu.ask == nil, tostring(act6))

-- Escape answers it rather than shutting the panel, and answers it with the
-- one that changes nothing: the key that gets out of everything else in here
-- has to get out of this without leaving the game by accident.
menu.sel = {root = top_index("leave")}
menu.step({go = true})
local act4, moved4 = menu.step({back = true})
check("escape answers the question instead of shutting the menu",
      act4 == nil and moved4 and menu.ask == nil and menu.open,
      tostring(act4) .. ", open " .. tostring(menu.open))

-- Flying, the same stop hands the seat back, which costs nothing that cannot
-- be taken again: the corner's TAKE SEAT is right there. So it does not ask.
menu.watching = false
menu.ask = nil
menu.sel = {root = top_index("leave")}
local act7 = menu.step({go = true})
check("handing a seat back does not ask",
      act7 == "leave_seat" and menu.ask == nil, tostring(act7))
menu.home = true
menu.scenery = false
menu.open = true

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
-- The acts stand on the landing's account stop rather than on a page of the
-- drawer. What they do is unchanged: these are the same act names the pilot
-- page's rows carried, run by the arena when a row of that list is pressed.
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

account_act("sign up")
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
account_act("log in")
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

-- --- signed in, the list changes shape ------------------------------------

account.claimed = true
menu.stack = {"root"}
menu.sel = {}
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

-- Without a meta-layer there is nothing to sign up to, so the list is the
-- one act that has an offline answer of its own.
do
    local kept = account.base
    account.base = ""
    check("with no account layer the list is the reroll alone",
          account_labels() == "new name", account_labels())
    account.base = kept
end

-- --- and the one act on that list that throws something away -------------
--
-- A call sign is the only name anybody here has, and it is the name on the
-- scoreboard of every game this pilot has flown. The row showed it and
-- replaced it on the press, with nothing said and nothing to say no to.

menu.zone = ""
menu.chosen = nil
menu.ask = nil
menu.stack = {"root"}
menu.sel = {}
local was = menu.name
local act8 = account_act("new name")
check("rolling a call sign asks first",
      act8 == nil and menu.ask ~= nil and menu.name == was,
      tostring(act8) .. ", name " .. tostring(menu.name))
-- At home the card asks only about the name; there is no ship to cost.
check("and at home says nothing about respawning",
      not string.find(menu.ask.head, "respawns"), menu.ask.head)
menu.step({back = true})
check("and escape keeps the one you have",
      menu.name == was and menu.ask == nil, tostring(menu.name))
account_act("new name")
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

menu.ask = nil
menu.stack = {"root"}
menu.sel = {}

-- --- mid-game, the same card owes one more sentence -------------------------
--
-- A new name is a new pilot, and a new pilot gets a fresh seat: the client
-- rejoins the game on its own, which costs the ship. The card is the one
-- place that can say so before it happens, and this is the row whose whole
-- design is asking first.

-- The card knows the difference, because `home` is what it asks and a pilot
-- can be connected with the stands behind them.
menu.stack = {"root"}
menu.sel = {}
menu.home = false
account_act("new name")
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
    for _, page in ipairs({"play", "hangar", "settings", "pilot"}) do
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

-- --- which key throws which charge ---------------------------------------
--
-- A hull that carries two kinds of charge leaves one thing for the pilot to
-- decide: which of the two keys spends which. The core numbers the kinds and
-- the profile carries counts by kind, so without a preference the first key
-- always throws the lower-numbered one, whatever the pilot would rather have.
--
-- It was a box on the charge's own row, back when the ship page was a kit
-- being built. It is a flair row now, beside the wake, and it is the one
-- thing that page carried which is still a pilot's to choose.

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
    menu.stack = {"root", "hangar"}
    menu.sel = {}

    local function keys_row()
        for _, r in ipairs(menu.view().rows) do
            if r.act == "swap_charges" then return r end
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
    menu.stack = {"root"}
    menu.sel = {}
    _G.sim = kept_core
end

-- --- the sides stop, which is the one page that arrives over the wire ------
--
-- A room says what sides it has, and until it does there are none to stand on.
-- The stop hides itself until they land, so the rail and the page agree inside
-- one frame; `enterable` is the belt to that, and what is checked here is the
-- half a player meets: the sides are reachable exactly when there are sides.
--
-- The games list was the page this guard was written for, and picking a game
-- is the landing's now.

do
    local kept_teams, kept_mine = net.teams, net.my_team
    local kept_home, kept_watching = menu.home, menu.watching
    menu.home, menu.watching = false, true
    menu.stack = {"root"}
    menu.sel = {}
    menu.corner_sel = nil

    net.teams = {}
    check("a room that has not named its sides carries no side stop",
          top_index("side") == nil,
          table.concat((function()
              local t = {}
              for _, r in ipairs(menu.view().rail) do t[#t + 1] = r.label end
              return t
          end)(), "/"))

    net.teams = {{team = 1, name = "Pylon", humans = 3, bots = 1},
                 {team = 2, name = "Caisson", humans = 4, bots = 0}}
    net.my_team = 1
    local side_at = top_index("side")
    check("and one that has names it first on the row", side_at == 1,
          tostring(side_at))
    menu.sel.root = side_at
    menu.step({down = true})
    check("which walks into the sides", menu.at() == "teams",
          table.concat(menu.stack, "/"))
    check("and they are the room's own, in the room's words",
          menu.view().rows[1] and menu.view().rows[1].label == "Pylon",
          table.concat(texts_of(menu.view()), ", "))

    net.teams, net.my_team = kept_teams, kept_mine
    menu.home, menu.watching = kept_home, kept_watching
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

    -- The tab set follows the cockpit, not the zone. No games on any of them:
    -- the landing's zone stop is the list, and there is no landing behind a
    -- room you are in.
    local function labels()
        local out = {}
        for _, r in ipairs(menu.view().rail) do out[#out + 1] = r.label end
        return table.concat(out, " ")
    end

    menu.home, menu.scenery, menu.watching = true, true, false
    menu.open, menu.stack, menu.sel = true, {"root"}, {}
    check("the stands carry the ship and settings",
          labels() == "ship settings",
          labels())

    -- Flying: the hangar goes, because a hull is locked for the match, and
    -- what is left is the way out of the seat and the machine.
    menu.home, menu.watching = false, false
    check("a pilot in a hull gets the short one",
          labels() == "leave settings", labels())

    -- A pilot the room benched is in the stands too: same empty cockpit, same
    -- time to read, so the hangar comes back. What they keep that the landing
    -- does not is `leave`: they are in a zone, and the stands are what leaving
    -- goes back to. What they lose is `pilot`, which needs there to be no
    -- zone: an account is not edited from inside a room. The two share the
    -- slot before settings, so `leave` arrives where `pilot` went.
    menu.home, menu.watching = false, true
    check("a benched pilot gets the hangar back",
          labels() == "ship leave settings",
          labels())

    -- And the thing all three rows agree on: settings closes every one of
    -- them. It is the least pressed stop on the row and the only one that is
    -- not part of the game, which is the place a phone's own tab bar has
    -- already taught its owner to look. A stop appended after it walks that
    -- back without anybody deciding to, which is how it ended up fourth of
    -- five in the first place: `pilot` was tacked on the end of a row that
    -- already finished with settings. See decision 83.
    for _, state in ipairs({{home = true, watching = false},
                            {home = false, watching = false},
                            {home = false, watching = true}}) do
        menu.home, menu.watching = state.home, state.watching
        local row = menu.view().rail
        check("settings is the last stop with home " .. tostring(state.home)
              .. " and watching " .. tostring(state.watching),
              row[#row].label == "settings", labels())
    end

    menu.home, menu.scenery, menu.watching = kept.home, kept.scenery,
                                             kept.watching
    menu.open, menu.stack, menu.sel = kept.open, kept.stack, kept.sel
end

-- --- the guest banner arms only when there is something to lose ----------
do
    local kept = {claimed = account.claimed, career = account.career,
                  home = menu.home, stack = menu.stack, sel = menu.sel}
    menu.open, menu.home = true, true
    menu.stack, menu.sel = {"root"}, {}
    account.claimed = false
    account.career = nil
    check("a fresh guest gets no banner and no dot",
          menu.view().banner ~= true and menu.guest_stakes() == false)
    account.career = {games = 1, kills = 0, deaths = 1}
    check("a rated game flown arms the banner",
          menu.view().banner == true and menu.guest_stakes() == true)
    -- It used to stand down on the page it pointed at. There is no such
    -- page: the band raises the card itself, and the same warning rides the
    -- landing's account stop as a dot. See decision 99.
    menu.stack = {"root", "settings"}
    check("and stands on every page the drawer has left",
          menu.view().banner == true, tostring(menu.view().banner))
    menu.stack = {"root"}
    menu.home = false
    check("and not away from home, where an account is not edited",
          menu.view().banner ~= true)
    menu.home = true
    account.claimed = true
    check("signing up takes it down",
          menu.view().banner ~= true and menu.view().guest_dot ~= true)
    account.claimed, account.career = kept.claimed, kept.career
    menu.home, menu.stack, menu.sel = kept.home, kept.stack, kept.sel
end

-- --- and a guest's career is re-asked until there is one -------------------
--
-- The figure the warning arms on is rated games, and a guest's first one is
-- filed while they are flying: the copy fetched when the session woke says
-- none for the whole of the session the game was flown in. So the panel asks
-- again while the answer is still nothing, and stops the moment it is not.
do
    local kept = {claimed = account.claimed,
                  career = account.career, asked = account.asked_career,
                  stack = menu.stack, sel = menu.sel}
    menu.open, menu.stack, menu.sel = true, {"root"}, {}
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
    menu.stack, menu.sel = kept.stack, kept.sel
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
    local roster_page = menu.view()
    local landed = menu.sel.hangar
    check("down into ship lands on the first ship of the roster",
          menu.at() == "hangar" and landed == 1
          and roster_page.rows[1] ~= nil
          and roster_page.rows[1].group == "ships",
          tostring(landed) .. "/"
          .. tostring(roster_page.rows[landed]
                      and roster_page.rows[landed].group))

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
