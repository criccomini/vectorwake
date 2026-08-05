-- Which card a pilot is shown while they are waiting to fly again.
--
-- The three seconds after a death are the only moment in this game when a
-- player is looking at the screen with nothing to do, and they have just been
-- given a reason to care about why it happened. That is the entire argument
-- for this: it is not a loading screen looking for something to fill it, it is
-- the one window where an explanation is both welcome and earned.
--
-- A card is a drawing of a thing that is out there and a sentence saying what
-- it is. The drawing does the work a sentence cannot: a line about bombs is a
-- line about bombs, and the shape beside it is the one that just killed you,
-- which you have watched a hundred times without ever being told its name.
-- The figures live in ui.lua next to the code that draws the real ones; this
-- file only decides which card a death has earned.
--
-- The sentences stay to one clause. A zone respawns in two to three seconds,
-- so anything that has to be read twice is not read at all.
--
-- Answers before advice. This client knows how the hull died and what it was
-- carrying, so a pilot caught in their own blast gets the bomb, one who had
-- climbed two rungs gets the green, and one who was worth killing gets the
-- bounty. Everything else falls through to the cycle, which is deliberately
-- short: six cards seen occasionally are six a player comes to know, and
-- thirty are wallpaper.
--
-- What they say is true of this simulation rather than of the genre. See
-- apply_damage in sim/src/sim.c, which strips rungs, add-ons, charges and
-- earned bounty in that order, and sim_bounty, which counts every one of them
-- back up: that is why a green raises what you are worth.

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
-- nobody can tell a cycle from a shuffle at one card every thirty seconds.
--
-- These are keys into ui.CARDS, which holds the figure and the words. What a
-- card *is* belongs next to the code that draws it; which card a death earns
-- belongs here, and the two meet by name.
local STOCK = {"bolt", "green", "bomb", "repel", "burst", "bounty"}

-- The contextual cards, each with the death it answers.
local SELF = "bomb"
local CARRIED = "green"
local HUNTED = "bounty"

-- What counts as worth remarking on. A pilot who died with one rung and no
-- bounty is an ordinary death and gets the stock, or the contextual lines
-- would fire on every one of them and stop meaning anything.
local RUNGS_WORTH_SAYING = 2
local BOUNTY_WORTH_SAYING = 5

local cursor = 0

-- Called on each death. Returns the name of a card in ui.CARDS. Never nil:
-- the cycle always has a next entry.
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
