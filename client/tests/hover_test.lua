-- The card that names a row of the corner stack.
--
--     lua5.1 client/tests/hover_test.lua
--
-- The stack is marks and counts, which says nothing to a pilot who has not
-- learned the marks. Resting a pointer on a row is how they ask, so what the
-- card says has to be true of the row under it: the name it answers to, the
-- kit the greens put on it, and the key that spends it *now* rather than the
-- key it shipped on.
--
-- Every assertion here reads text the interface actually drew, found through
-- the rectangles it publishes for its own rows, so nothing in this file works
-- the corner's arithmetic out a second time.

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

local layer = {n = 0}
local function noop(self) self.n = self.n + 1 end
for _, name in ipairs({"arc", "disc", "flush", "frame", "outline", "quad",
                       "reset", "ring", "ring_fade", "seg", "seg_fade",
                       "seg_flat", "skirt", "tri", "tri_fade", "halo",
                       "fan", "rect", "glow_band", "seg_glow"}) do
    layer[name] = noop
end

-- What the hull is carrying, which the stack reads through the sim and the
-- card reads through marks.lua. One table so a test cannot set one and assert
-- the other.
local kit = {level = {[0] = 0, [1] = 0}, mods = {}, multi_off = false}

_G.sim = setmetatable({
    ship_count = function() return 1 end,
    ship_x = function() return 400 end,
    ship_y = function() return 400 end,
    ship_alive = function() return 1 end,
    ship_bounty = function() return 37 end,
    ship_charge = function() return 2 end,
    charge_max = function() return 3 end,
    has_trigger = function() return true end,
    ship_level = function(_, t) return kit.level[t] or 0 end,
    ship_mod = function(_, t, i)
        return (kit.mods[t] and kit.mods[t][i]) or 0
    end,
    ship_multi_off = function() return kit.multi_off end,
    flag_count = function() return 0 end,
    flag_at = function() return 0, 0, 255 end,
    map_coarse = function() return nil end,
    prize_count = function() return 0 end,
    weapon_count = function() return 0 end,
    tick = function() return 1000 end,
    TRIG_GUN = 0, TRIG_BOMB = 1, TRIG_COUNT = 2, MOD_COUNT = 6,
    MOD_MULTI = 0,
    MAX_CHARGES = 4, BTN_FIRE = 1,
}, {__index = function() return function() return 0 end end})

local state = {text = {}, n = 0, version = 0}
package.loaded["arena.state"] = state
package.loaded["arena.world"] = {
    build_overview = function() end,
    forget_overview = function() end,
    overview = {grid = 0, n = 0, rect = {}},
    radar_tiles = {}, radar_safe = {}, radar_doors = {},
}

local ui = require("arena.ui")
local binds = require("arena.binds")

local W, H = 1280, 720
local CHARGES = {
    {name = "repel", short = "RPL", count = 2, max = 3},
    {name = "burst", short = "BST", count = 1, max = 3},
}

local function frame(hover_x, hover_y, touching)
    state.n = 0
    ui.hover_x, ui.hover_y = hover_x, hover_y
    -- `begin` owns M.touching, so a test that set it directly would have it
    -- overwritten here and would be asserting about a desktop either way.
    ui.begin(layer, W, H, 1, touching or false)
    ui.hud({
        me = 0,
        class_names = {"Apex", "Wedge", "Chord", "Anvil", "Facet", "Cipher",
                       "Lattice"},
        menu_open = false,
        pilots = {[0] = {name = "you", label = "human"}},
        teams = {}, feed = {}, hurt = 0,
        charges = CHARGES, pad_top = nil,
        cam_x = 400, cam_y = 400, half_w = W / 2, half_h = H / 2,
        banner = "", lag = 4,
        stats = {lag = 4, lead = 2, err = 1, err_max = 2, rewind = 1,
                 snaps = 10, rx = 0, tx = 0},
        zone = "alpha", fps = 60, frame_ms = 16,
        rx_rate = 0, tx_rate = 0,
    })
    ui.finish()
end

-- The middle of a published row, found by asking the interface where it put
-- it rather than by working the stack's layout out here.
local function point_on(key)
    frame(nil, nil)
    local x0, y0, x1, y1
    for px = 0, 360, 2 do
        for py = H - 360, H, 2 do
            if ui.row_at(px, py) == key then
                x0 = math.min(x0 or px, px)
                x1 = math.max(x1 or px, px)
                y0 = math.min(y0 or py, py)
                y1 = math.max(y1 or py, py)
            end
        end
    end
    if not x0 then return nil end
    return (x0 + x1) / 2, (y0 + y1) / 2
end

