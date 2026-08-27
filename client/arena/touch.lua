-- Touch controls.
--
-- The question platforms.md asks is whether mobile is a playing client or a
-- spectating one. This is the playing answer: one thumb for flying, and pads
-- for the weapons.
--
-- The flying thumb is a thumbstick, and it points where you want the nose to
-- go. Pointing beats a rotate-left/rotate-right pair on glass: there is no
-- tactile edge to feel for, so a player cannot hold a rotation and stop it on
-- time, but they can put a thumb where they want to be facing. The ship still
-- turns at its own rate, so nothing about the flight model changes. This only
-- decides which way the turn is applied, exactly as the AI does it.
--
-- It is the only flying control. Beside it for a while sat a d-pad, chosen in
-- the settings, and two goes at a reverse: down on the d-pad, and on the stick
-- a rearward push that read as backing out whenever the guns were up or a
-- hostile sat ahead. All three are gone, and why they went decides the shape
-- of the one that is here now. A thumb pushed the same way meant one thing on
-- the pad and another on the stick, and on the stick it changed again
-- mid-burst, which cost a field on every caller, a clock run from the frame
-- loop, and a module of its own deciding what counted as a fight.
--
-- So reverse is a stance the pilot sets rather than a push the stick reads
-- into. A double tap anywhere on the stick's half flips it, and it holds until
-- another double tap flips it back. Nothing is inferred from a fight, a
-- trigger or a bearing, and a push still means the one thing it has always
-- meant.
--
-- What it means is the course you want, and reverse must not take that away.
-- The stick goes on pointing where you want to be going and the nose is held
-- at the far end of it, so you back away from your own thumb with the guns
-- still on whatever you are backing away from. That is the only reason to fly
-- backward at all. Holding the nose on the thumb instead and running the
-- engine the other way is the mid-burst change again wearing a switch: the
-- same push would name a course going forward and a target going back.
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
local THRUST_PX = 46      -- push past this and the engine lights
local FAN_SWIPE_PX = 32   -- deliberate upward pull while holding the gun
local TAP_SLIP_PX = 40    -- how far a tap may wander and still be a tap
local TAP_HOLD = 0.30     -- seconds a press may last before it is a hold
local TAP_GAP = 0.30      -- seconds between the two taps of a double tap

M.used = false            -- has this device ever reported a touch?
M.scale = 1               -- drawable pixels per point

-- Seconds, counting up, set by the caller at the moment it hands a touch down.
--
-- The stick wants a clock for one thing: telling a double tap from two presses
-- that happen to land in the same place. The header lists a clock among what
-- the last reverse cost, so this one is worth being plain about. It is a
-- number set at the single call site rather than a timer this file runs.
-- Nothing here ticks.
--
-- The gesture wants time to have passed rather than merely not too much of it,
-- which costs nothing real: two taps by a hand are frames apart and this clock
-- moves every frame. What it buys is the direction the failure falls in. A
-- caller that stops setting this, or never starts, holds one number forever,
-- and a stick that reads every pair of quick presses as a flip is worse than
-- one that has quietly lost the flip altogether.
M.now = 0

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

local stick = nil         -- {id, ox, oy, x, y, t0, still, flipped}
-- The last press that ended as a tap: when it let go, and where it sat. A
-- second tap near it and soon after is the gesture.
local last_tap = nil
-- Which end of the ship the engine pushes from. Latched, because a stance is
-- not a thing a hand can hold: backing out of a fight is exactly when both
-- thumbs are busy elsewhere, and a reverse you have to keep pressing is one
-- you cannot shoot through.
local reversed = false
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

-- Whether an upward gun pull happened since it was last asked. The core toggles
-- multifire on a rising edge, so one gun hold may produce at most one edge.
local fanned = false

