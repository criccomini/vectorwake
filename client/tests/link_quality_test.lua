-- LINK is an instrument, not a live graph of packet timing.

package.path = "client/?.lua;" .. package.path

local link_quality = require("arena.link_quality")

local function eq(actual, expected, label)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", label,
                            tostring(expected), tostring(actual)))
    end
end

local link = link_quality.new()
eq(link:update(5, 1 / 60), 4, "a good first sample")

-- Samples on both sides of the six-tick boundary used to alternate between
-- three and four bars at snapshot speed. Filtering and hysteresis hold the
-- answer through the same ordinary variation.
for n = 1, 300 do
    local sample = n % 2 == 0 and 5.5 or 6.5
    eq(link:update(sample, 1 / 60), 4, "boundary jitter stays steady")
end

for _ = 1, 180 do link:update(10, 1 / 60) end
eq(link.bars, 3, "sustained latency lowers the meter")

for n = 1, 300 do
    local sample = n % 2 == 0 and 11.5 or 12.5
    eq(link:update(sample, 1 / 60), 3, "the next boundary also stays steady")
end

for _ = 1, 240 do link:update(4, 1 / 60) end
eq(link.bars, 4, "sustained recovery restores the meter")

link:reset()
eq(link.bars, 4, "a new connection starts clean")
eq(link:update(0, 1), 4, "no measurement is not a bad link")

print("link quality tests pass")
