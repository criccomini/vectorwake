-- The upgrades page: where its column ends, and what buys a rung.
--
--     lua5.1 client/tests/shop_test.lua
--
-- Wide enough, this page is two columns: the shelf on the left and a reading
-- pane on the right that fills with whatever the cursor is on. Everything
-- belonging to the shelf is measured against the shelf's width. Two things
-- were measured against the page's instead, so the wallet's number sat out
-- over the pane and every section rule ran the whole way across it, through
-- the divider and under the words. That is invisible in the source, where
-- both are a variable called something reasonable, and obvious in a
-- screenshot, which is where it was found. It is measured here.
--
-- The other half is the buy. It used to be the row: stand on one, press
-- again, and a card asked whether to spend. Nothing on screen said so except
-- a line of grey type reading "press the row". There is a button now, and
-- these checks are that it exists, that it says which row it would spend on,
-- and that it is the only thing on the page that spends.

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

-- --- the shelf has the column to itself -----------------------------------
--
-- There was a reading pane down the right hand side of this page, on any
-- window with 760 points to give it. The menu is one column at a phone's
-- measure now, so the shelf takes the whole of it and the pane is a page you
-- step into: `shop_item`, which is the route a phone always took and the only
-- route there is.

local v = {shop = true, rows = rows(), sel = 3, rail = {},
           pilot = {rivets = 310}}
local st = draw(v)

local function said(st2, s)
    for _, t2 in ipairs(texts(st2)) do
        if string.lower(t2.s or "") == string.lower(s) then return t2 end
    end
end

check("the shelf draws no reading pane beside itself",
      said(st, "gun add-on") == nil, "a pane is still drawn")

local rules = {}
for _, s in ipairs(segs) do
    if math.abs(s.y0 - s.y1) < 0.5 and s.x1 - s.x0 > 200
       and s.x0 > 10 and s.y0 > 80 and s.y0 < H - 120 then
        rules[#rules + 1] = s
    end
end
check("the shelf draws a rule over each of its sections", #rules == 2,
      tostring(#rules))

-- The currency is named beside the shelf's balance. The glyph alone asked a
-- new player to recognize a unit the menu had not taught yet.
check("the shelf names the currency and its balance",
      said(st, "310") ~= nil and said(st, "rivets") ~= nil,
      "missing rivets or balance")

-- --- the buy is on the item's own page ------------------------------------
--
-- One thing off the shelf, as a page you step into. It was a phone's route
-- alone while a wider window carried the pane beside the list; there is no
-- window wide enough now, so this is the route.

local ist = draw({item = rows()[3], rows = {}, rail = {},
                  pilot = {rivets = 310}})
check("the item page says what kind of thing this is",
      said(ist, "gun add-on") ~= nil, "no kind line")
check("and names it", said(ist, "Gun spray") ~= nil, "no headline")
-- The way back, because a page you step into needs one and the tab row goes
-- to a different page rather than up a level.
check("and carries the way back to the shelf", box("back") ~= nil, "no back")

local key = box("buy_go")
check("the item page buys with the shelf's own action", key ~= nil,
      "no buy key")
check("and names no row, being about one thing",
      key and key.value == nil, key and tostring(key.value) or "none")

-- A wallet too light does not take the button away. A page that published no
-- box at all was one where the mouse did nothing and said nothing; the price
-- is the answer, and it is the card that gives it.
draw({item = rows()[4], rows = {}, rail = {}, pilot = {rivets = 10}})
check("a price above the wallet keeps its button", box("buy_go") ~= nil,
      "no buy key on a row nobody can afford")

-- Nothing to sell, nothing to press. The page says yours or dealt instead.
draw({item = rows()[2], rows = {}, rail = {}, pilot = {rivets = 310}})
check("a row taken to the top of its ladder has no button",
      box("buy_go") == nil, "a topped-out row offered a buy")

if fails > 0 then
    print(("\n%d check(s) failed"):format(fails))
    os.exit(1)
end
print("\nall good")
