-- The prizes lying on the ground in a free roam zone.
--
--     lua5.1 client/tests/greens_test.lua
--
-- Two dozen greens is six times what a flag game puts on a map, and every one
-- of them draws onto the same bounded glow layer the shots and the hulls use.
-- So what this holds is the culling: a field of greens on the far side of a
-- thousand-tile map must not cost a round fired on this side of it. The rest
-- is the plain reading of the wire, that an inactive slot draws nothing and an
-- active one draws a shape.

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

-- --- the field, as this test arranges it -----------------------------------

local field = {}

_G.sim = {
    green_count = function() return #field end,
    green_at = function(i)
        local g = field[i + 1]
        return g.x, g.y, g.slot, g.active
    end,
    -- world.lua reads these at load; nothing here exercises them.
    ship_count = function() return 0 end,
    flag_count = function() return 0 end,
    weapon_count = function() return 0 end,
    map_w = function() return 1024 end,
    map_h = function() return 1024 end,
    T_EMPTY = 0, T_SOLID = 1, T_SAFE = 2, T_DOOR = 3, T_GOAL = 4,
    T_WORMHOLE = 5, T_OVER = 6, T_UNDER = 7, T_TURF = 8, T_SPAWN = 9,
    T_SLOPE = 10,
    EV_FIRE = 1, EV_BOUNCE = 2, EV_HIT = 3, EV_DEATH = 4, EV_SPAWN = 5,
    EV_EXPIRE = 6, EV_FLAG_TAKE = 8, EV_FLAG_DROP = 9, EV_CHARGE = 7,
    EV_GREEN = 15,
}

-- A layer that counts what was asked of it rather than drawing it.
local function layer()
    local l = {calls = 0}
    local function count() l.calls = l.calls + 1 end
    l.fan, l.outline, l.halo = count, count, count
    l.seg, l.tri, l.quad, l.rect, l.disc, l.ring = count, count, count, count, count, count
    l.tri_fade, l.glow_band = count, count
    return l
end

local ok, world = pcall(require, "arena.world")
if not ok then
    print("FAIL could not load arena.world  -- " .. tostring(world))
    os.exit(1)
end

local function draw(cull)
    local fill, glow = layer(), layer()
    world.greens(fill, glow, 0.0, cull)
    return fill.calls + glow.calls
end

-- The whole map, so nothing is culled for being far away.
local WIDE = {x0 = -1e6, x1 = 1e6, y0 = -1e6, y1 = 1e6}

field = {{x = 100, y = 100, slot = 0, active = true}}
check("an active green draws", draw(WIDE) > 0)

field = {{x = 100, y = 100, slot = 0, active = false}}
check("a green that has been taken draws nothing", draw(WIDE) == 0)

-- Every green in the field, and the same field with one of them off screen.
field = {}
for i = 1, 24 do
    field[i] = {x = 100 + i, y = 100, slot = i % 5, active = true}
end
local all = draw(WIDE)
check("two dozen of them all draw", all > 24)

local NARROW = {x0 = 0, x1 = 110, y0 = 0, y1 = 200}
local some = draw(NARROW)
check("and the ones off screen cost nothing", some < all, all .. " -> " .. some)

field = {{x = 9000, y = 9000, slot = 0, active = true}}
check("a green on the far side of the map draws nothing", draw(NARROW) == 0)

os.exit(fails == 0 and 0 or 1)
