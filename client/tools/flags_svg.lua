-- Every flag we might draw, on one sheet, without an engine.
--
--     lua5.1 client/tools/flags_svg.lua <out.svg> [root]
--
-- Rasterize with any browser:
--
--     chromium --headless --screenshot=out.png --window-size=1240,3130 out.svg
--
-- The pennant a flag wears today is the only object in this game drawn in
-- elevation. Everything else on the ground is a plan view: a stand is an
-- octagon, a spawn is two rings, a wall is its own face. A staff with a cloth
-- triangle hanging off it is a camera looking sideways at a flag flapping in
-- a wind, in a vacuum, and it reads as a golf pin. This sheet is where the
-- replacements get compared.
--
-- Unlike a hand drawn mock, every shape here goes through
-- client/render/vec.lua, the same arithmetic the mesh builder runs, in the
-- same layers and the same blend modes. `vwbuf` is stubbed to write SVG
-- triangles instead of vertex buffers, so a drawing that lands on this sheet
-- lands in the arena unchanged, and the triangle count it costs is printed.

local out_path = assert(arg[1], "an output path")
local root = arg[2] or "client"
package.path = root .. "/?.lua;" .. package.path

local W, H = 1240, 4360
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

-- --- the candidates ----------------------------------------------------------
--
-- Each one is a pair. `ground` is a flag on its stand or lying where somebody
-- dropped it. `held` is the same flag riding a hull.
--
-- Held is drawn as a collar outside the ship rather than as a mark on top of
-- it, and that rule came out of the first pass of this sheet. A shape sitting
-- on a hull hides the thing everybody in the room is trying to shoot, and at
-- the range where a carried flag matters it is a smudge on a ship rather than
-- a flag at all. Everything inside about thirteen pixels is left to the hull;
-- the flag lives from there out, where it reads from across a map and where
-- the ship stays whole underneath it.
--
-- Both draw on the flag's own position, which is the second thing wrong with
-- the pennant: it hangs its cloth up and to the right, so the shape a pilot
-- flies at sits a dozen pixels off the point the core tests, and the eighteen
-- pixel pickup radius is invisible. Everything below is centered.
--
-- `o.t` is the clock. `o.hx, o.hy` is the carrier's nose as a world unit
-- vector, and world y runs down the screen, so a ship flying up the screen is
-- (0, -1). Only the streamer asks.

local C = {}

local HULL = 13    -- what a held flag leaves alone, in world pixels

-- --- 0. pennant, what ships ---------------------------------------------------
--
-- Lifted from arena/world.lua unchanged, so the sheet argues against the real
-- thing rather than a flattering copy of it.

C[1] = {name = "0  pennant", key = "pennant",
        note = "what ships. a staff and a cloth triangle, off center, waving"
            .. " in a wind that is not there."}

local function pennant_at(fill, glow, x, y, col, o, carried)
    local wave = math.sin(o.t * 2.2) * 1.6
    local top = y - (carried and 26 or 13)
    local base = y + (carried and -10 or 6)
    glow:seg(x, base, x, top, 1.6, pal.a(col, 0.9))
    local pts = {x, top, x + 12 + wave, top + 4.5, x, top + 9}
    fill:fan(pts, pal.a(col, carried and 0.6 or 0.25))
    glow:outline(pts, 1.3, pal.a(col, carried and 1 or 0.7))
    glow:halo(x, top + 4, carried and 22 or 14, 10, pal.a(col, 0.13))
end

C[1].ground = function(fill, glow, x, y, col, o)
    pennant_at(fill, glow, x, y, col, o, false)
end

C[1].held = function(fill, glow, x, y, col, o)
    pennant_at(fill, glow, x, y, col, o, true)
end

-- --- 1. beacon ----------------------------------------------------------------
--
-- A transponder seen from above: a core, a ring, three arcs standing off it
-- that turn, and a ping, which is a ring that leaves the core and fades on its
-- way out. A flag is the object telling a room where the game is, so draw the
-- broadcast. Held, the arcs open out around the hull and the ping comes twice
-- as often, so the change of state is a change of rate rather than of shape
-- and survives being small.

