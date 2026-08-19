-- The per-frame effects that arrived with the graphics push: ship trails,
-- and wall edges lit by passing fire.
--
--     lua5.1 client/tests/effects_test.lua
--
-- Both draw into the glow layer and both fail quietly: a trail that lies
-- draws a ribbon across a teleport the ship never flew, and a wall light
-- with its cap gone is a frame spent scanning tiles for every round in a
-- fleet fight. So the rules are checked as arithmetic against stub layers,
-- the way the star budget already is.

package.path = "client/?.lua;" .. package.path

local fails = 0
local function check(name, ok, detail)
    if ok then
        print("ok   " .. name)
    else
        fails = fails + 1
        print("FAIL " .. name .. (detail and ("  -- " .. detail) or ""))
    end
end

-- A wall column: tiles at tx == 10 are solid for 0 <= ty <= 20.
_G.sim = {solid = function(tx, ty)
    return tx == 10 and ty >= 0 and ty <= 20
end}

local world = require("arena.world")
local COL = {1, 0.5, 0.2, 1}

local function glow_stub()
    local g = {fades = 0, glows = 0, alphas = {}, xs = {}}
    function g:seg_fade() self.fades = self.fades + 1 end
    function g:seg_glow(x1, _, _, _, _, a)
        self.glows = self.glows + 1
        self.alphas[#self.alphas + 1] = a
        self.xs[#self.xs + 1] = x1
    end
    return g
end

-- --- trails -----------------------------------------------------------------

local g = glow_stub()
world.trail(g, 1, 100, 100, 0, 0, COL, 0)
check("one sample draws nothing", g.fades == 0, tostring(g.fades))
world.trail(g, 1, 104, 100, 0, 0, COL, 1 / 60)
check("the very next frame draws a segment to the hull", g.fades == 1,
      tostring(g.fades))
-- Ninety frames of steady flight at four pixels a frame. Samples commit on
-- the fifty-millisecond clock, so the ribbon holds its full dozen and its
-- tail reaches well behind the hull: that reach is the whole reason the
-- clock exists, and the check that would catch a cadence quietly becoming
-- per-frame again, which is a ribbon a fifth as long drawn just as often.
local tail = math.huge
for i = 2, 90 do
    g = glow_stub()
    g.seg_fade = function(self, x1, _, x2)
        self.fades = self.fades + 1
        tail = math.min(tail, math.min(x1, x2))
    end
    tail = math.huge
    world.trail(g, 1, 100 + i * 4, 100, 0, 0, COL, i / 60)
end
check("a long flight draws a full ribbon and no more",
      g.fades * 6 == world.TRAIL_VERTS, tostring(g.fades))
check("and the ribbon reaches well behind the hull",
      (100 + 90 * 4) - tail > 100,
      string.format("tail %.0f behind", (100 + 90 * 4) - tail))

-- The ribbon leaves from the exhaust, not from the middle of the hull. Each
-- class's tail depth comes off its own jets, so an eastbound Apex trails
-- from eleven pixels behind its center and a Cipher from thirteen: the head
-- of the ribbon has to sit exactly there, and differently per hull.
local function head_of(cls)
    local head = -math.huge
    local hg = glow_stub()
    hg.seg_fade = function(self, x1)
        self.fades = self.fades + 1
        head = math.max(head, x1)
    end
    -- Two frames flying east (heading 16384 of 65536), far from earlier
    -- trails so the ship index can be reused without a reset mattering.
    world.trail(hg, 40 + cls, 5000, 5000, 16384, cls, COL, 0)
    world.trail(hg, 40 + cls, 5008, 5000, 16384, cls, COL, 1 / 60)
    return head
end
check("an Apex ribbon leaves from its jets", head_of(0) == 5008 - 11,
      tostring(head_of(0)))
check("a Cipher's leaves from its own, deeper", head_of(4) == 5008 - 13,
      tostring(head_of(4)))

-- A teleport is a jump with no gap in time; the ribbon must not cross it.
g = glow_stub()
world.trail(g, 1, 900, 900, 0, 0, COL, 91 / 60)
check("a teleport resets the ribbon", g.fades == 0, tostring(g.fades))

-- And a gap in time is a death, a respawn or a spell off screen.
world.trail(g, 1, 904, 900, 0, 0, COL, 92 / 60)
g = glow_stub()
world.trail(g, 1, 908, 900, 0, 0, COL, 92 / 60 + 0.5)
check("a gap in the record resets it too", g.fades == 0, tostring(g.fades))

-- --- wall light -------------------------------------------------------------

-- A light near the wall's open face lights it, hardest nearest the light.
world.lights_begin()
world.light(140, 168, COL, 0.8, 60)
g = glow_stub()
world.wall_light(g)
check("fire near a wall lights its edges", g.glows > 0, tostring(g.glows))
local worst = 0
for _, a in ipairs(g.alphas) do worst = math.max(worst, a) end
check("no edge outshines the light", worst <= 0.8, tostring(worst))
local face_only = true
for _, x in ipairs(g.xs) do
    if x < 160 - 16 or x > 176 + 16 then face_only = false end
end
check("the lit edges are the wall's own", face_only)
-- And the light falls off: the edge nearest the fire draws brighter than the
-- ones up the column, or this is a floodlight with a radius, not a glow.
local near_a, far_a = 0, math.huge
for _, a in ipairs(g.alphas) do
    near_a = math.max(near_a, a)
    far_a = math.min(far_a, a)
end
check("the light falls off along the wall", near_a > far_a * 1.5,
      string.format("%.3f vs %.3f", near_a, far_a))

-- A light out of reach lights nothing.
world.lights_begin()
world.light(20, 168, COL, 0.8, 60)
g = glow_stub()
world.wall_light(g)
check("fire far from every wall lights none", g.glows == 0, tostring(g.glows))

-- The cap: an eleventh light changes nothing, so a fleet fight cannot spend
-- the frame scanning tiles.
world.lights_begin()
for _ = 1, 10 do world.light(140, 168, COL, 0.5, 60) end
g = glow_stub()
world.wall_light(g)
local ten = g.glows
world.lights_begin()
for _ = 1, 25 do world.light(140, 168, COL, 0.5, 60) end
g = glow_stub()
world.wall_light(g)
check("the light cap holds", g.glows == ten,
      g.glows .. " vs " .. ten)

-- --- the ripple -------------------------------------------------------------

package.loaded["arena.sfx"] = {play = function() end}
local fxr = require("arena.fx")

-- Nothing exploding, nothing bent. The starfield asks this of every star it
-- places, so the quiet case has to be the identity or the sky drifts.
fxr.reset()
fxr.update(1 / 60)
local bx, by = fxr.bend(500, 500, 1)
check("a quiet sky is not bent", bx == 500 and by == 500,
      string.format("%.2f, %.2f", bx, by))

-- A blast pushes what is near its ring outward, and only what is near it.
-- The wave starts at radius 4 and eases out to 90, so one frame in the ring
-- is still small and the crest sits close to the middle.
fxr.reset()
fxr.wave(0, 0, 4, 90, 0.5, 10, COL)
fxr.update(1 / 60)
local function pushed(x, y)
    local ax, ay = fxr.bend(x, y, 1)
    return math.sqrt((ax - x) ^ 2 + (ay - y) ^ 2)
end
check("a star on the crest is pushed", pushed(14, 0) > 1, tostring(pushed(14, 0)))
check("a star far outside the band is not", pushed(600, 0) == 0,
      tostring(pushed(600, 0)))

-- The disturbance is a band travelling with the ring, not a bubble filling
-- it. A star well inside a grown ring is water the wave has already passed:
-- it has to be still again, or the whole sky inside a blast heaves at once.
fxr.reset()
fxr.wave(0, 0, 4, 300, 0.6, 10, COL)
for _ = 1, 12 do fxr.update(1 / 60) end
check("a star the wave has passed is still again", pushed(12, 0) == 0,
      tostring(pushed(12, 0)))
fxr.reset()
fxr.wave(0, 0, 4, 90, 0.5, 10, COL)
fxr.update(1 / 60)
check("and the push is outward, away from the blast",
      select(1, fxr.bend(14, 0, 1)) > 14)

-- Inside the band the push is shaped, not flat: hardest on the ring and
-- trailing off to nothing at the band's edges. Flat would heave a wide disc
-- of sky as one slab, which reads as the camera lurching rather than as a
-- wave going by. The ring is near ten pixels out one frame in, so a star at
-- seventy is inside the band and near its edge.
check("the push peaks on the ring and fades across the band",
      pushed(10, 0) > pushed(70, 0) * 4,
      string.format("crest %.2f, edge %.2f", pushed(10, 0), pushed(70, 0)))

-- Depth scales it: the near sky rides a blast the far sky barely feels.
check("a nearer layer is bent further than a far one",
      pushed(14, 0) > 0 and select(1, fxr.bend(14, 0, 0.18)) < select(1, fxr.bend(14, 0, 0.6)))

-- The centre of a blast is left alone rather than divided by a distance of
-- nothing: a star exactly on the origin has no direction to be pushed in.
local cx2, cy2 = fxr.bend(0, 0, 1)
check("a star at the very centre is left where it is",
      cx2 == 0 and cy2 == 0, string.format("%.2f, %.2f", cx2, cy2))

-- A spark-sized wave is not a shock. Ship deaths throw a 24-pixel flash
-- alongside the real one, and the sky must not twitch for every hit.
fxr.reset()
fxr.wave(0, 0, 2, 24, 0.16, 15, COL)
fxr.update(1 / 60)
check("a small flash does not bend the sky", pushed(20, 0) == 0,
      tostring(pushed(20, 0)))

-- And the disturbance dies with the ring rather than outliving it.
fxr.reset()
fxr.wave(0, 0, 4, 90, 0.5, 10, COL)
fxr.update(1 / 60)
local young = pushed(14, 0)
for _ = 1, 26 do fxr.update(1 / 60) end
local old_r = 0
for probe = 4, 140, 2 do old_r = math.max(old_r, pushed(probe, 0)) end
check("a dying wave bends less than a fresh one", old_r < young,
      string.format("%.2f then %.2f", young, old_r))

-- Only the loudest few, however many are going off: a fleet fight cannot pay
-- for a walk of every wave per star.
fxr.reset()
for k = 1, 30 do fxr.wave(k * 400, 0, 4, 90, 0.5, 10, COL) end
fxr.update(1 / 60)
local bent = 0
for k = 1, 30 do
    if pushed(k * 400 + 14, 0) > 0 then bent = bent + 1 end
end
check("the ripple count is capped", bent > 0 and bent <= 6, tostring(bent))

-- --- the blast feeds the light ---------------------------------------------

package.loaded["arena.sfx"] = {play = function() end}
local fx = require("arena.fx")
fx.reset()
fx.wave(300, 300, 4, 60, 0.4, 8, COL)
local lit = nil
fx.draw({ring_fade = function() end},
        function(x, y, _, s, reach) lit = {x = x, y = y, s = s, r = reach} end)
check("a shockwave declares itself a light", lit ~= nil)
check("at its own place", lit and lit.x == 300 and lit.y == 300)
check("with its strength tied to its fade", lit and lit.s > 0 and lit.s <= 0.9,
      lit and tostring(lit.s))

if fails > 0 then
    print(fails .. " failed")
    os.exit(1)
end
print("all ok")
