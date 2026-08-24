-- A pilot on a run, in gold that moves.
--
--     lua5.1 client/tests/streak_test.lua
--
-- Three kills without dying and the arena says so: a shimmering line in the
-- feed, a shimmering hull, and a sound. None of that is visible in a
-- screenshot of one frame, because the whole point of it is that it moves, so
-- it is measured here against the real `pal.gleam`, the real `M.hud` and the
-- real `world.ship` with the engine stubbed out.
--
-- What is actually at risk is subtler than "does it draw". Gold that does not
-- move is a sixth feed line in an odd color. Gold that leaves its two ends is
-- a color the palette never chose. And a hull effect that draws for every ship
-- rather than for the one on a streak is the arena telling you nothing at all,
-- loudly. Each of those is arithmetic, and each is checked below.

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

local pal = require("arena.palette")

-- --- the gleam itself ------------------------------------------------------
--
-- Two ends and a clock. Every color it hands back has to lie between them, or
-- a hull on a streak is drawn in a hue nobody picked; and over a second it has
-- to reach both, or it is not a shimmer.

local lo, hi = math.huge, -math.huge
local strayed = false
for i = 0, 200 do
    local c = pal.gleam(i / 100, 1)
    for ch = 1, 3 do
        local a, b = pal.STREAK[ch], pal.STREAK_HI[ch]
        if a > b then a, b = b, a end
        if c[ch] < a - 1e-9 or c[ch] > b + 1e-9 then strayed = true end
    end
    -- The red channel is the one the two ends differ least on, so it is the
    -- honest one to measure the travel against.
    if c[1] < lo then lo = c[1] end
    if c[1] > hi then hi = c[1] end
end
check("a gleam never leaves the two golds it runs between", not strayed)
check("and over two seconds it reaches both ends",
      math.abs(lo - math.min(pal.STREAK[1], pal.STREAK_HI[1])) < 0.02
          and math.abs(hi - math.max(pal.STREAK[1], pal.STREAK_HI[1])) < 0.02,
      lo .. " to " .. hi)
check("its alpha is the caller's", pal.gleam(0.3, 0.25)[4] == 0.25)

-- --- the feed line ---------------------------------------------------------

local layer = {}
local function noop() end
for _, name in ipairs({"arc", "bloom", "disc", "fan", "flush", "frame",
                       "glow_band", "halo", "outline", "quad", "rect",
                       "reset", "resize", "ring", "ring_fade", "seg",
                       "seg_fade", "seg_flat", "seg_glow", "skirt", "tri",
                       "tri_fade"}) do
    layer[name] = noop
end

-- Enough of a room for the hud to draw at all: it returns early on an empty
-- one, and every other number it asks for can be zero.
_G.sim = setmetatable({ship_count = function() return 1 end,
                       ship_alive = function() return 1 end}, {
    __index = function() return function() return 0 end end,
})
package.loaded["arena.state"] = {text = {}, n = 0, version = 0}
package.loaded["arena.touch"] = {
    layout = function() return {charge = {}} end,
    used = false,
}
package.loaded["arena.world"] = {
    build_overview = noop,
    forget_overview = noop,
    overview = function() return {grid = 0, rects = {}} end,
    radar_tiles = {},
    radar_safe = {},
    radar_doors = {},
}

local ui = require("arena.ui")

local W, H = 1280, 800

local function hud(feed, touching)
    package.loaded["arena.state"].n = 0
    ui.begin(layer, W, H, 1, touching or false, 0)
    ui.hud({
        me = 0,
        class_names = {"Apex"},
        menu_open = false,
        pilots = {[0] = {name = "you", label = "human"}},
        teams = {}, feed = feed, hurt = 0, charges = {},
        cam_x = 0, cam_y = 0, half_w = 640, half_h = 400,
        banner = "", lag = 4,
        stats = {lag = 4, lead = 2, err = 0, err_max = 0, rewind = 0,
                 snaps = 0, rx = 0, tx = 0},
        zone = "chaos",
        fps = 60, frame_ms = 16.7, rx_rate = 0, tx_rate = 0,
    })
    ui.finish()
