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

-- Sitting out is the last cell of this page rather than an answer on some
-- card elsewhere, so it is picked the same way a hull is: move to it, press
-- enter, and the action names itself. What it must not do is come back as a
-- hull change, which would fly you in a ship one past the end of the roster.
-- On both screens, because on the home screen this page is what you will
-- arrive as and arriving to watch is a thing the wire can say. It is the same
-- page and the same answers whether or not there is a game behind it.
--
-- Counted off the roster rather than written out, so a hull leaving the game
-- moves this without anybody having to remember it is here.
local rows0 = menu.view().rows
local hulls0 = 0
for _, r in ipairs(rows0) do if r.hull then hulls0 = hulls0 + 1 end end
local CELLS = #rows0
check("the cell is there with nothing behind the panel",
      hulls0 > 0 and CELLS == hulls0 + 1,
      CELLS .. " rows over " .. hulls0 .. " hulls")

menu.home = false
local ship_rows = menu.view().rows
check("and there with a game", #ship_rows == CELLS, tostring(#ship_rows))
menu.sel.ship = CELLS
local act_w = menu.step({go = true})
check("the last cell asks to spectate", act_w == "spectate",
      tostring(act_w))
check("and it is not a hull", ship_rows[CELLS].hull == nil,
      tostring(ship_rows[CELLS].hull))
-- A cell with no hull and no figure falls back to hull zero and draws an
-- Apex, which is what this one did until `figure` was carried through the
-- view. The drawing reads this field; nothing else can say what it gets.
check("so it says what to draw instead", ship_rows[CELLS].figure == "pilot",
      tostring(ship_rows[CELLS].figure))

-- The same cell, seen from the rail. The stage previews the page a rail stop
-- leads to before you go in, and that preview flattens rows down its own
-- path, so a field the grid reads has to survive both. `figure` survived only
-- one: escape into the menu and arrow left onto the rail, and the last cell
-- was an Apex; step into the page and it was the helmet again.
local was_stack, was_sel = menu.stack, menu.sel
menu.stack = {"root"}
menu.sel = {root = ship_at}
local peek = menu.view()
check("the rail previews the page it points at",
      #peek.rows == CELLS and peek.sel == 0,
      #peek.rows .. " rows, cursor " .. tostring(peek.sel))
check("flattened, not handed over as it was written",
      type(peek.rows[CELLS].mark) ~= "function")
check("and the last cell is a pilot there too",
      peek.rows[CELLS].figure == "pilot", tostring(peek.rows[CELLS].figure))
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
      menu.view().rows[3].mark and not menu.view().rows[CELLS].mark)
menu.spectate = true
check("and choosing to watch moves the wash to the last cell",
      menu.view().rows[CELLS].mark and not menu.view().rows[3].mark)
check("which is what the root row says too",
      menu.view().rail[2].detail == "spectating",
      tostring(menu.view().rail[2].detail))
-- In a game the connection is the truth, whatever was remembered: the server
-- can refuse a hull and the page must not claim you got it.
menu.home = false
check("in a game the connection wins over what was remembered",
      menu.view().rows[3].mark and not menu.view().rows[CELLS].mark,
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
local flying_view = menu.view().rows
check("flying marks the hull you are in",
      flying_view[3].mark and not flying_view[CELLS].mark,
      tostring(flying_view[3].mark) .. "/" .. tostring(flying_view[CELLS].mark))
menu.watching = true
local watching_view = menu.view().rows
check("watching marks the last cell instead, and no hull",
      watching_view[CELLS].mark and not watching_view[3].mark,
      tostring(watching_view[3].mark) .. "/" .. tostring(watching_view[CELLS].mark))
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
-- The page carries every hull and the answer "none of them, I am watching",
-- so the wrap runs through one more cell than there are ships. Checked as
-- the property rather than as the cell it lands on: a number worked out here
-- from the column count and the roster is the implementation written twice,
-- and it would agree with a broken one.
menu.sel.ship = 3
menu.step({up = true})
local landed = menu.sel.ship
check("up from the top row is the bottom row, same column",
      landed > CELLS - menu.cols
        and (landed - 1) % menu.cols == (3 - 1) % menu.cols,
      "cursor " .. tostring(landed) .. " of " .. CELLS
          .. " over " .. menu.cols .. " columns")
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
menu.click_rail(top_index("pilot"))
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
menu.click_rail(top_index("pilot"))
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
menu.click_rail(top_index("pilot"))
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

-- --- and the rail takes a pointer the same way ----------------------------
--
-- The same rule read the other way round: a hover is always drawn, and it
-- moves the cursor only where the cursor lives. The cursor lives in the rail
-- at the root and in the stage everywhere below it, so resting on a stop at
-- the root walks the rail exactly as the arrows do, and resting on one from
-- inside a page lights it without disturbing the list being read.

menu.stack = {"root"}
menu.sel = {}
menu.hover_stage(nil)
menu.hover_rail(nil)
check("a hover at the root walks the rail",
      menu.hover_rail(ship_at) and menu.sel.root == ship_at,
      "cursor " .. tostring(menu.sel.root))
check("and the stage follows it, the way the arrows make it",
      menu.view().rail_sel == ship_at, tostring(menu.view().rail_sel))
check("resting on the same stop says nothing more",
      menu.hover_rail(ship_at) == false)

-- One level in, the stage owns the cursor, so a hover on the rail is a
-- second mark rather than a move.
menu.click_rail(ship_at)
menu.sel.ship = 4
menu.hover_rail(settings_at)
check("a hover from inside a page leaves the cursor alone",
      menu.sel.ship == 4, "cursor " .. tostring(menu.sel.ship))
check("and leaves the lit stop saying where you are",
      menu.view().rail_sel == ship_at, tostring(menu.view().rail_sel))
check("while the view says where the pointer is",
      menu.view().rail_hover == settings_at,
      tostring(menu.view().rail_hover))
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

-- --- and the rail is reachable from the root, which is where it started ---

menu.stack = {"root"}
menu.sel = {}
local help_at = top_index("help")
menu.click_rail(help_at)
check("every stop is reachable", menu.stack[2] == "help",
      table.concat(menu.stack, "/"))

-- --- the discord stop leaves, rather than going somewhere in here ----------
--
-- Every other stop on the rail pushes a page onto the stack. This one hands a
-- URL to the browser and leaves the stack where it was, so the two things
-- worth pinning are that it opens the right address in a new tab and that it
-- does not quietly navigate the menu somewhere as well.

do
    local asked = nil
    _G.sys.open_url = function(url, attrs)
        asked = {url = url, target = attrs and attrs.target}
        return true
    end

    menu.open = true
    menu.home = true
    menu.stack = {"root"}
    menu.sel = {}
    local at = top_index("discord")
    check("the rail carries a discord stop", at ~= nil, "absent")
    -- Its own mark, or it would draw the fallback and read as an about row.
    local icon = nil
    for _, r in ipairs(menu.view().rail) do
        if r.label == "discord" then icon = r.icon end
    end
    check("and it wears its own mark", icon == "discord", tostring(icon))

    menu.click_rail(at)
    check("tapping it asks the browser to open the invite",
          asked and asked.url == "https://play.vectorwake.net/discord",
          asked and asked.url or "nothing asked")
    check("in a new tab", asked and asked.target == "_blank",
          asked and tostring(asked.target))
    -- The redirect, not the invite: an invite that has to be reissued should
    -- be one line of Caddy rather than a client release.
    check("and it is the redirect rather than a discord.gg link",
          asked and not asked.url:find("discord.gg", 1, true))
    check("the menu stays where it was", #menu.stack == 1,
          table.concat(menu.stack, "/"))

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

    -- And an engine with no open_url at all does not take the menu down.
    menu.stack = {"root"}
    menu.sel = {}
    _G.sys.open_url = nil
    local ok = pcall(menu.click_rail, top_index("discord"))
    check("an engine without open_url survives the tap", ok)
end

-- --- and on the web the page holds a real link over it --------------------
--
-- Nothing the client does from its own loop is inside the tap that asked for
-- it, and a browser will not open a tab for anything else: desktop allowed a
-- frame-late window.open, every phone called it a popup and blocked it. So
-- the row carries its address for the page to lay an anchor over, and the
-- finger lands on that rather than on the canvas.

do
    menu.open = true
    menu.home = true
    menu.stack = {"root"}
    menu.sel = {}
    local link = nil
    for _, r in ipairs(menu.view().rail) do
        if r.label == "discord" then link = r.link end
    end
    check("the rail stop carries its address", link ~= nil, "none")
    check("and it is the redirect",
          link == "https://play.vectorwake.net/discord", tostring(link))

    -- No other stop does, or the page would put a link over a page of the
    -- game's own.
    local strays = {}
    for _, r in ipairs(menu.view().rail) do
        if r.link and r.label ~= "discord" then
            strays[#strays + 1] = r.label
        end
    end
    check("and no other stop does", #strays == 0, table.concat(strays, ", "))
end

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
