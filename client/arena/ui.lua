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
-- Which pilot's card is open over the players sheet, by ship index, or nil
-- for the sheet itself. The interface's own state rather than the menu's, for
-- the reason the ship stop's open section is: how deep a panel is walked is a
-- fact about the screen. See `pages.board_card`.
M.col_pilot = nil
-- The connection, in numbers, behind the link bars over the dial. Off by
-- default and on no page, because it is for whoever is working on the client
-- rather than for whoever is flying.
M.debug = false
-- Which part of a ship the ship stop has open over its own menu: "body",
-- "guns", "bombs", "specials", "flair", or nil for the menu itself.
--
-- The one stop with a second level. It holds five parts of a ship and each
-- opens over the others, which is the stack decision 103 gave every panel and
-- the first surface to want it: back steps out of a section onto the ship
-- menu before it steps off the ship menu onto the column. Which stop is open
-- is `menu.stack`; this is how deep inside that one stop a hand has walked,
-- and it is cleared whenever the stop shuts.
M.col_sect = nil
-- Which ship the body section's carousel is turned to: a class, or the count
-- of them for sitting out. Nothing is chosen by turning, so this is a place in
-- a list rather than a decision, and it goes back to the ship being flown
-- every time the section is opened.
M.col_hull = nil
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

-- The two states a row can be lit in, laid at the span the caller hands in.
--
-- Every page calls this with the glass's own left edge and full width, and
-- every page draws its type inside that. A row lit short of the panel's edge
-- is a box floating on a panel: it was drawn at the type column for a while,
-- fourteen points in on each side, and on the settings page that was the only
-- field there was.
function LIT.state(x, y, w, h, hot, mark)
    if hot then
        LIT.field(x, y, w, h, LIT.CURSOR)
    elseif mark then
        LIT.field(x, y, w, h, LIT.HERE)
    end
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

-- The wing the badge wears, as a band swept back off the hull and cut into
-- three.
--
-- One table because this file is at the two hundred locals a Lua chunk may
-- hold, and because the numbers only mean anything together. See
-- client/tests/upvalues_test.lua.
--
-- The feathers were three strokes with a round cap, cut for the eleven points
-- the scoreboard draws this at, where a feather is a point across and a cap
-- is a rounding error. The menu now draws the same mark at a hundred and
-- thirty, and there the three are fourteen points across with a half circle
-- on each end, which is three sausages. What was wrong with them is the pen
-- rather than the arrangement, so the arrangement barely moved:
--
-- **They are parallel.** They sat at 32.1, 28.3 and 30.8 degrees, close
-- enough to look like a mistake and far enough to lose the even gap the roots
-- were cut for. All three are 30 now, and each runs out to `rake`, the line
-- the old tips already lay on: the bottom feather lands within a thousandth
-- of where it was and the middle one within two hundredths.
--
-- **Both ends are cut on a line.** The tips on `rake` and the roots on
-- `root_line`, which is the hull's own leading edge and the thing the roots
-- were placed against in the first place. So the wing is one band with a
-- clean edge either side of it, and the gap behind every feather is the same
-- gap.
--
-- **And they taper.** `w0` at the root to `w1` at the tip, in half widths, so
-- a feather has a direction in it and the eye finds the gaps. Drawn as closed
-- shapes rather than strokes, which is what the hull in the middle of the
-- badge is already drawn with, so the corners come out sharp for nothing.
--
-- The floor is `pen`'s own, and it is what keeps this honest at the sizes
-- three of the four callers draw at: nothing is cut thinner than nine tenths
-- of a point, so at ten and eleven the mark comes out where it always did and
-- the taper only says anything from about twenty up.
local WING = {
    -- Where each feather leaves the hull, on the leading edge's own line.
    roots = {{0.118, -0.06}, {0.166, 0.06}, {0.238, 0.18}},
    -- The two lines the ends are cut against, each as two points.
    rake = {{0.500, -0.30}, {0.389, 0.09}},
    root_line = {{0.118, -0.06}, {0.238, 0.18}},
    deg = 30,
    w0 = 0.020,
    w1 = 0.039,
    -- The circle that holds the whole mark, so a caller drawing it where a
    -- ship would go can ask for a radius and get a badge that fills it.
    reach = 0,
    -- The six shapes, in the mark's own units, and the width they were cut
    -- for. Rebuilt when a caller asks for a different one, which in a frame
    -- is at most twice: the nameplates draw at ten and everything else at
    -- eleven.
    cut = nil,
    cut_k = nil,
}

-- How far along `u` from `pt` a line sits, so a corner can be run out to it.
local function wing_hit(pt, u, line)
    local ax, ay = line[1][1], line[1][2]
    local bx, by = line[2][1], line[2][2]
    local nx, ny = -(by - ay), bx - ax
    return (nx * (ax - pt[1]) + ny * (ay - pt[2])) / (nx * u[1] + ny * u[2])
end

