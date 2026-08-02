-- The interface.
--
-- This is a transcription of `client-web/index.html`, which is the page this
-- game has actually been looked at in, down to its panel geometry and its
-- palette: fourteen pixels of margin, a translucent near-black panel behind a
-- one-pixel border, thirteen-pixel monospace, scores top left, radar top
-- right, feed under it, your own status bottom left, controls along the
-- bottom. The production client has no business looking like a different
-- game than the prototype everyone has already seen.
--
-- Shapes go into the `vwui` mesh layer in screen pixels. Text is appended to
-- the shared list that ui/vwui.gui_script draws, because glyphs are the one
-- thing a bare mesh cannot do. Both use the same layout arithmetic, in this
-- file, so the two halves cannot drift apart.
--
-- Coordinates here are the ones a stylesheet would use: origin top left, y
-- downward. `ry` flips into the projection's bottom-left origin exactly once,
-- at the point of drawing.

local pal = require("arena.palette")
local state = require("arena.state")
local world = require("arena.world")

local M = {}

local W, H, S = 0, 0, 1
local u = nil          -- the ui mesh layer for this frame
local text, nt = nil, 0

-- Metrics, in CSS pixels before the density scale.
local PAD = 14
local PANEL_X, PANEL_Y = 12, 10
local FONT = 13
local LINE = 18
-- Two triggers, one line each in the status panel. Read once rather than
-- from `sim` per frame: the panel's height needs it before it draws.
local SIM_TRIGGERS = 2
local COL_W = 248      -- the width of the three stacked side panels
local RADAR = 168

M.hits = {}            -- clickable rectangles the menu published, top-left px

-- --- primitives ------------------------------------------------------------

local function ry(y, h)
    return H - y - (h or 0)
end

local function rect(x, y, w, h, col)
    u:rect(x, ry(y, h), w, h, col)
end

-- A panel: translucent fill under a hairline border, which is the whole of
-- the prototype's chrome.
local function panel(x, y, w, h)
    rect(x, y, w, h, pal.PANEL)
    u:frame(x, ry(y, h), w, h, S, pal.BORDER)
end

local function txt(s, x, y, px, col, pivot)
    nt = nt + 1
    local t = text[nt]
    if not t then t = {} text[nt] = t end
    t.s, t.x, t.y, t.px, t.col, t.pivot = s, x, H - y, px, col, pivot or "left"
end

-- The only way anything outside this file gets words on screen. Coordinates
-- are the stylesheet's: origin top left, y downward, and `y` is the middle of
-- the line rather than its top.
function M.line(s, x, y, px, col, pivot)
    txt(s, x, y, px, col, pivot)
end

-- A rectangle the pointer can land on, published in the same coordinates it
-- was drawn in. Defined up here with the other primitives because everything
-- that draws something clickable needs it, and it used to sit far enough down
-- the file that the first function to call it from above found nil.
local function hit(x, y, w, h, action, value)
    M.hits[#M.hits + 1] = {x = x, y = y, w = w, h = h,
                           action = action, value = value}
end

