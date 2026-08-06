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
-- One course is not a turn: dead astern. A thumb pulled straight behind the
-- ship holds the nose and backs away, which is the fight's own gesture, since
-- backing off the thing you are shooting at is most of what reverse is for.
-- The cone is generous enough to land in and narrow enough that turning
-- around survives: ask anywhere outside it and the ship comes about as it
-- always did. See REAR below, and the chevrons in draw that say it took.
--
-- The simulation never learns any of this happened: it receives the same
-- button bitfield a keyboard produces.

local M = {}

local DEAD_PX = 14        -- ignore a thumb that has barely moved
local THRUST_PX = 46      -- push past this and the engine lights
-- How far either side of dead astern still reads as "back up" rather than as
-- a course to turn to, in radians. Wide enough that a thumb aiming for
-- behind lands in it, narrow enough that a player asking for a turnaround,
-- who sweeps or asks off-axis, never falls in by accident.
local REAR = 0.61

M.used = false            -- has this device ever reported a touch?
M.scale = 1               -- drawable pixels per point
-- How many of each charge slot are in hand, by slot. Set by the caller.
M.counts = {}

-- Whether the hull flying has a bomb rack. Two of the eight do not, and a pad
-- for a weapon that cannot exist is a pad that does nothing when pressed --
-- worse than useless, because it also swallows the touch. Set by the caller,
-- and true until told otherwise so a missing update never removes a control
-- somebody actually has.
M.has_bomb = true

local stick = nil         -- {id, ox, oy, x, y}
local guns = nil          -- touch id holding the guns pad
local bombs = nil
-- Which charge a tap asked for, latched and read once.
--
-- One pad per kind rather than a use pad and a swap pad. The simulation takes
-- the slot in the buttons and keeps no selection of its own, so "fire slot k"
-- was always expressible -- swapping was one way for an interface to choose
-- and it is the worse one on glass: two taps to spend a thing, and a state to
-- read back before either of them means anything.
--
-- Latched rather than held, because a charge is a thing you spend. A held pad
-- would spend a second one the moment the cooldown lapsed, and there are only
-- three.
local fired = nil

-- The charge slots this hull can carry, newest set by the caller. Empty until
-- told, so a hull with none draws none.
M.charges = {}

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
--
-- Everything the right thumb touches is one row along the bottom, walking
-- left from the corner: guns, then bombs, then a pad per charge. Stacking
-- them up the right edge instead cost the radar its corner and still did not
-- fit -- the band between the top weapon and the dial is about a fifth of a
-- landscape phone, and two pads want more than that. A row has the whole
-- width to spend and keeps every control inside one thumb's arc.
function M.layout(w, h, s)
    s = s or 1
    local r = math.max(30 * s, math.min(math.min(w, h) * 0.11, 62 * s))
    local gap = r * 0.35
    local row = r * 1.5
    local gun_pad  = {x = w - r * 1.4, y = row, r = r}
    local bomb_pad = {x = gun_pad.x - (r + gap + r * 0.8), y = row,
                      r = r * 0.8}
    local home  = {x = r * 1.6, y = r * 1.8, r = r * 1.15}

    -- The charges continue the row, smaller: they are tapped once in a while
    -- rather than held, and a target the size of a trigger would crowd the
    -- one control a thumb must never miss. They start clear of whichever
    -- weapon pad is actually drawn, so a hull with no rack closes the gap
    -- instead of leaving a hole where the bomb pad would have been.
    local cr = r * 0.55
    local lead = M.has_bomb and bomb_pad or gun_pad
    local x = lead.x - lead.r - gap - cr
    local y = row
    -- The stick's resting mark owns the other corner, and a pad that reaches
    -- it is a pad the steering thumb presses by accident. Past that point the
    -- row wraps upward instead -- which is what a narrow phone held upright
    -- does, and it is why this is a limit rather than an assumption that the
    -- width is always there.
    local edge = home.x + home.r * 1.6
    local charge = {}
    for i, k in ipairs(M.charges) do
        if x - cr < edge then
            x, y, edge = gun_pad.x, y + r + gap + cr, cr
        end
        charge[i] = {slot = k, x = x, y = y, r = cr}
        x = x - (cr * 2 + gap)
    end

    return {r = r, guns = gun_pad, bombs = bomb_pad, home = home,
            charge = charge}
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
    -- Not tested when the hull has no rack, so the space falls through to the
    -- stick rather than being eaten by a control that is not drawn.
    if M.has_bomb and near(L.bombs, x, y) then return "bombs" end
    for _, c in ipairs(L.charge) do
        if near(c, x, y) then return c.slot end     -- a number, not a name
    end
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
            elseif type(z) == "number" then
                fired = z
            end
        elseif t.released then
            if stick and stick.id == t.id then stick = nil end
            if guns == t.id then guns = nil end
            if bombs == t.id then bombs = nil end
        elseif stick and stick.id == t.id then
            stick.x, stick.y = tx, ty
        end
    end
end

-- Lifting a finger outside the window does not always produce a release, so
-- a lost touch has to be forgettable.
function M.release_all()
    stick, guns, bombs = nil, nil, nil
    M.reversing = false
end

-- Which charge slot was tapped since this was last asked, or nil. Consumed by
-- the read, because a tap is an event and the caller acts on it once.
function M.fired_charge()
    local k = fired
    fired = nil
    return k
end

