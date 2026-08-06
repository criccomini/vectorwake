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

-- The world the menu talks to, as little of it as it asks for.
package.loaded["arena.account"] = {
    status = function() return "flying as a guest" end,
    key = "", name = "", claim = function() end, aim = function() end,
}
package.loaded["arena.net"] = {
    teams = {}, my_team = 0, may_found = false,
    my_team_name = function() return "" end,
    protocol = 5, invite = function() end,
}
package.loaded["arena.callsign"] = {roll = function() return "Probe 1" end}
package.loaded["arena.directory"] = {
    rows = {{zone = "chaos", name = "chaos", detail = "a brawl",
             count = "0 playing", players = 0, bots = 51, live = true}},
    note = "", tick = function() end, aim = function() end,
    pilot_name = "",
}
package.loaded["arena.sfx"] = {ui = function() end, master_gain = function() end,
                               music_gain = function() end}
_G.sys = {get_config_string = function(_, d) return d end,
          get_config_int = function(_, d) return d end,
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
check("the rail carries the destinations", ship_at and settings_at,
      "ship " .. tostring(ship_at) .. ", settings " .. tostring(settings_at))

menu.click_rail(ship_at)
check("a rail tap goes in", menu.stack[2] == "ship",
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
check("and again, the other way", menu.stack[2] == "ship",
      table.concat(menu.stack, "/"))

-- --- a tap on a row is still a tap on a row -------------------------------

menu.stack = {"root"}
menu.sel = {}
menu.click_rail(ship_at)
menu.click_stage(3)
check("a stage tap picks from the page it is on", menu.pending == 2,
      "asked for hull " .. tostring(menu.pending))

-- --- the hulls are a grid, and its arrows mean what a grid's arrows mean ---
--
-- Right is enter everywhere else, which is what a one-column list wants and
-- exactly wrong on a page laid out in four: pressing right to look at the
-- hull beside this one flew it instead, and down, which should have gone to
-- the row below, went one ship along.

menu.stack = {"root"}
menu.sel = {}
menu.cols = 4
menu.click_rail(ship_at)
menu.pending = nil
menu.step({right = true})
check("right in the grid moves rather than picks",
      menu.sel.ship == 2 and menu.pending == nil,
      "cursor " .. tostring(menu.sel.ship) .. ", asked for "
          .. tostring(menu.pending))
menu.step({down = true})
check("down goes to the row below, not one to the right",
      menu.sel.ship == 6, "cursor " .. tostring(menu.sel.ship))
menu.step({up = true})
check("and up comes back", menu.sel.ship == 2,
      "cursor " .. tostring(menu.sel.ship))
local act = menu.step({go = true})
check("enter is the only thing that picks",
      act == "ship" and menu.pending == 1,
      tostring(act) .. ", asked for " .. tostring(menu.pending))

-- The edges wrap, so nothing on the page is out of reach in one press and an
-- arrow never does nothing, which is what right at the last column did.
menu.sel.ship = 6
menu.step({left = true})
check("left inside the grid moves", menu.sel.ship == 5 and menu.stack[2] == "ship",
      "cursor " .. tostring(menu.sel.ship) .. " at "
          .. table.concat(menu.stack, "/"))
menu.sel.ship = 8
menu.step({right = true})
check("right off the last column comes back to the first",
      menu.sel.ship == 5, "cursor " .. tostring(menu.sel.ship))
menu.sel.ship = 3
menu.step({up = true})
check("up from the top row is the bottom row, same column",
      menu.sel.ship == 7, "cursor " .. tostring(menu.sel.ship))
menu.step({down = true})
check("and down from the bottom is the top again", menu.sel.ship == 3,
      "cursor " .. tostring(menu.sel.ship))

-- Left off the first column is the one edge that does not wrap. It is the way
-- back to the rail, and wrapped round to the far end of the row it shut the
-- page on anybody holding nothing but the arrows.
menu.sel.ship = 5
menu.step({left = true})
check("and left off the first column is the way out", menu.stack[2] == nil,
      table.concat(menu.stack, "/"))

-- --- the client opens on the games, with the cursor in the list -----------
--
-- Startup shows the zones page rather than the root, so somebody who has just
-- loaded the client is looking at the list of games with the cursor in it and
-- one press from flying. What that rests on is `show` naming a level and the
-- stage taking the cursor when it does.

menu.hover_stage(nil)
menu.home = true
menu.show("zones")
local opened = menu.view()
check("showing a level puts the cursor in the stage",
      opened.focus == "stage" and menu.at() == "zones",
      tostring(opened.focus) .. " at " .. table.concat(menu.stack, "/"))
check("and on a row of it", opened.sel >= 1 and opened.rows[opened.sel] ~= nil,
      "row " .. tostring(opened.sel) .. " of " .. tostring(#opened.rows))
-- And the rail still says which page that is, since nothing else does now.
check("with the rail lit at the stop it belongs to",
      opened.rail[opened.rail_sel]
          and opened.rail[opened.rail_sel].label == "zones",
      "rail on " .. tostring(opened.rail_sel))

-- --- escape opens on the games, and escape leaves ------------------------
--
-- The key that puts the panel up over a fight has to take it down again, from
-- wherever you have got to in it. It opens one level in now, so walking back
-- out a level at a time would have made leaving cost three presses where it
-- used to cost two.

menu.home = false
menu.open = false
menu.toggle()
check("escape over a game opens on the games",
      menu.open and menu.at() == "zones" and menu.view().focus == "stage",
      table.concat(menu.stack, "/"))
menu.click_rail(settings_at)
check("and the rail still goes where it says", menu.at() == "settings",
      table.concat(menu.stack, "/"))
menu.step({back = true})
check("escape from a page inside it puts the fight back", not menu.open,
      "still open at " .. table.concat(menu.stack, "/"))

-- With nothing behind the panel there is nothing to shut it onto, so escape
-- walks back a level and the menu stays up.
menu.home = true
menu.open = true
menu.show("ship")
menu.step({back = true})
check("and with no game behind it, escape walks back instead",
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
menu.show("zones")
local zones = menu.view()
check("nothing at the foot of the list leaves the game",
      #zones.rows == 1 and zones.rows[1].label == "chaos",
      table.concat(texts_of(zones), ", "))

local act2 = menu.step({go = true})
check("enter on the game you are in asks instead of joining",
      act2 == nil and menu.ask ~= nil and menu.chosen == nil,
      tostring(act2) .. ", ask " .. tostring(menu.ask))
check("with the answer that changes nothing under the cursor",
      menu.ask.sel == #menu.ask.keys and menu.ask.keys[menu.ask.sel].act == nil,
      "on " .. tostring(menu.ask.sel) .. " of " .. tostring(#menu.ask.keys))
check("and the view carries it", menu.view().ask == menu.ask)

-- The question owns the keys while it is up. Anything else and the list walks
-- under a card that is asking about the row it walked off.
local before = menu.sel.zones
menu.step({down = true})
check("the list underneath cannot be walked", menu.sel.zones == before,
      tostring(before) .. " -> " .. tostring(menu.sel.zones))
-- Down moved between the answers instead. The answers sit side by side, so
-- left and right are what they are laid out along, but a hand that has been
-- walking a list all the way here reaches for down first.
check("the arrows move between the answers, whichever pair", menu.ask.sel == 1,
      "on " .. tostring(menu.ask.sel))

menu.ask.sel = 2
menu.step({left = true})
check("left moves to the other answer", menu.ask.sel == 1,
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

-- And a different game is still a join.
menu.zone = "elsewhere"
local act5 = menu.step({go = true})
check("any other game is still a join",
      act5 == "join" and menu.ask == nil and menu.chosen ~= nil,
      tostring(act5))
menu.zone = ""
menu.chosen = nil
menu.home = true
menu.stack = {"root"}
menu.sel = {}

-- --- a pointer resting on a row is the same cursor the arrows move --------

menu.stack = {"root"}
menu.sel = {}
menu.hover_stage(nil)
menu.click_rail(ship_at)
check("a hover moves the cursor", menu.hover_stage(4) and menu.sel.ship == 4,
      "cursor " .. tostring(menu.sel.ship))
check("and resting on the same row says nothing more",
      menu.hover_stage(4) == false)
-- A pointer left lying on a row must not put the cursor back on it, or the
-- arrows could never leave the row the mouse happens to be over.
menu.step({down = true})
check("and does not hold the arrows to it", menu.sel.ship == 8,
      "cursor " .. tostring(menu.sel.ship))

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

-- --- what the view says about the window does not depend on the page -----
--
-- `home` decides where the whole block is measured from: clear of the corner
-- stack over an arena, centred over the starfield. It used to be
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

-- --- and the rail is reachable from the root, which is where it started ---

menu.stack = {"root"}
menu.sel = {}
local help_at = top_index("help")
menu.click_rail(help_at)
check("every stop is reachable", menu.stack[2] == "help",
      table.concat(menu.stack, "/"))

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
