-- Lifetime and compaction for the figures that drift off a wreck: what a
-- death did to this pilot's rating, signed. It was the bounty a kill paid,
-- deleted with the shop, and it came back as the rating under decision 152.

local M = {}
M.__index = M

-- How long a figure stands, and how much of that it spends at full strength
-- before it begins to go. It was a second and a half, which is long enough to
-- notice and not long enough to read: a pilot who has just taken somebody is
-- still flying, and the glance that finds the number is the second glance
-- rather than the first. Two and a half seconds is what Chris asked for and
-- what a figure needs, and the hold grows with it, so the number is solid for
-- most of a second and then has the rest of its life to leave.
--
-- The drift is unchanged, which means it now travels the same distance at
-- half the speed. That is the right half to slow down: the rise is what says
-- the figure is leaving, and reading a number is easier when it is not moving
-- fast.
local LIFE = 2.5
local HOLD = 0.35

M.RISE = 26

function M.new()
    return setmetatable({items = {}}, M)
end

function M:add(now, x, y, amount)
    self.items[#self.items + 1] = {x = x, y = y, n = amount, t0 = now}
end

function M:clear()
    for i = #self.items, 1, -1 do self.items[i] = nil end
end

-- Visit live notices and compact the list in the same pass. `progress` runs
-- from zero to one; `alpha` holds briefly before fading.
function M:each(now, visit)
    local live = 0
    for i = 1, #self.items do
        local payout = self.items[i]
        local age = now - payout.t0
        if age >= 0 and age < LIFE then
            live = live + 1
            self.items[live] = payout
            local progress = age / LIFE
            local alpha = 1
            if progress > HOLD then
                alpha = 1 - (progress - HOLD) / (1 - HOLD)
            end
            visit(payout, progress, alpha)
        end
    end
    for i = #self.items, live + 1, -1 do self.items[i] = nil end
end

return M
