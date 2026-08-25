-- The two marks that say who is in a seat.
--
--     lua5.1 client/tests/marks_test.lua
--
-- A person wears a round helmet with a curved visor. A machine wears a
-- squared one with lamps in it and an antenna over the top. The difference is
-- the message: the games list sets a count of people beside a count of
-- machines, and round-against-square is what answers that at a glance, at a
-- size where a lamp is two pixels.
--
-- So this measures the two things that must stay apart and the three that
-- must stay together. Apart: the person's shell turns and the machine's does
-- not, and only the machine reaches above its crown. Together: one collar,
-- one width, one baseline, because a pair that does not sit level reads as
-- two unrelated pictures however different their shapes are.
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
function layer:seg(x1, y1, x2, y2, w)
    local s = put("seg", x1 - w / 2, y1 - w / 2, x2 + w / 2, y2 + w / 2)
    s.ax, s.ay, s.bx, s.by, s.w = x1, H - y1, x2, H - y2, w
end
function layer:disc(x, y, r) put("disc", x - r, y - r, x + r, y + r) end
function layer:rect(x, y, w, h) put("rect", x, y, x + w, y + h) end
function layer:outline(pts, w)
    local o = {kind = "outline", pts = {}, w = w}
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
-- Arcs keep their geometry: a curve's center, radius and sweep are how a
-- round shell is told from a square one.
function layer:arc(x, y, r, a0, a1)
    local s = put("arc", x - r, y - r, x + r, y + r)
    s.cx, s.cy, s.r, s.a0, s.a1 = x, H - y, r, a0, a1
end
function layer:quad(x1, y1, x2, y2, x3, y3, x4, y4)
    local xs, ys = {x1, x2, x3, x4}, {y1, y2, y3, y4}
    local s = put("quad", math.min(unpack(xs)), math.min(unpack(ys)),
                  math.max(unpack(xs)), math.max(unpack(ys)))
    s.top = H - math.max(unpack(ys))
end
-- The visor is one of these. Its points are kept rather than collapsed,
-- because what is checked about it is the shape of its two edges against each
-- other, which a bounding box has thrown away.
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

-- A person's helmet, found by its shell: a closed run drawn out of far more
-- points than any corner needs, standing taller than it is wide. Everything
-- else outlined on these screens is a handful of straight sides, and the one
-- other sampled curve, the ring around the world in the Zones stop, is three
-- times as wide as it is high.
local function crowns(list)
    local out = {}
    for _, sh in ipairs(list) do
        if sh.kind == "outline" and sh.pts and #sh.pts >= 20
            and sh.y1 - sh.y0 > sh.x1 - sh.x0 then
            out[#out + 1] = {cx = (sh.x0 + sh.x1) / 2,
                             cy = (sh.y0 + sh.y1) / 2,
                             w = sh.x1 - sh.x0, h = sh.y1 - sh.y0,
                             x0 = sh.x0, x1 = sh.x1,
                             y0 = sh.y0, y1 = sh.y1, pts = sh.pts}
        end
    end
    return out
end

local function horizontal(sh)
    return sh.kind == "seg" and math.abs(sh.ay - sh.by) < 0.01
end
-- A collar is a run of line, not a point. Asked for by length because setting
-- its reach to zero still draws a segment, and a degenerate one counted as a
-- collar for as long as this only counted them.
local function collar_of(sh, span)
    return horizontal(sh) and math.abs(sh.bx - sh.ax) > span
end
local function vertical(sh)
    return sh.kind == "seg" and math.abs(sh.ax - sh.bx) < 0.01
end

-- A machine's helmet, found by its crown: a horizontal run with a vertical
-- dropping from each of its two ends. That is the shape a flat top and two
-- straight sides make and nothing else in these screens draws one.
--
-- The sides are allowed to start a line width below the crown rather than on
-- it. They butt into it instead of meeting it, so that four capped strokes do
-- not overlap in four bright corners.
local function boxes(list)
    local out = {}
    for _, sh in ipairs(list) do
        if horizontal(sh) then
            local left, right, drop
            for _, o in ipairs(list) do
                if vertical(o) and o.by > o.ay
                    and o.ay >= sh.ay - 0.01 and o.ay <= sh.ay + sh.w then
                    if math.abs(o.ax - sh.ax) < 0.01 then left = o end
                    if math.abs(o.ax - sh.bx) < 0.01 then right = o end
                    drop = o.by - sh.ay
                end
            end
            if left and right then
                out[#out + 1] = {cx = (sh.ax + sh.bx) / 2, top = sh.ay,
                                 w = math.abs(sh.bx - sh.ax), h = drop,
                                 crown = sh}
            end
        end
    end
    return out
