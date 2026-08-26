-- What the friends page says with marks rather than with words.
--
--     lua5.1 client/tests/friends_page_test.lua
--
-- The page answers three questions and this measures the two that are drawn
-- rather than written: whether a friend is in a game, and how to reach
-- somebody who is not in the game at all.
--
-- Whether they are on is a dot, and the dot is two facts at once: green where
-- the color lands and solid-or-hollow where it does not. That redundancy is
-- the point. A page that says "on" in green alone says nothing to a pilot who
-- cannot separate green from grey, and this is the one page whose whole job is
-- that distinction, so the shape is checked here beside the color.
--
-- The invite key is checked for the thing that is easy to break by moving a
-- number: it is pinned to the foot, so it stands in the same place whether the
-- page holds three names or sixty, and it publishes the rectangle the browser
-- lays its anchor over. Without that rectangle the key is a drawing, since a
-- share sheet and a clipboard write both have to happen inside a gesture the
-- page itself saw and a press routed through the engine is not one.

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

local W, H = 390, 844
local discs, rings = {}, {}
local harness = require("tests.ui_harness")
local layer = harness.layer()
layer.disc = function(_, x, y, r, _segs, col)
    discs[#discs + 1] = {x = x, y = y, r = r, col = col}
end
layer.ring = function(_, x, y, r, w, _segs, col)
    rings[#rings + 1] = {x = x, y = y, r = r, w = w, col = col}
end
local ui = harness.install()
local pal = require("arena.palette")

local RAIL = {}
for i, n in ipairs({"play", "ship", "friends", "settings", "pilot"}) do
    RAIL[i] = {label = n, icon = n, index = i}
end

local INVITE = "https://vectorwake.net/"

-- The page as `menu.view` hands it over: an add waiting on an answer, a friend
-- in a game, and two who are not.
local function view(rows)
    return {depth = 2, sel = 0, rail = RAIL, rail_sel = 3, focus = "stage",
            home = true, closable = true, social = true, at = "friends",
            pilot = {name = "Delta 154", rivets = 0},
            add = {name = "", on = false, note = "", bad = false, found = {}},
            invite = INVITE, rows = rows}
end

local PAGE = {
    {label = "Gantry 4", detail = "added you 2h ago", state = "asked",
     index = 1, pick = true, sect = "received", sect_note = "1",
     acts = {{label = "accept", go = true}, {label = "ignore"}}},
    {label = "Halcyon 2", detail = "Team Battle", state = "flying",
     index = 2, pick = true, sect = "friends",
     acts = {{label = "join", go = true}, {label = "unfriend"}}},
    {label = "Vireo 9", detail = "", state = "friend", index = 3, pick = true,
     acts = {{label = "unfriend"}}},
    {label = "Sable 09", detail = "", state = "friend", index = 4, pick = true,
     acts = {{label = "unfriend"}}},
}

-- `keep` leaves the scroll where the caller put it. The clamp reads the extent
-- the last frame published, so reaching the end of a page takes two draws: one
-- to measure it and one to land there.
local function draw(v, w, h, keep)
    W, H = w or 390, h or 844
    discs, rings = {}, {}
    local st = package.loaded["arena.state"]
    st.n = 0
    if not keep then ui.page_scroll = 0 end
    ui.link_dom = nil
    ui.begin(layer, W, H, 1, false)
    ui.menu(v)
    ui.finish()
    return st
end

local function words(st)
    local out = {}
    for i = 1, st.n do out[#out + 1] = st.text[i].s end
    return out
end

local function says(st, s)
    for _, t in ipairs(words(st)) do
        if t == s then return true end
    end
    return false
end

-- --- the dot ---------------------------------------------------------------

local st = draw(view(PAGE))

-- Every disc drawn in the online green, which is the mark a friend in a game
-- wears and nothing else on this page does.
local function green_discs()
    local out = {}
    for _, d in ipairs(discs) do
        local c = d.col
        if c and c[1] == pal.ONLINE[1] and c[2] == pal.ONLINE[2]
           and c[3] == pal.ONLINE[3] then
            out[#out + 1] = d
        end
    end
    return out
end

check("the friend in a game gets one solid green dot",
      #green_discs() == 1, #green_discs() .. " of them")
check("and it is green rather than the menu's own cyan",
      pal.ONLINE[1] ~= pal.FRIEND[1] or pal.ONLINE[2] ~= pal.FRIEND[2],
      "ONLINE and FRIEND are the same color")

-- The two who are off. Hollow, so the page still says it on a screen that
-- shows both colors as one grey, and dim, so the eye lands on the one who is
-- on. Measured against the solid one's size, since the menu draws rings for
-- other reasons and a dot is the one that is a dot's width.
local function dim_rings()
    local solid = green_discs()[1]
    local out = {}
    for _, r in ipairs(rings) do
        local c = r.col
        if c and c[1] == pal.DIM[1] and c[2] == pal.DIM[2]
           and solid and math.abs(r.r - solid.r) < 0.01 then
            out[#out + 1] = r
        end
    end
    return out
end

check("the two who are off get hollow ones", #dim_rings() == 2,
      #dim_rings() .. " of them")
check("and the hollow ones sit on the rows of the two who are off",
      #dim_rings() == 2 and #green_discs() == 1
      and math.abs(dim_rings()[1].x - green_discs()[1].x) < 0.01,
      "hollow at " .. tostring(dim_rings()[1] and dim_rings()[1].x)
      .. ", solid at " .. tostring(green_discs()[1].x))

-- --- what a row says in words ---------------------------------------------

check("a friend in a game names it as the games list spells it",
      says(st, "Team Battle"), table.concat(words(st), " "))
-- Drawn raw. The menu is set in a sentence's case, which capitalizes the first
-- letter of a line and no other, so a game's name run through it comes out as
-- "Team battle" the moment somebody stops passing `raw`.
check("and keeps the capitals it came with", not says(st, "Team battle"),
      table.concat(words(st), " "))
check("and a friend who is off says nothing beside their name",
      says(st, "Vireo 9") and not says(st, "Not on"),
      table.concat(words(st), " "))

-- --- keys are on the row that is asking, and nowhere else -----------------
--
-- The old page hung a key off every row, and unfriend was drawn three times
-- for every join. What a friend's row offers is on the card it raises, which
-- is where five inputs always had to find it.

local function key_hits()
    local out = {}
    for _, hbox in ipairs(ui.hits) do
        if hbox.action == "friend_act" then out[#out + 1] = hbox end
    end
    return out
end

check("the received add carries its two keys", #key_hits() == 2,
      #key_hits() .. " keys drawn")
for _, hbox in ipairs(key_hits()) do
    check("and both belong to the row that is asking", hbox.value == 1,
          "row " .. tostring(hbox.value))
end

-- --- the invite key -------------------------------------------------------

local function invite_hit()
    for _, hbox in ipairs(ui.hits) do
        if hbox.action == "invite" then return hbox end
    end
end

check("the page draws an invite key", invite_hit() ~= nil)
check("and hands the browser a rectangle over it carrying the address",
      type(ui.link_dom) == "string"
      and ui.link_dom:find("vwshare:" .. INVITE, 1, true) ~= nil,
      tostring(ui.link_dom))

-- Pinned rather than scrolled to. A page with sixty names on it has the key in
-- the same place as a page with three, which is what makes it a way out of the
-- page rather than the end of a list.
local long = {}
for i = 1, 60 do
    long[i] = {label = "Pilot " .. (100 + i), detail = "", state = "friend",
               index = i, pick = true, sect = i == 1 and "friends" or nil,
               acts = {{label = "unfriend"}}}
end
local short_at = invite_hit().y
draw(view(long))
check("and it stands in the same place on a page of sixty",
      invite_hit() ~= nil and math.abs(invite_hit().y - short_at) < 0.01,
      tostring(invite_hit() and invite_hit().y) .. " against "
      .. tostring(short_at))

-- Scrolled to the end, the last row stops above the key rather than under it.
-- Two draws: the first publishes what the page came to, the second is clamped
-- against it and lands at the bottom.
ui.page_scroll = 99999
local st2 = draw(view(long), nil, nil, true)
local last = ui.page_scroll
check("a full page scrolls to its last name", says(st2, "Pilot 160"),
      "scrolled " .. string.format("%.0f", last))
local key_y = invite_hit().y
local under = 0
for i = 1, st2.n do
    local t = st2.text[i]
    -- state.text counts up from the bottom of the window and everything else
    -- here counts down from the top, so the row's line is compared in the
    -- frame the hit box is published in.
    local ty = H - t.y
    if t.s:find("^Pilot ") and ty > key_y then under = under + 1 end
end
check("and no name is drawn under the key", under == 0,
      under .. " below " .. string.format("%.0f", key_y))

-- --- the empty page keeps both doors --------------------------------------
--
-- The page most accounts meet: the field at the top and the key at the foot,
-- with the card between them. Neither is the list, so neither goes away when
-- there is no list.

local st3 = draw({depth = 2, sel = 0, rail = RAIL, rail_sel = 3,
                  focus = "stage", home = true, closable = true,
                  social = true, at = "friends", invite = INVITE,
                  pilot = {name = "Delta 154", rivets = 0},
                  add = {name = "", on = false, note = "", bad = false,
                         found = {}},
                  empty = {head = "nobody yet",
                           line = "type a call sign above, or invite"
                                  .. " somebody you know"},
                  rows = {}})
check("an empty page still asks for a call sign",
      says(st3, "ADD FRIEND"), table.concat(words(st3), " "))
check("and still offers the key", invite_hit() ~= nil)
check("and says it is empty", says(st3, "Nobody yet"),
      table.concat(words(st3), " "))

if fails > 0 then
    print(fails .. " failed")
    os.exit(1)
end
print("all friends page checks passed")
