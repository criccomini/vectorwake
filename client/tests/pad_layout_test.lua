-- Where the controls a thumb flies with are, and what they say.
--
-- Its sibling touch_test.lua drives the stick's arithmetic -- what a thumb's
-- position turns into as buttons. This one is about the other half: the pads,
-- their marks, and whether a tap lands on the one it looks like it lands on.
--
--     lua5.1 client/tests/pad_layout_test.lua
--
-- Two things have gone wrong here before and both are structural rather than
-- cosmetic, so both are measured rather than eyeballed.
--
-- The layout and the hit test were written out separately and drifted, so
-- half a pad did nothing and the dead space beside it fired. They share one
-- function now, and what that is worth is only real if a tap on the middle of
-- every drawn control is checked to reach that control.
--
-- And a control has to be reachable, distinct, and on the screen. A pad drawn
-- under the dial, a cell overlapping the trigger beside it, or a rail that
-- walks off the top of a short window are all faults a player meets before
-- anybody reviewing a diff does.
--
-- The drawing is measured through touch.draw with a recording layer, so what
-- is checked is what a player is shown rather than what the arithmetic
-- intended.

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

-- --- the engine, recording what is drawn and where -------------------------

local shapes = {}
local function put(kind, x0, y0, x1, y1, col)
    shapes[#shapes + 1] = {kind = kind, x0 = math.min(x0, x1),
                           y0 = math.min(y0, y1), x1 = math.max(x0, x1),
                           y1 = math.max(y0, y1), col = col}
    return shapes[#shapes]
end

-- How much of a shape there is, where its weight sits, and how far it reaches.
--
-- Both of the last two, because neither one is where a mark looks centered and
-- the answer is between them. Weighing a drawing by how much of it there is
-- puts a gun's center near the dot, since a solid disc outweighs the hairline
-- that reaches it. Taking its extent puts the center near the middle of the
-- line, since the far tip of a hairline counts for as much as the dot. A strip
-- of the mark drawn at biases either side agrees with the midpoint, so the
-- midpoint is what is checked, and marks.BOLT_BIAS is the number that came
-- out of the same measurement.
--
-- `rad` is the radius of the circle a piece belongs to, where it has one.
-- That is what tells the mark from the furniture: the pad's own ring and the
-- gauge outside it are circles the size of the pad, and weighing them buries
-- the mark's own offset under a much larger, perfectly centered mass.
local ink = {}
local function weigh(area, x, y, rad, x0, x1, alpha)
    if area > 0 then
        ink[#ink + 1] = {a = area, x = x, y = y, rad = rad,
                         -- A piece counts toward the extent only where it can
                         -- be seen. That is the whole reason a box and an eye
                         -- ever disagreed here.
                         x0 = (alpha or 1) >= 0.35 and x0 or nil, x1 = x1}
    end
end

local layer = {}
function layer:seg(x1, y1, x2, y2, w, c)
    -- The ends of the stroke as well as the box round it, because two of a
    -- box's four corners are not on the stroke at all and asking how far a
    -- diagonal reaches is exactly where that matters.
    local sh = put("seg", x1 - w / 2, y1 - w / 2, x2 + w / 2, y2 + w / 2, c)
    local a = c and c[4] or 1
    sh.tips = {{x1, y1, w / 2, a}, {x2, y2, w / 2, a}}
    local len = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
    weigh(len * w, (x1 + x2) / 2, (y1 + y2) / 2, nil,
          math.min(x1, x2) - w / 2, math.max(x1, x2) + w / 2, c and c[4])
end
function layer:seg_fade(x1, y1, x2, y2, w1, w2, a1, a2, c)
    local w = math.max(w1, w2)
    local sh = put("trail", x1 - w / 2, y1 - w / 2, x2 + w / 2, y2 + w / 2, c)
    -- Each end with its own width and its own alpha: a fade is thin and
    -- invisible at one end and neither of those is true at the other.
    sh.tips = {{x1, y1, w1 / 2, (c[4] or 1) * a1},
               {x2, y2, w2 / 2, (c[4] or 1) * a2}}
    -- Sliced, and each slice weighed by how visible it is.
    local n = 12
    local len = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2) / n
    for i = 1, n do
        local t = (i - 0.5) / n
        local px, py = x1 + (x2 - x1) * t, y1 + (y2 - y1) * t
        weigh(len * (w1 + (w2 - w1) * t) * (a1 + (a2 - a1) * t), px, py, nil,
              px - len / 2, px + len / 2,
              (c[4] or 1) * (a1 + (a2 - a1) * t))
    end
