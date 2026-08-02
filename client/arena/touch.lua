-- Touch controls.
--
-- The question platforms.md asks is whether mobile is a playing client or a
-- spectating one. This is the playing answer: a thumbstick that points where
-- you want to go, and pads for the weapons and the charges.
--
-- Pointing beats a rotate-left/rotate-right pair on glass. There is no tactile
-- edge to feel for, so a player cannot hold a rotation and stop it on time;
-- they can put a thumb where they want to be going. The ship still turns at
-- its own rate, so nothing about the flight model changes -- this only decides
-- which way the turn is applied, exactly as the AI does it. Both alternatives
-- have been built and both were worse: a relative stick read as two keyboard
-- axes, and a drawn d-pad. They make the pilot hold a rotation and judge when
-- to release it, which is the thing glass cannot help you do.
--
-- Where the thumb points is a course, not a facing. Ask for one behind you
-- and the ship backs up rather than turning around, which is how the stick
-- reaches the half of the flight model that Down owns on a keyboard.
--
-- The simulation never learns any of this happened: it receives the same
-- button bitfield a keyboard produces.

local M = {}

local DEAD_PX = 14        -- ignore a thumb that has barely moved
local THRUST_PX = 46      -- push past this and the engine lights

-- An angle folded into [-pi, pi]. Written once because it is wanted twice and
-- the second copy is where a sign error hides.
local function wrap(a)
    while a > math.pi do a = a - math.pi * 2 end
    while a < -math.pi do a = a + math.pi * 2 end
    return a
end

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
    local guns  = {x = w - r * 1.4, y = row, r = r}
    local bombs = {x = guns.x - (r + gap + r * 0.8), y = row, r = r * 0.8}
    local home  = {x = r * 1.6, y = r * 1.8, r = r * 1.15}

    -- The charges continue the row, smaller: they are tapped once in a while
    -- rather than held, and a target the size of a trigger would crowd the
    -- one control a thumb must never miss. They start clear of whichever
    -- weapon pad is actually drawn, so a hull with no rack closes the gap
    -- instead of leaving a hole where the bomb pad would have been.
    local cr = r * 0.55
    local lead = M.has_bomb and bombs or guns
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
            x, y, edge = guns.x, y + r + gap + cr, cr
        end
        charge[i] = {slot = k, x = x, y = y, r = cr}
        x = x - (cr * 2 + gap)
    end

    return {r = r, guns = guns, bombs = bombs, home = home, charge = charge}
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
                stick = {id = t.id, ox = tx, oy = ty, x = tx, y = ty,
                         px = 0, py = 0, swept = 0, calm = 0, waited = 0}
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
end

-- How far around the stick a thumb travels before this counts as asking for a
-- new course rather than trimming the one it has, and how fast it has to be
-- going for the ship to give up trying to follow. The rate is the meaningful
-- one: a hull turns about a revolution a second, so a thumb crossing faster
-- than that is not asking for a turn, because no turn could keep up with it.
--
-- Both, not either. Rate alone would gate the quick small corrections you
-- make tracking somebody; distance alone cannot tell an arc from a re-aim
-- until it lands.
local SWEEP = math.pi * 2 / 9        -- forty degrees
local GATE = 3.5                     -- radians a second, about two hundred
local LAND = 0.08                    -- seconds below the gate before deciding
local PATIENCE = 0.6                 -- and a stop, for a thumb going in circles

-- How near the thumb has to come to a ship before the swipe is read as
-- pointing at it rather than past it. Generous, because a thumb on glass is
-- worth about twenty degrees on a good day and the thing it is pointing at is
-- moving: a cone you have to hit is a cone that reads as broken.
local AIM = math.pi * 5 / 18         -- fifty degrees

-- The enemy a swipe is read against: {id, bearing}, or nil when nobody is
-- close enough to be the one you are fighting. Set by the caller each frame,
-- because which ship that is belongs to the game, not to the controls.
--
-- One ship, the nearest, rather than every enemy on screen. In a melee a cone
-- astern has somebody in it more often than not, and a rule that turns you
-- around a third of the times you meant to back off is worse than no rule.
M.foe = nil

