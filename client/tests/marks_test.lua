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
    shapes[#shapes + 1] = o
end
for _, n in ipairs({"arc", "fan", "flush", "frame", "halo", "quad", "reset",
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

-- A helmet, told apart from every other six cornered outline this interface
-- draws by its crown: two corners at the top, at the same height, spanning
-- the whole width. The help key's mark is also six cornered and has a chamfer
-- up top, so counting corners alone finds it too.
local function is_helmet(pts)
    if #pts ~= 6 then return false end
    local x0, y0, x1 = nil, nil, nil
    for _, pt in ipairs(pts) do
        x0 = math.min(x0 or pt[1], pt[1])
        x1 = math.max(x1 or pt[1], pt[1])
        y0 = math.min(y0 or pt[2], pt[2])
    end
    local wide = x1 - x0
    local up = {}
    for _, pt in ipairs(pts) do
        if math.abs(pt[2] - y0) < wide * 0.01 then up[#up + 1] = pt[1] end
    end
    if #up ~= 2 then return false end
    return math.abs(math.abs(up[1] - up[2]) - wide) < wide * 0.01
end

local function shells(list)
    local out = {}
    for _, sh in ipairs(list) do
        if sh.kind == "outline" and is_helmet(sh.pts) then
            out[#out + 1] = sh
        end
    end
    return out
end

local function box(pts)
    local x0, y0, x1, y1
    for _, pt in ipairs(pts) do
        x0 = math.min(x0 or pt[1], pt[1])
        x1 = math.max(x1 or pt[1], pt[1])
        y0 = math.min(y0 or pt[2], pt[2])
        y1 = math.max(y1 or pt[2], pt[2])
    end
    return x0, y0, x1, y1
end

-- A shell as a shape and nothing else: put on the origin and divided by its
-- own width, so two of them drawn at different sizes in different corners can
-- be held against each other.
local function shape_of(pts)
    local x0, y0, x1, y1 = box(pts)
    local w = x1 - x0
    local out = {}
    for i, pt in ipairs(pts) do
        out[i] = {(pt[1] - x0) / w, (pt[2] - y0) / w}
    end
    return out, w, x0, y0, x1, y1
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
local rail_only = shells(rail_frame)
check("the rail's pilot stop is a helmet", #rail_only == 1,
      #rail_only .. " helmets with no games listed")
local RAIL_HELMETS = #rail_only

-- The scoreboard's bot column.
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
local board = shells(board_frame)
-- Two: the scoreboard's column and the nameplate over the bot's own hull,
-- which is on screen in this room.
check("the scoreboard and the nameplate both mark the bot", #board == 2,
      #board .. " helmets beside one bot")

if #rail_only == 1 and #board >= 1 then
    local a = shape_of(rail_only[1].pts)
    local b = shape_of(board[1].pts)
    local worst = 0
    for i = 1, #a do
        worst = math.max(worst, math.abs(a[i][1] - b[i][1]),
                         math.abs(a[i][2] - b[i][2]))
    end
    -- The whole design rests on this number: drawn anywhere, at any size, the
    -- person and the machine are the same polygon.
    check("the person and the machine are the same shell", worst < 0.01,
          string.format("worst corner off by %.4f of a width", worst))
    -- And it is a helmet rather than a box: two corners hold the crown and
    -- four shape the jaw, which is where the chamfer went.
    local _, py0, _, py1 = box(rail_only[1].pts)
    local top, bot = 0, 0
    for _, pt in ipairs(rail_only[1].pts) do
        if pt[2] < (py0 + py1) / 2 then top = top + 1 else bot = bot + 1 end
    end
    check("the crown is flat and the jaw is cut", top == 2 and bot == 4,
          top .. " corners up top, " .. bot .. " below")
end

-- --- and two faces ---------------------------------------------------------

-- The antenna is what the machine says with nothing beside it, so it has to
-- reach above the shell, and the person must not.
--
-- Measured against the mark rather than against the frame. The first cut of
-- this looked for the highest thing drawn anywhere and found the top of the
-- screen, so deleting the antenna outright still passed.
local function over_crown(list)
    local sh = shells(list)[1]
    if not sh then return nil end
    local sx0, sy0, sx1, sy1 = box(sh.pts)
    local wide = sx1 - sx0
    local best = sy0
    for _, s2 in ipairs(list) do
        -- Only what stands in the mark's own columns, and only just above
        -- it. A window any wider than the shell picks up whatever else the
        -- screen happens to have drawn over that spot.
        if s2.kind ~= "outline"
            and s2.x1 > sx0 and s2.x0 < sx1
            and s2.y0 > sy0 - (sy1 - sy0) and s2.y0 < sy1 then
            best = math.min(best, s2.y0)
        end
    end
    return (sy0 - best) / wide
end

local machine_over = over_crown(board_frame)
check("the bot's antenna stands above its crown",
      machine_over and machine_over > 0.1,
      string.format("%.3f of a width above", machine_over or 0))

local person_over = over_crown(rail_frame)
check("and the pilot puts nothing above hers",
      person_over and person_over < 0.02,
      string.format("%.3f of a width above", person_over or 0))

-- --- the games list counts both --------------------------------------------

-- The row that made them a pair. People were a bare disc here, which is why
-- this checks the shape rather than that something was drawn at all.
local listed = shells(menu({{label = "chaos", players = 3, bots = 48,
                             live = true}}))
check("the games list counts people with a helmet, not a dot",
      #listed == RAIL_HELMETS + 2,
      #listed .. " helmets against " .. (RAIL_HELMETS + 2) .. " expected")

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