end
function layer:disc(x, y, r, _, c)
    put("disc", x - r, y - r, x + r, y + r, c)
    weigh(math.pi * r * r, x, y, r, x - r, x + r, c and c[4])
end
function layer:ring(x, y, r, w, _, c)
    put("ring", x - r - w, y - r - w, x + r + w, y + r + w, c).r = r
    weigh(2 * math.pi * r * w, x, y, r, x - r - w / 2, x + r + w / 2,
          c and c[4])
end
function layer:arc(x, y, r, a0, a1, w, _, c)
    put("arc", x - r - w, y - r - w, x + r + w, y + r + w, c).r = r
    -- An arc's weight sits at the middle of its own sweep, not at its center,
    -- and it reaches only as far as its own sweep carries it.
    local d = a1 - a0
    if math.abs(d) < 1e-6 then return end
    local x0, x1 = math.huge, -math.huge
    for i = 0, 24 do
        local t = a0 + d * i / 24
        x0 = math.min(x0, x + math.cos(t) * r)
        x1 = math.max(x1, x + math.cos(t) * r)
    end
    weigh(r * math.abs(d) * w,
          x + r * (math.sin(a1) - math.sin(a0)) / d,
          y - r * (math.cos(a1) - math.cos(a0)) / d, r,
          x0 - w / 2, x1 + w / 2, c and c[4])
end
function layer:rect(x, y, w, h, c) put("rect", x, y, x + w, y + h, c) end
function layer:frame(x, y, w, h, _, c) put("frame", x, y, x + w, y + h, c) end
for _, n in ipairs({"fan", "flush", "halo", "outline", "quad", "reset",
                    "ring_fade", "skirt", "tri", "tri_fade"}) do
    layer[n] = function() end
end

-- The core, answering about one hull. Everything the pads read comes through
-- here, which is the point: a pad reads the weapon rather than being told
-- about it, so a loadout and its drawing cannot disagree.
local MODS = {}          -- [trigger][mod index] = rungs
local LEVEL = {[0] = 0, [1] = 0}
local ENERGY, CAP = 700, 1000
_G.sim = setmetatable({
    TRIG_GUN = 0, TRIG_BOMB = 1,
    BTN_FIRE = 1, BTN_BOMB = 2, BTN_LEFT = 4, BTN_RIGHT = 8, BTN_THRUST = 16,
    BTN_REVERSE = 32,
    ship_mod = function(_, t, i) return (MODS[t] or {})[i] or 0 end,
    ship_level = function(_, t) return LEVEL[t] or 0 end,
    ship_energy = function() return ENERGY end,
    ship_max_energy = function() return CAP end,
    ship_multi_off = function() return false end,
    -- The zone's own shrapnel ladder. See stack_test for why a mark asks
    -- rather than works it out.
    shrap_count = function(n) return ({2, 4, 8})[math.min(n, 3)] or 0 end,
}, {__index = function() return function() return 0 end end})

local touch = require("arena.touch")
local marks = require("arena.marks")
local pal = require("arena.palette")

local function draw(w, h, s)
    shapes = {}
    ink = {}
    marks.begin(layer, s)
    touch.draw(layer, w, h, s)
    return touch.layout(w, h, s)
end

local function reset(w, h, s)
    touch.used = true
    touch.me = 0
    touch.has_bomb = true
    -- Off by default, which is the ordinary hull. A kit may omit multifire.
    -- The block at the bottom turns it on for the case that is actually tight.
    touch.has_fan = false
    touch.charges = {0, 1}
    touch.counts = {[0] = 2, [1] = 1}
    touch.maxes = {[0] = 3, [1] = 3}
    touch.safe_l, touch.safe_r, touch.safe_b = 0, 0, 0
    -- What the dial leaves: ui.radar_span() is two pads of 14 points plus
    -- 168 of dial. Written out rather than imported, because ui.lua drags
    -- the whole interface in and this is one number.
    touch.ceiling = h - 196 * s
    MODS = {}
    LEVEL = {[0] = 0, [1] = 0}
    return w, h, s
end

