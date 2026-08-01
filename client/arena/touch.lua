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

-- Draw the controls in world space, offset from the camera, which puts them
-- at fixed screen positions without needing a second render pass. The first
-- draw_debug3d of a frame consumes every queued line, so a screen-space pass
-- would swallow the arena with it.
function M.draw(cam_x, cam_y, half_w, half_h, w, h)
    if not M.used then return end
    local dim = vmath.vector4(0.35, 0.44, 0.58, 1)
    local live = vmath.vector4(0.31, 0.84, 1.00, 1)

    -- Screen pixels to world units, and screen origin to world.
    local sx = (2 * half_w) / w
    local sy = (2 * half_h) / h
    -- Touch y counts up from the bottom of the window; the world now renders
    -- +y downward, so the vertical term is negated.
    local function world(px, py)
        return cam_x + (px - w * 0.5) * sx, cam_y - (py - h * 0.5) * sy
    end

    local function ring(px, py, r, color, segments)
        local n = segments or 20
        local rx, ry = r * sx, r * sy
        local wx, wy = world(px, py)
        for i = 0, n - 1 do
            local a, b = (i / n) * math.pi * 2, ((i + 1) / n) * math.pi * 2
            msg.post("@render:", "draw_line", {
                start_point = vmath.vector3(wx + math.cos(a) * rx, wy + math.sin(a) * ry, 0),
                end_point = vmath.vector3(wx + math.cos(b) * rx, wy + math.sin(b) * ry, 0),
                color = color})
        end
    end

    -- The two weapon pads sit where a right thumb falls.
    ring(w * 0.86, h * 0.22, 46, guns and live or dim)
    ring(w * 0.86, h * 0.58, 34, bombs and live or dim)

    if stick then
        ring(stick.ox, stick.oy, 52, dim)
        ring(stick.x, stick.y, 20, live, 12)
        local ax, ay = world(stick.ox, stick.oy)
        local bx, by = world(stick.x, stick.y)
        msg.post("@render:", "draw_line", {
            start_point = vmath.vector3(ax, ay, 0),
            end_point = vmath.vector3(bx, by, 0), color = live})
    end
end

return M
