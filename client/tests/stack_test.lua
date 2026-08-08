-- The corner stack's two weapon marks, and what a loadout does to them.
--
--     lua5.1 client/tests/stack_test.lua
--
-- A gun and a bomb are one mark each, and an add-on is drawn onto the mark it
-- belongs to rather than set out beside it. That reads well and it makes the
-- row's width a function of what the ship is carrying, which is exactly the
-- kind of thing that looks fine on the hull somebody happened to test and
-- overruns a neighbouring row on a hull nobody did.
--
-- Three rules hold it together, and none of them is visible until a player is
-- flying a loaded ship on a build that takes six minutes to publish:
--
--   the mark stays inside its own row, however many add-ons it wears;
--   it never reaches the column the ladders and the bounty count in;
--   and every add-on draws something, so a green that landed is a green the
--   corner shows.
--
-- So this runs the real `M.hud` against a stubbed engine, records the geometry
-- rather than counting calls, and measures.

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

-- --- the engine, recording rather than drawing -----------------------------

-- Every primitive lands here as the box it occupies, in the layer's own
-- coordinates: origin bottom left, y upward, which is what `ry` flipped into.
-- The stack is read back in those, since flipping twice to ask a question
-- about a row is two chances to get the arithmetic wrong.
local shapes = {}
local kind = nil       -- what primitive is being recorded, for `subject`
local tint = nil       -- the colour it was drawn in, where that is the question
local function box(x0, y0, x1, y1, col, w)
    if x1 < x0 then x0, x1 = x1, x0 end
    if y1 < y0 then y0, y1 = y1, y0 end
    shapes[#shapes + 1] = {x0 = x0, y0 = y0, x1 = x1, y1 = y1, col = col,
                           w = w, kind = kind, tint = tint}
end

-- Kept apart from `col`, which the ladder search used to match against. A
-- mark's own colours have no business deciding where the counting column is,
-- and putting them in the same field would make the column's position depend
-- on what the hull is carrying.
local function hue(c)
    if not c then return "?" end
    return string.format("%.3f,%.3f,%.3f", c[1], c[2], c[3])
end

