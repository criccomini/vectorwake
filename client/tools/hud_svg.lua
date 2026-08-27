-- Draw a HUD frame without an engine.
--
--     lua5.1 client/tools/hud_svg.lua <out.svg> [scenario] [root] [w] [h]
--
-- Scenarios: after (a Ladder run five rungs in), fresh (its first life), deep
-- (far enough to have a floor), before (with the banner the server used to
-- send), ending and duel-ending (a room at the whistle), landing (the front end,
-- watched from the stands; landing-zones and landing-ships open a stop's
-- list), waiting (what the loader hands off to before a
-- room answers), loadout (a loaded hull with charges in hand, for the corner
-- stack). Rasterize with any browser:
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
-- Worth having because a collision is invisible to a test that reads strings.
-- The Ladder readout grew past the ratings beside the clock once a run earned
-- a floor, which no assertion had thought to make and one look found.

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
function layer:arc(x, y, r, a0, a1, w, segs, col)
    shapes[#shapes + 1] = {k = "arc", x = x, y = y, r = r, a0 = a0, a1 = a1,
                           w = w, col = col}
end
function layer:outline(pts, w, col)
    shapes[#shapes + 1] = {k = "outline", p = pts, w = w, col = col}
end

-- --- the engine, as much of it as ui.lua touches ---------------------------

local room = {count = 2, teams = {[0] = 0, 1}}
_G.sim = {
    ship_count = function() return room.count end,
    ship_x = function(i) return 3000 + i * 180 end,
    ship_y = function(i) return 3000 + i * 120 end,
    ship_x_raw = function(i) return 3000 + i * 180 end,
    ship_y_raw = function(i) return 3000 + i * 120 end,
    ship_heading = function() return 0 end,
    ship_active = function() return 1 end,
    ship_alive = function() return 1 end,
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
    flag_count = function() return 0 end,
    flag_at = function() return 0, 0, 255 end,
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

local function leg(rung, result, kills, deaths, seconds)
    return {rung = rung, result = result, kills = kills, deaths = deaths,
            seconds = seconds}
end

-- A run five rungs in: three taken, one lost, one drawn, and back up.
local RUN = {
    leg(0, "cleared", 1, 0, 33),
    leg(1, "cleared", 1, 0, 58),
    leg(2, "drawn", 1, 1, 12),
    leg(2, "cleared", 1, 0, 71),
    leg(3, "lost", 0, 1, 9),
    leg(1, "cleared", 1, 0, 25),
    leg(2, "cleared", 1, 0, 44),
    leg(3, "cleared", 1, 0, 39),
}

local ladder = {
    rung = 4, streak = 4, checkpoint = 0,
    active_opponent = 4, desired_opponent = 4,
    opponent_ready = true, waiting = false, cleared = false,
    first_to = 1, legs = 8, log = RUN,
}

-- The frame from the screenshot: rung 5, streak 4, floor 1, 2:46 on the clock,
-- nobody dead yet.
local match = {playing = true, left = 166, score = {[0] = 0, [1] = 0},
               ladder = ladder}

-- The first life of a run, which is what every run opens on. Nothing behind
-- it: no streak, no floor above the ground, no legs to look back at.
if scenario == "fresh" then
    ladder.rung, ladder.streak, ladder.checkpoint = 0, 0, 0
    ladder.active_opponent, ladder.desired_opponent = 0, 0
    ladder.legs, ladder.log = 0, {}
    match.left = 180
end

-- A run deep enough to have a floor under it, so the readout says all three.
if scenario == "deep" then
    ladder.rung, ladder.streak, ladder.checkpoint = 7, 2, 5
    ladder.active_opponent, ladder.desired_opponent = 7, 7
    ladder.legs = 23
    match.left = 91
    match.score = {[0] = 0, [1] = 0}
end

-- What the old build put across the middle of the screen every second of
-- every life. The server sends it; the client draws whatever arrives.
local banner = ""
if scenario == "before" then
    banner = "Ladder rung 5: first to 1, 0 to 0"
end

-- The front end: a melee room watched from the stands, with the game's name
-- and PLAY NOW over the foot of it. Worth a scenario of its own because this
-- is the first screen anybody sees and it is the one made of two pieces laid
-- out by different code, the watcher's HUD and the lockup over the key, so
-- whether they collide is a question only a picture answers.
-- The whistle: a full melee room with the result up. This is the frame the
-- ending was redesigned against, and the one worth a picture, since it is the
-- board drawn in a column of its own with a head and a foot around it.
local ending = scenario == "ending" or scenario == "duel-ending"
if scenario == "duel-ending" then
    -- The same whistle in the mode that keeps a run: two rows and the fights
    -- behind them, which is the section the board adds for this zone.
    match = {playing = false, left = 8, artifact = 1,
             score = {[0] = 1, [1] = 0}, ladder = ladder}
end
if scenario == "ending" then
    room.count = 8
    room.teams = {[0] = 0, 0, 0, 0, 1, 1, 1, 1}
    room.kills = {[0] = 0, 8, 6, 3, 6, 5, 5, 4}
    room.deaths = {[0] = 1, 4, 3, 7, 5, 5, 6, 4}
    room.assists = {[0] = 6, 4, 5, 3, 3, 3, 7, 8}
    room.points = {[0] = 112, 214, 168, 96, 191, 155, 173, 149}
    match = {playing = false, left = 15, artifact = 1,
             score = {[0] = 17, [1] = 20}}
end

-- Three frames of the front end: the stops closed, the zone list down, the
-- ship list down.
local landing = scenario == "landing" or scenario == "landing-zones"
    or scenario == "landing-ships"
if landing then
    room.count = 8
    room.teams = {[0] = 0, 0, 0, 0, 1, 1, 1, 1}
    match = {playing = true, left = 107, score = {[0] = 3, [1] = 5}}
end
-- The landing's stops, as the arena builds them: the pilot, the games with
-- their one-line formats, and the builds with sitting out as the last row.
local land = landing and {
    name = "Kestrel 8",
    zone = "Team Battle",
    ship = "Gunner",
    zones = {
        {label = "Team Battle", zone = "melee", live = true,
         format = "4v4 · 3:00", here = true},
        {label = "Duel", zone = "ladder", live = true, format = "1v1"},
    },
    ships = {
        {label = "Gunner", value = 1, here = true},
        {label = "Bomber", value = 2},
        {label = "spectate", value = "spectate"},
    },
} or nil
ui.land_open = (scenario == "landing-zones" and "zone")
    or (scenario == "landing-ships" and "ship") or nil

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
    me = landing and 0 or 0,
    -- A watcher's camera stands behind a hull that is not yours, and the
    -- landing is a watch nobody deployed from.
    watch = landing and {subject = 0} or nil,
    landing = landing or nil,
    land = land,
    side = 0,
    viewer_name = scenario == "ending" and "DRiFT" or "Kestrel 8",
    class_names = {"Apex", "Wedge", "Chord", "Anvil", "Facet", "Cipher", "Lattice"},
    menu_open = false,
    pilots = (landing or scenario == "ending") and (function()
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
        [0] = {name = "Kestrel 8", label = "unknown", tier = "Wing", games = 41},
        [1] = {name = "Ozone 12", label = "bot", ai = true, tier = "Ace", games = 900},
    },
    ratings = (landing or scenario == "ending") and {}
              or {[0] = 1183.4, [1] = 1346.6},
    watchers = nil,
    teams = {},
    match = match,
    side_names = (landing or scenario == "ending")
                 and {[0] = "Pylon", [1] = "Caisson"}
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
    match_url = ending and "https://vectorwake.net/m/42" or nil,
    rtt = 22,
    link_bars = 4,
    zone = (landing or scenario == "ending") and "melee" or "ladder",
    room = 1,
    fps = 60, frame_ms = 16.7, rx_rate = 31000, tx_rate = 700,
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
