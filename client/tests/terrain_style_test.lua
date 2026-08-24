-- The terrain proposal's structural promises.
--
--     lua5.1 client/tests/terrain_style_test.lua
--
-- A screenshot decides whether the treatment looks good. These checks protect
-- the less subjective parts: walls carry no decorative geometry, a rock has
-- internal structure instead of one flat fan, and a station paints every
-- pixel its six-tile collision stamp occupies.

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
local map_w, map_h = 1024, 1024
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
        if x < 0 or y < 0 or x >= map_w or y >= map_h then
            return T_SOLID, 1
        end
        local t = tiles[key(x, y)]
        return t and t[1] or T_EMPTY, t and t[2] or 0
    end,
    map_size = function() return map_w, map_h end,
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

-- Walls are plain masses. Rectangles paint the collision footprint, while
-- skirts, edge lines, and corner chamfers make its boundary readable. No
-- panels, fittings, warning marks, or interior seams belong on either depth.
local function check_plain_wall(label, fill_name, glow_name,
                                cell_count, edge_segments, skirts)
    local rects = count(fill_name .. ":rect")
    local segs = count(glow_name .. ":seg")
    local skirt_count = count(glow_name .. ":skirt")
    local allowed = {
        [fill_name .. ":rect"] = true,
        [fill_name .. ":reset"] = true,
        [fill_name .. ":flush"] = true,
        [glow_name .. ":seg"] = true,
        [glow_name .. ":skirt"] = true,
        [glow_name .. ":reset"] = true,
        [glow_name .. ":flush"] = true,
    }
    local unexpected = {}
    for name, list in pairs(calls) do
        local is_fill = name:sub(1, #fill_name + 1) == fill_name .. ":"
        local is_glow = name:sub(1, #glow_name + 1) == glow_name .. ":"
        if (is_fill or is_glow) and not allowed[name] and #list > 0 then
            unexpected[#unexpected + 1] = name .. "=" .. #list
        end
    end
    table.sort(unexpected)
    check(label .. " has no decoration",
          rects == cell_count and segs == edge_segments
          and skirt_count == skirts and #unexpected == 0,
          string.format("%d rects, %d segs, %d skirts%s",
                        rects, segs, skirt_count,
                        #unexpected > 0
                            and ", unexpected " .. table.concat(unexpected, ", ")
                            or ""))
end

local world = reset()
for x = 10, 140 do put(x, 12, T_SOLID, 0) end
world.build_static(writer("thin-fill"), writer("thin-glow"), 6, 8, 144, 16)
check_plain_wall("a horizontal thin wall", "thin-fill", "thin-glow",
                 131, 10, 6)

world = reset()
for y = 10, 140 do put(12, y, T_SOLID, 0) end
world.build_static(writer("vertical-fill"), writer("vertical-glow"),
                   8, 6, 16, 144)
check_plain_wall("a vertical thin wall", "vertical-fill", "vertical-glow",
                 131, 10, 6)

world = reset()
for y = 20, 23 do
    for x = 0, 160 do put(x, y, T_SOLID, 0) end
end
world.build_static(writer("thick-fill"), writer("thick-glow"),
                   0, 16, 160, 28)
check_plain_wall("a thick wall", "thick-fill", "thick-glow",
                 644, 12, 8)

world = reset()
for y = 12, 13 do
    for x = 10, 140 do put(x, y, T_SOLID, 1) end
end
world.build_static(writer("border-fill"), writer("border-glow"),
                   6, 8, 144, 17)
check_plain_wall("a perimeter wall", "border-fill", "border-glow",
                 262, 12, 8)

-- Mapgen lays a diagonal a step at a time, a leaning pair of slopes per row,
-- and each half of a pair hands its whole square side to the half beside it
-- and to the pair on the next row. That chain leaves exactly two square sides
-- open, one at the top of the run and one at the bottom, and those are the
-- only ends the mass has. Undrawn, a diagonal standing in open space is an
-- outline with both of them missing.
local NW, NE, SE, SW = 0, 1, 2, 3
local function arm(ox, oy, n, lean)
    for i = 0, n - 1 do
        local x, y = ox + i, oy + i
        local a, b = NE, SW
        if lean == "up" then x, a, b = ox + n - 1 - i, SE, NW end
        -- Where two arms cross, the tile is already taken and goes solid, the
        -- way m_slope_step in sim/tools/mapgen.c writes it.
        for j, v in ipairs({a, b}) do
            local fx = x + j - 1
            if tiles[key(fx, y)] then put(fx, y, T_SOLID, 0)
            else put(fx, y, T_SLOPE, v) end
        end
    end
end

local function seg_drawn(name, x1, y1, x2, y2)
    for _, g in ipairs(calls[name] or {}) do
        if g[1] == x1 and g[2] == y1 and g[3] == x2 and g[4] == y2 then
            return true
        end
    end
    return false
end

world = reset()
arm(10, 10, 5, "up")
world.build_static(writer("diag-fill"), writer("diag-glow"), 6, 6, 20, 20)
-- The two faces, then a cap across the top of the run and one across its
-- bottom, each a tile wide on the row the run stops on.
check("a lone diagonal is drawn as a closed outline",
      count("diag-glow:seg") == 4, count("diag-glow:seg") .. " lit lines")
check("a lone diagonal is capped at its top",
      seg_drawn("diag-glow:seg", 240, 160, 256, 160))
check("a lone diagonal is capped at its bottom",
      seg_drawn("diag-glow:seg", 160, 240, 176, 240))

-- An end that runs into a wall is not an end. The wall has that leg, so a cap
-- there would be a line drawn through the middle of one solid mass.
world = reset()
arm(10, 10, 5, "down")
for x = 8, 12 do put(x, 9, T_SOLID, 0) end
world.build_static(writer("met-fill"), writer("met-glow"), 6, 6, 20, 20)
check("a diagonal meeting a wall is not capped there",
      not seg_drawn("met-glow:seg", 160, 160, 176, 160))
check("its free end is still capped",
      seg_drawn("met-glow:seg", 240, 240, 256, 240))

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

-- Outside a map's declared rectangle the core reports solid to make collision
-- safe. That sentinel is not terrain. Sampling it made the radar paint the
-- off-map half of a small room as one large wall.
world = reset()
map_w, map_h = 41, 31
world.build_static(writer("edge-fill"), writer("edge-glow"),
                   34, 24, 50, 40)
local outside = false
for i = 1, #world.radar_tiles, 2 do
    if world.radar_tiles[i] >= map_w * 16
       or world.radar_tiles[i + 1] >= map_h * 16 then
        outside = true
        break
    end
end
check("the radar does not paint the off-map solid sentinel", not outside)

os.exit(fails == 0 and 0 or 1)
