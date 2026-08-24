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

-- A one-tile rail is too shallow for a row of enclosed access capsules. It
-- gets sparse open fittings instead, with bare stretches doing most of the
-- work.
local function count_pill_panels(name)
    local n = 0
    for _, args in ipairs(calls[name .. ":fan"] or {}) do
        local pts = args[1]
        local min_x, max_x = pts[1], pts[1]
        local min_y, max_y = pts[2], pts[2]
        for i = 3, #pts, 2 do
            min_x, max_x = math.min(min_x, pts[i]), math.max(max_x, pts[i])
            min_y = math.min(min_y, pts[i + 1])
            max_y = math.max(max_y, pts[i + 1])
        end
        local wide, deep = max_x - min_x, max_y - min_y
        if #pts == 16
           and math.max(wide, deep) > math.min(wide, deep) * 1.6 then
            n = n + 1
        end
    end
    return n
end

local world = reset()
for x = 10, 140 do put(x, 12, T_SOLID, 0) end
world.build_static(writer("fill"), writer("glow"), 6, 8, 144, 16)
local panels = count("fill:fan")
local mounts = count("fill:quad")
local beams = count("fill:seg")
local pill_panels = count_pill_panels("fill")
check("a thin rail carries no enclosed pill panels", pill_panels == 0,
      pill_panels .. " pill panels")
check("a thin rail mixes square mounts and open beams",
      mounts > 0 and beams > 0,
      panels .. "/" .. mounts .. "/" .. beams .. " treatments")
check("wall machinery does not fall back to circular fittings",
      count("glow:disc") == 0 and count("glow:ring") == 0,
      count("glow:disc") .. "/" .. count("glow:ring") .. " circles")

local odd_angles = 0
for _, seg in ipairs(calls["glow:seg"] or {}) do
    local dx = math.abs(seg[3] - seg[1])
    local dy = math.abs(seg[4] - seg[2])
    if dx > 0.001 and dy > 0.001 and math.abs(dx - dy) > 0.001 then
        odd_angles = odd_angles + 1
    end
end
check("wall lines use only 45 and 90 degree angles", odd_angles == 0,
      odd_angles .. " off-angle lines")

world = reset()
for y = 10, 140 do put(12, y, T_SOLID, 0) end
world.build_static(writer("vertical-fill"), writer("vertical-glow"),
                   8, 6, 16, 144)
check("a vertical thin rail also avoids pill panels",
      count_pill_panels("vertical-fill") == 0,
      count_pill_panels("vertical-fill") .. " pill panels")

-- Thick armor has room for real machines. A long face must change silhouette
-- from one occupied slot to the next; a shuffled row of identical pipes is
-- still a repeated pattern.
local function thick_wall(y0, y1)
    for y = y0, y1 do
        for x = 0, 160 do put(x, y, T_SOLID, 0) end
    end
end

