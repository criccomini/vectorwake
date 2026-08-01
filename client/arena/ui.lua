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
    u:frame(ix, ry(iy, r), r, r, S, pal.a(pal.BAR_EDGE, 0.8))

    local SPAN = 150 * 16
    local k = r / (2 * SPAN)
    local function put(wx, wy)
        local px = ix + (wx - cx + SPAN) * k
        local py = iy + (wy - cy + SPAN) * k
        if px < ix or py < iy or px > ix + r or py > iy + r then return nil end
        return px, py
    end

    local tiles = world.radar_tiles
    local dot = 2.2 * S
    for i = 1, #tiles, 2 do
        local px, py = put(tiles[i], tiles[i + 1])
        if px then rect(px, py, dot, dot, pal.RADAR_TILE) end
    end

    local my_team = sim.ship_team(me)
    for i = 0, sim.flag_count() - 1 do
        local fx, fy, team = sim.flag_at(i)
        local px, py = put(fx, fy)
        if px then
            local col = (team == 255) and pal.INK
                or (team == my_team and pal.FRIEND or pal.ENEMY)
            rect(px - 1.5 * S, py - 3 * S, 3 * S, 6 * S, pal.a(col, 0.9))
        end
    end

    for i = 0, sim.ship_count() - 1 do
        if sim.ship_alive(i) == 1 then
            local px, py = put(sim.ship_x(i), sim.ship_y(i))
            if px then
                local mine = i == me
                local col = mine and pal.WHITE
                    or (sim.ship_team(i) == my_team and pal.FRIEND or pal.ENEMY)
                local s = (mine and 5 or 4) * S
                rect(px - s / 2, py - s / 2, s, s, col)
            end
        end
    end
end

-- --- panels ----------------------------------------------------------------

local rows = {}

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
        local p = pilots[i]
        r.name = (p and p.name) or ("ship " .. i)
        r.ai = p and p.bot ~= nil
    end
    for i = n + 1, #rows do rows[i] = nil end
    table.sort(rows, function(a, b)
        if a.k ~= b.k then return a.k > b.k end
        if a.d ~= b.d then return a.d < b.d end
        return a.name < b.name
    end)

    local shown = math.min(n, 9)
    if shown == 0 then return 0 end
    local w = COL_W * S
    local h = PANEL_Y * 2 * S + shown * LINE * S
    panel(PAD * S, PAD * S, w, h)

    local my_team = sim.ship_team(me)
    local y = PAD * S + PANEL_Y * S
    for i = 1, shown do
        local r = rows[i]
        local mine = r.i == me
        local col = mine and pal.WHITE
            or (sim.ship_team(r.i) == my_team and pal.FRIEND or pal.ENEMY)
        local name = string.sub(r.name, 1, 15)
        txt((mine and "▸ " or "") .. name .. (r.ai and "  AI" or ""),
            PAD * S + PANEL_X * S, y + LINE * S / 2, FONT * S, col)
        txt(r.k .. " / " .. r.d, PAD * S + w - PANEL_X * S,
            y + LINE * S / 2, FONT * S, pal.DIM, "right")
        y = y + LINE * S
    end
    return h
end

