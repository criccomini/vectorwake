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
local keyset = require("arena.keys")
local marks = require("arena.marks")
local state = require("arena.state")
local ui_frame = require("arena.ui_frame")
local ui_payouts = require("arena.ui_payouts")
local world = require("arena.world")

local M = {}
local F = ui_frame.new(state)
-- The HUD stays up under the menu, so its hit boxes do too, and the first box
-- a press lands in wins. A dial the size of a quarter of the frame would sit
-- over half the menu and swallow every row behind it.

-- Metrics, in CSS pixels before the density scale.
local PAD = 14
local PANEL_X, PANEL_Y = 12, 10
local FONT = 13
-- The menu's own face, against the mono everything in flight is set in. Up
-- here with the other constants because both the controls page and the stage
-- rows below it set type in it.
local MENU_FONT = "menu"
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
    return F:ry(y, h)
end

local function rect(x, y, w, h, col)
    F.layer:rect(x, ry(y, h), w, h, col)
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
-- Which voice the interface is speaking in. The HUD is read at a glance, over
-- a fight, out of the corner of an eye, and capitals are the case an
-- instrument is labeled in. The menu is read rather than glanced at, and a
-- page of capitals is a page nobody reads twice, so it takes a sentence's
-- case: one capital at the front and nothing else shouting.
--
-- Set by whichever of the two is drawing. Done here rather than in the
-- strings themselves, because case is how a thing is set rather than what it
-- says, and the model has no business shouting.
local function cased(s)
    if F.case == "upper" then return string.upper(s) end
    return (string.gsub(s, "^%l", string.upper))
end

-- `raw` is for the handful of strings the interface is quoting rather than
-- saying: somebody's name, a key they have to type on another machine, the
-- address an operator has to read back, the commit a build was made from, and
-- the wordmark, which is a drawing of a name rather than a label.
local function txt(s, x, y, px, col, pivot, font, raw)
    if not raw then s = cased(s) end
    F.text_count = F.text_count + 1
    local t = F.text[F.text_count]
    if not t then t = {} F.text[F.text_count] = t end
    t.s, t.x, t.y, t.px, t.col, t.pivot =
        s, x, F.h - y, px, col, pivot or "left"
    t.font = font
    t.dim = F.text_dim ~= 1 and F.text_dim or nil
end

-- The small label the mocks head every group with: mono, upper, dim, and
-- tiny. It is the one piece of type in this interface that is neither a name
-- nor a number, and it is drawn raw because it is already in the case it
-- wants and the menu is otherwise set in a sentence's.
local function lbl(s, x, y, col, align, px)
    txt(string.upper(s or ""), x, y, px or 9 * F.scale,
        col or pal.a(pal.DIM, 0.9), align, nil, true)
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
    arm = arm or 14 * F.scale
    chamfer = chamfer or 5 * F.scale
    for _, c in ipairs({{x, y, 1, 1}, {x + w, y, -1, 1},
                        {x + w, y + h, -1, -1}, {x, y + h, 1, -1}}) do
        local cx, cy, sx, sy = c[1], c[2], c[3], c[4]
        F.layer:seg(cx + sx * chamfer, ry(cy), cx + sx * arm, ry(cy), F.scale, col, true)
        F.layer:seg(cx, ry(cy + sy * chamfer), cx, ry(cy + sy * arm), F.scale, col, true)
        F.layer:seg(cx + sx * chamfer, ry(cy), cx, ry(cy + sy * chamfer), F.scale, col,
              true)
    end
end

-- A lit rule with the light falling off one side of it, which is a wall face
-- stood on end. Everything in a column hangs off one of these.
local function vrule(x, y, h, col, spill)
    F.layer:skirt(x, ry(y), x, ry(y + h), (spill or 26 * F.scale), 0, 0.07, col)
    F.layer:seg(x, ry(y), x, ry(y + h), 1.4 * F.scale, col)
end

-- The map border's tick, used as a rule between things.
local function ticks(x, y, w, col, pitch)
    pitch = pitch or 12 * F.scale
    F.layer:seg(x, ry(y), x + w, ry(y), 0.8 * F.scale, pal.a(col, (col[4] or 1) * 0.7))
    local n = math.max(1, math.floor(w / pitch))
    for k = 0, n do
        local px = x + w * k / n
        F.layer:seg(px, ry(y - 2.5 * F.scale), px, ry(y), 0.8 * F.scale, col)
    end
end

-- A selection: bright where it meets its rule and gone across the row. It was
-- a filled rectangle.
local function wash(x, y, w, h, col)
    F.layer:skirt(x, ry(y), x, ry(y + h), w, 0, col[4] or 0.14, col)
end

