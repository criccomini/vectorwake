-- Drawing the world.
--
-- Ships, weapons, flags, prizes, stars and terrain, in the two world layers:
-- a dark alpha fill that occludes what is behind it, and an additive glow
-- that carries every bright edge. Nothing here reads input or advances
-- anything; it asks the simulation what is true and describes it in
-- triangles.
--
-- The look is the one docs/design/identity.md asks for: bright geometric
-- silhouettes on a near-black field, thin outlines over a darker fill, bolts
-- with sharp falloff and short trails, blasts that bloom into rings rather
-- than fireballs.

local pal = require("arena.palette")
local fx = require("arena.fx")

local M = {}

local TILE = 16
local TAU = math.pi * 2

-- Hulls, in local pixels with the nose along +y. Shape carries class and
-- colour carries team, so neither has to carry both, and every class has to be
-- identifiable by silhouette alone at radar scale -- which means each one
-- needs a front that is visibly not its back. See docs/design/ships.md.
--
-- `spine` is the interior detail: line pairs that give a hull a read at close
-- range without adding a second silhouette. `jets` are where thrust comes out.
M.HULLS = {
    -- Apex: a swept dart. Fastest and sharpest turn in the game.
    {poly = {0,17, 5,-2, 9,-10, 0,-5, -9,-10, -5,-2},
     spine = {0,11, 0,1}, jets = {0,-5}},
    -- Wedge: a flat wide triangle. It reads as a platform, not a fighter.
    {poly = {0,11, 6,2, 14,-8, 5,-5, -5,-5, -14,-8, -6,2},
     spine = {-4,-3, 4,-3}, jets = {-6,-5, 6,-5}},
    -- Chord: a wide shallow arc, hollow at the back.
    {poly = {0,12, 9,8, 16,-1, 9,-3, 0,2, -9,-3, -16,-1, -9,8},
     spine = {0,9, 0,3}, jets = {-6,-1, 6,-1}},
    -- Anvil: a blunt hexagon. The front is a flat face, not a point: nothing
    -- about this ship should look sharp.
    {poly = {-7,13, 7,13, 12,4, 10,-9, -10,-9, -12,4},
     spine = {-6,7, 6,7}, jets = {-5,-9, 5,-9}},
    -- Spire: a tall diamond carrying a mast, which is where the turrets go.
    {poly = {0,19, 3,9, 7,0, 3,-11, -3,-11, -7,0, -3,9},
     spine = {0,15, 0,-7}, jets = {0,-11}},
    -- Cipher: a thin sliver, barely there.
    {poly = {0,18, 3,0, 2,-8, 0,-11, -2,-8, -3,0},
     spine = {0,12, 0,-6}, jets = {0,-11}},
    -- Facet: a compact pentagon with a real nose on it.
    {poly = {0,13, 10,3, 7,-10, -7,-10, -10,3},
     spine = {-4,6, 4,6}, jets = {-4,-10, 4,-10}},
    -- Lattice: a cross. It owns terrain, and it should look like a marker
    -- planted in it. The forward arm is longest so the shape still points.
    {poly = {-3,15, 3,15, 3,4, 13,4, 13,-2, 3,-2, 3,-12,
             -3,-12, -3,-2, -13,-2, -13,4, -3,4},
     spine = {0,11, 0,-9}, jets = {0,-12}},
}

-- The centroid of each hull, so a fill can fan from inside the shape. Fanning
-- from a vertex double-covers a concave hull -- the cross especially -- and
-- the overlap shows as a darker wedge through the middle of the ship.
for _, h in ipairs(M.HULLS) do
    local sx, sy, n = 0, 0, #h.poly / 2
    for i = 1, #h.poly, 2 do sx, sy = sx + h.poly[i], sy + h.poly[i + 1] end
    h.cx, h.cy = sx / n, sy / n
    h.tmp = {}
end

