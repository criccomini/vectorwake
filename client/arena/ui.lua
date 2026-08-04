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
    return math.floor(W - pad - side), math.floor(pad + 18 * S),
           math.floor(side)
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
                    txt(mod.name .. (nn > 1 and ("x" .. nn) or ""), at,
                        y + rows_h / 2, (FONT - 2) * S,
                        muted and pal.a(pal.DIM, 0.45) or pal.a(pal.FRIEND, 0.75))
                    at = at + 46 * S
                end
            end
            y = y + rows_h
        end
    end

    if show_charges then
        for _, c in ipairs(slots) do
            txt(string.upper(c.name or c.short), x, y + rows_h / 2, lab,
                pal.a(pal.DIM, 0.8))
            pips(val + 3 * S, y + rows_h / 2, math.max(1, c.max or 3), c.count,
                 c.ready and pal.CHARGE_COL or pal.a(pal.CHARGE_COL, 0.7),
                 2.7 * S, 9 * S)
            y = y + rows_h
        end
    end

    -- What you are worth, which is the number that decides who comes for you,
    -- and which was only ever behind the info toggle.
    txt("BOUNTY", x, y + rows_h / 2, lab, pal.a(pal.DIM, 0.8))
    local bty = sim.ship_bounty(me)
    txt(tostring(bty), val, y + rows_h / 2, (FONT - 2) * S,
        bty > 0 and pal.a(pal.PRIZE, 0.95) or pal.a(pal.DIM, 0.5))
    y = y + rows_h

    if pickup then
        txt((pickup.sign or "+") .. " " .. pickup.name, x,
            y + rows_h / 2, FONT * S, pal.a(pickup.col, pickup.t))
    end
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
    local same_team = sim.ship_team(i) == sim.ship_team(o.me)
    -- Whether the team is worth saying, asked of the room rather than of the
    -- zone file, which the client is not sent. A free-for-all gives every seat
    -- its own number, so there are as many teams as pilots and "TEAM 41" is
    -- noise; sides mean something exactly when there are fewer of them than
    -- there are ships to put in them.
    local n = sim.ship_count()
    local seen, teams = {}, 0
    for k = 0, n - 1 do
        local t = sim.ship_team(k)
        if not seen[t] then seen[t] = true teams = teams + 1 end
    end
    local show_team = teams > 1 and teams < n
    local rows_n = 3 + (show_team and 1 or 0)
    local h = 30 * S + rows_n * rowh + 10 * S
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
        bot_mark(x + 12 * S + #nm * (FONT - 1) * S * 0.62, y + 15 * S,
                 pal.a(pal.DIM, 0.85), 10 * S)
    end
    -- Close, in the corner it opened under. Escape does the same thing.
    txt("X", x + w - 12 * S, y + 17 * S, (FONT - 2) * S, pal.a(pal.DIM, 0.8),
        "right")
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
    if show_team then
        row("TEAM", tostring(sim.ship_team(i)), pal.a(col, 0.9))
    end
    -- What the zone is willing to say this seat is, which is the honest
    -- version of the question: the client cannot tell, and the server's label
    -- is the only answer anybody has. A guest is not an accusation.
    row("SEAT", string.upper((p and p.label) or "unknown"))
    row("RECORD", sim.ship_kills(i) .. "K  " .. sim.ship_deaths(i) .. "D  "
        .. sim.ship_points(i) .. "P")
    -- What killing them pays, which is the number that decides whether the
    -- rest of this matters right now.
    row("BOUNTY", tostring(sim.ship_bounty(i)), pal.a(pal.BOUNTY, 0.9))
    return y + h
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
    local w = 176 * S
    local x = W - PAD * S - w
    local rowh = 13 * S
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
    local h = 20 * S + #lines * rowh + 6 * S
    local y = (top or 0) + 6 * S
    rect(x, y, w, h, pal.a(pal.BG, 0.78))
    vrule(x, y, h, pal.a(pal.PRIZE, 0.8))
    txt("DEBUG", x + 10 * S, y + 13 * S, (FONT - 4) * S, pal.a(pal.PRIZE, 0.9))
    txt(o.zone or "", x + w - 10 * S, y + 13 * S, (FONT - 4) * S,
        pal.a(pal.DIM, 0.8), "right")
    local ly = y + 20 * S
    for _, l in ipairs(lines) do
        txt(l[1], x + 10 * S, ly + rowh / 2, (FONT - 4) * S,
            pal.a(pal.DIM, 0.8))
        txt(l[2], x + w - 10 * S, ly + rowh / 2, (FONT - 4) * S,
            pal.a(pal.INK, 0.9), "right")
        ly = ly + rowh
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

function M.hud(o)
    if sim.ship_count() == 0 then return end
    local me = o.me
    menu_up = o.menu_open

    -- On a touchscreen the bottom of the screen belongs to the thumbs. The
    -- stick sits in the bottom left corner and the pads in the bottom right,
    -- which is exactly where the status panel and the control hint were, so
    -- everything else moves up out of the way of them.
    local lift = M.touching and 150 * S or 0

    local top = scores(me, o.pilots)
    nameplates(o)
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
-- the name only confirms it. The canopy comes along because at this size it is
-- the only thing that says which end is the front.
local function thumb(cx, cy, cls, col, scale)
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
local ROW_H = 34
local MENU_W = 460