-- A count, as marks rather than as a number: it reads at a glance and never
-- asks the eye to parse a digit.
local function pips(x, y, n, filled, col, r, pitch)
    r = r or 2.2 * F.scale
    pitch = pitch or 7.5 * F.scale
    for k = 0, n - 1 do
        local px = x + k * pitch
        if k < filled then
            F.layer:disc(px, ry(y), r, 8, col)
        else
            F.layer:ring(px, ry(y), r, 0.9 * F.scale, 8, pal.a(col, (col[4] or 1) * 0.3))
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
    F.layer:seg(cx - half * HELM_COLLAR, ry(neck), cx + half * HELM_COLLAR, ry(neck),
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
    F.layer:outline(pts, line, col, true)
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
    F.layer:seg(x0, ry(y0), x0 + w, ry(y0), line, col, true)
    F.layer:seg(x0, ry(y0 + line / 2), x0, ry(neck - line / 2), line, col)
    F.layer:seg(x0 + w, ry(y0 + line / 2), x0 + w, ry(neck - line / 2), line, col)
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
    k = k or MARK_K * F.scale
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
            F.layer:quad(px, ry(pty), x, ry(ty), x, ry(by), px, ry(pby), col)
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
    k = k or MARK_K * F.scale
    local cx = x + k / 2
    local x0, y0, w, _, mid, r = hull_helm(cx, y, k, col, line)
    -- The middle of the box rather than the middle of the circle it used to
    -- be: a flat crown puts the room the dome was using back into the shell,
    -- and lamps left where they were sat in the bottom third of it.
    local eye = mid - r * 0.16
    F.layer:disc(x0 + w * 0.31, ry(eye), w * 0.115, 8, col)
    F.layer:disc(x0 + w * 0.69, ry(eye), w * 0.115, 8, col)
    F.layer:seg(cx, ry(y0), cx, ry(y0 - r * 0.36), line or pen(k, 0.09), col, true)
    F.layer:disc(cx, ry(y0 - r * 0.48), w * 0.11, 8, col)
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
        txt(tostring(bots), right, y, 12 * F.scale, pal.a(pal.DIM, 0.9), "right")
        bot_mark(right - text_w(tostring(bots), 12 * F.scale) - 16 * F.scale, y,
                 pal.a(pal.DIM, 0.75))
        right = right - text_w(tostring(bots), 12 * F.scale) - 26 * F.scale
    end
    local pc = players > 0 and col or pal.a(pal.DIM, 0.8)
    txt(tostring(players), right, y, 13 * F.scale, pc, "right")
    -- A helmet rather than the plain dot this used to draw. The dot said
    -- "some number of somethings" and left the row's two counts looking like
    -- a bullet and a picture; the pair is one shell now, and which of them a
    -- player is looking at is the face in it.
    pilot_mark(right - text_w(tostring(players), 13 * F.scale) - 12 * F.scale, y, pc)
end


local KEY_H, KEY_PAD, KEY_GAP = 26, 9, 6
local function key_size() return (FONT - 1) * F.scale end
local function key_w(label) return text_w(label, key_size()) + 2 * KEY_PAD * F.scale end
local function key_frame(x, y, w, on)
    local col = on and pal.FRIEND or pal.DIM
    local h = KEY_H * F.scale
    rect(x, y, w, h, pal.a(col, on and 0.16 or 0.07))
    F.layer:frame(x, ry(y, h), w, h, 1.1 * F.scale, pal.a(col, on and 0.95 or 0.55))
    return col, h
end
local function key_cap(x, y, w, label, on)
    local col, h = key_frame(x, y, w, on)
    -- A key is shouted wherever it turns up, menu or corner: it is a thing to
    -- press rather than something the interface is saying, and the two of them
    -- are the same object.
    txt(string.upper(label), x + w / 2, y + h / 2, key_size(),
        pal.a(col, on and 1 or 0.85), "center", nil, true)
end

-- PLAYERS carries the room's composition with it. The helmet and machine are
-- the same marks the directory and scoreboard already use, kept inside the
-- one key rather than hung off it as another piece of HUD chrome.
local function players_cap(x, y, on, humans, bots)
    local size, count_size = key_size(), (FONT - 2) * F.scale
    local label = "PLAYERS"
    local human, bot = tostring(humans), tostring(bots)
    local mark = 10 * F.scale
    local label_gap, mark_gap, group_gap = 10 * F.scale, 4 * F.scale, 9 * F.scale
    local w = 2 * KEY_PAD * F.scale + text_w(label, size) + label_gap
        + mark + mark_gap + text_w(human, count_size) + group_gap
        + mark + mark_gap + text_w(bot, count_size)
    local col, h = key_frame(x, y, w, on)
    local mid = y + h / 2
    local at = x + KEY_PAD * F.scale
    local cap_col = pal.a(col, on and 1 or 0.85)
    txt(label, at, mid, size, cap_col, nil, nil, true)
    at = at + text_w(label, size) + label_gap

    pilot_mark(at + mark / 2, mid, cap_col, mark)
    at = at + mark + mark_gap
    txt(human, at, mid, count_size, cap_col)
    at = at + text_w(human, count_size) + group_gap

    bot_mark(at, mid, cap_col, mark)
    at = at + mark + mark_gap
    txt(bot, at, mid, count_size, cap_col)
    return w
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
    k = k or 9 * F.scale
    local out = k / 2
    local inn = k * 0.17
    local d = 0.7071
    for _, s in ipairs({{1, 1}, {1, -1}, {-1, 1}, {-1, -1}}) do
        local dx, dy = s[1] * d, s[2] * d
        F.layer:seg(x + dx * inn, ry(y + dy * inn),
              x + dx * out, ry(y + dy * out), 1.25 * F.scale, col, true)
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
local function zone(key, x, y, w, h)
    F.zones[#F.zones + 1] = {key = key, x = x, y = y, w = w, h = h}
end

-- Which row covers this point, or nil. Last registered wins, so a row inside
-- a panel beats the panel: the corner stack files a zone per row.
function M.row_at(x, y)
    if not x or not y then return nil end
    local found = nil
    for _, z in ipairs(F.zones) do
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
function M.safe(l, r, t, b, app)
    F:safe(l, r, t, b, app)
end

-- `now` is the frame's clock in seconds, for the few things on screen that
-- move on their own. Nothing that is laid out depends on it, so a caller with
-- no clock draws the same interface at rest.
function M.begin(layer, w, h, density, touching, now)
    F:begin(layer, w, h, density, now)
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
    -- The marks draw into the same layer, and the pads reach for them after
    -- this returns, so they are handed it here rather than by each caller.
    marks.begin(layer, density)
    M.touching = touching or false
    M.hits = {}
    -- The lines the page is asked to hold, if any card raised this frame
    -- asks for typing. Cleared here rather than by whoever raised it, for
    -- the reason the hit list is: a card that is no longer drawn has no
    -- lines, and the way to say so is to stop saying otherwise.
    M.ask_dom = nil
    M.link_dom = nil
end

function M.finish()
    F:finish()
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
    local pad = (M.compact and 8 or PAD) * F.scale
    local side = RADAR * F.scale
    if M.map then
        side = math.max(side,
                        math.min(math.min(F.w, F.h) * 0.66, F.h * 0.66,
                                 F.w - F.safe_r - pad - math.max(chip_right + 8 * F.scale,
                                                         124 * F.scale)))
    end
    -- Whole pixels. The dial snaps its contents to its own origin, so an
    -- origin landing on a half pixel would put the fraction back into every
    -- blip it was taken out of. Density is not always a whole number and
    -- neither, then, is the padding.
    local ix, iy = math.floor(F.w - F.safe_r - pad - side),
                   math.floor(F.safe_t + pad + 18 * F.scale)
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
    return F.safe_t + PAD * F.scale * 2 + side + 18 * F.scale
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
    local edge = 5 * F.scale
    if ax < ox + edge then ax = ox + edge end
    if ay < oy + edge then ay = oy + edge end
    if ax > ox + side - edge then ax = ox + side - edge end
    if ay > oy + side - edge then ay = oy + side - edge end
    local a = (sim.ship_heading(me) / 65536) * math.pi * 2
    local dx, dy = math.sin(a), -math.cos(a)
    local nose, back, wide = 6.5 * F.scale, 3.4 * F.scale, 3.2 * F.scale
    F.layer:disc(ax, ry(ay, 0), 7 * F.scale, 12, pal.a(pal.WHITE, 0.14))
    F.layer:tri(ax + dx * nose, ry(ay + dy * nose, 0),
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
    if not F.menu_up then hit(ix, iy, r, r, "map") end

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
    local dot = math.max(1, math.floor(math.max(2 * 16 * k, 1.5 * F.scale) + 0.5))
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

    local my_team = view_team
    for i = 0, sim.flag_count() - 1 do
        local fx, fy, team = sim.flag_at(i)
        local px, py = put(fx, fy)
        if px then
            local col = (team == 255) and pal.INK
                or (team == my_team and pal.FRIEND or pal.ENEMY)
            -- A pennant rather than a bar: a flag should look like one even
            -- at four pixels.
            F.layer:seg(px, ry(py + 3 * F.scale, 0), px, ry(py - 3.5 * F.scale, 0), F.scale,
                  pal.a(col, 0.95))
            F.layer:tri(px, ry(py - 3.5 * F.scale, 0), px + 4 * F.scale, ry(py - 2 * F.scale, 0),
                  px, ry(py - 0.5 * F.scale, 0), pal.a(col, 0.9))
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
                F.layer:disc(px, ry(py, 0), 4.6 * F.scale, 10, pal.a(col, 0.13))
                local d = 2.6 * F.scale
                F.layer:quad(px, ry(py - d, 0), px + d, ry(py, 0),
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
    -- rather than a preference about panels. At the radar's 0.55 whatever
    -- lies under the dial comes through it at half strength, in the one place
    -- a player would read it as part of the map.
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
    bracket(ix, iy, side, side, pal.a(pal.RADAR_TILE, 0.8), 22 * F.scale)
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
    if not F.menu_up then hit(ix, iy, side, side, "map") end
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
local payouts = ui_payouts.new()

-- Raised by whoever drains the kills. World coordinates, because that is
-- where the wreck is.
function M.payout(x, y, n)
    payouts:add(F.now, x, y, n)
end

-- A new arena is not the one the last number was earned in. Cheap to call and
-- it costs nothing when there is nothing to drop.
function M.clear_payouts()
    payouts:clear()
end

-- Where a world position lands on the glass. One formula, two callers: a
-- pilot's nameplate and the bounty that drifts off their wreck are the same
-- conversion, and they were the same two lines twice.
local function on_glass(o, scale, x, y)
    return F.w / 2 + (x - o.cam_x) * scale, F.h / 2 + (y - o.cam_y) * scale
end

local function nameplates(o)
    if not o.half_w or o.half_w <= 0 then return end
    -- The render script publishes its own half-extents for exactly this, so
    -- that nothing keeps a second copy of the projection. Deriving one from
    -- the view_tiles setting put every name adrift the moment the camera
    -- stopped being driven by that setting -- which it already had.
    local scale = F.w / (2 * o.half_w)
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
            local sx, sy = on_glass(o, scale, sim.ship_x(i), sim.ship_y(i))
            -- A name for a ship nobody can see is a name in the corner of
            -- the screen attached to nothing.
            if sx > -40 and sx < F.w + 40 and sy > -30 and sy < F.h + 30 then
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
                    txt(nm, sx + 12 * F.scale, sy + 13 * F.scale, 11 * F.scale, pal.a(col, 0.7),
                        nil, nil, true)
                    -- The same mark the scoreboard wears, on the hull itself:
                    -- who is flying a ship is worth knowing while you are
                    -- deciding whether to chase it, and that decision is made
                    -- looking at the ship rather than at a panel. Dim and
                    -- after the name, so it reads as a note about the label
                    -- and never competes with the bounty under it.
                    if p then
                        -- A mark set four points off the last letter reads as
                        -- the end of the name rather than as a thing beside
                        -- it, and a call sign is exactly the kind of string
                        -- somebody will end in a bracket or a dot.
                        local mx = sx + 12 * F.scale
                            + text_w(nm, 11 * F.scale) + 9 * F.scale
                        if p.ai then
                            bot_mark(mx, sy + 13 * F.scale,
                                     pal.a(col, 0.45), 10 * F.scale)
                        else
                            pilot_mark(mx + 5 * F.scale, sy + 13 * F.scale,
                                       pal.a(col, 0.45), 10 * F.scale)
                        end
                    end
                    if bty > 0 then
                        -- In the side's color rather than the bounty gold,
                        -- so the name and the number under it read as one
                        -- label belonging to one squad. Gold said "this is a
                        -- bounty", which the position under a name already
                        -- says, and it said it identically for every pilot on
                        -- screen: the one thing a color here can carry is
                        -- whose they are.
                        txt(tostring(bty), sx + 12 * F.scale, sy + 25 * F.scale, 11 * F.scale,
                            pal.a(col, 0.85))
                    end
                end
            end
        end
    end

    -- The payouts, drifting off the wrecks that paid them. Walked backwards
    -- into itself so an expired one is dropped in the same pass that draws
    -- the rest, and the list stays as short as the killing is fast.
    payouts:each(F.now, function(p, f, a)
            local px, py = on_glass(o, scale, p.x, p.y)
            -- The payout's own size and offset, in the green the feed
            -- already uses for a line about a kill of yours. Up is negative
            -- here: the name sits at +13 and the payout at +25, under it.
            txt("+" .. p.n, px + 12 * F.scale,
                py + 13 * F.scale - ui_payouts.RISE * F.scale * f,
                11 * F.scale, pal.a(pal.PAID, 0.95 * a), nil, nil, true)
    end)

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
    return LINE * F.scale
end

-- Where the scoreboard starts: under the menu chip when there is one, since
-- the chip owns the corner.
local function top_y()
    return F.safe_t + PAD * F.scale + 32 * F.scale
end

-- Two names, in the order a person reads them. Lowercased for the comparison
-- so a capital cannot jump a pilot to the top of the room, and the raw name
-- breaks a tie so the order is total and the list cannot flicker between two
-- pilots who differ only in case. The games list orders itself the same way.
-- The lowercased form is put on the row when the row is filled rather than
-- worked out here: this runs on both sides of every comparison, which is a
-- few hundred of them each frame the panel is open, to lower the same handful
-- of names over and over.
local function ahead(a, b)
    if a.lname ~= b.lname then return a.lname < b.lname, true end
    if a.name ~= b.name then return a.name < b.name, true end
    return false, false
end

-- Which column the scoreboard is sorted by, and the order that column asks
-- for. Written just before the sort and read inside it, so the comparator can
-- be one function built once rather than a fresh closure over the column every
-- frame the panel is up.
local sort_key = nil

local function by_column(a, b)
    -- Watchers last, under everybody who is actually flying, whatever column
    -- is chosen. They have no score to sort by and sorting them into the
    -- middle of a scoreboard by a zero would read as a pilot doing badly
    -- rather than as somebody not playing.
    if a.watch ~= b.watch then return b.watch end
    if a.mine ~= b.mine then return a.mine end
    if sort_key == "name" then
        local first, differ = ahead(a, b)
        if differ then return first end
    elseif sort_key == "kills" then
        if a.k ~= b.k then return a.k > b.k end
    elseif sort_key == "bounty" then
        if a.b ~= b.b then return a.b > b.b end
    elseif sort_key == "deaths" then
        -- Fewest first: on every other column the top of the list is the
        -- pilot doing best, and this is the one where that means less.
        if a.d ~= b.d then return a.d < b.d end
    else
        if a.p ~= b.p then return a.p > b.p end
    end
    if a.p ~= b.p then return a.p > b.p end
    if a.k ~= b.k then return a.k > b.k end
    return (ahead(a, b))
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
    local w = COL_W * F.scale
    local head = 24 * F.scale
    local rowh = LINE * F.scale
    local h = head + shown * rowh + 8 * F.scale
    local x = F.safe_l + PAD * F.scale
    local y = top_y()
    rect(x, y, w, h, pal.a(pal.BG, 0.62))
    vrule(x, y, h, pal.a(pal.RADAR_TILE, 0.7))
    txt("ROOMS", x + 12 * F.scale, y + 15 * F.scale, (FONT - 2) * F.scale, pal.a(pal.INK, 0.75))
    -- The zone, once, at the head. The rows are numbers and a number needs
    -- saying what it is a number of; the corner chip has no space for it and
    -- this does.
    txt(M.zone_name or "", x + w - 12 * F.scale, y + 15 * F.scale, (FONT - 3) * F.scale,
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
            wash(x + 1 * F.scale, ry0, w - 2 * F.scale, rowh, pal.a(pal.FRIEND, 0.13))
            col = pal.FRIEND
        end
        txt("ROOM " .. rm.n, x + 12 * F.scale, mid, (FONT - 1) * F.scale, col)
        population(x + w - 12 * F.scale, mid, rm.players, rm.bots,
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
        local bar = math.max(10 * F.scale, track * (shown / n))
        local at = (M.room_scroll / math.max(1, n - shown)) * (track - bar)
        F.layer:seg(x + w - 3 * F.scale, ry(ty + at), x + w - 3 * F.scale, ry(ty + at + bar),
              2 * F.scale, pal.a(pal.RADAR_TILE, 0.8))
    end
    -- The whole panel takes the wheel, rather than a strip beside it, which is
    -- how the scoreboard behaves: a list is the thing you point at when you
    -- mean to scroll it. Published after the rows so a row wins the press.
    hit(x, y, w, h, "rooms_list")
    return y + h
end

-- Is this seat in the snapshot?
--
-- Snapshots carry only what this client could lawfully see, so a pilot on the
-- far side of the map is absent from the simulation and every number it holds
-- about them is a zero. The roster is the other half of the answer: it names
-- every seat in the arena twice a second and carries their totals for exactly
-- this reason.
--
-- One copy of the question, because it has been got wrong twice by being
-- asked in a second place: the draw-time read of the team byte painted every
-- out-of-sight name in team zero's violet, and the pilot box read the four
-- score lines straight out of the simulation and showed zeros for the seat
-- whose row, on the scoreboard behind it, showed the real numbers.
local function seat_here(i)
    return sim.ship_active(i) == 1
end

local function seat_team(i, p)
    return seat_here(i) and sim.ship_team(i) or (p and p.team)
end

-- Kills, deaths, points and bounty, whichever way round they have to be got.
local function seat_score(i, p)
    if seat_here(i) then
        -- The simulation for a seat we can see, because it lands twenty times
        -- a second and your own kill should appear the moment it happens.
        return sim.ship_kills(i), sim.ship_deaths(i),
               sim.ship_points(i), sim.ship_bounty(i)
    end
    return (p and p.k) or 0, (p and p.d) or 0,
           (p and p.p) or 0, (p and p.b) or 0
end

local function refresh_players(pilots, watchers, side, viewer_name)
    pilots = pilots or {}
    if side ~= nil then view_team = side end
    local n = 0
    for i = 0, sim.ship_count() - 1 do
        local p = pilots[i]
        -- `ship_count` is a high-water mark. A departed pilot leaves an
        -- inactive hole below it until somebody reuses that slot. The roster
        -- still names distant pilots whose filtered snapshot is inactive, so
        -- either source makes a row; an inactive slot named by neither is
        -- nobody and must not become a made-up "ship 51" pilot.
        if p or seat_here(i) then
            n = n + 1
            local r = rows[n]
            if not r then r = {} rows[n] = r end
            r.i = i
            -- Bounty is the one number on this row about the next thirty seconds
            -- rather than about the last hour.
            r.k, r.d, r.p, r.b = seat_score(i, p)
            r.name = (p and p.name) or ("ship " .. i)
            r.lname = string.lower(r.name)
            -- The roster's own flag. This used to look for a local bot object,
            -- which the client no longer flies and the server never sends, so the
            -- column was blank for every AI in a zone full of them.
            r.ai = (p and p.ai) or false
            -- What the zone is willing to say this seat is, which is a stronger
            -- statement than "AI" and is what the counts below are made of.
            r.label = (p and p.label) or "unknown"
            -- Kept on the row, because the drawing wants it too: reading the
            -- simulation again at draw time painted every out-of-sight name in
            -- team zero's color, one shared violet that reshuffled as pilots
            -- crossed into view.
            r.team = seat_team(i, p)
            r.mine = r.team == view_team
            r.self = viewer_name ~= nil and r.name == viewer_name
            r.watch = false
        end
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
        r.lname = string.lower(r.name)
        r.ai = w.label == "bot" or w.label == "bot?"
        r.label = w.label
        r.mine = false
        r.self = viewer_name ~= nil and r.name == viewer_name
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
    sort_key = M.sort
    table.sort(rows, by_column)
    return n
end

-- Move the scoreboard's existing selection by one pilot. Watchers stay in the
-- list but are skipped because they have no hull and no pilot card to select.
-- With no current selection, down starts at the top and up starts at the
-- bottom. The list does not wrap, which keeps Page Up and Page Down behaving
-- like movement rather than a cycle.
function M.player_step(delta, pilots, watchers, side, viewer_name)
    M.details = true
    local n = refresh_players(pilots, watchers, side, viewer_name)
    local choices = {}
    local selected = nil
    for i = 1, n do
        if rows[i].i ~= nil then
            choices[#choices + 1] = i
            if rows[i].i == M.inspect then selected = #choices end
        end
    end
    if #choices == 0 then
        M.inspect = nil
        M.scroll = 0
        return nil
    end

    if selected == nil then
        selected = delta < 0 and #choices or 1
    else
        selected = math.max(1, math.min(#choices, selected + (delta < 0 and -1 or 1)))
    end
    local at = choices[selected]
    M.inspect = rows[at].i
    if at <= M.scroll then M.scroll = at - 1 end
    if at > M.scroll + SHOWN then M.scroll = at - SHOWN end
    return M.inspect
end

local function scores(me, pilots, watchers, viewer_name)
    -- Asked for, not assumed. Mid-fight this is the least useful thing on the
    -- screen and the feed still says who is killing whom, so it lives behind
    -- the same toggle your own loadout does.
    if not M.details then return 0 end
    local n = refresh_players(pilots, watchers, nil, viewer_name)

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
    local w = COL_W * F.scale
    local head = 24 * F.scale
    -- Header, rows, and a line of totals under them.
    local foot = 16 * F.scale
    local h = head + shown * LINE * F.scale + foot + 8 * F.scale
    local x = F.safe_l + PAD * F.scale
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
    local small = (FONT - 3) * F.scale
    local num = (FONT - 2) * F.scale
    local GAP = 7 * F.scale
    local function col_w(field, label)
        -- Floored, because a column of single digits collapses to six points
        -- and its heading is the control that sorts by it: a target that
        -- narrow cannot be hit with a mouse, let alone a thumb.
        local wide = math.max(text_w(label, small), 16 * F.scale)
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
    local bx = x + w - 12 * F.scale
    local px = bx - bw - GAP
    local dx = px - pw - GAP
    local kx = dx - dw - GAP
    -- The marks sit in their own column left of the numbers rather than after
    -- each name, so a scan down the list finds them in a line instead of at a
    -- dozen different indents. The names end where that column begins.
    local mark_x = kx - kw - GAP - MARK_K * F.scale
    local name_x = x + 12 * F.scale
    local name_n = math.max(3, math.floor((mark_x - GAP - name_x) /
                                          (num * ADVANCE)))
    -- A heading is a control now, so the one in use is lit and the rest are
    -- not: the same way every other toggle in this interface says which way it
    -- is set.
    local function head_col(name, label, hx, align)
        local on = M.sort == name
        txt(label, hx, top_y() + 14 * F.scale, small,
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
    hit(x + 8 * F.scale, top_y() + 4 * F.scale, 60 * F.scale, 18 * F.scale, "sort_name")
    hit(kx - kw - GAP, top_y() + 4 * F.scale, kw + GAP, 18 * F.scale, "sort_kills")
    hit(dx - dw - GAP, top_y() + 4 * F.scale, dw + GAP, 18 * F.scale, "sort_deaths")
    hit(px - pw - GAP, top_y() + 4 * F.scale, pw + GAP, 18 * F.scale, "sort_points")
    hit(bx - bw - GAP, top_y() + 4 * F.scale, bw + GAP, 18 * F.scale, "sort_bounty")
    ticks(x + 12 * F.scale, top_y() + 20 * F.scale, w - 24 * F.scale,
          pal.a(pal.RADAR_TILE, 0.35), 14 * F.scale)

    local y = top_y() + head
    for i = 1 + M.scroll, math.min(n, M.scroll + shown) do
        local r = rows[i]
        local mine = r.self
        local reading = r.i ~= nil and M.inspect == r.i
        -- A watcher is on nobody's side, so it is drawn in neither side's
        -- color: the neutral ink, dimmer than a pilot, which is the reading.
        local col = pal.DIM
        if r.watch and mine then
            -- A watcher has no side-colored hull to borrow from. Their own row
            -- still wears the same cyan the pilot's own row does, so sitting
            -- out does not make the roster lose track of who is reading it.
            col = pal.FRIEND
        elseif not r.watch then
            -- The same color their plate wears out in the arena. A key is
            -- only a key if it reads the same in both places: a name orange
            -- here and violet on the hull is two facts about one pilot. From
            -- the row rather than the simulation, because the simulation only
            -- holds the seats inside this client's interest window and
            -- answers team zero for everybody else.
            col = team_col(r.team)
        end
        if mine or reading then
            -- Your row, marked the way a selected row is marked everywhere
            -- else in this interface: a lit rule and a wash off it, not a
            -- glyph in front of your name. The row being read about wears the
            -- same mark, in its own color, since it is a selection and this
            -- is how this interface draws one.
            local mark = reading and pal.BOUNTY or pal.FRIEND
            wash(x, y, w, LINE * F.scale, pal.a(mark, 0.13))
            F.layer:seg(x, ry(y), x, ry(y + LINE * F.scale), 1.6 * F.scale, pal.a(mark, 0.95))
        end
        local name = string.sub(r.name, 1, name_n)
        local cy = y + LINE * F.scale / 2
        txt(name, name_x, cy, num, pal.a(col, mine and 1.0 or 0.8),
            nil, nil, true)
        if r.ai then
            bot_mark(mark_x, cy, pal.a(pal.DIM, 0.75))
        else
            pilot_mark(mark_x + MARK_K * F.scale / 2, cy,
                       pal.a(pal.DIM, 0.75))
        end
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
            hit(x, y, w - 6 * F.scale, LINE * F.scale, "pilot", r.i)
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
        y = y + LINE * F.scale
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
    txt(line, x + 12 * F.scale, fy, (FONT - 4) * F.scale, pal.a(pal.DIM, 0.8))

    -- Only when there is something to scroll to. A bar on a list that fits is
    -- a control that does nothing.
    if n > shown then
        local track = shown * LINE * F.scale
        local ty = top_y() + head
        local frac = shown / n
        local bar = math.max(10 * F.scale, track * frac)
        local at = (M.scroll / math.max(1, n - shown)) * (track - bar)
        F.layer:seg(x + w - 3 * F.scale, ry(ty + at), x + w - 3 * F.scale, ry(ty + at + bar),
              2 * F.scale, pal.a(pal.RADAR_TILE, 0.8))
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
--
-- A combat line keeps its names as parts even though nothing is hung on them
-- any more, because the parts are what keep a call sign's own capitals: the
-- feed sets a sentence about people and shouting a name back was wrong once.
--
-- Each name used to carry the mark its owner wears in the Players list, a
-- helmet or a machine. Two marks on a line that already names two pilots is
-- the same fact said twice, in the one panel whose whole argument is that a
-- list of short lines needs no chrome. The marks stay where they answer a
-- question: the Players list, the counts, a nameplate.
local function feed_line_w(t, size)
    if type(t) == "string" then return text_w(t, size) end
    local w = 0
    for _, part in ipairs(t) do
        w = w + text_w(type(part) == "table" and part[1] or part, size)
    end
    return w
end

local function draw_feed_line(t, x, y, size, col)
    if type(t) == "string" then
        txt(t, x, y, size, col, nil, nil, true)
        return
    end
    for _, part in ipairs(t) do
        local s = type(part) == "table" and part[1] or part
        txt(s, x, y, size, col, nil, nil, true)
        x = x + text_w(s, size)
    end
end

local function feed(lines, top)
    local shown = math.min(#lines, M.compact and 4 or M.FEED_MAX)
    if shown == 0 then return end
    local right = F.w - F.safe_r - PAD * F.scale - PANEL_X * F.scale
    local y = top + PANEL_Y * F.scale
    local size = FONT * F.scale
    for i = 1, shown do
        local f = lines[i]
        -- Older lines sit further back, and the last second and a half of a
        -- line's life is spent leaving.
        local a = 1 - (i - 1) * 0.07
        local left = M.FEED_LIFE - f.t
        if left < FEED_FADE then a = a * math.max(0, left / FEED_FADE) end
        local w = feed_line_w(f.text, size)
        draw_feed_line(f.text, right - w, y + LINE * F.scale / 2,
                       size, pal.a(f.col or pal.DIM, a))
        y = y + LINE * F.scale
    end
    -- As wide as the widest line it drew rather than a guess, since a feed of
    -- short names is a narrow block and a zone the width of the panel would
    -- claim empty screen beside it.
    local wide = 0
    for i = 1, shown do
        local w = feed_line_w(lines[i].text, size)
        if w > wide then wide = w end
    end
    local block_top = top + PANEL_Y * F.scale
    local block_bot = block_top + shown * LINE * F.scale
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
    if F.w >= F.h then
        -- Landscape: under the flags, in the band across the top that the
        -- corner chips and the dial leave empty between them.
        return F.safe_t + 62 * F.scale
    end
    -- Portrait: two thirds of the way down, the empty band between the ship
    -- and the controls. Clamped clear of what the pads actually reach rather
    -- than trusting the fraction, since a hull carrying four kinds of charge
    -- builds a taller rail than one carrying none, and the rail is the thing
    -- this must not land on.
    local floor = reach and (F.h - reach - 22 * F.scale) or F.h
    return math.min(F.h * 0.66, floor)
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
    local size = (FONT + 1) * F.scale
    local y = toast_y(reach)
    -- A wash under it rather than a box round it, the width of the words and
    -- no wider. Mid-screen over a starfield the type needs something to sit
    -- on; a border would be the one shape this interface does not draw.
    local line_w = feed_line_w(f.text, size)
    local w = line_w + 26 * F.scale
    local h = LINE * F.scale + 6 * F.scale
    rect(F.w / 2 - w / 2, y - h / 2, w, h, pal.rgb(0x03050a, 0.62 * a))
    draw_feed_line(f.text, F.w / 2 - line_w / 2, y, size,
                   pal.a(f.col or pal.INK, a))
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
    F.layer:ring(cx, ry(cy), k * 0.36, pen(k, 0.143), 10, col)
    F.layer:ring(cx, ry(cy), k * 0.78, pen(k, 0.129), 12,
           pal.a(col, (col[4] or 1) * 0.5))
end

-- Rounds in every direction: the burst at eight spokes, shrapnel at six.
local function gl_spokes(n)
    return function(cx, cy, k, col)
        for i = 0, n - 1 do
            local a = (i + 0.5) * 2 * math.pi / n
            local dx, dy = math.cos(a), math.sin(a)
            F.layer:seg(cx + dx * k * 0.3, ry(cy + dy * k * 0.3),
                  cx + dx * k, ry(cy + dy * k), pen(k, 0.143), col)
        end
    end
end
local gl_burst = gl_spokes(8)

-- What a green is, worn by the row that counts what greens made you worth.
local function gl_diamond(cx, cy, k, col)
    local pts = {cx, ry(cy - k), cx + k * 0.8, ry(cy),
                 cx, ry(cy + k), cx - k * 0.8, ry(cy)}
    F.layer:outline(pts, pen(k, 0.183), col, true)
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
    local z = F.scale * math.max(1, math.min(STACK,
                                       (F.h / F.scale) * STACK_SHARE / (n * 22)))
    local rows_h = 22 * z
    local x = F.safe_l + PAD * F.scale
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

    local y = F.h - PAD * F.scale - n * rows_h - (lift or 0)
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
           pal.a(CHARGE_HUES[slot] or pal.CHARGE_COL, 0.85))
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

    -- What you are worth, which is the number that decides who comes for
    -- you. It is the base plus your run, so this row says how long you have
    -- been alive and killing rather than what you own: the run is drawn
    -- beside it so a pilot reads "worth five, on a run of four" without
    -- having to subtract.
    gl_diamond(mid, y + rows_h / 2, 6 * z, pal.a(pal.BOUNTY, 0.8))
    local bty = sim.ship_bounty(me)
    local run = sim.ship_run and sim.ship_run(me) or 0
    txt(tostring(bty), val, y + rows_h / 2, (FONT - 2) * z,
        run > 0 and pal.a(pal.BOUNTY, 0.95) or pal.a(pal.DIM, 0.6))
    local bw = val + text_w(tostring(bty), (FONT - 2) * z)
    if run > 0 then
        txt("x" .. run, bw + 6 * z, y + rows_h / 2, (FONT - 4) * z,
            pal.a(pal.PAID, 0.8))
        bw = bw + 6 * z + text_w("x" .. run, (FONT - 4) * z)
    end
    zone("bounty", x, y, bw - x, rows_h)

    return 0
end

-- What this pilot is flying, under the same toggle as the scoreboard: which
-- hull, and how far up each stat their kit took them.
--
-- The gun and bomb ladders used to be here too. They are what a trigger does
-- rather than what a run has accumulated, and they belong in the corner with
-- the rest of what the ship is carrying, where they can be read without
-- opening a panel at all.
local function loadout(me, class_names, top)
    if not M.details then return top or 0 end
    local w = COL_W * F.scale
    local x = F.safe_l + PAD * F.scale
    local h = 54 * F.scale
    local y = (top or 0) + 6 * F.scale
    rect(x, y, w, h, pal.a(pal.BG, 0.62))
    vrule(x, y, h, pal.a(pal.RADAR_TILE, 0.7))

    txt(class_names[sim.ship_class(me) + 1] or "?", x + 12 * F.scale, y + 16 * F.scale,
        (FONT - 1) * F.scale, pal.FRIEND)
    txt(sim.ship_kills(me) .. "k  " .. sim.ship_deaths(me) .. "d",
        x + w - 12 * F.scale, y + 16 * F.scale, (FONT - 3) * F.scale, pal.a(pal.DIM, 0.85),
        "right")

    -- Every stat always present, and the pips run to the kit space's own
    -- ceiling rather than to a number written here: a pilot who bought the
    -- last two steps of a stat should see two more places to fill, not a row
    -- that silently stops counting.
    -- Through tonumber, because a stub `sim` that answers every unknown key
    -- with a function would otherwise be counted with.
    local steps = tonumber(sim.UP_STEPS) or 8
    local gap = (w - 24 * F.scale) / #pal.UPGRADES
    for i, up in ipairs(pal.UPGRADES) do
        local held = sim.ship_up(me, i - 1)
        local sx = x + 14 * F.scale + (i - 1) * gap
        txt(up.short, sx, y + 32 * F.scale, (FONT - 4) * F.scale, pal.a(pal.DIM, 0.75))
        pips(sx + 3 * F.scale, y + 42 * F.scale, steps, held, up.col,
             1.7 * F.scale, 4.6 * F.scale)
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
    if i < 0 or i >= sim.ship_count()
        or (not o.pilots[i] and not seat_here(i)) then
        M.inspect = nil
        return
    end
    local p = o.pilots[i]
    local w = COL_W * F.scale
    local x = F.safe_l + PAD * F.scale
    local rowh = 15 * F.scale
    -- Name, then the rows that always exist, then the team when it means
    -- something. Counted rather than guessed so the panel is exactly as tall
    -- as what it holds.
    --
    -- Their side comes from the roster when the seat is outside the snapshot,
    -- exactly as the scoreboard's does: the simulation holds only the seats
    -- inside this client's interest window, and a pilot across the map read
    -- as team zero: the wrong color on the row, and possibly the wrong
    -- side's name against it.
    local theirs = seat_team(i, p)
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
    -- The team row always exists now, so the count is fixed.
    local rows_n = 8
    local h = 30 * F.scale + rows_n * rowh
        + ((invite or follow) and (KEY_H + 12) * F.scale or 0)
        + 10 * F.scale
    -- Under whatever is in the column, and never above where the column
    -- starts: with the scoreboard shut there is nothing above it, and a panel
    -- at the top of the screen lands on the menu chip.
    local y = math.max((top or 0) + 6 * F.scale, top_y())
    rect(x, y, w, h, pal.a(pal.BG, 0.72))
    vrule(x, y, h, pal.a(same_team and pal.FRIEND or pal.ENEMY, 0.9))

    local col = same_team and pal.FRIEND or pal.ENEMY
    local nm = (p and p.name) or ("ship " .. i)
    txt(nm, x + 12 * F.scale, y + 17 * F.scale, (FONT - 1) * F.scale, pal.a(col, 0.95),
        nil, nil, true)
    -- The mark rides after the name here, not in a column: there is one line
    -- and nothing to line it up with.
    if p and p.ai then
        bot_mark(x + 12 * F.scale
                     + text_w(nm, (FONT - 1) * F.scale) + 5 * F.scale,
                 y + 17 * F.scale,
                 pal.a(pal.DIM, 0.85), 10 * F.scale)
    end
    -- Close, in the corner it opened under. Escape does the same thing.
    close_mark(x + w - 17 * F.scale, y + 17 * F.scale, pal.a(pal.DIM, 0.8), 10 * F.scale)
    hit(x + w - 26 * F.scale, y + 4 * F.scale, 26 * F.scale, 22 * F.scale, "uninspect")

    local ry_ = y + 30 * F.scale
    local lab = (FONT - 4) * F.scale
    local val = (FONT - 2) * F.scale
    local function row(k, v, vcol, raw)
        txt(k, x + 12 * F.scale, ry_ + rowh / 2, lab, pal.a(pal.DIM, 0.8))
        txt(v, x + w - 12 * F.scale, ry_ + rowh / 2, val, vcol or pal.a(pal.INK, 0.9),
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
    -- And the number under it, which is what the band is a rounding of.
    --
    -- The band exists so nobody has to watch a number move after every death,
    -- and that reasoning still holds for the *band*: it is the row above and it
    -- still only changes when something changed. This is the second line rather
    -- than a replacement for the first. A pilot who wants to know whether they
    -- are near the top of Lead or the bottom of it has no way to ask otherwise,
    -- and the number is already on the wire, updated on both pilots at every
    -- rated death.
    --
    -- Dim while placing, for the same reason the band is: ten games in, it is a
    -- number that has not settled, and reading it as firm is reading it wrong.
    -- A seat with no rating at all is a watcher, and a dash is the honest
    -- answer there rather than a zero.
    local score = o.ratings and o.ratings[i]
    row("RATING", score and tostring(math.floor(score + 0.5)) or "--",
        (band == "placing" or not score) and pal.a(pal.DIM, 0.85) or nil)
    -- A line each, rather than one line of "21K 20D 748P". Three numbers
    -- packed into a row with their units stuck to them is a thing to decode;
    -- three labeled rows are three numbers to read, and this panel already
    -- reads that way everywhere else.
    --
    -- Through the same read the scoreboard uses, which this panel was not
    -- doing: the four lines came straight out of the simulation, so opening
    -- the box on a pilot across the map answered zero to all of them while
    -- the row it was opened from, a finger's width behind it, showed what the
    -- roster says.
    local k, d, pts, bty = seat_score(i, p)
    row("KILLS", tostring(k))
    row("DEATHS", tostring(d))
    row("POINTS", tostring(pts))
    -- What killing them pays, which is the number that decides whether the
    -- rest of this matters right now.
    row("BOUNTY", tostring(bty), pal.a(pal.BOUNTY, 0.9))

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
        local by = ry_ + 4 * F.scale
        local bw = key_w(label)
        key_cap(x + 12 * F.scale, by, bw, label, action ~= nil)
        if action then
            hit(x + 12 * F.scale, by, bw, KEY_H * F.scale, action, i)
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
-- What a particular hull is carrying is the corner stack's job and it draws
-- that already; this is the keyboard, which is the same in every room.
--
-- Asked for each time it is drawn rather than held, because the keys are a
-- pilot's to move now. It used to be the list itself, on the argument that a
-- table which rearranged itself would be a reference you cannot learn; that is
-- still true of a table that rearranges on its own, and false of one that says
-- what you last told it.
--
-- Keyboard only, and that is not an oversight: a touchscreen has no key to
-- open it with and no keys to list. The menu's controls page is what a phone
-- gets, and it names thumbs because thumbs are what a phone has.
local binds = require("arena.binds")

-- Whether the table is up. The arena owns the key; this owns the drawing.
M.help = false
-- The first-zone offer is separate from the table it opens. The arena raises
-- and dismisses it; this module only draws it and publishes its two targets.
M.help_prompt = false

-- How wide a string draws, counting glyphs rather than bytes.
--
-- `text_w` counts bytes, which is right for every other caller and runs in
-- the wrap on every frame. The arrow keys are the one place the interface
-- says something outside ASCII, and each of them is three bytes: measured
-- with `text_w` the key column comes out three times too wide. Counting
-- continuation bytes is exact for UTF-8 and this runs once per control while
-- a table is open, so it can afford to be.
local function glyph_w(s, px)
    local _, cont = string.gsub(s, "[\128-\191]", "")
    return (#s - cont) * px * ADVANCE
end

local function help_table()
    -- Where the controls are now, not where they started. The same list the
    -- menu's page draws, so the table under H and the chips under the board
    -- cannot say different things about the same key.
    local bound = binds.rows()
    local fs = (M.compact and 11 or 13) * F.scale
    local rowh = fs * 1.65
    local pad = 18 * F.scale
    -- Three columns, measured off the widest thing each has to hold rather
    -- than guessed, since the sentences are what decides the width and they
    -- are the one column that cannot be allowed to wrap.
    local kw, nw, dw = 0, 0, 0
    for _, r in ipairs(bound) do
        kw = math.max(kw, glyph_w(r.show, fs))
        nw = math.max(nw, glyph_w(r.name, fs))
        dw = math.max(dw, glyph_w(r.what, fs))
    end
    local gap = 14 * F.scale
    local w = pad * 2 + kw + gap + nw + gap + dw
    local head = fs * 1.9
    local h = pad * 2 + head + #bound * rowh
    -- Shrunk to fit rather than clipped, because a window narrower than the
    -- longest sentence is a window this has to work in anyway.
    local room = F.w - 24 * F.scale
    local scale = (w > room) and (room / w) or 1
    if scale < 1 then
        fs, rowh, pad, gap = fs * scale, rowh * scale, pad * scale, gap * scale
        kw, nw = kw * scale, nw * scale
        head = head * scale
        w = room
        h = pad * 2 + head + #bound * rowh
    end
    local x, y = (F.w - w) / 2, (F.h - h) / 2

    rect(x, y, w, h, pal.rgb(0x03050a, 0.88))
    F.layer:frame(x, ry(y, h), w, h, 1.0 * F.scale, pal.a(pal.DIM, 0.5))

    txt("CONTROLS", x + pad, y + pad + head * 0.35, fs * 1.05,
        pal.a(pal.INK, 0.9))
    local rule = y + pad + head - fs * 0.35
    F.layer:seg(x + pad, ry(rule), x + w - pad, ry(rule), 0.8 * F.scale,
          pal.a(pal.DIM, 0.45))

    local kx = x + pad
    local nx = kx + kw + gap
    local dx = nx + nw + gap
    local was = F.case
    for i, r in ipairs(bound) do
        local ty = y + pad + head + (i - 0.5) * rowh
        -- The key in the color a key is drawn in everywhere else, the name in
        -- ink, and the sentence dimmer than both: three weights so the eye can
        -- run down one column without reading the other two.
        F.case = "upper"
        txt(r.show, kx, ty, fs, pal.a(pal.FRIEND, 0.95))
        txt(r.name, nx, ty, fs, pal.a(pal.INK, 0.92))
        -- Prose, and set as prose. The rest of the interface shouts.
        F.case = "sentence"
        txt(r.what, dx, ty, fs, pal.a(pal.PANEL_INK, 0.85))
    end
    F.case = was
end

local function help_prompt()
    -- The controls table is keyboard-only, so its offer is too. A touchscreen
    -- gets the controls page in the menu, written for thumbs rather than keys.
    if M.touching or M.help then return end

    local label = "PRESS H FOR HELP"
    local fs = (M.compact and 11 or 13) * F.scale
    local h = 32 * F.scale
    local close_w = 34 * F.scale
    local w = text_w(label, fs) + 28 * F.scale + close_w
    local x = (F.w - w) / 2
    local y = F.h - h - 18 * F.scale
    local cut = x + w - close_w

    rect(x, y, w, h, pal.a(pal.BTN_BG, 0.82))
    F.layer:frame(x, ry(y, h), w, h, 1.0 * F.scale, pal.a(pal.DIM, 0.48))
    F.layer:seg(cut, ry(y + 6 * F.scale), cut, ry(y + h - 6 * F.scale), 0.8 * F.scale,
          pal.a(pal.DIM, 0.38))

    -- One slow breath every three seconds. The hue stays neutral while the
    -- label moves from the interface gray to white and back.
    local pulse = 0.5 - 0.5 * math.cos((F.now or 0) * math.pi * 2 / 3)
    txt(label, x + 14 * F.scale, y + h / 2, fs,
        pal.hot(pal.DIM, pulse, 0.98), "left", nil, true)
    close_mark(cut + close_w / 2, y + h / 2, pal.a(pal.DIM, 0.88), 10 * F.scale)

    -- First published wins. The close mark sits inside the full button, so its
    -- smaller target has to come first or every click would open help.
    hit(cut, y, close_w, h, "help_prompt_close")
    hit(x, y, w, h, "help_prompt_open")
end

-- --- what a row of the corner stack is -------------------------------------
--
-- The stack is marks and counts. That is the right shape for reading in a
-- fight, when a glance has to answer "what am I holding" without words, and
-- it is no help at all to somebody who has not learned the marks yet: a
-- drawing that means "shrapnel" means nothing until somebody says so once.
--
-- A hand already on the mouse can ask. Rest the pointer on a row and it says
-- what the row is, what the greens have added to it, and which key spends it.
-- Nothing appears until the pointer is on it, so the corner is unchanged for
-- everybody flying, which is what the corner is for.
--
-- Keyboard only, like the controls table: a thumb has no pointer to rest, and
-- the pads on glass carry their own names.
M.hover_x, M.hover_y = nil, nil

-- Which published row covers a point, as the rectangle rather than the name.
-- `M.row_at` answers the name, which is what a test asking "where did this
-- land" wants; a card has to be put somewhere, so it needs the box.
local function zone_at(x, y)
    if not x or not y then return nil end
    local found = nil
    for _, z in ipairs(F.zones) do
        if x >= z.x and x <= z.x + z.w and y >= z.y and y <= z.y + z.h then
            found = z
        end
    end
    return found
end

-- Break a sentence to a width, on spaces. The one card that carries prose is
-- the bounty's, and its sentence is wider than any corner should be.
-- --- the pages --------------------------------------------------------------
--
-- The three pages drawn as layouts rather than as lists, kept in one table
-- rather than as five names of their own: a Lua chunk may hold two hundred
-- locals and this file is at that ceiling.
local pages = {}

local function wrapped(s, px, max)
    local out, line = {}, nil
    for word in string.gmatch(s, "%S+") do
        local try = line and (line .. " " .. word) or word
        if line and glyph_w(try, px) > max then
            out[#out + 1] = line
            line = word
        else
            line = try
        end
    end
    if line then out[#out + 1] = line end
    return out
end

-- What the greens have put on a trigger, named at whatever length teaches
-- best: `long` where a short name is jargon, and the feed's own name for the
-- rest, so a pilot reading "bounce" here has already seen "gun bounce" go by.
--
-- A rung is only worth saying once it has moved: every hull flies on the
-- bottom one, and a card that opened with "level 1" would be spending its
-- first line on the absence of an upgrade. Counted where a rung is worth more
-- than one of a thing, which is what a pilot holding two shrapnel wants to
-- know that the mark alone does not say.
local function trigger_kit(me, t)
    local out = {}
    local lvl = marks.level(me, t)
    if lvl > 0 then out[#out + 1] = "level " .. (lvl + 1) end
    for i = 1, #pal.MODS do
        local n = marks.mod(me, t, i - 1)
        if n > 0 then
            local name = pal.MODS[i].long or pal.MODS[i].name
            -- Multifire is the one add-on a pilot can switch off, and a card
            -- that listed it while the fan was folded would be naming a thing
            -- the next shot will not do.
            if i - 1 == (sim.MOD_MULTI or 0) and sim.ship_multi_off
               and sim.ship_multi_off(me) then
                name = name .. " (off)"
            end
            out[#out + 1] = (n > 1) and (name .. " x" .. n) or name
        end
    end
    return out
end

-- The control this row answers to, as the controls list has it now rather
-- than as it shipped: a pilot who moved their charge keys reads the keys they
-- moved them to, and the name comes from the same row so the card and the
-- table under H cannot call one thing two things.
local function control(id)
    for _, r in ipairs(binds.rows()) do
        if r.id == id then return r end
    end
    return nil
end

-- What the row under the pointer is called, what it is carrying, and what
-- spends it. Nil for a row with nothing to say.
local function stack_card_lines(key, o, me)
    if key == "bounty" then
        -- Fixed words, because the number is the whole of what the row shows
        -- and the question it raises is always the same one.
        return "bounty", {}, nil,
               "Your ship's bounty. Enemies get these points when you're destroyed."
    end
    if key == "gun" or key == "bomb" then
        local t = (key == "gun") and sim.TRIG_GUN or sim.TRIG_BOMB
        local id = (key == "gun") and "guns" or "bombs"
        local c = control(id)
        return (c and c.name) or key, trigger_kit(me, t), c and c.show, nil
    end
    local slot = string.match(key or "", "^charge:(.+)$")
    if not slot then return nil end
    -- Which key spends this row is a position rather than a name: the charge
    -- keys are slots under the skin, and the first one spends whatever the
    -- hull's first charge happens to be. So the row is found in the same list
    -- the stack drew, and its place in that list is the key.
    local nth = nil
    for i, c in ipairs(o.charges or {}) do
        if string.lower(c.name or c.short or "") == slot then nth = i break end
    end
    -- A charge is one thing the zone put in a slot and there is nothing to
    -- upgrade about it, so the list is empty rather than saying "none": an
    -- empty line would imply a kit this row can hold and does not.
    local c = nth and control("charge_" .. nth)
    return slot, {}, c and c.show, nil
end

-- The card itself, hung off the row it belongs to.
local function stack_card(o, me)
    if M.touching or M.help or not M.hover_x then return end
    local z = zone_at(M.hover_x, M.hover_y)
    if not z then return end
    local name, kit, key, prose = stack_card_lines(z.key, o, me)
    if not name then return end

    local fs = (M.compact and 11 or 12) * F.scale
    local pad = 9 * F.scale
    local gap = 14 * F.scale
    local rowh = fs * 1.5
    local body = {}
    if prose then
        for _, l in ipairs(wrapped(prose, fs, 210 * F.scale)) do
            body[#body + 1] = l
        end
    elseif #kit > 0 then
        body[#body + 1] = table.concat(kit, ", ")
    end

    local head = glyph_w(string.upper(name), fs)
    if key then head = head + gap + glyph_w(string.upper(key), fs) end
    local w = head
    for _, l in ipairs(body) do
        w = math.max(w, glyph_w(l, fs))
    end
    w = w + pad * 2
    local h = pad * 2 + rowh * (1 + #body)

    -- Beside the stack rather than over it: the stack is what the pointer is
    -- reading and a card on top of it would answer by hiding the question.
    -- Clear of the widest row rather than of the hovered one, because the rows
    -- are not the same width: a bounty of two figures is a good deal narrower
    -- than a charge with three pips, and a card hung off the narrow one covers
    -- the wide one above it.
    --
    -- Clamped to the window on both axes, since the stack sits in the corner a
    -- short window has least of.
    local right = z.x + z.w
    for _, other in ipairs(F.zones) do
        if other.x == z.x and other.x + other.w > right then
            right = other.x + other.w
        end
    end
    local x = right + 8 * F.scale
    local y = z.y + z.h / 2 - h / 2
    if x + w > F.w - 8 * F.scale then x = math.max(8 * F.scale, z.x - w - 8 * F.scale) end
    if y + h > F.h - 8 * F.scale then y = F.h - 8 * F.scale - h end
    if y < 8 * F.scale then y = 8 * F.scale end

    rect(x, y, w, h, pal.rgb(0x03050a, 0.9))
    F.layer:frame(x, ry(y, h), w, h, 1.0 * F.scale, pal.a(pal.DIM, 0.5))

    local was = F.case
    F.case = "upper"
    txt(name, x + pad, y + pad + rowh * 0.5, fs, pal.a(pal.INK, 0.95))
    if key then
        txt(key, x + w - pad, y + pad + rowh * 0.5, fs,
            pal.a(pal.FRIEND, 0.95), "right")
    end
    -- Quoted rather than set: these lines arrive in the case they are meant
    -- to be read in. A sentence broken to the card's width is still one
    -- sentence, and the interface's own rule would capitalize every line it
    -- was broken into, which is three sentences that are not there.
    for i, l in ipairs(body) do
        txt(l, x + pad, y + pad + rowh * (i + 0.5), fs,
            pal.a(pal.PANEL_INK, 0.85), nil, nil, true)
    end
    F.case = was
end

local function safe_note(spent, limit)
    local y = F.h * 0.62
    txt("SAFE ZONE", F.w / 2, y, (M.compact and 12 or 16) * F.scale,
        pal.a(pal.FRIEND, 0.9), "center")
    if limit <= 0 then return end
    -- Rounded up, so the last second is a 1 and the number never sits on 0
    -- while the hull is still there.
    local left = math.ceil((limit - spent) / 100)
    if left < 0 then left = 0 end
    -- Red for the last ten, which is where it stops being information and
    -- starts being a warning.
    local col = left <= 10 and pal.ENEMY or pal.DIM
    txt("seat released in " .. left, F.w / 2, y + (M.compact and 15 or 20) * F.scale,
        (M.compact and 10 or 12) * F.scale, pal.a(col, 0.9), "center")
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
    local d = math.min(F.w, F.h) * 0.34
    local function band(x1, y1, x2, y2, x3, y3, x4, y4)
        F.layer:tri_fade(x1, y1, 1, x2, y2, 1, x3, y3, 0, col)
        F.layer:tri_fade(x1, y1, 1, x3, y3, 0, x4, y4, 0, col)
    end
    band(0, 0, F.w, 0, F.w - d, d, d, d)
    band(0, F.h, F.w, F.h, F.w - d, F.h - d, d, F.h - d)
    band(0, 0, 0, F.h, d, F.h - d, d, d)
    band(F.w, 0, F.w, F.h, F.w - d, F.h - d, F.w - d, d)
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
local function menu_button(on_air, watch, room, pilots, watchers)
    -- Two keys, drawn the way the help page draws a key. They were two bare
    -- words over a shared rule, which asked a player to know that a word in
    -- that corner was a thing to press, and the board has taught the same hand
    -- what a key looks like already.
    --
    -- One color between them, and one rule for lighting it. MENU was drawn in
    -- ink and PLAYERS in slate, which is two controls that do the same kind of
    -- thing wearing two different states before either had been pressed. What
    -- they wear now is off or on, and the panel each opens is what turns it on.
    local x, y = F.safe_l + PAD * F.scale, F.safe_t + PAD * F.scale
    -- Each key is as wide as its own word. A slot cut for four letters is a
    -- slot the longer of the two runs out of.
    local humans, bots = 0, 0
    for _, p in pairs(pilots or {}) do
        if p.ai then bots = bots + 1 else humans = humans + 1 end
    end
    -- A spectator is still in the room. Guests wear the unknown label until
    -- they claim an account, but they are people unless they arrived with one
    -- of the two bot labels.
    for _, w in ipairs(watchers or {}) do
        if w.label == "bot" or w.label == "bot?" then
            bots = bots + 1
        else
            humans = humans + 1
        end
    end
    local cx = x
    local keys = {{"MENU", "open", F.menu_up}}
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
        hit(cx, y, ww, KEY_H * F.scale, c[2])
        cx = cx + ww + KEY_GAP * F.scale
    end
    local players_w = players_cap(cx, y, M.details, humans, bots)
    hit(cx, y, players_w, KEY_H * F.scale, "details")
    cx = cx + players_w + KEY_GAP * F.scale
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
        local mid = y + KEY_H * F.scale / 2
        -- A slow swell rather than a blink. It has to hold attention for as
        -- long as the camera holds you, which is minutes, and a blink that
        -- long is something a player learns to stop seeing.
        local beat = 0.55 + 0.45 * math.sin(F.now * 3.2)
        local r = 3.4 * F.scale
        F.layer:disc(cx + r, ry(mid, 0), r, 10, pal.a(pal.HURT, beat))
        local label = "ON AIR"
        local size = key_size()
        txt(label, cx + 2 * r + 5 * F.scale, mid, size, pal.a(pal.HURT, 0.9))
        cx = cx + 2 * r + 5 * F.scale + text_w(label, size) + KEY_GAP * F.scale
    elseif watch then
        -- Watching, and what of. The same slot, because the two are the same
        -- kind of fact about the connection and a watcher is never on air.
        --
        -- Green and a play mark rather than the tally's red dot: the red one
        -- is a warning about you and this is a statement about what you are
        -- looking at, which is the difference between being filmed and
        -- holding the camera.
        local mid = y + KEY_H * F.scale / 2
        local h = 4.6 * F.scale
        local wsym = h * 1.5
        local col = pal.a(pal.PAID, 0.92)
        F.layer:tri(cx, ry(mid - h, 0), cx, ry(mid + h, 0),
              cx + wsym, ry(mid, 0), col)
        local size = key_size()
        -- The room's feed says so in the interface's own word; a pilot says
        -- their own call sign, in their own case, the way a name is written
        -- everywhere else here.
        local named = watch.name ~= nil
        txt(named and watch.name or "CHANNEL",
            cx + wsym + 6 * F.scale, mid, size, col, nil, nil, named)
        cx = cx + wsym + 6 * F.scale
            + text_w(named and watch.name or "CHANNEL", size) + KEY_GAP * F.scale
    end
    chip_right = cx - KEY_GAP * F.scale
end

-- How good the line is, above the dial. It belongs up here with the
-- instrument rather than down in the corner with what the ship is carrying:
-- it is a fact about the connection, not about the ship.
--
-- Four bars from the connection's smoothed quality. It replaces
-- "online  err 0.0 / 1 px", which was the client's own debugging left on a
-- player's screen: nobody flying has ever made a decision on a prediction
-- error in pixels.
local function link(q)
    local pad = (M.compact and 8 or PAD) * F.scale
    local right = F.w - F.safe_r - pad
    local base = F.safe_t + pad + 13 * F.scale
    for k = 0, 3 do
        local bh = (3 + k * 2.6) * F.scale
        local bx = right - (26 - k * 6) * F.scale
        rect(bx, base - bh, 4 * F.scale, bh,
             k < q and pal.a(pal.PAID, 0.85) or pal.a(pal.DIM, 0.22))
    end
    txt("LINK", right - 34 * F.scale, base - 4 * F.scale, (FONT - 3) * F.scale,
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
    if not F.menu_up then
        local _, dial_y = dial()
        local x0 = right - 34 * F.scale - text_w("LINK", (FONT - 3) * F.scale) - 6 * F.scale
        hit(x0, F.safe_t, F.w - x0, math.max(dial_y - F.safe_t, 24 * F.scale), "debug")
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
    local size = (FONT - 1) * F.scale
    local colw = 214 * F.scale
    local rowh = 16 * F.scale
    local lines = {
        {"fps", string.format("%.0f", o.fps or 0)},
        {"frame", string.format("%.1f ms", (o.frame_ms or 0))},
        {"wire", string.format("%s / %.1f%% pace", st.wire or "ws",
                                (st.clock_rate or 1) * 100)},
        {"margin", string.format("%+d ticks", st.input_margin or 0)},
        {"rtt", string.format("%d ms / %d jitter / ~%d est",
                               st.server_rtt_ms or 0, st.jitter_ms or 0,
                               (st.rtt or 0) * 10)},
        {"lead", string.format("%d ticks", st.lead or 0)},
        {"self", string.format("%.1f / %.1f px", st.self_err or 0,
                                st.self_err_max or 0)},
        {"remote", string.format("%.1f / %.1f / %.1f px",
                                  st.remote_pos or 0, st.remote_pos_p95 or 0,
                                  st.remote_pos_max or 0)},
        {"turn", string.format("%.1f / %.1f / %.1f deg",
                                st.remote_turn or 0, st.remote_turn_p95 or 0,
                                st.remote_turn_max or 0)},
        {"debt", string.format("%.1f px / %.1f deg", st.smooth_pos or 0,
                                st.smooth_turn or 0)},
        {"replay", string.format("%d / %d ticks", st.replay or 0,
                                  st.replay_max or 0)},
        {"death?", string.format("%d/%d ok / %d wait",
                                   st.death_confirmed or 0,
                                   (st.death_confirmed or 0)
                                       + (st.death_rejected or 0),
                                   st.death_pending or 0)},
        {"snaps", string.format("%.1f Hz / %.0f / %.0f ms", st.snap_hz or 0,
                                 st.snap_gap_ms or 0,
                                 st.snap_gap_max_ms or 0)},
        {"loss", string.format("%d miss / %d late", st.snap_missed or 0,
                                st.snap_reordered or 0)},
        {"path", string.format("D %d%%  F %d%%", st.down_loss or 0,
                                st.combat_loss or 0)},
        {"input miss", string.format("%d%%", st.up_loss or 0)},
        {"input", string.format("%d holes", st.input_holes or 0)},
        {"down", string.format("%.1f kB/s", (o.rx_rate or 0) / 1000)},
        {"up", string.format("%.1f kB/s", (o.tx_rate or 0) / 1000)},
        {"tick", tostring(sim.tick())},
        {"ships", tostring(sim.ship_count())},
        {"shots", tostring(sim.weapon_count())},
    }
    -- How full the two world layers are, and what they refused. A layer past
    -- its capacity says nothing at all: the geometry simply stops being drawn.
    -- So a starfield that thinned out on a big monitor read as a rendering
    -- fault for as long as it took somebody to measure it, and the `+` here is
    -- how many vertices a layer turned away last frame.
    for _, name in ipairs({"fill", "glow"}) do
        local L = o.layers and o.layers[name]
        if L then
            lines[#lines + 1] = {name, string.format("%d / %d", L.n, L.cap) ..
                                 (L.dropped > 0 and (" +" .. L.dropped) or "")}
        end
    end
    -- Wrapped into as many columns as the room below the dial can hold. A
    -- phone in landscape is about four hundred points tall and the dial has
    -- most of that: one column of twelve rows at a size worth reading runs
    -- off the bottom of the screen, and a number nobody can see is not a
    -- readout. Two columns of six is the usual answer; a desktop window has
    -- the height for one and gets it.
    local y = (top or 0) + 6 * F.scale
    local avail = F.h - y - 6 * F.scale
    local most = math.max(1, math.floor((F.w - 2 * PAD * F.scale) / colw))
    -- The narrowest panel that fits, and a little type-shrinking is cheaper
    -- than another column: three columns of four reach most of the way across
    -- a phone held sideways and lie over the game, where two columns four per
    -- cent smaller sit in the corner and read the same. So take the first
    -- column count whose rows fit outright or all but, and only widen when
    -- the squeeze would start to hurt.
    local cols, per, k = most, 1, 1
    for c = 1, most do
        local p = math.ceil(#lines / c)
        local need = 24 * F.scale + p * rowh + 6 * F.scale
        local fit = (need <= avail) and 1 or (avail - 30 * F.scale) / (p * rowh)
        if fit >= 0.85 or c == most then
            cols, per, k = c, p, math.max(0.62, math.min(1, fit))
            break
        end
    end
    rowh = rowh * k
    size = size * k
    local h = 24 * F.scale + per * rowh + 6 * F.scale
    local w = colw * cols
    local x = F.w - F.safe_r - PAD * F.scale - w
    rect(x, y, w, h, pal.a(pal.BG, 0.78))
    vrule(x, y, h, pal.a(pal.PAID, 0.8))
    txt("DEBUG", x + 10 * F.scale, y + 15 * F.scale, size, pal.a(pal.PAID, 0.9))
    -- The zone's name and nothing else. The wire sends the description on a
    -- second line of the same message, and a sentence about the game is not a
    -- diagnostic: it wrapped the header in prose that never changes while the
    -- numbers under it do.
    txt((o.zone or ""):match("^[^\n]*"), x + w - 10 * F.scale, y + 15 * F.scale, size,
        pal.a(pal.DIM, 0.8), "right")
    for n, l in ipairs(lines) do
        local c = math.floor((n - 1) / per)
        local cx = x + c * colw
        local ly = y + 24 * F.scale + ((n - 1) % per) * rowh
        txt(l[1], cx + 10 * F.scale, ly + rowh / 2, size, pal.a(pal.DIM, 0.8))
        txt(l[2], cx + colw - 10 * F.scale, ly + rowh / 2, size,
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
    if not F.menu_up then hit(x, y, w, h, "debug") end
end

-- Where you are, over the dial's other top corner from the link readout.
--
-- In tiles, because that is the unit the map is laid out in and the unit a
-- player says out loud. Pixels would be the same place in numbers six digits
-- long that nobody can hold in their head or call across a room.
local function coords(me)
    if not me then return end
    local pad = (M.compact and 8 or PAD) * F.scale
    local x = dial()
    local base = F.safe_t + pad + 13 * F.scale
    txt("POS", x, base - 4 * F.scale, (FONT - 3) * F.scale, pal.a(pal.DIM, 0.8))
    txt(string.format("%d,%d", math.floor(sim.ship_x(me) / 16),
                      math.floor(sim.ship_y(me) / 16)),
        x + 26 * F.scale, base - 4 * F.scale, (FONT - 3) * F.scale, pal.a(pal.INK, 0.85))
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
    local pitch = 15 * F.scale
    local x0 = F.w / 2 - (n - 1) * pitch / 2
    local y = F.safe_t + 30 * F.scale
    for i = 0, n - 1 do
        local _, _, team = sim.flag_at(i)
        local col = (team == 255) and pal.a(pal.DIM, 0.55)
            or (team == my_team and pal.FRIEND or pal.ENEMY)
        local px = x0 + i * pitch
        -- The same pennant the radar draws, so a flag looks like a flag
        -- wherever it is shown.
        F.layer:seg(px, ry(y + 9 * F.scale, 0), px, ry(y - 8 * F.scale, 0), 1.6 * F.scale, col)
        F.layer:tri(px, ry(y - 8 * F.scale, 0), px + 9 * F.scale, ry(y - 4 * F.scale, 0),
              px, ry(y, 0), col)
    end
end

-- The clock and the score, dead center at the top, which are the two facts a
-- three minute match is about.
--
-- Both sides in the viewer's own colors rather than in the zone's: which one
-- is yours is the first thing the number has to say, and every other
-- instrument on this screen already reads cyan for yours and amber for
-- theirs. A watcher's side is the subject's, the way it is everywhere else.
--
-- Drawn under the menu as well, unlike the two big centered lines below,
-- because the menu is a scrim rather than a curtain and "how are you doing in
-- the thing you are in" is exactly what a player opening it wants to keep.
local function match_clock(m, names, alone)
    if not m then return end
    local left = m.left or 0
    local clock = string.format("%d:%02d", math.floor(left / 60), left % 60)
    local y = F.safe_t + 26 * F.scale
    local big = (M.compact and 22 or 30) * F.scale
    local small = (M.compact and 10 or 13) * F.scale

    -- The middle first, because everything else is placed off it.
    local dim = m.playing and 1 or 0.55
    txt(clock, F.w / 2, y, big, pal.a(pal.INK, 0.95 * dim), "center")
    -- Nothing under it while a match is being played: the clock is counting
    -- down and a word saying "match" beneath it is the interface reading its
    -- own label back. The intermission does need saying, because a clock
    -- counting down to something a player cannot see is a question.
    -- Only when the ending is not up. The card says the same thing at its
    -- foot, with room for it, and two of them at once is the interface
    -- answering a question nobody asked twice.
    if not m.playing and alone then
        txt("NEXT MATCH IN", F.w / 2, y + 17 * F.scale, small - 2 * F.scale,
            pal.a(pal.DIM, 0.8), "center")
    end

    -- A side's score sits outboard of the clock, its name outboard of that.
    -- Yours on the left however the zone numbered the teams, so the reading
    -- is positional and never has to be worked out from a color.
    local gap = 26 * F.scale
    local mine = view_team
    local sides = {}
    for team, n in pairs(m.score or {}) do
        sides[#sides + 1] = {team = team, n = n}
    end
    table.sort(sides, function(a, b)
        if (a.team == mine) ~= (b.team == mine) then return a.team == mine end
        return a.team < b.team
    end)
    for i, side in ipairs(sides) do
        local ours = side.team == mine
        local col = pal.a(ours and pal.FRIEND or pal.ENEMY, 0.95 * dim)
        local num = tostring(side.n)
        local nw = text_w(num, big)
        local nm = (names and names[side.team]) or ""
        local at, align
        if i == 1 then
            at = F.w / 2 - text_w(clock, big) / 2 - gap
            txt(num, at, y, big, col, "right")
            at, align = at - nw - 10 * F.scale, "right"
        else
            at = F.w / 2 + text_w(clock, big) / 2 + gap
            txt(num, at, y, big, col)
            at, align = at + nw + 10 * F.scale, nil
        end
        if nm ~= "" then
            txt(nm, at, y + 2 * F.scale, small, pal.a(col, 0.85 * dim), align)
        end
    end
end

-- The ending: who took the match, what everybody did in it, and what the room
-- is counting down to.
--
-- Built out of what the roster already carries rather than out of a message of
-- its own. Every number here is one the scoreboard has been drawing all match:
-- kills, deaths, and `points`, which is the bounty a pilot collected and so
-- exactly the rivets the match paid them.
--
-- It sits where the menu sits and stands down for it, the way the two big
-- centered lines do, because a player who opens the menu during an
-- intermission is doing the one thing the intermission is for.
local function podium(o, m, names)
    -- The roster, asked for here rather than assumed: the scoreboard fills it
    -- when somebody opens the scoreboard, and this page is on screen whether
    -- anybody did or not.
    refresh_players(o.pilots, o.watchers, nil, o.viewer_name)
    local pad = 18 * F.scale
    local w = math.min(F.w - 2 * pad, 620 * F.scale)
    local x = (F.w - w) / 2
    local line = (M.compact and 15 or 17) * F.scale

    -- Which side took it. A draw is a real result at three minutes and says
    -- so, rather than a winner being named by tie-break.
    local best, best_at, drawn = -1, nil, false
    for team, n in pairs(m.score or {}) do
        if n > best then best, best_at, drawn = n, team, false
        elseif n == best then drawn = true end
    end
    local head
    if drawn or best_at == nil then
        head = "drawn"
    else
        head = ((names and names[best_at]) or "a side") .. " takes it"
    end

    -- The sides, each with its own pilots under it, best first, and yours on
    -- the left however the zone numbered the teams. That is the same rule the
    -- clock's own score follows: the reading is positional, so it never has to
    -- be worked out from a color.
    local sides, seen = {}, {}
    for team in pairs(m.score or {}) do
        sides[#sides + 1] = team
        seen[team] = {}
    end
    table.sort(sides, function(a, b)
        if (a == view_team) ~= (b == view_team) then return a == view_team end
        return a < b
    end)
    -- The best gun in the room, whichever side it was on. Nobody in a
    -- scoreless match, because a mark on a pilot with no kills is a prize for
    -- turning up, and the fewer deaths where two are level, so the mark lands
    -- in the same place on every machine rather than on whoever the roster
    -- happened to name first.
    local mvp = nil
    for _, r in ipairs(rows) do
        if not r.watch and seen[r.team] then
            local list = seen[r.team]
            list[#list + 1] = r
            if r.k > 0 and (mvp == nil or r.k > mvp.k
                            or (r.k == mvp.k and r.d < mvp.d)) then
                mvp = r
            end
        end
    end
    for _, list in pairs(seen) do
        table.sort(list, function(a, b)
            if a.k ~= b.k then return a.k > b.k end
            return a.d < b.d
        end)
    end

    local tall = 0
    for _, list in pairs(seen) do tall = math.max(tall, #list) end
    local h = 34 * F.scale + 20 * F.scale + tall * line + 40 * F.scale
    local y = math.max(72 * F.scale, (F.h - h) / 2)

    -- A scrim over the whole screen and a heavier wash under the card. The
    -- match is over and the arena behind it is not hidden, because the next
    -- one starts in the room you are looking at, but a card you can read a
    -- wall through is a card with a wall written across it: at three quarters
    -- the lit edge of a rock came through the type.
    rect(0, 0, F.w, F.h, pal.rgb(0x03050a, 0.55))
    rect(x - pad, y - pad, w + 2 * pad, h + 2 * pad, pal.rgb(0x03050a, 0.9))
    txt(head, F.w / 2, y + 6 * F.scale, (M.compact and 17 or 21) * F.scale,
        pal.a(pal.INK, 0.95), "center")

    local cw = w / math.max(1, #sides)
    for i, team in ipairs(sides) do
        local cx = x + (i - 1) * cw
        -- A hairline between the columns, because one side's numbers and the
        -- next side's names are otherwise twenty four points apart and read as
        -- one line: "6 8 Halcyon".
        if i > 1 then
            F.layer:seg(cx, ry(y + 30 * F.scale), cx,
                        ry(y + 54 * F.scale + tall * line),
                        1.0 * F.scale, pal.a(pal.RADAR_TILE, 0.45), true)
        end
        local col = (team == view_team) and pal.FRIEND or pal.ENEMY
        local nm = (names and names[team]) or ""
        txt(nm, cx + 18 * F.scale, y + 34 * F.scale, 12 * F.scale,
            pal.a(col, 0.9))
        txt(tostring(m.score and m.score[team] or 0),
            cx + cw - 18 * F.scale, y + 34 * F.scale, 12 * F.scale,
            pal.a(col, 0.9), "right")
        -- What the two numbers on every row below are. Once per column, in
        -- the head, rather than a word per row.
        txt("k  d", cx + cw - 46 * F.scale, y + 34 * F.scale, 9.5 * F.scale,
            pal.a(pal.DIM, 0.75), "right")
        F.layer:seg(cx + 18 * F.scale, ry(y + 44 * F.scale),
                    cx + cw - 18 * F.scale, ry(y + 44 * F.scale),
                    1.0 * F.scale, pal.a(pal.RADAR_TILE, 0.6), true)
        for k, r in ipairs(seen[team] or {}) do
            local ry0 = y + 54 * F.scale + (k - 1) * line
            local a = r.self and 1 or 0.8
            -- Your own row keeps the field the scoreboard gives it, so the
            -- one line you are looking for is the one that is lit.
            if r.self then
                wash(cx + 10 * F.scale, ry0 - line / 2, cw - 20 * F.scale, line,
                     pal.a(pal.FRIEND, 0.12))
            end
            txt(r.name, cx + 18 * F.scale, ry0, 12.5 * F.scale,
                pal.a(r.self and pal.FRIEND or pal.INK, a), nil, nil, true)
            -- The best gun in the room, whichever side it was on. One mark
            -- rather than a column, because it is one pilot.
            if r == mvp then
                txt("mvp", cx + cw - 68 * F.scale, ry0, 9.5 * F.scale,
                    pal.a(pal.CHARGE_COL, 0.85), "right")
            end
            txt(r.k .. "  " .. r.d, cx + cw - 18 * F.scale, ry0, 12 * F.scale,
                pal.a(pal.DIM, 0.95), "right")
        end
    end

    -- What the match paid you, and when the next one starts. The payout is
    -- your own bounty taken, which is the number the wallet moves by.
    local foot = y + h - 6 * F.scale
    local mine
    for _, r in ipairs(rows) do if r.self then mine = r end end
    if mine then
        local paid = mine.p or 0
        txt("banked " .. paid .. (paid == 1 and " rivet" or " rivets"),
            x + 12 * F.scale, foot, 12 * F.scale, pal.a(pal.INK, 0.9))
    end
    local left = m.left or 0
    txt(string.format("next match in %d:%02d", math.floor(left / 60), left % 60),
        x + w - 12 * F.scale, foot, 12 * F.scale, pal.a(pal.DIM, 0.95), "right")
end

function M.hud(o)
    F.case = "upper"
    if sim.ship_count() == 0 then return end
    local me = o.me
    -- Before anything draws: every instrument that separates a friend from an
    -- enemy reads this, and while watching it is not the subject's side.
    view_team = o.side or team_of(o.me)
    F.menu_up = o.menu_open
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
    F.text_dim = (o.menu_open or M.room_ask) and 0.34 or 1

    -- On a touchscreen the bottom of the screen belongs to the thumbs. The
    -- stick sits in the bottom left corner and the pads in the bottom right,
    -- which is exactly where the status panel and the control hint were, so
    -- everything else moves up out of the way of them.
    local lift = M.touching and 150 * F.scale or 0

    -- One panel in this column at a time. The rooms list stands in the
    -- scoreboard's slot, so whichever is up is the one drawn.
    M.zone_name = (o.zone or ""):match("^[^\n]*")
    local top = rooms_panel(o.rooms, o.room)
    if top == 0 then
        top = scores(me, o.pilots, o.watchers, o.viewer_name)
    end
    -- Names hanging off ships, but not under the menu. Glyphs come from the
    -- gui and the gui draws over every mesh, so nothing the menu lays down
    -- can cover them: a panel with six pilots' names scattered through it
    -- reads as a fault rather than as depth. The instruments stay -- your
    -- bars, the dial, the feed -- because you can still be shot while you
    -- are reading, and those are what say so.
    -- The ending is text over a card and lands in the same trap, so it takes
    -- the plates down with it for the twenty five seconds it is up.
    local ending = o.match ~= nil and not o.match.playing
    if not o.menu_open and not ending then nameplates(o) end
    -- One corner, one instrument. The map is the radar pulled back to the
    -- whole thousand tiles, so it stands where the radar stands rather than
    -- somewhere else with the radar still lit beside it.
    if M.map then overview(me) else radar(o.cam_x, o.cam_y, me) end
    link(o.link_bars or 4)
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
    menu_button(o.on_air and not o.watch, o.watch, several and o.room or nil,
                o.pilots, o.watchers)
    vignette(o.hurt or 0)
    -- After the stack, because it is hung off the rows the stack published,
    -- and after the tint so a hurt frame does not wash out the words.
    if not (o.watch or M.touching) then
        stack_card(o, me)
    end
    -- Above the two big centered lines and above the menu's own early return:
    -- the clock is what the topbar carries and a player reading a menu still
    -- wants it. See `match_clock`.
    -- Kept for the menu, which is drawn after this in the same frame and has
    -- no connection of its own to ask. The alternative is a second copy of
    -- the same question in the view.
    M.side_names = o.side_names
    -- And the roster itself, for the column the menu draws beside its page.
    -- The scoreboard fills this when somebody opens the scoreboard; the menu
    -- is open right now and is about to read it.
    if o.menu_open then
        refresh_players(o.pilots, o.watchers, nil, o.viewer_name)
    end
    match_clock(o.match, o.side_names, o.menu_open)
    -- The two big centered lines are the only interface that sits where the
    -- menu does. The panels can share the screen with it; these cannot.
    if o.menu_open then return end
    -- The ending, while the room counts down to the next one. Same place, same
    -- reason: it is the thing being read.
    if o.match and not o.match.playing then
        podium(o, o.match, o.side_names)
        return
    end
    -- Over the arena and under nothing, since it is the thing being read. The
    -- game carries on behind it: nothing is paused here, and a player who
    -- opens this in a fight can still be shot while they read.
    if M.help then
        help_table()
    elseif M.help_prompt then
        help_prompt()
    end
    flag_strip(me)
    if o.banner and o.banner ~= "" then
        txt(o.banner, F.w / 2, 64 * F.scale, (M.compact and 15 or 24) * F.scale,
            pal.a(pal.INK, 0.92), "center")
    end
    if o.lag_notice and o.lag_notice ~= "" then
        txt(o.lag_notice, F.w / 2, 92 * F.scale, (M.compact and 10 or 13) * F.scale,
            pal.a(pal.HURT, 0.95), "center")
    end
    if not o.watch and sim.ship_alive(me) == 0 then
        txt("D E S T R O Y E D", F.w / 2, F.h * 0.46, (M.compact and 15 or 22) * F.scale,
            pal.ENEMY, "center")
    elseif not o.watch and (o.safe or 0) > 0 then
        safe_note(o.safe, o.safe_limit or 0)
    end
end


-- --- the shop --------------------------------------------------------------

-- What rivets buy, as a grid of cards rather than a list of rows.
--
-- A card because a shelf item is three things at once: what it is, what it
-- costs, and what it does. A row can hold two of those and the third goes
-- into a sentence nobody has room for, which is how the description ended up
-- being dropped the first time this page was drawn.
--
-- The wallet stands beside the grid rather than in it, because it is the one
-- number every price on the page is measured against.
function pages.shop(v, x, y, w, h, focused)
    local sidew = math.min(210 * F.scale, w * 0.24)
    local gap = 20 * F.scale
    local gx = x + sidew + gap
    local gw = w - sidew - gap

    -- The wallet, and where it comes from.
    lbl("balance", x, y + 16 * F.scale)
    txt(tostring(v.pilot and v.pilot.rivets or 0), x, y + 46 * F.scale,
        25 * F.scale, pal.a(pal.INK, 0.95))
    lbl("rivets", x + text_w(tostring(v.pilot and v.pilot.rivets or 0),
                             25 * F.scale) + 10 * F.scale,
        y + 48 * F.scale, pal.a(pal.DIM, 0.85))
    local ny = y + 70 * F.scale
    for _, line in ipairs(wrapped("what a bounty pays in, and what it buys "
                                  .. "is which slots you may fill",
                                  11.5 * F.scale, sidew - 8 * F.scale)) do
        txt(line, x, ny, 11.5 * F.scale, pal.a(pal.DIM, 0.8), nil, nil, true)
        ny = ny + 16 * F.scale
    end
    ny = ny + 10 * F.scale
    ticks(x, ny, sidew - 8 * F.scale, pal.a(pal.RADAR_TILE, 0.45),
          14 * F.scale)
    ny = ny + 16 * F.scale
    for _, line in ipairs(wrapped("nothing here makes a ship stronger: "
                                  .. "everything trades against the same "
                                  .. "thirty", 11.5 * F.scale,
                                  sidew - 8 * F.scale)) do
        txt(line, x, ny, 11.5 * F.scale, pal.a(pal.DIM, 0.6), nil, nil, true)
        ny = ny + 16 * F.scale
    end
    vrule(gx - 16 * F.scale, y + 6 * F.scale, h - 12 * F.scale,
          pal.a(pal.RADAR_TILE, 0.45), 16 * F.scale)

    -- The grid. Three across on a desktop, which is what leaves a card wide
    -- enough for a sentence at a size somebody would read.
    local cols = math.max(1, math.floor(gw / (185 * F.scale)))
    local cwid = (gw - (cols - 1) * 11 * F.scale) / cols
    -- A card is as tall as what it has to say. Everything in one group says
    -- the same amount, so the height is decided per group rather than per
    -- card and a row of them still lines up.
    local tall = {}
    for _, r in ipairs(v.rows or {}) do
        if r.sect then tall[r.sect] = 40 * F.scale end
    end
    local sect = nil
    for _, r in ipairs(v.rows or {}) do
        if r.sect then sect = r.sect end
        if sect and r.note and r.note ~= "" then
            tall[sect] = 62 * F.scale
        end
    end
    local chgt = 62 * F.scale
    local cy = y + 8 * F.scale
    local col = 0
    sect = nil
    for _, r in ipairs(v.rows or {}) do
        if r.sect and r.sect ~= sect then
            sect = r.sect
            if col > 0 then cy = cy + chgt + 11 * F.scale col = 0 end
            if cy > y + 8 * F.scale then cy = cy + 6 * F.scale end
            lbl(sect, gx, cy + 10 * F.scale)
            cy = cy + 20 * F.scale
            chgt = tall[sect] or 62 * F.scale
        end
        local cx = gx + col * (cwid + 11 * F.scale)
        local hot = (r.index == v.sel)
        -- `full` is the wallet being short, which is a card you can read and
        -- not press. It keeps its price, because a shop that shows only what
        -- you can afford never says what you are saving for.
        local held = r.full
        rect(cx, cy, cwid, chgt, pal.rgb(0x05070c, 0.55))
        vrule(cx, cy, chgt, pal.a(hot and pal.FRIEND or pal.RADAR_TILE,
                                  hot and 0.9 or 0.55), 18 * F.scale)
        if hot then
            wash(cx, cy, cwid, chgt,
                 pal.a(pal.FRIEND, focused and 0.16 or 0.08))
        end
        txt(r.label or "", cx + 14 * F.scale, cy + 16 * F.scale, 15 * F.scale,
            pal.a(pal.INK, held and 0.6 or 0.95), nil, MENU_FONT)
        -- The price, or nothing where the wallet cannot reach it: a shop that
        -- shows only what you can afford never says what you are saving for,
        -- so the number stays and the card goes back a shade.
        txt(r.detail or "", cx + cwid - 12 * F.scale, cy + 16 * F.scale,
            12 * F.scale, pal.a(held and pal.DIM or pal.CHARGE_COL,
                                held and 0.8 or 0.95), "right")
        local ly = cy + 36 * F.scale
        for _, line in ipairs(wrapped(r.note or "", 11 * F.scale,
                                      cwid - 26 * F.scale)) do
            txt(line, cx + 14 * F.scale, ly, 11 * F.scale,
                pal.a(pal.DIM, 0.85), nil, nil, true)
            ly = ly + 14 * F.scale
        end
        if r.pick then hit(cx, cy, cwid, chgt, "stage", r.index) end
        col = col + 1
        if col >= cols then col = 0 cy = cy + chgt + 11 * F.scale end
    end
end

-- --- the week --------------------------------------------------------------

-- The standings, as a table with a column apiece and the reader's own line
-- lit wherever it falls.
--
-- A table because every number here is being compared with the one above it,
-- which is what a column is for and what a row of "13w 11k" cannot do: two
-- pilots' kills sit at different places on the line the moment one of them
-- has won more.
function pages.week(v, x, y, w, h, focused)
    local sidew = math.min(250 * F.scale, w * 0.28)
    local gap = 22 * F.scale
    local tw = w - sidew - gap
    local sx2 = x + tw + gap

    -- The columns, right-aligned off the table's own right edge so the
    -- numbers line up under their names.
    local cols = {{"run", 0}, {"kills", 54}, {"won", 112}}
    local rowh = 26 * F.scale
    local ty = y + 14 * F.scale
    lbl("#", x + 6 * F.scale, ty)
    lbl("pilot", x + 34 * F.scale, ty)
    for _, c in ipairs(cols) do
        lbl(c[1], x + tw - c[2] * F.scale, ty, nil, "right")
    end
    ty = ty + 10 * F.scale
    ticks(x, ty, tw, pal.a(pal.RADAR_TILE, 0.45), 14 * F.scale)
    ty = ty + 16 * F.scale

    local mine
    for i, r in ipairs(v.rows or {}) do
        local ry0 = ty + (i - 1) * rowh
        if ry0 + rowh > y + h then break end
        local hot = (r.index == v.sel)
        if r.mark then mine = r end
        if hot then
            wash(x - 8 * F.scale, ry0 - rowh / 2 + 2 * F.scale,
                 tw + 8 * F.scale, rowh - 4 * F.scale,
                 pal.a(pal.FRIEND, focused and 0.2 or 0.1))
        elseif r.mark then
            wash(x - 8 * F.scale, ry0 - rowh / 2 + 2 * F.scale,
                 tw + 8 * F.scale, rowh - 4 * F.scale,
                 pal.a(pal.FRIEND, 0.08))
        end
        local col = r.mark and pal.FRIEND or pal.INK
        txt(tostring(r.rank or i), x + 6 * F.scale, ry0, 11 * F.scale,
            pal.a(pal.DIM, 0.9))
        txt(r.label or "", x + 34 * F.scale, ry0, 14 * F.scale,
            pal.a(col, r.mark and 1 or 0.85), nil, MENU_FONT, true)
        local vals = {r.run or 0, r.kills or 0, r.wins or 0}
        for k, c in ipairs(cols) do
            txt(tostring(vals[k]), x + tw - c[2] * F.scale, ry0, 12 * F.scale,
                pal.a(k == 2 and col or pal.DIM, 0.95), "right")
        end
    end

    vrule(sx2 - 18 * F.scale, y + 6 * F.scale, h - 12 * F.scale,
          pal.a(pal.RADAR_TILE, 0.45), 18 * F.scale)

    -- What the week says about you, which is the one row in it you came to
    -- read. A pilot who has not played this week is told that rather than
    -- shown an empty card.
    lbl("your week", sx2, y + 16 * F.scale)
    if mine then
        txt("#" .. tostring(mine.rank or 0), sx2, y + 46 * F.scale,
            25 * F.scale, pal.a(pal.FRIEND, 0.95))
        lbl("this week", sx2 + text_w("#" .. tostring(mine.rank or 0),
                                      25 * F.scale) + 10 * F.scale,
            y + 48 * F.scale, pal.a(pal.DIM, 0.85))
        local ly = y + 76 * F.scale
        for _, e in ipairs({{"kills", mine.kills or 0},
                            {"matches won", mine.wins or 0},
                            {"best run", mine.run or 0},
                            {"banked", v.pilot and v.pilot.rivets or 0}}) do
            lbl(e[1], sx2, ly, pal.a(pal.DIM, 0.85))
            txt(tostring(e[2]), sx2 + sidew - 24 * F.scale, ly, 12 * F.scale,
                pal.a(pal.INK, 0.9), "right")
            ly = ly + 20 * F.scale
        end
    else
        local ly = y + 46 * F.scale
        for _, line in ipairs(wrapped("nothing yet this week: the table takes "
                                      .. "a kill to put you on it",
                                      11.5 * F.scale, sidew - 24 * F.scale)) do
            txt(line, sx2, ly, 11.5 * F.scale, pal.a(pal.DIM, 0.85),
                nil, nil, true)
            ly = ly + 16 * F.scale
        end
    end
    local ny = y + h - 60 * F.scale
    ticks(sx2, ny, sidew - 24 * F.scale, pal.a(pal.RADAR_TILE, 0.45),
          14 * F.scale)
    ny = ny + 16 * F.scale
    for _, line in ipairs(wrapped("rating says how good you are and moves "
                                  .. "slowly; the week says what you did with "
                                  .. "it lately", 11 * F.scale,
                                  sidew - 24 * F.scale)) do
        txt(line, sx2, ny, 11 * F.scale, pal.a(pal.DIM, 0.7), nil, nil, true)
        ny = ny + 15 * F.scale
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

local function vertical_turn(turn)
    if not turn then return 1 end
    local ct = math.cos(turn)
    return (ct >= 0 and 1 or -1) * (0.2 + 0.8 * math.abs(ct))
end

-- Local now that it is. It was declared up with the glossary's figures and
-- assigned here, because the bounty card drew one; the card is gone and every
-- caller left is below this, so the forward declaration went with it rather
-- than leaving a global behind.
local function thumb(cx, cy, cls, col, scale, turn)
    local h = world.HULLS[cls + 1]
    if not h then return end
    local k = vertical_turn(turn)
    local function trace(src, width, c)
        local pts = {}
        for i = 1, #src, 2 do
            pts[i] = cx + src[i] * scale * k
            pts[i + 1] = ry(cy - (src[i + 1] - h.mid) * scale)
        end
        F.layer:outline(pts, width, c, true)
    end
    trace(h.poly, HULL_PEN * F.scale, col)
    if h.canopy then trace(h.canopy, 1.0 * F.scale, pal.a(col, 0.55)) end
end

-- The column beside a list: what the row under the cursor would do if you
-- pressed it. The play page is the one that has it, and it is there because a
-- list of two modes across a nine hundred point panel is a page with a hole
-- in it and a question it has not answered.
function pages.aside(a, x, y, w, h)
    if not a then return end
    vrule(x - 18 * F.scale, y + 6 * F.scale, h - 12 * F.scale,
          pal.a(pal.RADAR_TILE, 0.45), 18 * F.scale)
    lbl(a.head or "", x, y + 16 * F.scale)
    -- The match, where there is one. Read off the same roster the scoreboard
    -- draws from rather than out of a message of its own, which is what the
    -- ending does and for the same reason: the numbers are already here.
    if a.match then
        local sides, seen = {}, {}
        for _, r in ipairs(rows) do
            if not r.watch and r.team then
                if not seen[r.team] then
                    seen[r.team] = {}
                    sides[#sides + 1] = r.team
                end
                local list = seen[r.team]
                list[#list + 1] = r
            end
        end
        table.sort(sides, function(p1, p2)
            if (p1 == view_team) ~= (p2 == view_team) then
                return p1 == view_team
            end
            return p1 < p2
        end)
        for _, list in pairs(seen) do
            table.sort(list, function(p1, p2)
                if p1.k ~= p2.k then return p1.k > p2.k end
                return p1.d < p2.d
            end)
        end
        local ly = y + 40 * F.scale
        for _, team in ipairs(sides) do
            local col = (team == view_team) and pal.FRIEND or pal.ENEMY
            lbl(M.side_names and M.side_names[team] or "side", x, ly,
                pal.a(col, 0.9))
            local rx2 = x + w - 24 * F.scale
            lbl("k  d", rx2, ly, pal.a(pal.DIM, 0.75), "right")
            ly = ly + 8 * F.scale
            ticks(x, ly, w - 24 * F.scale, pal.a(pal.RADAR_TILE, 0.4),
                  14 * F.scale)
            ly = ly + 16 * F.scale
            for _, r in ipairs(seen[team]) do
                txt(r.name, x, ly, 12.5 * F.scale,
                    pal.a(r.self and pal.FRIEND or pal.INK, r.self and 1 or 0.8),
                    nil, nil, true)
                txt(r.k .. "  " .. r.d, x + w - 24 * F.scale, ly, 11 * F.scale,
                    pal.a(pal.DIM, 0.95), "right")
                ly = ly + 17 * F.scale
            end
            ly = ly + 12 * F.scale
        end
        return
    end
    txt(a.label or "", x, y + 44 * F.scale, 21 * F.scale,
        pal.a(pal.INK, 0.95), nil, MENU_FONT)
    lbl(a.sub or "", x, y + 64 * F.scale, pal.a(pal.DIM, 0.85))
    local ly = y + 88 * F.scale
    for _, e in ipairs(a.rows or {}) do
        lbl(e[1], x, ly, pal.a(pal.DIM, 0.85))
        txt(e[2], x + w - 24 * F.scale, ly, 12 * F.scale,
            pal.a(pal.INK, 0.9), "right")
        ly = ly + 20 * F.scale
    end
    if a.note and a.note ~= "" then
        ly = ly + 10 * F.scale
        local said = string.upper(string.sub(a.note, 1, 1))
                     .. string.sub(a.note, 2)
        for _, line in ipairs(wrapped(said, 12 * F.scale,
                                      w - 24 * F.scale)) do
            txt(line, x, ly, 12 * F.scale, pal.a(pal.DIM, 0.95), nil, nil, true)
            ly = ly + 16 * F.scale
        end
    end
    if a.foot and a.foot ~= "" then
        local ny = y + h - 52 * F.scale
        ticks(x, ny, w - 24 * F.scale, pal.a(pal.RADAR_TILE, 0.45),
              14 * F.scale)
        ny = ny + 16 * F.scale
        for _, line in ipairs(wrapped(a.foot, 11 * F.scale,
                                      w - 24 * F.scale)) do
            txt(line, x, ny, 11 * F.scale, pal.a(pal.DIM, 0.7), nil, nil, true)
            ny = ny + 15 * F.scale
        end
    end
end

-- --- the hangar ------------------------------------------------------------

-- One diamond of a ladder. Filled where the kit spends there, outlined where
-- there is a step left to spend, and drawn back to almost nothing where the
-- hull would take one and the account does not own it yet.
--
-- A diamond rather than a square because a row of squares is a progress bar,
-- and this is not progress: it is a number of things chosen out of a budget,
-- and every one of them cost the same one point.
function pages.pip(cx, cy, k, lit, col)
    local a = {cx, ry(cy - k), cx + k, ry(cy), cx, ry(cy + k), cx - k, ry(cy)}
    if lit == "on" then
        F.layer:quad(a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], col)
    else
        F.layer:outline({a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8]},
                        0.9 * F.scale,
                        pal.a(col, lit == "locked" and 0.14 or 0.34), true)
    end
end

-- A chip: the mocks' box for a thing you either have or do not, with its name
-- and, where the name is jargon, a line about what it does. Rungs and add-ons
-- are chips because they are not ladders you climb but switches you throw.
function pages.chip(x, y, w, h, r, hot, focused)
    local held = (r.choice or 0) > 0
    if held then
        rect(x, y, w, h, pal.a(pal.FRIEND, 0.14))
    end
    if hot then
        F.layer:frame(x, ry(y, h), w, h, 1.2 * F.scale,
                      pal.a(pal.FRIEND, focused and 1 or 0.5))
    else
        F.layer:frame(x, ry(y, h), w, h, 0.9 * F.scale,
                      pal.a(held and pal.FRIEND or pal.RADAR_TILE,
                            held and 0.55 or 0.5))
    end
    lbl(r.short or r.label, x + w / 2, y + h * 0.42,
        pal.a(held and pal.FRIEND or pal.DIM, held and 1 or 0.8), "center",
        9 * F.scale)
    -- How many of it, where more than one is possible. A rung is a ladder in
    -- a chip's clothing: two of them is level two.
    if (r.choices or 1) > 1 then
        txt(tostring(r.choice or 0), x + w / 2, y + h * 0.74, 9 * F.scale,
            pal.a(pal.DIM, 0.85), "center")
    end
end

-- The hangar, as the mocks lay it out: the roster down the left and what
-- thirty points buy on the one you are standing in beside it.
--
-- Two levels of the stack are on screen at once. That is the whole reason the
-- page is drawn by hand rather than as a list: picking a hull and spending its
-- thirty are the same act seen twice, and a page that showed one at a time
-- made a player memorise the ship they had just left.
function pages.kit(v, x, y, w, h, focused)
    -- Three columns, which is the shape the mocks give this page: who you
    -- could fly, what the one under the cursor is, and what thirty points buy
    -- on it. The middle is the only part of the hangar that is about the ship
    -- rather than about the choosing, and it is what the grid this replaced
    -- had no room for.
    local hullw = math.min(212 * F.scale, w * 0.24)
    local gap = 20 * F.scale
    local dw = math.min(240 * F.scale, w * 0.26)
    local dx = x + hullw + gap
    local kx = dx + dw + gap
    local kw = w - hullw - dw - 2 * gap

    -- The roster. It is the level above this one, so its cursor is only lit
    -- while the arrows are up there.
    local rowh = 34 * F.scale
    lbl("hull", x + 14 * F.scale, y + 14 * F.scale)
    local hy = y + 30 * F.scale
    for i, e in ipairs(v.hulls or {}) do
        local ry0 = hy + (i - 1) * rowh
        local here = (e.index == v.hull_sel)
        local mine = e.mark
        if here then
            wash(x, ry0, hullw, rowh,
                 pal.a(pal.FRIEND, v.hull_focus and 0.2 or 0.1))
        end
        local col = (here or mine) and pal.FRIEND or pal.INK
        if e.figure == "pilot" then
            pilot_mark(x + 26 * F.scale, ry0 + rowh / 2,
                       pal.a(col, (here or mine) and 1 or 0.55),
                       rowh * 0.26, 1.2 * F.scale)
        else
            thumb(x + 26 * F.scale, ry0 + rowh / 2, e.hull or 0,
                  pal.a(col, (here or mine) and 1 or 0.55), rowh / 116)
        end
        txt(e.label, x + 48 * F.scale, ry0 + rowh / 2, 15 * F.scale,
            pal.a(col, (here or mine) and 1 or 0.7), nil, MENU_FONT)
        lbl(e.role or "", x + hullw - 12 * F.scale, ry0 + rowh / 2 + 1 * F.scale,
            pal.a(pal.DIM, here and 0.95 or 0.7), "right", 8 * F.scale)
        hit(x, ry0, hullw, rowh, "hull", e.index)
    end

    vrule(dx - 16 * F.scale, y + 6 * F.scale, h - 12 * F.scale,
          pal.a(pal.RADAR_TILE, 0.45), 16 * F.scale)
    vrule(kx - 16 * F.scale, y + 6 * F.scale, h - 12 * F.scale,
          pal.a(pal.RADAR_TILE, 0.45), 16 * F.scale)

    -- The hull itself, at the size a drawing is worth looking at, with what it
    -- is for under it and what it will take under that.
    do
        local cx = dx + dw / 2
        local cy = y + 62 * F.scale
        local pick
        for _, e in ipairs(v.hulls or {}) do
            if e.index == v.hull_sel then pick = e end
        end
        if pick and pick.figure == "pilot" then
            pilot_mark(cx, cy, pal.a(pal.FRIEND, 0.95), 44 * F.scale,
                       1.8 * F.scale)
        elseif pick then
            -- Turning, because it is the one drawing on this page that is
            -- about the ship rather than about the choosing, and a hull seen
            -- from one angle is a silhouette rather than a shape.
            thumb(cx, cy, pick.hull or 0, pal.a(pal.FRIEND, 0.95),
                  1.9, F.now * 0.7)
        end
        local ty = y + 132 * F.scale
        txt(pick and pick.label or "", cx, ty, 24 * F.scale,
            pal.a(pal.INK, 0.95), "center", MENU_FONT)
        local roley = ty + 18 * F.scale
        lbl(pick and pick.role or "", cx, roley, nil, "center")
        -- One sentence, wrapped. Drawn raw and capitalised once by hand: the
        -- menu sets its type in a sentence's case, and a sentence broken
        -- across three lines is three sentences to that rule.
        local ly = ty + 40 * F.scale
        local said = pick and pick.detail or ""
        said = string.upper(string.sub(said, 1, 1)) .. string.sub(said, 2)
        for _, line in ipairs(wrapped(said, 12 * F.scale, dw - 16 * F.scale)) do
            txt(line, cx, ly, 12 * F.scale, pal.a(pal.DIM, 0.95), "center",
                nil, true)
            ly = ly + 17 * F.scale
        end

        -- The shape, which is the whole of what this hull is.
        --
        -- A row of ceilings stood here: how far the ladders climbed, how many
        -- charge kinds it took, how many it carried. None of that belongs to a
        -- hull any more, because none of it could be sold while it did. What
        -- is left is measured off the drawing and collided against at every
        -- wall, and it is worth reading: weapons test the oriented rectangle,
        -- so a beam of twelve is genuinely half the target a beam of
        -- twenty-eight is when you turn side-on.
        local ext = pick and pick.extent
        if ext then
            ly = ly + 14 * F.scale
            ticks(dx, ly, dw, pal.a(pal.RADAR_TILE, 0.45), 14 * F.scale)
            ly = ly + 16 * F.scale
            lbl("footprint", dx, ly)
            ly = ly + 18 * F.scale
            local shape = {{"nose", ext.fore}, {"tail", ext.aft},
                           {"beam", ext.beam}}
            for _, e in ipairs(shape) do
                lbl(e[1], dx, ly, pal.a(pal.DIM, 0.85))
                txt(e[2] .. " px", dx + dw - 8 * F.scale, ly, 11 * F.scale,
                    pal.a(pal.INK, 0.9), "right")
                ly = ly + 19 * F.scale
            end
        end
    end

    -- The kit. `v.rows` is the model in the order a pilot thinks about it, and
    -- the groups are drawn where they belong rather than where they fall.
    --
    -- While the arrows are in the roster this is a preview of the hull they
    -- are standing on, so nothing in it is the cursor and nothing in it takes
    -- a press. `v.sel` indexes the roster then, and a kit row whose index
    -- happened to match would light for no reason a player could explain.
    local budget, stats, guns, bombs, charges = nil, {}, {}, {}, {}
    for _, r in ipairs(v.rows or {}) do
        if r.bar then budget = r
        elseif r.group == "flight" then stats[#stats + 1] = r
        elseif r.group == "charges" then charges[#charges + 1] = r
        elseif r.trigger == 1 then bombs[#bombs + 1] = r
        else guns[#guns + 1] = r end
    end
    local live = not v.kit_preview
    local function cursor(r) return live and r.index == v.sel end

    local cy = y + 14 * F.scale

    -- What the budget is, as a bar and as a number. It is the one figure the
    -- whole page is spending against, so it stands at the head of it.
    if budget then
        local spent, total = budget.choice or 0, budget.choices or 30
        local left = total - spent
        lbl("kit", kx, cy + 8 * F.scale)
        local bx = kx + 34 * F.scale
        local bw = kw - 34 * F.scale - 150 * F.scale
        rect(bx, cy + 5 * F.scale, bw, 5 * F.scale,
             pal.a(pal.RADAR_TILE, 0.35))
        if spent > 0 then
            rect(bx, cy + 5 * F.scale, bw * math.min(1, spent / total),
                 5 * F.scale, pal.a(pal.FRIEND, 0.9))
        end
        txt(tostring(spent), bx + bw + 12 * F.scale, cy + 8 * F.scale,
            17 * F.scale, pal.a(pal.INK, 0.95))
        txt("/ " .. total, bx + bw + 12 * F.scale
            + text_w(tostring(spent), 17 * F.scale) + 6 * F.scale,
            cy + 9 * F.scale, 12 * F.scale, pal.a(pal.DIM, 0.9))
        txt(left .. " left", kx + kw, cy + 8 * F.scale, 13 * F.scale,
            pal.a(left == 0 and pal.DIM or pal.CHARGE_COL, 0.95), "right")
        cy = cy + 24 * F.scale
    end

    local function rule(label, note)
        cy = cy + 6 * F.scale
        ticks(kx, cy, kw, pal.a(pal.RADAR_TILE, 0.45), 14 * F.scale)
        cy = cy + 16 * F.scale
        if label then
            lbl(label, kx, cy)
            if note then
                lbl(note, kx + text_w(label, 9 * F.scale) + 16 * F.scale, cy,
                    pal.a(pal.DIM, 0.55), nil, 8.5 * F.scale)
            end
            cy = cy + 14 * F.scale
        end
    end

    -- The stats: five ladders of six, and the two steps past six that the
    -- shop sells, behind a divider so the page says which is which without a
    -- word about it.
    rule("stats", "six a stat is the whole budget, the last two are bought")
    local srow = 26 * F.scale
    for _, r in ipairs(stats) do
        local hot = cursor(r)
        if hot then wash(kx - 14 * F.scale, cy - srow / 2 + 2 * F.scale,
                         kw + 14 * F.scale, srow - 2 * F.scale,
                         pal.a(pal.FRIEND, focused and 0.2 or 0.1)) end
        local col = r.tint_col or pal.FRIEND
        lbl(r.short or "", kx, cy, pal.a(col, hot and 1 or 0.8), nil,
            9.5 * F.scale)
        local px = kx + 40 * F.scale
        local base = math.min(6, r.arena_max or 6)
        local step = 13 * F.scale
        for k = 1, base do
            pages.pip(px, cy, 4.4 * F.scale,
                 (r.choice or 0) >= k and "on" or "off", col)
            px = px + step
        end
        if (r.arena_max or 0) > base then
            F.layer:seg(px - 3 * F.scale, ry(cy - 5.5 * F.scale),
                        px - 3 * F.scale, ry(cy + 5.5 * F.scale),
                        1.0 * F.scale, pal.a(pal.RADAR_TILE, 0.6), true)
            px = px + 5 * F.scale
            for k = base + 1, r.arena_max do
                local lit = "locked"
                if k <= (r.owned or 0) then
                    lit = (r.choice or 0) >= k and "on" or "off"
                end
                pages.pip(px, cy, 4.4 * F.scale, lit, col)
                px = px + step
            end
        end
        txt(tostring(r.choice or 0), px + 10 * F.scale, cy, 11 * F.scale,
            pal.a(pal.INK, hot and 0.95 or 0.7))
        txt(r.label, px + 28 * F.scale, cy, 12 * F.scale,
            pal.a(pal.DIM, hot and 1 or 0.85), nil, MENU_FONT)
        if live and r.pick then hit(kx - 14 * F.scale, cy - srow / 2, kw, srow,
                           "stage", r.index) end
        cy = cy + srow
    end

    -- The triggers. A rung and its add-ons, per trigger, as chips.
    local cw, ch = 62 * F.scale, 36 * F.scale
    local function chips_for(list, label)
        if #list == 0 then return end
        rule(label)
        local px = kx
        for _, r in ipairs(list) do
            if px + cw > kx + kw then px = kx cy = cy + ch + 6 * F.scale end
            pages.chip(px, cy - 2 * F.scale, cw, ch, r, cursor(r), focused)
            if live and r.pick then hit(px, cy - 2 * F.scale, cw, ch, "stage", r.index) end
            px = px + cw + 8 * F.scale
        end
        cy = cy + ch + 8 * F.scale
    end
    chips_for(guns, "gun")
    chips_for(bombs, "bomb")

    -- The charges, which are the one thing on this page a death does not give
    -- back, so the page says so where they are chosen.
    if #charges > 0 then
        rule("charges", "spent charges do not come back when you die")
        for _, r in ipairs(charges) do
            local hot = cursor(r)
            if hot then wash(kx - 14 * F.scale, cy - srow / 2 + 2 * F.scale,
                             kw + 14 * F.scale, srow - 2 * F.scale,
                             pal.a(pal.FRIEND, focused and 0.2 or 0.1)) end
            txt(r.label, kx, cy, 13 * F.scale,
                pal.a(pal.INK, hot and 0.95 or 0.8), nil, MENU_FONT)
            local px = kx + 92 * F.scale
            for k = 1, (r.choices or 0) do
                pages.pip(px, cy, 4.4 * F.scale,
                     (r.choice or 0) >= k and "on" or "off", pal.CHARGE_COL)
                px = px + 13 * F.scale
            end
            if live and r.pick then hit(kx - 14 * F.scale, cy - srow / 2, kw, srow,
                               "stage", r.index) end
            cy = cy + srow
        end
    end
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
-- The keys and how wide each one is, and nothing about what any of them
-- does. What a key does is the view's to say now, since it is a pilot's to
-- change; this is the shape of a keyboard, which is not.
local BOARD = {
    {{"esc", 1.0}, {"`"}, {"1"}, {"2"}, {"3"}, {"4"}, {"5"}, {"6"}, {"7"},
     {"8"}, {"9"}, {"0"}, {"-"}, {"="}, {"bksp", 1.0}},
    {{"tab", 1.5}, {"Q"}, {"W"}, {"E"}, {"R"}, {"T"}, {"Y"}, {"U"}, {"I"},
     {"O"}, {"P"}, {"["}, {"]"}, {"\\", 1.5}},
    {{"caps", 1.75}, {"A"}, {"S"}, {"D"}, {"F"}, {"G"}, {"H"}, {"J"}, {"K"},
     {"L"}, {";"}, {"'"}, {"enter", 2.25}},
    {{"shift", 2.25}, {"Z"}, {"X"}, {"C"}, {"V"}, {"B"}, {"N"}, {"M"},
     {","}, {"."}, {"/"}, {"shift", 2.75}},
    {{"ctrl", 1.6}, {"space", 13.4}},
}

-- Which row of the page sits on which key of the picture, built once per draw.
-- The chips and the board are the same list read two ways, and this is where
-- the second reading happens: one table, so they cannot disagree about where
-- a control is.
--
-- Keyed by what the board writes on a key rather than by the key's own name,
-- because that is what the drawing loop below has in its hand.
--
-- A binding may be a chord, so a key can belong to more than one control:
-- Shift is half of the mine and Tab is the whole of the bomb and half of the
-- mine as well. The shortest chord wins the color, which is the binding a hand
-- falls back to and the one the key would fire on its own; every chord the key
-- is in still counts for the cursor, so resting on the mine brackets both of
-- its keys rather than one.
local function bind_map(v)
    local out = {}
    for i, r in ipairs(v.rows or {}) do
        for _, id in ipairs(r.keys or {}) do
            local k = keyset.by_id[id]
            local at = k and (k.label or k.id)
            if at then
                local e = out[at]
                if not e then
                    e = {on = {}, n = math.huge}
                    out[at] = e
                end
                -- The shortest chord owns the color: it is the binding the
                -- key would fire on its own, and the one a hand falls back to.
                if #r.keys < e.n then e.row, e.n = r, #r.keys end
                e.on[i] = true
                -- And whichever chord is asking owns the whole key while it
                -- is, however long it is. Mines are Shift and Tab, and Tab is
                -- also the bomb: reading the shortest chord for this left the
                -- board lighting half the chord it was waiting to be told.
                if r.arming then e.asking = r end
            end
        end
    end
    return out
end
-- Fifteen units of main block, then the navigation cluster beside it, where it
-- is on the keyboard this is a picture of. It used to hang off the right of
-- the two bottom rows, in the space a board that stopped at M left empty; the
-- board runs to the punctuation now and that space is a row of keys.
local BOARD_MAIN = 15
local BOARD_GAP = 0.4
local BOARD_UNITS = BOARD_MAIN + BOARD_GAP + 3
-- How wide the page that draws it may go, against the 460 every other page
-- takes. A menu of six words does not want the room; a picture of a keyboard
-- does, and on a desktop window there is a thousand points of it going spare.
-- The column keeps its left edge and grows to the right, so nothing jumps when
-- the page changes.
-- Everything on the board is sized off the key, so the whole picture scales
-- with the panel rather than a drawing growing around type that does not.
local KEY_LETTER = 0.40   -- a single character, against key height
local KEY_WORD = 0.30     -- "shift", "space": the ones that have to fit across

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
    if cat == "gun" then return pal.FRIEND end
    if cat == "multi" then return pal.MOD_COL end
    if cat == "bomb" then return pal.BOMB end
    if cat == "charge" then return pal.CHARGE_COL end
    if cat == "fly" then return pal.INK end
    if cat == "players" then return pal.DOOR end
    if cat == "map" then return pal.HOLE end
    if cat == "menu" then return pal.ENEMY end
    -- The one key that explains the rest of them, in the ink the interface
    -- names things with. It opens a slab of words rather than a panel.
    if cat == "help" then return pal.PANEL_INK end
    return nil
end

-- One key: an outline in its function's color with a hint of fill, or a
-- faint outline for a key the game does not use. `cy` is the row's top.
--
-- `dimmed` is Ctrl and nothing else: a gun the browser only surrenders in
-- fullscreen, drawn at half light so the board says "sometimes" without a
-- footnote on it. It is not in the list of controls because it cannot be
-- moved, so the picture is the only thing that knows about it.
local function board_key(bx, cy, kw, kh, label, cat, dimmed)
    local col = board_col(cat)
    if col and not dimmed then
        rect(bx, cy, kw, kh, pal.a(col, 0.10))
        F.layer:frame(bx, ry(cy, kh), kw, kh, 1.1 * F.scale, pal.a(col, 0.85))
    elseif col then
        -- Ctrl: a gun the browser only surrenders in fullscreen, drawn at
        -- half light so the board says "sometimes" without a footnote on it.
        F.layer:frame(bx, ry(cy, kh), kw, kh, 1.1 * F.scale, pal.a(col, 0.35))
    else
        F.layer:frame(bx, ry(cy, kh), kw, kh, 0.8 * F.scale, pal.a(pal.DIM, 0.22))
    end
    if label then
        local size = kh * (#label > 1 and KEY_WORD or KEY_LETTER)
        -- A word on a one-unit key would run over both its edges, so it takes
        -- whichever is smaller: the key's height or the room across it.
        local across = (kw - 6 * F.scale) / (#label * ADVANCE)
        if size > across then size = across end
        local ink = col and pal.a(col, dimmed and 0.5 or 0.95)
            or pal.a(pal.DIM, 0.4)
        txt(label, bx + kw / 2, cy + kh / 2, size, ink, "center")
    end
end

-- A direction, as a triangle, because the gui font's charset is picked over
-- and an arrow glyph it does not carry would draw as nothing.
local function board_arrow(cx, cy, dx, dy, col)
    local r = 3.6 * F.scale
    F.layer:tri(cx + dx * r, ry(cy + dy * r),
          cx - dx * r + dy * r, ry(cy - dy * r - dx * r),
          cx - dx * r - dy * r, ry(cy - dy * r + dx * r), col)
end

-- The whole board, drawn into the panel at `x, top`, `w` wide. Returns its
-- height so the caller can size the panel around it.
local function board(x, top, w, v)
    v = v or {}
    local on = bind_map(v)
    -- While a control is waiting for a key, every other key is a place it
    -- could land, so the board stops saying what it holds and starts saying
    -- what is free: everything drops to the outline an unbound key wears and
    -- the only lit thing left is the one that is asking.
    local arming = v.arming
    local unit = w / BOARD_UNITS
    local kh = unit * 0.82
    local pitch = kh + 3 * F.scale
    -- Which key the picture puts a bracket round, and which one stays lit
    -- while everything else goes dark. Resting, both are the cursor. Asking,
    -- both are the control that is asking, which is the row's own flag rather
    -- than the cursor: they are the same row in the game, and reading the
    -- cursor for it would let the page light one key while the chip with the
    -- empty slot in it was somewhere else.
    local function state_of(hit_row)
        if not hit_row then return false, false end
        if arming then
            local asking = hit_row.asking ~= nil
            return asking, asking
        end
        -- `on` is every row this key is part of, so a key that is a modifier
        -- for one control and the whole of another lights under the cursor of
        -- either. The color still comes from the shortest of them.
        return hit_row.on[v.sel] == true, false
    end

    -- Whether the cursor is on this key, and which control's color it wears.
    -- A nil color is a key drawn dark. `force` is for the one key whose color
    -- does not come from the list; it still goes out with the rest of them
    -- while a binding is being asked for.
    --
    -- Both halves of the board ask this: the main block below and the arrow
    -- cluster under it, which drew its keys differently and worked out their
    -- state identically. Chords had to be taught to both, one line each, and
    -- the arrows would have been the copy somebody missed.
    local function key_look(label, force)
        local hit_row = on[label]
        local sel, keep = state_of(hit_row)
        local cat = hit_row and hit_row.row.cat
        if keep and hit_row.asking then cat = hit_row.asking.cat end
        if force then cat = force end
        if arming and not keep then cat = nil end
        return sel, cat
    end

    -- The cursor: the same chamfered bracket that holds a cluster together
    -- everywhere else, round the key whose chip the cursor is on. Not a
    -- second color, so the key goes on saying what it does.
    local function key_cursor(bx, cy, kw)
        bracket(bx - 3 * F.scale, cy - 3 * F.scale, kw + 6 * F.scale, kh + 6 * F.scale,
                pal.a(pal.INK, arming and 0.95 or 0.7), 9 * F.scale, 3 * F.scale)
    end

    local function draw(bx, cy, kw, label)
        -- Ctrl is the one key on the board whose control is not in the list:
        -- it fires guns, it cannot be moved, and the browser only surrenders
        -- it in fullscreen. So the picture carries it on its own, at half
        -- light, which is the board saying "sometimes" without a footnote.
        local sel, cat = key_look(label, label == "ctrl" and "gun" or nil)
        board_key(bx, cy, kw, kh, label, cat, label == "ctrl")
        if sel then key_cursor(bx, cy, kw) end
        -- And the key itself is the control. A picture of a keyboard with a
        -- list of keys under it, where only the list answers a click, is a
        -- diagram somebody has to be told is not the thing.
        local k = keyset.by_label[label]
        if k and keyset.bindable(k.id) then
            hit(bx, cy, kw, kh, "key", k.id)
        end
    end
    for r, row in ipairs(BOARD) do
        local bx = x
        local cy = top + (r - 1) * pitch
        for _, k in ipairs(row) do
            local kw = (k[2] or 1) * unit - 3 * F.scale
            draw(bx, cy, kw, k[1])
            bx = bx + (k[2] or 1) * unit
        end
    end
    -- Page Up and Page Down, in the right column above the arrows. The other
    -- navigation keys do nothing in this game, so drawing their empty caps
    -- would spend room on a diagram nobody can use.
    local aw = unit
    local ax = x + (BOARD_MAIN + BOARD_GAP) * unit
    local navw = aw - 3 * F.scale
    draw(ax + 2 * aw, top, navw, "pgup")
    draw(ax + 2 * aw, top + pitch, navw, "pgdn")
    -- The arrows, as the inverted T they are on the board: up over down, in
    -- the corner the two bottom rows leave empty. Each entry is a column, a
    -- row off the shift row, and the direction its triangle points.
    for _, d in ipairs({{1, 0, 0, -1, "up"}, {0, 1, -1, 0, "left"},
                        {1, 1, 0, 1, "down"}, {2, 1, 1, 0, "right"}}) do
        local kx = ax + d[1] * aw
        local cy = top + (3 + d[2]) * pitch
        local kw = aw - 3 * F.scale
        local sel, cat = key_look(d[5])
        local col = board_col(cat)
        if col then
            rect(kx, cy, kw, kh, pal.a(col, 0.08))
            F.layer:frame(kx, ry(cy, kh), kw, kh, 1.1 * F.scale, pal.a(col, 0.75))
            board_arrow(kx + kw / 2, cy + kh / 2, d[3], d[4], pal.a(col, 0.95))
        else
            F.layer:frame(kx, ry(cy, kh), kw, kh, 0.8 * F.scale, pal.a(pal.DIM, 0.22))
            board_arrow(kx + kw / 2, cy + kh / 2, d[3], d[4],
                        pal.a(pal.DIM, 0.4))
        end
        if sel then key_cursor(kx, cy, kw) end
        hit(kx, cy, kw, kh, "key", d[5])
    end

    return 5 * pitch + 2 * F.scale
end

-- What the board will ask for, so the panel can be sized before drawing it.
-- Five rows of keys and the gap under them, which is every term the drawing
-- uses, in the order it uses them.
local function board_height(w)
    local kh = (w / BOARD_UNITS) * 0.82
    return 5 * (kh + 3 * F.scale) + 2 * F.scale
end

-- Every control, with the key it is on, under the picture of the board.
--
-- The board alone cannot answer "where is my second charge": four charge keys
-- share one color on it, and a key is under thirty points across at the widest
-- this page ever draws it, which has no room for a word under the letter. So
-- the page keeps both, and they are the same list drawn twice on purpose. The
-- board says where the hand goes; the chips say what each key is for and are
-- where one is changed.
--
-- Three columns, because the full list down one column is a list that scrolls,
-- and a list scrolling under a picture is no longer the same page as the
-- picture: you would be moving the answers past a diagram that stayed still.
local CHIP_COLS = 3
local CHIP_ROW = 26      -- * S
-- Between the last row of keys and the first row of chips.
local CHIP_GAP = 18      -- * S

local function chip_lines(n)
    return math.ceil(n / CHIP_COLS)
end

-- `rh` is a row's height, which the caller works out rather than this: what
-- the board can give up and what the chips need are one sum, and it is done
-- once where the page is measured.
local function chips(x, top, w, v, rh)
    local cw = w / CHIP_COLS
    -- Type off the row, the same way the board sizes a letter off its key, so
    -- a page squeezed into a short window comes out smaller rather than
    -- overlapping itself.
    local fs = math.min(12.5 * F.scale, rh * 0.48)
    for i, r in ipairs(v.rows) do
        local cx = x + ((i - 1) % CHIP_COLS) * cw
        local cy = top + math.floor((i - 1) / CHIP_COLS) * rh
        local hot = i == v.sel
        if hot then
            rect(cx - 6 * F.scale, cy, cw - 4 * F.scale, rh,
                 pal.a(pal.FRIEND, r.arming and 0.22 or 0.16))
        end
        -- The row that puts everything back is not a control and wears no
        -- swatch, so the column of colors down the left is exactly the set of
        -- things that have a key.
        local hue = board_col(r.cat) or pal.DIM
        if not r.reset then
            rect(cx, cy + rh / 2 - 3.5 * F.scale, 7 * F.scale, 7 * F.scale,
                 pal.a(hue, hot and 1 or 0.8))
        end
        txt(r.label or "", cx + 15 * F.scale, cy + rh / 2, fs,
            pal.a(pal.INK, hot and 1 or 0.8), nil, MENU_FONT)
        -- The key, in the face the numbers in flight are set in, because it is
        -- a reading off the machine rather than a word anybody chose. Verbatim
        -- for the same reason: "Esc" is what is written on the key.
        --
        -- While this one is asking, the column is empty and lit. The row that
        -- wants a key is the row with no key in it, and the sentence saying so
        -- is at the foot of the page rather than in a column too narrow to
        -- hold it.
        if r.arming then
            local slot = 18 * F.scale
            rect(cx + cw - 26 * F.scale - slot, cy + rh / 2 - 1 * F.scale, slot, 2 * F.scale,
                 pal.a(hue, 0.55 + 0.45 * math.sin(F.now * 6)))
        elseif r.detail then
            -- A control that cannot move is written in the shade every
            -- unpressable thing here is written in, which says so without a
            -- word for it.
            local ink = r.fixed and pal.DIM or hue
            -- A chord is three or four times as wide as a key, and the name
            -- it has to sit beside does not get any shorter for it. Set down
            -- until the pair fits rather than letting one run under the other,
            -- which is what the board does to a word on a one-unit key.
            local ks = fs
            local room = cw - 26 * F.scale - 15 * F.scale - glyph_w(r.label or "", fs)
                - 10 * F.scale
            while ks > fs * 0.6 and glyph_w(r.detail, ks) > room do
                ks = ks * 0.94
            end
            txt(r.detail, cx + cw - 26 * F.scale, cy + rh / 2, ks,
                pal.a(ink, hot and 1 or 0.75), "right", nil, true)
        end
        if r.pick then hit(cx - 6 * F.scale, cy, cw - 4 * F.scale, rh, "stage", i) end
    end
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
    F.layer:outline(pts, 1.1 * F.scale, pal.a(col, 0.8), true)
    -- Dark in the body and lit at the rim, which is how everything solid in
    -- this game is drawn, from a wall face to a hull.
    F.layer:disc(cx, ry(cy), body, 18, pal.a(pal.BG, 0.94))
    F.layer:ring(cx, ry(cy), body, 1.3 * F.scale, 20, col)
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
    pilot_mark(cx, cy, col, r * 1.6, RAIL_PEN * F.scale)
end

local function mark_team(cx, cy, r, col)
    -- Two pennants, which is what a flag is drawn as in the world.
    for i, k in ipairs({{-0.5, 0.85}, {0.35, 1.0}}) do
        local px, s = cx + r * k[1], r * k[2]
        F.layer:seg(px, ry(cy - s * 0.9), px, ry(cy + s * 0.85), 1.2 * F.scale,
              pal.a(col, i == 2 and 1 or 0.6), true)
        local pts = {px, ry(cy - s * 0.9), px + s * 0.85, ry(cy - s * 0.55),
                     px, ry(cy - s * 0.2)}
        F.layer:fan(pts, pal.a(col, i == 2 and 0.22 or 0.12))
        F.layer:outline(pts, 1.1 * F.scale, pal.a(col, i == 2 and 1 or 0.6), true)
    end
end

local function mark_settings(cx, cy, r, col)
    -- Three rules with a knob apiece, at three different settings, because a
    -- row of identical sliders is a picture of nothing being adjustable.
    for i, k in ipairs({-0.62, 0, 0.62}) do
        local y = cy + r * k
        F.layer:seg(cx - r, ry(y), cx + r, ry(y), 1.0 * F.scale, pal.a(col, 0.45), true)
        local kx = cx + r * ({-0.3, 0.42, -0.05})[i]
        rect(kx - r * 0.17, y - r * 0.26, r * 0.34, r * 0.52, col)
    end
end

-- The arrow cluster, which is what the page it opens is a picture of.
--
-- It carried a question mark for as long as the page was called help, then a
-- blank keycap for about an hour: a key with a `?` on it is a key with a `?`
-- on it, and a key with nothing on it is a box. Four boxes in the shape the
-- arrow keys make are a keyboard, and the shape is doing all of the work,
-- which is why there is nothing drawn on them.
--
-- Arrowheads were, briefly. At the size a rail mark gets they are four
-- triangles about three pixels on a side, and what they add to the inverted T
-- is clutter rather than meaning: the T is already the only thing on a
-- keyboard with that outline.
--
-- Plain boxes for the same reason the heads went. The cut corner is a
-- fraction of the shape it cuts, and a fifth of an eight-point key is a pixel
-- and a half: at that size it is not a chamfer, it is a ragged corner. The
-- board further down the page keeps the cut, its keys being three times the
-- size.
--
-- Sized off the key rather than off the mark, so the gaps stay in proportion
-- when the rail draws this larger or smaller.
local function mark_controls(cx, cy, r, col)
    local k = r * 0.66                 -- one key
    local pitch = k + k * 0.14         -- and the air around it
    local function key(gx, gy)
        local x0 = cx + gx * pitch - k / 2
        local y0 = cy + gy * pitch - k / 2
        rect(x0, y0, k, k, pal.a(col, 0.10))
        F.layer:frame(x0, ry(y0, k), k, k, 1.1 * F.scale, col)
    end
    key(0, -0.5)
    key(-1, 0.5)
    key(0, 0.5)
    key(1, 0.5)
end

local function mark_about(cx, cy, r, col)
    F.layer:ring(cx, ry(cy), r * 0.86, 1.15 * F.scale, 18, col)
    F.layer:disc(cx, ry(cy - r * 0.4), r * 0.15, 8, col)
    F.layer:seg(cx, ry(cy - r * 0.05), cx, ry(cy + r * 0.45), 1.4 * F.scale, col, true)
end

-- Discord's mark, traced from Discord's own file and drawn the way this rail
-- draws everything: a faint fill and an outline, in whatever color the stop is
-- wearing.
--
-- It was a solid Blurple silhouette for a commit, because discord.com/branding
-- says "please do not edit, change, distort, recolor, or reconfigure the
-- Discord logo" and names three colors it may appear in. Chris has that call
-- and made it: a stop that neither lights with its neighbors nor is drawn like
-- them is a foreign object on the rail, and a recognizable outline linking to
-- somebody's own server is what half the web does. The shape is exact; only
-- the ink and the fill are the rail's.
--
-- The geometry is the official path, sampled into rings and triangulated with
-- the eyes as holes, because the layer has no path, no bezier and no even-odd
-- rule to do it with at runtime. Baked rather than computed at load: it is the
-- same answer every time, and an ear clipper in the client would be a hundred
-- lines to arrive at a constant.
--
-- The triangles are still what fills it. Stroking the rings alone would leave
-- the eyes as unfilled shapes rather than holes, which is the same picture on
-- this background and the wrong one the moment anything is behind it.
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

-- Where each closed ring begins and ends in CLYDE_V, in vertices: the body,
-- then an eye each. Ranges rather than a second copy of the points, since the
-- triangulation was built by laying the rings out in exactly this order.
local CLYDE_RINGS = {{1, 40}, {41, 52}, {53, 64}}

local function mark_discord(cx, cy, r, col)
    for i = 1, #CLYDE_T, 3 do
        local t = {CLYDE_T[i] * 2 - 1, CLYDE_T[i + 1] * 2 - 1,
                   CLYDE_T[i + 2] * 2 - 1}
        F.layer:tri(cx + CLYDE_V[t[1]] * r, ry(cy + CLYDE_V[t[1] + 1] * r),
              cx + CLYDE_V[t[2]] * r, ry(cy + CLYDE_V[t[2] + 1] * r),
              cx + CLYDE_V[t[3]] * r, ry(cy + CLYDE_V[t[3] + 1] * r),
              pal.a(col, 0.10))
    end
    for _, ring in ipairs(CLYDE_RINGS) do
        local pts = {}
        for k = ring[1], ring[2] do
            pts[#pts + 1] = cx + CLYDE_V[k * 2 - 1] * r
            pts[#pts + 1] = ry(cy + CLYDE_V[k * 2] * r)
        end
        F.layer:outline(pts, 1.2 * F.scale, col, true)
    end
end

local function mark_leave(cx, cy, r, col)
    -- A doorway with the arrow going out of it, drawn open on the side the
    -- arrow leaves by so the shape says which way it means.
    local pts = {cx + r * 0.15, ry(cy - r * 0.9), cx - r * 0.85,
                 ry(cy - r * 0.9), cx - r * 0.85, ry(cy + r * 0.9),
                 cx + r * 0.15, ry(cy + r * 0.9)}
    F.layer:outline(pts, 1.2 * F.scale, pal.a(col, 0.8), false)
    F.layer:seg(cx - r * 0.2, ry(cy), cx + r * 0.85, ry(cy), 1.3 * F.scale, col, true)
    F.layer:tri(cx + r, ry(cy), cx + r * 0.45, ry(cy - r * 0.4),
          cx + r * 0.45, ry(cy + r * 0.4), col)
end

-- The hull is its own mark: the ship you are flying, drawn as the ship you
-- are flying. Nothing else in the rail has to be looked up.
local function mark_ship(cx, cy, r, col, cls)
    thumb(cx, cy, cls or 0, col, r / 17)
end

-- The shop, as the thing it charges in. A rivet is a disc with a shank, seen
-- from just off square on, and drawn small it is a ring with a bar under it.
--
-- Not a cart, and not a bag of coins. Nothing in this game is bought with
-- money and nothing is carried out of a shop: what changes hands is which
-- slots a pilot may fill, and rivets are what pays for it.
local function mark_shop(cx, cy, r, col)
    F.layer:ring(cx, ry(cy - r * 0.22), r * 0.62, RAIL_PEN * F.scale, 20, col)
    F.layer:seg(cx - r * 0.34, ry(cy + r * 0.62), cx + r * 0.34,
                ry(cy + r * 0.62), RAIL_PEN * F.scale, pal.a(col, 0.75), true)
end

-- The week's table, as three columns of different heights. The tallest is not
-- in the middle: a symmetric podium reads as a logo, and three bars that step
-- read as a ranking.
local function mark_standings(cx, cy, r, col)
    local w = r * 0.42
    for i, k in ipairs({0.5, 1.0, 0.72}) do
        local h = r * 1.5 * k
        local x = cx + (i - 2) * (w + r * 0.22) - w / 2
        rect(x, cy + r * 0.85 - h, w, h,
             pal.a(col, i == 2 and 1 or 0.6))
    end
end

local MARKS = {zones = mark_zones, pilot = mark_pilot, team = mark_team,
               settings = mark_settings, controls = mark_controls,
               about = mark_about, discord = mark_discord, leave = mark_leave,
               shop = mark_shop, standings = mark_standings}

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
    local ring = math.max(0.8 * F.scale, r * 0.022)
    -- Three range rings where there is room for three. A dial the height of a
    -- row has twenty points across it, and three rings in that are five points
    -- apart, which is closer than the stroke drawing them: they close up into
    -- a disc with a fringe. Two rings at that size is the same instrument,
    -- read at the distance it is actually being read from.
    local rings = (r > 24 * F.scale) and {0.42, 0.72, 1.0} or {0.55, 1.0}
    local sides = math.max(18, math.min(30, math.floor(r / F.scale)))
    for k, f in ipairs(rings) do
        F.layer:ring(cx, ry(cy), r * f, ring, sides,
               pal.a(pal.RADAR_TILE, 0.55 - k * 0.12))
    end
    local ang = -F.now * 0.8
    -- How much of the circle the tail covers. Fewer strokes on the small dial:
    -- the same half radian of them, on something twenty points across, is a
    -- quarter of the face filled in, and a sweep that wide is a pie chart.
    local tail = (r > 24 * F.scale) and 10 or 5
    for k = 0, tail - 1 do
        -- The trail is behind it, which for a sweep going round the way a
        -- dial's hand goes is the side it has just left.
        local a = ang + k * 0.05
        local f = 1 - k / tail
        F.layer:seg(cx, ry(cy), cx + math.cos(a) * r * 0.98,
              ry(cy - math.sin(a) * r * 0.98), math.max(1.0 * F.scale, r * 0.028),
              pal.a(pal.FRIEND, 0.32 * f * f), true)
    end
    F.layer:disc(cx, ry(cy), math.max(1.2 * F.scale, r * 0.05), 10, pal.a(pal.DIM, 0.9))
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
    -- Bright where it meets the panel's rule and gone across the row, which
    -- is what a selection is everywhere else in this interface. It was a flat
    -- field, and a flat field on a page that has a lit edge reads as a second
    -- panel laid over the first.
    if hot then wash(x, y, w, h, pal.a(pal.FRIEND, 0.18)) end
    -- One text column, whatever the row is, and it is the column the title
    -- above the list is set in. The wedge that says "this is the one you are
    -- already on" lives in the gutter to the left of that column, off the type
    -- entirely: drawn inline it pushed its own label right of every other
    -- label, so the one row worth finding was the one out of line.
    local tx = x + GUTTER * F.scale
    if r.mark then
        -- A lit wedge, the same one the corner stack uses to say a slot is
        -- the ready one.
        F.layer:tri(x + 7 * F.scale, ry(y + h / 2 - 4.5 * F.scale), x + 14 * F.scale, ry(y + h / 2),
              x + 7 * F.scale, ry(y + h / 2 + 4.5 * F.scale), pal.FRIEND)
    end
    local sel = hot or r.mark
    -- A row nothing is serving is a place that exists and cannot be flown to
    -- yet, so it is written a shade back from the ones that can.
    -- Two kinds of row you cannot press, written the same shade back from the
    -- ones you can: one nothing is serving yet, and one with no seat left.
    if r.waiting or r.full then col = pal.a(col, 0.6) end
    -- A row carrying a sentence of its own gives it the lower half and takes
    -- the upper for everything else. The games are the list that wants it:
    -- choosing between three of them is reading three sentences, and one at a
    -- time at the foot of the panel, a screen away from the name it belongs
    -- to, is not reading them.
    -- A sentence of its own needs two lines of room. A list long enough to
    -- squeeze its rows has neither, and drew the note over the label rather
    -- than dropping it: the shop's descriptions landed on top of the names
    -- they described.
    local note = (h >= 44 * F.scale) and r.note or nil
    -- A row carrying a sentence is a row about a thing you are choosing
    -- between rather than a value you are setting, and the mocks set those
    -- names half again as large: it is the name that is being read, and the
    -- sentence under it is the reading.
    --
    -- Declared under `note` rather than over it, which is the whole of what
    -- was wrong here: read above its own `local`, `note` is a global, a
    -- global is nil, and the larger size this chooses never once applied.
    -- That is the bug .luacheckrc exists to catch, and it caught this one.
    local size = (M.compact and 17 or 18) * F.scale
    if note and h >= 44 * F.scale then size = (M.compact and 19 or 21) * F.scale end
    local ly = note and (y + h * 0.36) or (y + h / 2)
    -- Drawn here unless the detail turns out not to fit beside it, in which
    -- case the pair is laid out as two lines below and this one is skipped.
    local two_line = r.detail and r.detail ~= "" and not r.players
        and not r.choice and not note
        and text_w(r.detail, 12 * F.scale) > w - 32 * F.scale - (tx - x) - 12 * F.scale
    if not two_line then
        txt(r.label or "", tx, ly, size,
            pal.a(col, sel and 1 or 0.82), nil, MENU_FONT, r.named)
    end
    if note then
        txt(note, tx, y + h * 0.68, 11.5 * F.scale,
            pal.a(pal.DIM, (hot and 1 or 0.75) * (r.waiting and 0.7 or 1)))
    end
    -- The right hand side is data, so it stays in the face the numbers in
    -- flight are set in: a call sign, a count, a hull's name.
    if r.waiting then
        -- No count, because there is nothing to count. The instrument that
        -- looks for a game says what the words did, in the room the numbers
        -- would have taken, and it keeps saying it while the list refreshes
        -- underneath: an arena can come back and this row is where it lands.
        sweep_dial(x + w - 16 * F.scale - 11 * F.scale, ly, 11 * F.scale)
    elseif r.players and (r.live or r.full) then
        -- A full room keeps its count. The dial above says "looking for one of
        -- these", which is the opposite of what a full room is: the count is
        -- the whole reason it cannot be entered, so hiding it would leave the
        -- row saying it is unavailable without saying why.
        population(x + w - 16 * F.scale, ly, r.players, r.bots,
                   pal.a(pal.FRIEND, sel and 1 or 0.85))
    elseif r.choice then
        -- A setting drawn as its own range: one step per value, the one it
        -- is on filled. "half" is a word to read and hold against the word
        -- on the row above; three steps of four lit is a position, and a
        -- press moves it along.
        local n = r.choices or 1
        local sw2 = 13 * F.scale
        local gap = 5 * F.scale
        local x1 = x + w - 16 * F.scale
        local x0 = x1 - (n * sw2 + (n - 1) * gap)
        if r.bar then
            -- A range too long to count is a bar instead: thirty pips is not
            -- a position anybody reads off, it is a wall, and it is wider
            -- than the row it would have to sit in. The kit's budget is the
            -- one of these, and how full it is says everything the page
            -- needs.
            local bw = 180 * F.scale
            local bh = 10 * F.scale
            local by = y + h / 2 - bh / 2
            x0 = x1 - bw
            local part = math.max(0, math.min(1, r.choice / math.max(1, n)))
            if part > 0 then
                rect(x0, by, bw * part, bh, pal.a(pal.FRIEND, sel and 1 or 0.8))
            end
            F.layer:frame(x0, ry(by, bh), bw, bh, 1.0 * F.scale,
                          pal.a(pal.DIM, 0.45))
        else
            for i = 1, n do
                local px = x0 + (i - 1) * (sw2 + gap)
                if i <= r.choice then
                    rect(px, y + h / 2 - 5 * F.scale, sw2, 10 * F.scale,
                         pal.a(pal.FRIEND, sel and 1 or 0.8))
                else
                    F.layer:frame(px, ry(y + h / 2 - 5 * F.scale, 10 * F.scale), sw2, 10 * F.scale,
                            1.0 * F.scale, pal.a(pal.DIM, 0.45))
                end
            end
        end
        if r.detail and r.detail ~= "" then
            txt(r.detail, x0 - 12 * F.scale, y + h / 2, 11 * F.scale,
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
            txt(r.detail, tx, y + h * 0.70, 11 * F.scale, pal.a(pal.DIM, 0.9),
                nil, nil, r.verbatim)
        else
            txt(r.detail, x + w - 16 * F.scale, ly, 12 * F.scale,
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
    local r = math.max(22 * F.scale, math.min(56 * F.scale, h * 0.26))
    -- Centered in whatever room is left rather than hung off the top of it: on
    -- an empty page there is nothing above to hang from.
    local blockh = 2 * r + 96 * F.scale
    local cy = y + math.max(0, (h - blockh) / 2) + r + 8 * F.scale
    sweep_dial(cx, cy, r)
    local ty = cy + r + 30 * F.scale
    txt(e.head or "", cx, ty, (M.compact and 17 or 19) * F.scale,
        pal.a(pal.INK, 0.85), "center", MENU_FONT)
    if e.line and e.line ~= "" then
        txt(e.line, cx, ty + 24 * F.scale, 12 * F.scale, pal.a(pal.DIM, 0.95), "center")
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
    txt(f.label or "", x, y, 11 * F.scale, pal.a(pal.DIM, lit and 0.95 or 0.7))
    local ty = y + 22 * F.scale
    if not dom then
        local shown = f.value or ""
        local size = 16 * F.scale
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
                F.layer:disc(x + (i - 0.5) * adv, ry(ty), 3.4 * F.scale, 10,
                       pal.a(pal.FRIEND, lit and 1 or 0.65))
            end
        else
            txt(shown, x, ty, size, pal.a(pal.FRIEND, lit and 1 or 0.7),
                nil, nil, true)
        end
        if lit then
            rect(x + #shown * adv + 1 * F.scale, ty - 9 * F.scale, 1.6 * F.scale, 18 * F.scale,
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
    F.layer:seg(x, ry(ty + 14 * F.scale), x + w, ry(ty + 14 * F.scale), 1.2 * F.scale,
          pal.a(col, alpha), true)
    return 48 * F.scale
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
        out[i] = string.format("%.1f,%.1f,%.1f,%d,%s,%d", fx / F.scale,
                               (y + 22 * F.scale) / F.scale - FIELD_H / 2, fw / F.scale,
                               FIELD_H, f.kind or "current-password",
                               f.max or 64)
        y = y + 48 * F.scale
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
    rect(0, 0, F.w, F.h, pal.a(pal.BG, 0.35))
    -- Nothing behind this is listening, and hit boxes are first come first
    -- served, so the ones already published go: a tap on the rail or on a row
    -- under the wash would otherwise answer a question it cannot see.
    M.hits = {}
    F.text_dim = 1
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
    local cw = math.min((a.fields and 380 or 340) * F.scale, w - 24 * F.scale)
    -- A card with a code in it is taller by the line the code takes, and one
    -- with lines to fill in is taller by each of them.
    local ch = (a.code and 152 or 110) * F.scale
    if a.fields then ch = (84 + 48 * #a.fields + 46) * F.scale end
    -- A line under the head needs its own room. The keys are laid out from
    -- the bottom edge up, so without this they come back to meet it.
    if a.note then ch = ch + 30 * F.scale end
    local cx = x + (w - cw) / 2
    local cy = y + (h - ch) / 2
    rect(cx, cy, cw, ch, pal.a(pal.BTN_BG, 0.98))
    F.layer:frame(cx, ry(cy, ch), cw, ch, 1.1 * F.scale, pal.a(pal.BORDER, 1))
    local mid = cx + cw / 2
    txt(a.head or "", mid, cy + 36 * F.scale, (M.compact and 15 or 16) * F.scale,
        pal.a(pal.INK, 0.95), "center", MENU_FONT)
    -- What answering costs, when that is not obvious from the question. The
    -- menu's cards never needed one; the rooms card does, because what a move
    -- takes off a pilot is the part they cannot see.
    if a.note then
        txt(a.note, mid, cy + 60 * F.scale, (FONT - 2) * F.scale,
            pal.a(pal.DIM, 0.9), "center")
    end
    -- What the question is about, when it is about a string rather than a
    -- choice: big enough to read off one machine and type into another,
    -- quoted rather than said, and lit, because it is the one thing on the
    -- card anybody has to get right.
    if a.code then
        txt(a.code, mid, cy + 72 * F.scale, 30 * F.scale, pal.FRIEND, "center", nil, true)
    end
    if a.fields then
        local fx = cx + 26 * F.scale
        local fw = cw - 52 * F.scale
        local fy = cy + 58 * F.scale
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
                hit(fx, fy - 48 * F.scale, fw, 46 * F.scale, "field", i)
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
    total = total + KEY_GAP * F.scale * (#a.keys - 1)
    local kx = mid - total / 2
    local ky = cy + ch - 22 * F.scale - KEY_H * F.scale
    for i, k in ipairs(a.keys) do
        key_cap(kx, ky, ws[i], k.label, i == a.sel)
        -- Whose question this is. The menu owns "answer"; anything else
        -- raising a card says so, or its answers are delivered to the menu.
        hit(kx, ky, ws[i], KEY_H * F.scale, a.action or "answer", i)
        kx = kx + ws[i] + KEY_GAP * F.scale
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
    ask_card(0, 0, F.w, F.h, {
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
    local cols = (w / F.scale >= 420) and 4 or 2
    -- How wide the grid came out, for whoever has to move a cursor around it.
    -- The arrows mean a column and a row, and only the drawing knows how many
    -- columns a window of this width got.
    M.stage_cols = cols
    local rowsn = math.ceil(n / cols)
    local cw = w / cols
    local ch = math.min(h / rowsn, (M.compact and 92 or 104) * F.scale)
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
            rect(x + c * cw + 4 * F.scale, y + rr * ch + 2 * F.scale, cw - 8 * F.scale,
                 ch - 4 * F.scale, pal.a(pal.FRIEND, 0.07))
        end
        if hot then
            rect(x + c * cw + 4 * F.scale, y + rr * ch + 2 * F.scale, cw - 8 * F.scale,
                 ch - 4 * F.scale, pal.a(pal.FRIEND, 0.14))
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
                       HULL_PEN * F.scale)
        else
            thumb(cx, cy - ch * 0.17, r.hull or 0,
                  pal.a(col, (hot or r.mark) and 1 or 0.7), ch / 116,
                  hot and F.now * 1.7 or nil)
        end
        txt(r.label or "", cx, cy + ch * 0.20, (M.compact and 14 or 15) * F.scale,
            pal.a(col, (hot or r.mark) and 1 or 0.8), "center", MENU_FONT)
        if r.role then
            txt(r.role, cx, cy + ch * 0.34, 10 * F.scale, pal.a(pal.DIM, 0.9),
                "center")
        end
        hit(x + c * cw, y + rr * ch, cw, ch, "stage", i)
    end
end

-- The mark is a top-down ship built from an orange Lambda and a cyan W. The
-- orange outside is one uninterrupted /\, while the shared five-point
-- chevron gives both letters their inside edge. A black separator is derived
-- from that one centerline at a constant width, so it cannot pinch or flare at
-- a corner.
--
-- Drawn here rather than imported because the interface is vector geometry at
-- every other point too. `client/web/logo.svg` carries the same coordinates,
-- and logo_test holds every inline and raster copy to that source.
local MK_W, MK_H = 84, 104

local MK_ORANGE = {42, 0, 84, 67, 66, 78, 42, 53, 18, 78, 0, 67}
local MK_ORANGE_TRI = {1, 2, 3, 1, 3, 4, 6, 1, 4, 4, 5, 6}

local MK_CYAN = {0, 67, 18, 78, 42, 53, 66, 78, 84, 67,
                 60, 103, 42, 74, 24, 103}
local MK_CYAN_TRI = {8, 1, 2, 8, 2, 3, 4, 5, 6,
                     3, 4, 6, 3, 6, 7, 3, 7, 8}

-- The two exact 1.5-unit offsets of the shared chevron, joined with miters
-- and square terminals. Triangulating the ring once is cheaper and more exact
-- than asking five independent strokes to agree at runtime.
local MK_GAP = {
    -0.4977, 64.9379, 17.7531, 76.0912, 42, 50.834,
    66.2469, 76.0912, 84.4977, 64.9379,
    86.0621, 67.4977, 65.7531, 79.9088, 42, 55.166,
    18.2469, 79.9088, -2.0621, 67.4977,
}
local MK_GAP_TRI = {10, 1, 2, 4, 5, 6, 4, 6, 7, 3, 4, 7,
                    3, 7, 8, 2, 3, 8, 2, 8, 9, 2, 9, 10}

-- Ten logo units is about two screen pixels beside the menu wordmark. The
-- depth disappears face-on and reaches that full width edge-on, so the mark
-- keeps its exact approved silhouette at rest and gains a visible edge only
-- while it turns.
local MK_DEPTH = 10
local MK_ORANGE_BACK = {pal.LOGO_ORANGE[1] * 0.30,
                        pal.LOGO_ORANGE[2] * 0.30,
                        pal.LOGO_ORANGE[3] * 0.30, 1}
local MK_ORANGE_SIDE = {pal.LOGO_ORANGE[1] * 0.48,
                        pal.LOGO_ORANGE[2] * 0.48,
                        pal.LOGO_ORANGE[3] * 0.48, 1}
local MK_CYAN_BACK = {pal.LOGO_CYAN[1] * 0.30,
                      pal.LOGO_CYAN[2] * 0.30,
                      pal.LOGO_CYAN[3] * 0.30, 1}
local MK_CYAN_SIDE = {pal.LOGO_CYAN[1] * 0.48,
                      pal.LOGO_CYAN[2] * 0.48,
                      pal.LOGO_CYAN[3] * 0.48, 1}

local function logo_poly(points, tris, ox, oy, k, squash, col)
    for i = 1, #tris, 3 do
        local a, b, c = tris[i], tris[i + 1], tris[i + 2]
        F.layer:tri(ox + (points[a * 2 - 1] - MK_W / 2) * k * squash,
              ry(oy + points[a * 2] * k),
              ox + (points[b * 2 - 1] - MK_W / 2) * k * squash,
              ry(oy + points[b * 2] * k),
              ox + (points[c * 2 - 1] - MK_W / 2) * k * squash,
              ry(oy + points[c * 2] * k), col)
    end
end

-- Join the rear and front copies around a polygon's perimeter. Each edge is a
-- pair of triangles, which turns the offset duplicate into a solid thickness
-- instead of a drop shadow. The front face is drawn last and hides the half of
-- each strip that should be behind it.
local function logo_sides(points, bx, fx, oy, k, squash, col)
    local n = #points / 2
    for i = 1, n do
        local j = i % n + 1
        local ax = (points[i * 2 - 1] - MK_W / 2) * k * squash
        local ay = ry(oy + points[i * 2] * k)
        local cx = (points[j * 2 - 1] - MK_W / 2) * k * squash
        local cy = ry(oy + points[j * 2] * k)
        F.layer:tri(bx + ax, ay, bx + cx, cy, fx + cx, cy, col)
        F.layer:tri(bx + ax, ay, fx + cx, cy, fx + ax, ay, col)
    end
end

local function logo_face(ox, oy, k, squash, orange, cyan, alpha)
    logo_poly(MK_ORANGE, MK_ORANGE_TRI, ox, oy, k, squash,
              pal.a(orange, alpha))
    logo_poly(MK_CYAN, MK_CYAN_TRI, ox, oy, k, squash,
              pal.a(cyan, alpha))
    logo_poly(MK_GAP, MK_GAP_TRI, ox, oy, k, squash,
              pal.a(pal.LOGO_GAP, alpha))
end

function M.logo_width(h)
    return h * MK_W / MK_H
end

function M.logo(cx, cy, h, alpha, still)
    alpha = alpha or 1
    local k = h / MK_H
    -- Match the selected hull's turn speed, then separate a dark rear face
    -- from the colored front face as it turns. The face nearest the viewer is
    -- drawn last: bright for the front half of the turn and dark for the back
    -- half. The solid edge keeps the mark visible at a true 90 degrees, when
    -- both faces collapse to a line. `still` keeps asset tests and non-menu
    -- callers front-on.
    local turn = not still and F.now * 1.7 or nil
    local squash = turn and math.cos(turn) or 1
    local depth = turn and math.sin(turn) * MK_DEPTH * k / 2 or 0
    local bx, fx = cx - depth, cx + depth
    local oy = cy - MK_H * k / 2
    local front_facing = squash >= 0
    if math.abs(depth) > 0.001 then
        if front_facing then
            logo_face(bx, oy, k, squash,
                      MK_ORANGE_BACK, MK_CYAN_BACK, alpha)
        else
            logo_face(fx, oy, k, squash,
                      pal.LOGO_ORANGE, pal.LOGO_CYAN, alpha)
        end
        logo_sides(MK_ORANGE, bx, fx, oy, k, squash,
                   pal.a(MK_ORANGE_SIDE, alpha))
        logo_sides(MK_CYAN, bx, fx, oy, k, squash,
                   pal.a(MK_CYAN_SIDE, alpha))
        logo_sides(MK_GAP, bx, fx, oy, k, squash,
                   pal.a(pal.LOGO_GAP, alpha))
    end
    if front_facing then
        logo_face(fx, oy, k, squash,
                  pal.LOGO_ORANGE, pal.LOGO_CYAN, alpha)
    else
        logo_face(bx, oy, k, squash,
                  MK_ORANGE_BACK, MK_CYAN_BACK, alpha)
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

-- How much room the lockup takes, so a row can start after it.
local function wordmark_w(size)
    return M.logo_width(size * LOGO_EM) + size * LOGO_GAP
           + text_w("vectorwake", size)
end

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
    F.case = "sentence"

    -- A question takes the keys off whatever asked it, and the panel says so
    -- by standing down. It has to be set before a word of it is written: a
    -- glyph carries the alpha it was queued with, and the gui draws it over
    -- every mesh whatever is laid on top afterwards.
    F.text_dim = v.ask and 0.1 or 1
    local pts_w, pts_h = F.w / F.scale, F.h / F.scale
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
    rect(0, 0, F.w, F.h, pal.rgb(0x03050a, narrow and (base + 0.08) or base))

    local margin = (narrow and 18 or 40) * F.scale
    -- Room over the block for the name, wherever the menu is. It was kept for
    -- the home screen alone, so the same menu opened mid-fight opened without
    -- the one thing on it that says what this is.
    local head = (narrow and 54 or 76) * F.scale

    local rx, ry_, rw, rh          -- the rail
    local icon_dy                  -- the icon's drop inside it, narrow only
    local sx, sy, sw, sh           -- the stage
    local logo_y                   -- the middle of the name, both layouts
    -- What the panel covers, name included: everything a press may land on
    -- without meaning to leave. Published as one box at the end, so the
    -- gaps between rows are not a way out of the menu.
    local px0, py0, px1, py1
    -- Two arrangements, and both put the tabs in a row.
    --
    -- On top where there is room to read a page under them, which is what
    -- `match-game.md` asks for and what the in-match surface needs: the same
    -- chrome in both places, so a player learns one screen and meets it twice.
    -- On the bottom edge of a phone, where a thumb has to reach them.
    --
    -- The rail was a column down the left for a long time, with the page
    -- beside it. That was the right shape while the pages were lists of a few
    -- rows each; the hangar and the shop are grids, and a grid in the two
    -- thirds of a window left over from a rail is a grid with no room in it.
    -- `vertical` stays as a name because the drawing below still asks, and it
    -- is false everywhere now.
    local vertical = false
    -- How far a lit tab's field reaches past its mark. Down to the edge of
    -- the screen on a phone, so the lit stop is a tab reaching the bottom of
    -- the glass rather than a panel floating over the indicator; down to the
    -- rule under the row where the tabs are on top.
    local tab_h

    if narrow then
        rh = (home and 78 or 84) * F.scale
        rw = F.w - F.safe_l - F.safe_r - 2 * margin
        rx = F.safe_l + margin
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
        --
        -- The full-height iPhone canvas puts the rail on the physical bottom
        -- edge now. Lift its furniture ten points in portrait so the labels do
        -- not sit against the glass. The rail surface and hit targets still run
        -- to the edge, and landscape keeps its existing vertical rail.
        local portrait_lift = pts_h > pts_w and 10 * F.scale or 0
        local base_icon_dy = (home and 30 or 32) * F.scale
        icon_dy = base_icon_dy - portrait_lift
        local under = rh - base_icon_dy - 24 * F.scale
        if F.installed then
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
            --
            -- Never more than the indicator itself, because the give-back is
            -- measured against it and a device reporting no inset has nothing
            -- to measure. Without that cap the arithmetic cancelled exactly at
            -- SB = 0: the whole of the rail's padding went back, which put the
            -- middle of the words on the bottom edge of the screen and cut
            -- every label in half. An Android PWA with button navigation
            -- reports no inset, and so does a phone with a home button.
            ry_ = F.h - rh + math.max(0, math.min(F.safe_b, under - F.safe_b * 0.56))
        else
            ry_ = F.h - rh - math.max(0, F.safe_b - under)
        end
        sx, sw = F.safe_l + margin, rw
        -- Under the chip row over a game: MENU and PLAYERS hold the top left
        -- corner while the arena is live, and the name drawn into them is two
        -- things in one place.
        local chip = home and 0 or 34 * F.scale
        sy = F.safe_t + margin + head + chip
        sh = ry_ - 20 * F.scale - sy
        -- Down to the bottom edge, rather than to the rail plus a margin
        -- that is no longer there: the wash is what the panel sits on, and a
        -- strip of bare arena under the rail reads as the panel having come
        -- loose from the screen.
        rect(0, sy - 16 * F.scale, F.w, F.h - (sy - 16 * F.scale), pal.rgb(0x03050a, 0.5))
        logo_y = F.safe_t + margin + chip + 22 * F.scale
        wordmark(rx, logo_y, 30 * F.scale)
        -- The whole screen from the name down. A phone's menu is the screen,
        -- so there is next to nothing outside it, which is the right answer
        -- there: the way out is the x and the lit rail stop.
        px0, py0 = 0, logo_y - 20 * F.scale
        px1, py1 = F.w, F.h
        F.layer:seg(rx, ry(ry_ - 12 * F.scale), F.w - F.safe_r - margin, ry(ry_ - 12 * F.scale),
              1.0 * F.scale, pal.a(pal.RADAR_TILE, 0.6), true)

        tab_h = F.h - ry_
    else
        local total = math.min(F.w - F.safe_l - F.safe_r - 2 * margin, 940 * F.scale)
        local x0 = F.safe_l + (F.w - F.safe_l - F.safe_r - total) / 2
        -- Clear of what the ship is carrying. Over a game the corner stack
        -- holds the left edge, and a centered block lands right on it.
        if not home then
            x0 = math.max(x0, F.safe_l + 124 * F.scale)
            total = math.min(total, F.w - F.safe_r - x0 - margin)
        end
        rx, rw = x0, total
        -- One row across the top: the mark, the tabs, and at the far end the
        -- pilot and what they have to spend. The name used to stand on a line
        -- of its own above the block, which cost 76 points of height to say
        -- something the mark already says, and left the right-hand end of the
        -- row empty on every page.
        rh = 56 * F.scale
        icon_dy = 21 * F.scale
        -- Tall enough for a hull column beside its kit, and no taller than a
        -- screen: the page under the tabs is the reason the tabs moved.
        local block = math.min(F.h - 2 * margin, 620 * F.scale)
        local top = math.max(margin, (F.h - block) / 2)
        ry_ = top
        sx, sw = x0, total
        sy = top + rh + 10 * F.scale
        sh = block - rh - 10 * F.scale
        tab_h = rh
        logo_y = top + rh / 2
        wordmark(x0, logo_y, (tall and 26 or 22) * F.scale)
        -- What you are reading, laid over what you are not. A wash rather
        -- than a panel: no border, no corners, just enough that the type sits
        -- on something and the arena stays visible round the edges of it.
        rect(x0 - 18 * F.scale, top - 12 * F.scale, total + 36 * F.scale,
             block + 24 * F.scale, pal.rgb(0x03050a, 0.5))
        px0, py0 = x0 - 18 * F.scale, top - 12 * F.scale
        px1, py1 = px0 + total + 36 * F.scale, py0 + block + 24 * F.scale
        -- The rule the whole thing hangs off, under the tabs rather than
        -- between a rail and a stage. The map border's own tick, which is
        -- what every rule in this interface is made of.
        ticks(x0, sy - 6 * F.scale, total, pal.a(pal.RADAR_TILE, 0.5),
              14 * F.scale)
        -- The far end of the row. Who you are and what you have to spend, in
        -- the slot a match fills with the score: whatever you are inside, the
        -- right-hand end of this row says how you are doing in it.
        -- Only where the corner is free. Over a game the way out lives there,
        -- and the arena's own topbar is already carrying the score, so a name
        -- and a wallet would be a third thing in a corner that has two.
        if v.pilot and not v.closable then
            local rt = x0 + total
            if v.pilot.rivets then
                local ly = logo_y + 1 * F.scale
                lbl("rivets", rt, ly, nil, "right")
                rt = rt - text_w("rivets", 9 * F.scale) - 8 * F.scale
                txt(tostring(v.pilot.rivets), rt, logo_y, 15 * F.scale,
                    pal.a(pal.INK, 0.95), "right")
                rt = rt - text_w(tostring(v.pilot.rivets), 15 * F.scale)
                     - 26 * F.scale
            end
            if v.pilot.name and v.pilot.name ~= "" then
                txt(v.pilot.name, rt, logo_y, 15 * F.scale,
                    pal.a(pal.INK, 0.9), "right", MENU_FONT, true)
                rt = rt - text_w(v.pilot.name, 15 * F.scale) - 10 * F.scale
                pilot_mark(rt - 7 * F.scale, logo_y, pal.a(pal.FRIEND, 0.9),
                           7 * F.scale, 1.1 * F.scale)
            end
        end
    end

    -- Which half the arrows are in. The two halves share one cursor and mark
    -- it with the same blue field, so the half wearing the brighter one is the
    -- answer to "what does up do here" without a word spent on saying it.
    local focused = (v.focus == "stage")

    -- --- the rail
    --
    -- Two rows, and they are different objects. On a phone it is a tab bar:
    -- marks with words under them, each in its own lit field, sized so a thumb
    -- lands on one. On a desktop it is a line of words beside the mark, with a
    -- rule under the one you are in, which is what the mocks draw and what a
    -- row of six things that are read rather than aimed at wants to be.
    local words = not narrow
    local pitch = vertical and (rh / n) or (rw / n)
    -- Where each word starts, for the row of words. Measured rather than
    -- divided: "standings" and "shop" are not the same width and a row that
    -- pretended otherwise would leave a hole beside the short ones.
    local wx, ww = {}, {}
    if words then
        local px = 15 * F.scale
        local at = rx + wordmark_w((tall and 26 or 22) * F.scale)
                   + 40 * F.scale
        for i, e in ipairs(rail) do
            ww[i] = text_w(e.label or "", px)
            wx[i] = at
            at = at + ww[i] + 21 * F.scale
        end
    elseif not vertical then
        local cap = 170 * F.scale
        if pitch > cap then
            rx = rx + (rw - cap * n) / 2
            pitch = cap
        end
    end
    -- Along the bottom, every stop says its name, and the words are sized so
    -- the longest of them fits the room one stop has. Only the lit one used to
    -- carry a word, because "settings" and "about" at the desktop's size run
    -- into each other with eight of them across a phone; a row of marks you
    -- have to learn by tapping is worse than a row of small words.
    local label_px = 11 * F.scale
    if not vertical then
        local longest = 0
        for _, e in ipairs(rail) do
            longest = math.max(longest, #(e.label or ""))
        end
        if longest > 0 then
            label_px = math.max(8 * F.scale, math.min(label_px,
                                (pitch - 5 * F.scale) / (longest * ADVANCE)))
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
            cx = rx + 26 * F.scale
            cy = ry_ + (i - 0.5) * pitch
        elseif words then
            cx = wx[i] + ww[i] / 2
            cy = ry_ + rh / 2
        else
            cx = rx + (i - 0.5) * pitch
            cy = ry_ + icon_dy
        end
        local col = (sel or hot) and pal.FRIEND or pal.a(pal.DIM, 0.9)
        local r = 13 * F.scale
        -- A word with a rule under the one you are in, and nothing else: no
        -- field, no mark. The words are the row.
        if words then
            local px = 15 * F.scale
            txt(e.label, wx[i], cy, px,
                pal.a(sel and pal.FRIEND or pal.INK, sel and 1
                      or (hot and 0.9 or 0.55)), nil, MENU_FONT)
            if sel then
                F.layer:seg(wx[i], ry(cy + 13 * F.scale),
                            wx[i] + ww[i], ry(cy + 13 * F.scale),
                            1.4 * F.scale,
                            pal.a(pal.FRIEND, focused and 0.55 or 1), true)
            elseif hot then
                F.layer:seg(wx[i], ry(cy + 13 * F.scale),
                            wx[i] + ww[i], ry(cy + 13 * F.scale),
                            1.0 * F.scale, pal.a(pal.DIM, 0.7), true)
            end
            if e.link then
                M.link_dom = string.format("%.1f,%.1f,%.1f,%.1f,%s",
                    (wx[i] - 6 * F.scale) / F.scale,
                    (cy - 14 * F.scale) / F.scale,
                    (ww[i] + 12 * F.scale) / F.scale,
                    (28 * F.scale) / F.scale, e.link)
            end
            hit(wx[i] - 8 * F.scale, ry_, ww[i] + 16 * F.scale, rh, "rail", i)
        end
        if not words and hot then
            -- The stage's own hover weight, and only the field: the lit rule
            -- beside a selected stop says which page the panel belongs to,
            -- and a pointer passing over says nothing of the kind.
            local warm = pal.a(pal.FRIEND, 0.16)
            if vertical then
                rect(rx - 6 * F.scale, cy - pitch / 2 + 3 * F.scale,
                     rw + 6 * F.scale, pitch - 6 * F.scale, warm)
            else
                rect(cx - pitch / 2 + 3 * F.scale, ry_, pitch - 6 * F.scale, tab_h, warm)
            end
        end
        if not words and sel then
            -- The lit one, and a rule reaching from it toward the stage, so
            -- the eye is told which mark the panel belongs to rather than
            -- having to work it out from a highlight. Brighter while the
            -- arrows are in the rail, down to the weight the stop keeps for
            -- saying where you are once they have gone into the page.
            local lit = pal.a(pal.FRIEND, focused and 0.06 or 0.22)
            local bar = pal.a(pal.FRIEND, focused and 0.5 or 1)
            if vertical then
                rect(rx - 6 * F.scale, cy - pitch / 2 + 3 * F.scale,
                     rw + 6 * F.scale, pitch - 6 * F.scale, lit)
                F.layer:seg(rx - 6 * F.scale, ry(cy - pitch / 2 + 3 * F.scale), rx - 6 * F.scale,
                      ry(cy + pitch / 2 - 3 * F.scale), 1.6 * F.scale, bar, true)
            else
                -- The field alone. It wore a lit bar along its top edge as
                -- well, which is the vertical rail's own mark turned on its
                -- side: there it points at the stage beside it, and here it
                -- points at nothing and reads as a tab that has come loose.
                --
                -- Down to the edge of the screen rather than to the end of
                -- the block, so the lit stop is a tab reaching the bottom of
                -- the phone and not a panel floating above the indicator.
                rect(cx - pitch / 2 + 3 * F.scale, ry_, pitch - 6 * F.scale, tab_h, lit)
            end
        end
        -- A stop that leaves the game gets a real link laid over it by the
        -- page. Nothing the client does from its own loop is inside the tap
        -- that asked for it, and a browser will not open a tab for anything
        -- else, so the finger has to land on an anchor rather than on the
        -- canvas. Published in CSS pixels, which is what the page lays out
        -- in; everything here is drawable ones.
        if e.link and not words then
            local lx, ly, lw, lh
            if vertical then
                lx, ly = rx - 6 * F.scale, cy - pitch / 2 + 3 * F.scale
                lw, lh = rw + 6 * F.scale, pitch - 6 * F.scale
            else
                lx, ly = cx - pitch / 2 + 3 * F.scale, ry_
                lw, lh = pitch - 6 * F.scale, tab_h
            end
            M.link_dom = string.format("%.1f,%.1f,%.1f,%.1f,%s",
                                       lx / F.scale, ly / F.scale,
                                       lw / F.scale, lh / F.scale, e.link)
        end
        if not words then
        draw_mark(e.icon, cx, cy, r, col, v.class or 0)
        end
        if vertical then
            txt(e.label, rx + 48 * F.scale, cy, 16 * F.scale,
                pal.a((sel or hot) and pal.INK or pal.DIM,
                      (sel or hot) and 1 or 0.85),
                nil, MENU_FONT)
        elseif not words then
            txt(e.label, cx, cy + 24 * F.scale, label_px,
                pal.a((sel or hot) and pal.FRIEND or pal.DIM,
                      (sel or hot) and 1 or 0.8),
                "center", MENU_FONT)
        end
        -- The rail's own action: it names a destination, not a row of
        -- whatever page is on the stage.
        if vertical then
            hit(rx - 6 * F.scale, cy - pitch / 2, rw + 10 * F.scale, pitch, "rail", i)
        elseif not words then
            hit(cx - pitch / 2, ry_ - 8 * F.scale, pitch, tab_h + 8 * F.scale, "rail", i)
        end
    end

    -- --- the stage
    -- Everything with type in it hangs off `tx`, a gutter in from the stage's
    -- own left edge: the rule at the head of it, and every row's label. A
    -- row's field starts back at `sx`, so what is lit reaches under the mark
    -- and the words never sit against the edge of it.
    local tx = sx + GUTTER * F.scale
    local avail = sw - GUTTER * F.scale
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
    local lw = avail - 14 * F.scale
    -- And a cap on a list, which came back when the tabs moved to the top.
    -- The cap was dropped while the block was a rail plus a stage and the
    -- widest a row could be was about 740 points; the stage is the whole
    -- block now, and a row running the width of a desktop window puts a name
    -- at one edge and its value at the other, which is two columns nobody
    -- reads as one line.
    --
    -- Lists only. The hull grid and the keyboard are drawings, and they take
    -- everything there is.
    local listy = not (v.board and not M.touching) and not v.hulls
        and not v.shelf and not v.table
        and not (v.rows and v.rows[1] and v.rows[1].hull)
    -- A page is a panel: a translucent ground hung off a lit rule down its left
    -- edge, with the light spilling across it. It is the shape every
    -- instrument in the arena already has, and the one thing the menu was
    -- still drawing without. No border, because a box is the shape this game
    -- does not contain.
    --
    -- It fills the block. The list inside it keeps a measure, because a row
    -- whose name sits at one edge and whose count sits at the other is two
    -- columns nobody reads as one line, but the panel is the page and a page
    -- narrower than the row of tabs over it reads as a page that failed to
    -- fill.
    local panel_x, panel_w = sx, avail
    if not narrow then
        local ph = sh - 6 * F.scale
        rect(panel_x, sy, panel_w, ph, pal.rgb(0x05070c, 0.5))
        vrule(panel_x, sy, ph, pal.a(pal.RADAR_TILE, 0.7))
    end
    local asidew = 0
    if listy then
        lw = math.min(lw, 560 * F.scale)
        if v.aside and not narrow and panel_w > 700 * F.scale then
            asidew = math.min(300 * F.scale, panel_w - lw - 60 * F.scale)
        end
    end
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
        close_mark(sx + sw - 8 * F.scale, logo_y, pal.a(pal.DIM, 0.9), 11 * F.scale)
        hit(sx + sw - 30 * F.scale, logo_y - 12 * F.scale, 40 * F.scale, 24 * F.scale, "close")
    end
    -- A page with a heading starts its heading where a page without one
    -- starts its first row, near enough: the air over the list is what the
    -- heading is standing in. Taking the full band and then the heading on
    -- top of it cost the kit page its last row.
    local top = sy + ((v.head and not v.hulls) and 10 or STAGE_TOP) * F.scale
    local room = sh - (top - sy) - 26 * F.scale
    -- A heading, on the one page that has one. The lit stop on the tab row is
    -- the title everywhere else, and it stops being one as soon as a page is
    -- about a thing you chose on the page before: over the kit it says
    -- "hangar", which is the room rather than the ship on the bench.
    --
    -- The hull is drawn beside its name for the same reason it is drawn in the
    -- grid you picked it from: eight names is a list to read and eight
    -- outlines is a shape to recognise, and the page you land on should be
    -- wearing the one you just pressed.
    if v.head and not v.hulls then
        -- One line of it. Stacked, the name and the trade cost a row off the
        -- list below, and a kit page that has to scroll to reach the last
        -- charge is a page that cannot be read in one look.
        local hh = 40 * F.scale
        local name = v.head.label or ""
        local size = 18 * F.scale
        -- Where the heading's own baseline sits. Named for what it is rather
        -- than `base`, which is the panel's wash weight a few hundred lines
        -- up: two different numbers under one name in one function.
        local head_y = top + hh * 0.56
        -- A hull where the page is about one, and nothing where it is not:
        -- the shop's heading is a wallet and has no ship in it.
        local nx = tx + 4 * F.scale
        if v.head.hull then
            thumb(tx + 16 * F.scale, head_y - 5 * F.scale, v.head.hull,
                  pal.a(pal.FRIEND, 0.95), hh / 78)
            nx = tx + 40 * F.scale
        end
        txt(name, nx, head_y, size, pal.a(pal.INK, 0.95), nil, MENU_FONT)
        if v.head.role then
            txt(v.head.role, nx + text_w(name, size) + 10 * F.scale, head_y,
                10.5 * F.scale, pal.a(pal.DIM, 0.9))
        end
        top = top + hh
        room = room - hh
    end
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
        -- than solved, the same way the page used to do it. What the chips
        -- want comes off the room first, since they are the half of this page
        -- that has to be readable: a board that has shrunk is still a picture
        -- of a keyboard, and a chip that has shrunk is a key you cannot read.
        local bw = avail
        -- The chip's own row height, which is not the stage row height below:
        -- one is a line in a grid of names and keys, the other is a row of a
        -- list, and they are sized against different things.
        local chip_h = CHIP_ROW * F.scale
        if v.chips then
            local lines = chip_lines(#v.rows)
            -- The board gives way first, down to its floor, and then the
            -- chips do. That order is the argument for the page: a keyboard
            -- drawn smaller is still a picture of where your hand goes, and a
            -- chip drawn smaller is a key you cannot read.
            while bw > 240 * F.scale
                  and board_height(bw) + lines * chip_h + CHIP_GAP * F.scale > room do
                bw = bw * 0.94
            end
            local left = room - board_height(bw) - CHIP_GAP * F.scale
            if lines * chip_h > left then
                chip_h = math.max(left / lines, 0)
            end
        else
            while bw > 240 * F.scale and board_height(bw) > room do bw = bw * 0.94 end
        end
        local used = board(tx, top, bw, v)
        -- The chips take the stage's width rather than the board's. In a
        -- column as narrow as a backed-off keyboard the key runs back under
        -- the name it belongs to, and there is nothing above them to line up
        -- with in any case.
        if v.chips then
            chips(tx, top + used + CHIP_GAP * F.scale, avail - 14 * F.scale, v,
                  chip_h)
        end
    elseif v.hulls then
        -- The hangar, which is the one page drawn as a layout rather than as
        -- a list: a roster beside the kit of the hull it is standing on.
        pages.kit(v, panel_x, top, panel_w - 14 * F.scale, room, focused)
    elseif v.table then
        -- The week, as a table with your own line in it.
        pages.week(v, panel_x + GUTTER * F.scale, top,
                  panel_w - 14 * F.scale - GUTTER * F.scale, room, focused)
    elseif v.shelf then
        -- The shelf, as a grid of cards with the wallet beside it.
        pages.shop(v, panel_x + GUTTER * F.scale, top,
                  panel_w - 14 * F.scale - GUTTER * F.scale, room, focused)
    elseif v.rows and #v.rows > 0 and v.rows[1].hull then
        ship_grid(tx, top, avail, room, v, focused)
    else
        -- Two lines of room where the rows have two lines in them, held to
        -- one height either way so nothing shifts as the cursor walks down.
        local noted = false
        for _, r in ipairs(v.rows) do
            if r.note then noted = true break end
        end
        -- A section head above the row that opens one, which is how the mocks
        -- group a list: a small label and the map border's tick, and then the
        -- rows the label is about. Only where the whole list fits, because a
        -- head that scrolls off leaves the rows under it belonging to
        -- whatever the eye last saw.
        local heads = 0
        for _, r in ipairs(v.rows) do
            if r.sect then heads = heads + 1 end
        end
        local SECT = 24 * F.scale
        local rowh = math.min((noted and 58 or (M.compact and 46 or 40)) * F.scale,
                              math.max(30 * F.scale,
                                       (room - heads * SECT)
                                       / math.max(#v.rows, 1)))
        -- A short list sits in the middle of the room rather than at the top
        -- of it: three games hung under a title on a tall phone leave the
        -- screen looking half loaded. A list long enough to fill the space
        -- starts where it always did, so nothing shifts as one grows.
        local used = rowh * #v.rows + heads * SECT
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
        local fits = math.max(1, math.floor((room - heads * SECT) / rowh))
        local first = 1
        if #v.rows > fits then
            ty = top
            local cur = (v.sel and v.sel > 0) and v.sel or 1
            first = math.min(math.max(1, cur - math.floor(fits / 2)),
                             #v.rows - fits + 1)
        end
        local at = ty
        for i = first, math.min(#v.rows, first + fits - 1) do
            local r = v.rows[i]
            -- A head belongs to the row under it, so it is drawn with that
            -- row rather than laid out in advance: a list that scrolls keeps
            -- the labels it can still show and drops the ones it cannot.
            if r.sect and at + SECT + rowh <= ty + room then
                ticks(tx, at + SECT * 0.45, lw - 20 * F.scale,
                      pal.a(pal.RADAR_TILE, 0.45), 14 * F.scale)
                lbl(r.sect, tx, at + SECT * 0.85)
                at = at + SECT
            end
            local y = at
            at = at + rowh
            -- The cursor, from whichever hand is on it. A pointer resting on
            -- a row of a page moves the cursor there rather than lighting a
            -- second row, so `hover` only ever arrives on the home screen,
            -- where the cursor belongs to the rail and the stage is a preview
            -- of what the mark beside it holds.
            stage_row(sx, y, GUTTER * F.scale + lw, rowh, r,
                      (focused and i == v.sel) or i == v.hover)
            if r.pick then hit(sx, y, GUTTER * F.scale + lw, rowh, "stage", i) end
            -- A row that leaves the game gets a real anchor laid over it by
            -- the page, because nothing this client does from its own loop is
            -- inside the tap that asked for it. Published in CSS pixels,
            -- which is what the page lays out in; everything here is drawable
            -- ones.
            if r.link then
                M.link_dom = string.format("%.1f,%.1f,%.1f,%.1f,%s",
                                           sx / F.scale, y / F.scale,
                                           (GUTTER * F.scale + lw) / F.scale,
                                           rowh / F.scale, r.link)
            end
        end
        -- What is off the ends, as the same tick the map border uses. It says
        -- there is more without spending a row on saying so.
        if #v.rows > fits then
            local bar = 3 * F.scale
            local hgt = room * fits / #v.rows
            -- How far down the bar its thumb starts. Named for that rather
            -- than `at`, which a few lines up is where the next row is drawn:
            -- one name for two positions in one function is how a scrollbar
            -- ends up tracking the wrong thing.
            local scrolled = room * (first - 1) / #v.rows
            rect(tx + lw + 8 * F.scale, ty, bar, room, pal.a(pal.DIM, 0.14))
            rect(tx + lw + 8 * F.scale, ty + scrolled, bar, hgt,
                 pal.a(pal.RADAR_TILE, 0.85))
        end
        if asidew > 0 then
            pages.aside(v.aside, panel_x + panel_w - asidew, top, asidew, room)
        end
        -- Under whatever rows there are, which over a game is the one row
        -- that leaves it.
        if v.empty then
            local ey = ty + used + 12 * F.scale
            empty_state(sx, ey, GUTTER * F.scale + lw, top + room - ey, v.empty)
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
        txt(v.note, tx, sy + sh - 4 * F.scale, 12 * F.scale, pal.a(pal.HURT, 0.95))
    elseif v.foot then
        -- The same line, for something that worked. It is the one thing on the
        -- controls page that is about the whole page rather than about a row,
        -- which is why it is down here and not in a column: what the page is
        -- waiting for, or what it just did.
        txt(v.foot, tx, sy + sh - 4 * F.scale, 12 * F.scale, pal.a(pal.DIM, 0.9))
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
        hit(0, 0, F.w, F.h, "close")
    end

    -- Last, over all of it, because it is the only thing being read.
    -- It takes the screen, boxes included: a question is answered, not
    -- clicked past.
    if v.ask then ask_card(sx, sy, GUTTER * F.scale + lw, sh, v.ask) end
    F.case = "upper"
end

-- --- cursor ----------------------------------------------------------------

-- The pointer. The page hides the browser's cursor over the canvas, so this
-- arrow is the only one anybody sees: the usual shape, restated in the
-- interface's language, with the heel corner cut at the same diagonal the
-- walls and the brackets use. Dark in the body and lit at the edge, the way
-- a hull is, so it reads over a starfield and over a panel alike. The tip is
-- the hotspot, exactly where the browser says the pointer is.
function M.cursor(x, y, alpha)
    local k = 16 * F.scale
    local cut = 0.22 * k
    -- Down the left edge, across the chamfer, and back up the hypotenuse.
    local pts = {
        x, ry(y),
        x, ry(y + k - cut),
        x + 0.93 * cut, ry(y + k - 0.38 * cut),
        x + 0.71 * k, ry(y + 0.71 * k),
    }
    F.layer:fan(pts, pal.a(pal.BG, 0.85 * alpha))
    F.layer:outline(pts, 1.25 * F.scale, pal.a(pal.INK, alpha), true)
end

return M
