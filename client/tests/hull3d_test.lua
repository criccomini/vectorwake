-- The hulls as solids, against the boxes the simulation collides them in.
--
--     lua5.1 client/tests/hull3d_test.lua
--
-- A hull is a deck over a keel now, and a bank is a rotation about its own
-- nose-to-tail axis rather than a scale on its local x. Three things have to
-- stay true through that, and none of them is visible from looking at a frame:
--
--   the third dimension may not cost a hull a pixel of hitbox, so every vertex
--   of every solid has to sit on the box sim/src/baseline.c gives that class,
--   and all seven of those boxes have to spend the same 625 square pixels;
--
--   the keel has to stay a keel, since two matched faces make every class read
--   the same from either side, which is the opposite of what a top-down game
--   wants;
--
--   and the bank has to be a rotation. A squash and a roll look alike in a
--   still and are not alike: under a squash nothing leaves the plane, and
--   under a roll the deck travels sideways by its own height. The last check
--   here is the one that can tell them apart.
--
-- hull_fit_test.lua holds the drawing to the same boxes from the other side.

package.path = "client/?.lua;" .. package.path

local EXTENTS_SRC = "sim/src/baseline.c"
local MAX_OVERLAP = 1.7
local TARGET_AREA = 625
-- How much of a hull's height the keel is allowed to be. A mirrored hull is
-- one, and one is what this exists to refuse: two matched faces make every
-- class read the same from either side. Half is the line, because past it the
-- underside stops reading as a plate and starts reading as a second deck. The
-- Chord comes closest at 0.36, and for a reason that is about the waterline
-- rather than about the keel: its crown is the shallowest in the roster, so
-- the band the two faces share is a bigger share of it.
local KEEL_MAX = 0.5

local fails = 0
local function check(name, ok, detail)
    if ok then
        print("ok   " .. name)
    else
        fails = fails + 1
        print("FAIL " .. name .. (detail and ("  -- " .. detail) or ""))
    end
end

