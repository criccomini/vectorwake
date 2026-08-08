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
local account = {
    status = function() return "flying as a guest" end,
    key = "", name = "", claim = function() end, aim = function() end,
    claimed = true, base = "https://meta", link_code = "",
}
account.redeemed = nil
function account.redeem_key(key, cb)
    account.redeemed = key
    if cb then cb(key == "VW7KQ4M2XP9BHT") end
end
function account.link(cb)
    account.link_code = "408317"
    if cb then cb(true) end
end
package.loaded["arena.account"] = account
package.loaded["arena.net"] = {
    teams = {}, my_team = 0, may_found = false,
    my_team_name = function() return "" end,
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

-- The stop you are already standing in. On a phone the rail is the whole of
-- the navigation and there is nothing outside the panel to press, so tapping
-- the lit stop is the way back into the game. Re-entering the page you are
-- already reading is the only other thing it could mean, and that is nothing.
menu.click_rail(ship_at)
check("the lit stop with nothing behind the panel stays put",
      menu.open and menu.stack[2] == "ship", table.concat(menu.stack, "/"))

menu.home = false
menu.click_rail(ship_at)
check("the lit stop over a game is the way back to it", not menu.open)

-- At the root the same stop is lit while the stage is only previewing it, so
-- a tap there goes in, which is what it has always done.
menu.open = true
menu.stack = {"root"}
menu.sel = {}
menu.click_rail(ship_at)
check("the lit stop at the root still goes in",
      menu.open and menu.stack[2] == "ship", table.concat(menu.stack, "/"))
menu.home = true
menu.stack = {"root"}
menu.sel = {}

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

-- Sitting out is the ninth cell of this page rather than an answer on some
-- card elsewhere, so it is picked the same way a hull is: move to it, press
-- enter, and the action names itself. What it must not do is come back as a
-- hull change, which would fly you in ship number eight.
-- On both screens, because on the home screen this page is what you will
-- arrive as and arriving to watch is a thing the wire can say. It is the same
-- page and the same nine answers whether or not there is a game behind it.
check("the cell is there with nothing behind the panel",
      #menu.view().rows == 9, tostring(#menu.view().rows))

menu.home = false
local ship_rows = menu.view().rows
check("and there with a game", #ship_rows == 9, tostring(#ship_rows))
menu.sel.ship = 9
local act_w = menu.step({go = true})
check("the ninth cell asks to spectate", act_w == "spectate",
      tostring(act_w))
check("and it is not a hull", ship_rows[9].hull == nil,
      tostring(ship_rows[9].hull))
-- A cell with no hull and no figure falls back to hull zero and draws an
-- Apex, which is what this one did until `figure` was carried through the
-- view. The drawing reads this field; nothing else can say what it gets.
check("so it says what to draw instead", ship_rows[9].figure == "pilot",
      tostring(ship_rows[9].figure))

-- The same cell, seen from the rail. The stage previews the page a rail stop
-- leads to before you go in, and that preview flattens rows down its own
-- path, so a field the grid reads has to survive both. `figure` survived only
-- one: escape into the menu and arrow left onto the rail, and the ninth cell
-- was an Apex; step into the page and it was the helmet again.
local was_stack, was_sel = menu.stack, menu.sel
menu.stack = {"root"}
menu.sel = {root = ship_at}
local peek = menu.view()
check("the rail previews the page it points at",
      #peek.rows == 9 and peek.sel == 0,
      #peek.rows .. " rows, cursor " .. tostring(peek.sel))
check("flattened, not handed over as it was written",
      type(peek.rows[9].mark) ~= "function")
check("and the ninth cell is a pilot there too",
      peek.rows[9].figure == "pilot", tostring(peek.rows[9].figure))
menu.stack, menu.sel = was_stack, was_sel

-- On the home screen the same page answers a different tense: not what you
-- are, which is nothing, but what you will arrive as. So the wash follows the
-- remembered choice there and the live connection in a game, and the two are
-- read through one question rather than by each caller checking `home`.
menu.home = true
menu.watching = false
menu.class = 2
menu.spectate = false
check("at home, no choice made yet marks the hull you will arrive in",
      menu.view().rows[3].mark and not menu.view().rows[9].mark)
menu.spectate = true
check("and choosing to watch moves the wash to the ninth",
      menu.view().rows[9].mark and not menu.view().rows[3].mark)
check("which is what the root row says too",
      menu.view().rail[2].detail == "spectating",
      tostring(menu.view().rail[2].detail))
-- In a game the connection is the truth, whatever was remembered: the server
-- can refuse a hull and the page must not claim you got it.
menu.home = false
check("in a game the connection wins over what was remembered",
      menu.view().rows[3].mark and not menu.view().rows[9].mark,
      "spectate remembered but watching is false")
menu.spectate = false
menu.home = true

-- Which cell wears the "you are here" wash follows the connection, not the
-- last hull picked: a watcher is in no hull, so none of the eight is marked.
-- Read off a fresh view each time, since that is where a mark stops being a
-- question and becomes an answer.
menu.home = false
menu.class = 2
menu.watching = false
local flying_view = menu.view().rows
check("flying marks the hull you are in",
      flying_view[3].mark and not flying_view[9].mark,
      tostring(flying_view[3].mark) .. "/" .. tostring(flying_view[9].mark))
menu.watching = true
local watching_view = menu.view().rows
check("watching marks the ninth instead, and no hull",
      watching_view[9].mark and not watching_view[3].mark,
      tostring(watching_view[3].mark) .. "/" .. tostring(watching_view[9].mark))
menu.watching = false

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
-- Nine cells, not eight: the page carries the eight hulls and the answer
-- "none of them, I am watching", so the wrap runs through nine.
menu.sel.ship = 3
menu.step({up = true})
check("up from the top row is the bottom row, same column",
      menu.sel.ship == 8, "cursor " .. tostring(menu.sel.ship))
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
      act2 == nil and menu.ask ~= nil,
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

-- --- a key is typed into the card, twelve slots and nothing else ---------
--
-- The only text entry in this client, and it exists for one string. What fills
-- the slots is a keyboard, a clipboard, or the alphabet drawn under them; all
-- three arrive here, so all three are filtered here.

menu.hover_stage(nil)
menu.ask = nil
menu.home = true
menu.stack = {"root"}
menu.sel = {}
menu.ask_key()
check("the card asks for a key with empty slots",
      menu.ask ~= nil and menu.ask.entry ~= nil
          and menu.ask.entry.typed == "" and menu.ask.entry.n == 12,
      tostring(menu.ask and menu.ask.entry and menu.ask.entry.typed))

check("a letter of the alphabet lands in a slot", menu.type_key("7")
          and menu.ask.entry.typed == "7", menu.ask.entry.typed)
-- Lowercase is the same letter: nobody types a key twice to find that out.
check("and lower case is the same letter", menu.type_key("k")
          and menu.ask.entry.typed == "7K", menu.ask.entry.typed)
-- The four letters the alphabet drops are dropped rather than shown wrong.
check("a letter that is not in the alphabet is refused",
      menu.type_key("I") == false and menu.type_key("-") == false
          and menu.ask.entry.typed == "7K", menu.ask.entry.typed)
check("backspace takes one back",
      menu.rub_key() and menu.ask.entry.typed == "7", menu.ask.entry.typed)
check("and stops at empty", menu.rub_key() and menu.rub_key() == false,
      menu.ask.entry.typed)

-- Pressing paste is a hand reaching past the words rather than an answer, so
-- the card has to still be there when the clipboard comes back.
menu.ask_key()
menu.ask.keys[#menu.ask.keys + 1] = {label = "paste", act = "paste"}
local act_p = menu.click_answer(#menu.ask.keys)
check("pressing paste leaves the card up",
      act_p == "pasting" and menu.ask ~= nil and menu.ask.entry ~= nil,
      tostring(act_p) .. ", ask " .. tostring(menu.ask))

-- A paste carries whatever was on the clipboard, which is usually the whole
-- line: prefix, dashes and all.
menu.paste_key("vw-7kq4-m2xp-9bht")
check("a paste fills the slots and sends the key",
      account.redeemed == "VW7KQ4M2XP9BHT" and menu.ask == nil,
      tostring(account.redeemed) .. ", ask " .. tostring(menu.ask))

-- Twelve typed characters send themselves; there is no key to press.
account.redeemed = nil
menu.ask_key()
for ch in string.gmatch("7KQ4M2XP9BHZ", ".") do menu.type_key(ch) end
check("twelve typed characters send themselves",
      account.redeemed == "VW7KQ4M2XP9BHZ", tostring(account.redeemed))
check("and a key the server refuses empties the slots and stays up",
      menu.ask ~= nil and menu.ask.entry.typed == "",
      tostring(menu.ask and menu.ask.entry.typed))
menu.ask = nil

-- --- the device code is a card, and answering it never takes the code away -
--
-- The code is live for ten minutes whatever this screen is showing. Answering
-- the card that carries it is somebody saying they have read it, not somebody
-- giving it back, and a player who dismissed it and walked to the other
-- machine should not have to come back and make a second one.

menu.hover_stage(nil)
menu.ask = nil
menu.home = true
menu.stack = {"root"}
menu.sel = {}
menu.click_rail(top_index("pilot"))
local rows_before = #menu.view().rows
menu.sel.pilot = rows_before          -- "add a device", the last row
local act_link = menu.step({go = true})
check("pressing add a device puts the code on a card",
      act_link == nil and menu.ask ~= nil
          and menu.ask.code == account.link_code,
      tostring(act_link) .. ", code " .. tostring(menu.ask and menu.ask.code))
check("and the card has one answer", #menu.ask.keys == 1,
      tostring(#menu.ask.keys))

menu.step({go = true})
check("answering it takes the card down and leaves the code alone",
      menu.ask == nil and account.link_code == "408317",
      "code " .. tostring(account.link_code))

-- And the row that holds it opens the card again, since the whole point of
-- keeping the code is being able to look at it.
local v_code = menu.view()
local code_row
for i, r in ipairs(v_code.rows) do
    if r.label == "code" then code_row = i end
end
check("the code has a row of its own", code_row ~= nil,
      table.concat(texts_of(v_code), ", "))
menu.sel.pilot = code_row
menu.step({go = true})
check("and pressing it shows the code again",
      menu.ask ~= nil and menu.ask.code == "408317",
      tostring(menu.ask and menu.ask.code))
menu.ask = nil
account.link_code = ""

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
menu.click_rail(top_index("pilot"))
local was = menu.name
local act8 = menu.step({go = true})
check("rolling a call sign asks first",
      act8 == nil and menu.ask ~= nil and menu.name == was,
      tostring(act8) .. ", name " .. tostring(menu.name))
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

menu.ask = nil
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
