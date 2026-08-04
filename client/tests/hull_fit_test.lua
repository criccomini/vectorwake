-- Every hull, against the box the simulation collides it in.
--
--     lua5.1 client/tests/hull_fit_test.lua
--
-- A ship collides as an axis-aligned box of `radius` half-width that never
-- rotates, so one pressed nose-first into a wall stops with its centre exactly
-- that far from the face. Anything the client draws further out than that is
-- drawn inside the wall. That is not a subtle failure and it still shipped for
-- months, because the two numbers live in different languages in different
-- directories and nothing compared them: the radius was a flat 14 in
-- sim/src/baseline.c and the Apex's nose reached 21.5 in arena/world.lua.
--
-- So this reads the radii out of the C rather than repeating them here, the
-- same way overview_test reads the maps the fleet serves. Redraw a hull past
-- its box, or shrink a box under its hull, and this is what says so.

package.path = "client/?.lua;" .. package.path

local RADII_SRC = "sim/src/baseline.c"

local fails = 0
local function check(name, ok, detail)
    if ok then
        print("ok   " .. name)
    else
        fails = fails + 1
        print("FAIL " .. name .. (detail and ("  -- " .. detail) or ""))
    end
end

-- The `hull_radius` table in baseline.c, in roster order.
local function radii_from_c()
    local f = assert(io.open(RADII_SRC, "r"), "run me from the repository root")
    local src = f:read("*a")
    f:close()
    local body = src:match("hull_radius%[SIM_MAX_CLASSES%]%s*=%s*{(.-)}%s*;")
    assert(body, RADII_SRC .. " has no hull_radius table this test can read")
    -- Comments carry numbers of their own, so they go before the digits do.
    body = body:gsub("/%*.-%*/", ""):gsub("//[^\n]*", "")
    local out = {}
    for n in body:gmatch("%d+") do out[#out + 1] = tonumber(n) end
    assert(#out == 8, "expected 8 radii, read " .. #out)
    return out
end

-- How far the drawing of one hull reaches from the point the ship turns and
-- collides about. Every part, not just the outline: the Spire's mast lamp is a
-- pod sitting past its own nose, and it was the furthest thing on the roster.
local function reach(h)
    local far = 0
    local function scan(pts, pad)
        pad = pad or 0
        for i = 1, #pts, 2 do
            local d = math.sqrt(pts[i] ^ 2 + pts[i + 1] ^ 2) + pad
            if d > far then far = d end
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
        for _, q in ipairs(h.tubes) do scan({q[1], q[2], q[3], q[4]}, q[5] / 2) end
    end
    return far
end

-- world.lua wants the extension for tile classes and never touches it at load.
_G.sim = {T_SOLID = 1, T_SAFE = 2, T_DOOR = 3, T_WORMHOLE = 5,
          map_coarse = function() return "", 0 end}

local world = require("arena.world")
local radii = radii_from_c()
local NAMES = {"Apex", "Wedge", "Chord", "Anvil",
               "Spire", "Cipher", "Facet", "Lattice"}

check("the roster and the radii are the same length",
      #world.HULLS == #radii,
      #world.HULLS .. " hulls against " .. #radii .. " radii")

-- 23 is the ceiling, and it is a promise to every map rather than a taste: at
-- 26 a hull stops fitting two of the spawns on the shipped maps and would
-- respawn inside a wall. See the note beside the table in baseline.c.
local CEILING = 23

for i, h in ipairs(world.HULLS) do
    local r = radii[i] or 0
    local far = reach(h)
    local name = NAMES[i] or ("hull " .. i)
    check(string.format("%s is drawn inside its box (%.1f px into %d)",
                        name, far, r),
          far <= r + 1e-6,
          string.format("%.1f px past the wall face when it noses into one",
                        far - r))
    -- Slack is not a bug, but a hull two pixels inside a box a size larger
    -- than it needs is a hull that is easier to hit than it looks.
    check(string.format("%s's box is not oversized", name),
          r - far < 1.0,
          string.format("radius %d for a hull reaching %.1f", r, far))
    check(string.format("%s is within the roster ceiling", name),
          r <= CEILING, "radius " .. r .. " needs gaps no map promises")
end

print(fails == 0 and "all ok" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
