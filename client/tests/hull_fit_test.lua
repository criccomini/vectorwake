-- Every hull, against the box the simulation collides it in.
--
--     lua5.1 client/tests/hull_fit_test.lua
--
-- A ship's collision box is built from three extents at its current heading:
-- reach past the nose, behind the tail, and to either side. A wall stops the
-- box and a weapon has to reach the rectangle, so the drawing and the extents
-- have to agree or the game lies at every wall. They live in different
-- languages in different directories, which is how a flat radius of 14 stood
-- against a 21.5 px nose for months with nothing comparing the halves.
--
-- So this reads the extents out of the C rather than repeating them here, the
-- same way overview_test reads the maps the fleet serves, and measures each
-- face of each drawn hull against its own number. The contract per face is a
-- band, not equality: the box may sit up to about a pixel and a half inside
-- the drawing, never outside it. Inside is deliberate -- it is what keeps the
-- box's diagonal under the 23 px ceiling the shipped maps were flood-filled
-- and spawn-checked against, so a long hull can still spin in a three-tile
-- corridor -- and a pixel of art crossing a wall at the moment of contact is
-- invisible where the seven and a half this test exists to prevent was not.
-- Outside would be the opposite defect: a ship bouncing off walls it visibly
-- never touched.

package.path = "client/?.lua;" .. package.path

local EXTENTS_SRC = "sim/src/baseline.c"

-- How far past its box a drawn face may reach, and the ceiling on the box's
-- own diagonal. Both are explained above; the second is the map contract.
local MAX_OVERLAP = 1.7
local CEILING = 23

local fails = 0
local function check(name, ok, detail)
    if ok then
        print("ok   " .. name)
    else
        fails = fails + 1
        print("FAIL " .. name .. (detail and ("  -- " .. detail) or ""))
    end
end

-- The `hull_extent` table in baseline.c: one row of {fore, aft, halfw} per
-- hull. The count is not asserted against a literal here, because the roster
-- is the core's to decide and this test is about whether the drawings match
-- the boxes; that the two lists are the same length is checked below, where
-- a mismatch names both numbers.
local function extents_from_c()
    local f = assert(io.open(EXTENTS_SRC, "r"), "run me from the repository root")
    local src = f:read("*a")
    f:close()
    local body = src:match("hull_extent%[SIM_MAX_CLASSES%]%[3%]%s*=%s*{(.-)}%s*;")
    assert(body, EXTENTS_SRC .. " has no hull_extent table this test can read")
    local out = {}
    for row in body:gmatch("{(.-)}") do
        local t = {}
        for n in row:gmatch("%d+") do t[#t + 1] = tonumber(n) end
        assert(#t == 3, "a row of hull_extent is not three numbers")
        out[#out + 1] = t
    end
    assert(#out > 0, "hull_extent read as empty")
    return out
end

-- The reach of one hull's drawing on each face: past the nose (+y in hull
-- space), behind the tail, and to either side. Every part, not just the
-- outline: a pod or a tube can sit past the hull's own nose, and the furthest
-- thing on a ship is not always on its outline.
local function reach(h)
    local fwd, aft, side = 0, 0, 0
    local function scan(pts, pad)
        pad = pad or 0
        for i = 1, #pts, 2 do
            local x, y = pts[i], pts[i + 1]
            if y + pad > fwd then fwd = y + pad end
            if -y + pad > aft then aft = -y + pad end
            local ax = x < 0 and -x or x
            if ax + pad > side then side = ax + pad end
        end
    end
    scan(h.poly)
    if h.canopy then scan(h.canopy) end
    if h.jets then scan(h.jets) end
    if h.plates then for _, q in ipairs(h.plates) do scan(q) end end
    if h.lines then for _, q in ipairs(h.lines) do scan(q) end end
    -- A pod is {x, y, radius}: a disc, so its edge is the radius out.
    if h.pods then
        for _, q in ipairs(h.pods) do scan({q[1], q[2]}, q[3]) end
    end
    -- A tube is {x1, y1, x2, y2, width}: a stroke, so half its width.
    if h.tubes then
        for _, q in ipairs(h.tubes) do
            scan({q[1], q[2], q[3], q[4]}, q[5] / 2)
        end
    end
    return fwd, aft, side
end

-- world.lua wants the extension for tile classes and never touches it at load.
_G.sim = {T_SOLID = 1, T_SAFE = 2, T_DOOR = 3, T_WORMHOLE = 5,
          map_coarse = function() return "", 0 end}

local world = require("arena.world")
local extents = extents_from_c()
local NAMES = {"Apex", "Wedge", "Chord", "Anvil",
               "Cipher", "Facet", "Lattice"}

check("the roster and the extents are the same length",
      #world.HULLS == #extents,
      #world.HULLS .. " hulls against " .. #extents .. " rows")

for i, h in ipairs(world.HULLS) do
    local fore, aft, halfw = extents[i][1], extents[i][2], extents[i][3]
    local name = NAMES[i] or ("hull " .. i)
    local df, da, ds = reach(h)
    for _, face in ipairs({{"nose", df, fore}, {"tail", da, aft},
                           {"flank", ds, halfw}}) do
        local what, drawn, box = face[1], face[2], face[3]
        check(string.format("%s %s: box %d inside drawing %.1f",
                            name, what, box, drawn),
              drawn - box >= -1e-6 and drawn - box <= MAX_OVERLAP,
              string.format("drawn %.1f against a box of %d is %+.1f px",
                            drawn, box, drawn - box))
    end
    local diag = math.max(math.sqrt(fore ^ 2 + halfw ^ 2),
                          math.sqrt(aft ^ 2 + halfw ^ 2))
    check(string.format("%s's diagonal is inside the map ceiling (%.1f)",
                        name, diag),
          diag <= CEILING,
          "a box this long and wide reaches past 23 px when flown diagonally")
end

print(fails == 0 and "all ok" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
