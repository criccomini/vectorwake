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
        -- The same helmet the games list counts people with, so the stop a player
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

    -- Two helmets, one behind the other: people rather than a person. The single
    -- helmet already stands for you, at the far end of this row beside your name,
    -- so the stop about everybody else cannot wear the same mark.
    local function mark_friends(cx, cy, r, col)
        pilot_mark(cx - r * 0.46, cy - r * 0.16, pal.a(col, 0.55), r * 1.15,
                   RAIL_PEN * F.scale)
        pilot_mark(cx + r * 0.36, cy + r * 0.2, col, r * 1.3,
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

    -- Discord's mark, traced from Discord's own file and drawn the way this rail
    -- draws everything: a faint fill and an outline, in whatever color the stop is
    -- wearing.
    --
    -- It was a solid Blurple silhouette for a commit, because discord.com/branding
    -- says "please do not edit, change, distort, recolor, or reconfigure the
    -- Discord logo" and names three colors it may appear in. Chris has that call
    -- and made it: a stop that neither lights with its neighbors nor is drawn like
    -- them is a foreign object on the rail, and a recognizable outline linking to
    -- somebody's own server is what half the web does. The shape is exact; only
    -- the ink and the fill are the rail's.
    --
    -- The geometry is the official path, sampled into rings and triangulated with
    -- the eyes as holes, because the layer has no path, no bezier and no even-odd
    -- rule to do it with at runtime. Baked rather than computed at load: it is the
    -- same answer every time, and an ear clipper in the client would be a hundred
    -- lines to arrive at a constant.
    --
    -- The triangles are still what fills it. Stroking the rings alone would leave
    -- the eyes as unfilled shapes rather than holes, which is the same picture on
    -- this background and the wrong one the moment anything is behind it.
    --
    -- Forty samples around the body and twelve around each eye. Eighty was tried
    -- and is indistinguishable at the thirteen points the rail gives this, which
    -- is the only size it is ever drawn at.
    --
    -- A unit box, y down, x from -1 to 1. Indices are one-based triples into it.
    local CLYDE_V = {
        0.6930, -0.6418, 0.5295, -0.7066, 0.3600, -0.7536, 0.2374, -0.6812,
        0.0754, -0.6762, -0.1000, -0.6750, -0.2474, -0.7018, -0.3826, -0.7487,
        -0.5515, -0.6995, -0.7087, -0.6219, -0.8084, -0.4523, -0.8856, -0.2838,
        -0.9418, -0.1164, -0.9785, 0.0501, -0.9974, 0.2158, -1.0000, 0.3806,
        -0.9505, 0.5322, -0.7921, 0.6299, -0.6363, 0.7041, -0.4828, 0.7536,
        -0.3896, 0.6045, -0.5178, 0.5176, -0.4173, 0.5048, -0.2470, 0.5547,
        -0.0746, 0.5787, 0.0982, 0.5770, 0.2697, 0.5496, 0.4382, 0.4963,
        0.4956, 0.5287, 0.3990, 0.6248, 0.5009, 0.7527, 0.6551, 0.6956,
        0.8112, 0.6188, 0.9698, 0.5178, 1.0000, 0.3409, 0.9924, 0.1609,
        0.9664, -0.0123, 0.9228, -0.1790, 0.8623, -0.3394, 0.7857, -0.4938,
        -0.3322, 0.2720, -0.4228, 0.2444, -0.4874, 0.1718, -0.5120, 0.0699,
        -0.4875, -0.0317, -0.4230, -0.1039, -0.3318, -0.1313, -0.2401, -0.1034,
        -0.1758, -0.0309, -0.1524, 0.0703, -0.1767, 0.1720, -0.2411, 0.2444,
        0.3327, 0.2720, 0.2421, 0.2444, 0.1774, 0.1718, 0.1528, 0.0699,
        0.1774, -0.0317, 0.2419, -0.1040, 0.3332, -0.1313, 0.4248, -0.1034,
        0.4891, -0.0308, 0.5125, 0.0705, 0.4883, 0.1721, 0.4241, 0.2445,
    }

    local CLYDE_T = {
        49, 56, 55, 57, 56, 49, 45, 44, 15, 15, 14, 13,
        13, 12, 11, 11, 10, 9, 9, 8, 7, 4, 3, 2,
        2, 1, 40, 40, 39, 38, 38, 37, 36, 36, 35, 34,
        34, 33, 32, 32, 31, 30, 28, 27, 26, 26, 25, 24,
        22, 21, 20, 20, 19, 18, 18, 17, 16, 16, 15, 44,
        50, 49, 55, 58, 57, 49, 46, 45, 15, 15, 13, 11,
        11, 9, 7, 4, 2, 40, 40, 38, 36, 36, 34, 32,
        32, 30, 29, 28, 26, 24, 22, 20, 18, 18, 16, 44,
        51, 50, 55, 59, 58, 49, 46, 15, 11, 11, 7, 6,
        5, 4, 40, 40, 36, 32, 28, 24, 23, 22, 18, 44,
        52, 51, 55, 59, 49, 48, 47, 46, 11, 11, 6, 5,
        40, 32, 29, 23, 22, 44, 41, 52, 55, 59, 48, 47,
        47, 11, 5, 40, 29, 28, 23, 44, 43, 41, 55, 54,
        59, 47, 5, 23, 43, 42, 41, 54, 53, 60, 59, 5,
        23, 42, 41, 61, 60, 5, 28, 23, 41, 61, 5, 40,
        28, 41, 53, 62, 61, 40, 28, 53, 64, 63, 62, 40,
        28, 64, 63, 63, 40, 28,
    }

    -- Where each closed ring begins and ends in CLYDE_V, in vertices: the body,
    -- then an eye each. Ranges rather than a second copy of the points, since the
    -- triangulation was built by laying the rings out in exactly this order.
    local CLYDE_RINGS = {{1, 40}, {41, 52}, {53, 64}}

    local function mark_discord(cx, cy, r, col)
        for i = 1, #CLYDE_T, 3 do
            local t = {CLYDE_T[i] * 2 - 1, CLYDE_T[i + 1] * 2 - 1,
                       CLYDE_T[i + 2] * 2 - 1}
            F.layer:tri(cx + CLYDE_V[t[1]] * r, ry(cy + CLYDE_V[t[1] + 1] * r),
                  cx + CLYDE_V[t[2]] * r, ry(cy + CLYDE_V[t[2] + 1] * r),
                  cx + CLYDE_V[t[3]] * r, ry(cy + CLYDE_V[t[3] + 1] * r),
                  pal.a(col, 0.10))
        end
        for _, ring in ipairs(CLYDE_RINGS) do
            local pts = {}
            for k = ring[1], ring[2] do
                pts[#pts + 1] = cx + CLYDE_V[k * 2 - 1] * r
                pts[#pts + 1] = ry(cy + CLYDE_V[k * 2] * r)
            end
            F.layer:outline(pts, 1.2 * F.scale, col, true)
        end
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
                   about = mark_about, discord = mark_discord, leave = mark_leave,
                   friends = mark_friends, upgrades = mark_upgrades}

    local function draw_mark(kind, cx, cy, r, col, cls)
        if kind == "ship" then return mark_ship(cx, cy, r, col, cls) end
        local f = MARKS[kind] or mark_about
        f(cx, cy, r, col)
    end

    return draw_mark
end

return M
