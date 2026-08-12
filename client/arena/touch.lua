-- Touch controls.
--
-- The question platforms.md asks is whether mobile is a playing client or a
-- spectating one. This is the playing answer: a thumbstick that points where
-- you want the nose to go, and pads for the weapons.
--
-- Pointing beats a rotate-left/rotate-right pair on glass. There is no tactile
-- edge to feel for, so a player cannot hold a rotation and stop it on time;
-- they can put a thumb where they want to be facing. The ship still turns at
-- its own rate, so nothing about the flight model changes -- this only decides
-- which way the turn is applied, exactly as the AI does it.
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

M.used = false            -- has this device ever reported a touch?
M.scale = 1               -- drawable pixels per point
-- How many of each charge slot are in hand, by slot. Set by the caller.
M.counts = {}
-- And how many of each the hull can hold, which is what the pips count out.
M.maxes = {}

-- Whether the hull flying has a bomb rack. Two of the eight do not, and a pad
-- for a weapon that cannot exist is a pad that does nothing when pressed --
-- worse than useless, because it also swallows the touch. Set by the caller,
-- and true until told otherwise so a missing update never removes a control
-- somebody actually has.
M.has_bomb = true

-- Whether the hull flying is carrying a fan on either trigger, and whether it
-- is currently declined. Set by the caller.
--
-- False until told otherwise, which is the opposite of `has_bomb` and the safe
-- direction for each: a rack is the ordinary case and a missing update must not
-- take the bomb pad away, while a fan is something you pick up, and a cell for
-- an add-on nobody holds is a control that toggles a mode it has no barrels
-- for. Multifire is the one gun mode with no key on glass, so this cell is the
-- only way to decline it there at all.
M.has_fan = false
M.multi_off = false

-- What an iPhone's island or notch covers at the sides, in drawable pixels,
-- set by the caller from what the page measures. The pads and the stick's
-- resting mark step inside them; the bottom is deliberately not represented,
-- because the home indicator overlays every full-screen game's controls and
-- lifting the whole row past it bought nothing but reach.
M.safe_l = 0
M.safe_r = 0

-- Which ship is yours, so a pad can read its own weapon out of the core
-- rather than have every fact about it copied into a field here. nil before
-- the first frame, and the marks fall back to a plain gun and a plain bomb.
M.me = nil

-- How high the rail may climb, in drawable pixels from the bottom. The dial
-- owns the top right corner and a pad that reaches it is a pad over an
-- instrument, so the caller hands down where the dial ends. Passed rather
-- than asked for: this file knows where a thumb goes and ui.lua knows where
-- the instruments go, and neither reaching into the other is what let the two
-- of them stop depending on each other at all.
M.ceiling = math.huge

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

-- Whether the fan cell was tapped since it was last asked. Latched the same
-- way and for a related reason: the core toggles multifire on the rising edge
-- of the button, so what a control owes it is one edge per press. A held cell
-- would hold the bit down, which is what the key does and is harmless, but a
-- thumb resting on a control it has already used should not be the difference
-- between one toggle and none.
local fanned = false
-- And the mine cell, latched the same way: one tap is one mine.
local mined = false

