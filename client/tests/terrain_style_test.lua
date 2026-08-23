-- The terrain proposal's structural promises.
--
--     lua5.1 client/tests/terrain_style_test.lua
--
-- A screenshot decides whether the treatment looks good. These checks protect
-- the less subjective parts: long walls carry hardware, a rock has internal
-- structure instead of one flat fan, and a station paints every pixel its
-- six-tile collision stamp occupies.

package.path = "client/?.lua;" .. package.path

local fails = 0
local function check(name, ok, detail)
    if ok then
        print("ok   " .. name)
    else
        fails = fails + 1
        print("FAIL " .. name .. (detail and ("  " .. detail) or ""))
    end
end

local T_EMPTY, T_SOLID, T_SAFE, T_DOOR = 0, 1, 2, 3
local T_GOAL, T_WORMHOLE, T_OVER, T_UNDER = 4, 5, 6, 7
local T_TURF, T_SPAWN, T_SLOPE = 8, 9, 10

local tiles = {}
local function key(x, y) return y * 1024 + x end
local function put(x, y, class, variant)
    tiles[key(x, y)] = {class, variant or 0}
end

_G.sim = {
    T_SOLID = T_SOLID, T_SAFE = T_SAFE, T_DOOR = T_DOOR,
    T_GOAL = T_GOAL, T_WORMHOLE = T_WORMHOLE,
    T_OVER = T_OVER, T_UNDER = T_UNDER, T_TURF = T_TURF,
    T_SPAWN = T_SPAWN, T_SLOPE = T_SLOPE,
    tile = function(x, y)
        local t = tiles[key(x, y)]
        return t and t[1] or T_EMPTY, t and t[2] or 0
    end,
    show_spawns = function() return false end,
    h = function() return 0 end,
}

package.loaded["arena.fx"] = setmetatable({}, {
    __index = function() return function() end end,
})

local calls = {}
local function writer(name)
    local w = {}
    setmetatable(w, {__index = function(_, method)
        return function(_, ...)
            local list = calls[name .. ":" .. method] or {}
            list[#list + 1] = {...}
            calls[name .. ":" .. method] = list
        end
    end})
    return w
end

local function count(name) return #(calls[name] or {}) end
local function reset()
    calls, tiles = {}, {}
    package.loaded["arena.world"] = nil
    return require("arena.world")
end

-- A long face needs fittings that break its length into readable modules.
local world = reset()
for x = 10, 30 do put(x, 12, T_SOLID, 0) end
world.build_static(writer("fill"), writer("glow"), 6, 8, 34, 16)
check("a long bulkhead has hardware nodes", count("glow:disc") > 0,
      count("glow:disc") .. " nodes")

-- A big rock is still one collision object, but it is no longer one flat
-- polygon. Facet triangles, ridges, pits, and a mineral seam give it volume.
world = reset()
put(20, 20, T_SOLID, 4)
world.build_static(writer("static-fill"), writer("static-glow"), 16, 16, 24, 24)
calls = {}
world.draw_rocks(writer("rock-fill"), writer("rock-glow"), 1.25,
                 {x0 = 0, y0 = 0, x1 = 10000, y1 = 10000})
check("a big rock has a faceted body", count("rock-fill:tri") >= 11,
      count("rock-fill:tri") .. " facets")
check("a big rock has crater relief", count("rock-fill:disc") >= 2,
      count("rock-fill:disc") .. " pits")
check("a big rock has internal fracture lines",
      count("rock-fill:seg") > 0 and count("rock-glow:seg") > 0,
      count("rock-fill:seg") .. "/" .. count("rock-glow:seg") .. " lines")

-- The station stamp is a 6 by 6 solid square. The renderer must cover that
-- exact footprint before it adds bays and reactor detail.
world = reset()
put(40, 30, T_SOLID, 6)
world.build_static(writer("station-fill"), writer("station-glow"),
                   36, 26, 50, 40)
local full = false
for _, r in ipairs(calls["station-fill:rect"] or {}) do
    if r[1] == 40 * 16 and r[2] == 30 * 16 and r[3] == 96 and r[4] == 96 then
        full = true
        break
    end
end
check("a station paints its whole collision footprint", full)
check("a station has a reactor and service rings",
      count("station-glow:ring") >= 2 and count("station-glow:disc") >= 5,
      count("station-glow:ring") .. "/" .. count("station-glow:disc"))

os.exit(fails == 0 and 0 or 1)
