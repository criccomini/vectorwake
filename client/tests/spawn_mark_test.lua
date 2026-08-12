-- Whether the map's spawn tiles get a mark on them.
--
--     lua5.1 client/tests/spawn_mark_test.lua
--
-- Two rings on a spawn tile say where a pilot is about to appear, give or take
-- whatever `spawn_radius` the zone set. A zone can want that kept quiet, and it
-- is not a hypothetical preference: the mark is drawn for every spawn on the
-- map, the enemy's included and in the enemy's color, so anybody flying can
-- read where the other side comes back.
--
-- What is checked here is that the drawing asks the core and obeys the answer.
-- Where a ship actually lands is checked in sim/tests/test_sim.c.

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

-- --- a recording writer ----------------------------------------------------
--
-- Only rings are kept. The spawn mark is the one thing in an otherwise empty
-- window that draws any, so counting them is enough to tell the two cases
-- apart without pinning the drawing's geometry, which marks_test's neighbours
-- already do for the shapes that have to hold still.

local rings = {}
local function writer()
    local w = {}
    setmetatable(w, {__index = function(_, k)
        if k == "ring" then
            return function(_, x, y, r) rings[#rings + 1] = {x = x, y = y, r = r} end
        end
        return function() end
    end})
    return w
end

-- --- a window with one spawn in it -----------------------------------------

local TILE = 16
local T_EMPTY, T_SOLID, T_SAFE, T_DOOR = 0, 1, 2, 3
local T_WORMHOLE, T_OVER, T_UNDER = 5, 6, 7
local T_TURF, T_SPAWN, T_GOAL = 8, 9, 4

local SPAWN_TX, SPAWN_TY = 20, 20

local function make_sim(show)
    return {
        T_SOLID = T_SOLID, T_SAFE = T_SAFE, T_DOOR = T_DOOR,
        T_WORMHOLE = T_WORMHOLE, T_OVER = T_OVER, T_UNDER = T_UNDER,
        T_TURF = T_TURF, T_SPAWN = T_SPAWN, T_GOAL = T_GOAL,
        -- One spawn tile for team 0 and nothing else, so the window draws no
        -- walls, no safe ground and no doors to put rings on the board.
        tile = function(tx, ty)
            if tx == SPAWN_TX and ty == SPAWN_TY then return T_SPAWN, 0 end
            return T_EMPTY, 0
        end,
        show_spawns = function() return show end,
        h = function() return 0 end,
    }
end

package.loaded["arena.fx"] = setmetatable({}, {
    __index = function() return function() end end,
})

local function draw(show)
    rings = {}
    _G.sim = make_sim(show)
    package.loaded["arena.world"] = nil
    local world = require("arena.world")
    world.my_team = 0
    world.build_static(writer(), writer(),
                       SPAWN_TX - 4, SPAWN_TY - 4, SPAWN_TX + 4, SPAWN_TY + 4)
    return rings
end

-- --- what it draws ---------------------------------------------------------

local on = draw(true)
check("a spawn tile is marked when the zone says so", #on > 0,
      "no rings drawn")

-- The mark sits on the middle of its tile rather than the corner, which is
-- also where the core now puts the ship that arrives on it.
local centered = false
for _, r in ipairs(on) do
    if r.x == SPAWN_TX * TILE + TILE / 2
        and r.y == SPAWN_TY * TILE + TILE / 2 then
        centered = true
    end
end
check("and sits on the middle of its tile", centered)

local off = draw(false)
check("and is not drawn when it says not to", #off == 0,
      #off .. " rings survived")

-- The gate is the collection, not the drawing, so an unmarked spawn costs no
-- geometry rather than geometry nobody sees.
check("the two cases differ only by the mark", #on > #off)

os.exit(fails == 0 and 0 or 1)
