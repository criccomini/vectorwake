-- Touch controls.
--
-- The question platforms.md asks is whether mobile is a playing client or a
-- spectating one. This is the playing answer: one thumb for flying, and pads
-- for the weapons.
--
-- What the flying thumb reads depends on what the screen is doing, and the two
-- answers come out opposite.
--
-- In the ordinary north-up view it is a thumbstick that points where you want
-- the nose to go. Pointing beats a rotate-left/rotate-right pair on glass:
-- there is no tactile edge to feel for, so a player cannot hold a rotation and
-- stop it on time, but they can put a thumb where they want to be facing. The
-- ship still turns at its own rate, so nothing about the flight model changes.
-- This only decides which way the turn is applied, exactly as the AI does it.
--
-- A player who would rather push than point gets a d-pad instead, which is a
-- setting. Eight ways, so a diagonal thrusts and turns at once, and the turn
-- runs for as long as the thumb is held. It is the older idiom and it is the
-- one a thumb raised on other games arrives already knowing, which is worth
-- more than the argument above to the player who wants it.
--
-- The pad is anchored where the resting mark sits, unlike the stick, which
-- appears wherever a thumb lands. Anchoring is what makes it tappable: a tap
-- on the left arm is a nudge left, with no drag to perform first, and a fixed
-- position is the closest glass gets to a tactile edge, because the thumb
-- learns where left lives. It is also what pays for the pad's known cost. A
-- held turn runs on until the thumb answers what the eye sees, which is a
-- fifth of a second late, and at these hulls' turn rates that is thirty-odd
-- degrees past wherever the player meant to stop; the correction has to be a
-- tap, so taps have to exist.
--
-- Fresh turns also ramp: a turn starts at a fraction of the hull's rate and
-- reaches full over a quarter second held, so a tap nudges a few degrees and
-- a committed swing still spins. The simulation knows nothing of it. The rate
-- is the hull's own and the client cannot change it, so the ramp is made by
-- withholding the turn bit on a share of ticks, which the input path treats
-- like any other buttons and the render smoothing hides.
--
-- Reverse has no pad of its own anywhere. On the d-pad, down is backwards.
-- On the stick it is read from intent: in a fight, a push away from where the
-- nose points backs the ship out with its guns still on it, which is the only
-- moment backwards is worth a full-strength engine (and it is full strength:
-- the simulation applies the same thrust either sign). "In a fight" is the
-- trigger held, or a hostile close ahead, and the second half is what keeps a
-- kite whole: guns lift between bursts to let the energy climb, and the ship
-- must not wheel toward its own retreat every time they do. See
-- arena/threat.lua for what counts and for the two signals deliberately not
-- consulted. The held pad this replaces sat above the stick and went unused,
-- because the thumb that could hold it was the thumb already steering.
--
-- The simulation never learns any of this happened: it receives the same
-- button bitfield a keyboard produces.
--
-- Every control wears the mark of the thing it does, from arena/marks.lua,
-- which is the same drawing the corner stack uses. That was the whole fault
-- of the layout this replaces: the two triggers were bare rings telling each
-- other apart by being slightly different sizes, while the charges beside
-- them carried pictures, so the control pressed most was the only one that
-- did not say what it was.
--
-- It also settles what the corner stack is for on a phone. A pad draws the
-- whole mark, add-ons and all, by calling the same marks.weapon the stack
-- calls, so the stack drops its weapon rows on a touchscreen instead of
-- repeating them at the far corner.

local M = {}

local marks = require("arena.marks")
local pal = require("arena.palette")

