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
-- the field, and one column, MENU_PAD in from each edge of the drawer, that
-- nothing a page draws may cross. It runs the real `M.menu` against a
-- recording layer and reads both back off it, so a page that moves takes its
-- assertions with it.

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

local RAIL = {}
for i, n in ipairs({"zones", "ship", "settings", "pilot"}) do
    RAIL[i] = {label = n, icon = n, index = i}
end

local function draw(view, w, h)
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

-- The fields that run the width of the drawer, which is what a row's does.
-- Everything narrower is a key, a cell or a rail stop, and those light their
-- own shapes on purpose.
local function row_fields()
    local dx, _, dw = ui.drawer_span()
    local out = {}
    for _, r in ipairs(fields()) do
        if math.abs(r.x - dx) < 1 and math.abs(r.w - dw) < 1 then
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

-- Each page as the menu is handed it, with a cursor somewhere in the list and
-- something on the page that is already yours.
local PAGES = {
    {
        name = "games",
        view = function()
            return {depth = 1, sel = 2, rail = RAIL, rail_sel = 1,
                    focus = "stage", closable = true, rows = {
                {label = "Chaos", index = 1, pick = true,
                 specs = {{"teams", "1 v 1"}, {"time", "one life"},
                          {"scoring", "streak"}}},
                {label = "Team Battle", index = 2, pick = true,
                 specs = {{"teams", "4 v 4"}, {"time", "3:00"},
                          {"scoring", "kills"}}},
                {label = "Shoal", index = 3, pick = true, mark = true,
                 specs = {{"teams", "8 v 8"}, {"time", "5:00"},
                          {"scoring", "kills"}}},
            }}
        end,
    },
    {
        name = "settings",
        view = function()
            return {depth = 2, sel = 1, rail = RAIL, rail_sel = 4,
                    focus = "stage", closable = true, rows = {
                {label = "Frames", index = 1, pick = true, choice = 1,
                 choices = 3},
                {label = "Fullscreen", detail = "fill the screen", index = 2,
                 pick = true},
            }}
        end,
    },
    {
        name = "play",
        view = function()
            return {depth = 2, sel = 1, rail = RAIL, rail_sel = 1,
                    focus = "stage", closable = true, at = "play",
                    rows = {
                {label = "Team Battle", detail = "3 + 5 AI", index = 1,
                 pick = true, players = 3, bots = 5, live = true,
                 acts = {{label = "leave", go = true}}},
                {label = "Duel", detail = "1 + 1 AI", index = 2,
                 pick = true, players = 1, bots = 1, live = true},
            }}
        end,
    },
    {
        name = "builds",
        view = function()
            return {depth = 3, sel = 2, rail = RAIL, rail_sel = 2,
                    focus = "stage", closable = true, newbuild = false,
                    builds = true, rows = {
                {label = "brawler", index = 1, choice = 1},
                {label = "runner", index = 2, choice = 0},
                {label = "new", index = 3, group = "keys"},
            }}
        end,
    },
    {
        name = "kit",
        view = function()
            -- The cursor on a ladder rather than on the band: the band's name
            -- key and points meter are furniture with their own shapes, and
            -- what this page is here to prove is the ladders.
            return {depth = 3, sel = 3, rail = RAIL, rail_sel = 2,
                    focus = "stage", closable = true, kit = true,
                    kit_spent = 12, kit_total = 30, rows = {
                {label = "brawler", index = 1, group = "band"},
                {label = "points", index = 2, group = "band"},
                -- Sectioned, the way menu.lua builds them: the first ladder
                -- on this page always opens a section, and the walk lays its
                -- rows out under the head rather than against the top of the
                -- page. A fixture without one is not a page this client draws.
                {label = "Gun", index = 3, choice = 2, choices = 4,
                 group = "levels", ladder = true, sect = "gun"},
                {label = "Repel", index = 4, choice = 1, choices = 3,
                 charge_slot = 1, price = 200, sect = "charges"},
            }}
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
    draw(page.view())
    local lit = row_fields()
    check(page.name .. " lights at least one row", #lit > 0,
          #lit .. " fields at the drawer span")
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

-- The whole point of the change: over five pages, a row was lit at two
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

-- --- the field is the hit box ---------------------------------------------

-- A press that lands where the eye was told the row is has landed on the row.
-- Two pages used to publish a box narrower than the field they drew, so a
-- press in the margin the field claimed hit nothing.
for _, page in ipairs(PAGES) do
    draw(page.view())
    local lit = row_fields()
    local span_x, _, span_w = ui.drawer_span()
    local covered = 0
    for _, r in ipairs(lit) do
        local mid = r.y + r.h / 2
        for _, h in ipairs(ui.hits) do
            if h.y <= mid and h.y + h.h >= mid
               and math.abs(h.x - span_x) < 1
               and math.abs(h.w - span_w) < 1 then
                covered = covered + 1
                break
            end
        end
    end
    check(page.name .. "'s lit rows publish a box the width of the field",
          covered == #lit, covered .. " of " .. #lit)
end

-- --- where you already are, and where a press would go --------------------

do
    -- The games list with one row flown and the cursor elsewhere: two fields,
    -- one of each weight.
    draw({depth = 1, sel = 1, rail = RAIL, rail_sel = 1, focus = "stage",
          closable = true, rows = {
        {label = "Chaos", index = 1, pick = true},
        {label = "Team Battle", index = 2, pick = true, mark = true},
    }})
    local lit = row_fields()
    check("a flown row and a cursor elsewhere light two rows", #lit == 2,
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
    draw({depth = 1, sel = 2, rail = RAIL, rail_sel = 1, focus = "stage",
          closable = true, rows = {
        {label = "Chaos", index = 1, pick = true},
        {label = "Team Battle", index = 2, pick = true, mark = true},
    }})
    lit = row_fields()
    check("a row that is both is lit once", #lit == 1, #lit .. " fields")
    -- And at the cursor's weight, which is the brighter of the two: measured
    -- against the standing field the same page drew a moment ago.
    if #lit == 1 then
        draw({depth = 1, sel = 0, rail = RAIL, rail_sel = 1, focus = "rail",
              closable = true, rows = {
            {label = "Team Battle", index = 1, pick = true, mark = true},
        }})
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
    local tris = 0
    layer.tri = function() tris = tris + 1 end
    draw({depth = 1, sel = 0, rail = RAIL, rail_sel = 1, focus = "rail",
          closable = true, rows = {
        {label = "Chaos", index = 1, pick = true, mark = true},
    }})
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

    local PAD = ui.MENU_PAD
    check("the interface publishes its column inset", type(PAD) == "number",
          tostring(PAD))

    for _, page in ipairs(PAGES) do
        local st = draw(page.view())
        local dx, _, dw = ui.drawer_span()
        local left, right = dx + PAD, dx + dw - PAD
        local out = {}
        for i = 1, st.n do
            local t = st.text[i]
            -- The page only, which is what the column governs: the head's own
            -- furniture sits on the panel's margin above it and the rail's
            -- labels are centered on their stops below it, and neither is type
            -- set in the column.
            if t and t.s and t.s ~= "" and t.y > 90 and t.y < H - 60 then
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
        check(page.name .. " sets every line inside the column",
              #out == 0,
              string.format("column is %.0f..%.0f; outside it: %s",
                            left, right, table.concat(out, ", ")))
    end
end

-- --- a sentence too long for the column wraps rather than running on -------

do
    -- The row keeps its key clear too: the note wraps to what is left beside
    -- it, which is what the leave key on the game you are flying needs.
    local long = "The longer your run, the bigger the bounty on you, and the "
        .. "longer the odds of getting home with it"
    local st = draw({depth = 1, sel = 1, rail = RAIL, rail_sel = 1,
                     focus = "stage", closable = true, rows = {
        {label = "Team Battle", note = long, index = 1, pick = true,
         acts = {{label = "leave"}}},
        {label = "Chaos", index = 2, pick = true},
    }})
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
        if t and t.s == "Chaos" then next_y = t.y end
        if t and t.s and t.s:find("odds", 1, true) then note_y = t.y end
    end
    check("and the line it grew into clears the row below it",
          note_y and next_y and note_y > next_y + 8,
          string.format("last note line at %s, next row at %s",
                        tostring(note_y), tostring(next_y)))
end

if fails > 0 then
    print(fails .. " failed")
    os.exit(1)
end
print("all row field checks passed")
