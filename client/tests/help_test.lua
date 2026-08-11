-- The help label: what it says, and where it puts it.
--
--     lua5.1 client/tests/help_test.lua
--
-- Point at an instrument and it names itself. It does that without a single
-- leader line, which is the whole design: a word set beside a thing is read as
-- being about that thing, and the lines drawn to reach eleven captions were
-- what made the first draft of this unreadable.
--
-- That trade only holds while the word really does land beside the thing. A
-- sentence one row off names the wrong instrument, and a sentence that starts
-- left of where the corner stack ends is printed straight through the numbers
-- it is supposed to explain. Neither is visible until somebody is flying, on a
-- build that takes six minutes to publish, so this runs the real `M.hud`
-- against a stubbed engine and measures where the words came out.

package.path = "client/?.lua;" .. package.path

local fails = 0
local function check(name, ok, detail)
    if ok then
        print("ok   " .. name)
    else
        fails = fails + 1
        print("FAIL " .. name .. (detail and ("  -- " .. detail) or ""))
    end
end

-- --- the engine, as much of it as ui.lua touches ---------------------------

local layer = {n = 0, rects = {}}
local function noop(self) self.n = self.n + 1 end
for _, name in ipairs({"arc", "disc", "flush", "frame", "halo", "outline",
                       "quad", "reset", "ring", "seg", "seg_fade",
                       "skirt", "tri", "tri_fade"}) do
    layer[name] = noop
