-- The sky, and the three things about it that are not a vertex count.
--
--     lua5.1 client/tests/sky_test.lua
--
-- The budget is watched next door in star_budget_test.lua, which asks whether
-- the drawing fits. This asks whether it is the right drawing.
--
-- Three claims, each of which broke at least once while it was being written.
-- A room's sky is the room's: placed from the map's name, so it is the same
-- every time that map is played and not the same as anybody else's. The band
-- is a band rather than a density bump, which means there is somewhere you can
-- stand and not be in it: the first version used a half width wider than the
-- window and the whole view was always inside it, which draws as a starfield
-- with the density turned up and nothing else. And the dust knows the
-- difference between flying and being put somewhere, because a camera that
-- teleports on a respawn would otherwise draw one frame of white rain.

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
local BAND_SIZE = 1.2
local most, least = 0, math.huge
world.sky_seed("drydock")
for i = -40, 40 do
    local L = recorder()
    world.stars(L, L, MID + i * 220, MID + i * 90, HW, HH)
    local n = 0
    for _, s in ipairs(L.log) do
        if s:sub(1, 1) == "r" and s:find(",1.20,", 1, true) then n = n + 1 end
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