-- A keycap, the way the prototype's <kbd> reads: a boxed glyph in a line of
-- ordinary text. Returns the width it consumed.
local function kbd(x, y, label, h)
    local w = math.max(h * 0.72, #label * FONT * S * 0.62 + 8 * S)
    rect(x, y, w, h, pal.a(pal.BTN_BG, 0.9))
    u:frame(x, ry(y, h), w, h, S, pal.BAR_EDGE)
    txt(label, x + w / 2, y + h / 2, FONT * S, pal.INK, "center")
    return w
end

-- --- frame -----------------------------------------------------------------

-- True when the screen is too narrow for the desktop layout: three columns of
-- 248 points plus their margins want about 640, and a phone in portrait has
-- 390. Below that the scoreboard and the radar were drawn straight through
-- each other and the hull grid ran off both edges of the screen.
M.compact = false
M.touching = false

function M.begin(layer, w, h, density, touching)
    u, W, H = layer, w, h
    -- Points of screen rather than pixels: a phone at two device pixels per
    -- point is a small screen, not a large one, and laying the interface out
    -- against the pixel count is how it ends up drawn at half size on the
    -- device it most needs to be readable on.
    local points = w / math.max(density, 0.0001)
    M.compact = points < 620
    -- No global shrink. Dropping the scoreboard and reflowing the hull grid
    -- is what makes a phone fit; scaling the type down as well only made it
    -- unreadable on the device with the least room to spare. Panels are 248
    -- points wide and a narrow phone is 390, so one column always fits.
    S = density
    M.touching = touching or false
    text = state.text
    nt = 0
    u:reset()
    M.hits = {}
end

function M.finish()
    state.n = nt
    state.version = state.version + 1
    u:flush()
end

-- --- radar -----------------------------------------------------------------
--
-- A hundred and fifty tiles around you, which is the prototype's span and
-- about six screens across: far enough to see a fight starting, close enough
-- that a blip means something.

local function radar(cx, cy, me)
    local box = RADAR * S + 16 * S
    local x = W - PAD * S - box
    local y = PAD * S
    panel(x, y, box, box)
    local ix, iy = x + 8 * S, y + 8 * S
    local r = RADAR * S
    rect(ix, iy, r, r, pal.RADAR_BG)

    -- Sixty tiles out, so the reference arena nearly fills the dial. At a
    -- hundred and fifty it sat in the middle quarter with the rest of the
    -- radar showing empty space nobody can fly to.
    local SPAN = 60 * 16
    local k = r / (2 * SPAN)
    local function put(wx, wy)
        local px = ix + (wx - cx + SPAN) * k
        local py = iy + (wy - cy + SPAN) * k
        if px < ix or py < iy or px > ix + r or py > iy + r then return nil end
        return px, py
    end

    -- The map, in three passes so the things worth steering by sit on top of
    -- the walls rather than under them.
    -- One blip covers exactly the ground its sample stands for -- two tiles,
    -- the sampling stride -- so a wall reads as a wall. A fixed pixel size
    -- left gaps between samples and turned every wall into a dashed line.
    local dot = math.max(2 * 16 * k, 1.5 * S)
    local function blips(list, col, grow)
        local d = dot * (grow or 1)
        for n = 1, #list, 2 do
            local px, py = put(list[n], list[n + 1])
            if px then rect(px - d / 2, py - d / 2, d, d, col) end
        end
    end
    blips(world.radar_tiles, pal.RADAR_TILE)
    blips(world.radar_safe, pal.a(pal.RADAR_SAFE, 0.95))
    blips(world.radar_doors, pal.a(pal.RADAR_DOOR, 1.0), 1.15)

    -- Greens, under the flags and ships and over the terrain: a green is
    -- worth steering for, but never worth steering for instead of the pilot
    -- carrying thirty of them.
    --
    -- Read live rather than sampled into a list the way terrain is. Terrain
    -- can be cached because it does not move; a green appears, is taken, and
    -- times out, and a radar showing one that is already gone is worse than
    -- a radar showing none.
    --
    -- One about to expire is dimmed, for the same reason the world draw
    -- blinks it: the useful question is not "is there a green there" but "will
    -- it still be there when I arrive", and on the radar that is a question
    -- about somewhere half a screen away.
    for i = 0, sim.prize_count() - 1 do
        local active, wx, wy, life = sim.prize_at(i)
        if active then
            local px, py = put(wx, wy)
            if px then
                u:disc(px, ry(py, 0), 1.9 * S, 6,
                       pal.a(pal.PRIZE, life < 120 and 0.4 or 0.95))
            end
        end
    end

    local my_team = sim.ship_team(me)
    for i = 0, sim.flag_count() - 1 do
        local fx, fy, team = sim.flag_at(i)
        local px, py = put(fx, fy)
        if px then
            local col = (team == 255) and pal.INK
                or (team == my_team and pal.FRIEND or pal.ENEMY)
            -- A pennant rather than a bar: a flag should look like one even
            -- at four pixels.
            u:seg(px, ry(py + 3 * S, 0), px, ry(py - 3.5 * S, 0), S,
                  pal.a(col, 0.95))
            u:tri(px, ry(py - 3.5 * S, 0), px + 4 * S, ry(py - 2 * S, 0),
                  px, ry(py - 0.5 * S, 0), pal.a(col, 0.9))
        end
    end

    for i = 0, sim.ship_count() - 1 do
        if sim.ship_alive(i) == 1 and i ~= me then
            local px, py = put(sim.ship_x(i), sim.ship_y(i))
            if px then
                local friend = sim.ship_team(i) == my_team
                local col = friend and pal.FRIEND or pal.ENEMY
                -- A diamond over a soft halo: it reads at three pixels and
                -- separates from the square terrain at a glance.
                u:disc(px, ry(py, 0), 4.6 * S, 10, pal.a(col, 0.13))
                local d = 2.6 * S
                u:quad(px, ry(py - d, 0), px + d, ry(py, 0),
                       px, ry(py + d, 0), px - d, ry(py, 0), col)
            end
        end
    end

    -- You, last and as an arrow: on a radar the one thing worth knowing
    -- besides where you are is which way you are pointing.
    local px, py = put(sim.ship_x(me), sim.ship_y(me))
    if px then
        local a = (sim.ship_heading(me) / 65536) * math.pi * 2
        local dx, dy = math.sin(a), -math.cos(a)
        local nose, back, wide = 6.5 * S, 3.4 * S, 3.2 * S
        u:disc(px, ry(py, 0), 7 * S, 12, pal.a(pal.WHITE, 0.14))
        u:tri(px + dx * nose, ry(py + dy * nose, 0),
              px - dx * back - dy * wide, ry(py - dy * back + dx * wide, 0),
              px - dx * back + dy * wide, ry(py - dy * back - dx * wide, 0),
              pal.WHITE)
    end

end

-- Names, at each ship's lower right.
--
-- Screen space, because text is: the world is a mesh and glyphs come from a
-- gui font. The projection is the render script's -- a fixed world extent
-- across the shorter axis, centred on the camera -- so one number converts
-- between them and the two cannot drift.
local function nameplates(o)
    if not o.half_w or o.half_w <= 0 then return end
    -- The render script publishes its own half-extents for exactly this, so
    -- that nothing keeps a second copy of the projection. Deriving one from
    -- the view_tiles setting put every name adrift the moment the camera
    -- stopped being driven by that setting -- which it already had.
    local scale = W / (2 * o.half_w)
    local my_team = sim.ship_team(o.me)
    for i = 0, sim.ship_count() - 1 do
        -- Not your own. You know which ship is yours -- it is the one in the
        -- middle of the screen with the marker on it -- and a label saying so
        -- is a word following the thing you are actually looking at.
        if i ~= o.me and sim.ship_alive(i) == 1 then
            local sx = W / 2 + (sim.ship_x(i) - o.cam_x) * scale
            local sy = H / 2 + (sim.ship_y(i) - o.cam_y) * scale
            -- A name for a ship nobody can see is a name in the corner of
            -- the screen attached to nothing.
            if sx > -40 and sx < W + 40 and sy > -30 and sy < H + 30 then
                local p = o.pilots[i]
                local nm = (p and p.name) or ("ship " .. i)
                local col = (sim.ship_team(i) == my_team) and pal.FRIEND
                    or pal.ENEMY
                -- The bounty rides with the name, always. It is what killing
                -- them pays, so it is the one number that says which of two
                -- ships in front of you is worth the risk.
                local bty = sim.ship_bounty(i)
                txt(nm, sx + 12 * S, sy + 13 * S, 11 * S, pal.a(col, 0.7))
                if bty > 0 then
                    txt(tostring(bty), sx + 12 * S, sy + 25 * S, 11 * S,
                        pal.a(pal.BOUNTY, 0.85))
                end
            end
        end
    end
end

-- --- panels ----------------------------------------------------------------

local rows = {}

-- Where the scoreboard starts: under the menu chip when there is one, since
-- the chip owns the corner.
local function top_y()
    return PAD * S + 32 * S
end

local function scores(me, pilots)
    -- A phone has no room for a nine-row table beside the radar, and mid-fight
    -- it is the least useful thing on the screen. The feed still says who is
    -- killing whom.
    if M.compact then return 0 end
    local n = 0
    for i = 0, sim.ship_count() - 1 do
        n = n + 1
        local r = rows[n]
        if not r then r = {} rows[n] = r end
        r.i = i
        r.k = sim.ship_kills(i)
        r.d = sim.ship_deaths(i)
        r.p = sim.ship_points(i)
        local p = pilots[i]
        r.name = (p and p.name) or ("ship " .. i)
        r.ai = p and p.bot ~= nil
    end
    for i = n + 1, #rows do rows[i] = nil end
    -- By points, because points are the score. Kills stay on the row: they
    -- are what a player counts in their head, and the two numbers say
    -- different things -- a pilot who kills loaded ships outscores one who
    -- kills more of the empty.
    table.sort(rows, function(a, b)
        if a.p ~= b.p then return a.p > b.p end
        if a.k ~= b.k then return a.k > b.k end
        if a.d ~= b.d then return a.d < b.d end
        return a.name < b.name
    end)

    local shown = math.min(n, 9)
    if shown == 0 then return 0 end
    local w = COL_W * S
    local h = PANEL_Y * 2 * S + shown * LINE * S
    panel(PAD * S, top_y(), w, h)

    local my_team = sim.ship_team(me)
    local y = top_y() + PANEL_Y * S
    for i = 1, shown do
        local r = rows[i]
        local mine = r.i == me
        local col = mine and pal.WHITE
            or (sim.ship_team(r.i) == my_team and pal.FRIEND or pal.ENEMY)
        local name = string.sub(r.name, 1, 15)
        txt((mine and "▸ " or "") .. name .. (r.ai and "  AI" or ""),
            PAD * S + PANEL_X * S, y + LINE * S / 2, FONT * S, col)
        txt(r.k .. " / " .. r.d, PAD * S + w - PANEL_X * S - 44 * S,
            y + LINE * S / 2, FONT * S, pal.a(pal.DIM, 0.7), "right")
        txt(tostring(r.p), PAD * S + w - PANEL_X * S,
            y + LINE * S / 2, FONT * S, pal.DIM, "right")
        y = y + LINE * S
    end
    return h
end

-- The notification feed: kills, greens, flags. Newest first.
--
-- Bare. No panel: this is the one thing on screen that is already a list of
-- short lines, and a box around it is chrome around text that reads perfectly
-- well without one. Right-aligned so the edge that lines up is the one
-- against the screen, which is what the box used to provide.
--
-- Lines expire, and fade as they go. The arena owns the clock -- it is what
-- ages them -- so the lifetime lives here, where both halves can see it.
M.FEED_LIFE = 9
local FEED_FADE = 1.6

local function feed(lines, top)
    local shown = math.min(#lines, M.compact and 4 or 9)
    if shown == 0 then return end
    local right = W - PAD * S - PANEL_X * S
    local y = top + PANEL_Y * S
    for i = 1, shown do
        local f = lines[i]
        -- Older lines sit further back, and the last second and a half of a
        -- line's life is spent leaving.
        local a = 1 - (i - 1) * 0.07
        local left = M.FEED_LIFE - f.t
        if left < FEED_FADE then a = a * math.max(0, left / FEED_FADE) end
        txt(f.text, right, y + LINE * S / 2, FONT * S,
            pal.a(f.col or pal.DIM, a), "right")
        y = y + LINE * S
    end
end

local function status(me, class_names, netinfo, pickup, charges, lift)
    local emax = math.max(1, sim.ship_max_energy(me))
    -- Clamped, because energy is allowed to go far negative: a bomb overkills
    -- by whatever it overkills by, and the ship carries that until it
    -- respawns. The bar clamped and the number did not, so a fresh corpse
    -- read "energy -221614%".
    local frac = sim.ship_energy(me) / emax
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    local vx, vy = sim.ship_vel(me)
    local speed = math.sqrt(vx * vx + vy * vy) * 100 / 16

    local rows_h = LINE * S              -- name / score
    local bar_h = 6 * S
    -- Rows: the five stats, what each trigger carries, and the charges in
    -- hand when the hull has any.
    local slots = charges or {}
    local h = PANEL_Y * 2 * S + rows_h + 7 * S + bar_h + 6 * S + rows_h
              + rows_h + 5 * S + rows_h + SIM_TRIGGERS * rows_h
              + ((#slots > 0) and rows_h or 0)
    if pickup then h = h + rows_h end
    if netinfo then h = h + rows_h end

    local w = COL_W * S
    local x = PAD * S
    local y = H - PAD * S - h - (lift or 0)
    panel(x, y, w, h)

    local ix = x + PANEL_X * S
    local iw = w - PANEL_X * 2 * S
    local cy = y + PANEL_Y * S

    txt(class_names[sim.ship_class(me) + 1] or "?", ix, cy + rows_h / 2,
        FONT * S, pal.FRIEND)
    txt(sim.ship_kills(me) .. "k / " .. sim.ship_deaths(me) .. "d",
        ix + iw, cy + rows_h / 2, FONT * S, pal.INK, "right")
    cy = cy + rows_h + 7 * S

    -- Energy. The bar is the one element that has to be readable without
    -- being looked at, so it is the full width of the panel and it changes
    -- colour rather than only length.
    rect(ix, cy, iw, bar_h, pal.BAR_BG)
    u:frame(ix, ry(cy, bar_h), iw, bar_h, S, pal.BAR_EDGE)
    local bar_col = pal.FRIEND
    if frac < 0.2 then bar_col = pal.HURT
    elseif frac < 0.45 then bar_col = pal.ENEMY end
    if frac > 0 then
        rect(ix + S, cy + S, (iw - 2 * S) * math.min(1, frac), bar_h - 2 * S,
             bar_col)
    end
    cy = cy + bar_h + 6 * S

    txt("energy " .. math.floor(frac * 100 + 0.5) .. "%", ix, cy + rows_h / 2,
        FONT * S, frac < 0.2 and pal.HURT or pal.DIM)
    txt(string.format("%.1f tiles/s", speed), ix + iw, cy + rows_h / 2,
        FONT * S, pal.DIM, "right")
    cy = cy + rows_h

    -- What you have been paid, and what you are worth. Two different numbers
    -- and the second is the one everybody else can see.
    txt(sim.ship_points(me) .. " points", ix, cy + rows_h / 2, (FONT - 1) * S,
        pal.DIM)
    local bty = sim.ship_bounty(me)
    txt("worth " .. bty, ix + iw, cy + rows_h / 2, (FONT - 1) * S,
        bty > 0 and pal.BOUNTY or pal.a(pal.DIM, 0.5), "right")
    cy = cy + rows_h + 5 * S

    -- Upgrades, as the prototype shows them: every slot always present, so
    -- the row does not reflow as prizes are picked up, and the ones you do
    -- not hold sit there greyed as a list of what is out there to find.
    local gap = iw / #pal.UPGRADES
    for i, up in ipairs(pal.UPGRADES) do
        local held = sim.ship_up(me, i - 1)
        local label = held > 0 and (up.short .. "×" .. held) or up.short
        txt(label, ix + (i - 1) * gap, cy + rows_h / 2, (FONT - 1) * S,
            held > 0 and up.col or pal.a(pal.DIM, 0.45))
    end
    cy = cy + rows_h

    -- And what the two triggers are carrying. A level is the same weapon
    -- harder and an add-on changes its character, so they read differently:
    -- "gun 2" is a rung, "MUL" is a thing bolted on. Both are per trigger,
    -- which is the point of showing them as two lines rather than one list.
    for t = 0, SIM_TRIGGERS - 1 do
        local x = ix
        local lvl = sim.ship_level(me, t)
        local name = (t == sim.TRIG_GUN) and "gun" or "bomb"
        txt(name .. (lvl > 0 and (" " .. (lvl + 1)) or ""),
            x, cy + rows_h / 2, (FONT - 1) * S,
            lvl > 0 and pal.LEVEL_COL or pal.a(pal.DIM, 0.55))
        -- Clear of the widest label plus its rung: "bomb" and "gun 2" both
        -- have to fit before the first add-on chip lands.
        local at = x + 52 * S
        for m, mod in ipairs(pal.MODS) do
            local n = sim.ship_mod(me, t, m - 1)
            if n > 0 then
                txt(mod.short .. (n > 1 and ("×" .. n) or ""), at,
                    cy + rows_h / 2, (FONT - 2) * S, pal.MOD_COL)
                at = at + 30 * S
            end
        end
        cy = cy + rows_h
    end

    -- Charges: a count you spend, and one of them is the one the use key
    -- fires. The marker is what makes a single fire key work for four kinds.
    if #slots > 0 then
        local at = ix
        for _, c in ipairs(slots) do
            local label = (c.ready and "> " or "") .. c.short .. "x" .. c.count
            txt(label, at, cy + rows_h / 2, (FONT - 1) * S,
                c.count > 0 and (c.ready and pal.CHARGE_COL
                                 or pal.a(pal.CHARGE_COL, 0.6))
                or pal.a(pal.DIM, 0.45))
            at = at + 62 * S
        end
        cy = cy + rows_h
    end

    if pickup then
        txt((pickup.sign or "+") .. " " .. pickup.name, ix,
            cy + rows_h / 2, FONT * S, pal.a(pickup.col, pickup.t))
        cy = cy + rows_h
    end
    if netinfo then
        txt("online", ix, cy + rows_h / 2, FONT * S, pal.DIM)
        txt(netinfo, ix + iw, cy + rows_h / 2, FONT * S, pal.DIM, "right")
    end
end

local function help(lift)
    local h = 17 * S
    local y = H - PAD * S - h - (lift or 0)
    -- Naming keys to somebody holding a phone is worse than saying nothing:
    -- it describes controls their device does not have while the ones it does
    -- have sit unexplained on screen. The touch layer draws the stick and the
    -- pads; this says what they are.
    if M.touching or M.compact then
        txt("thumb left to steer     pads right to fire",
            W / 2, y + h / 2, FONT * S, pal.a(pal.DIM, 0.9), "center")
        return
    end
    -- Measured first so the row can be centred: a control hint that drifts
    -- off centre as its own contents change looks like a bug.
    local parts = {
        {k = "←"}, {k = "↑"}, {k = "↓"}, {k = "→"}, {s = " fly    "},
        {k = "space"}, {s = " guns    "}, {k = "shift"}, {s = " bombs    "},
        {k = "c"}, {s = " use    "}, {k = "v"}, {s = " swap    "},
        -- The one thing a new player has to be told, because nothing else on
        -- screen implies it: there is a menu, and this is where it lives.
        {k = "esc"}, {s = " menu"},
    }
    local total = 0
    for _, p in ipairs(parts) do
        if p.k then
            p.w = math.max(h * 0.72, #p.k * FONT * S * 0.62 + 8 * S) + 3 * S
        else
            p.w = #p.s * FONT * S * 0.62
        end
        total = total + p.w
    end
    local x = (W - total) / 2
    for _, p in ipairs(parts) do
        if p.k then
            kbd(x, y, p.k, h)
        else
            txt(p.s, x, y + h / 2, FONT * S, pal.a(pal.DIM, 0.9))
        end
        x = x + p.w
    end
end

-- The damage vignette: red creeping in from the edges rather than a flash
-- over the middle, so it never hides the ship that is shooting you.
local function vignette(amount)
    if amount <= 0.01 then return end
    local col = pal.a(pal.HURT, 0.55 * amount)
    local d = math.min(W, H) * 0.34
    local function band(x1, y1, x2, y2, x3, y3, x4, y4)
        u:tri_fade(x1, y1, 1, x2, y2, 1, x3, y3, 0, col)
        u:tri_fade(x1, y1, 1, x3, y3, 0, x4, y4, 0, col)
    end
    band(0, 0, W, 0, W - d, d, d, d)
    band(0, H, W, H, W - d, H - d, d, H - d)
    band(0, 0, 0, H, d, H - d, d, d)
    band(W, 0, W, H, W - d, H - d, W - d, d)
end

-- --- the flight interface --------------------------------------------------

-- The way into the menu, in the corner, on every device and every layout.
--
-- It was drawn only for touch and only on a narrow screen, which meant it
-- depended on two guesses -- that a touch had been seen, and that the screen
-- counted as small -- to be findable at all. On an emulated phone both came
-- out false and the menu had no way in but a key that phone does not have.
-- A button that must always work cannot be behind a test.
local function menu_button()
    local w, h = 62 * S, 26 * S
    -- The corner, on every layout. It used to dodge sideways when the
    -- scoreboard was drawn, which put it somewhere no thumb goes looking and
    -- made it depend on a width test to be findable at all.
    local x, y = PAD * S, PAD * S
    rect(x, y, w, h, pal.a(pal.BTN_BG, 0.92))
    u:frame(x, ry(y, h), w, h, S, pal.BAR_EDGE)
    txt("menu", x + w / 2, y + h / 2, FONT * S, pal.a(pal.INK, 0.92), "center")
    hit(x, y, w, h, "open")
end

function M.hud(o)
    if sim.ship_count() == 0 then return end
    local me = o.me

    -- On a touchscreen the bottom of the screen belongs to the thumbs. The
    -- stick sits in the bottom left corner and the pads in the bottom right,
    -- which is exactly where the status panel and the control hint were, so
    -- everything else moves up out of the way of them.
    local lift = M.touching and 150 * S or 0

    local top = scores(me, o.pilots)
    nameplates(o)
    radar(o.cam_x, o.cam_y, me)
    feed(o.feed, PAD * S + (RADAR + 16) * S + 12 * S)
    status(me, o.class_names, o.netinfo, o.pickup, o.charges, lift)
    menu_button()
    help(lift + (M.touching and 118 * S or 0))
    vignette(o.hurt or 0)

    -- The two big centred lines are the only interface that sits where the
    -- menu does. The panels can share the screen with it; these cannot.
    if o.menu_open then return end
    if o.banner and o.banner ~= "" then
        txt(o.banner, W / 2, 64 * S, (M.compact and 15 or 24) * S,
            pal.a(pal.INK, 0.92), "center")
    end
    if sim.ship_alive(me) == 0 then
        txt("D E S T R O Y E D", W / 2, H * 0.46, (M.compact and 15 or 22) * S,
            pal.ENEMY, "center")
    end
end

-- --- the start screen ------------------------------------------------------
--
-- The arena behind this is the real one, stepping the real simulation, which
-- is why there is no attract mode: a player who does nothing still watches a
-- fight rather than a title card.


-- A hull drawn small, inside its button. The silhouette is what picks a ship;
-- the name only confirms it.
local function thumb(cx, cy, cls, col, scale)
    local h = world.HULLS[cls + 1]
    if not h then return end
    local pts = {}
    for i = 1, #h.poly, 2 do
        pts[i] = cx + h.poly[i] * scale
        pts[i + 1] = ry(cy - h.poly[i + 1] * scale)
    end
    u:outline(pts, 1.4 * S, col)
end

-- The menu. One list, whatever level it is.
--
-- A title, a breadcrumb's worth of depth, rows, and a hint at the bottom. The
-- same routine draws the hull list and the settings, which is the point of
-- having a tree rather than a screen: adding a level costs a table in
-- menu.lua and nothing here.
--
-- It draws over a live arena, so the backdrop is translucent rather than
-- opaque -- you can see the fight you left, and that you are still in it.
local ROW_H = 34
local MENU_W = 460

function M.menu(v)
    local w = math.min(MENU_W * S, W - 24 * S)
    local x = (W - w) / 2
    local rows = #v.rows
    local h = ROW_H * S * rows + 76 * S
    local y = math.max(20 * S, (H - h) / 2)

    -- Not a curtain: dimmed enough to read against, clear enough to see the
    -- arena still running behind it. Opening the menu does not pause anything
    -- and should not look as though it does.
    rect(0, 0, W, H, pal.rgb(0x03050a, 0.62))
    panel(x, y, w, h)

    txt(v.title, x + 20 * S, y + 26 * S, (M.compact and 19 or 23) * S,
        pal.FRIEND)
    -- Always, not only below the root: a phone has no escape key, and a menu
    -- with no visible way out is a trap.
    txt(v.depth > 1 and "back" or "close", x + w - 20 * S, y + 26 * S, 11 * S,
        pal.a(pal.DIM, 0.8), "right")
    hit(x + w - 90 * S, y + 8 * S, 90 * S, 34 * S, "row", -1)

    local ry0 = y + 48 * S
    for i, r in ipairs(v.rows) do
        local top = ry0 + (i - 1) * ROW_H * S
        local on = i == v.sel
        if on and r.pick then
            rect(x + 8 * S, top, w - 16 * S, ROW_H * S,
                 pal.a(pal.BTN_SEL, 0.95))
            rect(x + 8 * S, top, 3 * S, ROW_H * S, pal.FRIEND)
        end
        local ink = r.pick and (on and pal.INK or pal.a(pal.INK, 0.72))
            or pal.a(pal.DIM, 0.9)
        local lx = x + 22 * S
        if r.hull then
            -- The silhouette is what picks a ship. Eight names mean nothing
            -- to somebody who has not flown them; eight shapes are the game
            -- telling you what it has.
            thumb(x + 34 * S, top + ROW_H * S / 2, r.hull,
                  on and pal.INK or pal.a(pal.INK, 0.55), 0.55 * S)
            lx = x + 58 * S
        end
        if r.label ~= "" then
            txt(r.label, lx, top + ROW_H * S / 2, FONT * S, ink)
        end
        if r.detail and r.detail ~= "" then
            -- The value sits on the right of the row it belongs to, which is
            -- how a settings list reads everywhere else in the world.
            txt(r.detail, x + w - 22 * S, top + ROW_H * S / 2, FONT * S,
                r.mark and pal.FRIEND or pal.a(pal.DIM, 0.95), "right")
        end
        if r.mark and not r.hull then
            txt("▸", x + 12 * S, top + ROW_H * S / 2, FONT * S, pal.FRIEND)
        end
        if r.pick then hit(x + 8 * S, top, w - 16 * S, ROW_H * S, "row", i) end
    end

    local by = y + h - 16 * S
    if v.note then
        txt(v.note, x + w / 2, by, FONT * S, pal.ENEMY, "center")
    else
        txt((M.touching or M.compact) and "tap a row    esc to close"
                or "↑ ↓ move    enter choose    esc back",
            x + w / 2, by, 11 * S, pal.a(pal.DIM, 0.8), "center")
    end
end

return M