-- The window a phone actually is, in drawable pixels: 390 by 844 points at
-- two pixels per point, held either way.
local LAND = {1688, 780, 2}
local PORT = {780, 1688, 2}

-- A browser toolbar covers the bottom of the extended world canvas. Every
-- control a thumb needs moves above it by the measured amount, while their
-- spacing stays unchanged.
do
    local w, h, s = reset(unpack(PORT))
    local ordinary = touch.layout(w, h, s)
    touch.safe_b = 156
    local covered = touch.layout(w, h, s)
    check("browser chrome lifts both touch corners clear",
          covered.guns.y - ordinary.guns.y == 156
          and covered.home.y - ordinary.home.y == 156)
end

-- iOS standalone can report a viewport shorter than the physical screen.
-- Extending the world by that missing strip must not move the pads on the
-- glass: their distance from the old visible top stays identical.
do
    local w, h, s = reset(unpack(PORT))
    local ordinary = touch.layout(w, h, s)
    local extension = 124
    touch.safe_b = extension
    local extended = touch.layout(w, h + extension, s)
    check("a taller iOS world leaves both touch corners in place",
          h - ordinary.guns.y == h + extension - extended.guns.y
          and h - ordinary.home.y == h + extension - extended.home.y)
end

-- --- every control is drawn ------------------------------------------------

local W, H, S = reset(unpack(LAND))
local L = draw(W, H, S)

-- Ink inside a box, so "is anything drawn there" is a question about the
-- screen rather than about which call made it.
local function ink_in(x0, y0, x1, y1)
    local n = 0
    for _, sh in ipairs(shapes) do
        local cx, cy = (sh.x0 + sh.x1) / 2, (sh.y0 + sh.y1) / 2
        if cx >= x0 and cx <= x1 and cy >= y0 and cy <= y1 then n = n + 1 end
    end
    return n
end

local function marked(pad)
    -- Inside the pad's own rim rather than its bounding box, so the ring
    -- itself and the gauge outside it are not what answers.
    local r = pad.r * 0.8
    return ink_in(pad.x - r, pad.y - r, pad.x + r, pad.y + r)
end

check("the gun pad wears a mark", marked(L.guns) > 0,
      "nothing inside the gun's rim")
check("the bomb pad wears a mark", marked(L.bombs) > 0,
      "nothing inside the bomb's rim")
-- The fault this whole layout exists to fix. Both triggers were bare rings
-- telling each other apart by being slightly different sizes, so this is the
-- one check that must never come back green for the wrong reason: it asks how
-- the two marks differ, not whether they differ by some count.
--
-- A bomb has a ringed head and a gun is a line into a solid dot. That is the
-- distinction a player reads at a glance and the one worth pinning.
local function has_ring(pad)
    local r = pad.r * 0.8
    for _, sh in ipairs(shapes) do
        local cx, cy = (sh.x0 + sh.x1) / 2, (sh.y0 + sh.y1) / 2
        if sh.kind == "ring" and math.abs(cx - pad.x) < r
            and math.abs(cy - pad.y) < r and sh.r < pad.r * 0.6 then
            return true
        end
    end
    return false
end
check("the bomb's head is ringed and the gun's is not",
      has_ring(L.bombs) and not has_ring(L.guns),
      "bomb ringed: " .. tostring(has_ring(L.bombs)) ..
      ", gun ringed: " .. tostring(has_ring(L.guns)))
for i, c in ipairs(L.charge) do
    check("charge " .. i .. " wears its own mark", marked(c) > 0,
          "nothing inside the cell")
end

-- --- and each mark sits in the middle of its pad ---------------------------

