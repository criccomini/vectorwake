-- The map view's rectangles, against the map they came from.
--
--     lua5.1 client/tests/overview_test.lua
--
-- Run under plain Lua 5.1, which is what HTML5 builds run, with the engine
-- stubbed out. This exists because what it covers is a greedy merge over a
-- thousand tiles: it is right or it is a map with holes in it, and the only
-- other way to find out is to look at three arenas on a screen and try to
-- remember what their walls are supposed to be.
--
-- The maps are the ones the fleet serves, read out of the catalog rather than
-- written down here, so a reconverted map is a map this test immediately
-- covers.

package.path = "client/?.lua;" .. package.path

local TILES = 1024
local CELL = 4

-- The tile classes, which the extension publishes to Lua from sim.h.
local T_EMPTY, T_SOLID, T_SAFE, T_DOOR = 0, 1, 2, 3
local T_WORMHOLE = 5

-- A `.vwmap` is a ten-byte header and then three-byte runs of length and tile,
-- which is `sim_map_pack` in sim/src/pack.c.
local function tiles_of(path)
    local f = assert(io.open(path, "rb"), "run me from the repository root")
    local src = f:read("*a")
    f:close()
    local byte = string.byte
    assert(src:sub(1, 4) == "PAMV", path .. " is not a packed map")
    local out, n = {}, 0
    local at = 11
    while at + 2 <= #src and n < TILES * TILES do
        local run = byte(src, at) + byte(src, at + 1) * 256
        local v = byte(src, at + 2)
        for _ = 1, run do
            n = n + 1
            out[n] = v % 16
        end
        at = at + 3
    end
    assert(n == TILES * TILES, path .. " decoded to " .. n .. " tiles")
    return out
end

-- What `MapCoarse` in simcore.cpp hands over: one byte per cell, holding the
-- most important tile standing in it.
local RANK = {[T_SOLID] = 4, [T_DOOR] = 3, [T_SAFE] = 2, [T_WORMHOLE] = 1}
local function coarse(tiles, cell)
    local g = TILES / cell
    local grid = {}
    for i = 1, g * g do grid[i] = T_EMPTY end
    for ty = 0, TILES - 1 do
        local row = ty * TILES
        local grow = math.floor(ty / cell) * g
        for tx = 0, TILES - 1 do
            local cls = tiles[row + tx + 1]
            local i = grow + math.floor(tx / cell) + 1
            if (RANK[cls] or 0) > (RANK[grid[i]] or 0) then grid[i] = cls end
        end
    end
    return grid, g
end

local fails = 0
local function check(desc, ok, why)
    if not ok then fails = fails + 1 end
    print(string.format("%-46s %s", desc, ok and "ok" or ("FAIL: " .. why)))
end

-- Every map the catalog ships, which is the melee zone's two.
for _, name in ipairs({"melee/drydock", "melee/slipway"}) do
    local grid, g = coarse(tiles_of("catalog/zones/" .. name .. ".vwmap"), CELL)
    local bytes = {}
    for i = 1, g * g do bytes[i] = string.char(grid[i]) end
    local packed = table.concat(bytes)

    _G.sim = {
        T_SOLID = T_SOLID, T_SAFE = T_SAFE, T_DOOR = T_DOOR,
        T_WORMHOLE = T_WORMHOLE,
        map_coarse = function(cell)
            assert(cell == CELL, "the view asked for a grain this test has not built")
            return packed, g
        end,
    }
    package.loaded["arena.world"] = nil
    local world = require("arena.world")
    world.build_overview()
    local ov = world.overview

    -- Paint the rectangles back into a grid. Every cell has to end up holding
    -- what the map put there, which catches both halves of a bad merge: a
    -- rectangle that reaches past its run leaves a cell wrong, and one that
    -- stops short leaves a cell empty.
    local painted = {}
    local overlap = nil
    for i = 1, ov.n, 5 do
        local x, y, w, h, cls = ov.rect[i], ov.rect[i + 1], ov.rect[i + 2],
                                ov.rect[i + 3], ov.rect[i + 4]
        for yy = y, y + h - 1 do
            for xx = x, x + w - 1 do
                local k = yy * g + xx + 1
                if painted[k] and not overlap then
                    overlap = string.format("cell %d,%d covered twice", xx, yy)
                end
                painted[k] = cls
            end
        end
    end

    local wrong, missing, extra = nil, 0, 0
    for k = 1, g * g do
        local want = grid[k]
        if RANK[want] == nil then want = T_EMPTY end
        local got = painted[k] or T_EMPTY
        if got ~= want then
            if got == T_EMPTY then missing = missing + 1
            elseif want == T_EMPTY then extra = extra + 1
            elseif not wrong then
                wrong = string.format("cell %d holds %d, wanted %d", k, got, want)
            end
        end
    end

    local n = ov.n / 5
    print(string.format("== %s: %dx%d grid, %d rectangles, %d vertices",
                        name, g, g, n, n * 6))
    check(name .. ": every cell is covered", missing == 0,
          missing .. " cells the map fills are not drawn")
    check(name .. ": nothing is drawn over empty ground", extra == 0,
          extra .. " cells drawn where the map is empty")
    check(name .. ": every cell holds its own class", wrong == nil,
          tostring(wrong))
    check(name .. ": no cell is drawn twice", overlap == nil, tostring(overlap))
    -- The interface layer holds 24576 vertices and the rest of the HUD was
    -- measured at 3639 of them. A map that needs more than this is a map that
    -- silently loses its far side, since a layer past its cap simply stops
    -- writing.
    check(name .. ": fits the interface layer", n * 6 <= 24576 - 4096,
          n * 6 .. " vertices leaves nothing for the rest of the interface")
end

print(fails == 0 and "all ok" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