local DEAD_PX = 14        -- ignore a thumb that has barely moved
-- While firing, how far from the nose a push has to point before it means
-- "back out" rather than "turn there", and how close it has to come back
-- before it means turning again. Two numbers rather than one because a thumb
-- resting near the boundary would otherwise flap between the ship's two ends
-- several times a second.
local REAR_ENTER = 1.75   -- radians past this, a firing push steers the tail
local REAR_EXIT = 1.40    -- and back inside this, the nose again
-- The pad's inert middle, as a share of its radius: a thumb resting on the
-- anchor is resting, not steering. The stick needs no such gap because its
-- center is wherever the thumb pressed, which cannot be pressed again.
local PAD_GAP = 0.24
-- What share of the hull's turn rate a fresh turn starts at, and how long it
-- is held before the whole rate arrives. The floor is the tap: at these
-- numbers a quick tap turns a few degrees. The window is the reaction time it
-- exists to forgive, and matching it is what makes the end of a deliberate
-- swing arrive gently instead of thirty degrees late.
local RAMP_FLOOR = 0.4
local RAMP_S = 0.25
local THRUST_PX = 46      -- push past this and the engine lights
local FAN_SWIPE_PX = 32   -- deliberate upward pull while holding the gun

M.used = false            -- has this device ever reported a touch?
-- Whether the flying thumb gets a d-pad rather than the stick. Set by the
-- arena from the player's setting; it decides what a thumb direction means.
M.dpad = false
-- Whether a hostile sits close ahead of the nose, set by the arena each
-- frame from arena/threat.lua. Half of what "in a fight" means to the stick.
M.threat = false
M.scale = 1               -- drawable pixels per point
-- How many of each charge slot are in hand, by slot. Set by the caller.
M.counts = {}
-- And how many of each the hull can hold, which is what the pips count out.
M.maxes = {}

-- Whether the hull flying has a bomb rack. A zone may remove one, and a pad for
-- a weapon that cannot exist does nothing when pressed. It is worse than useless
-- because it also swallows the touch. Set by the caller, and true until told
-- otherwise so a missing update never removes a control somebody actually has.
M.has_bomb = true

-- Whether the hull flying is carrying a fan on either trigger, and whether it
-- is currently declined. Set by the caller.
--
-- False until told otherwise, which is the opposite of `has_bomb` and the safe
-- direction for each: a rack is the ordinary case and a missing update must not
-- take the bomb pad away, while a fan is something you pick up. Multifire is
-- worked as an upward pull from the gun pad, so it adds no target to the rail.
M.has_fan = false
M.multi_off = false

-- What an iPhone's island, notch, or browser toolbar covers, in drawable
-- pixels, set by the caller from what the page measures. The pads and the
-- stick's resting mark step inside them. The caller leaves the bottom at zero
-- for a bare home indicator, which may overlay the controls, and supplies it
-- only when browser chrome would swallow the row.
M.safe_l = 0
M.safe_r = 0
M.safe_b = 0

-- Which ship is yours, so a pad can read its own weapon out of the core
-- rather than have every fact about it copied into a field here. nil before
-- the first frame, and the marks fall back to a plain gun and a plain bomb.
M.me = nil

-- How high the utility row may climb, in drawable pixels from the bottom. The
-- dial owns the top right corner and a pad that reaches it is a pad over an
-- instrument, so the caller hands down where the dial ends. Passed rather
-- than asked for: this file knows where a thumb goes and ui.lua knows where
-- the instruments go, and neither reaching into the other is what let the two
-- of them stop depending on each other at all.
M.ceiling = math.huge

local stick = nil         -- {id, ox, oy, x, y}
-- Whether the stick is currently steering the tail (firing, push rearward).
-- Kept between reads for the hysteresis above, and dropped with the stick.
local rear = false
local guns = nil          -- touch id holding the guns pad
local gun_ox, gun_oy = nil, nil
local gun_fanned = false
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

-- The turn ramp: which way the pad is turning, how long it has been held, and
-- the running remainder that decides which ticks get the turn bit. The
-- accumulator starts at one so the first frame of any fresh turn always
-- answers; a pad that waited a frame to say anything would read as broken in
-- exactly the moment a tap is quickest.
local ramp = {dir = 0, held = 0, acc = 1}

-- Whether an upward gun pull happened since it was last asked. The core toggles
-- multifire on a rising edge, so one gun hold may produce at most one edge.
local fanned = false

-- The charge slots this hull can carry, newest set by the caller. Empty until
-- told, so a hull with none draws none. A mine is one of them: it used to be
-- a cell of its own tied to the bomb pad, and it is a count you carry and
-- spend now, which is what every cell on this rail already is.
M.charges = {}