end

-- Everything drawn near a mark, so what sits over its crown is caught too.
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

-- The shipped row, less friends. Every stop draws its mark at the foot of the
-- column now, and the friends mark is two helmets one behind the other: this
-- file counts helmets, so the one stop that brings its own pair stays off the
-- row. Nothing else on it wears one.
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

-- What the panel put on the frame, rather than what is on the frame. PLAYERS
-- keeps its own pair in the corner keys whether the panel is up or not, and
-- the two land 26 points apart across, which is close enough that picking one
-- by where it is would be picking whichever the layout moved last. Drawing
-- the frame both ways and taking the difference asks the question exactly.
-- The two kinds of mark are found by different readers and come back
-- described differently: a shell knows where its middle is, a box knows where
-- its top is. Across is common to both and is enough here, since nothing
-- draws two of either at one x.
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

-- --- the person is round ---------------------------------------------------

-- The helmet a room row counts its people with.
--
-- It was the topbar's, beside the call sign, and the topbar's far end is two
-- buttons now with no mark on either. Every check below is about how the
-- shell itself is drawn, so what it wants is one of them and not which frame
-- it came off.
local rail_frame = room_frame(true)
local rail_only = added(crowns)
check("a room row counts people with a helmet", #rail_only == 1,
      #rail_only .. " helmets the panel put up")

if rail_only[1] then
    local shell = rail_only[1]
    local parts = near(rail_frame, shell.cx, shell.cy, shell.h / 2)

    -- Nothing straight under it. The shell used to be cut off flat and stood
    -- on a collar, and the collar was a line wider than the cut, which read as
    -- shoulders. It closes on its own chin now, so a straight run down there
    -- is that collar come back.
    local straight = 0
    for _, sh in ipairs(parts) do
        if horizontal(sh) and sh.ay > shell.cy then straight = straight + 1 end
    end
    check("the person's shell closes on itself, with nothing under it",
          straight == 0, straight .. " straight runs below the middle")

    -- Taller than it is wide, and narrower at the chin than at the eyes.
    -- Both are what stopped it reading as a fishbowl, and neither survives
    -- somebody tuning one number without looking.
    check("it stands taller than it is wide", shell.h > shell.w * 1.05,
          string.format("%.2f wide by %.2f high", shell.w, shell.h))
    local widest, chin = 0, 0
    for _, pt in ipairs(shell.pts) do
        local dx = math.abs(pt[1] - shell.cx)
        widest = math.max(widest, dx)
        -- The bottom fifth, which is the chin.
        if pt[2] > shell.y1 - shell.h * 0.2 then chin = math.max(chin, dx) end
    end
    check("and draws in below the eyes", chin < widest * 0.75,
          string.format("chin %.2f against %.2f at the widest", chin, widest))

    -- The visor: one pane, walked as a strip of quads so that both its edges
    -- can bow. A fan would be fewer triangles and is what this drew until the
    -- top edge learned to bend, at which point the fan filled the bend back
    -- in, so the shape being a strip is itself worth pinning.
    local band = {}
    for _, sh in ipairs(parts) do
        if sh.kind == "quad" then band[#band + 1] = sh end
    end
    check("the person wears a visor", #band >= 4,
          #band .. " slices of pane")
    if #band >= 4 then
        local lo, hi = math.huge, -math.huge
        for _, sh in ipairs(band) do
            lo, hi = math.min(lo, sh.x0), math.max(hi, sh.x1)
        end
        local span = hi - lo
        -- Both edges bow the same way, and by different amounts. The top
        -- bends down under the brow and the bottom sags further, which is
        -- what a pane wrapped round a head does. Ruled flat, as it was, it
        -- read as a line drawn on a face rather than as glass set in a shell.
        local mid_top, end_top = -math.huge, math.huge
        local mid_bot, end_bot = -math.huge, math.huge
        for _, sh in ipairs(band) do
            local t = ((sh.x0 + sh.x1) / 2 - lo) / span
            if t > 0.35 and t < 0.65 then
                mid_top = math.max(mid_top, sh.y0)
                mid_bot = math.max(mid_bot, sh.y1)
            end
            if t < 0.1 or t > 0.9 then
                end_top = math.min(end_top, sh.y0)
                end_bot = math.min(end_bot, sh.y1)
            end
        end
        check("its top bends down at the middle",
              mid_top - end_top > shell.h * 0.02,
              string.format("%.3f of its own height",
                            (mid_top - end_top) / shell.h))
        check("and its bottom sags further",
              mid_bot - end_bot > mid_top - end_top,
              string.format("%.3f against %.3f of its height",
                            (mid_bot - end_bot) / shell.h,
                            (mid_top - end_top) / shell.h))

        -- Held inside the shell. Measured against the shell's own outline at
        -- the pane's height rather than against a radius, since there is no
        -- one circle to measure from any more.
        local function shell_half(y)
            local best = 0
            for _, pt in ipairs(shell.pts) do
                if math.abs(pt[2] - y) < shell.h * 0.08 then
                    best = math.max(best, math.abs(pt[1] - shell.cx))
                end
            end
            return best
        end
        local worst = 0
        for _, sh in ipairs(band) do
            for _, x in ipairs({sh.x0, sh.x1}) do
                for _, y in ipairs({sh.y0, sh.y1}) do
                    local half = shell_half(y)
                    if half > 0 then
                        worst = math.max(worst, math.abs(x - shell.cx) / half)
                    end
                end
            end
        end
        check("and stays inside the shell", worst < 1.02,
              string.format("reaches %.3f of the shell's own width", worst))
    end
end

-- --- the machine is square -------------------------------------------------

-- The scoreboard, nameplates, and PLAYERS count all answer the same question
-- with the same pair of marks. This room has a human pilot and a bot, with the
-- bot's hull on screen.
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
local board = boxes(board_frame)
check("the scoreboard, nameplate, and player count box the bot", #board == 3,
      #board .. " boxes beside one bot")
check("the scoreboard and player count mark the human pilot",
      #crowns(board_frame) == 2,
      #crowns(board_frame) .. " round helmets beside one human pilot")

-- With the list shut, a human stranger's hull keeps the human mark beside its
-- name. PLAYERS contributes the other helmet and its standing zero-bot mark.
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
check("a human nameplate wears the pilot helmet", #crowns(human_plate) == 2,
      #crowns(human_plate) .. " helmets across PLAYERS and one nameplate")

-- A kill line marks nobody. It names two pilots in words, and hanging a
-- helmet and a machine on them says the same thing twice in the one panel
-- whose argument is that short lines need no chrome. The room still
-- contributes the standing pair in PLAYERS, so that pair is the whole count.
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
check("a kill line hangs no helmet on its human", #crowns(kill_frame) == 1,
      #crowns(kill_frame) .. " helmets, wanted only the one in PLAYERS")
check("and none on its bot", #boxes(kill_frame) == 1,
      #boxes(kill_frame) .. " bot marks, wanted only the one in PLAYERS")

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

-- The antenna is what the machine says with nothing beside it, so it has to
-- reach above the crown, and the person must not.
--
-- Measured against the mark rather than against the frame. An earlier cut
-- looked for the highest thing drawn anywhere and found the top of the
-- screen, so deleting the antenna outright still passed.
local function over(list, cx, top, r)
    local best = top
    for _, sh in ipairs(near(list, cx, top + r, r)) do
        if sh.x1 > cx - r * 0.3 and sh.x0 < cx + r * 0.3
            and not (horizontal(sh) and math.abs(sh.ay - top) < 0.01) then
            best = math.min(best, sh.y0)
        end
    end
    return (top - best) / r
end

local machine_over = board[1]
    and over(board_frame, board[1].cx, board[1].top, board[1].w / 2)
check("the bot's antenna stands above its crown",
      machine_over and machine_over > 0.1,
      string.format("%.3f of a half width above", machine_over or 0))

local person_over = rail_only[1]
    and over(rail_frame, rail_only[1].cx, rail_only[1].y0,
             rail_only[1].h / 2)
check("and the pilot puts nothing above hers",
      person_over and person_over < 0.02,
      string.format("%.3f of a half height above", person_over or 0))

-- --- and the pair sits level -----------------------------------------------

-- What is left of the family after the shells stopped matching. A row that
-- reads as one question needs the two answers on one line, at one size, on
-- one collar: shape carries the meaning, but position is what makes them a
-- pair rather than two pictures that happen to be adjacent.
local list_frame = room_frame(true)
local listed_round = added(crowns)
local listed_square = added(boxes)
check("the rooms list counts people with a helmet, not a dot",
      #listed_round == 1, #listed_round .. " helmets against 1 expected")
check("and counts machines with a box", #listed_square == 1,
      #listed_square .. " boxes in the row")

if #listed_round == 1 and #listed_square == 1 then
    local person = listed_round[1]
    local machine = listed_square[1]
    -- One height, not one width. The person's shell is drawn narrower than
    -- its box on purpose, which is what stopped it reading as a fishbowl, so
    -- the two no longer measure the same across. What still has to hold is
    -- that they stand the same tall, because a pair at two sizes reads as two
    -- pictures that happen to be adjacent.
    --
    -- Read off the two ends rather than off a height, since the machine's
    -- sides butt half a line under its own crown so that four capped strokes
    -- do not light four corners, and a height measured through them comes out
    -- half a line short of the box the mark actually fills.
    check("the pair in the row is drawn to one crown",
          person and math.abs(person.y0 - machine.top) < 0.51,
          person and string.format("%.2f against %.2f", person.y0,
                                   machine.top) or "no row helmet")
    -- And on one line. The machine still stands on a collar and the person
    -- closes on a chin, so what is compared is the bottom of each: the line
    -- they are both drawn down to, whatever they do when they get there.
    local my
    for _, sh in ipairs(near(list_frame, machine.cx,
                             machine.top + machine.h / 2, machine.w / 2)) do
        if collar_of(sh, machine.w / 2) and sh.ay > machine.top then
            my = math.max(my or -math.huge, sh.ay)
        end
    end
    check("and they stand on one line", person and my
          and math.abs(person.y1 - my) < 0.51,
          string.format("%.2f against %.2f", person and person.y1 or -1,
                        my or -1))
end

-- --- and the ship page draws it in the page's line ------------------------

-- The ship page is a grid of hulls with one cell that is not a hull: the one
-- about flying nothing, which draws the helmet instead. Every hull in that
-- grid is outlined in one width held against the screen, so a row of eight
-- ships at one size is drawn in one weight whatever each of them measures.
--
-- The helmet was the only figure there working its weight out from its own
-- size, which at the cell's scale came out at twice the ships beside it. This
-- is the same defect the rail had and it has to be checked separately,
-- because the two pages hold their lines to different numbers and neither
-- knows about the other.
local ship_frame = frame(function()
    local rows = {}
    for i = 1, 8 do
        rows[i] = {label = "hull " .. i, hull = i - 1, role = "a trade"}
    end
    rows[9] = {label = "Spectate", role = "no hull", figure = "pilot"}
    ui.menu({depth = 2, sel = 9, rail = RAIL, rail_sel = 2, focus = "stage",
             home = false, closable = true, rows = rows})
end)

-- Everything on the stage, which is to say everything under the tabs. The tab
-- row is on this page too and wears a helmet of its own at its own line, so a
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
local helmets = crowns(stage)
check("the ship page draws the helmet in its spectate cell", #helmets == 1,
      #helmets .. " helmets on a page of seven hulls and one pilot")
if helmets[1] then
    -- The hulls are closed outlines too. They are told apart by being wider
    -- than they are tall and by being drawn out of a handful of points, where
    -- the helmet is a sampled curve.
    local hull_w, helm_w
    for _, sh in ipairs(stage) do
        if sh.kind == "outline" and sh.pts then
            if #sh.pts < 20 and sh.x1 - sh.x0 > sh.y1 - sh.y0 then
                hull_w = math.max(hull_w or 0, sh.w or 0)
            elseif #sh.pts >= 20 and sh.y1 - sh.y0 > sh.x1 - sh.x0 then
                helm_w = sh.w
            end
        end
    end
    check("in the same line as the hulls beside it",
          hull_w and helm_w and math.abs(hull_w - helm_w) < 0.01,
          string.format("%.2f against %.2f", helm_w or -1, hull_w or -1))
end

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