-- How much of the row a shape actually darkens, and where that ink sits.
--
-- Kept apart from the boxes above because the two answer different questions
-- and the difference is a real fault, not a rounding one: a bomb's trail is a
-- fade that reaches its full length and almost none of its brightness, so a
-- bounding box counts it and a player does not see it. Centring the boxes put
-- the bomb visibly right of the rows under it while every box-based check
-- said the stack was aligned.
local ink = {}
local function mark(weight, cx, cy)
    if weight > 0 then ink[#ink + 1] = {w = weight, x = cx, y = cy} end
end

local layer = {}
local function len(x1, y1, x2, y2)
    return math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
end

function layer:seg(x1, y1, x2, y2, w, c)
    tint = c
    box(x1 - w, y1 - w, x2 + w, y2 + w, nil, w)
    tint = nil
    mark(len(x1, y1, x2, y2) * w, (x1 + x2) / 2, (y1 + y2) / 2)
end
-- Sampled along its length rather than taken whole, because the point of a
-- fade is that one end of it is not there.
function layer:seg_fade(x1, y1, x2, y2, w1, w2, a1, a2, c)
    local w = math.max(w1, w2)
    tint = c
    box(x1 - w, y1 - w, x2 + w, y2 + w, nil, w)
    tint = nil
    local n = 8
    for i = 0, n - 1 do
        local t = (i + 0.5) / n
        mark(len(x1, y1, x2, y2) / n * (w1 + (w2 - w1) * t)
             * (a1 + (a2 - a1) * t), x1 + (x2 - x1) * t,
             y1 + (y2 - y1) * t)
    end
end
function layer:disc(x, y, r, _, c)
    kind, tint = "disc", c
    box(x - r, y - r, x + r, y + r)
    kind, tint = nil, nil
    mark(math.pi * r * r, x, y)
end
function layer:halo(x, y, r) box(x - r, y - r, x + r, y + r) end
function layer:ring(x, y, r, w)
    box(x - r - w, y - r - w, x + r + w, y + r + w, nil, w)
    mark(2 * math.pi * r * w, x, y)
end
function layer:ring_fade(x, y, r, w)
    box(x - r - w, y - r - w, x + r + w, y + r + w)
end
-- An arc is bounded by its own circle whichever way it opens, which is all
-- this needs: the question is whether a mark stayed inside a row, and a
-- generous box can only fail a mark that passed.
-- An arc is bounded by its own circle whichever way it opens, which is all the
-- box needs: the question there is whether a mark stayed inside a row, and a
-- generous box can only fail a mark that passed. Its ink is the run of it, and
-- its ink sits at the mean of the arc rather than at the centre of the circle.
function layer:arc(x, y, r, a0, a1, w)
    box(x - r - w, y - r - w, x + r + w, y + r + w, nil, w)
    local d = a1 - a0
    if d ~= 0 then
        mark(r * math.abs(d) * w,
             x + r * (math.sin(a1) - math.sin(a0)) / d, y)
    end
end
function layer:rect(x, y, w, h, col)
    box(x, y, x + w, y + h, col)
    mark(w * h, x + w / 2, y + h / 2)
end
function layer:frame(x, y, w, h, s, col)
    box(x, y, x + w, y + h, col)
    mark(2 * (w + h) * (s or 1), x + w / 2, y + h / 2)
end
function layer:outline(pts, w)
    for i = 1, #pts - 1, 2 do
        box(pts[i] - w, pts[i + 1] - w, pts[i] + w, pts[i + 1] + w)
        local j = (i + 2 <= #pts - 1) and i + 2 or 1
        mark(len(pts[i], pts[i + 1], pts[j], pts[j + 1]) * w,
             (pts[i] + pts[j]) / 2, (pts[i + 1] + pts[j + 1]) / 2)
    end
end
function layer:fan(pts)
    for i = 1, #pts - 1, 2 do box(pts[i], pts[i + 1], pts[i], pts[i + 1]) end
end
for _, name in ipairs({"flush", "quad", "reset", "skirt", "tri", "tri_fade"}) do
    layer[name] = function() end
end

-- What this hull is carrying, by trigger and by add-on index. Set per frame.
local mods = {}
-- Whether the fan is declined, which Q toggles in flight.
local multi_off = false
-- The rung this hull's triggers are on, which the mark carries as a colour.
local level = 1
-- What is in hand, by slot, which is what decides whether a charge gets a row
-- at all. The list handed to the interface is built from it below.
local in_hand = {repel = 2, burst = 1}

local sim = {
    ship_count = function() return 1 end,
    ship_x = function() return 400 end,
    ship_y = function() return 400 end,
    ship_heading = function() return 0 end,
    ship_alive = function() return 1 end,
    ship_team = function() return 1 end,
    ship_class = function() return 0 end,
    ship_energy = function() return 100 end,
    ship_max_energy = function() return 100 end,
    ship_kills = function() return 0 end,
    ship_deaths = function() return 0 end,
    ship_points = function() return 0 end,
    ship_bounty = function() return 40 end,
    ship_up = function() return 0 end,
    ship_level = function() return level end,
    ship_charge = function() return 2 end,
    ship_mod = function(_, t, m) return (mods[t] and mods[t][m]) or 0 end,
    ship_multi_off = function() return multi_off end,
    -- The zone's own shrapnel ladder, which is what the mark counts ticks
    -- off. The baseline's numbers: a rung buys a pattern, and the pattern
    -- says how many fragments. Nothing here doubles 4, 8, 16 by arithmetic,
    -- because the drawing must not either.
    shrap_count = function(n) return ({2, 4, 8})[math.min(n, 3)] or 0 end,
    charge_max = function() return 3 end,
    has_trigger = function() return true end,
    trigger_rate = function() return 1 end,
    tick = function() return 1000 end,
    weapon_count = function() return 0 end,
    prize_count = function() return 0 end,
    prize_at = function() return 0, 0, 0 end,
    flag_count = function() return 0 end,
    flag_at = function() return 0, 0, 255 end,
    map_coarse = function() return nil end,
    TRIG_GUN = 0,
    TRIG_BOMB = 1,
    BTN_FIRE = 1,
}
_G.sim = sim

local state = {text = {}, n = 0, version = 0}
package.loaded["arena.state"] = state
package.loaded["arena.touch"] = {
    layout = function() return {charge = {}} end,
    used = false,
}
package.loaded["arena.world"] = {
    build_overview = function() end,
    forget_overview = function() end,
    -- A field, not a call: ui.lua reads world.overview directly.
    overview = {grid = 0, n = 0, rect = {}},
    radar_tiles = {},
    radar_safe = {},
    radar_doors = {},
}

local ui = require("arena.ui")
local pal = require("arena.palette")

-- --- the harness -----------------------------------------------------------

local W, H = 1280, 800
local SCALE = 2      -- the density scale a retina window hands the interface

local function frame(px, py)
    shapes = {}
    ink = {}
    state.n = 0
    ui.begin(layer, W, H, SCALE, false)
    ui.hud({
        point_x = px, point_y = py,
        me = 0,
        class_names = {"Apex", "Wedge", "Chord", "Anvil", "Facet", "Cipher",
                       "Lattice", "Spire"},
        menu_open = false,
        pilots = {[0] = {name = "you", label = "human"}},
        teams = {},
        feed = {},
        hurt = 0,
        charges = {{name = "repel", short = "RPL",
                    count = in_hand.repel or 0, max = 3},
                   {name = "burst", short = "BST",
                    count = in_hand.burst or 0, max = 3}},
        cam_x = 400, cam_y = 400,
        half_w = 640, half_h = 400,
        banner = "",
        lag = 4,
        stats = {lag = 4, lead = 2, err = 1.5, err_max = 9.0, rewind = 3,
                 snaps = 120, rx = 0, tx = 0},
        zone = "chaos",
        fps = 60, frame_ms = 16.7, rx_rate = 0, tx_rate = 0,
    })
    ui.finish()
    return shapes
end

-- Where a row of the stack is, taken from the hover zones the interface
-- publishes rather than from this file's idea of the layout. Probed the way a
-- pointer probes: the box is the extent of the points that answer to the row.
local function row_box(key)
    local x0, y0, x1, y1
    for px = 0, 320, 2 do
        for py = H - 320, H, 2 do
            if ui.help_at(px, py) == key then
                x0 = math.min(x0 or px, px)
                x1 = math.max(x1 or px, px)
                y0 = math.min(y0 or py, py)
                y1 = math.max(y1 or py, py)
            end
        end
    end
    if not x0 then return nil end
    -- Back into the layer's coordinates, which is what `shapes` holds.
    return {x0 = x0, x1 = x1, y0 = H - y1, y1 = H - y0}
end

-- Where the counting column starts, read off the drawing rather than worked
-- out here. The stack is measured in a scale of its own that backs off on a
-- short window, so a constant in this file is a constant that goes stale the
-- first time the block is resized and takes the checks below with it.
--
-- Read off a charge row, because a weapon row has nothing in that column any
-- more: the level was three rungs in the team colour there, and the round's
-- own hue says it now. What is left counting is the pips, which are the
-- leftmost thing in the charge colour on a row that has any.
local function column_at(b)
    local at = nil
    for _, s in ipairs(shapes) do
        local mid = (s.y0 + s.y1) / 2
        if mid > b.y0 and mid < b.y1 and s.tint
            and s.tint[1] == pal.CHARGE_COL[1]
            and s.tint[2] == pal.CHARGE_COL[2]
            and s.tint[3] == pal.CHARGE_COL[3] then
            at = math.min(at or s.x0, s.x0)
        end
    end
    return at
end

-- And cached, since finding it costs a probe of the whole corner and the
-- answer does not move: the column is a function of the block's scale, and
-- the scale is a function of how many rows there are.
local column_cache = nil
local function column()
    if not column_cache then
        local b = row_box("charge:repel")
        column_cache = b and column_at(b) or nil
    end
    return column_cache
end

-- What the mark cell holds: everything drawn left of that column, at this
-- row's height.
local function cell(b)
    local edge = column() or (W / 2)
    local out = {}
    for _, s in ipairs(shapes) do
        local mid = (s.y0 + s.y1) / 2
        if mid > b.y0 and mid < b.y1 and s.x0 < edge then
            out[#out + 1] = s
        end
    end
    return out
end

local function extent(list)
    local x0, y0, x1, y1
    for _, s in ipairs(list) do
        x0 = math.min(x0 or s.x0, s.x0)
        y0 = math.min(y0 or s.y0, s.y0)
        x1 = math.max(x1 or s.x1, s.x1)
        y1 = math.max(y1 or s.y1, s.y1)
    end
    return x0, y0, x1, y1
end

-- --- one mark a trigger ----------------------------------------------------

mods = {}
frame()
local gun, bomb = row_box("gun"), row_box("bomb")
check("the gun row publishes itself to the pointer", gun ~= nil)
check("the bomb row publishes itself to the pointer", bomb ~= nil)

-- The two rows are the same height and do not overlap, which is what makes
-- "inside its row" a question with an answer.
if gun and bomb then
    check("the two weapon rows are the same height",
          math.abs((gun.y1 - gun.y0) - (bomb.y1 - bomb.y0)) <= 2,
          string.format("%.0f and %.0f", gun.y1 - gun.y0, bomb.y1 - bomb.y0))
    check("the two weapon rows do not overlap",
          gun.y0 >= bomb.y1 - 2 or bomb.y0 >= gun.y1 - 2,
          string.format("gun %.0f..%.0f bomb %.0f..%.0f",
                        gun.y0, gun.y1, bomb.y0, bomb.y1))
end

-- --- every add-on draws ----------------------------------------------------

-- A green that landed on a trigger has to change that trigger's mark, or the
-- corner is telling a player they picked up nothing. Measured against the bare
-- mark: what an add-on drew is what is there that was not there before.
local bare = {}
if bomb then bare = cell(bomb) end
local bare_n = #bare

for i = 1, #pal.MODS do
    for _, rungs in ipairs({1, 3}) do
        mods = {[1] = {[i - 1] = rungs}}
        frame()
        local b = row_box("bomb")
        local drew = b and #cell(b) or 0
        check(string.format("%s at %d rung(s) draws on the bomb",
                            pal.MODS[i].name, rungs),
              drew > bare_n,
              string.format("%d shapes, bare is %d", drew, bare_n))
    end
end

-- Shrapnel counts the zone's fragments rather than a ramp of its own.
--
-- Every other add-on's magnitude is a number the zone scales with `mod_step`.
-- Shrapnel's is a whole pattern per rung, so the only way for a drawing to
-- know how many fragments a rung buys is to ask, and the drawing that worked
-- it out instead said six, eight and ten against a baseline that throws two,
-- four and eight. Driven off a ladder this file makes up, so what is measured
-- is that the mark follows the zone rather than that it agrees with one.
for _, ladder in ipairs({{2, 4, 8}, {3, 5, 31}}) do
    sim.shrap_count = function(n) return ladder[math.min(n, 3)] or 0 end
    for rungs = 1, 3 do
        mods = {[1] = {[3] = rungs}}
        frame()
        local b = row_box("bomb")
        local drew = b and (#cell(b) - bare_n) or 0
        check(string.format("%d rung(s) of shrapnel draws %d fragments",
                            rungs, ladder[rungs]),
              drew == ladder[rungs],
              string.format("%d ticks for %d fragments", drew, ladder[rungs]))
    end
end
-- A rung the zone put no pattern on throws nothing, and the mark says so.
sim.shrap_count = function() return 0 end
mods = {[1] = {[3] = 2}}
frame()
check("a rung with no pattern behind it draws no fragments",
      #cell(row_box("bomb")) == bare_n,
      "ticks for fragments the zone does not throw")
sim.shrap_count = function(n) return ({2, 4, 8})[math.min(n, 3)] or 0 end

-- And on the gun, which wears the same six against a different round.
mods = {}
frame()
local bare_gun = gun and #cell(row_box("gun")) or 0
for i = 1, #pal.MODS do
    mods = {[0] = {[i - 1] = 2}}
    frame()
    local g = row_box("gun")
    check(pal.MODS[i].name .. " draws on the gun",
          g and #cell(g) > bare_gun,
          string.format("%d shapes, bare is %d", g and #cell(g) or 0, bare_gun))
end

-- --- depth is drawn, not spelled -------------------------------------------

-- The rungs used to be pips beside the symbol. They are in the shape now, so a
-- deeper add-on has to look different from a shallow one or the count is gone
-- from the interface rather than moved into it.
local function measure(key)
    local c = cell(row_box(key))
    local x0, y0, x1, y1 = extent(c)
    return #c, x0 or 0, y0 or 0, x1 or 0, y1 or 0
end

-- Bouncing is the exception, on both triggers: a ring or no ring, at any
-- depth. That is a decision rather than an oversight. How many walls deep it
-- runs is for the ladder beside the row to carry, and a ring three points
-- across cannot hold a count as well as an identity. The gun's fan goes the
-- same way, since the alternative is answering "how many barrels" with a
-- count of strokes. Pinned here rather than left out, so that putting depth
-- back into either shape reads as contradicting a decision instead of passing
-- quietly.
local FIXED = {[0] = {[0] = true, [1] = true}, [1] = {[1] = true}}

for _, t in ipairs({{0, "gun"}, {1, "bomb"}}) do
    for i = 1, #pal.MODS do
        mods = {[t[1]] = {[i - 1] = 1}}
        frame()
        local n1, a0, b0, a1, b1 = measure(t[2])
        mods = {[t[1]] = {[i - 1] = 3}}
        frame()
        local n3, c0, d0, c1, d1 = measure(t[2])
        -- Either more of it is drawn or it is drawn bigger. Which of the two
        -- is the add-on's business: fragments count up, a fuse reaches out.
        local moved = math.abs(c0 - a0) + math.abs(d0 - b0)
            + math.abs(c1 - a1) + math.abs(d1 - b1)
        if FIXED[t[1]][i - 1] then
            check(string.format("%s on the %s draws the same at any depth",
                                pal.MODS[i].name, t[2]),
                  n3 == n1 and moved < 0.01,
                  string.format("%d against %d shapes, extent moved %.2f",
                                n1, n3, moved))
        else
            check(string.format("a third rung of %s on the %s reads differently",
                                pal.MODS[i].name, t[2]),
                  n3 ~= n1 or moved > 0.5,
                  string.format("%d shapes either way, extent moved %.2f",
                                n1, moved))
        end
    end
end

-- --- the mark stays in its row ---------------------------------------------

-- Every combination the six add-ons can make, at full depth, is a hull no zone
-- in the catalog hands out and a layout this has to survive anyway: the room
-- around the round is shared out ahead of the drawing so that it does.
local worst_over, worst_case = 0, nil
for bits = 0, 63 do
    local set = {}
    local named = {}
    for i = 1, 6 do
        if math.floor(bits / 2 ^ (i - 1)) % 2 == 1 then
            set[i - 1] = 3
            named[#named + 1] = pal.MODS[i].name
        end
    end
    mods = {[0] = set, [1] = set}
    frame()
    for _, key in ipairs({"gun", "bomb"}) do
        local b = row_box(key)
        if b then
            local c = cell(b)
            local _, y0, _, y1 = extent(c)
            -- The row's own band, and a mark that leaves it is drawing over
            -- whatever the stack put above or below it.
            local over = math.max((b.y0 - (y0 or b.y0)), ((y1 or b.y1) - b.y1))
            if over > worst_over then
                worst_over = over
                worst_case = key .. " with " .. table.concat(named, "+")
            end
        end
    end
end
check("no loadout pushes a mark out of its own row", worst_over <= 2,
      string.format("%.1f points over on %s", worst_over,
                    tostring(worst_case)))

-- The counting column is the other edge. A mark that reaches it is drawn over
-- the pips the rows below it count in.
mods = {[0] = {[0] = 3, [1] = 3, [2] = 3, [3] = 3, [4] = 3, [5] = 3},
        [1] = {[0] = 3, [1] = 3, [2] = 3, [3] = 3, [4] = 3, [5] = 3}}
frame()
local reach = 0
for _, key in ipairs({"gun", "bomb"}) do
    local b = row_box(key)
    if b then
        local _, _, x1 = extent(cell(b))
        reach = math.max(reach, x1 or 0)
    end
end
local col_x = column() or 0
check("a fully loaded mark stops short of the counting column",
      reach > 0 and col_x > 0 and reach < col_x,
      string.format("reached %.0f, column is at %.0f", reach, col_x))

-- --- the row grows with what it carries ------------------------------------

-- The hover zone is the row, and pointing at a fragment thrown clear of the
-- bomb is still pointing at the bomb.
mods = {}
frame()
local narrow = row_box("bomb")
mods = {[1] = {[2] = 1, [3] = 3}}    -- proximity and shrapnel, a real bomber
frame()
local loaded = row_box("bomb")
check("a loaded row is at least as wide as a bare one",
      narrow and loaded and loaded.x1 >= narrow.x1 - 1,
      string.format("%.0f loaded against %.0f bare",
                    loaded and loaded.x1 or -1, narrow and narrow.x1 or -1))
local _, _, marks_to = extent(cell(loaded))
check("and the row covers everything its mark drew",
      marks_to and loaded and marks_to <= loaded.x1 + 2,
      string.format("mark reaches %.0f, row ends at %.0f",
                    marks_to or -1, loaded and loaded.x1 or -1))

-- --- the words are still available -----------------------------------------

-- A shape drawn onto a mark is learnable exactly once, by being told what it
-- is. Held H is where that happens now, and it has to name what the hull is
-- actually carrying rather than the add-ons weapons have in general, or a
-- player who just picked up their first proximity is looking at a new ring
-- with nothing on the screen connecting the two.
-- Upper cased, because the interface sets what it says in capitals and what
-- these checks are about is which words it says.
--
-- Joined by spaces rather than by newlines, because a hover sentence is
-- wrapped to whatever room is left beside the block and the block's width is
-- what a loadout decides. Matching across the wrap made a phrase check fail
-- for the reason a phrase check exists to ignore: the corner got narrower, the
-- label got wider, and "carrying prox" broke across two lines.
local function said()
    local out = {}
    for k = 1, state.n do out[#out + 1] = string.upper(state.text[k].s) end
    return table.concat(out, " ")
end

-- A point inside a row, asked of the interface rather than worked out here.
-- The zones come from the frame just drawn, so this runs between two frames:
-- one to publish them, one with the pointer resting where they said.
local function point_in(key)
    for py = H - 320, H, 2 do
        for px = 0, 320, 2 do
            if ui.help_at(px, py) == key then return px, py end
        end
    end
    return nil
end

-- Matched against the whole phrase rather than the words in it, because the
-- bomb's own card already contains "shrapnel" and "proximity" as things a
-- bomb can have. What is under test is the sentence about this hull.
mods = {[1] = {[2] = 1, [3] = 3}}
frame()
frame(point_in("bomb"))
local words = said()
check("pointing at the bomb names the add-ons it is carrying",
      words:find("CARRYING PROX, SHRAPNEL X3.", 1, true) ~= nil, words)

mods = {[0] = {[0] = 2}}
frame()
frame(point_in("gun"))
check("and names the gun's separately",
      said():find("CARRYING MULTI X2.", 1, true) ~= nil, said())

mods = {}
frame()
frame(point_in("gun"))
check("a bare weapon is not described as carrying anything",
      said():find("CARRYING", 1, true) == nil, said())

-- --- the block is sized to the window it is in ----------------------------

-- The stack draws larger than the rest of the interface, because it is read
-- from the middle of a fight rather than at rest. That is a good reason on a
-- desktop and a bad one on a phone held sideways, where five rows at full
-- size are most of the height, so the scale backs off against the room there
-- is. Neither end of that is visible without measuring it.
local function block(w, h, dens, touching)
    shapes = {}
    ink = {}
    state.n = 0
    ui.help = false
    ui.begin(layer, w, h, dens, touching or false)
    ui.hud({
        me = 0, class_names = {"Apex"}, menu_open = false,
        pilots = {[0] = {name = "you", label = "human"}},
        teams = {}, feed = {}, hurt = 0,
        charges = {{name = "repel", short = "RPL",
                    count = in_hand.repel or 0, max = 3},
                   {name = "burst", short = "BST",
                    count = in_hand.burst or 0, max = 3}},
        cam_x = 400, cam_y = 400, half_w = w / 2, half_h = h / 2,
        banner = "", lag = 4,
        stats = {lag = 4, lead = 2, err = 1, err_max = 9, rewind = 0,
                 snaps = 1, rx = 0, tx = 0},
        zone = "chaos", fps = 60, frame_ms = 16, rx_rate = 0, tx_rate = 0,
    })
    ui.finish()
    -- Top and bottom of the whole block, from the rows it published.
    local top, bot
    for _, key in ipairs({"gun", "bomb", "bounty"}) do
        for py = 0, h, 2 do
            if ui.help_at(4 + 14 * dens, py) == key then
                top = math.min(top or py, py)
                bot = math.max(bot or py, py)
            end
        end
    end
    if not top then return nil end
    -- The heaviest line anywhere in the block, which is what says whether the
    -- strokes grew with it or the shapes grew and left the lines behind.
    local heaviest = 0
    for _, sh in ipairs(shapes) do
        local mid = (sh.y0 + sh.y1) / 2
        if sh.w and h - mid > top - 4 and h - mid < bot + 4
            and sh.x0 < 200 * dens then
            heaviest = math.max(heaviest, sh.w)
        end
    end
    return {top = top, bot = bot, tall = bot - top, pts = (bot - top) / dens,
            ink = heaviest / dens}
end

mods = {[0] = {[0] = 1}, [1] = {[2] = 1, [3] = 2}}
for _, shape in ipairs({{1280, 800, 1}, {1280, 800, 2}, {2560, 1440, 2},
                        {844, 390, 2}, {390, 844, 2}, {1600, 900, 1}}) do
    local w, h, dens = shape[1], shape[2], shape[3]
    local b = block(w, h, dens)
    local at = string.format("%dx%d at %dx", w, h, dens)
    check("the stack fits its window: " .. at,
          b ~= nil and b.bot <= h and b.top >= 0,
          b and string.format("%.0f..%.0f in %d", b.top, b.bot, h) or "no rows")
    -- Either it stayed inside the share it is allowed, or the back-off has
    -- already run out and put it at the size it has always been. The floor is
    -- deliberate: this change makes the stack bigger, and a window too short
    -- for five rows at the old size was too short before it and is not this
    -- change's to fix. On a real phone the pad carries the charges and the
    -- stack is three rows, which is where that case actually lives.
    if b then
        local base = math.abs(b.pts - 5 * 22) < 2
        check("and takes a fair share of it: " .. at,
              b.tall <= h * 0.42 or base,
              string.format("%.0f of %d px, %.0f points, base %s",
                            b.tall, h, b.pts, tostring(base)))
        check("and never draws smaller than it always has: " .. at,
              b.pts >= 5 * 22 - 2,
              string.format("%.0f points", b.pts))
    end
end

-- A window with room draws the block bigger than the metric the rest of the
-- interface uses. Without this, setting the scale back to 1 reverts the whole
-- thing and every check above still passes: they all say "no larger than", and
-- none of them says "larger than".
local roomy = block(2560, 1440, 2)
check("a window with room draws the stack bigger than the base",
      roomy and roomy.pts > 5 * 22 * 1.2,
      roomy and string.format("%.0f points against a base of %d",
                              roomy.pts, 5 * 22) or "no rows")

-- And the lines grew with it. Every width in this corner used to be a
-- multiple of the density scale, so growing the block would have grown the
-- shapes and left the strokes where they were: the same drawing at twice the
-- size wearing hairlines.
local tight = block(1280, 400, 1)
if roomy and tight then
    check("and draws them with heavier lines, not the same hairline",
          roomy.ink > tight.ink * 1.15,
          string.format("%.2f against %.2f points of line",
                        roomy.ink, tight.ink))
end

-- --- the rows line up ------------------------------------------------------

-- Every mark stands its subject on one axis: the head of each round, the hub
-- of the repel's rings and the burst's spokes, the middle of the green. That
-- is not the same as centring the drawings, because a bolt is a long streak
-- with a small head and a bomb a short one with a big head, so centring the
-- boxes would put the round in a different place on each row. What the eye
-- lands on is the round.
--
-- Found as the darkest, densest thing on the row: the head of a weapon mark
-- is a filled disc and the radial glyphs are drawn about their own centre, so
-- the middle of the tightest shape on each row is its subject.
-- What lines up down the stack is the drawing, not the round inside it.
--
-- Neither weapon mark is symmetric about its own round: a gun's lines leave
-- from a muzzle well behind the dot and a bomb trails, so standing the round
-- on the axis hangs the mark off to the left of every other row. The charge
-- glyphs and the green are drawn about their own middles, so for them the two
-- are the same thing and this is one rule rather than two.
--
-- Measured bare, because that is what the bias is computed against: add-ons
-- hang off the right, and a bomb that picked up shrapnel should not slide left
-- out of the column it shares with four other rows.
local function mark_box(key, edge)
    local b = row_box(key)
    if not b then return nil end
    local sum, wsum = 0, 0
    for _, e in ipairs(ink) do
        if e.y > b.y0 and e.y < b.y1 and e.x < edge then
            sum = sum + e.w
            wsum = wsum + e.w * e.x
        end
    end
    if sum == 0 then return nil end
    return wsum / sum
end

local ROWS = {"gun", "bomb", "charge:repel", "charge:burst", "bounty"}

mods = {}
frame()
local counting = column()
local axis = {}
for _, key in ipairs(ROWS) do
    axis[key] = mark_box(key, counting or W)
end
local lo, hi
for _, at in pairs(axis) do
    if at then lo = math.min(lo or at, at) hi = math.max(hi or at, at) end
end
local spread = (hi or 0) - (lo or 0)
check("every row centres its mark on one axis", spread <= 2 * SCALE,
      string.format("%.1f px of spread across %d rows", spread, #ROWS))

-- And a loadout does not drag a row out of that column. The gun's fan opens
-- inside the span its bare line already occupied and the bomb's add-ons ring
-- a head that has not moved, so both should sit where they sat.
mods = {[0] = {[0] = 3, [1] = 3}, [1] = {[2] = 1, [3] = 3}}
frame()
local worst_drift, drifter = 0, nil
for _, key in ipairs({"gun", "bomb"}) do
    local now = mark_box(key, counting or W)
    if now and axis[key] then
        local d = math.abs(now - axis[key])
        if d > worst_drift then worst_drift, drifter = d, key end
    end
end
check("and a loadout does not drag the row out of it",
      worst_drift <= 6 * SCALE,
      string.format("%.1f px on the %s", worst_drift, tostring(drifter)))

-- And the counting column sits in close, not out where a row of separate
-- add-on symbols used to need it.
mods = {}
frame()
local gap = (counting or 0) - (axis.gun or 0)
check("the counting column sits close to the marks",
      gap > 8 * SCALE and gap < 30 * SCALE,
      string.format("%.0f px from the subject to the column", gap))

-- --- the level is a colour, not a ladder -----------------------------------

-- A weapon row was a mark and three cyan rungs beside it saying which rung of
-- the ladder the trigger was on. The round carries that now, in the hue it
-- will be when it leaves the gun, on the one ramp every round in the game is
-- drawn from. Two answers to one question, and the second one in the team's
-- colour, which a weapon's level has nothing to do with.
--
-- Measured as "no team colour on a weapon row" rather than "no rects": the
-- fault would be somebody putting the count back some other way, and the tell
-- is the colour it was counted in.
for _, lvl in ipairs({0, 1, 3}) do
    level = lvl
    mods = {}
    frame()
    for _, key in ipairs({"gun", "bomb"}) do
        local b = row_box(key)
        local n = 0
        if b then
            for _, sh in ipairs(shapes) do
                local mid = (sh.y0 + sh.y1) / 2
                local c = sh.col or sh.tint
                if mid > b.y0 and mid < b.y1 and c
                    and c[1] == pal.FRIEND[1] and c[2] == pal.FRIEND[2]
                    and c[3] == pal.FRIEND[3] then
                    n = n + 1
                end
            end
        end
        check(string.format("the %s row at level %d draws no ladder", key, lvl),
              n == 0, n .. " shapes in the team colour beside the mark")
    end
end
level = 1

-- --- a barrel you are not firing ------------------------------------------

-- Q declines the fan. The two extra barrels stay on the mark, dimmed, because
-- a fan that quietly stopped fanning with nothing on screen to say so is a
-- weapon that looks broken. What they stop being is rounds.
--
-- That distinction is the whole of this: bounce rings the rounds a gun puts
-- out, and it was ringing all three dots whether or not two of them were
-- firing. Nothing here measured it, which is how it shipped.
local function rings_on_gun()
    mods = {[0] = {[0] = 2, [1] = 2}}
    frame()
    local b = row_box("gun")
    if not b then return -1 end
    local n = 0
    for _, sh in ipairs(shapes) do
        local mid = (sh.y0 + sh.y1) / 2
        -- A bounce ring is the widest thing drawn on a dot, and it is drawn
        -- as a ring: count the shapes whose box is square and larger than the
        -- dot inside it.
        if mid > b.y0 and mid < b.y1 then
            local w, h = sh.x1 - sh.x0, sh.y1 - sh.y0
            if sh.w and math.abs(w - h) < 1 and w > 6 * SCALE then
                n = n + 1
            end
        end
    end
    return n
end

multi_off = false
local firing = rings_on_gun()
multi_off = true
local declined = rings_on_gun()
multi_off = false

check("a fanned gun rings all three of its rounds", firing == 3,
      tostring(firing) .. " rings")
check("and a declined fan rings only the one it fires", declined == 1,
      tostring(declined) .. " rings")
check("the barrels themselves stay on the mark when declined",
      (function()
          multi_off = true
          mods = {[0] = {[0] = 2}}
          frame()
          local n = #cell(row_box("gun"))
          multi_off = false
          mods = {[0] = {}}
          frame()
          local plain = #cell(row_box("gun"))
          return n > plain
      end)(), "a declined fan should still be drawn")

-- --- the fan is the round, not a thing hung on it -------------------------

-- Every other add-on is a decoration, so it is drawn in the round's hue run
-- hot: what a green added reads as part of the round rather than as a separate
-- object beside it. Multifire decorates nothing. Its extra barrels fire the
-- same round out of the same muzzle on the same spec, which is why world.lua
-- gives all three bullets one colour in flight. Drawn hot with the rest, the
-- corner said the middle bullet was a different weapon from the two either
-- side and disagreed with the arena about the one fact this ramp carries.
local function dots_on_gun()
    local b = row_box("gun")
    local out = {}
    if not b then return out end
    for _, sh in ipairs(shapes) do
        local mid = (sh.y0 + sh.y1) / 2
        if sh.kind == "disc" and mid > b.y0 and mid < b.y1 then
            out[#out + 1] = hue(sh.tint)
        end
    end
    return out
end

local function distinct(list)
    local seen, n = {}, 0
    for _, v in ipairs(list) do
        if not seen[v] then seen[v] = true n = n + 1 end
    end
    return n
end

mods = {[0] = {}}
frame()
local plain_dot = dots_on_gun()[1]
mods = {[0] = {[0] = 2}}
frame()
local fanned = dots_on_gun()
check("a fan draws three rounds", #fanned == 3, #fanned .. " dots")
check("and all three are the round the gun fires", distinct(fanned) == 1
      and fanned[1] == plain_dot,
      table.concat(fanned, "  vs plain ") .. " " .. tostring(plain_dot))

-- The one time they really are not the round you are firing.
multi_off = true
frame()
local off_dots = dots_on_gun()
multi_off = false
check("a declined fan tells the two apart", distinct(off_dots) == 2,
      distinct(off_dots) .. " colours across " .. #off_dots .. " dots")

-- The bomb's fan is the same argument: rounds leaving together, in the colour
-- of the round. Measured on the strokes, since a bomb's fan has no dots.
local function bomb_hues()
    local b = row_box("bomb")
    local out = {}
    if not b then return out end
    for _, sh in ipairs(shapes) do
        local mid = (sh.y0 + sh.y1) / 2
        if sh.tint and sh.kind ~= "disc" and mid > b.y0 and mid < b.y1 then
            out[hue(sh.tint)] = true
        end
    end
    return out
end
mods = {[1] = {[0] = 1}}
frame()
local bomb_fan = bomb_hues()
mods = {[1] = {}}
frame()
local bare_bomb = nil
for _, sh in ipairs(shapes) do
    local b = row_box("bomb")
    local mid = (sh.y0 + sh.y1) / 2
    if b and sh.kind == "disc" and mid > b.y0 and mid < b.y1 then
        bare_bomb = hue(sh.tint)
    end
end
check("a bomb's fan is drawn in the round's own colour",
      bare_bomb ~= nil and bomb_fan[bare_bomb] == true,
      "fan hues: " .. (next(bomb_fan) or "none") .. ", round: " ..
      tostring(bare_bomb))

-- --- a charge row is a charge you have -------------------------------------

-- The stack showed a row for every slot the hull could carry and drew the
-- empties as unlit pips, on the argument the stat panel makes for showing
-- upgrades you do not have. The stat panel is a thing you stop and read. This
-- corner is read in a fight, where the only question is what a key would spend
-- if you pressed it, and a row that answers "nothing" is a row costing height
-- the rows above it could have had.
local function rows_drawn()
    local n = 0
    for _, key in ipairs({"gun", "bomb", "charge:repel", "charge:burst",
                          "bounty"}) do
        if row_box(key) then n = n + 1 end
    end
    return n
end

mods = {}
in_hand = {repel = 2, burst = 1}
frame()
local full_rows = rows_drawn()
local full_top = row_box("gun")
local full_foot = row_box("bounty")
check("both charges in hand draw both rows", full_rows == 5,
      full_rows .. " rows")

in_hand = {repel = 2}
frame()
check("a spent slot draws no row", rows_drawn() == 4 and not row_box("charge:burst"),
      rows_drawn() .. " rows with one charge in hand")

in_hand = {}
frame()
check("and an empty hand draws neither", rows_drawn() == 3
      and not row_box("charge:repel") and not row_box("charge:burst"),
      rows_drawn() .. " rows with an empty hand")

-- And the block shrinks rather than leaving the gap. It hangs off the bottom
-- of the window, so what a dropped row costs comes off the top: the bounty
-- stays where it was and everything above it comes down.
local short_top = row_box("gun")
local short_foot = row_box("bounty")
-- Within the probe's own step, which walks the corner two pixels at a time.
check("the stack keeps its footing", full_foot and short_foot
      and math.abs(short_foot.y0 - full_foot.y0) <= 4,
      string.format("bottom at %.0f against %.0f",
                    short_foot and short_foot.y0 or -1,
                    full_foot and full_foot.y0 or -1))
check("and shrinks by what it dropped",
      full_top and short_top and short_top.y1 < full_top.y1,
      string.format("top at %.0f against %.0f",
                    short_top and short_top.y1 or -1,
                    full_top and full_top.y1 or -1))
in_hand = {repel = 2, burst = 1}

-- --- and none of it on glass ------------------------------------------------

-- A touchscreen draws no corner stack at all. The pads carry the weapons and
-- the charges, and the last thing left here was the bounty, which is a number
-- you read between fights rather than during one and which the scoreboard has.
-- One figure in the corner of a phone is furniture for the sake of the corner
-- not being empty, and that corner is where a thumb rests.
--
-- Measured by asking the interface what answers a point rather than by
-- counting shapes, because the whole bottom left is drawn over by the stick
-- and its resting mark, which this harness does not draw and a phone does.
do
    in_hand = {repel = 2, burst = 1}
    mods = {[0] = {[0] = 2}, [1] = {[2] = 1, [3] = 2}}
    block(844 * 2, 390 * 2, 2, true)
    local answered = {}
    for py = 0, 780, 6 do
        for px = 0, 400, 6 do
            local k = ui.help_at(px, py)
            if k then answered[k] = true end
        end
    end
    local left = {}
    for _, key in ipairs({"gun", "bomb", "charge:repel", "charge:burst",
                          "bounty"}) do
        if answered[key] then left[#left + 1] = key end
    end
    check("a touchscreen draws no corner stack", #left == 0,
          table.concat(left, ", ") .. " still in the corner")
end

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
