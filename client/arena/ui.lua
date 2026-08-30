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
-- Four, and each one has a job. LABEL is the upper case register that names a
-- group or a column of figures. BODY is everything small that is being read:
-- a sentence, a detail, a price, a word in a button, a tab. ROW is a name in a
-- list, and LEAD the same name where it heads a sentence or a strip of
-- figures.
--
-- A fifth stood over those, PAGE, for what a page called itself. The pilot
-- page's call sign was the last thing set in it, and a card's code the last
-- reference: both went with decision 99, and a rung nothing stands on is a
-- rung to delete.
--
-- The gap from LABEL to BODY is smaller than the rest of the ladder on
-- purpose. Upper case reads larger than lower at the same size, so a caps
-- label set level with the body it names looks heavier than it.
local TYPE = {LABEL = 12, BODY = 14, ROW = 17, LEAD = 21}

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
-- Which of the landing's stops has its list open: "account", "zone", "ship",
-- or nil for none of them. All three open lists in place. Account used to be
-- the exception, a door into the drawer's pilot page, and that page is gone:
-- what it held is a list like the other two. Owned by this module the way
-- `rooms_open` is: the arena flips it on a press and everything that leaves
-- the landing clears it.
M.col_open = nil
-- Where a press would land on the landing: the action a box publishes, and
-- the value that box carries so one row of an open list is told from the next.
--
-- One cursor, moved by either hand, which is the rule a page of the menu
-- follows. The pointer takes it through the same `M.pick` a press goes
-- through, so a row lights instead of the stop behind it and a pointer over
-- an open list's ground lights nothing at all; the arrows walk it through
-- `M.col_step` and enter presses whatever it names. Nil for nothing lit,
-- which is where the screen starts and what leaves enter meaning the key.
M.col_sel, M.col_sel_value = nil, nil

-- --- primitives ------------------------------------------------------------

local function ry(y, h)
    return F:ry(y, h)
end

local function rect(x, y, w, h, col)
    F.layer:rect(x, ry(y, h), w, h, col)
end

-- Frost: this box's worth of the scene behind it, blurred.
--
-- A panel over a live fight used to dim what was under it and nothing else, so
-- a stop with a rock passing behind it had a rock in it, sharp, competing with
-- the word it was there to hold. Frosting is what a pane of glass does: the
-- light comes through and the picture does not. The wash and the frame go over
-- the top exactly as they did, and this is the ground they now sit on.
--
-- At alpha one the box holds the blurred scene alone; below one, some of the
-- sharp picture comes through with it. Its own layer because it is its own
-- material, and the blurred copy it reads is made by the render script, which
-- is the only thing that can read a frame it has just drawn.
local function frost(x, y, w, h, a)
    if not F.frost then return end
    -- The rule the hit boxes follow, for the reason they follow it: what the
    -- column has cut away is not on screen, and glass past that edge would be
    -- a blurred stripe lying over the fight beside it.
    if F.clip_r then
        if x >= F.clip_r then return end
        if x + w > F.clip_r then w = F.clip_r - x end
    end
    F.frost:rect(x, ry(y, h), w, h, pal.a(pal.WHITE, a or 1))
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
-- on it are drawn by things a long way above them, and a local declared after
-- its first use is a global lookup that comes back nil.
local pages = {}

-- And the one that cuts a run of type against the column's edge, which `txt`
-- reaches several hundred lines before there is a way to measure a string.
local clip_run

-- The one row. Every menu in this game is a panel, every panel is rows, and
-- this draws all of them: the games list, the account acts, a hull's slots,
-- the settings page, the sides. It is declared here and written a long way
-- down, beside the pages whose vocabulary it grew out of, because the
-- landing's panels reach it several hundred lines before that.
--
-- What varies between two rows is the right hand end and nothing else. See
-- `menu_row` for the six of them.
local menu_row

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
    -- Cleared rather than left, because these tables are pooled and reused
    -- frame to frame: a node that was turned once and is not this time would
    -- otherwise keep the angle forever. See `arc_txt`, the one caller that
    -- ever sets it.
    t.rot = nil
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
-- The menu's own buttons wore two other shapes until now. Some were drawn
-- with `bracket` above, which is what holds a cluster together, and
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
-- was unfocused, a band inset sixteen points either side, the
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

-- One row of the menu, lit. The field is the panel, edge to edge, and the hit
-- box every page publishes is the same span: what lights up is what a press
-- lands on.
--
-- It used to take the drawer's own span off a module field, which worked while
-- there was exactly one panel in the interface and one place it could be. The
-- column's panel stands where its stop stands, so the span is handed in.
function LIT.field(x, y, w, h, weight)
    -- Flat, all the way across.
    --
    -- It was `wash`: most of the weight laid flat with the rest put in a skirt
    -- against the left edge, falling off over a hundred and thirty points.
    -- That is what a selection looks like *against a lit rule*, and it was
    -- written for the drawer, which was docked to the left of the screen and
    -- hung its rows off one. A panel is a floating rectangle outlined all the
    -- way round: there is no rule there for the accent to bleed off, so what
    -- it drew was a brighter quarter of the row with a visible edge where the
    -- falloff ran out, and on a panel five hundred and sixty points wide that
    -- edge lands a long way from anything that explains it.
    --
    -- The scoreboard and the plate keep the skirt, because they still hang off
    -- a `vrule` and it is still the right mark there.
    rect(x, y, w, h, pal.a(pal.FRIEND, weight))
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
-- Published so the tests measure the ladder rather than restating it, and so
-- a page that needs to know how tall a line is asks the same table the drawing
-- asks. See client/tests/type_test.lua.
M.TYPE = TYPE

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

