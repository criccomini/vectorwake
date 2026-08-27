-- The shapes a weapon is drawn as.
--
-- Two places draw a gun and a bomb: the corner stack, and the pads a thumb
-- flies with. They have to be the same drawing, or a player learns the mark
-- twice and the second one teaches them the first was arbitrary.
--
-- Coordinates here are the ones vec.lua consumes, y up from the bottom. The
-- two callers arrive at them differently -- ui.lua works top down and flips
-- once at the point of drawing, touch.lua is already bottom up -- so this
-- takes them flipped and does not know which of its callers thinks which way.
-- Every earlier attempt to let a shared drawing decide that for itself put a
-- second flip somewhere and mirrored the mark.
--
-- What is not here is where a mark goes: the stack hangs one off each row of a
-- column, a pad puts one in the middle of a ring. Everything else is, down to
-- which add-ons a hull is wearing, because the pads drew two of the six for a
-- while and the stack drew all of them, so a phone showed a bomb with a fuse
-- and no fragments while the desktop showed the fragments.

local M = {}

local pal = require("arena.palette")

local u, S = nil, 1

-- The layer this frame draws into, set once before anything asks for a mark.
function M.begin(layer, s)
    u, S = layer, s or 1
end

-- Strokes come off the mark's own size rather than the window's, so a mark
-- drawn twice as large is drawn twice as heavy. The floor is what stops a
-- hairline vanishing on a small one.
function M.pen(k, ratio)
    return math.max(0.9 * S, k * ratio)
end

-- A gun is the round the arena fires, frozen: the three passes world.weapons
-- lays a bolt down with, a broad faint streak, a tighter bright one over the
-- last stretch, a hot core into the head, then the halo and a hot head. It
-- was a line with a dot for a long time, on the argument that only a line
-- and a dot survive being drawn small; that predates the layered streak,
-- whose bright core is exactly what the old tapered smudge lacked, and the
-- corner was the one place in the game still drawing a round the arena
-- never fires.
M.BOLT_LEN = 1.4
local BOLT_HEAD, BOLT_HALO = 0.13, 0.26

-- One round in flight, from the muzzle out. Returns where the head landed,
-- because both callers ring it when the rounds bounce.
local function bolt_line(ox, oy, ang, k, col)
    local ca, sa = math.cos(ang), math.sin(ang)
    local d = k * M.BOLT_LEN
    local dx, dy = ox + ca * d, oy + sa * d
    local a = col[4] or 1
    u:seg_fade(ox, oy, dx, dy, k * 0.06, k * 0.30, 0, a * 0.33, col)
    u:seg_fade(dx - ca * d * 0.75, dy - sa * d * 0.75, dx, dy,
               k * 0.05, k * 0.16, a * 0.22, a, col)
    local hotc = pal.hot(col, 0.9, a)
    u:seg_fade(dx - ca * d * 0.36, dy - sa * d * 0.36, dx, dy,
               k * 0.04, k * 0.11, a * 0.4, a, hotc)
    u:halo(dx, dy, k * BOLT_HALO, 10, pal.a(col, a * 0.45))
    u:disc(dx, dy, k * BOLT_HEAD, 10, hotc)
    return dx, dy
end

-- What a bouncing round wears: a ring round the head, sized off the head
-- rather than off whatever room the caller has left, so the two draws match.
-- Outside the halo, so it stays a ring on a light rather than a rim of it.
local function bolt_bounce(dx, dy, k, col)
    local r = k * (BOLT_HEAD + 0.17)
    u:ring(dx, dy, r, M.pen(k, 0.055), 12, col)
    return r
end

-- A bomb is a ringed head, which is a good deal more object than a bolt gets,
-- and is why the two never read as the same weapon. It is also the whole of
-- the mark: nothing on a bomb reaches further than MARK_REACH in any
-- direction, which is what lets a caller size one against a round pad by
-- knowing a single number.
local BOMB_R = 0.46