-- Where the controls are. One definition, used by the hit test and by the
-- drawing, because they were written out separately once and had drifted: the
-- pads were drawn at one height and tested at another, so half of a pad did
-- nothing and the dead space beside it fired.
--
-- Coordinates are drawable pixels counting up from the bottom, which is the
-- space `screen_x`/`screen_y` arrive in and the space the interface layer
-- projects, so nothing has to be converted. Sized off the smaller screen
-- dimension so a pad is a thumb wide on a phone and does not become a dinner
-- plate on a monitor, with the limits in points rather than pixels: a phone
-- at two pixels per point would otherwise get pads half the size it needs.
--
-- The two triggers keep the corner, side by side along the bottom. Their
-- secondary actions form one fixed row above them: charge slots in stable
-- positions, two over the guns and the rest continuing left over the bomb.
-- Empty slots disappear but never pull a neighbor into their place. Reverse
-- mirrors that row above the flight stick.
function M.layout(w, h, s)
    s = s or 1
    local r = math.max(30 * s, math.min(math.min(w, h) * 0.11, 62 * s))
    local br = r * 0.82
    -- Far enough in that the rim clears the edge of the screen with a thumb's
    -- worth of margin: a control hard against the bezel is one a hand has to
    -- curl round to reach.
    local gun_pad  = {x = w - M.safe_r - r * 1.4,
                      y = M.safe_b + r * 1.4, r = r}
    local bomb_pad = {x = gun_pad.x - r - br - r * 0.34, y = gun_pad.y, r = br}
    local home  = {x = M.safe_l + r * 1.6,
                   y = M.safe_b + r * 1.8, r = r * 1.15}

    -- Secondary controls are square, smaller on screen than the triggers but
    -- enlarged to a full thumb target by `within`. Their row clears the
    -- triggers' enlarged hit circles, not merely their visible rims.
    local cw = r * 0.82
    local cell_reach = cw * 0.65
    local step = cell_reach * 2 + s
    local wanted_y = gun_pad.y + gun_pad.r * 1.3 + cell_reach + 4 * s
    local y0 = math.min(wanted_y, M.ceiling - cw / 2)

    -- Charge slots keep their configured identity. The first two sit over the
    -- weapons and the rest continue left past the bomb.
    local charge = {}
    for i, k in ipairs(M.charges) do
        if (M.counts and M.counts[k] or 0) > 0 then
            local x
            if i <= 2 then x = gun_pad.x - (i - 1) * step
            else x = bomb_pad.x - (i - 3) * step end
            charge[#charge + 1] = {slot = k, x = x, y = y0,
                                   w = cw, r = cw / 2}
        end
    end

    return {r = r, guns = gun_pad, bombs = bomb_pad, home = home,
            charge = charge}
end

local function near(pad, x, y, slack)
    local dx, dy = x - pad.x, y - pad.y
    local reach = pad.r * (slack or 1.18)
    return dx * dx + dy * dy <= reach * reach
end