-- Half way between where the drawing's weight sits and where the drawing
-- reaches, which is where it looks centered. A box alone got this wrong in the
-- shipped build, when a bomb was a fading trail into a solid head: the box
-- straddled the pad while everything you could see crowded one side, and the
-- mark sat a quarter of a pad radius off while every measurement said fine.
-- Weight alone gets it wrong the other way, and centers a gun on its dot with
-- the barrel hanging off the left of the pad.
--
-- Every loadout, because the pieces an add-on hangs on a mark are not
-- symmetric either: a fan pulls the weight back toward the muzzle and a bounce
-- ring pulls it forward, and the placement is the mean of what they do rather
-- than whichever one was drawn the day it was set.
local function mark_center(pad, other)
    -- Level with the pad, which keeps the rail of charge cells above it out of
    -- the sum; within a mark's reach of it and nearer it than the trigger
    -- beside it, which keeps the other weapon and the stick's resting mark
    -- out; and no bigger than a mark can be, which keeps the pad's own ring
    -- and its gauge out.
    local function mine(w)
        return (not other
                or math.abs(w.x - pad.x) < math.abs(w.x - other.x))
            and math.abs(w.x - pad.x) <= pad.r * 1.6
            and math.abs(w.y - pad.y) <= pad.r
            and not (w.rad and w.rad > pad.r * 0.7)
    end
    local sum, sx = 0, 0
    local lo, hi = math.huge, -math.huge
    for _, w in ipairs(ink) do
        if mine(w) then
            sum = sum + w.a
            sx = sx + w.a * w.x
            if w.x0 then
                lo = math.min(lo, w.x0)
                hi = math.max(hi, w.x1)
            end
        end
    end
    if sum <= 0 or lo > hi then return nil end
    return ((sx / sum) + (lo + hi) / 2) / 2 - pad.x
end

for _, load in ipairs({
    {"bare", {}},
    {"a fan", {[0] = {[0] = 1}}},
    {"a fan and bouncing rounds", {[0] = {[0] = 1, [1] = 1}}},
    {"a proximity fuse", {[1] = {[2] = 1}}},
    -- What 22 of the 24 hulls in the shipped zones are actually holding.
    {"a fuse and fragments", {[1] = {[2] = 1, [3] = 2}}},
}) do
    local w, h, s = reset(unpack(LAND))
    MODS = load[2]
    local l = draw(w, h, s)
    for _, pad in ipairs({{"gun", l.guns, l.bombs}, {"bomb", l.bombs, l.guns}}) do
        local off = mark_center(pad[2], pad[3])
        check("the " .. pad[1] .. " mark is centered with " .. load[1],
              off and math.abs(off) < pad[2].r * 0.10,
              off and string.format("%.1f off, %.0f%% of the radius", off,
                                    100 * off / pad[2].r) or "no ink")
    end
end

-- No round wears a trail. The tail is what put the bomb off center in the
-- first place: it faded to nothing along its length, so a box straddled the
-- pad while everything visible crowded one side. It belongs to a round in
-- flight, and a control is not showing a round going anywhere.
--
-- Checked over every loadout the catalog hands out rather than at one, because
-- a trail could come back through an add-on rather than through the body, and
-- through the body it could come back symmetrically, one either side say, and
-- pass every centring measurement while being wrong for the same reason.
-- Multifire is the exception and is why this is a list rather than a sweep of
-- all sixty-four: several rounds leaving together are several strokes, which
-- is that add-on's whole mark and is what a gun draws for it too. No zone in
-- the catalog puts it on a bomb.
local SHIPPED = {
    {"bare", {}},
    {"a fan and bouncing rounds", {[0] = {[0] = 2, [1] = 1}}},
    {"a fuse and fragments", {[1] = {[2] = 1, [3] = 2}}},
    {"a fuse, fragments, bouncing and a shove",
     {[1] = {[2] = 1, [3] = 2, [1] = 1, [5] = 2}}},
}
for _, load in ipairs(SHIPPED) do
    local w, h, s = reset(unpack(LAND))
    MODS = load[2]
    draw(w, h, s)
    local n = 0
    for _, sh in ipairs(shapes) do
        if sh.kind == "trail" then n = n + 1 end
    end
    check("no round trails on a pad with " .. load[1], n == 0,
          n .. " fading strokes on the controls")
end

do
    local w, h, s = reset(unpack(LAND))
    MODS = {[1] = {[2] = 1}}
    local l = draw(w, h, s)
    -- And with the tail gone the head is free to be drawn larger, which is
    -- the point of taking it off rather than merely a consequence.
    local span = 0
    for _, sh in ipairs(shapes) do
        if sh.kind == "ring" and math.abs((sh.x0 + sh.x1) / 2 - l.bombs.x) < 1
            and sh.r < l.bombs.r * 0.7 then
            span = math.max(span, sh.r)
        end
    end
    check("and the bomb fills its pad", span > l.bombs.r * 0.3,
          string.format("head reaches %.2f of the radius", span / l.bombs.r))
end

-- --- the gun wears no second ring -------------------------------------------

