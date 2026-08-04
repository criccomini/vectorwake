-- Drawing the world.
--
-- Ships, weapons, flags, prizes, stars and terrain, in the two world layers:
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
-- colour carries team, so neither has to carry both, and every class has to be
-- identifiable by silhouette alone at radar scale, which means each one needs
-- a front that is visibly not its back. See docs/design/ships.md.
--
-- `poly` is that silhouette, and it is the only part the menu's thumbnails
-- draw. The rest is what a hull looks like once it is close enough to matter:
-- `plates` are closed interior loops, `lines` open polylines, `canopy` the one
-- bright cell every hull carries forward of centre, `tubes` the hardpoints a
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
     jets = {-1.8,-11, 1.8,-11}},
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
     jets = {-5.6,-12, 5.6,-12}},
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
     jets = {-8.5,-2.2, 8.5,-2.2}},
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
     jets = {-9,-10.6, -3.5,-12, 3.5,-12, 9,-10.6}},
    -- Spire: the mast is the point of it. A lamp on top, docking pylons for
    -- turrets on the flanks, and the thing a team flies toward.
    {poly = {0,23, 1.2,17, 2.6,11, 6,2, 6.6,-4, 3.6,-11, 2.6,-13, 0,-13,
             -2.6,-13, -3.6,-11, -6.6,-4, -6,2, -2.6,11, -1.2,17},
     plates = {{0,9.5, 3.6,3.5, 3.2,-5, 0,-7.5, -3.2,-5, -3.6,3.5},
               {6.2,3.5, 10.8,2.6, 11.6,-0.6, 6.6,-1.6},
               {-6.6,-1.6, -11.6,-0.6, -10.8,2.6, -6.2,3.5}},
     lines = {{2.6,11, 6,2}, {-2.6,11, -6,2}, {4.4,-6.4, 2,-11.4},
              {-4.4,-6.4, -2,-11.4}, {0,22, 0,16.5}},
     canopy = {0,15.5, 1.6,12.2, 0,10.4, -1.6,12.2},
     pods = {{0, 22.6, 2.6}, {10.2, 1, 1.6}, {-10.2, 1, 1.6}},
     jets = {-1.6,-12.8, 1.6,-12.8}},
    -- Cipher: a knife. Draws dimmer than the rest of the roster on purpose,
    -- since the class is meant to be hard to pick out of a fight.
    {poly = {0,23, 1.7,7, 3.4,-2, 3,-9, 6.5,-12.5, 2.2,-11.5, 1.6,-13, 0,-13,
             -1.6,-13, -2.2,-11.5, -6.5,-12.5, -3,-9, -3.4,-2, -1.7,7},
     plates = {{0,19, 1.4,4, 0,-6, -1.4,4}},
     lines = {{0,22.4, 3.2,-2}, {0,22.4, -3.2,-2}, {3.2,-9.4, 5.9,-12.2},
              {-3.2,-9.4, -5.9,-12.2}},
     canopy = {0,17.5, 0.9,14, 0,11.5, -0.9,14},
     jets = {0,-13}, dim = 0.72},
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
     jets = {-2.6,-13, 2.6,-13}},
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
     jets = {-1.8,-14, 1.8,-14}},
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

for _, h in ipairs(M.HULLS) do
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
    -- Halfway up the hull, which is where a thumbnail has to be centred: every
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
    -- depth, cell size in world px, star size, colour, how many cells in
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

function M.stars(fill, glow, cam_x, cam_y, hw, hh)
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
                            glow:halo(px + size / 2, py + size / 2, 5, 8, bloom)
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
-- instrument grey, and colour kept for the things that mean something.
--
-- All of it is built once into the static layers when the camera leaves its
-- window, so detail here is close to free. Only the doors and the wells are
-- drawn per frame, and they are drawn per frame because they move.

