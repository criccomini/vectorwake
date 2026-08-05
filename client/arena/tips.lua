-- What a pilot is told while they are waiting to fly again.
--
-- The three seconds after a death are the only moment in this game when a
-- player is looking at the screen with nothing to do, and they have just been
-- given a reason to care about why it happened. That is the entire argument
-- for this: it is not a loading screen looking for something to fill it, it is
-- the one window where an explanation is both welcome and earned.
--
-- Which is also why they are short. A zone respawns in two to three seconds,
-- so a line that has to be read twice is a line nobody reads. One clause, one
-- idea, lower case, no punctuation to parse.
--
-- The first ones are answers rather than advice. This client knows how the
-- hull died and what it was carrying, so a death by your own bomb says so, and
-- a pilot who had climbed two rungs is told what those rungs cost them. What
-- is left over is the general stock, and that is deliberately small: six lines
-- seen occasionally are six lines somebody remembers, and thirty are wallpaper.
--
-- The mechanics here are the ones the interface cannot show. The help page
-- draws the keyboard and the corner panel draws the loadout; nothing anywhere
-- says that a green is gone when you are, or that a fresh hull is worth
-- nothing to the pilot who just killed you. They are true of this simulation
-- rather than of the genre: see apply_damage in sim/src/sim.c, which strips
-- rungs, add-ons, charges and earned bounty in that order.

local M = {}

-- Read once at the moment of death, in `arena.script`, because every number
-- this chooses on is cleared by the same tick that kills you.
--
-- `self` is a death you caused yourself. `bounty` is what you were carrying,
-- which is what the kill paid whoever took it. `rungs` counts the weapon
-- levels and add-ons the hull had climbed to.
--
-- Nothing here reads the simulation directly. It is handed a plain table so
-- the whole of it can be tested without an engine, which is how tips_test runs.

-- The stock, in the order it cycles. Ordered rather than shuffled: a random
-- pick repeats itself within three deaths often enough to look broken, and
-- nobody can tell a cycle from a shuffle at one line every thirty seconds.
local STOCK = {
    "energy is your health and your ammunition, one bar for both",
    "a green is gone when you are, so what you carry is what you have survived",
    "a fresh hull is worth nothing, so nobody profits by camping your start",
    "bounty is what you are carrying, and what brings them",
    "you cannot be touched in a safe zone, and you cannot fire from one",
    "your own bomb does not care whose it is",
}

-- The contextual lines, each with the question it answers.
local SELF = "your own blast reaches further with every rung you add to it"
local CARRIED = "everything those greens gave you went with the hull"
local HUNTED = "a bounty that high is a bounty somebody came for"

-- What counts as worth remarking on. A pilot who died with one rung and no
-- bounty is an ordinary death and gets the stock, or the contextual lines
-- would fire on every one of them and stop meaning anything.
local RUNGS_WORTH_SAYING = 2
local BOUNTY_WORTH_SAYING = 5

local cursor = 0

-- Called on each death. Returns the line to show, or nil when there is
-- nothing to say, which is never: the stock always has a next entry.
function M.pick(d)
    d = d or {}
    if d.self then return SELF end
    if (d.rungs or 0) >= RUNGS_WORTH_SAYING then return CARRIED end
    if (d.bounty or 0) >= BOUNTY_WORTH_SAYING then return HUNTED end
    cursor = cursor % #STOCK + 1
    return STOCK[cursor]
end

-- A fresh zone starts the cycle over, so the first death in a room is the
-- first line rather than wherever the last room left off.
function M.reset()
    cursor = 0
end

M.STOCK = STOCK

return M