end
-- Rectangles are kept rather than counted: a bar as tall as the instrument it
-- names is a rectangle, and its height is the thing under test.
function layer:rect(x, y, w, h, col)
    self.n = self.n + 1
    self.rects[#self.rects + 1] = {x = x, y = y, w = w, h = h, col = col}
end

-- Two add-ons on the gun, because a sentence has to clear the widest row the
-- stack can draw and a hull holding nothing would never test that.
local mods = {[0] = 1, [1] = 0, [2] = 1, [3] = 0, [4] = 0, [5] = 0}
local sim = {
    ship_count = function() return 2 end,
    ship_x = function(i) return 100 + i * 180 end,
    ship_y = function(i) return 100 + i * 120 end,
    ship_heading = function() return 0 end,
    ship_alive = function() return 1 end,
    ship_team = function(i) return i end,
    -- Nobody is riding anybody unless a test says so.
    ship_carrier = function() return 255 end,
    ship_class = function() return 0 end,
    ship_energy = function() return 100 end,
    ship_max_energy = function() return 100 end,
    ship_kills = function() return 1 end,
    ship_deaths = function() return 1 end,
    ship_points = function() return 10 end,
    ship_bounty = function() return 34 end,
    ship_up = function() return 0 end,
    ship_level = function() return 1 end,
    ship_charge = function() return 2 end,
    ship_mod = function(_, t, m) return (t == 0 and mods[m]) or 0 end,
    ship_multi_off = function() return 0 end,
    charge_max = function() return 3 end,
    has_trigger = function() return true end,
    trigger_rate = function() return 1 end,
    tick = function() return 4242 end,
    weapon_count = function() return 3 end,
    prize_count = function() return 0 end,
    prize_at = function() return 0, 0, 0 end,
    flag_count = function() return 0 end,
    flag_at = function() return 0, 0, 255 end,
    map_coarse = function() return nil end,
    TRIG_GUN = 0,
    BTN_FIRE = 1,
}
_G.sim = sim

local state = {text = {}, n = 0, version = 0}
package.loaded["arena.state"] = state
package.loaded["arena.touch"] = {
    layout = function() return {charge = {}} end,
    used = false,
}
package.loaded["arena.world"] = {
    build_overview = function() end,
    forget_overview = function() end,
    -- A field, not a call: ui.lua reads world.overview directly.
    overview = {grid = 0, n = 0, rect = {}},
    radar_tiles = {160, 160},
    radar_safe = {},
    radar_doors = {},
}

local ui = require("arena.ui")

-- --- the harness -----------------------------------------------------------

local W, H = 1280, 800
local ADVANCE = 1233 / 2048
-- ui.lua's LINE, at the density this harness draws with.
local LINE_H = 18

-- A full feed, because the bar beside it is supposed to be as tall as the
-- block and a single line would let a one-line bar pass for one.
local FEED_LINES = {}
for i = 1, 5 do
    FEED_LINES[i] = {text = "someone killed nobody (+" .. (20 + i) .. ")",
                     t = 0}
end

local function frame(o)
    o = o or {}
    ui.map = o.map or false
    layer.rects = {}
    ui.begin(layer, W, H, 1, o.touching or false)
    ui.hud({
        point_x = o.point_x, point_y = o.point_y,
        me = 0,
        class_names = {"Apex", "Wedge", "Chord", "Anvil", "Facet", "Cipher",
                       "Lattice"},
        menu_open = o.menu_open or false,
        pilots = {[0] = {name = "you", label = "human"},
                  [1] = {name = "someone", label = "human"}},
        teams = {},
        -- A feed with lines in it, since an empty one draws nothing and has
        -- nothing to be named.
        feed = FEED_LINES,
        hurt = 0,
        charges = o.charges or {{name = "repel", short = "RPL",
                                 max = 3, count = 2},
                                {name = "burst", short = "BST",
                                 max = 3, count = 1}},
        cam_x = sim.ship_x(0), cam_y = sim.ship_y(0),
        half_w = 640, half_h = 400,
        banner = "",
        lag = 4,
        stats = {lag = 4, lead = 2, err = 1.5, err_max = 9.0, rewind = 3,
                 snaps = 120, rx = 0, tx = 0},
        zone = "chaos",
        fps = 60, frame_ms = 16.7, rx_rate = 31000, tx_rate = 700,
    })
    ui.finish()
    -- Back into the coordinates ui.lua lays out in: origin top left, y down.
    local out = {}
    for i = 1, state.n do
        local t = state.text[i]
        local w = #t.s * t.px * ADVANCE
        local left = t.x
        if t.pivot == "right" then left = t.x - w
        elseif t.pivot == "center" then left = t.x - w / 2 end
        out[#out + 1] = {s = t.s, y = H - t.y, px = t.px,
                         left = left, right = left + w}
    end
    out.rects = layer.rects
    return out
end

-- The tallest thin upright rectangle whose right edge sits at `x`, which is
-- how a bar drawn beside a right-aligned line is found. Widths here are the
-- bar's 3 points, never a panel's.
local function bar_at(f, x, tol)
    local best = nil
    for _, r in ipairs(f.rects) do
        if r.w < 6 and math.abs((r.x + r.w) - x) <= (tol or 3)
           and (not best or r.h > best.h) then
            best = r
        end
    end
    return best
end

-- Case is typography, not content: the interface sets every word it says in
-- capitals, and what these checks are about is which words it says.
local function same(a, b) return string.upper(a) == string.upper(b) end

local function find(lines, s)
    for _, t in ipairs(lines) do
        if same(t.s, s) then return t end
    end
    return nil
end

-- A card's sentence is wrapped across several drawn lines, and the lines of
-- one block are drawn one after another, so the frame's text joined in order
-- contains the sentence whole. Anything shorter than the wrap is found by
-- `find` as before.
local function says(f, s)
    if not f.joined then
        local parts = {}
        for _, t in ipairs(f) do parts[#parts + 1] = string.upper(t.s) end
        f.joined = table.concat(parts, " ")
    end
    return f.joined:find(string.upper(s), 1, true) ~= nil
end

-- Where a block's words came out: the top and bottom of the run of lines that
-- carries this sentence, found by walking the drawn text for its first word.
local function block_of(f, sentence)
    -- Matched by consuming consecutive drawn lines until they cover the
    -- sentence. Anything looser mistakes a line of one card for a line of
    -- another, since they share plenty of short words. Compared in one case,
    -- since the interface sets what it says in capitals and what is being
    -- matched here is the words.
    --
    -- Covering rather than rebuilding exactly, because a row can say more than
    -- the card does: the gun row appends what it is carrying, and the line
    -- where the wrap crosses out of the card carries words from both. The
    -- question this answers is where the block that holds this sentence
    -- landed, which does not need the block to end with it.
    local s = string.upper(sentence)
    for i = 1, #f do
        local first = string.upper(f[i].s)
        if s:find(first, 1, true) == 1 then
            local acc, j = first, i
            while #acc < #s and j < #f do
                j = j + 1
                acc = acc .. " " .. string.upper(f[j].s)
            end
            if acc:sub(1, #s) == s then
                -- The block's extent, not its first and last baseline.
                local half = LINE_H / 2
                return {top = f[i].y - half, bot = f[j].y + half,
                        mid = (f[i].y + f[j].y) / 2,
                        left = f[i].left, right = f[i].right}
            end
        end
    end
    return nil
end

-- The corner stack says what the glossary says, so the test reads the
-- sentences out of the same place rather than keeping a second copy to fall
-- out of step with it. `card_text` and not `CARDS[k].text`, because a card
-- whose thing has a key says the key too and what lands on screen is both.
local GUN = ui.card_text("bolt")
local BOMB = ui.card_text("bomb")
local CHG = ui.card_text("repel")
local BST = ui.card_text("burst")
local BTY = ui.card_text("bounty")
local RADAR = "near space. the rings are range."
local MAP = "the whole arena, and you as the arrow"
local FEED = "who paid whom"

-- Two things this deliberately does not say, each because the instrument
-- already says it. The energy pip empties when you are shot, and four bars
-- labeled LINK are a sentence about the connection.
local SILENT = {"armour and ammunition, one pool", "your line to the arena"}

local ALL = {GUN, BOMB, CHG, BST, BTY, RADAR, FEED}

-- --- nothing until something is pointed at ---------------------------------

local quiet = frame()
local leaked = nil
for _, s in ipairs(ALL) do
    if says(quiet, s) then leaked = s end
end
check("nothing of it is drawn while the pointer is nowhere", leaked == nil,
      leaked)

-- --- what can be pointed at ------------------------------------------------
--
-- The rows wear glyphs rather than words, so the drawn text cannot say where a
-- row is. The hover zones can: they are the row rectangles the interface
-- itself publishes, and they are also what a pointer resting there names, so
-- the test and the player are asking the same question.

-- A point inside a given instrument, asked of the interface itself rather than
-- worked out again here. Reads the zones the last frame filed, so a frame has
-- to have been drawn first.
local function a_point_in(key)
    for y = 0, H - 1, 3 do
        for x = 0, W - 1, 3 do
            if ui.help_at(x, y) == key then return x, y end
        end
    end
    return nil
end

-- The run of rows one key owns, down the stack's left column.
local function zone_band(key)
    local x = 20
    local top, bot = nil, nil
    for yy = 0, H, 2 do
        if ui.help_at(x, yy) == key then
            top = top or yy
            bot = yy
        end
    end
    return top, bot
end

-- Each charge row is its own key, since a repel and a burst have a card each.
local KEYS = {"gun", "bomb", "charge:repel", "charge:burst", "bounty",
              "radar", "feed"}
local unreachable = {}
for _, k in ipairs(KEYS) do
    if not a_point_in(k) then unreachable[#unreachable + 1] = k end
end
check("every named instrument can be pointed at", #unreachable == 0,
      table.concat(unreachable, "; "))
if #unreachable > 0 then
    print("nothing to point at, so the rest cannot be measured")
    os.exit(1)
end

-- The field of play is not a hover zone by accident: the middle of the screen
-- belongs to flying, and only the pip over your own hull answers there.
check("open space answers nothing", ui.help_at(W * 0.72, H * 0.55) == nil,
      tostring(ui.help_at(W * 0.72, H * 0.55)))

-- --- pointing at a row answers beside that row ----------------------------
--
-- The whole promise, and the one that breaks silently. A card's worth of words
-- is taller than the row it belongs to, so the block is centered on the row and
-- pushed back on screen at the edges, and either of those can drift far enough
-- to name the row above instead.

for _, pair in ipairs({{"gun", GUN}, {"bomb", BOMB}, {"bounty", BTY}}) do
    local key, sentence = pair[1], pair[2]
    local top, bot = zone_band(key)
    local mid = top and (top + bot) / 2
    local f = frame({point_x = 20, point_y = mid})
    local b = block_of(f, sentence)
    check("pointing at " .. key .. " answers beside the " .. key .. " row",
          b and mid and math.abs(b.mid - mid) < 40,
          b and mid and ("row " .. mid .. ", words at " .. b.mid) or "absent")
end

-- --- one thing at a time ---------------------------------------------------
--
-- Resting on an instrument is a question about that instrument. It answers
-- with one line and none of the other six, so it costs about what looking at
-- the thing costs.

local hx, hy = a_point_in("bounty")
local hovered = frame({point_x = hx, point_y = hy})
check("the pointer on a row draws that row's line", says(hovered, BTY))
local extras = {}
for _, s in ipairs({GUN, BOMB, CHG, BST, RADAR, FEED}) do
    if says(hovered, s) then extras[#extras + 1] = s end
end
check("and none of the others", #extras == 0, table.concat(extras, "; "))

local spoke = {}
for _, s in ipairs(SILENT) do
    for _, k in ipairs(KEYS) do
        local px, py = a_point_in(k)
        if says(frame({point_x = px, point_y = py}), s) then
            spoke[#spoke + 1] = s
        end
    end
end
check("what the instruments say for themselves is left unsaid", #spoke == 0,
      table.concat(spoke, "; "))

-- Each instrument answers with its own sentence and not its neighbour's.
for _, pair in ipairs({{"gun", GUN}, {"bomb", BOMB}, {"radar", RADAR},
                       {"feed", FEED}, {"charge:repel", CHG},
                       {"charge:burst", BST}}) do
    local key, want = pair[1], pair[2]
    local px, py = a_point_in(key)
    local f = frame({point_x = px, point_y = py})
    check("pointing at " .. key .. " says its own line", says(f, want),
          "absent")
end

-- --- a charge is named for what it is, not for the digit that spends it ---
--
-- A repel and a burst do different things and each has a card of its own.
-- They shared one sentence only while that sentence was about which digit
-- spends them, which is a fact about the keyboard rather than about either.

do
    local rx, ry_ = a_point_in("charge:repel")
    local bx, by = a_point_in("charge:burst")
    check("the two charge rows are pointed at separately", ry_ ~= by,
          tostring(ry_) .. " and " .. tostring(by))
    local fr = frame({point_x = rx, point_y = ry_})
    local fb = frame({point_x = bx, point_y = by})
    check("the repel row says what a repel is",
          says(fr, CHG) and not says(fr, BST))
    check("the burst row says what a burst is",
          says(fb, BST) and not says(fb, CHG))
end

-- --- and it says which key works it ----------------------------------------
--
-- The sentence says what a thing is; on its own that leaves a pilot knowing
-- there is a repel aboard and no way to spend it. This reverses an earlier
-- call that kept the key out on the grounds that it is a fact about the
-- keyboard rather than about the repel. Both are true and only one of them
-- gets somebody out of a corner.
--
-- What it must not do is name a key on a device that has none, which is the
-- reason that call was made in the first place.

do
    for _, pair in ipairs({{"gun", "Space"}, {"bomb", "Tab"},
                           {"charge:repel", "Q"}, {"charge:burst", "W"}}) do
        local key, word = pair[1], pair[2]
        local px, py = a_point_in(key)
        check(key .. " names the key that works it",
              says(frame({point_x = px, point_y = py}), word), word)
    end

    -- And on glass it names none of them, because there is nothing there to
    -- point at: a touchscreen wears its weapons on the pads and the corner
    -- stack stands down rather than drawing them twice. That is the whole
    -- reason a card carries `pad` beside `key` instead of one sentence with a
    -- key in it. The guide is what reaches a phone, and guide_test covers it.
    frame({touching = true})
    local absent = {}
    for _, k in ipairs({"gun", "bomb", "charge:repel", "charge:burst",
                        "bounty"}) do
        if a_point_in(k) then absent[#absent + 1] = k end
    end
    check("a touchscreen has no corner stack to point at", #absent == 0,
          table.concat(absent, "; "))
end

-- --- nothing runs off the screen -------------------------------------------
--
-- Every drawn line, not only the ones this test knows the words of: a wrapped
-- sentence is several lines and any one of them can be the one that hangs off
-- the edge. The bounty row is the case that needs the clamp, since it is the
-- last row of a stack standing on the bottom of the screen.

do
    local off = nil
    for _, k in ipairs(KEYS) do
        local px, py = a_point_in(k)
        for _, t in ipairs(frame({point_x = px, point_y = py})) do
            if t.left < -1 or t.right > W + 1 or t.y < 0 or t.y > H then
                off = string.format("%s: %q spans %.0f..%.0f at y %.0f", k,
                                    t.s, t.left, t.right, t.y)
            end
        end
    end
    check("every line it draws fits on the screen", off == nil, off)
end

-- --- the dial says which dial it is ----------------------------------------
--
-- M swaps the radar for the whole map in the same corner. The word beside it
-- has to swap too, or it describes range rings that are not there.

do
    frame({map = true})
    local px, py = a_point_in("radar")
    local mapped = frame({map = true, point_x = px, point_y = py})
    check("with the map up the dial is described as the map",
          find(mapped, MAP) and not find(mapped, RADAR))
end

-- --- the menu is a different screen ----------------------------------------
--
-- It has a help page of its own, and two things explaining the interface at
-- once is neither.

frame()
local hover_menu = frame({menu_open = true, point_x = hx, point_y = hy})
check("hovering under the menu says nothing", not says(hover_menu, BTY))

-- --- a hull with no charges gets no charge row -----------------------------

do
    frame({charges = {}})
    check("a hull carrying no charges has no charge row to point at",
          a_point_in("charge:repel") == nil)
    local gx, gy = a_point_in("gun")
    check("and the rest of the stack is still there",
          gx ~= nil and says(frame({charges = {}, point_x = gx, point_y = gy}),
                             GUN))
end

-- --- a bar as tall as the thing it names ----------------------------------
--
-- The dial is a square the size of a phone's screen and the feed is five
-- lines. A mark the height of one line of type beside either of them reads as
-- a note about whatever row it happened to land next to, so the bar runs the
-- instrument's whole height.

do
    frame()
    local px, py = a_point_in("radar")
    local f = frame({point_x = px, point_y = py})
    local word = find(f, RADAR)
    local bar = bar_at(f, word.right + 11 * 1)
    check("the dial's bar is as tall as the dial",
          bar and bar.h > 100, bar and ("height " .. bar.h) or "no bar")

    local fx, fy = a_point_in("feed")
    local ff = frame({point_x = fx, point_y = fy})
    local fw = find(ff, FEED)
    local fbar = bar_at(ff, fw.right + 11 * 1)
    -- Five lines at the interface's own line height, less a little slack.
    check("the feed's bar is as tall as the feed",
          fbar and fbar.h > 4 * 18, fbar and ("height " .. fbar.h) or "no bar")
end

-- --- and the feed is named beside itself, not beneath it -------------------
--
-- Under it the bar could only be a line tall and the sentence would read as a
-- sixth kill.

do
    frame()
    local fx, fy = a_point_in("feed")
    local f = frame({point_x = fx, point_y = fy})
    local word = find(f, FEED)
    local lowest, highest = 0, math.huge
    for _, line in ipairs(FEED_LINES) do
        local t = find(f, line.text)
        if t then
            if t.y > lowest then lowest = t.y end
            if t.y < highest then highest = t.y end
        end
    end
    check("the feed's line sits level with the feed, not under it",
          word.y >= highest - 12 and word.y <= lowest + 12,
          string.format("word %.0f, feed %.0f..%.0f", word.y, highest, lowest))
    local feed_left = math.huge
    for _, line in ipairs(FEED_LINES) do
        local t = find(f, line.text)
        if t and t.left < feed_left then feed_left = t.left end
    end
    check("and to the left of it", word.right <= feed_left,
          string.format("word ends %.0f, feed starts %.0f", word.right,
                        feed_left))
end

if fails > 0 then
    print(fails .. " failed")
    os.exit(1)
end
print("all good")
