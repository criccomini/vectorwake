-- A simulation clock should not chase packet timing one tick at a time.
-- Network margin is noisy, so require a continuous wall-clock interval on one
-- side of the dead band before changing the rate. The small rate difference
-- then earns or gives back one tick over a second instead of moving the world
-- by a whole tick when a snapshot arrives.

local M = {}
local Pacer = {}
Pacer.__index = Pacer

function M.new(options)
    options = options or {}
    return setmetatable({
        target = options.target or -4,
        slack = options.slack or 3,
        max_lead = options.max_lead or 40,
        hold = options.hold or 1.0,
        stale = options.stale or 0.25,
        delta = options.delta or 0.01,
        direction = 0,
        since = nil,
        last = nil,
        active = 0,
    }, Pacer)
end

function Pacer:reset()
    self.direction = 0
    self.since = nil
    self.last = nil
    self.active = 0
end

local function wanted(self, margin, lead)
    if margin > self.target and lead < self.max_lead then return 1 end
    if margin < self.target - self.slack and lead > 0 then return -1 end
    return 0
end

function Pacer:observe(now, margin, lead)
    if self.last and now - self.last > self.stale then
        self:reset()
    end
    self.last = now

    local direction = wanted(self, margin, lead)
    if direction == 0 then
        self.direction = 0
        self.since = nil
        self.active = 0
    elseif direction ~= self.direction then
        self.direction = direction
        self.since = now
        self.active = 0
    elseif now - self.since >= self.hold then
        self.active = direction
    end
    return 1 + self.active * self.delta
end

function Pacer:rate(now)
    if not self.last or now - self.last > self.stale then
        self.active = 0
        return 1
    end
    return 1 + self.active * self.delta
end

return M
