-- Which card a pilot is shown while they are waiting to fly again.
--
-- The few seconds after a death are the only moment in this game when a
-- player is looking at the screen with nothing to do, and they have just been
-- given a reason to care about why it happened. That is the entire argument
-- for this: it is not a loading screen looking for something to fill it, it is
-- the one window where an explanation is both welcome and earned.
--
-- A card is a drawing of a thing that is out there and a sentence saying what
-- it is. The figures live in ui.lua next to the code that draws the real
-- ones; this file only decides which card a death gets, and the two meet by
-- name.
--
-- The pick is random. It chose by context once, your own blast earning the
-- bomb and a lost loadout the green, and the cleverness was not worth what it
-- cost: most deaths are ordinary, so most deaths reached the fallback anyway,
-- and the pool is cards a player is meant to meet in any order. The one rule
-- kept is that a card never follows itself, because a repeat does not read as
-- chance, it reads as a box that failed to change.
--
-- The generator is this module's own rather than math.random, whose global
-- seed the arena pins for its own reasons, and it starts from the clock so
-- two sessions do not deal the same order.

local M = {}

-- Keys into ui.CARDS, which holds the figure and the words.
local POOL = {"bolt", "green", "bomb", "shrap", "repel", "burst",
              "hole", "safe", "bounty"}

local seed = (os.time() % 65521) * 31
    + math.floor((os.clock() * 1000) % 997) + 7
local function rnd(n)
    seed = (seed * 1103515245 + 12345) % 2147483648
    return math.floor(seed / 1024) % n + 1
end

local last = nil

-- Called on each death. Returns the name of a card in ui.CARDS, never nil,
-- and never the card the last death showed.
function M.pick()
    if not last then
        last = POOL[rnd(#POOL)]
        return last
    end
    local i = rnd(#POOL - 1)
    for k = 1, #POOL do
        if POOL[k] ~= last then
            i = i - 1
            if i == 0 then
                last = POOL[k]
                return last
            end
        end
    end
end

M.POOL = POOL

return M
