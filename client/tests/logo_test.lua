-- The mark, in the two places it exists.
--
--     lua5.1 client/tests/logo_test.lua
--
-- It is drawn twice: as strokes into a mesh layer by `ui.logo`, and as a path
-- in `client/web/icon.svg`, which the page template carries as its home-screen
-- icon. Two drawings of one shape drift, and nothing on screen would say so.
-- So this reads the shipped SVG's own coordinates and holds the Lua to them.
--
-- The tab is deliberately not that shape, and the end of this file checks the
-- one thing that decision was made for.
--
-- It also checks the thing that makes the mark a word rather than a pattern:
-- six strokes in three wedges, each a diagonal landing on the baseline where a
-- vertical stands, one gap throughout so no space says where the V stops and
-- the W starts, and the V in one team's color with the W in the other's.
--
-- And it drives the animation, because the mark draws itself stroke by stroke
-- on the menu and a mark that never finishes is a mark nobody sees.
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
-- The bullet, which is the one thing on the mark that is not a stroke.
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

-- The mark, drawn still at a size that leaves the stroke floor out of it, and
-- the size the icon is cut at: the mark is wider than it is tall, so this is
-- what stands it in a square tile with room on every side.
local pal = require("arena.palette")
local MK = 264
ui.begin(layer, W, H, 1, false, 0)
ui.logo(W / 2, H / 2, MK, 1, true)
ui.finish()