-- Energy came off the gun pad, because every hull carries a bar above it
-- saying the same thing and that one is where a player is already looking.
-- What is left is one ring per control, the same as the bomb's. Measured as
-- "nothing round is drawn outside the rim", since the fault would be some
-- other instrument moving in rather than this one coming back.
do
    local w, h, s = reset(unpack(LAND))
    ENERGY = 400
    local l = draw(w, h, s)
    local out = 0
    for _, sh in ipairs(shapes) do
        local cx, cy = (sh.x0 + sh.x1) / 2, (sh.y0 + sh.y1) / 2
        -- Its own radius rather than the box drawn round it, which a
        -- stroke widens on both sides: the rim would answer for itself.
        if sh.r and math.abs(cx - l.guns.x) < l.guns.r
            and math.abs(cy - l.guns.y) < l.guns.r
            and sh.r > l.guns.r * 1.02 then
            out = out + 1
        end
    end
    check("the gun pad draws nothing outside its rim", out == 0,
          out .. " rings past the edge of the control")
    ENERGY = 700
end

-- --- nothing overlaps anything ---------------------------------------------

-- Every control answers for its rim. The gun used to answer for an energy arc
-- riding a fifth of a radius outside its ring instead, which was the piece
-- that reached the rail above it; the hull's own bar says energy, so the arc
-- went and the rim is the whole of the gun again.
local function controls(L2)
    -- Interactive reach rather than visible ink. A layout can look separated
    -- while two enlarged thumb targets answer the same point.
    local out = {{n = "guns", x = L2.guns.x, y = L2.guns.y,
                  r = L2.guns.r * 1.18}}
    if touch.has_bomb then
        out[#out + 1] = {n = "bombs", x = L2.bombs.x, y = L2.bombs.y,
                         r = L2.bombs.r * 1.18}
    end
    for i, c in ipairs(L2.charge) do
        out[#out + 1] = {n = "charge" .. i, x = c.x, y = c.y,
                         r = c.w * 0.65}
    end
    return out
end

local function worst_overlap(L2)
    local c, worst = controls(L2), nil
    for i = 1, #c do
        for j = i + 1, #c do
            local d = math.sqrt((c[i].x - c[j].x) ^ 2 + (c[i].y - c[j].y) ^ 2)
            local want = c[i].r + c[j].r
            if d < want then
                worst = worst or (c[i].n .. " into " .. c[j].n)
            end
        end
    end
    return worst
end

for _, win in ipairs({LAND, PORT}) do
    local w, h, s = reset(unpack(win))
    local l = touch.layout(w, h, s)
    local o = worst_overlap(l)
    check("nothing overlaps at " .. w .. "x" .. h, not o, o)
    -- And on the screen.
    local off = nil
    for _, c in ipairs(controls(l)) do
        local reach = c.r
        if c.x - reach < 0 or c.x + reach > w
            or c.y - reach < 0 or c.y + reach > h then
            off = c.n
        end
    end
    check("and every control is on the screen at " .. w .. "x" .. h, not off,
          tostring(off) .. " leaves the window")
end

-- --- the fixed utility row keeps clear of the dial --------------------------

-- The row sits below the dial in either orientation. It never wraps because a
-- wrap would make a slot's position depend on the available height.
local TIGHT, ROOMY = 352, 1262      -- what ui.radar_span() leaves, either way

local function rows(l)
    local seen, n = {}, 0
    for _, c in ipairs(l.charge) do
        local k = string.format("%.0f", c.y)
        if not seen[k] then seen[k] = true n = n + 1 end
    end
    return n
end

local function under_ceiling(l, ceil)
    for _, c in ipairs(l.charge) do
        if c.y + c.r > ceil then return false end
    end
    return true
end

do
    local w, h, s = reset(unpack(PORT))
    touch.ceiling = ROOMY
    touch.charges = {0, 1, 2, 3}
    touch.counts = {[0] = 3, [1] = 3, [2] = 3, [3] = 3}
    local l = touch.layout(w, h, s)
    check("upright, a full rack is one fixed row", rows(l) == 1,
          rows(l) .. " rows")
    check("and all of it clears the dial", under_ceiling(l, ROOMY))
    check("and its thumb targets do not overlap", not worst_overlap(l),
          tostring(worst_overlap(l)))
end

