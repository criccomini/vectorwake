-- The stick's arithmetic, driven the way a thumb drives it.
--
--     lua5.1 client/tests/touch_test.lua
--
-- The stick turns a thumb's position into the same buttons a keyboard
-- sends, and this pins that mapping: ahead thrusts, a course to the side
-- turns toward it, and a course behind the nose is a turn like any other.
-- That last one is a decision, not an accident. A rear cone that held the
-- nose and backed up shipped and was taken out within the day because it did
-- not feel good under a thumb; a second attempt read the same push as backing
-- out of a fight, lasted longer, and is gone as well. A push behind the nose
-- means one thing whatever else is held.
--
-- A phone does have a reverse, and the reason it is not a third attempt at
-- those two is the last section of this file. It is a stance the pilot sets
-- with a double tap, not a meaning the stick finds in a push, so the arithmetic
-- above is the same arithmetic either way with the nose asked for half a turn
-- round. Everything up to that section runs with the clock stopped at zero,
-- which is a state the gesture will not fire in, so none of it can flip by
-- accident and read as passing while measuring the wrong stance.

package.path = "client/?.lua;" .. package.path

_G.sim = {
    BTN_LEFT = 1,
    BTN_RIGHT = 2,
    BTN_THRUST = 4,
    BTN_REVERSE = 8,
    BTN_FIRE = 16,
    BTN_BOMB = 32,
}

local touch = require("arena.touch")

local fails = 0
local function check(name, ok, detail)
    if ok then
        print("ok   " .. name)
    else
        fails = fails + 1
        print("FAIL " .. name .. (detail and ("  -- " .. detail) or ""))
    end
end

local W, H = 844, 390

-- A thumb landing, moving, lifting. The stick is relative, so every case
-- starts a fresh press at a spot on the left half that no pad owns.
local OX, OY = 250, 200
local function press()
    touch.on_touch({touch = {{id = 7, pressed = true,
                              screen_x = OX, screen_y = OY}}}, W, H, 1)
end
local function drag(dx, dy)
    touch.on_touch({touch = {{id = 7,
                              screen_x = OX + dx, screen_y = OY + dy}}},
                   W, H, 1)
end
local function lift()
    touch.on_touch({touch = {{id = 7, released = true,
                              screen_x = OX, screen_y = OY}}}, W, H, 1)
end

local function has(list, bit)
    for _, b in ipairs(list) do if b == bit then return true end end
    return false
end

-- A drag of `mag` pixels at `deg` degrees off the nose, against a ship
-- heading north, which is screen up: 0 degrees is dead ahead, 180 dead
-- astern, positive to the right.
local function ask(deg, mag, heading)
    local a = math.rad(deg)
    press()
    drag(math.sin(a) * mag, math.cos(a) * mag)
    local bits = touch.bits(heading or 0)
    lift()
    return bits
end

