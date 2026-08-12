-- What a stroke is allowed to look like at the size it is actually drawn.
--
--     lua5.1 client/tests/stroke_test.lua
--
-- The browser gives one alpha sample per pixel and no argument, so every
-- stroke in this client is drawn with a pixel of ramp on each side and is
-- never allowed thinner than a pixel: the profile integrates to what a hard
-- quad would have covered, spread over enough of the screen for the screen to
-- show it. `seg` has always done that.
--
-- `seg_flat` did not. It is the cut the brand mark's diagonals take, and it
-- laid down a hard-edged quad instead, so the one stroke in the client that
-- leans by construction was the one drawn without antialiasing. Beside the
-- name on the home screen the mark is about two pixels thick, which is the
-- size where the ramp is most of the stroke, and the diagonals came out
-- visibly thinner and rougher than the verticals they land on.
--
-- So this measures both calls the way a screen does: how much ink each lays
-- down per unit of length, and how far it reaches square to itself.

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

-- The native writer, as much of it as the shapes need: every triangle, with
-- the alpha each corner carries.
local tris = {}
_G.vwbuf = {
    attach = function() return 1 end,
    reset = function() tris = {} end,
    rebind = function() end,
    finish = function() end,
    tri = function(_, x1, y1, x2, y2, x3, y3, col)
        tris[#tris + 1] = {{x1, y1, col[4] or 1}, {x2, y2, col[4] or 1},
                           {x3, y3, col[4] or 1}}
    end,
    tri_fade = function(_, x1, y1, a1, x2, y2, a2, x3, y3, a3, col)
        local A = col[4] or 1
        tris[#tris + 1] = {{x1, y1, a1 * A}, {x2, y2, a2 * A}, {x3, y3, a3 * A}}
    end,
    -- A quad is the two triangles it is made of, which is what the writer
    -- turns it into anyway.
    quad = function(id, x1, y1, x2, y2, x3, y3, x4, y4, col)
        _G.vwbuf.tri(id, x1, y1, x2, y2, x3, y3, col)
        _G.vwbuf.tri(id, x1, y1, x3, y3, x4, y4, col)
    end,
    rect = function() end,
}
_G.buffer = {create = function() return {} end,
             VALUE_TYPE_FLOAT32 = 1}
_G.go = {get = function() return nil end}
_G.hash = function(s) return s end

local vec = require("render.vec")
local layer = vec.layer("#none", 64)
layer.px = 1        -- the interface layer draws in pixels

local WHITE = {1, 1, 1, 1}

-- Ink, by sampling the triangles on a fine grid and taking the alpha at each
-- point. Coverage is what a screen resolves a stroke into, so it is what the
-- two calls have to agree about.
local function ink(x0, y0, x1, y1, step)
    local total = 0
    local function alpha_at(px, py)
        local best = 0
        for _, t in ipairs(tris) do
            local ax, ay, aa = t[1][1], t[1][2], t[1][3]
            local bx, by, ba = t[2][1], t[2][2], t[2][3]
            local cx, cy, ca = t[3][1], t[3][2], t[3][3]
            local d = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
            if math.abs(d) > 1e-12 then
                local u = ((by - cy) * (px - cx) + (cx - bx) * (py - cy)) / d
                local v = ((cy - ay) * (px - cx) + (ax - cx) * (py - cy)) / d
                local w = 1 - u - v
                if u >= -1e-9 and v >= -1e-9 and w >= -1e-9 then
                    -- Layers composite over one another, so the brightest
                    -- triangle covering a point is what that point ends up.
                    local a = u * aa + v * ba + w * ca
                    if a > best then best = a end
                end
            end
        end
        return best
    end
    for px = x0, x1, step do
        for py = y0, y1, step do
            total = total + alpha_at(px, py)
        end
    end
    return total * step * step
end

-- A vertical and a diagonal of the same nominal weight, at the size the
-- lockup draws them: a mark 59 px tall puts about two pixels in a stroke.
local ROW = 59 * 0.48
local W = ROW * 0.075
local RUN = 0.5 * ROW               -- a diagonal falls half as far as it runs
local WAKE = W * 4 / 3.6            -- measured across, so wider by the site's ratio

layer:reset()
layer:seg(40, 10, 40, 10 + ROW, W, WHITE)
local vertical = ink(20, 5, 60, 15 + ROW, 0.05) / ROW

layer:reset()
layer:seg_flat(40, 10, 40 + RUN, 10 + ROW, WAKE, WHITE)
local diagonal = ink(20, 5, 60 + RUN, 15 + ROW, 0.05)
    / math.sqrt(RUN * RUN + ROW * ROW)

check("a vertical lays down ink", vertical > 0.5,
      string.format("%.3f per unit", vertical))
check("a diagonal lays down the same ink per unit of length",
      math.abs(diagonal / vertical - 1) < 0.06,
      string.format("%.3f against %.3f, %+.1f%%", diagonal, vertical,
                    100 * (diagonal / vertical - 1)))

-- And it ramps rather than stopping dead, which is what the screen needs to
-- resolve a lean. A hard quad is two triangles and nothing else; a ramped one
-- carries corners at zero.
local faded = 0
for _, t in ipairs(tris) do
    for _, p in ipairs(t) do
        if p[3] < 0.01 then faded = faded + 1 end
    end
end
check("a flat-cut stroke ramps at its edges", faded > 0,
      "no corner of it reaches zero alpha")

-- Ends stay level. That is the whole reason this cut exists: the mark's rows
-- keep flat tops and bottoms while a diagonal is drawn across them.
local top, bottom = math.huge, -math.huge
for _, t in ipairs(tris) do
    for _, p in ipairs(t) do
        top, bottom = math.min(top, p[2]), math.max(bottom, p[2])
    end
end
check("and its ends stay level", math.abs(top - 10) < 1e-6
      and math.abs(bottom - (10 + ROW)) < 1e-6,
      string.format("%.3f to %.3f against %.3f to %.3f", top, bottom,
                    10, 10 + ROW))

-- Never thinner than the screen can hold. Below a pixel a stroke is widened
-- and dimmed by what it was widened by, so it keeps the light it had.
layer:reset()
layer:seg_flat(40, 10, 40 + RUN, 10 + ROW, 0.05, WHITE)
local reach = 0
for _, t in ipairs(tris) do
    for _, p in ipairs(t) do
        reach = math.max(reach, math.abs(p[1] - (40 + (p[2] - 10) * 0.5)))
    end
end
local across = reach * ROW / math.sqrt(RUN * RUN + ROW * ROW)
check("a hair-thin flat stroke still reaches a pixel across",
      across > 0.4, string.format("%.3f px", across * 2))

if fails > 0 then
    print(fails .. " failed")
    os.exit(1)
end
print("all ok")
