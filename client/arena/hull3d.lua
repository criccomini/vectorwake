-- The hulls, with a third dimension under them.
--
-- A hull is a deck over a keel. The deck is a crown lofted off the drawing in
-- world.lua: tall where the hull is wide, low where it is a wingtip or a nose,
-- because the height at a point is read off how far inside the outline that
-- point is. The keel is nearly flat, a plate about a quarter of the crown's
-- depth, and it is what keeps a banked ship telling you which face you are
-- looking at. Both are built here, once, at load.
--
-- Nothing in this file moves a vertex in x or y. The plan is the drawing, the
-- drawing is fitted to the box `sim/src/baseline.c` collides that class in,
-- and all seven of those boxes spend the same 625 square pixels. Height is the
-- only thing invented, which is what lets the whole roster grow a dimension
-- without any of them growing a hitbox. `client/tests/hull3d_test.lua` holds
-- that promise from this side and `hull_fit_test.lua` holds it from the other.
--
-- The camera looks straight down and stays there. There is no perspective
-- lean: a hull drawn a pixel off where the core collides it is the defect
-- hull_fit_test exists to prevent, and it would be worst at the edges of the
-- screen, which is where a wall usually is. So what a third dimension buys is
-- a faceted body and, when a pilot turns, a ship that rolls instead of a ship
-- that gets narrower. See arena.script's `ship_roll`, which has been working
-- that number out all along.

local M = {}

-- The vertical face at the outline itself, above and below the plane. Small,
-- and it is what gives a rolled hull a flank to show rather than an edge.
M.EDGE = 0.62

-- How much of the crown the keel takes. Nearly flat on purpose: two matched
-- faces make every class read the same from either side, which is the
-- opposite of what a top-down game wants.
M.BELLY = 0.12

-- How far in the deck ring sits as a fraction of how far that vertex can
-- travel before leaving its own hull, and how deep the height under it is read
-- from. Different numbers on purpose: put the ring where its height comes from
-- and a round hull turns into a wheel of eighteen spokes.
M.INSET = 0.34
M.CROWN_AT = 0.80

-- How tall a hull stands, off its own plan, and the ceiling on that. A dart as
-- tall as it is wide is a missile; a slab that is flat is a decal.
M.CROWN = 0.235
M.CROWN_MAX = 5.0

-- --- polygons --------------------------------------------------------------

-- Twice the signed area, whose sign is the winding.
function M.turn(p)
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
-- centroid can see all of it. Every hull that shipped before that was
-- star-shaped like that, and that is exactly why none of them had a notch: the
-- Apex's wings could not clear its engine block without the fill spilling into
-- the gap between them. Run once, at load, so a frame pays nothing for it.
function M.triangulate(p)
    local n = #p / 2
    local idx = {}
    for i = 1, n do idx[i] = (M.turn(p) > 0) and i or (n + 1 - i) end

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

-- Is this point inside the outline? Ray crossing, and the only place the
-- reflex vertices of a hull like the Apex are asked about directly.
local function inside_poly(p, x, y)
    local n, c = #p / 2, false
    local j = n
    for i = 1, n do
        local yi, yj = p[i * 2], p[j * 2]
        if (yi > y) ~= (yj > y) then
            local t = (y - yi) / (yj - yi)
            if x < p[i * 2 - 1] + t * (p[j * 2 - 1] - p[i * 2 - 1]) then
                c = not c
            end
        end
        j = i
    end
    return c
end

