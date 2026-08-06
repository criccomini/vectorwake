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
-- What is not here is how a mark is laid out. The stack hangs its marks off
-- one axis and shares the room around a head among as many as six add-ons; a
-- pad puts one in the middle of a ring with at most two. That part differs
-- and stays with each caller. This is the part that must not differ.

local M = {}

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
-- as a grey smudge with a speck on it. What survives being drawn small is a
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

-- A bomb is a short trail into a ringed head, which is a good deal more
-- object than a bolt gets, and is why the two never read as the same weapon.
M.BOMB_LEN, M.BOMB_R = 1.32, 0.46

-- A fuse: the reach it goes off at, broken because nothing is there yet. The
-- radius comes from the caller, since the stack shares the room round a head
-- among every add-on and a pad has the room to itself, but the four arcs and
-- the gaps between them are the drawing and belong here.
function M.bomb_prox(hx, hy, r, k, col)
    for i = 0, 3 do
        local a0 = i * math.pi / 2 + 0.17
        u:arc(hx, hy, r, a0, a0 + math.pi / 2 - 0.34, M.pen(k, 0.106), 5, col)
    end
end

function M.bomb_body(hx, hy, k, col)
    u:seg_fade(hx - k * M.BOMB_LEN, hy, hx, hy, M.pen(k, 0.078),
               M.pen(k, 0.244), 0, (col[4] or 1) * 0.6, col)
    u:ring(hx, hy, k * M.BOMB_R, M.pen(k, 0.122), 12, col)
    u:disc(hx, hy, k * 0.19, 8, col)
end

-- The charges, drawn from what the thing does rather than from a name that
-- could disagree with it: a repel shoves and hurts nobody, so it is rings
-- going outward; a burst is many rounds at once, so it is a rosette. Anything
-- else a zone puts in a slot gets a plain disc, which says "a charge"
-- honestly rather than drawing a repel and being wrong.
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
    else
        u:disc(cx, cy, k * 0.28, 10, col)
    end
end

return M
