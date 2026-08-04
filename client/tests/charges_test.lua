-- Somebody else's repel, drawn from their charge count going down.
--
--     lua5.1 client/tests/charges_test.lua
--
-- A repel lives one tick, so it reaches the state a snapshot is packed from
-- only when the tick it was fired on happens to be a snapshot tick: one time
-- in five at 20 Hz over a 100 Hz simulation. The other four a watcher is sent
-- no weapon and no expiry, and the shove arrives with nothing attached to it.
-- `server/src/main.rs` pins that fact from the other side.
--
-- So `world.charges` reads the firer's inventory instead. What it must not do
-- is fire on everything else that moves a charge count: your own hull, which
-- your own simulation already draws; a pilot picking a charge up; a seat
-- emptying or filling as somebody leaves and somebody else arrives; or a
-- charge like the burst, which puts twenty-four rounds in the air and needs no
-- help being seen. Each of those drew a shockwave at some point while this was
-- being written.

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

-- --- the room, as this test arranges it ------------------------------------

-- Slot 0 is a repel: a blast, and a round that is gone in a tick. Slot 1 is a
-- burst: no blast of its own and rounds that fly for ages.
-- Spec 12 is the case that only the life test catches: a charge that both goes
-- off and flies, a mine or a lobbed bomb. It draws itself all the way there
-- and detonates on its own expiry like any other blast, so drawing it from the
-- inventory as well would put a second explosion at the launcher.
local SPECS = {
    [10] = {blast = 512, life = 1, level = -1},
    [11] = {blast = 0, life = 550, level = -1},
    [12] = {blast = 200, life = 500, level = -1},
}
local CHARGE_SPEC = {[0] = 10, [1] = 11}

local room = {count = 3, alive = {[0] = true, [1] = true, [2] = true},
              charge = {}}
local function hold(ship, slot, n)
    room.charge[ship] = room.charge[ship] or {}
    room.charge[ship][slot] = n
end
for i = 0, 2 do hold(i, 0, 3) hold(i, 1, 3) end

_G.sim = {
    MAX_CHARGES = 2,
    ship_count = function() return room.count end,
    ship_alive = function(i) return room.alive[i] and 1 or 0 end,
    ship_charge = function(i, k) return (room.charge[i] or {})[k] or 0 end,
    ship_x = function(i) return 100 + i * 10 end,
    ship_y = function() return 200 end,
    ship_team = function() return 1 end,
    charge_spec = function(k) return CHARGE_SPEC[k] or -1 end,
    spec_blast = function(id) return (SPECS[id] or {}).blast or 0 end,
    spec_life = function(id) return (SPECS[id] or {}).life or 0 end,
    spec_level = function(id) return (SPECS[id] or {}).level or -1 end,
}

-- What was drawn, and what was heard.
local drawn, heard = {}, {}
package.loaded["arena.fx"] = setmetatable({
    detonate = function(x, y, r) drawn[#drawn + 1] = {x = x, y = y, r = r} end,
}, {__index = function() return function() end end})

local world = require("arena.world")
local function sfx(name, x, y) heard[#heard + 1] = {name = name, x = x, y = y} end

-- One pass, with the counts as they stand.
local ME = 0
local function look()
    drawn, heard = {}, {}
    world.charges(ME, sfx)
    return #drawn
end

-- --- the first look teaches, it does not draw ------------------------------

check("the first look draws nothing", look() == 0,
      "drew " .. #drawn)

-- --- a stranger spends a repel ---------------------------------------------

hold(1, 0, 2)
check("a stranger's repel is drawn", look() == 1, "drew " .. #drawn)
check("at their hull", drawn[1] and drawn[1].x == 110 and drawn[1].y == 200)
check("at the blast's own size", drawn[1] and drawn[1].r == 512,
      "radius " .. tostring(drawn[1] and drawn[1].r))
check("and heard", #heard == 1 and heard[1].name == "blast")

check("and only once", look() == 0, "drew " .. #drawn)

-- --- what must not draw ----------------------------------------------------

hold(ME, 0, 2)
check("your own repel is left to your own simulation", look() == 0,
      "drew " .. #drawn)

hold(1, 0, 3)
check("picking one up is not spending one", look() == 0, "drew " .. #drawn)

hold(2, 1, 2)
check("a burst draws itself and is not drawn again", look() == 0,
      "drew " .. #drawn)

-- A pilot who dies and respawns is re-outfitted, which moves counts in both
-- directions without anybody spending anything.
room.alive[1] = false
hold(1, 0, 0)
check("a hull that died is not spending charges", look() == 0,
      "drew " .. #drawn)
room.alive[1] = true
hold(1, 0, 3)
look()
hold(1, 0, 2)
check("and it draws again once they are back and flying", look() == 1,
      "drew " .. #drawn)

-- A seat that empties and is taken by somebody new starts from what they hold,
-- not from what the last pilot left in it.
room.count = 2
look()
room.count = 3
room.alive[2] = true
hold(2, 0, 1)
check("an arrival in a vacated seat is not a repel", look() == 0,
      "drew " .. #drawn)

-- --- a zone with no repel at all -------------------------------------------

-- Every zone names its own charges, and one that puts something else in slot
-- zero must not have it drawn as a shove.
CHARGE_SPEC[0] = 11
hold(1, 0, 3)
look()
hold(1, 0, 2)
check("a slot holding a long-lived round is not drawn", look() == 0,
      "drew " .. #drawn)

-- The one that needs the life test on its own: it has a blast, so every other
-- guard here lets it through, and it is already drawing itself.
CHARGE_SPEC[0] = 12
hold(1, 0, 3)
look()
hold(1, 0, 2)
check("a charge that flies and then goes off is not drawn twice",
      look() == 0, "drew " .. #drawn)
CHARGE_SPEC[0] = 10

-- And one that leaves the slot empty entirely.
CHARGE_SPEC[0] = nil
hold(1, 0, 3)
look()
hold(1, 0, 2)
check("an empty slot is not drawn", look() == 0, "drew " .. #drawn)

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
