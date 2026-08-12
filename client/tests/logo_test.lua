-- The mark, everywhere it exists.
--
--     lua5.1 client/tests/logo_test.lua
--
-- `ui.logo` draws it into a mesh layer. `client/web/icon.svg` supplies the
-- installed app icons, and `client/web/favicon.svg` supplies the heavier tab
-- cut. This reads the ordinary SVG's coordinates and holds the Lua to them.
-- It also checks every copy embedded in the single-file deployment.
--
-- The animation test matters too. Each row has a bullet, and both rows must use
-- the same clock instead of drawing one after the other.
--
-- And it checks the lockup, which is the third place the mark appears and the
-- one nothing was watching. The mark shipped a full em and a bit tall and
-- lifted a third of an em above the line the name sits on, so it read as a
-- picture standing over a caption rather than as part of the word. Neither
-- fact is visible in the shape itself; both only exist next to the type.

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

local W, H = 512, 512

-- The layer, recording the segments an outline is made of.
local segs = {}
local layer = {}
local function noop() end
for _, n in ipairs({"arc", "flush", "frame", "quad", "rect", "reset", "ring",
                    "skirt", "tri", "tri_fade", "fan"}) do
    layer[n] = noop
end
-- Each animated row has a bullet, the only part that is not a stroke.
local dots = {}
layer.disc = function(_, x, y, r) dots[#dots + 1] = {x = x, y = y, r = r} end
layer.halo = noop
layer.seg = function(_, x1, y1, x2, y2, w, col)
    segs[#segs + 1] = {x1 = x1, y1 = y1, x2 = x2, y2 = y2,
                       w = w, col = col, kind = "seg"}
end
layer.seg_fade = function(_, x1, y1, x2, y2, w1, w2, a1, a2, col)
    segs[#segs + 1] = {x1 = x1, y1 = y1, x2 = x2, y2 = y2, w0 = w1,
                       w = w2, col = col, a = a2, kind = "fade"}
end
layer.seg_flat = function(_, x1, y1, x2, y2, w, col)
    segs[#segs + 1] = {x1 = x1, y1 = y1, x2 = x2, y2 = y2,
                       w = w, col = col, kind = "flat"}
end
layer.outline = noop

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

-- At 350 px the two 168 px rows land on the icon's coordinates exactly.
local pal = require("arena.palette")
local MK = 350
ui.begin(layer, W, H, 1, false, 0)
ui.logo(W / 2, H / 2, MK, 1, true)
ui.finish()

check("the mark is twelve strokes", #segs == 12, "segments: " .. #segs)

local solid_wakes, faded_wakes = 0, 0
for _, sg in ipairs(segs) do
    if sg.kind == "flat" then solid_wakes = solid_wakes + 1 end
    if sg.kind == "fade" then faded_wakes = faded_wakes + 1 end
end
check("the game draws all six wakes in solid color",
      solid_wakes == 6 and faded_wakes == 0,
      solid_wakes .. " solid, " .. faded_wakes .. " faded")

-- Six wedges: a diagonal and a vertical meeting on each row's baseline.
local function wedges()
    local out = {}
    for i = 1, #segs, 2 do
        local d, v = segs[i], segs[i + 1]
        if not d or not v then return out end
        out[#out + 1] = {d = d, v = v}
    end
    return out
end
local W3 = wedges()
check("in two rows of three wedges", #W3 == 6, #W3 .. " wedges")

local worst_join, worst_vert = 0, 0
for _, wg in ipairs(W3) do
    -- The diagonal ends where the vertical stands. That shared point is what
    -- makes a pair read as a letter rather than as two marks near each other.
    worst_join = math.max(worst_join,
                          math.abs(wg.d.x2 - wg.v.x1) + math.abs(wg.d.y2 - wg.v.y1))
    worst_vert = math.max(worst_vert, math.abs(wg.v.x1 - wg.v.x2))
    -- And the diagonal is a diagonal.
    check("the wake falls across as well as down",
          math.abs(wg.d.x2 - wg.d.x1) > MK * 0.2,
          string.format("%.1f px across", math.abs(wg.d.x2 - wg.d.x1)))
end
check("each wake lands where its vertical stands", worst_join < 0.5,
      string.format("%.2f px apart", worst_join))
check("and the verticals are vertical", worst_vert < 0.01,
      string.format("%.2f px of lean", worst_vert))

-- The rows share their x positions, and each has one gap throughout.
local aligned, gap_ok = true, true
for i = 1, 3 do
    aligned = aligned and math.abs(W3[i].d.x1 - W3[i + 3].d.x1) < 0.5
        and math.abs(W3[i].v.x1 - W3[i + 3].v.x1) < 0.5
end
for row = 0, 1 do
    local a, b, c = W3[row * 3 + 1], W3[row * 3 + 2], W3[row * 3 + 3]
    local g1, g2 = b.d.x1 - a.v.x1, c.d.x1 - b.v.x1
    gap_ok = gap_ok and math.abs(g1 - g2) < 0.5
end
check("the rows use the same three x positions", aligned)
check("each row spaces its wedges evenly", gap_ok)

-- One width across the whole mark, the wakes' two ends included. A wake drawn
-- thinner than the vertical it lands on reads as a different kind of stroke,
-- and small enough it reads as a shadow behind the letters.
--
-- Measured square to each stroke rather than as the number handed to the
-- layer, because the two calls do not measure the same way: a vertical's
-- width is across the stroke, and a wake's is horizontal, since its ends are
-- cut flat and level. Passing one number to both drew the wakes a tenth
-- lighter than the verticals they land on, which is the same shape in two
-- weights and exactly what this check was meant to catch.
local function weight_of(sg)
    local dx, dy = sg.x2 - sg.x1, sg.y2 - sg.y1
    local len = math.sqrt(dx * dx + dy * dy)
    if sg.kind ~= "flat" or len < 1e-9 then return sg.w end
    return sg.w * math.abs(dy) / len
end

local thin, thick = math.huge, 0
for _, sg in ipairs(segs) do
    local wd = weight_of(sg)
    thin, thick = math.min(thin, wd), math.max(thick, wd)
end
-- Within a percent, which is the rounding the site's own numbers carry: 4
-- across a diagonal against 3.6 for a vertical is a perpendicular 3.578
-- against 3.6.
check("every stroke carries the same weight", thick - thin < thick * 0.01,
      string.format("%.2f to %.2f px", thin, thick))

-- Orange begins the top row, cyan finishes the bottom one, and dark slate
-- carries the other wedges.
local function hue(c) return c and string.format("%.3f,%.3f", c[1], c[2]) end
check("the mark carries the approved row colors",
      hue(W3[1].d.col) == hue(pal.ENEMY)
      and hue(W3[2].d.col) == hue(pal.MARK_MUTED)
      and hue(W3[3].d.col) == hue(pal.MARK_MUTED)
      and hue(W3[4].d.col) == hue(pal.MARK_MUTED)
      and hue(W3[5].d.col) == hue(pal.FRIEND)
      and hue(W3[6].d.col) == hue(pal.FRIEND),
      table.concat({hue(W3[1].d.col), hue(W3[2].d.col), hue(W3[3].d.col),
                    hue(W3[4].d.col), hue(W3[5].d.col),
                    hue(W3[6].d.col)}, " "))

-- --- against the drawing every other surface carries ------------------------

-- The mark exists six times over as SVG: the site header and footer, the admin
-- panel, the share card, three favicons and the installed app icon. All of
-- them are the same three fills, and this reads that path data once and holds
-- the drawn mark to it.
--
-- The installed icon used to be the exception. It was built from stroked lines
-- with a gradient fading each diagonal out toward its start, so the one place
-- the mark was drawn a different way was also the one place it read a
-- different weight, and nothing compared the two constructions.
local function read(path)
    local f = assert(io.open(path, "r"), "run me from the repository root")
    local s = f:read("*a")
    f:close()
    return s
end

-- The three fills, in row order: the wedge that opens the top row, the six
-- that carry the middle, and the pair that closes the bottom.
-- The first of each, because a page can carry the mark more than once: the
-- site puts it in the header and again in the footer.
local function fills(src)
    local out = {}
    for _, head in ipairs({"M0 2h4l24 48h%-4z", "M28 2h4l24 48h%-4z",
                           "M28 54h4l24 48h%-4z"}) do
        out[#out + 1] = src:match('d="(' .. head .. '[^"]*)"')
    end
    return out
end

local SITE = fills(read("deploy/site/index.html"))
check("the site draws the mark in three fills",
      #SITE == 3 and SITE[1] and SITE[2] and SITE[3], #SITE .. " found")

-- Every other surface carries that same drawing. The favicons differ from the
-- rest only in how heavily the fills are cut, which is deliberate and is the
-- one thing not compared here.
for _, place in ipairs({
    {"the admin panel", "deploy/admin/index.html"},
    {"the share card", "deploy/site/share-card.svg"},
    {"the installed app icon", "client/web/icon.svg"},
    {"the tab icon", "client/web/favicon.svg"},
    {"the site tab icon", "deploy/site/favicon.svg"},
    {"the admin tab icon", "deploy/admin/favicon.svg"},
}) do
    local got = fills(read(place[2]))
    local same = true
    for i = 1, 3 do same = same and got[i] ~= nil and got[i] == SITE[i] end
    check(place[1] .. " draws the site's mark", same,
          #got .. " fills, first " .. tostring(got[1]))
end

-- Nothing fades. The diagonals are solid wherever the mark is drawn, which is
-- what the install icon stopped doing on its own.
for _, place in ipairs({
    {"the installed app icon", "client/web/icon.svg"},
    {"the site header", "deploy/site/index.html"},
    {"the admin panel", "deploy/admin/index.html"},
}) do
    check("no gradient paints " .. place[1],
          not read(place[2]):find("mark%-grad")
          and not read(place[2]):find('stroke="url%(#[tb]%d'),
          "a diagonal takes a gradient")
end

-- And one weight, everywhere the mark is cut the ordinary way. The site sets
-- it in CSS and the standalone files set it on the group.
-- Taken off the group that holds the mark, or off the CSS rule that dresses
-- it, rather than off the first stroke-width in the file: the share card
-- draws its own border before it draws the mark.
local function cut(src)
    return tonumber(src:match('stroke%-width:%s*([%d%.]+)'))
        or tonumber(src:match('<g[^>]-stroke%-width="([%d%.]+)"'))
end
local ORDINARY = cut(read("deploy/site/site.css"))
check("the site names an ordinary cut", ORDINARY ~= nil, tostring(ORDINARY))
for _, place in ipairs({
    {"the admin panel", "deploy/admin/admin.css"},
    {"the share card", "deploy/site/share-card.svg"},
    {"the installed app icon", "client/web/icon.svg"},
}) do
    check(place[1] .. " cuts the mark to the same width",
          cut(read(place[2])) == ORDINARY,
          tostring(cut(read(place[2]))) .. " against " .. tostring(ORDINARY))
end

-- Now the shape itself, as centerlines and widths taken off the fills.
--
-- A diagonal is a parallelogram cut flat top and bottom: `M{x} {y}h{w}l{dx}
-- {dy}h-{w}z`, so its width is measured across and its centerline runs from
-- half a width in. A vertical is a plain bar. Both give a centerline and a
-- width, which is exactly what the layer is handed.
local N = "([%-%d%.]+)"
local DIAGONAL = "M" .. N .. " " .. N .. "h" .. N .. "l" .. N .. " " .. N .. "h"
local VERTICAL = "M" .. N .. " " .. N .. "h" .. N .. "v" .. N .. "h"

local want = {}
for _, d in ipairs(SITE) do
    for x, y, w, dx, dy in d:gmatch(DIAGONAL) do
        x, y, w, dx, dy = tonumber(x), tonumber(y), tonumber(w), tonumber(dx), tonumber(dy)
        want[#want + 1] = {x + w / 2, y, x + w / 2 + dx, y + dy, w = w, flat = true}
    end
    -- Bottom to top, which is the way the mark draws it: the bullet lands on
    -- the baseline and climbs the vertical from there.
    for x, y, w, dy in d:gmatch(VERTICAL) do
        x, y, w, dy = tonumber(x), tonumber(y), tonumber(w), tonumber(dy)
        want[#want + 1] = {x + w / 2, y + dy, x + w / 2, y, w = w, up = true}
    end
end
check("the fills hold twelve strokes", #want == 12, "strokes: " .. #want)

-- In the order the mark is drawn in: down a diagonal, then up the vertical it
-- lands on, wedge by wedge and row by row.
-- Sorted while still in the file's own downward y, so the top row comes
-- first. A stroke's row is where it starts, and a vertical starts low.
local function row_of(s) return math.min(s[2], s[4]) end
table.sort(want, function(a, b)
    if math.abs(row_of(a) - row_of(b)) > 1 then return row_of(a) < row_of(b) end
    if math.abs(a[1] - b[1]) > 0.5 then return a[1] < b[1] end
    return (a.flat and 0 or 1) < (b.flat and 0 or 1)
end)

-- Drawn at a size that makes one row of the file one row of the mark, so the
-- two can be compared as numbers rather than through a transform this file
-- would have to invent. The file's rows are 48 tall and MK_ROW of the mark's
-- height is one row.
segs = {}
local ROW = 48
ui.begin(layer, 512, 512, 1, false, 0)
ui.logo(256, 256, ROW / 0.48, 1, true)
ui.finish()
check("the drawn mark holds twelve strokes too", #segs == 12,
      "strokes: " .. #segs)

-- The file reckons y downward, as SVG does, and the layer has already been
-- handed the flip. Compared after each is moved to its own origin, because
-- only the shape is shared: where the mark sits is the caller's business.
local function moved(pts)
    local x, y = math.huge, math.huge
    for _, p in ipairs(pts) do
        x, y = math.min(x, p[1], p[3]), math.min(y, p[2], p[4])
    end
    local out = {}
    for i, p in ipairs(pts) do
        out[i] = {p[1] - x, p[2] - y, p[3] - x, p[4] - y, w = p.w}
    end
    return out
end

local from_file, from_lua = {}, {}
for i, a in ipairs(want) do
    from_file[i] = {a[1], -a[2], a[3], -a[4], w = a.w}
end
for i, sg in ipairs(segs) do
    from_lua[i] = {sg.x1, sg.y1, sg.x2, sg.y2, w = sg.w}
end
from_file, from_lua = moved(from_file), moved(from_lua)

local worst, worst_w = 0, 0
for i = 1, math.min(#from_file, #from_lua) do
    for k = 1, 4 do
        worst = math.max(worst, math.abs(from_file[i][k] - from_lua[i][k]))
    end
    worst_w = math.max(worst_w, math.abs(from_file[i].w - from_lua[i].w))
end
-- A tenth is what the file rounds to, so anything inside a quarter of a unit
-- is the same drawing written two ways.
check("the drawn mark matches the drawing every page carries", worst < 0.25,
      string.format("worst end off by %.2f", worst))
check("at the same widths, diagonals included", worst_w < 0.25,
      string.format("worst width off by %.2f", worst_w))

-- --- and the mark the page draws before the engine exists ------------------

-- There is a fourth drawing of it, and it is the first one anybody sees: the
-- loader in client/tools/single_file.py paints a starfield and this lockup on
-- a canvas while five megabytes of engine compile, seconds before the client
-- can draw anything at all.
--
-- It went on fading each diagonal out toward its start long after every other
-- surface had stopped, because it is JavaScript inside a Python string in the
-- packer and nothing here had ever looked at it. Its own comment claimed every
-- number in it had a twin in ui.lua, which is exactly the kind of claim worth
-- checking rather than believing.
local loader = read("client/tools/single_file.py")
local uisrc = read("client/arena/ui.lua")

check("the loader draws its diagonals solid",
      not loader:find("createLinearGradient"),
      "a gradient is still built for the mark")

-- The constants, against the ones ui.lua keeps. Written differently in the two
-- languages, so each is read on its own terms and compared as a number.
local function num(src, pat)
    return tonumber(src:match(pat))
end
for _, k in ipairs({
    {"MK_WD", "local MK_WD, MK_GAP = ([%d%.]+),", "var MK_WD = ([%d%.]+),"},
    {"MK_WEIGHT", "MK_ROW_GAP, MK_WEIGHT = [%d%.]+, [%d%.]+, ([%d%.]+)",
     "MK_WEIGHT = ([%d%.]+);"},
    {"MK_ROW", "local MK_ROW, MK_ROW_GAP.- = ([%d%.]+),", "var MK_ROW = ([%d%.]+),"},
    {"MK_ROW_GAP", "local MK_ROW, MK_ROW_GAP.- = [%d%.]+, ([%d%.]+),",
     "MK_ROW_GAP = ([%d%.]+);"},
    {"LOGO_EM", "local LOGO_EM, LOGO_GAP, LOGO_DROP = ([%d%.]+),",
     "var LOGO_EM = ([%d%.]+),"},
    {"LOGO_GAP", "local LOGO_EM, LOGO_GAP, LOGO_DROP = [%d%.]+, ([%d%.]+),",
     "LOGO_GAP = ([%d%.]+),"},
    {"LOGO_DROP", "LOGO_GAP, LOGO_DROP = [%d%.]+, [%d%.]+, ([%d%.]+)",
     "LOGO_DROP = ([%d%.]+);"},
}) do
    local mine, theirs = num(uisrc, k[2]), num(loader, k[3])
    check("the loader's " .. k[1] .. " is the client's",
          mine ~= nil and theirs ~= nil and math.abs(mine - theirs) < 1e-9,
          tostring(theirs) .. " against " .. tostring(mine))
end

-- And the widening that keeps a diagonal the same weight as the vertical it
-- lands on, which both of them have to apply or the two marks read
-- differently at the same size.
check("the loader widens its diagonals the same way",
      loader:find("4 / 3%.6") ~= nil and uisrc:find("4 / 3%.6") ~= nil,
      "one of the two is not carrying the site's 4-against-3.6")

-- --- and it draws itself ---------------------------------------------------

-- On the menu the mark is drawn stroke by stroke by a bullet that bounces off
-- the baseline. Two things have to hold and neither is visible in the finished
-- shape: it starts from nothing, and it ends as the shape rather than as an
-- approximation of it.
-- Stepped like a frame loop rather than jumped, because the run restarts when
-- the mark has not been drawn for a moment and that is deliberate: it is how
-- opening the menu replays it without anything having to say so.
local function animated(from, to)
    local ink, ndots = 0, 0
    local t = from
    while t <= to + 1e-9 do
        segs, dots = {}, {}
        ui.begin(layer, W, H, 1, false, t)
        ui.logo(W / 2, H / 2, MK)
        ui.finish()
        ink = 0
        for _, sg in ipairs(segs) do
            ink = ink + math.sqrt((sg.x2 - sg.x1) ^ 2 + (sg.y2 - sg.y1) ^ 2)
        end
        ndots = #dots
        t = t + 0.05
    end
    return ink, ndots
end

local early, early_dots = animated(100, 100.05)
local early_segs = segs
local mid_ink = animated(100, 100.5)
local late, late_dots = animated(100, 104)
check("the mark starts from almost nothing", early < late * 0.2,
      string.format("%.0f px of %.0f", early, late))
check("and is under way in the middle", mid_ink > early and mid_ink < late,
      string.format("%.0f px against %.0f and %.0f", mid_ink, early, late))
check("a bullet leads each row while it draws", early_dots == 6,
      early_dots .. " dots")
check("both rows start on the same frame",
      #early_segs == 2
      and math.abs(early_segs[1].y1 - early_segs[2].y1) > MK * 0.45,
      #early_segs .. " active strokes")
check("the moving wakes stay solid",
      #early_segs == 2
      and early_segs[1].kind == "flat" and early_segs[2].kind == "flat")
check("and is gone once it has finished", late_dots == 0,
      late_dots .. " dots")

-- Finished means finished: the same ink the still mark draws.
segs = {}
ui.begin(layer, W, H, 1, false, 0)
ui.logo(W / 2, H / 2, MK, 1, true)
ui.finish()
local still = 0
for _, sg in ipairs(segs) do
    still = still + math.sqrt((sg.x2 - sg.x1) ^ 2 + (sg.y2 - sg.y1) ^ 2)
end
check("and it finishes into the shape itself",
      math.abs(late - still) < 0.5,
      string.format("%.1f px against %.1f", late, still))

-- --- the lockup ------------------------------------------------------------

-- The home screen sets the name large with the mark beside it. Where the mark
-- lands is arithmetic against the type size, and arithmetic against a size
-- nobody measures is arithmetic nobody checks.
--
-- Drawn through the real menu rather than by calling the private function, so
-- what is measured is what a player is shown.
local state = package.loaded["arena.state"]

-- The mark's own strokes, picked back out of a whole menu by its three colors
-- at full strength.
local function mark_segs()
    local found = {}
    for _, sg in ipairs(segs) do
        local c = sg.col
        -- At full strength: the menu marks a selected row with a rule in the
        -- team color too, and that one is drawn at 0.95.
        if c and (c[4] or 1) > 0.99 then
            for _, team in ipairs({pal.FRIEND, pal.ENEMY, pal.MARK_MUTED}) do
                if c[1] == team[1] and c[2] == team[2] and c[3] == team[3] then
                    found[#found + 1] = sg
                end
            end
        end
    end
    return found
end

-- Run enough frames for the mark to finish drawing itself, then measure the
-- last one. A lockup is where the finished mark sits, not where the bullet is.
local function lockup(w, h)
    local rail = {}
    for i, n in ipairs({"zones", "ship", "pilot", "settings", "controls",
                        "about"}) do
        rail[i] = {label = n, icon = n, index = i}
    end
    local t = 200
    for _ = 1, 60 do
        segs = {}
        state.n = 0
        ui.begin(layer, w, h, 1, false, t)
        ui.menu({depth = 1, sel = 0, rail = rail, rail_sel = 1,
                 focus = "rail", home = true, closable = false,
                 rows = {{label = "chaos", kind = "row"}}})
        ui.finish()
        t = t + 0.05
    end
    -- The name, and the box the two hulls occupy beside it.
    local word = nil
    for i = 1, state.n do
        if state.text[i].s == "vectorwake" then word = state.text[i] end
    end
    -- The menu can put the mark on screen more than once: the panel's own
    -- lockup, and whatever the stage happens to be previewing. What is under
    -- test is the one beside this word, so the strokes are grouped by the
    -- width they were drawn at, which is a mark's own size, and the group that
    -- ends nearest the left of the name wins.
    --
    -- Grouped by the weight a mark is drawn at rather than by the number each
    -- stroke was handed, since a diagonal is handed a wider one to come out
    -- the same weight as the vertical it lands on. Taking that widening back
    -- off puts all twelve of a mark's strokes in one group again.
    local by_w = {}
    for _, sg in ipairs(mark_segs()) do
        local base = sg.w or 0
        if sg.kind == "flat" then base = base * 3.6 / 4 end
        local k = string.format("%.3f", base)
        by_w[k] = by_w[k] or {}
        table.insert(by_w[k], sg)
    end
    local mk, best
    for _, group in pairs(by_w) do
        if #group == 12 and word then
            local right = 0
            for _, sg in ipairs(group) do
                right = math.max(right, sg.x1, sg.x2)
            end
            local d = word.x - right
            if d > 0 and (not best or d < best) then mk, best = group, d end
        end
    end
    if not word or not mk then
        return nil, string.format("word %s, no mark beside it",
                                  tostring(word ~= nil))
    end
    local x0, y0, x1, y1
    for _, sg in ipairs(mk) do
        for _, p in ipairs({{sg.x1, sg.y1}, {sg.x2, sg.y2}}) do
            local px, py = p[1], h - p[2]
            x0 = math.min(x0 or px, px)
            x1 = math.max(x1 or px, px)
            y0 = math.min(y0 or py, py)
            y1 = math.max(y1 or py, py)
        end
    end
    -- Both come out of the layer's upward y and go back into the interface's
    -- own downward one, so "below" means what it says.
    return {size = word.px, wx = word.x, wy = h - word.y,
            x0 = x0, y0 = y0, x1 = x1, y1 = y1}
end

local L, why = lockup(1280, 800)
check("the home screen draws the name and the mark together", L ~= nil, why)

if L then
    -- On the middle of the word, which is not the middle of its line box.
    -- `txt` centers a string in a box with descender room under it, and this
    -- name is lowercase with no descenders, so its ink and its weight both
    -- sit lower than the box does. How much lower is a judgement made against
    -- a screenshot and recorded as LOGO_DROP; what is checked here is that
    -- the mark is placed against that judgement and not against zero, and
    -- that the offset travels with the type rather than being a pixel count.
    local center = (L.y0 + L.y1) / 2
    local drop = (center - L.wy) / L.size
    check("the mark sits on the middle of the word, not of its line box",
          drop > 0.06 and drop < 0.20,
          string.format("%.3f em below the line box center", drop))
    -- Shorter than the type it stands beside. A mark taller than the em is
    -- the one that made the first draft read as a picture with a caption.
    local tall = L.y1 - L.y0
    check("the mark is no taller than the type", tall < L.size,
          string.format("%.2f em tall", tall / L.size))
    check("and is not so small it reads as punctuation", tall > L.size * 0.5,
          string.format("%.2f em tall", tall / L.size))
    -- To the left of the name, clear of it: they are one lockup, not a
    -- collision.
    check("the mark sits left of the name", L.x1 < L.wx,
          string.format("mark ends at %.1f, name starts at %.1f", L.x1, L.wx))
    check("with air between them", L.wx - L.x1 > L.size * 0.05,
          string.format("%.2f em of gap", (L.wx - L.x1) / L.size))
end

-- A phone sets the name smaller. The lockup is arithmetic against the size,
-- so it has to hold at both, and a constant hiding in it shows up here.
local narrow = lockup(420, 780)
if L and narrow then
    local ndrop = ((narrow.y0 + narrow.y1) / 2 - narrow.wy) / narrow.size
    check("the lockup holds at the small size",
          math.abs(ndrop - (L.y0 + L.y1) / 2 / L.size
                   + L.wy / L.size) < 0.02,
          string.format("%.3f em against %.3f em", ndrop,
                        ((L.y0 + L.y1) / 2 - L.wy) / L.size))
    check("and the mark scales with the type",
          math.abs((narrow.y1 - narrow.y0) / narrow.size
                   - (L.y1 - L.y0) / L.size) < 0.02,
          string.format("%.2f em against %.2f em",
                        (narrow.y1 - narrow.y0) / narrow.size,
                        (L.y1 - L.y0) / L.size))
end

-- --- browser and install icons ---------------------------------------------

local tpl = assert(io.open("client/web/engine_template.html", "r"),
                   "run me from the repository root")
local page = tpl:read("*a")
tpl:close()

-- Enough of a base64 decoder to compare the embedded files byte for byte.
local function unb64(s)
    local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
                  .. "0123456789+/"
    local map = {}
    for i = 1, #chars do map[chars:sub(i, i)] = i - 1 end
    local out, bits, n = {}, 0, 0
    for c in s:gmatch(".") do
        local v = map[c]
        if v then
            bits, n = bits * 64 + v, n + 6
            if n >= 8 then
                n = n - 8
                out[#out + 1] = string.char(math.floor(bits / 2 ^ n) % 256)
                -- Drop what has been emitted. Left in, the accumulator runs
                -- past what a double holds exactly and the tail decodes to
                -- rubbish, which reads as the icon not being there at all.
                bits = bits % 2 ^ n
            end
        end
    end
    return table.concat(out)
end

local function read_file(path)
    local fh = assert(io.open(path, "rb"), "cannot read " .. path)
    local body = fh:read("*a")
    fh:close()
    return body
end

local favicon = read_file("client/web/favicon.svg")
check("the favicon uses the heavier cut",
      favicon:find('stroke%-width="3%.5"') ~= nil)
check("the favicon carries both rows and all three colors",
      favicon:find("M0 2", 1, true) and favicon:find("M0 54", 1, true)
      and favicon:find("#ffa552", 1, true)
      and favicon:find("#3f4b60", 1, true)
      and favicon:find("#4fd6ff", 1, true))
check("the public and admin sites use that favicon",
      read_file("deploy/site/favicon.svg") == favicon
      and read_file("deploy/admin/favicon.svg") == favicon)

local site_page = read_file("deploy/site/index.html")
local admin_page = read_file("deploy/admin/index.html")
local site_css = read_file("deploy/site/site.css")
local admin_css = read_file("deploy/admin/admin.css")
check("both sites link the weighted favicon",
      site_page:find('href="/favicon.svg"', 1, true)
      and admin_page:find('href="favicon.svg"', 1, true))
check("the admin header carries the two-row mark",
      admin_page:find('viewBox="0 0 84 104"', 1, true)
      and admin_page:find('class="mark%-amber"')
      and admin_page:find('class="mark%-muted"')
      and admin_page:find('class="mark%-cyan"'))
check("the public and admin header marks use the slightly heavier cut",
      site_css:find("stroke%-width: 0%.6")
      and admin_css:find("stroke%-width: 0%.6"))

local function png_size(body)
    local function n32(i)
        local a, b, c, d = body:byte(i, i + 3)
        return ((a * 256 + b) * 256 + c) * 256 + d
    end
    if body:sub(1, 8) ~= "\137PNG\r\n\26\n" then return 0, 0 end
    return n32(17), n32(21)
end

for _, spec in ipairs({
    {"client/web/favicon-64.png", 64},
    {"client/web/apple-touch-icon.png", 180},
    {"client/web/icon-192.png", 192},
    {"client/web/icon-512.png", 512},
}) do
    local pw, ph = png_size(read_file(spec[1]))
    check(spec[1] .. " has the declared size",
          pw == spec[2] and ph == spec[2], pw .. "x" .. ph)
end

local assets = {
    {"the page embeds the source favicon",
     page:match('rel="icon" type="image/svg%+xml" '
                .. 'href="data:image/svg%+xml;base64,([^"]+)"'),
     favicon},
    {"the page embeds the 64 px fallback",
     page:match('rel="icon" type="image/png" sizes="64x64" '
                .. 'href="data:image/png;base64,([^"]+)"'),
     read_file("client/web/favicon-64.png")},
    {"the page embeds the Apple icon",
     page:match('rel="apple%-touch%-icon" '
                .. 'href="data:image/png;base64,([^"]+)"'),
     read_file("client/web/apple-touch-icon.png")},
    {"the manifest embeds its 192 px icon",
     page:match('var ICON192 = "data:image/png;base64,([^"]+)"'),
     read_file("client/web/icon-192.png")},
    {"the manifest embeds its 512 px icon",
     page:match('var ICON512 = "data:image/png;base64,([^"]+)"'),
     read_file("client/web/icon-512.png")},
}
for _, asset in ipairs(assets) do
    local name, b64, source = asset[1], asset[2], asset[3]
    check(name, b64 and unb64(b64) == source,
          b64 and "embedded bytes differ" or "data URI missing")
end

check("the web manifest lists both install icons",
      page:find("{src: ICON192", 1, true)
      and page:find("{src: ICON512", 1, true))

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
