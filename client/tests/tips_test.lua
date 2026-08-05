-- The card dealt under DESTROYED.
--
--     lua5.1 client/tests/tips_test.lua
--
-- The pick is random, so this checks properties rather than a sequence:
-- every card dealt is one the drawing side knows, every card in the pool
-- turns up eventually, and no card is ever dealt twice running, which is the
-- one rule the randomness keeps. At six cards a true roll doubles up every
-- sixth death, and a repeat does not read as chance, it reads as a box that
-- failed to change.

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

local known = {}
for _, name in ipairs(tips.POOL) do known[name] = true end

local DRAWS = 600
local seen, repeats, foreign = {}, 0, 0
local prev = nil
for _ = 1, DRAWS do
    local c = tips.pick()
    if not known[c] then foreign = foreign + 1 end
    if c == prev then repeats = repeats + 1 end
    seen[c] = (seen[c] or 0) + 1
    prev = c
end

check("every deal is a card from the pool", foreign == 0,
      foreign .. " foreign")
check("no card is dealt twice running", repeats == 0, repeats .. " repeats")

local distinct = 0
for _ in pairs(seen) do distinct = distinct + 1 end
check("every card in the pool turns up", distinct == #tips.POOL,
      distinct .. " of " .. #tips.POOL)

-- No card hogs the deck. Uniform over six cards across six hundred draws
-- puts each near a hundred; a generator stuck in a short orbit lands far
-- outside a generous band around that.
local lo, hi = DRAWS, 0
for _, n in pairs(seen) do
    if n < lo then lo = n end
    if n > hi then hi = n end
end
check("and none hogs the deck", lo > DRAWS / #tips.POOL / 3
      and hi < DRAWS / #tips.POOL * 3, lo .. ".." .. hi)

-- --- every name is a card --------------------------------------------------

-- The picker and the drawing meet by name, and nothing checks that at load
-- time, so a card renamed on one side of the wall is a wait box that draws
-- nothing at all. Read out of ui.lua's source rather than by loading it,
-- since that would want an engine.
local src = io.open("client/arena/ui.lua"):read("*a")
local cards = {}
for name in src:gmatch("\n    (%w+) = {fig = ") do cards[name] = true end
check("ui.lua defines some cards", next(cards) ~= nil)
for _, name in ipairs(tips.POOL) do
    check("the pool names a card that exists: " .. name, cards[name] == true)
end

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
