-- How many words the interface asks for in one frame.
--
--     lua5.1 client/tests/glyph_budget_test.lua
--
-- Every glyph in this game is a gui text node out of one pool, and the pool
-- has an end: `client/ui/vwui.gui_script` clamps the frame at POOL nodes and
-- draws nothing past it. That clamp is silent, and what silence looked like
-- is what the standings table looked like for months before it was taken out:
-- ten pilots, then a row with a highlight on it and no name in it, and eleven
-- more pilots below that which were never drawn at all. The shapes kept
-- coming, because those are mesh; only the words stopped.
--
-- So the pool is a number this suite knows, and the pages that ask for the
-- most are drawn here at the sizes that ask for the most. A page that grows a
-- column or a row fails this before anybody has to notice a name missing.

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

-- Read off state.lua rather than written twice. The gui script draws its
-- pool from `state.TEXT_POOL`, so the side that writes the text and the two
-- tests that measure it are all held to the one number; this file only asks
-- whether a frame fits inside it.
local POOL
do
    local src = io.open("client/arena/state.lua"):read("*a")
    POOL = tonumber(string.match(src, "TEXT_POOL = (%d+)"))
    local gui = io.open("client/ui/vwui.gui_script"):read("*a")
    if not string.match(gui, "local POOL = state%.TEXT_POOL") then
        POOL = nil
    end
end
check("the gui script names a pool", POOL and POOL > 0, tostring(POOL))
-- And the scene has to hold at least that many, or the engine drops the
-- surplus before this file's arithmetic ever runs.
do
    local scene = io.open("client/ui/vwui.gui"):read("*a")
    local max = tonumber(string.match(scene, "max_nodes: (%d+)"))
    check("and the scene holds them", max and max >= POOL,
          "max_nodes " .. tostring(max) .. " for a pool of " .. tostring(POOL))
end

local W, H = 1280, 800
local harness = require("tests.ui_harness")
local layer = harness.layer()
local ui = harness.install()

local RAIL = {}
for i, n in ipairs({"zones", "ship", "upgrades", "friends", "settings"}) do
    RAIL[i] = {label = n, icon = n, index = i}
end

local function draw(view, w, h)
    W, H = w, h
    local st = package.loaded["arena.state"]
    st.n = 0
    ui.begin(layer, W, H, 1, false)
    ui.menu(view)
    ui.finish()
    return st.n
end

-- --- the friends page, which is the longest list in the menu ---------------
--
-- Sixty names because a room holds fewer than that and the page carries the
-- room on top of the friends; the drawing only publishes the rows that land
-- inside the panel, so the number that matters is how many fit rather than
-- how many came back.
local function friend_view(n)
    local rows = {}
    for i = 1, n do
        rows[i] = {label = "Pilot " .. (100 + i), index = i, pick = true,
                   detail = "flying halcyon", act = "unfriend",
                   who = i, state = "friend",
                   sect = (i % 10 == 1) and "a section" or nil}
    end
    return {depth = 2, sel = 1, rail = RAIL, rail_sel = 4, focus = "stage",
            home = true, closable = false, social = true, rows = rows,
            pilot = {name = "Squall 586"}, discord = "https://example.invalid",
            add = {name = "", on = false, note = "", bad = false, found = {}}}
end

-- The window a laptop opens at, two desktops, and four tall narrow shapes,
-- which are what fit the most rows into the panel. The last of them is past
-- anything a browser opens and is here as the ceiling rather than as a case.
local SHAPES = {{1280, 800}, {1920, 1200}, {2560, 1440}, {1100, 1600},
                {900, 2000}, {800, 2400}, {1000, 3000}}
for _, size in ipairs(SHAPES) do
    local w, h = size[1], size[2]
    local n = draw(friend_view(60), w, h)
    check(string.format("the friends page fits the pool at %dx%d", w, h),
          n <= POOL, n .. " of " .. POOL)
end

-- --- and the page beside it -----------------------------------------------
--
-- Not because it is close, but because "close" is a thing that changes when
-- somebody adds a column, and a suite that only watches the widest page finds
-- out about the second widest from a player.
do
    local rows = {}
    for i = 1, 40 do
        rows[i] = {label = "slot " .. i, index = i, pick = true,
                   detail = "level 3", price = 240, note = "what it does",
                   sect = (i % 8 == 1) and "a section" or nil}
    end
    local n = draw({depth = 2, sel = 1, rail = RAIL, rail_sel = 3,
                    focus = "stage", home = true, closable = false,
                    shop = true, rows = rows, rivets = 5000,
                    pilot = {name = "Squall 586"}}, 2560, 1440)
    check("the shelf fits the pool", n <= POOL, n .. " of " .. POOL)
end

print(fails == 0 and "PASS" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
