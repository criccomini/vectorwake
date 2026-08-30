-- One way to light a row and one column to set it in, held to across every
-- page of the menu.
--
--     lua5.1 client/tests/row_field_test.lua
--
-- The menu used to answer "which row is this" eight different ways: the
-- stage's wash at the drawer span, the kit page's at 0.2 falling to 0.1 while
-- the page was unfocused, one page's band inset sixteen points either
-- side, the builds page's field hanging past the panel's right edge, and three
-- more on their own shapes at 0.13, 0.14 and 0.16. Each was defensible where
-- it was written and none of them agreed, which is what a player sees when
-- they walk from the games list into the hangar.
--
-- It answered "how far in does the type start" as many ways again, and worse
-- at the right edge than at the left: a name stood 36 in from one and its
-- price stopped 50 short of the other, and a row's sentence was clamped by
-- nothing at all, so on a phone it ran to within eight points of the glass and
-- straight under the key on its own row. That one was reported twice.
--
-- So there are two rules and this measures both: two weights at one extent for
-- the field, and one column that nothing a page draws may cross. It runs the
-- real `M.menu` against a recording layer and reads both back off it, so a
-- page that moves takes its assertions with it.
--
-- The column draws rows in two places, and the rules are the same in both: a
-- row is lit at the glass's own span, and its type stands inside that by the
-- inset the interface publishes. Most of this file is about a stop's page; the
-- last section holds a stop that opens a list to the same extent and the same
-- two weights.

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
local rects = {}
local harness = require("tests.ui_harness")
local layer = harness.layer()
-- A field is a flat rectangle plus a skirt against its left rule, and both
-- carry the weight it was drawn at. Recorded together, because the question
-- here is "how was this row lit" rather than which primitive drew it.
layer.rect = function(_, x, y, w, h, col)
    rects[#rects + 1] = {x = x, y = H - y - h, w = w, h = h, col = col,
                         skirt = false}
end
layer.skirt = function(_, x, y0, _x1, y1, w, _fade, alpha, col)
    local top, bot = math.min(y0, y1), math.max(y0, y1)
    rects[#rects + 1] = {x = x, y = H - bot, w = w, h = bot - top,
                         col = {col[1], col[2], col[3], alpha or col[4]},
                         skirt = true}
end

local ui = harness.install()
local pal = require("arena.palette")

-- The three stops the column carries, as `menu.view` hands them over. Which
-- one is holding a page open is the only thing that changes between the pages
-- below.
local STOPS = {
    {stop = "leave", label = "leave", value = "to the stands"},
    {stop = "settings", label = "settings", mark = "settings"},
    {stop = "side", label = "side", value = "Pylon", named = true},
}

local function column(open_stop, page, rows)
    local stops = {}
    for i, s in ipairs(STOPS) do
        stops[i] = {stop = s.stop, label = s.label, value = s.value,
                    mark = s.mark, named = s.named,
                    open = s.stop == open_stop}
    end
    return {open = true, at = page, page = page, stops = stops, rows = rows}
end

-- One frame of the column with a cursor somewhere in the open page. `sel` is
-- the row the arrows are standing on, which is what the pointer writes too.
local function draw(view, sel, action, w, h)
    W, H = w or 1280, h or 800
    rects = {}
    local st = package.loaded["arena.state"]
    st.n = 0
    -- Each page arrives at the top of itself. The scroll offset is one number
    -- shared by whatever page is up, which is right in the client, where a
    -- page is opened and then scrolled; here the pages are drawn one after
    -- another with no navigation between them, so a deep page left scrolled
    -- would hand the next one an offset it never sees in the app.
    ui.page_scroll = 0
    ui.col_sel, ui.col_sel_value = action or (sel and "menu_row"), sel
    ui.begin(layer, W, H, 1, false)
    ui.menu(view)
    ui.finish()
    return st
end

