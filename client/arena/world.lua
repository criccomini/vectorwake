-- Drawing the world.
--
-- Ships, weapons, flags, stars and terrain, in the two world layers:
-- a dark alpha fill that occludes what is behind it, and an additive glow
-- that carries every bright edge. Nothing here reads input or advances
-- anything; it asks the simulation what is true and describes it in
-- triangles.
--
-- The look is the one docs/design/identity.md asks for: bright geometric
-- silhouettes on a near-black field, thin outlines over a darker fill, bolts
-- with sharp falloff and short trails, blasts that bloom into rings rather
-- than fireballs.

local pal = require("arena.palette")
local fx = require("arena.fx")

local M = {}

local TILE = 16
local TAU = math.pi * 2

-- The ring of sparks a streaking hull wears. An odd count on purpose: an even
-- ring keeps presenting opposite pairs, and two bright opposites with the
-- rest between beats read as an axis rather than a circle.
local GLEAM_SPARKS = 7

-- Is this world point outside what the camera can see? Every draw that walks
-- a list of things in the world asks this first.
--
-- Declared here, above everything, because a `local function` is only in
-- scope below its own declaration: sitting further down the file it was a nil
-- global to every function defined above it, which is a crash rather than a
-- missing cull. That has now been the shape of three bugs in this client.
local function outside(cull, x, y)
    return x < cull.x0 or x > cull.x1 or y < cull.y0 or y > cull.y1
end


-- Hulls, in local pixels with the nose along +y. Shape carries class and
-- color carries team, so neither has to carry both, and every class has to be
-- identifiable by silhouette alone at radar scale, which means each one needs
-- a front that is visibly not its back. See docs/design/ships.md.
--
-- `poly` is that silhouette, and it is the only part the menu's thumbnails
-- draw. The rest is what a hull looks like once it is close enough to matter:
-- `plates` are closed interior loops, `lines` open polylines, `canopy` the one
-- bright cell every hull carries forward of center, `tubes` the hardpoints a
-- class actually fires from, `pods` its lamps and dispensers, `jets` where
-- thrust comes out, and `dim` how brightly the whole thing draws.
M.HULLS = {
    -- Apex: a dart whose wings sweep back far enough to clear its own engine
    -- block. Fastest and sharpest turn in the game.
    {poly = {0,21, 1.6,12, 2.6,5, 6.5,-1, 11,-9, 8.5,-11.5, 3.5,-6.5, 3,-10.5,
             0,-11.5, -3,-10.5, -3.5,-6.5, -8.5,-11.5, -11,-9, -6.5,-1, -2.6,5,
             -1.6,12},
     plates = {{0,6.5, 2.2,2, 1.8,-6, 0,-8, -1.8,-6, -2.2,2}},
     lines = {{0,19.8, 2.6,5, 6.5,-1}, {0,19.8, -2.6,5, -6.5,-1},
              {5,0.2, 9.3,-8.2}, {-5,0.2, -9.3,-8.2}, {2.6,1.5, 6,-1.6},
              {-2.6,1.5, -6,-1.6}},
     canopy = {0,15.5, 1.5,10.5, 0,7.6, -1.5,10.5},
     tubes = {{4.2, 3, 4.2, -1, 1.4}, {-4.2, 3, -4.2, -1, 1.4}},
     pods = {{0, 20, 1.5}},
     jets = {-1.8,-11, 1.8,-11},
     fit = {1, 1.007575758, -0.662878788}},
    -- Wedge: a platform rather than a fighter. The bomb bay runs most of its
    -- length and the tube feeding it is the brightest thing on the hull.
    {poly = {0,14, 2.6,13, 4.6,7.5, 7.2,1.5, 15.5,-5.5, 16,-9, 9,-7.5, 8,-11,
             3.2,-12.5, 0,-12.5, -3.2,-12.5, -8,-11, -9,-7.5, -16,-9,
             -15.5,-5.5, -7.2,1.5, -4.6,7.5, -2.6,13},
     plates = {{3.4,5, 3.4,-10, -3.4,-10, -3.4,5}},
     lines = {{7.2,1.5, 15,-5.2}, {-7.2,1.5, -15,-5.2}, {11,-2.2, 11.6,-7.2},
              {-11,-2.2, -11.6,-7.2}, {4.4,4.4, 4.4,-8}, {-4.4,4.4, -4.4,-8},
              {-3.4,-2.5, 3.4,-2.5}},
     canopy = {0,12.4, 1.8,10.2, 1.6,7.6, -1.6,7.6, -1.8,10.2},
     tubes = {{0, 3.6, 0, -8.6, 3.2}},
     jets = {-5.6,-12, 5.6,-12},
     fit = {1.0390625, 0.830188679, 0.377358491}},
    -- Chord: a bow with a sensor housing at the middle of it, because what
    -- this hull does for a team is see.
    {poly = {0,13.5, 5.5,12, 11.5,7.5, 16.5,0.5, 18,-4, 14.5,-6, 11,-2.5,
             6.5,1.5, 2.5,3.5, 0,3.8, -2.5,3.5, -6.5,1.5, -11,-2.5, -14.5,-6,
             -18,-4, -16.5,0.5, -11.5,7.5, -5.5,12},
     plates = {{0,11.5, 2.2,9.5, 2.2,6.5, 0,5, -2.2,6.5, -2.2,9.5},
               {12.8,-0.6, 16.4,-3.4, 15,-5.6, 11.6,-2.4},
               {-11.6,-2.4, -15,-5.6, -16.4,-3.4, -12.8,-0.6}},
     lines = {{4,10.6, 13.2,3.2}, {-4,10.6, -13.2,3.2}, {2.5,3.5, 5.5,11.6},
              {-2.5,3.5, -5.5,11.6}, {8,0.4, 9.6,5.6}, {-8,0.4, -9.6,5.6}},
     canopy = {0,10.2, 1.3,8.4, 0,6.4, -1.3,8.4},
     tubes = {{15, -2, 15, 2.6, 1.4}, {-15, -2, -15, 2.6, 1.4}},
     pods = {{0, 8.3, 2.4}},
     jets = {-8.5,-2.2, 8.5,-2.2},
     fit = {1.140625, 0.923076923, -2.461538462}},
    -- Anvil: nothing on it is allowed to look sharp. Two bomb tubes on a flat
    -- bow face, an armour belt across it, four engines and no wings at all.
    {poly = {0,15, 6.5,14.2, 11,10, 13.5,3, 13.5,-4, 11,-9.5, 6.5,-12, 0,-12,
             -6.5,-12, -11,-9.5, -13.5,-4, -13.5,3, -11,10, -6.5,14.2},
     plates = {{9,12.4, 11.4,8.4, -11.4,8.4, -9,12.4},
               {0,5.4, 4.2,0, 0,-5.4, -4.2,0}},
     lines = {{9,8, 9,-8}, {-9,8, -9,-8}, {5.6,3.2, 9,3.2}, {-5.6,3.2, -9,3.2},
              {5.6,-3.2, 9,-3.2}, {-5.6,-3.2, -9,-3.2}, {-8,-9.6, 8,-9.6}},
     canopy = {3.4,14, 2.6,11.4, -2.6,11.4, -3.4,14},
     tubes = {{5.2, 9.6, 5.2, 15.2, 2.2}, {-5.2, 9.6, -5.2, 15.2, 2.2}},
     jets = {-9,-10.6, -3.5,-12, 3.5,-12, 9,-10.6},
     fit = {1, 0.954063604, -1.551236749}},
    -- Cipher: a knife. Draws dimmer than the rest of the roster on purpose,
    -- since the class is meant to be hard to pick out of a fight.
    {poly = {0,23, 1.7,7, 3.4,-2, 3,-9, 6.5,-12.5, 2.2,-11.5, 1.6,-13, 0,-13,
             -1.6,-13, -2.2,-11.5, -6.5,-12.5, -3,-9, -3.4,-2, -1.7,7},
     plates = {{0,19, 1.4,4, 0,-6, -1.4,4}},
     lines = {{0,22.4, 3.2,-2}, {0,22.4, -3.2,-2}, {3.2,-9.4, 5.9,-12.2},
              {-3.2,-9.4, -5.9,-12.2}},
     canopy = {0,17.5, 0.9,14, 0,11.5, -0.9,14},
     jets = {0,-13}, dim = 0.72,
     fit = {1.384615385, 1.140625, -4.234375}},
    -- Facet: two barrels hanging off the shoulders, out past the nose, so the
    -- one thing worth knowing about it reads from any angle.
    {poly = {0,15, 4.2,10.5, 8.5,6, 11.5,-2, 9.5,-10, 4.5,-13, 0,-13, -4.5,-13,
             -9.5,-10, -11.5,-2, -8.5,6, -4.2,10.5},
     plates = {{0,11.5, 4.6,6.4, 4,-1, -4,-1, -4.6,6.4},
               {4.4,-4.4, 3.6,-10.4, -3.6,-10.4, -4.4,-4.4}},
     lines = {{0,14.4, 8,6.4}, {0,14.4, -8,6.4}, {10.6,-1.6, 8.8,-9.2},
              {-10.6,-1.6, -8.8,-9.2}, {4.6,2, 10.9,0.4}, {-4.6,2, -10.9,0.4},
              {6.2,-4, 6.2,-10}, {-6.2,-4, -6.2,-10}},
     canopy = {0,9.6, 2.4,6.4, 0,4.4, -2.4,6.4},
     tubes = {{6.6, 7.2, 6.6, 13.6, 2.2}, {-6.6, 7.2, -6.6, 13.6, 2.2}},
     jets = {-2.6,-13, 2.6,-13},
     fit = {1.173913043, 0.964285714, -0.464285714}},
    -- Lattice: trussed arms rather than solid ones, which is the whole
    -- difference between a cross and a structure somebody planted.
    {poly = {0,17, 2.8,12.5, 2.8,5.5, 11.5,4.5, 15,1.5, 11.5,-1.5, 2.8,-2.5,
             2.8,-11, 2,-14, 0,-14, -2,-14, -2.8,-11, -2.8,-2.5, -11.5,-1.5,
             -15,1.5, -11.5,4.5, -2.8,5.5, -2.8,12.5},
     plates = {{0,5, 3.2,1.5, 0,-2, -3.2,1.5}},
     lines = {{4.5,4.2, 6,-2.2}, {-4.5,4.2, -6,-2.2}, {7.5,3.9, 9,-2},
              {-7.5,3.9, -9,-2}, {-2.8,12, 2.8,9.6}, {2.8,9, -2.8,6.6},
              {-2.8,-4.6, 2.8,-7}, {2.8,-7.6, -2.8,-10}},
     canopy = {0,14.6, 1.5,12.6, 0,10.8, -1.5,12.6},
     pods = {{13.6, 1.5, 1.7}, {-13.6, 1.5, 1.7}, {0, -13.2, 1.5}},
     jets = {-1.8,-14, 1.8,-14},
     fit = {0.8842, 0.85096, -0.46632}},
}

-- How far from the camera a hull keeps its plates, panel lines and lamps.
-- Past this it draws silhouette, canopy, hardpoints and engines only, which
-- costs a quarter less and is not visible without looking for it. The reason
-- is the glow layer's capacity, which an overflow does not report: it simply
-- stops drawing, and whichever strokes fall past the cap that frame vanish.
M.DETAIL_RANGE = 260

-- --- baking a hull ---------------------------------------------------------
--
-- Everything about a hull that never changes, worked out once at load.

-- Twice the signed area, whose sign is the winding.
local function turn(p)
    local a, n = 0, #p
    for i = 1, n, 2 do
        local j = (i + 1 < n) and i + 2 or 1
        a = a + p[i] * p[j + 1] - p[j] * p[i + 1]
    end
    return a
end