do
    local w, h, s = reset(unpack(LAND))
    touch.ceiling = TIGHT
    touch.charges = {0, 1, 2, 3}
    touch.counts = {[0] = 3, [1] = 3, [2] = 3, [3] = 3}
    local l = touch.layout(w, h, s)
    check("sideways, a full rack stays on one row", rows(l) == 1,
          rows(l) .. " rows")
    check("and still clears the dial", under_ceiling(l, TIGHT),
          "a cell drawn into the dial's corner")
    check("with no overlapping thumb targets", not worst_overlap(l),
          tostring(worst_overlap(l)))
    local left = w
    for _, c in ipairs(l.charge) do left = math.min(left, c.x - c.r) end
    check("and the rack stays in the right third", left > w * 0.66,
          string.format("reaches %.2f of the way across", left / w))
    -- Above them, never beside them: a thumb going for the gun crosses no cell.
    local low = math.huge
    for _, c in ipairs(l.charge) do low = math.min(low, c.y - c.r) end
    check("and sits above them", low > l.guns.y + l.guns.r,
          "a cell level with the triggers")
end

-- --- what is drawn is what answers -----------------------------------------

-- The drift this file's comments are about. A tap on the middle of each
-- control has to reach that control, and a tap between two of them must not
-- reach the wrong one.
do
    local w, h, s = reset(unpack(LAND))
    local l = touch.layout(w, h, s)
    local got = {}
    local function tap(x, y)
        touch.release_all()
        local out = nil
        touch.on_touch({touch = {{id = 1, pressed = true,
                                  screen_x = x, screen_y = y}}}, w, h, s)
        local k = touch.fired_charge()
        if k then out = k
        else
            for _, bit in ipairs(touch.bits(0)) do
                if bit == sim.BTN_FIRE then out = "guns"
                elseif bit == sim.BTN_BOMB then out = "bombs"
                elseif bit == sim.BTN_REVERSE then out = "reverse" end
            end
        end
        if not out and touch.steering() then out = "stick" end
        touch.release_all()
        return out
    end
    got.guns = tap(l.guns.x, l.guns.y)
    got.bombs = tap(l.bombs.x, l.bombs.y)
    check("the gun pad fires the gun", got.guns == "guns", tostring(got.guns))
    check("the bomb pad drops a bomb", got.bombs == "bombs",
          tostring(got.bombs))
    local ok = true
    for _, c in ipairs(l.charge) do
        if tap(c.x, c.y) ~= c.slot then ok = false end
    end
    check("and every cell spends its own slot", ok,
          "a cell answered for another slot")

    -- The far left is the stick, and the gap over the triggers is nothing at
    -- all: a thumb reaching past the rail must not fire on the way.
    check("the left half steers", tap(w * 0.2, h * 0.3) == "stick")
    check("the space above the rail is dead",
          tap(l.guns.x, h - 10 * s) == nil,
          tostring(tap(l.guns.x, h - 10 * s)))
end

-- --- a hull with no rack ---------------------------------------------------

do
    local w, h, s = reset(unpack(LAND))
    touch.has_bomb = false
    local l = draw(w, h, s)
    check("a hull with no rack draws no bomb pad", marked(l.bombs) == 0,
          "a bomb pad on a hull that cannot carry one")
    touch.release_all()
    touch.on_touch({touch = {{id = 1, pressed = true, screen_x = l.bombs.x,
                              screen_y = l.bombs.y}}}, w, h, s)
    -- It falls through to the stick rather than being swallowed by a control
    -- that is not there.
    check("and does not swallow the tap", #touch.bits(0) == 0,
          "a button held by a pad nobody drew")
    touch.release_all()
end

-- --- the pads carry the whole loadout ---------------------------------------

-- The reason the corner stack can drop its weapon rows on a phone. If the pads
-- do not draw the add-ons, that trade is a straight loss, and for a while it
-- was one: the pads knew about a fan, a bounce and a fuse, and nothing else.
-- Shrapnel is on 22 of the 24 hulls the catalog ships, so the common bomb
-- upgrade in this game was the one a phone could not see, with the corner that
-- would have said so switched off on the grounds that the pads had it covered.
--
-- The same loop stack_test runs against the corner, against the same six, so
-- neither surface can quietly grow a vocabulary the other lacks.
for _, trig in ipairs({{0, "gun", "guns"}, {1, "bomb", "bombs"}}) do
    local w, h, s = reset(unpack(LAND))
    local l = draw(w, h, s)
    local bare = marked(l[trig[3]])
    for i = 1, #pal.MODS do
        reset(w, h, s)
        MODS = {[trig[1]] = {[i - 1] = 2}}
        l = draw(w, h, s)
        local n = marked(l[trig[3]])
        check(pal.MODS[i].name .. " draws on the " .. trig[2] .. " pad",
              n > bare, n .. " shapes inside the rim, bare is " .. bare)
    end