end

-- What the interface published for a word, copied rather than referenced: the
-- text pool is reused frame to frame, so a reference kept across two frames is
-- the second frame twice.
local function drawn(word)
    local st = package.loaded["arena.state"]
    for k = 1, st.n do
        local t = st.text[k]
        if t.s == word then
            return {col = {t.col[1], t.col[2], t.col[3], t.col[4]}}
        end
    end
    return nil
end

-- Two lines with the same age, one shimmering and one not. Same clock, so
-- anything that separates them is the flag rather than the frame.
local function line(gleam, t)
    return {text = {" is on a streak of 3"}, t = t, gleam = gleam or nil}
end

hud({line(true, 0)})
local at_zero = drawn(" is on a streak of 3")
check("a streak line is drawn", at_zero ~= nil)
hud({line(true, 0.31)})
local later = drawn(" is on a streak of 3")
check("and its color has moved a third of a second later",
      at_zero and later and math.abs(at_zero.col[1] - later.col[1])
          + math.abs(at_zero.col[2] - later.col[2])
          + math.abs(at_zero.col[3] - later.col[3]) > 0.01,
      at_zero and later
          and (table.concat(at_zero.col, ",") .. " -> "
               .. table.concat(later.col, ",")))

hud({line(false, 0)})
local plain_a = drawn(" is on a streak of 3")
hud({line(false, 0.31)})
local plain_b = drawn(" is on a streak of 3")
check("an ordinary line holds still",
      plain_a and plain_b and math.abs(plain_a.col[1] - plain_b.col[1]) < 1e-9
          and math.abs(plain_a.col[2] - plain_b.col[2]) < 1e-9
          and math.abs(plain_a.col[3] - plain_b.col[3]) < 1e-9)

-- The phone's one line shimmers too. It is the same feed filtered to one
-- entry, and a streak that arrived in flat gold there would be the only place
-- in the game where the effect is missing.
local mine = line(true, 0.05)
mine.mine = true
hud({mine}, true)
local phone_a = drawn(" is on a streak of 3")
local mine2 = line(true, 0.36)
mine2.mine = true
hud({mine2}, true)
local phone_b = drawn(" is on a streak of 3")
check("the phone's single line shimmers as well",
      phone_a and phone_b and math.abs(phone_a.col[1] - phone_b.col[1])
          + math.abs(phone_a.col[2] - phone_b.col[2])
          + math.abs(phone_a.col[3] - phone_b.col[3]) > 0.01)

-- --- the hull --------------------------------------------------------------
--
-- Counted rather than pinned to geometry: what matters is that a streaking
-- hull grows an effect, that an ordinary one grows none of it, and that the
-- effect moves. `marks_test` and `hull_fit_test` are what hold the ship's own
-- shapes still.

package.loaded["arena.world"] = nil
package.loaded["arena.ui"] = nil
local world = require("arena.world")

