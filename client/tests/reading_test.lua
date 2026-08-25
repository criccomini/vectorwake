-- The reading a slot opens: what it says, and what buys a rung.
--
--     lua5.1 client/tests/reading_test.lua
--
-- The shelf used to be a tab of its own, a list of every slot with a reading
-- pane beside it on a wide enough window. It is the ship page now, and the
-- pane is the page a row opens: press a slot's name, or the part of its
-- ladder nobody owns, and this slides in from the right.
--
-- What is checked here is that the reading carries the four things no other
-- page in the menu does. What kind of thing this is and what it is called;
-- the lesson, in the client's own words; the price of the next rung against
-- the wallet it comes out of, which is on this page and no other; and one
-- key that spends it. Plus the way back, since a page that slid in over
-- another needs one.

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
local segs, rects, hits
local harness = require("tests.ui_harness")
local layer = harness.layer()
layer.rect = function(_, x, y, w, h)
    rects[#rects + 1] = {x = x, y = H - y - h, w = w, h = h}
end
layer.seg = function(_, x0, y0, x1, y1)
    segs[#segs + 1] = {x0 = x0, y0 = H - y0, x1 = x1, y1 = H - y1}
end

local ui = harness.install()

-- Two sections and four rows, one of them topped out, because what the
-- section rules do is the question and a page with one section has none.
local function rows()
    return {
        {sect = "stats", label = "Thrust", group = "flight", owned = 7,
         base = 6, arena_max = 8, price = 40, afford = true, pick = true,
         act = "buy", teach = "More push from the same engine."},
        {label = "Recharge", group = "flight", owned = 8, base = 6,
         arena_max = 8, pick = true},
        {sect = "gun add-ons", label = "Gun spray", group = "weapons",
         trigger = 0, mod = 0, owned = 1, base = 0, arena_max = 5,
         price = 70, afford = true, pick = true, act = "buy",
         teach = "More rounds a pull, opening into a fan."},
        {label = "Gun bouncing", group = "weapons", trigger = 0, mod = 1,
         owned = 0, base = 0, arena_max = 1, price = 120, afford = false,
         pick = true, act = "buy"},
    }
end

local function draw(v, w, h)
    W, H = w or 1280, h or 800
    segs, rects, hits = {}, {}, nil
    local st = package.loaded["arena.state"]
    st.n = 0
    ui.begin(layer, W, H, 1, false)
    ui.menu(v)
    ui.finish()
    hits = ui.hits or ui.boxes
    return st
end

local function texts(st)
    local out = {}
    for i = 1, st.n do out[#out + 1] = st.text[i] end
    return out
end

local function box(action)
    for _, b in ipairs(hits or {}) do
        if b.action == action then return b end
    end
end

-- --- the reading is about one slot ---------------------------------------

local function said(st2, s)
    for _, t2 in ipairs(texts(st2)) do
        if string.lower(t2.s or "") == string.lower(s) then return t2 end
    end
end

local function says(st2, s)
    for _, t2 in ipairs(texts(st2)) do
        if string.find(string.lower(t2.s or ""), string.lower(s), 1, true) then
            return t2
        end
    end
end

local ist = draw({item = rows()[3], rows = {rows()[3]}, rail = {},
                  headless = true, closable = true, wallet = 310, sel = 1,
                  focus = "stage"})
check("the reading says what kind of thing this is",
      said(ist, "gun add-on") ~= nil, "no kind line")
check("and names it", said(ist, "Gun spray") ~= nil, "no headline")
check("and teaches it in the client's own words",
      says(ist, "rounds a pull") ~= nil, "no lesson")
-- The one page in the menu that names a wallet. Points are spent everywhere
-- else here and rivets only here, which is what keeps the word "spend"
-- meaning one thing on the page this came off.
check("the reading names the price and the wallet it comes out of",
      says(ist, "70") ~= nil and said(ist, "310") ~= nil,
      "missing price or wallet")
-- The way back, because a page you step into needs one and the tab row goes
-- to a different page rather than up a level.
check("and carries the way back to the ship page", box("back") ~= nil,
      "no back")

local key = box("buy_go")
check("the reading buys with the shelf's own action", key ~= nil,
      "no buy key")
check("and names no row, being about one thing",
      key and key.value == nil, key and tostring(key.value) or "none")

-- A wallet too light does not take the button away. A page that published no
-- box at all was one where the mouse did nothing and said nothing; the price
-- is the answer, and it is the card that gives it.
draw({item = rows()[4], rows = {rows()[4]}, rail = {}, headless = true,
      closable = true, wallet = 10, sel = 1, focus = "stage"})
check("a price above the wallet keeps its button", box("buy_go") ~= nil,
      "no buy key on a row nobody can afford")

-- Nothing to sell, nothing to press. The page says yours or dealt instead.
local topped = draw({item = rows()[2], rows = {}, rail = {}, headless = true,
                     closable = true, wallet = 310})
check("a row taken to the top of its ladder has no button",
      box("buy_go") == nil, "a topped-out row offered a buy")
check("and says so rather than leaving the question open",
      says(topped, "dealt") ~= nil or says(topped, "yours") ~= nil,
      "nothing said about a topped-out slot")

if fails > 0 then
    print(("\n%d check(s) failed"):format(fails))
    os.exit(1)
end
print("\nall good")
