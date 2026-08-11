-- What color a round comes at you in.
--
--     lua5.1 client/tests/round_col_test.lua
--
-- One ramp for every round in the game: the rung a weapon has climbed is its
-- hue, so what is coming says how hard it hits. `rung_test` measures the ramp
-- itself, that its four colors stay apart from each other and from everything
-- else on the screen. This measures what the arena actually paints with it.
--
-- The case that brought it here is shrapnel. A fragment is a bullet: the core
-- reads the rung and the bouncing off the thrower's guns at the throw and
-- gives the fragment a bullet of that rung's damage. It was drawn in the
-- burst's violet all the same, which is the band for weapons on no ladder at
-- all, so a pilot who had climbed to red bullets threw red fragments and
-- watched violet ones come out of their bombs.
--
-- The rung cannot come off the spec for that one, which is why it was wrong.
-- Every fragment in the game is one spec, since a rung adds to its damage
-- instead of pointing at a row of its own, so `spec_level` finds it on
-- nobody's ladder and answers -1. It comes off the round, where the core put
-- it.

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

-- --- the room ---------------------------------------------------------------

-- Specs 1 to 4 are the gun ladder, one spec a rung, which is how a zone builds
-- one: a rung is a row of its own with more damage on it. Spec 5 is the burst,
-- fired from a charge and on nobody's ladder. Spec 6 is the fragment, also on
-- nobody's ladder and for a different reason, and the whole point of the file.
-- Spec 7 is the mine, and it is the third reason a rung cannot come off the
-- spec: a mine is a charge, so every mine in the game is one spec whatever
-- rung was posted, and the ladder it wears is its layer's bomb ladder.
local SPECS = {
    [1] = {life = 550, level = 0}, [2] = {life = 550, level = 1},
    [3] = {life = 550, level = 2}, [4] = {life = 550, level = 3},
    [5] = {life = 550, level = -1},
    [6] = {life = 550, level = -1},
    [7] = {life = 6000, level = -1, blast = 80, still = true, trigger = 32},
}
local BOLT = {[0] = 1, [1] = 2, [2] = 3, [3] = 4}
local MINE = 7

-- One round in the air at a time. Each row is what `weapon_at` hands back.
local air = nil

_G.sim = {
    tick = function() return 1000 end,
    spec_blast = function(id) return (SPECS[id] or {}).blast or 0 end,
    spec_still = function(id) return (SPECS[id] or {}).still or false end,
    spec_trigger = function(id) return (SPECS[id] or {}).trigger or 0 end,
    spec_life = function(id) return (SPECS[id] or {}).life or 0 end,
    spec_level = function(id) return (SPECS[id] or {}).level or -1 end,
    weapon_count = function() return air and 1 or 0 end,
    -- x, y, spec, vx, vy, team, life, owner, depth, level.
    weapon_at = function()
        return 400, 300, air.spec, 1, 0, 1, SPECS[air.spec].life, air.owner or 7,
               air.depth or 0, air.level or 0
    end,
}

package.loaded["arena.fx"] = setmetatable({}, {
    __index = function() return function() end end,
})

local world = require("arena.world")
local pal = require("arena.palette")

-- --- the layers, recording every stroke and what it was tinted -------------

