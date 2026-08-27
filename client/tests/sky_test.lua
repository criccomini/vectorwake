-- The sky, and the three things about it that are not a vertex count.
--
--     lua5.1 client/tests/sky_test.lua
--
-- The budget is watched next door in star_budget_test.lua, which asks whether
-- the drawing fits. This asks whether it is the right drawing.
--
-- Five claims, every one of which broke at least once while it was written.
--
-- A room's sky is the room's, placed from the map's name, so it is the same
-- every time that map is played and not the same as anybody else's. The band
-- is a band rather than a density bump, which means there is somewhere you can
-- stand and not be in it: the first version used a half width wider than the
-- window, so the whole view was always inside it, which draws as a starfield
-- with the density turned up and nothing else. The sky does not stop where the
-- map does, because past a declared edge every tile answers solid and anything
-- that reads that answer erases itself out there. The flare hangs off the
-- middle of the frame rather than off anything in the world, which is what
-- makes it a flare. And the dust knows the difference between flying and being
-- put somewhere, because a camera that teleports on a respawn would otherwise
-- draw one frame of white rain.

package.path = "client/?.lua;" .. package.path

_G.sim = {
    solid = function() return false end,
    map_size = function() return 160, 160 end,
}

local world = require("arena.world")

local fails = 0
local function check(desc, ok, why)
    if not ok then fails = fails + 1 end
    print(string.format("%-56s %s", desc, ok and "ok" or ("FAIL: " .. why)))
end

