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
-- How wide each letter of the menu's face draws, generated from the file it
-- draws with. See `text_w`.
local menu_face = require("arena.menu_face")
local state = require("arena.state")
local ui_frame = require("arena.ui_frame")
local ui_menu_marks = require("arena.ui_menu_marks")
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

-- The menu's type, as five sizes and nothing else.
--
-- In points, before the scale. There were fifteen sizes here, near enough all
-- of them written as bare numbers at the call site: 10, 10.5, 11, 11.5, 12,
-- 12.5, 13, 14, 15, 16, 18, 19, 21, 24 and 30, with four fifths of the type on
-- a page sitting at 13 or under. Nothing decided which of 11 and 11.5 a row
-- got. Somebody did, once, for that row.
--
-- Five, and each one has a job. LABEL is the upper case register that names a
-- group or a column of figures. BODY is everything small that is being read:
-- a sentence, a detail, a price, a word in a button, a tab. ROW is a name in a
-- list, LEAD the same name where it heads a sentence or a strip of figures,
-- and PAGE is what a page calls itself.
--
-- The gap from LABEL to BODY is smaller than the rest of the ladder on
-- purpose. Upper case reads larger than lower at the same size, so a caps
-- label set level with the body it names looks heavier than it.
local TYPE = {LABEL = 12, BODY = 14, ROW = 17, LEAD = 21, PAGE = 26}

-- What the menu multiplies its whole scale by on a window with room.
--
-- The menu is drawn at a phone's measure wherever it stands, which is the
-- right column and the wrong type: 390 points of column on a monitor is a
-- strip, and 10 point labels held at arm's length are half the angular size
-- they are in a hand. There was a constant for this, MENU_ZOOM at 1.18, and it
-- went out with decision 63 when the two layouts became one. Nothing replaced
-- it, so the menu spent five decisions being a phone screen shown on a desk.
--
-- The whole scale rather than the type alone. Rows, gaps, marks and the column
-- itself grow together, so nothing has to be measured twice; scaling the type
-- by itself is how a name ends up wider than the row that was sized for it.
-- 1.25 rather than the old 1.18 because the sizes above only moved partway to
-- what a desktop wants, and 12 points of label at 1.25 is 15, which is the
-- first size in this interface a monitor can read without leaning in.
local MENU_SCALE = 1.25
-- Two triggers, one line each in the status panel. Read once rather than
-- from `sim` per frame: the panel's height needs it before it draws.
local SIM_TRIGGERS = 2
local COL_W = 248      -- the width of the three stacked side panels

-- The dial, and the smaller one a phone draws.
--
-- `crop` comes off the side and off the reach by the same factor, so a small
-- screen gets a crop of the full dial rather than a scaled copy of it. A tile
-- is worth 1.4 pixels either way, which leaves a blip, a contact and the
-- space between two contacts reading as they do on a monitor; all that
-- changes is how much ground the square covers. Cropping the side alone would
-- have squeezed sixty tiles into two thirds of the pixels and cost every mark
-- on the dial a third of its separation.
--
-- Two thirds leaves forty tiles of reach, which is two screens of world
-- across on a phone: render/zoom.lua guarantees its short axis forty tiles,
-- so the dial reaches one screen past the glass in every direction. Uncropped
-- it reached three screens across there, against two and a half on an eight
-- hundred point window that sees fifty tiles at once. The smallest screen had
-- the most reach and the least room to draw it in.
local RADAR = {side = 168, crop = 2 / 3}

-- What this window draws the dial at. Asked by the side and by the reach,
-- because a dial cropped by one number and sized by another is a dial whose
-- contents no longer agree with its own scale.
function RADAR.factor()
    return M.compact and RADAR.crop or 1
end

M.hits = {}            -- clickable rectangles the menu published, top-left px
M.map = false          -- the whole map, in the radar's corner
-- How many hulls the ship page last drew across, for whoever moves a cursor
-- around it. Set by the drawing, because how many fit is a fact about the
-- window and nothing outside this file knows the window.
M.stage_cols = 4
-- Which pilot is being read about, by ship index, or nil. One at a time: this
-- answers "who is that", and two of them open at once is a filing cabinet.
M.inspect = nil
-- The connection, in numbers, behind the link bars in the menu's head. Off by
-- default and on no page, because it is for whoever is working on the client
-- rather than for whoever is flying.
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
-- Which of the landing's stops has its list open: "zone", "ship", or nil for
-- neither. The account stop opens the drawer instead of a list, so it never
-- lands here. Owned by this module the way `rooms_open` is: the arena flips
-- it on a press and everything that leaves the landing clears it.
M.land_open = nil
-- Where a press would land on the landing: the action a box publishes, and
-- the value that box carries so one row of an open list is told from the next.
--
-- One cursor, moved by either hand, which is the rule a page of the menu
-- follows. The pointer takes it through the same `M.pick` a press goes
-- through, so a row lights instead of the stop behind it and a pointer over
-- an open list's ground lights nothing at all; the arrows walk it through
-- `M.land_step` and enter presses whatever it names. Nil for nothing lit,
-- which is where the screen starts and what leaves enter meaning the key.
M.land_sel, M.land_sel_value = nil, nil

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

-- --- the pages -------------------------------------------------------------
--
-- The pages drawn as layouts rather than as lists, and the handful of marks
-- shared between them, kept in one table rather than under a name each: a Lua
-- chunk may hold two hundred locals and this file is at that ceiling.
--
-- Declared up here rather than beside the pages themselves, because the marks
-- on it are drawn by things a long way above them.
-- How far everything in the panel stands in from the drawer's edges: one
-- number, and the same one at both edges. Every page is handed this column and
-- draws inside it, so a name, a rule, a price and a sentence all begin and end
-- on the same two lines down the panel.
--
-- It was a gutter of 22 laid on top of the panel's own margin of 14, and then
-- a fourteen-point column held back at the right for the scroll tick, and then
-- a sixteen-point one on a row's own detail. They added up differently at each
-- edge and on each page: a row's name stood 36 in from the left while its
-- counts and prices stopped 50 short of the right, and a row's sentence was
-- clamped by nothing at all, so at the phone's width it ran to within eight
-- points of the glass. The scroll tick lives out in the margin now, which is
-- wide enough for it and is where a scrollbar goes anyway.
--
-- Up here with the primitives rather than beside the marks, because the pages
-- reach it several hundred lines earlier and a local declared after its first
-- use is a global lookup that comes back nil.
local MENU_PAD = 20

local pages = {}

-- A page with nothing on it, said with the dial that means "looking". Forward
-- declared because it is written where the other whole-page drawings are, a
-- long way below the friends page, which is the one page that draws it under
-- its own field rather than instead of itself.
local empty_state
-- The dial itself, forward declared for the same reason: the landing's
-- aside wears it beside a zone nobody is serving, and the aside is written
-- long before the dial is.
local sweep_dial
-- And the one that cuts a run of type against the column's edge, which `txt`
-- reaches several hundred lines before there is a way to measure a string.
local clip_run

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
    -- Cut against the column's edge, where the menu has set one. A run that
    -- has not reached it stands as it is; one that crosses it loses the
    -- letters past the line and hangs off its own left edge instead, since
    -- that is the edge the cut did not move.
    if F.clip_r then
        local kept, left = clip_run(s, x, px, font, pivot)
        if not kept then return end
        if kept ~= s then s, x, pivot = kept, left, "left" end
    end
    F.text_count = F.text_count + 1
    local t = F.text[F.text_count]
    if not t then t = {} F.text[F.text_count] = t end
    t.s, t.x, t.y, t.px, t.col, t.pivot =
        s, x, F.h - y, px, col, pivot or "left"
    t.font = font
    t.dim = F.text_dim ~= 1 and F.text_dim or nil
end

-- The small label the mocks head every group with: mono, upper, MUTE, LABEL.
-- It is the one piece of type in this interface that is neither a name nor a
-- number, and it is drawn raw because it is already in the case it wants and
-- the menu is otherwise set in a sentence's.
--
-- Callers pass a color to say something with it, never to say less loudly: the
-- register is one weight, and a label that has gone quiet is a label nobody
-- reads. Every one of them used to take an alpha, and every one of those was
-- under the 4.5:1 small type wants. See `pal.MUTE`.
--
-- The size is here rather than at the call sites so a head cannot be measured
-- at one size and drawn at another.
local LBL_PX = TYPE.LABEL
local function lbl(s, x, y, col, align, px)
    txt(string.upper(s or ""), x, y, px or LBL_PX * F.scale,
        col or pal.MUTE, align, nil, true)
end


-- A rectangle the pointer can land on, published in the same coordinates it
-- was drawn in. Defined up here with the other primitives because everything
-- that draws something clickable needs it, and it used to sit far enough down
-- the file that the first function to call it from above found nil.
-- `level` is for the one control that has a position as well as an identity:
-- a pip on a ladder, where the press means "this much" rather than "this row".
-- `pri` is for the handful of boxes that exist to stand behind other boxes: a
-- panel that swallows the press between two rows, the screen-wide box that
-- shuts the menu. See `M.pick`.
local function hit(x, y, w, h, action, value, level, pri)
    -- A box goes with the pixels it was drawn under. What the column has cut
    -- away is not on screen to be pressed: over a game the glass on that side
    -- of the edge is the arena, and a row that has slid past it is not there.
    if F.clip_r then
        if x >= F.clip_r then return end
        if x + w > F.clip_r then w = F.clip_r - x end
    end
    M.hits[#M.hits + 1] = {x = x, y = y, w = w, h = h,
                           action = action, value = value, level = level,
                           pri = pri}
end

-- The touch target floor, in points: what every platform's own ruler says a
-- fingertip is. Nothing here draws at that size, deliberately, and nothing
-- has to: a control keeps the shape the design gives it and makes up the
-- difference in `M.pick`, where a near miss on glass reaches the box it was
-- aimed at.
M.TARGET = 44

-- Which published box a press at (px, py) belongs to, or nil. The one copy of
-- the rule: `on_input`, the hover pass and the tests all ask this rather than
-- each walking the list with an idea of their own.
--
-- Containment first. Of the boxes under the point, the highest `pri` wins and
-- publish order breaks the tie, which is the first-box-wins rule every
-- existing pair was laid out against: a pip still beats the row behind it and
-- a close mark still beats the button it sits in, by order, while a backdrop
-- says out loud that it stands behind everything rather than depending on
-- being published last.
--
-- Then, for a finger only, the near miss. Each box is measured against the
-- TARGET floor and grown to it on any axis it falls short, and a press inside
-- the grown box belongs to the nearest of them: between two pips thirteen
-- points apart the closer one wins, and a box already a fingertip wide gains
-- nothing. Backdrops sit out, since nobody aims at a panel and forgiveness
-- toward one would swallow the miss meant for the control in front of it.
function M.pick(px, py, touching)
    local best, bestpri
    for _, r in ipairs(M.hits) do
        if px >= r.x and px <= r.x + r.w
           and py >= r.y and py <= r.y + r.h then
            local pri = r.pri or 0
            if not best or pri > bestpri then best, bestpri = r, pri end
        end
    end
    if best or not touching then return best end
    local floor = M.TARGET * F.scale
    local near, dist
    for _, r in ipairs(M.hits) do
        if (r.pri or 0) >= 0 then
            local gx = math.max(0, (floor - r.w) / 2)
            local gy = math.max(0, (floor - r.h) / 2)
            local dx = math.max(r.x - px, px - r.x - r.w, 0)
            local dy = math.max(r.y - py, py - r.y - r.h, 0)
            if dx <= gx and dy <= gy then
                local d = dx * dx + dy * dy
                if not near or d < dist then near, dist = r, d end
            end
        end
    end
    return near
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

-- A button's outline: a rectangle stroked all the way round, with a wash
-- inside it.
--
-- The one shape a thing to press wears. The corner's MENU and PLAYERS have
-- worn it from the start, and it is what the help page draws a key as, so a
-- hand that has learned one has learned all of them.
--
-- The menu's own buttons wore two other shapes until now. The friends page
-- drew them with `bracket` above, which is what holds a cluster together, and
-- the pair at the end of the top line were rounded pills, on the argument that
-- a pill is the shape the web puts a link in. Both were true about the shape
-- and wrong about the object: three controls that do what MENU does looked
-- like three other kinds of thing, on pages where MENU itself is one press
-- away.
--
-- What keeps the bracket is everything that is not a button: a field, a card,
-- a panel. So the two shapes now say which of those a rectangle is, which is
-- more than either was saying before.
local function key_box(x, y, w, h, fill, edge)
    if fill then rect(x, y, w, h, fill) end
    F.layer:frame(x, ry(y, h), w, h, 1.1 * F.scale, edge)
end

-- A lit rule with the light falling off one side of it, which is a wall face
-- stood on end. Everything in a column hangs off one of these.
local function vrule(x, y, h, col, spill)
    F.layer:skirt(x, ry(y), x, ry(y + h), (spill or 26 * F.scale), 0, 0.07, col)
    F.layer:seg(x, ry(y), x, ry(y + h), 1.4 * F.scale, col)
end

-- A rule between things inside the menu: one straight line, in the same color
-- and weight the panel's own left edge is drawn in.
--
-- These were the map border's tick, a row of little marks, which is the right
-- thing on a map border and wrong across a page: at a group head the eye read
-- a dotted line as something unfinished, and five of them down a page read as
-- texture rather than as structure. The border keeps its ticks; the menu gets
-- lines.
local function hrule(x, y, w, alpha)
    F.layer:seg(x, ry(y), x + w, ry(y), 1.0 * F.scale,
                pal.a(pal.RADAR_TILE, alpha or 0.7), true)
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

-- A selection: a translucent field over the whole of what is selected, a
-- shade brighter where it meets its rule.
--
-- It was a skirt falling off to nothing across the full width, which on a
-- phone row is a gradient and on a desktop row four hundred points wide is
-- two thirds of nothing: the cursor read as brighter type with a smudge at
-- one end. The falloff is now a short accent against the rule, and the field
-- carries the rest of the row.
local function wash(x, y, w, h, col)
    local a = col[4] or 0.14
    rect(x, y, w, h, pal.a(col, a * 0.8))
    F.layer:skirt(x, ry(y), x, ry(y + h),
                  math.min(w, 130 * F.scale), 0, a * 0.6, col)
end

-- How a row of the menu is lit, in one place.
--
-- The menu used to answer this eight different ways: a wash at the drawer span
-- for the stage's rows, the kit page's at 0.2 falling to 0.1 while the page
-- was unfocused, the friends page's band inset sixteen points either side, the
-- builds page's field hanging past the panel's right edge, and three more on
-- their own shapes at 0.13, 0.14 and 0.16. Nothing was decided by any of it:
-- they are one idea drawn by whoever wrote the page.
--
-- One table rather than a constant apiece, which is what this file's own
-- upvalue ceiling asks for. See client/tests/upvalues_test.lua.
local LIT = {
    -- Where a press would land, from either hand. A pointer resting on a row
    -- and the arrows standing on it are the same fact about the same row, so
    -- they share the weight, and whether the page holds the arrows does not
    -- change it: a page that dims its own cursor is a page saying "not this
    -- one" about the only row it is saying anything about.
    CURSOR = 0.18,
    -- Where you already are: the game you are flying, the hull you fly, the
    -- build that is loaded. It replaces the lit wedge that used to sit out in
    -- the gutter, where it pushed its own row's label right of every other
    -- label on the page. Both can be true of one row; the cursor outranks it,
    -- because what a press does next is the more urgent of the two.
    HERE = 0.07,
}

-- One row of the menu, lit. The field is the drawer, edge to edge, and the hit
-- box every page publishes is the same span: what lights up is what a press
-- lands on. It follows the drawer, so a row lit while the panel is sliding
-- travels with it.
function LIT.field(y, h, weight)
    local wx, _, ww = M.drawer_span()
    wash(wx, y, ww, h, pal.a(pal.FRIEND, weight))
end

-- How bright the label on a standing row is this frame. It breathes on the
-- clock the landing key breathes on, floored well clear of dark so the trough
-- never reads as a row that has gone out. `F.now` is zero under the test
-- harness, which is what keeps the layout tests still.
--
-- The cursor does not breathe: a row under the cursor is at full ink and
-- still, so the one row moving on the page is always the one you left running
-- somewhere else.
--
-- The clock is an argument so a test can sample the curve rather than a single
-- frame of it, and every drawing leaves it out and gets `F.now`.
function LIT.breath(t)
    return 0.74 + 0.26 * (0.5 + 0.5 * math.sin((t or F.now) * 2.6))
end

-- Published so the tests measure the rules rather than restating them. See
-- client/tests/row_field_test.lua.
M.LIT = LIT
M.MENU_PAD = MENU_PAD
-- Published so the tests measure the ladder rather than restating it, and so
-- a page that needs to know how tall a line is asks the same table the drawing
-- asks. See client/tests/type_test.lua.
M.TYPE = TYPE
M.MENU_SCALE = MENU_SCALE

-- A count, as marks rather than as a number: it reads at a glance and never
-- asks the eye to parse a digit.
-- Who is in a seat, in two marks that answer one question.
--
-- A person wears pilot's wings. A machine wears a chip. Drawn rather than
-- spelled, because "AI" beside a name is two letters that read as part of
-- the name until you have learned they are not, and these lists are scanned
-- rather than read.
--
-- What these replaced was a pair of helmets: a domed shell with a visor
-- wrapped into it, and a boxed one with two lamps and an antenna. That pair
-- read at every size and the logic under it was sound, curved is grown and
-- boxed is built. The objection was to the drawing. Two heads in a row of
-- numbers are two faces looking back at the reader, and the shells carried
-- enough detail that what separated them was a texture rather than a shape.
--
-- Badges carry the same fact with no head in them. A badge is what a seat is
-- issued rather than what sits in it, and both of these are shapes a player
-- already knows before the game explains anything: wings mean a pilot, a
-- square with legs means silicon. They also part at the silhouette instead
-- of at the detail, which is the half that survives being drawn at eleven
-- points beside a count.
--
-- Eleven points, kept from the helmets. It is still a mark beside a number
-- rather than a picture in a row, and it is what the feathers need to stay
-- three feathers instead of one wing.
local MARK_K = 11

-- Pilot's wings: a boss with three feathers off each side.
--
-- `cx` is the middle of the mark and `cy` the middle of the line it sits on,
-- so a caller can hand it a row's center without knowing the height.
--
-- Feathers rather than a filled spread, because the gaps are what make this
-- wings at all: solid at eleven points it is a moustache. They are struck a
-- shade under the mark's own pen for the same reason, since a heavy pen
-- closes the gaps it is drawn between, and the gaps are the mark.
--
-- Cut so the spread is exactly the mark's width. Every caller lays this out
-- against `k` and one of them sets it beside a name, so wings that reached
-- past what they reported would be wings that touch a call sign.
local function pilot_mark(cx, cy, col, k, line)
    k = k or MARK_K * F.scale
    line = (line or pen(k, 0.11)) * 0.85
    local function px(t) return cx + t * k end
    local function py(t) return ry(cy + t * k) end
    -- The ship the badge is issued for, which is what a pilot's wings have
    -- in the middle of them. This is the Apex's own outline, a little
    -- under half the mark's width: nose, wings swept back to tips near the tail, and a
    -- trailing edge cut into prongs by the engine block between them.
    --
    -- Three shapes were drawn before it and each failed for its own reason,
    -- which is worth writing down because they all looked reasonable on the
    -- way past. A diamond says nothing about which way it is flying, being
    -- as pointed at the back as at the front. An arrowhead with a stem under
    -- it is an up arrow, and nothing else, however much the stem is called
    -- an engine. A delta with a flat trailing edge is a triangle: no worse
    -- than the arrow but no better than generic.
    --
    -- What none of them had is the cut tail, and that turns out to be the
    -- whole of it. A pointed nose is shared with a great many shapes and a
    -- swept wing with a few, but a shape that forks at the back is read as a
    -- craft with engines in it and almost nothing else. The rail's own Ship
    -- stop has been proving that all along, drawing this same hull two sizes
    -- up.
    --
    -- Three quads, because a quad here draws the triangles 1-2-3 and 1-3-4
    -- and the silhouette is concave twice. The fuselage runs nose to tail
    -- through the two notches; each wing is its own piece from the leading
    -- edge out to the tip and back in. The notches are the gaps left between
    -- them, which is why they are drawn apart rather than as one run.
    --
    -- Taller than the fan it sits in, on purpose. Every earlier cut kept the
    -- ship inside the feathers and every one of them read as a lump between
    -- two wings. The badge is a ship that wings are pinned to, so the ship
    -- is the thing that should be seen first.
    F.layer:quad(px(0), py(-0.325), px(0.070), py(0.225),
                 px(0), py(0.325), px(-0.070), py(0.225), col)
    for _, f in ipairs({1, -1}) do
        F.layer:quad(px(f * 0.052), py(-0.005), px(f * 0.220), py(0.275),
                     px(f * 0.170), py(0.325), px(f * 0.070), py(0.225), col)
    end
    -- Swept back and fanned, longest on top. A rank of parallel strokes is a
    -- chevron; what makes a wing is that the three of them disagree about
    -- where they are going.
    --
    -- Each one starts off the hull's own edge rather than at a shared
    -- distance from the middle. They all began at one x, which is a straight
    -- line down a shape that has no straight line in it: the hull is a hair
    -- wide under the nose and four times that by the wingtip, so a root set
    -- clear of it at the bottom left the top two hanging in space.
    --
    -- The roots are the leading edge's x at each height plus the same small
    -- clearance, so the gap behind a feather is the same gap whichever
    -- feather you look at. Drawn touching first, and touching is worse: the
    -- three run into the hull and the badge reads as one blob with spines.
    -- What it wants is to sit just off, near enough to belong to the ship
    -- and far enough that the eye finds the edge.
    --
    -- Which makes these numbers the hull's, and they have to move when it
    -- does. Set wrong they do not fall off the mark or cross anything, they
    -- just reopen the gap unevenly, which is the kind of fault that lasts
    -- because nothing about it looks broken.
    for _, w in ipairs({1, -1}) do
        F.layer:seg(px(w * 0.118), py(-0.06), px(w * 0.500), py(-0.30),
                    line, col, true)
        F.layer:seg(px(w * 0.166), py(0.06), px(w * 0.463), py(-0.10),
                    line, col, true)
        F.layer:seg(px(w * 0.238), py(0.18), px(w * 0.389), py(0.09),
                    line, col, true)
    end
    return k
end

-- A chip: a square package with a core in it and two legs a side.
--
-- `x` is its left edge rather than its center, because every caller of this
-- one is laying a row out left to right and knows where the mark starts.
--
-- The legs are the mark. A square with a square in it is a button, and what
-- says silicon is the little runs coming out of the package, so they are
-- drawn on all four sides even at the size where each is two pixels: eight
-- of them read as a fringe, and a fringe is enough to carry it.
--
-- Butted rather than capped, each leg drawing its own length and no more. A
-- capped stroke runs half a width past each end, and eight of them would lay
-- a second line along all four sides of the package, which at the part alpha
-- every nameplate draws these at is a package with brighter edges than its
-- own outline.
local function bot_mark(x, y, col, k, line)
    k = k or MARK_K * F.scale
    line = line or pen(k, 0.11)
    local cx = x + k / 2
    local function px(t) return cx + t * k end
    local function py(t) return ry(y + t * k) end
    local s, leg = 0.33, 0.50
    F.layer:outline({px(-s), py(-s), px(s), py(-s),
                     px(s), py(s), px(-s), py(s)}, line, col, true)
    F.layer:quad(px(-0.11), py(-0.11), px(0.11), py(-0.11),
                 px(0.11), py(0.11), px(-0.11), py(0.11), col)
    for _, t in ipairs({-0.165, 0.165}) do
        F.layer:seg(px(-s), py(t), px(-leg), py(t), line, col)
        F.layer:seg(px(s), py(t), px(leg), py(t), line, col)
        F.layer:seg(px(t), py(-s), px(t), py(-leg), line, col)
        F.layer:seg(px(t), py(s), px(t), py(leg), line, col)
    end
    return k
end


-- How wide a string draws, in the face it will be drawn in.
--
-- Exact rather than an estimate, in both faces. The arena's is DejaVu Sans
-- Mono, which advances 1233 of 2048 units per glyph at every size; the menu's
-- is not monospace, so its advances are read out of the file itself and this
-- sums them. See `client/tools/font_advances.py`.
--
-- Measuring the mono for a string the menu draws is the bug this exists to
-- stop, and it had put a caret two letters past the end of a call sign and a
-- lit field wider on one side of a tab than the other. The mono runs about a
-- fifth wide of the menu's lower case, and the error is per letter, so it
-- grows with the word.
--
-- `raw` says the caller is quoting rather than saying, and is the same flag
-- `txt` takes: the menu sets a line in a sentence's case, so a word measured
-- as it was written and drawn with its first letter raised is measured one
-- letter short of what lands.
local ADVANCE = 1233 / 2048
local function text_w(s, px, font, raw)
    if font ~= MENU_FONT then return #s * px * ADVANCE end
    if not raw then s = cased(s) end
    local adv, w = menu_face.adv, 0
    for i = 1, #s do
        w = w + (adv[string.byte(s, i)] or menu_face.widest)
    end
    return w * px
end

-- What is left of a run of type once the column's edge has cut it: the
-- letters that fall inside and where their left edge stands, or nil if the
-- edge took the whole run.
--
-- A mesh is cut anywhere; a glyph is not, so this cuts at the nearest letter.
-- The run is measured from its own left edge whatever it is hung on, so a
-- price pivoted off the right of a row loses its tail exactly the way a name
-- does, and what comes back is pivoted left because that is the end of it the
-- cut has not touched.
clip_run = function(s, x, px, font, pivot)
    local edge = F.clip_r
    -- Already cased by the caller, so measured raw: measuring it again as
    -- written would be a letter short of what lands.
    local w = text_w(s, px, font, true)
    local left = x
    if pivot == "right" then left = x - w
    elseif pivot == "center" then left = x - w / 2 end
    if left >= edge then return nil end
    if left + w <= edge then return s, left end
    local room = edge - left
    if font ~= MENU_FONT then
        local n = math.floor(room / (px * ADVANCE))
        if n < 1 then return nil end
        return string.sub(s, 1, n), left
    end
    local adv, run = menu_face.adv, 0
    for i = 1, #s do
        run = run + (adv[string.byte(s, i)] or menu_face.widest) * px
        if run > room then
            if i == 1 then return nil end
            return string.sub(s, 1, i - 1), left
        end
    end
    return s, left
end

-- A key with a word in it: the shape every page presses to do a thing.
--
-- Laid out from its right edge and handing back its left, so a row can hang
-- two or three of them off its own end and let the name give way. `go` is
-- whether the thing it does is the encouraging one, which is the difference
-- between "accept" and "ignore" sitting side by side.
--
-- It lived inside the friends page, which was the first page to need one.
-- The shop needs the same shape for its BUY, and two of these would be two
-- chances to change the look of a button and only remember one of them.
local function row_button_w(label)
    return text_w(label, TYPE.BODY * F.scale, MENU_FONT) + 26 * F.scale
end

local function row_button(bx, cy, h, label, go, hot, action, val, lev)
    local bw = row_button_w(label)
    local by = cy - h / 2
    local edge = go and pal.FRIEND or pal.KEY_EDGE
    rect(bx - bw, by, bw, h, pal.rgb(0x070b12, hot and 0.85 or 0.55))
    if hot then rect(bx - bw, by, bw, h, pal.a(pal.FRIEND, LIT.CURSOR)) end
    -- The wash goes down before the outline, so the stroke is the last
    -- thing drawn on the shape rather than a line under a field.
    key_box(bx - bw, by, bw, h, nil, edge)
    txt(label, bx - bw / 2, cy, TYPE.BODY * F.scale,
        go and pal.FRIEND or pal.INK, "center", MENU_FONT)
    if action then hit(bx - bw, by, bw, h, action, val, lev) end
    return bx - bw
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


-- A line somebody types into: the box, what is in it, the caret and the mark
-- that empties it.
--
-- Two pages hold one of these: the call sign on the friends page and the name
-- a new build is given. They were two drawings once, six points apart in
-- height, with different insets and only one of them wiping on a press. A
-- field is a field wherever it is, so this is the field, and a page supplies
-- the words and the actions.
--
-- Returns nothing. The caller publishes its own hit boxes through `act` and
-- `wipe`, which are the two presses a field takes: put the caret here, and
-- empty it.
-- On `pages` rather than as two locals of its own: this chunk sits at the two
-- hundred local ceiling a Lua function has, and the house answer is to gather
-- onto a table, since a table is one name however much it holds. See
-- client/tests/upvalues_test.lua.
pages.FIELD_TALL = 30
function pages.field(x, y, w, value, hint, on, act, wipe)
    local h = pages.FIELD_TALL * F.scale
    local cy = y + h / 2
    rect(x, y, w, h, pal.rgb(0x070b12, 0.55))
    if on then rect(x, y, w, h, pal.a(pal.FRIEND, 0.1)) end
    bracket(x, y, w, h, pal.a(on and pal.FRIEND or pal.RADAR_TILE,
                              on and 0.9 or 0.55), 10 * F.scale)
    local ix = x + 11 * F.scale
    local px = TYPE.BODY * F.scale
    if value == "" then
        -- The placeholder is the only thing on screen saying what to type, so
        -- it is written to be read. It was DIM at half alpha, 1.94:1, the
        -- least legible run of type in the menu.
        txt(hint, ix, cy, px, pal.MUTE, nil, MENU_FONT)
    else
        txt(value, ix, cy, px, pal.CHARGE_COL, nil, MENU_FONT, true)
    end
    -- Where the next letter goes, and only while the box is taking them.
    if on then
        rect(ix + text_w(value, px, MENU_FONT, true) + 2 * F.scale,
             cy - 8 * F.scale, 1.6 * F.scale, 16 * F.scale,
             pal.a(pal.FRIEND, 0.9))
    end
    -- The way out, on the end of the box: holding backspace is the other way
    -- and it is not one anybody finds either.
    --
    -- Published before the box it sits inside. Hit boxes are tested in the
    -- order they went out and the first one wins, so the other way round the
    -- box swallows every press on its own mark.
    if value ~= "" and wipe then
        local mx = x + w - 12 * F.scale
        local k = 4 * F.scale
        for _, d in ipairs({{-1, 1}, {1, 1}}) do
            F.layer:seg(mx - k * d[1], ry(cy - k * d[2]),
                        mx + k * d[1], ry(cy + k * d[2]),
                        1.3 * F.scale, pal.a(pal.DIM, 0.9), true)
        end
        hit(mx - 12 * F.scale, y, 24 * F.scale, h, wipe)
    end
    if act then hit(x, y, w, h, act) end
end

local KEY_H, KEY_PAD, KEY_GAP = 26, 9, 6
local function key_size() return (FONT - 1) * F.scale end
local function key_w(label) return text_w(label, key_size()) + 2 * KEY_PAD * F.scale end
-- The outline is the whole of what says a key is there, so it draws at full
-- weight in a color that can carry the job: `pal.KEY_EDGE` off and the team
-- blue on. It was one color at two alphas, 0.55 of DIM when off, worth 2.12:1
-- against the column, which is a button you have to already know about. The
-- wash inside stays thin, because a wash is ground rather than structure.
local function key_frame(x, y, w, on)
    local col = on and pal.FRIEND or pal.DIM
    local h = KEY_H * F.scale
    key_box(x, y, w, h, pal.a(col, on and 0.16 or 0.07),
            on and pal.FRIEND or pal.KEY_EDGE)
    return col, h
end
local function key_cap(x, y, w, label, on)
    local col, h = key_frame(x, y, w, on)
    -- A key in flight is shouted: it is a thing to press rather than something
    -- the interface is saying, and upper case mono is what an instrument
    -- labels a button with. See `menu_key` for the other half of this.
    txt(string.upper(label), x + w / 2, y + h / 2, key_size(),
        on and pal.FRIEND or pal.INK, "center", nil, true)
    return col
end

-- The same key in the menu, which is a different object.
--
-- A key in the corner is glanced at over a fight. A key in the menu is a word
-- you read before you press it, so it takes the face and the case the rest of
-- the menu is set in. This is the one place the face rule splits on where a
-- thing is drawn rather than on what it says, and it splits exactly the way
-- interface.md already splits a call sign: the same name beside a nameplate in
-- flight is mono, because everything in flight is.
local function menu_key_w(label)
    return text_w(label, TYPE.BODY * F.scale, MENU_FONT) + 2 * KEY_PAD * F.scale
end

local function menu_key(x, y, w, label, on)
    local h = KEY_H * F.scale
    key_box(x, y, w, h, pal.a(pal.FRIEND, on and 0.16 or 0.07),
            on and pal.FRIEND or pal.KEY_EDGE)
    txt(label, x + w / 2, y + h / 2, TYPE.BODY * F.scale,
        on and pal.FRIEND or pal.INK, "center", MENU_FONT)
    return h
end

-- The way into the menu, as the three bars the whole web uses for it.
--
-- The word rides beside the mark on a desktop and the mark stands alone on a
-- phone. That is not a saving of room, or not much of one: the corner row goes
-- from 196 points to 175 of a phone's 390, and the clock band centered at 195
-- has to drop below the row either way. It is that a phone's corner is worked
-- by a thumb belonging to somebody who has met this screen before, and a
-- desktop's is read. MENU is the one word in that corner a first visit can
-- take without being taught a convention, so it stays where there is room.
--
-- The box stays in both. `key_box` is the one shape a pressable thing wears
-- here, and three bars floating on the glass would make this control the
-- exception the corner keys were drawn as boxes to stop being.
local BURGER = {w = 13, bar = 1.8, gap = 4.2}
local function burger_cap(x, y, on)
    local col = on and pal.FRIEND or pal.DIM
    local h = KEY_H * F.scale
    local bars = BURGER.w * F.scale
    local word = not M.compact and "MENU" or nil
    -- Square with the mark alone, so the key reads as one rather than as a
    -- word's box with a picture left in it. Under a fingertip either way:
    -- `M.pick` grows a box to the touch floor for a finger, so a 26 point key
    -- answers a press aimed anywhere near it.
    local w = word
        and (bars + 3 * KEY_PAD * F.scale + text_w(word, key_size()))
        or h
    key_box(x, y, w, h, pal.a(col, on and 0.16 or 0.07),
            pal.a(col, on and 0.95 or 0.55))
    local bx = word and (x + KEY_PAD * F.scale) or (x + w / 2 - bars / 2)
    local mid = y + h / 2
    local ink = pal.a(col, on and 1 or 0.85)
    for i = -1, 1 do
        rect(bx, mid + i * BURGER.gap * F.scale - BURGER.bar * F.scale / 2,
             bars, BURGER.bar * F.scale, ink)
    end
    if word then
        txt(word, bx + bars + KEY_PAD * F.scale, mid, key_size(), ink,
            nil, nil, true)
    end
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
    -- A frame that drew no menu has no drawer. The slide is state kept between
    -- frames, and without this it would keep whatever it was last left at
    -- forever: the arena calls `M.menu` for as long as the panel is on screen
    -- and then stops, so the frame after it stops is the frame that says so.
    -- Read by the instruments the drawer covers, which are drawn before it.
    if not M.menu_drawn then M.drawer_shut() end
    M.menu_drawn = false
    M.touching = touching or false
    -- Back to a row's ordinary height until the ending says otherwise this
    -- frame. Left set, a menu opened over the whistle would keep scrolling
    -- its own lists at the ending's pitch.
    M.podium_zoom = 1
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
-- The top row: where its line is, and how far the things standing in it are
-- allowed to reach.
--
-- One table rather than four names at this scope, because the file is at
-- Lua's ceiling of two hundred locals in a chunk and because these are one
-- fact between them. The row is the way into the menu at the left, the clock
-- band in the middle and the dial itself at the right; it has a center the
-- key and the band share, and an end at each side where an instrument stands
-- and the band stops.
local TOP = {
    -- How far the corner keys reach across the top left, filed by the thing
    -- that draws them rather than written down twice. It is a word's width,
    -- and PLAYERS grew the row the day it stopped being INFO.
    chip_right = 0,
}

