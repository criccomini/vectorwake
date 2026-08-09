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
local marks = require("arena.marks")
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
-- How many hulls the ship page last drew across, for whoever moves a cursor
-- around it. Set by the drawing, because how many fit is a fact about the
-- window and nothing outside this file knows the window.
M.stage_cols = 4
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

-- How heavy to draw a mark of this size.
--
-- Against the mark rather than against the window, which is the difference
-- between a drawing that can be resized and one that cannot. The corner stack
-- used to put every width in multiples of S, so drawing the whole block larger
-- would have grown the shapes and left the lines where they were: a set of
-- hairlines at twice the size, which is not the same drawing bigger. The floor
-- is for the small end, where a stroke under a pixel disappears.
-- Strokes off the mark's own size. Shared with the pads, which draw the same
-- marks and have to weight them the same way.
local pen = marks.pen

-- `font` names one of the faces the gui scene carries: nil for the mono
-- everything in flight is set in, "menu" for the menu's own. It is passed
-- through rather than looked up, so a caller that says nothing gets what the
-- rest of the interface uses.
-- Everything drawn while this is set draws that much of its alpha. It is
-- how the interface stands down under the menu: glyphs come from the gui,
-- which draws over every mesh, so no wash the menu lays down can touch them
-- and the only way to quiet a label is to quiet the label.
local text_dim = 1

-- Which voice the interface is speaking in. The HUD is read at a glance, over
-- a fight, out of the corner of an eye, and capitals are the case an
-- instrument is labelled in. The menu is read rather than glanced at, and a
-- page of capitals is a page nobody reads twice, so it takes a sentence's
-- case: one capital at the front and nothing else shouting.
--
-- Set by whichever of the two is drawing. Done here rather than in the
-- strings themselves, because case is how a thing is set rather than what it
-- says, and the model has no business shouting.
local case = "upper"
local function cased(s)
    if case == "upper" then return string.upper(s) end
    return (string.gsub(s, "^%l", string.upper))
end

-- `raw` is for the handful of strings the interface is quoting rather than
-- saying: somebody's name, a key they have to type on another machine, the
-- address an operator has to read back, the commit a build was made from, and
-- the wordmark, which is a drawing of a name rather than a label.
local function txt(s, x, y, px, col, pivot, font, raw)
    if not raw then s = cased(s) end
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

-- Who is in a seat, in two marks that answer one question.
--
-- A person wears a round helmet with a curved visor across it. A machine
-- wears a squared one with two lamps in it and an antenna over the top.
-- Drawn rather than spelled, because "AI" beside a name is two letters that
-- read as part of the name until you have learned they are not, and these
-- lists are scanned rather than read.
--
-- The two shells differ on purpose. They were one shell for a while, on the
-- reasoning that the games list sets a count of people beside a count of
-- machines and the pair should read as one question. It does read as one
-- question, but the round-against-square difference is what answers it at a
-- glance: curved is grown, boxed is built, and that is legible at a size
-- where a lamp is two pixels and an antenna is three. What holds the pair
-- together is the collar, the height, and the baseline, all of which they
-- still share.
--
-- Everywhere but that row each mark is alone, so each has to say what it is
-- with nothing to compare against. The box does that for the machine, and
-- the antenna over it says it twice.
--
-- `k` is the width of the shell. `y` is the middle of the line it sits on, so
-- a caller can hand it a row's centre without knowing the height.
--
-- HELM_NECK is how far below the centre the collar cuts, in radii. Both
-- shells are cut off there and sit on the same run of line, so the mark's
-- height is what it actually draws rather than a box of air around it.
local HELM_NECK, HELM_COLLAR = 0.68, 1.26
local HELM_TALL = 0.5 * (1 + HELM_NECK)

-- The collar, under either shell. `half` is the shell's own half width where
-- the cut lands; the line runs a little past it so the helmet sits in
-- something rather than ending in mid air.
local function collar(cx, neck, half, line, col)
    u:seg(cx - half * HELM_COLLAR, ry(neck), cx + half * HELM_COLLAR, ry(neck),
          line, col, true)
end

-- A person's shell: a bowl of glass, one turn of a circle cut off at the
-- neckline. The chamfer the rest of this interface is built from went here
-- first and made a box with a face in it, and straight sides after that made
-- a bucket. A helmet is the one object in this game that is not machined, and
-- it reads as one once its edges stop being edges.
local function helm(cx, cy, k, col)
    local w = k
    local h = w * HELM_TALL
    local x0, y0 = cx - w / 2, cy - h / 2
    local r = w * 0.5
    local mid = y0 + r                 -- the centre of the bowl
    local neck = mid + r * HELM_NECK   -- where the collar cuts it off
    local half = math.sqrt(math.max(0, r * r - (neck - mid) ^ 2))
    local line = pen(k, 0.11)
    local segs = math.max(8, math.floor(k * 0.8))
    -- The angle the cut meets the circle at, measured off the horizontal.
    local a = math.asin((neck - mid) / r)
    u:arc(cx, ry(mid), r, -a, math.pi + a, line, segs, col)
    collar(cx, neck, half, line, col)
    return x0, y0, w, h, mid, r
end

-- A machine's shell: the same envelope with the curve taken out of it.
--
-- Squared to the same width and the same neckline as the bowl, so the two sit
-- level in a row. Its crown is flat where the person's is domed, which is the
-- whole of the difference and all it needs to be.
--
-- Three sides and a collar rather than a closed outline. Closing it lays the
-- box's own base under the collar, and two lines of one colour on one pixel
-- row is a brighter line wherever these marks draw at part alpha, which is
-- every nameplate in the arena.
--
-- The same reasoning decides the corners. A capped stroke runs half a width
-- past each end, so four capped sides overlap in four squares and light every
-- corner. The crown is capped and covers them; the sides butt into it and
-- into the collar, each drawing its own length and no more.
local function hull_helm(cx, cy, k, col)
    local w = k
    local h = w * HELM_TALL
    local x0, y0 = cx - w / 2, cy - h / 2
    local r = w * 0.5
    local mid = y0 + r
    local neck = mid + r * HELM_NECK
    local line = pen(k, 0.11)
    u:seg(x0, ry(y0), x0 + w, ry(y0), line, col, true)
    u:seg(x0, ry(y0 + line / 2), x0, ry(neck - line / 2), line, col)
    u:seg(x0 + w, ry(y0 + line / 2), x0 + w, ry(neck - line / 2), line, col)
    collar(cx, neck, w / 2, line, col)
    return x0, y0, w, h, mid, r
end

-- A bowl on a collar with a visor in it has more parts than the box it
-- replaced, and parts are what die first when a mark is drawn small. Eleven
-- points rather than nine: still a mark beside a number rather than a picture
-- in a row, and enough for the glass, the collar and the band to survive.
local MARK_K = 11

-- How far off the bowl's centre the visor's two edges are struck from, in
-- radii, and where each sits when it crosses the middle. The two pivots are
-- that distance either side of the centre, which is what makes the band swell
-- rather than bend: bigger is flatter, and at a few radii the arcs are gentle
-- enough to read as a swelling instead of as a lens.
local VISOR_PIVOT = 2.8
local VISOR_TOP, VISOR_BOT = 0.34, 0.10

-- A person: the visor, one curved band across the glass.
--
-- It was a pair of shades with a wedge of nose between them, and the nose was
-- the part doing the work: two lenses without it close into a band with a
-- nick, and with it they read as a face rather than as a helmet. A visor is
-- the simpler object and the one a space helmet actually has, so the band is
-- unbroken and the face behind it is left alone.
--
-- Swelled rather than ruled or bent. Two earlier cuts curved both edges the
-- same way, which slides the whole band up or down without changing its
-- shape: struck like the dome it was a brow, and struck against the dome it
-- was a frown, and either way it read as a line that had been pushed around
-- rather than as an object.
--
-- This bows the edges apart instead. The top rises over the middle and the
-- bottom drops under it, so the band is deepest where it crosses the face and
-- narrows towards each end, which is what a curved pane does when you look at
-- it head on. The ends stop short of the glass rather than touching, which is
-- what keeps it a visor in a helmet instead of a helmet in two pieces.
--
-- Drawn as a strip of quads, walking the two edges together. A fan would
-- serve, the swelled band being convex where the bent one was not, but the
-- strip does not care either way and this shape has now changed three times.
local function pilot_mark(cx, cy, col, k)
    k = k or MARK_K * S
    local w, h, mid, r = select(3, helm(cx, cy, k, col))
    local _ = h
    -- The glass, less the line it is drawn with and the gap held off it.
    local rin = r - (pen(k, 0.11) + w * 0.045)
    -- One pivot under the helmet and one over it, each carrying the edge
    -- furthest from it. The top's arc therefore stands on its pivot and the
    -- bottom's hangs from its own, and the two part company away from the
    -- middle.
    local under, over = mid + r * VISOR_PIVOT, mid - r * VISOR_PIVOT
    local top = under - (mid - r * VISOR_TOP)
    local bot = (mid + r * VISOR_BOT) - over
    local function upper(x)
        return under - math.sqrt(math.max(0, top * top - x * x))
    end
    local function lower(x)
        return over + math.sqrt(math.max(0, bot * bot - x * x))
    end
    -- How far out the band runs before it would leave the glass. Solved by
    -- halving rather than in closed form: the answer is a couple of pixels
    -- and the arithmetic for it is a page.
    local lo, hi = 0, rin
    for _ = 1, 24 do
        local m = (lo + hi) / 2
        local ty, by = upper(m) - mid, lower(m) - mid
        if m * m + math.max(ty * ty, by * by) <= rin * rin then
            lo = m
        else
            hi = m
        end
    end
    local reach = lo
    local n = math.max(4, math.floor(k / 2))
    local px, pty, pby
    for i = 0, n do
        local x = -reach + 2 * reach * i / n
        local ty, by = upper(x), lower(x)
        if px then
            u:quad(cx + px, ry(pty), cx + x, ry(ty),
                   cx + x, ry(by), cx + px, ry(pby), col)
        end
        px, pty, pby = x, ty, by
    end
    return w
end

-- A machine: the boxed shell, two lamps, and the antenna over the crown.
--
-- `x` is its left edge rather than its centre, because every caller of this
-- one is laying a row out left to right and knows where the mark starts.
--
-- Lamps rather than a visor, and a flat crown to stand them under. The
-- antenna says the same thing a second time, which is worth the two points it
-- costs: three of this mark's four uses are solo.
local function bot_mark(x, y, col, k)
    k = k or MARK_K * S
    local cx = x + k / 2
    local x0, y0, w, _, mid, r = hull_helm(cx, y, k, col)
    -- The middle of the box rather than the middle of the circle it used to
    -- be: a flat crown puts the room the dome was using back into the shell,
    -- and lamps left where they were sat in the bottom third of it.
    local eye = mid - r * 0.16
    u:disc(x0 + w * 0.31, ry(eye), w * 0.115, 8, col)
    u:disc(x0 + w * 0.69, ry(eye), w * 0.115, 8, col)
    u:seg(cx, ry(y0), cx, ry(y0 - r * 0.36), pen(k, 0.09), col, true)
    u:disc(cx, ry(y0 - r * 0.48), w * 0.11, 8, col)
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


local KEY_H, KEY_PAD, KEY_GAP = 26, 9, 6
local function key_size() return (FONT - 1) * S end
local function key_w(label) return text_w(label, key_size()) + 2 * KEY_PAD * S end
local function key_cap(x, y, w, label, on)
    local col = on and pal.FRIEND or pal.DIM
    local h = KEY_H * S
    rect(x, y, w, h, pal.a(col, on and 0.16 or 0.07))
    u:frame(x, ry(y, h), w, h, 1.1 * S, pal.a(col, on and 0.95 or 0.55))
    -- A key is shouted wherever it turns up, menu or corner: it is a thing to
    -- press rather than something the interface is saying, and the two of them
    -- are the same object.
    txt(string.upper(label), x + w / 2, y + h / 2, key_size(),
        pal.a(col, on and 1 or 0.85), "center", nil, true)
end