end

-- And however loaded it is, it stays inside the control it belongs to. Every
-- combination at full depth, which is a hull no zone hands out and a size this
-- has to survive anyway: the room around the round is shared out ahead of the
-- drawing so that it does.
do
    local worst, worst_case = 0, nil
    for _, trig in ipairs({{0, "guns"}, {1, "bombs"}}) do
        for bits = 0, 63 do
            local set = {}
            for i = 1, 6 do
                if math.floor(bits / 2 ^ (i - 1)) % 2 == 1 then set[i - 1] = 3 end
            end
            local w, h, s = reset(unpack(LAND))
            MODS = {[trig[1]] = set}
            local l = draw(w, h, s)
            local pad = l[trig[2]]
            for _, sh in ipairs(shapes) do
                local cx, cy = (sh.x0 + sh.x1) / 2, (sh.y0 + sh.y1) / 2
                local hw = math.max((sh.x1 - sh.x0) / 2, (sh.y1 - sh.y0) / 2)
                -- The mark's own pieces: near the pad, and smaller than it.
                -- The rim and the gauge are the size of the pad and would
                -- answer for themselves otherwise.
                if math.abs(cx - pad.x) < pad.r and math.abs(cy - pad.y) < pad.r
                    and hw < pad.r * 0.9 then
                    -- A round piece reaches its own radius from its own
                    -- center, and a stroke reaches its far end. Neither
                    -- reaches a corner of the box drawn round it, which is
                    -- what a box-only reading of this said and why a mark
                    -- inside its pad measured as a mark over the rim.
                    local d = math.sqrt((cx - pad.x) ^ 2 + (cy - pad.y) ^ 2)
                        + hw
                    if sh.tips then
                        d = 0
                        for _, t in ipairs(sh.tips) do
                            if t[4] >= 0.35 then
                                d = math.max(d, t[3] + math.sqrt(
                                    (t[1] - pad.x) ^ 2 + (t[2] - pad.y) ^ 2))
                            end
                        end
                    end
                    if d / pad.r > worst then
                        worst, worst_case = d / pad.r, bits
                    end
                end
            end
        end
    end
    check("no loadout draws a mark outside its own pad", worst < 1.0,
          string.format("reaches %.2f of the radius, loadout %s",
                        worst, tostring(worst_case)))
end

-- --- and what is in hand ---------------------------------------------------