-- The `hull_extent` table in baseline.c, one Q8 row of {fore, aft, halfw} per
-- hull, read rather than repeated so the two cannot drift apart.
local function extents_from_c()
    local f = assert(io.open(EXTENTS_SRC, "r"), "run me from the repository root")
    local src = f:read("*a")
    f:close()
    local body = src:match("hull_extent%[SIM_MAX_CLASSES%]%[3%]%s*=%s*{(.-)}%s*;")
    assert(body, EXTENTS_SRC .. " has no hull_extent table this test can read")
    local out = {}
    for row in body:gmatch("{(.-)}") do
        local t = {}
        for n in row:gmatch("%d+") do t[#t + 1] = tonumber(n) / 256 end
        assert(#t == 3, "a row of hull_extent is not three numbers")
        out[#out + 1] = t
    end
    return out
end

_G.sim = {T_SOLID = 1, T_SAFE = 2, T_DOOR = 3, T_WORMHOLE = 5,
          map_coarse = function() return "", 0 end}

local pal = require("arena.palette")
local hull3d = require("arena.hull3d")
local world = require("arena.world")
local extents = extents_from_c()
local NAMES = {"Apex", "Wedge", "Chord", "Anvil", "Cipher", "Facet", "Lattice"}

check("every hull was given a solid",
      (function()
          for _, h in ipairs(world.HULLS) do
              if not h.mesh or h.mesh.fn == 0 then return false end
          end
          return true
      end)())

for i, h in ipairs(world.HULLS) do
    local name = NAMES[i] or ("hull " .. i)
    local m = h.mesh
    local fore, aft, halfw = extents[i][1], extents[i][2], extents[i][3]

    -- Nothing in hull3d moves a vertex in x or y, and this is what says so
    -- rather than asking to be believed: the solid's plan reach, measured over
    -- every vertex it has, against the box.
    local fwd, back, side = 0, 0, 0
    for v = 1, m.n do
        local ax = m.x[v] < 0 and -m.x[v] or m.x[v]
        if m.y[v] > fwd then fwd = m.y[v] end
        if -m.y[v] > back then back = -m.y[v] end
        if ax > side then side = ax end
    end
    -- Against the outline it was lofted from, exactly. Height is the only
    -- thing hull3d invents, and an equality here is what says so: the solid
    -- reaches neither further nor less far than the drawing does.
    local pf, pb, ps = 0, 0, 0
    for v = 1, #h.poly, 2 do
        local ax = h.poly[v] < 0 and -h.poly[v] or h.poly[v]
        if h.poly[v + 1] > pf then pf = h.poly[v + 1] end
        if -h.poly[v + 1] > pb then pb = -h.poly[v + 1] end
        if ax > ps then ps = ax end
    end
    for _, face in ipairs({{"nose", fwd, pf}, {"tail", back, pb},
                           {"flank", side, ps}}) do
        local what, solid, flat = face[1], face[2], face[3]
        check(string.format("%s's solid reaches its %s and no further", name, what),
              math.abs(solid - flat) < 1e-6,
              string.format("solid %.4f against a drawing of %.4f", solid, flat))
    end
    -- And the drawing is on the box, which is the contract the extra dimension
    -- must not have cost. hull_fit_test measures every part; this measures the
    -- outline, which is the part a solid is built from.
    for _, face in ipairs({{"nose", pf, fore}, {"tail", pb, aft},
                           {"flank", ps, halfw}}) do
        local what, drawn, box = face[1], face[2], face[3]
        check(string.format("%s's %s box (%.4g) is inside its outline",
                            name, what, box),
              drawn - box >= -MAX_OVERLAP and drawn - box <= MAX_OVERLAP,
              string.format("outline %.2f against a box of %.4g", drawn, box))
    end

    local area = (fore + aft) * halfw * 2
    check(string.format("%s spends the common target area (%.3f)", name, area),
          math.abs(area - TARGET_AREA) < 1e-6,
          string.format("%.3f px^2 rather than %d", area, TARGET_AREA))

    -- A deck above and a keel below, and the keel nearly flat.
    local hi, lo = -math.huge, math.huge
    for v = 1, m.n do
        if m.z[v] > hi then hi = m.z[v] end
        if m.z[v] < lo then lo = m.z[v] end
    end
    check(string.format("%s stands up off the plane (%.2f px)", name, hi),
          hi > hull3d.EDGE, string.format("crown %.3f", hi))
    check(string.format("%s's keel is nearly flat (%.2f of its crown)",
                        name, -lo / hi),
          -lo / hi < KEEL_MAX, string.format("keel %.2f crown %.2f", -lo, hi))

    -- The top is symmetric about the hull's own spine, which every drawing in
    -- world.lua already is and which the loft must not break.
    local mirrored = true
    for v = 1, m.n do
        local found = false
        for w = 1, m.n do
            if math.abs(m.x[w] + m.x[v]) < 1e-6
                and math.abs(m.y[w] - m.y[v]) < 1e-6
                and math.abs(m.z[w] - m.z[v]) < 1e-6 then
                found = true
                break
            end
        end
        if not found then mirrored = false break end
    end
    check(name .. "'s solid is symmetric about its spine", mirrored)

    -- Every face carries a unit normal, which is what the draw culls on.
    local unit = true
    for k = 1, m.fn do
        local l = math.sqrt(m.fnx[k] ^ 2 + m.fny[k] ^ 2 + m.fnz[k] ^ 2)
        if math.abs(l - 1) > 1e-5 then unit = false break end
    end
    check(name .. "'s faces all face somewhere", unit)
end

-- --- the bank is a rotation -------------------------------------------------
--
-- Draw one hull level and again holding the whole bank, and read the body out
-- of the fill layer. A squash and a roll are told apart by where the drawn
-- body's middle ends up: scaling local x leaves it on the ship's own spine,
-- and rotating about the spine carries the deck off it by its own height.

local SHIP_X, SHIP_Y = 500, 500

local function body_of(roll)
    local n, area, cx = 0, 0, 0
    local lo, hi = math.huge, -math.huge
    local noop = function() end
    local fill = setmetatable({
        tri = function(_, x1, y1, x2, y2, x3, y3)
            -- Area weighted, so what is measured is the shape rather than the
            -- triangulation of it. Ear clipping cuts a symmetric polygon into
            -- an asymmetric set of triangles, and counting their corners reads
            -- that as a lopsided ship.
            local a = math.abs((x2 - x1) * (y3 - y1) - (x3 - x1) * (y2 - y1)) / 2
            n = n + 1
            area = area + a
            cx = cx + a * (x1 + x2 + x3) / 3
            for _, v in ipairs({x1, x2, x3}) do
                if v < lo then lo = v end
                if v > hi then hi = v end
            end
        end,
    }, {__index = function() return noop end})
    local glow = setmetatable({}, {__index = function() return noop end})
    world.lights_begin()
    world.ship(fill, glow, 0, SHIP_X, SHIP_Y, 0, pal.FRIEND, {roll = roll})
    return {n = n, lo = lo, hi = hi, area = area,
            mid = area > 0 and cx / area - SHIP_X or 0}
end

local level = body_of(0)
local banked = body_of(0.95)

check("a hull draws a body at all", level.n > 0, tostring(level.n) .. " facets")
check("and it is a solid rather than a fan",
      level.n > #world.HULLS[1].poly / 2,
      level.n .. " facets from " .. (#world.HULLS[1].poly / 2) .. " outline points")
-- A hull's plan is symmetric and so is the cull, so at rest the drawn body's
-- middle sits on the ship's own spine.
check("level, the body's middle sits on the ship's spine",
      math.abs(level.mid) < 0.05, string.format("%.4f px off", level.mid))
check("banked, the hull is narrower",
      (banked.hi - banked.lo) < (level.hi - level.lo) * 0.9,
      string.format("%.1f then %.1f", level.hi - level.lo, banked.hi - banked.lo))

-- The whole point of the file, and the two things a squash cannot do.
--
-- A squash draws a hull exactly cos(roll) as wide as its plan and covers
-- exactly cos(roll) of its area, because scaling local x is all it is. A roll
-- draws more of both: the hull has thickness, and rolled over it shows the
-- flank that thickness gives it.
local squashed_w = (level.hi - level.lo) * math.cos(0.95)
check("banked, the hull draws wider than a squash would",
      (banked.hi - banked.lo) > squashed_w + 0.5,
      string.format("%.2f px against %.2f squashed", banked.hi - banked.lo,
                    squashed_w))
check("and covers more than a squash would",
      banked.area > level.area * math.cos(0.95) * 1.15,
      string.format("%.0f px^2 against %.0f squashed", banked.area,
                    level.area * math.cos(0.95)))

-- And it leans further the harder the bank, which is a squash's one certainty
-- reversed: scaling local x keeps a symmetric shape symmetric at every angle,
-- so under a squash every one of these is zero.
local last = -1
local leans = {}
for _, r in ipairs({0, 0.3, 0.6, 0.95}) do
    local m = body_of(r).mid
    leans[#leans + 1] = string.format("%.2f", m)
    -- A hundredth of a pixel, which is a hundred times any float noise here
    -- and still exactly zero under a squash: scaling local x keeps a
    -- symmetric shape symmetric at every angle.
    if m <= last + 0.01 then last = nil break end
    last = m
end
check("the deck leans further the harder the bank",
      last ~= nil, "middles: " .. table.concat(leans, " "))
check("and holding the whole bank it is off the spine by a real fraction of a pixel",
      body_of(0.95).mid > 0.1,
      string.format("%.3f px", body_of(0.95).mid))


-- --- the cull throws nothing away -------------------------------------------
--
-- The body is drawn with a back-face cull and nothing is depth sorted, which
-- is only safe because everything above the keel is a height field over the
-- plan and a height field cannot occlude itself. If that ever stops being
-- true, the symptom is a slot of bare starfield through the middle of a hull,
-- and it is invisible in a still of a level ship.
--
-- So rasterize what the cull draws and rasterize every face, and compare the
-- two areas. They have to agree: whatever the cull drops has to be behind
-- something it keeps. The Apex is allowed to differ by nothing either, which
-- is worth saying because its wing notch is a real slot and does show
-- starfield through it at some banks. That is the hull, not the renderer.

local GRID = 0.5

local function coverage(m, roll, cull)
    local cr, sr = math.cos(roll), math.sin(roll)
    local qx, qy = {}, {}
    local lo_x, hi_x, lo_y, hi_y = math.huge, -math.huge, math.huge, -math.huge
    for i = 1, m.n do
        qx[i] = m.x[i] * cr + m.z[i] * sr
        qy[i] = m.y[i]
        if qx[i] < lo_x then lo_x = qx[i] end
        if qx[i] > hi_x then hi_x = qx[i] end
        if qy[i] < lo_y then lo_y = qy[i] end
        if qy[i] > hi_y then hi_y = qy[i] end
    end
    local w = math.ceil((hi_x - lo_x) / GRID) + 2
    local x0, y0 = lo_x - GRID, lo_y - GRID
    local hit, n = {}, 0
    for k = 1, m.fn do
        if not cull or m.fnz[k] * cr - m.fnx[k] * sr > 0 then
            local a, b, c = m.fa[k], m.fb[k], m.fc[k]
            local ax, ay, bx, by, cx, cy = qx[a], qy[a], qx[b], qy[b], qx[c], qy[c]
            local d = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
            if math.abs(d) > 1e-12 then
                local gx0 = math.floor((math.min(ax, bx, cx) - x0) / GRID)
                local gx1 = math.ceil((math.max(ax, bx, cx) - x0) / GRID)
                local gy0 = math.floor((math.min(ay, by, cy) - y0) / GRID)
                local gy1 = math.ceil((math.max(ay, by, cy) - y0) / GRID)
                for gy = gy0, gy1 do
                    for gx = gx0, gx1 do
                        local px, py = x0 + (gx + 0.5) * GRID, y0 + (gy + 0.5) * GRID
                        local s = ((by - cy) * (px - cx) + (cx - bx) * (py - cy)) / d
                        local t = ((cy - ay) * (px - cx) + (ax - cx) * (py - cy)) / d
                        if s >= 0 and t >= 0 and s + t <= 1 then
                            local key = gy * w + gx
                            if not hit[key] then
                                hit[key] = true
                                n = n + 1
                            end
                        end
                    end
                end
            end
        end
    end
    return n * GRID * GRID
end

for c, h in ipairs(world.HULLS) do
    local name = NAMES[c] or ("hull " .. c)
    local worst, at = 0, 0
    for _, roll in ipairs({0, 0.3, 0.6, 0.8, 0.95}) do
        local kept = coverage(h.mesh, roll, true)
        local all = coverage(h.mesh, roll, false)
        local gap = all - kept
        if gap > worst then worst, at = gap, roll end
    end
    check(string.format("%s's cull hides nothing the hull does not", name),
          worst < 0.6,
          string.format("%.2f px^2 uncovered at bank %.2f", worst, at))
end


-- --- a full room fits in the layers -----------------------------------------
--
-- A solid hull is three or four times the geometry a flat one was, and a layer
-- that runs out of room does not report it: it stops drawing whatever came
-- last, so the failure looks like a ship missing its hull rather than like an
-- error. world.lua sizes the two per-frame layers against a seat ceiling, and
-- this is what holds that figure to the drawing.
--
-- Priced at the worst the roster can do: the hull with the most facets,
-- holding the whole bank, with its engines lit and its detail on.

local function seat_cost(cls, roll)
    local f, g = 0, 0
    local noop = function() end
    local fill = setmetatable({tri = function() f = f + 3 end,
                               quad = function() f = f + 6 end},
                              {__index = function() return noop end})
    local glow = setmetatable({
        tri = function() g = g + 3 end,
        tri_fade = function() g = g + 3 end,
        seg = function() g = g + 6 end,
        seg_glow = function() g = g + 6 end,
        seg_fade = function() g = g + 6 end,
        fan = function(_, q) g = g + (#q / 2) * 3 end,
        outline = function(_, q) g = g + (#q / 2) * 6 end,
        halo = function(_, _, _, _, segs) g = g + (segs or 8) * 3 end,
        bloom = function() g = g + 18 end,
    }, {__index = function() return noop end})
    world.lights_begin()
    world.ship(fill, glow, cls, SHIP_X, SHIP_Y, 0, pal.FRIEND,
               {roll = roll, thrusting = true, hurt = 0.5, flash = 1})
    return f, g
end

local worst_f, worst_g, worst_at = 0, 0, ""
for c = 0, #world.HULLS - 1 do
    for _, roll in ipairs({0, 0.5, 0.95}) do
        local f, g = seat_cost(c, roll)
        if f > worst_f then worst_f, worst_at = f, NAMES[c + 1] end
        if g > worst_g then worst_g = g end
    end
end

local seats = world.SEAT_CEILING
check(string.format("a full room of hulls fits the fill layer (%s is the worst seat)",
                    worst_at),
      worst_f * seats <= world.FILL_FIGHT,
      string.format("%d seats x %d verts is %d, budget %d",
                    seats, worst_f, worst_f * seats, world.FILL_FIGHT))
check("a full room of hulls fits the glow layer",
      worst_g * seats <= world.GLOW_FIGHT,
      string.format("%d seats x %d verts is %d, budget %d",
                    seats, worst_g, worst_g * seats, world.GLOW_FIGHT))

print(fails == 0 and "all ok" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