-- What a solid tile's variant says it is. Ordinary wall and border are drawn
-- as one mass; the rest are objects that happen to be solid, and each names
-- its own top-left corner, so a six-tile station is drawn once rather than
-- thirty-six times. See sim/tools/lvl2vw.c, which writes these.
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
    local ax, ay = 0, 0                 -- toward the neighbour being tested
    local px, py = 0, 0                 -- toward the previous tile in a run
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
    local tick = pal.a(lit, 0.42)
    local edge2 = pal.a(lit, 0.5)
    local inner = pal.a(pal.WALL_LIT, 1)
    local outer = pal.a(lit, 1)

    for i = 1, #cells, 2 do
        bg:rect(cells[i] * TILE, cells[i + 1] * TILE, TILE, TILE, pal.WALL)
    end

    -- Structure inside a mass, so a big block is not a void. Only where every
    -- neighbour is solid, and only on a three-tile pitch: bordering every tile
    -- turns a wall into graph paper, which this client has already done once.
    if not border then
        local seam = pal.a(lit, 0.18)
        for i = 1, #cells, 2 do
            local tx, ty = cells[i], cells[i + 1]
            if set[key(tx, ty - 1)] and set[key(tx, ty + 1)]
               and set[key(tx - 1, ty)] and set[key(tx + 1, ty)] then
                local x, y = tx * TILE, ty * TILE
                if tx % 3 == 0 then glow:seg(x, y, x, y + TILE, 0.7, seam) end
                if ty % 3 == 0 then glow:seg(x, y, x + TILE, y, 0.7, seam) end
            end
        end
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
                -- The map's own edge, said twice, with a tick every ten
                -- pixels: a boundary that is never going to open.
                glow:seg(px - ox * 3, py - oy * 3, qx - ox * 3, qy - oy * 3,
                         0.8, edge2)
                local len = math.abs(qx - px) + math.abs(qy - py)
                local n = math.max(1, math.floor(len / 32))
                local ux, uy = (qx - px) / n, (qy - py) / n
                for k = 1, n - 1 do
                    local mx, my = px + ux * k, py + uy * k
                    glow:seg(mx, my, mx - ox * 3, my - oy * 3, 0.7, tick)
                end
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

-- A safe zone: a marked floor rather than a coloured patch. A wash, a hatch
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

-- Rock. Faceted and grey on purpose: a hull is smooth, lit and coloured, and
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

local function rock_shape(seed, sides, r, craters)
    local k = seed .. ":" .. sides .. ":" .. r .. ":" .. craters
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
    local facets = {}
    local step = math.max(2, math.floor(sides / 3))
    for i = 0, sides - 1, step do
        local j = (i + math.floor(sides / 2)) % sides
        facets[#facets + 1] = {pts[i * 2 + 1], pts[i * 2 + 2],
                               (pts[i * 2 + 1] + pts[j * 2 + 1]) / 3,
                               (pts[i * 2 + 2] + pts[j * 2 + 2]) / 3}
    end
    local pits = {}
    for _ = 1, craters do
        local a, d = rnd() * TAU, (0.25 + rnd() * 0.35) * r
        pits[#pits + 1] = {math.cos(a) * d, math.sin(a) * d,
                           r * (0.16 + rnd() * 0.12)}
    end
    -- How it turns, out of the same seed: a rate, a direction, and a phase, so
    -- a field of rocks is a field of rocks rather than a rank of them turning
    -- in step. Slowest is a full revolution in about two minutes and fastest
    -- in about forty seconds, which reads as adrift rather than as machinery.
    local q = (seed % 97) / 97
    s = {pts = pts, nrm = nrm, facets = facets, pits = pits, sides = sides,
         rate = ((seed % 2 == 0) and 1 or -1) * (0.05 + q * 0.11),
         wob = 0.06 + q * 0.05,
         phase = q * TAU,
         tmp = {}, ntmp = {}}
    rock_shapes[k] = s
    return s
end