do
    local w, h, s = reset(unpack(LAND))
    touch.counts = {[0] = 2, [1] = 0}
    local l = draw(w, h, s)
    -- Pips: as many marks as the hull can hold, filled as far as it is. The
    -- count used to be a numeral floating above the pad, which is the one
    -- piece of this interface that could not be drawn by the mesh.
    local function pips(c)
        local full, empty = 0, 0
        for _, sh in ipairs(shapes) do
            local cx, cy = (sh.x0 + sh.x1) / 2, (sh.y0 + sh.y1) / 2
            if math.abs(cx - c.x) < c.w * 0.5
                and math.abs(cy - (c.y - c.w * 0.33)) < c.w * 0.06 then
                if sh.kind == "disc" then full = full + 1
                elseif sh.kind == "ring" then empty = empty + 1 end
            end
        end
        return full, empty
    end
    local f1, e1 = pips(l.charge[1])
    check("a cell counts what is in hand", f1 == 2 and e1 == 1,
          f1 .. " held, " .. e1 .. " spent")
    -- And a slot spent out has no cell at all. A control that does nothing
    -- when pressed is bad enough with a keyboard; on glass there is no travel
    -- and no cursor, so the only way to learn a cell is dead is to tap it in
    -- the middle of a fight and get nothing back.
    check("and a spent slot draws no cell", #l.charge == 1,
          #l.charge .. " cells for one charge in hand")
    touch.counts = {[0] = 2, [1] = 1}
    local both = draw(w, h, s)
    local second
    for _, c in ipairs(both.charge) do
        if c.slot == 1 then second = {c.x, c.y} end
    end
    touch.counts = {[0] = 0, [1] = 1}
    local one = draw(w, h, s)
    check("and a surviving slot does not slide into the gap",
          #one.charge == 1 and one.charge[1].slot == 1 and second
          and one.charge[1].x == second[1] and one.charge[1].y == second[2],
          #one.charge .. " cells after its neighbor emptied")

    -- A hull holding nothing draws no rail, and nothing above the triggers
    -- answers a tap.
    reset(unpack(LAND))
    touch.counts = {}
    local none = draw(w, h, s)
    check("a hull holding no charges draws no rail", #none.charge == 0,
          #none.charge .. " cells with an empty hand")
end

-- --- multifire stays on the gun ---------------------------------------------
--
-- Equipping a fan adds an upward gesture affordance to the gun, not another
-- control. The layout and every charge target stay exactly where they were.
do
    local w, h, s = reset(unpack(LAND))
    touch.ceiling = TIGHT
    touch.charges = {0, 1, 2, 3}
    -- Stock in every slot, or the rail quietly drops the empty ones and the
    -- tight case under test is not the tight case.
    touch.counts = {[0] = 3, [1] = 3, [2] = 3, [3] = 3}
    touch.maxes = {[0] = 3, [1] = 3, [2] = 3, [3] = 3}
    touch.has_fan = false
    local bare = touch.layout(w, h, s)
    touch.has_fan = true
    local l = touch.layout(w, h, s)
    check("a fan adds no standalone control",
          l.fan == nil and #l.charge == 4,
          tostring(l.fan) .. ", " .. #l.charge .. " charges")
    local same = #bare.charge == #l.charge
    for i, c in ipairs(l.charge) do
        same = same and c.x == bare.charge[i].x and c.y == bare.charge[i].y
    end
    check("equipping it moves no utility target", same)
    check("the full rack still has no overlap", not worst_overlap(l),
          worst_overlap(l))
    check("and the row still clears the dial", under_ceiling(l, TIGHT),
          "something is drawn into the dial's corner")
    for _, c in ipairs(controls(l)) do
        check(c.n .. " is on the screen",
              c.x - c.r >= 0 and c.x + c.r <= w
                  and c.y - c.r >= 0 and c.y + c.r <= h,
              string.format("%s at %.0f,%.0f r%.0f", c.n, c.x, c.y, c.r))
    end
end

-- --- four charge kinds -------------------------------------------------------
--
-- A kit chooses two kinds, but the core can represent four. Exercising all
-- four keeps the layout safe at that storage boundary, and every cell retains
-- its fixed slot as the rack empties.
do
    local w, h, s = reset(unpack(PORT))
    touch.ceiling = ROOMY
    touch.has_fan = true
    touch.charges = {0, 1, 2, 3}
    touch.counts = {[0] = 3, [1] = 3, [2] = 3, [3] = 3}
    touch.maxes = {[0] = 3, [1] = 3, [2] = 3, [3] = 3}
    local l = touch.layout(w, h, s)
    check("four charges make four cells", #l.charge == 4,
          tostring(#l.charge))
    check("nothing in the utility row overlaps", worst_overlap(l) == nil,
          tostring(worst_overlap(l)))
    check("and the utility row clears the dial", under_ceiling(l, ROOMY))
    for _, c in ipairs(controls(l)) do
        check(c.n .. " is on the screen with a full rail",
              c.x - c.r >= 0 and c.x + c.r <= w
                  and c.y - c.r >= 0 and c.y + c.r <= h,
              string.format("%s at %.0f,%.0f r%.0f", c.n, c.x, c.y, c.r))
    end

    -- Spending one must not slide a cell a thumb is already reaching for.
    local at = {}
    for _, c in ipairs(l.charge) do at[c.slot] = {c.x, c.y} end
    touch.counts = {[0] = 0, [1] = 1, [2] = 2, [3] = 0}
    local fewer = touch.layout(w, h, s)
    local held = true
    for _, c in ipairs(fewer.charge) do
        if c.x ~= at[c.slot][1] or c.y ~= at[c.slot][2] then held = false end
    end
    check("and every surviving cell holds its place as the rack empties", held)
    check("while a spent slot leaves no cell behind", #fewer.charge == 2,
          tostring(#fewer.charge))
end

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
