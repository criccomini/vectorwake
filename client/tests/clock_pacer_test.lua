-- Prediction-clock pacing stays independent of Defold and the network facade,
-- so timing noise can be checked without a browser or a live arena.

package.path = "client/?.lua;" .. package.path

local pacer = require("arena.clock_pacer")
local fails = 0

local function check(name, ok, detail)
    if ok then
        print("ok   " .. name)
    else
        fails = fails + 1
        print("FAIL " .. name .. (detail and ("  -- " .. detail) or ""))
    end
end

local function near(a, b)
    return math.abs(a - b) < 0.000001
end

local p = pacer.new()
check("a fresh clock runs at its natural rate", near(p:rate(0), 1))

for i = 0, 9 do
    p:observe(i / 10, -3, 8)
end
check("individual snapshots cannot speed the clock", near(p:rate(0.9), 1))
p:observe(1.0, -3, 8)
check("one second of low margin speeds the clock gradually",
      near(p:rate(1.0), 1.01), tostring(p:rate(1.0)))
p:observe(1.05, -4, 9)
check("the target dead band restores the natural rate",
      near(p:rate(1.05), 1))

p:reset()
for i = 0, 10 do
    p:observe(2 + i / 10, -8, 8)
end
check("one second of excess lead slows the clock gradually",
      near(p:rate(3.0), 0.99), tostring(p:rate(3.0)))

p:reset()
for i = 0, 12 do
    local margin = i % 2 == 0 and -3 or -8
    p:observe(4 + i / 10, margin, 8)
end
check("alternating packet timing never becomes clock drift",
      near(p:rate(5.2), 1))

p:reset()
for i = 0, 10 do
    p:observe(6 + i / 10, -3, 8)
end
check("continuous evidence can activate pacing", near(p:rate(7.0), 1.01))
check("stale evidence cannot keep pacing a suspended page",
      near(p:rate(7.3), 1))
p:observe(7.3, -3, 8)
check("the first snapshot after a stall starts a new hold",
      near(p:rate(7.3), 1))

p:reset()
for i = 0, 10 do
    p:observe(8 + i / 10, -3, 40)
end
check("the lead ceiling prevents further speedup", near(p:rate(9.0), 1))

if fails > 0 then os.exit(1) end
print("all fine")