local function seg_dist(px, py, ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local l2 = dx * dx + dy * dy
    local t = l2 > 1e-12 and ((px - ax) * dx + (py - ay) * dy) / l2 or 0
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    local qx, qy = ax + dx * t, ay + dy * t
    return math.sqrt((px - qx) * (px - qx) + (py - qy) * (py - qy))
end

-- How far inside the outline a point is: the distance to the nearest edge.
local function depth_at(p, x, y)
    local n, best = #p / 2, math.huge
    for i = 1, n do
        local j = i % n + 1
        local d = seg_dist(x, y, p[i * 2 - 1], p[i * 2],
                           p[j * 2 - 1], p[j * 2])
        if d < best then best = d end
    end
    return best
end

-- Do two segments cross? Proper intersections only: touching at a shared end
-- is what every neighbouring pair of edges does.
local function crosses(ax, ay, bx, by, cx, cy, dx, dy)
    local function side(px, py, qx, qy, rx, ry)
        local v = (qx - px) * (ry - py) - (rx - px) * (qy - py)
        if v > 1e-9 then return 1 elseif v < -1e-9 then return -1 end
        return 0
    end
    return side(ax, ay, bx, by, cx, cy) * side(ax, ay, bx, by, dx, dy) < 0
       and side(cx, cy, dx, dy, ax, ay) * side(cx, cy, dx, dy, bx, by) < 0
end

-- The deepest point in the outline, roughly: the hull's inradius. Everything
-- about the third dimension is a fraction of this, so it is worked out first
-- and on its own. A coarse sweep and one refinement, which is plenty for a
-- number that decides a crown height.
local function inradius(p)
    local lo_x, hi_x, lo_y, hi_y = math.huge, -math.huge, math.huge, -math.huge
    for i = 1, #p, 2 do
        if p[i] < lo_x then lo_x = p[i] end
        if p[i] > hi_x then hi_x = p[i] end
        if p[i + 1] < lo_y then lo_y = p[i + 1] end
        if p[i + 1] > hi_y then hi_y = p[i + 1] end
    end
    local best, bx, by = 1e-4, 0, 0
    local function sweep(x0, y0, x1, y1, steps)
        for j = 0, steps do
            for i = 0, steps do
                local x = x0 + (x1 - x0) * i / steps
                local y = y0 + (y1 - y0) * j / steps
                if inside_poly(p, x, y) then
                    local d = depth_at(p, x, y)
                    if d > best then best, bx, by = d, x, y end
                end
            end
        end
    end
    sweep(lo_x, lo_y, hi_x, hi_y, 20)
    local r = math.max(hi_x - lo_x, hi_y - lo_y) / 20
    sweep(bx - r, by - r, bx + r, by + r, 6)
    return best
end

-- How far vertex `v` can travel along its inward bisector before it leaves its
-- own hull. Solved against every edge that does not touch it rather than
-- marched, since a march is a hundred inside tests per vertex and this is one
-- line intersection each.
--
-- At a notch the bisector points outward and the vertex goes nowhere, which is
-- the right answer and the one a naive inset gets wrong: it folds the polygon
-- through itself.
local function reach_of(p, v, mx, my)
    local n = #p / 2
    local px, py = p[v * 2 - 1], p[v * 2]
    local best = math.huge
    if not inside_poly(p, px + mx * 0.02, py + my * 0.02) then return 0 end
    for i = 1, n do
        local j = i % n + 1
        if i ~= v and j ~= v then
            local ax, ay = p[i * 2 - 1], p[i * 2]
            local bx, by = p[j * 2 - 1], p[j * 2]
            local ex, ey = bx - ax, by - ay
            local den = mx * ey - my * ex
            if math.abs(den) > 1e-9 then
                local t = ((ax - px) * ey - (ay - py) * ex) / den
                local u = ((ax - px) * my - (ay - py) * mx) / den
                if t > 1e-6 and u >= 0 and u <= 1 and t < best then best = t end
            end
        end
    end
    return best < math.huge and best * 0.98 or 0
end

-- How brightly a face draws, on the light world.lua fixes to the hull's own
-- nose. Fixed to the world instead, the same ship would look like a different
-- ship depending on which way it was pointing, and the silhouette is the whole
-- identity system. In two dimensions the input is an edge's outward normal; in
-- three it is that normal with the crown's slope in it.
local function nose_light(ny, nz)
    return 0.40 + 0.60 * (0.5 + 0.5 * (ny * 0.82 + nz * 0.18))
end

-- --- building --------------------------------------------------------------

-- Give one hull its mesh. `h` is a refitted entry of world.HULLS, so its poly
-- already sits inside the class's collision box and nothing here moves it.
function M.build(h)
    local p = h.poly
    local n = #p / 2
    local lo_x, hi_x, lo_y, hi_y = math.huge, -math.huge, math.huge, -math.huge
    for i = 1, n do
        local x, y = p[i * 2 - 1], p[i * 2]
        if x < lo_x then lo_x = x end
        if x > hi_x then hi_x = x end
        if y < lo_y then lo_y = y end
        if y > hi_y then hi_y = y end
    end
    local cap = M.CROWN * math.min(hi_x - lo_x, hi_y - lo_y)
    if cap > M.CROWN_MAX then cap = M.CROWN_MAX end
    local dmax = inradius(p)

    -- The inward bisector at every vertex, and how far it may go. Which way
    -- is inward follows the polygon's own winding, read once.
    local wind = (M.turn(p) > 0) and 1 or -1
    local bx, by, reach = {}, {}, {}
    for v = 1, n do
        local u = (v - 2) % n + 1
        local w = v % n + 1
        local ax = p[v * 2 - 1] - p[u * 2 - 1]
        local ay = p[v * 2] - p[u * 2]
        local ex = p[w * 2 - 1] - p[v * 2 - 1]
        local ey = p[w * 2] - p[v * 2]
        local la = math.sqrt(ax * ax + ay * ay)
        local lb = math.sqrt(ex * ex + ey * ey)
        if la < 1e-6 then la = 1 end
        if lb < 1e-6 then lb = 1 end
        local mx = (-ay / la + -ey / lb) * wind
        local my = (ax / la + ex / lb) * wind
        local ml = math.sqrt(mx * mx + my * my)
        if ml < 1e-6 then mx, my, ml = 0, 0, 1 end
        bx[v], by[v] = mx / ml, my / ml
        -- How far in this vertex may come, capped against the hull's own
        -- inradius. Uncapped it is the whole chord to the far side, and on a
        -- broad hull that carries the ring across the spine and past its own
        -- mirror: the Wedge's came back tangled, its ears added up to seven
        -- times the area it enclosed, and the deck had two holes in it.
        local t = reach_of(p, v, bx[v], by[v])
        reach[v] = math.min(t, 2.2 * dmax)
    end

    -- Each vertex paired with the one whose plan is its mirror.
    --
    -- Every hull in world.lua is drawn symmetric about its own spine, and none
    -- of the arithmetic below is: the corridor march samples, and the fold
    -- relaxation shrinks whichever pair it happened to catch. Both walk the
    -- two halves apart, and the Anvil's came out two and a half pixels out of
    -- true, which reads as a ship built wrong rather than a ship drawn wrong.
    -- Pairing them and taking the tighter of the two keeps the drawing the
    -- shape the art is. A hull whose plan is not symmetric pairs with itself
    -- and none of this does anything to it.
    local mate = {}
    for v = 1, n do
        local best, bd = v, 1e-6
        for j = 1, n do
            local dx = p[j * 2 - 1] + p[v * 2 - 1]
            local dy = p[j * 2] - p[v * 2]
            local d = dx * dx + dy * dy
            if d < bd then best, bd = j, d end
        end
        mate[v] = best
    end
    local function pair(t)
        for v = 1, n do
            local w = mate[v]
            local m = math.min(t[v], t[w])
            t[v], t[w] = m, m
        end
    end
    for v = 1, n do
        local w = mate[v]
        bx[v], by[v] = (bx[v] - bx[w]) * 0.5, (by[v] + by[w]) * 0.5
        bx[w], by[w] = -bx[v], by[v]
    end
    pair(reach)

    -- Which way round the outline runs. world.lua draws its hulls clockwise;
    -- `triangulate` hands its caps back counter-clockwise whatever it is
    -- given. Built off the raw order the two disagree, every band faces into
    -- the ship, the cull drops all of them, and a hull is two caps and a hole.
    local function nxt(v)
        if wind > 0 then return v % n + 1 end
        return (v - 2) % n + 1
    end

    -- How far each vertex actually travels, after any fold has been undone.
    --
    -- Each one is given its own corridor, and where two neighbours' corridors
    -- differ sharply the deck ring can cross itself between them. The band
    -- built on that pair then winds backwards, faces into the ship, is culled
    -- with the rest of the far side, and leaves a slot of bare starfield
    -- through the middle of the hull. The Anvil did exactly that at half a
    -- bank, and it is invisible in a still of a level ship.
    --
    -- The test is each band triangle's own plan area, signed: wound outward it
    -- is positive, and a fold is the moment it stops being. Per triangle
    -- rather than per quad, because a quad that has folded along one diagonal
    -- still sums to the right sign. Pulling the pair back fixes it, and it
    -- settles in a few passes. A triangle with no plan area left to speak of
    -- is a vertex that could not move at all, which is what a notch does, and
    -- it covers nothing either way.
    local fac = {}
    for v = 1, n do fac[v] = M.INSET end
    local function ring_at(v)
        return p[v * 2 - 1] + bx[v] * reach[v] * fac[v],
               p[v * 2] + by[v] * reach[v] * fac[v]
    end
    local cap_tris
    for _ = 1, 24 do
        local folded = false
        for v = 1, n do
            local w = nxt(v)
            local ax, ay = p[v * 2 - 1], p[v * 2]
            local px2, py2 = p[w * 2 - 1], p[w * 2]
            local cx2, cy2 = ring_at(w)
            local dx3, dy3 = ring_at(v)
            local t1 = (px2 - ax) * (cy2 - ay) - (cx2 - ax) * (py2 - ay)
            local t2 = (cx2 - ax) * (dy3 - ay) - (dx3 - ax) * (cy2 - ay)
            if (t1 < -1e-9 and math.abs(t1) > 1e-6)
                or (t2 < -1e-9 and math.abs(t2) > 1e-6) then
                folded = true
                fac[v] = fac[v] * 0.7
                fac[w] = fac[w] * 0.7
            end
        end
        if folded then pair(fac) end
        -- The ring itself has to be simple, and neither the band test nor the
        -- ear count reliably says so: a ring that crosses itself can still cut
        -- ears that are all wound correctly and add up to more area than it
        -- encloses. This asks the question directly.
        if not folded then
            for a = 1, n do
                local a2 = nxt(a)
                local ax, ay = ring_at(a)
                local bx2, by2 = ring_at(a2)
                for b = 1, n do
                    local b2 = nxt(b)
                    if b ~= a and b ~= a2 and b2 ~= a then
                        local cx2, cy2 = ring_at(b)
                        local dx3, dy3 = ring_at(b2)
                        if crosses(ax, ay, bx2, by2, cx2, cy2, dx3, dy3) then
                            folded = true
                            break
                        end
                    end
                end
                if folded then break end
            end
            if folded then
                for v = 1, n do fac[v] = fac[v] * 0.7 end
            end
        end
        if not folded then
            -- The bands are straight and the ring is simple.
            -- Ear clipping cuts counter-clockwise ears whatever winding it is
            -- handed, so a ring that crosses itself somewhere the bands cannot
            -- see comes back with an ear cut the wrong way round: on the
            -- Cipher, whose waist is two pixels wide, that was a thirteen
            -- square pixel triangle of deck facing into the ship.
            local ring = {}
            for v = 1, n do ring[v * 2 - 1], ring[v * 2] = ring_at(v) end
            cap_tris = M.triangulate(ring)
            local ok, sum = true, 0
            for i = 1, #cap_tris, 3 do
                local a, b, c = cap_tris[i], cap_tris[i + 1], cap_tris[i + 2]
                local area = (ring[b * 2 - 1] - ring[a * 2 - 1]) * (ring[c * 2] - ring[a * 2])
                           - (ring[c * 2 - 1] - ring[a * 2 - 1]) * (ring[b * 2] - ring[a * 2])
                if area < -1e-9 then ok = false break end
                sum = sum + area
            end
            -- And the ears have to add up to the ring. Ear clipping gives up
            -- when it cannot find one, and it gives up quietly: the triangles
            -- it did cut are all wound correctly and a piece of the deck is
            -- simply missing, which on the Apex was a two pixel hole at each
            -- wing root that only a coverage scan finds.
            if ok and sum + 1e-6 < math.abs(M.turn(ring)) then ok = false end
            if ok then break end
            for v = 1, n do fac[v] = fac[v] * 0.7 end
        end
    end

    local ix, iy, dx2, dy2 = {}, {}, {}, {}
    for v = 1, n do
        ix[v], iy[v] = ring_at(v)
        dx2[v] = p[v * 2 - 1] + bx[v] * reach[v] * M.CROWN_AT
        dy2[v] = p[v * 2] + by[v] * reach[v] * M.CROWN_AT
    end

    -- The deck height under each ring vertex. A roof is never taller than the
    -- room it stands on, which is the second clamp: without it the Apex's neck
    -- and the Lattice's arms come out as fins, three pixels wide and five
    -- tall, a shape the plan view never promised.
    local deck = {}
    for v = 1, n do
        local d = inside_poly(p, dx2[v], dy2[v]) and depth_at(p, dx2[v], dy2[v]) or 0
        local z = 0
        if d > 0 then
            z = cap * (d / dmax) ^ 0.62
            if z > 0.85 * d then z = 0.85 * d end
        end
        deck[v] = M.EDGE + z
    end

    -- Four rings: the waterline above and below the plane, the deck, and the
    -- keel. Vertex v of ring r is at (r - 1) * n + v.
    local vx, vy, vz = {}, {}, {}
    local function put(i, x, y, z) vx[i], vy[i], vz[i] = x, y, z end
    for v = 1, n do
        put(v, p[v * 2 - 1], p[v * 2], M.EDGE)
        put(n + v, p[v * 2 - 1], p[v * 2], -M.EDGE)
        put(2 * n + v, ix[v], iy[v], deck[v])
        put(3 * n + v, ix[v], iy[v], -(M.EDGE + (deck[v] - M.EDGE) * M.BELLY))
    end

    local fa, fb, fc = {}, {}, {}
    local fn = 0
    local function face(a, b, c)
        fn = fn + 1
        fa[fn], fb[fn], fc[fn] = a, b, c
    end
    local function quad(a, b, c, d) face(a, b, c) face(a, c, d) end

    -- The caps come from the guard above, ear clipped rather than fanned: the
    -- Chord is a crescent and a fan from its centroid leaves the hull.
    --
    -- The order faces are built in is the order they are drawn in, and the
    -- layer has no depth buffer, so it is the order that decides what wins.
    --
    -- Lowest first. Rolled far enough, the flank the bank lifts shows its keel
    -- band and its deck band at the same drawn x, a sliver a third of a pixel
    -- wide where the two genuinely overlap, and the deck has to be the one on
    -- top. Everything above the keel is a height field over the plan and a
    -- height field cannot occlude itself, so within each of these groups the
    -- order does not matter and nothing has to be sorted per frame.
    for i = 1, #cap_tris, 3 do
        face(3 * n + cap_tris[i], 3 * n + cap_tris[i + 2], 3 * n + cap_tris[i + 1])
    end
    for v = 1, n do
        local w = nxt(v)
        quad(n + v, 3 * n + v, 3 * n + w, n + w)        -- down to the keel
    end
    for v = 1, n do
        local w = nxt(v)
        quad(n + v, n + w, w, v)                        -- the waterline band
    end
    for v = 1, n do
        local w = nxt(v)
        quad(v, w, 2 * n + w, 2 * n + v)                -- up to the deck
    end
    for i = 1, #cap_tris, 3 do
        face(2 * n + cap_tris[i], 2 * n + cap_tris[i + 1], 2 * n + cap_tris[i + 2])
    end

    -- Normals, and from them how brightly each face draws.
    local fnx, fny, fnz, flit = {}, {}, {}, {}
    for k = 1, fn do
        local a, b, c = fa[k], fb[k], fc[k]
        local ux, uy, uz = vx[b] - vx[a], vy[b] - vy[a], vz[b] - vz[a]
        local wx, wy, wz = vx[c] - vx[a], vy[c] - vy[a], vz[c] - vz[a]
        local nx = uy * wz - uz * wy
        local ny = uz * wx - ux * wz
        local nz = ux * wy - uy * wx
        local l = math.sqrt(nx * nx + ny * ny + nz * nz)
        if l < 1e-9 then l = 1 end
        fnx[k], fny[k], fnz[k] = nx / l, ny / l, nz / l
    end
    for k = 1, fn do flit[k] = nose_light(fny[k], fnz[k]) end

    h.mesh = {
        n = 4 * n, ring = n, fn = fn,
        x = vx, y = vy, z = vz,
        fa = fa, fb = fb, fc = fc,
        fnx = fnx, fny = fny, fnz = fnz, flit = flit,
        deck = deck, ix = ix, iy = iy, cap = cap, dmax = dmax,
        -- Somewhere to project into. A table per hull per frame is a hundred
        -- tables a frame and all of them garbage, on a collector that runs in
        -- the same thread as the draw.
        px = {}, py = {}, pz = {},
    }
    return h.mesh
end

-- The deck height over a point inside the outline, for hanging a detail on.
-- The parts a hull carries, its plates, its panel lines, its canopy, its lamps
-- and its hardpoints, are all drawn on the deck, so each of them needs one of
-- these. Same arithmetic the ring vertices got, so a detail sits on the
-- surface rather than through it.
function M.deck_at(h, x, y)
    local m = h.mesh
    if not inside_poly(h.poly, x, y) then return M.EDGE end
    local d = depth_at(h.poly, x, y)
    local z = m.cap * (d / m.dmax) ^ 0.62
    if z > 0.85 * d then z = 0.85 * d end
    return M.EDGE + z
end

return M
