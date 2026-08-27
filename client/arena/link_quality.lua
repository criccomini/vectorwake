-- The slow connection instrument behind the link meter in the menu head.

local M = {}
M.__index = M

-- Boundaries are simulation ticks, ten milliseconds each. The estimate moves
-- through a one-second low-pass filter, then needs another tick past a
-- boundary before a bar changes. Normal packet timing can wander around a
-- boundary without making the instrument blink between two answers.
local THRESHOLDS = {6, 12, 24}
local HYSTERESIS = 1
local TIME_CONSTANT = 1

local function raw_bars(rtt)
    if rtt > THRESHOLDS[3] then return 1 end
    if rtt > THRESHOLDS[2] then return 2 end
    if rtt > THRESHOLDS[1] then return 3 end
    return 4
end

function M.new()
    return setmetatable({rtt = nil, bars = 4}, M)
end

function M:reset()
    self.rtt = nil
    self.bars = 4
end

function M:update(sample, dt)
    if not sample or sample <= 0 then return self.bars end
    if not self.rtt then
        self.rtt = sample
        self.bars = raw_bars(sample)
        return self.bars
    end

    local elapsed = math.max(0, dt or 0)
    local weight = 1 - math.exp(-elapsed / TIME_CONSTANT)
    self.rtt = self.rtt + (sample - self.rtt) * weight

    -- Move one rung at a time. A sudden change still crosses the ladder in a
    -- few frames, while a sample sitting near one boundary stays put.
    if self.bars > 1 then
        local worse = THRESHOLDS[5 - self.bars]
        if self.rtt > worse + HYSTERESIS then
            self.bars = self.bars - 1
            return self.bars
        end
    end
    if self.bars < 4 then
        local better = THRESHOLDS[4 - self.bars]
        if self.rtt < better - HYSTERESIS then self.bars = self.bars + 1 end
    end
    return self.bars
end

return M