local drawn_halos, drawn_discs, drawn_blooms
local function recorder()
    local w = {}
    setmetatable(w, {__index = function(_, k)
        if k == "halo" then
            return function(_, x, y, r, _, col)
                drawn_halos[#drawn_halos + 1] = {x = x, y = y, r = r,
                                                 col = {col[1], col[2],
                                                        col[3], col[4]}}
            end
        elseif k == "disc" then
            return function(_, x, y) drawn_discs[#drawn_discs + 1] = {x = x, y = y} end
        elseif k == "bloom" then
            return function(_, _, _, r, a) drawn_blooms[#drawn_blooms + 1] = {r = r, a = a} end
        end
        return function() end
    end})
    return w
end

local function ship(opts)
    drawn_halos, drawn_discs, drawn_blooms = {}, {}, {}
    local w = recorder()
    world.ship(w, w, 0, 500, 500, 0, {0.3, 0.8, 1, 1}, opts)
    return #drawn_halos, #drawn_discs, #drawn_blooms
end

local SPARKS = 7
local plain_halos, plain_discs, plain_blooms = ship({})
local gold_halos, gold_discs, gold_blooms = ship({gleam = 0.4})
check("a hull on a streak grows seven sparks",
      gold_halos - plain_halos == SPARKS and gold_discs - plain_discs == SPARKS,
      (gold_halos - plain_halos) .. " halos, "
          .. (gold_discs - plain_discs) .. " discs")
check("and one more bloom over it", gold_blooms - plain_blooms == 1)

-- The sparks are the seven the streak added, which is the tail of the list:
-- the block draws last. Picking them out by distance instead would collect
-- whichever lamp or engine halo the hull happens to carry out at that radius.
local function sparks(t)
    ship({gleam = t})
    local out = {}
    for i = plain_halos + 1, #drawn_halos do
        local h = drawn_halos[i]
        out[#out + 1] = {
            r = math.sqrt((h.x - 500) ^ 2 + (h.y - 500) ^ 2),
            a = math.atan2(h.y - 500, h.x - 500),
            col = h.col,
        }
    end
    return out
end
local first = sparks(0)
local turned = sparks(0.5)
check("the sparks clear the hull",
      #first == SPARKS and first[1].r > 14,
      #first == SPARKS and tostring(first[1].r) or (#first .. " sparks"))
check("and they turn", #first == SPARKS and #turned == SPARKS
          and math.abs(first[1].a - turned[1].a) > 1e-3,
      #first == SPARKS and #turned == SPARKS
          and (first[1].a .. " -> " .. turned[1].a) or "not seven sparks")
check("spread around the hull rather than stacked",
      #first == SPARKS and math.abs(first[1].a - first[2].a) > 1e-3
          and math.abs(first[2].a - first[3].a) > 1e-3)

-- A spark dims on its own clock but never goes out. Each one's faintest
-- moment over two seconds has to hold a real fraction of its brightest, or
-- the ring is back to strobing lamps: a spark at zero is a gap, and a gap
-- plus a bright opposite is the lopsided look this effect must not have.
do
    local floor_ok, detail = true, nil
    for k = 1, SPARKS do
        local lo2, hi2 = math.huge, 0
        for i = 0, 40 do
            local s = sparks(i * 0.05)[k]
            local a = s.col[4]
            if a < lo2 then lo2 = a end
            if a > hi2 then hi2 = a end
        end
        if not (lo2 > 0 and lo2 > 0.25 * hi2) then
            floor_ok = false
            detail = "spark " .. k .. " runs " .. lo2 .. " to " .. hi2
        end
    end
    check("every spark dims without going out", floor_ok, detail)
end

-- Gold, not the team color it was handed. A streak has to read the same
-- whichever side you are on, or it is a second question inside the one call a
-- pilot makes in a tenth of a second.
local hue = sparks(0.2)[1]
check("the sparks are gold rather than the hull's own color",
      hue and hue.col[1] > hue.col[3] and hue.col[1] > 0.8,
      hue and table.concat(hue.col, ",") or "no spark drawn")

-- --- the kit knows the sound -----------------------------------------------
--
-- sfx_test already proves every name in sfx.c has a component behind it. What
-- it cannot say is that this particular one is there, and an announcement
-- nobody hears is the failure mode with no symptom.
do
    local f = assert(io.open("client/ext/simcore/src/sfx.c"),
                     "run me from the repository root")
    local src = f:read("*a")
    f:close()
    check("the synth renders a streak alert",
          src:find('{"streak"', 1, true) ~= nil)
    local names = src:match("const char %*const sfx_names%[%] = {(.-)};")
    check("and it is in the list the client installs from",
          names and names:find('"streak"', 1, true) ~= nil)
end

if fails > 0 then
    print(fails .. " failed")
    os.exit(1)
end
print("all streak checks pass")
