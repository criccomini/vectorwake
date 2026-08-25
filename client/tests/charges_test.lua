-- Somebody else's repel, drawn from a public action without their inventory.
--
--     lua5.1 client/tests/charges_test.lua
--
-- A repel lives one tick, so it reaches the state a snapshot is packed from
-- only when the tick it was fired on happens to be a snapshot tick: one time
-- in five at 20 Hz over a 100 Hz simulation. The other four a watcher is sent
-- no weapon and no expiry, and the shove arrives with nothing attached to it.
-- `server/src/main.rs` pins that fact from the other side.
--
-- Remote charge counts are owner-private now. The arena sends the slot and
-- position only when the action is inside the recipient's fairness circle.
-- This pins the client half: count changes disclose and draw nothing, while
-- the explicit action restores the one-tick blast that cannot reach a snapshot.

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
-- off and flies, such as a lobbed bomb. It draws itself all the way there
-- and detonates on its own expiry like any other blast, so drawing it from the
-- inventory as well would put a second explosion at the launcher.
local SPECS = {
    [10] = {blast = 512, life = 1, level = -1},
    [11] = {blast = 0, life = 550, level = -1},
    [12] = {blast = 200, life = 500, level = -1},
    -- A charge whose blast is exactly a rung two bomb's, for the mapping.
    [13] = {blast = 240, life = 1, level = -1},
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
    -- A seat the snapshot carries at all. Filtered snapshots leave far
    -- seats out entirely, so the board asks this before reading a score
    -- out of the simulation; in here every seat the room models is
    -- present.
    ship_active = function() return 1 end,
    ship_alive = function(i) return room.alive[i] and 1 or 0 end,
    ship_private = function(i) return i == 0 end,
    ship_charge = function(i, k) return (room.charge[i] or {})[k] or 0 end,
    ship_x = function(i) return 100 + i * 10 end,
    ship_y = function() return 200 end,
    ship_team = function() return 1 end,
    -- Nobody is riding anybody unless a test says so.
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
local function sfx(name, x, y, lvl)
    heard[#heard + 1] = {name = name, x = x, y = y, lvl = lvl}
end

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
check("a private remote count draws nothing", look() == 0, "drew " .. #drawn)

drawn, heard = {}, {}
world.remote_charge(0, 110, 200, sfx)
check("the public action draws the repel", #drawn == 1, "drew " .. #drawn)
check("at its authoritative position",
      drawn[1] and drawn[1].x == 110 and drawn[1].y == 200)
check("at the blast's own size", drawn[1] and drawn[1].r == 512,
      "radius " .. tostring(drawn[1] and drawn[1].r))
check("and heard", #heard == 1 and heard[1].name == "blast")
-- The four detonation sounds are sized by radius rather than by the rung that
-- fired, and this is why. A repel is on no ladder, so its level is -1, and a
-- level is what every other sound in the arena is picked by. Played that way
-- the widest shove in the game, 512 pixels against a top rung bomb's 320,
-- would come out as the smallest thing in the kit.
check("and at the size of the hole it makes",
      heard[1] and heard[1].lvl and heard[1].lvl >= 3,
      "rung " .. tostring(heard[1] and heard[1].lvl))

-- And the mapping is the bomb ladder's own radii, not a guess: 80 pixels a
-- rung, so a 240 pixel hole is the one a rung two bomb makes and gets that
-- rung's sound.
CHARGE_SPEC[0] = 13
drawn, heard = {}, {}
world.remote_charge(0, 110, 200, sfx)
check("a blast the size of a rung two bomb sounds like one",
      #heard == 1 and heard[1].lvl == 2,
      "rung " .. tostring(heard[1] and heard[1].lvl))
CHARGE_SPEC[0] = 10

-- --- what must not draw ----------------------------------------------------

hold(ME, 0, 2)
check("your own repel is left to your own simulation", look() == 0,
      "drew " .. #drawn)

CHARGE_SPEC[0] = 11
drawn, heard = {}, {}
world.remote_charge(0, 110, 200, sfx)
check("a slot holding a burst is not drawn again", #drawn == 0,
      "drew " .. #drawn)

-- The one that needs the life test on its own: it has a blast, so every other
-- guard here lets it through, and it is already drawing itself.
CHARGE_SPEC[0] = 12
drawn, heard = {}, {}
world.remote_charge(0, 110, 200, sfx)
check("a charge that flies and then goes off is not drawn twice",
      #drawn == 0, "drew " .. #drawn)
CHARGE_SPEC[0] = 10

-- And one that leaves the slot empty entirely.
CHARGE_SPEC[0] = nil
drawn, heard = {}, {}
world.remote_charge(0, 110, 200, sfx)
check("an empty slot is not drawn", #drawn == 0, "drew " .. #drawn)

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
