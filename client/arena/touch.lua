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

local DEAD_PX = 14        -- ignore a thumb that has barely moved
local THRUST_PX = 46      -- push past this and the engine lights

M.used = false            -- has this device ever reported a touch?
M.scale = 1               -- drawable pixels per point

local stick = nil         -- {id, ox, oy, x, y}
local guns = nil          -- touch id holding the guns pad
local bombs = nil
local use = nil           -- spend the ready charge
-- Swapping which charge is ready is a tap rather than a hold, so it is
-- latched here and read once. A held pad would cycle sixty times a second.
local swap_tap = false

-- Where the controls are. One definition, used by the hit test and by the
-- drawing, because they were written out separately and had drifted: the pads
-- were drawn at one height and tested at another, so half of a pad did
-- nothing and the dead space beside it fired.
--
-- Coordinates are drawable pixels counting up from the bottom, which is the
-- space `screen_x`/`screen_y` arrive in and the space the interface layer
-- projects, so nothing has to be converted. Sized off the smaller screen
-- dimension so a pad is a thumb wide on a phone and does not become a dinner
-- plate on a monitor, with the limits in points rather than pixels: a phone
-- at two pixels per point would otherwise get pads half the size it needs.
function M.layout(w, h, s)
    s = s or 1
    local r = math.max(30 * s, math.min(math.min(w, h) * 0.11, 62 * s))
    return {
        r = r,
        guns  = {x = w - r * 1.4, y = r * 1.5, r = r},
        bombs = {x = w - r * 1.4, y = r * 3.8, r = r * 0.8},
        -- The charge pair, inboard of the weapons and smaller: they are used
        -- once in a while rather than held, and the thumb that reaches them
        -- is not the thumb on the trigger.
        use   = {x = w - r * 3.3, y = r * 1.5, r = r * 0.72},
        swap  = {x = w - r * 3.3, y = r * 3.4, r = r * 0.6},
        home  = {x = r * 1.6,     y = r * 1.8, r = r * 1.15},
    }
end

local function near(pad, x, y, slack)
    local dx, dy = x - pad.x, y - pad.y
    local reach = pad.r * (slack or 1.3)
    return dx * dx + dy * dy <= reach * reach
end

-- Which control a finger landed on. The pads win over the stick wherever they
-- overlap, and everything on the left half that is not a pad is the stick, so
-- a thumb never has to find an exact spot to start steering.
local function zone(x, y, w, h, s)
    local L = M.layout(w, h, s)
    if near(L.guns, x, y) then return "guns" end
    if near(L.bombs, x, y) then return "bombs" end
    if near(L.use, x, y) then return "use" end
    if near(L.swap, x, y) then return "swap" end
    if x < w * 0.55 then return "stick" end
    return nil
end

-- This device has a touchscreen. Recorded separately from on_touch because
-- the interface eats the taps that land on its own buttons, and whether to
-- draw a stick and pads at all is a question about the device, not about
-- where the last finger happened to go.
function M.note_used()
    M.used = true
end

-- Feed Defold's multitouch action.
--
-- `screen_x`/`screen_y`, not `x`/`y`. On HTML5 Defold scales x and y into the
-- resolution game.project asks for -- 1280 by 800 -- rather than the size the
-- canvas actually is, so on a 390-point phone every touch arrived 3.3 times
-- too far to the right. The stick, the pads and the start screen's buttons
-- were all being tested against coordinates off the side of the screen, which
-- is why none of them worked on a phone. screen_x is the real drawable pixel
-- and needs no correction anywhere.
function M.on_touch(action, w, h, s)
    if not action.touch then return end
    M.used = true
    M.scale = s or 1
    for _, t in ipairs(action.touch) do
        local tx, ty = t.screen_x or t.x, t.screen_y or t.y
        if t.pressed then
            local z = zone(tx, ty, w, h, s)
            if z == "stick" and not stick then
                stick = {id = t.id, ox = tx, oy = ty, x = tx, y = ty}
            elseif z == "guns" then
                guns = t.id
            elseif z == "bombs" then
                bombs = t.id
            elseif z == "use" then
                use = t.id
            elseif z == "swap" then
                swap_tap = true
            end
        elseif t.released then
            if stick and stick.id == t.id then stick = nil end
            if guns == t.id then guns = nil end
            if bombs == t.id then bombs = nil end
            if use == t.id then use = nil end
        elseif stick and stick.id == t.id then
            stick.x, stick.y = tx, ty
        end
    end
