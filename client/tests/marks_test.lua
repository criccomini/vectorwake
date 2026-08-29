-- The two marks that say who is in a seat.
--
--     lua5.1 client/tests/marks_test.lua
--
-- A person wears pilot's wings. A machine wears a chip. The difference is the
-- message: the rooms list sets a count of people beside a count of machines,
-- and a fan of feathers against a square package is what answers that at a
-- glance, at a size where one feather is two pixels.
--
-- So this measures the two things that must stay apart and the two that must
-- stay together. Apart: the person's mark is line thrown outward from a
-- middle and the machine's is a closed package with legs, and neither borrows
-- the other's grammar. Together: one width and one center line, because a
-- pair that does not sit level reads as two unrelated pictures however
-- different their shapes are.
--
-- This measured a pair of helmets until the badges replaced them, and the
-- questions it asked survived the change even though every assertion under
-- them did. What it asked about the shells, that one turns and the other does
-- not, is asked here about the strokes: one mark's are struck outward and
-- capped round, the other's butt into a package they never cross.
--
-- Neither mark is public, and neither is exported for this: they are drawn
-- through the screens that use them, so what is measured is what a player is
-- shown.

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

-- --- the engine, recording what each mark is made of -----------------------

local W, H = 900, 600
local shapes = {}
local function put(kind, x0, y0, x1, y1)
    if x1 < x0 then x0, x1 = x1, x0 end
    if y1 < y0 then y0, y1 = y1, y0 end
    shapes[#shapes + 1] = {kind = kind, x0 = x0, y0 = H - y1, x1 = x1,
                           y1 = H - y0}
    return shapes[#shapes]
end

local layer = {}
-- The cap is kept, and it is not a detail. The feathers are capped round so
-- three of them read as three at eleven points; the chip's legs butt so that
-- eight of them do not lay a second line along all four sides of the package.
-- Both marks are a quad and a handful of segments, and the cap is one of the
-- few things in the record that tells their strokes apart.
function layer:seg(x1, y1, x2, y2, w, _, round)
    local s = put("seg", x1 - w / 2, y1 - w / 2, x2 + w / 2, y2 + w / 2)
    s.ax, s.ay, s.bx, s.by, s.w = x1, H - y1, x2, H - y2, w
    s.round = round and true or false
end
function layer:disc(x, y, r) put("disc", x - r, y - r, x + r, y + r) end
function layer:rect(x, y, w, h) put("rect", x, y, x + w, y + h) end
-- Closed is kept for the same kind of reason: the chip's package is a closed
-- run of four corners, and the one other four-point run on these screens, the
-- doorway in the Leave stop, is open.
function layer:outline(pts, w, _, closed)
    local o = {kind = "outline", pts = {}, w = w, closed = closed and true or false}
    for i = 1, #pts, 2 do
        o.pts[#o.pts + 1] = {pts[i], H - pts[i + 1]}
    end
    for _, pt in ipairs(o.pts) do
        o.x0 = math.min(o.x0 or pt[1], pt[1])
        o.x1 = math.max(o.x1 or pt[1], pt[1])
        o.y0 = math.min(o.y0 or pt[2], pt[2])
        o.y1 = math.max(o.y1 or pt[2], pt[2])
    end
    shapes[#shapes + 1] = o
end
-- Arcs keep their geometry, since a curve's center, radius and sweep are how
-- a round shape is told from a struck one.
function layer:arc(x, y, r, a0, a1)
    local s = put("arc", x - r, y - r, x + r, y + r)
    s.cx, s.cy, s.r, s.a0, s.a1 = x, H - y, r, a0, a1
end
-- The ship a wing is drawn around and the core of a chip are both one of
-- these, so the corners are kept rather than collapsed. A bounding box says
-- how big the body is and nothing about its shape, and the shape is the
-- difference between a craft and a gem.
function layer:quad(x1, y1, x2, y2, x3, y3, x4, y4)
    local xs, ys = {x1, x2, x3, x4}, {y1, y2, y3, y4}
    local s = put("quad", math.min(unpack(xs)), math.min(unpack(ys)),
                  math.max(unpack(xs)), math.max(unpack(ys)))
    s.top = H - math.max(unpack(ys))
    s.cx = (s.x0 + s.x1) / 2
    s.cy = (s.y0 + s.y1) / 2
    s.pts = {{x1, H - y1}, {x2, H - y2}, {x3, H - y3}, {x4, H - y4}}
end
function layer:fan(pts)
    local o = {kind = "fan", pts = {}}
    for i = 1, #pts, 2 do
        o.pts[#o.pts + 1] = {pts[i], H - pts[i + 1]}
    end
    for _, pt in ipairs(o.pts) do
        o.x0 = math.min(o.x0 or pt[1], pt[1])
        o.x1 = math.max(o.x1 or pt[1], pt[1])
        o.y0 = math.min(o.y0 or pt[2], pt[2])
        o.y1 = math.max(o.y1 or pt[2], pt[2])
    end
    shapes[#shapes + 1] = o
end
for _, n in ipairs({"flush", "frame", "halo", "reset", "ring",
                    "ring_fade", "seg_fade", "seg_flat", "skirt", "tri",
                    "tri_fade"}) do
    layer[n] = function() end
end

_G.sim = setmetatable({
    ship_count = function() return 2 end,
    ship_alive = function() return 1 end,
    ship_team = function(i) return i end,
    -- Nobody is riding anybody unless a test says so.
    ship_x = function(i) return 100 + i * 90 end,
    ship_y = function(i) return 100 + i * 60 end,
    ship_max_energy = function() return 100 end,
    ship_energy = function() return 100 end,
    has_trigger = function() return false end,
}, {__index = function() return function() return 0 end end})

local state = {text = {}, n = 0, version = 0}
package.loaded["arena.state"] = state
package.loaded["arena.touch"] = {layout = function() return {charge = {}} end,
                                 used = false}
package.loaded["arena.world"] = {
    build_overview = function() end, forget_overview = function() end,
    overview = {grid = 0, n = 0, rect = {}},
    radar_tiles = {}, radar_safe = {}, radar_doors = {},
    HULLS = setmetatable({}, {__index = function()
        return {poly = {0, 0, 1, 1, 2, 0}, mid = 0}
    end}),
}

local ui = require("arena.ui")

local function frame(f)
    shapes = {}
    state.n = 0
    ui.begin(layer, W, H, 1, false)
    f()
    ui.finish()
    return shapes
end

-- --- finding the marks -----------------------------------------------------

local function horizontal(sh)
    return sh.kind == "seg" and math.abs(sh.ay - sh.by) < 0.01
end
local function vertical(sh)
    return sh.kind == "seg" and math.abs(sh.ax - sh.bx) < 0.01
end

-- A pair of wings, found by its fan: a body with strokes thrown out of it,
-- capped round, three to a side and none of them level or upright.
--
-- The fan is what identifies it rather than the body, because a small solid
-- shape is the commonest thing on these screens and a run of six strokes
-- leaving one place is not drawn anywhere else. Three a side is asked for
-- exactly: the gaps between the feathers are the whole of what makes this
-- wings rather than a moustache, and a cut that loses one loses the mark.
--
-- The body is more than one piece, and the mark is found once all the same.
-- The ship is an arrowhead with an engine block hung under it, which is two
-- quads, and either of them sits close enough to the feathers to answer for
-- the whole mark. Two pieces that claim the same six feathers are one mark,
-- so the pieces are gathered by the feathers they share and measured
-- together: what a reader sees is the union of them and not whichever of
-- them was drawn first.
local function wings(list)
    local seen, out = {}, {}
    for _, q in ipairs(list) do
        if q.kind == "quad" then
            local left, right, span, lo, hi = 0, 0, 0, math.huge, -math.huge
            local reach = math.max(q.x1 - q.x0, q.y1 - q.y0) * 3
            local key = ""
            for i, sh in ipairs(list) do
                if sh.kind == "seg" and sh.round then
                    -- The end that starts at the body, whichever it is.
                    local near_x, near_y, far_x = sh.ax, sh.ay, sh.bx
                    if math.abs(sh.bx - q.cx) < math.abs(sh.ax - q.cx) then
                        near_x, near_y, far_x = sh.bx, sh.by, sh.ax
                    end
                    if math.abs(near_x - q.cx) < reach
                        and math.abs(near_y - q.cy) < reach
                        and not horizontal(sh) and not vertical(sh) then
                        if far_x < q.cx then left = left + 1 else right = right + 1 end
                        span = math.max(span, math.abs(far_x - q.cx))
                        lo = math.min(lo, sh.y0)
                        hi = math.max(hi, sh.y1)
                        key = key .. i .. ","
                    end
                end
            end
            if left == 3 and right == 3 then
                local m = seen[key]
                if not m then
                    m = {cx = q.cx, cy = q.cy, w = span * 2, h = hi - lo,
                         y0 = lo, y1 = hi, body = {}}
                    seen[key] = m
                    out[#out + 1] = m
                end
                m.body[#m.body + 1] = q
            end
        end
    end
    -- The body, as the reader sees it: every piece of it at once.
    for _, m in ipairs(out) do
        local bx0, bx1, by0, by1 = math.huge, -math.huge, math.huge, -math.huge
        for _, q in ipairs(m.body) do
            bx0, bx1 = math.min(bx0, q.x0), math.max(bx1, q.x1)
            by0, by1 = math.min(by0, q.y0), math.max(by1, q.y1)
        end
        m.bx0, m.bx1, m.by0, m.by1 = bx0, bx1, by0, by1
        m.body_w, m.body_h = bx1 - bx0, by1 - by0
        m.cx, m.cy = (bx0 + bx1) / 2, (by0 + by1) / 2
    end
    return out
end

-- How far down the body its widest point sits, as a share of its height. A
-- craft comes to a point at the nose and carries its wings behind that, so
-- the answer is well under the middle. A gem answers zero.
local function widest_below_middle(m)
    local best, at = 0, m.cy
    for _, q in ipairs(m.body) do
        for _, pt in ipairs(q.pts or {}) do
            local dx = math.abs(pt[1] - m.cx)
            if dx > best then best, at = dx, pt[2] end
        end
    end
    return (at - (m.by0 + m.by1) / 2) / m.body_h
end

-- A chip, found by its package: a closed run of exactly four points, every
-- one of them a corner of its own box, square to within a hundredth.
--
-- Corners are asked for and not merely four points, because the pip a ladder
-- draws for an empty rung is also a closed four-point run inside a square
-- box: it is a diamond, so its points sit at the middles of its sides and
-- none of them at a corner. The doorway in the Leave stop has four points
-- too and is open.
local function chips(list)
    local out = {}
    for _, sh in ipairs(list) do
        if sh.kind == "outline" and sh.closed and sh.pts and #sh.pts == 4 then
            local w, h = sh.x1 - sh.x0, sh.y1 - sh.y0
            local corners = 0
            for _, pt in ipairs(sh.pts) do
                if (math.abs(pt[1] - sh.x0) < 0.01 or math.abs(pt[1] - sh.x1) < 0.01)
                    and (math.abs(pt[2] - sh.y0) < 0.01
                         or math.abs(pt[2] - sh.y1) < 0.01) then
                    corners = corners + 1
                end
            end
            if corners == 4 and w > 0 and math.abs(w - h) < w * 0.01 then
                out[#out + 1] = {cx = (sh.x0 + sh.x1) / 2,
                                 cy = (sh.y0 + sh.y1) / 2,
                                 w = w, h = h, x0 = sh.x0, x1 = sh.x1,
                                 y0 = sh.y0, y1 = sh.y1, package = sh}
            end
        end
    end
    return out
end

-- The legs of a chip: the strokes that butt into its package from outside and
-- stop there. Counted by side, because what says silicon is a fringe on all
-- four rather than a pair of tabs on two.
local function legs(list, chip)
    local by = {left = 0, right = 0, top = 0, bottom = 0}
    local reach = 0
    for _, sh in ipairs(list) do
        if sh.kind == "seg" and not sh.round then
            local ax, ay, bx, by_ = sh.ax, sh.ay, sh.bx, sh.by
            local out_x = math.max(math.abs(ax - chip.cx), math.abs(bx - chip.cx))
            local out_y = math.max(math.abs(ay - chip.cy), math.abs(by_ - chip.cy))
            if out_x < chip.w * 1.2 and out_y < chip.h * 1.2 then
                if horizontal(sh) and out_x > chip.w / 2 then
                    if (ax + bx) / 2 < chip.cx then by.left = by.left + 1
                    else by.right = by.right + 1 end
                    reach = math.max(reach, out_x)
                elseif vertical(sh) and out_y > chip.h / 2 then
                    if (ay + by_) / 2 < chip.cy then by.top = by.top + 1
                    else by.bottom = by.bottom + 1 end
                    reach = math.max(reach, out_y)
                end
            end
        end
    end
    return by, reach
end

-- Everything drawn near a mark, so what sits beside its middle is caught too.
local function near(list, cx, cy, r)
    local out = {}
    for _, sh in ipairs(list) do
        if sh.x0 > cx - r * 1.6 and sh.x1 < cx + r * 1.6
            and sh.y1 > cy - r * 1.8 and sh.y0 < cy + r * 2.4 then
            out[#out + 1] = sh
        end
    end
    return out
end

-- The shipped row. Every stop draws its mark at the foot of the column, and
-- exactly one of them wears a badge, which is what this file counts.
local RAIL = {}
for i, n in ipairs({"zones", "ship", "upgrades", "settings"}) do
    RAIL[i] = {label = n, icon = n, index = i}
end

-- One room, and the panel that lists them open over an otherwise empty world.
-- That is where the pair still counts a population: the games list stopped
-- carrying counts when the menu became one column, and the corner's ROOM key
-- opens this instead of walking into the menu.
local function room_frame(open)
    ui.rooms_open = open
    local f = frame(function()
        ui.hud({me = 0, menu_open = false, pilots = {}, watchers = {},
                teams = {}, feed = {}, hurt = 0, charges = {},
                cam_x = 100, cam_y = 100, half_w = W / 2, half_h = H / 2,
                banner = "", zone = "chaos", room = 2,
                rooms = {{n = 1, players = 3, bots = 48}}})
    end)
    ui.rooms_open = false
    return f
end

-- What the panel put on the frame, rather than what is on the frame. Drawing
-- it both ways and taking the difference asks that question exactly, and it
-- keeps working however the chrome around the panel changes.
local function where(m)
    return string.format("%.1f", m.cx)
end

local function added(pick)
    local was = {}
    for _, m in ipairs(pick(room_frame(false))) do
        was[where(m)] = true
    end
    local out = {}
    for _, m in ipairs(pick(room_frame(true))) do
        if not was[where(m)] then out[#out + 1] = m end
    end
    return out
end

-- --- the person is a fan ---------------------------------------------------

-- The wings a room row counts its people with.
local rail_frame = room_frame(true)
local rail_only = added(wings)
check("a room row counts people with a pair of wings", #rail_only == 1,
      #rail_only .. " pairs the panel put up")

if rail_only[1] then
    local wing = rail_only[1]
    local parts = near(rail_frame, wing.cx, wing.cy, wing.w / 2)

    -- Wider than it is tall, and by a long way. This is the fact every
    -- caller lays out against: it is why the mark sits where it does beside a
    -- count, and why a pair of them would have to be stacked rather than set
    -- side by side.
    check("it lies wider than it stands", wing.w > wing.h * 1.6,
          string.format("%.2f wide by %.2f high", wing.w, wing.h))

    -- Struck under the mark's own pen. A heavy pen closes the gaps it is
    -- drawn between, and the gaps are the mark: this is the one number in
    -- the drawing that trades legibility of the shape against weight of the
    -- line, and raising it to the pen closes the fan first.
    local heaviest = 0
    for _, sh in ipairs(parts) do
        if sh.kind == "seg" and sh.round then
            heaviest = math.max(heaviest, sh.w)
        end
    end
    check("and is cut lighter than the mark it sits in",
          heaviest > 0 and heaviest < wing.body_h,
          string.format("%.2f of line against a %.2f body", heaviest,
                        wing.body_h))

    -- And it is drawn around a body rather than a speck. This first shipped
    -- at under a fifth of the mark's width, which rounds to three pixels by
    -- four beside a call sign: the feathers met at a hole where the middle
    -- should have been, and at the size the rail draws it was the one part
    -- of the badge a reader could not make out. Shrinking it back is the
    -- regression this catches.
    check("and is drawn around a body with a shape to it",
          wing.body_w > wing.w * 0.25,
          string.format("%.2f of body across a %.2f mark", wing.body_w,
                        wing.w))

    -- And that body is a ship rather than a gem, which is a different
    -- question and the one the first cut of it failed. A diamond is as
    -- pointed at the back as at the front and says nothing about which way
    -- it is flying: it is widest exactly halfway down, so it answers zero
    -- here. A craft noses to a point and carries its wings behind that, so
    -- its widest line sits well below its middle.
    local sweep = widest_below_middle(wing)
    check("and the body noses forward like a ship", sweep > 0.08,
          string.format("widest %.3f of its height below the middle", sweep))

    -- Three feathers to a side, arriving apart. Both halves of that matter
    -- and the second is the one that walks: the gaps between the tips are
    -- what makes this wings rather than one blunt spread, and two feathers
    -- whose ends land within a stroke of each other have merged into one
    -- however far apart they started. Measured between neighbors rather than
    -- across the set, since a pair can close while the third holds the span
    -- open.
    local tips = {}
    for _, sh in ipairs(parts) do
        if sh.kind == "seg" and sh.round then
            local ty = sh.bx > sh.ax and sh.by or sh.ay
            local tx = sh.bx > sh.ax and sh.bx or sh.ax
            if tx > wing.cx then tips[#tips + 1] = ty end
        end
    end
    check("and carries three feathers a side", #tips == 3,
          #tips .. " tips down one side")
    if #tips == 3 then
        table.sort(tips)
        local gap = math.min(tips[2] - tips[1], tips[3] - tips[2])
        check("with none of them arriving on top of another",
              gap > heaviest * 1.2,
              string.format("%.2f between the closest pair, on a %.2f line",
                            gap, heaviest))
    end

    -- Nothing closed anywhere near it. The helmets this replaced were a shell
    -- apiece and the whole point of badges is that neither mark is a head, so
    -- a closed run turning up around the person's middle is one come back.
    local shells = 0
    for _, sh in ipairs(parts) do
        if sh.kind == "outline" and sh.closed then shells = shells + 1 end
    end
    check("and wears no shell", shells == 0, shells .. " closed runs on it")
end

-- --- the machine is a package ----------------------------------------------

-- The scoreboard and the nameplates answer the same question with the same
-- pair of marks. This room has a human pilot and a bot, with the bot's hull on
-- screen.
ui.details = true
local board_frame = frame(function()
    ui.hud({
        me = 0, class_names = {"Apex"}, menu_open = false,
        pilots = {[0] = {name = "you", label = "human"},
                  [1] = {name = "a bot", label = "bot", ai = true}},
        teams = {}, feed = {}, hurt = 0, charges = {},
        cam_x = 100, cam_y = 100, half_w = W / 2, half_h = H / 2,
        banner = "", lag = 4,
        stats = {lag = 4, lead = 2, err = 1, err_max = 9, rewind = 0,
                 snaps = 1, rx = 0, tx = 0},
        zone = "chaos", fps = 60, frame_ms = 16, rx_rate = 0, tx_rate = 0,
    })
end)
ui.details = false
local board = chips(board_frame)
check("the scoreboard and the nameplate chip the bot", #board == 2,
      #board .. " chips beside one bot")
check("the scoreboard wings the human pilot",
      #wings(board_frame) == 1,
      #wings(board_frame) .. " pairs of wings beside one human pilot")

if board[1] then
    local chip = board[1]
    local side, reach = legs(board_frame, chip)
    -- A fringe on all four sides. Two tabs on two sides is a connector; what
    -- reads as silicon at eleven points is little runs coming out of the
    -- package wherever you look at it.
    check("the chip wears legs on all four sides",
          side.left == 2 and side.right == 2
          and side.top == 2 and side.bottom == 2,
          string.format("%d left, %d right, %d top, %d bottom",
                        side.left, side.right, side.top, side.bottom))
    -- And they stop where the mark stops. The legs are the outermost thing
    -- drawn, so what a caller is handed as the width has to cover them: a
    -- package measured without its legs is a mark that runs into the name
    -- beside it.
    check("and they reach the edge of the mark it reports",
          reach > chip.w / 2, string.format("%.2f against a %.2f package",
                                            reach, chip.w))
    -- The core, which is what keeps the package from reading as a button.
    local cores = 0
    for _, sh in ipairs(near(board_frame, chip.cx, chip.cy, chip.w / 2)) do
        if sh.kind == "quad" and math.abs(sh.cx - chip.cx) < chip.w * 0.05
            and math.abs(sh.cy - chip.cy) < chip.h * 0.05 then
            cores = cores + 1
        end
    end
    check("and carries a core", cores == 1, cores .. " cores in the package")
end

-- With the list shut, a human stranger's hull keeps the human mark beside its
-- name, and it is the only mark on the frame: nothing in the chrome carries a
-- standing pair any more.
local human_plate = frame(function()
    ui.hud({
        me = 0, class_names = {"Apex"}, menu_open = false,
        pilots = {[0] = {name = "you", label = "human"},
                  [1] = {name = "someone", label = "human"}},
        teams = {}, feed = {}, hurt = 0, charges = {},
        cam_x = 100, cam_y = 100, half_w = W / 2, half_h = H / 2,
        banner = "", lag = 4,
        stats = {lag = 4, lead = 2, err = 1, err_max = 9, rewind = 0,
                 snaps = 1, rx = 0, tx = 0},
        zone = "chaos", fps = 60, frame_ms = 16, rx_rate = 0, tx_rate = 0,
    })
end)
check("a human nameplate wears the pilot's wings", #wings(human_plate) == 1,
      #wings(human_plate) .. " pairs for one nameplate")

-- A kill line marks nobody. It names two pilots in words, and hanging a badge
-- on each says the same thing twice in the one panel whose argument is that
-- short lines need no chrome. With the roster shut and no chip in the corner,
-- that leaves no marks on the frame at all.
local kill_frame = frame(function()
    ui.hud({
        me = 0, class_names = {"Apex"}, menu_open = false,
        pilots = {[0] = {name = "you", label = "human"}},
        teams = {}, feed = {{
            text = {{"you", identity = "human"}, " killed ",
                    {"a bot", identity = "bot"}}, t = 0,
        }}, hurt = 0, charges = {},
        cam_x = 100, cam_y = 100, half_w = W / 2, half_h = H / 2,
        banner = "", lag = 4,
        stats = {lag = 4, lead = 2, err = 1, err_max = 9, rewind = 0,
                 snaps = 1, rx = 0, tx = 0},
        zone = "chaos", fps = 60, frame_ms = 16, rx_rate = 0, tx_rate = 0,
    })
end)
check("a kill line hangs no wings on its human", #wings(kill_frame) == 0,
      #wings(kill_frame) .. " pairs, wanted none")
check("and no chip on its bot", #chips(kill_frame) == 0,
      #chips(kill_frame) .. " chips, wanted none")

-- The line still measures and right-aligns off its words alone, which is what
-- the marks used to be folded into. A name keeps its own capitals.
local function text_entry(words)
    for i = 1, state.n do
        if state.text[i].s == words then return state.text[i] end
    end
end
local human_text, bot_text = text_entry("you"), text_entry("a bot")
check("the kill line still draws both names",
      human_text ~= nil and bot_text ~= nil)
check("and sets them on one line",
      human_text and bot_text and math.abs(human_text.y - bot_text.y) < 0.01)

-- --- and the pair sits level -----------------------------------------------

-- What makes the two a family, now that neither is a head. A row that reads as
-- one question needs the two answers at one size on one line: shape carries
-- the meaning, but position is what makes them a pair rather than two
-- pictures that happen to be adjacent.
local list_frame = room_frame(true)
local listed_wings = added(wings)
local listed_chips = added(chips)
check("the rooms list counts people with wings, not a dot",
      #listed_wings == 1, #listed_wings .. " pairs against 1 expected")
check("and counts machines with a chip", #listed_chips == 1,
      #listed_chips .. " chips in the row")

if #listed_wings == 1 and #listed_chips == 1 then
    local person = listed_wings[1]
    local machine = listed_chips[1]
    -- One width. Both marks are cut to the width their caller is handed, and
    -- that is the number the row lays itself out against: the wings are
    -- measured tip to tip and the chip across its legs, which is why the
    -- fringe had to reach the edge above.
    local _, machine_reach = legs(list_frame, machine)
    local machine_w = machine_reach * 2
    check("the pair in the row is cut to one width",
          math.abs(person.w - machine_w) < person.w * 0.06,
          string.format("%.2f of wing against %.2f of chip", person.w,
                        machine_w))
    -- And on one line. Neither stands on anything now, so what is compared is
    -- the middle each is drawn around rather than a foot they share.
    check("and drawn around one line",
          math.abs(person.cy - machine.cy) < 0.51,
          string.format("%.2f against %.2f", person.cy, machine.cy))
end

-- --- and the ship page draws it in the page's line ------------------------

-- The ship page is a grid of hulls with one cell that is not a hull: the one
-- about flying nothing, which draws the pilot instead. Every hull in that grid
-- is outlined in one width held against the screen, so a row of eight ships at
-- one size is drawn in one weight whatever each of them measures.
--
-- The pilot mark is the only figure there working from a pen it is handed, and
-- it cuts that pen back to keep its feathers apart. That is right, and it is
-- also exactly the kind of number that walks: too far under and the figure
-- fades out of a row of ships, at the pen and the fan closes. This is the same
-- defect the rail had and it has to be checked separately, because the two
-- pages hold their lines to different numbers and neither knows about the
-- other.
local ship_frame = frame(function()
    local rows = {}
    for i = 1, 3 do
        rows[i] = {label = "hull " .. i, hull = i - 1, detail = "a trade",
                   index = i, group = "ships", ship = true,
                   bars = {0.5, 0.5, 0.5, 0.5, 0.5}, carries = {"gun spray 2"}}
    end
    rows[4] = {label = "spectate", detail = "no hull", figure = "pilot",
               index = 4, group = "ships", ship = true,
               note = "watch the room from nobody's cockpit"}
    ui.menu({depth = 2, sel = 4, rail = RAIL, rail_sel = 2, focus = "stage",
             home = false, closable = true, ships = true, rows = rows})
end)

-- Everything on the stage, which is to say everything under the tabs. The tab
-- row is on this page too and wears a mark of its own at its own line, so a
-- search across the whole frame finds two of them and compares the wrong one.
--
-- By height rather than by width, which is what this asked before the tabs
-- moved from a column down the left to a row across the top. The row sits at
-- about 140 in this window and the first stage line at about 250.
local STAGE_Y = 200
local function on_stage(list)
    local out = {}
    for _, sh in ipairs(list) do
        if sh.y0 and sh.y0 > STAGE_Y then out[#out + 1] = sh end
    end
    return out
end

local stage = on_stage(ship_frame)
local pairs_on_stage = wings(stage)
check("the ship page draws the wings on its spectate row",
      #pairs_on_stage == 1,
      #pairs_on_stage .. " pairs on a roster of hulls and one pilot")
if pairs_on_stage[1] then
    -- The hulls are closed outlines, drawn out of a handful of points and
    -- wider than they are tall. The feathers are struck, so what is compared
    -- is a stroke against an outline.
    local hull_w, feather_w
    for _, sh in ipairs(stage) do
        if sh.kind == "outline" and sh.pts and #sh.pts < 12
            and sh.x1 - sh.x0 > sh.y1 - sh.y0 then
            hull_w = math.max(hull_w or 0, sh.w or 0)
        end
    end
    for _, sh in ipairs(near(stage, pairs_on_stage[1].cx, pairs_on_stage[1].cy,
                             pairs_on_stage[1].w / 2)) do
        if sh.kind == "seg" and sh.round then
            feather_w = math.max(feather_w or 0, sh.w)
        end
    end
    check("in the same line as the hulls beside it",
          hull_w and feather_w and feather_w < hull_w
          and feather_w > hull_w * 0.7,
          string.format("%.2f against %.2f", feather_w or -1, hull_w or -1))
end

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
