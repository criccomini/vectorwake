-- Draw a HUD frame without an engine.
--
--     lua5.1 client/tools/hud_svg.lua <out.svg> [scenario] [root] [w] [h]
--
-- Scenarios: after (a match part way through), before (with the banner the
-- server used to send), turf (a flag mode, for the pennant strip under the
-- band), roam (the one zone with prizes, for the greens on the dial, and
-- the one that sends no match, so the row counts the room), duel (two
-- pilots and no score),
-- ending (a room at the whistle), watching (the screen a client opens
-- on, a room with no seat of ours in it; watching-zones, watching-ships
-- and watching-account open a stop's list, watching-login the panel an
-- account act opens over one), waiting (what the loader hands off to
-- before a room answers), loadout (a loaded hull with charges in hand, for
-- the corner stack), menu (the in-match column; menu-settings, menu-side and
-- menu-zone open a stop's panel).
-- Rasterize with any browser:
--
--     chromium --headless --screenshot=out.png --window-size=1280,800 out.svg
--
-- client/tools/shot.sh is the honest picture and needs a build, a display and
-- a server next to it. This needs lua5.1 and answers a narrower question: is
-- the layout right. It drives the real arena.ui against a stubbed engine, the
-- way podium_test does, and writes down what it asked for instead of counting
-- it. Every position, size, color and string is the shipped code's; only the
-- drawing is this file's, so the shapes are approximations of the mesh (a
-- skirt is a falloff here, not a gradient) and there is no arena behind them.
--
-- Worth having because a collision is invisible to a test that reads strings:
-- two readouts can overlap with every string in the right order, which no
-- assertion had thought to make and one look found.

local out_path = assert(arg[1], "an output path")
local scenario = arg[2] or "after"
local root = arg[3] or "client"

package.path = root .. "/?.lua;" .. package.path

local shapes = {}
local function col_of(c)
    c = c or {1, 1, 1, 1}
    local function ch(v) return math.max(0, math.min(255, math.floor((v or 0) * 255 + 0.5))) end
    return string.format("rgb(%d,%d,%d)", ch(c[1]), ch(c[2]), ch(c[3])), c[4] or 1
end

-- What is on the stands, for the scenarios that have any. A row is what
-- `sim.flag_at` answers: x, y, the team holding it, whether it is carried.
local flags = {}

-- The prizes lying about, for the one zone that has any. A row is what
-- `sim.green_at` answers: x, y, the kit slot it fills, whether it is still
-- there.
local greens = {}

local H
local function fy(y) return H - y end