C[2] = {name = "1  beacon", key = "beacon",
        note = "a transponder from above: arcs that turn, and a ping leaving"
            .. " the core. held, it opens around the hull and pings faster."}

-- How many facets an arc of this radius needs. Layer:round_segs answers it
-- for a whole circle, and an arc is a fraction of one. The first pass of this
-- sheet passed segment counts in by hand and priced the beacon at nine
-- hundred and sixty triangles standing, most of them facets under a tenth of
-- a pixel across.
local function facets(glow, r, span)
    local n = math.ceil(glow:round_segs(r) * math.abs(span) / TAU)
    return n < 3 and 3 or n
end

-- One ring per beat, leaving `r0` and gone by twice `r1`.
local function ping(glow, x, y, col, a, r0, r1, rate, t)
    local ph = (t * rate) % 1
    local r = r0 + (r1 - r0) * ph
    glow:ring_aa(x, y, r, 1.4 * (1 - ph),
                 pal.a(col, a * (1 - ph) * (1 - ph)), facets(glow, r, TAU))
end

C[2].ground = function(fill, glow, x, y, col, o)
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

C[2].held = function(fill, glow, x, y, col, o)
    local spin = o.t * 1.9
    glow:halo(x, y, 30, 14, pal.a(col, 0.13))
    ping(glow, x, y, col, 0.5, HULL + 1, 34, 1.1, o.t)
    for i = 0, 2 do
        local a0 = spin + i / 3 * TAU
        glow:arc_aa(x, y, 22, a0, a0 + 1.3, 1.8,
                    facets(glow, 22, 1.3), pal.a(col, 1))
    end
    glow:ring_aa(x, y, HULL + 2, 1.2, pal.a(col, 0.75),
                 facets(glow, HULL + 2, TAU))
end

-- --- 2. sigil -----------------------------------------------------------------
--
-- A standard drawn as a mark rather than as cloth: three blades off a bright
-- core, bound at the waist by a ring, turning slowly. Held, the ring breaks
-- into three arcs and the blades reach out past the hull, so the silhouette
-- says taken without needing the color to say it.

C[3] = {name = "2  sigil", key = "sigil",
        note = "a standard as a mark: three blades and a binding ring. held,"
            .. " the ring breaks and the blades reach out past the hull."}

local function blades(fill, glow, x, y, col, spin, r0, r1, w, a, k)
    for i = 0, 2 do
        local ang = spin + i / 3 * TAU
        local cx, sy = math.cos(ang), math.sin(ang)
        local nx, ny = -sy, cx
        local pts = {x + cx * r1, y + sy * r1,
                     x + cx * r0 + nx * w, y + sy * r0 + ny * w,
                     x + cx * r0 - nx * w, y + sy * r0 - ny * w}
        if k > 0 then fill:fan(pts, pal.a(col, k)) end
        glow:outline(pts, 1.25, pal.a(col, a), true)
    end
end

C[3].ground = function(fill, glow, x, y, col, o)
    local spin = o.t * 0.32
    glow:halo(x, y, 15, 12, pal.a(col, 0.09))
    blades(fill, glow, x, y, col, spin, 2.4, 13, 3.0, 0.82, 0.13)
    glow:ring_aa(x, y, 7.4, 1.1, pal.a(col, 0.5), facets(glow, 7.4, TAU))
    glow:disc(x, y, 2.1, 12, pal.a(pal.WHITE, 0.8))
end

C[3].held = function(fill, glow, x, y, col, o)
    local spin = o.t * 1.05
    glow:halo(x, y, 30, 14, pal.a(col, 0.12))
    blades(fill, glow, x, y, col, spin, HULL + 1, 27, 4.4, 1, 0.10)
    for i = 0, 2 do
        local a0 = spin + i / 3 * TAU + TAU / 6
        glow:arc_aa(x, y, HULL + 2, a0 - 0.62, a0 + 0.62, 1.4,
                    facets(glow, HULL + 2, 1.24), pal.a(col, 0.85))
    end
