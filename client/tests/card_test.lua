-- The question card: the lines it draws, and the elements it hands the page.
--
--     lua5.1 client/tests/card_test.lua
--
-- A card is the one thing on screen that has to be answered before anything
-- else happens, and the lines on it are the only typing in this game. What
-- can go wrong there is in the drawing rather than the model: a password
-- drawn as itself, a pasted line that runs off the side of the card, an
-- input element laid over a rule it is nowhere near, or the page's copy of a
-- value and the client's copy both on screen half a frame apart. The pasted
-- line is the one that shipped.
--
-- So these run the real `ui.land_card` against a recording layer, over the
-- real cards `arena/menu.lua` raises. menu_test.lua is the model underneath:
-- what a letter does, what enter sends, what a refusal keeps. This file is
-- what any of it looks like on a screen.
--
-- The checks came from menu_view_test.lua, which measured the drawer the card
-- used to be drawn inside. The drawer is gone and the card is not: the arena
-- calls `ui.land_card(menu.ask)` every frame after everything else, so the
-- same card stands over the landing, over the column, or over a fight with
-- neither of them up.

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

-- --- the world the menu talks to, as little of it as a card wants ----------
--
-- Only the account cards reach past this file, and only to ask who they are
-- for. Nothing here is sent anywhere: `menu.step` is menu_test.lua's subject,
-- and what these frames need is the card as it stands before anybody answers
-- it.

local account = {
    name = "", claimed = false, base = "https://meta",
    aim = function() end,
    online = function() return true end,
    claim = function() end,
    login = function() end,
    rename = function() end,
    logout = function() end,
    profiles = {},
}
package.loaded["arena.account"] = account
package.loaded["arena.net"] = {
    teams = {}, my_team = 0, may_found = false,
    my_team_name = function() return "" end,
    transport = function() return {} end,
    PROTOCOL = 5, invite = function() end,
}
package.loaded["arena.callsign"] = {
    roll = function() return "Vesper 412" end,
    seed = function() end,
    generate = function() return "Vesper 412" end,
}
package.loaded["arena.directory"] = {
    rows = {}, note = "", tick = function() end, aim = function() end,
    pilot_name = "", label_of = function(z) return z end,
}
package.loaded["arena.sfx"] = {ui = function() end,
                               master_gain = function() end,
                               music_gain = function() end}
_G.sys = {get_config_string = function(_, d) return d end,
          get_config_int = function(_, d) return d end,
          get_engine_info = function() return {version = "test"} end,
          get_save_file = function() return "/tmp/vw-card-test-save" end,
          load = function() return {} end, save = function() return true end,
          get_sys_info = function() return {system_name = "Linux"} end}
_G.sound = setmetatable({}, {__index = function() return function() end end})
_G.html5 = nil
_G.hash = function(s) return s end

-- --- the engine, as much of it as the card touches -------------------------

local harness = require("tests.ui_harness")
local layer = harness.layer()

