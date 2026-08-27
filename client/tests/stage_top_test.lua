-- The air between the bar at the top of the menu and the page under it.
--
--     lua5.1 client/tests/stage_top_test.lua
--
-- Every page in the menu hangs under one head: the x at the near end of a
-- line, the call sign at the far end, and a rule across the bottom of it. What
-- goes under that rule was written twice and branched once, so it came out
-- different on every page: thirty-eight points of nothing over the games list,
-- eighteen over the hangar, and each page's own lead-in on top of whichever it
-- got. Walking the tab row, the panel appeared to change height under a hand
-- that had not moved.
--
-- Neither half of that is visible to a test that reads strings, and both are
-- arithmetic about rectangles, so this draws the real pages against a
-- recording layer and measures where their ink lands under the rule.

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

-- A phone held upright, which is the window every one of these pages is drawn
-- for and the one the column's own width was settled against.
local W, H = 390, 844

local harness = require("tests.ui_harness")
local ink = {}
local layer = harness.layer()
-- Everything with an edge, in the space hit boxes are published in. The menu
-- draws bottom-up like the rest of the mesh, so each of these is flipped back
-- to reading order on the way in.
layer.rect = function(_, x, y, w, h)
    ink[#ink + 1] = {k = "rect", top = H - y - h, x = x, w = w, h = h}
end
layer.frame = function(_, x, y, w, h)
    ink[#ink + 1] = {k = "frame", top = H - y - h, x = x, w = w, h = h}
end
layer.seg = function(_, x0, y0, x1, y1)
    ink[#ink + 1] = {k = "seg", top = H - math.max(y0, y1),
                     x = math.min(x0, x1), w = math.abs(x1 - x0),
                     h = math.abs(y1 - y0)}
end
layer.seg_flat = layer.seg
layer.skirt = function(_, x, y0, _x1, y1, w)
    ink[#ink + 1] = {k = "skirt", top = H - math.max(y0, y1), x = x, w = w,
                     h = math.abs(y1 - y0)}
end
layer.disc = function(_, x, y, r)
    ink[#ink + 1] = {k = "disc", top = H - y - r, x = x - r, w = 2 * r, h = 2 * r}
end

local ui = harness.install()
local MENU_PAD = ui.MENU_PAD

-- What the last draw set, in reading order, and where.
local type_at = {}

local function draw(view)
    ink = {}
    local st = package.loaded["arena.state"]
    st.n = 0
    ui.begin(layer, W, H, 1, false)
    ui.menu(view)
    ui.finish()
    type_at = {}
    for i = 1, st.n do
        local t = st.text[i]
        type_at[#type_at + 1] = {s = t.s, y = H - t.y, x = t.x}
    end
    table.sort(type_at, function(a, b) return a.y < b.y end)
end

-- The rule under the head, which is the line everything here is measured from.
-- It runs the whole width of the column and is the only thing that does above
-- the tab row, so it is found rather than assumed: a head that grew or shrank
-- moves this and every page with it, which is right, and a head that stopped
-- drawing a rule is a failure worth reading as one.
local function head_rule()
    local at = nil
    for _, s in ipairs(ink) do
        if s.k == "seg" and s.h < 2 and s.w >= W - 1 and s.top > 8 then
            if not at or s.top < at then at = s.top end
        end
    end
    return at
end

-- The top edge of the first thing the page draws under that rule, whatever it
-- is: a row's lit field, the ship page's band, the box on the friends page.
-- Specks are skipped, since a two-point tick is not the beginning of a page.
-- Hairlines are not, because a section head opens with one.
local function first_ink(rule)
    if not rule then return nil end
    local at = nil
    for _, s in ipairs(ink) do
        if s.top > rule + 1 and (s.w > 6 or s.h > 6) then
            if not at or s.top < at then at = s.top end
        end
    end
    return at
end

-- And the baseline of the first line it sets, which is the line a reader
-- measures the gap by. In the column rather than out at the far end of the
-- row: what a page pins to its right edge is a figure or a label about
-- something else, and the ship page's meter carries one over its bar.
local function first_line(rule)
    if not rule then return nil end
    for _, t in ipairs(type_at) do
        if t.y > rule + 1 and t.x < W - 60 then return t.y end
    end
    return nil
end

-- --- the pages, each in the shape the menu hands to `ui.menu` --------------

local RAIL = {}
for i, n in ipairs({"zones", "ship", "friends", "settings", "pilot"}) do
    RAIL[i] = {label = n, icon = n, index = i}
end

local function base(extra)
    local v = {depth = 2, sel = 1, rail = RAIL, rail_sel = 1, focus = "stage",
               home = true, closable = true,
               pilot = {name = "Drift 7", rivets = 0}}
    for k, val in pairs(extra) do v[k] = val end
    return v
end

-- A list of games: the play page, whose rows carry the format strip under the
-- name, which is the tallest row in the menu.
-- The strip is label-and-value pairs in the order the directory sends them,
-- which is the shape the row draws rather than a table keyed by name: handed a
-- map, the row counts none of them, comes out shorter, and sets its name at
-- the fraction a row with no strip uses. That is the wrong number to measure
-- the head against.
local games = base({rows = {
    {label = "Duel", index = 1, pick = true, live = true,
     specs = {{"teams", "1 v 1"}, {"time", "one life"},
              {"scoring", "streak"}}},
    {label = "Team Battle", index = 2, pick = true, live = true,
     specs = {{"teams", "4 v 4"}, {"time", "3:00"}, {"scoring", "kills"}}},
}})

-- A list under section labels: settings, where the first thing on the page is
-- a head rather than a row.
local sectioned = base({rows = {
    {label = "Sound", detail = "Half", index = 1, pick = true, sect = "audio"},
    {label = "Music", detail = "Half", index = 2, pick = true},
    {label = "Frames", detail = "Display", index = 3, pick = true,
     sect = "video"},
}})

-- The hangar: a band carrying the build's name as a key and the points as a
-- meter, with the ladders under it.
local hangar = base({kit = true, kit_spent = 12, kit_total = 30, rows = {
    {group = "band", label = "custom", index = 1},
    {group = "band", index = 2},
    {label = "Energy", index = 3, rung = 1, ceiling = 3, sect = "flight"},
}})

-- Friends: the add box over the sections, which is the one page that opened
-- tighter than every other and is why this file exists in the shape it does.
local friends = base({social = true, rows = {},
                      add = {name = "", on = false, note = "", bad = false,
                             found = {}},
                      invite = "https://vectorwake.net/"})

-- The pilot page, which is a drawing rather than a list.
local pilot = base({pilot_card = {name = "Drift 7", guest = false,
                                  career = {games = 3, kills = 5, deaths = 4}},
                    rows = {{label = "new name", index = 1}}})

local PAGES = {
    {"play", games}, {"settings", sectioned}, {"hangar", hangar},
    {"friends", friends}, {"pilot", pilot},
}

-- --- one line, and every page begins on it --------------------------------
--
-- The inset is MENU_PAD, which is what the column already holds back from each
-- of its two side edges: a page stands the same distance in from the bar over
-- it as from the edges beside it, and the menu has one margin rather than
-- three. It used to be thirty here plus eight taken separately a hundred lines
-- earlier, and ten instead of the thirty for a page carrying a band, which is
-- one gap written as two numbers in two places with a branch between them.
--
-- The games list is where that line is directly visible: a lit row is a field
-- filling the page from its first pixel, so the top of it is the top of the
-- page. Every other page opens with something standing inside its own head or
-- band: a key centered in forty-eight points, a label near the top of a
-- section head. Those are held to a range rather than to the number.

local marks = {}
for _, page in ipairs(PAGES) do
    local name, view = page[1], page[2]
    draw(view)
    local rule = head_rule()
    check(name .. ": the head draws its rule", rule ~= nil)
    marks[name] = rule and {rule = rule, ink = first_ink(rule),
                            said = first_line(rule)} or nil
end

do
    local m = marks.play
    check("a list begins one margin under the head rule",
          m and m.ink and math.abs(m.ink - m.rule - MENU_PAD) < 1.5,
          m and string.format("%.1f under the rule, wanted %.1f",
                              (m.ink or -1) - m.rule, MENU_PAD) or "not drawn")
end

-- Nothing reaches up into the head, and nothing hangs a second gap under the
-- first. The room between them is what a page's own opening object costs: a
-- band is forty-eight points tall with a twenty-six point key centered in it,
-- and the friends box is a section head with a field where its first row goes,
-- which is the deepest of them.
local ROOM = 26

for _, page in ipairs(PAGES) do
    local name = page[1]
    local m = marks[name]
    local at = m and m.ink and (m.ink - m.rule) or nil
    check(name .. ": opens on that line or just under it",
          at and at >= MENU_PAD - 1 and at <= MENU_PAD + ROOM,
          at and string.format("%.1f under the rule, wanted %d to %d",
                               at, MENU_PAD, MENU_PAD + ROOM)
             or "nothing drawn under the head")
end

-- --- and their first line of type lands in one band -----------------------
--
-- Where a page begins is the object; what a reader measures the gap by is the
-- type inside it, and the two are not the same number. A row sets its name in
-- a field tall enough for a strip of figures under it, and a section label
-- sits near the top of a head a third that height, so these do not agree
-- exactly and should not be made to. What they must not do is
-- spread. Before this was one line the first word on a page landed anywhere
-- from forty-two to sixty-four points under the rule depending on which stop
-- on the tab row you were standing on, which is a panel that appears to change
-- height under a hand that has not moved.
local SPREAD = 10

do
    local lo, hi, at_lo, at_hi = nil, nil, nil, nil
    for _, page in ipairs(PAGES) do
        local name = page[1]
        local m = marks[name]
        check(name .. ": says something under the head", m and m.said ~= nil)
        if m and m.said then
            local at = m.said - m.rule
            if not lo or at < lo then lo, at_lo = at, name end
            if not hi or at > hi then hi, at_hi = at, name end
        end
    end
    check("the first line of type on every page lands in one band",
          lo and hi and (hi - lo) <= SPREAD,
          string.format("%s at %.1f, %s at %.1f, spread %.1f over %d",
                        tostring(at_lo), lo or -1, tostring(at_hi), hi or -1,
                        (hi or 0) - (lo or 0), SPREAD))
    -- And the band sits against the head rather than adrift under it. The
    -- floor catches type that has climbed up into the margin, the ceiling
    -- catches the gap this went in to close coming back.
    check("and against the head rather than adrift under it",
          lo and hi and lo > MENU_PAD and hi < MENU_PAD + 32,
          string.format("%.1f to %.1f, wanted inside %d to %d",
                        lo or -1, hi or -1, MENU_PAD, MENU_PAD + 32))
end

os.exit(fails > 0 and 1 or 0)
