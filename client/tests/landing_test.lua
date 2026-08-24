-- The landing: where a press would put you, and what it takes to say so.
--
--     lua5.1 client/tests/landing_test.lua
--
-- Every window draws the same one: the deck, which is the game's name on a
-- carousel, what that game is, the room a press would drop you in, the ship
-- you would arrive in, and one DEPLOY key under all of it. A monitor holds
-- it to a phone's column, because at the width of a stage the clock sits at
-- one edge of the screen and the score at the other. A tall window keeps
-- the key with the readings instead of sinking it to the bottom of the
-- glass. Desktop drew the zones list with those readings in a column beside
-- it before this.

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

local W, H = 1280, 800
local boxes = {}
local layer = {}
local function noop() end
for _, name in ipairs({"arc", "disc", "flush", "outline", "quad", "reset",
                        "ring", "tri", "tri_fade", "fan", "seg", "seg_glow",
                        "glow_band", "halo", "ring_fade", "seg_fade",
                        "seg_flat", "skirt", "rect"}) do
    layer[name] = noop
end
layer.frame = function(_, x, y, w, h)
    boxes[#boxes + 1] = {x = x, y = y, w = w, h = h}
end

_G.sim = setmetatable({}, {__index = function()
    return function() return 0 end
end})
package.loaded["arena.state"] = {text = {}, n = 0, version = 0}
package.loaded["arena.touch"] = {
    layout = function() return {charge = {}} end,
    used = false,
}
package.loaded["arena.world"] = {
    build_overview = noop,
    forget_overview = noop,
    overview = {grid = 0},
    radar_tiles = {},
    radar_safe = {},
    radar_doors = {},
    HULLS = {{
        poly = {0, 20, 8, -8, 0, -12, -8, -8},
        mid = 4,
    }},
}

local ui = require("arena.ui")
local state = package.loaded["arena.state"]
local pal = require("arena.palette")

local function view(finding_rival)
    return {
        home = true,
        closable = false,
        focus = "stage",
        rail = {
            {label = "play"},
            {label = "ship"},
            {label = "settings"},
        },
        rail_sel = 1,
        at = "play",
        sel = 1,
        rows = {{sect = "zones", label = "Melee",
                 note = "Four a side, three minutes",
                 players = 4, bots = 4, live = true,
                 act = "join", value = 1, index = 1, pick = true}},
        aside = {
            deploy = true,
            label = "Melee",
            note = "Four a side, three minutes",
            zones = 3,
            at = 1,
            room = {players = 4, bots = 4, seats = 8},
            clock = 160,
            playing = not finding_rival,
            finding_rival = finding_rival,
            score = finding_rival and nil or {1, 1},
            row = 1,
            arrive = {hull = 0, name = "Apex", call = "you"},
        },
        -- The live arena keeps the fight visible in the glass beside the
        -- summary. Its roster does not replace the summary on desktop.
        arena = {
            pilots = {{name = "Halcyon"}},
            watchers = {},
            side = 0,
            score = {[0] = 1, [1] = 1},
        },
        pilot = {name = "you", rivets = 0},
    }
end

local function draw(w, h, finding_rival)
    W, H = w, h
    boxes = {}
    state.n = 0
    ui.begin(layer, W, H, 1, false)
    ui.menu(view(finding_rival))
    ui.finish()
    local out = {}
    for i = 1, state.n do
        out[#out + 1] = state.text[i]
    end
    return out, ui.hits or ui.boxes
end

local function has(texts, phrase)
    phrase = string.lower(phrase)
    for _, t in ipairs(texts) do
        if string.find(string.lower(t.s or ""), phrase, 1, true) then
            return true
        end
    end
    return false
end

local function find_text(texts, phrase)
    phrase = string.lower(phrase)
    for _, t in ipairs(texts) do
        if string.find(string.lower(t.s or ""), phrase, 1, true) then
            return t
        end
    end
    return nil
end

-- What both layouts must say about the room, wherever they lay it out.
local function readings_checks(name, texts)
    check(name .. " names the game", has(texts, "Melee"))
    check(name .. " says what the game is",
          has(texts, "Four a side, three minutes"))
    check(name .. " carries the live clock and score",
          has(texts, "On the clock") and has(texts, "2:40")
              and has(texts, "The score") and has(texts, " : "))
    local blue, orange = false, false
    for _, t in ipairs(texts) do
        if t.s == "1" then
            local col = t.col or {}
            if col[1] == pal.FRIEND[1] and col[2] == pal.FRIEND[2] then
                blue = true
            end
            if col[1] == pal.ENEMY[1] and col[2] == pal.ENEMY[2] then
                orange = true
            end
        end
    end
    check(name .. " colors the two scores by side", blue and orange)
    check(name .. " carries the room",
          has(texts, "The room") and has(texts, "8 seats"))
end

-- --- desktop: the deck, in a column of a phone's measure ------------------

local desktop, hits = draw(1280, 800)
readings_checks("desktop", desktop)
check("desktop says which ship arrives",
      has(desktop, "You arrive as") and has(desktop, "Apex"))
check("desktop ends in one Deploy key", has(desktop, "Deploy"))
local key_hit
for _, hit in ipairs(hits or {}) do
    if hit.action == "stage" and hit.value == 1 then key_hit = hit end
end
check("the key presses the zone the carousel is on", key_hit ~= nil,
      "no stage target on the key")
check("desktop does not replace the summary with a roster",
      not has(desktop, "Halcyon"), "roster name was drawn")
check("the deck keeps a phone's measure on a monitor",
      key_hit and key_hit.w < W * 0.45,
      key_hit and string.format("key %.0f wide in %d", key_hit.w, W)
          or "no key")
-- One column: the readings hang under the name of the game rather than
-- standing in a second column beside it.
local melee = find_text(desktop, "Melee")
local clock = find_text(desktop, "On the clock")
check("the readings sit under the name, not beside it",
      melee and clock and math.abs(melee.x - clock.x) < 40,
      string.format("melee %.0f, clock %.0f",
                    melee and melee.x or -1, clock and clock.x or -1))

-- A window taller than a phone keeps the key with the readings. Given the
-- whole of one the three bands sink to the foot of the window, which leaves
-- the name of the game a screen away from the facts about it.
local _, tall_hits = draw(1280, 1500)
local tall_key
for _, hit in ipairs(tall_hits or {}) do
    if hit.action == "stage" then tall_key = hit end
end
check("a tall window does not sink the key to the bottom of the glass",
      tall_key and tall_key.y + tall_key.h < H * 0.72,
      tall_key and string.format("key foot at %.0f of %d",
                                 tall_key.y + tall_key.h, H) or "no key")

-- --- phone: the same deck, given the whole page ----------------------------

local phone, phits = draw(420, 780)
readings_checks("phone", phone)
check("phone says which ship arrives",
      has(phone, "You arrive as") and has(phone, "Apex"))
check("phone ends in one Deploy key", has(phone, "Deploy"))
local stage, ship_page, pilot_page = 0, 0, 0
for _, hit in ipairs(phits or {}) do
    if hit.action == "stage" then stage = stage + 1 end
    if hit.action == "ship_page" then ship_page = ship_page + 1 end
    if hit.action == "pilot_page" then pilot_page = pilot_page + 1 end
end
check("phone publishes one Deploy target", stage == 1,
      stage .. " stage targets")
check("phone makes the ship name a destination", ship_page == 1,
      ship_page .. " ship targets")
-- One target is the account button in the header. The second is the
-- account name beside Deploy.
check("phone makes the account name a destination", pilot_page == 2,
      pilot_page .. " account targets")

for _, shape in ipairs({{1280, 800}, {420, 780}}) do
    local texts = draw(shape[1], shape[2], true)
    local name = shape[1] > 500 and "desktop" or "phone"
    check(name .. " Ladder landing says it is finding a rival",
          has(texts, "Finding rival") and has(texts, "--:--")
              and not has(texts, "Next match in"))
end

if fails > 0 then
    print(("\n%d check(s) failed"):format(fails))
    os.exit(1)
end
print("\nall good")
