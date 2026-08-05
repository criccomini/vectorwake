-- The help overlay: what it says, and where it puts it.
--
--     lua5.1 client/tests/help_test.lua
--
-- Hold H and the screen names its own parts. It does that without a single
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
for _, name in ipairs({"disc", "flush", "frame", "outline", "quad",
                       "reset", "ring", "seg", "seg_fade", "skirt", "tri",
                       "tri_fade"}) do
    layer[name] = noop
end
-- Rectangles are kept rather than counted: a bar as tall as the instrument it
-- names is a rectangle, and its height is the thing under test.
function layer:rect(x, y, w, h, col)
    self.n = self.n + 1
    self.rects[#self.rects + 1] = {x = x, y = y, w = w, h = h, col = col}
end

-- Two add-ons on the gun, because the overlay's column has to clear the widest
-- row the stack can draw and a hull holding nothing would never test that.
local mods = {[0] = 1, [1] = 0, [2] = 1, [3] = 0, [4] = 0, [5] = 0}
local sim = {
    ship_count = function() return 2 end,
    ship_x = function(i) return 100 + i * 180 end,
    ship_y = function(i) return 100 + i * 120 end,
    ship_heading = function() return 0 end,
    ship_alive = function() return 1 end,
    ship_team = function(i) return i end,
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
    ui.help = o.help or false
    ui.map = o.map or false
    layer.rects = {}
    ui.begin(layer, W, H, 1, o.touching or false)
    ui.hud({
        point_x = o.point_x, point_y = o.point_y,
        me = 0,
        class_names = {"Apex", "Wedge", "Chord", "Anvil", "Facet", "Cipher",
                       "Lattice", "Spire"},
        menu_open = o.menu_open or false,
        pilots = {[0] = {name = "you", label = "human"},
                  [1] = {name = "someone", label = "human"}},
        teams = {},
        -- A feed with lines in it, since an empty one draws nothing and has
        -- nothing to be named.
        feed = FEED_LINES,
        hurt = 0,
        charges = o.charges or {{name = "repel", short = "RPL",
                                 max = 3, count = 2}},
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

local function find(lines, s)
    for _, t in ipairs(lines) do
        if t.s == s then return t end
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
        for _, t in ipairs(f) do parts[#parts + 1] = t.s end
        f.joined = table.concat(parts, " ")
    end
    return f.joined:find(s, 1, true) ~= nil
end

-- Where a block's words came out: the top and bottom of the run of lines that
-- carries this sentence, found by walking the drawn text for its first word.
local function block_of(f, s)
    -- Matched by consuming consecutive drawn lines until they rebuild the
    -- sentence exactly. Anything looser mistakes a line of one card for a line
    -- of another, since they share plenty of short words.
    for i = 1, #f do
        if s:find(f[i].s, 1, true) == 1 then
            local acc, j = f[i].s, i
            while acc ~= s and j < #f do
                j = j + 1
                acc = acc .. " " .. f[j].s
                if s:find(acc, 1, true) ~= 1 then break end
            end
            if acc == s then
                -- The block's extent, not its first and last baseline. Two
                -- blocks whose baselines clear each other by less than a line
                -- are still printing through each other.
                local half = LINE_H / 2
                return {top = f[i].y - half, bot = f[j].y + half,
                        mid = (f[i].y + f[j].y) / 2,
                        left = f[i].left, right = f[i].right}
            end
        end
    end
    return nil
end

-- The corner stack says what the card a dead pilot reads says, so the test
-- reads them out of the same table rather than keeping a second copy to fall
-- out of step with it.
local GUN = ui.CARDS.bolt.text
local BOMB = ui.CARDS.bomb.text
local CHG = ui.CARDS.repel.text
local BTY = ui.CARDS.bounty.text
local RADAR = "near space. the rings are range."
local MAP = "the whole arena, and you as the arrow"
local FEED = "who paid whom"

-- Three things this deliberately does not say, each because the instrument
-- already says it. The energy pip empties when you are shot; four bars
-- labelled LINK are a sentence about the connection; and a held overlay does
-- not need to announce that letting go closes it.
local SILENT = {"armour and ammunition, one pool", "your line to the arena",
                "let go and it is gone"}

local ALL = {GUN, BOMB, CHG, BTY, RADAR, FEED}

-- --- it is off until it is held --------------------------------------------

local quiet = frame()
local leaked = nil
for _, s in ipairs(ALL) do
    if says(quiet, s) then leaked = s end
end
check("nothing of it is drawn until H is held", leaked == nil, leaked)

-- --- and then all of it is -------------------------------------------------

local held = frame({help = true})
local spoke = {}
for _, s in ipairs(SILENT) do
    if says(held, s) then spoke[#spoke + 1] = s end
end
check("what the instruments say for themselves is left unsaid", #spoke == 0,
      table.concat(spoke, "; "))

local missing = {}
for _, s in ipairs(ALL) do
    if not says(held, s) then missing[#missing + 1] = s end
end
check("holding H names every instrument", #missing == 0,
      table.concat(missing, "; "))
if #missing > 0 then
    print(#missing .. " absent, so the rest cannot be measured")
    os.exit(1)
end

-- --- pointing at a row answers beside that row ---------------------------
--
-- Held, the stack's sentences are a column: a card's worth of words is taller
-- than the row it belongs to and five of them left on their rows would print
-- through each other. Pointing at one is the case where the promise still
-- holds exactly, because one block has nothing to collide with.

for _, pair in ipairs({{"gun", GUN}, {"bomb", BOMB}, {"bounty", BTY}}) do
    local key, sentence = pair[1], pair[2]
    local px, py = nil, nil
    for y = 0, H - 1, 3 do
        for x = 0, W - 1, 3 do
            if not px and ui.help_at(x, y) == key then px, py = x, y end
        end
    end
    local f = frame({point_x = px, point_y = py})
    local b = block_of(f, sentence)
    check("pointing at " .. key .. " answers beside the " .. key .. " row",
          b and math.abs(b.mid - py) < 40,
          b and ("row " .. py .. ", words at " .. b.mid) or "absent")
end

-- --- and held, the column does not print through itself ------------------
--
-- This is the one that breaks silently. Five wrapped blocks in the space four
-- rows used to occupy will overlap unless they are laid out, and overlapping
-- text is unreadable long before it looks wrong.

do
    local blocks = {}
    for _, sentence in ipairs(ALL) do
        local b = block_of(held, sentence)
        if b then blocks[#blocks + 1] = {b = b, s = sentence} end
    end
    -- Only the stack's own column can collide with itself; the dial and the
    -- feed sit off on the right and are checked below.
    local clash = nil
    for i = 1, #blocks do
        for j = i + 1, #blocks do
            local a, c = blocks[i], blocks[j]
            if a.b.top < c.b.bot and c.b.top < a.b.bot then
                clash = "two blocks share the rows " ..
                        math.floor(a.b.top) .. ".." .. math.floor(a.b.bot) ..
                        " and " .. math.floor(c.b.top) .. ".." ..
                        math.floor(c.b.bot)
            end
        end
    end
    check("the held column lays itself out without overlapping", clash == nil,
          clash)
    check("and it has something in it", #blocks >= 4,
          tostring(#blocks) .. " blocks")
end

-- --- nothing runs off the screen -------------------------------------------
--
-- Every drawn line, not only the ones this test knows the words of: a wrapped
-- sentence is several lines and any one of them can be the one that hangs off
-- the edge.

do
    local off = nil
    for _, t in ipairs(held) do
        if t.left < -1 or t.right > W + 1 or t.y < 0 or t.y > H then
            off = string.format("%q spans %.0f..%.0f at y %.0f", t.s, t.left,
                                t.right, t.y)
        end
    end
    check("every line the overlay draws fits on the screen", off == nil, off)
end

-- --- the dial says which dial it is ----------------------------------------
--
-- M swaps the radar for the whole map in the same corner. The word beside it
-- has to swap too, or it describes range rings that are not there.

local mapped = frame({help = true, map = true})
check("with the map up the dial is described as the map",
      find(mapped, MAP) and not find(mapped, RADAR))
local mapped_clash = nil
for _, s in ipairs({MAP, FEED, GUN, BOMB, CHG, BTY}) do
    if not says(mapped, s) then
        mapped_clash = s .. " went missing with the map up"
    end
end
check("and the rest of it still clears its row with the map up",
      mapped_clash == nil, mapped_clash)

-- --- the menu is a different screen ----------------------------------------

local under_menu = frame({help = true, menu_open = true})
local shown = nil
for _, s in ipairs(ALL) do
    if find(under_menu, s) then shown = s end
end
check("held under the menu it stays down", shown == nil, shown)

-- --- a hull with no charges gets no charge line ----------------------------

local bare = frame({help = true, charges = {}})
check("a hull carrying no charges is not told how to spend them",
      not says(bare, CHG))
check("and the rest of it is still there", says(bare, GUN))

-- --- and the pointer names one thing at a time ----------------------------
--
-- Resting on an instrument is a question about that instrument. It answers
-- with one line, no wash, and none of the other eight, so it costs about what
-- looking at the thing costs.

-- A point inside a given instrument, asked of the interface itself
-- rather than worked out again here.
-- One frame first, so the zones exist to be asked about.
frame()
local function a_point_in(key)
    for y = 0, H - 1, 3 do
        for x = 0, W - 1, 3 do
            if ui.help_at(x, y) == key then return x, y end
        end
    end
    return nil
end

-- Each charge row is its own key now, since a repel and a burst have a card
-- each; the harness gives the hull a repel.
local KEYS = {"gun", "bomb", "charge:repel", "bounty", "radar", "feed"}
local unreachable = {}
for _, k in ipairs(KEYS) do
    if not a_point_in(k) then unreachable[#unreachable + 1] = k end
end
check("every named instrument can be pointed at", #unreachable == 0,
      table.concat(unreachable, "; "))

-- The field of play is not a hover zone by accident: the middle of the screen
-- belongs to flying, and only the pip over your own hull answers there.
check("open space answers nothing", ui.help_at(W * 0.72, H * 0.55) == nil,
      tostring(ui.help_at(W * 0.72, H * 0.55)))

-- Hovering draws that line and stops.
local hx, hy = a_point_in("bounty")
local hovered = frame({point_x = hx, point_y = hy})
check("the pointer on a row draws that row's line", says(hovered, BTY))
local extras = {}
for _, s in ipairs({GUN, BOMB, CHG, RADAR, FEED}) do
    if says(hovered, s) then extras[#extras + 1] = s end
end
check("and none of the others", #extras == 0, table.concat(extras, "; "))

-- Each instrument answers with its own sentence and not its neighbour's.
for _, pair in ipairs({{"gun", GUN}, {"bomb", BOMB}, {"radar", RADAR},
                       {"feed", FEED}}) do
    local key, want = pair[1], pair[2]
    local px, py = a_point_in(key)
    local f = frame({point_x = px, point_y = py})
    check("pointing at " .. key .. " says its own line", says(f, want),
          "absent")
end

-- Held beats hovered. A hand that happens to be resting on the dial must not
-- cut the other eight lines out of a mode the player deliberately opened.
local both = frame({help = true, point_x = hx, point_y = hy})
local lost = {}
for _, s in ipairs(ALL) do
    if not says(both, s) then lost[#lost + 1] = s end
end
check("holding H with the pointer resting still says everything",
      #lost == 0, table.concat(lost, "; "))

-- And the menu is still a different screen.
local hover_menu = frame({menu_open = true, point_x = hx, point_y = hy})
check("hovering under the menu says nothing", not says(hover_menu, BTY))

-- A pointer the client does not have names nothing.
local none = frame()
check("no pointer, no line", not says(none, BTY))

-- --- a bar as tall as the thing it names ----------------------------------
--
-- The dial is a square the size of a phone's screen and the feed is five
-- lines. A mark the height of one line of type beside either of them reads as
-- a note about whatever row it happened to land next to, so the bar runs the
-- instrument's whole height.

do
    local f = frame({help = true})
    local word = find(f, RADAR)
    local bar = bar_at(f, word.right + 11 * 1)
    check("the dial's bar is as tall as the dial",
          bar and bar.h > 100, bar and ("height " .. bar.h) or "no bar")

    local fw = find(f, FEED)
    local fbar = bar_at(f, fw.right + 11 * 1)
    -- Five lines at the interface's own line height, less a little slack.
    check("the feed's bar is as tall as the feed",
          fbar and fbar.h > 4 * 18, fbar and ("height " .. fbar.h) or "no bar")
end

-- --- and the feed is named beside itself, not beneath it -------------------
--
-- Under it the bar could only be a line tall and the sentence would read as a
-- sixth kill.

do
    local f = frame({help = true})
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
