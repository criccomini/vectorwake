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

local layer = {}
function layer:seg(x1, y1, x2, y2, w, c)
    put("seg", x1 - w / 2, y1 - w / 2, x2 + w / 2, y2 + w / 2, c)
end
function layer:seg_fade(x1, y1, x2, y2, w1, w2, _, _, c)
    local w = math.max(w1, w2)
    put("seg", x1 - w / 2, y1 - w / 2, x2 + w / 2, y2 + w / 2, c)
end
function layer:disc(x, y, r, _, c) put("disc", x - r, y - r, x + r, y + r, c) end
function layer:ring(x, y, r, w, _, c)
    put("ring", x - r - w, y - r - w, x + r + w, y + r + w, c).r = r
end
function layer:arc(x, y, r, _, _, w, _, c)
    put("arc", x - r - w, y - r - w, x + r + w, y + r + w, c).r = r
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
    ship_mod = function(_, t, i) return (MODS[t] or {})[i] or 0 end,
    ship_level = function(_, t) return LEVEL[t] or 0 end,
    ship_energy = function() return ENERGY end,
    ship_max_energy = function() return CAP end,
    ship_multi_off = function() return false end,
}, {__index = function() return function() return 0 end end})

local touch = require("arena.touch")
local marks = require("arena.marks")

local function draw(w, h, s)
    shapes = {}
    marks.begin(layer, s)
    touch.draw(layer, w, h, s)
    return touch.layout(w, h, s)
end

local function reset(w, h, s)
    touch.used = true
    touch.me = 0
    touch.has_bomb = true
    touch.charges = {0, 1}
    touch.counts = {[0] = 2, [1] = 1}
    touch.maxes = {[0] = 3, [1] = 3}
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

-- --- nothing overlaps anything ---------------------------------------------

-- The gun answers for its gauge rather than its rim: the arc rides outside
-- the ring and is the piece that actually reaches the rail above it.
local GAUGE = 1.25

local function controls(L2)
    local out = {{n = "guns", x = L2.guns.x, y = L2.guns.y,
                  r = L2.guns.r * GAUGE},
                 {n = "home", x = L2.home.x, y = L2.home.y, r = L2.home.r}}
    if touch.has_bomb then
        out[#out + 1] = {n = "bombs", x = L2.bombs.x, y = L2.bombs.y,
                         r = L2.bombs.r}
    end
    for i, c in ipairs(L2.charge) do
        out[#out + 1] = {n = "charge" .. i, x = c.x, y = c.y, r = c.r}
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
    -- On the screen, with the gun's gauge counted: it rides outside the rim
    -- and is the piece that reaches furthest.
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

-- --- the rail keeps clear of the dial --------------------------------------

-- The dial is what bounds the rail, and how much it bounds it is the whole
-- difference between the two orientations: on a phone held upright there is
-- most of a screen of edge to climb, and held sideways the dial takes better
-- than half the height and leaves room for one cell. Both are measured,
-- because the wrap is not an edge case on a landscape phone -- it is the
-- ordinary behaviour there, and it is the arithmetic that has to produce a
-- column in one window and a block in the other.
local TIGHT, ROOMY = 352, 1262      -- what ui.radar_span() leaves, either way

local function columns(l)
    local seen, n = {}, 0
    for _, c in ipairs(l.charge) do
        local k = string.format("%.0f", c.x)
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
    local l = touch.layout(w, h, s)
    check("upright, a full rack is one column", columns(l) == 1,
          columns(l) .. " columns with a screen of edge to climb")
    check("and all of it clears the dial", under_ceiling(l, ROOMY))
end

do
    local w, h, s = reset(unpack(LAND))
    touch.ceiling = TIGHT
    touch.charges = {0, 1, 2, 3}
    local l = touch.layout(w, h, s)
    check("sideways, a full rack steps sideways instead",
          columns(l) == #l.charge,
          columns(l) .. " columns where only one cell fits under the dial")
    check("and still clears the dial", under_ceiling(l, TIGHT),
          "a cell drawn into the dial's corner")
    check("with nothing overlapping after the wrap", not worst_overlap(l),
          tostring(worst_overlap(l)))
    -- The bound that makes the wrap acceptable. Stepping left is fine while
    -- the rack stays in the block over the triggers; walking into the middle
    -- of the screen is the row this layout replaced, drawn one cell higher.
    local left = w
    for _, c in ipairs(l.charge) do left = math.min(left, c.x - c.r) end
    check("and the rack stays over the triggers", left > w * 0.75,
          string.format("reaches %.2f of the way across", left / w))
    -- Above them, never beside them: a thumb going for the gun crosses no
    -- cell on the way.
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
        elseif touch.bits(0)[1] == sim.BTN_FIRE then out = "guns"
        elseif touch.bits(0)[1] == sim.BTN_BOMB then out = "bombs"
        elseif touch.steering() then out = "stick" end
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

-- --- the pads carry the loadout --------------------------------------------

-- The reason the corner stack can drop its weapon rows on a phone. If the
-- pads do not actually draw the add-ons, that trade is a straight loss.
do
    local w, h, s = reset(unpack(LAND))
    draw(w, h, s)
    local plain = marked(touch.layout(w, h, s).guns)
    reset(w, h, s)
    MODS = {[0] = {[0] = 1}}                    -- a fan on the gun
    draw(w, h, s)
    local fanned = marked(touch.layout(w, h, s).guns)
    check("a fan draws more gun than no fan", fanned > plain,
          fanned .. " against " .. plain)

    reset(w, h, s)
    MODS = {[0] = {[0] = 1, [1] = 1}}           -- and it bounces
    draw(w, h, s)
    check("and bouncing rounds draw more still",
          marked(touch.layout(w, h, s).guns) > fanned,
          marked(touch.layout(w, h, s).guns) .. " against " .. fanned)

    reset(w, h, s)
    draw(w, h, s)
    local bare = marked(touch.layout(w, h, s).bombs)
    reset(w, h, s)
    MODS = {[1] = {[2] = 1}}                    -- a proximity fuse
    draw(w, h, s)
    check("a fuse draws more bomb than no fuse",
          marked(touch.layout(w, h, s).bombs) > bare,
          marked(touch.layout(w, h, s).bombs) .. " against " .. bare)
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
    local f2, e2 = pips(l.charge[2])
    check("and an empty one still counts its room", f2 == 0 and e2 == 3,
          f2 .. " held, " .. e2 .. " spent")
end

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
