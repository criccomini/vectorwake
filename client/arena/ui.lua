-- The interface.
--
-- The layout came from the hand-written web prototype that preceded this
-- client, down to its panel geometry and its palette: fourteen pixels of
-- margin, a translucent near-black panel behind a one-pixel border,
-- thirteen-pixel monospace, scores top left, radar top right, feed under it,
-- your own status bottom left. That page is gone and this is where the
-- numbers survive, so they are worth reading as measurements rather than as
-- preferences.
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
local touch = require("arena.touch")
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
-- The scoreboard and your loadout, off until asked for. A guess about screen
-- size decided this before and got it backwards on the device it was written
-- for; see M.begin.
M.details = false

function M.begin(layer, w, h, density, touching)
    u, W, H = layer, w, h
    -- Points of screen rather than pixels: a phone at two device pixels per
    -- point is a small screen, not a large one, and laying the interface out
    -- against the pixel count is how it ends up drawn at half size on the
    -- device it most needs to be readable on.
    -- The *scarce* axis, not the width. This measured width alone, so a phone
    -- held in landscape -- 844 points wide and 390 tall, which is how anybody
    -- plays a game like this -- was classed as a large screen and got the
    -- full desktop interface stacked down a 390-point column. The tight
    -- dimension is the one that decides.
    local pw = w / math.max(density, 0.0001)
    local ph = h / math.max(density, 0.0001)
    local points = pw < ph and pw or ph
    M.compact = points < 480
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

-- How much vertical room the dial takes, so the feed under it can be told
-- rather than guess. Returned rather than duplicated: a second copy of this
-- arithmetic is how the pads and their own hit test drifted apart once.
function M.radar_span()
    return PAD * S * 2 + RADAR * S
end

local function radar(cx, cy, me)
    -- No panel and no inset. The dial is the most valuable thing on screen on
    -- a map a thousand tiles across and it keeps every pixel; what made it
    -- read as half a phone's height was the opaque box, the border and eight
    -- points of padding on each side, none of which is information.
    --
    -- A faint wash stays, because dots over a starfield are dots lost in a
    -- starfield -- but it is a wash rather than a panel.
    local r = RADAR * S
    local pad = (M.compact and 8 or PAD) * S
    local ix = W - pad - r
    local iy = pad
    rect(ix, iy, r, r, pal.a(pal.RADAR_BG, 0.55))

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

    -- Your own bounty, under your own hull, in the place and the colour every
    -- other ship carries theirs. It used to be a row in a corner panel, which
    -- asked you to look away to read the one number about you that everyone
    -- else reads without looking anywhere.
    local mine = sim.ship_bounty(o.me)
    if mine > 0 and sim.ship_alive(o.me) == 1 then
        txt(tostring(mine), W / 2 + 12 * S, H / 2 + 25 * S, 11 * S,
            pal.a(pal.BOUNTY, 0.85))
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
    -- Asked for, not assumed. Mid-fight this is the least useful thing on the
    -- screen and the feed still says who is killing whom, so it lives behind
    -- the same toggle your own loadout does.
    if not M.details then return 0 end
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
        -- The roster's own flag. This used to look for a local bot object,
        -- which the client no longer flies and the server never sends, so the
        -- column was blank for every AI in a zone full of them.
        r.ai = (p and p.ai) or false
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
    -- The bottom edge, not the height: what the loadout below needs to know
    -- is where this ends, and it does not start at the top of the screen.
    return top_y() + h
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