-- A fuse: the reach it goes off at, drawn as the area rather than as its edge.
--
-- It was that edge for a long time, a ring broken into four arcs, and every
-- version of that had the same fault. A proximity fuse is a circle a round
-- goes off inside of, so a drawing of its boundary is a ring, and the mark
-- already had rings on it: the head is one, bouncing is one, and a bare bomb
-- with neither read as a loaded one. Cutting the ring finer, squaring it off
-- and breaking it in other places were all drawn and all still asked a reader
-- to tell one circle from another at three points across.
--
-- Filled, nothing else on any mark is, so it cannot be mistaken for anything.
-- In the round's own hue taken right down rather than in the add-on's hot one,
-- because a fuse is not a thing stuck on the round: it is how far the round
-- reaches, so it is the round, faintly, over the area it reaches.
--
-- And under everything, which is the other half of why it works. A field the
-- fragments and the bounce ring stand on is ground; the same disc over them
-- would be a wash.
local function bomb_prox(hx, hy, r, col)
    u:disc(hx, hy, r, 28, pal.a(col, (col[4] or 1) * 0.24))
end

-- The head, and the whole of the round: the hot core in a ring the arena
-- flies, under its own light. The halo and the bloom are world.weapons' own
-- pair, the tight one sized to the thing and the wide faint one over it.
--
-- What it still does not have is the trail. An icon is not a round in
-- flight: it says which weapon a trigger fires, and a streak of motion on a
-- thing sitting still in a corner is a picture of the wrong moment. It also
-- cannot be centered, because it fades to nothing along its length, so it
-- drags the drawing off to one side while a bounding box reports the mark as
-- square in the middle; three separate attempts to bias it into place all
-- landed somewhere a screenshot said was still off. The gun keeps its streak
-- because the streak is the round; a bomb's identity is the lit ring, and
-- light thrown equally in every direction is centered where it is drawn.
--
-- The core fills most of the ring, which is the proportion the arena draws a
-- bomb in flight at: a 3.6 core inside a 4.6 ring, hot against the ring's
-- own hue, so the two read as one object with a lit rim.
local function bomb_head(hx, hy, k, col)
    local a = col[4] or 1
    u:halo(hx, hy, k * 0.78, 12, pal.a(col, a * 0.5))
    -- The wide faint pass is world's bloom, spelled as a halo: the two are
    -- the same triangles, and bloom's alpha-as-a-parameter exists for a loop
    -- that draws thousands a frame, which a corner of four marks is not.
    u:halo(hx, hy, k * 1.02, 12, pal.a(col, a * 0.18))
    u:ring(hx, hy, k * BOMB_R, M.pen(k, 0.122), 14, col)
    u:disc(hx, hy, k * 0.35, 12, pal.hot(col, 0.8, a * 0.95))
end

-- The charges, drawn from what the thing does rather than from a name that
-- could disagree with it, and lit the way the arena lights the things they
-- do: a repel shoves and hurts nobody, so it is rings going outward from a
-- hot point; a burst is many rounds at once, so it is rounds leaving in
-- every direction, each with the fade and the hot head a round in flight
-- wears. Anything else a zone puts in a slot gets a plain disc, which says
-- "a charge" honestly rather than drawing a repel and being wrong.
function M.charge(slot, cx, cy, k, col)
    local a = col[4] or 1
    if slot == 0 then
        u:halo(cx, cy, k * 0.5, 10, pal.a(col, a * 0.45))
        u:disc(cx, cy, k * 0.14, 8, pal.hot(col, 0.6, a))
        u:ring(cx, cy, k * 0.36, M.pen(k, 0.11), 14, col)
        u:ring(cx, cy, k * 0.66, M.pen(k, 0.09), 18, pal.a(col, a * 0.6))
    elseif slot == 1 then
        u:halo(cx, cy, k * 0.45, 10, pal.a(col, a * 0.4))
        for i = 0, 7 do
            local t = i * math.pi / 4
            local dx, dy = math.cos(t), math.sin(t)
            u:seg_fade(cx + dx * k * 0.22, cy + dy * k * 0.22,
                       cx + dx * k * 0.62, cy + dy * k * 0.62,
                       M.pen(k, 0.05), M.pen(k, 0.09), a * 0.25, a, col)
            u:disc(cx + dx * k * 0.62, cy + dy * k * 0.62, k * 0.10, 6,
                   pal.hot(col, 0.5, a))
        end
    else
        u:disc(cx, cy, k * 0.28, 10, col)
    end