-- Every line of text drawn this frame, lowercased, so an assertion can ask
-- what the card said without caring how the interface set it.
local function said()
    local out = {}
    for i = 1, state.n do
        out[#out + 1] = string.lower(state.text[i].s or "")
    end
    return out
end

local function shows(word)
    for _, s in ipairs(said()) do
        if string.find(s, word, 1, true) then return true end
    end
    return false
end

-- Everything drawn, run together. A sentence broken to the card's width is
-- still one sentence, and this is how to ask whether it is all there.
local function all_said()
    return table.concat(said(), " ")
end

-- --- a row names itself ----------------------------------------------------

for _, row in ipairs({{"gun", "guns"}, {"bomb", "bombs"},
                      {"charge:repel", "repel"}, {"charge:burst", "burst"}}) do
    local key, word = row[1], row[2]
    local px, py = point_on(key)
    check(key .. " publishes a row", px ~= nil)
    if px then
        frame(px, py)
        check(key .. " names itself when the pointer rests on it", shows(word))
    end
end

-- --- and says which key spends it ------------------------------------------

do
    local want = {}
    for _, r in ipairs(binds.rows()) do want[r.id] = string.lower(r.show) end
    for _, row in ipairs({{"gun", "guns"}, {"bomb", "bombs"},
                          {"charge:repel", "charge_1"},
                          {"charge:burst", "charge_2"}}) do
        local px, py = point_on(row[1])
        if px then
            frame(px, py)
            check(row[1] .. " says its key", shows(want[row[2]]),
                  "wanted " .. tostring(want[row[2]]))
        end
    end
end

-- A key a pilot moved is the key the card says. The whole reason it is read
-- from binds rather than from the controls list it started in.
do
    binds.set("charge_1", {"z"})
    local px, py = point_on("charge:repel")
    frame(px, py)
    check("a rebound charge says the key it moved to", shows("z"))
    binds.reset()
end

-- --- the kit the greens put on a trigger -----------------------------------

do
    kit.level = {[0] = 2, [1] = 0}
    kit.mods = {[0] = {[1] = 1, [3] = 2}}   -- bounce, and two of shrapnel
    local px, py = point_on("gun")
    frame(px, py)
    check("a rung above the first is named", shows("level 3"))
    check("an add-on is named", shows("bounce"))
    check("and a doubled one is counted", shows("shrapnel x2"))

    -- Jargon is spelled out. The card is the one place explaining rather than
    -- reporting, and a mark reading "prox" teaches nobody what the round does,
    -- which is the whole reason the card exists.
    kit.mods = {[0] = {[2] = 1}}
    frame(point_on("gun"))
    check("jargon gets its long form", shows("proximity detonation"))

    -- Spray folded is spray the next shot will not do, so the card says so
    -- rather than listing it flat.
    kit.mods = {[0] = {[0] = 1}}
    kit.multi_off = true
    frame(point_on("gun"))
    check("spray switched off says so", shows("spray (off)"))
    kit.multi_off = false
    kit.level = {[0] = 0, [1] = 0}
    kit.mods = {}
end

-- A fresh hull has no upgrades, and the card says nothing rather than
-- inventing a line: every hull flies on the bottom rung.
do
    local px, py = point_on("gun")
    frame(px, py)
    check("a bare trigger claims no level", not shows("level"))
end

-- --- the bounty is not in the corner ---------------------------------------

do
    -- It was a row here: a diamond, the number, and the run beside it. The
    -- corner is what your triggers do and what you carry, and a bounty is
    -- neither; it is what other people see when they look at you, and it is
    -- said over every nameplate and in the scoreboard's own column. A row
    -- that is not drawn publishes nothing to rest a pointer on.
    check("the corner has no bounty row to point at",
          point_on("bounty") == nil, "still publishing one")
    local px, py = point_on("gun")
    frame(px, py)
    check("and no card in the corner talks about one",
          not shows("bounty"), all_said())
end

-- --- and nothing at all otherwise ------------------------------------------

do
    -- The corner is unchanged for everybody flying, which is most of the
    -- reason this is a hover and not a label.
    --
    -- Probed with an add-on's long form, because that phrase belongs to the
    -- card and to nothing else on the screen. A row's own name will not do
    -- it: the table under H names every key including the guns, so "guns"
    -- reads as a card being up when the table is what is up.
    kit.mods = {[0] = {[2] = 1}}
    local px, py = point_on("gun")
    frame(px, py)
    check("a pointer on a row draws the card", shows("proximity detonation"))

    frame(nil, nil)
    check("no pointer draws no card", not shows("proximity detonation"))

    frame(px, 40)
    check("a pointer off the stack draws no card",
          not shows("proximity detonation"))

    frame(px, py, true)
    check("a thumb gets no card", not shows("proximity detonation"))

    ui.help = true
    frame(px, py)
    check("nor does the table that covers the corner",
          not shows("proximity detonation"))
    ui.help = false
    kit.mods = {}
end

if fails > 0 then
    print(fails .. " failed")
    os.exit(1)
end
print("all hover checks passed")