-- What is left of the status panel.
--
-- Energy is not here. Your own hull already carries the pip every other ship
-- carries -- same routine, same threshold -- so a bar and a percentage in a
-- corner were the same number drawn twice, in the place you are least likely
-- to be looking. Nor is your hull's name, which the silhouette says and you
-- chose; nor your speed, which nobody has ever made a decision on; nor your
-- kills, deaths and points, which are three scoreboard numbers.
--
-- What stays is what you cannot get anywhere else and need mid-fight: which
-- charge is ready and how many are in hand. On a touchscreen not even that,
-- because the pad draws it -- so the panel disappears entirely unless a green
-- was just taken or the netinfo line is up, and most of the time a phone
-- draws no panel at all.
local function status(me, netinfo, pickup, charges, lift)
    local slots = charges or {}
    -- The pad carries the marker on a touchscreen, so the row would be the
    -- same thing twice at opposite corners.
    local show_charges = #slots > 0 and not M.touching
    local rows_h = LINE * S
    local n = (show_charges and 1 or 0) + (pickup and 1 or 0) + (netinfo and 1 or 0)
    if n == 0 then return 0 end

    local h = PANEL_Y * 2 * S + n * rows_h
    local w = COL_W * S
    local x = PAD * S
    local y = H - PAD * S - h - (lift or 0)
    panel(x, y, w, h)

    local ix = x + PANEL_X * S
    local iw = w - PANEL_X * 2 * S
    local cy = y + PANEL_Y * S

    if show_charges then
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
    return h + 6 * S
end

-- Everything you own, on demand: the tech tree you are carrying and the two
-- score numbers, under the same toggle as the scoreboard. These change when
-- you fly over a green and not otherwise, so they are a thing you look up
-- between fights rather than a thing you watch during one -- and the feed
-- already announces every pickup as it happens, which is where a player
-- actually learns the tree exists.
-- Under the scoreboard, not at the foot of the screen.
--
-- It was anchored to the bottom like the panel it came out of, which is fine
-- on a desktop and wrong on a phone: with the thumbs lifting it 150 points
-- and only 390 to play with, it climbed into the scoreboard and the two drew
-- through each other. They are one stack now, because they are one toggle --
-- you asked one question and this is the whole answer to it.
local function loadout(me, class_names, top)
    if not M.details then return end
    local rows_h = LINE * S
    -- Only the triggers this hull actually has. Everything else in this panel
    -- shows what you do not hold as a list of what is out there to find, and
    -- a greyed `bomb` on a hull with no rack says exactly that -- about a
    -- weapon it can never be handed.
    local trigs = 0
    for t = 0, SIM_TRIGGERS - 1 do
        if sim.has_trigger(me, t) then trigs = trigs + 1 end
    end
    local h = PANEL_Y * 2 * S + rows_h * (3 + trigs)
    local w = COL_W * S
    local x = PAD * S
    local y = (top or 0) + 6 * S
    panel(x, y, w, h)

    local ix = x + PANEL_X * S
    local iw = w - PANEL_X * 2 * S
    local cy = y + PANEL_Y * S

    txt(class_names[sim.ship_class(me) + 1] or "?", ix, cy + rows_h / 2,
        FONT * S, pal.FRIEND)
    txt(sim.ship_kills(me) .. "k / " .. sim.ship_deaths(me) .. "d",
        ix + iw, cy + rows_h / 2, FONT * S, pal.INK, "right")
    cy = cy + rows_h

    txt(sim.ship_points(me) .. " points", ix, cy + rows_h / 2, (FONT - 1) * S,
        pal.DIM)
    local bty = sim.ship_bounty(me)
    txt("worth " .. bty, ix + iw, cy + rows_h / 2, (FONT - 1) * S,
        bty > 0 and pal.BOUNTY or pal.a(pal.DIM, 0.5), "right")
    cy = cy + rows_h

    -- Every slot always present, so the row does not reflow as prizes are
    -- picked up, and the ones you do not hold sit there greyed as a list of
    -- what is out there to find.
    local gap = iw / #pal.UPGRADES
    for i, up in ipairs(pal.UPGRADES) do
        local held = sim.ship_up(me, i - 1)
        local label = held > 0 and (up.short .. "×" .. held) or up.short
        txt(label, ix + (i - 1) * gap, cy + rows_h / 2, (FONT - 1) * S,
            held > 0 and up.col or pal.a(pal.DIM, 0.45))
    end
    cy = cy + rows_h

    -- A level is the same weapon harder and an add-on changes its character,
    -- so they read differently: "gun 2" is a rung, "MUL" is bolted on.
    for t = 0, SIM_TRIGGERS - 1 do
        if sim.has_trigger(me, t) then
            local lvl = sim.ship_level(me, t)
            local name = (t == sim.TRIG_GUN) and "gun" or "bomb"
            txt(name .. (lvl > 0 and (" " .. (lvl + 1)) or ""),
                ix, cy + rows_h / 2, (FONT - 1) * S,
                lvl > 0 and pal.LEVEL_COL or pal.a(pal.DIM, 0.55))
            local at = ix + 52 * S
            for m, mod in ipairs(pal.MODS) do
                local nn = sim.ship_mod(me, t, m - 1)
                if nn > 0 then
                    txt(mod.short .. (nn > 1 and ("×" .. nn) or ""), at,
                        cy + rows_h / 2, (FONT - 2) * S, pal.MOD_COL)
                    at = at + 30 * S
                end
            end
            cy = cy + rows_h
        end
    end
