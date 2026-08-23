-- The page about the room the game points at.
--
--     lua5.1 client/tests/discord_test.lua
--
-- It was four rows. One of them went somewhere and three did not, and all
-- four were set in the face and the size every row that goes somewhere is set
-- in, so a hand walking down them with the arrows found one control and three
-- impersonations of one. Each also carried a line underneath finishing its own
-- sentence, which is the caption docs/design/interface.md says this interface
-- does not have. And the one thing docs/design/community.md says ships first,
-- an address a player can read and retype, was not on it anywhere.
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
local layer = {}
local function noop() end
for _, n in ipairs({"arc", "disc", "flush", "outline", "quad", "reset", "ring",
                    "tri", "tri_fade", "fan", "seg_glow", "glow_band", "halo",
                    "ring_fade", "seg_fade", "seg_flat", "frame", "skirt",
                    "rect"}) do
    layer[n] = noop
end
layer.seg = function(_, x0, y0, x1, y1)
    segs[#segs + 1] = {x0 = x0, y0 = H - y0, x1 = x1, y1 = H - y1}
end

_G.sim = setmetatable({}, {__index = function() return function() return 0 end end})
package.loaded["arena.state"] = {text = {}, n = 0, version = 0}
package.loaded["arena.touch"] = {layout = function() return {charge = {}} end,
                                 used = false}
package.loaded["arena.world"] = {
    build_overview = noop, forget_overview = noop,
    overview = function() return {grid = 0} end,
    radar_tiles = {}, radar_safe = {}, radar_doors = {},
    HULLS = setmetatable({}, {__index = function()
        return {poly = {0, 0, 1, 1, 2, 0}, mid = 0}
    end})}

local ui = require("arena.ui")

local ADDR = "play.vectorwake.net/discord"
local function view()
    return {
        rail = {}, title = "discord", depth = 1,
        discord = "https://" .. ADDR,
        door = true,
        door_why = "This game carries no chat, and will not. "
            .. "The room is where everything a fight cannot say gets said.",
        door_for = {
            "A match wants eight, and this is where they arrange to meet.",
            "What broke is read by the people who wrote it.",
            "Hulls, maps and rules are argued about here before they exist.",
        },
        door_addr = ADDR,
        rows = {{label = "open the invite", act = "discord", pick = true}},
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

-- --- the house grammar ----------------------------------------------------

-- A group heading in this interface is a hairline with a small dim label
-- under it. Three groups, three rules, each one above its own label.
local rules = {}
for _, s in ipairs(segs) do
    if math.abs(s.y0 - s.y1) < 0.5 and s.x1 - s.x0 > 100 and s.y0 > 150 then
        rules[#rules + 1] = s
    end
end
check("the page is in three groups", #rules == 3, #rules .. " rules")
local labels = {}
for _, t in ipairs(texts(st)) do
    if t.s == string.upper(t.s) and #t.s > 4 and (t.x or 0) > 150 then
        labels[#labels + 1] = {y = H - t.y, s = t.s}
    end
end
local paired = 0
for _, r in ipairs(rules) do
    for _, l in ipairs(labels) do
        if l.y > r.y0 and l.y - r.y0 < 24 then paired = paired + 1 break end
    end
end
check("and every rule has its label under it, not over it",
      paired == #rules, paired .. " of " .. #rules)

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