-- One asteroid, turned to where it is this frame.
local function draw_rock(fill, glow, cx, cy, s, now)
    local ang = now * s.rate
    -- A rock is not a wheel. The long axis is squeezed a little on a slower
    -- cycle than the spin, which is what an irregular body tumbling in three
    -- dimensions does to its own silhouette; kept under a tenth so it reads as
    -- depth rather than as something soft being pressed.
    local squash = 1 - s.wob * (0.5 + 0.5 * math.cos(now * 0.31 + s.phase))
    local ca, sa = math.cos(ang), math.sin(ang)
    local src, pts, nrm = s.pts, s.tmp, s.ntmp
    local sn = s.nrm
    for i = 1, #src, 2 do
        local px, py = src[i] * squash, src[i + 1]
        pts[i] = cx + px * ca - py * sa
        pts[i + 1] = cy + px * sa + py * ca
        local nx, ny = sn[i], sn[i + 1]
        nrm[i] = nx * ca - ny * sa
        nrm[i + 1] = nx * sa + ny * ca
    end
    -- Fanned from the centre, not from a vertex: the outline is star-shaped
    -- about its own centre and nothing else, and a vertex fan on a shape with
    -- one notch in it paints outside the rock.
    local sides = s.sides
    local body = pal.a(pal.ROCK, 1)
    for i = 0, sides - 1 do
        local j = (i + 1) % sides
        fill:tri(cx, cy, pts[i * 2 + 1], pts[i * 2 + 2],
                 pts[j * 2 + 1], pts[j * 2 + 2], body)
    end
    glow:glow_band(pts, nrm, 5, 0.12, pal.a(pal.ROCK_EDGE, 1))
    glow:outline(pts, 1.2, pal.a(pal.hot(pal.ROCK_EDGE, 0.15, 1), 0.8), true)
    local facet = pal.a(pal.ROCK_EDGE, 0.22)
    for k = 1, #s.facets do
        local f = s.facets[k]
        local ax, ay = f[1] * squash, f[2]
        local bx, by = f[3] * squash, f[4]
        glow:seg(cx + ax * ca - ay * sa, cy + ax * sa + ay * ca,
                 cx + bx * ca - by * sa, cy + bx * sa + by * ca, 0.7, facet)
    end
    -- Half a crater rim. The pit rides round with the rock; the lit side does
    -- not, because the light does not turn. Drawn as segments rather than
    -- through arc, which strokes hard quads: on something that is now moving,
    -- an eight-tenths-of-a-pixel hard edge is the flicker all over again.
    local rim = pal.a(pal.ROCK_EDGE, 0.38)
    for k = 1, #s.pits do
        local p = s.pits[k]
        local px, py = p[1] * squash, p[2]
        local wx, wy = cx + px * ca - py * sa, cy + px * sa + py * ca
        local rr = p[3]
        local a0, a1, n = -2.5, -0.4, 5
        local step2 = (a1 - a0) / n
        for j = 0, n - 1 do
            local b0, b1 = a0 + step2 * j, a0 + step2 * (j + 1)
            glow:seg(wx + math.cos(b0) * rr, wy + math.sin(b0) * rr,
                     wx + math.cos(b1) * rr, wy + math.sin(b1) * rr, 0.8, rim)
        end
    end
end

-- Six tiles square, and the one piece of terrain with room to spend: a
-- hexagonal core on four docking arms, windows, and a lit heart.
local function station(bg, glow, tx, ty)
    local cx, cy = (tx + 3) * TILE, (ty + 3) * TILE
    local R = 40
    local hex, hexn, inner = {}, {}, {}
    for i = 0, 5 do
        local a = i / 6 * TAU
        hex[i * 2 + 1] = cx + math.cos(a) * R
        hex[i * 2 + 2] = cy + math.sin(a) * R
        hexn[i * 2 + 1] = math.cos(a)
        hexn[i * 2 + 2] = math.sin(a)
        inner[i * 2 + 1] = cx + math.cos(a) * (R - 7)
        inner[i * 2 + 2] = cy + math.sin(a) * (R - 7)
    end
    local edge = pal.a(pal.WALL_EDGE, 0.75)
    local lit = pal.a(pal.hot(pal.WALL_EDGE, 0.5, 1), 0.85)
    for i = 0, 3 do
        local a = i / 4 * TAU + TAU / 8
        local ca, sa = math.cos(a), math.sin(a)
        local nx, ny = -sa, ca
        local arm = {cx + ca * 22 + nx * 7, cy + sa * 22 + ny * 7,
                     cx + ca * 46 + nx * 5, cy + sa * 46 + ny * 5,
                     cx + ca * 46 - nx * 5, cy + sa * 46 - ny * 5,
                     cx + ca * 22 - nx * 7, cy + sa * 22 - ny * 7}
        bg:fan(arm, pal.WALL)
        glow:outline(arm, 1.1, edge, true)
        glow:seg(cx + ca * 44 + nx * 6, cy + sa * 44 + ny * 6,
                 cx + ca * 44 - nx * 6, cy + sa * 44 - ny * 6, 2.2, lit)
    end
    bg:fan(hex, pal.WALL)
    glow:glow_band(hex, hexn, 9, 0.10, pal.a(pal.WALL_LIT, 1))
    glow:glow_band(hex, hexn, 3, 0.22, pal.a(pal.WALL_LIT, 1))
    glow:outline(hex, 1.5, pal.a(pal.hot(pal.WALL_EDGE, 0.5, 1), 1), true)
    local ink = pal.a(pal.PANEL_INK, 0.28)
    glow:outline(inner, 0.8, ink, true)
    for i = 0, 5 do
        glow:seg(hex[i * 2 + 1], hex[i * 2 + 2],
                 inner[i * 2 + 1], inner[i * 2 + 2], 0.7, ink)
    end
    local win = pal.a(pal.FRIEND, 0.5)
    for _, i in ipairs({0, 2, 4}) do
        local j = (i + 1) % 6
        for k = 1, 4 do
            local t = k / 5
            glow:disc(inner[i * 2 + 1] + (inner[j * 2 + 1] - inner[i * 2 + 1]) * t,
                      inner[i * 2 + 2] + (inner[j * 2 + 2] - inner[i * 2 + 2]) * t,
                      1.1, 6, win)
        end
    end
    glow:ring(cx, cy, 11, 1.2, 16, pal.a(pal.PANEL_INK, 0.5))
    glow:halo(cx, cy, 16, 10, pal.a(pal.FRIEND, 0.22))
    glow:disc(cx, cy, 3.2, 8, pal.a(pal.hot(pal.FRIEND, 0.5, 1), 0.8))
