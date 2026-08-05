-- The two marks that say who is in a seat.
--
--     lua5.1 client/tests/marks_test.lua
--
-- A person and a machine are cut from one helmet and differ only in what is
-- inside it. That is not decoration: the games list sets a count of people
-- beside a count of machines, and the pair only reads as one question with two
-- answers while the shells match. Let one drift and the row goes back to being
-- two unrelated pictures, which is what it was when the people were a plain
-- dot.
--
-- Everywhere else the machine is alone, with no person beside it to be read
-- against, so it also has to say machine by itself. The antenna is what does
-- that, and it is the one part of the drawing that must never be shared.
--
-- Neither mark is public, and neither is exported for this: they are drawn
-- through the screens that use them, so what is measured is what a player is
-- shown. The shells are compared by shape rather than by position, since the
-- two are drawn at different sizes in different corners and it is the drawing
-- that has to match, not the arithmetic that placed it.

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
end

local layer = {}
function layer:seg(x1, y1, x2, y2, w)
    put("seg", x1 - w / 2, y1 - w / 2, x2 + w / 2, y2 + w / 2)
    shapes[#shapes].ax, shapes[#shapes].ay = x1, H - y1
    shapes[#shapes].bx, shapes[#shapes].by = x2, H - y2
end
function layer:disc(x, y, r) put("disc", x - r, y - r, x + r, y + r) end
function layer:rect(x, y, w, h) put("rect", x, y, x + w, y + h) end
-- Outlines are kept whole, with their corners: whether two marks share a
-- shell is a question about vertices, not about ink.
function layer:outline(pts, w)
    local o = {kind = "outline", pts = {}, w = w}
    for i = 1, #pts, 2 do
        o.pts[#o.pts + 1] = {pts[i], H - pts[i + 1]}
    end
    -- A box as well as the corners, so anything walking the frame can treat
    -- every record the same way.
    for _, pt in ipairs(o.pts) do
        o.x0 = math.min(o.x0 or pt[1], pt[1])
        o.x1 = math.max(o.x1 or pt[1], pt[1])
        o.y0 = math.min(o.y0 or pt[2], pt[2])
        o.y1 = math.max(o.y1 or pt[2], pt[2])
    end
    shapes[#shapes + 1] = o
end
-- The shell is arcs now, so they are kept with their geometry rather than
-- thrown away: a curve's centre, radius and sweep are what say two marks were
-- struck from one drawing.
function layer:arc(x, y, r, a0, a1)
    put("arc", x - r, y - r, x + r, y + r)
    local sh = shapes[#shapes]
    sh.cx, sh.cy, sh.r, sh.a0, sh.a1 = x, H - y, r, a0, a1
end
for _, n in ipairs({"fan", "flush", "frame", "halo", "quad", "reset",
                    "ring", "ring_fade", "seg_fade", "skirt", "tri",
                    "tri_fade"}) do
    layer[n] = function() end
end

_G.sim = setmetatable({
    ship_count = function() return 2 end,
    ship_alive = function() return 1 end,
    ship_team = function(i) return i end,
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

-- A helmet, found by its glass: the one arc in this interface that turns more
-- than half a revolution. Nothing else drawn on either of these screens does,
-- and the marks' own bowl runs from one end of the neck cut, up over the
-- crown, to the other.
--
-- The shell used to be a six cornered polygon and this used to count corners.
-- It is a turn of a circle now, because a chamfered approximation of a curve
-- is a chamfer, and at count size it is the corners the eye finds.
local function crowns(list)
    local out = {}
    for _, sh in ipairs(list) do
        if sh.kind == "arc" and sh.a0
            and math.abs(sh.a1 - sh.a0) > math.pi * 1.02 then
            out[#out + 1] = sh
        end
    end
    return out
end

-- Everything a mark is made of: what falls inside the box its crown implies,
-- give or take a helmet's height, so the antenna over it is caught too.
local function parts(list, crown)
    local out = {}
    local r = crown.r
    for _, sh in ipairs(list) do
        if sh.x0 > crown.cx - r * 1.6 and sh.x1 < crown.cx + r * 1.6
            and sh.y1 > crown.cy - r * 1.8 and sh.y0 < crown.cy + r * 2.4 then
            out[#out + 1] = sh
        end
    end
    return out
end

-- The shell, as a shape and nothing else: every arc and every straight run
-- that belongs to the outline, put on the crown and divided by its radius, so
-- two marks drawn at different sizes in different corners can be held against
-- each other. The antenna is left out, being the one thing the machine has
-- that the person must not.
local function shell_of(list, crown)
    local out = {}
    for _, sh in ipairs(parts(list, crown)) do
        local rel
        if sh.kind == "arc" then
            rel = string.format("arc %.3f %.3f %.3f %.3f %.3f",
                                (sh.cx - crown.cx) / crown.r,
                                (sh.cy - crown.cy) / crown.r,
                                sh.r / crown.r, sh.a0, sh.a1)
        elseif sh.kind == "seg" and sh.ay > crown.cy - crown.r * 0.05 then
            -- Straight runs at or below the crown's own centre: the sides and
            -- the chin. Anything above it is the antenna.
            rel = string.format("seg %.3f %.3f %.3f %.3f",
                                (sh.ax - crown.cx) / crown.r,
                                (sh.ay - crown.cy) / crown.r,
                                (sh.bx - crown.cx) / crown.r,
                                (sh.by - crown.cy) / crown.r)
        end
        if rel then out[#out + 1] = rel end
    end
    table.sort(out)
    return out
end

local RAIL = {}
for i, n in ipairs({"zones", "ship", "pilot", "settings", "help", "about"}) do
    RAIL[i] = {label = n, icon = n, index = i}
end

local function menu(rows)
    return frame(function()
        ui.menu({depth = 1, sel = 0, rail = RAIL, rail_sel = 3,
                 focus = "rail", home = true, closable = false,
                 rows = rows or {}})
    end)
end

-- --- one shell -------------------------------------------------------------

-- The rail's pilot stop, alone: no games list, so the only helmet on screen
-- is the one that names the player.
local rail_frame = menu({{label = "a row"}})
local rail_only = crowns(rail_frame)
check("the rail's pilot stop is a helmet", #rail_only == 1,
      #rail_only .. " helmets with no games listed")
local RAIL_HELMETS = #rail_only

-- The scoreboard's bot column, and the nameplate over the bot's own hull,
-- which is on screen in this room.
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
local board = crowns(board_frame)
check("the scoreboard and the nameplate both mark the bot", #board == 2,
      #board .. " helmets beside one bot")

if #rail_only == 1 and #board >= 1 then
    local a = shell_of(rail_frame, rail_only[1])
    local b = shell_of(board_frame, board[1])
    check("the person and the machine draw the same number of pieces",
          #a == #b, #a .. " against " .. #b)
    local same = #a == #b and #a > 0
    local worst = nil
    for i = 1, math.min(#a, #b) do
        if a[i] ~= b[i] then same = false worst = worst or (a[i] .. "  |  " .. b[i]) end
    end
    -- The whole design rests on this: drawn anywhere, at any size, the person
    -- and the machine are struck from one shell.
    check("and every piece of it is the same shape", same, worst)
    -- And it is a helmet rather than a circle: the crown turns through half a
    -- revolution and the sides below it are straight.
    local straight = 0
    for _, piece in ipairs(a) do
        if piece:sub(1, 3) == "seg" then straight = straight + 1 end
    end
    -- One straight run: the collar the glass sits in. The bowl is otherwise
    -- all curve, which is the whole difference from the box this replaced.
    check("the glass turns and only the collar is straight", straight == 1,
          straight .. " straight runs under the glass")
end

-- --- and two faces ---------------------------------------------------------

-- The antenna is what the machine says with nothing beside it, so it has to
-- reach above the crown, and the person must not.
--
-- Measured against the mark rather than against the frame. An earlier cut
-- looked for the highest thing drawn anywhere and found the top of the
-- screen, so deleting the antenna outright still passed.
local function over_crown(list, crown)
    local best = crown.cy - crown.r
    for _, sh in ipairs(parts(list, crown)) do
        if sh.kind ~= "arc" and sh.x1 > crown.cx - crown.r * 0.3
            and sh.x0 < crown.cx + crown.r * 0.3 then
            best = math.min(best, sh.y0)
        end
    end
    return (crown.cy - crown.r - best) / crown.r
end

local machine_over = board[1] and over_crown(board_frame, board[1])
check("the bot's antenna stands above its crown",
      machine_over and machine_over > 0.1,
      string.format("%.3f of a radius above", machine_over or 0))

local person_over = rail_only[1] and over_crown(rail_frame, rail_only[1])
check("and the pilot puts nothing above hers",
      person_over and person_over < 0.02,
      string.format("%.3f of a radius above", person_over or 0))

-- --- the games list counts both --------------------------------------------

-- The row that made them a pair. People were a bare disc here, which is why
-- this checks the shape rather than that something was drawn at all.
local listed = crowns(menu({{label = "chaos", players = 3, bots = 48,
                             live = true}}))
check("the games list counts people with a helmet, not a dot",
      #listed == RAIL_HELMETS + 2,
      #listed .. " helmets against " .. (RAIL_HELMETS + 2) .. " expected")

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
