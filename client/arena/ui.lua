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
-- The HUD stays up under the menu, so its hit boxes do too, and the first box
-- a press lands in wins. A dial the size of a quarter of the frame would sit
-- over half the menu and swallow every row behind it.
local menu_up = false

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
M.map = false          -- the whole map, in the radar's corner
-- Which pilot is being read about, by ship index, or nil. One at a time: this
-- answers "who is that", and two of them open at once is a filing cabinet.
M.inspect = nil
-- The connection, in numbers, behind the link bars. Off by default and not in
-- the menu, because it is for whoever is working on the client rather than for
-- whoever is flying.
M.debug = false

-- --- primitives ------------------------------------------------------------

local function ry(y, h)
    return H - y - (h or 0)
end

local function rect(x, y, w, h, col)
    u:rect(x, ry(y, h), w, h, col)
end

-- `font` names one of the faces the gui scene carries: nil for the mono
-- everything in flight is set in, "menu" for the menu's own. It is passed
-- through rather than looked up, so a caller that says nothing gets what the
-- rest of the interface uses.
-- Everything drawn while this is set draws that much of its alpha. It is
-- how the interface stands down under the menu: glyphs come from the gui,
-- which draws over every mesh, so no wash the menu lays down can touch them
-- and the only way to quiet a label is to quiet the label.
local text_dim = 1

local function txt(s, x, y, px, col, pivot, font)
    nt = nt + 1
    local t = text[nt]
    if not t then t = {} text[nt] = t end
    t.s, t.x, t.y, t.px, t.col, t.pivot = s, x, H - y, px, col, pivot or "left"
    t.font = font
    t.dim = text_dim ~= 1 and text_dim or nil
end

-- A rectangle the pointer can land on, published in the same coordinates it
-- was drawn in. Defined up here with the other primitives because everything
-- that draws something clickable needs it, and it used to sit far enough down
-- the file that the first function to call it from above found nil.
local function hit(x, y, w, h, action, value)
    M.hits[#M.hits + 1] = {x = x, y = y, w = w, h = h,
                           action = action, value = value}
end

-- Four chamfered corners and nothing between them. It is what holds a cluster
-- together without drawing a box round it, and it is the same diagonal the
-- walls cut off their own corners with. See docs/design/identity.md: a border
-- is the one shape this game does not otherwise contain.
local function bracket(x, y, w, h, col, arm, chamfer)
    arm = arm or 14 * S
    chamfer = chamfer or 5 * S
    for _, c in ipairs({{x, y, 1, 1}, {x + w, y, -1, 1},
                        {x + w, y + h, -1, -1}, {x, y + h, 1, -1}}) do
        local cx, cy, sx, sy = c[1], c[2], c[3], c[4]
        u:seg(cx + sx * chamfer, ry(cy), cx + sx * arm, ry(cy), S, col, true)
        u:seg(cx, ry(cy + sy * chamfer), cx, ry(cy + sy * arm), S, col, true)
        u:seg(cx + sx * chamfer, ry(cy), cx, ry(cy + sy * chamfer), S, col,
              true)
    end
end

-- A lit rule with the light falling off one side of it, which is a wall face
-- stood on end. Everything in a column hangs off one of these.
local function vrule(x, y, h, col, spill)
    u:skirt(x, ry(y), x, ry(y + h), (spill or 26 * S), 0, 0.07, col)
    u:seg(x, ry(y), x, ry(y + h), 1.4 * S, col)
end

-- The map border's tick, used as a rule between things.
local function ticks(x, y, w, col, pitch)
    pitch = pitch or 12 * S
    u:seg(x, ry(y), x + w, ry(y), 0.8 * S, pal.a(col, (col[4] or 1) * 0.7))
    local n = math.max(1, math.floor(w / pitch))
    for k = 0, n do
        local px = x + w * k / n
        u:seg(px, ry(y - 2.5 * S), px, ry(y), 0.8 * S, col)
    end
end

-- A selection: bright where it meets its rule and gone across the row. It was
-- a filled rectangle.
local function wash(x, y, w, h, col)
    u:skirt(x, ry(y), x, ry(y + h), w, 0, col[4] or 0.14, col)
end

-- A count, as marks rather than as a number: it reads at a glance and never
-- asks the eye to parse a digit.
local function pips(x, y, n, filled, col, r, pitch)
    r = r or 2.2 * S
    pitch = pitch or 7.5 * S
    for k = 0, n - 1 do
        local px = x + k * pitch
        if k < filled then
            u:disc(px, ry(y), r, 8, col)
        else
            u:ring(px, ry(y), r, 0.9 * S, 8, pal.a(col, (col[4] or 1) * 0.3))
        end
    end
end

