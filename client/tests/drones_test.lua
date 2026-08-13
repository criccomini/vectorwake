-- The drones a carrier's gunners draw as.
--
--     lua5.1 client/tests/drones_test.lua
--
-- `world.drones` is handed a flat list of four entries per gunner -- heading,
-- energy fraction, color, whether it is yours -- and the caller that fills it
-- is in arena.script, which no test loads. So the stride is a contract between
-- two files with nothing holding them together, and getting it wrong does not
-- throw: it reads a color as a heading and puts a drone somewhere plausible.
--
-- What this pins is the arithmetic that can be checked without eyes. A drone
-- sits on a ring in the direction its gunner is aiming, so its bearing from
-- the hull is that heading and its distance is the same for every gunner on
-- the hull whatever they are doing. That is the whole geometric claim, and it
-- is the one that broke twice while it was being drawn.

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

_G.sim = {
    MAX_CHARGES = 2,
    ship_count = function() return 0 end,
    ship_alive = function() return 1 end,
    ship_carrier = function() return 255 end,
    ship_energy = function(i) return i == 1 and 25 or 100 end,
    ship_max_energy = function() return 100 end,
    -- Energy remains public even when the rest of this ship's state does not.
    ship_private = function() return false end,
    weapon_count = function() return 0 end,
}
package.loaded["arena.fx"] = setmetatable({}, {
    __index = function() return function() end end,
})

local world = require("arena.world")
local pal = require("arena.palette")

check("a remote ship exposes its public energy fraction",
      world.energy_fraction(1) == 0.25)

-- A layer that records where it was asked to draw rather than drawing. Every
-- primitive lands as a point, which is all this test reads.
local function recorder()
    local L = {pts = {}}
    local function note(x, y) L.pts[#L.pts + 1] = {x = x, y = y} end
    L.fan = function(_, q)
        for i = 1, #q, 2 do note(q[i], q[i + 1]) end
    end
    L.outline = function(_, q) L.fan(nil, q) end
    L.seg = function(_, x1, y1, x2, y2) note(x1, y1) note(x2, y2) end
    L.disc = function(_, x, y) note(x, y) end
    L.halo = function(_, x, y) note(x, y) end
    L.tri = function() end
    L.rect = function() end
    return L
end

-- The middle of every point a drone drew, which is near enough its center for
-- a bearing and a radius.
local function center(pts)
    local sx, sy = 0, 0
    for _, p in ipairs(pts) do sx = sx + p.x; sy = sy + p.y end
    return sx / #pts, sy / #pts
end

local UP, RIGHT = 0, 16384          -- headings: 0 is up, a quarter is right
local X, Y = 500, 400
local APEX = 0

-- One gunner, aiming up. Its drone is above the hull, not beside it.
do
    local g = recorder()
    world.drones(nil, g, APEX, X, Y, {UP, 1.0, pal.FRIEND, false})
    local cx, cy = center(g.pts)
    check("a drone aiming up sits above the hull", cy < Y - 4,
          string.format("cy=%.1f against y=%d", cy, Y))
    check("and on the hull's own axis", math.abs(cx - X) < 1.5,
          string.format("cx=%.1f against x=%d", cx, X))
end

-- The same gunner aiming right. Same distance, quarter turn around.
do
    local up, right = recorder(), recorder()
    world.drones(nil, up, APEX, X, Y, {UP, 1.0, pal.FRIEND, false})
    world.drones(nil, right, APEX, X, Y, {RIGHT, 1.0, pal.FRIEND, false})
    local ux, uy = center(up.pts)
    local rx, ry = center(right.pts)
    local ur = math.sqrt((ux - X) ^ 2 + (uy - Y) ^ 2)
    local rr = math.sqrt((rx - X) ^ 2 + (ry - Y) ^ 2)
    check("turning walks a drone around the ring", rx > X + 4 and ry < Y + 4,
          string.format("(%.1f, %.1f)", rx - X, ry - Y))
    check("without changing how far out it is", math.abs(ur - rr) < 0.6,
          string.format("%.2f against %.2f", ur, rr))
end

-- Five gunners are five drones, and a stride that slipped would lose or
-- invent one.
do
    local one, five = recorder(), recorder()
    world.drones(nil, one, APEX, X, Y, {UP, 1.0, pal.FRIEND, false})
    local many = {}
    for k = 0, 4 do
        many[#many + 1] = k * 13000
        many[#many + 1] = 1.0
        many[#many + 1] = pal.FRIEND
        many[#many + 1] = false
    end
    world.drones(nil, five, APEX, X, Y, many)
    check("five gunners draw five drones", #five.pts == 5 * #one.pts,
          string.format("%d points against %d", #five.pts, #one.pts))
end

-- Nobody aboard draws nothing at all, which is the rule that a carrier looks
-- like any other ship.
do
    local g = recorder()
    world.drones(nil, g, APEX, X, Y, {})
    check("an empty carrier draws nothing", #g.pts == 0)
end

-- Yours is marked. Whatever the marking is, it cannot be nothing: riding
-- takes your hull off the screen, so this is the only thing that says which
-- drone you are.
do
    local theirs, mine = recorder(), recorder()
    world.drones(nil, theirs, APEX, X, Y, {UP, 1.0, pal.FRIEND, false})
    world.drones(nil, mine, APEX, X, Y, {UP, 1.0, pal.FRIEND, true})
    check("your own drone is drawn differently", #mine.pts > #theirs.pts,
          string.format("%d points against %d", #mine.pts, #theirs.pts))
end

-- The ring is the hull's, so a long hull and a compact one do not wear the
-- same one.
do
    local apex, anvil = recorder(), recorder()
    world.drones(nil, apex, 0, X, Y, {UP, 1.0, pal.FRIEND, false})
    world.drones(nil, anvil, 3, X, Y, {UP, 1.0, pal.FRIEND, false})
    local _, ay = center(apex.pts)
    local _, ny = center(anvil.pts)
    check("the ring is sized per hull", math.abs(ay - ny) > 0.5,
          string.format("apex %.1f, anvil %.1f", Y - ay, Y - ny))
end

if fails == 0 then print("all tests passed") end
os.exit(fails > 0 and 1 or 0)