-- Broken into lines no wider than `measure`, at whitespace. Used by the card a
-- dead pilot reads and by the label the pointer raises, which say the same
-- sentences and would otherwise break them in two different places.
--
-- Remembered, because the answer only changes when the sentence or the room
-- does, and the label asks the same question of the same sentence every
-- frame a pointer rests on an instrument. Building it each time is a hundred
-- string joins a frame to redraw words that have not moved, which is exactly
-- the sort of thing that shows up as a cursor that does not keep up.
local wrap_cache = {}
local function wrap(s, px, measure)
    local id = s .. "\1" .. px .. "\1" .. measure
    local hit_ = wrap_cache[id]
    if hit_ then return hit_ end
    local out, line = {}, nil
    for word in string.gmatch(s, "%S+") do
        local try = line and (line .. " " .. word) or word
        if line and text_w(try, px) > measure then
            out[#out + 1] = line
            line = word
        else
            line = try
        end
    end
    if line then out[#out + 1] = line end
    wrap_cache[id] = out
    return out
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

-- Where each instrument landed this frame.
--
-- The help label sets a word beside a thing instead of drawing a line to it,
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

-- The screen's unsafe margins, in drawable pixels: what an iPhone's island,
-- notch, and rounded corners cover at the left, right, and top edges. The
-- page runs edge to edge under them on purpose (viewport-fit=cover in the
-- template), so the world draws everywhere and only the furniture anchored
-- to an edge steps inside. Set by the caller from what the page measures;
-- zero everywhere hardware covers nothing, which is every desktop and most
-- of the phones. There is deliberately no bottom inset: the home indicator
-- overlays the pads the way it overlays every full-screen game's controls,
-- and lifting them a further 21 points bought nothing but reach.
local SL, SR, ST = 0, 0, 0
function M.safe(l, r, t)
    SL, SR, ST = l or 0, r or 0, t or 0
end

-- `now` is the frame's clock in seconds, for the few things on screen that
-- move on their own. Nothing that is laid out depends on it, so a caller with
-- no clock draws the same interface at rest.
function M.begin(layer, w, h, density, touching, now)
    u, W, H = layer, w, h
    M.now = now or 0
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
    -- Every wrapped sentence was broken against the old width, so the memo
    -- goes with the size that produced it. Only on a real change: clearing it
    -- every frame would be the same as not having one.
    if S ~= density then wrap_cache = {} end
    S = density
    -- The marks draw into the same layer, and the pads reach for them after
    -- this returns, so they are handed it here rather than by each caller.
    marks.begin(layer, density)
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
-- How far the MENU and PLAYERS keys reach across the top left, filed by the
-- thing that draws them rather than written down twice. It is a word's width,
-- and PLAYERS grew the row the day it stopped being INFO.
local chip_right = 0

-- The map is about a quarter of the frame, capped three ways: against the
-- window's width so it cannot run off the left edge, against its height so
-- there is still room for the feed under it, and against the corner the MENU
-- and PLAYERS keys stand in, since a hit box over those is two controls a
-- pointer can no longer reach.
local function dial()
    local pad = (M.compact and 8 or PAD) * S
    local side = RADAR * S
    if M.map then
        side = math.max(side,
                        math.min(math.min(W, H) * 0.66, H * 0.66,
                                 W - SR - pad - math.max(chip_right + 8 * S,
                                                         124 * S)))
    end
    -- Whole pixels. The dial snaps its contents to its own origin, so an
    -- origin landing on a half pixel would put the fraction back into every
    -- blip it was taken out of. Density is not always a whole number and
    -- neither, then, is the padding.
    local ix, iy = math.floor(W - SR - pad - side),
                   math.floor(ST + pad + 18 * S)
    side = math.floor(side)
    -- Filed here rather than in the two functions that draw into it, because
    -- the dial and the map are the same corner and want the same word beside
    -- them.
    -- The left edge and the whole vertical run of it, because the word beside
    -- the dial wears a bar as tall as the dial: an instrument this size is not
    -- named by a mark the height of one line of type.
    anchor.radar = {ix, iy, iy + side}
    zone("radar", ix, iy, side, side)
    return ix, iy, side
end

-- How much vertical room it takes, so the feed under it can be told rather
-- than guess.
function M.radar_span()
    local _, _, side = dial()
    return ST + PAD * S * 2 + side + 18 * S
end

-- You, as an arrow. On any view of the arena the one thing worth knowing
-- besides where you are is which way you are pointing, and the radar and the
-- map draw the same mark because they are the same statement about the same
-- ship. Clamped rather than dropped when it falls outside the frame it is
-- given: a view without you on it is a view with no origin.
-- The team a perspective seat is on, guarded: the hud's `me` is the watched
-- subject while spectating and nil when the channel has nobody, and 255 is
-- the byte that belongs to no side, so an absent eye colours everybody
-- hostile the way a free-for-all already colours everyone who is not you.
local function team_of(i)
    if not i or i < 0 or i >= sim.ship_count() then return 255 end
    return sim.ship_team(i)
end

-- The side this screen belongs to, which is not always the side of the hull
-- it is centred on.
--
-- Flying they are the same and it never mattered. Watching they come apart:
-- the camera stands behind whoever the channel picked, and deriving "my team"
-- from that repainted your own side as hostile every time the camera crossed
-- the line, and told the info box that a teammate of the pilot you happen to
-- be watching is a teammate of yours. Set once per frame from what the zone
-- told this client its side is.
local view_team = 255

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

    local my_team = view_team
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
    -- the arrow simply went missing. A watcher with no subject has no arrow
    -- to place: a view can have no origin after all, when it is nobody's.
    if me then
        own_arrow(ix + (sim.ship_x(me) - cx + SPAN) * k,
                  iy + (sim.ship_y(me) - cy + SPAN) * k, ix, iy, r, me)
    end
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
    if ov.grid > 0 and me then
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
    local my_team = view_team
    -- The one hull that goes unlabelled is your own, and a watcher has none.
    -- The pilot being observed therefore wears their name and their bounty
    -- exactly like everybody else on screen: "who am I looking at" is the
    -- question a spectator has most of, and the answer belongs on the hull
    -- rather than in a caption at the foot of the screen. Written as a
    -- separate value because `o.me` is the perspective seat while watching,
    -- which is precisely the hull that must keep its label.
    local own = -1
    if not o.watch then own = o.me end
    for i = 0, sim.ship_count() - 1 do
        if i ~= own and sim.ship_alive(i) == 1 then
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
                    -- A call sign is a name somebody was given, not a
                    -- word this interface is saying, so it keeps its own
                    -- case wherever it is drawn.
                    txt(nm, sx + 12 * S, sy + 13 * S, 11 * S, pal.a(col, 0.7),
                        nil, nil, true)
                    -- The same mark the scoreboard and the info box wear, on
                    -- the hull itself: who is flying a ship is worth knowing
                    -- while you are deciding whether to chase it, and that
                    -- decision is made looking at the ship rather than at a
                    -- panel. Dim and after the name, so it reads as a note
                    -- about the label and never competes with the bounty
                    -- under it.
                    if p and p.ai then
                        -- A mark set four points off the last letter reads as
                        -- the end of the name rather than as a thing beside
                        -- it, and a call sign is exactly the kind of string
                        -- somebody will end in a bracket or a dot.
                        bot_mark(sx + 12 * S + text_w(nm, 11 * S) + 9 * S,
                                 sy + 13 * S, pal.a(col, 0.45), 10 * S)
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
-- Which column the scoreboard is ordered by. Alphabetical to begin with: the
-- question a player has of this list most often is "is that name in the
-- room", and a name is found in a list sorted by name. The score columns are
-- still a click away for whoever is asking the other question.
M.sort = "name"
M.scroll = 0
-- Rows on screen at once. The list was capped at nine with no way to see the
-- tenth, which in a room of sixty-four is most of it.
local SHOWN = 9

-- How tall one row is, in the pixels a press arrives in. Published because a
-- finger dragging the list has to be turned into rows and only this file knows
-- what a row measures. The wheel never needed it: a notch is one row by
-- definition, which is why the list could only ever be scrolled by a mouse.
function M.row_pitch()
    return LINE * S
end

-- Where the scoreboard starts: under the menu chip when there is one, since
-- the chip owns the corner.
local function top_y()
    return ST + PAD * S + 32 * S
end

-- Two names, in the order a person reads them. Lowercased for the comparison
-- so a capital cannot jump a pilot to the top of the room, and the raw name
-- breaks a tie so the order is total and the list cannot flicker between two
-- pilots who differ only in case. The games list orders itself the same way.
local function ahead(a, b)
    local la, lb = string.lower(a.name), string.lower(b.name)
    if la ~= lb then return la < lb, true end
    if a.name ~= b.name then return a.name < b.name, true end
    return false, false
end

local function scores(me, pilots, watchers)
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
        r.mine = sim.ship_team(i) == view_team
        r.watch = false
    end
    -- Then whoever is watching. They are in the room without being in the
    -- game, so they are in the list without being in the sort: no seat, no
    -- side, no score, and nothing to ask about, since the box a row opens is
    -- about a hull. Being here at all is the point. A watcher is a pair of
    -- eyes on the fight and the room deserves to know whose.
    for _, w in ipairs(watchers or {}) do
        n = n + 1
        local r = rows[n]
        if not r then r = {} rows[n] = r end
        r.i = nil
        r.k, r.d, r.p = 0, 0, 0
        r.name = w.name
        r.ai = w.label == "bot" or w.label == "bot?"
        r.label = w.label
        r.mine = false
        r.watch = true
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
    -- Alphabetical inside each side by default. Kills stay on the row: they
    -- are what a player counts in their head, and they say something points
    -- do not, since a pilot who kills loaded ships outscores one who kills
    -- more of the empty.
    local key = M.sort
    table.sort(rows, function(a, b)
        -- Watchers last, under everybody who is actually flying, whatever
        -- column is chosen. They have no score to sort by and sorting them
        -- into the middle of a scoreboard by a zero would read as a pilot
        -- doing badly rather than as somebody not playing.
        if a.watch ~= b.watch then return b.watch end
        if a.mine ~= b.mine then return a.mine end
        if key == "name" then
            local first, differ = ahead(a, b)
            if differ then return first end
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
        return (ahead(a, b))
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
    local x = SL + PAD * S
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

    local my_team = view_team
    local y = top_y() + head
    for i = 1 + M.scroll, math.min(n, M.scroll + shown) do
        local r = rows[i]
        local mine = r.i ~= nil and r.i == me
        local reading = r.i ~= nil and M.inspect == r.i
        -- A watcher is on nobody's side, so it is drawn in neither side's
        -- colour: the neutral ink, dimmer than a pilot, which is the reading.
        local col = pal.DIM
        if not r.watch then
            col = (sim.ship_team(r.i) == my_team) and pal.FRIEND or pal.ENEMY
        end
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
            pal.a(col, mine and 1.0 or 0.8), nil, nil, true)
        -- The mark goes at a fixed column rather than after the name, so a
        -- scan down the list finds them in a line instead of at fourteen
        -- different indents.
        if r.ai then bot_mark(kx - 42 * S, cy, pal.a(pal.DIM, 0.75)) end
        if r.watch then
            -- No seat, so no box to open about them, and no numbers: a
            -- watcher has not scored anything and three zeroes would say they
            -- had. One word instead, in the columns the numbers would have
            -- used, so the row is plainly a different kind of row.
            txt("watching", px, y + LINE * S / 2, (FONT - 3) * S,
                pal.a(pal.DIM, 0.7), "right")
        else
            -- The one way to ask about a pilot. Published before the panel's
            -- own box below, which takes the wheel and would otherwise
            -- swallow the press: first box in wins.
            hit(x, y, w - 6 * S, LINE * S, "pilot", r.i)
            txt(tostring(r.k), kx, y + LINE * S / 2, (FONT - 2) * S,
                pal.a(pal.INK, 0.85), "right")
            txt(tostring(r.d), dx, y + LINE * S / 2, (FONT - 2) * S,
                pal.a(pal.DIM, 0.85), "right")
            txt(tostring(r.p), px, y + LINE * S / 2, (FONT - 2) * S,
                pal.a(pal.BOUNTY, 0.9), "right")
        end
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
    local claimed, guests, bots, watching = 0, 0, 0, 0
    for i = 1, n do
        local r = rows[i]
        if r.watch then watching = watching + 1
        elseif r.label == "bot" or r.label == "bot?" then bots = bots + 1
        elseif r.label == "human" then claimed = claimed + 1
        else guests = guests + 1 end
    end
    local fy = y + foot / 2
    -- The head count is people in the game. Watchers are counted apart and
    -- only when there are any, because a zero on the end of every room's
    -- line would be a column about nothing most of the time.
    local line = string.format("%d HERE: %d SIGNED, %d GUEST, %d AI",
                               n - watching, claimed, guests, bots)
    if watching > 0 then
        line = line .. string.format(", %d WATCHING", watching)
    end
    txt(line, x + 12 * S, fy, (FONT - 4) * S, pal.a(pal.DIM, 0.8))

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

-- A feed line is words with names in it, so it is given as words with names
-- in it: plain strings are the interface talking and go to capitals, and a
-- table is a name, which is drawn as whoever owns it wrote it.
local function line_text(t)
    if type(t) == "string" then return string.upper(t) end
    local out = {}
    for _, part in ipairs(t) do
        out[#out + 1] = type(part) == "table" and part[1] or string.upper(part)
    end
    return table.concat(out)
end

local function feed(lines, top)
    local shown = math.min(#lines, M.compact and 4 or M.FEED_MAX)
    if shown == 0 then return end
    local right = W - SR - PAD * S - PANEL_X * S
    local y = top + PANEL_Y * S
    for i = 1, shown do
        local f = lines[i]
        -- Older lines sit further back, and the last second and a half of a
        -- line's life is spent leaving.
        local a = 1 - (i - 1) * 0.07
        local left = M.FEED_LIFE - f.t
        if left < FEED_FADE then a = a * math.max(0, left / FEED_FADE) end
        txt(line_text(f.text), right, y + LINE * S / 2, FONT * S,
            pal.a(f.col or pal.DIM, a), "right", nil, true)
        y = y + LINE * S
    end
    -- As wide as the widest line it drew rather than a guess, since a feed of
    -- short names is a narrow block and a zone the width of the panel would
    -- claim empty screen beside it.
    local wide = 0
    for i = 1, shown do
        local w = text_w(line_text(lines[i].text), FONT * S)
        if w > wide then wide = w end
    end
    local block_top = top + PANEL_Y * S
    local block_bot = block_top + shown * LINE * S
    -- Its left edge and its whole height. The word goes beside the block, not
    -- under it: under it the bar could only be a line tall and the sentence
    -- read as a sixth kill, and the feed is the one panel here that is already
    -- a column of sentences.
    anchor.feed = {right - wide, block_top, block_bot}
    zone("feed", right - wide, block_top, wide, block_bot - block_top)
end

-- The one line a phone shows.
--
-- The feed is a column of five short lines hung off the right edge under the
-- dial, and on a touchscreen it was drawn not at all: that corner is where a
-- thumb flies the ship, and a running log nobody can pause is not what a
-- player wants there. Which left a phone with no way at all to learn that
-- somebody had just killed them, or that the green they flew through was a
-- rung of bomb rather than a rung of gun.
--
-- So the phone gets the same feed, filtered to one line. Only lines the arena
-- marked as being about this pilot: their kills, their deaths, and what they
-- picked up. A stranger killing a stranger is news, and it is news a player
-- in a fight cannot use. And only the newest of those at once, because two
-- lines stacked over the middle of the screen is a panel, and a panel over
-- the fight is the thing the corner feed was moved out of the way to avoid.
--
-- Shorter-lived than a feed line, too. Nine seconds is right for a column
-- that is read at a glance and scrolls; the same nine seconds in the middle
-- of the screen is a caption that lives there.
local TOAST_LIFE = 3.6
local TOAST_FADE = 0.9

-- Where it sits, which is the far side of the screen from the thumbs in
-- whichever way the phone is being held.
-- `reach` is how far up the screen the controls climb, in drawable pixels
-- from the bottom, handed down by the frame loop. Asked for rather than
-- worked out here: touch.lua owns where a thumb's controls go, this file owns
-- where the instruments go, and the two stopped requiring each other on
-- purpose.
local function toast_y(reach)
    if W >= H then
        -- Landscape: under the flags, in the band across the top that the
        -- corner chips and the dial leave empty between them.
        return ST + 62 * S
    end
    -- Portrait: two thirds of the way down, the empty band between the ship
    -- and the controls. Clamped clear of what the pads actually reach rather
    -- than trusting the fraction, since a hull carrying four kinds of charge
    -- builds a taller rail than one carrying none, and the rail is the thing
    -- this must not land on.
    local floor = reach and (H - reach - 22 * S) or H
    return math.min(H * 0.66, floor)
end

local function toast(lines, reach)
    local f = nil
    for i = 1, #lines do
        if lines[i].mine and lines[i].t < TOAST_LIFE then
            f = lines[i]
            break
        end
    end
    if not f then return end
    local a = 1
    local left = TOAST_LIFE - f.t
    if left < TOAST_FADE then a = math.max(0, left / TOAST_FADE) end
    local words = line_text(f.text)
    local size = (FONT + 1) * S
    local y = toast_y(reach)
    -- A wash under it rather than a box round it, the width of the words and
    -- no wider. Mid-screen over a starfield the type needs something to sit
    -- on; a border would be the one shape this interface does not draw.
    local w = text_w(words, size) + 26 * S
    local h = LINE * S + 6 * S
    -- The card a dead pilot reads is the one other slab that lands near the
    -- middle, and in both orientations it lands clear of this. Both cannot
    -- grow forever though, so the check is the overlap itself rather than
    -- "are they dead": a death line is exactly the kind this exists to show,
    -- and refusing to draw it whenever a card is up would be refusing the
    -- commonest one.
    if wait_box and y - h / 2 < wait_box.y + wait_box.h
       and y + h / 2 > wait_box.y then
        return
    end
    rect(W / 2 - w / 2, y - h / 2, w, h, pal.rgb(0x03050a, 0.62 * a))
    txt(words, W / 2, y, size, pal.a(f.col or pal.INK, a), "center", nil, true)
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
-- --- the corner stack's glyphs ---------------------------------------------
--
-- The stack used to label its rows and add-ons in words, which made the
-- corner a column of reading in the one place a pilot only ever glances.
-- Each word is a mark now: rows wear a miniature of the thing itself, drawn
-- the way the arena draws it. The hover and the held H spell any of them out
-- on request, so the words are an ask away rather than always on.
--
-- A trigger's add-ons used to be marks of their own, set out in a row to the
-- right of the ladder, and that was the wrong picture of what they are. Six
-- shapes lined up beside a seventh read as seven things a ship carries, when
-- what a player actually holds is one gun and one bomb that greens have been
-- changing all match. So there is one mark per trigger now, and an add-on is
-- something drawn onto it: the round you fire, wearing what it has learned.

-- The repel's rings, which are also the push add-on's: the same force in
-- both places, so the same mark.
local function gl_rings(cx, cy, k, col)
    u:ring(cx, ry(cy), k * 0.36, pen(k, 0.143), 10, col)
    u:ring(cx, ry(cy), k * 0.78, pen(k, 0.129), 12,
           pal.a(col, (col[4] or 1) * 0.5))
end

-- Rounds in every direction: the burst at eight spokes, shrapnel at six.
local function gl_spokes(n)
    return function(cx, cy, k, col)
        for i = 0, n - 1 do
            local a = (i + 0.5) * 2 * math.pi / n
            local dx, dy = math.cos(a), math.sin(a)
            u:seg(cx + dx * k * 0.3, ry(cy + dy * k * 0.3),
                  cx + dx * k, ry(cy + dy * k), pen(k, 0.143), col)
        end
    end
end
local gl_burst = gl_spokes(8)

-- What a green is, worn by the row that counts what greens made you worth.
local function gl_diamond(cx, cy, k, col)
    local pts = {cx, ry(cy - k), cx + k * 0.8, ry(cy),
                 cx, ry(cy + k), cx - k * 0.8, ry(cy)}
    u:outline(pts, pen(k, 0.183), col, true)
end

-- A charge is whatever the zone put in the slot, so the mark follows the
-- name and an unfamiliar one falls back to the prize shape it arrived as.
-- Each in the colour it goes off in: a repel is the gold of the count beside
-- it, a burst the violet of the two dozen rounds it throws. Grey said
-- "instrument" on a row where every other mark now says what the thing is.
local CHARGE_GLYPHS = {repel = gl_rings, burst = gl_burst}
local CHARGE_HUES = {repel = pal.CHARGE_COL, burst = pal.BURST}

-- --- the two weapon marks --------------------------------------------------
--
-- Both live in arena/marks.lua, which is also where the trigger pads get
-- theirs, so a phone and a desktop cannot end up showing a hull two different
-- loadouts. All this end does is hand over a point in its own coordinates.

-- A trigger's mark, standing its round on the stack's axis. Returns how far
-- right the whole thing reached, since a hull holding three add-ons draws a
-- good deal wider than one holding none and the row is measured by what it
-- drew rather than by a constant.
--
-- The y flip is the one thing that cannot move into the shared file. This one
-- reckons y downward and marks.lua reckons it upward, and every earlier
-- attempt to let the shared drawing decide for itself put a second flip
-- somewhere and mirrored a mark.
local function weapon_mark(cx, cy, k, me, t)
    return marks.weapon(cx, ry(cy), k, me, t)
end

-- What those marks mean, in words, for the hover and the held H. The
-- decorations are the row now, and a player who has just picked up their
-- first proximity has no way to learn that the dashed ring is what arrived.
local function mod_words(me, t)
    local out = nil
    for i = 1, #pal.MODS do
        local n = sim.ship_mod(me, t, i - 1)
        if n > 0 then
            local w = pal.MODS[i].name
            if n > 1 then w = w .. " x" .. n end
            out = out and (out .. ", " .. w) or w
        end
    end
    return out
end

-- How much bigger than the rest of the interface the corner stack draws, and
-- the share of the window it may take doing it.
--
-- This corner is the one thing a pilot reads without looking away from their
-- own hull, and it was laid out to the same metric as panels you stop and
-- read: rows of drawings eight or nine points across, glanced at from the
-- middle of a fight. It reads at rest and not in flight, which is the only
-- time it is on screen.
--
-- The share is what keeps that honest on a window it was not sized for. Five
-- rows at full size are most of the height of a phone held sideways, so a
-- short window gets whatever fits and never less than the old size.
local STACK, STACK_SHARE = 1.5, 0.34

local function status(me, charges, lift)
    local slots = charges or {}
    -- On a touchscreen the pads carry all of this: the counts sit over the
    -- charge pads and the weapon marks sit inside the trigger pads, drawn by
    -- touch.lua draws them, so any row here would be the same thing twice at
    -- opposite corners of a screen that has no room for once. What is left
    -- of the stack on glass is the one row no pad speaks for: the bounty.
    local show_charges = #slots > 0 and not M.touching
    local show_trigs = not M.touching
    local trigs = 0
    if show_trigs then
        for t = 0, SIM_TRIGGERS - 1 do
            if sim.has_trigger(me, t) then trigs = trigs + 1 end
        end
    end
    local n = trigs + (show_charges and #slots or 0) + 1

    -- One number the whole block is measured in, so it grows as a drawing
    -- rather than as a pile of separately tuned constants. Everything below
    -- is in `z`, not in S.
    local z = S * math.max(1, math.min(STACK,
                                       (H / S) * STACK_SHARE / (n * 22)))
    local rows_h = 22 * z
    local x = SL + PAD * S
    -- The axis every mark stands its subject on: the head of each round, the
    -- centre of the repel's rings and the burst's hub, the middle of the
    -- green. Far enough in that a bolt's trail, which runs a hull and a half
    -- back from its head, still starts inside the margin.
    local mid = x + 15 * z
    -- Where the counting starts. Close in, because a mark cannot run into it:
    -- marks.MARK_REACH bounds how far past its subject the widest loadout
    -- draws, and this clears that. The column used to sit far enough out for
    -- a row of separate add-on symbols that no longer exists, which left every
    -- ordinary row reading as two stacks with a hole between them.
    local val = mid + 17 * z

    local y = H - PAD * S - n * rows_h - (lift or 0)
    -- How far right the stack actually reached, which is what decides where a
    -- label beside it starts. A hull holding three add-ons is a good deal
    -- wider than one holding none, and a constant here would either crowd the
    -- wide case or strand the narrow one.
    local wide = val + 44 * z
    -- The charge rows in the order they were drawn, so a reader of this list
    -- walks them down the stack the way a reader of the stack does.
    anchor.charge_order = {}

    -- A level is the same weapon harder, so it is rungs on a ladder; an
    -- add-on changes what the round is, so it is drawn onto the round.
    for t = 0, show_trigs and SIM_TRIGGERS - 1 or -1 do
        if sim.has_trigger(me, t) then
            local lvl = sim.ship_level(me, t)
            local reach = weapon_mark(mid, y + rows_h / 2, 9 * z, me, t)
            ladder(val, y + rows_h / 2 - 2 * z, 3, lvl + 1, pal.FRIEND,
                   40 * z, 4 * z)
            local key = (t == sim.TRIG_GUN) and "gun" or "bomb"
            anchor[key] = y + rows_h / 2
            anchor[key .. "_mods"] = mod_words(me, t)
            -- The row as far right as it actually drew. A loaded bomb wears
            -- fragments a third of the mark's width clear of it, and pointing
            -- at one of those is still pointing at the bomb.
            local right = math.max(reach, val + 40 * z)
            if right > wide then wide = right end
            zone(key, x, y, right - x, rows_h)
            y = y + rows_h
        end
    end

    if show_charges then
        for _, c in ipairs(slots) do
            -- No ready mark and no key letter: there is no selection to
            -- show any more, a key or a pad names its charge outright, and
            -- which key is which row is the help page's job, not a label
            -- worn in the corner of every fight.
            local slot = string.lower(c.name or c.short or "")
            local gc = CHARGE_GLYPHS[slot] or gl_diamond
            gc(mid, y + rows_h / 2, 7 * z,
               pal.a(CHARGE_HUES[slot] or pal.PRIZE, 0.85))
            local slot_max = math.max(1, c.max or 3)
            pips(val + 3 * z, y + rows_h / 2, slot_max, c.count,
                 pal.CHARGE_COL, 2.7 * z, 9 * z)
            local pw = val + 3 * z + slot_max * 9 * z
            if pw > wide then wide = pw end
            -- A row per charge rather than one bracket over all of them. A
            -- repel and a burst are different things and each has a card of
            -- its own; they shared a sentence only while that sentence was
            -- about which key spends them.
            local key = "charge:" .. string.lower(c.name or c.short or "")
            anchor[key] = y + rows_h / 2
            anchor.charge_order[#anchor.charge_order + 1] = key
            zone(key, x, y, pw - x, rows_h)
            y = y + rows_h
        end
    end

    -- What you are worth, which is the number that decides who comes for you,
    -- and which was only ever behind the info toggle. The mark is the green's
    -- own diamond, since greens are most of what the number counts.
    gl_diamond(mid, y + rows_h / 2, 6 * z, pal.a(pal.PRIZE, 0.8))
    local bty = sim.ship_bounty(me)
    txt(tostring(bty), val, y + rows_h / 2, (FONT - 2) * z,
        bty > 0 and pal.a(pal.PRIZE, 0.95) or pal.a(pal.DIM, 0.5))
    anchor.bounty = y + rows_h / 2
    local bw = val + text_w(tostring(bty), (FONT - 2) * z)
    if bw > wide then wide = bw end
    zone("bounty", x, y, bw - x, rows_h)

    anchor.stack_x = wide + 26 * z
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
    local x = SL + PAD * S
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
    local x = SL + PAD * S
    local rowh = 15 * S
    -- Name, then the rows that always exist, then the team when it means
    -- something. Counted rather than guessed so the panel is exactly as tall
    -- as what it holds.
    local theirs = sim.ship_team(i)
    local same_team = theirs == view_team
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
    -- The other thing this panel can offer, and it belongs here for the same
    -- reason the invitation does: you opened it by picking a person, and
    -- borrowing their eyes is a thing you do to a person rather than to a
    -- seat number. Drawn only where it would work, which is a teammate: the
    -- zone grants live sight of your own side and refuses it of anybody
    -- else's, so offering it on an enemy would be a control that quietly
    -- dropped you back on the room channel.
    local follow = o.watch and same_team and o.watch.subject ~= i
    local rows_n = 5 + (side and 1 or 0)
    local h = 30 * S + rows_n * rowh
        + ((invite or follow) and (KEY_H + 12) * S or 0) + 10 * S
    -- Under whatever is in the column, and never above where the column
    -- starts: with the scoreboard shut there is nothing above it, and a panel
    -- at the top of the screen lands on the menu chip.
    local y = math.max((top or 0) + 6 * S, top_y())
    rect(x, y, w, h, pal.a(pal.BG, 0.72))
    vrule(x, y, h, pal.a(same_team and pal.FRIEND or pal.ENEMY, 0.9))

    local col = same_team and pal.FRIEND or pal.ENEMY
    local nm = (p and p.name) or ("ship " .. i)
    txt(nm, x + 12 * S, y + 17 * S, (FONT - 1) * S, pal.a(col, 0.95),
        nil, nil, true)
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
    local function row(k, v, vcol, raw)
        txt(k, x + 12 * S, ry_ + rowh / 2, lab, pal.a(pal.DIM, 0.8))
        txt(v, x + w - 12 * S, ry_ + rowh / 2, val, vcol or pal.a(pal.INK, 0.9),
            "right", nil, raw)
        ry_ = ry_ + rowh
    end
    if side then
        -- A side somebody founded and named is a name as well.
        row("SIDE", side, pal.a(col, 0.9), true)
    end
    -- What the zone is willing to say this seat is, which is the honest
    -- version of the question: the client cannot tell, and the server's label
    -- is the only answer anybody has. A guest is not an accusation.
    row("SEAT", (p and p.label) or "unknown")
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

    -- One word and a rule under it, because that is what a control looks like
    -- inside a panel. Once it is sent it says so and stops taking
    -- clicks: the zone answers an invitation with a team list that does not
    -- name the invitee, so this mark is the only acknowledgement there is, and
    -- a button that stayed pressable would invite an anxious second tap.
    -- Drawn as a key, the way everything else in this interface that is a
    -- thing to press is drawn: the corner's MENU and PLAYERS, the answers on
    -- a confirm card, every key on the help board. They were a word over a
    -- rule, which is what a control looked like here before the board taught
    -- the same hand what a key looks like, and a panel keeping the old idiom
    -- asks a player to know that this particular word is pressable.
    --
    -- Both verbs use the same slot, since a panel with two possible actions
    -- should put them where the eye already found the first one. They never
    -- appear together: inviting wants somebody who is not on your side and
    -- following wants somebody who is.
    local label, action = nil, nil
    if invite then
        -- Once it is sent it says so and stops taking clicks: the zone answers
        -- an invitation with a team list that does not name the invitee, so
        -- this is the only acknowledgement there is, and a button that stayed
        -- pressable would invite an anxious second tap.
        label = (o.invited and o.invited[i]) and "INVITED" or "INVITE"
        action = (o.invited and o.invited[i]) and nil or "invite"
    elseif follow then
        label, action = "WATCH", "watch"
    end
    if label then
        local by = ry_ + 4 * S
        local bw = key_w(label)
        key_cap(x + 12 * S, by, bw, label, action ~= nil)
        if action then
            hit(x + 12 * S, by, bw, KEY_H * S, action, i)
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

-- The weapon's own colour rather than a rung's. These figures say what killed
-- you, not how far up its ladder it was, and they used to borrow the second
-- entry of a ramp because it happened to look right -- which stopped being
-- true the moment one ramp meant one thing. Naming them is also what keeps two
-- cards from coming out the same colour.
local function fig_bomb(cx, cy, k)
    local col = pal.BOMB
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
    local col = pal.ENEMY
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

-- Fragments leaving the bomb that threw them.
--
-- Shrapnel wears the violet band in the arena, which it shares with the burst
-- and the wormhole: the palette gives that band to everything answering to
-- nobody's aim. Three violet cards would read as one, so this one keeps the
-- dying bomb at its centre in the bomb's own red. That is also the honest
-- picture, since a fragment is a thing a bomb becomes.
--
-- The angles are uneven on purpose. Shrapnel:Random is what the original's
-- own arena file sets and what the baseline copies, so a ring of them is not
-- a ring, and drawing it evenly would be drawing the burst again.
local SHRAP_ANGLES = {0.35, 1.15, 1.95, 2.55, 3.55, 4.35, 5.05, 5.85}
local function fig_shrap(cx, cy, k)
    local col = pal.BURST
    local bomb = pal.BOMB
    for _, a in ipairs(SHRAP_ANGLES) do
        local dx, dy = math.cos(a), math.sin(a)
        u:seg_fade(cx + dx * k * 0.34, ry(cy + dy * k * 0.34),
                   cx + dx * k * 0.95, ry(cy + dy * k * 0.95),
                   0.7 * S, 2.2 * S, 0, 0.85, col)
        u:disc(cx + dx * k * 0.95, ry(cy + dy * k * 0.95), k * 0.07, 6,
               pal.a(pal.hot(col, 0.9, 1), 1))
    end
    u:halo(cx, ry(cy), k * 0.3, 10, pal.a(bomb, 0.5))
    u:ring(cx, ry(cy), k * 0.2, 1.2 * S, 10, pal.a(bomb, 0.9))
end

-- The floor a pilot cannot be shot on, drawn the way the arena draws it: a
-- dashed edge round a hatched patch, in the friendly blue. The only square
-- figure in the deck, which is most of what tells it apart at a glance.
local function fig_safe(cx, cy, k)
    local col = pal.FRIEND
    local r = k * 0.82
    u:rect(cx - r, ry(cy - r, 2 * r), 2 * r, 2 * r, pal.a(col, 0.10))
    for i = -1, 1 do
        local o = i * r * 0.66
        u:seg(cx - r + math.max(0, o), ry(cy + r + math.min(0, o)),
              cx + r + math.min(0, o), ry(cy - r + math.max(0, o)),
              0.7 * S, pal.a(col, 0.3))
    end
    -- Dashed, the way a safe tile's face is: four to a side, so the gaps read
    -- as gaps rather than as a broken line.
    for i = 0, 3 do
        local t0 = -r + (2 * r) * i / 4 + r * 0.06
        local t1 = -r + (2 * r) * (i + 1) / 4 - r * 0.06
        u:seg(cx + t0, ry(cy - r), cx + t1, ry(cy - r), 1.2 * S, pal.a(col, 0.75))
        u:seg(cx + t0, ry(cy + r), cx + t1, ry(cy + r), 1.2 * S, pal.a(col, 0.75))
        u:seg(cx - r, ry(cy + t0), cx - r, ry(cy + t1), 1.2 * S, pal.a(col, 0.75))
        u:seg(cx + r, ry(cy + t0), cx + r, ry(cy + t1), 1.2 * S, pal.a(col, 0.75))
    end
end

-- The well, standing still: rings closing on an eye, with the arms that turn
-- against them out in the arena. Drawn falling inward rather than at even
-- spacing, so it reads as a pull and not as the repel's push.
local function fig_hole(cx, cy, k)
    local col = pal.HOLE
    for i = 1, 3 do
        local rr = k * (0.98 - (i - 1) * 0.26)
        u:ring(cx, ry(cy), rr, 1.0 * S, 18, pal.a(col, 0.18 + (i - 1) * 0.16))
    end
    for i = 0, 3 do
        local a0 = i * math.pi / 2 + 0.4
        u:arc(cx, ry(cy), k * 0.5, a0, a0 + 0.85, 1.2 * S, 5, pal.a(col, 0.75))
    end
    u:halo(cx, ry(cy), k * 0.3, 10, pal.a(col, 0.55))
    u:disc(cx, ry(cy), k * 0.13, 8, pal.a(pal.hot(col, 0.6, 1), 0.95))
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

-- Every card: the figure, the word for it, and what it does.
--
-- The word sits over the sentence rather than out at the box's edge, which is
-- where a caption lived once and did not work: out there it read as a label
-- for the whole panel, and the panel is always the same thing. Above the body
-- it is a heading for the paragraph under it, which is what it actually is,
-- and it gives a pilot the name to carry away. The figure alone taught the
-- shape and left them with nothing to call it.
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
    shrap = {fig = fig_shrap, name = "SHRAPNEL",
             text = "Fragments thrown by a bomb when it detonates. Each one " ..
                    "hits as hard as a bullet, and they bounce off walls."},
    safe = {fig = fig_safe, name = "SAFE ZONE",
            text = "Nothing can hurt you inside one, and you cannot fire " ..
                   "out. Pulling a trigger there stops your ship dead."},
    hole = {fig = fig_hole, name = "WORMHOLE",
            text = "Pulls in anything that comes near. Fly into one and it " ..
                   "throws you to a random start with your speed gone."},
}
M.CARDS = CARDS

-- What is drawn under DESTROYED while a pilot waits to fly again.
--
-- The shape is the interface's own and nothing new: a wash to lift it off
-- the arena, the map border's tick as a rule across the top, and under it a
-- card. It had corner brackets and a caption once, and both went. A frame is
-- for holding a cluster together against the panels around it, and this box
-- shares the middle of the screen with nothing.
--
-- The rule is the clock. It is drawn twice, dim across the full width and
-- lit across what is left of the respawn, so the one line the box carries
-- besides its card also says how long there is to read it. A numeral
-- counting down would be a thing to watch instead of the sentence, and this
-- game has one big centred readout already.
--
-- Centred under the banner rather than in a corner, because for these few
-- seconds there is nothing to fly and nothing to look away from, and it goes
-- the moment the hull is back.
-- Where the box goes and what it holds, worked out before anything else is
-- drawn so `nameplates` can step around it in the same frame. Measuring and
-- drawing are separate for that reason alone: the box is drawn last, over
-- everything, and a rectangle published then would be a frame stale, which is
-- one frame of a stranger's name across the sentence at the moment it appears.
local function wait_layout(which)
    local card = CARDS[which]
    if not card then return nil end
    -- Sized up, and against the wrong thing before. It was set under the
    -- corner stack's own body text, which is what a pilot reads at a glance
    -- while flying; this is read once, at arm's length, in the only seconds
    -- of the game where there is nothing else to do. A card nobody finishes
    -- is a card that may as well not be dealt.
    local fs = (M.compact and 13 or 15) * S
    local pad = 16 * S
    -- Wide enough to read, never wider than the screen it is on. The width
    -- is set by the longest card rather than by taste: the bomb is 123
    -- characters and wraps to four rows under 560, the last of them holding
    -- the single word "miss."
    local w = math.min(560 * S, W - 40 * S)
    local inner = w - pad * 2
    -- The figure's cell, and what is left for the sentence beside it. Square,
    -- because every shape in here is drawn around its own centre and a cell
    -- that was not square would put the bomb and the flag on different axes.
    local cell = (M.compact and 50 or 60) * S
    local gap = 14 * S
    -- Wrapped to less than the column holds. A line broken at exactly the
    -- width ends flush against the padding, which reads as text that only
    -- just fitted rather than text that was laid out.
    local measure = inner - cell - gap - 6 * S
    local lines = wrap(card.text, fs, measure)

    local rule = 13 * S              -- the clock rule, at the top of the box
    local rowh = 19 * S
    -- The heading and the air under it, which the figure's cell has to clear
    -- as well: the shape is centred on the whole block, name included, or it
    -- floats against a column it is supposed to sit beside.
    local lab = (M.compact and 11 or 12) * S
    local headh = lab + 9 * S
    -- Tall enough for the figure or for the words, whichever asks for more,
    -- so a one-line card is not a box with a bomb hanging out of the bottom.
    local body = math.max(cell, headh + #lines * rowh)
    local h = rule + 13 * S + body + 13 * S
    return {
        x = (W - w) / 2, y = H * 0.46 + (M.compact and 22 or 30) * S,
        w = w, h = h, inner = inner, pad = pad,
        fs = fs, lab = lab, headh = headh, rule = rule, rowh = rowh,
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

    -- The clock. `respawn_at` counts down in the core and is in every
    -- snapshot, so this is read rather than timed here: a local stopwatch
    -- would drift off the tick that actually puts the hull back.
    --
    -- The bar and nothing else. It used to run over a ticked rule, which is a
    -- ruler under a thing nobody is measuring: the wait is over when the bar
    -- runs out, and how much of a second each tick stood for was never a
    -- question anybody had while they were dead.
    local left, delay = 0, 0
    if sim.ship_respawn then left, delay = sim.ship_respawn(me) end
    if delay > 0 and left > 0 then
        local frac = left / delay
        if frac > 1 then frac = 1 end
        u:seg(x + b.pad, ry(y + b.rule),
              x + b.pad + b.inner * frac, ry(y + b.rule),
              1.2 * S, pal.a(pal.FRIEND, 0.7))
    end

    -- The words on the left, the figure on the right.
    --
    -- Reading order decides it. Every other panel in this interface opens at
    -- the left edge and the eye starts there by habit, so the name is the
    -- first thing met and the shape is what the sentence hands you at the end
    -- of it. With the figure leading, the eye had to step over a shape it did
    -- not yet have a word for.
    --
    -- The block of words is centred on the body's own middle rather than hung
    -- from the top, so a one-line card and a three-line card are both
    -- balanced against the shape, and the figure sits on that same middle.
    local top = y + b.rule + 13 * S
    local mid = top + b.body / 2

    local tx = x + b.pad
    local block = b.headh + #b.lines * b.rowh
    local ty = mid - block / 2 + b.lab / 2
    -- Brighter than the sentence under it, in the ink the interface names
    -- things with, so the eye takes the word first and then reads why.
    txt(b.card.name, tx, ty, b.lab, pal.a(pal.INK, 0.9))
    ty = ty + b.headh - b.lab / 2 + b.rowh / 2
    -- The word above is a label and shouts with the rest of the HUD. What is
    -- under it is prose: three seconds of reading rather than a glance, and a
    -- paragraph in capitals is a paragraph nobody finishes.
    --
    -- The capital is taken once, on the first line. Cased line by line, a
    -- sentence that wrapped onto three of them would start three times.
    local was = case
    case = "sentence"
    for i, line in ipairs(b.lines) do
        txt(line, tx, ty, b.fs, pal.a(pal.PANEL_INK, 0.92), nil, nil, i > 1)
        ty = ty + b.rowh
    end
    case = was

    -- Centred in what the text column left, against the box's right padding,
    -- so the shape has air round it rather than being pushed against a wall.
    b.card.fig(x + b.w - b.pad - b.cell / 2, mid, b.cell / 2)
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

-- One thing to press, wherever the thing to press turns up: a frame with a
-- hint of fill, lit in the colour of what it does, and its word in capitals in
-- the face the numbers are set in. The corner keys and a question's answers
-- are the same object, so they are one drawing rather than two functions
-- agreeing on seven numbers by hand.
--
-- `KEY_H` and `KEY_SIZE` are the two of them a caller has to lay out around,
-- so they live out here with it rather than being repeated at each call.
local function menu_button(on_air, watch)
    -- Two keys, drawn the way the help page draws a key. They were two bare
    -- words over a shared rule, which asked a player to know that a word in
    -- that corner was a thing to press, and the board has taught the same hand
    -- what a key looks like already.
    --
    -- One colour between them, and one rule for lighting it. MENU was drawn in
    -- ink and PLAYERS in slate, which is two controls that do the same kind of
    -- thing wearing two different states before either had been pressed. What
    -- they wear now is off or on, and the panel each opens is what turns it on.
    local x, y = SL + PAD * S, ST + PAD * S
    -- Each key is as wide as its own word. A slot cut for four letters is a
    -- slot the longer of the two runs out of.
    local cx = x
    for _, c in ipairs({{"MENU", "open", menu_up},
                        {"PLAYERS", "details", M.details}}) do
        local ww = key_w(c[1])
        key_cap(cx, y, ww, c[1], c[3])
        hit(cx, y, ww, KEY_H * S, c[2])
        cx = cx + ww + KEY_GAP * S
    end
    -- The tally, when the room channel is pointed at you.
    --
    -- It sits on this row rather than at the top of the middle, which is where
    -- it started and where it could not stay: that strip already carries the
    -- flag pennants and the round's banner, both of them centred, and a notice
    -- laid over them read as a fault in the flags. Those two are about the
    -- round. This is about you, like the keys beside it, and it is chrome
    -- rather than anything happening in the arena.
    --
    -- Counted into `chip_right` like the keys are, so the map that opens
    -- across this corner keeps clear of it by the rule that already keeps it
    -- clear of them.
    if on_air then
        local mid = y + KEY_H * S / 2
        -- A slow swell rather than a blink. It has to hold attention for as
        -- long as the camera holds you, which is minutes, and a blink that
        -- long is something a player learns to stop seeing.
        local beat = 0.55 + 0.45 * math.sin(M.now * 3.2)
        local r = 3.4 * S
        u:disc(cx + r, ry(mid, 0), r, 10, pal.a(pal.HURT, beat))
        local label = "ON AIR"
        local size = key_size()
        txt(label, cx + 2 * r + 5 * S, mid, size, pal.a(pal.HURT, 0.9))
        cx = cx + 2 * r + 5 * S + text_w(label, size) + KEY_GAP * S
    elseif watch then
        -- Watching, and what of. The same slot, because the two are the same
        -- kind of fact about the connection and a watcher is never on air.
        --
        -- Green and a play mark rather than the tally's red dot: the red one
        -- is a warning about you and this is a statement about what you are
        -- looking at, which is the difference between being filmed and
        -- holding the camera.
        local mid = y + KEY_H * S / 2
        local h = 4.6 * S
        local wsym = h * 1.5
        local col = pal.a(pal.PRIZE, 0.92)
        u:tri(cx, ry(mid - h, 0), cx, ry(mid + h, 0),
              cx + wsym, ry(mid, 0), col)
        local size = key_size()
        -- The room's feed says so in the interface's own word; a pilot says
        -- their own call sign, in their own case, the way a name is written
        -- everywhere else here.
        local named = watch.name ~= nil
        txt(named and watch.name or "CHANNEL",
            cx + wsym + 6 * S, mid, size, col, nil, nil, named)
        cx = cx + wsym + 6 * S
            + text_w(named and watch.name or "CHANNEL", size) + KEY_GAP * S
    end
    chip_right = cx - KEY_GAP * S
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
    local right = W - SR - pad
    local base = ST + pad + 13 * S
    for k = 0, 3 do
        local bh = (3 + k * 2.6) * S
        local bx = right - (26 - k * 6) * S
        rect(bx, base - bh, 4 * S, bh,
             k < q and pal.a(pal.PRIZE, 0.85) or pal.a(pal.DIM, 0.22))
    end
    txt("LINK", right - 34 * S, base - 4 * S, (FONT - 3) * S,
        pal.a(pal.DIM, 0.8), "right")
    -- Pointing at this one names nothing. Four bars labelled LINK beside a
    -- millisecond count are already a sentence about the connection, and a
    -- word saying so is the interface reading its own label back.
    -- The bars are the readout a player wants and the whole of it. Everything
    -- behind them is for whoever is working on this, so it hides behind the
    -- one thing on screen that is already about the connection.
    --
    -- What answers that press is the whole cluster and the strip it stands
    -- in. It was 46 by 20 points hung off the right edge, which covered the
    -- four bars and the last quarter of the word beside them: three quarters
    -- of the only thing on screen labelled LINK did nothing when pressed,
    -- and twenty points is half the height a thumb is usually given. It also
    -- took its top from the window while the drawing took it from the safe
    -- area, so a phone with an island drew the readout below the box meant
    -- to open it.
    --
    -- The strip above the dial is reserved for this readout already, so the
    -- box takes all of it: from the word's left edge to the screen's own,
    -- and from the top of the safe area down to where the dial starts. The
    -- corner does as much work as the size, since a thumb aimed there cannot
    -- overshoot upward or to the right off the screen. Taller would mean
    -- taking a strip off the dial, which is the control that opens the map,
    -- and one control does not get to eat another.
    if not menu_up then
        local _, dial_y = dial()
        local x0 = right - 34 * S - text_w("LINK", (FONT - 3) * S) - 6 * S
        hit(x0, ST, W - x0, math.max(dial_y - ST, 24 * S), "debug")
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
    local x = W - SR - PAD * S - w
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
    -- The way out is the thing itself. What opens this is the LINK bars in
    -- the far corner, which is a fine place to keep a switch nobody needs
    -- and a poor place to look for one: on a phone the readout lands under
    -- the dial, a screen's width from the four bars that put it there, and a
    -- player who has finished reading it has no reason to think the answer
    -- is back up in the corner. So a press anywhere on the panel closes it,
    -- which is what every other slab of text in this interface does.
    --
    -- Filed here rather than beside the bars, because it is this rectangle,
    -- and it is this rectangle only once the wrapping above has decided how
    -- many columns the window can hold.
    if not menu_up then hit(x, y, w, h, "debug") end
end

-- Where you are, over the dial's other top corner from the link readout.
--
-- In tiles, because that is the unit the map is laid out in and the unit a
-- player says out loud. Pixels would be the same place in numbers six digits
-- long that nobody can hold in their head or call across a room.
local function coords(me)
    if not me then return end
    local pad = (M.compact and 8 or PAD) * S
    local x = dial()
    local base = ST + pad + 13 * S
    txt("POS", x, base - 4 * S, (FONT - 3) * S, pal.a(pal.DIM, 0.8))
    txt(string.format("%d,%d", math.floor(sim.ship_x(me) / 16),
                      math.floor(sim.ship_y(me) / 16)),
        x + 26 * S, base - 4 * S, (FONT - 3) * S, pal.a(pal.INK, 0.85))
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
    local my_team = view_team
    local pitch = 15 * S
    local x0 = W / 2 - (n - 1) * pitch / 2
    local y = ST + 30 * S
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

-- --- the help label --------------------------------------------------------
--
-- Point at an instrument and it says what it is. Nothing is held, nothing is
-- toggled, and one thing is named at a time: the pointer is already an
-- expression of what you are asking about, so the question and the answer land
-- in the same place.
--
-- There was a held key for a while that named every instrument at once, and
-- what killed it is the sentences getting longer. Short phrases sat beside
-- their rows and adjacency did the work. Cards do not fit on a row, so all of
-- them together had to be gathered into a column, and a column off to one side
-- says which instrument each line belongs to by colour rather than by
-- position, which is the one thing this was built to avoid.
--
-- No leader lines either, which was the lesson before that. Every instrument
-- sits against an edge with clear space beside it, so a word set next to a
-- thing reads as being about that thing.

-- The line for one instrument, or nil where an instrument has nothing to say
-- beyond the label it already wears: GUN and BOMB name themselves, so their
-- lines explain the rung rather than the word.
--
-- Every instrument offers itself and only the one asked for is built, which
-- keeps the list of what can be named in one place while costing one sentence
-- to draw one. The pointer asks again every frame it rests somewhere, and
-- wrapping six sentences sixty times a second to draw the seventh is how a
-- cursor stops keeping up.
local function help_line(want)
    local found = nil
    -- `top` and `bot` are the run of the bar. Given, it is as tall as the
    -- instrument; left out, it is as tall as the sentence, which is now often
    -- more than one line.
    --
    -- Wrapped against the room actually left beside the thing, and never wider
    -- than a measure somebody can read across. A card's worth of words set as
    -- one line runs most of the way over the arena.
    local function add(key, x, y, s, col, align, top, bot)
        if key ~= want then return end
        local px = (FONT - 1) * S
        local room = (align == "right") and (x - 22 * S) or (W - x - 22 * S)
        local e = {key = key, x = x, y = y, col = col, align = align,
                   top = top, bot = bot,
                   lines = wrap(s, px, math.min(room, 640 * S))}
        e.h = #e.lines * LINE * S
        found = e
    end
    -- The corner stack says what the card a dead pilot reads says, word for
    -- word, out of CARDS. One sentence per thing, wherever a player meets it:
    -- learning what a bomb is from the wait after it killed you and then
    -- pointing at the BOMB row should not be learning it twice in two
    -- different sets of words.
    local sx = anchor.stack_x
    if sx then
        local function card(key, at, which, col, mods)
            local c = CARDS[which]
            if not at or not c then return end
            -- What the round on the row is wearing, named. The card says what
            -- the weapon is in general; the add-ons are what this hull picked
            -- up in this fight, and a shape drawn onto a mark is learnable
            -- exactly once, by being told.
            local s = mods and (c.text .. " Carrying " .. mods .. ".")
                or c.text
            add(key, sx, at, s, col)
        end
        card("gun", anchor.gun, "bolt", pal.FRIEND, anchor.gun_mods)
        card("bomb", anchor.bomb, "bomb", pal.BOMB, anchor.bomb_mods)
        for _, key in ipairs(anchor.charge_order or {}) do
            -- The slot's own name is the card's name: repel and burst each
            -- have one. A slot with no card is a charge this build has not
            -- described yet, and it says nothing rather than guessing.
            card(key, anchor[key], key:match("^charge:(.*)$"), pal.CHARGE_COL)
        end
        card("bounty", anchor.bounty, "bounty", pal.PRIZE)
    end
    -- Beside the dial and as tall as it, whichever dial it is. The map is four
    -- times the radar and a bar sized to the sentence would read as a note
    -- attached to whatever row of the map it happened to land on.
    if anchor.radar then
        local top, bot = anchor.radar[2], anchor.radar[3]
        add("radar", anchor.radar[1] - 16 * S, (top + bot) / 2,
            M.map and "the whole arena, and you as the arrow"
            or "near space. the rings are range.",
            pal.RADAR_TILE, "right", top, bot)
    end
    if anchor.feed then
        local top, bot = anchor.feed[2], anchor.feed[3]
        add("feed", anchor.feed[1] - 16 * S, (top + bot) / 2, "who paid whom",
            pal.BOUNTY, "right", top, bot)
    end
    return found
end

-- A bar in the thing's own colour, then the sentence. The bar sits on the side
-- facing whatever is being named, so it points without a line.
local function help_draw(e)
    local f = (FONT - 1) * S
    local lh = LINE * S
    -- The words are centred on the row; the bar is as tall as the instrument
    -- when it was given one, and otherwise as tall as the words.
    local ttop = e.y - e.h / 2
    local top = e.top or ttop
    local bot = e.bot or (ttop + e.h)
    local dir = (e.align == "right") and -1 or 1
    rect(e.x + (dir < 0 and -3 * S or 0), top, 3 * S, bot - top,
         pal.a(e.col, 0.85))
    -- The same sentences the dead read, so they are set the same way: prose,
    -- with its capital taken once on the first line.
    local was = case
    case = "sentence"
    for i, line in ipairs(e.lines) do
        txt(line, e.x + dir * 11 * S, ttop + (i - 0.5) * lh, f,
            pal.a(pal.INK, 0.95), e.align, nil, i > 1)
    end
    case = was
end

-- A block that would hang off the bottom or the top is moved back on, since
-- the corner stack sits against the bottom of the screen and the sentence
-- beside its last row is taller than the row is.
local function help_fit(e)
    local half = e.h / 2
    if e.y + half > H - 8 * S then e.y = H - 8 * S - half end
    if e.y - half < 8 * S then e.y = 8 * S + half end
end

-- The pointer resting on one instrument names that instrument, and nothing
-- else happens: no wash, no other lines, no mode. This is a question asked of
-- one thing, and it has to cost about as much as looking at it.
local function help_hover(key)
    local e = help_line(key)
    if not e then return end
    -- On its own row, since one block has nothing to collide with and every
    -- reason to sit against the thing being pointed at.
    help_fit(e)
    help_draw(e)
end

function M.hud(o)
    case = "upper"
    if sim.ship_count() == 0 then return end
    local me = o.me
    -- Before anything draws: every instrument that separates a friend from an
    -- enemy reads this, and while watching it is not the subject's side.
    view_team = o.side or team_of(o.me)
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
    if not o.menu_open and not o.watch and sim.ship_alive(me) == 0 then
        wait_box = wait_layout(o.tip)
    end

    -- On a touchscreen the bottom of the screen belongs to the thumbs. The
    -- stick sits in the bottom left corner and the pads in the bottom right,
    -- which is exactly where the status panel and the control hint were, so
    -- everything else moves up out of the way of them.
    local lift = M.touching and 150 * S or 0

    local top = scores(me, o.pilots, o.watchers)
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
    -- The phone's own reading of that same feed, and not in the same place:
    -- this one is over the middle of the screen rather than in the corner the
    -- debug readout took, so the two do not argue about a strip.
    if M.touching then toast(o.feed, o.pad_top) end
    -- Stacked, not overlaid: the panel that is always there sits at the
    -- bottom and the one you asked for sits on top of it. A watcher has no
    -- hull, so the hull's furniture -- the corner stack, the loadout -- is
    -- not drawn at all; the room's instruments stay.
    if not o.watch then
        status(me, o.charges, lift)
    end
    inspect(o, o.watch and top or loadout(me, o.class_names, top))
    -- A watcher is never the subject, so the tally can only be about a pilot
    -- who is flying, and the two never contend for the slot.
    menu_button(o.on_air and not o.watch, o.watch)
    vignette(o.hurt or 0)
    -- The pip over your own hull is not named. A bar that empties as you are
    -- shot and fills when you stop being shot is the one instrument here that
    -- explains itself, and a word beside it in the middle of the screen is a
    -- word in the middle of the fight.
    --
    -- Last, so the word lands on top of the instrument it names. Not under the
    -- menu, which is a different screen with its own help page on it.
    if not o.menu_open then
        local key = M.help_at(o.point_x, o.point_y)
        if key then help_hover(key) end
    end

    -- The two big centred lines are the only interface that sits where the
    -- menu does. The panels can share the screen with it; these cannot.
    if o.menu_open then return end
    flag_strip(me)
    if o.banner and o.banner ~= "" then
        txt(o.banner, W / 2, 64 * S, (M.compact and 15 or 24) * S,
            pal.a(pal.INK, 0.92), "center")
    end
    if not o.watch and sim.ship_alive(me) == 0 then
        txt("D E S T R O Y E D", W / 2, H * 0.46, (M.compact and 15 or 22) * S,
            pal.ENEMY, "center")
        wait(wait_box, me)
    end
end

-- --- the menu --------------------------------------------------------------

-- A hull drawn small, inside its button. The silhouette is what picks a ship;
-- the name only confirms it. The canopy comes along because at this size it is
-- the only thing that says which end is the front.
--
-- `turn` is an angle about the hull's own vertical axis. For a flat body that
-- is a squeeze across it, which is what an orthographic projection does to a
-- shape turning about an axis lying in the screen plane: the same move the
-- asteroids tumble with, on one axis instead of two.
--
-- Never quite to a hairline. A cutout seen exactly edge-on is a line, which is
-- honest and reads as the drawing having blinked, so the end of the turn is
-- spent rather than drawn: the width bottoms out at a fifth and carries on
-- through, keeping its sign so the far side comes round rather than bouncing
-- back off the near one.
function thumb(cx, cy, cls, col, scale, turn)
    local h = world.HULLS[cls + 1]
    if not h then return end
    local k = 1
    if turn then
        local ct = math.cos(turn)
        k = (ct >= 0 and 1 or -1) * (0.2 + 0.8 * math.abs(ct))
    end
    local function trace(src, width, c)
        local pts = {}
        for i = 1, #src, 2 do
            pts[i] = cx + src[i] * scale * k
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
    {{"esc", 1.3, "menu"}, {"~", 1, "multi"}, {"1"}, {"2"}, {"3"}, {"4"},
     {"5"}, {"6"}, {"7"}, {"8"}, {"9"}, {"0"}},
    {{"tab", 1.7, "bomb"}, {"Q", 1, "charge"}, {"W", 1, "charge"}, {"E"},
     {"R"}, {"T"}, {"Y"}, {"U"}, {"I"}, {"O"}, {"P", 1, "players"}},
    {{"caps", 2.0}, {"A", 1, "charge"}, {"S", 1, "charge"}, {"D"}, {"F"},
     {"G"}, {"H"}, {"J"}, {"K"}, {"L"}},
    {{"shift", 2.25}, {"Z"}, {"X"}, {"C"}, {"V"},
     {"B"}, {"N"}, {"M", 1, "map"}},
    {{"ctrl", 1.6, "gun2"}, {"space", 6.2, "gun"}},
}
-- The board is 12.4 units across, and the arrow cluster hangs off its right
-- edge over the two bottom rows, where the letter rows have already ended.
local BOARD_UNITS = 12.4
-- How wide the page that draws it may go, against the 460 every other page
-- takes. A menu of six words does not want the room; a picture of a keyboard
-- does, and on a desktop window there is a thousand points of it going spare.
-- The column keeps its left edge and grows to the right, so nothing jumps when
-- the page changes.
-- Everything on the board is sized off the key, so the whole picture scales
-- with the panel rather than a drawing growing around type that does not.
local KEY_LETTER = 0.40   -- a single character, against key height
local KEY_WORD = 0.30     -- "shift", "space": the ones that have to fit across

-- What each colour means, in the order the legend reads.
--
-- Every lit key is on this list, which is the point of it: the three keys
-- that open something used to share one grey and a line of prose naming them
-- one after another, so the picture said "these do interface things" and the
-- caption did the actual work. A colour apiece and a word in the legend says
-- it once.
local BOARD_CATS = {
    {key = "fly", word = "fly"},
    {key = "gun", word = "guns"},
    {key = "multi", word = "multifire"},
    {key = "bomb", word = "bombs"},
    {key = "charge", word = "charges"},
    {key = "players", word = "players"},
    {key = "map", word = "map"},
    {key = "menu", word = "menu"},
}

-- Hues nothing else in the legend is wearing, which is what a legend needs
-- and all it needs. Multifire takes the colour the green that grants it is
-- drawn in, so the one key that is a gun in a different mode reads as a
-- relative of the guns rather than as a separate weapon.
--
-- Menu had the grey every unbound key is drawn in, brighter. That is not a
-- colour, it is the absence of one, and against a board of dead keys in the
-- same hue the lit one did not read as lit at all: the swatch, the word
-- under it and the key itself all looked switched off. Amber instead, which
-- nothing else on this page is wearing.
local function board_col(cat)
    if cat == "gun" or cat == "gun2" then return pal.FRIEND end
    if cat == "multi" then return pal.MOD_COL end
    if cat == "bomb" then return pal.BOMB end
    if cat == "charge" then return pal.CHARGE_COL end
    if cat == "fly" then return pal.INK end
    if cat == "players" then return pal.DOOR end
    if cat == "map" then return pal.HOLE end
    if cat == "menu" then return pal.ENEMY end
    return nil
end

-- The legend, sized off the key like everything else here so a wide board
-- does not end up captioned in type meant for a narrow one.
local LEG_GAP = 8         -- * S, between legend lines

local function legend_size(kh)
    return math.max((FONT - 3) * S, kh * 0.34)
end

local function entry_w(word, lsize)
    return lsize * 0.7 + 6 * S + text_w(word, lsize) + 18 * S
end

local function pack_legend(w, lsize)
    local lines, line, used = {}, {}, 0
    for _, c in ipairs(BOARD_CATS) do
        local ew = entry_w(c.word, lsize)
        if #line > 0 and used + ew > w then
            lines[#lines + 1] = line
            line, used = {}, 0
        end
        line[#line + 1] = c
        used = used + ew
    end
    if #line > 0 then lines[#lines + 1] = line end
    return lines
end

-- How the legend falls into lines at this width, as a list of lines. Nine
-- words and their swatches do not fit across every board, and one that ran off
-- the edge would take the last of them with it, which are the ones nothing
-- else on the page explains.
--
-- Filled to the edge and then wrapped, the ninth word sits alone under a full
-- line and reads as a mistake, so the lines are evened out instead: pack to
-- the share each line would carry, then let that share grow until it fits
-- back into the number of lines the width allows.
local function legend_lines(w, lsize)
    local want = #pack_legend(w, lsize)
    if want < 2 then return pack_legend(w, lsize) end
    local total = 0
    for _, c in ipairs(BOARD_CATS) do
        total = total + entry_w(c.word, lsize)
    end
    local try = total / want
    while try < w do
        local lines = pack_legend(try, lsize)
        if #lines <= want then return lines end
        try = try * 1.04
    end
    return pack_legend(w, lsize)
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

    -- The legend, laid out where it was measured: same call, same answer, so
    -- a page sized for two lines cannot be drawn with three.
    local lsize = legend_size(kh)
    local sw = lsize * 0.7
    local ly = top + 5 * pitch + 10 * S
    for _, line in ipairs(legend_lines(w, lsize)) do
        local lx = x
        for _, c in ipairs(line) do
            local col = board_col(c.key)
            rect(lx, ly + lsize * 0.2, sw, sw, pal.a(col, 0.9))
            txt(c.word, lx + sw + 6 * S, ly + lsize / 2, lsize,
                pal.a(pal.DIM, 0.95))
            lx = lx + entry_w(c.word, lsize)
        end
        ly = ly + lsize + LEG_GAP * S
    end

    return (ly - top) + 2 * S
end

-- What the board will ask for, so the panel can be sized before drawing it.
-- Every term here is one the drawing uses, in the same order it uses them:
-- five key rows, the gap to the legend, and however many lines the legend
-- falls into at this width.
local function board_height(w)
    local kh = (w / BOARD_UNITS) * 0.82
    local lsize = legend_size(kh)
    return 5 * (kh + 3 * S) + 10 * S
        + #legend_lines(w, lsize) * (lsize + LEG_GAP * S) + 2 * S
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
--   wide      rail down the left with its labels, stage beside it
--   narrow    stage above, rail along the bottom where the thumbs are
--
-- The five inputs are unchanged, and so are the sounds: up and down move,
-- right or enter goes in, left or escape comes back. A pointer may land on
-- either half, which is the one thing the keyboard cannot do and the reason
-- the stage publishes its own hit boxes. Resting on a row is the other: it
-- lights, because it moves the same cursor the arrows move.

local MENU_FONT = "menu"

-- How far under the top of the block the stage's first row sits: the rule
-- that introduces the list, and the way out sitting over it. The rail starts
-- there too, so a mark is level with the row it would open rather than with
-- the middle of the list.
local STAGE_TOP = 30

-- The strip down the left of the stage that the type does not enter. The mark
-- on the row you are already in sits there, off the column rather than in it,
-- and it is what gives a lit row its left margin.
local GUTTER = 22

-- --- marks -----------------------------------------------------------------
--
-- Every destination gets a drawing rather than a word, in the same strokes
-- the hulls and the walls are made of: thin lines, chamfered corners, a
-- little fill where something is solid. They are drawn at a radius so the
-- rail can size them, and they are the only place in this interface where a
-- shape has to carry a meaning on its own -- so each one is a picture of the
-- thing it opens, not a symbol somebody has to learn.

local function mark_zones(cx, cy, r, col)
    -- A world with a ring around it. The stop opens the list of places there
    -- are to fly in, and in this game a place is a world.
    --
    -- Three marks came before it, each borrowed from somewhere that already
    -- owns the shape. A triangle is what every media player puts on the thing
    -- that starts a video, so it promised a button and led to a list. A cross
    -- in a box is what every interface draws on the control that makes a new
    -- one. Three linked dots is the mark for sharing a page.
    local body = r * 0.58
    -- The ring first and whole, with the world laid over it, so it passes
    -- behind rather than through.
    local a, b = r * 1.06, r * 0.34
    local ca, sa = math.cos(-0.34), math.sin(-0.34)
    local pts = {}
    for i = 0, 23 do
        local t = i / 24 * math.pi * 2
        local ex, ey = a * math.cos(t), b * math.sin(t)
        pts[#pts + 1] = cx + ex * ca - ey * sa
        pts[#pts + 1] = ry(cy + ex * sa + ey * ca)
    end
    u:outline(pts, 1.1 * S, pal.a(col, 0.8), true)
    -- Dark in the body and lit at the rim, which is how everything solid in
    -- this game is drawn, from a wall face to a hull.
    u:disc(cx, ry(cy), body, 18, pal.a(pal.BG, 0.94))
    u:ring(cx, ry(cy), body, 1.3 * S, 20, col)
end

local function mark_pilot(cx, cy, r, col)
    -- The same helmet the games list counts people with, so the stop a player
    -- opens to change their call sign wears the mark that stands for them
    -- everywhere else.
    pilot_mark(cx, cy, col, r * 1.6)
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

local MARKS = {zones = mark_zones, pilot = mark_pilot, team = mark_team,
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
        bot_mark(right - text_w(tostring(bots), 12 * S) - 16 * S, y,
                 pal.a(pal.DIM, 0.75))
        right = right - text_w(tostring(bots), 12 * S) - 26 * S
    end
    local pc = players > 0 and col or pal.a(pal.DIM, 0.8)
    txt(tostring(players), right, y, 13 * S, pc, "right")
    -- A helmet rather than the plain dot this used to draw. The dot said
    -- "some number of somethings" and left the row's two counts looking like
    -- a bullet and a picture; the pair is one shell now, and which of them a
    -- player is looking at is the face in it.
    pilot_mark(right - text_w(tostring(players), 13 * S) - 12 * S, y, pc)
end

-- The dial that says something is being looked for, at whatever size it is
-- handed: the page's own when the list has nothing in it at all, and a row's
-- when the list has the zone but nothing is serving it. Everything about it is
-- measured off its radius, so the small one is the large one rather than a
-- second drawing that has to be kept in step with it.
--
-- Nothing else in this interface turns for the sake of turning, and this is
-- telling the truth while it does: the directory is asked again every few
-- seconds, and a zone with nobody running it is one an arena can come back to.
local function sweep_dial(cx, cy, r)
    local ring = math.max(0.8 * S, r * 0.022)
    -- Three range rings where there is room for three. A dial the height of a
    -- row has twenty points across it, and three rings in that are five points
    -- apart, which is closer than the stroke drawing them: they close up into
    -- a disc with a fringe. Two rings at that size is the same instrument,
    -- read at the distance it is actually being read from.
    local rings = (r > 24 * S) and {0.42, 0.72, 1.0} or {0.55, 1.0}
    local sides = math.max(18, math.min(30, math.floor(r / S)))
    for k, f in ipairs(rings) do
        u:ring(cx, ry(cy), r * f, ring, sides,
               pal.a(pal.RADAR_TILE, 0.55 - k * 0.12))
    end
    local ang = -M.now * 0.8
    -- How much of the circle the tail covers. Fewer strokes on the small dial:
    -- the same half radian of them, on something twenty points across, is a
    -- quarter of the face filled in, and a sweep that wide is a pie chart.
    local tail = (r > 24 * S) and 10 or 5
    for k = 0, tail - 1 do
        -- The trail is behind it, which for a sweep going round the way a
        -- dial's hand goes is the side it has just left.
        local a = ang + k * 0.05
        local f = 1 - k / tail
        u:seg(cx, ry(cy), cx + math.cos(a) * r * 0.98,
              ry(cy - math.sin(a) * r * 0.98), math.max(1.0 * S, r * 0.028),
              pal.a(pal.FRIEND, 0.32 * f * f), true)
    end
    u:disc(cx, ry(cy), math.max(1.2 * S, r * 0.05), 10, pal.a(pal.DIM, 0.9))
end

-- One row of the stage: a mark for the one you are on, the name, and
-- whatever the row has to say about itself on the right.
--
-- `hot` is the cursor, from either hand: the row the arrows are on while the
-- stage has them, or the row a pointer is resting on.
local function stage_row(x, y, w, h, r, hot)
    local col = r.mark and pal.FRIEND or pal.INK
    -- The cursor is a field of team blue across the row, and only that. It
    -- was a field with a chamfered bracket drawn around it, which is two
    -- marks saying one thing, and the corners cut the row into a box in a
    -- panel that has no boxes anywhere else in it.
    if hot then rect(x, y, w, h, pal.a(pal.FRIEND, 0.16)) end
    -- One text column, whatever the row is, and it is the column the title
    -- above the list is set in. The wedge that says "this is the one you are
    -- already on" lives in the gutter to the left of that column, off the type
    -- entirely: drawn inline it pushed its own label right of every other
    -- label, so the one row worth finding was the one out of line.
    local tx = x + GUTTER * S
    if r.mark then
        -- A lit wedge, the same one the corner stack uses to say a slot is
        -- the ready one.
        u:tri(x + 7 * S, ry(y + h / 2 - 4.5 * S), x + 14 * S, ry(y + h / 2),
              x + 7 * S, ry(y + h / 2 + 4.5 * S), pal.FRIEND)
    end
    local sel = hot or r.mark
    -- A row nothing is serving is a place that exists and cannot be flown to
    -- yet, so it is written a shade back from the ones that can.
    if r.waiting then col = pal.a(col, 0.6) end
    local size = (M.compact and 17 or 18) * S
    -- A row carrying a sentence of its own gives it the lower half and takes
    -- the upper for everything else. The games are the list that wants it:
    -- choosing between three of them is reading three sentences, and one at a
    -- time at the foot of the panel, a screen away from the name it belongs
    -- to, is not reading them.
    local ly = r.note and (y + h * 0.36) or (y + h / 2)
    -- Drawn here unless the detail turns out not to fit beside it, in which
    -- case the pair is laid out as two lines below and this one is skipped.
    local two_line = r.detail and r.detail ~= "" and not r.players
        and not r.choice and not r.note
        and text_w(r.detail, 12 * S) > w - 32 * S - (tx - x) - 12 * S
    if not two_line then
        txt(r.label or "", tx, ly, size,
            pal.a(col, sel and 1 or 0.82), nil, MENU_FONT, r.named)
    end
    if r.note then
        txt(r.note, tx, y + h * 0.68, 11.5 * S,
            pal.a(pal.DIM, (hot and 1 or 0.75) * (r.waiting and 0.7 or 1)))
    end
    -- The right hand side is data, so it stays in the face the numbers in
    -- flight are set in: a call sign, a count, a hull's name.
    if r.waiting then
        -- No count, because there is nothing to count. The instrument that
        -- looks for a game says what the words did, in the room the numbers
        -- would have taken, and it keeps saying it while the list refreshes
        -- underneath: an arena can come back and this row is where it lands.
        sweep_dial(x + w - 16 * S - 11 * S, ly, 11 * S)
    elseif r.players and r.live then
        population(x + w - 16 * S, ly, r.players, r.bots,
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
                pal.a(col, sel and 1 or 0.82), nil, MENU_FONT, r.named)
            txt(r.detail, tx, y + h * 0.70, 11 * S, pal.a(pal.DIM, 0.9),
                nil, nil, r.verbatim)
        else
            txt(r.detail, x + w - 16 * S, ly, 12 * S,
                pal.a(r.mark and pal.FRIEND or pal.DIM, 0.95), "right",
                nil, r.verbatim)
        end
    end
end

-- What the games page draws when it has no games: the instrument that looks
-- for them, with nothing on it.
--
-- The page is a list of places, so an empty one is a dial with no blips. Three
-- range rings and a sweep going round say the client is still asking, which it
-- is, every few seconds until something answers, and that nothing has. A line
-- of type alone at the top of an empty panel said as much and read as a
-- failure the player had caused and would have to do something about.
--
-- The heading is what happened, the line under it is what happens next, and
-- the address under that is for whoever is running this rather than whoever is
-- playing, which is why it is set small and dim.
local function empty_state(x, y, w, h, e)
    local cx = x + w / 2
    local r = math.max(22 * S, math.min(56 * S, h * 0.26))
    -- Centred in whatever room is left rather than hung off the top of it: on
    -- an empty page there is nothing above to hang from.
    local blockh = 2 * r + 96 * S
    local cy = y + math.max(0, (h - blockh) / 2) + r + 8 * S
    sweep_dial(cx, cy, r)
    local ty = cy + r + 30 * S
    txt(e.head or "", cx, ty, (M.compact and 17 or 19) * S,
        pal.a(pal.INK, 0.85), "center", MENU_FONT)
    if e.line and e.line ~= "" then
        txt(e.line, cx, ty + 24 * S, 12 * S, pal.a(pal.DIM, 0.95), "center")
    end
    if e.at and e.at ~= "" then
        txt(e.at, cx, ty + 46 * S, 11 * S, pal.a(pal.DIM, 0.45), "center",
            nil, true)
    end
end

-- Twelve slots for a key, filled left to right, the next one lit. Drawn as
-- rules rather than boxes: a row of empty boxes reads as a form, and this
-- interface has no forms in it.
local function key_slots(cx, y, typed, n)
    local sw, gap, group = 20 * S, 4 * S, 12 * S
    local total = n * sw + (n - 1) * gap + 2 * (group - gap)
    local x = cx - total / 2
    for i = 1, n do
        local ch = string.sub(typed, i, i)
        local here = (i == #typed + 1)
        local col = (ch ~= "" or here) and pal.FRIEND or pal.DIM
        if here then rect(x, y, sw, 26 * S, pal.a(pal.FRIEND, 0.16)) end
        u:seg(x, ry(y + 26 * S), x + sw, ry(y + 26 * S), 1.2 * S,
              pal.a(col, here and 0.95 or (ch ~= "" and 0.6 or 0.35)), true)
        if ch ~= "" then
            txt(ch, x + sw / 2, y + 13 * S, 16 * S, pal.FRIEND, "center",
                nil, true)
        end
        x = x + sw + gap
        -- Four to a group, which is how the key is written wherever it is
        -- shown, so what is typed looks like what is being copied.
        if i % 4 == 0 then x = x + group - gap end
    end
    return 26 * S
end

-- The alphabet, for a machine with no keyboard to raise. Every cell is a tap
-- target, and the last one rubs a character out: a thumb needs somewhere to
-- put a mistake.
local function key_grid(cx, y, alphabet)
    -- Eleven across, which is the one width where the alphabet and the cell
    -- that rubs a character out come to exactly three rows: thirty two letters
    -- laid out eight to a row leave the thirty third alone on a row of its
    -- own, under the answers, looking like a typo.
    local cols, cw, chh, gap = 11, 28 * S, 26 * S, 3 * S
    local total = cols * cw + (cols - 1) * gap
    local x0 = cx - total / 2
    local n = #alphabet
    for i = 1, n + 1 do
        local ch = (i <= n) and string.sub(alphabet, i, i) or "<"
        local r0 = math.floor((i - 1) / cols)
        local c0 = (i - 1) % cols
        local x = x0 + c0 * (cw + gap)
        local yy = y + r0 * (chh + gap)
        txt(ch, x + cw / 2, yy + chh / 2, 14 * S, pal.a(pal.DIM, 0.85),
            "center", nil, true)
        if i <= n then
            hit(x, yy, cw, chh, "letter", ch)
        else
            hit(x, yy, cw, chh, "rub")
        end
    end
    return math.ceil((n + 1) / cols) * (chh + gap) - gap
end

-- A question the menu wants answered before anything else, over the page that
-- asked it.
--
-- The panel stays where it is and stands down: the answer is about the row the
-- cursor is on, and losing sight of that row to answer for it is how the wrong
-- game gets left. Standing down is a wash for the shapes and a tenth of the
-- alpha for the type, since glyphs come from the gui and draw over every mesh,
-- so a label is quieted where it is written or not at all.
--
-- One line, one face, and the answers underneath as the keys the corner of the
-- screen already wears. The line under the heading used to read "leave it and
-- go back to the home screen?", which is the answers written out as a
-- sentence: a card that asks twice is a card somebody reads twice.
local function ask_card(x, y, w, h, a)
    rect(0, 0, W, H, pal.a(pal.BG, 0.62))
    -- Nothing behind this is listening, and hit boxes are first come first
    -- served, so the ones already published go: a tap on the rail or on a row
    -- under the wash would otherwise answer a question it cannot see.
    M.hits = {}
    text_dim = 1
    local grid = a.entry and M.touching
    local cw = math.min((a.entry and 380 or 340) * S, w - 24 * S)
    -- A card with a code in it is taller by the line the code takes, and one
    -- being typed into is taller by its slots and whatever fills them.
    local ch = (a.code and 152 or 110) * S
    if a.entry then ch = (grid and 248 or 152) * S end
    local cx = x + (w - cw) / 2
    local cy = y + (h - ch) / 2
    rect(cx, cy, cw, ch, pal.a(pal.BTN_BG, 0.98))
    u:frame(cx, ry(cy, ch), cw, ch, 1.1 * S, pal.a(pal.BORDER, 1))
    local mid = cx + cw / 2
    txt(a.head or "", mid, cy + 36 * S, (M.compact and 15 or 16) * S,
        pal.a(pal.INK, 0.95), "center", MENU_FONT)
    -- What the question is about, when it is about a string rather than a
    -- choice: big enough to read off one machine and type into another,
    -- quoted rather than said, and lit, because it is the one thing on the
    -- card anybody has to get right.
    if a.code then
        txt(a.code, mid, cy + 72 * S, 30 * S, pal.FRIEND, "center", nil, true)
    end
    if a.entry then
        local ey = cy + 58 * S
        local eh = key_slots(mid, ey, a.entry.typed or "", a.entry.n or 12)
        -- The alphabet only where there is no keyboard to raise. On a desktop
        -- the keyboard is the input and a drawn one would be a picture of the
        -- thing under the player's hands.
        if grid then
            key_grid(mid, ey + eh + 16 * S, a.entry.alphabet or "")
        end
    end
    -- Laid out from the middle out rather than from an edge in, so the row of
    -- answers stays centred whatever the words are.
    local ws, total = {}, 0
    for i, k in ipairs(a.keys) do
        ws[i] = key_w(k.label)
        total = total + ws[i]
    end
    total = total + KEY_GAP * S * (#a.keys - 1)
    local kx = mid - total / 2
    local ky = cy + ch - 22 * S - KEY_H * S
    for i, k in ipairs(a.keys) do
        key_cap(kx, ky, ws[i], k.label, i == a.sel)
        hit(kx, ky, ws[i], KEY_H * S, "answer", i)
        kx = kx + ws[i] + KEY_GAP * S
    end
end

-- The hulls, as hulls. A list of eight names is eight words about drawings
-- the game already owns, and picking a ship from a menu that shows you the
-- ships is the one page that does not need reading at all.
local function ship_grid(x, y, w, h, v, focused)
    local n = #v.rows
    if n == 0 then return end
    local cols = (w / S >= 420) and 4 or 2
    -- How wide the grid came out, for whoever has to move a cursor around it.
    -- The arrows mean a column and a row, and only the drawing knows how many
    -- columns a window of this width got.
    M.stage_cols = cols
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
        local hot = (focused and i == v.sel) or i == v.hover
        local col = r.mark and pal.FRIEND or pal.INK
        -- The hull you are flying keeps a wash of its own, so a cursor moved
        -- off it does not take the answer to "which one am I in" with it.
        if r.mark then
            rect(x + c * cw + 4 * S, y + rr * ch + 2 * S, cw - 8 * S,
                 ch - 4 * S, pal.a(pal.FRIEND, 0.07))
        end
        if hot then
            rect(x + c * cw + 4 * S, y + rr * ch + 2 * S, cw - 8 * S,
                 ch - 4 * S, pal.a(pal.FRIEND, 0.14))
        end
        -- The hull, its name and its trade, held clear of the bottom of the
        -- lit cell. The role used to sit on that edge, its descenders over the
        -- line, so a selected ship read as type in a box a size too small for
        -- it.
        -- The one under the cursor turns, and nothing else on the page does.
        -- Eight hulls all revolving is a screensaver; one of them turning is
        -- the one you are looking at, answering.
        -- A cell about a hull draws the hull. The one that is about not having
        -- one draws the pilot instead, at the size the helmet reads at rather
        -- than at the hull's, since the two figures are built to different
        -- scales and matching their boxes would shrink the helmet to a dot.
        if r.figure == "pilot" then
            pilot_mark(cx, cy - ch * 0.17,
                       pal.a(col, (hot or r.mark) and 1 or 0.7), ch * 0.30)
        else
            thumb(cx, cy - ch * 0.17, r.hull or 0,
                  pal.a(col, (hot or r.mark) and 1 or 0.7), ch / 116,
                  hot and M.now * 1.7 or nil)
        end
        txt(r.label or "", cx, cy + ch * 0.20, (M.compact and 14 or 15) * S,
            pal.a(col, (hot or r.mark) and 1 or 0.8), "center", MENU_FONT)
        if r.role then
            txt(r.role, cx, cy + ch * 0.34, 10 * S, pal.a(pal.DIM, 0.9),
                "center")
        end
        hit(x + c * cw, y + rr * ch, cw, ch, "stage", i)
    end
end

-- The mark: two hulls passing, each nose a little past the other's tail.
--
-- The same drawing the page carries as its icon, and drawn here rather than
-- imported, because the interface has no way to put a picture on screen and
-- would not want one: everything else here is strokes into a mesh layer, and
-- a mark that arrived as pixels would be the only thing in the client that
-- could not be drawn at any size.
--
-- The silhouette is the simulation's own. `hull_extent` in sim/src/baseline.c
-- gives the Apex 20 forward, 11 back and 10 to a side, with the tail cut flat
-- rather than pointed, so the shape in the tab is the shape people fly.
--
-- What makes it ours is the arrangement rather than the ship. Two hulls at
-- rest, symmetric about a point, is the swap glyph every icon set already
-- has; two hulls passing on a course off the vertical is a moment out of the
-- game, and nothing in a tab bar looks like it. The angle is off the diagonal
-- the tile's own chamfer cuts, on purpose: at forty five the tails lined up
-- with the corners and the pair read as a shape fitted to its box.
local LOGO_FORE, LOGO_AFT, LOGO_HALF = 20, 11, 10
local LOGO_SHIP = {
    {0, -LOGO_FORE}, {LOGO_HALF, LOGO_AFT * 0.72}, {LOGO_HALF * 0.48, LOGO_AFT},
    {-LOGO_HALF * 0.48, LOGO_AFT}, {-LOGO_HALF, LOGO_AFT * 0.72},
}
-- Tilt off vertical, how far apart the two fly, and how far each nose reaches
-- past the other's tail. All three in hull units, so the mark scales by one
-- number.
local LOGO_TILT = -35 * math.pi / 180
local LOGO_SEP, LOGO_PASS = 21, 8

local function logo_hull(cx, cy, ang, s, col, w)
    local ca, sa = math.cos(ang), math.sin(ang)
    local pts = {}
    for _, p in ipairs(LOGO_SHIP) do
        local x, y = p[1] * s, p[2] * s
        pts[#pts + 1] = cx + x * ca - y * sa
        pts[#pts + 1] = ry(cy + x * sa + y * ca)
    end
    u:outline(pts, w, col, true)
end

-- `s` is one hull unit, so the pair stands about 31 of them long.
function M.logo(cx, cy, s, alpha)
    alpha = alpha or 1
    local along = (LOGO_FORE - LOGO_AFT - LOGO_PASS) / 2
    local ux, uy = math.sin(LOGO_TILT), -math.cos(LOGO_TILT)
    local px, py = math.cos(LOGO_TILT), math.sin(LOGO_TILT)
    -- Against the hull unit, so the weight travels with the mark rather than
    -- with the window. It used to be a tenth of this and the floor underneath
    -- did all the work, which meant the mark drew a hairline at every size it
    -- was ever asked for and got thinner the smaller it was set. The floor is
    -- still here for the sizes where a stroke under a pixel disappears.
    local w = math.max(1.2 * S, s * 1.1)
    logo_hull(cx - px * LOGO_SEP / 2 * s - ux * along * s,
              cy - py * LOGO_SEP / 2 * s - uy * along * s,
              LOGO_TILT, s, pal.a(pal.FRIEND, alpha), w)
    logo_hull(cx + px * LOGO_SEP / 2 * s + ux * along * s,
              cy + py * LOGO_SEP / 2 * s + uy * along * s,
              LOGO_TILT + math.pi, s, pal.a(pal.ENEMY, alpha), w)
end

-- The mark and the name, and nothing under them.
--
-- Not a logotype: the same face the menu is set in, at a size nothing else on
-- screen is, with the drawn mark beside it. A stroke ran under the pair for a
-- while, a wake that swelled and faded across the width of the panel. It was
-- decoration in an interface that has none anywhere else, and every shape of
-- it that was tried, swelling from both ends and then solid into a tail, read
-- as a rule somebody had left there rather than as part of the name.
-- How tall the mark stands and how much room it wants, both against the type
-- it sits beside. The pair measures 37.3 hull units from the highest nose to
-- the lowest tail (see LOGO_SHIP and the two offsets in M.logo), so a height
-- asked for in ems converts to one hull unit by dividing by that.
--
-- 0.74 em is a shade over the cap height of the face the name is set in. The
-- mark reads as belonging to the word at that size, and as a picture beside a
-- caption above it: the first draft stood a full em and a bit tall and lifted
-- itself a third of an em besides, which put its weight above the line the
-- word sits on and made the lockup look assembled by accident.
-- And how far below the line the mark sits.
--
-- Not zero, which is what "centred" would suggest and what this had. `txt`
-- centres a string in its line box, and a line box has room under the
-- baseline for descenders. "vectorwake" is all lowercase and has none, so its
-- ink stops at the baseline and its weight sits lower still, in the x-height
-- band: measured off a screenshot, the type runs from 143 to 171 with the
-- x-height starting at 151, which puts what the eye reads as the middle of
-- the word about an eighth of an em below the middle of the box it is set in.
-- A mark hung on the box centre is a mark that looks high, which is what it
-- looked.
local LOGO_EM, LOGO_SPAN, LOGO_DROP = 0.74, 37.31, 0.12

local function wordmark(x, y, size)
    -- The mark stands to the left of the name, on the middle of the word
    -- rather than the middle of its line box, so the two read as one lockup.
    -- It takes the room it needs and the name starts after it.
    local s = size * LOGO_EM / LOGO_SPAN
    local lw = size * 0.95
    M.logo(x + lw / 2, y + size * LOGO_DROP, s)
    txt("vectorwake", x + lw, y, size, pal.INK, nil, MENU_FONT, true)
end

-- --- the whole thing -------------------------------------------------------

function M.menu(v)
    case = "sentence"

    -- A question takes the keys off whatever asked it, and the panel says so
    -- by standing down. It has to be set before a word of it is written: a
    -- glyph carries the alpha it was queued with, and the gui draws it over
    -- every mesh whatever is laid on top afterwards.
    text_dim = v.ask and 0.1 or 1
    local pts_w, pts_h = W / S, H / S
    -- One rule about the window, three layouts. 620 points is where a rail
    -- with its labels and a stage worth reading stop fitting side by side;
    -- 430 is where the name set large over it stops having the room.
    local narrow = pts_w < 620
    local tall = pts_h >= 430
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
    -- Room over the block for the name, wherever the menu is. It was kept for
    -- the home screen alone, so the same menu opened mid-fight opened without
    -- the one thing on it that says what this is.
    local head = (narrow and 54 or 76) * S

    local rx, ry_, rw, rh          -- the rail
    local sx, sy, sw, sh           -- the stage
    local vertical = not narrow

    if vertical then
        local total = math.min(W - SL - SR - 2 * margin, 940 * S)
        local x0 = SL + (W - SL - SR - total) / 2
        -- Clear of what the ship is carrying. Over a game the corner stack
        -- holds the left edge, and on a phone held sideways a centred block
        -- lands right on it: the rail's marks and the words GUN and BOMB in
        -- the same column read as one broken thing. The stack stays, because
        -- what you are carrying is worth knowing while you pick a hull.
        if not home then
            x0 = math.max(x0, SL + 124 * S)
            -- And give back what moving right took: the block is as wide as
            -- the room left of the far margin, or it hangs off the edge of
            -- the screen carrying the end of the keyboard with it.
            total = math.min(total, W - SR - x0 - margin)
        end
        -- Wide enough for the words, at any height. A rail of marks alone
        -- was the short window's layout, on the argument that eight labelled
        -- stops do not fit a phone held sideways; they fit, and with no title
        -- over the stage the lit word is the only thing on screen that says
        -- which page this is.
        rw = 150 * S
        local pitch = math.min(math.max((H - head - 3 * margin) / n,
                                        38 * S), 58 * S)
        rh = pitch * n
        -- The rail hangs from the top of the block, starting where the stage's
        -- first row starts. Centred in the block instead, six stops in a tall
        -- window sat opposite the middle of a three-row list with the whole
        -- top of the panel empty above them, and the two halves read as two
        -- panels that had been put side by side by accident.
        local block = math.max(rh + STAGE_TOP * S,
                               math.min(H - head - 2 * margin, 470 * S))
        local top = math.max(margin, (H - block - head) / 2) + head
        rx, ry_ = x0, top + STAGE_TOP * S
        sx = x0 + rw + 26 * S
        sy, sh = top, block
        sw = total - rw - 26 * S
        wordmark(x0, top - head + 30 * S, (tall and 40 or 30) * S)
        -- What you are reading, laid over what you are not. A wash rather
        -- than a panel: no border, no corners, just enough that the type sits
        -- on something and the arena stays visible round the edges of it.
        rect(x0 - 18 * S, top - 16 * S, total + 36 * S, block + 30 * S,
             pal.rgb(0x03050a, 0.5))
        -- The rule the whole thing hangs off, between the rail and the stage.
        vrule(x0 + rw + 1 * S, top, block, pal.a(pal.RADAR_TILE, 0.75), 30 * S)
    else
        rh = (home and 78 or 84) * S
        rw = W - SL - SR - 2 * margin
        rx = SL + margin
        ry_ = H - margin - rh
        sx, sw = SL + margin, rw
        -- Under the chip row over a game: MENU and PLAYERS hold the top left
        -- corner while the arena is live, and the name drawn into them is two
        -- things in one place.
        local chip = home and 0 or 34 * S
        sy = ST + margin + head + chip
        sh = ry_ - 20 * S - sy
        rect(0, sy - 16 * S, W, sh + rh + 46 * S, pal.rgb(0x03050a, 0.5))
        wordmark(rx, ST + margin + chip + 22 * S, 30 * S)
        u:seg(rx, ry(ry_ - 12 * S), W - SR - margin, ry(ry_ - 12 * S),
              1.0 * S, pal.a(pal.RADAR_TILE, 0.6), true)
    end

    -- Which half the arrows are in. The two halves share one cursor and mark
    -- it with the same blue field, so the half wearing the brighter one is the
    -- answer to "what does up do here" without a word spent on saying it.
    local focused = (v.focus == "stage")

    -- --- the rail
    local pitch = vertical and (rh / n) or (rw / n)
    -- Along the bottom, every stop says its name, and the words are sized so
    -- the longest of them fits the room one stop has. Only the lit one used to
    -- carry a word, because "settings" and "about" at the desktop's size run
    -- into each other with eight of them across a phone; a row of marks you
    -- have to learn by tapping is worse than a row of small words.
    local label_px = 11 * S
    if not vertical then
        local longest = 0
        for _, e in ipairs(rail) do
            longest = math.max(longest, #(e.label or ""))
        end
        if longest > 0 then
            label_px = math.max(8 * S, math.min(label_px,
                                (pitch - 5 * S) / (longest * ADVANCE)))
        end
    end
    for i, e in ipairs(rail) do
        local sel = (i == v.rail_sel)
        local cx, cy
        if vertical then
            cx = rx + 26 * S
            cy = ry_ + (i - 0.5) * pitch
        else
            cx = rx + (i - 0.5) * pitch
            cy = ry_ + (home and 30 or 32) * S
        end
        local col = sel and pal.FRIEND or pal.a(pal.DIM, 0.9)
        local r = 13 * S
        if sel then
            -- The lit one, and a rule reaching from it toward the stage, so
            -- the eye is told which mark the panel belongs to rather than
            -- having to work it out from a highlight. Brighter while the
            -- arrows are in the rail, down to the weight the stop keeps for
            -- saying where you are once they have gone into the page.
            local lit = pal.a(pal.FRIEND, focused and 0.06 or 0.22)
            local bar = pal.a(pal.FRIEND, focused and 0.5 or 1)
            if vertical then
                rect(rx - 6 * S, cy - pitch / 2 + 3 * S,
                     rw + 6 * S, pitch - 6 * S, lit)
                u:seg(rx - 6 * S, ry(cy - pitch / 2 + 3 * S), rx - 6 * S,
                      ry(cy + pitch / 2 - 3 * S), 1.6 * S, bar, true)
            else
                -- The field alone. It wore a lit bar along its top edge as
                -- well, which is the vertical rail's own mark turned on its
                -- side: there it points at the stage beside it, and here it
                -- points at nothing and reads as a tab that has come loose.
                rect(cx - pitch / 2 + 3 * S, ry_, pitch - 6 * S, rh - 4 * S,
                     lit)
            end
        end
        draw_mark(e.icon, cx, cy, r, col, v.class or 0)
        if vertical then
            txt(e.label, rx + 48 * S, cy, 16 * S,
                pal.a(sel and pal.INK or pal.DIM, sel and 1 or 0.85),
                nil, MENU_FONT)
        elseif not vertical then
            txt(e.label, cx, cy + 24 * S, label_px,
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
    local listy = not (v.board and not M.touching)
        and not (v.rows and #v.rows > 0 and v.rows[1].hull)
    -- Everything with type in it hangs off `tx`, a gutter in from the stage's
    -- own left edge: the rule at the head of it, and every row's label. A
    -- row's field starts back at `sx`, so what is lit reaches under the mark
    -- and the words never sit against the edge of it.
    local tx = sx + GUTTER * S
    local avail = sw - GUTTER * S
    local lw = listy and math.min(avail, 520 * S) or avail
    -- No title over the stage. The rail is lit at the stop you are inside and
    -- says its name there, so a heading repeating it is the same answer
    -- written twice, in the one place a list of games could have used the
    -- room instead.
    --
    -- The way out, where a way out goes, and only where there is one: with
    -- nothing behind the panel the menu is the screen and cannot be shut.
    --
    -- The mark rather than a word. It said "back" from inside a page and
    -- "close" at the top, which is one control with two jobs and two names,
    -- and a rail that navigates from every level had already taken the going
    -- back. What is left is shutting the panel, and everything shuts on an x.
    if v.closable then
        close_mark(tx + lw - 8 * S, sy + 11 * S, pal.a(pal.DIM, 0.9), 11 * S)
        hit(tx + lw - 30 * S, sy, 40 * S, 24 * S, "close")
    end
    local top = sy + STAGE_TOP * S
    local room = sh - (top - sy) - 26 * S
    -- A list is capped: a row whose name sits at one edge and whose count
    -- sits at the other, a screen apart, is two columns nobody reads as one
    -- line. The board and the hull grid are drawings and take everything.
    --
    -- Nothing is drawn across the head of it. A ticked rule sat there, the
    -- one the map border is made of, introducing a list that needs no
    -- introducing: the rail says what the page is and the rows say what they
    -- are, and the rule was a third line of furniture between them.
    if v.board and not M.touching then
        -- The widest board the stage has the height for, backed off rather
        -- than solved, the same way the page used to do it.
        local bw = avail
        while bw > 240 * S and board_height(bw) > room do bw = bw * 0.94 end
        board(tx, top, bw)
    elseif v.rows and #v.rows > 0 and v.rows[1].hull then
        ship_grid(tx, top, avail, room, v, focused)
    else
        -- Two lines of room where the rows have two lines in them, held to
        -- one height either way so nothing shifts as the cursor walks down.
        local noted = false
        for _, r in ipairs(v.rows) do
            if r.note then noted = true break end
        end
        local rowh = math.min((noted and 58 or (M.compact and 46 or 40)) * S,
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
            -- The cursor, from whichever hand is on it. A pointer resting on
            -- a row of a page moves the cursor there rather than lighting a
            -- second row, so `hover` only ever arrives on the home screen,
            -- where the cursor belongs to the rail and the stage is a preview
            -- of what the mark beside it holds.
            stage_row(sx, y, GUTTER * S + lw, rowh, r,
                      (focused and i == v.sel) or i == v.hover)
            if r.pick then hit(sx, y, GUTTER * S + lw, rowh, "stage", i) end
        end
        -- What is off the ends, as the same tick the map border uses. It says
        -- there is more without spending a row on saying so.
        if #v.rows > fits then
            local bar = 3 * S
            local hgt = room * fits / #v.rows
            local at = room * (first - 1) / #v.rows
            rect(tx + lw + 8 * S, ty, bar, room, pal.a(pal.DIM, 0.18))
            rect(tx + lw + 8 * S, ty + at, bar, hgt, pal.a(pal.FRIEND, 0.6))
        end
        -- Under whatever rows there are, which over a game is the one row
        -- that leaves it.
        if v.empty then
            local ey = ty + used + 12 * S
            empty_state(sx, ey, GUTTER * S + lw, top + room - ey, v.empty)
        end
    end

    -- One line at the foot of the stage: why something did not work, or what
    -- the thing under the cursor is. Nothing when there is neither. It used to
    -- fall back to naming the keys, which is a caption on a rail whose whole
    -- argument is that a lit mark says where you are without one, and it was
    -- drawn on a phone that has none of those keys, under a list you get
    -- around by touching it.
    local foot = v.note or v.hint
    if foot then
        txt(foot, tx, sy + sh - 4 * S, 12 * S,
            pal.a(v.note and pal.HURT or pal.DIM, 0.95))
    end

    -- Last, over all of it, because it is the only thing being read.
    if v.ask then ask_card(sx, sy, GUTTER * S + lw, sh, v.ask) end
    case = "upper"
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
