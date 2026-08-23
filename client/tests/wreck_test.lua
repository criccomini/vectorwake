-- A ship coming apart, and which way its pieces go.
--
--     lua5.1 client/tests/wreck_test.lua
--
-- The death burst is the one event this game gives a full second to, and for
-- most of that second it was running backwards. Not the pieces, which fly
-- outward exactly as they are launched, but where they were drawn: the ripple
-- that bends the sky around a shockwave was bending the wreckage too, and it
-- had no idea the wreckage was standing in the middle of it.
--
-- Two faults, both in fx.bend. The shove fell off over a fixed 260 pixel band
-- either side of the ring, so a ring four pixels across still shoved a point
-- standing at its own center by the full crest amount. And the loop moved the
-- point as it went, so the second ring measured a piece the first had already
-- thrown and threw it again from where it landed. A death throws two rings
-- wide enough to ripple, at once, from one place.
--
-- Between them: three frames after a death the pieces sat a mean of four
-- pixels from the hull and were drawn at fifty-seven. A third of a second
-- later they had really travelled out to twenty-one and were drawn at thirty.
-- Every piece flying outward, the whole wreck closing.
--
-- So this file measures where the wreck is drawn, frame by frame, and asks
-- the only question a player is asking: is it getting wider.

package.path = "client/?.lua;" .. package.path

local fails = 0
local function check(name, ok, detail)
    if ok then
        print("ok   " .. name)
    else
        fails = fails + 1
        print("FAIL " .. name .. (detail and ("  -- " .. detail) or ""))
    end
end

local fx = require("arena.fx")
local pal = require("arena.palette")

-- A layer that keeps the hull pieces and throws the rest away. Sparks and
-- shards both come through seg_fade; the pieces are the ones drawn with a
-- fixed 0.8 tail, which is fx's own way of saying wreckage rather than light.
local hull
local glow = {}
local function noop() end
for _, n in ipairs({"bloom", "ring_fade"}) do glow[n] = noop end
function glow:seg_fade(x0, y0, x1, y1, w0)
    if w0 == 0.8 then
        hull[#hull + 1] = {x = (x0 + x1) / 2, y = (y0 + y1) / 2}
    end
end

-- How wide the wreck is: the mean distance of its pieces from where the ship
-- was. As long as none of them has burned out yet, that number can only fall
-- if pieces moved inward, which is the whole question.
local function spread()
    hull = {}
    fx.draw(glow)
    if #hull == 0 then return 0, 0 end
    local sum = 0
    for _, p in ipairs(hull) do
        sum = sum + math.sqrt(p.x * p.x + p.y * p.y)
    end
    return sum / #hull, #hull
end

-- --- the wreck only ever gets wider ----------------------------------------

fx.reset()
fx.listener(0, 0)
fx.destroy(0, 0, 0, 0, pal.ENEMY)

local dt = 1 / 60
local first, pieces = spread()
local last, peak, worst, at, frames = first, first, 0, 0, 0
check("a death draws hull pieces", pieces > 0, tostring(pieces))

-- Held to the stretch where every piece is still alive. A shard burning out
-- takes its distance out of the mean with it, so past that point the number
-- can fall for a reason that is not the wreck moving.
--
-- Measured against the widest the wreck has been rather than against the
-- frame before, because the fault this catches gave up a quarter of its
-- spread over twenty frames and never more than two pixels in any one of
-- them. Frame to frame that is a rounding error; end to end it is a ship
-- sucking itself back together.
while true do
    fx.update(dt)
    local now, n = spread()
    if n ~= pieces then break end
    frames = frames + 1
    if peak - now > worst then worst, at = peak - now, frames * dt end
    if now > peak then peak = now end
    last = now
end

check("the whole hull is still in the air long enough to judge",
      frames * dt > 0.5, ("only %.2fs"):format(frames * dt))
-- A pixel of slack, because the pieces tumble and the drawn midpoint of a
-- spinning shard is not perfectly still.
check("and never walks back toward the middle while it is",
      worst < 1, ("gave up %.1f px by t=%.2f"):format(worst, at))
check("it is wider at the end of that than at the start",
      last > first + 20, ("%.1f to %.1f"):format(first, last))

-- --- why it used to ---------------------------------------------------------

-- The bend is the mechanism, so it is checked on its own too: the two faults
-- above are both invisible in the mean once they are fixed, and a check that
-- can only fail as a moving average is a check nobody can read.

fx.reset()
fx.listener(0, 0)
fx.destroy(0, 0, 0, 0, pal.ENEMY)
fx.update(dt)

local function shove(d)
    local bx = fx.bend(d, 0, 1)
    return bx - d
end

-- The shape the shove has to have: nothing at the middle, growing out to the
-- ring, dying away past it. It used to be flat across all of that, so a speck
-- on the epicenter of a ring four pixels wide was thrown fifty-seven.
check("a shock leaves what is standing in its middle where it is",
      shove(1.5) < 3, ("thrown %.1f px"):format(shove(1.5)))
check("and shoves harder the nearer the ring you stand",
      shove(3) < shove(8) and shove(8) < shove(12),
      ("%.1f, %.1f, %.1f at 3, 8 and 12 px")
          :format(shove(3), shove(8), shove(12)))

-- And it still bends what it passes, or the ripple has been fixed by being
-- deleted. The rings a death throws reach ninety-six pixels; something out
-- where they are travelling has to move.
check("what it is passing through still moves", shove(90) > 6,
      ("90 px out moved %.1f"):format(shove(90)))
check("and what it has not reached does not", shove(400) == 0,
      ("400 px out moved %.1f"):format(shove(400)))

if fails > 0 then
    print(("\n%d check(s) failed"):format(fails))
    os.exit(1)
end
print("\nall ok")
