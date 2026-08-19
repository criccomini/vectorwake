-- Effects: the part of the picture the simulation does not know about.
--
-- Every one of these is triggered by an event the core reported and decides
-- nothing. A blast is drawn where the core said a bomb stopped existing, for
-- as long as it looks right, and if the client drew none of it the game would
-- play identically. That is the line, and it is why this file can be as loose
-- with time as it likes: it runs on frame time, not on ticks.
--
-- The vocabulary is deliberately small, because docs/design/identity.md asks
-- for effects that are "additive, brief, and cheap": an expanding ring, a
-- fading halo, and a spray of shards. Nothing lingers long enough to hide a
-- ship.

local pal = require("arena.palette")

local M = {}

local MAX_PARTS = 320
local MAX_WAVES = 48
local MAX_DEBRIS = 96

local parts = {}   -- {x, y, vx, vy, age, life, size, col, drag}
local waves = {}   -- {x, y, r0, r1, age, life, width, col, kind}
local debris = {}  -- {x, y, vx, vy, ang, spin, len, age, life, col}
local np, nw, nd = 0, 0, 0

local shake = 0
local shake_x, shake_y = 0, 0
local seed = 20260801

-- A deterministic-enough generator of our own. math.random is shared state,
-- and the bots draw from it on the same frames; a renderer must never be able
-- to move the simulation's dice.
local function rnd()
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed / 2147483648
end

function M.reset()
    np, nw, nd, shake = 0, 0, 0, 0
end

-- --- emitters --------------------------------------------------------------

-- An expanding ring. The blast radius the core used for the damage is the
-- radius this stops at, so the picture and the rule agree.
function M.wave(x, y, r0, r1, life, width, col)
    if nw >= MAX_WAVES then return end
    nw = nw + 1
    waves[nw] = {x = x, y = y, r0 = r0, r1 = r1, age = 0, life = life,
                 width = width, col = col}
end

function M.spark(x, y, vx, vy, life, size, col, drag)
    if np >= MAX_PARTS then return end
    np = np + 1
    parts[np] = {x = x, y = y, vx = vx, vy = vy, age = 0, life = life,
                 size = size, col = col, drag = drag or 0.94}
end

-- A spray in every direction, with speed and lifetime spread so the edge of
-- the burst is ragged rather than a circle of identical dots.
function M.burst(x, y, count, speed, life, size, col, vx0, vy0)
    vx0, vy0 = vx0 or 0, vy0 or 0
    for _ = 1, count do
        local a = rnd() * math.pi * 2
        local s = speed * (0.35 + rnd() * 0.65)
        M.spark(x, y, vx0 + math.cos(a) * s, vy0 + math.sin(a) * s,
                life * (0.5 + rnd() * 0.7), size, col)
    end
end

-- Hull fragments: line shards that tumble away and burn out. A point reads
-- as a spark whatever its size; a ship coming apart needs pieces with
-- length, spinning, or the hull just vanishes into confetti.
function M.shards(x, y, count, speed, life, len, col, vx0, vy0)
    vx0, vy0 = vx0 or 0, vy0 or 0
    for _ = 1, count do
        if nd >= MAX_DEBRIS then return end
        nd = nd + 1
        local a = rnd() * math.pi * 2
        local s = speed * (0.3 + rnd() * 0.7)
        debris[nd] = {x = x, y = y,
                      vx = vx0 + math.cos(a) * s, vy = vy0 + math.sin(a) * s,
                      ang = rnd() * math.pi * 2, spin = (rnd() - 0.5) * 16,
                      len = len * (0.6 + rnd() * 0.8), age = 0,
                      life = life * (0.6 + rnd() * 0.7), col = col}
    end
end

-- A cone, for a muzzle: heading in radians, spread in radians either side.
function M.cone(x, y, dir, spread, count, speed, life, size, col)
    for _ = 1, count do
        local a = dir + (rnd() - 0.5) * spread * 2
        local s = speed * (0.4 + rnd() * 0.6)
        M.spark(x, y, math.sin(a) * s, -math.cos(a) * s,
                life * (0.5 + rnd() * 0.6), size, col)
    end
end

-- A bomb going off: hot core, shockwave out to the real blast radius, and
-- shards that outrun both.
function M.detonate(x, y, radius, col)
    M.wave(x, y, radius * 0.12, radius, 0.42, radius * 0.16, pal.hot(col, 0.5, 1))
    M.wave(x, y, radius * 0.05, radius * 0.55, 0.22, radius * 0.3, pal.hot(col, 0.8, 1))
    M.burst(x, y, 14, radius * 3.4, 0.5, 2.2, col)
    M.burst(x, y, 6, radius * 1.5, 0.75, 1.4, pal.hot(col, 0.7, 1))
    M.jolt(0.55, x, y)
end

-- A ship coming apart: the one event in this game allowed a full second of
-- attention, and the one that has to read as an explosion rather than as a
-- large spark. In order of arrival: a white flash felt before it is read,
-- the fireball, two shockwaves, the hull leaving as spinning pieces, and
-- embers that outlive everything else. The pieces inherit the ship's
-- velocity, so a hull at speed dies along its own course instead of
-- stopping dead to explode.
function M.destroy(x, y, vx, vy, col)
    M.wave(x, y, 2, 24, 0.16, 15, pal.WHITE)
    M.wave(x, y, 4, 96, 0.6, 10, pal.hot(col, 0.45, 1))
    M.wave(x, y, 2, 44, 0.32, 14, pal.hot(col, 0.85, 1))
    M.shards(x, y, 10, 160, 1.1, 9, col, vx * 60, vy * 60)
    M.shards(x, y, 5, 60, 1.7, 6, pal.hot(col, 0.5, 1), vx * 60, vy * 60)
    M.burst(x, y, 30, 210, 0.8, 2.6, pal.hot(col, 0.65, 1), vx * 60, vy * 60)
    M.burst(x, y, 14, 75, 1.8, 1.5, col, vx * 60, vy * 60)
    M.jolt(1.15, x, y)
