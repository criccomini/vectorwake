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
-- Whether the rooms panel is down. Its key lives in the corner beside PLAYERS,
-- and like PLAYERS it opens a panel here rather than walking into the menu.
M.rooms_open = false
-- How far down the rooms list is scrolled. Its own, not the scoreboard's: the
-- two panels share a slot and never a position, so carrying one scroll between
-- them would open a five-room list halfway down.
M.room_scroll = 0
-- Which room has been pressed and is waiting to be told twice, by number.
--
-- Asked inline rather than by opening the menu's card, the way inviting a
-- pilot is asked inside the box that names them: the panel is a corner of the
-- screen and a question about a row belongs on the row. Opening the whole menu
-- to answer a press in a corner would also put the arena away, which is the
-- thing the press was trying not to do.
--
-- It is worth asking at all because a move is a reconnect and a reconnect is a
-- fresh spawn, so it costs a pilot everything they are carrying, and bounty
-- here is derived from holdings. One stray click in a corner should not empty
-- a hold.
M.room_ask = nil

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
-- instrument is labeled in. The menu is read rather than glanced at, and a
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
-- a caller can hand it a row's center without knowing the height.
--
-- HELM_NECK is how far below the center the collar cuts, in radii. Both
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

-- A person's shell: a closed flight helmet, a crown over a longer face, with
-- nothing under it.
--
-- Two superellipses sharing a waist, which is the widest line across it and
-- where the face keeps its eyes. FACE_CROWN is the share of the height above
-- that waist, so a small one is a long face. FACE_ROUND is how square the
-- crown turns and FACE_BLUNT how the chin ends: 2 turns through the bottom,
-- less draws it towards a point. FACE_IN is the width the face gives up on
-- its way down, which is the other half of a chin and has to move with
-- FACE_BLUNT, since a blunt end on a face that has already lost its width is
-- a stub rather than a jaw.
--
-- What this replaced was a bowl of glass on a collar, cut off flat at the
-- neck. Three things were wrong with it and only the last is obvious. A true
-- circle is as wide at the mouth as at the eyes and widest exactly halfway
-- down, which no helmet built for a cockpit is. The collar was a line wider
-- than the cut it stood on, so it read as shoulders under a fishbowl. And a
-- circle with a bar across it is a diagram of a face rather than a drawing of
-- one.
local FACE_WIDE, FACE_CROWN = 0.38, 0.38
local FACE_ROUND, FACE_BLUNT, FACE_IN = 2.1, 2.3, 0.22

