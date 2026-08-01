-- Touch controls.
--
-- The question platforms.md asks is whether mobile is a playing client or a
-- spectating one. This is the playing answer: a thumbstick that points where
-- you want the nose to go, and two pads for the two weapons.
--
-- Pointing beats a rotate-left/rotate-right pair on glass. There is no tactile
-- edge to feel for, so a player cannot hold a rotation and stop it on time;
-- they can put a thumb where they want to be facing. The ship still turns at
-- its own rate, so nothing about the flight model changes -- this only decides
-- which way the turn is applied, exactly as the AI does it.
--
-- The simulation never learns any of this happened: it receives the same
-- button bitfield a keyboard produces.

local M = {}

-- Screen is split by fraction of width and height, so the layout holds on any
-- aspect from a phone to an ultrawide.
local STICK_SIDE = 0.45   -- left of this is the stick
local WEAPON_SPLIT = 0.5  -- right side: below is guns, above is bombs
local DEAD_PX = 14        -- ignore a thumb that has barely moved
local THRUST_PX = 46      -- push past this and the engine lights

M.used = false            -- has this device ever reported a touch?

local stick = nil         -- {id, ox, oy, x, y}
local guns = nil          -- touch id holding the guns pad
local bombs = nil

local function zone(x, y, w, h)
    if x < w * STICK_SIDE then return "stick" end
    if y < h * WEAPON_SPLIT then return "guns" end
    return "bombs"
end

-- Feed Defold's multitouch action. Returns nothing; state is read by buttons().
function M.on_touch(action, w, h)
    if not action.touch then return end
    M.used = true
    for _, t in ipairs(action.touch) do
        if t.pressed then
            local z = zone(t.x, t.y, w, h)
            if z == "stick" and not stick then
                stick = {id = t.id, ox = t.x, oy = t.y, x = t.x, y = t.y}
            elseif z == "guns" then
                guns = t.id
            elseif z == "bombs" then
                bombs = t.id
            end
        elseif t.released then
            if stick and stick.id == t.id then stick = nil end
            if guns == t.id then guns = nil end
            if bombs == t.id then bombs = nil end
        elseif stick and stick.id == t.id then
            stick.x, stick.y = t.x, t.y
        end
    end
end

-- Lifting a finger outside the window does not always produce a release, so
-- a lost touch has to be forgettable.
function M.release_all()
    stick, guns, bombs = nil, nil, nil
end

-- The bits held this frame, given where the ship is currently pointing.
--
-- A list rather than a bitfield, because the caller merges this with the
-- keyboard and HTML5 builds run Lua 5.1, which has no bitwise or. Summing a
-- set of distinct bits is exact and needs no library.
function M.bits(heading)
    local out = {}
    if guns then out[#out + 1] = sim.BTN_FIRE end
    if bombs then out[#out + 1] = sim.BTN_BOMB end
    if not stick then return out end

    local dx, dy = stick.x - stick.ox, stick.y - stick.oy
    local mag = math.sqrt(dx * dx + dy * dy)
    if mag < DEAD_PX then return out end

    -- Screen +y is up and the simulation's +y is down, which is why this is
    -- atan2(x, y) rather than the atan2(dx, -dy) the AI uses on sim vectors.
    local want = math.atan2(dx, dy)
    local head = (heading / 65536) * math.pi * 2
    local diff = want - head
    while diff > math.pi do diff = diff - math.pi * 2 end
    while diff < -math.pi do diff = diff + math.pi * 2 end

    if diff > 0.06 then out[#out + 1] = sim.BTN_RIGHT
    elseif diff < -0.06 then out[#out + 1] = sim.BTN_LEFT end

    -- Thrust once the thumb is committed and the nose is roughly there, so a
    -- hard turn does not fling the ship the way it used to be facing.
    if mag > THRUST_PX and math.abs(diff) < 1.0 then
        out[#out + 1] = sim.BTN_THRUST
    end
    return out
end

-- True while the stick is steering, so the caller can drop keyboard steering
-- rather than let two sources fight over the rudder.
function M.steering()
    return stick ~= nil
end

-- Drawn in the screen-space interface layer, which is where a control that
-- follows the thumb belongs: touch coordinates arrive in window pixels
-- counting up from the bottom, and that is exactly the space this layer
-- projects, so the only conversion left is the drawable's pixel density.
--
-- w and h are the window, not the drawable.
function M.draw(u, w, h, density)
    if not M.used then return end
    local pal = require("arena.palette")
    local dim = pal.a(pal.DIM, 0.5)
    local live = pal.a(pal.FRIEND, 0.9)
    local s = density

    local function ring(px, py, r, col, segments)
        u:ring(px * s, py * s, r * s, 1.8 * s, segments or 26, col)
    end

    -- The two weapon pads sit where a right thumb falls.
    ring(w * 0.86, h * 0.22, 46, guns and live or dim)
    if guns then u:halo(w * 0.86 * s, h * 0.22 * s, 52 * s, 16, pal.a(pal.FRIEND, 0.16)) end
    ring(w * 0.86, h * 0.58, 34, bombs and live or dim)
    if bombs then u:halo(w * 0.86 * s, h * 0.58 * s, 40 * s, 16, pal.a(pal.BOMB, 0.18)) end

    if stick then
        ring(stick.ox, stick.oy, 52, dim)
        ring(stick.x, stick.y, 20, live, 16)
        u:seg(stick.ox * s, stick.oy * s, stick.x * s, stick.y * s, 2 * s, live)
    end
end

return M