end

-- --- 3. sweep -----------------------------------------------------------------
--
-- The one shape on this list that a top down game invented for itself: a
-- scanning face. A wedge of light turns around the core and leaves a decaying
-- tail behind it, the way a radar sweep does. It is the cheapest of the five,
-- it has a direction without claiming a wind, and the tail is what makes it
-- read as something running rather than something lit.

C[4] = {name = "3  sweep", key = "sweep",
        note = "a scanning face. a wedge of light turns and leaves a decaying"
            .. " tail. a direction without a wind, and the cheapest of these."}

-- Sampled finely enough that the tail is a smear rather than a comb: at
-- eight spokes the gaps between them were wider than the spokes.
local function sweep_at(glow, x, y, col, spin, r0, r1, a, tail)
    local N = 15
    for i = N, 1, -1 do
        local k = i / N
        local ang = spin - k * tail
        local ca, sa = math.cos(ang), math.sin(ang)
        glow:seg_fade(x + ca * r0, y + sa * r0, x + ca * r1, y + sa * r1,
                      (r1 - r0) * 0.09, (r1 - r0) * 0.30,
                      a * 0.6 * (1 - k) ^ 1.6, 0, col)
    end
    -- The leading edge, hard, so the sweep has a front rather than a smear.
    local ca, sa = math.cos(spin), math.sin(spin)
    glow:seg(x + ca * r0, y + sa * r0, x + ca * r1, y + sa * r1, 1.6,
             pal.a(col, a))
    glow:ring_aa(x, y, r1, 0.9, pal.a(col, a * 0.28), facets(glow, r1, TAU))
end

C[4].ground = function(fill, glow, x, y, col, o)
    glow:halo(x, y, 15, 12, pal.a(col, 0.09))
    sweep_at(glow, x, y, col, o.t * 1.5, 2.6, 13, 0.85, 1.5)
    glow:ring_aa(x, y, 4.2, 1.2, pal.a(col, 0.7), facets(glow, 4.2, TAU))
    fill:disc(x, y, 3.0, 14, pal.a(col, 0.2))
    glow:disc(x, y, 1.8, 12, pal.a(pal.WHITE, 0.85))
end

C[4].held = function(fill, glow, x, y, col, o)
    glow:halo(x, y, 30, 14, pal.a(col, 0.12))
    sweep_at(glow, x, y, col, o.t * 4.2, HULL + 1, 27, 1, 2.1)
    glow:ring_aa(x, y, HULL + 1, 1.2, pal.a(col, 0.7),
                 facets(glow, HULL + 1, TAU))
end

-- --- 4. streamer --------------------------------------------------------------
--
-- The inertia honest flag, and the only one that answers the question the
-- pennant is pretending to answer: what does a flag do when the thing holding
-- it moves? It trails. Eight links laid back along the carrier's nose,
-- tapering and fading, whipping at the tip and not at all at the root. With
-- nothing to trail from it coils on its stand instead, which is a line
-- stowed rather than a line flying.

C[5] = {name = "4  streamer", key = "streamer",
        note = "a ribbon that trails the carrier and curls on its stand. the"
            .. " only one that answers what a flag does in motion."}

-- A ribbon: a smooth run of samples laid down as tapering, fading segments.
-- `at_s` answers a point for a parameter running 0 at the root to 1 at the
-- tip. Sampled finely enough that the corners stop being corners, which is
-- what separates a ribbon from a chain of sticks.
local function ribbon(glow, col, N, at_s, w0, w1, a0, a1)
    local px_, py_ = at_s(0)
    for i = 1, N do
        local f0, f1 = (i - 1) / N, i / N
        local nx, ny = at_s(f1)
        glow:seg_fade(px_, py_, nx, ny,
                      w0 + (w1 - w0) * f0, w0 + (w1 - w0) * f1,
                      a0 + (a1 - a0) * f0, a0 + (a1 - a0) * f1, col)
        px_, py_ = nx, ny
    end
