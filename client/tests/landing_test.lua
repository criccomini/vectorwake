-- The landing: the panel that says which room a press would put you in.
--
--     lua5.1 client/tests/landing_test.lua
--
-- It is the first page of the game and the one every player sees most, and it
-- had drifted into a shape that fought the window it was in. A rule down its
-- left edge, which is the right shape for a panel standing beside something
-- and this one is the leftmost thing on the screen, pushed the whole page a
-- rail's width right of the wordmark directly above it. Two captions named
-- things the page already said: "deploying to" over a room's name and "on the
-- clock" over a running clock. A line reading "arriving as Apex" sat above
-- the key it was about, beside a drawing of the same hull. The two sides'
-- score columns were headed once, above the first of them. And the key itself
-- was pinned to the foot of the window, which on a desktop left a third of a
-- screen of nothing between the roster and the one thing to press.
--
-- Every check here is measured off a real menu frame, because all of it is
-- geometry: which column something is in, what is drawn beside it, and how
-- far the key is from the thing above it.

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

-- --- the engine, as much of it as ui.lua touches ---------------------------

local W, H = 1236, 1500
local segs, rects, discs, quads, outs, boxes
local layer = {}
local function noop() end
for _, n in ipairs({"arc", "flush", "reset", "ring", "ring_fade", "seg_fade",
                    "seg_flat", "skirt", "halo", "fan", "seg_glow",
                    "glow_band", "tri_fade"}) do
    layer[n] = noop