local function helm(cx, cy, k, col, line)
    local w = k
    local h = w * HELM_TALL
    local x0, y0 = cx - w / 2, cy - h / 2
    line = line or pen(k, 0.11)
    local up, down = h * FACE_CROWN, h * (1 - FACE_CROWN)
    local waist = y0 + up
    local half = k * FACE_WIDE
    -- Half the shell's width at a height. Crown above the waist, face below.
    local function hw(y)
        local t = (y - waist) / (y < waist and up or down)
        t = math.max(-1, math.min(1, t))
        if t < 0 then
            return half * (1 - (-t) ^ FACE_ROUND) ^ (1 / FACE_ROUND)
        end
        return half * (1 - t ^ FACE_BLUNT) ^ (1 / FACE_BLUNT)
                    * (1 - FACE_IN * t)
    end
    -- One closed run, left side down and right side back up. Sampled rather
    -- than struck, because there is no one circle to strike it from.
    local pts, steps = {}, math.max(10, math.min(18, math.floor(k * 0.7)))
    for i = 0, steps do
        local y = y0 + h * i / steps
        pts[#pts + 1] = cx - hw(y)
        pts[#pts + 1] = ry(y)
    end
    for i = steps, 0, -1 do
        local y = y0 + h * i / steps
        pts[#pts + 1] = cx + hw(y)
        pts[#pts + 1] = ry(y)
    end
    u:outline(pts, line, col, true)
    return x0, y0, w, h, waist, hw
end

-- A machine's shell: the same envelope with the curve taken out of it.
--
-- Squared to the same width and the same neckline as the bowl, so the two sit
-- level in a row. Its crown is flat where the person's is domed, which is the
-- whole of the difference and all it needs to be.
--
-- Three sides and a collar rather than a closed outline. Closing it lays the
-- box's own base under the collar, and two lines of one color on one pixel
-- row is a brighter line wherever these marks draw at part alpha, which is
-- every nameplate in the arena.
--
-- The same reasoning decides the corners. A capped stroke runs half a width
-- past each end, so four capped sides overlap in four squares and light every
-- corner. The crown is capped and covers them; the sides butt into it and
-- into the collar, each drawing its own length and no more.
local function hull_helm(cx, cy, k, col, line)
    local w = k
    local h = w * HELM_TALL
    local x0, y0 = cx - w / 2, cy - h / 2
    local r = w * 0.5
    local mid = y0 + r
    local neck = mid + r * HELM_NECK
    line = line or pen(k, 0.11)
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

-- How high the visor sits over the waist and how far it sags under it, in
-- strokes, so the glass travels with the line rather than with the mark.
-- Against the mark it grew with the drawing, and wherever the mark went big
-- under a line held thin -- the rail -- the glass came out a slab in a column
-- of line work.
--
-- And a ceiling on both, against the mark's own height, because the trade runs
-- the other way at the other end. The pen is 0.13 of this mark's height at
-- eleven points and 0.07 of it in the rail, so a visor cut purely in strokes
-- is twice as deep in the games list as in the menu: it filled the shell and
-- left a helmet reading as a blob with a notch in it. The ceilings are set
-- clear of what the rail draws, so the size this shape was chosen at is the
-- one neither of them touches.
local VISOR_LIFT, VISOR_SAG = 1.5, 2.6
local VISOR_LIFT_MAX, VISOR_SAG_MAX = 0.11, 0.19

-- How far the top edge bends down at the middle, as a share of the mark's
-- height. Against the mark rather than against the stroke, because the stroke
-- is held to the column in the rail and a bend cut in strokes came to under a
-- pixel there: it was drawn and could not be seen.
local VISOR_BEND = 0.080

-- A person: the visor, wrapped into the shell.
--
-- Ruled along the top and sagging along the bottom, so it wraps the face
-- rather than lying across it, and it is deepest where it crosses the middle
-- of that face. It sits on the waist, which is the shell's own widest line
-- and where a face keeps its eyes.
--
-- Everything before it was a band: struck two ways to bow apart, or bent, or
-- ruled flat. All of them read as a line drawn on a face rather than as a
-- pane set into a helmet, because a band has two edges doing the same thing
-- and glass in a shell does not. Both of these edges bow the same way and by
-- different amounts, which is what a pane wrapped round a head does.
--
-- Its ends come off the shell's own width at that height, so a narrower head
-- gets a shorter visor. That is the trade in this mark: the visor is the
-- whole of it at 26 points, and every hundredth of width the head gives up
-- comes off the part being read.
local function pilot_mark(cx, cy, col, k, line)
    k = k or MARK_K * S
    line = line or pen(k, 0.11)
    local w, h, waist, hw = select(3, helm(cx, cy, k, col, line))
    local top = waist - math.min(line * VISOR_LIFT, h * VISOR_LIFT_MAX)
    local reach = hw(top) - line * 1.1
    local sag = math.min(line * VISOR_SAG, h * VISOR_SAG_MAX)
    local bend, floor = h * VISOR_BEND, cy + h / 2
    -- A strip, a quad between each pair of samples, walking the two edges
    -- together. One fan would be fewer triangles and was what this drew until
    -- the top edge learned to bend: a fan is struck from a single corner and
    -- is exact only over a convex shape, and a pane with a bend in its top is
    -- concave along that edge, so the fan filled the bend back in. The bend
    -- was drawn and then painted over, which looks exactly like never having
    -- been drawn.
    local px, pty, pby
    for i = 0, 10 do
        local t = -1 + 2 * i / 10
        local x = cx + reach * t
        local ty = top + bend * (1 - t * t)
        local by = math.min(waist + sag * (1 - t * t), floor - line)
        if px then
            u:quad(px, ry(pty), x, ry(ty), x, ry(by), px, ry(pby), col)
        end
        px, pty, pby = x, ty, by
    end
    return w
end

-- A machine: the boxed shell, two lamps, and the antenna over the crown.
--
-- `x` is its left edge rather than its center, because every caller of this
-- one is laying a row out left to right and knows where the mark starts.
--
-- Lamps rather than a visor, and a flat crown to stand them under. The
-- antenna says the same thing a second time, which is worth the two points it
-- costs: three of this mark's four uses are solo.
local function bot_mark(x, y, col, k, line)
    k = k or MARK_K * S
    local cx = x + k / 2
    local x0, y0, w, _, mid, r = hull_helm(cx, y, k, col, line)
    -- The middle of the box rather than the middle of the circle it used to
    -- be: a flat crown puts the room the dome was using back into the shell,
    -- and lamps left where they were sat in the bottom third of it.
    local eye = mid - r * 0.16
    u:disc(x0 + w * 0.31, ry(eye), w * 0.115, 8, col)
    u:disc(x0 + w * 0.69, ry(eye), w * 0.115, 8, col)
    u:seg(cx, ry(y0), cx, ry(y0 - r * 0.36), line or pen(k, 0.09), col, true)
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

-- --- frame -----------------------------------------------------------------

-- True when the screen is too narrow for the desktop layout: three columns of
-- 248 points plus their margins want about 640, and a phone in portrait has
-- 390. Below that the scoreboard and the radar were drawn straight through
-- each other and the hull grid ran off both edges of the screen.
M.compact = false
M.touching = false
-- Whether a card asking to be typed into should hand its lines to the page
-- as input elements. True in a browser and false everywhere else: a native
-- build has no page, and a card that stopped drawing its own lines there
-- would be a card being typed into invisibly. Set once, by the arena.
M.page_fields = false
-- The scoreboard and your loadout, off until asked for. A guess about screen
-- size decided this before and got it backwards on the device it was written
-- for; see M.begin.
M.details = false

-- Where each row of the corner stack, the dial and the feed landed this
-- frame, filed by each element as it draws itself.
--
-- Nothing on screen reads these. They exist so that the layout can be asked
-- where it put something instead of a test working the same arithmetic out a
-- second time, which is two places that then have to agree about one corner.
-- The rows wear glyphs rather than words, so the drawn text cannot say where
-- a row is and this is the only account of it there is.
--
-- Deliberately not `M.hits`. A hit box is a press: `on_input` takes the first
-- one a press lands in, and the field of play holds none at all because left
-- click is the gun and a box over a hull would eat the shot. See
-- hud_hits_test for the rule those are staying out of the way of.
local zones = {}
local function zone(key, x, y, w, h)
    zones[#zones + 1] = {key = key, x = x, y = y, w = w, h = h}
end

-- Which row covers this point, or nil. Last registered wins, so a row inside
-- a panel beats the panel: the corner stack files a zone per row.
function M.row_at(x, y)
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
-- of the phones.
--
-- The bottom is a special case, and it is two things at once. The pads and
-- the stick ignore it: the home indicator overlays them the way it overlays
-- every full-screen game's controls, and lifting the row bought nothing but
-- reach. The menu's rail does not ignore it, because a rail is a row of
-- buttons a thumb presses and the indicator is a bar the system swallows
-- presses under, which is what a tab bar steps over on every phone.
--
-- What arrives here is already net of whatever the canvas does not cover:
-- under a browser's bottom toolbar the strip is spoken for, and stepping up
-- by the inset as well would be stepping over the same thing twice.
--
-- `app` is whether the page was launched from a home screen rather than
-- opened in a tab, and it decides the one case the paragraph above does not
-- cover. In a tab the rail sits above the toolbar and there is nothing under
-- it; installed, the rail is the last thing before the edge of the screen and
-- the inset lifts it off that edge, which is the strip of black under the
-- buttons on a phone with no address bar. So installed, the rail stops
-- stepping over the indicator and runs to the edge the way the pads already
-- do. It costs the bottom third of a stop's surface to a bar the system may
-- swallow a press under, and buys back the ten points that made the row look
-- like it had come loose.
local SL, SR, ST, SB, SAPP = 0, 0, 0, 0, false
function M.safe(l, r, t, b, app)
    SL, SR, ST, SB = l or 0, r or 0, t or 0, b or 0
    SAPP = app and true or false
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
    S = density
    -- The marks draw into the same layer, and the pads reach for them after
    -- this returns, so they are handed it here rather than by each caller.
    marks.begin(layer, density)
    M.touching = touching or false
    text = state.text
    nt = 0
    u:reset()
    M.hits = {}
    zones = {}
    -- The lines the page is asked to hold, if any card raised this frame
    -- asks for typing. Cleared here rather than by whoever raised it, for
    -- the reason the hit list is: a card that is no longer drawn has no
    -- lines, and the way to say so is to stop saying otherwise.
    M.ask_dom = nil
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
-- the byte that belongs to no side, so an absent eye colors everybody
-- hostile the way a free-for-all already colors everyone who is not you.
local function team_of(i)
    if not i or i < 0 or i >= sim.ship_count() then return 255 end
    return sim.ship_team(i)
end

-- The side this screen belongs to, which is not always the side of the hull
-- it is centered on.
--
-- Flying they are the same and it never mattered. Watching they come apart:
-- the camera stands behind whoever the channel picked, and deriving "my team"
-- from that repainted your own side as hostile every time the camera crossed
-- the line, and told the info box that a teammate of the pilot you happen to
-- be watching is a teammate of yours. Set once per frame from what the zone
-- told this client its side is.
local view_team = 255

-- What color to write a side's name in.
--
-- Yours is cyan, always, whichever byte it happens to be: "mine" is a reading
-- a pilot makes before they read anything, and a side that changed color on
-- you when the zone shuffled the numbers would break it. Everybody else wears
-- the color their byte generates.
--
-- Only words go through this. Hulls, plates, rounds and the radar keep the two
-- colors, because those are glanced at and a glance holds one bit.
local function team_col(t)
    if t == view_team then return pal.FRIEND end
    return pal.team(t)
end

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
    -- edge that size covers two pixel centers at some sub-pixel offsets and
    -- three at others: four pixels of area against nine, a bit over twice the
    -- ink, flipping as the fraction rolls over. Every blip shares the fraction,
    -- because they are a regular grid under one affine map, so the whole map
    -- breathes at once and reads as the terrain blinking off and on.
    --
    -- Two things fix it and both are free. A whole number of pixels covers
    -- exactly that many centers wherever it starts, so the size stops
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
-- thousand times a frame: `pal.a` builds a color, and building four of them
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
-- across the shorter axis, centered on the camera -- so one number converts
-- between them and the two cannot drift.
-- Nothing here is clickable, deliberately. The left button is the gun and the
-- right one is the bomb, and a hit box publishes over both: a box on a hull,
-- or on the label beside it, would eat the trigger at the exact moment a
-- player is lined up on somebody. Asking who somebody is belongs to the
-- scoreboard, where a click is a click and nothing else.
-- What a kill paid, rising off the wreck.
--
-- Only ever your own. The number is a reward, and a reward somebody else
-- collected is not news worth putting over the fight; the feed already says
-- who took whom. It is raised from the zone's kill message rather than from
-- the local simulation, for the reason the feed line is: prediction kills the
-- same pilot once per rollback, and the zone announces each death exactly
-- once with what it paid.
--
-- Anchored in the world, so it drifts off the spot the hull died on rather
-- than off a point on the screen, and a player who is still moving watches it
-- fall behind them the way the wreck does.
local payouts = {}
local PAYOUT_LIFE = 1.4    -- seconds from the kill to gone
local PAYOUT_RISE = 26     -- points travelled in that time
local PAYOUT_HOLD = 0.25   -- the fraction of it spent at full strength

-- Raised by whoever drains the kills. World coordinates, because that is
-- where the wreck is.
function M.payout(x, y, n)
    payouts[#payouts + 1] = {x = x, y = y, n = n, t0 = M.now}
end

-- A new arena is not the one the last number was earned in. Cheap to call and
-- it costs nothing when there is nothing to drop.
function M.clear_payouts()
    for i = #payouts, 1, -1 do payouts[i] = nil end
end

local function nameplates(o)
    if not o.half_w or o.half_w <= 0 then return end
    -- The render script publishes its own half-extents for exactly this, so
    -- that nothing keeps a second copy of the projection. Deriving one from
    -- the view_tiles setting put every name adrift the moment the camera
    -- stopped being driven by that setting -- which it already had.
    local scale = W / (2 * o.half_w)
    -- The one hull that goes unlabeled is your own, and a watcher has none.
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
                -- The plate is where the sides come apart. The hull under it
                -- stays cyan or orange, which is the call a pilot makes at
                -- speed; the name says which orange, which is the call they
                -- make when they have a moment to read one. Three hulls
                -- converging is a different problem if they are one squad.
                local col = team_col(sim.ship_team(i))
                -- The bounty rides with the name, always. It is what killing
                -- them pays, so it is the one number that says which of two
                -- ships in front of you is worth the risk.
                local bty = sim.ship_bounty(i)
                do
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
                        -- In the side's color rather than the bounty gold,
                        -- so the name and the number under it read as one
                        -- label belonging to one squad. Gold said "this is a
                        -- bounty", which the position under a name already
                        -- says, and it said it identically for every pilot on
                        -- screen: the one thing a color here can carry is
                        -- whose they are.
                        txt(tostring(bty), sx + 12 * S, sy + 25 * S, 11 * S,
                            pal.a(col, 0.85))
                    end
                end
            end
        end
    end

    -- The payouts, drifting off the wrecks that paid them. Walked backwards
    -- into itself so an expired one is dropped in the same pass that draws
    -- the rest, and the list stays as short as the killing is fast.
    local live = 0
    for k = 1, #payouts do
        local p = payouts[k]
        local age = M.now - p.t0
        if age >= 0 and age < PAYOUT_LIFE then
            live = live + 1
            payouts[live] = p
            local f = age / PAYOUT_LIFE
            local px = W / 2 + (p.x - o.cam_x) * scale
            local py = H / 2 + (p.y - o.cam_y) * scale
            -- Full for the first quarter and then out. A number that starts
            -- fading on the frame it appears is one nobody finishes reading,
            -- and this one appears in the middle of the thing that earned it.
            local a = 1
            if f > PAYOUT_HOLD then
                a = 1 - (f - PAYOUT_HOLD) / (1 - PAYOUT_HOLD)
            end
            -- The bounty's own size and offset, in the green the feed already
            -- uses for a line about a kill of yours. Up is negative here: the
            -- name sits at +13 and the bounty at +25, under it.
            txt("+" .. p.n, px + 12 * S, py + 13 * S - PAYOUT_RISE * S * f,
                11 * S, pal.a(pal.PRIZE, 0.95 * a), nil, nil, true)
        end
    end
    for k = #payouts, live + 1, -1 do payouts[k] = nil end

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

-- The rooms of this zone, and the way into a different one.
--
-- Every room the zone is holding, across every arena server serving it, which
-- is why this is drawn from the directory's answer rather than from the arena
-- we are connected to: that process knows its own rooms and nothing about
-- anybody else's. A room on another server is a different address and joining
-- it is a reconnect, the same as changing game, and none of that is said here.
-- A player never sees an address, so a player never sees which process a room
-- belongs to either.
--
-- In the scoreboard's slot rather than beside it, and mutually exclusive with
-- it, because the left column has room for one panel and the top right corner
-- already works this way: it holds the radar or the map, never both.
local function rooms_panel(rooms, here)
    if not M.rooms_open or not rooms or #rooms == 0 then return 0 end
    local n = #rooms
    -- A zone may hold a hundred rooms, so this list is not bounded by anything
    -- the layout can assume. Clamped here rather than where the wheel is read,
    -- for the same reason the scoreboard clamps here: this is the only place
    -- that knows how many rooms there are, and a room is reclaimed the moment
    -- its last pilot leaves, which can happen while somebody is scrolled to
    -- the bottom of the list.
    local max_scroll = math.max(0, n - SHOWN)
    if M.room_scroll > max_scroll then M.room_scroll = max_scroll end
    if M.room_scroll < 0 then M.room_scroll = 0 end
    local shown = math.min(n, SHOWN)
    local w = COL_W * S
    local head = 24 * S
    local rowh = LINE * S
    local h = head + shown * rowh + 8 * S
    local x = SL + PAD * S
    local y = top_y()
    rect(x, y, w, h, pal.a(pal.BG, 0.62))
    vrule(x, y, h, pal.a(pal.RADAR_TILE, 0.7))
    txt("ROOMS", x + 12 * S, y + 15 * S, (FONT - 2) * S, pal.a(pal.INK, 0.75))
    -- The zone, once, at the head. The rows are numbers and a number needs
    -- saying what it is a number of; the corner chip has no space for it and
    -- this does.
    txt(M.zone_name or "", x + w - 12 * S, y + 15 * S, (FONT - 3) * S,
        pal.a(pal.DIM, 0.85), "right")
    for i = 1 + M.room_scroll, math.min(n, M.room_scroll + shown) do
        local rm = rooms[i]
        local ry0 = y + head + (i - 1 - M.room_scroll) * rowh
        local mid = ry0 + rowh / 2
        local mine = rm.n == here
        local col = pal.INK
        if rm.full and not mine then col = pal.a(pal.DIM, 0.75) end
        if mine then
            -- The one you are in, lit the way the scoreboard lights your own
            -- row: this list is mostly read to answer "where am I", and the
            -- answer should not need counting down the rows.
            wash(x + 1 * S, ry0, w - 2 * S, rowh, pal.a(pal.FRIEND, 0.13))
            col = pal.FRIEND
        end
        txt("ROOM " .. rm.n, x + 12 * S, mid, (FONT - 1) * S, col)
        population(x + w - 12 * S, mid, rm.players, rm.bots,
                   pal.a(mine and pal.FRIEND or pal.INK, 0.9))
        -- A full room is a row you can read and not a row you can press. The
        -- one you are in is the same: pressing it would be a disconnect and a
        -- handshake to arrive where you already are.
        if not rm.full and not mine then
            hit(x, ry0, w, rowh, "room", rm.n)
        end
    end
    -- Only when there is something to scroll to, as the scoreboard's is: a bar
    -- on a list that fits is a control that does nothing.
    if n > shown then
        local track = shown * rowh
        local ty = y + head
        local bar = math.max(10 * S, track * (shown / n))
        local at = (M.room_scroll / math.max(1, n - shown)) * (track - bar)
        u:seg(x + w - 3 * S, ry(ty + at), x + w - 3 * S, ry(ty + at + bar),
              2 * S, pal.a(pal.RADAR_TILE, 0.8))
    end
    -- The whole panel takes the wheel, rather than a strip beside it, which is
    -- how the scoreboard behaves: a list is the thing you point at when you
    -- mean to scroll it. Published after the rows so a row wins the press.
    hit(x, y, w, h, "rooms_list")
    return y + h
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
        -- What killing them pays right now, which is the one number on this
        -- row that is about the next thirty seconds rather than about the
        -- last hour.
        r.b = sim.ship_bounty(i)
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
        r.k, r.d, r.p, r.b = 0, 0, 0, 0
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
        elseif key == "bounty" then
            if a.b ~= b.b then return a.b > b.b end
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

    -- Four columns, right aligned off the panel's own edge, in the order a
    -- row is read: what you have done, then what you are worth. Bounty is
    -- outermost because it is the one number here about the next thirty
    -- seconds rather than about the last hour.
    --
    -- Each is as wide as the widest thing actually in it, measured every
    -- frame against the heading as well as the numbers. Fixed offsets do not
    -- survive four columns in 248 points: a pilot on twelve thousand points
    -- needs five digits and nobody else needs any of them, so a column sized
    -- for the worst case eats the names in every room where the worst case
    -- has not happened.
    local small = (FONT - 3) * S
    local num = (FONT - 2) * S
    local GAP = 7 * S
    local function col_w(field, label)
        -- Floored, because a column of single digits collapses to six points
        -- and its heading is the control that sorts by it: a target that
        -- narrow cannot be hit with a mouse, let alone a thumb.
        local wide = math.max(text_w(label, small), 16 * S)
        for i = 1, n do
            local r = rows[i]
            if not r.watch then
                wide = math.max(wide, text_w(tostring(r[field]), num))
            end
        end
        return wide
    end
    local bw, pw, dw, kw =
        col_w("b", "BTY"), col_w("p", "PTS"), col_w("d", "D"), col_w("k", "K")
    local bx = x + w - 12 * S
    local px = bx - bw - GAP
    local dx = px - pw - GAP
    local kx = dx - dw - GAP
    -- The marks sit in their own column left of the numbers rather than after
    -- each name, so a scan down the list finds them in a line instead of at a
    -- dozen different indents. The names end where that column begins.
    local mark_x = kx - kw - GAP - MARK_K * S
    local name_x = x + 12 * S
    local name_n = math.max(3, math.floor((mark_x - GAP - name_x) /
                                          (num * ADVANCE)))
    -- A heading is a control now, so the one in use is lit and the rest are
    -- not: the same way every other toggle in this interface says which way it
    -- is set.
    local function head_col(name, label, hx, align)
        local on = M.sort == name
        txt(label, hx, top_y() + 14 * S, small,
            on and pal.a(pal.FRIEND, 0.95) or pal.a(pal.DIM, 0.7), align)
        return on
    end
    head_col("name", "PILOTS", name_x, nil)
    head_col("kills", "K", kx, "right")
    head_col("deaths", "D", dx, "right")
    head_col("points", "PTS", px, "right")
    head_col("bounty", "BTY", bx, "right")
    -- Hit boxes over the headings. Each takes its whole column and the gap to
    -- its left, so the four tile without overlapping and the labels, which
    -- are one or three characters wide, are not the target.
    hit(x + 8 * S, top_y() + 4 * S, 60 * S, 18 * S, "sort_name")
    hit(kx - kw - GAP, top_y() + 4 * S, kw + GAP, 18 * S, "sort_kills")
    hit(dx - dw - GAP, top_y() + 4 * S, dw + GAP, 18 * S, "sort_deaths")
    hit(px - pw - GAP, top_y() + 4 * S, pw + GAP, 18 * S, "sort_points")
    hit(bx - bw - GAP, top_y() + 4 * S, bw + GAP, 18 * S, "sort_bounty")
    ticks(x + 12 * S, top_y() + 20 * S, w - 24 * S,
          pal.a(pal.RADAR_TILE, 0.35), 14 * S)

    local y = top_y() + head
    for i = 1 + M.scroll, math.min(n, M.scroll + shown) do
        local r = rows[i]
        local mine = r.i ~= nil and r.i == me
        local reading = r.i ~= nil and M.inspect == r.i
        -- A watcher is on nobody's side, so it is drawn in neither side's
        -- color: the neutral ink, dimmer than a pilot, which is the reading.
        local col = pal.DIM
        if not r.watch then
            -- The same color their plate wears out in the arena. A key is
            -- only a key if it reads the same in both places: a name orange
            -- here and violet on the hull is two facts about one pilot.
            col = team_col(sim.ship_team(r.i))
        end
        if mine or reading then
            -- Your row, marked the way a selected row is marked everywhere
            -- else in this interface: a lit rule and a wash off it, not a
            -- glyph in front of your name. The row being read about wears the
            -- same mark, in its own color, since it is a selection and this
            -- is how this interface draws one.
            local mark = reading and pal.BOUNTY or pal.FRIEND
            wash(x, y, w, LINE * S, pal.a(mark, 0.13))
            u:seg(x, ry(y), x, ry(y + LINE * S), 1.6 * S, pal.a(mark, 0.95))
        end
        local name = string.sub(r.name, 1, name_n)
        local cy = y + LINE * S / 2
        txt(name, name_x, cy, num, pal.a(col, mine and 1.0 or 0.8),
            nil, nil, true)
        if r.ai then bot_mark(mark_x, cy, pal.a(pal.DIM, 0.75)) end
        if r.watch then
            -- No seat, so no box to open about them, and no numbers: a
            -- watcher has not scored anything and three zeroes would say they
            -- had. One word instead, in the columns the numbers would have
            -- used, so the row is plainly a different kind of row.
            txt("watching", bx, cy, small, pal.a(pal.DIM, 0.7), "right")
        else
            -- The one way to ask about a pilot. Published before the panel's
            -- own box below, which takes the wheel and would otherwise
            -- swallow the press: first box in wins.
            hit(x, y, w - 6 * S, LINE * S, "pilot", r.i)
            -- Kills, deaths and points all in ink. Deaths read dimmer than
            -- the two beside them for a while, which was a judgement about
            -- the number rather than a fact about it: a column is either a
            -- score this board keeps or it is not on the board, and graying
            -- one of the three says the reader should care less about it
            -- while still making them read past it.
            txt(tostring(r.k), kx, cy, num, pal.a(pal.INK, 0.85), "right")
            txt(tostring(r.d), dx, cy, num, pal.a(pal.INK, 0.85), "right")
            -- The bounty in gold, which is the color it wears on a
            -- nameplate, in the corner stack and in the box this row opens.
            -- Points held the gold while it was the only score here; with
            -- both on the row, one of them has to be the one that means
            -- bounty everywhere else.
            txt(tostring(r.p), px, cy, num, pal.a(pal.INK, 0.85), "right")
            txt(tostring(r.b), bx, cy, num, pal.a(pal.BOUNTY, 0.9), "right")
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
-- in it: a table part is a name and is drawn as whoever owns it wrote it,
-- and everything else is the interface talking.
--
-- The interface talks in capitals everywhere else and does not here. A label
-- shouts because it is a thing to find at a glance; this is a sentence about
-- people, and "OZONE KILLED KESTREL" reads as an announcement rather than as
-- something that happened. Lower case leaves the names as the only capitals
-- on the line, which is also what the eye is looking for.
local function line_text(t)
    if type(t) == "string" then return t end
    local out = {}
    for _, part in ipairs(t) do
        out[#out + 1] = type(part) == "table" and part[1] or part
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
    rect(W / 2 - w / 2, y - h / 2, w, h, pal.rgb(0x03050a, 0.62 * a))
    txt(words, W / 2, y, size, pal.a(f.col or pal.INK, a), "center", nil, true)
end

-- The corner stack: what the triggers do, what you carry and can spend, and
-- what you are worth. Five rows, no panel and no rules between them.
--
-- What a trigger does is the team color and what you carry is gold, and that
-- separation is the whole reason there is no divider: a rule between them
-- would say a second time what the color already says once.
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
-- Each in the color it goes off in: a repel is the gold of the count beside
-- it, a burst the violet of the two dozen rounds it throws. Gray said
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
    -- Only the charges you are holding. A row for a slot you have spent out
    -- is a row that answers a question nobody asked: what a hull could carry
    -- belongs to picking the hull, and this corner is read in a fight, where
    -- the only thing worth knowing is what a key would spend if you pressed
    -- it. The empties used to draw, on the argument that the stat panel shows
    -- upgrades you do not have, and the stat panel is a thing you stop and
    -- read.
    --
    -- The count still says how many, so a row appearing is the same event as
    -- a pip lighting and reads as one.
    local slots = {}
    for _, c in ipairs(charges or {}) do
        if (c.count or 0) > 0 then slots[#slots + 1] = c end
    end
    local trigs = 0
    for t = 0, SIM_TRIGGERS - 1 do
        if sim.has_trigger(me, t) then trigs = trigs + 1 end
    end
    local n = trigs + #slots + 1

    -- One number the whole block is measured in, so it grows as a drawing
    -- rather than as a pile of separately tuned constants. Everything below
    -- is in `z`, not in S.
    local z = S * math.max(1, math.min(STACK,
                                       (H / S) * STACK_SHARE / (n * 22)))
    local rows_h = 22 * z
    local x = SL + PAD * S
    -- The axis every mark stands its subject on: the head of each round, the
    -- center of the repel's rings and the burst's hub, the middle of the
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
    local wide = val
    -- The charge rows in the order they were drawn, so a reader of this list
    -- walks them down the stack the way a reader of the stack does.

    -- A weapon row is the mark and nothing else.
    --
    -- The level was three cyan rungs in the counting column beside it, which
    -- is where the number lived before the round had a color of its own. It
    -- has one now: a round is drawn in the hue of the rung it is fired at, on
    -- one ramp for the whole game, so the corner already says what the ladder
    -- said and says it in the same terms the arena does. Two answers to one
    -- question, and the second one in the team's color, which the level is
    -- nothing to do with.
    for t = 0, SIM_TRIGGERS - 1 do
        if sim.has_trigger(me, t) then
            local right = weapon_mark(mid, y + rows_h / 2, 9 * z, me, t)
            local key = (t == sim.TRIG_GUN) and "gun" or "bomb"
            -- The row as far right as it actually drew. A loaded bomb wears
            -- fragments a third of the mark's width clear of it, and pointing
            -- at one of those is still pointing at the bomb.
            if right > wide then wide = right end
            zone(key, x, y, right - x, rows_h)
            y = y + rows_h
        end
    end

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
        zone(key, x, y, pw - x, rows_h)
        y = y + rows_h
    end

    -- What you are worth, which is the number that decides who comes for you,
    -- and which was only ever behind the info toggle. The mark is the green's
    -- own diamond, since greens are most of what the number counts.
    gl_diamond(mid, y + rows_h / 2, 6 * z, pal.a(pal.PRIZE, 0.8))
    local bty = sim.ship_bounty(me)
    txt(tostring(bty), val, y + rows_h / 2, (FONT - 2) * z,
        bty > 0 and pal.a(pal.PRIZE, 0.95) or pal.a(pal.DIM, 0.5))
    local bw = val + text_w(tostring(bty), (FONT - 2) * z)
    zone("bounty", x, y, bw - x, rows_h)

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
    -- What is withheld is the *name*. Which side somebody is on is on their
    -- hull, in the color of their plate, and has been since the plates
    -- started carrying it, so a row that said nothing at all would be keeping
    -- a secret the screen has already given away. The row is always drawn, in
    -- the side's color; a side this pilot may not have named reads as
    -- "private", which is the honest answer and the one the zone intends.
    local side, side_named = nil, false
    for _, t in ipairs(o.teams or {}) do
        if t.team == theirs and (t.public or same_team) then
            side = (t.name ~= "" and t.name) or ("team " .. t.team)
            side_named = t.name ~= ""
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
    -- Riding lives in this panel for the reason the other two do: you opened
    -- it by picking a person, and climbing onto somebody is a thing you do to
    -- a person. Never offered to a watcher: the request goes out on your own
    -- seat, and a watcher pressing DROP on somebody else's carrier would be
    -- detaching a ship the button was not about.
    --
    -- Offered on a living teammate who is not you and is not themselves
    -- riding somebody, since the core refuses a chain. Every other condition
    -- the core enforces is left to it: a bar that is not full and a hull with
    -- no room refuse on the wire and say so by the button not taking. Testing
    -- them here as well would be a second copy of the rules, drifting.
    local riding = (not o.watch) and sim.ship_carrier(o.me) or 255
    local drop = riding ~= 255 and i == riding
    local attach = not o.watch and same_team and i ~= o.me
        and sim.ship_alive(i) == 1 and sim.ship_carrier(i) == 255 and not drop
    -- The team row always exists now, so the count is fixed.
    local rows_n = 7
    local h = 30 * S + rows_n * rowh
        + ((invite or follow or attach or drop) and (KEY_H + 12) * S or 0)
        + 10 * S
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
    -- In the side's own color, which is the same color their plate wears
    -- out in the arena: this box is where a player learns what that color
    -- on the hull they are looking at means.
    row("TEAM", side or "private", pal.a(team_col(theirs), 0.95), side_named)
    -- What the zone is willing to say this seat is, which is the honest
    -- version of the question: the client cannot tell, and the server's label
    -- is the only answer anybody has. A guest is not an accusation.
    row("SEAT", (p and p.label) or "unknown")
    -- Where the ladder has them. A band rather than the number behind it: the
    -- number twitches after every death and a word moves only when something
    -- changed, which is the whole reason tiers exist. A pilot still placing
    -- reads as that and draws dim, because it is the absence of an answer
    -- rather than a low one, and a newcomer should not read as ranked last.
    local band = (p and p.tier) or "unrated"
    row("TIER", band, band == "placing" and pal.a(pal.DIM, 0.85) or nil)
    -- A line each, rather than one line of "21K 20D 748P". Three numbers
    -- packed into a row with their units stuck to them is a thing to decode;
    -- three labeled rows are three numbers to read, and this panel already
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
    -- DROP only on the card of whoever you are riding: a DROP under a
    -- stranger's name would be a control about a ship the name does not
    -- belong to. ATTACH on any other living teammate, including while you
    -- ride -- switching carriers is a legal ask, gated by the core on the
    -- same full bar as any other attach. Neither ever displaces INVITE,
    -- which wants an enemy where these want a teammate.
    if drop then
        label, action = "DROP", "detach"
    elseif attach then
        label, action = "ATTACH", "attach"
    elseif invite then
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

-- What is drawn while a pilot is sitting in a safe zone.
--
-- Two things, and the second only when the room has a limit. A safe zone is
-- the one part of the map whose rules are different and the tile says so in
-- color alone, which is a thing you learn by being shot at somewhere you
-- thought was safe. And a room that is about to take the seat back has to say
-- so first, or the ship simply stops being yours.
--
-- The same place DESTROYED uses, and never both at once: they are the two
-- states where there is nothing to fly and nothing to look away from, and the
-- middle of the screen is where a player is already looking. Lower than the
-- word is, because there is a game going on around this one and the hull it
-- is about is in the middle of it.
--
-- The clock is a numeral rather than a draining bar. A minute is too long for
-- a bar to read as anything, and the number a pilot wants here is how many
-- seconds they have, which is a number.
-- --- the help table --------------------------------------------------------
--
-- Every key the game answers to, what it is, and one sentence saying what it
-- does. Held open rather than hovered, so reading it is a decision a player
-- makes once and not something that happens to them while they are flying.
--
-- Static. What a particular hull is carrying is the corner stack's job and it
-- draws that already; this is the keyboard, which is the same on every ship in
-- every room, and a table that rearranged itself would be a reference you
-- cannot learn.
--
-- Keyboard only, and that is not an oversight: a touchscreen has no key to
-- open it with and no keys to list. The menu's help page is what a phone gets,
-- and it names thumbs because thumbs are what a phone has.
local HELP_ROWS = require("arena.controls")
M.HELP_ROWS = HELP_ROWS

-- Whether the table is up. The arena owns the key; this owns the drawing.
M.help = false

-- How wide a string draws, counting glyphs rather than bytes.
--
-- `text_w` counts bytes, which is right for every other caller and runs in
-- the wrap on every frame. The arrow keys are the one place the interface
-- says something outside ASCII, and each of them is three bytes: measured
-- with `text_w` the key column comes out three times too wide. Counting
-- continuation bytes is exact for UTF-8 and this runs fourteen times while a
-- table is open, so it can afford to be.
local function glyph_w(s, px)
    local _, cont = string.gsub(s, "[\128-\191]", "")
    return (#s - cont) * px * ADVANCE
end

local function help_table()
    local fs = (M.compact and 11 or 13) * S
    local rowh = fs * 1.65
    local pad = 18 * S
    -- Three columns, measured off the widest thing each has to hold rather
    -- than guessed, since the sentences are what decides the width and they
    -- are the one column that cannot be allowed to wrap.
    local kw, nw, dw = 0, 0, 0
    for _, r in ipairs(HELP_ROWS) do
        kw = math.max(kw, glyph_w(r.key, fs))
        nw = math.max(nw, glyph_w(r.name, fs))
        dw = math.max(dw, glyph_w(r.what, fs))
    end
    local gap = 14 * S
    local w = pad * 2 + kw + gap + nw + gap + dw
    local head = fs * 1.9
    local h = pad * 2 + head + #HELP_ROWS * rowh
    -- Shrunk to fit rather than clipped, because a window narrower than the
    -- longest sentence is a window this has to work in anyway.
    local room = W - 24 * S
    local scale = (w > room) and (room / w) or 1
    if scale < 1 then
        fs, rowh, pad, gap = fs * scale, rowh * scale, pad * scale, gap * scale
        kw, nw = kw * scale, nw * scale
        head = head * scale
        w = room
        h = pad * 2 + head + #HELP_ROWS * rowh
    end
    local x, y = (W - w) / 2, (H - h) / 2

    rect(x, y, w, h, pal.rgb(0x03050a, 0.88))
    u:frame(x, ry(y, h), w, h, 1.0 * S, pal.a(pal.DIM, 0.5))

    txt("CONTROLS", x + pad, y + pad + head * 0.35, fs * 1.05,
        pal.a(pal.INK, 0.9))
    local rule = y + pad + head - fs * 0.35
    u:seg(x + pad, ry(rule), x + w - pad, ry(rule), 0.8 * S,
          pal.a(pal.DIM, 0.45))

    local kx = x + pad
    local nx = kx + kw + gap
    local dx = nx + nw + gap
    local was = case
    for i, r in ipairs(HELP_ROWS) do
        local ty = y + pad + head + (i - 0.5) * rowh
        -- The key in the color a key is drawn in everywhere else, the name in
        -- ink, and the sentence dimmer than both: three weights so the eye can
        -- run down one column without reading the other two.
        case = "upper"
        txt(r.key, kx, ty, fs, pal.a(pal.FRIEND, 0.95))
        txt(r.name, nx, ty, fs, pal.a(pal.INK, 0.92))
        -- Prose, and set as prose. The rest of the interface shouts.
        case = "sentence"
        txt(r.what, dx, ty, fs, pal.a(pal.PANEL_INK, 0.85))
    end
    case = was
end

local function safe_note(spent, limit)
    local y = H * 0.62
    txt("SAFE ZONE", W / 2, y, (M.compact and 12 or 16) * S,
        pal.a(pal.FRIEND, 0.9), "center")
    if limit <= 0 then return end
    -- Rounded up, so the last second is a 1 and the number never sits on 0
    -- while the hull is still there.
    local left = math.ceil((limit - spent) / 100)
    if left < 0 then left = 0 end
    -- Red for the last ten, which is where it stops being information and
    -- starts being a warning.
    local col = left <= 10 and pal.ENEMY or pal.DIM
    txt("seat released in " .. left, W / 2, y + (M.compact and 15 or 20) * S,
        (M.compact and 10 or 12) * S, pal.a(col, 0.9), "center")
end

-- The damage vignette: red creeping in from the edges rather than a flash
-- over the middle, so it never hides the ship that is shooting you.
--
-- With the corner energy bar gone this carries more weight than it used to:
-- the vignette says "you are being hit", the ship's pip says how much is
-- left, and its color says how urgent that is. Three channels, none of them
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

-- One thing to press, wherever the thing to press turns up: a frame with a
-- hint of fill, lit in the color of what it does, and its word in capitals in
-- the face the numbers are set in. The corner keys and a question's answers
-- are the same object, so they are one drawing rather than two functions
-- agreeing on seven numbers by hand.
--
-- `KEY_H` and `KEY_SIZE` are the two of them a caller has to lay out around,
-- so they live out here with it rather than being repeated at each call.
local function menu_button(on_air, watch, room)
    -- Two keys, drawn the way the help page draws a key. They were two bare
    -- words over a shared rule, which asked a player to know that a word in
    -- that corner was a thing to press, and the board has taught the same hand
    -- what a key looks like already.
    --
    -- One color between them, and one rule for lighting it. MENU was drawn in
    -- ink and PLAYERS in slate, which is two controls that do the same kind of
    -- thing wearing two different states before either had been pressed. What
    -- they wear now is off or on, and the panel each opens is what turns it on.
    local x, y = SL + PAD * S, ST + PAD * S
    -- Each key is as wide as its own word. A slot cut for four letters is a
    -- slot the longer of the two runs out of.
    local cx = x
    local keys = {{"MENU", "open", menu_up},
                  {"PLAYERS", "details", M.details}}
    -- Which copy of this game you are in, and the way to a different one.
    --
    -- Only when the zone is holding more than one, which is the caller's
    -- reading of `rooms` rather than anything this number can say. A zone with
    -- one room seats everybody in room 1, so the chip said ROOM 1 over a
    -- distinction that did not exist, next to a key that opened a list of the
    -- room the player was already in. Both are drawn from the same fact now.
    --
    -- The number is still the server's answer rather than the row that was
    -- pressed. A room can fill in the moment between a list being drawn and a
    -- key landing, and the join is then seated somewhere else; a chip
    -- repeating what was asked for would be the one thing on screen still
    -- claiming it worked.
    if room then
        keys[#keys + 1] = {"ROOM " .. room, "rooms", M.rooms_open}
    end
    for _, c in ipairs(keys) do
        local ww = key_w(c[1])
        key_cap(cx, y, ww, c[1], c[3])
        hit(cx, y, ww, KEY_H * S, c[2])
        cx = cx + ww + KEY_GAP * S
    end
    -- The tally, when the room channel is pointed at you.
    --
    -- It sits on this row rather than at the top of the middle, which is where
    -- it started and where it could not stay: that strip already carries the
    -- flag pennants and the round's banner, both of them centered, and a notice
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
    -- Pointing at this one names nothing. Four bars labeled LINK beside a
    -- millisecond count are already a sentence about the connection, and a
    -- word saying so is the interface reading its own label back.
    -- The bars are the readout a player wants and the whole of it. Everything
    -- behind them is for whoever is working on this, so it hides behind the
    -- one thing on screen that is already about the connection.
    --
    -- What answers that press is the whole cluster and the strip it stands
    -- in. It was 46 by 20 points hung off the right edge, which covered the
    -- four bars and the last quarter of the word beside them: three quarters
    -- of the only thing on screen labeled LINK did nothing when pressed,
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
-- Deliberately plain: labeled lines of text, no instrument, no color doing
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
        {"wire", st.wire or "ws"},
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
-- cross a phone. One pennant per flag, colored by who holds it, says the
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
    -- Dimmed under the menu, and under a card the same amount. A wash is a
    -- mesh and text is not: the gui draws over every layer, so a card that
    -- washes the screen darkens the instruments and leaves their labels at
    -- full brightness unless this says otherwise. The card is the only thing
    -- being asked about, and the readout behind it should recede whole.
    --
    -- A third rather than out: nothing is paused, you can be shot while you
    -- are answering, and a glance at your energy is still worth taking.
    text_dim = (o.menu_open or M.room_ask) and 0.34 or 1

    -- On a touchscreen the bottom of the screen belongs to the thumbs. The
    -- stick sits in the bottom left corner and the pads in the bottom right,
    -- which is exactly where the status panel and the control hint were, so
    -- everything else moves up out of the way of them.
    local lift = M.touching and 150 * S or 0

    -- One panel in this column at a time. The rooms list stands in the
    -- scoreboard's slot, so whichever is up is the one drawn.
    M.zone_name = (o.zone or ""):match("^[^\n]*")
    local top = rooms_panel(o.rooms, o.room)
    if top == 0 then top = scores(me, o.pilots, o.watchers) end
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
    --
    -- Nor on a touchscreen, where the pads carry the weapons and the charges
    -- and the last thing left in the corner was your bounty. That is a number
    -- you read between fights rather than during one, the scoreboard has it,
    -- and one figure in a corner of a phone is furniture for the sake of a
    -- corner not being empty.
    if not (o.watch or M.touching) then
        status(me, o.charges, lift)
    end
    inspect(o, o.watch and top or loadout(me, o.class_names, top))
    -- A watcher is never the subject, so the tally can only be about a pilot
    -- who is flying, and the two never contend for the slot.
    -- The room chip only where there is a room to move to. `rooms` is the
    -- zone's whole list and the directory already drops it to nil below two,
    -- which is the one place that decision is made; this reads it rather than
    -- making it again from a number.
    local several = o.rooms and #o.rooms > 1
    menu_button(o.on_air and not o.watch, o.watch, several and o.room or nil)
    vignette(o.hurt or 0)
    -- The two big centered lines are the only interface that sits where the
    -- menu does. The panels can share the screen with it; these cannot.
    if o.menu_open then return end
    -- Over the arena and under nothing, since it is the thing being read. The
    -- game carries on behind it: nothing is paused here, and a player who
    -- opens this in a fight can still be shot while they read.
    if M.help then help_table() end
    flag_strip(me)
    if o.banner and o.banner ~= "" then
        txt(o.banner, W / 2, 64 * S, (M.compact and 15 or 24) * S,
            pal.a(pal.INK, 0.92), "center")
    end
    if not o.watch and sim.ship_alive(me) == 0 then
        txt("D E S T R O Y E D", W / 2, H * 0.46, (M.compact and 15 or 22) * S,
            pal.ENEMY, "center")
    elseif not o.watch and (o.safe or 0) > 0 then
        safe_note(o.safe, o.safe_limit or 0)
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
--
-- The line is held against the screen rather than struck off the hull, so a
-- grid of eight ships at one size is drawn in one weight whatever each of them
-- measures. Anything else standing in that grid has to be told this: the
-- spectate cell draws a helmet rather than a hull, and left to work its own
-- weight out it came out at twice the ships beside it.
local HULL_PEN = 1.4

-- Local now that it is. It was declared up with the glossary's figures and
-- assigned here, because the bounty card drew one; the card is gone and every
-- caller left is below this, so the forward declaration went with it rather
-- than leaving a global behind.
local function thumb(cx, cy, cls, col, scale, turn)
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
    trace(h.poly, HULL_PEN * S, col)
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
-- the bound ones lit in the color of what they do, with a legend saying what
-- each color is. A key does not need a caption when the board it sits on
-- says where it is.
--
-- Widths are in key units so the board scales with the panel. The rows are
-- the standard board's, minus the function row nothing binds.
local BOARD = {
    {{"esc", 1.3, "menu"}, {"~", 1, "multi"}, {"1"}, {"2"}, {"3"}, {"4"},
     {"5"}, {"6"}, {"7"}, {"8"}, {"9"}, {"0"}},
    {{"tab", 1.7, "bomb"}, {"Q", 1, "charge"}, {"W", 1, "charge"}, {"E"},
     {"R"}, {"T"}, {"Y"}, {"U"}, {"I"}, {"O"}, {"P", 1, "players"}},
    {{"caps", 2.0}, {"A", 1, "charge"}, {"S", 1, "charge"}, {"D", 1, "drone"},
     {"F"},
     {"G"}, {"H", 1, "help"}, {"J"}, {"K"}, {"L"}},
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

-- What each color means, in the order the legend reads.
--
-- Every lit key is on this list, which is the point of it: the three keys
-- that open something used to share one gray and a line of prose naming them
-- one after another, so the picture said "these do interface things" and the
-- caption did the actual work. A color apiece and a word in the legend says
-- it once.
local BOARD_CATS = {
    {key = "fly", word = "fly"},
    {key = "gun", word = "guns"},
    {key = "multi", word = "multifire"},
    {key = "bomb", word = "bombs"},
    {key = "charge", word = "charges"},
    {key = "drone", word = "drop off"},
    {key = "players", word = "players"},
    {key = "map", word = "map"},
    {key = "menu", word = "menu"},
    {key = "help", word = "controls"},
}

-- Hues nothing else in the legend is wearing, which is what a legend needs
-- and all it needs. Multifire takes the color the green that grants it is
-- drawn in, so the one key that is a gun in a different mode reads as a
-- relative of the guns rather than as a separate weapon.
--
-- Menu had the gray every unbound key is drawn in, brighter. That is not a
-- color, it is the absence of one, and against a board of dead keys in the
-- same hue the lit one did not read as lit at all: the swatch, the word
-- under it and the key itself all looked switched off. Amber instead, which
-- nothing else on this page is wearing.
local function board_col(cat)
    if cat == "gun" or cat == "gun2" then return pal.FRIEND end
    if cat == "multi" then return pal.MOD_COL end
    if cat == "bomb" then return pal.BOMB end
    if cat == "charge" then return pal.CHARGE_COL end
    if cat == "fly" then return pal.INK end
    -- The gunner's own band, and it is the bounty gold rather than a new
    -- hue: this key is the way off a ship somebody else is flying, and gold
    -- is already what the interface uses for a number about you.
    if cat == "drone" then return pal.BOUNTY end
    if cat == "players" then return pal.DOOR end
    if cat == "map" then return pal.HOLE end
    if cat == "menu" then return pal.ENEMY end
    -- The one key that explains the rest of them, in the ink the interface
    -- names things with. It opens a slab of words rather than a panel.
    if cat == "help" then return pal.PANEL_INK end
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

-- One key: an outline in its function's color with a hint of fill, or a
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
--
-- One line runs through all of them, held against the screen rather than
-- against the mark's own size, so a column of six reads as one set. Anything
-- that draws itself here and works its weight out from its width has to be
-- told this instead.
local RAIL_PEN = 1.2

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
    --
    -- Drawn at the rail's own hairline rather than at its own. Everywhere else
    -- this mark goes it is 11 points beside a number and its weight is struck
    -- off its width, which is right for a mark that has to survive being
    -- small. Here it is drawn half again as big next to six shapes that all
    -- hold one line no matter what they are, and a weight that scales made it
    -- the one heavy stop in the column.
    pilot_mark(cx, cy, col, r * 1.6, RAIL_PEN * S)
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

-- Discord's own mark, traced from Discord's own file.
--
-- Two things about this one are not ours to decide, and both were got wrong
-- before the guidelines were read. discord.com/branding says "please do not
-- edit, change, distort, recolor, or reconfigure the Discord logo", and lists
-- three colors it may appear in: Blurple, black, or white.
--
-- So it does not take the `col` every other mark here takes. A rail stop
-- normally lights by turning its mark from slate to team blue, and this one
-- cannot: it stays Blurple lit or not. Nothing is lost, because a selected
-- stop already draws a lit field, a bar reaching toward the stage, and its
-- label in ink. The mark was never the only thing saying where you are.
--
-- And it is a filled silhouette with the eyes cut out of it, rather than the
-- outline-and-two-dots the rest of the rail is drawn as. That is the shape
-- the logo is; an outline of it would be a reconfiguration.
--
-- The geometry is the official path from Discord's own asset, sampled into a
-- polygon and triangulated with the eyes as holes, because the layer has no
-- path, no bezier and no even-odd rule to do it with at runtime. Baked here
-- rather than computed at load: it is the same answer every time, and an ear
-- clipper in the client would be a hundred lines to arrive at a constant.
--
-- Forty samples around the body and twelve around each eye. Eighty was tried
-- and is indistinguishable at the thirteen points the rail gives this, which
-- is the only size it is ever drawn at.
--
-- A unit box, y down, x from -1 to 1. Indices are one-based triples into it.
local CLYDE_V = {
    0.6930, -0.6418, 0.5295, -0.7066, 0.3600, -0.7536, 0.2374, -0.6812,
    0.0754, -0.6762, -0.1000, -0.6750, -0.2474, -0.7018, -0.3826, -0.7487,
    -0.5515, -0.6995, -0.7087, -0.6219, -0.8084, -0.4523, -0.8856, -0.2838,
    -0.9418, -0.1164, -0.9785, 0.0501, -0.9974, 0.2158, -1.0000, 0.3806,
    -0.9505, 0.5322, -0.7921, 0.6299, -0.6363, 0.7041, -0.4828, 0.7536,
    -0.3896, 0.6045, -0.5178, 0.5176, -0.4173, 0.5048, -0.2470, 0.5547,
    -0.0746, 0.5787, 0.0982, 0.5770, 0.2697, 0.5496, 0.4382, 0.4963,
    0.4956, 0.5287, 0.3990, 0.6248, 0.5009, 0.7527, 0.6551, 0.6956,
    0.8112, 0.6188, 0.9698, 0.5178, 1.0000, 0.3409, 0.9924, 0.1609,
    0.9664, -0.0123, 0.9228, -0.1790, 0.8623, -0.3394, 0.7857, -0.4938,
    -0.3322, 0.2720, -0.4228, 0.2444, -0.4874, 0.1718, -0.5120, 0.0699,
    -0.4875, -0.0317, -0.4230, -0.1039, -0.3318, -0.1313, -0.2401, -0.1034,
    -0.1758, -0.0309, -0.1524, 0.0703, -0.1767, 0.1720, -0.2411, 0.2444,
    0.3327, 0.2720, 0.2421, 0.2444, 0.1774, 0.1718, 0.1528, 0.0699,
    0.1774, -0.0317, 0.2419, -0.1040, 0.3332, -0.1313, 0.4248, -0.1034,
    0.4891, -0.0308, 0.5125, 0.0705, 0.4883, 0.1721, 0.4241, 0.2445,
}

local CLYDE_T = {
    49, 56, 55, 57, 56, 49, 45, 44, 15, 15, 14, 13,
    13, 12, 11, 11, 10, 9, 9, 8, 7, 4, 3, 2,
    2, 1, 40, 40, 39, 38, 38, 37, 36, 36, 35, 34,
    34, 33, 32, 32, 31, 30, 28, 27, 26, 26, 25, 24,
    22, 21, 20, 20, 19, 18, 18, 17, 16, 16, 15, 44,
    50, 49, 55, 58, 57, 49, 46, 45, 15, 15, 13, 11,
    11, 9, 7, 4, 2, 40, 40, 38, 36, 36, 34, 32,
    32, 30, 29, 28, 26, 24, 22, 20, 18, 18, 16, 44,
    51, 50, 55, 59, 58, 49, 46, 15, 11, 11, 7, 6,
    5, 4, 40, 40, 36, 32, 28, 24, 23, 22, 18, 44,
    52, 51, 55, 59, 49, 48, 47, 46, 11, 11, 6, 5,
    40, 32, 29, 23, 22, 44, 41, 52, 55, 59, 48, 47,
    47, 11, 5, 40, 29, 28, 23, 44, 43, 41, 55, 54,
    59, 47, 5, 23, 43, 42, 41, 54, 53, 60, 59, 5,
    23, 42, 41, 61, 60, 5, 28, 23, 41, 61, 5, 40,
    28, 41, 53, 62, 61, 40, 28, 53, 64, 63, 62, 40,
    28, 64, 63, 63, 40, 28,
}

-- Blurple, and not from the palette: `pal` is this game's colors and this is
-- somebody else's, held at the one value their guidelines name.
local BLURPLE = pal.rgb(0x5865F2)

local function mark_discord(cx, cy, r)
    -- Sized to the mark's own width, which is the wider of its two axes, so it
    -- fills the room a stop gives it the way the round marks beside it do.
    for i = 1, #CLYDE_T, 3 do
        local a1, b1, c1 = CLYDE_T[i] * 2 - 1, CLYDE_T[i + 1] * 2 - 1,
                           CLYDE_T[i + 2] * 2 - 1
        u:tri(cx + CLYDE_V[a1] * r, ry(cy + CLYDE_V[a1 + 1] * r),
              cx + CLYDE_V[b1] * r, ry(cy + CLYDE_V[b1 + 1] * r),
              cx + CLYDE_V[c1] * r, ry(cy + CLYDE_V[c1 + 1] * r), BLURPLE)
    end
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
               discord = mark_discord, leave = mark_leave}

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
    -- A row that stands for a side is written in that side's color, which is
    -- what makes this list the key to every plate in the arena. It outranks
    -- the mark's cyan because your own side generates cyan anyway, so the two
    -- rules agree on the one row where they could disagree.
    if r.tint then col = team_col(r.tint) end
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
    -- Two kinds of row you cannot press, written the same shade back from the
    -- ones you can: one nothing is serving yet, and one with no seat left.
    if r.waiting or r.full then col = pal.a(col, 0.6) end
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
    elseif r.players and (r.live or r.full) then
        -- A full room keeps its count. The dial above says "looking for one of
        -- these", which is the opposite of what a full room is: the count is
        -- the whole reason it cannot be entered, so hiding it would leave the
        -- row saying it is unavailable without saying why.
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
-- The heading is what happened and the line under it is what happens next.
-- The address being asked used to sit under those two, small and dim, for
-- whoever is running this rather than whoever is playing. Whoever is running
-- it reads logs.
local function empty_state(x, y, w, h, e)
    local cx = x + w / 2
    local r = math.max(22 * S, math.min(56 * S, h * 0.26))
    -- Centered in whatever room is left rather than hung off the top of it: on
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
end

-- One line of type being entered: its name at the left, what is in it along
-- a rule, and a caret where the next character lands. Not a box, because a
-- row of boxes reads as a form and this interface has none; the rule is the
-- same stroke a key slot used to stand on.
--
-- A password draws as discs. It is the one string on any screen somebody may
-- be reading over a shoulder, and a row of discs says how much has been
-- typed without saying what.
-- `dom` is a line the page is holding as an input element. The rule and the
-- label are still drawn here, because they are the card; what sits on the
-- rule belongs to the element.
local function field_line(x, y, w, f, lit, dom)
    -- Which line is taking type is the page's answer to give where the page
    -- holds them, so nothing here claims it: the labels weigh the same and
    -- the caret in the element is what says which line is live.
    if dom then lit = false end
    txt(f.label or "", x, y, 11 * S, pal.a(pal.DIM, lit and 0.95 or 0.7))
    local ty = y + 22 * S
    if not dom then
        local shown = f.value or ""
        local size = 16 * S
        local adv = size * ADVANCE
        -- What fits on the rule, and the end of it rather than the start,
        -- the way a text box scrolled to its caret shows the end. A line
        -- is sixty four characters at most and the rule holds fewer than
        -- that on any window; unclipped, a pasted password left the card
        -- and ran off the side of the screen. One character of room is
        -- kept back for the caret, which stands after the last of them.
        local fit = math.max(1, math.floor(w / adv) - 1)
        if #shown > fit then shown = string.sub(shown, #shown - fit + 1) end
        if f.mask then
            for i = 1, #shown do
                u:disc(x + (i - 0.5) * adv, ry(ty), 3.4 * S, 10,
                       pal.a(pal.FRIEND, lit and 1 or 0.65))
            end
        else
            txt(shown, x, ty, size, pal.a(pal.FRIEND, lit and 1 or 0.7),
                nil, nil, true)
        end
        if lit then
            rect(x + #shown * adv + 1 * S, ty - 9 * S, 1.6 * S, 18 * S,
                 pal.a(pal.FRIEND, 0.9))
        end
    end
    -- Lit is which line the caret is on, and where the page holds the caret
    -- this side does not know. Every rule alike then, a little awake, and
    -- the caret in the element is what says which line is taking type.
    local col, alpha = pal.DIM, 0.3
    if dom then
        alpha = 0.45
    elseif lit then
        col, alpha = pal.FRIEND, 0.9
    end
    u:seg(x, ry(ty + 14 * S), x + w, ry(ty + 14 * S), 1.2 * S,
          pal.a(col, alpha), true)
    return 48 * S
end

-- The lines of a card, for the page to lay input elements over. CSS pixels,
-- because that is the page's unit and this interface is drawn in device
-- pixels; `S` is the ratio between them.
--
-- Each element is centered on the middle `field_line` draws its type on, the
-- one the caret and the password's discs already use, so the type lands on
-- the rule rather than near it. Forty four tall rather than the height of
-- the type, which is the size a finger is: the whole row takes the tap, the
-- way the drawn line's own target did, and the label above it belongs to
-- the line it labels.
--
-- The name a manager should file the password under rides on the end, after
-- a bar, and is stripped to letters, digits and spaces on the way: it is
-- about to be written into a line of JavaScript, and the one string on this
-- card that came from somewhere else should not be able to end that line.
local FIELD_H = 44
local function ask_spec(fx, fy, fw, a)
    local out = {}
    local y = fy
    for i, f in ipairs(a.fields) do
        out[i] = string.format("%.1f,%.1f,%.1f,%d,%s,%d", fx / S,
                               (y + 22 * S) / S - FIELD_H / 2, fw / S,
                               FIELD_H, f.kind or "current-password",
                               f.max or 64)
        y = y + 48 * S
    end
    local spec = table.concat(out, ";")
    if a.ghost then
        spec = spec .. "|" .. string.gsub(a.ghost, "[^%w ]", "")
    end
    return spec
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
    -- Dimmed rather than blacked out. The wash is there to say that nothing
    -- behind it is listening, which the dropped hit boxes below enforce and
    -- this only has to announce; at 0.62 it was doing a second job nobody
    -- asked for, hiding a live arena from somebody who is still flying in it.
    rect(0, 0, W, H, pal.a(pal.BG, 0.35))
    -- Nothing behind this is listening, and hit boxes are first come first
    -- served, so the ones already published go: a tap on the rail or on a row
    -- under the wash would otherwise answer a question it cannot see.
    M.hits = {}
    text_dim = 1
    -- The lines go to the page wherever there is a page to take them, which
    -- is every build that runs in a browser and no other. What that buys is
    -- the same on both kinds of machine and is not available any other way:
    -- a password manager can fill a form and cannot fill a drawing.
    --
    -- It was a touchscreen only at first, on the argument that a desktop
    -- already has the keys and the drawn line reads in the interface's own
    -- face. The face was the smaller thing. Set by whoever draws, because
    -- only the client knows whether there is a page under it.
    local dom = a.fields and M.page_fields and true or false
    local cw = math.min((a.fields and 380 or 340) * S, w - 24 * S)
    -- A card with a code in it is taller by the line the code takes, and one
    -- with lines to fill in is taller by each of them.
    local ch = (a.code and 152 or 110) * S
    if a.fields then ch = (84 + 48 * #a.fields + 46) * S end
    -- A line under the head needs its own room. The keys are laid out from
    -- the bottom edge up, so without this they come back to meet it.
    if a.note then ch = ch + 30 * S end
    local cx = x + (w - cw) / 2
    local cy = y + (h - ch) / 2
    rect(cx, cy, cw, ch, pal.a(pal.BTN_BG, 0.98))
    u:frame(cx, ry(cy, ch), cw, ch, 1.1 * S, pal.a(pal.BORDER, 1))
    local mid = cx + cw / 2
    txt(a.head or "", mid, cy + 36 * S, (M.compact and 15 or 16) * S,
        pal.a(pal.INK, 0.95), "center", MENU_FONT)
    -- What answering costs, when that is not obvious from the question. The
    -- menu's cards never needed one; the rooms card does, because what a move
    -- takes off a pilot is the part they cannot see.
    if a.note then
        txt(a.note, mid, cy + 60 * S, (FONT - 2) * S,
            pal.a(pal.DIM, 0.9), "center")
    end
    -- What the question is about, when it is about a string rather than a
    -- choice: big enough to read off one machine and type into another,
    -- quoted rather than said, and lit, because it is the one thing on the
    -- card anybody has to get right.
    if a.code then
        txt(a.code, mid, cy + 72 * S, 30 * S, pal.FRIEND, "center", nil, true)
    end
    if a.fields then
        local fx = cx + 26 * S
        local fw = cw - 52 * S
        local fy = cy + 58 * S
        if dom then M.ask_dom = ask_spec(fx, fy, fw, a) end
        for i, f in ipairs(a.fields) do
            local lit = not a.sending and i == (a.field or 1)
            fy = fy + field_line(fx, fy, fw, f, lit, dom)
            -- A tap on a line moves the caret to it, the way a tap on a
            -- form's line does everywhere else a phone is used. Not where
            -- the page holds the line: the element covers this rectangle
            -- and answers the same tap itself, and a target underneath it
            -- would only be reachable by missing the one that works.
            if not dom then
                hit(fx, fy - 48 * S, fw, 46 * S, "field", i)
            end
        end
    end
    -- Laid out from the middle out rather than from an edge in, so the row of
    -- answers stays centered whatever the words are.
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
        -- Whose question this is. The menu owns "answer"; anything else
        -- raising a card says so, or its answers are delivered to the menu.
        hit(kx, ky, ws[i], KEY_H * S, a.action or "answer", i)
        kx = kx + ws[i] + KEY_GAP * S
    end
end

-- The question a pressed room raises, over the whole screen.
--
-- A card rather than something inside the panel. Moving costs a pilot every
-- green they are carrying, and a question that size should not be answerable
-- by a stray click in the corner the question was asked in: the wash puts the
-- arena behind it and `ask_card` drops every hit box already published, so
-- nothing else on screen can be pressed while it stands.
--
-- Drawn from the frame loop after everything else for that same reason: the
-- boxes it clears are the ones published before it.
function M.room_card(rooms)
    if not M.room_ask or not rooms then return end
    local rm
    for _, r in ipairs(rooms) do
        if r.n == M.room_ask then rm = r end
    end
    if not rm then M.room_ask = nil return end
    ask_card(0, 0, W, H, {
        head = "move to room " .. rm.n .. "?",
        note = "MOVING RESPAWNS YOU",
        action = "room_answer",
        keys = {{label = "move"}, {label = "stay"}},
        sel = 1,
    })
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
    -- Centered in the room it was given rather than hung off the top, so a
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
                       pal.a(col, (hot or r.mark) and 1 or 0.7), ch * 0.30,
                       HULL_PEN * S)
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

-- The mark: two aligned rows of \|\|\|.
--
-- Each wedge is a diagonal falling into a vertical and meeting it on the
-- baseline. The rows share their three x positions. Orange begins the upper
-- row, cyan finishes the lower one, and the other strokes use the dark slate
-- from the site mark.
--
-- The diagonals are wakes. The bullet reveals each one as a solid stroke, then
-- climbs the vertical beside it.
--
-- Drawn here rather than imported, because the interface has no way to put a
-- picture on screen and would not want one: everything else is strokes into a
-- mesh layer, and a mark that arrived as pixels would be the only thing in the
-- client that could not be drawn at any size. The page carries the same shape
-- as `client/web/icon.svg`, and logo_test holds the two to each other.
--
-- The row and gap ratios are the 48/4/48 construction used by the site SVG.
-- A row is half as tall as the old mark, so its pen is measured against the
-- row rather than the full two-row height.
local MK_WD, MK_GAP = 0.50, 1 / 12
local MK_ROW, MK_ROW_GAP, MK_WEIGHT = 0.48, 0.04, 0.075
local MK_SPAN = 3 * MK_WD + 2 * MK_GAP

-- How wide the mark stands, against its own height.
function M.logo_width(h)
    return h * MK_ROW * MK_SPAN
end

-- Where each stroke starts and ends, in units of one row's height, with the
-- row's left edge and baseline at the origin and y up. Six of them, in the
-- order a bullet would draw them: down the diagonal, bounce, up the vertical,
-- across to the next.
local function mk_strokes()
    local out = {}
    for i = 0, 2 do
        local x = i * (MK_WD + MK_GAP)
        out[#out + 1] = {x, 1, x + MK_WD, 0, wedge = i, wake = true}
        out[#out + 1] = {x + MK_WD, 0, x + MK_WD, 1, wedge = i}
    end
    return out
end
local MK_STROKES = mk_strokes()

-- How long each bullet spends on a piece, and how long a bounce shows for.
local MK_FALL, MK_RISE, MK_HOP, MK_FLASH = 0.17, 0.12, 0.07, 0.22

-- When the run started. Reset whenever the mark has not been drawn for a
-- moment, which is the honest reading of "the menu just opened": nothing has
-- to tell the mark that it did, and every way in gets the same animation.
local logo_seen, logo_t0 = -1, 0

-- One stroke, drawn to `p` of its length. At p = 1 this is exactly what the
-- still mark draws, which is what lets the animation finish into the shape
-- rather than into an approximation of it.
-- `oy` is the baseline, in this file's own downward y, and a stroke's second
-- and fourth numbers are heights above it. One flip, at the point of drawing.
local function mk_stroke(st, ox, oy, h, w, col, p)
    local x1, y1 = ox + st[1] * h, oy - st[2] * h
    local x2, y2 = ox + st[3] * h, oy - st[4] * h
    local ex, ey = x1 + (x2 - x1) * p, y1 + (y2 - y1) * p
    if st.wake then
        -- The flat cut keeps the top and bottom edges level as the wake grows.
        -- Its color stays solid from the bullet back to the starting point.
        u:seg_flat(x1, ry(y1), ex, ry(ey), w, col)
    else
        u:seg(x1, ry(y1), ex, ry(ey), w, col)
    end
    return ex, ey
end

-- One row gets its own bullet and clock cursor. Both rows are called with the
-- same elapsed time, so they fall, bounce, rise and hop together.
local function logo_row(ox, oy, h, w, hue, t, alpha)
    local bx, by, bcol
    for i, st in ipairs(MK_STROKES) do
        local span = st.wake and MK_FALL or MK_RISE
        local col = hue[st.wedge + 1]
        if t >= span then
            mk_stroke(st, ox, oy, h, w, col, 1)
            t = t - span
            -- A bounce off the baseline, and the hop across to the next wedge
            -- at the top. Neither draws any of the mark; the first is a flash
            -- where the bullet turned and the second is the bullet in transit.
            if st.wake then
                if t < MK_FLASH then
                    local f = 1 - t / MK_FLASH
                    u:ring(ox + st[3] * h, ry(oy), h * 0.10 * (1.6 - f),
                           math.max(1 * S, w * 0.5 * f), 12,
                           pal.a(pal.hot(col, 0.5), alpha * f * 0.9))
                end
            elseif i < #MK_STROKES then
                if t < MK_HOP then
                    local nx = MK_STROKES[i + 1][1]
                    local f = t / MK_HOP
                    bx = ox + (st[3] + (nx - st[3]) * f) * h
                    by = oy - h
                    bcol = pal.a(pal.DIM, alpha * 0.7)
                    break
                end
                t = t - MK_HOP
            end
        else
            bx, by = mk_stroke(st, ox, oy, h, w, col, math.max(0, t) / span)
            bcol = pal.a(pal.hot(col, 0.65), alpha)
            break
        end
    end
    return bx, by, bcol
end

-- The bullet is the same dot the corner draws on the end of a gun's line,
-- with its glow stepped out of discs rather than taken from `halo`.
local function logo_bullet(bx, by, w, bcol)
    if bx then
        local a = bcol[4] or 1
        u:disc(bx, ry(by), w * 3.0, 12, pal.a(bcol, a * 0.16))
        u:disc(bx, ry(by), w * 1.9, 10, pal.a(bcol, a * 0.30))
        u:disc(bx, ry(by), w * 1.15, 10, bcol)
    end
end

-- `h` is the full two-row height and (cx, cy) its center. `still` draws the
-- finished shape and nothing else, which is what anything not on the menu
-- wants.
function M.logo(cx, cy, h, alpha, still)
    alpha = alpha or 1
    local rh = h * MK_ROW
    local ox = cx - M.logo_width(h) / 2
    local top = cy - h / 2
    local oy = {top + rh, top + 2 * rh + h * MK_ROW_GAP}
    local w = math.max(1 * S, rh * MK_WEIGHT)
    local hue = {
        {pal.a(pal.ENEMY, alpha), pal.a(pal.MARK_MUTED, alpha),
         pal.a(pal.MARK_MUTED, alpha)},
        {pal.a(pal.MARK_MUTED, alpha), pal.a(pal.FRIEND, alpha),
         pal.a(pal.FRIEND, alpha)},
    }

    if not still and M.now - logo_seen > 0.25 then logo_t0 = M.now end
    if not still then logo_seen = M.now end
    local t = still and math.huge or (M.now - logo_t0)

    for row = 1, 2 do
        local bx, by, bcol = logo_row(ox, oy[row], rh, w, hue[row], t, alpha)
        logo_bullet(bx, by, w, bcol)
    end
end

-- The mark and the name, and nothing under them.
--
-- Not a logotype: the same face the menu is set in, at a size nothing else on
-- screen is, with the drawn mark beside it. A stroke ran under the pair for a
-- while, a wake that swelled and faded across the width of the panel. It was
-- decoration in an interface that has none anywhere else, and every shape of
-- it that was tried, swelling from both ends and then solid into a tail, read
-- as a rule somebody had left there rather than as part of the name.
-- How tall the mark stands, against the type it sits beside, and how much air
-- goes between them.
--
-- 0.74 em is a shade over the cap height of the face the name is set in. The
-- mark reads as belonging to the word at that size, and as a picture beside a
-- caption above it: the first draft stood a full em and a bit tall and lifted
-- itself a third of an em besides, which put its weight above the line the
-- word sits on and made the lockup look assembled by accident.
-- And how far below the line the mark sits.
--
-- Not zero, which is what "centered" would suggest and what this had. `txt`
-- centers a string in its line box, and a line box has room under the
-- baseline for descenders. "vectorwake" is all lowercase and has none, so its
-- ink stops at the baseline and its weight sits lower still, in the x-height
-- band: measured off a screenshot, the type runs from 143 to 171 with the
-- x-height starting at 151, which puts what the eye reads as the middle of
-- the word about an eighth of an em below the middle of the box it is set in.
-- A mark hung on the box center is a mark that looks high, which is what it
-- looked.
local LOGO_EM, LOGO_GAP, LOGO_DROP = 0.74, 0.30, 0.12

local function wordmark(x, y, size)
    -- The mark stands to the left of the name, on the middle of the word
    -- rather than the middle of its line box, so the two read as one lockup.
    -- It takes the room it needs and the name starts after it.
    local h = size * LOGO_EM
    local lw = M.logo_width(h)
    M.logo(x + lw / 2, y + size * LOGO_DROP, h)
    txt("vectorwake", x + lw + size * LOGO_GAP, y, size, pal.INK, nil,
        MENU_FONT, true)
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
    local icon_dy                  -- the icon's drop inside it, narrow only
    local sx, sy, sw, sh           -- the stage
    local logo_y                   -- the middle of the name, both layouts
    -- What the panel covers, name included: everything a press may land on
    -- without meaning to leave. Published as one box at the end, so the
    -- gaps between rows are not a way out of the menu.
    local px0, py0, px1, py1
    local vertical = not narrow

    if vertical then
        local total = math.min(W - SL - SR - 2 * margin, 940 * S)
        local x0 = SL + (W - SL - SR - total) / 2
        -- Clear of what the ship is carrying. Over a game the corner stack
        -- holds the left edge, and on a phone held sideways a centered block
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
        -- was the short window's layout, on the argument that eight labeled
        -- stops do not fit a phone held sideways; they fit, and with no title
        -- over the stage the lit word is the only thing on screen that says
        -- which page this is.
        rw = 150 * S
        -- A stop is 38 points at least, so a thumb has something to land on,
        -- and 58 at most, so six of them in a tall window do not drift apart
        -- into a list of unrelated things.
        --
        -- The floor gives way before the screen edge does, which it did not
        -- until a test drew the rail at its real length. Eight stops is what a
        -- pilot in a game with sides gets, and at 38 apiece that is 304 points
        -- of rail on a phone held sideways with 390 of screen: the last stops
        -- ran off the bottom, where a thumb cannot reach them at all. A small
        -- target is worse than a comfortable one and better than none.
        local room = H - head - 3 * margin - STAGE_TOP * S
        local pitch = math.min(math.max(room / n, 38 * S), 58 * S)
        if pitch * n > room then pitch = room / n end
        rh = pitch * n
        -- The rail hangs from the top of the block, starting where the stage's
        -- first row starts. Centered in the block instead, six stops in a tall
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
        logo_y = top - head + 30 * S
        wordmark(x0, logo_y, (tall and 40 or 30) * S)
        -- What you are reading, laid over what you are not. A wash rather
        -- than a panel: no border, no corners, just enough that the type sits
        -- on something and the arena stays visible round the edges of it.
        rect(x0 - 18 * S, top - 16 * S, total + 36 * S, block + 30 * S,
             pal.rgb(0x03050a, 0.5))
        -- Up to the name, which stands above the wash and is part of the
        -- panel to anybody looking at it.
        px0, py0 = x0 - 18 * S, top - head
        px1, py1 = px0 + total + 36 * S, top - 16 * S + block + 30 * S
        -- The rule the whole thing hangs off, between the rail and the stage.
        vrule(x0 + rw + 1 * S, top, block, pal.a(pal.RADAR_TILE, 0.75), 30 * S)
    else
        rh = (home and 78 or 84) * S
        rw = W - SL - SR - 2 * margin
        rx = SL + margin
        -- A tab bar, sitting where one sits: on the bottom edge, with the
        -- surface running under the home indicator and only the icons and
        -- words held clear of it.
        --
        -- The inset stands in for the padding the block already keeps rather
        -- than stacking on top of it. Stepping the whole rail up by the whole
        -- inset put the words 56 points off the bottom of a phone, which is
        -- the same interface-come-loose-from-the-edge the page margin used to
        -- give, and is what a hardware inset looks like when it is added to a
        -- gap that was already there.
        icon_dy = (home and 30 or 32) * S
        local under = rh - icon_dy - 24 * S
        if SAPP then
            -- Installed, the padding under the words is measured against the
            -- indicator rather than against the rail, because the indicator
            -- is the only thing down there and the rail's own idea of a
            -- bottom margin was written for a row with a toolbar under it.
            -- Two thirds of the strip is what the bar and its own margin
            -- take; the rest was the row sitting higher than it had to, and
            -- it goes back. On a large phone the rail's padding grows with
            -- the interface while the indicator stays 34 points whatever the
            -- screen, so this gives back more the bigger the phone, which is
            -- where the gap looked worst.
            ry_ = H - rh + math.max(0, under - SB * 0.56)
        else
            ry_ = H - rh - math.max(0, SB - under)
        end
        sx, sw = SL + margin, rw
        -- Under the chip row over a game: MENU and PLAYERS hold the top left
        -- corner while the arena is live, and the name drawn into them is two
        -- things in one place.
        local chip = home and 0 or 34 * S
        sy = ST + margin + head + chip
        sh = ry_ - 20 * S - sy
        -- Down to the bottom edge, rather than to the rail plus a margin
        -- that is no longer there: the wash is what the panel sits on, and a
        -- strip of bare arena under the rail reads as the panel having come
        -- loose from the screen.
        rect(0, sy - 16 * S, W, H - (sy - 16 * S), pal.rgb(0x03050a, 0.5))
        logo_y = ST + margin + chip + 22 * S
        wordmark(rx, logo_y, 30 * S)
        -- The whole screen from the name down. A phone's menu is the screen,
        -- so there is next to nothing outside it, which is the right answer
        -- there: the way out is the x and the lit rail stop.
        px0, py0 = 0, logo_y - 20 * S
        px1, py1 = W, H
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
        -- Where a pointer is resting, which at the root is the stop the
        -- cursor is already on and one level in is a second mark saying what
        -- a click would land on. The stage has worn this since the home
        -- screen was two panes; the rail is the other half of the same
        -- gesture and went without it.
        local hot = (i == v.rail_hover) and not sel
        local cx, cy
        if vertical then
            cx = rx + 26 * S
            cy = ry_ + (i - 0.5) * pitch
        else
            cx = rx + (i - 0.5) * pitch
            cy = ry_ + icon_dy
        end
        local col = (sel or hot) and pal.FRIEND or pal.a(pal.DIM, 0.9)
        local r = 13 * S
        if hot then
            -- The stage's own hover weight, and only the field: the lit rule
            -- beside a selected stop says which page the panel belongs to,
            -- and a pointer passing over says nothing of the kind.
            local warm = pal.a(pal.FRIEND, 0.16)
            if vertical then
                rect(rx - 6 * S, cy - pitch / 2 + 3 * S,
                     rw + 6 * S, pitch - 6 * S, warm)
            else
                rect(cx - pitch / 2 + 3 * S, ry_, pitch - 6 * S, H - ry_, warm)
            end
        end
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
                --
                -- Down to the edge of the screen rather than to the end of
                -- the block, so the lit stop is a tab reaching the bottom of
                -- the phone and not a panel floating above the indicator.
                rect(cx - pitch / 2 + 3 * S, ry_, pitch - 6 * S, H - ry_, lit)
            end
        end
        draw_mark(e.icon, cx, cy, r, col, v.class or 0)
        if vertical then
            txt(e.label, rx + 48 * S, cy, 16 * S,
                pal.a((sel or hot) and pal.INK or pal.DIM,
                      (sel or hot) and 1 or 0.85),
                nil, MENU_FONT)
        elseif not vertical then
            txt(e.label, cx, cy + 24 * S, label_px,
                pal.a((sel or hot) and pal.FRIEND or pal.DIM,
                      (sel or hot) and 1 or 0.8),
                "center", MENU_FONT)
        end
        -- The rail's own action: it names a destination, not a row of
        -- whatever page is on the stage.
        if vertical then
            hit(rx - 6 * S, cy - pitch / 2, rw + 10 * S, pitch, "rail", i)
        else
            hit(cx - pitch / 2, ry_ - 8 * S, pitch, H - ry_ + 8 * S, "rail", i)
        end
    end

    -- --- the stage
    -- Everything with type in it hangs off `tx`, a gutter in from the stage's
    -- own left edge: the rule at the head of it, and every row's label. A
    -- row's field starts back at `sx`, so what is lit reaches under the mark
    -- and the words never sit against the edge of it.
    local tx = sx + GUTTER * S
    local avail = sw - GUTTER * S
    -- The stage is the stage, whatever is on it. A list used to be capped at
    -- 520 points against a row reading as two columns a screen apart, which
    -- was a rule written for a window rather than for this panel: the block
    -- is already held to 940, so the widest a row can ever be is about 740,
    -- and the cap bought nothing but a ragged right edge. It ended a couple
    -- of hundred points short of the x, the rule and the scrollbar, and the
    -- pages that are drawings rather than lists went to the edge beside it.
    --
    -- What is kept is a column at the right for the scroll tick, whether or
    -- not there is one to draw, so a list does not shift sideways the moment
    -- it outgrows the page. It puts a row's count directly under the x.
    local lw = avail - 14 * S
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
    --
    -- On the name's own line, at the far end of it. It sat at the top of the
    -- stage, which on the desktop layout is a third of the way down the panel
    -- and level with nothing: a dialog's x belongs on the dialog's title, and
    -- here the title is the name. Same line in both layouts, since the name is
    -- in both.
    -- At the far end of that line, which is the block's own edge rather than
    -- the list's: the list is capped at 520 points and the x hung off the end
    -- of it, which was the right place under a heading and is a mark adrift
    -- in the middle of a title.
    if v.closable then
        close_mark(sx + sw - 8 * S, logo_y, pal.a(pal.DIM, 0.9), 11 * S)
        hit(sx + sw - 30 * S, logo_y - 12 * S, 40 * S, 24 * S, "close")
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

    -- One line at the foot of the stage: why something did not work. Nothing
    -- otherwise, which is nearly always.
    --
    -- It used to fall back to naming the keys, which is a caption on a rail
    -- whose whole argument is that a lit mark says where you are without one,
    -- and it was drawn on a phone that has none of those keys under a list you
    -- get around by touching it. Then it carried a sentence about the row
    -- under the cursor, and those turned out to be captions too, restating the
    -- row they sat under and moving every time the cursor did. What is left is
    -- the one thing that was never a label on anything: something that just
    -- happened.
    if v.note then
        txt(v.note, tx, sy + sh - 4 * S, 12 * S, pal.a(pal.HURT, 0.95))
    end

    -- A press that missed everything is a press on the arena behind, and over
    -- a game that means put me back in it, which is what escape does and what
    -- a hand reaches for after opening this by accident. Two boxes: the panel
    -- swallows its own, so the space between two rows is not a way out, and
    -- everything left over is one.
    --
    -- Published here because the first box a press lands in wins and every
    -- control on the panel has already had its turn. The instruments behind
    -- are published before the menu is drawn at all, so a dimmed scoreboard
    -- row still answers to a click rather than being a hole in the way out.
    if v.closable then
        hit(px0, py0, px1 - px0, py1 - py0, "panel")
        hit(0, 0, W, H, "close")
    end

    -- Last, over all of it, because it is the only thing being read.
    -- It takes the screen, boxes included: a question is answered, not
    -- clicked past.
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