end

C[5].ground = function(fill, glow, x, y, col, o)
    glow:halo(x, y, 15, 12, pal.a(col, 0.09))
    -- One turn and a bit, unwinding slowly. A line stowed rather than a line
    -- flying, and the shape says which without a caption.
    ribbon(glow, col, 22, function(f)
        local ang = o.t * 0.7 + f * TAU * 1.15
        local d = 5.0 + f * 8.6
        return x + math.cos(ang) * d, y + math.sin(ang) * d
    end, 3.0, 0.9, 0.95, 0.10)
    glow:ring_aa(x, y, 3.8, 1.2, pal.a(col, 0.6), facets(glow, 3.8, TAU))
    fill:disc(x, y, 2.8, 14, pal.a(col, 0.18))
    glow:disc(x, y, 1.8, 12, pal.a(pal.WHITE, 0.85))
end

C[5].held = function(fill, glow, x, y, col, o)
    glow:halo(x, y, 26, 14, pal.a(col, 0.11))
    -- Made fast at the engine rather than the nose, which is where a line
    -- fixed to a hull would actually run from.
    local hx, hy = o.hx or 1, o.hy or 0
    local ax, ay = x - hx * (HULL - 2), y - hy * (HULL - 2)
    local base = math.atan2(-hy, -hx)
    ribbon(glow, col, 20, function(f)
        local ang = base + math.sin(o.t * 4.2 - f * 3.4) * 0.36 * f
        local d = f * 32
        return ax + math.cos(ang) * d, ay + math.sin(ang) * d
    end, 3.6, 0.9, 1, 0.06)
    glow:ring_aa(x, y, HULL + 2, 1.3, pal.a(col, 0.65),
                 facets(glow, HULL + 2, TAU))
end

-- --- 5. cage ------------------------------------------------------------------
--
-- A flag as something held rather than something worn: a bright core inside
-- two counter turning frames that never line up. Taken, the frames grow out
-- around the hull and their sides come apart, so the ship flies inside a cage
-- that is visibly failing to hold what it has.

C[6] = {name = "5  cage", key = "cage",
        note = "a core in two counter turning frames. taken, they grow around"
            .. " the hull and come apart at the sides."}