-- --- the starfield ---------------------------------------------------------
--
-- Depth, from parallax, without storing a single star.
--
-- Each layer is an infinite grid of cells with at most one star in each,
-- placed by hashing the cell's own coordinates. Nothing is kept between
-- frames and the field extends as far as anyone can fly, so a map twice the
-- size costs exactly the same.
--
-- A layer at depth `k` puts a star whose base position is `b` at the world
-- position `b + cam*(1 - k)`, which lands on screen at `b - cam*k`. So `k` is
-- literally how fast the layer moves against the camera: 1 is the arena's own
-- plane, 0 is painted on the glass. The visible cells are the ones whose base
-- falls within a half-extent of `cam*k`, which is the only arithmetic here.
--
-- They were world-locked and built once before this, on the reasoning that a
-- parallax layer would slide against the terrain and read as a bug. It reads
-- as distance, which is the entire reason to have stars at all.

local STARS = {
    -- depth, cell size in world px, star size, colour, how many cells in
    -- sixteen carry one. Farther is denser, smaller and dimmer, which is what
    -- distance does.
    {k = 0.18, cell =  54, size = 1.1, col = pal.STAR_FAR,  fill = 13},
    {k = 0.36, cell =  92, size = 1.6, col = pal.STAR,      fill = 11},
    {k = 0.60, cell = 168, size = 2.3, col = pal.STAR_NEAR, fill =  9},
}

-- Lehmer, and the multiplier matters: Lua has no integers here, and the
-- 1103515245 everything else uses overflows a double's exact range on a
-- 31-bit seed, throwing away the low bits. 48271 stays exact, which is what
-- keeps a hashed grid from banding.
local function lcg(s)
    return (s * 48271) % 2147483647
end

-- Eight brightnesses per layer, made once. A star's alpha used to be a fresh
-- {r,g,b,a} per star per frame -- three hundred and fifty tables a frame,
-- twenty thousand a second, all of them garbage -- and at a pixel and a half
-- across nobody can tell an eighth of a step of alpha from a sixteenth.
local STAR_SHADES = 8
for _, L in ipairs(STARS) do
    L.shade = {}
    for i = 1, STAR_SHADES do
        L.shade[i] = pal.a(L.col, 0.45 + (i - 1) / (STAR_SHADES - 1) * 0.55)
    end
    L.bloom = pal.a(L.col, 0.30)
end

function M.stars(fill, glow, cam_x, cam_y, hw, hh)
    for li = 1, #STARS do
        local L = STARS[li]
        local c = L.cell
        -- Where this layer sits in the world, and which of its cells are on
        -- screen.
        local ox, oy = cam_x * (1 - L.k), cam_y * (1 - L.k)
        local bx, by = cam_x * L.k, cam_y * L.k
        local i0, i1 = math.floor((bx - hw) / c), math.floor((bx + hw) / c)
        local j0, j1 = math.floor((by - hh) / c), math.floor((by + hh) / c)
        local size, shade = L.size, L.shade
        local bloom = L.k > 0.5 and L.bloom or nil
        for j = j0, j1 do
            for i = i0, i1 do
                local s = lcg((i * 1973 + j * 9277 + li * 26699) % 2147483646 + 1)
                if s % 16 < L.fill then
                    s = lcg(s)
                    local px = (i + s / 2147483647) * c + ox
                    s = lcg(s)
                    local py = (j + s / 2147483647) * c + oy
                    -- A star behind rock is a star shining through it: the
                    -- wall interiors live in a layer under this one.
                    if not sim.solid(math.floor(px / TILE), math.floor(py / TILE)) then
                        s = lcg(s)
                        fill:rect(px, py, size, size,
                                  shade[s % STAR_SHADES + 1])
                        -- One in a while is close enough to bloom. Additive,
                        -- so it reads as light rather than a bigger dot.
                        if bloom and s % 17 == 0 then
                            glow:halo(px + size / 2, py + size / 2, 5, 8, bloom)
                        end
                    end
                end
            end
        end
    end
end

-- --- static terrain --------------------------------------------------------
--
-- Walls never move, so they are built once per map into their own buffers and
-- never touched again. A per-frame rebuild of a thousand tiles was the single
-- largest thing the old renderer did, and it did it every frame.