-- A masked line is a row of discs and nothing else, so counting them is how
-- this file asks how much has been typed into one. Everything else the card
-- draws is type, and type is read back off `arena.state`.
local discs = {}
layer.disc = function(_, x, y, r)
    discs[#discs + 1] = {x = x, y = y, r = r}
end

-- Eight seats, because the HUD returns on an empty room and draws nothing at
-- all. A card over a blank screen says nothing about what a card does to what
-- is behind it.
local SIM = setmetatable({
    ship_count = function() return 8 end,
    ship_active = function() return 1 end,
    ship_alive = function() return 1 end,
    ship_x = function(i) return 3000 + i * 90 end,
    ship_y = function(i) return 3000 + i * 60 end,
    ship_team = function(i) return i < 4 and 0 or 1 end,
    ship_energy = function() return 100 end,
    ship_max_energy = function() return 100 end,
    has_trigger = function() return true end,
    weapon_count = function() return 0 end,
    flag_count = function() return 0 end,
    flag_at = function() return 0, 0, 255 end,
    map_coarse = function() return nil end,
    BTN_FIRE = 1,
}, {__index = function() return function() return 0 end end})

local ui = harness.install({sim = SIM})
local state = package.loaded["arena.state"]
local menu = require("arena.menu")
-- Whoever the claim card will name. The account's name wins in the client
-- once there is one; here there is no account yet, and this is the same door
-- an operator's build comes in by.
menu.defaults("Vesper 412")

-- --- the harness -----------------------------------------------------------

local SEATS = {}
for i = 0, 7 do
    SEATS[i] = {name = "pilot " .. i, label = i % 2 == 0 and "human" or "bot",
                ai = i % 2 == 1}
end

-- The column as `menu.view` builds it: the way out, the machine, and which
-- side you are on. Only ever drawn here as something for a card to stand on.
local STOPS = {
    {stop = "leave", label = "leave", value = "to the stands"},
    {stop = "settings", label = "settings", mark = "settings"},
    {stop = "side", label = "side", value = "Pylon", named = true},
}

-- One frame with a card on it, drawn the way the arena draws one: whatever is
-- on screen first, then `ui.land_card` over the lot. `behind` is the case a
-- card is usually raised from, the menu column with the HUD under it; without
-- it the card stands on its own, which is what the checks about the card's
-- own lines want.
local W, H = 1280, 800
local function frame(ask, o)
    o = o or {}
    W, H = o.w or 1280, o.h or 800
    discs = {}
    state.n = 0
    ui.page_scroll = 0
    ui.details = false
    ui.col_sel, ui.col_sel_value = nil, nil
    -- Whether this build has a page to hand the lines to. Set per frame, so
    -- one section cannot leave it on for the next.
    ui.page_fields = o.page or false
    ui.begin(layer, W, H, o.density or 1, o.touching or false)
    if o.behind then
        ui.hud({
            me = 0,
            side = 0,
            viewer_name = "you",
            menu_open = o.column ~= false,
            -- The question itself, which is what tells the HUD to recede. The
            -- arena passes it every frame; see `M.hud`.
            card = true,
            pilots = SEATS,
            watchers = {},
            teams = {},
            match = {playing = true, left = 107, score = {[0] = 3, [1] = 5}},
            side_names = {[0] = "Pylon", [1] = "Caisson"},
            feed = {},
            hurt = 0,
            charges = {},
            cam_x = 3000, cam_y = 3000,
            half_w = W / 2, half_h = H / 2,
            banner = "",
            link_bars = 4,
            zone = "melee",
            fps = 60, frame_ms = 16.7, rx_rate = 0, tx_rate = 0,
        })
        -- The question rides the view, the way `menu.view` carries
        -- `menu.ask`: the column reads it to know that something stands over
        -- it and keeps the dim the HUD set. Without it the column would draw
        -- at full strength under the card it is being read through.
        ui.menu({open = true, stops = STOPS, rows = {}, ask = ask})
    end
    ui.land_card(ask)
    ui.finish()
    return state
end

-- Upper cased on the way out, because the interface sets every word it says
-- in capitals and what these checks are about is which words it says.
local function texts()
    local out = {}
    for i = 1, state.n do out[#out + 1] = string.upper(state.text[i].s) end
    return out
end

local function has(s)
    for _, t in ipairs(texts()) do
        if t == string.upper(s) then return true end
    end
    return false
end

-- Whether any line the card drew carries this string as it was written. `has`
-- upper cases both sides, which is the right question about a label and the
-- wrong one about something typed in: the whole point of the name line is
-- that it shows the characters that were typed.
local function drew(s)
    for i = 1, state.n do
        if string.find(state.text[i].s, s, 1, true) then
            return state.text[i].s
        end
    end
    return nil
end

-- The lines the page was asked to hold, one per element.
local function dom_rows()
    local out = {}
    for row in string.gmatch((ui.ask_dom or "") .. ";", "([^;]*);") do
        if row ~= "" then out[#out + 1] = row end
    end
    return out
end

-- --- a question stands what is behind it down and takes the taps with it ---
--
-- The card is drawn last and the gui draws every glyph over every mesh, so
-- nothing laid on top of the column can cover it: the column is quieted where
-- it is written or not at all. And a hit box published before the card is a
-- hit box under it, which is a tap on a row nobody can see answering a
-- question about a different one.

menu.confirm("you are already flying chaos",
             {{label = "leave", act = "leave"}, {label = "stay"}})
frame(menu.ask, {behind = true})

check("the question is drawn", has("you are already flying chaos"),
      table.concat(texts(), " "))
check("and its answers wear the keys the corner wears",
      has("LEAVE") and has("STAY"), table.concat(texts(), " "))

local loud, quiet = 0, 0
for i = 1, state.n do
    local t = state.text[i]
    if t.dim and t.dim < 1 then quiet = quiet + 1 else loud = loud + 1 end
end
check("what is behind it is quieted, glyph by glyph", quiet > 4,
      quiet .. " quieted, " .. loud .. " left lit")
-- The head and the two answers, at full strength, and nothing else: the card
-- is the only thing being asked about.
check("and the card itself is not", loud == 3, loud .. " lit")

local answers, others = 0, 0
for _, h in ipairs(ui.hits) do
    if h.action == "answer" then answers = answers + 1 else others = others + 1 end
end
check("only the answers can be pressed", answers == 2 and others == 0,
      answers .. " answers, " .. others .. " other boxes")

-- And it quiets the HUD with no column up as well. The account acts stand on
-- the landing now, so a sign-up card is raised over a bare fight with nothing
-- else over it. The rule was written for the drawer, which was always up
-- behind a card, so the card alone never reached it: the wash went down and
-- every instrument's label stayed at full brightness through it.
frame(menu.ask, {behind = true, column = false})
local lit_alone = 0
for i = 1, state.n do
    local t = state.text[i]
    if not (t.dim and t.dim < 1) then lit_alone = lit_alone + 1 end
end
check("a card over a bare fight quiets it too", lit_alone == 3,
      lit_alone .. " lit")

-- --- the lines a card is filled in on --------------------------------------
--
-- A question can also be lines to fill in. On a machine with keys the client
-- draws them, since the keys are already under the player's hands. Where
-- there is a page it hands the rectangles over instead and draws no value at
-- all. These are the drawn ones, which is what a native build has.

-- What gets typed into the two lines of a login card, here and in the section
-- after it: a call sign that is shown and a password that is not.
local NAME, PASS = "Vesper 412", "hunter2"
local function fill_login()
    menu.ask_login()
    for ch in string.gmatch(NAME, ".") do menu.type_field(ch) end
    menu.next_field()
    for ch in string.gmatch(PASS, ".") do menu.type_field(ch) end
end

fill_login()
frame(menu.ask)

check("a build with no page keeps its lines", ui.ask_dom == nil,
      tostring(ui.ask_dom))
-- Drawn, then: the name as itself, the password as discs, so the string typed
-- into it appears nowhere on the screen.
check("the name line shows what is in it", drew(NAME) ~= nil,
      table.concat(texts(), " "))
check("and the password line draws a disc per character instead",
      drew("hunter") == nil and #discs == #PASS,
      #discs .. " discs for " .. #PASS .. " characters, drew "
          .. tostring(drew("hunter")))

-- A line holds more than the rule under it can show. Sixty four characters is
-- what the server takes and what a manager generates, and pasting one in used
-- to draw every character: the run left the card and crossed the screen. The
-- end of it is what stays, because the end is where the caret is and where
-- the next character lands.
local long = string.rep("abcdefgh", 8)
frame({head = "Log in.", sel = 1, field = 1,
       fields = {{label = "call sign", value = long, kind = "username",
                  max = 64}},
       keys = {{label = "log in"}, {label = "cancel"}}},
      {w = 390, h = 844})
local run = drew("abcdefgh")
check("a line longer than its rule is clipped",
      run ~= nil and #run < #long,
      tostring(run and #run) .. " of " .. #long)
check("and it is the end that stays",
      run ~= nil and string.sub(long, #long - #run + 1) == run, tostring(run))

-- --- and the lines a page holds instead ------------------------------------
--
-- A canvas is not editable, and a browser raises its keyboard for an editable
-- element and for nothing else. So where there is a page, the card publishes
-- its rules as rectangles and the page lays real input elements over them.
-- The client draws the label and the rule either way, because those are the
-- card.
--
-- A phone at two device pixels to the point, which is where the unit these
-- are published in matters.
local PAGE_W, PAGE_H = 390, 844

fill_login()
frame(menu.ask, {w = PAGE_W * 2, h = PAGE_H * 2, density = 2, touching = true,
                 page = true})

check("a page is handed the lines", ui.ask_dom ~= nil, tostring(ui.ask_dom))
local spec = dom_rows()
-- One per line, and each carrying the word that tells a password manager
-- which box it is looking at. Without those two the whole exercise buys
-- nothing that the drawn keyboard did not already have.
check("one element per line", #spec == 2, tostring(#spec))
check("each saying what it is for",
      spec[1] and string.find(spec[1], ",username,", 1, true) ~= nil
          and spec[2]
          and string.find(spec[2], ",current-password,", 1, true) ~= nil,
      table.concat(spec, " | "))
-- And placed where the rule was drawn, in the page's unit rather than the
-- drawing's: at two device pixels to the point a card laid out at 390 points
-- would otherwise be published at twice its size, and the elements would sit
-- off the bottom of a card they belong on.
local l1, t1, w1 = string.match(spec[1] or "", "^([%d%.]+),([%d%.]+),([%d%.]+),")
l1, t1, w1 = tonumber(l1), tonumber(t1), tonumber(w1)
check("in css pixels, on the card",
      l1 and l1 > 0 and l1 < PAGE_W and t1 and t1 > 0 and t1 < PAGE_H
          and w1 and w1 < PAGE_W and l1 + w1 <= PAGE_W,
      tostring(l1) .. " " .. tostring(t1) .. " " .. tostring(w1))
local t2 = tonumber(string.match(spec[2] or "", "^[%d%.]+,([%d%.]+),"))
check("one line below the other", t2 and t1 and t2 - t1 == 48,
      tostring(t2) .. " - " .. tostring(t1))
-- Nothing of the value is drawn under an element holding it: two of
-- everything, half a frame apart, is what that would look like.
check("and the page's copy is the only copy",
      drew(NAME) == nil and drew("hunter") == nil and #discs == 0,
      table.concat(texts(), " ") .. ", " .. #discs .. " discs")
-- The labels stay ours, drawn in the interface's own face over the page's
-- boxes, so a card with elements on it is still the same card.
check("the labels are still drawn", has("call sign") and has("password"),
      table.concat(texts(), " "))

-- And on a machine with keys just the same. It was a touchscreen only at
-- first, on the argument that a desktop has the keys already; what that
-- argument left out is that a manager fills a form and cannot fill a drawing,
-- and that is the same on both.
frame(menu.ask, {page = true})
check("a keyboard too, which is where the manager is",
      ui.ask_dom ~= nil
          and string.find(ui.ask_dom, ",username,", 1, true) ~= nil,
      tostring(ui.ask_dom))

-- --- a claim card names the pilot it claims --------------------------------
--
-- A card asking only for a new password names the pilot it is for, so a
-- manager files the password against a call sign rather than against nothing.
-- It is not a line on the card: the name is not in question there.

account.claimed = false
menu.ask_password()
frame(menu.ask, {w = PAGE_W * 2, h = PAGE_H * 2, density = 2, touching = true,
                 page = true})
check("a claim carries the name it claims",
      string.find(ui.ask_dom or "", "|Vesper 412", 1, true) ~= nil,
      tostring(ui.ask_dom))
check("and asks for a new password rather than the held one",
      string.find(ui.ask_dom or "", ",new-password,", 1, true) ~= nil,
      tostring(ui.ask_dom))
check("and draws no second line for the name",
      select(2, string.gsub(ui.ask_dom or "", ";", "")) == 0,
      tostring(ui.ask_dom))

print(fails == 0 and "all card checks passed"
      or (fails .. " card checks failed"))
os.exit(fails == 0 and 0 or 1)
