-- Little-endian wire primitives shared by every client message decoder and
-- builder. These functions know byte layout and nothing about connection
-- state.

local M = {}

function M.u16(a, b)
    return a + b * 256
end

function M.u32(a, b, c, d)
    return a + b * 256 + c * 65536 + d * 16777216
end

function M.i16(a, b)
    local value = M.u16(a, b)
    if value >= 32768 then value = value - 65536 end
    return value
end

function M.i32(a, b, c, d)
    local value = M.u32(a, b, c, d)
    if value >= 2147483648 then value = value - 4294967296 end
    return value
end

function M.put_u32(value)
    return string.char(
        value % 256,
        math.floor(value / 256) % 256,
        math.floor(value / 65536) % 256,
        math.floor(value / 16777216) % 256
    )
end

-- Anything placed in a byte may have arrived from a directory response. An
-- invalid room number is expressed as no preference instead of raising from
-- string.char inside a transport callback.
function M.byte_or_zero(value)
    if type(value) ~= "number" then return 0 end
    value = math.floor(value)
    if value < 0 or value > 255 then return 0 end
    return value
end

return M
