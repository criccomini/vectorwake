-- Every weapon mark the corner can draw, on one sheet, without an engine.
--
--     lua5.1 client/tools/marks_svg.lua <out.svg> [root]
--
-- Rasterize with any browser:
--
--     chromium --headless --screenshot=out.png --window-size=1200,1400 out.svg
--
-- It drives the real arena/marks.lua against a small SVG layer, the way
-- hud_svg.lua drives the whole interface, and exists for the same reason:
-- what a loadout does to a drawing is invisible to a test that measures
-- boxes, and the marks wear sixty-four combinations of add-ons. The sheet
-- draws the two rounds at every rung, every subset of the six add-ons on a
-- bomb, the depth ladders, the gun's loadouts, and the charges.
--
-- The marks ask the core two things a zone owns rather than the drawing:
-- sim.shrap_count, how many fragments a rung throws, and sim.spray_shape,
-- how many rounds a pull throws and how far apart. Both stub the shipped
-- baseline here: fragments double 2, 4, 8, and spray adds a round a rung at
-- seven and a half degrees for the pair and fifteen for the fan.

local out_path = assert(arg[1], "an output path")
local root = arg[2] or "client"
package.path = root .. "/?.lua;" .. package.path

-- --- a layer that writes SVG ------------------------------------------------

local H = 1560
local W = 1180
local body, defs, uid = {}, {}, 0

local function fy(y) return H - y end

local function rgba(c, a)
    local function ch(v)
        return math.max(0, math.min(255, math.floor((v or 0) * 255 + 0.5)))
    end
    return string.format("rgba(%d,%d,%d,%.3f)", ch(c[1]), ch(c[2]), ch(c[3]),
                         a or c[4] or 1)
end

local layer = {}

function layer:seg(x1, y1, x2, y2, w, col)
    body[#body + 1] = string.format(
        '<line x1="%.2f" y1="%.2f" x2="%.2f" y2="%.2f" stroke="%s" '
        .. 'stroke-width="%.2f" stroke-linecap="round"/>',
        x1, fy(y1), x2, fy(y2), rgba(col), w)
end

-- A fade is a tapered quad filled with a gradient along its own length,
-- which is what the mesh actually builds.
function layer:seg_fade(x1, y1, x2, y2, w1, w2, a1, a2, col)
    local dx, dy = x2 - x1, y2 - y1
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1e-6 then return end
    local nx, ny = -dy / len, dx / len
    uid = uid + 1
    local a = col[4] or 1
    defs[#defs + 1] = string.format(
        '<linearGradient id="f%d" gradientUnits="userSpaceOnUse" '
        .. 'x1="%.2f" y1="%.2f" x2="%.2f" y2="%.2f">'
        .. '<stop offset="0" stop-color="%s"/>'
        .. '<stop offset="1" stop-color="%s"/></linearGradient>',
        uid, x1, fy(y1), x2, fy(y2),
        rgba(col, a * a1), rgba(col, a * a2))
    body[#body + 1] = string.format(
        '<polygon points="%.2f,%.2f %.2f,%.2f %.2f,%.2f %.2f,%.2f" '
        .. 'fill="url(#f%d)"/>',
        x1 + nx * w1 / 2, fy(y1 + ny * w1 / 2),
        x2 + nx * w2 / 2, fy(y2 + ny * w2 / 2),
        x2 - nx * w2 / 2, fy(y2 - ny * w2 / 2),
        x1 - nx * w1 / 2, fy(y1 - ny * w1 / 2), uid)
end

function layer:disc(x, y, r, _, col)
    body[#body + 1] = string.format(
        '<circle cx="%.2f" cy="%.2f" r="%.2f" fill="%s"/>',
        x, fy(y), r, rgba(col))
end

function layer:ring(x, y, r, w, _, col)
    body[#body + 1] = string.format(
        '<circle cx="%.2f" cy="%.2f" r="%.2f" fill="none" stroke="%s" '
        .. 'stroke-width="%.2f"/>', x, fy(y), r, rgba(col), w)
end

-- Solid at the center, gone at the rim: a radial gradient is that exactly.
function layer:halo(x, y, r, _, col)
    uid = uid + 1
    defs[#defs + 1] = string.format(
        '<radialGradient id="f%d"><stop offset="0" stop-color="%s"/>'
        .. '<stop offset="1" stop-color="%s"/></radialGradient>',
        uid, rgba(col), rgba(col, 0))
    body[#body + 1] = string.format(
        '<circle cx="%.2f" cy="%.2f" r="%.2f" fill="url(#f%d)"/>',
        x, fy(y), r, uid)
end

function layer:arc(x, y, r, a0, a1, w, _, col)
    local steps, pts = 24, {}
    for i = 0, steps do
        local t = a0 + (a1 - a0) * i / steps
        pts[#pts + 1] = string.format("%.2f,%.2f", x + math.cos(t) * r,
                                      fy(y + math.sin(t) * r))
    end
    body[#body + 1] = string.format(
        '<polyline points="%s" fill="none" stroke="%s" stroke-width="%.2f"/>',
        table.concat(pts, " "), rgba(col), w)
end

-- --- the engine, as much of it as the marks touch ---------------------------