-- The bits held this frame, given where the ship is currently pointing.
--
-- A list rather than a bitfield, because the caller merges this with the
-- keyboard and HTML5 builds run Lua 5.1, which has no bitwise or. Summing a
-- set of distinct bits is exact and needs no library.
-- Whether the stick is asking for reverse this frame, for the chevrons in
-- draw: the arithmetic lives in bits and the drawing must not repeat it.
M.reversing = false

function M.bits(heading)
    local out = {}
    if guns then out[#out + 1] = sim.BTN_FIRE end
    if bombs then out[#out + 1] = sim.BTN_BOMB end
    if not stick then
        M.reversing = false
        return out
    end

    local dx, dy = stick.x - stick.ox, stick.y - stick.oy
    local mag = math.sqrt(dx * dx + dy * dy)
    if mag < DEAD_PX * M.scale then
        M.reversing = false
        return out
    end

    -- Screen +y is up and the simulation's +y is down, which is why this is
    -- atan2(x, y) rather than the atan2(dx, -dy) the AI uses on sim vectors.
    local want = math.atan2(dx, dy)
    local head = (heading / 65536) * math.pi * 2
    local diff = want - head
    while diff > math.pi do diff = diff - math.pi * 2 end
    while diff < -math.pi do diff = diff + math.pi * 2 end

    -- Dead astern, and a cone either side of it: hold the nose and back
    -- toward the thumb rather than turning to it. The rudder stays out of it
    -- entirely, because a retreat that slewed the nose would take the guns
    -- off the thing being retreated from, and keeping them on it is the
    -- point of backing up. The cone tracks the live heading, so a course
    -- asked outside it can never wander in: the nose only ever turns toward
    -- the ask, and the gap between them only shrinks.
    if math.abs(diff) > math.pi - REAR then
        M.reversing = mag > THRUST_PX * M.scale
        if M.reversing then out[#out + 1] = sim.BTN_REVERSE end
        return out
    end
    M.reversing = false

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
    if M.has_bomb then
        ring(L.bombs.x, L.bombs.y, L.bombs.r,
             bombs and pal.a(pal.BOMB, 0.95) or dim)
        if bombs then glow(L.bombs, pal.BOMB) end
    end
    -- A pad per charge, each with a picture of what it does inside it, drawn
    -- whether or not you hold any: the same reason the stat row shows the
    -- upgrades you do not have.
    --
    -- The icon is drawn from the weapon's own behaviour rather than from a
    -- second field that could disagree with it, which is the rule the client
    -- already follows for projectiles: a repel shoves and hurts nobody, so it
    -- is rings going outward; a burst is many rounds at once, so it is a
    -- rosette. Anything a zone puts in the other two slots gets a plain disc
    -- and ui.lua's short name over it, which says "a charge" honestly rather
    -- than drawing a repel and being wrong.
    --
    -- The count is a numeral from ui.lua, because glyphs are the one thing a
    -- bare mesh cannot do.
    for _, c in ipairs(L.charge) do
        local n = M.counts and M.counts[c.slot] or 0
        local lit = n > 0
        ring(c.x, c.y, c.r, lit and pal.a(pal.CHARGE_COL, 0.9) or dim)
        local ic = pal.a(pal.CHARGE_COL, lit and 0.85 or 0.28)
        if c.slot == 0 then                       -- repel: a shove outward
            u:ring(c.x, c.y, c.r * 0.30, 1.4 * s, 14, ic)
            u:ring(c.x, c.y, c.r * 0.52, 1.2 * s, 16, ic)
        elseif c.slot == 1 then                   -- burst: a rosette
            for i = 0, 7 do
                local a = i * math.pi / 4
                u:disc(c.x + math.cos(a) * c.r * 0.46,
                       c.y + math.sin(a) * c.r * 0.46, 2.2 * s, 6, ic)
            end
        else
            u:disc(c.x, c.y, c.r * 0.22, 10, ic)
        end
    end

    if stick then
        ring(stick.ox, stick.oy, L.home.r, dim)
        ring(stick.x, stick.y, L.r * 0.42, live, 16)
        u:seg(stick.ox, stick.oy, stick.x, stick.y, 2 * s, live)
        -- Backing up, said at the thumb: chevrons past the head, pointing the
        -- way the ship is actually going, which is toward the thumb and tail
        -- first. Without them a reverse the player fell into by accident is
        -- a ship that stopped obeying the stick.
        if M.reversing then
            local dx, dy = stick.x - stick.ox, stick.y - stick.oy
            local m = math.sqrt(dx * dx + dy * dy)
            if m > 0 then
                local ux, uy = dx / m, dy / m
                local hr = L.r * 0.42
                for i = 1, 2 do
                    local bx = stick.x + ux * hr * (0.9 + 0.6 * i)
                    local by = stick.y + uy * hr * (0.9 + 0.6 * i)
                    local tx, ty = bx + ux * hr * 0.4, by + uy * hr * 0.4
                    u:seg(bx - uy * hr * 0.45, by + ux * hr * 0.45,
                          tx, ty, 1.8 * s, live)
                    u:seg(bx + uy * hr * 0.45, by - ux * hr * 0.45,
                          tx, ty, 1.8 * s, live)
                end
            end
        end
    else
        -- A resting mark where a thumb should go. The stick itself is
        -- relative -- it appears wherever you press -- but a control that is
        -- invisible until you find it is a control nobody finds.
        ring(L.home.x, L.home.y, L.home.r, pal.a(pal.DIM, 0.28))
        ring(L.home.x, L.home.y, L.r * 0.3, pal.a(pal.DIM, 0.35), 16)
    end
end

return M
