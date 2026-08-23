-- The landing: the summary of what Deploy will do.
--
--     lua5.1 client/tests/landing_test.lua
--
-- Desktop once replaced the phone's useful summary with a roster and a map.
-- That made the larger screen explain less about the press. Both layouts now
-- name the mode, clock, score, room, and arriving ship in the same order.

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

local function view()
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
        rows = {{label = "Melee", act = "join", value = 1}},
        aside = {
            deploy = true,
            label = "Melee",
            note = "Four a side, three minutes",
            zones = 3,
            at = 1,
            room = {players = 4, bots = 4, seats = 8},
            clock = 160,
            playing = true,
            score = {1, 1},
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

local function draw(w, h)
    W, H = w, h
    boxes = {}
    state.n = 0
    ui.begin(layer, W, H, 1, false)
    ui.menu(view())
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

local function summary_checks(name, w, h)
    local texts, hits = draw(w, h)
    check(name .. " names the game", has(texts, "Melee"))
    check(name .. " says what the game is",
          has(texts, "Four a side, three minutes"))
    check(name .. " carries the live clock and score",
          has(texts, "On the clock") and has(texts, "2:40")
              and has(texts, "The score") and has(texts, "1 : 1"))
    check(name .. " carries the room",
          has(texts, "The room") and has(texts, "8 seats"))
    check(name .. " says which ship arrives",
          has(texts, "You arrive as") and has(texts, "Apex"))
    check(name .. " ends in one Deploy action", has(texts, "Deploy"))

    local stage = 0
    for _, hit in ipairs(hits or {}) do
        if hit.action == "stage" then stage = stage + 1 end
    end
    check(name .. " publishes one Deploy target", stage == 1,
          stage .. " stage targets")
    return texts
end

local desktop = summary_checks("desktop", 1280, 800)
check("desktop does not replace the summary with a roster",
      not has(desktop, "Halcyon"), "roster name was drawn")

summary_checks("phone", 420, 780)

if fails > 0 then
    print(("\n%d check(s) failed"):format(fails))
    os.exit(1)
end
print("\nall good")