end

-- The damage vignette: red creeping in from the edges rather than a flash
-- over the middle, so it never hides the ship that is shooting you.
--
-- With the corner energy bar gone this carries more weight than it used to:
-- the vignette says "you are being hit", the hull's pip says how much is
-- left, and its colour says how urgent that is. Three channels, none of them
-- a panel.
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

-- The control hints used to live here, across the bottom of the screen, in
-- every frame of every game. They are read once and then never again, and on
-- a phone they were a line of text laid over the thumbs. They are in the
-- menu now, under `help`, which is where a thing you consult belongs.

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

    -- And the switch for everything that is not needed mid-fight: the
    -- scoreboard and your own loadout, together, because they answer the same
    -- question and you ask it at the same moments.
    local bx = x + w + 6 * S
    rect(bx, y, w, h, pal.a(pal.BTN_BG, M.details and 0.92 or 0.6))
    u:frame(bx, ry(y, h), w, h, S,
            M.details and pal.FRIEND or pal.a(pal.BAR_EDGE, 0.8))
    txt("info", bx + w / 2, y + h / 2, FONT * S,
        pal.a(M.details and pal.FRIEND or pal.INK, 0.92), "center")
    hit(bx, y, w, h, "details")
end

-- The count in each charge pad.
--
-- The pad and its icon are drawn by touch.lua, which owns where a pad is and
-- tests taps against the same arithmetic -- the two were written out
-- separately once and drifted, so half a pad did nothing and the dead space
-- beside it fired. This adds the one thing a mesh cannot: a numeral.
--
-- A kind you hold none of still shows its zero rather than vanishing. The
-- pad is a control, and a control that disappears when it has nothing to do
-- is a control a player stops believing in.
local function pad_charges(charges)
    if not M.touching then return end
    local L = touch.layout(W, H, S)
    for i, pad in ipairs(L.charge or {}) do
        local c = charges and charges[i]
        if c then
            -- Above the pad, not inside it. A pad is a thumb's worth of ring
            -- with a picture already in it, and a numeral in there lands on
            -- the picture or on the stroke; there is nothing above it.
            -- touch.lua counts up from the bottom; text counts down from the
            -- top.
            txt(tostring(c.count), pad.x, H - (pad.y + pad.r * 1.5),
                (FONT - 1) * S,
                c.count > 0 and pal.CHARGE_COL or pal.a(pal.DIM, 0.5), "center")
        end
    end
end