-- The six feathers at one mark width, as flat runs of four corners.
--
-- The spread comes out exactly the mark's width whatever the floor did to the
-- widths: the set is squeezed in x until the widest corner is a half, which
-- moves a root by thousandths and keeps the three parallel, since scaling one
-- axis does. Every caller lays this mark out against `k` and one of them sets
-- it beside a call sign, so a tip corner at 0.51 is a wing that touches a
-- name.
local function wing_cut(k)
    if WING.cut and WING.cut_k == k then return WING.cut end
    local a = WING.deg * math.pi / 180
    local u = {math.cos(a), -math.sin(a)}
    local n = {-u[2], u[1]}
    local floor = 0.45 / math.max(1, k)
    local w0 = math.max(WING.w0, floor)
    local w1 = math.max(WING.w1, floor)
    local out, far = {}, 0
    for _, root in ipairs(WING.roots) do
        local s = wing_hit(root, u, WING.rake)
        local q = {}
        for i, side in ipairs({{w0, WING.root_line, 0},
                               {w1, WING.rake, s},
                               {-w1, WING.rake, s},
                               {-w0, WING.root_line, 0}}) do
            local w, cut, along = side[1], side[2], side[3]
            local pt = {root[1] + u[1] * along + n[1] * w,
                        root[2] + u[2] * along + n[2] * w}
            local t = wing_hit(pt, u, cut)
            q[i] = {pt[1] + u[1] * t, pt[2] + u[2] * t}
        end
        out[#out + 1] = q
        for _, pt in ipairs(q) do far = math.max(far, math.abs(pt[1])) end
    end
    local squeeze = 0.5 / far
    local both = {}
    for _, q in ipairs(out) do
        local l, r = {}, {}
        for i, pt in ipairs(q) do
            r[i] = {pt[1] * squeeze, pt[2]}
            l[i] = {-pt[1] * squeeze, pt[2]}
        end
        both[#both + 1] = r
        both[#both + 1] = l
    end
    WING.cut, WING.cut_k = both, k
    return both
end

-- Measured once, off every corner the mark draws, the way world.lua measures
-- a hull when it loads. The feather tips reach further than the nose does.
do
    for _, q in ipairs(wing_cut(MARK_K)) do
        for _, pt in ipairs(q) do
            WING.reach = math.max(WING.reach,
                                  math.sqrt(pt[1] * pt[1] + pt[2] * pt[2]))
        end
    end
    for _, pt in ipairs({{0, -0.325}, {0.220, 0.275}, {0.170, 0.325}}) do
        WING.reach = math.max(WING.reach,
                              math.sqrt(pt[1] * pt[1] + pt[2] * pt[2]))
    end
    WING.cut, WING.cut_k = nil, nil
end

-- Pilot's wings: a boss with three feathers off each side.
--
-- `cx` is the middle of the mark and `cy` the middle of the line it sits on,
-- so a caller can hand it a row's center without knowing the height.
--
-- Feathers rather than a filled spread, because the gaps are what make this
-- wings at all: solid at eleven points it is a moustache. They are cut a
-- shade under the mark's own pen for the same reason, since a heavy feather
-- closes the gap beside it, and the gaps are the mark.
--
-- Cut so the spread is exactly the mark's width. Every caller lays this out
-- against `k` and one of them sets it beside a name, so wings that reached
-- past what they reported would be wings that touch a call sign.
local function pilot_mark(cx, cy, col, k)
    k = k or MARK_K * F.scale
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
    -- Swept back and cut into three, off the hull's own leading edge. The
    -- band and the two lines its ends are cut on are `WING`, above, which is
    -- also where the reasons live.
    --
    -- The roots are the leading edge's own line rather than a shared distance
    -- from the middle. They all began at one x, which is a straight line down
    -- a shape that has no straight line in it: the hull is a hair wide under
    -- the nose and four times that by the wingtip, so a root set clear of it
    -- at the bottom left the top two hanging in space.
    --
    -- Which makes these numbers the hull's, and they have to move when it
    -- does. Set wrong they do not fall off the mark or cross anything, they
    -- just reopen the gap unevenly, which is the kind of fault that lasts
    -- because nothing about it looks broken.
    for _, q in ipairs(wing_cut(k)) do
        F.layer:quad(px(q[1][1]), py(q[1][2]), px(q[2][1]), py(q[2][2]),
                     px(q[3][1]), py(q[3][2]), px(q[4][1]), py(q[4][2]), col)
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
-- A key in the menu, which is the only kind there is now that the corner
-- holds nothing to press.
--
-- A key in the menu is a word you read before you press it, so it takes the
-- face and the case the rest of the menu is set in. Anything drawn in flight
-- is mono instead, the way interface.md already splits a call sign: the same
-- name beside a nameplate is mono, because everything in flight is.
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
-- this edge, and the column's own key comes to rest on this key's pixels. It
-- spent a long time in the top left corner, where it was a control detached
-- from everything it did.
--
-- Faint, and the same faint on every window. This key lives inside the fight
-- rather than beside it, so at rest it is furniture: a pilot who has met the
-- screen once does not need it shouting, and one who has not is reading the
-- word rather than the weight. The word rides along on a phone as well, which
-- the corner never had the room for.
--
-- No box. `key_box` is the one shape a pressable thing wears here, and every
-- other one of them keeps it, but this key is not standing among them: it is
-- alone at the foot, over the fight in a seat, and the box was the thing that
-- read wrong. It made an instrument of it, since the band, the dial and the
-- corner chips are the boxes up there and a box at the foot joins them.
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

-- Whether there is a room on the glass at all: true for every frame the HUD
-- draws, false while the client is still looking for one.
--
-- What reads it is the corner: the dial, the readings over it, and where the
-- feed starts under them. There is no dial to draw before a room answers, and
-- the feed would otherwise begin a hundred and forty points down an instrument
-- nobody drew.
--
-- It used to mean something narrower, that this client had walked into the
-- room rather than merely having it on screen, and it took the radar and the
-- roster away from anybody who had not pressed play. A watcher is in the room;
-- see decision 159.
M.joined = false

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
-- One table rather than three names at this scope, because the file is at
-- Lua's ceiling of two hundred locals in a chunk and because these are one
-- fact between them. The row is the clock band in the middle and the dial at
-- the right, over an empty left corner; it has a center everything standing
-- in it shares, and a right end where the dial stands and the band stops.
local TOP = {}

-- The middle of the row, which everything standing in it lines up on.
--
-- A key's height sets it. There is no key up here any more, but the height is
-- still what the band was drawn to and what the dial's readouts hang off, so
-- it stays the one number the row is measured from. They each worked out a
-- baseline of their own from the padding once, which left them four points
-- high on a monitor and ten on a phone, and the padding is a horizontal
-- measurement that has no business setting a vertical one.
function TOP.mid()
    return F.safe_t + PAD * F.scale + KEY_H * F.scale / 2
end

-- The dial's box at rest, left edge and right, whatever is open in that
-- corner. Both ends of it are read by things that are not the dial: the clock
-- band stops at one, and the two readouts standing over the instrument hang
-- off both. Measured at rest so that opening the map moves none of them, since
-- the map is the same corner drawn wider and says nothing about the row.
function TOP.dial_x()
    local right = F.w - F.safe_r - PAD * F.scale
    return right - RADAR.side * RADAR.factor() * F.scale, right
end

-- Where the row ends, which is what the clock band may grow into.
--
-- The dial's left edge, a gap short of it. What stands in the row out there is
-- the strip the dial's own readouts take (see `over_dial`), and that strip is
-- exactly as wide as the instrument under it, so one measurement answers for
-- both.
--
-- A phone is where this bites. 390 points hold the way into the menu, a
-- centered clock and a 112-point dial, and what is left over is not a call
-- sign, so the band gives up its two names there. The figures under them
-- always draw.
--
-- Which is why this asks nothing about `M.joined`. What the band has to stop
-- short of is the strip on its own line, and the strip is there on every
-- screen with a connection behind it. One measurement covers both because they
-- are the same width.
function TOP.row_right()
    return TOP.dial_x() - KEY_GAP * F.scale
end

-- Half a minute, which is where the clock stops being a reading and becomes a
-- warning. The band used to say this by standing 26 points tall for three
-- minutes; a row set in one size says it in the ink instead, at the moment it
-- is worth saying.
TOP.WARN = 30

-- How wide the badge in the near corner is drawn, in points.
--
-- A shade over the row's thirteen point type, which is what makes it the mark
-- beside the figure rather than a note after it. The sheet draws the same
-- wings at eleven, where they stand at the end of a call sign and must not
-- out-read it; here there is no name to defer to and the mark is half of what
-- the corner says. Eighteen was drawn too and stands taller than the row.
TOP.MARK = 14

-- Your own standing, at the left end of the row: a badge and a figure.
--
-- A rating is the one durable thing a pilot has and it moved all match with
-- nowhere to watch it: the players sheet carries it at the whistle and the
-- ending is where it was read, which is a figure you are told about after the
-- fact. It stands in the near corner the way POS stands over the dial, at the
-- row's own size.
--
-- Two words stood beside it and both are gone. `RATING` named a reading the
-- figure had already named, and a phone dropped it first, which left a phone
-- showing a number with nothing to say what kind of number it was. The
-- movement in brackets was the other, and in a flag game it read a bracketed
-- zero for the length of a match, since those zones rate the whistle and not
-- the wreck (decision 157): a figure that cannot change while it is on screen
-- tells a reader nothing. What a death did to your rating is still said twice
-- where it happens, on the wreck and at the end of the feed's line (decisions
-- 152 and 155), and the players sheet still carries the movement in its
-- column for the whole room.
--
-- The badge takes their place, in the band's own color: the same wings the
-- sheet draws beside a human seat, drawn a shade over the row's type so the
-- mark is seen first and the figure read second. It says which of the five
-- bands the figure is in without spending a word on it, which is the reading a
-- caption could not carry and a phone could not keep. `pal.tier` is where the
-- five colors live and why they are those five.
--
-- A pilot inside their first ten rated games is placing: no band yet, so the
-- badge is the floor's mute at a lower alpha and the figure is in the mute the
-- pilot's own card gives it. Nothing at all for a watcher, whose rating this
-- room is not moving, and nothing for a pilot who has no rating yet, which is
-- a guest before their first rated death.
--
-- Answers where the row's left end is, which is what the band beside it grows
-- toward: the readout's own right edge where there is one, and the window's
-- margin where there is not, so a room that does not use this corner gives it
-- back to the band.
function TOP.rating(o, mid, px)
    local x = F.safe_l + PAD * F.scale
    local at = (not o.watch) and o.me and o.ratings and o.ratings[o.me]
    if not at then return x end
    local tier = (o.pilots and o.pilots[o.me] or {}).tier
    local placing = tier == "placing" or tier == nil
    -- The mark is laid out on its own width, which `pilot_mark` cuts the
    -- feathers to exactly, so it is handed the middle of that span rather
    -- than its left edge.
    local k = TOP.MARK * F.scale
    pilot_mark(x + k / 2, mid, pal.a(pal.tier(tier), placing and 0.55 or 0.95),
               k)
    x = x + k + 6 * F.scale
    -- Rounded here rather than left as the server sent it, the way the sheet
    -- and the pilot's card round it: one figure in three places, or it is
    -- three readings of one number.
    local now = tostring(math.floor(at + 0.5))
    txt(now, x, mid, px, pal.a(placing and pal.MUTE or pal.INK, 0.9))
    return x + text_w(now, px)
end

-- Both instruments this corner holds, since they are the same corner and one
-- replaces the other: the radar at rest, and the map when a player has asked
-- for it. They start on one line and differ in width alone.
--
-- The map is about a quarter of the frame, capped three ways: against the
-- window's width so it cannot run off the left edge, against its height so
-- there is still room for the feed under it, and at 124 points from the far
-- margin so it stops short of the opposite corner. That last cap was measured
-- against whatever chips stood over there and is a plain number now, since
-- nothing does.
local function dial()
    local pad = PAD * F.scale
    local side = RADAR.side * RADAR.factor() * F.scale
    -- Under the top row, both of them. The strip up there is the dial's own
    -- readouts: how the line is and where you are, standing over the
    -- instrument they are about (see `over_dial`). The radar sat hard in the
    -- corner for as long as that strip was empty, and it is not empty now.
    --
    -- It is the line the map has to start on in any case. The map is two
    -- thirds of the window's short side, so on an upright phone it reaches
    -- past the middle and sharing the band's line would put the clock on top
    -- of it, while capping its width to clear the band leaves something
    -- narrower at 390 points than the radar it grew from.
    local iy = TOP.mid() + KEY_H * F.scale / 2
    if M.map then
        side = math.max(side,
                        math.min(math.min(F.w, F.h) * 0.66, F.h * 0.66,
                                 F.w - F.safe_r - pad - 124 * F.scale))
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
-- than guess. The square and a gap: what the dial carries hangs over its head
-- rather than off its foot, and it is already counted here, since the square
-- starts under the row those readouts stand in.
--
-- The square is what goes when there is no dial, which is every frame until
-- this client joins something. The row above it stays, since the bars in it
-- are about the connection rather than about a seat, so the feed starts under
-- them instead of a hundred and forty points down an instrument nobody drew.
-- See `M.joined`.
function M.radar_span()
    local _, iy, side = dial()
    if not M.joined then return iy + 14 * F.scale end
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

-- A flag at four pixels: the same mark wherever an instrument shows one, so a
-- flag looks like a flag on the dial, on the map, and pinned to a rim.
--
-- It was a staff and a cloth triangle, matching what the arena drew. The
-- arena draws a transponder now, so this does too: a bright core inside a
-- ring, which is what the world's own mark reduces to once there is no room
-- left for the arcs standing off it.
local function flag_mark(px, py, s, col)
    F.layer:disc(px, ry(py, 0), 4.4 * s, 10, pal.a(col, 0.16))
    F.layer:ring_aa(px, ry(py, 0), 3.1 * s, 0.9 * s, pal.a(col, 0.9), 14)
    F.layer:disc(px, ry(py, 0), 1.3 * s, 8, pal.a(col, 1))
end

-- A prize on the dial. Built once rather than per green: two dozen of them
-- are out at a time and `pal.a` returns a fresh table, which is work for the
-- collector in a loop that runs every frame.
--
-- Short of full strength, for the reason the palette gives this color: a
-- field of two dozen must not out-shout the ships flying between them.
local RADAR_GREEN = pal.a(pal.GREEN, 0.9)

local function radar(cx, cy, me)
    -- No panel and no inset. The dial is the most valuable thing on screen on
    -- a map a thousand tiles across and it keeps every pixel; what made it
    -- read as half a phone's height was the opaque box, the border and eight
    -- points of padding on each side, none of which is information.
    --
    -- A faint wash stays, because dots over a starfield are dots lost in a
    -- starfield -- but it is a wash rather than a panel.
    -- The corner is the dial's from the top row down. The strip on that row
    -- carries the two readings the instrument is asked for beside it, the line
    -- and the tile you are on (see `over_dial`), so the square starts under
    -- them rather than at the window's own margin.
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

    -- The greens, over the terrain they are lying on and under everything
    -- that moves. A prize is a decision about where to fly next and a contact
    -- is a decision about right now, so a dial with both on it has to put the
    -- second on top.
    --
    -- The instrument is where a prize is decided on. The zone puts them out
    -- six to twenty-eight tiles from a live pilot for that reason, which
    -- `baseline.c` and the roam zone's file both say in as many words: inside
    -- the far edge so a green lands on the radar of whoever it appeared for.
    -- A prize a pilot can only find by flying over it is one nobody goes and
    -- gets.
    --
    -- A dot, where a contact is a diamond and a flag is a ringed core: the
    -- quietest of the marks standing on the terrain, because it is the only
    -- one that does not move and cannot shoot. In nobody's color, which is
    -- what a prize is (see `pal.GREEN`).
    --
    -- Nothing here culls. The zone writes a green outside a pilot's interest
    -- radius inert, and that radius is the sixty tiles this dial spans, so
    -- what the client holds is already what belongs on it; `put` answers nil
    -- for the rest, which is the crop the compact dial takes.
    for i = 0, sim.green_count() - 1 do
        local gx, gy, _, active = sim.green_at(i)
        if active then
            local px, py = put(gx, gy)
            if px then
                F.layer:disc(px, ry(py, 0), 2 * F.scale, 8, RADAR_GREEN)
            end
        end
    end

    local my_team = view_team
    for i = 0, sim.flag_count() - 1 do
        local fx, fy, team, carried = sim.flag_at(i)
        local px, py = put(fx, fy)
        local col = (team == 255) and pal.INK
            or (team == my_team and pal.FRIEND or pal.ENEMY)
        if px then
            -- A core in a ring rather than a bar: a flag should look like
            -- one even at four pixels.
            flag_mark(px, py, F.scale, col)
        elseif carried and team ~= my_team then
            -- The runner, as a bearing. Carrying the flag puts you on the
            -- map (decision 133): the wire has always said where a carried
            -- flag is, so the dial says it too, pinned to the rim it left
            -- by. Only a carrier earns this; a flag lying somewhere far away
            -- is going nowhere and can wait for the map.
            local dx, dy = fx - qx, fy - qy
            local m = math.max(math.abs(dx), math.abs(dy))
            if m > 0 then
                local inset = 5 * F.scale
                local ex = ix + (dx * SPAN / m + SPAN) * k
                local ey = iy + (dy * SPAN / m + SPAN) * k
                ex = math.min(math.max(ex, ix + inset), ix + r - inset)
                ey = math.min(math.max(ey, iy + inset), iy + r - inset)
                flag_mark(ex, ey, F.scale, col)
            end
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
    -- You, and only you, of the ships. That rule stands: a map showing where
    -- everybody is would be a wall hack. Where *you* are is something you
    -- already know, and without it a view of a thousand tiles is a picture of
    -- somewhere rather than of where you are standing, which is the whole
    -- question the map exists to answer.
    --
    -- The flags are not ships and they are on it, carried ones included,
    -- which is decision 133: the wire tells every client where every flag is,
    -- so the map draws it, and being lit map-wide is the cost of picking one
    -- up, paid knowingly by whoever does. The one map the original's players
    -- watched all game showed exactly this.
    --
    -- A cell is OVERVIEW_CELL tiles of sixteen pixels, so the world divides
    -- by that to land in the same coordinates the rectangles above use.
    if ov.grid > 0 then
        local cell = 4 * 16
        local my_team = view_team
        for i = 0, sim.flag_count() - 1 do
            local fx, fy, team = sim.flag_at(i)
            local col = (team == 255) and pal.INK
                or (team == my_team and pal.FRIEND or pal.ENEMY)
            flag_mark(ox + (fx / cell) * k, oy + (fy / cell) * k,
                      F.scale, col)
        end
        if me then
            own_arrow(ox + (sim.ship_x(me) / cell) * k,
                      oy + (sim.ship_y(me) / cell) * k, ix, iy, side, me)
        end
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

-- What a death did to this pilot's rating, drifting off the wreck. On the
-- module rather than in a local because ui.lua stands at LuaJIT's limit of
-- two hundred locals; see decision 152 for why the figure is back.
M.payouts = require("arena.ui_payouts").new()

function M.payout(x, y, n)
    M.payouts:add(F.now, x, y, n)
end

function M.clear_payouts()
    M.payouts:clear()
end

-- A rating change as a pilot reads it, signed in both directions and signed
-- at zero. Two things print one, the figure off the wreck and the end of the
-- feed's line about the same death, and a plus that turned up in one and not
-- the other would read as two different numbers about one kill.
function M.signed(n)
    return string.format("%+d", n)
end

local function nameplates(o)
    if not o.half_w or o.half_w <= 0 then return end
    -- What a hull just said, one line under its plate, in ink rather than
    -- the side's color: the plate says who, the line says what, and a line
    -- in the side's color read as a longer name. The plate's own size, in the
    -- case the phrase was written in, and gone in three seconds.
    local function said_line(i, sx, sy)
        local s = o.said and o.said[i]
        if not s then return end
        local a = 0.9
        local left = M.SAY_LIFE - s.t
        if left < M.SAY_FADE then a = a * math.max(0, left / M.SAY_FADE) end
        txt(s.phrase, sx + 12 * F.scale, sy, 11 * F.scale, pal.a(pal.INK, a),
            nil, nil, true)
    end
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
                    said_line(i, sx, sy + 27 * F.scale)
                    -- The same mark the scoreboard wears, on the hull itself:
                    -- who is flying a ship is worth knowing while you are
                    -- deciding whether to chase it, and that decision is made
                    -- looking at the ship rather than at a panel. Dim and
                    -- after the name, so it reads as a note about the label
                    -- and never competes with the name it follows.
                    --
                    -- In the band's color rather than the side's, which is
                    -- the one thing this mark can say that the name beside it
                    -- cannot: the plate already carries the side twice over,
                    -- in the name's color and in the hull under it, and a
                    -- third reading of the same fact is a color spent saying
                    -- nothing. How good they are is not written anywhere else
                    -- in the world, and it is what the decision this plate is
                    -- read for turns on.
                    if p then
                        -- A mark set four points off the last letter reads as
                        -- the end of the name rather than as a thing beside
                        -- it, and a call sign is exactly the kind of string
                        -- somebody will end in a bracket or a dot.
                        local mx = sx + 12 * F.scale
                            + text_w(nm, 11 * F.scale) + 9 * F.scale
                        -- A tenth up on the alpha the side's color was drawn
                        -- at, because the ladder's floor is a mute and both
                        -- sides' colors are bright: at 0.45 the band most
                        -- pilots are in would have read fainter than the mark
                        -- it replaced, which is a change nobody asked for.
                        -- Still well under the name it follows.
                        local band = pal.a(pal.tier(p.tier), 0.55)
                        if p.ai then
                            bot_mark(mx, sy + 13 * F.scale, band,
                                     10 * F.scale)
                        else
                            pilot_mark(mx + 5 * F.scale, sy + 13 * F.scale,
                                       band, 10 * F.scale)
                        end
                    end
                end
            end
        end
    end
    -- Your own hull wears no plate, so your own line stands where the plate
    -- would. That is how you know a call went: the room echoes it to the
    -- side, you included.
    if own >= 0 and own < sim.ship_count() and sim.ship_alive(own) == 1 then
        local sx, sy = on_glass(o, scale, sim.ship_x(own), sim.ship_y(own))
        said_line(own, sx, sy + 13 * F.scale)
    end
    -- The figures, drifting off the wrecks they were earned on. Walked
    -- backwards into itself so an expired one is dropped in the same pass
    -- that draws the rest, and the list stays as short as the killing is
    -- fast. Green when the number went up, the feed's red when it went down,
    -- and a plus zero is drawn as a gain, since the kill was still yours.
    M.payouts:each(F.now, function(p, f, a)
        local px, py = on_glass(o, scale, p.x, p.y)
        local col = p.n < 0 and pal.HURT or pal.PAID
        txt(M.signed(p.n), px + 12 * F.scale,
            py + 13 * F.scale - M.payouts.RISE * F.scale * f,
            11 * F.scale, pal.a(col, 0.95 * a), nil, nil, true)
    end)
end

-- --- panels ----------------------------------------------------------------

local rows = {}
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

-- How tall one row is, in the pixels a scroll arrives in. Published because
-- a finger dragging a panel and a wheel notch both have to be turned into
-- rows, and only this file knows what a row measures.
--
-- The menu's row, since every list a hand can drag is a panel of the menu
-- now: the players sheet, the settings page, the ship panel. The HUD's own
-- eighteen-point line is what the feed is set on, and the feed is not dragged.
function M.row_pitch()
    return (M.compact and 40 or 44) * F.scale
end

-- The band's own measurements, in one place because three things need them:
-- the band draws itself from these, the column under it starts where they
-- end, and a test can ask what the band is rather than working the sizes out
-- a second time.
--
-- Two numbers: the box the row stands in, which is a key tall, and the one
-- size everything set on it is set in.
--
-- The band was three sizes inside eight characters. The clock was a key tall
-- at 26 points and each side was a 9 point name over a 14 point number, which
-- put the largest type on the screen's top row on the one reading that
-- changes by itself and the smallest on the two a match is played for. Every
-- reading up here is the body size now, the size POS and the feed are already
-- set in, and what tells them apart is color and order. See decision 163.
--
-- The box stays a key tall. Nothing on the row fills it any more, but it is
-- what the flags, the room's line and the board hanging under the band are
-- placed against, and a row of one size is not a reason to move them.
local function band_type()
    return KEY_H * F.scale, FONT * F.scale
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
-- row is for.
--
-- Both readouts are back up there and neither can do it again, because
-- neither is placed against the window any more. They stand over the dial and
-- inside its width (see `over_dial`), and the band stops at that instrument's
-- left edge, which is one measurement rather than two that have to be kept
-- clear of each other. A side with nowhere left to grow drops its name rather
-- than the whole band dropping a line (see `match_clock`).
local function band_top()
    return F.safe_t + PAD * F.scale
end

local function band_bottom()
    return band_top() + (band_type())
end

-- The order the players sheet reads in: your own side first, then everybody
-- else, then the watchers, and inside each of those three by name.
--
-- The partition is "who is with me", which is the question a list of a room
-- is opened with: a name is only worth reading once you know which end of the
-- gun it is on. It was a partition and a chosen column for a while, with four
-- pressable headings over the figures. The Team column says the side on every
-- row now, so the grouping is a reading rather than the only way to tell, and
-- one order everybody learns beats four a hand has to find its way back to.
--
-- Watchers last, under everybody who is actually flying. They have no score,
-- and sorting a zero into the middle of a list reads as a pilot doing badly
-- rather than as somebody not playing. Their rows say `watching` where a side
-- would be, so the group needs no rule of its own beyond being last.
--
-- A to Z inside each group. It ran Z to A first, which is what was asked for
-- then, and a room read backwards is one a hand cannot scan: a list of names
-- is looked down the way a phone book is. Lowercased first so a capital cannot
-- jump a pilot to the front, and the raw name breaks the tie so the order is
-- total and two pilots who differ only in case cannot flicker past each other.
local function by_column(a, b)
    if a.watch ~= b.watch then return b.watch end
    if a.mine ~= b.mine then return a.mine end
    if a.lname ~= b.lname then return a.lname < b.lname end
    return a.name < b.name
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
            -- The band the roster has them in, which is the color their mark
            -- wears. Kept on the row for the same reason the side is: the
            -- drawing wants it, and the roster is where it is answered.
            r.tier = p and p.tier or nil
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
        -- A watcher is in the room without being in the match, so the room
        -- knows no band for them and their mark takes the mute the whole
        -- column used to wear.
        r.tier = nil
        r.mine = false
        r.self = viewer_name ~= nil and r.name == viewer_name
        r.watch = true
    end
    for i = n + 1, #rows do rows[i] = nil end
    -- And into the one order this list has. See `by_column`.
    table.sort(rows, by_column)
    return n
end

-- The notification feed: kills, arrivals, departures and flags. Newest first.
--
-- Bare. No panel: this is the one thing on screen that is already a list of
-- short lines, and a box around it is chrome around text that reads perfectly
-- well without one. Right-aligned so the edge that lines up is the one
-- against the screen, which is what the box used to provide.
--
-- Lines expire, and fade as they go. The arena owns the clock, it is what
-- ages them, so the lifetime lives here, where both halves can see it.
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
    -- The controls table is keyboard-only, so its offer is too. There is no
    -- second page behind this for glass: the pads name themselves.
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
    -- Clocked the way the match clock is. Past a minute nobody reads a bare
    -- count of seconds as a duration, and the limit is a uint16 of ticks, so
    -- the longest sit this can be asked to draw is 656 seconds.
    local clock = string.format("%d:%02d", math.floor(left / 60), left % 60)
    -- Red for the last ten, which is where it stops being information and
    -- starts being a warning.
    local col = left <= 10 and pal.ENEMY or pal.DIM
    -- Says where the pilot is about to be rather than what the room is about
    -- to take, since a seat is the room's word for it. The feed's own line
    -- once the clock runs out is "moved to spectator: too long in the safe
    -- zone", and this is that line said in advance.
    txt("moving to spectator in " .. clock, F.w / 2,
        y + (M.compact and 15 or 20) * F.scale,
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

-- What stands over the dial: how good the line is, and where you are.
--
-- One strip, on the top row's own line, as wide as the instrument under it.
-- Both belong up here with the dial rather than down in the corner stack with
-- what the ship is carrying, because neither is a fact about the ship.
--
-- Four bars from the connection's smoothed quality, hard against the dial's
-- right edge. They carry no word: four bars climbing in the corner of a screen
-- are a signal meter on every device a player owns, and LINK beside them was
-- the interface reading its own label back.
--
-- The bars replaced "online  err 0.0 / 1 px", which was the client's own
-- debugging left on a player's screen, since nobody flying has ever made a
-- decision on a prediction error in pixels. Those numbers are still here,
-- behind a press, for whoever is working on this.
local function over_dial(q, me)
    local left, right = TOP.dial_x()
    local mid = TOP.mid()
    -- The bars are one block on the row rather than four things each centered
    -- on it. A meter is a staircase standing on a floor, so the floor is what
    -- gets placed: the tallest bar is centered and the rest stand on its line.
    local tall = (3 + 3 * 2.6) * F.scale
    local foot = mid + tall / 2
    for k = 0, 3 do
        local bh = (3 + k * 2.6) * F.scale
        rect(right - (22 - k * 6) * F.scale, foot - bh, 4 * F.scale, bh,
             k < q and pal.a(pal.PAID, 0.85) or pal.a(pal.DIM, 0.22))
    end
    -- The switch is on the bars because they are the one thing on screen the
    -- readout behind them is about. What answers the press is the cluster and
    -- the corner around it: from a gap left of the first bar to the screen's
    -- own edge, and from the top of the safe area down to where the dial
    -- starts. The corner does as much work as the size, since a thumb aimed
    -- there cannot overshoot upward or to the right off the screen. Taller
    -- would mean taking a strip off the dial, which is the control that opens
    -- the map, and one control does not get to eat another.
    if not F.menu_up then
        local x0 = right - (22 + KEY_GAP) * F.scale
        hit(x0, F.safe_t, F.w - x0,
            mid + KEY_H * F.scale / 2 - F.safe_t, "debug")
    end
    -- And where you are, off the dial's left edge, in tiles: that is the unit
    -- the map is laid out in and the unit a player says out loud. Pixels would
    -- be the same place in numbers six digits long that nobody can hold in
    -- their head or call across a room.
    --
    -- Captioned where the bars are not, because a pair of numbers is not a
    -- shape anybody recognizes. POS is what says they are a place rather than
    -- a score, a count or a time, all of which the rest of this row carries.
    if not me then return end
    local size = (FONT - 3) * F.scale
    txt("POS", left, mid, size, pal.a(pal.DIM, 0.8))
    txt(string.format("%d,%d", math.floor(sim.ship_x(me) / 16),
                      math.floor(sim.ship_y(me) / 16)),
        left + 26 * F.scale, mid, size, pal.a(pal.INK, 0.85))
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
    -- The way out is the thing itself. What opens this is the link meter over
    -- the dial, and the readout lands under the dial: on a phone that is the
    -- best part of a screen away from the four bars that put it there, and a
    -- player who has finished reading it has no reason to think the answer is
    -- back up in the corner. So a press anywhere on the panel closes it, which
    -- is what every other slab of text in this interface does. The meter
    -- closes it too, being a switch.
    --
    -- Filed here rather than beside the bars, because it is this rectangle,
    -- and it is this rectangle only once the wrapping above has decided how
    -- many columns the window can hold. A backdrop: it holds no controls
    -- today, and a slab of text that closes on a press is the same kind of
    -- thing as the panels that do.
    if not F.menu_up then hit(x, y, w, h, "debug", nil, nil, -1) end
end

local function match_ended(m)
    return m ~= nil and not m.playing
end
-- The arena asks the same question, to keep the touch pads off the ending:
-- the whistle benched every hull, so the pads have nothing to drive, and the
-- board's own rows land exactly where the gun pad draws.
M.match_ended = match_ended

-- The flags, as flags.
--
-- This was a sentence, "flags  you 2 - 1 them   1 loose", which is three
-- numbers, two of them derivable from the third, in enough characters to
-- cross a phone. One mark per flag, colored by who holds it, says the same
-- thing in a glance and in a fifth of the width: you count shapes, not words,
-- and it scales to whatever number of flags a mode puts out.
--
-- `r` is the mark's own radius and `gap` the air between the band and the top
-- of it. Written down because the strip is not the only thing under the band,
-- and everything else down there is placed off how much room this took. It
-- was a staff and a pennant, measured from the tip of the staff down; the
-- mark is round now and a radius is the whole of it.
--
-- One table holding the measurements and the functions that read them, rather
-- than a handful of constants and some loose locals, because ui.lua sits on
-- Lua 5.1's ceiling of 200 locals in a chunk and had exactly one left. A
-- `local` at this level does not fail a test, it fails to load the file.
local FLAG = {gap = 9, r = 5, pitch = 16}

-- How far the strip pushes the rest of the stack down: nothing in a mode with
-- no flags, and nothing at the whistle, where the band's own line is what the
-- clock is counting down to.
--
-- The band is the top of a column, and this is what the column is made of: the
-- clock and the two sides, the flag strip, the room's line, then the board a
-- press on the band opens. Each of those used to be placed against the band on
-- its own, and the strip was placed against neither the band nor the window:
-- it was pinned twenty-five points above where the banner lands, which is a
-- real measurement taken from the wrong end of the stack. The band ends eight
-- points above that line, so the strip was drawn straight through the clock
-- and every flag stood a staff up through a numeral. Nothing showed it until
-- there were flags to draw, and Turf and Capture the Flag are the first modes
-- that put any out.
function FLAG.stack(m)
    if match_ended(m) or sim.flag_count() == 0 then return 0 end
    return (FLAG.gap + FLAG.r * 2) * F.scale
end

-- How far the strip reaches either side of the window's middle, which the
-- band's own press has to cover in a game that draws no score.
function FLAG.half_span()
    local n = sim.flag_count()
    return ((n - 1) * FLAG.pitch / 2 + FLAG.r) * F.scale
end

local function flag_strip(m)
    if FLAG.stack(m) == 0 then return end
    local n = sim.flag_count()
    local my_team = view_team
    local pitch = FLAG.pitch * F.scale
    local x0 = F.w / 2 - (n - 1) * pitch / 2
    local y = band_bottom() + (FLAG.gap + FLAG.r) * F.scale
    for i = 0, n - 1 do
        local _, _, team = sim.flag_at(i)
        local col = (team == 255) and pal.a(pal.DIM, 0.55)
            or (team == my_team and pal.FRIEND or pal.ENEMY)
        -- The same mark the radar draws, so a flag looks like a flag
        -- wherever it is shown.
        flag_mark(x0 + i * pitch, y, F.scale, col)
    end
end

-- The side holding every flag, and nil where nobody is. Worked out from the
-- flags themselves rather than sent, because the client already has all of
-- them and this is the same question the pennants answer a mark at a time.
--
-- On the table beside the measurements for the reason given there.
function FLAG.holder()
    local n = sim.flag_count()
    if n == 0 then return nil end
    local held = nil
    for i = 0, n - 1 do
        local _, _, team = sim.flag_at(i)
        if team == 255 or (held and team ~= held) then return nil end
        held = team
    end
    return held
end

-- The row across the top of the window: your standing at the left of it, the
-- clock with a side either side of it in the middle, and the dial's own
-- readouts at the far end (see `over_dial`). One line, set in one size.
--
-- What tells a score from a name from a clock is color and order rather than
-- weight. A side's two words wear the side's color and its figure leads,
-- reading outward from the middle; the clock between them is the reading ink,
-- since it is the one number up here that nobody is playing for; your own
-- standing is the interface's ink with only its movement colored. See
-- decision 163, and `band_type` for what the sizes used to be.
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

-- The whistle used to be a table here, working out which side had taken the
-- match so the band could stand the other one down to a third of its ink.
-- Both sides read at their own strength now: the scores say who won, which is
-- what a score is for, and a figure that has to be read through an alpha is a
-- figure the interface is editorializing about. See decision 163.

local function match_clock(o, m, names, alone)
    local row, px = band_type()
    -- Every reading on the row shares the row's own middle, which is what
    -- makes it one line rather than three things that happen to be up here.
    local mid = band_top() + row / 2
    -- The near corner first, because it is the end the band on its right has
    -- to stop short of.
    local near = TOP.rating(o, mid, px)
    -- A room that runs forever has no clock and no score, so the middle of
    -- the row is empty. Free Roam is the one zone with neither, and how many
    -- are in the room is a fact the players sheet carries a line each for: an
    -- instrument that reads out a number nobody is playing for is furniture,
    -- and the whole top edge of that zone is the fight's.
    if not m then return end
    local ended = match_ended(m)
    -- The dim is for a figure that has stopped moving, which at the whistle
    -- is both sides' points. The clock is not one of them and never takes it:
    -- it is counting something wherever it stands, and between matches it is
    -- counting the hardest, since it is the whole of what the row has left to
    -- say.
    local dim = m.playing and 1 or 0.55
    -- A flag game has no match clock: it runs until somebody holds every
    -- flag, and the only thing worth counting is the fifteen seconds that
    -- decide it. So the middle of the row is empty for most of one, and the
    -- clock appears when the set is completed and goes again when it breaks.
    -- See decision 165.
    local left = m.left
    local half = 0
    if left then
        local clock = string.format("%d:%02d", math.floor(left / 60), left % 60)
        -- Under half a minute a match clock goes to the warning color, which
        -- is the one thing on the row that says something other than what it
        -- reads. A hold is different: fifteen seconds is the whole of it, so
        -- red would be its only color, and it is a warning to one side and
        -- the other side's win. It wears whoever is holding the set instead,
        -- the same two colors the pennants under it are wearing.
        local ink = pal.READ
        if not m.score then
            local who = FLAG.holder()
            ink = (who == nil and pal.READ)
                or (who == view_team and pal.FRIEND or pal.ENEMY)
        elseif m.playing and left <= TOP.WARN then
            ink = pal.HURT
        end
        txt(clock, F.w / 2, mid, px, pal.a(ink, 0.95), "center")
        half = text_w(clock, px) / 2
    end
    -- What the band came to, walked outward from the clock as each side is
    -- laid down and read next frame by the press below.
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
    -- Nothing to press while the menu is up: what the band opens is a stop of
    -- that menu, and a control that opens what is already open would be a
    -- press with nothing on screen answering it. On the landing the same
    -- thing for a different reason: out there the column has no players stop
    -- at all, so the band is a reading of the fight behind the name.
    local function press()
        if alone then return end
        -- The pennants are the band in a game that draws no score, so the box
        -- reaches down over them: without that a flag zone has a top row with
        -- nothing on it for most of a match and no way into the sheet but the
        -- menu. Nothing to reach for in the games that draw a score, where the
        -- strip is either absent or hanging under a band already wide enough
        -- to press.
        local x0, x1 = band_l, band_r
        local strip = FLAG.stack(m)
        if strip > 0 then
            local span = FLAG.half_span()
            x0 = math.min(x0, F.w / 2 - span)
            x1 = math.max(x1, F.w / 2 + span)
        end
        hit(x0 - 6 * F.scale, mid - row / 2 - 4 * F.scale,
            x1 - x0 + 12 * F.scale, row + 8 * F.scale + strip, "players_open")
    end

    -- A match that has finished keeps both its sides, and the band is what
    -- says who took it: the winner at its own strength, the beaten side stood
    -- down to a third, over the clock counting to the next match.
    --
    -- What that clock is counting to goes on the line under it, which is the
    -- flags' line while a match is on and free at the whistle, when no mode
    -- draws any. It rode the row itself for a while and did not fit: eighteen
    -- characters between the two scores put the far one through the dial's
    -- strip on an upright phone. It is a caption rather than a reading, and
    -- the row is for readings.
    --
    -- A game with no score gives that line to `match_note` instead. The band
    -- there carries a clock and nothing else at the whistle, so a caption
    -- about the clock would be the only thing under it and who took the match
    -- would be said nowhere at all.
    if ended and m.score then
        -- Not on an upright window, and not on any window too narrow for it.
        -- What stands on that line is the dial, which is a third of a phone
        -- across, so a phone held upright has the caption running into the
        -- instrument or hard against it; a caption that will not fit is
        -- dropped the way a side's name is. The clock it is about is on the
        -- row above, counting, and the sheet the whistle raises is over the
        -- rest of the screen saying the match is done.
        local cap, dial_l = "NEXT MATCH IN", TOP.dial_x()
        if F.w >= F.h and F.w / 2 + text_w(cap, px) / 2 <= dial_l then
            txt(cap, F.w / 2, band_bottom() + 8 * F.scale, px,
                pal.a(pal.DIM, 0.8), "center")
        end
    end
    -- A side is its score and its name, in that order out from the middle, so
    -- the two figures sit at the ends of the band and the two names bracket
    -- the clock.
    --
    -- Nothing at all in a game whose standing is not a number. A flag game
    -- sends no sides: what it is scored in is the ground, the pennants draw
    -- that, and a pair of figures up here would be the same fact written out
    -- longhand under the picture of itself. See decision 165.
    local mine = view_team
    local sides = {}
    for team, n in pairs(m.score or {}) do
        sides[#sides + 1] = {team = team, n = n}
    end
    table.sort(sides, function(a, b)
        if (a.team == mine) ~= (b.team == mine) then return a.team == mine end
        return a.team < b.team
    end)
    -- A duel is one clean kill, so its score is not a reading: it stands at
    -- nil to nil for the whole match and then the match is over. What its two
    -- sides are is the two pilots, and Pilot against Rival names neither of
    -- them, so the row carries their call signs and the clock. See decision
    -- 146.
    local duel = o.zone == "duel"
    local gap = (M.compact and 12 or 16) * F.scale
    local inner = 8 * F.scale
    -- How much room a side has, which is the tighter of the row's two ends
    -- rather than each end's own: your standing at the near one, the dial's
    -- strip at the far one.
    --
    -- The two ends are not the same width and never were, so asking each side
    -- against the end it happens to face drops the right name at widths where
    -- the left one still draws, which reads as a fault rather than as a band
    -- running out of room. One measure for both sides means two names of a
    -- size go together.
    --
    -- Two names of very different lengths still part company, and should: a
    -- name that will not fit is a name that will not fit. What this stops is
    -- the same name fitting on one side of the clock and not the other.
    local room = math.min(F.w / 2 - half - near,
                          TOP.row_right() - F.w / 2 - half) - 2 * gap
    for i, side in ipairs(sides) do
        local ours = side.team == mine
        local col = pal.a(ours and pal.FRIEND or pal.ENEMY, 0.95 * dim)
        local figure = (not duel) and tostring(side.n) or ""
        -- A side's name is a label and wears the interface's own case; a
        -- pilot's is quoted, the way the roster and the plate on their hull
        -- quote it. Which of the two this is decides the case.
        local label, quoted = (names and names[side.team]) or "", false
        if duel then
            for _, p in pairs(o.pilots or {}) do
                if p.team == side.team then
                    label, quoted = p.name, true
                    break
                end
            end
        end
        -- Right-aligned against the clock on the left of it and left-aligned
        -- on the right, so both sides run away from the middle.
        local edge = i == 1 and F.w / 2 - half - gap or F.w / 2 + half + gap
        local pivot = i == 1 and "right" or nil
        -- A name that will not fit is dropped and the figure always draws:
        -- the figure is the reading and it is two characters.
        local wide = text_w(figure, px)
        if label ~= "" then
            wide = wide + text_w(label, px) + (figure ~= "" and inner or 0)
        end
        if label ~= "" and wide > room then
            label, wide = "", text_w(figure, px)
        end
        -- The name is the half nearest the clock, so the figure ends up at
        -- the band's own edge and `reach` has one number to walk out to.
        local fx = edge
        if label ~= "" then
            txt(label, edge, mid, px, pal.a(col, 0.85 * dim), pivot,
                nil, quoted)
            local step = text_w(label, px) + inner
            fx = i == 1 and edge - step or edge + step
        end
        if figure ~= "" then txt(figure, fx, mid, px, col, pivot) end
        reach(i == 1 and edge - wide or edge + wide)
    end
    press()
end

-- What the room has to say, under the band that carries everything else, and
-- under the pennants when the mode has flags to hang there.
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
    -- Not while the ending is up, in a game the band scores. The podium is
    -- the room's own account of the match that just finished and the band
    -- carries it, so a line here would be a third statement laid over the
    -- second. The banner used to be drawn after the ending's early return,
    -- which is the same rule written as an accident of order.
    --
    -- A game the band does not score is the other way round. Its whistle
    -- leaves a clock and nothing else up there, so this line is where "Keel
    -- takes it" lands, and the caption about the clock stands down for it.
    -- See `match_clock`.
    if match_ended(m) and m.score then return end
    -- In ink rather than in the warning color. The lines left, an opponent
    -- who left mid-fight and a clock that has run out, would wear red well
    -- enough, but the lag notice under this one is the red one and two reds in
    -- a column would stop meaning anything.
    local px = (M.compact and 9 or 11) * F.scale
    txt(line, F.w / 2, band_bottom() + FLAG.stack(m) + 8 * F.scale, px,
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
-- How long a phrase stays under the plate of whoever said it, in seconds.
-- The arena counts a phrase out against it. Three, the last eight tenths
-- spent leaving: a call is read in a glance and a fight moves on. The six
-- podium phrases share the clock and nothing on this client sends one; the
-- calls do, from the list `M.say_board` draws. See decision 167.
M.SAY_LIFE = 3.0
M.SAY_FADE = 0.8

-- What this match has done to everybody's rating, by ship.
--
-- The client's own subtraction rather than a number off the wire. A rating
-- moves only through rated deaths and the zone reports both pilots' rating
-- after every one, so the copy this client holds is exact and the figure now
-- less the figure at the whistle that started the match is what the match has
-- been worth so far.
--
-- Rounded on each end rather than once at the difference. What a pilot sees
-- on their own card is the rounded rating, and a movement worked out from the
-- unrounded pair would be a point off the two numbers it is supposed to
-- explain.
--
-- Nothing at all for a room with no standings to subtract, which is what the
-- sheet's column asks about. An empty table is a truthy answer, and it would
-- put a column of brackets over a room whose ratings have not arrived.
local function rating_moves(o)
    if not (o.ratings and o.rated_from) then return nil end
    local out, any = {}, false
    for ship, now in pairs(o.ratings) do
        local was = o.rated_from[ship]
        if was then
            out[ship] = math.floor(now + 0.5) - math.floor(was + 0.5)
            any = true
        end
    end
    return any and out or nil
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
-- monitor's width of one word is a banner rather than a button.
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

-- Where the column stands, and what it is made of: `n` stops of one width
-- over one key, rising out of the strip the menu key sits in.
--
-- One function, because there is one column. There were two, `landing_geom`
-- and `menu_geom`, and the second was written as "the same stops at the same
-- width over the same breathing key" as the first: two copies of one
-- measurement, kept in step by hand and by comment. See decision 143.
--
-- And one shape. There was a second, for the screen the client opened on: a
-- short window that could not hold the lockup over the stops lay them down
-- into a rail along the foot beside the key instead. That screen was the
-- landing and there is no landing; what the client opens on is a room, with
-- the same column over it a pilot in that room raises, and it stands upright
-- on every window. The lockup stayed, because it heads the menu wherever the
-- menu stands. See decisions 159 and 161.
local function column_geom(n)
    local pts_w = F.w / math.max(F.density, 0.0001)
    local narrow = pts_w < 620
    local kh = (narrow and 50 or (M.compact and 44 or 54)) * F.scale
    local margin = 14 * F.scale
    local span = F.w - F.safe_l - F.safe_r - 2 * margin
    local kw = narrow and span or (M.compact and 240 or 320) * F.scale
    local mid = F.safe_l + (F.w - F.safe_l - F.safe_r) / 2
    local rgap = 8 * F.scale
    local rh = (narrow and 44 or (M.compact and 30 or 36)) * F.scale
    local g = {narrow = narrow, kh = kh, kw = kw, kx = mid - kw / 2,
               rgap = rgap, rh = rh,
               kpx = (narrow and TYPE.ROW
                      or (M.compact and TYPE.BODY or TYPE.LEAD)) * F.scale,
               stops = {}}
    -- The key's own foot on the menu key's, so the two occupy one place: the
    -- column comes up out of the key and the key it raised settles onto it.
    local _, ky, _, kbh = foot_key_box()
    g.ky = ky + kbh - kh
    g.top = g.ky - 12 * F.scale - n * rh - (n - 1) * rgap
    for i = 1, n do
        g.stops[i] = {x = g.kx, y = g.top + (i - 1) * (rh + rgap),
                      w = kw, h = rh}
    end
    -- And where the lockup that heads it stands: centered on the column's own
    -- middle, a line clear of the top stop. `txt` sets a string on the middle
    -- of its line, so half the type goes back to put the baseline where it
    -- belongs above what it heads.
    g.size = (M.compact and 20 or 26) * F.scale
    g.mark_x = mid - M.wordmark_w(g.size) / 2
    g.mark_y = g.top - (M.compact and 16 or 20) * F.scale - g.size / 2
    return g
end

-- How many stops the column carries, for the one caller that needs its measure
-- without a view to build it from: the lockup on the loading screen, which
-- stands where the column will stand it. A constant because the stops are:
-- account, zone, players, ship, settings, always all five.
local COLUMN_STOPS = 5

-- One stop of the column: the question at its left edge and the answer it
-- currently holds at its right, in the same stroked rectangle every key here
-- wears. `lit` is the stop whose list is open.
--
-- It had a second shape, a rail cell that set the question over the answer
-- the way a gauge sets its caption over its reading, for the screen the
-- client opened on when the window was too short to stand a column up. That
-- screen was the landing and there is no landing. See decision 159.
--
-- `raw` says the answer is quoted rather than said: a call sign, a game's
-- name and a build's name all stand in the case they were given, where the
-- HUD would otherwise shout them. Sitting out is the one answer that is the
-- interface's own word and takes the interface's own case. See `txt`.
-- `o` carries the handful of things only some stops want, because a stop takes
-- enough positional arguments already: `raw` quotes the answer rather than
-- saying it, `warn` puts the guest dot on it, and `value` is what a press on
-- it reports.
--
-- No stop draws a mark saying it opens. Each wore a caret for two decisions,
-- two strokes pointing down at the list about to come up, and since every
-- stop opens something the mark was true of all five and told a hand nothing.
-- What it cost was the corner, which is where the answers are set, and the
-- answers are what a pilot is down here reading. See decision 154.
local function land_stop(x, y, w, h, label, value, action, lit, o)
    o = o or {}
    -- Where a press would land, at the weight every row of the menu is lit
    -- at. Under the outline rather than over it: the edge is the brighter
    -- half of the same signal, and a wash laid over it would mute it.
    --
    -- What the box publishes and not the action alone. Every stop publishes
    -- `menu_stop` and they tell themselves apart by the value; without it a
    -- cursor on any one of them lit the lot.
    local hot = M.col_sel == action and M.col_sel_value == o.value
    frost(x, y, w, h)
    rect(x, y, w, h, pal.a(pal.BTN_BG, 0.6))
    if hot then rect(x, y, w, h, pal.a(pal.FRIEND, LIT.CURSOR)) end
    key_box(x, y, w, h, nil,
            (lit or hot) and pal.a(pal.FRIEND, 0.8)
                or pal.a(pal.RADAR_TILE, 0.75))
    local raw = o.raw
    -- The measure every panel in the game insets its names by. A stop was on
    -- twelve, which is the exact number decision 104 unified away on the
    -- panels: a hand walking from a stop into the panel that climbs off it saw
    -- the type column step two points sideways at the moment the panel
    -- replaced the stop, which is the seam the language exists to close.
    local pad = M.ROW_INSET * F.scale
    local px = TYPE.LABEL * F.scale
    -- A question at the label's weight with the answer beside it at full
    -- strength, which is what every stop of the column is, including the one
    -- whose answer is a page rather than a value.
    --
    -- That one had its name in ink for two decisions, on the argument that a
    -- stop with nothing at full strength reads as a control that cannot be
    -- pressed. It does not. What made it read that way was decision 110's dim,
    -- which had the whole column at a third; with that fixed the argument was
    -- left holding a lit word in a column of muted ones, and five labels down
    -- a column with one of them white is a column that looks broken rather
    -- than one that says anything. The left edge is the question column and it
    -- is one weight the whole way down.
    local names = value == nil or value == ""
    lbl(label, x + pad, y + h / 2)
    -- And nothing is set where there is nothing to say. An empty string went
    -- down the type list every frame, which draws nothing and is one more word
    -- for anything reading this frame back to walk past.
    --
    -- Flush with the inset the question stands on at the other edge. It ended
    -- fourteen points short of it while the caret had that corner, and a
    -- reading stopping short of the glass with nothing after it is a column
    -- that looks ragged down its right hand side.
    if not names then
        txt(value, x + w - pad, y + h / 2, px,
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
        -- The answer is set from the right, so where it begins is where it
        -- ends less its own width. Asked of the same measure the drawing uses
        -- rather than guessed at, since a call sign is as long as its pilot
        -- made it.
        local dx = x + w - pad - text_w(value or "", px, nil, raw)
            - 7 * F.scale
        F.layer:disc(dx, ry(y + h / 2), 2.5 * F.scale, 8,
                     pal.a(pal.CHARGE_COL, 0.95))
    end
    hit(x, y, w, h, action, o.value)
end

-- --- what a stop opens -----------------------------------------------------
--
-- A panel that slides up out of the bottom edge and takes the window, rather
-- than a list unrolling upward from the row that opened it.
--
-- The lists opened upward because they had to keep off the key, which put
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

-- How far a row's type stands inside the glass it is drawn on.
--
-- The field a state lights is the glass, edge to edge, so this is the one
-- measure that says where the type column is, and it is published because the
-- field no longer says it: a lit row used to be exactly the box its type was
-- handed, and `client/tests/row_field_test.lua` measured the column off it.
M.ROW_INSET = 14

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
-- How wide a panel comes out at this window, which the height has to know
-- before the geometry is worked out: a sentence that wraps is a row that
-- grows, and what it wraps to is the glass it is drawn on.
local function panel_width()
    local margin = PANEL_MARGIN * F.scale
    local span = F.w - F.safe_l - F.safe_r - 2 * margin
    return math.min(span, (M.compact and 440 or PANEL_MAX) * F.scale)
end

local function panel_geom(want)
    local margin = PANEL_MARGIN * F.scale
    local w = panel_width()
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
    -- The head, the credit tray under it, and whatever the level holds. Three
    -- of the kinds are not rows and answer their own height.
    local h = pages.HEAD_H * F.scale + 30 * F.scale + 10 * F.scale
    for _, r in ipairs(panel.rows or {}) do
        h = h + pages.land_row_h(r, drh)
    end
    return h
end

function pages.page_h(v, rowh, noted)
    local rh = noted and rowh + pages.NOTE_LINE * F.scale or rowh
    return pages.HEAD_H * F.scale + 10 * F.scale + #v.rows * rh
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
--
-- `tray` is the purse, where the panel is one a credit can be spent from. It
-- is chrome rather than content: the panel draws it under the head, the same
-- on the ship menu and on all five of its sections, so a pilot stepping a
-- slot is looking at what that step costs. It was the third strip of the
-- ship page's content and scrolled away with the rows above it.
local function panel_frame(px, py, pw, ph, title, back, foot_note, back_value,
                           tray, named)
    local headh = 44 * F.scale
    -- The same measure the rows under it are inset by, so the head's mark and
    -- the names below it stand on one line rather than two points apart.
    local pad = M.ROW_INSET * F.scale
    frost(px, py, pw, ph)
    rect(px, py, pw, ph, pal.a(pal.BTN_BG, 0.72))
    key_box(px, py, pw, ph, nil, pal.a(pal.RADAR_TILE, 0.75))
    -- The head is a control like any other row, so it lights like one. It did
    -- not, and a hand walking the panel with the arrows could stand on the way
    -- back with nothing on screen saying so: the walk named it, the drawing
    -- never did. Both hands write `M.col_sel` through the same `M.pick`, so
    -- this answers a pointer resting on it as well.
    local hot = back and M.col_sel == back
    LIT.state(px, py, pw, headh, hot, false)
    local hy = py + headh / 2
    F.layer:tri(px + pad + 2 * F.scale, ry(hy),
                px + pad + 9 * F.scale, ry(hy - 6 * F.scale),
                px + pad + 9 * F.scale, ry(hy + 6 * F.scale),
                pal.a(pal.FRIEND, hot and 1 or 0.9))
    -- The head names the panel, in the register that names a group of rows.
    -- Unless what it names is a person: a call sign is quoted wherever it is
    -- drawn, in the case its owner gave it, so the one head that carries one
    -- takes the menu's own voice and that pilot's own color. That is the
    -- players sheet's card, and it is the only head in the game about
    -- somebody rather than about a page.
    if named then
        txt(title or "", px + pad + 18 * F.scale, hy, TYPE.ROW * F.scale,
            named.col or pal.a(pal.INK, 0.95), nil, MENU_FONT, true)
    else
        lbl(title or "", px + pad + 18 * F.scale, hy,
            hot and pal.a(pal.INK, 0.95) or pal.MUTE)
    end
    -- What a control waiting for a key has to say, where it says it: on the
    -- head of the page that asked, so a hand looking at the row is looking at
    -- the sentence about it.
    if foot_note then
        txt(foot_note, px + pw - pad, hy, (M.compact and 10 or 11) * F.scale,
            pal.a(pal.READ, 0.95), "right", MENU_FONT, true)
    end
    hrule(px, py + headh, pw, 0.6)
    hit(px, py, pw, headh, back, back_value, nil, 1)
    -- The purse, as a count drawn rather than written: the whole reason a
    -- step costs one is that nobody should have to read a number to know what
    -- they can afford. Spent credits are hollow.
    if tray then
        local trayh = 30 * F.scale
        local ty = py + headh
        local cy = ty + trayh / 2
        lbl("build credits", px + pad, cy, pal.a(pal.CHARGE_COL, 0.8))
        local side = 9 * F.scale
        local gap = 6 * F.scale
        local total = tray.credits or 0
        local run = total * side + math.max(0, total - 1) * gap
        local sx = px + pw - pad - run
        for i = 1, total do
            local x = sx + (i - 1) * (side + gap)
            local lit = i <= (tray.free or 0)
            F.layer:quad(x + side / 2, ry(cy - side / 2),
                         x + side, ry(cy),
                         x + side / 2, ry(cy + side / 2),
                         x, ry(cy),
                         pal.a(pal.CHARGE_COL, lit and 0.95 or 0.18))
        end
        hrule(px, ty + trayh, pw, 0.45)
        headh = headh + trayh
    end
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
-- The column's own key, and LOG IN at the foot of the card that asks for a
-- password. One drawing, because it is one object: it was written out three
-- times, and the third copy is what made that worth saying.
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

-- The dial that says something is being looked for, at whatever size it is
-- handed: the screen's own while a room is still being found, and a row's
-- when the games list has the zone but nothing is serving it. Everything
-- about it is measured off its radius, so the small one is the large one
-- rather than a second drawing that has to be kept in step with it.
--
-- Nothing else in this interface turns for the sake of turning, and this is
-- telling the truth while it does: the directory is asked again every three
-- seconds, and a zone with nobody running it is one an arena can come back
-- to. `F.now` is zero under the test harness, which holds it still.
--
-- On `pages` rather than in a local of its own, for the reason `pages.dot`
-- is: a Lua chunk may hold two hundred locals and this file is at that
-- ceiling. See client/tests/upvalues_test.lua.
function pages.sweep_dial(cx, cy, r)
    local ring = math.max(0.8 * F.scale, r * 0.022)
    -- Three range rings where there is room for three. A dial the height of a
    -- row has twenty two points across it, and three rings in that are five
    -- points apart, which is closer than the stroke drawing them: they close
    -- up into a disc with a fringe. Two rings at that size is the same
    -- instrument, read at the distance it is actually being read from.
    local rings = (r > 24 * F.scale) and {0.42, 0.72, 1.0} or {0.55, 1.0}
    local sides = math.max(18, math.min(30, math.floor(r / F.scale)))
    for k, f in ipairs(rings) do
        F.layer:ring(cx, ry(cy), r * f, ring, sides,
                     pal.a(pal.RADAR_TILE, 0.55 - k * 0.12))
    end
    local ang = -F.now * 0.8
    -- How much of the circle the tail covers. Fewer strokes on the small dial:
    -- the same half radian of them, on something twenty two points across, is
    -- a quarter of the face filled in, and a sweep that wide is a pie chart.
    local tail = (r > 24 * F.scale) and 10 or 5
    for k = 0, tail - 1 do
        -- The trail is behind the hand, which for a sweep going round the way
        -- a dial's goes is the side it has just left.
        local a = ang + k * 0.05
        local f = 1 - k / tail
        F.layer:seg(cx, ry(cy), cx + math.cos(a) * r * 0.98,
                    ry(cy - math.sin(a) * r * 0.98),
                    math.max(1.0 * F.scale, r * 0.028),
                    pal.a(pal.FRIEND, 0.32 * f * f), true)
    end
    F.layer:disc(cx, ry(cy), math.max(1.2 * F.scale, r * 0.05), 10,
                 pal.a(pal.DIM, 0.9))
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
    local pad = M.ROW_INSET * F.scale
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
            LIT.state(kx, y, kw, drh, hov, r.here)
            -- These lists used to set their names in the HUD's twelve point
            -- mono capitals, because a list was once a strip drawn over a
            -- fight. It is a panel now, read rather than glanced at, so the
            -- name goes in the menu's own voice like every other row in the
            -- game: `mark` is where you already are, `named` quotes a name in
            -- the case its owner gave it, and `detail` is the reading.
            menu_row(kx + pad, y, kw - 2 * pad, drh, {
                label = r.label, named = r.raw, detail = r.note,
                mark = r.here, tint = r.tint, offer = r.offer, dim = r.dim,
                waiting = r.waiting,
            }, hov)
            if not r.dim then
                hit(kx, y, kw, drh, r.action, r.value, nil, 1)
            end
            y = y + drh
        end
    end
end


-- How long one turn of a hull on the carousel takes, in seconds.
--
-- Slow enough to read as a thing turning rather than a thing spinning: what a
-- pilot is doing here is looking at a silhouette, and the whole identity
-- system is that every hull has a front visibly not its back. `F.now` is zero
-- under the test harness, which holds every one of these still.
local HULL_TURN = 11

-- The drawing stands in an ordinary row, and the name takes a line under it.
--
-- Which is the whole of the carousel's height: `land_row_h` asks for one row
-- of the panel's own and adds the name to it, and the radius falls out of
-- whatever that leaves. The drawing carried a radius of its own for as long
-- as it existed, 78 and then 62, and both of them were a picture sized
-- against nothing: at 78 it stood 168 points tall where the five flight bars
-- under it take 130 between them, so the section a pilot picks a hull on was
-- mostly ship. A row is the measure everything else on this panel is drawn
-- to, so it is the one the ship gets as well. The name under it takes the
-- same band as a flight row, since it is set at the same weight as one.
--
-- The air is two points rather than the six it was. Six is nothing against a
-- circle of 78 and twelve of a row's forty four, and the hulls do not need
-- it: `reach` is a radius over every point of the polygon, so a hull as wide
-- as it is long already stands well inside its own circle.
local HULL_ART_PAD = 2
local HULL_NAME_H = 26

-- One hull, turning on its own vertical axis, drawn the way the arena draws
-- one.
--
-- Not an outline of a ship. The first of these stroked `poly` and laid the
-- interior lines over it, which is a tracing: the arena gives a hull plates
-- washed and outlined in the panel ink, hardpoints drawn hot, a canopy that
-- is always the brightest closed shape on it, lamps, and a silhouette whose
-- every edge carries its own brightness off `h.hot`. That last one is most of
-- what makes a hull look built rather than cut from one sheet of neon, and a
-- traced outline has none of it. Every element and every weight here is
-- `world.ship`'s, read off the same tables.
--
-- What is left out is the two skirts of bloom and the halo under them.
-- `world.ship` puts those on the fight's glow layer, which is additive and
-- sits behind the glass; a panel draws on the interface's layer, which
-- composites and sits in front of it. A skirt drawn there hazes rather than
-- lights, so this takes the strokes and leaves the light.
--
-- The turn is the bank the renderer already has: local x scaled by the cosine
-- of the angle, and everything that speaks local x going with it, so hull,
-- plates, canopy and hardpoints turn together. That is a ship rotating about
-- the axis running up the screen, broadside at nought and edge-on at a
-- quarter turn, with its nose up the whole way round. It was a spin in the
-- plane of the screen, which is a ship tumbling rather than a ship turning.
local function hull_art(cx, cy, cls, r, col, alpha)
    local h = world.HULLS and world.HULLS[cls + 1]
    -- `reach`, `mid` and `hot` are all measured off the polygon when
    -- world.lua loads, so a hull without them is a table this was never meant
    -- to be handed. Nothing rather than a raise: the panel around it is still
    -- the thing on screen.
    if not (h and h.poly and h.reach and h.hot) then return end
    local k = r / math.max(1, h.reach)
    local dim = alpha * (h.dim or 1)
    local squash = math.cos((F.now * math.pi * 2) / HULL_TURN)
    -- Local pixels to the interface's own, with the nose up the screen: the
    -- hulls are written with the nose along +y and this counts y downward.
    local out = {}
    local function put(src)
        for i = 1, #src, 2 do
            out[i] = cx + src[i] * squash * k
            out[i + 1] = ry(cy - (src[i + 1] - h.mid) * k)
        end
        for i = #src + 1, #out do out[i] = nil end
        return out
    end

    -- The interior first, so the silhouette closes over it.
    for _, q in ipairs(h.plates or {}) do
        local t = put(q)
        F.layer:fan(t, pal.a(pal.PANEL_INK, 0.035 * dim))
        F.layer:outline(t, 0.85 * F.scale,
                        pal.a(pal.PANEL_INK, 0.36 * dim), true)
    end
    for _, q in ipairs(h.lines or {}) do
        local t = put(q)
        for i = 1, #t - 3, 2 do
            F.layer:seg(t[i], t[i + 1], t[i + 2], t[i + 3], 0.7 * F.scale,
                        pal.a(pal.PANEL_INK, 0.26 * dim), true)
        end
    end
    -- Hardpoints: where a hull's damage comes out of is worth knowing at a
    -- glance, and it is the same element at every size.
    for _, t in ipairs(h.tubes or {}) do
        local ax, ay = cx + t[1] * squash * k, ry(cy - (t[2] - h.mid) * k)
        local bx, by = cx + t[3] * squash * k, ry(cy - (t[4] - h.mid) * k)
        local w = t[5] * k
        F.layer:seg(ax, ay, bx, by, w, pal.a(col, 0.30 * dim), true)
        F.layer:seg(ax, ay, bx, by, w * 0.34,
                    pal.a(pal.hot(col, 0.55, 1), 0.9 * dim), true)
    end
    -- The silhouette, every edge at its own brightness. `hot` is a light
    -- fixed to the hull's own nose, so a ship reads the same whichever way it
    -- is pointing.
    local pts = put(h.poly)
    local edge = pal.hot(col, 0.34, 1)
    local n, e = #pts, 1
    for i = 1, n, 2 do
        local j = (i + 1 < n) and i + 2 or 1
        F.layer:seg(pts[i], pts[i + 1], pts[j], pts[j + 1], 1.5 * k,
                    pal.a(edge, math.min(1, (h.hot[e] or 1) * dim)), true)
        e = e + 1
    end
    -- The canopy: always the brightest closed shape on a hull and always
    -- forward of centre, so which end is the front never needs a second look.
    if h.canopy then
        local t = put(h.canopy)
        F.layer:fan(t, pal.a(pal.hot(col, 0.3, 1), 0.42 * dim))
        F.layer:outline(t, 0.9 * F.scale,
                        pal.a(pal.hot(col, 0.8, 1), 0.95 * dim), true)
    end
    for _, d in ipairs(h.pods or {}) do
        local lx, ly = cx + d[1] * squash * k, ry(cy - (d[2] - h.mid) * k)
        F.layer:halo(lx, ly, d[3] * 2.6 * k, 6, pal.a(col, 0.30 * dim))
        F.layer:disc(lx, ly, d[3] * 0.45 * k, 4,
                     pal.a(pal.hot(col, 0.8, 1), 0.8 * dim))
    end
end

-- One flight row of the carousel: the word, and where this hull stands on it
-- against the rest of the roster.
--
-- A share rather than a figure. The units are the core's, five different
-- scales none of which a player reads, and what the row is answering is
-- "faster than what".
--
-- With a floor under the fill, because the hull at the bottom of a row is
-- still a hull that flies. A share of nothing drew nothing, which is exact
-- about the range and wrong about the ship: the Anvil is the floor of speed,
-- thrust and turn all three, so its page came out with three of five rows
-- blank and read as an instrument that had failed rather than as the slowest
-- ship in the game. The floor is small enough that the order down a row is
-- still the order, and every hull's page now has five bars on it.
local FLOOR = 0.035

local function stat_line(kx, kw, y, h, r, col)
    local pad = M.ROW_INSET * F.scale
    local name_w = math.min(96 * F.scale, (kw - 2 * pad) * 0.34)
    local mid = y + h / 2
    lbl(r.label, kx + pad, mid, pal.MUTE)
    local bx = kx + pad + name_w
    local bw = kw - 2 * pad - name_w
    local share = math.max(FLOOR, math.min(1, r.share or 0))
    rect(bx, mid - 1.5 * F.scale, bw, 3 * F.scale, pal.a(pal.DIM, 0.22))
    rect(bx, mid - 1.5 * F.scale, bw * share, 3 * F.scale, pal.a(col, 0.85))
end

-- One row of the ship stop, at whichever level of it is open.
--
-- Six kinds and each one is a shape the menu already had: a section reads
-- what it holds, a slot steps or switches, a flair row fills its cells, a
-- hull is a name with its flight beside it, and the two that are not rows at
-- all are the bars under the body row and the hairline over the reset.
local function land_row(kx, kw, y, h, r)
    local pad = M.ROW_INSET * F.scale
    if r.kind == "rule" then
        hrule(kx + pad, y + h / 2, kw - 2 * pad, 0.6)
        return
    end
    if r.kind == "stat" then
        stat_line(kx, kw, y, h, r, r.here and pal.FRIEND or pal.INK)
        return
    end
    if r.kind == "art" then
        -- The carousel: one ship turning, an arrow either side of it at its
        -- own middle, and the name under it. The arrows are the choice: what
        -- a pilot turns to is what they are flying by the time it stops
        -- moving, so there is nothing here to commit afterwards.
        --
        -- Your color, always: the ship on the carousel is the ship you fly,
        -- since turning is what chooses. There is no other for a mark to tell
        -- it from, so the field the roster used to light on "this is the one"
        -- is gone with the press that made one of them the one.
        --
        -- Standing on the carousel, which is one control however many hulls
        -- it turns through. It answered for the hull it was showing, and the
        -- hull is what the arrows change: every step of them moved the row
        -- out from under the cursor, so scrubbing the roster put the row out
        -- and the arrows left the walk. What a hand stands on here is the
        -- carousel, not the Chord.
        local on = M.col_sel == "land_pick_ship"
        LIT.state(kx, y, kw, h, on, false)
        local col = pal.FRIEND
        local a = 1
        -- The name under the drawing, and the drawing over what is left.
        --
        -- A sentence about the hull used to run under the name, wrapped to
        -- the glass. It went with the height: what it said was where the hull
        -- stands in speed, thrust, turn, energy and recharge, which is what
        -- the five bars directly beneath it draw, so it was the page saying
        -- the same thing twice and taking two more lines to do it.
        local nameh = HULL_NAME_H * F.scale
        local mid = y + (h - nameh) / 2
        local art_r = (h - nameh) / 2 - HULL_ART_PAD * F.scale
        if r.cls then
            hull_art(kx + kw / 2, mid, r.cls, art_r, col, a)
        end
        -- The name is set at a row's own weight rather than a heading's. It
        -- is the label of the thing the row holds, the way every other label
        -- on this panel is, and a heading over a drawing thirty points tall
        -- was the largest type on the page announcing the smallest thing on
        -- it.
        txt(r.label, kx + kw / 2, y + h - nameh / 2,
            TYPE.ROW * F.scale, pal.a(col, a), "center", MENU_FONT, true)
        -- The two arrows, at the glass's own edges and level with the middle
        -- of the row.
        --
        -- The middle of the drawing before that, on the argument that the
        -- drawing is what they turn. What that missed is that the name turns
        -- with it: the pair is one thing, and standing beside its upper half
        -- put both arrows in the top third of the row with the row's own
        -- centre line empty between them.
        --
        -- Each takes the whole row, which is over the floor a platform puts
        -- under a fingertip and is centred on the mark it draws. It was a
        -- fixed 52 points, taller than this row, so both boxes hung over the
        -- edge into whatever the panel had put above them.
        local rowmid = y + h / 2
        for _, d in ipairs({{-1, kx + 24 * F.scale},
                            {1, kx + kw - 24 * F.scale}}) do
            local dir, ax = d[1], d[2]
            F.layer:tri(ax + dir * 7 * F.scale, ry(rowmid),
                        ax - dir * 6 * F.scale, ry(rowmid - 9 * F.scale),
                        ax - dir * 6 * F.scale, ry(rowmid + 9 * F.scale),
                        pal.a(pal.FRIEND, 0.9))
            hit(ax - 24 * F.scale, y, 48 * F.scale, h,
                "land_page_ship", dir, nil, 1)
        end
        -- The ship itself takes no press. Turning the carousel is the whole
        -- of choosing: what a pilot arrives as changes as they turn, so
        -- there is nothing left for a press on the drawing to do and a row
        -- that looks pressable and is not is worse than one that plainly is
        -- not. See decision 118.
        --
        -- The box stays, at the priority a row that only anchors a cursor is
        -- published at. It is where a hand stands so that left and right can
        -- turn, which is the same job `land_kit_row` does for the arrows
        -- either side of a count.
        hit(kx + 56 * F.scale, y, kw - 112 * F.scale, h, "land_pick_ship",
            nil, nil, 0)
        return
    end
    if r.kind == "sect" then
        -- What a section says beside its name is what it holds rather than
        -- what it cost. See `menu.sect_reading`.
        local on = M.col_sel == "land_sect" and M.col_sel_value == r.sect
        LIT.state(kx, y, kw, h, on, false)
        hit(kx, y, kw, h, "land_sect", r.sect, nil, 1)
        menu_row(kx + pad, y, kw - 2 * pad, h,
                 {label = r.label, detail = r.detail, verbatim = r.raw}, on)
        return
    end
    if r.kind == "reset" then
        local on = M.col_sel == "land_kit_reset"
        if r.on then LIT.state(kx, y, kw, h, on, false) end
        menu_row(kx + pad, y, kw - 2 * pad, h,
                 {label = r.label, dim = not r.on}, on and r.on)
        if r.on then
            hit(kx, y, kw, h, "land_kit_reset", nil, nil, 1)
        end
        return
    end
    if r.kind == "flair" then
        -- The wake and which key throws which charge, which are the ship's
        -- and were on the settings page while this one was a list of things
        -- to spend credits on. A row of cells, and enter and the arrows both
        -- step it: it holds one of a few answers and every one of them is the
        -- next one along.
        local on = M.col_sel == "land_flair" and M.col_sel_value == r.index
        LIT.state(kx, y, kw, h, on, false)
        hit(kx, y, kw, h, "land_flair", r.index, nil, 1)
        menu_row(kx + pad, y, kw - 2 * pad, h,
                 {label = r.label, detail = r.detail, choice = r.choice,
                  choices = r.choices}, on)
        return
    end
    -- A slot: a stepper or a switch, and which is not a decision made here.
    -- A slot that only goes to one is on and off and gets a switch, and
    -- anything you can have more of gets the arrows. An arrow that would do
    -- nothing is drawn dim rather than left out, so a row does not change
    -- shape as a pilot spends.
    local on = M.col_sel == "land_kit_row" and M.col_sel_value == r.slot
    LIT.state(kx, y, kw, h, on, false)
    hit(kx, y, kw, h, "land_kit_row", r.slot, nil, 0)
    menu_row(kx + pad, y, kw - 2 * pad, h, {
        label = r.label,
        toggle = r.toggle or nil,
        step = {value = r.value, base = r.base, reads = r.reads,
                can_up = r.can_up, can_down = r.can_down, slot = r.slot,
                action = "land_kit_step"},
    }, on)
end

-- How tall one row of the ship stop stands.
--
-- Three of the kinds are not rows and say so: the bars strip is the shipped
-- one, the roster's column head is a band, and the hairline over the reset is
-- the rule the account list already draws between its two groups.
function pages.land_row_h(r, drh)
    if r.kind == "art" then return drh + HULL_NAME_H * F.scale end
    if r.kind == "stat" then return 26 * F.scale end
    if r.kind == "rule" then return 9 * F.scale end
    return drh
end

-- What the cursor is standing on inside the ship stop, as one value the panel
-- can compare against a row: a section by its name, a slot by its number, a
-- hull by its place in the roster, a flair row by its index.
local function land_row_at(r)
    if r.kind == "sect" then return "land_sect", r.sect end
    if r.kind == "slot" then return "land_kit_row", r.slot end
    if r.kind == "art" then return "land_pick_ship", nil end
    if r.kind == "flair" then return "land_flair", r.index end
    if r.kind == "reset" then return "land_kit_reset", nil end
    return nil, nil
end

-- How far the ship panel has been scrolled, in points. Kept apart from the
-- settings panel's own scroll because the two are different surfaces and a
-- position carried between them would open one where the other was left.
M.col_scroll = 0

-- The row the panel last scrolled itself to. Without it the panel would haul
-- itself back to the lit row on every frame, which is a finger dragging a page
-- it cannot keep.
local col_followed = nil

-- The ship stop's panel: five rows and a reset over a tray, or one of the
-- five sections over the same tray.
--
-- It was one panel with all of it on at once: the roster walked on the top
-- row, the flight bars under it, the tray under those, and then every slot
-- the hull could reach running down the rest of the glass under three band
-- labels. Fourteen rows on an Apex. What that cost was not the scroll, which
-- is still here, and it is not room: it is that the tray was the third strip
-- of the content and went off the top with everything above the fold, so a
-- pilot stepping a slot near the foot was spending a purse they could not
-- see. The tray is chrome now and lives in the frame, so it is on screen at
-- every level and at every window size, and what scrolls is only ever rows.
-- See decision 112.
--
-- Whole rows only, which is the same rule the drawer's pages follow and for
-- the same reason: the scissor in the renderer cuts against a vertical edge,
-- so a row half off the bottom would draw through the frame rather than be
-- cut by it.
local function land_panel(kx, kw, top, bottom, panel, drh)
    local list = panel.rows or {}
    local content = 0
    for _, r in ipairs(list) do
        content = content + pages.land_row_h(r, drh)
    end
    local over = math.max(0, content - (bottom - top))
    M.col_scroll = math.max(0, math.min(M.col_scroll, over))
    -- The panel follows the cursor, since walking it with a pad or the arrows
    -- is how it is read without a pointer: a row lit under the fold is a row
    -- nobody can see themselves spending on. On the frame the cursor moved
    -- and no other, which is what keeps a finger dragging it from being
    -- hauled back.
    local key = tostring(M.col_sel) .. "/" .. tostring(M.col_sel_value)
    if col_followed ~= key then
        col_followed = key
        local at = 0
        for _, r in ipairs(list) do
            local rh = pages.land_row_h(r, drh)
            local act, value = land_row_at(r)
            if act and act == M.col_sel and value == M.col_sel_value then
                if at < M.col_scroll then
                    M.col_scroll = at
                elseif at + rh > M.col_scroll + (bottom - top) then
                    M.col_scroll = at + rh - (bottom - top)
                end
                break
            end
            at = at + rh
        end
        M.col_scroll = math.max(0, math.min(M.col_scroll, over))
    end
    local y = top - M.col_scroll
    for _, r in ipairs(list) do
        local rh = pages.land_row_h(r, drh)
        if y >= top - 0.5 and y + rh <= bottom + 0.5 then
            land_row(kx, kw, y, rh, r)
        end
        y = y + rh
    end
    -- That there is more, said as a thumb against the panel's own edge rather
    -- than as a word. Only where there is: a rail on a panel that fits is an
    -- instrument reporting on nothing.
    if over > 0 then
        local run = bottom - top
        local thumb = math.max(20 * F.scale, run * run / content)
        local at = top + (run - thumb) * (M.col_scroll / over)
        rect(kx + kw - 3 * F.scale, top, 2 * F.scale, run, pal.a(pal.DIM, 0.2))
        rect(kx + kw - 3 * F.scale, at, 2 * F.scale, thumb,
             pal.a(pal.DIM, 0.7))
    end
end

-- What a keyboard walks, read off the boxes the last frame published rather
-- than off a second list of controls kept beside the drawing. What is on the
-- screen is a fact the drawing has already decided: a stop the open panel
-- stands over is not drawn, and a game the fleet is not serving publishes no
-- box because it cannot be picked.
--
-- With a panel up the walk is that panel, and only it: the way back out on
-- its head, then its rows in the order they were drawn. The stop that opened
-- it is off the bottom of the screen and out of the walk with it, which is
-- the point of the panel's own head carrying the way back.
--
-- One list, because there is one column. It was two, and they differed: the
-- landing's walk was a written order of four named controls and the menu's
-- was a filter over everything published, so the two screens disagreed about
-- whether a row could be reached before its list had arrived.
function M.col_walk()
    local out = {}
    for _, r in ipairs(M.hits) do
        if r.action == "menu_stop" or r.action == "menu_pick"
           or r.action == "menu_row" or r.action == "menu_back"
           or r.action == "menu_go"
           -- And the ship panel's own rows: the five sections, the carousel,
           -- the slots and the flair. The way out of it is the head's
           -- `menu_back`, already above.
           or r.action == "land_sect" or r.action == "land_pick_ship"
           or r.action == "land_kit_row" or r.action == "land_flair"
           or r.action == "land_kit_reset"
           -- And the players sheet: a row apiece, and the one key on the card
           -- a row opens. The way out of either is the head's `menu_back`,
           -- already above.
           or r.action == "board_row" or r.action == "board_join"
        then
            out[#out + 1] = r
        end
    end
    return out
end

-- What left or right does where the cursor is standing, as an action and a
-- value for `menu_act` to run, or nil where the two arrows mean nothing.
--
-- A row that holds a value is stepped by the arrows, which is how sound,
-- music, frames, the wake and the charge keys are all set, and how a credit
-- is spent and the carousel turned. The rows that are pages answer nothing:
-- left is the way back out and it has its own key.
function M.col_side(dir)
    if M.col_sel == "menu_row" then
        return "menu_step", {index = M.col_sel_value, dir = dir}
    end
    if M.col_sel == "land_kit_row" then
        return "land_kit_step", {slot = M.col_sel_value, dir = dir}
    end
    if M.col_sel == "land_flair" then
        return "land_flair_step", {index = M.col_sel_value, dir = dir}
    end
    if M.col_sel == "land_pick_ship" then
        return "land_page_ship", dir
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
    -- Nothing lit falls through to the key, which is the one thing this
    -- column exists for. A keyboard that had to walk to it would be a screen
    -- nobody can start the game from.
    --
    -- Only while the key is actually on the screen. With a panel up the
    -- column has gone out through the bottom edge and taken the key with it,
    -- and a press meant for a row of that panel must not take a seat instead.
    -- Asked of the boxes rather than of the state, because the drawing has
    -- already decided it.
    for _, r in ipairs(M.hits) do
        if r.action == "menu_go" then return "menu_go", nil end
    end
    return nil
end

-- Before a room answers: a dial looking for one, the name the column will
-- head itself with, and a line saying what went wrong when something has.
--
-- The whole of it. This is the loading screen, held from the moment the page
-- hands over until a room is on the glass, and everything the client has to
-- say about a room is about a room it has not found yet: the radar, the
-- readings over it, the roster and the column all arrive with the game.
--
-- The name is the one thing that does not, and it is drawn to the column's own
-- measure so that it does not move when the room arrives. See decisions 159
-- and 161.
--
-- A first boot is a directory lookup and a handshake, two seconds of it; a
-- game picked off the list drops the room on screen and dials the next one.
-- One wait, one picture.
function M.waiting(note)
    M.foot_key, M.joined = false, false
    -- The name, in the place the column will put it, off the column's own
    -- measure. Nothing on this screen moves when the room arrives: the stops
    -- and the key come up underneath a mark that was already there, which is
    -- the one thing a hand-off should never get wrong. See decision 161.
    local g = column_geom(COLUMN_STOPS)
    M.wordmark(g.mark_x, g.mark_y, g.size)
    -- And the dial that is looking for a room, hung directly over the name at
    -- whatever size the space above it allows.
    --
    -- Over the name rather than in the middle of the window. The middle is
    -- where the hull will be, which is what it used to be sized against, and
    -- that was the right measure while the name sat at the foot. The name
    -- stands where the column will head itself now, which on a short window is
    -- within a few points of the middle: the dial had nowhere to go and came
    -- out at its floor, a ring the size of a full stop tucked under the type.
    -- A stack has room on every window, and on the two with height to spare it
    -- puts the dial on the middle anyway.
    --
    -- Sized off the shorter side of the window as well, so a phone held
    -- upright gets one that fits across it.
    local head = g.mark_y - g.size / 2 - 16 * F.scale
    -- The band it has to stand in, less a margin at the top: sized against the
    -- whole of it, the dial on a landscape phone came out touching the edge of
    -- the window.
    local band = head - F.safe_t - 12 * F.scale
    local r = math.max(14 * F.scale,
                       math.min(56 * F.scale, band / 2,
                                math.min(F.w, F.h) * 0.12))
    pages.sweep_dial(F.w / 2, math.max(F.safe_t + r, head - r), r)
    -- A line under the name, but only when something has gone wrong. Waiting
    -- says nothing: the wordmark on a starfield is what this game looks like
    -- and a caption narrating a normal two second wait is noise. A fleet that
    -- is down is different, and silence there would be a client that looks
    -- like it is still trying.
    if note and note ~= "" then
        txt(note, F.w / 2, g.mark_y + g.size * 0.9,
            (M.compact and 11 or 13) * F.scale,
            pal.a(pal.DIM, 0.9), "center", MENU_FONT, true)
    end
end

-- The calls, listed under the scoreboard while the call key has them up.
--
-- Decision 67's board, the one the band opened before the players sheet took
-- the roster into the menu: a column hanging centered under the row, a wash
-- of the field color with a lit rule down its left edge and no border, and
-- rows one HUD line tall in the mono. No head: the rows are the whole of
-- what there is to read, and the key that put them up is the key that takes
-- them down. A digit says the row it numbers; so does a pointer, through the
-- box each row publishes. The fight behind is not washed, since the list is
-- up for a second and the fight is what you are reading. See decision 167.
function M.say_board(o)
    local calls = o.calls
    if not calls or #calls == 0 then return end
    local s = F.scale
    local w = 236 * s
    local x = math.floor((F.w - w) / 2)
    local y = TOP.mid() + KEY_H * s / 2 + 10 * s
    local line = LINE * s
    local h = #calls * line + 14 * s
    rect(x, y, w, h, pal.a(pal.BG, 0.62))
    rect(x, y, 1.5 * s, h, pal.a(pal.RADAR_TILE, 0.7))
    local top = y + 6 * s
    for i, phrase in ipairs(calls) do
        local mid = top + line / 2
        txt(tostring(i), x + 12 * s, mid, 10 * s, pal.DIM, nil, nil, true)
        txt(phrase, x + 26 * s, mid, 11 * s, pal.a(pal.INK, 0.9),
            nil, nil, true)
        hit(x, top, w, line, "say", (o.call_first or 0) + i - 1)
        top = top + line
    end
end

function M.hud(o)
    F.case = "upper"
    -- There is a room on the glass: this is the one thing that draws one. See
    -- `M.joined`.
    M.joined = true
    -- Whether the match on screen has been settled. What that changes here is
    -- the band, which gives up its pennants and stands the beaten side down;
    -- the account of the match itself is the players sheet, raised by the
    -- arena at the whistle like any other stop.
    local ending = match_ended(o.match)
    if sim.ship_count() == 0 then return end
    local me = o.me
    -- Before anything draws: every instrument that separates a friend from an
    -- enemy reads this, and while watching it is not the subject's side.
    view_team = o.side or team_of(o.me)
    F.menu_up = o.menu_open
    -- The menu key is drawn at the foot wherever there is a room, which is
    -- every frame this function runs. A screen still waiting on its first one
    -- clears the flag itself; see `M.waiting`. It used to be off for a client
    -- with no seat, on the grounds that the column out there was already up
    -- and could not be put away. It can be put away now, so the way back has
    -- to be on the screen.
    M.foot_key = true
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
    -- account stop and drawn by `M.land_card` after this returns. It was not
    -- read here at all for a while: a sign-up card washed the meshes behind it
    -- and left every instrument's label at full brightness, which is the exact
    -- fault the paragraph above is about. It went unnoticed while the only
    -- card the interface raised stood inside a drawer that was always up.
    --
    -- The board used to be the third case here, drawn in a column of its own
    -- with its own wash. It is a panel of the menu now, so `o.menu_open`
    -- covers it and there is nothing separate to dim for. The ending stays,
    -- because the sheet the whistle raises is that same menu.
    F.text_dim = (o.menu_open or o.card) and 0.34 or 1

    -- On a touchscreen the bottom of the screen belongs to the thumbs. The
    -- stick sits in the bottom left corner and the pads in the bottom right,
    -- which is exactly where the status panel and the control hint were, so
    -- everything else moves up out of the way of them.
    local lift = M.touching and 150 * F.scale or 0

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
    -- And so does a panel one of the stops opens, which is where this was
    -- noticed: the ship panel climbs from its own stop to the top of the
    -- window, and every call sign in the fight behind it was drawn through the
    -- build a pilot was reading. `o.panel` is that case, and it is a separate
    -- question from `o.menu_open`: the bare column is five rows at the foot
    -- and covers nothing.
    if not (o.menu_open or ending or o.panel or o.card) then
        nameplates(o)
    end
    -- One corner, one instrument. The map is the radar pulled back to the
    -- whole thousand tiles, so it stands where the radar stands rather than
    -- somewhere else with the radar still lit beside it.
    -- The dial's corner, in every state a room has. It used to stand down under
    -- an open drawer, which on a phone was the whole window; the column stands
    -- at the foot and reaches no corner, so the radar and the clock band are
    -- on screen while the menu is up. That is the point of a menu that does
    -- not pause: a pilot reading it is still being shot at, and the two
    -- instruments that say so keep saying it.
    --
    -- Drawn for a watcher as well as for a pilot, on the camera's own seat:
    -- what is near the hull the channel is behind is the question anybody
    -- reading this corner is asking, whether or not the hull is theirs. It was
    -- absent for a client that had taken no seat, which left a stranger
    -- watching a fight with no way to tell where in the map it was happening.
    -- See decision 159.
    if M.map then overview(me) else radar(o.cam_x, o.cam_y, me) end
    -- And the strip over it, which holds for the map as well: it is measured
    -- against the dial at rest, so the readings stay put while a player reads
    -- the whole arena. Four bars for a client that has not been handed a
    -- reading yet, which is what a fresh connection looks like anyway.
    --
    -- POS reads the camera's own seat, which while watching is the hull the
    -- channel is behind. Where the fight is in the map, said in tiles, is the
    -- reading everybody looking at this corner wants, whether or not the hull
    -- under the camera is theirs.
    over_dial(o.link or 4, me)
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
    --
    -- Down under anything being read over the arena, on the same rule the
    -- nameplates go down on and for the same reason: glyphs come from the gui
    -- and the gui draws over every mesh, so no panel can cover this. On a
    -- phone a panel is most of the window, and a kill line was landing in the
    -- middle of a settings row: the line is unreadable there and it takes the
    -- row with it. The instruments stay, because you can still be shot while
    -- you read; the feed is news rather than an instrument, and the corner
    -- feed is already off on a touchscreen for the same kind of reason.
    if M.touching
       and not (o.menu_open or ending or o.panel or o.card)
    then
        toast(o.feed, o.pad_top)
    end
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
    -- And the room itself, for the players sheet the menu is about to draw.
    -- Filled here rather than handed over in the view, because the figures a
    -- row carries come from the simulation for every seat this client can see
    -- and from the roster for the rest, and this file is where that read
    -- lives. Only while the menu is up: nothing else reads it, and sorting a
    -- room every frame for a panel nobody opened is work for no reader.
    if o.menu_open then
        refresh_players(o.pilots, o.watchers, nil, o.viewer_name)
        M.sheet = {
            -- The sides' names, and which of them this zone will say out
            -- loud. A public side is one anybody may see named; a private one
            -- is a squad who arranged themselves, and naming it on a row
            -- would hand the room a roster the zone deliberately withheld.
            names = o.side_names, teams = o.teams,
            -- The roster rows, for the card a pressed row opens: what the
            -- zone vouches for a seat as, and where the ladder has them.
            pilots = o.pilots, ratings = o.ratings, me = o.me,
            -- And what the match has done to each rating, which the column
            -- reads beside the standing for the whole match rather than at
            -- the whistle alone. Where the ladder has the room is the reading
            -- this panel is opened for, and a standing handed over once the
            -- fighting is finished is one nobody could fly against. Your own
            -- has stood in the corner of the band all match since decision
            -- 163, in these words; the column says it for everybody in the
            -- room.
            moved = rating_moves(o),
        }
    end
    -- The band and the room's line under it read at full strength over the
    -- wash as well. They are the instrument the board belongs to rather than
    -- something it covers, and the clock is the one reading a player wants
    -- whatever else is up.
    --
    -- The ending for the same reason and more so. What it says is who took
    -- the match and how long until the next one, and the countdown is part of
    -- that rather than something behind it: at a third of an alpha the one
    -- number on screen that is still moving was the faintest thing on it.
    if ending then F.text_dim = 1 end
    -- Through the ending as well, which is the whole point of a band: the
    -- clock is one instrument in one place, and a player who has spent three
    -- minutes reading the top of the window does not have to find it
    -- somewhere else the moment the whistle goes. The ending's own head
    -- carries the score, so the band gives its two sides up while that block
    -- is on screen and keeps the numerals. See `match_clock`.
    match_clock(o, o.match, o.side_names, o.menu_open)
    if o.say then M.say_board(o) end
    -- The pennants belong to the band and are drawn with it, which puts them
    -- above the menu's early return below. Same reason the clock is: the menu
    -- is a scrim rather than a curtain, and who is holding what is exactly the
    -- reading a player opening it wants to keep. Called between the two lines
    -- it sits between on the screen, so the order here is the order down it.
    flag_strip(o.match)
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
    if ending then return end
    -- Over the arena and under nothing, since it is the thing being read. The
    -- game carries on behind it: nothing is paused here, and a player who
    -- opens this in a fight can still be shot while they read.
    if M.help then
        help_table()
    elseif M.help_prompt then
        help_prompt()
    end
    -- The room's own line and the pennant strip are drawn with the band they
    -- hang off, above. See `match_note` and `flag_strip`.
    if o.lag_notice and o.lag_notice ~= "" then
        txt(o.lag_notice, F.w / 2,
            band_bottom() + FLAG.stack(o.match) + 26 * F.scale,
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
-- end says what the row does. Five ends and nothing else varies:
--
--   reads     `detail`  -- a value, in the mono, with no control
--   steps     `step`    -- arrows either side of a count
--   fills     `choice`  -- one cell per value, the word beside them
--   switches  `toggle`  -- the box, lit and to the right for on
--   walks     `walk`    -- arrows at the edges, the name between them
--
-- and the states that can be true of any of them: `hot` where a press would
-- land, `mark` where you already are, `tint` for a side, `offer` for the one
-- row that is an offer, `dim` for a row that cannot act, and `waiting` for a
-- game the fleet is not serving yet.
--
-- There were six. A row that opened a panel wore a caret at the right edge,
-- and every row that could be pressed into a panel wore one, so it told a
-- hand nothing and cost a section the corner its reading wants. A row that
-- opens is an ordinary reading now, and the panel is the answer to the press.
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
    -- A game nothing is serving keeps the dial that is looking for one, at the
    -- right end where a reading sits, and gives up that much of the column.
    --
    -- The one state on a row that draws rather than colors. `dim` says the row
    -- cannot be pressed and this says why, which is the part that can change
    -- while the list is on screen: the directory is re-asked every three
    -- seconds and an arena can come back to a game at any of them. What the row
    -- reads is still read, because the format of a game is true whether or not
    -- anybody is running it; it is set inside the dial rather than under it.
    if r.waiting then
        local dr = 11 * F.scale
        pages.sweep_dial(x + w - dr, y + h / 2, dr)
        w = w - 2 * dr - 10 * F.scale
    end
    -- No field is laid here. The cursor and the standing mark are a field of
    -- team blue across the row, and the row this function draws is the type
    -- column: fourteen points in on either side of the glass. Lighting from
    -- inside meant a highlight that stopped short of both edges, and on the
    -- pages that lit the row themselves as well, a brighter band up the
    -- middle where the two fields overlapped. `LIT.state` is the one place it
    -- happens now, called by the page that knows where the glass ends.
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
        and not (r.walk or r.toggle or r.step)
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
    -- The three ends below are the ones that carry a control. They are drawn
    -- before `choice` and `detail` because a row wears exactly one end, and
    -- these are the ones that publish a press of their own.
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
        -- The switch takes a press whether or not it can be thrown. A switch
        -- that is off and cannot be afforded is still drawn, and a control
        -- drawn where a press does nothing at all is a control that looks
        -- broken: the press goes through and the arena answers it. See
        -- `spend`.
        local s = r.step
        if s then
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
        -- Both arrows take a press, and a dim one is answered rather than
        -- ignored. A dim arrow published no box at all, so a pilot pressing
        -- the up arrow on an empty purse pressed the glass behind it: the
        -- panel swallowed the press and the interface said nothing, which
        -- reads as a control that has stopped working rather than as a purse
        -- that is empty. The arena makes the refusal audible. See `spend`.
        for _, d in ipairs({{-1, vx - 54 * F.scale, s.can_down},
                            {1, vx, s.can_up}}) do
            local dir, ax, live = d[1], d[2], d[3]
            F.layer:tri(ax + dir * 4.5 * F.scale, ry(mid),
                        ax - dir * 4 * F.scale, ry(mid - 5.5 * F.scale),
                        ax - dir * 4 * F.scale, ry(mid + 5.5 * F.scale),
                        pal.a(pal.FRIEND, live and 0.9 or 0.25))
            hit(ax - 14 * F.scale, y, 28 * F.scale, h, s.action,
                {slot = s.slot, dir = dir}, nil, 1)
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
-- breathing key at its foot, which is what the column's own key already is.
-- Pressing back is pressing cancel: the two were always the same act, and one
-- of them had no button.
--
-- A question with no lines to fill in is not this. A confirm with two equal
-- answers stays an `ask_card`, deliberately: it is a question about an act
-- rather than a place to be, and it belongs over whatever raised it.
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
    local pad = M.ROW_INSET * F.scale
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

-- The menu: five stops over one key, and there is one of it.
--
-- `v` is `menu.view()`. It carries the stops and the rows of whichever stop
-- is open. That is the whole payload.
--
-- Two of these stood in this file for a year. The landing drew ACCOUNT, ZONE
-- and SHIP over PLAY NOW off a payload of its own; the column drew ZONE,
-- SHIP, SETTINGS and SIDE over RESUME off this one. They shared every
-- drawing primitive under them and diverged above: two geometries measuring
-- the same stops at the same width, two keyboard walks that disagreed about
-- when a row was reachable, two sets of actions for one press. What a player
-- got out of that was a front page with no settings on it and a match menu
-- with no account, so where a thing lived depended on whether you had taken
-- a seat yet. See decision 143.
--
-- One difference outlived that merge: whether the column was the screen or a
-- panel raised over a fight. Out on the landing it carried the lockup, washed
-- nothing, and could not be put away, because putting it away left a player
-- looking at a starfield with no way back. There is a game behind it wherever
-- it stands now, so it is a panel everywhere and there is nothing left to
-- branch on. See decision 159.
--
-- What it replaced on the way here was a rail of tabs, a stage, a topbar, a
-- head row and a preview of the page the rail cursor was resting on: five
-- answers to "where am I" on a panel four pages deep. A lit stop with its
-- panel climbing off it is one answer.
function M.menu(v)
    local n = v.stops and #v.stops or 0
    if n == 0 then return end
    -- The HUD shouts, because everything in flight does; the menu speaks. A
    -- row that says "Sound" is a label and one that says "SOUND" is an
    -- instrument reading, and these are labels. Restored on the way out,
    -- since anything drawn after the column is the arena's again.
    local was_case = F.case
    F.case = "sentence"
    -- And at full strength, which it was not. `M.hud` drops every word on
    -- screen to a third while the menu is up, so the instruments behind it
    -- recede, and then returns early with that still set: the column is drawn
    -- after it and inherited the dim meant for what it stands over. Every
    -- word of the in-match menu came out at 0.34 against the landing's 1.00,
    -- on the same rows drawn by the same function. RESUME was grey where PLAY
    -- NOW is lit, and the settings stop's ink read as mute.
    --
    -- `M.land_card` and `ask_card` have always done this, for exactly this
    -- reason: what is being read is at full strength and what it is read over
    -- is not. Nothing caught it because the shared test harness answers zero
    -- to `ship_count`, and `M.hud` returns before the dim on an empty world.
    --
    -- Unless something stands over the column in turn, in which case the dim
    -- is meant for this too and is kept: the menu's own card, which is drawn
    -- after this and cannot reach back to quiet what it covers.
    local was_dim = F.text_dim
    if not v.ask then F.text_dim = 1 end
    local g = column_geom(n)
    column_x, column_w = g.kx, g.kw
    -- The slide, which is how the column arrives and leaves.
    --
    -- `F.now` is zero under the test harness, which is what settles it
    -- instantly there and keeps the layout tests still.
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
    -- it. One grammar for both was the point of decision 102, so it holds for
    -- what a stop opens too.
    --
    -- Which stop is actually showing something. A stop is opened by a press
    -- and filled by whatever answers next, so between the two there is a frame
    -- or two where the stack names a stop with nothing behind it yet. The
    -- column stays put through those: sliding away to reveal an empty panel is
    -- worse than a stop that takes a moment to open.
    local open = nil
    for _, s in ipairs(v.stops) do
        if s.open then open = s end
    end
    if open and open.stop == "ship" and not v.panel then open = nil end
    -- The players sheet is drawn from the room this file already holds rather
    -- than from rows in the view, so it is open the moment its stop is,
    -- without a frame of empty glass while something answers.
    if open and open.stop ~= "ship" and open.stop ~= "players"
       and #v.rows == 0 then
        open = nil
    end
    local at = panel_slide(menu_slide, open and 1 or 0)
    if not open then
        menu_h.at, menu_h.from, menu_h.to, menu_h.when = 0, 0, 0, 0
    end
    local drop = at * (F.h - g.top)
    local live = at < 0.5

    -- The wash behind the column, and a press off it to put it away.
    wash(0, 0, F.w, F.h, pal.a(pal.BG, COLUMN_WASH * M.column))
    -- Under everything else: the lowest priority box on the screen.
    hit(0, 0, F.w, F.h, "menu_shut", nil, nil, -2)

    -- The key first, under the stops that stand over it.
    --
    -- Which word it wears is the whole of what this screen knows about where
    -- you are sitting and what you are holding. No seat in the room, whether
    -- this client has just opened or has been benched, and it is the way into
    -- one; a seat of your own, and it is the way back out to the stands of the
    -- same game; a seat with a hull drafted over it, and it is the refit, which
    -- names the hull because that is the whole of what the press does. The
    -- stands need no name on it: `PLAY` already means "in whatever the ship
    -- stop says". See decisions 143 and 160.
    local word = "PLAY"
    if v.key == "fly" then
        word = "FLY " .. string.upper(v.key_ship or "")
    elseif v.key == "spectate" then
        word = "SPECTATE"
    end
    local ky = g.ky + rise + drop
    local key_hot = M.col_sel == "menu_go"
    if at < 1 then
        commit_key(g.kx, ky, g.kw, g.kh, g.kpx, word, key_hot)
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
                      "menu_stop", s.open,
                      {raw = s.named, value = s.stop, warn = s.warn})
        end
    end
    -- A stop on its way out is not a stop.
    if not live then
        for i = #M.hits, stops_at + 1, -1 do M.hits[i] = nil end
    end

    if open then
        -- The games and the account acts, one row each, which is the shape
        -- every list in this menu has: a name, what it is, and a mark on the
        -- one you are already on.
        local list = nil
        if open.stop == "zone" or open.stop == "account" then
            list = {}
            for _, r in ipairs(v.rows) do
                if r.rule then
                    list[#list + 1] = {rule = true}
                else
                    list[#list + 1] = {label = r.label,
                                       note = r.note or r.detail,
                                       raw = r.named, here = r.mark,
                                       tint = r.tint, dim = r.dim,
                                       offer = r.offer, waiting = r.waiting,
                                       action = "menu_pick", value = r.index}
                end
            end
        end
        -- And the ship, which is a panel rather than a list: five parts of a
        -- ship over the credits they are bought with, or whichever of the five
        -- is open over the same credits. See `land_panel`.
        local panel = open.stop == "ship" and v.panel or nil
        -- The players sheet, and the card a pressed row opened over it. The
        -- card is a panel that stacked, which is what `board` names here: one
        -- level in the head says players, two levels in it says the pilot,
        -- and back steps one of those at a time.
        local board = open.stop == "players"
        local card = board and M.col_pilot ~= nil
            and select(2, pages.board_at(M.col_pilot)) or nil
        -- As tall as what it holds, eased between one page's worth and the
        -- next: walking from settings into the controls board slides the glass
        -- to the new page's height rather than swapping two rectangles.
        local noted = false
        for _, r in ipairs(v.rows) do
            if r.note then noted = true end
        end
        -- One row height, and it is the settings page's: a games row is as
        -- tall as a sound row because they are the same object.
        --
        -- These were thirty on a monitor and forty on a phone, from the days
        -- when a list was a strip that had to keep off the key and every point
        -- of height was one the key could not have. The panel is the window
        -- now, so the room is there to spend, and forty four is the floor
        -- every platform's own ruler puts under a fingertip. It is also what a
        -- row wants before it can carry a sentence of its own: the note under
        -- a name is drawn only where the row has the two lines for it.
        local prh = (M.compact and 40 or 44) * F.scale
        local tall = (panel and pages.ship_h(panel, prh))
            or (card and pages.HEAD_H * F.scale
                + (pages.board_foot(card) and 5 or 4) * prh + 10 * F.scale)
            or (board and pages.board_h(prh))
            or (list and pages.list_h(list, prh))
            or pages.page_h(v, prh, noted)
        local px, py, pw, ph =
            panel_geom(panel_height(menu_h, math.min(tall, panel_room())))
        -- The panel rides the column's own slide as well as its own, so
        -- dismissing the whole menu with a page open takes the page with it
        -- rather than leaving it standing over the fight.
        py = py + (1 - at) * (F.h - py) + rise
        -- A backdrop behind everything (`pri` -1) so a press on the margin
        -- beside the glass puts the panel away rather than pulling a trigger
        -- on the fight. The column's own backdrop is already under this at -2
        -- and means one level further out.
        hit(0, 0, F.w, F.h, "menu_shut", nil, nil, -1)
        -- The rows are the panel's now, so that is the span they are lit at.
        column_x, column_w = px, pw
        if panel then
            -- Named by the section that is open rather than by the stop: one
            -- level in the head says ship, two levels in it says body, and
            -- back steps one of those at a time. The tray rides the frame at
            -- both levels, so the purse is on screen wherever a credit is
            -- spent.
            local top, foot = panel_frame(px, py, pw, ph,
                                          panel.label or open.label,
                                          "menu_back", v.foot, nil, panel)
            land_panel(px, pw, top, foot, panel, prh)
        elseif card then
            local _, col = pages.sheet_side(card)
            local top, foot = panel_frame(px, py, pw, ph, card.name,
                                          "menu_back", nil, nil, nil,
                                          {col = pal.a(col, 0.95)})
            pages.board_card(px, pw, top, foot, card, prh)
        elseif board then
            local top, foot = panel_frame(px, py, pw, ph, open.label,
                                          "menu_back")
            pages.board_list(px, pw, top, foot, prh)
        elseif list then
            local top = panel_frame(px, py, pw, ph, open.label, "menu_back")
            land_list(px, pw, top, list, prh)
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

    -- The lockup, over the column it heads.
    --
    -- It goes when a stop opens, because the column is one object and a name
    -- left hanging over an open panel is the menu refusing to get out of the
    -- way, and it comes back when the panel does. And it rides the column's
    -- own slide, so the two arrive and leave together: it used to be pinned
    -- while the stops sank underneath it, which nobody saw because the screen
    -- it stood on could not be dismissed. See decision 161.
    if at <= 0.001 then M.wordmark(g.mark_x, g.mark_y + rise, g.size) end

    -- While the column is going away it still draws, so the fight behind it
    -- comes back through a wash that is fading rather than a panel that
    -- vanished. Nothing it published can be pressed, though: a key on the way
    -- out is not a key.
    if v.open == false then
        for i = #M.hits, hits_before + 1, -1 do M.hits[i] = nil end
    end
    F.case = was_case
    F.text_dim = was_dim
end

-- --- the players sheet ------------------------------------------------------
--
-- Everybody in the room, one row each, in the menu's own language: the glass,
-- the head, rows at the touch floor. It is what the band opens, what the
-- `players` stop opens, and what the whistle raises by itself, and all three
-- are the same panel because there is one of it. See decision 147.
--
-- The room it draws is `rows`, filled by `refresh_players` while the menu is
-- up, and `M.sheet`, which carries what a row cannot read off the simulation:
-- the sides' names, whether the zone will say them, and where the ladder has
-- everybody.

-- What a row says about a side, and in what color.
--
-- The zone decides whether a side may be named. A public one is anybody's to
-- see; a private one is a squad who arranged themselves, and printing its
-- name in a column would hand the room a roster the zone withheld. Your own
-- side is always yours to know, since you are in it. What is withheld is the
-- name and never the fact: the color is on their hull already.
function pages.sheet_side(r)
    if r.watch then return "watching", pal.MUTE end
    local col = team_col(r.team)
    local sheet = M.sheet or {}
    for _, t in ipairs(sheet.teams or {}) do
        if t.team == r.team then
            -- Whether this side would take you, which the zone answers rather
            -- than the client working it out of two counts and a cap. It is
            -- the same byte that decides whether a side is offered anywhere
            -- else, so a full side reads the same way in every place that
            -- names one.
            if t.public or r.mine then
                if t.name ~= "" then return t.name, col, true, t.may_join end
                return "team " .. t.team, col, false, t.may_join
            end
            return "private", col, false, t.may_join
        end
    end
    return "private", col
end

-- The sheet's columns, measured against what is actually in them.
--
-- Each is as wide as the widest thing in it, heading included, every frame.
-- Fixed offsets do not survive several columns in a panel that is 560 points
-- on a monitor and 362 on an upright phone: a column sized for the worst case
-- eats the names in every room where the worst case has not happened.
--
-- Assists go first where the glass is too narrow to hold every column, which
-- is an upright phone. It is the one figure of the four that is about a kill
-- somebody else finished, and the Team column is what this sheet exists to
-- carry.
function pages.sheet_cols(n)
    local px = TYPE.BODY * F.scale
    local out = {}
    local function col(key, head, wide)
        for i = 1, n do
            local r = rows[i]
            local v = r[key]
            if key == "team" then
                v = (pages.sheet_side(r))
            elseif key == "moved" then
                v = r.moved_at
            end
            if v ~= nil then
                wide = math.max(wide, text_w(tostring(v), px))
            end
        end
        out[#out + 1] = {key = key, head = head,
                         w = math.max(wide, text_w(head, LBL_PX * F.scale))}
    end
    col("team", "TEAM", 0)
    col("k", "K", 16 * F.scale)
    col("d", "D", 16 * F.scale)
    if not M.compact then col("a", "A", 16 * F.scale) end
    if (M.sheet or {}).moved then col("moved", "RATING", 0) end
    return out
end

-- How wide the columns come to, gaps included, so the name knows where it
-- ends.
function pages.sheet_run(cols)
    local gap = 10 * F.scale
    local run = 0
    for i, c in ipairs(cols) do
        run = run + c.w + (i > 1 and gap or 0)
    end
    return run, gap
end

-- One row: the name in its side's color with the seat's mark after it, then
-- the columns right-aligned off the panel's own edge.
--
-- Your own row keeps the wash it wears everywhere in this interface. A row
-- under a hand lights edge to edge like every other row, and a press on it
-- opens that pilot's card.
local function sheet_row(kx, kw, y, h, r, cols, i)
    local pad = M.ROW_INSET * F.scale
    local hot = M.col_sel == "board_row" and M.col_sel_value == i
    LIT.state(kx, y, kw, h, hot, r.self)
    local _, col = pages.sheet_side(r)
    if r.watch then col = pal.READ end
    local mid = y + h / 2
    local run, gap = pages.sheet_run(cols)
    -- Where the name has to stop. Cut at the columns rather than drawn
    -- through them: a call sign is as long as its pilot made it, and the
    -- figures are the reading this sheet is opened for.
    local kept = F.clip_r
    F.clip_r = math.min(kept or math.huge, kx + kw - pad - run - gap)
    local tx = kx + pad
    txt(r.name, tx, mid, TYPE.ROW * F.scale,
        pal.a(col, r.self and 1 or 0.85), nil, MENU_FONT, true)
    -- The mark rides after the name, which is where it rode on the board this
    -- replaced: one line, and the column it would line up in is spent on the
    -- figures.
    local mark_x = tx + text_w(r.name, TYPE.ROW * F.scale, MENU_FONT, true)
        + 6 * F.scale
    -- In the band's color, the same five the corner's badge wears, so one
    -- mark answers two questions at once: what is in the seat, by its shape,
    -- and how good they are, by its color. The column beside it says where
    -- the ladder has everybody in figures; this says it down the list at a
    -- glance, which is what a room of strangers is read for.
    local band = pal.a(pal.tier(r.tier), 0.85)
    if r.ai then
        bot_mark(mark_x, mid, band, 11 * F.scale)
    else
        pilot_mark(mark_x, mid, band, 11 * F.scale)
    end
    F.clip_r = kept
    -- The figures, in the face every number in this game is set in.
    local px = TYPE.BODY * F.scale
    local x = kx + kw - pad
    for j = #cols, 1, -1 do
        local c = cols[j]
        if c.key == "team" then
            -- A side's name is quoted, in the case the zone gave it, the way
            -- a name is quoted everywhere in this interface. What is not a
            -- name is the interface's own word for the absence of one, and
            -- those take the interface's own case: a private side, and a
            -- watcher who is on no side at all.
            local name, tcol, named = pages.sheet_side(r)
            txt(name, x, mid, px, pal.a(tcol, 0.9), "right", nil, named)
        elseif c.key == "moved" then
            -- Where the ladder has them, and what the match has done to it,
            -- and nothing at all for somebody who is not in it.
            --
            -- Two colors, because the two are different kinds of fact. The
            -- standing is a reading like the three figures beside it and is
            -- set in their ink; the movement is what the match has done to
            -- it, green up, red down and mute where nothing has happened. One
            -- ink over the pair would have said a standing was good or bad,
            -- which no rating is.
            if r.moved_by then
                local by = r.moved
                local mcol = pal.a(pal.MUTE, 1)
                if by and by > 0 then mcol = pal.a(pal.PAID, 0.95)
                elseif by and by < 0 then mcol = pal.a(pal.HURT, 0.9) end
                txt(r.moved_by, x, mid, px, mcol, "right")
                -- In front of the bracket, off the bracket's own width, so
                -- the pair sits exactly where the column was measured for.
                if r.rating_at then
                    txt(r.rating_at, x - text_w(" " .. r.moved_by, px), mid,
                        px, pal.a(pal.READ, 1), "right")
                end
            end
        else
            -- A watcher's figures are zeros in the register a reading that
            -- means nothing is set in: they are in the room without being in
            -- the game, and the row says so in its Team column.
            txt(tostring(r[c.key]), x, mid, px,
                pal.a(r.watch and pal.MUTE or pal.READ, 1), "right")
        end
        x = x - c.w - gap
    end
    -- And the press, for a row that has a card behind it. A watcher has no
    -- seat, so there is nothing to open and no key to offer: their row reads
    -- rather than presses, which is a row the cursor steps over and a hand
    -- gets no light from. A press drawn over nothing is worse than no press,
    -- since the one answer it can give is silence.
    if r.i ~= nil then hit(kx, y, kw, h, "board_row", i, nil, 1) end
end

-- How tall the sheet wants to be: a heading and a row per body in the room.
function pages.board_h(rowh)
    return pages.HEAD_H * F.scale + 24 * F.scale + #rows * rowh
        + 10 * F.scale
end

-- The sheet, laid into the room the frame left it.
--
-- Scrolled with `M.page_scroll`, which is what the settings page uses and
-- what the wheel and a dragging thumb already move: one panel of the menu
-- scrolls at a time and this is a panel of the menu.
function pages.board_list(kx, kw, top, bottom, rowh)
    local pad = M.ROW_INSET * F.scale
    local n = #rows
    -- Where the ladder has each pilot, and what this match has done to it:
    -- the standing first and the movement after it in brackets, which is the
    -- order the two are read in. A signed figure on its own says how the
    -- evening went and not where anybody stands, and where a pilot stands is
    -- what the column is called.
    --
    -- Worked out before the columns are measured, because the widest of them
    -- is what the column is sized to, and written onto the rows rather than
    -- looked up twice, since the measure and the drawing both want it. The
    -- two halves are kept apart as well as joined: they are drawn in
    -- different ink and the drawing needs the bracket's own width to place
    -- the standing in front of it.
    local sheet = M.sheet or {}
    local moved, scores = sheet.moved, sheet.ratings
    for i = 1, n do
        local r = rows[i]
        local seated = not r.watch and r.i ~= nil
        local by = moved and seated and moved[r.i] or nil
        r.moved = by
        -- Rounded the way the card rounds it, so a pilot reading their own
        -- standing in two places is not told two numbers.
        local at = scores and seated and scores[r.i] or nil
        r.rating_at = at and tostring(math.floor(at + 0.5)) or nil
        -- A pilot whose rating did not move reads a bracketed zero, because
        -- "this match has changed nothing for you" is an answer and a blank is
        -- not. A watcher is in the room without being in the match and reads
        -- nothing at all.
        --
        -- Nor does a seat whose standing has not arrived, which is a pilot the
        -- snapshot carries and the roster has not named yet. A bracket with no
        -- figure in front of it says the match has cost them nothing, and what
        -- the client actually knows about them is nothing. Keyed on the
        -- standing rather than on the seat for that reason, and a watcher has
        -- no standing either, so the seat no longer needs asking about twice.
        r.moved_by = moved and r.rating_at
            and ("(" .. ((by and by > 0) and "+" or "")
                 .. tostring(by or 0) .. ")") or nil
        if r.moved_by then
            r.moved_at = r.rating_at
                and (r.rating_at .. " " .. r.moved_by) or r.moved_by
        else
            r.moved_at = nil
        end
    end
    local cols = pages.sheet_cols(n)
    local heads = 24 * F.scale
    local view_h = bottom - top
    M.page_x, M.page_y, M.page_w, M.page_h = kx, top, kw, view_h
    local extent = heads + n * rowh
    local max_scroll = math.max(0, extent - view_h)
    if M.page_scroll > max_scroll then M.page_scroll = max_scroll end
    if M.page_scroll < 0 then M.page_scroll = 0 end
    -- And it follows the cursor, the way every panel in this menu does: a row
    -- lit under the fold is a row nobody can see themselves pressing.
    if M.col_sel == "board_row" and page_followed ~= M.col_sel_value then
        page_followed = M.col_sel_value
        local at = heads + (M.col_sel_value - 1) * rowh
        if at < M.page_scroll then
            M.page_scroll = at
        elseif at + rowh > M.page_scroll + view_h then
            M.page_scroll = at + rowh - view_h
        end
        M.page_scroll = math.max(0, math.min(M.page_scroll, max_scroll))
    elseif M.col_sel ~= "board_row" then
        page_followed = nil
    end
    local y = top - M.page_scroll
    -- The headings, which name the columns and nothing else. They were four
    -- controls that sorted by what they named; the Team column says the side
    -- on every row now, so the grouping is a reading rather than the only way
    -- to tell, and one order everybody learns beats four to find a way back
    -- from. See `by_column`.
    if y + heads > top and y < top + view_h then
        local run, gap = pages.sheet_run(cols)
        local x = kx + kw - pad
        for j = #cols, 1, -1 do
            lbl(cols[j].head, x, y + heads / 2, pal.MUTE, "right")
            x = x - cols[j].w - gap
        end
        local _ = run
    end
    y = y + heads
    -- Whole rows only, which is the rule the ship panel follows and the one
    -- the interface is written to: the scissor in the renderer cuts against a
    -- vertical edge, so a row half off the bottom draws through the frame
    -- rather than being cut by it, and a name sliced across the middle reads
    -- as a fault. What a row does at the edge is appear whole or not at all,
    -- and the thumb on the panel's edge is what says there is more.
    for i = 1, n do
        if y >= top - 0.5 and y + rowh <= top + view_h + 0.5 then
            sheet_row(kx, kw, y, rowh, rows[i], cols, i)
        end
        y = y + rowh
    end
    -- That there is more, as a thumb against the panel's own edge. Only where
    -- there is: a rail on a panel that fits is an instrument reporting on
    -- nothing.
    if max_scroll > 0 then
        local run = view_h
        local thumb = math.max(20 * F.scale, run * run / extent)
        local at = top + (run - thumb) * (M.page_scroll / max_scroll)
        rect(kx + kw - 3 * F.scale, top, 2 * F.scale, run, pal.a(pal.DIM, 0.2))
        rect(kx + kw - 3 * F.scale, at, 2 * F.scale, thumb,
             pal.a(pal.DIM, 0.7))
    end
end

-- Which row of the sheet is about this seat, or nil once they have gone. A
-- pilot who left while their card was open takes the card with them rather
-- than leaving a panel about somebody who is not there.
function pages.board_at(seat)
    for i = 1, #rows do
        if rows[i].i ~= nil and rows[i].i == seat then return i, rows[i] end
    end
    return nil
end

-- The two lookups the arena needs to turn a press into a pilot and back.
--
-- A row's number is where it sits on the screen this frame and a seat is who
-- it is about, and the two part company the moment somebody joins or dies:
-- the list re-sorts every frame it is drawn. So a press is answered as a
-- seat, which outlives the sort, and a cursor is put back on a row by looking
-- the seat up again.
--
-- A watcher has no seat and no card, which is what the nil says.
function M.board_seat_of(row)
    local r = row and rows[row]
    return r and r.i or nil
end

function M.board_row_of(seat)
    return (pages.board_at(seat))
end

-- The card a pressed row opens: one pilot, and the one act the sheet offers.
--
-- A panel that stacked, which is what the language already calls this: the
-- head names them, back steps out onto the sheet, and the rows read what the
-- zone will vouch for and what they have done this match. The card answers
-- the question a name over a hull raises and cannot itself answer.
--
-- Its foot is the way onto their side. That is where an invitation was always
-- going to live: picking a person is the whole of the old invite menu, and a
-- player deciding to join a side is usually already reading about somebody on
-- it. Gated exactly as a hull change is, so the key says what it will cost by
-- refusing rather than by warning.
-- Whether a card about this pilot has a foot: the key onto their side, or the
-- line saying that side will not take you. Asked before the panel is measured,
-- because the language sizes a panel to what it holds and a card with nothing
-- to offer should not keep an empty row where a key would have gone.
function pages.board_foot(r)
    if r == nil or r.watch or r.mine or r.self then return false end
    return true
end

function pages.board_card(kx, kw, top, bottom, r, rowh)
    local sheet = M.sheet or {}
    local p = r.i ~= nil and sheet.pilots and sheet.pilots[r.i] or nil
    local side, side_col, side_named = pages.sheet_side(r)
    local out = {}
    local function line(label, detail, col, named)
        out[#out + 1] = {label = label, detail = detail, col = col,
                         named = named}
    end
    line("Team", side, side_col, side_named)
    -- What the zone is willing to say this seat is, which is the honest
    -- version of the question: the client cannot tell, and the server's label
    -- is the only answer anybody has. A guest is not an accusation.
    line("Seat", (p and p.label) or "unknown")
    -- Where the ladder has them, as the band and the number under it: the band
    -- moves only when something changed, and the number is what the band is a
    -- rounding of. A watcher has no rating and a dash is the honest answer.
    local tier = (p and p.tier) or "unrated"
    local score = sheet.ratings and r.i ~= nil and sheet.ratings[r.i]
    line("Rating", score
        and (tostring(math.floor(score + 0.5)) .. " " .. tier) or tier,
        (tier == "placing" or not score) and pal.a(pal.MUTE, 1) or nil)
    -- And the match, on one line rather than three: they are the same three
    -- numbers the row this card was opened from already carries, and a card
    -- that spent a row apiece on them would be the sheet said again.
    line("This match", r.watch and "watching"
        or (r.k .. " k  " .. r.d .. " d  " .. r.a .. " a"))
    -- The label through the row every menu row is drawn by, and the reading
    -- beside it drawn here rather than handed over with it: two of these are
    -- in a color the row has no way to be told about, and a row that drew its
    -- own reading and then had a second one laid over it would be the value
    -- printed twice.
    local pad = M.ROW_INSET * F.scale
    local y = top
    for _, l in ipairs(out) do
        menu_row(kx + pad, y, kw - 2 * pad, rowh, {label = l.label}, false)
        txt(l.detail, kx + kw - pad, y + rowh / 2, TYPE.BODY * F.scale,
            l.col or pal.a(pal.READ, 1), "right",
            l.named and MENU_FONT or nil, l.named)
        y = y + rowh
    end
    -- The key, at the foot of what it is about.
    --
    -- Drawn only where it would do something: somebody else, on a side that
    -- is not yours and has a seat. On your own side, on yourself and on a
    -- watcher there is nothing for it to do, and a key that looks pressable
    -- and is not is worse than no key. A side with nobody spare says so
    -- instead, in the register an unavailable thing is written in.
    local _, _, _, may_join = pages.sheet_side(r)
    if pages.board_foot(r) then
        local kh = (M.compact and 40 or 44) * F.scale
        local ky = bottom - kh
        if may_join == false then
            txt(side .. " is full", kx + kw / 2, ky + kh / 2,
                TYPE.BODY * F.scale, pal.a(pal.MUTE, 1), "center", MENU_FONT)
        else
            local hot = M.col_sel == "board_join"
            commit_key(kx + pad, ky, kw - 2 * pad, kh,
                       TYPE.BODY * F.scale, "JOIN " .. string.upper(side), hot)
            hit(kx + pad, ky, kw - 2 * pad, kh, "board_join", r.team, nil, 1)
        end
    end
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
    local pad = M.ROW_INSET * F.scale
    local rowh = (M.compact and 40 or 44) * F.scale
    -- One run of rows, with nothing banding them. The page grouped its rows
    -- under small labels once, audio over the two sound rows and the machine
    -- over the last two, and six settings are not enough of a page to want
    -- chapters: the headings said what the rows under them already said, and
    -- three of them made a short page read like a form.
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
    local extent = #v.rows * rh
    local max_scroll = math.max(0, extent - view_h)
    if M.page_scroll > max_scroll then M.page_scroll = max_scroll end
    if M.page_scroll < 0 then M.page_scroll = 0 end
    -- And it follows the cursor, since walking with a pad or the arrows is how
    -- this is read without a pointer: a row lit under the fold is a row nobody
    -- can see themselves setting. On the frame the cursor moved and no other,
    -- which is what keeps a finger dragging it from being hauled back.
    if M.col_sel == "menu_row" and page_followed ~= M.col_sel_value then
        page_followed = M.col_sel_value
        local at = (M.col_sel_value - 1) * rh
        if at < M.page_scroll then
            M.page_scroll = at
        elseif at + rh > M.page_scroll + view_h then
            M.page_scroll = at + rh - view_h
        end
        M.page_scroll = math.max(0, math.min(M.page_scroll, max_scroll))
    elseif M.col_sel ~= "menu_row" then
        page_followed = nil
    end
    -- Nothing draws outside the panel. A row's own name and answer are the
    -- one thing here whose length this file does not choose, and at a
    -- landscape phone's 240 points a long one ran off the panel and over the
    -- fight beside it. Cut at the panel's edge, which is what a stop already
    -- does with a long game name.
    local kept_clip = F.clip_r
    local edge = math.min(kept_clip or math.huge, kx + kw - pad)
    local y = top - M.page_scroll
    for i, r in ipairs(v.rows) do
        if y + rh > top and y < top + view_h then
            local hot = M.col_sel == "menu_row" and M.col_sel_value == i
            LIT.state(kx, y, kw, rh, hot, r.mark)
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