-- Every field drawn in team blue this frame, flat ones only: the skirt is the
-- same weight's accent against the left rule and would count each field twice.
local function fields()
    local out = {}
    for _, r in ipairs(rects) do
        local c = r.col
        if c and not r.skirt and c[1] == pal.FRIEND[1] and c[2] == pal.FRIEND[2]
           and (c[4] or 0) > 0.02 and r.h > 0 and r.w > 0 then
            out[#out + 1] = r
        end
    end
    return out
end

-- The fields that run the width of a panel row.
--
-- A row is lit at the glass's own span, left edge to right edge, which is what
-- tells it apart from everything else drawn in the same blue: the pips on a row
-- that carries a range are a few points wide, and a key or a stop is somewhere
-- else entirely. It used to be the opposite test, strictly inside the column,
-- because a row lit itself at its type column and stopped fourteen points
-- short of the glass on both sides. Chris saw that on the zone panel and it is
-- the reason this changed: a highlight that stops short of the edge is a box
-- floating on a panel.
local function row_fields()
    local cx, cw = ui.column_span()
    local out = {}
    for _, r in ipairs(fields()) do
        if math.abs(r.x - cx) < 1 and math.abs(r.w - cw) < 1 then
            out[#out + 1] = r
        end
    end
    return out
end

local function near(a, b) return math.abs(a - b) < 0.001 end

-- The two weights, read off the interface rather than written down here, so
-- this test cannot drift from the file it is about.
local CURSOR, HERE = ui.LIT.CURSOR, ui.LIT.HERE
check("the interface publishes its two weights",
      type(CURSOR) == "number" and type(HERE) == "number",
      tostring(CURSOR) .. " / " .. tostring(HERE))
check("and the cursor outweighs where you already are", CURSOR > HERE)

-- What reaches the layer is not the weight itself: `wash` lays most of the
-- field flat and puts the rest in the skirt against the left rule. So the
-- checks below ask about the two weights as a pair, that there are two of them
-- and that they stand in the ratio the interface published, rather than
-- restating either number here in a second place where it could go stale.
local RATIO = CURSOR / HERE
-- Every distinct weight a row was lit at, over every page below.
local seen = {}
local function note_weight(a)
    for _, s in ipairs(seen) do
        if near(s, a) then return end
    end
    seen[#seen + 1] = a
end

-- --- one extent and two weights, on every page ----------------------------

-- Each page of the settings stop as the menu is handed it, with a cursor
-- somewhere in the list and a row that is already yours.
--
-- No shipped page marks a settings row today; the sides are where "where you
-- already are" lives, and they open a list rather than a page. The mark is
-- still the row vocabulary rather than one page's trick, and it is `stage_row`
-- that answers it, so the pages here ask for it: what is being measured is the
-- drawing, and a rule only one caller currently exercises is the one that
-- rots.
local PAGES = {
    {
        name = "settings",
        sel = 1,
        view = function()
            return column("settings", "settings", {
                {label = "sound", sect = "audio", detail = "half",
                 choice = 2, choices = 4, index = 1, pick = true},
                {label = "music", detail = "quiet", choice = 1, choices = 3,
                 index = 2, pick = true},
                {label = "fullscreen", detail = "fill the screen", index = 3,
                 pick = true, mark = true},
            })
        end,
    },
    {
        name = "controls",
        sel = 2,
        view = function()
            return column("settings", "controls", {
                {label = "turn left", detail = "A", index = 1, pick = true,
                 control = "turn_left"},
                {label = "thrust", detail = "Up", index = 2, pick = true,
                 control = "thrust"},
                {label = "guns", detail = "Ctrl", index = 3, pick = true,
                 control = "guns", mark = true},
                {label = "reset to defaults", index = 4, pick = true,
                 reset = true},
            })
        end,
    },
    {
        name = "about",
        sel = 3,
        view = function()
            return column("settings", "about", {
                {label = "build", detail = "dev", index = 1, verbatim = true},
                {label = "wire", detail = "webtransport, quic datagrams",
                 index = 2, verbatim = true},
                {label = "device", detail = "Linux", index = 3, pick = true,
                 verbatim = true},
                {label = "policies", detail = "on the site", index = 4,
                 pick = true, mark = true},
            })
        end,
    },
}

-- The brightest field on a page is its cursor, whatever the page is.
local function brightest(lit)
    local top = 0
    for _, r in ipairs(lit) do top = math.max(top, r.col[4]) end
    return top
end

for _, page in ipairs(PAGES) do
    draw(page.view(), page.sel)
    local lit = row_fields()
    check(page.name .. " lights at least one row", #lit > 0,
          #lit .. " fields inside the column")
    for _, r in ipairs(lit) do note_weight(r.col[4]) end
    -- One cursor. Two rows lit at the brightest weight is a page that cannot
    -- say where a press would go.
    local cursors = 0
    local top = brightest(lit)
    for _, r in ipairs(lit) do
        if near(r.col[4], top) then cursors = cursors + 1 end
    end
    check(page.name .. " lights exactly one cursor", cursors == 1,
          cursors .. " of them")
end

-- The whole point of the change: over every page, a row was lit at two
-- weights, and they are the two the interface published. Before this there
-- were eight, at five different extents.
check("the menu lights a row at two weights, over every page", #seen == 2,
      #seen .. ": " .. table.concat((function()
          local out = {}
          for _, s in ipairs(seen) do out[#out + 1] = string.format("%.3f", s) end
          return out
      end)(), ", "))
if #seen == 2 then
    local hi, lo = math.max(seen[1], seen[2]), math.min(seen[1], seen[2])
    check("and they are the cursor and the standing weight",
          math.abs(hi / lo - RATIO) < 0.01,
          string.format("%.3f / %.3f is %.2f, wanted %.2f", hi, lo,
                        hi / lo, RATIO))
end

-- --- the field is inside the box a press lands on -------------------------

-- A press that lands where the eye was told the row is has landed on the row.
-- Two pages used to publish a box narrower than the field they drew, so a
-- press in the margin the field claimed hit nothing.
--
-- The panel publishes its rows at the glass's full width and lights them at
-- the same span, so the two are the same rectangle again: what lights up is
-- exactly what a press lands on, which is the strongest form this can take.
for _, page in ipairs(PAGES) do
    draw(page.view(), page.sel)
    local lit = row_fields()
    local covered = 0
    for _, r in ipairs(lit) do
        local mid = r.y + r.h / 2
        for _, h in ipairs(ui.hits) do
            if h.action == "menu_row"
               and h.y <= mid and h.y + h.h >= mid
               and h.x <= r.x + 0.5
               and h.x + h.w >= r.x + r.w - 0.5 then
                covered = covered + 1
                break
            end
        end
    end
    check(page.name .. "'s lit rows sit inside a box a press reaches",
          covered == #lit, covered .. " of " .. #lit)
end

-- --- where you already are, and where a press would go --------------------

do
    -- A page with one row already yours and the cursor elsewhere: two fields,
    -- one of each weight.
    local two = function()
        return column("settings", "settings", {
            {label = "sound", detail = "half", index = 1, pick = true},
            {label = "music", detail = "quiet", index = 2, pick = true,
             mark = true},
        })
    end
    draw(two(), 1)
    local lit = row_fields()
    check("a standing row and a cursor elsewhere light two rows", #lit == 2,
          #lit .. " fields")
    if #lit == 2 then
        local hi = math.max(lit[1].col[4], lit[2].col[4])
        local lo = math.min(lit[1].col[4], lit[2].col[4])
        check("one at the cursor's weight and one at the standing weight",
              math.abs(hi / lo - RATIO) < 0.01,
              string.format("%.3f / %.3f", hi, lo))
    end

    -- Both true of one row is one field, at the cursor's weight: what a press
    -- does next is the more urgent of the two, and two fields on one row is
    -- a row lit twice.
    draw(two(), 2)
    lit = row_fields()
    check("a row that is both is lit once", #lit == 1, #lit .. " fields")
    -- And at the cursor's weight, which is the brighter of the two: measured
    -- against the standing field the same page drew a moment ago.
    if #lit == 1 then
        draw(column("settings", "settings", {
            {label = "music", detail = "quiet", index = 1, pick = true,
             mark = true},
        }), nil)
        local standing = row_fields()
        check("and lit as the cursor rather than as standing",
              #standing == 1 and lit[1].col[4] > standing[1].col[4] + 0.001,
              #standing == 1
              and string.format("%.3f against %.3f", lit[1].col[4],
                                standing[1].col[4]) or "no standing field")
    end
end

-- --- the wedge is gone ----------------------------------------------------

do
    -- The row you are on used to carry a lit triangle out in the gutter,
    -- which pushed its own label right of every other label on the page. The
    -- field says the same thing inside the column.
    --
    -- Counted inside the page only. The panel draws a triangle of its own
    -- that is nothing to do with a row: the arrow on its head, which is the
    -- way back out of the page, and it sits above the rows rather than in
    -- them.
    local function standing()
        return column("settings", "settings", {
            {label = "sound", detail = "half", index = 1, pick = true,
             mark = true},
        })
    end
    -- Once to learn where the page is, then again counting what lands in it.
    draw(standing(), nil)
    local _, py, _, ph = ui.page_span()
    local tris = 0
    layer.tri = function(_, _x0, y0, _x1, y1, _x2, y2)
        -- Turned back the way the rest of this file counts, the gui reckoning
        -- its own y up from the foot of the window.
        local top, bot = H - math.max(y0, y1, y2), H - math.min(y0, y1, y2)
        if top >= py and bot <= py + ph then tris = tris + 1 end
    end
    draw(standing(), nil)
    layer.tri = harness.noop
    check("the row you are on draws no wedge beside it", tris == 0,
          tris .. " drawn")
end

-- --- the standing row breathes, and only it -------------------------------

do
    -- The pulse is on the clock the landing key breathes on. `F.now` is zero
    -- under this harness, so the check is on the shape of the thing rather
    -- than on a frame of it: floored well clear of dark, never over full ink,
    -- and moving.
    -- A quarter turn of the clock apart, which is trough to crest: half a
    -- turn lands back where it started and would call a moving thing still.
    local lo, hi = ui.LIT.breath(0), ui.LIT.breath((math.pi / 2) / 2.6)
    check("the standing row's ink is floored above dark", lo >= 0.7,
          tostring(lo))
    check("and never brighter than the cursor's", hi <= 1.0, tostring(hi))
    check("and it moves", math.abs(hi - lo) > 0.05,
          tostring(lo) .. " to " .. tostring(hi))
end

-- --- and nothing a page draws leaves the column ---------------------------
--
-- The one that was reported twice. A sentence with nothing clamping it ran off
-- the right of the panel; a price stopped fourteen points inside the line its
-- own name began on. Both are the same question asked of every line of type
-- the page sets, so ask it of every line of type the page sets.
--
-- The column is taken off the drawing rather than written down here: a lit
-- row's field is the glass, and the type column is that field brought in by
-- the inset the interface publishes. Those two lines are the ones no line of
-- type may cross.

do
    local menu_face = require("arena.menu_face")
    local ADVANCE = 1233 / 2048
    -- The two rules ui.lua measures with: the menu face's own advances for the
    -- menu font, one fixed advance for the mono one.
    local function measure(s, px, font)
        if font ~= "menu" then return #s * px * ADVANCE end
        local adv, w = menu_face.adv, 0
        for i = 1, #s do
            w = w + (adv[string.byte(s, i)] or menu_face.widest)
        end
        return w * px
    end

    for _, page in ipairs(PAGES) do
        local st = draw(page.view(), page.sel)
        local lit = row_fields()
        check(page.name .. " lit a row to measure its column by", #lit > 0)
        if #lit > 0 then
            local inset = ui.ROW_INSET
            local left = lit[1].x + inset
            local right = lit[1].x + lit[1].w - inset
            local _, py, _, ph = ui.page_span()
            local out, looked = {}, 0
            for i = 1, st.n do
                local t = st.text[i]
                -- The page only, which is what the column governs. The
                -- panel's own head sits above it and the stops and the key
                -- below it, and none of those is type set in the column.
                --
                -- A run of type carries the baseline it was handed to the gui,
                -- which counts up from the foot of the window, and every
                -- rectangle here has already been turned back the other way
                -- up. So the page's own box is met halfway.
                local ty = t and H - t.y
                if t and t.s and t.s ~= "" and ty >= py and ty <= py + ph
                then
                    looked = looked + 1
                    local w = measure(t.s, t.px, t.font)
                    local x0 = t.x
                    if t.pivot == "center" then x0 = t.x - w / 2
                    elseif t.pivot == "right" then x0 = t.x - w end
                    if x0 < left - 1 or x0 + w > right + 1 then
                        out[#out + 1] = string.format("%s (%.0f..%.0f)",
                                                      t.s, x0, x0 + w)
                    end
                end
            end
            -- A page whose lines all landed outside the box this looked in is
            -- a check that passed by asking nothing. It happened: the boxes
            -- are reckoned from the top of the window and a run of type from
            -- the foot, and read straight against each other they never met.
            check(page.name .. " set some type on its page", looked >= #lit,
                  looked .. " lines in " .. string.format("%.0f..%.0f",
                                                          py, py + ph))
            check(page.name .. " sets every line inside the column",
                  #out == 0,
                  string.format("column is %.0f..%.0f; outside it: %s",
                                left, right, table.concat(out, ", ")))
        end
    end
end

-- --- a sentence too long for the column wraps rather than running on -------

-- Asked at a phone's width, which is where the rule earns its keep and where
-- it was reported from: the panel is the window less its margin there, so a
-- sentence has the least room it will ever have. On a monitor the same panel
-- is capped at 560 and this sentence fits on one line, which is the cap doing
-- its job rather than the wrap failing.
do
    local long = "The longer your run, the bigger the bounty on you, and the "
        .. "longer the odds of getting home with it"
    local st = draw(column("settings", "settings", {
        {label = "Apex", note = long, index = 1, pick = true},
        {label = "Lattice", index = 2, pick = true},
    }), 1, nil, 390, 844)
    local pieces = 0
    for i = 1, st.n do
        local t = st.text[i]
        if t and t.s and t.s:find("longer", 1, true) then pieces = pieces + 1 end
    end
    check("a sentence too long for its row is broken across lines", pieces > 1,
          pieces .. " line(s)")
    -- And the list grew every row for it rather than running the second line
    -- into the row underneath.
    local note_y, next_y
    for i = 1, st.n do
        local t = st.text[i]
        if t and t.s == "Lattice" then next_y = t.y end
        if t and t.s and t.s:find("odds", 1, true) then note_y = t.y end
    end
    check("and the line it grew into clears the row below it",
          note_y and next_y and note_y > next_y + 8,
          string.format("last note line at %s, next row at %s",
                        tostring(note_y), tostring(next_y)))
end

-- --- and a stop that opens a list keeps the same two weights ---------------
--
-- The sides are the one stop whose answer is a list rather than a page. Same
-- extent and same two weights: a walk from the settings page onto the side
-- list should not change what "here" and "under the cursor" look like, and
-- for a while it did, because a page lit its rows at the type column and a
-- list lit them at the glass.

do
    local function sides()
        return column("side", nil, {
            {label = "Pylon", index = 1, detail = "8", tint = 0, mark = true,
             named = true, pick = true},
            {label = "Caisson", index = 2, detail = "7", tint = 1,
             named = true, pick = true},
            {label = "Meridian", index = 3, detail = "6", tint = 2,
             named = true, pick = true},
        })
    end
    draw(sides(), 2, "menu_pick")
    -- Everything the column held went out through the bottom edge when the
    -- panel came up, key included, so the fields at the panel's own span are
    -- the list and nothing else: there is no breathing key left up here to
    -- tell them apart from. Read with the same measure the pages are, which is
    -- the point of the section: one extent, whether a stop opens a list or a
    -- page.
    local lit = row_fields()
    check("the side list lights the row you fly for and the one under the "
          .. "cursor", #lit == 2, #lit .. " fields")
    if #lit == 2 then
        local hi = math.max(lit[1].col[4], lit[2].col[4])
        local lo = math.min(lit[1].col[4], lit[2].col[4])
        -- Asked as a ratio, exactly as the pages above are asked, and for the
        -- same reason: `wash` lays most of the field flat and puts the rest in
        -- the skirt, so what reaches the layer is a fraction of the published
        -- weight rather than the weight.
        --
        -- This used to compare against CURSOR and HERE themselves, and passed
        -- because a list lit its rows with a flat rect at the full weight
        -- while every page washed them. Two shapes for one idea is the thing
        -- the file's own opening paragraph is about, and the list draws the
        -- page's shape now, so the page's question is the one to ask.
        check("at the same two weights the pages use",
              math.abs(hi / lo - RATIO) < 0.01,
              string.format("%.3f / %.3f is %.2f, against %.2f", hi, lo,
                            hi / lo, RATIO))
    end
end

if fails > 0 then
    print(fails .. " failed")
    os.exit(1)
end
print("all row field checks passed")
