-- Destination marks for the menu rail and its page controls.
--
-- The renderer owns the frame and the few shared drawings these marks reuse.
-- Passing those pieces in keeps the marks on the same live layer and scale
-- without giving this module control of menu layout or hit publication.

local M = {}

function M.new(context)
    local F = assert(context.frame)
    local pal = assert(context.palette)
    local rect = assert(context.rect)
    local ry = assert(context.ry)
    local pilot_mark = assert(context.pilot_mark)
    local thumb = assert(context.thumb)
    local rivet_mark = assert(context.rivet_mark)

    local RAIL_PEN = 1.2

    local function mark_zones(cx, cy, r, col)
        -- A world with a ring around it. The stop opens the list of places there
        -- are to fly in, and in this game a place is a world.
        --
        -- Three marks came before it, each borrowed from somewhere that already
        -- owns the shape. A triangle is what every media player puts on the thing
        -- that starts a video, so it promised a button and led to a list. A cross
        -- in a box is what every interface draws on the control that makes a new
        -- one. Three linked dots is the mark for sharing a page.
        local body = r * 0.58
        -- The ring first and whole, with the world laid over it, so it passes
        -- behind rather than through.
        local a, b = r * 1.06, r * 0.34
        local ca, sa = math.cos(-0.34), math.sin(-0.34)
        local pts = {}
        for i = 0, 23 do
            local t = i / 24 * math.pi * 2
            local ex, ey = a * math.cos(t), b * math.sin(t)
            pts[#pts + 1] = cx + ex * ca - ey * sa
            pts[#pts + 1] = ry(cy + ex * sa + ey * ca)
        end
        F.layer:outline(pts, 1.1 * F.scale, pal.a(col, 0.8), true)
        -- Dark in the body and lit at the rim, which is how everything solid in
        -- this game is drawn, from a wall face to a hull.
        F.layer:disc(cx, ry(cy), body, 18, pal.a(pal.BG, 0.94))
        F.layer:ring(cx, ry(cy), body, 1.3 * F.scale, 20, col)
    end

    local function mark_pilot(cx, cy, r, col)
        -- The same wings the games list counts people with, so the stop a player
        -- opens to change their call sign wears the mark that stands for them
        -- everywhere else.
        --
        -- Drawn at the rail's own hairline rather than at its own. Everywhere else
        -- this mark goes it is 11 points beside a number and its weight is struck
        -- off its width, which is right for a mark that has to survive being
        -- small. Here it is drawn half again as big next to six shapes that all
        -- hold one line no matter what they are, and a weight that scales made it
        -- the one heavy stop in the column.
        pilot_mark(cx, cy, col, r * 1.6, RAIL_PEN * F.scale)
    end

    -- Two badges, pinned one over the other: people rather than a person. The
    -- single pair of wings already stands for you, at the far end of this row
    -- beside your name, so the stop about everybody else cannot wear the same
    -- mark.
    --
    -- Stacked rather than set side by side, and that is the badge's own shape
    -- deciding it. Two helmets stood beside each other because a helmet is
    -- taller than it is wide and a step across separated them. This mark is
    -- wider than it is tall, so the same step left two fans crossing through
    -- each other and reading as one wide tangle. Clear air between them is
    -- above and below, which is also how badges sit on a uniform.
    --
    -- Smaller than the single stop's, because two of these have to fit the
    -- height one of them was sized against, and the ship in the middle of
    -- each is taller than the fan around it.
    local function mark_friends(cx, cy, r, col)
        pilot_mark(cx - r * 0.12, cy - r * 0.46, pal.a(col, 0.55), r * 0.95,
                   RAIL_PEN * F.scale)
        pilot_mark(cx + r * 0.12, cy + r * 0.46, col, r * 1.05,
                   RAIL_PEN * F.scale)
    end

    local function mark_team(cx, cy, r, col)
        -- Two pennants, which is what a flag is drawn as in the world.
        for i, k in ipairs({{-0.5, 0.85}, {0.35, 1.0}}) do
            local px, s = cx + r * k[1], r * k[2]
            F.layer:seg(px, ry(cy - s * 0.9), px, ry(cy + s * 0.85), 1.2 * F.scale,
                  pal.a(col, i == 2 and 1 or 0.6), true)
            local pts = {px, ry(cy - s * 0.9), px + s * 0.85, ry(cy - s * 0.55),
                         px, ry(cy - s * 0.2)}
            F.layer:fan(pts, pal.a(col, i == 2 and 0.22 or 0.12))
            F.layer:outline(pts, 1.1 * F.scale, pal.a(col, i == 2 and 1 or 0.6), true)
        end
    end

    local function mark_settings(cx, cy, r, col)
        -- Three rules with a knob apiece, at three different settings, because a
        -- row of identical sliders is a picture of nothing being adjustable.
        for i, k in ipairs({-0.62, 0, 0.62}) do
            local y = cy + r * k
            F.layer:seg(cx - r, ry(y), cx + r, ry(y), 1.0 * F.scale, pal.a(col, 0.45), true)
            local kx = cx + r * ({-0.3, 0.42, -0.05})[i]
            rect(kx - r * 0.17, y - r * 0.26, r * 0.34, r * 0.52, col)
        end
    end

    -- The arrow cluster, which is what the page it opens is a picture of.
    --
    -- It carried a question mark for as long as the page was called help, then a
    -- blank keycap for about an hour: a key with a `?` on it is a key with a `?`
    -- on it, and a key with nothing on it is a box. Four boxes in the shape the
    -- arrow keys make are a keyboard, and the shape is doing all of the work,
    -- which is why there is nothing drawn on them.
    --
    -- Arrowheads were, briefly. At the size a rail mark gets they are four
    -- triangles about three pixels on a side, and what they add to the inverted T
    -- is clutter rather than meaning: the T is already the only thing on a
    -- keyboard with that outline.
    --
    -- Plain boxes for the same reason the heads went. The cut corner is a
    -- fraction of the shape it cuts, and a fifth of an eight-point key is a pixel
    -- and a half: at that size it is not a chamfer, it is a ragged corner. The
    -- board further down the page keeps the cut, its keys being three times the
    -- size.
    --
    -- Sized off the key rather than off the mark, so the gaps stay in proportion
    -- when the rail draws this larger or smaller.
    local function mark_controls(cx, cy, r, col)
        local k = r * 0.66                 -- one key
        local pitch = k + k * 0.14         -- and the air around it
        local function key(gx, gy)
            local x0 = cx + gx * pitch - k / 2
            local y0 = cy + gy * pitch - k / 2
            rect(x0, y0, k, k, pal.a(col, 0.10))
            F.layer:frame(x0, ry(y0, k), k, k, 1.1 * F.scale, col)
        end
        key(0, -0.5)
        key(-1, 0.5)
        key(0, 0.5)
        key(1, 0.5)
    end

    local function mark_about(cx, cy, r, col)
        F.layer:ring(cx, ry(cy), r * 0.86, 1.15 * F.scale, 18, col)
        F.layer:disc(cx, ry(cy - r * 0.4), r * 0.15, 8, col)
        F.layer:seg(cx, ry(cy - r * 0.05), cx, ry(cy + r * 0.45), 1.4 * F.scale, col, true)
    end

    local function mark_leave(cx, cy, r, col)
        -- A doorway with the arrow going out of it, drawn open on the side the
        -- arrow leaves by so the shape says which way it means.
        local pts = {cx + r * 0.15, ry(cy - r * 0.9), cx - r * 0.85,
                     ry(cy - r * 0.9), cx - r * 0.85, ry(cy + r * 0.9),
                     cx + r * 0.15, ry(cy + r * 0.9)}
        F.layer:outline(pts, 1.2 * F.scale, pal.a(col, 0.8), false)
        F.layer:seg(cx - r * 0.2, ry(cy), cx + r * 0.85, ry(cy), 1.3 * F.scale, col, true)
        F.layer:tri(cx + r, ry(cy), cx + r * 0.45, ry(cy - r * 0.4),
              cx + r * 0.45, ry(cy + r * 0.4), col)
    end

    -- The hull is its own mark: the ship you are flying, drawn as the ship you
    -- are flying. Nothing else in the rail has to be looked up.
    local function mark_ship(cx, cy, r, col, cls)
        thumb(cx, cy, cls or 0, col, r / 17)
    end

    -- Upgrades, as the thing they charge in.
    --
    -- Not a cart, and not a bag of coins. Nothing in this game is bought with
    -- money and nothing is carried out of a shop: what changes hands is which
    -- slots a pilot may fill, and rivets are what pays for it.
    --
    -- So the mark is the rivet itself: a ring with a bar under it, the same
    -- mark that stands in front of every price on the page it leads to.
    local function mark_upgrades(cx, cy, r, col)
        rivet_mark(cx, cy, r * 0.86, col)
    end

    local MARKS = {zones = mark_zones, pilot = mark_pilot, team = mark_team,
                   settings = mark_settings, controls = mark_controls,
                   about = mark_about, leave = mark_leave,
                   friends = mark_friends, upgrades = mark_upgrades}

    local function draw_mark(kind, cx, cy, r, col, cls)
        if kind == "ship" then return mark_ship(cx, cy, r, col, cls) end
        local f = MARKS[kind] or mark_about
        f(cx, cy, r, col)
    end

    return draw_mark
end

return M