-- A layer that writes down what it was asked to draw instead of drawing it.
-- Positions and colors both, because two skies that put the same number of
-- stars in the same places in different colors are still two skies.
local function recorder()
    local L = {log = {}, rects = 0, segs = 0}
    function L:rect(x, y, w, _, col)
        self.rects = self.rects + 1
        self.log[#self.log + 1] = string.format("r%.1f,%.1f,%.2f,%.3f",
                                                x, y, w, col[4])
    end
    function L:halo(x, y, r, _, col)
        self.log[#self.log + 1] = string.format("h%.1f,%.1f,%.0f,%.3f",
                                                x, y, r, col[4])
    end
    function L:ring(x, y, r, w, _, col)
        self.log[#self.log + 1] = string.format("o%.1f,%.1f,%.0f,%.1f,%.3f",
                                                x, y, r, w, col[4])
    end
    function L:seg_fade(x1, y1, x2, y2)
        self.segs = self.segs + 1
        self.log[#self.log + 1] = string.format("s%.1f,%.1f,%.1f,%.1f",
                                                x1, y1, x2, y2)
    end
    function L:bloom(x, y)
        self.log[#self.log + 1] = string.format("b%.1f,%.1f", x, y)
    end
    return L
end

local MID = 160 * 16 / 2
local HW, HH = 640, 400

-- Draw one frame at a camera and hand back what came out. The camera is walked
-- to it first, since the dust reads how far it moved to get there.
local function frame_at(name, path)
    world.sky_seed(name)
    local L
    for i = 1, #path do
        L = recorder()
        world.stars(L, L, MID + path[i], MID, HW, HH)
    end
    return L
end

local function joined(L)
    return table.concat(L.log, "|")
end

-- --- a room's sky is the room's -------------------------------------------

local a1 = frame_at("drydock", {0, 0})
local a2 = frame_at("drydock", {0, 0})
check("a map gets the same sky every time it is played",
      joined(a1) == joined(a2), "the same name drew two different skies")

local b1 = frame_at("relay", {0, 0})
check("two maps do not share a sky", joined(a1) ~= joined(b1),
      "drydock and relay drew the same sky")

-- The menu has no map and is a map like any other as far as this is concerned.
local m1 = frame_at("", {0, 0})
check("the nameless sky is a sky", #m1.log > 0, "nothing was drawn")

-- --- the band is a band ----------------------------------------------------

-- Walk a long way across the map and count the band's own grain, which is the
-- only thing in the sky drawn at BAND.size. A band that is everywhere and a
-- band that is nowhere are both failures, and they fail in opposite
-- directions, so both ends are checked.
local BAND_SIZE = string.format(",%.2f,", 1.2)
local most, least = 0, math.huge
world.sky_seed("drydock")
for i = -40, 40 do
    local L = recorder()
    world.stars(L, L, MID + i * 220, MID + i * 90, HW, HH)
    local n = 0
    for _, s in ipairs(L.log) do
        if s:sub(1, 1) == "r" and s:find(BAND_SIZE, 1, true) then n = n + 1 end
    end
    if n > most then most = n end
    if n < least then least = n end
end
check("the band is thick somewhere", most > 150,
      "the most grain any camera saw was " .. most)
check("the band ends somewhere", least == 0,
      "every camera was inside the band, the thinnest saw " .. least)
print(string.format("   across the map the band ran from %d grains to %d",
                    least, most))

-- --- the sky does not stop where the map does ------------------------------

-- Past a map's declared edge the core answers solid for every tile, because
-- that is what closes the world to a hull. The sky used to read that answer
-- and take itself out of the drawing, so a pilot flying the corner of a room
-- saw the field end at the outer wall with nothing but cloud beyond it. It
-- draws under the map now and asks the core nothing, which is what this holds:
-- with every tile solid, a camera outside the room still gets a sky.
local closed = {
    solid = function() return true end,
    map_size = function() return 160, 160 end,
}
local open = _G.sim
_G.sim = closed
world.sky_seed("drydock")
local out = recorder()
world.stars(out, out, MID + 3000, MID + 3000, HW, HH)
out = recorder()
world.stars(out, out, MID + 3000, MID + 3000, HW, HH)
_G.sim = open
check("a sky the core calls solid is still drawn", #out.log > 200,
      "drew " .. #out.log .. " pieces past the edge of the map")
print(string.format("   outside the room, %d pieces of sky", #out.log))

-- --- the flare hangs off the middle of the view ----------------------------

-- A lens flare is not out in the sky, it is inside the camera: the ghosts sit
-- on the line from the light through the middle of the frame, so the chain
-- swings about that middle as the light crosses it and goes out when the light
-- leaves. Anchored in the world instead they would drift along with the stars,
-- which is the one thing a smudge on the lens never does, and nothing else in
-- this file would notice.
local function ghosts(cx, cy)
    local seen = {}
    local L = {}
    function L:rect() end
    function L:seg_fade() end
    function L:bloom() end
    function L:halo(x, y, _, segs)
        if segs == world.IRIS_SEGS then seen[#seen + 1] = {x - cx, y - cy} end
    end
    function L:ring(x, y, _, _, segs)
        if segs == world.IRIS_SEGS then seen[#seen + 1] = {x - cx, y - cy} end
    end
    world.stars(L, L, cx, cy, HW, HH)
    return seen
end

world.sky_seed("drydock")
local chain = ghosts(MID, MID)
check("the sun throws a chain of ghosts", #chain >= 5,
      "drew " .. #chain .. " of them")

-- The first is the aperture, drawn on the sun itself, so everything else is
-- measured against where that sits.
local sun = chain[1] or {0, 0}
local bent = nil
for i = 2, #chain do
    local g = chain[i]
    -- Zero cross product against the sun's own offset means on the line.
    local cross = sun[1] * g[2] - sun[2] * g[1]
    if not bent and (cross > 0.5 or cross < -0.5) then bent = i end
end
check("every ghost is on the line from the sun through the middle",
      bent == nil, "ghost " .. tostring(bent) .. " is off it")

local swung = ghosts(MID + 1600, MID)
local across = math.abs((swung[1] or {0})[1] - sun[1])
check("flying swings the chain", across > 200,
      "the sun moved " .. string.format("%.0f", across) .. " across the frame")

-- Away from the sun rather than past it: fly far enough along its own bearing
-- and it comes back into frame on the other side, which is right and is not
-- what this is asking about.
local gone = ghosts(MID, MID + 3000)
check("a flare goes out with the light that throws it", #gone == 0,
      "still drew " .. #gone .. " with the sun off the frame")
print(string.format("   the chain swings %.0f px across the frame over 1600" ..
                    " of flight", across))

-- --- dust knows flying from being moved ------------------------------------

-- Same camera both times, so every other layer draws exactly the same thing
-- and the only difference in the counts is the dust. Standing still it is a
-- rect on the fill layer; under way it is a streak on the glow layer.
local still = frame_at("drydock", {900, 900, 900, 900, 900, 900})
local flown = frame_at("drydock", {600, 660, 720, 780, 840, 900})
local moved = still.rects - flown.rects
check("standing still, dust is a dot", moved > 0,
      "flying changed the fill count by " .. moved)
check("under way, dust is a streak", flown.segs - still.segs == moved,
      string.format("%d rects became %d streaks",
                    moved, flown.segs - still.segs))
print(string.format("   %d motes moved from the fill layer to the glow one",
                    moved))

-- A camera that jumps is a respawn, an eye moving to another hull, or a new
-- map, and none of those is flight. The frame after the jump has to look like
-- the frame after that one, which is the frame of a camera sitting still.
world.sky_seed("drydock")
for _ = 1, 6 do
    local L = recorder()
    world.stars(L, L, MID, MID, HW, HH)
end
local jump = recorder()
world.stars(jump, jump, MID + 5000, MID + 5000, HW, HH)
local after = recorder()
world.stars(after, after, MID + 5000, MID + 5000, HW, HH)
check("a camera that teleports does not smear the dust",
      jump.rects == after.rects and jump.segs == after.segs,
      string.format("the jump drew %d rects and %d streaks, the frame after" ..
                    " it %d and %d", jump.rects, jump.segs,
                    after.rects, after.segs))

if fails > 0 then
    print(fails .. " check(s) failed")
    os.exit(1)
end
print("all checks passed")