-- The flags, as flags.
--
-- This was a sentence -- "flags  you 2 - 1 them   1 loose" -- which is three
-- numbers, two of them derivable from the third, in enough characters to
-- cross a phone. One pennant per flag, coloured by who holds it, says the
-- same thing in a glance and in a fifth of the width: you count shapes, not
-- words, and it scales to whatever number of flags a mode puts out.
local function flag_strip(me)
    local n = sim.flag_count()
    if n == 0 then return end
    local my_team = sim.ship_team(me)
    local pitch = 15 * S
    local x0 = W / 2 - (n - 1) * pitch / 2
    local y = 30 * S
    for i = 0, n - 1 do
        local _, _, team = sim.flag_at(i)
        local col = (team == 255) and pal.a(pal.DIM, 0.55)
            or (team == my_team and pal.FRIEND or pal.ENEMY)
        local px = x0 + i * pitch
        -- The same pennant the radar draws, so a flag looks like a flag
        -- wherever it is shown.
        u:seg(px, ry(y + 9 * S, 0), px, ry(y - 8 * S, 0), 1.6 * S, col)
        u:tri(px, ry(y - 8 * S, 0), px + 9 * S, ry(y - 4 * S, 0),
              px, ry(y, 0), col)
    end
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
    -- Under the dial, wherever the dial now ends: it lost its panel and its
    -- padding, so a constant here would have left a gap or an overlap.
    feed(o.feed, M.radar_span())
    -- Stacked, not overlaid: the panel that is always there sits at the
    -- bottom and the one you asked for sits on top of it.
    status(me, o.netinfo, o.pickup, o.charges, lift)
    loadout(me, o.class_names, top)
    menu_button()
    vignette(o.hurt or 0)

    -- The two big centred lines are the only interface that sits where the
    -- menu does. The panels can share the screen with it; these cannot.
    if o.menu_open then return end
    pad_charges(o.charges)
    flag_strip(me)
    if o.banner and o.banner ~= "" then
        txt(o.banner, W / 2, 64 * S, (M.compact and 15 or 24) * S,
            pal.a(pal.INK, 0.92), "center")
    end
    if sim.ship_alive(me) == 0 then
        txt("D E S T R O Y E D", W / 2, H * 0.46, (M.compact and 15 or 22) * S,
            pal.ENEMY, "center")
    end
end

-- --- the menu --------------------------------------------------------------

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
-- A title, a breadcrumb's worth of depth, rows, and a line at the bottom. The
-- same routine draws the hull list, the games and the settings, which is the
-- point of having a tree rather than a screen: adding a level costs a table in
-- menu.lua and nothing here.
--
-- It is both the home screen and the panel you open mid-fight, so the backdrop
-- is translucent rather than opaque. Over an arena you can see the fight you
-- left, and that you are still in it; on the way in there is a starfield
-- behind it and the same wash makes the type readable against the stars.
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
    -- A phone has no escape key, so the way out is drawn. At the root of the
    -- home screen there is no way out to draw: nothing is behind the panel,
    -- and a `close` that leaves a player on an empty starfield would be a
    -- button that breaks the game.
    if v.closable then
        txt(v.depth > 1 and "back" or "close", x + w - 20 * S, y + 26 * S,
            11 * S, pal.a(pal.DIM, 0.8), "right")
        hit(x + w - 90 * S, y + 8 * S, 90 * S, 34 * S, "row", -1)
    end

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

    -- One line under the list, and three things want it. A note is why
    -- something did not work and outranks everything. A hint is the sentence
    -- about whatever is under the cursor, which is how a game in the list says
    -- what it is without a second column no phone has room for. The controls
    -- are what is left when there is nothing more useful to say.
    local by = y + h - 16 * S
    if v.note then
        txt(v.note, x + w / 2, by, FONT * S, pal.ENEMY, "center")
    elseif v.hint then
        txt(v.hint, x + w / 2, by, (FONT - 1) * S, pal.a(pal.DIM, 0.95),
            "center")
    else
        txt((M.touching or M.compact) and "tap a row"
                or "↑ ↓ move    enter choose    esc back",
            x + w / 2, by, 11 * S, pal.a(pal.DIM, 0.8), "center")
    end
end

return M