-- What flies a seat, when it is not a person: a head with two eyes and a
-- stub of an aerial. Drawn rather than spelled, because "AI" beside a name is
-- two letters that read as part of the name until you have learned they are
-- not, and this list is scanned rather than read.
--
-- Chamfered, like everything else here. `y` is the middle of the line it sits
-- on, so a caller can hand it a row's centre without knowing the height.
local function bot_mark(x, y, col, k)
    k = k or 9 * S
    local w, h = k, k * 0.78
    local left, top = x, y - h / 2
    local cut = k * 0.22
    -- The head, as five strokes: the chamfer replaces the top left corner.
    local pts = {{left + cut, top}, {left + w, top}, {left + w, top + h},
                 {left, top + h}, {left, top + cut}}
    for i = 1, #pts do
        local a, b = pts[i], pts[i % #pts + 1]
        u:seg(a[1], ry(a[2]), b[1], ry(b[2]), 1.1 * S, col, true)
    end
    -- The aerial, off the square corner, so the shape has a top.
    u:seg(left + w - cut, ry(top), left + w - cut, ry(top - k * 0.34),
          1.1 * S, col, true)
    local ey = top + h * 0.5
    u:disc(left + w * 0.31, ry(ey), 1.15 * S, 6, col)
    u:disc(left + w * 0.69, ry(ey), 1.15 * S, 6, col)
    return w
end

-- How wide a string draws. The interface is set in one monospace face, so
-- this is exact rather than an estimate: DejaVu Sans Mono advances 1233 of
-- 2048 units per glyph at every size. Written down once because two places
-- had guessed at it separately, and a guess that runs 3% long puts a mark
-- inside the last letter of a name.
local ADVANCE = 1233 / 2048
local function text_w(s, px)
    return #s * px * ADVANCE
end

-- Close, as a drawn mark rather than the letter x.
--
-- A letter is a letter: at this size an x reads as text somebody left in the
-- corner, and it inherits the font's proportions rather than the interface's.
-- Four spokes instead, cut away from a void at the middle -- the same thing
-- a chamfer does to a corner, which is the one move the walls, the brackets
-- and the hulls all make. It still says close at a glance and stops looking
-- like a character that wandered out of a paragraph.
local function close_mark(x, y, col, k)
    k = k or 9 * S
    local out = k / 2
    local inn = k * 0.17
    local d = 0.7071
    for _, s in ipairs({{1, 1}, {1, -1}, {-1, 1}, {-1, -1}}) do
        local dx, dy = s[1] * d, s[2] * d
        u:seg(x + dx * inn, ry(y + dy * inn),
              x + dx * out, ry(y + dy * out), 1.25 * S, col, true)
    end
end

-- A weapon level, as filled rungs. Three rungs and how many are lit, which is
-- a rung count read without reading a numeral.
local function ladder(x, y, rungs, level, col, w, h)
    w = w or 34 * S
    h = h or 3.4 * S
    local step = w / rungs
    for k = 0, rungs - 1 do
        local px = x + k * step
        local wk = step - 2 * S
        if k < level then
            rect(px, y, wk, h, col)
        else
            u:frame(px, ry(y, h), wk, h, 0.8 * S,
                    pal.a(col, (col[4] or 1) * 0.32))
        end
    end
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
-- Held, never toggled: the screen names its own parts for as long as the key
-- is down. See `help_overlay`.
M.help = false

-- Where each instrument landed this frame.
--
-- The help overlay sets a word beside a thing instead of drawing a line to it,
-- so it has to know where the thing ended up, and the only account of that
-- which cannot drift is the one each element files as it draws itself. A
-- second copy of the layout arithmetic would be two places that have to agree
-- about one corner.
local anchor = {}

-- What the pointer can rest on to ask what it is, filed the same way and at
-- the same time as the anchors.
--
-- Deliberately not `M.hits`. A hit box is a press: `on_input` takes the first
-- one a press lands in, and the field of play holds none at all because left
-- click is the gun and a box over a hull would eat the shot. These are read by
-- the pointer and by nothing else, so naming a thing can never cost a trigger
-- pull. See hud_hits_test for the rule they are staying out of the way of.
local zones = {}
local function zone(key, x, y, w, h)
    zones[#zones + 1] = {key = key, x = x, y = y, w = w, h = h}
end

-- Which instrument the pointer is over, or nil. Last registered wins, so a
-- row inside a panel beats the panel: the corner stack files a zone per row
-- and hovering one names that row rather than the stack.
function M.help_at(x, y)
    if not x or not y then return nil end
    local found = nil
    for _, z in ipairs(zones) do
        if x >= z.x and x <= z.x + z.w and y >= z.y and y <= z.y + z.h then
            found = z.key
        end
    end
    return found
end

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
    anchor = {}
    zones = {}
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

-- The top right corner holds one instrument at a time: the radar, or the map
-- when that is open. Everything that hangs off its edges asks here rather than
-- keeping a second copy of where it is, which is how the touch pads and their
-- own hit test drifted apart once.
--
-- The map is about a quarter of the frame, capped three ways: against the
-- window's width so it cannot run off the left edge, against its height so
-- there is still room for the feed under it, and against the corner the MENU
-- and INFO chips stand in, since a hit box over those is two controls a
-- pointer can no longer reach.
local function dial()
    local pad = (M.compact and 8 or PAD) * S
    local side = RADAR * S
    if M.map then
        side = math.max(side,
                        math.min(math.min(W, H) * 0.66, H * 0.66,
                                 W - pad - 124 * S))
    end
    -- Whole pixels. The dial snaps its contents to its own origin, so an
    -- origin landing on a half pixel would put the fraction back into every
    -- blip it was taken out of. Density is not always a whole number and
    -- neither, then, is the padding.
    local ix, iy = math.floor(W - pad - side), math.floor(pad + 18 * S)
    side = math.floor(side)
    -- Filed here rather than in the two functions that draw into it, because
    -- the dial and the map are the same corner and want the same word beside
    -- them.
    anchor.radar = {ix, iy + side * 0.5}
    zone("radar", ix, iy, side, side)
    return ix, iy, side
end

-- How much vertical room it takes, so the feed under it can be told rather
-- than guess.
function M.radar_span()
    local _, _, side = dial()
    return PAD * S * 2 + side + 18 * S
end

-- You, as an arrow. On any view of the arena the one thing worth knowing
-- besides where you are is which way you are pointing, and the radar and the
-- map draw the same mark because they are the same statement about the same
-- ship. Clamped rather than dropped when it falls outside the frame it is
-- given: a view without you on it is a view with no origin.
local function own_arrow(ax, ay, ox, oy, side, me)
    local edge = 5 * S
    if ax < ox + edge then ax = ox + edge end
    if ay < oy + edge then ay = oy + edge end
    if ax > ox + side - edge then ax = ox + side - edge end
    if ay > oy + side - edge then ay = oy + side - edge end
    local a = (sim.ship_heading(me) / 65536) * math.pi * 2
    local dx, dy = math.sin(a), -math.cos(a)
    local nose, back, wide = 6.5 * S, 3.4 * S, 3.2 * S
    u:disc(ax, ry(ay, 0), 7 * S, 12, pal.a(pal.WHITE, 0.14))
    u:tri(ax + dx * nose, ry(ay + dy * nose, 0),
          ax - dx * back - dy * wide, ry(ay - dy * back + dx * wide, 0),
          ax - dx * back + dy * wide, ry(ay - dy * back - dx * wide, 0),
          pal.WHITE)
end

local function radar(cx, cy, me)
    -- No panel and no inset. The dial is the most valuable thing on screen on
    -- a map a thousand tiles across and it keeps every pixel; what made it
    -- read as half a phone's height was the opaque box, the border and eight
    -- points of padding on each side, none of which is information.
    --
    -- A faint wash stays, because dots over a starfield are dots lost in a
    -- starfield -- but it is a wash rather than a panel.
    -- Under the link readout, which owns the top right corner now.
    local ix, iy, r = dial()
    rect(ix, iy, r, r, pal.a(pal.RADAR_BG, 0.55))
    -- The dial is the way in to the map: a thing you point at to see more of
    -- is a thing you can click, and it saves teaching a key to somebody who
    -- never opens the help.
    if not menu_up then hit(ix, iy, r, r, "map") end

    -- Sixty tiles out, so the reference arena nearly fills the dial. At a
    -- hundred and fifty it sat in the middle quarter with the rest of the
    -- radar showing empty space nobody can fly to.
    local SPAN = 60 * 16
    local k = r / (2 * SPAN)
    -- The dial is a diagram, not a window, and it is worth snapping to the
    -- pixel grid it is drawn on.
    --
    -- A blip is a square about 2.8 pixels across with a hard edge, and a hard
    -- edge that size covers two pixel centres at some sub-pixel offsets and
    -- three at others: four pixels of area against nine, a bit over twice the
    -- ink, flipping as the fraction rolls over. Every blip shares the fraction,
    -- because they are a regular grid under one affine map, so the whole map
    -- breathes at once and reads as the terrain blinking off and on.
    --
    -- Two things fix it and both are free. A whole number of pixels covers
    -- exactly that many centres wherever it starts, so the size stops
    -- mattering; and snapping the camera to a whole dial pixel leaves every
    -- blip's own fraction fixed, so the pattern slides rigidly rather than
    -- each square shifting off its neighbours. What a blip stands for is a
    -- two-tile sample, and no part of that is worth a sub-pixel.
    local qx = math.floor(cx * k + 0.5) / k
    local qy = math.floor(cy * k + 0.5) / k
    local function put(wx, wy)
        local px = ix + (wx - qx + SPAN) * k
        local py = iy + (wy - qy + SPAN) * k
        if px < ix or py < iy or px > ix + r or py > iy + r then return nil end
        return px, py
    end

    -- The map, in three passes so the things worth steering by sit on top of
    -- the walls rather than under them.
    -- One blip covers exactly the ground its sample stands for -- two tiles,
    -- the sampling stride -- so a wall reads as a wall. A fixed pixel size
    -- left gaps between samples and turned every wall into a dashed line.
    -- Whole pixels, per above. A door gets one more rather than a fraction
    -- more, which is the only way "bigger" survives being rounded.
    local dot = math.max(1, math.floor(math.max(2 * 16 * k, 1.5 * S) + 0.5))
    local function blips(list, col, extra)
        local d = dot + (extra or 0)
        for n = 1, #list, 2 do
            local px, py = put(list[n], list[n + 1])
            if px then
                rect(math.floor(px - d / 2 + 0.5),
                     math.floor(py - d / 2 + 0.5), d, d, col)
            end
        end
    end
    blips(world.radar_tiles, pal.RADAR_TILE)
    blips(world.radar_safe, pal.a(pal.RADAR_SAFE, 0.95))
    blips(world.radar_doors, pal.a(pal.RADAR_DOOR, 1.0), 1)

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

    -- Nothing drawn on the dial but the map and what is flying over it.
    --
    -- It carried two range rings, a bearing tick on each eighth and a
    -- chamfered bracket at the corners, on the argument that a dot in an empty
    -- square says where a contact is and nothing about how far. What that
    -- missed is that the dial is small and the graticule was competing with
    -- the contacts for the same few pixels. The square's own edge is the
    -- reference, the wash is what separates it from the starfield, and both
    -- are already there.
    --
    -- The expanded map keeps its bracket. It is large enough to need telling
    -- where it ends, which is the thing a bracket is for.

    -- You, last. Placed by hand rather than through `put`, which answers nil
    -- for anything off the edge: right for a contact and wrong for the pilot
    -- reading the thing, because the dial is drawn around the camera, the
    -- camera is not the ship, and on a wide window it leads far enough that
    -- the arrow simply went missing.
    own_arrow(ix + (sim.ship_x(me) - cx + SPAN) * k,
              iy + (sim.ship_y(me) - cy + SPAN) * k, ix, iy, r, me)
end

-- --- the map ---------------------------------------------------------------
--
-- The radar answers "what is near me". The map answers "where am I going",
-- which on a thousand tiles is a different question and one nothing on screen
-- could answer before.
--
-- Terrain and nothing else. No ships, no greens, no flags, nothing in flight:
-- a view of the whole arena with every pilot on it is a wall hack with a
-- keyboard shortcut, and contacts are the radar's job. So this draws what the
-- room is rather than what is happening in it, and never changes between the
-- frame a map arrives and the frame the next one does.
--
-- Constants rather than calls in the loop below, which runs a couple of
-- thousand times a frame: `pal.a` builds a colour, and building four of them
-- per rectangle is work for the collector rather than for the screen.
local MAP_WALL = pal.a(pal.RADAR_TILE, 0.85)
local MAP_SAFE = pal.a(pal.RADAR_SAFE, 0.95)
local MAP_DOOR = pal.a(pal.RADAR_DOOR, 1.0)
local MAP_HOLE = pal.a(pal.HOLE, 0.9)

local function overview(me)
    local ix, iy, side = dial()
    local ov = world.overview
    -- Opaque, where the radar's wash is not, and that is the rule above
    -- rather than a preference about panels. At the radar's 0.55 a green
    -- lying under the dial comes through it at half strength, so a view that
    -- draws no prizes shows prizes anyway, in the one place a player would
    -- read them as part of the map.
    rect(ix, iy, side, side, pal.RADAR_BG)
    if ov.grid > 0 then
        local k = side / ov.grid
        local r = ov.rect
        for i = 1, ov.n, 5 do
            local cls = r[i + 4]
            local col = (cls == sim.T_SOLID and MAP_WALL)
                or (cls == sim.T_SAFE and MAP_SAFE)
                or (cls == sim.T_DOOR and MAP_DOOR)
                or MAP_HOLE
            rect(ix + r[i] * k, iy + r[i + 1] * k,
                 r[i + 2] * k, r[i + 3] * k, col)
        end
    end
    bracket(ix, iy, side, side, pal.a(pal.RADAR_TILE, 0.8), 22 * S)
    -- You, and only you. No ships is the rule above, and it stands: a map
    -- showing where everybody is would be a wall hack. Where *you* are is
    -- something you already know, and without it a view of a thousand tiles
    -- is a picture of somewhere rather than of where you are standing, which
    -- is the whole question the map exists to answer.
    --
    -- A cell is OVERVIEW_CELL tiles of sixteen pixels, so the world divides
    -- by that to land in the same coordinates the rectangles above use.
    if ov.grid > 0 then
        local cell = 4 * 16
        local k = side / ov.grid
        own_arrow(ix + (sim.ship_x(me) / cell) * k,
                  iy + (sim.ship_y(me) / cell) * k, ix, iy, side, me)
    end
    -- Clicking it again puts the radar back, which is the same gesture that
    -- opened it.
    if not menu_up then hit(ix, iy, side, side, "map") end
end

-- Names, at each ship's lower right.
--
-- Screen space, because text is: the world is a mesh and glyphs come from a
-- gui font. The projection is the render script's -- a fixed world extent
-- across the shorter axis, centred on the camera -- so one number converts
-- between them and the two cannot drift.
-- Nothing here is clickable, deliberately. The left button is the gun and the
-- right one is the bomb, and a hit box publishes over both: a box on a hull,
-- or on the label beside it, would eat the trigger at the exact moment a
-- player is lined up on somebody. Asking who somebody is belongs to the
-- scoreboard, where a click is a click and nothing else.
-- Where the wait box is standing this frame, or nil when there is none. Set
-- by `wait` and read by `nameplates`, which is the one thing that can land on
-- top of it: a nameplate is a gui glyph, and the gui draws over every mesh, so
-- no wash can quiet one. The only way past that is to not draw it.
local wait_box = nil

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
                -- Not when it would land on the line somebody has three
                -- seconds to read. A name is worth knowing while you are
                -- deciding whether to chase somebody, and you are dead, so
                -- for those three seconds it is worth less than the sentence
                -- underneath it. The hull still draws; only the label goes.
                local b = wait_box
                local clear = not (b and sx + 12 * S < b.x + b.w
                    and sx + 90 * S > b.x and sy + 28 * S > b.y
                    and sy + 4 * S < b.y + b.h)
                if clear then
                    txt(nm, sx + 12 * S, sy + 13 * S, 11 * S, pal.a(col, 0.7))
                    -- The same mark the scoreboard and the info box wear, on
                    -- the hull itself: who is flying a ship is worth knowing
                    -- while you are deciding whether to chase it, and that
                    -- decision is made looking at the ship rather than at a
                    -- panel. Dim and after the name, so it reads as a note
                    -- about the label and never competes with the bounty
                    -- under it.
                    if p and p.ai then
                        bot_mark(sx + 12 * S + text_w(nm, 11 * S) + 4 * S,
                                 sy + 13 * S, pal.a(col, 0.45), 8 * S)
                    end
                    if bty > 0 then
                        txt(tostring(bty), sx + 12 * S, sy + 25 * S, 11 * S,
                            pal.a(pal.BOUNTY, 0.85))
                    end
                end
            end
        end
    end

    -- Not your own, for the same reason your name is not drawn: a bounty under
    -- your hull is a number about you, in the one place on screen you are
    -- already looking, and it rode along with every shot you lined up. The
    -- corner stack carries it, where a glance finds it and nothing is in the
    -- way of the fight. Everybody else keeps theirs, because theirs is what
    -- says which of two ships in front of you is worth the risk.
end

-- --- panels ----------------------------------------------------------------

local rows = {}
-- How the scoreboard is ordered, and how far down it. Both belong to the
-- interface rather than to the game: nothing here changes what is true, only
-- which part of it is on screen.
--
-- `points` is the default because points are the score. Clicking a heading
-- picks that column, and clicking the one already picked does nothing: every
-- column here has an obvious direction, and a name that sorts Z to A or a
-- kill count that puts the worst first is a state somebody reaches by accident
-- and then has to work out how to leave.
M.sort = "points"
M.scroll = 0
-- Rows on screen at once. The list was capped at nine with no way to see the
-- tenth, which in a room of sixty-four is most of it.
local SHOWN = 9

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
        -- What the zone is willing to say this seat is, which is a stronger
        -- statement than "AI" and is what the counts below are made of.
        r.label = (p and p.label) or "unknown"
        r.mine = sim.ship_team(i) == sim.ship_team(me)
    end
    for i = n + 1, #rows do rows[i] = nil end
    -- Your own team first, whatever the column says.
    --
    -- The scoreboard answers two questions and they do not sort the same way.
    -- "Who is winning" is the column somebody picked; "who is with me" is a
    -- partition, and in a fight it is the more urgent of the two, because a
    -- name is only worth reading once you know which end of the gun it is on.
    -- So the sort runs inside each side rather than across both.
    --
    -- Points is the default, because points are the score. Kills stay on the
    -- row: they are what a player counts in their head, and the two numbers
    -- say different things, since a pilot who kills loaded ships outscores one
    -- who kills more of the empty.
    local key = M.sort
    table.sort(rows, function(a, b)
        if a.mine ~= b.mine then return a.mine end
        if key == "name" then
            if a.name ~= b.name then return a.name < b.name end
        elseif key == "kills" then
            if a.k ~= b.k then return a.k > b.k end
        elseif key == "deaths" then
            -- Fewest first: on every other column the top of the list is the
            -- pilot doing best, and this is the one where that means less.
            if a.d ~= b.d then return a.d < b.d end
        else
            if a.p ~= b.p then return a.p > b.p end
        end
        if a.p ~= b.p then return a.p > b.p end
        if a.k ~= b.k then return a.k > b.k end
        return a.name < b.name
    end)

    if n == 0 then
        M.scroll = 0
        return 0
    end
    -- Clamped here rather than where the wheel is read, because this is the
    -- only place that knows how many pilots there are: a room empties while
    -- somebody is scrolled to the bottom of it.
    local max_scroll = math.max(0, n - SHOWN)
    if M.scroll > max_scroll then M.scroll = max_scroll end
    if M.scroll < 0 then M.scroll = 0 end
    local shown = math.min(n, SHOWN)
    local w = COL_W * S
    local head = 24 * S
    -- Header, rows, and a line of totals under them.
    local foot = 16 * S
    local h = head + shown * LINE * S + foot + 8 * S
    local x = PAD * S
    -- Enough behind it to read over a starfield, and no border: a rule down
    -- the left is what holds the column, the way it holds a wall face.
    rect(x, top_y(), w, h, pal.a(pal.BG, 0.62))
    vrule(x, top_y(), h, pal.a(pal.RADAR_TILE, 0.7))

    local kx = x + w - 74 * S
    local dx = x + w - 44 * S
    local px = x + w - 12 * S
    local small = (FONT - 3) * S
    -- A heading is a control now, so the one in use is lit and the rest are
    -- not: the same way every other toggle in this interface says which way it
    -- is set.
    local function head_col(name, label, hx, align)
        local on = M.sort == name
        txt(label, hx, top_y() + 14 * S, small,
            on and pal.a(pal.FRIEND, 0.95) or pal.a(pal.DIM, 0.7), align)
        return on
    end
    head_col("name", "PILOTS", x + 12 * S, nil)
    head_col("kills", "K", kx, "right")
    head_col("deaths", "D", dx, "right")
    head_col("points", "PTS", px, "right")
    -- Hit boxes over the headings. Generous, and to the left of each label,
    -- because the labels are right-aligned one or three characters wide and a
    -- box the size of the glyphs is a target nobody can hit.
    hit(x + 8 * S, top_y() + 4 * S, 60 * S, 18 * S, "sort_name")
    hit(kx - 24 * S, top_y() + 4 * S, 28 * S, 18 * S, "sort_kills")
    hit(dx - 24 * S, top_y() + 4 * S, 28 * S, 18 * S, "sort_deaths")
    hit(px - 26 * S, top_y() + 4 * S, 30 * S, 18 * S, "sort_points")
    ticks(x + 12 * S, top_y() + 20 * S, w - 24 * S,
          pal.a(pal.RADAR_TILE, 0.35), 14 * S)

    local my_team = sim.ship_team(me)
    local y = top_y() + head
    for i = 1 + M.scroll, math.min(n, M.scroll + shown) do
        local r = rows[i]
        local mine = r.i == me
        local reading = M.inspect == r.i
        local col = (sim.ship_team(r.i) == my_team) and pal.FRIEND or pal.ENEMY
        if mine or reading then
            -- Your row, marked the way a selected row is marked everywhere
            -- else in this interface: a lit rule and a wash off it, not a
            -- glyph in front of your name. The row being read about wears the
            -- same mark, in its own colour, since it is a selection and this
            -- is how this interface draws one.
            local mark = reading and pal.BOUNTY or pal.FRIEND
            wash(x, y, w, LINE * S, pal.a(mark, 0.13))
            u:seg(x, ry(y), x, ry(y + LINE * S), 1.6 * S, pal.a(mark, 0.95))
        end
        local name = string.sub(r.name, 1, 14)
        local cy = y + LINE * S / 2
        txt(name, x + 12 * S, cy, (FONT - 2) * S,
            pal.a(col, mine and 1.0 or 0.8))
        -- The mark goes at a fixed column rather than after the name, so a
        -- scan down the list finds them in a line instead of at fourteen
        -- different indents.
        if r.ai then bot_mark(kx - 42 * S, cy, pal.a(pal.DIM, 0.75)) end
        -- The one way to ask about a pilot. Published before the panel's own
        -- box below, which takes the wheel and would otherwise swallow the
        -- press: first box in wins.
        hit(x, y, w - 6 * S, LINE * S, "pilot", r.i)
        txt(tostring(r.k), kx, y + LINE * S / 2, (FONT - 2) * S,
            pal.a(pal.INK, 0.85), "right")
        txt(tostring(r.d), dx, y + LINE * S / 2, (FONT - 2) * S,
            pal.a(pal.DIM, 0.85), "right")
        txt(tostring(r.p), px, y + LINE * S / 2, (FONT - 2) * S,
            pal.a(pal.BOUNTY, 0.9), "right")
        y = y + LINE * S
    end

    -- Who is in the room, by what the zone is willing to say about them.
    --
    -- Three numbers rather than one, because "sixty in the room" is a
    -- different room depending on how many of them are people. The three are
    -- the three labels a seat can wear: a claimed account, a guest, and a
    -- declared bot. A guest is counted apart from a claimed pilot rather than
    -- folded into the humans, because the label is a statement about what the
    -- server knows and most guests are people in their first session.
    --
    -- Spelled out rather than punched into "0/2/50". Three bare numbers in a
    -- corner are a code, and this line is read once by somebody deciding
    -- whether a room is worth joining.
    local claimed, guests, bots = 0, 0, 0
    for i = 1, n do
        local l = rows[i].label
        if l == "bot" or l == "bot?" then bots = bots + 1
        elseif l == "human" then claimed = claimed + 1
        else guests = guests + 1 end
    end
    local fy = y + foot / 2
    txt(string.format("%d HERE: %d SIGNED, %d GUEST, %d AI",
                      n, claimed, guests, bots),
        x + 12 * S, fy, (FONT - 4) * S, pal.a(pal.DIM, 0.8))

    -- Only when there is something to scroll to. A bar on a list that fits is
    -- a control that does nothing.
    if n > shown then
        local track = shown * LINE * S
        local ty = top_y() + head
        local frac = shown / n
        local bar = math.max(10 * S, track * frac)
        local at = (M.scroll / math.max(1, n - shown)) * (track - bar)
        u:seg(x + w - 3 * S, ry(ty + at), x + w - 3 * S, ry(ty + at + bar),
              2 * S, pal.a(pal.RADAR_TILE, 0.8))
    end

    -- The whole panel takes the wheel, rather than a strip beside it: a list
    -- is the thing you point at when you mean to scroll it.
    hit(x, top_y(), w, h, "scores")

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
-- How many lines stand at once. Deep enough to hold a busy moment, shallow
-- enough that the feed stays something you read at a glance rather than a log
-- running down the side of the screen; a phone gets fewer again.
M.FEED_MAX = 5

local function feed(lines, top)
    local shown = math.min(#lines, M.compact and 4 or M.FEED_MAX)
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
    anchor.feed = {right, y + LINE * S / 2}
    -- As wide as the widest line it drew rather than a guess, since a feed of
    -- short names is a narrow block and a zone the width of the panel would
    -- claim empty screen beside it.
    local wide = 0
    for i = 1, shown do
        local w = text_w(lines[i].text, FONT * S)
        if w > wide then wide = w end
    end
    zone("feed", right - wide, top + PANEL_Y * S - LINE * S / 2, wide,
         shown * LINE * S)
end

-- The corner stack: what the triggers do, what you carry and can spend, and
-- what you are worth. Five rows, no panel and no rules between them.
--
-- What a trigger does is the team colour and what you carry is gold, and that
-- separation is the whole reason there is no divider: a rule between them
-- would say a second time what the colour already says once.
--
-- Energy is not here. Your own hull carries the pip every other hull carries,
-- so a bar in a corner was the same number drawn twice in the place you are
-- least likely to be looking. Nor is your speed, which nobody has made a
-- decision on, nor the prediction error in pixels, which was this client
-- debugging itself on a player's screen.
local function status(me, pickup, charges, lift)
    local slots = charges or {}
    -- Sized up. This corner is what a pilot checks mid-fight without looking
    -- away from their own hull, and it was set three and four points under
    -- the body text: legible while you are reading it and not while you are
    -- flying, which is the only time it is on screen. The row pitch and the
    -- value column move with the type rather than being left where the small
    -- labels fit.
    local rows_h = 22 * S
    local x = PAD * S
    local lab = FONT * S
    local val = x + 62 * S

    -- The pad carries the charge counts on a touchscreen, so those rows would
    -- be the same thing twice at opposite corners.
    local show_charges = #slots > 0 and not M.touching
    local trigs = 0
    for t = 0, SIM_TRIGGERS - 1 do
        if sim.has_trigger(me, t) then trigs = trigs + 1 end
    end
    local n = trigs + (show_charges and #slots or 0) + 1
        + (pickup and 1 or 0)
    local y = H - PAD * S - n * rows_h - (lift or 0)
    -- How far right the stack actually reached, which is what decides where
    -- the help overlay's column starts. A hull holding three add-ons is a good
    -- deal wider than one holding none, and a constant here would either crowd
    -- the wide case or strand the narrow one.
    local wide = val + 50 * S

    -- A level is the same weapon harder, so it is rungs; an add-on changes
    -- its character, so it is a word.
    for t = 0, SIM_TRIGGERS - 1 do
        if sim.has_trigger(me, t) then
            local lvl = sim.ship_level(me, t)
            txt((t == sim.TRIG_GUN) and "GUN" or "BOMB", x,
                y + rows_h / 2, lab, pal.a(pal.DIM, 0.8))
            ladder(val, y + rows_h / 2 - 2 * S, 3, lvl + 1, pal.FRIEND,
                   40 * S, 4 * S)
            local at = val + 50 * S
            local off = sim.ship_multi_off and sim.ship_multi_off(me)
            for m, mod in ipairs(pal.MODS) do
                local nn = sim.ship_mod(me, t, m - 1)
                if nn > 0 then
                    -- A declined add-on is drawn dimmed rather than dropped.
                    -- You still hold it, and a fan that quietly stopped
                    -- fanning with nothing on screen to say so is a weapon
                    -- that looks broken.
                    local muted = off and m - 1 == 0
                    local word = mod.name .. (nn > 1 and ("x" .. nn) or "")
                    txt(word, at, y + rows_h / 2, (FONT - 2) * S,
                        muted and pal.a(pal.DIM, 0.45) or pal.a(pal.FRIEND, 0.75))
                    -- Measured, not stepped. The column is 46 wide and
                    -- "shrapnel" is 53, so a row ending in the longest add-on
                    -- reaches past where the next column would start, and the
                    -- help overlay lining up on the step would sit on the tail
                    -- of the word.
                    local ends = at + text_w(word, (FONT - 2) * S)
                    if ends > wide then wide = ends end
                    at = at + 46 * S
                end
            end
            -- The row as far right as it actually drew, so the add-ons are
            -- part of the thing you point at rather than dead space beside it.
            local key = (t == sim.TRIG_GUN) and "gun" or "bomb"
            anchor[key] = y + rows_h / 2
            zone(key, x, y, math.max(at, val + 50 * S) - x, rows_h)
            y = y + rows_h
        end
    end

    if show_charges then
        for _, c in ipairs(slots) do
            -- No ready mark and no digit: there is no selection to show any
            -- more, a key or a pad names its charge outright, and which
            -- number is which row is the help page's job, not a label worn
            -- in the corner of every fight.
            txt(string.upper(c.name or c.short), x, y + rows_h / 2, lab,
                pal.a(pal.DIM, 0.8))
            local slot_max = math.max(1, c.max or 3)
            pips(val + 3 * S, y + rows_h / 2, slot_max, c.count,
                 pal.CHARGE_COL, 2.7 * S, 9 * S)
            -- First and last, because however many charge rows a hull carries
            -- they are one idea and the overlay says it once.
            anchor.chg_top = anchor.chg_top or (y + rows_h / 2)
            anchor.chg_bot = y + rows_h / 2
            local pw = val + 3 * S + slot_max * 9 * S
            if pw > wide then wide = pw end
            -- Every charge row answers to the one sentence, so they all point
            -- at the same key.
            zone("charges", x, y, pw - x, rows_h)
            y = y + rows_h
        end
    end

    -- What you are worth, which is the number that decides who comes for you,
    -- and which was only ever behind the info toggle.
    txt("BOUNTY", x, y + rows_h / 2, lab, pal.a(pal.DIM, 0.8))
    local bty = sim.ship_bounty(me)
    txt(tostring(bty), val, y + rows_h / 2, (FONT - 2) * S,
        bty > 0 and pal.a(pal.PRIZE, 0.95) or pal.a(pal.DIM, 0.5))
    anchor.bounty = y + rows_h / 2
    local bw = val + text_w(tostring(bty), (FONT - 2) * S)
    if bw > wide then wide = bw end
    zone("bounty", x, y, bw - x, rows_h)
    y = y + rows_h

    if pickup then
        txt((pickup.sign or "+") .. " " .. pickup.name, x,
            y + rows_h / 2, FONT * S, pal.a(pickup.col, pickup.t))
    end
    anchor.stack_x = wide + 26 * S
    return 0
end

-- What a season of play has added up to, under the same toggle as the
-- scoreboard: which hull you are in and how far up each stat the greens have
-- carried you.
--
-- The gun and bomb ladders used to be here too. They are what a trigger does
-- rather than what a run has accumulated, and they belong in the corner with
-- the rest of what the ship is carrying, where they can be read without
-- opening a panel at all.
local function loadout(me, class_names, top)
    if not M.details then return top or 0 end
    local w = COL_W * S
    local x = PAD * S
    local h = 54 * S
    local y = (top or 0) + 6 * S
    rect(x, y, w, h, pal.a(pal.BG, 0.62))
    vrule(x, y, h, pal.a(pal.RADAR_TILE, 0.7))

    txt(class_names[sim.ship_class(me) + 1] or "?", x + 12 * S, y + 16 * S,
        (FONT - 1) * S, pal.FRIEND)
    txt(sim.ship_kills(me) .. "k  " .. sim.ship_deaths(me) .. "d",
        x + w - 12 * S, y + 16 * S, (FONT - 3) * S, pal.a(pal.DIM, 0.85),
        "right")

    -- Every slot always present, so the row does not reflow as prizes are
    -- picked up, and the ones you do not hold sit there as empties: a list of
    -- what is still out there to find.
    local gap = (w - 24 * S) / #pal.UPGRADES
    for i, up in ipairs(pal.UPGRADES) do
        local held = sim.ship_up(me, i - 1)
        local sx = x + 14 * S + (i - 1) * gap
        txt(up.short, sx, y + 32 * S, (FONT - 4) * S, pal.a(pal.DIM, 0.75))
        pips(sx + 3 * S, y + 42 * S, 4, held, up.col, 1.9 * S, 6 * S)
    end
    return y + h
end

-- Who that is: one pilot, read off the roster and the simulation.
--
-- It answers the question a name over a hull raises and cannot itself answer.
-- The nameplate says what to call them; this says what the zone will vouch
-- for, how they are doing, and whether they are on your side.
--
-- In the left column under whatever is already there, because that column is
-- where this interface keeps things you asked to see. Not over the middle: a
-- box you opened by clicking a ship must not cover the ship you clicked.
local function inspect(o, top)
    -- It belongs to the scoreboard, which is the only thing that opens it, so
    -- it goes when the scoreboard goes. A box left standing under a shut list
    -- is a panel about somebody with nothing on screen saying who they were or
    -- how to get another one.
    if not M.details then M.inspect = nil end
    local i = M.inspect
    if not i then return end
    -- A pilot who left while the box was open. The box goes with them rather
    -- than describing somebody who is not there.
    if i < 0 or i >= sim.ship_count() then
        M.inspect = nil
        return
    end
    local p = o.pilots[i]
    local w = COL_W * S
    local x = PAD * S
    local rowh = 15 * S
    -- Name, then the rows that always exist, then the team when it means
    -- something. Counted rather than guessed so the panel is exactly as tall
    -- as what it holds.
    local theirs = sim.ship_team(i)
    local same_team = theirs == sim.ship_team(o.me)
    -- Which side they are on, and whether this pilot is allowed to be told.
    --
    -- The zone decides. A side it marks public is one anybody may see and name;
    -- a private one is a squad who arranged themselves, and naming it here
    -- would hand the room a roster the zone deliberately did not send. Your own
    -- side is always yours to know, whatever it is marked, since you are in it.
    --
    -- Falling back to the raw number when the zone has sent no team list at all
    -- would be the same leak by a duller instrument, so an unknown side simply
    -- has no row: this box says what it is told and infers nothing.
    local side = nil
    for _, t in ipairs(o.teams or {}) do
        if t.team == theirs and (t.public or same_team) then
            side = (t.name ~= "" and t.name) or ("team " .. t.team)
        end
    end
    -- The invitation lives here because this is already the panel you open by
    -- picking a person, and picking a person was the whole of the old invite
    -- menu. Drawn only when it would do something: you are on a private side,
    -- and this is somebody other than you who is not already on it.
    local invite = o.may_invite and i ~= o.me and not same_team
    local rows_n = 5 + (side and 1 or 0)
    local h = 30 * S + rows_n * rowh + (invite and 26 * S or 0) + 10 * S
    -- Under whatever is in the column, and never above where the column
    -- starts: with the scoreboard shut there is nothing above it, and a panel
    -- at the top of the screen lands on the menu chip.
    local y = math.max((top or 0) + 6 * S, top_y())
    rect(x, y, w, h, pal.a(pal.BG, 0.72))
    vrule(x, y, h, pal.a(same_team and pal.FRIEND or pal.ENEMY, 0.9))

    local col = same_team and pal.FRIEND or pal.ENEMY
    local nm = (p and p.name) or ("ship " .. i)
    txt(nm, x + 12 * S, y + 17 * S, (FONT - 1) * S, pal.a(col, 0.95))
    -- The mark rides after the name here, not in a column: there is one line
    -- and nothing to line it up with.
    if p and p.ai then
        bot_mark(x + 12 * S + text_w(nm, (FONT - 1) * S) + 5 * S, y + 17 * S,
                 pal.a(pal.DIM, 0.85), 10 * S)
    end
    -- Close, in the corner it opened under. Escape does the same thing.
    close_mark(x + w - 17 * S, y + 17 * S, pal.a(pal.DIM, 0.8), 10 * S)
    hit(x + w - 26 * S, y + 4 * S, 26 * S, 22 * S, "uninspect")

    local ry_ = y + 30 * S
    local lab = (FONT - 4) * S
    local val = (FONT - 2) * S
    local function row(k, v, vcol)
        txt(k, x + 12 * S, ry_ + rowh / 2, lab, pal.a(pal.DIM, 0.8))
        txt(v, x + w - 12 * S, ry_ + rowh / 2, val, vcol or pal.a(pal.INK, 0.9),
            "right")
        ry_ = ry_ + rowh
    end
    if side then
        row("SIDE", side, pal.a(col, 0.9))
    end
    -- What the zone is willing to say this seat is, which is the honest
    -- version of the question: the client cannot tell, and the server's label
    -- is the only answer anybody has. A guest is not an accusation.
    row("SEAT", string.upper((p and p.label) or "unknown"))
    -- A line each, rather than one line of "21K 20D 748P". Three numbers
    -- packed into a row with their units stuck to them is a thing to decode;
    -- three labelled rows are three numbers to read, and this panel already
    -- reads that way everywhere else.
    row("KILLS", tostring(sim.ship_kills(i)))
    row("DEATHS", tostring(sim.ship_deaths(i)))
    row("POINTS", tostring(sim.ship_points(i)))
    -- What killing them pays, which is the number that decides whether the
    -- rest of this matters right now.
    row("BOUNTY", tostring(sim.ship_bounty(i)), pal.a(pal.BOUNTY, 0.9))

    -- One word and a rule under it, like the menu chip, because that is what a
    -- control looks like in here. Once it is sent it says so and stops taking
    -- clicks: the zone answers an invitation with a team list that does not
    -- name the invitee, so this mark is the only acknowledgement there is, and
    -- a button that stayed pressable would invite an anxious second tap.
    if invite then
        local sent = o.invited and o.invited[i]
        local by = ry_ + 4 * S
        local c = pal.a(sent and pal.DIM or pal.FRIEND, sent and 0.7 or 0.95)
        txt(sent and "INVITED" or "INVITE", x + 12 * S, by + 9 * S,
            (FONT - 2) * S, c)
        local uy = ry(by + 17 * S)
        u:seg(x + 12 * S, uy, x + 12 * S + 46 * S, uy, 0.8 * S, pal.a(c, 0.5))
        if not sent then
            hit(x, by - 2 * S, w, 24 * S, "invite", i)
        end
    end
    return y + h
end

-- The damage vignette: red creeping in from the edges rather than a flash
-- over the middle, so it never hides the ship that is shooting you.
--
-- With the corner energy bar gone this carries more weight than it used to:
-- the vignette says "you are being hit", the hull's pip says how much is
-- left, and its colour says how urgent that is. Three channels, none of them
-- a panel.
-- --- the glossary ----------------------------------------------------------
--
-- Each card in the wait box draws the thing it is about and then says what it
-- is. That is the whole idea: a sentence about bombs is a sentence, and the
-- bomb that killed you is a shape you have seen a hundred times without ever
-- being told what it was.
--
-- The figures are the arena's own, built the way world.lua builds them, at a
-- smaller scale and standing still. Drawing a fresh icon for the purpose would
-- teach a pilot to recognise something that is not out there.
--
-- They draw into the interface layer rather than the glow one, which is alpha
-- blended and not additive, so the bloom comes from stacked translucent rings
-- instead of from adding light. Close enough at this size, and it keeps the
-- card in the layer that owns the rest of the box.

-- The bomb's own rung colour, not the top of the ladder: the top rung is
-- 0xffd166, which is also the charge colour, and a bomb drawn in it was a
-- repel with a smaller middle. Two cards that look alike teach nothing.
local function fig_bomb(cx, cy, k)
    local col = pal.BOMB_LVL[2]
    -- No trail, though it wears one in flight. Drawn inside the blast ring it
    -- stopped short of the rim and read as a stray stroke rather than as
    -- motion, and the card does not need it: against the repel below this is
    -- already the red one with something burning in the middle.
    --
    -- The blast it would throw, faint, because the blast is what a rung buys
    -- and it is what the card is about.
    u:ring(cx, ry(cy), k * 0.92, 1.0 * S, 22, pal.a(col, 0.26))
    u:halo(cx, ry(cy), k * 0.50, 12, pal.a(col, 0.45))
    u:ring(cx, ry(cy), k * 0.32, 1.6 * S, 14, pal.a(col, 0.95))
    u:disc(cx, ry(cy), k * 0.20, 10, pal.a(pal.hot(col, 0.85, 1), 0.95))
end

local function fig_bolt(cx, cy, k)
    local col = pal.ENEMY_LVL[2]
    -- Travelling left to right with its trail behind it, which is the only
    -- way a bolt is ever seen: the streak is what says which way it is going.
    --
    -- Heavier than the arena's own. Out there a bolt is three overlapping
    -- strokes on an additive layer and the light piles up; in here the layer
    -- is alpha blended, so the same numbers drew a hairline with a dot on the
    -- end. The look is matched rather than the arithmetic.
    local x0, x1 = cx - k * 0.95, cx + k * 0.5
    u:seg_fade(x0, ry(cy), x1, ry(cy), 1.0 * S, 6.5 * S, 0, 0.30, col)
    u:seg_fade(cx - k * 0.45, ry(cy), x1, ry(cy), 1.4 * S, 3.6 * S, 0, 0.85,
               col)
    u:halo(x1, ry(cy), k * 0.42, 10, pal.a(col, 0.55))
    u:disc(x1, ry(cy), k * 0.17, 8, pal.a(pal.hot(col, 0.9, 1), 1))
end

local function fig_green(cx, cy, k)
    local col = pal.PRIZE
    local r = k * 0.62
    local pts = {cx, ry(cy - r), cx + r, ry(cy), cx, ry(cy + r), cx - r, ry(cy)}
    u:halo(cx, ry(cy), k * 0.95, 10, pal.a(col, 0.16))
    u:fan(pts, pal.a(col, 0.28))
    u:outline(pts, 1.4 * S, pal.a(col, 0.95), true)
end

-- Twelve rounds where the arena throws twenty-four. A ring drawn at the real
-- count closes into a disc at this size, and what the figure has to say is
-- "every direction at once" rather than a number.
local function fig_burst(cx, cy, k)
    local col = pal.BURST
    u:halo(cx, ry(cy), k * 0.45, 12, pal.a(col, 0.25))
    for i = 0, 11 do
        local a = i * math.pi / 6
        local dx, dy = math.cos(a), math.sin(a)
        local x0, y0 = cx + dx * k * 0.30, cy + dy * k * 0.30
        local x1, y1 = cx + dx * k * 0.92, cy + dy * k * 0.92
        u:seg_fade(x0, ry(y0), x1, ry(y1), 0.8 * S, 2.6 * S, 0, 0.85, col)
        u:disc(x1, ry(y1), k * 0.075, 6, pal.a(pal.hot(col, 0.9, 1), 1))
    end
end

local function fig_repel(cx, cy, k)
    local col = pal.CHARGE_COL
    -- Rings going out and nothing in the middle, which is a shove drawn
    -- standing still. The empty centre is the point of difference from the
    -- bomb: a repel is not an object, it is a thing that happened at a place.
    u:ring(cx, ry(cy), k * 0.96, 1.1 * S, 22, pal.a(col, 0.22))
    u:ring(cx, ry(cy), k * 0.68, 1.3 * S, 18, pal.a(col, 0.48))
    u:ring(cx, ry(cy), k * 0.40, 1.5 * S, 14, pal.a(col, 0.9))
end

-- The nameplate, as a stranger wears it: a hull with a number under it. What
-- the card is about is the number, so the hull is dim and small.
local thumb    -- defined with the menu, which is the other thing that draws one
local function fig_bounty(cx, cy, k)
    thumb(cx, cy - k * 0.28, 5, pal.a(pal.ENEMY, 0.9), k * 0.042)
    txt("42", cx, cy + k * 0.88, 12 * S, pal.a(pal.BOUNTY, 0.95), "center")
end

-- Every card: the figure, the word for it, and what it does. The order is the
-- order they cycle in.
local CARDS = {
    bomb = {fig = fig_bomb, name = "BOMB",
            text = "Heavy weapon that detonates on impact. Upgrades include " ..
                   "shrapnel and proximity abilities. Proximity detonates on " ..
                   "a near miss."},
    bolt = {fig = fig_bolt, name = "BULLET",
            text = "Bullets are your rapid fire weapon. Upgrades include " ..
                   "spread and bouncing abilities."},
    green = {fig = fig_green, name = "GREEN",
             text = "Greens contain prizes that upgrade your ship. They also " ..
                    "increase your bounty."},
    repel = {fig = fig_repel, name = "REPEL",
             text = "Pushes enemy fire and ships away from you. Does not " ..
                    "affect you or your team."},
    burst = {fig = fig_burst, name = "BURST",
             text = "Fires bullets in every direction at once. Deadly at " ..
                    "close range."},
    bounty = {fig = fig_bounty, name = "BOUNTY",
              text = "Points earned for destroying an enemy. Your enemies " ..
                     "earn your bounty when they destroy you."},
}
M.CARDS = CARDS

-- What is drawn under DESTROYED while a pilot waits to fly again.
--
-- The shape is the interface's own and nothing new: a wash to lift it off the
-- arena, four chamfered corners instead of a border, a label in the small
-- grey the panels label their rows in, and the map border's tick as the rule
-- between the label and the line. Everything here is already on screen
-- somewhere else, which is the point. A death is not the moment to introduce
-- a new kind of box.
--
-- The rule doubles as the clock. It is drawn twice, dim across the full width
-- and lit across what is left of the respawn, so the same element that
-- separates the label from the tip also says how long you have to read it.
-- A numeral counting down would be a thing to watch instead of the sentence,
-- and this game has one big centred readout already.
--
-- Centred under the banner rather than in a corner, because for these three
-- seconds there is nothing to fly and nothing to look away from, and it goes
-- the instant the hull is back.
-- Where the box goes and what it holds, worked out before anything else is
-- drawn so `nameplates` can step around it in the same frame. Measuring and
-- drawing are separate for that reason alone: the box is drawn last, over
-- everything, and a rectangle published then would be a frame stale, which is
-- one frame of a stranger's name across the sentence at the moment it appears.
local function wait_layout(which)
    local card = CARDS[which]
    if not card then return nil end
    local fs = (M.compact and 10 or 12) * S
    local lab = (M.compact and 8 or 9) * S
    local pad = 14 * S
    -- Wide enough to read, never wider than the screen it is on.
    local w = math.min(430 * S, W - 40 * S)
    local inner = w - pad * 2
    -- The figure's cell, and what is left for the sentence beside it. Square,
    -- because every shape in here is drawn around its own centre and a cell
    -- that was not square would put the bomb and the flag on different axes.
    local cell = (M.compact and 40 or 48) * S
    local gap = 12 * S
    -- Wrapped to less than the column holds. A line broken at exactly the
    -- width ends flush against the padding, which reads as text that only
    -- just fitted rather than text that was laid out.
    local measure = inner - cell - gap - 6 * S
    local lines = {}
    do
        local line = nil
        for word in string.gmatch(card.text, "%S+") do
            local try = line and (line .. " " .. word) or word
            if line and text_w(try, fs) > measure then
                lines[#lines + 1] = line
                line = word
            else
                line = try
            end
        end
        if line then lines[#lines + 1] = line end
    end

    local head = 16 * S              -- label baseline inside the box
    local rule = head + 9 * S        -- the tick rule under it
    local rowh = 15 * S
    -- Tall enough for the figure or for the sentence, whichever asks for more,
    -- so a one-line card is not a box with a bomb hanging out of the bottom.
    local body = math.max(cell, #lines * rowh)
    local h = rule + 11 * S + body + 11 * S
    return {
        x = (W - w) / 2, y = H * 0.46 + (M.compact and 22 or 30) * S,
        w = w, h = h, inner = inner, pad = pad,
        fs = fs, lab = lab, head = head, rule = rule, rowh = rowh,
        cell = cell, gap = gap, body = body,
        card = card, lines = lines,
    }
end

local function wait(b, me)
    if not b then return end
    local x, y = b.x, b.y

    -- Darker than the panels' own wash. Those sit in a corner over mostly
    -- empty field; this sits in the middle of the arena, where a stranger's
    -- hull flies straight through it, and a line you have three seconds to
    -- read cannot afford to be shared with one.
    rect(x, y, b.w, b.h, pal.a(pal.BG, 0.86))
    bracket(x, y, b.w, b.h, pal.a(pal.DIM, 0.5), 12 * S, 4 * S)
    -- The word for the thing, where the panels put their row labels. It says
    -- what the figure underneath it is, which is the one job a caption has.
    txt(b.card.name, x + b.pad, y + b.head, b.lab, pal.a(pal.DIM, 0.85))

    -- The clock. `respawn_at` counts down in the core and is in every
    -- snapshot, so this is read rather than timed here: a local stopwatch
    -- would drift off the tick that actually puts the hull back.
    local left, delay = 0, 0
    if sim.ship_respawn then left, delay = sim.ship_respawn(me) end
    ticks(x + b.pad, y + b.rule, b.inner, pal.a(pal.DIM, 0.5), 14 * S)
    if delay > 0 and left > 0 then
        local frac = left / delay
        if frac > 1 then frac = 1 end
        u:seg(x + b.pad, ry(y + b.rule),
              x + b.pad + b.inner * frac, ry(y + b.rule),
              1.2 * S, pal.a(pal.FRIEND, 0.7))
    end

    -- The figure in its cell, then the sentence beside it. Both centred on
    -- the body's own middle rather than hung from the top, so a one-line card
    -- and a two-line card are both balanced against the shape.
    local top = y + b.rule + 11 * S
    local mid = top + b.body / 2
    b.card.fig(x + b.pad + b.cell / 2, mid, b.cell / 2)

    local tx = x + b.pad + b.cell + b.gap
    local ty = mid - (#b.lines - 1) * b.rowh / 2
    for _, line in ipairs(b.lines) do
        txt(line, tx, ty, b.fs, pal.a(pal.PANEL_INK, 0.92))
        ty = ty + b.rowh
    end
end

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
    -- Two words and a rule, where there were two boxed labels. A box is the
    -- one shape the rest of this game does not contain, and a control does not
    -- need one to be a control: the rule under the pair says they belong
    -- together, and the lit segment says which is on.
    local x, y = PAD * S, PAD * S
    local w, h = 52 * S, 26 * S
    txt("MENU", x, y + h / 2, (FONT - 1) * S, pal.a(pal.INK, 0.9))
    hit(x - 4 * S, y, w, h, "open")

    local bx = x + w
    txt("INFO", bx, y + h / 2, (FONT - 1) * S,
        M.details and pal.FRIEND or pal.a(pal.DIM, 0.85))
    hit(bx - 4 * S, y, w, h, "details")

    local ruley = y + h - 6 * S
    u:seg(x, ry(ruley), x + w * 2 - 16 * S, ry(ruley), 0.8 * S,
          pal.a(pal.RADAR_TILE, 0.5))
    if M.details then
        u:seg(bx, ry(ruley), bx + w - 16 * S, ry(ruley), 1.4 * S,
              pal.a(pal.FRIEND, 0.9))
    end
end

-- How good the line is, above the dial. It belongs up here with the
-- instrument rather than down in the corner with what the ship is carrying:
-- it is a fact about the connection, not about the ship.
--
-- Four bars off the round trip the predictor already measures, in ticks of a
-- centisecond. It replaces "online  err 0.0 / 1 px", which was the client's
-- own debugging left on a player's screen: nobody flying has ever made a
-- decision on a prediction error in pixels.
local function link(lag)
    local q = 4
    if lag > 24 then q = 1 elseif lag > 12 then q = 2 elseif lag > 6 then q = 3 end
    local pad = (M.compact and 8 or PAD) * S
    local right = W - pad
    local base = pad + 13 * S
    for k = 0, 3 do
        local bh = (3 + k * 2.6) * S
        local bx = right - (26 - k * 6) * S
        rect(bx, base - bh, 4 * S, bh,
             k < q and pal.a(pal.PRIZE, 0.85) or pal.a(pal.DIM, 0.22))
    end
    txt("LINK", right - 34 * S, base - 4 * S, (FONT - 3) * S,
        pal.a(pal.DIM, 0.8), "right")
    -- The dial's left edge, not the bars', because the bars are the right-hand
    -- end of a row that starts with the position readout: a word set just left
    -- of `LINK` is a word printed over `POS 382,360`. The same edge the dial's
    -- own line is set against, so the two stack into one column.
    anchor.link = {dial(), base - 4 * S}
    -- The bars and the word beside them, which is what a hand would aim at.
    -- Not as far left as the anchor: that reaches to the dial's edge so the
    -- sentence lands in clear space, and a zone that wide would swallow the
    -- position readout sitting between the two.
    zone("link", right - 40 * S, pad, 46 * S, 20 * S)
    -- The bars are the readout a player wants and the whole of it. Everything
    -- behind them is for whoever is working on this, so it hides behind the
    -- one thing on screen that is already about the connection.
    if not menu_up then
        hit(right - 40 * S, pad, 46 * S, 20 * S, "debug")
    end
end

-- The connection in numbers, for whoever is debugging it.
--
-- Deliberately plain: labelled lines of text, no instrument, no colour doing
-- work. It is read by somebody who wants a number they can quote in a bug
-- report, and every one of these has been asked for out loud at least once.
--
-- Under the dial rather than beside it, and only ever one column wide, so it
-- sits in the same place whatever the window is. It covers the feed, which is
-- the trade: both cannot have that strip, and while this is up the feed is not
-- what you are looking at.
local function debug_hud(o, top)
    if not M.debug then return end
    local st = o.stats or {}
    -- Set at body size rather than the smallest the font will draw. This is a
    -- readout somebody squints at while flying and then quotes into a bug
    -- report, and four points below the interface's own text it was neither
    -- glanceable nor quotable.
    local size = (FONT - 1) * S
    local colw = 214 * S
    local rowh = 16 * S
    local lines = {
        {"fps", string.format("%.0f", o.fps or 0)},
        {"frame", string.format("%.1f ms", (o.frame_ms or 0))},
        {"lag", string.format("%d cs", st.lag or 0)},
        {"lead", string.format("%d ticks", st.lead or 0)},
        {"err", string.format("%.1f / %.1f px", st.err or 0, st.err_max or 0)},
        {"rewind", string.format("%d ticks", st.rewind or 0)},
        {"snaps", tostring(st.snaps or 0)},
        {"down", string.format("%.1f kB/s", (o.rx_rate or 0) / 1000)},
        {"up", string.format("%.1f kB/s", (o.tx_rate or 0) / 1000)},
        {"tick", tostring(sim.tick())},
        {"ships", tostring(sim.ship_count())},
        {"shots", tostring(sim.weapon_count())},
    }
    -- Wrapped into as many columns as the room below the dial can hold. A
    -- phone in landscape is about four hundred points tall and the dial has
    -- most of that: one column of twelve rows at a size worth reading runs
    -- off the bottom of the screen, and a number nobody can see is not a
    -- readout. Two columns of six is the usual answer; a desktop window has
    -- the height for one and gets it.
    local y = (top or 0) + 6 * S
    local avail = H - y - 6 * S
    local most = math.max(1, math.floor((W - 2 * PAD * S) / colw))
    -- The narrowest panel that fits, and a little type-shrinking is cheaper
    -- than another column: three columns of four reach most of the way across
    -- a phone held sideways and lie over the game, where two columns four per
    -- cent smaller sit in the corner and read the same. So take the first
    -- column count whose rows fit outright or all but, and only widen when
    -- the squeeze would start to hurt.
    local cols, per, k = most, 1, 1
    for c = 1, most do
        local p = math.ceil(#lines / c)
        local need = 24 * S + p * rowh + 6 * S
        local fit = (need <= avail) and 1 or (avail - 30 * S) / (p * rowh)
        if fit >= 0.85 or c == most then
            cols, per, k = c, p, math.max(0.62, math.min(1, fit))
            break
        end
    end
    rowh = rowh * k
    size = size * k
    local h = 24 * S + per * rowh + 6 * S
    local w = colw * cols
    local x = W - PAD * S - w
    rect(x, y, w, h, pal.a(pal.BG, 0.78))
    vrule(x, y, h, pal.a(pal.PRIZE, 0.8))
    txt("DEBUG", x + 10 * S, y + 15 * S, size, pal.a(pal.PRIZE, 0.9))
    -- The zone's name and nothing else. The wire sends the description on a
    -- second line of the same message, and a sentence about the game is not a
    -- diagnostic: it wrapped the header in prose that never changes while the
    -- numbers under it do.
    txt((o.zone or ""):match("^[^\n]*"), x + w - 10 * S, y + 15 * S, size,
        pal.a(pal.DIM, 0.8), "right")
    for n, l in ipairs(lines) do
        local c = math.floor((n - 1) / per)
        local cx = x + c * colw
        local ly = y + 24 * S + ((n - 1) % per) * rowh
        txt(l[1], cx + 10 * S, ly + rowh / 2, size, pal.a(pal.DIM, 0.8))
        txt(l[2], cx + colw - 10 * S, ly + rowh / 2, size,
            pal.a(pal.INK, 0.9), "right")
    end
end

-- Where you are, over the dial's other top corner from the link readout.
--
-- In tiles, because that is the unit the map is laid out in and the unit a
-- player says out loud. Pixels would be the same place in numbers six digits
-- long that nobody can hold in their head or call across a room.
local function coords(me)
    local pad = (M.compact and 8 or PAD) * S
    local x = dial()
    local base = pad + 13 * S
    txt("POS", x, base - 4 * S, (FONT - 3) * S, pal.a(pal.DIM, 0.8))
    txt(string.format("%d,%d", math.floor(sim.ship_x(me) / 16),
                      math.floor(sim.ship_y(me) / 16)),
        x + 26 * S, base - 4 * S, (FONT - 3) * S, pal.a(pal.INK, 0.85))
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

-- --- the help overlay ------------------------------------------------------
--
-- Held, never toggled. H down and the screen names its own parts; H up and it
-- is gone. That is the difference between something you consult in the middle
-- of a fight and a panel you have to remember to shut, and it is why there is
-- no way to leave this open by accident.
--
-- No leader lines anywhere in it, which was the whole lesson of the first
-- draft. Every instrument on this screen already sits against an edge with
-- clear space beside it, so a word set next to a thing is read as being about
-- that thing, and the eleven strokes crossing open sky to reach eleven
-- captions were doing nothing except making the screen unreadable. What is
-- left is one line per instrument, in the colour that instrument already
-- wears, and only where the label on the row does not say it already: GUN and
-- BOMB name themselves, so those lines explain the rung rather than the word.

-- A bar in the thing's own colour, then the sentence. The bar sits on the side
-- facing whatever is being named, so it points without a line.
local function help_mark(x, y, s, col, align)
    local f = (FONT - 1) * S
    if align == "right" then
        rect(x - 3 * S, y - 6.5 * S, 3 * S, 13 * S, pal.a(col, 0.85))
        txt(s, x - 11 * S, y, f, pal.a(pal.INK, 0.95), "right")
    else
        rect(x, y - 6.5 * S, 3 * S, 13 * S, pal.a(col, 0.85))
        txt(s, x + 11 * S, y, f, pal.a(pal.INK, 0.95))
    end
end

-- Every line the overlay can draw, and which instrument each one belongs to.
--
-- Built rather than drawn directly, because the same list answers two
-- questions. Holding H draws all of it. Resting the pointer on one instrument
-- draws that instrument's line and nothing else, and the key it is filed under
-- is what makes "that one" a thing this file can say.
local function help_lines(o)
    local out = {}
    local function add(key, x, y, s, col, align)
        local e = {key = key, x = x, y = y, s = s, col = col, align = align}
        out[#out + 1] = e
        return e
    end
    local sx = anchor.stack_x
    if sx then
        if anchor.gun then
            add("gun", sx, anchor.gun, "at its rung, and what is bolted on",
                pal.FRIEND)
        end
        if anchor.bomb then
            add("bomb", sx, anchor.bomb, "a rung buys blast, not damage",
                pal.BOMB)
        end
        -- One bar down the side of however many charge rows there are, and one
        -- sentence against the middle of it.
        if anchor.chg_top then
            local e = add("charges", sx, (anchor.chg_top + anchor.chg_bot) / 2,
                          "digits 1 to 4 spend these, top down",
                          pal.CHARGE_COL)
            e.top, e.bot = anchor.chg_top, anchor.chg_bot
        end
        if anchor.bounty then
            add("bounty", sx, anchor.bounty, "what a kill on you pays",
                pal.PRIZE)
        end
    end
    if anchor.radar then
        add("radar", anchor.radar[1] - 16 * S, anchor.radar[2],
            M.map and "the whole arena, and you as the arrow"
            or "near space. the rings are range.",
            pal.RADAR_TILE, "right")
    end
    -- Not while the map is up. The readouts along the top right start at the
    -- dial's left edge, and the map is four times the dial, so that edge lands
    -- near the middle of the screen and the only space left beside `POS` is
    -- the strip the flags fly in. A word with nowhere to go is not drawn: the
    -- whole method here is space beside the thing, and when there is none the
    -- honest answer is to say nothing rather than to print over the flags.
    if anchor.link and not M.map then
        add("link", anchor.link[1] - 16 * S, anchor.link[2],
            "your line to the arena", pal.DIM, "right")
    end
    if anchor.feed then
        add("feed", anchor.feed[1], anchor.feed[2], "who paid whom",
            pal.BOUNTY, "right")
    end
    -- Your own hull is the one in the middle of the screen, and the pip above
    -- it is the same pip every other hull wears. Projected the way nameplates
    -- projects, off the half-extents the render script publishes, so the word
    -- lands on the bar at any camera.
    if o.half_w and o.half_w > 0 then
        local scale = W / (2 * o.half_w)
        add("energy", W / 2 + 13 * scale, H / 2 - 26 * scale,
            "armour and ammunition, one pool", pal.FRIEND)
    end
    return out
end

local function help_draw(e)
    if e.top then
        -- The charge rows are one idea however many of them a hull carries, so
        -- the bar runs the height of all of them.
        rect(e.x, e.top - 6.5 * S, 3 * S, e.bot - e.top + 13 * S,
             pal.a(e.col, 0.85))
        txt(e.s, e.x + 11 * S, e.y, (FONT - 1) * S, pal.a(pal.INK, 0.95))
    else
        help_mark(e.x, e.y, e.s, e.col, e.align)
    end
end

local function help_overlay(o)
    for _, e in ipairs(help_lines(o)) do help_draw(e) end
    -- The one thing the overlay cannot say by pointing at it.
    txt("let go and it is gone", W / 2, H - 20 * S, (FONT - 3) * S,
        pal.a(pal.DIM, 0.8), "center")
end

-- The pointer resting on one instrument names that instrument, and nothing
-- else happens: no wash, no other lines, no key held. Holding H is the whole
-- screen at once and reads as a mode; this is a question asked of one thing
-- and has to cost about as much as looking at it.
local function help_hover(o, key)
    for _, e in ipairs(help_lines(o)) do
        if e.key == key then help_draw(e) return end
    end
end

function M.hud(o)
    if sim.ship_count() == 0 then return end
    local me = o.me
    menu_up = o.menu_open
    -- Under the menu the instruments stay -- you can still be shot while you
    -- are reading -- but they stop competing with it. A third of their light
    -- is enough to keep a glance at your energy or the dial worth taking and
    -- not enough to read across the panel.
    text_dim = o.menu_open and 0.34 or 1

    -- Measured first, drawn last. Nameplates need to know where it is before
    -- they draw, and it needs to sit over everything, so the two happen at
    -- opposite ends of this function. Nil whenever it will not be drawn:
    -- alive, or under the menu, which takes the centre of the screen for
    -- itself and puts both of these away.
    wait_box = nil
    if not o.menu_open and sim.ship_alive(me) == 0 then
        wait_box = wait_layout(o.tip)
    end

    -- The scenery dims and the instruments do not, so the wash goes down
    -- before any of them and over the whole arena. Nothing is paused while
    -- this is up: you can be killed reading it, and anything that helps you
    -- fly has to stay exactly as bright as it was.
    --
    -- Not under the menu, which is a different screen with its own help page
    -- on it. Two of these reading at once is neither.
    local help = M.help and not o.menu_open
    if help then rect(0, 0, W, H, pal.rgb(0x03050a, 0.60)) end

    -- On a touchscreen the bottom of the screen belongs to the thumbs. The
    -- stick sits in the bottom left corner and the pads in the bottom right,
    -- which is exactly where the status panel and the control hint were, so
    -- everything else moves up out of the way of them.
    local lift = M.touching and 150 * S or 0

    local top = scores(me, o.pilots)
    -- Names hanging off ships, but not under the menu. Glyphs come from the
    -- gui and the gui draws over every mesh, so nothing the menu lays down
    -- can cover them: a panel with six pilots' names scattered through it
    -- reads as a fault rather than as depth. The instruments stay -- your
    -- bars, the dial, the feed -- because you can still be shot while you
    -- are reading, and those are what say so.
    if not o.menu_open then nameplates(o) end
    -- One corner, one instrument. The map is the radar pulled back to the
    -- whole thousand tiles, so it stands where the radar stands rather than
    -- somewhere else with the radar still lit beside it.
    if M.map then overview(me) else radar(o.cam_x, o.cam_y, me) end
    link(o.lag or 0)
    coords(me)
    -- Under the dial, wherever the dial now ends: it lost its panel and its
    -- padding, so a constant here would have left a gap or an overlap. Not on
    -- a touchscreen: the lines land where a thumb flies the ship, and a
    -- phone's screen has no room for a running log a player cannot pause to
    -- read anyway.
    -- The debug readout wants the same strip the feed does, and takes it: a
    -- reader who opened it is reading it rather than the kill lines.
    if M.debug then
        debug_hud(o, M.radar_span())
    elseif not M.touching then
        feed(o.feed, M.radar_span())
    end
    -- Stacked, not overlaid: the panel that is always there sits at the
    -- bottom and the one you asked for sits on top of it.
    status(me, o.pickup, o.charges, lift)
    inspect(o, loadout(me, o.class_names, top))
    menu_button()
    vignette(o.hurt or 0)
    -- The pip over your own hull, which the world layer draws and this file
    -- only names. Filed here because the projection is known here.
    if o.half_w and o.half_w > 0 then
        local sc = W / (2 * o.half_w)
        zone("energy", W / 2 - 11 * sc, H / 2 - 30 * sc, 22 * sc, 9 * sc)
    end
    -- Last, so every word lands on top of the instrument it names.
    --
    -- Held wins over hovered. H is a deliberate "explain the screen" and the
    -- pointer is often somewhere by accident, so a hand resting on the dial
    -- must not quietly cut the other eight lines out of a mode the player
    -- asked for.
    if help then
        help_overlay(o)
    elseif not o.menu_open then
        local key = M.help_at(o.point_x, o.point_y)
        if key then help_hover(o, key) end
    end

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
        wait(wait_box, me)
    end
end

-- --- the menu --------------------------------------------------------------

-- A hull drawn small, inside its button. The silhouette is what picks a ship;
-- the name only confirms it. The canopy comes along because at this size it is
-- the only thing that says which end is the front.
function thumb(cx, cy, cls, col, scale)
    local h = world.HULLS[cls + 1]
    if not h then return end
    local function trace(src, width, c)
        local pts = {}
        for i = 1, #src, 2 do
            pts[i] = cx + src[i] * scale
            pts[i + 1] = ry(cy - (src[i + 1] - h.mid) * scale)
        end
        u:outline(pts, width, c, true)
    end
    trace(h.poly, 1.4 * S, col)
    if h.canopy then trace(h.canopy, 1.0 * S, pal.a(col, 0.55)) end
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

-- The help page's keyboard, drawn as a keyboard.
--
-- The controls were a column of sentences, which is a wall of text about a
-- thing everybody already has a picture of under their hands. So the picture
-- is what gets drawn: the board itself, unbound keys as faint outlines and
-- the bound ones lit in the colour of what they do, with a legend saying what
-- each colour is. A key does not need a caption when the board it sits on
-- says where it is.
--
-- Widths are in key units so the board scales with the panel. The rows are
-- the standard board's, minus the function row nothing binds.
local BOARD = {
    {{"esc", 1.3, "ui"}, {"1", 1, "charge"}, {"2", 1, "charge"},
     {"3", 1, "charge"}, {"4", 1, "charge"}, {"5"}, {"6"}, {"7"}, {"8"},
     {"9"}, {"0"}},
    {{"tab", 1.7, "bomb"}, {"Q", 1, "ui"}, {"W"}, {"E"}, {"R"}, {"T"}, {"Y"},
     {"U"}, {"I", 1, "ui"}, {"O"}, {"P"}},
    {{"caps", 2.0}, {"A"}, {"S"}, {"D"}, {"F"}, {"G"}, {"H", 1, "ui"}, {"J"},
     {"K"}, {"L"}},
    {{"shift", 2.25, "gun"}, {"Z", 1, "gun"}, {"X", 1, "bomb"}, {"C"}, {"V"},
     {"B"}, {"N"}, {"M", 1, "ui"}},
    {{"ctrl", 1.6, "gun2"}, {"space", 6.2, "gun"}},
}
-- The board is 12.4 units across, and the arrow cluster hangs off its right
-- edge over the two bottom rows, where the letter rows have already ended.
local BOARD_UNITS = 12.4
-- How wide the page that draws it may go, against the 460 every other page
-- takes. A menu of six words does not want the room; a picture of a keyboard
-- with four lines of caption under it does, and on a desktop window there is
-- a thousand points of it going spare. The column keeps its left edge and
-- grows to the right, so nothing jumps when the page changes.
-- Everything on the board is sized off the key, so the whole picture scales
-- with the panel rather than a drawing growing around type that does not.
local KEY_LETTER = 0.40   -- a single character, against key height
local KEY_WORD = 0.30     -- "shift", "space": the ones that have to fit across
local CAP_SIZE = 0.30     -- the caption lines under the legend
local CAP_PITCH = 0.46

-- What each colour means, in the order the legend reads.
local BOARD_CATS = {
    {key = "fly", word = "fly"},
    {key = "gun", word = "guns"},
    {key = "bomb", word = "bombs"},
    {key = "charge", word = "charges"},
}

-- What a drawing of a keyboard cannot say, in as few lines as it can be said.
-- Up here rather than inside `board` because the panel has to be sized before
-- it is drawn, and a count written twice is a count that goes stale: adding
-- the line about H to the list and leaving a 4 in the height is exactly the
-- kind of drift this file has been bitten by.
local BOARD_CAPS = {
    "mouse: left guns, right bombs, wheel scrolls lists",
    "Q holds a multifire gun to one shot; I scores, M map, esc menu",
    "1 to 4 spend the charges as the corner stack lists them",
    -- No longer than the longest line already here: the captions are set off
    -- the key size now, and at 700 points across a line of 69 characters runs
    -- off the right of the board. board_test measures exactly that.
    "hold H and the screen names its own parts",
    "in fullscreen ctrl joins the guns, where the browser allows it",
}

local function board_col(cat)
    if cat == "gun" then return pal.FRIEND end
    if cat == "bomb" then return pal.BOMB end
    if cat == "charge" then return pal.CHARGE_COL end
    if cat == "fly" then return pal.INK end
    if cat == "ui" then return pal.a(pal.DIM, 1.0) end
    return nil
end

-- One key: an outline in its function's colour with a hint of fill, or a
-- faint outline for a key the game does not use. `cy` is the row's top.
local function board_key(bx, cy, kw, kh, label, cat, dimmed)
    local col = board_col(cat)
    if col and not dimmed then
        rect(bx, cy, kw, kh, pal.a(col, 0.10))
        u:frame(bx, ry(cy, kh), kw, kh, 1.1 * S, pal.a(col, 0.85))
    elseif col then
        -- Ctrl: a gun the browser only surrenders in fullscreen, drawn at
        -- half light so the board says "sometimes" without a footnote on it.
        u:frame(bx, ry(cy, kh), kw, kh, 1.1 * S, pal.a(col, 0.35))
    else
        u:frame(bx, ry(cy, kh), kw, kh, 0.8 * S, pal.a(pal.DIM, 0.22))
    end
    if label then
        local size = kh * (#label > 1 and KEY_WORD or KEY_LETTER)
        -- A word on a one-unit key would run over both its edges, so it takes
        -- whichever is smaller: the key's height or the room across it.
        local across = (kw - 6 * S) / (#label * ADVANCE)
        if size > across then size = across end
        local ink = col and pal.a(col, dimmed and 0.5 or 0.95)
            or pal.a(pal.DIM, 0.4)
        txt(label, bx + kw / 2, cy + kh / 2, size, ink, "center")
    end
end

-- A direction, as a triangle, because the gui font's charset is picked over
-- and an arrow glyph it does not carry would draw as nothing.
local function board_arrow(cx, cy, dx, dy, col)
    local r = 3.6 * S
    u:tri(cx + dx * r, ry(cy + dy * r),
          cx - dx * r + dy * r, ry(cy - dy * r - dx * r),
          cx - dx * r - dy * r, ry(cy - dy * r + dx * r), col)
end

-- The whole board, drawn into the panel at `x, top`, `w` wide. Returns its
-- height so the caller can size the panel around it.
local function board(x, top, w)
    local unit = w / BOARD_UNITS
    local kh = unit * 0.82
    local pitch = kh + 3 * S
    for r, row in ipairs(BOARD) do
        local bx = x
        local cy = top + (r - 1) * pitch
        for _, k in ipairs(row) do
            local kw = (k[2] or 1) * unit - 3 * S
            board_key(bx, cy, kw, kh, k[1], k[3], k[3] == "gun2")
            bx = bx + (k[2] or 1) * unit
        end
    end
    -- The arrows, as the inverted T they are on the board: up over down, in
    -- the corner the two bottom rows leave empty. Each entry is a column, a
    -- row off the shift row, and the direction its triangle points.
    local fly = board_col("fly")
    local aw = unit * 0.92
    local ax = x + w - 3 * aw
    for _, d in ipairs({{1, 0, 0, -1}, {0, 1, -1, 0}, {1, 1, 0, 1},
                        {2, 1, 1, 0}}) do
        local kx = ax + d[1] * aw
        local cy = top + (3 + d[2]) * pitch
        local kw = aw - 3 * S
        rect(kx, cy, kw, kh, pal.a(fly, 0.08))
        u:frame(kx, ry(cy, kh), kw, kh, 1.1 * S, pal.a(fly, 0.75))
        board_arrow(kx + kw / 2, cy + kh / 2, d[3], d[4], pal.a(fly, 0.95))
    end

    -- The legend: a swatch per colour, one line. Sized off the key like
    -- everything else here, so a wide board does not end up captioned in
    -- type meant for a narrow one.
    local lsize = math.max((FONT - 3) * S, kh * 0.34)
    local sw = lsize * 0.7
    local ly = top + 5 * pitch + 10 * S
    local lx = x
    for _, c in ipairs(BOARD_CATS) do
        local col = board_col(c.key)
        rect(lx, ly + lsize * 0.2, sw, sw, pal.a(col, 0.9))
        txt(c.word, lx + sw + 6 * S, ly + lsize / 2, lsize,
            pal.a(pal.DIM, 0.95))
        lx = lx + sw + 6 * S + text_w(c.word, lsize) + 18 * S
    end

    local csize = math.max((FONT - 3) * S, kh * CAP_SIZE)
    local cpitch = math.max(14 * S, kh * CAP_PITCH)
    local cy = ly + lsize + 12 * S
    for _, line in ipairs(BOARD_CAPS) do
        txt(line, x, cy, csize, pal.a(pal.DIM, 0.85))
        cy = cy + cpitch
    end
    return (cy - top) + 2 * S
end

-- What the board will ask for, so the panel can be sized before drawing it.
-- Every term here is one the drawing uses, in the same order it uses them:
-- five key rows, the gap to the legend, the legend, and the captions, counted
-- off the list itself rather than written down a second time.
local function board_height(w)
    local kh = (w / BOARD_UNITS) * 0.82
    local lsize = math.max((FONT - 3) * S, kh * 0.34)
    local cpitch = math.max(14 * S, kh * CAP_PITCH)
    return 5 * (kh + 3 * S) + 10 * S + lsize + 12 * S
           + #BOARD_CAPS * cpitch + 2 * S
end

-- --- the menu -------------------------------------------------------------
--
-- A rail of destinations and a stage showing what the one you are on holds.
--
-- The old menu was one column of words: a title, `label ....... value` rows,
-- and a sentence underneath. It read the same on a phone and on a desktop,
-- which meant it was laid out for neither, and every level looked like every
-- other level, so nothing on screen told you where you were except a word at
-- the top.
--
-- What replaces it is two things that do not move. The rail carries the
-- destinations as marks -- play, ship, pilot, settings -- and stays put
-- whatever level you are at, so the answer to "where am I" is a lit icon
-- rather than a breadcrumb to read. The stage beside it shows what the rail
-- is pointing at, filled in already rather than after a keystroke: moving
-- down the rail on a home screen walks you through the games, the hulls and
-- the settings without choosing anything.
--
-- Three shapes, from one rule about the window rather than a guess about the
-- device:
--
--   wide and tall    rail down the left with its labels, stage beside it
--   wide and short   the same, icons only, because eight labelled stops do
--                    not fit a phone held sideways
--   narrow           stage above, rail along the bottom where the thumbs are
--
-- The five inputs are unchanged, and so are the sounds: up and down move,
-- right or enter goes in, left or escape comes back. A pointer may land on
-- either half, which is the one thing the keyboard cannot do and the reason
-- the stage publishes its own hit boxes.

local MENU_FONT = "menu"

-- --- marks -----------------------------------------------------------------
--
-- Every destination gets a drawing rather than a word, in the same strokes
-- the hulls and the walls are made of: thin lines, chamfered corners, a
-- little fill where something is solid. They are drawn at a radius so the
-- rail can size them, and they are the only place in this interface where a
-- shape has to carry a meaning on its own -- so each one is a picture of the
-- thing it opens, not a symbol somebody has to learn.

local function mark_play(cx, cy, r, col)
    local pts = {cx - r * 0.55, ry(cy - r * 0.8), cx + r * 0.9, ry(cy),
                 cx - r * 0.55, ry(cy + r * 0.8)}
    u:fan(pts, pal.a(col, 0.16))
    u:outline(pts, 1.3 * S, col, true)
end

local function mark_pilot(cx, cy, r, col)
    -- A call sign on a plate: the chamfer top left, a dot for the mark and
    -- two rules for the name, which is what the scoreboard row looks like
    -- from far enough away.
    local w, h, c = r * 1.7, r * 1.25, r * 0.34
    local x0, y0 = cx - w / 2, cy - h / 2
    local pts = {x0 + c, ry(y0), x0 + w, ry(y0), x0 + w, ry(y0 + h),
                 x0, ry(y0 + h), x0, ry(y0 + c)}
    u:outline(pts, 1.2 * S, col, true)
    u:disc(x0 + r * 0.42, ry(cy - r * 0.02), r * 0.17, 8, col)
    u:seg(x0 + r * 0.75, ry(cy - r * 0.22), x0 + w - r * 0.28,
          ry(cy - r * 0.22), 1.0 * S, pal.a(col, 0.75), true)
    u:seg(x0 + r * 0.75, ry(cy + r * 0.24), x0 + w - r * 0.5,
          ry(cy + r * 0.24), 1.0 * S, pal.a(col, 0.5), true)
end

local function mark_team(cx, cy, r, col)
    -- Two pennants, which is what a flag is drawn as in the world.
    for i, k in ipairs({{-0.5, 0.85}, {0.35, 1.0}}) do
        local px, s = cx + r * k[1], r * k[2]
        u:seg(px, ry(cy - s * 0.9), px, ry(cy + s * 0.85), 1.2 * S,
              pal.a(col, i == 2 and 1 or 0.6), true)
        local pts = {px, ry(cy - s * 0.9), px + s * 0.85, ry(cy - s * 0.55),
                     px, ry(cy - s * 0.2)}
        u:fan(pts, pal.a(col, i == 2 and 0.22 or 0.12))
        u:outline(pts, 1.1 * S, pal.a(col, i == 2 and 1 or 0.6), true)
    end
end

local function mark_settings(cx, cy, r, col)
    -- Three rules with a knob apiece, at three different settings, because a
    -- row of identical sliders is a picture of nothing being adjustable.
    for i, k in ipairs({-0.62, 0, 0.62}) do
        local y = cy + r * k
        u:seg(cx - r, ry(y), cx + r, ry(y), 1.0 * S, pal.a(col, 0.45), true)
        local kx = cx + r * ({-0.3, 0.42, -0.05})[i]
        rect(kx - r * 0.17, y - r * 0.26, r * 0.34, r * 0.52, col)
    end
end

local function mark_help(cx, cy, r, col)
    -- A key off the board the page draws, with the question on it.
    local w, h, c = r * 1.5, r * 1.5, r * 0.3
    local x0, y0 = cx - w / 2, cy - h / 2
    local pts = {x0 + c, ry(y0), x0 + w, ry(y0), x0 + w, ry(y0 + h - c),
                 x0 + w - c, ry(y0 + h), x0, ry(y0 + h), x0, ry(y0 + c)}
    u:fan(pts, pal.a(col, 0.10))
    u:outline(pts, 1.2 * S, col, true)
    txt("?", cx, cy, r * 1.25, col, "center")
end

local function mark_about(cx, cy, r, col)
    u:ring(cx, ry(cy), r * 0.86, 1.15 * S, 18, col)
    u:disc(cx, ry(cy - r * 0.4), r * 0.15, 8, col)
    u:seg(cx, ry(cy - r * 0.05), cx, ry(cy + r * 0.45), 1.4 * S, col, true)
end

local function mark_leave(cx, cy, r, col)
    -- A doorway with the arrow going out of it, drawn open on the side the
    -- arrow leaves by so the shape says which way it means.
    local pts = {cx + r * 0.15, ry(cy - r * 0.9), cx - r * 0.85,
                 ry(cy - r * 0.9), cx - r * 0.85, ry(cy + r * 0.9),
                 cx + r * 0.15, ry(cy + r * 0.9)}
    u:outline(pts, 1.2 * S, pal.a(col, 0.8), false)
    u:seg(cx - r * 0.2, ry(cy), cx + r * 0.85, ry(cy), 1.3 * S, col, true)
    u:tri(cx + r, ry(cy), cx + r * 0.45, ry(cy - r * 0.4),
          cx + r * 0.45, ry(cy + r * 0.4), col)
end

-- The hull is its own mark: the ship you are flying, drawn as the ship you
-- are flying. Nothing else in the rail has to be looked up.
local function mark_ship(cx, cy, r, col, cls)
    thumb(cx, cy, cls or 0, col, r / 17)
end

local MARKS = {play = mark_play, pilot = mark_pilot, team = mark_team,
               settings = mark_settings, help = mark_help, about = mark_about,
               leave = mark_leave}

local function draw_mark(kind, cx, cy, r, col, cls)
    if kind == "ship" then return mark_ship(cx, cy, r, col, cls) end
    local f = MARKS[kind] or mark_about
    f(cx, cy, r, col)
end

-- --- the stage -------------------------------------------------------------

-- How full a room is, as pips rather than a sentence. Filled for people,
-- outlined for the AI holding seats until people arrive, so a glance says
-- both how busy a game is and how much of that is real.
-- Who is in a room, as two counts with a mark apiece rather than a sentence.
--
-- Pips were tried first and read as a dashed line: a room with fifty bots and
-- nobody in it lit nothing, which is honest and says nothing. A filled dot
-- for people and the same bot mark the scoreboard wears for the AI holding
-- seats says both numbers at a glance, and the marks are ones a player has
-- already met in flight.
local function population(x, y, players, bots, col)
    local right = x
    if bots and bots > 0 then
        txt(tostring(bots), right, y, 12 * S, pal.a(pal.DIM, 0.9), "right")
        bot_mark(right - text_w(tostring(bots), 12 * S) - 14 * S, y,
                 pal.a(pal.DIM, 0.75), 9 * S)
        right = right - text_w(tostring(bots), 12 * S) - 26 * S
    end
    local pc = players > 0 and col or pal.a(pal.DIM, 0.8)
    txt(tostring(players), right, y, 13 * S, pc, "right")
    u:disc(right - text_w(tostring(players), 13 * S) - 9 * S, ry(y), 3.2 * S,
           10, pc)
end

-- One row of the stage: a mark for the one you are on, the name, and
-- whatever the row has to say about itself on the right.
local function stage_row(x, y, w, h, r, sel, focused, live)
    local col = r.mark and pal.FRIEND or pal.INK
    if sel and focused then
        rect(x, y, w, h, pal.a(pal.FRIEND, 0.09))
        bracket(x, y, w, h, pal.a(pal.FRIEND, 0.9), 12 * S, 4 * S)
    elseif sel then
        rect(x, y, w, h, pal.a(pal.INK, 0.04))
    end
    local tx = x + 16 * S
    if r.mark then
        -- Where you already are: a lit wedge, the same one the corner stack
        -- uses to say a slot is the ready one.
        u:tri(tx, ry(y + h / 2 - 4.5 * S), tx + 7 * S, ry(y + h / 2),
              tx, ry(y + h / 2 + 4.5 * S), pal.FRIEND)
        tx = tx + 15 * S
    end
    local size = (M.compact and 17 or 18) * S
    -- Drawn here unless the detail turns out not to fit beside it, in which
    -- case the pair is laid out as two lines below and this one is skipped.
    local two_line = r.detail and r.detail ~= "" and not r.players
        and not r.choice
        and text_w(r.detail, 12 * S) > w - 32 * S - (tx - x) - 12 * S
    if not two_line then
        txt(r.label or "", tx, y + h / 2, size,
            pal.a(col, (sel or r.mark) and 1 or 0.82), nil, MENU_FONT)
    end
    -- The right hand side is data, so it stays in the face the numbers in
    -- flight are set in: a call sign, a count, a hull's name.
    if r.players and r.live then
        population(x + w - 16 * S, y + h / 2, r.players, r.bots,
                   pal.a(pal.FRIEND, sel and 1 or 0.85))
    elseif r.choice then
        -- A setting drawn as its own range: one step per value, the one it
        -- is on filled. "half" is a word to read and hold against the word
        -- on the row above; three steps of four lit is a position, and a
        -- press moves it along.
        local n = r.choices or 1
        local sw2 = 13 * S
        local gap = 5 * S
        local x1 = x + w - 16 * S
        local x0 = x1 - (n * sw2 + (n - 1) * gap)
        for i = 1, n do
            local px = x0 + (i - 1) * (sw2 + gap)
            if i <= r.choice then
                rect(px, y + h / 2 - 5 * S, sw2, 10 * S,
                     pal.a(pal.FRIEND, sel and 1 or 0.8))
            else
                u:frame(px, ry(y + h / 2 - 5 * S, 10 * S), sw2, 10 * S,
                        1.0 * S, pal.a(pal.DIM, 0.45))
            end
        end
        if r.detail and r.detail ~= "" then
            txt(r.detail, x0 - 12 * S, y + h / 2, 11 * S,
                pal.a(pal.DIM, 0.8), "right")
        end
    elseif r.detail and r.detail ~= "" then
        -- Beside the label where it fits, under it where it does not. The
        -- help rows a phone gets are sentences -- "left thumb: point where
        -- you want the nose" -- and right-aligned in a column 350 points
        -- wide they ran back under the word they belong to.
        --
        -- `two_line` decides it, once, above: asking the same question in
        -- two places is how a row ends up with its label drawn twice, or not
        -- at all, the day somebody edits one of them.
        if two_line then
            txt(r.label or "", tx, y + h * 0.32, size,
                pal.a(col, (sel or r.mark) and 1 or 0.82), nil, MENU_FONT)
            txt(r.detail, tx, y + h * 0.70, 11 * S, pal.a(pal.DIM, 0.9))
        else
            txt(r.detail, x + w - 16 * S, y + h / 2, 12 * S,
                pal.a(r.mark and pal.FRIEND or pal.DIM, 0.95), "right")
        end
    end
end

-- The hulls, as hulls. A list of eight names is eight words about drawings
-- the game already owns, and picking a ship from a menu that shows you the
-- ships is the one page that does not need reading at all.
local function ship_grid(x, y, w, h, v, focused)
    local n = #v.rows
    if n == 0 then return end
    local cols = (w / S >= 420) and 4 or 2
    local rowsn = math.ceil(n / cols)
    local cw = w / cols
    local ch = math.min(h / rowsn, (M.compact and 92 or 104) * S)
    -- Centred in the room it was given rather than hung off the top, so a
    -- tall phone does not draw eight ships in the top third of the screen.
    y = y + math.max(0, (h - ch * rowsn) / 2)
    for i, r in ipairs(v.rows) do
        local c, rr = (i - 1) % cols, math.floor((i - 1) / cols)
        local cx = x + c * cw + cw / 2
        local cy = y + rr * ch + ch / 2
        local sel = (i == v.sel)
        local col = r.mark and pal.FRIEND or pal.INK
        if sel and focused then
            bracket(x + c * cw + 4 * S, y + rr * ch + 2 * S, cw - 8 * S,
                    ch - 4 * S, pal.a(pal.FRIEND, 0.9), 12 * S, 4 * S)
        end
        if r.mark then
            rect(x + c * cw + 4 * S, y + rr * ch + 2 * S, cw - 8 * S,
                 ch - 4 * S, pal.a(pal.FRIEND, 0.07))
        end
        thumb(cx, cy - ch * 0.12, r.hull or 0,
              pal.a(col, (sel or r.mark) and 1 or 0.7), ch / 116)
        txt(r.label or "", cx, cy + ch * 0.30, (M.compact and 14 or 15) * S,
            pal.a(col, (sel or r.mark) and 1 or 0.8), "center", MENU_FONT)
        if r.role then
            txt(r.role, cx, cy + ch * 0.44, 10 * S, pal.a(pal.DIM, 0.9),
                "center")
        end
        hit(x + c * cw, y + rr * ch, cw, ch, "stage", i)
    end
end

-- The name, and the stroke under it that makes it a mark.
--
-- Not a logotype: the same face the menu is set in, at a size nothing else on
-- screen is. What makes it ours is the stroke beneath, which starts at
-- nothing on the left, swells under the word and is gone again by the end of
-- it, which is a wake. It was here before this layout and it stays: the one
-- piece of decoration in the whole interface that anybody has asked to keep.
local function wordmark(x, y, size, ww)
    txt("vectorwake", x, y, size, pal.INK, nil, MENU_FONT)
    local wy = y + size * 0.78
    local n = 40
    for i = 0, n - 1 do
        local t0, t1 = i / n, (i + 1) / n
        local function swell(t) return math.sin(t * math.pi) ^ 1.6 end
        local a0, a1 = swell(t0), swell(t1)
        u:seg_fade(x + ww * t0, ry(wy), x + ww * t1, ry(wy),
                   (0.7 + 2.6 * a0) * S, (0.7 + 2.6 * a1) * S,
                   0.85 * a0, 0.85 * a1, pal.FRIEND)
    end
end

-- --- the whole thing -------------------------------------------------------

function M.menu(v)
    text_dim = 1
    local pts_w, pts_h = W / S, H / S
    -- One rule about the window, three layouts. 620 points is where a rail
    -- with its labels and a stage worth reading stop fitting side by side;
    -- 430 is where eight labelled stops stop fitting down the side.
    local narrow = pts_w < 620
    local labelled = pts_h >= 430
    local rail = v.rail or {}
    local n = #rail
    -- Is there a game behind this, or the starfield. Every measurement below
    -- that depends on the window depends on this and on nothing else, so the
    -- rail and the stage are in the same place on every screen of the menu:
    -- what changes as you move around is what is written in them.
    local home = v.home

    -- Not a curtain. Over an arena you can see the fight you left, and that
    -- you are still in it; on the way in the starfield is what is behind it.
    -- Heavier over a game than over a starfield, because a wall lit at the
    -- edge and a kill feed are a great deal more to read through than stars,
    -- and a menu you have to squint past the game to read is not a menu.
    local base = home and 0.6 or 0.78
    rect(0, 0, W, H, pal.rgb(0x03050a, narrow and (base + 0.08) or base))

    local margin = (narrow and 18 or 40) * S
    local head = 0
    if home then head = (narrow and 54 or 76) * S end

    local rx, ry_, rw, rh          -- the rail
    local sx, sy, sw, sh           -- the stage
    local vertical = not narrow

    if vertical then
        local total = math.min(W - 2 * margin, 940 * S)
        local x0 = (W - total) / 2
        -- Clear of what the ship is carrying. Over a game the corner stack
        -- holds the left edge, and on a phone held sideways a centred block
        -- lands right on it: the rail's marks and the words GUN and BOMB in
        -- the same column read as one broken thing. The stack stays, because
        -- what you are carrying is worth knowing while you pick a hull.
        if not home then
            x0 = math.max(x0, 124 * S)
            -- And give back what moving right took: the block is as wide as
            -- the room left of the far margin, or it hangs off the edge of
            -- the screen carrying the end of the keyboard with it.
            total = math.min(total, W - x0 - margin)
        end
        rw = (labelled and 150 or 62) * S
        local pitch = math.min(math.max((H - head - 3 * margin) / n,
                                        38 * S), 58 * S)
        rh = pitch * n
        local block = math.max(rh, math.min(H - head - 2 * margin, 470 * S))
        local top = math.max(margin, (H - block - head) / 2) + head
        rx, ry_ = x0, top + (block - rh) / 2
        sx = x0 + rw + 26 * S
        sy, sh = top, block
        sw = total - rw - 26 * S
        if home then
            wordmark(x0, top - head + 30 * S, (labelled and 40 or 30) * S,
                     math.min(sw, 420 * S))
        end
        -- What you are reading, laid over what you are not. A wash rather
        -- than a panel: no border, no corners, just enough that the type sits
        -- on something and the arena stays visible round the edges of it.
        rect(x0 - 18 * S, top - 16 * S, total + 36 * S, block + 30 * S,
             pal.rgb(0x03050a, 0.5))
        -- The rule the whole thing hangs off, between the rail and the stage.
        vrule(x0 + rw + 1 * S, top, block, pal.a(pal.RADAR_TILE, 0.75), 30 * S)
    else
        rh = (home and 78 or 84) * S
        rw = W - 2 * margin
        rx = margin
        ry_ = H - margin - rh
        sx, sw = margin, W - 2 * margin
        -- Under the chip row over a game: MENU and INFO hold the top left
        -- corner while the arena is live, and a title drawn into them is two
        -- words in one place.
        sy = margin + head + (home and 0 or 34 * S)
        sh = ry_ - 20 * S - sy
        rect(0, sy - 16 * S, W, sh + rh + 46 * S, pal.rgb(0x03050a, 0.5))
        if home then
            wordmark(margin, margin + 26 * S, 30 * S, math.min(sw, 300 * S))
        end
        u:seg(margin, ry(ry_ - 12 * S), W - margin, ry(ry_ - 12 * S),
              1.0 * S, pal.a(pal.RADAR_TILE, 0.6), true)
    end

    -- --- the rail
    local pitch = vertical and (rh / n) or (rw / n)
    for i, e in ipairs(rail) do
        local sel = (i == v.rail_sel)
        local cx, cy
        if vertical then
            cx = labelled and (rx + 26 * S) or (rx + rw / 2)
            cy = ry_ + (i - 0.5) * pitch
        else
            cx = rx + (i - 0.5) * pitch
            cy = ry_ + (home and 30 or 32) * S
        end
        local col = sel and pal.FRIEND or pal.a(pal.DIM, 0.9)
        local r = (vertical and (labelled and 13 or 14) or 13) * S
        if sel then
            -- The lit one, and a rule reaching from it toward the stage, so
            -- the eye is told which mark the panel belongs to rather than
            -- having to work it out from a highlight.
            if vertical then
                rect(rx - 6 * S, cy - pitch / 2 + 3 * S,
                     rw + 6 * S, pitch - 6 * S, pal.a(pal.FRIEND, 0.08))
                u:seg(rx - 6 * S, ry(cy - pitch / 2 + 3 * S), rx - 6 * S,
                      ry(cy + pitch / 2 - 3 * S), 1.6 * S, pal.FRIEND, true)
            else
                rect(cx - pitch / 2 + 3 * S, ry_, pitch - 6 * S, rh - 4 * S,
                     pal.a(pal.FRIEND, 0.08))
                u:seg(cx - pitch / 2 + 3 * S, ry(ry_), cx + pitch / 2 - 3 * S,
                      ry(ry_), 1.6 * S, pal.FRIEND, true)
            end
        end
        draw_mark(e.icon, cx, cy, r, col, v.class or 0)
        if vertical and labelled then
            txt(e.label, rx + 48 * S, cy, 16 * S,
                pal.a(sel and pal.INK or pal.DIM, sel and 1 or 0.85),
                nil, MENU_FONT)
        elseif not vertical and (sel or n <= 6) then
            -- Every stop is labelled while there is room for it. With eight
            -- of them on a phone there is not: "settings" and "about" run
            -- into each other, so only the one you are on says its name and
            -- the rest are marks, which is what they were drawn to be.
            txt(e.label, cx, cy + 24 * S, 11 * S,
                pal.a(sel and pal.FRIEND or pal.DIM, sel and 1 or 0.8),
                "center", MENU_FONT)
        end
        -- The rail's own action: it names a destination, not a row of
        -- whatever page is on the stage.
        if vertical then
            hit(rx - 6 * S, cy - pitch / 2, rw + 10 * S, pitch, "rail", i)
        else
            hit(cx - pitch / 2, ry_ - 8 * S, pitch, rh + 8 * S, "rail", i)
        end
    end

    -- --- the stage
    local focused = (v.focus == "stage")
    local title = v.stage_title or v.title or ""
    local listy = not (v.board and not M.touching)
        and not (v.rows and #v.rows > 0 and v.rows[1].hull)
    local lw = listy and math.min(sw, 520 * S) or sw
    txt(title, sx, sy + 14 * S, (M.compact and 19 or 22) * S,
        pal.a(pal.FRIEND, focused and 1 or 0.75), nil, MENU_FONT)
    if v.closable then
        txt(focused and "back" or "close", sx + lw, sy + 14 * S, 12 * S,
            pal.a(pal.DIM, 0.85), "right", MENU_FONT)
        hit(sx + lw - 70 * S, sy, 70 * S, 30 * S, "row", -1)
    end
    local top = sy + 40 * S
    local room = sh - (top - sy) - 26 * S
    -- A list is capped: a row whose name sits at one edge and whose count
    -- sits at the other, a screen apart, is two columns nobody reads as one
    -- line. The board and the hull grid are drawings and take everything.
    -- The rule introduces whatever is under it, so it is as wide as that.
    ticks(sx, sy + 28 * S, lw, pal.a(pal.RADAR_TILE, 0.45), 12 * S)
    if v.board and not M.touching then
        -- The widest board the stage has the height for, backed off rather
        -- than solved, the same way the page used to do it.
        local bw = sw
        while bw > 240 * S and board_height(bw) > room do bw = bw * 0.94 end
        board(sx, top, bw)
    elseif v.rows and #v.rows > 0 and v.rows[1].hull then
        ship_grid(sx, top, sw, room, v, focused)
    else
        local rowh = math.min((M.compact and 46 or 40) * S,
                              math.max(30 * S, room / math.max(#v.rows, 1)))
        -- A short list sits in the middle of the room rather than at the top
        -- of it: three games hung under a title on a tall phone leave the
        -- screen looking half loaded. A list long enough to fill the space
        -- starts where it always did, so nothing shifts as one grows.
        local used = rowh * #v.rows
        -- Only where the stage is tall and thin. On a phone three games hung
        -- under a title leave the screen looking half loaded; on a desktop
        -- the same centring floats the list away from the title it belongs
        -- to, which reads as two panels rather than one.
        local ty = top
        if narrow and used < room * 0.6 then ty = top + (room - used) / 2 end
        -- A list longer than the room it has scrolls, and the cursor drags it
        -- rather than walking off the bottom edge. Rows past the end used to
        -- be skipped, which is a list that quietly stops being the list: a
        -- fleet with a dozen games would have shown seven of them and said
        -- nothing about the rest.
        local fits = math.max(1, math.floor(room / rowh))
        local first = 1
        if #v.rows > fits then
            ty = top
            local cur = (v.sel and v.sel > 0) and v.sel or 1
            first = math.min(math.max(1, cur - math.floor(fits / 2)),
                             #v.rows - fits + 1)
        end
        for i = first, math.min(#v.rows, first + fits - 1) do
            local r = v.rows[i]
            local y = ty + (i - first) * rowh
            stage_row(sx, y, lw, rowh, r, i == v.sel, focused)
            if r.pick then hit(sx, y, lw, rowh, "stage", i) end
        end
        -- What is off the ends, as the same tick the map border uses. It says
        -- there is more without spending a row on saying so.
        if #v.rows > fits then
            local bar = 3 * S
            local hgt = room * fits / #v.rows
            local at = room * (first - 1) / #v.rows
            rect(sx + lw + 8 * S, ty, bar, room, pal.a(pal.DIM, 0.18))
            rect(sx + lw + 8 * S, ty + at, bar, hgt, pal.a(pal.FRIEND, 0.6))
        end
        if #v.rows == 0 then
            txt(v.note or "", sx + 16 * S, top + 20 * S, 13 * S,
                pal.a(pal.DIM, 0.9))
        end
    end

    -- One line at the foot of the stage: why something did not work, or what
    -- the thing under the cursor is, or how to work the menu. In that order,
    -- because that is the order they matter in.
    local by = sy + sh - 4 * S
    local foot = v.note or v.hint
    if foot then
        txt(foot, sx, by, 12 * S,
            pal.a(v.note and pal.HURT or pal.DIM, 0.95))
    elseif not narrow then
        txt("up down  ·  enter  ·  esc", sx, by, 11 * S, pal.a(pal.DIM, 0.6))
    end
end

-- --- cursor ----------------------------------------------------------------

-- The pointer. The page hides the browser's cursor over the canvas, so this
-- arrow is the only one anybody sees: the usual shape, restated in the
-- interface's language, with the heel corner cut at the same diagonal the
-- walls and the brackets use. Dark in the body and lit at the edge, the way
-- a hull is, so it reads over a starfield and over a panel alike. The tip is
-- the hotspot, exactly where the browser says the pointer is.
function M.cursor(x, y, alpha)
    local k = 16 * S
    local cut = 0.22 * k
    -- Down the left edge, across the chamfer, and back up the hypotenuse.
    local pts = {
        x, ry(y),
        x, ry(y + k - cut),
        x + 0.93 * cut, ry(y + k - 0.38 * cut),
        x + 0.71 * k, ry(y + 0.71 * k),
    }
    u:fan(pts, pal.a(pal.BG, 0.85 * alpha))
    u:outline(pts, 1.25 * S, pal.a(pal.INK, alpha), true)
end

return M
