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

-- --- where the shelf ends -------------------------------------------------

local v = {shop = true, rows = rows(), sel = 3, rail = {},
           pilot = {rivets = 310}}
local st = draw(v)

-- The pane's left edge, read off the one thing only it draws: the kind line
-- over the headline. Everything the shelf draws has to stop short of it.
local pane_x
for _, t in ipairs(texts(st)) do
    if string.lower(t.s or "") == "gun add-on" then pane_x = t.x end
end
check("the reading pane is on screen to be crossed", pane_x ~= nil,
      "no pane")

local rules = {}
for _, s in ipairs(segs) do
    if math.abs(s.y0 - s.y1) < 0.5 and s.x1 - s.x0 > 200
       and s.x0 > 100 and s.y0 > 150 then
        rules[#rules + 1] = s
    end
end
check("the shelf draws a rule over each of its sections", #rules == 2,
      tostring(#rules))
local worst = 0
for _, s in ipairs(rules) do worst = math.max(worst, s.x1) end
check("and no rule reaches the pane it would otherwise cross",
      pane_x and worst < pane_x, ("rule ends at %.1f, pane at %.1f")
          :format(worst, pane_x or -1))

-- The currency is named beside the shelf's balance. The glyph alone asked a
-- new player to recognize a unit the menu had not taught yet.
local wallet
local currency
for _, t in ipairs(texts(st)) do
    if t.s == "310" then wallet = t.x end
    if t.s == "RIVETS" then currency = t.x end
end
check("the shelf names the currency and its balance",
      wallet ~= nil and currency ~= nil, "missing rivets or balance")
check("and says it over the shelf rather than over the pane",
      wallet and pane_x and wallet < pane_x,
      ("wallet at %.1f, pane at %.1f"):format(wallet or -1, pane_x or -1))

-- --- the buy --------------------------------------------------------------

local buy = box("buy_go")
check("the pane carries a button that buys", buy ~= nil, "no buy box")
check("and it stands in the pane rather than over the shelf",
      buy and pane_x and buy.x >= pane_x - 1,
      buy and ("button at %.1f, pane at %.1f"):format(buy.x, pane_x or -1)
          or "none")
check("and it names the row the pane is reading",
      buy and buy.value == 3, buy and tostring(buy.value) or "none")

-- Whatever the pane came to be reading, the button spends on that and not on
-- something worked out a second time. The pane takes the cursor first and the
-- pointer where there is none, so the check is that the two agree rather than
-- which of the two won: reading the headline back out is what settles it.
local function pane_reads(st2)
    -- The headline is set in the page's largest type, and it is the row's
    -- own name.
    local big, at = 0, nil
    for _, t in ipairs(texts(st2)) do
        if (t.px or 0) > big and t.x and pane_x and t.x >= pane_x - 1 then
            big, at = t.px, t.s
        end
    end
    return at
end

local function agree(label, v2)
    local st2 = draw(v2)
    local b = box("buy_go")
    local said = pane_reads(st2)
    local named = b and (v2.rows[b.value] or {}).label
    check(label, said ~= nil and named ~= nil
          and string.lower(said) == string.lower(named),
          tostring(said) .. " read, " .. tostring(named) .. " on the button")
end

agree("the button spends on the row the pane is reading",
      {shop = true, rows = rows(), sel = 3, rail = {}, pilot = {rivets = 310}})
agree("and follows the pointer where nothing has the cursor",
      {shop = true, rows = rows(), hover = 1, rail = {},
       pilot = {rivets = 310}})

-- A wallet too light does not take the button away. A row that published no
-- box at all was a page where the mouse did nothing and said nothing; the
-- price is the answer, and it is the card that gives it.
agree("a price above the wallet keeps its button",
      {shop = true, rows = rows(), sel = 4, rail = {}, pilot = {rivets = 10}})

-- Nothing to sell, nothing to press. The pane says yours or dealt instead.
v.hover = nil
v.sel = 2
draw(v)
check("a row taken to the top of its ladder has no button",
      box("buy_go") == nil, "a topped-out row offered a buy")

-- --- and the same act on a phone -----------------------------------------

-- Too narrow for a pane, so the shelf is the page and one thing off it is a
-- page you step into. That page ends in a BUY of its own, and it publishes
-- the same action so the two cannot come apart.
local item = {item = rows()[3], rail = {}, pilot = {rivets = 310}}
draw(item, 420, 780)
local key = box("buy_go")
check("the page a phone steps into buys with the same action", key ~= nil,
      "no buy key")
check("and names no row, being about one thing",
      key and key.value == nil, key and tostring(key.value) or "none")

if fails > 0 then
    print(("\n%d check(s) failed"):format(fails))
    os.exit(1)
end
print("\nall good")
