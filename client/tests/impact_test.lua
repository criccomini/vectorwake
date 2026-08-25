-- What a hit looks like: the muzzle, the mark it leaves, and the hull.
--
--     lua5.1 client/tests/impact_test.lua
--
-- Firing used to be three sparks at the barrel and a noise, and being hit
-- used to be five sparks and a bar appearing. Neither said much, and neither
-- said it on the hull, which is where a pilot is already looking. So there is
-- now a flash at the muzzle, a mark where a round breaks on rock, a flare on
-- a hull that just took one, and an outline that grades as its energy goes.
--
-- Two of the last three effects this repository shipped were correct and
-- invisible, which every test they had passed. So the middle of this file
-- samples the real vector layer on a grid and asks the player's question:
-- how many pixels does this actually light up, and for how many frames.

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
local fx = require("arena.fx")

local COL = {1, 0.5, 0.2, 1}

-- --- the flash, as an effect ------------------------------------------------

local function bloom_stub()
    local g = {n = 0, hits = {}}
    function g:bloom(x, y, r, a) self.n = self.n + 1
        self.hits[#self.hits + 1] = {x = x, y = y, r = r, a = a} end
    function g:seg_fade() end
    function g:ring_fade() end
    return g
end

fx.reset()
fx.flash(300, 400, 15, 0.1, 0.5, COL, 0.5)
local g = bloom_stub()
fx.draw(g)
check("a flash draws", g.n == 1, tostring(g.n))
check("where it was put", g.hits[1] and g.hits[1].x == 300 and g.hits[1].y == 400)

-- It collapses rather than expanding. Growth is a shockwave's language, and
-- a muzzle that expanded would read as something going off at the barrel.
local first = g.hits[1]
for _ = 1, 3 do fx.update(1 / 60) end
g = bloom_stub()
fx.draw(g)
local later = g.hits[1]
check("and it shrinks as it dies", later and later.r < first.r,
      later and string.format("%.1f then %.1f", first.r, later.r))
check("dimming as it goes", later and later.a < first.a,
      later and string.format("%.3f then %.3f", first.a, later.a))

-- Alpha falls off linearly, not squared. Squared, a tenth-of-a-second flash
-- is bright for one frame and gone: the visibility measure below is what
-- caught that, and this is the rule it settled on, pinned here so a later
-- tidy-up does not quietly restore the wave's own curve.
check("half way through it is still half lit", later.a > first.a * 0.4,
      string.format("%.3f of %.3f", later.a, first.a))

for _ = 1, 12 do fx.update(1 / 60) end
g = bloom_stub()
fx.draw(g)
check("and it is gone when its life is up", g.n == 0, tostring(g.n))

-- A flash is a light like a blast is, so a gun fired in a corridor lights the
-- corridor. Strength falls with the flash rather than being held to the end.
fx.reset()
fx.flash(300, 400, 15, 0.1, 0.5, COL, 0.6)
local lit
fx.gather_lights(function(x, y, col, s, reach)
    lit = {x = x, y = y, col = col, s = s, r = reach}
end)
check("a flash declares itself a light", lit ~= nil)
check("at its own place, in its own color",
      lit and lit.x == 300 and lit.y == 400 and lit.col == COL)
check("reaching past its own edge", lit and lit.r > 15, lit and tostring(lit.r))
local born = lit.s
for _ = 1, 4 do fx.update(1 / 60) end
fx.gather_lights(function(_, _, _, s) lit.s = s end)
check("and dimming as the flash does", lit.s < born,
      string.format("%.3f then %.3f", born, lit.s))

-- Capped, because a sixty-four seat room firing at once is a real frame.
fx.reset()
for k = 1, 90 do fx.flash(k * 10, 0, 15, 0.1, 0.5, COL, 0.5) end
g = bloom_stub()
fx.draw(g)
check("the flash count is capped", g.n > 0 and g.n <= 24, tostring(g.n))

-- --- near ------------------------------------------------------------------

fx.listener(1000, 1000)
check("something under the camera is near", fx.near(1000, 1000, 500))
check("something across the arena is not", fx.near(4000, 1000, 500) == false)
check("and the radius is a radius, not a box",
      fx.near(1000 + 400, 1000 + 400, 500) == false)

-- --- can any of it be seen -------------------------------------------------
--
-- The real vector layer, writing into a recorded buffer, sampled on a grid.
-- Coverage is what a screen resolves a shape into, so lit area and the count
-- of frames it lasts are the two numbers a player actually experiences.

local tris = {}
_G.vwbuf = {
    attach = function() return 1 end,
    reset = function() tris = {} end,
    rebind = function() end,
    finish = function() end,
    tri = function(_, x1, y1, x2, y2, x3, y3, col)
        local a = col[4] or 1
        tris[#tris + 1] = {{x1, y1, a}, {x2, y2, a}, {x3, y3, a}}
    end,
    tri_fade = function(_, x1, y1, a1, x2, y2, a2, x3, y3, a3, col)
        local A = col[4] or 1
        tris[#tris + 1] = {{x1, y1, a1 * A}, {x2, y2, a2 * A}, {x3, y3, a3 * A}}
    end,
    quad = function(id, x1, y1, x2, y2, x3, y3, x4, y4, col)
        _G.vwbuf.tri(id, x1, y1, x2, y2, x3, y3, col)
        _G.vwbuf.tri(id, x1, y1, x3, y3, x4, y4, col)
    end,
    rect = function() end,
}
_G.buffer = {create = function() return {} end, VALUE_TYPE_FLOAT32 = 1}
_G.go = {get = function() return nil end}
_G.hash = function(s) return s end

local vec = require("render.vec")
local layer = vec.layer("#none", 4096)

-- The glow layer is additive, so overlapping triangles add rather than
-- replace: alpha at a point is the sum of what covers it, the way the screen
-- composites it.
local function alpha_at(px, py)
    local sum = 0
    for _, t in ipairs(tris) do
        local ax, ay, aa = t[1][1], t[1][2], t[1][3]
        local bx, by, ba = t[2][1], t[2][2], t[2][3]
        local cx, cy, ca = t[3][1], t[3][2], t[3][3]
        local d = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
        if math.abs(d) > 1e-12 then
            local u = ((by - cy) * (px - cx) + (cx - bx) * (py - cy)) / d
            local v = ((cy - ay) * (px - cx) + (ax - cx) * (py - cy)) / d
            local w = 1 - u - v
            if u >= 0 and v >= 0 and w >= 0 then
                sum = sum + u * aa + v * ba + w * ca
            end
        end
    end
    return sum
end

-- How wide the lit patch is, through its own middle, in pixels. Width rather
-- than area, because "big enough to see" is a claim about how many pixels
-- across a thing is and that is the number to state and check. Two-pixel
-- steps, so each lit sample stands for two pixels of screen.
local LIT = 0.1
local function lit_width(cx, cy, half)
    local n = 0
    for px = cx - half, cx + half, 2 do
        if alpha_at(px, cy) >= LIT then n = n + 1 end
    end
    return n * 2
end

-- A gun's muzzle, exactly as world.lua emits one: the flash a shot puts at
-- the barrel, drawn frame by frame until it dies. A hull is about
-- twenty-four pixels across, so a flash that measures the same is one a
-- pilot reads as coming off the ship rather than as a brighter pixel.
local MX, MY = 600, 600
local SEEN = 16          -- pixels across, below which nobody is going to
                         -- notice a tenth of a second of anything
fx.reset()
fx.flash(MX, MY, 15, 0.1, 0.5, pal.hot(pal.FRIEND, 0.55, 1), 0.5)
local peak, frames = 0, 0
for _ = 1, 12 do
    tris = {}
    fx.draw(layer)
    local wide = lit_width(MX, MY, 40)
    if wide > peak then peak = wide end
    if wide >= SEEN then frames = frames + 1 end
    fx.update(1 / 60)
end
check("a muzzle flash is about as wide as the ship firing it", peak >= 22,
      string.format("%d px across", peak))
-- Three frames is fifty milliseconds, which is about the floor for a flash
-- registering as one rather than as a dropped frame. It measures four.
check("and holds for several frames rather than one", frames >= 3,
      tostring(frames) .. " frames")

-- And it is at the barrel, not at the middle of the hull. world.lua puts the
-- flash ten pixels along the heading; the light has to be there and not
-- smeared evenly over both.
fx.reset()
fx.flash(MX, MY - 10, 15, 0.1, 0.5, pal.hot(pal.FRIEND, 0.55, 1), 0.5)
tris = {}
fx.draw(layer)
check("and the light is at the muzzle rather than the hull",
      alpha_at(MX, MY - 10) > alpha_at(MX, MY + 12) * 2,
      string.format("%.3f vs %.3f", alpha_at(MX, MY - 10),
                    alpha_at(MX, MY + 12)))

-- The mark a round leaves on rock lasts longer than the muzzle that sent it,
-- because it is a scorch rather than a discharge.
fx.reset()
fx.flash(MX, MY, 13, 0.16, 0.55, pal.hot(pal.INK, 0.4, 1), 0.4)
local mark_frames = 0
for _ = 1, 16 do
    tris = {}
    fx.draw(layer)
    if lit_width(MX, MY, 40) >= SEEN then mark_frames = mark_frames + 1 end
    fx.update(1 / 60)
end
check("an impact mark outlasts the muzzle", mark_frames > frames,
      mark_frames .. " frames vs " .. frames)

-- --- the light list keeps the loudest --------------------------------------

_G.sim = {solid = function(tx, ty) return tx == 10 and ty >= 0 and ty <= 20 end,
          tick = function() return 0 end}
local world = require("arena.world")

local function wall_stub()
    local w = {n = 0, best = 0}
    function w:seg_glow(_, _, _, _, _, a)
        self.n = self.n + 1
        if a > self.best then self.best = a end
    end
    return w
end

-- Ten weak lights fill the list, and then the blast goes off. Draw order is
-- exactly this: the engines add theirs while their hulls draw, and a blast
-- gathered first can still be pushed out by them once the caps are met the
-- other way round. What must not happen is the loudest thing on the field
-- being the one that is dropped.
world.lights_begin()
for _ = 1, 10 do world.light(140, 168, COL, 0.2, 60) end
local w = wall_stub()
world.wall_light(w)
local weak = w.best
world.light(140, 168, COL, 0.9, 60)
w = wall_stub()
world.wall_light(w)
check("a full light list makes room for a brighter light", w.best > weak * 4,
      string.format("%.3f then %.3f", weak, w.best))

-- And refuses a dimmer one, or the list would churn.
world.lights_begin()
for _ = 1, 10 do world.light(140, 168, COL, 0.9, 60) end
w = wall_stub()
world.wall_light(w)
local strong = w.n
world.light(140, 168, COL, 0.01, 60)
w = wall_stub()
world.wall_light(w)
check("and turns a dimmer one away", w.n == strong, w.n .. " vs " .. strong)

-- --- a hull remembers being hit --------------------------------------------

local now = 0
_G.sim.tick = function() return now end

check("a hull nobody has hit does not flare", world.hit_flash(3) == 0)
world.note_hit(3)
check("one that just took a round flares fully", world.hit_flash(3) == 1,
      tostring(world.hit_flash(3)))
now = 6
check("and fades as the moment passes",
      world.hit_flash(3) > 0 and world.hit_flash(3) < 1,
      tostring(world.hit_flash(3)))
now = 20
check("and is over soon after", world.hit_flash(3) == 0,
      tostring(world.hit_flash(3)))

-- Prediction rewinds and re-runs on every correction, so the tick goes
-- backwards. A flash that survived that would fire a second time.
now = 100
world.note_hit(4)
now = 90
check("a rewound clock does not flash twice", world.hit_flash(4) == 0,
      tostring(world.hit_flash(4)))

-- --- the outline says how the hull is doing --------------------------------

-- The silhouette's own strokes, and only those. A hull draws panel lines,
-- hardpoints and a canopy in the same call, some of them brighter than the
-- rim, so the run has to be picked out rather than sampled: it starts at the
-- glow bands that sit under the silhouette and ends at the canopy's fan.
local function silhouette(opts)
    local segs = {}
    local phase = 0
    local noop = function() end
    local fill = setmetatable({}, {__index = function() return noop end})
    local glow = setmetatable({
        glow_band = function() phase = 1 end,
        fan = function() if phase == 1 then phase = 2 end end,
        seg = function(_, _, _, _, _, width, col)
            if phase == 1 then
                segs[#segs + 1] = {r = col[1], g = col[2], b = col[3],
                                   a = col[4], w = width}
            end
        end,
    }, {__index = function() return noop end})
    world.lights_begin()
    world.ship(fill, glow, 0, 500, 500, 0, pal.FRIEND, opts)
    return segs
end

-- Two readings of the rim: how warm it is, and how much light it lays down.
local function warmth(opts)
    local segs = silhouette(opts)
    local best, warm = 0, 0
    for _, c in ipairs(segs) do
        if c.a > best then best, warm = c.a, c.r - c.b end
    end
    return warm
end

local function rim_ink(opts)
    local segs, total = silhouette(opts), 0
    for _, c in ipairs(segs) do total = total + c.a * c.w end
    return total
end

check("a hull draws a silhouette to read", #silhouette({}) > 2,
      tostring(#silhouette({})))

local healthy = warmth({})
local wounded = warmth({hurt = 1})
check("a healthy friendly rim is cool", healthy < 0,
      string.format("%.3f", healthy))
check("a hull down to nothing runs warm", wounded > 0,
      string.format("%.3f", wounded))
check("and grades in between",
      warmth({hurt = 0.5}) > healthy and warmth({hurt = 0.5}) < wounded,
      string.format("%.3f", warmth({hurt = 0.5})))

-- The team read survives it. A hurt friend is still cyan everywhere the eye
-- takes a side from: this changes one stroke, and that stroke was carrying
-- no information before.
local band
local noop = function() end
local fill2 = setmetatable({}, {__index = function() return noop end})
local glow2 = setmetatable({
    glow_band = function(_, _, _, _, _, col)
        band = band or {col[1], col[3]}
    end,
}, {__index = function() return noop end})
world.lights_begin()
world.ship(fill2, glow2, 0, 500, 500, 0, pal.FRIEND, {hurt = 1})
check("a hurt friend is still washed in its team color",
      band and band[2] > band[1],
      band and string.format("%.2f/%.2f", band[1], band[2]))

-- A fresh hit brightens rather than warming: taking a round is a moment,
-- being wounded is a state, and the two must not look like each other.
check("a hull that just took one lays down more light",
      rim_ink({flash = 1}) > rim_ink({}) * 1.5,
      string.format("%.2f then %.2f", rim_ink({}), rim_ink({flash = 1})))
check("and its rim stays cool while it does",
      warmth({flash = 1}) < 0, string.format("%.3f", warmth({flash = 1})))
check("so a flare is never mistaken for damage",
      warmth({flash = 1}) < wounded,
      string.format("%.3f vs %.3f", warmth({flash = 1}), wounded))

-- --- somebody else's gun ---------------------------------------------------
--
-- The fire event belongs to the one ship this client predicts, so every
-- muzzle world.lua drew was your own. Everyone else's gun was a sound and a
-- round already forty pixels out. `world.shots` is where a remote trigger is
-- worked out from a cooldown that rose, and it is now where their muzzle is
-- drawn too.

local SPECS = {
    [1] = {blast = 0, life = 300, level = 2},
    [2] = {blast = 400, life = 500, level = 1},
}
local room = {count = 2, cd = {[0] = 0, [1] = 0}}
local air = {}
_G.sim = {
    ship_count = function() return room.count end,
    ship_alive = function() return 1 end,
    ship_cooldown = function(i) return room.cd[i] end,
    ship_x = function() return 2000 end,
    ship_y = function() return 2000 end,
    ship_heading = function() return 0 end,
    ship_team = function() return 1 end,
    tick = function() return 0 end,
    spec_blast = function(id) return SPECS[id].blast end,
    spec_trigger = function() return 0 end,
    spec_life = function(id) return SPECS[id].life end,
    spec_level = function(id) return SPECS[id].level end,
    weapon_count = function() return #air end,
    weapon_at = function(i)
        local a = air[i + 1]
        return 0, 0, a[1], 0, 0, 1, 10, a[2], 0
    end,
}
world.forget_specs()

-- Ship 1 fires a gun: its cooldown rises and a round of spec 1 appears.
-- What a shot actually draws, not merely that something was queued: a flash
-- with no radius is still an entry in every list and still invisible, which
-- is the exact failure this whole file exists to catch.
local function fire(spec)
    air = {}
    room.cd[1] = 0
    world.shots(0, function() end)
    air = {{spec, 1}}
    room.cd[1] = 40
    fx.reset()
    world.shots(0, function() end)
    local b = bloom_stub()
    fx.draw(b)
    return b.hits
end

fx.listener(2000, 2000)
local shot = fire(1)
check("a stranger's gun puts a flash at their barrel", #shot == 1,
      tostring(#shot))
check("wide enough to see", shot[1] and shot[1].r >= 11 and shot[1].a > 0.2,
      shot[1] and string.format("r %.0f a %.2f", shot[1].r, shot[1].a))
-- The heading points at -y, so the barrel is above the hull, not on it.
check("and at the barrel rather than the hull",
      shot[1] and shot[1].y == 1990, shot[1] and tostring(shot[1].y))
local bombed = fire(2)
check("a stranger's bomb flashes wider than their gun",
      #bombed == 1 and bombed[1].r > shot[1].r,
      #bombed == 1 and string.format("%.0f vs %.0f", bombed[1].r, shot[1].r))

-- But not from across the arena: sixty seats of off-screen muzzle would
-- spend the particle budget on things nobody can see.
fx.listener(20000, 20000)
check("a shot across the arena draws nothing", #fire(1) == 0,
      tostring(#fire(1)))

-- And a quiet trigger draws nothing wherever the camera is.
fx.listener(2000, 2000)
air = {{1, 1}}
room.cd[1] = 40
world.shots(0, function() end)
fx.reset()
world.shots(0, function() end)
local qb = bloom_stub()
fx.draw(qb)
local quiet = #qb.hits
check("a trigger nobody pulled draws nothing", quiet == 0, tostring(quiet))

-- --- the events that set all this off --------------------------------------
--
-- Everything above tests the effect. This tests the wiring, which is the half
-- that has actually broken here: an effect written, measured, shipped and
-- never called is the shape of two of the last three of these.

local EV = {FIRE = 1, EXPIRE = 2, HIT = 3}
local queue = {}
_G.sim = {
    EV_FIRE = EV.FIRE, EV_EXPIRE = EV.EXPIRE, EV_HIT = EV.HIT,
    EV_DEATH = 90, EV_SPAWN = 91, EV_BOUNCE = 92, EV_CHARGE = 93,
    EV_FLAG_TAKE = 95,
    TRIG_GUN = 0, TRIG_BOMB = 1,
    tick = function() return 500 end,
    event_count = function() return #queue end,
    event_at = function(i)
        local e = queue[i + 1]
        return e[1], e[2], e[3], e[4]
    end,
    ship_count = function() return 2 end,
    ship_x = function() return 2000 end,
    ship_y = function() return 2000 end,
    ship_x_raw = function() return 2000 end,
    ship_y_raw = function() return 2000 end,
    ship_heading = function() return 0 end,
    ship_team = function() return 1 end,
    ship_level = function() return 1 end,
    ship_max_energy = function() return 1000 end,
    spec_blast = function(id) return SPECS[id].blast end,
    spec_level = function(id) return SPECS[id].level end,
    spec_life = function(id) return SPECS[id].life end,
}
world.forget_specs()

local function fired(ev)
    queue = {ev}
    fx.reset()
    world.events(0, function() end)
    local b = bloom_stub()
    fx.draw(b)
    return b.hits
end

-- A flash worth the name: somewhere near the size of the hull that made it,
-- and bright enough to stand off the fill.
local function seen(hits)
    return #hits == 1 and hits[1].r >= 11 and hits[1].a > 0.2
end

-- Your own shot. The muzzle sits ten pixels along the heading, which points
-- at -y, so the flash is above the hull rather than on it.
local own = fired({EV.FIRE, 0, 1, 0})
check("your own gun puts a flash at its muzzle", seen(own),
      own[1] and string.format("r %.0f a %.2f", own[1].r, own[1].a))
check("ten pixels ahead of the hull that fired it",
      own[1] and own[1].y == 1990, own[1] and tostring(own[1].y))

-- A round breaking on rock. The payload packs the position into two
-- fourteen-bit halves, and `b` past the seat count means it ended on terrain.
local mark = fired({EV.EXPIRE, 1, 9, 1200 * 16384 + 1300})
check("a round breaking on rock leaves a mark", seen(mark),
      mark[1] and string.format("r %.0f a %.2f", mark[1].r, mark[1].a))
check("where it broke", mark[1] and mark[1].x == 1200 and mark[1].y == 1300,
      mark[1] and (mark[1].x .. "," .. mark[1].y))

-- And a hull taking one, which both flashes at the point of impact and
-- leaves the hull itself lit for a moment.
local struck = fired({EV.HIT, 1, 0, 200})
check("a hull taking a round flashes", seen(struck),
      struck[1] and string.format("r %.0f a %.2f", struck[1].r, struck[1].a))
check("and the hull remembers it", world.hit_flash(1) == 1,
      tostring(world.hit_flash(1)))
check("while the one beside it does not", world.hit_flash(0) == 0,
      tostring(world.hit_flash(0)))

if fails > 0 then
    print(fails .. " failed")
    os.exit(1)
end
print("all ok")