-- One frame of stick tracking.
--
-- Called once a frame by the caller rather than folded into bits(), which is
-- asked three times -- once for the network, once for the step, once to know
-- whether to draw a flame -- so anything accumulated in there would be
-- counted three times over.
--
-- Everything here is in seconds rather than frames. Frames were what the
-- first version counted, and under a software rasteriser they are not a
-- clock: whether a sweep was seen as a sweep depended on how long the last
-- frame happened to take.
function M.tick(dt)
    local s = stick
    if not s then return end
    dt = math.max(dt or 0, 1e-4)
    local dx, dy = s.x - s.ox, s.y - s.oy

    -- Crossing the origin: the offset reverses between frames whatever the
    -- speed, which is how a thumb pulled straight back and out the far side
    -- announces itself. Re-arms the choice on the spot; there is nothing to
    -- settle, because the ship has already stopped turning in the middle.
    if s.px * dx + s.py * dy < 0 then s.back, s.swept = nil, 0 end
    s.px, s.py = dx, dy

    local ang = math.atan2(dx, dy)
    local turned = s.ang and math.abs(wrap(ang - s.ang)) or 0
    s.ang = ang
    s.swept = s.swept + turned
    if turned / dt > GATE then s.calm = 0 else s.calm = s.calm + dt end
    if s.settling then s.waited = s.waited + dt end

    -- Whether the thumb is pointing at the ship you are fighting. Tracked
    -- every frame rather than only when the choice is read, so the caller can
    -- mark that ship while the thumb is still on its way there -- the rule is
    -- only fair if you can see it decide.
    local out = dx * dx + dy * dy >= (DEAD_PX * M.scale) ^ 2
    if out and M.foe and math.abs(wrap(ang - M.foe.bearing)) < AIM then
        s.aimed = M.foe.id
    else
        s.aimed = nil
    end
end

