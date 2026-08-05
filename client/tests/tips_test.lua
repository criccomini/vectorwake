-- The line shown under DESTROYED, and which death gets which.
--
--     lua5.1 client/tests/tips_test.lua
--
-- Two things this has to get right. The contextual lines answer the death
-- that just happened, so they outrank the stock and each other in a fixed
-- order; and the stock cycles rather than rolling, because a random pick
-- repeats itself inside three deaths often enough to read as broken.
--
-- It is a plain table in and a string out, with no engine anywhere near it,
-- which is the whole reason the picking lives in its own module: the numbers
-- it chooses on are gone from the simulation by the time anything can look.

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

local function stock(s)
    for _, line in ipairs(tips.STOCK) do
        if line == s then return true end
    end
    return false
end

-- --- the contextual lines --------------------------------------------------

tips.reset()
local own = tips.pick({self = true, bounty = 0, rungs = 0})
check("your own blast is answered", not stock(own), own)
check("and says so about the blast", own:find("blast") ~= nil, own)

local loss = tips.pick({self = false, bounty = 0, rungs = 3})
check("a loaded hull is told what it lost", not stock(loss), loss)
check("and it is a different line", loss ~= own)

local hunted = tips.pick({self = false, bounty = 40, rungs = 0})
check("a fat bounty is answered", not stock(hunted), hunted)
check("and it is its own line", hunted ~= own and hunted ~= loss)

-- Your own bomb outranks everything: it is the most specific thing that can
-- be said about a death, and it is the one a pilot is actually asking about.
check("your own blast outranks a lost loadout",
      tips.pick({self = true, rungs = 3, bounty = 40}) == own)
check("and a lost loadout outranks a bounty",
      tips.pick({self = false, rungs = 3, bounty = 40}) == loss)

-- --- what is ordinary gets the stock ---------------------------------------

-- A pilot who died with one rung and no bounty is an ordinary death. If the
-- contextual lines fired on those too they would fire on nearly every death
-- and stop meaning anything.
check("one rung is not a loadout worth mourning",
      stock(tips.pick({rungs = 1, bounty = 0})))
check("and a couple of points is not a manhunt",
      stock(tips.pick({rungs = 0, bounty = 2})))
check("a death with nothing to say still says something",
      stock(tips.pick({})))
check("and so does one with no table at all", stock(tips.pick()))

-- --- the cycle -------------------------------------------------------------

tips.reset()
local seen = {}
for i = 1, #tips.STOCK do
    seen[i] = tips.pick({})
end
check("the stock comes out in order", seen[1] == tips.STOCK[1]
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

-- --- the lines themselves --------------------------------------------------

-- A zone respawns in two to three seconds, so anything that needs reading
-- twice is not read at all. Measured against the widest the box gets: about
-- 60 characters at the desktop size before it wraps to a second row.
for _, line in ipairs(tips.STOCK) do
    check("a stock line fits two rows: " .. line, #line <= 90, #line .. " chars")
    check("and is lower case: " .. line, line == line:lower())
    check("and carries no full stop: " .. line, line:sub(-1) ~= ".")
end

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
