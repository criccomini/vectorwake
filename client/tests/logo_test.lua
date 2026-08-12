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
local thin, thick = math.huge, 0
for _, sg in ipairs(segs) do
    for _, wd in ipairs({sg.w, sg.w0 or sg.w}) do
        thin, thick = math.min(thin, wd), math.max(thick, wd)
    end
end
check("every stroke is the same width", thick - thin < 0.01,
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

-- --- against the file the page actually carries ----------------------------

local f = assert(io.open("client/web/icon.svg", "r"),
                 "run me from the repository root")
local svg = f:read("*a")
f:close()

-- Every stroke the icon draws, as its two endpoints, in file order. The tile
-- is the one path with no L in it.
--
-- All twelve are strokes of one width. What tells a wake from a vertical in the
-- file is what paints it: a wake takes a gradient and a vertical takes a
-- color. The tile takes neither, which is how it is left out.
local want = {}
for d, rest in svg:gmatch('<path d="(M[^"]-)"([^>]*)>') do
    local x1, y1, x2, y2 =
        d:match("^M([%-%d%.]+),([%-%d%.]+) L([%-%d%.]+),([%-%d%.]+)$")
    local grad = rest:find('stroke="url%(#')
    if x1 and (grad or rest:find('stroke="#')) then
        want[#want + 1] = {tonumber(x1), tonumber(y1), tonumber(x2),
                           tonumber(y2), fade = grad}
    end
end
check("the icon holds the same twelve strokes", #want == 12,
      "strokes: " .. #want)

-- Drawn at the icon's own scale and center, so the two can be compared
-- outright rather than through a transform this file would have to invent.
segs = {}
ui.begin(layer, 512, 512, 1, false, 0)
ui.logo(256, 256, MK, 1, true)
ui.finish()

-- The install icon keeps its gradient wakes, while the game draws the same
-- geometry in solid color.
local faded, drawn_fade = 0, 0
for i = 1, math.min(#want, #segs) do
    if want[i].fade then faded = faded + 1 end
    if segs[i].kind == "fade" then drawn_fade = drawn_fade + 1 end
end
check("the icon keeps six faded wakes and the game keeps them solid",
      faded == 6 and drawn_fade == 0,
      faded .. " in the file, " .. drawn_fade .. " drawn")

-- And the file draws them all at one width too.
local widths = {}
for wd in svg:gmatch('stroke%-width="([%d%.]+)"') do widths[#widths + 1] = wd end
local same = #widths == 12
for _, wd in ipairs(widths) do same = same and wd == widths[1] end
check("at one width in the file as well", same,
      table.concat(widths, " "))

-- The ordinary mark is centered in its tile with enough room for the stroke.
local sw = tonumber(widths[1]) or 0
local lo, hi = math.huge, -math.huge
for _, a in ipairs(want) do
    lo, hi = math.min(lo, a[1], a[3]), math.max(hi, a[1], a[3])
end
-- The wake ends square across its own direction and the vertical wears a
-- square cap, so the two ends of the drawing reach different distances.
local pad_l, pad_r = lo - sw * 0.447, 512 - (hi + sw * 0.5)
check("the mark clears both edges of the tile", pad_l > 2 and pad_r > 2,
      string.format("%.1f left, %.1f right", pad_l, pad_r))
check("and is centered in it",
      math.abs(pad_l - pad_r) < 1,
      string.format("%.1f left, %.1f right", pad_l, pad_r))

-- The file reckons y downward, as SVG does. What the layer is handed has been
-- flipped into the layer's own upward y, so one of the two has to come back.
--
-- Compared after each is moved to its own origin, because only the shape is
-- shared when the mark sits beside the wordmark.
local function moved(pts)
    local x, y = math.huge, math.huge
    for _, p in ipairs(pts) do
        x, y = math.min(x, p[1], p[3]), math.min(y, p[2], p[4])
    end
    local out = {}
    for i, p in ipairs(pts) do
        out[i] = {p[1] - x, p[2] - y, p[3] - x, p[4] - y}
    end
    return out
end
local from_file, from_lua = {}, {}
for i, a in ipairs(want) do
    from_file[i] = {a[1], 512 - a[2], a[3], 512 - a[4]}
end
for i, sg in ipairs(segs) do
    from_lua[i] = {sg.x1, sg.y1, sg.x2, sg.y2}
end
from_file, from_lua = moved(from_file), moved(from_lua)
local worst = 0
for i = 1, math.min(#from_file, #from_lua) do
    for k = 1, 4 do
        worst = math.max(worst, math.abs(from_file[i][k] - from_lua[i][k]))
    end
end
-- A tenth is what the file rounds to, so anything inside a quarter of a pixel
-- is the same drawing written two ways.
check("the drawn mark matches the shipped icon", worst < 0.25,
      string.format("worst end off by %.2f px", worst))

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
    for i, n in ipairs({"zones", "ship", "pilot", "settings", "help",
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
    local by_w = {}
    for _, sg in ipairs(mark_segs()) do
        local k = string.format("%.3f", sg.w or 0)
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