-- Triangulate by ear clipping, into flat vertex-index triples.
--
-- The body fill used to fan from the centroid, which covers a hull only if the
-- centroid can see all of it. Every hull that shipped before this was
-- star-shaped like that, and that is exactly why none of them had a notch: the
-- Apex's wings could not clear its engine block without the fill spilling into
-- the gap between them. Run once, at load, so a frame pays nothing for it.
local function triangulate(p)
    local n = #p / 2
    local idx = {}
    for i = 1, n do idx[i] = (turn(p) > 0) and i or (n + 1 - i) end

    local function cross(a, b, c)
        return (p[b * 2 - 1] - p[a * 2 - 1]) * (p[c * 2] - p[a * 2])
             - (p[b * 2] - p[a * 2]) * (p[c * 2 - 1] - p[a * 2 - 1])
    end

    -- Is vertex q inside the triangle abc? Barycentric, since an ear may not
    -- swallow a vertex of the polygon it is being cut from.
    local function inside(q, a, b, c)
        local qx, qy = p[q * 2 - 1], p[q * 2]
        local ax, ay = p[a * 2 - 1], p[a * 2]
        local bx, by = p[b * 2 - 1], p[b * 2]
        local cx, cy = p[c * 2 - 1], p[c * 2]
        local d = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
        if math.abs(d) < 1e-12 then return false end
        local s = ((by - cy) * (qx - cx) + (cx - bx) * (qy - cy)) / d
        local t = ((cy - ay) * (qx - cx) + (ax - cx) * (qy - cy)) / d
        return s > 1e-9 and t > 1e-9 and (1 - s - t) > 1e-9
    end

    local out, guard = {}, 0
    while #idx > 3 and guard < 4096 do
        guard = guard + 1
        local cut
        for i = 1, #idx do
            local a = idx[(i - 2) % #idx + 1]
            local b = idx[i]
            local c = idx[i % #idx + 1]
            if cross(a, b, c) > 0 then
                local clear = true
                for k = 1, #idx do
                    local q = idx[k]
                    if q ~= a and q ~= b and q ~= c and inside(q, a, b, c) then
                        clear = false
                        break
                    end
                end
                if clear then
                    out[#out + 1], out[#out + 2], out[#out + 3] = a, b, c
                    cut = i
                    break
                end
            end
        end
        if not cut then break end
        table.remove(idx, cut)
    end
    if #idx == 3 then
        out[#out + 1], out[#out + 2], out[#out + 3] = idx[1], idx[2], idx[3]
    end
    return out
end

-- Refit a hull to its collision-space budget before deriving any render data.
-- The three numbers are horizontal scale, vertical scale and vertical offset.
-- Every part moves together, including hardpoints and engine lamps, so the
-- drawing cannot leave an old piece outside its new footprint.
-- `client/tests/hull_fit_test.lua` measures the finished result.
local function refit(h, f)
    local sx, sy, oy = f[1], f[2], f[3]
    local line_scale = math.sqrt(sx * sy)
    local function pts(t)
        for i = 1, #t, 2 do
            t[i] = t[i] * sx
            t[i + 1] = t[i + 1] * sy + oy
        end
    end
    pts(h.poly)
    if h.canopy then pts(h.canopy) end
    if h.jets then pts(h.jets) end
    if h.plates then for _, q in ipairs(h.plates) do pts(q) end end
    if h.lines then for _, q in ipairs(h.lines) do pts(q) end end
    if h.pods then
        for _, q in ipairs(h.pods) do
            q[1], q[2], q[3] = q[1] * sx, q[2] * sy + oy,
                               q[3] * line_scale
        end
    end
    if h.tubes then
        for _, q in ipairs(h.tubes) do
            q[1], q[2] = q[1] * sx, q[2] * sy + oy
            q[3], q[4] = q[3] * sx, q[4] * sy + oy
            q[5] = q[5] * line_scale
        end
    end
end

for _, h in ipairs(M.HULLS) do
    if h.fit then refit(h, h.fit) h.fit = nil end
    local p = h.poly
    local n = #p / 2
    local w = (turn(p) > 0) and 1 or -1

    local sx, sy = 0, 0
    local nose, lo, hi = p[2], p[2], p[2]
    for i = 1, #p, 2 do
        sx, sy = sx + p[i], sy + p[i + 1]
        if p[i + 1] > nose then nose = p[i + 1] end
        if p[i + 1] < lo then lo = p[i + 1] end
        if p[i + 1] > hi then hi = p[i + 1] end
    end
    h.cx, h.cy = sx / n, sy / n
    h.nose = nose

    -- The circle that holds this hull, measured from the point it turns
    -- about. What it is for is anything drawn around the outside of a ship:
    -- an Anvil is twice the beam of a Cipher, and one constant radius would
    -- put the same decoration inside one hull and a long way off the other.
    local far = 0
    for i = 1, #p, 2 do
        local d = p[i] * p[i] + p[i + 1] * p[i + 1]
        if d > far then far = d end
    end
    h.reach = math.sqrt(far)

    -- The outward normal of every edge, and from those, how brightly the edge
    -- draws: a light fixed to the hull's own nose. Fixed to the world instead,
    -- the same ship would look like a different ship depending on which way it
    -- was pointing, and the silhouette is the entire identity system.
    --
    -- Two weights rather than one because the wide skirt of the bloom wants a
    -- flatter falloff than the edge does, and a power in a draw loop on a Lua
    -- 5.1 interpreter is not free.
    local en = {}
    h.wide, h.band, h.hot = {}, {}, {}
    for v = 1, n do
        local a, b = v, (v % n) + 1
        local dx = p[b * 2 - 1] - p[a * 2 - 1]
        local dy = p[b * 2] - p[a * 2]
        local len = math.sqrt(dx * dx + dy * dy)
        if len < 1e-9 then len = 1 end
        en[v * 2 - 1], en[v * 2] = dy / len * w, -dx / len * w
        local light = 0.40 + 0.60 * (0.5 + 0.5 * en[v * 2])
        h.wide[v], h.band[v], h.hot[v] = light ^ 0.55, light ^ 0.8, light
    end

    -- The direction the bloom leaves each vertex by: the mitre between the two
    -- edges that meet there, clamped hard. Unclamped, a nose as sharp as the
    -- Apex's throws a thirty-pixel spike of light off its tip.
    h.nrm = {}
    for v = 1, n do
        local u = (v - 2) % n + 1
        local mx = en[u * 2 - 1] + en[v * 2 - 1]
        local my = en[u * 2] + en[v * 2]
        local len = math.sqrt(mx * mx + my * my)
        if len < 1e-6 then
            mx, my, len = en[v * 2 - 1], en[v * 2], 1
        end
        mx, my = mx / len, my / len
        local d = mx * en[v * 2 - 1] + my * en[v * 2]
        if d < 0.35 then d = 0.35 end
        local k = 1 / d
        if k > 1.35 then k = 1.35 end
        h.nrm[v * 2 - 1], h.nrm[v * 2] = mx * k, my * k
    end

    -- Where each vertex sits between stern and bow, which is what lights the
    -- front of the body and leaves the back of it nearly black.
    local span = (hi - lo)
    if span < 1e-6 then span = 1 end
    h.lit = {}
    for v = 1, n do
        local t = (p[v * 2] - lo) / span
        h.lit[v] = t * t
    end
    -- Halfway up the hull, which is where a thumbnail has to be centered: every
    -- one of these reaches further forward than back, so its origin is not its
    -- middle and a row of them drawn about the origin sits low.
    h.mid = (lo + hi) / 2

    h.tris = triangulate(p)

    -- Somewhere to transform into. A fresh table per part per hull per frame
    -- is a hundred tables a frame and all of them garbage, on a collector that
    -- runs in the same thread as the draw.
    h.tmp, h.ntmp, h.ctmp = {}, {}, {}
    h.ptmp, h.ltmp = {}, {}
    for k = 1, #(h.plates or {}) do h.ptmp[k] = {} end
    for k = 1, #(h.lines or {}) do h.ltmp[k] = {} end
end


-- --- the starfield ---------------------------------------------------------
--
-- Depth, from parallax, without storing a single star.
--
-- Each layer is an infinite grid of cells with at most one star in each,
-- placed by hashing the cell's own coordinates. Nothing is kept between
-- frames and the field extends as far as anyone can fly, so a map twice the
-- size costs exactly the same.
--
-- A layer at depth `k` puts a star whose base position is `b` at the world
-- position `b + cam*(1 - k)`, which lands on screen at `b - cam*k`. So `k` is
-- literally how fast the layer moves against the camera: 1 is the arena's own
-- plane, 0 is painted on the glass. The visible cells are the ones whose base
-- falls within a half-extent of `cam*k`, which is the only arithmetic here.
--
-- They were world-locked and built once before this, on the reasoning that a
-- parallax layer would slide against the terrain and read as a bug. It reads
-- as distance, which is the entire reason to have stars at all.

local STARS = {
    -- depth, cell size in world px, star size, color, how many cells in
    -- sixteen carry one. Farther is denser, smaller and dimmer, which is what
    -- distance does.
    {k = 0.18, cell =  54, size = 1.1, col = pal.STAR_FAR,  fill = 13},
    {k = 0.36, cell =  92, size = 1.6, col = pal.STAR,      fill = 11},
    {k = 0.60, cell = 168, size = 2.3, col = pal.STAR_NEAR, fill =  9},
}

-- Lehmer, and the multiplier matters: Lua has no integers here, and the
-- 1103515245 everything else uses overflows a double's exact range on a
-- 31-bit seed, throwing away the low bits. 48271 stays exact, which is what
-- keeps a hashed grid from banding.
local function lcg(s)
    return (s * 48271) % 2147483647
end

-- Eight brightnesses per layer, made once. A star's alpha used to be a fresh
-- {r,g,b,a} per star per frame -- three hundred and fifty tables a frame,
-- twenty thousand a second, all of them garbage -- and at a pixel and a half
-- across nobody can tell an eighth of a step of alpha from a sixteenth.
local STAR_SHADES = 8
for _, L in ipairs(STARS) do
    L.shade = {}
    for i = 1, STAR_SHADES do
        L.shade[i] = pal.a(L.col, 0.45 + (i - 1) / (STAR_SHADES - 1) * 0.55)
    end
    L.bloom = pal.a(L.col, 0.30)
end

-- Nebulae: the layer behind the layers. A few enormous, extremely faint
-- radial fades drifting at the deepest parallax, whose whole job is making
-- the black feel like a volume instead of a ceiling. Alpha stays under a
-- twelfth, because identity.md's line is that the background never competes
-- with a projectile, and a nebula that reads as an object has changed genre.
-- The same hashed-cell scheme as the stars, so nothing is stored and a map
-- twice the size costs the same.
local NEBULA = {k = 0.12, cell = 720, fill = 9}
local NEB_COLS = {
    pal.a(pal.rgb(0x2b4268), 0.070),
    pal.a(pal.rgb(0x4a306e), 0.055),
    pal.a(pal.rgb(0x1d4a5a), 0.060),
}

-- What a star costs where it is drawn: a rect on the fill layer, and on the
-- near layer sometimes an eight-segment halo on the glow layer. Published
-- because the budget below is only as good as the drawing agreeing with it,
-- and a test that watches the drawing is how that stays true.
local STAR_VERTS = 6
local HALO_SEGS = 8
local HALO_VERTS = HALO_SEGS * 3
M.STAR_VERTS, M.HALO_SEGS = STAR_VERTS, HALO_SEGS

-- Room for everything in the world that is not a star, in vertices, on each
-- of the two per-frame layers.
--
-- Unlike the starfield these do not follow the window: what fills them is
-- hulls, bolts and blasts, and how many of those are on screen is a
-- property of the room. Sixty-four seats of detailed hull is past the glow
-- figure already and always has been; see the ceiling note where the layers
-- are made.
local FILL_FIGHT = 3072
-- Grown when the trails and the wall light arrived: sixty-four ribbons at
-- M.TRAIL_VERTS each and ten lights' worth of lit edges are about seven
-- thousand vertices on a bad frame, and a glow layer that runs out does not
-- report it, it just stops drawing whatever came last.
-- Raised again for the blooms: every bolt, bomb, hull, engine and shockwave
-- now sheds a six-segment halo of its own, which is eighteen vertices each
-- and a few thousand across a busy frame.
local GLOW_FIGHT = 40960

-- Capacities move in steps of this, so dragging a window edge does not
-- allocate a new buffer on every frame of the drag.
local BUDGET_STEP = 1024

-- The most a frame of starfield can ask for at this view size, in vertices,
-- on the fill layer and on the glow layer.
--
-- This is a bound rather than a measurement, and deliberately so: a capacity
-- that is short does not report anything, it just stops drawing, which is the
-- bug this exists to prevent. So the worst case is taken at face value. Every
-- cell in range carries a star and every near star blooms, which overshoots
-- the real count by about a third on the fill layer and by a lot on the glow
-- one, where a bloom is one star in seventeen. Tightening the glow figure
-- would buy back a few hundred vertices at a laptop's size, against a fight
-- allowance of twenty-four thousand, in exchange for a margin somebody has to
-- keep measuring. The bound as written can be read off the table above, so it
-- moves when the table does.
--
-- `floor(u + d) - floor(u)` is at most `floor(d) + 1` whatever `u` is, so the
-- cell counts hold wherever the camera happens to sit inside a cell.
function M.star_cost(hw, hh)
    local f, g = 0, 0
    -- The nebula layer, priced like the rest: every cell carrying one.
    local nc = (math.floor(2 * hw / NEBULA.cell) + 2) *
               (math.floor(2 * hh / NEBULA.cell) + 2)
    f = f + nc * HALO_VERTS
    for li = 1, #STARS do
        local L = STARS[li]
        local cells = (math.floor(2 * hw / L.cell) + 2) *
                      (math.floor(2 * hh / L.cell) + 2)
        f = f + cells * STAR_VERTS
        if L.k > 0.5 then g = g + cells * HALO_VERTS end
    end
    return f, g
end

-- What the two per-frame world layers should hold for a view this size.
--
-- The camera holds a fixed zoom per decision 13, so the window decides how
-- much world is on screen and therefore how many stars are in it. A capacity
-- picked for one window is wrong for every other one, and wrong in the
-- direction that loses geometry: at 6144 vertices the far and middle layers
-- alone fill the buffer somewhere around 2100 points of width, and the near
-- stars, the big bright ones, stop being drawn. Whether they come back is then
-- a question of how much of the field is behind rock at that moment, which
-- changes as you fly, so they flicker.
--
-- Growth is linear in the window's area and the constant is small. At 28
-- bytes a vertex the fill layer runs about 200 kB a frame on a laptop and 860
-- kB on a 4K window, while the glow layer barely moves, since what fills it is
-- the fight rather than the sky. That is a fair price on a machine driving 4K,
-- and the reason there is no ceiling here the way there is on the terrain
-- window, whose cost is the square of its half-width in tiles.
local function step(n)
    return math.ceil(n / BUDGET_STEP) * BUDGET_STEP
end

function M.world_budget(hw, hh)
    local f, g = M.star_cost(hw, hh)
    return step(f + FILL_FIGHT), step(g + GLOW_FIGHT)
end

function M.stars(fill, glow, cam_x, cam_y, hw, hh)
    do
        local L = NEBULA
        local c = L.cell
        local ox, oy = cam_x * (1 - L.k), cam_y * (1 - L.k)
        local bx, by = cam_x * L.k, cam_y * L.k
        local i0, i1 = math.floor((bx - hw) / c), math.floor((bx + hw) / c)
        local j0, j1 = math.floor((by - hh) / c), math.floor((by + hh) / c)
        for j = j0, j1 do
            for i = i0, i1 do
                local s = lcg((i * 7907 + j * 15551 + 977) % 2147483646 + 1)
                if s % 16 < L.fill then
                    s = lcg(s)
                    local px = (i + s / 2147483647) * c + ox
                    s = lcg(s)
                    local py = (j + s / 2147483647) * c + oy
                    s = lcg(s)
                    fill:halo(px, py, 150 + (s % 160), HALO_SEGS,
                              NEB_COLS[s % #NEB_COLS + 1])
                end
            end
        end
    end
    for li = 1, #STARS do
        local L = STARS[li]
        local c = L.cell
        -- Where this layer sits in the world, and which of its cells are on
        -- screen.
        local ox, oy = cam_x * (1 - L.k), cam_y * (1 - L.k)
        local bx, by = cam_x * L.k, cam_y * L.k
        local i0, i1 = math.floor((bx - hw) / c), math.floor((bx + hw) / c)
        local j0, j1 = math.floor((by - hh) / c), math.floor((by + hh) / c)
        local size, shade = L.size, L.shade
        local bloom = L.k > 0.5 and L.bloom or nil
        for j = j0, j1 do
            for i = i0, i1 do
                local s = lcg((i * 1973 + j * 9277 + li * 26699) % 2147483646 + 1)
                if s % 16 < L.fill then
                    s = lcg(s)
                    local px = (i + s / 2147483647) * c + ox
                    s = lcg(s)
                    local py = (j + s / 2147483647) * c + oy
                    -- A star behind rock is a star shining through it: the
                    -- wall interiors live in a layer under this one.
                    if not sim.solid(math.floor(px / TILE), math.floor(py / TILE)) then
                        s = lcg(s)
                        fill:rect(px, py, size, size,
                                  shade[s % STAR_SHADES + 1])
                        -- One in a while is close enough to bloom. Additive,
                        -- so it reads as light rather than a bigger dot.
                        if bloom and s % 17 == 0 then
                            glow:halo(px + size / 2, py + size / 2, 5,
                                      HALO_SEGS, bloom)
                        end
                    end
                end
            end
        end
    end
end

-- --- static terrain --------------------------------------------------------
--
-- Walls never move, so they are built once per map into their own buffers and
-- never touched again. A per-frame rebuild of a thousand tiles was the single
-- largest thing the old renderer did, and it did it every frame.

-- Terrain for the radar, sampled once. At the radar's scale a hundred and
-- fifty tiles cross a hundred and sixty-eight pixels, so one dot every four
-- tiles is already denser than the display can show, and it turns a
-- thousand-tile scan per frame into a list of seventy.
M.radar_tiles = {}
M.radar_safe = {}
M.radar_doors = {}

-- Doors and wormholes, found once per map.
--
-- This used to be a scan: every tile in the arena, every frame, asking the
-- core what class it was. Eighty-nine tiles square is seven thousand nine
-- hundred crossings into C to find four doors, and it cost more than the
-- simulation it was drawing. The tiles do not move, so the search is a
-- property of the map and belongs where the walls are built.
M.moving_tiles = {}
-- Scenery above the ships, which is not moving geometry but is drawn on the
-- same pass, for the same reason: the static mesh is under everything.
M.over_tiles = {}

local function index_moving(x0, y0, x1, y1)
    local out, over = {}, {}
    for ty = y0, y1 do
        for tx = x0, x1 do
            local cls, variant = sim.tile(tx, ty)
            if cls == sim.T_DOOR or cls == sim.T_WORMHOLE then
                out[#out + 1] = {tx = tx, ty = ty, cls = cls, variant = variant}
            elseif cls == sim.T_OVER then
                over[#over + 1] = {tx = tx, ty = ty, variant = variant}
            end
        end
    end
    M.moving_tiles = out
    M.over_tiles = over
end

-- --- terrain ---------------------------------------------------------------
--
-- The map, in the language the hulls use: a dark body that is a hole in the
-- starfield, edges lit with falloff rather than banded, structure in a neutral
-- instrument gray, and color kept for the things that mean something.
--
-- All of it is built once into the static layers when the camera leaves its
-- window, so detail here is close to free. Only the doors and the wells are
-- drawn per frame, and they are drawn per frame because they move.

-- What a solid tile's variant says it is. Ordinary wall and border are drawn
-- as one mass; the rest are objects that happen to be solid, and each names
-- its own top-left corner, so a six-tile station is drawn once rather than
-- thirty-six times.
--
-- These are SIM_SOLID_* in sim/include/sim/sim.h, copied because Lua cannot
-- read a C header. It is the only place the numbering is written twice, so a
-- variant added there has to be added here or it draws as plain wall.
local V_BORDER = 1
local V_ROCK_A, V_ROCK_B = 2, 3
local V_ROCK_BIG, V_ROCK_BODY = 4, 5
local V_STATION, V_STATION_BODY = 6, 7

local function key(tx, ty) return ty * 1024 + tx end

-- Maximal straight runs of exposed face, along one side of a set of tiles.
--
-- Drawing a face per tile lays a segment against its neighbour at every tile
-- boundary, and additively that is a bright bead every sixteen pixels along an
-- otherwise straight wall. It is the same double-cover the hulls had at their
-- corners, and merging is both the fix and the cheaper path.
local function runs(set, cells, side, emit)
    local ax, ay                        -- toward the neighbour being tested
    local px, py                        -- toward the previous tile in a run
    if side == "n" then ax, ay, px, py = 0, -1, -1, 0
    elseif side == "s" then ax, ay, px, py = 0, 1, -1, 0
    elseif side == "w" then ax, ay, px, py = -1, 0, 0, -1
    else ax, ay, px, py = 1, 0, 0, -1 end
    for i = 1, #cells, 2 do
        local tx, ty = cells[i], cells[i + 1]
        if not set[key(tx + ax, ty + ay)] then
            -- Only the first tile of a run draws it, and it walks to the end.
            local prev = set[key(tx + px, ty + py)]
            if not prev or set[key(tx + px + ax, ty + py + ay)] then
                local ex, ey = tx, ty
                while set[key(ex - px, ey - py)]
                      and not set[key(ex - px + ax, ey - py + ay)] do
                    ex, ey = ex - px, ey - py
                end
                emit(tx, ty, ex, ey)
            end
        end
    end
end

-- Where a run's face lies, in world pixels, and which way is out of it.
local function face_line(side, tx, ty, ex, ey)
    if side == "n" then
        return tx * TILE, ty * TILE, (ex + 1) * TILE, ey * TILE, 0, -1
    elseif side == "s" then
        return tx * TILE, (ty + 1) * TILE, (ex + 1) * TILE, (ey + 1) * TILE,
               0, 1
    elseif side == "w" then
        return tx * TILE, ty * TILE, ex * TILE, (ey + 1) * TILE, -1, 0
    end
    return (tx + 1) * TILE, ty * TILE, (ex + 1) * TILE, (ey + 1) * TILE, 1, 0
end

local SIDES = {"n", "s", "w", "e"}

-- A block of wall, drawn as one thing rather than as tiles.
local function wall_mass(bg, glow, set, cells, border)
    local lit = pal.WALL_EDGE
    local hotline = pal.a(pal.hot(lit, 0.28, 1), 0.9)
    local bevel = pal.a(lit, 0.26)
    local edge2 = pal.a(lit, 0.5)
    local inner = pal.a(pal.WALL_LIT, 1)
    local outer = pal.a(lit, 1)

    for i = 1, #cells, 2 do
        bg:rect(cells[i] * TILE, cells[i + 1] * TILE, TILE, TILE, pal.WALL)
    end

    for s = 1, #SIDES do
        local side = SIDES[s]
        runs(set, cells, side, function(tx, ty, ex, ey)
            local px, py, qx, qy, ox, oy = face_line(side, tx, ty, ex, ey)
            local long = (tx ~= ex) or (ty ~= ey)
            -- The light the face throws back into the wall, and out of it. A
            -- body that is one flat slate all the way through has no thickness
            -- in it; lit at the rim and near black at the core, it has.
            --
            -- A one-tile face gets the outward light and the line and nothing
            -- else. Sixteen pixels is too short to read a gradient along, and
            -- a map that is mostly single tiles is the one shape that can
            -- overflow the layer: four full-dress faces and four chamfers
            -- apiece, times everything on screen.
            if long then
                glow:skirt(px, py, qx, qy, -ox * 11, -oy * 11, 0.17, inner)
            end
            glow:skirt(px, py, qx, qy, ox * 6, oy * 6, 0.13, outer)
            glow:seg(px, py, qx, qy, 1.4, hotline)
            if border then
                -- The map's own edge, said twice.
                glow:seg(px - ox * 3, py - oy * 3, qx - ox * 3, qy - oy * 3,
                         0.8, edge2)
            elseif long then
                glow:seg(px - ox * 3.5, py - oy * 3.5,
                         qx - ox * 3.5, qy - oy * 3.5, 0.7, bevel)
            end
        end)
    end

    -- A chamfer at the mass's convex corners. Four pixels of diagonal is the
    -- difference between a stack of tiles and something that was built.
    local corner = pal.a(pal.hot(lit, 0.35, 1), 0.55)
    for i = 1, #cells, 2 do
        local tx, ty = cells[i], cells[i + 1]
        local x, y = tx * TILE, ty * TILE
        local n = not set[key(tx, ty - 1)]
        local s = not set[key(tx, ty + 1)]
        local w = not set[key(tx - 1, ty)]
        local e = not set[key(tx + 1, ty)]
        if n and w then glow:seg(x + 4, y, x, y + 4, 1.1, corner) end
        if n and e then
            glow:seg(x + TILE - 4, y, x + TILE, y + 4, 1.1, corner)
        end
        if s and e then
            glow:seg(x + TILE - 4, y + TILE, x + TILE, y + TILE - 4, 1.1,
                     corner)
        end
        if s and w then
            glow:seg(x + 4, y + TILE, x, y + TILE - 4, 1.1, corner)
        end
    end
end

-- A slope, by the corner it fills. Mirrors SIM_SLOPE_* in sim/include/sim/sim.h.
--
-- Each row is the solid triangle's three corners in tile fractions, then the
-- two ends of its face, then the way out of that face, then the step to the
-- next tile of a run. A run of these is one wall at 45 degrees, and drawing it
-- a tile at a time lays a lit segment against its neighbour at every tile
-- boundary: the same bead every sixteen pixels the orthogonal faces merge runs
-- to avoid, and worse on a diagonal, where the beads read as the staircase the
-- slope exists to get rid of.
-- `fill` is the solid triangle's three corners. `from` and `to` are the ends of
-- its face, ordered so `to` is the end a run continues through and `from` the
-- end it started at. `out` is the way out of the face, which is what the light
-- is thrown along. `step` is the next tile of a run.
local R2 = 0.70710678
local SLOPE = {
    [0] = {fill = {0,0, 1,0, 0,1}, from = {0,1}, to = {1,0},
           out = { R2,  R2}, step = { 1, -1}},   -- NW
    [1] = {fill = {0,0, 1,0, 1,1}, from = {0,0}, to = {1,1},
           out = {-R2,  R2}, step = { 1,  1}},   -- NE
    [2] = {fill = {1,0, 1,1, 0,1}, from = {0,1}, to = {1,0},
           out = {-R2, -R2}, step = { 1, -1}},   -- SE
    [3] = {fill = {0,0, 0,1, 1,1}, from = {0,0}, to = {1,1},
           out = { R2, -R2}, step = { 1,  1}},   -- SW
}

-- The two square sides of the triangle, the ones the face was cut across. A
-- slope is wall the whole way along these two. Along the other two it is one
-- corner touching the line and nothing else.
local LEG = {
    [0] = {"n", "w"},   -- NW
    [1] = {"n", "e"},   -- NE
    [2] = {"s", "e"},   -- SE
    [3] = {"s", "w"},   -- SW
}
local TOWARD = {n = {0, -1}, s = {0, 1}, w = {-1, 0}, e = {1, 0}}
local FACING = {n = "s", s = "n", w = "e", e = "w"}

-- Whether a tile hands its whole `side` edge to the tile beyond it. Square
-- wall does on all four; a slope only on its legs.
local function fills(wall, slopes, tx, ty, side)
    local k = key(tx, ty)
    if not wall[k] then return false end
    local var = slopes[k]
    if not var then return true end
    return LEG[var][1] == side or LEG[var][2] == side
end

-- A leg with nothing behind it: the cut end of a diagonal, or the side it
-- would have handed to a wall that is not there.
local function open_leg(wall, slopes, tx, ty, side)
    local var = slopes[key(tx, ty)]
    if not var or (LEG[var][1] ~= side and LEG[var][2] ~= side) then
        return false
    end
    local d = TOWARD[side]
    return not fills(wall, slopes, tx + d[1], ty + d[2], FACING[side])
end

-- Maximal straight runs of open leg, the way `runs` merges the square faces
-- and for the same reason: two ends side by side are one end.
local function cap_runs(wall, slopes, cells, side, emit)
    local px, py = -1, 0
    if side == "w" or side == "e" then px, py = 0, -1 end
    for i = 1, #cells, 3 do
        local tx, ty = cells[i], cells[i + 1]
        if open_leg(wall, slopes, tx, ty, side)
           and not open_leg(wall, slopes, tx + px, ty + py, side) then
            local ex, ey = tx, ty
            while open_leg(wall, slopes, ex - px, ey - py, side) do
                ex, ey = ex - px, ey - py
            end
            emit(tx, ty, ex, ey)
        end
    end
end

-- The diagonal half of a wall, drawn as the face it is.
local function slope_mass(bg, glow, wall, set, cells)
    local lit = pal.WALL_EDGE
    local hotline = pal.a(pal.hot(lit, 0.28, 1), 0.9)
    local inner = pal.a(pal.WALL_LIT, 1)
    local outer = pal.a(lit, 1)

    for i = 1, #cells, 3 do
        local tx, ty, var = cells[i], cells[i + 1], cells[i + 2]
        local f = SLOPE[var].fill
        local x, y = tx * TILE, ty * TILE
        bg:tri(x + f[1] * TILE, y + f[2] * TILE,
               x + f[3] * TILE, y + f[4] * TILE,
               x + f[5] * TILE, y + f[6] * TILE, pal.WALL)
    end

    -- One lit segment for a whole run, drawn by the tile that starts it.
    for i = 1, #cells, 3 do
        local tx, ty, var = cells[i], cells[i + 1], cells[i + 2]
        local s = SLOPE[var]
        local sx, sy = s.step[1], s.step[2]
        if set[key(tx - sx, ty - sy)] ~= var then
            local ex, ey = tx, ty
            while set[key(ex + sx, ey + sy)] == var do ex, ey = ex + sx, ey + sy end
            local px = (tx + s.from[1]) * TILE
            local py = (ty + s.from[2]) * TILE
            local qx = (ex + s.to[1]) * TILE
            local qy = (ey + s.to[2]) * TILE
            local ox, oy = s.out[1], s.out[2]
            glow:skirt(px, py, qx, qy, -ox * 11, -oy * 11, 0.17, inner)
            glow:skirt(px, py, qx, qy, ox * 6, oy * 6, 0.13, outer)
            glow:seg(px, py, qx, qy, 1.4, hotline)
        end
    end

    -- The ends. A diagonal that runs into a wall hands its leg to that wall
    -- and there is nothing to draw there; one that stops in open space is cut
    -- square, and unlit that end reads as a face somebody forgot.
    --
    -- A cap is a tile or two long, so it gets what a one-tile square face
    -- gets: the light thrown out of it and the line. No gradient back into
    -- the body, because the body behind a leg is half a tile of triangle and
    -- eleven pixels of it would cross the face.
    for s = 1, #SIDES do
        local side = SIDES[s]
        cap_runs(wall, set, cells, side, function(tx, ty, ex, ey)
            local px, py, qx, qy, ox, oy = face_line(side, tx, ty, ex, ey)
            glow:skirt(px, py, qx, qy, ox * 6, oy * 6, 0.13, outer)
            glow:seg(px, py, qx, qy, 1.4, hotline)
        end)
    end
end

-- A safe zone: a marked floor rather than a colored patch. A wash, a hatch
-- that stays inside its own tiles, and a dashed rim along the outside faces.
local function safe_zone(bg, glow, set, cells)
    local wash = pal.a(pal.FRIEND, 0.05)
    local hatch = pal.a(pal.FRIEND, 0.09)
    local dash = pal.a(pal.FRIEND, 0.55)
    local spill = pal.a(pal.FRIEND, 1)
    for i = 1, #cells, 2 do
        local tx, ty = cells[i], cells[i + 1]
        local x, y = tx * TILE, ty * TILE
        bg:rect(x, y, TILE, TILE, wash)
        -- Corner to corner, so a diagonal never leaves the tile it belongs
        -- to. A hatch that runs past its own edge is a hatch with no edge.
        glow:seg(x, y + TILE, x + TILE, y, 0.7, hatch)
        glow:seg(x, y + TILE / 2, x + TILE / 2, y, 0.7, hatch)
        glow:seg(x + TILE / 2, y + TILE, x + TILE, y + TILE / 2, 0.7, hatch)
    end
    for s = 1, #SIDES do
        local side = SIDES[s]
        runs(set, cells, side, function(tx, ty, ex, ey)
            local px, py, qx, qy, ox, oy = face_line(side, tx, ty, ex, ey)
            local len = math.sqrt((qx - px) * (qx - px) + (qy - py) * (qy - py))
            local ux, uy = (qx - px) / len, (qy - py) / len
            local k = 0
            while k < len - 0.5 do
                local e = math.min(k + 5.5, len)
                glow:seg(px + ux * k, py + uy * k, px + ux * e, py + uy * e,
                         1.2, dash)
                k = k + 9
            end
            glow:skirt(px, py, qx, qy, ox * 5, oy * 5, 0.09, spill)
        end)
    end
end

-- Rock. Faceted and gray on purpose: a hull is smooth, lit and colored, and
-- at a glance across a room that is the whole difference between the two.
-- An asteroid's shape, in its own space and built once.
--
-- Rocks turn, so their geometry cannot live in the static mesh with the walls
-- and cannot be rebuilt from scratch sixty times a second either. This is the
-- hull treatment applied to terrain: the random shape is drawn once out of the
-- seed and kept, and a frame does nothing but rotate it.
--
-- Cached on the seed, so two rocks that would have looked alike still do, and
-- a map with a hundred of them holds a hundred small tables.
local rock_shapes = {}

local ROCK_FACETS = {
    pal.a(pal.ROCK_DARK, 1),
    pal.a(pal.ROCK, 1),
    pal.a(pal.ROCK_MID, 1),
    pal.a(pal.ROCK_LIT, 1),
}
local ROCK_RIDGE = pal.a(pal.ROCK_EDGE, 0.20)
local ROCK_CRACK = pal.a(pal.ROCK_DARK, 0.95)
local ROCK_CRATER = pal.a(pal.ROCK_EDGE, 0.17)
local ROCK_ORE = pal.a(pal.ROCK_ORE, 0.52)

local function rock_shape(seed, sides, r)
    local k = seed .. ":" .. sides .. ":" .. r
    local s = rock_shapes[k]
    if s then return s end
    local rs = seed
    local function rnd()
        rs = (rs * 48271) % 2147483647
        return rs / 2147483647
    end
    local pts, nrm = {}, {}
    for i = 0, sides - 1 do
        local a = i / sides * TAU + (rnd() - 0.5) * 0.42
        local rr = r * (0.64 + rnd() * 0.46)
        pts[i * 2 + 1] = math.cos(a) * rr
        pts[i * 2 + 2] = math.sin(a) * rr
        nrm[i * 2 + 1] = math.cos(a)
        nrm[i * 2 + 2] = math.sin(a)
    end
    -- How it turns, out of the same seed: a rate, a direction, and a phase, so
    -- a field of rocks is a field of rocks rather than a rank of them turning
    -- in step. Slowest is a full revolution in about a minute and fastest in
    -- about twenty seconds, which still reads as adrift rather than as
    -- machinery. The other three numbers are the tumble: how deeply the
    -- silhouette foreshortens, how fast that cycle runs, and how fast the
    -- axis it happens about wanders round the screen plane.
    local q = (seed % 97) / 97
    local craters = {}
    local crater_count = sides >= 10 and 2 or 1
    for _ = 1, crater_count do
        local a = rnd() * TAU
        local d = r * (0.18 + rnd() * 0.24)
        craters[#craters + 1] = math.cos(a) * d
        craters[#craters + 1] = math.sin(a) * d
        craters[#craters + 1] = r * (0.10 + rnd() * 0.07)
    end
    local ridges = {}
    local ridge_count = sides >= 10 and 3 or 1
    for _ = 1, ridge_count do
        ridges[#ridges + 1] = math.floor(rnd() * sides)
    end
    s = {pts = pts, nrm = nrm, sides = sides, seed = seed,
         rate = ((seed % 2 == 0) and 1 or -1) * (0.10 + q * 0.22),
         depth = 0.14 + q * 0.16,
         trate = 0.23 + q * 0.30,
         drift = ((seed % 3 == 0) and 1 or -1) * (0.05 + q * 0.07),
         phase = q * TAU,
         craters = craters, ridges = ridges,
         tmp = {}, ntmp = {}}
    rock_shapes[k] = s
    return s
end

-- One asteroid, turned to where it is this frame.
local function draw_rock(fill, glow, cx, cy, s, now)
    local ang = now * s.rate
    -- A rock is not a wheel. The silhouette foreshortens along one direction,
    -- which is what rotation about an axis lying in the screen plane does to
    -- an irregular body -- and that axis wanders slowly round the plane
    -- instead of riding the outline, so the squeeze crosses the shape rather
    -- than breathing with it. Spin, foreshorten and precession run on three
    -- unrelated clocks, which is the whole tell of a tumble against a turn.
    --
    -- One 2x2 matrix carries all of it: rotate by the spin, foreshorten
    -- along the axis, and each vertex costs what plain rotation cost.
    local axis = now * s.drift + s.phase * 2
    local squash = 1 - s.depth * (0.5 + 0.5 * math.cos(now * s.trate + s.phase))
    local cf, sf = math.cos(axis), math.sin(axis)
    local cb, sb = math.cos(ang - axis), math.sin(ang - axis)
    local m11 = cf * squash * cb - sf * sb
    local m12 = -(cf * squash * sb + sf * cb)
    local m21 = sf * squash * cb + cf * sb
    local m22 = cf * cb - sf * squash * sb
    -- Normals only turn. Foreshortening them too would swing the lit side
    -- with the tumble, and the light does not tumble.
    local ca, sa = math.cos(ang), math.sin(ang)
    local src, pts, nrm = s.pts, s.tmp, s.ntmp
    local sn = s.nrm
    for i = 1, #src, 2 do
        local px, py = src[i], src[i + 1]
        pts[i] = cx + px * m11 + py * m12
        pts[i + 1] = cy + px * m21 + py * m22
        local nx, ny = sn[i], sn[i + 1]
        nrm[i] = nx * ca - ny * sa
        nrm[i + 1] = nx * sa + ny * ca
    end
    -- Fanned from the center, not from a vertex: the outline is star-shaped
    -- about its own center and nothing else, and a vertex fan on a shape with
    -- one notch in it paints outside the rock.
    local sides = s.sides
    for i = 0, sides - 1 do
        local j = (i + 1) % sides
        fill:tri(cx, cy, pts[i * 2 + 1], pts[i * 2 + 2],
                 pts[j * 2 + 1], pts[j * 2 + 2],
                 ROCK_FACETS[(s.seed + i * 5) % #ROCK_FACETS + 1])
    end

    -- Facet ridges do not all meet at the center. Each joins two interior
    -- points on separated faces, which reads as fractured volume rather than
    -- spokes painted on a wheel.
    for i = 1, #s.ridges do
        local a = s.ridges[i]
        local b = (a + 2 + i) % sides
        local ax, ay = pts[a * 2 + 1], pts[a * 2 + 2]
        local bx, by = pts[b * 2 + 1], pts[b * 2 + 2]
        local af = 0.46 + (i % 2) * 0.08
        local bf = 0.58 + (i % 3) * 0.05
        glow:seg(cx + (ax - cx) * af, cy + (ay - cy) * af,
                 cx + (bx - cx) * bf, cy + (by - cy) * bf,
                 0.7, ROCK_RIDGE)
    end

    -- Pits and one mineral seam survive the tumble because their centers are
    -- passed through the same matrix as the silhouette. They stay subordinate
    -- to the collision outline; a rock is still one dark mass at speed.
    local craters = s.craters
    for i = 1, #craters, 3 do
        local px, py = craters[i], craters[i + 1]
        local x = cx + px * m11 + py * m12
        local y = cy + px * m21 + py * m22
        local rr = craters[i + 2] * (0.75 + squash * 0.25)
        fill:disc(x, y, rr, 8, ROCK_FACETS[1])
        glow:ring(x, y, rr, 0.6, 8, ROCK_CRATER)
    end
    local vi = s.seed % sides
    local vj = (vi + math.floor(sides / 3)) % sides
    local vx, vy = pts[vi * 2 + 1], pts[vi * 2 + 2]
    local wx, wy = pts[vj * 2 + 1], pts[vj * 2 + 2]
    local mx, my = cx + (vx - cx) * 0.30, cy + (vy - cy) * 0.30
    local ex, ey = cx + (wx - cx) * 0.66, cy + (wy - cy) * 0.66
    fill:seg(mx, my, ex, ey, 1.1, ROCK_CRACK)
    if sides >= 10 then
        glow:seg(mx, my, ex, ey, 0.55, ROCK_ORE)
        glow:seg(mx + (vx - cx) * 0.12, my + (vy - cy) * 0.12,
                 mx, my, 0.5, ROCK_ORE)
    end
    glow:glow_band(pts, nrm, 5, 0.12, pal.a(pal.ROCK_EDGE, 1))
    glow:outline(pts, 1.2, pal.a(pal.hot(pal.ROCK_EDGE, 0.15, 1), 0.8), true)
end

-- Six tiles square, and the one piece of terrain with room to spend: an
-- armored service platform built around a cold reactor and four recessed
-- docking throats.
--
-- The fill reaches the whole six-tile stamp. The old picture was a hexagon on
-- four arms inside that square, which left transparent corners a ship still
-- bounced off. Decoration may suggest depth, but the bright outside edge is
-- the collision shape and tells the truth everywhere.
local function station(bg, glow, tx, ty)
    local x, y = tx * TILE, ty * TILE
    local size = TILE * 6
    local cx, cy = x + size / 2, y + size / 2
    local body = pal.a(pal.STATION_BODY, 1)
    local plate = pal.a(pal.STATION_PLATE, 1)
    local recess = pal.a(pal.STATION_RECESS, 0.96)
    local edge = pal.a(pal.WALL_EDGE, 0.88)
    local edge_hot = pal.a(pal.hot(pal.WALL_EDGE, 0.45, 1), 0.96)
    local structure = pal.a(pal.PANEL_INK, 0.25)
    local cold = pal.a(pal.STATION_COLD, 0.58)
    local cold_hot = pal.a(pal.hot(pal.STATION_COLD, 0.35, 1), 0.86)
    local warm = pal.a(pal.STATION_WARM, 0.68)

    bg:rect(x, y, size, size, body)

    -- Four armor quarters, each with an angled inside corner. Their seams aim
    -- at the reactor instead of following the tile grid.
    local q = 31
    local c = 18
    local plates = {
        {x + 4,y + 4, x + q,y + 4, x + q,y + c, x + c,y + q, x + 4,y + q},
        {x + size - 4,y + 4, x + size - q,y + 4, x + size - q,y + c,
         x + size - c,y + q, x + size - 4,y + q},
        {x + size - 4,y + size - 4, x + size - q,y + size - 4,
         x + size - q,y + size - c, x + size - c,y + size - q,
         x + size - 4,y + size - q},
        {x + 4,y + size - 4, x + q,y + size - 4,
         x + q,y + size - c, x + c,y + size - q,
         x + 4,y + size - q},
    }
    for i = 1, #plates do
        bg:fan(plates[i], plate)
        glow:outline(plates[i], 0.7, structure, true)
    end

    -- Docking throats are recesses painted into the solid mass. A ship cannot
    -- enter them, so the outside edge stays unbroken and bright; the paired
    -- rails lead inward only as visual machinery.
    bg:rect(cx - 10, y, 20, 29, recess)
    bg:rect(cx - 10, y + size - 29, 20, 29, recess)
    bg:rect(x, cy - 10, 29, 20, recess)
    bg:rect(x + size - 29, cy - 10, 29, 20, recess)
    for _, off in ipairs({-6, 6}) do
        glow:seg(cx + off, y + 3, cx + off, cy - 19, 0.8, cold)
        glow:seg(cx + off, y + size - 3, cx + off, cy + 19, 0.8, cold)
        glow:seg(x + 3, cy + off, cx - 19, cy + off, 0.8, cold)
        glow:seg(x + size - 3, cy + off, cx + 19, cy + off, 0.8, cold)
    end

    -- Warning teeth live on the thresholds. Four short diagonals read as
    -- painted hazard marks without borrowing the enemy's bright silhouette.
    for k = -2, 1 do
        local d = k * 4
        glow:seg(cx + d, y + 3, cx + d + 3, y + 7, 1.0, warm)
        glow:seg(cx + d, y + size - 3, cx + d + 3, y + size - 7, 1.0, warm)
        glow:seg(x + 3, cy + d, x + 7, cy + d + 3, 1.0, warm)
        glow:seg(x + size - 3, cy + d, x + size - 7, cy + d + 3, 1.0, warm)
    end

    local outer = {x,y, x + size,y, x + size,y + size, x,y + size}
    local outer_n = {0,-1, 1,0, 0,1, -1,0}
    glow:glow_band(outer, outer_n, 9, 0.11, pal.a(pal.WALL_LIT, 1))
    glow:glow_band(outer, outer_n, 3, 0.22, pal.a(pal.WALL_LIT, 1))
    glow:outline(outer, 1.6, edge_hot, true)
    glow:outline({x + 4,y + 4, x + size - 4,y + 4,
                  x + size - 4,y + size - 4, x + 4,y + size - 4},
                 0.8, edge, true)

    -- The octagonal machine at the middle gives the platform one landmark.
    -- Trusses join it to the armor quarters, while the cold core stays below
    -- the brightness of a ship or a live round.
    local core, core_n, inner = {}, {}, {}
    for i = 0, 7 do
        local a = i / 8 * TAU + TAU / 16
        local ca, sa = math.cos(a), math.sin(a)
        core[i * 2 + 1], core[i * 2 + 2] = cx + ca * 24, cy + sa * 24
        core_n[i * 2 + 1], core_n[i * 2 + 2] = ca, sa
        inner[i * 2 + 1], inner[i * 2 + 2] = cx + ca * 18, cy + sa * 18
    end
    bg:fan(core, plate)
    glow:glow_band(core, core_n, 5, 0.10, pal.a(pal.STATION_COLD, 1))
    glow:outline(core, 1.2, edge_hot, true)
    glow:outline(inner, 0.8, structure, true)
    for i = 0, 7 do
        glow:seg(core[i * 2 + 1], core[i * 2 + 2],
                 inner[i * 2 + 1], inner[i * 2 + 2], 0.7, structure)
    end
    for _, p in ipairs({{x + 17,y + 17}, {x + size - 17,y + 17},
                        {x + size - 17,y + size - 17},
                        {x + 17,y + size - 17}}) do
        glow:seg(p[1], p[2],
                 cx + (p[1] - cx) * 0.44, cy + (p[2] - cy) * 0.44,
                 0.8, structure)
        glow:disc(p[1], p[2], 1.2, 6, cold)
    end
    bg:disc(cx, cy, 13, 16, recess)
    glow:ring(cx, cy, 12, 1.2, 20, cold)
    glow:ring(cx, cy, 7, 1.0, 16, cold_hot)
    glow:halo(cx, cy, 16, 12, pal.a(pal.STATION_COLD, 0.15))
    glow:disc(cx, cy, 3.0, 10, cold_hot)
end

-- Floor markings, beneath the ships and in instrument gray, so decoration is
-- never mistaken for something a ship can hit.
local function under_mark(glow, tx, ty, kind)
    local x, y = tx * TILE, ty * TILE
    local a = pal.a(pal.PANEL_INK, 0.24)
    local b = pal.a(pal.PANEL_INK, 0.3)
    kind = kind % 6
    if kind == 0 then
        glow:outline({x + 2, y + 2, x + 14, y + 2, x + 14, y + 14,
                      x + 2, y + 14}, 0.7, a, true)
        glow:disc(x + 4.5, y + 4.5, 0.8, 4, b)
        glow:disc(x + 11.5, y + 4.5, 0.8, 4, b)
        glow:disc(x + 4.5, y + 11.5, 0.8, 4, b)
        glow:disc(x + 11.5, y + 11.5, 0.8, 4, b)
    elseif kind == 1 then
        local chev = pal.a(pal.PANEL_INK, 0.19)
        for k = -1, 2 do
            glow:seg(x + k * 6, y + 14, x + k * 6 + 7, y + 2, 1.6, chev)
        end
    elseif kind == 2 then
        for k = 0, 3 do
            glow:seg(x + 3, y + 3 + k * 3.2, x + 13, y + 3 + k * 3.2, 0.9, a)
        end
    elseif kind == 3 then
        glow:ring(x + 8, y + 8, 5.4, 0.8, 12, a)
        glow:ring(x + 8, y + 8, 2.2, 0.8, 8, a)
    elseif kind == 4 then
        glow:seg(x, y + 5, x + TILE, y + 5, 0.8, a)
        glow:seg(x, y + 11, x + TILE, y + 11, 0.8,
                 pal.a(pal.PANEL_INK, 0.17))
        local rung = pal.a(pal.PANEL_INK, 0.12)
        for k = 1, 3 do
            glow:seg(x + k * 4, y + 4, x + k * 4, y + 12, 0.6, rung)
        end
    else
        glow:outline({x + 4, y + 3, x + 12, y + 3, x + 13, y + 8,
                      x + 12, y + 13, x + 4, y + 13, x + 3, y + 8},
                     0.8, a, true)
        glow:seg(x + 6, y + 8, x + 10, y + 8, 0.7, b)
    end
end

-- A stand to plant a flag in, and a place a side arrives at. Both are marks on
-- the ground rather than obstacles, and both are read while flying past.
local function turf_stand(glow, tx, ty)
    local x, y = tx * TILE + TILE / 2, ty * TILE + TILE / 2
    local pts, nrm = {}, {}
    for i = 0, 7 do
        local a = i / 8 * TAU + TAU / 16
        pts[i * 2 + 1] = x + math.cos(a) * 5.6
        pts[i * 2 + 2] = y + math.sin(a) * 5.6
        nrm[i * 2 + 1] = math.cos(a)
        nrm[i * 2 + 2] = math.sin(a)
    end
    glow:glow_band(pts, nrm, 4, 0.14, pal.a(pal.INK, 1))
    glow:outline(pts, 1.2, pal.a(pal.INK, 0.55), true)
    glow:seg(x, y + 2.2, x, y - 2.2, 1.6, pal.a(pal.INK, 0.85))
    glow:disc(x, y - 2.6, 1.3, 6, pal.a(pal.WHITE, 0.85))
end

local function spawn_mark(glow, tx, ty, team, my_team)
    local x, y = tx * TILE + TILE / 2, ty * TILE + TILE / 2
    local col = (team == my_team) and pal.FRIEND or pal.ENEMY
    -- Two rings and nothing else. It carried an arrow out of a cradle before,
    -- which meant nothing in a game with no up: a ship arrives pointing
    -- wherever the mode says. Dimmer than it was, too. This is a mark on the
    -- ground, not something anybody flies into.
    glow:ring(x, y, 7, 1.0, 16, pal.a(col, 0.22))
    glow:ring(x, y, 4.2, 1.0, 12, pal.a(col, 0.38))
end

-- A mouth to put something into: three sides and a net, open to the field.
local function goal_mouth(glow, tx, ty, team, my_team)
    local col = (team == my_team) and pal.FRIEND or pal.ENEMY
    local x, y = tx * TILE, ty * TILE
    local net = pal.a(col, 0.26)
    for k = 1, 3 do
        glow:seg(x + 2, y + 2 + k * 3, x + TILE - 2, y + 2 + k * 3, 0.6, net)
        glow:seg(x + 2 + k * 3, y + 2, x + 2 + k * 3, y + TILE - 2, 0.6, net)
    end
    local frame = pal.a(pal.hot(col, 0.4, 1), 0.9)
    local halo = pal.a(col, 1)
    local sides = {{x + 2, y + TILE - 2, x + 2, y + 2},
                   {x + 2, y + 2, x + TILE - 2, y + 2},
                   {x + TILE - 2, y + 2, x + TILE - 2, y + TILE - 2}}
    for i = 1, 3 do
        local s = sides[i]
        glow:seg_glow(s[1], s[2], s[3], s[4], 4, 0.10, halo)
        glow:seg(s[1], s[2], s[3], s[4], 1.4, frame, true)
    end
end

-- Everything static, in one pass over the window.
local function build_terrain(bg, glow, x0, y0, x1, y1)
    local wall_set, wall_cells = {}, {}
    local bord_cells = {}
    -- Slopes are in the wall set and not in its cells: a wall beside one must
    -- not light the edge they share, and the slope draws its own face rather
    -- than four square ones. The set holds the variant, since a run is a run
    -- of one kind and the light follows the whole of it.
    local slope_set, slope_cells = {}, {}
    local safe_set, safe_cells = {}, {}
    local rocks, stations, unders = {}, {}, {}
    local turfs, spawns, goals = {}, {}, {}
    local my_team = M.my_team or 0
    -- Asked once per window rather than once per tile. A zone can keep its
    -- home ends quiet, which is not hypothetical: every spawn on the map is
    -- marked, the enemy's included and in the enemy's color, so anybody flying
    -- can read where the other side comes back.
    local show_spawns = sim.show_spawns()

    for ty = y0, y1 do
        for tx = x0, x1 do
            local cls, var = sim.tile(tx, ty)
            if cls == sim.T_SOLID then
                if var == V_BORDER then
                    wall_set[key(tx, ty)] = true
                    bord_cells[#bord_cells + 1] = tx
                    bord_cells[#bord_cells + 1] = ty
                elseif var == V_ROCK_A or var == V_ROCK_B then
                    rocks[#rocks + 1] = tx
                    rocks[#rocks + 1] = ty
                    rocks[#rocks + 1] = var
                elseif var == V_ROCK_BIG then
                    rocks[#rocks + 1] = tx
                    rocks[#rocks + 1] = ty
                    rocks[#rocks + 1] = var
                elseif var == V_STATION then
                    stations[#stations + 1] = tx
                    stations[#stations + 1] = ty
                elseif var ~= V_ROCK_BODY and var ~= V_STATION_BODY then
                    wall_set[key(tx, ty)] = true
                    wall_cells[#wall_cells + 1] = tx
                    wall_cells[#wall_cells + 1] = ty
                end
            elseif cls == sim.T_SLOPE then
                wall_set[key(tx, ty)] = true
                slope_set[key(tx, ty)] = var
                slope_cells[#slope_cells + 1] = tx
                slope_cells[#slope_cells + 1] = ty
                slope_cells[#slope_cells + 1] = var
            elseif cls == sim.T_SAFE then
                safe_set[key(tx, ty)] = true
                safe_cells[#safe_cells + 1] = tx
                safe_cells[#safe_cells + 1] = ty
            elseif cls == sim.T_UNDER then
                unders[#unders + 1] = tx
                unders[#unders + 1] = ty
                unders[#unders + 1] = var
            elseif cls == sim.T_TURF then
                turfs[#turfs + 1] = tx
                turfs[#turfs + 1] = ty
            elseif cls == sim.T_SPAWN and show_spawns then
                spawns[#spawns + 1] = tx
                spawns[#spawns + 1] = ty
                spawns[#spawns + 1] = var
            elseif cls == sim.T_GOAL then
                goals[#goals + 1] = tx
                goals[#goals + 1] = ty
                goals[#goals + 1] = var
            end
        end
    end

    -- Border tiles are in the wall set, so the two masses agree about which
    -- faces are exposed and neither draws an edge into the other.
    wall_mass(bg, glow, wall_set, wall_cells, false)
    wall_mass(bg, glow, wall_set, bord_cells, true)
    slope_mass(bg, glow, wall_set, slope_set, slope_cells)
    safe_zone(bg, glow, safe_set, safe_cells)

    for i = 1, #unders, 3 do
        under_mark(glow, unders[i], unders[i + 1], unders[i + 2])
    end
    -- Rocks are not built into this mesh. They turn, so they are drawn per
    -- frame like the doors and the wells; what happens here is that the
    -- window's worth of them is found once and their shapes baked, instead of
    -- the whole map being searched every frame for a dozen asteroids.
    local found = {}
    for i = 1, #rocks, 3 do
        local tx, ty, var = rocks[i], rocks[i + 1], rocks[i + 2]
        local e
        if var == V_ROCK_BIG then
            e = {x = (tx + 1) * TILE, y = (ty + 1) * TILE,
                 s = rock_shape(60413 + tx * 7 + ty * 13, 11, 14.5)}
        else
            e = {x = (tx + 0.5) * TILE, y = (ty + 0.5) * TILE,
                 s = rock_shape((var == V_ROCK_B and 977 or 12345)
                                + tx * 31 + ty * 17,
                                var == V_ROCK_B and 7 or 8, 7)}
        end
        found[#found + 1] = e
    end
    M.rocks = found
    for i = 1, #stations, 2 do
        station(bg, glow, stations[i], stations[i + 1])
    end
    for i = 1, #turfs, 2 do
        turf_stand(glow, turfs[i], turfs[i + 1])
    end
    for i = 1, #spawns, 3 do
        spawn_mark(glow, spawns[i], spawns[i + 1], spawns[i + 2], my_team)
    end
    for i = 1, #goals, 3 do
        goal_mouth(glow, goals[i], goals[i + 1], goals[i + 2], my_team)
    end
end

-- How much further than the mesh window the radar has to be sampled.
--
-- The radar reaches `RADAR_TILES` from the camera, and the mesh window is
-- rebuilt only once the camera has walked `STATIC_STEP` tiles from where it
-- was built. So in the direction of travel the radar can want terrain up to
-- `RADAR_TILES + STATIC_STEP` from the build center, and a window sized for
-- drawing alone is short of that -- which is not a subtle artefact: the radar
-- carries no terrain out there at all, and then a whole slab of it appears
-- the moment the window is rebuilt. It reads as the map blinking in at the
-- edges, because it is.
--
-- Sampling wider is nearly free. This loop makes no geometry -- it collects
-- points at a two-tile stride for the radar to draw as dots -- so the wide
-- box costs tile reads and a longer list, while the mesh, which is the
-- expensive half, keeps the window it needs for the screen.
local RADAR_TILES = 60          -- must match ui.lua's SPAN
local RADAR_SLACK = 24          -- > arena.script's STATIC_STEP
local RADAR_REACH = RADAR_TILES + RADAR_SLACK

function M.build_static(bg, glow, x0, y0, x1, y1)
    bg:reset()
    glow:reset()
    -- The tile array can hold 1024 square, but a room usually occupies only a
    -- small declared rectangle inside it. Outside that rectangle `sim.tile`
    -- answers solid so collision closes the world. Drawing that sentinel as
    -- terrain turns every off-map part of the radar into one solid slab.
    local map_w, map_h = sim.map_size()
    local last_x, last_y = map_w - 1, map_h - 1
    local cx = (x0 + x1) / 2
    local cy = (y0 + y1) / 2
    if x0 < 0 then x0 = 0 end
    if y0 < 0 then y0 = 0 end
    if x1 > last_x then x1 = last_x end
    if y1 > last_y then y1 = last_y end

    -- The doors and wormholes, found once here rather than searched for on
    -- every frame that draws them. Over the radar's box rather than the
    -- mesh's: a door is drawn in the world *and* on the radar, and the radar
    -- sees further.
    local rx0 = math.max(0, math.floor(cx - RADAR_REACH))
    local ry0 = math.max(0, math.floor(cy - RADAR_REACH))
    local rx1 = math.min(last_x, math.floor(cx + RADAR_REACH))
    local ry1 = math.min(last_y, math.floor(cy + RADAR_REACH))
    index_moving(rx0, ry0, rx1, ry1)

    -- Every second tile, not every fourth. The arena's outer walls are two
    -- tiles thick, so a four-tile stride aliased them away completely and the
    -- map read as a scatter of unrelated dots.
    --
    -- Safe zones and doors get their own lists: they are the two things worth
    -- steering by, and they were not on the radar at all.
    -- Anchored to the map's own even grid, never to the window. The stride
    -- is two tiles, so the phase of the sampled grid decides which tiles are
    -- looked at, and taking it from the window center meant every rebuild
    -- could flip it: measured on Chaos, 664 of 719 blips vanished when the
    -- window moved one tile, which on screen was the whole dial re-rolling
    -- every 256 pixels of flight. On the map's grid the same tiles are
    -- sampled from every center, so the picture slides and never re-rolls.
    --
    -- And the whole two-by-two block per sample, not its corner tile. With a
    -- fixed phase, a corner read would leave a one-tile wall on the odd
    -- parity permanently invisible rather than blinking, which is worse.
    -- Doors outrank safe outranks wall inside a block, because the door is
    -- the part worth steering by.
    local rt, rs, rd = {}, {}, {}
    if rx0 % 2 == 1 then rx0 = rx0 + 1 end
    if ry0 % 2 == 1 then ry0 = ry0 + 1 end
    for ty = ry0, ry1, 2 do
        for tx = rx0, rx1, 2 do
            local best = 0
            for dy = 0, 1 do
                for dx = 0, 1 do
                    local sx, sy = tx + dx, ty + dy
                    if sx <= last_x and sy <= last_y then
                        local cls = sim.tile(sx, sy)
                        if cls == sim.T_DOOR then
                            best = 3
                        elseif cls == sim.T_SAFE and best < 2 then
                            best = 2
                        elseif (cls == sim.T_SOLID or cls == sim.T_SLOPE)
                               and best < 1 then
                            -- A slope is a dot like any other wall. At two
                            -- tiles to a sample there is nowhere to say which
                            -- half of one is solid, and a pilot steering by
                            -- the radar wants the wall, not its shape.
                            best = 1
                        end
                    end
                end
            end
            local out = (best == 1 and rt) or (best == 2 and rs)
                or (best == 3 and rd)
            if out then
                out[#out + 1] = tx * TILE
                out[#out + 1] = ty * TILE
            end
        end
    end
    M.radar_tiles = rt
    M.radar_safe = rs
    M.radar_doors = rd

    build_terrain(bg, glow, x0, y0, x1, y1)

    bg:flush()
    glow:flush()
end

-- --- the overview ----------------------------------------------------------
--
-- The whole map as a few thousand rectangles, so a view of all thousand tiles
-- costs a list walk per frame rather than a million tile reads.
--
-- Four tiles to a cell. The map view is around four hundred pixels on a
-- desktop, which is two and a half tiles to the pixel, so a finer grain buys
-- detail nothing can draw. Coarser and the corridors start closing up.
local OVERVIEW_CELL = 4

-- Rectangles, five numbers each: cell x, cell y, width, height, tile class.
-- Flat rather than a table per rectangle, because two thousand small tables
-- is two thousand things for the collector to walk every time it runs.
M.overview = {grid = 0, n = 0, rect = {}}

-- Greedy rectangles rather than one quad per cell, which is the difference
-- between two thousand of them and sixty thousand. A row of identical cells
-- becomes one run, and the run swallows the rows under it while they match.
--
-- Measured on the three shipped maps by client/tests/overview_test.lua: 928 to
-- 2195 rectangles, against 3287 to 4104 for rows alone and the 6144 vertices
-- the interface layer used to hold.
function M.build_overview()
    local s, gw, gh = sim.map_coarse(OVERVIEW_CELL)
    local byte = string.byte
    local taken = {}
    local r, n = {}, 0
    for y = 0, gh - 1 do
        local x = 0
        while x < gw do
            -- One-based, because a Lua string is.
            local i = y * gw + x + 1
            local cls = byte(s, i)
            if cls == 0 or taken[i] then
                x = x + 1
            else
                local w = 1
                while x + w < gw and byte(s, i + w) == cls and not taken[i + w] do
                    w = w + 1
                end
                local h = 1
                while y + h < gh do
                    local j = i + h * gw
                    local same = true
                    for k = 0, w - 1 do
                        if byte(s, j + k) ~= cls or taken[j + k] then
                            same = false
                            break
                        end
                    end
                    if not same then break end
                    h = h + 1
                end
                for yy = 0, h - 1 do
                    local j = i + yy * gw
                    for xx = 0, w - 1 do taken[j + xx] = true end
                end
                r[n + 1], r[n + 2], r[n + 3] = x, y, w
                r[n + 4], r[n + 5] = h, cls
                n = n + 5
                x = x + w
            end
        end
    end
    -- `grid` is the square the view scales by, so a map that is wider than it
    -- is tall keeps its shape inside the dial rather than being stretched to
    -- fill it.
    M.overview = {grid = math.max(gw, gh), gw = gw, gh = gh, n = n, rect = r}
end

function M.forget_overview()
    M.overview = {grid = 0, gw = 0, gh = 0, n = 0, rect = {}}
end

-- Made once, not per frame: these are constants wearing a function's clothes,
-- and allocating them in a draw loop is what a collector notices first.
-- A door reads in its own color now rather than in the wall's, and shut and
-- open are different hues rather than two brightnesses of one. See pal.DOOR:
-- the band is nothing else's, so this costs no other reading.
local DOOR_LIT = pal.DOOR
local DOOR_SEAM = pal.a(pal.hot(pal.DOOR, 0.55, 1), 0.98)
local DOOR_WASH = pal.a(DOOR_LIT, 0.07)
local DOOR_FIL = pal.a(DOOR_LIT, 0.5)
local DOOR_PULSE = pal.a(pal.hot(pal.DOOR, 0.45, 1), 0.85)
local DOOR_NODE = pal.a(pal.hot(pal.DOOR, 0.6, 1), 0.95)
local DOOR_NODE_HALO = pal.a(DOOR_LIT, 0.35)
local DOOR_POST_SHUT = pal.a(DOOR_LIT, 0.95)
local DOOR_POST_OPEN = pal.a(pal.DOOR_OPEN, 0.7)
local DOOR_TICK_SHUT = pal.a(DOOR_LIT, 0.9)
local DOOR_TICK_OPEN = pal.a(pal.DOOR_OPEN, 0.6)
local DOOR_MARK = pal.a(pal.DOOR_OPEN, 0.8)
local DOOR_SILL = pal.a(pal.DOOR_OPEN, 0.28)
-- The rings are a function of the clock now, so their colors are made per
-- frame rather than held here. The arms still are: their fade is by depth
-- rather than by time.
local HOLE_ARM = {}
for k = 1, 5 do HOLE_ARM[k] = pal.a(pal.HOLE, 0.34 - (k - 1) * 0.05) end

-- One door, however many tiles it spans.
--
-- A door has a color of its own, and the rule it used to follow said it could
-- not. That rule was about not borrowing: color belongs to teams and to weapon
-- classes, and a door wearing cyan or pink is a door somebody misreads under
-- fire. Green borrows from neither, so the door keeps its shape and its motion
-- and gains a hue, and shut and open now differ in color rather than only in
-- brightness. Which of the four clocks it is on is still a count of ticks on
-- its posts.
--
-- A run is framed once. Framed per tile, a four-tile gateway reads as four
-- separate shutters, which is four wrong answers to "can I fit through that".
--
-- Shut, it is a force field, not a shutter. The old drawing was a slate
-- slab with ribs and a meeting seam -- machinery, a thing with halves and
-- hinges -- and a barrier the map switches on and off is not machinery, it
-- is energy held between two points. So: a faint wash where the field
-- stands, a bright filament down the length of the gap flanked by two
-- dimmer ones that breathe by width, a charge that runs the length from
-- emitter to emitter, and a lit node at each end where the field takes hold
-- of the frame. The breathing is width rather than color because widths
-- are numbers and colors are tables, and this runs per door per frame.
local function door_run(fill, glow, x0, y0, x1, y1, vertical, group, shut, now)
    if shut then
        fill:rect(x0, y0, x1 - x0, y1 - y0, DOOR_WASH)
        local ax, ay, bx, by, ux, uy, nx, ny, span
        if vertical then
            ax, ay, bx, by = (x0 + x1) / 2, y0, (x0 + x1) / 2, y1
            ux, uy, nx, ny = 0, 1, 1, 0
            span = y1 - y0
        else
            ax, ay, bx, by = x0, (y0 + y1) / 2, x1, (y0 + y1) / 2
            ux, uy, nx, ny = 1, 0, 0, 1
            span = x1 - x0
        end
        glow:seg_glow(ax, ay, bx, by, 7, 0.20, pal.a(DOOR_LIT, 1))
        glow:seg(ax, ay, bx, by, 1.2, DOOR_SEAM)
        local br = 0.55 + 0.30 * math.sin(now * 6 + group * 1.7)
        glow:seg(ax + nx * 4, ay + ny * 4, bx + nx * 4, by + ny * 4,
                 0.6 + br * 0.5, DOOR_FIL)
        glow:seg(ax - nx * 4, ay - ny * 4, bx - nx * 4, by - ny * 4,
                 1.1 - br * 0.5, DOOR_FIL)
        -- The charge crosses the gap and leaves off the end before coming
        -- round, so it reads as sent rather than as orbiting.
        local ph = (now * 110 + group * 53) % (span + 24) - 12
        local p0, p1 = math.max(0, ph - 9), math.min(span, ph + 9)
        if p1 > p0 then
            glow:seg_glow(ax + ux * p0, ay + uy * p0,
                          ax + ux * p1, ay + uy * p1, 6, 0.55, DOOR_PULSE)
        end
        glow:halo(ax, ay, 8, 8, DOOR_NODE_HALO)
        glow:halo(bx, by, 8, 8, DOOR_NODE_HALO)
        fill:disc(ax, ay, 2.6, 6, DOOR_NODE)
        fill:disc(bx, by, 2.6, 6, DOOR_NODE)
    else
        -- Open, the gap is marked: brackets reaching in from the posts and a
        -- faint line across the threshold. Posts alone are a doorway a pilot
        -- cannot see until it shuts on them.
        if vertical then
            glow:seg(x0, y0, x0 + 4, y0, 1.0, DOOR_MARK, true)
            glow:seg(x1 - 4, y0, x1, y0, 1.0, DOOR_MARK, true)
            glow:seg(x0, y1, x0 + 4, y1, 1.0, DOOR_MARK, true)
            glow:seg(x1 - 4, y1, x1, y1, 1.0, DOOR_MARK, true)
            glow:seg(x0, (y0 + y1) / 2, x1, (y0 + y1) / 2, 0.7, DOOR_SILL)
        else
            glow:seg(x0, y0, x0, y0 + 4, 1.0, DOOR_MARK, true)
            glow:seg(x0, y1 - 4, x0, y1, 1.0, DOOR_MARK, true)
            glow:seg(x1, y0, x1, y0 + 4, 1.0, DOOR_MARK, true)
            glow:seg(x1, y1 - 4, x1, y1, 1.0, DOOR_MARK, true)
            glow:seg((x0 + x1) / 2, y0, (x0 + x1) / 2, y1, 0.7, DOOR_SILL)
        end
    end

    local post = shut and DOOR_POST_SHUT or DOOR_POST_OPEN
    local tick = shut and DOOR_TICK_SHUT or DOOR_TICK_OPEN
    local n = (group % 4) + 1
    for side = 0, 1 do
        local ax, ay, bx, by, ux, uy, nx, ny
        if vertical then
            ax, ay = (side == 0) and x0 or x1, y0
            bx, by = ax, y1
            ux, uy = 0, 1
            nx, ny = (side == 0) and 1 or -1, 0
        else
            ax, ay = x0, (side == 0) and y0 or y1
            bx, by = x1, ay
            ux, uy = 1, 0
            nx, ny = 0, (side == 0) and 1 or -1
        end
        glow:seg(ax, ay, bx, by, 1.3, post)
        local len = math.abs(bx - ax) + math.abs(by - ay)
        local mid = len / 2 - (n - 1) * 1.5
        for k = 0, n - 1 do
            local t = mid + k * 3
            glow:seg(ax + ux * t, ay + uy * t,
                     ax + ux * t + nx * 2.4, ay + uy * t + ny * 2.4, 0.9, tick)
        end
    end
end

-- Doors and the tiles that mark a place rather than block one. These cannot
-- go in the static mesh: a door is a wall on a clock, and a wall nobody can
-- see is the worst thing in the game.
-- The asteroids, turning. Drawn before the ships rather than with the doors,
-- because a rock's body is opaque and the fill layer composites in the order
-- it was written: after them it would paint over anything flying past one.
function M.draw_rocks(fill, glow, now, cull)
    local list = M.rocks
    if not list then return end
    for n = 1, #list do
        local e = list[n]
        if not outside(cull, e.x, e.y) then
            draw_rock(fill, glow, e.x, e.y, e.s, now)
        end
    end
end

function M.draw_tiles(fill, glow, now, cull)
    local list = M.moving_tiles
    local seen = {}
    for n = 1, #list do
        local t = list[n]
        local wx, wy = t.tx * TILE, t.ty * TILE
        if outside(cull, wx, wy) then
            -- off screen
        elseif t.cls == sim.T_DOOR then
            -- A door tile that continues one already drawn this frame is part
            -- of it, not another door.
            if not seen[t.ty * 1024 + t.tx] then
                local group = t.variant % 4
                -- Which way the run goes is read off the tiles, not off the
                -- variant. The format's 162-165 and 166-169 name how a door
                -- was drawn in the original's tileset, and a map is free to
                -- lay either of them out along either axis: the reference map
                -- lays its "vertical" doors in a row. Asking the neighbours is
                -- the only answer that is right for both.
                local function same(px, py)
                    local cls, var = sim.tile(px, py)
                    return cls == sim.T_DOOR and var == t.variant
                end
                local across = same(t.tx + 1, t.ty) or same(t.tx - 1, t.ty)
                local dx, dy = across and 1 or 0, across and 0 or 1
                local ex, ey = t.tx, t.ty
                while same(ex + dx, ey + dy) do
                    ex, ey = ex + dx, ey + dy
                    seen[ey * 1024 + ex] = true
                end
                -- Back to where the door actually begins, past the edge of the
                -- screen if that is where it begins.
                --
                -- The tile this run was found from is only the first one that
                -- survived the cull, and a door longer than the cull margin
                -- loses its start to it. Anchoring there made every fact the
                -- run derives from its own length -- the tick cluster at the
                -- middle, the sill of an open door, the phase of the charge
                -- travelling along it -- a function of how much of the door
                -- was on screen, so flying along a long door walked its
                -- furniture a tile at a time and re-wrapped the pulse. The
                -- ends are the map's, not the camera's.
                local sx, sy = t.tx, t.ty
                while same(sx - dx, sy - dy) do
                    sx, sy = sx - dx, sy - dy
                    seen[sy * 1024 + sx] = true
                end
                -- A run of tiles across the screen is a door that slides up
                -- and down, so its slats lie along the run and its posts cap
                -- the ends.
                door_run(fill, glow, sx * TILE, sy * TILE,
                         (ex + 1) * TILE, (ey + 1) * TILE,
                         not across, group, not sim.door_open(t.variant), now)
            end
        else
            -- A well, and a hole rather than a wall: you fly into it, and
            -- since touching one now moves the ship, it has to look like
            -- somewhere that goes somewhere rather than like a decorated
            -- floor tile.
            --
            -- Everything here travels inward. Four rings are born at the rim
            -- and fall to the eye on a shared clock, so at any moment there is
            -- one just appearing and one about to vanish, and each fades as it
            -- closes; the arms turn against that fall, which is what stops the
            -- whole thing reading as a single rotating sprite. The eye itself
            -- beats. None of it is state: it is all a function of the clock,
            -- so every client draws the same well at the same moment without
            -- anything being sent.
            local cx = t.tx * TILE + TILE / 2
            local cy = t.ty * TILE + TILE / 2
            local spin = now * 0.9
            fill:disc(cx, cy, 7, 10, pal.a(pal.BG, 1))
            local RIM, EYE = 38, 9
            for k = 1, 4 do
                -- Phase, offset a quarter turn per ring so they arrive evenly.
                local ph = (now * 0.45 + (k - 1) * 0.25) % 1
                local rr = RIM - (RIM - EYE) * ph
                -- Brightest in the middle of the fall: a ring that appeared
                -- at full strength would pop, and one that vanished at full
                -- strength would blink.
                local fade = math.sin(ph * math.pi)
                glow:ring(cx, cy, rr, 1.1, 20, pal.a(pal.HOLE, 0.36 * fade))
            end
            -- Arms, turning against the fall so the two motions read apart.
            for i = 0, 3 do
                local a0 = i * TAU / 4 - spin
                for k = 1, 5 do
                    glow:arc(cx, cy, 10 + (k - 1) * 5.5,
                             a0 + (k - 1) * 0.30, a0 + (k - 1) * 0.30 + 0.5,
                             1.3, 3, HOLE_ARM[k])
                end
            end
            -- The eye, beating. Slower than the rings, so the two clocks do
            -- not line up into one pulse.
            local beat = 0.5 + 0.5 * math.sin(now * 2.1)
            glow:halo(cx, cy, 15 + beat * 5, 10, pal.a(pal.HOLE, 0.24 + 0.16 * beat))
            glow:ring(cx, cy, 7, 1.4 + beat * 0.6, 12,
                      pal.a(pal.hot(pal.HOLE, 0.4, 1), 0.75 + 0.25 * beat))
        end
    end
end

-- Scenery that belongs above the ships, drawn after them for that reason. It
-- is the one thing on the map defined by what it is drawn over, so it cannot
-- ride in the static mesh, which is under everything.
function M.draw_over(glow, cull)
    local list = M.over_tiles
    for n = 1, #list do
        local t = list[n]
        local x, y = t.tx * TILE, t.ty * TILE
        if not outside(cull, x, y) then
            local a = pal.a(pal.PANEL_INK, 0.34)
            local kind = t.variant % 3
            if kind == 0 then
                glow:seg(x, y + 5, x + TILE, y + 5, 1.1, a)
                glow:seg(x, y + 11, x + TILE, y + 11, 1.1, a)
                for k = 0, 3 do
                    glow:seg(x + k * 4, y + 5, x + (k + 1) * 4, y + 11, 0.7,
                             pal.a(pal.PANEL_INK, 0.22))
                end
            elseif kind == 1 then
                glow:seg(x + 5, y, x + 5, y + TILE, 2.4,
                         pal.a(pal.PANEL_INK, 0.16))
                glow:seg(x + 5, y, x + 5, y + TILE, 0.8, a)
                glow:seg(x + 11, y, x + 11, y + TILE, 1.6,
                         pal.a(pal.PANEL_INK, 0.13))
            else
                glow:seg(x, y + 4, x + 12, y + 4, 1.0, a)
                glow:seg(x + 12, y + 4, x + 12, y + TILE, 1.0, a)
                glow:seg(x + 2, y + 4, x + 12, y + 14, 0.7,
                         pal.a(pal.PANEL_INK, 0.20))
            end
        end
    end
end

-- --- ships -----------------------------------------------------------------

-- Transform a hull into world space. Heading a travels along (sin a, -cos a)
-- in simulation coordinates, so that is where the local +y axis has to point.
--
-- `sx` scales the lateral axis alone, and it is how a hull banks: rolled
-- about its own long axis and seen from above, the wings foreshorten and
-- nothing else moves, which is exactly a cosine on local x.
local function place(pts, out, x, y, ca, sa, scale, sx)
    local kx = scale * (sx or 1)
    for i = 1, #pts, 2 do
        local px, py = pts[i] * kx, pts[i + 1] * scale
        out[i] = x + px * ca + py * sa
        out[i + 1] = y + px * sa - py * ca
    end
    return out
end

-- The same turn applied to directions rather than points, for the outward
-- normals the bloom leaves a hull by. They rotate with it and never translate.
local function place_dir(dirs, out, ca, sa)
    for i = 1, #dirs, 2 do
        local dx, dy = dirs[i], dirs[i + 1]
        out[i] = dx * ca + dy * sa
        out[i + 1] = dx * sa - dy * ca
    end
    return out
end

-- One ship.
--
-- Four weights of line rather than one, a body lit at the bow, and a
-- silhouette whose every edge carries its own brightness. Everything here goes
-- through primitives vec.lua already had, or through the two it grew for this:
-- a segment that fades across its width, and a skirt offset from a closed
-- outline. No shader, no texture, no second pass.
--
-- `thrusting` draws the flame, which is the only thing on screen that says a
-- pilot is accelerating rather than coasting. `far` drops the detail that only
-- reads up close; see M.DETAIL_RANGE.
-- One hull's color, warmed by whatever is burning next to it. Held as a
-- module scratch rather than made per ship per frame, and only ever read
-- inside the call that filled it.
local lit_col = {0, 0, 0, 1}
-- The hot edge, graded. Same bargain as lit_col: read during the call and
-- never kept, so one table serves every hull in the room.
local edge_col = {0, 0, 0, 1}

function M.ship(fill, glow, cls, x, y, heading, col, opts)
    local h = M.HULLS[cls + 1] or M.HULLS[1]
    -- A blast beside a hull throws its color onto it. Half weight at most, so
    -- a ship in the middle of a detonation is tinted rather than repainted:
    -- the team read lives on this color, and a pink Apex nobody can place is
    -- a worse bug than a flat one.
    local lr, lg, lb, lw = M.light_at(x, y)
    if lw > 0.02 then
        local k = lw * 0.5
        lit_col[1] = col[1] + (lr - col[1]) * k
        lit_col[2] = col[2] + (lg - col[2]) * k
        lit_col[3] = col[3] + (lb - col[3]) * k
        lit_col[4] = col[4]
        col = lit_col
    end
    local a = heading / 65536 * TAU
    local ca, sa = math.cos(a), math.sin(a)
    -- Roll, handed in as radians of bank. Everything below that speaks a
    -- local x multiplies by this, so the whole ship leans together: hull,
    -- plates, canopy, hardpoints, lamps and the engines, whose plumes stay
    -- on the heading while their nozzles come inboard.
    local squash = 1
    if opts and opts.roll and opts.roll ~= 0 then
        squash = math.cos(opts.roll)
    end
    local pts = place(h.poly, h.tmp, x, y, ca, sa, 1, squash)
    local mine = opts and opts.mine
    local dim = ((opts and opts.alpha) or 1) * (h.dim or 1)
    local near = not (opts and opts.far)
    -- How badly this hull is hurt, and whether it was hit a moment ago. Both
    -- come in from the arena rather than being read here, because this
    -- function draws one ship and is given everything about it; the arena is
    -- already holding the energy for the pip and the tick for the flare.
    local hurt = (opts and opts.hurt) or 0
    local flare = (opts and opts.flash) or 0

    -- The flame first, so the hull sits on top of it. Three parts: a bloom
    -- sitting in the nozzle, a soft cone, and a hot core down half its length.
    -- A single wide taper carries all its alpha at its widest and reads as a
    -- solid orange wedge.
    if opts and opts.thrusting then
        local flick = 0.72 + (opts.flicker or 0) * 0.28
        for i = 1, #h.jets, 2 do
            local jx = x + h.jets[i] * squash * ca + h.jets[i + 1] * sa
            local jy = y + h.jets[i] * squash * sa - h.jets[i + 1] * ca
            local len = 17 * flick
            local mx, my = jx + sa * 1.5, jy - ca * 1.5
            glow:halo(jx, jy, 5.4 * flick, 8, pal.a(pal.THRUST, 0.42 * dim))
            glow:bloom(jx, jy, 19 * flick, 0.15 * dim, pal.THRUST)
            -- An engine is a light like any other, which is what makes
            -- flying down a corridor light the corridor. Weaker and shorter
            -- than a blast, since a ship should warm a wall rather than
            -- announce itself through one.
            M.light(jx, jy, pal.THRUST, 0.28 * dim * flick, 60)
            glow:seg_fade(mx, my, jx - sa * len, jy + ca * len,
                          5.4, 0.6, 0.34 * dim, 0, pal.THRUST)
            glow:seg_fade(mx, my, jx - sa * len * 0.55, jy + ca * len * 0.55,
                          2.3, 0.5, 0.95 * dim, 0, pal.hot(pal.THRUST, 0.72, 1))
        end
    end

    -- Retros: one flame off the bow, firing forward. Smaller than the main
    -- flame, because reverse is a manoeuvre rather than a charge and a plume
    -- the same size ahead of the hull reads as flying the other way round.
    --
    -- Drawn at all because on a touchscreen the thrust sign is inferred from
    -- where your thumb is rather than commanded, and a pilot has to be able
    -- to see the answer somewhere they are already looking. That is the ship,
    -- not the corner their own thumb is covering.
    if opts and opts.reversing then
        local flick = 0.7 + (opts.flicker or 0) * 0.3
        local nx = x + h.nose * sa
        local ny = y - h.nose * ca
        local len = 10 * flick
        glow:seg_fade(nx, ny, nx + sa * len, ny - ca * len,
                      5.0, 0.95, 0.8 * dim, 0, pal.THRUST)
        glow:seg_fade(nx, ny, nx + sa * len * 0.45, ny - ca * len * 0.45,
                      2.6, 0.75, 1.0 * dim, 0, pal.hot(pal.THRUST, 0.75, 1))
    end

    -- The body, in two passes. An opaque base first, dark enough to be a hole
    -- in the starfield and tinted toward the team so it is never a black one;
    -- then an additive wash over it that is brightest at the bow and gone at
    -- the stern. The wash has to be additive rather than a lighter fill,
    -- because anything the fill layer draws below full alpha lets a star
    -- through the hull.
    local body = {col[1] * 0.055 + 0.018, col[2] * 0.055 + 0.026,
                  col[3] * 0.055 + 0.042, 0.95 * dim}
    local tris, lit = h.tris, h.lit
    for i = 1, #tris, 3 do
        local a1, b1, c1 = tris[i], tris[i + 1], tris[i + 2]
        fill:tri(pts[a1 * 2 - 1], pts[a1 * 2], pts[b1 * 2 - 1], pts[b1 * 2],
                 pts[c1 * 2 - 1], pts[c1 * 2], body)
        glow:tri_fade(pts[a1 * 2 - 1], pts[a1 * 2], lit[a1] * 0.20 * dim,
                      pts[b1 * 2 - 1], pts[b1 * 2], lit[b1] * 0.20 * dim,
                      pts[c1 * 2 - 1], pts[c1 * 2], lit[c1] * 0.20 * dim, col)
    end

    -- Interior structure, under the silhouette so the outline always wins.
    -- Drawn in a neutral instrument gray rather than in the team color: the
    -- team read belongs on the silhouette, and a hull whose every line is the
    -- same color looks cut from one sheet of neon rather than built.
    if near then
        if h.plates then
            for k = 1, #h.plates do
                local q = place(h.plates[k], h.ptmp[k], x, y, ca, sa, 1,
                                squash)
                glow:fan(q, pal.a(pal.PANEL_INK, 0.035 * dim))
                glow:outline(q, 0.85, pal.a(pal.PANEL_INK, 0.36 * dim), true)
            end
        end
        if h.lines then
            for k = 1, #h.lines do
                local q = place(h.lines[k], h.ltmp[k], x, y, ca, sa, 1,
                                squash)
                for i = 1, #q - 3, 2 do
                    glow:seg(q[i], q[i + 1], q[i + 2], q[i + 3], 0.7,
                             pal.a(pal.PANEL_INK, 0.26 * dim), true)
                end
            end
        end
    end

    -- Hardpoints, drawn hot: where a hull's damage comes out of is worth
    -- knowing at a glance, and it is the same element at every size, from the
    -- Apex's wing-root guns to the Anvil's two bomb tubes.
    if h.tubes then
        for k = 1, #h.tubes do
            local t = h.tubes[k]
            local ax = x + t[1] * squash * ca + t[2] * sa
            local ay = y + t[1] * squash * sa - t[2] * ca
            local bx = x + t[3] * squash * ca + t[4] * sa
            local by = y + t[3] * squash * sa - t[4] * ca
            glow:seg_glow(ax, ay, bx, by, t[5] + 4.0, 0.09 * dim, col)
            glow:seg(ax, ay, bx, by, t[5], pal.a(col, 0.30 * dim), true)
            glow:seg(ax, ay, bx, by, t[5] * 0.34,
                     pal.a(pal.hot(col, 0.55, 1), 0.9 * dim), true)
        end
    end

    -- The silhouette: two skirts of bloom and a hot edge on top, each edge at
    -- its own brightness. It was three concentric strokes, which beaded at
    -- every corner and banded rather than falling off.
    -- The normals are not squashed with the points. Correcting them is an
    -- inverse scale and a renormalize apiece, and what they aim is a soft
    -- skirt three to nine pixels deep: at the steepest bank the error is a
    -- few degrees on a gradient, which is nothing.
    local nrm = place_dir(h.nrm, h.ntmp, ca, sa)
    -- What the hull throws into the dark around it, under the skirts rather
    -- than instead of them: the skirts hug the silhouette and say what shape
    -- this is, and this says there is something lit here.
    glow:bloom(x, y, 30 + flare * 10, (0.085 + flare * 0.16) * dim, col)
    glow:glow_band(pts, nrm, 9.0, 0.105 * dim, col, h.wide)
    glow:glow_band(pts, nrm, 3.0, 0.32 * dim, col, h.band)
    -- The hot edge, which is the team color pushed toward white. A hurt hull
    -- pushes it toward HURT instead, so an outline that was cooling to white
    -- runs red as the energy goes.
    --
    -- Only the edge. The fill, the wash, the canopy and the bloom all stay on
    -- the team color, because the friend-or-foe read is the call a pilot
    -- makes in a tenth of a second and nothing may put a second question
    -- inside it. What this changes is the one stroke already carrying no
    -- information: a rim that was there to say "lit" and now says how lit.
    -- Enemies had nothing at all before this. Their pip only appears when
    -- they are hurt, but a 22-pixel bar over a hull in a scrap is not a
    -- reading, and an enemy at eight percent looked exactly like one at
    -- ninety right up until it died.
    --
    -- The flare from a fresh hit rides on top, toward white and brighter,
    -- which is the opposite direction and deliberately so: taking a round is
    -- a moment and being wounded is a state, so they must not look alike.
    local edge = pal.hot(col, mine and 0.62 or 0.34, 1)
    if hurt > 0 or flare > 0 then
        local k = hurt * 0.7
        for c = 1, 3 do
            local v = edge[c] + (pal.HURT[c] - edge[c]) * k
            edge_col[c] = v + (1 - v) * flare * 0.8
        end
        edge_col[4] = 1
        edge = edge_col
    end
    local ea = dim * (1 + flare * 0.9)
    local n = #pts
    local e = 1
    for i = 1, n, 2 do
        local j = (i + 1 < n) and i + 2 or 1
        glow:seg(pts[i], pts[i + 1], pts[j], pts[j + 1], 1.5 + flare * 1.1,
                 pal.a(edge, math.min(1, h.hot[e] * ea)), true)
        e = e + 1
    end

    -- The canopy. Every hull has one, it is always the brightest closed shape
    -- on the ship, and it is always forward of center, so "which end is the
    -- front" never needs a second look.
    if h.canopy then
        local q = place(h.canopy, h.ctmp, x, y, ca, sa, 1, squash)
        glow:fan(q, pal.a(pal.hot(col, 0.3, 1), 0.42 * dim))
        glow:outline(q, 0.9, pal.a(pal.hot(col, 0.8, 1), 0.95 * dim), true)
    end

    -- Lamps, dispensers and docking cradles. Six segments, not twelve: at two
    -- pixels across the difference is invisible, and round primitives were
    -- costing as much as the whole silhouette.
    if near and h.pods then
        for k = 1, #h.pods do
            local d = h.pods[k]
            local lx = x + d[1] * squash * ca + d[2] * sa
            local ly = y + d[1] * squash * sa - d[2] * ca
            glow:halo(lx, ly, d[3] * 2.6, 6, pal.a(col, 0.30 * dim))
            glow:disc(lx, ly, d[3] * 0.45, 4,
                      pal.a(pal.hot(col, 0.8, 1), 0.8 * dim))
        end
    end

    -- Engines lit at idle, so a coasting hull still has something running.
    for i = 1, #h.jets, 2 do
        local jx = x + h.jets[i] * squash * ca + h.jets[i + 1] * sa
        local jy = y + h.jets[i] * squash * sa - h.jets[i + 1] * ca
        glow:halo(jx, jy, 4.2, 6, pal.a(pal.THRUST, 0.15 * dim))
    end

    -- Your own ship carries a halo. In a room of nine identical outlines the
    -- one question a player asks every second is "which one is me".
    if mine then
        glow:halo(x, y, 26, 12, pal.a(col, 0.10 * dim))
    end

    -- A pilot on a run wears gold, and the gold moves.
    --
    -- Last, so it sits over the silhouette rather than under it, and in a hue
    -- no side owns: the friend-or-foe read is made on the outline's color in a
    -- tenth of a second and nothing may put a second question inside it. What
    -- this adds is a third thing that is true of a hull at the same time as
    -- its side and its health, and it has to survive being seen at the edge of
    -- vision, which is why it is the one thing in the arena that shimmers.
    --
    -- Three parts. A gold skirt outside the hull's own, so the shape reads as
    -- gilded rather than repainted; a bloom saying there is something lit
    -- here; and seven sparks going round, each breathing on its own clock.
    -- The sparks are what carries it at distance, where the skirt is a few
    -- pixels and the bloom is a smudge.
    if opts and opts.gleam then
        local t = opts.gleam
        local gold = pal.gleam(t, 1)
        local beat = 0.62 + 0.38 * math.sin(t * 3.4)
        glow:glow_band(pts, nrm, 13.0, 0.085 * beat * dim, gold, h.wide)
        glow:bloom(x, y, 46, 0.055 * beat * dim, gold)
        for k = 0, GLEAM_SPARKS - 1 do
            -- Around the hull rather than around the point: an Anvil is twice
            -- the beam of a Cipher, and sparks at one radius would be inside
            -- one and a long way off the other.
            local a2 = t * 1.25 + k * (TAU / GLEAM_SPARKS)
            local r = h.reach + 7 + 2.5 * math.sin(t * (4.3 + k * 0.61) + k * 2.1)
            local px, py = x + math.cos(a2) * r, y + math.sin(a2) * r
            local sc = pal.gleam(t + k * 0.17, 1)
            -- Each spark breathes at its own frequency, floored well above
            -- dark. Sparks stepped along one shared clock put several dim
            -- moments together, and the ring reads as two or three lamps
            -- strobing off center; unshared frequencies keep the dips apart,
            -- and the floor keeps every spark present, so the ring reads
            -- whole and round from any single glance.
            local up = 0.35 + 0.65 * (0.5 + 0.5 * math.sin(t * (3.1 + k * 0.83)
                                                           + k * 2.4))
            glow:halo(px, py, 5.4 * (0.7 + 0.3 * up), 6,
                      pal.a(sc, 0.5 * up * dim))
            glow:disc(px, py, 1.15, 4, pal.a(pal.hot(sc, 0.7, 1), up * dim))
        end
    end
end

-- The energy pip above a hull. Energy is health in this game -- it powers the
-- guns and it absorbs the damage -- so one bar says both things, and a
-- wounded enemy reads at a glance without a number anywhere near it.
--
-- World space, not screen: zoom is fixed at one, so twenty-two world pixels
-- are twenty-two screen pixels and the pip needs no projection of its own.
function M.energy_fraction(ship)
    return sim.ship_energy(ship) / math.max(1, sim.ship_max_energy(ship))
end

function M.ship_bar(fill, glow, sx, sy, frac, col)
    local W, H = 22, 2.5
    local x, y = sx - W / 2, sy - 26
    fill:rect(x - 1, y - 1, W + 2, H + 2, pal.a(pal.BG, 0.8))
    fill:rect(x, y, W, H, pal.a(pal.BAR_EDGE, 0.5))
    if frac > 0 then
        glow:rect(x, y, W * math.min(1, frac), H, pal.a(col, 0.9))
    end
end

-- --- weapons ---------------------------------------------------------------
--
-- What a projectile looks like is this file's business and nowhere else's.
-- The simulation hands over a spec id and the numbers that spec flies by; the
-- picture is looked up here, exactly as a tile's class carries no picture and
-- the terrain builder chooses one. A weapon with a blast is drawn as a bomb
-- because it *is* one -- the appearance follows a simulation property rather
-- than a second field that could disagree with it.
local blast_of = {}
local level_of = {}

local life_of = {}
-- What each pilot was last seen holding, by ship and charge slot. See
-- `M.charges`.
local charge_seen = {}

-- What each pilot's trigger was last seen doing, by ship. See `M.shots`.
local shot_seen = {}

-- How far from the camera somebody else's muzzle is still drawn. A little
-- over a phone's half-diagonal, so a shot just off the edge of the glass
-- still throws its light onto what is on it.
local MUZZLE_R = 900

-- --- being hit -------------------------------------------------------------
--
-- The tick each hull last took damage on, so its outline can flare for a
-- moment afterwards. Sparks at the point of impact say something landed;
-- they do not say *who* it landed on, and in a four-way scrap that is the
-- question. A hull that flashes when it is hit answers it on the hull.
--
-- Kept on the sim clock rather than on frame time because the events that
-- write it are read off the core and the draw that reads it already has the
-- tick to hand, so there is no second clock to keep in step.
local HIT_TICKS = 12
local hit_at = {}

-- This hull took one, now.
function M.note_hit(i)
    hit_at[i] = sim.tick()
end

-- How lit this hull is by the hit it just took, from 1 down to 0. Falls to
-- nothing once the window is spent, and clears itself on the way past so a
-- room that has been running an hour is not carrying a number per seat that
-- nobody will read again.
--
-- A negative age means the clock went backwards, which it does: prediction
-- rewinds and re-runs on every correction. Treated as expired, because a
-- flash that came back after the rewind would flash twice.
function M.hit_flash(i)
    local at = hit_at[i]
    if not at then return 0 end
    local age = sim.tick() - at
    if age < 0 or age >= HIT_TICKS then
        hit_at[i] = nil
        return 0
    end
    return 1 - age / HIT_TICKS
end

-- A spec id means whatever the current settings say it means, and a zone
-- sends its own -- so the answers cached here stop being true the moment a
-- settings message lands. Cheap to rebuild, wrong to keep.
function M.forget_specs()
    blast_of = {}
    level_of = {}
    life_of = {}
    charge_seen = {}
    shot_seen = {}
end

local function spec_blast(id)
    local r = blast_of[id]
    if r == nil then
        r = sim.spec_blast(id)
        blast_of[id] = r
    end
    return r
end

-- The rung a spec sits on, or -1 for a weapon on no ladder: a charge like
-- the burst, or a bomb's shrapnel. The color tables answer both.
local function spec_level(id)
    local r = level_of[id]
    if r == nil then
        r = sim.spec_level(id)
        level_of[id] = r
    end
    return r
end

local function spec_life(id)
    local r = life_of[id]
    if r == nil then
        r = sim.spec_life(id)
        life_of[id] = r
    end
    return r
end

local function bomb_col(lvl)
    if lvl < 0 then return pal.BURST end
    return pal.rung(lvl)
end

-- One bomb rung of blast radius, in world pixels: BombExplodePixels for a
-- rung one bomb, and every rung above it is a multiple of that.
local BLAST_STEP = 80

-- Which of the four detonation sounds a blast of this radius gets.
--
-- Off the radius rather than off the rung that fired it, though for a bomb
-- the two say the same thing, since a bomb rung is exactly a wider blast.
-- The radius answers the rest as well. A repel is a detonation on no ladder
-- at all, so it has no rung to read, and its shove clears 512 pixels, wider
-- than a top rung bomb; asked for its level it would come back with -1 and be
-- played as the smallest thing in the kit. Sizing every detonation by the
-- hole it makes is one rule for all of them, and it is the hole the player is
-- watching.
--
-- A zone that moves BombExplodePixels moves how loud its detonations sound
-- and nothing else, which is a drift worth having over a second mechanism.
local function blast_rung(r)
    local k = math.floor(r / BLAST_STEP) - 1
    return k > 0 and k or 0
end

-- Remember private charge counts for the owner. Remote counts are withheld;
-- their one-tick blast arrives through `M.remote_charge` instead.
--
-- A repel is a weapon whose life is one tick. It is spawned and gone inside a
-- single step, so it reaches the state a snapshot is packed from only when the
-- tick it was fired on happens to be a snapshot tick, which at 20 Hz over a
-- 100 Hz simulation is one time in five. The other four the watcher is sent
-- nothing at all: no weapon to draw, no expiry to hear, only ships suddenly
-- moving. Your own is fine, because you simulate the whole of it yourself.
--
-- Nobody noticed for as long as nobody fired one. The bots learned to spend
-- charges this week and now a room is full of shoves with no explanation
-- attached to four fifths of them.
--
-- The old client inferred this from every pilot's inventory. That made exact
-- enemy charge counts public. The arena now sends the action only to views
-- whose fixed fairness circle contains the firing ship.
-- The perspective seat's team, guarded. The arena hands these functions 255
-- while watching a room through nobody's eyes, and 255 is a byte that indexes
-- no seat: it belongs to no side, so everything reads as hostile, which is
-- what a stranger's fight should look like.
local function team_of(i)
    if not i or i < 0 or i >= sim.ship_count() then return 255 end
    return sim.ship_team(i)
end

function M.charges(me, sfx)
    local n = sim.ship_count()
    for i = 0, n - 1 do
        local seen = charge_seen[i]
        if not seen then seen = {} charge_seen[i] = seen end
        local alive = sim.ship_alive(i) == 1
        if sim.ship_private and not sim.ship_private(i) then
            charge_seen[i] = {alive = alive}
        else
        for k = 0, sim.MAX_CHARGES - 1 do
            local held = sim.ship_charge(i, k)
            local was = seen[k]
            -- Your own is drawn by your own simulation, on the expiry event,
            -- and drawing it twice would put two shockwaves on one shove.
            --
            -- A seat that was empty a moment ago, or a hull that just died or
            -- respawned, is not a pilot spending anything: an arrival is
            -- outfitted and a departure leaves zeroes behind, and both look
            -- like a drop from here.
            if was and held < was and i ~= me and alive and seen.alive then
                local spec = sim.charge_spec(k)
                local blast = spec >= 0 and spec_blast(spec) or 0
                if spec >= 0 and blast > 0 and spec_life(spec) <= 1 then
                    local x, y = sim.ship_x(i), sim.ship_y(i)
                    fx.detonate(x, y, blast, bomb_col(spec_level(spec)))
                    sfx("blast", x, y, blast_rung(blast))
                end
            end
            seen[k] = held
        end
        seen.alive = alive
        end
    end
    -- Seats past the end of the room belong to nobody now, and holding their
    -- counts would greet whoever takes one with a shockwave.
    for i in pairs(charge_seen) do
        if i >= n then charge_seen[i] = nil end
    end
end

-- Draw a remote charge action announced by the arena. Most charges leave
-- rounds that already draw themselves. A one-tick blast does not survive to a
-- snapshot, so it is the case this explicit public event restores.
function M.remote_charge(slot, x, y, sfx)
    local spec = sim.charge_spec(slot)
    local blast = spec >= 0 and spec_blast(spec) or 0
    if spec >= 0 and blast > 0 and spec_life(spec) <= 1 then
        fx.detonate(x, y, blast, bomb_col(spec_level(spec)))
        sfx("blast", x, y, blast_rung(blast))
    end
end

-- Somebody else's trigger.
--
-- The fire event only ever fires here for the ship you are flying, and that is
-- not a bug in the event: this client predicts one ship. `sim.replay` is handed
-- your buttons and nobody else's, so a remote pilot is flown coasting, their
-- trigger is never pulled locally, and no fire event for them can exist. Their
-- rounds arrive already in the air, in a snapshot. So an arena sounded of
-- explosions and wall hits and nothing at all leaving the guns making them,
-- which reads as though everyone else is shooting blanks.
--
-- Two things in every snapshot say it happened. `fire_cooldown` is the honest
-- one: a shot sets it and each tick takes one off, so on a hull nothing local
-- can fire it only ever counts down, and a rise came from the wire. It cannot
-- lie the way a weapon appearing can, because prediction kills remote rounds
-- against ships whose position it got wrong, and the next snapshot puts them
-- back, which looks exactly like firing.
--
-- What it does not say is *what* was fired, so the rounds answer that: the
-- count of live ones by family, over the same tick. A cooldown that rose while
-- their bomb count did was a bomb. Rounds a snapshot never carried, from
-- somebody shooting on the far side of the map past the cull, leave neither
-- count moving and are silent, which is where they belong.
--
-- Missing one is cheaper than inventing one, so both signals have to agree.
local guns, bombs, gun_spec, bomb_spec = {}, {}, {}, {}
function M.shots(me, sfx)
    local n = sim.ship_count()
    for i = 0, n - 1 do
        guns[i], bombs[i], gun_spec[i], bomb_spec[i] = 0, 0, nil, nil
    end
    for i = 0, sim.weapon_count() - 1 do
        local _, _, spec, _, _, _, _, owner, depth = sim.weapon_at(i)
        -- A fragment is nobody's aim, and a repel is spent from an inventory
        -- rather than fired. `M.charges` has that one, and counting it here
        -- would put a bomb shot on top of the shockwave.
        if depth == 0 and guns[owner] and spec_life(spec) > 1 then
            if spec_blast(spec) > 0 then
                bombs[owner] = bombs[owner] + 1
                bomb_spec[owner] = spec
            else
                guns[owner] = guns[owner] + 1
                gun_spec[owner] = spec
            end
        end
    end

    for i = 0, n - 1 do
        local seen = shot_seen[i]
        if not seen then seen = {cd = 0, gun = 0, bomb = 0} shot_seen[i] = seen end
        local cd = sim.ship_cooldown(i)
        local g, b = guns[i], bombs[i]
        -- A seat that just filled, or a hull that just died or respawned,
        -- arrives with numbers that have nothing to do with the ones before
        -- them, and every one of those changes looks like a shot from here.
        local alive = sim.ship_alive(i) == 1
        if i ~= me and alive and seen.alive and cd > seen.cd then
            local x, y = sim.ship_x(i), sim.ship_y(i)
            local bombed = b > seen.bomb
            if bombed then
                sfx("bomb", x, y, spec_level(bomb_spec[i]))
            elseif g > seen.gun then
                sfx("gun", x, y, spec_level(gun_spec[i]))
            end
            -- And the picture, which everyone else's guns did not have.
            -- `M.events` puts a muzzle on every shot the core reports, and
            -- the core reports the shots this client predicts: your own.
            -- Somebody else opening up two hulls away was a sound and a
            -- round already forty pixels out, with nothing at the barrel to
            -- say where it came from.
            --
            -- Only within a screen or so of whoever is watching. A sound
            -- from across the arena is attenuated and costs nothing; sixty
            -- seats' worth of off-screen muzzle would spend the particle
            -- budget on things nobody can see and crowd out an explosion
            -- that is happening in front of them.
            if fx.near(x, y, MUZZLE_R) then
                local ang = sim.ship_heading(i) / 65536 * TAU
                local col = bombed and pal.BOMB
                    or (sim.ship_team(i) == team_of(me) and pal.FRIEND
                        or pal.ENEMY)
                local mx, my = x + math.sin(ang) * 10, y - math.cos(ang) * 10
                fx.cone(mx, my, ang, bombed and 0.9 or 0.35,
                        bombed and 7 or 3, bombed and 120 or 190, 0.14,
                        bombed and 2.2 or 1.4, col)
                fx.flash(mx, my, bombed and 26 or 15, bombed and 0.13 or 0.1,
                         bombed and 0.7 or 0.5, pal.hot(col, 0.55, 1),
                         bombed and 0.75 or 0.5)
            end
        end
        seen.cd, seen.gun, seen.bomb, seen.alive = cd, g, b, alive
    end

    for i in pairs(shot_seen) do
        if i >= n then shot_seen[i] = nil end
    end
end

-- Rounds this client has already been drawing, so the ones that just arrived
-- can be told from the ones in flight. A round has no id on the wire and needs
-- none: its owner, its spec and the tick it was born on name it, and the birth
-- falls out of how much life it has spent. A multifire fan shares one key and
-- therefore one fade, which is what a fan launched together should do anyway.
local flown = {}

-- Enemy fire is known a round trip late, so it enters the state already well
-- into its flight: one frame nothing, the next a round forty pixels out with
-- its streak drawn whole. Two things soften the arrival into something the
-- eye reads as "was already flying" rather than "appeared". It blooms in,
-- from dim to full over a tenth of a second, never from invisible, because a
-- live round the player could dodge must not be hidden for style. And for
-- that tenth its streak reaches back toward where it was actually fired,
-- easing down to the standard trail as it settles; the velocity is constant
-- in flight, so age times velocity is the true path just flown.
--
-- Your own rounds are exempt by age rather than by ownership: anything first
-- seen within a few ticks of birth left a muzzle on this screen, and a fade
-- would only mute the trigger. Age keys the exemption because ownership
-- would get the cull case wrong: an enemy round fired far away and flown
-- into view was in the state the whole way, is found here long before it is
-- drawn, and arrives with its fade already spent, which is correct.
local FADE_S = 0.12
local function arrival(spec, life, owner, t)
    local age = spec_life(spec) - life
    local born = owner * 16777216 + spec * 65536 + (sim.tick() - age) % 65536
    local seen = flown[born]
    if not seen then
        seen = {t0 = t, late = age > 4}
        flown[born] = seen
    end
    seen.t = t
    local fade = 1
    if seen.late then
        fade = math.min(1, (t - seen.t0) / FADE_S)
    end
    return fade, age
end

-- --- ship trails -----------------------------------------------------------
--
-- A ribbon behind every live hull: the last dozen committed positions of the
-- drawn ship, fading over about half a second. Client-side and cosmetic: it
-- follows the smoothed positions the hull is drawn at, so it rides the same
-- easing the hull does.
--
-- Samples commit on a clock, not per frame. The first cut kept one sample a
-- frame in a nine-slot ring, which is a hundred and fifty milliseconds of
-- path: thirty-odd pixels at flight speed, at thirty percent alpha, mostly
-- under the hull and the engine plume. It drew every frame and nobody ever
-- saw it. Fifty milliseconds a sample and twelve samples is six hundred
-- milliseconds, which at flight speed is a ribbon long enough to be the
-- point. The head still hugs the ship every frame, drawn live from the hull
-- to the newest committed sample, so the cadence shapes the tail without
-- ever detaching the front.
local TRAIL_LEN = 12
local TRAIL_STEP = 0.05
M.TRAIL_VERTS = TRAIL_LEN * 6
local trails = {}

-- Where a ribbon starts: the exhaust, not the middle of the hull. Each
-- class's depth is read off its own jets, the points the engine plumes
-- already draw from, so the ribbon leaves exactly where the fire does and a
-- hull redrawn with its engines somewhere new takes its ribbon along.
local TAIL = {}
for ci = 1, #M.HULLS do
    local jets = M.HULLS[ci].jets
    local depth = 0
    for k = 2, #jets, 2 do
        if -jets[k] > depth then depth = -jets[k] end
    end
    TAIL[ci] = depth
end

-- Whose ribbon wears the pilot's wake choice, and which choice. Set by the
-- arena each frame: this file knows ships by index and nothing about which
-- one is the player's. The choice is client-side cosmetic, like the ribbon
-- itself: other clients draw this hull their own standard way.
M.wake_of = nil
M.wake_style = 0

function M.trail(glow, i, x, y, heading, cls, col, t)
    -- The wake, where this is the ship it belongs to: 1 stretches the
    -- ribbon by committing samples at twice the interval (same ring, same
    -- cost, twice the seconds of path), 2 leaves none at all. The samples
    -- are still kept when drawing is off, so turning the wake back on does
    -- not open on a stub.
    local style = (i == M.wake_of) and M.wake_style or 0
    -- From the hull's center to its tail, along the drawn heading: zero is
    -- north, and the simulation's +y runs down.
    local d = TAIL[cls + 1] or 0
    if d > 0 then
        local a = heading / 65536 * math.pi * 2
        x = x - math.sin(a) * d
        y = y + math.cos(a) * d
    end
    local tr = trails[i]
    if not tr then
        tr = {n = 0, at = 0, t = t, pushed = -1e9}
        trails[i] = tr
    end
    -- A gap in the record is a death, a respawn, or time spent off screen,
    -- and a wormhole is a jump with no gap at all. Whichever it was, a
    -- ribbon drawn across it would be a line the ship never flew.
    if t - tr.t > 0.2 then tr.n = 0 end
    if tr.n > 0 then
        local lx, ly = tr[tr.at * 2 - 1], tr[tr.at * 2]
        local dx, dy = x - lx, y - ly
        if dx * dx + dy * dy > 90 * 90 then tr.n = 0 end
    end
    tr.t = t
    local cadence = (style == 1) and TRAIL_STEP * 2 or TRAIL_STEP
    if tr.n == 0 or t - tr.pushed >= cadence then
        tr.at = tr.at % TRAIL_LEN + 1
        tr[tr.at * 2 - 1], tr[tr.at * 2] = x, y
        if tr.n < TRAIL_LEN then tr.n = tr.n + 1 end
        tr.pushed = t
    end
    if style == 2 then return end
    -- From the hull back through the committed samples, fading and thinning
    -- as it goes. Alphas ride the team color through seg_fade's own vertex
    -- alpha, so no color tables are made here, at sixty a second, per hull.
    local ax, ay = x, y
    for back = 0, tr.n - 1 do
        local slot = (tr.at - back - 1) % TRAIL_LEN + 1
        local bx, by = tr[slot * 2 - 1], tr[slot * 2]
        -- A resting ship commits the same point over and over, and the head
        -- sits on the newest sample the frame it commits. Those segments
        -- have no length and say nothing; skipping them here rather than in
        -- the layer keeps the ribbon's cost equal to what it shows.
        if ax ~= bx or ay ~= by then
            local f1 = 1 - back / TRAIL_LEN
            local f2 = 1 - (back + 1) / TRAIL_LEN
            glow:seg_fade(ax, ay, bx, by, 0.5 + 2.9 * f1, 0.5 + 2.9 * f2,
                          0.38 * f1, 0.38 * f2, col)
        end
        ax, ay = bx, by
    end
end

-- --- light on the walls -----------------------------------------------------
--
-- The per-frame lights: bright rounds and blasts, gathered while they are
-- drawn and spent on the wall edges near them. A flat array with a stride
-- rather than a table per light, for the usual reason: this refills at
-- sixty a second.
local LIGHT_MAX = 10
local LIGHT_STRIDE = 6
local lights = {n = 0}

function M.lights_begin()
    lights.n = 0
end

-- A full list keeps the loudest, rather than whatever arrived first.
--
-- Order here is draw order, which has nothing to do with what matters: the
-- blasts are gathered before the frame starts and every thrusting engine
-- adds one while its hull draws, so ten ships coasting past a corridor could
-- fill the list with engine glow and drop the bomb that went off next to
-- them. Ten entries is a short enough scan to just find the weakest and take
-- its place, which makes the result depend on the fight instead of on the
-- order the renderer happens to walk it in.
function M.light(x, y, col, strength, reach)
    local n = lights.n
    local base
    if n >= LIGHT_MAX then
        local worst, wi = strength, -1
        for li = 0, LIGHT_MAX - 1 do
            local s = lights[li * LIGHT_STRIDE + 4]
            if s < worst then worst, wi = s, li end
        end
        if wi < 0 then return end
        base = wi * LIGHT_STRIDE
    else
        base = n * LIGHT_STRIDE
        lights.n = n + 1
    end
    lights[base + 1], lights[base + 2] = x, y
    lights[base + 3] = col
    lights[base + 4], lights[base + 5] = strength, reach
end

local function dist(x0, y0, x1, y1)
    local dx, dy = x1 - x0, y1 - y0
    return math.sqrt(dx * dx + dy * dy)
end

-- What the lights add at one point, as a color and a strength.
--
-- The walls read the same list geometrically, edge by edge; a hull is small
-- enough that one sample at its middle is the whole answer. Returned as three
-- numbers and a weight rather than a table, because this is asked once per
-- hull per frame and a fresh {r,g,b} apiece is garbage a fight cannot afford.
function M.light_at(x, y)
    local r, g, b, w = 0, 0, 0, 0
    for li = 0, lights.n - 1 do
        local base = li * LIGHT_STRIDE
        local dx, dy = x - lights[base + 1], y - lights[base + 2]
        local reach = lights[base + 5]
        local d2 = dx * dx + dy * dy
        if d2 < reach * reach then
            local col = lights[base + 3]
            local a = lights[base + 4] * (1 - math.sqrt(d2) / reach)
            if a > 0 then
                r = r + col[1] * a
                g = g + col[2] * a
                b = b + col[3] * a
                w = w + a
            end
        end
    end
    if w > 1 then
        r, g, b = r / w, g / w, b / w
        w = 1
    elseif w > 0 then
        r, g, b = r / w, g / w, b / w
    end
    return r, g, b, w
end

-- Exposed wall edges near each light, brightened in the light's own color.
-- The terrain mesh is static and rebuilt only when the camera walks, so the
-- flicker of passing fire cannot live there; it is drawn over the top, on
-- the glow layer, where bloom picks it up with everything else bright.
--
-- The scan is bounded twice: at most LIGHT_MAX lights a frame, and at most
-- a five-tile radius each, so the worst frame reads a few hundred tiles.
function M.wall_light(glow)
    for li = 0, lights.n - 1 do
        local base = li * LIGHT_STRIDE
        local lx, ly = lights[base + 1], lights[base + 2]
        local col = lights[base + 3]
        local s, reach = lights[base + 4], lights[base + 5]
        local rt = math.min(math.ceil(reach / TILE), 5)
        local tx0, ty0 = math.floor(lx / TILE), math.floor(ly / TILE)
        for ty = ty0 - rt, ty0 + rt do
            for tx = tx0 - rt, tx0 + rt do
                if sim.solid(tx, ty) then
                    local x0, y0 = tx * TILE, ty * TILE
                    -- Each open side is an exposed edge; alpha falls off
                    -- with the distance from the light to its middle.
                    if not sim.solid(tx - 1, ty) then
                        local d = dist(lx, ly, x0, y0 + TILE / 2)
                        local a = s * (1 - d / reach)
                        if a > 0.04 then
                            glow:seg_glow(x0, y0, x0, y0 + TILE, 1.6, a, col)
                        end
                    end
                    if not sim.solid(tx + 1, ty) then
                        local d = dist(lx, ly, x0 + TILE, y0 + TILE / 2)
                        local a = s * (1 - d / reach)
                        if a > 0.04 then
                            glow:seg_glow(x0 + TILE, y0, x0 + TILE, y0 + TILE,
                                          1.6, a, col)
                        end
                    end
                    if not sim.solid(tx, ty - 1) then
                        local d = dist(lx, ly, x0 + TILE / 2, y0)
                        local a = s * (1 - d / reach)
                        if a > 0.04 then
                            glow:seg_glow(x0, y0, x0 + TILE, y0, 1.6, a, col)
                        end
                    end
                    if not sim.solid(tx, ty + 1) then
                        local d = dist(lx, ly, x0 + TILE / 2, y0 + TILE)
                        local a = s * (1 - d / reach)
                        if a > 0.04 then
                            glow:seg_glow(x0, y0 + TILE, x0 + TILE, y0 + TILE,
                                          1.6, a, col)
                        end
                    end
                end
            end
        end
    end
end

function M.weapons(fill, glow, t, cull)
    local pulse = 0.72 + 0.28 * math.sin(t * 11)
    for i = 0, sim.weapon_count() - 1 do
        local x, y, spec, vx, vy, _, life, owner, depth, level = sim.weapon_at(i)
        local fade, age = arrival(spec, life, owner, t)
        local af = 0.45 + 0.55 * fade
        if outside(cull, x, y) then
            -- nothing: off screen
        elseif spec_blast(spec) > 0 then
            -- A bomb is a heavy, slow, obviously dangerous object: a hot core
            -- inside a ring that breathes, with a trail long enough to read
            -- its heading from across the arena. Its rung is its hue -- see
            -- the palette -- so what is coming says how hard it hits.
            local col = bomb_col(spec_level(spec))
            M.light(x, y, col, 0.55 * af, 78)
            local reach = 7 + (math.min(age, 20) - 7) * (1 - fade)
            glow:seg_fade(x - vx * reach, y - vy * reach, x, y,
                          1.5, 5.5, 0, 0.55 * af, col)
            glow:halo(x, y, 13 * pulse, 10, pal.a(col, 0.5 * af))
            glow:bloom(x, y, 38 * pulse, 0.20 * af, col)
            glow:ring(x, y, 4.6, 1.4, 10, pal.a(col, 0.95 * af))
            fill:disc(x, y, 3.6, 8, pal.a(pal.hot(col, 0.8, 1), 0.9 * af))
        else
            -- A bolt: a streak along its own velocity with a hot head. The
            -- streak is what makes a stream of fire read as a direction
            -- rather than as a scatter of dots, and it is the whole reason
            -- the core reports weapon velocity to the client at all. The
            -- The rung it was fired at, and nothing else: a round's color
            -- says how hard it hits, not who sent it. It said the team once,
            -- climbing toward white with the rung, and the two facts fought:
            -- the ramps converged at the top, so the deadliest rounds were
            -- the ones hardest to read either way. A bolt from no ladder is
            -- violet, because it answers to nobody's aim.
            --
            -- A fragment is not one of those, and was drawn as one anyway.
            -- Shrapnel *is* bullets: the core reads the rung and the bounce
            -- off the thrower's guns at the throw, and the fragment does a
            -- bullet of that rung's damage. So a pilot who had climbed to red
            -- bullets threw red fragments and watched violet ones come out,
            -- which is the ramp lying about the one thing it exists to say.
            --
            -- The rung has to come off the round rather than off the spec.
            -- Every fragment in the game is one spec, since a rung adds to its
            -- damage instead of pointing at a row of its own, so `spec_level`
            -- finds it on nobody's ladder and answers -1. Depth is what says a
            -- round is a fragment; only a splinter has one.
            local lvl = spec_level(spec)
            if lvl < 0 and depth > 0 then lvl = level end
            local col = lvl < 0 and pal.BURST or pal.rung(lvl)
            M.light(x, y, col, 0.4 * af, 52)
            local reach = 14 + (math.min(age, 30) - 14) * (1 - fade)
            glow:seg_fade(x - vx * reach, y - vy * reach, x, y,
                          0.6, 4.5, 0, 0.30 * af, col)
            glow:seg_fade(x - vx * 6, y - vy * 6, x, y, 0.8, 2.6, 0,
                          0.85 * af, col)
            glow:seg_fade(x - vx * 2, y - vy * 2, x, y, 0.6, 1.6, 0, af,
                          pal.hot(col, 0.9, 1))
            glow:halo(x, y, 7, 8, pal.a(col, 0.55 * af))
            -- And the light it sheds. Wide and faint, so a stream of fire
            -- brightens the space it crosses rather than staying a line of
            -- separate dots.
            glow:bloom(x, y, 24, 0.16 * af, col)
        end
    end
    -- Rounds that stopped existing take their fade state with them, or the
    -- table holds one entry per shot ever fired. Anything not touched this
    -- frame is gone from the simulation; a rollback that briefly removes and
    -- restores a round re-arrives under the same key inside one frame, so it
    -- never trips this.
    for born, seen in pairs(flown) do
        if seen.t ~= t then flown[born] = nil end
    end
end

-- --- flags -----------------------------------------------------------------

-- Everything below takes a cull box, the camera's own extents grown by a
-- margin, and skips what falls outside it. Drawing what nobody is looking at
-- is not merely wasted: it overflows the layer, and whichever strokes fall
-- past the cap that frame simply vanish. It read as hulls that changed shape
-- and energy bars that blinked empty, because a bar's backing is on the fill
-- layer and its level is on the glow one.


function M.flags(fill, glow, my_team, t)
    local wave = math.sin(t * 2.2) * 1.6
    for i = 0, sim.flag_count() - 1 do
        local x, y, team, carried = sim.flag_at(i)
        local col = (team == 255) and pal.INK
            or (team == my_team and pal.FRIEND or pal.ENEMY)
        local top = y - (carried and 26 or 13)
        local base = y + (carried and -10 or 6)
        glow:seg(x, base, x, top, 1.6, pal.a(col, 0.9))
        local pts = {x, top, x + 12 + wave, top + 4.5, x, top + 9}
        fill:fan(pts, pal.a(col, carried and 0.6 or 0.25))
        glow:outline(pts, 1.3, pal.a(col, carried and 1 or 0.7))
        glow:halo(x, top + 4, carried and 22 or 14, 10, pal.a(col, 0.13))
    end
end

-- --- events ----------------------------------------------------------------
--
-- The simulation reports what happened; this turns each report into light and
-- noise. Positions come from the event where the core carries one, because by
-- the time the client looks a dead weapon is already gone from the state.

-- The announcements that arrive as snapshot state changes rather than as
-- local events. Since decision 40 that is every remote death: prediction is
-- not allowed to conclude one, so net.lua finds them by diffing the world
-- across each snapshot and queues them. Each draws exactly what the event
-- would have. See the comment on the queues in net.lua.
function M.corpse(i, vx, vy, me, sfx)
    local x, y = sim.ship_x(i), sim.ship_y(i)
    local col = (sim.ship_team(i) == team_of(me)) and pal.FRIEND
        or pal.ENEMY
    fx.destroy(x, y, vx, vy, col)
    sfx("death", x, y)
end

function M.late_blast(w, sfx)
    local r = spec_blast(w.spec)
    fx.detonate(w.x, w.y, r, bomb_col(spec_level(w.spec)))
    sfx("blast", w.x, w.y, blast_rung(r))
end

function M.events(me, sfx)
    for i = 0, sim.event_count() - 1 do
        local ty, a, b, v = sim.event_at(i)
        if ty == sim.EV_FIRE then
            local x, y = sim.ship_x(a), sim.ship_y(a)
            local ang = sim.ship_heading(a) / 65536 * TAU
            local bomb = spec_blast(b) > 0
            local col = bomb and pal.BOMB
                or (sim.ship_team(a) == team_of(me) and pal.FRIEND or pal.ENEMY)
            local mx, my = x + math.sin(ang) * 10, y - math.cos(ang) * 10
            fx.cone(mx, my, ang, bomb and 0.9 or 0.35, bomb and 7 or 3,
                    bomb and 120 or 190, 0.14, bomb and 2.2 or 1.4, col)
            -- The flash itself. The cone was the whole muzzle before this,
            -- and a spray of three sparks is the smoke rather than the shot:
            -- at the moment of firing there was nothing bright at the barrel
            -- at all, which is why the guns read as quiet.
            fx.flash(mx, my, bomb and 26 or 15, bomb and 0.13 or 0.1,
                     bomb and 0.7 or 0.5, pal.hot(col, 0.55, 1),
                     bomb and 0.75 or 0.5)
            -- Which rung fired it. Read off the ship rather than off the
            -- weapon, because a spec carries what it does and not the rung it
            -- came from, and this is the tick that fired so the two cannot
            -- have drifted apart yet. Clamping to what the kit actually holds
            -- is sfx's job, not this one's.
            local trig = bomb and sim.TRIG_BOMB or sim.TRIG_GUN
            sfx(bomb and "bomb" or "gun", x, y, sim.ship_level(a, trig))
        elseif ty == sim.EV_EXPIRE then
            -- The payload is two fourteen-bit coordinates.
            local x = math.floor(v / 16384) % 16384
            local y = v % 16384
            -- Pinned to the hull it ended on, when it ended on one. The event
            -- position is simulation truth, but a remote hull is drawn where
            -- the render smoothing says, up to a correction behind the truth,
            -- and a detonation centered beside the ship it plainly just hit is
            -- the game telling the shooter their shot missed. Moving the ring
            -- by the same offset the hull is drawn under keeps the two
            -- together; the offset dies away in a tenth of a second anyway.
            -- A dead victim's offset is already zero, so the anchor degrades
            -- to a no-op on a kill shot, where the death burst is drawn at
            -- the hull anyway.
            if b < sim.ship_count() then
                x = x + (sim.ship_x(b) - sim.ship_x_raw(b))
                y = y + (sim.ship_y(b) - sim.ship_y_raw(b))
            end
            local r = spec_blast(a)
            local lvl = spec_level(a)
            if r > 0 then
                fx.detonate(x, y, r, bomb_col(lvl))
                sfx("blast", x, y, blast_rung(r))
            else
                -- A round that ends without a blast ended on something: a
                -- wall, a rock, a hull. Four sparks was the whole picture,
                -- which reads as the round being absorbed rather than
                -- stopping against anything. The mark is white-hot and
                -- deliberately colorless: where a shot landed is a fact
                -- about the terrain, and painting it in the shooter's team
                -- color would put a friend-or-foe read on a wall.
                fx.burst(x, y, 4, 90, 0.22, 1.5, pal.a(pal.INK, 0.9))
                fx.flash(x, y, 13, 0.16, 0.55, pal.hot(pal.INK, 0.4, 1), 0.4)
            end
        elseif ty == sim.EV_HIT then
            local x, y = sim.ship_x(a), sim.ship_y(a)
            local col = (sim.ship_team(a) == team_of(me)) and pal.FRIEND or pal.ENEMY
            fx.burst(x, y, 5, 130, 0.26, 1.8, pal.hot(col, 0.6, 1))
            fx.flash(x, y, 20, 0.12, 0.5, pal.hot(col, 0.7, 1), 0.45)
            M.note_hit(a)
            -- The screen shakes by what it cost you, not by what hit you.
            -- A blast falls off linearly from its center, so the damage is
            -- already a measure of how close you were standing to it: a bomb
            -- in the face rattles the camera ten pixels, the edge of the same
            -- blast barely a pixel, and a bullet sits between them where it
            -- belongs. It was a flat jolt for everything before, which made
            -- taking two thirds of a bar feel like being scratched.
            if a == me then
                local frac = v / math.max(1, sim.ship_max_energy(a))
                if frac > 1 then frac = 1 end
                fx.jolt(0.18 + frac * 1.25)
            end
            sfx("hit", x, y)
        elseif ty == sim.EV_DEATH then
            -- The predicted pilot's own death, and since decision 40 only
            -- theirs: every other death arrives as a snapshot change and is
            -- drawn by M.corpse.
            local x, y = sim.ship_x(a), sim.ship_y(a)
            local vx, vy = sim.ship_vel(a)
            local col = (sim.ship_team(a) == team_of(me)) and pal.FRIEND or pal.ENEMY
            fx.destroy(x, y, vx, vy, col)
            sfx("death", x, y)
        elseif ty == sim.EV_SPAWN then
            local x, y = sim.ship_x(a), sim.ship_y(a)
            fx.wave(x, y, 46, 5, 0.4, 4, pal.a(pal.FRIEND, 0.9))
            sfx("spawn", x, y)
        elseif ty == sim.EV_BOUNCE then
            -- A ship off a wall, and only a ship. A weapon coming off one is
            -- SIM_EV_RICOCHET and is deliberately not handled: a bouncing
            -- bullet is silent, decided rather than overlooked.
            --
            -- The two used to share this event, and reading one as the other
            -- is what made a ricochet thump: v is an impact here and a packed
            -- position there, and a position clears this gate almost always,
            -- so every bounce anywhere on the map put a wall hit on the
            -- shooter's own hull.
            local x, y = sim.ship_x(a), sim.ship_y(a)
            if v > 40000 then
                fx.burst(x, y, 3, 70, 0.2, 1.2, pal.a(pal.WALL_EDGE, 1))
                sfx("bounce", x, y)
            end
        elseif ty == sim.EV_CHARGE then
            -- Spending one is a small flare at the hull rather than a shot
            -- effect: the weapon it made draws itself, and what wants
            -- reporting here is that the inventory went down by one.
            local x, y = sim.ship_x(a), sim.ship_y(a)
            fx.wave(x, y, 5, 30, 0.3, 4, pal.CHARGE_COL)
            sfx("charge", x, y)
        elseif ty == sim.EV_FLAG_TAKE then
            local x, y = sim.ship_x(a), sim.ship_y(a)
            local col = (sim.ship_team(a) == team_of(me)) and pal.FRIEND or pal.ENEMY
            fx.wave(x, y, 6, 30, 0.45, 5, pal.a(col, 0.55))
            fx.burst(x, y, 5, 55, 0.4, 1.4, pal.a(col, 0.8))
            sfx("flag", x, y)
        end
    end
end

return M
