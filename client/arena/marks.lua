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

-- A gun is a line with a dot on the end of it, and that is the whole mark.
-- One line, or three when the fan is on; a ring round each dot when the
-- rounds come back off walls. It was a tapered streak once, drawn the way the
-- arena draws a bolt in flight, and at the size a corner allows that came out
-- as a gray smudge with a speck on it. What survives being drawn small is a
-- line and a dot.
M.BOLT_LEN, M.BOLT_DOT, M.BOLT_FAN = 1.4, 0.17, 0.47

-- One barrel, from the muzzle out to its dot. Returns where the dot landed,
-- because both callers ring it when the rounds bounce.
function M.bolt_line(ox, oy, ang, k, col)
    local d = k * M.BOLT_LEN
    local dx, dy = ox + math.cos(ang) * d, oy + math.sin(ang) * d
    u:seg(ox, oy, dx, dy, M.pen(k, 0.075), col)
    u:disc(dx, dy, k * M.BOLT_DOT, 10, col)
    return dx, dy
end

-- What a bouncing round wears: a ring round the dot, sized off the dot rather
-- than off whatever room the caller has left, so the two draws match.
function M.bolt_bounce(dx, dy, k, col)
    local r = k * (M.BOLT_DOT + 0.16)
    u:ring(dx, dy, r, M.pen(k, 0.065), 12, col)
    return r
end

-- A bomb is a ringed head, which is a good deal more object than a bolt gets,
-- and is why the two never read as the same weapon. It is also the whole of
-- the mark: nothing on a bomb reaches further than MARK_REACH in any
-- direction, which is what lets a caller size one against a round pad by
-- knowing a single number.
M.BOMB_R = 0.46

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
function M.bomb_prox(hx, hy, r, col)
    u:disc(hx, hy, r, 28, pal.a(col, (col[4] or 1) * 0.24))
end

-- The head, and the whole of the round.
--
-- It had a fading trail behind it for a while, drawn the way the arena draws a
-- bomb in flight. Two things were wrong with that. An icon is not a round in
-- flight: it says which weapon a trigger fires, and a streak of motion on a
-- thing sitting still in a corner is a picture of the wrong moment. And it
-- cannot be centered, because it fades to nothing along its length, so it drags
-- the drawing off to one side while a bounding box reports the mark as square
-- in the middle. Three separate attempts to bias it into place all landed
-- somewhere a screenshot said was still off. A ring about a point is centered
-- where it is drawn.
-- The core fills most of the ring, which is the proportion the arena draws a
-- bomb in flight at: a 3.6 core inside a 4.6 ring, so the two read as one
-- object with a lit rim. It was a fifth of that for a while, a small dot a
-- long way inside a ring, and a small dot a long way inside a ring is the
-- picture a proximity fuse used to draw, so a bare bomb looked loaded and a
-- loaded one looked doubly so.
function M.bomb_head(hx, hy, k, col)
    u:ring(hx, hy, k * M.BOMB_R, M.pen(k, 0.122), 14, col)
    u:disc(hx, hy, k * 0.34, 12, col)
end

