-- What a mark draws while its hull is gone.
--
--     lua5.1 client/tests/held_test.lua
--
-- Dying strips a ship of levels, add-ons and charges in one instruction, so
-- a mark that reads the core straight through drops to a plain green round
-- for the whole respawn wait: the interface rearranging itself over the card
-- that says what killed you. `marks.hold` is what stops that, and what it
-- stops is invisible in CI and only lasts four seconds on a phone, so it is
-- measured here instead.
--
-- The check is a comparison, not a picture: draw a loaded weapon against a
-- live ship, strip the ship the way a death strips it, and assert the mark
-- is unchanged while held and does change once the hold is dropped. That
-- second half is the one that matters, because a test that only proves
-- something stayed the same passes just as well against a drawing that
-- cannot change at all.

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

-- --- a recording layer -----------------------------------------------------

-- Every primitive as a line of text: shape, rounded geometry, and the colour
-- it was drawn in. Comparing the whole record catches a mark that moved, one
-- that lost a decoration, and one that only changed hue, which is exactly the
-- fault reported: green where the round had climbed a ladder.
local rec = {}
local function put(...)
    local parts = {}
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if type(v) == "number" then
            parts[#parts + 1] = string.format("%.2f", v)
        elseif type(v) == "table" then
            parts[#parts + 1] = string.format("(%.3f %.3f %.3f %.3f)",
                v[1] or 0, v[2] or 0, v[3] or 0, v[4] or 1)
        else
            parts[#parts + 1] = tostring(v)
        end
    end
    rec[#rec + 1] = table.concat(parts, " ")
end

local layer = {}
for _, name in ipairs({"seg", "seg_fade", "disc", "halo", "ring", "ring_fade",
                       "arc", "rect", "frame", "tri", "tri_fade", "outline",
                       "fan", "quad", "skirt", "flush", "reset"}) do
    layer[name] = function(_, ...) put(name, ...) end
end

-- --- a ship that can be stripped -------------------------------------------

-- A loaded hull: the gun two rungs up wearing a fan and a bounce, the bomb a
-- rung up wearing a fuse and fragments. Enough that every part of the mark
-- has something to lose.
local live = {
    level = {[0] = 2, [1] = 1},
    mods = {[0] = {[0] = 2, [1] = 1, [2] = 0, [3] = 0, [4] = 0, [5] = 0},
            [1] = {[0] = 0, [1] = 0, [2] = 1, [3] = 2, [4] = 0, [5] = 0}},
    multi_off = false,
}
-- What a death leaves: the memset, exactly.
local stripped = {
    level = {[0] = 0, [1] = 0},
    mods = {[0] = {}, [1] = {}},
    multi_off = false,
}
local ship = live

_G.sim = {
    ship_level = function(_, t) return ship.level[t] or 0 end,
    ship_mod = function(_, t, i) return (ship.mods[t] or {})[i] or 0 end,
    ship_multi_off = function() return ship.multi_off end,
    TRIG_GUN = 0,
    TRIG_BOMB = 1,
    TRIG_COUNT = 2,
    MOD_COUNT = 6,
}

local marks = require("arena.marks")

-- One trigger's mark, as a string. `me` is any ship index; the stubs above
-- answer for whichever hull `ship` currently points at.
local function draw(t)
    rec = {}
    marks.begin(layer, 1)
    marks.weapon(120, 80, 22, 0, t)
    return table.concat(rec, "\n")
end

-- --- the flown hull, and the same hull dead --------------------------------

local before_gun, before_bomb = draw(0), draw(1)
check("a loaded gun draws something", #before_gun > 0)
check("and its mark is not the bomb's", before_gun ~= before_bomb)

-- The pilot dies: the core strips the ship, and the frame loop hands the
-- marks the copy it kept of what was being flown.
ship = stripped
marks.hold(live)
check("the gun keeps what it was flying while the hull is gone",
      draw(0) == before_gun)
check("and so does the bomb", draw(1) == before_bomb)

-- Respawn: the hold is dropped, and the mark tells the truth about the fresh
-- hull, which is that it carries nothing.
marks.hold(nil)
local after_gun, after_bomb = draw(0), draw(1)
check("a fresh hull's gun is drawn stripped", after_gun ~= before_gun)
check("and so is its bomb", after_bomb ~= before_bomb)

-- The colour is the reported symptom, so it gets its own check rather than
-- riding on the record comparison: rung zero is the green a stripped round
-- is drawn in, and the held mark must not be wearing it.
local pal = require("arena.palette")
local function green_count(s)
    local g = pal.rung(0)
    local want = string.format("(%.3f %.3f %.3f", g[1], g[2], g[3])
    local n = 0
    for _ in string.gmatch(s, want:gsub("%(", "%%("):gsub("%.", "%%.")) do
        n = n + 1
    end
    return n
end
check("a stripped mark really is drawn in the rung-zero green",
      green_count(after_gun) > 0, "no green in the stripped mark")
marks.hold(live)
check("and the held mark is not",
      green_count(draw(0)) == 0, "green survived into the held mark")
marks.hold(nil)

-- The rung a trigger is on, which the pads ring themselves in. This is not
-- covered by the record above, because the ring is drawn by touch.lua rather
-- than by the mark, and reading the core for it while the mark read the copy
-- is what a photographed death actually showed: an orange fan inside a green
-- ring for the length of the respawn wait.
ship = stripped
marks.hold(live)
check("the rung the pads ring themselves in is held too",
      marks.level(0, 0) == live.level[0] and marks.level(0, 1) == live.level[1],
      "gun " .. marks.level(0, 0) .. ", bomb " .. marks.level(0, 1))
marks.hold(nil)
check("and released with everything else",
      marks.level(0, 0) == 0 and marks.level(0, 1) == 0)

-- A hold that has never been filled must not blank a living ship: the copy is
-- only offered once a hull has been flown, and nil means read the core.
ship = live
check("no hold means the live ship", draw(0) == before_gun)

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
