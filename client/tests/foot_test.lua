-- What the menu pins at the foot of its column stands on the rail.
--
--     lua5.1 client/tests/foot_test.lua
--
-- Three things get pinned down there: the guest warning the menu draws
-- itself, the invite band on the friends page, and the account keys at the
-- foot of the pilot page. They are drawn by three different pieces of code
-- against three different floors, and for a while those floors disagreed: the
-- warning sat on the rule over the tabs and the other two stood forty points
-- clear of it, which reads as furniture that has come away from the bottom of
-- the panel it belongs to.
--
-- So this measures all three against the same line, the rule the tab row is
-- drawn under, and against each other. It is arithmetic no assertion about
-- strings can see and no screenshot in CI can catch.

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

local harness = require("tests.ui_harness")
local ui = harness.install()
local state = package.loaded["arena.state"]

local W, H = 1440, 810

-- Every straight line the frame drew, back in the coordinates the interface
-- laid them out in: `ry` flips y for the layer, so this flips it back.
local rules
local function layer()
    local l = harness.layer()
    l.seg = function(_, x1, y1, x2, y2)
        rules[#rules + 1] = {x1 = x1, y1 = H - y1, x2 = x2, y2 = H - y2}
    end
    return l
end

local RAIL = {}
for i, n in ipairs({"play", "ship", "friends", "pilot", "settings"}) do
    RAIL[i] = {label = n, icon = n == "play" and "zones" or n, index = i}
end

local function draw(v)
    rules = {}
    ui.begin(layer(), W, H, 1, false, 0)
    ui.menu(v)
    ui.finish()
end

-- The rule the tab row hangs under: the lowest line across the whole column.
-- The head wears one too, and so does the top of every band.
local function rail_top()
    local at
    for _, r in ipairs(rules) do
        if math.abs(r.y1 - r.y2) < 0.01 and math.abs(r.x2 - r.x1) > 380
           and (not at or r.y1 > at) then
            at = r.y1
        end
    end
    return at
end

local function hit_of(action, wide)
    for _, hbox in ipairs(ui.hits) do
        if hbox.action == action and (not wide or hbox.w > 380) then
            return hbox
        end
    end
end

local function word(s)
    for i = 1, state.n do
        if state.text[i].s == s then
            return {x = state.text[i].x, y = H - state.text[i].y}
        end
    end
end

-- --- the friends page's invite band -----------------------------------------

local function friends(banner)
    return {depth = 2, sel = 1, rail = RAIL, rail_sel = 3, focus = "stage",
            home = true, closable = true, at = "friends", social = true,
            banner = banner, guest_dot = banner,
            invite = "https://vectorwake.net/",
            pilot = {name = "Vantage 7", rivets = 120},
            add = {name = "", on = false, note = "", bad = false, found = {}},
            rows = {{label = "Corvid 12", detail = "Team Battle",
                     state = "flying", index = 1, pick = true}}}
end

draw(friends(false))
local rail = rail_top()
local band = hit_of("invite")
check("the invite band stands on the rail",
      band and math.abs((band.y + band.h) - rail) < 0.5,
      band and string.format("%.0f against %.0f", band.y + band.h, rail))
check("and reaches both edges of the column",
      band and band.w > 380, band and string.format("%.0f wide", band.w))

-- --- the guest warning, and the two of them stacked --------------------------

draw(friends(true))
rail = rail_top()
local warn = hit_of("pilot_page", true)
band = hit_of("invite")
check("the guest warning stands on the rail",
      warn and math.abs((warn.y + warn.h) - rail) < 0.5,
      warn and string.format("%.0f against %.0f", warn.y + warn.h, rail))
check("and the invite band stands on the warning rather than under it",
      band and warn and math.abs((band.y + band.h) - warn.y) < 0.5,
      band and warn and string.format("%.0f against %.0f",
                                      band.y + band.h, warn.y))
check("the two bands are one height",
      band and warn and math.abs(band.h - warn.h) < 0.5,
      band and warn and string.format("%.0f and %.0f", band.h, warn.h))
-- One column for the type on both of them, which is the column every page
-- draws its own type in.
local a = word("Get somebody you know into the game.")
local b = word("You are using a guest account.")
check("and their words begin on one line",
      a and b and math.abs(a.x - b.x) < 0.5,
      a and b and string.format("%.0f and %.0f", a.x, b.x))

-- --- the pilot page's account keys ------------------------------------------
--
-- Keys rather than a band, so they keep the gutter the column keeps at its
-- sides rather than sitting on the rule. What is pinned is that they keep no
-- more than it: this pair stood in a strip of ground half again as tall as
-- the keys themselves.

local function pilot(claimed)
    return {depth = 2, sel = 0, rail = RAIL, rail_sel = 4, focus = "stage",
            home = true, closable = true, at = "pilot",
            pilot = {name = "Vantage 7", rivets = 120},
            pilot_card = {name = "Vantage 7", online = true,
                          claimed = claimed, rivets = 120,
                          career = {games = 14, kills = 61, deaths = 48}},
            rows = {}}
end

for _, who in ipairs({{true, "a signed-in pilot"}, {false, "a guest"}}) do
    draw(pilot(who[1]))
    rail = rail_top()
    local low
    for _, hbox in ipairs(ui.hits) do
        if hbox.action == "stage" and (not low or hbox.y > low.y) then
            low = hbox
        end
    end
    local gap = low and (rail - (low.y + low.h))
    check("the foot of the pilot page clears the rail by the column's gutter"
          .. " for " .. who[2],
          gap and gap > 0 and gap <= ui.MENU_PAD + 0.5,
          gap and string.format("%.0f", gap))
end

if fails > 0 then
    print(fails .. " failed")
    os.exit(1)
end
print("all passed")