end
local tris
-- Everything is kept in the layer's own frame, which is the frame the drawn
-- text is in, so a mark and the word beside it compare without a flip.
layer.rect = function(_, x, y, w, h)
    rects[#rects + 1] = {x = x, y = y, w = w, h = h}
end
layer.seg = function(_, x0, y0, x1, y1, w)
    segs[#segs + 1] = {x0 = x0, y0 = y0, x1 = x1, y1 = y1, w = w}
end
layer.disc = function(_, x, y) discs[#discs + 1] = {x = x, y = y} end
layer.quad = function(_, x, y) quads[#quads + 1] = {x = x, y = y} end
layer.outline = function(_, pts) outs[#outs + 1] = pts end
layer.tri = function(_, x0, y0, x1, y1, x2, y2)
    tris[#tris + 1] = {x0 = x0, y0 = y0, x1 = x1, y1 = y1, x2 = x2, y2 = y2}
end
layer.frame = function(_, x, y, w, h)
    boxes[#boxes + 1] = {x = x, y = y, w = w, h = h}
end

-- Four a side, alternating people and machines, so a check about the marks
-- has one of each to find on the same rule.
local NAMES = {"Halcyon", "Sable", "Ozone", "Tessellate",
               "Cirrus", "Ridgeline", "Kestrel", "Vantage"}
_G.sim = setmetatable({
    ship_count = function() return 8 end,
    ship_active = function() return 1 end,
    ship_alive = function() return 1 end,
    ship_team = function(i) return i < 4 and 0 or 1 end,
    charge_max = function() return 3 end,
    has_trigger = function() return true end,
    tick = function() return 100 end,
    flag_at = function() return 0, 0, 255 end,
    map_coarse = function() return nil end,
    T_SOLID = 1, T_SLOPE = 2, T_SAFE = 3, T_DOOR = 4,
}, {__index = function() return function() return 0 end end})

package.loaded["arena.state"] = {text = {}, n = 0, version = 0}
package.loaded["arena.touch"] = {layout = function() return {charge = {}} end,
                                 used = false}
package.loaded["arena.world"] = {
    build_overview = noop, forget_overview = noop,
    overview = {grid = 4, n = 0, rect = {}},
    radar_tiles = {}, radar_safe = {}, radar_doors = {},
    -- The real Apex, because the gap beside the hull in the key is measured
    -- off the poly's own half-width and a stub triangle would not test it.
    HULLS = {{poly = {0, 21, 1.6, 12, 2.6, 5, 6.5, -1, 11, -9, 8.5, -11.5,
                      3.5, -6.5, 3, -10.5, 0, -11.5, -3, -10.5, -3.5, -6.5,
                      -8.5, -11.5, -11, -9, -6.5, -1, -2.6, 5, -1.6, 12},
              mid = 4.75}}}

local ui = require("arena.ui")
local st = package.loaded["arena.state"]

local pilots = {}
for i = 0, 7 do
    pilots[i] = {name = NAMES[i + 1], ai = i % 2 == 1,
                 label = i % 2 == 1 and "ai" or "human"}
end

local function view(playing)
    return {
        home = true, closable = false, focus = "stage",
        rail = {{label = "Play"}, {label = "Ship"}, {label = "Settings"}},
        at = "play", sel = 1,
        rows = {{label = "Melee", act = "join", value = 1}},
        aside = {deploy = true, head = "deploying to", label = "Melee",
                 note = "Four a side, three minutes", zones = 3, at = 1,
                 room = {players = 4, bots = 4, seats = 8},
                 clock = 160, playing = playing, ground = "drydock", row = 1,
                 arrive = {spectate = false, hull = 0, name = "Apex",
                           call = "you"}},
        arena = {pilots = pilots, watchers = {}, side = 0,
                 score = {[0] = 1, [1] = 1},
                 names = {[0] = "Pylon", [1] = "Caisson"}},
        pilot = {name = "you", rivets = 0},
    }
end

local said
local function frame(playing, w, h)
    W, H = w or 1236, h or 1500
    segs, rects, discs, quads, outs, boxes, tris =
        {}, {}, {}, {}, {}, {}, {}
    st.n = 0
    ui.begin(layer, W, H, 1, false)
    ui.menu(view(playing ~= false))
    ui.finish()
    said = {}
    for i = 1, st.n do
        local t = st.text[i]
        said[#said + 1] = {s = t.s, low = string.lower(t.s or ""),
                           x = t.x, y = t.y, px = t.px}
    end
end

local function drawn(word)
    for _, t in ipairs(said) do
        if string.find(t.low, word, 1, true) then return t end
    end
end

-- The rail is the wordmark and the tabs across the top. Its left edge is
-- whatever it draws furthest left, which is the mark before the word.
local function rail_left()
    local lo = math.huge
    local function keep(x, y) if H - y < 110 then lo = math.min(lo, x) end end
    for _, g in ipairs(segs) do keep(g.x0, g.y0) keep(g.x1, g.y1) end
    for _, g in ipairs(tris) do
        keep(g.x0, g.y0) keep(g.x1, g.y1) keep(g.x2, g.y2)
    end
    for _, g in ipairs(rects) do keep(g.x, g.y) end
    for _, g in ipairs(outs) do
        for i = 1, #g, 2 do keep(g[i], g[i + 1]) end
    end
    return lo
end

frame(true)

-- --- flush with the rail ---------------------------------------------------

local note = drawn("four a side")
check("the page says what the game is", note ~= nil)
check("and starts where the rail above it starts",
      note and math.abs(note.x - rail_left()) < 3,
      note and ("page at %.1f, rail at %.1f"):format(note.x, rail_left())
          or "no note")

-- Nothing hangs off a lit vertical any more, so nothing tall and thin stands
-- at the panel's left edge. Measured as a stroke taller than the roster it
-- would be standing beside.
local vert = nil
for _, g in ipairs(segs) do
    if math.abs(g.x0 - g.x1) < 1 and math.abs(g.y0 - g.y1) > 200
       and g.x0 < 120 then
        vert = g
    end
end
check("and hangs off no rule of its own", vert == nil,
      vert and ("a %.0f px stroke at x %.1f")
          :format(math.abs(vert.y0 - vert.y1), vert.x0) or "none")

-- --- captions that named what was under them ------------------------------

check("no caption over the room's name", drawn("deploying to") == nil,
      drawn("deploying to") and "still there" or "")
check("nor over a running clock", drawn("on the clock") == nil,
      drawn("on the clock") and "still there" or "")
check("but the clock is still there", drawn("2:40") ~= nil)

-- Between matches the same figure counts to a start rather than to a finish,
-- which the numerals cannot say and the caption can.
frame(false)
check("a clock counting to a whistle still says so",
      drawn("next match in") ~= nil, "lost with the other two")
frame(true)

-- --- what is flying each hull ---------------------------------------------

-- A person and a machine on the same side, one under the other. The two marks
-- are told apart the way they are drawn: a visor is a strip of quads, a
-- machine's face is lamps, which are discs.
local function marks_on(name)
    local row = drawn(string.lower(name))
    if not row then return nil end
    local d, q = 0, 0
    for _, g in ipairs(discs) do
        if math.abs(g.y - row.y) < 12 and g.x < row.x then d = d + 1 end
    end
    for _, g in ipairs(quads) do
        if math.abs(g.y - row.y) < 12 and g.x < row.x then q = q + 1 end
    end
    return d, q, row
end

local hd, hq, hrow = marks_on("Halcyon")
local bd, bq = marks_on("Sable")
check("a person's row wears a mark", hrow ~= nil and hq > 0,
      ("%s quads"):format(tostring(hq)))
check("and so does a machine's", bd and bd > 0,
      ("%s discs"):format(tostring(bd)))
-- A visor is what a person's mark has and a machine's has not, and lamps are
-- what a machine's has more of. Either alone would pass on two copies of one
-- mark, which is the failure worth catching: it was the *absence* of a mark
-- that used to say "machine", so a column of identical marks would read as a
-- fix while saying exactly as little.
check("and the two are not the same mark", bq == 0 and bd > hd,
      ("person %d lamps %d visor, machine %d lamps %d visor")
          :format(hd or -1, hq or -1, bd or -1, bq or -1))
check("with the names standing clear of both",
      hrow and hrow.x > rail_left() + 12,
      hrow and ("name at %.1f"):format(hrow.x) or "none")

-- --- both sides get their columns headed ----------------------------------

local heads = {}
for _, t in ipairs(said) do
    if t.low == "k  d" then heads[#heads + 1] = t end
end
check("each side heads its own two columns", #heads == 2, tostring(#heads))
for _, name in ipairs({"Pylon", "Caisson"}) do
    local side = drawn(string.lower(name))
    local level = nil
    for _, hh in ipairs(heads) do
        if math.abs(hh.y - (side and side.y or -1)) < 2 then level = hh end
    end
    check(name .. " is headed on its own line", level ~= nil,
          side and ("side at %.1f, heads at %s"):format(side.y,
              table.concat({heads[1] and heads[1].y or -1,
                            heads[2] and heads[2].y or -1}, " and "))
              or "no side")
end

-- --- the key, and what is in it -------------------------------------------

check("nothing says what you are arriving as in words",
      drawn("arriving as") == nil, "still there")

local key
for _, bx in ipairs(boxes) do
    if bx.h > 50 * 1.1 and bx.w > 200 then key = bx end
end
check("there is a key to press", key ~= nil)
local word = drawn("deploy")
check("and it says deploy", word ~= nil)

-- The hull, in the key rather than a line above it.
local hull = nil
for _, pts in ipairs(outs) do
    local lo, hi, ty, by = math.huge, -math.huge, math.huge, -math.huge
    for i = 1, #pts, 2 do
        lo = math.min(lo, pts[i])
        hi = math.max(hi, pts[i])
        ty = math.min(ty, pts[i + 1])
        by = math.max(by, pts[i + 1])
    end
    if key and lo > key.x and hi < key.x + key.w
       and ty > key.y and by < key.y + key.h then
        hull = {lo = lo, hi = hi, ty = ty, by = by}
    end
end
check("the hull you would arrive in is drawn inside it", hull ~= nil,
      "nothing of the sort inside the key")
check("to the left of the word, clear of it",
      hull and word and hull.hi < word.x - 6,
      hull and word and ("hull ends at %.1f, word starts at %.1f")
          :format(hull.hi, word.x) or "none")
-- Both halves in the middle of the key rather than parked against an edge,
-- which is what a mark bolted onto a centered word would look like.
check("and the pair sits in the middle of the key",
      hull and word and key
      and hull.lo > key.x + key.w * 0.25
      and word.x < key.x + key.w * 0.75,
      hull and word and key
          and ("hull at %.0f, word at %.0f, key %.0f..%.0f")
              :format(hull.lo, word.x, key.x, key.x + key.w) or "none")

-- --- and the key follows the page rather than the window ------------------

-- The lowest thing the page draws above the key: the last roster row, or the
-- map panel where the roster is shorter than it.
local floor_of_page = 0
for _, t in ipairs(said) do
    if key and t.y > key.y + key.h and t.y < H - 120 then
        floor_of_page = math.max(floor_of_page, H - t.y)
    end
end
local gap = key and (H - (key.y + key.h)) - floor_of_page or -1
check("the key stands just under what the page drew", gap > 0 and gap < 110,
      ("%.0f px of nothing above it"):format(gap))
check("rather than at the foot of the window",
      key and (H - key.y) < H * 0.7,
      key and ("key bottom at %.0f of %d"):format(H - key.y, H) or "none")

if fails > 0 then
    print(("\n%d check(s) failed"):format(fails))
    os.exit(1)
end
print("\nall ok")