-- Terrain for the radar, sampled once. At the radar's scale a hundred and
-- fifty tiles cross a hundred and sixty-eight pixels, so one dot every four
-- tiles is already denser than the display can show, and it turns a
-- thousand-tile scan per frame into a list of seventy.
M.radar_tiles = {}
M.radar_safe = {}
M.radar_doors = {}

-- Doors and wormholes, found once per map.
--
-- This used to be a scan: every tile in the arena, every frame, asking the
-- core what class it was. Eighty-nine tiles square is seven thousand nine
-- hundred crossings into C to find four doors, and it cost more than the
-- simulation it was drawing. The tiles do not move, so the search is a
-- property of the map and belongs where the walls are built.
M.moving_tiles = {}

local function index_moving(lo, hi)
    local out = {}
    for ty = lo - 2, hi + 2 do
        for tx = lo - 2, hi + 2 do
            local cls, variant = sim.tile(tx, ty)
            if cls == sim.T_DOOR or cls == sim.T_WORMHOLE then
                out[#out + 1] = {tx = tx, ty = ty, cls = cls, variant = variant}
            end
        end
    end
    M.moving_tiles = out
end

-- Made once, not per tile per frame: these are constants wearing a function's
-- clothes, and allocating them in a draw loop is what a garbage collector
-- notices first.
local DOOR_GHOST = pal.a(pal.WALL_EDGE, 0.30)
local DOOR_LIT = pal.a(pal.ENEMY, 0.75)
local HOLE_RING = {pal.a(pal.BOMB, 0.34), pal.a(pal.BOMB, 0.17),
                   pal.a(pal.BOMB, 0.34 / 3)}

function M.build_static(bg, glow, lo, hi)
    bg:reset()
    glow:reset()

    -- The doors and wormholes, found once here rather than searched for on
    -- every frame that draws them.
    index_moving(lo, hi)

    -- Every second tile, not every fourth. The arena's outer walls are two
    -- tiles thick, so a four-tile stride aliased them away completely and the
    -- map read as a scatter of unrelated dots.
    --
    -- Safe zones and doors get their own lists: they are the two things worth
    -- steering by, and they were not on the radar at all.
    local rt, rs, rd = {}, {}, {}
    for ty = lo - 2, hi + 2, 2 do
        for tx = lo - 2, hi + 2, 2 do
            local cls = sim.tile(tx, ty)
            local out = (cls == sim.T_SOLID and rt)
                or (cls == sim.T_SAFE and rs)
                or (cls == sim.T_DOOR and rd)
            if out then
                out[#out + 1] = tx * TILE
                out[#out + 1] = ty * TILE
            end
        end
    end
    M.radar_tiles = rt
    M.radar_safe = rs
    M.radar_doors = rd

    -- Wall bodies, and a lit edge only on the faces that touch open space.
    -- Drawing every tile's border outlines the grid inside a solid block,
    -- which turns a wall into graph paper. The edge gets the same two-stroke
    -- treatment a hull does, so terrain glows rather than being merely
    -- outlined -- and since it is built once, the second stroke is free.
    local edge = pal.a(pal.WALL_EDGE, 1)
    local spill = pal.a(pal.WALL_EDGE, 0.16)
    local function face(x1, y1, x2, y2)
        glow:seg(x1, y1, x2, y2, 7, spill)
        glow:seg(x1, y1, x2, y2, 1.6, edge)
    end
    for ty = lo - 2, hi + 2 do
        for tx = lo - 2, hi + 2 do
            if sim.solid(tx, ty) then
                local x, y = tx * TILE, ty * TILE
                bg:rect(x, y, TILE, TILE, pal.WALL)
                if not sim.solid(tx, ty - 1) then face(x, y, x + TILE, y) end
                if not sim.solid(tx, ty + 1) then
                    face(x, y + TILE, x + TILE, y + TILE)
                end
                if not sim.solid(tx - 1, ty) then face(x, y, x, y + TILE) end
                if not sim.solid(tx + 1, ty) then
                    face(x + TILE, y, x + TILE, y + TILE)
                end
            end
        end
    end

    -- Safe zones. Static, because they never move -- a hatched floor and a
    -- lit border, so it reads as a place rather than as a coloured patch.
    local safe_fill = pal.a(pal.FRIEND, 0.07)
    local safe_edge = pal.a(pal.FRIEND, 0.55)
    for ty = lo - 2, hi + 2 do
        for tx = lo - 2, hi + 2 do
            if sim.tile(tx, ty) == sim.T_SAFE then
                local x, y = tx * TILE, ty * TILE
                bg:rect(x, y, TILE, TILE, safe_fill)
                -- Only the outside faces, or the interior turns to graph
                -- paper the way the walls did.
                if sim.tile(tx, ty - 1) ~= sim.T_SAFE then
                    glow:seg(x, y, x + TILE, y, 1.2, safe_edge)
                end
                if sim.tile(tx, ty + 1) ~= sim.T_SAFE then
                    glow:seg(x, y + TILE, x + TILE, y + TILE, 1.2, safe_edge)
                end
                if sim.tile(tx - 1, ty) ~= sim.T_SAFE then
                    glow:seg(x, y, x, y + TILE, 1.2, safe_edge)
                end
                if sim.tile(tx + 1, ty) ~= sim.T_SAFE then
                    glow:seg(x + TILE, y, x + TILE, y + TILE, 1.2, safe_edge)
                end
            end
        end
    end

    bg:flush()
    glow:flush()
end

-- Doors and the tiles that mark a place rather than block one. These cannot
-- go in the static mesh: a door is a wall on a clock, and a wall nobody can
-- see is the worst thing in the game.
function M.draw_tiles(fill, glow)
    local list = M.moving_tiles
    for n = 1, #list do
        local t = list[n]
        if t.cls == sim.T_DOOR then
            local x, y = t.tx * TILE, t.ty * TILE
            if sim.door_open(t.variant) then
                -- Open: the frame stays, so a pilot can see where it will be
                -- when it shuts, and time the crossing.
                glow:seg(x, y, x, y + TILE, 1.0, DOOR_GHOST)
                glow:seg(x + TILE, y, x + TILE, y + TILE, 1.0, DOOR_GHOST)
            else
                fill:rect(x, y, TILE, TILE, pal.WALL)
                glow:seg(x, y, x + TILE, y, 1.4, DOOR_LIT)
                glow:seg(x, y + TILE, x + TILE, y + TILE, 1.4, DOOR_LIT)
            end
        else
            local cx, cy = t.tx * TILE + TILE / 2, t.ty * TILE + TILE / 2
            -- Three rings falling off outward, which is what the pull does:
            -- something to read the reach of before entering it.
            for r = 1, 3 do
                glow:ring(cx, cy, r * 9, 1.0, 18, HOLE_RING[r])
            end
        end
    end
end

-- --- ships -----------------------------------------------------------------

-- Transform a hull into world space. Heading a travels along (sin a, -cos a)
-- in simulation coordinates, so that is where the local +y axis has to point.
local function place(pts, out, x, y, ca, sa, scale)
    for i = 1, #pts, 2 do
        local px, py = pts[i] * scale, pts[i + 1] * scale
        out[i] = x + px * ca + py * sa
        out[i + 1] = y + px * sa - py * ca
    end
    return out
end

-- One ship. `thrusting` draws the flame, which is the only thing on screen
-- that says a pilot is accelerating rather than coasting.
function M.ship(fill, glow, cls, x, y, heading, col, opts)
    local h = M.HULLS[cls + 1] or M.HULLS[1]
    local a = heading / 65536 * TAU
    local ca, sa = math.cos(a), math.sin(a)
    local pts = place(h.poly, h.tmp, x, y, ca, sa, 1)
    local mine = opts and opts.mine
    local dim = (opts and opts.alpha) or 1

    -- The flame first, so the hull sits on top of it.
    if opts and opts.thrusting then
        local flick = 0.72 + (opts.flicker or 0) * 0.28
        for i = 1, #h.jets, 2 do
            local jx = x + h.jets[i] * ca + h.jets[i + 1] * sa
            local jy = y + h.jets[i] * sa - h.jets[i + 1] * ca
            local len = 15 * flick
            glow:seg_fade(jx, jy, jx - sa * len, jy + ca * len,
                          6.5, 1.0, 0.85 * dim, 0, pal.THRUST)
            glow:seg_fade(jx, jy, jx - sa * len * 0.45, jy + ca * len * 0.45,
                          3.0, 0.8, 1.0 * dim, 0, pal.hot(pal.THRUST, 0.75, 1))
        end
    end

    -- A dark interior, tinted toward the team so a hull is never a black
    -- hole, and opaque enough that a star behind it does not shine through.
    local cxw = x + h.cx * ca + h.cy * sa
    local cyw = y + h.cx * sa - h.cy * ca
    local body = {col[1] * 0.16 + 0.02, col[2] * 0.16 + 0.03,
                  col[3] * 0.16 + 0.05, 0.94 * dim}
    local n = #pts
    for i = 1, n, 2 do
        local j = (i + 1 < n) and i + 2 or 1
        fill:tri(cxw, cyw, pts[i], pts[i + 1], pts[j], pts[j + 1], body)
    end

    -- Outline: three concentric strokes, widest and faintest first. That is
    -- the whole bloom -- no post pass, no second target -- and additively it
    -- reads as a bright edge with light spilling off it rather than as three
    -- lines. Anything past three is invisible and costs a third of the layer.
    glow:outline(pts, 8.0, pal.a(col, 0.055 * dim))
    glow:outline(pts, 3.4, pal.a(col, 0.16 * dim))
    glow:outline(pts, 1.4, pal.hot(col, mine and 0.6 or 0.3, dim))

    if h.spine then
        local s = place(h.spine, {}, x, y, ca, sa, 1)
        glow:seg(s[1], s[2], s[3], s[4], 1.1, pal.a(col, 0.45 * dim))
    end

    -- Your own ship carries a halo. In a room of nine identical outlines the
    -- one question a player asks every second is "which one is me".
    if mine then
        glow:halo(x, y, 26, 12, pal.a(col, 0.10 * dim))
    end
end

-- The energy pip above a hull. Energy is health in this game -- it powers the
-- guns and it absorbs the damage -- so one bar says both things, and a
-- wounded enemy reads at a glance without a number anywhere near it.
--
-- World space, not screen: zoom is fixed at one, so twenty-two world pixels
-- are twenty-two screen pixels and the pip needs no projection of its own.
function M.ship_bar(fill, glow, sx, sy, frac, col)
    local W, H = 22, 2.5
    local x, y = sx - W / 2, sy - 26
    fill:rect(x - 1, y - 1, W + 2, H + 2, pal.a(pal.BG, 0.8))
    fill:rect(x, y, W, H, pal.a(pal.BAR_EDGE, 0.5))
    if frac > 0 then
        glow:rect(x, y, W * math.min(1, frac), H, pal.a(col, 0.9))
    end
end

-- --- weapons ---------------------------------------------------------------
--
-- What a projectile looks like is this file's business and nowhere else's.
-- The simulation hands over a spec id and the numbers that spec flies by; the
-- picture is looked up here, exactly as a tile's class carries no picture and
-- the terrain builder chooses one. A weapon with a blast is drawn as a bomb
-- because it *is* one -- the appearance follows a simulation property rather
-- than a second field that could disagree with it.
local blast_of = {}

-- A spec id means whatever the current settings say it means, and a zone
-- sends its own -- so the answers cached here stop being true the moment a
-- settings message lands. Cheap to rebuild, wrong to keep.
function M.forget_specs()
    blast_of = {}
end

local function spec_blast(id)
    local r = blast_of[id]
    if r == nil then
        r = sim.spec_blast(id)
        blast_of[id] = r
    end
    return r
end

function M.weapons(fill, glow, me_team, t)
    local pulse = 0.72 + 0.28 * math.sin(t * 11)
    for i = 0, sim.weapon_count() - 1 do
        local x, y, spec, vx, vy, team = sim.weapon_at(i)
        if spec_blast(spec) > 0 then
            -- A bomb is a heavy, slow, obviously dangerous object: a hot core
            -- inside a ring that breathes, with a trail long enough to read
            -- its heading from across the arena.
            local col = pal.BOMB
            glow:seg_fade(x - vx * 7, y - vy * 7, x, y, 1.5, 5.5, 0, 0.55, col)
            glow:halo(x, y, 13 * pulse, 10, pal.a(col, 0.5))
            glow:ring(x, y, 4.6, 1.4, 10, pal.a(col, 0.95))
            fill:disc(x, y, 3.6, 8, pal.a(pal.hot(col, 0.8, 1), 0.9))
        else
            -- A bolt: a streak along its own velocity with a hot head. The
            -- streak is what makes a stream of fire read as a direction
            -- rather than as a scatter of dots, and it is the whole reason
            -- the core reports weapon velocity to the client at all.
            local col = (team == me_team) and pal.FRIEND or pal.ENEMY
            glow:seg_fade(x - vx * 14, y - vy * 14, x, y, 0.6, 4.5, 0, 0.30, col)
            glow:seg_fade(x - vx * 6, y - vy * 6, x, y, 0.8, 2.6, 0, 0.85, col)
            glow:seg_fade(x - vx * 2, y - vy * 2, x, y, 0.6, 1.6, 0, 1,
                          pal.hot(col, 0.9, 1))
            glow:halo(x, y, 7, 8, pal.a(col, 0.55))
        end
    end
end

-- --- prizes and flags ------------------------------------------------------

function M.prizes(fill, glow, t)
    local spin = t * 1.1
    local ca, sa = math.cos(spin), math.sin(spin)
    local pulse = 0.78 + 0.22 * math.sin(t * 3.4)
    for i = 0, sim.prize_count() - 1 do
        local active, x, y, life = sim.prize_at(i)
        if active then
            -- Every green looks the same, because every green *is* the same:
            -- what it turns out to be is decided when somebody takes it, from
            -- what their hull can hold. Colouring them by kind would have been
            -- colouring them by a decision that has not been made yet.
            local col = pal.PRIZE
            -- A prize about to time out blinks, so a player can tell the
            -- difference between one worth crossing the arena for and one
            -- that will be gone before they arrive.
            local fade = (life < 120) and (0.35 + 0.65 * math.abs(math.sin(t * 9))) or 1
            local r = 6.5 * pulse
            local pts = {}
            for k = 0, 3 do
                local px = (k == 0 and 0) or (k == 1 and r) or (k == 2 and 0) or -r
                local py = (k == 0 and -r) or (k == 1 and 0) or (k == 2 and r) or 0
                pts[k * 2 + 1] = x + px * ca + py * sa
                pts[k * 2 + 2] = y + px * sa - py * ca
            end
            glow:halo(x, y, 15, 10, pal.a(col, 0.20 * fade))
            fill:fan(pts, pal.a(col, 0.28 * fade))
            glow:outline(pts, 1.4, pal.a(col, 0.95 * fade))
        end
    end
end

function M.flags(fill, glow, my_team, t)
    local wave = math.sin(t * 2.2) * 1.6
    for i = 0, sim.flag_count() - 1 do
        local x, y, team, carried = sim.flag_at(i)
        local col = (team == 255) and pal.INK
            or (team == my_team and pal.FRIEND or pal.ENEMY)
        local top = y - (carried and 26 or 13)
        local base = y + (carried and -10 or 6)
        glow:seg(x, base, x, top, 1.6, pal.a(col, 0.9))
        local pts = {x, top, x + 12 + wave, top + 4.5, x, top + 9}
        fill:fan(pts, pal.a(col, carried and 0.6 or 0.25))
        glow:outline(pts, 1.3, pal.a(col, carried and 1 or 0.7))
        glow:halo(x, top + 4, carried and 22 or 14, 10, pal.a(col, 0.13))
    end
end

-- --- events ----------------------------------------------------------------
--
-- The simulation reports what happened; this turns each report into light and
-- noise. Positions come from the event where the core carries one, because by
-- the time the client looks a dead weapon is already gone from the state.

function M.events(me, sfx)
    for i = 0, sim.event_count() - 1 do
        local ty, a, b, v = sim.event_at(i)
        if ty == sim.EV_FIRE then
            local x, y = sim.ship_x(a), sim.ship_y(a)
            local ang = sim.ship_heading(a) / 65536 * TAU
            local bomb = spec_blast(b) > 0
            local col = bomb and pal.BOMB
                or (sim.ship_team(a) == sim.ship_team(me) and pal.FRIEND or pal.ENEMY)
            fx.cone(x + math.sin(ang) * 10, y - math.cos(ang) * 10, ang,
                    bomb and 0.9 or 0.35, bomb and 7 or 3,
                    bomb and 120 or 190, 0.14, bomb and 2.2 or 1.4, col)
            sfx(bomb and "bomb" or "gun", x, y)
        elseif ty == sim.EV_EXPIRE then
            local x = math.floor(v / 16384)
            local y = v % 16384
            local r = spec_blast(a)
            if r > 0 then
                fx.detonate(x, y, r, pal.BOMB)
                sfx("blast", x, y)
            else
                fx.burst(x, y, 4, 90, 0.22, 1.5, pal.a(pal.INK, 0.9))
            end
        elseif ty == sim.EV_HIT then
            local x, y = sim.ship_x(a), sim.ship_y(a)
            local col = (sim.ship_team(a) == sim.ship_team(me)) and pal.FRIEND or pal.ENEMY
            fx.burst(x, y, 5, 130, 0.26, 1.8, pal.hot(col, 0.6, 1))
            -- The screen shakes by what it cost you, not by what hit you.
            -- A blast falls off linearly from its centre, so the damage is
            -- already a measure of how close you were standing to it: a bomb
            -- in the face rattles the camera ten pixels, the edge of the same
            -- blast barely a pixel, and a bullet sits between them where it
            -- belongs. It was a flat jolt for everything before, which made
            -- taking two thirds of a bar feel like being scratched.
            if a == me then
                local frac = v / math.max(1, sim.ship_max_energy(a))
                if frac > 1 then frac = 1 end
                fx.jolt(0.18 + frac * 1.25)
            end
            sfx("hit", x, y)
        elseif ty == sim.EV_DEATH then
            local x, y = sim.ship_x(a), sim.ship_y(a)
            local vx, vy = sim.ship_vel(a)
            local col = (sim.ship_team(a) == sim.ship_team(me)) and pal.FRIEND or pal.ENEMY
            fx.destroy(x, y, vx, vy, col)
            sfx("death", x, y)
        elseif ty == sim.EV_SPAWN then
            local x, y = sim.ship_x(a), sim.ship_y(a)
            fx.wave(x, y, 46, 5, 0.4, 4, pal.a(pal.FRIEND, 0.9))
            sfx("spawn", x, y)
        elseif ty == sim.EV_BOUNCE then
            local x, y = sim.ship_x(a), sim.ship_y(a)
            if v > 40000 then
                fx.burst(x, y, 3, 70, 0.2, 1.2, pal.a(pal.WALL_EDGE, 1))
                sfx("bounce", x, y)
            end
        elseif ty == sim.EV_PRIZE then
            -- v is +1 for an upgrade and -1 for rust. A green that took
            -- something has to look and sound like a loss, or the one
            -- mechanic that costs you anything is invisible.
            local x, y = sim.ship_x(a), sim.ship_y(a)
            local col = (v < 0) and pal.RUST or pal.prize(b)
            if v < 0 then
                fx.wave(x, y, 5, 22, 0.4, 3, col)
                fx.burst(x, y, 5, 40, 0.45, 1.2, col)
                sfx("rust", x, y)
            else
                fx.wave(x, y, 4, 26, 0.35, 3, col)
                fx.burst(x, y, 6, 60, 0.5, 1.4, col)
                sfx("prize", x, y)
            end
        elseif ty == sim.EV_FLAG_TAKE then
            local x, y = sim.ship_x(a), sim.ship_y(a)
            local col = (sim.ship_team(a) == sim.ship_team(me)) and pal.FRIEND or pal.ENEMY
            fx.wave(x, y, 6, 30, 0.45, 5, pal.a(col, 0.55))
            fx.burst(x, y, 5, 55, 0.4, 1.4, pal.a(col, 0.8))
            sfx("flag", x, y)
        end
    end
end

return M
