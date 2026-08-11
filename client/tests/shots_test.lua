-- Somebody else's gun, heard from their cooldown going up.
--
--     lua5.1 client/tests/shots_test.lua
--
-- The fire event belongs to the one ship this client predicts. `sim.replay` is
-- handed your buttons and nobody else's, so a remote pilot coasts, their
-- trigger is never pulled here, and there is no event to hear. Their rounds
-- turn up already flying, in a snapshot.
--
-- `world.shots` reads two things a snapshot does carry. A cooldown that rose
-- says a trigger was pulled, because nothing local can pull theirs. The count
-- of their live rounds by family says which one. Both have to agree, because
-- each is wrong on its own: a cooldown cannot tell a gun from a bomb, and a
-- round appearing is also what a mispredicted collision looks like when the
-- next snapshot puts it back.

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

-- Spec 1 is a gun on rung 2, spec 2 a bomb on rung 1. Spec 3 is a repel: a
-- blast that is gone in a tick, spent from an inventory rather than fired.
-- Spec 4 is shrapnel, on no ladder at all.
local SPECS = {
    [1] = {blast = 0,   life = 300, level = 2},
    [2] = {blast = 400, life = 500, level = 1},
    [3] = {blast = 512, life = 1,   level = -1},
    [4] = {blast = 0,   life = 40,  level = -1},
}

local room = {count = 3, alive = {[0] = true, [1] = true, [2] = true},
              cd = {[0] = 0, [1] = 0, [2] = 0}}
-- Each row is {spec, owner, depth}.
local air = {}

_G.sim = {
    MAX_CHARGES = 2,
    ship_count = function() return room.count end,
    ship_alive = function(i) return room.alive[i] and 1 or 0 end,
    ship_cooldown = function(i) return room.cd[i] or 0 end,
    ship_charge = function() return 0 end,
    ship_x = function(i) return 100 + i * 10 end,
    ship_y = function() return 200 end,
    ship_team = function() return 1 end,
    charge_spec = function() return -1 end,
    spec_blast = function(id) return (SPECS[id] or {}).blast or 0 end,
    spec_life = function(id) return (SPECS[id] or {}).life or 0 end,
    spec_level = function(id) return (SPECS[id] or {}).level or -1 end,
    weapon_count = function() return #air end,
    weapon_at = function(i)
        local w = air[i + 1]
        return 0, 0, w[1], 0, 0, 1, 10, w[2], w[3]
    end,
}

package.loaded["arena.fx"] = setmetatable({}, {
    __index = function() return function() end end,
})

local world = require("arena.world")

local heard = {}
local function sfx(name, x, y, lvl)
    heard[#heard + 1] = {name = name, x = x, y = y, lvl = lvl}
end

local ME = 0
local function look()
    heard = {}
    world.shots(ME, sfx)
    return #heard
end

-- Fire `n` rounds of `spec` from `ship`, the way a snapshot delivers one: the
-- rounds are suddenly in the air and the cooldown is suddenly up.
local function fires(ship, spec, n)
    room.cd[ship] = 20
    for _ = 1, (n or 1) do air[#air + 1] = {spec, ship, 0} end
end

-- A tick with nobody firing: every cooldown counts down by one.
local function idle()
    for i = 0, room.count - 1 do
        if room.cd[i] > 0 then room.cd[i] = room.cd[i] - 1 end
    end
end

-- --- the first look teaches, it does not sound -----------------------------

check("the first look is silent", look() == 0, "heard " .. #heard)

-- --- a stranger shoots -----------------------------------------------------

fires(1, 1)
check("a stranger's gun is heard", look() == 1, "heard " .. #heard)
check("as a gun", heard[1] and heard[1].name == "gun")
check("on their rung", heard[1] and heard[1].lvl == 2,
      "rung " .. tostring(heard[1] and heard[1].lvl))
check("at their hull", heard[1] and heard[1].x == 110 and heard[1].y == 200)

idle()
check("and once, not once a tick while it flies", look() == 0,
      "heard " .. #heard)

fires(2, 2)
check("and a bomb is heard as a bomb", look() == 1 and heard[1].name == "bomb")

-- Multifire is one pull of one trigger. Three rounds leaving together is one
-- shot, or a hull with the add-on sounds like three pilots.
idle()
fires(1, 1, 3)
check("three barrels are one shot", look() == 1, "heard " .. #heard)

-- --- what must not sound ---------------------------------------------------

idle()
fires(ME, 1)
check("your own shot is left to your own simulation", look() == 0,
      "heard " .. #heard)

-- A round appearing with no cooldown behind it is prediction being corrected:
-- the local simulation flew a remote hull into a bolt it never actually met,
-- killed the bolt, and the next snapshot put it back.
idle()
air[#air + 1] = {1, 1, 0}
check("a round the wire put back is not a shot", look() == 0,
      "heard " .. #heard)

-- And a cooldown with no round behind it is a charge: `world.charges` has
-- that one, and a repel sounding as a bomb as well would double it.
idle()
room.cd[1] = 20
air[#air + 1] = {3, 1, 0}
check("a repel is not a bomb shot", look() == 0, "heard " .. #heard)

-- Nobody aimed a fragment, and its owner may be dead by the time it exists.
idle()
room.cd[2] = 20
air[#air + 1] = {4, 2, 1}
check("shrapnel is not a shot", look() == 0, "heard " .. #heard)

-- A pilot who dies and respawns is re-outfitted and their rounds are cleared,
-- which moves both numbers without anybody pulling anything.
idle()
room.alive[1] = false
room.cd[1] = 30
check("a hull that died is not shooting", look() == 0, "heard " .. #heard)
room.alive[1] = true
room.cd[1] = 0
look()
fires(1, 1)
check("and it is heard again once they are back and flying", look() == 1,
      "heard " .. #heard)

-- A seat that empties and is taken by somebody new starts from what they are
-- doing, not from what the last pilot left behind.
idle()
room.count = 2
look()
room.count = 3
room.alive[2] = true
room.cd[2] = 25
air[#air + 1] = {1, 2, 0}
check("an arrival in a vacated seat is not a shot", look() == 0,
      "heard " .. #heard)

-- --- out of the snapshot altogether ----------------------------------------

-- A zone packs the weapons near you and drops the rest, so a pilot shooting
-- across the map hands this a cooldown and no rounds. That is the right
-- silence: they are far outside earshot anyway.
idle()
air = {}
look()
idle()
room.cd[1] = 20
check("a shot whose rounds were culled is silent", look() == 0,
      "heard " .. #heard)

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