-- A cell is square, and so is what it answers to. Grown by the same margin a
-- round pad is, because a thumb landing a few pixels outside a control meant
-- to be hit is a thumb that meant to hit it.
local function within(c, x, y)
    local reach = c.w * 0.65
    return math.abs(x - c.x) <= reach and math.abs(y - c.y) <= reach
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
        if within(c, x, y) then return c.slot end   -- a number, not a name
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
-- `claimed` is the set of touch ids the interface took before this was called:
-- a finger scrolling the scoreboard, or one that landed on a hit box. Only
-- their presses are skipped. A release is always honored whoever it belongs
-- to, because a release exists to let go of something and the id that never
-- grabbed anything lets go of nothing.
--
-- The list-dragging finger used to arrive here unmarked. The scoreboard sits
-- in the left column, which is the stick's half of the screen, so scrolling it
-- mid-flight also grabbed the stick: reading the scores turned the ship and,
-- past a longer drag, lit the engine.
function M.on_touch(action, w, h, s, claimed)
    if not action.touch then return end
    M.used = true
    M.scale = s or 1
    for _, t in ipairs(action.touch) do
        local tx, ty = t.screen_x or t.x, t.screen_y or t.y
        if t.pressed and claimed and claimed[t.id] then
            -- taken by the interface; it starts nothing here
        elseif t.pressed then
            local z = zone(tx, ty, w, h, s)
            if z == "stick" and not stick then
                if M.dpad then
                    -- Anchored: the pad's center is the resting mark, not the
                    -- press, so the press itself already names a direction
                    -- and a tap needs no drag to mean something.
                    local hm = M.layout(w, h, s).home
                    stick = {id = t.id, ox = hm.x, oy = hm.y, x = tx, y = ty,
                             gap = hm.r * PAD_GAP}
                else
                    stick = {id = t.id, ox = tx, oy = ty, x = tx, y = ty}
                end
            elseif z == "guns" then
                guns = t.id
                gun_ox, gun_oy = tx, ty
                gun_fanned = false
            elseif z == "bombs" then
                bombs = t.id
            elseif type(z) == "number" then
                fired = z
            end
        elseif t.released then
            M.release(t.id)
        else
            if stick and stick.id == t.id then
                stick.x, stick.y = tx, ty
            elseif guns == t.id and M.has_fan and not gun_fanned then
                local dx, dy = tx - gun_ox, ty - gun_oy
                if dy >= FAN_SWIPE_PX * M.scale
                    and math.abs(dx) <= dy * 1.25 then
                    fanned = true
                    gun_fanned = true
                end
            end
        end
    end
end

-- Forget one finger wherever its release was consumed. The arena handles UI
-- presses before flight controls, so one finger can open a panel in the same
-- batch that another leaves a pad. Passing that release through here first
-- keeps the panel's early return from leaving the other control held.
function M.release(id)
    if stick and stick.id == id then
        stick = nil
        rear = false
        ramp.dir, ramp.held, ramp.acc = 0, 0, 1
    end
    if guns == id then
        guns, gun_ox, gun_oy, gun_fanned = nil, nil, nil, false
    end
    if bombs == id then bombs = nil end
end

-- Lifting a finger outside the window does not always produce a release, so
-- a lost touch has to be forgettable.
function M.release_all()
    stick, guns, bombs = nil, nil, nil
    rear = false
    ramp.dir, ramp.held, ramp.acc = 0, 0, 1
    gun_ox, gun_oy, gun_fanned = nil, nil, false
end

-- Which charge slot was tapped since this was last asked, or nil. Consumed by
-- the read, because a tap is an event and the caller acts on it once.
function M.fired_charge()
    local k = fired
    fired = nil
    return k
end

-- Whether an upward gun pull happened since this was last asked. Consumed by
-- the read so one gesture is one toggle however many frames pass first.
function M.fired_multi()
    local hit = fanned
    fanned = false
    return hit
end

-- The bits held this frame, given where the ship is currently pointing.
--
-- A list rather than a bitfield, because the caller merges this with the
-- keyboard and HTML5 builds run Lua 5.1, which has no bitwise or. Summing a
-- set of distinct bits is exact and needs no library.
-- Which way the pad is being pushed, as the four arms it lights.
--
-- Read by the input and by the drawing, so the arm that lights is the arm that
-- is doing something rather than a second opinion about the same thumb. All
-- four come back false while nothing is pushing it.
--
-- Eight ways, so a diagonal thrusts and turns at once. Sectors rather than a
-- threshold on each axis, because independent thresholds leave a corner where
-- a thumb pushed exactly between two of them does nothing at all.
local function pad_arms()
    if not stick then return false, false, false, false end
    local dx, dy = stick.x - stick.ox, stick.y - stick.oy
    -- The inert middle. The anchored pad's is sized to the pad, because its
    -- center can be pressed directly; the drag threshold is for a stick whose
    -- center is wherever the press was.
    local dead = stick.gap or (DEAD_PX * M.scale)
    if dx * dx + dy * dy < dead * dead then
        return false, false, false, false
    end
    -- Zero is straight up the screen and it runs clockwise: 1 is up and to the
    -- right, 2 is right, 4 is straight down. The sweep runs from -4 to 4, so
    -- straight down arrives under either sign depending on which side of it
    -- the thumb sits. Backing up is therefore read off the magnitude, which is
    -- what lets both ends mean the same thing without normalizing one away.
    local oct = math.floor(math.atan2(dx, dy) / (math.pi / 4) + 0.5)
    return oct <= -1 and oct >= -3,     -- turning left
           oct >= 1 and oct <= 3,       -- turning right
           oct >= -1 and oct <= 1,      -- thrusting
           math.abs(oct) >= 3           -- backing up
