-- What a green just handed you, in words.
--
-- The core reports a pickup as a slot in the kit space and the count the
-- pilot now holds of it. That is the right thing for it to say and the wrong
-- thing to put in front of a player: the space is flat, and slot fourteen is
-- not a sentence.
--
-- Where its regions begin is asked of the core, the way the hangar asks it,
-- so a layout that moves moves here too rather than in two places. The words
-- are the palette's, which is where this interface keeps its names, and they
-- are the same words the corner card uses for the same kit: a pilot who
-- learns what a green gave them can find it on the card a second later, and
-- would not if the two called one thing two things.

local pal = require("arena.palette")

local M = {}

-- A number the core publishes, or the layout as it shipped. The fallbacks are
-- here for the same reason the hangar's are: this file is loaded by tests and
-- by tools that have no extension under them, and a missing constant should
-- cost a wrong word rather than a crash on the frame a prize is taken.
local function core_n(key, fallback)
    local core = _G.sim
    return (core and tonumber(core[key])) or fallback
end

-- The two triggers, in the core's order. Said here as words because nothing
-- on the wire carries any: a slot knows which trigger it hangs off and the
-- interface is what knows that trigger is called the gun.
local TRIGGERS = {"gun", "bomb"}

-- How many of it you now hold, where that is worth saying. One of a thing is
-- the thing, so nothing is added; above one this is the corner card's own
-- "x n", because a pilot reading the feed and then reading the card must not
-- have to translate between two ways of counting the same kit.
--
-- It is also the whole of what tells a step up from a shrug. A green that
-- lands on a slot already at its ceiling is spent for nothing, and what says
-- so is a number that did not move.
local function times(held)
    return (held > 1) and (" x" .. held) or ""
end

-- One slot, named. `held` is what the pilot holds of it after the grant,
-- which is what SIM_EV_GREEN carries.
function M.words(slot, held)
    slot = tonumber(slot) or 0
    held = tonumber(held) or 0
    local ups = core_n("UP_COUNT", 5)
    local trigs = core_n("TRIG_COUNT", 2)
    local mods = core_n("MOD_COUNT", 6)
    local lvl0 = core_n("SLOT_LEVEL0", ups)
    local mod0 = core_n("SLOT_MOD0", ups + trigs)
    local ch0 = core_n("SLOT_CHARGE0", ups + trigs + trigs * mods)

    -- A flight stat: one of the five every hull is flying on already.
    if slot < lvl0 then
        local up = pal.UPGRADES[slot + 1]
        return (up and up.name or "upgrade") .. times(held)
    end

    -- A rung of a weapon's ladder, counted from one: the bottom of a ladder
    -- is still a rung of it and every hull stands on it, so a gun one green
    -- up is level two here exactly as it is on the card.
    if slot < mod0 then
        local t = TRIGGERS[slot - lvl0 + 1] or "weapon"
        return t .. " level " .. (held + 1)
    end

    -- An add-on, with the trigger it was bolted to. The trigger has to be
    -- said: a feed line stands on its own, where the card sits under a mark
    -- that has already answered whether this is the gun or the bomb.
    --
    -- Named at the length that teaches, which is the card's rule as well:
    -- `long` where the short name is jargon, the ordinary name otherwise.
    if slot < ch0 then
        local i = slot - mod0
        local t = TRIGGERS[math.floor(i / mods) + 1] or "weapon"
        local m = pal.MODS[i % mods + 1]
        return t .. " " .. (m and (m.long or m.name) or "add-on") .. times(held)
    end

    -- A charge: a thing you carry a count of and spend.
    local c = pal.CHARGES[slot - ch0 + 1]
    return (c and c.name or "charge") .. times(held)
end

return M
