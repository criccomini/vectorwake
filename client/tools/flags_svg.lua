-- The beacon, the flag that replaces the pennant, on one sheet.
--
--     lua5.1 client/tools/flags_svg.lua <out.svg> [root]
--
-- Rasterize with any browser:
--
--     chromium --headless --screenshot=out.png --window-size=1240,2775 out.svg
--
-- The pennant this replaces is the only object in the game drawn in
-- elevation. Everything else on the ground is a plan view: a stand is an
-- octagon, a spawn is two rings, a wall is its own face. A staff with a cloth
-- triangle hanging off it is a camera turned sideways to watch a flag flap in
-- a wind, in a vacuum, and it reads as a golf pin.
--
-- The beacon is a transponder seen from above instead: a core, a ring, three
-- arcs standing off it that turn, and a ping leaving the core on a beat. A
-- flag is the object telling a room where the game is, so it draws the
-- broadcast. Carried, it opens out into a collar clear of the hull and pings
-- twice as often, which is a change of rate rather than of shape and so
-- survives being small.
--
-- Four other candidates were drawn against it and are in the history of this
-- file; Chris picked this one. What is left here is the sheet that develops
-- it: every state, every hull, and the two motions it has.
--
-- Unlike a hand drawn mock, every shape here goes through
-- client/render/vec.lua, the same arithmetic the mesh builder runs, in the
-- same layers and the same blend modes. `vwbuf` is stubbed to write SVG
-- triangles instead of vertex buffers, so a drawing that lands on this sheet
-- lands in the arena unchanged, and the triangle count it costs is printed.

local out_path = assert(arg[1], "an output path")
local root = arg[2] or "client"
package.path = root .. "/?.lua;" .. package.path

local W, H = 1240, 2775
local defs, uid = {}, 0
local shapes, tris = 0, 0

-- Four lists, because the arena draws in four passes and a mock that draws in
-- one lies about what covers what. Behind: the sheet's own grid and rules.
-- Then the fill layer, which is alpha blended and is the dark inside of a
-- shape. Then the glow layer, which is additive and is every bright thing.
-- Type last, on top of all of it.
local back, art_fill, art_glow, front = {}, {}, {}, {}

local function fy(y) return H - y end

local function ch(v)
    return math.max(0, math.min(255, math.floor((v or 0) * 255 + 0.5)))
end

-- --- vwbuf, writing SVG ------------------------------------------------------
--
-- Four writers is the whole native surface vec.lua uses, so four is all this
-- has to answer. Every stroke, disc, ring, arc, halo and skirt in the client
-- is built out of them upstream of here.

-- The glow layer blends ONE, ONE on the GPU. `plus-lighter` is that exactly,
-- and it is not cosmetic: an arc is a run of quads whose ramps meet at every
-- facet, and under ordinary alpha those overlaps bead into a dotted line
-- instead of summing into a smooth edge. Nothing about the drawing is wrong
-- there; the mock was.
local ADD = ' style="mix-blend-mode:plus-lighter"'
local lists, blends = {}, {}

