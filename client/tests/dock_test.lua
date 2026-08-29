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

-- The mesh is counted rather than drawn everywhere else in this file, and one
-- question here is not about a count: the link meter in the head is four
-- rectangles, and a press box that misses them is the fault. Kept bottom-up,
-- the way the mesh takes them, and cleared with the text at the top of a frame.
local rects = {}
layer.rect = function(_, x, y, w, h)
    rects[#rects + 1] = {x = x, y = y, w = w, h = h}
end

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
                    {"pilot", "pilot"}, {"settings", "settings"}}) do
    RAIL[i] = {label = e[1], icon = e[2], index = i}
end

local ROWS = {
    {sect = "zones", label = "melee", detail = "3 + 5 AI", index = 1,
     pick = true, players = 3, bots = 5, live = true,
     note = "four a side, three minutes"},
    {label = "chaos", detail = "1 + 1 AI", index = 2, pick = true,
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
    rects = {}
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
    rects = {}
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

-- `touching` is the third argument the real client passes for a finger rather
-- than a pointer, and it is what turns on the near-miss pass in `M.pick`.
local function press(x, y, touching)
    local r = ui.pick(x, y, touching)
    return r and r.action
end

-- One word of the frame, or nil. Used to prove an absence: the meter in the
-- head draws no caption, and this is how the test says so.
local function word_at(s)
    local st = package.loaded["arena.state"]
    for k = 1, st.n do
        if st.text[k].s == s then return st.text[k] end
    end
    return nil
end

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
    -- behind the panel. The call sign is a label rather than a key since
    -- decision 99, so it is the word that is looked for and not a box.
    check(name .. " carries the call sign in the head",
          word_at("Krait 4") ~= nil, "no call sign")
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
-- And the call sign takes no press. It was a second door onto the pilot page
-- and there is no page: what a press near it must not do is reach something
-- else, so the head's own ground answers instead of the fight behind it.
local sign = word_at("Krait 4")
if sign then
    check("the head's call sign is a label rather than a key",
          box("pilot_page") == nil, "the call sign still takes a press")
end
-- The fight beside the column is not the column. A press on a game means put
-- me back in it, which is what escape does.
check("a press on the fight beside it is the way out",
      press(1000, 400) == "close", tostring(press(1000, 400)))
check("and a press on the column's own ground is not",
      press(120, 400) ~= "close", tostring(press(120, 400)))

-- --- the state of the line, in the head ------------------------------------
--
-- The link meter stood in the top right of the arena, above the dial, for as
-- long as there was a HUD to stand in. It is a fact about this client rather
-- than about the fight, like the call sign it now sits beside, so it moved
-- into the head of the panel that carries the rest of them.
--
-- Four bars and no caption, which is what makes the measurements below the
-- whole of what says it is there: no word is drawn, so a test that reads the
-- frame's text cannot see this at all. What it reads instead is the meter's
-- own rectangles and the box published over them.
--
-- Three things are worth pinning. The block is on the head's line and inside
-- the column, at every window, because a readout hung off the drawer's right
-- edge would be drawn over the fight. It is to the left of the account button
-- rather than through it, because both are laid out from the same end and
-- neither is told about the other, which is exactly how the tab row and this
-- same button once ran into each other. And the box covers every bar, since
-- the old one on the arena's corner took the bars and the last quarter of the
-- word beside them and left most of itself dead.

-- The meter's own rectangles: four narrow ones standing on the head's line.
-- Kept in the order they were drawn, which is shortest bar first.
local function bar_rects(h, switch)
    local out = {}
    for _, r in ipairs(rects) do
        local top = h - (r.y + r.h)
        if r.w < 8 and top >= switch.y - 0.01 and top < switch.y + switch.h then
            out[#out + 1] = {x = r.x, w = r.w, top = top, h = r.h}
        end
    end
    return out
end

for _, shape in ipairs(SHAPES) do
    local name, w, h = shape[1], shape[2], shape[3]
    page(w, h)
    local switch, acct = box("debug"), word_at("Krait 4")
    check(name .. " publishes the meter's press in the head",
          switch ~= nil, "no box")
    if switch and acct then
        local bars = bar_rects(h, switch)
        check(name .. " draws four bars and no caption",
              #bars == 4 and word_at("LINK") == nil,
              #bars .. " bars, caption " .. tostring(word_at("LINK") ~= nil))
        -- The call sign is a label now rather than a key, so what the bars
        -- stand clear of is the type itself and not a box around it.
        check(name .. " puts them to the left of the call sign",
              switch.x + switch.w <= acct.x + 0.01,
              string.format("cluster ends %.1f, name starts %.1f",
                            switch.x + switch.w, acct.x))
        -- Inside the column, which is docked to the left edge and is 390
        -- points wide wherever there is room for it.
        local dock = math.min(DOCK, w)
        check(name .. " keeps the whole cluster inside the column",
              switch.x >= -0.01 and switch.x + switch.w <= dock + 0.01,
              string.format("%.1f..%.1f of %d", switch.x,
                            switch.x + switch.w, dock))
        for i, b in ipairs(bars) do
            check(string.format("%s has bar %d inside the press", name, i),
                  b.x >= switch.x - 0.01
                      and b.x + b.w <= switch.x + switch.w + 0.01,
                  string.format("bar %.1f..%.1f, box %.1f..%.1f",
                                b.x, b.x + b.w, switch.x,
                                switch.x + switch.w))
        end
        -- A staircase, and one standing on the button's own line: the
        -- rectangles rise left to right and share a foot, and that foot is
        -- placed so the tallest is centered on the row.
        if #bars == 4 then
            local rising = true
            for i = 2, 4 do
                if bars[i].h <= bars[i - 1].h then rising = false end
                if math.abs((bars[i].top + bars[i].h)
                            - (bars[1].top + bars[1].h)) > 0.01 then
                    rising = false
                end
            end
            check(name .. " draws them as a staircase on one foot", rising,
                  "the bars do not rise from a shared floor")
            local tall = bars[4]
            -- The call sign's own line, flipped into the space the bars are
            -- measured in: `txt` sets a string on the middle of its line, so
            -- the recorded y is that middle and needs no half-height.
            local sign_y = h - acct.y
            check(name .. " centers the tallest on the call sign's line",
                  math.abs((tall.top + tall.h / 2) - sign_y) < 1,
                  string.format("bar mid %.1f, name mid %.1f",
                                tall.top + tall.h / 2, sign_y))
        end
    end
end

-- How many bars are lit is the reading, so it has to follow the count it is
-- handed rather than always drawing a full meter.
do
    local function lit(bars)
        page(1440, 810, {link_bars = bars})
        local switch = box("debug")
        return switch and #bar_rects(810, switch) or 0
    end
    check("every rung of the meter is drawn whatever the count",
          lit(1) == 4 and lit(4) == 4,
          "a dim bar went missing")
end

-- A press on it is the way into the numbers behind it, which is the one thing
-- this cluster is a control for.
do
    page(1440, 810)
    local switch = box("debug")
    if switch then
        check("a press on the bars reaches the debug readout",
              press(switch.x + switch.w / 2, switch.y + switch.h / 2)
                  == "debug",
              tostring(press(switch.x + switch.w / 2,
                             switch.y + switch.h / 2)))
        -- And it is a fingertip rather than the drawing. Twenty two points of
        -- bars is well under what a thumb is owed, and the near-miss pass that
        -- covers every other small control in this interface cannot help here:
        -- the column publishes one box over the whole of itself, an exact hit
        -- beats a near miss, so a press wide of these bars is answered by the
        -- panel rather than falling through to them. The box has to be the
        -- target itself.
        check("the box is a whole target, not the size of the bars",
              switch.w >= ui.TARGET - 0.01 and switch.h >= ui.TARGET - 0.01,
              string.format("%.1fx%.1f against %d",
                            switch.w, switch.h, ui.TARGET))
        check("and a press just wide of the bars lands on it",
              press(switch.x + 2, switch.y + switch.h / 2) == "debug",
              tostring(press(switch.x + 2, switch.y + switch.h / 2)))
    end
end

-- The account button grows with the call sign on it and a window narrower than
-- a phone shrinks the column under both, so a long enough name in a small
-- enough window leaves nothing between that button and the x at the other end
-- of the head. The readout goes rather than being laid over the way out:
-- `M.pick` answers on publish order and the head publishes before the page
-- does, so a cluster reaching that square would take the presses meant for it
-- and strand a player inside the menu.
--
-- 350 points is narrower than a phone held upright, which is the point: the
-- rule is about the collision rather than about a device, and the width is
-- chosen to force one while the account button itself still clears the x. A
-- wider column keeps the meter and gives up part of its press box instead,
-- which the case below is about.
do
    page(350, 700, {pilot = {name = string.rep("W", 24), rivets = 310}})
    local switch = box("debug")
    check("a column too narrow for both leaves the meter out",
          switch == nil, "the meter is still drawn")
    local x = box("close")
    check("and the way out is what a press on that square reaches",
          x ~= nil and press(x.x + x.w / 2, x.y + x.h / 2) == "close",
          x and tostring(press(x.x + x.w / 2, x.y + x.h / 2)) or "no x")
end

-- Between those two there is a band where the bars fit and a whole fingertip
-- does not, and there the box gives up its left rather than the readout giving
-- up the row: a phone at its own measure with the longest call sign anybody can
-- register. What must hold is that the box still covers every bar and still
-- stops short of the x, since a press box over the way out is the thing this
-- whole rule exists to prevent.
do
    local h = 844
    page(390, h, {pilot = {name = string.rep("W", 24), rivets = 310}})
    local switch, x = box("debug"), box("close")
    check("the longest call sign on a phone keeps the meter",
          switch ~= nil, "the meter went")
    if switch and x then
        local bars = bar_rects(h, switch)
        check("with every bar still inside its press", #bars == 4, #bars)
        for i, b in ipairs(bars) do
            check("bar " .. i .. " is covered on a crowded head",
                  b.x >= switch.x - 0.01
                      and b.x + b.w <= switch.x + switch.w + 0.01)
        end
        check("and the press stops short of the way out",
              switch.x >= x.x + x.w,
              string.format("box starts %.1f, the x ends %.1f",
                            switch.x, x.x + x.w))
        check("so that square is still the way out",
              press(x.x + x.w / 2, x.y + x.h / 2) == "close",
              tostring(press(x.x + x.w / 2, x.y + x.h / 2)))
    end
end

-- A head with no account button has nothing for the meter to sit inside, so it
-- takes the end of the row itself rather than hanging off a control that was
-- not drawn. `false` rather than nil: the view is merged with `pairs`, and a
-- nil never reaches it to clear anything.
do
    page(1440, 810, {pilot = false})
    local switch = box("debug")
    check("a head with no account button still carries the meter",
          switch ~= nil, "no meter")
    check("and there is no button for it to run into",
          box("pilot_page") == nil, "a call sign was drawn")
    if switch then
        local wide = measure(1440, 810)
        check("and it stays inside the column",
              switch.x + switch.w <= wide + 0.01,
              string.format("ends %.1f of %.1f", switch.x + switch.w, wide))
    end
end

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
-- line the arrows reach by pressing up off the first row of a page.

do
    frame(1440, 810)
    local plain_x = box("close")
    local plain_name = word_at("Krait 4")
    frame(1440, 810, {at = "hangar", kit = true, kit_spent = 12,
                      kit_total = 30, profile = {name = "custom"},
                      rows = {{label = "custom", group = "band", index = 1},
                              {label = "points", group = "band", index = 2}}})
    local kit_x = box("close")
    check("the ship page keeps the call sign the other pages carry",
          word_at("Krait 4") ~= nil and plain_name ~= nil,
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
-- a key nobody could read. That page is gone and its acts are rows of the
-- landing's account list; the floor it produced is still the floor, and
-- client/tests/type_test.lua holds the whole menu to the same ladder.

do
    local st = page(1440, 810,
                     {at = "settings", depth = 2, focus = "stage", sel = 1,
                      rows = {{label = "sound", index = 1, pick = true,
                               detail = "loud"},
                              {label = "music", index = 2, pick = true,
                               detail = "off"}}})
    local floor = ui.TYPE.LABEL * ui.MENU_SCALE - 0.01
    local small = nil
    for i = 1, st.n do
        local t = st.text[i]
        if t.px < floor then small = t end
    end
    check("a page of the menu sets nothing under the ladder's bottom rung",
          small == nil,
          small and string.format("%s at %.1f", small.s, small.px) or "")
end

print(fails == 0 and "all dock checks passed"
      or (fails .. " dock checks failed"))
os.exit(fails == 0 and 0 or 1)
