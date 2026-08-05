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

local layer = {n = 0}
local function noop(self) self.n = self.n + 1 end
for _, name in ipairs({"disc", "flush", "frame", "outline", "quad", "rect",
                       "reset", "ring", "seg", "seg_fade", "skirt", "tri",
                       "tri_fade"}) do
    layer[name] = noop
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

local function frame(o)
    o = o or {}
    ui.help = o.help or false
    ui.map = o.map or false
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
        feed = {{text = "someone +9 you", t = 0}},
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
    return out
end

local function find(lines, s)
    for _, t in ipairs(lines) do
        if t.s == s then return t end
    end
    return nil
end

-- Every line sharing a row with this one, itself excluded. Two texts are on a
-- row together when their baselines agree to within a pixel.
local function row_of(lines, t)
    local out = {}
    for _, u in ipairs(lines) do
        if u ~= t and math.abs(u.y - t.y) < 1 then out[#out + 1] = u end
    end
    return out
end

local GUN = "at its rung, and what is bolted on"
local BOMB = "a rung buys blast, not damage"
local CHG = "digits 1 to 4 spend these, top down"
local BTY = "what a kill on you pays"
local RADAR = "near space. the rings are range."
local MAP = "the whole arena, and you as the arrow"
local LINK = "your line to the arena"
local FEED = "who paid whom"
local NRG = "armour and ammunition, one pool"
local LETGO = "let go and it is gone"

local ALL = {GUN, BOMB, CHG, BTY, RADAR, LINK, FEED, NRG, LETGO}

-- --- it is off until it is held --------------------------------------------

local quiet = frame()
local leaked = nil
for _, s in ipairs(ALL) do
    if find(quiet, s) then leaked = s end
end
check("nothing of it is drawn until H is held", leaked == nil, leaked)

-- --- and then all of it is -------------------------------------------------

local held = frame({help = true})
local missing = {}
for _, s in ipairs(ALL) do
    if not find(held, s) then missing[#missing + 1] = s end
end
check("holding H names every instrument", #missing == 0,
      table.concat(missing, "; "))
if #missing > 0 then
    print(#missing .. " absent, so the rest cannot be measured")
    os.exit(1)
end

-- --- each word lands on the row it is about --------------------------------
--
-- The row labels are what the player reads it against, so the test reads it
-- against them too.

for _, pair in ipairs({{"GUN", GUN}, {"BOMB", BOMB}, {"BOUNTY", BTY}}) do
    local label, sentence = pair[1], pair[2]
    local a, b = find(held, label), find(held, sentence)
    check("the " .. label .. " line sits on the " .. label .. " row",
          a and b and math.abs(a.y - b.y) < 1,
          a and b and ("label y " .. a.y .. " vs word y " .. b.y) or "absent")
end

-- The charge sentence is one line for however many charge rows there are, so
-- it is not on a row: it is between the first and the last of them.
do
    local rpl, chg = find(held, "REPEL"), find(held, CHG)
    check("the charge line sits against the charge rows",
          rpl and chg and math.abs(rpl.y - chg.y) <= 22,
          rpl and chg and ("REPEL y " .. rpl.y .. " vs word y " .. chg.y)
          or "absent")
end

-- --- and clears what is already on that row --------------------------------
--
-- This is the one that breaks silently, and it broke: the column starts past
-- the widest row the corner stack drew, so a hull carrying add-ons pushes it
-- right, and the line about the connection was anchored to the left of `LINK`
-- when `LINK` is the right-hand end of a row that opens with `POS 382,360`.
-- Both faults print a sentence through the readout it is explaining, and
-- neither shows up in a check that only compares the help lines with each
-- other. So every one of them is measured against everything else sharing its
-- row, whichever side of it the instrument sits on.

local overlap = nil
for _, s in ipairs(ALL) do
    local t = find(held, s)
    for _, other in ipairs(row_of(held, t)) do
        if t.left < other.right and other.left < t.right then
            overlap = s .. " over " .. other.s
        end
    end
end
check("no word is printed over anything already on its row",
      overlap == nil, overlap)

-- --- nothing runs off the screen -------------------------------------------

local off = nil
for _, s in ipairs(ALL) do
    local t = find(held, s)
    if t.left < 0 or t.right > W then
        off = s .. " spans " .. math.floor(t.left) .. " to " ..
              math.floor(t.right)
    end
end
check("every word fits on the screen", off == nil, off)

-- --- and no two of them collide --------------------------------------------

local clash = nil
for i = 1, #ALL do
    for j = i + 1, #ALL do
        local a, b = find(held, ALL[i]), find(held, ALL[j])
        if math.abs(a.y - b.y) < 12
           and a.left < b.right and b.left < a.right then
            clash = ALL[i] .. " over " .. ALL[j]
        end
    end
end
check("no two of them land on each other", clash == nil, clash)

-- --- the dial says which dial it is ----------------------------------------
--
-- M swaps the radar for the whole map in the same corner. The word beside it
-- has to swap too, or it describes range rings that are not there.

local mapped = frame({help = true, map = true})
check("with the map up the dial is described as the map",
      find(mapped, MAP) and not find(mapped, RADAR))
-- The map is four times the dial, so the readouts along the top of it start
-- near the middle of the screen and there is no clear space left of them. The
-- line about the connection stands down rather than printing over the flags.
check("and the line with nowhere left to go stands down",
      not find(mapped, LINK))
local mapped_clash = nil
for _, s in ipairs({MAP, FEED, NRG, GUN, BOMB, CHG, BTY, LETGO}) do
    local t = find(mapped, s)
    if not t then
        mapped_clash = s .. " went missing with the map up"
    else
        for _, other in ipairs(row_of(mapped, t)) do
            if t.left < other.right and other.left < t.right then
                mapped_clash = s .. " over " .. other.s
            end
        end
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
      not find(bare, CHG))
check("and the rest of it is still there", find(bare, GUN) ~= nil)

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

local KEYS = {"gun", "bomb", "charges", "bounty", "radar", "link", "feed",
              "energy"}
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
check("the pointer on a row draws that row's line", find(hovered, BTY) ~= nil)
local extras = {}
for _, s in ipairs({GUN, BOMB, CHG, RADAR, LINK, FEED, NRG, LETGO}) do
    if find(hovered, s) then extras[#extras + 1] = s end
end
check("and none of the others", #extras == 0, table.concat(extras, "; "))

-- Each instrument answers with its own sentence and not its neighbour's.
for _, pair in ipairs({{"gun", GUN}, {"bomb", BOMB}, {"radar", RADAR},
                       {"feed", FEED}, {"energy", NRG}}) do
    local key, want = pair[1], pair[2]
    local px, py = a_point_in(key)
    local f = frame({point_x = px, point_y = py})
    check("pointing at " .. key .. " says its own line",
          find(f, want) ~= nil, "absent")
end

-- Held beats hovered. A hand that happens to be resting on the dial must not
-- cut the other eight lines out of a mode the player deliberately opened.
local both = frame({help = true, point_x = hx, point_y = hy})
local lost = {}
for _, s in ipairs(ALL) do
    if not find(both, s) then lost[#lost + 1] = s end
end
check("holding H with the pointer resting still says everything",
      #lost == 0, table.concat(lost, "; "))

-- And the menu is still a different screen.
local hover_menu = frame({menu_open = true, point_x = hx, point_y = hy})
check("hovering under the menu says nothing", find(hover_menu, BTY) == nil)

-- A pointer the client does not have names nothing.
local none = frame()
check("no pointer, no line", find(none, BTY) == nil)

if fails > 0 then
    print(fails .. " failed")
    os.exit(1)
end
print("all good")
