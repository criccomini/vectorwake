-- Lifetime and compaction for the figures that drift off a wreck: what a
-- death did to this pilot's rating, signed. It was the bounty a kill paid,
-- deleted with the shop, and it came back as the rating under decision 152.

local M = {}
M.__index = M

local LIFE = 1.4
local HOLD = 0.25

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