local drawn = {}
local function rec(kind, ...)
    local n = select("#", ...)
    local col = select(n, ...)
    local a = {}
    for i = 1, n - 1 do a[i] = select(i, ...) end
    drawn[#drawn + 1] = {kind = kind, args = a, col = col}
end
local layer = {}
function layer:seg_fade(...) rec("seg_fade", ...) end
function layer:halo(...) rec("halo", ...) end
function layer:ring(...) rec("ring", ...) end
function layer:disc(...) rec("disc", ...) end
-- What a mine is made of. Two of these cannot go through `rec`, which reads
-- the color off the end of the argument list: `seg` carries a cap flag after
-- its color, and `fan` takes a table of points rather than a run of numbers,
-- which the flattening would record as one opaque value.
function layer:ring_fade(...) rec("ring_fade", ...) end
function layer:seg(x1, y1, x2, y2, width, col)
    drawn[#drawn + 1] = {kind = "seg", args = {x1, y1, x2, y2, width}, col = col}
end
function layer:fan(pts, col)
    local a = {}
    for i = 1, #pts do a[i] = pts[i] end
    drawn[#drawn + 1] = {kind = "fan", args = a, col = col}
end

local CULL = {x0 = 0, y0 = 0, x1 = 800, y1 = 600}

-- Everything drawn for one round, at a fixed clock so the arrival bloom is the
-- same for all of them and the strokes are comparable stroke for stroke.
local function draw(w)
    air = w
    drawn = {}
    world.weapons(layer, layer, 12.5, CULL)
    air = nil
    return drawn
end

local function hex(c)
    return string.format("%02x%02x%02x", c[1] * 255 + 0.5, c[2] * 255 + 0.5,
                         c[3] * 255 + 0.5)
end

-- The colors a round was painted in, in order, as text. A bolt is four
-- strokes and two of them run the hue hot, so a round is a short list rather
-- than a single color, and comparing the lists is comparing the whole look.
local function palette_of(shapes)
    local out = {}
    for i, s in ipairs(shapes) do out[i] = hex(s.col) end
    return table.concat(out, " ")
end

local function same_shape(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i].kind ~= b[i].kind or #a[i].args ~= #b[i].args then return false end
        for k = 1, #a[i].args do
            if math.abs(a[i].args[k] - b[i].args[k]) > 1e-9 then return false end
        end
    end
    return true
end

-- --- a bullet is its rung ---------------------------------------------------

for lvl = 0, 3 do
    local got = palette_of(draw({spec = BOLT[lvl]}))
    check(string.format("a rung %d bullet is drawn in rung %d", lvl, lvl),
          got:find(hex(pal.rung(lvl)), 1, true) ~= nil,
          "drawn " .. got .. ", want " .. hex(pal.rung(lvl)))
end

-- --- and a fragment is the bullet it is -------------------------------------

-- Stroke for stroke and color for color, at every rung. Not "close to the
-- bullet" and not "some color off the ramp": the same drawing, because the
-- weapon is the same weapon and a player told them apart on sight was being
-- told something untrue.
for lvl = 0, 3 do
    local bolt = draw({spec = BOLT[lvl]})
    local frag = draw({spec = 6, depth = 1, level = lvl})
    check(string.format("a fragment off rung %d guns is a rung %d bullet", lvl,
                        lvl),
          palette_of(frag) == palette_of(bolt),
          "fragment " .. palette_of(frag) .. ", bullet " .. palette_of(bolt))
    check("and drawn with the same strokes", same_shape(frag, bolt),
          "the fragment is not the shape of the bullet")
end

-- The one a player reported, kept as its own line because it is the failure
-- and not an instance of it: violet on a round that came off a ladder.
local red = draw({spec = 6, depth = 1, level = 3})
check("and no fragment is violet", not palette_of(red):find(hex(pal.BURST), 1,
                                                            true),
      "still wearing the burst's color")

-- --- what is genuinely on no ladder stays violet ----------------------------

-- The burst is the weapon that band is for. It is a charge: a thing you found
-- whole, carrying none of your add-ons and climbing nothing, so there is no
-- rung to draw it in. Its bolts have depth 0 and that is what tells them from
-- a fragment, which is also on no ladder and has a rung all the same.
local burst = palette_of(draw({spec = 5}))
check("a burst's bolts are still violet",
      burst:find(hex(pal.BURST), 1, true) ~= nil, "drawn " .. burst)
for lvl = 0, 3 do
    check(string.format("and rung %d has not reached them", lvl),
          not burst:find(hex(pal.rung(lvl)), 1, true), "drawn " .. burst)
end

-- --- a mine wears the rung of the bombs that laid it ------------------------

-- A charge, like the burst, and drawn nothing like it. The burst has no rung
-- because nobody's ladder reaches it; a mine has one because it *is* the bomb
-- you left behind, and the core hands the layer's bomb rung to the round for
-- exactly this. Violet here would say "a thing you found whole", which is
-- true of the charge and false of what it puts on the floor.
for lvl = 0, 3 do
    local got = palette_of(draw({spec = MINE, level = lvl}))
    check(string.format("a mine laid off rung %d bombs is rung %d", lvl, lvl),
          got:find(hex(pal.rung(lvl)), 1, true) ~= nil,
          "drawn " .. got .. ", want " .. hex(pal.rung(lvl)))
    check(string.format("and a rung %d mine is not violet", lvl),
          not got:find(hex(pal.BURST), 1, true), "drawn " .. got)
end

-- Two rungs apart are two colors apart, which is the property the ramp exists
-- for and the one a single shared spec would have quietly cost.
check("and two mines off different rungs do not match",
      palette_of(draw({spec = MINE, level = 0}))
      ~= palette_of(draw({spec = MINE, level = 3})))

-- It is a mine rather than a bomb on the screen, too: the shapes differ, and
-- the dark center is the whole of what separates them at a glance.
check("a mine is not drawn as a bomb",
      not same_shape(draw({spec = MINE, level = 2}), draw({spec = BOLT[2]})))

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