end

-- Floor markings, beneath the ships and in instrument grey, so decoration is
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
    local safe_set, safe_cells = {}, {}
    local rocks, stations, unders = {}, {}, {}
    local turfs, spawns, goals = {}, {}, {}
    local my_team = M.my_team or 0

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
            elseif cls == sim.T_SPAWN then
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
                 s = rock_shape(60413 + tx * 7 + ty * 13, 11, 14.5, 2)}
        else
            e = {x = (tx + 0.5) * TILE, y = (ty + 0.5) * TILE,
                 s = rock_shape((var == V_ROCK_B and 977 or 12345)
                                + tx * 31 + ty * 17,
                                var == V_ROCK_B and 7 or 8, 7, 1)}
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
-- `RADAR_TILES + STATIC_STEP` from the build centre, and a window sized for
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
    local LAST = 1023
    local cx = (x0 + x1) / 2
    local cy = (y0 + y1) / 2
    if x0 < 0 then x0 = 0 end
    if y0 < 0 then y0 = 0 end
    if x1 > LAST then x1 = LAST end
    if y1 > LAST then y1 = LAST end

    -- The doors and wormholes, found once here rather than searched for on
    -- every frame that draws them. Over the radar's box rather than the
    -- mesh's: a door is drawn in the world *and* on the radar, and the radar
    -- sees further.
    local rx0 = math.max(0, math.floor(cx - RADAR_REACH))
    local ry0 = math.max(0, math.floor(cy - RADAR_REACH))
    local rx1 = math.min(LAST, math.floor(cx + RADAR_REACH))
    local ry1 = math.min(LAST, math.floor(cy + RADAR_REACH))
    index_moving(rx0, ry0, rx1, ry1)

    -- Every second tile, not every fourth. The arena's outer walls are two
    -- tiles thick, so a four-tile stride aliased them away completely and the
    -- map read as a scatter of unrelated dots.
    --
    -- Safe zones and doors get their own lists: they are the two things worth
    -- steering by, and they were not on the radar at all.
    local rt, rs, rd = {}, {}, {}
    for ty = ry0, ry1, 2 do
        for tx = rx0, rx1, 2 do
            local cls = sim.tile(tx, ty)
            local out = (cls == sim.T_SOLID and rt)
                or (cls == sim.T_SAFE and rs)
                or (cls == sim.T_DOOR and rd)
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

