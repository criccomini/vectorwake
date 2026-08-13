-- Serial-number arithmetic and packet receipt windows used by rollback.

local M = {}
M.__index = M

local U32 = 4294967296
local SERIAL_HALF = 2147483648

function M.u32n(value)
    return value % U32
end

function M.serial_after(a, b)
    if a == b then return false end
    return M.u32n(a - b) < SERIAL_HALF
end

function M.serial_at_or_before(a, b)
    return a == b or M.serial_after(b, a)
end

function M.serial_delta(a, b)
    local delta = M.u32n(a - b)
    if delta >= SERIAL_HALF then delta = delta - U32 end
    return delta
end

function M.next_tick(tick)
    return M.u32n(tick + 1)
end

function M.previous_tick(tick)
    return M.u32n(tick - 1)
end

function M.snapshot_distance(newer, older)
    local distance = M.u32n(newer - older)
    if newer < older then distance = distance - 1 end
    return distance
end

function M.snapshot_after(a, b)
    return a ~= b and M.snapshot_distance(a, b) < SERIAL_HALF
end

function M.receipt_bit(mask, behind)
    if behind < 0 or behind >= 32 then return false end
    return math.floor(mask / (2 ^ behind)) % 2 == 1
end

function M.new()
    return setmetatable({
        input_ack = 0,
        input_mask = 0,
        snapshot_ack = 0,
        snapshot_mask = 0,
    }, M)
end

function M:reset()
    self.input_ack = 0
    self.input_mask = 0
    self.snapshot_ack = 0
    self.snapshot_mask = 0
end

function M:set_input(ack, mask)
    self.input_ack = ack
    self.input_mask = mask
end

-- Returns the number of newly visible holes between this sequence and the
-- newest one previously received.
function M:record_snapshot(sequence)
    if sequence == 0 then return 0 end
    local missed = 0
    if self.snapshot_ack == 0
        or M.snapshot_after(sequence, self.snapshot_ack) then
        local shift = self.snapshot_ack == 0 and 1
            or M.snapshot_distance(sequence, self.snapshot_ack)
        if self.snapshot_ack ~= 0 and shift > 1 then
            missed = shift - 1
        end
        self.snapshot_mask = (self.snapshot_ack == 0 or shift >= 32)
            and 1
            or ((self.snapshot_mask % (2 ^ (32 - shift))) * (2 ^ shift) + 1)
        self.snapshot_ack = sequence
    else
        local behind = M.snapshot_distance(self.snapshot_ack, sequence)
        if behind < 32 and not M.receipt_bit(self.snapshot_mask, behind) then
            self.snapshot_mask = self.snapshot_mask + 2 ^ behind
        end
    end
    return missed
end

function M:input_received(tick)
    return self.input_mask ~= 0
        and M.serial_at_or_before(tick, self.input_ack)
        and M.receipt_bit(self.input_mask, M.u32n(self.input_ack - tick))
end

return M
