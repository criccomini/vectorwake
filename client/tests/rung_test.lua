-- The rung ramp: one colour a rung, and colour on a round says nothing else.
--
--     lua5.1 client/tests/rung_test.lua
--
-- Colour is the only channel a three-pixel object crossing a screen has, so
-- what this measures is whether two rounds can actually be told apart, in
-- units of perceived difference rather than in hex.
--
-- The ramp this replaced failed both ways and neither was visible in the
-- source. Its rungs were ten units apart, which is not a call anybody makes
-- under fire. It put a rung 3 bomb on the charge colour exactly, and a rung 4
-- bolt within seven of the HUD's own text. And it blended toward white, so
-- the two teams converged as they climbed and the deadliest rounds were the
-- hardest to attribute.
--
-- Every one of those is a number, so every one of them is checked here. The
-- present ramp borrows a scale everybody knows and pays for it by coming
-- nearer the prize green and the charge gold than a ramp of its own hues
-- would; the floors below are set under what it actually measures, so they
-- catch a regression without pinning the palette to today's exact values.

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

-- CIE76: coarse next to the modern formulas, and far more than enough to
-- separate "two colours" from "one colour twice". Under about 15 is a
-- distinction nobody makes on something moving.
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

-- --- there is one ramp -----------------------------------------------------

check("the ramp has a rung for every level a zone hands out",
      type(pal.RUNG) == "table" and #pal.RUNG == 4,
      tostring(pal.RUNG and #pal.RUNG) .. " rungs")

-- The whole point of the change: a bullet and a bomb, yours and theirs, read
-- off one table. Three ramps is what it replaced, so three ramps must not
-- come back.
check("and there is only the one", pal.FRIEND_LVL == nil
      and pal.ENEMY_LVL == nil and pal.BOMB_LVL == nil,
      "a per-team or per-weapon ramp is back")

-- Out of range either way, because a level comes from a zone file and a zone
-- file is not this repository.
check("a level past the top of the ramp still has a colour",
      pal.rung(99) == pal.RUNG[4] and pal.rung(-3) == pal.RUNG[1],
      "the clamp does not hold")

-- --- one rung against the next ---------------------------------------------

local worst, pair = math.huge, ""
for i = 1, #pal.RUNG - 1 do
    local d = de(pal.RUNG[i], pal.RUNG[i + 1])
    if d < worst then
        worst = d
        pair = string.format("%s to %s at %.0f", hexof(pal.RUNG[i]),
                             hexof(pal.RUNG[i + 1]), d)
    end
end
check("one rung is well clear of the next", worst > 25,
      "closest: " .. pair)

-- Not only neighbours: rung 1 against rung 4 matters just as much, and a
-- ramp that wanders can bring two distant rungs back together.
local any, apair = math.huge, ""
for i = 1, #pal.RUNG do
    for j = i + 1, #pal.RUNG do
        local d = de(pal.RUNG[i], pal.RUNG[j])
        if d < any then
            any = d
            apair = string.format("%s and %s at %.0f", hexof(pal.RUNG[i]),
                                  hexof(pal.RUNG[j]), d)
        end
    end
end
check("and no two rungs anywhere in it are close", any > 25,
      "closest: " .. apair)

-- --- and clear of everything else on the screen ----------------------------

-- What a round can be mistaken for. Each of these means something a player
-- acts on, so a round wearing one is a round telling a lie.
local SPENT = {
    {"team cyan", pal.FRIEND}, {"team amber", pal.ENEMY},
    {"charge gold", pal.CHARGE_COL}, {"prize green", pal.PRIZE},
    {"burst violet", pal.BURST}, {"HUD ink", pal.INK},
    {"a bomb's own colour", pal.BOMB}, {"rust", pal.RUST},
}
local near, nname = math.huge, ""
for i, c in ipairs(pal.RUNG) do
    for _, s in ipairs(SPENT) do
        local d = de(c, s[2])
        if d < near then
            near = d
            nname = string.format("rung %d %s is %.0f from %s", i, hexof(c),
                                  d, s[1])
        end
    end
end
check("no rung lands on something already spent", near > 20, nname)

-- Burst and shrapnel are the one thing on the map that answers to no aim and
-- sits on no ladder, which is why they keep a colour of their own. If a rung
-- ever reaches it, that distinction is gone.
local vio = math.huge
for _, c in ipairs(pal.RUNG) do vio = math.min(vio, de(c, pal.BURST)) end
check("and none of them reaches the violet that means no ladder", vio > 30,
      string.format("%.0f from the burst violet", vio))

-- --- it reads as a scale ---------------------------------------------------

-- A ramp is a sequence, not a set: rung 4 has to look like more than rung 1
-- or the colours are four labels a player has to memorise. Measured as a
-- turn through hue rather than as lightness, since the point of leaving the
-- old ramp was that lightness alone converged.
local function hue(c)
    local _, a, b = lab(c)
    return math.deg(math.atan2(b, a)) % 360
end
-- One direction, whichever it is: green through red and red through green are
-- both scales, and a ramp that doubles back is four labels to memorise.
local step, ok = {}, true
for i = 1, #pal.RUNG - 1 do
    local d = (hue(pal.RUNG[i]) - hue(pal.RUNG[i + 1])) % 360
    if d > 180 then d = d - 360 end
    step[i] = d
    if math.abs(d) < 12 or (i > 1 and d * step[i - 1] <= 0) then ok = false end
end
check("and it turns one way through the wheel, rung to rung", ok,
      string.format("steps %.0f %.0f %.0f", step[1] or 0, step[2] or 0,
                    step[3] or 0))

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