-- Made once, not per frame: these are constants wearing a function's clothes,
-- and allocating them in a draw loop is what a collector notices first.
-- A door reads in its own colour now rather than in the wall's, and shut and
-- open are different hues rather than two brightnesses of one. See pal.DOOR:
-- the band is nothing else's, so this costs no other reading.
local DOOR_LIT = pal.DOOR
local DOOR_SEAM = pal.a(pal.hot(pal.DOOR, 0.55, 1), 0.98)
local DOOR_SLAT = pal.a(DOOR_LIT, 0.42)
local DOOR_POST_SHUT = pal.a(DOOR_LIT, 0.95)
local DOOR_POST_OPEN = pal.a(pal.DOOR_OPEN, 0.7)
local DOOR_TICK_SHUT = pal.a(DOOR_LIT, 0.9)
local DOOR_TICK_OPEN = pal.a(pal.DOOR_OPEN, 0.6)
local DOOR_MARK = pal.a(pal.DOOR_OPEN, 0.8)
local DOOR_SILL = pal.a(pal.DOOR_OPEN, 0.28)
-- The rings are a function of the clock now, so their colours are made per
-- frame rather than held here. The arms still are: their fade is by depth
-- rather than by time.
local HOLE_ARM = {}
for k = 1, 5 do HOLE_ARM[k] = pal.a(pal.HOLE, 0.34 - (k - 1) * 0.05) end

-- One door, however many tiles it spans.
--
-- A door has a colour of its own, and the rule it used to follow said it could
-- not. That rule was about not borrowing: colour belongs to teams and to weapon
-- classes, and a door wearing cyan or pink is a door somebody misreads under
-- fire. Green borrows from neither, so the door keeps its shape and its motion
-- and gains a hue, and shut and open now differ in colour rather than only in
-- brightness. Which of the four clocks it is on is still a count of ticks on
-- its posts.
--
-- A run is framed once. Framed per tile, a four-tile gateway reads as four
-- separate shutters, which is four wrong answers to "can I fit through that".
local function door_run(fill, glow, x0, y0, x1, y1, vertical, group, shut)
    if shut then
        fill:rect(x0, y0, x1 - x0, y1 - y0, pal.WALL)
        -- Ribs every two tiles. Pitched off the door's thickness instead,
        -- a fifteen-tile gateway gets sixty of them and reads as a comb.
        local span = vertical and (y1 - y0) or (x1 - x0)
        local n = math.max(2, math.floor(span / 32))
        for k = 1, n - 1 do
            local t = k / n
            if vertical then
                glow:seg(x0, y0 + span * t, x1, y0 + span * t, 0.8, DOOR_SLAT)
            else
                glow:seg(x0 + span * t, y0, x0 + span * t, y1, 0.8, DOOR_SLAT)
            end
        end
        local ax, ay, bx, by
        if vertical then
            ax, ay, bx, by = x0, (y0 + y1) / 2, x1, (y0 + y1) / 2
        else
            ax, ay, bx, by = (x0 + x1) / 2, y0, (x0 + x1) / 2, y1
        end
        -- The bar down the middle is what says "shut", so it carries the
        -- colour hardest: a wide soft glow under a bright thin line.
        glow:seg_glow(ax, ay, bx, by, 7, 0.20, pal.a(DOOR_LIT, 1))
        glow:seg(ax, ay, bx, by, 1.3, DOOR_SEAM)
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
                -- A run of tiles across the screen is a door that slides up
                -- and down, so its slats lie along the run and its posts cap
                -- the ends.
                door_run(fill, glow, wx, wy, (ex + 1) * TILE, (ey + 1) * TILE,
                         not across, group, not sim.door_open(t.variant))
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
function M.ship(fill, glow, cls, x, y, heading, col, opts)
    local h = M.HULLS[cls + 1] or M.HULLS[1]
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
    -- Drawn in a neutral instrument grey rather than in the team colour: the
    -- team read belongs on the silhouette, and a hull whose every line is the
    -- same colour looks cut from one sheet of neon rather than built.
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
    -- inverse scale and a renormalise apiece, and what they aim is a soft
    -- skirt three to nine pixels deep: at the steepest bank the error is a
    -- few degrees on a gradient, which is nothing.
    local nrm = place_dir(h.nrm, h.ntmp, ca, sa)
    glow:glow_band(pts, nrm, 9.0, 0.105 * dim, col, h.wide)
    glow:glow_band(pts, nrm, 3.0, 0.32 * dim, col, h.band)
    local edge = pal.hot(col, mine and 0.62 or 0.34, 1)
    local n = #pts
    local e = 1
    for i = 1, n, 2 do
        local j = (i + 1 < n) and i + 2 or 1
        glow:seg(pts[i], pts[i + 1], pts[j], pts[j + 1], 1.5,
                 pal.a(edge, h.hot[e] * dim), true)
        e = e + 1
    end

    -- The canopy. Every hull has one, it is always the brightest closed shape
    -- on the ship, and it is always forward of centre, so "which end is the
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
end