local ship = {level = {}, mods = {}, off = false}
_G.sim = {
    TRIG_GUN = 0,
    TRIG_BOMB = 1,
    shrap_count = function(n)
        if n <= 0 then return 0 end
        return 2 ^ math.min(n, 3)
    end,
    spray_shape = function(_, _, _, n)
        if n <= 0 then return 1, 0 end
        return n + 1, (n == 1) and (65536 / 48) or (65536 / 24)
    end,
    ship_level = function(_, t) return ship.level[t] or 0 end,
    ship_mod = function(_, t, i) return (ship.mods[t] or {})[i] or 0 end,
    ship_multi_off = function() return ship.off end,
}

local marks = require("arena.marks")
marks.begin(layer, 1)

-- --- the sheet --------------------------------------------------------------

local MONO = "DejaVu Sans Mono, Menlo, Consolas, monospace"

local function label(x, y, s, px, col)
    body[#body + 1] = string.format(
        '<text x="%.1f" y="%.1f" font-size="%d" fill="%s" '
        .. 'text-anchor="middle" font-family="%s">%s</text>',
        x, fy(y), px or 9, col or "#6c7a90", MONO, s)
end

local function head(x, y, s)
    body[#body + 1] = string.format(
        '<text x="%.1f" y="%.1f" font-size="12" fill="#9fb6d4" '
        .. 'letter-spacing="2" font-family="%s">%s</text>',
        x, fy(y), MONO, string.upper(s))
end

local K = 26
local MODS = {"spray", "bounce", "prox", "shrap", "freeze", "push"}

local y = H - 46

-- The two rounds at every rung: color is the rung and nothing else.
head(40, y, "the rounds, bare, rung 0 to 3")
y = y - 58
for lvl = 0, 3 do
    marks.round(90 + lvl * 120, y, K, true, lvl, {})
    marks.round(660 + lvl * 120, y, K, false, lvl, {})
end
label(270, y - 44, "gun")
label(840, y - 44, "bomb")

-- Every subset of the six add-ons on a bomb, one rung of each, at rung 1.
y = y - 92
head(40, y, "the bomb, every permutation of add-ons, one rung of each")
y = y - 66
for i = 0, 63 do
    local col_ = i % 8
    local row = math.floor(i / 8)
    local cx = 90 + col_ * 142
    local cy = y - row * 96
    local modn, names = {}, {}
    for b = 1, 6 do
        if math.floor(i / 2 ^ (b - 1)) % 2 == 1 then
            modn[b] = 1
            names[#names + 1] = MODS[b]
        end
    end
    marks.round(cx, cy, K, false, 1, modn)
    label(cx, cy - 44, #names == 0 and "bare" or table.concat(names, "+"), 8)
end
y = y - 7 * 96

-- The three add-ons whose depth changes the drawing, walked up their rungs.
y = y - 100
head(40, y, "depth: prox, shrap and spray climb their rungs")
y = y - 62
local depth = {
    {"prox", 3}, {"shrap", 3}, {"spray", 3},
}
local dx = 70
for _, d in ipairs(depth) do
    local slot
    for b, n in ipairs(MODS) do
        if n == d[1] then slot = b end
    end
    for n = 1, d[2] do
        local modn = {}
        modn[slot] = n
        marks.round(dx, y, K, false, 1, modn)
        label(dx, y - 44, d[1] .. " " .. n, 8)
        dx = dx + 116
    end
    dx = dx + 16
end

-- The gun's ladder of rounds, one bullet per rung climbed, at the angles
-- the core fires them; then bounce, freeze, and the declined fan, which
-- only the ship path can draw.
y = y - 104
head(40, y, "the gun: 1 to 5 bullets, then bounce, freeze, a declined fan")
y = y - 62
local gun_loads = {
    {"1 round", {}},
    {"spray 1: 2", {[0] = 1}},
    {"spray 2: 3", {[0] = 2}},
    {"spray 3: 4", {[0] = 3}},
    {"spray 4: 5", {[0] = 4}},
    {"fan+bounce", {[0] = 2, [1] = 1}},
    {"freeze 2", {[4] = 2}},
}
dx = 80
for _, g in ipairs(gun_loads) do
    ship.level = {[0] = 2}
    ship.mods = {[0] = g[2]}
    marks.weapon(dx, y, K, 0, 0)
    label(dx, y - 44, g[1], 8)
    dx = dx + 138
end
ship.level = {[0] = 2}
ship.mods = {[0] = {[0] = 2, [1] = 1}}
ship.off = true
marks.weapon(dx, y, K, 0, 0)
label(dx, y - 44, "fan declined", 8)
ship.off = false

-- The charges, in their own colors: gold is the charge color, violet the
-- burst's rounds, and the disc is the fallback for a slot with no mark.
y = y - 104
head(40, y, "the charges")
y = y - 62
local pal = require("arena.palette")
marks.charge(0, 90, y, 20, pal.a(pal.CHARGE_COL, 0.85))
label(90, y - 44, "repel", 8)
marks.charge(1, 220, y, 20, pal.a(pal.BURST, 0.85))
label(220, y - 44, "burst", 8)
marks.charge(2, 350, y, 20, pal.a(pal.CHARGE_COL, 0.85))
label(350, y - 44, "fallback", 8)

-- --- out --------------------------------------------------------------------

local f = assert(io.open(out_path, "w"))
f:write(string.format(
    '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" '
    .. 'viewBox="0 0 %d %d">\n<rect width="%d" height="%d" '
    .. 'fill="#05070c"/>\n<defs>%s</defs>\n%s\n</svg>\n',
    W, H, W, H, W, H, table.concat(defs, "\n"), table.concat(body, "\n")))
f:close()
print(string.format("%d shapes -> %s", #body, out_path))
