-- The menu's rail and stage, measured rather than looked at.
--
--     lua5.1 client/tests/menu_view_test.lua
--
-- Four things here are invisible in CI and each of them has already been
-- wrong once: a stage cursor drawn while the cursor is on the rail, a list
-- longer than its room quietly showing only what fits, a rail stop with no
-- hit box under it, and a block that runs off the side of the screen when it
-- shifts to clear the corner stack. All four are arithmetic about rectangles
-- and indices, so this runs the real `M.menu` against a recording layer.

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

local W, H = 1280, 800
local frames, rects, segs = {}, {}, {}
local layer = {}
local function noop() end
for _, name in ipairs({"arc", "disc", "flush", "outline", "quad", "reset", "ring",
                       "skirt", "tri", "tri_fade", "fan", "seg_glow",
                       "glow_band", "halo", "ring_fade", "seg_fade",
                       "seg_flat"}) do
    layer[name] = noop
end
layer.frame = function(_, x, y, w, h)
    frames[#frames + 1] = {x = x, y = H - y - h, w = w, h = h}
end
layer.rect = function(_, x, y, w, h, col)
    rects[#rects + 1] = {x = x, y = H - y - h, w = w, h = h, col = col}
end
layer.seg = function(_, x0, y0, x1, y1)
    segs[#segs + 1] = {x0 = x0, y0 = y0, x1 = x1, y1 = y1}
end

_G.sim = setmetatable({}, {__index = function() return function() return 0 end end})
package.loaded["arena.state"] = {text = {}, n = 0, version = 0}
package.loaded["arena.touch"] = {layout = function() return {charge = {}} end,
                                 used = false}
package.loaded["arena.world"] = {build_overview = noop, forget_overview = noop,
                                 overview = function() return {grid = 0} end,
                                 radar_tiles = {}, radar_safe = {},
                                 radar_doors = {},
                                 HULLS = setmetatable({}, {__index = function()
                                     return {poly = {0, 0, 1, 1, 2, 0}, mid = 0}
                                 end})}

local ui = require("arena.ui")
local pal = require("arena.palette")

local RAIL = {}
-- The rail at its longest, which is what a pilot in a game with sides sees:
-- zones, ship, pilot, team, settings, help, discord, about. Every mark the
-- rail can wear is therefore drawn at least once here, and a mark that throws
-- is a menu that will not open. The change before this shipped a crash in a
-- drawing path no test ever ran.
for i, n in ipairs({"zones", "ship", "pilot", "team", "settings", "controls",
                    "discord", "about"}) do
    RAIL[i] = {label = n, icon = n, index = i}
end

-- The cursor, as the drawing makes it: a field of team blue across the row it
-- is on. Counted by color, since the wash a marked row carries is the same
-- blue at a lighter weight, and by width, since the rail's own lit stop wears
-- the same field at the same weight and is a third as wide.
local function cursors()
    local n = 0
    for _, r in ipairs(rects) do
        local c = r.col
        if c and c[1] == pal.FRIEND[1] and c[2] == pal.FRIEND[2]
           and c[4] > 0.12 and r.w > 300 then
            n = n + 1
        end
    end
    return n
end

local function draw(view, w, h, touching)
    W, H = w or 1280, h or 800
    frames, rects, segs = {}, {}, {}
    local st = package.loaded["arena.state"]
    st.n = 0
    ui.begin(layer, W, H, 1, touching or false)
    ui.menu(view)
    ui.finish()
    return st
end

-- Upper cased on the way out, because the interface sets every word it says
-- in capitals and what these checks are about is which words it says and
-- where they land.
local function texts(st)
    local out = {}
    for i = 1, st.n do out[#out + 1] = string.upper(st.text[i].s) end
    return out
end

local function is(t, s) return string.upper(t.s) == string.upper(s) end

local function has(st, s)
    for _, t in ipairs(texts(st)) do
        if t == string.upper(s) then return true end
    end
    return false
end

-- --- the rail is always there, and every stop is reachable by pointer ------

local rows = {}
for i = 1, 3 do
    rows[i] = {label = "zone" .. i, detail = "", index = i, pick = true,
               players = i, bots = 4, live = true}
end
local st = draw({depth = 1, sel = 0, rail = RAIL, rail_sel = 1, focus = "rail",
                 home = true, closable = false, rows = rows})

local rail_hits = 0
for _, h in ipairs(ui.hits) do
    if h.action == "rail" then rail_hits = rail_hits + 1 end
end
check("every rail stop publishes a hit box", rail_hits == #RAIL,
      rail_hits .. " of " .. #RAIL)
-- And under its own action, because a rail tap does not mean what a tap on
-- the page's rows means: routed as a row it picked the fourth hull when it
-- was asked for settings.
local as_rows = 0
for _, h in ipairs(ui.hits) do
    if h.action == "row" and h.value and h.value >= 1 then as_rows = as_rows + 1 end
end
check("and not as a row of whatever page is showing", as_rows == 0,
      as_rows .. " rail stops published as rows")
check("the rail names its stops", has(st, "zones") and has(st, "about"))
check("the stage shows what the rail points at", has(st, "zone1"))

-- --- the rail does not move when you go a level in ------------------------
--
-- The stop you just tapped has to still be under your thumb, because the next
-- tap is the one that goes somewhere else. It was not: the layout asked one
-- flag both "is there a game behind this" and "are we at the top level", so
-- descending on the start screen shifted the block clear of a corner stack
-- that is not there. On a phone held sideways that is 124 points sideways --
-- the rail slides out from under the thumb and the next tap lands on nothing.

local function rail_boxes(w, h, depth)
    draw({depth = depth, sel = depth == 1 and 0 or 1, rail = RAIL,
          rail_sel = 2, focus = depth == 1 and "rail" or "stage",
          home = true, closable = depth > 1, rows = rows}, w, h, true)
    local out = {}
    for _, hh in ipairs(ui.hits) do
        if hh.action == "rail" then
            out[hh.value] = string.format("%.0f,%.0f,%.0f,%.0f",
                                          hh.x, hh.y, hh.w, hh.h)
        end
    end
    return out
end

for _, shape in ipairs({{390, 844}, {844, 390}, {1280, 800}, {1600, 900}}) do
    local a = rail_boxes(shape[1], shape[2], 1)
    local b = rail_boxes(shape[1], shape[2], 2)
    local moved
    for i = 1, #RAIL do
        if a[i] ~= b[i] then moved = i .. ": " .. a[i] .. " -> " .. b[i] end
    end
    check(string.format("%dx%d holds the rail still on the way in",
                        shape[1], shape[2]), not moved, moved)
end

-- --- a preview carries no cursor -------------------------------------------
--
-- `sel` counts rail stops at this level. A stage that highlighted row `sel`
-- put a cursor on the second hull while the arrow keys moved the rail.

local preview = {depth = 1, sel = 2,
                 rail = RAIL, rail_sel = 2, focus = "rail",
                 home = true, closable = false, rows = rows}
draw(preview)
check("a previewed stage draws no cursor", cursors() == 0,
      cursors() .. " rows lit while the cursor is on the rail")
preview.focus = "stage"
draw(preview)
check("and the page it opens draws exactly one", cursors() == 1,
      cursors() .. " rows lit")
preview.focus = "rail"

-- --- a pointer resting on a row lights it ----------------------------------
--
-- The one thing the keyboard cannot say. In a preview the cursor belongs to
-- the rail, so the row under the pointer is the only thing that can tell you
-- what a click would land on; one level in the hover has already moved the
-- cursor and `hover` never arrives.

preview.hover = 3
draw(preview)
check("a pointer lights the row it rests on", cursors() == 1,
      cursors() .. " rows lit")
preview.hover = nil

-- --- the lit half is the half the arrows are in ---------------------------
--
-- Both halves mark their cursor with the same blue field, so the one wearing
-- the brighter of the two is the whole of the answer to what up and down will
-- move. Read off the rail's own field, drawn either side of the focus.

local function rail_wash()
    local a = 0
    for _, r in ipairs(rects) do
        local c = r.col
        if c and c[1] == pal.FRIEND[1] and c[2] == pal.FRIEND[2]
           and r.w < 300 and c[4] < 0.5 and c[4] > a then
            a = c[4]
        end
    end
    return a
end

preview.focus = "rail"
draw(preview)
local lit_rail = rail_wash()
preview.focus = "stage"
draw(preview)
local dim_rail = rail_wash()
check("the rail lights brighter while the arrows are in it",
      lit_rail > dim_rail and dim_rail > 0,
      lit_rail .. " against " .. dim_rail)
preview.focus = "rail"

-- --- a long list scrolls rather than stopping -----------------------------

local many = {}
for i = 1, 30 do
    many[i] = {label = "row" .. i, detail = "", index = i, pick = true}
end
st = draw({depth = 2, sel = 25,
           rail = RAIL, rail_sel = 1, focus = "stage", home = false,
           closable = true, rows = many})
check("a cursor near the end of a long list is on screen", has(st, "row25"),
      "drew: " .. table.concat(texts(st), " "))
-- And the other way it can go wrong: a list that draws every row regardless
-- puts most of them off the bottom of the screen, where they are as good as
-- skipped and cost vertices besides.
local below = 0
for i = 1, st.n do
    local t = st.text[i]
    -- state holds y counting up from the bottom, so off the bottom is y < 0
    if t.y < 0 or t.y > H then below = below + 1 end
end
check("and no row is drawn off the screen to get there", below == 0,
      below .. " lines outside")
st = draw({depth = 2, sel = 1,
           rail = RAIL, rail_sel = 1, focus = "stage", home = false,
           closable = true, rows = many})
check("and one at the start is too", has(st, "row1"))

-- --- the block stays on screen wherever it is pushed ----------------------

for _, shape in ipairs({{1280, 800}, {900, 600}, {700, 500}, {1600, 900},
                        {390, 844}, {844, 390}}) do
    draw({depth = 2, sel = 1,
          rail = RAIL, rail_sel = 1, focus = "stage", home = false,
          closable = true, rows = rows}, shape[1], shape[2])
    local x1, y1 = 0, 0
    for _, r in ipairs(rects) do
        x1 = math.max(x1, r.x + r.w)
        y1 = math.max(y1, r.y + r.h)
    end
    -- The backdrop is the whole screen, so the test is that nothing exceeds
    -- it rather than that everything is inside some margin.
    check(string.format("%dx%d keeps the menu on screen", shape[1], shape[2]),
          x1 <= shape[1] + 1 and y1 <= shape[2] + 1,
          string.format("reaches %.0f x %.0f", x1, y1))
end

-- --- settings draw as steps rather than words -----------------------------

local function setting(choice, choices)
    draw({depth = 2, sel = 1,
          rail = RAIL, rail_sel = 4, focus = "stage", home = false,
          closable = true,
          rows = {{label = "sound", detail = "half", choice = choice,
                   choices = choices, index = 1, pick = true}}})
    local steps, lit = 0, 0
    for _, f in ipairs(frames) do
        if math.abs(f.h - 10) < 0.01 then steps = steps + 1 end
    end
    for _, r in ipairs(rects) do
        if math.abs(r.h - 10) < 0.01 then lit = lit + 1 end
    end
    return steps, lit
end

local steps, lit = setting(2, 3)
check("a setting draws one step per value", steps + lit == 3,
      steps .. " outlined, " .. lit .. " filled")
check("and lights the one it is on", lit == 2, lit .. " filled")

-- Off is an empty range rather than the first value of one. A control that
-- lights a box for silence says it is doing a little of something while doing
-- none of it, and that is the state somebody sets deliberately and then comes
-- back to wondering about.
steps, lit = setting(0, 3)
check("a setting at nothing lights nothing", lit == 0 and steps == 3,
      steps .. " outlined, " .. lit .. " filled")

-- --- the way out is a mark, and only where there is a way out -------------
--
-- It was a word that said "back" from inside a page and "close" at the top,
-- which is one control doing two jobs under two names. The rail navigates
-- from every level, so what is left for this one is shutting the panel, and
-- with nothing behind the panel there is nothing to shut it onto.

local function closers()
    local n = 0
    for _, h in ipairs(ui.hits) do
        if h.action == "close" then n = n + 1 end
    end
    return n
end

-- What a press lands on, by the rule the arena uses: the first box published
-- that contains it.
local function press(x, y)
    for _, h in ipairs(ui.hits) do
        if x >= h.x and x <= h.x + h.w and y >= h.y and y <= h.y + h.h then
            return h.action
        end
    end
    return nil
end

local shut = {depth = 2, sel = 1,
              rail = RAIL, rail_sel = 1, focus = "stage", home = false,
              closable = true, rows = rows}
st = draw(shut)
check("a menu over a game carries a mark and the ground behind it",
      closers() == 2, closers() .. " published")
check("and no word for it", not has(st, "close") and not has(st, "back"),
      table.concat(texts(st), " "))

-- The x sits on the name's line rather than at the top of the stage: a
-- dialog's close belongs on its title, and here the title is the wordmark.
local logo_y
for i = 1, st.n do
    if is(st.text[i], "vectorwake") then logo_y = H - st.text[i].y end
end
local xbox
for _, h in ipairs(ui.hits) do
    if h.action == "close" and h.w < W then xbox = h end
end
check("the way out is on the name's line", logo_y and xbox
      and math.abs((xbox.y + xbox.h / 2) - logo_y) < 3,
      string.format("logo %.1f, mark %.1f", logo_y or -1,
                    xbox and (xbox.y + xbox.h / 2) or -1))

-- Off the panel is out of the menu, which is what escape does. On the panel
-- is not, or the space between two rows would throw a player back into the
-- fight.
check("a press off the panel is the way out", press(W - 8, H - 8) == "close",
      tostring(press(W - 8, H - 8)))
check("a press on the panel's own ground is not",
      press(W / 2, H / 2) ~= "close", tostring(press(W / 2, H / 2)))

shut.closable = false
draw(shut)
check("and none at all with nothing behind it", closers() == 0,
      closers() .. " published")
check("so a press off the panel does nothing there",
      press(W - 8, H - 8) == nil, tostring(press(W - 8, H - 8)))

-- --- the mark hangs off the column rather than moving it ------------------
--
-- The wedge that says "this is the game you are in" used to be drawn inline
-- and push its own label fifteen points right of every other label on the
-- page, so the one row worth finding was the one out of line with the rest.

local marked = draw({depth = 2, sel = 1,
                     rail = RAIL, rail_sel = 1, focus = "stage", home = false,
                     closable = true,
                     rows = {{label = "alpha", index = 1, pick = true,
                              mark = true},
                             {label = "chaos", index = 2, pick = true}}})
local ax, cx, hx
for i = 1, marked.n do
    local t = marked.text[i]
    if is(t, "alpha") then ax = t.x end
    if is(t, "chaos") then cx = t.x end
    if is(t, "zones") then hx = t.x end
end
check("a marked row keeps the column every other row is in",
      ax and cx and math.abs(ax - cx) < 0.01,
      string.format("marked at %s, plain at %s", tostring(ax), tostring(cx)))
-- And the page is named once, out on the rail. A title over the stage was the
-- same word twice on one screen, in the place the list could have used.
local names = 0
for i = 1, marked.n do
    if is(marked.text[i], "zones") then names = names + 1 end
end
check("the page is named on the rail and nowhere else", names == 1,
      names .. " times, at " .. tostring(hx))

-- --- a row that carries a sentence puts it in the row --------------------
--
-- The games are chosen between by reading them, and at the foot of the panel
-- they arrived one at a time, a screen away from the name each belonged to.
-- A row with a `note` gives it the lower half and takes the upper for
-- everything else, including the count on the right.

local noted = draw({depth = 2, sel = 1, rail = RAIL, rail_sel = 1,
                    focus = "stage", home = false, closable = true,
                    rows = {{label = "chaos", index = 1, pick = true,
                             players = 4, bots = 51, live = true,
                             note = "everybody against everybody"}}})
local name_x, name_y, note_x, note_y, count_y
for i = 1, noted.n do
    local t = noted.text[i]
    if is(t, "chaos") then name_x, name_y = t.x, t.y end
    if is(t, "everybody against everybody") then note_x, note_y = t.x, t.y end
    if is(t, "4") then count_y = t.y end
end
-- `state` counts y up from the bottom, so under means a smaller number.
check("a row's sentence sits under its name",
      name_y and note_y and name_y - note_y > 8,
      string.format("name at %s, sentence at %s", tostring(name_y),
                    tostring(note_y)))
check("and in the same column", name_x and note_x
      and math.abs(name_x - note_x) < 0.01,
      string.format("%s against %s", tostring(name_x), tostring(note_x)))
check("with the count still on the name's line",
      count_y and name_y and math.abs(count_y - name_y) < 1.5,
      string.format("count at %s, name at %s", tostring(count_y),
                    tostring(name_y)))

-- --- a long value does not run under the label it belongs to -------------
--
-- The help rows a phone gets are sentences, and right-aligned in a column
-- 350 points wide they came back under the word they describe.

local st2 = draw({depth = 2, sel = 1,
                  rail = RAIL, rail_sel = 5, focus = "stage",
                  home = false, closable = true,
                  rows = {{label = "steer", index = 1, pick = true,
                           detail = "left thumb: point where you want the nose"}}},
                 390, 844, true)
local lab, det
for i = 1, st2.n do
    local t = st2.text[i]
    if is(t, "steer") then lab = t end
    if string.upper(t.s):find("LEFT THUMB") then det = t end
end
-- A right-aligned string reports its right edge, so its left edge is that
-- less its width. Reading `x` as the left edge is how this check passed
-- against the very overlap it was written for.
local function left_of(t)
    local w = #t.s * t.px * 0.602
    if t.pivot == "right" then return t.x - w end
    if t.pivot == "center" then return t.x - w / 2 end
    return t.x
end
check("a long value clears the label it belongs to", lab and det and (
          math.abs(lab.y - det.y) > 4
          or left_of(det) - (lab.x + #lab.s * lab.px * 0.602) > 8),
      lab and det and string.format("label ends %.0f, value starts %.0f, dy %.0f",
          lab.x + #lab.s * lab.px * 0.602, left_of(det), math.abs(lab.y - det.y))
          or "not drawn")

-- --- a question stands the panel down and takes the taps with it ----------
--
-- The card is drawn last and the gui draws every glyph over every mesh, so
-- nothing laid on top of the list can cover it: the list is quieted where it
-- is written or not at all. And a hit box published before the card is a hit
-- box under it, which is a tap on a row nobody can see answering a question
-- about a different one.

local ask = {head = "you are already flying chaos", sel = 2,
             keys = {{label = "leave", act = "leave"}, {label = "stay"}}}
local st3 = draw({depth = 2, sel = 2, rail = RAIL, rail_sel = 1,
                  focus = "stage", home = false, closable = true,
                  rows = rows, ask = ask})

check("the question is drawn", has(st3, "you are already flying chaos"))
check("and its answers wear the keys the corner wears",
      has(st3, "LEAVE") and has(st3, "STAY"),
      table.concat(texts(st3), " "))

local loud, quiet = 0, 0
for i = 1, st3.n do
    local t = st3.text[i]
    if t.dim and t.dim < 0.2 then quiet = quiet + 1 else loud = loud + 1 end
end
check("the panel behind it is quieted, glyph by glyph", quiet > 4,
      quiet .. " quieted, " .. loud .. " left lit")
check("and the card itself is not", loud == 3, loud .. " lit")

local answers, others = 0, 0
for _, h in ipairs(ui.hits) do
    if h.action == "answer" then answers = answers + 1 else others = others + 1 end
end
check("only the answers can be pressed", answers == 2 and others == 0,
      answers .. " answers, " .. others .. " other boxes")

-- A question may be about a string rather than a choice. A device code is
-- read off this screen and typed into another machine, so it is drawn as
-- itself: big, lit, and in the case it was given.
local st4 = draw({depth = 2, sel = 1, rail = RAIL, rail_sel = 1,
                  focus = "stage", home = true, closable = false,
                  rows = rows,
                  ask = {head = "Type this on the other device", sel = 1,
                         code = "408317", keys = {{label = "done"}}}})
local code_t
for i = 1, st4.n do
    if st4.text[i].s == "408317" then code_t = st4.text[i] end
end
check("a question can carry a code, drawn as given", code_t ~= nil,
      table.concat(texts(st4), " "))
check("and drawn larger than what it is about",
      code_t and code_t.px > 20, code_t and tostring(code_t.px))

-- A question can also be lines to fill in. On a keyboard the client draws
-- them, since the keys are already under the player's hands. On a
-- touchscreen it hands the rectangles to the page instead, which lays real
-- input elements over them: a canvas is not editable and a browser raises
-- its keyboard for an editable element and for nothing else. The client
-- draws the label and the rule either way, because those are the card.
local ask_fields = {head = "Log in.", sel = 1, field = 2,
                    fields = {{label = "call sign", value = "Vesper 412",
                               kind = "username", max = 24},
                              {label = "password", value = "hunter2",
                               mask = true, kind = "current-password",
                               max = 64}},
                    keys = {{label = "log in", act = "do_login"},
                            {label = "cancel"}}}
ui.page_fields = false
local st_kb = draw({depth = 2, sel = 1, rail = RAIL, rail_sel = 1,
                    focus = "stage", home = true, closable = false,
                    rows = rows, ask = ask_fields})
check("a build with no page keeps its lines", ui.ask_dom == nil,
      tostring(ui.ask_dom))
-- Drawn, then: the name as itself, the password as discs, so the string
-- typed into it appears nowhere on the screen.
local said_name, said_pass = false, false
for i = 1, st_kb.n do
    if st_kb.text[i].s == "Vesper 412" then said_name = true end
    if string.find(st_kb.text[i].s, "hunter", 1, true) then said_pass = true end
end
check("the name line shows what is in it", said_name,
      table.concat(texts(st_kb), " "))
check("and the password line does not", not said_pass)

-- A line holds more than the rule under it can show. Sixty four characters
-- is what the server takes and what a manager generates, and pasting one in
-- used to draw every character: the run left the card and crossed the
-- screen. The end of it is what stays, because the end is where the caret is
-- and where the next character lands.
local long = string.rep("abcdefgh", 8)
local st_long = draw({depth = 2, sel = 1, rail = RAIL, rail_sel = 1,
                      focus = "stage", home = true, closable = false,
                      rows = rows,
                      ask = {head = "Log in.", sel = 1, field = 1,
                             fields = {{label = "call sign", value = long,
                                        kind = "username", max = 64}},
                             keys = {{label = "log in"}, {label = "cancel"}}}},
                     390, 844)
local drew
for i = 1, st_long.n do
    if string.find(st_long.text[i].s, "abcdefgh", 1, true) then
        drew = st_long.text[i].s
    end
end
check("a line longer than its rule is clipped", drew ~= nil and #drew < #long,
      tostring(drew and #drew) .. " of " .. #long)
check("and it is the end that stays", drew ~= nil
          and string.sub(long, #long - #drew + 1) == drew, tostring(drew))

ui.page_fields = true
local st5 = draw({depth = 2, sel = 1, rail = RAIL, rail_sel = 1,
                  focus = "stage", home = true, closable = false,
                  rows = rows, ask = ask_fields}, 390, 844, true)
check("a page is handed the lines", ui.ask_dom ~= nil, tostring(ui.ask_dom))
-- And on a machine with keys just the same. It was a touchscreen only at
-- first, on the argument that a desktop has the keys already; what that
-- argument left out is that a manager fills a form and cannot fill a
-- drawing, and that is the same on both.
draw({depth = 2, sel = 1, rail = RAIL, rail_sel = 1, focus = "stage",
      home = true, closable = false, rows = rows, ask = ask_fields},
     1280, 800, false)
check("a keyboard too, which is where the manager is",
      ui.ask_dom ~= nil and string.find(ui.ask_dom, ",username,", 1, true),
      tostring(ui.ask_dom))
draw({depth = 2, sel = 1, rail = RAIL, rail_sel = 1, focus = "stage",
      home = true, closable = false, rows = rows, ask = ask_fields},
     390, 844, true)
-- One per line, and each carrying the word that tells a password manager
-- which box it is looking at. Without those two the whole exercise buys
-- nothing that the drawn keyboard did not already have.
local spec = {}
for row in string.gmatch((ui.ask_dom or "") .. ";", "([^;]*);") do
    if row ~= "" then spec[#spec + 1] = row end
end
check("one element per line", #spec == 2, tostring(#spec))
check("each saying what it is for",
      spec[1] and string.find(spec[1], ",username,", 1, true) ~= nil
          and spec[2]
          and string.find(spec[2], ",current-password,", 1, true) ~= nil,
      table.concat(spec, " | "))
-- And placed where the rule was drawn, in the page's unit rather than the
-- drawing's: at two device pixels to the point a card laid out at 390
-- points would otherwise be published at twice its size, and the elements
-- would sit off the bottom of a card they belong on.
local l1, t1, w1 = string.match(spec[1] or "", "^([%d%.]+),([%d%.]+),([%d%.]+),")
check("in css pixels, on the card", tonumber(l1) and tonumber(l1) > 0
          and tonumber(l1) < 390 and tonumber(t1) and tonumber(t1) < 844
          and tonumber(w1) and tonumber(w1) < 390,
      tostring(l1) .. " " .. tostring(t1) .. " " .. tostring(w1))
local _, t2 = string.match(spec[2] or "", "^([%d%.]+),([%d%.]+),")
check("one line below the other", tonumber(t2) and tonumber(t1)
          and tonumber(t2) - tonumber(t1) == 48,
      tostring(t2) .. " - " .. tostring(t1))
-- Nothing of the value is drawn under an element holding it: two of
-- everything, half a frame apart, is what that would look like.
said_name, said_pass = false, false
for i = 1, st5.n do
    if st5.text[i].s == "Vesper 412" then said_name = true end
    if string.find(st5.text[i].s, "hunter", 1, true) then said_pass = true end
end
check("and the page's copy is the only copy", not said_name and not said_pass,
      table.concat(texts(st5), " "))
-- The labels stay ours, drawn in the interface's own face over the page's
-- boxes, so a card with elements on it is still the same card.
local said_label = false
for i = 1, st5.n do
    if string.upper(st5.text[i].s) == "CALL SIGN" then said_label = true end
end
check("the labels are still drawn", said_label, table.concat(texts(st5), " "))

-- A card asking only for a new password names the pilot it is for, so a
-- manager files the password against a call sign rather than against
-- nothing. It is not a line on the card: the name is not in question there.
local st6 = draw({depth = 2, sel = 1, rail = RAIL, rail_sel = 1,
                  focus = "stage", home = true, closable = false, rows = rows,
                  ask = {head = "Keep Vesper 412. Choose a password.",
                         sel = 1, field = 1, ghost = "Vesper 412",
                         fields = {{label = "password", value = "",
                                    mask = true, kind = "new-password",
                                    max = 64}},
                         keys = {{label = "keep", act = "do_claim"},
                                 {label = "cancel"}}}}, 390, 844, true)
check("a claim carries the name it claims",
      string.find(ui.ask_dom or "", "|Vesper 412", 1, true) ~= nil,
      tostring(ui.ask_dom))
check("and asks for a new password rather than the held one",
      string.find(ui.ask_dom or "", ",new-password,", 1, true) ~= nil,
      tostring(ui.ask_dom))
check("and draws no second line for the name", st6 ~= nil
          and select(2, string.gsub(ui.ask_dom or "", ";", "")) == 0,
      tostring(ui.ask_dom))

-- --- the rail lights under a pointer, as the stage does -------------------
--
-- The stage has worn a hover since the home screen was two panes. The rail is
-- the other half of the same gesture and went without one, so a mouse walking
-- down it lit nothing until it was clicked. Counted as a field in the rail's
-- own column, which is a third the width of a stage row's.

-- Wider than a mark and narrower than a stage row. The lower bound is not
-- fussiness: several icons are drawn from rectangles, the settings sliders
-- among them, and they take the stop's color when it lights, so counting
-- every blue rectangle in the rail counts the drawing as well as the field.
local function rail_fields()
    local n = 0
    for _, r in ipairs(rects) do
        local c = r.col
        if c and c[1] == pal.FRIEND[1] and c[2] == pal.FRIEND[2]
           and c[4] > 0.12 and r.w > 60 and r.w < 300 then
            n = n + 1
        end
    end
    return n
end

local rail_view = {depth = 2, sel = 1, rail = RAIL, rail_sel = 1,
                   focus = "stage", home = true, closable = false,
                   rows = rows}
draw(rail_view)
local plain = rail_fields()
rail_view.rail_hover = 4
draw(rail_view)
check("a stop under the pointer wears a field of its own",
      rail_fields() == plain + 1,
      plain .. " without a hover, " .. rail_fields() .. " with one")

-- The stop you are already in is lit for a different reason and does not get
-- a second wash laid over the first.
rail_view.rail_hover = 1
draw(rail_view)
check("and the lit stop is not lit twice", rail_fields() == plain,
      tostring(rail_fields()))
rail_view.rail_hover = nil


-- --- the controls page fits on the device it was written for --------------
--
-- It is the longest page the menu has, and it grew: the touch rows come from
-- arena/controls.lua now, a dozen of them against the five somebody kept by
-- hand. A dozen two-line rows on a phone held sideways is the case that
-- decides whether that was a good idea, and no other check here covers it,
-- since the rest draw three rows and a rail.

do
    local binds = require("arena.binds")
    local pad_rows = {}
    for _, c in ipairs(binds.rows()) do
        if c.pad then
            pad_rows[#pad_rows + 1] = {label = c.pad_name or c.name,
                                       detail = c.pad}
        end
    end
    -- A phone held sideways, in drawable pixels at two per point, which is
    -- the shortest window this interface is laid out for.
    local hh = 390 * 2
    local page = draw({depth = 2, sel = 0, rail = RAIL, rail_sel = 1,
                     focus = "rows", home = false, closable = true,
                     rows = pad_rows}, 844 * 2, hh, true)
    local off = nil
    for i = 1, page.n do
        local t = page.text[i]
        if t.y < 0 or t.y > hh then
            off = string.format("%q at y %.0f", t.s, t.y)
        end
    end
    check("every controls row fits a phone held sideways", off == nil, off)
    local drawn = 0
    for _, r in ipairs(pad_rows) do
        for i = 1, page.n do
            if string.upper(page.text[i].s) == string.upper(r.label) then
                drawn = drawn + 1
                break
            end
        end
    end
    check("and every one of them is drawn", drawn == #pad_rows,
          drawn .. " of " .. #pad_rows)
end

-- --- the page is told where to put the link -------------------------------
--
-- The stop that leaves the game is a real anchor laid over the canvas by the
-- page, because a tab opened a frame after a tap is a popup as far as every
-- phone is concerned. What the client owes the page is where that stop landed
-- and where it goes, in the CSS pixels the page lays out in.

do
    local RAIL2 = {}
    for i, n in ipairs({"zones", "ship", "pilot", "settings", "controls",
                        "discord", "about"}) do
        RAIL2[i] = {label = n, icon = n, index = i}
    end
    RAIL2[6].link = "https://play.vectorwake.net/discord"

    for _, shape in ipairs({{1280, 800, 1}, {844 * 2, 390 * 2, 2}}) do
        draw({depth = 1, sel = 1, rail = RAIL2, rail_sel = 1, focus = "rail",
              home = true, closable = false, rows = {}},
             shape[1], shape[2], shape[3] == 2)
        local box = ui.link_dom
        check(string.format("%dx%d publishes a link box", shape[1], shape[2]),
              box ~= nil, "none")
        if box then
            local x, y, w, h, url =
                box:match("^([%d%.%-]+),([%d%.%-]+),([%d%.%-]+),([%d%.%-]+),(.+)$")
            check("  and it parses into a box and an address",
                  x and url == "https://play.vectorwake.net/discord",
                  tostring(box))
            -- Big enough for a finger, and inside the window it is drawn in.
            -- ui.lua publishes CSS pixels by dividing by the density, and
            -- this harness always draws at one, so here the two are the same
            -- number and the window is compared as given.
            if x then
                x, y, w, h = tonumber(x), tonumber(y), tonumber(w), tonumber(h)
                check("  and it is a target a thumb can hit",
                      w >= 24 and h >= 24,
                      string.format("%.0f by %.0f", w, h))
                check("  and it is on the screen",
                      x >= -1 and y >= -1
                      and x + w <= shape[1] + 1 and y + h <= shape[2] + 1,
                      string.format("%.0f,%.0f %.0fx%.0f in %dx%d",
                                    x, y, w, h, shape[1], shape[2]))
            end
        end
    end

    -- And nothing is published when no stop on the rail is a link, or the
    -- page would keep an invisible anchor over a menu that has none.
    draw({depth = 1, sel = 1, rail = RAIL, rail_sel = 1, focus = "rail",
          home = true, closable = false, rows = {}}, 1280, 800)
    check("a rail with no link publishes none", ui.link_dom == nil,
          tostring(ui.link_dom))

    -- And the two halves of the crossing still know each other's name.
    --
    -- The anchor is a real element over the canvas, so while the pointer is
    -- on it the canvas is not what the browser is pointing at: no movement
    -- reaches the engine, the drawn cursor freezes, and the flag that hides
    -- it when a pointer leaves the canvas has already been set. The stop lit
    -- and went out as the pointer crossed the edge of the element that exists
    -- to make it pressable. The page reports the position instead, and this
    -- is the only place a rename can be caught: nothing in Lua can call it.
    local tf = io.open("client/web/engine_template.html")
    local tpl = tf and tf:read("*a") or ""
    if tf then tf:close() end
    local af = io.open("client/arena/arena.script")
    local arena = af and af:read("*a") or ""
    if af then af:close() end
    check("the page reports where the pointer is over the link",
          tpl:find("window.vwLinkAt", 1, true) ~= nil
          and tpl:find("window.vwPointerOut = false", 1, true) ~= nil,
          "engine_template.html no longer answers for the anchor")
    check("and the arena asks it",
          arena:find("vwLinkAt", 1, true) ~= nil,
          "arena.script no longer polls it")
end

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