-- One run of type bent around a circle, a glyph at a time.
--
-- The mono face advances the same width for every glyph, which is what makes
-- this arithmetic rather than layout: each letter takes the same angle, so
-- the run is centered on `at` by stepping out half of what it spans and
-- walking round. Each glyph is set on the tangent, which is a quarter turn
-- off its own radius.
--
-- Worth the nodes it costs in exactly one place: the stick's rim, where the
-- thing being labelled is a circle and a straight line under it reads as a
-- caption for the screen rather than for the control. Every other label in
-- this interface is a straight run and should stay one.
local function arc_txt(s, cx, cy, r, at, px, col, flip)
    local step = px * ADVANCE / r
    -- UTF-8: the multiplication sign and the middle dot are two bytes each,
    -- and a run measured in bytes would spread the word out and turn the
    -- letters wrong.
    local glyphs = {}
    for ch in string.gmatch(s, "[%z\1-\127\194-\244][\128-\191]*") do
        glyphs[#glyphs + 1] = ch
    end
    local n = #glyphs
    if n == 0 then return end
    -- Under the circle the run reads left to right with the letters turned
    -- outward, so it walks the other way and each glyph is turned the other
    -- way with it.
    local dir = flip and -1 or 1
    local a = at - dir * step * (n - 1) / 2
    for i = 1, n do
        local gx = cx + math.cos(a) * r
        local gy = cy + math.sin(a) * r
        txt(glyphs[i], gx, F.h - gy, px, col, "center", nil, true)
        F.text[F.text_count].rot = a + dir * math.pi / 2
        a = a + dir * step
    end
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
-- The name a new build is given is the one this menu holds. It had a twin
-- once, six points apart in height, with different insets and only one of
-- them wiping on a press. A field is a field wherever it is, so this is the
-- field, and a page supplies the words and the actions.
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

-- The way into the menu, as the three bars the whole web uses for it, with
-- the word beside them.
--
-- It sits at the bottom middle, which is where the column it opens stands: the
-- press and what the press raises share a spot, the column slides up out of
-- this edge, and RESUME comes to rest on the key's own pixels. Pressing RESUME
-- hands the spot back. It spent a long time in the top left corner, where it
-- was a control detached from everything it did.
--
-- Faint, and the same faint on every window. This key lives inside the fight
-- rather than beside it, so at rest it is furniture: a pilot who has met the
-- screen once does not need it shouting, and one who has not is reading the
-- word rather than the weight. The word rides along on a phone as well, which
-- the corner never had the room for.
--
-- No box. `key_box` is the one shape a pressable thing wears here, and every
-- other one of them keeps it, but this key is not standing among them: it is
-- alone at the foot, over the fight in a seat and under PLAY NOW in the
-- stands, and in both places the box was the thing that read wrong. On the
-- landing it made a fourth stop under the three, since a stop is a box at
-- that width in that column. Over a match it made an instrument, since the
-- band, the dial and the corner chips are the boxes up there and a box at the
-- foot joins them.
--
-- The mark and the word carry it instead, which is what the footer line in
-- `.design/no-drawer` was already doing. What the box was buying was "this is
-- pressable", and the three bars say that on every screen anybody has used.
local BURGER = {w = 12, bar = 1.6, gap = 3.8, h = 22}
local function burger_w()
    return BURGER.w * F.scale + 3 * KEY_PAD * F.scale
        + text_w("MENU", key_size())
end

local function burger_cap(x, y, on)
    local col = on and pal.FRIEND or pal.DIM
    local h = BURGER.h * F.scale
    local bars = BURGER.w * F.scale
    local w = burger_w()
    -- Under a fingertip whatever it looks like: `M.pick` grows a box to the
    -- touch floor for a finger, so a mark drawn at 22 points answers a press
    -- aimed anywhere near it, and the box it grows is the one it publishes
    -- rather than the one it draws.
    local bx = x + KEY_PAD * F.scale
    local mid = y + h / 2
    local ink = pal.a(col, on and 1 or 0.5)
    for i = -1, 1 do
        rect(bx, mid + i * BURGER.gap * F.scale - BURGER.bar * F.scale / 2,
             bars, BURGER.bar * F.scale, ink)
    end
    txt("MENU", bx + bars + KEY_PAD * F.scale, mid, key_size(), ink,
        nil, nil, true)
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
function M.begin(layer, w, h, density, touching, now, frost_layer)
    F:begin(layer, w, h, density, now, frost_layer)
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
-- Where a world position lands on the glass. One formula, and it was two
-- callers: a pilot's nameplate and the figure that used to drift off their
-- wreck were the same conversion written twice.
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
    -- The pilot being observed therefore wears their name exactly like
    -- everybody else on screen: "who am I looking at" is the
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
                    -- and never competes with the name it follows.
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
                end
            end
        end
    end

end

-- --- panels ----------------------------------------------------------------

local rows = {}
-- How the scoreboard is ordered, and how far down it. Both belong to the
-- interface rather than to the game: nothing here changes what is true, only
-- which part of it is on screen.
--
-- Clicking a heading picks that column, and clicking the one already picked
-- does nothing: every column here has an obvious direction, and a name that
-- sorts Z to A or a kill count that puts the worst first is a state somebody
-- reaches by accident and then has to work out how to leave.
--
-- Which column the scoreboard is ordered by. Alphabetical to begin with: the
-- question a player has of this list most often is "is that name in the
-- room", and a name is found in a list sorted by name. The score columns are
-- still a click away for whoever is asking the other question.
M.sort = "name"
M.scroll = 0

-- How far the page under the tabs is scrolled, in pixels, and how tall it
-- came out.
--
-- How far the settings panel has been scrolled, in points.
--
-- Kept on the module because three hands move it: the drawing clamps it, a
-- wheel turns it, and a thumb drags it. It was the drawer's own page scroll
-- and it is the same idea in a smaller panel.
M.page_scroll = 0

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
    elseif sort_key == "deaths" then
        -- Fewest first: on every other column the top of the list is the
        -- pilot doing best, and this is the one where that means less.
        if a.d ~= b.d then return a.d < b.d end
    elseif sort_key == "assists" then
        if a.a ~= b.a then return a.a > b.a end
    end
    -- Kills break every tie, because kills are the score.
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

-- Kills, deaths and assists, whichever way round they have to be got.
--
-- There were five. Points and bounty came off with the two numbers a kill used
-- to pay, so what is left is the three a player counts in their head.
local function seat_score(i, p)
    if seat_here(i) then
        -- The simulation for a seat we can see, because it lands twenty times
        -- a second and your own kill should appear the moment it happens.
        return sim.ship_kills(i), sim.ship_deaths(i), sim.ship_assists(i)
    end
    return (p and p.k) or 0, (p and p.d) or 0, (p and p.a) or 0
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
            r.k, r.d, r.a = seat_score(i, p)
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
        r.k, r.d, r.a = 0, 0, 0
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

-- `moved` is what the match did to each pilot's rating, by ship, and is
-- handed in only at the ending. See `podium`.
local function scores(me, pilots, watchers, viewer_name, always, moved)
    -- Asked for, not assumed. Mid-fight this is the least useful thing on the
    -- screen and the feed still says who is killing whom, so it lives behind
    -- the same toggle your own loadout does.
    --
    -- `always` is the match ending, which is this panel with a head over it:
    -- at the whistle the room's numbers stop being something a player has to
    -- ask for.
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

    -- Three columns, right aligned off the panel's own edge, in the order a
    -- row is read. There were five, and the outer two were points and bounty:
    -- what a kill paid and what the next one would. Neither number exists.
    --
    -- Four at the ending, where the outermost is what the match did to each
    -- pilot's rating. Only there. A rating is a standing rather than a
    -- running total, and a number climbing over somebody's head while they
    -- are trying to fly is the shape the bounty had.
    --
    -- Each is as wide as the widest thing actually in it, measured every
    -- frame against the heading as well as the numbers. Fixed offsets do not
    -- survive several columns in 248 points, so a column sized for the worst
    -- case eats the names in every room where the worst case has not
    -- happened.
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
    -- What the match did, as a signed figure, worked out before the columns
    -- are measured because the widest of them is what the column is sized to.
    -- A pilot whose rating did not move reads a dim zero rather than nothing:
    -- "this match changed nothing for you" is an answer, and a blank is not.
    if moved then
        for i = 1, n do
            local r = rows[i]
            local by = (not r.watch) and r.i ~= nil and moved[r.i] or nil
            r.moved = by and ((by > 0 and "+" or "") .. tostring(by)) or nil
            r.moved_by = by
        end
    else
        for i = 1, n do rows[i].moved, rows[i].moved_by = nil, nil end
    end
    local aw, dw, kw = col_w("a", "A"), col_w("d", "D"), col_w("k", "K")
    local rw = moved and col_w("moved", "RATING") or 0
    local rx = x + w - 12 * F.scale
    local ax = moved and (rx - rw - GAP) or rx
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
    -- Not a sort control, unlike the three beside it. The ending sorts by the
    -- side that took the match and by what each pilot did to the result, and
    -- a heading that lit but changed nothing would be a button that lies.
    if moved then
        txt("RATING", rx, top + 14 * F.scale, small, pal.a(pal.DIM, 0.7),
            "right")
    end
    -- Hit boxes over the headings. Each takes its whole column and the gap to
    -- its left, so the four tile without overlapping and the labels, which
    -- are one or three characters wide, are not the target.
    hit(x + 8 * F.scale, top + 4 * F.scale, 60 * F.scale, 18 * F.scale, "sort_name")
    hit(kx - kw - GAP, top + 4 * F.scale, kw + GAP, 18 * F.scale, "sort_kills")
    hit(dx - dw - GAP, top + 4 * F.scale, dw + GAP, 18 * F.scale, "sort_deaths")
    hit(ax - aw - GAP, top + 4 * F.scale, aw + GAP, 18 * F.scale, "sort_assists")
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
    -- And only in a room big enough for the mark to say something. Three
    -- scorers is where a prize starts picking somebody out rather than
    -- restating the result.
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
            txt("watching", moved and rx or ax, cy, small,
                pal.a(pal.DIM, 0.7), "right")
        else
            -- The one way to ask about a pilot. Published before the panel's
            -- own box below, which takes the wheel and would otherwise
            -- swallow the press: first box in wins.
            hit(x, y, w - 6 * F.scale, LINE * F.scale, "pilot", r.i)
            -- Kills, deaths and assists all in ink. Deaths read dimmer than
            -- the two beside them for a while, which was a judgement about
            -- the number rather than a fact about it: a column is either a
            -- score this board keeps or it is not on the board, and graying
            -- one of the three says the reader should care less about it
            -- while still making them read past it.
            txt(tostring(r.k), kx, cy, num, pal.a(pal.INK, 0.85), "right")
            txt(tostring(r.d), dx, cy, num, pal.a(pal.INK, 0.85), "right")
            txt(tostring(r.a), ax, cy, num, pal.a(pal.INK, 0.85), "right")
            -- Up in the green a kill of yours is already printed in, down in
            -- the color the room uses for the other side, level in the ink
            -- everything else on the row is set in.
            if r.moved then
                local col2 = pal.INK
                local a2 = 0.6
                if (r.moved_by or 0) > 0 then col2, a2 = pal.PAID, 0.95
                elseif (r.moved_by or 0) < 0 then col2, a2 = pal.ENEMY, 0.9 end
                txt(r.moved, rx, cy, num, pal.a(col2, a2), "right")
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
    local k, d, a = seat_score(i, p)
    row("KILLS", tostring(k))
    row("DEATHS", tostring(d))
    -- Kills you were part of and did not finish, which is the third thing a
    -- pilot counts and the one a two-column board used to lose.
    row("ASSISTS", tostring(a))

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
local function corner_row(on_air, watch, room, landed)
    -- Keys drawn the way the help page draws a key. They were bare words over
    -- a shared rule, which asked a player to know that a word in that corner
    -- was a thing to press, and the board has taught the same hand what a key
    -- looks like already.
    --
    -- MENU is not among them any more, and with PLAYERS already folded into
    -- the clock band this row is chips about you and this room rather than
    -- navigation: the seat being held, which copy of the game you are in, and
    -- whether the camera is on you. In an ordinary match it is empty, and the
    -- corner is the fight.
    --
    -- MENU stood first here for as long as there was a drawer for it to pull
    -- out. A key in the top left corner opening a panel at the bottom of the
    -- screen is a control detached from what it does; it is at the foot now,
    -- where the column stands. See `burger_cap`.
    local x, y = F.safe_l + PAD * F.scale, F.safe_t + PAD * F.scale
    -- Each key is as wide as its own word. A slot cut for four letters is a
    -- slot the longer of the two runs out of.
    local cx = x
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

local function match_ended(m)
    return m ~= nil and not m.playing
end
-- The arena asks the same question, to keep the touch pads off the ending:
-- the whistle benched every hull, so the pads have nothing to drive, and the
-- board's own rows land exactly where the gun pad draws.
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
-- How far the clock band reached last frame, which is where the press that
-- opens the scoreboard has to land. Measured rather than guessed: the band is
-- centered but grows outward with the scores, the side names and their
-- ratings, and a half-width written down here would be a second copy of that
-- arithmetic to keep in step.
--
-- The drawer read it too, to ask whether it was standing over the band. The
-- column stands at the foot and reaches nothing up here.
local band_l, band_r = 0, 0

local function match_clock(o, m, names, alone)
    if not m then return end
    local left = m.left or 0
    local clock = string.format("%d:%02d", math.floor(left / 60), left % 60)
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
    --
    -- The dim is for numbers that have stopped moving, which at the whistle is
    -- both sides' points. The numerals themselves keep full strength wherever
    -- they are counting something, and between matches they are counting the
    -- hardest: the clock is the whole of what the band has left to say then.
    -- Only the rival search's --:--, which is counting nothing, goes quiet.
    local dim = m.playing and 1 or 0.55
    txt(clock, F.w / 2, mid, big, pal.a(pal.INK, 0.95), "center")
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
    -- Nothing to press while the menu is up. The band keeps drawing, since a
    -- player reading the column still wants the clock, but the board it opens
    -- is not drawn then, and a control whose panel cannot appear is a press
    -- that does nothing anybody can see.
    local function press()
        if alone then return end
        local x0, x1 = band_l, band_r
        hit(x0 - 6 * F.scale, top - 4 * F.scale,
            x1 - x0 + 12 * F.scale, big + 8 * F.scale, "details")
    end

    -- A match that has finished draws no sides. The ending's own head names
    -- both of them inside a bar with their points on the ends, a few lines
    -- down the same window, so a side up here would be that read twice. What the band keeps
    -- is the clock, in the pixels it has counted the match down in, now
    -- counting to the next one.
    --
    -- And a word under it saying so, because a clock counting down to
    -- something a player cannot see is a question. Nothing under it while a
    -- match is being played: the clock is running and "match" beneath it is
    -- the interface reading its own label back.
    --
    -- No press either. The board this box opens is already up and covering the
    -- window, so the box would be a strip across the top of the ending that
    -- toggles a panel nobody can see change.
    if match_ended(m) then
        txt("NEXT MATCH IN", F.w / 2, band_bottom() + 8 * F.scale,
            (M.compact and 9 or 11) * F.scale, pal.a(pal.DIM, 0.8), "center")
        return
    end

    -- A side is a team: its name over what it has scored, which is the pair a
    -- player checks the clock to find out about.
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
    -- In ink rather than in the warning color. The lines left, an opponent
    -- who left mid-fight and a clock that has run out, would wear red well
    -- enough, but the lag notice under this one is the red one and two reds in
    -- a column would stop meaning anything.
    local px = (M.compact and 9 or 11) * F.scale
    txt(line, F.w / 2, band_bottom() + 8 * F.scale, px,
        pal.a(pal.INK, 0.9), "center")
end

-- The ending: the board, with a head over it.
--
-- There was a page here. It carried a title, a score bar, both rosters, six
-- phrase chips, a countdown with a drain bar beside it and a share key the
-- width of the measure, and most of that was the scoreboard's own content a
-- second time now that the board is one press off the band. So the ending
-- stopped being a page. At the whistle the board comes up whether or not
-- anybody asked for it, and grows a line saying who took the match and a bar
-- under that. Decision 68.
--
-- Nothing under the roster. The foot that held the countdown went to the band
-- with it, so the clock a player has been reading in the top row all match is
-- still in the top row after it. Decision 94, which took the two keys that
-- stood beside that countdown with it.
--
-- One layout at every window size. The measure and the type change, and on an
-- upright phone the block hugs the foot of the screen, where a thumb reaches
-- the roster; nothing else about the arrangement moves.

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

-- Which side took it, what the ending calls that, and in what color. A draw is
-- a real result at three minutes and says so, rather than a winner being named
-- by tie-break.
function END.result(o, m, names)
    local best, best_at, drawn = -1, nil, false
    for team, n in pairs(m.score or {}) do
        if n > best then best, best_at, drawn = n, team, false
        elseif n == best then drawn = true end
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

-- What this match did to everybody's rating, by ship.
--
-- The client's own subtraction rather than a number off the wire. A rating
-- moves only through rated deaths and the zone reports both pilots' rating
-- after every one, so the copy this client holds is exact and the figure at
-- the whistle less the figure at the last one is what the match was worth.
--
-- Rounded on each end rather than once at the difference. What a pilot sees
-- on their own card is the rounded rating, and a movement worked out from the
-- unrounded pair would be a point off the two numbers it is supposed to
-- explain.
local function rating_moves(o)
    if not (o.ratings and o.rated_from) then return nil end
    local out = {}
    for ship, now in pairs(o.ratings) do
        local was = o.rated_from[ship]
        if was then
            out[ship] = math.floor(now + 0.5) - math.floor(was + 0.5)
        end
    end
    return out
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
        h = head + gap + roster_h(n)
    end
    measure()

    -- What the block has to clear at the top and at the bottom of the window.
    --
    -- The band and the word under it hold the top row now, so the block starts
    -- under them rather than being centered through them. Both are measured at
    -- the interface's own scale and before the zoom below touches it, because
    -- the band is drawn at that scale whatever the block is grown to.
    local ceil = band_bottom() + 20 * F.scale
    local floor = F.safe_b + 18 * F.scale

    -- The zoom, and everything after this line draws at it. Scaling F.scale
    -- itself is what grows the block as one drawing: every size below, the
    -- roster's rows included, is a multiple of it, and the hit boxes are
    -- published off the same numbers, so the targets grow with the ink.
    -- Clamped by the room the band has left rather than by the window's
    -- width, since the measure already gives way to a narrow screen on its
    -- own. The band itself never wears the zoom: it is not part of this
    -- drawing.
    local was_scale = F.scale
    local slack = F.h - ceil - floor
    local zoom = math.max(1, math.min(END.ZOOM, slack / h))
    M.podium_zoom = zoom
    if zoom > 1 then
        F.scale = was_scale * zoom
        measure()
    end

    -- Centered in what the band has left, and hugging the foot of an upright
    -- phone: the roster is dragged with a thumb, and a thumb reaches the
    -- bottom of a tall screen rather than the middle. Never over the band
    -- either way, which is the one thing above it that is still being read.
    local y
    if M.compact and F.h > F.w then
        y = F.h - F.safe_b - 26 * F.scale - h
    else
        y = ceil + (slack - h) / 2
    end
    y = math.max(ceil, y)

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
    scores(o.me, o.pilots, o.watchers, o.viewer_name, true, rating_moves(o))
    top_side = nil
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
-- Where the faint menu key stands: the bottom middle, at the foot of
-- everything, in the strip the column rises out of.
--
-- Published as a box rather than drawn here, because two callers need it and
-- they need different halves of it. The HUD draws the key in it while the
-- column is down; the column measures its own foot off the top of it, so
-- RESUME comes to rest on the pixels the key was occupying. See `burger_cap`.
local function foot_key_box()
    local h = BURGER.h * F.scale
    local w = burger_w()
    local mid = F.safe_l + (F.w - F.safe_l - F.safe_r) / 2
    return mid - w / 2, F.h - F.safe_b - 10 * F.scale - h, w, h
end

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
    --
    -- PLAY NOW sits on the bottom margin, with nothing under it. The menu key
    -- shared this strip for a while and the column was lifted clear of it,
    -- which put a faint second control under the one the screen exists for.
    -- The menu is about the room you are in, and out here you are not in one
    -- yet: what this screen offers is a game, a ship and the way in. See
    -- `M.foot_key`.
    local foot = F.h - F.safe_b - (M.compact and 18 or 22) * F.scale
    local rgap = 8 * F.scale
    local size = (M.compact and 20 or 26) * F.scale
    -- `txt` sets a string on the middle of its line, so half the type goes
    -- back to put the baseline where it belongs above what it heads.
    local mgap = (M.compact and 16 or 20) * F.scale + size / 2
    local g = {narrow = narrow, size = size, kh = kh, kw = kw,
               kx = mid - kw / 2, ky = foot - kh, rgap = rgap,
               kpx = (narrow and TYPE.ROW
                      or (M.compact and TYPE.BODY or TYPE.LEAD)) * F.scale,
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

-- And the menu's own column: the same stops at the same width over the same
-- breathing key, standing where the key that raised it stood.
--
-- No wordmark over it and no rail under it. The lockup belongs to the screen a
-- player arrives on rather than to a panel raised mid-match, and the rail is
-- what the landing falls back to when a hull and a name have to fit above the
-- stops, and there is nothing above these, so three rows and a key always fit.
--
-- `n` is how many stops there are, which is two or three: the sides arrive
-- with the roster broadcast, a frame or two after the column could first be
-- raised. Measured rather than assumed, so a column that grows a stop grows
-- upward and nothing already under a thumb moves.
local function menu_geom(n)
    local pts_w = F.w / math.max(F.density, 0.0001)
    local narrow = pts_w < 620
    local margin = 14 * F.scale
    local span = F.w - F.safe_l - F.safe_r - 2 * margin
    local kh = (narrow and 50 or (M.compact and 44 or 54)) * F.scale
    local kw = narrow and span or (M.compact and 240 or 320) * F.scale
    local mid = F.safe_l + (F.w - F.safe_l - F.safe_r) / 2
    local rgap = 8 * F.scale
    local rh = (narrow and 44 or (M.compact and 30 or 36)) * F.scale
    local _, ky, _, kbh = foot_key_box()
    local g = {kw = kw, kh = kh, kx = mid - kw / 2, rgap = rgap, rh = rh,
               kpx = (narrow and TYPE.ROW
                      or (M.compact and TYPE.BODY or TYPE.LEAD)) * F.scale,
               stops = {}}
    -- The key's own foot on the strip's, so the two occupy one place: the
    -- column comes up out of the key and RESUME settles onto it.
    g.ky = ky + kbh - kh
    local top = g.ky - 12 * F.scale - n * rh - (n - 1) * rgap
    for i = 1, n do
        g.stops[i] = {x = g.kx, y = top + (i - 1) * (rh + rgap),
                      w = kw, h = rh}
    end
    g.top = top
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
-- `o` carries the handful of things only some stops want, because a stop takes
-- enough positional arguments already: `raw` quotes the answer rather than
-- saying it, `warn` puts the guest dot on it, `value` is what a press on it
-- reports, and `flat` says the stop acts rather than opening, so it wears no
-- caret. A caret is a promise that a list is about to come up, and the one
-- stop here that keeps its promise by doing something instead should not be
-- making it.
local function land_stop(x, y, w, h, label, value, action, lit, stacked, o)
    -- Where a press would land, at the weight every row of the menu is lit
    -- at. Under the outline rather than over it: the edge is the brighter
    -- half of the same signal, and a wash laid over it would mute it.
    local hot = M.col_sel == action
    frost(x, y, w, h)
    rect(x, y, w, h, pal.a(pal.BTN_BG, 0.6))
    if hot then rect(x, y, w, h, pal.a(pal.FRIEND, LIT.CURSOR)) end
    key_box(x, y, w, h, nil,
            (lit or hot) and pal.a(pal.FRIEND, 0.8)
                or pal.a(pal.RADAR_TILE, 0.75))
    o = o or {}
    local raw = o.raw
    local pad = 12 * F.scale
    local cx = x + w - pad - 3 * F.scale
    -- Down the column an answer is set on the type ladder like everything
    -- else. A rail cell is the one place in this interface where an answer has
    -- to fit a third of a small screen, and at 12 points "Team Battle" no
    -- longer does on a 320 point window: the cell clips it, and a game's name
    -- cut short is the one thing that cell is for. So the rail takes the size
    -- that fits and the column takes the rung.
    local px = (stacked and 11 or TYPE.LABEL) * F.scale
    if stacked then
        -- The caret rides the question's line rather than the answer's, so
        -- the answer has the cell's whole width to be read across. At the
        -- narrowest a cell gets there is barely room for a zone's name, and
        -- what would have paid for the caret is those last two letters.
        pad = 8 * F.scale
        lbl(label, x + pad, y + h * 0.33)
        if not o.flat then
            land_caret(cx, y + h * 0.33, pal.a(pal.INK, 0.75))
        end
        local kept = F.clip_r
        F.clip_r = x + w - pad
        txt(value or "", x + pad, y + h * 0.68, px, pal.a(pal.INK, 0.95),
            nil, nil, raw)
        F.clip_r = kept
    else
        lbl(label, x + pad, y + h / 2)
        if not o.flat then land_caret(cx, y + h / 2, pal.a(pal.INK, 0.75)) end
        txt(value or "", cx - 11 * F.scale, y + h / 2, px,
            pal.a(pal.INK, 0.95), "right", nil, raw)
    end
    -- The guest warning, where a guest has something a lost account would
    -- cost them: one dot in the caution color beside the name it is about.
    -- The drawer said it in words on a band, which it had the width for. Out
    -- here the stop is the whole of the account, and a dot on it is the mark
    -- that band used to put on the pilot tab.
    --
    -- Beside the call sign, not beside the word ACCOUNT. What is at stake is
    -- who you are signed in as rather than the question the row is asking,
    -- and down the column those are at opposite ends of the row: a mark in
    -- the left margin reads as a note on the label.
    if o.warn then
        local dy = stacked and y + h * 0.68 or y + h / 2
        -- The rail sets the answer under the question at the same left edge,
        -- so the margin the outline leaves is still the right place to stand
        -- and the dot only has to drop a line to be beside the name. A
        -- measure off the label would leave the box there: the label starts
        -- at eight points on a rail cell and twelve down the column.
        local dx = x + 5.5 * F.scale
        if not stacked then
            -- The answer is set from the right, so where it begins is where
            -- it ends less its own width. Asked of the same measure the
            -- drawing uses rather than guessed at, since a call sign is as
            -- long as its pilot made it.
            dx = cx - 11 * F.scale - text_w(value or "", px, nil, raw)
                - 7 * F.scale
        end
        F.layer:disc(dx, ry(dy), 2.5 * F.scale, 8,
                     pal.a(pal.CHARGE_COL, 0.95))
    end
    hit(x, y, w, h, action, o.value)
end

-- --- what a stop opens -----------------------------------------------------
--
-- A panel that slides up out of the bottom edge and takes the window, rather
-- than a list unrolling upward from the row that opened it.
--
-- The lists opened upward because they had to keep off PLAY NOW, which put
-- every one of them in the strip between the stops and the top of the screen,
-- and made the ship panel's height a standing argument with the window: it
-- asked for more than the strip had and scrolled inside whatever it was given.
-- The panel does not have that argument, because the buttons go with it. Press
-- a stop and the column sinks out through the bottom edge while the panel
-- rises through the same edge, so the two are one movement and the screen
-- holds one thing at a time. Back plays it the other way round.
--
-- What that buys beyond the room is that a row which opens something stops
-- being a special case: it slides the next panel in over this one, and back
-- steps one level out rather than shutting everything. Nothing stacks yet --
-- the account acts still raise a card -- but the grammar no longer forbids it.
-- Mocked in .design/dropdown-stack.

-- How long a column or a panel takes to come up or go down, in seconds.
--
-- It is worth the machinery for the same reason the drawer's was: the press
-- and the panel are the same spot, so without the slide the key would blink
-- into a column with nothing saying one became the other. What it costs is one
-- easing and three numbers, and what it buys is the one sentence this
-- interface most needs to say: the thing you pressed is the thing that opened.
local COLUMN_SPAN = 0.16

-- Out fast and settling slow, which is the drawer's own curve: a panel that
-- decelerates into place reads as arriving, and one that moves at a constant
-- rate reads as being dragged.
local function column_ease(t)
    local u = 1 - t
    return 1 - u * u * u
end

-- The measure a panel is held to, and the margin it keeps from every edge.
--
-- The window less that margin is right on a phone and wrong on a monitor. A
-- row eleven hundred points wide sets a game's name at one end and its format
-- at the other, two things too far apart to be read as one row, and glass that
-- wide stops being a panel over a fight and becomes the screen. Capped, it
-- stands in the middle of the window with the room showing either side, which
-- is what the frost was for in the first place. Wider than the column it came
-- from either way, so opening one reads as a step up rather than sideways.
local PANEL_MAX = 560
local PANEL_MARGIN = 14

-- The most a panel can grow to, which is the window less its margins.
local function panel_room()
    local margin = PANEL_MARGIN * F.scale
    return (F.h - F.safe_b - margin) - (F.safe_t + margin)
end

-- Where a panel of this height stands.
--
-- As tall as what it holds, and no taller. Decision 103 gave every panel the
-- whole window, which is right for a hull's build and absurd for three account
-- acts: a head, three rows and six hundred points of empty glass over a fight
-- somebody is watching. The panel is the thing on screen, not the screen.
--
-- Anchored at the foot rather than the top, which is the edge it slides out of
-- and back into: it grows upward from there, so its head moves and the rows
-- nearest a thumb stay where they are. Over the room it has it takes the room
-- and scrolls inside it, which is what the ship page and the settings page
-- have always done.
local function panel_geom(want)
    local margin = PANEL_MARGIN * F.scale
    local span = F.w - F.safe_l - F.safe_r - 2 * margin
    local w = math.min(span, (M.compact and 440 or PANEL_MAX) * F.scale)
    local mid = F.safe_l + (F.w - F.safe_l - F.safe_r) / 2
    local room = panel_room()
    local h = math.min(want or room, room)
    return mid - w / 2, F.h - F.safe_b - margin - h, w, h
end

-- How far an open panel has come up: 0 fully below the bottom edge, 1
-- standing. The same number moves the buttons the other way.
--
-- One of these per column rather than one shared between them. Only ever one
-- of the two is on a screen, so one set of numbers would do: `M.hud` returns
-- before the landing wherever the menu is up, and the menu is only up in a
-- room. But that is a fact about a line a long way from here, and a shared
-- slide written twice in a frame with two different answers is an animation
-- that restarts every frame and never lands. Two tables are cheaper than a
-- dependency on a return staying where it is.
local function new_slide()
    return {at = 0, from = 0, to = 0, when = 0}
end
-- Two apiece: how far up the panel has come, and how tall it is.
--
-- The height eases on the same curve the rise does, because it moves for the
-- same reason: a panel that opens over another is a different amount of
-- content, and the glass under it growing or shrinking to fit is the same
-- gesture as the glass arriving. Snapping between two heights reads as two
-- panels swapped rather than one sliding to fit what it now holds.
local land_slide, menu_slide = new_slide(), new_slide()
local land_h, menu_h = new_slide(), new_slide()

-- Advance one of them toward `want` and answer where it reached. Called once a
-- frame by the column that owns it.
--
-- `F.now` is zero under the test harness, which is what settles the panel
-- instantly there and keeps the layout tests still.
local function panel_slide(s, want)
    if want ~= s.to then
        s.from, s.to, s.when = s.at, want, F.now
    end
    if F.now <= 0 then
        s.at = want
    else
        local t = math.min(1, (F.now - s.when) / COLUMN_SPAN)
        s.at = s.from + (s.to - s.from) * column_ease(t)
    end
    return s.at
end

-- A panel's height, which eases between two panels and snaps on arrival.
--
-- Opening one is already a movement: it rises through the bottom edge, and a
-- height easing out of nothing at the same time makes it arrive as a sliver
-- that grows, which is two gestures for one act. So the first frame takes the
-- height it wants. What eases is the change from one panel's worth to the
-- next, which is the only time the glass is asked to be a different size while
-- it is standing still.
--
-- `at` is zero exactly when nothing was open, because closing zeroes it.
local function panel_height(s, want)
    if s.at <= 0 then
        s.at, s.from, s.to, s.when = want, want, want, F.now
        return want
    end
    return panel_slide(s, want)
end

-- Put every slide back on the floor without playing it, for the caller that
-- is tearing the whole screen down rather than closing a panel.
function M.panel_shut()
    for _, s in ipairs({land_slide, menu_slide, land_h, menu_h}) do
        s.at, s.from, s.to, s.when = 0, 0, 0, 0
    end
end

-- What each panel wants to be, in points, before the window has its say.
--
-- Measured rather than assumed, because the whole point of a panel that is as
-- tall as what it holds is that only the thing holding it knows. Each of these
-- counts exactly what its own drawing lays down, so a row added to a page
-- moves the glass with it.
--
-- On `pages` rather than as four more locals: this chunk sits at Lua's own
-- ceiling of two hundred, and a coherent group belongs on one table. See
-- client/tests/upvalues_test.lua.
pages.HEAD_H = 44

function pages.list_h(list, drh)
    local h = pages.HEAD_H * F.scale + 10 * F.scale
    for _, r in ipairs(list) do
        h = h + (r.rule and 9 * F.scale or drh)
    end
    return h
end

function pages.ship_h(panel, drh)
    -- The head, the walker under it, the flight bars, the credit tray, and a
    -- row apiece. A section band is shorter than a row and says so.
    local h = pages.HEAD_H * F.scale * 2 + 10 * F.scale
    if panel.bars then h = h + 34 * F.scale end
    if panel.rows then
        h = h + 30 * F.scale
        for _, r in ipairs(panel.rows) do
            h = h + (r.kind == "sect" and 24 * F.scale or drh)
        end
    else
        h = h + drh
    end
    return h
end

function pages.page_h(v, rowh, secth, noted)
    local rh = noted and rowh + pages.NOTE_LINE * F.scale or rowh
    local h = pages.HEAD_H * F.scale + 10 * F.scale
    for _, r in ipairs(v.rows) do
        h = h + rh + (r.sect and secth or 0)
    end
    return h
end

-- The panel itself: the glass, and the head that says where you are with the
-- way back out on it.
--
-- The same frost the stops wear, rather than the near-opaque ground the lists
-- had. A list was a strip that had to carry two rows over a firefight; a panel
-- is the surface the screen is currently about, and the room behind it is what
-- says this is still a game being watched rather than a settings application.
--
-- The head is the in-match settings page's, which had it first: a triangle
-- pointing back and the name of the section, the whole row being the press.
-- `title` is the section, `back` the action that steps one level out.
--
-- Answers the top of the content and the foot it has to stay above, so a
-- caller can lay rows into it without measuring the chrome again.
-- `back_value` is for the one caller whose way back is an answer rather than a
-- level: an account card's cancel travels by its place in the card's own list
-- of answers, the way the key beside it used to.
local function panel_frame(px, py, pw, ph, title, back, foot_note, back_value)
    local headh = 44 * F.scale
    -- The same measure the rows under it are inset by, so the head's mark and
    -- the names below it stand on one line rather than two points apart.
    local pad = 14 * F.scale
    frost(px, py, pw, ph)
    rect(px, py, pw, ph, pal.a(pal.BTN_BG, 0.72))
    key_box(px, py, pw, ph, nil, pal.a(pal.RADAR_TILE, 0.75))
    -- The head is a control like any other row, so it lights like one. It did
    -- not, and a hand walking the panel with the arrows could stand on the way
    -- back with nothing on screen saying so: the walk named it, the drawing
    -- never did. Both hands write `M.col_sel` through the same `M.pick`, so
    -- this answers a pointer resting on it as well.
    local hot = back and M.col_sel == back
    if hot then LIT.field(px, py, pw, headh, LIT.CURSOR) end
    local hy = py + headh / 2
    F.layer:tri(px + pad + 2 * F.scale, ry(hy),
                px + pad + 9 * F.scale, ry(hy - 6 * F.scale),
                px + pad + 9 * F.scale, ry(hy + 6 * F.scale),
                pal.a(pal.FRIEND, hot and 1 or 0.9))
    lbl(title or "", px + pad + 18 * F.scale, hy,
        hot and pal.a(pal.INK, 0.95) or pal.MUTE)
    -- What a control waiting for a key has to say, where it says it: on the
    -- head of the page that asked, so a hand looking at the row is looking at
    -- the sentence about it.
    if foot_note then
        txt(foot_note, px + pw - pad, hy, (M.compact and 10 or 11) * F.scale,
            pal.a(pal.READ, 0.95), "right", MENU_FONT, true)
    end
    hrule(px, py + headh, pw, 0.6)
    hit(px, py, pw, headh, back, back_value, nil, 1)
    -- And the panel itself takes a press, so a tap that misses a row lands on
    -- the glass rather than on the fight behind it. Under the rows and under
    -- the head, which both publish above it, and over the backdrop that shuts
    -- the panel: with the glass covering most of the window, a press it did not
    -- swallow would put the panel away every time a thumb missed a row.
    hit(px, py, pw, ph, "panel_hold", nil, nil, 0)
    return py + headh + 5 * F.scale, py + ph - 5 * F.scale
end

-- The commit: the one key on a screen that does the thing the screen exists
-- for, breathing on its own clock so a first visit's eye ends on it.
--
-- PLAY NOW out on the landing, RESUME in a match, LOG IN at the foot of the
-- card that asks for a password. One drawing, because it is one object: it was
-- written out three times, and the third copy is what made that worth saying.
--
-- The edge is floored well above dark so the trough never reads as a key that
-- has stopped working, and under a pointer the breath stops at the top of its
-- own swell: the one thing moving on a screen should never be the thing you
-- are already on. `F.now` is zero under the test harness, which is what keeps
-- the layout tests still.
local function commit_key(x, y, w, h, px, word, hot)
    local swell = hot and 1 or (0.5 + 0.5 * math.sin(F.now * 2.6))
    frost(x, y, w, h)
    rect(x, y, w, h, pal.a(pal.FRIEND, 0.06 + 0.12 * swell))
    if hot then rect(x, y, w, h, pal.a(pal.FRIEND, LIT.CURSOR)) end
    key_box(x, y, w, h, nil, pal.a(pal.FRIEND, 0.62 + 0.38 * swell))
    txt(word, x + w / 2, y + h / 2, px, pal.a(pal.INK, 1), "center")
end

-- A group of rows inside a panel, named: a small label between two rules, the
-- full width of the glass.
--
-- One function because both panels that band their rows were drawing their own
-- and drawing them differently -- the ship page's rules at 0.45, the settings
-- page's at 0.45 above and nothing below, its label inset by a different pad.
-- What a band says is what the rows under it are about, and it is the one
-- thing a page of eight settings cannot say in its title.
local function menu_band(kx, kw, y, h, label)
    hrule(kx, y, kw, 0.45)
    lbl(label, kx + 14 * F.scale, y + h / 2, pal.MUTE)
    hrule(kx, y + h, kw, 0.45)
end

-- A stop's rows, drawn from `top` down the panel that opened them. Rows wear
-- the menu's own states from decision 72: the row the pointer rests on washes
-- at 0.18, the row you are already in at 0.07.
--
-- The ground under them belongs to the panel now rather than to the list. It
-- was the list's while a list was a strip of its own unrolled over the fight,
-- and it had to be nearly opaque for two rows over a firefight to be readable
-- at all. A panel is one surface with one glass, so the rows draw onto it.
local function land_list(kx, kw, top, list, drh)
    local pad = 14 * F.scale
    local y = top
    for _, r in ipairs(list) do
        if r.rule then
            hrule(kx + pad, y + 4.5 * F.scale, kw - 2 * pad, 0.6)
            y = y + 9 * F.scale
        else
            local hov = not r.dim and M.col_sel == r.action
                and M.col_sel_value == r.value
            -- The field a state lights runs the panel's full width, and the
            -- type column stands inside it: the caller owns the glass, the
            -- row owns what is written on it.
            if hov then
                LIT.field(kx, y, kw, drh, LIT.CURSOR)
            elseif r.here then
                LIT.field(kx, y, kw, drh, LIT.HERE)
            end
            -- These lists used to set their names in the HUD's twelve point
            -- mono capitals, because a list was once a strip drawn over a
            -- fight. It is a panel now, read rather than glanced at, so the
            -- name goes in the menu's own voice like every other row in the
            -- game: `mark` is where you already are, `named` quotes a name in
            -- the case its owner gave it, and `detail` is the reading.
            menu_row(kx + pad, y, kw - 2 * pad, drh, {
                label = r.label, named = r.raw, detail = r.note,
                mark = r.here, tint = r.tint, offer = r.offer, dim = r.dim,
            }, hov)
            if not r.dim then
                hit(kx, y, kw, drh, r.action, r.value, nil, 1)
            end
            y = y + drh
        end
    end
end

-- The five rows a hull's flight is read on, in the order the panel and the
-- roster both draw them.
local FLIGHT_ROWS = {"speed", "thrust", "turn", "energy", "recharge"}

-- How far the ship panel has been scrolled, in points. Kept apart from the
-- settings panel's own scroll because the two are different surfaces and a
-- position carried between them would open one where the other was left.
M.col_scroll = 0


-- The row the panel last scrolled itself to. Without it the panel would haul
-- itself back to the lit row on every frame, which is a finger dragging a page
-- it cannot keep.
local col_followed = nil

-- One row of the ship panel: a section band, a slot, or the way back to the
-- hull's own row.
--
-- A section head is a band the full width of the panel with a rule above and
-- below it, so the page reads as bands of instruments stacked in one frame
-- rather than as a list with words dropped into it. The first band's upper
-- rule is the one the credit tray closes on, which is why the tray does not
-- draw one of its own.
--
-- A slot is a stepper or a switch, and which is not a decision made here: a
-- slot that only goes to one is on and off and gets a switch, and anything
-- you can have more of gets the arrows. The arrows are the wake row's, and
-- one that would do nothing is drawn dim rather than left out, so a row does
-- not change shape as a pilot spends.
local function land_row(kx, kw, y, h, r)
    local pad = 14 * F.scale
    if r.kind == "sect" then
        menu_band(kx, kw, y, h, r.label)
        return
    end
    if r.kind == "reset" then
        menu_row(kx + pad, y, kw - 2 * pad, h,
                 {label = r.label, dim = not r.on}, false)
        if r.on then
            hit(kx, y, kw, h, "land_kit_reset", nil, nil, 1)
        end
        return
    end
    -- Lit where a hand on the arrows is standing, the way every row in the
    -- menu is. The row is also the anchor that walk stands on: the arrows
    -- are published over it, so a pointer aiming at one lands on it and a
    -- pad walking the panel lands on the row.
    local on = M.col_sel == "land_kit_row" and M.col_sel_value == r.slot
    if on then LIT.field(kx, y, kw, h, LIT.CURSOR) end
    hit(kx, y, kw, h, "land_kit_row", r.slot, nil, 0)
    -- A slot is a stepper or a switch, and which is not a decision made here:
    -- a slot that only goes to one is on and off, and anything you can have
    -- more of gets the arrows. Either way it is one row wearing one end.
    menu_row(kx + pad, y, kw - 2 * pad, h, {
        label = r.label,
        toggle = r.toggle or nil,
        step = {value = r.value, base = r.base, reads = r.reads,
                can_up = r.can_up, can_down = r.can_down, slot = r.slot,
                action = "land_kit_step"},
    }, on)
end

-- The ship stop's panel: one hull, what it flies like, and the credits its
-- pilot has spent on it.
--
-- The other two stops open lists, and this one did too until it was the only
-- roster there is. Seven hulls with five bars and a build apiece is a page in
-- a list's clothes, and the thing a player is doing here is looking at one
-- ship. So it pages: left and right walk the roster and everything below the
-- name is about the ship in front of you. See decision 100.
--
-- Drawn identically at every window shape, and scrolled where the window is
-- too short to hold it. A landscape phone had a version of its own for a
-- while, three sections side by side, which is two layouts to learn and two
-- to keep working for one panel that already fits a scroll.
--
-- `top` and `bottom` are the room the section panel has already left for it,
-- under the head that names the stop. The roster is walked on an ordinary row
-- under that head rather than on a second head of its own: a panel heads
-- itself once, and what the walker says is which of the seven ships is in
-- front of you, which is a row's worth of information.
local function land_panel(kx, kw, top, bottom, panel, drh)
    local pad = 14 * F.scale
    local rowh = drh
    local headh = 44 * F.scale
    local barh = panel.bars and 34 * F.scale or 0
    local trayh = panel.rows and 30 * F.scale or 0
    local py = top

    -- The walker: arrows at the row's own edges with the ship's name between
    -- them. Lit where the cursor is standing on it, like any other row.
    local col = panel.mine and pal.FRIEND or pal.INK
    local walk_hot = M.col_sel == "land_pick_ship"
    if walk_hot then LIT.field(kx, py, kw, headh, LIT.CURSOR) end
    menu_row(kx + pad, py, kw - 2 * pad, headh, {
        label = panel.label, named = not panel.watching,
        walk = "land_page_ship", mark = panel.mine,
    }, walk_hot)
    hrule(kx, py + headh, kw, 0.6)
    -- The name itself is the press that flies this one, so a pilot who has
    -- paged to a ship is one press from arriving in it. Published under the
    -- two arrows, which take their own share of the row.
    hit(kx + 36 * F.scale, py, kw - 72 * F.scale, headh, "land_pick_ship",
        panel.watching and "spectate" or panel.class, nil, 0)

    local y = py + headh
    -- The flight row, as five bars against the rest of the roster. A share
    -- rather than a figure: the question is "faster than what".
    if panel.bars then
        local n = #panel.bars
        local gap = 6 * F.scale
        local bx = kx + pad
        local bw = kw - 2 * pad
        local cw = (bw - gap * (n - 1)) / n
        for i = 1, n do
            local px = bx + (i - 1) * (cw + gap)
            local share = math.max(0, math.min(1, panel.bars[i] or 0))
            rect(px, y + 12 * F.scale, cw, 3 * F.scale, pal.a(pal.DIM, 0.22))
            rect(px, y + 12 * F.scale, cw * share, 3 * F.scale,
                 pal.a(col, 0.85))
            lbl(FLIGHT_ROWS[i], px, y + 23 * F.scale, pal.MUTE, nil,
                8.5 * F.scale)
        end
        y = y + barh
        hrule(kx, y, kw, 0.45)
    end

    -- The purse: every credit this pilot has, spent ones hollow. A count
    -- drawn rather than written, because the whole reason a step costs one is
    -- that nobody should have to read a number to know what they can afford.
    if panel.rows then
        local cy = y + trayh / 2
        lbl("build credits", kx + pad, cy, pal.a(pal.CHARGE_COL, 0.8))
        local side = 9 * F.scale
        local gap = 6 * F.scale
        local total = panel.credits or 0
        local run = total * side + math.max(0, total - 1) * gap
        local sx = kx + kw - pad - run
        for i = 1, total do
            local x = sx + (i - 1) * (side + gap)
            local on = i <= (panel.free or 0)
            F.layer:quad(x + side / 2, ry(cy - side / 2),
                         x + side, ry(cy),
                         x + side / 2, ry(cy + side / 2),
                         x, ry(cy),
                         pal.a(pal.CHARGE_COL, on and 0.95 or 0.18))
        end
        y = y + trayh
    end

    -- The rows, scrolled where the window is too short for them.
    --
    -- Whole rows only, which is the same rule the drawer's pages follow and
    -- for the same reason: the scissor in the renderer cuts against a
    -- vertical edge, so a row half off the bottom would draw through the
    -- frame rather than be cut by it. So the scroll is clamped to a row
    -- boundary and a row that does not fit is not drawn at all.
    local ry0, ry1 = y, bottom
    local content = 0
    if panel.rows then
        for _, r in ipairs(panel.rows) do
            content = content + (r.kind == "sect" and 24 * F.scale or rowh)
        end
    end
    local over = math.max(0, content - (ry1 - ry0))
    M.col_scroll = math.max(0, math.min(M.col_scroll, over))
    -- The panel follows the cursor, since walking it with a pad or the
    -- arrows is how it is read without a pointer: a row lit under the fold
    -- is a row nobody can see themselves spending on. Whole rows only, the
    -- same rule the drawing follows, so the panel never stops halfway down
    -- one. On the frame the cursor moved and no other, which is what keeps a
    -- finger dragging it from being hauled back.
    if M.col_sel == "land_kit_row" and col_followed ~= M.col_sel_value then
        col_followed = M.col_sel_value
        local at = 0
        for _, r in ipairs(panel.rows or {}) do
            local rh = r.kind == "sect" and 24 * F.scale or rowh
            if r.kind == "slot" and r.slot == M.col_sel_value then
                if at < M.col_scroll then
                    M.col_scroll = at
                elseif at + rh > M.col_scroll + (ry1 - ry0) then
                    M.col_scroll = at + rh - (ry1 - ry0)
                end
                break
            end
            at = at + rh
        end
        M.col_scroll = math.max(0, math.min(M.col_scroll, over))
    elseif M.col_sel ~= "land_kit_row" then
        col_followed = nil
    end
    local cy = ry0 - M.col_scroll
    if panel.rows then
        for _, r in ipairs(panel.rows) do
            local rh = r.kind == "sect" and 24 * F.scale or rowh
            if cy >= ry0 - 0.5 and cy + rh <= ry1 + 0.5 then
                land_row(kx, kw, cy, rh, r)
            end
            cy = cy + rh
        end
        -- That there is more, said as a thumb against the panel's own edge
        -- rather than as a word. Only where there is: a rail on a panel that
        -- fits is an instrument reporting on nothing.
        if over > 0 then
            local run = ry1 - ry0
            local thumb = math.max(20 * F.scale, run * run / content)
            local at = ry0 + (run - thumb) * (M.col_scroll / over)
            rect(kx + kw - 3 * F.scale, ry0, 2 * F.scale, run,
                 pal.a(pal.DIM, 0.2))
            rect(kx + kw - 3 * F.scale, at, 2 * F.scale, thumb,
                 pal.a(pal.DIM, 0.7))
        end
    elseif panel.note then
        txt(panel.note, kx + pad, cy + rowh / 2,
            (M.compact and 11 or 12) * F.scale, pal.READ)
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
-- and never learned there was another game or another ship to be. All three
-- open lists in place, and SPECTATE is the ship list's last row, exactly as
-- the ship page has it. Mocked in .design/start-flow, where the column won
-- over a rail along the foot and a line of pressable words.
--
-- Account was the odd one until decision 99: a door that opened the drawer on
-- a pilot page carrying the career over the account acts. The career went to
-- the site, and what was left was four short acts standing on a page of their
-- own, two presses and a panel away from the screen an account is worth
-- editing on. They are the list this stop opens now, and the pilot page and
-- its tab are gone. Mocked in .design/pilot-dropdown.
--
-- Nothing else is added. The HUD a watcher already gets, corner keys and
-- clock and score and radar and feed, is the rest of this screen. See
-- decision 61 for why a spectator's view of a game beats a panel describing
-- one as a front page.
local function landing(land, covered)
    local g = landing_geom()
    -- The slide, and how far down it has pushed everything the column holds.
    --
    -- One number moves both halves: the buttons go down by however much of the
    -- window stands above them, so at rest they are where they were drawn and
    -- fully open they are clear of the bottom edge, while the panel comes up
    -- through that same edge. What sinks is the lockup as well as the stops
    -- and the key, because the column is one object and a wordmark left
    -- hanging over an open panel is the front page refusing to get out of the
    -- way.
    -- Which stop is actually showing something. A stop is opened by a press
    -- and filled by whatever answers next, so between the two there is a frame
    -- or two where `M.col_open` names a stop with nothing behind it yet. The
    -- column stays put through those: sliding away to reveal an empty panel is
    -- worse than a stop that takes a moment to open.
    local shown = M.col_open
    if not land
       or (shown == "account" and not land.account)
       or (shown == "zone" and not land.zones)
       or (shown == "ship" and not land.panel) then
        shown = nil
    end
    local at = panel_slide(land_slide, shown and 1 or 0)
    -- With nothing open the height goes back to nought, so the next panel
    -- arrives at its own size rather than easing out of whatever the last one
    -- happened to be.
    if not shown then
        land_h.at, land_h.from, land_h.to, land_h.when = 0, 0, 0, 0
    end
    local col_top = math.min(g.mark_y - g.size, g.stops[1] and g.stops[1].y
                             or g.ky)
    local drop = at * (F.h - col_top)
    local ky = g.ky + drop
    -- The key breathes on the same clock the on-air tally swells at, and the
    -- edge is floored well above dark so the trough never reads as a key that
    -- has stopped working. `F.now` is zero under the test harness, which is
    -- what keeps the layout tests still.
    local key_hot = M.col_sel == "play_now"
    -- Everything the column holds is drawn while it is on its way out, so the
    -- movement is visible, and none of it is pressable once it has gone: a key
    -- sliding off the screen is not a key. The panel publishes its own boxes
    -- either way.
    local live = at < 0.5
    if at < 1 then
        commit_key(g.kx, ky, g.kw, g.kh, g.kpx, "PLAY NOW", key_hot)
        if live then hit(g.kx, ky, g.kw, g.kh, "play_now") end
    end
    local mark_down = at > 0.001
    if land then
        local acct_box, zone_box, ship_box =
            g.stops[1], g.stops[2], g.stops[3]
        -- What the open stop holds, as rows or as the ship panel, and the word
        -- the panel's head will call it by.
        local open, list, panel = shown, nil, nil
        local title = nil
        -- One row height, and it is the settings page's: a games row is as
        -- tall as a sound row because they are the same object.
        --
        -- These were thirty on a monitor and forty on a phone, from the days
        -- when a list was a strip that had to keep off PLAY NOW and every
        -- point of height was one the key could not have. The panel is the
        -- window now, so the room is there to spend, and forty four is the
        -- floor every platform's own ruler puts under a fingertip. It is also
        -- what a row wants before it can carry a sentence of its own: the note
        -- under a name is drawn only where the row has the two lines for it.
        local drh = (M.compact and 40 or 44) * F.scale
        if open == "account" and land.account then
            list, title = {}, "account"
            for i, a in ipairs(land.account) do
                -- The rule between what you can do to this account and how to
                -- be a different one. It arrives as a row of its own from the
                -- menu, which owns the order; the ship list writes its own
                -- because sitting out is known there by its value.
                if a.rule then
                    list[#list + 1] = {rule = true}
                else
                    -- Indexed rather than named on the wire back: these are
                    -- the interface's own words, and the value that returns
                    -- is a row of a list this frame drew.
                    list[#list + 1] = {label = a.label, value = i,
                                       action = "land_pick_account",
                                       offer = a.offer, note = a.note}
                end
            end
        elseif open == "zone" and land.zones then
            list, title = {}, "zone"
            for _, z in ipairs(land.zones) do
                -- Every game is named rather than described, so every row
                -- here is quoted.
                list[#list + 1] = {label = z.label, value = z.zone,
                                   action = "land_pick_zone", here = z.here,
                                   dim = not z.live, note = z.format,
                                   raw = true}
            end
        elseif open == "ship" and land.panel then
            -- The ship stop opens a pager rather than a list, and it is the
            -- one stop that does: what it holds is one hull at a time with
            -- its flight and its credits under it, which is not a row and
            -- cannot be made into one. See `land_panel`.
            panel, title = land.panel, "ship"
        else
            open = nil
        end
        -- The stops, riding the same slide the key does. All three are drawn
        -- whatever is open, because they are leaving rather than being
        -- replaced: the one that was pressed sinks with its neighbours, and
        -- the panel comes up through the edge they went out of. That is the
        -- whole of the sentence this movement says, and hiding the pressed
        -- stop would cut it in half.
        local before = #M.hits
        if at < 1 then
            for _, s in ipairs({
                {acct_box, "account", land.name, "land_account",
                 open == "account", {raw = true, warn = land.warn}},
                {zone_box, "zone", land.zone, "land_zone", open == "zone",
                 {raw = true}},
                {ship_box, "ship", land.ship, "land_ship", open == "ship",
                 {raw = not land.watching}},
            }) do
                local box, label, value, action, lit, o =
                    s[1], s[2], s[3], s[4], s[5], s[6]
                land_stop(box.x, box.y + drop, box.w, box.h, label, value,
                          action, lit, g.rail, o)
            end
        end
        -- A stop on its way out is not a stop: once the column is more than
        -- half gone, the boxes it just published are dropped, so nothing under
        -- the glass takes a press meant for the panel over it.
        if not live then
            for i = #M.hits, before + 1, -1 do M.hits[i] = nil end
        end
        -- And the panel, on its way up through the bottom edge. A backdrop
        -- behind everything (`pri` -1) so a press on the margin beside the
        -- glass puts it away rather than pulling a trigger on the fight.
        -- A panel with another standing over it is not drawn.
        --
        -- Glyphs come from the gui and the gui draws over every mesh, so
        -- nothing a panel lays down can cover the type of the panel beneath
        -- it: the account acts read straight through the log-in panel raised
        -- from them, two heads landing on one line. It is the rule the
        -- nameplates and the lockup already follow, and a stack is where it
        -- was always going to be needed.
        --
        -- The slide above still runs, so the column stays out and comes home
        -- when the whole stack does rather than jumping back the moment the
        -- upper panel opens.
        if open and not covered then
            -- As tall as what it holds, eased between one panel's worth and
            -- the next so opening one over another slides the glass to fit
            -- rather than swapping two rectangles.
            local want = panel and pages.ship_h(panel, drh)
                or pages.list_h(list, drh)
            local px, py, pw, ph =
                panel_geom(panel_height(land_h, math.min(want, panel_room())))
            py = py + (1 - at) * (F.h - py)
            hit(0, 0, F.w, F.h, "land_shut", nil, nil, -1)
            -- The menu's voice, for as long as the menu is the thing on
            -- screen. The HUD shouts because everything read at a glance over
            -- a fight does; a panel is read rather than glanced at, and a page
            -- of capitals is a page nobody reads twice.
            --
            -- Set here as well as in `M.menu` because the landing is the other
            -- place a panel stands, and it was the reason these lists were in
            -- capitals at all: they inherited the case of the screen they were
            -- drawn over rather than the case of the thing they are.
            local was_case = F.case
            F.case = "sentence"
            local top, foot = panel_frame(px, py, pw, ph, title, "land_back")
            if panel then
                land_panel(px, pw, top, foot, panel, drh)
            else
                land_list(px, pw, top, list, drh)
            end
            F.case = was_case
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
function M.col_walk()
    local out = {}
    -- The menu's column, while it is the one standing. Its stops and its key
    -- are boxes like any others, so the same walk carries a hand round both
    -- interfaces: what changes is which boxes were published, and the drawing
    -- has already decided that.
    if M.menu_column then
        for _, r in ipairs(M.hits) do
            if r.action == "menu_stop" or r.action == "menu_pick"
               or r.action == "menu_row" or r.action == "menu_back"
               or r.action == "menu_go"
            then
                out[#out + 1] = r
            end
        end
        return out
    end
    -- With a panel up the walk is that panel, and only it: the way back out on
    -- its head, then its rows in the order they were drawn. The stop that
    -- opened it is off the bottom of the screen and out of the walk with it,
    -- which is the point of the panel's own head carrying the way back.
    if M.col_open == "ship" then
        -- The panel walks as the way back, the ship it is on, one stop a row,
        -- and back to the hull's own build. The arrows either side of a value
        -- are not stops of their own: a hand standing on a row steps it with
        -- left and right, which is the rule the drawer's own rows follow. See
        -- `M.col_side`.
        for _, r in ipairs(M.hits) do
            if r.action == "land_back" or r.action == "land_pick_ship"
               or r.action == "land_kit_row" or r.action == "land_kit_reset"
            then
                out[#out + 1] = r
            end
        end
        return out
    end
    if M.col_open == "account" or M.col_open == "zone" then
        local pick = "land_pick_" .. M.col_open
        for _, r in ipairs(M.hits) do
            if r.action == "land_back" or r.action == pick then
                out[#out + 1] = r
            end
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

-- What left or right does where the cursor is standing, as an action and a
-- value for `land_act` to run, or nil where the two arrows mean nothing.
--
-- Only the ship panel answers. It is the one thing out here with rows that
-- hold a value rather than rows that are a choice: a build is spent with the
-- same two keys the drawer's own value rows are set with, and the roster is
-- paged with them from the ship's own row. Everywhere else left and right
-- are unread, which is why this returns nil rather than guessing.
function M.col_side(dir)
    -- In the menu, a row that holds a value is stepped by the arrows, which is
    -- how sound, music, frames, the wake and the charge keys are all set. The
    -- rows that are pages answer nothing: left is the way back out and it has
    -- its own key.
    if M.menu_column then
        if M.col_sel == "menu_row" then
            return "menu_step", {index = M.col_sel_value, dir = dir}
        end
        return nil
    end
    if M.col_open ~= "ship" then return nil end
    if M.col_sel == "land_pick_ship" then
        return "land_page_ship", dir
    end
    if M.col_sel == "land_kit_row" then
        return "land_kit_step", {slot = M.col_sel_value, dir = dir}
    end
    return nil
end

-- Where the cursor is standing in that walk, or nil for nowhere. Nowhere is
-- an ordinary answer: nothing is lit until a hand puts something there, and
-- a control can go off the screen under a hand that is not looking.
local function land_at(walk)
    for i, r in ipairs(walk) do
        if r.action == M.col_sel and r.value == M.col_sel_value then
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
function M.col_step(dir)
    local walk = M.col_walk()
    if #walk == 0 then return false end
    local at = land_at(walk)
    if at then
        at = (at - 1 + dir) % #walk + 1
    else
        at = dir > 0 and 1 or #walk
    end
    M.col_sel, M.col_sel_value = walk[at].action, walk[at].value
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
function M.col_go()
    local walk = M.col_walk()
    local at = land_at(walk)
    if at then return walk[at].action, walk[at].value end
    -- Nothing lit falls through to the key, which is the one thing either
    -- column exists for: PLAY NOW out here, RESUME in the menu. A keyboard
    -- that had to walk to it would be a screen nobody can leave.
    if M.menu_column then return "menu_go", nil end
    if M.col_open then return nil end
    return "play_now", nil
end

-- Before a room answers: the landing with everything that needs a room taken
-- off it.
--
-- Not a screen of its own. It is the same starfield with the same name in the
-- same place, so when the stands arrive the only thing that happens is that
-- the room, the stops and the menu key appear. Nothing already on screen
-- moves. The instruments a watcher gets are all about a room this
-- client has not found yet, so the radar and the roster are simply absent
-- rather than drawn empty.
--
-- What used to be here was a lockup centered in the window, which was the
-- loading screen held one beat longer and read as a third screen between the
-- loader and the game. The logo moved when the game arrived, which is the one
-- thing the hand-off should never do.
function M.waiting(note)
    M.foot_key, M.menu_column = false, false
    landing_mark()
    -- The one control, drawn here rather than through the corner row, which
    -- carries a roster this screen has not got.
    --
    -- No menu key. There is no room yet, so there is nothing for a menu to be
    -- about: leaving, sides and settings are all things a room has, and the
    -- column that holds them arrives with the room. This screen is the
    -- wordmark, and a note when the fleet is down.
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
    -- Whether the menu key is drawn at the foot: in a room you are in, and
    -- nowhere else. A screen still waiting on its first room clears this
    -- itself (see `M.waiting`), and the front page is the other half of the
    -- same rule.
    --
    -- The landing watches a live room, so for a while it carried the key on
    -- the argument that a room on the screen is a room to have a menu about.
    -- It is not one you are in. Everything the menu holds is about the room
    -- you took a seat in: the way out of it, which side you are on, and the
    -- machine you are flying it on. Out here none of those has an answer yet,
    -- and the three stops above PLAY NOW are the choices that do. A faint
    -- fourth control under the one key the screen exists for was the whole of
    -- what it added.
    M.foot_key = not o.landing
    -- And whether the menu's own column is the one standing, which is what the
    -- one walk reads to know which set of boxes it is walking.
    M.menu_column = o.menu_open or false
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
    -- `o.card` is the menu's own question, which is raised from the landing's
    -- account stop and drawn by `M.land_card` after this returns. The room's
    -- question beside it has always been read off `M.room_ask`, and this one
    -- was not read at all: a sign-up card washed the meshes behind it and left
    -- every instrument's label at full brightness, which is the exact fault
    -- the paragraph above is about. It went unnoticed while the only card the
    -- interface raised stood inside a drawer that was always up.
    local reading = M.details and not o.menu_open and not ending
    F.text_dim = (ending or o.menu_open or o.card or M.room_ask or reading)
        and 0.34 or 1

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
    -- in front of it does not. Not under an open menu: that is a panel over
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
        -- And under that, the pilot a row was pressed on. It belongs to this
        -- column and is drawn with it, rather than after the instruments: all
        -- three are one panel with one wash behind them.
        inspect(o, top)
        F.text_dim = behind
    end
    -- Names hanging off ships, but not under anything being read over the
    -- arena. Glyphs come from the gui and the gui draws over every mesh, so
    -- nothing a panel lays down can cover them: a panel with six pilots'
    -- names scattered through it reads as a fault rather than as depth. The
    -- instruments stay, your bars and the dial and the feed, because you can
    -- still be shot while you are reading, and those are what say so.
    --
    -- The ending is text over a card and lands in the same trap, so it takes
    -- the plates down with it for the twenty five seconds it is up. So does
    -- the menu's own column, and so does a question card.
    --
    -- And so does the landing's column, which is where this was noticed: the
    -- front page is a live room, the ship stop opens a panel that climbs from
    -- its own stop to the top of the window, and every call sign in the fight
    -- behind it was drawn through the build a pilot was reading. It went
    -- unseen while `menu_open` was the only name on this line, because that
    -- was true of the drawer and the drawer was where a panel used to stand.
    if not (o.menu_open or ending or M.col_open or o.card or M.room_ask) then
        nameplates(o)
    end
    -- One corner, one instrument. The map is the radar pulled back to the
    -- whole thousand tiles, so it stands where the radar stands rather than
    -- somewhere else with the radar still lit beside it.
    -- The dial's corner, in every state there is. It used to stand down under
    -- an open drawer, which on a phone was the whole window; the column stands
    -- at the foot and reaches no corner, so the radar and the clock band are
    -- on screen while the menu is up. That is the point of a menu that does
    -- not pause: a pilot reading it is still being shot at, and the two
    -- instruments that say so keep saying it.
    dial()
    if M.map then overview(me) else radar(o.cam_x, o.cam_y, me) end
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
    -- What the stick's rim says. touch.lua works out the sentence and where it
    -- goes, in its own space of drawable pixels counting up from the bottom;
    -- this flips it into the one type is measured in and draws it. Raw,
    -- because it is already in the case it wants, and centered on the stick's
    -- middle so it stays put as the words change length.
    if M.touching and o.stick_hint then
        local hint = o.stick_hint
        -- Around the foot of the stick's own rim rather than on a line under
        -- it: the thing being labelled is a circle, and a straight run below
        -- it reads as a caption for the screen instead of for the control.
        arc_txt(hint.text, hint.x, hint.y, hint.r, -math.pi / 2,
                TYPE.LABEL * F.scale, hint.col)
    end
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
    -- The corner row keeps its line under an open menu. The column stands at
    -- the foot and reaches no corner, so nothing up here has to stand down for
    -- it any more: PLAYERS, the seat and the room chip are all readable while
    -- a pilot is in settings, which is the point of a menu that does not
    -- pause.
    corner_row(o.on_air and not o.watch, o.watch,
               several and o.room or nil, o.landing)
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
    --
    -- The ending for the same reason and more so. It washes the whole window
    -- and then draws the block at full strength on top, and the countdown is
    -- part of what it is saying rather than something behind it: at a third
    -- of an alpha the one number on screen that is still moving was the
    -- faintest thing on it.
    if reading or ending then F.text_dim = 1 end
    -- Through the ending as well, which is the whole point of a band: the
    -- clock is one instrument in one place, and a player who has spent three
    -- minutes reading the top of the window does not have to find it
    -- somewhere else the moment the whistle goes. The ending's own head
    -- carries the score, so the band gives its two sides up while that block
    -- is on screen and keeps the numerals. See `match_clock`.
    match_clock(o, o.match, o.side_names, o.menu_open)
    match_note(o, o.match)
    -- The menu key, at the foot, wherever there is a room to have a menu
    -- about and no column standing on the spot already. It is drawn from here
    -- rather than by the column so it survives the early return below: the
    -- ending washes the window and the key still has to be pressable under it.
    if M.foot_key and not o.menu_open then
        local kx, ky = foot_key_box()
        local kw = burger_cap(kx, ky, M.col_sel == "open")
        hit(kx, ky, kw, BURGER.h * F.scale, "open")
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
    if o.landing then landing(o.land, o.card) end
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
        txt("D E S T R O Y E D", F.w / 2, F.h * 0.46,
            (M.compact and 15 or 22) * F.scale, pal.ENEMY, "center")
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

-- One circle, in the three states a count has.
--
-- Solid is one in hand, a ring is a slot a spent one leaves, and a dim grey
-- ring is a rung this ship does not reach. One mark with three fills is a
-- grammar a pilot learns once.
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
})


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

-- The sentence, broken to the room the row has for it. `w` is the column.
--
-- Cased once over the whole sentence and drawn raw: left to `txt`, the case
-- is applied to each line as it is drawn, and a sentence that wrapped came
-- back with a capital in the middle of itself.
function pages.note_lines(note, w)
    if not note or note == "" then return nil end
    return wrapped(cased(note), pages.NOTE_PX * F.scale,
                   math.max(40 * F.scale, w), MENU_FONT)
end

-- One row of the stage: a mark for the one you are on, the name, and
-- whatever the row has to say about itself on the right.
--
-- `hot` is the cursor, from either hand: the row the arrows are on while the
-- stage has them, or the row a pointer is resting on.
--
-- One row of one menu, and there is only one kind.
--
-- The menu used to answer "what is a row" three ways. The games and account
-- lists set theirs in the HUD's twelve point mono capitals, because they grew
-- out of a list drawn over a fight; the settings page set its in the menu's
-- own face at seventeen, sentence case; a hull's slots were a third shape
-- again with their own height and their own arrows. Walking from the games
-- list into settings into a ship changed dialect twice, and none of it had
-- been decided: each was written by whoever wrote the page.
--
-- So: one shape. The name at the left in the menu's voice, and the right hand
-- end says what the row does. Six ends and nothing else varies:
--
--   opens     `caret`   -- a panel comes up over this one
--   reads     `detail`  -- a value, in the mono, with no control
--   steps     `step`    -- arrows either side of a count
--   fills     `choice`  -- one cell per value, the word beside them
--   switches  `toggle`  -- the box, lit and to the right for on
--   walks     `walk`    -- arrows at the edges, the name between them
--
-- and the states that can be true of any of them: `hot` where a press would
-- land, `mark` where you already are, `tint` for a side, `offer` for the one
-- row that is an offer, `dim` for a row that cannot act.
--
-- `x`/`w` are the type column, not the panel: the field a state lights runs
-- the panel's full width and is laid down by the caller, which is the only
-- thing that knows where the glass ends.
function menu_row(x, y, w, h, r, hot)
    local col = r.mark and pal.FRIEND or pal.INK
    -- The one row that is an offer rather than a choice wears the caution
    -- color, which is the color of the dot on the stop it hangs under: one
    -- warning, said twice in one hue. And a row that cannot act is dimmed,
    -- which is the whole of what it has to say.
    if r.offer then col = pal.CHARGE_COL end
    if r.dim then col = pal.a(pal.DIM, 0.8) end
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
        LIT.field(x, y, w, h, LIT.CURSOR)
    elseif r.mark then
        -- Where you already are, at the standing weight. This was a lit wedge
        -- out in the gutter; the field says the same thing without spending a
        -- mark on it, and without pushing its own label out of the column.
        LIT.field(x, y, w, h, LIT.HERE)
    end
    -- One text column, whatever the row is, and it is the column the title
    -- above the list is set in.
    local tx = x
    local sel = hot or r.mark
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
    -- A row you are choosing between, rather than one setting a value, sets
    -- its name half again as large, which is how the mocks draw both: it is
    -- the name that is being read, and what is under it is the reading.
    --
    -- Declared under `note` rather than over it, which is the whole of what
    -- was wrong here: read above its own `local`, `note` is a global, a
    -- global is nil, and the larger size this chooses never once applied.
    -- That is the bug .luacheckrc exists to catch, and it caught this one.
    local size = TYPE.ROW * F.scale
    if note and h >= 44 * F.scale then
        size = TYPE.LEAD * F.scale
    end
    local ly = note and (y + h * 0.36) or (y + h / 2)
    -- Drawn here unless the detail turns out not to fit beside it, in which
    -- case the pair is laid out as two lines below and this one is skipped.
    --
    -- Asked as the question it is: what is left of the column once the name
    -- has had its share, against what the detail needs. It was the column's
    -- width less three constants that between them stood for the name, and
    -- they were measured against a column that has since changed width at
    -- both edges, so a phone's help rows went back to being drawn over their
    -- own labels the moment the column moved.
    -- Only a row whose end is a plain reading can drop that reading onto a
    -- second line. Every end that carries a control returns before the block
    -- that would have drawn the label there, so a row wearing one and
    -- answering true here would lose its name entirely.
    local two_line = r.detail and r.detail ~= ""
        and not r.choice and not note
        and not (r.caret or r.walk or r.toggle or r.step)
        and text_w(r.detail, 12 * F.scale)
            > w - text_w(r.label or "", size, MENU_FONT) - 16 * F.scale
    if r.walk then
        -- The one row whose name is not at the left edge: what is being paged
        -- is the name itself, so it stands between the two arrows that page
        -- it rather than beside one of them.
        txt(r.label or "", x + w / 2, ly, size,
            pal.a(col, label_a), "center", MENU_FONT, r.named)
    elseif not two_line then
        txt(r.label or "", tx, ly, size,
            pal.a(col, label_a), nil, MENU_FONT, r.named)
    end
    if note then
        -- Centered on the line one line would have sat on, so a row whose
        -- sentence fits is drawn exactly where it always was and a row whose
        -- sentence takes two grows into the room the list gave it, evenly,
        -- rather than hanging off the top of the gap.
        local lines = pages.note_lines(note, w)
        local ny = y + h * 0.68
            - (#lines - 1) * pages.NOTE_LINE * F.scale / 2
        for _, line in ipairs(lines) do
            txt(line, tx, ny, pages.NOTE_PX * F.scale, pal.READ,
                nil, MENU_FONT, true)
            ny = ny + pages.NOTE_LINE * F.scale
        end
    end
    -- The right hand side is data, so it stays in the face the numbers in
    -- flight are set in: a call sign, a count, a hull's name.
    --
    -- The four ends below are the ones that carry a control. They are drawn
    -- before `choice` and `detail` because a row wears exactly one end, and
    -- these are the ones that publish a press of their own.
    if r.caret then
        -- Opens. Two strokes at the right edge saying a panel is about to
        -- come up over this one, which is the same promise the landing's
        -- stops make with the same mark.
        land_caret(x + w - 4 * F.scale, y + h / 2,
                   pal.a(pal.INK, hot and 0.95 or 0.75))
        if r.detail and r.detail ~= "" then
            txt(r.detail, x + w - 18 * F.scale, ly, TYPE.BODY * F.scale,
                pal.READ, "right", nil, r.verbatim)
        end
        return
    end
    if r.walk then
        -- Walks. The arrows go to the row's own edges and the name stands
        -- between them, because what is being paged is the name: this is the
        -- ship page's old second head, folded into an ordinary row so a panel
        -- heads itself once. `walk` is the action the two arrows publish.
        local mid = y + h / 2
        for _, d in ipairs({{-1, x + 10 * F.scale}, {1, x + w - 10 * F.scale}}) do
            local dir, ax = d[1], d[2]
            F.layer:tri(ax + dir * 6 * F.scale, ry(mid),
                        ax - dir * 5 * F.scale, ry(mid - 7 * F.scale),
                        ax - dir * 5 * F.scale, ry(mid + 7 * F.scale),
                        pal.a(pal.FRIEND, 0.9))
            hit(ax - 18 * F.scale, y, 36 * F.scale, h, r.walk, dir, nil, 1)
        end
        return
    end
    if r.toggle then
        -- Switches. The box it is: lit and to the right for on.
        local sw = 34 * F.scale
        local sh = 18 * F.scale
        local sx = x + w - sw
        local sy = y + (h - sh) / 2
        local lit = (r.step and r.step.value or 0) > 0
        rect(sx, sy, sw, sh, pal.a(pal.FRIEND, lit and 0.18 or 0))
        F.layer:frame(sx, ry(sy, sh), sw, sh, 1.0 * F.scale,
                      pal.a(lit and pal.FRIEND or pal.RADAR_TILE, 0.75))
        local k = sh - 4 * F.scale
        rect(lit and (sx + sw - k - 2 * F.scale) or (sx + 2 * F.scale),
             sy + 2 * F.scale, k, k,
             pal.a(lit and pal.FRIEND or pal.DIM, lit and 0.95 or 0.6))
        local s = r.step
        if s and (lit or s.can_up) then
            hit(sx - 8 * F.scale, y, sw + 16 * F.scale, h, s.action,
                {slot = s.slot, dir = lit and -1 or 1}, nil, 1)
        end
        return
    end
    if r.step then
        -- Steps. A count between the two arrows that move it.
        --
        -- What the count reads at is the row's to say. Every slot but one
        -- counts what has been bought, so nothing bought is a nought; a rung
        -- is which weapon off the hull's ladder, and a hull nobody has spent
        -- on is still firing the first one rather than none. Its color is off
        -- the spend either way: rung one is dim because it cost nothing.
        local s = r.step
        local vx = x + w - 26 * F.scale
        local mid = y + h / 2
        -- What the row reads at, which is the row's to say: every slot but
        -- two counts what has been bought, a rung counts from one because a
        -- hull nobody has spent on still fires its first gun, and shrapnel
        -- reads the fragments a rung throws rather than the rung. The color is
        -- off the spend either way, so rung one is dim because it cost nothing.
        txt(tostring(s.reads or (s.value + (s.base or 0))),
            vx - 24 * F.scale, mid, TYPE.BODY * F.scale,
            s.value > 0 and pal.FRIEND or pal.a(pal.DIM, 0.9), "center")
        for _, d in ipairs({{-1, vx - 54 * F.scale, s.can_down},
                            {1, vx, s.can_up}}) do
            local dir, ax, live = d[1], d[2], d[3]
            F.layer:tri(ax + dir * 4.5 * F.scale, ry(mid),
                        ax - dir * 4 * F.scale, ry(mid - 5.5 * F.scale),
                        ax - dir * 4 * F.scale, ry(mid + 5.5 * F.scale),
                        pal.a(pal.FRIEND, live and 0.9 or 0.25))
            if live then
                hit(ax - 14 * F.scale, y, 28 * F.scale, h, s.action,
                    {slot = s.slot, dir = dir}, nil, 1)
            end
        end
        return
    end
    if r.choice then
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
            -- A sentence that would not fit beside its label goes under it,
            -- and goes there a rung smaller: it is a caption on the row rather
            -- than a second reading. The column is a floating panel and stands
            -- 28 points in from the glass, where the drawer was docked to the
            -- edge and had those points, so the longest of these (the thumb
            -- sentences on the controls board, "Left thumb: point where you
            -- want the nose") ran past the panel it was set in.
            txt(r.label or "", tx, y + h * 0.32, size,
                pal.a(col, label_a), nil, MENU_FONT, r.named)
            txt(r.detail, tx, y + h * 0.70, TYPE.LABEL * F.scale, pal.READ,
                nil, nil, r.verbatim)
        else
            txt(r.detail, x + w, ly, TYPE.BODY * F.scale,
                r.mark and pal.FRIEND or pal.MUTE, "right",
                nil, r.verbatim)
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
    -- A card with lines to fill in is taller by each of them.
    local ch = 110 * F.scale
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

-- What an account act opens, which is a panel like everything else a menu
-- opens.
--
-- It was a card: a small centered rectangle on a ground of its own at 0.98,
-- outlined in a color nothing else here uses, with no way back on it and no
-- glass behind it. That made it the one menu surface in the game that was not
-- a panel, and the odd one out on every count the language names -- ground,
-- head, voice and key.
--
-- So it is a panel. The head names the act and carries the way back, the lines
-- to fill in are the panel's rows, and the answer that commits is the
-- breathing key at its foot, which is what PLAY NOW and RESUME already are.
-- Pressing back is pressing cancel: the two were always the same act, and one
-- of them had no button.
--
-- A question with no lines to fill in is not this. `M.room_card` asks whether
-- to move room, and a question about a destructive act with two equal answers
-- is a confirm rather than a menu: it stays a card, deliberately, and says so.
--
-- The caller decides when: while the menu column is up or sliding, `M.menu`
-- draws the card and this must not, or the wash goes down twice and the second
-- copy takes the hits.
function M.land_card(a)
    if not a then return end
    if not a.fields then return ask_card(0, 0, F.w, F.h, a) end
    -- Nothing behind this is listening, and hit boxes are first come first
    -- served, so the ones already published go: a press on the panel this
    -- opened over would otherwise answer a question it cannot see.
    rect(0, 0, F.w, F.h, pal.a(pal.BG, 0.35))
    M.hits = {}
    F.text_dim = 1
    local was_case = F.case
    F.case = "sentence"
    -- The head, a note where it carries one, a line apiece, and the commit at
    -- the foot with its own margin. As tall as that and no taller: a panel
    -- asking for one password is not the height of the window.
    local kh = (M.compact and 44 or 50) * F.scale
    local said = a.status or a.note
    local want = pages.HEAD_H * F.scale + 10 * F.scale
        + (said and 34 * F.scale or 0)
        + #a.fields * 48 * F.scale
        + kh + 28 * F.scale
    local px, py, pw, ph =
        panel_geom(panel_height(land_h, math.min(want, panel_room())))
    -- Back is cancel, which is the last of the answers the card carries. It
    -- travels the way every other answer does, by its place in that list.
    local top = panel_frame(px, py, pw, ph, a.head or "", a.action or "answer",
                            nil, #a.keys)
    local pad = 14 * F.scale
    -- What signing up buys, or what the fleet said about the last press. A
    -- status supersedes the note while it stands and wears the caution color,
    -- since the two it carries are "wait" and "that did not work".
    if said then
        txt(said, px + pad, top + 12 * F.scale, TYPE.BODY * F.scale,
            a.status and pal.CHARGE_COL or pal.READ)
        top = top + 34 * F.scale
    end
    local fx, fw = px + pad, pw - 2 * pad
    local fy = top + 10 * F.scale
    -- The lines go to the page wherever there is a page to take them, which is
    -- every build that runs in a browser and no other: a password manager can
    -- fill a form and cannot fill a drawing.
    local dom = M.page_fields and true or false
    if dom then M.ask_dom = ask_spec(fx, fy, fw, a) end
    for i, f in ipairs(a.fields) do
        local lit = not a.sending and i == (a.field or 1)
        fy = fy + field_line(fx, fy, fw, f, lit, dom)
        -- A tap on a line moves the caret to it, the way a tap on a form's
        -- line does everywhere else a phone is used. Not where the page holds
        -- the line: the element covers this rectangle and answers the same tap
        -- itself, and a target underneath it would only be reachable by
        -- missing the one that works.
        if not dom then
            hit(fx, fy - 48 * F.scale, fw, 46 * F.scale, "field", i)
        end
    end
    -- And the commit, at the foot of what it commits.
    local ky = py + ph - pad - kh
    commit_key(fx, ky, fw, kh, (M.compact and TYPE.BODY or TYPE.ROW) * F.scale,
               a.keys[1] and a.keys[1].label or "", a.sel == 1)
    hit(fx, ky, fw, kh, a.action or "answer", 1)
    F.case = was_case
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

-- --- the column ------------------------------------------------------------

-- How far the column has come up, 0 down and 1 fully up, and the state of that
-- slide between frames. It travels on `COLUMN_SPAN` and `column_ease`, which
-- the panel a stop opens shares: the two movements are halves of one gesture,
-- so they had better agree about how long it takes.
M.column = 0            -- 0 down, 1 fully up
local col_from, col_to, col_at = 0, 0, 0

-- Whether the column is on screen at all, up or still leaving. The arena
-- draws it while this is true and stops when it goes false.
function M.column_up()
    return M.column > 0.001
end

function M.column_shut()
    M.column, col_from, col_to, col_at = 0, 0, 0, 0
end

-- Where the rows stood last frame, and how wide. Published for the same reason
-- the drawer's span was: a row's lit field runs the full width of whatever it
-- is drawn on, and the thing that lights it is a long way from the thing that
-- measured it. That surface is the column while nothing is open and the panel
-- once a stop opens one, so this follows the rows rather than the stops.
local column_x, column_w = 0, 0
function M.column_span()
    return column_x, column_w
end

-- The wash behind the column.
--
-- Thin, and thin on purpose. Nothing pauses: the ship goes on flying under
-- this, the radar goes on sweeping and the clock goes on running, so a curtain
-- would be the interface telling a lie about what the simulation is doing. It
-- is enough to settle the fight behind the type and no more, which means a
-- pilot reading their own settings can watch trouble arrive and press RESUME
-- before it does.
local COLUMN_WASH = 0.42

-- The row the settings panel last scrolled itself to, so it follows the cursor
-- on the frame the cursor moved and not on every frame after it.
local page_followed = nil

-- The whole of the in-game menu: three stops over a breathing key, standing
-- where the key that raised them stood.
--
-- `v` is `menu.view()`. It carries the stops, and the rows of whichever stop is
-- open, and that is the whole payload. What it replaced was a rail of tabs, a
-- stage, a topbar, a head row and a preview of the page the rail cursor was
-- resting on: five answers to "where am I" on a panel four pages deep. A lit
-- stop with its panel climbing off it is one answer, and it is the answer the
-- landing has always given.
function M.menu(v)
    local n = v.stops and #v.stops or 0
    if n == 0 then return end
    -- The HUD shouts, because everything in flight does; the menu speaks. A
    -- row that says "Sound" is a label and one that says "SOUND" is an
    -- instrument reading, and these are labels. Restored on the way out,
    -- since anything drawn after the column is the arena's again.
    local was_case = F.case
    F.case = "sentence"
    local g = menu_geom(n)
    column_x, column_w = g.kx, g.kw
    -- The slide. `F.now` is zero under the test harness, which is what settles
    -- the column instantly there and keeps the layout tests still.
    local want = v.open == false and 0 or 1
    if want ~= col_to then
        col_from, col_to, col_at = M.column, want, F.now
    end
    if F.now <= 0 then
        M.column = want
    else
        local t = math.min(1, (F.now - col_at) / COLUMN_SPAN)
        M.column = col_from + (col_to - col_from) * column_ease(t)
    end
    -- Off the bottom by whatever is left of the slide, so the column rises out
    -- of the key's own strip and sinks back into it.
    local rise = (1 - M.column) * (F.h - g.top)
    local hits_before = #M.hits
    -- And a second slide inside the first: the stop that is open sends the
    -- column back out through the bottom edge and brings a panel up through
    -- it, exactly as the landing's stops do. One grammar for both columns was
    -- the point of decision 102, so it holds for what a stop opens too.
    local open = nil
    for _, s in ipairs(v.stops) do
        if s.open then open = s end
    end
    local at = panel_slide(menu_slide, open and 1 or 0)
    if not open then
        menu_h.at, menu_h.from, menu_h.to, menu_h.when = 0, 0, 0, 0
    end
    local drop = at * (F.h - g.top)
    local live = at < 0.5

    wash(0, 0, F.w, F.h, pal.a(pal.BG, COLUMN_WASH * M.column))
    -- A press anywhere off the column puts it away, which is what tapping
    -- beside a panel means everywhere. Under everything else: the lowest
    -- priority box on the screen.
    hit(0, 0, F.w, F.h, "menu_shut", nil, nil, -2)

    -- The key first, under the stops that stand over it, the way the landing
    -- draws PLAY NOW first.
    local ky = g.ky + rise + drop
    local key_hot = M.col_sel == "menu_go"
    if at < 1 then
        commit_key(g.kx, ky, g.kw, g.kh, g.kpx, "RESUME", key_hot)
        if live then hit(g.kx, ky, g.kw, g.kh, "menu_go", nil, nil, 1) end
    end

    -- Then the stops. All of them, including the open one: they are leaving
    -- rather than being replaced, and the panel comes up through the edge they
    -- went out of. Hiding the pressed stop would cut that sentence in half.
    -- Once they are wholly past that edge they stop being drawn at all.
    local stops_at = #M.hits
    if at < 1 then
        for i, s in ipairs(v.stops) do
            local box = g.stops[i]
            local sy = box.y + rise + drop
            land_stop(box.x, sy, box.w, box.h, s.label, s.value,
                      "menu_stop", s.open, false,
                      -- Leave acts rather than opening, so no caret.
                      {raw = s.named, value = s.stop,
                       flat = s.stop == "leave"})
            -- The stop's own mark where it has no word to say: settings is
            -- the mixer, and it is the one stop here whose answer is a page
            -- rather than a value.
            if s.mark then
                draw_mark(s.mark, box.x + box.w - 26 * F.scale,
                          sy + box.h / 2, 8 * F.scale,
                          pal.a(pal.INK, 0.9), 0)
            end
        end
    end
    -- A stop on its way out is not a stop.
    if not live then
        for i = #M.hits, stops_at + 1, -1 do M.hits[i] = nil end
    end

    if open then
        -- The sides, one row each. A row per side rather than a stepper: with
        -- three or more, arrows would walk a pilot through every team between
        -- here and the one they want.
        local list = nil
        if open.stop == "side" then
            list = {}
            for _, r in ipairs(v.rows) do
                list[#list + 1] = {label = r.label, note = r.detail,
                                   raw = r.named, here = r.mark,
                                   tint = r.tint,
                                   action = "menu_pick", value = r.index}
            end
        end
        -- As tall as what it holds, eased between one page's worth and the
        -- next: walking from settings into the controls board slides the glass
        -- to the new page's height rather than swapping two rectangles.
        local noted = false
        for _, r in ipairs(v.rows) do
            if r.note then noted = true end
        end
        local tall = list and pages.list_h(list, g.rh)
            or pages.page_h(v, (M.compact and 40 or 44) * F.scale,
                            24 * F.scale, noted)
        local px, py, pw, ph =
            panel_geom(panel_height(menu_h, math.min(tall, panel_room())))
        -- The panel rides the column's own slide as well as its own, so
        -- dismissing the whole menu with a page open takes the page with it
        -- rather than leaving it standing over the fight.
        py = py + (1 - at) * (F.h - py) + rise
        -- The rows are the panel's now, so that is the span they are lit at.
        column_x, column_w = px, pw
        if list then
            local top = panel_frame(px, py, pw, ph, open.label, "menu_back")
            land_list(px, pw, top, list, g.rh)
        else
            -- Settings, and the pages it opens, which name themselves on the
            -- head rather than being named by the stop: one level in, the head
            -- says settings; two levels in, it says controls, and back steps
            -- one of those at a time.
            local top, foot = panel_frame(px, py, pw, ph, v.page or open.label,
                                          "menu_back", v.foot)
            M.menu_panel(px, pw, top, foot, v)
        end
    end

    -- While the column is going away it still draws, so the fight behind it
    -- comes back through a wash that is fading rather than a panel that
    -- vanished. Nothing it published can be pressed, though: a key on the way
    -- out is not a key.
    if v.open == false then
        for i = #M.hits, hits_before + 1, -1 do M.hits[i] = nil end
    end
    F.case = was_case
end

-- The settings panel's rows, laid into the panel the stop opened.
--
-- Its own function because it is the one part of the column that scrolls, and
-- because the rows are the drawer's rows: sections, values drawn as the range
-- they sit in, sentences under the row they explain, and a control waiting for
-- a key. That vocabulary was the good half of the panel this replaced, and
-- none of it was about being a drawer.
--
-- The glass and the head belong to `panel_frame` now, which is what lets the
-- settings page and a landing stop be the same object: `top` and `bottom` are
-- the room it left. The page used to measure its own height against a ceiling
-- that kept the clock band clear, and to shrink to whatever its rows wanted.
-- Both are gone with the full-height panel, and the second of them was the
-- bug: eight rows and two bands asked for more than the strip above the column
-- had, so the page overran the stops it was standing on.
function M.menu_panel(kx, kw, top, bottom, v)
    -- The one measure every panel insets its rows by. This page had its own,
    -- which is how the settings rows came to start two points inside every
    -- other row in the game.
    local pad = 14 * F.scale
    local rowh = (M.compact and 40 or 44) * F.scale
    -- A run of rows under a small label and a rule, which is how the ship
    -- panel bands its own sections and how the settings page has always
    -- grouped: audio, video, the machine. What a band says is what the rows
    -- under it are about, and it is the one thing a page of eight settings
    -- cannot say in its title.
    local secth = 24 * F.scale
    local noted = false
    for _, r in ipairs(v.rows) do
        if r.note then noted = true end
    end
    local rh = noted and rowh + pages.NOTE_LINE * F.scale or rowh
    local view_h = bottom - top
    -- Where the rows were drawn, for a wheel and a dragging thumb to be tested
    -- against. The same four numbers the drawer's pages published, read back
    -- by `M.page_span`.
    M.page_x, M.page_y, M.page_w, M.page_h = kx, top, kw, view_h
    -- Scrolled by whole rows, which is the rule the ship panel follows: a
    -- panel that stops halfway down a row asks a reader to decide whether the
    -- half they can see is worth scrolling for.
    local extent = 0
    for _, r in ipairs(v.rows) do
        extent = extent + rh + (r.sect and secth or 0)
    end
    local max_scroll = math.max(0, extent - view_h)
    if M.page_scroll > max_scroll then M.page_scroll = max_scroll end
    if M.page_scroll < 0 then M.page_scroll = 0 end
    -- And it follows the cursor, since walking with a pad or the arrows is how
    -- this is read without a pointer: a row lit under the fold is a row nobody
    -- can see themselves setting. On the frame the cursor moved and no other,
    -- which is what keeps a finger dragging it from being hauled back.
    if M.col_sel == "menu_row" and page_followed ~= M.col_sel_value then
        page_followed = M.col_sel_value
        local at = 0
        for i, r in ipairs(v.rows) do
            if i == M.col_sel_value then break end
            at = at + rh + (r.sect and secth or 0)
        end
        if at < M.page_scroll then
            M.page_scroll = at
        elseif at + rh > M.page_scroll + view_h then
            M.page_scroll = at + rh - view_h
        end
        M.page_scroll = math.max(0, math.min(M.page_scroll, max_scroll))
    elseif M.col_sel ~= "menu_row" then
        page_followed = nil
    end
    -- Nothing draws outside the panel. A row's own sentence is the one thing
    -- here whose length this file does not choose: the thumb sentences on the
    -- controls board run to forty characters, and at a landscape phone's 240
    -- points they ran off the panel and over the fight beside it. Cut at the
    -- panel's edge, which is what the landing's stops already do with a long
    -- game name.
    local kept_clip = F.clip_r
    local edge = math.min(kept_clip or math.huge, kx + kw - pad)
    local y = top - M.page_scroll
    for i, r in ipairs(v.rows) do
        if r.sect then
            if y + secth > top and y < top + view_h then
                hrule(kx, y, kw, 0.45)
                lbl(r.sect, kx + pad, y + secth / 2, pal.MUTE)
                hrule(kx, y + secth, kw, 0.45)
            end
            y = y + secth
        end
        if y + rh > top and y < top + view_h then
            local hot = M.col_sel == "menu_row" and M.col_sel_value == i
            -- The clip goes around the drawing and not around the box a press
            -- lands in. A row is pressable to the panel's own edge; what is
            -- cut is only the type that would have run past it.
            F.clip_r = edge
            menu_row(kx + pad, y, kw - 2 * pad, rh, r, hot)
            F.clip_r = kept_clip
            if r.pick then
                hit(kx, y, kw, rh, "menu_row", i, nil, 1)
            end
        end
        y = y + rh
    end

    -- A thumb down the edge where there is more than fits.
    if extent > view_h then
        local bar = math.max(30 * F.scale, view_h * view_h / extent)
        local at = (M.page_scroll / math.max(1, max_scroll)) * (view_h - bar)
        local sx = kx + kw - 3 * F.scale
        rect(sx, top, 3 * F.scale, view_h, pal.a(pal.DIM, 0.12))
        rect(sx, top + at, 3 * F.scale, bar, pal.a(pal.RADAR_TILE, 0.8))
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