end

-- The ramp's clock, run by the arena once a frame. Kept apart from M.bits so
-- that reading the buttons never advances time: the drawing asks pad_arms the
-- same question and must see the same answer.
function M.step(dt)
    if not M.dpad then
        ramp.dir, ramp.held, ramp.acc = 0, 0, 1
        return
    end
    local left, right = pad_arms()
    local dir = (left and -1 or 0) + (right and 1 or 0)
    if dir ~= ramp.dir then
        -- A fresh turn, including a reversal mid-hold: the ramp starts over,
        -- so correcting an overshoot is as gentle as the tap that made it.
        ramp.dir, ramp.held, ramp.acc = dir, 0, 1
    elseif dir ~= 0 then
        ramp.held = ramp.held + (dt or 0)
    end
end

function M.bits(heading)
    local out = {}
    if guns then out[#out + 1] = sim.BTN_FIRE end
    if bombs then out[#out + 1] = sim.BTN_BOMB end
    if not stick then return out end

    -- The pad says which way the thumb is pushing and holds it there. The
    -- stick below says where the nose should end up and stops when it
    -- arrives. Both come out as the same turn bits; what differs is who
    -- decides when the turn ends, the player or the arithmetic.
    if M.dpad then
        local left, right, fwd, back = pad_arms()
        -- Turning is pulsed by the ramp; thrust and reverse are not. The
        -- overshoot this forgives is angular, and an engine that came up
        -- softly would read as mush without buying anything for it.
        if left or right then
            local f = RAMP_FLOOR
                + (1 - RAMP_FLOOR) * math.min(ramp.held / RAMP_S, 1)
            ramp.acc = ramp.acc + f
            if ramp.acc >= 1 then
                ramp.acc = ramp.acc - 1
                if left then out[#out + 1] = sim.BTN_LEFT end
                if right then out[#out + 1] = sim.BTN_RIGHT end
            end
        end
        if fwd then out[#out + 1] = sim.BTN_THRUST end
        if back then out[#out + 1] = sim.BTN_REVERSE end
        return out
    end

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

    -- Which end of the ship the thumb is steering.
    --
    -- Not firing, always the nose: the stick points where the nose should go,
    -- and a push behind you is a turn, exactly as it has always been.
    --
    -- Firing, a push far enough behind the nose steers the tail instead. The
    -- intent it reads is the kite: guns on the fight, ship backing out of it,
    -- which no pointing stick could say because pointing away is turning
    -- away. Mirroring the error swings the tail onto the thumb, so small
    -- moves of a rearward thumb steer the retreat while the guns stay
    -- forward, and the engine below fires backward under the same alignment
    -- gate thrust uses. The one thing this costs is a nose-first turn of
    -- more than about a hundred degrees mid-burst; letting go of the trigger
    -- for a beat buys it back.
    if guns or M.threat then
        rear = math.abs(diff) > (rear and REAR_EXIT or REAR_ENTER)
    else
        rear = false
    end
    if rear then
        diff = diff > 0 and diff - math.pi or diff + math.pi
    end

    if diff > 0.06 then out[#out + 1] = sim.BTN_RIGHT
    elseif diff < -0.06 then out[#out + 1] = sim.BTN_LEFT end

    -- The engine once the thumb is committed and the steered end is roughly
    -- there, so a hard turn does not fling the ship the way it used to be
    -- facing. Backing out it is the same gate on the other end of the hull,
    -- and the simulation's reverse is the same thrust with the sign flipped.
    if mag > THRUST_PX * M.scale and math.abs(diff) < 1.0 then
        out[#out + 1] = rear and sim.BTN_REVERSE or sim.BTN_THRUST
    end
    return out
end

-- True while the stick is steering, so the caller can drop keyboard steering
-- rather than let two sources fight over the rudder.
function M.steering()
    return stick ~= nil
end

-- --- what a pad has to say -------------------------------------------------

-- How big a mark is drawn, which is as big as its own worst loadout fits.
--
-- Derived rather than picked. A mark reaches marks.MARK_REACH of its own size
-- out from the round when a hull wears every add-on there is, and a gun's
-- round sits marks.BOLT_BIAS forward of the middle, so the two triggers have
-- different worst cases and a single ratio would either spill the gun's
-- fragments over the rim or draw a bomb head a third smaller than the pad it
-- has to itself.
--
-- RIM is what it stays inside, and it is not the ring. The ring is a stroke
-- rather than a line, so its inner edge is already inside the radius, and ink
-- that stops at the inner edge reads as ink touching it. This leaves a gap you
-- can see: at 0.95 a loaded bomb's fragments ended a pixel off the rim on a
-- phone, which looked like a drawing that had outgrown its control.
local RIM = 0.90
local function mark_k(pad, t)
    -- Half a mark's width in its own units, plus the heaviest stroke drawn out
    -- there. A gun is the wider one: its muzzle is a hull and a half behind
    -- the round and its add-ons ring the round itself. The fuse is measured
    -- separately because it is the one add-on that reaches past the rest, so
    -- the number the rings are shared out of is not the widest thing drawn.
    local half = math.max(marks.MARK_REACH + 0.05, marks.FIELD_MAX)
    if t == sim.TRIG_GUN then
        half = math.max(marks.BOLT_LEN - marks.BOLT_BIAS,
                        marks.BOLT_BIAS + half)
    end
    return pad.r * RIM / half
end

-- The mark itself is marks.weapon, the same call the corner stack makes, so a
-- pad shows the whole loadout rather than the two add-ons this file used to
-- know about. It drew a fan, a bounce ring and a fuse and nothing else, so a
-- hull carrying shrapnel, which is 22 of the 24 in the shipped zones, was
-- carrying it invisibly on a phone, and the corner stack that would have said
-- so is exactly what a touchscreen switches off.
local function pad_mark(pad, t)
    marks.weapon(pad.x, pad.y, mark_k(pad, t), M.me, t)
end

-- Drawn in the screen-space interface layer, which is where a control that
-- follows the thumb belongs: touches and this layer are both in drawable
-- pixels counting up from the bottom, so there is nothing to convert.
function M.draw(u, w, h, s)
    if not M.used then return end
    local dim = pal.a(pal.DIM, 0.45)
    local L = M.layout(w, h, s)

    local function pad_ring(pad, col, lit)
        u:ring(pad.x, pad.y, pad.r, 2.6 * s, 28, pal.a(col, lit and 0.95 or 0.5))
        u:disc(pad.x, pad.y, pad.r, 24, pal.a(col, lit and 0.10 or 0.045))
    end

    -- The gun, in the color of the round it fires.
    -- The rung the round is fired at, which is the color it will be coming
    -- at somebody across the arena. A player who has learned one has learned
    -- the other, and the two pads tell each other apart by their marks now
    -- rather than by their color.
    local gcol = pal.rung(marks.level(M.me, sim.TRIG_GUN))
    pad_ring(L.guns, gcol, guns)
    pad_mark(L.guns, sim.TRIG_GUN)
    -- Multifire stays attached to the gun instead of becoming another button.
    -- The short arrow teaches the upward pull; the weapon mark itself still
    -- shows whether the fan is equipped and whether it is declined.
    if M.has_fan then
        local ay = L.guns.y + L.guns.r + 5 * s
        local col = pal.a(gcol, M.multi_off and 0.32 or 0.72)
        u:seg(L.guns.x, ay - 6 * s, L.guns.x, ay + 3 * s, 1.8 * s, col)
        u:seg(L.guns.x, ay + 3 * s,
              L.guns.x - 4 * s, ay - 1 * s, 1.8 * s, col)
        u:seg(L.guns.x, ay + 3 * s,
              L.guns.x + 4 * s, ay - 1 * s, 1.8 * s, col)
    end
    -- The gun wore its energy on a second arc outside the rim for a while.
    -- Every hull in the game already carries a bar above it saying the same
    -- thing, yours included, and that one is where you are looking: at the
    -- ship, in the middle of the screen, rather than under the thumb in the
    -- corner. So the gun had two rings where the bomb has one, and the outer
    -- one was a copy of an instrument thirty degrees of eye travel away.

    if M.has_bomb then
        local bcol = pal.rung(marks.level(M.me, sim.TRIG_BOMB))
        pad_ring(L.bombs, bcol, bombs)
        pad_mark(L.bombs, sim.TRIG_BOMB)
    end

    -- A cell per charge in hand, and none for one that is spent out. Its slot
    -- keeps the same position when a neighbor empties. What says how many is
    -- pips along the cell's floor rather than a numeral above it: a charge is
    -- one of three, and three marks is a quantity read without counting,
    -- where the numeral sat in the gap between two pads and belonged to
    -- neither.
    for _, c in ipairs(L.charge) do
        local n = M.counts and M.counts[c.slot] or 0
        local cap = (M.maxes and M.maxes[c.slot]) or 3
        local half = c.w / 2
        u:rect(c.x - half, c.y - half, c.w, c.w, pal.a(pal.CHARGE_COL, 0.05))
        u:frame(c.x - half, c.y - half, c.w, c.w, 2.2 * s,
                pal.a(pal.CHARGE_COL, 0.55))
        marks.charge(c.slot, c.x, c.y + c.w * 0.08, c.w * 0.42,
                     pal.a(pal.CHARGE_COL, 0.92))
        local pitch = c.w * 0.19
        local px = c.x - (cap - 1) * pitch / 2
        for i = 1, cap do
            local at = px + (i - 1) * pitch
            if i <= n then
                u:disc(at, c.y - c.w * 0.33, 2.4 * s, 8, pal.CHARGE_COL)
            else
                u:ring(at, c.y - c.w * 0.33, 2.4 * s, 1.4 * s, 8,
                       pal.a(pal.CHARGE_COL, 0.3))
            end
        end
    end

    if M.dpad then
        -- The pad. Four chevrons pointing out of a middle, lit where the
        -- thumb is pushing.
        -- At the anchor whether held or not: the pad's fixed position is
        -- what a thumb learns, so it is never drawn anywhere else. Holding it
        -- only brightens it.
        local cx, cy = L.home.x, L.home.y
        local col = stick and dim or pal.a(pal.DIM, 0.35)
        local reach, span = L.home.r * 0.92, L.home.r * 0.30
        local left, right, fwd, back = pad_arms()
        for _, arm in ipairs({{0, 1, fwd}, {0, -1, back},
                              {-1, 0, left}, {1, 0, right}}) do
            local ux, uy, on = arm[1], arm[2], arm[3]
            local c = on and pal.a(pal.FRIEND, 0.9) or col
            -- Tip out along the arm, arms swept back either side of it.
            local tx, ty = cx + ux * reach, cy + uy * reach
            local bx, by = cx + ux * (reach - span), cy + uy * (reach - span)
            u:seg(bx - uy * span, by + ux * span, tx, ty, 2 * s, c)
            u:seg(tx, ty, bx + uy * span, by - ux * span, 2 * s, c)
        end
    elseif stick then
        local live = pal.a(pal.FRIEND, 0.9)
        u:ring(stick.ox, stick.oy, L.home.r, 1.8 * s, 26, dim)
        u:ring(stick.x, stick.y, L.r * 0.42, 1.8 * s, 16, live)
        u:seg(stick.ox, stick.oy, stick.x, stick.y, 2 * s, live)
    else
        -- A resting mark where a thumb should go. The stick itself is
        -- relative: it appears wherever you press, and a control that is
        -- invisible until you find it is a control nobody finds.
        u:ring(L.home.x, L.home.y, L.home.r, 1.8 * s, 26, pal.a(pal.DIM, 0.28))
        u:ring(L.home.x, L.home.y, L.r * 0.3, 1.8 * s, 16, pal.a(pal.DIM, 0.35))
    end
end

return M