local function feed(lines, top)
    local shown = math.min(#lines, M.compact and 4 or 9)
    if shown == 0 then return end
    local w = COL_W * S
    local h = PANEL_Y * 2 * S + shown * LINE * S
    local x = W - PAD * S - w
    panel(x, top, w, h)
    local y = top + PANEL_Y * S
    for i = 1, shown do
        txt(lines[i], x + PANEL_X * S, y + LINE * S / 2, FONT * S,
            pal.a(pal.DIM, 1 - (i - 1) * 0.07))
        y = y + LINE * S
    end
end

local function status(me, class_names, netinfo, pickup, lift)
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
    local h = PANEL_Y * 2 * S + rows_h + 7 * S + bar_h + 6 * S + rows_h
              + 5 * S + rows_h
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

    if pickup then
        txt("+ " .. pickup.name, ix, cy + rows_h / 2, FONT * S,
            pal.a(pickup.col, pickup.t))
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
        {k = "space"}, {s = " guns    "}, {k = "shift"}, {s = " bombs"},
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

function M.hud(o)
    if sim.ship_count() == 0 then return end
    local me = o.me

    -- On a touchscreen the bottom of the screen belongs to the thumbs. The
    -- stick sits in the bottom left corner and the pads in the bottom right,
    -- which is exactly where the status panel and the control hint were, so
    -- everything else moves up out of the way of them.
    local lift = M.touching and 150 * S or 0

    local top = scores(me, o.pilots)
    radar(o.cam_x, o.cam_y, me)
    feed(o.feed, PAD * S + (RADAR + 16) * S + 12 * S)
    status(me, o.class_names, o.netinfo, o.pickup, lift)
    help(lift + (M.touching and 118 * S or 0))
    vignette(o.hurt or 0)

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

local ROLES = {"interceptor", "bomber", "skirmisher", "heavy",
               "support", "stealth", "brawler", "denial"}
local MODES = {"launch", "duel"}

local function hit(x, y, w, h, action, value)
    M.hits[#M.hits + 1] = {x = x, y = y, w = w, h = h,
                           action = action, value = value}
end

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

function M.menu(o, names)
    local cx = W / 2
    rect(0, 0, W, H, pal.rgb(0x030509, 0.93))

    local BW, BH, GAP = 148 * S, 66 * S, 8 * S
    -- As many columns of hulls as the screen can hold. Four across is 616
    -- points, which a phone in portrait does not have and used to run off
    -- both edges with three of the eight hulls unreachable.
    local cols = 4
    while cols > 1 and BW * cols + GAP * (cols - 1) > W - 24 * S do
        cols = cols / 2
    end
    local rows = math.ceil(8 / cols)
    local grid_w = BW * cols + GAP * (cols - 1)
    local grid_h = BH * rows + GAP * (rows - 1)
    local FIELD_H = 30 * S
    local block = 40 * S + 12 * S + 2 * 18 * S + 26 * S + grid_h + 20 * S
                  + FIELD_H + 12 * S + 42 * S + 26 * S + 18 * S
    local y = math.max(12 * S, (H - block) / 2)

    txt("v e c t o r w a k e", cx, y + 20 * S, (M.compact and 25 or 34) * S,
        pal.FRIEND, "center")
    y = y + 40 * S + 12 * S
    if M.compact then
        txt("Energy is your health and your ammunition.",
            cx, y + 9 * S, FONT * S, pal.DIM, "center")
    else
        txt("Frictionless flight. Energy is your health and your ammunition.",
            cx, y + 9 * S, FONT * S, pal.DIM, "center")
    end
    y = y + 18 * S
    txt("Pick a hull and fight eight AI pilots.", cx, y + 9 * S, FONT * S,
        pal.DIM, "center")
    y = y + 18 * S + 26 * S

    local gx = cx - grid_w / 2
    for i = 0, 7 do
        local bx = gx + (i % cols) * (BW + GAP)
        local by = y + math.floor(i / cols) * (BH + GAP)
        local sel = i == o.class
        rect(bx, by, BW, BH, sel and pal.BTN_SEL or pal.BTN_BG)
        u:frame(bx, ry(by, BH), BW, BH, S, sel and pal.FRIEND or pal.BAR_EDGE)
        thumb(bx + 26 * S, by + BH / 2, i,
              sel and pal.FRIEND or pal.a(pal.DIM, 0.8), 0.9 * S)
        txt(names[i + 1] or "?", bx + 52 * S, by + 26 * S, FONT * S,
            sel and pal.INK or pal.a(pal.INK, 0.8))
        txt(ROLES[i + 1] or "", bx + 52 * S, by + 44 * S, 11 * S, pal.DIM)
        hit(bx, by, BW, BH, "class", i)
    end
    y = y + grid_h + 26 * S

    -- Name and server. Two fields side by side on a wide screen, stacked on
    -- a narrow one, because an address is long and a phone is not.
    local FW = math.min(grid_w, 460 * S)
    local fx = cx - FW / 2
    local stacked = M.compact or FW < 340 * S
    local nw = stacked and FW or FW * 0.34
    local sw = stacked and FW or FW - nw - 8 * S

    local function field(x, fy, w, key, label, value)
        local on = o.focus == key
        rect(x, fy, w, FIELD_H, on and pal.rgb(0x0a1620) or pal.BTN_BG)
        u:frame(x, ry(fy, FIELD_H), w, FIELD_H, S,
                on and pal.FRIEND or pal.BAR_EDGE)
        txt(label, x + 8 * S, fy + FIELD_H / 2, 11 * S, pal.DIM)
        local shown = value
        if value == "" then shown = on and "" or "-" end
        -- A caret, so a focused empty field does not look broken.
        if on then shown = shown .. "_" end
        txt(shown, x + 8 * S + 46 * S, fy + FIELD_H / 2, FONT * S,
            on and pal.INK or pal.a(pal.INK, 0.85))
        hit(x, fy, w, FIELD_H, "field", key)
    end

    field(fx, y, nw, "name", "NAME", o.name)
    if stacked then
        y = y + FIELD_H + 6 * S
        field(fx, y, sw, "server", "ZONE", o.server)
    else
        field(fx + nw + 8 * S, y, sw, "server", "ZONE", o.server)
    end
    y = y + FIELD_H + 12 * S

    -- Launch, duel, join and browse, in the prototype's colours: the primary
    -- action is a solid cyan block, the others outlines.
    local LW, DW, JW, BH2 = 124 * S, 96 * S, 100 * S, 42 * S
    local ZW = 106 * S
    local total = LW + DW + JW + ZW + 30 * S
    local three = total <= grid_w
    if not three then
        LW, DW, JW = grid_w, (grid_w - 8 * S) / 2, (grid_w - 8 * S) / 2
        ZW = grid_w
    end
    local bx = three and (cx - total / 2) or (cx - grid_w / 2)

    local launch = o.mode == 1
    rect(bx, y, LW, BH2, launch and pal.FRIEND or pal.BTN_BG)
    if not launch then
        u:frame(bx, ry(y, BH2), LW, BH2, S, pal.a(pal.FRIEND, 0.7))
    end
    txt("L A U N C H", bx + LW / 2, y + BH2 / 2, FONT * S,
        launch and pal.rgb(0x04121a) or pal.FRIEND, "center")
    hit(bx, y, LW, BH2, "go", 1)

    local dx, jy = bx + LW + 10 * S, y
    if not three then dx = bx jy = y + BH2 + 8 * S end
    rect(dx, jy, DW, BH2, o.mode == 2 and pal.rgb(0x1a1008) or pal.BTN_BG)
    u:frame(dx, ry(jy, BH2), DW, BH2, S,
            o.mode == 2 and pal.ENEMY or pal.rgb(0x3a2a1a))
    txt("D U E L", dx + DW / 2, jy + BH2 / 2, FONT * S, pal.ENEMY, "center")
    hit(dx, jy, DW, BH2, "go", 2)

    local jx = three and (dx + DW + 10 * S) or (dx + DW + 8 * S)
    rect(jx, jy, JW, BH2, o.mode == 3 and pal.rgb(0x08160f) or pal.BTN_BG)
    u:frame(jx, ry(jy, BH2), JW, BH2, S,
            o.mode == 3 and pal.FRIEND or pal.rgb(0x1d3a2a))
    txt("J O I N", jx + JW / 2, jy + BH2 / 2, FONT * S,
        pal.a(pal.FRIEND, 0.92), "center")
    hit(jx, jy, JW, BH2, "go", 3)

    -- Browse: the same address, asked what is running rather than joined
    -- outright. Without it the directory the server already speaks is
    -- reachable only by launching the client with a flag.
    local zx, zy = jx + JW + 10 * S, jy
    if not three then zx = bx zy = jy + BH2 + 8 * S end
    rect(zx, zy, ZW, BH2, o.mode == 4 and pal.rgb(0x0a1620) or pal.BTN_BG)
    u:frame(zx, ry(zy, BH2), ZW, BH2, S,
            o.mode == 4 and pal.FRIEND or pal.BAR_EDGE)
    txt("Z O N E S", zx + ZW / 2, zy + BH2 / 2, FONT * S,
        pal.a(pal.INK, 0.9), "center")
    hit(zx, zy, ZW, BH2, "go", 4)
    y = zy + BH2 + 26 * S

    -- Whatever the connection last had to say outranks the key hints: a
    -- player who just failed to reach a zone needs the reason, not a lesson
    -- in arrow keys.
    if o.note then
        txt(o.note, cx, y + 9 * S, FONT * S, pal.ENEMY, "center")
    else
        txt((M.touching or M.compact)
                and "tap a hull, then LAUNCH -- or type a zone and tap JOIN"
                or "← → hull   ↑ ↓ mode   enter launches   JOIN plays with others",
            cx, y + 9 * S, FONT * S, pal.a(pal.DIM, 0.85), "center")
    end
end

return M
