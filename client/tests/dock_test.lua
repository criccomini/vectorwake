-- The menu is one column, stood in one place on every window.
--
--     lua5.1 client/tests/dock_test.lua
--
-- The menu used to be two layouts: a tab bar under a thumb below 620 points
-- and a row of words across the top above it, with a second column beside the
-- page where a monitor had room for one. Two layouts is two things to learn
-- and two sets of measurements to keep in step, and the wide one was drawn
-- over the fight a watcher opened the menu from.
--
-- What replaces them is a column at a phone's own measure docked to the left
-- edge: the name and the call sign in a head, the page under it, the way in
-- over the six stops at its foot. This file is the arithmetic that says so,
-- because the thing it pins is invisible in CI and is exactly what a second
-- layout would quietly reintroduce. See .design/menu-unify.

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

local harness = require("tests.ui_harness")
local layer = harness.layer()

-- Eight seats, four a side, so the HUD behind the menu has a room to draw.
local SEATS = {}
for i = 0, 7 do
    SEATS[i] = {name = "pilot " .. i, label = i % 2 == 0 and "human" or "bot",
                ai = i % 2 == 1}
end
local SIM = setmetatable({
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

local ui = harness.install({sim = SIM})

local RAIL = {}
for i, e in ipairs({{"play", "zones"}, {"ship", "ship"},
                    {"friends", "friends"}, {"settings", "settings"}}) do
    RAIL[i] = {label = e[1], icon = e[2], index = i}
end

local ROWS = {
    {sect = "zones", label = "melee", detail = "3 + 5 AI", index = 1,
     pick = true, players = 3, bots = 5, live = true,
     note = "four a side, three minutes"},
    {label = "ladder", detail = "1 + 1 AI", index = 2, pick = true,
     players = 1, bots = 1, live = true, note = "one life at a time"},
    -- A row whose sentence is there and empty, which is what a game whose
    -- catalog left the hook line blank hands the list. It read as a row with
    -- a sentence everywhere the size and the position of the label are
    -- decided, and as a row without one where the lines are counted, so the
    -- page threw on the length of nothing and the menu came up blank over a
    -- live arena. Kept on the list rather than checked on its own, because
    -- the row this happens to is an ordinary row of an ordinary page.
    {label = "trial", detail = "2 + 2 AI", index = 3, pick = true,
     players = 2, bots = 2, live = true, note = ""},
}

local function view(over)
    local v = {depth = 1, sel = 1, rail = RAIL, rail_sel = 1, focus = "rail",
               home = false, scenery = true, closable = true, rows = ROWS,
               at = "play", pilot = {name = "Krait 4", rivets = 310}}
    for k, val in pairs(over or {}) do v[k] = val end
    return v
end

-- One frame of the menu, drawn over the same watcher HUD the client draws it
-- over. Both halves matter here: the column stands on the corner the HUD's
-- own keys hold, and what a press there reaches is the question.
local function frame(w, h, over)
    local st = package.loaded["arena.state"]
    st.n = 0
    ui.begin(layer, w, h, 1, false, 0)
    ui.hud({
        me = 0, watch = {subject = 0}, landing = true, side = 0,
        viewer_name = "Krait 4", menu_open = true,
        pilots = SEATS, watchers = {}, teams = {},
        match = {playing = true, left = 107, score = {[0] = 3, [1] = 5}},
        side_names = {[0] = "Pylon", [1] = "Caisson"},
        feed = {}, hurt = 0, charges = {},
        cam_x = 3000, cam_y = 3000, half_w = w / 2, half_h = h / 2,
        banner = "", link_bars = 4, zone = "melee",
        fps = 60, frame_ms = 16.7, rx_rate = 0, tx_rate = 0,
    })
    ui.menu(view(over))
    ui.finish()
    return st
end

-- The panel alone, with no HUD behind it: a check about the menu's own type
-- is not answered by a side name in the score band over the window.
local function page(w, h, over)
    local st = package.loaded["arena.state"]
    st.n = 0
    ui.begin(layer, w, h, 1, false, 0)
    ui.menu(view(over))
    ui.finish()
    return st
end

local function box(action)
    for _, b in ipairs(ui.hits) do
        if b.action == action then return b end
    end
    return nil
end

local function rail_boxes()
    local out = {}
    for _, b in ipairs(ui.hits) do
        if b.action == "rail" then out[#out + 1] = b end
    end
    table.sort(out, function(a, b) return a.x < b.x end)
    return out
end

local function press(x, y) local r = ui.pick(x, y) return r and r.action end

-- The measure the whole layout is written in. A window narrower than this
-- gives the column everything it has, which is what a phone held upright
-- already did.
local DOCK = 390

-- What a window with room multiplies that by. The column is one drawing
-- wherever it stands and it is not one size: a monitor draws it a quarter
-- larger, column and type and gaps together, because 390 points held at
-- arm's length is a strip of a phone screen shown on a desk. A phone keeps
-- the measure, held sideways included, since the scarce axis is what decides
-- and a landscape phone is 390 points tall. Asked of ui rather than written
-- down twice. See TYPE and MENU_SCALE in arena/ui.lua.
local function measure(w, h)
    local compact = math.min(w, h) < 480
    return math.min(DOCK * (compact and 1 or ui.MENU_SCALE), w)
end

local SHAPES = {
    {"desktop", 1440, 810},
    {"sideways", 844, 390},
    {"upright", 390, 844},
    {"small", 320, 480},
}

-- --- the same column on every window ---------------------------------------

local seen = {}
for _, s in ipairs(SHAPES) do
    local name, w, h = s[1], s[2], s[3]
    frame(w, h)
    local want = measure(w, h)
    local tabs = rail_boxes()
    check(name .. " lays the six stops along the foot",
          #tabs == #RAIL, #tabs .. " of " .. #RAIL)
    if #tabs == #RAIL then
        local left = tabs[1].x
        local right = tabs[#tabs].x + tabs[#tabs].w
        check(name .. " docks the column to the left edge",
              math.abs(left) < 1.5, string.format("%.1f", left))
        check(name .. " draws the column at this window's measure",
              math.abs(right - want) < 2,
              string.format("%.1f against %.1f", right, want))
        -- The foot is the foot: the stops reach the bottom of the glass
        -- rather than floating over an indicator.
        local bottom = tabs[1].y + tabs[1].h
        check(name .. " puts the stops on the bottom edge",
              bottom >= h - 1, string.format("%.1f of %d", bottom, h))
        seen[name] = {left = left, right = right, pitch = tabs[1].w}
    end
    -- And the head, which carries the name and the call sign whatever is
    -- behind the panel.
    check(name .. " carries the call sign in the head",
          box("pilot_page") ~= nil, "no call sign")
    local x = box("close")
    check(name .. " keeps a way out on the head's own line",
          x ~= nil and x.y < 80, x and string.format("%.1f", x.y) or "none")
end

-- The point of all of it: the column is the same drawing wherever it stands,
-- so the only things a window changes are how large it is drawn and how much
-- fight is beside it. Same proportions, one scale apart.
do
    local a, b = seen.desktop, seen.sideways
    check("a monitor and a phone on its side draw one column at two sizes",
          a and b and math.abs(a.right - b.right * ui.MENU_SCALE) < 2
              and math.abs(a.pitch - b.pitch * ui.MENU_SCALE) < 2,
          a and b and string.format("%.1f/%.1f wide, %.1f/%.1f a stop",
                                    a.right, b.right, a.pitch, b.pitch)
              or "missing a shape")
    local c = seen.upright
    check("and a phone held upright gets the column and nothing else",
          c and math.abs(c.right - 390) < 2,
          c and string.format("%.1f", c.right) or "missing")
end

-- --- the column covers the corner it is docked to --------------------------
--
-- `M.pick` breaks a tie on publish order and the HUD publishes first, so a box
-- the column covers would still win the press that landed on the column: a
-- hand reaching for the head of this panel would find the MENU key underneath
-- it and shut the thing it was aiming at.

frame(1440, 810)
check("the corner row is not drawn under the column",
      box("open") == nil, "MENU is still published")
-- Nor the band's own press, which is what opens the roster now. It keeps
-- drawing over a drawer that does not reach it, because a player reading a
-- page still wants the clock; it stops being a control, because the board it
-- opens is not drawn while the menu is.
check("nor the band's press across the top", box("details") == nil,
      "the band is still a control under the menu")
-- And a press on the head reaches the head.
local sign = box("pilot_page")
if sign then
    check("a press on the head's call sign reaches it",
          press(sign.x + sign.w / 2, sign.y + sign.h / 2) == "pilot_page",
          tostring(press(sign.x + sign.w / 2, sign.y + sign.h / 2)))
end
-- The fight beside the column is not the column. A press on a game means put
-- me back in it, which is what escape does.
check("a press on the fight beside it is the way out",
      press(1000, 400) == "close", tostring(press(1000, 400)))
check("and a press on the column's own ground is not",
      press(120, 400) ~= "close", tostring(press(120, 400)))

-- --- the way in ------------------------------------------------------------
--
-- The column covers PLAY NOW: `M.hud` stands the landing block down while the
-- menu is up. A DEPLOY key stood at the foot of the column for that, and it is
-- gone: the games list is the page that key sent you to and the row is what
-- the walk ended in, so pressing a game is the way in and one control for the
-- act is enough.

for _, s in ipairs(SHAPES) do
    local name, w, h = s[1], s[2], s[3]
    frame(w, h)
    check(name .. " carries no key of its own at the foot",
          box("play_now") == nil, "a deploy key came back")
    -- The rows are the way in. Every one of them answers a press, and the
    -- press covers the whole width of the panel rather than the row's own
    -- measure, because that is what the lit field covers.
    local row
    for _, b in ipairs(ui.hits) do
        if b.action == "stage" and b.value == 1 then row = b end
    end
    check(name .. " makes the game a thing to press", row ~= nil, "no row")
    if row then
        local dx, _, dw = ui.drawer_span()
        check(name .. " gives the row the panel's whole width",
              math.abs(row.x - dx) < 1.5 and math.abs(row.w - dw) < 1.5,
              string.format("%.0f..%.0f against %.0f..%.0f", row.x,
                            row.x + row.w, dx, dx + dw))
        check(name .. " presses that row where it is drawn",
              press(row.x + row.w / 2, row.y + row.h / 2) == "stage",
              tostring(press(row.x + row.w / 2, row.y + row.h / 2)))
    end
end

-- --- and the way out of a seat is on the row of the room it is in -----------
--
-- A button at the row's right hand end. The row itself publishes a box the
-- whole width of the panel, so a button drawn inside that box which lost the
-- press would be a control you can see and cannot use. It wins because it is
-- published first and `M.pick` breaks a tie on publish order.

do
    local flying = {}
    for i, r in ipairs(ROWS) do
        local c = {}
        for k, val in pairs(r) do c[k] = val end
        flying[i] = c
    end
    flying[1].acts = {{label = "leave"}}
    for _, s in ipairs(SHAPES) do
        local name, w, h = s[1], s[2], s[3]
        frame(w, h, {rows = flying, home = false, scenery = false})
        local key
        for _, b in ipairs(ui.hits) do
            if b.action == "row_act" then key = b end
        end
        check(name .. " hangs the button off the row it belongs to",
              key ~= nil, "none published")
        if key then
            local dx, _, dw = ui.drawer_span()
            check(name .. " keeps it inside the panel",
                  key.x >= dx - 1.5 and key.x + key.w <= dx + dw + 1.5,
                  string.format("%.0f..%.0f in %.0f..%.0f", key.x,
                                key.x + key.w, dx, dx + dw))
            -- At the row's right hand end rather than anywhere along it,
            -- which is what makes the right arrow the way to it.
            check(name .. " at that row's right hand end",
                  key.x > dx + dw * 0.6,
                  string.format("%.0f of %.0f", key.x - dx, dw))
            check(name .. " sends a press on it to the button",
                  press(key.x + key.w / 2, key.y + key.h / 2) == "row_act",
                  tostring(press(key.x + key.w / 2, key.y + key.h / 2)))
            -- And the rest of the row is still the row. Two controls on one
            -- line, and the line has to keep meaning what it means.
            check(name .. " and the rest of that row to the row",
                  press(dx + 12, key.y + key.h / 2) == "stage",
                  tostring(press(dx + 12, key.y + key.h / 2)))
        end
    end
end

-- --- the way out stands where the way in stood ------------------------------
--
-- The x sits in the square the menu key had, at the same inset on the same
-- line. Pressing the menu key and pressing the x are one control seen from
-- either side, so a hand that learned where one was has learned the other.

do
    local st = frame(1440, 810)
    local x = box("close")
    check("the way out is on the left of the head", x ~= nil and x.x < 60,
          x and string.format("%.0f", x.x) or "none")
    if x then
        check("and square, the size the menu key is",
              math.abs(x.w - x.h) < 1.5,
              string.format("%.0fx%.0f", x.w, x.h))
    end
    -- And the name is not on that line at all. It sat between the x and the
    -- call sign on every page, turning: a picture of a name the reader has
    -- already read, animating in the corner of a panel they opened to do
    -- something else. The landing keeps it, over the key it is a title for.
    local named = false
    for i = 1, st.n do
        if string.lower(st.text[i].s) == "vectorwake" then named = true end
    end
    check("and the head carries no wordmark", not named, "the name is on it")
end

-- --- one head, on every page ------------------------------------------------
--
-- The ship page and the four screens it opens used to draw their own band on
-- the head's line instead, taking the call sign and the rule off it: the
-- longest page in the menu spending nothing above the build. What that bought
-- was a panel that jumped the height of its own head the moment a hand walked
-- into the ship page from the rail, and one page where the two controls at the
-- top of the drawer were not where they are everywhere else. It is also the
-- line the arrows reach by pressing up off the first row of a page, so a page
-- without one is a page with no way to the account.

do
    frame(1440, 810)
    local plain_x = box("close")
    local plain_name = box("pilot_page")
    frame(1440, 810, {at = "hangar", kit = true, kit_spent = 12,
                      kit_total = 30, profile = {name = "custom"},
                      rows = {{label = "custom", group = "band", index = 1},
                              {label = "points", group = "band", index = 2}}})
    local kit_x = box("close")
    check("the ship page keeps the call sign the other pages carry",
          box("pilot_page") ~= nil and plain_name ~= nil,
          "no call sign over the kit")
    check("and the x stays on the line it is on everywhere else",
          kit_x ~= nil and plain_x ~= nil
          and math.abs(kit_x.y - plain_x.y) < 1.5,
          kit_x and plain_x
          and string.format("%.1f against %.1f", kit_x.y, plain_x.y)
          or "none")
end

-- --- nothing in the menu is set under the ladder ----------------------------
--
-- The account page's keys were under the old floor: NEW NAME at eight and a
-- half points is eight and a half pixels on a monitor, and it was reported as
-- a key nobody could read. The floor is the bottom rung now, and it is
-- measured here in the page that broke it rather than only in the sweep, so
-- the reason this file exists stays attached to the check it produced.
-- client/tests/type_test.lua holds the whole menu to the same ladder.

do
    local st = page(1440, 810,
                     {at = "pilot", depth = 2, focus = "stage", sel = 1,
                      pilot_card = {name = "Krait 4", claimed = true,
                                    online = true, rivets = 310,
                                    career = {kills = 3, deaths = 4,
                                              games = 7}},
                      rows = {{label = "new name", index = 1, pick = true},
                              {label = "change password", index = 2,
                               pick = true},
                              {label = "log out", index = 3, pick = true}}})
    local floor = ui.TYPE.LABEL * ui.MENU_SCALE - 0.01
    local small = nil
    for i = 1, st.n do
        local t = st.text[i]
        if t.px < floor then small = t end
    end
    check("the account page sets nothing under the ladder's bottom rung",
          small == nil,
          small and string.format("%s at %.1f", small.s, small.px) or "")
end

print(fails == 0 and "all dock checks passed"
      or (fails .. " dock checks failed"))
os.exit(fails == 0 and 0 or 1)