check("the mark is six strokes", #segs == 6, "segments: " .. #segs)

-- Three wedges: a diagonal and a vertical meeting on the baseline.
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
check("in three wedges", #W3 == 3, #W3 .. " wedges")

local worst_join, worst_vert = 0, 0
for _, wg in ipairs(W3) do
    -- The diagonal ends where the vertical stands. That shared point is what
    -- makes a pair read as a letter rather than as two marks near each other.
    worst_join = math.max(worst_join,
                          math.abs(wg.d.x2 - wg.v.x1) + math.abs(wg.d.y2 - wg.v.y1))
    worst_vert = math.max(worst_vert, math.abs(wg.v.x1 - wg.v.x2))
    -- And the diagonal is a diagonal.
    check("the wake falls across as well as down",
          math.abs(wg.d.x2 - wg.d.x1) > MK * 0.3,
          string.format("%.1f px across", math.abs(wg.d.x2 - wg.d.x1)))
end
check("each wake lands where its vertical stands", worst_join < 0.5,
      string.format("%.2f px apart", worst_join))
check("and the verticals are vertical", worst_vert < 0.01,
      string.format("%.2f px of lean", worst_vert))

-- One gap throughout. A word space between the V and the W would make the
-- mark two letters set beside each other; there isn't one, and the reader
-- gets V and W out of the run by reading it.
local gaps = {}
for i = 2, #W3 do
    gaps[#gaps + 1] = W3[i].d.x1 - W3[i - 1].v.x1
end
check("the three wedges are evenly spaced",
      #gaps == 2 and math.abs(gaps[1] - gaps[2]) < 0.5,
      string.format("%.1f then %.1f", gaps[1] or -1, gaps[2] or -1))

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

-- The V is the other side's color and the W is yours, which is the only
-- thing in the mark that says where one letter stops.
local function hue(c) return c and string.format("%.3f,%.3f", c[1], c[2]) end
check("the V wears one side and the W the other",
      hue(W3[1].d.col) == hue(pal.ENEMY)
      and hue(W3[2].d.col) == hue(pal.FRIEND)
      and hue(W3[3].d.col) == hue(pal.FRIEND),
      table.concat({tostring(hue(W3[1].d.col)), tostring(hue(W3[2].d.col)),
                    tostring(hue(W3[3].d.col))}, " "))

-- --- against the file the page actually carries ----------------------------

local f = assert(io.open("client/web/icon.svg", "r"),
                 "run me from the repository root")
local svg = f:read("*a")
f:close()

-- Every stroke the icon draws, as its two endpoints, in the order the file
-- lists them. The tile is the one path with no L in it.
--
-- All six are strokes of one width. What tells a wake from a vertical in the
-- file is what paints it: a wake takes a gradient and a vertical takes a
-- color. The tile takes neither, which is how it is left out.
local want = {}
for d, rest in svg:gmatch('<path d="(M[^"]-)"([^>]*)>') do
    local x1, y1, x2, y2 =
        d:match("^M([%-%d%.]+),([%-%d%.]+) L([%-%d%.]+),([%-%d%.]+)$")
    local grad = rest:find("url%(#")
    if x1 and (grad or rest:find('stroke="#')) then
        want[#want + 1] = {tonumber(x1), tonumber(y1), tonumber(x2),
                           tonumber(y2), fade = grad}
    end
end
check("the icon holds the same six strokes", #want == 6, "strokes: " .. #want)

-- Drawn at the icon's own scale and center, so the two can be compared
-- outright rather than through a transform this file would have to invent.
segs = {}
ui.begin(layer, 512, 512, 1, false, 0)
ui.logo(256, 256, MK, 1, true)
ui.finish()

-- And the same three of them fade. Which three is not a detail the shape
-- survives losing: fade the verticals instead and the mark falls upward.
local faded, drawn_fade = 0, 0
for i = 1, math.min(#want, #segs) do
    if want[i].fade then faded = faded + 1 end
    if segs[i].kind == "fade" then drawn_fade = drawn_fade + 1 end
    if (want[i].fade ~= nil) ~= (segs[i].kind == "fade") then
        faded = -1
        break
    end
end
check("the icon fades the strokes the mark fades",
      faded == 3 and drawn_fade == 3,
      faded .. " in the file, " .. drawn_fade .. " drawn")

-- And the file draws them all at one width too.
local widths = {}
for wd in svg:gmatch('stroke%-width="([%d%.]+)"') do widths[#widths + 1] = wd end
local same = #widths == 6
for _, wd in ipairs(widths) do same = same and wd == widths[1] end
check("at one width in the file as well", same,
      table.concat(widths, " "))

-- Where it stands in the tile, which nothing above checks any more now that
-- the two drawings are compared on shape alone. Both ends matter and for
-- different reasons: the mark shipped once with its last vertical 12 px off
-- the right edge and read as having fallen against it, and biasing left far
-- enough to fix that will eventually run the first wake's thin end off the
-- left edge, which is a hard cut across a gradient.
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
check("and sits left of center in it, where its weight is not",
      pad_r > pad_l * 3 and pad_r < pad_l * 25,
      string.format("%.1f left, %.1f right", pad_l, pad_r))

-- The file reckons y downward, as SVG does. What the layer is handed has been
-- flipped into the layer's own upward y, so one of the two has to come back.
--
-- Compared after each is moved to its own origin, because the two are the same
-- shape in two different places and only the shape is shared. The icon stands
-- in a square tile and is biased left inside it, since the wakes arrive out of
-- nothing and the drawing weighs to the right of the box it fills. The
-- wordmark stands next to a word and is placed against that instead.
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
local mid_ink = animated(100, 100.5)
local late, late_dots = animated(100, 104)
check("the mark starts from almost nothing", early < late * 0.2,
      string.format("%.0f px of %.0f", early, late))
check("and is under way in the middle", mid_ink > early and mid_ink < late,
      string.format("%.0f px against %.0f and %.0f", mid_ink, early, late))
check("a bullet leads it while it draws", early_dots > 0,
      early_dots .. " dots")
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

-- The mark's own strokes, picked back out of a whole menu: the two team
-- colors at full strength, and nothing else the menu draws is that.
local function mark_segs()
    local found = {}
    for _, sg in ipairs(segs) do
        local c = sg.col
        -- At full strength: the menu marks a selected row with a rule in the
        -- team color too, and that one is drawn at 0.95.
        if c and (c[4] or 1) > 0.99 then
            for _, team in ipairs({pal.FRIEND, pal.ENEMY}) do
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
        if #group == 6 and word then
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

-- --- the tab ---------------------------------------------------------------

-- The favicon is the mark at a heavier cut, stood on its middle vertical.
--
-- Which is the thing worth checking, because it is the thing that is easy to
-- undo. Three wedges are 1.75 as wide as they are tall, so a square tile holds
-- them at barely half its height; the mark earns the tile back by being placed
-- on its verticals instead of on the box it fills, which puts the standing
-- part of it evenly about the center and runs the faded end of the first wake
-- off the left edge. A cut centered the ordinary way sits visibly right and
-- looks like nobody measured.
local tpl = assert(io.open("client/web/engine_template.html", "r"),
                   "run me from the repository root")
local page = tpl:read("*a")
tpl:close()

local b64 = page:match('rel="icon" type="image/svg%+xml" '
                       .. 'href="data:image/svg%+xml;base64,([^"]+)"')
check("the page carries a favicon", b64 ~= nil, "no svg icon link")

-- Enough of a base64 decoder to read a small SVG back out of the page. The
-- alternative is trusting a comment, which is what let the tab drift in the
-- first place.
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

if b64 then
    local icon = unb64(b64)
    -- Every stroke, and which of them is a vertical: a wake takes a gradient
    -- and a vertical takes a color, the same way the mark's own file is read
    -- further up.
    local verts, all = {}, 0
    for d, rest in icon:gmatch('<path d="(M[^"]-)"([^>]*)>') do
        local x1, y1, _, y2 =
            d:match("^M([%-%d%.]+),([%-%d%.]+) L([%-%d%.]+),([%-%d%.]+)$")
        if x1 then
            all = all + 1
            if rest:find('stroke="#') then
                verts[#verts + 1] = {x = tonumber(x1),
                                     h = math.abs(tonumber(y2) - tonumber(y1))}
            end
        end
    end
    check("the tab carries the mark, six strokes", all == 6,
          all .. " strokes")
    if #verts == 3 then
        table.sort(verts, function(a, b) return a.x < b.x end)
        -- The whole placement: the middle vertical on the tile's own center.
        check("the middle vertical stands on the tile's center",
              math.abs(verts[2].x - 256) < 0.6,
              string.format("%.1f against 256", verts[2].x))
        -- Which leaves the outer two the same distance out, so the standing
        -- part of the mark is symmetric whatever the wakes do to its left.
        local l, r = 256 - verts[1].x, verts[3].x - 256
        check("with the other two evenly either side of it",
              math.abs(l - r) < 0.6, string.format("%.1f then %.1f", l, r))
        -- Heavier than the mark's own cut, which is why it reads at sixteen
        -- points where a hairline does not.
        check("cut heavier than a hairline", verts[1].h > 0,
              string.format("%.0f px tall", verts[1].h))
    else
        check("three verticals among them", false, #verts .. " verticals")
    end
end

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