-- The energy pip above a hull. Energy is health in this game -- it powers the
-- guns and it absorbs the damage -- so one bar says both things, and a
-- wounded enemy reads at a glance without a number anywhere near it.
--
-- World space, not screen: zoom is fixed at one, so twenty-two world pixels
-- are twenty-two screen pixels and the pip needs no projection of its own.
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

-- A spec id means whatever the current settings say it means, and a zone
-- sends its own -- so the answers cached here stop being true the moment a
-- settings message lands. Cheap to rebuild, wrong to keep.
function M.forget_specs()
    blast_of = {}
end

local function spec_blast(id)
    local r = blast_of[id]
    if r == nil then
        r = sim.spec_blast(id)
        blast_of[id] = r
    end
    return r
end

function M.weapons(fill, glow, me_team, t, cull)
    local pulse = 0.72 + 0.28 * math.sin(t * 11)
    for i = 0, sim.weapon_count() - 1 do
        local x, y, spec, vx, vy, team = sim.weapon_at(i)
        if outside(cull, x, y) then
            -- nothing: off screen
        elseif spec_blast(spec) > 0 then
            -- A bomb is a heavy, slow, obviously dangerous object: a hot core
            -- inside a ring that breathes, with a trail long enough to read
            -- its heading from across the arena.
            local col = pal.BOMB
            glow:seg_fade(x - vx * 7, y - vy * 7, x, y, 1.5, 5.5, 0, 0.55, col)
            glow:halo(x, y, 13 * pulse, 10, pal.a(col, 0.5))
            glow:ring(x, y, 4.6, 1.4, 10, pal.a(col, 0.95))
            fill:disc(x, y, 3.6, 8, pal.a(pal.hot(col, 0.8, 1), 0.9))
        else
            -- A bolt: a streak along its own velocity with a hot head. The
            -- streak is what makes a stream of fire read as a direction
            -- rather than as a scatter of dots, and it is the whole reason
            -- the core reports weapon velocity to the client at all.
            local col = (team == me_team) and pal.FRIEND or pal.ENEMY
            glow:seg_fade(x - vx * 14, y - vy * 14, x, y, 0.6, 4.5, 0, 0.30, col)
            glow:seg_fade(x - vx * 6, y - vy * 6, x, y, 0.8, 2.6, 0, 0.85, col)
            glow:seg_fade(x - vx * 2, y - vy * 2, x, y, 0.6, 1.6, 0, 1,
                          pal.hot(col, 0.9, 1))
            glow:halo(x, y, 7, 8, pal.a(col, 0.55))
        end
    end
end

-- --- prizes and flags ------------------------------------------------------

-- Everything below takes a cull box -- the camera's own extents, grown by a
-- margin -- and skips what falls outside it.
--
-- This was not needed when the arena was 84 tiles: everything in the world
-- was on screen or a few tiles off it. On a map a thousand tiles across, all
-- but a fraction of it is somewhere nobody is looking, and drawing it is not
-- merely wasted -- it *overflows the layer*. A hundred and fifty greens at a
-- ten segment halo each pinned the glow buffer at 8190 of 8192 and dropped a
-- million primitives a minute, which is not a slow frame but a wrong one:
-- whichever strokes fell past the cap that frame simply vanished. It read as
-- hulls that changed shape and energy bars that blinked empty, because a
-- bar's backing is on the fill layer and its level is on the glow one.
function M.prizes(fill, glow, t, cull)
    local spin = t * 1.1
    local ca, sa = math.cos(spin), math.sin(spin)
    local pulse = 0.78 + 0.22 * math.sin(t * 3.4)
    for i = 0, sim.prize_count() - 1 do
        local active, x, y, life = sim.prize_at(i)
        if active and not outside(cull, x, y) then
            -- Every green looks the same, because every green *is* the same:
            -- what it turns out to be is decided when somebody takes it, from
            -- what their hull can hold. Colouring them by kind would have been
            -- colouring them by a decision that has not been made yet.
            local col = pal.PRIZE
            -- A prize about to time out blinks, so a player can tell the
            -- difference between one worth crossing the arena for and one
            -- that will be gone before they arrive.
            local fade = (life < 120) and (0.35 + 0.65 * math.abs(math.sin(t * 9))) or 1
            local r = 6.5 * pulse
            local pts = {}
            for k = 0, 3 do
                local px = (k == 0 and 0) or (k == 1 and r) or (k == 2 and 0) or -r
                local py = (k == 0 and -r) or (k == 1 and 0) or (k == 2 and r) or 0
                pts[k * 2 + 1] = x + px * ca + py * sa
                pts[k * 2 + 2] = y + px * sa - py * ca
            end
            glow:halo(x, y, 15, 10, pal.a(col, 0.20 * fade))
            fill:fan(pts, pal.a(col, 0.28 * fade))
            glow:outline(pts, 1.4, pal.a(col, 0.95 * fade))
        end
    end
