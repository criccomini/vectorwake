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
local frames, rects, segs, outlines = {}, {}, {}, {}
local harness = require("tests.ui_harness")
local layer = harness.layer()
-- A selection is a skirt now rather than a rectangle: bright where it meets
-- the panel's rule and gone across the row. It is counted with the rectangles
-- because what these checks ask is "how many rows are lit", which is a
-- question about the mark and not about which primitive drew it.
layer.skirt = function(_, x, y0, _x1, y1, w, _fade, alpha, col)
    local top, bot = math.min(y0, y1), math.max(y0, y1)
    rects[#rects + 1] = {x = x, y = H - bot, w = w, h = bot - top,
                         col = {col[1], col[2], col[3], alpha or col[4]}}
end
layer.frame = function(_, x, y, w, h)
    frames[#frames + 1] = {x = x, y = H - y - h, w = w, h = h}
end
layer.rect = function(_, x, y, w, h, col)
    rects[#rects + 1] = {x = x, y = H - y - h, w = w, h = h, col = col}
end
layer.seg = function(_, x0, y0, x1, y1, w, col)
    segs[#segs + 1] = {x0 = x0, y0 = y0, x1 = x1, y1 = y1, w = w, col = col}
end
layer.outline = function(_, pts)
    outlines[#outlines + 1] = pts
end

local ui = harness.install()
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
    frames, rects, segs, outlines = {}, {}, {}, {}
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

-- Whether any line the page drew carries this inside it. `has` asks for a
-- whole string, which is the right question about a heading and the wrong one
-- about a figure and its word set as one piece of type.
local function says(st, s)
    for _, t in ipairs(texts(st)) do
        if t:find(string.upper(s), 1, true) then return true end
    end
    return false
end

-- What the last draw published, by action. `ui.hits` is rebuilt every draw,
-- so these read whichever one just ran.
local function hit_named(action)
    for _, h in ipairs(ui.hits) do
        if h.action == action then return h end
    end
    return nil
end

local function actions()
    local out = {}
    for _, h in ipairs(ui.hits) do out[#out + 1] = h.action end
    return out
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

-- --- a button is a shape, not a line of the list --------------------------
--
-- The Discord row is drawn as a button because it is the one thing on the play
-- page that is not a place inside the game. A press has to land on the button:
-- published across the whole row, as every other row's is, the shape would be
-- decoration over a line that still behaved like a line.
do
    local btn = {label = "Talk on Discord", index = 1, pick = true,
                 button = "discord", detail = ""}
    draw({depth = 2, sel = 1, rail = RAIL, rail_sel = 1, focus = "stage",
          home = true, closable = false, rows = {btn}})
    local box = nil
    for _, h in ipairs(ui.hits) do
        if h.action == "stage" and h.value == 1 then box = h end
    end
    check("the button publishes a box", box ~= nil)
    check("narrower than the row it sits in", box and box.w < W * 0.5,
          box and string.format("%.0f of %d", box.w, W) or "none")
    check("and no taller than a row", box and box.h <= 60, box and box.h)
end

-- --- the call sign in the corner takes a press ----------------------------
--
-- It is the only way to the pilot page: there is no stop for it on the tab
-- row. The box under it went out as "pilot", which the scoreboard's own rows
-- already publish for the card about one of them, and the press dispatch
-- reads that one first: the name lit under the pointer and answered nothing.
local corner = draw({depth = 1, sel = 0, rail = RAIL, rail_sel = 1,
                     focus = "rail", home = true, closable = false,
                     rows = rows,
                     pilot = {name = "Tiller 963", rivets = 40}})
check("the corner says who is reading", has(corner, "Tiller 963"))
local named, clashed = nil, false
for _, h in ipairs(ui.hits) do
    if h.action == "pilot" then clashed = true end
    -- Small, on the column's head line, at the right-hand end of it. Of the
    -- column rather than of the window: the menu is one column docked to the
    -- left edge, so the far end of the head is a few hundred points in and
    -- not three quarters of the way across a monitor.
    if h.w < 200 and h.h < 60 and h.y < 120 and h.x > 150 and h.x < 390 then
        named = h.action
    end
end
check("and publishes a box under it", named ~= nil, tostring(named))
check("under an action the arena does not already spend on something else",
      not clashed, "the menu published a hit as \"pilot\"")
check("the stage shows what the rail points at", has(st, "zone1"))

-- The mark renderer is a separate drawing family. Run every supported mark
-- through the real rail so its frame, palette, shared hull drawings, and hit
-- publication are covered together rather than with a source-text guard.
do
    local all = {}
    local names = {"zones", "ship", "pilot", "team", "settings", "controls",
                   "discord", "about", "friends", "standings", "upgrades",
                   "leave"}
    for i, name in ipairs(names) do
        all[i] = {label = name, icon = name, index = i}
    end
    draw({depth = 1, sel = 0, rail = all, rail_sel = 1, focus = "rail",
          home = true, closable = false, rows = rows}, 1280, 1400)
    local hits = 0
    for _, box in ipairs(ui.hits) do
        if box.action == "rail" then hits = hits + 1 end
    end
    check("every supported destination mark renders in the rail",
          hits == #all, hits .. " of " .. #all)
end

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
-- Both halves mark their cursor the same way, so the one wearing the brighter
-- of the two is the whole of the answer to what up and down will move. Read
-- off the field behind the tab you are in, which is the tab row's own mark.
-- It used to be a rule under the word, drawn either side of the focus; the
-- field replaced it, and a field with a line under it is one mark too many.

local function rail_wash()
    local a = 0
    for _, r in ipairs(rects) do
        local c = r.col
        -- The tab row's own band, which is the only blue field at the foot of
        -- the column: a stage row's cursor is further up the screen.
        if c and c[1] == pal.FRIEND[1] and c[2] == pal.FRIEND[2]
           and r.y > H - 120 and (c[4] or 1) > a then
            a = c[4] or 1
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

-- A range step is the small 13 by 10 box in the rendered row. Match its
-- proportions rather than reading the renderer's scale constant out of its
-- source, so changing the menu zoom changes the measurement and the drawing
-- together.
local function is_step(box)
    return box.h > 0 and box.h < 24
           and math.abs(box.w / box.h - 1.3) < 0.01
end

local function setting(choice, choices)
    draw({depth = 2, sel = 1,
          rail = RAIL, rail_sel = 4, focus = "stage", home = false,
          closable = true,
          rows = {{label = "sound", detail = "half", choice = choice,
                   choices = choices, index = 1, pick = true}}})
    local steps, lit = 0, 0
    for _, f in ipairs(frames) do
        if is_step(f) then steps = steps + 1 end
    end
    for _, r in ipairs(rects) do
        if is_step(r) then lit = lit + 1 end
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

-- The x sits on the head's own line, at the panel's left inset, where the
-- key that opened the drawer stands: pressing the key and pressing the x are
-- one control seen from either side. The wordmark used to share that line
-- and does not any more.
local xbox
for _, h in ipairs(ui.hits) do
    if h.action == "close" and h.w < W then xbox = h end
end
check("the way out is at the head's left", xbox and xbox.x < 60,
      xbox and string.format("%.0f", xbox.x) or "none")
check("and the head carries no wordmark", not has(st, "vectorwake"),
      table.concat(texts(st), " "))

-- Off the panel is out of the menu, which is what escape does. On the panel
-- is not, or the space between two rows would throw a player back into the
-- fight.
check("a press off the panel is the way out", press(W - 8, H - 8) == "close",
      tostring(press(W - 8, H - 8)))
check("a press on the panel's own ground is not",
      press(120, H / 2) ~= "close", tostring(press(120, H / 2)))
-- And the fight beside the column is off the panel, which is the whole point
-- of docking it: the game is showing there, and a press on a game means put
-- me back in it.
check("the fight beside the column is a way out too",
      press(W / 2, H / 2) == "close", tostring(press(W / 2, H / 2)))

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
-- A row with a `note` gives it the lower half and takes the upper for the
-- name. The count that used to sit on the name's line is gone with the rest
-- of what the play page was told about a room's population.

local noted = draw({depth = 2, sel = 1, rail = RAIL, rail_sel = 1,
                    focus = "stage", home = false, closable = true,
                    rows = {{label = "chaos", index = 1, pick = true,
                             live = true,
                             note = "everybody against everybody"}}})
local name_x, name_y, note_x, note_y
for i = 1, noted.n do
    local t = noted.text[i]
    if is(t, "chaos") then name_x, name_y = t.x, t.y end
    if is(t, "everybody against everybody") then note_x, note_y = t.x, t.y end
end
-- `state` counts y up from the bottom, so under means a smaller number.
check("a row's sentence sits under its name",
      name_y and note_y and name_y - note_y > 8,
      string.format("name at %s, sentence at %s", tostring(name_y),
                    tostring(note_y)))
check("and in the same column", name_x and note_x
      and math.abs(name_x - note_x) < 0.01,
      string.format("%s against %s", tostring(name_x), tostring(note_x)))

-- --- a tab's field is centered on its stop --------------------------------
--
-- The row is marks with a word under each, laid out on an even pitch, and the
-- lit field is the stop's own share of that pitch. It used to be a row of
-- words on a desktop with the field measured off the word's width in a face
-- that was not the one it was drawn in, so every word sat left of the middle
-- of its own field.
do
    local tabs = draw({depth = 1, sel = 1, rail = RAIL, rail_sel = 4,
                       focus = "rail", home = true, rows = {}}, 1280, 800)
    local word
    for i = 1, tabs.n do
        local t = tabs.text[i]
        if string.lower(t.s) == "team" and t.pivot == "center" then word = t end
    end
    -- The field behind it: team blue, running the height of the tab row
    -- rather than the height of a list row.
    local field
    for _, r in ipairs(rects) do
        local c = r.col
        if c and c[1] == pal.FRIEND[1] and c[2] == pal.FRIEND[2]
           and word and r.x < word.x and r.x + r.w > word.x
           and r.h > 50 then
            field = r
        end
    end
    check("the tab you are on has a field behind it",
          word ~= nil and field ~= nil,
          tostring(word and word.s) .. "/" .. tostring(field and field.w))
    if word and field then
        -- A centered word reports its own middle, so this is one subtraction
        -- rather than a width measured in a face nothing here draws in.
        check("and the word sits on the middle of it",
              math.abs(word.x - (field.x + field.w / 2)) < 1.5,
              string.format("word at %.1f, field middle %.1f",
                            word.x, field.x + field.w / 2))
    end
end

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
-- The stage has worn a hover since the home screen was two panes. The tab row
-- is the other half of the same gesture and went without one, so a mouse
-- walking along it lit nothing until it was clicked. Counted as fields behind
-- the words: the tab you are in wears one and the one under the pointer wears
-- a fainter one, so a row with a hover on it carries two rather than one.
local function rail_fields()
    local n = 0
    for _, r in ipairs(rects) do
        local c = r.col
        if c and c[1] == pal.FRIEND[1] and c[2] == pal.FRIEND[2]
           and r.y > H - 120 and r.w > 20 and r.w < 200 then
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

end

-- --- the week's table -----------------------------------------------------
--
-- A `won` column stood at the end of this with a zero in every cell, because
-- nothing files a match result. What is here instead is what the log actually
-- holds.
--
-- There was also a card down the right hand side saying more about whichever
-- row the cursor was on, and every line in it was a column this table could
-- carry instead. It is columns now, and the quarter of the page the card took
-- is what pays for them.
do
    local week = draw({
        depth = 2, sel = 2, rail = RAIL, rail_sel = 1, focus = "stage",
        home = true, closable = false, page = "week",
        pilot = {name = "Vantage 7", rivets = 12},
        table = true,
        week = {sort = "kills", filter = "", back = 0, since = ""},
        rows = {
            {label = "Halcyon 1", rank = 1, kills = 9, deaths = 3, assists = 6,
             kd = 3, run = 4, banked = 180, rating = 1240, swing = 29,
             played = "22m", index = 1, pick = true},
            {label = "Vantage 7", rank = 2, kills = 5, deaths = 4, assists = 1,
             kd = 1.25, run = 2, banked = 90, rating = 1190, swing = -12,
             played = "8m", index = 2, pick = true, mark = true},
        },
    })
    check("the table says nothing about matches won", not has(week, "won"),
          table.concat(texts(week), " "))
    -- Each figure and the word for it are one string in the packed row, which
    -- is the only row this table has now: the menu is one column at a phone's
    -- measure, so the wide table of separate columns has no window to be
    -- drawn on. `says` is what asks for a piece of one.
    check("and carries deaths and time instead",
          says(week, "3 deaths") and says(week, "22m time"),
          table.concat(texts(week), " "))
    -- Every line the card used to hold, as a figure on the row beside it.
    check("the ratio is a column now", says(week, "3.00 k/d"),
          table.concat(texts(week), " "))
    check("and so is the best run", says(week, "4 streak"),
          table.concat(texts(week), " "))
    -- Kills a pilot was part of and did not finish. A hull rarely comes apart
    -- to one pilot's fire, and two columns told whoever did four fifths of
    -- the work and lost the last shot that they had done nothing.
    check("assists are a column beside the two they belong with",
          says(week, "6 assists"),
          table.concat(texts(week), " "))
    -- Two different facts, and the table wants both: what somebody is rated
    -- at, and what this week did to it.
    check("a rating is what a pilot is rated at",
          says(week, "1240 rating"),
          table.concat(texts(week), " "))
    check("and the rating change says what the week did to it",
          says(week, "+29 rating change") and says(week, "-12 rating change"),
          table.concat(texts(week), " "))
    -- The week's earnings, and the word for them. "Earned" keeps this separate
    -- from the balance left after purchases.
    check("what the week paid is earned",
          says(week, "180 earned"),
          table.concat(texts(week), " "))
    -- Nothing falls off the end of the row. It used to stop at the end of the
    -- first line, which lost the last four figures in a column this narrow.
    check("and nothing a pilot could sort by is missing from the row",
          says(week, "180 earned") and says(week, "22m time")
              and says(week, "1240 rating"),
          table.concat(texts(week), " "))
    check("and there is no card beside any of it",
          not has(week, "your week") and not has(week, "kills per death"),
          table.concat(texts(week), " "))
    -- Which way the sorted column runs is a triangle, not a caret and a
    -- letter v. Those were the two characters nearest the shape and read as
    -- exactly what they are at nine points. Checked as an absence, because
    -- the mark itself is geometry and nothing this test reads can see it: the
    -- head is the bare word and the direction is drawn.
    local heading = nil
    for _, t in ipairs(texts(week)) do
        if string.lower(t) == "kills" then heading = t end
    end
    check("the sorted head is the word alone", heading ~= nil,
          table.concat(texts(week), " "))
    check("with no caret or vee standing in for an arrow",
          not has(week, "^") and not has(week, "kills v"),
          table.concat(texts(week), " "))

    -- A guest has no account to keep a rating under, and a zero drawn as a
    -- number would read as a very bad pilot rather than as nobody's rating.
    local guest = draw({
        depth = 2, sel = 1, rail = RAIL, rail_sel = 1, focus = "stage",
        home = true, closable = false, page = "week",
        pilot = {name = "Vantage 7", rivets = 12},
        table = true,
        week = {sort = "kills", filter = "", back = 0, since = ""},
        rows = {
            {label = "Halcyon 1", rank = 1, kills = 9, deaths = 3, assists = 2,
             kd = 3, run = 4, banked = 180, rating = 0, swing = 5,
             played = "22m", index = 1, pick = true},
        },
    })
    check("an unrated pilot is drawn as nothing, not as zero",
          says(guest, "- rating") and not says(guest, "0 rating"),
          table.concat(texts(guest), " "))
end

-- --- the week steps the way it points --------------------------------------
--
-- `week_back` counts weeks behind the one running, so the arrow pointing left
-- asks for one more of them. Both arrows once published the direction they
-- pointed, which is the opposite, and both were dead: left asked to go
-- forward from the week that is running and right was drawn dark until you
-- were already back.
do
    local wk = function(back)
        return draw({
            depth = 2, sel = 1, rail = RAIL, rail_sel = 1, focus = "stage",
            home = true, closable = false, page = "week",
            pilot = {name = "Vantage 7", rivets = 12}, table = true,
            week = {sort = "kills", filter = "", back = back, since = ""},
            rows = {{label = "Halcyon 1", rank = 1, kills = 9, deaths = 3,
                     kd = 3, run = 4, banked = 180, rating = 1240, swing = 29,
                     played = "22m", index = 1, pick = true}},
        })
    end
    local function offered()
        local out = {}
        for _, h in ipairs(ui.hits) do
            if h.action == "week" then out[#out + 1] = h.value end
        end
        table.sort(out)
        return out
    end
    wk(0)
    local one = offered()
    check("the week that is running offers one step, and it goes back",
          #one == 1 and one[1] == 1, table.concat(one, "/"))
    wk(2)
    local both = offered()
    check("and a week already back offers both ways",
          #both == 2 and both[1] == -1 and both[2] == 1,
          table.concat(both, "/"))

    -- A week nobody played says so under its own heading. Drawn instead of
    -- the page, as it was, the line carrying the way to another week goes
    -- with it and a pilot who stepped back one week could not step forward.
    local bare = draw({
        depth = 2, sel = 1, rail = RAIL, rail_sel = 1, focus = "stage",
        home = true, closable = false, page = "week",
        pilot = {name = "Vantage 7", rivets = 12}, table = true,
        week = {sort = "kills", filter = "", back = 2, since = "Aug 3"},
        rows = {},
        empty = {head = "nobody played that week",
                 line = "the weeks before it are still there"},
    })
    check("an empty week still says which week it is",
          has(bare, "week of Aug 3") and has(bare, "nobody played that week"),
          table.concat(texts(bare), " "))
    check("and still offers the way out of it", #offered() == 2,
          table.concat(actions(), " "))
end

-- --- the filter is a box ---------------------------------------------------
--
-- It was a dim line of type at the end of the rule saying "type to filter",
-- which is a control that looks like a caption. On glass there is no keyboard
-- to find it with at all.
do
    local empty = draw({
        depth = 2, sel = 1, rail = RAIL, rail_sel = 1, focus = "stage",
        home = true, closable = false, page = "week",
        pilot = {name = "Vantage 7", rivets = 12}, table = true,
        week = {sort = "kills", filter = "", back = 0, since = ""},
        rows = {{label = "Halcyon 1", rank = 1, kills = 9, deaths = 3,
                 kd = 3, run = 4, banked = 180, rating = 1240, swing = 29,
                 played = "22m", index = 1, pick = true}},
    })
    check("the empty box says what it takes",
          has(empty, "filter by pilot"), table.concat(texts(empty), " "))
    check("and it is a thing to press",
          hit_named("filter_box") ~= nil, table.concat(actions(), " "))
    check("with nothing to clear yet",
          hit_named("filter_wipe") == nil, table.concat(actions(), " "))

    local typed = draw({
        depth = 2, sel = 1, rail = RAIL, rail_sel = 1, focus = "stage",
        home = true, closable = false, page = "week",
        pilot = {name = "Vantage 7", rivets = 12}, table = true,
        week = {sort = "kills", filter = "hal", filter_on = true,
                back = 0, since = ""},
        rows = {{label = "Halcyon 1", rank = 1, kills = 9, deaths = 3,
                 kd = 3, run = 4, banked = 180, rating = 1240, swing = 29,
                 played = "22m", index = 1, pick = true}},
    })
    check("what was typed is in the box",
          has(typed, "hal") and not has(typed, "filter by pilot"),
          table.concat(texts(typed), " "))
    check("and there is a way to empty it",
          hit_named("filter_wipe") ~= nil, table.concat(actions(), " "))
    -- The mark sits inside the box, and hit boxes are tested in the order
    -- they went out with the first one winning. Published the other way round
    -- the box swallows every press on its own mark.
    local wipe, box
    for i, h in ipairs(ui.hits) do
        if h.action == "filter_wipe" and not wipe then wipe = i end
        if h.action == "filter_box" and not box then box = i end
    end
    check("and the mark is reachable inside the box it sits in",
          wipe and box and wipe < box,
          tostring(wipe) .. " against " .. tostring(box))
end

-- --- the ship page is a ship and its thirty points ------------------------
--
-- Two columns stood to the left of the kit: every hull as a row, and a panel
-- carrying a role, a sentence and three footprint numbers. That is two thirds
-- of a page spent on a choice made once and on reference material, so it is a
-- drawing with arrows either side of it now.
--
-- What is pinned is what a player uses: the head names the build, the ship is
-- named where it is chosen, and the numbers that belonged to a spec sheet are
-- gone.
--
-- The ship stood in that head once, with an arrow either side. It was the
-- second hull selector on one page, and the head of a page about thirty
-- points is where the build's own name belongs.
do
    local ROWS = {
        {label = "Screen", group = "band", act = "builds", verbatim = true,
         state = "edited", index = 1},
        {label = "points", group = "band", act = "points", index = 2},
        {label = "energy", group = "flight", sect = "flight", short = "en",
         choice = 2, choices = 6, owned = 6, arena_max = 8, index = 3},
        {label = "gun spray", group = "weapons", sect = "gun", trigger = 0,
         mod = 0, ladder = true, choice = 1, choices = 2, owned = 2,
         arena_max = 5, price = 40, afford = true, index = 4},
        {label = "hull", group = "flair", sect = "flair", ship = true,
         verbatim = true, detail = "Cipher", choice = 1, choices = 2,
         index = 5},
        {label = "save", group = "save", act = "save_kit", index = 6},
    }
    local hangar = draw({
        depth = 2, sel = 3, rail = RAIL, rail_sel = 1, focus = "stage",
        home = true, closable = true, page = "kit", headless = true,
        kit = true, profile = {name = "Screen", state = "edited"},
        kit_spent = 28, kit_total = 30,
        rows = ROWS,
    })
    check("the band names the build", has(hangar, "screen"),
          table.concat(texts(hangar), " "))
    check("and says it has been tuned away from it", has(hangar, "edited"),
          table.concat(texts(hangar), " "))
    -- The figure a builder mid-edit is after is what is left, not a ratio to
    -- subtract before it says anything.
    check("the points are a meter and what is left of them",
          says(hangar, "2 left") and has(hangar, "points"),
          table.concat(texts(hangar), " "))
    check("with no head over any of it, and no wordmark",
          not has(hangar, "vectorwake"), table.concat(texts(hangar), " "))
    check("the sections name themselves", has(hangar, "flight")
          and has(hangar, "gun") and has(hangar, "flair"),
          table.concat(texts(hangar), " "))
    check("the page names the ship", has(hangar, "cipher"),
          table.concat(texts(hangar), " "))
    check("and says which of them it is", has(hangar, "1 of 2"),
          table.concat(texts(hangar), " "))
    -- The one price on the page, on the row it belongs to. It is the whole
    -- of what the shelf's own tab used to be for.
    check("a row with a rung left to sell carries its price",
          says(hangar, "40"), table.concat(texts(hangar), " "))
    check("and the key that keeps the build stands at the foot",
          has(hangar, "save"), table.concat(texts(hangar), " "))
    -- Pressing the name, or the part of the ladder nobody owns, is the same
    -- question; the circles this account owns keep their own presses.
    check("the name and the row past the ladder open the reading",
          hit_named("read_row") ~= nil, "no reading")
    check("and the circles it owns spend a point where they are pressed",
          hit_named("kit_at") ~= nil, "no ladder")

    -- The kit a build is exactly is a kit with nothing to keep, so no key.
    local kept = draw({
        depth = 2, sel = 3, rail = RAIL, rail_sel = 1, focus = "stage",
        home = true, closable = true, page = "kit", headless = true,
        kit = true, profile = {name = "Screen"},
        kit_spent = 30, kit_total = 30,
        rows = {ROWS[1], ROWS[2], ROWS[3], ROWS[5]},
    })
    check("a build that is exactly its own name offers no save key",
          not has(kept, "save"), table.concat(texts(kept), " "))
    check("and says nothing about being edited",
          not has(kept, "edited"), table.concat(texts(kept), " "))
end

-- --- the library, behind the band's name ----------------------------------
--
-- Every build this pilot can fly, with two keys under it and nothing else.
-- Saving is at the foot of the ship page where the kit that earned it is,
-- and renaming went with it.
do
    local builds = draw({
        depth = 3, sel = 2, rail = RAIL, rail_sel = 1, focus = "stage",
        home = true, closable = true, page = "builds", headless = true,
        builds = true,
        rows = {
            {label = "Gunner", group = "builds", verbatim = true,
             starter = true, choice = 0, choices = 1, index = 1},
            {label = "Screen", group = "builds", verbatim = true,
             choice = 1, choices = 1, index = 2},
            {label = "new", group = "keys", act = "new_build", index = 3},
            {label = "delete", group = "keys", act = "delete_profile",
             index = 4},
        },
    })
    check("the library carries every build", has(builds, "gunner")
          and has(builds, "screen"), table.concat(texts(builds), " "))
    check("with the three the game ships marked as its own",
          has(builds, "starter"), table.concat(texts(builds), " "))
    check("and two keys under them, and nothing that renames one",
          has(builds, "new") and has(builds, "delete")
          and not has(builds, "rename"),
          table.concat(texts(builds), " "))
    check("every row of it takes a press", hit_named("stage") ~= nil,
          "no rows")
    check("and the way back is on the line the x is on",
          hit_named("back") ~= nil, "no way back")
end

-- --- naming a new build ---------------------------------------------------
do
    local naming = draw({
        depth = 4, sel = 1, rail = RAIL, rail_sel = 1, focus = "stage",
        home = true, closable = true, page = "newbuild", headless = true,
        newbuild = true, new = {name = "Screen 2", on = true}, rows = {},
    })
    check("the naming page says what it is for",
          has(naming, "new build"), table.concat(texts(naming), " "))
    check("with the name in a box that takes type",
          says(naming, "Screen 2") and hit_named("new_field") ~= nil,
          table.concat(texts(naming), " "))
    check("and one key, which makes it", has(naming, "create")
          and hit_named("create_build") ~= nil,
          table.concat(texts(naming), " "))
end

-- --- what the thirty points are -------------------------------------------
do
    local points = draw({
        depth = 3, sel = 1, rail = RAIL, rail_sel = 1, focus = "stage",
        home = true, closable = true, page = "points", headless = true,
        points = true, kit_spent = 28, kit_total = 30, rows = {},
    })
    check("the points page says what the thirty are",
          has(points, "thirty points"), table.concat(texts(points), " "))
    check("and spells the meter out", says(points, "28 spent"),
          table.concat(texts(points), " "))
    check("and teaches the circle a slot's ladder is drawn in",
          says(points, "equipped") and says(points, "owned")
          and says(points, "not yours yet"),
          table.concat(texts(points), " "))
end

-- --- a page that overflows can be scrolled to the end of itself ------------
--
-- The scroll was clamped against the stage rectangle while the pages that
-- overflow are handed a shorter box that starts under the heading. Every one
-- of them stopped 56 points short on a phone: a week with a dozen pilots on
-- it would not move at all, and a longer one would not reach its last row.
-- Both were reported as the standings not scrolling.
--
-- Measured rather than looked at, because the difference is a heading's worth
-- of pixels and it looks like the page simply ending.
do
    local function week_rows(n)
        local out = {}
        for i = 1, n do
            out[i] = {label = "Pilot " .. i, rank = i, kills = n - i,
                      deaths = 1, kd = 1, run = 2, banked = 10 * i,
                      rating = 1200, swing = 3, played = "9m", index = i,
                      pick = true}
        end
        return out
    end
    local function week_view(n)
        return {depth = 2, sel = 1, rail = RAIL, rail_sel = 1,
                focus = "stage", home = true, closable = false,
                at = "standings", table = true,
                pilot = {name = "Vantage 7", rivets = 0},
                week = {sort = "kills", filter = "", back = 0, since = ""},
                rows = week_rows(n)}
    end

    -- The window a page publishes is its own, and it is shorter than the
    -- stage. Clamping against the stage is what lost the difference.
    ui.page_scroll = 0
    draw(week_view(20), 390, 844, true)
    check("a page publishes the box it drew into",
          ui.page_room > 0 and ui.page_room < 844,
          tostring(ui.page_room))

    -- A phone-sized week with a dozen pilots on it overflows by less than a
    -- heading, which is exactly the case that would not move at all.
    ui.page_scroll = 0
    draw(week_view(13), 390, 844, true)
    local over = ui.page_extent - ui.page_room
    check("a week that overflows by a little still has somewhere to go",
          over > 0, "overflow " .. string.format("%.0f", over))
    ui.page_scroll = 9999
    draw(week_view(13), 390, 844, true)
    check("and a finger can reach all of it",
          math.abs(ui.page_scroll - over) < 1,
          string.format("%.0f of %.0f", ui.page_scroll, over))

    -- And the last row is on the screen once it has, in both orientations.
    -- The clamp and the draw read the same numbers, so a scroll that stops in
    -- the right place and a row that is drawn are two different claims.
    for _, size in ipairs({{390, 844, 20}, {844, 390, 20}}) do
        ui.page_scroll = 0
        draw(week_view(size[3]), size[1], size[2], true)
        ui.page_scroll = 9999
        local drawn = draw(week_view(size[3]), size[1], size[2], true)
        check("the last pilot of a week is reachable at "
              .. size[1] .. "x" .. size[2],
              has(drawn, "Pilot " .. size[3]),
              "scrolled " .. string.format("%.0f", ui.page_scroll))
    end
    ui.page_scroll = 0
end

-- --- the tab row tiles, and no two tabs share a pixel -------------------
--
-- The field behind a lit tab was a flat eleven points either side of the word,
-- against a gap that starts at twenty-one and shrinks to nine as the window
-- narrows. So two lit fields overlapped at every width: by a point on the
-- widest, by thirteen on the narrowest, which is what a hovered tab beside the
-- one you are on looked like. The hit boxes had the same defect at eight
-- points, and the first box published wins, so the left-hand tab quietly took
-- a few points of its neighbour.
--
-- Both are half the gap now, which makes the row a tiling: nothing overlaps
-- and nothing between two tabs belongs to neither.
do
    local function tab_boxes()
        local out = {}
        for _, hbox in ipairs(ui.hits) do
            if hbox.action == "rail" then out[#out + 1] = hbox end
        end
        table.sort(out, function(a, b) return a.x < b.x end)
        return out
    end
    -- The lit fields, by the color and the place only they wear: team blue,
    -- at the foot of the column, narrower than the column itself.
    local function lit_fields()
        local out = {}
        for _, r in ipairs(rects) do
            local c = r.col
            if c and c[1] == pal.FRIEND[1] and c[2] == pal.FRIEND[2]
               and c[3] == pal.FRIEND[3]
               and r.y > H - 120 and r.w < 300 then
                out[#out + 1] = r
            end
        end
        table.sort(out, function(a, b) return a.x < b.x end)
        return out
    end

    -- Wide and squeezed. The gap is 21 points at the top and floors at 9, and
    -- the old field overlapped at both ends of that range.
    for _, wide in ipairs({1600, 1280, 900, 700}) do
        -- The tab you are on, with the pointer resting on the one before it,
        -- which is the pair that has to be looked at.
        draw({depth = 1, sel = 0, rail = RAIL, rail_sel = 2, rail_hover = 1,
              focus = "rail", home = true, closable = false,
              pilot = {name = "Vantage 7", rivets = 0}, rows = {}}, wide, 800)
        local boxes = tab_boxes()
        local worst, at = 0, nil
        for i = 1, #boxes - 1 do
            local over = (boxes[i].x + boxes[i].w) - boxes[i + 1].x
            if over > worst then worst, at = over, i end
        end
        check("no tab takes a press meant for the next at " .. wide,
              #boxes == #RAIL and worst <= 0.01,
              string.format("%d boxes, %.1f points over at %s",
                            #boxes, worst, tostring(at)))
        -- And nothing between two of them belongs to neither, which is the
        -- other half of tiling: a press in the gap has to land somewhere.
        local hole = 0
        for i = 1, #boxes - 1 do
            hole = math.max(hole, boxes[i + 1].x - (boxes[i].x + boxes[i].w))
        end
        check("and nothing between two tabs is dead at " .. wide,
              hole <= 0.01, string.format("%.1f points of hole", hole))

        local fields = lit_fields()
        local lap = 0
        for i = 1, #fields - 1 do
            lap = math.max(lap, (fields[i].x + fields[i].w) - fields[i + 1].x)
        end
        check("the lit tab and the hovered one do not overlap at " .. wide,
              #fields == 2 and lap <= 0.01,
              string.format("%d fields, %.1f points over", #fields, lap))
    end
end

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