function M.menu(v)
    local w = math.min(MENU_W * S, W - 24 * S)
    local x = math.max(24 * S, (W - w) / 2 - 120 * S)
    local nrows = #v.rows
    -- The home screen carries the name at a size that owns its corner, and
    -- everything under it moves down by the room that takes. Only while the
    -- room exists: a phone held sideways has about 350 points of height, the
    -- column with the big header is 374, and a wordmark that pushes "tap a
    -- row" off the bottom of the screen is decoration eating the controls.
    -- The header yields and the title falls back to the size every other
    -- screen uses.
    local head = 0
    if v.home_root then
        local need = ROW_H * nrows + 76 + 60 + 24
        if H / S >= need then head = 60 * S end
    end
    local h = ROW_H * S * nrows + 76 * S + head
    local y = math.max(20 * S, (H - h) / 2)

    -- Not a curtain: dimmed enough to read against, clear enough to see the
    -- arena still running behind it. Opening the menu does not pause anything
    -- and should not look as though it does.
    rect(0, 0, W, H, pal.rgb(0x03050a, 0.58))

    -- No panel. A modal box with a border is the one shape this game does not
    -- otherwise contain, and it made the menu look like a settings dialog
    -- borrowed from another application. What holds the column together is
    -- the same thing that holds a wall together: a lit rule with the light
    -- falling off it. The column sits left of centre so the arena keeps the
    -- middle of the screen.
    vrule(x, y, h, pal.a(pal.RADAR_TILE, 0.8), 40 * S)

    if head > 0 then
        -- The name, and under it the thing the name is about.
        --
        -- Not a logotype: the same monospace as everything else, at a size
        -- nothing else on the screen is. What makes it a mark is the stroke
        -- beneath, which starts at nothing on the left, swells under the word
        -- and is gone again by the end of it, which is a wake.
        local size = (M.compact and 30 or 46) * S
        txt(v.title, x + 20 * S, y + 40 * S, size, pal.INK)
        local ww = math.min(#v.title * size * 0.62, w - 40 * S)
        local wy = y + 72 * S
        local n = 40
        for i = 0, n - 1 do
            local t0, t1 = i / n, (i + 1) / n
            local function swell(t)
                return math.sin(t * math.pi) ^ 1.6
            end
            local a0, a1 = swell(t0), swell(t1)
            u:seg_fade(x + 20 * S + ww * t0, ry(wy),
                       x + 20 * S + ww * t1, ry(wy),
                       (0.7 + 2.6 * a0) * S, (0.7 + 2.6 * a1) * S,
                       0.85 * a0, 0.85 * a1, pal.FRIEND)
        end
    else
        txt(v.title, x + 20 * S, y + 26 * S, (M.compact and 19 or 23) * S,
            pal.FRIEND)
    end
    -- A phone has no escape key, so the way out is drawn. At the root of the
    -- home screen there is no way out to draw: nothing is behind the column,
    -- and a `close` that leaves a player on an empty starfield would be a
    -- button that breaks the game.
    if v.closable then
        txt(v.depth > 1 and "back" or "close", x + w - 20 * S, y + 26 * S,
            11 * S, pal.a(pal.DIM, 0.8), "right")
        hit(x + w - 90 * S, y + 8 * S, 90 * S, 34 * S, "row", -1)
    end
    ticks(x + 20 * S, y + 40 * S + head, w - 20 * S,
          pal.a(pal.RADAR_TILE, 0.4), 12 * S)

    local ry0 = y + 48 * S + head
    for i, r in ipairs(v.rows) do
        local top = ry0 + (i - 1) * ROW_H * S
        local on = i == v.sel
        if on and r.pick then
            -- A wash off the rule, and the rule lit where the row meets it.
            wash(x, top, w, ROW_H * S, pal.a(pal.FRIEND, 0.14))
            u:seg(x, ry(top), x, ry(top + ROW_H * S), 2.2 * S, pal.FRIEND)
            u:seg(x + 8 * S, ry(top + ROW_H * S / 2),
                  x + 13 * S, ry(top + ROW_H * S / 2), 1.4 * S, pal.FRIEND)
        end
        local ink = r.pick and (on and pal.INK or pal.a(pal.INK, 0.7))
            or pal.a(pal.DIM, 0.9)
        local lx = x + 20 * S
        if r.hull then
            -- The silhouette is what picks a ship. Eight names mean nothing
            -- to somebody who has not flown them; eight shapes are the game
            -- telling you what it has.
            thumb(x + 36 * S, top + ROW_H * S / 2, r.hull,
                  on and pal.INK or pal.a(pal.INK, 0.55), 0.62 * S)
            lx = x + 62 * S
        end
        if r.label ~= "" then
            txt(r.label, lx, top + ROW_H * S / 2, FONT * S, ink)
        end
        if r.detail and r.detail ~= "" then
            -- The value sits on the right of the row it belongs to, which is
            -- how a settings list reads everywhere else in the world.
            txt(r.detail, x + w - 20 * S, top + ROW_H * S / 2, FONT * S,
                r.mark and pal.FRIEND or pal.a(pal.DIM, 0.95), "right")
        end
        if r.pick then hit(x, top, w, ROW_H * S, "row", i) end
    end

    -- One line under the list, and three things want it. A note is why
    -- something did not work and outranks everything. A hint is the sentence
    -- about whatever is under the cursor, which is how a game in the list says
    -- what it is without a second column no phone has room for. The controls
    -- are what is left when there is nothing more useful to say.
    local by = y + h - 16 * S
    ticks(x + 20 * S, by - 16 * S, w - 20 * S, pal.a(pal.RADAR_TILE, 0.25),
          12 * S)
    if v.note then
        txt(v.note, x + 20 * S, by, FONT * S, pal.ENEMY)
    elseif v.hint then
        txt(v.hint, x + 20 * S, by, (FONT - 1) * S, pal.a(pal.DIM, 0.95))
    else
        txt((M.touching or M.compact) and "tap a row"
            or "up down to move    enter to choose    esc to go back",
            x + 20 * S, by, (FONT - 2) * S, pal.a(pal.DIM, 0.7))
    end
end

return M