-- The middle of the row, which everything standing in it lines up on.
--
-- A key's height sets it: the corner key is KEY_H tall and the band is drawn
-- to match. The readouts each worked out a baseline of their own from the
-- padding, which left them four points high on a monitor and ten on a phone,
-- and the padding is a horizontal measurement that has no business setting a
-- vertical one.
function TOP.mid()
    return F.safe_t + PAD * F.scale + KEY_H * F.scale / 2
end

-- Where the row ends, which is what the clock band may grow into.
--
-- The radar's left edge at rest. It stood in the strip a line below this row
-- until the link bars went into the menu's head and it came up into the
-- corner they left, and the band, which had grown to the window's own edge in
-- the meantime, gives that width back. Measured at rest so that opening the
-- map does not move it: the map hangs under the row (see `dial`) and has
-- nothing to do with where the row ends.
--
-- A phone is where this bites. 390 points hold the way into the menu, a
-- centered clock and a 112-point dial, and what is left over is not a call
-- sign, so the band gives up its two names there. The figures under them
-- always draw.
function TOP.row_right()
    return F.w - F.safe_r - PAD * F.scale
        - RADAR.side * RADAR.factor() * F.scale - KEY_GAP * F.scale
end

-- Both instruments this corner holds, since they are the same corner and one
-- replaces the other: the radar at rest, and the map when a player has asked
-- for it. They differ in the line they start on and in nothing else.
--
-- The map is about a quarter of the frame, capped three ways: against the
-- window's width so it cannot run off the left edge, against its height so
-- there is still room for the feed under it, and against the corner the MENU
-- and PLAYERS keys stand in, since a hit box over those is two controls a
-- pointer can no longer reach.
local function dial()
    local pad = PAD * F.scale
    local side = RADAR.side * RADAR.factor() * F.scale
    -- Hard into the corner, at the margin the way into the menu keeps from
    -- the other one. The radar started a row lower because the link bars
    -- stood in the strip above it, and those are in the menu's head now: with
    -- nothing left up there it was hanging off a row that had gone, which
    -- read as the instrument having slipped down the screen. The two things
    -- anchored to the top of the window are hung off one padding rather than
    -- one of them off the other, so `PAD` here is the same `PAD` the key
    -- uses, on both axes and at every window size.
    local iy = F.safe_t + pad
    if M.map then
        side = math.max(side,
                        math.min(math.min(F.w, F.h) * 0.66, F.h * 0.66,
                                 F.w - F.safe_r - pad - math.max(TOP.chip_right + 8 * F.scale,
                                                         124 * F.scale)))
        -- The map keeps the line under the row instead. The radar is narrow
        -- enough to stand beside the clock band, and this is two thirds of
        -- the short side of the window: on an upright phone it reaches past
        -- the middle, so sharing the band's line would put the clock on top
        -- of it. Capping its width to clear the band is not a way out, since
        -- what that leaves at 390 points is narrower than the radar it grew
        -- from.
        iy = TOP.mid() + KEY_H * F.scale / 2
    end
    -- Whole pixels. The dial snaps its contents to its own origin, so an
    -- origin landing on a half pixel would put the fraction back into every
    -- blip it was taken out of. Density is not always a whole number and
    -- neither, then, is the padding.
    local ix = math.floor(F.w - F.safe_r - pad - side)
    iy = math.floor(iy)
    side = math.floor(side)
    return ix, iy, side
end