local function top_module_signatures(name, face_y, pitch, max_depth)
    local slots = {}
    local function add(method, coords)
        local min_y, max_y = coords[2], coords[2]
        local sum_x = 0
        for i = 1, #coords, 2 do
            sum_x = sum_x + coords[i]
            min_y = math.min(min_y, coords[i + 1])
            max_y = math.max(max_y, coords[i + 1])
        end
        if min_y < face_y or max_y > face_y + max_depth then return end
        local slot = math.floor((sum_x / (#coords / 2)) / pitch)
        slots[slot] = slots[slot] or {}
        slots[slot][#slots[slot] + 1] = {method, coords}
    end

    for _, spec in ipairs({
        {name .. ":fan", "fan", "points"},
        {name .. ":quad", "quad", 8},
        {name .. ":seg", "seg", 4},
    }) do
        for _, args in ipairs(calls[spec[1]] or {}) do
            local coords = {}
            if spec[3] == "points" then
                for i = 1, #args[1] do coords[i] = args[1][i] end
            else
                for i = 1, spec[3] do coords[i] = args[i] end
            end
            add(spec[2], coords)
        end
    end

    local out = {}
    for slot, shapes in pairs(slots) do
        local min_x = math.huge
        for _, shape in ipairs(shapes) do
            for i = 1, #shape[2], 2 do
                min_x = math.min(min_x, shape[2][i])
            end
        end
        local parts = {}
        for _, shape in ipairs(shapes) do
            local part = {shape[1]}
            for i = 1, #shape[2], 2 do
                part[#part + 1] = string.format("%.2f", shape[2][i] - min_x)
                part[#part + 1] = string.format("%.2f", shape[2][i + 1]
                                                - face_y)
            end
            parts[#parts + 1] = table.concat(part, ",")
        end
        table.sort(parts)
        out[#out + 1] = {slot, table.concat(parts, "|")}
    end
    table.sort(out, function(a, b) return a[1] < b[1] end)
    return out
end

world = reset()
thick_wall(20, 23)
world.build_static(writer("thick-fill"), writer("thick-glow"),
                   0, 16, 160, 28)
local thick_modules = top_module_signatures("thick-fill", 20 * 16, 256, 28)
local repeats = 0
local unique = {}
for i, module in ipairs(thick_modules) do
    unique[module[2]] = true
    if i > 1 and module[2] == thick_modules[i - 1][2] then
        repeats = repeats + 1
    end
end
local unique_n = 0
for _ in pairs(unique) do unique_n = unique_n + 1 end
check("a thick wall changes machine silhouette at every occupied slot",
      #thick_modules >= 5 and repeats == 0 and unique_n >= 4,
      #thick_modules .. " modules, " .. unique_n .. " shapes, "
      .. repeats .. " repeats")

-- The thick map boundary uses the same machinery at a slower rhythm. It is a
-- calmer wall, not an undecorated void between two bright collision lines.
world = reset()
for y = 12, 13 do
    for x = 10, 140 do put(x, y, T_SOLID, 1) end
end
world.build_static(writer("border-fill"), writer("border-glow"),
                   6, 8, 144, 17)
local border_parts = count("border-fill:fan")
                     + count("border-fill:quad")
                     + count("border-fill:seg")
check("a perimeter mass carries sparse service bays",
      border_parts >= 8 and border_parts <= 36
      and count("border-fill:fan") > 0 and count("border-fill:seg") > 0,
      border_parts .. " parts")

-- Static terrain is a moving window over one fixed map. A wall pattern that
-- is seeded from the clipped run changes when that window moves, even though
-- the wall did not. Compare the decorations well inside two overlapping
-- windows, where both builds must produce the same geometry.
local function shape_keys(fill_name, glow_name, x0, x1)
    local out = {}
    local function add(method, coords)
        local lo, hi = coords[1], coords[1]
        for i = 3, #coords, 2 do
            lo, hi = math.min(lo, coords[i]), math.max(hi, coords[i])
        end
        if lo >= x0 and hi <= x1 then
            local parts = {method}
            for i = 1, #coords do
                parts[#parts + 1] = string.format("%.2f", coords[i])
            end
            out[#out + 1] = table.concat(parts, ",")
        end
    end

    for _, spec in ipairs({
        {fill_name .. ":fan", "fan", "points"},
        {fill_name .. ":quad", "quad", 8},
        {fill_name .. ":seg", "fill-seg", 4},
        {glow_name .. ":outline", "outline", "points"},
        {glow_name .. ":seg", "glow-seg", 4},
    }) do
        for _, args in ipairs(calls[spec[1]] or {}) do
            local coords = {}
            if spec[3] == "points" then
                for i = 1, #args[1] do coords[i] = args[1][i] end
            else
                for i = 1, spec[3] do coords[i] = args[i] end
            end
            add(spec[2], coords)
        end
    end
    table.sort(out)
    return out
end

local function same_list(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

world = reset()
thick_wall(20, 23)
world.build_static(writer("stable-a-fill"), writer("stable-a-glow"),
                   0, 16, 100, 28)
local stable_a = shape_keys("stable-a-fill", "stable-a-glow",
                            40 * 16, 84 * 16)
world = reset()
thick_wall(20, 23)
world.build_static(writer("stable-b-fill"), writer("stable-b-glow"),
                   24, 16, 124, 28)
local stable_b = shape_keys("stable-b-fill", "stable-b-glow",
                            40 * 16, 84 * 16)
check("a thick wall keeps its pattern when the terrain window moves",
      #stable_a > 6 and same_list(stable_a, stable_b),
      #stable_a .. "/" .. #stable_b .. " overlapping shapes")

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