local function poly(id, pts, paint)
    shapes = shapes + 1
    tris = tris + (#pts >= 8 and 2 or 1)
    local s = {}
    for i = 1, #pts, 2 do
        s[#s + 1] = string.format("%.3f,%.3f", pts[i], fy(pts[i + 1]))
    end
    local out = lists[id]
    out[#out + 1] = string.format('<polygon points="%s" fill="%s"%s/>',
                                  table.concat(s, " "), paint, blends[id])
end

local function flat(col, a)
    return string.format('rgba(%d,%d,%d,%.4f)', ch(col[1]), ch(col[2]),
                         ch(col[3]), (col[4] or 1) * (a or 1))
end

-- A triangle whose corners carry their own alpha. Gouraud shading is affine
-- in the plane, so a linear gradient down the alpha's own gradient direction
-- reproduces it exactly rather than approximately: solve a(x,y) = px + qy + r
-- through the three corners, then run the ramp along (p, q).
local function tri_fade(id, x1, y1, a1, x2, y2, a2, x3, y3, a3, col)
    local dx2, dy2, dx3, dy3 = x2 - x1, y2 - y1, x3 - x1, y3 - y1
    local det = dx2 * dy3 - dx3 * dy2
    if math.abs(det) < 1e-9 then return end
    local p = ((a2 - a1) * dy3 - (a3 - a1) * dy2) / det
    local q = (dx2 * (a3 - a1) - dx3 * (a2 - a1)) / det
    local g = math.sqrt(p * p + q * q)
    if g < 1e-7 then
        poly(id, {x1, y1, x2, y2, x3, y3}, flat(col, a1))
        return
    end
    local r = a1 - p * x1 - q * y1
    local ux, uy = p / g, q / g
    local lo = math.min(ux * x1 + uy * y1, ux * x2 + uy * y2, ux * x3 + uy * y3)
    local hi = math.max(ux * x1 + uy * y1, ux * x2 + uy * y2, ux * x3 + uy * y3)
    uid = uid + 1
    defs[#defs + 1] = string.format(
        '<linearGradient id="g%d" gradientUnits="userSpaceOnUse" '
        .. 'x1="%.3f" y1="%.3f" x2="%.3f" y2="%.3f">'
        .. '<stop offset="0" stop-color="%s"/>'
        .. '<stop offset="1" stop-color="%s"/></linearGradient>',
        uid, ux * lo, fy(uy * lo), ux * hi, fy(uy * hi),
        flat(col, math.max(0, math.min(1, g * lo + r))),
        flat(col, math.max(0, math.min(1, g * hi + r))))
    poly(id, {x1, y1, x2, y2, x3, y3}, string.format("url(#g%d)", uid))
end

local next_id = 0

_G.vwbuf = {
    attach = function()
        next_id = next_id + 1
        return next_id
    end,
    reset = function() end,
    rebind = function() end,
    finish = function() return 0, 0 end,
    tri = function(id, x1, y1, x2, y2, x3, y3, col)
        poly(id, {x1, y1, x2, y2, x3, y3}, flat(col))
    end,
    tri_fade = tri_fade,
    quad = function(id, x1, y1, x2, y2, x3, y3, x4, y4, col)
        poly(id, {x1, y1, x2, y2, x3, y3, x4, y4}, flat(col))
    end,
    rect = function(id, x, y, w, h, col)
        poly(id, {x, y, x + w, y, x + w, y + h, x, y + h}, flat(col))
    end,
}

-- --- the rest of Defold, as much of it as vec.lua touches --------------------

_G.hash = function(s) return s end
_G.buffer = {create = function() return {} end, VALUE_TYPE_FLOAT32 = 1}
_G.go = {get = function() return {} end}
_G.resource = {set_buffer = function() end}

local vec = require("render.vec")
local pal = require("arena.palette")

-- Order matters and is the arena's: fill first, then glow over it. Named
-- apart from the `fill, glow` every drawing below takes, because those are
-- arguments, the way arena/world.lua's own M.flags takes them.
local L_FILL = vec.layer("fill", 1)
local L_GLOW = vec.layer("glow", 1)
lists[L_FILL.id], blends[L_FILL.id] = art_fill, ""
lists[L_GLOW.id], blends[L_GLOW.id] = art_glow, ADD

local TAU = math.pi * 2

-- The colors a flag can wear. Neutral is INK, which is what an unowned flag
-- draws today and is worth keeping: a flag nobody holds is not a third team,
-- it is the absence of one.
local NEUTRAL, FRIEND, ENEMY = pal.INK, pal.FRIEND, pal.ENEMY

-- --- the roster, read rather than copied ------------------------------------
--
-- The hull polygons out of arena/world.lua, lifted by slicing the table out of
-- the file and evaluating it. Every value in there is a number or a table of
-- them, so this is safe, and it means the clearance this sheet proves is
-- proved against the roster as it stands rather than against a copy of it
-- that goes stale the first time a hull is recut.
local function read_hulls(path)
    local f = assert(io.open(path, "r"), path)
    local src = f:read("*a")
    f:close()
    local i = assert(src:find("M.HULLS = {", 1, true), "no M.HULLS")
    -- The table is a top level literal, so it closes on a line that is one
    -- brace and nothing else. Counting braces instead would have to know
    -- which of them are inside comments.
    local j = assert(src:find("\n}\n", i, true), "M.HULLS does not close")
    local chunk = assert(loadstring("return "
                                    .. src:sub(i + #"M.HULLS = ", j + 1)))
    return chunk()
end

local HULLS = read_hulls(root .. "/arena/world.lua")

-- The names, in the order arena/world.lua declares them.
local HULL_NAMES = {"Apex", "Wedge", "Chord", "Anvil", "Cipher", "Facet",
                    "Lattice"}

-- How far the widest hull in the roster reaches from its own center. This is
-- the number the collar is built on rather than a figure picked by eye: the
-- Apex is 21 and was what the first draft cleared, but the Cipher is a knife
-- and reaches 23 down its own length, so a collar sized to the Apex sat on
-- the nose of the hull it was supposed to be marking.
local HULL_R = 0
for _, h in ipairs(HULLS) do
    for i = 1, #h.poly, 2 do
        local r = math.sqrt(h.poly[i] ^ 2 + h.poly[i + 1] ^ 2)
        if r > HULL_R then HULL_R = r end
    end
end

-- Four pixels of daylight between the widest hull and the collar's inner rim.
-- Less and a Cipher at full stretch touches it; the whole point of drawing the
-- flag around the ship rather than on it is that the ship stays legible.
local CLEAR = HULL_R + 4

-- --- the beacon --------------------------------------------------------------
--
-- `o.t` is the clock. Both states draw on the flag's own position, which is
-- the second thing wrong with the pennant: it hangs its cloth up and to the
-- right, so the shape a pilot flies at sits a dozen pixels off the point the
-- core tests, and the eighteen pixel pickup radius is invisible.

-- How many facets an arc of this radius needs. Layer:round_segs answers it for
-- a whole circle, and an arc is a fraction of one. Worth deriving rather than
-- passing in: the first draft of this drawing passed segment counts by hand
-- and cost nine hundred and sixty triangles standing, most of them facets
-- under a tenth of a pixel across.
local function facets(glow, r, span)
    local n = math.ceil(glow:round_segs(r) * math.abs(span) / TAU)
    return n < 3 and 3 or n
end

-- One ring per beat, leaving `r0` and gone by `r1`. This is the whole of what
-- makes the drawing read as something running rather than something lit.
local function ping(glow, x, y, col, a, r0, r1, rate, t)
    local ph = (t * rate) % 1
    local r = r0 + (r1 - r0) * ph
    glow:ring_aa(x, y, r, 1.4 * (1 - ph),
                 pal.a(col, a * (1 - ph) * (1 - ph)), facets(glow, r, TAU))
end

local B = {}

-- Where each ring of the stack sits. A pilot can hold more than one flag, and
-- in Capture the Flag holding the set is the round, so the drawing has to be
-- able to say two and three and four rather than just "carrying".
--
-- One rim, always: that is the boundary against the hull and there is only one
-- hull. Then either a ring of arcs per flag, or, where the zone runs a carry
-- limit, one ring of arcs and a draining rim per flag. Arcs say you have them;
-- rims say how long for. Stacking both would put eight rings around a ship and
-- say neither.
local ARC0 = CLEAR + 7
local CLOCK0 = CLEAR + 16
local STEP = 8

-- Standing on a stand, or lying where somebody dropped it. Twelve pixels of
-- arc against an eighteen pixel pickup radius: big enough to fly at, small
-- enough that four of them on a map are objects rather than weather.
function B.ground(fill, glow, x, y, col, o)
    local spin = o.t * 0.5
    glow:halo(x, y, 16, 12, pal.a(col, 0.10))
    ping(glow, x, y, col, 0.45, 6, 18, 0.5, o.t)
    for i = 0, 2 do
        local a0 = spin + i / 3 * TAU
        glow:arc_aa(x, y, 12, a0, a0 + 1.15, 1.7,
                    facets(glow, 12, 1.15), pal.a(col, 0.8))
    end
    glow:ring_aa(x, y, 6.0, 1.2, pal.a(col, 0.65), facets(glow, 6, TAU))
    fill:disc(x, y, 3.4, 16, pal.a(col, 0.2))
    glow:disc(x, y, 1.9, 12, pal.a(pal.WHITE, 0.8))
end

-- One ring of arcs. Alternate rings turn against each other so a stack never
-- locks into a solid band: two rings turning the same way at the same phase
-- read as one thick ring, and the whole point of the stack is being countable.
local function collar(glow, x, y, col, r, t, layer)
    local dir = (layer % 2 == 0) and -1 or 1
    local spin = t * 1.9 * dir + layer * 0.7
    for i = 0, 2 do
        local a0 = spin + i / 3 * TAU
        glow:arc_aa(x, y, r, a0, a0 + 1.3, 2.2,
                    facets(glow, r, 1.3), pal.a(col, 1))
    end
end

-- One flag's carry clock. Counterclockwise from noon, so it empties the way a
-- fuse burns down, and the last fifth in the other side's color, because that
-- is who the flag is about to be available to again.
--
-- Drawn finer than the arcs on purpose. The arcs are the count and have to
-- survive being small; the rims are a gauge, read when somebody is looking at
-- them. Equal weight put four rims and one collar on the same footing and the
-- count stopped being the first thing anybody saw.
local function clock(glow, x, y, col, r, left)
    local hot = left < 0.2
    glow:ring_aa(x, y, r, 1.0, pal.a(col, 0.10), facets(glow, r, TAU))
    if left <= 0 then return end
    glow:arc_aa(x, y, r, -math.pi / 2, -math.pi / 2 - left * TAU, 1.7,
                facets(glow, r, left * TAU),
                pal.a(hot and ENEMY or col, hot and 1 or 0.9))
end

-- Riding a hull.
--
-- Everything inside the widest hull in the roster is left to the ship, so the
-- collar is a ring of daylight and then the flag: the hull underneath stays
-- whole and shootable, and a ship wearing this is legible from across a map
-- without hiding what anybody is aiming at.
--
-- `o.n` is how many flags this pilot is holding, one by default. `o.left` is
-- what is left on each of their carry clocks, as a fraction, and is nil in a
-- zone that runs no carry limit. Where there are clocks they are sorted so the
-- one about to expire is outermost: it is the one that turns the other side's
-- color, and it is the answer to the only question a carrier is asking.
function B.held(fill, glow, x, y, col, o)
    local n = o.n or 1
    local outer
    if o.left then
        collar(glow, x, y, col, ARC0, o.t, 1)
        local left = {}
        for i = 1, n do left[i] = o.left[i] or 1 end
        table.sort(left, function(a, b) return a > b end)
        for k = 1, n do
            clock(glow, x, y, col, CLOCK0 + (k - 1) * STEP, left[k])
        end
        outer = CLOCK0 + (n - 1) * STEP
    else
        for k = 1, n do
            collar(glow, x, y, col, ARC0 + (k - 1) * STEP, o.t, k)
        end
        outer = ARC0 + (n - 1) * STEP
    end
    glow:halo(x, y, outer + 10, 16, pal.a(col, 0.11))
    ping(glow, x, y, col, 0.5, outer + 3, outer + 25, 1.1, o.t)
    glow:ring_aa(x, y, CLEAR, 1.2, pal.a(col, 0.7), facets(glow, CLEAR, TAU))
end

-- How far out a carrier's drawing reaches, so the sheet can lay out cells that
-- fit it rather than cells that clip it.
function B.reach(n, timed)
    return (timed and CLOCK0 or ARC0) + (n - 1) * STEP + 25
end

-- --- the sheet ---------------------------------------------------------------

local MONO = "DejaVu Sans Mono, Menlo, Consolas, monospace"

local function text(x, y, s, px, col, anchor, track)
    front[#front + 1] = string.format(
        '<text x="%.1f" y="%.1f" font-size="%d" fill="%s" text-anchor="%s" '
        .. 'letter-spacing="%.1f" font-family="%s">%s</text>',
        x, fy(y), px or 9, col or "#63728a", anchor or "middle", track or 0,
        MONO, s)
end

local function head(x, y, s)
    text(x, y, string.upper(s), 12, "#9fb6d4", "start", 2)
end

-- Wrapped at a column count rather than a width, which is exact in a
-- monospaced face and saves measuring one.
local function note(x, y, s, cols, lead, px, col)
    cols, lead = cols or 118, lead or 15
    local line = ""
    for word in s:gmatch("%S+") do
        if line == "" then
            line = word
        elseif #line + 1 + #word <= cols then
            line = line .. " " .. word
        else
            text(x, y, line, px or 10, col or "#59677d", "start")
            y = y - lead
            line = word
        end
    end
    if line ~= "" then text(x, y, line, px or 10, col or "#59677d", "start") end
    return y - lead
end

local function rule(y)
    back[#back + 1] = string.format(
        '<line x1="40" y1="%.1f" x2="%d" y2="%.1f" stroke="#18212f" '
        .. 'stroke-width="1"/>', fy(y), W - 40, fy(y))
end

-- Draw the world into the sheet, magnified k times about (x, y).
--
-- Two transforms in one. The scale carries the gradients with it, since both
-- are written in the same user space, and the layer is told what a screen
-- pixel is worth at this magnification so the minimum stroke width behaves
-- the way it will on a real screen at that zoom rather than going hairline
-- and flattering the drawing. The y is negated because world space runs down
-- the screen and this sheet is laid out running up it: without that, every
-- drawing hangs the wrong way and only the symmetric ones get away with it.
local function at(k, x, y, fn)
    local g = string.format(
        '<g transform="translate(%.2f %.2f) scale(%.4f %.4f) '
        .. 'translate(%.2f %.2f)">', x, fy(y), k, -k, -x, -fy(y))
    art_fill[#art_fill + 1], art_glow[#art_glow + 1] = g, g
    L_FILL.px, L_GLOW.px = 1 / k, 1 / k
    fn()
    L_FILL.px, L_GLOW.px = 1, 1
    art_fill[#art_fill + 1], art_glow[#art_glow + 1] = '</g>', '</g>'
end

-- A tile grid, so a flag at size is judged against the ground it sits on
-- rather than against a void. Sixteen pixels, which is what a tile is.
local function grid(x0, y0, w, h)
    for gx = 0, w, 16 do
        back[#back + 1] = string.format(
            '<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="#0e1522" '
            .. 'stroke-width="1"/>', x0 + gx, fy(y0), x0 + gx, fy(y0 + h))
    end
    for gy = 0, h, 16 do
        back[#back + 1] = string.format(
            '<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="#0e1522" '
            .. 'stroke-width="1"/>', x0, fy(y0 + gy), x0 + w, fy(y0 + gy))
    end
end

-- A hull, placed by arena/world.lua's own turn, which negates the polygon's
-- y: at a heading of zero the nose is at world y minus its length, and world
-- y runs down the screen, so zero points up it. See the render script, where
-- top and bottom are swapped for exactly that reason.
--
-- Silhouette only. The plates, lamps and engine work belong to world.lua and
-- this sheet is about what goes around them.
local function hull(cls, x, y, heading, col)
    local shape = HULLS[cls].poly
    local ca, sa = math.cos(heading), math.sin(heading)
    local pts = {}
    for i = 1, #shape, 2 do
        pts[i] = x + shape[i] * ca + shape[i + 1] * sa
        pts[i + 1] = y + shape[i] * sa - shape[i + 1] * ca
    end
    L_FILL:fan(pts, pal.a(col, 0.10))
    L_GLOW:outline(pts, 1.2, pal.a(col, 0.8), true)
end

-- The pickup radius the core actually tests, which no flag drawing has shown.
local function reach(x, y, col)
    L_GLOW:ring_aa(x, y, 18, 0.8, pal.a(col, 0.12), 44)
end

-- What a drawing costs the layer it lands on, in triangles.
local function cost(fn)
    local before = tris
    fn()
    return tris - before
end

-- Every still on this sheet is one frame of an animation, and the two states
-- ping at different rates, so one clock cannot catch both mid flight. These
-- are the moments that show the mechanism: the ping about half way out, where
-- it is a ring travelling rather than a second rim.
local T = 0.9        -- standing, ping at 45% of its beat
local TH = 0.41      -- carried, ping at 45% of its beat
local UP = 0         -- a heading pointing up the sheet

local y = H - 44
text(40, y, "VECTORWAKE  /  THE BEACON", 14, "#cfe0f5", "start", 3)
y = y - 22
y = note(40, y, "the flag, as a transponder seen from above. every shape runs"
         .. " through client/render/vec.lua, the mesh builder the arena uses,"
         .. " so nothing on this sheet is a picture of a drawing: what lands"
         .. " here lands in the game.")
rule(y - 6)

-- --- on a stand --------------------------------------------------------------

y = y - 34
head(40, y, "on a stand, x4")
y = y - 17
y = note(40, y, "unowned, yours, theirs. the faint outer ring is the eighteen"
         .. " pixel pickup radius, which is the shape a pilot is really flying"
         .. " at, and the arcs are sized to sit inside it.")

local RH = 190
y = y - 16
local ground_cost = 0
for ci, c in ipairs({{NEUTRAL, "unowned"}, {FRIEND, "yours"}, {ENEMY, "theirs"}}) do
    local cx = 320 + (ci - 1) * 300
    local cy = y - RH / 2
    at(4, cx, cy, function()
        reach(cx, cy, c[1])
        ground_cost = cost(function()
            B.ground(L_FILL, L_GLOW, cx, cy, c[1], {t = T})
        end)
    end)
    text(cx, y - RH + 32, c[2], 9, "#4a5768")
end
text(40, y - RH + 32, string.format("%d triangles", ground_cost), 9,
     "#3d4a5d", "start")
y = y - RH

rule(y + 4)

-- --- carried -----------------------------------------------------------------

y = y - 16
head(40, y, "carried, x2.4")
y = y - 17
y = note(40, y, "the collar opens to clear the hull rather than sit on it. the"
         .. " dashed circle is the widest reach in the roster, which is the"
         .. " Cipher at 23 pixels and not the Apex at 21; the inner rim stands"
         .. " four pixels outside it.")

-- The reach the collar is built to clear, drawn so the clearance is a
-- measurement on the sheet rather than a claim in a caption.
-- Dashed, so it reads as a measurement drawn onto the sheet and not as part
-- of the flag.
local function envelope(x, y_)
    for i = 0, 23 do
        local a0 = i / 24 * TAU
        L_GLOW:arc_aa(x, y_, HULL_R, a0, a0 + TAU / 48, 0.8,
                      3, pal.a(pal.WALL_LIT, 0.55))
    end
end

local KH = 268
y = y - 14
local held_cost = 0
local SHOW = {{1, FRIEND, "Apex, yours"}, {5, FRIEND, "Cipher, yours"},
              {1, ENEMY, "Apex, theirs"}, {5, ENEMY, "Cipher, theirs"}}
for i, s in ipairs(SHOW) do
    local cx = 200 + (i - 1) * 280
    local cy = y - KH / 2 - 4
    at(2.4, cx, cy, function()
        envelope(cx, cy)
        hull(s[1], cx, cy, UP, s[2])
        held_cost = cost(function()
            B.held(L_FILL, L_GLOW, cx, cy, s[2], {t = TH})
        end)
    end)
    text(cx, y - KH + 34, s[3], 9, "#4a5768")
end
text(40, y - KH + 34, string.format("%d triangles", held_cost), 9,
     "#3d4a5d", "start")
y = y - KH

rule(y + 4)

-- --- every hull --------------------------------------------------------------

y = y - 16
head(40, y, "the whole roster, x1.7")
y = y - 17
y = note(40, y, "one collar over all seven hulls, at the size they fly. the"
         .. " point of the band is that nothing touches: the drawing is built"
         .. " off the roster's own polygons, so a hull that gets recut moves"
         .. " the clearance with it.")

local EH = 226
y = y - 12
for i = 1, #HULLS do
    local cx = 116 + (i - 1) * 168
    local cy = y - EH / 2 - 6
    at(1.7, cx, cy, function()
        envelope(cx, cy)
        hull(i, cx, cy, UP, FRIEND)
        B.held(L_FILL, L_GLOW, cx, cy, FRIEND, {t = TH})
    end)
    text(cx, y - EH + 30, HULL_NAMES[i] or ("hull " .. i), 9, "#4a5768")
end
y = y - EH

rule(y + 4)

-- --- the two motions ---------------------------------------------------------

y = y - 16
head(40, y, "the beat, x1.9")
y = y - 17
y = note(40, y, "one carried ping, five frames of it. the ring leaves the"
         .. " collar's rim and is gone by the time the next one starts, and"
         .. " the arcs turn under it at their own rate. standing, the same"
         .. " beat runs at half the speed.")

local PH = 250
y = y - 12
for i = 0, 4 do
    -- One full beat is 1/1.1 of a second at the carried rate, so five frames
    -- across it are these clocks.
    local t = i / 5 / 1.1
    local cx = 190 + i * 220
    local cy = y - PH / 2 - 4
    at(1.9, cx, cy, function()
        hull(1, cx, cy, UP, FRIEND)
        B.held(L_FILL, L_GLOW, cx, cy, FRIEND, {t = t})
    end)
    text(cx, y - PH + 30, string.format("%.0f%% of a beat", i / 5 * 100), 9,
         "#4a5768")
end
y = y - PH

rule(y + 4)

-- --- more than one ----------------------------------------------------------
--
-- The case that matters is not two carriers in one place: it is one carrier
-- holding several flags, which in Capture the Flag is the whole round. Hold
-- all four for ten seconds and it is yours, so a pilot two flags in has to
-- look like it from anywhere on the map.

y = y - 16
head(40, y, "carrying more than one, x1.35")
y = y - 17
y = note(40, y, "top row, a zone with no carry limit: one ring of arcs per"
         .. " flag, alternate rings turning against each other so a stack"
         .. " stays countable. bottom row, the same hands with the clock"
         .. " running: one ring of arcs, and a draining rim per flag.")

local MH = 300
y = y - 12
for n = 1, 4 do
    local cx = 200 + (n - 1) * 290
    local cy = y - MH / 2 + 8
    at(1.35, cx, cy, function()
        hull(1, cx, cy, UP, FRIEND)
        B.held(L_FILL, L_GLOW, cx, cy, FRIEND, {t = TH, n = n})
    end)
    text(cx, y - MH + 30, n == 1 and "one flag" or (n .. " flags"), 9,
         "#4a5768")
end
y = y - MH

y = y - 4
-- Four hands, each flag taken at a different moment, which is what the stack
-- is for: the rims do not move together and the outermost is always the one
-- about to go.
local HANDS = {{0.72}, {0.81, 0.33}, {0.88, 0.52, 0.14}, {0.9, 0.66, 0.4, 0.17}}
local hand_cost = {}
for n = 1, 4 do
    local cx = 200 + (n - 1) * 290
    local cy = y - MH / 2 + 8
    at(1.35, cx, cy, function()
        hull(1, cx, cy, UP, FRIEND)
        hand_cost[n] = cost(function()
            B.held(L_FILL, L_GLOW, cx, cy, FRIEND,
                   {t = TH, n = n, left = HANDS[n]})
        end)
    end)
    local secs = {}
    for _, f in ipairs(HANDS[n]) do
        secs[#secs + 1] = string.format("%.0f", 30 * f)
    end
    text(cx, y - MH + 30, table.concat(secs, " / ") .. " seconds left", 9,
         "#4a5768")
    if n == 4 then
        -- Both ends of it, because the arena's worst case is not this cell.
        -- Four pilots holding one flag each pay four pings, four inner rims
        -- and four collars; one pilot holding four pays one of each.
        text(40, y - MH + 10,
             string.format("a pilot holding four costs %d triangles; four"
                           .. " pilots holding one apiece cost %d, since"
                           .. " every one of them pays for its own ping and"
                           .. " its own rim", hand_cost[4], hand_cost[1] * 4),
             9, "#4a5768", "start")
    end
end
y = y - MH

rule(y + 4)

-- --- the carry clock ---------------------------------------------------------
--
-- Capture the Flag drops a carried flag after thirty seconds and nothing on
-- screen counts them down. The collar is drawn round, so the clock is a rim
-- to drain and costs one arc.

y = y - 16
head(40, y, "the carry clock, x1.9")
y = y - 17
y = note(40, y, "thirty seconds, invisible today. the rim sits outside the"
         .. " arcs so it cannot be read as one of them, and the last five"
         .. " seconds turn to the other side's color, because that is who the"
         .. " flag is about to be available to again.")

local CKH = 302
y = y - 12
for i, f in ipairs({1, 0.55, 0.2, 0.05}) do
    local cx = 220 + (i - 1) * 270
    local cy = y - CKH / 2 - 4
    at(1.9, cx, cy, function()
        hull(1, cx, cy, UP, FRIEND)
        B.held(L_FILL, L_GLOW, cx, cy, FRIEND, {t = TH, left = {f}})
    end)
    text(cx, y - CKH + 30, string.format("%.0f seconds left", 30 * f), 9,
         "#4a5768")
end
y = y - CKH

rule(y + 4)

-- --- at size, in a room ------------------------------------------------------

y = y - 16
head(40, y, "in a room, x1")
y = y - 17
y = note(40, y, "sixteen pixel tiles at the zoom the game is played at. four"
         .. " flags across a Capture the Flag map: two standing, one lying"
         .. " where its carrier died, one running for home with two hulls"
         .. " after it. nothing here is magnified.")

-- A wall run, drawn the way terrain reads rather than the way it is built: a
-- dark body with a lit face, which is all a flag has to compete with.
local function wall(x0, y0, w, h)
    local lit = pal.a(pal.WALL_LIT, 0.22)
    L_FILL:rect(x0, y0, w, h, pal.a(pal.PANEL_INK, 0.22))
    L_GLOW:seg(x0, y0, x0 + w, y0, 0.7, lit)
    L_GLOW:seg(x0, y0 + h, x0 + w, y0 + h, 0.7, lit)
    L_GLOW:seg(x0, y0, x0, y0 + h, 0.7, lit)
    L_GLOW:seg(x0 + w, y0, x0 + w, y0 + h, 0.7, lit)
end

local SCH = 250
y = y - 12
local cy = y - SCH / 2
local x0 = 250
grid(x0 - 190, cy - 104, 1120, 208)
at(1, x0, cy, function()
    wall(x0 - 130, cy - 104, 16, 62)
    wall(x0 + 60, cy - 46, 16, 78)
    wall(x0 + 330, cy + 30, 96, 16)
    wall(x0 + 560, cy - 104, 16, 74)
    wall(x0 + 690, cy + 44, 130, 16)
    B.ground(L_FILL, L_GLOW, x0 - 60, cy - 44, ENEMY, {t = T})
    B.ground(L_FILL, L_GLOW, x0 + 250, cy + 48, NEUTRAL, {t = T + 0.7})
    B.ground(L_FILL, L_GLOW, x0 + 460, cy - 56, FRIEND, {t = T + 1.4})
    local rx, ry_ = x0 + 800, cy - 20
    hull(1, rx, ry_, -0.35, FRIEND)
    -- Two flags, taken eleven seconds apart, which is what a run home
    -- actually looks like once somebody is winning.
    B.held(L_FILL, L_GLOW, rx, ry_, FRIEND, {t = TH, n = 2,
                                             left = {0.60, 0.24}})
    hull(5, rx - 128, ry_ - 48, -0.2, ENEMY)
    hull(4, rx - 150, ry_ + 40, -0.5, ENEMY)
end)
y = y - SCH

text(W / 2, 26, string.format("%s   %d triangles on the page",
                              os.date("%Y-%m-%d"), tris), 9, "#2c3646")

-- --- out ---------------------------------------------------------------------

if y < 30 then
    io.stderr:write(string.format(
        "the sheet overran its page by %d px; raise H\n", 30 - y))
end

-- The glow group is isolated so its additive blending sums against the
-- sheet's own ground and not against whatever a viewer has behind the page.
local f = assert(io.open(out_path, "w"))
f:write(string.format(
    '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" '
    .. 'viewBox="0 0 %d %d">\n<rect width="%d" height="%d" fill="#05070c"/>\n'
    .. '<defs>%s</defs>\n<g style="isolation:isolate">\n%s\n%s\n%s\n</g>'
    .. '\n%s\n</svg>\n',
    W, H, W, H, W, H, table.concat(defs, "\n"), table.concat(back, "\n"),
    table.concat(art_fill, "\n"), table.concat(art_glow, "\n"),
    table.concat(front, "\n")))
f:close()
print(string.format("hull reach %.0f, collar rim %.0f. standing %d, carried "
                    .. "%d, four with clocks %d, four carriers %d. %d "
                    .. "triangles on the page, %d px of it left -> %s",
                    HULL_R, CLEAR, ground_cost, held_cost, hand_cost[4],
                    hand_cost[1] * 4, tris, y, out_path))
