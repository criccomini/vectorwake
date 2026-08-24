-- The landing: where a press would put you, and what it takes to say so.
--
--     lua5.1 client/tests/landing_test.lua
--
-- Every window draws the same one: the deck, which is the game's name on a
-- carousel, what that game is, the clock and the room, the score as a bar
-- with a side coming in from each end, and one DEPLOY key across the foot.
-- The name and the bar and the key all take the page's own measure, which
-- is what these check: a landing laid out in a column somewhere in the
-- middle of a monitor is the shape this replaced.

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
local boxes, rects = {}, {}
local layer = {}
local function noop() end
for _, name in ipairs({"arc", "disc", "flush", "outline", "quad", "reset",
                        "ring", "tri", "tri_fade", "fan", "seg", "seg_glow",
                        "glow_band", "halo", "ring_fade", "seg_fade",
                        "seg_flat", "skirt"}) do
    layer[name] = noop
end
layer.frame = function(_, x, y, w, h)
    boxes[#boxes + 1] = {x = x, y = y, w = w, h = h}
end
layer.rect = function(_, x, y, w, h, col)
    rects[#rects + 1] = {x = x, y = y, w = w, h = h, col = col}
end

-- A room with three seats in it, so the landing has a roster to name. The
-- list reads the simulation for the seats it can see and the server's own
-- list for their names, which is what the scoreboard does.
local SEATS = {
    [0] = {name = "Halcyon", team = 0, k = 4, d = 2, a = 1},
    [1] = {name = "Sable", team = 1, k = 1, d = 3, a = 0, ai = true},
    [2] = {name = "Vantage", team = 0, k = 0, d = 0, a = 2},
}
_G.sim = setmetatable({
    ship_count = function() return 3 end,
    ship_active = function() return 1 end,
    ship_team = function(i) return SEATS[i].team end,
    ship_kills = function(i) return SEATS[i].k end,
    ship_deaths = function(i) return SEATS[i].d end,
    ship_assists = function(i) return SEATS[i].a end,
}, {__index = function()
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
        -- The room in the glass behind the panel, which is what the
        -- landing lists: the same roster and side the scoreboard reads.
        arena = {
            pilots = SEATS,
            watchers = {},
            side = 0,
            score = {[0] = 1, [1] = 1},
        },
        pilot = {name = "you", rivets = 0},
    }
end

local function draw(w, h, finding_rival)
    W, H = w, h
    boxes, rects = {}, {}
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

-- Which of the drawn rectangles are the two halves of the score bar: a
-- short one in each side's own color. Nothing else on this page is a band
-- of team color a few points tall.
local function bar_halves()
    local cyan, amber
    for _, r in ipairs(rects) do
        local c = r.col or {}
        if r.h < 12 and r.w > 20 then
            if c[1] == pal.FRIEND[1] and c[2] == pal.FRIEND[2] then
                cyan = r
            elseif c[1] == pal.ENEMY[1] and c[2] == pal.ENEMY[2] then
                amber = r
            end
        end
    end
    return cyan, amber
end

-- What both shapes must say about the room, wherever they lay it out.
local function readings_checks(name, texts)
    check(name .. " names the game", has(texts, "Melee"))
    check(name .. " says what the game is",
          has(texts, "Four a side, three minutes"))
    check(name .. " carries the live clock",
          has(texts, "Time") and has(texts, "2:40"))
    check(name .. " heads the roster", has(texts, "Players"))
    check(name .. " names everybody in the room",
          has(texts, "Halcyon") and has(texts, "Sable")
              and has(texts, "Vantage"))
    check(name .. " carries what each of them has done",
          has(texts, "4") and has(texts, "3") and has(texts, "2"))
    check(name .. " says nothing about arriving",
          not has(texts, "You arrive as"),
          "the arrival row was taken out")
    -- The score is a bar now, with a figure at each end of it in that
    -- side's color rather than two numbers and a colon, and no word over it:
    -- two figures in the side colors dividing a bar at the same place is not
    -- a reading anybody has to be told the name of.
    check(name .. " puts no label over the score", not has(texts, "Score"))
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
    check(name .. " says the score with no colon between the figures",
          not has(texts, " : "))
    local cyan, amber = bar_halves()
    check(name .. " draws the score as a bar of two colors",
          cyan ~= nil and amber ~= nil,
          (cyan and "" or "no cyan half ")
              .. (amber and "" or "no amber half"))
    check(name .. " meets the two halves where the match stands",
          cyan and amber and math.abs(cyan.x + cyan.w - amber.x) < 1,
          cyan and amber
              and string.format("cyan ends %.1f, amber starts %.1f",
                                cyan.x + cyan.w, amber.x) or "no bar")
end

-- --- desktop: the deck, across the page ----------------------------------

local desktop, hits = draw(1280, 800)
readings_checks("desktop", desktop)
check("desktop ends in one Deploy key", has(desktop, "Deploy"))
local key_hit
for _, hit in ipairs(hits or {}) do
    if hit.action == "stage" and hit.value == 1 then key_hit = hit end
end
check("the key presses the zone the carousel is on", key_hit ~= nil,
      "no stage target on the key")
-- The key runs the page. It was a box a third of a monitor wide, standing
-- in a column with a screen of nothing beside it.
check("the key takes the width of the page",
      key_hit and key_hit.w > W * 0.85,
      key_hit and string.format("key %.0f wide in %d", key_hit.w, W)
          or "no key")
-- And the bar runs the same measure, so the two read as one block. Measured
-- against the drawn key rather than its hit box, which is a few points
-- proud of it on every side so a near miss still lands.
local cyan, amber = bar_halves()
local key_box
for _, b in ipairs(boxes) do
    if not key_box or b.w > key_box.w then key_box = b end
end
check("the score bar takes the key's own measure",
      cyan and amber and key_box
          and math.abs(cyan.w + amber.w - key_box.w) < 1,
      cyan and amber and key_box
          and string.format("bar %.1f, key %.1f", cyan.w + amber.w,
                            key_box.w) or "no bar")
-- One column: the readings hang under the name of the game rather than
-- standing in a second column beside it.
local melee = find_text(desktop, "Melee")
local clock = find_text(desktop, "Time")
check("the readings sit under the name, not beside it",
      melee and clock and math.abs(melee.x - clock.x) < 60,
      string.format("melee %.0f, clock %.0f",
                    melee and melee.x or -1, clock and clock.x or -1))
-- The name is the biggest thing on the page, which is the one question it
-- asks. It used to be set at the size of a row in a list.
check("the game's name is the biggest type on the page",
      melee and clock and melee.px > 40,
      melee and string.format("name at %.0f", melee.px) or "no name")

-- --- phone: the same deck, given a phone's page ---------------------------

local phone, phits = draw(420, 780)
readings_checks("phone", phone)
check("phone ends in one Deploy key", has(phone, "Deploy"))
local stage, ship_page, pilot_page = 0, 0, 0
for _, hit in ipairs(phits or {}) do
    if hit.action == "stage" then stage = stage + 1 end
    if hit.action == "ship_page" then ship_page = ship_page + 1 end
    if hit.action == "pilot_page" then pilot_page = pilot_page + 1 end
end
check("phone publishes one Deploy target", stage == 1,
      stage .. " stage targets")
-- The ship and the call sign left with the arrival row. Ship is a stop on
-- the rail and the account is the button in the header, which is where both
-- of them are on every other page.
check("phone sends nobody to the ship page from here", ship_page == 0,
      ship_page .. " ship targets")
check("phone keeps the one account button", pilot_page == 1,
      pilot_page .. " account targets")

-- A ladder pilot waiting on a rival reads the same label as a room between
-- matches, over a clock that is not counting. FINDING RIVAL over --:-- was
-- the same news twice, since the dashes already say nothing is counting.
for _, shape in ipairs({{1280, 800}, {420, 780}}) do
    local texts = draw(shape[1], shape[2], true)
    local name = shape[1] > 500 and "desktop" or "phone"
    check(name .. " Ladder landing waits under the one label",
          has(texts, "Next match") and has(texts, "--:--")
              and not has(texts, "Finding rival")
              and not has(texts, "Time"))
end

if fails > 0 then
    print(("\n%d check(s) failed"):format(fails))
    os.exit(1)
end
print("\nall good")