-- The ship the thumb is pointing at, if any, so it can be marked on screen.
function M.aiming()
    return stick and stick.aimed or nil
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
function M.bits(heading)
    local out = {}
    if guns then out[#out + 1] = sim.BTN_FIRE end
    if bombs then out[#out + 1] = sim.BTN_BOMB end
    if not stick then return out end

    local dx, dy = stick.x - stick.ox, stick.y - stick.oy
    local mag = math.sqrt(dx * dx + dy * dy)

    if mag < DEAD_PX * M.scale then
        stick.back, stick.swept, stick.ang = nil, 0, nil
        stick.settling = false
        return out
    end

    -- A sweep, not a correction: the thumb has gone far enough around the
    -- stick to be asking for a different course rather than trimming this
    -- one. Hold the rudder and the engine until the hand finishes.
    --
    -- The hold is the whole trick. The choice of which end leads is read from
    -- the thumb against the heading, and the ship spends every frame turning
    -- that heading toward the thumb -- so by the time an arc lands, the angle
    -- the choice would be read from has already been dragged most of the way
    -- closed, and the answer comes out as whatever the hull happened to be
    -- able to turn in the time. An Apex turns 1.05 revolutions a second; an
    -- Anvil does not; the same gesture meant different things in different
    -- ships. Stop turning and the reading is honest again.
    --
    -- It has to be a hold rather than a test on the jump itself, because at
    -- the instant a thumb leaves, an eighty-degree re-aim and the first frame
    -- of a half-circle arc are the same event. Only where it lands tells them
    -- apart, and that is a hundred milliseconds later.
    if not stick.settling and stick.swept > SWEEP then
        stick.settling, stick.waited = true, 0
    end
    if stick.settling then
        -- Out once the thumb has been below the gate long enough to have
        -- landed, or on the patience cap, so a thumb going in circles cannot
        -- leave the ship without a rudder.
        if stick.calm < LAND and stick.waited < PATIENCE then return out end
        stick.settling, stick.swept, stick.back = false, 0, nil
    end

    -- Screen +y is up and the simulation's +y is down, which is why this is
    -- atan2(x, y) rather than the atan2(dx, -dy) the AI uses on sim vectors.
    local want = math.atan2(dx, dy)
    local head = (heading / 65536) * math.pi * 2
    local diff = wrap(want - head)

    -- Which end of the ship goes toward the thumb: whichever is already
    -- nearer it. The stick asks for a direction of travel, not for a place to
    -- point, so a course that is behind you backs the ship up instead of
    -- spinning it around -- which is the move the pointing stick could never
    -- make, holding your guns on somebody while the range opens.
    --
    -- The keyboard says the same thing with a heading and a thrust sign. This
    -- infers the sign from the geometry, because the thumbs are all spoken
    -- for: steering, the engine and the trigger are three things to hold and
    -- there are two thumbs, and the only reason the stick works at all is
    -- that it folds the engine into the steering.
    --
    -- Read once, when the thumb commits, and held until it asks again --
    -- through the middle, or by sweeping. Held rather than re-read every
    -- frame so the ship cannot change its mind about which end leads halfway
    -- through a manoeuvre, which is also why there is no hysteresis here: a
    -- choice made once has nothing to oscillate against.
    if stick.back == nil then
        -- Behind you means back up -- unless you are pointing at the ship you
        -- are fighting, which always means turn and face them.
        --
        -- Those two are the same gesture. Swiping astern in a fight means
        -- "open the range" when the enemy is in front of you and "come about"
        -- when they are behind you, and nothing in the swipe itself can tell
        -- them apart -- which is why every tuning of thresholds, rates and
        -- hysteresis kept being right half the time. The difference is not in
        -- the hand, it is on the screen, so that is where it is read from.
        --
        -- Old ground: an action game locks on for the same reason, because
        -- one stick cannot say where you face and where you go at once, and
        -- a fighting game quietly flips what "back" means when you cross
        -- sides. Reading the input against what you are fighting is the
        -- standard answer, not a trick.
        stick.back = math.abs(diff) > math.pi / 2 and stick.aimed == nil
        stick.swept = 0
    end

    local err = stick.back and wrap(diff - math.pi) or diff

    if err > 0.06 then out[#out + 1] = sim.BTN_RIGHT
    elseif err < -0.06 then out[#out + 1] = sim.BTN_LEFT end

    -- Burn once the thumb is committed and the chosen end is roughly there,
    -- so a hard turn does not fling the ship the way it used to be facing.
    if mag > THRUST_PX * M.scale and math.abs(err) < 1.0 then
        out[#out + 1] = stick.back and sim.BTN_REVERSE or sim.BTN_THRUST
    end
    return out
end

-- Whether the stick is currently backing the ship up rather than driving it
-- forward, so the caller can show it. An inferred control has to be legible
-- or it reads as the game doing something you did not ask for.
function M.reversing()
    return stick ~= nil and stick.back == true
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
        -- Amber while the ship is backing up rather than driving forward.
        -- The retro flames on the hull are the feedback that matters, since
        -- that is where a pilot is looking; this is for the glance down.
        local col = M.reversing() and pal.a(pal.THRUST, 0.9) or live
        ring(stick.ox, stick.oy, L.home.r, dim)
        ring(stick.x, stick.y, L.r * 0.42, col, 16)
        u:seg(stick.ox, stick.oy, stick.x, stick.y, 2 * s, col)
    else
        -- A resting mark where a thumb should go. The stick itself is
        -- relative -- it appears wherever you press -- but a control that is
        -- invisible until you find it is a control nobody finds.
        ring(L.home.x, L.home.y, L.home.r, pal.a(pal.DIM, 0.28))
        ring(L.home.x, L.home.y, L.r * 0.3, pal.a(pal.DIM, 0.35), 16)
    end
end

return M