local layer = {}
function layer:flush() end
function layer:reset() end
function layer:rect(x, y, w, h, col)
    shapes[#shapes + 1] = {k = "rect", x = x, y = y, w = w, h = h, col = col}
end
function layer:frame(x, y, w, h, t, col)
    shapes[#shapes + 1] = {k = "frame", x = x, y = y, w = w, h = h, t = t, col = col}
end
function layer:tri(x1, y1, x2, y2, x3, y3, col)
    shapes[#shapes + 1] = {k = "poly", p = {x1, y1, x2, y2, x3, y3}, col = col}
end
function layer:tri_fade(x1, y1, a1, x2, y2, a2, x3, y3, a3, col)
    shapes[#shapes + 1] = {k = "poly", p = {x1, y1, x2, y2, x3, y3}, col = col,
                           fade = (a1 + a2 + a3) / 3}
end
function layer:quad(x1, y1, x2, y2, x3, y3, x4, y4, col)
    shapes[#shapes + 1] = {k = "poly", p = {x1, y1, x2, y2, x3, y3, x4, y4}, col = col}
end
function layer:seg(x1, y1, x2, y2, w, col)
    shapes[#shapes + 1] = {k = "seg", x1 = x1, y1 = y1, x2 = x2, y2 = y2,
                           w = w, col = col, cap = "round"}
end
function layer:seg_flat(x1, y1, x2, y2, w, col)
    shapes[#shapes + 1] = {k = "seg", x1 = x1, y1 = y1, x2 = x2, y2 = y2,
                           w = w, col = col, cap = "butt"}
end
-- Kept whole rather than averaged: the weapon marks are made of these now,
-- and a fade drawn as a uniform line reads as a bar where the player sees a
-- streak. The writer below builds the tapered quad with a gradient along it,
-- which is what the mesh actually is.
function layer:seg_fade(x1, y1, x2, y2, w1, w2, a1, a2, col)
    shapes[#shapes + 1] = {k = "fade", x1 = x1, y1 = y1, x2 = x2, y2 = y2,
                           w1 = w1, w2 = w2, a1 = a1, a2 = a2, col = col}
end
-- Solid at the center, gone at the rim: a radial gradient.
function layer:halo(x, y, r, _, col)
    shapes[#shapes + 1] = {k = "halo", x = x, y = y, r = r, col = col}
end
function layer:skirt(x1, y1, x2, y2, dx, dy, a, col)
    shapes[#shapes + 1] = {k = "skirt", x1 = x1, y1 = y1, x2 = x2, y2 = y2,
                           dx = dx, dy = dy, a = a, col = col}
end
function layer:disc(x, y, r, segs, col)
    shapes[#shapes + 1] = {k = "disc", x = x, y = y, r = r, col = col}
end
function layer:ring(x, y, r, w, segs, col)
    shapes[#shapes + 1] = {k = "ring", x = x, y = y, r = r, w = w, col = col}
end
function layer:ring_fade(x, y, r, w, segs, col)
    shapes[#shapes + 1] = {k = "ring", x = x, y = y, r = r, w = w, col = col, fade = 0.5}
end
-- The soft-edged ring, which is the one a flag mark is drawn with. Note the
-- order: this takes its color before the segment count, where the two above
-- take it after, so it cannot borrow either body.
function layer:ring_aa(x, y, r, w, col, segs)
    shapes[#shapes + 1] = {k = "ring", x = x, y = y, r = r, w = w, col = col}
end
function layer:arc(x, y, r, a0, a1, w, segs, col)
    shapes[#shapes + 1] = {k = "arc", x = x, y = y, r = r, a0 = a0, a1 = a1,
                           w = w, col = col}
end
function layer:outline(pts, w, col)
    shapes[#shapes + 1] = {k = "outline", p = pts, w = w, col = col}
end
-- A convex fill through a point list. The mesh fans it into triangles; an SVG
-- has a polygon, so the same points go straight down as one.
function layer:fan(pts, col)
    shapes[#shapes + 1] = {k = "poly", p = pts, col = col}
end

-- --- the engine, as much of it as ui.lua touches ---------------------------

local room = {count = 2, teams = {[0] = 0, 1}, alive = {}}
_G.sim = {
    ship_count = function() return room.count end,
    ship_x = function(i) return 3000 + i * 180 end,
    ship_y = function(i) return 3000 + i * 120 end,
    ship_x_raw = function(i) return 3000 + i * 180 end,
    ship_y_raw = function(i) return 3000 + i * 120 end,
    ship_heading = function() return 0 end,
    ship_active = function() return 1 end,
    ship_alive = function(i) return room.alive[i] == false and 0 or 1 end,
    ship_team = function(i) return room.teams[i] or 0 end,
    ship_class = function() return 0 end,
    ship_energy = function() return 780 end,
    ship_max_energy = function() return 1000 end,
    ship_kills = function(i)
        return room.kills and room.kills[i] or (i == 0 and 4 or 1)
    end,
    ship_deaths = function(i)
        return room.deaths and room.deaths[i] or (i == 0 and 1 or 4)
    end,
    ship_assists = function(i)
        return room.assists and room.assists[i] or 0
    end,
    ship_points = function(i)
        return room.points and room.points[i] or (i == 0 and 12 or 3)
    end,
    ship_bounty = function(i) return i == 0 and 5 or 2 end,
    ship_up = function() return 2 end,
    ship_level = function(_, t)
        if scenario == "loadout" then return t == 0 and 2 or 1 end
        return 1
    end,
    ship_charge = function() return 0 end,
    -- What a rung of shrapnel breaks into, as the shipped baseline sets it:
    -- rung one throws four fragments and the rungs above climb by two. The
    -- ship page reads this rather than the rung, so a stub answering nought
    -- would draw the page telling a pilot the wrong number. See
    -- `sim_splinter_count`.
    splinter_count = function(rung)
        return ({[0] = 0, 4, 6, 8})[rung or 0] or 0
    end,
    -- The loadout frame flies what most of the shipped hulls actually hold:
    -- the gun two rungs up wearing a fan and a bounce, the bomb a rung up
    -- wearing a fuse and fragments.
    ship_mod = function(_, t, i)
        if scenario ~= "loadout" then return 0 end
        local mods = {[0] = {[0] = 2, [1] = 1}, [1] = {[2] = 2, [3] = 2}}
        return (mods[t] or {})[i] or 0
    end,
    -- False, not 0: a number is truthy in Lua, and the marks read this as
    -- "the fan is declined" and dim it.
    ship_multi_off = function() return false end,
    shrap_count = function(n)
        if n <= 0 then return 0 end
        return 2 ^ math.min(n, 3)
    end,
    -- What a pull throws, which a zone owns rather than the drawing: the
    -- baseline's round a rung, a pair at seven and a half degrees and the
    -- fan at fifteen.
    spray_shape = function(_, _, _, n)
        if n <= 0 then return 1, 0 end
        return n + 1, (n == 1) and (65536 / 48) or (65536 / 24)
    end,
    ship_vel = function() return 0, 0 end,
    has_trigger = function() return true end,
    TRIG_GUN = 0,
    TRIG_BOMB = 1,
    tick = function() return 4242 end,
    weapon_count = function() return 0 end,
    green_count = function() return #greens end,
    green_at = function(i)
        local g = greens[i + 1]
        return g[1], g[2], g[3], true
    end,
    flag_count = function() return #flags end,
    flag_at = function(i)
        local f = flags[i + 1]
        return f[1], f[2], f[3], f[4]
    end,
    map_coarse = function() return nil end,
    UP_STEPS = 8,
    BTN_FIRE = 1,
}

package.loaded["arena.state"] = dofile(root .. "/arena/state.lua")
package.loaded["arena.touch"] = {
    layout = function() return {charge = {}} end,
    used = false,
}
package.loaded["arena.world"] = {
    build_overview = function() end,
    forget_overview = function() end,
    overview = function() return {grid = 0, rects = {}} end,
    radar_tiles = {2960, 2960, 3120, 2960, 3120, 3120},
    radar_safe = {},
    radar_doors = {},
}

local ui = require("arena.ui")
local state = package.loaded["arena.state"]

-- --- the frame --------------------------------------------------------------

local W = tonumber(arg[4]) or 1280
H = tonumber(arg[5]) or 800

-- A match part way through: 2:46 on the clock, nobody dead yet.
local match = {playing = true, left = 166, score = {[0] = 0, [1] = 0}}

-- What the old build put across the middle of the screen every second of
-- every life. The server sends it; the client draws whatever arrives.
local banner = ""
if scenario == "before" then
    banner = "Opponent left. Replaying that fight"
end

-- The front end: a melee room watched from the stands, with the game's name
-- and PLAY NOW over the foot of it. Worth a scenario of its own because this
-- is the first screen anybody sees and it is the one made of two pieces laid
-- out by different code, the watcher's HUD and the lockup over the key, so
-- whether they collide is a question only a picture answers.
-- The whistle: a full melee room with the result up. This is the frame the
-- ending was redesigned against, and the one worth a picture, since it is the
-- board drawn in a column of its own with a head and a foot around it.
local ending = scenario == "ending"
if ending then
    room.count = 8
    room.teams = {[0] = 0, 0, 0, 0, 1, 1, 1, 1}
    room.kills = {[0] = 0, 8, 6, 3, 6, 5, 5, 4}
    room.deaths = {[0] = 1, 4, 3, 7, 5, 5, 6, 4}
    room.assists = {[0] = 6, 4, 5, 3, 3, 3, 7, 8}
    room.points = {[0] = 112, 214, 168, 96, 191, 155, 173, 149}
    match = {playing = false, left = 15, artifact = 1,
             score = {[0] = 17, [1] = 20}}
end

-- Turf, part way through: six stands, four of them claimed, and a score that
-- has been paid a while. The picture is the point of it. The pennant strip was
-- pinned above where the room's line lands rather than under the band, which
-- put a staff through every numeral of the clock and made the score unreadable
-- in the two zones that have flags; every string was in the right place and in
-- the right order while it did, which is the fault this tool exists for.
if scenario == "turf" then
    room.count = 8
    room.teams = {[0] = 0, 0, 0, 0, 1, 1, 1, 1}
    match = {playing = true, left = 158, score = {[0] = 7, [1] = 16}}
    flags = {{2990, 2990, 0, 0}, {3010, 2990, 0, 0}, {3030, 2990, 255, 0},
             {3050, 2990, 1, 0}, {3070, 2990, 1, 0}, {3090, 2990, 255, 0}}
end

-- A duel, which is the one zone whose row carries no score: one clean kill
-- takes a match, so it would read nil to nil the whole way, and what the two
-- sides are is the two pilots. See decision 163.
if scenario == "duel" then
    room.count = 2
    room.teams = {[0] = 0, 1}
    match = {playing = true, left = 97, score = {[0] = 0, [1] = 0}}
end

-- Free Roam, which is the one zone that puts prizes on the ground, so it is
-- the one frame that can show what a dial holds when they are out. Sown six
-- to twenty-eight tiles from a live pilot, which is the ring the zone uses
-- and the reason a green is meant to land on somebody's radar: these sit
-- where that ring puts them, in tiles off the camera.
if scenario == "roam" then
    -- And the one zone that sends no match at all, which is what the row
    -- reads off to count the room instead of drawing a clock and two scores.
    match = nil
    local function green(tx, ty, slot)
        greens[#greens + 1] = {3000 + tx * 16, 3000 + ty * 16, slot}
    end
    green(9, -6, 1)
    green(-14, 8, 19)
    green(22, 17, 2)
    green(-7, -21, 5)
    green(26, -12, 12)
    green(-24, -3, 0)
    green(13, 27, 20)
end

-- Four frames of the front end: the stops closed, and each of the three
-- lists down.
local in_menu = scenario == "menu" or scenario == "menu-settings"
    or scenario == "menu-side" or scenario == "menu-zone"
local watching = scenario == "watching" or scenario == "watching-zones"
    or scenario == "watching-ships" or scenario == "watching-account"
    or scenario == "watching-login"
if watching then
    room.count = 8
    room.teams = {[0] = 0, 0, 0, 0, 1, 1, 1, 1}
    match = {playing = true, left = 107, score = {[0] = 3, [1] = 5}}
end
-- The column's stops, as the arena builds them: the call sign and what its
-- list holds, the games with their one-line formats, and the ships.
-- The ship stop's panel, as `menu.ship_panel` builds one.
--
-- A fixture the way the zones and the account rows above are: `arena.menu`
-- wants the engine and a meta-layer before it will load, which is more world
-- than a picture needs. The shape is that function's, the labels and notes
-- are `menu.tune_rows`, and the ceilings are what `sim_slot_cap` answers for
-- an Apex, so the row a credit can move is drawn live and one it cannot is
-- drawn dim.
--
-- This was a list of hull names, and had been since the stop stopped opening
-- one, so the picture showed an empty stop and nobody could see that the gun
-- and bomb Rung rows had gone missing from it.
local function slot_row(slot, label, note, value, cap, free, reads)
    return {kind = "slot", slot = slot, label = label, note = note,
            value = value, cap = cap, toggle = cap == 1,
            -- What the row reads at, where that is not its own count. The
            -- menu sets this off the core; here it is passed in, and the one
            -- row that wants it is shrapnel.
            reads = reads,
            can_up = value < cap and free >= 1, can_down = value > 0}
end

local function ship_panel()
    -- The Apex: one credit of spray, one of shrapnel, two repels and a
    -- burst, which leaves two of the seven in hand. The shrapnel rung is
    -- spent on purpose: it is the one row that reads out something other
    -- than what it cost, and at nought there is nothing to see.
    local free = 2
    return {
        at = 0, pages = 8, watching = false, class = 0,
        label = "Apex", detail = "dart",
        bars = {0.95, 0.62, 0.55, 0.28, 0.44},
        free = free, credits = 7, mine = true,
        rows = {
            {kind = "sect", label = "gun"},
            slot_row(5, "Rung",
                     "Which gun off this hull's own ladder it fires.",
                     0, 2, free),
            slot_row(7, "Spray",
                     "How many rounds one pull of the trigger throws.",
                     1, 5, free),
            slot_row(8, "Bounce",
                     "Rounds come off walls instead of ending on them.",
                     0, 1, free),
            slot_row(11, "Freeze",
                     "What a round hits stops recharging for a moment.",
                     0, 1, free),
            {kind = "sect", label = "bomb"},
            slot_row(6, "Rung",
                     "Which bomb off this hull's own ladder it throws.",
                     0, 2, free),
            slot_row(14, "Bounce",
                     "The bomb comes off walls instead of ending on them.",
                     0, 1, free),
            slot_row(15, "Proximity detonation",
                     "A fuse, so a near miss counts.", 0, 1, free),
            slot_row(16, "Shrapnel",
                     "Fragments thrown by the blast, each carrying the "
                     .. "gun's damage.", 1, 3, free,
                     _G.sim.splinter_count(1)),
            slot_row(17, "Freeze",
                     "The blast stops whoever it catches recharging.",
                     0, 1, free),
            {kind = "sect", label = "rack"},
            slot_row(19, "Repel",
                     "A push that answers rounds already on their way to "
                     .. "you.", 2, 3, free),
            slot_row(20, "Burst",
                     "A ring of rounds thrown out around you.", 1, 2, free),
            {kind = "reset", label = "Reset", on = false},
        },
    }
end

local land = watching and {
    name = "Kestrel 8",
    zone = "Team Battle",
    ship = "Gunner",
    zones = {
        {label = "Team Battle", zone = "melee", live = true,
         format = "4v4 · 3:00", here = true},
        -- A second game, so the picture can show a row you are already in and
        -- a row under the cursor at once. Those are the two states a row has
        -- and one row could only ever be in one of them.
        {label = "Duel", zone = "duel", live = true, format = "1v1"},
        -- And a third nothing is serving, which is the row that dims and
        -- wears the dial that is looking for an arena. It is a state a row
        -- has and neither of the two above can be in, so without it the
        -- picture cannot show what a fleet with a game down looks like.
        {label = "Capture the Flag", zone = "war", live = false,
         format = "4v4"},
    },
    -- What the ship stop opens: one hull with its flight and its credits,
    -- and the rows those credits go on. `menu.ship_panel` builds it, driven
    -- by the roster the core actually ships, so the picture is the real
    -- panel rather than a list written here. It was a list written here, and
    -- had been since the stop stopped opening one, which is why nobody could
    -- see that the gun and bomb Rung rows had gone.
    panel = ship_panel(),
    -- A guest with a game behind them: the offer, the reroll, and the way
    -- onto an account that already exists. See `menu.account_rows`.
    account = {
        {label = "sign up", act = "claim", offer = true,
         note = "keep your points"},
        {label = "new name", act = "reroll"},
        {rule = true},
        {label = "log in", act = "enter_login"},
    },
    warn = true,
} or nil
-- Which stop is standing open, if any. This was `ui.land_open` for a while,
-- which is a field the interface has never had: the three scenarios that open
-- a stop all quietly drew the closed column instead, and a tool that draws
-- the wrong picture without saying so is worse than one that fails.
ui.col_open = (scenario == "watching-zones" and "zone")
    or (scenario == "watching-ships" and "ship")
    -- The log-in panel stands over the account panel it was raised from,
    -- which is what makes it a picture of the stack rather than of a card.
    or ((scenario == "watching-account" or scenario == "watching-login")
        and "account") or nil

-- And a row under the cursor on the stop that is open, because a panel drawn
-- with nothing lit leaves out the one part of a row most worth looking at.
-- The field says where a press would land, and it was drawn short of the
-- glass on both sides for a while with no picture here that would have shown
-- it.
if scenario == "watching-zones" then
    ui.col_sel, ui.col_sel_value = "land_pick_zone", "duel"
elseif scenario == "watching-ships" then
    ui.col_sel, ui.col_sel_value = "land_kit_row", 16
elseif scenario == "watching-account" then
    ui.col_sel, ui.col_sel_value = "land_pick_account", 1
end

ui.details = true
state.n = 0
-- The ending's bar arrives over a third of a second off the frame clock, so a
-- single still frame at time zero draws it empty. Backdated, which is what a
-- picture of the settled screen wants.
if ending then ui.podium_at, ui.podium_artifact = -1, 1 end
ui.begin(layer, W, H, 1, false, 0)

-- Before a room answers. Not a HUD at all: the loader's picture, held by the
-- engine until the stands arrive, which is what the hand-off lands on.
if scenario == "waiting" then
    -- Silent, which is the normal case: a wait of a couple of seconds says
    -- nothing and the line is kept for a fleet that is not there.
    ui.waiting(nil)
else
ui.hud({
    me = 0,
    -- A watcher's camera stands behind a hull that is not yours.
    watch = watching and {subject = 0} or nil,
    -- Something is being read over the fight, so the instruments
    -- behind it stand down: glyphs draw over every mesh, so a label
    -- is quieted where it is written or not at all.
    card = (scenario == "watching-login") or nil,
    side = 0,
    viewer_name = scenario == "ending" and "DRiFT" or "Kestrel 8",
    class_names = {"Apex", "Wedge", "Chord", "Anvil", "Facet", "Cipher", "Lattice"},
    menu_open = in_menu,
    pilots = (watching or scenario == "ending") and (function()
        local out = {}
        local names = ending
            and {"DRiFT", "Gantry", "Bellwether", "Ozone",
                 "Carrack", "Isobar", "Cirrus", "Jackstay"}
            or {"Krait 4", "Vireo 9", "Saber 3", "Plinth 41",
                "Mantis 7", "Halcyon 2", "Sable 09", "Orrery 3"}
        for i = 0, 7 do
            out[i] = {name = names[i + 1],
                      label = i % 2 == 0 and "unknown" or "bot",
                      ai = i % 2 == 1}
        end
        return out
    end)() or {
        -- The seat's own side, which the row reads in the one zone that
        -- names its sides by the pilots on them.
        [0] = {name = "Kestrel 8", label = "unknown", tier = "Wing", games = 41,
               team = 0},
        [1] = {name = "Ozone 12", label = "bot", ai = true, tier = "Ace",
               games = 900, team = 1},
    },
    -- A rating a seat, since the row carries the viewer's own all match and
    -- the sheet at the whistle carries the room's.
    ratings = ending and {[0] = 1494, 1620, 1408, 1377,
                          1551, 1502, 1466, 1439}
              or watching and {}
              or {[0] = 1183.4, [1] = 1346.6},
    -- What the whistle latched, which the row and the sheet both subtract
    -- from the live figure to say what this match has been worth.
    rated_from = ending and {[0] = 1500, 1611, 1413, 1382,
                             1542, 1497, 1461, 1440}
                 or watching and {}
                 or {[0] = 1189.4, [1] = 1346.6},
    watchers = nil,
    teams = {},
    match = match,
    side_names = (watching or scenario == "ending")
                 and {[0] = "Pylon", [1] = "Caisson"}
                 or (scenario == "turf" and {[0] = "Keel", [1] = "Vantage"})
                 or {[0] = "Pilot", [1] = "Rival"},
    feed = {},
    hurt = 0,
    charges = scenario == "loadout"
        and {{name = "repel", short = "RPL", count = 2, max = 3},
             {name = "burst", short = "BST", count = 1, max = 2}}
        or {},
    cam_x = 3000, cam_y = 3000,
    half_w = W / 2, half_h = H / 2,
    banner = banner,
    lag_notice = "",
    rtt = 22,
    zone = (scenario == "roam" and "roam")
           or (scenario == "duel" and "duel") or "melee",
    room = 1,
    fps = 60, frame_ms = 16.7, rx_rate = 31000, tx_rate = 700,
})
end
-- What an account act opens: the log-in panel, over the account panel it was
-- pressed from. Drawn after everything else, which is where the arena's own
-- frame loop draws it, and it clears every box published before it.
if scenario == "watching-login" then
    ui.land_card({
        head = "Log in.",
        keys = {{label = "log in", act = "do_login"}, {label = "cancel"}},
        sel = 1, field = 1,
        fields = {{label = "call sign", value = "Vesper 412",
                   kind = "username", max = 24},
                  {label = "password", value = "hunter2", mask = true,
                   kind = "current-password", max = 64}},
    })
end
-- The column over a watched room, which is what a client that has just opened
-- is looking at: five stops over a breathing key, and whatever one of them
-- opened. The payload is `menu.view()`'s, written out here for the same reason
-- the in-match one below is.
--
-- The table above it was handed to `ui.hud` for years and read by nothing:
-- the column is `ui.menu`'s, so a picture that only drew the HUD was a picture
-- of the screen with the whole front of it missing. It is drawn here now.
if watching then
    local open = (scenario == "watching-zones" and "zone")
        or (scenario == "watching-ships" and "ship")
        or ((scenario == "watching-account" or scenario == "watching-login")
            and "account") or nil
    local rows = {}
    if open == "zone" then
        for i, z in ipairs(land.zones) do
            rows[i] = {label = z.label, named = true, note = z.format,
                       mark = z.here, dim = not z.live, waiting = not z.live,
                       index = i}
        end
    elseif open == "account" then
        for i, a in ipairs(land.account) do
            rows[i] = {label = a.label, note = a.note, offer = a.offer,
                       rule = a.rule, index = i}
        end
    end
    ui.menu({
        open = true, key = "play", at = open, page = open,
        depth = open and 1 or nil,
        pilot = {name = land.name},
        stops = {
            {stop = "account", label = "account", value = land.name,
             named = true, warn = land.warn, open = open == "account"},
            {stop = "zone", label = "zone", value = land.zone, named = true,
             open = open == "zone"},
            {stop = "players", label = "players", value = "watching"},
            {stop = "ship", label = "ship", value = land.ship, named = true,
             open = open == "ship"},
            {stop = "settings", label = "settings"},
        },
        rows = rows,
        panel = open == "ship" and land.panel or nil,
    })
end
-- The in-match column, drawn after the HUD the way the arena's frame loop
-- draws it: three stops over a breathing key, and whatever one of them opened.
-- `menu.view()` is the payload, written out here rather than driven through
-- menu.lua, which wants an account, a directory and a socket to answer.
if in_menu then
    local open = scenario ~= "menu"
    local side = scenario == "menu-side"
    local zone = scenario == "menu-zone"
    local at = (side and "side") or (zone and "zone") or "settings"
    ui.menu({
        open = true,
        at = at,
        page = open and at or nil,
        depth = open and 1 or nil,
        -- The four stops `menu.stops` builds. LEAVE SEAT stood here until
        -- decision 136 took it out: leaving is choosing another game off the
        -- zone stop, which is why that stop heads the column.
        stops = {
            {stop = "zone", label = "zone", value = "Team Battle",
             named = true, open = zone},
            {stop = "ship", label = "ship", value = "Wedge", named = true},
            {stop = "settings", label = "settings",
             open = open and not side and not zone},
            {stop = "side", label = "side", value = "Pylon", named = true,
             open = side},
        },
        rows = open and (zone and {
            -- The games list, as `menu.zone_rows` builds it and `M.menu`
            -- turns it into the column's own kind of list: the format at the
            -- right end, a mark on the one you are in, and a game the fleet is
            -- not serving dimmed with the dial that is looking for an arena
            -- beside its format.
            {label = "Team Battle", named = true, note = "4v4 · 3:00",
             mark = true, index = 0, pick = true},
            {label = "Duel", named = true, note = "1v1 · 3:00",
             index = 1, pick = true},
            {label = "Capture the Flag", named = true, note = "4v4",
             dim = true, waiting = true, index = 2, pick = true},
        } or side and {
            {label = "Pylon", detail = "4 pilots", named = true,
             mark = true, tint = 0, index = 0},
            {label = "Caisson", detail = "4 pilots", named = true,
             tint = 1, index = 1},
        } or {
            -- The settings page as `menu.lua` builds it: one run of rows,
            -- with nothing banding them.
            {label = "Sound", choice = 2, choices = 3,
             detail = "half", pick = true},
            {label = "Music", choice = 2, choices = 3, detail = "half",
             pick = true},
            {label = "Frames", choice = 1, choices = 3,
             detail = "display", pick = true},
            {label = "Fullscreen", detail = "fill the screen"},
            {label = "Controls", detail = "keys"},
            {label = "About", detail = "this build"},
        }) or {},
    })
end
ui.finish()

-- --- out --------------------------------------------------------------------

local o = {}
local nfade = 0
local function w(s) o[#o + 1] = s end
local function esc(s)
    s = string.gsub(s, "&", "&amp;")
    s = string.gsub(s, "<", "&lt;")
    s = string.gsub(s, ">", "&gt;")
    return s
end

w(string.format('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" '
                .. 'viewBox="0 0 %d %d" font-family="DejaVu Sans Mono, Menlo, '
                .. 'Consolas, monospace">', W, H, W, H))
-- The arena behind it. The real one is a starfield and a map; this is the
-- ground color, so the panels read as panels.
w(string.format('<rect width="%d" height="%d" fill="#05070c"/>', W, H))

for _, s in ipairs(shapes) do
    local c, a = col_of(s.col)
    if s.fade then a = a * s.fade end
    if s.k == "rect" then
        w(string.format('<rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" '
                        .. 'fill="%s" fill-opacity="%.3f"/>',
                        s.x, fy(s.y + s.h), s.w, s.h, c, a))
    elseif s.k == "frame" then
        w(string.format('<rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" '
                        .. 'fill="none" stroke="%s" stroke-opacity="%.3f" '
                        .. 'stroke-width="%.2f"/>',
                        s.x, fy(s.y + s.h), s.w, s.h, c, a, s.t or 1))
    elseif s.k == "seg" then
        w(string.format('<line x1="%.2f" y1="%.2f" x2="%.2f" y2="%.2f" '
                        .. 'stroke="%s" stroke-opacity="%.3f" stroke-width="%.2f" '
                        .. 'stroke-linecap="%s"/>',
                        s.x1, fy(s.y1), s.x2, fy(s.y2), c, a, s.w or 1, s.cap))
    elseif s.k == "skirt" then
        -- A falloff off one edge. Drawn as a faint band so the panel edges
        -- keep the glow they have, without pretending to be a gradient mesh.
        w(string.format('<line x1="%.2f" y1="%.2f" x2="%.2f" y2="%.2f" '
                        .. 'stroke="%s" stroke-opacity="%.3f" stroke-width="%.2f"/>',
                        s.x1, fy(s.y1), s.x2, fy(s.y2), c, a * (s.a or 0.07) * 2,
                        math.max(1, math.abs(s.dx or 0) / 6)))
    elseif s.k == "poly" or s.k == "outline" then
        local pts = {}
        for i = 1, #s.p, 2 do
            pts[#pts + 1] = string.format("%.2f,%.2f", s.p[i], fy(s.p[i + 1]))
        end
        if s.k == "poly" then
            w(string.format('<polygon points="%s" fill="%s" fill-opacity="%.3f"/>',
                            table.concat(pts, " "), c, a))
        else
            w(string.format('<polyline points="%s" fill="none" stroke="%s" '
                            .. 'stroke-opacity="%.3f" stroke-width="%.2f" '
                            .. 'stroke-linejoin="round"/>',
                            table.concat(pts, " "), c, a, s.w or 1))
        end
    elseif s.k == "fade" then
        -- The tapered quad the mesh builds, with the alpha ramp along it.
        local dx, dy = s.x2 - s.x1, s.y2 - s.y1
        local l = math.sqrt(dx * dx + dy * dy)
        if l > 1e-6 then
            local nx, ny = -dy / l, dx / l
            nfade = nfade + 1
            local cc = s.col or {1, 1, 1, 1}
            local function ch(v)
                return math.max(0, math.min(255, math.floor((v or 0) * 255 + 0.5)))
            end
            w(string.format(
                '<defs><linearGradient id="fade%d" '
                .. 'gradientUnits="userSpaceOnUse" x1="%.2f" y1="%.2f" '
                .. 'x2="%.2f" y2="%.2f">'
                .. '<stop offset="0" stop-color="rgba(%d,%d,%d,%.3f)"/>'
                .. '<stop offset="1" stop-color="rgba(%d,%d,%d,%.3f)"/>'
                .. '</linearGradient></defs>',
                nfade, s.x1, fy(s.y1), s.x2, fy(s.y2),
                ch(cc[1]), ch(cc[2]), ch(cc[3]), (cc[4] or 1) * (s.a1 or 1),
                ch(cc[1]), ch(cc[2]), ch(cc[3]), (cc[4] or 1) * (s.a2 or 1)))
            w(string.format(
                '<polygon points="%.2f,%.2f %.2f,%.2f %.2f,%.2f %.2f,%.2f" '
                .. 'fill="url(#fade%d)"/>',
                s.x1 + nx * s.w1 / 2, fy(s.y1 + ny * s.w1 / 2),
                s.x2 + nx * s.w2 / 2, fy(s.y2 + ny * s.w2 / 2),
                s.x2 - nx * s.w2 / 2, fy(s.y2 - ny * s.w2 / 2),
                s.x1 - nx * s.w1 / 2, fy(s.y1 - ny * s.w1 / 2), nfade))
        end
    elseif s.k == "halo" then
        nfade = nfade + 1
        w(string.format(
            '<defs><radialGradient id="fade%d">'
            .. '<stop offset="0" stop-color="%s" stop-opacity="%.3f"/>'
            .. '<stop offset="1" stop-color="%s" stop-opacity="0"/>'
            .. '</radialGradient></defs>'
            .. '<circle cx="%.2f" cy="%.2f" r="%.2f" fill="url(#fade%d)"/>',
            nfade, c, a, c, s.x, fy(s.y), s.r, nfade))
    elseif s.k == "disc" then
        w(string.format('<circle cx="%.2f" cy="%.2f" r="%.2f" fill="%s" '
                        .. 'fill-opacity="%.3f"/>', s.x, fy(s.y), s.r, c, a))
    elseif s.k == "ring" then
        w(string.format('<circle cx="%.2f" cy="%.2f" r="%.2f" fill="none" '
                        .. 'stroke="%s" stroke-opacity="%.3f" stroke-width="%.2f"/>',
                        s.x, fy(s.y), s.r, c, a, s.w or 1))
    elseif s.k == "arc" then
        local steps = 24
        local pts = {}
        for i = 0, steps do
            local t = s.a0 + (s.a1 - s.a0) * i / steps
            pts[#pts + 1] = string.format("%.2f,%.2f",
                s.x + math.cos(t) * s.r, fy(s.y + math.sin(t) * s.r))
        end
        w(string.format('<polyline points="%s" fill="none" stroke="%s" '
                        .. 'stroke-opacity="%.3f" stroke-width="%.2f"/>',
                        table.concat(pts, " "), c, a, s.w or 1))
    end
end

local ANCHOR = {left = "start", right = "end", center = "middle"}
for i = 1, state.n do
    local t = state.text[i]
    local c, a = col_of(t.col)
    if t.dim then a = a * t.dim end
    w(string.format('<text x="%.2f" y="%.2f" font-size="%.2f" fill="%s" '
                    .. 'fill-opacity="%.3f" text-anchor="%s" '
                    .. 'dominant-baseline="central" xml:space="preserve">%s</text>',
                    t.x, fy(t.y), t.px, c, a, ANCHOR[t.pivot] or "start",
                    esc(t.s)))
end
w("</svg>")

local f = assert(io.open(out_path, "w"))
f:write(table.concat(o, "\n"))
f:close()
print(string.format("%s: %d shapes, %d words -> %s",
                    scenario, #shapes, state.n, out_path))