-- The charge slots this hull can carry, newest set by the caller. Empty until
-- told, so a hull with none draws none.
M.charges = {}
-- Whether this hull lays mines at all, which is `mine_max` above zero.
M.has_mine = false

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
-- The two triggers keep the corner, side by side along the bottom, and the
-- charges go above them rather than beside them. They used to continue the
-- triggers' own row leftward, which put a tap-once control inside the arc the
-- trigger thumb sweeps and spent the whole width of the screen doing it.
--
-- Above means a column climbing the edge, and it stays a column for as long
-- as there is edge to climb. On a phone held upright there is plenty. Held
-- sideways the dial takes better than half the height and the answer is one
-- cell, so the rail steps left and starts again -- which packs a full rack
-- into the block over the triggers instead of stringing it along the bottom.
-- Either way every cell is over the triggers and none is beside them, which
-- is the part that matters: reaching the gun never crosses a charge.
function M.layout(w, h, s)
    s = s or 1
    local r = math.max(30 * s, math.min(math.min(w, h) * 0.11, 62 * s))
    local br = r * 0.82
    -- Far enough in that the rim clears the edge of the screen with a thumb's
    -- worth of margin: a control hard against the bezel is one a hand has to
    -- curl round to reach.
    local gun_pad  = {x = w - M.safe_r - r * 1.4, y = r * 1.4, r = r}
    local bomb_pad = {x = gun_pad.x - r - br - r * 0.34, y = gun_pad.y, r = br}
    local home  = {x = M.safe_l + r * 1.6, y = r * 1.8, r = r * 1.15}

    -- The charges, as square cells: which class a control belongs to reads
    -- before the picture inside it does, and a round trigger beside a square
    -- charge can never be mistaken for another trigger. Smaller than the
    -- triggers, because they are tapped once in a while and a target the size
    -- of a trigger would crowd the one control a thumb must never miss.
    --
    -- Sized to fit two of them under the dial on a phone held sideways, which
    -- is the tightest case and the ordinary loadout. The drawing is a little
    -- under the forty-odd points a finger wants; what answers a tap is not,
    -- since `within` grows the cell by a third on every side.
    local cw = r * 0.82
    local x0 = gun_pad.x
    -- Clear of the rim with a gap you can see. It used to have to clear the
    -- energy arc riding a fifth of a radius outside the gun as well, and the
    -- first build of this cleared neither, which took a screenshot to see.
    local y0 = gun_pad.y + r * 1.08 + cw * 0.75
    local x, y = x0, y0
    -- The fan takes the first cell, nearest the trigger whose mode it is, and
    -- keeps it. The rest of the rail closes up as charges are spent, and a
    -- mode that slid down the column every time somebody used a charge would
    -- be a control that moved while a thumb was reaching for it. This one only
    -- ever appears or goes, and it goes by being lost rather than by being
    -- spent.
    local fan = nil
    if M.has_fan then
        fan = {x = x, y = y, w = cw, r = cw / 2}
        y = y + cw * 1.14
    end
    -- The mine takes the next fixed cell, for the same reason the fan takes
    -- the first: it is a mode of the bomb trigger rather than a thing in a
    -- slot, so it is always there or never, and it must not slide down the
    -- rail when a charge is spent. On glass there is no shift to hold, so a
    -- cell is the whole of the control.
    local mine = nil
    if M.has_mine then
        mine = {x = x, y = y, w = cw, r = cw / 2}
        y = y + cw * 1.14
    end
    local charge = {}
    for _, k in ipairs(M.charges) do
        -- Only what is in hand. A cell for a slot you have spent out is a
        -- control that does nothing when pressed, and glass gives no way to
        -- tell that before pressing it: there is no travel, no resistance and
        -- no cursor that could have hovered first. The rail closes up as they
        -- go, so what is under a thumb is always something it can spend.
        if (M.counts and M.counts[k] or 0) > 0 then
            -- Past the dial the rail steps left and starts again, which is
            -- what a hull carrying four kinds on a short window does. A limit
            -- rather than an assumption the height is always there.
            if y + cw / 2 > M.ceiling then
                x, y = x - cw * 1.14, y0
            end
            charge[#charge + 1] = {slot = k, x = x, y = y, w = cw,
                                   r = cw / 2}
            y = y + cw * 1.14
        end
    end

    return {r = r, guns = gun_pad, bombs = bomb_pad, home = home,
            charge = charge, fan = fan, mine = mine}
end

local function near(pad, x, y, slack)
    local dx, dy = x - pad.x, y - pad.y
    local reach = pad.r * (slack or 1.3)
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
    -- Tested in the order the rail is drawn in, and only when it is there, so
    -- a hull with no fan leaves the space to the stick rather than to a cell
    -- nobody can see.
    if L.fan and within(L.fan, x, y) then return "multi" end
    if L.mine and within(L.mine, x, y) then return "mine" end
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
            elseif z == "multi" then
                fanned = true
            elseif z == "mine" then
                mined = true
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

-- Which charge slot was tapped since this was last asked, or nil. Consumed by
-- the read, because a tap is an event and the caller acts on it once.
function M.fired_charge()
    local k = fired
    fired = nil
    return k
end

