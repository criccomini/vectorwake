-- The page about the room the game points at.
--
--     lua5.1 client/tests/discord_test.lua
--
-- The page is a poster rather than a small document: one reason to go, one
-- action, and one fallback address. These checks protect that hierarchy as well
-- as the link and the narrow layout.
--
-- So the checks here are about shape rather than wording: that one thing on
-- the page answers a press, that the address is on it and is quoted the way a
-- machine reading is quoted, and that the page fits the window a phone gives
-- it. The words themselves are menu.lua's and menu_nav_test's.

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

-- --- the engine, as much of it as ui.lua touches --------------------------

local W, H = 1280, 800
local segs, hits
local harness = require("tests.ui_harness")
local layer = harness.layer()
layer.seg = function(_, x0, y0, x1, y1)
    segs[#segs + 1] = {x0 = x0, y0 = H - y0, x1 = x1, y1 = H - y1}
end

local ui = harness.install()

local ADDR = "play.vectorwake.net/discord"
local function view()
    return {
        rail = {}, at = "discord", depth = 2, home = true, focus = "stage",
        discord = "https://" .. ADDR,
        door = true,
        door_head = "Rally for the next match.",
        door_body = "Meet pilots before the whistle. The people building "
            .. "Vectorwake read bug reports and talk through new ships, maps, "
            .. "and rules there.",
        door_note = "opens a new tab; your game keeps running",
        door_addr = ADDR,
        rows = {{label = "join discord", act = "discord", pick = true,
                 link = "https://" .. ADDR}},
        sel = 1,
    }
end

local function draw(w, h)
    W, H = w or 1280, h or 800
    segs = {}
    local st = package.loaded["arena.state"]
    st.n = 0
    ui.begin(layer, W, H, 1, false)
    ui.menu(view())
    ui.finish()
    hits = ui.hits or ui.boxes
    return st
end

local function texts(st)
    local out = {}
    for i = 1, st.n do out[#out + 1] = st.text[i] end
    return out
end

local function said(st, s)
    for _, t in ipairs(texts(st)) do
        if t.s == s then return t end
    end
end

local function containing(st, s)
    for _, t in ipairs(texts(st)) do
        if t.s and t.s:find(s, 1, true) then return t end
    end
end

-- --- one thing answers ----------------------------------------------------

local st = draw()

-- The page's own boxes, which is every box the corner and the backdrop did
-- not publish. A page with one control publishes one.
local mine = {}
for _, b in ipairs(hits or {}) do
    if b.action == "stage" then mine[#mine + 1] = b end
end
check("one thing on the page answers a press", #mine == 1,
      #mine .. " rows published a box")
check("and it is a shape rather than a line across the page",
      mine[1] and mine[1].w < 400, mine[1] and tostring(mine[1].w) or "none")
check("at least as tall as a button is", mine[1] and mine[1].h >= 26,
      mine[1] and tostring(mine[1].h) or "none")
check("and the browser gets a real anchor for the tap",
      ui.link_dom and ui.link_dom:find("https://" .. ADDR, 1, true),
      tostring(ui.link_dom))

-- --- the address ----------------------------------------------------------

local addr = said(st, ADDR)
check("the address is on the page", addr ~= nil, "not drawn")
-- Verbatim. The menu sets its own sentences in a sentence's case, and an
-- address run through that comes out with the host capitalized, which is not
-- an address any more.
check("and is quoted exactly, the way every machine reading is",
      addr and addr.s == ADDR, addr and addr.s or "none")
check("with no scheme in front of it for somebody to type",
      addr and not addr.s:find("://", 1, true))

-- --- the poster hierarchy -------------------------------------------------

local hero = said(st, "Rally for the next match.")
local body = containing(st, "Meet pilots")
local action = said(st, "Join discord")
check("the reason to go is the largest line", hero and body and hero.px > body.px * 2,
      hero and body and (hero.px .. " over " .. body.px) or "missing copy")
check("the action says where it goes", action ~= nil, "no Join discord")

local rules = 0
for _, s in ipairs(segs) do
    if math.abs(s.y0 - s.y1) < 0.5 and math.abs(s.x1 - s.x0) > 100
       and s.y0 > 150 then
        rules = rules + 1
    end
end
check("one rule separates the fallback address", rules == 1, rules .. " rules")

-- --- and it fits a phone --------------------------------------------------

-- The window a phone held upright gives this. Nothing on the page may run out
-- of it: the line beside the button is the widest thing here and does not fit
-- beside the button at this width, so it goes under it.
local ADV = 1233 / 2048
local narrow = draw(420, 780)
local right = 0
for _, t in ipairs(texts(narrow)) do
    if t.x and t.px and t.s then
        right = math.max(right, t.x + #t.s * t.px * ADV)
    end
end
check("nothing runs off a phone", right < 420, ("widest ends at %.1f"):format(right))
check("and the address is still whole on one", said(narrow, ADDR) ~= nil,
      "the address wrapped or vanished")

if fails > 0 then
    print(("\n%d check(s) failed"):format(fails))
    os.exit(1)
end
print("\nall good")
