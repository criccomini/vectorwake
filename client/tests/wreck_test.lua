-- A ship coming apart, and which way its pieces go.
--
--     lua5.1 client/tests/wreck_test.lua
--
-- The death burst is the one event this game gives a full second to, and for
-- most of that second it was running backwards. Not the pieces, which fly
-- outward exactly as they are launched, but where they were drawn: the ripple
-- that bent the sky around a shockwave bent the wreckage too, and it had no
-- idea the wreckage was standing in the middle of it. Three frames after a
-- death the pieces sat a mean of four pixels from the hull and were drawn at
-- fifty-seven; a third of a second later they had really travelled out to
-- twenty-one and were drawn at thirty. Every piece flying outward, the whole
-- wreck closing.
--
-- The ripple is gone now, so a piece is drawn where it is. This file is what
-- keeps that true: it measures where the wreck is drawn, frame by frame, and
-- asks the only question a player is asking, which is whether it is getting
-- wider. Anything that moves a fragment away from its own position for the
-- look of the thing has to answer here first.

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

if fails > 0 then
    print(("\n%d check(s) failed"):format(fails))
    os.exit(1)
end
print("\nall ok")