end

-- Camera shake, attenuated by distance from whoever is watching. Set the
-- listener first; an explosion across the arena must not rattle the screen.
local lx, ly = 0, 0
function M.listener(x, y) lx, ly = x, y end

function M.jolt(amount, x, y)
    if x then
        local dx, dy = x - lx, y - ly
        local d = math.sqrt(dx * dx + dy * dy)
        amount = amount * math.max(0, 1 - d / 620)
    end
    if amount > shake then shake = amount end
end

-- --- update ----------------------------------------------------------------

function M.update(dt)
    if dt > 0.1 then dt = 0.1 end
    local i = 1
    while i <= np do
        local p = parts[i]
        p.age = p.age + dt
        if p.age >= p.life then
            parts[i] = parts[np]
            parts[np] = nil
            np = np - 1
        else
            local k = p.drag ^ (dt * 60)
            p.x = p.x + p.vx * dt
            p.y = p.y + p.vy * dt
            p.vx = p.vx * k
            p.vy = p.vy * k
            i = i + 1
        end
    end

    i = 1
    while i <= nd do
        local p = debris[i]
        p.age = p.age + dt
        if p.age >= p.life then
            debris[i] = debris[nd]
            debris[nd] = nil
            nd = nd - 1
        else
            -- Heavier than a spark, so it coasts further and spins down as
            -- it goes, the way a thrown thing does.
            local k = 0.965 ^ (dt * 60)
            p.x = p.x + p.vx * dt
            p.y = p.y + p.vy * dt
            p.vx = p.vx * k
            p.vy = p.vy * k
            p.ang = p.ang + p.spin * dt
            p.spin = p.spin * (0.985 ^ (dt * 60))
            i = i + 1
        end
    end

    i = 1
    while i <= nw do
        local w = waves[i]
        w.age = w.age + dt
        if w.age >= w.life then
            waves[i] = waves[nw]
            waves[nw] = nil
            nw = nw - 1
        else
            i = i + 1
        end
    end

    if shake > 0 then
        shake = shake - dt * 2.4
        if shake < 0 then shake = 0 end
        local a = rnd() * math.pi * 2
        local m = shake * shake * 9
        shake_x, shake_y = math.cos(a) * m, math.sin(a) * m
    else
        shake_x, shake_y = 0, 0
    end
end

function M.shake_offset()
    return shake_x, shake_y
end

-- --- draw ------------------------------------------------------------------

-- One table, filled and handed over, for every colour this file passes down.
--
-- The layer's calls read a colour during the call and keep no reference to it,
-- which is what makes this safe and is the same bargain vec.lua's own dimming
-- scratch relies on. A fresh table per particle meant up to four hundred and
-- sixty of them a frame, all garbage, arriving exactly when two explosions
-- overlap and the frame is already at its heaviest.
local tint = {0, 0, 0, 0}
local function faded(col, alpha)
    tint[1], tint[2], tint[3], tint[4] = col[1], col[2], col[3], alpha
    return tint
end

-- `light`, when given, is told about each live shockwave so the walls can
-- catch the flash: world.light, passed in by the arena rather than required
-- here, since this file draws effects and owes the terrain nothing.
function M.draw(glow, light)
    for i = 1, nw do
        local w = waves[i]
        local t = w.age / w.life
        local r = w.r0 + (w.r1 - w.r0) * (1 - (1 - t) * (1 - t))  -- ease out
        local fade = 1 - t
        local col = w.col
        glow:ring_fade(w.x, w.y, r, w.width * (0.35 + fade * 0.65),
                       24, faded(col, col[4] * fade * fade))
        if light then
            light(w.x, w.y, col, fade * fade * 0.9, r + 30)
        end
    end

    for i = 1, np do
        local p = parts[i]
        local t = p.age / p.life
        local fade = 1 - t
        local col = p.col
        -- A shard is drawn along its own velocity, so a fast one is a streak
        -- and a dying one is a dot. That single rule does most of the work.
        local sx, sy = p.vx * 0.016, p.vy * 0.016
        glow:seg_fade(p.x - sx, p.y - sy, p.x, p.y,
                      p.size * 0.3, p.size * fade, 0, 1, faded(col, col[4] * fade))
    end

    for i = 1, nd do
        local p = debris[i]
        local t = p.age / p.life
        local fade = 1 - t
        local col = p.col
        -- A piece of hull is drawn along its own angle, not its velocity:
        -- tumbling free of its course is what tells it apart from a spark.
        local h = p.len * (0.4 + 0.6 * fade) / 2
        local ca, sa = math.cos(p.ang), math.sin(p.ang)
        glow:seg_fade(p.x - ca * h, p.y - sa * h, p.x + ca * h, p.y + sa * h,
                      0.8, 1.5, fade * 0.45, fade, faded(col, col[4] * fade))
    end
end

return M