end

-- Lifting a finger outside the window does not always produce a release, so
-- a lost touch has to be forgettable.
function M.release_all()
    stick, guns, bombs, use = nil, nil, nil, nil
end

-- Whether the swap pad was tapped since this was last asked. Consumed by the
-- read, because a tap is an event and the caller acts on it once.
function M.swapped()
    local t = swap_tap
    swap_tap = false
    return t
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
    if use then out[#out + 1] = sim.BTN_USE end
    if not stick then return out end

    local dx, dy = stick.x - stick.ox, stick.y - stick.oy
    local mag = math.sqrt(dx * dx + dy * dy)
    if mag < DEAD_PX * M.scale then return out end

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
    if mag > THRUST_PX * M.scale and math.abs(diff) < 1.0 then
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
-- follows the thumb belongs: touches and this layer are both in drawable
-- pixels counting up from the bottom, so there is nothing to convert.
-- What the use pad is holding, set by the caller each frame: the ready
-- charge's short name and how many are in hand. Drawn inside the pad rather
-- than in a row across the screen, because that is where the thumb already
-- is and where the question is asked.
M.ready = nil

function M.draw(u, w, h, s)
    if not M.used then return end
    local pal = require("arena.palette")
    local dim = pal.a(pal.DIM, 0.45)
    local live = pal.a(pal.FRIEND, 0.9)
    local L = M.layout(w, h, s)

    local function ring(px, py, r, col, segments)
        u:ring(px, py, r, 1.8 * s, segments or 26, col)
    end
    local function glow(pad, col)
        u:halo(pad.x, pad.y, pad.r * 1.25, 18, pal.a(col, 0.17))
    end

    ring(L.guns.x, L.guns.y, L.guns.r, guns and live or dim)
    if guns then glow(L.guns, pal.FRIEND) end
    ring(L.bombs.x, L.bombs.y, L.bombs.r, bombs and pal.a(pal.BOMB, 0.95) or dim)
    if bombs then glow(L.bombs, pal.BOMB) end
    -- The charge pair. Drawn always, in their own colour, so a pilot who has
    -- never found one still knows the control is there -- the same reason the
    -- stat row shows the upgrades you do not hold.
    ring(L.use.x, L.use.y, L.use.r, use and pal.a(pal.CHARGE_COL, 0.95) or dim)
    if use then glow(L.use, pal.CHARGE_COL) end
    ring(L.swap.x, L.swap.y, L.swap.r, pal.a(pal.CHARGE_COL, 0.4), 18)
    -- How many of the ready charge are in hand, as pips *inside* the use pad.
    -- A count you can see without reading, on the control that spends it --
    -- and nothing at all when you hold none, which is the same rule the
    -- hull's energy pip follows.
    --
    -- Inside rather than around: the pads sit close enough together that an
    -- arc outside one lands on its neighbour, which read as three loose dots
    -- floating between the controls rather than as the contents of one.
    local held = M.ready and M.ready.count or 0
    if held > 0 then
        local pitch = 9 * s
        for i = 1, held do
            u:disc(L.use.x + (i - 1) * pitch - (held - 1) * pitch / 2,
                   L.use.y, 3 * s, 7, pal.a(pal.CHARGE_COL, 0.95))
        end
    end

    if stick then
        ring(stick.ox, stick.oy, L.home.r, dim)
        ring(stick.x, stick.y, L.r * 0.42, live, 16)
        u:seg(stick.ox, stick.oy, stick.x, stick.y, 2 * s, live)
    else
        -- A resting mark where a thumb should go. The stick itself is
        -- relative -- it appears wherever you press -- but a control that is
        -- invisible until you find it is a control nobody finds.
        ring(L.home.x, L.home.y, L.home.r, pal.a(pal.DIM, 0.28))
        ring(L.home.x, L.home.y, L.r * 0.3, pal.a(pal.DIM, 0.35), 16)
    end
end

return M
