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
local function box(x0, y0, x1, y1)
    if x1 < x0 then x0, x1 = x1, x0 end
    if y1 < y0 then y0, y1 = y1, y0 end
    shapes[#shapes + 1] = {x0 = x0, y0 = y0, x1 = x1, y1 = y1}
end

local layer = {}
function layer:seg(x1, y1, x2, y2, w) box(x1 - w, y1 - w, x2 + w, y2 + w) end
function layer:seg_fade(x1, y1, x2, y2, w1, w2)
    local w = math.max(w1, w2)
    box(x1 - w, y1 - w, x2 + w, y2 + w)
end
function layer:disc(x, y, r) box(x - r, y - r, x + r, y + r) end
function layer:halo(x, y, r) box(x - r, y - r, x + r, y + r) end
function layer:ring(x, y, r, w) box(x - r - w, y - r - w, x + r + w, y + r + w) end
function layer:ring_fade(x, y, r, w)
    box(x - r - w, y - r - w, x + r + w, y + r + w)
end
-- An arc is bounded by its own circle whichever way it opens, which is all
-- this needs: the question is whether a mark stayed inside a row, and a
-- generous box can only fail a mark that passed.
function layer:arc(x, y, r, _, _, w) box(x - r - w, y - r - w, x + r + w, y + r + w) end
function layer:rect(x, y, w, h) box(x, y, x + w, y + h) end
function layer:frame(x, y, w, h) box(x, y, x + w, y + h) end
function layer:outline(pts, w)
    for i = 1, #pts - 1, 2 do
        box(pts[i] - w, pts[i + 1] - w, pts[i] + w, pts[i + 1] + w)
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
    ship_level = function() return 1 end,
    ship_charge = function() return 2 end,
    ship_mod = function(_, t, m) return (mods[t] and mods[t][m]) or 0 end,
    ship_multi_off = function() return false end,
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

local function frame(help)
    shapes = {}
    state.n = 0
    ui.help = help or false
    ui.begin(layer, W, H, SCALE, false)
    ui.hud({
        me = 0,
        class_names = {"Apex", "Wedge", "Chord", "Anvil", "Facet", "Cipher",
                       "Lattice", "Spire"},
        menu_open = false,
        pilots = {[0] = {name = "you", label = "human"}},
        teams = {},
        feed = {},
        hurt = 0,
        charges = {{name = "repel", short = "RPL", count = 2, max = 3},
                   {name = "burst", short = "BST", count = 1, max = 3}},
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

-- What the mark cell holds: everything drawn left of the counting column, at
-- this row's height. The ladder starts at `val`, so the cell ends there.
local LADDER_X = (14 + 48) * SCALE
local function cell(b)
    local out = {}
    for _, s in ipairs(shapes) do
        local mid = (s.y0 + s.y1) / 2
        if mid > b.y0 and mid < b.y1 and s.x0 < LADDER_X then
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
        check(string.format("a third rung of %s on the %s reads differently",
                            pal.MODS[i].name, t[2]),
              n3 ~= n1 or moved > 0.5,
              string.format("%d shapes either way, extent moved %.2f",
                            n1, moved))
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
-- the ladder that says what level the weapon is.
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
check("a fully loaded mark stops short of the counting column",
      reach > 0 and reach < LADDER_X,
      string.format("reached %.0f, column is at %d", reach, LADDER_X))

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
local function said()
    local out = {}
    for k = 1, state.n do out[#out + 1] = state.text[k].s end
    return table.concat(out, "\n")
end

-- Matched against the whole phrase rather than the words in it, because the
-- bomb's own card already contains "shrapnel" and "proximity" as things a
-- bomb can have. What is under test is the sentence about this hull.
mods = {[1] = {[2] = 1, [3] = 3}}
frame(true)
local words = said()
check("held H names the add-ons this bomb is carrying",
      words:find("Carrying prox, shrapnel x3.", 1, true) ~= nil, words)

mods = {[0] = {[0] = 2}}
frame(true)
check("and names the gun's separately",
      said():find("Carrying multi x2.", 1, true) ~= nil, said())

mods = {}
frame(true)
check("a bare weapon is not described as carrying anything",
      said():find("Carrying", 1, true) == nil, said())

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
