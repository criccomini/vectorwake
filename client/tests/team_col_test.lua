-- A colour a side, generated from its byte.
--
--     lua5.1 client/tests/team_col_test.lua
--
-- Cyan and orange answer "mine or not", and in a room holding ten sides the
-- next question is "which not-mine". A side's colour answers it, and it has
-- to answer without anything being sent: the same byte has to make the same
-- colour on every machine, or two players describing the same squad are
-- describing different ones.
--
-- Three things can go wrong and none of them is visible in the source. A side
-- could be issued a cyan and read as friendly, which is the one mistake here
-- that costs somebody a life. Two sides could land near enough to be one
-- colour twice. And the generator could allocate on every call, which matters
-- because a plate asks for its colour once per ship per frame.
--
-- So the distances are measured rather than eyeballed, in CIE76, which is
-- coarse next to the modern formulas and far more than enough to tell "two
-- colours" from "one colour twice".

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

local pal = require("arena.palette")

local function lab(c)
    local function lin(v)
        return v <= 0.04045 and v / 12.92 or ((v + 0.055) / 1.055) ^ 2.4
    end
    local r, g, b = lin(c[1]), lin(c[2]), lin(c[3])
    local x = 0.4124 * r + 0.3576 * g + 0.1805 * b
    local y = 0.2126 * r + 0.7152 * g + 0.0722 * b
    local z = 0.0193 * r + 0.1192 * g + 0.9505 * b
    local function f(t)
        return t > 0.008856 and t ^ (1 / 3) or 7.787 * t + 16 / 116
    end
    local fx, fy, fz = f(x / 0.95047), f(y), f(z / 1.08883)
    return 116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)
end

local function de(c1, c2)
    local l1, a1, b1 = lab(c1)
    local l2, a2, b2 = lab(c2)
    return math.sqrt((l1 - l2) ^ 2 + (a1 - a2) ^ 2 + (b1 - b2) ^ 2)
end

local function hexof(c)
    return string.format("#%02x%02x%02x", math.floor(c[1] * 255 + 0.5),
                         math.floor(c[2] * 255 + 0.5),
                         math.floor(c[3] * 255 + 0.5))
end

-- --- it is a colour, and it is the same one every time ---------------------

local c0 = pal.team(0)
check("a side has a colour", type(c0) == "table" and #c0 == 4, hexof(c0))
check("and asking twice gives the same one", pal.team(0) == c0,
      "a fresh table a frame is an allocation in a draw loop")
check("every byte answers", pal.team(255) ~= nil and pal.team(0) ~= nil)
check("and a missing byte does not throw", pal.team() ~= nil)

-- --- no side is issued a cyan ----------------------------------------------

-- The costly mistake. Everything else here is legibility; this one is a
-- player reading an enemy plate as a teammate's.
local worst, worst_t = 999, nil
for t = 0, 63 do
    local d = de(pal.team(t), pal.FRIEND)
    if d < worst then worst, worst_t = d, t end
end
check("no side lands on the colour that means yours", worst > 25,
      string.format("team %d is %.0f from FRIEND (%s)", worst_t or -1, worst,
                    hexof(pal.team(worst_t or 0))))

-- --- and no two sides are one colour twice ---------------------------------

-- Over the count a room actually holds. Sixty-four sides on one hue wheel
-- would be indistinguishable whatever the scheme, and no zone deals that
-- many: the shipped ones cap at ten.
local N = 12
local near, pair = 999, nil
for a = 0, N - 1 do
    for b = a + 1, N - 1 do
        local d = de(pal.team(a), pal.team(b))
        if d < near then near, pair = d, a .. " and " .. b end
    end
end
check("the sides a room holds are told apart", near > 15,
      string.format("%s are %.0f apart", tostring(pair), near))

-- --- and they are legible on the field they are drawn over -----------------

for t = 0, N - 1 do
    local c = pal.team(t)
    local l = lab(c)
    check("side " .. t .. " reads against the field", l > 55,
          hexof(c) .. " lightness " .. string.format("%.0f", l))
end

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