-- How much vertical room it takes, so the feed under it can be told rather
-- than guess. The square and a gap: nothing hangs off the dial's foot now
-- that the tile readout has gone, so this is the instrument's own extent
-- again.
function M.radar_span()
    local _, iy, side = dial()
    return iy + side + 14 * F.scale
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
-- the line. Set once per frame from what the zone told this client its side
-- is.
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
    -- The whole corner is the dial's, hard into it. The link bars used to
    -- stand in the strip above and are in the menu's head now, so there is no
    -- strip: the square starts at the same margin the way into the menu keeps
    -- from the corner opposite, and its caption hangs off its foot.
    local ix, iy, r = dial()
    rect(ix, iy, r, r, pal.a(pal.RADAR_BG, 0.55))
    -- The dial is the way in to the map: a thing you point at to see more of
    -- is a thing you can click, and it saves teaching a key to somebody who
    -- never opens the help.
    if not F.menu_up then hit(ix, iy, r, r, "map") end

    -- Sixty tiles out, so the reference arena nearly fills the dial. At a
    -- hundred and fifty it sat in the middle quarter with the rest of the
    -- radar showing empty space nobody can fly to.
    --
    -- Sixty is also what the zone culls a snapshot to and what a bot sees by,
    -- and constant_drift_test holds those three copies together, so the number
    -- stays written down whole here and the crop is taken on the next line
    -- instead. Short of the filter is the safe direction: the dial then shows
    -- less than the client was told, where a longer one would carry a band of
    -- empty square the zone has never reported a ship into.
    local SPAN = 60 * 16
    SPAN = SPAN * RADAR.factor()
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
-- Terrain and nothing else. No ships, no flags, nothing in flight:
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
    -- The dial is square and a map need not be. Scaled by the longer side and
    -- centered on the short one, so a wide room reads as a wide room instead
    -- of being stretched to fill a square it is not.
    local k, ox, oy = 0, ix, iy
    if ov.grid > 0 then
        k = side / ov.grid
        ox = ix + (side - (ov.gw or ov.grid) * k) / 2
        oy = iy + (side - (ov.gh or ov.grid) * k) / 2
        local r = ov.rect
        for i = 1, ov.n, 5 do
            local cls = r[i + 4]
            local col = (cls == sim.T_SOLID and MAP_WALL)
                or (cls == sim.T_SLOPE and MAP_WALL)
                or (cls == sim.T_SAFE and MAP_SAFE)
                or (cls == sim.T_DOOR and MAP_DOOR)
                or MAP_HOLE
            rect(ox + r[i] * k, oy + r[i + 1] * k,
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
        own_arrow(ox + (sim.ship_x(me) / cell) * k,
                  oy + (sim.ship_y(me) / cell) * k, ix, iy, side, me)
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
                    -- Only where it is worth something. A zone opens every
                    -- pilot at a bounty of one, so "1" under every name on
                    -- screen was a column of ones saying nothing: what this
                    -- number is for is the pilot who is worth more than the
                    -- one beside them.
                    if bty > 1 then
                        -- In the side's color rather than the bounty gold,
                        -- so the name and the number under it read as one
                        -- label belonging to one squad. Gold said "this is a
                        -- bounty", which the position under a name already
                        -- says, and it said it identically for every pilot on
                        -- screen: the one thing a color here can carry is
                        -- whose they are.
                        --
                        -- Set as a price, with the rivet every other price in
                        -- the game wears. Position alone said "bounty", and
                        -- position is also what says kills, deaths and points
                        -- everywhere those are drawn: a bare figure under a
                        -- name is a number with no unit on it. This one is
                        -- what the zone pays for the hull it is over, so it
                        -- says so in the currency it pays in.
                        pages.priced(bty, sx + 12 * F.scale,
                                     sy + 25 * F.scale, 11 * F.scale,
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

-- How far the page under the tabs is scrolled, in pixels, and how tall it
-- came out.
--
-- A phone's ship page is fourteen hundred points of ladders and chips in the
-- eight hundred a phone has, and it was drawn straight past the bottom edge:
-- the last two charges sat under the tab bar with nothing that could reach
-- them. The extent is measured by whoever drew last and read back the next
-- frame to clamp against, which is a frame of lag on a number that only moves
-- when the window does or a page is opened.
M.page_scroll = 0
M.page_extent = 0

-- Keep the row the arrows are on inside the window.
--
-- A wheel and a finger move the page, and the arrows move the cursor: a cursor
-- that walks off the bottom takes the page with it, or the list goes on being
-- walked with nothing on screen to say where. `at` is the row's offset into
-- the page's own content, before the scroll is taken off it.
--
-- Only while the page has the arrows. A pointer moving a hover across rows is
-- not a reason to move the page under the hand holding it.
--
-- And only on the frame the cursor actually moved. Held every frame, this is
-- not a follow but a leash: a finger dragging a page the cursor is not on
-- gets it back the moment it lets go, which on glass is every drag, because
-- nothing there moves a cursor. A wheel escaped it only because a mouse is
-- hovering while it turns, and a hover is the cursor, so the row under the
-- pointer stayed on screen by definition. See `M.cursor_moved`.
local function follow_cursor(at, rowh, room, focused)
    if not focused or not M.cursor_moved or at == nil or room <= 0 then
        return
    end
    -- Never past the top. A row's offset has half a row taken off it so the
    -- cursor sits inside the window rather than against its edge, which on
    -- the first row is a negative scroll: harmless, since the clamp at the
    -- head of the next frame takes it back, and wrong for a frame.
    if at < M.page_scroll then M.page_scroll = math.max(0, at) end
    if at + rowh > M.page_scroll + room then
        M.page_scroll = at + rowh - room
    end
end

-- And the window that extent was measured against, published beside it for
-- the same reason and read back the same frame later.
--
-- It has to come from the page rather than from the stage, because the pages
-- do not all measure from the same line. The stage's own rectangle starts at
-- the top of the panel; the ship page and the friends page are handed a
-- shorter box that begins under the heading. Clamped against the stage, every
-- one of them stopped short by the difference: the last rows of a list were
-- reachable by nothing, and a page whose overflow was smaller than that
-- difference would not move at all.
M.page_room = 0
M.page_at = nil
-- Which page and row the cursor was on last frame, and whether it has moved
-- since. Read by `follow_cursor`, which only drags the page when it has.
M.cursor_page, M.cursor_sel = nil, nil
M.cursor_moved = false

-- Where that page was drawn, for a finger to be tested against. Four returns
-- rather than a table, because this is asked once a frame per touch point and
-- a table would be garbage every one of them.
function M.page_span()
    return M.page_x or 0, M.page_y or 0, M.page_w or 0, M.page_h or 0
end

-- Rows on screen at once. The list was capped at nine with no way to see the
-- tenth, which in a room of sixty-four is most of it.
local SHOWN = 9

-- How tall the roster panel comes out for this many pilots. Written once
-- because two callers need it: the panel draws itself from it, and the match
-- ending places its whole block off the total height of the parts, which
-- means knowing this before anything is drawn.
local function roster_h(n)
    local shown = math.min(n, SHOWN)
    return 24 * F.scale + shown * LINE * F.scale + 8 * F.scale
end

-- How tall one row is, in the pixels a press arrives in. Published because a
-- finger dragging the list has to be turned into rows and only this file knows
-- what a row measures. The wheel never needed it: a notch is one row by
-- definition, which is why the list could only ever be scrolled by a mouse.
function M.row_pitch()
    -- Times the ending's zoom, because a finger drags the rows as drawn: at
    -- the whistle the board's rows are taller, and a pitch read off the bare
    -- scale scrolled them faster than the finger moved.
    return LINE * F.scale * (M.podium_zoom or 1)
end

-- Where the left column starts: under the menu chip, since the chip owns the
-- corner. The rooms list is what stands there now; the scoreboard moved out
-- from under the corner keys and into the column under the band that opens
-- it. See `board` below.
local function top_y()
    return F.safe_t + PAD * F.scale + 32 * F.scale
end

-- The band's own measurements, in one place because three things need them:
-- the band draws itself from these, the column under it starts where they
-- end, and a test can ask what the band is rather than working the sizes out
-- a second time.
--
-- Everything on the band is a fraction of the clock. A side is two lines,
-- who they are over how they are doing, and those two plus the gap between
-- them add up to exactly the clock's height, so the band reads as one line of
-- instrument however many words are in it.
--
-- The clock is one key tall. It stood at 36 on a monitor, half again the key
-- beside it, and a number that size in the middle of the top row is a
-- headline rather than a reading: the row carries the way into the menu, the
-- clock and the dial's readouts, and a row wants one height. KEY_H is the
-- same at every window size, so the band is too, and the sizes here stopped
-- needing a column for a phone and a column for a monitor.
local function band_type()
    local clock = KEY_H * F.scale
    local name = 9 * F.scale
    local gap = 3 * F.scale
    return clock, name, clock - name - gap
end

-- The top row's own line, at every window size. The way into the menu is at
-- the left of it, and the band is what stands to the right of that.
--
-- A phone dropped it a line for a while. The band is centered and grows
-- outward with two names and two numbers, and the top right of a 390-point
-- screen carried the link bars and a tile readout both: at that width the
-- rival's name was drawn straight through the coordinates. The line under the
-- row is where the dial is, though, so what that bought was the same
-- collision against a bigger instrument, and it cost the one alignment the
-- row is for. Everything that was crowding it has since left the corner: the
-- readout is gone outright, the bars went into the menu's head (see
-- `pages.link`), and the dial came up into the space they left. A side with
-- nowhere to grow drops its name rather than the whole band dropping a line
-- (see `match_clock`).
local function band_top()
    return F.safe_t + PAD * F.scale
end

local function band_bottom()
    return band_top() + (band_type())
end

-- Where the board column stands, and how wide it is.
--
-- Under the band, centered on it, because the band is the control that opens
-- it and a panel belongs under the thing that opened it. The corner keys keep
-- the left column for the rooms list; this column is the scoreboard's own.
--
-- Filled once a frame by `M.hud` rather than worked out on demand, because
-- the top depends on what is standing between the band and the list (the
-- band always, and a line of banner when the room has said something), and
-- three panels read it.
--
-- Wider than the 248-point columns down the side of the screen, and capped
-- rather than fluid. A roster row is a name and five numbers, and at 248 the
-- numbers take two thirds of it and call signs are cut to nine characters; at
-- 340 a name is a name. The cap is what stops a phone held sideways from
-- spreading eight rows across 816 points of glass with the names at one edge
-- and the numbers at the other, and an upright phone is narrower than the cap
-- anyway, so there it is the margins that decide.
local BOARD_W = 340
local board = {x = 0, y = 0, w = 0}

local function set_board(under)
    local room = F.w - F.safe_l - F.safe_r - 2 * PAD * F.scale
    local w = math.min(BOARD_W * F.scale, room)
    board.w = w
    board.x = F.safe_l + PAD * F.scale + (room - w) / 2
    board.y = band_bottom() + (under or 0) + 10 * F.scale
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

-- The side the match ending puts first, or nil while a match is running.
--
-- Mid-fight the partition is "who is with me", because a name is only worth
-- reading once you know which end of the gun it is on. A finished match has a
-- better answer to which side comes first, and it is the one the ending is
-- about: whoever took it, whether or not that is yours. See `podium`.
local top_side = nil

local function by_column(a, b)
    if top_side ~= nil then
        -- Winner's side first, then by what each pilot did to the result:
        -- kills less deaths, since a side's score is the kills its pilots
        -- landed and every death is one of those handed to the other side.
        -- Level on that, the one who was in more of it. It is the measure the
        -- mark is picked by, so whoever wears it is the top row of its side.
        if a.watch ~= b.watch then return b.watch end
        local at, bt = a.team == top_side, b.team == top_side
        if at ~= bt then return at end
        local an, bn = a.k - a.d, b.k - b.d
        if an ~= bn then return an > bn end
        if a.k ~= b.k then return a.k > b.k end
        return (ahead(a, b))
    end
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
    elseif sort_key == "assists" then
        if a.a ~= b.a then return a.a > b.a end
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
    -- mean to scroll it. A backdrop by declaration, so the rows in front of it
    -- win the press whatever order anything was published in.
    hit(x, y, w, h, "rooms_list", nil, nil, -1)
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

-- Kills, deaths, assists, points and bounty, whichever way round they have to
-- be got.
local function seat_score(i, p)
    if seat_here(i) then
        -- The simulation for a seat we can see, because it lands twenty times
        -- a second and your own kill should appear the moment it happens.
        return sim.ship_kills(i), sim.ship_deaths(i), sim.ship_assists(i),
               sim.ship_points(i), sim.ship_bounty(i)
    end
    return (p and p.k) or 0, (p and p.d) or 0, (p and p.a) or 0,
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
            r.k, r.d, r.a, r.p, r.b = seat_score(i, p)
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
        r.k, r.d, r.a, r.p, r.b = 0, 0, 0, 0, 0
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

local function scores(me, pilots, watchers, viewer_name, always)
    -- Asked for, not assumed. Mid-fight this is the least useful thing on the
    -- screen and the feed still says who is killing whom, so it lives behind
    -- the same toggle your own loadout does.
    --
    -- `always` is the match ending, which is this panel with a head and a foot
    -- around it: at the whistle the room's numbers stop being something a
    -- player has to ask for.
    if not (M.details or always) then return 0 end
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
    local w = board.w
    local head = 24 * F.scale
    local h = roster_h(n)
    local x = board.x
    local top = board.y
    -- Enough behind it to read over a starfield, and no border: a rule down
    -- the left is what holds the column, the way it holds a wall face.
    rect(x, top, w, h, pal.a(pal.BG, 0.62))
    vrule(x, top, h, pal.a(pal.RADAR_TILE, 0.7))

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
    local pw, aw, dw, kw =
        col_w("p", "PTS"), col_w("a", "A"), col_w("d", "D"), col_w("k", "K")
    -- The ending has no bounty column: a bounty prices the next kill, and at
    -- the whistle there is no next kill. Points take the outer edge instead,
    -- and their head is the rivet mark rather than a word, because what that
    -- column is saying then is what the match paid.
    local bw, bx, px
    if always then
        px = x + w - 12 * F.scale
    else
        bw = col_w("b", "BTY")
        bx = x + w - 12 * F.scale
        px = bx - bw - GAP
    end
    local ax = px - pw - GAP
    local dx = ax - aw - GAP
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
        txt(label, hx, top + 14 * F.scale, small,
            on and pal.a(pal.FRIEND, 0.95) or pal.a(pal.DIM, 0.7), align)
        return on
    end
    head_col("name", "PILOTS", name_x, nil)
    head_col("kills", "K", kx, "right")
    head_col("deaths", "D", dx, "right")
    -- Kills you were part of and did not finish. A column rather than a line
    -- in the box a row opens, because it is the same kind of fact as the two
    -- beside it and belongs where they are.
    head_col("assists", "A", ax, "right")
    if always then
        -- The mark stands where the word stood, lit the same way when its
        -- column is the sort.
        local r = small * 0.5
        pages.rivet_mark(px - r, top + 14 * F.scale, r,
                         M.sort == "points" and pal.a(pal.FRIEND, 0.95)
                             or pal.a(pal.DIM, 0.7))
    else
        head_col("points", "PTS", px, "right")
        head_col("bounty", "BTY", bx, "right")
    end
    -- Hit boxes over the headings. Each takes its whole column and the gap to
    -- its left, so the four tile without overlapping and the labels, which
    -- are one or three characters wide, are not the target.
    hit(x + 8 * F.scale, top + 4 * F.scale, 60 * F.scale, 18 * F.scale, "sort_name")
    hit(kx - kw - GAP, top + 4 * F.scale, kw + GAP, 18 * F.scale, "sort_kills")
    hit(dx - dw - GAP, top + 4 * F.scale, dw + GAP, 18 * F.scale, "sort_deaths")
    hit(ax - aw - GAP, top + 4 * F.scale, aw + GAP, 18 * F.scale, "sort_assists")
    hit(px - pw - GAP, top + 4 * F.scale, pw + GAP, 18 * F.scale, "sort_points")
    if not always then
        hit(bx - bw - GAP, top + 4 * F.scale, bw + GAP, 18 * F.scale, "sort_bounty")
    end
    ticks(x + 12 * F.scale, top + 20 * F.scale, w - 24 * F.scale,
          pal.a(pal.RADAR_TILE, 0.35), 14 * F.scale)

    -- Who wears the mark, worked out once rather than per row. Only at the
    -- ending: mid-fight the board is a list of who is here, and a prize on it
    -- is a reading nobody asked for while they are being shot at.
    --
    -- On the side that took it, and never on the other one. A match is won by
    -- a side and the mark is the winner's to hand out; the best pilot on a
    -- side that lost is a reading about a fight that did not go their way.
    --
    -- Kills less deaths, which is what that pilot was worth to the result
    -- rather than how much of it they were seen doing. The score is the kills
    -- a side's pilots landed, so a death is a point handed to the other side
    -- and the pilot who took five and gave back four moved the match by one.
    -- Level on that, the one with more kills: the same net through more of
    -- the fight is more of the fight.
    --
    -- And only in a room big enough for the mark to say something. A duel is
    -- first to one, so the winner is the only pilot with a kill and the mark
    -- would be the bar over it said a second time. Three scorers is where a
    -- prize starts picking somebody out rather than restating the result.
    local best = nil
    if top_side ~= nil then
        local scored = 0
        for i = 1, n do
            if not rows[i].watch and rows[i].k > 0 then scored = scored + 1 end
        end
        if scored >= 3 then
            local best_net = 0
            for i = 1, n do
                local r = rows[i]
                -- Something shot down, still. A pilot who stayed out of every
                -- fight comes out level at nothing, which beats a wingman who
                -- traded four for five, and the mark is not for hiding.
                if not r.watch and r.team == top_side and r.k > 0 then
                    local net = r.k - r.d
                    if best == nil or net > best_net
                       or (net == best_net and r.k > best.k) then
                        best, best_net = r, net
                    end
                end
            end
        end
    end

    local y = top + head
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
        -- Who moved the match most, at the ending only and on the side that
        -- took it. Nobody in a scoreless match, because a mark on a pilot
        -- with no kills is a prize for turning up, and the more kills where
        -- two are level on net, so it lands in the same place on every
        -- machine rather than on whoever the roster happened to name first.
        if best ~= nil and r == best then
            local at = name_x + text_w(name, num) + 8 * F.scale
            if at + text_w("MVP", small) < mark_x then
                lbl("mvp", at, cy, pal.a(pal.PAID, 0.95), nil, small)
            end
        end
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
            txt("watching", always and px or bx, cy, small,
                pal.a(pal.DIM, 0.7), "right")
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
            txt(tostring(r.a), ax, cy, num, pal.a(pal.INK, 0.85), "right")
            -- The bounty in gold, which is the color it wears on a
            -- nameplate, in the corner stack and in the box this row opens.
            -- Points held the gold while it was the only score here; with
            -- both on the row, one of them has to be the one that means
            -- bounty everywhere else.
            txt(tostring(r.p), px, cy, num, pal.a(pal.INK, 0.85), "right")
            if not always then
                txt(tostring(r.b), bx, cy, num, pal.a(pal.BOUNTY, 0.9),
                    "right")
            end
        end
        y = y + LINE * F.scale
    end

    -- No line of totals under the rows. It counted the room by seat label,
    -- "8 here: 1 signed, 0 guest, 7 ai", and went at Chris's request: the
    -- marks in the rows already say who is a person, and the PLAYERS chip
    -- that opens this panel carries the head count.

    -- Only when there is something to scroll to. A bar on a list that fits is
    -- a control that does nothing.
    if n > shown then
        local track = shown * LINE * F.scale
        local ty = top + head
        local frac = shown / n
        local bar = math.max(10 * F.scale, track * frac)
        local at = (M.scroll / math.max(1, n - shown)) * (track - bar)
        F.layer:seg(x + w - 3 * F.scale, ry(ty + at), x + w - 3 * F.scale, ry(ty + at + bar),
              2 * F.scale, pal.a(pal.RADAR_TILE, 0.8))
    end

    -- The whole panel takes the wheel, rather than a strip beside it: a list
    -- is the thing you point at when you mean to scroll it. A backdrop, so
    -- every row in front of it wins the press by rank rather than by the luck
    -- of publish order.
    hit(x, top, w, h, "scores", nil, nil, -1)

    -- The bottom edge, not the height: what the loadout below needs to know
    -- is where this ends, and it does not start at the top of the screen.
    return top + h
end

-- What a finished leg was, as the row says it and in the color it says it.
--
-- "won" rather than the mode's "cleared", because a row in a list of fights is
-- read as a result and clearing is what the rung was, not what you did.
local LEG_WORD = {
    lost = {"lost", pal.ENEMY},
    cleared = {"won", pal.FRIEND},
    drawn = {"drew", pal.DIM},
}

-- The run so far, under the roster, for the one game that is a run.
--
-- Two sections, in the order a duel is read: where the run stands, and then
-- the fights that got it there. Ladder is an evening of ten-second fights and
-- what a climber is playing for is how many they take without dying; the room
-- is the only thing that sees a whole run, so the room is where both come
-- from and this draws what arrived.
--
-- Behind the scoreboard's own toggle, because they answer the same kind of
-- question and a player who opened one wants the others.
--
-- What used to be here was a rung number at the head and another on every
-- row, with a scoreline between them. None of the three said anything a
-- player could act on: a rung was a roster slot, the floor beside it a save
-- point a loss could not cross, and the scoreline is 1-0 or 0-1 in a mode that
-- is first to one. See decision 74. All three are gone from the game as well
-- now, with the ladder they belonged to: decision 92.

-- One table for the run's two sections, because ui.lua sits on Lua's ceiling
-- of two hundred locals in a chunk and four names here would put it over.
-- `SHOWN` is how many fights the panel draws, which is exactly what the room
-- sends, and `READ_H` is the height of the readings band. Both are published
-- because the ending measures the whole block before it places any of it.
local RUN = {SHOWN = 5, READ_H = 44}
M.RUN = RUN

-- How many legs the column has room for, and so how tall the fights section
-- comes out. Two thirds of the screen is the ceiling, because the pilot box
-- hangs under whatever this returns and the corner stack grows up from the
-- bottom left into the same column. A phone gets fewer rows rather than a
-- panel running off the bottom, and the rows it drops are the oldest.
--
-- Its own function because the match ending measures the whole block before
-- it places any of it, exactly as it does with the roster above this.
function RUN.shown(o, y0, cap)
    local duel = o.match and o.match.duel
    local log = duel and duel.log or {}
    -- The ending hands down a cap, and that cap is the answer: it was measured
    -- against the whole block before any of it was placed, and the block is
    -- centered rather than hung off the top of the screen. Intersecting it
    -- with the rule below cost the ending three of its five rows, because
    -- two thirds of the screen is above where a centered block's list starts.
    if cap then return math.min(#log, RUN.SHOWN, math.max(0, cap)) end
    local room = math.floor((F.h * 0.66 - y0 - RUN.READ_H * F.scale
                             - 8 * F.scale) / (LINE * F.scale))
    return math.min(#log, RUN.SHOWN, math.max(0, room))
end

-- Where the run stands: three readings, label over value, with a thin rule
-- between the stacks.
--
-- The grammar is the play page's format strip and the band's own TIME and
-- PLAYERS: a reading is a label over a number, and a heading is a word in a
-- row of words above columns. These were drawn as the second thing for a
-- while, sitting where the roster's own K D A sit, at the same size under the
-- same ticked rule, heading columns they had nothing to do with. A shape is
-- read before the words in it are.
--
-- Above the fights rather than below them, because the streak is what the
-- mode is played for and the fights are how it got there.
function RUN.readings(o, top)
    local duel = o.match.duel
    local x, w = board.x, board.w
    local h = RUN.READ_H * F.scale
    local small = LBL_PX * F.scale
    local num = (FONT) * F.scale
    rect(x, top, w, h, pal.a(pal.BG, 0.62))
    vrule(x, top, h, pal.a(pal.RADAR_TILE, 0.7))

    local at = x + 12 * F.scale
    local streak = duel.streak or 0
    local stacks = {
        {"streak", streak, streak > 0 and pal.FRIEND or pal.DIM},
        {"best", math.max(duel.best_streak or 0, streak), pal.INK},
        {"fights", duel.legs or #(duel.log or {}), pal.INK},
    }
    for i, stack in ipairs(stacks) do
        if i > 1 then
            -- Between the stacks rather than around them, and the height of
            -- the pair it separates: the strip is one instrument with three
            -- readings on it, not three boxes.
            F.layer:seg(at, ry(top + 11 * F.scale), at,
                        ry(top + h - 11 * F.scale), 1.0 * F.scale,
                        pal.a(pal.RADAR_TILE, 0.45))
            at = at + 15 * F.scale
        end
        lbl(stack[1], at, top + 15 * F.scale, pal.a(pal.DIM, 0.85), nil, small)
        txt(tostring(stack[2]), at, top + 31 * F.scale, num,
            pal.a(stack[3], 0.9))
        at = at + math.max(text_w(string.upper(stack[1]), small, nil, true),
                           text_w(tostring(stack[2]), num)) + 15 * F.scale
    end

    hit(x, top, w, h, "run_readings", nil, nil, -1)
    return top + h
end

-- And the fights themselves, newest first, one row each: who was across the
-- arena, what came of it, and how long it took.
--
-- No head. Everything that was ever in one is either gone or in the section
-- above, and a column of "won", "lost" and "drew" is labelled by its own rows,
-- as is a column of "0:44". The rival is set in the menu face because it is a
-- name being read, and the two beside it in the mono every number wears.
function RUN.fights(o, top, shown)
    local log = o.match.duel.log or {}
    local num = (FONT - 2) * F.scale
    local x, w = board.x, board.w
    local h = shown * LINE * F.scale + 12 * F.scale
    rect(x, top, w, h, pal.a(pal.BG, 0.62))
    vrule(x, top, h, pal.a(pal.RADAR_TILE, 0.7))

    local GAP = 7 * F.scale
    local function col_w(of)
        local wide = 26 * F.scale
        for k = 1, shown do
            wide = math.max(wide, text_w(of(log[#log - k + 1]), num))
        end
        return wide
    end
    local function clocked(leg)
        local secs = leg.seconds or 0
        return string.format("%d:%02d", math.floor(secs / 60), secs % 60)
    end
    local function verdict(leg)
        return (LEG_WORD[leg.result] or LEG_WORD.drawn)[1]
    end
    local tw = col_w(clocked)
    local vw = col_w(verdict)
    local tx = x + w - 12 * F.scale
    local vx = tx - tw - GAP
    local name_x = x + 12 * F.scale
    -- Cut to what the column has left, the way the roster cuts a call sign
    -- against its own mark column.
    local name_n = math.max(3, math.floor((vx - vw - GAP - name_x) /
                                          (num * ADVANCE)))

    local y = top + 6 * F.scale
    for k = 1, shown do
        local leg = log[#log - k + 1]
        local cy = y + LINE * F.scale / 2
        local said = LEG_WORD[leg.result] or LEG_WORD.drawn
        txt(string.sub(leg.rival or "", 1, name_n), name_x, cy, num,
            pal.a(pal.INK, 0.85), nil, MENU_FONT, true)
        txt(said[1], vx, cy, num, pal.a(said[2], 0.9), "right")
        txt(clocked(leg), tx, cy, num, pal.a(pal.INK, 0.8), "right")
        y = y + LINE * F.scale
    end

    -- A backdrop, the way the roster's own is one: nothing in here is a
    -- control, and a press landing on the arena behind a solid panel is the
    -- kind of thing that shoots a wall.
    hit(x, top, w, h, "run_log", nil, nil, -1)
    return top + h
end

local function run_log(o, top, always, cap)
    if not (M.details or always) then return top end
    local duel = o.match and o.match.duel
    if not duel then return top end
    -- The readings draw with nothing under them. A run that has not finished a
    -- fight yet is still a run, and a streak of zero is a reading rather than
    -- an absence: the shipped panel hid it at zero, so the one number this
    -- mode is played for went missing exactly on the screen a player reads
    -- after losing.
    local y = RUN.readings(o, top + 8 * F.scale)
    local shown = RUN.shown(o, top + 8 * F.scale, cap)
    if shown > 0 then y = RUN.fights(o, y + 8 * F.scale, shown) end
    return y
end

-- The notification feed: kills, arrivals, departures and flags. Newest first.
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
        -- A streak line gleams rather than sitting in a color. It is the one
        -- line in this column that is not a report of something that has
        -- finished happening: somebody is still on it while you are reading,
        -- and a still gold among five still lines is just a sixth line. The
        -- shimmer rides the line's own age, so two of them at once are a
        -- fraction out of step, which is what a room of them should look
        -- like.
        draw_feed_line(f.text, right - w, y + LINE * F.scale / 2, size,
                       f.gleam and pal.gleam(f.t, a)
                               or pal.a(f.col or pal.DIM, a))
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
-- somebody had just killed them.
--
-- So the phone gets the same feed, filtered to one line. Lines the arena
-- marked as being about this pilot: their kills and their deaths. A stranger
-- killing a stranger is news, and it is news a player in a fight cannot use.
-- A streak line passes whoever it names, because it is the one piece of room
-- news a fight runs on: it says who everybody goes after next, and a phone
-- that only played the announcement sound left its player hearing that
-- somebody was streaking with no way to learn who. And only the newest at
-- once, because two lines stacked over the middle of the screen is a panel,
-- and a panel over the fight is the thing the corner feed was moved out of
-- the way to avoid.
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
    -- than trusting the fraction, since a hull carrying two kinds of charge
    -- builds a taller rail than one carrying none, and the rail is the thing
    -- this must not land on.
    local floor = reach and (F.h - reach - 22 * F.scale) or F.h
    return math.min(F.h * 0.66, floor)
end

local function toast(lines, reach)
    local f = nil
    for i = 1, #lines do
        if (lines[i].mine or lines[i].gleam) and lines[i].t < TOAST_LIFE then
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
                   f.gleam and pal.gleam(f.t, a) or pal.a(f.col or pal.INK, a))
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
-- what a player actually holds is one gun and one bomb configured by its kit.
-- So there is one mark per trigger now, and an add-on is something drawn onto
-- it: the round you fire, wearing what it has learned.

-- The two shipped charges draw through marks.charge, which is the drawing a
-- pad's control carries on a phone: the corner and the thumb must not teach
-- two pictures for one thing, and for a while they did, plain rings here
-- against the pad's own pair.
local function gl_rings(cx, cy, k, col)
    marks.charge(0, cx, ry(cy), k, col)
end
local function gl_burst(cx, cy, k, col)
    marks.charge(1, cx, ry(cy), k, col)
end

-- The rivet: what this game charges in.
--
-- A currency wants a mark rather than a word. Every one in use is a shape with
-- a stroke or two struck through it, and that convention is what makes a glyph
-- read as money rather than as decoration, so this follows it: the head of a
-- rivet seen face on, struck through twice.
--
-- Two bars rather than one, and overhanging on both sides. One bar through a
-- circle is a "no entry" sign, which is a poor thing to price a shelf in; two
-- is what the yen, the euro and the won all do, and the overhang is what keeps
-- the strokes visible where the circle is only a few pixels across.
function pages.rivet_mark(cx, cy, r, col)
    local line = pen(r * 1.5, 0.15)
    -- The cap, the shank, and two strikes across it.
    --
    -- This started as a rivet head seen face on, a circle with the two bars
    -- struck through it, and at the size a price is actually set the bars sat
    -- inside the circle with nothing but a few pixels between them: they
    -- filled in and the mark read as a barred circle, which is a "no entry"
    -- sign. Seen from the side there is nothing enclosing the strikes, so the
    -- gap between them is the page, and the silhouette is a fastener rather
    -- than a symbol that could be anything.
    F.layer:seg(cx - r * 0.95, ry(cy - r * 0.9),
                cx + r * 0.95, ry(cy - r * 0.9), line, col)
    F.layer:seg(cx, ry(cy - r * 0.9), cx, ry(cy + r), line, col)
    for _, dy in ipairs({-0.05, 0.42}) do
        F.layer:seg(cx - r * 0.62, ry(cy + r * dy),
                    cx + r * 0.62, ry(cy + r * dy), line, col)
    end
end

-- A price, as the mark and the number: "40 rivets" was a word doing a glyph's
-- job, three times on every card.
function pages.priced(n, x, y, px, col, align)
    -- As tall as the figure beside it, near enough. A mark half the height of
    -- its own number reads as a bullet point rather than as a unit.
    local r = px * 0.46
    local w = text_w(tostring(n), px)
    local lead = r * 2.4
    local left = align == "right" and (x - w - lead) or x
    pages.rivet_mark(left + r, y + px * 0.02, r, col)
    txt(tostring(n), left + lead, y, px, col)
    return lead + w
end

-- A neutral fallback for a charge kind without its own mark.
local function gl_diamond(cx, cy, k, col)
    local pts = {cx, ry(cy - k), cx + k * 0.8, ry(cy),
                 cx, ry(cy + k), cx - k * 0.8, ry(cy)}
    F.layer:outline(pts, pen(k, 0.183), col, true)
end

-- A charge is whatever the zone put in the slot, so the mark follows the
-- name and an unfamiliar one falls back to a neutral diamond.
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
-- How far down a charge row washes on the tick its key shuts. Dim enough to
-- read as unavailable at a glance and not so dim that the row leaves the
-- corner: what a pilot is holding is still true while they wait for it.
local SHUT = 0.3

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
    -- a circle filling and reads as one.
    local slots = {}
    for _, c in ipairs(charges or {}) do
        if (c.count or 0) > 0 then slots[#slots + 1] = c end
    end
    local trigs = 0
    for t = 0, SIM_TRIGGERS - 1 do
        if sim.has_trigger(me, t) then trigs = trigs + 1 end
    end
    -- The rows this will actually draw. The extra one was the bounty's, and
    -- with that gone it reserved a row of nothing at the bottom: the block
    -- hangs off the bottom of the window and grows upward, so an unused row
    -- in the count lifts everything a row clear of where it belongs and
    -- changes the scale the whole block is drawn at.
    local n = trigs + #slots

    -- One number the whole block is measured in, so it grows as a drawing
    -- rather than as a pile of separately tuned constants. Everything below
    -- is in `z`, not in S.
    local z = F.scale * math.max(1, math.min(STACK,
                                       (F.h / F.scale) * STACK_SHARE / (n * 22)))
    local rows_h = 22 * z
    local x = F.safe_l + PAD * F.scale
    -- The axis every mark stands its subject on: the head of each round, the
    -- center of the repel's rings and the burst's hub, the middle of the
    -- fallback charge diamond. Far enough in that a bolt's trail, which runs a
    -- hull and a half back from its head, still starts inside the margin.
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
        --
        -- What the row does carry is the wait. A burst shuts its own key
        -- behind it, so the row goes out with it and comes back as the clock
        -- runs down, which is the same event drawn twice:
        -- one pip fewer says it was spent, and the row returning says when
        -- the next one may go. A blink would say the first and not the
        -- second, and a key that simply did nothing would say neither.
        --
        -- A kind with no delay, which the repel is, has no wait and never
        -- dims: `ready` is 1 the whole time.
        local ready = 1
        if (c.wait or 0) > 0 and (c.delay or 0) > 0 then
            ready = 1 - math.min(1, c.wait / c.delay)
        end
        local lit = SHUT + (1 - SHUT) * ready
        local slot = string.lower(c.name or c.short or "")
        local gc = CHARGE_GLYPHS[slot] or gl_diamond
        gc(mid, y + rows_h / 2, 7 * z,
           pal.a(CHARGE_HUES[slot] or pal.CHARGE_COL, 0.85 * lit))
        -- The count in the ship page's own circle grammar, pages.dot: solid
        -- is a charge in hand, a ring is the slot a spent one leaves. The
        -- corner used its own smaller pips for this, which was a second
        -- drawing for the one idea the hangar already taught.
        local slot_max = math.max(1, c.max or 3)
        for p = 1, slot_max do
            pages.dot(val + 3 * z + (p - 1) * 13 * z, y + rows_h / 2,
                      4.5 * z, p <= (c.count or 0) and "on" or "ring",
                      pal.a(pal.CHARGE_COL, lit))
        end
        local pw = val + 3 * z + (slot_max - 1) * 13 * z + 4.5 * z
        if pw > wide then wide = pw end
        -- A row per charge rather than one bracket over all of them. A
        -- repel and a burst are different things and each has a card of
        -- its own; they shared a sentence only while that sentence was
        -- about which key spends them.
        local key = "charge:" .. string.lower(c.name or c.short or "")
        zone(key, x, y, pw - x, rows_h)
        y = y + rows_h
    end

    -- What you are worth is not in here. It was: a diamond, the number, and
    -- the run beside it. The corner is what your triggers do and what you
    -- carry, which are the things a press changes, and a bounty is neither.
    -- It is also the one number in the corner that is about how other people
    -- see you rather than about what you can do next, and it is already said
    -- in the two places that ask that question: over every pilot's nameplate,
    -- your own included when somebody is watching you, and in the scoreboard
    -- column that sorts by it.

    return 0
end

-- The hull's own panel, which named the ship and drew a row of pips per
-- stat, is gone. Every fact on it is somewhere a pilot already looks: the
-- hull is the shape you are flying and its name is on the ship page you
-- chose it from, the three figures are your own row of the scoreboard, and
-- what a kit bought is a decision made in the hangar rather than a reading
-- taken mid-fight. It cost a panel's worth of the left column to say none of
-- it at a moment anybody could act on.

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
    local w = board.w
    local x = board.x
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
    -- The team row always exists now, so the count is fixed.
    local rows_n = 8
    local h = 30 * F.scale + rows_n * rowh
        + (invite and (KEY_H + 12) * F.scale or 0)
        + 10 * F.scale
    -- Under whatever is in the column, and never above where the column
    -- starts: with the scoreboard shut there is nothing above it, and a panel
    -- at the top of the screen lands on the menu chip.
    local y = math.max((top or 0) + 6 * F.scale, board.y)
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
    local lab = (FONT - 3) * F.scale
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

    -- Drawn as a key, the way everything else in this interface that is a
    -- thing to press is drawn: the corner's MENU and PLAYERS, the answers on
    -- a confirm card, every key on the help board. It was a word over a rule,
    -- which is what a control looked like here before the board taught the
    -- same hand what a key looks like, and a panel keeping the old idiom asks
    -- a player to know that this particular word is pressable.
    local label, action = nil, nil
    if invite then
        -- Once it is sent it says so and stops taking clicks: the zone answers
        -- an invitation with a team list that does not name the invitee, so
        -- this is the only acknowledgement there is, and a button that stayed
        -- pressable would invite an anxious second tap.
        label = (o.invited and o.invited[i]) and "INVITED" or "INVITE"
        action = (o.invited and o.invited[i]) and nil or "invite"
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
-- what the row is, how its kit configures it, and which key spends it.
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
-- `font` names the face the lines will be drawn in, because a line has to be
-- measured in the face it is set in. The menu's runs about 85% of the mono's
-- width for the same size, so a sentence measured with the mono's one number
-- breaks a word or two early on every line, which on a phone is a paragraph
-- one line taller than it needs to be. Nothing measures type by guessing.
local function wrapped(s, px, max, font)
    local out, line = {}, nil
    local width = font == MENU_FONT
        and function(t) return text_w(t, px, font, true) end
        or function(t) return glyph_w(t, px) end
    for word in string.gmatch(s, "%S+") do
        local try = line and (line .. " " .. word) or word
        if line and width(try) > max then
            out[#out + 1] = line
            line = word
        else
            line = try
        end
    end
    if line then out[#out + 1] = line end
    return out
end

-- What the kit put on a trigger, named at whatever length teaches best: `long`
-- where a short name is jargon and the ordinary name for everything else.
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

-- What a duelist reads while the room looks for somebody to fight.
--
-- The room benches both seats until the fight opens, and a benched hull is a
-- dead one as far as the core is concerned, so this used to be the word
-- DESTROYED: a player's first ten seconds of the game were spent being told
-- they had been shot before they had flown anywhere. The clock reads dashes
-- above, which says something is not running but not what.
--
-- The second line is why nothing is happening. The seat across the arena is
-- held open for a person for ten seconds before a house pilot is sent to it,
-- so a player who arrives to an empty room is looking at a wait with an end
-- on it rather than at a zone that is broken. See `DUEL_HOLD_TICKS` in
-- server/src/arena.rs.
--
-- Not spaced out the way DESTROYED is: that is one word standing on its own,
-- and a whole sentence set letter by letter is a thing to decode. The same
-- treatment SAFE ZONE gets, in the same place, for the same reason.
local function rival_note()
    local y = F.h * 0.46
    txt("WAITING FOR A RIVAL", F.w / 2, y, (M.compact and 12 or 16) * F.scale,
        pal.a(pal.INK, 0.9), "center")
    txt("a house pilot takes the seat if nobody does", F.w / 2,
        y + (M.compact and 15 or 20) * F.scale,
        (M.compact and 10 or 12) * F.scale, pal.a(pal.DIM, 0.9), "center")
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
local function menu_button(on_air, watch, room, landed)
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
    local cx = x
    -- The way in first, as its own drawing: it is the one key here that is a
    -- mark rather than a word, and on a phone it is only a mark.
    local menu_w = burger_cap(cx, y, F.menu_up)
    hit(cx, y, menu_w, KEY_H * F.scale, "open")
    cx = cx + menu_w + KEY_GAP * F.scale
    local keys = {}
    -- The way back into a hull, for a pilot the room is holding a seat for.
    -- Not on the landing, where PLAY NOW is that key and says it better: two
    -- controls for one act, one of them pulsing at the foot of the screen and
    -- one of them a chip in the corner, is the same offer made twice.
    if watch and not landed then
        keys[#keys + 1] = {"TAKE SEAT", "take_seat", false}
    end
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
    -- No PLAYERS key. It carried the head count and opened the roster, and the
    -- band across the top of the screen does both now: the score and the clock
    -- are what a player looks up there for, the roster is what a press on them
    -- opens, and two keys for one panel is the offer made twice. What the chip
    -- said about who was in the room, the rows in that panel say about each of
    -- them. See `match_clock`.
    -- The tally, when the room channel is pointed at you.
    --
    -- It sits on this row rather than at the top of the middle, which is where
    -- it started and where it could not stay: that strip already carries the
    -- flag pennants and the round's banner, both of them centered, and a notice
    -- laid over them read as a fault in the flags. Those two are about the
    -- round. This is about you, like the keys beside it, and it is chrome
    -- rather than anything happening in the arena.
    --
    -- Counted into `TOP.chip_right` like the keys are, so the map that opens
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
    end
    -- Nothing in this slot for a watcher. A green play mark and the word
    -- CHANNEL sat here, on the argument that what you are looking at is the
    -- same kind of fact about the connection as the tally beside it. It is
    -- not: the tally is a warning, because being on air changes how you fly,
    -- and this was a label on the obvious. Every hull on screen wears somebody
    -- else's call sign and none of them wears yours, which is the whole of
    -- what the word was there to say. Removed at Chris's request.
    TOP.chip_right = cx - KEY_GAP * F.scale
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
    -- And the text budget, which is the third capacity a frame can quietly
    -- run out of. `state.n` is what the last frame queued and the pool is
    -- what the gui will draw; the `+` is glyphs that did not appear, which
    -- is how the podium's chips lost their words with nothing saying so.
    local over = state.n - state.TEXT_POOL
    lines[#lines + 1] = {"text",
                         string.format("%d / %d", state.n, state.TEXT_POOL)
                         .. (over > 0 and (" +" .. over) or "")}
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
    -- The zone's name, which is the whole of what the wire says about a game
    -- now. It carried a sentence on a second line of the same message for as
    -- long as a zone had one, and this dropped it: a description that never
    -- changes is not a diagnostic, and it wrapped the header in prose while
    -- the numbers under it moved.
    txt(o.zone or "", x + w - 10 * F.scale, y + 15 * F.scale, size,
        pal.a(pal.DIM, 0.8), "right")
    for n, l in ipairs(lines) do
        local c = math.floor((n - 1) / per)
        local cx = x + c * colw
        local ly = y + 24 * F.scale + ((n - 1) % per) * rowh
        txt(l[1], cx + 10 * F.scale, ly + rowh / 2, size, pal.a(pal.DIM, 0.8))
        txt(l[2], cx + colw - 10 * F.scale, ly + rowh / 2, size,
            pal.a(pal.INK, 0.9), "right")
    end
    -- The way out is the thing itself. What opens this is the link meter in
    -- the menu's head, which is a fine place to keep a switch nobody needs
    -- and a poor place to look for one: the readout lands under the dial with
    -- the panel that opened it shut over the top of it, and a player who has
    -- finished reading it has no reason to think the answer is back inside
    -- the menu. So a press anywhere on the panel closes it, which is what
    -- every other slab of text in this interface does.
    --
    -- Filed here rather than beside the bars, because it is this rectangle,
    -- and it is this rectangle only once the wrapping above has decided how
    -- many columns the window can hold. A backdrop: it holds no controls
    -- today, and a slab of text that closes on a press is the same kind of
    -- thing as the panels that do.
    if not F.menu_up then hit(x, y, w, h, "debug", nil, nil, -1) end
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

local function duel_waiting(m)
    return m ~= nil and not m.playing and m.duel ~= nil
        and m.duel.waiting == true
end

local function match_ended(m)
    if m == nil or m.playing then return false end
    if m.duel == nil then return true end
    return m.artifact ~= nil and not duel_waiting(m)
end
-- The arena asks the same question, to keep the touch pads off the ending:
-- the whistle benched every hull, so the pads have nothing to drive, and the
-- board's foot keys land exactly where they draw.
M.match_ended = match_ended

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
-- The one pilot on a side, for a game that has one to a side.
--
-- Ladder is that game: one person, one house rival, and the whole question a
-- climber has about the rung in front of them is who they are fighting. The
-- roster already carries every seat's rating and how many rated games are
-- behind it, so this is a lookup rather than anything new on the wire.
local function side_seat(o, team)
    for i = 0, sim.ship_count() - 1 do
        local p = o.pilots and o.pilots[i]
        if (p or seat_here(i)) and seat_team(i, p) == team then
            return i, p
        end
    end
end

-- A rating as the corner stack would say it, or nil where there is nothing
-- honest to say. Still placing draws dim: ten games in it is a number that has
-- not settled, and reading it as firm is reading it wrong. The same rule the
-- pilot card follows, because it is the same number.
local function rating_line(o, team)
    local i, p = side_seat(o, team)
    if i == nil then return end
    local score = o.ratings and o.ratings[i]
    if not score then return end
    local placing = (p and p.tier) == "placing"
    return string.format("%d", math.floor(score + 0.5)), placing
end

-- How far the clock band reached last frame, so the drawer can ask whether it
-- is standing over it. Measured rather than guessed: the band is centered but
-- grows outward with the scores, the side names and their ratings, and a
-- half-width written down here would be a second copy of that arithmetic to
-- keep in step.
local band_l, band_r = 0, 0

local function match_clock(o, m, names, alone)
    if not m then return end
    -- Not under the drawer. The band is the one instrument the menu does not
    -- stand down for -- a player reading a panel still wants the clock -- and
    -- on a phone the drawer is the whole window, so it was drawn straight
    -- through the panel over it. It goes when the drawer's edge reaches it and
    -- is back when that edge has passed. See `M.drawer_over`.
    if band_r > band_l and M.drawer_over(band_l, band_r - band_l) then
        return
    end
    local left = m.left or 0
    local clock = duel_waiting(m) and "--:--"
        or string.format("%d:%02d", math.floor(left / 60), left % 60)
    local big, name_px, under_px = band_type()
    local top = band_top()
    -- Every line is placed off the clock's own box rather than off a baseline
    -- of its own, which is what keeps a side the same height as the clock
    -- beside it: the name sits at the top of that box, the number under it
    -- fills the rest, and the two are as tall together as the numerals in the
    -- middle. See `band_type`.
    local mid = top + big / 2
    local name_y = top + name_px / 2
    local under_y = top + big - under_px / 2

    -- The middle first, because everything else is placed off it.
    local dim = m.playing and 1 or 0.55
    txt(clock, F.w / 2, mid, big, pal.a(pal.INK, 0.95 * dim), "center")
    local half = text_w(clock, big) / 2
    -- What the band came to, walked outward from the clock as each side is
    -- laid down and read next frame by the question above.
    band_l, band_r = F.w / 2 - half, F.w / 2 + half
    local function reach(x)
        if x < band_l then band_l = x end
        if x > band_r then band_r = x end
    end
    -- The press that opens the board. The band is the control now: PLAYERS
    -- was a second key for the same panel and went with the redraw, so this
    -- box is the only way in that is not the keyboard.
    --
    -- Exactly the drawn band, no wider. Every published box swallows the
    -- press that lands in it, and on a mouse that press is the gun, so a
    -- generous target here would be a strip across the top of the arena that
    -- eats a shot whenever the cursor happens to be resting on it. A finger
    -- gets the near-miss growth `M.pick` gives every control, and costs
    -- nothing: a phone fires from the pads.
    --
    -- Nothing to press while the menu is up. The band keeps drawing under a
    -- drawer it does not reach, since a player reading a page still wants the
    -- clock, but the board it opens is not drawn then, and a control whose
    -- panel cannot appear is a press that does nothing anybody can see.
    local function press()
        if alone then return end
        local x0, x1 = band_l, band_r
        hit(x0 - 6 * F.scale, top - 4 * F.scale,
            x1 - x0 + 12 * F.scale, big + 8 * F.scale, "details")
    end

    -- A rival search is not a scored life, and it is not a named one either:
    -- the room has not chosen who is across the arena yet, so both sides would
    -- be last fight's. The clock alone until it has.
    if duel_waiting(m) then
        press()
        return
    end

    -- What a side is, which is the one thing the two games do not share.
    --
    -- A team game's side is a team: its name over what it has scored, which is
    -- the pair a player checks the clock to find out about. A duel's side is a
    -- person: their call sign over their rating, and no score at all, because
    -- first-to-one has nothing to say until it is over, and the board behind
    -- the band says it better: which fight, won or lost, and how long it
    -- took.
    local duel = m.duel ~= nil
    local mine = view_team
    local sides = {}
    for team, n in pairs(m.score or {}) do
        sides[#sides + 1] = {team = team, n = n}
    end
    table.sort(sides, function(a, b)
        if (a.team == mine) ~= (b.team == mine) then return a.team == mine end
        return a.team < b.team
    end)
    -- How much room a name has, which is the tighter of the row's two ends
    -- rather than each end's own.
    --
    -- The two ends are not the same width and never were: the way into the
    -- menu is a small key and the dial is a square a third of a phone across.
    -- Asking each side against the end it happens to face therefore dropped
    -- the right name at widths where the left one still drew, which reads as
    -- a fault rather than as a band running out of room, and an upright phone
    -- hit it every match once the dial came up into the corner and took the
    -- right end back. One measure for both sides means two names of a size
    -- go together.
    --
    -- Two names of very different lengths still part company, and should: a
    -- name that will not fit is a name that will not fit. What this stops is
    -- the same name fitting on one side of the clock and not the other.
    local gap = (M.compact and 14 or 22) * F.scale
    local room = math.min(
        F.w / 2 - half - gap - TOP.chip_right,
        TOP.row_right() - (F.w / 2 + half + gap)) - KEY_GAP * F.scale
    for i, side in ipairs(sides) do
        local ours = side.team == mine
        local col = pal.a(ours and pal.FRIEND or pal.ENEMY, 0.95 * dim)
        local label = (names and names[side.team]) or ""
        -- A side's name is a label and wears the interface's own case; a
        -- pilot's is quoted, the way the roster and the plate on their hull
        -- quote it. Which of the two this is decides the case.
        local quoted = false
        local under, faint = tostring(side.n), false
        if duel then
            -- The seat rather than the side. One pilot is one side here, so
            -- the name over the number is a person's, and a rating nobody has
            -- settled yet reads dim for the same reason it does on the card:
            -- ten games in it is a number that has not stopped moving.
            local _, p = side_seat(o, side.team)
            if p and p.name ~= "" then label, quoted = p.name, true end
            local rated, placing = rating_line(o, side.team)
            under, faint = rated or "--", placing or not rated
        end
        -- Right-aligned against the clock on the left of it and left-aligned
        -- on the right, so both lines of a side run away from the middle and
        -- the numbers that matter sit against the numerals they are read with.
        --
        -- And only as far as the row lets it. The band is centered and grows
        -- with whatever the sides are called, and what it grows toward at
        -- each end is an instrument: the way into the menu on the left, the
        -- dial on the right. A name with nowhere to go is dropped, the way
        -- the ending's bar drops one that will not fit its share. The number
        -- under it always draws: it is the reading, and it is four characters.
        local edge, pivot
        if i == 1 then
            edge = F.w / 2 - half - gap
            pivot = "right"
        else
            edge = F.w / 2 + half + gap
            pivot = nil
        end
        if label ~= "" and text_w(label, name_px) > room then label = "" end
        local wide = math.max(label ~= "" and text_w(label, name_px) or 0,
                              text_w(under, under_px))
        reach(i == 1 and edge - wide or edge + wide)
        if label ~= "" then
            txt(label, edge, name_y, name_px, pal.a(col, 0.85 * dim), pivot,
                nil, quoted)
        end
        txt(under, edge, under_y, under_px,
            faint and pal.a(pal.DIM, 0.8 * dim) or col, pivot)
    end
    press()
    -- Nothing under it while a match is being played: the clock is counting
    -- down and a word saying "match" beneath it is the interface reading its
    -- own label back. The intermission does need saying, because a clock
    -- counting down to something a player cannot see is a question.
    -- Only when the ending is not up. The card says the same thing at its
    -- foot, with room for it, and two of them at once is the interface
    -- answering a question nobody asked twice.
    if match_ended(m) and alone then
        txt("NEXT MATCH IN", F.w / 2, band_bottom() + 8 * F.scale,
            (M.compact and 9 or 11) * F.scale, pal.a(pal.DIM, 0.8), "center")
    end
end

-- What the room has to say, under the band that carries everything else.
--
-- This was a sentence across the middle of the screen in the largest type on
-- it, and it said things the instruments already said: which rung had just
-- been cleared, what the next one is, how long the streak is. All three are
-- on the board behind the band now, a press away. The two that are not, that
-- the clock has run out and the next death settles it and that the rival went
-- away mid-life, are what is left for this to carry.
--
-- So it is drawn the size of a label rather than the size of a headline, in
-- the register every other instrument uses, under the band and out of the
-- fight. See `Ladder::banner` on the server for what stopped being sent.
local function match_note(o, m)
    local line = o.banner
    if not line or line == "" then return end
    -- Not while the ending is up. The podium is the room's own account of the
    -- match that just finished and this slot is where the band says what the
    -- clock is counting down to, so a line here would be a third statement
    -- laid over the second. The banner used to be drawn after the ending's
    -- early return, which is the same rule written as an accident of order.
    if match_ended(m) then return end
    if band_r > band_l and M.drawer_over(band_l, band_r - band_l) then
        return
    end
    -- In ink rather than in the warning color. The lines left, an opponent
    -- who left mid-fight and a clock that has run out, would wear red well
    -- enough, but the lag notice under this one is the red one and two reds in
    -- a column would stop meaning anything.
    local px = (M.compact and 9 or 11) * F.scale
    txt(line, F.w / 2, band_bottom() + 8 * F.scale, px,
        pal.a(pal.INK, 0.9), "center")
end

-- The ending: the board, with a head and a foot.
--
-- There was a page here. It carried a title, a score bar, both rosters, six
-- phrase chips, a countdown with a drain bar beside it and a share key the
-- width of the measure, and most of that was the scoreboard's own content a
-- second time now that the board is one press off the band. So the ending
-- stopped being a page. At the whistle the board comes up whether or not
-- anybody asked for it, and grows a line saying who took the match, a bar
-- under that, and a foot with the countdown and one key. Decision 68.
--
-- One layout at every window size. The measure and the type change, and on an
-- upright phone the block hugs the foot of the screen so the key on it lands
-- under a thumb; nothing else about the arrangement moves.

-- How long a phrase stands on somebody's row once one arrives.
--
-- Nothing on this client sends one any more: the six chips at the foot of the
-- old card were the only way to, and they were the widest thing on it. The
-- wire, the roster's own line and this clock are the spine of the feature and
-- stay, so the key that replaces the chips is a key rather than a rebuild.
-- The arena counts a phrase out against it.
M.SAY_LIFE = 4.0

-- One table for everything the ending owns, rather than a local apiece: this
-- chunk is close to the two hundred a Lua main function may declare, and a
-- coherent group on a table is one of them however many pieces it holds. See
-- upvalues_test.
--
-- `W` is what the ending may spend on its column, wider than the 340 the band
-- opens mid-match because a roster row is a name and five numbers and the
-- ending owns the window rather than a corner of it. `CHROME` is what a run
-- section costs before any leg is drawn.
--
-- `ZOOM` is how much larger the whole block draws than the instruments
-- around it. The ending borrowed the board's own type, sized to sit in a
-- corner of a live fight, and at the whistle that read as a footnote: the
-- one thing on screen, set in the smallest type on it. The block is one
-- drawing, so it is grown as one, the way a pinch would grow it, rather
-- than by reweighing every size on it against its neighbors. A window too
-- short for the full zoom takes what it has room for instead, and never
-- less than the old size.
local END = {W = 720, CHROME = 38, ZOOM = 1.45}

-- What the ending is currently zoomed by, for the one reader outside this
-- file: a finger dragging the roster is turned into rows by `M.row_pitch`,
-- and a row on the ending is this much taller than a row anywhere else.
-- Reset every frame by `M.begin` so it never outlives the board it measures.
M.podium_zoom = 1

-- The mark on the key that hands this match to somebody else: a tray with an
-- arrow leaving it. Every phone puts this glyph on that control, and a mark
-- somebody already knows is worth more here than one of our own: the key says
-- what it does in words, and the mark is what finds it at a glance.
function END.share_mark(cx, cy, r, col)
    local line = pen(r * 1.5, 0.15)
    -- The arrow, from inside the tray and out over its rim.
    F.layer:seg(cx, ry(cy - r * 0.75), cx, ry(cy + r * 0.28), line, col)
    F.layer:seg(cx - r * 0.39, ry(cy - r * 0.36), cx, ry(cy - r * 0.75),
                line, col)
    F.layer:seg(cx + r * 0.39, ry(cy - r * 0.36), cx, ry(cy - r * 0.75),
                line, col)
    -- The tray, open where the arrow passes through it.
    local ty, by = cy - r * 0.08, cy + r * 0.75
    for _, side in ipairs({-1, 1}) do
        F.layer:seg(cx + side * r * 0.43, ry(ty), cx + side * r * 0.68, ry(ty),
                    line, col)
        F.layer:seg(cx + side * r * 0.68, ry(ty), cx + side * r * 0.68, ry(by),
                    line, col)
    end
    F.layer:seg(cx - r * 0.68, ry(by), cx + r * 0.68, ry(by), line, col)
end

-- Which side took it, what the ending calls that, and in what color. A draw is
-- a real result at three minutes and says so, rather than a winner being named
-- by tie-break.
function END.result(o, m, names)
    local best, best_at, drawn = -1, nil, false
    for team, n in pairs(m.score or {}) do
        if n > best then best, best_at, drawn = n, team, false
        elseif n == best then drawn = true end
    end
    local last = m.duel and (m.duel.log or {})[#(m.duel.log or {})]
    if last and last.rival ~= "" then
        -- A duel's result is about the two people in it, so it is said the way
        -- melee says one: a name and a verb. Both come off the fight the room
        -- just filed on this viewer's own card, which already knows which side
        -- of it they were on. Off the card rather than off the roster, because
        -- the seat across the arena is handed to somebody else within seconds
        -- of the whistle and a name read late is the wrong one.
        --
        -- A watcher's card is empty, so they fall through to the side naming
        -- below: nobody in the stands has a side in this.
        if last.result == "drawn" then
            return "drawn", pal.DIM, best_at, false
        end
        if last.result == "cleared" then
            return last.rival, pal.FRIEND, best_at, "beaten"
        end
        return last.rival, pal.ENEMY, best_at, "takes it"
    end
    if drawn or best_at == nil then return "drawn", pal.INK, nil, false end
    -- The side keeps the case it was supplied in; the verb is the interface
    -- speaking, so it is drawn separately by the caller.
    return (names and names[best_at]) or "a side",
           best_at == view_team and pal.FRIEND or pal.ENEMY, best_at, true
end

-- The score as one band: each side's name inside its own share of it, in the
-- ground's own near-black, with the points on the ends in the side's color.
-- The proportion is the fight and the colors are the sides, so the bar carries
-- the whole reading rather than labelling a stripe.
function END.band(m, names, x, y, w, sides, grow)
    -- The figures wear the ending's zoom; the bar between them keeps the
    -- interface's own size, and so do the names set inside it, since they
    -- have to fit the bar they are in. A band grown with the type read as a
    -- banner rather than a reading.
    local unz = M.podium_zoom or 1
    local px = (M.compact and 20 or 26) * F.scale
    local name_px = (M.compact and 10 or 12) * F.scale / unz
    local bar_h = (M.compact and 18 or 26) * F.scale / unz
    local gap = 14 * F.scale
    local l, r = sides[1], sides[2]
    local ls = (l ~= nil and m.score and m.score[l]) or 0
    local rs = (r ~= nil and m.score and m.score[r]) or 0
    local lcol = l == view_team and pal.FRIEND or pal.ENEMY
    local rcol = r == view_team and pal.FRIEND or pal.ENEMY
    local mid = y + bar_h / 2
    local bx = x + text_w(tostring(ls), px) + gap
    local bw = w - text_w(tostring(ls), px) - text_w(tostring(rs), px)
        - 2 * gap
    local part = (ls + rs) > 0 and ls / (ls + rs) or 0.5

    txt(tostring(ls), x, mid, px, pal.a(lcol, 1))
    txt(tostring(rs), x + w, mid, px, pal.a(rcol, 1), "right")
    -- The two sides meet where the score puts them, arriving rather than
    -- appearing. It is the only movement on the ending.
    rect(bx, y, bw, bar_h, pal.a(pal.DIM, 0.16))
    local lfill = bw * part * grow
    local rfill = bw * (1 - part) * grow
    rect(bx, y, lfill, bar_h, pal.a(lcol, 0.9))
    rect(bx + bw - rfill, y, rfill, bar_h, pal.a(rcol, 0.9))
    -- Each name against the outer end of its own share, so the two read
    -- outward from the middle the way the points beyond them do. Dropped
    -- rather than drawn over the far side when a rout leaves no room for it.
    local pad = 9 * F.scale
    local ground = pal.rgb(0x05070c, 0.95)
    local ln = (l ~= nil and names and names[l]) or ""
    local rn = (r ~= nil and names and names[r]) or ""
    if ln ~= "" and text_w(ln, name_px) + 2 * pad < lfill then
        txt(ln, bx + pad, mid, name_px, ground)
    end
    if rn ~= "" and text_w(rn, name_px) + 2 * pad < rfill then
        txt(rn, bx + bw - pad, mid, name_px, ground, "right")
    end
end

-- What the room is counting down to, and the one thing to do while it does.
--
-- The countdown is a reading rather than a draining bar: the bar was a second
-- clock beside the first, and the figure is the clock. INVITE FRIEND is the
-- act the share key performed, named for what a player wants out of it and
-- sized like a key rather than a banner. A guest keeps the key that claims
-- their pilot beside it, since the end of a match is when they are most
-- likely to want it.
function END.foot(o, m, x, y, w)
    local px = (M.compact and 10 or 12) * F.scale
    -- The countdown and its caption keep the interface's own size while the
    -- keys wear the zoom: the keys are the things to press, and the clock
    -- grown with them read as a headline about waiting.
    local unz = M.podium_zoom or 1
    local cap_px = px / unz
    local clock_px = (M.compact and 17 or 21) * F.scale / unz
    local key_h = KEY_H * F.scale
    local mid = y + key_h / 2
    lbl("next match", x, mid, pal.a(pal.DIM, 0.9), nil, cap_px)
    local at = x + text_w("NEXT MATCH", cap_px) + 12 * F.scale / unz
    local left = m.left or 0
    txt(string.format("%d:%02d", math.floor(left / 60), left % 60),
        at, mid, clock_px, pal.a(pal.INK, 0.92))

    -- Laid down from the right edge, so the countdown keeps the left however
    -- many keys this viewer has earned.
    local keys = {}
    if o.match_url then
        keys[#keys + 1] = {M.share_result == "copied" and "link copied"
                           or "invite friend", "share",
                           "vwshare:" .. o.match_url, END.share_mark}
    end
    if o.keep_pilot then
        keys[#keys + 1] = {"keep " .. (o.viewer_name or "pilot"), "keep_pilot"}
    end
    local right = x + w
    for i = #keys, 1, -1 do
        local a = keys[i]
        local mark = a[4]
        local mr = px * 0.72
        local lead = mark and (2 * mr + px * 0.7) or 0
        local kw = text_w(string.upper(a[1]), px) + lead + 26 * F.scale
        local kx = right - kw
        local col = i == 1 and pal.FRIEND or pal.RADAR_TILE
        local fill = i == 1 and 0.10 or 0.06
        local edge = i == 1 and 0.76 or 0.6
        if a[2] == "share" then
            -- The one act on the ending, so it breathes on the clock the
            -- PLAY NOW key breathes on, but under it: the ending's zoom
            -- already grows these keys, and PLAY NOW's full wash on top of
            -- that made the invite the loudest thing on the board. The
            -- floor still keeps the trough from reading as a key that
            -- stopped working. `F.now` is 0 under the test harness, which
            -- keeps the layout tests still.
            local breath = 0.5 + 0.5 * math.sin(F.now * 2.6)
            fill = 0.04 + 0.06 * breath
            edge = 0.50 + 0.26 * breath
        end
        key_box(kx, y, kw, key_h, pal.a(col, fill), pal.a(col, edge))
        local ink = pal.a(i == 1 and pal.FRIEND or pal.INK, 0.95)
        if mark then
            -- The mark and the words are centered together, so the key reads
            -- as one thing rather than as a label with something parked
            -- beside it.
            local lw = text_w(string.upper(a[1]), px)
            local lx = kx + kw / 2 - (lw + lead) / 2
            mark(lx + mr, mid, mr, ink)
            lbl(a[1], lx + lead, mid, ink, nil, px)
        else
            lbl(a[1], kx + kw / 2, mid, ink, "center", px)
        end
        hit(kx, y, kw, key_h, a[2])
        -- The browser lays a real anchor over this key: a copy to the
        -- clipboard has to happen inside a gesture the page itself saw, and a
        -- press routed through the engine is not one. The rectangle travels
        -- in page points, which is what the shell lays out in.
        if a[3] then
            M.link_dom = string.format("%.1f,%.1f,%.1f,%.1f,%s",
                kx / F.density, y / F.density, kw / F.density,
                key_h / F.density, a[3])
        end
        right = kx - KEY_GAP * F.scale
    end
    return key_h
end

local function podium(o, m, names)
    -- The room, ordered the way the ending reads it: the side that took the
    -- match first, whether or not it is this viewer's, and the best gun first
    -- inside each side. Set before the roster is filled, since the sort runs
    -- inside `refresh_players`.
    local said, said_col, winner, verbed = END.result(o, m, names)
    top_side = winner
    local n = refresh_players(o.pilots, o.watchers, nil, o.viewer_name)
    top_side = nil

    -- The measure and the block's own height, both known before anything is
    -- drawn: the ending is placed as one block and there is no second pass to
    -- discover how tall it came out. In a function because it runs twice,
    -- once at the interface's own scale and once at the ending's, and two
    -- copies of the same measurements is how the pads and their hit test
    -- drifted apart once already.
    local pad, room, w, x, title_px, bar_h, gap, head, h
    local function measure()
        pad = PAD * F.scale
        room = F.w - F.safe_l - F.safe_r - 2 * pad
        w = math.min(END.W * F.scale, room)
        x = F.safe_l + pad + (room - w) / 2
        title_px = (M.compact and 15 or 20) * F.scale
        -- Divided by the zoom, because the bar does not wear it: see
        -- `END.band`, which sizes the bar the same way.
        bar_h = (M.compact and 18 or 26) * F.scale / (M.podium_zoom or 1)
        gap = (M.compact and 10 or 14) * F.scale
        head = title_px + gap + bar_h
        h = head + gap + roster_h(n) + gap + KEY_H * F.scale
    end
    measure()

    -- The zoom, and everything after this line draws at it. Scaling F.scale
    -- itself is what grows the block as one drawing: every size below, the
    -- roster's rows and the foot's keys included, is a multiple of it, and
    -- the hit boxes are published off the same numbers, so the targets grow
    -- with the ink. Clamped by the window's height rather than its width,
    -- since the measure already gives way to a narrow screen on its own.
    local was_scale = F.scale
    local slack = F.h - 2 * (F.safe_t + 18 * F.scale)
    local zoom = math.max(1, math.min(END.ZOOM, slack / h))
    M.podium_zoom = zoom
    if zoom > 1 then
        F.scale = was_scale * zoom
        measure()
    end

    -- The zone's own sections under the roster, for the mode that keeps them:
    -- a duel's ending is about the run, so the board puts where the run stands
    -- and the fights that got it there under the two rows. Measured off the
    -- room the window has left rather than off where this block lands, since
    -- where it lands depends on how tall it comes out.
    --
    -- The readings are a fixed band and go up whenever there is a run at all,
    -- including one with no finished fight in it. The fights under them take
    -- whatever is left.
    local legs = 0
    if m.duel then
        local log = m.duel.log or {}
        h = h + gap + RUN.READ_H * F.scale
        local spare = F.h - 2 * (F.safe_t + 18 * F.scale) - h - 8 * F.scale
        legs = math.max(0, math.floor(spare / (LINE * F.scale)))
        legs = math.min(legs, #log, RUN.SHOWN)
        if legs > 0 then
            h = h + 8 * F.scale + legs * LINE * F.scale + 12 * F.scale
        end
    end

    -- Centered where there is room, and hugging the foot of an upright phone:
    -- the key at the bottom of this block is the only thing on it to press,
    -- and a thumb reaches the bottom of a tall screen rather than the middle.
    local y
    if M.compact and F.h > F.w then
        y = F.h - F.safe_b - 26 * F.scale - h
    else
        y = math.max(F.safe_t + 18 * F.scale, (F.h - h) / 2)
    end

    -- How long the ending has been up, so the bar arrives rather than appears.
    -- Latched off the frame clock rather than counted from the seconds the
    -- server sends, which are whole and would step the movement four times.
    if M.podium_at == nil then M.podium_at = F.now end
    local age = math.max(0, (F.now or 0) - (M.podium_at or 0))
    local grow = math.min(1, age / 0.34)
    grow = 1 - (1 - grow) * (1 - grow)

    -- The arena stays present under one scrim, and nothing else stands between
    -- it and the ending.
    rect(0, 0, F.w, F.h, pal.rgb(0x03050a, 0.8))

    -- Said once, over the bar it is the sentence for.
    local ty = y + title_px * 0.5
    if verbed then
        -- The name keeps its supplied case; the verb is the interface talking.
        -- A duel supplies its own, since one pilot beating another and one
        -- taking it off them are two results rather than one.
        local verb = verbed == true and "takes it" or verbed
        local word_gap = title_px * 0.42
        local nw = text_w(said, title_px, MENU_FONT, true)
        local total = nw + word_gap + text_w(verb, title_px, MENU_FONT)
        local hx = x + w / 2 - total / 2
        txt(said, hx, ty, title_px, pal.a(said_col, 1), nil, MENU_FONT, true)
        txt(verb, hx + nw + word_gap, ty, title_px, pal.a(pal.INK, 0.9), nil,
            MENU_FONT)
    else
        txt(said, x + w / 2, ty, title_px, pal.a(said_col, 1), "center",
            MENU_FONT)
    end

    -- The sides, winner first however the zone numbered them.
    local sides = {}
    for team in pairs(m.score or {}) do sides[#sides + 1] = team end
    table.sort(sides, function(a, b)
        local an = (m.score and m.score[a]) or 0
        local bn = (m.score and m.score[b]) or 0
        if an ~= bn then return an > bn end
        return a < b
    end)
    END.band(m, names, x, y + title_px + gap, w, sides, grow)

    -- And the board itself, in the column this block just laid out for it.
    board.x, board.w = x, w
    board.y = y + head + gap
    top_side = winner
    local bottom = scores(o.me, o.pilots, o.watchers, o.viewer_name, true)
    top_side = nil
    -- Both sections, or the readings alone where the window had no room for
    -- a fight under them. `legs` is what the measure above found space for.
    if m.duel then bottom = run_log(o, bottom, true, legs) end
    END.foot(o, m, x, bottom + gap, w)
    F.scale = was_scale
end

-- The landing: the game's name over the one key the screen exists for.
--
-- This is the whole of the front end now. Opening the client seats you in the
-- stands of a real room, so what a stranger meets is the game being played,
-- drawn by the same code that draws it to the people in it, with two things
-- laid over the bottom of it: what this is, and the way in.
--
-- The name goes directly over the key rather than into a corner or under the
-- clock. A stranger's eye ends on the pulsing thing at the foot of the screen,
-- and the name has to be where that look lands or it is a page that never says
-- what it is. Read as one object the two are a title and its button; read
-- apart they are a mark in a corner nobody looks at. Three placements were
-- drawn before this one was picked; see .design/spectator-landing.
--
-- Nothing else is added. The HUD a watcher already gets, corner keys and
-- clock and score and radar and feed, is the rest of this screen. See
-- decision 61 for why a spectator's view of a game beats a panel describing
-- one as a front page.
-- Where the front end's pieces sit. One function because the waiting screen
-- draws the same wordmark in the same place as the landing does, and a logo
-- that jumps when the room arrives is the reason this is shared rather than
-- written twice. The name stands clear of the stops even on the waiting
-- screen, where the stops are not drawn yet: when the room answers, the stops
-- and the key appear and nothing already on screen moves.
--
-- The window is asked two questions here, the way it is for the menu. Width
-- decides how wide the key is: edge to edge on a phone held upright, where a
-- centered key of fixed width leaves two margins of nothing either side of
-- the only control on the screen, and a measured key everywhere else, since a
-- monitor's width of PLAY NOW is a banner rather than a button.
--
-- Height decides the shape, and used to decide nothing. The column costs
-- about 260 points whatever the window is: a third of a monitor, and more
-- than half of a phone held sideways. The camera stands behind the hull the
-- stands are watching, so the middle of the screen is that hull, and on a
-- short window the column is drawn straight across it with the name landing
-- on the ship. Where it would climb that far the same pieces lie down into a
-- rail along the foot: three cells beside the key, one line high, with the
-- name over them. Height is what a window held sideways is short of and width
-- is what it has going spare, so the rail spends the one it has. Drawn as
-- direction B in `.design/start-flow`, where the column won the upright case.
local function landing_geom()
    local pts_w = F.w / math.max(F.density, 0.0001)
    local narrow = pts_w < 620
    local kh = (narrow and 50 or (M.compact and 44 or 54)) * F.scale
    local margin = 14 * F.scale
    local span = F.w - F.safe_l - F.safe_r - 2 * margin
    local kw = narrow and span or (M.compact and 240 or 320) * F.scale
    local mid = F.safe_l + (F.w - F.safe_l - F.safe_r) / 2
    -- `y` counts down from the top here, as it does everywhere in this file,
    -- so the foot of the screen is measured back from `F.h`.
    local foot = F.h - F.safe_b - (M.compact and 18 or 22) * F.scale
    local rgap = 8 * F.scale
    local size = (M.compact and 20 or 26) * F.scale
    -- `txt` sets a string on the middle of its line, so half the type goes
    -- back to put the baseline where it belongs above what it heads.
    local mgap = (M.compact and 16 or 20) * F.scale + size / 2
    local g = {narrow = narrow, size = size, kh = kh, kw = kw,
               kx = mid - kw / 2, ky = foot - kh, rgap = rgap,
               kpx = (narrow and 16 or (M.compact and 14 or 19)) * F.scale,
               mark_x = mid - M.wordmark_w(size) / 2, stops = {}}
    -- The column: three rows at the key's own width stacked over it, in the
    -- order you would say them. A finger gets the touch floor; a pointer gets
    -- a slimmer row and `M.pick` grows it when a finger arrives anyway.
    local rh = (narrow and 44 or (M.compact and 30 or 36)) * F.scale
    local top = g.ky - 12 * F.scale - 3 * rh - 2 * rgap
    -- Measured from the name's own top, which is the highest thing the
    -- landing draws, against the middle of the screen and a hull's clearance
    -- under it: the camera stands behind the hull the stands are watching, so
    -- the column stands only where it keeps off that hull and its call sign.
    if top - mgap - size / 2 >= F.h / 2 + 40 * F.scale then
        g.rh, g.mark_y = rh, top - mgap
        for i = 1, 3 do
            g.stops[i] = {x = g.kx, y = top + (i - 1) * (rh + rgap),
                          w = kw, h = rh}
        end
        return g
    end
    -- The rail. A cell carries its question over its answer rather than
    -- beside it, so three of them and the key fit one line; where that line
    -- is wider than the window, the cells take a line of their own over the
    -- key rather than shrinking past reading. A cell stands as tall as the
    -- key beside it, floored at what a thumb needs: a band drawn at two
    -- heights reads as a key with smaller apparatus parked next to it.
    local ch = math.max(44 * F.scale, kh)
    local cw = (M.compact and 120 or 140) * F.scale
    local band = 3 * cw + 2 * rgap + 14 * F.scale + kw
    g.rail, g.rh = true, ch
    local cx, cy
    if band <= span then
        cy = foot - ch
        cx, g.kx, g.ky = mid - band / 2, mid + band / 2 - kw,
                         cy + (ch - kh) / 2
    else
        cw = (span - 2 * rgap) / 3
        cx, cy = F.safe_l + margin, g.ky - 10 * F.scale - ch
    end
    g.mark_y = cy - mgap
    for i = 1, 3 do
        g.stops[i] = {x = cx + (i - 1) * (cw + rgap), y = cy, w = cw, h = ch}
    end
    return g
end

-- The name, where it sits whether or not there is a room to join yet.
local function landing_mark()
    local g = landing_geom()
    M.wordmark(g.mark_x, g.mark_y, g.size)
end

-- A stop's caret: the two strokes that say a press here opens downward into
-- a list, in the weight the rest of the chrome is drawn at.
local function land_caret(cx, cy, col)
    local k = 4 * F.scale
    F.layer:seg(cx - k, ry(cy - k * 0.6), cx, ry(cy + k * 0.6),
                1.3 * F.scale, col, true)
    F.layer:seg(cx, ry(cy + k * 0.6), cx + k, ry(cy - k * 0.6),
                1.3 * F.scale, col, true)
end

-- One stop of the landing: the question, the answer it currently holds and a
-- caret, in the same stroked rectangle every key here wears. `lit` is the
-- stop whose list is open.
--
-- A column row sets the question at its left edge and the answer at its
-- right. A rail cell has no width for the two side by side, so the question
-- goes over the answer the way a gauge's caption goes over its reading, and
-- an answer with no room left is cut at the cell's edge: a long call sign
-- walking into the next cell is worse than a call sign that says it is longer
-- than the cell.
--
-- `raw` says the answer is quoted rather than said: a call sign, a game's
-- name and a build's name all stand in the case they were given, where the
-- HUD would otherwise shout them. Sitting out is the one answer that is the
-- interface's own word and takes the interface's own case. See `txt`.
local function land_stop(x, y, w, h, label, value, action, lit, stacked, raw)
    -- Where a press would land, at the weight every row of the menu is lit
    -- at. Under the outline rather than over it: the edge is the brighter
    -- half of the same signal, and a wash laid over it would mute it.
    local hot = M.land_sel == action
    rect(x, y, w, h, pal.a(pal.BTN_BG, 0.6))
    if hot then rect(x, y, w, h, pal.a(pal.FRIEND, LIT.CURSOR)) end
    key_box(x, y, w, h, nil,
            (lit or hot) and pal.a(pal.FRIEND, 0.8)
                or pal.a(pal.RADAR_TILE, 0.75))
    local pad = 12 * F.scale
    local cx = x + w - pad - 3 * F.scale
    local px = (M.compact and 11 or 12) * F.scale
    if stacked then
        -- The caret rides the question's line rather than the answer's, so
        -- the answer has the cell's whole width to be read across. At the
        -- narrowest a cell gets there is barely room for a zone's name, and
        -- what would have paid for the caret is those last two letters.
        pad = 8 * F.scale
        lbl(label, x + pad, y + h * 0.33)
        land_caret(cx, y + h * 0.33, pal.a(pal.INK, 0.75))
        local kept = F.clip_r
        F.clip_r = x + w - pad
        txt(value or "", x + pad, y + h * 0.68, px, pal.a(pal.INK, 0.95),
            nil, nil, raw)
        F.clip_r = kept
    else
        lbl(label, x + pad, y + h / 2)
        land_caret(cx, y + h / 2, pal.a(pal.INK, 0.75))
        txt(value or "", cx - 11 * F.scale, y + h / 2, px,
            pal.a(pal.INK, 0.95), "right", nil, raw)
    end
    hit(x, y, w, h, action)
end

-- A stop's open list, upward over the glass so it never covers the key. Rows
-- wear the menu's own states from decision 72: the row the pointer rests on
-- washes at 0.18, the row you are already in at 0.07. Nearly opaque ground,
-- unlike the drawer's wash: two or three rows over a live fight have to be
-- read, not read through.
local function land_list(kx, kw, bottom, list, drh)
    local padv = 5 * F.scale
    local h = padv * 2
    for _, r in ipairs(list) do
        h = h + (r.rule and 9 * F.scale or drh)
    end
    local py = bottom - h
    rect(kx, py, kw, h, pal.a(pal.BG, 0.96))
    F.layer:frame(kx, ry(py, h), kw, h, 1.1 * F.scale,
                  pal.a(pal.RADAR_TILE, 0.85))
    local pad = 12 * F.scale
    local dpx = (M.compact and 11 or 12) * F.scale
    local y = py + padv
    for _, r in ipairs(list) do
        if r.rule then
            hrule(kx + pad, y + 4.5 * F.scale, kw - 2 * pad, 0.6)
            y = y + 9 * F.scale
        else
            local hov = not r.dim and M.land_sel == r.action
                and M.land_sel_value == r.value
            if hov then
                rect(kx, y, kw, drh, pal.a(pal.FRIEND, 0.18))
            elseif r.here then
                rect(kx, y, kw, drh, pal.a(pal.FRIEND, 0.07))
            end
            local col = r.dim and pal.a(pal.DIM, 0.8)
                or (r.here and pal.a(pal.FRIEND, 0.95))
                or pal.a(pal.INK, hov and 1 or 0.8)
            txt(r.label, kx + pad, y + drh / 2, dpx, col, nil, nil, r.raw)
            if r.note then
                txt(r.note, kx + kw - pad, y + drh / 2,
                    dpx - 2 * F.scale, pal.a(pal.DIM, 0.9), "right")
            end
            if not r.dim then
                hit(kx, y, kw, drh, r.action, r.value, nil, 1)
            end
            y = y + drh
        end
    end
end

-- The landing: the game's name and the column of stops over the one key the
-- screen exists for.
--
-- This is the whole of the front end now. Opening the client seats you in the
-- stands of a real room, so what a stranger meets is the game being played,
-- drawn by the same code that draws it to the people in it, with the choices
-- laid over the bottom of it in the order you would say them: what this is,
-- who you are, where you are going, what you arrive as, and the way in.
--
-- The stops exist because the drawer went undiscovered: a first visit met
-- PLAY NOW and a hamburger, deployed into whatever the stands were showing,
-- and never learned there was another game or another ship to be. Account
-- opens the drawer on the pilot page; zone and ship open lists in place, and
-- SPECTATE is the ship list's last row, exactly as the ship page has it.
-- Mocked in .design/start-flow, where the column won over a rail along the
-- foot and a line of pressable words.
--
-- Nothing else is added. The HUD a watcher already gets, corner keys and
-- clock and score and radar and feed, is the rest of this screen. See
-- decision 61 for why a spectator's view of a game beats a panel describing
-- one as a front page.
local function landing(land)
    local g = landing_geom()
    -- The key breathes on the same clock the on-air tally swells at, and the
    -- edge is floored well above dark so the trough never reads as a key that
    -- has stopped working. `F.now` is zero under the test harness, which is
    -- what keeps the layout tests still.
    local breath = 0.5 + 0.5 * math.sin(F.now * 2.6)
    -- Under a pointer the breath stops at the top of its own swell, which is
    -- the rule the menu's rows follow: the one thing moving on the screen
    -- should never be the thing you are already on. Standing still says
    -- little by itself, this being the one control out here that is lit to
    -- begin with, so the cursor's own field goes over that ground as well.
    local key_hot = M.land_sel == "play_now"
    local swell = key_hot and 1 or breath
    rect(g.kx, g.ky, g.kw, g.kh, pal.a(pal.FRIEND, 0.06 + 0.12 * swell))
    if key_hot then
        rect(g.kx, g.ky, g.kw, g.kh, pal.a(pal.FRIEND, LIT.CURSOR))
    end
    key_box(g.kx, g.ky, g.kw, g.kh, nil,
            pal.a(pal.FRIEND, 0.62 + 0.38 * swell))
    txt("PLAY NOW", g.kx + g.kw / 2, g.ky + g.kh / 2, g.kpx,
        pal.a(pal.INK, 1), "center")
    hit(g.kx, g.ky, g.kw, g.kh, "play_now")
    local mark_down = false
    if land then
        local acct_box, zone_box, ship_box =
            g.stops[1], g.stops[2], g.stops[3]
        -- The open list first, as rows and a height, because whatever it
        -- covers has to stand down: glyphs come from the gui and the gui
        -- draws over every mesh, so a stop drawn under the panel would read
        -- through it. Same rule the clock band follows under the drawer.
        local open, list, from = M.land_open, nil, nil
        local drh = g.narrow and 40 * F.scale or 30 * F.scale
        if open == "zone" and land.zones then
            list, from = {}, zone_box
            for _, z in ipairs(land.zones) do
                -- Every game is named rather than described, so every row
                -- here is quoted.
                list[#list + 1] = {label = z.label, value = z.zone,
                                   action = "land_pick_zone", here = z.here,
                                   dim = not z.live, note = z.format,
                                   raw = true}
            end
        elseif open == "ship" and land.ships then
            list, from = {}, ship_box
            for _, s in ipairs(land.ships) do
                -- Sitting out is the list's last answer, held apart from the
                -- builds by a rule: it is a different kind of thing to be.
                if s.value == "spectate" then list[#list + 1] = {rule = true} end
                list[#list + 1] = {label = s.label, value = s.value,
                                   action = "land_pick_ship", here = s.here,
                                   raw = s.value ~= "spectate"}
            end
        else
            open = nil
        end
        -- Where the panel stands and how far up it reaches. It hangs off the
        -- stop it belongs to, at the key's width down the column and at its
        -- own cell's on the rail, held to a measure a row can be read at and
        -- kept inside the window.
        local ptop, lx, lw, bottom = nil, g.kx, g.kw, nil
        if list then
            local h = 10 * F.scale
            for _, r in ipairs(list) do
                h = h + (r.rule and 9 * F.scale or drh)
            end
            if g.rail then
                lw = math.max(from.w, (M.compact and 200 or 220) * F.scale)
                lx = math.min(from.x,
                              F.w - F.safe_r - 14 * F.scale - lw)
                lx = math.max(lx, F.safe_l + 14 * F.scale)
            end
            bottom = from.y - 6 * F.scale
            ptop = bottom - h
        end
        -- The stops the panel does not cover. Down the column a list opens
        -- upward from its own stop, so the stops above the open one are the
        -- covered ones; along the rail it opens over the fight and covers no
        -- stop at all, the three of them standing side by side.
        if g.rail or (open ~= "zone" and open ~= "ship") then
            land_stop(acct_box.x, acct_box.y, acct_box.w, acct_box.h,
                      "account", land.name, "land_account", false, g.rail,
                      true)
        end
        if g.rail or open ~= "ship" then
            land_stop(zone_box.x, zone_box.y, zone_box.w, zone_box.h,
                      "zone", land.zone, "land_zone", open == "zone", g.rail,
                      true)
        end
        land_stop(ship_box.x, ship_box.y, ship_box.w, ship_box.h,
                  "ship", land.ship, "land_ship", open == "ship", g.rail,
                  not land.watching)
        -- The list itself, its rows published above the stops (`pri` 1) and
        -- a screen-wide backdrop behind everything (`pri` -1), so a press
        -- outside it puts it away instead of pulling a trigger.
        if list then
            hit(0, 0, F.w, F.h, "land_shut", nil, nil, -1)
            land_list(lx, lw, bottom, list, drh)
            -- And the name stands down when the panel climbs into it.
            mark_down = ptop < g.mark_y + g.size
        end
    end
    if not mark_down then landing_mark() end
end

-- The landing's controls in the order they are said, which is not the order
-- they are published in: the key is drawn before the stops that stand over
-- it. An arrow means the direction it points, and saying order is top to
-- bottom down the column and left to right along the rail, so one list
-- answers both shapes.
local LAND_WALK = {"land_account", "land_zone", "land_ship", "play_now"}

-- What a keyboard walks out here, read off the boxes the last frame
-- published rather than off a second list of controls kept beside the
-- drawing. What is on the screen is a fact the drawing has already decided: a
-- stop the open list stands over is not drawn, and a game the fleet is not
-- serving publishes no box because it cannot be picked.
--
-- With a list open the walk is that list, and only it: the stop the list
-- hangs off, which is the way back out, and then its rows in the order they
-- are drawn, which is the order they were published in.
function M.land_walk()
    local out = {}
    if M.land_open == "zone" or M.land_open == "ship" then
        local stop = "land_" .. M.land_open
        local pick = "land_pick_" .. M.land_open
        for _, r in ipairs(M.hits) do
            if r.action == stop or r.action == pick then out[#out + 1] = r end
        end
        return out
    end
    for _, action in ipairs(LAND_WALK) do
        for _, r in ipairs(M.hits) do
            if r.action == action then
                out[#out + 1] = r
                break
            end
        end
    end
    return out
end

-- Where the cursor is standing in that walk, or nil for nowhere. Nowhere is
-- an ordinary answer: nothing is lit until a hand puts something there, and
-- a control can go off the screen under a hand that is not looking.
local function land_at(walk)
    for i, r in ipairs(walk) do
        if r.action == M.land_sel and r.value == M.land_sel_value then
            return i
        end
    end
    return nil
end

-- An arrow, `dir` being 1 for down and -1 for up. Answers whether it moved,
-- so the caller can make the noise a key makes.
--
-- The ends wrap, the way every list in the menu wraps, so nothing on this
-- screen is more than two presses away. A first press with nothing lit lands
-- on the end the arrow came from.
function M.land_step(dir)
    local walk = M.land_walk()
    if #walk == 0 then return false end
    local at = land_at(walk)
    if at then
        at = (at - 1 + dir) % #walk + 1
    else
        at = dir > 0 and 1 or #walk
    end
    M.land_sel, M.land_sel_value = walk[at].action, walk[at].value
    return true
end

-- What enter presses: whatever the cursor is standing on, and the key itself
-- when nothing is lit. There is one thing this screen exists for, and a
-- keyboard that had to walk to it would be a front page nobody can start the
-- game from.
--
-- Nothing at all when a list is open and the cursor is not in it, which is
-- the one case where that fallback would be wrong: a press meant for a row
-- would deploy instead of picking one.
function M.land_go()
    local walk = M.land_walk()
    local at = land_at(walk)
    if at then return walk[at].action, walk[at].value end
    if M.land_open then return nil end
    return "play_now", nil
end

-- Before a room answers: the landing with everything that needs a room taken
-- off it.
--
-- Not a screen of its own. It is the same starfield, the same name in the same
-- place, and the same MENU in the same corner, so when the stands arrive the
-- only thing that happens is that the room and the key appear. Nothing already
-- on screen moves. The instruments a watcher gets are all about a room this
-- client has not found yet, so the radar and the roster are simply absent
-- rather than drawn empty.
--
-- What used to be here was a lockup centered in the window, which was the
-- loading screen held one beat longer and read as a third screen between the
-- loader and the game. The logo moved when the game arrived, which is the one
-- thing the hand-off should never do.
function M.waiting(note)
    landing_mark()
    -- The one control, drawn here rather than through the corner row, which
    -- carries a roster this screen has not got.
    --
    -- And not while the drawer is standing over it, which is the same rule
    -- the clock band and the dial corner follow: a panel's ground is a wash
    -- rather than a curtain, so anything drawn under it reads through, and a
    -- key ghosting under the panel that replaced it is the interface drawn
    -- twice. It showed up on a zone change, where the room drops for a frame
    -- or two and this screen is what is behind the open menu.
    local x, y = F.safe_l + PAD * F.scale, F.safe_t + PAD * F.scale
    local w = KEY_H * F.scale
    if not M.compact then
        w = BURGER.w * F.scale + 3 * KEY_PAD * F.scale
            + text_w("MENU", key_size())
    end
    if M.drawer_over(x, w) then return end
    burger_cap(x, y, F.menu_up)
    hit(x, y, w, KEY_H * F.scale, "open")
    -- And a line where the key will be, but only when something has gone
    -- wrong. Waiting says nothing: the wordmark on a starfield is what this
    -- game looks like and a caption narrating a normal two second wait is
    -- noise. A fleet that is down is different, and silence there would be a
    -- client that looks like it is still trying.
    if note and note ~= "" then
        local g = landing_geom()
        txt(note, F.w / 2, g.ky + g.kh / 2, (M.compact and 11 or 13) * F.scale,
            pal.a(pal.DIM, 0.9), "center", MENU_FONT, true)
    end
end

function M.hud(o)
    F.case = "upper"
    local ending = match_ended(o.match)
    -- Each whistle gets its own entrance. Once play or a rival search resumes,
    -- release the old timestamp so the next result does not inherit a fully
    -- grown podium from the first match of the session.
    if not ending then
        M.podium_at = nil
        M.podium_artifact = nil
    elseif o.match.artifact ~= nil
       and M.podium_artifact ~= o.match.artifact then
        -- Network updates continue when rendering pauses. Keying the entrance
        -- to the filed result lets a second whistle animate even when no live
        -- frame was drawn between the two results.
        M.podium_at = nil
        M.podium_artifact = o.match.artifact
    end
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
    -- An open board is the same case: it is the thing being read, so the fight
    -- and every instrument around it recede while it is up. See the wash under
    -- the board below, which is the mesh half of the same move.
    local reading = M.details and not o.menu_open and not ending
    F.text_dim = (ending or o.menu_open or M.room_ask or reading) and 0.34 or 1

    -- On a touchscreen the bottom of the screen belongs to the thumbs. The
    -- stick sits in the bottom left corner and the pads in the bottom right,
    -- which is exactly where the status panel and the control hint were, so
    -- everything else moves up out of the way of them.
    local lift = M.touching and 150 * F.scale or 0

    -- One panel in this column at a time. The rooms list stands in the
    -- scoreboard's slot, so whichever is up is the one drawn.
    M.zone_name = o.zone or ""
    -- The rooms list keeps the left column, under the key that opens it. The
    -- board is its own column now, under the band, so the two no longer stand
    -- in one slot and neither has to put the other away.
    rooms_panel(o.rooms, o.room)
    -- Where that column starts, before anything in it draws. Under the band,
    -- and under the room's note as well when there is one, since a line of
    -- text between them is a line the list would otherwise be drawn over.
    local note = (o.banner and o.banner ~= "") and 16 * F.scale or 0
    set_board(note)
    -- The wash the board is read over. Laid down before the board's own panel
    -- and after nothing else, so the fight behind it goes back and the panel
    -- in front of it does not. Not under an open drawer: that is a panel over
    -- this one, and dimming for a panel nobody can see is a screen that went
    -- dark for no reason.
    if reading then rect(0, 0, F.w, F.h, pal.a(pal.BG, 0.55)) end
    -- The board itself, at full strength over that wash: it is the thing
    -- being read, and the dim above is what everything else on the screen is
    -- wearing while it is up.
    if not (o.menu_open or ending) then
        local behind = F.text_dim
        if reading then F.text_dim = 1 end
        local top = scores(me, o.pilots, o.watchers, o.viewer_name)
        -- And under the roster, for a mode whose roster is two rows and whose
        -- real scoreboard is the run behind them.
        top = run_log(o, top)
        -- And under that, the pilot a row was pressed on. It belongs to this
        -- column and is drawn with it, rather than after the instruments: all
        -- three are one panel with one wash behind them.
        inspect(o, top)
        F.text_dim = behind
    end
    -- Names hanging off ships, but not under the menu. Glyphs come from the
    -- gui and the gui draws over every mesh, so nothing the menu lays down
    -- can cover them: a panel with six pilots' names scattered through it
    -- reads as a fault rather than as depth. The instruments stay -- your
    -- bars, the dial, the feed -- because you can still be shot while you
    -- are reading, and those are what say so.
    -- The ending is text over a card and lands in the same trap, so it takes
    -- the plates down with it for the twenty five seconds it is up.
    if not o.menu_open and not ending then nameplates(o) end
    -- One corner, one instrument. The map is the radar pulled back to the
    -- whole thousand tiles, so it stands where the radar stands rather than
    -- somewhere else with the radar still lit beside it.
    -- The dial's corner, and nothing in it while the drawer is over it. On a
    -- phone the drawer is the whole window, so the radar was drawn straight
    -- through the panel standing on top of it. On a monitor
    -- the drawer is 390 points of 1440 and never reaches this corner, so
    -- nothing there changes: the question is the overlap rather than whether a
    -- menu is open. See `M.drawer_over`.
    local dial_x = dial()
    if not M.drawer_over(dial_x, F.w - dial_x) then
        if M.map then overview(me) else radar(o.cam_x, o.cam_y, me) end
    end
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
    -- Nor at the ending: everybody is benched, so what the triggers do and
    -- what is left to spend are facts about a fight that is over, drawn
    -- through the board's own scrim.
    if not (o.watch or M.touching or ending) then
        status(me, o.charges, lift)
    end
    -- A watcher is never the subject, so the tally can only be about a pilot
    -- who is flying, and the two never contend for the slot.
    -- The room chip only where there is a room to move to. `rooms` is the
    -- zone's whole list and the directory already drops it to nil below two,
    -- which is the one place that decision is made; this reads it rather than
    -- making it again from a number.
    local several = o.rooms and #o.rooms > 1
    -- Not under an open menu. The column is docked to this corner and covers
    -- the row outright, so drawing it puts a ghost of MENU under the panel's
    -- own head: the way back in is the lit stop on the column's foot row, and
    -- the way out is the x on its head.
    if not o.menu_open then
        menu_button(o.on_air and not o.watch, o.watch,
                    several and o.room or nil, o.landing)
    end
    vignette(o.hurt or 0)
    -- After the stack, because it is hung off the rows the stack published,
    -- and after the tint so a hurt frame does not wash out the words.
    if not (o.watch or M.touching or ending) then
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
    -- The band and the room's line under it read at full strength over the
    -- wash as well. They are the instrument the board belongs to rather than
    -- something it covers, and the clock is the one reading a player wants
    -- whatever else is up.
    if reading then F.text_dim = 1 end
    -- Not while the ending is up. The ending's own head carries the score and
    -- its foot carries the clock, so a band across the top would be both of
    -- them a second time, over a block that already owns the window.
    --
    -- Unless the menu is over the ending, which is the one case where neither
    -- of those is on screen: the drawer covers the block, and a player reading
    -- a page still wants to know how long they have.
    if not ending or o.menu_open then
        match_clock(o, o.match, o.side_names, o.menu_open)
        match_note(o, o.match)
    end
    -- The two big centered lines are the only interface that sits where the
    -- menu does. The panels can share the screen with it; these cannot.
    if o.menu_open then return end
    -- The ending, while the room counts down to the next one. Same place, same
    -- reason: it is the thing being read.
    if ending then
        F.text_dim = 1
        podium(o, o.match, o.side_names)
    end
    -- The name and the way in, over the fight a stranger has just landed in
    -- the stands of. Through the ending as well as through play: a match
    -- ending is not a reason to take the one key on the screen away.
    --
    -- Drawn after it rather than before, which is the whole of why this is not
    -- one line up. The ending washes the entire window, so a key laid down
    -- first spends the twenty five seconds between matches buried under it:
    -- visible to a hit test, invisible to a person.
    if o.landing then landing(o.land) end
    if ending then return end
    -- Over the arena and under nothing, since it is the thing being read. The
    -- game carries on behind it: nothing is paused here, and a player who
    -- opens this in a fight can still be shot while they read.
    if M.help then
        help_table()
    elseif M.help_prompt then
        help_prompt()
    end
    flag_strip(me)
    -- The room's own line is drawn with the band it hangs off, above. See
    -- `match_note`.
    if o.lag_notice and o.lag_notice ~= "" then
        txt(o.lag_notice, F.w / 2, band_bottom() + 26 * F.scale,
            (M.compact and 10 or 13) * F.scale,
            pal.a(pal.HURT, 0.95), "center")
    end
    if not o.watch and sim.ship_alive(me) == 0 then
        -- Down because the room has nobody to fight yet is not down because
        -- somebody shot you, and the two are the same benched hull from here.
        -- The room is the only thing that can tell them apart, and it does:
        -- see `duel_waiting`.
        if duel_waiting(o.match) then
            rival_note()
        else
            txt("D E S T R O Y E D", F.w / 2, F.h * 0.46,
                (M.compact and 15 or 22) * F.scale, pal.ENEMY, "center")
        end
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
-- grid of seven hulls at one size is drawn in one weight whatever each of them
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
local function thumb(cx, cy, cls, col, scale, turn, detail)
    local h = world.HULLS[cls + 1]
    if not h then return end
    local k = vertical_turn(turn)
    local function trace(src, width, c, open)
        local pts = {}
        for i = 1, #src, 2 do
            pts[i] = cx + src[i] * scale * k
            pts[i + 1] = ry(cy - (src[i + 1] - h.mid) * scale)
        end
        F.layer:outline(pts, width, c, not open)
    end
    -- The interior, where the drawing is big enough to hold one. At thumb
    -- sizes the plates read as noise inside the silhouette; at the landing's
    -- hero size a bare outline reads as a decal, and the plates and panel
    -- lines are what make it the machine you are about to be sitting in.
    -- Panel ink, like the arena draws them, so the team color stays on the
    -- silhouette.
    if detail then
        local ink = pal.a(pal.PANEL_INK, 0.5)
        for _, loop in ipairs(h.plates or {}) do
            trace(loop, 0.9 * F.scale, ink)
        end
        for _, line in ipairs(h.lines or {}) do
            trace(line, 0.9 * F.scale, pal.a(pal.PANEL_INK, 0.38), true)
        end
    end
    trace(h.poly, HULL_PEN * F.scale, col)
    if h.canopy then trace(h.canopy, 1.0 * F.scale, pal.a(col, 0.55)) end
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

-- One circle, in the three states a slot's ladder has.
--
-- Everything on this page is a circle and the fill says what it is: solid is
-- a point equipped, a ring in the slot's own color is a step this account
-- owns and has not spent a point on, and a dim grey ring is a rung the arena
-- has that the account does not. One mark with three fills is a grammar a
-- pilot learns once; the page used to carry pips, chips, squares and a
-- diamond, which is four marks for one idea. See .design/hangar.
--
-- The ring carries its own alpha over whatever the caller handed in, rather
-- than replacing it: every page passes a solid color and gets 0.8 as before,
-- and the one caller that washes a whole row down (a charge whose key is shut)
-- has its rings wash with the rest of it instead of staying bright.
function pages.dot(cx, cy, r, kind, col)
    local sides = 14
    if kind == "on" then
        F.layer:disc(cx, ry(cy), r, sides, col)
    elseif kind == "ring" then
        F.layer:ring(cx, ry(cy), r - 0.5 * F.scale, 1.1 * F.scale, sides,
                     pal.a(col, 0.8 * (col[4] or 1)))
    else
        F.layer:ring(cx, ry(cy), r - 0.5 * F.scale, 1.0 * F.scale, sides,
                     pal.a(pal.DIM, 0.5))
    end
end

-- A slot's ladder, at whatever size it is handed: filled to what is equipped,
-- ringed to what is owned, dim to where the arena's own ladder stops.
function pages.ladder(r, x, cy, step, rad)
    local held, owned = r.choice or 0, r.choices or 0
    local top = math.max(r.arena_max or owned, owned)
    local col = r.tint_col or pal.FRIEND
    for k = 1, top do
        local kind = (k <= held and "on") or (k <= owned and "ring") or "dim"
        pages.dot(x + (k - 1) * step, cy, rad, kind, col)
    end
    return x + math.max(top, 1) * step
end

-- The ship page: every slot this arena has, and the thirty points on it.
--
-- One page, where there were two. The shelf was a tab of its own drawing the
-- same slots in the same order for the other question, and a pilot who could
-- not turn something on had to leave to find out why. The row says why: a
-- dim circle is a rung that is not yours, and where it is for sale the row
-- ends in its price. Pressing the name, or the dim part of the ladder, slides
-- the reading in over the page.
--
-- It carries no head. The wordmark and the call sign come off the top of the
-- column here, because this is the longest page in the menu and the band it
-- puts on that line, the build's name and the points, is what a builder needs
-- on screen. See .design/hangar and docs/design/match-game.md.
function pages.kit(v, x, y, w, h, focused)
    local band, slots, flair, save = {}, {}, {}, nil
    for _, r in ipairs(v.rows or {}) do
        if r.group == "band" then band[#band + 1] = r
        elseif r.group == "save" then save = r
        elseif r.group == "flair" then flair[#flair + 1] = r
        else slots[#slots + 1] = r end
    end
    local live = not v.kit_preview
    local function cursor(r) return live and r.index == v.sel end

    -- --- the band
    --
    -- The build's name as a key, and the points as a meter. Both open a page
    -- of their own, which is the one gesture this screen has: press a thing
    -- to read about it.
    local BAND = 48 * F.scale
    local mid = y + BAND / 2
    -- At the column's own edge. It used to start clear of the x, which this
    -- page drew on the band's line while it carried no head of its own; the
    -- head is on every page now and the x is up there with it.
    local bx = x
    if band[1] then
        local r = band[1]
        local px = TYPE.BODY * F.scale
        local label = cased(r.label or "custom")
        local kw = text_w(label, px, MENU_FONT) + 26 * F.scale
        local kh = 26 * F.scale
        local hot = cursor(r)
        key_box(bx, mid - kh / 2, kw, kh,
                hot and pal.a(pal.FRIEND, LIT.CURSOR) or nil,
                pal.a(pal.FRIEND, hot and (focused and 1 or 0.55) or 0.5))
        txt(label, bx + kw / 2, mid, px, pal.INK,
            "center", MENU_FONT)
        if live then hit(bx, mid - kh / 2, kw, kh, "stage", r.index) end
        -- Whether the thirty points in hand are still what that name says.
        -- Nothing at all while the two agree, which is the ordinary case and
        -- needs no word for it.
        if v.profile and v.profile.state then
            lbl(v.profile.state, bx + kw + 10 * F.scale, mid,
                pal.MUTE)
        end
    end
    if band[2] and v.kit_spent then
        local r = band[2]
        local total = v.kit_total or 30
        local left = math.max(0, total - v.kit_spent)
        local hot = cursor(r)
        local right = x + w
        -- What is left, which is the figure a builder mid-edit is actually
        -- after: "28 / 30" is a ratio to subtract before it says anything.
        local fig = tostring(left) .. " left"
        local fw = text_w(fig, 11 * F.scale)
        local bw = 52 * F.scale
        local by = mid + 5 * F.scale
        txt(fig, right, by, TYPE.BODY * F.scale,
            pal.INK, "right")
        lbl("points", right, mid - 9 * F.scale, pal.MUTE,
            "right")
        local mx = right - fw - 8 * F.scale - bw
        rect(mx, by - 2 * F.scale, bw, 4 * F.scale, pal.a(pal.DIM, 0.25))
        rect(mx, by - 2 * F.scale, bw * (v.kit_spent / math.max(total, 1)),
             4 * F.scale, pal.a(pal.FRIEND, 0.85))
        -- The meter is furniture in the band rather than a row of the list, so
        -- it lights its own shape; the weight is the one every cursor wears.
        if hot then
            wash(mx - 8 * F.scale, mid - 18 * F.scale,
                 right - mx + 16 * F.scale, 34 * F.scale,
                 pal.a(pal.FRIEND, LIT.CURSOR))
        end
        if live then
            hit(mx - 8 * F.scale, y, right - mx + 12 * F.scale, BAND,
                "stage", r.index)
        end
    end
    hrule(x, y + BAND, w)

    -- --- the ladders, under it
    local kit_top = y + BAND + 6 * F.scale
    -- The save key, where there is one, is furniture rather than a row of the
    -- list: it stands over the stops and the ladders scroll under it.
    local foot = save and 54 * F.scale or 0
    local room = h - BAND - 6 * F.scale - foot
    local cy = kit_top - M.page_scroll
    local srow = 26 * F.scale
    local function seen(a, b) return a >= kit_top and b <= kit_top + room end
    local cur_at = nil
    local function note_cursor(r)
        if cursor(r) then cur_at = cy - kit_top + M.page_scroll end
    end

    local function rule(label)
        cy = cy + 6 * F.scale
        if seen(cy - 2 * F.scale, cy + 2 * F.scale) then hrule(x, cy, w) end
        cy = cy + 16 * F.scale
        if label then
            if seen(cy - 8 * F.scale, cy + 4 * F.scale) then lbl(label, x, cy) end
            cy = cy + 24 * F.scale
        end
    end

    -- Where the circles begin, the same on every row of the page so the
    -- ladders line up under each other whatever their names are worth.
    local NAMEW = 112 * F.scale
    local STEP = 13 * F.scale
    local RAD = 4.4 * F.scale

    local function slot_row(r)
        note_cursor(r)
        if not seen(cy - srow / 2, cy + srow / 2) then
            cy = cy + srow
            return
        end
        local hot = cursor(r)
        if hot then LIT.field(cy - srow / 2, srow, LIT.CURSOR) end
        txt(r.label, x, cy, TYPE.BODY * F.scale,
            pal.INK, nil, MENU_FONT)
        -- The ladder. Every circle this account owns takes a press of its
        -- own, so a tap on the fourth asks for four; the one it is already on
        -- takes the point back. The dim ones are not controls: a press there
        -- is the same question the name asks, and it opens the reading.
        local px = x + NAMEW
        local held, owned = r.choice or 0, r.choices or 0
        local col = r.tint_col or pal.FRIEND
        local top = math.max(r.arena_max or owned, owned)
        for k = 1, top do
            local cx = px + (k - 1) * STEP
            local kind = (k <= held and "on") or (k <= owned and "ring")
                         or "dim"
            pages.dot(cx, cy, RAD, kind, col)
            if live and k <= owned then
                hit(cx - STEP / 2, cy - srow / 2, STEP, srow,
                    "kit_at", r.index, k)
            end
        end
        px = px + math.max(top, 1) * STEP
        -- What it is set to, where the count is a word rather than a number:
        -- a rung reads L1, L2, L3, because that is what a level is called
        -- everywhere else, and a spray of two is two rounds.
        if r.group == "levels" then
            txt("L" .. (held + 1), px + 10 * F.scale, cy, TYPE.BODY * F.scale,
                pal.INK)
        elseif r.ladder then
            txt(tostring(held + 1), px + 10 * F.scale, cy, TYPE.BODY * F.scale,
                pal.INK)
        end
        -- Which of the two keys throws a carried charge, in a box beside it.
        if r.charge_slot then
            -- In a column of its own rather than after however many circles
            -- this charge happens to hold, so two of them read as one control
            -- at one indent, and never closer than a gap to a ladder a zone
            -- has made longer than six.
            local bx2 = math.max(px + 12 * F.scale,
                                 x + NAMEW + 6 * STEP + 16 * F.scale)
            local bh = 18 * F.scale
            -- What is left before the price at the end of the row. The key it
            -- is thrown with is the part that gives: which of the two slots
            -- this is is the fact, and the key is how it is spent.
            local box_room = x + w - (r.price and 52 * F.scale or 0) - bx2
            local word = "charge " .. r.charge_slot
                .. (r.on_key and (" (" .. r.on_key .. ")") or "")
            if text_w(word, LBL_PX * F.scale) + 18 * F.scale > box_room then
                word = "charge " .. r.charge_slot
            end
            local bw = text_w(word, LBL_PX * F.scale) + 18 * F.scale
            key_box(bx2, cy - bh / 2, bw, bh,
                    pal.a(pal.CHARGE_COL, hot and 0.16 or 0.07),
                    pal.a(pal.CHARGE_COL, hot and 0.9 or 0.5))
            lbl(word, bx2 + bw / 2, cy,
                pal.CHARGE_COL, "center")
            if live then hit(bx2, cy - bh / 2, bw, bh, "charge_swap") end
        end
        -- And what the next rung costs, on the end of the row. The only
        -- commerce on this page: a price always wears the rivet mark and the
        -- shop's gold, and the wallet it comes out of is on the reading.
        if r.price then
            local can = r.afford ~= false
            pages.priced(r.price, x + w, cy, TYPE.BODY * F.scale,
                         pal.a(can and pal.CHARGE_COL or pal.DIM,
                               can and 0.95 or 0.55), "right")
        end
        -- The name and everything past the ladder ask the same question,
        -- and it is the one the row cannot answer itself. Published last, so
        -- the circles this account owns keep the presses that land on them,
        -- and across the whole field, so a press that landed where the row lit
        -- up is a press that landed on the row.
        if live then
            local hx, _, hw = M.drawer_span()
            hit(hx, cy - srow / 2, hw, srow, "read_row", r.index)
        end
        cy = cy + srow
    end

    local function flair_row(r)
        note_cursor(r)
        if not seen(cy - srow / 2, cy + srow / 2) then
            cy = cy + srow
            return
        end
        local hot = cursor(r)
        if hot then LIT.field(cy - srow / 2, srow, LIT.CURSOR) end
        txt(r.label, x, cy, TYPE.BODY * F.scale,
            pal.INK, nil, MENU_FONT)
        local vx = x + NAMEW + 14 * F.scale
        local vw = text_w(r.detail or "", 12.5 * F.scale, MENU_FONT)
        txt(r.detail or "", vx, cy, TYPE.BODY * F.scale,
            pal.FRIEND, nil, MENU_FONT)
        local dirs = {{-1, vx - 16 * F.scale}, {1, vx + vw + 14 * F.scale}}
        local action = r.ship and "carousel" or "wake"
        for _, d in ipairs(dirs) do
            local dir, px2 = d[1], d[2]
            local warm = hot or (r.ship and v.carousel_hot == dir)
            F.layer:tri(px2 + dir * 4 * F.scale, ry(cy),
                        px2 - dir * 3.5 * F.scale, ry(cy - 5 * F.scale),
                        px2 - dir * 3.5 * F.scale, ry(cy + 5 * F.scale),
                        pal.a(pal.FRIEND, warm and 0.9 or 0.55))
            if live then
                hit(px2 - 11 * F.scale, cy - srow / 2, 22 * F.scale, srow,
                    action, dir)
            end
        end
        if r.choices and r.choices > 1 then
            lbl((r.choice or 1) .. " of " .. r.choices, x + w, cy,
                pal.MUTE, "right")
        end
        if live then
            local hx, _, hw = M.drawer_span()
            hit(hx, cy - srow / 2, hw, srow, "stage", r.index)
        end
        cy = cy + srow
    end

    -- The slots, in the sections the rows name: flight, then each trigger
    -- with its own level at the head of it, then the charges. A section is
    -- the whole story of one weapon, which is what put the levels in with the
    -- add-ons that ride them.
    local was = nil
    for _, r in ipairs(slots) do
        if r.sect ~= was then rule(r.sect) was = r.sect end
        slot_row(r)
    end
    if #flair > 0 then
        rule("flair")
        for _, r in ipairs(flair) do flair_row(r) end
    end

    -- Follow the arrows. A frame late, since the offsets only exist once the
    -- rows have walked; the page settles on the very next draw. A cursor in
    -- the band is at the top of the column by definition: the band does not
    -- scroll.
    for _, r in ipairs(band) do
        if cursor(r) then cur_at = 0 end
    end
    if save and cursor(save) then cur_at = nil end
    if live then
        follow_cursor(cur_at and (cur_at - srow / 2) or nil,
                      srow + 8 * F.scale, room, focused)
    end
    M.page_extent = (cy + M.page_scroll - kit_top) + BAND + 16 * F.scale
    M.page_room = h - foot

    -- --- the key at the foot
    --
    -- There only while the thirty points in hand differ from the build they
    -- came from, which is what makes its presence the answer to "is there
    -- anything to keep here".
    if save then
        local kh = 40 * F.scale
        local ky = y + h - kh
        local hot = cursor(save)
        key_box(x, ky, w, kh,
                pal.a(pal.FRIEND, hot and LIT.CURSOR or 0.10),
                pal.a(pal.FRIEND, hot and (focused and 1 or 0.7) or 0.85))
        txt("save", x + w / 2, ky + kh / 2, TYPE.BODY * F.scale,
            pal.INK, "center", MENU_FONT)
        if live then hit(x, ky, w, kh, "stage", save.index) end
    end

    -- A thumb down the edge where there is more than fits.
    if M.page_extent > h - foot then
        local track = room
        local bar = math.max(30 * F.scale, track * track / M.page_extent)
        local at = (M.page_scroll / math.max(1, M.page_extent - (h - foot)))
                   * (track - bar)
        local sx2 = x + w - 3 * F.scale
        rect(sx2, kit_top, 3 * F.scale, track, pal.a(pal.DIM, 0.12))
        rect(sx2, kit_top + at, 3 * F.scale, bar, pal.a(pal.RADAR_TILE, 0.8))
    end
end

-- The way back out of a page that slid in over another: a chevron and the
-- name of what is behind it, on the line the band stands on.
--
-- Under the x rather than beside it: the head is on every page, so the way
-- back out of a reading is the first thing on the page under it. A swipe
-- right does it too; see `M.drawer`.
function pages.back_row(v, x, y, w, place)
    local mid = y + 24 * F.scale
    local bx = x
    F.layer:tri(bx, ry(mid), bx + 7 * F.scale, ry(mid - 5.5 * F.scale),
                bx + 7 * F.scale, ry(mid + 5.5 * F.scale),
                pal.MUTE)
    lbl(place, bx + 15 * F.scale, mid, pal.MUTE)
    hit(bx - 10 * F.scale, y, 130 * F.scale, 48 * F.scale, "back")
    hrule(x, y + 48 * F.scale, w)
    return y + 48 * F.scale + 8 * F.scale
end

-- One slot, read: what it is, what it does in a fight, how far its ladder
-- runs, and where a rung is still for sale, what it costs and what the wallet
-- holds.
--
-- This is the shelf's own reading pane, at page size, reached from the row
-- that raised the question instead of from a tab of its own. Everything a
-- pilot could not learn on the ship page is here, and nothing else in the
-- menu spends rivets.
function pages.slot(v, x, y, w, h, focused)
    local r = v.item
    if not r then return end
    local at = pages.back_row(v, x, y, w, "ship")
    local kind
    if r.group == "flight" then kind = "flight stat"
    elseif r.group == "levels" then
        kind = (r.trigger == 0 and "gun" or "bomb") .. " ladder"
    elseif r.group == "weapons" then
        kind = (r.trigger == 0 and "gun" or "bomb") .. " add-on"
    else kind = "charge" end
    lbl(kind, x, at + 16 * F.scale)
    txt(r.label or r.sold or "", x, at + 44 * F.scale, TYPE.PAGE * F.scale,
        pal.INK, nil, MENU_FONT)
    -- The thing working, at toy scale. A page can name a fuse and price a
    -- fuse, and neither tells a browsing pilot what a fuse is for.
    local by = at + 64 * F.scale
    local bh = 118 * F.scale
    bracket(x, by, w, bh, pal.a(pal.RADAR_TILE, 0.8))
    pages.range(r, x, by, w, bh)
    local ly = by + bh + 26 * F.scale
    -- What it does, in the client's own words.
    if r.teach then
        for _, line in ipairs(wrapped(r.teach, TYPE.BODY * F.scale, w,
                                      MENU_FONT)) do
            txt(line, x, ly, TYPE.BODY * F.scale, pal.READ,
                nil, MENU_FONT, true)
            ly = ly + pages.NOTE_LINE * F.scale
        end
        ly = ly + 12 * F.scale
    end
    -- The ladder again, at reading size, and what each part of it is.
    local held, owned = r.choice or 0, r.choices or 0
    local top = math.max(r.arena_max or owned, owned)
    if top > 0 then
        pages.ladder({choice = held, choices = owned, arena_max = top,
                      tint_col = r.tint_col}, x + 6 * F.scale, ly,
                     17 * F.scale, 5.5 * F.scale)
        local said = {}
        local base = r.base or 0
        if base > 0 then said[#said + 1] = base .. " dealt to everybody" end
        if owned > base then said[#said + 1] = (owned - base) .. " bought" end
        if held > 0 then said[#said + 1] = held .. " equipped" end
        if top > owned then said[#said + 1] = (top - owned) .. " to climb" end
        lbl(table.concat(said, " \194\183 "), x, ly + 24 * F.scale,
            pal.MUTE)
        ly = ly + 48 * F.scale
    end
    -- The deal, and the wallet it comes out of. This is the one page in the
    -- menu that names either.
    if r.price then
        local can = r.afford ~= false
        local used = pages.priced(r.price, x, ly, 15 * F.scale,
                                  pal.a(can and pal.CHARGE_COL or pal.DIM,
                                        can and 0.95 or 0.55))
        lbl("buys the next rung", x + used + 14 * F.scale, ly,
            pal.MUTE)
        -- The wallet at the far end of the same line, its word measured off
        -- the figure rather than guessed at: a four-figure balance is wider
        -- than a two-figure one and the label has to start clear of it.
        local purse = pages.priced(v.wallet or 0, x + w, ly, 12 * F.scale,
                                   pal.a(pal.CHARGE_COL, 0.9), "right")
        lbl("wallet", x + w - purse - 8 * F.scale, ly, pal.MUTE,
            "right")
        ly = ly + 26 * F.scale
    elseif top > 0 then
        lbl(owned > (r.base or 0) and "yours, all the way up"
            or "dealt to everybody", x, ly, pal.MUTE)
        ly = ly + 26 * F.scale
    end
    M.page_extent = (ly - y) + 90 * F.scale
    M.page_room = h
    -- The keys: the buy where there is something to buy, and the charge
    -- swap where there are two kinds to trade. Each is a row, so the arrows
    -- reach them and the page's own enter presses the first.
    local ky = y + h - 46 * F.scale
    for i = #(v.rows or {}), 1, -1 do
        local row = v.rows[i]
        local kh = 44 * F.scale
        local hot = focused and row.index == v.sel
        local buy = row.act == "buy"
        local can = (not buy) or (r.afford ~= false)
        local col = buy and pal.CHARGE_COL or pal.FRIEND
        key_box(x, ky, w, kh,
                pal.a(col, (hot and 0.18) or (can and 0.10 or 0.04)),
                pal.a(can and col or pal.DIM, hot and 1 or (can and 0.9 or 0.5)))
        txt(buy and "buy" or (row.label or ""), x + w / 2, ky + kh / 2,
            TYPE.BODY * F.scale, can and pal.INK or pal.MUTE, "center",
            MENU_FONT)
        hit(x, ky, w, kh, buy and "buy_go" or "stage",
            buy and nil or row.index)
        ky = ky - kh - 10 * F.scale
    end
end

-- The library, behind the name in the band: every build this pilot can fly,
-- with the one the kit in hand actually is lit, and the two things there are
-- to do to the list.
--
-- Two keys and no more. Saving is at the foot of the ship page, where the kit
-- that earned it is, and renaming went with it: a build is named when it is
-- made, and a name that wants changing is a new build and a delete.
function pages.builds(v, x, y, w, h, focused)
    local at = pages.back_row(v, x, y, w, "ship")
    lbl("builds", x, at + 16 * F.scale)
    local list, keys = {}, {}
    for _, r in ipairs(v.rows or {}) do
        if r.group == "keys" then keys[#keys + 1] = r else list[#list + 1] = r end
    end
    local ry0 = at + 34 * F.scale
    local ROW = 30 * F.scale
    for _, r in ipairs(list) do
        local hot = focused and r.index == v.sel
        -- The one the kit in hand actually is, in the color this menu uses
        -- for yours. It is where you already are, so it wears the standing
        -- field and breathes; the cursor outranks it.
        local loaded = (r.choice or 0) > 0
        if hot then
            LIT.field(ry0, ROW, LIT.CURSOR)
        elseif loaded then
            LIT.field(ry0, ROW, LIT.HERE)
        end
        txt(r.label or "", x, ry0 + ROW / 2, TYPE.ROW * F.scale,
            loaded and pal.a(pal.FRIEND, hot and 1 or LIT.breath())
                or pal.INK,
            nil, MENU_FONT, true)
        if r.starter then
            lbl("starter", x + w, ry0 + ROW / 2, pal.MUTE, "right")
        end
        local hx, _, hw = M.drawer_span()
        hit(hx, ry0, hw, ROW, "stage", r.index)
        ry0 = ry0 + ROW
    end
    -- The two keys, side by side under the last name.
    local ky = ry0 + 16 * F.scale
    local kh = 32 * F.scale
    local kw = (w - 10 * F.scale) / 2
    for i, r in ipairs(keys) do
        local kx = x + (i - 1) * (kw + 10 * F.scale)
        local hot = focused and r.index == v.sel
        local dim = r.dim
        key_box(kx, ky, kw, kh,
                (not dim) and (hot and pal.a(pal.FRIEND, LIT.CURSOR)
                               or (i == 1 and pal.a(pal.FRIEND, 0.08) or nil))
                or nil,
                pal.a(pal.FRIEND, dim and 0.2 or (hot and 1 or 0.55)))
        txt(r.label or "", kx + kw / 2, ky + kh / 2, TYPE.BODY * F.scale,
            dim and pal.MUTE or pal.INK, "center",
            MENU_FONT)
        hit(kx, ky, kw, kh, "stage", r.index)
    end
    M.page_extent = (ky + kh - y) + 20 * F.scale
    M.page_room = h
end

-- Naming one, a slide further right: the thirty points in hand under a name
-- of the pilot's own.
function pages.newbuild(v, x, y, w, h, focused)
    local at = pages.back_row(v, x, y, w, "builds")
    local nb = v.new or {}
    lbl("builds", x, at + 16 * F.scale)
    txt("new build", x, at + 44 * F.scale, TYPE.PAGE * F.scale,
        pal.INK, nil, MENU_FONT)
    local ly = at + 64 * F.scale
    for _, line in ipairs(wrapped(
            "keeps the thirty points in hand under a name of yours.",
            TYPE.BODY * F.scale, w, MENU_FONT)) do
        txt(line, x, ly, TYPE.BODY * F.scale, pal.READ, nil, MENU_FONT,
            true)
        ly = ly + pages.NOTE_LINE * F.scale
    end
    ly = ly + 16 * F.scale
    pages.field(x, ly, w, nb.name or "", "a name for this build", nb.on,
                "new_field")
    ly = ly + pages.FIELD_TALL * F.scale + 8 * F.scale
    lbl("a name for this build", x, ly + 4 * F.scale)
    -- The key, which is what a page for making one thing ends in.
    local kh = 44 * F.scale
    local ky = ly + 28 * F.scale
    local can = (nb.name or "") ~= ""
    local row = (v.rows or {})[1]
    local hot = focused and row ~= nil and row.index == v.sel
    key_box(x, ky, w, kh,
            pal.a(pal.FRIEND, can and (hot and 0.18 or 0.10) or 0.04),
            pal.a(can and pal.FRIEND or pal.DIM, can and 0.9 or 0.5))
    txt("create", x + w / 2, ky + kh / 2, TYPE.BODY * F.scale,
        can and pal.INK or pal.MUTE, "center", MENU_FONT)
    hit(x, ky, w, kh, "create_build")
    if hot then
        key_box(x, ky, w, kh, nil, pal.a(pal.FRIEND, 1))
    end
    M.page_extent = (ky + kh - y) + 20 * F.scale
    M.page_room = h
end

-- What the thirty points are, behind the meter, and what a circle says.
--
-- The page teaches its own grammar where the grammar is asked about, which is
-- the same gesture every other reading here answers: press the thing, read
-- about the thing.
function pages.points(v, x, y, w, h)
    local at = pages.back_row(v, x, y, w, "ship")
    lbl("points", x, at + 16 * F.scale)
    txt("thirty points", x, at + 44 * F.scale, TYPE.PAGE * F.scale,
        pal.INK, nil, MENU_FONT)
    local ly = at + 64 * F.scale
    for _, line in ipairs(wrapped(
            "every ship is a spend of the same thirty points, whoever flies "
            .. "it and whatever the account owns. press a circle to spend a "
            .. "point there; press the one it is on to take the point back.",
            TYPE.BODY * F.scale, w)) do
        txt(line, x, ly, TYPE.BODY * F.scale, pal.READ, nil, nil,
            true)
        ly = ly + pages.NOTE_LINE * F.scale
    end
    ly = ly + 22 * F.scale
    -- The meter again, at reading size, with both figures spelled out.
    local total = v.kit_total or 30
    local spent = v.kit_spent or 0
    local fig = spent .. " spent \194\183 " .. math.max(0, total - spent)
                .. " left"
    local fw = text_w(fig, 12 * F.scale)
    local bw = w - fw - 14 * F.scale
    rect(x, ly - 3 * F.scale, bw, 6 * F.scale, pal.a(pal.DIM, 0.25))
    rect(x, ly - 3 * F.scale, bw * (spent / math.max(total, 1)), 6 * F.scale,
         pal.a(pal.FRIEND, 0.85))
    txt(fig, x + w, ly, TYPE.BODY * F.scale, pal.INK, "right")
    ly = ly + 30 * F.scale
    lbl("what a circle says", x, ly)
    ly = ly + 22 * F.scale
    for _, s in ipairs({
            {"on", pal.FRIEND, "equipped: one of your thirty"},
            {"ring", pal.FRIEND, "owned, waiting for a point"},
            {"dim", pal.DIM, "not yours yet: its price sits on the row"}}) do
        pages.dot(x + 6 * F.scale, ly, 5.5 * F.scale, s[1], s[2])
        txt(s[3], x + 24 * F.scale, ly, TYPE.BODY * F.scale,
            pal.READ, nil, nil, true)
        ly = ly + 26 * F.scale
    end
    M.page_extent = (ly - y) + 20 * F.scale
    M.page_room = h
end

-- The friends page: a field you type a call sign into, the adds waiting on an
-- answer, your friends, and one key out to somebody who has never played.
--
-- Two rows and two grammars. A received add asks a question, so it carries
-- its name over what it did and the two keys that answer it. A friend is not
-- asking anything, so the row is a dot, a name, and the game they are in:
-- solid where they are flying, hollow where they are not, which says on and
-- off twice over and reads without color. What can be done with a friend is
-- on the card the row raises, which is where five inputs always had to find
-- it, and where a join names the game it would put you in.
--
-- The field is pinned and the sections scroll under it, the way the ship
-- page's band stays over its kit. Whole rows only, and nothing is drawn over
-- a partial one: type comes from the gui and draws over every mesh this file
-- lays down, so a row that has slid under the field cannot be covered.
--
-- See docs/design/friends.md.

-- How big the dot beside a friend is, and how tall a band pinned at the foot
-- of the column stands. Both hang off `pages` beside FIELD_TALL rather than
-- standing as locals of their own: this file is at Lua's ceiling of two
-- hundred locals in its main chunk, and a page's own measurements belong to
-- the page anyway.
--
-- One height for both bands: the invite here, and the guest warning the menu
-- itself draws on the same line of the same column. Where a guest opens this
-- page the two are stacked, and two heights would read as two kinds of thing.
pages.ON_R = 4
pages.BAND_H = 46

-- The way out of a roster that can only hold people already here: a band that
-- hands the game's own address to whatever the device shares with, which on a
-- phone is the share sheet and on a desktop is the clipboard. It is pinned at
-- the foot rather than scrolled to, because a page with three friends on it
-- has nothing else down there and a page with forty would bury it.
--
-- The guest warning's shape, in the friends page's color: a band standing on
-- the rail, edge to edge of the column, two lines of words and the whole of it
-- the press. It was a labeled key floating over a rule with the page's ground
-- under it, which read as the last row of a list that had run out rather than
-- as the foot of the panel. One band grammar for the two things this menu
-- pins at a foot, and the color says which of them you are looking at: gold
-- warns, green offers.
--
-- The lines say what the press is for and never how it travels: the sheet
-- decides that, and a key promising a text message on a machine that copies a
-- link is a key that lied.
function pages.invite_banner(v, y)
    local bx, _, bw = M.drawer_span()
    local bh = pages.BAND_H * F.scale
    local hot = v.invite_hot == true
    rect(bx, y, bw, bh, pal.a(pal.FRIEND, hot and 0.14 or 0.08))
    F.layer:seg(bx, ry(y), bx + bw, ry(y), F.scale,
                pal.a(pal.FRIEND, 0.5), true)
    local margin = MENU_PAD * F.scale
    txt("Get somebody you know into the game.", bx + margin,
        y + 16 * F.scale, TYPE.BODY * F.scale, pal.INK, nil,
        MENU_FONT)
    -- The second line flips once the browser says the link went somewhere,
    -- which is the only acknowledgment a copy gets: nothing else on screen
    -- moves.
    local copied = M.share_result == "copied"
    txt(copied and "Link copied." or "Press here to share an invite.",
        bx + margin, y + 33 * F.scale, TYPE.BODY * F.scale, pal.READ, nil,
        MENU_FONT)
    hit(bx, y, bw, bh, "invite")
    -- The browser lays a real anchor over it: a share sheet and a clipboard
    -- write both have to happen inside a gesture the page itself saw, and a
    -- press routed through the engine is not one. The rectangle travels in
    -- page points, which is what the shell lays out in.
    M.link_dom = string.format("%.1f,%.1f,%.1f,%.1f,%s",
        bx / F.density, y / F.density, bw / F.density, bh / F.density,
        "vwshare:" .. v.invite)
end

function pages.friends(v, x, y, w, h, focused)
    local a = v.add or {}
    -- One question, asked of the room rather than of the device: whether a
    -- name, its line and two keys fit across one row. Around 470 points they
    -- stop fitting, and a received add goes to two lines with the keys
    -- sharing the second. A friend's row is one line at every width.
    local packed = w < 470 * F.scale
    local bh = pages.FIELD_TALL * F.scale
    local kh = 26 * F.scale
    -- How tall a section head is, and therefore how far into one its label
    -- sits. Read up here because the box at the top of the page is a section
    -- head like any other on it: the same label on the same line, with the
    -- head's rule left to the one already drawn under the bar.
    local SECT = pages.SECT * F.scale

    -- One button. Returns its left edge, so a row can lay them out from the
    -- right and stop where it stops.
    -- --- the field, pinned at the top
    --
    -- Its label stands where every other label on this page stands, and the
    -- box under it where a section's first row goes. It used to sit eight
    -- points down, which is a page whose first line is higher than its second
    -- section's for no reason either of them could give.
    lbl("add friend", x, y + SECT * pages.SECT_LABEL, pal.MUTE)
    local fy = y + SECT + bh / 2
    local aw = text_w("add", 12 * F.scale) + 26 * F.scale
    local fw = math.min(300 * F.scale, w - aw - 12 * F.scale)
    local fx = x
    local by = fy - bh / 2
    local typed = a.name or ""
    pages.field(fx, by, fw, typed, "a call sign", a.on, "add_box", "add_wipe")
    row_button(fx + fw + 10 * F.scale + aw, fy, kh, "add", true,
           v.add_hot == true, "add_go")
    -- What the last press came to, under the field, and the hint where there
    -- is room beside it. The hint is what stops somebody typing half a name
    -- and waiting: this looks up a call sign whole and offers nothing.
    local note = a.note or ""
    if note ~= "" then
        txt(note, x, fy + bh / 2 + 12 * F.scale, TYPE.BODY * F.scale,
            a.bad and pal.ENEMY or pal.FRIEND)
    elseif not packed then
        txt("enter their call sign exactly",
            x + fw + aw + 24 * F.scale, fy, TYPE.BODY * F.scale, pal.READ,
            nil, MENU_FONT)
    end
    local BAND = SECT + bh + 24 * F.scale

    -- --- what the box found, under it
    --
    -- A call sign is a word and three digits, and typing one exactly is the
    -- kind of small task nobody should have to be careful about. So the
    -- meta-layer answers a prefix and the names land here, under the box, and
    -- pressing one adds that pilot by number: what you pressed is what is
    -- added even where two call signs open the same way.
    --
    -- Drawn over the sections rather than pushing them down. A list that
    -- appears and disappears as you type would walk the whole page up and
    -- down with it, and the rows underneath are not what anybody is looking
    -- at while the box has a caret in it.
    local hits = a.found or {}
    if #hits > 0 then
        local rh = 28 * F.scale
        local ly = fy + bh / 2 + 6 * F.scale
        local lw = fw
        rect(fx, ly, lw, #hits * rh, pal.rgb(0x070b12, 0.96))
        bracket(fx, ly, lw, #hits * rh, pal.a(pal.RADAR_TILE, 0.7),
                10 * F.scale)
        for i, p in ipairs(hits) do
            local ry0 = ly + (i - 1) * rh
            -- Lit by a pointer resting on it or by the arrows standing on
            -- it, which are the same fact about the same row.
            local on = v.found_hot == i or a.sel == i
            -- The list hangs off a field rather than filling the drawer, so
            -- it lights its own shape at the cursor's weight.
            if on then
                rect(fx, ry0, lw, rh, pal.a(pal.FRIEND, LIT.CURSOR))
            end
            txt(p.name or "?", fx + 11 * F.scale, ry0 + rh / 2, TYPE.ROW * F.scale,
                pal.INK, nil, MENU_FONT, true)
            hit(fx, ry0, lw, rh, "found", i)
        end
        -- The band grows to clear them, so the first section is not drawn
        -- underneath a name somebody is about to press.
        BAND = BAND + #hits * rh + 6 * F.scale
    end

    -- --- the sections, scrolling under it, and the band under them
    local top = y + BAND
    -- The page's own floor: everything below it belongs to the invite band,
    -- which is pinned there whatever the list does. No address to hand out
    -- means no band and no floor: the page has the whole panel, rather than
    -- fifty points of nothing under a band that could not do anything.
    local foot = (v.invite and v.invite ~= "")
        and pages.BAND_H * F.scale or 0
    local floor = y + h - foot
    -- Two heights, because the two rows say different amounts. A received add
    -- carries a line about when it arrived and two keys; a friend carries a
    -- dot, a name and a game.
    local function row_h(r)
        if r.state == "asked" then return (packed and 52 or 44) * F.scale end
        return 44 * F.scale
    end
    -- Laid out unscrolled and drawn shifted, so the height this page came to
    -- is a number and not that number minus wherever the finger left it.
    local at = top
    -- The head above a section is as tall as the sentence it carries, so the
    -- walk that finds the cursor has to wrap the same words the drawing does.
    local function head_h(r)
        if not r.sect then return 0 end
        local said = r.sect_line
            and wrapped(cased(r.sect_line), TYPE.BODY * F.scale,
                        w - 10 * F.scale, MENU_FONT)
            or nil
        return SECT + (said and (#said * 15 * F.scale + 4 * F.scale) or 0)
    end
    local tall = 0
    do
        local walk, cur = 0, nil
        for i, r in ipairs(v.rows or {}) do
            walk = walk + head_h(r)
            if i == v.sel and not a.on then cur = walk end
            walk = walk + row_h(r)
            tall = math.max(tall, row_h(r))
        end
        follow_cursor(cur, tall, floor - top, focused)
    end
    local dy = M.page_scroll
    local seen = function(t, rh) return t >= top and t + rh <= floor end

    for i, r in ipairs(v.rows or {}) do
        local rowh = row_h(r)
        if r.sect then
            -- Wrapped to the room the panel has, and measured before the head
            -- is placed so a sentence that took two lines does not draw the
            -- second one over the row under it. On a phone this sentence is
            -- most of the width of the screen.
            local said = r.sect_line
                and wrapped(cased(r.sect_line), TYPE.BODY * F.scale,
                            w - 10 * F.scale, MENU_FONT) or nil
            local sh = head_h(r)
            local hy = at - dy
            if hy >= top and hy + sh <= floor then
                hrule(x, hy + SECT * pages.SECT_RULE, w)
                lbl(r.sect, x, hy + SECT * pages.SECT_LABEL)
                if r.sect_note then
                    lbl(r.sect_note,
                        x + text_w(r.sect, LBL_PX * F.scale) + 12 * F.scale,
                        hy + SECT * pages.SECT_LABEL,
                        pal.FRIEND)
                end
                if said then
                    -- Cased once over the whole sentence and drawn raw. Left
                    -- to `txt` the case is applied per line, so a sentence
                    -- that wrapped came out with a capital in the middle of
                    -- itself.
                    local ny = hy + SECT + 8 * F.scale
                    for _, line in ipairs(said) do
                        txt(line, x, ny, TYPE.BODY * F.scale, pal.READ,
                            nil, MENU_FONT, true)
                        ny = ny + pages.NOTE_LINE * F.scale
                    end
                end
            end
            at = at + sh
        end
        local ry0 = at - dy
        at = at + rowh
        if seen(ry0, rowh) then
            -- Nothing in the list is the cursor while the field above has
            -- it. Two lit things on one page is a page that cannot say where
            -- a press would go.
            local hot = (focused and not a.on and i == v.sel) or i == v.hover
            if hot then LIT.field(ry0, rowh, LIT.CURSOR) end
            local cy = ry0 + rowh / 2
            local col = pal.a(pal.INK, r.dim and 0.6 or (hot and 1 or 0.9))
            if r.state == "asked" then
                -- An add that is asking something: the keys first, from the
                -- right, because the name is what gives way when a row runs
                -- out of width.
                local edge = x + w - 8 * F.scale
                for k = #(r.acts or {}), 1, -1 do
                    local act = r.acts[k]
                    edge = row_button(edge, cy, kh, act.label, act.go,
                                  v.friend_hot == i and v.friend_hot_act == k,
                                  "friend_act", i, k) - 8 * F.scale
                end
                if packed then
                    txt(r.label or "?", x, ry0 + rowh * 0.28, TYPE.ROW * F.scale,
                        col, nil, MENU_FONT, true)
                    txt(r.detail or "", x, ry0 + rowh * 0.72, TYPE.BODY * F.scale,
                        pal.READ, nil, MENU_FONT)
                else
                    txt(r.label or "?", x, cy - 8 * F.scale, TYPE.ROW * F.scale, col,
                        nil, MENU_FONT, true)
                    txt(r.detail or "", x, cy + 10 * F.scale, TYPE.BODY * F.scale,
                        pal.READ, nil, MENU_FONT)
                end
            else
                -- A friend: the dot, the name, and the game. Solid where they
                -- are flying and hollow where they are not, so the row says it
                -- in a mark before it says it in a word, and says it at all on
                -- a screen where the two greens are one grey.
                local on = r.state == "flying"
                local dx = x + pages.ON_R * F.scale
                if on then
                    F.layer:disc(dx, ry(cy), pages.ON_R * F.scale, 10,
                                 pal.ONLINE)
                else
                    F.layer:ring(dx, ry(cy), pages.ON_R * F.scale,
                                 1.3 * F.scale, 10, pal.a(pal.DIM, 0.7))
                end
                txt(r.label or "?", x + 19 * F.scale, cy, TYPE.ROW * F.scale,
                    on and pal.INK or pal.READ,
                    nil, MENU_FONT, true)
                -- Against the far edge, where the eye is not reading names,
                -- and raw: a game keeps the capitals the games list gave it.
                if r.detail and r.detail ~= "" then
                    txt(r.detail, x + w, cy, TYPE.BODY * F.scale,
                        pal.READ, "right", MENU_FONT, true)
                end
            end
            -- The row itself, after its buttons, so a press on one of them
            -- does not raise the card as well. Across the field it lit up,
            -- which is the whole drawer.
            if r.pick then
                local hx, _, hw = M.drawer_span()
                hit(hx, ry0, hw, rowh, "stage", i)
            end
        end
    end

    -- Nothing at all, which is a different page from a page with one empty
    -- section on it. Under the field rather than instead of it: the field is
    -- how somebody with no friends gets their first one, and the band at the
    -- foot is how they get one who has never played.
    if #(v.rows or {}) == 0 and v.empty then
        empty_state(x, top, w, floor - top, v.empty)
    end

    if foot > 0 then pages.invite_banner(v, floor) end

    -- The room the list has is the room above the band, so a page that would
    -- have just fitted scrolls rather than running its last row under it.
    --
    -- No breathing room past the last row: the band at the foot is the
    -- breathing room now, and sixteen points of nothing under the list is
    -- sixteen points the scroll has to travel and cannot show. On a window
    -- short enough to hold one row that was the difference between reaching
    -- the last name and stopping two points above it, since a row that does
    -- not fit whole is not drawn at all.
    local room = floor - y
    M.page_extent = (at - top) + BAND
    M.page_room = room
    if M.page_extent > room then
        local track = floor - top
        local bar = math.max(30 * F.scale, track * track / M.page_extent)
        local pos = (M.page_scroll / math.max(1, M.page_extent - room))
                    * (track - bar)
        local bx = x + w - 3 * F.scale
        rect(bx, top, 3 * F.scale, track, pal.a(pal.DIM, 0.12))
        rect(bx, top + pos, 3 * F.scale, bar, pal.a(pal.RADAR_TILE, 0.8))
    end
end

-- The firing range: the row under the cursor, drawn doing the thing it does.
-- A shelf can name a fuse and price a fuse, and neither tells a browsing
-- pilot what a fuse is for; thirty points of animation does. Everything in
-- here is the arena's own vocabulary at toy scale: rounds from marks.lua
-- wearing the rung and add-on actually on offer, hulls from the roster,
-- blasts as the rings they are. The loop is short and seamless because a
-- browser is not watching it, they are reading past it, and it only has to
-- be the right picture whenever the eye lands.
function pages.range(r, bx, by, bw, bh)
    local t = (F.now % 2.4) / 2.4
    local cy = by + bh / 2
    local sell = math.min((r.owned or 0) + 1, math.max(r.arena_max or 0, 1))
    local gun = r.trigger == 0
    -- A craft in motion, at a size where a hull would be a smudge: the
    -- contact triangle, nose to the right.
    local function dart(cx2, cy2, k, col)
        F.layer:outline({cx2 + k, ry(cy2), cx2 - k * 0.7, ry(cy2 - k * 0.7),
                         cx2 - k * 0.7, ry(cy2 + k * 0.7)},
                        1.0 * F.scale, col, true)
    end
    local function blast(cx2, cy2, u, col, reach)
        if u <= 0 or u >= 1 then return end
        F.layer:ring(cx2, ry(cy2), 4 * F.scale + u * (reach or 26 * F.scale),
                     1.2 * F.scale, 20, pal.a(col, 0.9 * (1 - u)))
    end
    -- A tank of energy: the one meter the whole game runs on, as a bar.
    local function tank(x2, y2, w2, fill, col)
        F.layer:frame(x2, ry(y2, 7 * F.scale), w2, 7 * F.scale,
                      1.0 * F.scale, pal.a(pal.DIM, 0.5))
        if fill > 0.01 then
            rect(x2 + 1.5 * F.scale, y2 + 1.5 * F.scale,
                 (w2 - 3 * F.scale) * math.min(fill, 1), 4 * F.scale,
                 pal.a(col, 0.8))
        end
    end
    if r.group == "flight" then
        -- Every stat demo is the same sentence: the top line is the ship
        -- you have, the bottom line is the ship one rung up, moving while
        -- you watch. "Now" and "next" in the small voice, the next rung in
        -- the stat's own color.
        local lx = bx + 66 * F.scale
        local lw2 = bw - 96 * F.scale
        local y1, y2 = cy - 22 * F.scale, cy + 22 * F.scale
        local col = pal.a(r.tint_col or pal.INK, 0.9)
        if r.short ~= "ROT" then
            lbl("now", bx + 12 * F.scale, y1, pal.MUTE)
            lbl("next", bx + 12 * F.scale, y2,
                pal.a(r.tint_col or pal.INK, 0.9))
        end
        if r.short == "NRG" then
            -- The same three hits land on both tanks; the deeper one is
            -- still flying after them.
            local hits = math.floor(t * 4) * 0.3
            tank(lx, y1 - 3 * F.scale, lw2 * 0.7, 1 - hits, pal.a(pal.DIM, 0.8))
            tank(lx, y2 - 3 * F.scale, lw2 * 0.85, 1 - hits * 0.82, col)
        elseif r.short == "RCH" then
            tank(lx, y1 - 3 * F.scale, lw2 * 0.8, t, pal.a(pal.DIM, 0.8))
            tank(lx, y2 - 3 * F.scale, lw2 * 0.8, math.min(1, t * 1.5), col)
        elseif r.short == "SPD" then
            dart(lx + (t % 1) * lw2, y1, 6 * F.scale, pal.a(pal.DIM, 0.8))
            dart(lx + (t * 1.3 % 1) * lw2, y2, 6 * F.scale, col)
        elseif r.short == "THR" then
            -- From a standing start, which is where thrust lives.
            dart(lx + t * t * lw2, y1, 6 * F.scale, pal.a(pal.DIM, 0.8))
            dart(lx + math.min(1, t * t * 1.45) * lw2, y2, 6 * F.scale, col)
        elseif r.short == "ROT" then
            local function turn_dial(cx2, rate, col2)
                local a = t * 6.2832 * rate
                F.layer:ring(cx2, ry(cy), 16 * F.scale, 1.0 * F.scale, 20,
                             pal.a(pal.DIM, 0.4))
                F.layer:seg(cx2, ry(cy),
                            cx2 + math.sin(a) * 15 * F.scale,
                            ry(cy - math.cos(a) * 15 * F.scale),
                            1.4 * F.scale, col2)
            end
            local d1 = lx + 40 * F.scale
            local d2 = lx + lw2 - 40 * F.scale
            local wy = cy + 28 * F.scale
            turn_dial(d1, 1, pal.a(pal.DIM, 0.8))
            turn_dial(d2, 1.4, col)
            lbl("now", d1, wy, pal.MUTE, "center")
            lbl("next", d2, wy,
                pal.a(r.tint_col or pal.INK, 0.9), "center")
        end
    elseif r.group == "levels" then
        -- The whole ladder, each rung as the round it fires, with the one
        -- on sale ringed; over it the rung you would own next, flying. The
        -- ramp does the teaching: hotter rungs wear the hotter color.
        local top = math.max(r.arena_max or 1, 1)
        local pitch = math.min(44 * F.scale, (bw - 40 * F.scale) / top)
        local lx = bx + bw / 2 - (top - 1) * pitch / 2
        local ly2 = by + bh - 30 * F.scale
        for k = 1, top do
            local cx2 = lx + (k - 1) * pitch
            marks.round(cx2, ry(ly2), 8 * F.scale, gun, k)
            if k == sell then
                F.layer:ring(cx2 + (gun and 2 or 0), ry(ly2), 13 * F.scale,
                             1.1 * F.scale, 20, pal.a(pal.CHARGE_COL, 0.85))
            end
        end
        local fy = by + bh * 0.32
        local fx = bx + 20 * F.scale + t * (bw - 60 * F.scale)
        if t < 0.82 then
            marks.round(fx, ry(fy), 8 * F.scale, gun, sell)
        else
            blast(bx + bw - 40 * F.scale, fy, (t - 0.82) / 0.18,
                  pal.rung(sell), gun and 14 * F.scale or 30 * F.scale)
        end
    elseif r.group == "weapons" then
        local m = r.mod or -1
        local lvl = r.lvl or 0
        local modn = {}
        modn[m + 1] = sell
        local x0 = bx + 20 * F.scale
        if m == 0 then
            -- Spray: the pull, thrown n wide.
            local d = 14 * F.scale + t * (bw - 64 * F.scale)
            for i = 1, sell + 1 do
                local a = (i - (sell + 2) / 2) * 0.17
                marks.round(x0 + d * math.cos(a),
                            ry(cy + d * math.sin(a) * 0.9),
                            6.5 * F.scale, gun, lvl)
            end
        elseif m == 1 then
            -- Bounce: the wall keeps the round in play. The path it will
            -- take is laid faintly under it, folds and all.
            local x1, ph = x0, by + 16 * F.scale
            local pb = by + bh - 16 * F.scale
            local run = bw - 50 * F.scale
            local folds = 1 + math.min(sell, 3)
            local function at(u)
                local v2 = u * folds
                local fold = 2 * math.abs(v2 / 2 - math.floor(v2 / 2 + 0.5))
                return x1 + u * run, ph + fold * (pb - ph)
            end
            local steps = 24
            for i = 0, steps - 1 do
                local ax, ay = at(i / steps)
                local bx2, by2 = at((i + 1) / steps)
                F.layer:seg(ax, ry(ay), bx2, ry(by2), 0.8 * F.scale,
                            pal.a(pal.DIM, 0.22))
            end
            local px2, py2 = at(t)
            marks.round(px2, ry(py2), 7 * F.scale, gun, lvl, modn)
        elseif m == 2 then
            -- Prox: the dodge that stopped working. The ring is the fuse.
            local tx2 = bx + bw - 44 * F.scale
            local reach = (18 + sell * 7) * F.scale
            thumb(tx2, cy, 0, pal.a(pal.ENEMY, 0.9), 1.2)
            F.layer:ring(tx2, ry(cy), reach, 1.0 * F.scale, 24,
                         pal.a(pal.BOMB, 0.30 + 0.12 * math.sin(F.now * 3)))
            local stop = tx2 - reach
            if t < 0.7 then
                marks.round(x0 + t / 0.7 * (stop - x0), ry(cy),
                            7 * F.scale, gun, lvl, modn)
            else
                blast(stop, cy, (t - 0.7) / 0.3, pal.rung(lvl))
            end
        elseif m == 3 then
            -- Shrapnel: the ending is an attack of its own. The splinters
            -- are the gun rounds they really are, small.
            local sx2 = bx + bw * 0.55
            if t < 0.5 then
                marks.round(x0 + t * 2 * (sx2 - x0), ry(cy), 7 * F.scale,
                            gun, lvl, modn)
            else
                local d = (t - 0.5) * 110 * F.scale
                for i = 0, 5 do
                    local a = i * 1.0472 + 0.3
                    marks.round(sx2 + math.cos(a) * d,
                                ry(cy + math.sin(a) * d * 0.8),
                                4.5 * F.scale, true, 1)
                end
                blast(sx2, cy, (t - 0.5) * 3, pal.rung(lvl))
            end
        elseif m == 4 then
            -- Freeze: their tank stops refilling. The top bar is a ship
            -- that was not hit; the bottom one took the round.
            local tx2 = bx + bw - 44 * F.scale
            thumb(tx2, cy - 6 * F.scale, 0,
                  pal.a(pal.ENEMY, t > 0.45 and t < 0.85 and 0.5 or 0.9),
                  1.2)
            local fl
            if t < 0.45 then fl = t
            elseif t < 0.85 then fl = 0.45
            else fl = 0.45 + (t - 0.85) * 2 end
            lbl("their recharge", bx + 12 * F.scale, by + bh - 18 * F.scale,
                pal.MUTE)
            tank(bx + bw * 0.42, by + bh - 21 * F.scale, bw * 0.44, fl,
                 pal.a(pal.ENEMY, 0.8))
            if t < 0.45 then
                marks.round(x0 + t / 0.45 * (tx2 - 26 * F.scale - x0),
                            ry(cy - 6 * F.scale), 7 * F.scale, gun, lvl, modn)
            else
                blast(tx2 - 16 * F.scale, cy - 6 * F.scale,
                      (t - 0.45) / 0.2, pal.a(pal.hot(pal.rung(lvl), 0.45), 1),
                      12 * F.scale)
            end
        elseif m == 5 then
            -- Push: whatever the blast reaches is thrown. The thrown thing
            -- is a ship, so it is drawn as one.
            local sx2 = bx + bw * 0.5
            local ex = bx + bw - 50 * F.scale
                       + (t > 0.5 and (t - 0.5) * 70 * F.scale or 0)
            thumb(ex, cy, 0, pal.a(pal.ENEMY, 0.9), 1.2)
            if t < 0.5 then
                marks.round(x0 + t * 2 * (sx2 - x0), ry(cy), 7 * F.scale,
                            gun, lvl, modn)
            else
                blast(sx2, cy, (t - 0.5) * 2, pal.rung(lvl), 44 * F.scale)
            end
        end
    elseif r.group == "charges" then
        local name = string.lower(r.label or "")
        if string.find(name, "repel", 1, true) then
            thumb(bx + bw / 2, cy, 0, pal.a(pal.FRIEND, 0.95), 1.3)
            for i = 0, 5 do
                local a = i * 1.0472 + 0.5
                local d = t < 0.5 and (66 - t * 2 * 44) or (22 + (t - 0.5) * 2 * 80)
                d = d * F.scale
                marks.round(bx + bw / 2 + math.cos(a) * d,
                            ry(cy + math.sin(a) * d * 0.7),
                            5 * F.scale, true, 1)
            end
            if t > 0.5 then
                blast(bx + bw / 2, cy, (t - 0.5) * 2, pal.CHARGE_COL,
                      56 * F.scale)
            end
        elseif string.find(name, "burst", 1, true) then
            -- A burst is many rounds at once, so the rosette is drawn as
            -- the rounds it throws, not as an abstraction of them.
            thumb(bx + bw / 2, cy, 0, pal.a(pal.FRIEND, 0.95), 1.3)
            if t > 0.3 then
                local d = (t - 0.3) * 110 * F.scale
                for i = 0, 7 do
                    local a = i * 0.7854
                    marks.round(bx + bw / 2 + math.cos(a) * d,
                                ry(cy + math.sin(a) * d * 0.7),
                                5 * F.scale, true, 1)
                end
            end
        else
            marks.charge(2, bx + bw / 2, ry(cy), 16 * F.scale,
                         pal.a(pal.CHARGE_COL, 0.9))
        end
    end
end

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

-- How far under the head's rule a page begins, on every page in the menu.
--
-- The column keeps MENU_PAD from each of its side edges, so the page is inset
-- the same from the bar over it as it is from the two edges beside it. One
-- measure for the panel, rather than one for the sides and another for the
-- top.
--
-- It was thirty, plus eight more in `sy`, and a page carrying a band of its
-- own got ten instead. Thirty was room held for two things that have since
-- moved out from under it: the ticked rule that used to introduce a list, and
-- the way out, which is on the head row now beside the call sign. What was
-- left was thirty-eight points of nothing over a games list and eighteen over
-- the hangar, which is the same panel measured two ways.
local STAGE_TOP = MENU_PAD

-- And how much the foot of the stage keeps back for the one line drawn across
-- it, on the frames where there is one. On `pages` rather than beside
-- STAGE_TOP because this file is at the two hundred locals a Lua chunk may
-- hold. See client/tests/upvalues_test.lua.
pages.FOOT_LINE = 26

-- A section head: a hairline with a small label under it, which is how this
-- menu groups a list. How tall one is, and how far into it the rule and the
-- label sit. Two pages draw them, the list and the friends page, and they had
-- a set of fractions each: 0.45 and 0.85 against 0.42 and 0.82, the same
-- object measured two ways, so the first label on the settings page and the
-- first on the friends page sat most of a point apart. On `pages` for the
-- reason FOOT_LINE is.
pages.SECT = 24
pages.SECT_RULE = 0.45
pages.SECT_LABEL = 0.85

-- The strip down the left of the stage that the type does not enter. The mark
-- on the row you are already in sits there, off the column rather than in it,
-- and it is what gives a lit row its left margin.
-- --- menu marks ----------------------------------------------------------
--
-- Rail destinations and the same marks reused by page controls live in one
-- drawing module. Layout and hit publication stay here so their ordering
-- remains explicit in the menu renderer.
local draw_mark = ui_menu_marks.new({
    frame = F,
    palette = pal,
    rect = rect,
    ry = ry,
    pilot_mark = pilot_mark,
    thumb = thumb,
    rivet_mark = pages.rivet_mark,
})

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
function sweep_dial(cx, cy, r)
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

-- The door: one page about the room the game points at.
--
-- The pilot page: who you are, what you have flown, and the way to keep it.
-- The name leads with NEW NAME as a key beside it, the career sits under a
-- ship-page section rule as bare totals, and the account acts stand at the
-- foot the way DEPLOY and SAVE do: a guest gets one lit SIGN UP under two
-- centered lines, a signed-in pilot gets the password and the way out as a
-- pair. The node's rows are the arrows' side of these controls, in the order
-- they are met walking down: the name key, the lit act, the line under it.
function pages.pilot(v, x, y, w, h, focused)
    local c = v.pilot_card or {}
    local sel = focused and (v.sel or 0) or 0
    local at = y + 10 * F.scale

    -- The name in its owner's case. A press on it does nothing any more; it
    -- used to reroll it, which cost a curious pilot their call sign.
    local kh = 26 * F.scale
    txt(c.name or "", x, at + kh / 2, TYPE.PAGE * F.scale, pal.INK,
        nil, MENU_FONT, true)
    -- The size every other key in this menu is set at. It was eight and a half
    -- points, which is under the ten this interface holds authored type to and
    -- is eight and a half pixels on a monitor that is not a phone: a key
    -- nobody with a desktop could read. See `lbl`.
    local KEY_PX = TYPE.BODY * F.scale
    local kw = text_w("new name", KEY_PX, MENU_FONT) + 22 * F.scale
    local hot = sel == 1
    key_box(x + w - kw, at, kw, kh,
            pal.rgb(0x0a0f18, hot and 0.95 or 0.7),
            pal.a(hot and pal.FRIEND or pal.RADAR_TILE, hot and 0.95 or 0.7))
    txt("new name", x + w - kw / 2, at + kh / 2, KEY_PX,
        hot and pal.FRIEND or pal.INK, "center",
        MENU_FONT)
    hit(x + w - kw, at, kw, kh, "stage", 1)
    at = at + kh + 16 * F.scale

    -- The career, in the ship page's section grammar: a rule edge to edge of
    -- the page and the label under it, then the totals. Bare totals with no
    -- clock on them, because there is no season and the week belongs to the
    -- site's ladder. The rating names the class it was earned in and is
    -- withheld while provisional, the way /pilots withholds it.
    hrule(x, at, w)
    at = at + 13 * F.scale
    lbl("career", x, at)
    at = at + 24 * F.scale
    local function fact(label, value)
        txt(label, x, at, TYPE.ROW * F.scale, pal.INK)
        txt(value, x + w, at, TYPE.BODY * F.scale, pal.READ,
            "right", nil, true)
        at = at + 26 * F.scale
    end
    local career = c.career
    if career and career.class then
        local word = career.class == "duel" and "Duel rating"
            or "Arena rating"
        local val = "provisional"
        if career.rating then
            val = string.format("%d, %s", math.floor(career.rating + 0.5),
                                string.lower(career.tier or ""))
        end
        fact(word, val)
    end
    if career then
        fact("Record", career.kills .. " kills, " .. career.deaths
             .. " deaths")
        fact("Games", tostring(career.games))
    end
    txt("Rivets", x, at, TYPE.ROW * F.scale, pal.INK)
    pages.priced(c.rivets or 0, x + w, at, TYPE.BODY * F.scale,
                 pal.a(pal.CHARGE_COL, 0.95), "right")
    at = at + 26 * F.scale

    -- The foot. Signing up is the one big act a guest has here, so it gets
    -- the DEPLOY treatment: full width, lit, under the line saying what it
    -- buys and the line for the pilot who already has one. Signed in, the
    -- same room holds the password and the way out as a pair, and nothing
    -- has to say which state the account is in: the keys are the state.
    local fh = 36 * F.scale
    -- Off the rail by the gutter the column keeps at its sides, which is the
    -- one margin this drawer has. It was six points off a floor that stopped
    -- forty short of the rule, so the pair stood in a strip of ground half
    -- again as tall as the keys themselves: a foot that had come away from
    -- the bottom of the panel it belongs to.
    local ky = y + h - fh - 14 * F.scale
    if c.online and not c.claimed then
        local mid = x + w / 2
        local l2 = ky - 16 * F.scale
        local l1 = l2 - 19 * F.scale
        txt("Keep your points and log in on other devices", mid, l1,
            TYPE.BODY * F.scale, pal.READ, "center", MENU_FONT)
        local ask = "Already have a pilot? "
        local act = "log in"
        local px2 = TYPE.BODY * F.scale
        local aw = text_w(ask, px2, MENU_FONT)
        local vw = text_w(act, px2, MENU_FONT)
        local sx2 = mid - (aw + vw) / 2
        -- The cursor says where a press lands, the way it does on every other
        -- row of every other page. It used to be said by setting the word
        -- itself a shade brighter, which is a thing type in this menu no
        -- longer does: state is a color here, and cyan has nothing above it.
        if sel == 3 then
            LIT.field(l2 - 10 * F.scale, 20 * F.scale, LIT.CURSOR)
        end
        txt(ask, sx2, l2, px2, pal.READ, nil, MENU_FONT)
        txt(act, sx2 + aw, l2, px2,
            pal.FRIEND, nil, MENU_FONT, true)
        hit(x, l2 - 10 * F.scale, w, 20 * F.scale, "stage", 3)
        local hot2 = sel == 2
        key_box(x, ky, w, fh, pal.a(pal.FRIEND, hot2 and 0.18 or 0.10),
                pal.a(pal.FRIEND, hot2 and 1 or 0.85))
        txt("sign up", mid, ky + fh / 2, TYPE.BODY * F.scale,
            pal.INK, "center", MENU_FONT)
        hit(x, ky, w, fh, "stage", 2)
    elseif c.online then
        local half = (w - 10 * F.scale) / 2
        for i, word in ipairs({"change password", "log out"}) do
            local bx = x + (i - 1) * (half + 10 * F.scale)
            local on = sel == i + 1
            key_box(bx, ky, half, fh,
                    pal.rgb(0x0a0f18, on and 0.95 or 0.7),
                    pal.a(on and pal.FRIEND or pal.RADAR_TILE,
                          on and 0.95 or 0.7))
            txt(word, bx + half / 2, ky + fh / 2, KEY_PX,
                on and pal.FRIEND or pal.INK,
                "center", MENU_FONT)
            hit(bx, ky, half, fh, "stage", i + 1)
        end
    end
    -- Head and foot are pinned, the career fits between them on any window
    -- this drawer runs at, so the page never scrolls.
    M.page_extent = h
    M.page_room = h
end

-- How tall a line of a row's sentence is, and how that sentence breaks.
--
-- The sentence used to be drawn as one line from the column's left edge with
-- nothing clamping it, so a zone description longer than the column ran on to
-- whatever was beside it and then off the panel: at the phone's width the two
-- shipped ones reached within eight and fifteen points of the glass, straight
-- through the leave key on the row they belonged to. It wraps now, inside what
-- the row actually has left, and the list gives every row the height of the
-- longest one so nothing shifts as the cursor walks down.
--
-- On `pages` rather than in a local of its own, because this file is at the
-- two hundred locals a Lua chunk may hold. See client/tests/upvalues_test.lua.
pages.NOTE_PX = TYPE.BODY
pages.NOTE_LINE = 19

-- What a row keeps back at its right for the keys it carries, if any.
function pages.acts_w(r)
    local out = 0
    for _, a in ipairs(r.acts or {}) do
        out = out + row_button_w(a.label) + 8 * F.scale
    end
    return out
end

-- The sentence, broken to the room the row has for it. `w` is the column.
--
-- Cased once over the whole sentence and drawn raw, which is what the friends
-- page learned the same way: left to `txt`, the case is applied to each line
-- as it is drawn, and a sentence that wrapped came back with a capital in the
-- middle of itself.
function pages.note_lines(note, w, r)
    if not note or note == "" then return nil end
    return wrapped(cased(note), pages.NOTE_PX * F.scale,
                   math.max(40 * F.scale, w - pages.acts_w(r)), MENU_FONT)
end

-- One row of the stage: a mark for the one you are on, the name, and
-- whatever the row has to say about itself on the right.
--
-- `hot` is the cursor, from either hand: the row the arrows are on while the
-- stage has them, or the row a pointer is resting on.
--
-- `idx` is the row's place in the page, which is what a press on it says, and
-- `warm` is which of the row's own buttons a pointer is resting on, if any.
local function stage_row(x, y, w, h, r, hot, idx, warm)
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
    if hot then
        LIT.field(y, h, LIT.CURSOR)
    elseif r.mark then
        -- Where you already are, at the standing weight. This was a lit wedge
        -- out in the gutter; the field says the same thing without spending a
        -- mark on it, and without pushing its own label out of the column.
        LIT.field(y, h, LIT.HERE)
    end
    -- One text column, whatever the row is, and it is the column the title
    -- above the list is set in.
    local tx = x
    local sel = hot or r.mark
    -- Two kinds of row you cannot press, written a register back from the ones
    -- you can: one nothing is serving yet, and one with no seat left.
    --
    -- It was `col = pal.a(col, 0.6)` and it did nothing at all, because the
    -- two places that draw the name ask for `pal.a(col, label_a)` and `pal.a`
    -- replaces an alpha rather than multiplying one. So a room nobody was
    -- serving named itself at exactly the weight of a room you could join,
    -- while the strip of figures under it did dim, through a multiplier that
    -- worked, down to 1.97:1. The row said the wrong half of itself quietly.
    -- A register carries it now, which is a thing that cannot be thrown away
    -- by the next hand that sets an alpha.
    local off = r.waiting or r.full
    if off then col = pal.MUTE end
    -- The row you are already on breathes, unless the cursor is also on it, in
    -- which case the cursor has it and the row is still: one thing moves on a
    -- page, and it is the thing you are not looking at. Breath is the one
    -- alpha left on type in this menu, and it rides on a name at full ink,
    -- floored at 0.74, which is 9.2:1 at the bottom of the curve.
    local label_a = 1
    if r.mark and not hot then label_a = LIT.breath() end
    -- A row carrying a sentence of its own gives it the lower half and takes
    -- the upper for everything else. The rows that set a value are the ones
    -- that want it: a shelf item or a control is a name whose meaning is not
    -- in the name, and the line under it is where that meaning goes.
    -- A sentence of its own needs two lines of room. A list long enough to
    -- squeeze its rows has neither, and drew the note over the label rather
    -- than dropping it: the shelf's descriptions landed on top of the names
    -- they described.
    --
    -- An empty sentence is not one. A row's note arrives as "" rather than
    -- absent wherever the thing behind it has the field and nothing in it,
    -- which on the games list is a zone whose catalog left the hook line
    -- blank. `note` is read three times below, for the label's size, for
    -- where the label sits, and for whether the sentence is drawn at all, and
    -- only the third asked `note_lines`, which answers nil for an empty
    -- string exactly as it does for a missing one. The length of that nil is
    -- where the page stopped drawing, and the menu came up empty over the
    -- arena with nothing on screen saying why.
    local note = (h >= 44 * F.scale) and r.note ~= "" and r.note or nil
    -- The format strip, where the row carries one and the list gave it the
    -- room. It is the whole of the row under the name: a game had a sentence
    -- between the two until the strip made it a second answer to a question
    -- the stacks already answer, and no row carries both.
    local strip = (h >= 58 * F.scale) and r.specs or nil
    -- A row you are choosing between, rather than one setting a value, sets
    -- its name half again as large, which is how the mocks draw both: it is
    -- the name that is being read, and what is under it is the reading.
    --
    -- Declared under `note` rather than over it, which is the whole of what
    -- was wrong here: read above its own `local`, `note` is a global, a
    -- global is nil, and the larger size this chooses never once applied.
    -- That is the bug .luacheckrc exists to catch, and it caught this one.
    local size = TYPE.ROW * F.scale
    if (note or strip) and h >= 44 * F.scale then
        size = TYPE.LEAD * F.scale
    end
    local ly = note and (y + h * 0.36) or (y + h / 2)
    if strip then ly = y + h * 0.25 end
    -- Drawn here unless the detail turns out not to fit beside it, in which
    -- case the pair is laid out as two lines below and this one is skipped.
    --
    -- Asked as the question it is: what is left of the column once the name
    -- has had its share, against what the detail needs. It was the column's
    -- width less three constants that between them stood for the name, and
    -- they were measured against a column that has since changed width at
    -- both edges, so a phone's help rows went back to being drawn over their
    -- own labels the moment the column moved.
    local two_line = r.detail and r.detail ~= ""
        and not r.choice and not note
        and text_w(r.detail, 12 * F.scale)
            > w - text_w(r.label or "", size, MENU_FONT) - 16 * F.scale
    if not two_line then
        txt(r.label or "", tx, ly, size,
            pal.a(col, label_a), nil, MENU_FONT, r.named)
    end
    if note then
        -- Centered on the line one line would have sat on, so a row whose
        -- sentence fits is drawn exactly where it always was and a row whose
        -- sentence takes two grows into the room the list gave it, evenly,
        -- rather than hanging off the top of the gap.
        local lines = pages.note_lines(note, w, r)
        local ny = y + h * 0.68
            - (#lines - 1) * pages.NOTE_LINE * F.scale / 2
        for _, line in ipairs(lines) do
            txt(line, tx, ny, pages.NOTE_PX * F.scale,
                off and pal.MUTE or pal.READ,
                nil, MENU_FONT, true)
            ny = ny + pages.NOTE_LINE * F.scale
        end
    end
    if strip then
        -- Label over value, a thin rule between the stacks: the room band's
        -- own grammar (TIME, PLAYERS), reading down the same columns on
        -- every game because the rows share one height and one order. The
        -- words are the catalog's; this only lays them out. Values keep
        -- their authored case, since "4 v 4" is data rather than a
        -- sentence, and a row nothing is serving writes its facts a
        -- register back, with the rest of itself.
        --
        -- About seven points of air over the name and seven under the
        -- values, which is what the row had when a sentence sat between
        -- them: it lost a line, so the two that are left closed up rather
        -- than spreading into the gap.
        local sx2 = tx
        local right = x + w
        for si, s in ipairs(strip) do
            local sw2 = math.max(
                text_w(string.upper(s[1] or ""), LBL_PX * F.scale, nil, true),
                text_w(s[2] or "", 13 * F.scale, nil, true))
            -- Whole stacks only, rule included. A drawer too narrow for the
            -- next one drops it rather than running the strip under the
            -- dial at the right.
            local at2 = sx2 + (si > 1 and 15 * F.scale or 0)
            if at2 + sw2 > right then break end
            if si > 1 then
                F.layer:seg(sx2, ry(y + h * 0.49), sx2, ry(y + h * 0.90),
                            1.0 * F.scale, pal.a(pal.RADAR_TILE, 0.45), true)
            end
            lbl(s[1], at2, y + h * 0.59,
                pal.MUTE)
            txt(s[2], at2, y + h * 0.81, TYPE.BODY * F.scale,
                off and pal.MUTE or pal.READ, nil, nil, true)
            sx2 = at2 + sw2 + 15 * F.scale
        end
    end
    -- The right hand side is data, so it stays in the face the numbers in
    -- flight are set in: a call sign, a count, a hull's name.
    if r.acts then
        -- What can be done to this row, as buttons at its right hand end. The
        -- games list carries one: the way out of the seat you are flying, on
        -- the row of the room it is in.
        --
        -- A button rather than a row of its own, because it is about the row it
        -- sits on, and the row goes on meaning what every other row in the list
        -- means. Drawn with the friends page's own button, so the two lists
        -- that hang controls off a name cannot drift apart.
        local kh = math.min(h - 12 * F.scale, 26 * F.scale)
        local edge = x + w
        for k = #r.acts, 1, -1 do
            local a = r.acts[k]
            -- Published inside `row_button`, and before the row's own box, so
            -- a press on the button is the button rather than the row under it.
            edge = row_button(edge, y + h / 2, kh, a.label, a.go,
                              warm == k, "row_act", idx, k) - 8 * F.scale
        end
    elseif r.waiting then
        -- No count, because there is nothing to count. The instrument that
        -- looks for a game says what the words did, in the room the numbers
        -- would have taken, and it keeps saying it while the list refreshes
        -- underneath: an arena can come back and this row is where it lands.
        sweep_dial(x + w - 11 * F.scale, ly, 11 * F.scale)
    elseif r.choice then
        -- A setting drawn as its own range: one step per value, the one it
        -- is on filled. "half" is a word to read and hold against the word
        -- on the row above; three steps of four lit is a position, and a
        -- press moves it along.
        local n = r.choices or 1
        local sw2 = 13 * F.scale
        local gap = 5 * F.scale
        local x1 = x + w
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
            txt(r.detail, x0 - 12 * F.scale, y + h / 2, TYPE.BODY * F.scale,
                pal.READ, "right")
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
                pal.a(col, label_a), nil, MENU_FONT, r.named)
            txt(r.detail, tx, y + h * 0.70, TYPE.BODY * F.scale, pal.READ,
                nil, nil, r.verbatim)
        else
            txt(r.detail, x + w, ly, TYPE.BODY * F.scale,
                r.mark and pal.FRIEND or pal.MUTE, "right",
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
function empty_state(x, y, w, h, e)
    local cx = x + w / 2
    local r = math.max(22 * F.scale, math.min(56 * F.scale, h * 0.26))
    -- Centered in whatever room is left rather than hung off the top of it: on
    -- an empty page there is nothing above to hang from.
    local blockh = 2 * r + 96 * F.scale
    local cy = y + math.max(0, (h - blockh) / 2) + r + 8 * F.scale
    sweep_dial(cx, cy, r)
    local ty = cy + r + 30 * F.scale
    txt(e.head or "", cx, ty, TYPE.LEAD * F.scale,
        pal.INK, "center", MENU_FONT)
    -- Wrapped to the room it has. It was one centred line whatever it said,
    -- so on a phone "fly with somebody, add them here, and they add you back"
    -- ran off both edges at once and the sentence was missing a word at each
    -- end.
    if e.line and e.line ~= "" then
        local px = TYPE.BODY * F.scale
        local ly = ty + 24 * F.scale
        -- Cased once, over the whole sentence, and then drawn raw. Left to
        -- `txt` it is applied per line, so a sentence that wrapped came out
        -- with a capital in the middle of itself.
        for _, line in ipairs(wrapped(cased(e.line), px, w - 16 * F.scale,
                                      MENU_FONT)) do
            txt(line, cx, ly, px, pal.READ, "center", MENU_FONT, true)
            ly = ly + pages.NOTE_LINE * F.scale
        end
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
    txt(f.label or "", x, y, TYPE.BODY * F.scale, pal.READ)
    local ty = y + 22 * F.scale
    if not dom then
        local shown = f.value or ""
        local size = TYPE.ROW * F.scale
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
            txt(shown, x, ty, size, pal.FRIEND,
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
        out[i] = string.format("%.1f,%.1f,%.1f,%d,%s,%d", fx / F.density,
                               (y + 22 * F.scale) / F.density - FIELD_H / 2,
                               fw / F.density,
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
    txt(a.head or "", mid, cy + 36 * F.scale, TYPE.ROW * F.scale,
        pal.INK, "center", MENU_FONT)
    -- What answering costs, when that is not obvious from the question. The
    -- menu's cards never needed one; the rooms card does, because what a move
    -- takes off a pilot is the part they cannot see.
    if a.note then
        txt(a.note, mid, cy + 60 * F.scale, TYPE.BODY * F.scale,
            pal.READ, "center")
    end
    -- What the question is about, when it is about a string rather than a
    -- choice: big enough to read off one machine and type into another,
    -- quoted rather than said, and lit, because it is the one thing on the
    -- card anybody has to get right.
    if a.code then
        txt(a.code, mid, cy + 72 * F.scale, TYPE.PAGE * F.scale, pal.FRIEND, "center", nil, true)
    end
    if a.fields then
        local fx = cx + 26 * F.scale
        local fw = cw - 52 * F.scale
        -- Under the note where the card carries one: the sign-up card is
        -- the first to want both, and without this they overprinted.
        local fy = cy + (a.note and 88 or 58) * F.scale
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
        ws[i] = menu_key_w(k.label)
        total = total + ws[i]
    end
    total = total + KEY_GAP * F.scale * (#a.keys - 1)
    local kx = mid - total / 2
    local ky = cy + ch - 22 * F.scale - KEY_H * F.scale
    for i, k in ipairs(a.keys) do
        menu_key(kx, ky, ws[i], k.label, i == a.sel)
        -- Whose question this is. The menu owns "answer"; anything else
        -- raising a card says so, or its answers are delivered to the menu.
        hit(kx, ky, ws[i], KEY_H * F.scale, a.action or "answer", i)
        kx = kx + ws[i] + KEY_GAP * F.scale
    end
end

-- The question a pressed room raises, over the whole screen.
--
-- A card rather than something inside the panel. A room-change question should
-- not be answerable by a stray click in the corner where it was asked: the wash
-- puts the arena behind it and `ask_card` drops every hit box already published,
-- so nothing else on screen can be pressed while it stands.
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

-- The hulls, as hulls. A list of seven names is seven words about drawings the
-- game already owns, and picking a ship from a menu that shows you the ships is
-- the one page that does not need reading at all.
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
    -- tall phone does not draw eight cells in the top third of the screen.
    y = y + math.max(0, (h - ch * rowsn) / 2)
    for i, r in ipairs(v.rows) do
        local c, rr = (i - 1) % cols, math.floor((i - 1) / cols)
        local cx = x + c * cw + cw / 2
        local cy = y + rr * ch + ch / 2
        local hot = (focused and i == v.sel) or i == v.hover
        local col = r.mark and pal.FRIEND or pal.INK
        -- The hull you are flying keeps a field of its own, so a cursor moved
        -- off it does not take the answer to "which one am I in" with it. A
        -- cell is not a row, so it lights its own shape rather than the
        -- drawer; the two weights are the list's.
        if r.mark then
            rect(x + c * cw + 4 * F.scale, y + rr * ch + 2 * F.scale, cw - 8 * F.scale,
                 ch - 4 * F.scale, pal.a(pal.FRIEND, LIT.HERE))
        end
        if hot then
            rect(x + c * cw + 4 * F.scale, y + rr * ch + 2 * F.scale, cw - 8 * F.scale,
                 ch - 4 * F.scale, pal.a(pal.FRIEND, LIT.CURSOR))
        end
        -- The hull, its name and its trade, held clear of the bottom of the
        -- lit cell. The role used to sit on that edge, its descenders over the
        -- line, so a selected ship read as type in a box a size too small for
        -- it.
        -- The one under the cursor turns, and nothing else on the page does.
        -- Seven hulls all revolving is a screensaver; one of them turning is
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
        -- The name of the hull you fly breathes the way every standing row
        -- does, unless the cursor is on it, in which case the cursor has it.
        txt(r.label or "", cx, cy + ch * 0.20, TYPE.ROW * F.scale,
            pal.a(col, (r.mark and not hot) and LIT.breath() or 1),
            "center", MENU_FONT)
        if r.role then
            txt(r.role, cx, cy + ch * 0.34, TYPE.LABEL * F.scale, pal.MUTE,
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
-- One table for the logo helpers, because the chunk sits at the
-- compiler's two-hundred-local ceiling and these travel together.
local logo = {}
logo.DEPTH = 10
-- The far face of the turning mark, and its edge. These were 0.30 and 0.48,
-- which read as black and as barely-there: a mark that spends half its turn
-- looking switched off. A face pointing away is still lit by the same room,
-- so it is shaded rather than extinguished.
local MK_ORANGE_BACK = {pal.LOGO_ORANGE[1] * 0.62,
                        pal.LOGO_ORANGE[2] * 0.62,
                        pal.LOGO_ORANGE[3] * 0.62, 1}
local MK_ORANGE_SIDE = {pal.LOGO_ORANGE[1] * 0.78,
                        pal.LOGO_ORANGE[2] * 0.78,
                        pal.LOGO_ORANGE[3] * 0.78, 1}
local MK_CYAN_BACK = {pal.LOGO_CYAN[1] * 0.62,
                      pal.LOGO_CYAN[2] * 0.62,
                      pal.LOGO_CYAN[3] * 0.62, 1}
local MK_CYAN_SIDE = {pal.LOGO_CYAN[1] * 0.78,
                      pal.LOGO_CYAN[2] * 0.78,
                      pal.LOGO_CYAN[3] * 0.78, 1}

function logo.poly(points, tris, ox, oy, k, squash, col)
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
function logo.sides(points, bx, fx, oy, k, squash, col)
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

function logo.face(ox, oy, k, squash, orange, cyan, alpha)
    logo.poly(MK_ORANGE, MK_ORANGE_TRI, ox, oy, k, squash,
              pal.a(orange, alpha))
    logo.poly(MK_CYAN, MK_CYAN_TRI, ox, oy, k, squash,
              pal.a(cyan, alpha))
    logo.poly(MK_GAP, MK_GAP_TRI, ox, oy, k, squash,
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
    local depth = turn and math.sin(turn) * logo.DEPTH * k / 2 or 0
    local bx, fx = cx - depth, cx + depth
    local oy = cy - MK_H * k / 2
    local front_facing = squash >= 0
    if math.abs(depth) > 0.001 then
        if front_facing then
            logo.face(bx, oy, k, squash,
                      MK_ORANGE_BACK, MK_CYAN_BACK, alpha)
        else
            logo.face(fx, oy, k, squash,
                      pal.LOGO_ORANGE, pal.LOGO_CYAN, alpha)
        end
        logo.sides(MK_ORANGE, bx, fx, oy, k, squash,
                   pal.a(MK_ORANGE_SIDE, alpha))
        logo.sides(MK_CYAN, bx, fx, oy, k, squash,
                   pal.a(MK_CYAN_SIDE, alpha))
        logo.sides(MK_GAP, bx, fx, oy, k, squash,
                   pal.a(pal.LOGO_GAP, alpha))
    end
    if front_facing then
        logo.face(fx, oy, k, squash,
                  pal.LOGO_ORANGE, pal.LOGO_CYAN, alpha)
    else
        logo.face(bx, oy, k, squash,
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
logo.EM, logo.GAP, logo.DROP = 0.74, 0.30, 0.12

-- How much room the lockup takes, so a row can start after it.
function M.wordmark_w(size)
    return M.logo_width(size * logo.EM) + size * logo.GAP
           + text_w("vectorwake", size)
end

-- On the module rather than file-local, because the landing draws it too and
-- `M.hud` is written above this line. A local would not be in scope there.
function M.wordmark(x, y, size)
    -- The mark stands to the left of the name, on the middle of the word
    -- rather than the middle of its line box, so the two read as one lockup.
    -- It takes the room it needs and the name starts after it.
    local h = size * logo.EM
    local lw = M.logo_width(h)
    M.logo(x + lw / 2, y + size * logo.DROP, h)
    txt("vectorwake", x + lw + size * logo.GAP, y, size, pal.INK, nil,
        MENU_FONT, true)
end

-- How tall a control on the head's line stands. The account button sets it,
-- and the link readout beside it takes its press box from the same number, so
-- the two answer over one band rather than each guessing at a height.
pages.HEAD_KEY = 30

-- The button at the far end of the top line: who you are signed in as.
--
-- It had the way out to the community beside it, on every layout, until the
-- game stopped carrying one.
--
-- Returns the left edge it reached, which is where the tab row beside it has
-- to stop. Laid out from opposite ends and never told about each other, the
-- two ran into the middle of a landscape phone and the last tab was drawn
-- under a pill that took its taps: settings could not be reached at all.
-- On `pages` rather than as a local of its own: this chunk sits at the two
-- hundred local ceiling a Lua function has, and the house answer is to gather
-- onto a table, since a table is one name however much it holds. See
-- client/tests/upvalues_test.lua.
function pages.corner(v, right, cy)
    local bh = pages.HEAD_KEY * F.scale
    local by = cy - bh / 2
    local rt = right
    if not (v.pilot and v.pilot.name and v.pilot.name ~= "") then
        return rt
    end
    -- A name is quoted rather than said: it keeps the case its owner gave it,
    -- where every other word on this row is in the interface's.
    --
    -- Lit by the arrows standing on it, wherever the panel is: that is a
    -- cursor, and a cursor you cannot see is a cursor nobody can use. A
    -- pointer resting on it lights it too, but not while its own page is up:
    -- the rail already carries the "you are here" mark for that page, and a
    -- mouse crossing the name is not a claim about where you are.
    local on = v.head_sel == "pilot"
        or (v.pilot_hot and v.at ~= "pilot")
    -- LABEL rather than BODY, which is the one place on the ladder a name
    -- steps down a rung. The head is a strip of fixed height sharing its
    -- width with the way out at one end and the line meter at the other,
    -- and this button grows with whatever is written on it: at BODY the
    -- longest call sign anybody can register leaves a phone 54 points for a
    -- readout that needs 80, so the meter stands down on a column that can
    -- plainly afford it. A chip in a dense bar is what this rung is for.
    local px = TYPE.LABEL * F.scale
    local bw = text_w(v.pilot.name, px, MENU_FONT, true) + 30 * F.scale
    local bx = rt - bw
    key_box(bx, by, bw, bh, pal.rgb(0x0a0f18, on and 0.95 or 0.7),
            pal.a(on and pal.FRIEND or pal.RADAR_TILE, on and 0.95 or 0.7))
    -- The weight a tab wears, because it is one more stop on that row. It was
    -- set brighter than the tabs it sits beside, and read as the thing the
    -- head was about.
    txt(v.pilot.name, bx + 15 * F.scale, cy, px,
        on and pal.FRIEND or pal.INK, nil,
        MENU_FONT, true)
    hit(bx, by, bw, bh, "pilot_page")
    return bx
end

-- How good the line is, to the left of the account button in the head.
--
-- Four bars from the connection's smoothed quality and nothing else. It
-- replaces "online  err 0.0 / 1 px", which was the client's own debugging left
-- on a player's screen: nobody flying has ever made a decision on a prediction
-- error in pixels.
--
-- It stood in the top right of the arena for a long time, above the dial. That
-- corner belongs to the dial, and a connection is not a thing that happens in
-- the arena: it is a fact about this client, like the call sign beside it and
-- the wallet behind that, and the head of the menu is where this game keeps
-- those. What the corner bought was four bars on screen for every second of
-- every match. Nobody asks that question while flying, and everybody asks it
-- the moment the game stutters, which is a moment somebody opens the menu
-- anyway.
--
-- The word LINK stood beside them until now, in the register every group on
-- every page is labeled in. A rising staircase of bars is the one instrument
-- on a phone that needs no caption, and captioning it put four letters on the
-- head of every page of the menu to say what the drawing already said.
--
-- `right` is the edge to hang it off, which is the account button's left, and
-- `mid` is the line that button is centered on. `floor` is the far end of what
-- the near side of the row is already holding. All three come from the caller
-- because the head lays itself out from the right and this is one more thing
-- in that row.
--
-- Returns the left edge it reached, the way `pages.corner` does, so anything
-- put in this row later knows where the row already ends.
--
-- `LINK_W` is the block of bars and `LINK_OVER` is how far past it the press
-- box may reach on the right before it is into the account button's clearance.
-- The box grows leftward from there to a whole target, which is the only
-- direction it has: see the press below.
pages.LINK_W, pages.LINK_OVER = 22, 4

function pages.link(q, right, mid, floor)
    -- Nothing at all, where the row has nowhere to put it. The account button
    -- grows with the call sign on it and a window narrower than a phone shrinks
    -- the column under both, so a long enough name in a small enough window
    -- leaves this standing over the x at the other end of the head. `M.pick`
    -- answers on publish order and the head publishes before the page does, so
    -- what that would cost is not a crowded row: it is the way out of the menu,
    -- taken by a readout. The band across the top of the arena drops a side's
    -- name under the same pressure, and a name says more than this does.
    --
    -- Asked of the bars themselves rather than of the box around them. The box
    -- is a fingertip wide and the drawing is a third of that, so asking it of
    -- the box would drop the readout on an ordinary phone the first time
    -- somebody registered a long call sign, over room only the press wanted.
    if right - pages.LINK_W * F.scale < floor then return right end
    -- What is left of the target once the floor has had its say. The bars are
    -- inside it either way, since the line above is what guarantees that.
    local left = math.max(right + (pages.LINK_OVER - M.TARGET) * F.scale, floor)
    -- The bars are one block on the row rather than four things each centered
    -- on it. A meter is a staircase standing on a floor, so the floor is what
    -- gets placed: the tallest bar is centered and the rest rest on its line.
    -- The block ends on `right`, since with the word gone that edge is the
    -- only thing holding it to the row.
    local tall = (3 + 3 * 2.6) * F.scale
    local foot = mid + tall / 2
    for k = 0, 3 do
        local bh = (3 + k * 2.6) * F.scale
        local bx = right - (pages.LINK_W - k * 6) * F.scale
        rect(bx, foot - bh, 4 * F.scale, bh,
             k < q and pal.a(pal.PAID, 0.85) or pal.a(pal.DIM, 0.22))
    end
    -- Everything behind the bars is for whoever is working on this, so it hides
    -- behind the one thing on screen that is already about the connection.
    --
    -- A whole `M.TARGET` square, which is not how the rest of this interface
    -- sizes a small control. Everywhere else a control keeps the shape the
    -- design gives it and `M.pick` makes up the difference, because a press
    -- that lands on nothing falls through to a near-miss pass that reaches the
    -- closest box. Inside the menu it never lands on nothing: the column
    -- publishes one box over the whole of itself so the gaps between rows are
    -- not a way out, an exact hit on that box beats the near-miss pass before
    -- it runs, and a thumb two points wide of these bars was answered by the
    -- panel. So the box is the target rather than the drawing, grown leftward
    -- because the right is the account button's clearance, and cut short there
    -- only by the way out at the other end of the head.
    hit(left, mid - M.TARGET * F.scale / 2,
        right + pages.LINK_OVER * F.scale - left, M.TARGET * F.scale, "debug")
    return left
end

-- --- the whole thing -------------------------------------------------------

-- How wide the menu is, in points, wherever it is drawn.
--
-- A phone's own measure, which is what makes one drawing serve three windows:
-- every page in here was already laid out to survive 390 points, because a
-- phone held upright is 390 points and the menu had to fit one. What the wider
-- windows were doing with the rest of the screen was a second layout nobody
-- was looking at, since the fight is what a player watching wants the glass
-- for. A window narrower than this gives the column everything it has.
--
-- The menu used to set its type 1.18 times the arena's on a window with room
-- for it, which is what a panel that is the whole window wants and the wrong
-- answer for a column at a phone's width: the sizes in here are a phone's
-- already. See .design/menu-unify.
local DOCK_W = 390

-- How long the drawer takes to come in or go out, in seconds, and the state
-- of that slide between frames.
--
-- The panel is a drawer: it comes in from the edge it lives on and leaves the
-- same way. That is worth the machinery because the column covers the corner
-- keys it is docked over, so without the slide a press on MENU swaps one
-- screen for another with nothing saying where the new one came from.
--
-- `M.drawer` is published because the arena has to keep handing this a view
-- for as long as the panel is still on screen, which is past the point the
-- menu itself calls closed. See `M.drawer_up`.
local DRAWER_SPAN = 0.16
M.drawer = 0            -- 0 shut, 1 fully in
-- Points of drawable pixel a finger has pulled the drawer left by, negative,
-- and nil while nobody is holding it. The arena sets it: a drawer that does
-- not follow the thumb dragging it is a drawer nobody believes they are
-- dragging.
M.drawer_grab = nil
local drawer_from, drawer_to, drawer_at = 0, 0, 0
-- Where the drawer stands and how wide it is, for the arena's own reading of
-- a gesture that starts on it.
local drawer_x, drawer_w = 0, 0

-- Whether the panel is on screen at all, open or still leaving. The arena
-- draws the menu while this is true and stops when it goes false.
function M.drawer_up()
    return M.drawer > 0.001 or M.drawer_grab ~= nil
end

-- Nothing is drawing the menu, so there is no drawer. Called by `M.begin` off
-- a frame that drew none.
function M.drawer_shut()
    M.drawer, M.drawer_grab = 0, nil
    drawer_from, drawer_to = 0, 0
    drawer_w = 0
end

-- The box the drawer covers, in the space hit boxes are published in.
function M.drawer_span()
    return drawer_x, 0, drawer_w, F.h
end

-- Whether the drawer is standing over this span of the screen.
--
-- The left column asks before it draws. The drawer is docked to the same edge
-- the scoreboard is pinned to, so the two are always over each other once it
-- is in, and a roster showing through a panel that has arrived on top of it
-- reads as a fault rather than as depth.
--
-- Asked as a real overlap rather than as "is the menu open", so the answer
-- follows the slide: the roster goes when the drawer's leading edge reaches
-- it and is back the moment that edge has passed it again. That is also what
-- makes it self-correcting if either of them ever moves.
--
-- One frame behind, because the arena draws its instruments before the panel
-- over them and this reads where the panel was last put. Sixteen milliseconds
-- of a roster during a slide is not a thing anybody sees.
function M.drawer_over(x, w)
    if M.drawer <= 0 and not M.drawer_grab then return false end
    if drawer_w <= 0 then return false end
    return drawer_x + drawer_w > x and drawer_x < x + w
end

-- Ease so it leaves fast and settles slow, which is what a drawer with weight
-- does and what stops a 160ms slide reading as a jump.
local function drawer_ease(t)
    return 1 - (1 - t) * (1 - t) * (1 - t)
end

-- Where a finger has the drawer, as a fraction of it being in.
local function drawer_held()
    if not M.drawer_grab then return M.drawer end
    return math.max(0, math.min(1,
        1 + M.drawer_grab / math.max(drawer_w, 1)))
end

-- The thumb has let go. `shut` says the pull was far enough to count as a
-- dismissal; either way the slide picks the drawer up from wherever the finger
-- left it rather than snapping, which is the whole difference between a drawer
-- somebody is pushing and a panel that blinks.
function M.drawer_release(shut)
    local slide = drawer_held()
    M.drawer_grab = nil
    M.drawer = slide
    drawer_from, drawer_to, drawer_at = slide, shut and 0 or 1, F.now
end

-- How deep the stack was last frame, and when it last changed, so a page
-- that has just been stepped into can arrive from the side rather than
-- appearing where the last one was.
--
-- The reading slides in over the page from the right, and stepping back sends
-- it the other way; that is the whole of what makes the two feel like one
-- surface being moved rather than two screens being swapped. Same span and
-- the same ease as the drawer, since it is the same gesture at a smaller
-- scale: a swipe right does it by hand.
--
-- At a still clock the page draws settled, which is what keeps the layout
-- tests still: `F.now` never advances under the harness, and a client reaches
-- its first menu long after its first frame.
local page_depth, page_at, page_dir = 1, 0, 0

local function page_slide(depth)
    if depth ~= page_depth then
        -- A step onto or off the root does not slide. At the root the stage is
        -- already a preview of the page the lit tab leads to, so stepping into
        -- that page changes which row the cursor is on and nothing else: the
        -- rows are the same rows. Sliding a panel the width of the drawer for
        -- that reads as a second drawer arriving over the first, which is what
        -- it was reported as, and it happened every time a hand walked up out
        -- of the tabs and back down into them.
        --
        -- Deeper than that it is a reading arriving over the page that opened
        -- it, which is a different surface and does slide.
        local shallow = depth <= 2 and page_depth <= 2
        page_dir = (not shallow) and (depth > page_depth and 1 or -1) or 0
        page_depth, page_at = depth, F.now
    end
    if F.now <= 0 or page_dir == 0 then return 0 end
    local t = math.min(1, (F.now - page_at) / DRAWER_SPAN)
    if t >= 1 then
        page_dir = 0
        return 0
    end
    -- In from the right on the way down, in from the left on the way back.
    return page_dir * (1 - drawer_ease(t))
end

function M.menu(v)
    M.menu_drawn = true
    F.case = "sentence"
    local was_scale = F.scale
    -- The column draws larger wherever there is room for it. A phone is
    -- already showing as much as it can, so it keeps the scale the rest of the
    -- interface uses; anything wider gets the whole menu a quarter larger,
    -- column included. Restored at the end of the function, because everything
    -- drawn after the menu is the arena's and is not a menu.
    if not M.compact then F.scale = was_scale * MENU_SCALE end

    -- A question takes the keys off whatever asked it, and the panel says so
    -- by standing down. It has to be set before a word of it is written: a
    -- glyph carries the alpha it was queued with, and the gui draws it over
    -- every mesh whatever is laid on top afterwards.
    F.text_dim = v.ask and 0.1 or 1
    -- The window, in the browser's own points rather than the menu's. What
    -- these two decide is what shape the window is, and a menu that has just
    -- made its own pixels bigger would answer that question with its own
    -- zoom in it: at 1.25 a 600 point window reports as 480 and takes the
    -- layout a short screen gets.
    local pts_w, pts_h = F.w / F.density, F.h / F.density
    -- Where the column stands, which is the whole of the menu's layout.
    --
    -- It is drawn at a phone's own measure wherever it stands: a head carrying
    -- the name and the call sign, the page under it, and the way in over the
    -- six stops at its foot. A window narrower than that measure gives it
    -- everything, which is what a phone held upright already did. A window
    -- wider docks it against the left edge and keeps the fight beside it, so
    -- a ship or a zone can be changed without leaving the stands.
    --
    -- There were two layouts here, a tab bar under a thumb below 620 points
    -- and a row of words across the top above it, and they disagreed about
    -- where the tabs went, what the type was set in, and whether there was a
    -- second column. One drawing stood in one place is what replaces them.
    -- See .design/menu-unify.
    local dock = math.min(DOCK_W * F.scale, F.w - F.safe_l - F.safe_r)
    -- How far in the drawer is, and which way it is heading.
    --
    -- A clock that has not moved has nothing to animate over, so with `F.now`
    -- at zero the drawer is drawn settled where it is heading. That is the
    -- test harness, which never advances it; a client reaches its first menu
    -- long after its first frame, since nothing opens the menu but a player.
    local want = v.open == false and 0 or 1
    if want ~= drawer_to then
        drawer_from, drawer_to, drawer_at = M.drawer, want, F.now
    end
    if F.now <= 0 then
        M.drawer = want
    else
        local step = math.min(1, (F.now - drawer_at) / DRAWER_SPAN)
        M.drawer = drawer_from
            + (drawer_to - drawer_from) * drawer_ease(step)
    end
    -- A finger holding the drawer overrides the clock: it is where the thumb
    -- has put it until the thumb lets go.
    drawer_w = dock
    local slide = drawer_held()
    -- Off the left edge by whatever is left of the slide.
    local dx = F.safe_l - (1 - slide) * dock
    drawer_x = dx
    -- A drawer on its way out answers nothing. It is drawn, because that is
    -- the whole point of drawing it, but the menu is shut and the game under
    -- it is live: every box below this line is taken back at the end so a
    -- press during the slide reaches the arena rather than a panel that has
    -- already gone.
    local shutting = v.open == false
    local hits_before = #M.hits
    -- Whether the column is the window. The one thing still worth asking about
    -- shape: what it decides is whether there is a fight beside the column for
    -- the wash to stay off, and whether the column's right edge needs a rule
    -- to say where it ends.
    local covers = dock >= F.w - F.safe_l - F.safe_r - F.scale
    -- Whether there is height to spend. A phone held sideways is 390 points
    -- tall, and the head and the foot take a third of that before a page is
    -- drawn, so what is left over decides whether anything but the page fits.
    local short = pts_h < 500
    local rail = v.rail or {}
    local n = #rail
    -- The roster of the room the menu is standing over, for the column beside
    -- the page. The scoreboard fills this list while a client is in a game
    -- and the arena draws no instruments of its own behind a menu opened from
    -- the stands, so it is refreshed here for both.
    if v.arena then
        refresh_players(v.arena.pilots, v.arena.watchers,
                        v.arena.side, v.pilot and v.pilot.name)
    end

    -- The column stands over whatever the interface drew under it, so the
    -- boxes that furniture published have to go with the pixels. `M.pick`
    -- breaks a tie on publish order and the HUD publishes first, so a box
    -- covered by the column still wins the press that landed on the column:
    -- a hand reaching for the head of this panel would have found the MENU
    -- key underneath it and shut the thing it was aiming at.
    --
    -- Boxes the column covers outright, which is the honest reading of what a
    -- panel over something does. One that runs past the column's edge keeps
    -- the part of itself that is still showing, and answers there.
    if not shutting then
        local kept = {}
        for _, r in ipairs(M.hits) do
            if r.x < dx - F.scale or r.x + r.w > dx + dock + F.scale then
                kept[#kept + 1] = r
            end
        end
        M.hits = kept
        hits_before = #M.hits
    end

    -- Not a curtain. Over an arena you can see the fight you left, and that
    -- you are still in it. There is always one behind this now: the stands
    -- are the front end, so a menu opened there is a panel over a room like
    -- any other, and the wash that used to be lighter over a starfield has
    -- one weight because there is one thing it is ever drawn over.
    local reading = v.social or v.item or v.points
        or v.newbuild or v.settings or v.at == "controls" or v.at == "about"
        or v.at == "pilot"
    -- The ground under the column, and nothing outside it. The wash used to
    -- take the window, which is what a panel that is the window wants and the
    -- wrong answer for one standing beside a fight: everything that is not
    -- the column is the game, drawn at the weight the people in it see.
    local base = reading and 0.9 or 0.86
    rect(dx, 0, dock, F.h, pal.rgb(0x03050a, base))
    -- Where the column stops, said out loud. Only where something else is
    -- showing: a rule down the edge of a window is a rule against nothing.
    if not covers then
        F.layer:seg(dx + dock, ry(0), dx + dock, ry(F.h), F.scale,
                    pal.a(pal.RADAR_TILE, 0.6), true)
    end

    -- What the column keeps off its own edges.
    local margin = 14 * F.scale
    -- The head: the name at one end of that line and the call sign at the
    -- other. Inside the top inset rather than under it, because a notch over
    -- a wordmark is a wordmark nobody can read.
    local head = (short and 48 or 56) * F.scale
    -- The foot: the six stops, on the bottom edge, with the surface running
    -- under the home indicator and only the marks and words held clear of it.
    -- The height a phone's tab bar already had, because that is what the
    -- clearance under the labels is measured against and those numbers were
    -- settled against real insets. See client/tests/safe_test.lua.
    local foot = 78 * F.scale

    local rx, ry_, rw, rh          -- the rail
    local icon_dy                  -- the mark's drop inside it
    local sx, sy, sw, sh           -- the stage
    local logo_y                   -- the line the head's controls sit on
    -- What the panel covers, name included: everything a press may land on
    -- without meaning to leave. Published as one box at the end, so the
    -- gaps between rows are not a way out of the menu.
    local px0, py0, px1, py1
    -- One arrangement, and it puts the tabs in a row along the foot of the
    -- column, where a thumb reaches them and where a desktop reads them as
    -- the bottom of a panel rather than the top of a bar.
    --
    -- The rail was a column down the left for a long time, with the page
    -- beside it, and then a row that changed ends depending on the window.
    -- How far a lit tab's field reaches past its mark: down to the bottom
    -- edge, so the lit stop is a tab reaching the end of the glass rather
    -- than a panel floating over the indicator.
    local tab_h

    rh = foot
    rw = dock
    rx = dx
    -- The tab bar sits on the bottom edge, with the surface running under the
    -- home indicator and only the marks and words held clear of it.
    --
    -- The inset stands in for the padding the block already keeps rather than
    -- stacking on top of it. Stepping the whole rail up by the whole inset put
    -- the words 56 points off the bottom of a phone, which is the same
    -- interface-come-loose-from-the-edge the page margin used to give, and is
    -- what a hardware inset looks like when it is added to a gap that was
    -- already there.
    --
    -- The full-height iPhone canvas puts the rail on the physical bottom edge,
    -- so lift its furniture ten points in portrait and let the labels off the
    -- glass. The rail surface and hit targets still run to the edge.
    local portrait_lift = pts_h > pts_w and 10 * F.scale or 0
    local base_icon_dy = 30 * F.scale
    icon_dy = base_icon_dy - portrait_lift
    local under = rh - base_icon_dy - 24 * F.scale
    if F.installed then
        -- Installed, the padding under the words is measured against the
        -- indicator rather than against the rail, because the indicator is the
        -- only thing down there and the rail's own idea of a bottom margin was
        -- written for a row with a toolbar under it. Two thirds of the strip
        -- is what the bar and its own margin take; the rest was the row
        -- sitting higher than it had to, and it goes back. On a large phone
        -- the rail's padding grows with the interface while the indicator
        -- stays 34 points whatever the screen, so this gives back more the
        -- bigger the phone, which is where the gap looked worst.
        --
        -- Never more than the indicator itself, because the give-back is
        -- measured against it and a device reporting no inset has nothing to
        -- measure. Without that cap the arithmetic cancelled exactly at
        -- SB = 0: the whole of the rail's padding went back, which put the
        -- middle of the words on the bottom edge of the screen and cut every
        -- label in half. An Android PWA with button navigation reports no
        -- inset, and so does a phone with a home button.
        ry_ = F.h - rh + math.max(0, math.min(F.safe_b, under - F.safe_b * 0.56))
    else
        ry_ = F.h - rh - math.max(0, F.safe_b - under)
    end
    tab_h = F.h - ry_
    -- A rule across the top of the stops, which is what separates the row
    -- from the page over it.
    hrule(dx, ry_, dock)

    -- No key at the foot. A DEPLOY stood on the line above the stops, because
    -- the column covers the landing's PLAY NOW and a player who opened this to
    -- change a ship would otherwise have to walk back to the games list to get
    -- into the game already playing behind it. The games list is where that
    -- walk ended, and pressing the game is what it ended in: the row is the
    -- way in, by a tap or by enter, so the key was one control for an act the
    -- page already had.

    -- The head, and the page between it and the stops.
    --
    -- Every page carries it. The ship page and the four screens it opens used
    -- to put their own band on that line instead, taking the call sign and the
    -- rule off, on the argument that the longest page in the menu should spend
    -- nothing above the build. What that bought was a panel that jumped the
    -- height of its own head the moment a hand walked into the ship page from
    -- the rail, and one page where the x and the call sign were not where they
    -- are everywhere else. The band draws under the head now, and the arrows
    -- reach the account from the top of any page in the menu.
    local hy = F.safe_t
    logo_y = hy + head / 2
    sx, sw = dx + margin, dock - 2 * margin
    -- The stage begins at the rule, and what a page holds back from it is
    -- STAGE_TOP alone. Eight points used to be taken here and the rest taken
    -- again where the page starts, which is one gap written as two numbers in
    -- two places, and it is why nobody could say what the air under the head
    -- was meant to be.
    sy = hy + head
    -- Down to the rail. The stage used to stop fourteen points short of it
    -- and the room handed to a page took another twenty-six under that, so a
    -- key pinned at the foot of a page stood forty points clear of the tab
    -- row while the guest band beside it sat on the rule. Two of the three
    -- things this menu pins at a foot are bands, and a band with a strip of
    -- ground under it is a band that came loose. The page's floor is the rail
    -- now, and what wants air above the rule asks for it: see `room` below,
    -- and the two pages that pin furniture of their own.
    sh = ry_ - sy
    -- The guest banner: a band in the caution color standing on the rail,
    -- for a guest with something to lose, on every page but the one it
    -- points at. Words alone, and the whole band is the press. It takes its
    -- room off the page so no list runs underneath it.
    --
    -- The words stand in the column every page's type stands in rather than
    -- against the panel's own margin, six points further out. The friends
    -- page pins a band of the same shape, and where a guest opens that page
    -- the two are stacked: two bands beginning on two different lines, under
    -- a page beginning on a third.
    if v.banner then
        local bh = pages.BAND_H * F.scale
        sh = sh - bh
        local by = ry_ - bh
        rect(dx, by, dock, bh, pal.a(pal.CHARGE_COL, 0.08))
        F.layer:seg(dx, ry(by), dx + dock, ry(by), F.scale,
                    pal.a(pal.CHARGE_COL, 0.5), true)
        txt("You are using a guest account.", dx + MENU_PAD * F.scale,
            by + 16 * F.scale, TYPE.BODY * F.scale, pal.INK, nil,
            MENU_FONT)
        txt("Press here to set your password.", dx + MENU_PAD * F.scale,
            by + 33 * F.scale, TYPE.BODY * F.scale, pal.READ, nil,
            MENU_FONT)
        hit(dx, by, dock, bh, "pilot_page")
    end
    -- A rule under the head, so the x and the call sign read as a bar over the
    -- page rather than as the page's own first line. Edge to edge, since it is
    -- the underside of a head rather than the top of a list.
    hrule(dx, hy + head, dock)
    px0, py0, px1, py1 = dx, 0, dx + dock, F.h

    -- The call sign at the far end of the head first, so the name knows what
    -- room is left.
    --
    -- On every window and at every level, which is the point of one column.
    -- The account used to be reachable only from a corner a phone does not
    -- draw, and then it was dropped from any menu with a game behind it,
    -- because the corner stack held that corner. The column covers the corner
    -- stack now, so this head is the only place it can be and it carries it
    -- whatever is behind the panel.
    local head_end = pages.corner(v, dx + dock - margin, logo_y)
    -- And the state of the line just inside it. It used to stand in the top
    -- right of the arena, which is the corner the dial owns; it is a fact
    -- about this client rather than about the fight, so it belongs on the row
    -- that already carries who you are. See `pages.link`.
    --
    -- What the near end of this line is holding is the way out, in the square
    -- the menu key had at the same inset, and it is drawn below with the page
    -- rather than here. The readout is told where that ends so it can stand
    -- down rather than be laid over it.
    pages.link(v.link_bars or 4, head_end - 12 * F.scale, logo_y,
               dx + margin + (KEY_H + KEY_GAP) * F.scale)
    -- The x is at the other end of it, drawn below with the page it belongs
    -- to. Nothing between them: the wordmark sat there on every page of the
    -- menu, turning, a picture of a name everybody reading this screen has
    -- already read, animating in the corner of a panel they opened to do
    -- something else. The landing still wears it, over the key it is a title
    -- for, which is the one place it says anything.

    -- Which of the three rows the arrows are in: the head over the page, the
    -- page, or the rail under it. They share one cursor and mark it with the
    -- same blue field, so the row wearing it is the answer to "what does up do
    -- here" without a word spent on saying it.
    local focused = (v.focus == "stage")
    local rail_focus = (v.focus == "rail")

    -- --- how far the page is scrolled
    --
    -- Clamped against what the page came to last frame, since only the page
    -- knows how tall it is and it does not know until it has drawn. A page
    -- that shrank under a scrolled finger is pulled back on the next one,
    -- which is a frame nobody sees.
    --
    -- And back to the top whenever the page changes, because a scroll belongs
    -- to what is being read: carried across, opening friends from the bottom
    -- of the ship page would open it halfway down.
    if v.at ~= M.page_at then
        M.page_at = v.at
        M.page_scroll = 0
    end
    -- Whether the cursor moved since the last frame, which is the only reason
    -- to pull the page out from under whoever is reading it. A page arriving
    -- counts: its scroll has just been put back to the top and the cursor may
    -- be anywhere in it.
    M.cursor_moved = (v.at ~= M.cursor_page) or (v.sel ~= M.cursor_sel)
    M.cursor_page, M.cursor_sel = v.at, v.sel
    -- Against the page's own window where it published one, and the stage
    -- otherwise. A page that has never drawn has published neither, and both
    -- being zero holds the scroll at zero, which is right.
    local slack = math.max(0, M.page_extent
                              - (M.page_room > 0 and M.page_room or sh))
    M.page_scroll = math.max(0, math.min(M.page_scroll, slack))
    M.page_x, M.page_y, M.page_w, M.page_h = sx, sy, sw, sh
    -- Whoever draws sets these. Nothing does on a page that fits, and the
    -- clamp above then holds the scroll at zero, which is what a page that
    -- fits wants.
    M.page_extent = 0
    M.page_room = 0

    -- --- the rail
    --
    -- One row: marks with words under them, each in its own lit field, sized
    -- so a thumb lands on one. It was two objects, this and a line of words
    -- beside the mark on a desktop, which is a second thing to draw and a
    -- second thing to learn for a row that says the same six words either way.
    -- The column is a phone's measure on every window now, so the row a phone
    -- wanted is the row.
    -- A rail with nothing on it is not a thing the menu builds, and a division
    -- by the count of it is not a thing to find out about in a released
    -- client: an infinite pitch draws nothing and lays a hit box over the
    -- whole foot of the column.
    local pitch = n > 0 and (rw / n) or rw
    -- Along the bottom, every stop says its name, and the words are sized so
    -- the longest of them fits the room one stop has. Only the lit one used to
    -- carry a word, because "settings" and "about" at the desktop's size run
    -- into each other with eight of them across a phone; a row of marks you
    -- have to learn by tapping is worse than a row of small words.
    local label_px = TYPE.BODY * F.scale
    -- The widest of them at one point, so the size that fits it in the room
    -- one stop has is a division. Counting characters and calling each one an
    -- advance was the same sum with the wrong face's number in it, and it set
    -- the row a point smaller than it had to be.
    local widest = 0
    for _, e in ipairs(rail) do
        widest = math.max(widest, text_w(e.label or "", 1, MENU_FONT))
    end
    if widest > 0 then
        label_px = math.max(8 * F.scale, math.min(label_px,
                            (pitch - 5 * F.scale) / widest))
    end
    for i, e in ipairs(rail) do
        local sel = (i == v.rail_sel)
        -- Where a pointer is resting, which at the root is the stop the
        -- cursor is already on and one level in is a second mark saying what
        -- a click would land on. The stage has worn this since the home
        -- screen was two panes; the rail is the other half of the same
        -- gesture and went without it.
        local hot = (i == v.rail_hover) and not sel
        local cx = rx + (i - 0.5) * pitch
        local cy = ry_ + icon_dy
        local col = (sel or hot) and pal.FRIEND or pal.MUTE
        local r = 13 * F.scale
        if hot then
            -- The list's own cursor weight, and only the field: the lit stop
            -- says which page the panel belongs to, and a pointer passing
            -- over says nothing of the kind. A stop is not a row, so the
            -- field is its own slot.
            rect(cx - pitch / 2 + 3 * F.scale, ry_, pitch - 6 * F.scale,
                 tab_h, pal.a(pal.FRIEND, LIT.CURSOR))
        end
        if sel then
            -- The lit one. Brighter while the arrows are in the rail, down to
            -- the weight the stop keeps for saying where you are once they
            -- have gone into the page.
            --
            -- Down to the edge of the screen rather than to the end of the
            -- block, so the lit stop is a tab reaching the bottom of the glass
            -- and not a panel floating above the indicator.
            rect(cx - pitch / 2 + 3 * F.scale, ry_, pitch - 6 * F.scale,
                 tab_h, pal.a(pal.FRIEND, rail_focus and 0.22 or 0.06))
        end
        draw_mark(e.icon, cx, cy, r, col, v.class or 0)
        -- The quiet half of the guest warning: a spark on the stop the
        -- banner points at, carried wherever the banner itself is not.
        if v.guest_dot and e.label == "pilot" then
            F.layer:disc(cx + 11 * F.scale, ry(cy - 9 * F.scale),
                         2.4 * F.scale, 10, pal.CHARGE_COL)
        end
        txt(e.label, cx, cy + 24 * F.scale, label_px,
            (sel or hot) and pal.FRIEND or pal.MUTE,
            "center", MENU_FONT)
        -- The rail's own action: it names a destination, not a row of
        -- whatever page is on the stage.
        hit(cx - pitch / 2, ry_ - 8 * F.scale, pitch, tab_h + 8 * F.scale,
            "rail", i)
    end

    -- --- the stage
    -- Everything with type in it stands in the one column: MENU_PAD in from
    -- edge of the drawer, so a row's name and a row's price begin and end on
    -- the same two lines, and so does the rule of the section above them.
    -- A row's lit field is still the whole drawer, which is what makes the
    -- column read as type on a panel rather than as a box inside one.
    local tx = dx + MENU_PAD * F.scale
    local avail = dock - 2 * MENU_PAD * F.scale
    -- The stage is the stage, whatever is on it. A list used to be capped at
    -- 520 points against a row reading as two columns a screen apart, which
    -- was a rule written for a window rather than for this panel: the block
    -- is already held to 940, so the widest a row can ever be is about 740,
    -- and the cap bought nothing but a ragged right edge. It ended a couple
    -- of hundred points short of the x, the rule and the scrollbar, and the
    -- pages that are drawings rather than lists went to the edge beside it.
    --
    -- The column is the column, scroll tick or no scroll tick. It used to hold
    -- fourteen points back at the right for one, so a list did not shift
    -- sideways the moment it outgrew the page, which put every row's count
    -- fourteen points inside the line its name started on. The tick draws out
    -- in the margin MENU_PAD keeps clear instead, where nothing else is, and
    -- that outgrows its page still does not move.
    local lw = avail
    -- And a cap on a list, which came back when the tabs moved to the top.
    -- The cap was dropped while the block was a rail plus a stage and the
    -- widest a row could be was about 740 points; the stage is the whole
    -- block now, and a row running the width of a desktop window puts a name
    -- at one edge and its value at the other, which is two columns nobody
    -- reads as one line.
    --
    -- Lists only. The hull grid is a drawing, and it takes everything there is.
    local listy = not v.kit
        and not (v.rows and v.rows[1] and v.rows[1].hull)
    -- A page is a panel: a translucent ground hung off a lit rule down its left
    -- edge, with the light spilling across it. It is the shape every
    -- instrument in the arena already has, and the one thing the menu was
    -- still drawing without. No border, because a box is the shape this game
    -- does not contain.
    --
    -- It fills the block. The list inside it keeps a measure, because a row
    -- whose name sits at one edge and whose count sits at the other is two
    -- columns nobody reads as one line, and in a column this wide the two are
    -- the same number.
    --
    -- Nothing stands beside the list any more. The aside was a second column
    -- carrying the room's roster, drawn only where the panel had 700 points
    -- to spare, which is a thing that existed on a monitor and nowhere else.
    -- The column is 390 points on every window now, so what the aside held is
    -- drawn under the rows instead, where there is room for it. See `asidey`.
    -- A page is handed the column and nothing else, so the pages that draw
    -- themselves and the list that draws rows begin and end on the same two
    -- lines. It used to be handed the panel's own margin as its left edge and
    -- a width short of the column at the right, which is how the hangar's
    -- names came to start six points outside every name on the games list.
    local panel_x, panel_w = tx, avail
    -- Where in its slide this page is, if it has just arrived. Everything the
    -- page draws and every box it publishes moves with it, which is what
    -- makes a press during the slide land on what the finger is over.
    local slid = page_slide(v.depth or 1) * dock
    panel_x, tx = panel_x + slid, tx + slid
    -- And cut against the column's own right edge while it moves.
    --
    -- A page arriving from the right starts a full drawer width outside the
    -- column, and on a window wider than the column there is nothing at that
    -- edge to hide it: the reading was drawn over the fight and then walked
    -- back in over it. Cut against that edge, the page comes out from behind
    -- the column instead.
    --
    -- Only while it moves. A settled page stands inside the column and has
    -- nothing to lose to a cut, and every layout check in the suite draws on
    -- a clock that never advances, so what they measure is what ships.
    --
    -- One edge, not two. The column is docked against the leading edge of the
    -- window, so a page stepping back leaves past the glass rather than past
    -- the fight, and there is nothing on that side worth cutting against.
    if slid ~= 0 then
        F.clip_r = dx + dock
        F.layer:clip(F.clip_r)
    end
    if listy then lw = math.min(lw, 560 * F.scale) end
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
    -- On the head's own line, at the near end of it, in the square the menu
    -- key had at the same inset: pressing the menu key and pressing the x are
    -- one control seen from either side, so a hand that learned where one of
    -- them was has learned the other. It sat at the top of the stage, which on
    -- the desktop layout was a third of the way down the panel and level with
    -- nothing.
    --
    -- Against the block's own edge rather than the list's: the list is capped
    -- at 560 points and the x hung off the end of it, which was the right
    -- place under a heading and is a mark adrift in the middle of a title.
    if v.closable then
        local box = KEY_H * F.scale
        -- Lit while the arrows are on it, the way the call sign at the other
        -- end of this line is: the two are one row and they wear one cursor.
        local shut_on = v.head_sel == "close"
        if shut_on then
            wash(dx + margin, logo_y - box / 2, box, box,
                 pal.a(pal.FRIEND, LIT.CURSOR))
        end
        close_mark(dx + margin + box / 2, logo_y,
                   pal.a(shut_on and pal.FRIEND or pal.DIM,
                         shut_on and 1 or 0.9), 11 * F.scale)
        hit(dx + margin, logo_y - box / 2, box, box, "close")
    end
    -- A page with a heading starts its heading where a page without one
    -- starts its first row, which is what this used to spend a second number
    -- on getting near: ten under the stage for a page carrying a band or a
    -- head, thirty for a list. Both wanted the same line and neither landed on
    -- it. One line now, and each page's first object stands on it: a row's
    -- lit field, the ship page's band, the friends box's label. What that
    -- object centers inside itself falls where it falls.
    local top = sy + STAGE_TOP * F.scale
    -- And the room under it is the rest of the stage, less the one line
    -- drawn across the foot of it. That line is a refusal on the ship page or
    -- a confirmation on the bindings page, both of them answers to a press
    -- somebody just made, so nearly every frame of nearly every page has
    -- nothing to put there. The room is kept back when there is something to
    -- say rather than on every page forever, which is what it was: twenty-six
    -- points of nothing at the bottom of every screen in the menu.
    local room = sh - (top - sy)
                 - ((v.note or v.foot) and pages.FOOT_LINE or 0) * F.scale
    -- A heading, on the one page that has one. The lit stop on the tab row is
    -- the title everywhere else, and it stops being one as soon as a page is
    -- about a thing you chose on the page before: over the kit it says
    -- "hangar", which is the room rather than the ship on the bench.
    --
    -- The hull is drawn beside its name for the same reason it is drawn in the
    -- grid you picked it from: eight names is a list to read and eight
    -- outlines is a shape to recognise, and the page you land on should be
    -- wearing the one you just pressed.
    if v.head and not v.kit then
        -- One line of it. Stacked, the name and the trade cost a row off the
        -- list below, and a kit page that has to scroll to reach the last
        -- charge is a page that cannot be read in one look.
        local hh = 40 * F.scale
        local name = v.head.label or ""
        local size = TYPE.LEAD * F.scale
        -- Where the heading's own baseline sits. Named for what it is rather
        -- than `base`, which is the panel's wash weight a few hundred lines
        -- up: two different numbers under one name in one function.
        local head_y = top + hh * 0.56
        -- A hull where the page is about one, and nothing where it is not:
        -- the upgrades heading is a wallet and has no ship in it.
        local nx = tx + 4 * F.scale
        if v.head.hull then
            thumb(tx + 16 * F.scale, head_y - 5 * F.scale, v.head.hull,
                  pal.a(pal.FRIEND, 0.95), hh / 78)
            nx = tx + 40 * F.scale
        end
        txt(name, nx, head_y, size, pal.INK, nil, MENU_FONT)
        if v.head.role then
            txt(v.head.role, nx + text_w(name, size, MENU_FONT) + 10 * F.scale,
                head_y, TYPE.LABEL * F.scale, pal.MUTE)
        end
        top = top + hh
        room = room - hh
    end
    -- One dim line over the list, on a page whose rows do not explain
    -- themselves. Set in the small face the section labels are set in, so it
    -- reads as the page talking rather than as a row you can land on: it is
    -- not in `rows` and the cursor never touches it.
    if v.lede then
        -- Wrapped to the list's own measure. One line is what it is on a
        -- monitor and two on a phone, where it ran off the right edge and the
        -- sentence stopped mid-word.
        local px = TYPE.BODY * F.scale
        local lines = wrapped(v.lede, px, lw, MENU_FONT)
        local lh = pages.NOTE_LINE * F.scale
        for i, line in ipairs(lines) do
            -- Only the first line is a sentence opening. The menu capitalizes
            -- the first letter of whatever it is handed, and handed two lines
            -- it capitalized both: "as / Soon as they add you back".
            txt(line, tx, top + 10 * F.scale + (i - 1) * lh, px,
                pal.READ, nil, MENU_FONT, i > 1)
        end
        local used = #lines * lh + 12 * F.scale
        top = top + used
        room = room - used
    end
    -- A list is capped: a row whose name sits at one edge and whose count
    -- sits at the other, a screen apart, is two columns nobody reads as one
    -- line. The board and the hull grid are drawings and take everything.
    --
    -- Nothing is drawn across the head of it. A ticked rule sat there, the
    -- one the map border is made of, introducing a list that needs no
    -- introducing: the rail says what the page is and the rows say what they
    -- are, and the rule was a third line of furniture between them.
    if v.kit then
        -- The ship page: every slot this arena has, and the thirty points on
        -- it. The same left edge every other page has. It began at the
        -- panel's own rule while the others began a gutter in from it, which
        -- is a quarter inch of difference nobody can name and everybody can
        -- see when they walk the tab row.
        pages.kit(v, panel_x, top, panel_w, room, focused)
    elseif v.social then
        -- Friends, as a field over sections whose rows carry buttons.
        pages.friends(v, panel_x, top, panel_w, room,
                      focused)
    elseif v.builds then
        -- The library, behind the band's name key.
        pages.builds(v, panel_x, top, panel_w, room, focused)
    elseif v.newbuild then
        -- Naming one, a slide further right.
        pages.newbuild(v, panel_x, top, panel_w, room,
                       focused)
    elseif v.points then
        -- What the thirty are, behind the band's meter.
        pages.points(v, panel_x, top, panel_w, room)
    elseif v.item then
        -- One slot, read: where a press on a row's name lands.
        pages.slot(v, panel_x, top, panel_w, room, focused)
    elseif v.pilot_card then
        -- Who you are and the way to keep it, drawn rather than listed.
        pages.pilot(v, panel_x, top, panel_w, room, focused)
    elseif v.rows and #v.rows > 0 and v.rows[1].hull then
        ship_grid(tx, top, avail, room, v, focused)
    else
        -- Two lines of room where the rows have two lines in them, held to
        -- one height either way so nothing shifts as the cursor walks down.
        local noted = false
        for _, r in ipairs(v.rows) do
            if r.note then noted = true break end
        end
        -- And a second line of room where a row carries its format strip:
        -- the name, and the stacks under it. One height for the whole list,
        -- as above, so the games read down the same columns.
        local specced = false
        for _, r in ipairs(v.rows) do
            if r.specs then specced = true break end
        end
        -- Whatever the longest sentence in the list needs beyond one line. A
        -- row is as tall as the tallest, so a list does not change pitch
        -- halfway down; the sentence that wraps is usually the only one, and
        -- the rows above it keep their own single line centered.
        local wrapped_extra = 0
        for _, r in ipairs(v.rows) do
            local lines = pages.note_lines(r.note, lw, r)
            if lines and #lines > 1 then
                wrapped_extra = math.max(wrapped_extra,
                                         (#lines - 1) * pages.NOTE_LINE)
            end
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
        local SECT = pages.SECT * F.scale
        local rowh = math.min((wrapped_extra + (specced and 70 or noted and 58
                               or (M.compact and 46 or 40))) * F.scale,
                              math.max(30 * F.scale,
                                       (room - heads * SECT)
                                       / math.max(#v.rows, 1)))
        -- The list starts at the top, on every screen.
        --
        -- It was centred in the room on a phone, on the argument that three
        -- games hung under a title leave the screen looking half loaded. What
        -- that produced with one game in the directory was a single row
        -- floating in the middle of eight hundred points of nothing, above
        -- and below, which reads as a page that failed to draw rather than as
        -- a short list. A list against the top with the tab bar closing the
        -- bottom is the shape every phone already uses, and the void sits
        -- where a void reads as "that is all of them".
        local ty = top
        -- A list longer than the room it has scrolls, and the cursor drags it
        -- rather than walking off the bottom edge. Rows past the end used to
        -- be skipped, which is a list that quietly stops being the list: a
        -- fleet with a dozen games would have shown seven of them and said
        -- nothing about the rest.
        --
        -- Scrolled in pixels rather than jumped in rows, because a finger
        -- drags a page and a wheel notch is a couple of rows: the offset the
        -- arena moves is the offset every page reads, and this one used to
        -- have its own idea derived from the cursor alone. A list on glass
        -- could therefore only be moved by tapping a row, which is a list you
        -- have to select your way down.
        --
        -- How tall it comes to, and where the cursor sits inside it, from one
        -- walk: a section head is height, and only the walk knows where the
        -- heads fall.
        local full, cur_at = 0, nil
        for i, r in ipairs(v.rows) do
            if r.sect then full = full + SECT end
            if i == v.sel then cur_at = full end
            full = full + rowh
        end
        M.page_extent = (top - sy) + full + 20 * F.scale
        -- This one measures from the top of the stage, because its rows do,
        -- so its window is the stage down to the end of the list.
        M.page_room = (top - sy) + room
        -- The arrows still drag the page rather than walking off the edge of
        -- it, which is what a d-pad and a keyboard need and what a finger
        -- does not care about either way.
        if cur_at and focused then
            if cur_at < M.page_scroll then M.page_scroll = cur_at end
            if cur_at + rowh > M.page_scroll + room then
                M.page_scroll = cur_at + rowh - room
            end
        end
        local at = ty - M.page_scroll
        for i, r in ipairs(v.rows) do
            -- A head belongs to the row under it, so it is drawn with that
            -- row rather than laid out in advance: a list that scrolls keeps
            -- the labels it can still show and drops the ones it cannot.
            if r.sect and at >= ty and at + SECT <= ty + room then
                -- To the same right edge the row's own numbers sit on. It
                -- stopped four points short of them, which is three
                -- different right edges down one page once the selection
                -- field is counted.
                hrule(tx, at + SECT * pages.SECT_RULE, lw)
                lbl(r.sect, tx, at + SECT * pages.SECT_LABEL)
                at = at + SECT
            end
            local y = at
            at = at + rowh
            -- Whole rows only. The column's scissor is a vertical edge and
            -- cuts nothing off the top of a list, and type comes from the gui,
            -- which draws over every mesh this file lays down, so nothing
            -- behind the heading can cover a row that has slid under it.
            if y >= ty - F.scale and y + rowh <= ty + room + F.scale then
                -- The cursor, from whichever hand is on it. A pointer resting
                -- on a row of a page moves the cursor there rather than
                -- lighting a second row, so `hover` only ever arrives on the
                -- home screen, where the cursor belongs to the rail and the
                -- stage is a preview of what the mark beside it holds.
                stage_row(tx, y, lw, rowh, r,
                          (focused and i == v.sel) or i == v.hover,
                          i, v.row_hot == i and v.row_hot_act)
                if r.pick then
                    -- The whole width of the panel, which is what the lit
                    -- field covers: a press that missed by a margin the eye
                    -- was told is part of the row is a press that missed
                    -- nothing.
                    local hx, _, hw = M.drawer_span()
                    hit(hx, y, hw, rowh, "stage", i)
                end
            end
        end
        -- What is off the ends. It says there is more without spending a row
        -- on saying so.
        if M.page_extent > room + (top - sy) then
            local bar = 3 * F.scale
            local hgt = math.max(30 * F.scale, room * room / full)
            local scrolled = (M.page_scroll / math.max(1, full - room))
                             * (room - hgt)
            -- Out in the margin, centered in what MENU_PAD holds clear, rather
            -- in a column cut out of the type. It is furniture about the page
            -- rather than a thing on it, and the row that used to give up
            -- fourteen points for it gets them back.
            local bx = tx + lw + (MENU_PAD * F.scale - bar) / 2
            rect(bx, ty, bar, room, pal.a(pal.DIM, 0.14))
            rect(bx, ty + scrolled, bar, hgt, pal.a(pal.RADAR_TILE, 0.85))
        end
        -- Under whatever rows there are, which over a game is the one row
        -- that leaves it.
        if v.empty then
            -- Under whatever the list came to, which is where `at` has walked
            -- to. It was a separately computed height and the two drifted
            -- apart the moment the list stopped being centred.
            local ey = at + 12 * F.scale
            empty_state(tx, ey, lw, top + room - ey, v.empty)
        end
    end
    -- The page is drawn, so whatever was cutting it stops here: the foot and
    -- the way out below stand still and belong to the column either way.
    if F.clip_r then
        F.clip_r = nil
        F.layer:unclip()
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
    -- Wrapped to the stage's own measure, and climbing rather than growing
    -- down: the foot is the foot. Written as one line whatever it said, "press
    -- a key for repel, or two together; escape leaves it alone" ran off the
    -- right of a phone with the last four words missing.
    local said = v.note or v.foot
    if said then
        local px = TYPE.BODY * F.scale
        local col = v.note and pal.HURT or pal.READ
        -- Cased once over the whole sentence and drawn raw, since `txt`
        -- would capitalise each line it was handed and a wrapped sentence
        -- would come out with a capital in the middle of itself.
        local lines = wrapped(cased(said), px, sw - 8 * F.scale, MENU_FONT)
        -- Standing in the room `room` kept back for it, which is measured
        -- from the rail: the stage runs to the rule now, so a line four
        -- points off the end of it would be drawn half under the tab row.
        local fy = sy + sh - 14 * F.scale - (#lines - 1) * pages.NOTE_LINE * F.scale
        for _, line in ipairs(lines) do
            txt(line, tx, fy, px, col, nil, MENU_FONT, true)
            fy = fy + 16 * F.scale
        end
    end

    -- A press that missed everything is a press on the arena behind, and over
    -- a game that means put me back in it, which is what escape does and what
    -- a hand reaches for after opening this by accident. Two boxes: the panel
    -- swallows its own, so the space between two rows is not a way out, and
    -- everything left over is one.
    --
    -- Two backdrops, ranked rather than ordered: the panel stands behind
    -- every control on it and the way out stands behind the panel, so a
    -- dimmed scoreboard row still answers to a click rather than being a
    -- hole in the way out.
    if v.closable then
        hit(px0, py0, px1 - px0, py1 - py0, "panel", nil, nil, -1)
        hit(0, 0, F.w, F.h, "close", nil, nil, -2)
    end

    -- Last, over all of it, because it is the only thing being read.
    -- It takes the screen, boxes included: a question is answered, not
    -- clicked past.
    if v.ask then ask_card(sx, sy, sw, sh, v.ask) end
    -- Everything this drew answers a press only while the menu is open. See
    -- `shutting`.
    if shutting then
        for i = #M.hits, hits_before + 1, -1 do M.hits[i] = nil end
    end
    F.case = "upper"
    F.scale = was_scale
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