-- The charge slots this hull can carry, newest set by the caller. Empty until
-- told, so a hull with none draws none.
M.charges = {}
-- Ticks until each kind may be thrown again, and how long each waits when it
-- is thrown, both by slot and both set by the caller alongside the counts.
M.waits = {}
M.delays = {}
-- How far down a cell washes on the tick its key shuts, matching the corner
-- rail's own floor: unavailable at a glance, still readable as a control.
local SHUT = 0.3

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
-- Empty slots disappear but never pull a neighbor into their place.
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
                -- The flip lands on the second press rather than its release,
                -- so tap-then-press-and-drag is one gesture: the stance
                -- changes and the same thumb flies out of it without lifting.
                local slip = TAP_SLIP_PX * M.scale
                local flip = last_tap ~= nil
                    and M.now > last_tap.t
                    and M.now - last_tap.t <= TAP_GAP
                    and math.abs(tx - last_tap.x) <= slip
                    and math.abs(ty - last_tap.y) <= slip
                if flip then
                    reversed = not reversed
                    last_tap = nil
                end
                stick = {id = t.id, ox = tx, oy = ty, x = tx, y = ty,
                         t0 = M.now, still = true, flipped = flip}
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
                -- A thumb that has gone anywhere is flying, and a press that
                -- flew is not half of a double tap however briefly it lasted.
                if math.abs(tx - stick.ox) > TAP_SLIP_PX * M.scale
                    or math.abs(ty - stick.oy) > TAP_SLIP_PX * M.scale then
                    stick.still = false
                end
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
        -- A press that stayed put and let go quickly is a tap, and a tap is
        -- half a gesture. The press that just flipped is not: three taps are
        -- one double tap and a spare, not two double taps, which is the
        -- difference between a stance a thumb can trust and a coin toss.
        --
        -- Anything else clears the pending half rather than leaving it to time
        -- out, so a tap followed by a real bit of flying cannot be joined to
        -- the press after it.
        if stick.still and not stick.flipped
            and M.now - stick.t0 <= TAP_HOLD then
            last_tap = {t = M.now, x = stick.ox, y = stick.oy}
        else
            last_tap = nil
        end
        stick = nil
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
    gun_ox, gun_oy, gun_fanned = nil, nil, false
    last_tap = nil
    -- The stance goes with them. This is called when the cockpit went away:
    -- focus lost, a watch taken, the client shutting down. Coming back to a
    -- ship that flies backward for a reason nobody remembers setting is worse
    -- than coming back to one that flies the way it always has.
    reversed = false
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
function M.bits(heading)
    local out = {}
    if guns then out[#out + 1] = sim.BTN_FIRE end
    if bombs then out[#out + 1] = sim.BTN_BOMB end
    if not stick then return out end

    local dx, dy = stick.x - stick.ox, stick.y - stick.oy
    local mag = math.sqrt(dx * dx + dy * dy)
    if mag < DEAD_PX * M.scale then return out end

    -- Screen +y is up and the simulation's +y is down, which is why this is
    -- atan2(x, y) rather than the atan2(dx, -dy) the AI uses on sim vectors.
    local want = math.atan2(dx, dy)
    -- The thumb names the course either way. Reversed, the engine pushes out
    -- of the tail, so the nose that serves that course is the one half a turn
    -- from it, and that is what the rudder is given to chase. Everything below
    -- is then the forward case unchanged, the thrust gate included: the nose
    -- still has to be roughly where it is wanted before the engine lights.
    if reversed then want = want + math.pi end
    local head = (heading / 65536) * math.pi * 2
    local diff = want - head
    while diff > math.pi do diff = diff - math.pi * 2 end
    while diff < -math.pi do diff = diff + math.pi * 2 end

    -- The nose, always: the stick points where the nose should go, so a push
    -- behind you is a turn like any other rather than an order to back up.
    if diff > 0.06 then out[#out + 1] = sim.BTN_RIGHT
    elseif diff < -0.06 then out[#out + 1] = sim.BTN_LEFT end

    -- The engine once the thumb is committed and the nose is roughly there,
    -- so a hard turn does not fling the ship the way it used to be facing.
    if mag > THRUST_PX * M.scale and math.abs(diff) < 1.0 then
        out[#out + 1] = reversed and sim.BTN_REVERSE or sim.BTN_THRUST
    end
    return out
end

-- True while the stick is steering, so the caller can drop keyboard steering
-- rather than let two sources fight over the rudder.
function M.steering()
    return stick ~= nil
end

-- Which way the engine is pointed. For the drawing below, and for a test:
-- everything the stance changes is inside this file, so nothing else has to
-- ask, and the ship shows the answer on its own anyway. See the retros in
-- arena/world.lua, drawn off the bow because a thumb reporting the sign of the
-- thrust is a thumb the pilot is not looking at.
function M.reversing()
    return reversed
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
        -- A kind that has just been thrown keeps its key shut, and the cell
        -- goes out with it and comes back as the clock does. A thumb has no
        -- key to feel go dead, so on glass this is the only thing that says
        -- the tap will do nothing yet. Nothing dims for a kind with no delay,
        -- which the repel is.
        local wait = M.waits and M.waits[c.slot] or 0
        local delay = M.delays and M.delays[c.slot] or 0
        local lit = 1
        if wait > 0 and delay > 0 then
            lit = SHUT + (1 - SHUT) * (1 - math.min(1, wait / delay))
        end
        local half = c.w / 2
        u:rect(c.x - half, c.y - half, c.w, c.w,
               pal.a(pal.CHARGE_COL, 0.05 * lit))
        u:frame(c.x - half, c.y - half, c.w, c.w, 2.2 * s,
                pal.a(pal.CHARGE_COL, 0.55 * lit))
        marks.charge(c.slot, c.x, c.y + c.w * 0.08, c.w * 0.42,
                     pal.a(pal.CHARGE_COL, 0.92 * lit))
        local pitch = c.w * 0.19
        local px = c.x - (cap - 1) * pitch / 2
        for i = 1, cap do
            local at = px + (i - 1) * pitch
            if i <= n then
                u:disc(at, c.y - c.w * 0.33, 2.4 * s, 8,
                       pal.a(pal.CHARGE_COL, lit))
            else
                u:ring(at, c.y - c.w * 0.33, 2.4 * s, 1.4 * s, 8,
                       pal.a(pal.CHARGE_COL, 0.3 * lit))
            end
        end
    end

    -- The stance is the stick's own color: THRUST is what the ship's plumes
    -- are drawn in, so a stick the color of an engine is a stick with the
    -- engine turned round. It has to be on the mark as well as on the live
    -- control, because a stance outlives the thumb that set it and the resting
    -- mark is the whole of what a pilot can read with no thumb down.
    local hot = reversed and pal.THRUST or pal.FRIEND
    if stick then
        local live = pal.a(hot, 0.9)
        u:ring(stick.ox, stick.oy, L.home.r, 1.8 * s, 26, dim)
        u:ring(stick.x, stick.y, L.r * 0.42, 1.8 * s, 16, live)
        u:seg(stick.ox, stick.oy, stick.x, stick.y, 2 * s, live)
        -- The nose, out the far side of the press. Reverse is the one time
        -- the ship is not pointed where the thumb is, and that is the part of
        -- it a pilot has to be shown rather than told: a thumb to the right
        -- turning the ship left looks like a bug until you can see the nose
        -- being carried to the other end of the course.
        --
        -- Headed, and stopping short of the ring. A bare segment on the line
        -- the thumb is already on reads as the thumb's own line drawn longer,
        -- which is the one thing it must not say.
        if reversed then
            local dx, dy = stick.x - stick.ox, stick.y - stick.oy
            local mag = math.sqrt(dx * dx + dy * dy)
            if mag > DEAD_PX * s then
                local ux, uy = -dx / mag, -dy / mag
                local px, py = -uy, ux
                local tx = stick.ox + ux * L.home.r * 0.72
                local ty = stick.oy + uy * L.home.r * 0.72
                local barb = L.r * 0.2
                u:seg(stick.ox, stick.oy, tx, ty, 2 * s, pal.a(hot, 0.4))
                local c = pal.a(hot, 0.55)
                u:seg(tx, ty, tx - ux * barb + px * barb * 0.6,
                      ty - uy * barb + py * barb * 0.6, 2 * s, c)
                u:seg(tx, ty, tx - ux * barb - px * barb * 0.6,
                      ty - uy * barb - py * barb * 0.6, 2 * s, c)
            end
        end
    else
        -- A resting mark where a thumb should go. The stick itself is
        -- relative: it appears wherever you press, and a control that is
        -- invisible until you find it is a control nobody finds.
        --
        -- Reversed, its middle is an arrow rather than a dot, and it points
        -- down: the same arrow the keyboard's reverse key wears, since that
        -- control is bound to the down key and this one is the same control.
        local eye = L.r * 0.3
        local rest = reversed and pal.a(hot, 0.55) or pal.a(pal.DIM, 0.28)
        u:ring(L.home.x, L.home.y, L.home.r, 1.8 * s, 26, rest)
        if reversed then
            local c = pal.a(hot, 0.8)
            u:seg(L.home.x, L.home.y + eye, L.home.x, L.home.y - eye,
                  1.8 * s, c)
            u:seg(L.home.x, L.home.y - eye,
                  L.home.x - eye * 0.7, L.home.y - eye * 0.3, 1.8 * s, c)
            u:seg(L.home.x, L.home.y - eye,
                  L.home.x + eye * 0.7, L.home.y - eye * 0.3, 1.8 * s, c)
        else
            u:ring(L.home.x, L.home.y, eye, 1.8 * s, 16, pal.a(pal.DIM, 0.35))
        end
    end
end

return M
