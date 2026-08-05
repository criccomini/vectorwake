-- Which card is shown under DESTROYED, and which death earns which.
--
--     lua5.1 client/tests/tips_test.lua
--
-- Two things this has to get right. The contextual cards answer the death that
-- just happened, so they outrank the cycle and each other in a fixed order;
-- and the cycle is a cycle rather than a roll, because a random pick repeats
-- itself inside three deaths often enough to read as broken.
--
-- It is a plain table in and a card name out, with no engine anywhere near it,
-- which is the whole reason the picking lives in its own module: the numbers
-- it chooses on are gone from the simulation by the time anything can look.
-- The card that name refers to, the figure and the sentence, lives in ui.lua
-- beside the code that draws the real thing.

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

local tips = require("arena.tips")

local function cycles(s)
    for _, name in ipairs(tips.STOCK) do
        if name == s then return true end
    end
    return false
end

-- --- the contextual cards --------------------------------------------------

tips.reset()
local own = tips.pick({self = true, bounty = 0, rungs = 0})
check("your own blast earns the bomb", own == "bomb", own)

local loss = tips.pick({self = false, bounty = 0, rungs = 3})
check("a loaded hull earns the green", loss == "green", loss)

local hunted = tips.pick({self = false, bounty = 40, rungs = 0})
check("a fat bounty earns the bounty", hunted == "bounty", hunted)

-- Your own bomb outranks everything: it is the most specific thing that can
-- be said about a death, and it is the one a pilot is actually asking about.
check("your own blast outranks a lost loadout",
      tips.pick({self = true, rungs = 3, bounty = 40}) == "bomb")
check("and a lost loadout outranks a bounty",
      tips.pick({self = false, rungs = 3, bounty = 40}) == "green")

-- --- what is ordinary gets the cycle ---------------------------------------

-- A pilot who died with one rung and no bounty is an ordinary death. If the
-- contextual cards fired on those too they would fire on nearly every death
-- and stop meaning anything.
check("one rung is not a loadout worth mourning",
      cycles(tips.pick({rungs = 1, bounty = 0})))
check("and a couple of points is not a manhunt",
      cycles(tips.pick({rungs = 0, bounty = 2})))
check("a death with nothing to say still shows a card",
      cycles(tips.pick({})))
check("and so does one with no table at all", cycles(tips.pick()))

-- --- the cycle -------------------------------------------------------------

tips.reset()
local seen = {}
for i = 1, #tips.STOCK do
    seen[i] = tips.pick({})
end
check("the cycle comes out in order", seen[1] == tips.STOCK[1]
      and seen[#tips.STOCK] == tips.STOCK[#tips.STOCK])
local uniq = {}
for _, s in ipairs(seen) do uniq[s] = true end
local n = 0
for _ in pairs(uniq) do n = n + 1 end
check("with no repeats inside one pass", n == #tips.STOCK,
      n .. " distinct of " .. #tips.STOCK)
check("and it wraps rather than running out",
      tips.pick({}) == tips.STOCK[1])

-- A room you leave takes the cursor with it.
tips.pick({})
tips.reset()
check("a fresh zone starts the cycle over", tips.pick({}) == tips.STOCK[1])

-- --- every name is a card --------------------------------------------------

-- The picker and the drawing meet by name, and nothing checks that at load
-- time, so a card renamed on one side of the wall is a wait box that draws
-- nothing at all. Read out of ui.lua's source rather than by loading it,
-- since that would want an engine.
local src = io.open("client/arena/ui.lua"):read("*a")
local known = {}
for name in src:gmatch("\n    (%w+) = {fig = ") do known[name] = true end
check("ui.lua defines some cards", next(known) ~= nil)
for _, name in ipairs(tips.STOCK) do
    check("the cycle names a card that exists: " .. name, known[name] == true)
end
for _, name in ipairs({"bomb", "green", "bounty"}) do
    check("the contextual card exists: " .. name, known[name] == true)
end

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