end

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

function M.events(me, sfx)
    for i = 0, sim.event_count() - 1 do
        local ty, a, b, v = sim.event_at(i)
        if ty == sim.EV_FIRE then
            local x, y = sim.ship_x(a), sim.ship_y(a)
            local ang = sim.ship_heading(a) / 65536 * TAU
            local bomb = spec_blast(b) > 0
            local col = bomb and pal.BOMB
                or (sim.ship_team(a) == sim.ship_team(me) and pal.FRIEND or pal.ENEMY)
            fx.cone(x + math.sin(ang) * 10, y - math.cos(ang) * 10, ang,
                    bomb and 0.9 or 0.35, bomb and 7 or 3,
                    bomb and 120 or 190, 0.14, bomb and 2.2 or 1.4, col)
            -- Which rung fired it. Read off the ship rather than off the
            -- weapon, because a spec carries what it does and not the rung it
            -- came from, and this is the tick that fired so the two cannot
            -- have drifted apart yet. Clamping to what the kit actually holds
            -- is sfx's job, not this one's.
            local trig = bomb and sim.TRIG_BOMB or sim.TRIG_GUN
            sfx(bomb and "bomb" or "gun", x, y, sim.ship_level(a, trig))
        elseif ty == sim.EV_EXPIRE then
            local x = math.floor(v / 16384)
            local y = v % 16384
            local r = spec_blast(a)
            if r > 0 then
                fx.detonate(x, y, r, pal.BOMB)
                sfx("blast", x, y)
            else
                fx.burst(x, y, 4, 90, 0.22, 1.5, pal.a(pal.INK, 0.9))
            end
        elseif ty == sim.EV_HIT then
            local x, y = sim.ship_x(a), sim.ship_y(a)
            local col = (sim.ship_team(a) == sim.ship_team(me)) and pal.FRIEND or pal.ENEMY
            fx.burst(x, y, 5, 130, 0.26, 1.8, pal.hot(col, 0.6, 1))
            -- The screen shakes by what it cost you, not by what hit you.
            -- A blast falls off linearly from its centre, so the damage is
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
            local x, y = sim.ship_x(a), sim.ship_y(a)
            local vx, vy = sim.ship_vel(a)
            local col = (sim.ship_team(a) == sim.ship_team(me)) and pal.FRIEND or pal.ENEMY
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
        elseif ty == sim.EV_PRIZE then
            -- v is +1 for an upgrade and -1 for rust. A green that took
            -- something has to look and sound like a loss, or the one
            -- mechanic that costs you anything is invisible.
            local x, y = sim.ship_x(a), sim.ship_y(a)
            local col = (v < 0) and pal.RUST or pal.prize(b)
            if v < 0 then
                fx.wave(x, y, 5, 22, 0.4, 3, col)
                fx.burst(x, y, 5, 40, 0.45, 1.2, col)
                sfx("rust", x, y)
            else
                fx.wave(x, y, 4, 26, 0.35, 3, col)
                fx.burst(x, y, 6, 60, 0.5, 1.4, col)
                sfx("prize", x, y)
            end
        elseif ty == sim.EV_FLAG_TAKE then
            local x, y = sim.ship_x(a), sim.ship_y(a)
            local col = (sim.ship_team(a) == sim.ship_team(me)) and pal.FRIEND or pal.ENEMY
            fx.wave(x, y, 6, 30, 0.45, 5, pal.a(col, 0.55))
            fx.burst(x, y, 5, 55, 0.4, 1.4, pal.a(col, 0.8))
            sfx("flag", x, y)
        end
    end
end

return M