-- Dead ahead, committed: the engine lights and nothing else does.
local b = ask(0, 60)
check("dead ahead thrusts", has(b, sim.BTN_THRUST))
check("and only thrusts", #b == 1, #b .. " bits")

-- Off to the side: a turn, and no thrust while the nose is that far from
-- the ask.
b = ask(90, 60)
check("a course to the right turns right",
      has(b, sim.BTN_RIGHT) and not has(b, sim.BTN_LEFT))
check("and does not thrust yet", not has(b, sim.BTN_THRUST))
b = ask(-90, 60)
check("a course to the left turns left",
      has(b, sim.BTN_LEFT) and not has(b, sim.BTN_RIGHT))

-- The stick names a course rather than a direction to spin in, so a thumb
-- already on the ship's heading asks for no turn wherever that heading is.
-- Headings are the simulation's: 0..65535, zero north, clockwise.
b = ask(90, 60, 65536 / 4)
check("a thumb on the current heading turns nothing",
      not has(b, sim.BTN_LEFT) and not has(b, sim.BTN_RIGHT))
check("and drives the ship along it", has(b, sim.BTN_THRUST))

-- A resting thumb inside the dead zone asks nothing.
b = ask(180, 8)
check("a thumb that barely moved does nothing", #b == 0, #b .. " bits")

-- Courses behind the nose, at and around dead astern: every one is a turn
-- toward the ask, and none silently becomes reverse.
for _, deg in ipairs({150, 170, 179, -170, -150}) do
    b = ask(deg, 60)
    local turning = has(b, sim.BTN_LEFT) or has(b, sim.BTN_RIGHT)
    check(deg .. " degrees astern is a turn like any other",
          turning and not has(b, sim.BTN_REVERSE))
end

-- Lifting the thumb clears the ask.
check("after the lift the stick is quiet", #touch.bits(0) == 0)

-- --- and none of it changes while a trigger is down -------------------------
--
-- The trigger used to be half of what said "fight", and in a fight a rearward
-- push backed the ship out instead of turning it. It says nothing now: the
-- pads decide what is fired and the stick decides where the nose goes, and
-- neither reads the other.

local L = touch.layout(W, H, 1)
touch.on_touch({touch = {{id = 9, pressed = true,
                          screen_x = L.guns.x, screen_y = L.guns.y}}}, W, H, 1)
touch.on_touch({touch = {{id = 8, pressed = true,
                          screen_x = 120, screen_y = 250}}}, W, H, 1)
touch.on_touch({touch = {{id = 8, screen_x = 120, screen_y = 190}}}, W, H, 1)
local held = touch.bits(0)
check("firing, a push behind the nose is still a turn",
      (has(held, sim.BTN_LEFT) or has(held, sim.BTN_RIGHT))
          and not has(held, sim.BTN_REVERSE))
check("and the gun is still firing through it", has(held, sim.BTN_FIRE))
touch.release(9)
held = touch.bits(0)
check("letting the trigger go leaves the same turn",
      (has(held, sim.BTN_LEFT) or has(held, sim.BTN_RIGHT))
          and not has(held, sim.BTN_FIRE))
touch.release(8)

-- --- the gun holds and nothing else -----------------------------------------
--
-- Multifire was an upward pull off this pad, and it is gone: a gesture nobody
-- finds on a control they are holding down, buying a state the mark already
-- drew. What has to stay true is that the pull it used to read is now just a
-- thumb that wandered, so the gun goes on firing through it and lets go when
-- the finger lifts and not before.

L = touch.layout(W, H, 1)
touch.on_touch({touch = {{id = 3, pressed = true,
                          screen_x = L.guns.x, screen_y = L.guns.y}}}, W, H, 1)
touch.on_touch({touch = {{id = 3,
                          screen_x = L.guns.x,
                          screen_y = L.guns.y + 40}}}, W, H, 1)
check("an upward gun pull is nothing but a held trigger",
      has(touch.bits(0), sim.BTN_FIRE))
touch.on_touch({touch = {{id = 3,
                          screen_x = L.guns.x + 42,
                          screen_y = L.guns.y + 8}}}, W, H, 1)
check("and so is a sideways one", has(touch.bits(0), sim.BTN_FIRE))
touch.release(3)
check("lifting after it releases the gun",
      not has(touch.bits(0), sim.BTN_FIRE))
touch.release_all()

-- A UI press can consume a whole multitouch batch. The arena forwards releases
-- through this narrow path first, so the pad held by another finger still lets
-- go even when the rest of the action belongs to the panel.
touch.has_bomb = true
L = touch.layout(W, H, 1)
touch.on_touch({touch = {{id = 9, pressed = true,
                          screen_x = L.guns.x, screen_y = L.guns.y}}}, W, H, 1)
check("a held gun reaches the buttons", has(touch.bits(0), sim.BTN_FIRE))
touch.release(9)
check("a release consumed by the UI still clears it",
      not has(touch.bits(0), sim.BTN_FIRE))

-- --- the stance, and the double tap that sets it --------------------------
--
-- Reverse is latched rather than pushed for, so what is pinned here is in two
-- halves: which pairs of presses are the gesture and which are two presses,
-- and what the stick asks for once the gesture has landed.
--
-- The clock is the caller's, handed in at `touch.now`. Every step below sets
-- it, because the gap between two taps is the whole difference between a
-- gesture and a thumb repositioning itself.

touch.release_all()
touch.now = 0

local function at(t, ev)
    touch.now = t
    touch.on_touch({touch = {ev}}, W, H, 1)
end
-- A tap: down and up in the same place, a frame apart, which is the shortest
-- thing a hand can do.
local function stick_tap(t, x, y)
    at(t, {id = 5, pressed = true, screen_x = x or OX, screen_y = y or OY})
    at(t + 0.016, {id = 5, released = true, screen_x = x or OX,
                   screen_y = y or OY})
end

check("the stick starts forward", touch.reversing() == false)
stick_tap(1.0)
check("one tap is not a gesture", touch.reversing() == false)
stick_tap(1.2)
check("a second tap soon after flips the stance", touch.reversing() == true)

-- Three taps are one gesture and a spare. The press that flipped is spent, so
-- the third tap has nothing to pair with and the stance holds where the pilot
-- put it rather than falling back a beat later.
stick_tap(1.4)
check("a third tap does not flip it back", touch.reversing() == true)

-- And a fourth, pairing with that third, does: two gestures, two flips.
stick_tap(1.55)
check("but a fourth tap is a second gesture", touch.reversing() == false)

-- Too slow, and it is two presses.
stick_tap(3.0)
stick_tap(3.5)
check("taps further apart than the gap are two presses",
      touch.reversing() == false)

-- Too far, and it is two presses: a thumb that came down somewhere else meant
-- somewhere else.
stick_tap(4.0)
stick_tap(4.1, OX + 120, OY)
check("taps far apart on the glass are two presses",
      touch.reversing() == false)

-- A press that flew is not half of a gesture, however briefly it lasted. This
-- is the one that matters in a fight: a flick of the stick and an immediate
-- press back onto it is ordinary flying, not a request to turn the ship round.
touch.now = 5.0
touch.on_touch({touch = {{id = 5, pressed = true,
                          screen_x = OX, screen_y = OY}}}, W, H, 1)
at(5.01, {id = 5, screen_x = OX + 70, screen_y = OY})
at(5.02, {id = 5, released = true, screen_x = OX + 70, screen_y = OY})
stick_tap(5.1)
check("a flick then a tap is not a gesture", touch.reversing() == false)

-- A press held still but held long is not a tap either.
touch.now = 6.0
touch.on_touch({touch = {{id = 5, pressed = true,
                          screen_x = OX, screen_y = OY}}}, W, H, 1)
at(6.9, {id = 5, released = true, screen_x = OX, screen_y = OY})
stick_tap(7.0)
check("a long hold then a tap is not a gesture", touch.reversing() == false)

-- A clock that never moves is a caller that has stopped setting it, and the
-- gesture goes quiet rather than firing on every pair of quick presses.
touch.now = 9.0
stick_tap(9.0)
stick_tap(9.0)
check("a stopped clock flips nothing", touch.reversing() == false)

-- --- and what the stance changes -------------------------------------------
--
-- The thumb names the course in both stances. Reversed, the nose is held at
-- the far end of it, which is what lets a pilot back out of a fight with the
-- guns still pointed into it.

touch.now = 10.0
stick_tap(10.0)
stick_tap(10.2)
check("set up reversed", touch.reversing() == true)

-- The ship is heading north and the thumb pushes north: the course is ahead,
-- so the nose has to come round to face south before the engine may burn.
b = ask(0, 60)
check("reversed, a course dead ahead is a turn",
      has(b, sim.BTN_LEFT) or has(b, sim.BTN_RIGHT))
check("and the engine is not lit through it",
      not has(b, sim.BTN_THRUST) and not has(b, sim.BTN_REVERSE))

-- Astern, the nose is already where reverse wants it, so nothing turns and
-- the ship backs up along its own heading.
b = ask(180, 60)
check("reversed, a course dead astern turns nothing",
      not has(b, sim.BTN_LEFT) and not has(b, sim.BTN_RIGHT))
check("and backs the ship up", has(b, sim.BTN_REVERSE))
check("with the forward engine off", not has(b, sim.BTN_THRUST))
check("and nothing else", #b == 1, #b .. " bits")

-- The rudder still turns toward the course, which is the far side of it from
-- the nose: a thumb to the right of a north-facing ship wants the nose south
-- of west, and left is the shorter way there.
b = ask(90, 60)
check("reversed, a course to the right turns left",
      has(b, sim.BTN_LEFT) and not has(b, sim.BTN_RIGHT))
b = ask(-90, 60)
check("and a course to the left turns right",
      has(b, sim.BTN_RIGHT) and not has(b, sim.BTN_LEFT))

-- The dead zone is the dead zone in either stance.
b = ask(180, 8)
check("reversed, a thumb that barely moved does nothing", #b == 0,
      #b .. " bits")

-- The flip lands on the second press, not its release, so one gesture is tap
-- then press-and-fly: the stance changes and the same thumb steers out of it
-- without leaving the glass.
touch.release_all()
touch.now = 20.0
check("release_all puts the ship back the way it flies",
      touch.reversing() == false)
stick_tap(20.0)
touch.now = 20.15
touch.on_touch({touch = {{id = 5, pressed = true,
                          screen_x = OX, screen_y = OY}}}, W, H, 1)
check("the flip lands on the press", touch.reversing() == true)
at(20.2, {id = 5, screen_x = OX, screen_y = OY - 60})
check("and the thumb that set it is already flying it",
      has(touch.bits(0), sim.BTN_REVERSE))
touch.release_all()

-- --- and the stance is drawn ----------------------------------------------
--
-- A latched mode is only as safe as the thing that says it is set, and the
-- resting mark is the whole of what says so once the thumb is off the glass.
-- If that ever goes quiet a pilot flies backward for a reason nothing on
-- screen explains, so it is worth an assertion rather than a look.
--
-- Counted rather than judged: the mark is a ring with a dot in it forward and
-- a ring with an arrow in it reversed, so the question is how many rings and
-- how many segments come out of the corner the stick rests in.

do
    local marks = require("arena.marks")
    -- marks.weapon draws the pads, and it asks the core about the loadout.
    -- Nothing here is about the pads, so the core answers zero to everything
    -- it has not already been given a value for.
    setmetatable(sim, {__index = function()
        return function() return 0 end
    end})

    local pads = touch.layout(W, H, 1)
    -- Every call the marks make, absorbed, and the three this is counting
    -- laid back over the top.
    local u = require("tests.ui_harness").layer()
    local drawn
    local function corner(x, y)
        -- The stick's own corner, which is the only part of the frame this
        -- is asking about: the triggers are at the far side of the window.
        return math.abs(x - pads.home.x) < pads.home.r * 2
            and math.abs(y - pads.home.y) < pads.home.r * 2
    end
    function u:ring(x, y) if corner(x, y) then drawn.ring = drawn.ring + 1 end end
    function u:disc(x, y) if corner(x, y) then drawn.disc = drawn.disc + 1 end end
    function u:seg(x1, y1) if corner(x1, y1) then drawn.seg = drawn.seg + 1 end end
    -- A ring is one circle however many passes draw it. The rim carries a
    -- crisp stroke with two wider, fainter ones under it that are the light
    -- coming off it, all at the same radius, so counting strokes here would
    -- count a glow as more rings. Counted by radius instead.
    function u:arc_aa(x, y, r, _, _, _, _, _)
        if corner(x, y) then
            local key = string.format("%.1f", r)
            if not drawn.radii[key] then
                drawn.radii[key] = true
                drawn.ring = drawn.ring + 1
            end
        end
    end
    function u:rect() end
    function u:frame() end
    marks.begin(u, 1)

    local function paint()
        drawn = {ring = 0, disc = 0, seg = 0, radii = {}}
        touch.draw(u, W, H, 1)
        return drawn
    end

    touch.release_all()
    touch.used = true
    local fwd = paint()
    -- One ring and a point at its middle, whichever way the engine faces.
    -- What used to sit inside it was a second ring, or reversed an arrow, and
    -- both were pictures of a stance: a thing to be learned, on the one
    -- control whose whole problem was that nobody learned it. The stance is
    -- the ring's own color now, and the gesture is written under it in words.
    -- See touch.hint.
    check("forward, the resting mark is a ring and a point",
          fwd.ring == 1 and fwd.disc == 1 and fwd.seg == 0,
          fwd.ring .. " rings, " .. fwd.disc .. " discs, "
          .. fwd.seg .. " segments")

    -- On the resting mark itself, so the thumb and the mark share a corner
    -- and one filter answers for both.
    local HX, HY = pads.home.x, pads.home.y
    touch.now = 40.0
    stick_tap(40.0, HX, HY)
    stick_tap(40.2, HX, HY)
    check("set up reversed for the drawing", touch.reversing() == true)
    local rev = paint()
    check("reversed, it is the same ring and point",
          rev.ring == 1 and rev.disc == 1 and rev.seg == 0,
          rev.ring .. " rings, " .. rev.disc .. " discs, "
          .. rev.seg .. " segments")
    -- What changed instead: the sentence under the rim, which names what the
    -- next double tap will do rather than the stance you are in. A pilot
    -- reading it is deciding whether to do it.
    check("and the hint under it now offers the way back",
          touch.hint(W, H, 1).text == "TAP ×2 · FORWARD",
          touch.hint(W, H, 1).text)

    -- And while a thumb is on it, the nose spur is drawn beyond the line the
    -- thumb itself makes: one segment forward, four reversed.
    touch.now = 41.0
    touch.on_touch({touch = {{id = 5, pressed = true,
                              screen_x = HX, screen_y = HY}}}, W, H, 1)
    touch.on_touch({touch = {{id = 5, screen_x = HX, screen_y = HY + 60}}},
                   W, H, 1)
    local held_rev = paint()
    check("reversed and flying, the nose is drawn as well as the thumb",
          held_rev.seg == 4, held_rev.seg .. " segments")
    touch.release_all()
    touch.on_touch({touch = {{id = 5, pressed = true,
                              screen_x = HX, screen_y = HY}}}, W, H, 1)
    touch.on_touch({touch = {{id = 5, screen_x = HX, screen_y = HY + 60}}},
                   W, H, 1)
    local held_fwd = paint()
    check("and forward it is the thumb alone", held_fwd.seg == 1,
          held_fwd.seg .. " segments")
    touch.release_all()
end

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