local function frame_at(glow, x, y, col, r, ph, w, a, burst)
    local pts = {}
    for i = 0, 2 do
        local ang = ph + i / 3 * TAU
        pts[#pts + 1] = x + math.cos(ang) * r
        pts[#pts + 1] = y + math.sin(ang) * r
    end
    if burst <= 0 then
        glow:outline(pts, w, pal.a(col, a), true)
        return
    end
    -- Broken: every side pushed out along its own outward normal, so the
    -- three of them separate instead of scaling up together.
    for i = 1, 6, 2 do
        local j = (i + 1 < 6) and i + 2 or 1
        local mx = (pts[i] + pts[j]) / 2 - x
        local my = (pts[i + 1] + pts[j + 1]) / 2 - y
        local ml = math.sqrt(mx * mx + my * my)
        glow:seg(pts[i] + mx / ml * burst, pts[i + 1] + my / ml * burst,
                 pts[j] + mx / ml * burst, pts[j + 1] + my / ml * burst,
                 w, pal.a(col, a), true)
    end
end

C[6].ground = function(fill, glow, x, y, col, o)
    glow:halo(x, y, 15, 12, pal.a(col, 0.10))
    frame_at(glow, x, y, col, 13, o.t * 0.34, 1.35, 0.85, 0)
    frame_at(glow, x, y, col, 8.9, -o.t * 0.46 + TAU / 6, 1.1, 0.6, 0)
    fill:disc(x, y, 3.4, 14, pal.a(col, 0.2))
    glow:disc(x, y, 2.0, 12, pal.a(pal.WHITE, 0.85))
end

C[6].held = function(fill, glow, x, y, col, o)
    glow:halo(x, y, 32, 14, pal.a(col, 0.13))
    local open = 3.0 + math.sin(o.t * 3.0) * 1.2
    frame_at(glow, x, y, col, 24, o.t * 0.9, 1.5, 1, open)
    frame_at(glow, x, y, col, 17.5, -o.t * 1.2 + TAU / 6, 1.2, 0.6, open * 0.5)
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
-- flag hangs the wrong way and only the symmetric ones get away with it.
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

-- The Apex silhouette, for scale and for something to hang a held flag on.
-- arena/world.lua owns the real one; this is its polygon with none of the
-- plates, lamps or engine work, because the sheet is about the flag.
local APEX = {0,21, 1.6,12, 2.6,5, 6.5,-1, 11,-9, 8.5,-11.5, 3.5,-6.5, 3,-10.5,
              0,-11.5, -3,-10.5, -3.5,-6.5, -8.5,-11.5, -11,-9, -6.5,-1,
              -2.6,5, -1.6,12}

-- Placed by arena/world.lua's own turn, which negates the polygon's y: at a
-- heading of zero the nose is at world y minus twenty one, and world y runs
-- down the screen, so zero points up it. See the render script, where top and
-- bottom are swapped for exactly this reason.
local function hull(x, y, heading, col)
    local ca, sa = math.cos(heading), math.sin(heading)
    local pts = {}
    for i = 1, #APEX, 2 do
        pts[i] = x + APEX[i] * ca + APEX[i + 1] * sa
        pts[i + 1] = y + APEX[i] * sa - APEX[i + 1] * ca
    end
    L_FILL:fan(pts, pal.a(col, 0.09))
    L_GLOW:outline(pts, 1.1, pal.a(col, 0.5), true)
end

-- The pickup radius the core actually tests, which no flag drawing has shown.
local function reach(x, y, col)
    L_GLOW:ring_aa(x, y, 18, 0.8, pal.a(col, 0.12), 44)
end

-- What a drawing costs the layer it lands on, in triangles. Worth putting on
-- the sheet rather than working out afterwards: a world layer has a hard
-- ceiling, four flags and a dozen greens share it with every hull and every
-- round in flight, and whatever falls past the cap that frame just vanishes.
local function cost(fn)
    local before = tris
    fn()
    return tris - before
end

local T = 1.9        -- the clock every still on this sheet is frozen at
-- A hull flying up the sheet, and the same direction handed to a flag as the
-- world vector its nose points along. World y runs down the screen.
local UP = 0
local NOSE = {hx = 0, hy = -1}

local y = H - 44
text(40, y, "VECTORWAKE  /  FLAG GRAPHICS", 14, "#cfe0f5", "start", 3)
y = y - 22
y = note(40, y, "five of them, against what ships. every shape runs through"
         .. " client/render/vec.lua, the mesh builder the arena uses, so"
         .. " nothing on this sheet is a picture of a drawing: what lands"
         .. " here lands in the game.")
rule(y - 6)

-- --- on a stand --------------------------------------------------------------

y = y - 34
head(40, y, "on a stand, x4")
y = y - 17
y = note(40, y, "unowned, yours, theirs. the faint outer ring is the eighteen"
         .. " pixel pickup radius, which is the shape a pilot is really"
         .. " flying at.")

local COLS = {{NEUTRAL, "unowned"}, {FRIEND, "yours"}, {ENEMY, "theirs"}}
local RW, RH = 192, 158
y = y - 22

for ri, cand in ipairs(C) do
    local cy = y - RH / 2
    text(48, cy + 30, cand.name, 11, "#9fb6d4", "start", 1)
    local under = note(48, cy + 12, cand.note, 58, 14)
    local gcost = 0
    for ci, c in ipairs(COLS) do
        local cx = 636 + (ci - 1) * RW
        at(4, cx, cy, function()
            reach(cx, cy, c[1])
            gcost = cost(function()
                cand.ground(L_FILL, L_GLOW, cx, cy, c[1], {t = T})
            end)
        end)
        if ri == 1 then text(cx, y + 6, c[2], 9, "#4a5768") end
    end
    local hcost = cost(function()
        -- Off the page, purely to price it. Nothing here reaches the sheet.
        local sink = {}
        for _, k in ipairs({art_fill, art_glow}) do sink[#sink + 1] = #k end
        cand.held(L_FILL, L_GLOW, -4000, -4000, NEUTRAL,
                  {t = T, hx = 0, hy = -1})
        for i, k in ipairs({art_fill, art_glow}) do
            for j = #k, sink[i] + 1, -1 do k[j] = nil end
        end
    end)
    text(48, under - 2, string.format("%d triangles standing, %d carried",
                                      gcost, hcost), 9, "#3d4a5d", "start")
    y = y - RH
end

rule(y + 22)

-- --- carried -----------------------------------------------------------------

y = y - 18
head(40, y, "carried, x3")
y = y - 17
y = note(40, y, "an Apex heading up the sheet. this is the state that decides"
         .. " a round, so it has to carry across a map, and it has to leave"
         .. " the hull under it visible enough to shoot at.")

local KH = 224
y = y - 16

for ri, cand in ipairs(C) do
    local cy = y - KH / 2
    text(48, cy + 6, cand.name, 11, "#9fb6d4", "start", 1)
    for ci, c in ipairs({{FRIEND, "yours"}, {ENEMY, "theirs"}}) do
        local cx = 646 + (ci - 1) * 240
        at(3, cx, cy, function()
            hull(cx, cy, UP, c[1])
            cand.held(L_FILL, L_GLOW, cx, cy, c[1],
                      {t = T, hx = NOSE.hx, hy = NOSE.hy})
        end)
        if ri == 1 then text(cx, y + 6, c[2], 9, "#4a5768") end
    end
    y = y - KH
end

rule(y + 26)

-- --- at size -----------------------------------------------------------------

y = y - 20
head(40, y, "at size, x1")
y = y - 17
y = note(40, y, "sixteen pixel tiles and an Apex for scale. the row that"
         .. " decides, because a flag is read at a glance, across a map, by"
         .. " somebody being shot at.")

local SH = 150
y = y - 14
grid(40, y - SH + 26, W - 80, SH - 34)

for i, cand in ipairs(C) do
    local cx = 40 + 100 + (i - 1) * 193
    local cy = y - SH / 2 + 10
    at(1, cx, cy, function()
        reach(cx - 46, cy, NEUTRAL)
        cand.ground(L_FILL, L_GLOW, cx - 46, cy, NEUTRAL, {t = T})
        hull(cx + 46, cy, UP, FRIEND)
        cand.held(L_FILL, L_GLOW, cx + 46, cy, FRIEND,
                  {t = T, hx = NOSE.hx, hy = NOSE.hy})
    end)
    text(cx, y - SH + 8, cand.name, 9, "#4a5768")
end
y = y - SH

rule(y + 4)

-- --- in a room ---------------------------------------------------------------
--
-- The condition every one of these is actually judged in: four flags across a
-- Capture the Flag map at the zoom the game is played at, two on their
-- stands, one lying where its carrier died, one running. Nothing on this
-- band is magnified. If a candidate needs a caption here, it has lost.

y = y - 34
head(40, y, "in a room, x1")
y = y - 17
y = note(40, y, "four flags at the zoom the game is played at: two standing,"
         .. " one dropped, one running for home with two hulls after it."
         .. " nothing here is magnified.")

-- A wall run, drawn the way terrain reads rather than the way it is built:
-- a dark body with a lit face, which is all a flag has to compete with.
local function wall(x0, y0, w, h)
    local lit = pal.a(pal.WALL_LIT, 0.22)
    L_FILL:rect(x0, y0, w, h, pal.a(pal.PANEL_INK, 0.22))
    L_GLOW:seg(x0, y0, x0 + w, y0, 0.7, lit)
    L_GLOW:seg(x0, y0 + h, x0 + w, y0 + h, 0.7, lit)
    L_GLOW:seg(x0, y0, x0, y0 + h, 0.7, lit)
    L_GLOW:seg(x0 + w, y0, x0 + w, y0 + h, 0.7, lit)
end

local SCH = 176
for _, cand in ipairs(C) do
    local cy = y - SCH / 2
    local x0 = 250
    grid(x0 - 40, cy - 66, 940, 132)
    text(48, cy + 2, cand.name, 11, "#9fb6d4", "start", 1)
    at(1, x0, cy, function()
        wall(x0 + 60, cy - 66, 16, 46)
        wall(x0 + 330, cy + 16, 96, 16)
        wall(x0 + 560, cy - 66, 16, 62)
        wall(x0 + 700, cy + 30, 130, 16)
        -- Two standing, one theirs and one nobody's yet.
        cand.ground(L_FILL, L_GLOW, x0 + 30, cy - 30, ENEMY, {t = T})
        cand.ground(L_FILL, L_GLOW, x0 + 250, cy + 34, NEUTRAL, {t = T})
        -- One dropped, where somebody died with it.
        cand.ground(L_FILL, L_GLOW, x0 + 470, cy - 40, FRIEND, {t = T + 0.9})
        -- One running, with two hulls after it.
        local rx, ry_ = x0 + 760, cy - 16
        hull(rx, ry_, -0.35, FRIEND)
        cand.held(L_FILL, L_GLOW, rx, ry_, FRIEND,
                  {t = T, hx = math.sin(-0.35), hy = -math.cos(-0.35)})
        hull(rx - 74, ry_ - 34, -0.2, ENEMY)
        hull(rx - 100, ry_ + 20, -0.5, ENEMY)
    end)
    y = y - SCH
end

rule(y + 16)

-- --- the carry clock ---------------------------------------------------------
--
-- Capture the Flag drops a carried flag after thirty seconds and nothing on
-- screen counts them down. The pennant has nowhere to put a clock. Every
-- candidate above is drawn round, so all of them have a rim to drain, which
-- is an argument for round on its own.

y = y - 34
head(40, y, "the carry clock, x3")
y = y - 17
y = note(40, y, "thirty seconds, invisible today. a draining rim is free on"
         .. " anything drawn round, and turns the last five seconds into"
         .. " something the whole room can see coming.")

y = y - 18
local CKH = 262
for i, f in ipairs({0, 0.45, 0.8, 0.95}) do
    local cx = 220 + (i - 1) * 270
    local cy = y - CKH / 2 - 6
    at(3, cx, cy, function()
        hull(cx, cy, UP, FRIEND)
        C[2].held(L_FILL, L_GLOW, cx, cy, FRIEND,
                  {t = T, hx = NOSE.hx, hy = NOSE.hy})
        -- Counterclockwise from noon, so it empties the way a fuse burns
        -- down, and the last fifth turns to the other side's color, because
        -- that is who the flag is about to be available to again.
        local hot = f > 0.8
        L_GLOW:ring_aa(cx, cy, 34, 1.0, pal.a(FRIEND, 0.14), 64)
        L_GLOW:arc_aa(cx, cy, 34, -math.pi / 2, -math.pi / 2 - (1 - f) * TAU,
                      2.0, 64,
                      pal.a(hot and pal.ENEMY or FRIEND, hot and 1 or 0.9))
    end)
    text(cx, y - CKH + 6, string.format("%.0f seconds left", 30 * (1 - f)), 9,
         "#4a5768")
end
y = y - CKH

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
print(string.format("%d shapes, %d triangles, %d px of page left -> %s",
                    shapes, tris, y, out_path))