-- The charges, drawn from what the thing does rather than from a name that
-- could disagree with it: a repel shoves and hurts nobody, so it is rings
-- going outward; a burst is many rounds at once, so it is a rosette; a mine
-- sits where it is put, so it is the spiked hexagon it looks like in the
-- world. Anything else a zone puts in a slot gets a plain disc, which says "a
-- charge" honestly rather than drawing a repel and being wrong.
function M.charge(slot, cx, cy, k, col)
    if slot == 0 then
        u:ring(cx, cy, k * 0.34, M.pen(k, 0.11), 14, col)
        u:ring(cx, cy, k * 0.64, M.pen(k, 0.095), 18, col)
    elseif slot == 1 then
        for i = 0, 7 do
            local t = i * math.pi / 4
            u:disc(cx + math.cos(t) * k * 0.52, cy + math.sin(t) * k * 0.52,
                   k * 0.135, 6, col)
        end
    elseif slot == 2 then
        -- The same shape the world draws, at the same fixed rotation, so the
        -- pad and the thing it puts down are recognisably one object. Hollow,
        -- because a dark center is the whole of what separates a mine from a
        -- bomb at a glance.
        local rot, hub = 0.26, k * 0.30
        local pts = {}
        for i = 0, 5 do
            local a = rot + i / 6 * math.pi * 2
            pts[#pts + 1] = cx + math.cos(a) * hub
            pts[#pts + 1] = cy + math.sin(a) * hub
        end
        u:outline(pts, M.pen(k, 0.10), col, true)
        for i = 0, 5 do
            local a = rot + (i + 0.5) / 6 * math.pi * 2
            local c, s = math.cos(a), math.sin(a)
            u:seg(cx + c * hub, cy + s * hub,
                  cx + c * k * 0.58, cy + s * k * 0.58,
                  M.pen(k, 0.09), col)
        end
    else
        u:disc(cx, cy, k * 0.28, 10, col)
    end
end

-- --- a whole weapon, wearing what the greens did to it ---------------------

-- One barrel on a mark under construction, rather than on bare coordinates:
-- the mark remembers where the dots landed, because the bounce rings them, and
-- how far right anything got, because the caller sizes a row off that.
--
-- `held` is a barrel you have but are not firing: drawn, so the fan does not
-- appear to vanish when it is declined, but not counted as a round. What is
-- not firing does not bounce, and a ring on it says it does.
local function barrel(m, ang, col, held)
    local dx, dy = M.bolt_line(m.origin, m.y, ang, m.k, col)
    if not held then m.dots[#m.dots + 1] = {dx, dy} end
    m.far = math.max(m.far, dx - m.x + m.k * M.BOLT_DOT)
end

-- The two builders work out a mark's numbers and draw nothing, because one
-- add-on draws underneath the round and a builder that drew as it measured
-- would have put the round down first. See M.weapon.
local function mk_bolt(hx, cy, k)
    return {x = hx, y = cy, k = k, bolt = true,
            tail = hx - k * M.BOLT_LEN, origin = hx - k * M.BOLT_LEN,
            dots = {}, out = k * M.BOLT_DOT, far = k * M.BOLT_DOT,
            -- Nothing on this mark rings the head except the add-ons that
            -- ring any mark. The fan hangs off the muzzle and the bounce
            -- ring sits on a dot, so neither takes a share of the room.
            radial = {false, false, false, true, false, true}}
end

local function mk_bomb(hx, cy, k)
    -- `tail` is where a fan of them leaves from, which is the only thing
    -- behind the head on this mark and so is set at the edge the mark may
    -- reach rather than at a length of its own.
    return {x = hx, y = cy, k = k, tail = hx - k * M.MARK_REACH,
            out = k * M.BOMB_R, far = k * M.BOMB_R}
end

-- The round itself, once whatever it stands on has been drawn.
local function draw_round(m, col)
    if m.bolt then barrel(m, 0, col) else M.bomb_head(m.x, m.y, m.k, col) end
end

-- Every add-on takes the mark, a color and how many rungs deep it is, and
-- draws its rungs rather than reporting them. A number beside a symbol was
-- what the stack did before, and it made a corner of arithmetic out of six
-- facts a shape can carry: one rung of multifire is two more barrels, one rung
-- of bouncing is one more wall, a rung of proximity is a wider reach. The zone
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

local function dec_multi(m, col, n)
    -- On a gun, two more barrels off the same muzzle and that is all: one line
    -- or three, never five. The rungs widen the fan instead of adding lines,
    -- because a corner that answers "how many barrels" with a count of strokes
    -- stops being a shape and starts being a tally.
    if m.bolt then
        -- Declined, the extra barrels stay on the mark and stop being rounds:
        -- see barrel.
        barrel(m, -M.BOLT_FAN, col, m.off)
        barrel(m, M.BOLT_FAN, col, m.off)
        return
    end
    -- On a bomb, rounds leaving together from where this one came from. These
    -- are the only strokes a bomb mark has now that the body is gone, and that
    -- is the right way round: a lone bomb is a thing, and several of them are
    -- several things going somewhere at once.
    local len = m.x - m.tail
    for i = 1, math.min(n, 3) do
        local a = 0.26 * i
        local d = len * (1 - 0.14 * i)
        for _, s in ipairs({-1, 1}) do
            u:seg_fade(m.tail, m.y,
                       m.tail + math.cos(a) * d,
                       m.y + s * math.sin(a) * d,
                       M.pen(m.k, 0.078), M.pen(m.k, 0.222), 0,
                       (col[4] or 1) * 0.85, col)
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
            local r = M.bolt_bounce(d[1], d[2], m.k, col)
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
    local r0, r1 = m.k * M.BOMB_R * 0.58, m.k * M.BOMB_R * 1.0
    for i = 0, rungs * 2 - 1 do
        local a = (i + 0.5) * math.pi / rungs
        local dx, dy = math.cos(a), math.sin(a)
        u:seg(m.x + dx * r0, m.y + dy * r0,
              m.x + dx * r1, m.y + dy * r1, M.pen(m.k, 0.085), col)
    end
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
    M.bomb_prox(m.x, m.y, r, col)
    m.far = math.max(m.far, r)
end

-- In pal.MODS order, which is also the order they draw in: each of the ones
-- that rings the head takes the next ring of room out from the last, so the
-- fragments sit inside the shove. Reorder this list and they land on top of
-- each other.
local MOD_DECOR = {dec_multi, dec_bounce, nil, dec_shrap, dec_freeze, dec_push}
-- And the one that goes down before the round rather than onto it.
local MOD_GROUND = {nil, nil, ground_prox}
-- Which of them ring the head, and so want a share of the room around it.
-- Multifire leaves from the tail, freeze sits on the body and the fuse is
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
-- center near the dot, because a solid disc outweighs the hairline that
-- reaches it; taking the drawing's extent puts the center near the middle of
-- the line, because the far tip of a hairline counts for as much as the dot.
-- Both are wrong in a direction, the eye lands between them, and a strip of
-- the mark drawn at biases either side of the midpoint agrees with it. Then
-- averaged over the loadouts a trigger can wear, since a fan pulls the weight
-- back toward the muzzle and a bounce ring pulls it forward and no one case is
-- the one to favor.
--
-- The bomb wants nothing. It is a ring about a point, so the two answers are
-- the same answer and both are zero.
M.BOLT_BIAS, M.BOMB_BIAS = 0.46, 0

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

-- The rung a trigger is on, for a caller that colors something around a
-- mark rather than drawing the mark itself. Exported because the pads ring
-- themselves in the round's own color, and reading the core for that while
-- the mark read the held copy is exactly the split this module exists to
-- prevent: it put an orange fan inside a green ring for the length of a
-- respawn wait.
function M.level(me, t)
    return ship_lvl(me, t)
end

-- A trigger's mark: the round it fires, wearing what the greens did to it.
--
-- In the round's own color, which is the color it will be when it leaves the
-- gun: one ramp for every round in the game, so the rung a weapon has climbed
-- is legible here exactly as it is legible coming at you across the arena, and
-- a player who has learned one has learned the other.
--
-- The add-ons are the same color run hot, so what a green added reads as part
-- of the round rather than as a separate object parked next to it. Two of the
-- six are not that.
--
-- Shrapnel is drawn off the *gun's* rung rather than off the rung of the mark
-- it is worn on. A fragment is a bullet, and the core reads which one off the
-- guns at the throw, so a bomber who finds gun prizes watches the fragments on
-- their bomb mark climb the ramp while the bomb under them stays put. It is
-- also the color those fragments come out in across the arena, which is the
-- point of there being one ramp.
--
-- Multifire is the one add-on that decorates nothing. Its extra barrels are
-- the round itself, fired from the same muzzle on the same spec, which is why
-- the arena draws all three bullets in one color. Run hot with the rest, the
-- mark said the middle bullet was a different weapon from the two beside it,
-- and disagreed with the arena about the only fact this ramp exists to carry.
--
-- The room outside the round is shared out before anything draws rather than
-- spent first come. Two add-ons take half of it each and read clearly; four
-- take a quarter each and read as a dense mark, which is the right way round,
-- and no loadout can push a mark past the reach its caller sized for.
--
-- Returns how far right the whole thing reached, since a hull holding three
-- add-ons draws a good deal wider than one holding none.
function M.weapon(cx, cy, k, me, t)
    local gun = t == sim.TRIG_GUN
    local lvl = ship_lvl(me, t)
    local base = pal.a(pal.rung(lvl), 0.9)
    local at = cx + k * (gun and M.BOLT_BIAS or M.BOMB_BIAS)
    local m = gun and mk_bolt(at, cy, k) or mk_bomb(at, cy, k)
    -- Which add-ons want a ring of room is a fact about the mark, not about
    -- the add-on: the fan and the bounce ring cost a gun nothing, and cost a
    -- bomb a share each.
    local radial = m.radial or MOD_RADIAL
    local rings = 0
    for i = 1, #pal.MODS do
        if radial[i] and ship_mod(me, t, i - 1) > 0 then rings = rings + 1 end
    end
    m.step = rings > 0 and (k * M.MARK_REACH - m.out) / rings or 0
    -- A declined add-on is drawn dimmed rather than dropped. You still hold
    -- it, and a fan that quietly stopped fanning with nothing on screen to say
    -- so is a weapon that looks broken.
    local off = ship_multi_off(me)
    m.off = off and true or false
    -- What goes under the round goes down first, in the round's own color
    -- rather than the add-on's hot one: a fuse is not a thing stuck on a bomb,
    -- it is how far the bomb reaches, so it is the bomb faintly over the area
    -- it reaches. Then the round, then everything worn on it.
    for i = 1, #pal.MODS do
        local n = ship_mod(me, t, i - 1)
        if n > 0 and MOD_GROUND[i] then MOD_GROUND[i](m, base, n) end
    end
    draw_round(m, base)
    -- The round's hue run toward white, which is how this palette makes
    -- anything hotter, so an add-on is the same weapon louder rather than a
    -- different color stuck on the side of it.
    local add = pal.a(pal.hot(pal.rung(lvl), 0.45), 0.95)
    -- And the one add-on whose magnitude lives on the other ladder.
    local frag = pal.a(pal.hot(pal.rung(ship_lvl(me, sim.TRIG_GUN)), 0.45), 0.95)
    for i = 1, #pal.MODS do
        local n = ship_mod(me, t, i - 1)
        if n > 0 then
            -- More of the round is the round's own color; everything else is
            -- the round run hot. See above.
            local col = (i == 1) and base or add
            -- Except the fragments, which are a different weapon's rung. See
            -- above; on a hull whose two ladders are level they come out the
            -- same color as the rest, which is the honest answer.
            if i == 4 then col = frag end
            -- Except when you have declined it, which is the one time the
            -- barrels either side really are not the round you are firing.
            if off and i == 1 then col = pal.a(pal.DIM, 0.45) end
            if MOD_DECOR[i] then MOD_DECOR[i](m, col, n) end
        end
    end
    return m.x + m.far
end

return M