end

-- --- a whole weapon, wearing its loadout -----------------------------------

-- One barrel on a mark under construction, rather than on bare coordinates:
-- the mark remembers where the dots landed, because the bounce rings them, and
-- how far right anything got, because the caller sizes a row off that.
--
-- `held` is a barrel you have but are not firing: drawn, so the fan does not
-- appear to vanish when it is declined, but not counted as a round. What is
-- not firing does not bounce, and a ring on it says it does.
local function barrel(m, ang, col, held)
    local dx, dy = bolt_line(m.origin, m.y, ang, m.k, col)
    if not held then m.dots[#m.dots + 1] = {dx, dy} end
    m.far = math.max(m.far, dx - m.x + m.k * BOLT_HALO)
end

-- The two builders work out a mark's numbers and draw nothing, because one
-- add-on draws underneath the round and a builder that drew as it measured
-- would have put the round down first. See M.weapon.
local function mk_bolt(hx, cy, k)
    return {x = hx, y = cy, k = k, bolt = true,
            tail = hx - k * M.BOLT_LEN, origin = hx - k * M.BOLT_LEN,
            dots = {}, out = k * BOLT_HALO, far = k * BOLT_HALO,
            -- Nothing on this mark rings the head except the add-ons that
            -- ring any mark. The fan hangs off the muzzle and the bounce
            -- ring sits on a head, so neither takes a share of the room.
            radial = {false, false, false, true, false, true}}
end

local function mk_bomb(hx, cy, k)
    -- `tail` is where a fan of them leaves from, which is the only thing
    -- behind the head on this mark and so is set at the edge the mark may
    -- reach rather than at a length of its own. `far` starts at the bloom,
    -- the widest light the bare round sheds.
    return {x = hx, y = cy, k = k, tail = hx - k * M.MARK_REACH,
            out = k * BOMB_R, far = k * 1.02}
end

-- The round itself, once whatever it stands on has been drawn.
local function draw_round(m, col)
    if m.bolt then barrel(m, 0, col) else bomb_head(m.x, m.y, m.k, col) end
end

-- What a declined round is drawn in: still on the mark, no longer a round.
local DECLINED = pal.a(pal.DIM, 0.45)

-- Every add-on takes the mark, a color and how many rungs deep it is, and
-- draws its rungs rather than reporting them. A number beside a symbol was
-- what the stack did before, and it made a corner of arithmetic out of six
-- facts a shape can carry: a rung of spray is one more round, a rung of
-- bouncing is one more wall, a rung of proximity is a wider reach. The zone
-- says so in mod_step, and this draws what the zone said.
--
-- Most of the six ring the head, and those share out `m.step`: one ring of
-- room each, decided before any of them draws. See M.weapon for why. Depth
-- moves a mark inside its own ring rather than pushing past it, so a third
-- rung of proximity never costs shrapnel the room it was given.
--
-- `m.out` is the cursor through those shares and `m.far` is how far anything
-- actually got drawn. They are not the same number: a mark that spends less
-- than its share should not claim the width it did not use.

-- Spray: the volley a pull actually throws, at the angles the core throws
-- it, so the mark counts bullets exactly as the arena does: two at the
-- first rung, three at the second, five at the fourth, symmetric about the
-- aim.
--
-- It drew a fixed three-line fan above the first rung for a while, on the
-- argument that a count of lines is a tally rather than a shape. What that
-- bought was a corner disagreeing with the arena about the one fact a
-- volley carries, and at the true angles even five rounds stay inside the
-- row, so the tally is the shape.
--
-- Both numbers come off `m`, asked of the core in `dressed` rather than
-- worked out here: see `shape` below for why they cannot be constants.
--
-- The whole volley draws here, the center round included, because a pair
-- has no center round: dressed() skips draw_round when the trigger wears
-- any spray. Declined, the geometry holds and the color goes: the one
-- round that would still fire stays lit and the rest dim, so a fan that
-- stopped fanning is visibly the same weapon holding its fire.
local function draw_volley(m, col)
    local count, step = m.count or 1, m.spacing or 0
    if count <= 1 then
        draw_round(m, col)
        return
    end
    -- The round nearest the aim, which is the one a declined fan still
    -- fires. A pair straddles the aim, so its upper round stands in.
    local center = math.floor(count / 2)
    -- Several shells drawn whole want to be smaller than one alone, and the
    -- outermost, light and all, must stay inside the reach the caller sized
    -- for, so the scale comes off the fan's own geometry: what is left of
    -- MARK_REACH above the outer round's offset is what a shell may fill.
    local out_ang = count > 1 and step * (count - 1) / 2 or 0
    local s = math.min(0.78,
                       M.MARK_REACH * (1 - math.sin(out_ang)) / 1.02 * 0.95)
    local len = m.x - m.tail
    for i = 0, count - 1 do
        local off = step * (2 * i - (count - 1)) / 2
        local declined = m.off and i ~= center
        local c = declined and DECLINED or col
        if m.bolt then
            barrel(m, off, c, declined)
        else
            local hx = m.tail + math.cos(off) * len
            local hy = m.y + math.sin(off) * len
            bomb_head(hx, hy, m.k * s, c)
            m.far = math.max(m.far, hx - m.x + m.k * s * 1.02)
        end
    end
end

-- A round that stops where it lands is a round; one that carries on off the
-- wall is a round with something still around it. Both marks say it the same
-- way, and neither counts the walls: how many bounces deep the add-on runs is
-- a question for the ladder beside the row, not for a ring three points wide.
local function dec_bounce(m, col, n)
    if m.bolt then
        for _, d in ipairs(m.dots) do
            local r = bolt_bounce(d[1], d[2], m.k, col)
            m.far = math.max(m.far, d[1] - m.x + r)
        end
        return
    end
    local r = m.out + m.step * 0.5
    u:ring(m.x, m.y, r, M.pen(m.k, 0.075), 16, col)
    m.out = m.out + m.step
    m.far = math.max(m.far, r)
end

-- What is left of it afterwards, thrown clear of everything else the mark
-- wears: one tick per fragment, counted off the zone rather than off a ramp
-- written in here.
--
-- Shrapnel is the one add-on whose magnitude is another weapon rather than a
-- number, so a zone says how many by naming a pattern per rung. The baseline
-- doubles, 2 then 4 then 8, where this drawing said 6 then 8 then 10: close
-- enough to look deliberate, wrong at every rung, and free to be wrong by any
-- amount at all in a zone that puts its own patterns on those rungs. The one
-- add-on whose count a player can read straight off the arena was the one the
-- corner was making up.
--
-- The ticks thin as they multiply, because thirty-one of them at the width six
-- want is a filled ring, and a filled ring is what the fuse already is. Down
-- to the stroke floor and no further: a hairline under a pixel blinks as the
-- mark moves, so a count that cannot be drawn as separate ticks at this size
-- is drawn as a dense ring instead, which is the same thing the eye would have
-- made of it anyway.
--
-- What stays fixed is how far out they sit. That is the mark's share of the
-- room, and it belongs to the add-on rather than to how deep it runs.
local function dec_shrap(m, col, n)
    local r0 = m.out + m.step * 0.28
    local r1 = m.out + m.step
    local c = sim.shrap_count and sim.shrap_count(n) or 0
    -- A rung the zone put no pattern on throws nothing, and drawing nothing is
    -- the honest answer. The share of room is spent either way, so a hull that
    -- picks the pattern up later does not shove its other add-ons outward.
    for i = 0, c - 1 do
        local a = (i + 0.5) * 2 * math.pi / c
        local dx, dy = math.cos(a), math.sin(a)
        u:seg(m.x + dx * r0, m.y + dy * r0,
              m.x + dx * r1, m.y + dy * r1,
              M.pen(m.k, math.min(0.100,
                                  2 * math.pi * r1 * 0.42 / (c * m.k))), col)
    end
    m.out = r1
    m.far = math.max(m.far, r1)
end

-- Rime on the round itself. Freeze is the one add-on that does nothing to the
-- round and everything to whoever it reaches, so it is drawn on the body
-- rather than around it: the shot is unchanged, and it is carrying something.
-- A bolt's body is its streak and a bomb's is its shell, so the ticks cross
-- the streak on one and the shell on the other, and neither takes a ring of
-- room from anything that does.
--
-- The bomb's spikes cross its ring and reach into the halo, needle points
-- out. They used to stop at the ring's own radius, which was legible on a
-- plain shell and invisible on a lit one: a hot tick ending on a hot ring is
-- the ring. What still tells them from shrapnel is where they stand: rime
-- grows out of the shell, fragments are thrown clear of it.
local function dec_freeze(m, col, n)
    local rungs = 2 + math.min(n, 2)
    if m.bolt then
        local len = m.x - m.tail
        local t = m.k * 0.24
        for i = 1, rungs do
            local px = m.tail + len * (0.28 + 0.15 * (i - 1))
            u:seg(px, m.y - t, px, m.y + t, M.pen(m.k, 0.100), col)
        end
        return
    end
    local r0, r1 = m.k * 0.26, m.k * 0.68
    for i = 0, rungs * 2 - 1 do
        local a = (i + 0.5) * math.pi / rungs
        local dx, dy = math.cos(a), math.sin(a)
        u:seg(m.x + dx * r0, m.y + dy * r0,
              m.x + dx * r1, m.y + dy * r1, M.pen(m.k, 0.095), col)
    end
    m.far = math.max(m.far, r1)
end

-- A shove standing off the head, and a rung is another wave of it. The repel
-- wears rings closed all the way round because it happens at a place; this
-- one opens forward, because it is a shove a round is carrying somewhere.
local function dec_push(m, col, n)
    local rungs = math.min(n, 3)
    for i = 1, rungs do
        u:arc(m.x, m.y, m.out + m.step * (i / rungs), -0.85, 0.85,
              M.pen(m.k, 0.100), 6,
              pal.a(col, (col[4] or 1) * (1 - 0.2 * (i - 1))))
    end
    m.out = m.out + m.step
    m.far = math.max(m.far, m.out)
end

-- The fuse, drawn before the round and under it. A rung is another tile of
-- reach, so the field grows with depth; it starts at the width the rest of the
-- mark may use, so at any depth everything else on the mark stands on it.
--
-- It takes no share of the room. A share is for something that rings the round
-- and has to be told from the ring outside it, and this is not a ring: what it
-- costs the marks beside it is nothing, so a hull with a fuse and fragments
-- splits the width two ways rather than three.
local function ground_prox(m, col, n)
    local r = m.k * (M.MARK_REACH + 0.05 * (math.min(n, 3) - 1))
    bomb_prox(m.x, m.y, r, col)
    m.far = math.max(m.far, r)
end

-- In pal.MODS order, which is also the order they draw in: each of the ones
-- that rings the head takes the next ring of room out from the last, so the
-- fragments sit inside the shove. Reorder this list and they land on top of
-- each other.
-- Spray has no entry. Its rungs are more of the round rather than something
-- worn on it, so the volley is drawn by the round itself: see draw_volley,
-- which also covers a zone whose pattern already throws several with no
-- spray bought at all.
local MOD_DECOR = {nil, dec_bounce, nil, dec_shrap, dec_freeze, dec_push}
-- And the one that goes down before the round rather than onto it.
local MOD_GROUND = {nil, nil, ground_prox}
-- Which of them ring the head, and so want a share of the room around it.
-- Spray leaves from the tail, freeze sits on the body and the fuse is
-- ground; none of the three costs the mark any width. This is the bomb's
-- answer; a bolt carries its own, since it draws its fan and its bounce into
-- the mark itself.
local MOD_RADIAL = {false, true, false, true, false, true}
-- How far out from the head a mark may reach, against its own size. In the
-- stack the row is 22 points tall and a mark has to live inside it however
-- loaded it is; on a pad the ring is what it has to live inside. Each caller
-- picks `k` to suit its own room, and this is what the shares are shares of.
M.MARK_REACH = 1.05
-- And how far the one add-on that is not bounded by it goes: a fuse is the
-- only one whose magnitude is a distance, so it grows past the rest with
-- depth. A caller sizing a mark against a round control wants this number, not
-- the one above.
M.FIELD_MAX = M.MARK_REACH + 0.10

-- Where to put the round so that the mark reads as centered on the point it was
-- given, which is not the same as putting the round there.
--
-- A gun is not symmetric about its own round: three lines leaving a muzzle a
-- hull and a half behind the dot that ends them. So the round is offset, and
-- what lines up is the drawing.
--
-- Measured rather than worked out, and measured as the mean of two answers
-- that disagree. Weighing the drawing by how much of it there is puts the
-- center near the head, because the bright end of the streak outweighs the
-- faint one; taking the drawing's extent puts the center near the middle of
-- the streak, because the far tip of a fade counts for as much as the head.
-- Both are wrong in a direction, the eye lands between them, and a strip of
-- the mark drawn at biases either side of the midpoint agrees with it. Then
-- averaged over the loadouts a trigger can wear, since a fan pulls the weight
-- back toward the muzzle and a bounce ring pulls it forward and no one case is
-- the one to favor.
--
-- Re-measured when the line and dot became the flown streak: the bright core
-- and halo moved a third of the old dot's weight up to the head, so the head
-- stands a step nearer the middle than it did.
--
-- The bomb wants nothing. It is light about a point, so the two answers are
-- the same answer and both are zero.
M.BOLT_BIAS = 0.33
local BOMB_BIAS = 0

-- Reading a hull's loadout without minding whether there is a hull yet. A pad
-- draws before the first snapshot lands, and a plain gun and a plain bomb are
-- the right thing to show while nobody has told us otherwise.
-- The loadout to draw while there is no hull to read one off.
--
-- Dying strips a ship of everything at once: levels, add-ons and charges are
-- memset in the same instruction that takes the last of the energy. So a mark
-- read straight off the core the moment you die drops to a plain green round
-- and stays there for the whole respawn wait, which is four seconds of the
-- interface rearranging itself while the player is reading the card that says
-- what killed them. It is a true statement about a ship that does not exist.
--
-- The frame loop keeps a copy of the last loadout actually flown and hands it
-- over while the hull is gone. The marks go back to reading the live ship the
-- moment there is one, which is where the change belongs: a fresh hull is
-- visibly a fresh hull, and the kit it does not have reads as new rather than
-- as something that quietly drained away while nothing was happening.
local held = nil
function M.hold(h)
    held = h
end

local function ship_lvl(me, t)
    if held then return held.level[t] or 0 end
    return (me and sim.ship_level) and sim.ship_level(me, t) or 0
end

local function ship_mod(me, t, i)
    if held then return (held.mods[t] and held.mods[t][i]) or 0 end
    return (me and sim.ship_mod) and sim.ship_mod(me, t, i) or 0
end

local function ship_multi_off(me)
    if held then return held.multi_off end
    return me and sim.ship_multi_off and sim.ship_multi_off(me)
end

local function ship_cls(me)
    if held then return held.cls or 0 end
    return (me and sim.ship_class) and sim.ship_class(me) or 0
end

-- How many rounds a pull throws and how far apart they leave, asked of the
-- core rather than worked out here.
--
-- Three facts decide it and none of them belongs to a drawing: what the
-- pattern this rung fires already throws, how many rounds a rung of spray
-- adds, and the two spreads a zone opens a pair and a fan at. The baseline
-- answers one round, one a rung, seven and a half degrees and fifteen, and
-- a zone is free to answer differently on all four; a mark carrying those
-- as constants would go on drawing the baseline in a room that had left it.
--
-- The fallback is the baseline, and it is for a caller with no engine under
-- it: the SVG tools and the tests draw marks against a stubbed core. A
-- count of zero means the core has no pattern at that rung to describe, and
-- takes the fallback for the same reason.
-- The core counts a full turn in 65536 heading units and hands its spacing
-- over in those, so the conversion to the radians this file draws in happens
-- here rather than in the binding.
local TURN = 65536
local PAIR_STEP, FAN_STEP = 2 * math.pi / 48, 2 * math.pi / 24

-- Which trigger a mark is about, for the one question that has to be asked
-- of the core by index. Which of the two is being drawn stays the caller's
-- explicit boolean: a mark that worked that out by comparing indexes would
-- draw a bomb as a gun anywhere the two constants are missing, since in Lua
-- one absent constant equals another.
local function trig(gun)
    if gun then return sim.TRIG_GUN or 0 end
    return sim.TRIG_BOMB or 1
end
local function shape(cls, t, lvl, n)
    if sim.spray_shape then
        local count, spacing = sim.spray_shape(cls, t, lvl, n)
        if count and count > 0 then
            spacing = (spacing or 0) * 2 * math.pi / TURN
            -- Several rounds at no spacing is the core's scatter encoding,
            -- which is a roll rather than an angle. A still mark cannot draw
            -- a roll, so it spreads them at the fan's own step and says how
            -- many, which are the two facts a scattered volley still has.
            if count > 1 and spacing == 0 then spacing = FAN_STEP end
            return count, spacing
        end
    end
    if n <= 0 then return 1, 0 end
    return n + 1, (n == 1) and PAIR_STEP or FAN_STEP
end

-- The rung a trigger is on, for a caller that colors something around a
-- mark rather than drawing the mark itself. Exported because the pads ring
-- themselves in the round's own color, and reading the core for that while
-- the mark read the held copy is exactly the split this module exists to
-- prevent: it put an orange fan inside a green ring for the length of a
-- respawn wait.
function M.level(me, t)
    return ship_lvl(me, t)
end

-- What a trigger is carrying of one add-on, for a caller that names the kit
-- rather than drawing it. Exported for the same reason `level` is: the hover
-- card in the corner reads what the mark beside it is showing, and a card
-- reading the core while the mark read the held copy would name a loadout the
-- drawing next to it was not wearing.
function M.mod(me, t, i)
    return ship_mod(me, t, i)
end

-- A trigger's mark: the round it fires, wearing the trigger's loadout.
--
-- In the round's own color, which is the color it will be when it leaves the
-- gun: one ramp for every round in the game, so the rung a weapon has climbed
-- is legible here exactly as it is legible coming at you across the arena, and
-- a player who has learned one has learned the other.
--
-- The add-ons are the same color run hot, so what the kit added reads as part
-- of the round rather than as a separate object parked next to it. Two of the
-- six are not that.
--
-- Shrapnel is drawn off the *gun's* rung rather than off the rung of the mark
-- it is worn on. A fragment is a bullet, and the core reads which one off the
-- guns at the throw, so a bomber with a higher gun rung sees the fragments on
-- their bomb mark climb the ramp while the bomb under them stays put. It is
-- also the color those fragments come out in across the arena, which is the
-- point of there being one ramp.
--
-- Spray is the one add-on that decorates nothing. Its extra rounds are the
-- round itself, fired on the same spec, which is why the arena draws a whole
-- spray in one color. Run hot with the rest, the mark said the middle bullet
-- was a different weapon from the two beside it, and disagreed with the arena
-- about the only fact this ramp exists to carry.
--
-- The room outside the round is shared out before anything draws rather than
-- spent first come. Two add-ons take half of it each and read clearly; four
-- take a quarter each and read as a dense mark, which is the right way round,
-- and no loadout can push a mark past the reach its caller sized for.
--
-- Returns how far right the whole thing reached, since a hull holding three
-- add-ons draws a good deal wider than one holding none.
local function dressed(cx, cy, k, gun, cls, lvl, modn, gun_lvl, off)
    local base = pal.a(pal.rung(lvl), 0.9)
    local at = cx + k * (gun and M.BOLT_BIAS or BOMB_BIAS)
    local m = gun and mk_bolt(at, cy, k) or mk_bomb(at, cy, k)
    -- The volley, before anything is drawn: how many rounds leave and at
    -- what angle is the round itself rather than something worn on it, and
    -- the spray rungs are only one of the things that decide it.
    m.count, m.spacing = shape(cls, trig(gun), lvl, modn[1] or 0)
    -- Which add-ons want a ring of room is a fact about the mark, not about
    -- the add-on: the fan and the bounce ring cost a gun nothing, and cost a
    -- bomb a share each.
    local radial = m.radial or MOD_RADIAL
    local rings = 0
    for i = 1, #pal.MODS do
        if radial[i] and (modn[i] or 0) > 0 then rings = rings + 1 end
    end
    m.step = rings > 0 and (k * M.MARK_REACH - m.out) / rings or 0
    -- A declined add-on is drawn dimmed rather than dropped. You still hold
    -- it, and a fan that quietly stopped fanning with nothing on screen to say
    -- so is a weapon that looks broken.
    m.off = off and true or false
    -- What goes under the round goes down first, in the round's own color
    -- rather than the add-on's hot one: a fuse is not a thing stuck on a bomb,
    -- it is how far the bomb reaches, so it is the bomb faintly over the area
    -- it reaches. Then the round, then everything worn on it.
    for i = 1, #pal.MODS do
        local n = modn[i] or 0
        if n > 0 and MOD_GROUND[i] then MOD_GROUND[i](m, base, n) end
    end
    draw_volley(m, base)
    -- The round's hue run toward white, which is how this palette makes
    -- anything hotter, so an add-on is the same weapon louder rather than a
    -- different color stuck on the side of it.
    local add = pal.a(pal.hot(pal.rung(lvl), 0.45), 0.95)
    -- And the one add-on whose magnitude lives on the other ladder.
    local frag = pal.a(pal.hot(pal.rung(gun_lvl), 0.45), 0.95)
    for i = 1, #pal.MODS do
        local n = modn[i] or 0
        if n > 0 then
            -- More of the round is the round's own color; everything else is
            -- the round run hot. See above.
            local col = (i == 1) and base or add
            -- Except the fragments, which are a different weapon's rung. See
            -- above; on a hull whose two ladders are level they come out the
            -- same color as the rest, which is the honest answer.
            if i == 4 then col = frag end
            if MOD_DECOR[i] then MOD_DECOR[i](m, col, n) end
        end
    end
    return m.x + m.far
end

function M.weapon(cx, cy, k, me, t)
    local modn = {}
    for i = 1, #pal.MODS do modn[i] = ship_mod(me, t, i - 1) end
    return dressed(cx, cy, k, t == sim.TRIG_GUN, ship_cls(me),
                   ship_lvl(me, t), modn,
                   ship_lvl(me, sim.TRIG_GUN), ship_multi_off(me))
end

-- The round with a named kit, for a caller that has no ship to read: the
-- shelf sells an add-on by drawing the round wearing the one on offer, and a
-- shelf that read a live hull would be selling whatever the pilot happened
-- to be flying. `modn` is counts in sim_mod order, and fragments take the
-- round's own rung, which on a mark about one trigger is the honest answer.
--
-- The volley is asked against the first hull, since a shelf is selling to
-- nobody in particular. Every shipped zone builds one gun ladder for all of
-- them, so that is the whole roster's answer; a zone that gave its hulls
-- different patterns would be selling against the first one's.
function M.round(cx, cy, k, gun, lvl, modn)
    return dressed(cx, cy, k, gun, 0, lvl, modn or {}, lvl, false)
end

return M
