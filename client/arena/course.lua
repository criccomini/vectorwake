-- A stick names a course; the rudder chases it.
--
-- The thumb on glass and the left stick on a gamepad both point where the
-- nose should go, and the ship turns toward it at its own rate. The
-- arithmetic that turns a push into rudder and engine bits was written once
-- for the thumb and is shared here rather than copied, because two copies
-- of a rule about which way to turn drift, and a stick that reads a push
-- behind the nose differently from the thumb would be a second flight model
-- nobody asked for.
--
-- `dx`, `dy` are the push, screen +y up. `dead` and `full` are the two
-- magnitudes that matter, in whatever unit the push is in: below `dead`
-- nothing is asked for, past `full` the engine lights once the nose is
-- roughly there. `heading` is the ship's own, in the simulation's 16-bit
-- turn. `reversed` asks for the nose half a turn from the course, which is
-- the thumb's stance; a gamepad has a key for backing up and never sets it.
--
-- A list of bits rather than a bitfield: the caller merges this with the
-- keyboard, and HTML5 builds run Lua 5.1, which has no bitwise or.

local M = {}

function M.bits(dx, dy, dead, full, heading, reversed)
    local out = {}
    local mag = math.sqrt(dx * dx + dy * dy)
    if mag < dead then return out end

    -- Screen +y is up and the simulation's +y is down, which is why this is
    -- atan2(x, y) rather than the atan2(dx, -dy) the AI uses on sim vectors.
    local want = math.atan2(dx, dy)
    -- Reversed, the engine pushes out of the tail, so the nose that serves
    -- that course is the one half a turn from it, and that is what the
    -- rudder is given to chase. Everything below is then the forward case
    -- unchanged, the thrust gate included.
    if reversed then want = want + math.pi end
    local head = (heading / 65536) * math.pi * 2
    local diff = want - head
    while diff > math.pi do diff = diff - math.pi * 2 end
    while diff < -math.pi do diff = diff + math.pi * 2 end

    -- The nose, always: the stick points where the nose should go, so a push
    -- behind you is a turn like any other rather than an order to back up.
    if diff > 0.06 then out[#out + 1] = sim.BTN_RIGHT
    elseif diff < -0.06 then out[#out + 1] = sim.BTN_LEFT end

    -- The engine once the push is committed and the nose is roughly there,
    -- so a hard turn does not fling the ship the way it used to be facing.
    if mag > full and math.abs(diff) < 1.0 then
        out[#out + 1] = reversed and sim.BTN_REVERSE or sim.BTN_THRUST
    end
    return out
end

return M