-- Whether the fan cell was tapped since this was last asked. Consumed by the
-- read, like a charge, so one tap is one toggle however many frames pass
-- before the step loop gets to it.
function M.fired_multi()
    local hit = fanned
    fanned = false
    return hit
end

-- Whether the mine cell was tapped since this was last asked, consumed by the
-- read like the others: one tap lays one mine however many frames pass before
-- the step loop gets to it.
function M.fired_mine()
    local hit = mined
    mined = false
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

    -- The fan, in the rail's first cell.
    --
    -- The same square as a charge, because it sits in the same column and a
    -- rail of two shapes reads as two rails. What tells it from a charge is
    -- the gun's own color instead of the charge hue, and the absence of pips:
    -- pips are a count of what is left, and a mode has no stock to run out of.
    -- Dimmed while it is declined, which is the treatment the same add-on
    -- already gets on a weapon mark.
    if L.fan then
        local c = L.fan
        local half = c.w / 2
        local lit = not M.multi_off
        u:rect(c.x - half, c.y - half, c.w, c.w,
               pal.a(gcol, lit and 0.07 or 0.03))
        u:frame(c.x - half, c.y - half, c.w, c.w, 2.2 * s,
                pal.a(gcol, lit and 0.6 or 0.26))
        marks.fan(c.x, c.y, c.w * 0.30,
                  pal.a(gcol, lit and 0.92 or 0.42), M.multi_off)
    end

    -- The mine, in the cell after the fan and drawn like it: the same square,
    -- the bomb's own color rather than the charge hue, because it is the bomb
    -- trigger's other posture and not something found in a slot.
    --
    -- Its pips are the room left rather than the stock in hand, which is the
    -- one place a mine differs from everything else on this rail. A pilot
    -- never runs out of mines; they run out of floor. So a lit pip is a mine
    -- that could still be laid, and a cell with none lit is a minefield at its
    -- ceiling -- the same picture a spent charge would draw, saying the same
    -- thing about whether pressing it will do anything.
    if L.mine then
        local c = L.mine
        local half = c.w / 2
        local cap = M.mine_max or 0
        local room = cap - (M.mines_out or 0)
        local lit = room > 0
        local bcol = pal.rung(marks.level(M.me, sim.TRIG_BOMB))
        u:rect(c.x - half, c.y - half, c.w, c.w,
               pal.a(bcol, lit and 0.07 or 0.03))
        u:frame(c.x - half, c.y - half, c.w, c.w, 2.2 * s,
                pal.a(bcol, lit and 0.6 or 0.26))
        marks.mine(c.x, c.y + c.w * 0.06, c.w * 0.30,
                   pal.a(bcol, lit and 0.92 or 0.42))
        if cap > 0 then
            local pw = c.w * 0.14
            local gap = pw * 0.55
            local span = cap * pw + (cap - 1) * gap
            local px = c.x - span / 2
            for i = 1, cap do
                u:rect(px, c.y - half + c.w * 0.10, pw, c.w * 0.075,
                       pal.a(bcol, i <= room and 0.85 or 0.18))
                px = px + pw + gap
            end
        end
    end

    -- A cell per charge in hand, and none for one that is spent out. What
    -- says how many is pips along the cell's floor rather than a numeral above
    -- it: a charge is one of three, and three marks is a quantity read without
    -- counting, where the numeral sat in the gap between two pads and belonged
    -- to neither.
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

    if stick then
        local live = pal.a(pal.FRIEND, 0.9)
        u:ring(stick.ox, stick.oy, L.home.r, 1.8 * s, 26, dim)
        u:ring(stick.x, stick.y, L.r * 0.42, 1.8 * s, 16, live)
        u:seg(stick.ox, stick.oy, stick.x, stick.y, 2 * s, live)
    else
        -- A resting mark where a thumb should go. The stick itself is
        -- relative -- it appears wherever you press -- but a control that is
        -- invisible until you find it is a control nobody finds.
        u:ring(L.home.x, L.home.y, L.home.r, 1.8 * s, 26, pal.a(pal.DIM, 0.28))
        u:ring(L.home.x, L.home.y, L.r * 0.3, 1.8 * s, 16, pal.a(pal.DIM, 0.35))
    end
end

return M
